#!/usr/bin/env bash
# ==============================================================================
# restic-backup.sh — dual-repo infra backups (public stacks + private runtime)
# - Reads ENV_FILE (Restic repo, policy, BACKUP_PATHS[], KUMA_PUSH_URL, etc.)
# - Runs `restic backup` over BACKUP_PATHS (skipping missing paths)
# - Optionally applies retention (`restic forget --prune`) if RUN_FORGET=1
# - Honors RESTIC_GROUP_BY (e.g. host,tags) for retention grouping
# - Pushes status to Uptime Kuma if KUMA_PUSH_URL is set (supports KUMA_RESOLVE_IP override)
# - Optionally emits Prometheus metrics via textfile collector helper
#
# Safe to re-run. Idempotent. Produces concise logs.
# ==============================================================================

set -Eeuo pipefail

# Centralised env file location (can be overridden via ENV_FILE in the environment)
ENV_FILE="${ENV_FILE:-/opt/homelab-runtime/ops/backups/restic.env}"

ts() { date +"[%Y-%m-%dT%H:%M:%S%z]"; }
log() { echo "$(ts) $*"; }

# ------------------------------------------------------------------------------
# Optional: Prometheus backup metrics helper (textfile collector)
# ------------------------------------------------------------------------------
BACKUP_METRICS_ENABLED=0
if [[ -r /opt/homelab-stacks/ops/backups/lib/backup-metrics.sh ]]; then
  # shellcheck source=/dev/null
  . /opt/homelab-stacks/ops/backups/lib/backup-metrics.sh
  BACKUP_METRICS_ENABLED=1
else
  log "[WARN] backup-metrics helper not found; Prometheus metrics disabled"
fi

# ------------------------------------------------------------------------------
# Uptime Kuma integration
# ------------------------------------------------------------------------------
push_kuma() {
  # Usage: push_kuma up|down "MSG"
  local status="${1:-up}"; shift || true
  local msg="${1:-OK}"
  if [[ -n "${KUMA_PUSH_URL:-}" ]]; then
    local sep='?'; [[ "$KUMA_PUSH_URL" == *\?* ]] && sep='&'
    local url="$KUMA_PUSH_URL"
    if [[ -n "${KUMA_RESOLVE_IP:-}" ]]; then
      # Honour DNS override for Kuma push (hairpin NAT/DNS issues)
      local scheme="${url%%://*}"
      local rest="${url#*://}"
      local hostport="${rest%%/*}"
      local host="${hostport%%:*}"
      local port="${hostport#*:}"; [[ "$port" == "$hostport" ]] && { [[ "$scheme" == "https" ]] && port=443 || port=80; }
      curl --resolve "${host}:${port}:${KUMA_RESOLVE_IP}" -fsS -m 10 \
        "${url}${sep}status=${status}&msg=${msg}&ping=" >/dev/null || true
    else
      curl -fsS -m 10 \
        "${url}${sep}status=${status}&msg=${msg}&ping=" >/dev/null || true
    fi
  fi
}

cleanup() {
  [[ -n "${TMPFILES:-}" && -f "${TMPFILES:-}" ]] && rm -f "$TMPFILES" || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 1) Load environment (repo, password, policy, BACKUP_PATHS, KUMA_PUSH_URL, etc.)
# ------------------------------------------------------------------------------
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
else
  log "[WARN] ENV_FILE not found or not readable: $ENV_FILE (using current environment)"
fi

# Defaults (can be overridden in ENV_FILE)
# Resolve exclude precedence: EXCLUDE_FILE > RESTIC_EXCLUDE_FILE > RESTIC_EXCLUDES_FILE > default
EXCLUDE_FILE="${EXCLUDE_FILE:-${RESTIC_EXCLUDE_FILE:-${RESTIC_EXCLUDES_FILE:-/opt/homelab-stacks/ops/backups/exclude.txt}}}"
RUN_FORGET="${RUN_FORGET:-1}"

# Prometheus textfile collector output (can be overridden via BACKUP_TEXTFILE_DIR)
BACKUP_TEXTFILE_DIR="${BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
METRIC_FILE="${BACKUP_TEXTFILE_DIR%/}/restic_backup.prom"

# ------------------------------------------------------------------------------
# 2) Preflight checks
# ------------------------------------------------------------------------------
require_env() {
  local var="$1"
  local reason="$2"
  if [[ -z "${!var:-}" ]]; then
    log "[ERR] ${var} is empty (set it in ${ENV_FILE} or the current environment)"
    push_kuma down "$reason"
    exit 1
  fi
}

command -v restic >/dev/null 2>&1 || { log "[ERR] restic not found in PATH"; push_kuma down "restic-missing"; exit 1; }
require_env "RESTIC_REPOSITORY" "repo-missing"
require_env "RESTIC_PASSWORD" "password-missing"

