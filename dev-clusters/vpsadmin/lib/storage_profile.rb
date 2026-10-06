# frozen_string_literal: true

require 'json'

module DevClusters
  # Provider policy; all physical work uses existing API transaction chains.
  class VpsAdminStorageProfile
    Invalid = Class.new(StandardError)
    PLAN_NAME = :dev_short_backup
    SNAPSHOT_SCHEDULE = ['*/5', '*', '*', '*', '*'].freeze
    BACKUP_SCHEDULE = ['2-59/10', '*', '*', '*', '*'].freeze
    RESOURCE_DEFAULTS = { 'cpu' => 4, 'memory' => 4096, 'swap' => 2048,
                          'diskspace' => 8192, 'ipv4' => 4, 'ipv4_private' => 16 }.freeze
    PRESERVING_SEED = { 'version' => 1, 'existingAssignments' => 'preserve' }.freeze

    attr_reader :config

    def initialize(config)
      @config = config
      validate_config!
    end

    def self.configure(config)
      @instance ||= new(config)
      raise Invalid, 'Storage profile was loaded with different configuration' unless @instance.config == config

      # Normal overlay configuration runs after Admin loads its models. Readers
      # need this persisted STI type even when enrollment is retired.
      load_catch_up_chain!
      @instance
    end

    def self.instance
      @instance || raise(Invalid, 'Storage profile is not configured')
    end

    def validate_config!
      fields = %w[version enrollment environmentId sourcePools backupPool nasPool resources packageVersion namespaceBlocks]
      fields += %w[vpsBackupPool] if config.is_a?(Hash) && config['version'] == 2
      unless config.is_a?(Hash) && config['version'].is_a?(Integer) && [1, 2].include?(config['version']) &&
             config.keys.sort == fields.sort
        raise Invalid, 'Invalid storage profile configuration'
      end

      raise Invalid, 'Storage profile enrollment must be a boolean' unless [true, false].include?(config['enrollment'])

      positive_integer!(config.fetch('environmentId'))
      positive_integer!(config.fetch('packageVersion'))
      positive_integer!(config.fetch('namespaceBlocks'), maximum: 32)
      sources = config.fetch('sourcePools')
      unless sources.is_a?(Array) && sources.size.between?(1, 8) && sources.uniq.size == sources.size
        raise Invalid, 'Storage profile requires distinct source pools'
      end

      sources.each { |pool| validate_pool_config!(pool, role: 'hypervisor') }
      validate_pool_config!(config.fetch('backupPool'), role: 'backup')
      validate_pool_config!(config.fetch('nasPool'), role: 'primary')
      backup = config.fetch('backupPool')
      nas = config.fetch('nasPool')
      unless backup.fetch('nodeId') == nas.fetch('nodeId') && backup.fetch('filesystem') != nas.fetch('filesystem')
        raise Invalid, 'NAS and backup roots must be distinct on the configured storage node'
      end

      all = sources + [backup, nas]
      if config.fetch('version') == 2
        vps = config.fetch('vpsBackupPool')
        validate_pool_config!(vps, role: 'backup')
        raise Invalid, 'VPS backup must use the configured storage node' unless vps.fetch('nodeId') == backup.fetch('nodeId')

        all << vps
      end
      unless all.map { |pool| [pool.fetch('nodeId'), pool.fetch('filesystem')] }.uniq.size == all.size
        raise Invalid, 'Storage profile pool selections overlap'
      end

      resources = config.fetch('resources')
      unless resources.is_a?(Hash) && resources.keys.sort == RESOURCE_DEFAULTS.keys.sort
        raise Invalid, 'Invalid future-user resource policy'
      end

      resources.each_value { |value| positive_integer!(value, maximum: 1_048_576) }
    end

    # Called by the real repeatable seed before API/Node services are available.
    # Missing namespace/map state is completed later by an outer allocator chain.
    def preserve_namespace!(user)
      namespaces = ::UserNamespace.where(user: user).limit(2).to_a
      raise Invalid, 'User namespace is ambiguous' if namespaces.size > 1
      return :missing if namespaces.empty?

      namespace = namespaces.first
      blocks = namespace.user_namespace_blocks.order(:index).to_a
      unless blocks.size == namespace.block_count && blocks.any? &&
             blocks.map(&:index) == (blocks.first.index..blocks.last.index).to_a &&
             namespace.offset == blocks.first.offset && namespace.size == blocks.sum(&:size)
        raise Invalid, 'Existing user namespace allocation is inconsistent'
      end

      maps = namespace.user_namespace_maps.where(label: 'Default map').limit(2).to_a
      raise Invalid, 'Default namespace map is ambiguous' if maps.size > 1
      return :missing_map if maps.empty?

      entries = maps.first.user_namespace_map_entries.to_a
      unless entries.any? && entries.map(&:kind).uniq.sort == %w[gid uid] &&
             entries.all?(&:valid?)
        raise Invalid, 'Existing default namespace map is inconsistent'
      end

      :preserved
    end

    def preserve_seed_resources!(admin, environment, user, values)
      ::User.transaction do
        user.lock!
        packages = ::ClusterResourcePackage.where(user: user, environment: environment).limit(2).to_a
        raise Invalid, 'Personal resource package is ambiguous' if packages.size > 1

        links = ::UserClusterResourcePackage.where(user: user, environment: environment).to_a
        resources = ::ClusterResource.all.to_a
        existing = ::UserClusterResource.where(user: user, environment: environment).to_a
        if packages.empty?
          unless links.empty? && existing.empty?
            raise Invalid, 'Missing personal package has existing resource assignments'
          end

          package = ::ClusterResourcePackage.new(user: user, environment: environment, label: 'Dev personal package')
          package.save!
          resources.each do |resource|
            ::ClusterResourcePackageItem.create!(cluster_resource_package: package, cluster_resource: resource,
                                                 value: values.fetch(resource.name, 0))
            ::UserClusterResource.create!(user: user, environment: environment, cluster_resource: resource, value: 0)
          end
          previous_actor = ::User.current
          begin
            ::User.current = admin
            package.assign_to(environment, user, comment: 'Development seed')
          ensure
            ::User.current = previous_actor
          end
          return :created
        end

        package = packages.first
        unless package.cluster_resource_package_items.pluck(:cluster_resource_id).sort == resources.map(&:id).sort
          raise Invalid, 'Existing personal package has incomplete resource policy'
        end
        unless links.count { |link| link.cluster_resource_package_id == package.id } == 1 &&
               links.map(&:cluster_resource_package_id).uniq.size == links.size
          raise Invalid, 'Existing personal package assignment is inconsistent'
        end

        expected = Hash.new(0)
        links.each do |link|
          items = link.cluster_resource_package.cluster_resource_package_items.to_a
          if items.map(&:cluster_resource_id).uniq.size != items.size
            raise Invalid, 'Existing resource package items are ambiguous'
          end

          items.each { |item| expected[item.cluster_resource_id] += item.value }
        end
        unless existing.map(&:cluster_resource_id).uniq.size == existing.size
          raise Invalid, 'Existing user resources are ambiguous'
        end

        existing.each do |resource|
          unless resource.value == expected[resource.cluster_resource_id]
            raise Invalid, 'Existing user resources disagree with assigned packages'
          end
        end
        resources.each do |resource|
          next if existing.any? { |row| row.cluster_resource_id == resource.id }

          ::UserClusterResource.create!(user: user, environment: environment, cluster_resource: resource,
                                        value: expected[resource.id])
        end
        :preserved
      end
    end

    def bootstrap_defaults!
      ::Environment.transaction(requires_new: true) do
        # Static future-user configuration must also boot under retained freeze.
        # Physical work and plan enrollment use their own admission boundary.
        environment = ::Environment.lock.find(config.fetch('environmentId'))
        next remove_owned_default!(environment) unless enrollment?

        environment.update!(can_create_vps: true, can_destroy_vps: true, max_vps_count: 2)
        label = "Dev storage profile resources v#{config.fetch('packageVersion')}"
        packages = ::ClusterResourcePackage.where(label: label).limit(2).to_a
        raise Invalid, 'Storage profile resource package is ambiguous' if packages.size > 1

        package = packages.first
        if package
          raise Invalid, 'Storage profile package must be shared' if package.user_id || package.environment_id

          values = package.cluster_resource_package_items.joins(:cluster_resource)
                          .pluck('cluster_resources.name', :value)
          unless values.size == config.fetch('resources').size && values.to_h == config.fetch('resources')
            raise Invalid, 'Assigned storage profile package policy cannot change'
          end
        else
          package = ::ClusterResourcePackage.new(label: label)
          package.save!
          config.fetch('resources').each do |name, value|
            ::ClusterResourcePackageItem.create!(cluster_resource_package: package,
                                                 cluster_resource: ::ClusterResource.find_by!(name: name), value: value)
          end
        end
        defaults = ::DefaultUserClusterResourcePackage.where(environment: environment).lock.to_a
        unless defaults.empty? || (defaults.one? && defaults.first.cluster_resource_package_id == package.id)
          raise Invalid, 'Environment has conflicting default resource packages'
        end

        if defaults.empty?
          ::DefaultUserClusterResourcePackage.create!(environment: environment, cluster_resource_package: package)
        end
        package
      end
    end

    def install_plan!
      profile = self
      ::VpsAdmin::API::DatasetPlans::Registrator.plan(
        PLAN_NAME, label: 'Development short backup', keep_empty_group_snapshots: true
      ) do |dip|
        profile.require_enrollment! if %i[add verify].include?(direction)
        profile.validate_registration!(dip, check_backup_path: %i[add verify].include?(direction))
        group_snapshot dip, *SNAPSHOT_SCHEDULE
        backup dip, *BACKUP_SCHEDULE
      end
    end

    def plan
      ::VpsAdmin::API::DatasetPlans.plans.fetch(PLAN_NAME)
    end

    # Post-readiness only: Pool::Create must have completed before this commit.
    def bootstrap_templates!
      require_enrollment!
      plan.with_configuration_lock do |record|
        pools = source_pool_configs.map { |selection| pool!(selection) }
        environments = ::EnvironmentDatasetPlan.where(dataset_plan: record).lock.to_a
        unless environments.empty? || (environments.one? && environments.first.environment_id == config.fetch('environmentId'))
          raise Invalid, 'Storage profile environment plan is ambiguous'
        end

        if environments.empty?
          ::EnvironmentDatasetPlan.create!(dataset_plan: record, environment_id: config.fetch('environmentId'),
                                           user_add: true, user_remove: true)
        elsif !environments.first.user_add || !environments.first.user_remove
          raise Invalid, 'Storage profile environment plan has conflicting permissions'
        end
        pools.each do |pool|
          actions = ::DatasetAction.where(dataset_plan: record, pool: pool, action: :group_snapshot).lock.limit(2).to_a
          raise Invalid, 'Shared snapshot template is ambiguous' if actions.size > 1

          action = actions.first
          if action
            if action.src_dataset_in_pool_id || action.dst_dataset_in_pool_id || action.dataset_in_pool_plan_id
              raise Invalid, 'Shared snapshot template has source-specific ownership'
            end

            validate_task!(action, SNAPSHOT_SCHEDULE)
          else
            action = ::DatasetAction.create!(dataset_plan: record, pool: pool, action: :group_snapshot)
            ::RepeatableTask.create!(class_name: 'DatasetAction', table_name: 'dataset_actions', row_id: action.id,
                                     **schedule_attributes(SNAPSHOT_SCHEDULE))
          end
        end
      end
    end

    def validate_registration!(source, check_backup_path: true, confirmed_only: false)
      _, copy = select_backup!(source, existing_only: true, registration: true,
                               check_backup_path: check_backup_path, confirmed_only: confirmed_only)
      copy
    end

    def ensure_backup_and_plan!(chain:, source_dip:)
      require_enrollment!
      ::StorageMutationAdmission.check!
      chain.lock(source_dip.dataset)
      chain.lock(source_dip)
      destination, backup = select_backup!(source_dip, chain: chain)
      unless backup
        if destination.dataset_in_pools.count >= destination.max_datasets
          raise Invalid, 'Configured backup pool has no dataset capacity'
        end

        backup = ::DatasetInPool.create!(dataset: source_dip.dataset, pool: destination, label: 'backup',
                                         confirmed: ::DatasetInPool.confirmed(:confirm_create),
                                         min_snapshots: 2, max_snapshots: 5, snapshot_max_age: 3600)
        chain.lock(backup)
        chain.append_t(::Transactions::Storage::CreateDataset, args: backup) { |confirmation| confirmation.create(backup) }
      else
        chain.lock(backup)
      end
      if owned_create?(chain, source_dip.dataset)
        source_dip.update!(min_snapshots: 2, max_snapshots: 3, snapshot_max_age: 1800)
      end
      chain.append_t(::Transactions::Utils::NoOp, args: source_dip.pool.node_id) do |confirmation|
        plan.register(source_dip, confirmation: confirmation)
      end
      backup
    end

    def ensure_namespace!(chain:, user:)
      require_enrollment!
      state = preserve_namespace!(user)
      namespace = if state == :missing
                    chain.use_chain(::TransactionChains::UserNamespace::Allocate,
                                    args: [user, config.fetch('namespaceBlocks')])
                  else
                    ::UserNamespace.find_by!(user: user)
                  end
      chain.lock(namespace)
      maps = namespace.user_namespace_maps.where(label: 'Default map').limit(2).to_a
      if maps.one?
        chain.lock(maps.first)
        return maps.first
      end

      map = ::UserNamespaceMap.create_chained!(namespace, 'Default map')
      chain.lock(map)
      entries = ::UserNamespaceMapEntry.kinds.each_value.map do |kind|
        ::UserNamespaceMapEntry.create!(user_namespace_map: map, kind: kind, vps_id: 0, ns_id: 0, count: namespace.size)
      end
      chain.append_t(::Transactions::Utils::NoOp, args: chain.find_node_id) do |confirmation|
        confirmation.just_create(map)
        entries.each { |entry| confirmation.just_create(entry) }
      end
      map
    end

    def ensure_nas!(chain:, user:)
      require_enrollment!
      unless user.level == 1 && user.object_state == 'active'
        raise Invalid, 'Storage profile NAS requires an active ordinary member'
      end

      ::StorageMutationAdmission.check!
      chain.lock(user)
      map = ensure_namespace!(chain: chain, user: user)
      nas = pool!(config.fetch('nasPool'))
      names = [user.id.to_s, "nas-#{user.id}"]
      nas_datasets = ::DatasetInPool.where(pool: nas).select(:dataset_id)
      candidates = ::Dataset.roots.where(name: names)
      # Include owned NAS roots with unexpected names and foreign owners of
      # either accepted NAS path; neither permits creating a second root.
      roots = ::Dataset.roots.where(user: user, vps_id: nil, id: nas_datasets)
                       .or(candidates.where(user: user, vps_id: nil))
                       .or(candidates.where(id: nas_datasets)).lock.limit(2).to_a
      raise Invalid, 'Member NAS root is ambiguous' if roots.size > 1

      if roots.one?
        root = roots.first
        copies = root.dataset_in_pools.where(pool: nas).lock.limit(2).to_a
        unless root.user_id == user.id && root.vps_id.nil? && names.include?(root.name) &&
               root.full_name == root.name && root.confirmed? && root.user_editable && root.user_create && !root.user_destroy &&
               copies.one? && copies.first.confirmed? && copies.first.label == 'nas' && copies.first.effective_quota == 1024
          raise Invalid, 'Existing NAS root is incompatible or pending'
        end

        ensure_backup_and_plan!(chain: chain, source_dip: copies.first)
        return copies.first
      end
      raise Invalid, 'Configured NAS pool has no dataset capacity' if nas.dataset_in_pools.count >= nas.max_datasets

      root = ::Dataset.new(name: "nas-#{user.id}", user: user, user_editable: true,
                           user_create: true, user_destroy: false, confirmed: ::Dataset.confirmed(:confirm_create))
      chain.use_chain(::TransactionChains::Dataset::Create,
                      args: [nas, nil, [root], { user: user, label: 'nas', automount: false,
                                                 userns_map: map, properties: { quota: 1024 } }]).last
    end

    def install_hooks!
      return if @hooks_installed

      profile = self
      ::DatasetInPool.connect_hook(:create) do |ret, dip, purpose: nil, preserve_existing_backups: false, **|
        next ret unless profile.enrollment?
        next ret if dip.pool.backup?
        next ret if purpose == :vps_replace && preserve_existing_backups

        profile.ensure_backup_and_plan!(chain: self, source_dip: dip)
        ret
      end
      ::DatasetInPool.connect_hook(:migrated) do |ret, _from, to|
        next ret unless profile.enrollment?

        profile.ensure_backup_and_plan!(chain: self, source_dip: to)
        ret
      end
      ::User.connect_hook(:create) do |ret, user|
        next ret unless profile.enrollment?
        next ret unless user.level == 1 && user.object_state == 'active'

        profile.ensure_nas!(chain: self, user: user)
        ret
      end
      @hooks_installed = true
    end

    def self.load_catch_up_chain!
      return const_get(:CatchUp, false) if const_defined?(:CatchUp, false)

      const_set(:CatchUp, Class.new(::TransactionChain) do
        label 'Provision development storage profile'
        allow_empty

        def link_chain(profile, user: nil, source_dip: nil, source_dips: nil)
          profile.require_enrollment!
          ::StorageMutationAdmission.check!
          return profile.ensure_nas!(chain: self, user: user) if user

          sources = source_dips || [source_dip]
          unless sources.size.between?(1, 32) && sources.none?(&:nil?)
            raise Invalid, 'Storage profile catch-up requires bounded source members'
          end

          copies = sources.map { |source| profile.ensure_backup_and_plan!(chain: self, source_dip: source) }
          source_dips ? copies : copies.first
        end
      end)
    end

    def catch_up_chain
      self.class.load_catch_up_chain!
    end

    def pool!(selection)
      pools = ::Pool.where(node_id: selection.fetch('nodeId'), filesystem: selection.fetch('filesystem')).limit(2).to_a
      raise Invalid, 'Configured storage pool is missing or ambiguous' unless pools.one?

      pool = pools.first
      unless pool.role == selection.fetch('role') && pool.is_open == 1 && pool.max_datasets.positive? &&
             pool.node.location.environment_id == config.fetch('environmentId') && pool.maintenance_lock.zero? &&
             pool.state_online? && pool.allocation_metrics_fresh? && pool.available_space.to_i >= 1024 &&
             (!selection.key?('maxDatasets') || pool.max_datasets == selection.fetch('maxDatasets'))
        raise Invalid, 'Configured storage pool is closed, unavailable or lacks fresh capacity evidence'
      end
      raise Invalid, 'Configured storage pool is locked' if pool.get_current_lock

      pool
    end

    def source_pool_configs
      config.fetch('sourcePools') + [config.fetch('nasPool')]
    end

    # One enumeration owns inspect, physical preflight, creation and readiness.
    def pool_configs
      config.fetch('sourcePools') + [config.fetch('backupPool'), config.fetch('nasPool')] +
        (config.fetch('version') == 2 ? [config.fetch('vpsBackupPool')] : [])
    end

    def backup_placement
      %w[backupPool vpsBackupPool].zip(%w[legacy vps]).to_h do |field, name|
        selection = config.fetch(field)
        [name, { 'node_id' => selection.fetch('nodeId'), 'filesystem' => selection.fetch('filesystem') }]
      end
    end

    def enrollment?
      config.fetch('enrollment')
    end

    def require_enrollment!
      raise Invalid, 'Storage profile enrollment is disabled' unless enrollment?
    end

    def retire!
      raise Invalid, 'Storage profile retirement requires enrollment disabled' if enrollment?

      plan.with_configuration_lock do |record|
        environments = record.environment_dataset_plans.lock.limit(2).to_a
        unless environments.empty? || (environments.one? && environments.first.environment_id == config.fetch('environmentId'))
          raise Invalid, 'Storage profile environment plan is ambiguous'
        end

        memberships = ::DatasetInPoolPlan.joins(:environment_dataset_plan)
                                         .where(environment_dataset_plans: { dataset_plan_id: record.id }).order(:id).limit(257).to_a
        raise Invalid, 'Storage profile retirement exceeds its membership bound' if memberships.size > 256

        memberships.each { |membership| plan.unregister(membership.dataset_in_pool) }
        actions = ::DatasetAction.where(dataset_plan: record).lock.to_a
        plan.check_pending_confirmations!(actions)
        owned_pool_ids = source_pool_configs.map do |selection|
          pools = ::Pool.joins(node: :location).where(
            node_id: selection.fetch('nodeId'), filesystem: selection.fetch('filesystem'), role: selection.fetch('role'),
            locations: { environment_id: config.fetch('environmentId') }
          ).limit(2).to_a
          raise Invalid, 'Storage profile template pool is missing or ambiguous' unless pools.one?

          pools.first.id
        end
        actions.each do |action|
          unless owned_pool_ids.include?(action.pool_id)
            raise Invalid, 'Storage profile template is outside configured pools'
          end

          unless action.group_snapshot? && action.src_dataset_in_pool_id.nil? && action.dst_dataset_in_pool_id.nil? &&
                 action.dataset_in_pool_plan_id.nil?
            raise Invalid, 'Storage profile has unexplained action ownership'
          end
          raise Invalid, 'Snapshot template still has members' if action.group_snapshots.exists?

          validate_task!(action, SNAPSHOT_SCHEDULE).destroy!
          action.destroy!
        end
        record.environment_dataset_plans.destroy_all
        remove_owned_default!(::Environment.lock.find(config.fetch('environmentId')))
      end
    end

    private

    # Pool identity, never a Dataset/VPS ID, determines placement. Existing
    # copies are resolved first so reuse does not depend on an unused default.
    def placement_for(source)
      selection = source_pool_configs.find do |pool|
        pool.fetch('nodeId') == source.pool.node_id && pool.fetch('filesystem') == source.pool.filesystem
      end
      raise Invalid, 'Source is outside configured storage profile pools' unless selection

      pool!(selection)
      legacy = config.fetch('backupPool')
      pool!(legacy) if config.fetch('version') == 1
      if config.fetch('version') == 2 && selection.fetch('role') == 'hypervisor'
        preferred = config.fetch('vpsBackupPool')
        [[legacy, preferred], preferred]
      else
        [[legacy], legacy]
      end
    end

    def select_backup!(source, chain: nil, existing_only: false, registration: false,
                       check_backup_path: true, confirmed_only: false)
      ::StorageMutationAdmission.check! if check_backup_path
      allowed, default = placement_for(source)
      scope = source.dataset.dataset_in_pools.joins(:pool)
      copies = scope.where(pools: { role: :backup })
      if config.fetch('version') == 2
        # A configured destination with a changed role is invalid, not empty.
        allowed.each do |pool|
          copies = copies.or(scope.where(pools: { node_id: pool.fetch('nodeId'), filesystem: pool.fetch('filesystem') }))
        end
      end
      # v1 direct Plan calls retain their open-copy selection. Catch-up and the
      # strict guest reader, plus every v2 caller, inspect all backup copies.
      copies = copies.where(pools: { is_open: true }) if registration && !confirmed_only && config.fetch('version') == 1
      copies = copies.lock if check_backup_path
      copies = copies.limit(2).to_a
      if copies.empty? && !existing_only
        destination = pool!(default)
        validate_backup_path!(source.dataset, destination)
        return [destination, nil]
      end
      unless copies.one?
        raise Invalid, 'Source requires exactly the configured backup destination'
      end

      copy = copies.first
      selected = allowed.find do |pool|
        pool.fetch('nodeId') == copy.pool.node_id && pool.fetch('filesystem') == copy.pool.filesystem
      end
      raise Invalid, 'Existing backup copy is pending or has a conflicting destination' unless selected

      destination = pool!(selected)
      raise Invalid, 'Existing backup copy has an ambiguous destination' unless copy.pool_id == destination.id

      source_lock = source.get_current_lock
      chain_id = chain ? chain.dst_chain.id : (source_lock.locked_by_id if source_lock&.locked_by_type == 'TransactionChain')
      if confirmed_only
        unless source.confirmed? && source.dataset.confirmed? && copy.confirmed? && !source_lock && !source.dataset.get_current_lock
          raise Invalid, 'Fixture source or backup destination is pending or locked'
        end
      elsif !(copy.confirmed? || (copy.confirmed == :confirm_create && chain_id && owned_create_by_id?(chain_id, copy)))
        raise Invalid, 'Configured backup destination is not confirmed by this chain'
      end
      copy_lock = copy.get_current_lock
      if copy_lock && (confirmed_only || !(chain_id && copy_lock.locked_by_type == 'TransactionChain' && copy_lock.locked_by_id == chain_id))
        raise ::ResourceLocked.new(copy, 'Configured backup destination is locked by another chain')
      end

      validate_backup_path!(source.dataset, destination, copy: copy) if check_backup_path
      [destination, copy]
    end

    def validate_backup_path!(dataset, destination, copy: nil)
      ::StorageMutationAdmission.check!
      owners = ::DatasetInPool.joins(:pool, :dataset).where(
        pools: { node_id: destination.node_id, filesystem: destination.filesystem },
        datasets: { full_name: dataset.full_name }
      )
      owners = owners.where.not(id: copy.id) if copy
      # Admission serializes upgraded profile writers. FOR UPDATE sees a claim
      # committed while this transaction waited, including pending/Pool aliases.
      return if owners.lock.limit(1).to_a.empty?

      raise Invalid, 'Configured backup path has another catalog owner'
    end

    # Static seed and retirement share this bounded ownership check. Packages
    # and assignments survive; only the future default link is removed.
    def remove_owned_default!(environment)
      packages = ::ClusterResourcePackage.where(label: "Dev storage profile resources v#{config.fetch('packageVersion')}")
                                         .lock.limit(2).to_a
      defaults = ::DefaultUserClusterResourcePackage.where(environment: environment).lock.limit(2).to_a
      return if defaults.empty?

      unless defaults.one? && packages.one? && packages.first.user_id.nil? && packages.first.environment_id.nil? &&
             defaults.first.cluster_resource_package_id == packages.first.id
        raise Invalid, 'Storage profile future default is ambiguous or not owned'
      end

      defaults.first.destroy!
      nil
    end

    def positive_integer!(value, maximum: 1_000_000_000)
      return if value.is_a?(Integer) && value.between?(1, maximum)

      raise Invalid, 'Storage profile value must be a bounded positive integer'
    end

    def owned_create?(chain, record)
      owned_create_by_id?(chain.dst_chain.id, record)
    end

    def owned_create_by_id?(chain_id, record)
      ::TransactionConfirmation.where(
        done: 0, table_name: record.class.table_name, row_pks: { 'id' => record.id }, confirm_type: :create_type,
        transaction_id: ::Transaction.where(transaction_chain_id: chain_id).select(:id)
      ).exists?
    end

    def validate_pool_config!(pool, role:)
      fields = role == 'hypervisor' ? %w[nodeId filesystem role] : %w[nodeId filesystem role maxDatasets]
      unless pool.is_a?(Hash) && pool.keys.sort == fields.sort && pool['role'] == role &&
             pool['filesystem'].is_a?(String) && pool['filesystem'].match?(%r{\A[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z}) &&
             pool['filesystem'].split('/').none? { |part| %w[. ..].include?(part) }
        raise Invalid, 'Invalid configured storage pool'
      end

      positive_integer!(pool.fetch('nodeId'))
      positive_integer!(pool.fetch('maxDatasets'), maximum: 1024) unless role == 'hypervisor'
    end

    def schedule_attributes(schedule)
      { minute: schedule[0], hour: schedule[1], day_of_month: schedule[2], month: schedule[3], day_of_week: schedule[4] }
    end

    def validate_task!(action, schedule)
      tasks = ::RepeatableTask.where(class_name: 'DatasetAction', row_id: action.id).lock.limit(2).to_a
      unless tasks.one? && tasks.first.table_name == 'dataset_actions' &&
             schedule_attributes(schedule).all? { |key, value| tasks.first.public_send(key) == value }
        raise Invalid, 'Shared snapshot task is missing, ambiguous or incompatible'
      end

      plan.check_pending_confirmations!([action, tasks.first])
      tasks.first
    end
  end
end
