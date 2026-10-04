require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../dev-clusters/vpsadmin/lib/maintenance'

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

  def test_pending_unknown_maintenance_refuses_ordinary_writer_operations
    %w[start update restart refresh reset].each do |command|
      with_workspace('vpsadmin') do |env, directory|
        File.write(File.join(directory, 'maintenance-hold.json'), '{"version":99}')
        File.chmod(0o600, File.join(directory, 'maintenance-hold.json'))
        result = run_helper('vpsadmin', env, command)
        refute(result.success?, command)
        refute(events(env).any? { |event| %w[build run copy activate ssh].include?(event['event']) })
        assert_equal('{"version":99}', File.binread(File.join(directory, 'maintenance-hold.json')))
        assert_locks_released(env)
      end
    end
  end

  def test_maintenance_forms_reject_arbitrary_flags_before_build_or_boot
    [
      ['maintenance-start', '--force'],
      ['maintenance-start', '--kernel-params', 'init=/other'],
      ['maintenance-start', '--resident-config', '/fixture/resident'],
      ['start', '--copied-config', '--force'],
      ['update', 'node1', '--copy-only'],
      ['update', '--copy-only', 'services'],
      ['update', 'services', '--force', '--copy-only']
    ].each do |command, *arguments|
      with_workspace('vpsadmin') do |env, _directory|
        stdout, stderr, result = Open3.capture3(env, File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'),
                                              command, env.fetch('TEST_SLUG'), *arguments)
        refute(result.success?, stdout + stderr)
        refute(events(env).any? { |event| %w[build run copy activate ssh].include?(event['event']) })
        assert_locks_released(env)
      end
    end
  end

  def test_storage_profile_refuses_disabled_or_stopped_clusters_before_guest_effects
    with_workspace('vpsadmin', retained: true) do |env, directory|
      result = run_helper('vpsadmin', env, 'storage-profile', 'provision')
      refute(result.success?)
      assert_includes(@last_output, 'not enabled')
      refute(events(env).any? { |event| event['event'] == 'ssh' })

      env = enable_storage_profile(env, directory)
      result = run_helper('vpsadmin', env, 'storage-profile', 'provision')
      refute(result.success?)
      assert_includes(@last_output, 'owned running cluster')
      refute(events(env).any? { |event| event['event'] == 'ssh' })
    end
  end

  def test_storage_profile_checks_all_roots_before_provisioning_and_restarts_only_after_success
    with_workspace('vpsadmin', retained: true) do |env, directory|
      env = enable_storage_profile(env, directory)
      with_profile_runner(env, directory) do
        result = run_helper('vpsadmin', env, 'storage-profile', 'provision')
        assert(result.success?, @last_output)
        commands = events(env).select { |event| event['event'] == 'ssh' }.map { |event| event['argv'].last }
        inspection = commands.index { |command| command.include?('vpsadmin-storage-profile inspect') }
        probes = commands.each_index.select { |index| commands[index].include?('zfs list -H -r') }
        stop = commands.index('systemctl stop vpsadmin-scheduler.service')
        provision = commands.index { |command| command.include?("vpsadmin-storage-profile 'provision'") }
        restart = commands.index('systemctl start vpsadmin-scheduler.service')
        assert_equal(3, probes.size)
        assert(probes.all? { |index| index > inspection && index < stop })
        assert_operator(stop, :<, provision)
        assert_operator(provision, :<, restart)
        assert_empty(Dir.glob(File.join(directory, '.profile-check.*')))
        refute(events(env).any? { |event| %w[build run copy activate].include?(event['event']) })
        assert_locks_released(env)
      end
    end
  end

  def test_storage_profile_refuses_uncatalogued_or_missing_roots_before_stopping_scheduling
    %w[TEST_PROFILE_ORPHAN TEST_PROFILE_MISSING_ROOT].each do |failure|
      with_workspace('vpsadmin', retained: true) do |env, directory|
        env = enable_storage_profile(env, directory).merge(failure => '1')
        with_profile_runner(env, directory) do
          result = run_helper('vpsadmin', env, 'storage-profile', 'provision')
          refute(result.success?)
          commands = events(env).select { |event| event['event'] == 'ssh' }.map { |event| event['argv'].last }
          refute_includes(commands, 'systemctl stop vpsadmin-scheduler.service')
          refute(commands.any? { |command| command.include?("vpsadmin-storage-profile 'provision'") })
          assert_equal(1, Dir.glob(File.join(directory, '.profile-check.*')).size)
          assert_locks_released(env)
        end
      end
    end
  end

  def test_storage_profile_failure_leaves_scheduling_stopped
    %w[provision retire].each do |operation|
      with_workspace('vpsadmin', retained: true) do |env, directory|
        env = enable_storage_profile(env, directory, enrollment: operation == 'provision')
        env['FAIL_PROFILE_OPERATION'] = '1'
        with_profile_runner(env, directory) do
          result = run_helper('vpsadmin', env, 'storage-profile', operation)
          refute(result.success?, @last_output)
          commands = events(env).select { |event| event['event'] == 'ssh' }.map { |event| event['argv'].last }
          assert_includes(commands, 'systemctl stop vpsadmin-scheduler.service')
          refute_includes(commands, 'systemctl start vpsadmin-scheduler.service')
          assert_locks_released(env)
        end
      end
    end
  end

  def test_successful_retirement_resumes_unrelated_scheduling_after_cleanup
    with_workspace('vpsadmin', retained: true) do |env, directory|
      env = enable_storage_profile(env, directory, enrollment: false)
      with_profile_runner(env, directory) do
        result = run_helper('vpsadmin', env, 'storage-profile', 'retire')
        assert(result.success?, @last_output)
        commands = events(env).select { |event| event['event'] == 'ssh' }.map { |event| event['argv'].last }
        stop = commands.index('systemctl stop vpsadmin-scheduler.service')
        retire = commands.index { |command| command.include?("vpsadmin-storage-profile 'retire'") }
        restart = commands.index('systemctl start vpsadmin-scheduler.service')
        assert_operator(stop, :<, retire)
        assert_operator(retire, :<, restart)
        assert_empty(Dir.glob(File.join(directory, '.profile-check.*')))
      end
    end
  end

  def test_storage_profile_requires_the_correct_desired_and_deployed_enrollment
    [[true, 'retire'], [false, 'provision'], [nil, 'retire'], %w[false retire]].each do |enrollment, operation|
      with_workspace('vpsadmin', retained: true) do |env, directory|
        env = enable_storage_profile(env, directory, enrollment: enrollment)
        result = run_helper('vpsadmin', env, 'storage-profile', operation)
        refute(result.success?)
        refute(events(env).any? { |event| event['event'] == 'ssh' })
      end
    end
    [true, false].each do |enrollment|
      with_workspace('vpsadmin', retained: true) do |env, directory|
        env = enable_storage_profile(env, directory, enrollment: enrollment)
              .merge('TEST_PROFILE_EFFECTIVE_ENROLLMENT' => (!enrollment).to_s)
        with_profile_runner(env, directory) do
          result = run_helper('vpsadmin', env, 'storage-profile', enrollment ? 'provision' : 'retire')
          refute(result.success?)
          assert_includes(@last_output, 'desired and deployed enrollment differ')
          commands = events(env).select { |event| event['event'] == 'ssh' }.map { |event| event['argv'].last }
          refute(commands.any? { |command| command.include?('zfs list') || command.include?('systemctl stop') })
        end
      end
    end
  end

  def test_failed_guest_requisite_query_keeps_target_pending_without_root_or_promotion
    with_workspace('vpsadmin') do |env, directory|
      proof_env = selection_proof_environment(env).merge('FAIL_PROOF_QUERY' => '1')
      result = run_helper('vpsadmin', proof_env, 'update', 'node1')
      assert_equal(23, result.exitstatus, @last_output)
      applied = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
      assert_equal(['node1'], applied.fetch('pending').fetch('targets'))
      assert_empty(applied.fetch('provenance'))
      assert_equal(['--query'], File.readlines(proof_env.fetch('TEST_PROOF_EVENTS'), chomp: true))
      assert_locks_released(env)
    end
  end

  def test_guest_closure_and_root_proof_promotes_only_the_updated_target
    with_workspace('vpsadmin') do |env, directory|
      proof_env = selection_proof_environment(env)
      result = run_helper('vpsadmin', proof_env, 'update', 'node1')
      assert(result.success?, @last_output)
      applied = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
      assert_nil(applied.fetch('pending'))
      assert_equal(['node1'], applied.fetch('provenance').keys)
      assert_equal(%w[--query --check-validity --add-root], File.readlines(proof_env.fetch('TEST_PROOF_EVENTS'), chomp: true))
    end
  end

  def test_failed_applied_source_root_leaves_pending_before_copy
    with_workspace('vpsadmin') do |env, directory|
      result = run_helper('vpsadmin', env.merge('FAIL_GC_ROOT' => '1'), 'update', 'node1')
      refute(result.success?, @last_output)
      applied = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
      assert_equal(['node1'], applied.fetch('pending').fetch('targets'))
      assert_empty(applied.fetch('provenance'))
      refute(events(env).any? { |event| %w[copy activate].include?(event['event']) })
    end
  end

  def test_payload_registration_failure_prevents_fresh_runner_and_target_effects
    %w[start update].each do |operation|
      with_workspace('vpsadmin') do |env, directory|
        attempt = events(env).length
        result = run_helper('vpsadmin', env.merge('FAIL_PAYLOAD_ROOT' => '1'), operation, operation == 'update' ? 'node1' : nil)
        refute(result.success?, @last_output)
        target = operation == 'update' ? 'node1' : 'services'
        assert_payload_root_refusal(env, attempt, File.join(env.fetch('TEST_STORE'), "fixture-#{target}-kernel"))
        refute(events(env).any? { |event| %w[run copy activate selection-proof].include?(event['event']) })
        if operation == 'update'
          applied = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
          assert_equal(['node1'], applied.fetch('pending').fetch('targets'))
          assert_empty(applied.fetch('provenance'))
        else
          refute(File.exist?(File.join(directory, 'applied-config.json')))
        end
      end
    end
  end

  def test_update_roots_only_the_candidate_target_and_retains_previously_proved_payloads
    with_workspace('vpsadmin') do |env, directory|
      assert(run_helper('vpsadmin', env, 'start').success?, @last_output)
      old_roots = Dir.glob(File.join(directory, 'maintenance-payload-*'))
      machines = fixture_machines
      machines.fetch('services')['toplevel'] += '-unproved'
      machines.fetch('node1')['squashfs'] += '-updated'
      env['TEST_BUILT_MACHINES'] = JSON.generate(machines)
      assert(run_helper('vpsadmin', env, 'update', 'node1').success?, @last_output)
      targets = Dir.glob(File.join(directory, 'maintenance-payload-*')).map { |path| File.readlink(path) }
      assert_includes(targets, env.fetch('TEST_STORE') + '/fixture-node1-squashfs-updated')
      refute_includes(targets, env.fetch('TEST_STORE') + '/fixture-services-unproved')
      assert(old_roots.all? { |path| File.symlink?(path) })
      copy = events(env).index { |event| event['event'] == 'copy' }
      assert(events(env)[0...copy].any? { |event| event['event'] == 'payload-root' && event['item'].end_with?('-updated') })
      applied = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
      assert_equal(machines.fetch('node1'), applied.fetch('configuration').fetch('machines').fetch('node1'))
      refute_equal(machines.fetch('services'), applied.fetch('configuration').fetch('machines').fetch('services'))
    end
  end

  def test_recovery_roots_selected_payloads_not_superseded_dns_and_retry_repairs_or_refuses
    with_workspace('vpsadmin') do |env, directory|
      with_recovery_selection(env, directory) do |evidence|
        FileUtils.rm_rf(File.join(env.fetch('TEST_STORE'), 'old-dns-primary-not-copied'))
        command = [File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'), 'maintenance-recover-config',
                   env.fetch('TEST_SLUG'), '--residency-evidence', evidence]
        _, error, result = Open3.capture3(env, *command)
        assert(result.success?, error)
        record = File.join(directory, 'maintenance-hold.json')
        before = File.binread(record)
        applied = File.binread(File.join(directory, 'applied-config.json'))
        selected = File.join(env.fetch('TEST_STORE'), 'old-dns-primary')
        root = File.join(directory, "maintenance-payload-#{Digest::SHA256.hexdigest(selected)}")
        assert_equal(selected, File.readlink(root))
        refute(Dir.glob(File.join(directory, 'maintenance-payload-*')).any? { |path| File.readlink(path).end_with?('-not-copied') })
        File.unlink(root)
        _, error, result = Open3.capture3(env, *command)
        assert(result.success?, error)
        assert_equal(selected, File.readlink(root))
        assert_equal(before, File.binread(record))
        assert_equal(applied, File.binread(File.join(directory, 'applied-config.json')))
        # An on-disk item can lose its Nix registration. Keep it present so
        # the real helper reaches the controlled store-validity refusal.
        attempt = events(env).length
        _, error, result = Open3.capture3(env.merge('FAIL_VALIDITY_ITEM' => selected), *command)
        refute(result.success?)
        assert_equal([{ 'event' => 'store-validity-refused', 'item' => selected }],
          events(env).drop(attempt).select { |event| event['event'] == 'store-validity-refused' })
        assert_equal(before, File.binread(record))
        assert_equal(applied, File.binread(File.join(directory, 'applied-config.json')))
        refute(events(env).any? { |event| %w[build run copy activate ssh selection-proof].include?(event['event']) })
      end
    end
  end

  def test_payload_registration_failure_keeps_recovery_predecessor_and_blocks_copied_boot
    with_workspace('vpsadmin') do |env, directory|
      with_recovery_selection(env, directory) do |evidence|
        command = File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster')
        record = File.join(directory, 'maintenance-hold.json')
        before = File.binread(record)
        attempt = events(env).length
        _, error, result = Open3.capture3(env.merge('FAIL_PAYLOAD_ROOT' => '1'), command,
          'maintenance-recover-config', env.fetch('TEST_SLUG'), '--residency-evidence', evidence)
        refute(result.success?)
        assert_payload_root_refusal(env, attempt, File.join(env.fetch('TEST_STORE'), 'kernel'))
        assert_equal(before, File.binread(record))
        refute(File.exist?(File.join(directory, 'applied-config.json')))
        roots = Dir.glob(File.join(directory, 'maintenance-source-*'))
        refute_empty(roots)
        attempt = events(env).length
        _, error, result = Open3.capture3(env.merge('FAIL_PAYLOAD_ROOT' => '1'), command,
          'start', env.fetch('TEST_SLUG'), '--copied-config')
        refute(result.success?)
        assert_payload_root_refusal(env, attempt, File.join(env.fetch('TEST_STORE'), 'kernel'))
        assert_equal('starting_copied', JSON.parse(File.read(record)).fetch('phase'))
        assert(roots.all? { |path| File.symlink?(path) })
        assert_equal('copied_boot', JSON.parse(File.read(File.join(directory, 'applied-config.json'))).fetch('pending').fetch('operation'))
        refute(events(env).any? { |event| %w[run copy activate ssh selection-proof].include?(event['event']) })
      end
    end
  end

  def test_maintenance_payload_failure_precedes_system_inspection_and_masked_launch
    with_workspace('vpsadmin') do |env, directory|
      with_recovery_selection(env, directory) do |_evidence, resident, residency, top|
        before = File.binread(File.join(directory, 'maintenance-hold.json'))
        attempt = events(env).length
        _, error, result = Open3.capture3(env.merge('FAIL_PAYLOAD_ROOT' => '1'),
          File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'), 'maintenance-start', env.fetch('TEST_SLUG'),
          '--resident-config', resident, '--expect-services-toplevel', top, '--residency-evidence', residency)
        refute(result.success?)
        assert_payload_root_refusal(env, attempt, File.join(env.fetch('TEST_STORE'), 'kernel'))
        assert_equal(before, File.binread(File.join(directory, 'maintenance-hold.json')))
        refute(events(env).any? { |event| %w[run copy activate ssh].include?(event['event']) })
      end
    end
  end

  def test_public_recovery_is_metadata_only_and_root_failure_preserves_original_hold
    [true, false].each do |root_failure|
      with_workspace('vpsadmin') do |env, directory|
        with_recovery_selection(env, directory) do |evidence|
          before = File.binread(File.join(directory, 'maintenance-hold.json'))
          arguments = [File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'), 'maintenance-recover-config',
                       env.fetch('TEST_SLUG'), '--residency-evidence', evidence]
          stdout, stderr, result = Open3.capture3(env.merge('FAIL_GC_ROOT' => root_failure ? '1' : '0'), *arguments)
          if root_failure
            refute(result.success?, stdout + stderr)
            assert_equal(before, File.binread(File.join(directory, 'maintenance-hold.json')))
            refute(File.exist?(File.join(directory, 'applied-config.json')))
          else
            assert(result.success?, stdout + stderr)
            hold = JSON.parse(File.read(File.join(directory, 'maintenance-hold.json')))
            assert_equal(2, hold.fetch('version'))
            assert_equal('copied', hold.fetch('phase'))
            assert_equal(before, File.binread(hold.fetch('predecessor').fetch('path')))
            applied = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
            assert_equal('copied_boot', applied.fetch('pending').fetch('operation'))
            current = File.binread(File.join(directory, 'maintenance-hold.json'))
            _, retry_stderr, retry_result = Open3.capture3(env, *arguments)
            assert(retry_result.success?, retry_stderr)
            assert_equal(current, File.binread(File.join(directory, 'maintenance-hold.json')))
          end
          refute(events(env).any? { |event| %w[build run copy activate ssh selection-proof].include?(event['event']) })
          assert_locks_released(env)
        end
      end
    end
  end

  def test_public_maintenance_start_never_launches_old_services_after_recovery
    with_workspace('vpsadmin') do |env, directory|
      with_recovery_selection(env, directory) do |evidence, resident, residency, top|
        command = File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster')
        _, errors, recovered = Open3.capture3(env, command, 'maintenance-recover-config', env.fetch('TEST_SLUG'),
                                            '--residency-evidence', evidence)
        assert(recovered.success?, errors)
        before = File.binread(File.join(directory, 'maintenance-hold.json'))
        stdout, stderr, result = Open3.capture3(env, command, 'maintenance-start', env.fetch('TEST_SLUG'),
          '--resident-config', resident, '--expect-services-toplevel', top, '--residency-evidence', residency)
        refute(result.success?, stdout + stderr)
        assert_equal(before, File.binread(File.join(directory, 'maintenance-hold.json')))
        refute(events(env).any? { |event| %w[run copy activate ssh].include?(event['event']) })
        refute(File.exist?(File.join(directory, 'ready')))
      end
    end
  end

  def test_legacy_images_refuse_cold_start_without_inventing_residency
    with_workspace('vpsadmin', retained: true) do |env, directory|
      FileUtils.mkdir_p(File.join(directory, 'state'))
      File.write(File.join(directory, 'state/services-root.img'), 'existing retained image')
      result = run_helper('vpsadmin', env, 'start')
      refute(result.success?)
      refute(events(env).any? { |event| event['event'] == 'run' })
      refute(File.exist?(File.join(directory, 'applied-config.json')))
    end
  end

  def test_retained_start_refuses_changed_layout_and_ignores_unapplied_boot_payloads
    with_workspace('vpsadmin') do |env, directory|
      assert(run_helper('vpsadmin', env, 'start').success?, @last_output)
      original = JSON.parse(File.read(File.join(directory, 'applied-config.json')))
      pending_before = File.binread(File.join(directory, 'applied-config.json'))
      machines = fixture_machines
      machines.fetch('node1')['networks'] = [{ 'type' => 'bridge', 'name' => 'changed-routing' }]
      env['TEST_BUILT_MACHINES'] = JSON.generate(machines)
      runs = events(env).count { |event| event['event'] == 'run' }
      refute(run_helper('vpsadmin', env, 'start').success?)
      assert_equal(runs, events(env).count { |event| event['event'] == 'run' })
      assert_equal(pending_before, File.binread(File.join(directory, 'applied-config.json')))
      machines = fixture_machines
      machines.fetch('services')['toplevel'] += '-new-unapplied'
      machines.fetch('node1')['squashfs'] += '-new-unapplied'
      env['TEST_BUILT_MACHINES'] = JSON.generate(machines)
      assert(run_helper('vpsadmin', env, 'start').success?, @last_output)
      runner = events(env).select { |event| event['event'] == 'run' }.last
      config_arg = runner.fetch('argv').index('--config') + 1
      actual_boot = JSON.parse(File.read(runner.fetch('argv').fetch(config_arg)))
      assert_equal(original.fetch('configuration'), actual_boot)
      assert_equal(original.fetch('configuration'), JSON.parse(File.read(File.join(directory, 'applied-config.json'))).fetch('configuration'))
    end
  end

  def test_recovery_accepts_only_fixed_evidence_argument_and_refuses_a_live_runner
    with_workspace('vpsadmin') do |env, directory|
      with_profile_runner(env, directory) do
        before = events(env)
        stdout, stderr, result = Open3.capture3(env, File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'),
          'maintenance-recover-config', env.fetch('TEST_SLUG'), '--residency-evidence', '/fixture/evidence.json')
        refute(result.success?, stdout + stderr)
        assert_equal(before, events(env))
        refute(File.exist?(File.join(directory, 'maintenance-hold.json')))
      end
    end
    [[], ['--force'], ['--residency-evidence', '/fixture/evidence', '--config', '/fixture/config']].each do |arguments|
      with_workspace('vpsadmin') do |env, _directory|
        stdout, stderr, result = Open3.capture3(env, File.join(ROOT, 'dev-clusters/vpsadmin/bin/devcluster'),
          'maintenance-recover-config', env.fetch('TEST_SLUG'), *arguments)
        refute(result.success?, stdout + stderr)
        assert_empty(events(env))
      end
    end
  end

  private

  def assert_payload_root_refusal(env, attempt, item)
    directory = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), '.dev-clusters', 'vpsadmin', 'clusters', env.fetch('TEST_SLUG'))
    root = File.join(directory, "maintenance-payload-#{Digest::SHA256.hexdigest(item)}")
    assert_equal([{ 'event' => 'payload-root-refused', 'item' => item, 'root' => root }],
      events(env).drop(attempt).select { |event| event['event'] == 'payload-root-refused' })
  end

  def write_host_payloads(store, machines)
    machines.each_value do |machine|
      %w[toplevel qemu virtiofsd].each do |field|
        path = machine.fetch(field).sub('/nix/store/', store + '/')
        FileUtils.mkdir_p(path)
      end
      %w[qemu virtiofsd].each do |field|
        package = machine.fetch(field).sub('/nix/store/', store + '/')
        executable = File.join(package, 'bin', field == 'qemu' ? 'qemu-kvm' : 'virtiofsd')
        FileUtils.mkdir_p(File.dirname(executable))
        File.write(executable, 'fixture executable')
        File.chmod(0o755, executable)
      end
      %w[kernel initrd squashfs].each do |field|
        next unless machine[field]

        path = machine.fetch(field).sub('/nix/store/', store + '/')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, 'fixture host boot payload')
      end
    end
  end

  def fixture_machines
    %w[services node1 node2].to_h do |name|
      machine = { 'spin' => name == 'services' ? 'nixos' : 'vpsadminos',
                  'qemu' => '/nix/store/fixture-tools', 'virtiofsd' => '/nix/store/fixture-tools',
                  'toplevel' => "/nix/store/fixture-#{name}",
                  'kernel' => "/nix/store/fixture-#{name}-kernel", 'initrd' => "/nix/store/fixture-#{name}-initrd" }
      disk = { 'device' => '{machine}-root.img', 'type' => 'file',
               'create' => true, 'preserve' => true, 'size' => '1G' }
      if name == 'services'
        machine['rootDisk'] = disk
      else
        machine['disks'] = [disk]
        machine['squashfs'] = "/nix/store/fixture-#{name}-squashfs"
      end
      [name, machine]
    end
  end

  def with_recovery_selection(env, directory)
    store = env.fetch('TEST_STORE')
    state = File.join(directory, 'state')
    FileUtils.mkdir_p(state)
    File.write(File.join(directory, 'network'), "bridge\n")
    qemu = File.join(store, 'qemu')
    FileUtils.mkdir_p(File.join(qemu, 'bin'))
    File.write(File.join(qemu, 'bin/qemu-kvm'), 'fixture')
    File.chmod(0o755, File.join(qemu, 'bin/qemu-kvm'))
    historic = { 'machines' => fixture_machines }
    historic.fetch('machines')['dns-primary'] = historic.fetch('machines').fetch('services').dup
    historic.fetch('machines').each do |name, machine|
      machine['toplevel'] = File.join(store, "old-#{name}")
      machine['kernel'] = File.join(store, 'kernel')
      machine['initrd'] = File.join(store, 'initrd')
      machine['qemu'] = qemu
      machine['virtiofsd'] = qemu
      File.write(File.join(state, "#{name}-root.img"), 'retained fixture image')
    end
    historic_path = File.join(store, 'historic.json')
    File.write(historic_path, JSON.generate(historic))
    selected = JSON.parse(JSON.generate(historic))
    selected.fetch('machines').fetch('dns-primary')['toplevel'] += '-not-copied'
    resident_path = File.join(store, 'legacy-selected.json')
    File.write(resident_path, JSON.generate(selected))
    candidate = JSON.parse(JSON.generate(selected))
    candidate.fetch('machines').fetch('services')['toplevel'] += '-copied'
    candidate['labels'] = { 'vpsadminPreservingSeed' => '{"version":1,"existingAssignments":"preserve"}' }
    candidate_path = File.join(store, 'candidate.json')
    File.write(candidate_path, JSON.generate(candidate))
    write_host_payloads(store, historic.fetch('machines'))
    write_host_payloads(store, selected.fetch('machines'))
    write_host_payloads(store, candidate.fetch('machines'))
    evidence = File.join(directory, 'residency.json')
    File.write(evidence, JSON.generate('version' => 1, 'workspace' => env.fetch('DEVCLUSTER_WORKSPACE'),
      'slug' => env.fetch('TEST_SLUG'), 'resident_config' => resident_path,
      'resident_config_sha256' => Digest::SHA256.file(resident_path).hexdigest,
      'services_toplevel' => selected.fetch('machines').fetch('services').fetch('toplevel'),
      'evidence_kind' => 'prior_activation', 'evidence_reference' => 'fixture real services residency; DNS unproved'))
    File.chmod(0o600, evidence)
    helper = DevClusters::VpsAdminMaintenance.new(workspace: env.fetch('DEVCLUSTER_WORKSPACE'),
      slug: env.fetch('TEST_SLUG'), directory: directory, store_root: store)
    helper.prepare!(config_path: resident_path,
      services_toplevel: selected.fetch('machines').fetch('services').fetch('toplevel'), evidence_path: evidence)
    identity = { pid: 123, start: '456', boot_id: '01111111-2222-3333-4444-555555555555' }
    helper.bind_boot!(**identity)
    helper.begin_copy!(candidate_path: candidate_path, **identity)
    next_path = File.join(store, 'next.json')
    helper.build_next!(next_path: next_path)
    helper.finish_copy!(next_path: next_path, **identity)
    proof = JSON.parse(File.read(next_path)).fetch('machines').to_h do |name, machine|
      source = name == 'dns-primary' ? historic_path : next_path
      [name, { 'source_config' => source, 'source_config_sha256' => Digest::SHA256.file(source).hexdigest,
               'proof_kind' => name == 'services' ? 'held_copy' : (name == 'dns-primary' ? 'prior_boot' : 'prior_update'),
               'proof_reference' => 'fixture action ledger; retained disk never replaced',
               'disks' => helper.send(:disk_identities, name:, machine:) }]
    end
    recovery = File.join(directory, 'recovery.json')
    File.write(recovery, JSON.generate('version' => 1, 'kind' => 'retained_boot_recovery',
      'workspace' => env.fetch('DEVCLUSTER_WORKSPACE'), 'slug' => env.fetch('TEST_SLUG'),
      'expected_hold_sha256' => Digest::SHA256.file(File.join(directory, 'maintenance-hold.json')).hexdigest,
      'machines' => proof))
    File.chmod(0o600, recovery)
    yield recovery, resident_path, evidence, selected.fetch('machines').fetch('services').fetch('toplevel')
  end

  def selection_proof_environment(env)
    bin = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), 'proof-bin')
    FileUtils.mkdir_p(bin)
    path = File.join(bin, 'nix-store')
    File.write(path, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
      File.open(ENV.fetch('TEST_PROOF_EVENTS'), 'a') { |file| file.puts(ARGV.first) }
      if ARGV.first == '--query'
        exit 23 if ENV['FAIL_PROOF_QUERY'] == '1'
        puts ENV.fetch('TEST_PROOF_TOP')
      end
    RUBY
    File.chmod(0o755, path)
    env.merge('RUN_SELECTION_PROOF' => '1', 'TEST_PROOF_BIN' => bin,
              'TEST_PROOF_EVENTS' => File.join(bin, 'events'))
  end

  def enable_storage_profile(env, directory, enrollment: :omitted)
    config = JSON.parse(File.read(env.fetch('TEST_CONFIG')))
    config['storageProfile'] = { 'enable' => true }
    config['storageProfile']['enrollment'] = enrollment unless enrollment == :omitted
    path = File.join(directory, 'config.json')
    File.write(path, JSON.generate(config))
    File.write(File.join(directory, 'topology'), "storage\n")
    env.merge('TEST_CONFIG' => path, 'TEST_STORAGE_PROFILE' => '1')
  end

  def with_profile_runner(_env, directory)
    socket = File.read(File.join(directory, 'socket-dir')).strip
    pid = Process.spawn(RbConfig.ruby, '-e', 'sleep 60', '--', '--sock-dir', socket,
                        out: File::NULL, err: File::NULL)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until File.read("/proc/#{pid}/cmdline").split("\0").include?(socket)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise 'Fixture runner did not publish its socket argument'
      end

      sleep 0.01
    end
    File.write(File.join(directory, 'runner.pid'), "#{pid}\n")
    yield
  ensure
    if pid
      Process.kill('TERM', pid)
      Process.wait(pid)
    end
  end

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
      store = File.join(workspace, 'store')
      FileUtils.mkdir_p(store)
      machines = fixture_machines
      write_host_payloads(store, machines)
      built = File.join(store, 'built.json')
      File.write(built, JSON.generate('machines' => machines, 'labels' => {}))
      File.symlink(built, File.join(directory, 'result-config')) if retained
      bin = File.join(workspace, 'bin')
      FileUtils.mkdir_p(bin)
      %w[nix nix-store ruby ssh ssh-keygen openssl git rm jq mktemp mv ping].each do |name|
        path = File.join(bin, name)
        File.write(path, "#!#{RbConfig.ruby}\n" + command_stub)
        File.chmod(0o755, path)
      end
      env = {
        'DEVCLUSTER_WORKSPACE' => workspace,
        'TEST_SLUG' => slug,
        'TEST_KIND' => kind,
        'TEST_REAL_RUBY' => RbConfig.ruby,
        'TEST_STORE' => store,
        'TEST_BUILT_MACHINES' => JSON.generate(machines),
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
    if kind == 'vpsadmin' && command == 'update'
      state = File.join(env.fetch('DEVCLUSTER_WORKSPACE'), '.dev-clusters', kind, 'clusters', env.fetch('TEST_SLUG'), 'state')
      FileUtils.mkdir_p(state)
      fixture_machines.each_key do |name|
        path = File.join(state, "#{name}-root.img")
        File.write(path, 'retained sentinel') unless File.exist?(path)
      end
    end
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
      exit 1 if command == 'ping'
      if command == 'ruby'
        helper = ARGV.first
        if helper && helper.end_with?('/vpsadmin/lib/maintenance.rb')
          require helper
          DevClusters::VpsAdminMaintenance.prepend(Module.new do
            def initialize(**identity)
              super(**identity, store_root: ENV.fetch('TEST_STORE'))
            end

            # Shell proof fixtures use fixed /nix/store names, while the real
            # helper registers only these test-owned filesystem equivalents.
            def host_payloads(config, **options)
              local = JSON.parse(JSON.generate(config).gsub('/nix/store/', ENV.fetch('TEST_STORE') + '/'))
              super(local, **options)
            end
          end)
          $0 = ARGV.shift
          $VERBOSE = nil
          load helper
          exit 0
        end
        exec ENV.fetch('TEST_REAL_RUBY'), *ARGV
      end
      if command == 'nix-store'
        ARGV.shift(3) if ARGV.first == '--option' && ARGV[1, 2] == %w[substitute false]
        if ARGV.first == '--add'
          require 'digest'
          source = ARGV.fetch(1)
          target = File.join(ENV.fetch('TEST_STORE'), Digest::SHA256.file(source).hexdigest + '-sealed.json')
          FileUtils.cp(source, target) unless File.exist?(target)
          puts target
        elsif ARGV.first == '--add-root'
          exit 23 if ENV['FAIL_GC_ROOT'] == '1'
          link = ARGV.fetch(1)
          target = ARGV.last
          FileUtils.mkdir_p(File.dirname(link))
          FileUtils.rm_f(link)
          File.symlink(target, link)
          if File.basename(link).start_with?('maintenance-payload-')
            if ENV['FAIL_PAYLOAD_ROOT'] == '1'
              File.open(ENV.fetch('TEST_EVENTS'), 'a') do |file|
                file.puts(JSON.generate('event' => 'payload-root-refused', 'item' => target, 'root' => link))
              end
              exit 23
            end
            File.open(ENV.fetch('TEST_EVENTS'), 'a') { |file| file.puts(JSON.generate('event' => 'payload-root', 'item' => target)) }
          end
        elsif ARGV.first == '--check-validity'
          item = ARGV.fetch(1)
          if ENV['FAIL_VALIDITY_ITEM'] == item || !File.exist?(item)
            File.open(ENV.fetch('TEST_EVENTS'), 'a') { |file| file.puts(JSON.generate('event' => 'store-validity-refused', 'item' => item)) }
            exit 23
          end
        elsif ARGV[0, 2] == %w[--query --roots]
          directory = File.join(ENV.fetch('DEVCLUSTER_WORKSPACE'), '.dev-clusters', 'vpsadmin', 'clusters', ENV.fetch('TEST_SLUG'))
          roots = Dir.glob(File.join(directory, 'maintenance-{payload,source}-*')).select { |path| File.symlink?(path) && File.readlink(path) == ARGV.last }
          puts roots.map { |path| "#{path} -> #{ARGV.last}" }
        else
          abort 'unexpected fixture nix-store action'
        end
        exit 0
      end
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
                elsif ARGV.last.include?('vpsadmin-devcluster-applied-')
                  'selection-proof'
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
          machines = JSON.parse(ENV.fetch('TEST_BUILT_MACHINES'))
          store = ENV.fetch('TEST_STORE')
          machines.each_value do |machine|
            %w[toplevel qemu virtiofsd].each do |field|
              path = machine.fetch(field).sub('/nix/store/', store + '/')
              FileUtils.mkdir_p(path)
            end
            %w[kernel initrd squashfs].each do |field|
              next unless machine[field]
              path = machine.fetch(field).sub('/nix/store/', store + '/')
              FileUtils.mkdir_p(File.dirname(path))
              File.write(path, 'fixture host boot payload')
            end
          end
          labels = if config.dig('newWebui', 'enable') == true
                     { 'webuiSourceRevision' => environment.fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_REVISION'),
                       'webuiSourceDirty' => environment.fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_DIRTY') == '1' ? 'true' : 'false',
                       'webuiSourceKind' => environment.fetch('VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_SOURCE_KIND') }
                   else
                     {}
                   end
          labels.delete('webuiSourceKind') if ENV['TEST_PARTIAL_LABELS'] == '1'
          target = File.join(ENV.fetch('TEST_STORE'), "built-#{File.readlines(ENV.fetch('TEST_EVENTS')).length}.json")
          File.write(target, ENV['TEST_INVALID_RESULT'] == '1' ? '{invalid' : JSON.generate('machines' => machines, 'labels' => labels))
          FileUtils.rm_f(link)
          File.symlink(target, link)
          exit 23 if ENV['FAIL_AFTER_LINK'] == '1'
        when 'run'
          config = JSON.parse(File.read(value_after('--config')))
          state = value_after('--state-dir')
          FileUtils.mkdir_p(state)
          config.fetch('machines').each_key do |name|
            path = File.join(state, "#{name}-root.img")
            File.write(path, 'new fixture image') unless File.exist?(path)
          end
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
        if event == 'selection-proof'
          if ENV['RUN_SELECTION_PROOF'] == '1'
            require 'open3'
            remote = ARGV.last
            top = remote.match(/= '([^']+)'/).captures.first
            prelude = <<~SH
              readlink() { printf '%s\n' '#{top}'; }
              test() {
                if [ "$1" = -x ] && [ "$2" = '#{top}/init' ]; then return 0; fi
                command test "$@"
              }
            SH
            output, errors, result = Open3.capture3({ 'PATH' => "#{ENV.fetch('TEST_PROOF_BIN')}:#{ENV.fetch('PATH')}", 'TEST_PROOF_TOP' => top }, 'bash', '-c', prelude + remote)
            print output
            warn errors unless errors.empty?
            exit result.exitstatus
          end
          exit 0
        end
        if ENV['TEST_STORAGE_PROFILE'] == '1'
          remote = ARGV.last
          if remote.include?('vpsadmin-storage-profile inspect')
            selection = JSON.parse(File.read(ENV.fetch('TEST_CONFIG'))).fetch('storageProfile')
            enrollment = selection.fetch('enrollment', true)
            enrollment = JSON.parse(ENV.fetch('TEST_PROFILE_EFFECTIVE_ENROLLMENT')) if ENV.key?('TEST_PROFILE_EFFECTIVE_ENROLLMENT')
            puts JSON.generate('version' => 1, 'enrollment' => enrollment, 'pools' => [
              { 'node_id' => 101, 'filesystem' => 'tank/ct', 'present' => true },
              { 'node_id' => 201, 'filesystem' => 'tank/backup', 'present' => false },
              { 'node_id' => 201, 'filesystem' => 'tank/nas', 'present' => false }
            ])
          elsif remote.include?('zfs list -H -r')
            roots = ['tank']
            roots << 'tank/ct' if value_after('-p') == '10122' && ENV['TEST_PROFILE_MISSING_ROOT'] != '1'
            roots << 'tank/backup' if value_after('-p') == '10322' && ENV['TEST_PROFILE_ORPHAN'] == '1'
            puts roots
          elsif remote.match?(/vpsadmin-storage-profile '(provision|retire)'/) && ENV['FAIL_PROFILE_OPERATION'] == '1'
            exit 23
          end
        end
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
