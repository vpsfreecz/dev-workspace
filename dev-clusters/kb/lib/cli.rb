# frozen_string_literal: true

require 'optparse'
require_relative 'guards'
require_relative 'portable'
require_relative 'provider'

module DevClusters
  module Kb
    class CLI
      USAGE = <<~TEXT.freeze
        Usage: kb-devcluster [--workspace NAME] COMMAND SLUG [options]
          start SLUG [--topology NAME] [--network bridge|local] [--config FILE]
          resume SLUG [--timeout SECONDS]
          update SLUG [--topology NAME] [--network bridge|local] [--config FILE]
          stop SLUG [--timeout SECONDS]
          status SLUG --json
          connection SLUG
          capture-lease SLUG --instance-id ID --run-id ID --artifact-id ID
            --artifact-sha256 SHA --descriptor-sha256 SHA
          config SLUG
          refresh SLUG
          ssh SLUG MACHINE -- COMMAND [ARGUMENT...]
          reset SLUG
          cleanup-paths SLUG
          transition-adopt SLUG
      TEXT

      def self.run(arguments, environment: ENV, input: $stdin, output: $stdout, error: $stderr)
        return output.write(USAGE) && 0 if arguments == ['--help'] || arguments == ['-h']

        command, slug, *rest = arguments
        raise Error, 'command and session slug are required' unless command && slug

        workspace = environment.fetch('DEVCLUSTER_WORKSPACE')
        name = environment.fetch('DEV_WORKSPACE_NAME')
        raise Error, 'explicit registered workspace name is required' unless /\A[a-z0-9][a-z0-9-]{0,62}\z/.match?(name)

        binding = Binding.new(workspace:, slug:)
        portable = Portable.new(binding:, metadata_path: environment.fetch('VPSFREE_KB_ENGINE_METADATA'))
        contract = JSON.parse(File.read(environment.fetch('DEVCLUSTER_RUNTIME_CONTRACT')))
        guards = Guards.new(binding:, contract:, environment:)
        public_argv = [File.join(environment.fetch('HOME'), 'bin/kb-devcluster'), '--workspace', name, 'capture-lease', slug]
        provider = Provider.new(binding:, engine: environment.fetch('VPSFREE_KB_ENGINE'), portable:, public_argv:)

        case command
        when 'cleanup-paths'
          raise Error, 'unexpected cleanup-paths arguments' unless rest.empty?
          # The generic removal caller holds its session lock and passes no FD.
          # This positive inventory does not enter a recursive session guard.
          value = if binding.present?(binding.path)
                    guards.adapter { provider.cleanup_paths }
                  else
                    provider.cleanup_paths
                  end
          output.puts(JSON.generate(value))
        when 'transition-adopt'
          raise Error, 'unexpected transition-adopt arguments' unless rest.empty?
          guards.adapter { provider.transition_adopt }
        when 'status'
          raise Error, 'unexpected status arguments' unless rest.empty? || rest == ['--json']
          value = binding.present?(binding.path) ? guards.adapter { provider.status } : provider.status
          output.puts(JSON.generate(value))
        else
          guards.session(command) do
            guards.adapter(create: command == 'start') do
              case command
              when 'start', 'update', 'resume', 'stop'
                flags = operation_flags(command, rest, environment)
                value = command == 'start' ? provider.start(*flags) : provider.existing(command, *flags)
                output.write(value)
              when 'connection'
                raise Error, 'unexpected connection arguments' unless rest.empty?
                output.write(provider.connection)
              when 'capture-lease'
                request = lease_request(rest)
                provider.capture_lease(request, input:, output:, error:)
              when 'config', 'refresh'
                raise Error, "unexpected #{command} arguments" unless rest.empty?
                output.write(provider.existing(command))
              when 'ssh'
                machine, *remote = rest
                raise Error, 'machine and explicit -- separator are required' unless machine && remote.shift == '--'
                output.write(provider.existing(command, machine, '--', *remote))
              when 'reset'
                raise Error, 'unexpected reset arguments' unless rest.empty?
                output.write(provider.reset)
              else
                raise Error, "unsupported command: #{command}"
              end
            end
          end
        end
        0
      rescue Busy => failure
        error.puts(failure.message)
        75
      rescue Error, KeyError, OptionParser::ParseError, JSON::ParserError, SystemCallError => failure
        error.puts("error: #{failure.message}")
        1
      end

      def self.operation_flags(command, arguments, environment)
        values = {}
        parser = OptionParser.new do |options|
          options.on('--timeout SECONDS', Integer) { |v| values['--timeout'] = v.to_s }
          if %w[start update].include?(command)
            options.on('--topology NAME') { |v| values['--topology'] = v }
            options.on('--network MODE') { |v| values['--network'] = v }
            options.on('--config FILE') { |v| values['--config'] = v }
          end
        end
        parser.parse!(arguments)
        raise Error, 'unexpected lifecycle arguments' unless arguments.empty?
        values['--config'] ||= environment.fetch('VPSFREE_KB_DEFAULT_CONFIG') if %w[start update].include?(command)
        values.to_a.flatten
      end

      def self.lease_request(arguments)
        value = {}
        parser = OptionParser.new do |options|
          %w[instance_id run_id artifact_id artifact_sha256 descriptor_sha256].each do |key|
            options.on("--#{key.tr('_', '-')} VALUE") { |entry| value[key] = entry }
          end
        end
        parser.parse!(arguments)
        raise Error, 'unexpected capture-lease arguments' unless arguments.empty?
        value
      end
    end
  end
end
