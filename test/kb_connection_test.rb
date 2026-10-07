# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev-clusters/kb/lib/connection'

class KbConnectionTest < Minitest::Test
  def descriptor
    { 'schema' => 1, 'kind' => 'vpsfree-kb-connection',
      'instance_id' => 'instance', 'run_id' => 'run', 'artifact_id' => 'artifact', 'artifact_sha256' => 'a' * 64,
      'services' => { 'webui' => { 'url' => 'https://webui.example.test/', 'connect_host' => '127.0.0.1', 'connect_port' => 28443 } },
      'machines' => { 'services' => { 'host' => '127.0.0.1', 'port' => 28022, 'private_key' => '/private/key', 'known_hosts' => '/private/known-hosts' } },
      'provenance' => { 'source' => { 'revision' => 'b' * 40 } },
      'control' => { 'argv' => ['/selected/engine', 'capture-lease', 'session'] } }
  end

  def public_argv
    ['/home/test/bin/kb-devcluster', '--workspace', 'example', 'capture-lease', 'session']
  end

  def test_changes_only_public_control_and_keeps_exact_canonical_byte_digest
    canonical = JSON.pretty_generate(descriptor) + "\n"
    connection = DevClusters::Kb::Connection.new(canonical_bytes: canonical, public_argv:)
    managed = JSON.parse(connection.bytes)
    assert_equal(descriptor.reject { |key, _value| key == 'control' }, managed.reject { |key, _value| key == 'control' })
    assert_equal({ 'argv' => public_argv }, managed.fetch('control'))
    assert_equal(Digest::SHA256.hexdigest(canonical), connection.canonical_sha256)
    assert_equal(Digest::SHA256.hexdigest(connection.bytes), connection.managed_sha256)
    refute_equal(connection.canonical_sha256, connection.managed_sha256)
    assert_equal(['/selected/engine', 'capture-lease', 'session'], connection.value.fetch('control').fetch('argv'))
    reordered = descriptor.to_a.reverse.to_h
    again = DevClusters::Kb::Connection.new(canonical_bytes: JSON.generate(reordered), public_argv:)
    assert_equal(connection.bytes, again.bytes)
    refute_equal(connection.canonical_sha256, again.canonical_sha256)
  end

  def test_request_matches_current_managed_identity_and_never_substitutes_canonical_digest
    connection = DevClusters::Kb::Connection.new(canonical_bytes: JSON.generate(descriptor), public_argv:)
    request = descriptor.slice(*DevClusters::Kb::Connection::IDENTITY_FIELDS).merge('descriptor_sha256' => connection.managed_sha256)
    connection.require_request!(request)
    %w[instance_id run_id artifact_id artifact_sha256 descriptor_sha256].each do |key|
      assert_raises(DevClusters::Kb::Error) { connection.require_request!(request.merge(key => 'stale')) }
    end
    assert_raises(DevClusters::Kb::Error) do
      connection.require_request!(request.merge('descriptor_sha256' => connection.canonical_sha256))
    end
    assert_equal(connection.canonical_sha256, connection.lease_arguments.last)
    refute_includes(connection.lease_arguments, connection.managed_sha256)
    assert_equal(connection.canonical_sha256, connection.canonical_readiness.fetch('descriptor_sha256'))
  end

  def test_current_source_artifact_endpoint_or_binding_selection_changes_invalidate_managed_digest
    original = DevClusters::Kb::Connection.new(canonical_bytes: JSON.generate(descriptor), public_argv:)
    candidates = [
      descriptor.merge('artifact_id' => 'replacement'),
      descriptor.merge('provenance' => { 'source' => { 'revision' => 'c' * 40 } }),
      descriptor.merge('services' => { 'webui' => { 'url' => 'https://other.example.test/', 'connect_host' => '127.0.0.1', 'connect_port' => 28444 } })
    ]
    candidates.each do |value|
      changed = DevClusters::Kb::Connection.new(canonical_bytes: JSON.generate(value), public_argv:)
      refute_equal(original.managed_sha256, changed.managed_sha256)
    end
    changed_binding = DevClusters::Kb::Connection.new(canonical_bytes: JSON.generate(descriptor), public_argv: [public_argv.first, '--workspace', 'other', 'capture-lease', 'session'])
    refute_equal(original.managed_sha256, changed_binding.managed_sha256)
  end
end
