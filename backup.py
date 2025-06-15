#!/usr/bin/env python3

import os
import sys
import subprocess
import shutil
from datetime import datetime, timedelta

# --- Configuration ---
# Read from environment variables
BACKUP_DIR = os.getenv("BACKUP_DIR", "/backups")
RETENTION_DAYS = int(os.getenv("RETENTION_DAYS", "7"))
FULL_BACKUP_DAY = int(os.getenv("FULL_BACKUP_DAY", "1"))
PG_USER = os.getenv("PGUSER")
PG_HOST = os.getenv("PGHOST")

# --- Helper Functions ---

def log(message):
    """Prints a message with a timestamp."""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{timestamp}] {message}")

def run_command(command, env):
    """Executes a shell command and logs its output."""
    log(f"Running command: {' '.join(command)}")
    try:
        process = subprocess.run(
            command,
            check=True,
            text=True,
            capture_output=True,
            env=env
        )
        if process.stdout:
            log(f"STDOUT:\n{process.stdout}")
        if process.stderr:
            log(f"STDERR:\n{process.stderr}")
        log("Command successful.")
    except subprocess.CalledProcessError as e:
        log(f"ERROR: Command failed with exit code {e.returncode}")
        log(f"STDOUT:\n{e.stdout}")
        log(f"STDERR:\n{e.stderr}")
        raise

def find_latest_backup():
    """Finds the most recent backup directory (full or incremental)."""
    try:
        backups = [d for d in os.listdir(BACKUP_DIR) if os.path.isdir(os.path.join(BACKUP_DIR, d))]
        if not backups:
            return None
        # Sort by directory name (timestamp)
        latest_backup = sorted(backups)[-1]
        return os.path.join(BACKUP_DIR, latest_backup)
    except FileNotFoundError:
        return None

def prune_old_backups():
    """
    Deletes backup sets older than RETENTION_DAYS, but NEVER deletes the
    most recent full backup set.
    """
    log("--- Starting Pruning Process ---")
    retention_delta = timedelta(days=RETENTION_DAYS)
    now = datetime.now()

    try:
        # Get all directories and sort them chronologically
        all_dirs = sorted([d for d in os.listdir(BACKUP_DIR) if os.path.isdir(os.path.join(BACKUP_DIR, d))])
    except FileNotFoundError:
        log("Backup directory not found. Nothing to prune.")
        return

    # Identify all the full backups
    full_backups = sorted([d for d in all_dirs if d.endswith("_full")])

    # If there's only one full backup set (or none), we can't prune anything.
    if len(full_backups) <= 1:
        log("Only one (or zero) full backup set exists. Skipping pruning.")
        return

    # We only consider old backup sets for deletion, not the current one.
    # So we iterate up to the second-to-last full backup.
    for i, full_backup_name in enumerate(full_backups[:-1]):
        try:
            backup_date_str = full_backup_name.split('T')[0]
            backup_date = datetime.strptime(backup_date_str, '%Y-%m-%d')
        except (ValueError, IndexError):
            log(f"Could not parse date from directory: {full_backup_name}. Skipping.")
            continue

        # Check if the full backup is older than the retention period
        if now - backup_date > retention_delta:
            log(f"Full backup '{full_backup_name}' is older than {RETENTION_DAYS} days and is superseded. Preparing to delete set.")

            # The set to be deleted starts with this full backup and ends
            # just before the next full backup begins.
            start_dir = full_backup_name
            end_dir = full_backups[i+1] # The next full backup in the list

            # Find all directories in this set to delete
            dirs_to_delete = [d for d in all_dirs if d >= start_dir and d < end_dir]

            for d_to_delete in dirs_to_delete:
                dir_path = os.path.join(BACKUP_DIR, d_to_delete)
                log(f"Deleting: {dir_path}")
                try:
                    shutil.rmtree(dir_path)
                except OSError as e:
                    log(f"Error deleting {dir_path}: {e}")
        else:
            log(f"Full backup '{full_backup_name}' is within retention period.")


# --- Main Backup Logic ---

def main():
    """Main function to run the backup process."""
    log("--- PostgreSQL Incremental Backup Script Started ---")

    if not PG_USER or not PG_HOST:
        log("ERROR: PGUSER and PGHOST environment variables are required.")
        sys.exit(1)

    os.makedirs(BACKUP_DIR, exist_ok=True)
    
    # Get a copy of the current environment to pass to subprocess
    pg_env = os.environ.copy()

    today = datetime.now()
    timestamp = today.strftime("%Y-%m-%dT%H-%M-%S")
    
    is_full_backup_day = (today.day == FULL_BACKUP_DAY)
    latest_backup_path = find_latest_backup()
    
    if is_full_backup_day or not latest_backup_path:
        # --- Perform Full Backup ---
        if not latest_backup_path:
            log("No previous backups found. Performing initial full backup.")
        else:
            log(f"Today is day {today.day}, which is the designated full backup day.")
        
        backup_path = os.path.join(BACKUP_DIR, f"{timestamp}_full")
        command = [
            "pg_basebackup",
            "-D", backup_path,
            "-F", "t",          # Tar format
            "-X", "stream",      # Include required WAL files
            "--checkpoint=fast", # Start backup quickly
            "--label=full_backup",
            "--progress"
        ]
        run_command(command, pg_env)
    else:
        # --- Perform Incremental Backup ---
        log(f"Performing incremental backup based on '{latest_backup_path}'.")
        manifest_path = os.path.join(latest_backup_path, "backup_manifest")
        
        if not os.path.exists(manifest_path):
            log(f"ERROR: backup_manifest not found in '{latest_backup_path}'. Cannot perform incremental backup.")
            sys.exit(1)
            
        backup_path = os.path.join(BACKUP_DIR, f"{timestamp}_incremental")
        command = [
            "pg_basebackup",
            "-D", backup_path,
            "-F", "t",
            "-X", "stream",
            "--checkpoint=fast",
            f"--incremental={manifest_path}",
            "--label=incremental_backup",
            "--progress"
        ]
        run_command(command, pg_env)
        
    # --- Prune Old Backups ---
    prune_old_backups()
    
    log("--- Backup Script Finished Successfully ---")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"An unexpected error occurred: {e}")
        sys.exit(1)