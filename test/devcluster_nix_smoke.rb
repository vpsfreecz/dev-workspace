require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

$stdout.sync = true

# Run outside the build sandbox: Nix evaluates the installed provider flakes
# through the daemon, using locked test inputs and disposable configuration.
storage_profile = ARGV.delete('--storage-profile')
unless ARGV.length == 5
  abort 'Usage: devcluster_nix_smoke.rb PACKAGE VPSADMIN VPSADMINOS VPSF_STATUS VPSADMIN_WEBUI [--storage-profile]'
end
package, vpsadmin, vpsadminos, status, webui = ARGV

def run!(environment, *command)
  stdout, stderr, result = Open3.capture3(environment, *command)
  unless result.success?
    warn stderr
    abort "Command failed (#{result.exitstatus}): #{command.join(' ')}"
  end
  stdout.strip
end

# Read the actual profile JSON producer in the evaluated services dependency
# graph. No fixture config import or VM closure realization substitutes for it.
def storage_profile_projection!(environment, config_drv)
  graph = JSON.parse(run!(environment, 'nix', 'derivation', 'show', '--recursive', config_drv))
  unless graph.is_a?(Hash) && graph.keys.sort == %w[derivations version] &&
         graph['version'].is_a?(Integer) && graph['version'] == 4 && graph['derivations'].is_a?(Hash)
    abort 'Unsupported Nix derivation metadata envelope'
  end
  derivations = graph.fetch('derivations')
  unless derivations.values.all? { |entry| entry.is_a?(Hash) && entry['env'].is_a?(Hash) }
    abort 'Invalid Nix derivation metadata entries'
  end
  profiles = derivations.values.select { |entry| entry.fetch('env').fetch('name', nil) == 'vpsadmin-storage-profile.json' }
  abort 'Actual services graph did not contain one profile JSON producer' unless profiles.one?

  JSON.parse(profiles.first.fetch('env').fetch('text'))
end

