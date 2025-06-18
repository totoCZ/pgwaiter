# file: test_backup_pruning.rb

# --- PRE-SETUP: CONFIGURE THE TEST ENVIRONMENT ---
require 'tmpdir'

@test_dir = Dir.mktmpdir("backup_test")
ENV['BACKUP_DIR'] = @test_dir
ENV['KEEP_FULL_DAYS'] = '30'
ENV['KEEP_INCREMENTAL_DAYS'] = '7'
ENV['PG_BIN_DIR'] = '/tmp/fake_pg_bin' # Prevent searching a real path

# --- SCRIPT LOADING AND TEST CLASS DEFINITION ---
require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'time'
load './backup.rb' # Load the refactored script

TEST_TEMP_DIR = ENV['BACKUP_DIR']

class TestBackupPruning < Minitest::Test
  def setup
    FileUtils.rm_rf(TEST_TEMP_DIR)
    FileUtils.mkdir_p(TEST_TEMP_DIR)

    @now = Time.parse('2023-01-15T12:00:00Z')

    # --- Create a mock backup history ---
    # Scenario 1: A very old chain (full backup > 30 days old).
    # EXPECTATION: The entire chain should be deleted.
    chain1_full = create_mock_backup(type: 'full', timestamp: @now - 45 * SECONDS_IN_A_DAY)
    create_mock_backup(type: 'incremental', parent: chain1_full, timestamp: @now - 44 * SECONDS_IN_A_DAY)

    # Scenario 2: A mid-age chain (full < 30 days, oldest incremental > 7 days).
    # EXPECTATION: The full backup is KEPT, its incrementals are DELETED.
    chain2_full = create_mock_backup(type: 'full', timestamp: @now - 20 * SECONDS_IN_A_DAY)
    chain2_inc1 = create_mock_backup(type: 'incremental', parent: chain2_full, timestamp: @now - 10 * SECONDS_IN_A_DAY)
    create_mock_backup(type: 'incremental', parent: chain2_inc1, timestamp: @now - 9 * SECONDS_IN_A_DAY)

    # Scenario 3: A recent, active chain (full and incrementals are new).
    # EXPECTATION: The entire chain is KEPT because it's the most recent one.
    chain3_full = create_mock_backup(type: 'full', timestamp: @now - 5 * SECONDS_IN_A_DAY)
    create_mock_backup(type: 'incremental', parent: chain3_full, timestamp: @now - 2 * SECONDS_IN_A_DAY)
  end

  Minitest.after_run do
    FileUtils.rm_rf(TEST_TEMP_DIR) if TEST_TEMP_DIR && Dir.exist?(TEST_TEMP_DIR)
  end

  # REFACTOR: This helper now mimics the main script by storing relative basenames.
  def create_mock_backup(type:, timestamp:, parent: nil)
    dir_name = "#{timestamp.utc.strftime('%Y-%m-%d_%H-%M-%S')}_#{type}"
    backup_path = File.join(TEST_TEMP_DIR, dir_name)
    FileUtils.mkdir_p(backup_path)

    parent_basename = parent ? File.basename(parent) : nil
    chain_start_basename = if type == 'full'
                             dir_name
                           else
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
    backup_path # Return the full path for chaining calls in the test setup
  end

  def test_pruning_logic_is_correct
    Time.stub :now, @now do
      # Silence the output of the script for a clean test log.
      capture_io { perform_prune }
    end

    remaining_backups = find_all_backups(TEST_TEMP_DIR).map { |p| File.basename(p) }

    # --- VERIFY SCENARIO 1 ---
    # The entire 45-day-old chain should be gone.
    assert_empty remaining_backups.grep(/#{(@now - 45 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')}/),
                 "The 45-day-old chain should have been pruned"

    # --- VERIFY SCENARIO 2 ---
    # The full backup is kept, but its incrementals are pruned.
    assert_equal 1, remaining_backups.grep(/#{(@now - 20 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')}/).grep(/_full$/).count,
                 "The 20-day-old full backup should be kept"
    assert_empty remaining_backups.grep(/#{(@now - 10 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')}/),
                 "The 10-day-old incremental should have been pruned"

    # --- VERIFY SCENARIO 3 ---
    # The entire active chain should be untouched.
    assert_equal 1, remaining_backups.grep(/#{(@now - 5 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')}/).count,
                 "The 5-day-old full backup (active chain) should be kept"
    assert_equal 1, remaining_backups.grep(/#{(@now - 2 * SECONDS_IN_A_DAY).strftime('%Y-%m-%d')}/).count,
                 "The 2-day-old incremental (active chain) should be kept"

    # --- FINAL COUNT ---
    # We expect 1 full from scenario 2, and 1 full + 1 incremental from scenario 3. Total = 3.
    assert_equal 3, remaining_backups.count, "There should be exactly 3 backups remaining"
  end
end