require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

$stdout.sync = true

# Run outside the build sandbox: Nix evaluates the installed provider flakes
# through the daemon, using locked test inputs and disposable configuration.
abort 'Usage: devcluster_nix_smoke.rb PACKAGE VPSADMIN VPSADMINOS VPSF_STATUS' unless ARGV.length == 4
package, vpsadmin, vpsadminos, status = ARGV

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
      overrides += [
        '--override-input', 'vpsadmin', "path:#{vpsadmin}",
        '--override-input', 'vpsadmin/vpsadminos', "path:#{vpsadminos}",
        '--override-input', 'vpsfStatus', "path:#{status}"
      ]
    end
    common = ['--impure', '--no-write-lock-file', *overrides]

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
