#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require 'open3'

# --- Configuration ---
# Read configuration from environment variables, with sensible defaults.
BACKUP_DIR = ENV['BACKUP_DIR'] || '/backups'
RESTORE_DIR = ENV['RESTORE_DIR'] || '/restore'
FULL_BACKUP_INTERVAL_DAYS = (ENV['FULL_BACKUP_INTERVAL_DAYS'] || 14).to_i

## FIX 1: Convert constants to methods to read ENV at runtime.
# This ensures that tests can modify the environment and the script will see the changes.
def keep_full_days
  (ENV['KEEP_FULL_DAYS'] || 30).to_i
end

def keep_incremental_days
  (ENV['KEEP_INCREMENTAL_DAYS'] || 7).to_i
end

# Default to the path for Postgres 17 client tools, which are not always in the main PATH.
PG_BIN_DIR = ENV['PG_BIN_DIR'] || '/usr/lib/postgresql/17/bin'
SECONDS_IN_A_DAY = 24 * 3600.0 # Use a float for precise division

# --- Helper Functions ---

# Logs a message to standard output.
def log(message)
  puts message.to_s
end

# Constructs the full command path, making the script independent of the system's PATH.
def pg_command(name)
  # If PG_BIN_DIR is configured, use it to build the full path.
  return File.join(PG_BIN_DIR, name) if PG_BIN_DIR && !PG_BIN_DIR.empty?
  # Otherwise, fall back to the original behavior and hope it's in the PATH.
  name
end

# Executes a system command, streaming its output and checking for success.
def execute_command(command)
  log "Executing: #{command}"
  success = Open3.popen2e(command) do |_stdin, stdout_stderr, wait_thr|
    while (line = stdout_stderr.gets)
      puts line
    end
    wait_thr.value.success?
  end

  unless success
    log "ERROR: Command failed: #{command}"
    exit 1
  end
  log 'Command executed successfully.'
end

# Finds all valid backup directories by looking for metadata.json
def find_all_backups(base_dir)
  Dir.glob(File.join(base_dir, '*/metadata.json')).map { |f| File.dirname(f) }.sort
end

# Reads and parses the metadata file for a given backup.
def read_metadata(backup_path)
  metadata_file = File.join(backup_path, 'metadata.json')
  return nil unless File.exist?(metadata_file)

  JSON.parse(File.read(metadata_file), symbolize_names: true)
end

# --- Core Logic ---

def perform_backup
  log 'Starting backup process...'
  FileUtils.mkdir_p(BACKUP_DIR)

  last_backup_path = find_all_backups(BACKUP_DIR).last
  metadata = last_backup_path ? read_metadata(last_backup_path) : nil

  is_full_backup = true
  parent_backup_path = nil
  chain_start_path = nil

  if metadata
    # REFACTOR: Resolve chain_start basename to its full path
    chain_start_basename = metadata[:chain_start]
    chain_start_path = File.join(File.dirname(last_backup_path), chain_start_basename)
    last_full_metadata = read_metadata(chain_start_path)

    if last_full_metadata
      last_full_time = Time.parse(last_full_metadata[:timestamp])
      if (Time.now - last_full_time) / SECONDS_IN_A_DAY < FULL_BACKUP_INTERVAL_DAYS
        is_full_backup = false
        parent_backup_path = last_backup_path
        log 'Last full backup is recent. Performing an incremental backup.'
      else
        log "Last full backup is older than #{FULL_BACKUP_INTERVAL_DAYS} days. Performing a new full backup."
      end
    else
      log "Warning: Could not read metadata for chain start '#{chain_start_path}'. Starting a new full backup."
    end
  else
    log 'No previous backups found. Performing initial full backup.'
  end

  backup_type = is_full_backup ? 'full' : 'incremental'
  timestamp = Time.now.utc.strftime('%Y-%m-%d_%H-%M-%S')
  current_backup_path = File.join(BACKUP_DIR, "#{timestamp}_#{backup_type}")

  FileUtils.mkdir_p(current_backup_path)
  log "Created backup directory: #{current_backup_path}"

  base_cmd = "#{pg_command('pg_basebackup')} --verbose --pgdata='#{current_backup_path}' --format=p"

  if is_full_backup
    execute_command(base_cmd)
    chain_start_path = current_backup_path # This backup starts a new chain
  else
    incremental_arg = "--incremental='#{File.join(parent_backup_path, 'backup_manifest')}'"
    execute_command("#{base_cmd} #{incremental_arg}")
  end

  # REFACTOR: Store parent and chain_start as relative directory names (basenames)
  # This makes the entire backup set portable.
  parent_basename = parent_backup_path ? File.basename(parent_backup_path) : nil
  chain_start_basename = chain_start_path ? File.basename(chain_start_path) : nil

  our_metadata = {
    timestamp: Time.now.utc.iso8601,
    type: backup_type,
    parent: parent_basename,
    chain_start: chain_start_basename
  }
  File.write(File.join(current_backup_path, 'metadata.json'), JSON.pretty_generate(our_metadata))
  log "Backup metadata written to #{current_backup_path}/metadata.json"

  log 'Backup complete.'
  perform_prune
