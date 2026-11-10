require 'date'
require 'digest'
require 'json'
require 'open3'
require 'time'
require_relative 'image-repository-fixtures'

# A deliberately offline, marked-demo-only fixture tool. It is not a public
# statistics import operation and never invents access-log events.
class ImageRepositoryHistory
  INSTANCE = 'synthetic-history-v1'.freeze
  COLUMNS = %w[repository instance day dimensions requests bytes scope kind distribution arch vendor variant version format method outcome status].freeze
  LIMIT = 50_000

  def initialize(sqlite)
    @sqlite = sqlite
  end

  def sample(seed_time)
    timestamp = Time.iso8601(seed_time)
    raise 'Seed time must be an explicit real UTC timestamp' unless timestamp.utc? && timestamp <= Time.now.utc && timestamp.year >= 2026

    index = JSON.parse(File.binread(ImageRepositoryFixtures::DEFAULT_INDEX))
    ImageRepositoryFixtures.new # Verify exact frozen metadata before using it.
    first = timestamp.to_date - 364
    rows = []
    365.times do |day|
      next if (day % 17).zero? # Quiet days stay genuinely absent/zero in charts.

      index.fetch('images').each_with_index do |image, item|
        next unless ((day + item) % 4).zero?

        requests = 1 + ((day * 7 + item * 11) % 23) + (day / 31) % 4
        # These large values are simulated traffic only, not tiny archive sizes.
        size = (32 + (item % 16) * 16) * 1024 * 1024
        date = (first + day).iso8601
        rows << row(image, date, 200, 'complete', requests, requests * size)
        rows << row(image, date, 206, 'complete', 2, size / 4) if (item % 7).zero?
        rows << row(image, date, 200, 'interrupted', 1, size / 8) if (item % 11).zero?
        rows << row(image, date, 503, 'complete', 1, 0) if (item % 13).zero?
      end
    end
    rows.sort_by! { |entry| entry.values_at(0, 1, 2, 3) }
    raise 'Historical fixture exceeds bounded daily keys' if rows.length > LIMIT || rows.map { |r| r.values_at(0, 1, 2, 3) }.uniq.length != rows.length
    raise 'Simulated counters overflow signed 64-bit bounds' unless rows.sum { |r| r[4] }.between?(0, (1 << 63) - 1) && rows.sum { |r| r[5] }.between?(0, (1 << 63) - 1)

    { 'schema' => 1, 'fixture' => INSTANCE, 'repository' => 'demo', 'instance' => INSTANCE,
      'purpose' => 'Simulated historical sample; later observations are traffic to this synthetic preview, not production downloads.',
      'source_sha256' => ImageRepositoryFixtures::SOURCE_SHA256, 'seed_time' => timestamp.iso8601(9),
      'retention_days' => 365, 'columns' => COLUMNS, 'rows' => rows }
  end

  def row(image, day, status, outcome, requests, bytes)
    tuple = %w[vendor variant arch distribution version].to_h { |key| [key, image.fetch(key)] }
    format = image.fetch('image').key?('tar') ? 'tar' : 'zfs'
    dimensions = JSON.generate('scope' => 'public', 'kind' => 'artifact', 'tuple' => tuple,
                               'format' => format, 'method' => 'GET', 'status' => status, 'outcome' => outcome)
    ['demo', INSTANCE, day, dimensions, requests, bytes, 'public', 'artifact',
     image.fetch('distribution'), image.fetch('arch'), image.fetch('vendor'), image.fetch('variant'), image.fetch('version'),
     format, 'GET', outcome, status]
  end

  def write_sample(path, seed_time)
    data = ImageRepositoryFixtures.json(sample(seed_time)) + "\n"
    if File.exist?(path)
      raise 'Existing historical sample differs' unless !File.symlink?(path) && File.binread(path) == data
    else
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(data); file.fsync }
    end
    { 'rows' => JSON.parse(data).fetch('rows').length, 'sha256' => Digest::SHA256.hexdigest(data), 'bytes' => data.bytesize }
  end

  def query(db, sql, readonly: false)
    argv = [@sqlite, '-batch', '-bail', '-json']
    argv << '-readonly' if readonly
    out, err, status = Open3.capture3(*argv, db, stdin_data: sql)
    raise "Offline fixture SQLite operation failed: #{err.byteslice(0, 200)}" unless status.success?

    out.empty? ? [] : JSON.parse(out)
  end

  def apply(root, sample_path)
    root = File.expand_path(root)
    state = File.join(root, 'state')
    marker = File.join(root, 'DEMO')
    db = File.join(state, 'catalog.sqlite')
    lock_path = File.join(state, 'writer.lock')
    raise 'Refusing unmarked or symlinked demo state' unless [root, state].all? { |p| File.directory?(p) && !File.symlink?(p) } &&
                                                         [marker, db, lock_path].all? { |p| File.file?(p) && !File.symlink?(p) } &&
                                                         File.binread(marker) == "osctl-repo-server synthetic demo v1\n"
    bytes = File.binread(sample_path)
    data = JSON.parse(bytes)
    raise 'Historical sample content/provenance differs' unless data == sample(data.fetch('seed_time'))

    digest = Digest::SHA256.hexdigest(bytes)
    identity = { 'schema' => 1, 'fixture' => INSTANCE, 'repository' => 'demo', 'instance' => INSTANCE,
                 'sample_sha256' => digest, 'source_sha256' => ImageRepositoryFixtures::SOURCE_SHA256,
                 'seed_time' => data.fetch('seed_time'), 'row_count' => data.fetch('rows').length,
                 'rows_sha256' => Digest::SHA256.hexdigest(ImageRepositoryFixtures.json(data.fetch('rows'))),
                 'requests' => data['rows'].sum { |row| row[4] }, 'bytes' => data['rows'].sum { |row| row[5] } }
    manifest = File.join(root, "#{INSTANCE}.json")
    File.open(lock_path, File::RDWR) do |writer|
      raise 'Service writer must be stopped before offline fixture import' unless writer.flock(File::LOCK_EX | File::LOCK_NB)

      version = query(db, 'PRAGMA user_version;', readonly: true)
      raise 'Offline fixture supports schemas 2 and 3 only' unless [[{ 'user_version' => 2 }], [{ 'user_version' => 3 }]].include?(version)
      raise 'Offline fixture requires existing demo repository' unless query(db, "SELECT id FROM repositories WHERE id='demo';", readonly: true) == [{ 'id' => 'demo' }]

      if File.exist?(manifest) || File.symlink?(manifest)
        raise 'Fixture manifest must be a regular file' unless File.file?(manifest) && !File.symlink?(manifest)

        previous = JSON.parse(File.binread(manifest))
        raise 'Fixture manifest belongs to different content' unless previous.reject { |key, _| key == 'state' } == identity
        return identity.merge('state' => 'already-applied') if previous['state'] == 'applied'
        raise 'Unknown fixture manifest state' unless previous['state'] == 'prepared'
      else
        write_manifest(manifest, identity.merge('state' => 'prepared'))
      end
      apply_transaction(db, data)
      write_manifest(manifest, identity.merge('state' => 'applied'))
    end
    identity.merge('state' => 'applied')
  end

  def apply_transaction(db, data)
    # Hex is only SQL literal transport for one JSON parameter, never user SQL or
    # shell interpolation. json_each projects the explicit current 17-column row.
    parameter = ImageRepositoryFixtures.json(data).unpack1('H*')
    projections = COLUMNS.each_index.map { |i| "json_extract(value,'$[#{i}]') AS #{COLUMNS[i]}" }.join(',')
    columns = COLUMNS.join(',')
    own = "repository='demo' AND instance='#{INSTANCE}'"
    metadata = "repository='demo' AND instance='#{INSTANCE}' AND retention_days=365 AND revision=1 AND updated_at=json_extract(CAST(@fixture AS TEXT),'$.seed_time')"
    sql = <<~SQL
      .parameter init
      .parameter set @fixture X'#{parameter}'
      PRAGMA busy_timeout=0;
      BEGIN EXCLUSIVE;
      CREATE TEMP TABLE fixture_guard(value INTEGER CHECK(value=1));
      INSERT INTO fixture_guard SELECT CASE WHEN (SELECT user_version FROM pragma_user_version) IN (2,3) THEN 1 ELSE 0 END;
      CREATE TEMP TABLE fixture_expected AS SELECT #{projections} FROM json_each(CAST(@fixture AS TEXT),'$.rows');
      INSERT INTO fixture_guard SELECT CASE WHEN
        ((SELECT count(*) FROM http_daily WHERE #{own})=0 AND (SELECT count(*) FROM http_measurement WHERE #{own})=0)
        OR ((SELECT count(*) FROM http_measurement WHERE #{metadata})=1
          AND NOT EXISTS(SELECT #{columns} FROM http_daily WHERE #{own} EXCEPT SELECT #{columns} FROM fixture_expected)
          AND NOT EXISTS(SELECT #{columns} FROM fixture_expected EXCEPT SELECT #{columns} FROM http_daily WHERE #{own}))
        THEN 1 ELSE 0 END;
      INSERT INTO http_daily(#{columns}) SELECT #{columns} FROM fixture_expected
        WHERE NOT EXISTS(SELECT 1 FROM http_measurement WHERE #{own});
      INSERT INTO http_measurement(repository,instance,retention_days,revision,updated_at)
        SELECT 'demo','#{INSTANCE}',365,1,json_extract(CAST(@fixture AS TEXT),'$.seed_time')
        WHERE NOT EXISTS(SELECT 1 FROM http_measurement WHERE #{own});
      COMMIT;
    SQL
    query(db, sql)
  end

  def write_manifest(path, data)
    temporary = "#{path}.#{$$}.tmp"
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(ImageRepositoryFixtures.json(data) + "\n")
      file.fsync
    end
    File.rename(temporary, path)
    File.open(File.dirname(path)) { |directory| directory.fsync }
  ensure
    File.unlink(temporary) if temporary && File.exist?(temporary)
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.shift
  when 'generate'
    abort 'Usage: image-repository-history.rb generate OUTPUT SEED_UTC' unless ARGV.length == 2
    puts ImageRepositoryFixtures.json(ImageRepositoryHistory.new(nil).write_sample(*ARGV))
  when 'apply'
    abort 'Usage: image-repository-history.rb apply SQLITE ROOT SAMPLE' unless ARGV.length == 3
    puts ImageRepositoryFixtures.json(ImageRepositoryHistory.new(ARGV.shift).apply(*ARGV))
  else
    abort 'Explicit generate or offline apply operation required'
  end
end
