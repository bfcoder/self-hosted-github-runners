#!/usr/bin/env bash
# Samples this container's cgroup memory for the life of a job, so a build that
# dies without a diagnostic can be explained after the fact rather than by
# re-running CI. Output goes to stdout, which is `docker compose logs runner-N`.
#
# The decisive field is memory.events:oom_kill. If it climbs, the kernel killed
# something in this container - and a compiler killed that way reports no error
# of its own (sccache turns SIGKILL into a bare exit code 2).
set -uo pipefail

INTERVAL="${MEM_SAMPLE_INTERVAL:-5}"
STEP_PCT="${MEM_SAMPLE_STEP_PCT:-10}"
CG=/sys/fs/cgroup

read_val()  { [[ -r "$1" ]] && cat "$1" 2>/dev/null || echo ""; }
event_of()  { awk -v k="$1" '$1==k{print $2}' "${CG}/memory.events" 2>/dev/null; }
human()     { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }
log()       { echo "[mem] $(date -u '+%H:%M:%SZ') $*"; return 0; }

snapshot() {
  ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -5 | while read -r rss comm; do
    [[ -n "${rss:-}" ]] && echo "[mem]          $(human $((rss * 1024)))  ${comm}"
  done
  return 0
}

# The OOM victim is already gone by the time we poll, so keep the previous
# snapshot: that is the one that names what was actually large.
PREV_SNAPSHOT=""
show_prev() {
  if [[ -n "${PREV_SNAPSHOT}" ]]; then
    log "       largest processes at the previous sample:"
    echo "${PREV_SNAPSHOT}"
  fi
  return 0
}

LIMIT="$(read_val ${CG}/memory.max)"
[[ "${LIMIT}" == "max" || -z "${LIMIT}" ]] && LIMIT=0
OOM_BASE="$(event_of oom_kill)"; OOM_BASE="${OOM_BASE:-0}"
OOM_SEEN="${OOM_BASE}"
BAND=0

summary() {
  local peak oom killed pct=""
  peak="$(read_val ${CG}/memory.peak)"; peak="${peak:-0}"
  oom="$(event_of oom_kill)"; oom="${oom:-0}"
  killed=$(( oom - OOM_BASE ))
  [[ "${LIMIT}" -gt 0 && "${peak}" -gt 0 ]] && pct=" ($(( peak * 100 / LIMIT ))% of limit)"
  log "SUMMARY peak=$(human "${peak}")${pct} oom_kills=${killed}"
  if [[ "${killed}" -gt 0 ]]; then
    log "SUMMARY the kernel killed ${killed} process(es) in this container."
    log "SUMMARY a build step that failed with no diagnostic was almost certainly one of them."
  fi
  exit 0
}
trap summary INT TERM

log "sampler started (every ${INTERVAL}s; limit $( [[ "${LIMIT}" -gt 0 ]] && human "${LIMIT}" || echo unlimited ))"

while true; do
  cur="$(read_val ${CG}/memory.current)"; cur="${cur:-0}"
  oom="$(event_of oom_kill)"; oom="${oom:-0}"

  if [[ "${oom}" -gt "${OOM_SEEN}" ]]; then
    log "OOM KILL  $(( oom - OOM_SEEN )) process(es) killed by the kernel; current=$(human "${cur}")"
    show_prev
    OOM_SEEN="${oom}"
  fi

  # Only speak when usage crosses a new band, so a quiet job stays quiet.
  if [[ "${LIMIT}" -gt 0 ]]; then
    band=$(( cur * 100 / LIMIT / STEP_PCT ))
    if [[ "${band}" -gt "${BAND}" ]]; then
      BAND="${band}"
      log "usage $(human "${cur}") = $(( cur * 100 / LIMIT ))% of limit"
      echo "${PREV_SNAPSHOT}"
    fi
  fi

  PREV_SNAPSHOT="$(snapshot)"

  sleep "${INTERVAL}" &
  wait $! 2>/dev/null || true
done