end

def perform_prune
  log "Starting pruning process with policy:"
  # Use the new methods to get current configuration
  log "  - Full backups (and their chains) are kept for #{keep_full_days} days."
  log "  - For retained chains, all incrementals are kept if the OLDEST incremental is newer than #{keep_incremental_days} days."

  ## FIX 2: Get ALL directories, not just those with metadata, so we can find and rename invalid ones.
  all_possible_backup_paths = Dir.glob(File.join(BACKUP_DIR, '*')).select { |f| File.directory?(f) }.sort
  return log('No backups found to prune.') if all_possible_backup_paths.empty?

  # --- REFACTOR: Partition backups into valid and corrupt sets first ---
  valid_backups = []
  corrupt_backups = []

  all_possible_backup_paths.each do |path|
    begin
      metadata = read_metadata(path)
      # A valid backup must have readable metadata with essential keys.
      if metadata && metadata[:chain_start] && metadata[:timestamp]
        valid_backups << path
      else
        corrupt_backups << path
      end
    rescue JSON::ParserError, NoMethodError => e
      log "  DEBUG: Detected corrupt or incomplete metadata for #{path}: #{e.class}"
      corrupt_backups << path
    end
  end

  # Step 1: Quarantine any corrupt backups by renaming them. They will be preserved.
  unless corrupt_backups.empty?
    log "Found #{corrupt_backups.length} backup(s) with missing or corrupt metadata. Quarantining them."
    corrupt_backups.each do |path|
      basename = File.basename(path)
      # Avoid re-renaming an already invalid directory
      next if basename.start_with?('Invalid_')
      
      new_basename = "Invalid_#{basename}"
      new_path = File.join(File.dirname(path), new_basename)
      # In case of collision, add a timestamp to the renamed directory.
      new_path = "#{new_path}_#{Time.now.to_i}" if File.exist?(new_path)

      log "  - Renaming '#{path}' to '#{new_path}' for manual inspection."
      FileUtils.mv(path, new_path)
    end
  end

  # Step 2: Run the pruning logic ONLY on the set of valid backups.
  return log('No valid backups remain to be pruned.') if valid_backups.empty?

  chains = valid_backups.group_by { |path| read_metadata(path)[:chain_start] }
  now = Time.now
  
  sorted_chain_start_basenames = chains.keys.compact.sort_by do |basename|
    chain_start_path = chains[basename].find { |p| File.basename(p) == basename }
    if chain_start_path && (metadata = read_metadata(chain_start_path))
      Time.parse(metadata[:timestamp])
    else
      Time.at(0) # Sort inconsistent chains to the beginning
    end
  end

  valid_backups_to_keep = []

  # Rule 0: Always keep the entire active (most recent) chain.
  current_chain_start_basename = sorted_chain_start_basenames.pop
  if current_chain_start_basename
    log "Keeping the current valid chain (starting with #{current_chain_start_basename}) untouched."
    valid_backups_to_keep.concat(chains[current_chain_start_basename])
  end

  if sorted_chain_start_basenames.empty?
    log('No past valid chains to evaluate for pruning.')
  else
    log "Found #{sorted_chain_start_basenames.length} past valid chain(s) to evaluate for pruning."
  end

  # Evaluate the remaining older valid chains
  sorted_chain_start_basenames.each do |chain_start_basename|
    chain_backups = chains[chain_start_basename]
    chain_start_path = chain_backups.find { |p| File.basename(p) == chain_start_basename }
    full_backup_metadata = read_metadata(chain_start_path) # Assumed to be valid from partitioning

    full_backup_age_days = (now - Time.parse(full_backup_metadata[:timestamp])) / SECONDS_IN_A_DAY
    # Use the new method for the check
    if full_backup_age_days <= keep_full_days
      log "  - Keeping full backup #{File.basename(chain_start_path)} (it's #{full_backup_age_days.to_i} days old)."
      valid_backups_to_keep << chain_start_path

      incrementals = (chain_backups - [chain_start_path]).sort
      if incrementals.empty?
        log '    - No incrementals found in this chain to evaluate.'
      else
        oldest_incremental_path = incrementals.first
        oldest_incremental_metadata = read_metadata(oldest_incremental_path)
        oldest_incremental_age_days = (now - Time.parse(oldest_incremental_metadata[:timestamp])) / SECONDS_IN_A_DAY
        log "    - Oldest incremental is #{File.basename(oldest_incremental_path)} (#{oldest_incremental_age_days.to_i} days old)."

        # Use the new method for the check
        if oldest_incremental_age_days <= keep_incremental_days
          log "    - Keeping all #{incrementals.count} incrementals as the oldest is within the #{keep_incremental_days}-day retention period."
          valid_backups_to_keep.concat(incrementals)
        else
          log "    - Pruning all #{incrementals.count} incrementals as the oldest exceeds the retention period."
        end
      end
    else
      log "  - Pruning entire chain starting at #{File.basename(chain_start_path)} (full backup is #{full_backup_age_days.to_i} days old, exceeds #{keep_full_days} days)."
    end
  end

  # Step 3: Determine what to delete by finding the difference between all *valid* backups and the ones we decided to keep.
  backups_to_delete = valid_backups - valid_backups_to_keep

  if backups_to_delete.empty?
    log 'No valid backups met the pruning criteria.'
  else
    log "Deleting #{backups_to_delete.uniq.count} expired backup(s)..."
    backups_to_delete.uniq.each do |path|
      log "  Deleting #{path}"
      FileUtils.rm_rf(path)
    end
  end
  log 'Pruning complete.'
