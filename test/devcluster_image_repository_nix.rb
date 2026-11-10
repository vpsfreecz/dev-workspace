require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# No derivation realization, service, VM or cluster mutation. The generated
# logger runs only with bounded local stand-ins for external commands.
def check_generated_logger(tmp, projection)
  service = File.join(tmp, 'logger-service')
  log = File.join(service, 'log')
  bin = File.join(tmp, 'logger-bin')
  data = File.join(tmp, 'logger-data')
  trace = File.join(tmp, 'logger-trace')
  [log, bin, data].each { |dir| FileUtils.mkdir_p(dir) }
  # This is the selected OS helper template; its unrelated osctl operations
  # are unavailable in this fixture. waitForService itself stays unchanged.
  File.write(File.join(service, 'helpers'), projection.fetch('helperTemplate').gsub('@osctl@', '/unavailable-osctl'))
  commands = {
    'sv' => "test \"$*\" = 'check pool-tank' || exit 90\nprintf 'pool-ready\\n' >> \"$TRACE\"\n",
    'prepare' => "printf 'prepare\\n' >> \"$TRACE\"\nmkdir -p \"$DATA/logs/service\"\n",
    'chpst' => "test \"$1\" = -u || exit 91\ntest \"$2\" = osctl-repo-demo:osctl-repo-demo || exit 92\nshift 2\nexec \"$@\"\n",
    'svlogd' => "test \"$*\" = \"-tt $DATA/logs/service\" || exit 93\nprintf 'logger\\n' >> \"$TRACE\"\n"
  }
  commands.each do |name, body|
    path = File.join(bin, name)
    File.write(path, "#!/usr/bin/env bash\nset -e\n#{body}")
    File.chmod(0o700, path)
  end
  script = projection.fetch('generatedLog')
  replacements = {
    %r{/nix/store/[^/\s]+-prepare-repository-demo} => File.join(bin, 'prepare'),
    %r{/nix/store/[^/\s]+/bin/chpst} => File.join(bin, 'chpst'),
    %r{/nix/store/[^/\s]+/bin/svlogd} => File.join(bin, 'svlogd')
  }
  replacements.each do |pattern, replacement|
    abort "Generated logger command missing: #{pattern}" unless script.scan(pattern).length == 1
    script = script.gsub(pattern, replacement)
  end
  script = script.gsub('/var/lib/osctl-repo-server-demo', data)
  path = File.join(log, 'run')
  File.write(path, script)
  environment = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'TRACE' => trace, 'DATA' => data, 'BASH_ENV' => nil }
  _, err, status = Open3.capture3(environment, 'bash', path, chdir: log)
  abort "Generated logger failed: #{err}" unless status.success?
  abort 'Generated logger startup order differs' unless File.read(trace) == "pool-ready\nprepare\nlogger\n"
  abort 'Private logger rotation config differs' unless File.read("#{data}/logs/service/config") == "s1048576\nn2\n"
  # Show that the original missing-helper defect is caught before preparation
  # or logger execution, without executing any native service or storage tool.
  File.write(trace, '')
  File.write(path, script.lines.reject { |line| line.strip == 'source ../helpers' }.join)
  _, err, status = Open3.capture3(environment, 'bash', path, chdir: log)
  abort 'Missing-helper logger unexpectedly succeeded' if status.success?
  abort 'Missing-helper failure not reproduced' unless err.include?('waitForService: command not found') && File.read(trace).empty?
end

