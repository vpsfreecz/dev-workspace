require 'json'
require 'minitest/autorun'
require 'tmpdir'

# Minimal OSVM types expose the consumer's required disk API.
module OsVm
  class MachineConfig
    class Disk
      attr_reader :preserve
    end

    def all_disks
      []
    end

    def self.from_config(config)
      raise 'constructed an unsupported machine' unless Disk.method_defined?(:preserve)

      Struct.new(:spin).new(config.fetch('spin'))
    end
  end

  class NixosMachine
    attr_reader :options

    def initialize(*_args, **options)
      @options = options
    end
  end

  class VpsadminosMachine < NixosMachine; end
end
$LOADED_FEATURES << 'osvm.rb'
require_relative '../dev-clusters/lib/devcluster_runner'
require_relative '../dev-clusters/vpsadmin/lib/maintenance'

class DevclusterRunnerTest < Minitest::Test
  def test_shutdown_budgets_fit_the_portal_release_contract
    contract = JSON.parse(File.read(ENV.fetch('DEVCLUSTER_RUNTIME_CONTRACT')))
    budgets = DevClusters::OsVmRunner::SHUTDOWN.values
    assert(budgets.all? { |seconds| seconds.is_a?(Integer) && seconds.positive? })
    assert_operator(budgets.sum, :<, contract.fetch('clusterProvider').fetch('releaseTimeoutSeconds'))
  end

  def test_both_guests_use_the_generic_disk_defaults
    with_runner do |runner, options|
      machines = runner.send(:build_machines, options)
      assert_equal(2, machines.length)
      machines.each do |entry|
        assert_equal({ default_timeout: 30, hash_base: 'test' }, entry.machine.options)
      end
    end
  end

  def test_old_osvm_is_rejected_before_machine_construction
    with_runner do |runner, options|
      with_legacy_disk do
        error = assert_raises(RuntimeError) { runner.send(:build_machines, options) }
        assert_includes(error.message, 'per-disk preservation')
      end
    end
  end

  def test_vpsadminos_only_clusters_also_require_the_disk_api
    with_runner do |runner, options|
      File.write(options.fetch(:config), JSON.generate('machines' => { 'node1' => { 'spin' => 'vpsadminos' } }))
      with_legacy_disk do
        error = assert_raises(RuntimeError) { runner.send(:build_machines, options) }
        assert_includes(error.message, 'per-disk preservation')
      end
    end
  end

  def test_typed_maintenance_validates_before_constructing_only_services
    with_runner do |_runner, options|
      calls = []
      policy = Class.new do
        define_method(:initialize) { |**identity| calls << [:identity, identity] }
        define_method(:validate_runner!) do |config_path:|
          calls << [:validated, config_path]
          ['systemd.mask=timers.target']
        end
        define_method(:validate_machine_disks!) { |**| }
      end
      runner = DevClusters::OsVmRunner.new([], hash_base: 'test', priority_machines: ['services'], maintenance_policy: policy)
      machines = runner.send(:build_machines, options.merge(maintenance: true))
      assert_equal(['services'], machines.map(&:name))
      assert_equal([:validated, options.fetch(:config)], calls.last)
      started = []
      machines.first.machine.define_singleton_method(:start) { |**kwargs| started << kwargs }
      machines.first.machine.define_singleton_method(:wait_for_boot) { |timeout:| }
      runner.send(:start_machines, machines, 30, kernel_params: runner.instance_variable_get(:@maintenance_kernel_params))
      assert_equal([{ kernel_params: ['systemd.mask=timers.target'], wait_for_boot: false }], started)
    end
  end

  def test_other_provider_cannot_select_maintenance_mode
    %w[--maintenance --copied-config].each do |mode|
      runner = DevClusters::OsVmRunner.new(['start', mode], hash_base: 'test', priority_machines: [])
      assert_raises(OptionParser::InvalidOption) { runner.run }
    end
  end

  def test_missing_disk_after_construction_refuses_both_recorded_boot_modes
    %i[maintenance copied_config].each do |mode|
      with_recorded_runner(mode) do |runner, options, disk|
        machines = runner.send(:build_machines, options)
        started = []
        machines.each do |entry|
          entry.machine.define_singleton_method(:start) do |**|
            started << entry.name
            File.write(disk, 'replacement image') unless File.exist?(disk)
          end
          entry.machine.define_singleton_method(:wait_for_boot) { |**| }
        end
        File.unlink(disk)
        assert_raises(DevClusters::VpsAdminMaintenance::Invalid, mode.to_s) do
          runner.send(:start_machines, machines, 30, kernel_params: runner.instance_variable_get(:@maintenance_kernel_params))
        end
        assert_empty(started)
        refute(File.exist?(disk))
      end
    end
  end

  def test_failed_maintenance_policy_never_constructs_a_machine
    with_runner do |_runner, options|
      policy = Class.new do
        def initialize(**); end
        def validate_runner!(**)
          raise 'residency validation failed'
        end
      end
      runner = DevClusters::OsVmRunner.new([], hash_base: 'test', priority_machines: [], maintenance_policy: policy)
      error = assert_raises(RuntimeError) { runner.send(:build_machines, options.merge(maintenance: true)) }
      assert_equal('residency validation failed', error.message)
    end
  end

  def test_shutdown_starts_all_guests_before_waiting_for_any_guest
    entered = Queue.new
    release = Queue.new
    machines = 3.times.map do |index|
      machine = Object.new
      machine.define_singleton_method(:stop) { |timeout:| entered << index; release.pop }
      DevClusters::OsVmRunner::MachineState.new(name: index.to_s, machine: machine)
    end
    runner = DevClusters::OsVmRunner.new([], hash_base: 'test', priority_machines: [])
    worker = Thread.new { runner.send(:stop_machines, machines, timeout: 2) }
    Timeout.timeout(1) { 3.times { entered.pop } }
    3.times { release << true }
    worker.value
  ensure
    worker&.kill
  end

  def test_shutdown_bounds_a_stuck_poweroff_and_reaps_the_guest
    killed = []
    machine = Object.new
    machine.define_singleton_method(:stop) { |timeout:| sleep 10 }
    machine.define_singleton_method(:kill) { |signal:| killed << signal }
    entry = DevClusters::OsVmRunner::MachineState.new(name: 'stuck', machine: machine)
    runner = DevClusters::OsVmRunner.new([], hash_base: 'test', priority_machines: [])
    Timeout.timeout(1) { runner.send(:stop_machines, [entry], timeout: 0.02) }
    assert_equal(['KILL'], killed)
  end

  def with_legacy_disk
    original = OsVm::MachineConfig.send(:remove_const, :Disk)
    OsVm::MachineConfig.const_set(:Disk, Class.new)
    yield
  ensure
    OsVm::MachineConfig.send(:remove_const, :Disk)
    OsVm::MachineConfig.const_set(:Disk, original)
  end

  def with_runner
    Dir.mktmpdir('devcluster-runner-test') do |directory|
      config = File.join(directory, 'config.json')
      File.write(config, JSON.generate('machines' => {
        'services' => { 'spin' => 'nixos' }, 'node1' => { 'spin' => 'vpsadminos' }
      }))
      options = { config: config, state_dir: directory, sock_dir: directory, timeout: 30 }
      runner = DevClusters::OsVmRunner.new([], hash_base: 'test', priority_machines: [])
      yield runner, options
    end
  end

  def with_recorded_runner(mode)
    Dir.mktmpdir('recorded-runner-test') do |workspace|
      slug = '2026-10-02-recorded-runner'
      directory = File.join(workspace, '.dev-clusters/vpsadmin/clusters', slug)
      state = File.join(directory, 'state')
      store = File.join(workspace, 'store')
      top = File.join(store, 'services')
      qemu = File.join(store, 'qemu')
      systemd = File.join(store, 'systemd')
      FileUtils.mkdir_p([state, File.join(qemu, 'bin'), File.join(top, 'sw/bin'),
                        File.join(top, 'etc/systemd/system'), File.join(systemd, 'bin'),
                        File.join(systemd, 'lib/systemd/system-generators')])
      File.write(File.join(qemu, 'bin/qemu-kvm'), 'fixture')
      File.chmod(0o755, File.join(qemu, 'bin/qemu-kvm'))
      File.write(File.join(systemd, 'bin/systemctl'), 'fixture')
      generator = File.join(systemd, 'lib/systemd/system-generators/systemd-debug-generator')
      File.write(generator, 'fixture')
      File.chmod(0o755, generator)
      File.symlink(File.join(systemd, 'bin/systemctl'), File.join(top, 'sw/bin/systemctl'))
      File.write(File.join(top, 'activate'), '# fixture')
      disk = File.join(state, 'services-root.img')
      File.write(disk, 'retained sentinel')
      config = File.join(store, 'resident.json')
      machine = { 'spin' => 'nixos', 'toplevel' => top, 'qemu' => qemu,
                  'kernel' => File.join(store, 'kernel'), 'initrd' => File.join(store, 'initrd'),
                  'rootDisk' => { 'device' => '{machine}-root.img', 'type' => 'file', 'preserve' => true, 'size' => '1G' } }
      File.write(config, JSON.generate('machines' => { 'services' => machine }))
      evidence = File.join(directory, 'evidence.json')
      File.write(evidence, JSON.generate('version' => 1, 'workspace' => workspace, 'slug' => slug,
                                       'resident_config' => config, 'resident_config_sha256' => Digest::SHA256.file(config).hexdigest,
                                       'services_toplevel' => top, 'evidence_kind' => 'prior_copy', 'evidence_reference' => 'fixture'))
      File.chmod(0o600, evidence)
      policy_class = Class.new(DevClusters::VpsAdminMaintenance) do
        define_method(:initialize) { |**identity| super(**identity, store_root: store) }
      end
      policy = policy_class.new(workspace:, slug:, directory:)
      policy.prepare!(config_path: config, services_toplevel: top, evidence_path: evidence)
      if mode == :copied_config
        identity = { pid: 123, start: '456', boot_id: '01111111-2222-3333-4444-555555555555' }
        policy.bind_boot!(**identity)
        candidate = File.join(store, 'candidate.json')
        File.write(candidate, JSON.generate('machines' => { 'services' => machine },
                                            'labels' => { 'vpsadminPreservingSeed' => '{"version":1,"existingAssignments":"preserve"}' }))
        policy.begin_copy!(candidate_path: candidate, **identity)
        config = File.join(store, 'next.json')
        policy.build_next!(next_path: config)
        policy.finish_copy!(next_path: config, **identity)
        policy.copied_config!
      end
      options = { config:, state_dir: state, sock_dir: state, timeout: 30, mode => true }
      runner = DevClusters::OsVmRunner.new([], hash_base: 'test', priority_machines: ['services'], maintenance_policy: policy_class)
      yield runner, options, disk
    end
  end
end
