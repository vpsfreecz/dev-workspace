require 'minitest/autorun'
require 'tmpdir'
require_relative '../dev-clusters/vpsadminos/lib/image-repository-history'

class ImageRepositoryHistoryTest < Minitest::Test
  SQLITE = ENV.fetch('DEMO_SQLITE')
  SERVER = ENV.fetch('DEMO_SCHEMA_SERVER')
  SCHEMA = Integer(ENV.fetch('DEMO_SCHEMA_VERSION', '2'))
  raise 'Tests require a compiled schema-2 or schema-3 server' unless [2, 3].include?(SCHEMA)
  SEED_TIME = '2026-11-10T14:10:21.949194Z'.freeze

  class CommitGap < ImageRepositoryHistory
    def write_manifest(path, data)
      raise 'simulated commit-before-marker interruption' if data['state'] == 'applied'

      super
    end
  end

  def setup
    @history = ImageRepositoryHistory.new(SQLITE)
  end

  def with_compiled_schema
    Dir.mktmpdir do |root|
      state = File.join(root, 'state')
      out, err, status = Open3.capture3('timeout', '3s', SERVER, 'serve', '--root', state,
                                      '--listen', 'invalid-listen-address', '--repository', 'demo', '--instance', ImageRepositoryHistory::INSTANCE,
                                      '--max-bytes', '16777216', '--max-upload-bytes', '1048576', '--max-runs', '100',
                                      '--max-lease', '1h', '--export-lease', '1m')
      refute status.success?
      refute_equal 124, status.exitstatus
      assert_includes out + err, 'explicit bounded HTTP measurement options required'
      db = File.join(state, 'catalog.sqlite')
      assert_equal [{ 'user_version' => SCHEMA }], @history.query(db, 'PRAGMA user_version;', readonly: true)
      File.write(File.join(root, 'DEMO'), "osctl-repo-server synthetic demo v1\n")
      @history.query(db, <<~SQL)
        INSERT INTO catalogs(id,repository,document,modified,retain_until)
          VALUES('baseline','demo','{"vendors":{"default":"demo","demo":"minimal"},"images":[]}', '2026-11-10T00:00:00Z',0);
        INSERT INTO repositories(id,generation) VALUES('demo','baseline');
        INSERT INTO http_daily(repository,instance,day,dimensions,requests,bytes,scope,kind,distribution,arch,vendor,variant,version,format,method,outcome,status)
          VALUES('demo','synthetic-demo','2026-11-10','{}',4,100,'public','artifact','synthetic','x86_64','demo','minimal','1','tar','GET','complete',200);
        INSERT INTO http_measurement VALUES('demo','synthetic-demo',7,5,'2026-11-10T00:00:00Z');
      SQL
      sample = File.join(root, 'history.json')
      @history.write_sample(sample, SEED_TIME)
      yield root, db, sample
    end
  end

  def own_count(db)
    @history.query(db, "SELECT count(*) AS count FROM http_daily WHERE instance='synthetic-history-v1';").first.fetch('count')
  end

  def test_fixed_utc_generation_typed_dimensions_bounds_and_quiet_days
    first = @history.sample(SEED_TIME)
    assert_equal first, @history.sample(SEED_TIME)
    assert_operator first['rows'].length, :<=, 50_000
    assert_operator first['rows'].length, :>, 10_000
    assert_equal 178, first['rows'].map { |r| r.values_at(8, 9, 10, 11, 12) }.uniq.length
    assert_operator first['rows'].map { |r| r[2] }.uniq.length, :<, 365
    assert_includes first['rows'].map { |r| r[16] }.uniq, 206
    assert_includes first['rows'].map { |r| r[16] }.uniq, 503
    assert_includes first['rows'].map { |r| r[15] }.uniq, 'interrupted'
    first['rows'].each do |row|
      assert_equal 17, row.length
      dimensions = JSON.parse(row[3])
      assert_equal row.values_at(6, 7, 13, 14, 16, 15), dimensions.values_at('scope', 'kind', 'format', 'method', 'status', 'outcome')
      assert_equal row.values_at(10, 11, 9, 8, 12), dimensions['tuple'].values_at('vendor', 'variant', 'arch', 'distribution', 'version')
    end
    assert_raises(RuntimeError) { @history.sample('2099-01-01T00:00:00Z') }
    assert_raises(RuntimeError) { @history.sample('2026-11-10T00:00:00+01:00') }
  end

  def test_actual_schema_atomic_import_original_instance_and_applied_replay
    with_compiled_schema do |root, db, sample|
      old = @history.query(db, "SELECT * FROM http_daily WHERE instance='synthetic-demo';")
      before_metadata = @history.query(db, "SELECT * FROM http_measurement WHERE instance='synthetic-demo';")
      result = @history.apply(root, sample)
      assert_equal 'applied', result['state']
      assert_equal result['row_count'], own_count(db)
      assert_equal old, @history.query(db, "SELECT * FROM http_daily WHERE instance='synthetic-demo';")
      assert_equal before_metadata, @history.query(db, "SELECT * FROM http_measurement WHERE instance='synthetic-demo';")
      # Normal later observations/pruning change the namespace. Applied replay
      # must not compare/reset these real changes to the original sample.
      @history.query(db, "UPDATE http_daily SET requests=requests+2,bytes=bytes+200 WHERE rowid=(SELECT min(rowid) FROM http_daily WHERE instance='synthetic-history-v1'); UPDATE http_measurement SET revision=9 WHERE instance='synthetic-history-v1';")
      changed = @history.query(db, "SELECT sum(requests) AS requests,sum(bytes) AS bytes FROM http_daily WHERE instance='synthetic-history-v1';")
      assert_equal 'already-applied', @history.apply(root, sample)['state']
      assert_equal changed, @history.query(db, "SELECT sum(requests) AS requests,sum(bytes) AS bytes FROM http_daily WHERE instance='synthetic-history-v1';")
      assert_equal 9, @history.query(db, "SELECT revision FROM http_measurement WHERE instance='synthetic-history-v1';").first['revision']
    end
  end

  def test_commit_gap_exact_reconciliation_and_conflict_refusal
    with_compiled_schema do |root, db, sample|
      interrupted = CommitGap.new(SQLITE)
      assert_raises(RuntimeError) { interrupted.apply(root, sample) }
      count = own_count(db)
      assert_operator count, :>, 10_000
      assert_equal 'prepared', JSON.parse(File.read(File.join(root, 'synthetic-history-v1.json')))['state']
      assert_equal 'applied', @history.apply(root, sample)['state']
      assert_equal count, own_count(db)
      File.unlink(File.join(root, 'synthetic-history-v1.json'))
      @history.query(db, "UPDATE http_measurement SET revision=2 WHERE instance='synthetic-history-v1';")
      assert_raises(RuntimeError) { @history.apply(root, sample) }
      assert_equal count, own_count(db)
    end
  end

  def test_guard_refusals_and_failed_transaction_leave_original_data
    with_compiled_schema do |root, db, sample|
      File.open(File.join(root, 'state/writer.lock'), File::RDWR) do |writer|
        writer.flock(File::LOCK_EX)
        assert_raises(RuntimeError) { @history.apply(root, sample) }
      end
      [0, 1, 4].each do |unsupported|
        @history.query(db, "PRAGMA user_version=#{unsupported};")
        error = assert_raises(RuntimeError) { @history.apply(root, sample) }
        assert_includes error.message, 'supports schemas 2 and 3 only'
        refute File.exist?(File.join(root, 'synthetic-history-v1.json'))
        # The transaction independently refuses an unsupported version too.
        assert_raises(RuntimeError) { @history.apply_transaction(db, @history.sample(SEED_TIME)) }
        assert_equal 0, own_count(db)
      end
      @history.query(db, "PRAGMA user_version=#{SCHEMA};")
      File.write(File.join(root, 'DEMO'), 'wrong')
      assert_raises(RuntimeError) { @history.apply(root, sample) }
      File.write(File.join(root, 'DEMO'), "osctl-repo-server synthetic demo v1\n")
      @history.query(db, "CREATE TRIGGER reject_fixture BEFORE INSERT ON http_daily WHEN NEW.instance='synthetic-history-v1' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;")
      assert_raises(RuntimeError) { @history.apply(root, sample) }
      assert_equal 0, own_count(db)
      assert_empty @history.query(db, "SELECT * FROM http_measurement WHERE instance='synthetic-history-v1';")
      assert_equal 4, @history.query(db, "SELECT requests FROM http_daily WHERE instance='synthetic-demo';").first['requests']
    end
  end
end
