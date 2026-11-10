require 'minitest/autorun'
require 'tmpdir'
require_relative '../dev-clusters/vpsadminos/lib/image-repository-fixtures'
require_relative '../dev-clusters/vpsadminos/lib/image-repository-seed'

class ImageRepositoryFixturesTest < Minitest::Test
  def setup
    @fixture = ImageRepositoryFixtures.new
  end

  def test_full_source_order_routes_and_synthetic_integrity
    Dir.mktmpdir do |tmp|
      out = File.join(tmp, 'generated')
      manifest = @fixture.generate(out)
      assert_equal 178, manifest['tuples']
      assert_equal 347, manifest['files'].length
      assert_equal 1872, manifest['routes']
      assert_operator manifest['payload_bytes'], :<=, 2 * 1024 * 1024
      assert_equal File.binread(ImageRepositoryFixtures::DEFAULT_INDEX), File.binread("#{out}/v1/INDEX.json")
      manifest['files'].each do |entry|
        bytes = File.binread("#{out}/v1/#{entry['path']}")
        assert_equal entry['size'], bytes.bytesize
        assert_equal entry['sha256'], Digest::SHA256.hexdigest(bytes)
        assert_operator bytes.bytesize, :<=, 4096
        assert_includes bytes, ImageRepositoryFixtures::MARKER
        if entry['format'] == 'tar'
          Gem::Package::TarReader.new(StringIO.new(bytes)) do |tar|
            member = tar.first
            assert_equal 'SYNTHETIC-PREVIEW.txt', member.full_name
            assert_equal 1, member.header.mtime
            assert_includes member.read, ImageRepositoryFixtures::MARKER
          end
        else
          assert bytes.start_with?('NOT A ZFS STREAM')
        end
      end
      @fixture.routes.each { |path, target| assert_equal File.binread("#{out}/v1/#{target}"), File.binread("#{out}/v1/#{path}") }
      assert_equal manifest, @fixture.generate(out)
      File.write("#{out}/unknown", 'unreviewed')
      assert_raises(RuntimeError) { @fixture.generate(out) }
      File.unlink("#{out}/unknown")
      payload = "#{out}/v1/#{manifest['files'].first['path']}"
      File.binwrite(payload, 'tampered')
      assert_raises(RuntimeError) { @fixture.generate(out) }
      assert_equal 'tampered', File.binread(payload)
    end
  end

  def test_refuses_changed_source_unsafe_and_colliding_metadata
    Dir.mktmpdir do |tmp|
      bad = File.join(tmp, 'bad.json')
      File.write(bad, '{}')
      assert_raises(RuntimeError) { ImageRepositoryFixtures.new(bad) }
    end
    original = JSON.parse(File.read(ImageRepositoryFixtures::DEFAULT_INDEX))
    ['../escape', '/absolute', 'a//b', 'a\\b'].each do |path|
      data = Marshal.load(Marshal.dump(original))
      data['images'][0]['image']['zfs'] = path
      assert_raises(RuntimeError) { @fixture.validate_index(data) }
    end
    duplicate = Marshal.load(Marshal.dump(original))
    duplicate['images'] << duplicate['images'].first
    assert_raises(RuntimeError) { @fixture.validate_index(duplicate) }
    collision = Marshal.load(Marshal.dump(original))
    group = collision['images'].group_by { |image| image.values_at('vendor', 'variant', 'arch', 'distribution') }.values.find { |v| v.length > 1 }
    group[0]['tags'] << group[1]['version']
    assert_raises(RuntimeError) { @fixture.validate_index(collision) }
  end

  def export_fixture(root)
    FileUtils.mkdir_p("#{root}/files")
    catalog = { 'vendors' => ImageRepositoryDemoSeed::DEFAULTS, 'images' => [] }
    refs = {}
    paths = {}
    seed = ImageRepositoryDemoSeed.new('/unused', '/unused', 3600)
    %w[1 0].each do |version|
      bytes = seed.payload(version)
      ref = { 'id' => "old-#{version}", 'sha256' => Digest::SHA256.hexdigest(bytes), 'size' => bytes.bytesize,
              'format' => 'tar', 'modified' => '2026-11-10T00:00:00Z' }
      image = seed.tuple(version).transform_keys(&:to_s).merge('tags' => version == '1' ? %w[latest stable] : ['oldstable'], 'files' => { 'tar' => ref })
      catalog['images'] << image
      refs[ref['id']] = ref
      paths["#{@fixture.tuple(image)}/image-archive.tar"] = ref['id']
      File.binwrite("#{root}/files/#{ref['id']}", bytes)
    end
    manifest = { 'schema' => 1, 'repository' => 'demo', 'generation' => 'old-generation', 'catalog' => catalog,
                 'paths' => paths, 'files' => refs, 'index_sha256' => Digest::SHA256.hexdigest(ImageRepositoryFixtures.json(@fixture.native_index(catalog))) }
    File.write("#{root}/manifest.json", ImageRepositoryFixtures.json(manifest))
    manifest
  end

  def test_union_preserves_current_ids_bytes_and_requires_explicit_default_transition
    Dir.mktmpdir do |tmp|
      baseline = export_fixture("#{tmp}/export")
      File.write("#{tmp}/DEMO", ImageRepositoryDemoSeed::MARKER)
      seed = ImageRepositoryDemoSeed.new(tmp, '/must-not-execute', 3600)
      args = { export_path: "#{tmp}/export", output: "#{tmp}/union", expected_generation: 'old-generation' }
      assert_raises(RuntimeError) { seed.prepare_catalog(**args) }
      refute File.exist?("#{tmp}/union")
      receipt = seed.prepare_catalog(**args, allow_default_transition: true)
      assert_equal 180, receipt['total_tuples']
      assert_equal 2, receipt['preserved_tuples']
      manifest = JSON.parse(File.read("#{tmp}/union/manifest.json"))
      assert_equal 349, manifest['files'].length
      baseline['files'].each do |key, ref|
        assert_equal ref, manifest['files'][key]
        assert_equal File.binread("#{tmp}/export/files/#{key}"), File.binread("#{tmp}/union/files/#{key}")
      end
      assert_equal 'vpsadminos', manifest['catalog']['vendors']['default']
      assert_equal 'minimal', manifest['catalog']['vendors']['demo']
      request = JSON.parse(File.read("#{tmp}/union/import-request.json"))
      assert_equal 'demo', request['repository']
      assert_equal 'old-generation', request['params']['generation']
      assert_equal 'import-generation', request['operation']
      assert_equal receipt, seed.prepare_catalog(**args, allow_default_transition: true)
      assert_raises(RuntimeError) { seed.prepare_catalog(**args.merge(expected_generation: 'moved'), allow_default_transition: true) }
      File.unlink("#{tmp}/export/files/old-0")
      File.symlink('/etc/passwd', "#{tmp}/export/files/old-0")
      assert_raises(RuntimeError) { seed.prepare_catalog(**args, allow_default_transition: true) }
    end
  end
end
