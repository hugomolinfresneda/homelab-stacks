#!/usr/bin/env bash
# ==============================================================================
# Nextcloud Restore (staging by default; in-place opt-in)
# - Selects backup by BACKUP_TS or deterministic latest
# - Verifies checksum for selected artifacts
# - Staging: materializes DB + volume into TARGET (no runtime changes)
# - In-place: restores volume + DB via docker compose (requires ALLOW_INPLACE=1)
# ==============================================================================

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -z "${STACKS_DIR:-}" ]]; then
  STACKS_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd -P)"
fi

# --- Inputs (overridable via env) ---------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-$HOME/Backups/nextcloud}"
BACKUP_TS="${BACKUP_TS:-}"
TARGET="${TARGET:-}"
ALLOW_INPLACE="${ALLOW_INPLACE:-}"

# Runtime dir holding compose.override.yml and .env (only for in-place)
RUNTIME_DIR_INPUT="${RUNTIME_DIR:-}"

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

NC_APP="$(normalize_service "${NC_APP:-app}")"
NC_DB="$(normalize_service "${NC_DB:-db}")"
NC_WEB="$(normalize_service "${NC_WEB:-web}")"
NC_CRON="$(normalize_service "${NC_CRON:-cron}")"
NC_VOL="${NC_VOL:-nextcloud}"

BACKUP_TS_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'

err() { echo "error: $*" >&2; }
info() { echo "info: $*"; }

die() {
  err "$@"
  exit 1
}

validate_backup_dir() {
  if [[ -z "$BACKUP_DIR" ]]; then
    die "set BACKUP_DIR=/path/to/backups"
  fi
  if [[ ! -d "$BACKUP_DIR" ]]; then
    die "BACKUP_DIR does not exist: $BACKUP_DIR"
  fi
}

validate_backup_ts_format() {
  if [[ -n "$BACKUP_TS" && ! "$BACKUP_TS" =~ $BACKUP_TS_REGEX ]]; then
    die "invalid BACKUP_TS, expected YYYY-MM-DD_HHMMSS (e.g. 2025-12-08_023808)"
  fi
}

