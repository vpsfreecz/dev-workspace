# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'shellwords'
require 'timeout'

# The guest half runs through the database package's normal db:seed:file task.
# The host half uses only the public, session-bound provider SSH/update commands.
module StorageProfileAcceptance
  Invalid = Class.new(StandardError)
  MAX_SECONDS = 2400
  PAYLOADS = {
    'A' => { 'keep' => "fixture-A\n", 'remove' => "removed-in-B\n" },
    'B' => { 'keep' => "fixture-B\n", 'added' => "added-in-B\n" }
  }.freeze

  module Guest
    module_function

    # Publish admitted IDs before waiting, so an interrupted chain leaves
    # enough private evidence to inspect its exact objects without replaying it.
    def record_admitted!(chain, objects = {})
      path = File.join(File.dirname(ENV.fetch('STORAGE_PROFILE_ACCEPTANCE_REPORT')), 'admitted.json')
      records = File.exist?(path) ? JSON.parse(File.binread(path)) : []
      raise Invalid, 'fixture admitted evidence exceeds bound' if records.size >= 64

      records << objects.merge('chain_id' => chain&.id)
      File.write(path, JSON.generate(records), mode: 'w', perm: 0o600)
    end

    def wait!(chain)
      raise Invalid, 'fixture did not admit a nonempty chain' unless chain

      record_admitted!(chain)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
      loop do
        chain.reload
        if chain.state == 'done'
          transactions = chain.transactions
          raise Invalid, 'terminal fixture chain has unfinished members' if transactions.where.not(done: 1).exists?
          raise Invalid, 'terminal fixture chain has pending confirmations' if
            TransactionConfirmation.where(transaction_id: transactions.select(:id), done: 0).exists?
          raise Invalid, 'terminal fixture chain retains locks' if ResourceLock.where(locked_by: chain).exists?

          return
        end
        raise Invalid, 'fixture chain is failed or uncertain' if %w[failed fatal resolved].include?(chain.state)
        raise Invalid, 'fixture chain deadline exceeded; inspect admitted work' if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 1
      end
    end

    def validate!(request)
      raise Invalid, 'invalid fixture request shape' unless request.is_a?(Hash)
      raise Invalid, 'invalid fixture key' unless request.fetch('key').is_a?(String) &&
                                                  request.fetch('key').match?(/\A[0-9a-f]{16}\z/)
      unless %w[prepare baseline tasks info retired-info snapshot transfer backup view free-view].include?(request.fetch('operation'))
        raise Invalid, 'unsupported fixture operation'
      end

      %w[user_id vps_id source_id snapshot_id clone_id os_template_id].each do |field|
        next unless request.key?(field)

        unless request.fetch(field).is_a?(Integer) && request.fetch(field).positive?
          raise Invalid, 'invalid fixture object ID'
        end
      end
      if request.fetch('operation') == 'view' && !%w[source destination].include?(request.fetch('copy'))
        raise Invalid, 'invalid fixture copy selection'
      end

      profile = DevClusters::VpsAdminStorageProfile.instance
      profile.require_enrollment! unless request.fetch('operation') == 'retired-info'
      StorageMutationAdmission.check!
      profile
    end

    def member!(request)
      user = User.find(request.fetch('user_id'))
      unless user.login == "profile-#{request.fetch('key')}" && user.level == 1 && user.object_state == 'active'
        raise Invalid, 'fixture member identity differs'
      end

      user
    end

    def source!(request)
      user = member!(request)
      source = DatasetInPool.find(request.fetch('source_id'))
      dataset = source.dataset
      unless dataset.user_id == user.id && dataset.confirmed? && source.confirmed? && !source.pool.backup?
        raise Invalid, 'fixture source ownership or confirmation differs'
      end

      if request.fetch('kind') == 'vps'
        vps = Vps.find(request.fetch('vps_id'))
        unless vps.user_id == user.id && vps.hostname == "profile-#{request.fetch('key')}" &&
               vps.dataset_in_pool_id == source.id && dataset.vps_id == vps.id
          raise Invalid, 'fixture VPS identity differs'
        end
      elsif request.fetch('kind') == 'nas'
        unless dataset.name == "profile-#{request.fetch('key')}" && dataset.parent&.user_id == user.id &&
               source.pool.role == 'primary'
          raise Invalid, 'fixture NAS child identity differs'
        end
      else
        raise Invalid, 'invalid fixture source kind'
      end
      source
    end

    def destination!(source, profile)
      backup_pool = profile.pool!(profile.config.fetch('backupPool'))
      copies = source.dataset.dataset_in_pools.joins(:pool).where(pools: { role: :backup }).limit(2).to_a
      unless copies.one? && copies.first.pool_id == backup_pool.id && copies.first.confirmed?
        raise Invalid, 'fixture backup destination differs'
      end

      copies.first
    end

    def machine!(node)
      names = JSON.parse(File.binread(ENV.fetch('STORAGE_PROFILE_ACCEPTANCE_NODE_MAP')))
      name = names.fetch(node.id.to_s)
      raise Invalid, 'fixture node has no supported provider route' unless name.match?(/\A(?:node[12]|storage1)\z/)

      name
    end

    def info(source, profile)
      destination = destination!(source, profile)
      tree = destination.dataset_trees.where(head: true).limit(2).to_a
      raise Invalid, 'fixture head tree is ambiguous' if tree.size > 1

      branches = tree.empty? ? [] : tree.first.branches.where(head: true).limit(2).to_a
      raise Invalid, 'fixture head branch is ambiguous' if branches.size > 1

      settled = tree.all?(&:confirmed?) && branches.all?(&:confirmed?)
      snapshots = [source, destination].to_h do |dip|
        rows = dip.snapshot_in_pools.order(:snapshot_id).limit(65).to_a
        raise Invalid, 'fixture snapshot evidence exceeds bound' if rows.size > 64

        settled &&= rows.all? { |sip| sip.confirmed? && sip.snapshot.confirmed? }
        rows.each do |sip|
          next unless dip.pool.backup?

          links = SnapshotInPoolInBranch.where(snapshot_in_pool: sip).limit(3).to_a
          settled &&= !links.empty? && links.all?(&:confirmed?)
        end
        [dip.id.to_s, rows.map { |sip| { 'id' => sip.snapshot_id, 'name' => sip.snapshot.name, 'sip_id' => sip.id } }]
      end
      {
        'source_id' => source.id, 'destination_id' => destination.id,
        'source_node' => machine!(source.pool.node), 'destination_node' => machine!(destination.pool.node),
        'source_fs' => "#{source.pool.filesystem}/#{source.dataset.full_name}",
        'settled' => settled,
        'tree_id' => tree.first&.id, 'branch_id' => branches.first&.id,
        'snapshots' => snapshots,
        'retention' => [source.min_snapshots, source.max_snapshots, destination.min_snapshots, destination.max_snapshots]
      }
    end

    def prepare!(request, profile)
      label = "profile-#{request.fetch('key')}"
      if User.exists?(login: label) || Vps.exists?(hostname: label)
        raise Invalid, 'fixture name already exists; inspect partial work'
      end

      user = User.new(login: label, full_name: 'Storage Profile Fixture', email: "#{label}@example.test",
                      language: Language.find_by!(code: 'en'), level: 1,
                      enable_basic_auth: false, enable_token_auth: true, mailer_enabled: false)
      user.set_password(SecureRandom.hex(24))
      chain, user = TransactionChains::User::Create.fire(user, false, nil, nil, true)
      record_admitted!(chain, 'user_id' => user.id)
      wait!(chain)
      source_pool = profile.pool!(profile.config.fetch('sourcePools').first)
      template = OsTemplate.find(request.fetch('os_template_id'))
      unless template.enabled? && template.hypervisor_type == source_pool.node.hypervisor_type
        raise Invalid, 'fixture OS template is disabled or incompatible'
      end

      chain, vps = VpsAdmin::API::Operations::Vps::Create.run(
        { user: user, node: source_pool.node, os_template: template, hostname: label },
        { cpu: 1, memory: 512, swap: 0, diskspace: 4096 },
        { ipv4: 0, ipv4_private: 0, ipv6: 0, start: true }
      )
      record_admitted!(chain, 'user_id' => user.id, 'vps_id' => vps.id)
      wait!(chain)
      nas_pool = profile.pool!(profile.config.fetch('nasPool'))
      roots = Dataset.roots.where(user: user).joins(:dataset_in_pools)
                     .where(dataset_in_pools: { pool_id: nas_pool.id }).distinct.limit(2).to_a
      raise Invalid, 'fixture member NAS root is missing or ambiguous' unless roots.one?

      parent = roots.first.dataset_in_pools.find_by!(pool: nas_pool)
      map = UserNamespaceMap.joins(:user_namespace).find_by!(user_namespaces: { user_id: user.id })
      child = Dataset.new(name: label, user: user, user_editable: true, user_create: true,
                          user_destroy: true, confirmed: Dataset.confirmed(:confirm_create))
      chain, dips = TransactionChains::Dataset::Create.fire(nas_pool, parent, [child],
                                                            { user: user, label: 'fixture', automount: false, userns_map: map })
      record_admitted!(chain, 'user_id' => user.id, 'source_id' => dips.last.id)
      wait!(chain)
      {
        'identity' => { 'user_id' => user.id, 'vps_id' => vps.id },
        'vps' => info(vps.reload.dataset_in_pool, profile),
        'nas' => info(dips.last.reload, profile)
      }
    end

    def baseline(request)
      user_id = request.fetch('user_id')
      {
        'namespaces' => UserNamespace.where.not(user_id: user_id).order(:id).map(&:attributes),
        'blocks' => UserNamespaceBlock.where.not(user_namespace_id: UserNamespace.where(user_id: user_id).select(:id))
                                      .or(UserNamespaceBlock.where(user_namespace_id: nil)).order(:id).map(&:attributes),
        'maps' => UserNamespaceMap.where.not(user_namespace_id: UserNamespace.where(user_id: user_id).select(:id)).order(:id).map(&:attributes),
        'entries' => UserNamespaceMapEntry.where.not(user_namespace_map_id: UserNamespaceMap.joins(:user_namespace)
                                                                                            .where(user_namespaces: { user_id: user_id }).select(:id)).order(:id).map(&:attributes),
        'packages' => ClusterResourcePackage.where.not(user_id: user_id).or(ClusterResourcePackage.where(user_id: nil)).order(:id).map(&:attributes),
        'items' => ClusterResourcePackageItem.where.not(cluster_resource_package_id: ClusterResourcePackage.where(user_id: user_id).select(:id))
                                             .order(:id).map(&:attributes),
        'assignments' => UserClusterResourcePackage.where.not(user_id: user_id).order(:id).map(&:attributes),
        'resources' => UserClusterResource.where.not(user_id: user_id).order(:id).map(&:attributes)
      }
    end

    def execute(request)
      profile = validate!(request)
      case request.fetch('operation')
      when 'prepare'
        prepare!(request, profile)
      when 'baseline'
        baseline(request)
      when 'tasks'
        rows = RepeatableTask.where(class_name: 'DatasetAction', row_id: profile.plan.dataset_plan.dataset_actions.select(:id)).order(:id).limit(257).to_a
        raise Invalid, 'fixture profile task evidence exceeds bound' if rows.size > 256

        rows.map(&:attributes)
      when 'info', 'retired-info'
        info(source!(request), profile).merge('enrollment' => profile.enrollment?)
      when 'snapshot'
        chain, sip = TransactionChains::Dataset::Snapshot.fire(source!(request), { label: "profile-#{request.fetch('key')}" })
        wait!(chain)
        { 'snapshot_id' => sip.snapshot_id, 'name' => sip.snapshot.reload.name }
      when 'transfer', 'backup'
        source = source!(request)
        destination = destination!(source, profile)
        klass = request.fetch('operation') == 'backup' ? TransactionChains::Dataset::Backup : TransactionChains::Dataset::Transfer
        chain, = klass.fire(source, destination)
        wait!(chain)
        sends = chain.transactions.where(handle: Transactions::Storage::Send.t_type).order(:id).map do |transaction|
          input = transaction.input
          input = JSON.parse(input) if input.is_a?(String)
          input.fetch('snapshots').map { |snapshot| snapshot.fetch('id') }
        end
        info(source, profile).merge('chain_id' => chain.id, 'send_snapshots' => sends)
      when 'view'
        source = source!(request)
        dip = request.fetch('copy') == 'source' ? source : destination!(source, profile)
        sip = dip.snapshot_in_pools.find_by!(snapshot_id: request.fetch('snapshot_id'))
        map = UserNamespaceMap.joins(:user_namespace).find_by!(user_namespaces: { user_id: member!(request).id })
        if SnapshotInPoolClone.exists?(snapshot_in_pool: sip, user_namespace_map: map)
          raise Invalid, 'fixture snapshot already has a clone; inspect retained evidence'
        end

        chain, clone = TransactionChains::SnapshotInPool::UseClone.fire(sip, map)
        record_admitted!(chain, 'clone_id' => clone.id, 'snapshot_id' => sip.snapshot_id, 'source_id' => dip.id)
        wait!(chain)
        { 'clone_id' => clone.id, 'node' => machine!(dip.pool.node), 'filesystem' => "#{dip.pool.filesystem}/vpsadmin/mount/#{clone.name}" }
      when 'free-view'
        source = source!(request)
        clone = SnapshotInPoolClone.find(request.fetch('clone_id'))
        dip_ids = [source.id, destination!(source, profile).id]
        unless dip_ids.include?(clone.snapshot_in_pool.dataset_in_pool_id) && clone.snapshot_in_pool.snapshot_id == request.fetch('snapshot_id') &&
               clone.user_namespace_map.user_namespace.user_id == member!(request).id
          raise Invalid, 'fixture clone is outside exact source/copy snapshot'
        end

        chain, = TransactionChains::SnapshotInPool::FreeClone.fire(clone)
        wait!(chain)
        # Same normal RemoveClone operation as PurgeClones, restricted to this
        # fixture-owned ID; never invoke the fleet-wide inactive clone sweep.
        klass = Class.new(TransactionChains::SnapshotInPool::PurgeClones) do
          # Persist the supported owning chain type, rather than a test-only
          # STI name that another API process could not load after the trial.
          def self.sti_name
            TransactionChains::SnapshotInPool::PurgeClones.sti_name
          end

          define_method(:link_chain) do |record|
            StorageMutationAdmission.check!
            lock(record)
            raise StorageProfileAcceptance::Invalid, 'fixture clone is not inactive' unless record.state == 'inactive'

            append_t(Transactions::Storage::RemoveClone, args: [record], reversible: :keep_going) do |confirmation|
              confirmation.decrement(record.snapshot_in_pool, :reference_count)
              confirmation.destroy(record)
            end
          end
        end
        unless StorageProfileAcceptance.const_defined?(:RemoveFixtureClone)
          StorageProfileAcceptance.const_set(:RemoveFixtureClone, klass)
        end
        chain, = StorageProfileAcceptance::RemoveFixtureClone.fire(clone)
        wait!(chain)
        { 'removed' => !SnapshotInPoolClone.exists?(clone.id) }
      else
        raise Invalid, 'unsupported fixture operation'
      end
    end
  end

  class Host
    attr_reader :summary

    def initialize(options)
      @slug = options.fetch(:slug)
      @directory = File.realpath(options.fetch(:artifact_dir))
      unless File.stat(@directory).mode & 0o777 == 0o700 && Dir.empty?(@directory)
        raise Invalid, 'fixture artifact directory must be private and empty'
      end
      raise Invalid, 'fixture requires the exact bound session' unless command!('dev-session', 'current').strip == @slug

      @key = SecureRandom.hex(8)
      @request = { 'key' => @key, 'os_template_id' => options.fetch(:os_template_id) }
      @summary = { 'passed' => 0, 'stage' => 0, 'cross_node' => 0, 'same_node' => 0,
                   'automatic_cycle' => 0, 'scheduler_stopped' => 0 }
    end

    def run
      Timeout.timeout(MAX_SECONDS) do
        unless remote!('services', 'systemctl is-active vpsadmin-scheduler.service').strip == 'active'
          raise Invalid, 'scheduler must be running before fixture acceptance'
        end

        remote!('services', 'systemctl stop vpsadmin-scheduler.service')
        @summary['scheduler_stopped'] = 1
        @summary['stage'] = 1
        prepared = api!('prepare')
        @request.merge!(prepared.fetch('identity'))
        save!('identity.json', @request)
        baseline = api!('baseline')
        save!('baseline.json', baseline)
        %w[vps nas].each do |kind|
          @request['kind'] = kind
          @request['source_id'] = prepared.fetch(kind).fetch('source_id')
          @info = api!('info')
          raise Invalid, 'controlled fixture evidence is pending' unless @info.fetch('settled')
          unless @info.fetch('snapshots').fetch(@info.fetch('destination_id').to_s).empty?
            raise Invalid, 'fixture destination already contains snapshots'
          end

          @summary['stage'] = 2
          write_payload!('A')
          first = api!('snapshot')
          full = api!('transfer')
          unless full.fetch('send_snapshots') == [[first.fetch('snapshot_id')]]
            raise Invalid, 'fixture first send does not include S1'
          end

          verify_snapshot!(first, 'A')
          @summary['stage'] = 3
          write_payload!('B')
          second = api!('snapshot')
          incremental = api!('transfer')
          unless incremental.values_at('tree_id', 'branch_id') == full.values_at('tree_id', 'branch_id') &&
                 incremental.fetch('send_snapshots') == [[first.fetch('snapshot_id'), second.fetch('snapshot_id')]]
            raise Invalid, 'fixture incremental send changed head or common base'
          end

          verify_snapshot!(first, 'A')
          verify_snapshot!(second, 'B')
          # Manual normal Backup rotates only this new fixture's retention.
          6.times do
            api!('snapshot')
            @info = api!('backup')
          end
          verify_snapshot!(@info.fetch('snapshots').fetch(@info.fetch('source_id').to_s).last, 'B')
          source_rows = @info.fetch('snapshots').fetch(@info.fetch('source_id').to_s)
          backup_rows = @info.fetch('snapshots').fetch(@info.fetch('destination_id').to_s)
          unless source_rows.size.between?(2, 3) && backup_rows.size.between?(2, 5) &&
                 backup_rows.map { |row| row.fetch('id') }.include?(source_rows.last.fetch('id'))
            raise Invalid, 'fixture rotation lacks bounded history and latest common base'
          end

          different = @info.fetch('source_node') != @info.fetch('destination_node')
          raise Invalid, 'fixture does not exercise expected topology' unless different == (kind == 'vps')

          @summary[kind == 'vps' ? 'cross_node' : 'same_node'] = 1
          save!("#{kind}-proof.json", { 'first' => first, 'second' => second, 'full' => full, 'incremental' => incremental, 'rotated' => @info })
        end
        @summary['stage'] = 4
        command!('vpsadmin-devcluster', 'storage-profile', @slug, 'provision')
        @summary['scheduler_stopped'] = 0
        raise Invalid, 'repeat provision changed existing allocations' unless api!('baseline') == baseline

        remote!('services', 'schedulerctl update')
        tasks = api!('tasks')
        loaded = remote!('services', 'schedulerctl get-tasks')
        tasks.each do |task|
          unless loaded.include?("Task #{task.fetch('id')}\n")
            raise Invalid, 'profile task is absent from the actual scheduler'
          end
        end
        unless loaded.include?('minute = 0,5,10,15,20,25,30,35,40,45,50,55') && loaded.include?('minute = 2,12,22,32,42,52')
          raise Invalid, 'actual scheduler lacks profile interval expansions'
        end

        save!('scheduler-before.txt', loaded)
        before = %w[vps nas].to_h do |kind|
          @request.merge!('kind' => kind, 'source_id' => prepared.fetch(kind).fetch('source_id'))
          [kind, api!('info')]
        end
        automatic_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
        observed = {}
        loop do
          sleep 10
          %w[vps nas].each do |kind|
            @request.merge!('kind' => kind, 'source_id' => prepared.fetch(kind).fetch('source_id'))
            current = api!('info')
            next unless current.fetch('settled')

            source_ids = current.fetch('snapshots').fetch(current.fetch('source_id').to_s).map { |row| row.fetch('id') }
            destination_ids = current.fetch('snapshots').fetch(current.fetch('destination_id').to_s).map { |row| row.fetch('id') }
            old = before.fetch(kind)
            old_ids = old.fetch('snapshots').fetch(old.fetch('destination_id').to_s).map { |row| row.fetch('id') }
            observed[kind] = current if (source_ids & destination_ids).any? { |id| !old_ids.include?(id) }
          end
          if observed.size == 2
            @summary['automatic_cycle'] = 1
            break
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= automatic_deadline
            raise Invalid, 'automatic fixture backup cycle deadline exceeded'
          end
        end
        remote!('services', 'systemctl stop vpsadmin-scheduler.service')
        @summary['scheduler_stopped'] = 1
        observed.each do |kind, info|
          @request.merge!('kind' => kind, 'source_id' => prepared.fetch(kind).fetch('source_id'))
          @info = info
          verify_snapshot!(info.fetch('snapshots').fetch(info.fetch('destination_id').to_s).last, 'B')
        end
        @summary['stage'] = 5
        remote!('services', 'systemctl stop vpsadmin-scheduler.service')
        command!('vpsadmin-devcluster', 'update', @slug, 'services')
        raise Invalid, 'repeat preserving services seed changed allocations' unless api!('baseline') == baseline

        command!('vpsadmin-devcluster', 'storage-profile', @slug, 'provision')
        @summary['scheduler_stopped'] = 0
        raise Invalid, 'repeat provision changed task identities' unless api!('tasks') == tasks
        unless remote!('services', 'systemctl is-active vpsadmin-scheduler.service').strip == 'active'
          raise Invalid, 'scheduler did not resume after successful provision'
        end

        @summary['passed'] = 1
      end
    rescue StandardError => error
      save!('failure.json', { 'class' => error.class.name, 'message' => error.message })
      # Keep admitted work and scheduler state for diagnosis, never destroy the
      # fixture or toggle the storage freeze to manufacture a successful retry.
      @summary['recovery_required'] = 1
    ensure
      save!('summary.json', @summary)
      puts JSON.generate(@summary)
    end

    private

    def command!(*argv)
      stdout, stderr, status = nil
      Open3.popen3(*argv, pgroup: true) do |input, output, error, child|
        input.close
        errors = Thread.new { error.read }
        begin
          Timeout.timeout(600) do
            stdout = output.read
            stderr = errors.value
            status = child.value
          end
        ensure
          begin
            Process.kill('KILL', -child.pid)
          rescue Errno::ESRCH
            nil
          end
          child.join
          errors.join
        end
      end
      File.open(File.join(@directory, 'commands.log'), 'a', 0o600) { |file| file.write(stderr) }
      raise Invalid, 'fixture command failed; inspect private diagnostics' unless status.success?

      stdout
    end

    def remote!(machine, command)
      raise Invalid, 'invalid fixture machine name' unless machine.match?(/\A(?:services|node[12]|storage1)\z/)

      command!('vpsadmin-devcluster', 'ssh', @slug, machine, '--', command)
    end

    def api!(operation, extra = {})
      request = @request.merge('operation' => operation).merge(extra)
      bytes = JSON.generate(request)
      raise Invalid, 'fixture request exceeds bound' if bytes.bytesize > 8192

      response = remote!('services', "vpsadmin-storage-profile-acceptance #{Shellwords.escape(Base64.strict_encode64(bytes))}")
      raise Invalid, 'fixture response exceeds bound' if response.bytesize > 262_144

      JSON.parse(response)
    end

    def save!(name, value)
      bytes = value.is_a?(String) ? value : JSON.pretty_generate(value)
      File.write(File.join(@directory, name), bytes, mode: 'w', perm: 0o600)
    end

    def write_payload!(version)
      files = PAYLOADS.fetch(version)
      body = 'set -eu; mkdir -p /storage-profile-fixture; rm -f /storage-profile-fixture/keep /storage-profile-fixture/remove /storage-profile-fixture/added; '
      files.each { |name, content| body += "printf %s #{Shellwords.escape(content)} > /storage-profile-fixture/#{name}; " }
      if @request.fetch('kind') == 'vps'
        remote!(@info.fetch('source_node'), Shellwords.join(['osctl', 'ct', 'exec', @request.fetch('vps_id').to_s, 'sh', '-c', body]))
      else
        fs = Shellwords.escape(@info.fetch('source_fs'))
        mounted = "test \"$(zfs get -H -o value mounted #{fs})\" = yes; root=$(zfs get -H -o value mountpoint #{fs}); test \"$root\" != none; "
        payload = body.gsub('/storage-profile-fixture', '"$root"/private/storage-profile-fixture')
        remote!(@info.fetch('source_node'), "#{mounted}test -d \"$root\"/private; #{payload}")
      end
    end

    def verify_snapshot!(snapshot, version)
      %w[source destination].each do |copy|
        view = api!('view', 'copy' => copy, 'snapshot_id' => snapshot.fetch('id', snapshot['snapshot_id']))
        begin
          fs = Shellwords.escape(view.fetch('filesystem'))
          mount = "set -eu; test \"$(zfs get -H -o value readonly #{fs})\" = on; " \
                  "test \"$(zfs get -H -o value mounted #{fs})\" = yes; " \
                  "root=$(zfs get -H -o value mountpoint #{fs}); test \"$root\" != none; test -d \"$root\"/private; "
          PAYLOADS.fetch(version).each do |name, contents|
            digest = Digest::SHA256.hexdigest(contents)
            output = remote!(view.fetch('node'), mount + "sha256sum \"$root\"/private/storage-profile-fixture/#{name}")
            raise Invalid, 'fixture historical payload checksum mismatch' unless output.split.first == digest
          end
          absent = version == 'A' ? 'added' : 'remove'
          remote!(view.fetch('node'), mount + "test ! -e \"$root\"/private/storage-profile-fixture/#{absent}")
        ensure
          api!('free-view', 'clone_id' => view.fetch('clone_id'), 'snapshot_id' => snapshot.fetch('id', snapshot['snapshot_id']))
        end
      end
    end
  end
