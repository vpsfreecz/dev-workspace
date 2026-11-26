# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

module DevClusters
  # Called under the provider's cluster lock; registration remains read-only.
  class VpsAdminSourceSelection
    Invalid = Class.new(StandardError)

    def self.resolve(workspace, slug, config_path)
      name = JSON.parse(File.read(config_path))['vpsadminosWorktree']
      directory = File.join(workspace, 'worktrees', slug)
      if name.nil?
        legacy = File.join(directory, 'vpsadminos')
        return File.directory?(legacy) ? legacy : ''
      end

      unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
        raise Invalid, 'vpsadminosWorktree must name a registered worktree'
      end

      manifest = YAML.safe_load_file(File.join(workspace, 'work', slug, 'portal.yml'))
      unless manifest.is_a?(Hash) && manifest['slug'] == slug && manifest['repositories'].is_a?(Array)
        raise Invalid, 'vpsadminosWorktree requires this session\'s repository registration'
      end
      entries = manifest['repositories'].select { |entry| entry.is_a?(Hash) && entry['name'] == name }
      unless entries.length == 1 && entries.first['project'] == 'vpsadminos'
        raise Invalid, 'vpsadminosWorktree must select exactly one registered vpsadminos repository'
      end

      path = File.join(directory, name)
      unless File.directory?(path) && File.realpath(path) == path
        raise Invalid, 'vpsadminosWorktree path is missing or contains a symlink'
      end
      unless git(path, 'rev-parse', '--show-toplevel') == path &&
             git(path, 'rev-parse', '--path-format=absolute', '--git-common-dir') ==
               File.realpath(File.join(workspace, 'repos', 'vpsadminos.git'))
        raise Invalid, 'vpsadminosWorktree is not a worktree of the canonical vpsadminos repository'
      end
      branch = entries.first['branch']
      unless branch.is_a?(String) && !branch.empty? && git(path, 'symbolic-ref', '--quiet', '--short', 'HEAD') == branch
        raise Invalid, 'vpsadminosWorktree branch does not match its registration'
      end

      path
    end

    def self.git(path, *args)
      stdout, _stderr, status = Open3.capture3('git', '-C', path, *args)
      raise Invalid, 'vpsadminosWorktree Git identity is unavailable' unless status.success?

      stdout.strip
    end
    private_class_method :git
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts DevClusters::VpsAdminSourceSelection.resolve(*ARGV)
  rescue DevClusters::VpsAdminSourceSelection::Invalid, JSON::ParserError, Psych::Exception, SystemCallError => e
    warn "error: vpsadminosWorktree selection failed: #{e.message}"
    exit 1
  end
end
