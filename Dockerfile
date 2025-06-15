# Use a slim, modern Ruby base image
FROM docker.io/ruby:3.4-slim

# Install PostgreSQL client utilities for version 17.
# To do this, we add the official PostgreSQL APT repository, as the base image's
# OS (Debian 12 Bookworm) ships with PG15 by default.
RUN apt-get update \
    # Install dependencies needed to add a new repository
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    # Add the PostgreSQL GPG key for verification
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    # Add the PostgreSQL repository source list
    # We explicitly use 'bookworm' as this ruby image is based on Debian 12
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    # Update package lists again to include the new repository
    && apt-get update \
    # Install the specific PG17 client package
    && apt-file search pg_combinebackup
    && apt-get install -y --no-install-recommends postgresql-17-client \
    # Clean up to keep the image small
    && apt-get purge -y --auto-remove curl gnupg \
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