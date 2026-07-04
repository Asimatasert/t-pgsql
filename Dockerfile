# t-pgsql — PostgreSQL dump/restore/sync tool, containerized.
#
# The PostgreSQL client major version is a build arg. Set it to the version of
# your TARGET server so cross-version dumps are produced with the right tools
# (e.g. dumping a PG16 server for restore into PG18 → build with PG_MAJOR=18).
#
#   docker build --build-arg PG_MAJOR=18 -t t-pgsql:18 .
#   docker run --rm t-pgsql:18 --version
#
FROM debian:bookworm-slim

ARG PG_MAJOR=18

# Runtime deps: PostgreSQL client (pg_dump/pg_restore/psql), ssh, external
# compressors, pv (stream progress), python3 (bot JSON parsing), curl (notifications).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "postgresql-client-${PG_MAJOR}" \
        openssh-client zstd xz-utils bzip2 pv python3; \
    apt-get purge -y --auto-remove gnupg; \
    rm -rf /var/lib/apt/lists/*

# Non-root user; /data is the working dir for jobs.yaml, dumps and secrets (mount here).
# Pre-create /data/dumps owned by the runtime user so a fresh named volume mounted
# there inherits that ownership and is writable (Docker seeds empty named volumes
# from the image path). For bind mounts, make the host dir writable by UID 10001
# (or run with --user "$(id -u):$(id -g)").
RUN useradd --create-home --uid 10001 tpgsql \
    && install -d -o tpgsql -g tpgsql /data /data/dumps
COPY t-pgsql /usr/local/bin/t-pgsql
RUN chmod 0755 /usr/local/bin/t-pgsql

USER tpgsql
WORKDIR /data
ENV T_PGSQL_IN_DOCKER=1
# Default dump output inside the container (mount a volume here to persist).
ENV T_PGSQL_OUTPUT_DIR=/data/dumps

ENTRYPOINT ["t-pgsql"]
CMD ["--help"]
