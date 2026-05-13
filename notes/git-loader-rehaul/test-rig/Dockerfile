FROM python:3.11-bookworm

# Add the PostgreSQL official APT repo (bookworm ships PG-15; we need PG-17 with contrib).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

# System deps: PG-17 (with contrib for btree_gist/pgcrypto/pg_trgm), build tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-17 postgresql-contrib-17 postgresql-client-17 libpq-dev \
      build-essential cmake pkg-config autoconf libssl-dev \
      git \
    && rm -rf /var/lib/apt/lists/*

# Postgres official repo for newer minor versions if needed
# (bookworm currently provides 17.x via the Debian backports/security path automatically).

# Rust toolchain — installed to /usr/local so all users can read+write
# (cargo writes to $CARGO_HOME/registry/ at build time, so a+rwx is needed).
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal --no-modify-path \
    && chmod -R a+rwX /usr/local/rustup /usr/local/cargo

# Test deps — installed once at image-build time so per-cell setup is fast
RUN pip install --no-cache-dir \
      maturin patchelf \
      pytest pytest-timeout pytest-postgresql \
      pytest-mock pytest-randomly pytest-asyncio pytest-cov pytest-xdist \
      pytest-shared-session-scope requests-mock pytz \
      cassandra-driver

# /work is bind-mounted to the host's swh-environment.
WORKDIR /work
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTEST_ADDOPTS="--timeout=60 -ra"

COPY run-cells.sh /usr/local/bin/run-cells.sh
RUN chmod +x /usr/local/bin/run-cells.sh

# PostgreSQL initdb refuses to run as root.  Also: running as uid=1000 matches
# the typical Linux developer user and avoids the bind-mount cross-uid safety
# tripwire (git's "dubious ownership" check).  Pre-create /home/tester/.local
# so pip --user installs land there even before WORKDIR is touched.
RUN useradd -m -u 1000 -s /bin/bash tester \
    && mkdir -p /home/tester/.local \
    && chown -R tester:tester /home/tester
USER tester
ENV PATH=/home/tester/.local/bin:$PATH

ENTRYPOINT ["/usr/local/bin/run-cells.sh"]
