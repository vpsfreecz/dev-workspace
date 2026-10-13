# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'fileutils'
require 'securerandom'
command_library = File.join(__dir__, 'workspace-coordination-command.rb')
require(File.file?(command_library) ? command_library : ENV.fetch('WORKSPACE_COORDINATION_COMMAND'))

# Build and copy in preparation. All subsequent operations execute in the
# configuration's retained immutable confctl gem environment, without Nix eval.
module WorkspaceConfctlAdapter
  LIMIT = 262_144
  class StrictHash < Hash
    def []=(key, value)
      raise 'duplicate adapter key' if key?(key)
      super
    end
  end

  def self.parse(bytes)
    raise 'adapter input is too large' if bytes.bytesize > LIMIT
    JSON.parse(bytes, object_class: StrictHash, max_nesting: 48)
  end

  def self.digest(value)
    canonical = lambda do |v|
      case v
      when Hash then v.keys.sort.to_h { |k| [k, canonical.call(v[k])] }
      when Array then v.map { |item| canonical.call(item) }
      else v
      end
    end
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical.call(value)))}"
  end

  def self.capture(*args, input: '')
    out, err, status, overflow = WorkspaceCoordination::Command.run(args, input:, limit: LIMIT, log: @diagnostics)
    raise "#{args.first}: #{err.byteslice(0, 4096)}" unless status.success?
    raise 'adapter command output exceeds its bound' if overflow
    out
  end

  def self.run(bytes, pinned: false)
    request = parse(bytes)
    @diagnostics = WorkspaceCoordination::Command::Log.new
    raise 'unsupported adapter protocol' unless request['schema'] == 1
    fields = %w[schema operation target machine]
    case request['operation']
    when 'prepare' then fields += %w[requestId source stateRoot]
    when 'activate' then fields += %w[artifact expectedLive attemptId requestDigest attemptDirectory]
    when 'inspect', 'transition-check' then fields += %w[artifact]
    when 'reconcile' then fields += %w[artifact attemptId requestDigest attemptDirectory expectedLive]
    else raise 'unsupported adapter operation'
    end
    raise 'invalid adapter fields' unless request.keys.sort == fields.sort
    raise 'invalid machine mapping' unless request['machine'].is_a?(Hash) && request['machine']['selector'].is_a?(String)
    unless pinned
      if request['operation'] == 'prepare'
        source = request.fetch('source')
        raise 'invalid source revision' unless source.keys.sort == %w[path revision] && source['revision'].match?(/\A[0-9a-f]{40}\z/)
        actual = capture('git', '-C', source.fetch('path'), 'rev-parse', 'HEAD').strip
        raise 'configuration source changed' unless actual == source['revision'] && capture('git', '-C', source['path'], 'status', '--porcelain').empty?
        helper = File.realpath(File.join(__dir__, '../bin/workspace-confctl-adapter'))
        # Both paths are immutable/owned, but still encode them as Nix strings.
        flake = "git+file://#{File.realpath(source['path'])}?rev=#{actual}"
        expression = <<~NIX
          let f = builtins.getFlake #{JSON.generate(flake)};
              p = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
              c = f.inputs.confctl.packages.x86_64-linux.confctl;
              h = builtins.storePath #{JSON.generate(helper)};
          in p.writeShellScriptBin "workspace-confctl-environment" ''
            export GEM_HOME="${c.deps}/${c.ruby.gemPath}"
            export GEM_PATH="$GEM_HOME"
            export RUBYLIB="${c.src}/lib"
            export PATH="${p.lib.makeBinPath [p.git p.openssh p.nix]}:$PATH"
            exec ${c.ruby}/bin/ruby ${h} --pinned
          ''
        NIX
        environment = capture('nix', 'build', '--impure', '--no-link', '--print-out-paths', '--expr', expression).strip
        raise 'unexpected prepared environment' unless environment.match?(%r{\A/nix/store/[^/\s]+\z})
      else
        environment = request.fetch('artifact').fetch('environmentPackage')
        raise 'invalid retained environment' unless environment.match?(%r{\A/nix/store/[^/\s]+\z})
      end
      response = parse(capture(File.join(environment, 'bin/workspace-confctl-environment'), input: bytes))
      response.fetch('artifact')['environmentPackage'] = environment if request['operation'] == 'prepare'
      return response
    end

    artifact = request['artifact']
    source = request['operation'] == 'prepare' ? request.fetch('source').fetch('path') : artifact.fetch('source')
    Dir.chdir(source) do
      # confctl loads configuration scripts and diagnostics; preserve protocol
      # stdout for exactly one JSON response.
      saved = STDOUT.dup
      STDOUT.reopen(STDERR)
      begin
        require 'confctl'
        # Library callers must initialize the logger normally opened by the
        # CLI. Keep its command diagnostics on the bounded stderr channel.
        ConfCtl::Logger.open('workspace-coordination', output: STDERR)
        if request['operation'] == 'prepare'
          selector = request['machine'].fetch('selector')
          machine = ConfCtl::MachineList.new[selector]
          raise 'selector must resolve one standalone NixOS machine' unless machine && machine.name == selector && machine.spin == 'nixos' && !machine.carried?
          generation = ConfCtl::Nix.new.build_attributes(hosts: [selector]).fetch(selector)
          metadata = parse(File.binread(File.join(generation.dir, 'generation.json')))
          raise 'copy did not finish' unless ConfCtl::Nix.new.copy(machine, [generation.toplevel, generation.auto_rollback].compact)
          mapping = {'name' => machine.name, 'metaConfig' => machine.meta, 'carrier' => nil,
            'clusterName' => machine.cluster_name, 'key' => machine.key}
          value = {'adapterProtocol' => 1, 'configurationRevision' => request['source']['revision'],
            'generationName' => generation.name, 'generationDigest' => digest(metadata),
            'toplevel' => generation.toplevel, 'autoRollback' => generation.auto_rollback,
            'machineConfig' => mapping, 'inputsInfo' => generation.inputs_info, 'inputs' => generation.inputs}
          return {'schema' => 1, 'status' => 'prepared', 'artifact' => value, 'observed' => inspect_machine(machine)}
        end
        raise 'unsupported retained artifact' unless artifact['adapterProtocol'] == 1
        mapping = artifact.fetch('machineConfig')
        machine = ConfCtl::Machine.new(mapping, machine_list: nil)
        raise 'retained selector differs' unless machine.name == request['machine']['selector'] && machine.spin == 'nixos' && !machine.carried?
        generation = ConfCtl::Generation::Build.new(machine.name)
        generation.load(artifact.fetch('generationName'))
        metadata = parse(File.binread(File.join(generation.dir, 'generation.json')))
        unless digest(metadata) == artifact['generationDigest'] && generation.toplevel == artifact['toplevel'] && generation.auto_rollback == artifact['autoRollback']
          raise 'retained generation differs from sealed artifact'
        end
        return {'schema' => 1, 'compatible' => true} if request['operation'] == 'transition-check'
        observed = inspect_machine(machine)
        return {'schema' => 1, 'observed' => observed} if request['operation'] == 'inspect'
        if request['operation'] == 'reconcile'
          # Baseline links or target links alone cannot prove a lost activation
          # and its rollback helper finished. Only our verified receipt can.
          receipt = File.join(request.fetch('attemptDirectory'), 'adapter-result.json')
          if File.file?(receipt)
            result = parse(File.binread(receipt))
            return result if result['attemptId'] == request['attemptId'] && result['requestDigest'] == request['requestDigest'] && result['observed'] == observed
          end
          return outcome(request, 'unknown', observed, 'remote activation completion requires operator recovery')
        end
        return outcome(request, 'baseline_changed', observed) unless observed == request['expectedLive']
        directory = request.fetch('attemptDirectory')
        raise 'invalid attempt directory' unless File.basename(directory) == request['attemptId'] && request['attemptId'].match?(/\A[0-9a-f-]{36}\z/)
        nix = ConfCtl::Nix.stateless
        return outcome(request, 'not_applied', observed, 'dry activation failed') unless nix.activate(machine, generation, 'dry-activate')
        observed = inspect_machine(machine)
        return outcome(request, 'baseline_changed', observed) unless observed == request['expectedLive']
        phase(request, 'activation_intent')
        begin
          ok = machine.auto_rollback? ? nix.activate_with_rollback(machine, generation, 'switch') : nix.activate(machine, generation, 'switch')
          raise 'activation failed or rolled back' unless ok
          phase(request, 'activation_finished')
          phase(request, 'profile_publication_intent')
          raise 'system profile publication failed' unless nix.set_profile(machine, generation.toplevel)
          observed = inspect_machine(machine)
          raise 'both live system and profile must select the prepared generation' unless observed['runningSystem'] == generation.toplevel && observed['systemProfile'] == generation.toplevel
          phase(request, 'verified')
          result = outcome(request, 'applied', observed)
        rescue StandardError => e
          result = outcome(request, 'unknown', nil, e.message)
        end
        atomic(File.join(directory, 'adapter-result.json'), result)
        result
      ensure
        STDOUT.reopen(saved)
        saved.close
      end
    end
  ensure
    if @diagnostics && request && !pinned
      directory = request['operation'] == 'prepare' ? File.join(request.fetch('stateRoot'), 'preparation', request.fetch('requestId')) : request['attemptDirectory']
      if directory
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.open(File.join(directory, 'adapter-log'), File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(@diagnostics.bytes) }
      end
    end
  end

  def self.inspect_machine(machine)
    control = ConfCtl::MachineControl.new(machine)
    {'runningSystem' => control.read_realpath('/run/current-system'),
      'systemProfile' => control.read_realpath(machine.profile),
      'machineIdentity' => digest([machine.name, machine.target_host, machine.target_port, machine.profile])}
  end

  def self.outcome(request, state, observed, error = nil)
    {'schema' => 1, 'attemptId' => request['attemptId'], 'requestDigest' => request['requestDigest'],
      'outcome' => state, 'observed' => observed, 'error' => error}
  end

  def self.atomic(path, value)
    tmp = "#{path}.#{SecureRandom.hex(8)}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(value)); file.flush; file.fsync
    end
    File.rename(tmp, path)
    File.open(File.dirname(path)) { |file| file.fsync }
  ensure
    File.unlink(tmp) if tmp && File.exist?(tmp)
  end

  def self.phase(request, name)
    atomic(File.join(request.fetch('attemptDirectory'), 'adapter-phase.json'),
      {'schema' => 1, 'attemptId' => request['attemptId'], 'requestDigest' => request['requestDigest'], 'phase' => name})
  end
end
