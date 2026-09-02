#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Root phase. Fixes up ownership of the shared volumes, seeds the externals
# volume the sibling dockerd needs, then drops to `runner` and re-execs.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then

  # Only relevant when a host socket is bind-mounted instead of using dind.
  if [[ -S /var/run/docker.sock ]]; then
    SOCK_GID="$(stat -c %g /var/run/docker.sock)"
    if [[ "${SOCK_GID}" -eq 0 ]]; then
      echo "WARNING: docker.sock is owned by group root; jobs using Docker will fail." >&2
    else
      SOCK_GROUP="$(getent group "${SOCK_GID}" | cut -d: -f1 || true)"
      if [[ -z "${SOCK_GROUP}" ]]; then
        SOCK_GROUP=dockerhost
        groupadd -g "${SOCK_GID}" "${SOCK_GROUP}"
      fi
      usermod -aG "${SOCK_GROUP}" runner
      echo "Granted runner access to docker.sock via group ${SOCK_GROUP} (gid ${SOCK_GID})"
    fi
  fi

  # Fresh volumes arrive root-owned. Non-recursive: chown -R over a warm tool
  # cache is slow, and everything inside is created by runner anyway.
  for d in "${RUNNER_WORKDIR:-/home/runner/work}" \
           "/home/runner" \
           "${AGENT_TOOLSDIRECTORY:-/opt/hostedtoolcache}" \
           "${EXTERNALS_SYNC_DIR:-}"; do
    [[ -n "${d}" ]] || continue
    mkdir -p "${d}"
    chown runner:runner "${d}"
  done

  # A `container:` job makes the runner mount /actions-runner/externals into the
  # job container. That path is resolved by the DAEMON, so the sibling dockerd
  # needs the same content at the same path. Sync it into the shared volume,
  # keyed on the runner version so an image upgrade re-seeds it.
  if [[ -n "${EXTERNALS_SYNC_DIR:-}" && -d /actions-runner/externals ]]; then
    IMAGE_VERSION="$(cat /actions-runner/.runner-version 2>/dev/null || echo unknown)"
    VOLUME_VERSION="$(cat "${EXTERNALS_SYNC_DIR}/.runner-version" 2>/dev/null || echo none)"
    if [[ "${IMAGE_VERSION}" != "${VOLUME_VERSION}" ]]; then
      echo "Seeding externals for runner ${IMAGE_VERSION} (volume had: ${VOLUME_VERSION})"
      rm -rf "${EXTERNALS_SYNC_DIR:?}"/*
      cp -a /actions-runner/externals/. "${EXTERNALS_SYNC_DIR}/"
      echo "${IMAGE_VERSION}" > "${EXTERNALS_SYNC_DIR}/.runner-version"
      chown -R runner:runner "${EXTERNALS_SYNC_DIR}"
      echo "Externals seeded."
    fi
  fi

  # setpriv swaps the uid but leaves the environment alone, so HOME would stay
  # /root (mode 0700) and every git/node call would EACCES on ~/.gitconfig.
  export HOME=/home/runner
  export USER=runner
  export LOGNAME=runner

  exec setpriv --reuid runner --regid runner --init-groups "$0" "$@"
fi

: "${GITHUB_URL:?Set GITHUB_URL, e.g. https://github.com/my-org or https://github.com/my-org/my-repo}"

RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-runner}-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,docker}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/home/runner/work}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
FRESH_WORKSPACE="${FRESH_WORKSPACE:-true}"

cd /actions-runner

# ---------------------------------------------------------------------------
# A hosted runner gets a brand-new VM per job. Compose restarts the same
# container, so the work tree would carry over; wipe it to match. _tool is NOT
# in here (it lives in /opt/hostedtoolcache), so toolchains survive, which is
# what hosted runners do with their preinstalled tools.
# ---------------------------------------------------------------------------
if [[ "${FRESH_WORKSPACE}" == "true" ]]; then
  if [[ -n "$(ls -A "${RUNNER_WORKDIR}" 2>/dev/null)" ]]; then
    echo "Clearing work tree ${RUNNER_WORKDIR} (FRESH_WORKSPACE=true)"
    rm -rf "${RUNNER_WORKDIR:?}"/* "${RUNNER_WORKDIR:?}"/.[!.]* 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Wait for the sibling dockerd. Without this the first job races the daemon
# and fails on an image pull for no obvious reason.
# ---------------------------------------------------------------------------
if [[ -n "${DOCKER_HOST:-}" ]]; then
  echo "Waiting for Docker daemon at ${DOCKER_HOST}"
  for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      echo "Docker daemon ready ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
      break
    fi
    [[ "${i}" -eq 60 ]] && { echo "ERROR: no Docker daemon at ${DOCKER_HOST} after 60s" >&2; exit 1; }
    sleep 1
  done
fi

# ---------------------------------------------------------------------------
# Obtain a registration token. Either supply RUNNER_TOKEN directly (short-lived,
# ~1h) or supply GITHUB_PAT and let the container mint one on every start.
# ---------------------------------------------------------------------------
api_scope() {
  local path="${GITHUB_URL#*://}"
  path="${path#*/}"
  path="${path%/}"
  if [[ "${path}" == */* ]]; then
    echo "repos/${path}"
  else
    echo "orgs/${path}"
  fi
}

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  : "${GITHUB_PAT:?Set RUNNER_TOKEN or GITHUB_PAT}"
  API_BASE="${GITHUB_API_URL:-https://api.github.com}"
  SCOPE="$(api_scope)"
  echo "Requesting registration token from ${API_BASE}/${SCOPE}"
  RESPONSE="$(
    curl -sS -w $'\n%{http_code}' -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_PAT}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API_BASE}/${SCOPE}/actions/runners/registration-token" 2>&1
  )" || { echo "ERROR: could not reach ${API_BASE} - ${RESPONSE}" >&2; exit 1; }

  HTTP_CODE="$(tail -n1 <<<"${RESPONSE}")"
  HTTP_BODY="$(sed '$d' <<<"${RESPONSE}")"

  if [[ "${HTTP_CODE}" != "201" ]]; then
    echo "ERROR: GitHub API returned HTTP ${HTTP_CODE} for ${SCOPE}" >&2
    echo "       $(jq -r '.message // .' <<<"${HTTP_BODY}" 2>/dev/null || echo "${HTTP_BODY}")" >&2
    echo "       Check GITHUB_URL and that GITHUB_PAT has admin:org (org) or repo (repo) scope." >&2
    exit 1
  fi

  RUNNER_TOKEN="$(jq -r .token <<<"${HTTP_BODY}")"
  [[ -n "${RUNNER_TOKEN}" && "${RUNNER_TOKEN}" != "null" ]] || { echo "ERROR: no token in API response" >&2; exit 1; }
fi

CONFIG_ARGS=(
  --url "${GITHUB_URL}"
  --token "${RUNNER_TOKEN}"
  --name "${RUNNER_NAME}"
  --labels "${RUNNER_LABELS}"
  --runnergroup "${RUNNER_GROUP}"
  --work "${RUNNER_WORKDIR}"
  --unattended
  --replace
)
[[ "${RUNNER_EPHEMERAL}" == "true" ]] && CONFIG_ARGS+=(--ephemeral)

echo "Configuring runner '${RUNNER_NAME}' against ${GITHUB_URL}"
./config.sh "${CONFIG_ARGS[@]}"

cleanup() {
  echo "Removing runner '${RUNNER_NAME}' from ${GITHUB_URL}"
  ./config.sh remove --token "${RUNNER_TOKEN}" || true
}
trap 'cleanup; exit 0' INT TERM

./run.sh &
RUNNER_PID=$!
EXIT_CODE=0
wait "${RUNNER_PID}" || EXIT_CODE=$?

# Ephemeral runners exit after one job; the container restarts and re-registers.
cleanup
exit "${EXIT_CODE}"
