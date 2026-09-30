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

  def test_react_webui_credentials_are_stable_and_source_is_recorded
    with_workspace('vpsadmin') do |env, directory|
      env = enable_react_webui(env, directory)
      File.write(File.join(directory, 'network'), "bridge\n")
      FileUtils.mkdir_p(File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'worktrees', env.fetch('TEST_SLUG'), 'vpsadmin-webui'))
      first = run_helper('vpsadmin', env, 'update', 'services')
      assert(first.success?, @last_output)
      bundle = File.join(directory, 'webui-credentials')
      assert_equal(0o700, File.stat(bundle).mode & 0o777)
      values = %w[oauth-client-id oauth-client-secret session-secret].to_h do |name|
        path = File.join(bundle, name)
        assert_equal(0o600, File.stat(path).mode & 0o777)
        [name, File.binread(path)]
      end
      selected = JSON.parse(File.read(File.realpath(File.join(directory, 'result-config'))))
      assert_equal({
        'webuiSourceKind' => 'worktree',
        'webuiSourceRevision' => '1111111111111111111111111111111111111111',
        'webuiSourceDirty' => 'false'
      }, selected.fetch('labels'))
      refute(File.exist?(File.join(directory, 'webui-source.json')))
      build = events(env).find { |event| event['event'] == 'build' }
      assert_includes(build.fetch('argv'), '--override-input')
      assert_includes(build.fetch('argv'), 'vpsadminWebui')
      assert_equal(bundle, build.fetch('environment').fetch('VPSADMIN_DEVCLUSTER_WEBUI_CREDENTIALS_DIR'))
      assert_equal('worktree', build.fetch('environment').fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_SOURCE_KIND'))

      second = run_helper('vpsadmin', env, 'update', 'services')
      assert(second.success?, @last_output)
      values.each { |name, value| assert_equal(value, File.binread(File.join(bundle, name))) }
      assert_empty(Dir.glob(File.join(directory, '.webui-credentials.*')))
    end
  end

  def test_post_publication_failure_keeps_one_selected_result_without_deployment
    [false, true].product(%w[start update]).each do |retained, command|
      with_workspace('vpsadmin', retained:) do |env, directory|
        env = enable_react_webui(env, directory)
        File.write(File.join(directory, 'network'), "bridge\n")
        env['TEST_START_NETWORK'] = 'bridge'
        if retained && command == 'update'
          source = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'worktrees', env.fetch('TEST_SLUG'), 'vpsadmin-webui')
          FileUtils.mkdir_p(source)
          env['TEST_GIT_DIRTY'] = '1'
        end
        before = retained ? File.readlink(File.join(directory, 'result-config')) : nil

        target = command == 'update' ? 'services' : nil
        result = run_helper('vpsadmin', env.merge('FAIL_AFTER_LINK' => '1'), command, target)
        assert_equal(23, result.exitstatus, @last_output)
        selected = File.readlink(File.join(directory, 'result-config'))
        refute_equal(before, selected)
        expected_kind = env['TEST_GIT_DIRTY'] == '1' ? 'worktree' : 'pinned'
        labels = JSON.parse(File.read(selected)).fetch('labels')
        assert_equal(expected_kind, labels.fetch('webuiSourceKind'))
        assert_equal(env['TEST_GIT_DIRTY'] == '1' ? 'true' : 'false', labels.fetch('webuiSourceDirty'))
        assert_equal(['build'], events(env).map { |event| event.fetch('event') }.grep(/build|run|copy|activate|ssh/))
        status = read_vpsadmin_status(env)
        expected_revision = expected_kind == 'worktree' ? '1' * 40 : '534caa83a5f97d2b40b4a126886649b14dc9e8d3'
        assert_equal({ 'revision' => expected_revision,
                       'dirty' => env['TEST_GIT_DIRTY'] == '1', 'kind' => expected_kind }, status.fetch('webuiSource'))
      end
    end
  end

  def test_post_build_result_parse_failure_stops_before_deployment
    %w[TEST_INVALID_RESULT TEST_PARTIAL_LABELS].each do |failure|
      with_workspace('vpsadmin') do |env, directory|
        env = enable_react_webui(env, directory)
        File.write(File.join(directory, 'network'), "bridge\n")
        result = run_helper('vpsadmin', env.merge(failure => '1'), 'update', 'services')
        refute(result.success?)
        assert(File.symlink?(File.join(directory, 'result-config')))
        assert_equal(['build'], events(env).map { |event| event.fetch('event') }.grep(/build|copy|activate|ssh/))
      end
    end
  end

  def test_disabled_post_publication_failure_has_no_source_labels
    with_workspace('vpsadmin') do |env, directory|
      result = run_helper('vpsadmin', env.merge('FAIL_AFTER_LINK' => '1'), 'update', 'services')
      assert_equal(23, result.exitstatus)
      selected = JSON.parse(File.read(File.realpath(File.join(directory, 'result-config'))))
      assert_equal({}, selected.fetch('labels'))
      status = read_vpsadmin_status(env)
      refute(status.key?('webuiSource'))
      assert_equal(['build'], events(env).map { |event| event.fetch('event') }.grep(/build|copy|activate|ssh/))
    end
  end

  def test_source_kind_and_dirty_state_come_from_the_selected_source
    with_workspace('vpsadmin') do |env, directory|
      env = enable_react_webui(env, directory)
      File.write(File.join(directory, 'network'), "bridge\n")
      source = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'worktrees', env.fetch('TEST_SLUG'), 'vpsadmin-webui')
      FileUtils.mkdir_p(source)
      env['TEST_GIT_DIRTY'] = '1'
      env['VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_SOURCE_KIND'] = 'pinned'
      result = run_helper('vpsadmin', env, 'update', 'services')
      assert(result.success?, @last_output)
      selected = JSON.parse(File.read(File.realpath(File.join(directory, 'result-config'))))
      assert_equal('worktree', selected.fetch('labels').fetch('webuiSourceKind'))
      assert_equal('true', selected.fetch('labels').fetch('webuiSourceDirty'))
      refute(File.exist?(File.join(directory, 'webui-source.json')))
    end
  end

  def test_source_inspection_failure_stops_before_build
    with_workspace('vpsadmin') do |env, directory|
      env = enable_react_webui(env, directory)
      File.write(File.join(directory, 'network'), "bridge\n")
      source = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'worktrees', env.fetch('TEST_SLUG'), 'vpsadmin-webui')
      FileUtils.mkdir_p(source)
      result = run_helper('vpsadmin', env.merge('FAIL_GIT_STATUS' => '1'), 'update', 'services')
      refute(result.success?)
      refute(events(env).any? { |event| event['event'] == 'build' })
    end
  end

  def test_react_webui_rejects_invalid_bundles_before_build
    %w[missing malformed permissions symlink foreign].each do |failure|
      with_workspace('vpsadmin') do |env, directory|
        env = enable_react_webui(env, directory)
        File.write(File.join(directory, 'network'), "bridge\n")
        bundle = File.join(directory, 'webui-credentials')
        FileUtils.mkdir_p(bundle)
        File.chmod(0o700, bundle)
        %w[oauth-client-id oauth-client-secret session-secret].each do |name|
          path = File.join(bundle, name)
          File.write(path, "#{'a' * 64}\n")
          File.chmod(0o600, path)
        end
        case failure
        when 'missing' then File.delete(File.join(bundle, 'session-secret'))
        when 'malformed' then File.write(File.join(bundle, 'session-secret'), "bad\n")
        when 'permissions' then File.chmod(0o644, File.join(bundle, 'session-secret'))
        when 'symlink'
          File.delete(File.join(bundle, 'session-secret'))
          File.symlink(File.join(bundle, 'oauth-client-secret'), File.join(bundle, 'session-secret'))
        when 'foreign' then File.write(File.join(bundle, 'unexpected'), 'foreign')
        end
        result = run_helper('vpsadmin', env, 'update', 'services')
        refute(result.success?, failure)
        refute(events(env).any? { |event| event['event'] == 'build' }, failure)
        refute(File.exist?(File.join(directory, 'webui-source.json')))
      end
    end
  end

  def test_react_webui_rejects_local_mode_before_credential_generation
    with_workspace('vpsadmin') do |env, directory|
      env = enable_react_webui(env, directory)
      result = run_helper('vpsadmin', env, 'start')
      refute(result.success?)
      assert_includes(@last_output, 'requires bridge networking')
      refute(File.exist?(File.join(directory, 'webui-credentials')))
      assert_empty(events(env))
    end
  end

  def test_react_webui_random_generation_failure_removes_temporary_bundle
    with_workspace('vpsadmin') do |env, directory|
      env = enable_react_webui(env, directory)
      File.write(File.join(directory, 'network'), "bridge\n")
      result = run_helper('vpsadmin', env.merge('FAIL_AT' => 'rand'), 'update', 'services')
      assert_equal(1, result.exitstatus)
      refute(File.exist?(File.join(directory, 'webui-credentials')))
      assert_empty(Dir.glob(File.join(directory, '.webui-credentials.*')))
      refute(events(env).any? { |event| event['event'] == 'build' })
    end
  end

  def test_react_webui_rejects_invalid_or_duplicate_domain_before_certificates
    ['bad/host.example.test', 'api.devhost.int.vpsfree.cz'].each do |domain|
      with_workspace('vpsadmin') do |env, directory|
        env = enable_react_webui(env, directory)
        config_path = File.join(directory, 'config.json')
        config = JSON.parse(File.read(config_path))
        config.fetch('domains')['newadmin'] = domain
        File.write(config_path, JSON.generate(config))
        File.write(File.join(directory, 'network'), "bridge\n")
        result = run_helper('vpsadmin', env, 'update', 'services')
        refute(result.success?)
        assert_includes(@last_output, 'distinct valid domains.newadmin')
        refute(File.exist?(File.join(directory, 'webui-credentials')))
        assert_empty(events(env))
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
        stale_source = File.join(directory, 'webui-source.json')
        File.write(stale_source, '{invalid') if kind == 'vpsadmin'
        result = run_helper(kind, env, 'start')
        assert(result.success?, "#{kind}: #{result.exitstatus}")
        build = events(env).find { |event| event['event'] == 'build' }
        runner = events(env).find { |event| event['event'] == 'run' }
        refute_nil(runner)
        assert_equal(build.fetch('environment'), runner.fetch('environment'))
        assert_equal('local', runner.fetch('environment').fetch("#{kind.upcase}_DEVCLUSTER_NETWORK"))
        assert_equal(File.join(directory, 'config.json'), runner.fetch('environment').fetch("#{kind.upcase}_DEVCLUSTER_CONFIG_FILE"))
        assert(File.exist?(File.join(directory, 'ready')))
        assert_equal('{invalid', File.read(stale_source)) if kind == 'vpsadmin'
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

  def enable_react_webui(env, directory)
    config = JSON.parse(File.read(env.fetch('TEST_CONFIG')))
    config['newWebui'] = { 'enable' => true }
    config.fetch('domains')['newadmin'] = 'newadmin.example.test'
    path = File.join(directory, 'config.json')
    File.write(path, JSON.generate(config))
    env.merge('TEST_CONFIG' => path)
  end

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
      %w[nix ssh ssh-keygen openssl git rm jq mktemp mv].each do |name|
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
        'TEST_REAL_JQ' => ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'jq') }.find { |path| File.executable?(path) },
        'TEST_REAL_MKTEMP' => ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'mktemp') }.find { |path| File.executable?(path) },
        'TEST_REAL_MV' => ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'mv') }.find { |path| File.executable?(path) },
        'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
        "#{kind.upcase}_DEVCLUSTER_DEFAULT_CONFIG" => config
      }
      yield env, directory
    ensure
      FileUtils.rm_rf(socket) if socket
    end
  end

  def run_helper(kind, env, command, target = nil)
    argv = [File.join(ROOT, 'dev-clusters', kind, 'bin', 'devcluster'), command, env.fetch('TEST_SLUG')]
    argv << target if target
    argv += ['--network', env.fetch('TEST_START_NETWORK', 'local'), '--topology', 'dual'] if command == 'start'
    stdout, stderr, result = Open3.capture3(env, *argv)
    assert(result.exited?, stderr)
    @last_output = stdout + stderr
    result
  end

  def read_vpsadmin_status(env)
    stdout, stderr, result = Open3.capture3(
      env, File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'),
      'status', env.fetch('TEST_SLUG'), '--json'
    )
    assert(result.success?, stderr)
    JSON.parse(stdout)
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
      if command == 'jq'
        abort 'obsolete source metadata jq write' if ARGV.include?('-n') && ARGV.include?('revision')
        exec ENV.fetch('TEST_REAL_JQ'), *ARGV
      end
      if command == 'mktemp'
        abort 'obsolete source metadata temporary file' if ARGV.any? { |arg| arg.include?('.webui-source.') }
        exec ENV.fetch('TEST_REAL_MKTEMP'), *ARGV
      end
      if command == 'mv'
        abort 'obsolete source metadata replacement' if ARGV.any? { |arg| arg.include?('webui-source.json') || arg.include?('.webui-source.') }
        exec ENV.fetch('TEST_REAL_MV'), *ARGV
      end
      if command == 'rm'
        abort 'obsolete source metadata removal' if ARGV.any? { |arg| arg.include?('webui-source.json') }
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
        if ENV['FAIL_GIT_STATUS'] == '1' && ARGV.include?('status') &&
           ARGV.any? { |arg| arg.end_with?('/vpsadmin-webui') }
          exit 23
        end
        puts ' M changed' if ENV['TEST_GIT_DIRTY'] == '1' && ARGV.include?('status')
        puts '1111111111111111111111111111111111111111' if ARGV.include?('rev-parse')
        exit 0
      end
      environment = ENV.select { |key, _| key.start_with?("#{ENV.fetch('TEST_KIND').upcase}_DEVCLUSTER_") }
      File.open(ENV.fetch('TEST_EVENTS'), 'a') { |file| file.puts(JSON.generate('event' => event, 'environment' => environment, 'argv' => ARGV)) }
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
          workspace = ENV.fetch('DEVCLUSTER_WORKSPACE')
          config = JSON.parse(File.read(ENV.fetch('TEST_CONFIG')))
          machines = %w[services node1 node2].to_h { |name| [name, { 'toplevel' => "/fixture/#{name}" }] }
          labels = if config.dig('newWebui', 'enable') == true
                     { 'webuiSourceRevision' => environment.fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_REVISION'),
                       'webuiSourceDirty' => environment.fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_DIRTY') == '1' ? 'true' : 'false',
                       'webuiSourceKind' => environment.fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_SOURCE_KIND') }
                   else
                     {}
                   end
          labels.delete('webuiSourceKind') if ENV['TEST_PARTIAL_LABELS'] == '1'
          target = File.join(workspace, "built-#{File.readlines(ENV.fetch('TEST_EVENTS')).length}.json")
          File.write(target, ENV['TEST_INVALID_RESULT'] == '1' ? '{invalid' : JSON.generate('machines' => machines, 'labels' => labels))
          FileUtils.rm_f(link)
          File.symlink(target, link)
          exit 23 if ENV['FAIL_AFTER_LINK'] == '1'
        when 'run'
          File.write(value_after('--ready-file'), 'ready')
        end
      when 'ssh-keygen'
        File.write(value_after('-f'), 'fixture')
        File.write(value_after('-f') + '.pub', 'fixture')
      when 'openssl'
        if ARGV.first == 'rand'
          puts('a' * 64)
        elsif ARGV.include?('-ext')
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
