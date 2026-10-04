# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../dev-clusters/vpsadmin/lib/maintenance'

# Every Nix child uses a fresh private local store. No daemon, builds or GC.
class DevclusterStoreRootsTest < Minitest::Test
  Maintenance = DevClusters::VpsAdminMaintenance

  def test_raw_json_has_no_references_but_each_selected_payload_is_registered
    with_store do |helper, paths, config|
      assert_empty(nix!('--query', '--references', paths.fetch(:config)).strip)
      before = File.binread(paths.fetch(:config))
      expected = helper.host_payloads(config).keys
      assert_equal(6, expected.size)
      assert_equal(expected, helper.root_host_payloads!(config_path: paths.fetch(:config)))
      expected.each do |item|
        root = payload_root(paths.fetch(:directory), item)
        assert_equal(item, File.readlink(root))
        assert_includes(nix!('--query', '--roots', item).lines.map(&:chomp), "#{root} -> #{item}")
      end
      assert_equal(before, File.binread(paths.fetch(:config)))
      assert_equal(expected.size, Dir.glob(File.join(paths.fetch(:directory), 'maintenance-payload-*')).size)
      assert_equal(expected, helper.root_host_payloads!(config_path: paths.fetch(:config)))
      # No JSON/candidate root supplies this evidence; these are direct roots.
      assert_empty(nix!('--query', '--roots', paths.fetch(:config)).strip)
    end
  end

  def test_equal_json_bytes_keep_both_exact_source_items_and_legacy_root
    with_store do |helper, paths, _config|
      first = paths.fetch(:config)
      copy = File.join(paths.fetch(:workspace), 'same-bytes-different-name.json')
      FileUtils.cp(first, copy)
      second = nix!('--add', copy).strip
      refute_equal(first, second)
      digest = Digest::SHA256.file(first).hexdigest
      assert_equal(digest, Digest::SHA256.file(second).hexdigest)
      [first, second].each { |path| assert_empty(nix!('--query', '--references', path).strip) }
      legacy = File.join(paths.fetch(:directory), "maintenance-applied-#{digest}")
      nix!('--option', 'substitute', 'false', '--add-root', legacy, '--indirect', '--realise', first)
      helper.root_source_config!(config_path: first)
      helper.root_source_config!(config_path: second)
      helper.root_source_config!(config_path: first)
      roots = [first, second].map do |item|
        root = File.join(paths.fetch(:directory), "maintenance-source-#{Digest::SHA256.hexdigest(item)}")
        assert_equal(item, File.readlink(root))
        assert_includes(nix!('--query', '--roots', item).lines.map(&:chomp), "#{root} -> #{item}")
        root
      end
      refute_equal(*roots)
      assert_equal(first, File.readlink(legacy))
      assert_includes(nix!('--query', '--roots', first).lines.map(&:chomp), "#{legacy} -> #{first}")
      missing = File.join(paths.fetch(:store), 'missing-exact-source.json')
      assert_raises(Maintenance::Invalid) { helper.root_source_config!(config_path: missing) }
      assert_equal(first, File.readlink(legacy))
      assert_equal(second, File.readlink(roots.last))
    end
  end

  def test_missing_unused_preserved_image_is_ignored_but_fresh_image_is_required
    with_store do |helper, paths, config|
      refute(File.exist?(config.dig('machines', 'services', 'rootDisk', 'image')))
      helper.root_host_payloads!(config_path: paths.fetch(:config))
      File.unlink(File.join(paths.fetch(:directory), 'state/services-root.img'))
      fresh = seal_json(paths, config)
      assert_raises(Maintenance::Invalid) { helper.root_host_payloads!(config_path: fresh) }
      config.fetch('machines').fetch('services').fetch('rootDisk')['image'] = paths.fetch(:squashfs) + '/root.squashfs'
      fresh = seal_json(paths, config)
      assert_includes(helper.root_host_payloads!(config_path: fresh), paths.fetch(:squashfs))
    end
  end

  def test_absent_or_unregistered_payload_refuses_without_fetching
    with_store do |helper, paths, config|
      kernel = config.dig('machines', 'services', 'kernel')
      config.fetch('machines').fetch('services')['kernel'] = File.join(paths.fetch(:store), 'missing-kernel')
      assert_raises(Maintenance::Invalid) { helper.root_host_payloads!(config_path: seal_json(paths, config)) }
      refute(File.exist?(config.dig('machines', 'services', 'kernel')))
      unregistered = File.join(paths.fetch(:store), '00000000000000000000000000000000-unregistered-kernel')
      File.write(unregistered, 'not registered')
      config.fetch('machines').fetch('services')['kernel'] = unregistered
      assert_raises(Maintenance::Invalid) { helper.root_host_payloads!(config_path: seal_json(paths, config)) }
      config.fetch('machines').fetch('services')['kernel'] = kernel + '-absent-file'
      assert_raises(Maintenance::Invalid) { helper.root_host_payloads!(config_path: seal_json(paths, config)) }
    end
  end

  def test_malformed_or_derivation_payload_refuses_before_root_registration
    with_store do |helper, paths, config|
      [paths.fetch(:store) + '/bad/../kernel', paths.fetch(:store) + '//kernel',
       paths.fetch(:store) + '/bad.drv/bzImage', paths.fetch(:store), 'relative/kernel'].each do |path|
        config.fetch('machines').fetch('services')['kernel'] = path
        assert_raises(Maintenance::Invalid) { helper.root_host_payloads!(config_path: seal_json(paths, config)) }
        assert_empty(Dir.glob(File.join(paths.fetch(:directory), 'maintenance-payload-*')))
      end
    end
  end

  def test_real_registration_failure_propagates_and_existing_wrong_root_refuses
    with_store do |helper, paths, config|
      item = helper.host_payloads(config).keys.first
      root = payload_root(paths.fetch(:directory), item)
      File.symlink(paths.fetch(:squashfs), root)
      assert_raises(Maintenance::Invalid) { helper.root_host_payloads!(config_path: paths.fetch(:config)) }
      assert_equal(paths.fetch(:squashfs), File.readlink(root))
      blocked = File.join(paths.fetch(:directory), 'not-a-directory')
      File.write(blocked, 'owned test obstruction')
      blocked_helper = Maintenance.new(workspace: paths.fetch(:workspace), slug: 'store-root-test',
                                      directory: blocked, store_root: paths.fetch(:store))
      assert_raises(Maintenance::Invalid) { blocked_helper.root_host_payloads!(config_path: paths.fetch(:config)) }
      assert_equal('owned test obstruction', File.read(blocked))
      assert_equal(paths.fetch(:squashfs), File.readlink(root))
    end
  end

  private

  def payload_root(directory, item)
    File.join(directory, "maintenance-payload-#{Digest::SHA256.hexdigest(item)}")
  end

  def nix!(*arguments)
    output, error, status = Open3.capture3(@nix_environment, 'nix-store', *arguments)
    assert(status.success?, error)
    output
  end

  def add(paths, name, files)
    source = File.join(paths.fetch(:workspace), name)
    FileUtils.mkdir_p(source)
    files.each do |relative, executable|
      path = File.join(source, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, 'private fake host payload')
      File.chmod(executable ? 0o755 : 0o644, path)
    end
    nix!('--add', source).strip
  end

  def seal_json(paths, config)
    source = File.join(paths.fetch(:workspace), 'config.json')
    File.write(source, JSON.generate(config))
    nix!('--add', source).strip
  end

  def with_store
    workspace = Dir.mktmpdir('devcluster-store-roots')
    paths = { workspace:, directory: File.join(workspace, 'cluster'), store: File.join(workspace, 'store') }
    original_environment = {}
    primary_error = nil
    begin
      FileUtils.mkdir_p(File.join(paths.fetch(:directory), 'state'), mode: 0o700)
      @nix_environment = { 'NIX_REMOTE' => "local?store=#{paths.fetch(:store)}&state=#{workspace}/nix-state&log=#{workspace}/nix-log",
                           'NIX_CONFIG' => "substitute = false\nbuild-users-group =\n" }
      original_environment = @nix_environment.keys.to_h { |key| [key, ENV[key]] }
      @nix_environment.each { |key, value| ENV[key] = value }
      kernel = add(paths, 'kernel', { 'bzImage' => false, 'initrd' => false })
      tools = add(paths, 'tools', { 'bin/qemu-kvm' => true, 'bin/virtiofsd' => true, 'bin/bridge-helper' => true })
      top = add(paths, 'system', { 'init' => true })
      share = add(paths, 'share', { 'fixture' => false })
      paths[:squashfs] = add(paths, 'squashfs', { 'root.squashfs' => false })
      iso = add(paths, 'iso', { 'boot.iso' => false })
      File.write(File.join(paths.fetch(:directory), 'state/services-root.img'), 'retained test disk')
      machine = { 'spin' => 'nixos', 'toplevel' => top, 'kernel' => kernel + '/bzImage', 'initrd' => kernel + '/initrd',
                  'qemu' => tools, 'virtiofsd' => tools,
                  'rootDisk' => { 'device' => '{machine}-root.img', 'type' => 'file', 'create' => true,
                                  'preserve' => true, 'image' => paths.fetch(:store) + '/absent-old-image' },
                  'sharedFileSystems' => { 'store-share' => share, 'external' => workspace + '/external' },
                  'networks' => [{ 'type' => 'bridge', 'opts' => { 'helper' => tools + '/bin/bridge-helper' } }] }
      config = { 'machines' => { 'services' => machine, 'node1' => machine.reject { |key, _| key == 'rootDisk' }.merge(
        'spin' => 'vpsadminos', 'squashfs' => paths.fetch(:squashfs) + '/root.squashfs', 'iso' => iso + '/boot.iso') } }
      paths[:config] = seal_json(paths, config)
      helper = Maintenance.new(workspace:, slug: 'store-root-test', directory: paths.fetch(:directory), store_root: paths.fetch(:store))
      yield helper, paths, config
    rescue Exception => error # Preserve this invocation's failure, including signals, through cleanup.
      primary_error = error
      raise
    ensure
      begin
        original_environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
        store = paths.fetch(:store)
        unless store == File.join(workspace, 'store') && !File.symlink?(store)
          raise 'invalid private-store cleanup path'
        end
        # Nix imports read-only trees. FileUtils does not traverse symlinks;
        # change only this invocation's private store, after its final query.
        FileUtils.chmod_R('u+w', store) if File.directory?(store)
        FileUtils.remove_entry(workspace)
      rescue Exception
        raise unless primary_error

        warn 'private_store_cleanup_failed=1'
      end
    end
  end
end
