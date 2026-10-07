# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require 'stringio'
require 'rbconfig'
require_relative '../dev-clusters/kb/lib/cli'

# CLI/session/adapter/fixed-child composition. The portable snapshot fixture is
# explicit; actual selected K reader behavior is covered by kb_portable_test.
class KbCliTest < Minitest::Test
  class Snapshot
    attr_reader :revision, :canonical_bytes

    def initialize(binding, guards, descriptor)
      @binding, @guards = binding, guards
      @revision = 'b' * 40
      @canonical_bytes = JSON.generate(descriptor) + "\n"
    end

    def canonical
      @binding.read
      [canonical_bytes, JSON.parse(canonical_bytes)]
    end

    def inventory
      @binding.read
      @guards.adapter { raise 'recursive adapter lock reached' }
    rescue DevClusters::Kb::Busy
      { 'schema' => 1, 'paths' => [@binding.cluster_directory, @binding.record_directory] }
    end

    def transition_adopt
      @binding.read
      true
    end
  end

  def with_cli
    Dir.mktmpdir('kb-public-cli-') do |workspace|
      slug = 'session'
      binding = DevClusters::Kb::Binding.new(workspace:, slug:)
      FileUtils.mkdir_p(File.join(workspace, 'work', slug))
      File.write(File.join(workspace, 'work', slug, 'state.md'), "---\nlifecycle: active\n---\n")
      locks = File.join(workspace, 'worktrees', '.locks')
      FileUtils.mkdir_p(locks)
      lock = File.join(locks, slug + '.lock')
      File.open(lock, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      log = File.join(workspace, 'engine-commands.jsonl')
      descriptor = { 'schema' => 1, 'kind' => 'vpsfree-kb-connection', 'instance_id' => SecureRandom.uuid,
        'run_id' => SecureRandom.uuid, 'artifact_id' => SecureRandom.uuid, 'artifact_sha256' => 'a' * 64,
        'services' => {}, 'control' => { 'argv' => ['/selected/portable-engine', 'capture-lease', slug] } }
      canonical_sha = Digest::SHA256.hexdigest(JSON.generate(descriptor) + "\n")
      engine = File.join(workspace, 'fixed-engine')
      File.write(engine, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'json'
        File.open(#{log.inspect}, 'a') { |file| file.puts(JSON.generate(ARGV)) }
        root, command, slug = ARGV[1, 3]
        cluster = File.join(root, 'clusters', slug)
        case command
        when 'start'
          Dir.mkdir(File.join(root, 'clusters'), 0700) unless File.directory?(File.join(root, 'clusters'))
          Dir.mkdir(cluster, 0700)
          print "started\n"
        when 'status'
          puts JSON.generate('schema' => 2, 'found' => true, 'state' => 'stopped', 'ready' => false)
        when 'capture-lease'
          options = ARGV.drop(4).each_slice(2).to_h
          abort 'wrong canonical digest' unless options['--descriptor-sha256'] == #{canonical_sha.inspect}
          identity = #{descriptor.slice(*DevClusters::Kb::Connection::IDENTITY_FIELDS).inspect}
          puts JSON.generate(identity.merge('schema' => 1, 'descriptor_sha256' => #{canonical_sha.inspect}))
          STDOUT.flush
          STDIN.read
        when 'reset'
          Dir.rmdir(cluster)
        else
          print command + "\n"
        end
      RUBY
      File.chmod(0o755, engine)
      environment = { 'DEVCLUSTER_WORKSPACE' => workspace, 'DEV_WORKSPACE_NAME' => 'example',
        'HOME' => workspace, 'XDG_RUNTIME_DIR' => File.join(workspace, 'runtime'),
        'DEVCLUSTER_RUNTIME_CONTRACT' => ENV.fetch('DEVCLUSTER_RUNTIME_CONTRACT'),
        'VPSFREE_KB_ENGINE_METADATA' => '/selected/metadata', 'VPSFREE_KB_ENGINE' => engine,
        'VPSFREE_KB_DEFAULT_CONFIG' => '/selected/default-config.json' }
      guards = DevClusters::Kb::Guards.new(binding:, contract: JSON.parse(File.read(environment['DEVCLUSTER_RUNTIME_CONTRACT'])), environment:)
      snapshot = Snapshot.new(binding, guards, descriptor)
      DevClusters::Kb::Portable.stub(:new, snapshot) do
        yield binding, guards, snapshot, environment, log, lock
      end
    end
  end

  def run_cli(environment, *argv)
    output, error = StringIO.new, StringIO.new
    result = DevClusters::Kb::CLI.run(argv, environment:, output:, error:)
    [result, output.string, error.string]
  end

  def commands(path)
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def test_help_and_absent_inventory_status_do_not_initialize_state
    output = StringIO.new
    assert_equal(0, DevClusters::Kb::CLI.run(['--help'], environment: {}, output:))
    assert_match(/^Usage:/, output.string)
    with_cli do |binding, _guards, _snapshot, environment, log, _lock|
      %w[status cleanup-paths].each do |command|
        result, output, error = run_cli(environment, command, 'session')
        assert_equal(0, result, error)
        value = JSON.parse(output)
        assert_equal(command == 'status' ? false : [], value.fetch(command == 'status' ? 'found' : 'paths'))
        refute(File.exist?(binding.state_root))
      end
      assert_empty(commands(log))
    end
  end

  def test_start_binds_creation_provenance_and_forwards_only_scoped_options_to_fixed_cli
    with_cli do |binding, _guards, snapshot, environment, log, _lock|
      result, output, error = run_cli(environment, 'start', 'session', '--network', 'local', '--topology', 'single')
      assert_equal(0, result, error)
      assert_equal("started\n", output)
      assert_equal(snapshot.revision, binding.read['engine_revision'])
      assert_equal(['--state-root', binding.state_root, 'start', 'session', '--network', 'local', '--topology', 'single', '--config', '/selected/default-config.json'], commands(log).last)
      %w[--state-root --software-metadata --workspace].each do |flag|
        count = commands(log).size
        assert_equal(1, run_cli(environment, 'update', 'session', flag, '/unselected').first)
        assert_equal(count, commands(log).size)
      end
      result, _output, error = run_cli(environment, 'update', 'session', '--config', '/explicit/config.json', '--timeout', '90')
      assert_equal(0, result, error)
      assert_equal(['--state-root', binding.state_root, 'update', 'session', '--config', '/explicit/config.json', '--timeout', '90'], commands(log).last)
    end
  end

  def test_inventory_precedes_reset_without_recursive_session_lock_and_keeps_creation_binding
    with_cli do |binding, _guards, _snapshot, environment, log, lock|
      assert_equal(0, run_cli(environment, 'start', 'session').first)
      original = File.binread(binding.path)
      File.open(lock, 'r+') do |owner|
        owner.flock(File::LOCK_EX)
        result, output, error = run_cli(environment, 'cleanup-paths', 'session')
        assert_equal(0, result, error)
        assert_equal([binding.cluster_directory, binding.record_directory], JSON.parse(output)['paths'])
        assert_equal(original, File.binread(binding.path))
        assert_equal(['start'], commands(log).map { |argv| argv[2] })
        lifecycle = environment.merge('DEV_SESSION_LIFECYCLE_OPERATION' => 'removal',
          'DEV_SESSION_LIFECYCLE_LOCK_FD' => owner.fileno.to_s, 'DEV_SESSION_LIFECYCLE_LOCK_PATH' => lock)
        journal = File.join(binding.workspace, 'worktrees', '.locks', 'session.removal.json')
        File.open(journal, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write('{}') }
        assert_equal(0, run_cli(lifecycle, 'reset', 'session').first)
        refute(File.exist?(binding.cluster_directory))
        refute(File.exist?(binding.record_directory))
        assert_equal(%w[start stop reset], commands(log).map { |argv| argv[2] })
      end
    end
  end

  def test_session_mutation_and_pending_lifecycle_refuse_before_engine_invocation
    with_cli do |binding, _guards, _snapshot, environment, log, lock|
      File.open(lock, 'r+') do |owner|
        owner.flock(File::LOCK_EX)
        assert_equal(75, run_cli(environment, 'start', 'session').first)
      end
      journal = File.join(binding.workspace, 'worktrees', '.locks', 'session.archive.json')
      File.open(journal, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write('{}') }
      assert_equal(1, run_cli(environment, 'start', 'session').first)
      assert_empty(commands(log))
      refute(File.exist?(binding.path))
    end
  end

  def test_public_managed_connection_and_full_lease_translate_only_current_digest
    with_cli do |binding, _guards, snapshot, environment, log, _lock|
      assert_equal(0, run_cli(environment, 'start', 'session').first)
      result, bytes, error = run_cli(environment, 'connection', 'session')
      assert_equal(0, result, error)
      value = JSON.parse(bytes)
      assert_equal([File.join(binding.workspace, 'bin/kb-devcluster'), '--workspace', 'example', 'capture-lease', 'session'], value['control']['argv'])
      assert_equal(JSON.parse(snapshot.canonical_bytes).reject { |k, _v| k == 'control' }, value.reject { |k, _v| k == 'control' })
      assert_equal(bytes, File.binread(File.join(binding.record_directory, 'connection.json')))
      request = value.slice(*DevClusters::Kb::Connection::IDENTITY_FIELDS).merge('descriptor_sha256' => Digest::SHA256.hexdigest(bytes))
      caller_input, peer_input = IO.pipe
      peer_output, caller_output = IO.pipe
      errors = StringIO.new
      flags = request.flat_map { |key, entry| ["--#{key.tr('_', '-')}", entry] }
      thread = Thread.new { DevClusters::Kb::CLI.run(['capture-lease', 'session', *flags], environment:, input: caller_input, output: caller_output, error: errors) }
      readiness = JSON.parse(Timeout.timeout(5) { peer_output.gets })
      assert_equal(request.merge('schema' => 1), readiness)
      refute_equal(Digest::SHA256.hexdigest(snapshot.canonical_bytes), readiness['descriptor_sha256'])
      assert(thread.alive?)
      peer_input.close
      assert_equal(0, Timeout.timeout(7) { thread.value }, errors.string)
      assert_equal('', peer_output.read)
      assert_equal(Digest::SHA256.hexdigest(snapshot.canonical_bytes), commands(log).last.last)
      assert_equal(1, run_cli(environment, 'capture-lease', 'session', *flags.map { |entry| entry == request['descriptor_sha256'] ? 'stale' : entry }).first)
      assert_equal(1, commands(log).count { |argv| argv[2] == 'capture-lease' })
    ensure
      [caller_input, peer_input, peer_output, caller_output].compact.each { |stream| stream.close unless stream.closed? }
      raise 'CLI lease thread did not reap its fixed child' if thread && !thread.join(7)
    end
  end
end
