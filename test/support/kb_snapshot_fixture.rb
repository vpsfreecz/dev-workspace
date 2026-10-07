# frozen_string_literal: true

require 'tmpdir'
require 'timeout'
require 'rbconfig'
require_relative '../../dev-clusters/kb/lib/portable'


# Synthetic private state/process fixture using the exact selected K readers.
module KbSnapshotFixture
  def metadata_path
    ENV.fetch('VPSFREE_KB_ENGINE_METADATA')
  end

  def with_snapshot
    Dir.mktmpdir('kb-adapter-snapshot-') do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      binding.create(engine_revision: 'a' * 40)
      portable = DevClusters::Kb::Portable.new(binding:, metadata_path:)
      state = KbRuntime::State.new(binding.state_root, binding.slug)
      software = KbRuntime::Software.new(JSON.parse(File.read(metadata_path)))
      engine = KbRuntime::Engine.new(state:, software:, controller: [RbConfig.ruby,
        File.join(software.source, 'cluster/launcher.rb'), '--software-metadata', metadata_path])
      state.transaction(create: true) { state.initialize_identity }
      credentials = state.path('credentials')
      state.private_directory(credentials, create: true)
      %w[id_ed25519 id_ed25519.pub known_hosts vpsadmin-ca.crt vpsadmin-ca.key vpsadmin-cert.crt vpsadmin-cert.key].each do |name|
        File.open(File.join(credentials, name), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write('synthetic fixture') }
      end
      id = state.identity
      artifact_id, run_id = SecureRandom.uuid, SecureRandom.uuid
      config = { 'domains' => { 'webui' => 'webui.example.test' },
        'local' => { 'ports' => { 'services' => { 'https' => 28443 } } } }
      input = state.path('fixture-input.json')
      state.write(input, config)
      build_inputs = { 'topology' => 'single', 'network' => 'local' }
      input_sha = Digest::SHA256.hexdigest(KbRuntime::Software.canonical_json(build_inputs.merge('config' => config)))
      layout = { 'services' => { 'spin' => 'nixos', 'root_image' => true, 'disks' => [] } }
      disk = state.path('fixture-root.img')
      File.open(disk, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write('sentinel') }
      runner = state.path('fixture-runner.rb')
      File.open(runner, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("STDOUT.puts('ready'); STDOUT.flush; STDIN.read\n")
      end
      artifact = { 'schema' => 1, 'instance_id' => id['instance_id'], 'artifact_id' => artifact_id,
        'source' => software.metadata, 'topology' => 'single', 'network' => 'local',
        'input_path' => input, 'config_path' => input, 'config_sha256' => Digest::SHA256.file(input).hexdigest,
        'config_input_sha256' => input_sha, 'build_inputs' => build_inputs,
        'guest_identity' => { 'schema' => 1, 'source' => software.metadata, 'instance_id' => id['instance_id'],
          'artifact_id' => artifact_id, 'config_input_sha256' => input_sha }, 'layout' => layout,
        'credential_identity' => KbRuntime::Software.credentials_identity(credentials), 'runner' => runner,
        'runner_identity' => { 'executable' => RbConfig.ruby, 'entrypoint' => runner },
        'machine_toplevels' => { 'services' => "/nix/store/#{'0' * 32}-synthetic-toplevel" } }
      state.write(state.path("artifact-#{artifact_id}.json"), artifact)
      state.write(state.path("prepared-#{artifact_id}.json"), { 'schema' => 1, 'complete' => true,
        'instance_id' => id['instance_id'], 'artifact_id' => artifact_id, 'kind' => 'initial', 'layout' => layout })
      state.write(state.path('disks-services.json'), { 'schema' => 1, 'complete' => true,
        'instance_id' => id['instance_id'], 'layout' => layout['services'],
        'disks' => { 'root' => KbRuntime::DiskPreparation.new(state, artifact).identity(disk) } })
      record = artifact.merge(id).merge('run_id' => run_id, 'boot_id' => KbRuntime::ProcessIdentity.boot_id,
        'artifact_sha256' => engine.artifact_digest(artifact), 'state_dir' => state.directory,
        'socket_dir' => engine.resources.socket_dir(id['instance_id'], run_id),
        'endpoints' => { 'services' => { 'host' => '127.0.0.1', 'port' => 28022, 'user' => 'root' } })
      input_reader, writer = IO.pipe
      reader, output_writer = IO.pipe
      argv = %w[config state-dir sock-dir run-id instance-id artifact-id artifact-sha256].flat_map do |key|
        value = { 'config' => record['config_path'], 'state-dir' => record['state_dir'], 'sock-dir' => record['socket_dir'] }[key] || record[key.tr('-', '_')]
        ["--#{key}", value]
      end
      pid = Process.spawn(RbConfig.ruby, runner, *argv, in: input_reader, out: output_writer, err: File::NULL, close_others: true)
      input_reader.close
      output_writer.close
      raise 'synthetic runner handshake failed' unless Timeout.timeout(5) { reader.gets } == "ready\n"
      process = KbRuntime::ProcessIdentity.read(pid)
      raise 'synthetic runner tuple differs' unless KbRuntime::ProcessIdentity.runner_matches?(process, record)
      state.write(state.path("launch-#{run_id}.json"), record)
      state.write(state.path("processes-#{run_id}.json"), record.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256').merge('runner' => process, 'children' => [], 'complete' => false))
      state.write(state.path('phase.json'), { 'schema' => 1, 'phase' => 'ready', 'run_id' => run_id })
      state.write(state.path("ready-#{run_id}.json"), record.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256').merge('schema' => 1))
      state.write(state.path('accounts.json'), { 'users' => [] })
      state.write(state.path('connection.json'), engine.descriptor(record))
      yield binding, portable, state, engine, record, artifact
    ensure
      writer&.close unless writer&.closed?
      Timeout.timeout(5) { Process.waitpid(pid) } if pid
      [input_reader, writer, reader, output_writer].compact.each { |stream| stream.close unless stream.closed? }
    end
  end

  def files(root)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).sort.filter_map do |path|
      next if %w[. ..].include?(File.basename(path))
      stat = File.lstat(path)
      [path, [stat.mode, stat.ino, stat.size, stat.file? ? File.binread(path) : nil]]
    end.to_h
  end

end