end

# ... (The rest of the file `perform_restore`, `show_help`, `main execution` remains unchanged)
def perform_restore(target_backup_path)
  log "Starting restore process for: #{target_backup_path}"

  unless Dir.exist?(target_backup_path)
    log "ERROR: Target backup path does not exist: #{target_backup_path}"
    exit 1
  end

  # REFACTOR: Build the chain by resolving relative parent names.
  restore_chain = []
  current_path = target_backup_path
  backup_base_dir = File.dirname(target_backup_path) # All backups in a chain must be in the same directory.

  while current_path
    metadata = read_metadata(current_path)
    unless metadata
      log "ERROR: Missing metadata.json in #{current_path}. Cannot proceed."
      exit 1
    end
    restore_chain.unshift(current_path) # Prepend to keep chronological order

    parent_basename = metadata[:parent]
    if parent_basename
      current_path = File.join(backup_base_dir, parent_basename)
      unless Dir.exist?(current_path)
        log "ERROR: Corrupted chain. Parent backup '#{parent_basename}' not found in #{backup_base_dir}."
        exit 1
      end
    else
      current_path = nil # Reached the full backup, end of the chain.
    end
  end

  log "Restore requires the following backup chain (oldest to newest):"
  restore_chain.each { |p| log "  - #{File.basename(p)}" }

  FileUtils.rm_rf(RESTORE_DIR) if Dir.exist?(RESTORE_DIR)
  FileUtils.mkdir_p(RESTORE_DIR)
  log "Cleaned and created restore directory: #{RESTORE_DIR}"

  cmd = "#{pg_command('pg_combinebackup')} -o '#{RESTORE_DIR}' #{restore_chain.join(' ')}"
  execute_command(cmd)

  log "Restore complete. Data is available in #{RESTORE_DIR}"
  log "Remember to configure recovery.conf/postgresql.auto.conf and provide WAL files for Point-in-Time Recovery."
end

def show_help
  puts <<~HELP
    PostgreSQL Backup & Restore Tool for Postgres 17+

    Usage:
      # Perform a backup (full or incremental) and then prune old backups.
      ruby backup.rb backup

      # Restore a specific backup (full or incremental) to the /restore directory.
      ruby backup.rb restore /backups/path/to/target_backup

      # Show this help message.
      ruby backup.rb --help

    Configuration via Environment Variables:
      BACKUP_DIR                : Directory to store backups (default: /backups).
      RESTORE_DIR               : Directory to restore to (default: /restore).
      FULL_BACKUP_INTERVAL_DAYS : Days between full backups (default: 14).
      KEEP_FULL_DAYS            : Days to keep a full backup. If a full backup is older than this, its entire chain is deleted (default: 30).
      KEEP_INCREMENTAL_DAYS     : Days to keep incremental backups. If the OLDEST incremental in a chain is older, ALL incrementals in that chain are deleted (default: 7).
      PG_BIN_DIR                : Path to PostgreSQL binaries (e.g., /usr/lib/postgresql/17/bin).
      PG*                       : Standard PostgreSQL variables (PGHOST, PGUSER, PGPASSWORD, etc.).
  HELP
end

# --- Main Execution ---
if __FILE__ == $0
  case ARGV[0]
  when 'backup'
    perform_backup
  when 'restore'
    if ARGV[1]
      perform_restore(ARGV[1])
    else
      log 'ERROR: Restore command requires a path to the target backup directory.'
      show_help
      exit 1
    end
  when '--help', '-h', nil
    show_help
  else
    log "ERROR: Unknown command '#{ARGV[0]}'."
    show_help
    exit 1
  end
end