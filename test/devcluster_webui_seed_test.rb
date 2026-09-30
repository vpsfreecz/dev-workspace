require 'minitest/autorun'
require 'tmpdir'

class FakeOauth2Client
  NAME = 'vpsAdmin React development WebUI'

  class Scope
    def initialize(rows, name)
      @rows = rows
      @name = name
    end

    def where
      self
    end

    def not(client_id:)
      @excluded_id = client_id
      self
    end

    def exists?
      @rows.any? { |row| row.name == @name && row.client_id != @excluded_id }
    end
  end

  attr_reader :client_id, :secret, :secret_updates
  attr_accessor :name, :is_default, :attributes

  class << self
    attr_accessor :rows

    def transaction
      yield
    end

    def where(name:)
      Scope.new(rows, name)
    end

    def find_by(client_id:)
      rows.find { |row| row.client_id == client_id }
    end
  end

  def initialize(client_id:, name: nil, secret: nil, is_default: nil)
    @client_id = client_id
    @name = name
    @secret = secret
    @is_default = is_default
    @secret_updates = 0
    @attributes = {}
  end

  def persisted?
    self.class.rows.include?(self)
  end

  def assign_attributes(attrs)
    @attributes = attrs
    @name = attrs.fetch(:name)
    @is_default = attrs.fetch(:is_default)
  end

  def check_secret(value)
    @secret == value
  end

  def is_default?
    @is_default == true
  end

  def set_secret(value)
    @secret = value
    @secret_updates += 1
  end

  def save!
    self.class.rows << self unless persisted?
  end
end

class DevclusterWebuiSeedTest < Minitest::Test
  SEED = File.expand_path('../dev-clusters/vpsadmin/nix/webui-oauth-seed.rb', __dir__)
  CLIENT_ID = 'a' * 64
  SECRET = 'b' * 64

  def setup
    @previous_model = Object.const_defined?(:Oauth2Client) ? Object.const_get(:Oauth2Client) : nil
    Object.send(:remove_const, :Oauth2Client) if @previous_model
    Object.const_set(:Oauth2Client, FakeOauth2Client)
    FakeOauth2Client.rows = []
  end

  def teardown
    Object.send(:remove_const, :Oauth2Client)
    Object.const_set(:Oauth2Client, @previous_model) if @previous_model
  end

  def test_seed_is_repeatable_and_preserves_php_default
    php = FakeOauth2Client.new(client_id: 'vpsadmin-webui-test', name: 'PHP WebUI',
                               secret: 'php-secret', is_default: true)
    FakeOauth2Client.rows << php
    with_credentials do
      load SEED
      webui = FakeOauth2Client.find_by(client_id: CLIENT_ID)
      assert_equal(FakeOauth2Client::NAME, webui.name)
      assert_equal(false, webui.is_default)
      assert_equal(1200, webui.attributes.fetch(:access_token_seconds))
      assert_equal(2_592_000, webui.attributes.fetch(:refresh_token_seconds))
      assert_equal(true, webui.attributes.fetch(:issue_refresh_token))
      assert_equal(false, webui.attributes.fetch(:authorization_start_requires_user_action))
      assert_equal(true, webui.attributes.fetch(:allow_single_sign_on))
      assert_equal('https://newadmin.example.test/oauth/callback', webui.attributes.fetch(:redirect_uri))
      load SEED
      assert_equal(2, FakeOauth2Client.rows.size)
      assert_same(webui, FakeOauth2Client.find_by(client_id: CLIENT_ID))
      assert_equal(1, webui.secret_updates)
      assert_equal('php-secret', php.secret)
      assert_equal(true, php.is_default)
    end
  end

  def test_client_id_collision_refuses_before_mutation
    php = FakeOauth2Client.new(client_id: CLIENT_ID, name: 'PHP WebUI',
                               secret: 'php-secret', is_default: true)
    FakeOauth2Client.rows << php
    with_credentials do
      assert_raises(RuntimeError) { load SEED }
      assert_equal('PHP WebUI', php.name)
      assert_equal('php-secret', php.secret)
      assert_equal(true, php.is_default)
      assert_equal(0, php.secret_updates)
    end
  end

  def test_retained_name_with_other_id_refuses_before_mutation
    existing = FakeOauth2Client.new(client_id: 'c' * 64, name: FakeOauth2Client::NAME,
                                    secret: 'existing', is_default: false)
    FakeOauth2Client.rows << existing
    with_credentials do
      assert_raises(RuntimeError) { load SEED }
      assert_nil(FakeOauth2Client.find_by(client_id: CLIENT_ID))
      assert_equal('existing', existing.secret)
      assert_equal(0, existing.secret_updates)
    end
  end

  def test_existing_default_with_retained_name_and_id_is_not_repurposed
    existing = FakeOauth2Client.new(client_id: CLIENT_ID, name: FakeOauth2Client::NAME,
                                    secret: 'existing', is_default: true)
    FakeOauth2Client.rows << existing
    with_credentials do
      assert_raises(RuntimeError) { load SEED }
      assert_equal(true, existing.is_default)
      assert_equal('existing', existing.secret)
      assert_equal(0, existing.secret_updates)
    end
  end

  private

  def with_credentials
    Dir.mktmpdir('webui-seed-test') do |directory|
      File.write(File.join(directory, 'oauth-client-id'), "#{CLIENT_ID}\n")
      File.write(File.join(directory, 'oauth-client-secret'), "#{SECRET}\n")
      previous = ENV.to_h.slice('CREDENTIALS_DIRECTORY', 'DEVCLUSTER_WEBUI_ORIGIN')
      ENV['CREDENTIALS_DIRECTORY'] = directory
      ENV['DEVCLUSTER_WEBUI_ORIGIN'] = 'https://newadmin.example.test'
      yield
    ensure
      %w[CREDENTIALS_DIRECTORY DEVCLUSTER_WEBUI_ORIGIN].each do |key|
        previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key)
      end
    end
  end
end
