# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'shellwords'
require 'socket'
require 'timeout'
require 'osvm'
require 'test-runner'
require 'maintenance'

# This fixture owns services and one DNS disk, not a registered cluster.
# It never releases the full-cluster hold or substitutes for Node refresh.
class RetainedServicesMaintenanceFixture < TestRunner::TestEvaluator
  PORT = 19_122
  MAX_SECONDS = 3600
  COUNTER_NAMES = %w[old-api old-supervisor old-scheduler old-seed old-auth-tokens
                     new-api new-supervisor new-scheduler new-seed new-auth-tokens].freeze
  Invalid = Class.new(StandardError)
  SCRIPT = <<~RUBY
    configure_examples { |config| config.default_order = :defined }
    describe 'retained services maintenance', order: :defined do
      it 'preserves assignments and payload through interrupted copy and copied boot' do
        Timeout.timeout(RetainedServicesMaintenanceFixture::MAX_SECONDS) { run_scenario! }
      end
    end
  RUBY

  # Upstream construction rebuilds through NixCli; this fixture has sealed
  # packaged inputs and deliberately adapts only that constructor boundary.
  def initialize(options) # rubocop:disable Lint/MissingSuper
    @options = options
    @directory = File.realpath(options.fetch(:artifact_dir))
    raise Invalid, 'fixture artifact directory is not private and empty' unless
      File.stat(@directory).mode & 0o777 == 0o700 && Dir.empty?(@directory)

    @resident_path = store_json!(options.fetch(:resident_config))
    @candidate_path = store_json!(options.fetch(:candidate_config))
    @resident = JSON.parse(File.binread(@resident_path))
    @candidate = JSON.parse(File.binread(@candidate_path))
    @historical_path = @resident_path
    @historical = @resident
    [@resident, @candidate].each do |config|
      unless config.fetch('machines').keys.sort == %w[dns-primary services]
        raise Invalid, 'fixture configuration must contain services and one DNS guest'
      end
    end
    @state = File.join(@directory, 'state')
    @sockets = File.join(@directory, 'sockets')
    FileUtils.mkdir_p([@state, @sockets], mode: 0o700)
    @policy = new_policy
    @summary = { 'passed' => 0, 'hold_released' => 0, 'stage' => 0 }
    descriptor = { 'description' => 'Retained services maintenance', 'expectFailure' => false,
                   'attempts' => 1, 'tags' => [], 'labels' => {}, 'script' => SCRIPT }
    @test = TestRunner::Test.new(path: 'retained-services-maintenance', type: 'file',
                                 name: 'retained-services-maintenance', description: descriptor.fetch('description'),
                                 attempts: 1, expect_failure: false, test_script_jobs: 1,
                                 tags: [], labels: {}, test_scripts: { 'default' => descriptor })
    @scripts = [@test.test_scripts.fetch('default')]
    # Only construction is adapted: upstream execution, examples, hooks,
    # result handling and cleanup remain responsible for this shared registry.
    @opts = { default_timeout: 300, destructive: false, recreate_disks: false,
              state_dir: @state, sock_dir: @sockets }
    @config = @resident.merge('testScripts' => { 'default' => descriptor })
    raise Invalid, 'fixture framework configuration is invalid' unless @config.fetch('framework').is_a?(Hash)

    @machines = {}
    @default_timeout = @opts.fetch(:default_timeout)
    @used_container_ids = []
    @used_container_ids_mutex = Mutex.new
    @log_mutex = Mutex.new
    @key = ENV.fetch('RETAINED_SERVICES_FIXTURE_SSH_KEY')
    @ssh_options = ['-i', @key, '-p', PORT.to_s, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                    '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=#{@directory}/known-hosts",
                    '-o', 'ConnectTimeout=5']
  end

  attr_reader :summary

  def run_scenario!
    refuse_existing_listener!
    @summary['stage'] = 1
    boot!(@resident)
    wait!('for unit in vpsadmin-api.service vpsadmin-supervisor.service vpsadmin-scheduler.service; ' \
          'do systemctl is-active --quiet "$unit" || exit 1; done')
    mutate_retained_fixture!
    guest!('mkdir -p /var/lib/storage-profile-fixture; printf retained-payload > /var/lib/storage-profile-fixture/payload')
    %w[vpsadmin-api-auth-tokens.timer vpsadmin-api-auth-tokens.service].each do |unit|
      guest!("systemctl stop #{unit}")
      expect(guest!("systemctl show #{unit} --property=ActiveState --value").strip).to eq('inactive')
    end
    @projection = projections
    @payload = guest!('sha256sum /var/lib/storage-profile-fixture/payload').split.first
    @old_dns_toplevel = dns_execute!('readlink -e /run/current-system').strip
    expect(@old_dns_toplevel).to eq(@resident.fetch('machines').fetch('dns-primary').fetch('toplevel'))
    candidate_dns = @candidate.fetch('machines').fetch('dns-primary').fetch('toplevel')
    expect(candidate_dns).not_to eq(@old_dns_toplevel)
    code, = machines.fetch('dns-primary').execute(
      "nix-store --check-validity #{quote(candidate_dns)}", timeout: 30
    )
    expect(code).not_to eq(0)
    dns_execute!('printf retained-dns-payload > /var/lib/retained-dns-payload')
    @dns_payload = dns_execute!('sha256sum /var/lib/retained-dns-payload').split.first
    @old_counters = counters
    expect(@old_counters.fetch('old-seed', 0).positive?).to be(true)
    save_private('before.json', @projection)
    stop!
    @disk_identity = disk_identity
    @dns_disk_identity = File.stat(File.join(@state, 'dns-primary-root.img')).then { |stat| [stat.dev, stat.ino, stat.size] }
    save_private('preservation-baseline.json', {
                   'projection_sha256' => @projection.transform_values { |value| Digest::SHA256.hexdigest(value) },
                   'payload_sha256' => @payload, 'counters' => counter_diagnostics(@old_counters),
                   'services_disk' => @disk_identity, 'dns_disk' => @dns_disk_identity,
                   'dns_payload_sha256' => @dns_payload
                 })
    select_legacy_candidate_dns!
    evidence = File.join(@directory, 'residency.json')
    save_private('residency.json', {
                   'version' => 1, 'workspace' => @directory, 'slug' => 'retained-services-fixture',
                   'resident_config' => @resident_path, 'resident_config_sha256' => Digest::SHA256.file(@resident_path).hexdigest,
                   'services_toplevel' => old_toplevel, 'evidence_kind' => 'prior_activation',
                   'evidence_reference' => 'actual old services boot; legacy candidate DNS intentionally unproved'
                 })
    @policy.prepare!(config_path: @resident_path, services_toplevel: old_toplevel, evidence_path: evidence)

    @summary['stage'] = 2
    masked_boot!
    original_identity = identity
    @policy.bind_boot!(**original_identity)
    check_preservation!
    check_masks!
    %w[nginx.service container@webui.service vpsadmin-api.service].each do |unit|
      code, = services.execute("systemctl start #{unit}", timeout: 30)
      expect(!code.zero?).to be(true)
    end
    # The real accelerated timer must not launch a writer during the hold.
    sleep 3
    check_preservation!

    @summary['stage'] = 3
    @policy.begin_copy!(candidate_path: @candidate_path, **original_identity)
    @policy.root_source_config!(config_path: @candidate_path)
    @policy.root_host_payloads!(config_path: @candidate_path, machines: ['services'])
    paths = host!('nix-store', '--query', '--requisites', new_toplevel).lines.map(&:strip)
    partial = paths.find { |path| path.end_with?('-vpsadmin-storage-profile.json') }
    expect(!partial.nil?).to be(true)
    interrupted_copy!(partial)
    expect(@policy.status.fetch('phase') == 'copying').to be(true)
    expect_refusal! { @policy.copied_config! }
    code, = services.execute("nix-store --check-validity #{quote(new_toplevel)}", timeout: 30)
    expect(!code.zero?).to be(true)
    check_preservation!
    stop!
    check_missing_disk_refusal!

    @summary['stage'] = 4
    masked_boot!
    second_identity = identity
    expect(second_identity.fetch(:boot_id) != original_identity.fetch(:boot_id)).to be(true)
    expect_refusal! { @policy.begin_copy!(candidate_path: @candidate_path, **second_identity) }
    @policy.bind_boot!(**second_identity)
    expect_refusal! { @policy.begin_copy!(candidate_path: @candidate_path, **original_identity) }
    @policy.begin_copy!(candidate_path: @candidate_path, **second_identity)
    @policy.root_source_config!(config_path: @candidate_path)
    @policy.root_host_payloads!(config_path: @candidate_path, machines: ['services'])
    # A full real copy can finish while its worker dies before publication.
    interrupted_copy!(new_toplevel)
    @policy = new_policy
    expect(@policy.status.fetch('phase') == 'copying').to be(true)
    expect_refusal! { @policy.copied_config! }
    verify_copied!(new_toplevel)
    # A present store file without executable init is insufficient.
    expect { verify_copied!(partial) }.to raise_error(Invalid, /guest command failed/)
    expect_refusal! { @policy.begin_copy!(candidate_path: @resident_path, **second_identity) }
    check_preservation!
    @policy.build_next!(next_path: File.join(@directory, 'next.json'))
    @next_path = host!('nix-store', '--add', File.join(@directory, 'next.json')).strip
    store_json!(@next_path)
    @policy.root_source_config!(config_path: @next_path)
    host!('nix-store', '--option', 'substitute', 'false', '--add-root', File.join(@directory, 'next-root'), '--indirect', '--realise', @next_path)
    @policy.root_host_payloads!(config_path: @next_path)
    @policy.finish_copy!(next_path: @next_path, **second_identity)
    expect(identity == second_identity).to be(true)
    expect(guest!('readlink -f /run/current-system').strip == old_toplevel).to be(true)
    expect(@policy.status.fetch('phase') == 'copied').to be(true)
    check_preservation!
    guest!('touch /var/lib/storage-profile-fixture/block-new-seed')
    stop!
    recover_dns_selection!

    @summary['stage'] = 5
    boot_copied!
    wait!('test -e /var/lib/storage-profile-fixture/new-seed-entered')
    interrupted_identity = identity
    expect(interrupted_identity.fetch(:boot_id) != second_identity.fetch(:boot_id)).to be(true)
    expect(guest!('readlink -f /run/current-system').strip == new_toplevel).to be(true)
    guest!('rm /var/lib/storage-profile-fixture/new-seed-entered && sync -f /var/lib/storage-profile-fixture')
    # Interrupt only the new preserving seed; old unmasked fallback is forbidden.
    stop!(force: true)
    expect(disk_identity == @disk_identity).to be(true)
    @policy = new_policy
    expect(@policy.status.fetch('phase') == 'starting_copied').to be(true)

    @summary['stage'] = 6
    boot_copied!
    wait!('test -e /var/lib/storage-profile-fixture/new-seed-entered')
    expect(identity.fetch(:boot_id) != interrupted_identity.fetch(:boot_id)).to be(true)
    guest!('rm /var/lib/storage-profile-fixture/block-new-seed')
    wait!('for unit in vpsadmin-api.service vpsadmin-supervisor.service; ' \
          'do systemctl is-active --quiet "$unit" || exit 1; done')
    expect(guest!('systemctl show vpsadmin-devcluster-seed.service -p Result --value').strip == 'success').to be(true)
    expect(guest!('readlink -f /run/current-system').strip == new_toplevel).to be(true)
    check_preservation!
    expect(counters.fetch('new-seed', 0) >= 2).to be(true)
    expect(dns_execute!('readlink -e /run/current-system').strip).to eq(@old_dns_toplevel)
    expect(dns_execute!('cat /etc/retained-dns-generation').strip).to eq('old')
    expect(dns_execute!('sha256sum /var/lib/retained-dns-payload').split.first).to eq(@dns_payload)
    expect(File.stat(File.join(@state, 'dns-primary-root.img')).then { |stat| [stat.dev, stat.ino, stat.size] }).to eq(@dns_disk_identity)
    expect(@policy.status.fetch('phase') == 'starting_copied').to be(true)
    save_private('after.json', projections)
    stop!
    @summary.merge!('scenario_completed' => 1, 'phase_starting_copied' => 1,
                    'projection_sha256' => Digest::SHA256.hexdigest(JSON.generate(@projection)),
                    'resident_config' => @resident_path, 'historical_config' => @historical_path,
                    'candidate_config' => @candidate_path,
                    'resident_toplevel' => old_toplevel, 'candidate_toplevel' => new_toplevel)
  end

  private

  def new_policy
    DevClusters::VpsAdminMaintenance.new(workspace: @directory, slug: 'retained-services-fixture', directory: @directory)
  end

  def store_json!(path)
    check = path.start_with?('/nix/store/') && File.file?(path) && File.size(path) <= 2 * 1024 * 1024
    raise Invalid, 'fixture configuration is not bounded store JSON' unless check

    path
  end

  def expect_refusal!(&block)
    expect(&block).to raise_error(DevClusters::VpsAdminMaintenance::Invalid)
  end

  # The script evaluator is cloned. Resolve the shared mutable registry each time
  # so kernel checks and inherited cleanup see every replacement guest.
  def services
    machines.fetch('services')
  end

  def quote(value)
    Shellwords.escape(value)
  end

  def old_toplevel
    @resident.fetch('machines').fetch('services').fetch('toplevel')
  end

  def new_toplevel
    @candidate.fetch('machines').fetch('services').fetch('toplevel')
  end

  def refuse_existing_listener!
    [PORT, 19_123].each do |port|
      begin
        Socket.tcp('127.0.0.1', port, connect_timeout: 1) { |_| raise Invalid, 'fixture port is occupied' }
      rescue Errno::ECONNREFUSED
        next
      end
    end
  end

  def boot!(config, masked: false, config_path: @resident_path)
    raise Invalid, 'fixture already has a guest' unless machines.empty?

    @policy.root_source_config!(config_path:)
    @policy.root_host_payloads!(config_path:, machines: masked ? ['services'] : nil)
    selected = config.fetch('machines')
    selected = selected.slice('services') if masked
    if @services_stopped_at
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @services_stopped_at
      delay = [5 - elapsed, 0].max
      sleep(delay) if delay.positive?
    end
    selected.each do |name, machine_config|
      @policy.validate_machine_disks!(name:, machine: machine_config) if @disk_identity
      machine = OsVm::NixosMachine.new(name, OsVm::MachineConfig.from_config(machine_config),
                                     @state, @sockets, default_timeout: @default_timeout, hash_base: @test.path)
      machines[name] = machine
      @policy.validate_machine_disks!(name:, machine: machine_config) if @disk_identity
      machine.start(kernel_params: masked ? DevClusters::VpsAdminMaintenance.kernel_parameters : [], wait_for_boot: true)
    end
    wait!('systemctl is-active --quiet mysql.service')
    wait!('systemctl is-active --quiet sshd.service nix-daemon.socket')
    host!('ssh', *@ssh_options, 'root@127.0.0.1', 'true')
  end

  def dns_execute!(command)
    code, output = machines.fetch('dns-primary').execute(command, timeout: 120)
    raise Invalid, 'fixture DNS read failed' unless code.zero?

    output
  end

  def select_legacy_candidate_dns!
    # Reproduce the old full build-result selection after the real old boot.
    # This combined configuration has never booted; only services is resident.
    selected = @historical.merge('machines' => @historical.fetch('machines').merge(
      'dns-primary' => @candidate.fetch('machines').fetch('dns-primary')))
    expect(selected.reject { |key, _| key == 'machines' }).to eq(@historical.reject { |key, _| key == 'machines' })
    expect(selected.fetch('machines').fetch('services')).to eq(@historical.fetch('machines').fetch('services'))
    @policy.send(:compatible_configuration!, @historical, selected)
    save_private('legacy-selected.json', selected)
    @resident_path = store_json!(host!('nix-store', '--add', File.join(@directory, 'legacy-selected.json')).strip)
    @policy.root_source_config!(config_path: @resident_path)
    host!('nix-store', '--option', 'substitute', 'false', '--add-root', File.join(@directory, 'legacy-selected-root'), '--indirect', '--realise', @resident_path)
    @resident = JSON.parse(File.binread(@resident_path))
  end

  def recover_dns_selection!
    expect(machines).to be_empty
    record_path = File.join(@directory, 'maintenance-hold.json')
    before = JSON.parse(File.binread(record_path))
    original = JSON.parse(File.binread(@next_path))
    expect(original.fetch('machines').fetch('dns-primary')).to eq(@candidate.fetch('machines').fetch('dns-primary'))
    expect(original.fetch('machines').fetch('services')).to eq(@candidate.fetch('machines').fetch('services'))
    proofs = original.fetch('machines').to_h do |name, machine|
      source = name == 'services' ? @candidate_path : @historical_path
      kind = name == 'services' ? 'held_copy' : 'prior_boot'
      [name, { 'source_config' => source, 'source_config_sha256' => Digest::SHA256.file(source).hexdigest,
               'proof_kind' => kind, 'proof_reference' => 'fixture real old full boot and completed services copy; no disk replacement',
               'disks' => @policy.send(:disk_identities, name:, machine:) }]
    end
    recovery = File.join(@directory, 'recovery-evidence.json')
    save_private('recovery-evidence.json', { 'version' => 1, 'kind' => 'retained_boot_recovery',
      'workspace' => @directory, 'slug' => 'retained-services-fixture',
      'expected_hold_sha256' => Digest::SHA256.file(record_path).hexdigest, 'machines' => proofs })
    prepared = @policy.prepare_recovery!(evidence_path: recovery, output_path: File.join(@directory, 'recovered-next.json'))
    prepared.fetch('sources').each do |source|
      @policy.root_source_config!(config_path: source)
    end
    @next_path = store_json!(host!('nix-store', '--add', prepared.fetch('next_config')).strip)
    @policy.root_source_config!(config_path: @next_path)
    host!('nix-store', '--option', 'substitute', 'false', '--add-root', File.join(@directory, 'recovered-next-root'), '--indirect', '--realise', @next_path)
    @policy.root_host_payloads!(config_path: @next_path)
    @policy.commit_recovery!(evidence_path: recovery, next_path: @next_path)
    corrected = JSON.parse(File.binread(@next_path))
    expect(corrected.fetch('machines').fetch('dns-primary')).to eq(@historical.fetch('machines').fetch('dns-primary'))
    expect(corrected.fetch('machines').fetch('services')).to eq(original.fetch('machines').fetch('services'))
    after = JSON.parse(File.binread(record_path))
    unchanged = DevClusters::VpsAdminMaintenance::RECORD_KEYS - %w[version next_config next_config_sha256]
    expect(after.slice(*unchanged)).to eq(before.slice(*unchanged))
    expect(@policy.status.fetch('phase')).to eq('copied')
    expect(@policy.pending?).to be(true)
  end

  def masked_boot!
    @policy.root_source_config!(config_path: @resident_path)
    @policy.root_host_payloads!(config_path: @resident_path, machines: ['services'])
    @policy.validate_runner!(config_path: @resident_path)
    boot!(@resident, masked: true)
  end

  def boot_copied!
    selected_path = store_json!(@policy.copied_config!)
    expect(selected_path).to eq(@next_path)
    @policy.validate_copied_runner!(config_path: selected_path)
    selected = JSON.parse(File.binread(selected_path))
    expect(selected.fetch('machines').keys.sort).to eq(%w[dns-primary services])
    boot!(selected, config_path: selected_path)
  end

  def stop!(force: false)
    return if machines.empty?

    machines.keys.each do |name|
      machine = machines.fetch(name)
      if force
        machine.kill(signal: 'KILL')
      else
        begin
          machine.stop(timeout: 45)
        rescue OsVm::UnrecoverableTimeoutError
          machine.kill(signal: 'KILL')
        end
      end
      machine.raise_if_kernel_failed!
      machine.finalize
      machine.cleanup
      machines.delete(name)
    end
    @services_stopped_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def guest!(command)
    code, output = services.execute(command, timeout: 120)
    raise Invalid, 'fixture guest command failed' unless code.zero?

    output
  end

  def wait!(command)
    services.wait_until_succeeds(command, timeout: 300)
  end

  def host!(*argv)
    stdout = nil
    status = nil
    File.open(File.join(@directory, 'host.log'), 'a', 0o600) do |log|
      Open3.popen3(*argv, pgroup: true) do |input, output, error, child|
        input.close
        reader = Thread.new { IO.copy_stream(error, log) }
        begin
          Timeout.timeout(600) do
            stdout = output.read
            status = child.value
            reader.join
          end
        ensure
          begin
            Process.kill('KILL', -child.pid)
          rescue Errno::ESRCH
            nil
          end
          child.join
          reader.join
        end
      end
    end
    raise Invalid, 'fixture host command failed' unless status.success?

    stdout
  end

  def save_private(name, value)
    File.open(File.join(@directory, name), 'w', 0o600) { |file| file.write(JSON.pretty_generate(value)) }
  end

  def sql!(sql)
    guest!("mariadb --database=vpsadmin --batch --skip-column-names --execute #{quote(sql)}")
  end

  def mutate_retained_fixture!
    sql!(<<~SQL)
      SET @u=(SELECT id FROM users WHERE login='test-user1');
      SET @ns=(SELECT id FROM user_namespaces WHERE user_id=@u);
      SET @env=(SELECT environment_id FROM cluster_resource_packages WHERE user_id=@u LIMIT 1);
      SET @cpu=(SELECT id FROM cluster_resources WHERE name='cpu');
      SELECT COUNT(*) FROM user_namespace_blocks WHERE `index` BETWEEN 25 AND 32 AND user_namespace_id IS NULL;
    SQL
    free = sql!('SELECT COUNT(*) FROM user_namespace_blocks WHERE `index` BETWEEN 25 AND 32 AND user_namespace_id IS NULL').to_i
    expect(free == 8).to be(true)
    sql!(<<~SQL)
      START TRANSACTION;
      SET @u=(SELECT id FROM users WHERE login='test-user1');
      SET @ns=(SELECT id FROM user_namespaces WHERE user_id=@u);
      SET @cpu=(SELECT id FROM cluster_resources WHERE name='cpu');
      UPDATE user_namespace_blocks SET user_namespace_id=NULL WHERE user_namespace_id=@ns;
      UPDATE user_namespace_blocks SET user_namespace_id=@ns WHERE `index` BETWEEN 25 AND 32;
      UPDATE user_namespaces SET `offset`=(SELECT MIN(`offset`) FROM user_namespace_blocks WHERE user_namespace_id=@ns),
        size=(SELECT SUM(size) FROM user_namespace_blocks WHERE user_namespace_id=@ns), block_count=8 WHERE id=@ns;
      UPDATE user_namespace_map_entries SET vps_id=3, ns_id=5, count=100
        WHERE user_namespace_map_id IN (SELECT id FROM user_namespace_maps WHERE user_namespace_id=@ns);
      UPDATE cluster_resource_package_items SET value=27 WHERE cluster_resource_id=@cpu
        AND cluster_resource_package_id IN (SELECT id FROM cluster_resource_packages WHERE user_id=@u);
      UPDATE user_cluster_resources AS resources SET value=(
        SELECT SUM(items.value) FROM user_cluster_resource_packages AS assignments
        JOIN cluster_resource_package_items AS items
          ON items.cluster_resource_package_id=assignments.cluster_resource_package_id
        WHERE assignments.user_id=@u AND assignments.environment_id=resources.environment_id
          AND items.cluster_resource_id=@cpu
      ) WHERE resources.user_id=@u AND resources.cluster_resource_id=@cpu;
      COMMIT;
    SQL
    expect(sql!("SELECT block_count FROM user_namespaces WHERE user_id=(SELECT id FROM users WHERE login='test-user1')").strip == '8').to be(true)
  end

  def projections
    selections = {
      'namespaces' => 'SELECT * FROM user_namespaces ORDER BY id',
      'blocks' => 'SELECT * FROM user_namespace_blocks ORDER BY id',
      'maps' => 'SELECT * FROM user_namespace_maps ORDER BY id',
      'entries' => 'SELECT * FROM user_namespace_map_entries ORDER BY id',
      'personal_packages' => 'SELECT * FROM cluster_resource_packages WHERE user_id IS NOT NULL ORDER BY id',
      'personal_items' => 'SELECT * FROM cluster_resource_package_items WHERE cluster_resource_package_id IN (SELECT id FROM cluster_resource_packages WHERE user_id IS NOT NULL) ORDER BY id',
      'assignments' => 'SELECT * FROM user_cluster_resource_packages ORDER BY id',
      'resources' => 'SELECT * FROM user_cluster_resources ORDER BY id'
    }
    selections.transform_values { |sql| sql!(sql) }
  end

  def counters
    output = guest!('for f in /var/lib/storage-profile-fixture/counters/*; do test -f "$f" || continue; printf "%s " "${f##*/}"; wc -l < "$f"; done')
    output.lines.to_h do |line|
      name, count = line.split
      [name, Integer(count, 10)]
    end
  end

  def check_preservation!
    actual_projection = projections
    actual_payload = guest!('sha256sum /var/lib/storage-profile-fixture/payload').split.first
    actual_counters = counters
    actual_disk = disk_identity if @disk_identity
    expected_old = @old_counters.select { |name, _| name.start_with?('old-') }
    actual_old = actual_counters.select { |name, _| name.start_with?('old-') }
    @preservation_check = (@preservation_check || 0) + 1
    if @preservation_check <= 16
      save_private(format('preservation-check-%02d.json', @preservation_check), {
                     'stage' => @summary.fetch('stage'), 'check' => @preservation_check,
                     'equal' => {
                       'projections' => actual_projection == @projection, 'payload' => actual_payload == @payload,
                       'old_counters' => actual_old == expected_old, 'services_disk' => actual_disk == @disk_identity
                     },
                     'projection_sha256' => {
                       'expected' => @projection.transform_values { |value| Digest::SHA256.hexdigest(value) },
                       'actual' => actual_projection.transform_values { |value| Digest::SHA256.hexdigest(value) }
                     },
                     'projection_equal' => @projection.to_h do |name, value|
                       [name, actual_projection.fetch(name) == value]
                     end,
                     'payload_sha256' => { 'expected' => @payload, 'actual' => actual_payload },
                     'counters' => {
                       'expected' => counter_diagnostics(@old_counters), 'actual' => counter_diagnostics(actual_counters)
                     },
                     'services_disk' => { 'expected' => @disk_identity, 'actual' => actual_disk }
                   })
    end
    # Keep exact SQL and unexpected counter-key comparisons out of assertion output.
    context = "stage #{@summary.fetch('stage')} check #{@preservation_check} (see preservation-check JSON)"
    expect(actual_projection == @projection).to eq(true), "preservation projections differ at #{context}"
    expect(actual_payload).to eq(@payload), "preservation payload SHA256 differs at #{context}"
    if (actual_old.keys | expected_old.keys).all? { |name| COUNTER_NAMES.include?(name) }
      expect(actual_old).to eq(expected_old), "preservation old counters differ at #{context}"
    else
      expect(actual_old == expected_old).to eq(true), "preservation old counters differ at #{context}"
    end
    expect(actual_disk).to eq(@disk_identity), "preservation services disk identity differs at #{context}" if @disk_identity
  end

  def counter_diagnostics(values)
    unexpected = values.reject { |name, _| COUNTER_NAMES.include?(name) }
    {
      'known' => COUNTER_NAMES.to_h { |name| [name, values[name]] },
      'unexpected_count' => unexpected.size,
      'unexpected_sha256' => Digest::SHA256.hexdigest(JSON.generate(unexpected.sort.to_h))
    }
  end

  def disk_identity
    disk = @resident.fetch('machines').fetch('services').fetch('rootDisk')
    path = File.expand_path(disk.fetch('device').gsub('{machine}', 'services'), @state)
    stat = File.stat(path)
    [stat.dev, stat.ino, stat.size]
  end

  def check_missing_disk_refusal!
    disk = @resident.fetch('machines').fetch('services').fetch('rootDisk')
    path = File.expand_path(disk.fetch('device').gsub('{machine}', 'services'), @state)
    hidden = "#{path}.fixture-missing"
    File.rename(path, hidden)
    expect_refusal! { @policy.validate_machine_disks!(name: 'services', machine: @resident.fetch('machines').fetch('services')) }
  ensure
    File.rename(hidden, path) if hidden && File.exist?(hidden)
  end

  def identity
    { pid: Process.pid, start: File.read('/proc/self/stat').sub(/\A.*\) /, '').split.fetch(19),
      boot_id: guest!('cat /proc/sys/kernel/random/boot_id').strip }
  end

  def check_masks!
    parameters = guest!('cat /proc/cmdline').split
    DevClusters::VpsAdminMaintenance.kernel_parameters.each do |parameter|
      expect(parameters.count(parameter)).to eq(1)
    end
    DevClusters::VpsAdminMaintenance::MASKS.each do |unit|
      links = guest!('for dir in /run/systemd/generator.early /run/systemd/generator /run/systemd/generator.late; ' \
                     "do readlink \"$dir/#{unit}\" 2>/dev/null || true; done").lines.map(&:strip)
      expect(links).to include('/dev/null')
      expect(guest!("systemctl show #{unit} --property=LoadState --value").strip).to eq('masked')
      expect(guest!("systemctl show #{unit} --property=ActiveState --value").strip).to eq('inactive')
    end
    active = guest!('systemctl list-units --no-legend --plain --no-pager --state=active,activating --type=service,timer')
    expect(active.lines.grep(/\Avpsadmin-api-.*\.(?:service|timer)\s/)).to be_empty
  end

  def interrupted_copy!(path)
    marker = File.join(@directory, 'copy-finished')
    File.unlink(marker) if File.exist?(marker)
    pid = fork do
      ENV['NIX_SSHOPTS'] = @ssh_options.shelljoin
      host!('nix', 'copy', '--to', 'ssh://root@127.0.0.1', path)
      File.write(marker, '1', mode: 'w', perm: 0o600)
      Process.kill('STOP', Process.pid)
    end
    Timeout.timeout(600) do
      until File.exist?(marker)
        raise Invalid, 'fixture copy worker exited early' if Process.waitpid(pid, Process::WNOHANG)

        sleep 0.1
      end
    end
    Process.kill('KILL', pid)
    Process.wait(pid)
  ensure
    if pid
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def verify_copied!(path)
    guest!("set -euo pipefail; test -x #{quote(path)}/init; " \
           "nix-store --query --requisites #{quote(path)} | xargs -r nix-store --check-validity; " \
           "nix-store --add-root /nix/var/nix/gcroots/storage-profile-fixture --indirect --realise #{quote(path)} >/dev/null")
  end
