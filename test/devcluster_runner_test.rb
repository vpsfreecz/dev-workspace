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
end
