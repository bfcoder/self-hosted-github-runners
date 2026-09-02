#!/usr/bin/env bash
# Weekly prune. With FRESH_WORKSPACE=true the work trees are already wiped per
# job, so what accumulates is (a) tool caches and (b) each dind's image/layer
# store. Both are pruned AGE-BASED, so a running job's working set is never a
# candidate.
set -euo pipefail

TOOL_CACHE_DIRS="${TOOL_CACHE_DIRS:-}"
DIND_HOSTS="${DIND_HOSTS:-}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-14}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-604800}"
DRY_RUN="${DRY_RUN:-false}"
PRUNE_DOCKER="${PRUNE_DOCKER:-true}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

prune_tool_caches() {
  [[ -n "${TOOL_CACHE_DIRS}" ]] || return 0
  IFS=',' read -r -a dirs <<<"${TOOL_CACHE_DIRS}"
  for cache in "${dirs[@]}"; do
    [[ -d "${cache}" ]] || continue
    log "  ${cache} ($(du -sh "${cache}" 2>/dev/null | cut -f1))"
    # Whole tool/version dirs, never individual files: deleting part of a
    # toolchain leaves it half-installed and the next job fails obscurely.
    for version_dir in "${cache}"/*/*; do
      [[ -d "${version_dir}" ]] || continue
      if [[ -z "$(find "${version_dir}" -newermt "-${MAX_AGE_DAYS} days" -print -quit 2>/dev/null)" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
          log "    DRY_RUN would remove stale toolchain: ${version_dir}"
        else
          log "    removing stale toolchain: ${version_dir}"
          rm -rf -- "${version_dir}"
        fi
      fi
    done
  done
}

prune_dind_images() {
  [[ "${PRUNE_DOCKER}" == "true" && -n "${DIND_HOSTS}" ]] || return 0
  local hours=$((MAX_AGE_DAYS * 24))
  IFS=',' read -r -a hosts <<<"${DIND_HOSTS}"
  for h in "${hosts[@]}"; do
    if ! DOCKER_HOST="${h}" docker info >/dev/null 2>&1; then
      log "  ${h}: unreachable, skipped"
      continue
    fi
    local before
    before="$(DOCKER_HOST="${h}" docker system df --format '{{.Size}}' 2>/dev/null | head -1)"
    if [[ "${DRY_RUN}" == "true" ]]; then
      log "  DRY_RUN would prune ${h} (images+builder older than ${hours}h, currently ${before})"
      continue
    fi
    log "  ${h} before: ${before}"
    log "    images:  $(DOCKER_HOST="${h}" docker image prune -af --filter "until=${hours}h" 2>&1 | tail -1)"
    log "    builder: $(DOCKER_HOST="${h}" docker builder prune -af --filter "until=${hours}h" 2>&1 | tail -1)"
  done
}

prune_once() {
  log "=== prune start (max age ${MAX_AGE_DAYS}d, dry_run=${DRY_RUN}) ==="
  log "tool caches:"
  prune_tool_caches
  log "dind image stores:"
  prune_dind_images
  log "=== prune done ==="
}

# Backgrounded sleep + wait, with a trap: a foreground `sleep` would make the
# shell defer SIGTERM until the whole interval elapsed, so `docker compose down`
# would block for the full stop_grace_period on every shutdown.
trap 'log "signal received, shutting down"; exit 0' INT TERM

prune_once
while true; do
  log "sleeping ${INTERVAL_SECONDS}s until next prune"
  sleep "${INTERVAL_SECONDS}" &
  wait $! || true
  prune_once
done