abort 'Usage: ruby test/devcluster_image_repository_nix.rb VPSADMINOS_FLAKE' unless ARGV.length == 1
repository = File.expand_path('..', __dir__)
Dir.mktmpdir('image-repository-module-') do |tmp|
  provider = File.join(tmp, 'provider')
  FileUtils.cp_r(File.join(repository, 'dev-clusters/vpsadminos'), provider)
  FileUtils.cp(File.join(repository, 'test/fixtures/vpsadminos-config.json'), File.join(provider, 'default-config.json'))
  config = File.join(tmp, 'config.json')
  expression = <<~'NIX'
    let
      os = builtins.getFlake (builtins.getEnv "DEMO_OS");
      lib = os.inputs.nixpkgs.lib;
      test = (import (builtins.getEnv "DEMO_PROVIDER" + "/nix/test.nix") {
        inherit lib; vpsadminos = os; workspace = "/fixture"; slug = "demo";
        topology = "dual"; networkMode = "bridge"; bridgeHelper = "";
        clusterConfigFile = builtins.getEnv "DEMO_CONFIG";
        sshPubKey = "/fixture/public-key"; vpsadminosSourcePath = os.outPath;
      }) { pkgs = {}; };
      evaluate = node: (import (os.outPath + "/os") {
        pkgs = os.inputs.nixpkgs.outPath;
        configuration = null;
        modules = [ (os.outPath + "/tests/configs/vpsadminos/base.nix") test.machines.${node}.config ];
        extraArgs = { vpsadminos = os; };
      }).config;
      cfg = evaluate "node1";
      service = cfg.runit.services.osctl-repo-server-demo or null;
    in {
      source = os.outPath;
      servicePackage = toString os.packages.x86_64-linux.osctl-repo-server;
      imports = builtins.mapAttrs (_: n: builtins.length n.config.imports) test.machines;
      enabled = service != null;
      run = if service == null then "" else service.run;
      log = if service == null then "" else service.log.run;
      generatedLog = if service == null then "" else cfg.environment.etc."runit/services/osctl-repo-server-demo/log/run".source.text;
      helperTemplate = if service == null then "" else builtins.readFile cfg.environment.etc."runit/services/osctl-repo-server-demo/helpers".source.src;
      cron = cfg.services.cron.systemCronJobs;
      users = builtins.attrNames cfg.users.users;
      packages = map toString cfg.environment.systemPackages;
    }
  NIX
  env = { 'DEMO_OS' => File.expand_path(ARGV.first), 'DEMO_PROVIDER' => provider, 'DEMO_CONFIG' => config }
  evaluate = lambda do |addon, success: true|
    File.write(config, JSON.generate('imageRepository' => addon))
    out, err, status = Open3.capture3(env, 'nix', 'eval', '--impure', '--json', '--expr', expression)
    abort err unless status.success? == success
    success ? JSON.parse(out) : err
  end
  disabled = evaluate.call({ 'enable' => false })
  abort 'Disabled addon imported a module' unless disabled['imports'].values == [2, 2] && !disabled['enabled']
  enabled = evaluate.call({ 'enable' => true, 'node' => 'node1' })
  abort 'Addon was not isolated to selected node' unless enabled['imports'] == { 'node1' => 3, 'node2' => 2 }
  selected_server = "#{enabled.fetch('servicePackage')}/bin/osctl-repo-server serve"
  abort 'Selected package/listener missing' unless enabled['run'].include?(selected_server) && enabled['run'].include?('--listen 127.0.0.1:8080') && enabled['packages'].include?(enabled.fetch('servicePackage'))
  abort 'Native service account missing' unless enabled['users'].include?('osctl-repo-demo')
  abort 'Bounded maintenance missing' unless enabled['cron'].any? { |x| x.include?('17 * * * * osctl-repo-demo') }
  abort 'Seed command missing' unless enabled['packages'].any? { |x| x.end_with?('-osctl-repo-demo-seed') }
  abort 'Backward-compatible measurement defaults changed' unless enabled['run'].match?(/--instance '?synthetic-demo'?(?:\s|$)/) &&
                                                               enabled['run'].include?('--stats-days 7 --stats-max-rows 256') &&
                                                               !enabled['run'].include?('--display-name') && !enabled['run'].include?('--purpose')
  rich = evaluate.call({ 'enable' => true, 'displayName' => 'Synthetic image catalog preview',
                         'purpose' => 'Synthetic archive bytes and simulated history; later observations are preview traffic, not production downloads.',
                         'instance' => 'synthetic-history-v1', 'statsDays' => 365, 'statsMaxRows' => 65_536 })
  abort 'Explicit preview fields/limits missing' unless rich['run'].match?(/--instance '?synthetic-history-v1'?(?:\s|$)/) &&
                                                      rich['run'].include?("--display-name 'Synthetic image catalog preview'") &&
                                                      rich['run'].include?('--stats-days 365 --stats-max-rows 65536') &&
                                                      rich['run'].include?('--max-bytes 67108864')
  abort 'Explicit offline fixture helper missing' unless rich['packages'].any? { |x| x.end_with?('-osctl-repo-demo-history') }
  check_generated_logger(tmp, enabled)
  no_seed = evaluate.call({ 'enable' => true, 'seed' => false })
  abort 'Seed command present despite disabled seed' if no_seed['packages'].any? { |x| x.end_with?('-osctl-repo-demo-seed') }
  wrong_node = evaluate.call({ 'enable' => true, 'node' => 'node3' }, success: false)
  abort 'Wrong node error missing' unless wrong_node.include?('must exist in the selected topology')
  wrong_port = evaluate.call({ 'enable' => true, 'port' => 8081 }, success: false)
  abort 'Wrong port error missing' unless wrong_port.include?('loopback port 8080')
  unbounded = evaluate.call({ 'enable' => true, 'limits' => { 'maxRuns' => 0 } }, success: false)
  abort 'Finite bound error missing' unless unbounded.include?('finite demo bounds')
  [ { 'statsDays' => 0 }, { 'statsDays' => 366 }, { 'statsMaxRows' => 65_537 },
    { 'instance' => '../escape' }, { 'displayName' => "bad\nname" }, { 'purpose' => 'x' * 513 } ].each do |fields|
    error = evaluate.call({ 'enable' => true }.merge(fields), success: false)
    abort 'Invalid optional presentation/measurement field accepted' unless error.include?('finite demo bounds')
  end
  puts JSON.generate(source: enabled.fetch('source'), service_package: enabled.fetch('servicePackage'), truths: 16,
                     generated_logger: 'helper loaded; pool -> prepare -> logger; missing-helper failure reproduced', result: 'pass')
end
