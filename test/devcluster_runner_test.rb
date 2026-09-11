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
