FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    openssl \
    ca-certificates \
    gzip \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL client (pg_dump, pg_restore)
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client-15 \
    && rm -rf /var/lib/apt/lists/*

# MariaDB client (mysqldump, mysql)
RUN apt-get update && apt-get install -y --no-install-recommends \
    mariadb-client \
    && rm -rf /var/lib/apt/lists/*

# Valkey/Redis CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    redis-tools \
    && rm -rf /var/lib/apt/lists/*

# ClickHouse client (static binary)
RUN curl -fsSL https://clickhouse.com/ | sh && \
    mv clickhouse /usr/local/bin/clickhouse && \
    ln -s /usr/local/bin/clickhouse /usr/local/bin/clickhouse-client

# Minio client (mc) for S3 operations
RUN curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc \
    -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc

COPY scripts/ /opt/backup/
RUN chmod +x /opt/backup/*.sh

ENTRYPOINT ["/opt/backup/entrypoint.sh"]
