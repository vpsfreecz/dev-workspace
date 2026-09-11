require 'json'
require 'minitest/autorun'
require 'tmpdir'

# Minimal OSVM constructors expose the cross-repository keyword contract.
module OsVm
  class MachineConfig
    def self.from_config(config)
      Struct.new(:spin).new(config.fetch('spin'))
    end
  end

  class NixosMachine
    attr_reader :preserve_root_disk

    def initialize(*_args, preserve_root_disk: false, **_options)
      @preserve_root_disk = preserve_root_disk
    end
  end

  class VpsadminosMachine
    attr_reader :options

    def initialize(*_args, **options)
      @options = options
    end
  end
end
$LOADED_FEATURES << 'osvm.rb'
require_relative '../dev-clusters/lib/devcluster_runner'

class DevclusterRunnerTest < Minitest::Test
  def test_only_nixos_guests_request_root_disk_preservation
    with_runner do |runner, options|
      machines = runner.send(:build_machines, options)
      assert(machines[0].machine.preserve_root_disk)
      refute(machines[1].machine.options.key?(:preserve_root_disk))
    end
  end

  def test_old_osvm_is_rejected_before_machine_construction
    with_runner do |runner, options|
      with_legacy_nixos_machine do
        error = assert_raises(RuntimeError) { runner.send(:build_machines, options) }
        assert_includes(error.message, 'persistent NixOS root disks')
      end
    end
  end

  def test_vpsadminos_only_clusters_do_not_require_the_nixos_disk_option
    with_runner do |runner, options|
      File.write(options.fetch(:config), JSON.generate('machines' => { 'node1' => { 'spin' => 'vpsadminos' } }))
      with_legacy_nixos_machine do
        machines = runner.send(:build_machines, options)
        assert_equal(1, machines.length)
        refute(machines.first.machine.options.key?(:preserve_root_disk))
      end
    end
  end

  def with_legacy_nixos_machine
    original = OsVm.send(:remove_const, :NixosMachine)
    legacy = Class.new do
      def initialize(*)
        raise 'constructed an unsupported machine'
      end
    end
    OsVm.const_set(:NixosMachine, legacy)
    yield
  ensure
    OsVm.send(:remove_const, :NixosMachine)
    OsVm.const_set(:NixosMachine, original)
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
