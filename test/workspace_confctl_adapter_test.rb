# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/workspace_confctl_adapter'

# A confctl public-API fixture; no Nix, SSH or machine mutation in these tests.
module ConfCtl
  class Logger
    def self.open(_name, output:)
      raise 'library diagnostics must use stderr' unless output.equal?(STDERR)
      ConfCtl.events << [:logger_open]
    end
  end
  class << self
    attr_accessor :events, :live, :profile, :fail_publication, :rollback
  end
  class Machine
    attr_reader :meta
    def initialize(config, machine_list: nil)
      @meta = config['metaConfig']
    end
    def name = 'standalone/testhost'
    def spin = 'nixos'
    def carried? = false
    def cluster_name = 'standalone'
    def key = 'testhost'
    def target_host = 'host.example.test'
    def target_port = 22
    def profile = '/nix/var/nix/profiles/system'
    def auto_rollback? = ConfCtl.rollback
  end
  class MachineList
    def [](selector)
      selector == 'standalone/testhost' ? Machine.new({'metaConfig' => {}}) : nil
    end
  end
  class MachineControl
    def initialize(machine); end
    def read_realpath(path)
      raise 'library logger not initialized' unless ConfCtl.events.any? { |event| event.first == :logger_open }
      ConfCtl.events << [:inspect, path]
      path == '/run/current-system' ? ConfCtl.live : ConfCtl.profile
    end
  end
  module Generation
    class Build
      def initialize(selector); end
      def load(name); end
      def name = 'fixture-generation'
      def dir = File.join(Dir.pwd, 'generation')
      def toplevel = '/nix/store/fixture-system'
      def auto_rollback = '/nix/store/fixture-rollback'
      def inputs_info = {'runtime' => {'url' => 'github:example/runtime', 'rev' => 'a' * 40}}
      def inputs = {}
    end
  end
  class Nix
    def self.stateless(show_trace: false, max_jobs: 'auto')
      new(show_trace:, max_jobs:)
    end
    def initialize(show_trace: false, max_jobs: nil)
      # The pinned constructor reads Settings (and evaluates Nix) by default.
      ConfCtl.events << [:settings_evaluation] unless max_jobs
    end
    def build_attributes(hosts:)
      ConfCtl.events << [:build, hosts]
      {hosts.first => Generation::Build.new(hosts.first)}
    end
    def copy(machine, paths)
      ConfCtl.events << [:copy, paths]
      true
    end
    def activate(machine, generation, action)
      ConfCtl.events << [:activate, action]
      ConfCtl.live = generation.toplevel unless action == 'dry-activate'
      true
    end
    def activate_with_rollback(machine, generation, action)
      ConfCtl.events << [:rollback, action]
      ConfCtl.live = generation.toplevel
      true
    end
    def set_profile(machine, path)
      ConfCtl.events << [:publish, path]
      raise 'fixture publication failure' if ConfCtl.fail_publication
      ConfCtl.profile = path
      true
    end
  end
end
$LOADED_FEATURES << 'confctl.rb'

class WorkspaceConfctlAdapterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@directory, 'generation'))
    File.write(File.join(@directory, 'generation/generation.json'), JSON.generate('mode' => 'flakes', 'toplevel' => '/nix/store/fixture-system'))
    ConfCtl.events, ConfCtl.live, ConfCtl.profile, ConfCtl.rollback, ConfCtl.fail_publication = [], '/nix/store/baseline', '/nix/store/baseline', true, false
    @mapping = {'id' => 'example:host', 'aliases' => [], 'adapter' => 'confctl', 'configurationRepository' => 'configuration', 'selector' => 'standalone/testhost'}
    @attempt = SecureRandom.uuid
    @attempt_directory = File.join(@directory, 'attempts', @attempt)
    FileUtils.mkdir_p(@attempt_directory, mode: 0o700)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def call(operation, values)
    WorkspaceConfctlAdapter.run(JSON.generate({'schema' => 1, 'operation' => operation, 'target' => 'example:host', 'machine' => @mapping}.merge(values)), pinned: true)
  end

  def prepare
    response = call('prepare', 'requestId' => SecureRandom.uuid, 'source' => {'path' => @directory, 'revision' => 'a' * 40}, 'stateRoot' => @directory)
    @artifact = response['artifact'].merge('source' => @directory)
    @baseline = response['observed']
  end

  def activation_values
    {'artifact' => @artifact, 'expectedLive' => @baseline, 'attemptId' => @attempt,
      'requestDigest' => 'sha256:' + ('b' * 64), 'attemptDirectory' => @attempt_directory}
  end

  def test_only_preparation_builds_and_copies_and_activation_preserves_rollback
    prepare
    assert_equal 1, ConfCtl.events.count { |event| event.first == :build }
    assert_equal 1, ConfCtl.events.count { |event| event.first == :copy }
    ConfCtl.events.clear
    result = call('activate', activation_values)
    assert_equal 'applied', result['outcome']
    assert_equal [[:activate, 'dry-activate'], [:rollback, 'switch'], [:publish, '/nix/store/fixture-system']], ConfCtl.events.select { |event| %i[activate rollback publish].include?(event.first) }
    refute ConfCtl.events.any? { |event| %i[build copy settings_evaluation].include?(event.first) }
    assert_equal '/nix/store/fixture-system', result['observed']['runningSystem']
    assert_equal '/nix/store/fixture-system', result['observed']['systemProfile']
    assert_equal result, call('reconcile', activation_values)
  end

  def test_changed_baseline_never_activates
    prepare
    ConfCtl.profile = '/nix/store/foreign-system'
    ConfCtl.events.clear
    result = call('activate', activation_values)
    assert_equal 'baseline_changed', result['outcome']
    assert ConfCtl.events.all? { |event| %i[logger_open inspect].include?(event.first) }
  end

  def test_partial_publication_and_baseline_looking_recovery_stay_unknown
    prepare
    ConfCtl.fail_publication = true
    result = call('activate', activation_values)
    assert_equal 'unknown', result['outcome']
    assert_equal '/nix/store/fixture-system', ConfCtl.live
    assert_equal '/nix/store/baseline', ConfCtl.profile
    ConfCtl.events.clear
    assert_equal 'unknown', call('reconcile', activation_values)['outcome']
    ConfCtl.live = '/nix/store/baseline'
    assert_equal 'unknown', call('reconcile', activation_values)['outcome']
    refute ConfCtl.events.any? { |event| %i[build copy rollback activate publish].include?(event.first) }
  end

  def test_wrong_selector_and_unknown_fields_refuse_before_build
    @mapping['selector'] = '*'
    assert_raises(RuntimeError) { prepare }
    assert_equal [[:logger_open]], ConfCtl.events
    assert_raises(RuntimeError) { call('inspect', 'artifact' => {}, 'command' => 'arbitrary') }
  end
end
