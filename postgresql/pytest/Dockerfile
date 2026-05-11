# syntax=docker/dockerfile:1.4
# ──────────────────────────────────────────────────────────────────────────────
# Percona pg_tde QA – Docker test environment
#
# Two build targets:
#   package-env   Install PostgreSQL + pg_tde from Percona apt repos (default)
#   source-env    Compile PostgreSQL + pg_tde from GitHub source
#
# Key build args:
#   PG_MAJOR        Primary PostgreSQL major version  (default: 18)
#   OLD_PG_MAJOR    Old version for pg_upgrade tests  (default: 17)
#   PG_TDE_REF      pg_tde git branch/tag/sha         (default: main)
#   PG_TDE_REPO     pg_tde git remote URL             (default: Percona-Lab GitHub)
#   PG_REF          PostgreSQL git branch/tag          (default: REL_18_STABLE)
#   PG_REPO         PostgreSQL git remote URL          (default: upstream GitHub)
#   DEBUG_BUILD     Include --enable-debug --enable-cassert (default: true)
#
# Quick start (see docker-compose.yml or run_tests.sh):
#   docker compose run --rm pg-tde-tests-pkg pytest tests/test_encryption.py -v
#   docker compose run --rm pg-tde-tests-src pytest tests/test_recovery.py -v
# ──────────────────────────────────────────────────────────────────────────────

ARG UBUNTU_VER=22.04

# ══════════════════════════════════════════════════════════════════════════════
# Stage 1 – shared base (OS packages, non-root user, Python venv)
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:${UBUNTU_VER} AS base

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        sudo \
        locales \
        python3 \
        python3-venv \
        python3-pip \
        git \
        gcc \
        make \
        pkg-config \
        procps \
        iproute2 \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Non-root user — PostgreSQL refuses to start as root.
# UID 1001 avoids collisions with common host UIDs; override at build time if needed.
ARG PGQA_UID=1001
RUN useradd -m -s /bin/bash -u ${PGQA_UID} pgqa \
    && echo "pgqa ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pgqa \
    && chmod 0440 /etc/sudoers.d/pgqa

# Shared Python venv (filled in each final stage)
RUN python3 -m venv /opt/pgqa-venv \
    && /opt/pgqa-venv/bin/pip install --quiet --upgrade pip \
    && /opt/pgqa-venv/bin/pip install --quiet \
        "pytest>=7.4" \
        "pytest-xdist>=3.0" \
        "pytest-timeout>=2.1" \
        "pytest-html>=4.0" \
        "psutil>=5.9"

ENV VIRTUAL_ENV=/opt/pgqa-venv
ENV PGUSER=pgqa

# ══════════════════════════════════════════════════════════════════════════════
# Stage 2a – Percona package installation
# ══════════════════════════════════════════════════════════════════════════════
FROM base AS package-install

ARG PG_MAJOR=18
ARG OLD_PG_MAJOR=17
ARG PERCONA_RELEASE_URL=https://repo.percona.com/apt/percona-release_latest

# Add Percona release tool and enable repos
RUN CODENAME=$(lsb_release -sc) \
    && curl -fsSL "${PERCONA_RELEASE_URL}.${CODENAME}_all.deb" -o /tmp/percona-release.deb \
    && dpkg -i /tmp/percona-release.deb \
    && rm /tmp/percona-release.deb \
    && percona-release enable ppg-${PG_MAJOR} release \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        percona-postgresql-${PG_MAJOR} \
        percona-postgresql-client-${PG_MAJOR} \
        percona-postgresql-contrib-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