Dir.mktmpdir('devcluster-nix-smoke') do |workspace|
  key = File.join(workspace, 'id_ed25519')
  run!({}, 'ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key)
  certs = File.join(workspace, 'certs')
  FileUtils.mkdir_p(certs)

  %w[vpsadmin vpsadminos].each do |kind|
    source = File.join(package, 'share/vpsfree-dev-workspace/dev-clusters', kind)
    prefix = "#{kind.upcase}_DEVCLUSTER_"
    # Remove caller settings so an active development session cannot redirect
    # this check to its live configuration, credentials or source overrides.
    environment = ENV.keys.grep(/\AVPSADMIN(?:OS)?_DEVCLUSTER_/).to_h { |name| [name, nil] }
    environment.merge!(
      "#{prefix}WORKSPACE" => workspace,
      "#{prefix}SLUG" => 'packaging-smoke',
      "#{prefix}TOPOLOGY" => 'single',
      "#{prefix}SSH_PUBKEY" => "#{key}.pub",
      "#{prefix}CERT_DIR" => certs
    )
    overrides = ['--override-input', 'vpsadminos', "path:#{vpsadminos}"]
    if kind == 'vpsadmin'
      # A path override has no flake rev metadata; this store path still comes from the pinned input.
      environment["#{prefix}VPSADMIN_WEBUI_REVISION"] = '534caa83a5f97d2b40b4a126886649b14dc9e8d3'
      environment["#{prefix}VPSADMIN_WEBUI_DIRTY"] = '0'
      environment["#{prefix}VPSADMIN_WEBUI_SOURCE_KIND"] = 'pinned'
      overrides += [
        '--override-input', 'vpsadmin', "path:#{vpsadmin}",
        '--override-input', 'vpsadmin/vpsadminos', "path:#{vpsadminos}",
        '--override-input', 'vpsadminWebui', "path:#{webui}",
        '--override-input', 'vpsfStatus', "path:#{status}"
      ]
    end
    common = ['--impure', '--no-write-lock-file', *overrides]

    if kind == 'vpsadmin'
      provenance = JSON.parse(run!(environment, 'nix', 'eval', *common, '--json',
                                   "path:#{source}#lib.webuiPackageProvenance"))
      abort 'WebUI frontend/BFF package provenance differs' unless provenance.fetch('frontend') == provenance.fetch('bff')
    end

    # Forcing drvPath evaluates the actual machine configuration without
    # realising its VM closure or starting a kernel build.
    %w[bridge local].each do |network|
      environment["#{prefix}NETWORK"] = network
      %w[defaults override].each do |variant|
        if variant == 'override'
          config = File.join(workspace, "#{kind}-override.json")
          cluster_overrides = {
            'network' => { 'bridge' => 'smoke-br0' },
            'nodes' => { 'node1' => { 'sshPort' => 32123 } }
          }
          # Exercise explicit disabled selection against the actual default
          # API input, which has no profile scheduler refresh option.
          cluster_overrides['storageProfile'] = { 'enable' => false } if kind == 'vpsadmin'
          File.write(config, JSON.generate(cluster_overrides))
          environment["#{prefix}CONFIG_FILE"] = config
        else
          environment["#{prefix}CONFIG_FILE"] = nil
        end
        result = JSON.parse(run!(environment, 'nix', 'eval', *common, '--json',
                                 '--apply', 'config: { drvPath = config.drvPath; text = config.text; }',
                                 "path:#{source}#cluster-config"))
        abort "Expected a configuration derivation, got #{result.inspect}" unless result.fetch('drvPath').end_with?('.drv')
        rendered = JSON.parse(result.fetch('text'))
        if kind == 'vpsadmin'
          if rendered.fetch('labels').key?('vpsadminPreservingSeed')
            abort 'Disabled storage profile emitted a preserving-seed marker'
          end
          abort 'Disabled WebUI unexpectedly added source labels' unless
            (rendered.fetch('labels').keys & %w[webuiSourceRevision webuiSourceDirty webuiSourceKind]).empty?
          abort 'Disabled WebUI unexpectedly added a credential mount' if rendered.fetch('machines').fetch('services').fetch('sharedFileSystems').key?('webuiCredentials')
        end
        defaults = JSON.parse(File.read(File.join(source, 'default-config.json')))
        networks = rendered.fetch('machines').fetch('node1').fetch('networks')
        if network == 'bridge'
          expected = variant == 'override' ? 'smoke-br0' : defaults.fetch('network').fetch('bridge')
          actual = networks.find { |entry| entry.fetch('type') == 'bridge' }.fetch('opts').fetch('link')
        else
          port = variant == 'override' ? 32123 : defaults.fetch('nodes').fetch('node1').fetch('sshPort')
          expected = "tcp:127.0.0.1:#{port}-:22"
          actual = networks.find { |entry| entry.fetch('type') == 'user' }.fetch('opts').fetch('hostForward')
        end
        unless actual == expected
          abort "#{kind}: #{network} #{variant} expected #{expected.inspect}, got #{actual.inspect}"
        end
        puts "#{kind}: #{network} #{variant} configuration evaluated"
      end
    end

    if kind == 'vpsadmin'
      enabled = File.join(workspace, 'vpsadmin-enabled.json')
      File.write(enabled, JSON.generate(
        'newWebui' => { 'enable' => true },
        'domains' => { 'newadmin' => 'newadmin.smoke.example.test' }
      ))
      environment["#{prefix}CONFIG_FILE"] = enabled
      environment["#{prefix}WEBUI_CREDENTIALS_DIR"] = File.join(workspace, 'runtime-webui-credentials')
      environment["#{prefix}NETWORK"] = 'bridge'
      result = JSON.parse(run!(environment, 'nix', 'eval', *common, '--json',
                               '--apply', 'config: { drvPath = config.drvPath; text = config.text; }',
                               "path:#{source}#cluster-config"))
      rendered = JSON.parse(result.fetch('text'))
      mounts = rendered.fetch('machines').fetch('services').fetch('sharedFileSystems')
      assert_path = environment.fetch("#{prefix}WEBUI_CREDENTIALS_DIR")
      abort 'Enabled WebUI runtime mount is missing from services' unless mounts.fetch('webuiCredentials') == assert_path
      abort 'WebUI runtime mount leaked to a node' if rendered.fetch('machines').fetch('node1').fetch('sharedFileSystems').key?('webuiCredentials')
      expected_labels = {
        'webuiSourceRevision' => '534caa83a5f97d2b40b4a126886649b14dc9e8d3',
        'webuiSourceDirty' => 'false',
        'webuiSourceKind' => 'pinned'
      }
      abort 'WebUI source labels were not retained in the build' unless rendered.fetch('labels') == expected_labels
      puts 'vpsadmin: enabled bridge WebUI configuration evaluated'

      {
        "#{prefix}VPSADMIN_WEBUI_REVISION" => ['invalid', 'lowercase source revision'],
        "#{prefix}VPSADMIN_WEBUI_DIRTY" => ['unknown', 'source dirty value'],
        "#{prefix}VPSADMIN_WEBUI_SOURCE_KIND" => ['foreign', 'source kind']
      }.each do |name, (invalid, error)|
        original = environment.fetch(name)
        environment[name] = invalid
        _stdout, stderr, result = Open3.capture3(environment, 'nix', 'eval', *common, '--json',
                                                  '--apply', 'config: config.drvPath',
                                                  "path:#{source}#cluster-config")
        abort "Invalid #{name} was accepted" if result.success?
        unless stderr.include?(error)
          # This request uses only the fixed disposable smoke configuration.
          warn stderr
          abort "Invalid #{name} did not report #{error}"
        end
        environment[name] = original
      end

      environment["#{prefix}NETWORK"] = 'local'
      _stdout, stderr, result = Open3.capture3(environment, 'nix', 'eval', *common, '--json',
                                                '--apply', 'config: config.drvPath',
                                                "path:#{source}#cluster-config")
      abort 'Enabled local WebUI was accepted' if result.success?
      abort 'Enabled local WebUI did not report its routing limit' unless stderr.include?('requires bridge networking')
      puts 'vpsadmin: enabled local WebUI refused'

      if storage_profile
        profile_config = File.join(workspace, 'vpsadmin-storage-profile.json')
        File.write(profile_config, JSON.generate('storageProfile' => { 'enable' => true }))
        environment["#{prefix}CONFIG_FILE"] = profile_config
        environment["#{prefix}TOPOLOGY"] = 'storage'
        environment["#{prefix}NETWORK"] = 'local'
        result = JSON.parse(run!(environment, 'nix', 'eval', *common, '--json',
                                 '--apply', 'config: { drvPath = config.drvPath; text = config.text; }',
                                 "path:#{source}#cluster-config"))
        rendered = JSON.parse(result.fetch('text'))
        marker = JSON.parse(rendered.fetch('labels').fetch('vpsadminPreservingSeed'))
        abort 'Enabled storage profile marker differs from preserving seed policy' unless
          marker == { 'version' => 1, 'existingAssignments' => 'preserve' }
        abort 'Storage profile did not retain the actual storage topology' unless
          %w[node1 node2 storage1 services].all? { |machine| rendered.fetch('machines').key?(machine) }
        legacy_projection = storage_profile_projection!(environment, result.fetch('drvPath'))
        abort 'Omitted VPS backup selection changed the v1 projection' unless
          legacy_projection.fetch('version') == 1 && !legacy_projection.key?('vpsBackupPool')
        puts 'vpsadmin: enabled storage profile and actual services closure evaluated'

        File.write(profile_config, JSON.generate('storageProfile' => { 'enable' => true, 'enrollment' => false }))
        retired_result = JSON.parse(run!(environment, 'nix', 'eval', *common, '--json',
                                         '--apply', 'config: { drvPath = config.drvPath; text = config.text; }',
                                         "path:#{source}#cluster-config"))
        retired = JSON.parse(retired_result.fetch('text'))
        abort 'Retired storage profile lost its preserving seed marker' unless
          retired.fetch('labels').fetch('vpsadminPreservingSeed') == rendered.fetch('labels').fetch('vpsadminPreservingSeed')
        puts 'vpsadmin: retired storage profile retains preserving services closure'
        [nil, 'false'].each do |invalid|
          File.write(profile_config, JSON.generate('storageProfile' => { 'enable' => true, 'enrollment' => invalid }))
          _stdout, stderr, result = Open3.capture3(environment, 'nix', 'eval', *common, '--json',
                                                   '--apply', 'config: config.drvPath', "path:#{source}#cluster-config")
          abort 'Storage profile accepted nonboolean enrollment' if result.success?
          abort 'Invalid enrollment did not report the boolean boundary' unless stderr.include?('must be booleans')
        end
        placement = { 'enable' => true, 'vpsBackupFilesystem' => 'tank/vps-backup' }
        [true, false].each do |enrollment|
          File.write(profile_config, JSON.generate('storageProfile' => placement.merge('enrollment' => enrollment)))
          placement_result = JSON.parse(run!(environment, 'nix', 'eval', *common, '--json',
                                             '--apply', 'config: { drvPath = config.drvPath; text = config.text; }',
                                             "path:#{source}#cluster-config"))
          actual = storage_profile_projection!(environment, placement_result.fetch('drvPath'))
          expected = legacy_projection.merge('version' => 2, 'enrollment' => enrollment,
                                             'vpsBackupPool' => legacy_projection.fetch('backupPool').merge('filesystem' => 'tank/vps-backup'))
          abort 'Actual v2 placement projection differs' unless actual == expected
          labels = JSON.parse(placement_result.fetch('text')).fetch('labels')
          abort 'V2 placement changed preserving-seed marker1' unless
            labels.fetch('vpsadminPreservingSeed') == rendered.fetch('labels').fetch('vpsadminPreservingSeed')
          puts "vpsadmin: actual v2 placement enrollment=#{enrollment} evaluated"
        end
        [nil, '', 32, 'tank', 'tank/backup', 'tank/nas', 'tank/backup/nas-3'].each do |invalid|
          File.write(profile_config, JSON.generate('storageProfile' => placement.merge('vpsBackupFilesystem' => invalid)))
          _stdout, stderr, result = Open3.capture3(environment, 'nix', 'eval', *common, '--json',
                                                   '--apply', 'config: config.drvPath', "path:#{source}#cluster-config")
          abort 'Storage profile accepted an invalid or overlapping VPS backup root' if result.success?
          unless stderr.include?('VPS backup root must be valid and distinct')
            warn stderr
            abort 'Invalid VPS backup root did not report its placement boundary'
          end
        end
        File.write(profile_config, JSON.generate('storageProfile' => { 'enable' => true }))

        environment["#{prefix}TOPOLOGY"] = 'single'
        _stdout, stderr, result = Open3.capture3(environment, 'nix', 'eval', *common, '--json',
                                                 '--apply', 'config: config.drvPath', "path:#{source}#cluster-config")
        abort 'Enabled storage profile accepted an incomplete topology' if result.success?
        unless stderr.include?('requires storage topology')
          abort 'Invalid storage topology did not report the profile boundary'
        end
        puts 'vpsadmin: storage profile without a storage node refused'
        environment["#{prefix}TOPOLOGY"] = 'storage'
      end
    end

    output = run!(environment, 'nix', 'build', *common, '--no-link', '--print-out-paths', "path:#{source}#runner")
    executable = File.join(output, 'bin', "#{kind}-devcluster-runner")
    stdout, stderr, result = Open3.capture3(environment, executable)
    unless result.exitstatus == 2 && (stdout + stderr).start_with?('Usage: ')
      warn stdout + stderr
      abort "#{kind}: runner did not load successfully"
    end
    puts "#{kind}: runner built and loaded"
  end
end
