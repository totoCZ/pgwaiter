# Use a minimal base image
FROM debian:bookworm-slim

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install PostgreSQL APT repository to get a specific client version
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg && \
    curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - && \
    echo "deb http://apt.postgresql.org/pub/repos/apt/ bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update

# Install Python and the PostgreSQL 17 client
RUN apt-get install -y --no-install-recommends \
        python3 \
        postgresql-client-17 && \
    # Clean up APT cache to keep the image small
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the backup script into the container
COPY backup.py /usr/local/bin/backup.py

# Make the script executable
RUN chmod +x /usr/local/bin/backup.py

# Set the default command to run when the container starts
CMD ["/usr/local/bin/backup.py"]