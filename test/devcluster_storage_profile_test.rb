# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../dev-clusters/vpsadmin/lib/storage_profile'

class DevclusterStorageProfileTest < Minitest::Test
  Profile = DevClusters::VpsAdminStorageProfile

  def configuration
    {
      'version' => 1, 'enrollment' => true, 'environmentId' => 1,
      'sourcePools' => [{ 'nodeId' => 101, 'filesystem' => 'tank/ct', 'role' => 'hypervisor' }],
      'backupPool' => { 'nodeId' => 201, 'filesystem' => 'tank/backup', 'role' => 'backup', 'maxDatasets' => 32 },
      'nasPool' => { 'nodeId' => 201, 'filesystem' => 'tank/nas', 'role' => 'primary', 'maxDatasets' => 32 },
      'resources' => Profile::RESOURCE_DEFAULTS.dup, 'packageVersion' => 1, 'namespaceBlocks' => 8
    }
  end

  def test_enrollment_is_an_explicit_boolean_in_loaded_configuration
    assert(Profile.new(configuration).enrollment?)
    retired = Profile.new(configuration.merge('enrollment' => false))
    refute(retired.enrollment?)
    assert_raises(Profile::Invalid) { retired.require_enrollment! }
    [nil, 0, 1, 'true', 'false'].each do |value|
      assert_raises(Profile::Invalid) { Profile.new(configuration.merge('enrollment' => value)) }
    end
    assert_raises(Profile::Invalid) { Profile.new(configuration.reject { |key, _| key == 'enrollment' }) }
  end

  def test_profile_configuration_is_explicit_and_bounded
    assert_equal(configuration, Profile.new(configuration).config)
    ['../backup', 'tank/..', './backup', 'tank/backup/child', 'tank/backup;false', ''].each do |root|
      invalid = configuration
      invalid.fetch('backupPool')['filesystem'] = root
      assert_raises(Profile::Invalid) { Profile.new(invalid) }
    end
    [0, -1, 33, '8'].each do |blocks|
      assert_raises(Profile::Invalid) { Profile.new(configuration.merge('namespaceBlocks' => blocks)) }
    end
    assert_raises(Profile::Invalid) { Profile.new(configuration.merge('engine' => 'other')) }
    assert_raises(Profile::Invalid) { Profile.new(configuration.merge('sourcePools' => [])) }
  end

  def test_duplicate_and_mixed_storage_selections_are_refused
    duplicate = configuration
    duplicate.fetch('sourcePools') << duplicate.fetch('sourcePools').first.dup
    assert_raises(Profile::Invalid) { Profile.new(duplicate) }
    mixed = configuration
    mixed.fetch('nasPool')['nodeId'] = 202
    assert_raises(Profile::Invalid) { Profile.new(mixed) }
    overlap = configuration
    overlap.fetch('nasPool')['filesystem'] = 'tank/backup'
    assert_raises(Profile::Invalid) { Profile.new(overlap) }
  end

  def placement_configuration
    configuration.merge('version' => 2, 'vpsBackupPool' => {
      'nodeId' => 201, 'filesystem' => 'tank/vps-backup', 'role' => 'backup', 'maxDatasets' => 32
    })
  end

  def test_profile_formats_are_exact_integer_declarations_with_no_optional_fields
    [configuration, placement_configuration].each do |valid|
      assert_equal(valid, Profile.new(valid).config)
      [nil, '1', '2', 1.0, 2.0, 0, 3].each do |version|
        assert_raises(Profile::Invalid) { Profile.new(valid.merge('version' => version)) }
      end
      assert_raises(Profile::Invalid) { Profile.new(valid.merge('extra' => true)) }
    end
    assert_raises(Profile::Invalid) { Profile.new(placement_configuration.merge('version' => 1)) }
    assert_raises(Profile::Invalid) { Profile.new(configuration.merge('version' => 2)) }
  end

  def test_vps_placement_is_bounded_distinct_and_on_the_existing_storage_node
    [nil, '', 'tank', 'tank/backup/child', 'tank/..', 'tank/backup', 'tank/nas'].each do |root|
      invalid = placement_configuration
      invalid.fetch('vpsBackupPool')['filesystem'] = root
      assert_raises(Profile::Invalid) { Profile.new(invalid) }
    end
    invalid = placement_configuration
    invalid.fetch('vpsBackupPool')['nodeId'] = 202
    assert_raises(Profile::Invalid) { Profile.new(invalid) }
    invalid = placement_configuration
    invalid.fetch('sourcePools').first['nodeId'] = 201
    invalid.fetch('vpsBackupPool')['filesystem'] = 'tank/ct'
    assert_raises(Profile::Invalid) { Profile.new(invalid) }
    %w[role maxDatasets].each do |field|
      invalid = placement_configuration
      invalid.fetch('vpsBackupPool').delete(field)
      assert_raises(Profile::Invalid) { Profile.new(invalid) }
    end
  end

  def test_pool_enumeration_and_inspection_placement_leave_templates_on_source_pools
    selected = Profile.new(placement_configuration)
    assert_equal(4, selected.pool_configs.size)
    assert_equal(2, selected.source_pool_configs.size)
    assert_equal({ 'legacy' => { 'node_id' => 201, 'filesystem' => 'tank/backup' },
                   'vps' => { 'node_id' => 201, 'filesystem' => 'tank/vps-backup' } }, selected.backup_placement)
    assert_equal(3, Profile.new(configuration).pool_configs.size)
    bounded = placement_configuration
    bounded['sourcePools'] = 8.times.map { |i| { 'nodeId' => 101 + i, 'filesystem' => 'tank/ct', 'role' => 'hypervisor' } }
    assert_equal(11, Profile.new(bounded).pool_configs.size)
    bounded['sourcePools'] << { 'nodeId' => 109, 'filesystem' => 'tank/ct', 'role' => 'hypervisor' }
    assert_raises(Profile::Invalid) { Profile.new(bounded) }
  end

  def test_existing_preservation_marker_has_the_exact_consumer_shape
    assert_equal({ 'version' => 1, 'existingAssignments' => 'preserve' }, Profile::PRESERVING_SEED)
    source = File.read(File.expand_path('../dev-clusters/vpsadmin/nix/test.nix', __dir__))
    assert_includes(source, 'return DevClusters::VpsAdminStorageProfile.instance.preserve_namespace!(user)')
    assert_includes(source, 'return DevClusters::VpsAdminStorageProfile.instance.preserve_seed_resources!')
    assert_includes(source, 'labels = webuiSourceLabels // storageProfile.preservingSeedMarker;')
  end
end
