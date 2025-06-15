#!/bin/bash
set -eo pipefail

# --- Configuration ---
# Days between full backups. Can be overridden by env var.
FULL_BACKUP_DAYS=${FULL_BACKUP_DAYS:-14}
# Number of old backup chains to keep, besides the current one.
KEEP_CHAINS=${KEEP_CHAINS:-1}
BACKUP_ROOT="/backups"

# --- Main Logic ---
echo "Starting backup process..."

# Ensure backup root directory exists
mkdir -p "$BACKUP_ROOT"

# Determine if we need a new full backup
# A full backup is identified by the *absence* of the "incremental" flag in its manifest.
# This works for both old and new PostgreSQL versions. Use `grep -L` to find files *without* the match.
# The subshell with `|| true` prevents the script from exiting if `find` returns no files.
LATEST_FULL_DIR=$( (find "$BACKUP_ROOT" -type f -name "backup_manifest" -exec grep -L '"Backup-Mode": "incremental"' {} + || true) | xargs -r dirname | sort -r | head -n 1)
NEEDS_FULL_BACKUP=true

if [ -n "$LATEST_FULL_DIR" ]; then
    echo "Latest full backup found at: $LATEST_FULL_DIR"
    LATEST_FULL_TIMESTAMP=$(basename "$LATEST_FULL_DIR" | sed 's/_/ /')
    LATEST_FULL_EPOCH=$(date -d "$LATEST_FULL_TIMESTAMP" +%s)
    DAYS_AGO=$(( ( $(date +%s) - LATEST_FULL_EPOCH ) / 86400 ))

    if [ "$DAYS_AGO" -lt "$FULL_BACKUP_DAYS" ]; then
        echo "Latest full backup is recent enough ($DAYS_AGO days old). Performing incremental backup."
        NEEDS_FULL_BACKUP=false
    else
        echo "Latest full backup is too old ($DAYS_AGO days old). Performing a new full backup."
    fi
else
    echo "No existing full backup found. Performing initial full backup."
fi

# Create the new backup
BACKUP_TIME=$(date +"%Y-%m-%d_%H%M%S")
TARGET_DIR="$BACKUP_ROOT/$BACKUP_TIME"
mkdir -p "$TARGET_DIR"

echo "Backing up to $TARGET_DIR"

# Use a bash array for safety instead of `eval`
CMD_ARGS=(
    pg_basebackup
    -D "$TARGET_DIR"
    --format=plain
    --wal-method=stream
    --label="Backup $BACKUP_TIME"
    --progress
)

if ! $NEEDS_FULL_BACKUP; then
    # Find the absolute latest backup (full or incremental) to use as a base
    LATEST_BACKUP_DIR=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n 1)
    INCREMENTAL_BASE_MANIFEST=$(find "$LATEST_BACKUP_DIR" -type f -name "backup_manifest")
    echo "Using manifest from $LATEST_BACKUP_DIR for incremental base."
    CMD_ARGS+=(--incremental="$INCREMENTAL_BASE_MANIFEST")
fi

# Execute the backup command safely
"${CMD_ARGS[@]}"

echo "Backup completed successfully."

# --- Pruning Logic ---
echo "Pruning old backup chains..."

# Find all full backups using the correct `grep -L` logic and sort them.
FULL_BACKUPS=( $( (find "$BACKUP_ROOT" -type f -name "backup_manifest" -exec grep -L '"Backup-Mode": "incremental"' {} + || true) | xargs -r dirname | sort) )
NUM_FULL_BACKUPS=${#FULL_BACKUPS[@]}
# We want to keep the current chain plus KEEP_CHAINS older ones.
NUM_TO_KEEP=$((KEEP_CHAINS + 1))

if [ "$NUM_FULL_BACKUPS" -gt "$NUM_TO_KEEP" ]; then
    NUM_TO_PRUNE=$((NUM_FULL_BACKUPS - NUM_TO_KEEP))
    echo "Found $NUM_FULL_BACKUPS full backup chains. Will prune the oldest $NUM_TO_PRUNE."

    # Identify the cutoff directory. Anything older than this directory will be pruned.
    # This is the first directory we want to KEEP.
    CUTOFF_DIR=${FULL_BACKUPS[$NUM_TO_PRUNE]}
    CUTOFF_TIMESTAMP=$(basename "$CUTOFF_DIR" | sed 's/_/ /')
    echo "Pruning all backups older than $CUTOFF_DIR..."

    # Find all backup directories older than the cutoff timestamp and delete them.
    # This is safer and simpler than finding ranges.
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        \! -newermt "$CUTOFF_TIMESTAMP" \
        -exec echo "  Deleting {}" \; -exec rm -rf {} \;

else
    echo "Found $NUM_FULL_BACKUPS full backup chain(s). No pruning needed (keeping up to $NUM_TO_KEEP)."
fi

echo "Backup process finished."