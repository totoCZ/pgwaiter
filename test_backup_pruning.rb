# file: test_backup_pruning.rb

# --- PRE-SETUP: CONFIGURE THE TEST ENVIRONMENT ---

# 1. Require the library for creating temporary directories
require 'tmpdir'

# 2. Set up environment variables for testing BEFORE loading the main script.
#    This ensures the constants in backup.rb are initialized with our test values.
@test_dir = Dir.mktmpdir("backup_test")
ENV['BACKUP_DIR'] = @test_dir
ENV['KEEP_FULL_DAYS'] = '30'
ENV['KEEP_INCREMENTAL_DAYS'] = '7'
# We can also prevent it from looking for a real pg_bin dir
ENV['PG_BIN_DIR'] = '/tmp/fake_pg_bin'


# --- SCRIPT LOADING AND TEST CLASS DEFINITION ---

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'time'
# 3. Now that ENV is set, load the script. Its constants will use our values.
load './backup.rb'

# Since we're not running the script directly, BACKUP_DIR is now correctly set
# from the ENV var we configured above. We just need to ensure the test teardown
# can access the temporary directory path.
TEST_TEMP_DIR = ENV['BACKUP_DIR']

class TestBackupPruning < Minitest::Test
  # This setup method runs before each test.

  def setup
    # The directory is created once outside the test class.
    # We just need to clean and recreate it for each test run to ensure isolation.
    FileUtils.rm_rf(TEST_TEMP_DIR)
    FileUtils.mkdir_p(TEST_TEMP_DIR)

    # A fixed point in time for predictable age calculations.
    @now = Time.parse('2023-01-15T12:00:00Z')
    
    # --- Create a mock backup history ---
    # Scenario 1: A very old chain (full backup > 30 days old).
    # EXPECTATION: The entire chain should be deleted.
    chain1_full = create_mock_backup(type: 'full', timestamp: @now - 45 * SECONDS_IN_A_DAY)
    create_mock_backup(type: 'incremental', parent: chain1_full, timestamp: @now - 44 * SECONDS_IN_A_DAY)

    # Scenario 2: A mid-age chain (full < 30 days, oldest incremental > 7 days).
    # EXPECTATION: The full backup is KEPT, its incrementals are DELETED.
    chain2_full = create_mock_backup(type: 'full', timestamp: @now - 20 * SECONDS_IN_A_DAY)
    # --- FIX: Create a proper linear chain ---
    chain2_inc1 = create_mock_backup(type: 'incremental', parent: chain2_full, timestamp: @now - 10 * SECONDS_IN_A_DAY)
    create_mock_backup(type: 'incremental', parent: chain2_inc1, timestamp: @now - 9 * SECONDS_IN_A_DAY)
    
    # Scenario 3: A recent, active chain (full and incrementals are new).
    # EXPECTATION: The entire chain is KEPT because it's the most recent one.
    chain3_full = create_mock_backup(type: 'full', timestamp: @now - 5 * SECONDS_IN_A_DAY)
    create_mock_backup(type: 'incremental', parent: chain3_full, timestamp: @now - 2 * SECONDS_IN_A_DAY)
  end

  # This teardown method runs after each test to ensure a clean state.
  def teardown
    # The Minitest::after_run hook will handle the final cleanup.
  end

  # A hook to clean up the main temporary directory once all tests are finished.
  Minitest.after_run do
    FileUtils.rm_rf(TEST_TEMP_DIR) if TEST_TEMP_DIR && Dir.exist?(TEST_TEMP_DIR)
  end

  # Helper method to create a fake backup directory and metadata file.
  def create_mock_backup(type:, timestamp:, parent: nil)
    dir_name = "#{timestamp.utc.strftime('%Y-%m-%d_%H-%M-%S')}_#{type}"
    backup_path = File.join(TEST_TEMP_DIR, dir_name)
    FileUtils.mkdir_p(backup_path)

    chain_start = (type == 'full') ? backup_path : read_metadata(parent)[:chain_start]

    metadata = {
      timestamp: timestamp.utc.iso8601,
      type: type,
      parent: parent,
      chain_start: chain_start
    }
    File.write(File.join(backup_path, 'metadata.json'), JSON.pretty_generate(metadata))
    backup_path
  end
  
  # The actual test of the pruning logic.
  def test_pruning_logic_is_correct
    # Mock Time.now so age calculations are consistent.
    Time.stub :now, @now do
      # Silence the output of the script for a clean test log.
      capture_io { perform_prune }
    end

    # Assert the state of the filesystem after pruning.
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