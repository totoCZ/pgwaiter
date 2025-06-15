# Use a slim, modern Ruby base image
FROM ruby:3.4-slim

# Install PostgreSQL client utilities, which include pg_basebackup and pg_combinebackup
# Using bookworm (Debian 12) which has PG15 client tools, compatible with PG17 server.
# For production, you might want to build from a source that has the exact pg_client version.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Create a directory for our application
WORKDIR /app

# Copy the backup script into the container
COPY backup.rb .

# Make the script executable
RUN chmod +x backup.rb

# Set the entrypoint to our script
ENTRYPOINT ["ruby", "/app/backup.rb"]

# The default command if none is provided
CMD ["--help"]