require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class DevclusterCommandsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  KINDS = %w[vpsadmin vpsadminos].freeze

  def test_failed_build_does_not_launch_or_deploy_an_old_result
    KINDS.product(%w[start update], [false, true]).each do |kind, command, retained|
      with_workspace(kind, retained:) do |env, directory|
        before = retained ? File.readlink(File.join(directory, 'result-config')) : nil
        result = run_helper(kind, env.merge('FAIL_AT' => 'build'), command)
        assert_equal(23, result.exitstatus, "#{kind} #{command}")
        assert_equal(['build'], events(env).map { |event| event.fetch('event') }.grep(/build|run|copy|activate|ssh/))
        refute(File.exist?(File.join(directory, 'ready')))
        if retained
          assert_equal(before, File.readlink(File.join(directory, 'result-config')))
        else
          refute(File.exist?(File.join(directory, 'result-config')))
        end
        assert_locks_released(env)
      end
    end
  end

  def test_credential_failures_stop_before_the_build
    KINDS.product(%w[start update]).each do |kind, command|
      failures = kind == 'vpsadmin' ? %w[keygen genrsa req x509] : %w[keygen]
      failures.each do |failure|
        with_workspace(kind) do |env, _directory|
          result = run_helper(kind, env.merge('FAIL_AT' => failure), command)
          assert_equal(23, result.exitstatus, "#{kind} #{command} #{failure}")
          refute(events(env).any? { |event| %w[build run copy activate ssh].include?(event['event']) })
          assert_locks_released(env)
        end
      end
    end
  end

  def test_failed_copy_or_activation_stops_the_remaining_update
    KINDS.product(%w[copy activate]).each do |kind, failure|
      with_workspace(kind) do |env, _directory|
        result = run_helper(kind, env.merge('FAIL_AT' => failure), 'update')
        assert_equal(23, result.exitstatus, "#{kind} #{failure}")
        calls = events(env).map { |event| event.fetch('event') }.grep(/build|copy|activate|ssh/)
        assert_equal(failure == 'copy' ? %w[build copy] : %w[build copy activate], calls)
        assert_locks_released(env)
      end
    end
  end

  def test_successful_start_keeps_build_environment_for_the_runner
    KINDS.each do |kind|
      with_workspace(kind) do |env, directory|
        result = run_helper(kind, env, 'start')
        assert(result.success?, "#{kind}: #{result.exitstatus}")
        build = events(env).find { |event| event['event'] == 'build' }
        runner = events(env).find { |event| event['event'] == 'run' }
        refute_nil(runner)
        assert_equal(build.fetch('environment'), runner.fetch('environment'))
        assert_equal('local', runner.fetch('environment').fetch("#{kind.upcase}_DEVCLUSTER_NETWORK"))
        assert_equal(File.join(directory, 'config.json'), runner.fetch('environment').fetch("#{kind.upcase}_DEVCLUSTER_CONFIG_FILE"))
        assert(File.exist?(File.join(directory, 'ready')))
        assert_locks_released(env)
      end
    end
  end

  def test_refresh_failure_is_not_reported_as_success
    %w[start update].each do |command|
      with_workspace('vpsadmin') do |env, _directory|
        result = run_helper('vpsadmin', env.merge('FAIL_AT' => 'ssh'), command)
        assert_equal(23, result.exitstatus)
        assert_equal(1, events(env).count { |event| event['event'] == 'ssh' })
        assert_locks_released(env)
      end
    end
  end

  def test_refresh_waits_for_node_ssh_before_running_remote_actions
    with_workspace('vpsadmin') do |env, _directory|
      result = run_helper('vpsadmin', env.merge('RETRY_NODE_SSH' => '1'), 'start')
      assert(result.success?, @last_output)
      assert_equal(4, events(env).count { |event| event['event'] == 'ssh-ready' })
      assert_equal(3, events(env).count { |event| event['event'] == 'ssh' })
      assert_locks_released(env)
    end
  end

  def test_stalled_ssh_probe_times_out_without_running_remote_actions
    with_workspace('vpsadmin') do |env, _directory|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run_helper('vpsadmin', env.merge('HANG_SSH_PROBE' => '1'), 'refresh')
      assert_equal(124, result.exitstatus)
      assert_operator(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15)
      assert_equal(1, events(env).count { |event| event['event'] == 'ssh-ready' })
      assert_equal(0, events(env).count { |event| event['event'] == 'ssh' })
      assert_locks_released(env)
    end
  end

  def test_node_refresh_waits_for_osctld_to_load_the_pool
    with_workspace('vpsadmin') do |env, _directory|
      remote_env = node_refresh_environment(env)
      result = run_helper('vpsadmin', env.merge(remote_env), 'refresh')
      assert(result.success?, @last_output)
      assert_equal(%w[pool-probe pool-probe pool-probe devices devices devices devices restart],
                   File.readlines(remote_env.fetch('TEST_REMOTE_EVENTS'), chomp: true))
      assert_locks_released(env)
    end
  end

  def test_node_refresh_does_not_mutate_an_unready_pool
    with_workspace('vpsadmin') do |env, _directory|
      remote_env = node_refresh_environment(env).merge('FAIL_POOL_WAIT' => '1')
      result = run_helper('vpsadmin', env.merge(remote_env), 'refresh')
      assert_equal(1, result.exitstatus)
      assert_includes(@last_output, 'not ready in ZFS and osctld')
      assert(File.readlines(remote_env.fetch('TEST_REMOTE_EVENTS'), chomp: true).all? { |event| event == 'pool-probe' })
      assert_equal(2, events(env).count { |event| event['event'] == 'ssh' })
      assert_locks_released(env)
    end
  end

  def test_invalid_retained_configuration_is_not_replaced
    KINDS.each do |kind|
      with_workspace(kind) do |env, directory|
        path = File.join(directory, 'config.json')
        File.write(path, '{broken')
        result = run_helper(kind, env, 'start')
        refute(result.success?)
        assert_equal('{broken', File.read(path))
        assert_empty(events(env))
      end
    end
  end

  def test_failed_readiness_cleanup_does_not_launch_or_accept_stale_readiness
    KINDS.each do |kind|
      with_workspace(kind) do |env, directory|
        File.write(File.join(directory, 'ready'), 'old readiness')
        result = run_helper(kind, env.merge('FAIL_AT' => 'cleanup'), 'start')
        assert_equal(23, result.exitstatus, @last_output)
        assert_equal('old readiness', File.read(File.join(directory, 'ready')))
        refute(events(env).any? { |event| %w[run ssh].include?(event['event']) })
        assert_locks_released(env)
      end
    end
  end

  private

  def with_workspace(kind, retained: false)
    Dir.mktmpdir('devcluster-commands') do |workspace|
      slug = '2026-09-11-command-test'
      directory = File.join(workspace, '.dev-clusters', kind, 'clusters', slug)
      FileUtils.mkdir_p(directory)
      prefix = kind == 'vpsadmin' ? 'vpsfree' : 'vpsadminos'
      digest = Digest::SHA256.hexdigest("#{File.realpath(workspace)}\0#{slug}")[0, 12]
      socket = "/tmp/#{prefix}-devcluster-#{digest}"
      File.write(File.join(directory, 'socket-dir'), "#{socket}\n")
      File.write(File.join(directory, 'network'), "local\n")
      File.write(File.join(directory, 'topology'), "dual\n")
      tracking = File.join(workspace, 'work', slug)
      FileUtils.mkdir_p(tracking)
      File.write(File.join(tracking, 'state.md'), "---\nlifecycle: active\n---\n")
      %w[vpsadmin vpsadminos].each { |project| FileUtils.mkdir_p(File.join(workspace, 'worktrees', slug, project)) }
      config = File.join(ROOT, 'test', 'fixtures', "#{kind}-config.json")
      machines = %w[services node1 node2].to_h { |name| [name, { 'toplevel' => "/fixture/#{name}" }] }
      File.write(File.join(workspace, 'built.json'), JSON.generate('machines' => machines))
      File.symlink(File.join(workspace, 'built.json'), File.join(directory, 'result-config')) if retained
      bin = File.join(workspace, 'bin')
      FileUtils.mkdir_p(bin)
      %w[nix ssh ssh-keygen openssl git rm].each do |name|
        path = File.join(bin, name)
        File.write(path, "#!#{RbConfig.ruby}\n" + command_stub)
        File.chmod(0o755, path)
      end
      env = {
        'DEVCLUSTER_WORKSPACE' => workspace,
        'TEST_SLUG' => slug,
        'TEST_KIND' => kind,
        'TEST_CONFIG' => config,
        'TEST_EVENTS' => File.join(workspace, 'events.jsonl'),
        'TEST_REAL_RM' => ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'rm') }.find { |path| File.executable?(path) },
        'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
        "#{kind.upcase}_DEVCLUSTER_DEFAULT_CONFIG" => config
      }
      yield env, directory
    ensure
      FileUtils.rm_rf(socket) if socket
    end
  end

  def run_helper(kind, env, command)
    argv = [File.join(ROOT, 'dev-clusters', kind, 'bin', 'devcluster'), command, env.fetch('TEST_SLUG')]
    argv += %w[--network local --topology dual] if command == 'start'
    stdout, stderr, result = Open3.capture3(env, *argv)
    assert(result.exited?, stderr)
    @last_output = stdout + stderr
    result
  end

  def events(env)
    return [] unless File.exist?(env.fetch('TEST_EVENTS'))

    File.readlines(env.fetch('TEST_EVENTS')).map { |line| JSON.parse(line) }
  end

  def assert_locks_released(env)
    Dir.glob(File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'worktrees', '.locks', '*.lock')).each do |path|
      File.open(path) { |file| assert(file.flock(File::LOCK_EX | File::LOCK_NB), path) }
    end
  end

  def node_refresh_environment(env)
    directory = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'remote-bin')
    FileUtils.mkdir_p(directory)
    %w[zpool zfs mkdir osctl sv nodectl timeout].each do |name|
      path = File.join(directory, name)
      File.write(path, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
        command = File.basename($PROGRAM_NAME)
        def record(event)
          File.open(ENV.fetch('TEST_REMOTE_EVENTS'), 'a') { |f| f.puts(event) }
        end
        case command
        when 'timeout'
          abort 'unexpected pool timeout' unless ARGV[0, 2] == ['--kill-after=1', '180']
          ARGV[1] = '2.5' if ENV['FAIL_POOL_WAIT'] == '1'
          exec ENV.fetch('TEST_REAL_TIMEOUT'), *ARGV
        when 'osctl'
          if ARGV[0, 2] == %w[pool show]
            record('pool-probe')
            path = ENV.fetch('TEST_POOL_PROBES')
            count = File.exist?(path) ? File.read(path).to_i + 1 : 1
            File.write(path, count.to_s)
            exit 1 if count == 1 || ENV['FAIL_POOL_WAIT'] == '1'
            puts(count == 2 ? 'importing' : 'active')
          else
            record('devices')
            abort 'pool mutation before readiness' if File.read(ENV.fetch('TEST_POOL_PROBES')).to_i < 3
          end
        when 'sv'
          record('restart') if ARGV.first == 'restart'
        when 'nodectl'
          puts 'State: running'
        when 'mkdir', 'zfs'
          abort 'filesystem mutation before readiness' if File.read(ENV.fetch('TEST_POOL_PROBES')).to_i < 3
        end
      RUBY
      File.chmod(0o755, path)
    end
    {
      'RUN_NODE_REFRESH' => '1',
      'TEST_REMOTE_BIN' => directory,
      'TEST_REMOTE_EVENTS' => File.join(directory, 'events'),
      'TEST_POOL_PROBES' => File.join(directory, 'probes'),
      'TEST_REAL_TIMEOUT' => ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'timeout') }.find { |path| File.executable?(path) }
    }
  end

  def command_stub
    <<~'RUBY'
      require 'json'
      require 'fileutils'
      command = File.basename($PROGRAM_NAME)
      if command == 'rm'
        if ENV['FAIL_AT'] == 'cleanup' && ARGV.any? { |arg| File.basename(arg) == 'ready' }
          exit 23
        end
        exec ENV.fetch('TEST_REAL_RM'), *ARGV
      end
      event = case command
              when 'nix' then ARGV.first
              when 'ssh-keygen' then 'keygen'
              when 'ssh'
                if ARGV.any? { |arg| arg.include?('switch-to-configuration') }
                  'activate'
                elsif ARGV.last == 'true'
                  'ssh-ready'
                else
                  'ssh'
                end
              when 'openssl' then ARGV.first
              else command
              end
      if command == 'git'
        puts '1111111111111111111111111111111111111111' if ARGV.include?('rev-parse')
        exit 0
      end
      environment = ENV.select { |key, _| key.start_with?("#{ENV.fetch('TEST_KIND').upcase}_DEVCLUSTER_") }
      File.open(ENV.fetch('TEST_EVENTS'), 'a') { |file| file.puts(JSON.generate('event' => event, 'environment' => environment)) }
      exit 23 if ENV['FAIL_AT'] == event
      def value_after(option)
        index = ARGV.index(option)
        index && ARGV[index + 1]
      end
      case command
      when 'nix'
        case event
        when 'build'
          link = value_after('--out-link')
          FileUtils.rm_f(link)
          File.symlink(File.join(ENV.fetch('DEVCLUSTER_WORKSPACE'), 'built.json'), link)
        when 'run'
          File.write(value_after('--ready-file'), 'ready')
        end
      when 'ssh-keygen'
        File.write(value_after('-f'), 'fixture')
        File.write(value_after('-f') + '.pub', 'fixture')
      when 'openssl'
        if ARGV.include?('-ext')
          config = JSON.parse(File.read(ENV.fetch('TEST_CONFIG')))
          puts (config.fetch('domains').values + config.fetch('tmpDomains').values).map { |name| "DNS:#{name}" }.join(', ')
        elsif (output = value_after('-out'))
          File.write(output, 'fixture')
        end
      when 'ssh'
        if event == 'ssh-ready'
          exit 24 unless ARGV.include?('BatchMode=yes') && ARGV.include?('IdentitiesOnly=yes')
          sleep 60 if ENV['HANG_SSH_PROBE'] == '1'
        end
        if event == 'ssh-ready' && ENV['RETRY_NODE_SSH'] == '1' && value_after('-p') == '10122'
          marker = File.join(ENV.fetch('DEVCLUSTER_WORKSPACE'), 'ssh-ready-retried')
          unless File.exist?(marker)
            File.write(marker, 'retried')
            exit 255
          end
        end
        if ARGV.include?('sh')
          script = STDIN.read
          if ENV['RUN_NODE_REFRESH'] == '1' && value_after('-p') == '10122'
            require 'open3'
            script = <<~'SH' + script
              test() {
                if [ "$1" = -S ] && [ "$2" = /run/nodectl/nodectld.sock ]; then return 0; fi
                command test "$@"
              }
            SH
            output, errors, result = Open3.capture3(
              { 'PATH' => "#{ENV.fetch('TEST_REMOTE_BIN')}:#{ENV.fetch('PATH')}" },
              'sh', '-s', '--', 'tank/ct', stdin_data: script
            )
            print output
            warn errors unless errors.empty?
            exit result.exitstatus
          end
        end
      end
    RUBY
  end
end
