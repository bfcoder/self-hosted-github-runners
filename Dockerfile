FROM ubuntu:24.04

# Set at build time: docker build --build-arg RUNNER_VERSION=2.328.0 ...
# Leave empty to resolve the latest release from the GitHub API at build time.
ARG RUNNER_VERSION=""
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# Base tooling + the runner's own dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git jq unzip zip tar gzip \
        sudo gnupg lsb-release build-essential \
        libicu74 liblttng-ust1 libkrb5-3 zlib1g libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Native build dependencies. Hosted runner images ship these, and -sys crates
# (openssl-sys, libsqlite3-sys, pq-sys) fail at build time without them:
# openssl-sys shells out to pkg-config and cannot proceed if it is missing.
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config libssl-dev \
        cmake clang llvm libclang-dev \
        libsqlite3-dev libpq-dev zlib1g-dev \
        libxml2-dev libxmlsec1-dev libxmlsec1-openssl libxslt1-dev \
    && rm -rf /var/lib/apt/lists/*

# Database clients. Hosted images ship these; workflows use them to talk to
# `services:` containers (psql for setup SQL, redis-cli for cache checks).
RUN apt-get update && apt-get install -y --no-install-recommends \
        postgresql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

# Python. Hosted images ship it, and plenty of actions and helper scripts
# assume `python3` exists. venv is included because Ubuntu 24.04 marks the
# system interpreter externally-managed (PEP 668), so `pip install` outside a
# virtualenv refuses to run.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI + compose plugin, so jobs can talk to a mounted Docker socket.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# The runner refuses to run as root, so give it its own user.
# UID 1001 avoids clashing with ubuntu:24.04's built-in "ubuntu" user (1000).
# Layout mirrors a GitHub-hosted runner: HOME=/home/runner, work tree at
# /home/runner/work, tool cache at /opt/hostedtoolcache, uid 1001.
RUN useradd -m -u 1001 -s /bin/bash runner \
    && echo "runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && mkdir -p /actions-runner /home/runner/work /opt/hostedtoolcache /mnt/externals \
    && chown -R runner:runner /actions-runner /home/runner /opt/hostedtoolcache /mnt/externals

WORKDIR /actions-runner

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) RUNNER_ARCH=x64 ;; \
        arm64) RUNNER_ARCH=arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    VERSION="${RUNNER_VERSION}"; \
    if [ -z "${VERSION}" ]; then \
        VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"; \
    fi; \
    echo "Installing actions/runner ${VERSION} (${RUNNER_ARCH})"; \
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-${RUNNER_ARCH}-${VERSION}.tar.gz"; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz; \
    ./bin/installdependencies.sh; \
    echo "${VERSION}" > /actions-runner/.runner-version; \
    chown -R runner:runner /actions-runner

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Deliberately NOT `USER runner`: the entrypoint starts as root only to align the
# container's group with the host's Docker socket GID, then drops to `runner`
# via setpriv. The actions runner itself never runs as root.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
