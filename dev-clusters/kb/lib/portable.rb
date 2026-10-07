# frozen_string_literal: true

require 'digest'
require_relative 'managed'

module DevClusters
  module Kb
    # Read-only validation uses the exact selected engine's own receipt rules.
    # Lifecycle and live attestation are always performed by its packaged CLI.
    class Portable
      def initialize(binding:, metadata_path:)
        @binding, @metadata_path = binding, metadata_path
        metadata = JSON.parse(File.read(metadata_path))
        source = metadata.fetch('source')
        raise Error, 'packaged immutable KB source is required' unless source.start_with?('/nix/store/') && File.directory?(source)

        require File.join(source, 'cluster', 'lib', 'kb_runtime')
        begin
          @software = KbRuntime::Software.new(metadata)
          @state = KbRuntime::State.new(binding.state_root, binding.slug)
          @engine = KbRuntime::Engine.new(state: @state, software: @software, controller: [])
        rescue KbRuntime::Error => error
          raise Error, error.message
        end
      rescue JSON::ParserError, KeyError, SystemCallError => error
        raise Error, "invalid packaged KB metadata: #{error.message}"
      end

      def revision
        @software.metadata.fetch('revision')
      end

      def snapshot
        @binding.read
        @state.transaction(create: false, wait: false) do
          @state.identity
          yield
        end
      rescue KbRuntime::Busy => error
        raise Busy, error.message
      rescue KbRuntime::Error => error
        raise Error, error.message
      rescue KeyError, SystemCallError => error
        raise Error, "invalid owned KB snapshot: #{error.message}"
      end

      def validate_record(record, run)
        raise Error, 'invalid recorded run identity' unless KbRuntime::State::UUID.match?(run.to_s)

        @engine.validate_launch(record, run)
        expected = @engine.resources.socket_dir(record.fetch('instance_id'), run)
        raise Error, 'recorded socket namespace differs' unless record['socket_dir'] == expected

        record
      end

      def canonical
        snapshot do
          record = validate_record(@engine.launch, @engine.phase.fetch('run_id'))
          raise Error, 'managed KB cluster is not ready' unless @engine.ready?(record)

          validate_artifact(record)
          bytes = @state.file(@state.path('connection.json'))
          value = JSON.parse(bytes)
          argv = value.fetch('control').fetch('argv')
          suffix = ['--state-root', @state.root, 'capture-lease', @state.slug]
          prefix = [File.join(@software.source, 'cluster', 'launcher.rb'), '--software-metadata', @metadata_path]
          unless argv.is_a?(Array) && argv.size == 8 && argv.first.is_a?(String) && argv.first.start_with?('/nix/store/') &&
                 argv.first.end_with?('/bin/ruby') && argv[1, 3] == prefix && argv.last(4) == suffix
            raise Error, 'canonical controller is not the selected packaged engine'
          end
          expected = @engine.descriptor(record).merge('control' => { 'argv' => argv })
          raise Error, 'canonical descriptor differs from the owned launch' unless value == expected

          [bytes, value]
        end
      rescue JSON::ParserError, KeyError => error
        raise Error, "invalid canonical KB descriptor: #{error.message}"
      end

      def validate_artifact(record, selected: true)
        artifact = @engine.artifact(record)
        validator = if selected
                      @engine
                    else
                      # Creation provenance is retained. Selected code validates
                      # the original artifact without granting capture readiness.
                      original = KbRuntime::Software.new(artifact.fetch('source'))
                      KbRuntime::Engine.new(state: @state, software: original, controller: [])
                    end
        validator.validate_prepared(artifact)
        artifact.each do |key, value|
          next if key == 'schema' # artifact schema 1, launch identity schema 2

          raise Error, "launch #{key} differs from its artifact" unless record[key] == value
        end
        artifact
      end

      def inventory
        snapshot do
          paths = [@state.directory, @binding.record_directory]
          Dir.children(@state.directory).sort.each do |name|
            next unless name.start_with?('reservation-', 'launch-') && name.end_with?('.json')

            run = name.delete_prefix('reservation-').delete_prefix('launch-').delete_suffix('.json')
            record = validate_record(@state.read(@state.path(name)), run)
            paths << record.fetch('socket_dir')
          end
          { 'schema' => 1, 'paths' => paths.uniq }
        end
      end

      def transition_adopt
        snapshot do
          record = validate_record(@engine.launch, @engine.phase.fetch('run_id'))
          artifact = validate_artifact(record, selected: false)
          unless artifact['schema'] == 1 && artifact.fetch('guest_identity')['schema'] == 1 &&
                 record.fetch('source') == artifact.fetch('source') && (@engine.live?(record) || @engine.gone?(record))
            raise Error, 'incompatible or ambiguous retained KB engine state'
          end
          inventory_records = Dir.children(@state.directory).grep(/\A(?:reservation|launch)-.*\.json\z/)
          inventory_records.each do |name|
            run = name.delete_prefix('reservation-').delete_prefix('launch-').delete_suffix('.json')
            validate_record(@state.read(@state.path(name)), run)
          end
          true
        end
      end
    end
  end
end
