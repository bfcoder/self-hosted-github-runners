#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Root phase: a bind-mounted /var/run/docker.sock keeps the HOST's group GID,
# which usually matches no group in this image, so `runner` gets EACCES. Create
# a matching group on the fly, then drop privileges and re-exec this script.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
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
  # The bind-mounted work dir arrives owned by root; hand it to `runner`.
  ROOT_PHASE_WORKDIR="${RUNNER_WORKDIR:-/actions-runner/_work}"
  mkdir -p "${ROOT_PHASE_WORKDIR}"
  chown runner:runner "${ROOT_PHASE_WORKDIR}"

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
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/actions-runner/_work}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"

cd /actions-runner

# ---------------------------------------------------------------------------
# Obtain a registration token.
# Either supply RUNNER_TOKEN directly (short-lived, ~1h) or supply GITHUB_PAT
# and let the container mint one on every start (needed for restarts).
# ---------------------------------------------------------------------------
api_scope() {
  # https://github.com/OWNER            -> orgs/OWNER
  # https://github.com/OWNER/REPO       -> repos/OWNER/REPO
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
  HTTP_BODY=""
  HTTP_CODE=""
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

# ---------------------------------------------------------------------------
# Configure.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Deregister cleanly on SIGINT/SIGTERM (docker compose down / stop).
# ---------------------------------------------------------------------------
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
