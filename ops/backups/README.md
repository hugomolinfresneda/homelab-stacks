# Restic — Dual-repo infrastructure backups

Backs up your **public stacks definition** and **private runtime state** with [restic], integrated with:

- a dual-repo layout (`homelab-stacks` + `homelab-runtime`),
- a root-owned systemd service for scheduled runs,
- a unified `make backup stack=restic` entrypoint,
- optional health pushes to **Uptime Kuma**,
- and optional **Prometheus/Grafana** metrics via node_exporter’s textfile collector.

- **homelab-stacks** (public): backup script + exclude file + Makefile integration.
- **homelab-runtime** (private): your `restic.env` with repo/password/paths/policy.

[restic]: https://restic.net

---

## Canonical paths (setup)
Use these variables in commands and file paths:
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"    # e.g. /opt/homelab-stacks
export RUNTIME_ROOT="/abs/path/to/homelab-runtime" # e.g. /opt/homelab-runtime
```

## Architecture

| Repository          | Purpose                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| **homelab-stacks**  | Public base (`ops/backups/restic-backup.sh`, `exclude.txt`, Make targets).                      |
| **homelab-runtime** | Private config (`ops/backups/restic.env` with credentials, policy and the paths to back up).    |

At runtime:

- A **root-owned systemd service** (`homelab-restic-backup.service`) runs the backup via `restic-backup.sh`.
- The **Makefile** in `homelab-stacks` exposes a single coherent entrypoint:

  ```bash
  make backup stack=restic
  ```

- Optionally, the script:
  - pushes status to **Uptime Kuma** (Push monitor),
  - writes backup metrics for **Prometheus** (textfile collector).

---

## Requirements

On the **host** (Proxmox node / VM):

- `restic` installed.
- `systemd` available (the backup runs as a root oneshot service).
- A backup repository (local directory, S3/B2, rclone remote, …).
- A dual layout on disk (`STACKS_DIR` + `RUNTIME_ROOT`; e.g. `/opt/homelab-stacks` y `/opt/homelab-runtime`).

For observability (optional):

- `node_exporter` with the **textfile collector** enabled and pointing to your
  textfile directory (default shown below):

  ```text
  /var/lib/node_exporter/textfile_collector
  ```

  (already wired by the `monitoring` stack).

---

## File layout

```text
${STACKS_DIR}/
└── ops/backups/
    ├── restic-backup.sh
    └── exclude.txt

${RUNTIME_ROOT}/
└── ops/backups/
    └── restic.env        # repo/password/policy/paths (not in git)
```

---

## Runtime configuration (`${RUNTIME_ROOT}/ops/backups/restic.env`)
Example path: e.g. `/opt/homelab-runtime/ops/backups/restic.env`.

Minimal example (aligns with the example env file shipped next to it):

```dotenv
# --- Restic ---
export BACKUPS_DIR="/abs/path/backups"                  # base mount for local backup storage
export RESTIC_REPOSITORY="${BACKUPS_DIR}/homelab-restic" # or s3:..., b2:..., rclone:...
export RESTIC_PASSWORD="CHANGE_ME"

# Retention policy
export RESTIC_KEEP_DAILY=7
export RESTIC_KEEP_WEEKLY=4
export RESTIC_KEEP_MONTHLY=6

# Grouping for retention (optional; e.g. "host" or "host,tags")
# export RESTIC_GROUP_BY="host"

# Apply retention after each backup? (1=yes, 0=no)
export RUN_FORGET=1

# Exclusions
# Prefer this var name (singular). The script also accepts EXCLUDE_FILE and legacy RESTIC_EXCLUDES_FILE.
export RESTIC_EXCLUDE_FILE="${STACKS_DIR}/ops/backups/exclude.txt"

# Prometheus textfile collector (optional)
# Default is /var/lib/node_exporter/textfile_collector
# export BACKUP_TEXTFILE_DIR="/abs/path/textfile_collector"

# Uptime Kuma (Push monitor)
export KUMA_PUSH_URL="https://uptime-kuma.<YOUR_DOMAIN>/api/push/<YOUR_TOKEN>"
# Optional DNS override for Kuma push (hairpin NAT/DNS issues)
# export KUMA_RESOLVE_IP="<KUMA_LAN_IP>"

