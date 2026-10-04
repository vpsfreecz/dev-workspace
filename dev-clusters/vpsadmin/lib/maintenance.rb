# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tempfile'

module DevClusters
  # Private operation state is always accessed under the provider lifecycle lock.
  # Operator residency evidence is a bounded reference, not guest authentication.
  class VpsAdminMaintenance
    Invalid = Class.new(StandardError)
    VERSION = 2
    LEGACY_VERSION = 1
    MASK_POLICY = 1
    SEED_VERSION = 1
    EVIDENCE_VERSION = 1
    APPLIED_VERSION = 1
    MAX_CONFIG_BYTES = 2 * 1024 * 1024
    MAX_RECORD_BYTES = 16 * 1024
    MAX_EVIDENCE_BYTES = 8 * 1024
    MAX_KERNEL_COMMAND_LINE_BYTES = 2047
    MAX_PAYLOAD_ITEMS = 512
    MASKS = %w[
      vpsadmin-database-setup.service vpsadmin-devcluster-seed.service vpsadmin-rabbitmq-setup.service
      vpsadmin-devcluster-webui-seed.service vpsadmin-devcluster-webui-credentials.service
      vpsadmin-notification-templates.service credentials.service api-wait-online.service
      vpsadmin-api.service vpsadmin-supervisor.service vpsadmin-scheduler.service
      vpsadmin-password-recovery.service vpsadmin-console-router.service
      vpsadmin-api-wait-online.service container@webui.service container@newadmin.service
      container@mailer.service nginx.service haproxy.service adminer.service
      phpfpm-vpsfree.service timers.target
    ].freeze
    EVIDENCE_KEYS = %w[
      version workspace slug resident_config resident_config_sha256 services_toplevel
      evidence_kind evidence_reference
    ].freeze
    RECORD_KEYS = %w[
      version mode phase workspace slug resident_config resident_config_sha256
      services_toplevel evidence evidence_sha256 mask_policy runner_pid runner_start
      boot_id candidate candidate_sha256 next_config next_config_sha256 copied_toplevel
      preserving_seed
    ].freeze
    PHASES = %w[held maintenance_ready copying copied starting_copied released].freeze
    RAKE_TASKS = %w[
      migrate-db migrate-plugins auth-tokens user-sessions report-failed-logins
      migration-plans mail-process monitoring-check monitoring-close monitoring-prune
      incident-reports oom-reports-run oom-reports-prune purge-clones vps-status-logs-prune
      dataset-property-logs-prune dns-transfer-logs-prune daily-report
      mail-user-expiration-regular mail-user-expiration-forced mail-vps-expiration-regular
      mail-vps-expiration-forced users-suspend users-soft-delete users-hard-delete
      vpses-expire others-expire prometheus-export-base prometheus-export-dns-records
      prometheus-export-deploy dataset-expansion-run payments-process payments-report
      requests-ipqs outage-reports-auto-resolve
    ].freeze

    class UniqueHash < Hash
      def []=(key, value)
        raise Invalid, 'duplicate JSON key' if key?(key)

        super
      end
    end

    def initialize(workspace:, slug:, directory:, store_root: '/nix/store')
      @workspace = File.realpath(workspace)
      @slug = slug
      @directory = directory
      @store_root = store_root
      @record_path = File.join(directory, 'maintenance-hold.json')
      @applied_path = File.join(directory, 'applied-config.json')
    end

    def self.kernel_parameters
      MASKS.map { |unit| "systemd.mask=#{unit}" }
    end

    def pending?
      record = load_record
      record && record.fetch('phase') != 'released'
    end

    def status
      record = load_record
      return nil unless record

      # Deliberately omit evidence references, config paths and private inputs.
      {
        'version' => record.fetch('version'), 'mode' => record.fetch('mode'), 'phase' => record.fetch('phase'),
        'pending' => record.fetch('phase') != 'released',
        'copied' => !record.fetch('copied_toplevel').nil?,
        'active' => record.fetch('phase') == 'released'
      }
    end

    def prepare!(config_path:, services_toplevel:, evidence_path:)
      config, digest = config_file(config_path)
      store_path!(services_toplevel)
      unless config.fetch('machines').fetch('services').fetch('toplevel') == services_toplevel
        raise Invalid, 'resident services selection differs'
      end
      validate_disks!(config)
      validate_boot!(config.fetch('machines').fetch('services'))
      evidence, evidence_digest = evidence_file(evidence_path)
      unless evidence.fetch('resident_config') == config_path &&
             evidence.fetch('resident_config_sha256') == digest &&
             evidence.fetch('services_toplevel') == services_toplevel
        raise Invalid, 'residency evidence differs from resident selection'
      end

      previous = load_record
      if previous && previous.fetch('phase') != 'released'
        raise Invalid, 'recovered selection requires copied boot' if previous['recovery']
        unless previous.fetch('resident_config') == config_path &&
               previous.fetch('resident_config_sha256') == digest &&
               previous.fetch('services_toplevel') == services_toplevel &&
               previous.fetch('evidence_sha256') == evidence_digest &&
               previous.fetch('evidence') == evidence
          raise Invalid, 'maintenance retry changes resident evidence'
        end
        return previous
      end

      write_record({
        'version' => VERSION, 'mode' => 'maintenance', 'phase' => 'held',
        'workspace' => @workspace, 'slug' => @slug,
        'resident_config' => config_path, 'resident_config_sha256' => digest,
        'services_toplevel' => services_toplevel, 'evidence' => evidence,
        'evidence_sha256' => evidence_digest, 'mask_policy' => MASK_POLICY,
        'runner_pid' => nil, 'runner_start' => nil, 'boot_id' => nil,
        'candidate' => nil, 'candidate_sha256' => nil, 'next_config' => nil,
        'next_config_sha256' => nil, 'copied_toplevel' => nil, 'preserving_seed' => nil
      })
    end

    def bind_boot!(pid:, start:, boot_id:)
      record = required_record
      raise Invalid, 'recovered selection requires copied boot' if record['recovery']
      raise Invalid, 'unexpected maintenance boot phase' unless %w[held maintenance_ready copying copied].include?(record.fetch('phase'))
      validate_identity!(pid, start, boot_id)
      record.merge!('phase' => 'maintenance_ready', 'runner_pid' => pid,
                    'runner_start' => start, 'boot_id' => boot_id,
                    'candidate' => nil, 'candidate_sha256' => nil, 'next_config' => nil,
                    'next_config_sha256' => nil, 'copied_toplevel' => nil, 'preserving_seed' => nil)
      write_record(record)
    end

    def begin_copy!(candidate_path:, pid:, start:, boot_id:)
      record = required_record
      raise Invalid, 'recovered selection requires copied boot' if record['recovery']
      assert_boot!(record, pid, start, boot_id)
      raise Invalid, 'copy requires proved maintenance readiness' unless %w[maintenance_ready copying copied].include?(record.fetch('phase'))
      resident, = config_file(record.fetch('resident_config'), expected_digest: record.fetch('resident_config_sha256'))
      candidate, digest = config_file(candidate_path)
      marker = preserving_seed!(candidate)
      compatible_services!(resident, candidate)
      record.merge!('phase' => 'copying', 'candidate' => candidate_path,
                    'candidate_sha256' => digest, 'next_config' => nil,
                    'next_config_sha256' => nil, 'copied_toplevel' => nil, 'preserving_seed' => marker)
      write_record(record)
    end

    def build_next!(next_path:)
      record = required_record
      raise Invalid, 'copy has no pending candidate' unless record.fetch('phase') == 'copying'
      write_private_json(next_path, next_configuration(record), max_bytes: MAX_CONFIG_BYTES)
    end

    def finish_copy!(next_path:, pid:, start:, boot_id:)
      record = required_record
      assert_boot!(record, pid, start, boot_id)
      raise Invalid, 'copy has no pending candidate' unless record.fetch('phase') == 'copying'
      candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
      next_config, next_digest = config_file(next_path)
      raise Invalid, 'rooted next configuration differs' unless next_config == next_configuration(record)
      record.merge!('phase' => 'copied', 'next_config' => next_path,
                    'next_config_sha256' => next_digest,
                    'copied_toplevel' => candidate.fetch('machines').fetch('services').fetch('toplevel'))
      write_record(record)
    end

    def copied_config!
      record = required_record
      unless %w[copied starting_copied].include?(record.fetch('phase')) && record.fetch('copied_toplevel')
        raise Invalid, 'maintenance copy is incomplete'
      end
      candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
      next_config, = config_file(record.fetch('next_config'), expected_digest: record.fetch('next_config_sha256'))
      unless preserving_seed!(candidate) == record.fetch('preserving_seed') &&
             preserving_seed!(next_config) == record.fetch('preserving_seed') &&
             next_config.fetch('machines').fetch('services').fetch('toplevel') == record.fetch('copied_toplevel') &&
             next_config == next_configuration(record)
        raise Invalid, 'copied preservation selection differs'
      end
      validate_disks!(next_config)
      record['phase'] = 'starting_copied'
      write_record(record)
      record.fetch('next_config')
    end

    def release!(pid:, start:, boot_id:)
      record = required_record
      raise Invalid, 'release requires copied boot' unless record.fetch('phase') == 'starting_copied'
      applied = applied_record
      config, = config_file(record.fetch('next_config'), expected_digest: record.fetch('next_config_sha256'))
      unless applied && complete_applied?(applied) && applied.fetch('configuration') == config
        raise Invalid, 'release requires completed full applied proof'
      end
      validate_identity!(pid, start, boot_id)
      record.merge!('phase' => 'released', 'runner_pid' => pid, 'runner_start' => start, 'boot_id' => boot_id)
      write_record(record)
    end

    def resident_config!
      record = required_record
      config_file(record.fetch('resident_config'), expected_digest: record.fetch('resident_config_sha256'))
      record.fetch('resident_config')
    end

    def validate_runner!(config_path:)
      record = required_record
      raise Invalid, 'recovered selection requires copied boot' if record['recovery']
      raise Invalid, 'maintenance runner requires a pending hold' if record.fetch('phase') == 'released'
      raise Invalid, 'maintenance runner changes resident config' unless resident_config! == config_path
      config, = config_file(config_path, expected_digest: record.fetch('resident_config_sha256'))
      validate_disks!(config)
      services = config.fetch('machines').fetch('services')
      validate_boot!(services)
      validate_system!(services.fetch('toplevel'))
      self.class.kernel_parameters
    end

    def validate_copied_runner!(config_path:)
      record = required_record
      unless record.fetch('phase') == 'starting_copied' && record.fetch('next_config') == config_path
        raise Invalid, 'copied runner requires the recorded next configuration'
      end
      validate_adoption!
      config, = config_file(config_path, expected_digest: record.fetch('next_config_sha256'))
      validate_disks!(config)
      @boot_disk_identities = nil
      if record['recovery']
        evidence, = private_json(record.fetch('recovery').fetch('evidence_path'), max_bytes: MAX_RECORD_BYTES)
        @boot_disk_identities = evidence.fetch('machines').transform_values { |proof| proof.fetch('disks') }
      end
    end

    def validate_system!(toplevel)
      store_path!(toplevel)
      controller = File.realpath(File.join(toplevel, 'sw/bin/systemctl'))
      generator = File.join(File.dirname(File.dirname(controller)), 'lib/systemd/system-generators/systemd-debug-generator')
      raise Invalid, 'resident debug generator is unavailable' unless File.executable?(generator)
      override = File.join(toplevel, 'etc/systemd/system-generators/systemd-debug-generator')
      if (File.exist?(override) || File.symlink?(override)) && File.realpath(override) != File.realpath(generator)
        raise Invalid, 'resident debug generator is overridden'
      end
      units = File.join(toplevel, 'etc/systemd/system')
      raise Invalid, 'resident unit inventory is unavailable' unless File.directory?(units)
      entries = Dir.children(units)
      raise Invalid, 'resident unit inventory exceeds bound' if entries.length > 4096
      visited = entries.length
      known_rake = RAKE_TASKS.map { |name| "vpsadmin-api-#{name}" }
      entries.each do |name|
        if name.end_with?('.service', '.timer')
          names = [name, File.basename(File.realpath(File.join(units, name)))].uniq
          if names.any? { |unit| unit.start_with?('vpsadmin') && !MASKS.include?(unit) && !known_rake.include?(unit.sub(/\.(service|timer)\z/, '')) }
            raise Invalid, 'resident has an unsupported application writer'
          end
        end
        if name.end_with?('.wants', '.requires') && File.directory?(File.join(units, name))
          links = Dir.children(File.join(units, name))
          visited += links.length
          raise Invalid, 'resident unit links exceed bound' if visited > 4096
          links.each do |link|
            target = File.basename(File.realpath(File.join(units, name, link)))
            task = [link, target].find { |unit| known_rake.include?(unit.sub(/\.(service|timer)\z/, '')) }
            next unless task
            next if task.end_with?('.timer') && name == 'timers.target.wants'
            next if task == 'vpsadmin-api-prometheus-export-deploy.service' &&
                    %w[vpsadmin-api-prometheus-export-base.service.requires vpsadmin-api-prometheus-export-dns-records.service.requires].include?(name)
            raise Invalid, 'resident Rake task has an unsupported automatic caller'
          end
        end
        next unless name.end_with?('.socket', '.path')
        text = bounded_bytes(File.join(units, name), 64 * 1024)
        if text.match?(/vpsadmin|container@(?:webui|newadmin|mailer)/)
          raise Invalid, 'resident application has an unsupported activation trigger'
        end
      end
      activation = bounded_bytes(File.join(toplevel, 'activate'), 512 * 1024)
      if activation.match?(/bundle\s+exec\s+rake|rake\s+db:|^\s*(?:exec\s+)?(?:\S*\/)?ruby\s[^\n]*vpsadmin|^\s*(?:exec\s+)?(?:\S*\/)?vpsadmin-(?:api|supervisor|scheduler)(?:\s|$)/)
        raise Invalid, 'resident activation invokes an application writer'
      end
    rescue Errno::ENOENT
      raise Invalid, 'resident generator or activation evidence is missing'
    end

    def selected_toplevel!
      record = required_record
      case record.fetch('phase')
      when 'copying', 'copied', 'starting_copied'
        candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
        candidate.fetch('machines').fetch('services').fetch('toplevel')
      else
        record.fetch('services_toplevel')
      end
    end

    def validate_adoption!
      record = load_record
      return unless record
      resident, = config_file(record.fetch('resident_config'), expected_digest: record.fetch('resident_config_sha256'))
      validate_disks!(resident)
      if %w[copying copied starting_copied released].include?(record.fetch('phase'))
        candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
        raise Invalid, 'adopted preservation selection differs' unless preserving_seed!(candidate) == record.fetch('preserving_seed')
      end
      if %w[copied starting_copied released].include?(record.fetch('phase'))
        next_config, = config_file(record.fetch('next_config'), expected_digest: record.fetch('next_config_sha256'))
        raise Invalid, 'adopted next configuration differs' unless next_config == next_configuration(record)
      end
    end

    def load_record
      return nil unless File.exist?(@record_path) || File.symlink?(@record_path)

      record, = private_json(@record_path, max_bytes: MAX_RECORD_BYTES)
      validate_record!(record)
    end

    def validate_record!(record)
      version = record.fetch('version')
      exact_keys!(record, version == LEGACY_VERSION ? RECORD_KEYS : RECORD_KEYS + %w[predecessor recovery])
      unless version.is_a?(Integer) && [LEGACY_VERSION, VERSION].include?(version) && record.fetch('mode') == 'maintenance' &&
             record.fetch('mask_policy').is_a?(Integer) && record.fetch('mask_policy') == MASK_POLICY && PHASES.include?(record.fetch('phase')) &&
             record.fetch('workspace') == @workspace && record.fetch('slug') == @slug
        raise Invalid, 'unsupported maintenance record'
      end
      evidence!(record.fetch('evidence'))
      %w[resident_config_sha256 evidence_sha256].each { |key| digest!(record.fetch(key)) }
      store_path!(record.fetch('resident_config'))
      store_path!(record.fetch('services_toplevel'))
      unless record.fetch('evidence').fetch('resident_config') == record.fetch('resident_config') &&
             record.fetch('evidence').fetch('resident_config_sha256') == record.fetch('resident_config_sha256') &&
             record.fetch('evidence').fetch('services_toplevel') == record.fetch('services_toplevel')
        raise Invalid, 'maintenance record evidence differs'
      end
      if record.fetch('phase') != 'held'
        validate_identity!(record.fetch('runner_pid'), record.fetch('runner_start'), record.fetch('boot_id'))
      end
      if %w[copying copied starting_copied released].include?(record.fetch('phase'))
        store_path!(record.fetch('candidate'))
        digest!(record.fetch('candidate_sha256'))
        unless record.fetch('preserving_seed').is_a?(Hash) && record.fetch('preserving_seed')['version'].is_a?(Integer) &&
               record.fetch('preserving_seed') == { 'version' => SEED_VERSION, 'existingAssignments' => 'preserve' }
          raise Invalid, 'maintenance record preservation contract differs'
        end
      end
      if %w[copied starting_copied released].include?(record.fetch('phase'))
        store_path!(record.fetch('next_config'))
        store_path!(record.fetch('copied_toplevel'))
        digest!(record.fetch('next_config_sha256'))
      end
      unused = []
      unused += %w[runner_pid runner_start boot_id] if record.fetch('phase') == 'held'
      if %w[held maintenance_ready].include?(record.fetch('phase'))
        unused += %w[candidate candidate_sha256 preserving_seed]
      end
      if %w[held maintenance_ready copying].include?(record.fetch('phase'))
        unused += %w[next_config next_config_sha256 copied_toplevel]
      end
      raise Invalid, 'maintenance record contains an unproved later phase' unless unused.all? { |key| record.fetch(key).nil? }
      validate_recovery_record!(record) if version == VERSION
      record
    end

    def validate_disks!(config)
      machines = config.fetch('machines')
      raise Invalid, 'resident services machine is missing' unless machines.is_a?(Hash) && machines.key?('services')
      raise Invalid, 'too many resident machines' unless machines.length.between?(1, 16)
      devices = []
      machines.each do |name, machine|
        validate_machine_disks!(name:, machine:).each do |path|
          raise Invalid, 'resident disks share a device' if devices.include?(path)
          devices << path
        end
      end
    end

    # Repeated directly before construction/start: OSVM creates missing images.
    def validate_machine_disks!(name:, machine:)
      string!(name, max_bytes: 128)
      raise Invalid, 'invalid resident machine name' unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
      raise Invalid, 'invalid resident machine' unless machine.is_a?(Hash) && machine.fetch('disks', []).is_a?(Array)
      disks = [machine.fetch('rootDisk', nil), *machine.fetch('disks', [])].compact
      raise Invalid, 'resident machine has no retained disk' if disks.empty? || disks.length > 32
      paths = disks.map do |disk|
        unless disk.is_a?(Hash) && disk.fetch('type') == 'file' &&
               disk.fetch('create', true) == true && disk.fetch('preserve', true) == true
          raise Invalid, 'maintenance requires managed preserved file disks'
        end
        device = string!(disk.fetch('device')).gsub('{machine}', name)
        path = File.expand_path(device, File.join(@directory, 'state'))
        unless path.start_with?(File.join(@directory, 'state') + '/') &&
               !File.symlink?(path) && File.file?(path) && File.size(path).positive?
          raise Invalid, 'expected retained disk is missing or differs'
        end
        path
      end
      if @boot_disk_identities
        current = paths.map do |path|
          stat = File.stat(path)
          { 'device' => path.delete_prefix(File.join(@directory, 'state') + '/'),
            'dev' => stat.dev, 'ino' => stat.ino, 'size' => stat.size }
        end
        raise Invalid, 'stopped disk snapshot changed before boot' unless current == @boot_disk_identities.fetch(name)
      end
      paths
    end

    def validate_boot!(machine)
      extra_options = machine.fetch('extraQemuOptions', [])
      unless machine.fetch('spin') == 'nixos' && machine.fetch('bootMode', 'direct') == 'direct' &&
             extra_options.is_a?(Array) && extra_options.empty? && machine['iso'].nil?
        raise Invalid, 'unsupported maintenance boot mode'
      end
      store_path!(machine.fetch('toplevel'))
      store_path!(machine.fetch('qemu'))
      executable = File.join(machine.fetch('qemu'), 'bin/qemu-kvm')
      unless File.directory?(machine.fetch('qemu')) && File.file?(executable) && File.executable?(executable)
        raise Invalid, 'maintenance requires the supported x86_64 runner'
      end
      %w[kernel initrd].each { |key| store_path!(machine.fetch(key)) }
      params = machine.fetch('kernelParams', [])
      unless params.is_a?(Array) && params.all? { |param| param.is_a?(String) && !param.match?(/[\s\x00-\x1f\x7f]/) }
        raise Invalid, 'invalid resident kernel parameters'
      end
      if params.any? { |param| param.match?(/\A(?:init|rdinit|systemd\.|rd\.systemd\.|SYSTEMD_|debug|single|rescue|emergency)/) }
        raise Invalid, 'conflicting maintenance kernel parameters'
      end
      command_line = ['console=ttyS0', "init=#{machine.fetch('toplevel')}/init", *params, *self.class.kernel_parameters].join(' ')
      raise Invalid, 'maintenance kernel command line exceeds supported bound' if command_line.bytesize > MAX_KERNEL_COMMAND_LINE_BYTES
      command_line
    end

    def compatible_services!(resident, candidate)
      old_machine = resident.fetch('machines').fetch('services')
      new_machine = candidate.fetch('machines').fetch('services')
      changed = %w[toplevel kernel initrd]
      layout = lambda do |machine|
        machine.reject { |key, _| changed.include?(key) }.merge(
          'rootDisk' => machine.fetch('rootDisk').reject { |key, _| key == 'image' }
        )
      end
      # make-test generates a new root-image source for each closure. Existing
      # preserved disks are mandatory, so OSVM must never use this source image.
      unless layout.call(old_machine) == layout.call(new_machine)
        raise Invalid, 'candidate changes services disk, network or mount layout'
      end
      %w[toplevel kernel initrd].each { |key| store_path!(new_machine.fetch(key)) }
      validate_disks!(candidate.merge('machines' => { 'services' => new_machine }))
    end

    def preserving_seed!(config)
      labels = config.fetch('labels', {})
      raise Invalid, 'candidate has invalid labels' unless labels.is_a?(Hash)
      raw = labels.fetch('vpsadminPreservingSeed', nil)
      raise Invalid, 'candidate lacks preserving seed contract' unless raw.is_a?(String) && raw.bytesize <= 256
      marker = parse_json(raw)
      unless marker.is_a?(Hash) && marker['version'].is_a?(Integer) &&
             marker == { 'version' => SEED_VERSION, 'existingAssignments' => 'preserve' }
        raise Invalid, 'unsupported preserving seed contract'
      end
      marker
    end

    # A built candidate does not establish residency on any retained disk.
    def begin_update!(candidate_path:, target:)
      candidate, digest = config_file(candidate_path)
      validate_disks!(candidate)
      candidate.fetch('machines').fetch(target)
      applied = applied_record || empty_applied(candidate)
      pending = applied.fetch('pending')
      if pending && (pending.fetch('operation') != 'update' || pending.fetch('targets') != [target])
        raise Invalid, 'another applied operation remains uncertain'
      end
      compatible_configuration!(applied.fetch('configuration'), candidate)
      applied['pending'] = pending_operation('update', [target], candidate_path, digest)
      write_applied(applied)
    end

    def promote_update!(target:, proof_reference:)
      applied = applied_record || raise(Invalid, 'applied update is missing')
      pending = applied.fetch('pending')
      unless pending && pending.fetch('operation') == 'update' && pending.fetch('targets') == [target]
        raise Invalid, 'applied target differs from pending update'
      end
      candidate, = config_file(pending.fetch('candidate'), expected_digest: pending.fetch('candidate_sha256'))
      validate_disks!(candidate)
      compatible_configuration!(applied.fetch('configuration'), candidate)
      applied.fetch('configuration').fetch('machines')[target] = candidate.fetch('machines').fetch(target)
      applied.fetch('configuration')['labels'] = candidate.fetch('labels', {}) if target == 'services'
      applied.fetch('provenance')[target] = provenance(pending.fetch('candidate'), pending.fetch('candidate_sha256'), 'prior_update', proof_reference)
      applied['pending'] = nil
      write_applied(applied)
    end

    def begin_boot!(config_path:, operation:)
      raise Invalid, 'unsupported applied boot operation' unless %w[boot copied_boot].include?(operation)
      config, digest = config_file(config_path)
      applied = applied_record
      if operation == 'boot' && applied
        raise Invalid, 'retained selection remains incomplete or pending' unless complete_applied?(applied)
        raise Invalid, 'retained boot selection differs' unless config == applied.fetch('configuration')
        validate_disks!(config)
      elsif operation == 'boot'
        # No legacy result/ready file is an initialization source for old images.
        managed_disk_paths(config).each do |path|
          raise Invalid, 'legacy retained images require explicit residency recovery' if File.exist?(path) || File.symlink?(path)
        end
      else
        record = required_record
        unless %w[copied starting_copied].include?(record.fetch('phase')) && record.fetch('next_config') == config_path
          raise Invalid, 'copied boot must use the recorded selection'
        end
        validate_disks!(config)
        if applied && applied.fetch('pending') && applied.fetch('pending').fetch('operation') != 'copied_boot'
          raise Invalid, 'another applied operation remains uncertain'
        end
      end
      applied ||= empty_applied(config)
      applied['provenance'].delete_if do |name, proof|
        source, = config_file(proof.fetch('source_config'), expected_digest: proof.fetch('source_config_sha256'))
        source.fetch('machines').fetch(name) != config.fetch('machines').fetch(name)
      end
      applied['configuration'] = config
      applied['pending'] = pending_operation(operation, config.fetch('machines').keys, config_path, digest)
      write_applied(applied)
    end

    def finish_boot!(config_path:, proof_reference:)
      config, digest = config_file(config_path)
      validate_disks!(config)
      applied = applied_record || raise(Invalid, 'applied boot is missing')
      pending = applied.fetch('pending')
      unless pending && %w[boot copied_boot].include?(pending.fetch('operation')) &&
             pending.fetch('candidate') == config_path && pending.fetch('candidate_sha256') == digest &&
             pending.fetch('targets').sort == config.fetch('machines').keys.sort
        raise Invalid, 'full boot proof differs from pending selection'
      end
      applied['configuration'] = config
      applied['provenance'] = config.fetch('machines').keys.to_h do |name|
        [name, provenance(config_path, digest, 'prior_boot', proof_reference)]
      end
      applied['pending'] = nil
      write_applied(applied)
    end

    def retained_config!(output_path:, candidate_path: nil)
      applied = applied_record || raise(Invalid, 'retained selection is unknown; explicit residency recovery required')
      raise Invalid, 'retained selection is incomplete or pending' unless complete_applied?(applied)
      if candidate_path
        candidate, = config_file(candidate_path)
        compatible_configuration!(applied.fetch('configuration'), candidate)
      end
      validate_disks!(applied.fetch('configuration'))
      write_private_json(output_path, applied.fetch('configuration'), max_bytes: MAX_CONFIG_BYTES)
    end

    def retained_selection?
      !applied_record.nil?
    end

    # Raw added JSON has no registered references to paths in its contents.
    # Keep host inputs independently rooted; this establishes no guest proof.
    def root_host_payloads!(config_path:, machines: nil)
      config, = config_file(config_path)
      root_payload_projection!(host_payloads(config, machines:))
    end

    def root_source_config!(config_path:)
      config_file(config_path)
      root_store_item!(payload_store_item!(config_path), namespace: 'source')
      raise Invalid, 'recorded configuration is missing' unless File.file?(config_path)
    end

    def root_applied_payloads!
      applied = applied_record
      return unless applied

      sources = applied.fetch('provenance').values.map { |proof| proof.fetch('source_config') }
      sources << applied.fetch('pending').fetch('candidate') if applied.fetch('pending')
      sources.uniq.each { |path| root_source_config!(config_path: path) }
      root_payload_projection!(host_payloads(applied.fetch('configuration'), machines: applied.fetch('provenance').keys))
    end

    def root_maintenance_sources!
      record = load_record
      return unless record

      sources = %w[resident_config candidate next_config].filter_map { |field| record.fetch(field) }
      sources << record.fetch('recovery').fetch('original_next_config') if record['recovery']
      sources.uniq.each { |path| root_source_config!(config_path: path) }
    end

    def host_payloads(config, machines: nil)
      selected = config.fetch('machines')
      unless selected.is_a?(Hash) && selected.key?('services') && selected.length.between?(1, 16)
        raise Invalid, 'invalid host payload machine set'
      end
      names = machines || selected.keys
      unless names.is_a?(Array) && names.uniq == names && (names - selected.keys).empty?
        raise Invalid, 'invalid host payload selection'
      end
      inputs = {}
      names.each do |name|
        string!(name, max_bytes: 128)
        raise Invalid, 'invalid host payload machine name' unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
        machine = selected.fetch(name)
        raise Invalid, 'invalid host payload machine' unless machine.is_a?(Hash)

        %w[kernel initrd].each { |field| add_payload!(inputs, machine.fetch(field), :file) }
        add_payload!(inputs, machine.fetch('toplevel'), :directory)
        %w[qemu virtiofsd].each do |field|
          path = machine.fetch(field)
          add_payload!(inputs, path, :directory)
          add_payload!(inputs, File.join(path, 'bin', field == 'qemu' ? 'qemu-kvm' : 'virtiofsd'), :executable)
        end
        %w[squashfs iso].each do |field|
          add_payload!(inputs, machine.fetch(field), :file) unless machine[field].nil?
        end
        shares = machine.fetch('sharedFileSystems', {})
        raise Invalid, 'invalid shared host payloads' unless shares.is_a?(Hash)
        shares.each_value { |path| add_payload!(inputs, path, :directory, external: true) }
        networks = machine.fetch('networks', [])
        raise Invalid, 'invalid host payload networks' unless networks.is_a?(Array)
        networks.each do |network|
          raise Invalid, 'invalid host payload network' unless network.is_a?(Hash)
          next unless network['type'] == 'bridge'

          options = network.fetch('opts', {})
          raise Invalid, 'invalid bridge host payload options' unless options.is_a?(Hash)
          helper = options['helper']
          add_payload!(inputs, helper, :executable, external: true) unless helper.nil? || helper == ''
        end
        disks = [machine['rootDisk'], *machine.fetch('disks', [])].compact
        raise Invalid, 'invalid host payload disks' unless disks.length <= 32
        disks.each do |disk|
          raise Invalid, 'invalid host payload disk' unless disk.is_a?(Hash)
          next unless disk.fetch('type') == 'file' && disk.fetch('create', true) == true && disk['image']

          path = File.expand_path(string!(disk.fetch('device')).gsub('{machine}', name), File.join(@directory, 'state'))
          # OSVM skips the image for a present preserved destination.
          next if disk.fetch('preserve', true) == true && File.exist?(path)

          add_payload!(inputs, disk.fetch('image'), :file)
        end
      end
      inputs
    end

    def prepare_recovery!(evidence_path:, output_path:)
      record, hold_digest = private_json(@record_path, max_bytes: MAX_RECORD_BYTES)
      required_record # Full v1/v2 validation, without modifying legacy bytes.
      evidence, evidence_digest = private_json(evidence_path, max_bytes: MAX_RECORD_BYTES)
      if record['recovery']
        recovery = record.fetch('recovery')
        raise Invalid, 'recovery retry changes evidence' unless recovery.fetch('evidence_sha256') == evidence_digest
        recovery_configuration!(record, original_next!(record))
        return { 'already_recorded' => true, 'next_config' => record.fetch('next_config'),
                 'sources' => recovery_sources(record, evidence, recovery.fetch('original_next_config')) }
      end
      raise Invalid, 'recovery requires a completed pending copy' unless %w[copied starting_copied].include?(record.fetch('phase'))
      original, = config_file(record.fetch('next_config'), expected_digest: record.fetch('next_config_sha256'))
      raise Invalid, 'original next selection differs' unless original == next_configuration(record)
      corrected = derive_recovery!(record, hold_digest, evidence, original)
      history = history_directory!
      predecessor_path = File.join(history, "#{hold_digest}-hold.json")
      snapshot_path = File.join(history, "#{evidence_digest}-evidence.json")
      archive_bytes!(predecessor_path, bounded_bytes(@record_path, MAX_RECORD_BYTES))
      archive_bytes!(snapshot_path, bounded_bytes(evidence_path, MAX_RECORD_BYTES))
      write_private_json(output_path, corrected, max_bytes: MAX_CONFIG_BYTES)
      { 'already_recorded' => false, 'next_config' => output_path,
        'sources' => recovery_sources(record, evidence, record.fetch('next_config')) }
    end

    def commit_recovery!(evidence_path:, next_path:)
      prepared = prepare_recovery!(evidence_path:, output_path: File.join(@directory, 'recovery-next.json'))
      return required_record if prepared.fetch('already_recorded')
      record, hold_digest = private_json(@record_path, max_bytes: MAX_RECORD_BYTES)
      required_record
      evidence, evidence_digest = private_json(evidence_path, max_bytes: MAX_RECORD_BYTES)
      original, = config_file(record.fetch('next_config'), expected_digest: record.fetch('next_config_sha256'))
      corrected = derive_recovery!(record, hold_digest, evidence, original)
      actual, next_digest = config_file(next_path)
      raise Invalid, 'rooted recovery selection differs' unless actual == corrected
      history = history_directory!
      upgraded = record.merge('version' => VERSION,
                              'predecessor' => { 'path' => File.join(history, "#{hold_digest}-hold.json"), 'sha256' => hold_digest },
                              'recovery' => { 'evidence_path' => File.join(history, "#{evidence_digest}-evidence.json"),
                                              'evidence_sha256' => evidence_digest,
                                              'original_next_config' => record.fetch('next_config'),
                                              'original_next_config_sha256' => record.fetch('next_config_sha256') },
                              'next_config' => next_path, 'next_config_sha256' => next_digest)
      validate_recovery_record!(upgraded)
      applied = empty_applied(corrected)
      applied['provenance'] = evidence.fetch('machines').transform_values do |proof|
        proof.slice('source_config', 'source_config_sha256', 'proof_kind', 'proof_reference')
      end
      applied['pending'] = pending_operation('copied_boot', corrected.fetch('machines').keys, next_path, next_digest)
      write_applied(applied) # Never boot-eligible as complete before full proof.
      write_record(upgraded) # Authoritative hold publication is last.
    end

    private

    def recovery_sources(record, evidence, original_next)
      [record.fetch('resident_config'), record.fetch('candidate'), original_next,
       *evidence.fetch('machines').values.map { |proof| proof.fetch('source_config') }].uniq
    end

    def payload_store_item!(path)
      store_path!(path)
      relative = path.delete_prefix(@store_root + '/')
      parts = relative.split('/')
      if parts.empty? || parts.any? { |part| part.empty? || %w[. ..].include?(part) } || parts.first.end_with?('.drv')
        raise Invalid, 'invalid host payload store item'
      end
      File.join(@store_root, parts.first)
    end

    def add_payload!(inputs, path, kind, external: false)
      string!(path)
      return if external && !path.start_with?(@store_root + '/') && path != @store_root

      item = payload_store_item!(path)
      inputs[item] ||= []
      requirement = [path, kind]
      inputs[item] << requirement unless inputs[item].include?(requirement)
      raise Invalid, 'too many host payload store items' if inputs.size > MAX_PAYLOAD_ITEMS
    end

    def root_payload_projection!(inputs)
      inputs.each_key { |item| root_store_item!(item, namespace: 'payload') }
      inputs.each_value do |requirements|
        requirements.each do |path, kind|
          valid = case kind
                  when :directory then File.directory?(path)
                  when :file then File.file?(path)
                  when :executable then File.file?(path) && File.executable?(path)
                  end
          raise Invalid, 'required host payload path is missing or differs' unless valid
        end
      end
      inputs.keys
    end

    def root_store_item!(item, namespace:)
      root = File.join(@directory, "maintenance-#{namespace}-#{Digest::SHA256.hexdigest(item)}")
      if File.exist?(root) || File.symlink?(root)
        raise Invalid, 'host store-item root differs' unless File.symlink?(root) && File.readlink(root) == item
      end
      unless File.exist?(item) && system('nix-store', '--check-validity', item, out: File::NULL)
        raise Invalid, 'host store item is missing or unregistered'
      end
      unless system('nix-store', '--option', 'substitute', 'false', '--add-root', root, '--indirect', '--realise', item, out: File::NULL)
        raise Invalid, 'host store-item root registration failed'
      end
      roots, status = Open3.capture2('nix-store', '--query', '--roots', item)
      unless status.success? && File.symlink?(root) && File.readlink(root) == item && roots.lines.map(&:chomp).include?("#{root} -> #{item}")
        raise Invalid, 'host store-item root registration is unproved'
      end
      root
    end

    def provenance(path, digest, kind, reference)
      string!(reference)
      { 'source_config' => path, 'source_config_sha256' => digest, 'proof_kind' => kind, 'proof_reference' => reference }
    end

    def empty_applied(config)
      { 'version' => APPLIED_VERSION, 'workspace' => @workspace, 'slug' => @slug,
        'configuration' => config, 'provenance' => {}, 'pending' => nil }
    end

    def pending_operation(operation, targets, path, digest)
      { 'operation' => operation, 'targets' => targets, 'candidate' => path, 'candidate_sha256' => digest }
    end

    def applied_record
      return nil unless File.exist?(@applied_path) || File.symlink?(@applied_path)
      applied, = private_json(@applied_path, max_bytes: MAX_CONFIG_BYTES)
      exact_keys!(applied, %w[version workspace slug configuration provenance pending])
      unless applied.fetch('version').is_a?(Integer) && applied.fetch('version') == APPLIED_VERSION && applied.fetch('workspace') == @workspace && applied.fetch('slug') == @slug
        raise Invalid, 'unsupported applied selection'
      end
      configuration = applied.fetch('configuration')
      managed_disk_paths(configuration)
      proofs = applied.fetch('provenance')
      unless proofs.is_a?(Hash) && (proofs.keys - configuration.fetch('machines').keys).empty?
        raise Invalid, 'invalid applied provenance'
      end
      proofs.each do |name, proof|
        validate_provenance!(proof)
        source, = config_file(proof.fetch('source_config'), expected_digest: proof.fetch('source_config_sha256'))
        raise Invalid, 'applied descriptor differs from its proof' unless source.fetch('machines').fetch(name) == configuration.fetch('machines').fetch(name)
      end
      pending = applied.fetch('pending')
      if pending
        exact_keys!(pending, %w[operation targets candidate candidate_sha256])
        targets = pending.fetch('targets')
        unless %w[update boot copied_boot].include?(pending.fetch('operation')) && targets.is_a?(Array) &&
               !targets.empty? && targets.uniq == targets && (targets - configuration.fetch('machines').keys).empty? &&
               (pending.fetch('operation') != 'update' || targets.one?)
          raise Invalid, 'invalid pending applied operation'
        end
        config_file(pending.fetch('candidate'), expected_digest: pending.fetch('candidate_sha256'))
      end
      applied
    end

    def complete_applied?(applied)
      applied.fetch('pending').nil? && applied.fetch('provenance').keys.sort == applied.fetch('configuration').fetch('machines').keys.sort
    end

    def write_applied(applied)
      write_private_json(@applied_path, applied, max_bytes: MAX_CONFIG_BYTES)
      applied
    end

    def managed_disk_paths(config)
      machines = config.fetch('machines')
      unless machines.is_a?(Hash) && machines.key?('services') && machines.length.between?(1, 16)
        raise Invalid, 'invalid applied machine set'
      end
      paths = machines.flat_map do |name, machine|
        string!(name, max_bytes: 128)
        raise Invalid, 'invalid machine name' unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
        disks = [machine['rootDisk'], *machine.fetch('disks', [])].compact
        raise Invalid, 'invalid retained disk set' unless disks.length.between?(1, 32)
        disks.map do |disk|
          unless disk.fetch('type') == 'file' && disk.fetch('create', true) == true && disk.fetch('preserve', true) == true
            raise Invalid, 'retained selection requires preserved managed disks'
          end
          path = File.expand_path(string!(disk.fetch('device')).gsub('{machine}', name), File.join(@directory, 'state'))
          raise Invalid, 'retained disk escapes state' unless path.start_with?(File.join(@directory, 'state') + '/') && !File.symlink?(path)
          path
        end
      end
      raise Invalid, 'retained disks share a destination' unless paths.uniq == paths
      paths
    end

    def compatible_configuration!(current, candidate)
      unless current.reject { |key, _| %w[machines labels].include?(key) } == candidate.reject { |key, _| %w[machines labels].include?(key) } &&
             current.fetch('machines').keys.sort == candidate.fetch('machines').keys.sort
        raise Invalid, 'candidate changes the retained topology'
      end
      current.fetch('machines').each do |name, machine|
        raise Invalid, 'candidate changes retained layout' unless machine_layout(machine) == machine_layout(candidate.fetch('machines').fetch(name))
      end
    end

    def machine_layout(machine)
      allowed = case machine.fetch('spin')
                when 'nixos' then %w[toplevel kernel initrd]
                when 'vpsadminos' then %w[toplevel kernel initrd squashfs]
                else []
                end
      allowed = [] unless machine.fetch('bootMode', 'direct') == 'direct'
      result = machine.reject { |key, _| allowed.include?(key) }
      if machine.fetch('spin') == 'nixos' && machine.fetch('bootMode', 'direct') == 'direct' && machine.key?('rootDisk')
        result = result.merge('rootDisk' => machine.fetch('rootDisk').reject { |key, _| key == 'image' })
      end
      result
    end

    def validate_provenance!(proof)
      exact_keys!(proof, %w[source_config source_config_sha256 proof_kind proof_reference])
      store_path!(proof.fetch('source_config'))
      digest!(proof.fetch('source_config_sha256'))
      string!(proof.fetch('proof_reference'))
      raise Invalid, 'unsupported residency proof' unless %w[prior_boot prior_update held_copy].include?(proof.fetch('proof_kind'))
    end

    def derive_recovery!(record, hold_digest, evidence, original)
      exact_keys!(evidence, %w[version kind workspace slug expected_hold_sha256 machines])
      unless evidence.fetch('version').is_a?(Integer) && evidence.fetch('version') == EVIDENCE_VERSION && evidence.fetch('kind') == 'retained_boot_recovery' &&
             evidence.fetch('workspace') == @workspace && evidence.fetch('slug') == @slug && evidence.fetch('expected_hold_sha256') == hold_digest
        raise Invalid, 'recovery evidence differs from predecessor'
      end
      proofs = evidence.fetch('machines')
      unless proofs.is_a?(Hash) && proofs.keys.sort == original.fetch('machines').keys.sort
        raise Invalid, 'recovery must prove every recorded machine'
      end
      dns = original.fetch('machines').keys & %w[dns-primary dns-secondary]
      raise Invalid, 'recorded selection has no supported DNS guests' if dns.empty?
      selected = original.fetch('machines').dup
      dns_sources = []
      proofs.each do |name, proof|
        exact_keys!(proof, %w[source_config source_config_sha256 proof_kind proof_reference disks])
        validate_provenance!(proof.reject { |key, _| key == 'disks' })
        source, = config_file(proof.fetch('source_config'), expected_digest: proof.fetch('source_config_sha256'))
        machine = source.fetch('machines').fetch(name)
        unless machine_layout(machine) == machine_layout(original.fetch('machines').fetch(name))
          raise Invalid, 'recovery changes a retained layout'
        end
        disks = proof.fetch('disks')
        unless disks.is_a?(Array) && disks.length.between?(1, 32)
          raise Invalid, 'invalid stopped disk binding'
        end
        disks.each do |disk|
          exact_keys!(disk, %w[device dev ino size])
          string!(disk.fetch('device'))
          unless %w[dev ino size].all? { |key| disk.fetch(key).is_a?(Integer) && disk.fetch(key) >= (key == 'size' ? 1 : 0) }
            raise Invalid, 'invalid stopped disk stat'
          end
        end
        expected_disks = disk_identities(name:, machine:)
        raise Invalid, 'current stopped disk binding differs' unless proof.fetch('disks') == expected_disks
        if dns.include?(name)
          unless machine.fetch('spin') == 'nixos' && original.fetch('machines').fetch(name).fetch('spin') == 'nixos'
            raise Invalid, 'DNS recovery requires NixOS descriptors'
          end
          raise Invalid, 'DNS recovery requires prior full boot' unless proof.fetch('proof_kind') == 'prior_boot'
          dns_sources << proof.fetch('source_config')
          selected[name] = machine
        else
          kind = name == 'services' ? 'held_copy' : 'prior_update'
          unless proof.fetch('proof_kind') == kind && machine == original.fetch('machines').fetch(name)
            raise Invalid, 'recovery changes a proved services or Node selection'
          end
        end
      end
      raise Invalid, 'DNS guests require the same prior full boot configuration' unless dns_sources.uniq.one?
      candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
      unless selected.fetch('services') == candidate.fetch('machines').fetch('services') &&
             selected.fetch('services').fetch('toplevel') == record.fetch('copied_toplevel')
        raise Invalid, 'recovery loses the completed services copy'
      end
      preserving_seed!(candidate)
      corrected = original.merge('machines' => selected)
      validate_disks!(corrected)
      corrected
    end

    def disk_identities(name:, machine:)
      validate_machine_disks!(name:, machine:).map do |path|
        stat = File.stat(path)
        { 'device' => path.delete_prefix(File.join(@directory, 'state') + '/'),
          'dev' => stat.dev, 'ino' => stat.ino, 'size' => stat.size }
      end
    end

    def history_directory!
      path = File.join(@directory, 'maintenance-history')
      Dir.mkdir(path, 0o700) unless File.exist?(path) || File.symlink?(path)
      stat = File.lstat(path)
      raise Invalid, 'unsafe maintenance history' unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
      path
    end

    def archive_bytes!(path, bytes)
      if File.exist?(path) || File.symlink?(path)
        private_json(path, max_bytes: MAX_RECORD_BYTES)
        raise Invalid, 'immutable history differs' unless File.binread(path) == bytes
        return
      end
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.open(File.dirname(path)) { |directory| directory.fsync }
    end

    def original_next!(record)
      recovery = record.fetch('recovery')
      config_file(recovery.fetch('original_next_config'), expected_digest: recovery.fetch('original_next_config_sha256')).first
    end

    def validate_recovery_record!(record)
      if record['recovery'].nil?
        raise Invalid, 'unexpected predecessor without recovery' unless record['predecessor'].nil?
        return
      end
      exact_keys!(record.fetch('predecessor'), %w[path sha256])
      recovery = record.fetch('recovery')
      exact_keys!(recovery, %w[evidence_path evidence_sha256 original_next_config original_next_config_sha256])
      predecessor, predecessor_digest = private_json(record.fetch('predecessor').fetch('path'), max_bytes: MAX_RECORD_BYTES)
      unless record.fetch('predecessor').fetch('path') == File.join(@directory, 'maintenance-history', "#{predecessor_digest}-hold.json") &&
             recovery.fetch('evidence_path') == File.join(@directory, 'maintenance-history', "#{recovery.fetch('evidence_sha256')}-evidence.json")
        raise Invalid, 'recovery snapshots escape private history'
      end
      unless predecessor_digest == record.fetch('predecessor').fetch('sha256') &&
             predecessor['recovery'].nil? && predecessor['predecessor'].nil?
        raise Invalid, 'recovery predecessor differs or recurses'
      end
      validate_record!(predecessor)
      raise Invalid, 'predecessor copy is incomplete' unless %w[copied starting_copied].include?(predecessor.fetch('phase'))
      predecessor_next, = config_file(predecessor.fetch('next_config'), expected_digest: predecessor.fetch('next_config_sha256'))
      raise Invalid, 'predecessor selection differs' unless predecessor_next == next_configuration(predecessor)
      unchanged = RECORD_KEYS - %w[version phase runner_pid runner_start boot_id next_config next_config_sha256]
      raise Invalid, 'recovery changed original copy bindings' unless unchanged.all? { |key| predecessor.fetch(key) == record.fetch(key) }
      evidence, evidence_digest = private_json(recovery.fetch('evidence_path'), max_bytes: MAX_RECORD_BYTES)
      raise Invalid, 'recovery evidence digest differs' unless evidence_digest == recovery.fetch('evidence_sha256')
      unless recovery.fetch('original_next_config') == predecessor.fetch('next_config') &&
             recovery.fetch('original_next_config_sha256') == predecessor.fetch('next_config_sha256')
        raise Invalid, 'recovery original next binding differs'
      end
      expected = derive_recovery!(record, predecessor_digest, evidence, original_next!(record))
      actual, = config_file(record.fetch('next_config'), expected_digest: record.fetch('next_config_sha256'))
      raise Invalid, 'recovered next differs' unless actual == expected
    end

    def recovery_configuration!(record, original)
      recovery = record.fetch('recovery')
      evidence, = private_json(recovery.fetch('evidence_path'), max_bytes: MAX_RECORD_BYTES)
      derive_recovery!(record, record.fetch('predecessor').fetch('sha256'), evidence, original)
    end

    def next_configuration(record)
      resident, = config_file(record.fetch('resident_config'), expected_digest: record.fetch('resident_config_sha256'))
      candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
      marker = preserving_seed!(candidate)
      compatible_services!(resident, candidate)
      original = resident.merge('machines' => resident.fetch('machines').merge('services' => candidate.fetch('machines').fetch('services')),
                                'labels' => resident.fetch('labels', {}).merge('vpsadminPreservingSeed' => JSON.generate(marker)))
      return original unless record['recovery']

      recovery_configuration!(record, original)
    end

    def config_file(path, expected_digest: nil, store: true)
      store_path!(path) if store
      bytes = bounded_bytes(path, MAX_CONFIG_BYTES)
      digest = Digest::SHA256.hexdigest(bytes)
      raise Invalid, 'recorded configuration digest changed' if expected_digest && digest != expected_digest
      config = parse_json(bytes)
      unless config.is_a?(Hash) && config['machines'].is_a?(Hash) && config['machines']['services'].is_a?(Hash)
        raise Invalid, 'invalid configuration shape'
      end
      [config, digest]
    end

    def evidence_file(path)
      evidence, digest = private_json(path, max_bytes: MAX_EVIDENCE_BYTES)
      evidence!(evidence)
      [evidence, digest]
    end

    def evidence!(evidence)
      exact_keys!(evidence, EVIDENCE_KEYS)
      unless evidence.fetch('version').is_a?(Integer) && evidence.fetch('version') == EVIDENCE_VERSION && evidence.fetch('workspace') == @workspace &&
             evidence.fetch('slug') == @slug && %w[prior_activation prior_copy cold_residency].include?(evidence.fetch('evidence_kind'))
        raise Invalid, 'unsupported residency evidence scope'
      end
      EVIDENCE_KEYS.reject { |key| key == 'version' }.each { |key| string!(evidence.fetch(key), max_bytes: key == 'slug' ? 128 : 2048) }
      store_path!(evidence.fetch('resident_config'))
      store_path!(evidence.fetch('services_toplevel'))
      digest!(evidence.fetch('resident_config_sha256'))
    end

    def store_path!(path)
      string!(path)
      unless path.start_with?(@store_root + '/') && File.expand_path(path) == path && path.match?(/\A[A-Za-z0-9\/_.+-]+\z/)
        raise Invalid, 'invalid recorded store path'
      end
      path
    end

    def string!(value, max_bytes: 2048)
      unless value.is_a?(String) && value.valid_encoding? && value.encoding == Encoding::UTF_8 &&
             value.bytesize.between?(1, max_bytes) && !value.match?(/[\x00-\x1f\x7f]/)
        raise Invalid, 'invalid bounded string'
      end
      value
    end

    def digest!(value)
      raise Invalid, 'invalid recorded digest' unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def exact_keys!(object, keys)
      raise Invalid, 'invalid JSON object fields' unless object.is_a?(Hash) && object.keys.sort == keys.sort
    end

    def bounded_bytes(path, limit)
      raise Invalid, 'recorded file is missing' unless File.file?(path)
      bytes = File.open(path, 'rb') { |file| file.read(limit + 1) }.force_encoding(Encoding::UTF_8)
      raise Invalid, 'recorded file exceeds bound' if bytes.bytesize > limit || !bytes.valid_encoding?
      bytes
    end

    def private_json(path, max_bytes:)
      stat = File.lstat(path)
      unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600
        raise Invalid, 'private evidence or record has unsafe ownership or mode'
      end
      bytes = bounded_bytes(path, max_bytes)
      [parse_json(bytes), Digest::SHA256.hexdigest(bytes)]
    rescue Errno::ENOENT
      raise Invalid, 'private evidence or record is missing'
    end

    def parse_json(bytes)
      parsed = JSON.parse(bytes, object_class: UniqueHash, max_nesting: 24, create_additions: false)
      # Duplicate detection applies to input bytes, not subsequent state changes.
      plain_json(parsed)
    rescue JSON::ParserError, JSON::NestingError
      raise Invalid, 'malformed bounded JSON'
    end

    def plain_json(value)
      case value
      when Hash
        value.to_h { |key, item| [key, plain_json(item)] }
      when Array
        value.map { |item| plain_json(item) }
      else
        value
      end
    end

    def required_record
      load_record || raise(Invalid, 'maintenance operation is missing')
    end

    def validate_identity!(pid, start, boot_id)
      unless pid.is_a?(Integer) && pid.positive? && start.is_a?(String) && start.match?(/\A[0-9]+\z/) &&
             boot_id.is_a?(String) && boot_id.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
        raise Invalid, 'invalid runner or guest boot identity'
      end
    end

    def assert_boot!(record, pid, start, boot_id)
      validate_identity!(pid, start, boot_id)
      unless record.fetch('runner_pid') == pid && record.fetch('runner_start') == start && record.fetch('boot_id') == boot_id
        raise Invalid, 'maintenance runner or guest boot changed'
      end
    end

    def write_record(record)
      record = record.merge('version' => VERSION, 'predecessor' => record['predecessor'], 'recovery' => record['recovery'])
      write_private_json(@record_path, record, max_bytes: MAX_RECORD_BYTES)
      record
    end

    def write_private_json(path, value, max_bytes:)
      bytes = JSON.generate(value)
      raise Invalid, 'maintenance record exceeds bound' if bytes.bytesize > max_bytes
      Tempfile.create(['.maintenance-', '.json'], File.dirname(path)) do |file|
        file.chmod(0o600)
        file.write(bytes)
        file.flush
        file.fsync
        File.rename(file.path, path)
        File.open(File.dirname(path)) { |directory| directory.fsync }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    workspace, slug, directory, action, *arguments = ARGV
    maintenance = DevClusters::VpsAdminMaintenance.new(workspace:, slug:, directory:)
    identity = lambda do |values|
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid maintenance identity arguments' unless values.length == 3
      { pid: Integer(values.fetch(0), 10), start: values.fetch(1), boot_id: values.fetch(2) }
    end
    case action
    when 'root-source'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid source root arguments' unless arguments.one?
      maintenance.root_source_config!(config_path: arguments.fetch(0))
    when 'root-maintenance-sources'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected source root arguments' unless arguments.empty?
      maintenance.root_maintenance_sources!
    when 'root-payloads'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid host payload arguments' unless arguments.length.between?(1, 2)
      maintenance.root_host_payloads!(config_path: arguments.fetch(0), machines: arguments[1] && [arguments[1]])
    when 'root-applied-payloads'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected host payload arguments' unless arguments.empty?
      maintenance.root_applied_payloads!
    when 'applied-begin-update'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid applied update arguments' unless arguments.length == 2
      maintenance.begin_update!(candidate_path: arguments.fetch(0), target: arguments.fetch(1))
    when 'applied-promote-update'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid applied proof arguments' unless arguments.length == 2
      maintenance.promote_update!(target: arguments.fetch(0), proof_reference: arguments.fetch(1))
    when 'applied-begin-boot'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid applied boot arguments' unless arguments.length == 2
      maintenance.begin_boot!(config_path: arguments.fetch(0), operation: arguments.fetch(1))
    when 'applied-finish-boot'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid applied boot proof arguments' unless arguments.length == 2
      maintenance.finish_boot!(config_path: arguments.fetch(0), proof_reference: arguments.fetch(1))
    when 'applied-config'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid applied render arguments' unless arguments.length.between?(1, 2)
      maintenance.retained_config!(output_path: arguments.fetch(0), candidate_path: arguments[1])
    when 'applied-present'
      puts maintenance.retained_selection? ? 'true' : 'false'
    when 'recover-prepare'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid recovery arguments' unless arguments.length == 1
      puts JSON.generate(maintenance.prepare_recovery!(evidence_path: arguments.fetch(0), output_path: File.join(directory, 'recovery-next.json')))
    when 'recover-commit'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid rooted recovery arguments' unless arguments.length == 2
      maintenance.commit_recovery!(evidence_path: arguments.fetch(0), next_path: arguments.fetch(1))
    when 'prepare'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid maintenance evidence arguments' unless arguments.length == 3
      maintenance.prepare!(config_path: arguments.fetch(0), services_toplevel: arguments.fetch(1), evidence_path: arguments.fetch(2))
    when 'ready'
      maintenance.bind_boot!(**identity.call(arguments))
    when 'begin-copy'
      maintenance.begin_copy!(candidate_path: arguments.shift, **identity.call(arguments))
    when 'build-next'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'invalid next-config arguments' unless arguments.length == 1
      maintenance.build_next!(next_path: arguments.fetch(0))
    when 'finish-copy'
      maintenance.finish_copy!(next_path: arguments.shift, **identity.call(arguments))
    when 'release'
      maintenance.release!(**identity.call(arguments))
    when 'resident'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      puts maintenance.resident_config!
    when 'inspect'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      maintenance.validate_runner!(config_path: maintenance.resident_config!)
    when 'candidate-toplevel'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      puts maintenance.selected_toplevel!
    when 'copied'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      puts maintenance.copied_config!
    when 'status'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      puts JSON.generate(maintenance.status)
    when 'adopt'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      maintenance.validate_adoption!
    when 'ordinary'
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unexpected maintenance arguments' unless arguments.empty?
      raise DevClusters::VpsAdminMaintenance::Invalid, 'pending maintenance requires stop, maintenance retry or copy-only' if maintenance.pending?
    else
      raise DevClusters::VpsAdminMaintenance::Invalid, 'unsupported maintenance action'
    end
  rescue DevClusters::VpsAdminMaintenance::Invalid, KeyError, TypeError, ArgumentError, SystemCallError
    warn 'error: maintenance evidence, state or selection validation failed'
    exit 1
  end
end
