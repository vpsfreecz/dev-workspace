# frozen_string_literal: true

require 'open3'
require_relative 'managed'
require_relative 'connection'
require_relative 'lease'

module DevClusters
  module Kb
    class Provider
      def initialize(binding:, engine:, portable: nil, public_argv: nil)
        unless engine.is_a?(String) && engine.start_with?('/') && File.file?(engine) && File.executable?(engine)
          raise Error, 'packaged KB engine is unavailable'
        end

        @binding = binding
        @engine = engine
        @portable, @public_argv = portable, public_argv
      end

      def invoke(command, *arguments)
        output, error, status = Open3.capture3(@engine, '--state-root', @binding.state_root,
          command, @binding.slug, *arguments, close_others: true)
        raise Busy, 'KB cluster is changing' if status.exitstatus == 75
        raise Error, "KB engine #{command} failed: #{error.strip}" unless status.success?

        output
      end

      def start(*arguments)
        if @binding.present?(@binding.path)
          @binding.read
        else
          @binding.create(engine_revision: @portable.revision)
        end
        invoke('start', *arguments)
      end

      def existing(command, *arguments)
        @binding.read
        invoke(command, *arguments)
      end

      def managed_connection
        canonical, = @portable.canonical
        Connection.new(canonical_bytes: canonical, public_argv: @public_argv)
      end

      def connection
        value = managed_connection
        @binding.write_bytes(File.join(@binding.record_directory, 'connection.json'), value.bytes)
      end

      def capture_lease(request, input: $stdin, output: $stdout, error: $stderr)
        value = managed_connection
        value.require_request!(request)
        # canonical's noncreating snapshot has returned and released K locks.
        # The fixed CLI acquires its own gate and rechecks the exact C digest.
        Lease.new(argv: [@engine, '--state-root', @binding.state_root, 'capture-lease', @binding.slug,
                        *value.lease_arguments], canonical: value.canonical_readiness,
                  managed: value.managed_sha256, input:, output:, error:).run
      end

      def cleanup_paths
        unless @binding.present?(@binding.path)
          if @binding.present?(@binding.cluster_directory) || @binding.present?(@binding.record_directory)
            raise Error, 'partial or unbound managed KB state'
          end
          return { 'schema' => 1, 'paths' => [] }
        end
        @portable.inventory
      end

      def transition_adopt
        @binding.read
        @portable.transition_adopt
      end

      def reset
        @binding.read
        files = Dir.children(@binding.record_directory).sort
        raise Error, 'unknown managed KB binding files' unless (files - %w[binding.json connection.json]).empty?
        files.each { |name| @binding.read_file(File.join(@binding.record_directory, name), limit: 2 * 1024 * 1024) }
        invoke('stop') if @binding.present?(@binding.cluster_directory)
        invoke('reset') if @binding.present?(@binding.cluster_directory)
        raise Error, 'KB reset left its owned instance in place' if @binding.present?(@binding.cluster_directory)

        files.each { |name| File.unlink(File.join(@binding.record_directory, name)) }
        Dir.rmdir(@binding.record_directory)
        File.open(File.dirname(@binding.record_directory), &:fsync)
        ''
      end

      def engine_json(command, *arguments)
        output, error, status = Open3.capture3(
          'timeout', '--kill-after=1', '4', @engine,
          '--state-root', @binding.state_root, command, @binding.slug, *arguments,
          close_others: true
        )
        raise Busy, 'KB cluster is changing' if status.exitstatus == 75 || status.exitstatus == 124
        raise Error, "KB engine #{command} failed: #{error.strip}" unless status.success?
        raise Error, 'KB engine response exceeds limit' if output.bytesize > 2 * 1024 * 1024

        JSON.parse(output)
      rescue JSON::ParserError
        raise Error, 'KB engine response is invalid JSON'
      end

      def status
        unless @binding.present?(@binding.path)
          if @binding.present?(@binding.cluster_directory) || @binding.present?(@binding.record_directory)
            raise Error, 'KB state exists without its managed binding'
          end

          return { 'schema' => 2, 'kind' => 'kb', 'found' => false }
        end
        @binding.read
        value = engine_json('status', '--json')
        unless value.is_a?(Hash) && value['schema'] == 2 && [true, false].include?(value['found'])
          raise Error, 'KB engine status has an unsupported schema'
        end
        return { 'schema' => 2, 'kind' => 'kb', 'found' => false } unless value['found']

        ready = value['ready'] == true
        state = if ready
                  'running'
                elsif value['state'] == 'stopped'
                  'stopped'
                else
                  'stale'
                end
        { 'schema' => 2, 'kind' => 'kb', 'found' => true, 'state' => state, 'ready' => ready,
          'commands' => [], 'services' => [] }
      end
    end
  end
end