# What to back up (paths may be absent; the script will skip them cleanly)
# NOTE: do NOT put the Nextcloud data volume here; use the dedicated nc-backup.sh flow.
BACKUP_PATHS=(
  # Public infra (scripts, ops, etc.)
  "${STACKS_DIR}/ops"

  # CouchDB (bind)
  "${RUNTIME_ROOT}/stacks/couchdb/data"

  # Nextcloud backup artifacts (sql+tar+.sha256), not the data volume
  "${BACKUPS_DIR}/nextcloud"

  # Uptime Kuma data (bind)
  "${RUNTIME_ROOT}/stacks/uptime-kuma/data"
)
```

> The script tolerates missing paths and skips them safely.

---

## Prometheus & Grafana integration (optional)

The backup script sources a shared helper:

```text
${STACKS_DIR}/ops/backups/lib/backup-metrics.sh
```

When the backup runs as **root** and node_exporter’s textfile collector is configured, it writes:

```text
${BACKUP_TEXTFILE_DIR}/restic_backup.prom
```

(`BACKUP_TEXTFILE_DIR` defaults to `/var/lib/node_exporter/textfile_collector` and can be
overridden via the environment, e.g. in `restic.env`.)

with the following gauges:

- `restic_last_success_timestamp` — Unix timestamp of the last successful backup.
- `restic_last_duration_seconds` — Duration in seconds of the last backup run.
- `restic_last_added_bytes` — Bytes added by the last successful backup (approx., via `restic stats`).
- `restic_last_status` — Exit code of the last run (0=success, non-zero=failure).

These metrics feed into:

- the alert rules in `stacks/monitoring/prometheus/rules/backups.rules.yml`, and
- the `Backups – Overview` dashboard under `40_Backups` in Grafana.

If the script runs as a **non-root** user and cannot write into the textfile collector directory, the helper **fails soft**: it simply skips writing the `.prom` file and the backup still completes.

---

## Deployment (Makefile integration)

From the **stacks** repo (`STACKS_DIR`; e.g. `/opt/homelab-stacks`):

```bash
make backup stack=restic
```

This target:

- triggers the backup via the `homelab-restic-backup.service` systemd unit (root),
- uses `${RUNTIME_ROOT}/ops/backups/restic.env` as its configuration source
  (e.g. `/opt/homelab-runtime/ops/backups/restic.env`),
- and honours `BACKUP_PATHS`, `RESTIC_KEEP_*`, `RESTIC_GROUP_BY`, etc.

For advanced operations (`restic snapshots`, `restic check`, …) you can call `restic` directly after loading `restic.env` into your environment.

---

## Systemd integration

The backup is executed by a root-owned oneshot service, for example:

```ini
# /etc/systemd/system/homelab-restic-backup.service
[Unit]
Description=Homelab restic backup (stacks + runtime)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Group=root
Environment=ENV_FILE=${RUNTIME_ROOT}/ops/backups/restic.env
ExecStart=${STACKS_DIR}/ops/backups/restic-backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
```

Optional daily timer:

```ini
# /etc/systemd/system/homelab-restic-backup.timer
[Unit]
Description=Daily homelab restic backup

[Timer]
OnCalendar=*-*-* 03:30
Persistent=true
Unit=homelab-restic-backup.service

[Install]
WantedBy=timers.target
```

You can then:

```bash
sudo systemctl start homelab-restic-backup.service      # manual run
sudo systemctl enable --now homelab-restic-backup.timer # enable daily backup
```

`make backup stack=restic` is simply a convenient wrapper around this service.

---

## Manual run (portable / debug)

To run the backup script directly (bypassing Makefile and systemd), execute **as root**:

```bash
sudo ENV_FILE=${RUNTIME_ROOT}/ops/backups/restic.env   ${STACKS_DIR}/ops/backups/restic-backup.sh
```

This matches what the systemd service does and is useful for first-time validation or debugging.

---

## Optional sudoers integration

To allow user `foo` to launch the backup without typing the sudo password, you can add:

```text
# /etc/sudoers.d/homelab-restic (edit with visudo)
foo ALL=(root) NOPASSWD: /usr/bin/systemctl start homelab-restic-backup.service
```

---

## Uptime Kuma

If `KUMA_PUSH_URL` is set, the script pushes **up/down** with a short message:

- `up` on success (or `no-op` if there is nothing to back up),
- `down` with a reason on preflight errors.

This appears as a dedicated monitor in **Uptime Kuma** and, indirectly, in the global status dashboard in Grafana.

Use `KUMA_RESOLVE_IP` when `KUMA_PUSH_URL` points to public DNS but the host needs to reach Kuma over a LAN IP (hairpin NAT/DNS issues). It forces the push to resolve the Kuma hostname to the supplied IP.

---

## Troubleshooting

| Symptom                            | Likely cause / fix                                            |
| ---------------------------------- | ------------------------------------------------------------- |
| `restic: command not found`        | Install restic on the host.                                   |
| `RESTIC_REPOSITORY is empty`       | Missing values in `restic.env`.                               |
| No changes despite edits           | Check `exclude.txt` and `BACKUP_PATHS`.                       |
| Retention keeps too many snapshots | Verify `RESTIC_GROUP_BY` and `KEEP_*` in `restic.env`.        |
| Kuma does not flip to OK           | Check `KUMA_PUSH_URL` and host DNS/hairpin issues.            |
| `permission denied` on some paths  | Ensure the backup runs as root and `restic.env` lists them.   |
| No Prometheus metrics for Restic   | Check node_exporter textfile dir and that the backup runs as root. |

---

## Security notes

- `restic.env` lives in the **runtime** repo, is **not versioned**, and should be owned by root (`chown root:root`, mode `600`).
- The restic repository is encrypted, but you should still:
  - Keep it on a dedicated backups disk (e.g. `${BACKUPS_DIR}/homelab-restic` for local repos).
  - Restrict permissions to root (`chown -R root:root`, mode `700`).
- All repository operations should run as root (via systemd or `sudo`).
- For offsite copies, combine this with `rclone`/object storage lifecycle (S3/B2/etc.).
