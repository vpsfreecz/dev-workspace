# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../dev-clusters/kb/lib/managed'
require_relative '../dev-clusters/kb/lib/provider'

class KbDevclusterTest < Minitest::Test
  def test_binding_keeps_workspace_meaning_outside_the_portable_cluster_tree
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'same-session')
      value = binding.create(engine_revision: 'a' * 40)
      assert_equal(File.join(workspace, '.dev-clusters', 'kb'), binding.state_root)
      assert_equal(workspace, value.fetch('workspace'))
      assert_equal('kb', value.fetch('provider'))
      assert_equal(2, value.fetch('portable_schema'))
      refute(File.exist?(binding.cluster_directory), 'only K initializes its portable cluster directory')
      assert_equal(0o600, File.stat(binding.path).mode & 0o777)
      assert_equal(0o700, File.stat(File.dirname(binding.path)).mode & 0o777)
      assert_equal(value, binding.read)
    end
  end

  def test_a_copied_binding_cannot_select_another_workspace_or_session
    Dir.mktmpdir do |directory|
      workspaces = %w[first second].map { |name| File.join(directory, name) }
      workspaces.each { |path| Dir.mkdir(path) }
      bindings = workspaces.map { |workspace| DevClusters::Kb::Binding.new(workspace:, slug: 'same-session') }
      bindings.each { |binding| binding.create(engine_revision: 'a' * 40) }
      FileUtils.cp(bindings.first.path, bindings.last.path)
      assert_raises(DevClusters::Kb::Error) { bindings.last.read }
      other_session = DevClusters::Kb::Binding.new(workspace: workspaces.first, slug: 'other-session')
      other_session.create(engine_revision: 'a' * 40)
      FileUtils.cp(bindings.first.path, other_session.path)
      assert_raises(DevClusters::Kb::Error) { other_session.read }
      assert_equal('same-session', bindings.first.read.fetch('slug'))
    end
  end

  def test_existing_unbound_portable_or_legacy_state_is_not_adopted
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      FileUtils.mkdir_p(binding.cluster_directory)
      sentinel = File.join(binding.cluster_directory, 'sentinel')
      File.write(sentinel, 'keep')
      assert_raises(DevClusters::Kb::Error) { binding.create(engine_revision: 'a' * 40) }
      assert_equal('keep', File.read(sentinel))
      refute(File.exist?(binding.path))
    end
  end

  def test_read_only_binding_lookup_does_not_initialize_missing_state
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      assert_raises(DevClusters::Kb::Error) { binding.read }
      refute(File.exist?(binding.state_root))
    end
  end

  def test_binding_rejects_unsupported_schema_and_private_path_mistakes
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      original = binding.create(engine_revision: 'a' * 40)
      File.write(binding.path, JSON.generate(original.merge('portable_schema' => 3)))
      assert_raises(DevClusters::Kb::Error) { binding.read }
      File.write(binding.path, JSON.generate(original))
      File.chmod(0o644, binding.path)
      assert_raises(DevClusters::Kb::Error) { binding.read }
      File.chmod(0o600, binding.path)
      File.rename(binding.path, binding.path + '.retained')
      File.symlink(binding.path + '.retained', binding.path)
      assert_raises(DevClusters::Kb::Error) { binding.read }
      assert_equal(original, JSON.parse(File.read(binding.path + '.retained')))
    end
  end

  def test_status_translates_portable_phases_without_claiming_failed_update_readiness
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      binding.create(engine_revision: 'a' * 40)
      response = File.join(workspace, 'engine-status.json')
      arguments = File.join(workspace, 'engine-arguments.json')
      engine = File.join(workspace, 'engine')
      File.write(engine, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'json'
        File.write(#{arguments.inspect}, JSON.generate(ARGV))
        print File.read(#{response.inspect})
      RUBY
      File.chmod(0o755, engine)
      provider = DevClusters::Kb::Provider.new(binding:, engine:)
      {
        'ready' => ['running', true], 'stopped' => ['stopped', false],
        'updating' => ['stale', false], 'failed' => ['stale', false]
      }.each do |phase, (state, ready)|
        File.write(response, JSON.generate('schema' => 2, 'found' => true, 'state' => phase, 'ready' => ready))
        status = provider.status
        assert_equal(state, status.fetch('state'))
        assert_equal(ready, status.fetch('ready'))
        assert_equal([], status.fetch('services'))
        assert_equal('kb', status.fetch('kind'))
      end
      assert_equal(['--state-root', binding.state_root, 'status', 'session', '--json'], JSON.parse(File.read(arguments)))
    end
  end

  def test_missing_status_is_read_only_and_existing_unbound_state_is_refused
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      engine = File.join(workspace, 'engine')
      File.write(engine, "#!#{RbConfig.ruby}\nabort 'unexpected engine invocation'\n")
      File.chmod(0o755, engine)
      provider = DevClusters::Kb::Provider.new(binding:, engine:)
      assert_equal({ 'schema' => 2, 'kind' => 'kb', 'found' => false }, provider.status)
      refute(File.exist?(binding.state_root))
      FileUtils.mkdir_p(binding.cluster_directory)
      assert_raises(DevClusters::Kb::Error) { provider.status }
      assert(File.directory?(binding.cluster_directory))
    end
  end

  def test_busy_engine_status_preserves_portal_busy_contract
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      binding.create(engine_revision: 'a' * 40)
      engine = File.join(workspace, 'engine')
      File.write(engine, "#!#{RbConfig.ruby}\nexit 75\n")
      File.chmod(0o755, engine)
      provider = DevClusters::Kb::Provider.new(binding:, engine:)
      assert_raises(DevClusters::Kb::Busy) { provider.status }
      assert_equal('a' * 40, binding.read.fetch('engine_revision'))
    end
  end
end
