# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require 'stringio'
require 'rbconfig'
require_relative '../dev-clusters/kb/lib/lease'

class KbLeaseTest < Minitest::Test
  def teardown
    Array(@lease_threads).each do |thread|
      raise 'lease fixture did not finish owned-child cleanup' unless thread.join(7)
    end
  end

  def canonical
    { 'schema' => 1, 'instance_id' => 'instance', 'run_id' => 'run', 'artifact_id' => 'artifact',
      'artifact_sha256' => 'a' * 64, 'descriptor_sha256' => 'c' * 64 }
  end

  def with_engine(mode)
    Dir.mktmpdir('kb-lease-test-') do |directory|
      executable = File.join(directory, 'engine')
      pid_path = File.join(directory, 'pid')
      cleanup_path = File.join(directory, 'cleanup')
      release_path = File.join(directory, 'cleanup-release')
      fd_path = File.join(directory, 'fds.json')
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'json'
        File.write(#{pid_path.inspect}, Process.pid.to_s)
        File.write(#{fd_path.inspect}, JSON.generate(Dir.glob('/proc/self/fd/*').filter_map { |path| File.readlink(path) rescue nil }))
        readiness = #{canonical.inspect}
        mode = #{mode.inspect}
        if mode == 'stderr-eof'
          STDERR.reopen(File::NULL, 'w')
          STDERR.close
        end
        unless mode == 'before-eof'
          readiness['descriptor_sha256'] = 'wrong' if mode == 'wrong-digest'
          readiness['extra'] = true if mode == 'extra-field'
          STDOUT.write(mode == 'malformed' ? "{invalid}\n" : JSON.generate(readiness) + "\n")
          STDOUT.write("extra\n") if mode == 'extra-output'
          STDOUT.flush
        end
        if %w[before-eof ready-eof].include?(mode)
          STDOUT.reopen(File::NULL, 'w')
          STDOUT.close
        end
        STDIN.read
        File.write(#{cleanup_path.inspect}, 'input ended')
        sleep 0.01 until File.exist?(#{release_path.inspect}) if mode == 'ready-eof'
      RUBY
      File.chmod(0o755, executable)
      yield executable, pid_path, cleanup_path, fd_path, directory
    end
  end

  def pipes
    caller_input, peer_input = IO.pipe
    peer_output, caller_output = IO.pipe
    yield caller_input, peer_input, peer_output, caller_output
  ensure
    [caller_input, peer_input, peer_output, caller_output].compact.each { |stream| stream.close unless stream.closed? }
  end

  def start_lease(engine, input, output)
    result = Queue.new
    thread = Thread.new do
      lease = DevClusters::Kb::Lease.new(argv: [engine], canonical:, managed: 'm' * 64, input:, output:, error: StringIO.new)
      begin
        result << lease.run
      rescue StandardError => error
        result << error
      end
    end
    (@lease_threads ||= []) << thread
    [thread, result]
  end

  def wait_file(path)
    Timeout.timeout(5) { sleep 0.01 until File.exist?(path) }
  end

  def assert_child_gone(path)
    pid = Integer(File.read(path))
    refute(File.exist?("/proc/#{pid}"), "owned lease child #{pid} remains")
  end

  def test_translates_only_canonical_digest_and_releases_after_peer_eof
    with_engine('ready') do |engine, pid, cleanup, _fds, _directory|
      pipes do |input, peer_input, peer_output, output|
        thread, result = start_lease(engine, input, output)
        readiness = Timeout.timeout(5) { JSON.parse(peer_output.gets) }
        assert_equal(canonical.merge('descriptor_sha256' => 'm' * 64), readiness)
        refute(File.exist?(cleanup))
        peer_input.close
        Timeout.timeout(5) { thread.join }
        assert_equal(true, result.pop)
        assert_equal('', peer_output.read)
        assert_equal('input ended', File.read(cleanup))
        assert_child_gone(pid)
      end
    end
  end

  def test_rejects_malformed_extra_or_noncanonical_readiness_without_publishing
    %w[malformed extra-output extra-field wrong-digest].each do |mode|
      with_engine(mode) do |engine, pid, _cleanup, _fds, _directory|
        pipes do |input, _peer_input, peer_output, output|
          thread, result = start_lease(engine, input, output)
          assert_equal('', Timeout.timeout(5) { peer_output.read }, mode)
          Timeout.timeout(5) { thread.join }
          assert_instance_of(DevClusters::Kb::Error, result.pop, mode)
          assert_child_gone(pid)
        end
      end
    end
  end

  def test_stdout_eof_before_readiness_leaves_no_managed_lease_or_child
    with_engine('before-eof') do |engine, pid, cleanup, _fds, _directory|
      pipes do |input, _peer_input, peer_output, output|
        thread, result = start_lease(engine, input, output)
        assert_equal('', Timeout.timeout(5) { peer_output.read })
        Timeout.timeout(5) { thread.join }
        assert_instance_of(DevClusters::Kb::Error, result.pop)
        assert_equal('input ended', File.read(cleanup))
        assert_child_gone(pid)
      end
    end
  end

  def test_ready_stdout_eof_closes_protocol_before_child_cleanup_and_retains_guard
    with_engine('ready-eof') do |engine, pid, cleanup, _fds, directory|
      guard_path = File.join(directory, 'guard')
      File.open(guard_path, 'w') {}
      pipes do |input, _peer_input, peer_output, output|
        result = Queue.new
        thread = Thread.new do
          File.open(guard_path, 'r+') do |guard|
            guard.flock(File::LOCK_EX)
            lease = DevClusters::Kb::Lease.new(argv: [engine], canonical:, managed: 'm' * 64, input:, output:, error: StringIO.new)
            begin
              result << lease.run
            rescue StandardError => error
              result << error
            end
          end
        end
        (@lease_threads ||= []) << thread
        bytes = Timeout.timeout(5) { peer_output.read }
        assert(bytes.empty? || JSON.parse(bytes) == canonical.merge('descriptor_sha256' => 'm' * 64))
        wait_file(cleanup)
        assert(File.exist?("/proc/#{Integer(File.read(pid))}"))
        File.open(guard_path, 'r+') { |guard| refute(guard.flock(File::LOCK_EX | File::LOCK_NB)) }
        File.write(File.join(directory, 'cleanup-release'), '')
        Timeout.timeout(5) { thread.join }
        assert_instance_of(DevClusters::Kb::Error, result.pop)
        assert_child_gone(pid)
        File.open(guard_path, 'r+') { |guard| assert(guard.flock(File::LOCK_EX | File::LOCK_NB)) }
      end
    end
  end

  def test_stderr_eof_alone_keeps_the_lease_usable
    with_engine('stderr-eof') do |engine, pid, cleanup, _fds, _directory|
      pipes do |input, peer_input, peer_output, output|
        thread, result = start_lease(engine, input, output)
        assert_equal('m' * 64, Timeout.timeout(5) { JSON.parse(peer_output.gets).fetch('descriptor_sha256') })
        peer_input.write('peer remains live')
        peer_input.flush
        sleep 0.05
        assert(thread.alive?)
        refute(File.exist?(cleanup))
        peer_input.close
        Timeout.timeout(5) { thread.join }
        assert_equal(true, result.pop)
        assert_child_gone(pid)
      end
    end
  end

  def test_child_receives_mediated_pipes_without_peer_or_guard_descriptors
    with_engine('ready') do |engine, pid, _cleanup, fds, directory|
      guard_path = File.join(directory, 'generation-guard')
      File.open(guard_path, 'w') {}
      File.open(guard_path, 'r+') do |guard|
        guard.close_on_exec = false
        pipes do |input, peer_input, peer_output, output|
          input.close_on_exec = false
          output.close_on_exec = false
          original = [input, output].map { |stream| File.readlink("/proc/self/fd/#{stream.fileno}") }
          thread, result = start_lease(engine, input, output)
          Timeout.timeout(5) { peer_output.gets }
          inherited = JSON.parse(File.read(fds))
          refute_includes(inherited, guard_path)
          original.each { |target| refute_includes(inherited, target) }
          peer_input.close
          Timeout.timeout(5) { thread.join }
          assert_equal(true, result.pop)
          assert_child_gone(pid)
        end
      end
    end
  end

  def test_default_stdout_subprocess_detaches_the_real_protocol_pipe
    with_engine('ready-eof') do |engine, pid, cleanup, _fds, directory|
      program = <<~RUBY
        require #{File.expand_path('../dev-clusters/kb/lib/lease', __dir__).inspect}
        begin
          DevClusters::Kb::Lease.new(argv: [ARGV.fetch(0)], canonical: #{canonical.inspect}, managed: #{('m' * 64).inspect}).run
        rescue DevClusters::Kb::Error
          exit 1
        end
      RUBY
      child_input, peer_input = IO.pipe
      peer_output, child_output = IO.pipe
      adapter = Process.spawn(RbConfig.ruby, '-e', program, engine, in: child_input, out: child_output, err: File::NULL, close_others: true)
      child_input.close
      child_output.close
      Timeout.timeout(5) { peer_output.read }
      wait_file(cleanup)
      assert(File.exist?("/proc/#{Integer(File.read(pid))}"))
      File.write(File.join(directory, 'cleanup-release'), '')
      _owned, status = Timeout.timeout(5) { Process.waitpid2(adapter) }
      adapter = nil
      assert_equal(1, status.exitstatus)
      assert_child_gone(pid)
    ensure
      [child_input, peer_input, peer_output, child_output].compact.each { |stream| stream.close unless stream.closed? }
      if adapter
        Process.kill('KILL', adapter)
        Process.waitpid(adapter)
      end
    end
  end

  def test_abrupt_adapter_loss_ends_child_input_without_inheriting_caller_input
    with_engine('ready') do |engine, pid, cleanup, _fds, _directory|
      program = <<~RUBY
        require #{File.expand_path('../dev-clusters/kb/lib/lease', __dir__).inspect}
        DevClusters::Kb::Lease.new(argv: [ARGV.fetch(0)], canonical: #{canonical.inspect}, managed: #{('m' * 64).inspect}).run
      RUBY
      child_input, peer_input = IO.pipe
      peer_output, child_output = IO.pipe
      adapter = Process.spawn(RbConfig.ruby, '-e', program, engine, in: child_input, out: child_output, err: File::NULL, close_others: true)
      child_input.close
      child_output.close
      Timeout.timeout(5) { peer_output.gets }
      Process.kill('KILL', adapter)
      Process.waitpid(adapter)
      adapter = nil
      assert_equal('', Timeout.timeout(5) { peer_output.read })
      wait_file(cleanup)
      Timeout.timeout(5) do
        until process_exited?(Integer(File.read(pid)))
          sleep 0.02
        end
      end
      assert_equal('input ended', File.read(cleanup))
    ensure
      [child_input, peer_input, peer_output, child_output].compact.each { |stream| stream.close unless stream.closed? }
      if adapter
        Process.kill('KILL', adapter)
        Process.waitpid(adapter)
      end
    end
  end

  def process_exited?(pid)
    # Kernel EOF must finish the orphan even before its new parent reaps it.
    File.read("/proc/#{pid}/stat").split[2] == 'Z'
  rescue Errno::ENOENT
    true
  end
end
