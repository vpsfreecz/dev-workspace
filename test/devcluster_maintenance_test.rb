require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative '../dev-clusters/vpsadmin/lib/maintenance'

class DevclusterMaintenanceTest < Minitest::Test
  Maintenance = DevClusters::VpsAdminMaintenance
  BOOT_ID = '01111111-2222-3333-4444-555555555555'.freeze

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
      assert_equal({ 'version' => 1, 'mode' => 'maintenance', 'phase' => 'held',
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

  private

  def identity
    { pid: 123, start: '456', boot_id: BOOT_ID }
  end

  def bind_boot(maintenance)
    maintenance.bind_boot!(**identity)
  end

  def begin_copy(maintenance, paths, **overrides)
    maintenance.begin_copy!(candidate_path: paths.fetch(:candidate), **identity.merge(overrides))
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
                        'node1' => node.merge('toplevel' => File.join(store, 'not-copied-node')) },
        'labels' => { 'vpsadminPreservingSeed' => JSON.generate('version' => 1, 'existingAssignments' => 'preserve') }
      })
      maintenance = Maintenance.new(workspace:, slug:, directory:, store_root: store)
      yield maintenance, paths
    end
  end
end
