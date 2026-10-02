# frozen_string_literal: true

require 'json'

# Loaded by the database package's normal db:seed:file task. The configured
# API overlay supplies exactly the same helper, pools and plan as API hooks.
profile = DevClusters::VpsAdminStorageProfile.instance
operation = ENV.fetch('STORAGE_PROFILE_OPERATION')
report_path = ENV.fetch('STORAGE_PROFILE_REPORT')
raise 'Invalid storage profile operation' unless %w[inspect provision retire].include?(operation)

module DevStorageProfileProvision
  MAX_SECONDS = 1800

  module_function

  def check_deadline!
    return unless @deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline

    raise 'Storage profile aggregate deadline exceeded; inspect admitted work before retry'
  end

  def wait_for_chain!(chain, timeout: 300)
    return unless chain

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      check_deadline!
      chain.reload
      if chain.state == 'done'
        ids = chain.transactions.select(:id)
        if TransactionConfirmation.where(transaction_id: ids, done: 0).exists?
          raise 'Completed profile chain retains confirmations'
        end
        raise 'Completed profile chain retains locks' if ResourceLock.where(locked_by: chain).exists?

        return
      end
      if %w[failed fatal resolved].include?(chain.state)
        raise 'Storage profile chain failed; inspect its retained evidence'
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise 'Storage profile chain deadline exceeded; inspect admitted work before retry'
      end

      sleep 1
    end
  end

  def pool_rows(profile)
    selections = profile.config.fetch('sourcePools') + [profile.config.fetch('backupPool'), profile.config.fetch('nasPool')]
    selections.map do |selection|
      pools = Pool.where(node_id: selection.fetch('nodeId'), filesystem: selection.fetch('filesystem')).limit(2).to_a
      raise 'Configured storage pool is ambiguous' if pools.size > 1
      if pools.empty? && selection.fetch('role') == 'hypervisor'
        raise 'Existing source pool is absent; provisioning does not fabricate it'
      end

      pool = pools.first
      if pool && (pool.role != selection.fetch('role') || pool.is_open != 1 || pool.get_current_lock)
        raise 'Configured storage pool conflicts with catalog or admitted work'
      end

      node = Node.find(selection.fetch('nodeId'))
      unless node.location.environment_id == profile.config.fetch('environmentId') &&
             ((selection.fetch('role') == 'hypervisor' && node.role == 'node') ||
              (selection.fetch('role') != 'hypervisor' && node.role == 'storage'))
        raise 'Configured storage pool has a conflicting node/environment'
      end

      { 'node_id' => node.id, 'filesystem' => selection.fetch('filesystem'), 'present' => !pool.nil? }
    end
  end

  def inspect(profile)
    { 'version' => 1, 'enrollment' => profile.enrollment?, 'pools' => pool_rows(profile) }
  end

  def provision!(profile)
    profile.require_enrollment!
    @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_SECONDS
    StorageFreezeControl.transaction(requires_new: true) do
      StorageMutationAdmission.check!
    end
    pool_rows(profile)
    [profile.config.fetch('backupPool'), profile.config.fetch('nasPool')].each do |selection|
      check_deadline!
      next if Pool.exists?(node_id: selection.fetch('nodeId'), filesystem: selection.fetch('filesystem'))

      pool = Pool.new(node_id: selection.fetch('nodeId'), filesystem: selection.fetch('filesystem'),
                      label: selection.fetch('role') == 'backup' ? 'Development backups' : 'Member NAS',
                      role: selection.fetch('role'), is_open: 1, max_datasets: selection.fetch('maxDatasets'),
                      refquota_check: false)
      chain, = TransactionChains::Pool::Create.fire(pool, {})
      wait_for_chain!(chain)
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
    loop do
      check_deadline!
      begin
        (profile.config.fetch('sourcePools') + [profile.config.fetch('backupPool'), profile.config.fetch('nasPool')]).each do |selection|
          profile.pool!(selection)
        end
        break
      rescue DevClusters::VpsAdminStorageProfile::Invalid
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise 'Storage profile pools lack fresh capacity/readiness evidence'
        end

        sleep 1
      end
    end
    # This transaction completes before any member chain can enroll.
    profile.bootstrap_templates!
    users = User.joins(:environment_user_configs).where(level: 1, object_state: :active,
                                                        environment_user_configs: { environment_id: profile.config.fetch('environmentId') })
                .distinct.order(:id).limit(257).to_a
    raise 'Storage profile member catch-up exceeds its bound' if users.size > 256

    users.each do |user|
      check_deadline!
      chain, = profile.catch_up_chain.fire(profile, user: user)
      wait_for_chain!(chain)
    end
    pool_ids = profile.source_pool_configs.map { |selection| profile.pool!(selection).id }
    sources = DatasetInPool.joins(:dataset).where(pool_id: pool_ids, confirmed: DatasetInPool.confirmed(:confirmed),
                                                  datasets: { confirmed: Dataset.confirmed(:confirmed) })
                           .order(:id).limit(257).to_a
    raise 'Storage profile source catch-up exceeds its bound' if sources.size > 256

    sources.each do |source|
      check_deadline!
      chain, = profile.catch_up_chain.fire(profile, source_dip: source)
      wait_for_chain!(chain)
    end
    { 'version' => 1, 'members' => users.size, 'sources' => sources.size, 'provisioned' => true }
  end
end

actor = User.find_by!(login: 'test-admin')
raise 'Storage profile requires its active administrator' unless actor.level == 99 && actor.object_state == 'active'

previous_actor = User.current
begin
  User.current = actor
  result = case operation
           when 'inspect'
             DevStorageProfileProvision.inspect(profile)
           when 'provision'
             DevStorageProfileProvision.provision!(profile)
           when 'retire'
             profile.retire!
             { 'version' => 1, 'retired' => true }
           end
  File.open(report_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(result)) }
ensure
  User.current = previous_actor
end
