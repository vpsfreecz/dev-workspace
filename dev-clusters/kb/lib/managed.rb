# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'

module DevClusters
  module Kb
    Error = Class.new(StandardError)
    Busy = Class.new(Error)
    SLUG = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/
    REVISION = /\A[0-9a-f]{40}\z/

    # The managed binding records workspace meaning outside portable K state.
    class Binding
      attr_reader :workspace, :slug, :state_root, :path, :record_directory

      def initialize(workspace:, slug:)
        raise Error, 'invalid KB session slug' unless slug.is_a?(String) && SLUG.match?(slug)

        @workspace = File.expand_path(workspace)
        check_ancestors(@workspace)
        raise Error, 'workspace path is not canonical' unless File.realpath(@workspace) == @workspace

        @slug = slug
        @state_root = File.join(@workspace, '.dev-clusters', 'kb')
        @record_directory = File.join(@state_root, 'bindings', slug)
        @path = File.join(@record_directory, 'binding.json')
      end

      def cluster_directory
        File.join(state_root, 'clusters', slug)
      end

      def present?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end

      def check_ancestors(path)
        current = File.expand_path(path)
        loop do
          raise Error, "symlink in managed state path: #{current}" if File.symlink?(current)
          raise Error, "invalid managed state ancestor: #{current}" if File.exist?(current) && !File.directory?(current)
          break if current == '/'

          current = File.dirname(current)
        end
      end

      def private_directory(path, create: false)
        check_ancestors(path)
        unless present?(path)
          return false unless create

          parent = File.dirname(path)
          private_directory(parent, create: true) unless File.directory?(parent)
          begin
            Dir.mkdir(path, 0o700)
          rescue Errno::EEXIST
            # Validate the concurrent initializer below.
          end
        end
        stat = File.lstat(path)
        unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
          raise Error, "unsafe managed private directory: #{path}"
        end
        true
      end

      def read_file(path, limit: 8192)
        check_ancestors(File.dirname(path))
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600 && stat.size <= limit
          raise Error, "unsafe managed private file: #{path}"
        end
        File.open(path, File::RDONLY | File::NOFOLLOW) do |stream|
          raise Error, 'managed file changed during open' unless [stream.stat.dev, stream.stat.ino] == [stat.dev, stat.ino]

          bytes = stream.read(limit + 1) || ''
          raise Error, 'managed file exceeds limit' if bytes.bytesize > limit

          bytes
        end
      end

      def read
        private_directory(state_root) || raise(Error, 'managed KB state is absent')
        private_directory(File.dirname(path)) || raise(Error, 'managed KB binding inventory is absent')
        private_directory(record_directory) || raise(Error, 'managed KB binding is absent')
        value = JSON.parse(read_file(path))
        expected = %w[schema workspace slug provider portable_schema engine_revision]
        unless value.is_a?(Hash) && value.keys.sort == expected.sort && value['schema'] == 1 &&
               value['workspace'] == workspace && value['slug'] == slug && value['provider'] == 'kb' &&
               value['portable_schema'] == 2 && REVISION.match?(value['engine_revision'].to_s)
          raise Error, 'unsupported or foreign managed KB binding'
        end
        value
      rescue JSON::ParserError
        raise Error, 'invalid managed KB binding JSON'
      end

      def create(engine_revision:)
        raise Error, 'KB engine revision is not exact' unless engine_revision.is_a?(String) && REVISION.match?(engine_revision)
        raise Error, 'managed KB state already exists without a new binding' if present?(cluster_directory) || present?(path)

        private_directory(state_root, create: true)
        private_directory(record_directory, create: true)
        value = { 'schema' => 1, 'workspace' => workspace, 'slug' => slug, 'provider' => 'kb',
                  'portable_schema' => 2, 'engine_revision' => engine_revision }
        write_bytes(path, JSON.generate(value) + "\n")
        read
      end

      def write_bytes(path, bytes)
        raise Error, 'invalid managed record path' unless File.dirname(path) == record_directory
        private_directory(record_directory) || raise(Error, 'managed KB binding directory is absent')
        read_file(path, limit: 2 * 1024 * 1024) if present?(path)
        temporary = "#{path}.#{SecureRandom.hex(12)}"
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |stream|
            stream.write(bytes)
            stream.flush
            stream.fsync
          end
          File.rename(temporary, path)
          File.open(File.dirname(path), &:fsync)
        ensure
          File.unlink(temporary) if File.exist?(temporary)
        end
        bytes
      end
    end
  end
end
