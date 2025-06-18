require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'time'
# We need to load the original script to get access to its methods.
# We use `load` instead of `require` to allow for easier re-loading in test environments if needed.
load './backup.rb'

class TestBackupPruning < Minitest::Test
  # This setup method runs before each test.
  def setup
    # --- Test Configuration ---
    # Create a temporary directory for our test backups to avoid touching real data.
    @test_dir = Dir.mktmpdir("backup_test")
    
    # Override the constants from the script for this test run.
    # By using a temporary directory and overriding constants, we isolate the test.
    Object.const_set('BACKUP_DIR', @test_dir)
    Object.const_set('KEEP_FULL_DAYS', 30)
    Object.const_set('KEEP_INCREMENTAL_DAYS', 7)

    # We need a fixed point in time to make our age calculations predictable.
    @now = Time.parse('2023-01-15T12:00:00Z')
    
    # --- Create a mock backup history ---
    # This structure is designed to test every rule in the pruning logic.

    # Scenario 1: A very old chain.
    # The full backup is > 30 days old.
    # EXPECTATION: The entire chain should be deleted.
    chain1_full = create_mock_backup(type: 'full', timestamp: @now - 45 * SECONDS_IN_A_DAY) # 45 days old
    create_mock_backup(type: 'incremental', parent: chain1_full, timestamp: @now - 44 * SECONDS_IN_A_DAY)

    # Scenario 2: A mid-age chain.
    # The full backup is < 30 days old, but its oldest incremental is > 7 days old.
    # EXPECTATION: The full backup should be KEPT, but its incrementals should be DELETED.
    chain2_full = create_mock_backup(type: 'full', timestamp: @now - 20 * SECONDS_IN_A_DAY) # 20 days old
    create_mock_backup(type: 'incremental', parent: chain2_full, timestamp: @now - 10 * SECONDS_IN_A_DAY) # 10 days old
    create_mock_backup(type: 'incremental', parent: chain2_full, timestamp: @now - 9 * SECONDS_IN_A_DAY) # 9 days old
    
    # Scenario 3: A recent, active chain.
    # The full backup is < 30 days old, and its incrementals are < 7 days old.
    # EXPECTATION: The entire chain should be KEPT because it's the most recent one.
    chain3_full = create_mock_backup(type: 'full', timestamp: @now - 5 * SECONDS_IN_A_DAY) # 5 days old
    create_mock_backup(type: 'incremental', parent: chain3_full, timestamp: @now - 2 * SECONDS_IN_A_DAY) # 2 days old
  end

  # This teardown method runs after each test.
  def teardown
    # Clean up the temporary directory.
    FileUtils.rm_rf(@test_dir)
    # Restore original constants to avoid side-effects if other tests are added
    Object.const_set('BACKUP_DIR', '/backups')
    Object.const_set('KEEP_FULL_DAYS', 30)
    Object.const_set('KEEP_INCREMENTAL_DAYS', 7)
  end

  # Helper method to create a fake backup directory and metadata file.
  # This simulates the output of the `perform_backup` function.
  def create_mock_backup(type:, timestamp:, parent: nil)
    dir_name = "#{timestamp.utc.strftime('%Y-%m-%d_%H-%M-%S')}_#{type}"
    backup_path = File.join(@test_dir, dir_name)
    FileUtils.mkdir_p(backup_path)

    chain_start = (type == 'full') ? backup_path : read_metadata(parent)[:chain_start]

    metadata = {
      timestamp: timestamp.utc.iso8601,
      type: type,
      parent: parent,
      chain_start: chain_start
    }
    File.write(File.join(backup_path, 'metadata.json'), JSON.pretty_generate(metadata))
    # Return the path for use as a parent in subsequent calls
    backup_path
  end
  
  # The actual test of the pruning logic.
  def test_pruning_logic_is_correct
    # Mock Time.now so the age calculations in perform_prune are consistent.
    Time.stub :now, @now do
      # Silence the output of the script during the test run
      original_stdout = $stdout
      $stdout = StringIO.new
      
      # Run the function we are testing
      perform_prune
      
      # Restore stdout
      $stdout = original_stdout
    end

    # Now, we assert the state of the filesystem after pruning.
    remaining_backups = find_all_backups(@test_dir).map { |p| File.basename(p) }
    
    # --- VERIFY SCENARIO 1 ---
    # The entire chain (full + incremental) should be gone.
    assert_equal 0, remaining_backups.grep(/_full$/).select { |b| b.start_with?(Time.at(@now.to_i - 45 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 45-day-old full backup should have been pruned"
    assert_equal 0, remaining_backups.grep(/_incremental$/).select { |b| b.start_with?(Time.at(@now.to_i - 44 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 44-day-old incremental backup should have been pruned"

    # --- VERIFY SCENARIO 2 ---
    # The full backup is kept, but its incrementals are pruned.
    assert_equal 1, remaining_backups.grep(/_full$/).select { |b| b.start_with?(Time.at(@now.to_i - 20 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 20-day-old full backup should be kept"
    assert_equal 0, remaining_backups.grep(/_incremental$/).select { |b| b.start_with?(Time.at(@now.to_i - 10 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 10-day-old incremental should have been pruned"
    assert_equal 0, remaining_backups.grep(/_incremental$/).select { |b| b.start_with?(Time.at(@now.to_i - 9 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 9-day-old incremental should have been pruned"
    
    # --- VERIFY SCENARIO 3 ---
    # The entire active chain should be untouched.
    assert_equal 1, remaining_backups.grep(/_full$/).select { |b| b.start_with?(Time.at(@now.to_i - 5 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 5-day-old full backup (active chain) should be kept"
    assert_equal 1, remaining_backups.grep(/_incremental$/).select { |b| b.start_with?(Time.at(@now.to_i - 2 * SECONDS_IN_A_DAY.to_i).utc.strftime('%Y-%m-%d')) }.count, "The 2-day-old incremental (active chain) should be kept"

    # Finally, check the total count of remaining backups.
    # We expect 1 full from scenario 2, and 1 full + 1 incremental from scenario 3. Total = 3.
    assert_equal 3, remaining_backups.count, "There should be exactly 3 backups remaining"
  end
end