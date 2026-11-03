# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/workspace_confctl_adapter'

# A confctl public-API fixture; real local Nix projection is opt-in below.
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

  def resolution_request(selector = 'standalone/testhost')
    {'schema' => 1, 'operation' => 'resolve-machine', 'selector' => selector,
      'source' => {'path' => @directory, 'revision' => 'a' * 40}}
  end

  def resolve_stub(request = resolution_request, output: nil, calls: [], revision: nil)
    output ||= JSON.generate('schema' => 1, 'name' => request['selector'], 'sharedLockId' => nil)
    revision ||= request.dig('source', 'revision')
    original = WorkspaceConfctlAdapter.method(:capture)
    WorkspaceConfctlAdapter.define_singleton_method(:capture) do |*args|
      calls << args
      args.first == 'git' ? revision : output
    end
    WorkspaceConfctlAdapter.run(JSON.generate(request))
  ensure
    WorkspaceConfctlAdapter.define_singleton_method(:capture, original) if original
  end

  def test_resolution_projects_only_identity_without_deployment_or_probes
    calls = []
    assert_equal({'schema' => 1, 'name' => 'standalone/testhost', 'sharedLockId' => nil},
      resolve_stub(calls:))
    assert_equal %w[git nix], calls.map(&:first)
    assert_equal ['git', '-C', @directory, 'rev-parse', '--verify', "#{'a' * 40}^{commit}"], calls.first
    assert_equal ['nix', 'eval', '--offline', '--no-write-lock-file', '--no-update-lock-file',
      '--option', 'allow-import-from-derivation', 'false', '--json', '--expr'], calls.last[0...-1]
    assert_empty ConfCtl.events
  end

  def test_resolution_preserves_exact_unicode_and_shared_labels_at_the_byte_bound
    request = resolution_request('host.example.test')
    ['shared:group/č', 'é' * 128].each do |label|
      output = JSON.generate('schema' => 1, 'name' => request['selector'], 'sharedLockId' => label)
      assert_equal label, resolve_stub(request, output:)['sharedLockId']
    end
    request['selector'] = 'č' * 128
    assert_equal request['selector'], resolve_stub(request)['name']
  end

  def test_resolution_rejects_malformed_protocol_source_and_identity_before_evaluation
    base = resolution_request
    invalid = [base.merge('extra' => true), base.reject { |key, _| key == 'source' },
      base.merge('schema' => 1.0), base.merge('source' => nil),
      base.merge('source' => base['source'].merge('revision' => 'master')),
      base.merge('source' => base['source'].merge('path' => 'relative')),
      base.merge('source' => base['source'].merge('extra' => true)),
      base.merge('attemptDirectory' => File.join(@directory, 'must-not-write'))]
    ['', " host", "host\u00a0", "ho\u0085st", "host\nname", 'é' * 129].each do |selector|
      invalid << base.merge('selector' => selector)
    end
    calls = []
    invalid.each { |request| assert_raises(RuntimeError) { resolve_stub(request, calls:) } }
    assert_empty calls
    refute File.exist?(File.join(@directory, 'must-not-write'))
    duplicate = JSON.generate(base).sub('"schema":1', '"schema":1,"schema":1')
    assert_raises(RuntimeError) { WorkspaceConfctlAdapter.run(duplicate) }
    assert_raises(RuntimeError) { WorkspaceConfctlAdapter.run(' ' * (WorkspaceConfctlAdapter::LIMIT + 1)) }
  end

  def test_resolution_rejects_wrong_commit_and_malformed_or_unbounded_results
    assert_raises(RuntimeError) { resolve_stub(revision: 'b' * 40) }
    result = {'schema' => 1, 'name' => 'standalone/testhost', 'sharedLockId' => nil}
    invalid = [result.merge('extra' => true), result.reject { |key, _| key == 'sharedLockId' },
      result.merge('name' => 'another'), result.merge('schema' => 1.0)]
    [false, 3, '', ' shared', "shared\u00a0", "shared\u007f", 'é' * 129].each do |label|
      invalid << result.merge('sharedLockId' => label)
    end
    invalid.each { |value| assert_raises(RuntimeError) { resolve_stub(output: JSON.generate(value)) } }
    assert_raises(RuntimeError) { resolve_stub(output: JSON.generate(result).sub('"schema":1', '"schema":1,"schema":1')) }
    assert_raises(RuntimeError) { resolve_stub(output: ' ' * (WorkspaceConfctlAdapter::LIMIT + 1)) }
    invalid_utf8 = JSON.generate(result.merge('sharedLockId' => 'invalid')).sub('invalid', "\xff".b).force_encoding(Encoding::UTF_8)
    assert_raises(RuntimeError) { resolve_stub(output: invalid_utf8) }
    assert_empty ConfCtl.events
  end

  def test_resolution_retains_the_shared_command_output_bound
    status = Struct.new(:success?).new(true)
    options = nil
    original = WorkspaceCoordination::Command.method(:run)
    WorkspaceCoordination::Command.define_singleton_method(:run) do |_args, **keywords|
      options = keywords
      ['', '', status, true]
    end
    assert_raises(RuntimeError) { WorkspaceConfctlAdapter.run(JSON.generate(resolution_request)) }
    assert_equal WorkspaceConfctlAdapter::LIMIT, options[:limit]
  ensure
    WorkspaceCoordination::Command.define_singleton_method(:run, original)
  end

  def test_resolution_evaluates_an_immutable_disposable_flake_offline_without_ifd
    skip 'enable WORKSPACE_CONFCTL_LOCAL_EVAL=1 outside the build sandbox' unless ENV['WORKSPACE_CONFCTL_LOCAL_EVAL'] == '1'
    repository = File.join(@directory, 'metadata source#fixture')
    FileUtils.mkdir_p(repository)
    git = lambda do |*args|
      output, error, status = Open3.capture3('git', '-C', repository, *args)
      assert status.success?, error
      output.strip
    end
    git.call('init', '--initial-branch=master')
    flake = File.join(repository, 'flake.nix')
    File.write(flake, <<~'NIX')
      {
        outputs = { self }: {
          confctl.machines = {
            "host.example.test" = { name = "host.example.test"; metaConfig.labels = {}; };
            "shared/č" = { name = "shared/č"; metaConfig = {
              labels."dev-workspace.lock-id" = "old-shared";
              private = throw "full machine metadata was evaluated";
            }; };
            "literal${name" = { name = "literal${name"; metaConfig.labels = {}; };
            "null" = { name = "null"; metaConfig.labels."dev-workspace.lock-id" = null; };
            "empty" = { name = "empty"; metaConfig.labels."dev-workspace.lock-id" = ""; };
            "malformed" = { name = "malformed"; metaConfig.labels."dev-workspace.lock-id" = 42; };
            "bad-labels" = { name = "bad-labels"; metaConfig.labels = null; };
            "wrong" = { name = "different"; metaConfig.labels = {}; };
            "ifd" = { name = "ifd"; metaConfig.labels."dev-workspace.lock-id" =
              builtins.readFile (builtins.derivation {
                name = "must-not-build"; system = "x86_64-linux"; builder = "/bin/false";
              }); };
          };
          confctl.machinesJson = throw "machinesJson must not build";
          packages.x86_64-linux.default = throw "packages must not build";
        };
      }
    NIX
    # Nix literal strings must preserve the interpolation-shaped configured name.
    File.write(flake, File.read(flake).gsub('${') { '\${' })
    message = File.join(@directory, 'message')
    File.write(message, "fixture: retain exact machine metadata\n")
    git.call('add', 'flake.nix')
    git.call('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-F', message)
    revision = git.call('rev-parse', 'HEAD')
    File.write(flake, File.read(flake).sub('old-shared', 'changed-head'))
    git.call('add', 'flake.nix')
    git.call('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-F', message)
    bare = File.join(@directory, 'canonical metadata#?.git')
    git.call('clone', '--bare', repository, bare)
    resolve = lambda do |selector|
      request = resolution_request(selector)
      request['source'] = {'path' => bare, 'revision' => revision}
      WorkspaceConfctlAdapter.run(JSON.generate(request))
    end
    assert_nil resolve.call('host.example.test')['sharedLockId']
    assert_equal 'old-shared', resolve.call('shared/č')['sharedLockId']
    assert_equal 'literal${name', resolve.call('literal${name')['name']
    %w[null empty malformed bad-labels wrong missing ifd].each do |selector|
      error = assert_raises(RuntimeError) { resolve.call(selector) }
      assert_match(/import.from.derivation|allow-import-from-derivation/, error.message) if selector == 'ifd'
    end
    request = resolution_request
    request['source'] = {'path' => bare, 'revision' => 'f' * 40}
    assert_raises(RuntimeError) { WorkspaceConfctlAdapter.run(JSON.generate(request)) }
    refute File.exist?(File.join(repository, 'flake.lock'))
    assert_empty ConfCtl.events
  end
end
