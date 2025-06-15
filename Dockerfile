# Use a slim base image with PostgreSQL 17 client tools
FROM debian:bookworm-slim

# Install dependencies and PostgreSQL 17 client
RUN apt-get update \
    && apt-get install -y --no-install-recommends gnupg curl ca-certificates lsb-release \
    # Add PostgreSQL APT repository
    && curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    # Install the client
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-17 \
    # Clean up
    && apt-get purge -y --auto-remove gnupg curl ca-certificates lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Copy the scripts into the container
COPY backup.sh /usr/local/bin/backup.sh
COPY restore.sh /usr/local/bin/restore.sh

# Make them executable
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh

# Set up the backup volume
VOLUME /backups

# Set the default command to run the backup script
ENTRYPOINT ["/usr/local/bin/backup.sh"]