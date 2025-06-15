# PostgreSQL 17+ Incremental Backup & Restore Tool

This tool provides an automated, containerized solution for creating and managing full and incremental backups for PostgreSQL 17 and newer, leveraging its native incremental backup capabilities.

It is designed to be run via `podman` and integrated with `systemd` using Quadlets.

## Features

- **Automated Backup Strategy**: Performs a full backup periodically (e.g., every 14 days) and incremental backups on all other days.
- **Chain-Based Pruning**: Safely removes old backup chains (a full backup and its subsequent incrementals), keeping a configurable number of recent chains.
- **Simple Restore**: Can restore from any backup in a chain (full or incremental) to a target directory using `pg_combinebackup`.
- **Containerized**: Runs inside a `podman` container, isolating dependencies.
- **Systemd Integration**: Uses Quadlet files for easy and robust scheduling with `systemd`.
- **Clear Metadata**: Avoids fragile filesystem parsing by saving its own `metadata.json` inside each backup folder.

## Prerequisites

- A running PostgreSQL 17+ server.
- A dedicated PostgreSQL user with the `pg_read_all_data` role (or superuser privileges).
- `podman` installed on the host machine.
- A host OS that uses `systemd` (e.g., Fedora, CentOS, Ubuntu 22.04+).
- postgres with summarize_wal, and wal_summary_keep_time greater than interval between increments (default 10d is enough)

## 1. Setup

### Step 1: Build the Container Image

Clone this repository and build the Podman image from the `Dockerfile`.

```bash
podman build -t postgres-backup:latest .
```

### Step 2: Create Directories and Configuration

Create the host directories for backups and the environment file for secrets.

```bash
# Create directories for backups and restores
sudo mkdir -p /var/lib/pgbackups/data /var/lib/pgbackups/restore
sudo chown your_user:your_user /var/lib/pgbackups/data /var/lib/pgbackups/restore

# Create the environment file for secrets
sudo mkdir -p /etc/default
sudo touch /etc/default/postgres-backup
```

Edit the environment file `/etc/default/postgres-backup` with your database connection details:

```ini
# /etc/default/postgres-backup
PGHOST=your-db-host.or.ip
PGPORT=5432
PGUSER=backup_user
PGPASSWORD=your_super_secret_password
PGDATABASE=postgres

# --- Optional: Script Configuration ---
# Number of days between full backups.
FULL_BACKUP_INTERVAL_DAYS=14

# Number of *past* backup chains to keep, in addition to the current one.
# KEEP_CHAINS=1 means you will have the current chain and one complete old chain.
KEEP_CHAINS=1
```

Set secure permissions for this file:

```bash
sudo chmod 600 /etc/default/postgres-backup
```

### Step 3: Install Quadlet Files

Copy the `.quadlet` and `.timer` files to the systemd user or system location. For system-wide services, use `/etc/containers/systemd/`.

First, edit `backup.quadlet` to use the correct host paths:

```ini
# In backup.quadlet, change these lines:
...
Volume=/var/lib/pgbackups/data:/backups:Z
Volume=/var/lib/pgbackups/restore:/restore:Z
...
```

Now, copy the files and reload systemd:

```bash
# As root, or with sudo
cp backup.quadlet /etc/containers/systemd/
cp backup.timer /etc/containers/systemd/

# Reload systemd to recognize the new files
systemctl daemon-reload
```

### Step 4: Enable and Start the Timer

The timer will trigger the backup service at the scheduled time.

```bash
# Enable the timer to start on boot
systemctl enable --now backup.timer

# Check the status of the timer
systemctl list-timers backup.timer
```

Your automated backups are now configured!

## 2. Usage

### Manual Backup

To trigger a backup manually, you can start the service directly:

```bash
systemctl start backup.service
```

Or run it with `podman` for immediate feedback:

```bash
podman run --rm -it \
  --env-file /etc/default/postgres-backup \
  -v /var/lib/pgbackups/data:/backups:Z \
  localhost/postgres-backup:latest backup
```

### Manual Restore

To restore a backup, you must provide the path to the specific backup directory you want to restore *to*. This can be a full or an incremental backup. The script will automatically find all required parent backups in the chain.

The restored, ready-to-use PostgreSQL data directory will be placed in the `/restore` volume mount.

**Example:** Let's say you want to restore the state from an incremental backup located at `/var/lib/pgbackups/data/2025-05-15_02-00-10_incremental`.

```bash
podman run --rm -it \
  --env-file /etc/default/postgres-backup \
  -v /var/lib/pgbackups/data:/backups:Z \
  -v /var/lib/pgbackups/restore:/restore:Z \
  localhost/postgres-backup:latest restore /backups/2025-05-15_02-00-10_incremental
```

After the command completes, the directory `/var/lib/pgbackups/restore` on your host will contain a full, restored PostgreSQL data directory. You can then copy this directory to your new database server, set up `recovery.signal`, and start PostgreSQL to perform Point-in-Time Recovery using your archived WAL files.