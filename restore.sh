#!/bin/bash
set -eo pipefail

TARGET_DATE="$1"
BACKUP_ROOT="/backups"
RESTORE_DIR="/restore"

if [ -z "$TARGET_DATE" ]; {
    echo "Error: Please provide a target restore date/time as the first argument."
    echo "Usage: ./restore.sh \"YYYY-MM-DD HH:MM:SS\""
    exit 1
}

echo "Attempting to restore to state at or before: $TARGET_DATE"
TARGET_EPOCH=$(date -d "$TARGET_DATE" +%s)

# Find the latest backup directory created on or before the target date
TARGET_BACKUP_DIR=""
for dir in $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort); do
    BACKUP_TIMESTAMP=$(basename "$dir" | sed 's/_/ /')
    BACKUP_EPOCH=$(date -d "$BACKUP_TIMESTAMP" +%s)
    if [ "$BACKUP_EPOCH" -le "$TARGET_EPOCH" ]; then
        TARGET_BACKUP_DIR=$dir
    else
        break # Backups are sorted, so we can stop
    fi
done

if [ -z "$TARGET_BACKUP_DIR" ]; then
    echo "Error: No backup found on or before the specified date."
    exit 1
fi

echo "Found target backup: $TARGET_BACKUP_DIR"

# Trace back from the target backup to its full backup to build the chain
echo "Building backup chain..."
BACKUP_CHAIN=()
CURRENT_BACKUP_DIR=$TARGET_BACKUP_DIR

while [ -n "$CURRENT_BACKUP_DIR" ]; do
    BACKUP_CHAIN=("$CURRENT_BACKUP_DIR" "${BACKUP_CHAIN[@]}") # Prepend to array
    MANIFEST_FILE="$CURRENT_BACKUP_DIR/backup_manifest"
    if grep -q '"Backup-Mode": "full"' "$MANIFEST_FILE"; then
        echo "  Found full backup base: $CURRENT_BACKUP_DIR"
        break
    else
        # Extract the path of the parent manifest, get its directory
        PARENT_MANIFEST=$(grep '"Incremental-Base-Manifest-Path"' "$MANIFEST_FILE" | sed -E 's/.*: "(.*)",/\1/')
        CURRENT_BACKUP_DIR=$(dirname "$PARENT_MANIFEST")
        echo "  Found incremental backup: $(basename ${BACKUP_CHAIN[0]}) -> parent: $(basename $CURRENT_BACKUP_DIR)"
    fi
done

echo "Restore chain consists of:"
printf "  %s\n" "${BACKUP_CHAIN[@]}"

# Ensure restore directory is empty
if [ "$(ls -A $RESTORE_DIR)" ]; then
   echo "Error: Restore directory $RESTORE_DIR is not empty. Please clear it before restoring."
   exit 1
fi

echo "Combining backups into $RESTORE_DIR..."
pg_combinebackup -o "$RESTORE_DIR" "${BACKUP_CHAIN[@]}"

echo -e "\n--- Restore Complete ---"
echo "A complete data directory has been created in $RESTORE_DIR."
echo "To finish recovery, follow these steps:"
echo "1. Edit '$RESTORE_DIR/postgresql.conf' and set the recovery target."
echo "   For example:"
echo "   recovery_target_time = '$TARGET_DATE'"
echo "   recovery_target_action = 'promote' # or 'pause' or 'shutdown'"
echo ""
echo "2. Create a recovery signal file in the data directory:"
echo "   touch $RESTORE_DIR/recovery.signal"
echo ""
echo "3. Ensure file permissions are correct for the postgres user."
echo "   chown -R postgres:postgres $RESTORE_DIR"
echo ""
echo "4. Start your PostgreSQL server using the new data directory."