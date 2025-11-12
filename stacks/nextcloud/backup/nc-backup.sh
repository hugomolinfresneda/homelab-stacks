#!/usr/bin/env bash
# ==============================================================================
# Nextcloud Backup (DB dump + volume archive + checksums)
# - Reads lightweight env from ENV_FILE (defaults to ~/.config/nextcloud/nc-backup.env)
# - Enters maintenance mode (or stops app/web/cron if config is read-only)
# - Produces db.sql, vol.tar.gz and a combined .sha256 file
# - Idempotent, with a simple lock to avoid concurrent runs
# - Patched to expand BACKUP_DIR (~, $HOME) and pass DB creds from host env
# ==============================================================================

set -Eeuo pipefail

# --- Config loader (robust to spaces around '=' and CRLF) ---------------------
ENV_FILE="${ENV_FILE:-$HOME/.config/nextcloud/nc-backup.env}"
case "$ENV_FILE" in "~"/*) ENV_FILE="$HOME${ENV_FILE#~}";; esac

load_env_file() {
  local f="$1" line key val
  [[ -f "$f" ]] || return 0
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

# --- Compatibility aliases (accept both NC_* and DB_* styles) -----------------
: "${NC_DB_NAME:=${DB_NAME:-}}"
: "${NC_DB_USER:=${DB_USER:-}}"
: "${NC_DB_PASS:=${DB_PASSWORD:-}}"
: "${NC_DB_HOST:=${DB_HOST:-nc-db}}"

# --- Explicit inputs ----------------------------------------------------------
# Containers / volume (allow classic names as fallbacks)
NC_APP_CONT="${NC_APP_CONT:-${NC_APP:-nc-app}}"
NC_DB_CONT="${NC_DB_CONT:-${NC_DB:-nc-db}}"
NC_WEB_CONT="${NC_WEB_CONT:-${NC_WEB:-nc-web}}"
NC_CRON_CONT="${NC_CRON_CONT:-${NC_CRON:-nc-cron}}"
NC_VOL="${NC_VOL:-nextcloud_nextcloud}"

# Required DB params
: "${NC_DB_NAME:?NC_DB_NAME is required}"
: "${NC_DB_USER:?NC_DB_USER is required}"
: "${NC_DB_PASS:?NC_DB_PASS is required}"

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

ts="$(date -u +%F_%H%M%S)"
prefix="$BACKUP_DIR/nc-${ts}"
lock="$BACKUP_DIR/.lock"

# Prevent concurrent runs
exec 9>"$lock"
flock -n 9 || { echo "Another backup is running. Exiting."; exit 1; }

# --- Helpers ------------------------------------------------------------------
wait_ready() {
  local c="$1" s h
  for _ in $(seq 1 60); do
    s="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)"
    h="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)"
    if [[ "$s" == "true" && ( "$h" == "healthy" || "$h" == "none" ) ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Timeout waiting for $c" >&2
  return 1
}

FROZEN_MODE="none"
unfreeze() {
  set +e
  if [[ "$FROZEN_MODE" == "maintenance" ]]; then
    docker exec -u 33 "$NC_APP_CONT" php /var/www/html/occ maintenance:mode --off >/dev/null 2>&1 || true
  elif [[ "$FROZEN_MODE" == "stopped" ]]; then
    docker start "$NC_DB_CONT" >/dev/null 2>&1 || true
    docker start "$NC_APP_CONT" "$NC_WEB_CONT" "$NC_CRON_CONT" >/dev/null 2>&1 || true
  fi
}
trap unfreeze EXIT

# Ensure DB/app are minimally reachable
wait_ready "$NC_DB_CONT"  || true
wait_ready "$NC_APP_CONT" || true

echo "==> Enabling maintenance mode…"
set +e
OCC_OUT="$(docker exec -u 33 "$NC_APP_CONT" php /var/www/html/occ maintenance:mode --on 2>&1)"
OCC_RC=$?
set -e

if [[ $OCC_RC -eq 0 ]]; then
  FROZEN_MODE="maintenance"
  echo "$OCC_OUT" | sed -n '1,2p' || true
else
  if echo "$OCC_OUT" | grep -qi 'read-only'; then
    echo "==> config_is_read_only; stopping app/web/cron as fallback…"
    docker stop "$NC_APP_CONT" "$NC_WEB_CONT" "$NC_CRON_CONT"
    FROZEN_MODE="stopped"
    wait_ready "$NC_DB_CONT"
  else
    echo "$OCC_OUT" >&2
    exit 1
  fi
fi

echo "==> Dumping MariaDB…"
# Pass credentials from host env (no inner-shell placeholder variables)
docker exec "$NC_DB_CONT" mariadb-dump \
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
