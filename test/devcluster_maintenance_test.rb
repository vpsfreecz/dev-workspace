require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../dev-clusters/vpsadmin/lib/maintenance'

class DevclusterMaintenanceTest < Minitest::Test
  Maintenance = DevClusters::VpsAdminMaintenance
  BOOT_ID = '01111111-2222-3333-4444-555555555555'.freeze

  def test_host_projection_normalizes_lexical_items_and_ignores_external_or_unselected_inputs
    with_fixture do |maintenance, paths|
      config = payload_configuration(paths)
      store = File.dirname(paths.fetch(:resident))
      services = config.fetch('machines').fetch('services')
      services['kernel'] = store + '/boot/bzImage'
      services['initrd'] = store + '/boot/initrd'
      services['sharedFileSystems'] = { 'store' => store + '/share/subdir', 'worktree' => '/external/worktree' }
      services['networks'] = [{ 'type' => 'bridge', 'opts' => { 'helper' => store + '/qemu/bin/helper' } }]
      config.fetch('machines').fetch('node1')['kernel'] = store + '/unselected.drv'
      inputs = maintenance.host_payloads(config, machines: ['services'])
      assert_equal([store + '/boot', services.fetch('toplevel'), store + '/qemu', store + '/share'], inputs.keys)
      assert_equal([[store + '/boot/bzImage', :file], [store + '/boot/initrd', :file]], inputs.fetch(store + '/boot'))
      refute(inputs.key?(store + '/old-image'))
      refute(inputs.key?('/external/worktree'))
      assert_raises(Maintenance::Invalid) { maintenance.host_payloads(config) }
    end
  end

  def test_host_projection_includes_only_disk_images_that_osvm_will_consume
    with_fixture do |maintenance, paths|
      config = payload_configuration(paths)
      services = config.fetch('machines').fetch('services')
      image = services.fetch('rootDisk').fetch('image')
      refute(maintenance.host_payloads(config).key?(image))
      File.unlink(paths.fetch(:services_disk))
      assert_includes(maintenance.host_payloads(config).keys, image)
      File.write(paths.fetch(:services_disk), 'present again')
      services.fetch('rootDisk')['preserve'] = false
      assert_includes(maintenance.host_payloads(config).keys, image)
      services.fetch('rootDisk')['create'] = false
      refute(maintenance.host_payloads(config).key?(image))
    end
  end

  def test_host_projection_enforces_item_machine_and_string_bounds_before_registration
    with_fixture do |maintenance, paths|
      config = payload_configuration(paths)
      services = config.fetch('machines').fetch('services')
      services['sharedFileSystems'] = 513.times.to_h { |i| [i.to_s, File.dirname(paths.fetch(:resident)) + "/share-#{i}"] }
      assert_raises(Maintenance::Invalid) { maintenance.host_payloads(config) }
      services['sharedFileSystems'] = {}
      services['kernel'] = 'x' * 2049
      assert_raises(Maintenance::Invalid) { maintenance.host_payloads(config) }
      config = payload_configuration(paths)
      config['machines'] = 17.times.to_h { |i| [i.zero? ? 'services' : "node#{i}", services] }
      assert_raises(Maintenance::Invalid) { maintenance.host_payloads(config) }
    end
  end

  def test_residency_evidence_is_required_bound_and_private
    with_fixture do |maintenance, paths|
      assert_raises(Maintenance::Invalid) { prepare(maintenance, paths, evidence_path: paths.fetch(:missing)) }
      %w[workspace slug resident_config resident_config_sha256 services_toplevel evidence_kind].each do |field|
        original = File.binread(paths.fetch(:evidence))
        evidence = JSON.parse(original)
        evidence[field] = 'wrong'
        write_json(paths.fetch(:evidence), evidence)
        assert_raises(Maintenance::Invalid, field) { prepare(maintenance, paths) }
        File.binwrite(paths.fetch(:evidence), original)
      end
      File.chmod(0o644, paths.fetch(:evidence))
      assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
      File.chmod(0o600, paths.fetch(:evidence))
      File.symlink(paths.fetch(:evidence), paths.fetch(:missing))
      assert_raises(Maintenance::Invalid) { prepare(maintenance, paths, evidence_path: paths.fetch(:missing)) }
      refute(File.exist?(paths.fetch(:record)))
    end
  end

  def test_evidence_shape_duplicate_keys_and_byte_bounds_refuse_before_hold
    [
      '{', '{"version":1,"version":1}',
      JSON.generate('version' => 1), ' ' * (Maintenance::MAX_EVIDENCE_BYTES + 1)
    ].each do |input|
      with_fixture do |maintenance, paths|
        File.binwrite(paths.fetch(:evidence), input)
        assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
        refute(File.exist?(paths.fetch(:record)))
      end
    end
    with_fixture do |maintenance, paths|
      evidence = JSON.parse(File.binread(paths.fetch(:evidence)))
      evidence['extra'] = true
      write_json(paths.fetch(:evidence), evidence)
      assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
    end
    with_fixture do |maintenance, paths|
      resident = File.binread(paths.fetch(:resident))
      File.binwrite(paths.fetch(:resident), resident.sub('"preserve":true', '"preserve":true,"preserve":true'))
      error = assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
      assert_equal('duplicate JSON key', error.message)
      refute(File.exist?(paths.fetch(:record)))
    end
  end

  def test_same_evidence_retry_accepts_relocation_but_not_changed_bytes
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      before = File.binread(paths.fetch(:record))
      assert_equal(0o600, File.stat(paths.fetch(:record)).mode & 0o777)
      FileUtils.copy_file(paths.fetch(:evidence), paths.fetch(:missing))
      File.chmod(0o600, paths.fetch(:missing))
      prepare(maintenance, paths, evidence_path: paths.fetch(:missing))
      assert_equal(before, File.binread(paths.fetch(:record)))
      File.open(paths.fetch(:missing), 'a') { |file| file.write("\n") }
      assert_raises(Maintenance::Invalid) { prepare(maintenance, paths, evidence_path: paths.fetch(:missing)) }
      assert_equal(before, File.binread(paths.fetch(:record)))
      assert_equal({ 'version' => 2, 'mode' => 'maintenance', 'phase' => 'held',
                     'pending' => true, 'copied' => false, 'active' => false }, maintenance.status)
      refute_includes(JSON.generate(maintenance.status), 'private reference')
    end
  end

  def test_all_retained_disks_must_exist_and_be_preserved_before_boot
    [false, true].each do |missing|
      with_fixture do |maintenance, paths|
        if missing
          File.unlink(paths.fetch(:node_disk))
        else
          config = JSON.parse(File.binread(paths.fetch(:resident)))
          config.fetch('machines').fetch('node1').fetch('disks').first['preserve'] = false
          write_json(paths.fetch(:resident), config)
          update_evidence_digest(paths)
        end
        assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
        refute(File.exist?(paths.fetch(:record)))
      end
    end
  end

  def test_only_fixed_bounded_masks_are_passed_before_start
    assert_includes(Maintenance.kernel_parameters, 'systemd.mask=credentials.service')
    assert_includes(Maintenance.kernel_parameters, 'systemd.mask=api-wait-online.service')
    assert_includes(Maintenance.kernel_parameters, 'systemd.mask=vpsadmin-rabbitmq-setup.service')
    assert_includes(Maintenance.kernel_parameters, 'systemd.mask=timers.target')
    refute(Maintenance.kernel_parameters.any? { |param| param.include?('*') })
    with_fixture do |maintenance, paths|
      config = JSON.parse(File.binread(paths.fetch(:resident)))
      services = config.fetch('machines').fetch('services')
      assert_operator(maintenance.validate_boot!(services).bytesize, :<=, Maintenance::MAX_KERNEL_COMMAND_LINE_BYTES)
      ['init=/evil', 'systemd.wants=vpsadmin-api.service', 'SYSTEMD_GENERATOR_PATH=/override', 'debug'].each do |param|
        assert_raises(Maintenance::Invalid) { maintenance.validate_boot!(services.merge('kernelParams' => [param])) }
      end
      assert_raises(Maintenance::Invalid) do
        maintenance.validate_boot!(services.merge('kernelParams' => ['x' * 2048]))
      end
      assert_raises(Maintenance::Invalid) { maintenance.validate_boot!(services.merge('bootMode' => 'firmware')) }
    end
  end

  def test_copy_requires_preserving_marker_matching_runner_and_boot
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      assert_raises(Maintenance::Invalid) { begin_copy(maintenance, paths) }
      bind_boot(maintenance)
      assert_raises(Maintenance::Invalid) { begin_copy(maintenance, paths, pid: 124) }
      candidate = JSON.parse(File.binread(paths.fetch(:candidate)))
      original = File.binread(paths.fetch(:candidate))
      [nil, {}, { 'version' => 2, 'existingAssignments' => 'preserve' },
       { 'version' => 1, 'existingAssignments' => 'overwrite' }].each do |marker|
        candidate['labels'] = marker ? { 'vpsadminPreservingSeed' => JSON.generate(marker) } : {}
        write_json(paths.fetch(:candidate), candidate)
        assert_raises(Maintenance::Invalid) { begin_copy(maintenance, paths) }
        assert_equal('maintenance_ready', maintenance.status.fetch('phase'))
      end
      File.binwrite(paths.fetch(:candidate), original)
      begin_copy(maintenance, paths)
      assert_equal('copying', maintenance.status.fetch('phase'))
      assert_raises(Maintenance::Invalid) { maintenance.copied_config! }
      second_identity = identity.merge(boot_id: '01111111-2222-3333-4444-666666666666')
      before = File.binread(paths.fetch(:record))
      error = assert_raises(Maintenance::Invalid) { begin_copy(maintenance, paths, **second_identity) }
      assert_equal('maintenance runner or guest boot changed', error.message)
      assert_equal(before, File.binread(paths.fetch(:record)))
      maintenance.bind_boot!(**second_identity)
      rebound = File.binread(paths.fetch(:record))
      error = assert_raises(Maintenance::Invalid) { begin_copy(maintenance, paths) }
      assert_equal('maintenance runner or guest boot changed', error.message)
      assert_equal(rebound, File.binread(paths.fetch(:record)))
      begin_copy(maintenance, paths, **second_identity)
      assert_equal('copying', maintenance.status.fetch('phase'))
    end
  end

  def test_next_boot_replaces_only_services_and_never_rebuilds_other_guests
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      bind_boot(maintenance)
      begin_copy(maintenance, paths)
      maintenance.build_next!(next_path: paths.fetch(:next))
      maintenance.finish_copy!(next_path: paths.fetch(:next), **identity)
      selected = JSON.parse(File.binread(paths.fetch(:next)))
      resident = JSON.parse(File.binread(paths.fetch(:resident)))
      candidate = JSON.parse(File.binread(paths.fetch(:candidate)))
      assert_equal(resident.fetch('machines').fetch('node1'), selected.fetch('machines').fetch('node1'))
      refute_equal(candidate.fetch('machines').fetch('node1'), selected.fetch('machines').fetch('node1'))
      assert_equal(candidate.fetch('machines').fetch('services'), selected.fetch('machines').fetch('services'))
      refute_equal(resident.dig('machines', 'services', 'rootDisk', 'image'), selected.dig('machines', 'services', 'rootDisk', 'image'))
      assert_equal('retained services payload', File.binread(paths.fetch(:services_disk)))
      assert_equal(paths.fetch(:next), maintenance.copied_config!)
      assert_equal('starting_copied', maintenance.status.fetch('phase'))
      maintenance.begin_boot!(config_path: paths.fetch(:next), operation: 'copied_boot')
      maintenance.finish_boot!(config_path: paths.fetch(:next), proof_reference: 'fixture full boot proof')
      maintenance.release!(**identity.merge(boot_id: '01111111-2222-3333-4444-666666666666'))
      refute(maintenance.pending?)
      assert(maintenance.status.fetch('active'))
    end
  end

  def test_every_other_disk_descriptor_change_refuses_copy
    {
      'device' => 'another-root.img', 'type' => 'blockdev', 'create' => false,
      'preserve' => false, 'size' => '2G', 'extra' => true
    }.each do |field, value|
      with_fixture do |maintenance, paths|
        prepare(maintenance, paths)
        bind_boot(maintenance)
        candidate = JSON.parse(File.binread(paths.fetch(:candidate)))
        candidate.fetch('machines').fetch('services').fetch('rootDisk')[field] = value
        write_json(paths.fetch(:candidate), candidate)
        assert_raises(Maintenance::Invalid, field) { begin_copy(maintenance, paths) }
        assert_equal('maintenance_ready', maintenance.status.fetch('phase'))
        assert_equal('retained services payload', File.binread(paths.fetch(:services_disk)))
        refute(File.exist?(paths.fetch(:next)))
      end
    end
  end

  def test_qemu_package_uses_the_runtime_executable_and_accepts_its_alias
    with_fixture do |maintenance, paths|
      machine = JSON.parse(File.binread(paths.fetch(:resident))).fetch('machines').fetch('services')
      maintenance.validate_boot!(machine)
      File.unlink(File.join(machine.fetch('qemu'), 'bin/qemu-kvm'))
      assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
      refute(File.exist?(paths.fetch(:record)))
    end
  end

  def test_interrupted_record_publication_preserves_the_previous_hold
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      bind_boot(maintenance)
      before = File.binread(paths.fetch(:record))
      fail_rename = ->(*) { raise Errno::EIO }
      File.stub(:rename, fail_rename) do
        assert_raises(Errno::EIO) { begin_copy(maintenance, paths) }
      end
      assert_equal(before, File.binread(paths.fetch(:record)))
      assert_equal('maintenance_ready', maintenance.status.fetch('phase'))
      assert_raises(Maintenance::Invalid) { maintenance.copied_config! }
    end
  end

  def test_copy_rejects_layout_change_and_mutated_config_without_release
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      bind_boot(maintenance)
      candidate = JSON.parse(File.binread(paths.fetch(:candidate)))
      original = File.binread(paths.fetch(:candidate))
      candidate.fetch('machines').fetch('services')['sharedFileSystems'] = { 'unexpected' => '/other' }
      write_json(paths.fetch(:candidate), candidate)
      assert_raises(Maintenance::Invalid) { begin_copy(maintenance, paths) }
      File.binwrite(paths.fetch(:candidate), original)
      begin_copy(maintenance, paths)
      File.open(paths.fetch(:candidate), 'a') { |file| file.write("\n") }
      assert_raises(Maintenance::Invalid) { maintenance.finish_copy!(next_path: paths.fetch(:next), **identity) }
      assert(maintenance.pending?)
      refute(File.exist?(paths.fetch(:next)))
      assert_raises(Maintenance::Invalid) { maintenance.release!(**identity) }
    end
  end

  def test_unknown_hold_is_not_ignored_by_status_or_adoption
    with_fixture do |maintenance, paths|
      write_json(paths.fetch(:record), { 'version' => 2, 'phase' => 'held' })
      assert_raises(Maintenance::Invalid) { maintenance.pending? }
      assert_raises(Maintenance::Invalid) { maintenance.status }
    end
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      record = JSON.parse(File.binread(paths.fetch(:record)))
      record['copied_toplevel'] = paths.fetch(:toplevel)
      write_json(paths.fetch(:record), record)
      assert_raises(Maintenance::Invalid) { maintenance.status }
      assert_raises(Maintenance::Invalid) { maintenance.validate_adoption! }
    end
  end

  def test_generator_and_known_unit_inventory_are_required_before_runner_start
    with_fixture do |maintenance, paths|
      top = paths.fetch(:toplevel)
      systemd = File.join(File.dirname(top), 'systemd')
      FileUtils.mkdir_p([File.join(systemd, 'bin'), File.join(systemd, 'lib/systemd/system-generators'),
                        File.join(top, 'sw/bin'), File.join(top, 'etc/systemd/system')])
      File.write(File.join(systemd, 'bin/systemctl'), 'fixture')
      generator = File.join(systemd, 'lib/systemd/system-generators/systemd-debug-generator')
      File.write(generator, 'fixture')
      File.chmod(0o755, generator)
      File.symlink(File.join(systemd, 'bin/systemctl'), File.join(top, 'sw/bin/systemctl'))
      File.write(File.join(top, 'activate'), "#!/bin/sh\nuseradd vpsadmin-api\n")
      File.write(File.join(top, 'etc/systemd/system/vpsadmin-rabbitmq-setup.service'), "[Service]\nType=oneshot\n")
      wants = File.join(top, 'etc/systemd/system/multi-user.target.wants')
      FileUtils.mkdir_p(wants)
      File.symlink('../vpsadmin-rabbitmq-setup.service', File.join(wants, 'vpsadmin-rabbitmq-setup.service'))
      maintenance.validate_system!(top)
      unit = File.join(top, 'etc/systemd/system/vpsadmin-api-unknown.service')
      File.write(unit, '[Service]')
      assert_raises(Maintenance::Invalid) { maintenance.validate_system!(top) }
      File.unlink(unit)
      File.write(File.join(top, 'etc/systemd/system/vpsadmin-api-mail-process.service'), '[Service]')
      File.symlink('../vpsadmin-api-mail-process.service', File.join(wants, 'vpsadmin-api-mail-process.service'))
      assert_raises(Maintenance::Invalid) { maintenance.validate_system!(top) }
      File.unlink(File.join(wants, 'vpsadmin-api-mail-process.service'))
      File.symlink('../vpsadmin-api-mail-process.service', File.join(wants, 'unrelated-alias.service'))
      assert_raises(Maintenance::Invalid) { maintenance.validate_system!(top) }
      File.unlink(File.join(wants, 'unrelated-alias.service'))
      FileUtils.mkdir_p(File.join(top, 'etc/systemd/system-generators'))
      override = File.join(top, 'etc/systemd/system-generators/systemd-debug-generator')
      File.symlink('/dev/null', override)
      assert_raises(Maintenance::Invalid) { maintenance.validate_system!(top) }
      File.unlink(override)
      File.write(File.join(top, 'activate'), "#!/bin/sh\nbundle exec rake db:seed\n")
      assert_raises(Maintenance::Invalid) { maintenance.validate_system!(top) }
    end
  end

  def test_target_promotion_keeps_all_other_descriptors_and_proofs
    with_applied_fixture do |maintenance, paths|
      before = read_applied(paths)
      maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'node1')
      pending = read_applied(paths)
      assert_equal(before.fetch('configuration'), pending.fetch('configuration'))
      assert_equal(before.fetch('provenance'), pending.fetch('provenance'))
      maintenance.promote_update!(target: 'node1', proof_reference: 'exact current-system and rooted closure')
      after = read_applied(paths)
      assert_equal(before.dig('configuration', 'machines', 'services'), after.dig('configuration', 'machines', 'services'))
      assert_equal(before.dig('provenance', 'services'), after.dig('provenance', 'services'))
      assert_equal(JSON.parse(File.read(paths.fetch(:candidate))).dig('machines', 'node1'), after.dig('configuration', 'machines', 'node1'))
      assert_nil(after.fetch('pending'))
    end
  end

  def test_node_boot_payload_changes_only_promote_the_selected_descriptor
    with_applied_fixture do |maintenance, paths|
      before = read_applied(paths)
      maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'node1')
      maintenance.promote_update!(target: 'node1', proof_reference: 'real-shaped Node current-system and closure proof')
      after = read_applied(paths)
      refute_equal(before.dig('configuration', 'machines', 'node1', 'squashfs'), after.dig('configuration', 'machines', 'node1', 'squashfs'))
      assert_equal(before.dig('configuration', 'machines', 'services'), after.dig('configuration', 'machines', 'services'))
      %w[kernelParams extraQemuOptions iso qemu virtiofs networks sharedFileSystems].each do |field|
        candidate = JSON.parse(File.read(paths.fetch(:candidate)))
        candidate.fetch('machines').fetch('node1')[field] = 'changed retained layout'
        path = paths.fetch(:candidate) + "-#{field}.json"
        write_json(path, candidate)
        unchanged = File.binread(paths.fetch(:applied))
        assert_raises(Maintenance::Invalid, field) { maintenance.begin_update!(candidate_path: path, target: 'node1') }
        assert_equal(unchanged, File.binread(paths.fetch(:applied)), field)
      end
    end
  end

  def test_unexpected_node_root_disk_has_no_image_source_exemption
    with_applied_fixture do |maintenance, paths|
      current = read_applied(paths)
      node = current.fetch('configuration').fetch('machines').fetch('node1')
      node['rootDisk'] = { 'type' => 'file', 'device' => 'node-extra.img', 'preserve' => true,
                           'image' => paths.fetch(:resident) }
      File.write(File.join(File.dirname(paths.fetch(:record)), 'state/node-extra.img'), 'retained extra disk')
      source = paths.fetch(:resident) + '-unexpected-root.json'
      write_json(source, current.fetch('configuration'))
      current.fetch('provenance')['node1'] = { 'source_config' => source,
        'source_config_sha256' => Digest::SHA256.file(source).hexdigest,
        'proof_kind' => 'prior_boot', 'proof_reference' => 'fixture unexpected retained descriptor' }
      write_json(paths.fetch(:applied), current)
      candidate = JSON.parse(JSON.generate(current.fetch('configuration')))
      candidate.fetch('machines').fetch('node1').fetch('rootDisk')['image'] = paths.fetch(:candidate)
      changed = paths.fetch(:candidate) + '-unexpected-root.json'
      write_json(changed, candidate)
      assert_raises(Maintenance::Invalid) { maintenance.begin_update!(candidate_path: changed, target: 'node1') }
    end
  end

  def test_pending_target_refuses_another_target_and_allows_explicit_retry
    with_applied_fixture do |maintenance, paths|
      maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'node1')
      before = File.binread(paths.fetch(:applied))
      assert_raises(Maintenance::Invalid) { maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'services') }
      assert_equal(before, File.binread(paths.fetch(:applied)))
      assert_raises(Maintenance::Invalid) { maintenance.retained_config!(output_path: paths.fetch(:rendered)) }
      retry_config = JSON.parse(File.read(paths.fetch(:candidate)))
      retry_config.fetch('machines').fetch('node1')['toplevel'] += '-retry'
      # Both candidates remain immutable; only the explicit pending target changes.
      retry_path = paths.fetch(:candidate) + '-retry.json'
      write_json(retry_path, retry_config)
      maintenance.begin_update!(candidate_path: retry_path, target: 'node1')
      assert_equal(retry_path, read_applied(paths).fetch('pending').fetch('candidate'))
      maintenance.promote_update!(target: 'node1', proof_reference: 'actual retry proof')
      assert_equal(retry_config.fetch('machines').fetch('node1'), read_applied(paths).dig('configuration', 'machines', 'node1'))
    end
  end

  def test_legacy_target_update_does_not_prove_untouched_images
    with_fixture do |maintenance, paths|
      assert_raises(Maintenance::Invalid) { maintenance.begin_boot!(config_path: paths.fetch(:resident), operation: 'boot') }
      maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'node1')
      maintenance.promote_update!(target: 'node1', proof_reference: 'actual target update')
      applied = JSON.parse(File.read(File.join(File.dirname(paths.fetch(:record)), 'applied-config.json')))
      assert_equal(['node1'], applied.fetch('provenance').keys)
      assert_raises(Maintenance::Invalid) { maintenance.retained_config!(output_path: paths.fetch(:next)) }
    end
  end

  def test_missing_or_changed_disk_layout_refuses_before_pending_publication
    with_applied_fixture do |maintenance, paths|
      before = File.binread(paths.fetch(:applied))
      candidate = JSON.parse(File.read(paths.fetch(:candidate)))
      candidate.fetch('machines').fetch('node1').fetch('disks').first['device'] = '../outside'
      write_json(paths.fetch(:candidate), candidate)
      assert_raises(Maintenance::Invalid) { maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'node1') }
      assert_equal(before, File.binread(paths.fetch(:applied)))
    end
  end

  def test_interrupted_target_promotion_retains_pending_and_prior_selection
    with_applied_fixture do |maintenance, paths|
      maintenance.begin_update!(candidate_path: paths.fetch(:candidate), target: 'node1')
      before = File.binread(paths.fetch(:applied))
      maintenance.stub(:write_private_json, ->(*) { raise Errno::EIO }) do
        assert_raises(Errno::EIO) { maintenance.promote_update!(target: 'node1', proof_reference: 'actual proof') }
      end
      assert_equal(before, File.binread(paths.fetch(:applied)))
    end
  end

  def test_recovery_preserves_six_machine_copy_and_immutable_predecessor
    with_recovery_fixture do |maintenance, paths|
      old_hold = File.binread(paths.fetch(:record))
      original = JSON.parse(File.read(paths.fetch(:next)))
      prepared = maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:corrected))
      assert_equal(false, prepared.fetch('already_recorded'))
      assert_equal(old_hold, File.binread(paths.fetch(:record)))
      maintenance.commit_recovery!(evidence_path: paths.fetch(:recovery), next_path: paths.fetch(:corrected))
      corrected = JSON.parse(File.read(paths.fetch(:corrected)))
      %w[services node1 node2 storage1].each do |name|
        assert_equal(original.fetch('machines').fetch(name), corrected.fetch('machines').fetch(name))
      end
      history = JSON.parse(File.read(paths.fetch(:historic)))
      %w[dns-primary dns-secondary].each do |name|
        assert_equal(history.fetch('machines').fetch(name), corrected.fetch('machines').fetch(name))
      end
      record = maintenance.load_record
      assert_equal(2, record.fetch('version'))
      assert_equal(1, record.fetch('mask_policy'))
      assert_equal(old_hold, File.binread(record.fetch('predecessor').fetch('path')))
      assert_equal('copied', maintenance.status.fetch('phase'))
      assert(maintenance.pending?)
      assert_raises(Maintenance::Invalid) { maintenance.retained_config!(output_path: paths.fetch(:rendered)) }
      retry_result = maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:rendered))
      assert(retry_result.fetch('already_recorded'))
      assert_equal(paths.fetch(:corrected), retry_result.fetch('next_config'))
    end
  end

  def test_recovery_validation_failure_never_publishes
    %w[hold node services dns_source disk layout extra marker float duplicate].each do |failure|
      with_recovery_fixture do |maintenance, paths|
        evidence = JSON.parse(File.read(paths.fetch(:recovery)))
        case failure
        when 'hold' then evidence['expected_hold_sha256'] = '0' * 64
        when 'node'
          foreign = JSON.parse(File.read(paths.fetch(:next)))
          foreign.fetch('machines').fetch('node1')['squashfs'] += '-different'
          source = paths.fetch(:historic) + '-foreign.json'
          write_json(source, foreign)
          evidence.fetch('machines').fetch('node1').merge!(
            'source_config' => source, 'source_config_sha256' => Digest::SHA256.file(source).hexdigest)
        when 'services'
          evidence.fetch('machines').fetch('services').merge!(
            'source_config' => paths.fetch(:historic), 'source_config_sha256' => Digest::SHA256.file(paths.fetch(:historic)).hexdigest)
        when 'dns_source' then evidence.fetch('machines').fetch('dns-primary')['proof_kind'] = 'prior_update'
        when 'disk' then evidence.fetch('machines').fetch('dns-primary').fetch('disks').first['ino'] += 1
        when 'layout' then File.unlink(paths.fetch(:dns_disk))
        when 'float' then evidence['version'] = 1.0
        when 'extra' then evidence.fetch('machines')['foreign'] = evidence.fetch('machines').fetch('node1')
        when 'marker'
          candidate = JSON.parse(File.read(paths.fetch(:candidate)))
          candidate['labels'] = {}
          write_json(paths.fetch(:candidate), candidate)
        end
        write_json(paths.fetch(:recovery), evidence)
        if failure == 'duplicate'
          File.write(paths.fetch(:recovery), File.read(paths.fetch(:recovery)).sub('{', '{"version":1,'))
        end
        before = File.binread(paths.fetch(:record))
        assert_raises(Maintenance::Invalid, failure) do
          maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:corrected))
        end
        assert_equal(before, File.binread(paths.fetch(:record)), failure)
        refute(File.exist?(paths.fetch(:corrected)), failure)
      end
    end
  end

  def test_recovery_final_publication_failure_leaves_original_hold_authoritative
    with_recovery_fixture do |maintenance, paths|
      maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:corrected))
      before = File.binread(paths.fetch(:record))
      original_writer = maintenance.method(:write_private_json)
      maintenance.stub(:write_private_json, lambda { |path, value, **options|
        raise Errno::EIO if path == paths.fetch(:record)
        original_writer.call(path, value, **options)
      }) do
        assert_raises(Errno::EIO) { maintenance.commit_recovery!(evidence_path: paths.fetch(:recovery), next_path: paths.fetch(:corrected)) }
      end
      assert_equal(before, File.binread(paths.fetch(:record)))
      assert(maintenance.pending?)
    end
  end

  def test_recovered_boot_rechecks_current_disk_snapshot_and_requires_full_proof
    with_recovery_fixture do |maintenance, paths|
      maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:corrected))
      maintenance.commit_recovery!(evidence_path: paths.fetch(:recovery), next_path: paths.fetch(:corrected))
      assert_equal(paths.fetch(:corrected), maintenance.copied_config!)
      maintenance.validate_copied_runner!(config_path: paths.fetch(:corrected))
      assert_raises(Maintenance::Invalid) { maintenance.release!(**identity) }
      config = JSON.parse(File.read(paths.fetch(:corrected)))
      File.rename(paths.fetch(:dns_disk), paths.fetch(:dns_disk) + '.old')
      File.write(paths.fetch(:dns_disk), 'replacement same size'.ljust(File.size(paths.fetch(:dns_disk) + '.old')))
      assert_raises(Maintenance::Invalid) do
        maintenance.validate_machine_disks!(name: 'dns-primary', machine: config.fetch('machines').fetch('dns-primary'))
      end
    end
  end

  def test_recovered_pending_selection_refuses_old_maintenance_before_effects
    with_recovery_fixture do |maintenance, paths|
      maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:corrected))
      maintenance.commit_recovery!(evidence_path: paths.fetch(:recovery), next_path: paths.fetch(:corrected))
      before = File.binread(paths.fetch(:record))
      error = assert_raises(Maintenance::Invalid) { prepare(maintenance, paths) }
      assert_equal('recovered selection requires copied boot', error.message)
      error = assert_raises(Maintenance::Invalid) { maintenance.validate_runner!(config_path: paths.fetch(:resident)) }
      assert_equal('recovered selection requires copied boot', error.message)
      assert_equal(before, File.binread(paths.fetch(:record)))
    end
  end

  def test_applied_envelope_rejects_float_version
    with_applied_fixture do |maintenance, paths|
      applied = read_applied(paths).merge('version' => 1.0)
      write_json(paths.fetch(:applied), applied)
      assert_raises(Maintenance::Invalid) { maintenance.retained_selection? }
    end
  end

  def test_completed_recovered_full_boot_publishes_before_release
    with_recovery_fixture do |maintenance, paths|
      maintenance.prepare_recovery!(evidence_path: paths.fetch(:recovery), output_path: paths.fetch(:corrected))
      maintenance.commit_recovery!(evidence_path: paths.fetch(:recovery), next_path: paths.fetch(:corrected))
      maintenance.copied_config!
      maintenance.begin_boot!(config_path: paths.fetch(:corrected), operation: 'copied_boot')
      assert_raises(Maintenance::Invalid) { maintenance.release!(**identity) }
      maintenance.finish_boot!(config_path: paths.fetch(:corrected), proof_reference: 'full copied boot, seed and Node refresh completed')
      maintenance.release!(**identity)
      refute(maintenance.pending?)
      maintenance.retained_config!(output_path: paths.fetch(:rendered))
      assert_equal(JSON.parse(File.read(paths.fetch(:corrected))), JSON.parse(File.read(paths.fetch(:rendered))))
      assert_equal(2, maintenance.load_record.fetch('version'))
    end
  end

  def test_legacy_v1_reader_remains_exact_and_new_transitions_write_v2
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      legacy = maintenance.load_record.reject { |key, _| %w[predecessor recovery].include?(key) }.merge('version' => 1)
      write_json(paths.fetch(:record), legacy)
      assert_equal(1, maintenance.load_record.fetch('version'))
      bind_boot(maintenance)
      new_record = maintenance.load_record
      assert_equal(2, new_record.fetch('version'))
      # The published v1 reader's exact version/key guard cannot accept v2,
      # including a released record; no unknown-type compatibility fallback.
      %w[held released].each do |phase|
        candidate = new_record.merge('phase' => phase)
        refute(candidate.fetch('version') == 1 && candidate.keys.sort == Maintenance::RECORD_KEYS.sort)
      end
    end
  end

  private

  def payload_configuration(paths)
    config = JSON.parse(File.read(paths.fetch(:resident)))
    qemu = config.dig('machines', 'services', 'qemu')
    config.fetch('machines').each_value { |machine| machine.merge!('qemu' => qemu, 'virtiofsd' => qemu) }
    config
  end

  def identity
    { pid: 123, start: '456', boot_id: BOOT_ID }
  end

  def bind_boot(maintenance)
    maintenance.bind_boot!(**identity)
  end

  def begin_copy(maintenance, paths, **overrides)
    maintenance.begin_copy!(candidate_path: paths.fetch(:candidate), **identity.merge(overrides))
  end

  def read_applied(paths)
    JSON.parse(File.read(paths.fetch(:applied)))
  end

  def with_applied_fixture
    with_fixture do |maintenance, paths|
      prepare(maintenance, paths)
      bind_boot(maintenance)
      begin_copy(maintenance, paths)
      maintenance.build_next!(next_path: paths.fetch(:next))
      maintenance.finish_copy!(next_path: paths.fetch(:next), **identity)
      maintenance.copied_config!
      maintenance.begin_boot!(config_path: paths.fetch(:next), operation: 'copied_boot')
      maintenance.finish_boot!(config_path: paths.fetch(:next), proof_reference: 'fixture prior successful full boot')
      paths[:applied] = File.join(File.dirname(paths.fetch(:record)), 'applied-config.json')
      paths[:rendered] = paths.fetch(:next) + '-rendered.json'
      yield maintenance, paths
    end
  end

  def with_recovery_fixture
    with_fixture do |maintenance, paths|
      historic = JSON.parse(File.read(paths.fetch(:resident)))
      old_services = historic.fetch('machines').fetch('services')
      %w[node2 storage1].each do |name|
        historic.fetch('machines')[name] = historic.fetch('machines').fetch('node1').merge('toplevel' => File.join(File.dirname(paths.fetch(:resident)), "old-#{name}"))
        File.write(File.join(File.dirname(paths.fetch(:record)), 'state', "#{name}-tank.img"), 'retained node payload')
      end
      %w[dns-primary dns-secondary].each do |name|
        historic.fetch('machines')[name] = old_services.merge('toplevel' => File.join(File.dirname(paths.fetch(:resident)), "old-#{name}"))
        File.write(File.join(File.dirname(paths.fetch(:record)), 'state', "#{name}-root.img"), 'retained dns payload')
      end
      paths[:dns_disk] = File.join(File.dirname(paths.fetch(:record)), 'state', 'dns-primary-root.img')
      paths[:historic] = paths.fetch(:resident) + '-historic.json'
      write_json(paths.fetch(:historic), historic)
      selected = JSON.parse(JSON.generate(historic))
      %w[dns-primary dns-secondary].each { |name| selected.fetch('machines').fetch(name)['toplevel'] += '-never-copied' }
      write_json(paths.fetch(:resident), selected)
      update_evidence_digest(paths)
      candidate = selected.merge('machines' => selected.fetch('machines').merge(
        'services' => JSON.parse(File.read(paths.fetch(:candidate))).fetch('machines').fetch('services')),
        'labels' => { 'vpsadminPreservingSeed' => '{"version":1,"existingAssignments":"preserve"}' })
      write_json(paths.fetch(:candidate), candidate)
      prepare(maintenance, paths)
      bind_boot(maintenance)
      begin_copy(maintenance, paths)
      maintenance.build_next!(next_path: paths.fetch(:next))
      maintenance.finish_copy!(next_path: paths.fetch(:next), **identity)
      paths[:recovery] = paths.fetch(:evidence) + '-recovery.json'
      paths[:corrected] = paths.fetch(:next) + '-corrected.json'
      paths[:rendered] = paths.fetch(:next) + '-rendered.json'
      current = JSON.parse(File.read(paths.fetch(:next)))
      proofs = current.fetch('machines').to_h do |name, machine|
        dns = name.start_with?('dns-')
        source = dns ? paths.fetch(:historic) : paths.fetch(:next)
        kind = dns ? 'prior_boot' : (name == 'services' ? 'held_copy' : 'prior_update')
        [name, { 'source_config' => source, 'source_config_sha256' => Digest::SHA256.file(source).hexdigest,
                 'proof_kind' => kind, 'proof_reference' => 'actual owning fixture boot/update/copy reference',
                 'disks' => maintenance.send(:disk_identities, name:, machine:) }]
      end
      write_json(paths.fetch(:recovery), { 'version' => 1, 'kind' => 'retained_boot_recovery',
        'workspace' => File.realpath(File.join(File.dirname(paths.fetch(:resident)), '..')),
        'slug' => '2026-10-02-maintenance-fixture',
        'expected_hold_sha256' => Digest::SHA256.file(paths.fetch(:record)).hexdigest, 'machines' => proofs })
      yield maintenance, paths
    end
  end

  def prepare(maintenance, paths, evidence_path: paths.fetch(:evidence))
    maintenance.prepare!(config_path: paths.fetch(:resident), services_toplevel: paths.fetch(:toplevel), evidence_path:)
  end

  def write_json(path, value)
    File.binwrite(path, JSON.generate(value))
    File.chmod(0o600, path)
  end

  def update_evidence_digest(paths)
    evidence = JSON.parse(File.binread(paths.fetch(:evidence)))
    evidence['resident_config_sha256'] = Digest::SHA256.file(paths.fetch(:resident)).hexdigest
    write_json(paths.fetch(:evidence), evidence)
  end

  def with_fixture
    Dir.mktmpdir('maintenance-test') do |workspace|
      slug = '2026-10-02-maintenance-fixture'
      directory = File.join(workspace, '.dev-clusters', 'vpsadmin', 'clusters', slug)
      store = File.join(workspace, 'store')
      FileUtils.mkdir_p([store, File.join(directory, 'state')])
      paths = { resident: File.join(store, 'resident.json'), candidate: File.join(store, 'candidate.json'),
                evidence: File.join(directory, 'evidence.json'), missing: File.join(directory, 'missing.json'),
                record: File.join(directory, 'maintenance-hold.json'), next: File.join(store, 'next.json'),
                toplevel: File.join(store, 'old-services'), node_disk: File.join(directory, 'state', 'node1-tank.img'),
                services_disk: File.join(directory, 'state', 'services-root.img') }
      services = { 'spin' => 'nixos', 'toplevel' => paths.fetch(:toplevel),
                   'qemu' => File.join(store, 'qemu'),
                   'kernel' => File.join(store, 'old-kernel'), 'initrd' => File.join(store, 'old-initrd'),
                   'rootDisk' => { 'device' => '{machine}-root.img', 'type' => 'file', 'create' => true,
                                   'preserve' => true, 'size' => '1G', 'image' => File.join(store, 'old-image') } }
      node = { 'spin' => 'vpsadminos', 'toplevel' => File.join(store, 'old-node'),
               'kernel' => File.join(store, 'old-node-kernel'), 'initrd' => File.join(store, 'old-node-initrd'),
               'squashfs' => File.join(store, 'old-node-squashfs'),
               'disks' => [{ 'device' => '{machine}-tank.img', 'type' => 'file', 'preserve' => true }] }
      FileUtils.mkdir_p(File.join(services.fetch('qemu'), 'bin'))
      File.binwrite(File.join(services.fetch('qemu'), 'bin/qemu-system-x86_64'), 'fixture')
      File.chmod(0o755, File.join(services.fetch('qemu'), 'bin/qemu-system-x86_64'))
      File.symlink('qemu-system-x86_64', File.join(services.fetch('qemu'), 'bin/qemu-kvm'))
      write_json(paths.fetch(:resident), { 'machines' => { 'services' => services, 'node1' => node } })
      File.binwrite(paths.fetch(:services_disk), 'retained services payload')
      File.binwrite(paths.fetch(:node_disk), 'retained node payload')
      write_json(paths.fetch(:evidence), { 'version' => 1, 'workspace' => workspace, 'slug' => slug,
                                         'resident_config' => paths.fetch(:resident),
                                         'resident_config_sha256' => Digest::SHA256.file(paths.fetch(:resident)).hexdigest,
                                         'services_toplevel' => paths.fetch(:toplevel), 'evidence_kind' => 'cold_residency',
                                         'evidence_reference' => 'private reference' })
      write_json(paths.fetch(:candidate), {
        'machines' => { 'services' => services.merge('toplevel' => File.join(store, 'new-services'),
                                                    'kernel' => File.join(store, 'new-kernel'), 'initrd' => File.join(store, 'new-initrd'),
                                                    'rootDisk' => services.fetch('rootDisk').merge('image' => File.join(store, 'new-image'))),
                        'node1' => node.merge('toplevel' => File.join(store, 'not-copied-node'),
                                              'squashfs' => File.join(store, 'not-copied-node-squashfs')) },
        'labels' => { 'vpsadminPreservingSeed' => JSON.generate('version' => 1, 'existingAssignments' => 'preserve') }
      })
      maintenance = Maintenance.new(workspace:, slug:, directory:, store_root: store)
      yield maintenance, paths
    end
  end
end
