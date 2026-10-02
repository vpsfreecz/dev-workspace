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

  def test_existing_preservation_marker_has_the_exact_consumer_shape
    assert_equal({ 'version' => 1, 'existingAssignments' => 'preserve' }, Profile::PRESERVING_SEED)
    source = File.read(File.expand_path('../dev-clusters/vpsadmin/nix/test.nix', __dir__))
    assert_includes(source, 'return DevClusters::VpsAdminStorageProfile.instance.preserve_namespace!(user)')
    assert_includes(source, 'return DevClusters::VpsAdminStorageProfile.instance.preserve_seed_resources!')
    assert_includes(source, 'labels = webuiSourceLabels // storageProfile.preservingSeedMarker;')
  end
end
