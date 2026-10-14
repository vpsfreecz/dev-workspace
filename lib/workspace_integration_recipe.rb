# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'tempfile'

# Immutable pin-generation and read-only semantic verification. Site input names
# and channel mappings come from the consuming workspace's integration catalog.
module WorkspaceIntegrationRecipe
  LIMIT = 262_144

  def self.capture(source, *argv)
    out, error, status = Open3.capture3(*argv, chdir: source)
    raise error.byteslice(0, 4096) unless status.success?
    raise 'recipe output exceeds protocol limit' if out.bytesize > LIMIT
    out
  end

  def self.git(source, *argv)
    capture(source, 'git', *argv).strip
  end

  def self.lock(source, revision)
    JSON.parse(capture(source, 'git', 'show', "#{revision}:flake.lock"))
  end

  def self.node(graph, path, depth = 0)
    raise 'cyclic input path' if depth > 32
    current = graph.fetch('root')
    path.each do |part|
      value = graph.fetch('nodes').fetch(current).fetch('inputs').fetch(part)
      current = value.is_a?(Array) ? node(graph, value, depth + 1) : value
    end
    current
  end

  def self.normalized(graph, excluded, current = graph.fetch('root'), path = [], depth = 0)
    raise 'input graph exceeds depth' if depth > 32
    return {'managedInput' => true} if path == excluded
    value = graph.fetch('nodes').fetch(current)
    value.reject { |key, _| key == 'inputs' }.merge('inputs' => value.fetch('inputs', {}).sort.to_h do |name, reference|
      resolved = reference.is_a?(Array) ? node(graph, reference) : reference
      child = normalized(graph, excluded, resolved, path + [name], depth + 1)
      [name, {'follows' => reference.is_a?(Array) ? reference : nil, 'value' => child}]
    end)
  end

  def self.verify(source, from, to, parameters, heads)
    path = parameters.fetch('inputPath')
    raise 'inputPath must be a nonempty string list' unless path.is_a?(Array) && !path.empty? && path.all? { |part| part.is_a?(String) && part.match?(/\A[A-Za-z0-9_-]+\z/) }
    expected = heads.fetch(parameters.fetch('repository'))
    raise 'expected source is not an exact revision' unless expected.match?(/\A[0-9a-f]{40}\z/)
    old_graph, new_graph = lock(source, from), lock(source, to)
    raise 'generated lock changes unrelated inputs or follows' unless normalized(old_graph, path) == normalized(new_graph, path)
    selected = new_graph.fetch('nodes').fetch(node(new_graph, path)).fetch('locked')
    original = old_graph.fetch('nodes').fetch(node(old_graph, path)).fetch('locked')
    remote_fields = %w[type owner repo url dir submodules]
    raise 'pin refresh changes the managed source identity' unless original.slice(*remote_fields) == selected.slice(*remote_fields)
    raise 'generated lock does not select the exact reviewed source' unless selected['rev'] == expected && selected['narHash'].is_a?(String)
    changed = git(source, 'diff', '--name-only', from, to).lines.map(&:strip)
    raise 'pin refresh changes unrelated files' unless changed.all? { |name| %w[flake.nix flake.lock].include?(name) || name.match?(%r{\A(?:work|archive|notes)/}) }
    if changed.include?('flake.nix')
      pattern = /((?:#{Regexp.escape(parameters.fetch('urlAttribute'))})\s*=\s*")[^"]+(";)/
      old_nix = capture(source, 'git', 'show', "#{from}:flake.nix")
      new_nix = capture(source, 'git', 'show', "#{to}:flake.nix")
      raise 'pin refresh changes unrelated Nix declarations' unless old_nix.sub(pattern, '\\1MANAGED\\2') == new_nix.sub(pattern, '\\1MANAGED\\2')
    end
    {'schema' => 1, 'relation' => 'generated_pin', 'from' => from, 'to' => to,
      'parameters' => parameters, 'heads' => heads, 'selected' => selected,
      'unmanagedDigest' => Digest::SHA256.hexdigest(JSON.generate(normalized(new_graph, path)))}
  end

  def self.run(bytes)
    raise 'recipe request exceeds limit' if bytes.bytesize > LIMIT
    request = JSON.parse(bytes)
    raise 'unsupported recipe protocol' unless request['schema'] == 1 && %w[refresh verify].include?(request['action'])
    source, parameters, heads = request.values_at('source', 'parameters', 'heads')
    raise 'recipe requires an existing source' unless source.is_a?(String) && File.directory?(source)
    from = request.fetch('from')
    if request['action'] == 'refresh'
      unless git(source, 'status', '--porcelain').empty? && git(source, 'rev-parse', 'HEAD') == request.fetch('toBase')
        raise 'recipe requires the exact clean prepared target'
      end
      revision = heads.fetch(parameters.fetch('repository'))
      case parameters.fetch('type')
      when 'confctl_channel'
        capture(source, 'nix', 'develop', '--command', 'confctl', 'inputs', 'channel', 'set', '--commit',
          parameters.fetch('channel'), parameters.fetch('role'), revision)
      when 'nix_input'
        file = File.join(source, 'flake.nix')
        pattern = /(#{Regexp.escape(parameters.fetch('urlAttribute'))}\s*=\s*")[^"]+(";)/
        text = File.read(file)
        raise 'managed URL declaration is absent or ambiguous' unless text.scan(pattern).length == 1
        File.write(file, text.sub(pattern) { "#{Regexp.last_match(1)}#{parameters.fetch('urlPrefix')}/#{revision}#{Regexp.last_match(2)}" })
        capture(source, 'nix', 'flake', 'update', parameters.fetch('inputPath').join('/'))
        capture(source, 'git', 'add', '--', 'flake.nix', 'flake.lock')
        unless git(source, 'diff', '--cached', '--name-only').empty?
          Tempfile.create('integration-pin-message') do |message|
            message.write("inputs: refresh reviewed workspace runtime\n\nRegenerate the managed runtime selection on the current target while\npreserving unrelated inputs and the declared dependency graph.\n")
            message.flush
            capture(source, 'git', 'commit', '-F', message.path)
          end
        end
      else raise 'unsupported pin recipe type'
      end
    end
    head = request['action'] == 'verify' ? request.fetch('to') : git(source, 'rev-parse', 'HEAD')
    proof = verify(source, from, head, parameters, heads)
    {'schema' => 1, 'verified' => true, 'head' => head, 'proof' => proof}
  end
end
