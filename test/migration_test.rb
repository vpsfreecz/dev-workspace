# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

load File.expand_path('../bin/vpsfree-dev-workspace-migrate', __dir__)

class MigrationTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HELPER = ENV.fetch('MIGRATION_HELPER', File.join(ROOT, 'bin/vpsfree-dev-workspace-migrate'))

  def test_user_migration_rewrites_runtime_and_reverses_exactly
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      before = snapshot(fixture.fetch(:snapshot_paths))

      run_helper('forward', *user_arguments(fixture))

      refute_path_exists(fixture.fetch(:old_config))
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces/registry.json'))
      assert_includes(File.read(fixture.fetch(:portal)), File.join(fixture.fetch(:runtime), 'dev-workspaces'))
      assert_includes(
        File.read(fixture.fetch(:archived_portal)),
        File.join(fixture.fetch(:runtime), 'dev-workspaces')
      )
      assert_equal('forward', journal(fixture).fetch('state'))
      registry_rewrite = journal(fixture).fetch('rewrites').find do |rewrite|
        rewrite.fetch('path').end_with?('/registry.json')
      end
      refute_nil(registry_rewrite)
      assert_equal(registry_rewrite.fetch('original'), registry_rewrite.fetch('updated'))

      activate_final_profile(fixture)
      before_preflight = File.binread(fixture.fetch(:journal))
      run_helper(
        'preflight', '--direction', 'reverse',
        *user_arguments(fixture).reject { |argument| argument == '--yes' }
      )
      assert_equal(before_preflight, File.binread(fixture.fetch(:journal)))
      run_helper('reverse', *user_arguments(fixture))
      restore_compatibility_profile(fixture)

      assert_equal(before, snapshot(fixture.fetch(:snapshot_paths)))
      assert_equal('reversed', journal(fixture).fetch('state'))
    end
  end

  def test_user_reverse_accepts_the_current_compatibility_package
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      before = snapshot(fixture.fetch(:snapshot_paths))

      run_helper('forward', *user_arguments(fixture))
      run_helper('reverse', *user_arguments(fixture))

      assert_equal(before, snapshot(fixture.fetch(:snapshot_paths)))
      assert_equal('reversed', journal(fixture).fetch('state'))
    end
  end

  def test_user_reverse_accepts_a_compensated_final_profile_switch
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      activate_final_profile(fixture)
      profile = File.join(fixture.fetch(:new_state), 'profile')
      File.unlink(profile)
      File.symlink('profile-1-link', profile)

      run_helper('reverse', *user_arguments(fixture))

      assert_equal('reversed', journal(fixture).fetch('state'))
      assert_equal(
        fixture.fetch(:compatibility_package),
        File.realpath(File.join(fixture.fetch(:old_state), 'profile'))
      )
    end
  end

  def test_user_rewrites_preserve_a_supplementary_group
    supplementary_gid = Process.groups.find { |gid| gid != Process.egid }
    skip 'the test process has no supplementary group' unless supplementary_gid

    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      File.chown(-1, supplementary_gid, fixture.fetch(:portal))

      run_helper('forward', *user_arguments(fixture))
      assert_equal(supplementary_gid, File.stat(fixture.fetch(:portal)).gid)

      run_helper('reverse', *user_arguments(fixture))
      assert_equal(supplementary_gid, File.stat(fixture.fetch(:portal)).gid)
    end
  end

  def test_preflight_is_read_only_for_both_scopes
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      before = snapshot(fixture.fetch(:snapshot_paths))

      run_helper('preflight', *user_arguments(fixture).reject { |argument| argument == '--yes' })
      host_journal = File.join(dir, 'var/lib/vpsfree-dev-workspace-host-migration.json')
      run_helper('preflight', '--scope', 'host', '--host-root', dir)

      refute_path_exists(fixture.fetch(:journal))
      refute_path_exists(host_journal)
      assert_equal(before, snapshot(fixture.fetch(:snapshot_paths)))
    end
  end

  def test_populated_host_preflight_is_read_only
    Dir.mktmpdir do |dir|
      paths = {
        '/var/lib/vpsfree-workspace-portal-password/password' => ["password\n", 0o600],
        '/var/lib/vpsfree-workspace-portal-auth/htpasswd' => ["user:hash\n", 0o640],
        '/var/lib/vpsfree-workspace-pki/authority/ca-key.pem' => ["key\n", 0o600],
        '/var/lib/vpsfree-workspace-portal-tls/pairs/current/server.pem' => ["cert\n", 0o644],
        '/var/lib/vpsfree-workspace-portal-public/ca.pem' => ["public\n", 0o644],
        '/run/vpsfree-workspace-router/router.sock.marker' => ["socket\n", 0o600],
        '/run/lock/vpsfree-workspace-portal-substrate.lock' => ['', 0o600]
      }
      paths.each do |relative, (content, mode)|
        path = rooted(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        File.chmod(mode, path)
      end
      before = snapshot(paths.keys.map { |path| rooted(dir, path) })
      migration_journal = File.join(dir, 'host-journal.json')

      run_helper(
        'preflight', '--direction', 'forward', '--scope', 'host',
        '--host-root', dir, '--journal', migration_journal
      )

      refute_path_exists(migration_journal)
      assert_equal(before, snapshot(paths.keys.map { |path| rooted(dir, path) }))
    end
  end

  def test_host_migration_preserves_credentials_tls_metadata_and_reverse
    Dir.mktmpdir do |dir|
      paths = {
        '/var/lib/vpsfree-workspace-portal-password/password' => ["password\n", 0o600],
        '/var/lib/vpsfree-workspace-portal-auth/htpasswd' => ["user:hash\n", 0o640],
        '/var/lib/vpsfree-workspace-pki/ca.key' => ["key\n", 0o600],
        '/var/lib/vpsfree-workspace-pki/ca.pem' => ["ca\n", 0o644],
        '/var/lib/vpsfree-workspace-portal-tls/releases/selected/server.pem' => ["cert\n", 0o644],
        '/var/lib/vpsfree-workspace-portal-tls/releases/selected/server.key' => ["leaf-key\n", 0o600],
        '/var/lib/vpsfree-workspace-portal-public/ca.pem' => ["public\n", 0o644],
        '/run/vpsfree-workspace-router/router.sock.marker' => ["socket\n", 0o600],
        '/run/lock/vpsfree-workspace-portal-substrate.lock' => ['', 0o600]
      }
      paths.each do |relative, (content, mode)|
        path = rooted(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        File.chmod(mode, path)
      end
      selected = rooted(dir, '/var/lib/vpsfree-workspace-portal-tls/current')
      File.symlink('releases/selected', selected)
      snapshot_paths = paths.keys.map { |path| rooted(dir, path) }
      snapshot_paths << selected
      before = snapshot(snapshot_paths)
      migration_journal = File.join(dir, 'host-journal.json')
      arguments = ['--scope', 'host', '--yes', '--host-root', dir, '--journal', migration_journal]

      run_helper('forward', *arguments)
      assert_equal("password\n", File.read(rooted(dir, '/var/lib/dev-workspaces/password/password')))
      assert_equal(0o600, File.stat(rooted(dir, '/var/lib/dev-workspaces/password/password')).mode & 0o777)
      assert_equal('releases/selected', File.readlink(rooted(dir, '/var/lib/dev-workspaces/tls/current')))
      assert_path_exists(rooted(dir, '/run/lock/dev-workspace-substrate.lock'))

      before_preflight = File.binread(migration_journal)
      run_helper(
        'preflight', '--direction', 'reverse', '--scope', 'host',
        '--host-root', dir, '--journal', migration_journal
      )
      assert_equal(before_preflight, File.binread(migration_journal))
      run_helper('reverse', *arguments)
      assert_equal(before, snapshot(snapshot_paths))
    end
  end

  def test_user_migration_hands_live_tmux_server_between_systemd_keepers
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      old_socket = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/tmux.sock')
      new_socket = File.join(fixture.fetch(:runtime), 'dev-workspaces/site/tmux.sock')
      old_worktree = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/worktree')
      new_worktree = File.join(fixture.fetch(:runtime), 'dev-workspaces/site/worktree')
      opaque_thread = 'thread-VPSFREE_DEV_SESSION_SLUG'
      live = prepare_live_tmux(fixture, codex_thread: opaque_thread)
      window = live.fetch(:window)
      tmux(old_socket, 'set-option', '-w', '-t', window, '@vpsfree_dev_session_window', 'shell')
      tmux(old_socket, 'set-option', '-w', '-t', window, '@vpsfree_dev_session_worktree', old_worktree)
      contract = JSON.parse(File.read(ENV.fetch('DEV_WORKSPACE_RUNTIME_CONTRACT')))
      worktree_option = contract.fetch('tmuxMetadata').fetch('windowOptions').find do |option|
        option.fetch('name') == '@dev_session_worktree'
      end
      worktree_option['path'] = true
      contract_path = File.join(dir, 'runtime-contract.json')
      File.write(contract_path, JSON.pretty_generate(contract) + "\n")
      systemctl, environment, first_keeper = fake_systemctl(dir, fixture.fetch(:runtime), 'site')
      environment['PATH'] = '/empty' if ENV['MIGRATION_HELPER']
      environment['HOME'] = fixture.fetch(:home)
      environment['DEV_WORKSPACE_RUNTIME_CONTRACT'] = contract_path
      arguments = user_arguments(fixture) + ['--systemctl-command', systemctl]

      run_helper('forward', *arguments, env: environment)

      wait_for_exit(first_keeper)
      assert(File.socket?(new_socket))
      assert_equal('1', tmux(new_socket, 'show-options', '-qv', '-t', 'session', '@dev_session').strip)
      assert_equal('session', tmux(new_socket, 'show-options', '-qv', '-t', 'session', '@dev_session_slug').strip)
      assert_equal('shell', tmux(new_socket, 'show-options', '-w', '-qv', '-t', window,
                                 '@dev_session_window').strip)
      assert_equal(new_worktree, tmux(new_socket, 'show-options', '-w', '-qv', '-t', window,
                                      '@dev_session_worktree').strip)
      assert_equal(
        'DEV_SESSION_SLUG=session',
        tmux(new_socket, 'show-environment', '-t', 'session', 'DEV_SESSION_SLUG').strip
      )
      migrated_authority = File.join(fixture.fetch(:runtime), 'dev-workspaces/site/authority/session.json')
      content = File.read(migrated_authority)
      authority = JSON.parse(content)
      assert_includes(content, File.join(fixture.fetch(:runtime), 'dev-workspaces/site/app-server.sock'))
      refute_includes(content, 'vpsfree-workspaces')
      assert_equal(opaque_thread, authority.fetch('codex_thread_id'))
      assert_equal(
        old_socket,
        tmux(new_socket, 'display-message', '-p', '-t', 'session:', '#{socket_path}').strip
      )
      assert_equal(
        authority.fetch('codex_socket_path'),
        tmux(new_socket, 'show-options', '-qv', '-t', 'session', '@dev_session_codex_socket').strip
      )
      assert_equal(
        opaque_thread,
        tmux(new_socket, 'show-options', '-qv', '-t', 'session', '@dev_session_codex_thread').delete_suffix("\n")
      )
      assert_equal(
        new_socket,
        tmux_environment_value(new_socket, 'session', 'DEV_SESSION_TMUX_SOCKET')
      )
      assert_equal(
        File.dirname(migrated_authority),
        tmux_environment_value(new_socket, 'session', 'DEV_SESSION_AUTHORITY_DIR')
      )
      assert_equal(
        File.join(fixture.fetch(:new_state), 'codex/current/bin/codex'),
        tmux_environment_value(new_socket, 'session', 'DEV_SESSION_CODEX')
      )
      assert_equal(
        ' required-VPSFREE_DEV_SESSION_SLUG ',
        tmux_environment_value(new_socket, 'session', 'DEV_SESSION_REQUIRE_RUNTIME')
      )
      assert_equal('', tmux_environment_value(new_socket, 'session', 'DEV_SESSION_LIFECYCLE_OPERATION'))
      assert_equal(
        "-DEV_SESSION_URL\n",
        tmux(new_socket, 'show-environment', '-t', 'session', 'DEV_SESSION_URL')
      )
      data = journal(fixture)
      data.fetch('tmux').fetch('sessions').first.fetch('environment').first << 'extra-field'
      write_journal(fixture, data)
      error = run_helper_failure(
        'preflight', '--direction', 'reverse',
        *arguments.reject { |argument| argument == '--yes' }, env: environment
      )
      assert_includes(error, 'invalid tmux session')
      data.fetch('tmux').fetch('sessions').first.fetch('environment').first.pop
      write_journal(fixture, data)
      tmux(new_socket, 'set-option', '-t', 'session', '@vpsfree_dev_session_slug', 'session')
      tmux(new_socket, 'set-option', '-w', '-t', window, '@vpsfree_dev_session_window', 'shell')
      tmux(new_socket, 'set-option', '-w', '-t', window, '@vpsfree_dev_session_worktree', old_worktree)
      tmux(new_socket, 'set-environment', '-t', 'session', 'VPSFREE_DEV_SESSION_SLUG', 'session')
      data = journal(fixture)
      data['state'] = 'prepared'
      data.fetch('tmux').fetch('sessions').each { |record| record['state'] = 'pending' }
      write_journal(fixture, data)
      run_helper('forward', *arguments, env: environment)
      assert_empty(tmux(new_socket, 'show-options', '-qv', '-t', 'session',
                        '@vpsfree_dev_session_slug'))
      assert_empty(tmux(new_socket, 'show-options', '-w', '-qv', '-t', window,
                        '@vpsfree_dev_session_window'))
      assert_empty(tmux(new_socket, 'show-options', '-w', '-qv', '-t', window,
                        '@vpsfree_dev_session_worktree'))
      _output, _error, old_environment = Open3.capture3(
        'tmux', '-S', new_socket, 'show-environment', '-t', 'session',
        'VPSFREE_DEV_SESSION_SLUG'
      )
      refute(old_environment.success?)
      refute_path_exists(File.join(fixture.fetch(:runtime), 'systemd/user/workspace-tmux@.service.d',
                                   'vpsfree-dev-workspace-migration.conf'))
      assert_path_exists(File.join(fixture.fetch(:runtime), 'systemd/user'))

      second_keeper = spawn_fake_keeper(environment.fetch('FAKE_SYSTEMCTL_STATE'))
      activate_final_profile(fixture)
      tmux(new_socket, 'set-option', '-t', 'session', '@vpsfree_dev_session_slug', 'session')
      tmux(new_socket, 'set-option', '-w', '-t', window, '@vpsfree_dev_session_window', 'shell')
      tmux(new_socket, 'set-option', '-w', '-t', window, '@vpsfree_dev_session_worktree', old_worktree)
      tmux(new_socket, 'set-environment', '-t', 'session', 'VPSFREE_DEV_SESSION_SLUG', 'session')
      run_helper('reverse', *arguments, env: environment)

      wait_for_exit(second_keeper)
      assert(File.socket?(old_socket))
      assert_equal(
        'session',
        tmux(old_socket, 'show-options', '-qv', '-t', 'session', '@vpsfree_dev_session_slug').strip
      )
      assert_equal(
        'session',
        tmux_environment_value(old_socket, 'session', 'VPSFREE_DEV_SESSION_SLUG')
      )
      assert_equal(
        old_socket,
        tmux_environment_value(old_socket, 'session', 'VPSFREE_DEV_SESSION_TMUX_SOCKET')
      )
      assert_equal(
        File.join(File.dirname(old_socket), 'app-server.sock'),
        tmux(old_socket, 'show-options', '-qv', '-t', 'session',
             '@vpsfree_dev_session_codex_socket').strip
      )
      assert_equal('shell', tmux(old_socket, 'show-options', '-w', '-qv', '-t', window,
                                 '@vpsfree_dev_session_window').strip)
      assert_equal(old_worktree, tmux(old_socket, 'show-options', '-w', '-qv', '-t', window,
                                      '@vpsfree_dev_session_worktree').strip)
      assert_equal(
        opaque_thread,
        tmux(old_socket, 'show-options', '-qv', '-t', 'session',
             '@vpsfree_dev_session_codex_thread').delete_suffix("\n")
      )
      assert_equal(
        ' required-VPSFREE_DEV_SESSION_SLUG ',
        tmux_environment_value(old_socket, 'session', 'VPSFREE_DEV_SESSION_REQUIRE_RUNTIME')
      )
      assert_equal('', tmux_environment_value(old_socket, 'session',
                                              'VPSFREE_DEV_SESSION_LIFECYCLE_OPERATION'))
      assert_equal(
        "-VPSFREE_DEV_SESSION_URL\n",
        tmux(old_socket, 'show-environment', '-t', 'session', 'VPSFREE_DEV_SESSION_URL')
      )
      assert_empty(tmux(old_socket, 'show-options', '-qv', '-t', 'session', '@dev_session_slug'))
      assert_empty(tmux(old_socket, 'show-options', '-w', '-qv', '-t', window,
                        '@dev_session_window'))
      assert_empty(tmux(old_socket, 'show-options', '-w', '-qv', '-t', window,
                        '@dev_session_worktree'))
      _output, _error, new_environment = Open3.capture3(
        'tmux', '-S', old_socket, 'show-environment', '-t', 'session', 'DEV_SESSION_SLUG'
      )
      refute(new_environment.success?)
    ensure
      [new_socket, old_socket].compact.each do |socket|
        Open3.capture3('tmux', '-S', socket, 'kill-server') if File.socket?(socket)
      end
      [first_keeper, second_keeper].compact.each { |pid| terminate(pid) }
    end
  end

  def test_occupied_target_symlink_and_mount_tree_are_rejected
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      FileUtils.mkdir_p(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
      error = run_helper_failure('forward', *user_arguments(fixture))
      assert_includes(error, 'migration target already exists')
      assert_path_exists(fixture.fetch(:old_config))

      FileUtils.rm_rf(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
      FileUtils.rm_rf(fixture.fetch(:old_config))
      File.symlink(dir, fixture.fetch(:old_config))
      alternate_journal = File.join(dir, 'symlink-journal.json')
      fixture[:journal] = alternate_journal
      error = run_helper_failure('forward', *user_arguments(fixture))
      assert_includes(error, 'migration source is a symlink')

      runner = VpsfreeDevWorkspaceMigration::Runner.new([
        'status', '--scope', 'host', '--host-root', dir,
        '--journal', File.join(dir, 'missing.json')
      ])
      error = assert_raises(VpsfreeDevWorkspaceMigration::Error) do
        runner.send(:reject_mount_tree, '/proc')
      end
      assert_includes(error.message, 'mount point')
    end
  end

  def test_malformed_authority_and_unsafe_portal_are_rejected_before_moves
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      write_authority(fixture, "{not-json\n")
      error = run_helper_failure('forward', *user_arguments(fixture))
      assert_includes(error, 'malformed machine state')
      assert_path_exists(fixture.fetch(:old_config))

      write_authority(fixture)
      File.unlink(fixture.fetch(:portal))
      File.symlink('/dev/null', fixture.fetch(:portal))
      fixture[:journal] = File.join(dir, 'unsafe-portal-journal.json')
      error = run_helper_failure('forward', *user_arguments(fixture))
      assert_includes(error, 'unsafe rewrite source')
      assert_path_exists(fixture.fetch(:old_config))
    end
  end

  def test_runtime_authority_contract_is_enforced_before_moves
    invalid = {
      'missing schema' => ->(record) { record.delete('schema') },
      'wrong schema' => ->(record) { record['schema'] = 2 },
      'wrong slug' => ->(record) { record['slug'] = 'other' },
      'wrong workspace' => ->(record) { record['workspace'] = '/other' },
      'relative socket' => ->(record) { record['tmux_socket'] = 'tmux.sock' },
      'invalid session id' => ->(record) { record['tmux_session_id'] = '1' },
      'floating schema' => ->(record) { record['schema'] = 1.0 },
      'numeric session id' => ->(record) { record['tmux_session_id'] = 1 },
      'numeric tmux identity' => ->(record) { record['tmux_identity'] = 10**63 },
      'numeric client version' => ->(record) { record['codex_client_version'] = 0.1534 },
      'boolean client version' => ->(record) { record['codex_client_version'] = true },
      'partial Codex identity' => ->(record) { record.delete('codex_client_version') },
      'unknown field' => ->(record) { record['extra'] = true }
    }
    invalid.each do |name, mutate|
      Dir.mktmpdir do |dir|
        fixture = prepare_user_tree(dir)
        record = authority_record(fixture)
        mutate.call(record)
        write_authority(fixture, JSON.generate(record))

        error = run_helper_failure('forward', *user_arguments(fixture))

        assert_includes(error, 'runtime authority', name)
        assert_user_tree_unmoved(fixture)
      end
    end

    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      write_authority(fixture, "#{JSON.generate(authority_record(fixture))}\n{}")

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'malformed machine state')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_runtime_authority_metadata_is_enforced_before_moves
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      write_authority(fixture)
      File.chmod(0o644, fixture.fetch(:authority))

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'unsafe metadata')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_machine_rewrites_change_only_owned_path_fields
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      runner = VpsfreeDevWorkspaceMigration::Runner.new([
        'status', '--scope', 'user', '--home', fixture.fetch(:home),
        '--runtime-dir', fixture.fetch(:runtime),
        '--workspace-root', fixture.fetch(:workspace), '--journal', fixture.fetch(:journal)
      ])
      opaque = 'thread-VPSFREE_DEV_SESSION_SLUG'
      authority = authority_record(fixture).merge('codex_thread_id' => opaque)
      original_authority = JSON.pretty_generate(authority) + "\n"
      authority_path = File.join(
        fixture.fetch(:runtime), 'dev-workspaces/site/authority/session.json'
      )
      rewritten_authority = runner.send(
        :rewrite_machine_state, authority_path, original_authority
      )
      parsed_authority = JSON.parse(rewritten_authority)
      assert_equal(opaque, parsed_authority.fetch('codex_thread_id'))
      assert_includes(parsed_authority.fetch('tmux_socket'), '/dev-workspaces/')
      assert_includes(parsed_authority.fetch('codex_socket_path'), '/dev-workspaces/')

      sibling = File.join(fixture.fetch(:home), '.local/state/vpsfree-workspaces-backup/bin/codex')
      assert_equal(sibling, runner.send(:replace_path_namespaces, sibling))
      embedded = "prefix-#{authority.fetch('codex_socket_path')}"
      assert_equal(embedded, runner.send(:replace_path_namespaces, embedded))
      old_state = File.join(fixture.fetch(:home), '.local/state/vpsfree-workspaces')
      new_state = File.join(fixture.fetch(:home), '.local/state/dev-workspaces')
      assert_equal(new_state, runner.send(:replace_path_namespaces, old_state))
      assert_equal(
        File.join(new_state, 'profile/bin/codex'),
        runner.send(:replace_path_namespaces, File.join(old_state, 'profile/bin/codex'))
      )

      old_socket = authority.fetch('codex_socket_path')
      portal = <<~YAML
        ---
        schema: 1
        codex:
          thread_id: #{opaque}
          socket_path: #{old_socket.inspect}
          client_version: 0.153.4
        artifacts:
        - label: VPSFREE_DEV_SESSION_SLUG
          path: evidence.txt
      YAML
      rewritten_portal = runner.send(:rewrite_machine_state, fixture.fetch(:portal), portal)
      assert_includes(rewritten_portal, "thread_id: #{opaque}\n")
      assert_includes(rewritten_portal, "label: VPSFREE_DEV_SESSION_SLUG\n")
      assert_includes(rewritten_portal, '/dev-workspaces/site/app-server.sock')
      refute_includes(rewritten_portal, old_socket)

      registry_path = File.join(fixture.fetch(:home), '.config/dev-workspaces/registry.json')
      registry = JSON.generate('schema' => 1, 'workspaces' => [{ 'name' => opaque }])
      assert_same(registry, runner.send(:rewrite_machine_state, registry_path, registry))
    end
  end

  def test_runtime_authority_validator_uses_the_generic_shared_corpus
    manifest_path = ENV.fetch('RUNTIME_AUTHORITY_CORPUS')
    manifest = JSON.parse(File.binread(manifest_path))
    unless manifest.is_a?(Hash) && manifest.keys.sort == %w[invalid schema valid] &&
           manifest['schema'] == 1 && manifest['valid'].is_a?(Array) &&
           manifest['invalid'].is_a?(Array) && !manifest['valid'].empty? &&
           !manifest['invalid'].empty?
      flunk 'generic runtime-authority corpus manifest is incomplete'
    end
    names = manifest.fetch('valid') + manifest.fetch('invalid')
    unless names.all? { |name| name.is_a?(String) && File.basename(name) == name && name.end_with?('.json') } &&
           names.uniq.length == names.length
      flunk 'generic runtime-authority corpus manifest has invalid fixture names'
    end
    inventory = Dir.glob(File.join(File.dirname(manifest_path), 'runtime-authority-*.json'))
                   .map { |path| File.basename(path) }
                   .reject { |name| name == File.basename(manifest_path) }
                   .sort
    assert_equal(inventory, names.sort, 'generic runtime-authority corpus omits fixtures')

    runner = VpsfreeDevWorkspaceMigration::Runner.new([
      'status', '--scope', 'user', '--workspace-root', '/srv/workspace',
      '--journal', '/tmp/migration.json'
    ])
    directory = File.dirname(manifest_path)
    manifest.fetch('valid').each do |name|
      path = File.join(directory, name)
      contents = File.binread(path)
      record = JSON.parse(contents)
      if record['state'] == 'ready'
        runner.send(:validate_runtime_authority!, record, ['site', 'example'], path, contents.bytesize)
      else
        assert_raises(VpsfreeDevWorkspaceMigration::Error, path) do
          runner.send(:validate_runtime_authority!, record, ['site', 'example'], path, contents.bytesize)
        end
      end
    end
    manifest.fetch('invalid').each do |name|
      path = File.join(directory, name)
      contents = File.binread(path)
      record = JSON.parse(contents)
      assert_raises(VpsfreeDevWorkspaceMigration::Error, path) do
        runner.send(:validate_runtime_authority!, record, ['site', 'example'], path, contents.bytesize)
      end
    end
  end

  def test_runtime_authority_paths_accept_the_complete_supported_slug_domain
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      runner = VpsfreeDevWorkspaceMigration::Runner.new([
        'status', '--scope', 'user', '--runtime-dir', fixture.fetch(:runtime),
        '--workspace-root', fixture.fetch(:workspace), '--journal', fixture.fetch(:journal)
      ])
      slugs = ['Upper_case', "A_#{'x' * 200}"]
      slugs.each do |slug|
        authority = File.join(fixture.fetch(:runtime), 'dev-workspaces/site/authority', "#{slug}.json")
        portal = File.join(fixture.fetch(:workspace), 'archive', slug, 'portal.yml')
        assert_equal(['site', slug], runner.send(:runtime_authority_identity, authority))
        assert(runner.send(:rewrite_path_allowed?, authority))
        assert(runner.send(:rewrite_path_allowed?, portal))
        refute(runner.send(:rewrite_path_allowed?, "#{authority}/extra"))
        refute(runner.send(:rewrite_path_allowed?, "#{portal}/extra"))
      end
    end
  end

  def test_runtime_authority_must_match_the_captured_live_tmux_session
    mutations = {
      'wrong valid socket' => ->(record, _live) { record['tmux_socket'] = '/run/other/tmux.sock' },
      'wrong session id' => ->(record, _live) { record['tmux_session_id'] = '$99' },
      'session name' => lambda { |_record, live|
        tmux(live.fetch(:socket), 'rename-session', '-t', 'session', 'Other_session')
      },
      'workspace' => lambda { |_record, live|
        tmux(live.fetch(:socket), 'set-environment', '-t', 'session',
             'VPSFREE_DEV_SESSION_WORKSPACE', '/other/workspace')
      },
      'missing tmux identity' => ->(record, _live) { record.delete('tmux_identity') },
      'tmux identity' => ->(record, _live) { record['tmux_identity'] = 'b' * 64 },
      'Codex thread' => ->(record, _live) { record['codex_thread_id'] = 'other-thread' }
    }
    mutations.each do |name, mutate|
      Dir.mktmpdir do |dir|
        fixture = prepare_user_tree(dir)
        live = prepare_live_tmux(fixture)
        record = live.fetch(:authority).dup
        mutate.call(record, live)
        write_authority(fixture, JSON.generate(record))

        error = run_helper_failure(
          'preflight', *user_arguments(fixture).reject { |argument| argument == '--yes' }
        )

        assert_includes(error, 'runtime authority', name)
        refute_path_exists(fixture.fetch(:journal))
        assert_path_exists(fixture.fetch(:old_config))
      ensure
        Open3.capture3('tmux', '-S', live[:socket], 'kill-server') if live && File.socket?(live[:socket])
      end
    end
  end

  def test_forward_and_reverse_moves_sync_both_parents_before_journaling
    Dir.mktmpdir do |dir|
      source_parent = File.join(dir, 'old')
      target_parent = File.join(dir, 'new')
      FileUtils.mkdir_p([source_parent, target_parent])
      source = File.join(source_parent, 'state')
      target = File.join(target_parent, 'state')
      File.write(source, 'state')
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['status', '--scope', 'user', '--journal', File.join(dir, 'journal.json')]
      )
      move = runner.send(:inspect_move, source, target)
      journal = { 'moves' => [move] }
      synced = []
      saved = false
      inject = true
      runner.define_singleton_method(:fsync_directory) do |path|
        synced << path
        if inject
          inject = false
          raise VpsfreeDevWorkspaceMigration::Error, 'injected directory sync failure'
        end
      end
      runner.define_singleton_method(:save_journal) do |_journal|
        required = [source_parent, target_parent]
        raise 'journal advanced before both rename parents were synced' unless (required - synced).empty?

        saved = true
      end

      assert_raises(VpsfreeDevWorkspaceMigration::Error) { runner.send(:apply_moves, journal) }
      assert_equal('pending', move.fetch('state'))
      refute(saved)
      synced.clear
      runner.send(:apply_moves, journal)
      assert_equal('moved', move.fetch('state'))
      assert(saved)

      synced.clear
      saved = false
      inject = true
      assert_raises(VpsfreeDevWorkspaceMigration::Error) { runner.send(:reverse_moves, journal) }
      assert_equal('moved', move.fetch('state'))
      refute(saved)
      synced.clear
      runner.send(:reverse_moves, journal)
      assert_equal('reversed', move.fetch('state'))
      assert(saved)
      assert_path_exists(target_parent)
    end
  end

  def test_reverse_removes_only_recorded_parents_and_retries_after_cleanup
    Dir.mktmpdir do |dir|
      source_parent = File.join(dir, 'old')
      target_parent = File.join(dir, 'new', 'nested')
      FileUtils.mkdir_p(source_parent)
      source = File.join(source_parent, 'state')
      target = File.join(target_parent, 'state')
      File.write(source, 'state')
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['status', '--scope', 'user', '--home', dir, '--journal', File.join(dir, 'journal.json')]
      )
      move = runner.send(:inspect_move, source, target)
      assert_equal([target_parent, File.dirname(target_parent)], move.fetch('createdParents'))
      journal = { 'moves' => [move] }
      runner.define_singleton_method(:save_journal) { |_journal| nil }
      runner.send(:apply_moves, journal)
      assert_path_exists(target)

      inject = true
      runner.define_singleton_method(:fsync_directory) do |path|
        if inject && path == dir
          inject = false
          raise VpsfreeDevWorkspaceMigration::Error, 'injected cleanup sync failure'
        end
      end
      assert_raises(VpsfreeDevWorkspaceMigration::Error) { runner.send(:reverse_moves, journal) }
      assert_equal('moved', move.fetch('state'))
      assert_path_exists(source)
      refute_path_exists(File.join(dir, 'new'))

      runner.send(:reverse_moves, journal)
      assert_equal('reversed', move.fetch('state'))
      assert_path_exists(source)
      refute_path_exists(File.join(dir, 'new'))
    end
  end

  def test_host_preflight_rejects_unsafe_destination_ancestors_without_mutation
    Dir.mktmpdir do |dir|
      source = rooted(dir, '/var/lib/vpsfree-workspace-portal-password')
      target_root = rooted(dir, '/var/lib/dev-workspaces')
      FileUtils.mkdir_p(source)
      File.write(File.join(source, 'password'), "secret\n")
      FileUtils.mkdir_p(target_root)
      File.chmod(0o777, target_root)
      journal = File.join(dir, 'host-journal.json')

      error = run_helper_failure(
        'preflight', '--scope', 'host', '--host-root', dir, '--journal', journal
      )

      assert_includes(error, 'unsafe ownership or mode')
      assert_path_exists(File.join(source, 'password'))
      refute_path_exists(File.join(target_root, 'password'))
      refute_path_exists(journal)
    end
  end

  def test_symlinked_portal_ancestor_is_rejected_before_mutation
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      session_directory = File.dirname(fixture.fetch(:portal))
      actual_directory = File.join(dir, 'redirected-session')
      File.rename(session_directory, actual_directory)
      File.symlink(actual_directory, session_directory)

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'unsafe symlink in path')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_wrong_owned_portal_is_rejected_before_mutation
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['forward', *user_arguments(fixture)],
        out: StringIO.new,
        err: StringIO.new
      )
      portal = fixture.fetch(:portal)
      runner.define_singleton_method(:rewrite_source_owned?) do |path|
        path != portal
      end

      error = assert_raises(VpsfreeDevWorkspaceMigration::Error) { runner.run }

      assert_includes(error.message, 'rewrite source is not owned by the current user')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_invalid_registry_path_types_are_rejected_before_mutation
    %i[directory dangling_symlink directory_symlink].each do |type|
      Dir.mktmpdir do |dir|
        fixture = prepare_user_tree(dir)
        registry = File.join(fixture.fetch(:old_config), 'registry.json')
        File.unlink(registry)
        case type
        when :directory
          FileUtils.mkdir_p(registry)
        when :dangling_symlink
          File.symlink(File.join(dir, 'missing-registry'), registry)
        when :directory_symlink
          target = File.join(dir, 'registry-directory')
          FileUtils.mkdir_p(target)
          File.symlink(target, registry)
        end

        error = run_helper_failure('forward', *user_arguments(fixture))

        assert_includes(error, 'unsafe rewrite source')
        assert_user_tree_unmoved(fixture)
      end
    end
  end

  def test_all_moves_are_preflighted_before_the_first_rename
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['forward', *user_arguments(fixture)],
        out: StringIO.new,
        err: StringIO.new
      )
      runner.send(:save_journal, runner.send(:build_journal))
      File.write(File.join(fixture.fetch(:old_state), 'late-change'), "changed\n")

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'migration tree changed since preparation')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_move_source_ancestors_are_preflighted_before_mutation
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['forward', *user_arguments(fixture)],
        out: StringIO.new,
        err: StringIO.new
      )
      runner.send(:save_journal, runner.send(:build_journal))
      config_parent = File.dirname(fixture.fetch(:old_config))
      real_parent = File.join(dir, 'real-config-parent')
      File.rename(config_parent, real_parent)
      File.symlink(real_parent, config_parent)

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'unsafe symlink in path')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_transition_lock_is_required_and_profile_is_verified_after_locking
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      File.unlink(File.join(fixture.fetch(:old_state), 'transition.lock'))

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'workspace transition lock is missing')
      assert_user_tree_unmoved(fixture)
    end

    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['forward', *user_arguments(fixture)],
        out: StringIO.new,
        err: StringIO.new
      )
      final = make_profile_package(
        dir,
        'racing-final-package',
        namespace: 'dev-workspaces',
        router_socket: '/run/dev-workspaces/router.sock',
        activation_aliases: []
      )
      runner.define_singleton_method(:lock_mutation_files) do |journal, forward:|
        locks = super(journal, forward:)
        state = fixture.fetch(:old_state)
        File.symlink(final, File.join(state, 'profile-2-link'))
        File.unlink(File.join(state, 'profile'))
        File.symlink('profile-2-link', File.join(state, 'profile'))
        locks
      end

      error = assert_raises(VpsfreeDevWorkspaceMigration::Error) { runner.run }

      assert_includes(error.message, 'no longer selects the compatibility package')
      assert_user_tree_unmoved(fixture)
    end
  end

  def test_failed_preparation_leaves_no_stale_journal_and_can_be_retried
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      transition_lock = File.join(fixture.fetch(:old_state), 'transition.lock')
      File.unlink(transition_lock)

      error = run_helper_failure('forward', *user_arguments(fixture))

      assert_includes(error, 'workspace transition lock is missing')
      refute_path_exists(fixture.fetch(:journal))
      File.write(transition_lock, '')
      File.chmod(0o600, transition_lock)

      run_helper('forward', *user_arguments(fixture))
      assert_equal('forward', journal(fixture).fetch('state'))
    end
  end

  def test_forward_and_reverse_retry_accept_completed_durable_boundaries
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      data = journal(fixture)
      move = data.fetch('moves').find { |entry| entry.fetch('source') == fixture.fetch(:old_config) }
      data['state'] = 'prepared'
      move['state'] = 'pending'
      write_journal(fixture, data)

      run_helper('forward', *user_arguments(fixture))
      assert_equal('forward', journal(fixture).fetch('state'))

      data = journal(fixture)
      rewrite = data.fetch('rewrites').find { |entry| entry.fetch('path') == fixture.fetch(:portal) }
      File.binwrite(rewrite.fetch('path'), rewrite.fetch('original').unpack1('m0'))
      activate_final_profile(fixture)
      run_helper('reverse', *user_arguments(fixture))
      assert_equal('reversed', journal(fixture).fetch('state'))
      assert_path_exists(fixture.fetch(:portal))
    end
  end

  def test_reverse_preflights_every_rewrite_before_mutation
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      data = journal(fixture)
      rewrites = data.fetch('rewrites')
      before = rewrites.to_h { |rewrite| [rewrite.fetch('path'), File.binread(rewrite.fetch('path'))] }
      late = rewrites.first.fetch('path')
      File.binwrite(late, before.fetch(late) + "\n")
      activate_final_profile(fixture)

      error = run_helper_failure('reverse', *user_arguments(fixture))

      assert_includes(error, 'rewrite source changed after journal preparation')
      before.each do |path, contents|
        next if path == late

        assert_equal(contents, File.binread(path), path)
      end
      refute_path_exists(fixture.fetch(:old_config))
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
      assert_equal('forward', journal(fixture).fetch('state'))
      assert(journal(fixture).fetch('rewrites').all? { |rewrite| rewrite.fetch('state') == 'applied' })
    end
  end

  def test_reverse_preflight_rejects_new_authorities_and_portal_manifests
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      activate_final_profile(fixture)
      arguments = [
        'preflight', '--direction', 'reverse',
        *user_arguments(fixture).reject { |argument| argument == '--yes' }
      ]
      authority = File.join(
        fixture.fetch(:runtime), 'dev-workspaces/site/authority/late.json'
      )
      File.write(authority, JSON.generate('state' => 'ready'))

      error = run_helper_failure(*arguments)
      assert_includes(error, 'rewrite inventory changed')
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))

      File.unlink(authority)
      portal = File.join(fixture.fetch(:workspace), 'work/late/portal.yml')
      FileUtils.mkdir_p(File.dirname(portal))
      File.write(portal, "schema: 1\nslug: late\n")

      error = run_helper_failure(*arguments)
      assert_includes(error, 'rewrite inventory changed')
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
    end
  end

  def test_reverse_preflight_rejects_new_tmux_sessions_and_windows
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      old_socket = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/tmux.sock')
      new_socket = File.join(fixture.fetch(:runtime), 'dev-workspaces/site/tmux.sock')
      tmux(old_socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
      tmux(old_socket, 'new-session', '-d', '-s', 'migration-test')
      systemctl, environment, first_keeper = fake_systemctl(dir, fixture.fetch(:runtime), 'site')
      environment['PATH'] = '/empty' if ENV['MIGRATION_HELPER']
      environment['HOME'] = fixture.fetch(:home)
      forward_arguments = user_arguments(fixture) + ['--systemctl-command', systemctl]
      run_helper('forward', *forward_arguments, env: environment)
      wait_for_exit(first_keeper)
      first_keeper = nil
      activate_final_profile(fixture)
      preflight_arguments = [
        'preflight', '--direction', 'reverse',
        *forward_arguments.reject { |argument| argument == '--yes' }
      ]

      tmux(new_socket, 'new-session', '-d', '-s', 'late-session')
      error = run_helper_failure(*preflight_arguments, env: environment)
      assert_includes(error, 'tmux session inventory changed')
      tmux(new_socket, 'kill-session', '-t', 'late-session')

      tmux(new_socket, 'new-window', '-d', '-t', 'migration-test', '-n', 'late-window')
      error = run_helper_failure(*preflight_arguments, env: environment)
      assert_includes(error, 'tmux window inventory changed')
      tmux(new_socket, 'kill-window', '-t', 'late-window')

      window = tmux(new_socket, 'list-windows', '-t', 'migration-test', '-F', '#{window_id}').strip
      tmux(new_socket, 'set-option', '-t', 'migration-test', '@dev_session_codex_thread', 'late-thread')
      error = run_helper_failure(*preflight_arguments, env: environment)
      assert_includes(error, 'tmux metadata changed')
      tmux(new_socket, 'set-option', '-qu', '-t', 'migration-test', '@dev_session_codex_thread')

      tmux(new_socket, 'set-option', '-w', '-t', window, '@dev_session_worktree', '/late')
      error = run_helper_failure(*preflight_arguments, env: environment)
      assert_includes(error, 'tmux metadata changed')
      tmux(new_socket, 'set-option', '-w', '-qu', '-t', window, '@dev_session_worktree')

      tmux(new_socket, 'set-environment', '-t', 'migration-test', 'DEV_SESSION_WORK_DIR', '/late')
      error = run_helper_failure(*preflight_arguments, env: environment)
      assert_includes(error, 'tmux metadata changed')
      tmux(new_socket, 'set-environment', '-u', '-t', 'migration-test', 'DEV_SESSION_WORK_DIR')
      assert(File.socket?(new_socket))
      refute(File.socket?(old_socket))
    ensure
      [new_socket, old_socket].compact.each do |socket|
        Open3.capture3('tmux', '-S', socket, 'kill-server') if File.socket?(socket)
      end
      [first_keeper].compact.each { |pid| terminate(pid) }
    end
  end

  def test_reverse_rewrite_preflight_leaves_the_keeper_and_tmux_namespace_untouched
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      old_socket = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/tmux.sock')
      new_socket = File.join(fixture.fetch(:runtime), 'dev-workspaces/site/tmux.sock')
      tmux(old_socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
      tmux(old_socket, 'new-session', '-d', '-s', 'migration-test')
      tmux(old_socket, 'set-option', '-t', 'migration-test', '@vpsfree_dev_session_slug', 'session')
      tmux(old_socket, 'set-environment', '-t', 'migration-test', 'VPSFREE_DEV_SESSION_SLUG', 'session')
      systemctl, environment, first_keeper = fake_systemctl(dir, fixture.fetch(:runtime), 'site')
      environment['PATH'] = '/empty' if ENV['MIGRATION_HELPER']
      environment['HOME'] = fixture.fetch(:home)
      arguments = user_arguments(fixture) + ['--systemctl-command', systemctl]
      run_helper('forward', *arguments, env: environment)
      wait_for_exit(first_keeper)
      first_keeper = nil
      second_keeper = spawn_fake_keeper(environment.fetch('FAKE_SYSTEMCTL_STATE'))
      data = journal(fixture)
      late = data.fetch('rewrites').first.fetch('path')
      File.binwrite(late, File.binread(late) + "\n")
      activate_final_profile(fixture)

      error = run_helper_failure('reverse', *arguments, env: environment)

      assert_includes(error, 'rewrite source changed after journal preparation')
      Process.kill(0, second_keeper)
      assert(File.socket?(new_socket))
      refute(File.socket?(old_socket))
      assert_equal(
        'session',
        tmux(new_socket, 'show-options', '-qv', '-t', 'migration-test', '@dev_session_slug').strip
      )
      assert_equal(
        'DEV_SESSION_SLUG=session',
        tmux(new_socket, 'show-environment', '-t', 'migration-test', 'DEV_SESSION_SLUG').strip
      )
      refute_path_exists(fixture.fetch(:old_config))
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
    ensure
      [new_socket, old_socket].compact.each do |socket|
        Open3.capture3('tmux', '-S', socket, 'kill-server') if File.socket?(socket)
      end
      [first_keeper, second_keeper].compact.each { |pid| terminate(pid) }
    end
  end

  def test_retry_locks_the_path_that_was_already_renamed
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      data = journal(fixture)
      runtime_move = data.fetch('moves').find do |entry|
        entry.fetch('source') == File.join(fixture.fetch(:runtime), 'vpsfree-workspaces')
      end
      data['state'] = 'prepared'
      write_journal(fixture, data)

      lock_path = File.join(runtime_move.fetch('target'), 'site/authority/retry.lock')
      File.write(lock_path, '')
      File.chmod(0o600, lock_path)
      lock = File.open(lock_path, File::RDWR)
      lock.flock(File::LOCK_EX)

      error = run_helper_failure('forward', *user_arguments(fixture))
      assert_includes(error, 'lifecycle operation is active')
    ensure
      lock&.flock(File::LOCK_UN)
      lock&.close
    end
  end

  def test_active_fallback_lifecycle_lock_blocks_both_directions
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      lock_path = File.join(fixture.fetch(:workspace), 'worktrees/.locks/session.lock')
      FileUtils.mkdir_p(File.dirname(lock_path))
      lock = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
      File.chmod(0o600, lock_path)
      lock.flock(File::LOCK_EX)

      error = run_helper_failure('forward', *user_arguments(fixture))
      assert_includes(error, 'lifecycle operation is active')
      assert_path_exists(fixture.fetch(:old_config))

      lock.flock(File::LOCK_UN)
      run_helper('forward', *user_arguments(fixture))
      activate_final_profile(fixture)
      lock.flock(File::LOCK_EX)
      error = run_helper_failure('reverse', *user_arguments(fixture))
      assert_includes(error, 'lifecycle operation is active')
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
    ensure
      lock&.flock(File::LOCK_UN)
      lock&.close
    end
  end

  def test_journal_is_private_and_cannot_redirect_migration_paths
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      data = journal(fixture)
      data.fetch('moves').first['source'] = File.join(dir, 'victim')
      write_journal(fixture, data)
      error = run_helper_failure('reverse', *user_arguments(fixture))
      assert_includes(error, 'invalid move entry')

      File.chmod(0o644, fixture.fetch(:journal))
      error = run_helper_failure('status', '--scope', 'user', '--journal', fixture.fetch(:journal))
      assert_includes(error, 'owned mode-0600 file')
    end
  end

  def test_oversized_aggregate_journal_is_rejected_before_write
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'migration.json')
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['status', '--scope', 'user', '--journal', path],
        out: StringIO.new,
        err: StringIO.new
      )
      chunk = 'x' * (1024 * 1024)
      data = { 'rewrites' => Array.new(17) { { 'original' => chunk } } }

      error = assert_raises(VpsfreeDevWorkspaceMigration::Error) do
        runner.send(:save_journal, data)
      end

      assert_includes(error.message, 'exceeds 16 MiB')
      refute_path_exists(path)
    end
  end

  def test_journal_reserves_space_for_the_largest_reachable_state
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'migration.json')
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['status', '--scope', 'user', '--journal', path],
        out: StringIO.new,
        err: StringIO.new
      )
      data = {
        'state' => 'forward',
        'moves' => Array.new(10) { { 'state' => 'moved' } },
        'padding' => ''
      }
      content = runner.send(:journal_content, data)
      data['padding'] = 'x' * (VpsfreeDevWorkspaceMigration::MAX_JOURNAL_BYTES - content.bytesize)
      assert_operator(
        runner.send(:journal_content, data).bytesize,
        :<=,
        VpsfreeDevWorkspaceMigration::MAX_JOURNAL_BYTES
      )

      error = assert_raises(VpsfreeDevWorkspaceMigration::Error) do
        runner.send(:save_journal, data)
      end

      assert_includes(error.message, 'reachable state')
      refute_path_exists(path)
    end
  end

  def test_journal_projection_covers_every_declared_persisted_state_field
    runner = VpsfreeDevWorkspaceMigration::Runner.new(
      ['status', '--scope', 'user', '--journal', '/tmp/migration.json'],
      out: StringIO.new,
      err: StringIO.new
    )
    fields = VpsfreeDevWorkspaceMigration::PERSISTED_STATE_FIELDS.values
                                                                  .flat_map(&:keys)
                                                                  .uniq
    data = { 'nested' => [fields.to_h { |name| [name, 'short'] }] }

    projected = runner.send(:maximum_reachable_journal, data)

    assert_equal(
      VpsfreeDevWorkspaceMigration::PERSISTED_STATE_MAXIMUMS,
      projected.fetch('nested').first
    )
  end

  def test_near_limit_journal_can_forward_reverse_and_retry
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      6.times do |index|
        portal = File.join(fixture.fetch(:workspace), "work/near-limit-#{index}/portal.yml")
        FileUtils.mkdir_p(File.dirname(portal))
        File.write(
          portal,
          "schema: 1\nslug: near-limit-#{index}\npadding: #{'x' * 985_000}\n"
        )
      end

      run_helper('forward', *user_arguments(fixture))
      data = journal(fixture)
      runner = VpsfreeDevWorkspaceMigration::Runner.new(
        ['status', '--scope', 'user', '--journal', fixture.fetch(:journal)],
        out: StringIO.new,
        err: StringIO.new
      )
      maximum = runner.send(:journal_content, runner.send(:maximum_reachable_journal, data)).bytesize
      assert_operator(
        maximum,
        :>,
        VpsfreeDevWorkspaceMigration::MAX_JOURNAL_BYTES - (1024 * 1024)
      )

      rewrite = data.fetch('rewrites').find { |entry| entry.fetch('path') == fixture.fetch(:portal) }
      File.binwrite(rewrite.fetch('path'), rewrite.fetch('original').unpack1('m0'))
      activate_final_profile(fixture)
      run_helper('reverse', *user_arguments(fixture))

      assert_equal('reversed', journal(fixture).fetch('state'))
      assert_path_exists(fixture.fetch(:portal))
    end
  end

  def test_tmux_socket_symlinks_are_rejected_before_journaling
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      socket = File.join(fixture.fetch(:runtime), 'unrelated.sock')
      tmux(socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
      linked = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/tmux.sock')
      File.symlink(socket, linked)

      error = run_helper_failure(
        'preflight', *user_arguments(fixture).reject { |argument| argument == '--yes' }
      )

      assert_includes(error, 'tmux socket is unsafe')
      refute_path_exists(fixture.fetch(:journal))
    ensure
      Open3.capture3('tmux', '-S', socket, 'kill-server') if socket && File.socket?(socket)
    end
  end

  def test_tmux_socket_symlinked_ancestors_are_rejected_before_journaling
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      outside = File.join(dir, 'outside')
      FileUtils.mkdir_p(outside)
      socket = File.join(outside, 'tmux.sock')
      tmux(socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
      linked = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/linked')
      File.symlink(outside, linked)

      error = run_helper_failure(
        'preflight', *user_arguments(fixture).reject { |argument| argument == '--yes' }
      )

      assert_includes(error, 'unsafe symlink in path')
      refute_path_exists(fixture.fetch(:journal))
    ensure
      Open3.capture3('tmux', '-S', socket, 'kill-server') if socket && File.socket?(socket)
    end
  end

  def test_tmux_socket_replacement_is_rejected_before_keeper_handoff
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      socket = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/tmux.sock')
      tmux(socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
      failing_systemctl = File.join(dir, 'failing-systemctl')
      File.write(failing_systemctl, "#!#{RbConfig.ruby}\nexit 1\n")
      File.chmod(0o755, failing_systemctl)
      arguments = user_arguments(fixture) + ['--systemctl-command', failing_systemctl]

      error = run_helper_failure('forward', *arguments, env: { 'HOME' => fixture.fetch(:home) })
      assert_includes(error, 'systemctl failed')
      assert_path_exists(fixture.fetch(:journal))

      Open3.capture3('tmux', '-S', socket, 'kill-server')
      File.unlink(socket) if File.socket?(socket)
      tmux(socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
      error = run_helper_failure('forward', *arguments, env: { 'HOME' => fixture.fetch(:home) })

      assert_includes(error, 'tmux socket identity changed')
      assert_path_exists(fixture.fetch(:old_config))
    ensure
      Open3.capture3('tmux', '-S', socket, 'kill-server') if socket && File.socket?(socket)
    end
  end

  def test_reverse_requires_the_recorded_compatibility_generation
    Dir.mktmpdir do |dir|
      fixture = prepare_user_tree(dir)
      run_helper('forward', *user_arguments(fixture))
      activate_final_profile(fixture)
      File.unlink(File.join(fixture.fetch(:new_state), 'profile-1-link'))

      error = run_helper_failure('reverse', *user_arguments(fixture))
      assert_includes(error, 'no previous compatibility generation')
      assert_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
    end
  end

  def test_help_does_not_require_scope
    output = run_helper('--help')
    assert_includes(output, 'Usage:')
  end

  private

  def prepare_user_tree(dir)
    home = File.join(dir, 'home')
    runtime = File.join(dir, 'run')
    workspace = File.join(dir, 'workspace')
    old_config = File.join(home, '.config/vpsfree-workspaces')
    old_state = File.join(home, '.local/state/vpsfree-workspaces')
    old_runtime = File.join(runtime, 'vpsfree-workspaces/site')
    authority_dir = File.join(old_runtime, 'authority')
    portal = File.join(workspace, 'work/session/portal.yml')
    archived_portal = File.join(workspace, 'archive/retained-session/portal.yml')
    FileUtils.mkdir_p([old_config, old_state, authority_dir, File.dirname(portal),
                       File.dirname(archived_portal),
                       File.join(workspace, 'worktrees/.locks')])
    File.write(
      File.join(old_config, 'registry.json'),
      JSON.generate('schema' => 1, 'workspaces' => [{ 'name' => 'site' }])
    )
    File.write(File.join(old_state, 'marker'), "state\n")
    File.write(File.join(old_state, 'transition.lock'), '')
    File.chmod(0o600, File.join(old_state, 'transition.lock'))
    compatibility_package = make_profile_package(
      dir,
      'compatibility-package',
      namespace: 'vpsfree-workspaces',
      router_socket: '/run/vpsfree-workspace-router/router.sock',
      activation_aliases: ['VPSFREE_WORKSPACE_ACTIVATION']
    )
    File.symlink(compatibility_package, File.join(old_state, 'profile-1-link'))
    File.symlink('profile-1-link', File.join(old_state, 'profile'))
    old_socket = File.join(runtime, 'vpsfree-workspaces/site/app-server.sock')
    authority = File.join(authority_dir, 'session.json')
    File.chmod(0o700, authority_dir)
    File.write(portal, "codex:\n  socket_path: #{old_socket.inspect}\n")
    File.write(archived_portal, "codex:\n  socket_path: #{old_socket.inspect}\n")
    fixture = {
      home:, runtime:, workspace:, old_config:, authority:, portal:, archived_portal:,
      old_state:, new_state: File.join(home, '.local/state/dev-workspaces'),
      compatibility_package:,
      journal: File.join(dir, 'user-journal.json'),
      snapshot_paths: [
        old_config,
        old_state,
        File.join(runtime, 'vpsfree-workspaces'),
        portal,
        archived_portal
      ]
    }
    fixture
  end

  def authority_record(fixture)
    old_runtime = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site')
    {
      'schema' => 1,
      'state' => 'ready',
      'slug' => 'session',
      'workspace' => fixture.fetch(:workspace),
      'tmux_socket' => File.join(old_runtime, 'tmux.sock'),
      'tmux_session_id' => '$1',
      'codex_thread_id' => 'thread-1',
      'codex_socket_path' => File.join(old_runtime, 'app-server.sock'),
      'codex_client_version' => '0.153.4'
    }
  end

  def write_authority(fixture, contents = JSON.generate(authority_record(fixture)))
    File.write(fixture.fetch(:authority), contents)
    File.chmod(0o600, fixture.fetch(:authority))
  end

  def prepare_live_tmux(fixture, codex_thread: 'thread-1')
    socket = File.join(fixture.fetch(:runtime), 'vpsfree-workspaces/site/tmux.sock')
    tmux(socket, 'new-session', '-d', '-s', '__workspace_portal_keeper')
    tmux(socket, 'new-session', '-d', '-s', 'session')
    session_id = tmux(socket, 'display-message', '-p', '-t', 'session:', '#{session_id}').strip
    window = tmux(socket, 'list-windows', '-t', 'session', '-F', '#{window_id}').strip
    pane = tmux(socket, 'display-message', '-p', '-t', 'session:', '#{pane_id}').strip
    identity = 'a' * 64
    options = {
      '@vpsfree_dev_session' => '1',
      '@vpsfree_dev_session_slug' => 'session',
      '@vpsfree_dev_session_codex_thread' => codex_thread,
      '@vpsfree_dev_session_codex_socket' => File.join(File.dirname(socket), 'app-server.sock'),
      '@vpsfree_dev_session_codex_version' => '0.153.4',
      '@vpsfree_dev_session_codex_pane' => pane
    }
    options.each { |name, value| tmux(socket, 'set-option', '-t', 'session', name, value) }
    environment = {
      'VPSFREE_DEV_SESSION_SLUG' => 'session',
      'VPSFREE_DEV_SESSION_WORKSPACE' => fixture.fetch(:workspace),
      'VPSFREE_DEV_SESSION_TMUX_SOCKET' => socket,
      'VPSFREE_DEV_SESSION_AUTHORITY_DIR' => File.join(File.dirname(socket), 'authority'),
      'VPSFREE_DEV_SESSION_CODEX' => File.join(fixture.fetch(:old_state), 'codex/current/bin/codex'),
      'VPSFREE_DEV_SESSION_CODEX_SOCKET' => File.join(File.dirname(socket), 'app-server.sock'),
      'VPSFREE_DEV_SESSION_PORTAL_COMMAND' =>
        File.join(fixture.fetch(:old_state), 'profile-1-link/bin/workspace-portal'),
      'VPSFREE_DEV_SESSION_REQUIRE_RUNTIME' => ' required-VPSFREE_DEV_SESSION_SLUG ',
      'VPSFREE_DEV_SESSION_LIFECYCLE_OPERATION' => '',
      'VPSFREE_DEV_SESSION_TMUX_IDENTITY' => identity
    }
    environment.each { |name, value| tmux(socket, 'set-environment', '-t', 'session', name, value) }
    tmux(socket, 'set-environment', '-r', '-t', 'session', 'VPSFREE_DEV_SESSION_URL')
    authority = authority_record(fixture).merge(
      'tmux_session_id' => session_id,
      'tmux_identity' => identity,
      'codex_thread_id' => codex_thread
    )
    write_authority(fixture, JSON.generate(authority))
    { socket:, window:, authority: }
  end

  def activate_final_profile(fixture)
    state = fixture.fetch(:new_state)
    package = make_profile_package(
      File.dirname(fixture.fetch(:home)),
      'final-package',
      namespace: 'dev-workspaces',
      router_socket: '/run/dev-workspaces/router.sock',
      activation_aliases: []
    )
    File.symlink(package, File.join(state, 'profile-2-link')) unless File.symlink?(File.join(state, 'profile-2-link'))
    File.unlink(File.join(state, 'profile'))
    File.symlink('profile-2-link', File.join(state, 'profile'))
  end

  def restore_compatibility_profile(fixture)
    state = fixture.fetch(:old_state)
    File.unlink(File.join(state, 'profile'))
    File.symlink('profile-1-link', File.join(state, 'profile'))
    File.unlink(File.join(state, 'profile-2-link'))
  end

  def make_profile_package(root, name, namespace:, router_socket:, activation_aliases:)
    package = File.join(root, 'packages', name)
    metadata = File.join(package, 'share/dev-workspace/package.json')
    FileUtils.mkdir_p(File.dirname(metadata))
    File.write(
      metadata,
      JSON.generate(
        'schema' => 1,
        'activationEnvironmentAliases' => activation_aliases,
        'routerSocket' => router_socket,
        'userNamespace' => namespace
      )
    )
    package
  end

  def user_arguments(fixture)
    [
      '--scope', 'user', '--yes', '--home', fixture.fetch(:home),
      '--runtime-dir', fixture.fetch(:runtime), '--workspace-root', fixture.fetch(:workspace),
      '--journal', fixture.fetch(:journal)
    ]
  end

  def assert_user_tree_unmoved(fixture)
    assert_path_exists(fixture.fetch(:old_config))
    assert_path_exists(fixture.fetch(:old_state))
    assert_path_exists(File.join(fixture.fetch(:runtime), 'vpsfree-workspaces'))
    refute_path_exists(File.join(fixture.fetch(:home), '.config/dev-workspaces'))
    refute_path_exists(File.join(fixture.fetch(:home), '.local/state/dev-workspaces'))
    refute_path_exists(File.join(fixture.fetch(:runtime), 'dev-workspaces'))
    if File.file?(fixture.fetch(:journal))
      data = journal(fixture)
      assert_equal('prepared', data.fetch('state'))
      assert_nil(data.fetch('tmux'))
      assert(data.fetch('moves').all? { |move| %w[pending skipped].include?(move.fetch('state')) })
    else
      refute_path_exists(fixture.fetch(:journal))
    end
  end

  def fake_systemctl(dir, runtime, workspace)
    state = File.join(dir, 'systemctl-state.json')
    script = File.join(dir, 'systemctl')
    File.write(script, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
      require 'json'
      arguments = ARGV.dup
      abort 'missing --user' unless arguments.shift == '--user'
      command = arguments.shift
      state_path = ENV.fetch('FAKE_SYSTEMCTL_STATE')
      state = JSON.parse(File.read(state_path))
      case command
      when 'daemon-reload'
        exit 0
      when 'show'
        drop_in = ENV.fetch('FAKE_SYSTEMCTL_DROP_IN')
        puts "ActiveState=#{state.fetch('pid').zero? ? 'failed' : 'active'}"
        puts "MainPID=#{state.fetch('pid')}"
        puts "KillMode=#{File.file?(drop_in) ? 'process' : 'control-group'}"
        puts "Restart=#{File.file?(drop_in) ? 'no' : 'on-failure'}"
      when 'kill'
        pid = state.fetch('pid')
        Process.kill('KILL', pid) if pid.positive?
        state['pid'] = 0
        File.write(state_path, JSON.generate(state))
      else
        abort "unsupported fake systemctl command: #{command}"
      end
    RUBY
    File.chmod(0o755, script)
    pid = spawn_fake_keeper(state)
    environment = {
      'FAKE_SYSTEMCTL_STATE' => state,
      'FAKE_SYSTEMCTL_DROP_IN' => File.join(
        runtime, 'systemd/user/workspace-tmux@.service.d',
        'vpsfree-dev-workspace-migration.conf'
      ),
      'FAKE_SYSTEMCTL_WORKSPACE' => workspace
    }
    [script, environment, pid]
  end

  def spawn_fake_keeper(state)
    pid = Process.spawn('sleep', '300', out: File::NULL, err: File::NULL)
    File.write(state, JSON.generate('pid' => pid))
    pid
  end

  def wait_for_exit(pid)
    _waited, status = Process.wait2(pid)
    assert(status.signaled?)
  rescue Errno::ECHILD
    nil
  end

  def terminate(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def run_helper(*arguments, env: {})
    stdout, stderr, status = Open3.capture3(env, HELPER, *arguments)
    assert(status.success?, "#{stdout}#{stderr}")
    stdout
  end

  def run_helper_failure(*arguments, env: {})
    stdout, stderr, status = Open3.capture3(env, HELPER, *arguments)
    refute(status.success?, "expected failure, got: #{stdout}")
    stdout + stderr
  end

  def tmux(socket, *arguments)
    stdout, stderr, status = Open3.capture3('tmux', '-S', socket, *arguments)
    assert(status.success?, stderr)
    stdout
  end

  def tmux_environment_value(socket, session, name)
    output = tmux(socket, 'show-environment', '-t', session, name).delete_suffix("\n")
    prefix = "#{name}="
    assert(output.start_with?(prefix), "malformed tmux environment output for #{name}")
    output.delete_prefix(prefix)
  end

  def journal(fixture)
    JSON.parse(File.read(fixture.fetch(:journal)))
  end

  def write_journal(fixture, value)
    File.write(fixture.fetch(:journal), JSON.pretty_generate(value) + "\n")
    File.chmod(0o600, fixture.fetch(:journal))
  end

  def rooted(root, path)
    File.join(root, path.delete_prefix('/'))
  end

  def snapshot(paths)
    paths.to_h do |path|
      stat = File.lstat(path)
      value = if stat.file?
                File.binread(path)
              elsif stat.symlink?
                File.readlink(path)
              else
                tree_snapshot(path)
              end
      [path, [stat.ftype, stat.mode & 0o7777, stat.uid, stat.gid, value]]
    end
  end

  def tree_snapshot(root)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject do |path|
      %w[. ..].include?(File.basename(path))
    end.sort.map do |path|
      stat = File.lstat(path)
      relative = path.delete_prefix("#{root}/")
      content = if stat.file?
                  File.binread(path)
                elsif stat.symlink?
                  File.readlink(path)
                end
      [relative, stat.ftype, stat.mode & 0o7777, stat.uid, stat.gid, content]
    end
  end
end