list_ts_db() {
  local f bn
  for f in "$BACKUP_DIR"/nc-*-db.sql; do
    bn="$(basename "$f")"
    if [[ "$bn" =~ ^nc-([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})-db\.sql$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done | sort -u
}

list_ts_vol() {
  local f bn
  for f in "$BACKUP_DIR"/nc-vol-*.tar.gz; do
    bn="$(basename "$f")"
    if [[ "$bn" =~ ^nc-vol-([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})\.tar\.gz$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done | sort -u
}

list_ts_sha() {
  local f bn
  for f in "$BACKUP_DIR"/nc-*.sha256; do
    bn="$(basename "$f")"
    if [[ "$bn" =~ ^nc-([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})\.sha256$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done | sort -u
}

resolve_latest_ts() {
  local ts latest
  declare -A vol_set sha_set

  while read -r ts; do
    [[ -n "$ts" ]] && vol_set["$ts"]=1
  done < <(list_ts_vol)

  while read -r ts; do
    [[ -n "$ts" ]] && sha_set["$ts"]=1
  done < <(list_ts_sha)

  latest=""
  while read -r ts; do
    [[ -n "$ts" ]] || continue
    if [[ -n "${vol_set[$ts]:-}" && -n "${sha_set[$ts]:-}" ]]; then
      latest="$ts"
    fi
  done < <(list_ts_db)

  if [[ -z "$latest" ]]; then
    die "no valid backup timestamps found in $BACKUP_DIR"
  fi

  echo "$latest"
}

resolve_backup_ts() {
  if [[ -z "$BACKUP_TS" ]]; then
    BACKUP_TS="$(resolve_latest_ts)"
    BACKUP_TS_SOURCE="latest"
  else
    BACKUP_TS_SOURCE="explicit"
  fi
}

validate_artifacts() {
  DB_FILE="$BACKUP_DIR/nc-${BACKUP_TS}-db.sql"
  SHA_FILE="$BACKUP_DIR/nc-${BACKUP_TS}.sha256"
  VOL_FILE="$BACKUP_DIR/nc-vol-${BACKUP_TS}.tar.gz"

  missing=()
  [[ -f "$DB_FILE" ]] || missing+=("nc-${BACKUP_TS}-db.sql")
  [[ -f "$SHA_FILE" ]] || missing+=("nc-${BACKUP_TS}.sha256")
  [[ -f "$VOL_FILE" ]] || missing+=("nc-vol-${BACKUP_TS}.tar.gz")

  if (( ${#missing[@]} )); then
    err "missing artifacts for BACKUP_TS=$BACKUP_TS"
    err "expected:"
    for f in "${missing[@]}"; do
      err "  - $f"
    done
    exit 1
  fi
}

sha_basenames() {
  local sha_file="$1"
  awk '
    {
      f=$2
      sub(/^\*/, "", f)
      sub(/^\.\//, "", f)
      sub(/^.*\//, "", f)
      if (f != "") print f
    }
  ' "$sha_file"
}

verify_checksum() {
  local sha_file="$1" db_bn vol_bn listed
  db_bn="$(basename "$DB_FILE")"
  vol_bn="$(basename "$VOL_FILE")"

  [[ -f "$sha_file" ]] || die "missing checksum file: $sha_file"

  listed="$(sha_basenames "$sha_file" | sort -u)"

  if ! printf '%s\n' "$listed" | grep -Fxq "$db_bn"; then
    err "checksum file does not reference expected DB artifact: $db_bn"
    err "found basenames: $(printf '%s' "$listed" | tr '\n' ' ')"
    exit 1
  fi
  if ! printf '%s\n' "$listed" | grep -Fxq "$vol_bn"; then
    err "checksum file does not reference expected volume artifact: $vol_bn"
    err "found basenames: $(printf '%s' "$listed" | tr '\n' ' ')"
    exit 1
  fi

  (cd "$BACKUP_DIR" && sha256sum -c "$(basename "$sha_file")") || die "checksum verification failed"
}

print_plan() {
  echo "mode=$MODE"
  echo "BACKUP_DIR=$BACKUP_DIR"
  if [[ "${BACKUP_TS_SOURCE:-explicit}" == "latest" ]]; then
    echo "BACKUP_TS=latest -> $BACKUP_TS"
  else
    echo "BACKUP_TS=$BACKUP_TS"
  fi
  echo "TARGET=$TARGET"
  echo "ARTIFACTS:"
  echo "  DB : $DB_FILE"
  echo "  SHA: $SHA_FILE"
  echo "  VOL: $VOL_FILE"
}

stage_restore() {
  mkdir -p "$TARGET/vol"
  cp "$DB_FILE" "$TARGET/db.sql"
  tar -xzf "$VOL_FILE" -C "$TARGET/vol"
  echo "Staged restore completed: $TARGET"
}

# --- Safe loader for runtime .env (no eval; tolerates spaces & CRLF) ----------
load_runtime_env() {
  local envf="$RUNTIME_DIR/.env" line key val
  [[ -f "$envf" ]] || return 0
  set +u
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      [[ "$val" =~ ^\"(.*)\"$ ]] && val="${BASH_REMATCH[1]}"
      [[ "$val" =~ ^\'(.*)\'$ ]] && val="${BASH_REMATCH[1]}"
      export "$key=$val"
    fi
  done < "$envf"
  set -u
}

# --- Determine base compose file (public repo) --------------------------------
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

# Build docker compose args: base + override + env (if present)
build_compose_args() {
  COMPOSE_ARGS=(-f "$CF")
  [[ -f "$RUNTIME_DIR/compose.override.yml" ]] && COMPOSE_ARGS+=(-f "$RUNTIME_DIR/compose.override.yml")
  [[ -f "$RUNTIME_DIR/.env" ]] && COMPOSE_ARGS+=(--env-file "$RUNTIME_DIR/.env")
}

dc() { docker compose "${COMPOSE_ARGS[@]}" "$@"; }
dc_id() { dc ps -q "$1" | head -n1; }

wait_healthy() {
  local svc="$1" st cid
  cid="$(dc_id "$svc")"
  if [[ -z "$cid" ]]; then
    echo "Container not found for service: $svc" >&2
    return 1
  fi
  for _ in $(seq 1 60); do
    st="$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo none)"
    [[ "$st" == "healthy" || "$st" == "none" ]] && return 0
    sleep 2
  done
  echo "Timeout waiting for $svc (health)" >&2
  return 1
}

inplace_restore() {
  [[ -n "$RUNTIME_DIR" ]] || die "RUNTIME_DIR is required for in-place restore"
  [[ -d "$RUNTIME_DIR" ]] || die "RUNTIME_DIR not found: $RUNTIME_DIR"

  load_runtime_env
  discover_compose_file
  build_compose_args

  # Stop writers & enter maintenance (best-effort)
  dc stop "$NC_APP" "$NC_WEB" "$NC_CRON" || true
  dc exec -T -u www-data "$NC_APP" php occ maintenance:mode --on || true

  # Restore volume
  echo "Restoring volume $NC_VOL..."
  local vol_bn
  vol_bn="$(basename "$VOL_FILE")"
  docker run --rm \
    -v "$NC_VOL":/data \
    -v "$BACKUP_DIR":/backup \
    -e VOL_FILE_BN="$vol_bn" \
    busybox sh -lc '
      set -e
      cd /data
      find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      tar -xzf "/backup/$VOL_FILE_BN" -C /data
    '

  # Ensure DB/redis up before import
  dc up -d "$NC_DB" redis
  wait_healthy "$NC_DB" || true

  # Restore database
  echo "Restoring database..."
  dc exec -T \
    -e MYSQL_PWD="${NC_DB_PASS:-}" \
    -e DB_USER="${NC_DB_USER:-}" \
    -e DB_NAME="${NC_DB_NAME:-}" \
    "$NC_DB" sh -lc "exec mariadb -u\"\$DB_USER\" \"\$DB_NAME\"" < "$DB_FILE"

  # Bring up app → then web/cron
  dc up -d "$NC_APP"
  wait_healthy "$NC_APP" || true
  dc up -d "$NC_WEB" "$NC_CRON"

  # Repairs & maintenance off
  dc exec -T -u www-data "$NC_APP" php occ maintenance:repair || true
  dc exec -T -u www-data "$NC_APP" php occ maintenance:mode --off || true

  echo "Restore complete (in-place)."
}

main() {
  validate_backup_dir
  validate_backup_ts_format
  resolve_backup_ts
  validate_artifacts

  local runtime_dir target_runtime
  runtime_dir="$RUNTIME_DIR_INPUT"
  if [[ -z "$runtime_dir" && "$ALLOW_INPLACE" == "1" && -n "${RUNTIME_ROOT:-}" ]]; then
    runtime_dir="${RUNTIME_ROOT}/stacks/nextcloud"
  fi

  target_runtime=0
  if [[ -n "$runtime_dir" ]]; then
    if [[ -z "$TARGET" || "$TARGET" == "$runtime_dir" ]]; then
      target_runtime=1
    fi
  fi

  if [[ "$target_runtime" -eq 1 ]]; then
    if [[ "$ALLOW_INPLACE" == "1" ]]; then
      MODE="in-place"
      RUNTIME_DIR="$runtime_dir"
      if [[ -z "$TARGET" ]]; then
        TARGET="$runtime_dir"
      fi
    else
      err "in-place restore requires ALLOW_INPLACE=1"
      err "set ALLOW_INPLACE=1 and TARGET=\"${runtime_dir:-/abs/path/to/runtime}\""
      err "or omit RUNTIME_DIR/TARGET to keep staging mode"
      exit 1
    fi
  else
    MODE="staging"
    if [[ -z "$TARGET" ]]; then
      TARGET="$(mktemp -d -t "nc-restore.${BACKUP_TS}.XXXXXX")"
    fi
    if [[ "$ALLOW_INPLACE" == "1" ]]; then
      info "ALLOW_INPLACE=1 set but runtime not targeted; staying in staging mode"
    fi
  fi

  print_plan
  verify_checksum "$SHA_FILE"

  if [[ "$MODE" == "staging" ]]; then
    stage_restore
    return 0
  fi

  inplace_restore
}

main "$@"
