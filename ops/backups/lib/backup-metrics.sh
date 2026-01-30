#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ==============================================================================
# backup-metrics.sh — helper to emit backup metrics in node_exporter textfile format
# - Intended to be sourced by backup scripts (Restic, Nextcloud, etc.)
# - Never aborts the caller: all failures are downgraded to warnings + return 0
# - Uses tmp file + mv for atomic updates of .prom files
# ==============================================================================
#
# Design notes:
#   - Do NOT enable `set -e` / `set -u` here: we must not change caller behaviour.
#   - If anything fails while writing metrics, we log a warning (only for root in
#     the low-level writer) and return 0.
#   - This code must never prevent the backup from completing.
# ==============================================================================

# Directory where .prom files will be written.
# Can be overridden via BACKUP_TEXTFILE_DIR in the environment.
BACKUP_TEXTFILE_DIR="${BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

# ------------------------------------------------------------------------------
# write_prom_file <metric_file_path> <content>
#   - Writes the content to a .prom file using tmp + mv (atomic).
#   - On any error, logs a warning (for root) and returns 0.
# ------------------------------------------------------------------------------
write_prom_file() {
  local metric_file="$1"
  local content="$2"

  # Without a target path there is nothing to do; do not fail the backup.
  if [[ -z "$metric_file" ]]; then
    return 0
  fi

  local dir
  dir="$(dirname "$metric_file")"

  # Best-effort directory creation
  mkdir -p "$dir" 2>/dev/null || {
    # If we are root and cannot create the directory, it is worth a warning.
    if [[ "${EUID:-0}" -eq 0 ]]; then
      echo "[WARN] backup-metrics: unable to create directory ${dir}" >&2
    fi
    return 0
  }

  local tmp
  if ! tmp="$(mktemp "${metric_file}.XXXXXX" 2>/dev/null)"; then
    # As non-root it is expected to fail on /var/lib/node_exporter; stay quiet.
    # As root, surface a warning so the operator can fix permissions.
    if [[ "${EUID:-0}" -eq 0 ]]; then
      echo "[WARN] backup-metrics: mktemp failed for ${metric_file}" >&2
    fi
    return 0
  fi

  if ! printf '%s\n' "$content" >"$tmp"; then
    if [[ "${EUID:-0}" -eq 0 ]]; then
      echo "[WARN] backup-metrics: could not write to temporary file ${tmp}" >&2
    fi
    rm -f "$tmp" || true
    return 0
  fi

  chmod 0644 "$tmp" 2>/dev/null || true

  if ! mv "$tmp" "$metric_file"; then
    if [[ "${EUID:-0}" -eq 0 ]]; then
      echo "[WARN] backup-metrics: could not move ${tmp} to ${metric_file}" >&2
    fi
    rm -f "$tmp" || true
    return 0
  fi

  return 0
}

# ------------------------------------------------------------------------------
# backup_emit_metrics
#   Emit basic backup metrics into a .prom file.
#
#   Arguments (all via flags):
#     --metric-file       Full path to the .prom on the host.
#     --ts-metric         Metric name for "last success timestamp" (optional).
#     --duration-metric   Metric name for duration in seconds (optional).
#     --size-metric       Metric name for size in bytes (optional).
#     --status-metric     Metric name for exit status (0=ok, !=0=failure). (required)
#     --end-ts            Backup end timestamp (Unix seconds).
#     --duration          Backup duration in seconds.
#     --size-bytes        Backup size (or added bytes).
#     --exit-code         Backup exit code. (required)
#
#   Behaviour:
#     - If exit-code != 0:
#         * Status metric is updated.
#         * Timestamp and size are NOT updated (to avoid pretending success).
#     - Duration metric is emitted whenever provided, even on failure.
#     - On missing mandatory params, logs a warning and returns 0.
# ------------------------------------------------------------------------------
backup_emit_metrics() {
  local metric_file=""
  local ts_metric=""
  local duration_metric=""
  local size_metric=""
  local status_metric=""
  local end_ts=""
  local duration=""
  local size_bytes=""
  local exit_code=""

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --metric-file)       metric_file="$2";       shift 2 ;;
      --ts-metric)         ts_metric="$2";         shift 2 ;;
      --duration-metric)   duration_metric="$2";   shift 2 ;;
      --size-metric)       size_metric="$2";       shift 2 ;;
      --status-metric)     status_metric="$2";     shift 2 ;;
      --end-ts)            end_ts="$2";           shift 2 ;;
      --duration)          duration="$2";          shift 2 ;;
      --size-bytes)        size_bytes="$2";        shift 2 ;;
      --exit-code)         exit_code="$2";         shift 2 ;;
      *)
        echo "[WARN] backup-metrics: unknown parameter '$1' (ignoring remaining flags)" >&2
        break
        ;;
    esac
  done

  # Minimal required fields: metric_file + status_metric + exit_code
  if [[ -z "$metric_file" || -z "$status_metric" || -z "$exit_code" ]]; then
    echo "[WARN] backup-metrics: missing required parameters (metric-file/status-metric/exit-code)" >&2
    return 0
  fi

  local payload=""

  # Timestamp of last success and size: only when exit_code == 0
  if [[ "$exit_code" -eq 0 ]] 2>/dev/null; then
    if [[ -n "$ts_metric" && -n "$end_ts" ]]; then
      payload+="# TYPE ${ts_metric} gauge
# HELP ${ts_metric} Unix timestamp of the last successful backup.
${ts_metric} ${end_ts}

"
    fi

    if [[ -n "$size_metric" && -n "$size_bytes" ]]; then
      payload+="# TYPE ${size_metric} gauge
# HELP ${size_metric} Size in bytes of the last successful backup.
${size_metric} ${size_bytes}

"
    fi
  fi

  # Duration: emit whenever provided, even if the backup failed
  if [[ -n "$duration_metric" && -n "$duration" ]]; then
    payload+="# TYPE ${duration_metric} gauge
# HELP ${duration_metric} Duration in seconds of the last backup run.
${duration_metric} ${duration}

"
  fi

  # Status: always emit
  payload+="# TYPE ${status_metric} gauge
# HELP ${status_metric} Last backup exit status (0=success, non-zero=failure).
${status_metric} ${exit_code}
"

  write_prom_file "$metric_file" "$payload"
}