# Install pg_tde — try multiple package name conventions across releases
RUN apt-get update \
    && (apt-get install -y --no-install-recommends "percona-pg-tde-${PG_MAJOR}" 2>/dev/null \
        || apt-get install -y --no-install-recommends "percona-postgresql-${PG_MAJOR}-pg-tde" 2>/dev/null \
        || echo "WARNING: pg_tde package not found for PG${PG_MAJOR}; encryption tests will fail") \
    && rm -rf /var/lib/apt/lists/*

# Old PostgreSQL version for pg_upgrade tests (failure is non-fatal)
RUN percona-release enable ppg-${OLD_PG_MAJOR} release 2>/dev/null || true \
    && apt-get update \
    && (apt-get install -y --no-install-recommends \
           percona-postgresql-${OLD_PG_MAJOR} \
           percona-postgresql-client-${OLD_PG_MAJOR} \
           percona-postgresql-contrib-${OLD_PG_MAJOR} 2>/dev/null \
        || apt-get install -y --no-install-recommends \
           postgresql-${OLD_PG_MAJOR} 2>/dev/null \
        || echo "WARNING: PG${OLD_PG_MAJOR} not installed; upgrade tests will be skipped") \
    && rm -rf /var/lib/apt/lists/*

# pgbackrest for backup tests (best-effort)
RUN apt-get update \
    && (apt-get install -y --no-install-recommends pgbackrest 2>/dev/null || true) \
    && rm -rf /var/lib/apt/lists/*

ENV INSTALL_DIR=/usr/lib/postgresql/${PG_MAJOR}
ENV OLD_INSTALL_DIR=/usr/lib/postgresql/${OLD_PG_MAJOR}

# ══════════════════════════════════════════════════════════════════════════════
# Stage 2b – source build (compile PostgreSQL + pg_tde from GitHub)
# ══════════════════════════════════════════════════════════════════════════════
FROM base AS source-build

ARG PG_MAJOR=18
ARG PG_REF=REL_18_STABLE
ARG PG_REPO=https://github.com/postgres/postgres.git
ARG PG_TDE_REF=main
ARG PG_TDE_REPO=https://github.com/Percona-Lab/pg_tde.git
ARG DEBUG_BUILD=true

ENV PG_INSTALL=/opt/postgresql/${PG_MAJOR}

# Compilation dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        libreadline-dev \
        zlib1g-dev \
        libssl-dev \
        libxml2-dev \
        libxslt1-dev \
        libicu-dev \
        liblz4-dev \
        libzstd-dev \
        libjson-c-dev \
        bison \
        flex \
        perl \
        libperl-dev \
        pgbackrest \
    && rm -rf /var/lib/apt/lists/*

# Build PostgreSQL from source
RUN git clone --depth=1 --branch "${PG_REF}" "${PG_REPO}" /tmp/postgres \
    && cd /tmp/postgres \
    && CONFIGURE_FLAGS="--prefix=${PG_INSTALL} --with-openssl --with-readline --with-zlib --with-lz4 --with-libxml --with-icu" \
    && if [ "${DEBUG_BUILD}" = "true" ]; then \
           CONFIGURE_FLAGS="${CONFIGURE_FLAGS} --enable-debug --enable-cassert"; \
       fi \
    && eval ./configure ${CONFIGURE_FLAGS} \
    && make -j"$(nproc)" world \
    && make install-world \
    && rm -rf /tmp/postgres

# Build pg_tde from source against the just-compiled PostgreSQL
RUN git clone --depth=1 --branch "${PG_TDE_REF}" "${PG_TDE_REPO}" /tmp/pg_tde \
    && cd /tmp/pg_tde \
    && PATH="${PG_INSTALL}/bin:${PATH}" make USE_PGXS=1 -j"$(nproc)" \
    && PATH="${PG_INSTALL}/bin:${PATH}" make USE_PGXS=1 install \
    && rm -rf /tmp/pg_tde

ENV INSTALL_DIR=${PG_INSTALL}
# Source mode only installs one PG version; upgrade tests are skipped unless
# OLD_INSTALL_DIR is set via docker compose environment or -e flag.
ENV OLD_INSTALL_DIR=""

# ══════════════════════════════════════════════════════════════════════════════
# Stage 3a – final test image: package mode
# ══════════════════════════════════════════════════════════════════════════════
FROM package-install AS package-env

ARG PG_MAJOR=18

ENV PATH="/opt/pgqa-venv/bin:/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
USER pgqa

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pytest", "tests/", "-v", "--timeout=120", \
     "-m", "not slow and not vault and not upgrade"]

# ══════════════════════════════════════════════════════════════════════════════
# Stage 3b – final test image: source mode
# ══════════════════════════════════════════════════════════════════════════════
FROM source-build AS source-env

ARG PG_MAJOR=18

ENV PATH="/opt/pgqa-venv/bin:/opt/postgresql/${PG_MAJOR}/bin:${PATH}"

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
USER pgqa

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pytest", "tests/", "-v", "--timeout=120", \
     "-m", "not slow and not vault and not upgrade"]
