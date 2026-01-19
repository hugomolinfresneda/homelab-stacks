#!/usr/bin/env bash
# homelab-stacks/stacks/monitoring/scripts/blackbox-targets.sh
# -------------------------------------------------------------------
# Blackbox Target Manager for Prometheus scrape configs.
# - Containerized yq and promtool (no host dependencies required)
# - Works with both runtime stacks: mon- and demo-
# - SELinux-aware mounts (:Z) when enforcing is enabled
# -------------------------------------------------------------------
set -euo pipefail

die(){ echo "Error: $*" >&2; exit 1; }

usage(){
  cat <<'USAGE' >&2
Usage:
  stacks/monitoring/scripts/blackbox-targets.sh [--demo|--file <path>] ls [job] [--raw]
  stacks/monitoring/scripts/blackbox-targets.sh [--demo|--file <path>] add <job> <target>
  stacks/monitoring/scripts/blackbox-targets.sh [--demo|--file <path>] rm  <job> <target>

Examples:
  stacks/monitoring/scripts/blackbox-targets.sh --demo ls
  stacks/monitoring/scripts/blackbox-targets.sh add blackbox-http https://example.org
  stacks/monitoring/scripts/blackbox-targets.sh --demo rm blackbox-http http://127.0.0.1:65535
USAGE
  exit 1
}

# Root of the monitoring stack (…/stacks/monitoring)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default files
PROM_FILE_MON="prometheus/prometheus.yml"
PROM_FILE_DEMO="prometheus/prometheus.demo.yml"

# Reload hints (avoid container_name assumptions)
RELOAD_HINT_MON="make reload-prom"
RELOAD_HINT_DEMO="make -f stacks/monitoring/Makefile.demo demo-reload-prom DEMO_PROJECT=\${DEMO_PROJECT:-mon-demo}"

need_docker(){ command -v docker >/dev/null 2>&1 || die "Docker is required on the host."; }

# Add ':Z' when SELinux is enforcing (keeps host labels intact)
selinux_flag(){
  if [ -e /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce 2>/dev/null || echo 0)" = "1" ]; then
    printf ':Z'
  fi
}
MOUNT_OPTS="$(selinux_flag)"

PROM_FILE="$PROM_FILE_MON"
RELOAD_HINT="$RELOAD_HINT_MON"

