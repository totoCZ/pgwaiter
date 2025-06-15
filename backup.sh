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
LATEST_FULL_DIR=$(find "$BACKUP_ROOT" -type f -name "backup_manifest" -exec grep -l '"Backup-Mode": "full"' {} + | xargs -r dirname | sort -r | head -n 1)
INCREMENTAL_BASE_MANIFEST=""
NEEDS_FULL_BACKUP=true

if [ -n "$LATEST_FULL_DIR" ]; then
    echo "Latest full backup found at: $LATEST_FULL_DIR"
    LATEST_FULL_TIMESTAMP=$(basename "$LATEST_FULL_DIR" | sed 's/_/ /')
    LATEST_FULL_EPOCH=$(date -d "$LATEST_FULL_TIMESTAMP" +%s)
    DAYS_AGO=$(( ( $(date +%s) - LATEST_FULL_EPOCH ) / 86400 ))

    if [ "$DAYS_AGO" -lt "$FULL_BACKUP_DAYS" ]; then
        echo "Latest full backup is recent enough ($DAYS_AGO days old). Performing incremental backup."
        NEEDS_FULL_BACKUP=false
        # Find the absolute latest backup (full or incremental) to use as a base
        LATEST_BACKUP_DIR=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n 1)
        INCREMENTAL_BASE_MANIFEST="$LATEST_BACKUP_DIR/backup_manifest"
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
CMD="pg_basebackup -D \"$TARGET_DIR\" --format=plain --wal-method=stream --label=\"Backup $BACKUP_TIME\" --progress"

if ! $NEEDS_FULL_BACKUP; then
    CMD="$CMD --incremental=\"$INCREMENTAL_BASE_MANIFEST\""
fi

# Execute the backup command
eval "$CMD"

echo "Backup completed successfully."

# --- Pruning Logic ---
echo "Pruning old backup chains..."
# Find all full backups and sort them chronologically
FULL_BACKUPS=($(find "$BACKUP_ROOT" -type f -name "backup_manifest" -exec grep -l '"Backup-Mode": "full"' {} + | xargs -r dirname | sort))
NUM_FULL_BACKUPS=${#FULL_BACKUPS[@]}
NUM_TO_KEEP=$((KEEP_CHAINS + 1)) # Keep current chain + N old chains

if [ "$NUM_FULL_BACKUPS" -gt "$NUM_TO_KEEP" ]; then
    NUM_TO_PRUNE=$((NUM_FULL_BACKUPS - NUM_TO_KEEP))
    echo "Found $NUM_FULL_BACKUPS full backup chains. Will prune the oldest $NUM_TO_PRUNE."

    for i in $(seq 0 $((NUM_TO_PRUNE - 1))); do
        CHAIN_START_DIR=${FULL_BACKUPS[$i]}
        # The chain ends right before the next full backup starts
        NEXT_CHAIN_START_DIR=${FULL_BACKUPS[$((i + 1))]}

        echo "Pruning chain starting at $CHAIN_START_DIR..."
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
            -newermt "$(basename "$CHAIN_START_DIR" | sed 's/_/ /')" \
            \! -newermt "$(basename "$NEXT_CHAIN_START_DIR" | sed 's/_/ /')" \
            -exec echo "  Deleting {}" \; -exec rm -rf {} \;
        
        # Also delete the chain start dir itself
        echo "  Deleting $CHAIN_START_DIR"
        rm -rf "$CHAIN_START_DIR"
    done
else
    echo "Found $NUM_FULL_BACKUPS full backup chain(s). No pruning needed (keeping $NUM_TO_KEEP)."
fi

echo "Backup process finished."