# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require 'rbconfig'
require_relative 'support/kb_snapshot_fixture'

# Actual selected K validators, with synthetic files/processes in private temp
# roots. This does not start a cluster or assert guest/closure readiness.
class KbPortableTest < Minitest::Test
  include KbSnapshotFixture

  def test_selected_validators_read_full_descriptor_without_mutation_and_release_locks
    with_snapshot do |binding, portable, state, _engine, record, _artifact|
      calls = []
      selected_source = JSON.parse(File.read(metadata_path)).fetch('source')
      trace = TracePoint.new(:call) do |event|
        calls << [event.defined_class.to_s, event.method_id] if event.path.start_with?(selected_source)
      end
      before = files(binding.state_root)
      canonical, value = trace.enable { portable.canonical }
      assert_equal(JSON.parse(canonical), value)
      assert_equal(record['run_id'], value['run_id'])
      assert_equal('a' * 40, binding.read['engine_revision'], 'creation provenance does not become the selected revision')
      refute_equal(binding.read['engine_revision'], portable.revision)
      assert_equal(before, files(binding.state_root))
      forbidden = %i[checkout prepare build verify_live ssh initialize_credentials claim release write start resume update stop reset]
      assert_empty(calls.select { |_owner, name| forbidden.include?(name) })
      assert_includes(calls.map(&:last), :validate_prepared)
      assert_includes(calls.map(&:last), :descriptor)
      assert_includes(calls.map(&:last), :ready?)
      state.transaction(wait: false) { assert(true, 'snapshot locks are released before canonical child lease') }
    end
  end

  def test_noncreating_busy_snapshot_preserves_exact_inventory
    with_snapshot do |binding, portable, state, _engine, _record, _artifact|
      before = files(binding.state_root)
      state.lock('gate') do
        assert_raises(DevClusters::Kb::Busy) { portable.canonical }
        assert_raises(DevClusters::Kb::Busy) { portable.inventory }
      end
      assert_equal(before, files(binding.state_root))
      File.unlink(File.join(state.root, 'locks', 'session.operation.lock'))
      before = files(binding.state_root)
      assert_raises(DevClusters::Kb::Error) { portable.inventory }
      assert_equal(before, files(binding.state_root), 'missing locks are not initialized')
    end
  end

  def test_inventory_accepts_running_stopped_and_pending_recorded_namespaces_without_exit_claims
    with_snapshot do |binding, portable, state, engine, record, _artifact|
      pending = record.merge('run_id' => SecureRandom.uuid)
      pending['socket_dir'] = engine.resources.socket_dir(record['instance_id'], pending['run_id'])
      state.write(state.path("reservation-#{pending['run_id']}.json"), pending)
      %w[ready stopped updating].each do |phase|
        state.write(state.path('phase.json'), { 'schema' => 1, 'phase' => phase, 'run_id' => record['run_id'] })
        before = files(binding.state_root)
        value = portable.inventory
        assert_equal({ 'schema' => 1, 'paths' => [state.directory, binding.record_directory, record['socket_dir'], pending['socket_dir']].uniq.sort }, value.merge('paths' => value['paths'].sort))
        refute_includes(value['paths'], state.root)
        assert_equal(before, files(binding.state_root))
      end
      state.write(state.path("reservation-#{pending['run_id']}.json"), pending.merge('socket_dir' => '/tmp/unrecorded-socket'))
      assert_raises(DevClusters::Kb::Error) { portable.inventory }
    end
  end

  def test_foreign_source_endpoint_artifact_and_disk_records_never_supply_managed_readiness
    with_snapshot do |_binding, portable, state, _engine, record, _artifact|
      connection = File.binread(state.path('connection.json'))
      value = JSON.parse(connection)
      state.write(state.path('connection.json'), value.merge('services' => {}))
      assert_raises(DevClusters::Kb::Error) { portable.canonical }
      File.binwrite(state.path('connection.json'), connection)
      state.write(state.path("launch-#{record['run_id']}.json"), record.merge('artifact_sha256' => '0' * 64))
      assert_raises(DevClusters::Kb::Error) { portable.canonical }
      state.write(state.path("launch-#{record['run_id']}.json"), record)
      File.binwrite(state.path('fixture-root.img'), 'changed disk size')
      assert_raises(DevClusters::Kb::Error) { portable.canonical }
      assert_raises(DevClusters::Kb::Error) { portable.transition_adopt }
    end
  end

  def test_compatible_management_preserves_binding_and_does_not_certify_stopped_capture
    with_snapshot do |binding, portable, state, _engine, record, _artifact|
      before = files(binding.state_root)
      assert_equal(true, portable.transition_adopt)
      assert_equal(before, files(binding.state_root))
      state.write(state.path('phase.json'), { 'schema' => 1, 'phase' => 'stopped', 'run_id' => record['run_id'] })
      assert_equal(true, portable.transition_adopt)
      assert_raises(DevClusters::Kb::Error) { portable.canonical }
      assert_equal('a' * 40, binding.read['engine_revision'])
    end
  end

  def test_ready_marker_loss_refuses_capture_but_preserves_live_management
    with_snapshot do |binding, portable, state, engine, record, _artifact|
      File.unlink(state.path("ready-#{record['run_id']}.json"))
      assert(engine.live?(record))
      before = files(binding.state_root)
      assert_raises(DevClusters::Kb::Error) { portable.canonical }
      assert_equal(true, portable.transition_adopt)
      assert_includes(portable.inventory.fetch('paths'), record['socket_dir'])
      assert_equal(before, files(binding.state_root))
    end
  end

  def test_foreign_or_unsafe_ready_marker_refuses_without_snapshot_mutation
    with_snapshot do |binding, portable, state, engine, record, _artifact|
      path = state.path("ready-#{record['run_id']}.json")
      marker = state.read(path)
      ['schema', 'instance_id', 'run_id', 'artifact_id', 'artifact_sha256'].each do |key|
        state.write(path, marker.merge(key => key == 'schema' ? 2 : 'foreign'))
        before = files(binding.state_root)
        assert(engine.live?(record))
        assert_raises(DevClusters::Kb::Error) { portable.canonical }
        assert_equal(before, files(binding.state_root))
      end
      state.write(path, marker)
      File.chmod(0o644, path)
      before = files(binding.state_root)
      assert_raises(DevClusters::Kb::Error) { portable.canonical }
      assert_equal(before, files(binding.state_root))
    end
  end

  def test_metadata_mismatch_and_absent_state_fail_before_any_initialization
    Dir.mktmpdir do |workspace|
      binding = DevClusters::Kb::Binding.new(workspace:, slug: 'session')
      portable = DevClusters::Kb::Portable.new(binding:, metadata_path:)
      assert_raises(DevClusters::Kb::Error) { portable.inventory }
      refute(File.exist?(binding.state_root))
      metadata = JSON.parse(File.read(metadata_path)).merge('lock_sha256' => '0' * 64)
      candidate = File.join(workspace, 'mismatch.json')
      File.write(candidate, JSON.generate(metadata))
      assert_raises(DevClusters::Kb::Error) { DevClusters::Kb::Portable.new(binding:, metadata_path: candidate) }
      refute(File.exist?(binding.state_root))
    end
  end
end
