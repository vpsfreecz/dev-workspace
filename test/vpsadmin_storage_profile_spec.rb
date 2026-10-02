# frozen_string_literal: true

api_root = File.realpath(ENV.fetch('VPSADMIN_REPO_ROOT'))
if ENV.key?('DATABASE_URL') || File.exist?(File.join(api_root, 'api/config/database.yml'))
  raise 'Storage profile tests require a disposable database'
end

require File.join(api_root, 'api/spec/spec_helper')
require 'open3'
require 'tmpdir'
require 'timeout'
require 'rbconfig'
revision, status = Open3.capture2('git', '-C', api_root, 'rev-parse', 'HEAD')
raise 'API revision is unavailable' unless status.success?

warn "storage-profile API revision=#{revision.strip} helper=#{api_root}/api/spec/spec_helper.rb"
require_relative '../dev-clusters/vpsadmin/lib/storage_profile'

RSpec.describe DevClusters::VpsAdminStorageProfile do
  let(:source_pool) { SpecSeed.pool }
  let(:environment) { source_pool.node.location.environment }
  let(:user) { create_lifecycle_user! }
  let(:backup_pool) { create_profile_pool!(:backup, 'profile_backup') }
  let(:nas_pool) { create_profile_pool!(:primary, 'profile_nas') }
  let(:configuration) do
    {
      'version' => 1, 'enrollment' => true, 'environmentId' => environment.id,
      'sourcePools' => [{ 'nodeId' => source_pool.node_id, 'filesystem' => source_pool.filesystem, 'role' => 'hypervisor' }],
      'backupPool' => { 'nodeId' => backup_pool.node_id, 'filesystem' => backup_pool.filesystem, 'role' => 'backup', 'maxDatasets' => 32 },
      'nasPool' => { 'nodeId' => nas_pool.node_id, 'filesystem' => nas_pool.filesystem, 'role' => 'primary', 'maxDatasets' => 32 },
      'resources' => described_class::RESOURCE_DEFAULTS.dup, 'packageVersion' => 1, 'namespaceBlocks' => 2
    }
  end
  let(:profile) { described_class.new(configuration) }

  around do |example|
    definitions = VpsAdmin::API::DatasetPlans.plans.dup
    instance = described_class.instance_variable_get(:@instance)
    described_class.instance_variable_set(:@instance, nil)
    listeners = [User, DatasetInPool].flat_map do |klass|
      HaveAPI::Hooks.hooks.fetch(klass).values.map { |hook| [hook.fetch(:listeners), hook.fetch(:listeners).dup] }
    end
    unlock_transaction_signer!
    with_current_context(user: SpecSeed.admin) { example.run }
  ensure
    VpsAdmin::API::DatasetPlans::Registrator.instance_variable_set(:@plans, definitions)
    described_class.instance_variable_set(:@instance, instance)
    listeners.each { |list, saved| list.replace(saved) }
  end

  before do
    ensure_available_node_status!(source_pool.node)
    ensure_available_node_status!(SpecSeed.other_node)
    SpecSeed.other_location.update!(environment: environment)
    source_pool.update!(filesystem: 'tank/profile_source', max_datasets: 100, role: :hypervisor, state: :online, is_open: 1, maintenance_lock: 0,
                        checked_at: Time.current, available_space: 10_000, used_space: 100, total_space: 10_100)
  end

  def create_profile_pool!(role, suffix)
    pool = Pool.new(node: SpecSeed.other_node, label: suffix, filesystem: "tank/#{suffix}", role: role,
                    state: :online, is_open: 1, maintenance_lock: 0, max_datasets: 32,
                    checked_at: Time.current, available_space: 10_000, used_space: 100, total_space: 10_100)
    pool.save!
    pool
  end

  def install_profile_hooks!(selected = profile)
    [User, DatasetInPool].each do |klass|
      HaveAPI::Hooks.hooks.fetch(klass).each_value { |hook| hook.fetch(:listeners).clear }
    end
    selected.install_hooks!
  end

  def bootstrap!
    profile.install_plan!
    profile.bootstrap_templates!
  end

  def fresh_profile_reader(selected_configuration, chains)
    # The top-level guard and actual spec_helper started this automatic DB.
    # Never forward a configured/inherited URL, or reset its schema in a child.
    owned_url = VpsAdmin::TestDb.auto_start!
    uri = URI.parse(owned_url)
    connection = ActiveRecord::Base.connection_db_config.configuration_hash
    unless ENV.fetch('DATABASE_URL') == owned_url && uri.scheme == 'mysql2' && uri.host == '127.0.0.1' &&
           connection.values_at(:adapter, :host, :port, :database) ==
           ['mysql2', uri.host, uri.port, uri.path.delete_prefix('/')]
      raise 'Fresh profile reader refuses a database not owned by the automatic test harness'
    end

    Dir.mktmpdir('profile-reader-') do |root|
      File.chmod(0o700, root)
      config_dir = File.join(root, 'config')
      FileUtils.mkdir(config_dir)
      api = File.realpath(ENV.fetch('VPSADMIN_REPO_ROOT'))
      # Reproduce storageProfileConfigDir's public overlay, not a generated seed.
      FileUtils.cp(Dir[File.join(api, 'tests/configs/vpsadmin/api', '*')], config_dir)
      overlay = File.expand_path('../dev-clusters/vpsadmin/nix/storage-profile', __dir__)
      %w[hooks dataset_plans].each { |name| FileUtils.cp(File.join(overlay, "#{name}.rb"), config_dir) }
      FileUtils.cp(File.join(overlay, 'config.rb'), File.join(config_dir, 'storage_profile_config.rb'))
      FileUtils.cp(File.expand_path('../dev-clusters/vpsadmin/lib/storage_profile.rb', __dir__),
                   File.join(config_dir, 'storage_profile_impl.rb'))
      File.write(File.join(config_dir, 'storage-profile.json'), JSON.generate(selected_configuration), mode: 'w', perm: 0o600)
      input = { api: api, root: root, port: uri.port, database: connection.fetch(:database), ids: chains.map(&:id) }
      Open3.popen3({ 'PROFILE_READER_DATABASE_URL' => owned_url, 'DATABASE_URL' => nil },
                   RbConfig.ruby, '-e', fresh_profile_reader_script, pgroup: true) do |stdin, stdout, stderr, waiter|
        stdin.write(JSON.generate(input))
        stdin.close
        output = Thread.new { stdout.read(16_384) }
        diagnostics = Thread.new { stderr.read(16_384) }
        begin
          status = Timeout.timeout(45) { waiter.value }
          unless status.success?
            failure = begin
              JSON.parse(output.value).fetch('reader_failure')
            rescue JSON::ParserError, KeyError, TypeError
              nil
            end
            unless failure.is_a?(Array) && failure.size == 4 &&
                   failure.all? { |value| value.is_a?(Integer) && value.between?(0, 10_000) }
              failure = [0, 0, 0, 0]
            end
            stage, category, frame, line = failure
            selected = selected_configuration.fetch('enrollment') ? 1 : 0
            raise "Fresh profile reader failed (selection=#{selected} stage=#{stage} category=#{category} frame=#{frame} line=#{line})"
          end

          JSON.parse(output.value)
        ensure
          begin
            Process.kill('KILL', -waiter.pid) if waiter.alive?
          rescue Errno::ESRCH
            # The child exited between the liveness check and cancellation.
            nil
          end
          waiter.join
          output.join
          diagnostics.join
        end
      end
    end
  end

  def fresh_profile_reader_script
    <<~'RUBY'
      stage = 0
      begin
        require 'timeout'
        Timeout.timeout(35) do
          require 'bundler/setup'
          require 'active_record'
          require 'json'
          require 'uri'
          stage = 1
          input = JSON.parse(STDIN.read(16_384))
          stage = 2
          uri = URI.parse(ENV.fetch('PROFILE_READER_DATABASE_URL'))
          unless uri.scheme == 'mysql2' && uri.host == '127.0.0.1' &&
                 uri.port == input.fetch('port') && uri.path == "/#{input.fetch('database')}"
            raise 'Invalid private reader database binding'
          end
          # Base loads database_configurations; require 'active_record' alone
          # does not define that constant in this fresh process.
          config = ActiveRecord::Base.configurations.resolve(uri.to_s)
          stage = 3
          ActiveRecord::Base.establish_connection(
            config.configuration_hash.merge(connect_timeout: 5, read_timeout: 5, write_timeout: 5)
          )
          db = ActiveRecord::Base.connection
          unless db.select_value('SELECT @@port').to_i == input.fetch('port') &&
                 db.select_value('SELECT DATABASE()') == input.fetch('database')
            raise 'Reader connected to a different disposable database'
          end
          # Only this test-owned reader sees the parent's rollback fixture.
          stage = 4
          db.execute('SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED')
          db.execute('SET SESSION TRANSACTION READ ONLY')
          before = db.select_value('SELECT COUNT(*) FROM transaction_chains').to_i
          module VpsAdmin
            module API; end
          end
          VpsAdmin::API.instance_variable_set(:@root, input.fetch('root'))
          producer_guard = TracePoint.new(:call) do |event|
            raise 'A reader invoked the catch-up producer' if event.method_id == :catch_up_chain
          end
          producer_guard.enable do
            # Actual Admin bootstrap invokes load_configurable after its models.
            stage = 5
            require File.join(input.fetch('api'), 'api/lib/vpsadmin')
            stage = 6
            rows = TransactionChain.where(id: input.fetch('ids')).order(:id).map do |chain|
              { 'id' => chain.id, 'class' => chain.class.name, 'state' => chain.state, 'size' => chain.size,
                'transactions' => chain.transactions.order(:id).pluck(:id, :handle) }
            end
            stage = 7
            raise 'Reader initialization wrote a chain' unless TransactionChain.count == before

            puts JSON.generate('enrollment' => DevClusters::VpsAdminStorageProfile.instance.enrollment?, 'chains' => rows)
          end
        end
      rescue StandardError, ScriptError => error
        # Fixed categories and public source IDs only. Never render messages,
        # SQL, URLs, input/config values or arbitrary backtrace paths.
        categories = { 'NameError' => 1, 'NoMethodError' => 2, 'LoadError' => 3, 'ArgumentError' => 4,
                       'Mysql2::Error' => 5, 'ActiveRecord::StatementInvalid' => 6, 'Timeout::Error' => 7,
                       'JSON::ParserError' => 8, 'RuntimeError' => 9 }
        category = categories.fetch(error.class.name, 0)
        public_sources = { '-e' => 1 }
        if defined?(input) && input.is_a?(Hash)
          api = input.fetch('api')
          root = input.fetch('root')
          public_sources.merge!(
            File.join(api, 'api/lib/vpsadmin.rb') => 2,
            File.join(api, 'api/lib/vpsadmin/api.rb') => 3,
            File.join(root, 'config/storage_profile_impl.rb') => 4,
            File.join(root, 'config/storage_profile_config.rb') => 5,
            File.join(root, 'config/hooks.rb') => 6,
            File.join(root, 'config/dataset_plans.rb') => 7,
            File.join(api, 'api/models/transaction_chain.rb') => 8
          )
        end
        location = error.backtrace_locations&.find { |frame| public_sources.key?(frame.path) }
        frame = location ? public_sources.fetch(location.path) : 0
        line = location ? location.lineno.clamp(0, 10_000) : 0
        require 'json'
        puts JSON.generate('reader_failure' => [stage, category, frame, line])
        exit 1
      end
    RUBY
  end

  def retired_profile!
    described_class.new(configuration.merge('enrollment' => false)).tap(&:install_plan!)
  end

  # Execute the actual static seed methods, including their enabled/disabled
  # branch, from the public Nix template. No generated private seed is read.
  def seed_methods(enabled: true, selected_configuration: configuration)
    described_class.configure(selected_configuration)
    source = File.read(File.expand_path('../dev-clusters/vpsadmin/nix/test.nix', __dir__))
    first = source.index('    def upsert_user_namespace(')
    last = source.index('    def upsert_dev_user(', first)
    methods = source[first...last].gsub(/\$\{lib.optionalString storageProfile.enable ''\n(.*?)      ''\}/m) do
      enabled ? Regexp.last_match(1) : ''
    end
    Object.new.tap { |receiver| receiver.instance_eval(methods, 'static-profile-seed', 1) }
  end

  it 'runs the enabled static seed repeatedly without rewriting changed namespace or resource assignments' do
    ensure_user_namespace_blocks!(count: 6)
    chain, namespace = TransactionChains::UserNamespace::Allocate.fire(user, 2)
    map = UserNamespaceMap.create_chained!(namespace, 'Default map')
    UserNamespaceMapEntry.kinds.each_value do |kind|
      UserNamespaceMapEntry.create!(user_namespace_map: map, kind: kind, vps_id: 3, ns_id: 5, count: 100)
    end
    seed = seed_methods
    seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS)
    package = ClusterResourcePackage.find_by!(user: user, environment: environment)
    cpu = ClusterResource.find_by!(name: 'cpu')
    package.cluster_resource_package_items.find_by!(cluster_resource: cpu).update!(value: 27)
    user.user_cluster_resources.find_by!(environment: environment, cluster_resource: cpu).update!(value: 27)
    before = [namespace.reload.attributes, namespace.user_namespace_blocks.order(:id).map(&:attributes),
              map.user_namespace_map_entries.order(:id).map(&:attributes), package.reload.attributes,
              package.cluster_resource_package_items.order(:id).map(&:attributes),
              user.user_cluster_resource_packages.order(:id).map(&:attributes),
              user.user_cluster_resources.order(:id).map(&:attributes)]
    2.times do
      seed.upsert_user_namespace(user, 'namespace' => { 'blockStart' => 9999, 'blockCount' => 8 })
      seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS)
    end
    expect([namespace.reload.attributes, namespace.user_namespace_blocks.order(:id).map(&:attributes),
            map.user_namespace_map_entries.order(:id).map(&:attributes), package.reload.attributes,
            package.cluster_resource_package_items.order(:id).map(&:attributes),
            user.user_cluster_resource_packages.order(:id).map(&:attributes),
            user.user_cluster_resources.order(:id).map(&:attributes)]).to eq(before)
    expect(chain.transactions.order(:id).pluck(:handle)).to eq([Transactions::Utils::NoOp.t_type])
  end

  it 'defers missing namespace allocation from the enabled static seed' do
    expect { seed_methods.upsert_user_namespace(user, {}) }.not_to change(UserNamespace, :count)
    expect(UserNamespace.where(user: user)).to be_empty
  end

  it 'retains the disabled seed personal-resource update behavior' do
    seed = seed_methods(enabled: false)
    seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS)
    seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS.merge('cpu' => 9))
    expect(user.user_cluster_resources.find_by!(environment: environment, cluster_resource: ClusterResource.find_by!(name: 'cpu')).value).to eq(9)
  end

  it 'refuses inconsistent accounting without overwriting the existing assignment' do
    seed = seed_methods
    seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS)
    cpu = user.user_cluster_resources.find_by!(cluster_resource: ClusterResource.find_by!(name: 'cpu'))
    cpu.update!(value: 99)
    expect { seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS) }
      .to raise_error(described_class::Invalid, /disagree/)
    expect(cpu.reload.value).to eq(99)
  end

  it 'bootstraps a shared future-user default and refuses subsequent policy drift' do
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    package = profile.bootstrap_defaults!
    expect(package.user_id).to be_nil
    expect(package.environment_id).to be_nil
    expect(profile.bootstrap_defaults!.id).to eq(package.id)
    changed = configuration.merge('resources' => configuration.fetch('resources').merge('cpu' => 8))
    expect { described_class.new(changed).bootstrap_defaults! }.to raise_error(described_class::Invalid, /cannot change/)
    expect(package.cluster_resource_package_items.find_by!(cluster_resource: ClusterResource.find_by!(name: 'cpu')).value).to eq(4)
    expect(environment.reload.max_vps_count).to eq(2)
  end

  it 'repeats static defaults while frozen without changing assignments, storage or enrollment' do
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    seed_methods.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS)
    ensure_user_namespace_blocks!(count: 6)
    _, namespace = TransactionChains::UserNamespace::Allocate.fire(user, 2)
    map = UserNamespaceMap.create_chained!(namespace, 'Default map')
    UserNamespaceMapEntry.kinds.each_value do |kind|
      UserNamespaceMapEntry.create!(user_namespace_map: map, kind: kind, vps_id: 3, ns_id: 5, count: 100)
    end
    create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-frozen-existing')
    bootstrap!
    StorageMutationAdmission.set_read_only_for_user!(
      read_only: true, expected_epoch: StorageFreezeControl.singleton!.epoch,
      reason: 'frozen preserving seed fixture', user: SpecSeed.admin, user_session: UserSession.current
    )
    protected_models = [
      StorageFreezeControl, StorageFreezeTransition, StorageObserverCatchUpAudit,
      UserClusterResourcePackage, UserClusterResource, UserNamespace, UserNamespaceBlock,
      UserNamespaceMap, UserNamespaceMapEntry, Pool, Dataset, DatasetInPool, DatasetProperty,
      Snapshot, SnapshotInPool, DatasetTree, Branch, SnapshotInPoolInBranch, SnapshotInPoolClone,
      TransactionChain, Transaction, TransactionConfirmation, ResourceLock, StorageMutationIntent,
      StorageMutationIntentScope, StorageMutationTarget, StorageMutationAttempt,
      StorageMutationTargetObservation, DatasetPlan, EnvironmentDatasetPlan, DatasetInPoolPlan,
      DatasetAction, GroupSnapshot, RepeatableTask
    ]
    preserved_rows = -> { protected_models.map { |model| model.order(:id).map(&:attributes) } }
    before = preserved_rows.call
    existing_package = ClusterResourcePackage.find_by!(user: user, environment: environment)
    existing_package_attributes = existing_package.attributes
    existing_items = existing_package.cluster_resource_package_items.order(:id).map(&:attributes)

    package = profile.bootstrap_defaults!
    expect(profile.bootstrap_defaults!.id).to eq(package.id)
    expect(preserved_rows.call).to eq(before)
    expect(existing_package.reload.attributes).to eq(existing_package_attributes)
    expect(existing_package.cluster_resource_package_items.order(:id).map(&:attributes)).to eq(existing_items)
    expect(environment.reload).to have_attributes(can_create_vps: true, can_destroy_vps: true, max_vps_count: 2)
    expect(DefaultUserClusterResourcePackage.where(environment: environment).pluck(:cluster_resource_package_id))
      .to eq([package.id])

    environment.update!(can_create_vps: false, can_destroy_vps: false, max_vps_count: 9)
    previous_environment = environment.reload.attributes
    previous_packages = ClusterResourcePackage.order(:id).map(&:attributes)
    previous_items = ClusterResourcePackageItem.order(:id).map(&:attributes)
    changed = configuration.merge('resources' => configuration.fetch('resources').merge('cpu' => 8))
    expect { described_class.new(changed).bootstrap_defaults! }.to raise_error(described_class::Invalid, /cannot change/)
    expect(environment.reload.attributes).to eq(previous_environment)
    expect(ClusterResourcePackage.order(:id).map(&:attributes)).to eq(previous_packages)
    expect(ClusterResourcePackageItem.order(:id).map(&:attributes)).to eq(previous_items)
    expect(preserved_rows.call).to eq(before)
  end

  it 'repeats the retired static seed while frozen and removes only the owned future default' do
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    profile.bootstrap_defaults!
    environment.update!(can_create_vps: false, can_destroy_vps: false, max_vps_count: 9)
    retired = retired_profile!
    seed = seed_methods(selected_configuration: retired.config)
    seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS)
    ensure_user_namespace_blocks!(count: 6)
    _, namespace = TransactionChains::UserNamespace::Allocate.fire(user, 2)
    map = UserNamespaceMap.create_chained!(namespace, 'Default map')
    UserNamespaceMapEntry.kinds.each_value do |kind|
      UserNamespaceMapEntry.create!(user_namespace_map: map, kind: kind, vps_id: 3, ns_id: 5, count: 100)
    end
    create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-retired-frozen')
    StorageMutationAdmission.set_read_only_for_user!(
      read_only: true, expected_epoch: StorageFreezeControl.singleton!.epoch,
      reason: 'retired preserving seed fixture', user: SpecSeed.admin, user_session: UserSession.current
    )
    protected_models = [
      Environment, StorageFreezeControl, StorageFreezeTransition, ClusterResourcePackage, ClusterResourcePackageItem,
      UserClusterResourcePackage, UserClusterResource, UserNamespace, UserNamespaceBlock, UserNamespaceMap,
      UserNamespaceMapEntry, Pool, Dataset, DatasetInPool, TransactionChain, Transaction, TransactionConfirmation,
      ResourceLock, DatasetPlan, EnvironmentDatasetPlan, DatasetInPoolPlan, DatasetAction, GroupSnapshot, RepeatableTask
    ]
    rows = -> { protected_models.map { |model| model.order(:id).map(&:attributes) } }
    before = rows.call
    2.times do
      retired.bootstrap_defaults!
      seed.upsert_user_namespace(user, 'namespace' => { 'blockStart' => 9999, 'blockCount' => 8 })
      seed.upsert_user_resources(SpecSeed.admin, environment, user, described_class::RESOURCE_DEFAULTS.merge('cpu' => 9))
    end
    expect(DefaultUserClusterResourcePackage.where(environment: environment)).to be_empty
    expect(rows.call).to eq(before)
    unrelated = ClusterResourcePackage.create!(label: 'Unrelated future policy')
    link = DefaultUserClusterResourcePackage.create!(environment: environment, cluster_resource_package: unrelated)
    expect { retired.bootstrap_defaults! }.to raise_error(described_class::Invalid, /not owned/)
    expect(link.reload.cluster_resource_package_id).to eq(unrelated.id)
    expect(environment.reload.max_vps_count).to eq(9)
  end

  it 'rejects retired explicit enrollment and direct add or verify while permitting normal removal' do
    bootstrap!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-retired-existing')
    attach_dataset_to_pool!(dataset: dataset, pool: backup_pool)
    profile.plan.register(source)
    other_dataset, other = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-retired-new')
    attach_dataset_to_pool!(dataset: other_dataset, pool: backup_pool)
    retired = retired_profile!
    protected_models = [DatasetInPoolPlan, DatasetAction, GroupSnapshot, RepeatableTask, TransactionChain, Transaction,
                        TransactionConfirmation, ResourceLock, DatasetInPool, UserNamespace]
    rows = -> { protected_models.map { |model| model.order(:id).map(&:attributes) } }
    before = rows.call
    [source, other].each do |dip|
      expect { retired.plan.register(dip) }.to raise_error(described_class::Invalid, /disabled/)
    end
    expect { retired.bootstrap_templates! }.to raise_error(described_class::Invalid, /disabled/)
    expect { retired.catch_up_chain.fire(retired, user: user) }.to raise_error(described_class::Invalid, /disabled/)
    expect { retired.ensure_namespace!(chain: nil, user: user) }.to raise_error(described_class::Invalid, /disabled/)
    expect { retired.ensure_nas!(chain: nil, user: user) }.to raise_error(described_class::Invalid, /disabled/)
    expect { retired.ensure_backup_and_plan!(chain: nil, source_dip: source) }.to raise_error(described_class::Invalid, /disabled/)
    expect(rows.call).to eq(before)
    retired.plan.unregister(source)
    expect(DatasetInPoolPlan.where(dataset_in_pool: source)).to be_empty
    expect(dataset.reload.dataset_in_pools.count).to eq(2)
    expect { profile.retire! }.to raise_error(described_class::Invalid, /requires enrollment disabled/)
  end

  it 'keeps retired Dataset and member hooks free of new enrollment' do
    retired = retired_profile!
    install_profile_hooks!(retired)
    seed_pool_dataset_properties!(source_pool)
    source_pool.update!(refquota_check: false)
    root = Dataset.new(user: user, name: 'profile-retired-hook', user_editable: true,
                       user_create: true, user_destroy: true, confirmed: Dataset.confirmed(:confirm_create))
    chain, sources = TransactionChains::Dataset::Create.fire(source_pool, nil, [root], { user: user })
    expect(chain.transactions.where(handle: Transactions::Storage::CreateDataset.t_type).count).to eq(1)
    expect(root.reload.dataset_in_pools.count).to eq(1)
    expect(DatasetInPoolPlan.where(dataset_in_pool: sources.last)).to be_empty
    member = User.new(login: "profile-retired-#{SecureRandom.hex(4)}", full_name: 'Retired Profile Member',
                      email: 'profile-retired@test.invalid', language: SpecSeed.language, level: 1,
                      enable_basic_auth: true, enable_token_auth: true, mailer_enabled: true)
    member.set_password('secret123')
    user_chain, created = TransactionChains::User::Create.fire(member, false, nil, nil, true)
    expect(UserNamespace.where(user: created)).to be_empty
    expect(Dataset.where(user: created)).to be_empty
    expect(user_chain.transactions.where(handle: Transactions::Storage::CreateDataset.t_type)).to be_empty
  end

  it 'reports loaded enrollment and rejects retired provision before catalog or chain changes' do
    SpecSeed.other_node.update!(role: :storage)
    source = File.read(File.expand_path('../dev-clusters/vpsadmin/nix/storage-profile-provision.rb', __dir__))
    first = source.index('module DevStorageProfileProvision')
    last = source.index("\nactor = ", first)
    Object.class_eval(source[first...last], 'storage-profile-provision', 1)
    retired = retired_profile!
    expect(DevStorageProfileProvision.inspect(profile).fetch('enrollment')).to be(true)
    report = DevStorageProfileProvision.inspect(retired)
    expect(report.fetch('enrollment')).to be(false)
    expect(report.fetch('pools').map { |row| row.fetch('present') }).to eq([true, true, true])
    models = [Pool, Dataset, DatasetInPool, DatasetAction, RepeatableTask, TransactionChain, Transaction, ResourceLock]
    before = models.map(&:count)
    expect { DevStorageProfileProvision.provision!(retired) }.to raise_error(described_class::Invalid, /disabled/)
    expect(models.map(&:count)).to eq(before)
  end

  it 'does not allocate member NAS or namespace for a future administrative account' do
    install_profile_hooks!
    account = User.new(login: "profile-admin-#{SecureRandom.hex(4)}", full_name: 'Profile Service Administrator',
                       email: 'profile-admin@test.invalid', language: SpecSeed.language, level: 99,
                       enable_basic_auth: true, enable_token_auth: true, mailer_enabled: true)
    account.set_password('secret123')
    _, created = TransactionChains::User::Create.fire(account, false, nil, nil, true)
    expect(UserNamespace.where(user: created)).to be_empty
    expect(Dataset.where(user: created)).to be_empty
    expect { profile.catch_up_chain.fire(profile, user: created) }
      .to raise_error(described_class::Invalid, /ordinary member/)
  end

  it 'bootstraps exact empty templates separately and preserves their identities on repetition' do
    bootstrap!
    actions = profile.plan.dataset_plan.dataset_actions.order(:id).to_a
    expect(actions.map(&:pool_id)).to contain_exactly(source_pool.id, nas_pool.id)
    expect(actions.all? { |action| action.group_snapshots.empty? }).to be(true)
    tasks = actions.map { |action| RepeatableTask.find_for!(action).id }
    profile.bootstrap_templates!
    expect(profile.plan.dataset_plan.dataset_actions.order(:id).pluck(:id)).to eq(actions.map(&:id))
    expect(actions.map { |action| RepeatableTask.find_for!(action).id }).to eq(tasks)
  end

  it 'loads persisted nonempty queued and terminal catch-up chains in fresh active and retired overlay readers' do
    bootstrap!
    chains = %w[queued done].map do |state|
      _, source = create_dataset_with_pool!(user: user, pool: source_pool, name: "profile-reader-#{state}")
      chain, = profile.catch_up_chain.fire(profile, source_dip: source)
      expect(chain.transactions.order(:id).pluck(:handle))
        .to eq([Transactions::Storage::CreateDataset.t_type, Transactions::Utils::NoOp.t_type])
      # A terminal STI row must remain readable too; no Node effect is run here.
      chain.update!(state: state)
      chain
    end
    expected = chains.sort_by(&:id).map do |chain|
      { 'id' => chain.id, 'class' => 'DevClusters::VpsAdminStorageProfile::CatchUp',
        'state' => chain.state, 'size' => chain.size,
        'transactions' => chain.transactions.order(:id).pluck(:id, :handle) }
    end
    [true, false].each do |enrollment|
      expect(fresh_profile_reader(configuration.merge('enrollment' => enrollment), chains))
        .to eq('enrollment' => enrollment, 'chains' => expected)
    end
  end

  it 'adds only a missing backup copy to 5201 and gives the outer NoOp its new membership metadata' do
    bootstrap!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-existing-source')
    source.update!(min_snapshots: 7, max_snapshots: 99, snapshot_max_age: 777)
    shared = profile.plan.dataset_plan.dataset_actions.to_a
    chain, backup = profile.catch_up_chain.fire(profile, source_dip: source)
    expect(chain.transactions.order(:id).pluck(:handle))
      .to eq([Transactions::Storage::CreateDataset.t_type, Transactions::Utils::NoOp.t_type])
    expect(backup.attributes.values_at('min_snapshots', 'max_snapshots', 'snapshot_max_age')).to eq([2, 5, 3600])
    expect(source.reload.attributes.values_at('min_snapshots', 'max_snapshots', 'snapshot_max_age')).to eq([7, 99, 777])
    rows = confirmations_for(chain)
    expect(rows.select { |row| row.confirm_type == 'create_type' }.map { |row| [row.table_name, row.row_pks] })
      .to eq([['dataset_in_pools', { 'id' => backup.id }]])
    expect(rows.any? { |row| row.table_name == 'datasets' && row.row_pks == { 'id' => dataset.id } }).to be(false)
    shared.each do |action|
      expect(rows.any? { |row| row.table_name == 'dataset_actions' && row.row_pks == { 'id' => action.id } }).to be(false)
    end
    expect(rows.select { |row| row.table_name == 'group_snapshots' }.size).to eq(1)
    expect(rows.select { |row| row.table_name == 'dataset_in_pool_plans' }.size).to eq(1)
  end

  it 'rolls back staging failure without owning the reused Dataset or shared templates' do
    bootstrap!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-rollback-source')
    ids = profile.plan.dataset_plan.dataset_actions.pluck(:id)
    allow(profile.plan).to receive(:register).and_raise(described_class::Invalid, 'injected staging failure')
    expect { profile.catch_up_chain.fire(profile, source_dip: source) }.to raise_error(described_class::Invalid, /injected/)
    expect(dataset.reload.dataset_in_pools.pluck(:id)).to eq([source.id])
    expect(profile.plan.dataset_plan.dataset_actions.pluck(:id)).to match_array(ids)
    expect(GroupSnapshot.where(dataset_in_pool: source)).to be_empty
  end

  it 'refuses foreign or closed destinations without fallback or provisional rows' do
    bootstrap!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-foreign-source')
    foreign = create_profile_pool!(:backup, 'foreign_backup')
    DatasetInPool.create!(dataset: dataset, pool: foreign, confirmed: DatasetInPool.confirmed(:confirmed))
    expect { profile.catch_up_chain.fire(profile, source_dip: source) }.to raise_error(described_class::Invalid, /conflicting/)
    expect(DatasetInPool.where(dataset: dataset).count).to eq(2)
    backup_pool.update!(is_open: 0)
    expect { profile.catch_up_chain.fire(profile, source_dip: source) }.to raise_error(described_class::Invalid, /closed/)
    expect(DatasetInPoolPlan.where(dataset_in_pool: source)).to be_empty
  end

  it 'reuses members within one outer chain without creating another backup or owning the templates' do
    bootstrap!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-reuse')
    chain, copies = profile.catch_up_chain.fire(profile, source_dips: [source, source])
    expect(copies.map(&:id).uniq.size).to eq(1)
    expect(chain.transactions.where(handle: Transactions::Storage::CreateDataset.t_type).count).to eq(1)
    expect(DatasetInPoolPlan.where(dataset_in_pool: source).count).to eq(1)
    expect(GroupSnapshot.where(dataset_in_pool: source).count).to eq(1)
    expect(confirmations_for(chain).count { |row| row.table_name == 'datasets' }).to eq(0)
    expect(dataset.reload.confirmed?).to be(true)
  end

  it 'keeps the configured destination mandatory for direct plan enrollment' do
    bootstrap!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-direct')
    destination = attach_dataset_to_pool!(dataset: dataset, pool: backup_pool)
    destination.update!(confirmed: DatasetInPool.confirmed(:confirm_create))
    expect { profile.plan.register(source) }.to raise_error(described_class::Invalid, /not confirmed/)
    expect(DatasetInPoolPlan.where(dataset_in_pool: source)).to be_empty
    destination.update!(confirmed: DatasetInPool.confirmed(:confirmed))
    profile.plan.register(source)
    expect(DatasetInPoolPlan.where(dataset_in_pool: source).count).to eq(1)
  end

  it 'uses the actual Dataset hook once and respects preserve-existing-backups replacement' do
    bootstrap!
    install_profile_hooks!
    profile.install_hooks!
    seed_pool_dataset_properties!(source_pool)
    source_pool.update!(refquota_check: false)
    root = Dataset.new(user: user, name: 'profile-hook', user_editable: true,
                       user_create: true, user_destroy: true, confirmed: Dataset.confirmed(:confirm_create))
    chain, sources = TransactionChains::Dataset::Create.fire(source_pool, nil, [root], { user: user })
    source = sources.last
    expect(chain.transactions.where(handle: Transactions::Storage::CreateDataset.t_type).count).to eq(2)
    expect(source.attributes.values_at('min_snapshots', 'max_snapshots', 'snapshot_max_age')).to eq([2, 3, 1800])
    expect(confirmations_for(chain).count { |row| row.table_name == 'datasets' && row.row_pks == { 'id' => root.id } }).to eq(1)
    expect do
      source.call_class_hooks_for(:create, chain, args: [source],
                                                  kwargs: { purpose: :vps_replace, preserve_existing_backups: true })
    end.not_to change(Transaction, :count)
  end

  it 'allocates a future member namespace and NAS on its User chain after default accounting' do
    bootstrap!
    install_profile_hooks!
    ensure_user_namespace_blocks!(count: 8)
    seed_pool_dataset_properties!(nas_pool)
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    package = profile.bootstrap_defaults!
    member = User.new(login: "profile-future-#{SecureRandom.hex(4)}", full_name: 'Profile Future User',
                      email: 'profile-future@test.invalid', language: SpecSeed.language, level: 1,
                      enable_basic_auth: true, enable_token_auth: true, mailer_enabled: true)
    member.set_password('secret123')
    chain, created = TransactionChains::User::Create.fire(member, false, nil, nil, true)
    root = Dataset.roots.find_by!(user: created, name: created.id.to_s)
    expect(root.dataset_in_pools.pluck(:pool_id)).to contain_exactly(nas_pool.id, backup_pool.id)
    expect(root.dataset_in_pools.find_by!(pool: nas_pool).effective_quota).to eq(1024)
    expect(UserNamespace.where(user: created).count).to eq(1)
    expect(UserNamespaceMap.joins(:user_namespace).where(user_namespaces: { user_id: created.id }).count).to eq(1)
    expect(UserClusterResourcePackage.where(user: created, environment: environment, cluster_resource_package: package).count).to eq(1)
    expect(created.user_cluster_resources.find_by!(environment: environment, cluster_resource: ClusterResource.find_by!(name: 'diskspace')).value).to eq(8192)
    expect(confirmations_for(chain).map(&:table_name)).to include('user_namespaces', 'user_namespace_maps', 'datasets')
    expect(chain.transactions.where(handle: Transactions::Storage::CreateDataset.t_type).count).to eq(2)
    expect(TransactionChain.where(user: SpecSeed.admin).where.not(id: chain.id).count).to eq(0)
  end

  it 'rolls back a failed future-member NAS enrollment without deleting shared templates' do
    bootstrap!
    install_profile_hooks!
    ensure_user_namespace_blocks!(count: 8)
    seed_pool_dataset_properties!(nas_pool)
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    profile.bootstrap_defaults!
    member = User.new(login: "profile-failed-#{SecureRandom.hex(4)}", full_name: 'Profile Failed User',
                      email: 'profile-failed@test.invalid', language: SpecSeed.language, level: 1,
                      enable_basic_auth: true, enable_token_auth: true, mailer_enabled: true)
    member.set_password('secret123')
    ids = profile.plan.dataset_plan.dataset_actions.pluck(:id)
    allow(profile.plan).to receive(:register).and_raise(described_class::Invalid, 'injected enrollment failure')
    expect { TransactionChains::User::Create.fire(member, false, nil, nil, true) }.to raise_error(described_class::Invalid, /injected/)
    expect(User.exists?(login: member.login)).to be(false)
    expect(UserNamespace.where(user_id: member.id)).to be_empty
    expect(Dataset.where(user_id: member.id)).to be_empty
    expect(profile.plan.dataset_plan.dataset_actions.pluck(:id)).to match_array(ids)
  end

  it 'retires memberships and templates atomically without deleting logical or physical copy catalog' do
    bootstrap!
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    package = profile.bootstrap_defaults!
    package_items = package.cluster_resource_package_items.order(:id).map(&:attributes)
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-retire')
    attach_dataset_to_pool!(dataset: dataset, pool: backup_pool)
    profile.plan.register(source)
    retired = retired_profile!
    2.times { retired.retire! }
    expect(DatasetInPoolPlan.where(dataset_in_pool: source)).to be_empty
    expect(profile.plan.dataset_plan.dataset_actions).to be_empty
    expect(profile.plan.dataset_plan.environment_dataset_plans).to be_empty
    expect(DefaultUserClusterResourcePackage.where(environment: environment)).to be_empty
    expect(package.reload.cluster_resource_package_items.order(:id).map(&:attributes)).to eq(package_items)
    expect(dataset.reload.dataset_in_pools.count).to eq(2)
    2.times { retired.bootstrap_defaults! }
    expect { retired.bootstrap_templates! }.to raise_error(described_class::Invalid, /disabled/)
    expect { retired.catch_up_chain.fire(retired, source_dip: source) }.to raise_error(described_class::Invalid, /disabled/)
    expect(DefaultUserClusterResourcePackage.where(environment: environment)).to be_empty
    expect(retired.plan.dataset_plan.dataset_actions).to be_empty
  end

  it 'refuses a foreign template atomically without deleting owned memberships or future defaults' do
    bootstrap!
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    profile.bootstrap_defaults!
    dataset, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-foreign-template')
    attach_dataset_to_pool!(dataset: dataset, pool: backup_pool)
    profile.plan.register(source)
    foreign = create_profile_pool!(:primary, 'unconfigured_template')
    action = DatasetAction.create!(dataset_plan: profile.plan.dataset_plan, pool: foreign, action: :group_snapshot)
    RepeatableTask.create!(class_name: 'DatasetAction', table_name: 'dataset_actions', row_id: action.id,
                           minute: '*/5', hour: '*', day_of_month: '*', month: '*', day_of_week: '*')
    models = [DatasetAction, RepeatableTask, DatasetInPoolPlan, GroupSnapshot, EnvironmentDatasetPlan,
              DefaultUserClusterResourcePackage, Dataset, DatasetInPool]
    rows = models.map { |model| model.order(:id).map(&:attributes) }
    retired = retired_profile!
    expect { retired.retire! }.to raise_error(described_class::Invalid, /outside configured pools/)
    expect(models.map { |model| model.order(:id).map(&:attributes) }).to eq(rows)
  end

  it 'refuses retirement during pending rollback and preserves the future default link' do
    bootstrap!
    DefaultUserClusterResourcePackage.where(environment: environment).delete_all
    package = profile.bootstrap_defaults!
    _, source = create_dataset_with_pool!(user: user, pool: source_pool, name: 'profile-pending-retire')
    chain, = profile.catch_up_chain.fire(profile, source_dip: source)
    chain.update!(state: :rollbacking)
    chain.transactions.first.update!(done: 2)
    rows = confirmations_for(chain).map(&:attributes)
    actions = profile.plan.dataset_plan.dataset_actions.order(:id).map(&:attributes)
    retired = retired_profile!
    expect { retired.retire! }.to raise_error(ResourceLocked)
    expect(DefaultUserClusterResourcePackage.where(environment: environment).pluck(:cluster_resource_package_id))
      .to eq([package.id])
    expect(confirmations_for(chain).map(&:attributes)).to eq(rows)
    expect(profile.plan.dataset_plan.dataset_actions.order(:id).map(&:attributes)).to eq(actions)
    expect(DatasetInPoolPlan.where(dataset_in_pool: source).count).to eq(1)
  end
end
