# frozen_string_literal: true

require_relative 'managed'

module DevClusters
  module Kb
    # Session guards precede the adapter and portable engine locks. Inventory
    # callers already hold the session lock and must not recursively acquire it.
    class Guards
      def initialize(binding:, contract:, environment: ENV)
        @binding, @contract, @environment = binding, contract, environment
        unless contract['trackingMaxBytes'].is_a?(Integer) && contract['trackingMaxBytes'].positive? &&
               contract.dig('clusterProvider', 'statusBusyExitCode') == 75 &&
               contract['lifecycleJournals'].is_a?(Array) &&
               contract['lifecycleJournals'].map { |row| row['command'] }.sort == %w[archive delete revive] &&
               contract['lifecycleJournals'].all? { |row| row.keys.sort == %w[command name] && SLUG.match?(row['name'].to_s) }
          raise Error, 'unsupported workspace runtime contract'
        end
      end

      def active_session!
        path = File.join(@binding.workspace, 'work', @binding.slug, 'state.md')
        @binding.check_ancestors(File.dirname(path))
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.size <= @contract.fetch('trackingMaxBytes')
          raise Error, 'unsafe or missing active session state'
        end
        header = File.open(path, File::RDONLY | File::NOFOLLOW) { |stream| stream.each_line.take(3).map(&:chomp) }
        raise Error, 'development session is not active' unless header == ['---', 'lifecycle: active', '---']
        archive = File.join(@binding.workspace, 'archive', @binding.slug)
        @binding.check_ancestors(File.dirname(archive))
        raise Error, 'development session also exists in the archive' if @binding.present?(archive)
      end

      def lifecycle_allowed!(command)
        @contract.fetch('lifecycleJournals').each do |row|
          path = File.join(@binding.workspace, 'worktrees', '.locks', "#{@binding.slug}.#{row['name']}.json")
          next unless @binding.present?(path)

          @binding.read_file(path, limit: @contract.fetch('trackingMaxBytes'))
          unless command == 'reset' && @environment['DEV_SESSION_LIFECYCLE_OPERATION'] == row['name'] &&
                 %w[archive delete].include?(row['command'])
            raise Error, 'development session has an unfinished lifecycle operation'
          end
          inherited_session_lock!
        end
      end

      def session_lock_path
        name = @environment['DEV_WORKSPACE_NAME']
        raise Error, 'explicit registered workspace selection is required' unless /\A[a-z0-9][a-z0-9-]{0,62}\z/.match?(name.to_s)

        runtime = @environment['DEV_WORKSPACES_RUNTIME_DIR'] ||
                  File.join(@environment['XDG_RUNTIME_DIR'] || "/run/user/#{Process.uid}", 'dev-workspaces')
        authority = File.join(runtime, name, 'authority', "#{@binding.slug}.lock")
        fallback = File.join(@binding.workspace, 'worktrees', '.locks', "#{@binding.slug}.lock")
        [authority, fallback]
      end

      def inherited_session_lock!
        descriptor = Integer(@environment.fetch('DEV_SESSION_LIFECYCLE_LOCK_FD', ''), 10)
        path = @environment['DEV_SESSION_LIFECYCLE_LOCK_PATH']
        raise Error, 'foreign lifecycle session lock' unless descriptor >= 3 && session_lock_path.include?(path)

        @binding.read_file(path, limit: 0)
        stream = File.for_fd(descriptor, autoclose: false)
        stat = File.lstat(path)
        raise Error, 'lifecycle lock descriptor differs' unless [stat.dev, stat.ino] == [stream.stat.dev, stream.stat.ino]

        File.open(path, File::RDWR | File::NOFOLLOW) do |probe|
          raise Error, 'lifecycle session lock is not held exclusively' if probe.flock(File::LOCK_SH | File::LOCK_NB)
        end
        raise Error, 'lifecycle session lock is not owned' unless stream.flock(File::LOCK_EX | File::LOCK_NB)
        true
      rescue ArgumentError, Errno::EBADF
        raise Error, 'lifecycle session lock is unavailable'
      end

      def session(command)
        inherited = command == 'reset' && @environment.key?('DEV_SESSION_LIFECYCLE_LOCK_FD')
        if inherited
          inherited_session_lock!
          lifecycle_allowed!(command)
          yield
        else
          path = session_lock_path.find { |candidate| @binding.present?(candidate) }
          raise Error, 'session lock is unavailable; start the development session first' unless path

          @binding.read_file(path, limit: 0)
          File.open(path, File::RDWR | File::NOFOLLOW) do |stream|
            raise Busy, 'development session is changing' unless stream.flock(File::LOCK_SH | File::LOCK_NB)
            active_session!
            lifecycle_allowed!(command)
            yield
          end
        end
      end

      def adapter(create: false)
        root = File.join(@binding.workspace, '.dev-clusters', '.locks')
        if create
          @binding.private_directory(root, create: true)
        elsif !@binding.private_directory(root)
          raise Error, 'adapter lock inventory is absent'
        end
        path = File.join(root, "kb-#{@binding.slug}.lock")
        if create && !@binding.present?(path)
          begin
            File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) {}
          rescue Errno::EEXIST
            # Validate the concurrent initializer below.
          end
        end
        @binding.read_file(path, limit: 0)
        stat = File.lstat(path)
        File.open(path, File::RDWR | File::NOFOLLOW) do |stream|
          raise Error, 'adapter lock changed during open' unless [stream.stat.dev, stream.stat.ino] == [stat.dev, stat.ino]
          raise Busy, 'managed KB cluster is changing' unless stream.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end
    end
  end
end
