#!/usr/bin/env bash
set -euo pipefail

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
  RUNNER_TOKEN="$(
    curl -fsSL -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_PAT}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API_BASE}/${SCOPE}/actions/runners/registration-token" | jq -r .token
  )"
  [[ -n "${RUNNER_TOKEN}" && "${RUNNER_TOKEN}" != "null" ]] || { echo "Failed to get registration token" >&2; exit 1; }
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
