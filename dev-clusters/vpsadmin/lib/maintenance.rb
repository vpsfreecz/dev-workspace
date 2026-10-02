# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tempfile'

module DevClusters
  # Private operation state is always accessed under the provider lifecycle lock.
  # Operator residency evidence is a bounded reference, not guest authentication.
  class VpsAdminMaintenance
    Invalid = Class.new(StandardError)
    VERSION = 1
    MAX_CONFIG_BYTES = 2 * 1024 * 1024
    MAX_RECORD_BYTES = 16 * 1024
    MAX_EVIDENCE_BYTES = 8 * 1024
    MAX_KERNEL_COMMAND_LINE_BYTES = 2047
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
        'version' => VERSION, 'mode' => record.fetch('mode'), 'phase' => record.fetch('phase'),
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
        'evidence_sha256' => evidence_digest, 'mask_policy' => VERSION,
        'runner_pid' => nil, 'runner_start' => nil, 'boot_id' => nil,
        'candidate' => nil, 'candidate_sha256' => nil, 'next_config' => nil,
        'next_config_sha256' => nil, 'copied_toplevel' => nil, 'preserving_seed' => nil
      })
    end

    def bind_boot!(pid:, start:, boot_id:)
      record = required_record
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
      exact_keys!(record, RECORD_KEYS)
      unless record.fetch('version').is_a?(Integer) && record.fetch('version') == VERSION && record.fetch('mode') == 'maintenance' &&
             record.fetch('mask_policy').is_a?(Integer) && record.fetch('mask_policy') == VERSION && PHASES.include?(record.fetch('phase')) &&
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
        unless record.fetch('preserving_seed') == { 'version' => VERSION, 'existingAssignments' => 'preserve' }
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
      disks.map do |disk|
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
             marker == { 'version' => VERSION, 'existingAssignments' => 'preserve' }
        raise Invalid, 'unsupported preserving seed contract'
      end
      marker
    end

    private

    def next_configuration(record)
      resident, = config_file(record.fetch('resident_config'), expected_digest: record.fetch('resident_config_sha256'))
      candidate, = config_file(record.fetch('candidate'), expected_digest: record.fetch('candidate_sha256'))
      marker = preserving_seed!(candidate)
      compatible_services!(resident, candidate)
      resident.merge('machines' => resident.fetch('machines').merge('services' => candidate.fetch('machines').fetch('services')),
                     'labels' => resident.fetch('labels', {}).merge('vpsadminPreservingSeed' => JSON.generate(marker)))
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
      unless evidence.fetch('version').is_a?(Integer) && evidence.fetch('version') == VERSION && evidence.fetch('workspace') == @workspace &&
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
