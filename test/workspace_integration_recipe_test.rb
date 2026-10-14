# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/workspace_integration_recipe'

class WorkspaceIntegrationRecipeTest < Minitest::Test
  def graph(revision = 'a' * 40)
    {'version' => 7, 'root' => 'root', 'nodes' => {
      'root' => {'inputs' => {'runtime' => 'runtime', 'sibling' => 'sibling'}},
      'runtime' => {'locked' => {'type' => 'github', 'owner' => 'example', 'repo' => 'runtime', 'rev' => revision, 'narHash' => 'sha256:fixture'}},
      'sibling' => {'locked' => {'type' => 'github', 'owner' => 'example', 'repo' => 'sibling', 'rev' => 'b' * 40, 'narHash' => 'sha256:sibling'}}}}
  end

  def test_managed_revision_changes_preserve_sibling_graph
    old = graph
    updated = graph('c' * 40)
    assert_equal WorkspaceIntegrationRecipe.normalized(old, ['runtime']), WorkspaceIntegrationRecipe.normalized(updated, ['runtime'])
    updated['nodes']['sibling']['locked']['rev'] = 'd' * 40
    refute_equal WorkspaceIntegrationRecipe.normalized(old, ['runtime']), WorkspaceIntegrationRecipe.normalized(updated, ['runtime'])
  end

  def test_changed_follows_is_not_hidden_by_equal_locked_content
    old = graph
    updated = graph
    updated['nodes']['root']['inputs']['sibling'] = ['runtime']
    refute_equal WorkspaceIntegrationRecipe.normalized(old, ['runtime']), WorkspaceIntegrationRecipe.normalized(updated, ['runtime'])
  end

  def test_read_only_verification_accepts_exact_pin_and_rejects_wrong_source
    Dir.mktmpdir do |source|
      run = ->(*args) { WorkspaceIntegrationRecipe.capture(source, *args) }
      run.call('git', 'init', '--initial-branch=master')
      run.call('git', 'config', 'user.name', 'Fixture')
      run.call('git', 'config', 'user.email', 'fixture@example.test')
      File.write(File.join(source, 'flake.lock'), JSON.generate(graph))
      run.call('git', 'add', '.')
      run.call('git', 'commit', '-m', 'old pin fixture')
      from = WorkspaceIntegrationRecipe.git(source, 'rev-parse', 'HEAD')
      File.write(File.join(source, 'flake.lock'), JSON.generate(graph('c' * 40)))
      run.call('git', 'add', '.')
      run.call('git', 'commit', '-m', 'updated pin fixture')
      to = WorkspaceIntegrationRecipe.git(source, 'rev-parse', 'HEAD')
      parameters = {'inputPath' => ['runtime'], 'repository' => 'runtime'}
      result = WorkspaceIntegrationRecipe.verify(source, from, to, parameters, {'runtime' => 'c' * 40})
      assert_equal 'generated_pin', result['relation']
      assert_raises(RuntimeError) { WorkspaceIntegrationRecipe.verify(source, from, to, parameters, {'runtime' => 'd' * 40}) }
      assert_equal to, WorkspaceIntegrationRecipe.git(source, 'rev-parse', 'HEAD')
      assert_empty WorkspaceIntegrationRecipe.git(source, 'status', '--porcelain')
    end
  end
end
