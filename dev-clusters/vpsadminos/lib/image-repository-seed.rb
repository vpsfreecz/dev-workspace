require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'stringio'
require 'rubygems/package'

# This command produces synthetic protocol fixtures, never runnable OS images.
class ImageRepositoryDemoSeed
  MARKER = "osctl-repo-server synthetic demo v1\n".freeze
  DEFAULTS = { 'default' => 'demo', 'demo' => 'minimal' }.freeze
  SOURCE = { sha: '0' * 40, input_digest: 'synthetic-demo-v1', ref: 'demo/fixtures', event: 'synthetic-demo' }.freeze

  def initialize(root, binary, lease)
    @root, @binary, @lease = root, binary, Integer(lease)
    @sockets = '/run/osctl-repo-server-demo'
  end

  def payload(version)
    ENV['SOURCE_DATE_EPOCH'] = '1'
    io = StringIO.new(''.b)
    text = "SYNTHETIC DEMO #{version}: not an operating system image.\n"
    Gem::Package::TarWriter.new(io) { |tar| tar.add_file_simple('DEMO.txt', 0o644, text.bytesize) { |f| f.write(text) } }
    io.string
  end

  def call(role, id, operation, params = {}, key = nil, bytes = ''.b)
    request = { request_id: "demo-v1-#{id}", operation: operation, repository: 'demo', params: params }
    request[:run_key] = key if key
    out, err, status = Open3.capture3(@binary, 'ctl', '--socket', "#{@sockets}/#{role}.sock",
                                    stdin_data: JSON.generate(request) + "\n" + bytes)
    response = JSON.parse(out)
    raise "Demo #{operation} failed: #{response['error'] || err.byteslice(0, 200)}" unless status.success? && response['ok']

    response.fetch('result')
  end

  def write_once(path, bytes)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    if File.exist?(path)
      raise "Existing demo fixture differs: #{path}" unless File.binread(path) == bytes
    else
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(bytes); f.fsync }
    end
  end

  def link_once(path, target)
    if File.symlink?(path)
      raise "Existing demo alias differs: #{path}" unless File.readlink(path) == target
    else
      File.symlink(target, path)
    end
  end

  def tuple(version)
    { vendor: 'demo', variant: 'minimal', arch: 'x86_64', distribution: 'synthetic', version: version }
  end

  def seed
    raise 'Refusing an unmarked repository root' unless File.file?("#{@root}/DEMO") && File.read("#{@root}/DEMO") == MARKER
    raise 'Demo lease must be between one hour and one day' unless (3600..86400).cover?(@lease)

    File.open("#{@root}/seed.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      raise 'Demo seed already running' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      seed_locked
    end
  end

  def seed_locked
    legacy = "#{@root}/fixture-import"
    images = %w[1 0].map do |version|
      relative = "demo/minimal/x86_64/synthetic/#{version}/image-archive.tar"
      write_once("#{legacy}/v1/#{relative}", payload(version))
      tuple(version).merge(tags: version == '1' ? %w[latest stable] : ['oldstable'], image: { tar: relative })
    end
    write_once("#{legacy}/v1/INDEX.json", JSON.generate(vendors: DEFAULTS, images: images))
    link_once("#{legacy}/v1/default", 'demo')
    link_once("#{legacy}/v1/demo/default", 'minimal')
    %w[latest stable].each { |tag| link_once("#{legacy}/v1/demo/minimal/x86_64/synthetic/#{tag}", '1') }
    link_once("#{legacy}/v1/demo/minimal/x86_64/synthetic/oldstable", '0')
    call('admin', 'import', 'import-legacy', { path: legacy, generation: '' })

    runs = {}
    %w[complete pending failed].each do |name|
      runs[name] = call('producer', "#{name}-begin", 'begin', {
        id: "synthetic-demo-#{name}", attempt: 1, source: SOURCE,
        expected: [{ id: 'synthetic', order: 0, tags: %w[latest stable] }],
        defaults: DEFAULTS, lease_seconds: @lease
      }).fetch('key')
    end
    %w[complete failed].each do |name|
      key = runs.fetch(name)
      call('producer', "#{name}-bind", 'bind', {
        item_id: 'synthetic', attempt: 1,
        descriptor: tuple('2').merge(formats: ['tar'], config_digest: 'synthetic-demo-v1')
      }, key)
      if name == 'complete'
        bytes = payload('2')
        call('producer', 'complete-upload', 'upload', {
          item_id: 'synthetic', attempt: 1, format: 'tar', sha256: Digest::SHA256.hexdigest(bytes), size: bytes.bytesize
        }, key, bytes)
      end
      call('producer', "#{name}-result", 'result', {
        item_id: 'synthetic', attempt: 1, config_digest: 'synthetic-demo-v1',
        state: name == 'complete' ? 'verified' : 'failed',
        build_ok: name == 'complete', tests_ok: name == 'complete',
        message: 'Synthetic demo result; no image build or OS test was performed'
      }, key)
      call('producer', "#{name}-finish", 'finish', {}, key)
    end
    call('producer', 'complete-seal', 'seal', {}, runs.fetch('complete'))
    summary = { label: 'Synthetic demo fixtures, not operating system images', runs: runs,
                sha256: %w[0 1 2].to_h { |v| [v, Digest::SHA256.hexdigest(payload(v))] } }
    write_once("#{@root}/seed.json", JSON.pretty_generate(summary) + "\n")
    traffic(runs) unless File.exist?("#{@root}/traffic.done")
    puts JSON.generate(summary)
  end

  def traffic(runs)
    path = '/v1/default/default/x86_64/synthetic/latest/image-archive.tar'
    requests = [[:get, '/', {}, 200], [:get, '/v1/INDEX.json', {}, 200],
                [:head, path, {}, 200], [:get, path, {}, 200],
                [:get, path, { 'Range' => 'bytes=0-31' }, 206],
                [:get, '/v1/missing', {}, 404],
                [:get, "/runs/#{runs.fetch('complete')}/v1/INDEX.json", {}, 200],
                [:get, "/runs/#{runs.fetch('pending')}/v1/INDEX.json", {}, 503]]
    # Disable proxy environment discovery; fixture requests stay on guest loopback.
    Net::HTTP.start('127.0.0.1', 8080, nil, nil, nil, nil, open_timeout: 3, read_timeout: 5) do |http|
      requests.each do |method, target, headers, expected|
        type = method == :head ? Net::HTTP::Head : Net::HTTP::Get
        response = http.request(type.new(target, headers.merge('User-Agent' => 'synthetic-demo-seed/1')))
        raise "Demo HTTP #{target}: expected #{expected}, got #{response.code}" unless response.code.to_i == expected
      end
    end
    write_once("#{@root}/traffic.done", "synthetic-demo-v1\n")
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: image-repository-seed.rb ROOT SERVER LEASE_SECONDS' unless ARGV.length == 3
  ImageRepositoryDemoSeed.new(*ARGV).seed
end
