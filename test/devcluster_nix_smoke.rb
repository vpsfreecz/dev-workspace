require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

$stdout.sync = true

# Run outside the build sandbox: Nix evaluates the installed provider flakes
# through the daemon, using locked test inputs and disposable configuration.
abort 'Usage: devcluster_nix_smoke.rb PACKAGE VPSADMIN VPSADMINOS VPSF_STATUS VPSADMIN_WEBUI' unless ARGV.length == 5
package, vpsadmin, vpsadminos, status, webui = ARGV

def run!(environment, *command)
  stdout, stderr, result = Open3.capture3(environment, *command)
  unless result.success?
    warn stderr
    abort "Command failed (#{result.exitstatus}): #{command.join(' ')}"
  end
  stdout.strip
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
          File.write(config, JSON.generate(
            'network' => { 'bridge' => 'smoke-br0' },
            'nodes' => { 'node1' => { 'sshPort' => 32123 } }
          ))
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
        abort "Invalid #{name} did not report #{error}" unless stderr.include?(error)
        environment[name] = original
      end

      environment["#{prefix}NETWORK"] = 'local'
      _stdout, stderr, result = Open3.capture3(environment, 'nix', 'eval', *common, '--json',
                                                '--apply', 'config: config.drvPath',
                                                "path:#{source}#cluster-config")
      abort 'Enabled local WebUI was accepted' if result.success?
      abort 'Enabled local WebUI did not report its routing limit' unless stderr.include?('requires bridge networking')
      puts 'vpsadmin: enabled local WebUI refused'
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