end

if ENV['STORAGE_PROFILE_ACCEPTANCE_MODE'] == 'guest'
  request = JSON.parse(Base64.strict_decode64(ENV.fetch('STORAGE_PROFILE_ACCEPTANCE_REQUEST')))
  actor = User.find_by!(login: 'test-admin')
  unless actor.level == 99 && actor.object_state == 'active'
    raise StorageProfileAcceptance::Invalid, 'fixture requires its active administrator'
  end

  previous = User.current
  begin
    User.current = actor
    response = StorageProfileAcceptance::Guest.execute(request)
    File.write(ENV.fetch('STORAGE_PROFILE_ACCEPTANCE_REPORT'), JSON.generate(response), mode: 'w', perm: 0o600)
  ensure
    User.current = previous
  end
elsif $PROGRAM_NAME == __FILE__
  options = { os_template_id: 1 }
  OptionParser.new do |parser|
    parser.on('--slug SLUG') { |value| options[:slug] = value }
    parser.on('--artifact-dir NEW_DIRECTORY') { |value| options[:artifact_dir] = value }
    parser.on('--os-template-id ID', Integer) { |value| options[:os_template_id] = value }
  end.parse!
  raise ArgumentError, 'fixture requires bound slug, new artifact directory and positive template ID' unless
    ARGV.empty? && options.keys.sort == %i[artifact_dir os_template_id slug] && options.fetch(:os_template_id).positive?

  File.umask(0o077)
  FileUtils.mkdir(options.fetch(:artifact_dir), mode: 0o700)
  fixture = StorageProfileAcceptance::Host.new(options)
  fixture.run
  exit(fixture.summary.fetch('passed') == 1 ? 0 : 1)
end
