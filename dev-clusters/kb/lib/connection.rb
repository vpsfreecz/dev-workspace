# frozen_string_literal: true

require 'digest'
require_relative 'managed'

module DevClusters
  module Kb
    # Constructed only after the selected engine validates the full canonical
    # descriptor. There is no alternate digest accepted by the portable engine.
    class Connection
      IDENTITY_FIELDS = %w[instance_id run_id artifact_id artifact_sha256].freeze
      attr_reader :canonical_sha256, :managed_sha256, :bytes, :value

      def initialize(canonical_bytes:, public_argv:)
        @canonical_sha256 = Digest::SHA256.hexdigest(canonical_bytes)
        @value = JSON.parse(canonical_bytes)
        raise Error, 'unsupported canonical descriptor' unless @value.is_a?(Hash) && @value['schema'] == 1 && @value['kind'] == 'vpsfree-kb-connection'
        raise Error, 'canonical controller is missing' unless @value.fetch('control').keys == ['argv']

        managed = @value.merge('control' => { 'argv' => public_argv })
        @bytes = JSON.generate(sorted(managed)) + "\n"
        @managed_sha256 = Digest::SHA256.hexdigest(@bytes)
      rescue JSON::ParserError, KeyError
        raise Error, 'invalid canonical descriptor'
      end

      def sorted(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, sorted(value.fetch(key))] }
        when Array
          value.map { |item| sorted(item) }
        else
          value
        end
      end

      def canonical_readiness
        { 'schema' => 1, **value.slice(*IDENTITY_FIELDS), 'descriptor_sha256' => canonical_sha256 }
      end

      def require_request!(request)
        expected = value.slice(*IDENTITY_FIELDS).merge('descriptor_sha256' => managed_sha256)
        raise Error, 'managed lease request differs from the current descriptor' unless request == expected
      end

      def lease_arguments
        IDENTITY_FIELDS.flat_map { |key| ["--#{key.tr('_', '-')}", value.fetch(key)] } +
          ['--descriptor-sha256', canonical_sha256]
      end
    end
  end
end