end

options = {}
OptionParser.new do |parser|
  parser.on('--resident-config PATH') { |value| options[:resident_config] = value }
  parser.on('--candidate-config PATH') { |value| options[:candidate_config] = value }
  parser.on('--artifact-dir PATH') { |value| options[:artifact_dir] = value }
end.parse!
raise ArgumentError, 'fixture requires exactly its three declared arguments' unless
  ARGV.empty? && options.keys.sort == %i[artifact_dir candidate_config resident_config]

directory = File.realpath(options.fetch(:artifact_dir))
raise ArgumentError, 'artifact directory must be private and empty' unless
  File.stat(directory).mode & 0o777 == 0o700 && Dir.empty?(directory)

File.umask(0o077)
# Initialize the empty fixture before creating its owned log.
fixture = RetainedServicesMaintenanceFixture.new(options)
$stderr.reopen(File.join(directory, 'test-runner.log'), 'w')
summary = fixture.summary
begin
  events = []
  results = fixture.run { |event| events << event if event.is_a?(Hash) && event.fetch('type') == 'example' }
  result = results.fetch('default')
  summary['examples'] = events.size
  complete = events.one? && events.first.values_at('success', 'pending', 'skip') == [true, false, false]
  summary['passed'] = 1 if complete && results.keys == ['default'] && result.successful? && result.expected_result? &&
                           summary['scenario_completed'] == 1 && fixture.machines.empty?
rescue StandardError => error
  File.write(File.join(directory, 'failure.json'), JSON.pretty_generate('class' => error.class.name, 'message' => error.message),
             mode: 'w', perm: 0o600)
ensure
  File.write(File.join(directory, 'summary.json'), JSON.pretty_generate(summary), mode: 'w', perm: 0o600)
  puts JSON.generate(summary.select { |_, value| value.is_a?(Integer) })
end
exit(summary.fetch('passed') == 1 ? 0 : 1)
