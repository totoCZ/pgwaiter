# file: test_backup_pruning.rb

# --- PRE-SETUP: CONFIGURE THE TEST ENVIRONMENT ---
require 'tmpdir'

@test_dir = Dir.mktmpdir("backup_test")
ENV['BACKUP_DIR'] = @test_dir
# Set default ENV vars; tests may override them for specific scenarios.
ENV['KEEP_FULL_DAYS'] = '30'
ENV['KEEP_INCREMENTAL_DAYS'] = '7'
ENV['PG_BIN_DIR'] = '/tmp/fake_pg_bin' # Prevent searching a real path

# --- SCRIPT LOADING AND TEST CLASS DEFINITION ---
require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'time'
load './backup.rb' # Load the script being tested

TEST_TEMP_DIR = ENV['BACKUP_DIR']

class TestBackupPruning < Minitest::Test
  # This setup runs before each test. It ensures a clean environment.
  def setup
    FileUtils.rm_rf(TEST_TEMP_DIR)
    FileUtils.mkdir_p(TEST_TEMP_DIR)
    @now = Time.parse('2023-01-15T12:00:00Z')
  end

  # This hook ensures the temporary directory is cleaned up after all tests run.
  Minitest.after_run do
    FileUtils.rm_rf(TEST_TEMP_DIR) if TEST_TEMP_DIR && Dir.exist?(TEST_TEMP_DIR)
  end

  # Helper method to create a mock backup directory with metadata,
  # mimicking the structure of the actual backup script.
  def create_mock_backup(type:, timestamp:, parent: nil)
    dir_name = "#{timestamp.utc.strftime('%Y-%m-%d_%H-%M-%S')}_#{type}"
    backup_path = File.join(TEST_TEMP_DIR, dir_name)
    FileUtils.mkdir_p(backup_path)

    parent_basename = parent ? File.basename(parent) : nil
    chain_start_basename = if type == 'full'
                             dir_name
                           elsif parent
                             # Read the parent's metadata to find its chain_start basename
                             read_metadata(parent)[:chain_start]
                           end

    metadata = {
      timestamp: timestamp.utc.iso8601,
      type: type,
      parent: parent_basename,
      chain_start: chain_start_basename
    }
    File.write(File.join(backup_path, 'metadata.json'), JSON.pretty_generate(metadata))
    backup_path # Return the full path for chaining calls
  end

  # --- TEST CASES ---

  # This test covers the standard retention policy and replaces the original test case.
  def test_strategy1_standard_retention
    ENV['KEEP_FULL_DAYS'] = '30'
    ENV['KEEP_INCREMENTAL_DAYS'] = '7'

    Time.stub :now, @now do
      # Scenario 1: An old chain that should be completely pruned.
      old_full = create_mock_backup(type: 'full', timestamp: @now - 45 * SECONDS_IN_A_DAY)
      create_mock_backup(type: 'incremental', parent: old_full, timestamp: @now - 44 * SECONDS_IN_A_DAY)

      # Scenario 2: A mid-age chain where the full is kept but old incrementals are pruned.
      mid_full = create_mock_backup(type: 'full', timestamp: @now - 20 * SECONDS_IN_A_DAY)
      mid_inc = create_mock_backup(type: 'incremental', parent: mid_full, timestamp: @now - 10 * SECONDS_IN_A_DAY)

      # Scenario 3: The most recent chain, which should be kept entirely.
      recent_full = create_mock_backup(type: 'full', timestamp: @now - 5 * SECONDS_IN_A_DAY)
      recent_inc = create_mock_backup(type: 'incremental', parent: recent_full, timestamp: @now - 2 * SECONDS_IN_A_DAY)

      capture_io { perform_prune }
    end

    remaining = find_all_backups(TEST_TEMP_DIR).map { |p| File.basename(p) }

    # Verify Scenario 1: Old chain is gone
    refute_includes remaining, File.basename(old_full), "The 45-day-old full backup should have been pruned"

    # Verify Scenario 2: Mid-age full is kept, its incremental is pruned
    assert_includes remaining, File.basename(mid_full), "The 20-day-old full backup should be kept"
    refute_includes remaining, File.basename(mid_inc), "The 10-day-old incremental should have been pruned"

    # Verify Scenario 3: Recent chain is untouched
    assert_includes remaining, File.basename(recent_full), "The 5-day-old full backup (active chain) should be kept"
    assert_includes remaining, File.basename(recent_inc), "The 2-day-old incremental (active chain) should be kept"

    assert_equal 3, remaining.size, "Should be 3 backups left: 1 from mid-chain, 2 from recent chain"
  end

  def test_strategy2_long_term_archival
    ENV['KEEP_FULL_DAYS'] = '365'
    ENV['KEEP_INCREMENTAL_DAYS'] = '14'

    Time.stub :now, @now do
      # A very old full backup that should be kept due to the long retention policy.
      long_full = create_mock_backup(type: 'full', timestamp: @now - 200 * SECONDS_IN_A_DAY)
      # An incremental that is outside the 14-day incremental window.
      create_mock_backup(type: 'incremental', parent: long_full, timestamp: @now - 20 * SECONDS_IN_A_DAY)
      # A recent chain, ensuring the long-term one is not the "latest".
      create_mock_backup(type: 'full', timestamp: @now - 5 * SECONDS_IN_A_DAY)

      capture_io { perform_prune }
    end

    all_dirs = Dir.entries(TEST_TEMP_DIR).reject { |f| f.start_with?('.') }
    assert_includes all_dirs, File.basename(long_full), 'Long-term full (200 days old) should be kept'
    assert all_dirs.none? { |d| d.include?((@now - 20 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')) }, 'Old incremental (20 days old) should be pruned'
    assert_equal 2, all_dirs.count, "Should be 2 backups: the long-term full and the recent full"
  end

  def test_strategy3_short_term_window
    ENV['KEEP_FULL_DAYS'] = '14'
    ENV['KEEP_INCREMENTAL_DAYS'] = '14'

    Time.stub :now, @now do
      # This entire chain is older than 14 days and should be pruned.
      old_full = create_mock_backup(type: 'full', timestamp: @now - 20 * SECONDS_IN_A_DAY)
      create_mock_backup(type: 'incremental', parent: old_full, timestamp: @now - 18 * SECONDS_IN_A_DAY)

      # This chain is within the 14-day window and is the most recent, so it's kept.
      recent_full = create_mock_backup(type: 'full', timestamp: @now - 3 * SECONDS_IN_A_DAY)
      recent_inc = create_mock_backup(type: 'incremental', parent: recent_full, timestamp: @now - 2 * SECONDS_IN_A_DAY)

      capture_io { perform_prune }
    end

    remaining_basenames = Dir.entries(TEST_TEMP_DIR).reject { |f| f.start_with?('.') }
    refute_includes remaining_basenames, File.basename(old_full), 'Old full (20 days old) should be pruned'
    assert_includes remaining_basenames, File.basename(recent_full)
    assert_includes remaining_basenames, File.basename(recent_inc)
    assert_equal 2, remaining_basenames.count, "Only the 2 recent backups should remain"
  end

  def test_invalid_metadata_is_renamed_and_ignored
    Time.stub :now, @now do
      # An old valid backup that should be pruned.
      create_mock_backup(type: 'full', timestamp: @now - 40 * SECONDS_IN_A_DAY)

      # An invalid backup directory (no metadata.json) that should be renamed.
      invalid_dirname = (@now - 39 * SECONDS_IN_A_DAY).utc.strftime('%Y-%m-%d_%H-%M-%S') + "_invalid"
      FileUtils.mkdir_p(File.join(TEST_TEMP_DIR, invalid_dirname))

      # A recent backup that will be kept.
      create_mock_backup(type: 'full', timestamp: @now - 5 * SECONDS_IN_A_DAY)

      capture_io { perform_prune }
    end

    all_dirs = Dir.entries(TEST_TEMP_DIR).reject { |f| f.start_with?('.') }

    assert any_renamed_invalid?(all_dirs), 'Invalid backup directory should be renamed'
    assert all_dirs.none? { |d| d.include?((@now - 40 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')) }, 'Old valid backup should have been pruned'
    assert all_dirs.any? { |d| d.include?((@now - 5 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')) }, 'Recent valid backup should be present'
    assert_equal 2, all_dirs.count, "Should be 2 entries: the renamed invalid dir and the recent full backup"
  end

  def test_old_full_with_invalid_incrementals
    Time.stub :now, @now do
      # Full backup is < 30 days old (kept), but not the latest chain.
      full_backup = create_mock_backup(type: 'full', timestamp: @now - 25 * SECONDS_IN_A_DAY)
      # Valid incremental is > 7 days old (pruned).
      valid_inc = create_mock_backup(type: 'incremental', parent: full_backup, timestamp: @now - 10 * SECONDS_IN_A_DAY)
      # Invalid incremental (no metadata) is renamed and ignored.
      invalid_inc_dir = (@now - 9 * SECONDS_IN_A_DAY).utc.strftime('%Y-%m-%d_%H-%M-%S') + '_incremental'
      FileUtils.mkdir_p(File.join(TEST_TEMP_DIR, invalid_inc_dir))
      # A recent chain to ensure the other one is not the "latest".
      create_mock_backup(type: 'full', timestamp: @now - 1 * SECONDS_IN_A_DAY)

      capture_io { perform_prune }
    end

    all_dirs = Dir.entries(TEST_TEMP_DIR).reject { |f| f.start_with?('.') }

    assert_includes all_dirs, File.basename(full_backup), 'Full backup (25 days old) should be kept'
    refute_includes all_dirs, File.basename(valid_inc), 'Valid old incremental should have been pruned'
    assert any_renamed_invalid?(all_dirs), 'Invalid incremental should have been renamed'
    assert all_dirs.any? { |d| d.include?((@now - 1 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')) }, 'The latest chain should be kept'
    assert_equal 3, all_dirs.count, "Should be 3 entries: the kept full, the renamed invalid, and the latest full"
  end

  private

  # Helper to check if a directory was renamed due to being invalid.
  def any_renamed_invalid?(dirs)
    dirs.any? { |d| d.start_with?('Invalid_') }
  end
end