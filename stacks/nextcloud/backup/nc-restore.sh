#!/usr/bin/env bash
# ==============================================================================
# Nextcloud Restore (volume + DB)
# - Selects latest nc-*-db.sql[.gz] and nc-vol-*.tar.gz from BACKUP_DIR
# - Verifies checksum if a matching .sha256 exists
# - Stops writers, restores volume, imports DB, runs maintenance repairs
# - Uses runtime override (.env + compose.override.yml) when present
# ==============================================================================

set -Eeuo pipefail

# --- Inputs (overridable via env) ---------------------------------------------
BACKUP_DIR="${BACKUP_DIR:-$HOME/Backups/nextcloud}"

NC_APP="${NC_APP:-nc-app}"
NC_DB="${NC_DB:-nc-db}"
NC_WEB="${NC_WEB:-nc-web}"
NC_CRON="${NC_CRON:-nc-cron}"
NC_VOL="${NC_VOL:-nextcloud}"

# Runtime dir holding compose.override.yml and .env
RUNTIME_DIR="${RUNTIME_DIR:-/opt/homelab-runtime/stacks/nextcloud}"

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

# --- Pick latest artifacts -----------------------------------------------------
pick_artifacts() {
  DB_FILE="$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'nc-*-db.sql.gz' -o -name 'nc-*-db.sql' \) \
             -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1="";sub(/^ /,"");print}')"
  VOL_FILE="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'nc-vol-*.tar.gz' \
             -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1="";sub(/^ /,"");print}')"

  [[ -n "${DB_FILE:-}"  ]] || { echo "ERROR: no DB backup in $BACKUP_DIR (nc-*-db.sql[.gz])." >&2; exit 1; }
  [[ -n "${VOL_FILE:-}" ]] || { echo "ERROR: no volume archive in $BACKUP_DIR (nc-vol-*.tar.gz)." >&2; exit 1; }

  # Verify checksum if matching .sha256 exists (based on DB file stem)
  local sha_cand
  sha_cand="$(basename "$DB_FILE" | sed -E 's/-db\.sql(\.gz)?$/.sha256/')"
  if [[ -f "$BACKUP_DIR/$sha_cand" ]]; then
    (cd "$BACKUP_DIR" && sha256sum -c "$sha_cand") || {
      echo "WARNING: checksum mismatch. Continue anyway? (yes/NO)"
      read -r ok; [[ "$ok" == "yes" ]] || exit 1
    }
  fi

  echo "Will restore:"
  echo "  DB : $DB_FILE"
  echo "  VOL: $VOL_FILE"
  read -rp "Confirm (yes/NO): " ok
  [[ "$ok" == "yes" ]] || { echo "Cancelled."; exit 1; }
}

wait_healthy() {
  local c="$1" st
  for _ in $(seq 1 60); do
    st="$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)"
    [[ "$st" == "healthy" || "$st" == "none" ]] && return 0
    sleep 2
  done
  echo "Timeout waiting for $c (health)" >&2
  return 1
}

main() {
  load_runtime_env
  discover_compose_file
  build_compose_args
  pick_artifacts

  # Stop writers & enter maintenance (best-effort)
  dc stop app web cron || true
  docker exec -u www-data "$NC_APP" php occ maintenance:mode --on || true

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
  dc up -d db redis
  wait_healthy "$NC_DB" || true

  # Restore database (supports .sql and .sql.gz)
  echo "Restoring database..."
  if [[ "$DB_FILE" == *.gz ]]; then
    gzip -t "$DB_FILE"
    gunzip -c "$DB_FILE" | docker exec -i \
      -e MYSQL_PWD="${NC_DB_PASS:-}" \
      -e DB_USER="${NC_DB_USER:-}" \
      -e DB_NAME="${NC_DB_NAME:-}" \
      "$NC_DB" sh -lc 'exec mariadb -u"$DB_USER" "$DB_NAME"'
  else
    docker exec -i \
      -e MYSQL_PWD="${NC_DB_PASS:-}" \
      -e DB_USER="${NC_DB_USER:-}" \
      -e DB_NAME="${NC_DB_NAME:-}" \
      "$NC_DB" sh -lc 'exec mariadb -u"$DB_USER" "$DB_NAME"' < "$DB_FILE"
  fi

  # Bring up app → then web/cron
  dc up -d app
  wait_healthy "$NC_APP" || true
  dc up -d web cron

  # Repairs & maintenance off
  docker exec -u www-data "$NC_APP" php occ maintenance:repair || true
  docker exec -u www-data "$NC_APP" php occ maintenance:mode --off || true

  echo "Restore complete."
}

main "$@"
