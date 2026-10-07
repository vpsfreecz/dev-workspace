# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'open3'
require 'tempfile'
require_relative 'support/kb_snapshot_fixture'
require_relative '../dev-clusters/kb/lib/guards'

# The generic dispatcher, E CLI and selected K snapshot reader are real. Only
# the final live guest/SSH lease is replaced by a synthetic, gate-owning child.
# This is local composition proof, not installed activation or VM proof.
load File.join(ENV.fetch('DEV_WORKSPACE_HOST_SOURCE'), 'libexec/workspace-host')

class KbPublicDispatchTest < Minitest::Test
  include KbSnapshotFixture

  def with_dispatch
    with_snapshot do |binding, _portable, state, engine, record, _artifact|
      workspace = binding.workspace
      %w[repos work worktrees].each { |name| FileUtils.mkdir_p(File.join(workspace, name)) }
      FileUtils.mkdir_p(File.join(workspace, 'work/session'))
      File.write(File.join(workspace, 'work/session/state.md'), "---\nlifecycle: active\n---\n")
      session_lock = File.join(workspace, 'worktrees/.locks/session.lock')
      FileUtils.mkdir_p(File.dirname(session_lock))
      File.open(session_lock, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      registry = File.join(workspace, 'registry.json')
      DevWorkspaceHost::Registry.new(registry).register(name: 'example', root: workspace,
        hostname: 'workspace.example.test', aliases: [], replace: false)
      profile = File.join(workspace, 'profile')
      File.symlink(ENV.fetch('DEV_WORKSPACE_HOST_SOURCE'), profile)
      pid_file = File.join(workspace, 'lease-child.pid')
      ended = File.join(workspace, 'lease-ended')
      release = File.join(workspace, 'lease-release')
      fds = File.join(workspace, 'lease-fds.json')
      fixed = File.join(workspace, 'selected-lease-fixture')
      File.write(fixed, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'json'
        require 'digest'
        require #{File.join(JSON.parse(File.read(metadata_path)).fetch('source'), 'cluster/lib/kb_state').inspect}
        root, command, slug = ARGV[1, 3]
        abort 'unexpected fixed CLI operation' unless command == 'capture-lease'
        options = ARGV.drop(4).each_slice(2).to_h
        state = KbRuntime::State.new(root, slug)
        state.lock('gate', wait: false) do
          descriptor = state.file(state.path('connection.json'))
          value = JSON.parse(descriptor)
          expected = value.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256')
          wanted = expected.to_h { |key, entry| ['--' + key.tr('_', '-'), entry] }
          wanted['--descriptor-sha256'] = Digest::SHA256.hexdigest(descriptor)
          abort 'canonical child request differs' unless options == wanted
          File.write(#{pid_file.inspect}, Process.pid.to_s)
          File.write(#{fds.inspect}, JSON.generate(Dir.glob('/proc/self/fd/*').filter_map { |path| File.readlink(path) rescue nil }))
          puts JSON.generate(expected.merge('schema' => 1, 'descriptor_sha256' => wanted['--descriptor-sha256']))
          STDOUT.flush
          command = STDIN.gets
          if command == "close-protocol\n"
            STDOUT.reopen(File::NULL, 'w')
            STDOUT.close
          elsif command == "close-diagnostics\n"
            STDERR.reopen(File::NULL, 'w')
            STDERR.close
          end
          STDIN.read
          File.write(#{ended.inspect}, 'owned input EOF')
          sleep 0.01 until File.exist?(#{release.inspect}) if command == "close-protocol\n"
        end
      RUBY
      File.chmod(0o755, fixed)
      provider = File.join(workspace, 'selected-adapter')
      File.write(provider, <<~RUBY)
        #!#{RbConfig.ruby}
        require #{File.expand_path('../dev-clusters/kb/lib/cli', __dir__).inspect}
        exit DevClusters::Kb::CLI.run(ARGV)
      RUBY
      File.chmod(0o755, provider)
      catalog = File.join(workspace, 'extensions.json')
      File.write(catalog, JSON.generate('schema' => 1, 'commands' => [], 'skills' => [],
        'clusterProviders' => [{ 'id' => 'kb', 'label' => 'KB', 'command' => provider }]))
      environment = { 'HOME' => workspace, 'PATH' => ENV.fetch('PATH'),
        'DEV_WORKSPACES_CONFIG' => registry, 'DEV_WORKSPACES_STATE' => File.join(workspace, 'host-state'),
        'DEV_WORKSPACES_PROFILE' => profile, 'DEV_WORKSPACES_EXTENSION_CATALOG' => catalog,
        'DEV_WORKSPACES_RUNTIME_DIR' => File.join(workspace, 'host-runtime'),
        'VPSFREE_KB_ENGINE_METADATA' => metadata_path, 'VPSFREE_KB_ENGINE' => fixed,
        'DEVCLUSTER_RUNTIME_CONTRACT' => ENV.fetch('DEVCLUSTER_RUNTIME_CONTRACT'),
        'DEV_WORKSPACE_HOST_MODE' => 'kb-devcluster' }
      guards = DevClusters::Kb::Guards.new(binding:, contract: JSON.parse(File.read(environment['DEVCLUSTER_RUNTIME_CONTRACT'])),
        environment: environment.merge('DEV_WORKSPACE_NAME' => 'example'))
      guards.adapter(create: true) {}
      begin
        yield binding, state, engine, record, environment, { pid: pid_file, ended:, release:, fds:, session_lock:,
          generation_lock: File.join(workspace, 'host-state/transition.lock') }
      ensure
        File.write(release, '')
        if File.exist?(pid_file)
          owned_child = Integer(File.read(pid_file))
          Timeout.timeout(7) { sleep 0.02 while KbRuntime::ProcessIdentity.read(owned_child) }
        end
      end
    end
  end

  def dispatcher
    File.join(ENV.fetch('DEV_WORKSPACE_HOST_SOURCE'), 'libexec/workspace-host')
  end

  def managed(environment)
    output, error, result = Open3.capture3(environment, RbConfig.ruby, dispatcher,
      '--workspace', 'example', 'connection', 'session', close_others: true)
    assert(result.success?, error)
    [output, JSON.parse(output)]
  end

  def lease_flags(bytes, value)
    request = value.slice('instance_id', 'run_id', 'artifact_id', 'artifact_sha256')
      .merge('descriptor_sha256' => Digest::SHA256.hexdigest(bytes))
    request.flat_map { |key, entry| ["--#{key.tr('_', '-')}", entry] }
  end

  def start_dispatch(environment, flags)
    input, writer = IO.pipe
    reader, output = IO.pipe
    diagnostics = Tempfile.new('kb-dispatch-diagnostics')
    pid = Process.spawn(environment, RbConfig.ruby, dispatcher, '--workspace', 'example',
      'capture-lease', 'session', *flags, in: input, out: output, err: diagnostics, close_others: true)
    input.close
    output.close
    yield pid, writer, reader, diagnostics
  ensure
    [input, writer, reader, output].compact.each { |stream| stream.close unless stream.closed? }
    if pid
      owned = begin
        Process.waitpid(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        false
      end
      if owned
        Process.kill('KILL', pid)
        Process.waitpid(pid)
      end
    end
    diagnostics&.close!
  end

  def wait_file(path)
    Timeout.timeout(5) { sleep 0.01 until File.exist?(path) }
  end

  def test_public_connection_uses_selected_reader_and_keeps_canonical_bytes_untouched
    with_dispatch do |binding, state, _engine, _record, environment, _paths|
      original = File.binread(state.path('connection.json'))
      bytes, value = managed(environment)
      assert_equal([File.join(binding.workspace, 'bin/kb-devcluster'), '--workspace', 'example', 'capture-lease', 'session'], value['control']['argv'])
      assert_equal(JSON.parse(original).reject { |key, _| key == 'control' }, value.reject { |key, _| key == 'control' })
      assert_equal(original, File.binread(state.path('connection.json')))
      assert_equal(bytes, File.binread(File.join(binding.record_directory, 'connection.json')))
      assert_equal('a' * 40, binding.read['engine_revision'])
    end
  end

  def test_public_lease_holds_all_guards_until_canonical_child_is_reaped_after_protocol_loss
    with_dispatch do |binding, state, _engine, _record, environment, paths|
      bytes, value = managed(environment)
      start_dispatch(environment, lease_flags(bytes, value)) do |pid, writer, reader, diagnostics|
        ready = JSON.parse(Timeout.timeout(5) { reader.gets })
        assert_equal(Digest::SHA256.hexdigest(bytes), ready['descriptor_sha256'])
        refute_equal(Digest::SHA256.file(state.path('connection.json')).hexdigest, ready['descriptor_sha256'])
        writer.puts('close-protocol')
        writer.flush
        assert_nil(Timeout.timeout(5) { reader.gets }, 'managed protocol EOF reaches caller before cleanup')
        refute(writer.closed?, 'caller input remains open')
        wait_file(paths[:ended])
        assert_nil(Process.waitpid(pid, Process::WNOHANG), 'dispatcher still owns provider cleanup')
        [paths[:generation_lock], paths[:session_lock], File.join(binding.workspace, '.dev-clusters/.locks/kb-session.lock')].each do |path|
          File.open(path, 'r+') { |probe| refute(probe.flock(File::LOCK_EX | File::LOCK_NB), path) }
        end
        assert_raises(KbRuntime::Busy) { state.lock('gate', wait: false) { flunk('private lease gate released early') } }
        child = Integer(File.read(paths[:pid]))
        assert(File.exist?("/proc/#{child}"))
        received = JSON.parse(File.read(paths[:fds]))
        [paths[:generation_lock], paths[:session_lock], File.join(binding.workspace, '.dev-clusters/.locks/kb-session.lock')].each { |path| refute_includes(received, path) }
        [writer, reader].each { |stream| refute_includes(received, File.readlink("/proc/self/fd/#{stream.fileno}")) }
        File.write(paths[:release], '')
        _owned, status = Timeout.timeout(7) { Process.waitpid2(pid) }
        assert_equal(1, status.exitstatus)
        refute(File.exist?("/proc/#{child}"), 'fixed child was reaped')
        diagnostics.rewind
        assert_includes(diagnostics.read, 'KB lease protocol ended')
        state.lock('gate', wait: false) { assert(true) }
      end
    end
  end

  def test_public_stderr_eof_does_not_end_lease_and_peer_eof_releases_it
    with_dispatch do |_binding, state, _engine, _record, environment, paths|
      bytes, value = managed(environment)
      start_dispatch(environment, lease_flags(bytes, value)) do |pid, writer, reader, _diagnostics|
        assert_equal(Digest::SHA256.hexdigest(bytes), JSON.parse(Timeout.timeout(5) { reader.gets })['descriptor_sha256'])
        writer.puts('close-diagnostics')
        writer.flush
        assert_raises(KbRuntime::Busy) { state.lock('gate', wait: false) { flunk('live private lease released') } }
        refute(File.exist?(paths[:ended]))
        writer.close
        assert_equal('', Timeout.timeout(5) { reader.read })
        _owned, status = Timeout.timeout(7) { Process.waitpid2(pid) }
        assert(status.success?)
        assert_equal('owned input EOF', File.read(paths[:ended]))
        refute(File.exist?("/proc/#{Integer(File.read(paths[:pid]))}"))
      end
    end
  end

  def test_cleanup_inventory_runs_before_reset_without_reacquiring_generic_session_lock
    with_dispatch do |binding, state, _engine, record, environment, paths|
      File.open(paths[:session_lock], 'r+') do |owner|
        owner.flock(File::LOCK_EX)
        original = files(binding.state_root)
        output, error, status = Open3.capture3(environment, RbConfig.ruby, dispatcher,
          '--workspace', 'example', 'cleanup-paths', 'session', close_others: true)
        assert(status.success?, error)
        assert_equal([state.directory, binding.record_directory, record['socket_dir']].sort, JSON.parse(output)['paths'].sort)
        assert_equal(original, files(binding.state_root))
        refute(File.exist?(paths[:pid]), 'inventory never starts the live child')
      end
    end
  end

  def test_public_dispatcher_loss_ends_adapter_and_private_child_while_caller_input_stays_open
    with_dispatch do |binding, state, _engine, _record, environment, paths|
      bytes, value = managed(environment)
      start_dispatch(environment, lease_flags(bytes, value)) do |pid, writer, reader, _diagnostics|
        assert_equal(Digest::SHA256.hexdigest(bytes), JSON.parse(Timeout.timeout(5) { reader.gets })['descriptor_sha256'])
        children = KbRuntime::ProcessIdentity.children(pid)
        assert_equal(1, children.size, 'dispatcher owns exactly its selected adapter')
        adapter = KbRuntime::ProcessIdentity.read(children.first)
        child = KbRuntime::ProcessIdentity.read(Integer(File.read(paths[:pid])))
        refute_nil(adapter)
        refute_nil(child)
        assert_nil(Process.waitpid(pid, Process::WNOHANG), 'dispatcher remains an unreaped owned child')
        Process.kill('KILL', pid)
        _owned, status = Timeout.timeout(5) { Process.waitpid2(pid) }
        assert(status.signaled?)
        assert_nil(Timeout.timeout(5) { reader.gets }, 'caller sees dispatcher loss')
        refute(writer.closed?, 'original caller input remains open')
        wait_file(paths[:ended])
        Timeout.timeout(7) do
          sleep 0.02 until KbRuntime::ProcessIdentity.gone?(adapter) && KbRuntime::ProcessIdentity.gone?(child)
        end
        assert_equal('owned input EOF', File.read(paths[:ended]))
        [paths[:generation_lock], paths[:session_lock], File.join(binding.workspace, '.dev-clusters/.locks/kb-session.lock')].each do |path|
          File.open(path, 'r+') { |probe| assert(probe.flock(File::LOCK_EX | File::LOCK_NB), path) }
        end
        state.lock('gate', wait: false) { assert(true, 'private capture gate ends after kernel pipe loss') }
      end
    end
  end
end
