# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../dev-clusters/kb/lib/guards'

class KbGuardsTest < Minitest::Test
  def contract
    JSON.parse(File.read(ENV.fetch('DEVCLUSTER_RUNTIME_CONTRACT')))
  end

  def with_guard
    Dir.mktmpdir('kb-guards-') do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      FileUtils.mkdir_p(File.join(workspace, 'work', 'session'))
      File.write(File.join(workspace, 'work', 'session', 'state.md'), "---\nlifecycle: active\n---\n")
      FileUtils.mkdir_p(File.join(workspace, 'worktrees', '.locks'))
      lock = File.join(workspace, 'worktrees', '.locks', 'session.lock')
      File.open(lock, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
      environment = { 'DEV_WORKSPACE_NAME' => 'example', 'XDG_RUNTIME_DIR' => File.join(workspace, 'runtime') }
      guards = DevClusters::Kb::Guards.new(binding:, contract:, environment:)
      yield binding, guards, environment, lock
    end
  end

  def test_active_session_and_lifecycle_journals_are_checked_before_mutation
    with_guard do |binding, guards, _environment, _lock|
      reached = false
      guards.session('start') { reached = true }
      assert(reached)
      journal = File.join(binding.workspace, 'worktrees', '.locks', 'session.removal.json')
      File.open(journal, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |stream| stream.write('{}') }
      assert_raises(DevClusters::Kb::Error) { guards.session('capture-lease') { flunk('lease reached with pending deletion') } }
      File.unlink(journal)
      File.write(File.join(binding.workspace, 'work', 'session', 'state.md'), "---\nlifecycle: complete\n---\n")
      assert_raises(DevClusters::Kb::Error) { guards.session('start') { flunk('inactive session started') } }
    end
  end

  def test_session_guard_refuses_a_held_mutation_lock_without_waiting
    with_guard do |_binding, guards, _environment, lock|
      File.open(lock, 'r+') do |owner|
        owner.flock(File::LOCK_EX)
        assert_raises(DevClusters::Kb::Busy) { guards.session('start') { flunk('crossed session exclusion') } }
      end
    end
  end

  def test_adapter_read_is_noncreating_and_busy_read_preserves_files
    with_guard do |binding, guards, _environment, _lock|
      before = Dir.glob(File.join(binding.workspace, '**', '*'), File::FNM_DOTMATCH).sort
      assert_raises(DevClusters::Kb::Error) { guards.adapter { flunk('absent adapter lock was created') } }
      assert_equal(before, Dir.glob(File.join(binding.workspace, '**', '*'), File::FNM_DOTMATCH).sort)
      guards.adapter(create: true) do
        another = DevClusters::Kb::Guards.new(binding:, contract:, environment: { 'DEV_WORKSPACE_NAME' => 'example' })
        assert_raises(DevClusters::Kb::Busy) { another.adapter { flunk('crossed adapter exclusion') } }
      end
      guards.adapter { assert(File.exist?(File.join(binding.workspace, '.dev-clusters', '.locks', 'kb-session.lock'))) }
    end
  end

  def test_lifecycle_reset_reuses_only_exact_exclusive_inherited_session_descriptor
    with_guard do |binding, guards, environment, lock|
      File.open(lock, 'r+') do |owner|
        owner.flock(File::LOCK_EX)
        environment.merge!('DEV_SESSION_LIFECYCLE_OPERATION' => 'removal',
                           'DEV_SESSION_LIFECYCLE_LOCK_FD' => owner.fileno.to_s, 'DEV_SESSION_LIFECYCLE_LOCK_PATH' => lock)
        journal = File.join(binding.workspace, 'worktrees', '.locks', 'session.removal.json')
        File.open(journal, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |stream| stream.write('{}') }
        reached = false
        guards.session('reset') { reached = true }
        assert(reached)
        assert_raises(DevClusters::Kb::Error) { guards.session('start') { flunk('inherited lifecycle lock permitted start') } }
        environment['DEV_SESSION_LIFECYCLE_LOCK_PATH'] = File.join(binding.workspace, 'foreign.lock')
        assert_raises(DevClusters::Kb::Error) { guards.session('reset') { flunk('foreign inherited lock accepted') } }
      end
    end
  end
end
