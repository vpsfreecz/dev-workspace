require 'minitest/autorun'
require 'tmpdir'
require_relative '../dev-clusters/vpsadminos/lib/image-repository-seed'

class ImageRepositoryDemoSeedTest < Minitest::Test
  class Fixture < ImageRepositoryDemoSeed
    attr_reader :requests, :traffic_count

    def initialize(root)
      super(root, '/unused-server', 3600)
      @requests = []
      @traffic_count = 0
    end

    def call(role, id, operation, params = {}, key = nil, bytes = ''.b)
      @requests << [role, id, operation, params, key, bytes]
      operation == 'begin' ? { 'key' => "fixture-#{params.fetch(:id)}" } : {}
    end

    def traffic(_runs)
      @traffic_count += 1
      write_once("#{@root}/traffic.done", "synthetic-demo-v1\n")
    end
  end

  def test_refuses_unknown_root_without_writes
    Dir.mktmpdir do |root|
      seed = Fixture.new(root)
      assert_raises(RuntimeError) { seed.seed }
      assert_empty Dir.children(root)
      assert_empty seed.requests
    end
  end

  def test_deterministic_tar_and_explicit_demo_content
    seed = Fixture.new('/unused')
    first = seed.payload('1')
    assert_equal first, seed.payload('1')
    assert_operator first.bytesize, :<, 4096
    Gem::Package::TarReader.new(StringIO.new(first)) do |tar|
      entry = tar.first
      assert_equal 'DEMO.txt', entry.full_name
      assert_match(/SYNTHETIC DEMO 1: not an operating system image/, entry.read)
      assert_equal 1, entry.header.mtime
    end
  end

  def test_replay_preserves_import_bytes_and_requests_without_extra_traffic
    Dir.mktmpdir do |root|
      File.write("#{root}/DEMO", ImageRepositoryDemoSeed::MARKER)
      seed = Fixture.new(root)
      capture_io { seed.seed }
      first_requests = Marshal.load(Marshal.dump(seed.requests))
      index = File.binread("#{root}/fixture-import/v1/INDEX.json")
      summary = File.binread("#{root}/seed.json")
      capture_io { seed.seed }
      assert_equal first_requests, seed.requests.drop(first_requests.length)
      assert_equal index, File.binread("#{root}/fixture-import/v1/INDEX.json")
      assert_equal summary, File.binread("#{root}/seed.json")
      assert_equal 1, seed.traffic_count
      assert_equal 'demo', File.readlink("#{root}/fixture-import/v1/default")
      assert_equal '1', File.readlink("#{root}/fixture-import/v1/demo/minimal/x86_64/synthetic/latest")
      assert_equal 3, first_requests.count { |r| r[2] == 'begin' }
      assert_equal 1, first_requests.count { |r| r[2] == 'upload' }
      assert_equal 1, first_requests.count { |r| r[2] == 'seal' }
      refute first_requests.any? { |r| %w[publish expire reclaim].include?(r[2]) }
      upload = first_requests.find { |r| r[2] == 'upload' }
      assert_equal Digest::SHA256.hexdigest(upload[5]), upload[3].fetch(:sha256)
      assert_equal upload[5].bytesize, upload[3].fetch(:size)
    end
  end

  def test_refuses_changed_existing_fixture
    Dir.mktmpdir do |root|
      File.write("#{root}/DEMO", ImageRepositoryDemoSeed::MARKER)
      seed = Fixture.new(root)
      capture_io { seed.seed }
      path = "#{root}/fixture-import/v1/demo/minimal/x86_64/synthetic/1/image-archive.tar"
      File.write(path, 'unknown bytes')
      assert_raises(RuntimeError) { capture_io { seed.seed } }
      assert_equal 'unknown bytes', File.read(path)
    end
  end
end
