#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require 'open3'

# --- Configuration ---
# Read configuration from environment variables, with sensible defaults.
BACKUP_DIR = '/backups'
RESTORE_DIR = '/restore'
FULL_BACKUP_INTERVAL_DAYS = (ENV['FULL_BACKUP_INTERVAL_DAYS'] || 14).to_i
KEEP_CHAINS = (ENV['KEEP_CHAINS'] || 1).to_i # Number of *past* chains to keep

# --- Helper Functions ---

# Logs a message to standard output.
def log(message)
  puts "#{message}"
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

  JSON.parse(File.read(metadata_file))
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
    chain_start_path = metadata['chain_start']
    last_full_metadata = read_metadata(chain_start_path)
    last_full_time = Time.parse(last_full_metadata['timestamp'])

    if (Time.now - last_full_time) / (24 * 3600) < FULL_BACKUP_INTERVAL_DAYS
      is_full_backup = false
      parent_backup_path = last_backup_path
      log "Last full backup is recent. Performing an incremental backup."
    else
      log "Last full backup is older than #{FULL_BACKUP_INTERVAL_DAYS} days. Performing a new full backup."
    end
  else
    log 'No previous backups found. Performing initial full backup.'
  end

  backup_type = is_full_backup ? 'full' : 'incremental'
  timestamp = Time.now.utc.strftime('%Y-%m-%d_%H-%M-%S')
  current_backup_path = File.join(BACKUP_DIR, "#{timestamp}_#{backup_type}")

  FileUtils.mkdir_p(current_backup_path)
  log "Created backup directory: #{current_backup_path}"

  # Construct pg_basebackup command
  # It automatically uses PGPASSWORD, PGUSER, PGHOST, etc.
  base_cmd = "pg_basebackup --verbose --pgdata='#{current_backup_path}' --format=p --wal-method=fetch"
  
  if is_full_backup
    execute_command(base_cmd)
    chain_start_path = current_backup_path # This backup starts a new chain
  else
    incremental_arg = "--incremental='#{File.join(parent_backup_path, 'backup_manifest')}'"
    execute_command("#{base_cmd} #{incremental_arg}")
  end

  # Create our own metadata file
  our_metadata = {
    timestamp: Time.now.utc.iso8601,
    type: backup_type,
    parent: parent_backup_path,
    chain_start: chain_start_path
  }
  File.write(File.join(current_backup_path, 'metadata.json'), JSON.pretty_generate(our_metadata))
  log "Backup metadata written to #{current_backup_path}/metadata.json"

  log 'Backup complete.'
  perform_prune
end

def perform_prune
  log "Starting pruning process. Keeping current chain + #{KEEP_CHAINS} previous chain(s)."
  all_backups = find_all_backups(BACKUP_DIR)

  # Group backups into chains using our 'chain_start' metadata key
  chains = all_backups.group_by { |path| read_metadata(path)['chain_start'] }
  
  # A chain's identity is its start path. Sort chains by their start time.
  sorted_chains = chains.keys.sort.map { |chain_start_path| chains[chain_start_path] }

  # The last chain is the current, active one. We always keep it.
  # We also keep KEEP_CHAINS number of chains before the current one.
  return log 'No old chains to prune.' if sorted_chains.length <= (1 + KEEP_CHAINS)

  chains_to_prune_count = sorted_chains.length - (1 + KEEP_CHAINS)
  chains_to_prune = sorted_chains.first(chains_to_prune_count)

  log "Found #{sorted_chains.length} chain(s). Pruning #{chains_to_prune.length} chain(s)."

  chains_to_prune.each do |chain|
    log "Pruning chain starting with: #{chain.first}"
    chain.each do |backup_path|
      log "  Deleting #{backup_path}"
      FileUtils.rm_rf(backup_path)
    end
  end
  log 'Pruning complete.'
end

def perform_restore(target_backup_path)
  log "Starting restore process for: #{target_backup_path}"

  unless Dir.exist?(target_backup_path)
    log "ERROR: Target backup path does not exist: #{target_backup_path}"
    exit 1
  end

  # Build the chain of backups needed for restore
  restore_chain = []
  current_path = target_backup_path
  
  while current_path
    metadata = read_metadata(current_path)
    unless metadata
      log "ERROR: Missing metadata.json in #{current_path}. Cannot proceed."
      exit 1
    end
    restore_chain.unshift(current_path) # Prepend to keep chronological order
    current_path = metadata['parent']
  end

  log "Restore requires the following backup chain (oldest to newest):"
  restore_chain.each { |p| log "  - #{p}" }

  FileUtils.rm_rf(RESTORE_DIR) if Dir.exist?(RESTORE_DIR)
  FileUtils.mkdir_p(RESTORE_DIR)
  log "Cleaned and created restore directory: #{RESTORE_DIR}"

  # Construct and run pg_combinebackup command
  # The list of directories must be passed as separate arguments.
  cmd = "pg_combinebackup -o '#{RESTORE_DIR}' #{restore_chain.join(' ')}"
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
      FULL_BACKUP_INTERVAL_DAYS : Days between full backups (default: 14)
      KEEP_CHAINS               : Number of past backup chains to keep (default: 1)
      PG*                       : Standard PostgreSQL variables (PGHOST, PGUSER, PGPASSWORD, etc.)
  HELP
end

# --- Main Execution ---
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