# --- Parse flags/action -------------------------------------------------------
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --demo)
      PROM_FILE="$PROM_FILE_DEMO"
      RELOAD_HINT="$RELOAD_HINT_DEMO"
      shift;;
    --file)
      [[ $# -ge 2 ]] || die "Missing path after --file"
      if [[ "$2" = /* ]]; then
        case "$2" in
          "$ROOT"/*) PROM_FILE="${2#"$ROOT"/}" ;;  # make it relative if inside ROOT
          *) PROM_FILE="$2" ;;
        esac
      else
        PROM_FILE="$2"
      fi
      shift 2;;
    ls|add|rm) ACTION="$1"; shift; break;;
    -h|--help) usage;;
    *) break;;
  esac
done
[[ -n "${ACTION:-}" ]] || usage

HOST_FILE="$PROM_FILE"
[[ "$HOST_FILE" = /* ]] || HOST_FILE="$ROOT/$PROM_FILE"
[ -f "$HOST_FILE" ] || die "Not found: $HOST_FILE"

# --- yq executed inside a container (consistent across hosts) -----------------
yq_eval(){
  need_docker
  if [[ "$PROM_FILE" = /* ]]; then
    local mount_src mount_dest
    mount_src="$(dirname "$HOST_FILE")"
    mount_dest="/hostdir"
    docker run --rm       -e JOB -e TARGET       -v "${mount_src}:${mount_dest}${MOUNT_OPTS}" -w "$mount_dest"       mikefarah/yq:4 "$@" "$(basename "$HOST_FILE")"
  else
    docker run --rm       -e JOB -e TARGET       -v "${ROOT}:/workdir${MOUNT_OPTS}" -w /workdir       mikefarah/yq:4 "$@" "$PROM_FILE"
  fi
}

# Write-back helper: evaluate into a temp file and atomically replace HOST_FILE
yq_update(){
  local expr="$1"
  need_docker
  local tmp
  tmp="$(mktemp)"
  JOB="${JOB:-}" TARGET="${TARGET:-}" yq_eval -o=yaml "$expr" > "$tmp"
  cat "$tmp" > "$HOST_FILE"
  rm -f "$tmp"
}

# promtool via container (no host promtool required)
run_promtool(){
  need_docker
  if [[ "$PROM_FILE" = /* ]]; then
    local mount_src mount_dest
    mount_src="$(dirname "$HOST_FILE")"
    mount_dest="/hostdir"
    docker run --rm       --entrypoint /bin/promtool       -v "${mount_src}:${mount_dest}${MOUNT_OPTS}" -w "$mount_dest"       prom/prometheus:latest "$@"
  else
    docker run --rm       --entrypoint /bin/promtool       -v "${ROOT}:/workdir${MOUNT_OPTS}" -w /workdir       prom/prometheus:latest "$@"
  fi
}

validate_config(){
  echo "Validating with promtool…"
  local cfg="$PROM_FILE"
  [[ "$PROM_FILE" = /* ]] && cfg="$(basename "$HOST_FILE")"
  if run_promtool check config "$cfg" >/dev/null; then
    echo "OK. You can reload Prometheus with:"
    echo "  $RELOAD_HINT"
  else
    die "promtool reported issues in $(basename "$HOST_FILE")"
  fi
}

check_job(){
  local job="$1"
  if ! JOB="$job" yq_eval '.scrape_configs[] | select(.job_name == env(JOB))' >/dev/null 2>&1; then
    echo "Available jobs in $(basename "$HOST_FILE"):" >&2
    yq_eval -r '.scrape_configs[].job_name' | sed 's/^/  - /' >&2 || true
    die "Job '$job' does not exist in $HOST_FILE"
  fi
}

# --- Actions ------------------------------------------------------------------
case "$ACTION" in
  ls)
    JOB="${1:-blackbox-http}"
    RAW="${2:-}"
    check_job "$JOB"

    mapfile -t TARGETS < <(
      JOB="$JOB" yq_eval -r '
        .scrape_configs[]
        | select(.job_name == env(JOB))
        | (.static_configs // [])[]
        | (.targets // [])
        | .[]'
    )

    if [[ "$RAW" == "--raw" ]]; then
      printf "%s
" "${TARGETS[@]}"
      exit 0
    fi

    echo "File: $HOST_FILE"
    echo "Job:  $JOB"
    echo "Targets (${#TARGETS[@]}):"
    i=1; for t in "${TARGETS[@]:-}"; do printf "  %2d) %s
" "$i" "$t"; ((i++)); done
    ;;

  add)
    [[ $# -ge 2 ]] || { echo; echo "Usage: $0 [--demo|--file <path>] add <job> <target>"; exit 1; }
    JOB="$1"; TARGET="$2"
    check_job "$JOB"

    # already present?
    if JOB="$JOB" yq_eval -r '
        .scrape_configs[] | select(.job_name == env(JOB))
        | (.static_configs // [])[]
        | (.targets // [])
        | .[]' | grep -Fxq "$TARGET"; then
      echo "Already present in $JOB: $TARGET"
      exit 0
    fi

    # ensure list exists, then append, uniq + sort for idempotency
    yq_update '
      (.scrape_configs[] | select(.job_name == env(JOB)) | .static_configs) |=
        ( . // [ {"targets": []} ] )
      |
      (.scrape_configs[] | select(.job_name == env(JOB)) | .static_configs[0].targets) |=
        ( (. // []) + [env(TARGET)] | unique | sort )
    '

    echo "Added to $JOB: $TARGET"
    validate_config
    ;;

  rm)
    [[ $# -ge 2 ]] || { echo; echo "Usage: $0 [--demo|--file <path>] rm <job> <target>"; exit 1; }
    JOB="$1"; TARGET="$2"
    check_job "$JOB"

    yq_update '
      (.scrape_configs[] | select(.job_name == env(JOB)) | .static_configs[]?.targets) |=
        ( (. // []) | map(select(. != env(TARGET))) )
    '

    echo "Removed from $JOB (if it existed): $TARGET"
    validate_config
    ;;

  *)
    usage ;;
esac