# Initialize repo if needed
if ! restic snapshots >/dev/null 2>&1; then
  log "[INFO] Initializing restic repository at ${RESTIC_REPOSITORY}"
  restic init
fi

# ------------------------------------------------------------------------------
# 3) Build file list from BACKUP_PATHS (array). Skip missing.
# ------------------------------------------------------------------------------
TMPFILES="$(mktemp -t restic-paths.XXXXXX)"
ADDED_ANY=0
if declare -p BACKUP_PATHS >/dev/null 2>&1; then
  for p in "${BACKUP_PATHS[@]}"; do
    p="${p%/}"
    if [[ -e "$p" ]]; then
      printf '%s\n' "$p" >> "$TMPFILES"
      ADDED_ANY=1
    else
      log "[WARN] skip (not found): $p"
    fi
  done
else
  log "[WARN] BACKUP_PATHS array not defined; backing up nothing"
fi

# ------------------------------------------------------------------------------
# 4) Run backup
# ------------------------------------------------------------------------------
log "[INFO] Starting restic backup..."
backup_args=(backup)
[[ -f "$EXCLUDE_FILE" ]] && backup_args+=(--exclude-file "$EXCLUDE_FILE")
[[ "${HOSTNAME:-}" != "" ]] && backup_args+=(--host "$HOSTNAME")
# Avoid backing up the Restic repository itself if it is a local path
if [[ "${RESTIC_REPOSITORY:-}" == /* && -d "$RESTIC_REPOSITORY" ]]; then
  backup_args+=(--exclude "$RESTIC_REPOSITORY")
fi
if [[ "$ADDED_ANY" -eq 1 ]]; then
  backup_args+=(--files-from "$TMPFILES")
else
  log "[WARN] No existing paths in BACKUP_PATHS; skipping backup run"
  push_kuma up "no-op"
  exit 0
fi

# Measure backup duration and exit code
start_ts="$(date +%s)"
backup_rc=0
if ! restic "${backup_args[@]}"; then
  backup_rc=$?
fi
end_ts="$(date +%s)"
duration="$(( end_ts - start_ts ))"

# Measure added bytes to the backup
added_bytes=0
if [[ "$backup_rc" -eq 0 ]] && command -v jq >/dev/null 2>&1; then
  if restic stats latest --mode raw-data --json >/tmp/restic_stats.json 2>/dev/null; then
    added_bytes="$(jq '.total_size // 0' /tmp/restic_stats.json 2>/dev/null || echo 0)"
    rm -f /tmp/restic_stats.json || true
  fi
fi

# Send metrics to the textfile collector (if the helper is available)
if [[ "$BACKUP_METRICS_ENABLED" -eq 1 ]]; then
  backup_emit_metrics \
    --metric-file "$METRIC_FILE" \
    --ts-metric "restic_last_success_timestamp" \
    --duration-metric "restic_last_duration_seconds" \
    --size-metric "restic_last_added_bytes" \
    --status-metric "restic_last_status" \
    --end-ts "$end_ts" \
    --duration "$duration" \
    --size-bytes "$added_bytes" \
    --exit-code "$backup_rc"
fi

# If the backup has failed, log it in Uptime Kuma and exit.
if [[ "$backup_rc" -ne 0 ]]; then
  log "[ERR] restic backup failed with exit code ${backup_rc}"
  push_kuma down "backup-failed-${backup_rc}"
  exit "$backup_rc"
fi

# ------------------------------------------------------------------------------
# 5) Apply retention if requested
# ------------------------------------------------------------------------------
if [[ "$RUN_FORGET" == "1" ]]; then
  log "[INFO] Applying retention policy (daily=${RESTIC_KEEP_DAILY:-} weekly=${RESTIC_KEEP_WEEKLY:-} monthly=${RESTIC_KEEP_MONTHLY:-}${RESTIC_GROUP_BY:+; group-by=${RESTIC_GROUP_BY}})"
  forget_args=(forget --prune)
  [[ -n "${RESTIC_GROUP_BY:-}"     ]] && forget_args+=(--group-by "$RESTIC_GROUP_BY")
  [[ -n "${RESTIC_KEEP_DAILY:-}"   ]] && forget_args+=(--keep-daily   "$RESTIC_KEEP_DAILY")
  [[ -n "${RESTIC_KEEP_WEEKLY:-}"  ]] && forget_args+=(--keep-weekly  "$RESTIC_KEEP_WEEKLY")
  [[ -n "${RESTIC_KEEP_MONTHLY:-}" ]] && forget_args+=(--keep-monthly "$RESTIC_KEEP_MONTHLY")
  restic "${forget_args[@]}"
fi

log "[INFO] Backup completed successfully"
push_kuma up "OK"
