# ══════════════════════════════════════════════════════
# Stage 1 — base: Ruby + PostgreSQL 18 client on Alpine
# ══════════════════════════════════════════════════════
FROM docker.io/ruby:4-alpine AS base

# pg18 lives in Alpine's edge/community repo
RUN apk add --no-cache \
      --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
      postgresql18-client

# ══════════════════════════════════════════════════════
# Stage 2 — app: drop in the script, nothing else
# ══════════════════════════════════════════════════════
FROM base AS app

WORKDIR /app
COPY backup.rb .
RUN chmod +x backup.rb

ENTRYPOINT ["ruby", "/app/backup.rb"]
CMD ["--help"]