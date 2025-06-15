# PostgreSQL 17+ Incremental Backup & Restore

This project provides a simple, containerized solution for creating and restoring PostgreSQL 17+ backups using its native incremental backup features.

It leverages `pg_basebackup` for creating full and incremental backups and `pg_combinebackup` for restores. This approach creates self-contained backup directories, eliminating the need for a separate WAL archive.

## Features

- **Incremental Backups**: Performs full backups periodically and incremental backups on other days, saving space and time.
- **Self-Contained**: Each backup includes the necessary WAL files (`-X stream`), simplifying restoration.
- **Configurable**: Control backup frequency and retention via environment variables.
- **Automated Pruning**: Automatically deletes old backup chains to manage disk space.
- **Containerized**: Ships as a Docker/Podman container for easy deployment.
- **Simple Restore**: A straightforward script to restore your database to any available point in time.
- **Systemd Integration**: Example systemd units are provided for automated, scheduled backups on a host system.

---

## 1. Prerequisites

- A running PostgreSQL 17+ server.
- Docker or Podman installed on the machine that will run the backups.
- A user/role in PostgreSQL with `REPLICATION` privileges (or a superuser).
- A `.pgpass` file or environment variables set for password-less connection.

---

## 2. Backup Script (`backup.sh`)

The `backup.sh` script performs the following actions:
1. Determines whether to take a new full backup or an incremental one based on the age of the last full backup.
2. Runs `pg_basebackup` to create the backup in `/backups/YYYY-MM-DD_HHMMSS`.
3. Prunes old backup chains based on the `KEEP_CHAINS` setting. A "chain" is one full backup and all its subsequent incrementals.

### Configuration (Environment Variables)

The script is configured using standard PostgreSQL environment variables and two custom ones:

- **`PGHOST`**: The database server host.
- **`PGPORT`**: The database server port.
- **`PGUSER`**: The user to connect as (must have `REPLICATION` privilege).
- **`PGPASSWORD`**: The password for the user. (Using a `.pgpass` file is recommended over this).
- **`FULL_BACKUP_DAYS`**: (Optional) Days between full backups. **Default: `14`**.
- **`KEEP_CHAINS`**: (Optional) Number of *old* backup chains to keep, in addition to the current one. **Default: `1`** (keeps the current chain and the one before it).

### How to Run a Backup

Build the Docker image first:
```bash
docker build -t pg17-backup .
```
Then, run the container. Mount a local directory (e.g., ./backups) to /backups inside the container.

```
# Ensure your local ./backups directory exists
mkdir -p ./backups

# Run a one-off backup
docker run --rm \
  -e PGHOST=your-db-host \
  -e PGUSER=your-replication-user \
  -e PGPASSWORD=your-password \
  -v ./backups:/backups \
  pg17-backup
```

## 3. Restore Script (restore.sh)

The restore.sh script restores a database to a specific point in time using the available backups.

### How to Run a Restore

The restore script takes a single argument: the target restore date and time in a format date can understand (e.g., YYYY-MM-DD HH:MM:SS).

The script will:

1. Find the latest backup created on or before the target time.
2. Trace back from that backup to its parent full backup to identify the complete chain needed for restore.
3. Use pg_combinebackup to create a complete, restored data directory in /restore.
4. Print instructions for the final recovery steps.

Example:

```
# Ensure your local ./restore directory exists and is empty
mkdir -p ./restore && rm -rf ./restore/*

# Run the restore container
# The entrypoint is overridden to call restore.sh
docker run --rm \
  --entrypoint /usr/local/bin/restore.sh \
  -v ./backups:/backups:ro \
  -v ./restore:/restore \
  pg17-backup "2025-05-15 10:30:00"
```

*Note the `:ro` (read-only) flag for the backups volume, which is a good safety practice.*

After the script finishes, follow the on-screen instructions, which will be similar to:

1.  **Configure PostgreSQL**: In your new data directory (`./restore`), edit `postgresql.conf` to set the `restore_command`. Most importantly, set the recovery target. For example:
    ```ini
    # postgresql.conf
    recovery_target_time = '2025-05-15 10:30:00'
    recovery_target_action = 'promote'
    ```

2.  **Signal Recovery**: Create a `recovery.signal` file in the data directory:
    ```bash
    touch ./restore/recovery.signal
    ```

3.  **Start PostgreSQL**: Start your PostgreSQL server pointing to the `./restore` data directory. It will enter recovery mode, replay WALs up to the target time, and then become a normal, running server.

---

## 4. Automation with Systemd

You can schedule the backup script to run daily using systemd timers.

1.  **Create an Environment File**: Store your secrets in a file that the service can read.
    ```bash
    # /etc/pg-backup.env
    PGHOST=your-db-host
    PGUSER=your-replication-user
    PGPASSWORD=your-secret-password
    # Optional overrides
    # FULL_BACKUP_DAYS=7
    # KEEP_CHAINS=2
    ```
    Make sure this file is secure: `sudo chmod 600 /etc/pg-backup.env`

2.  **Copy Systemd Units**: Copy `pg-backup.service` and `pg-backup.timer` to `/etc/systemd/system/`.

3.  **Enable and Start the Timer**:
    ```bash
    sudo systemctl daemon-reload
    sudo systemctl enable pg-backup.timer
    sudo systemctl start pg-backup.timer
    ```

This will trigger the backup service daily at 2 AM. You can check the status with `systemctl status pg-backup.timer` and `journalctl -u pg-backup.service`.
