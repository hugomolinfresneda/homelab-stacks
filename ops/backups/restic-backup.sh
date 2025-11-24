#!/usr/bin/env bash
# restic-backup.sh — dual-repo infra backups (public stacks + private runtime)
# - Reads ENV_FILE (Restic repo, policy, BACKUP_PATHS[], KUMA_PUSH_URL, etc.)
# - Runs `restic backup` over BACKUP_PATHS (skipping missing paths)
# - Optionally applies retention (`restic forget --prune`) if RUN_FORGET=1
# - Honors RESTIC_GROUP_BY (e.g. host,tags) for retention grouping
# - Pushes status to Uptime Kuma if KUMA_PUSH_URL is set (supports KUMA_RESOLVE_IP override)
#
# Safe to re-run. Idempotent. Produces concise logs.
set -euo pipefail
: "${ENV_FILE:=/opt/homelab-runtime/ops/backups/.env}"

ts() { date +"[%Y-%m-%dT%H:%M:%S%z]"; }
log() { echo "$(ts) $*"; }

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
      curl --resolve "${host}:${port}:${KUMA_RESOLVE_IP}" -fsS -m 10             "${url}${sep}status=${status}&msg=${msg}&ping=" >/dev/null || true
    else
      curl -fsS -m 10 "${url}${sep}status=${status}&msg=${msg}&ping=" >/dev/null || true
    fi
  fi
}

cleanup() { [[ -n "${TMPFILES:-}" && -f "${TMPFILES:-}" ]] && rm -f "$TMPFILES" || true; }
trap 'cleanup' EXIT

# 1) Load environment (repo, password, policy, BACKUP_PATHS, KUMA_PUSH_URL, etc.)
ENV_FILE="${ENV_FILE:-/opt/homelab-runtime/ops/backups/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
else
  log "[WARN] ENV_FILE not found: $ENV_FILE (using current environment)"
fi

# Defaults (can be overridden in ENV_FILE)
# Resolve exclude precedence: EXCLUDE_FILE > RESTIC_EXCLUDE_FILE > RESTIC_EXCLUDES_FILE > default
EXCLUDE_FILE="${EXCLUDE_FILE:-${RESTIC_EXCLUDE_FILE:-${RESTIC_EXCLUDES_FILE:-/opt/homelab-stacks/ops/backups/exclude.txt}}}"
RUN_FORGET="${RUN_FORGET:-1}"

# 2) Preflight checks
command -v restic >/dev/null 2>&1 || { log "[ERR] restic not found in PATH"; push_kuma down "restic-missing"; exit 1; }
[[ -n "${RESTIC_REPOSITORY:-}" ]] || { log "[ERR] RESTIC_REPOSITORY is empty"; push_kuma down "repo-missing"; exit 1; }
[[ -n "${RESTIC_PASSWORD:-}"   ]] || { log "[ERR] RESTIC_PASSWORD is empty"; push_kuma down "password-missing"; exit 1; }

# Initialize repo if needed
if ! restic snapshots >/dev/null 2>&1; then
  log "Initializing restic repository at ${RESTIC_REPOSITORY}"
  restic init
fi

# 3) Build file list from BACKUP_PATHS (array). Skip missing.
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

# 4) Run backup
log "Starting restic backup..."
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

restic "${backup_args[@]}"

# 5) Apply retention if requested
if [[ "$RUN_FORGET" == "1" ]]; then
  log "Applying retention policy (daily=${RESTIC_KEEP_DAILY:-} weekly=${RESTIC_KEEP_WEEKLY:-} monthly=${RESTIC_KEEP_MONTHLY:-}${RESTIC_GROUP_BY:+; group-by=${RESTIC_GROUP_BY}})"
  forget_args=(forget --prune)
  [[ -n "${RESTIC_GROUP_BY:-}"     ]] && forget_args+=(--group-by "$RESTIC_GROUP_BY")
  [[ -n "${RESTIC_KEEP_DAILY:-}"   ]] && forget_args+=(--keep-daily   "$RESTIC_KEEP_DAILY")
  [[ -n "${RESTIC_KEEP_WEEKLY:-}"  ]] && forget_args+=(--keep-weekly  "$RESTIC_KEEP_WEEKLY")
  [[ -n "${RESTIC_KEEP_MONTHLY:-}" ]] && forget_args+=(--keep-monthly "$RESTIC_KEEP_MONTHLY")
  restic "${forget_args[@]}"
fi

log "Backup completed successfully"
push_kuma up "OK"
