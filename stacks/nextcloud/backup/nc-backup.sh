#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# Nextcloud Backup (DB dump + volume archive + checksums)
# - Reads lightweight env from ENV_FILE (defaults to ${RUNTIME_ROOT}/ops/backups/nc-backup.env)
# - Enters maintenance mode (or stops app/web/cron if config is read-only)
# - Produces db.sql, vol.tar.gz and a combined .sha256 file
# - Idempotent, with a simple lock to avoid concurrent runs
# - Expands BACKUP_DIR (~, $HOME) and passes DB creds from host env
# ==============================================================================

set -Eeuo pipefail

# --- Config loader (robust to spaces around '=' and CRLF) ---------------------
ENV_FILE="${ENV_FILE:-${RUNTIME_ROOT}/ops/backups/nc-backup.env}"
case "$ENV_FILE" in "~"/*) ENV_FILE="$HOME${ENV_FILE#~}";; esac

load_env_file() {
  local f="$1" line key val

  # Only attempt to load if the file is readable by the current user
  [[ -r "$f" ]] || return 0

  # Temporarily relax -u while parsing
  set +u
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # strip CR if present
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      [[ "$val" =~ ^\"(.*)\"$ ]] && val="${BASH_REMATCH[1]}"
      [[ "$val" =~ ^\'(.*)\'$ ]] && val="${BASH_REMATCH[1]}"
      export "$key=$val"
    fi
  done < "$f"
  set -u
}

load_env_file "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${STACKS_DIR:-}" ]]; then
  STACKS_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd -P)"
fi

# --- Prometheus backup metrics helper (textfile collector) --------------------
BACKUP_METRICS_ENABLED=0
BACKUP_TEXTFILE_DIR="${BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
METRIC_FILE="${BACKUP_TEXTFILE_DIR}/nextcloud_backup.prom"

if [[ -r "${STACKS_DIR}/ops/backups/lib/backup-metrics.sh" ]]; then
  # shellcheck source=/dev/null
  . "${STACKS_DIR}/ops/backups/lib/backup-metrics.sh"
  BACKUP_METRICS_ENABLED=1
else
  echo "[WARN] backup-metrics helper not found; Prometheus metrics disabled" >&2
fi

# --- Uptime Kuma push integration (optional) ----------------------------------
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

# If anything fails (and is not masked with `|| true`), emit metrics (if enabled)
# and mark the backup as DOWN in Kuma.
_nc_err_trap() {
  local rc=$?
  # Avoid ERR recursion inside the trap itself
  set +e
  trap - ERR

  echo "[ERR] nc-backup failed with exit code ${rc}" >&2

  if [[ "${BACKUP_METRICS_ENABLED:-0}" -eq 1 ]]; then
    local end_ts duration size_bytes=0

    end_ts="$(date +%s)"
    if [[ -n "${BACKUP_START_TS:-}" ]]; then
      duration="$(( end_ts - BACKUP_START_TS ))"
    else
      duration=0
    fi

    if [[ -n "${BACKUP_TAR_PATH:-}" && -f "${BACKUP_TAR_PATH}" ]]; then
      size_bytes="$(stat -c%s "${BACKUP_TAR_PATH}" 2>/dev/null || echo 0)"
    fi

    backup_emit_metrics \
      --metric-file "${METRIC_FILE:-}" \
      --ts-metric "nextcloud_backup_last_success_timestamp" \
      --duration-metric "nextcloud_backup_last_duration_seconds" \
      --size-metric "nextcloud_backup_last_size_bytes" \
      --status-metric "nextcloud_backup_last_status" \
      --end-ts "$end_ts" \
      --duration "$duration" \
      --size-bytes "$size_bytes" \
      --exit-code "$rc"
  fi

  push_kuma down "nc-backup-error"
}

trap _nc_err_trap ERR

# --- Compatibility aliases (accept both NC_* and DB_* styles) -----------------
: "${NC_DB_NAME:=${DB_NAME:-}}"
: "${NC_DB_USER:=${DB_USER:-}}"
: "${NC_DB_PASS:=${DB_PASSWORD:-}}"
: "${NC_DB_HOST:=${DB_HOST:-db}}"

# --- Explicit inputs ----------------------------------------------------------
# Runtime dir holding compose.override.yml and .env
if [[ -z "${RUNTIME_DIR:-}" ]]; then
  if [[ -z "${RUNTIME_ROOT:-}" ]]; then
    echo "error: set RUNTIME_ROOT=/abs/path/to/homelab-runtime (required)" >&2
    exit 1
  fi
  RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"
fi

normalize_service() {
  case "$1" in
    nc-app) echo "app" ;;
    nc-db) echo "db" ;;
    nc-web) echo "web" ;;
    nc-cron) echo "cron" ;;
    nc-mysqld-exporter) echo "mysqld-exporter" ;;
    nc-redis-exporter) echo "redis-exporter" ;;
    *) echo "$1" ;;
  esac
}

# Compose services / volume (allow legacy nc-* inputs)
NC_APP_SERVICE="$(normalize_service "${NC_APP_CONT:-${NC_APP:-app}}")"
NC_DB_SERVICE="$(normalize_service "${NC_DB_CONT:-${NC_DB:-db}}")"
NC_WEB_SERVICE="$(normalize_service "${NC_WEB_CONT:-${NC_WEB:-web}}")"
NC_CRON_SERVICE="$(normalize_service "${NC_CRON_CONT:-${NC_CRON:-cron}}")"
NC_VOL="${NC_VOL:-nextcloud_nextcloud}"

# Required DB params
: "${NC_DB_NAME:?NC_DB_NAME is required}"
: "${NC_DB_USER:?NC_DB_USER is required}"
: "${NC_DB_PASS:?NC_DB_PASS is required}"

# --- Determine compose file and args ------------------------------------------
discover_compose_file() {
  if [[ -n "${COMPOSE_FILE:-}" ]]; then
    CF="$COMPOSE_FILE"
  else
    local script_dir stack_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
    stack_dir="$(dirname "$script_dir")"
    if [[ -f "$stack_dir/compose.yaml" ]]; then
      CF="$stack_dir/compose.yaml"
    elif [[ -f "$stack_dir/compose.yml" ]]; then
      CF="$stack_dir/compose.yml"
    else
      echo "ERROR: cannot find compose.(yml|yaml) under $stack_dir. Set COMPOSE_FILE/STACK_DIR." >&2
      exit 1
    fi
  fi
}

build_compose_args() {
  COMPOSE_ARGS=(-f "$CF")
  [[ -f "$RUNTIME_DIR/compose.override.yml" ]] && COMPOSE_ARGS+=(-f "$RUNTIME_DIR/compose.override.yml")
  [[ -f "$RUNTIME_DIR/.env" ]] && COMPOSE_ARGS+=(--env-file "$RUNTIME_DIR/.env")
}

dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }
dc_id() { dc ps -q "$1" | head -n1; }

# --- Output directory (expand ~ and $HOME; ensure absolute) -------------------
BACKUP_DIR="${BACKUP_DIR:-$HOME/Backups/nextcloud}"
# Expand ~ (only leading)
case "$BACKUP_DIR" in "~"/*) BACKUP_DIR="$HOME${BACKUP_DIR#~}";; esac
# Expand $HOME and ${HOME}
BACKUP_DIR="${BACKUP_DIR//\$HOME/$HOME}"
BACKUP_DIR="${BACKUP_DIR/#\~/$HOME}"
# Ensure absolute (docker -v needs it)
if [[ "$BACKUP_DIR" != /* ]]; then
  BACKUP_DIR="$(pwd)/$BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"

# Sanitize quotes in NC_VOL
NC_VOL=${NC_VOL//\"/}
NC_VOL=${NC_VOL//\'/}

discover_compose_file
build_compose_args

BACKUP_START_TS="$(date +%s)"
ts="$(date -u +%F_%H%M%S)"
prefix="$BACKUP_DIR/nc-${ts}"
lock="$BACKUP_DIR/.lock"
BACKUP_TAR_PATH="${BACKUP_DIR}/nc-vol-${ts}.tar.gz"

# Prevent concurrent runs
exec 9>"$lock"
flock -n 9 || { echo "[ERR] Another Nextcloud backup is already running (lock: ${lock}). Exiting." >&2; exit 1; }

# --- Helpers ------------------------------------------------------------------
wait_ready() {
  local svc="$1" s h cid
  cid="$(dc_id "$svc")"
  if [[ -z "$cid" ]]; then
    echo "[WARN] Container not found for service: ${svc}" >&2
    return 1
  fi
  for _ in $(seq 1 60); do
    s="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)"
    h="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo none)"
    if [[ "$s" == "true" && ( "$h" == "healthy" || "$h" == "none" ) ]]; then
      return 0
    fi
    sleep 2
  done
  echo "[WARN] Timeout waiting for service: ${svc}" >&2
  return 1
}

FROZEN_MODE="none"
unfreeze() {
  set +e
  if [[ "$FROZEN_MODE" == "maintenance" ]]; then
    dc exec -T -u 33 "$NC_APP_SERVICE" php /var/www/html/occ maintenance:mode --off >/dev/null 2>&1 || true
  elif [[ "$FROZEN_MODE" == "stopped" ]]; then
    dc start "$NC_DB_SERVICE" >/dev/null 2>&1 || true
    dc start "$NC_APP_SERVICE" "$NC_WEB_SERVICE" "$NC_CRON_SERVICE" >/dev/null 2>&1 || true
  fi
}
trap unfreeze EXIT

# Ensure DB/app are minimally reachable
wait_ready "$NC_DB_SERVICE"  || true
wait_ready "$NC_APP_SERVICE" || true

echo "==> Enabling maintenance mode…"
set +e
OCC_OUT="$(dc exec -T -u 33 "$NC_APP_SERVICE" php /var/www/html/occ maintenance:mode --on 2>&1)"
OCC_RC=$?
set -e

if [[ $OCC_RC -eq 0 ]]; then
  FROZEN_MODE="maintenance"
  echo "$OCC_OUT" | sed -n '1,2p' || true
else
  if echo "$OCC_OUT" | grep -qi 'read-only'; then
    echo "==> config_is_read_only; stopping app/web/cron as fallback…"
    dc stop "$NC_APP_SERVICE" "$NC_WEB_SERVICE" "$NC_CRON_SERVICE"
    FROZEN_MODE="stopped"
    wait_ready "$NC_DB_SERVICE"
  else
    echo "$OCC_OUT" >&2
    exit 1
  fi
fi

echo "==> Dumping MariaDB…"
# Pass credentials from host env (no inner-shell placeholder variables)
dc exec -T "$NC_DB_SERVICE" mariadb-dump \
  -u"$NC_DB_USER" -p"$NC_DB_PASS" "$NC_DB_NAME" \
  --single-transaction --quick --routines --events \
  > "${prefix}-db.sql"

echo "==> Archiving Nextcloud volume (${NC_VOL})…"
docker run --rm \
  -v "${NC_VOL}:/src:ro" \
  -v "${BACKUP_DIR}:/backup" \
  busybox sh -c 'cd /src && tar -czf "/backup/nc-vol-'"${ts}"'.tar.gz" .'

echo "==> Checksums…"
(
  cd "$BACKUP_DIR" || exit 1
  sha256sum "nc-vol-${ts}.tar.gz" "${prefix}-db.sql" > "${prefix}.sha256"
)

echo "==> Done."
echo "Artifacts:"
echo "  - ${prefix}-db.sql"
echo "  - ${BACKUP_DIR}/nc-vol-${ts}.tar.gz"
echo "  - ${prefix}.sha256"

# Emit Prometheus backup metrics (success path)
if [[ "${BACKUP_METRICS_ENABLED:-0}" -eq 1 ]]; then
  end_ts="$(date +%s)"
  duration="$(( end_ts - BACKUP_START_TS ))"
  size_bytes=0

  if [[ -n "${BACKUP_TAR_PATH:-}" && -f "${BACKUP_TAR_PATH}" ]]; then
    size_bytes="$(stat -c%s "${BACKUP_TAR_PATH}" 2>/dev/null || echo 0)"
  fi

  backup_emit_metrics \
    --metric-file "${METRIC_FILE:-}" \
    --ts-metric "nextcloud_backup_last_success_timestamp" \
    --duration-metric "nextcloud_backup_last_duration_seconds" \
    --size-metric "nextcloud_backup_last_size_bytes" \
    --status-metric "nextcloud_backup_last_status" \
    --end-ts "$end_ts" \
    --duration "$duration" \
    --size-bytes "$size_bytes" \
    --exit-code 0
fi

# Report success to Uptime Kuma (if configured)
push_kuma up "OK"
