# Restic — Dual-repo infrastructure backups

Backs up your **public stacks definition** and **private runtime state** with [restic], integrated with your Makefile, a root-owned systemd service, and optional health pushes to **Uptime Kuma**.

- **homelab-stacks** (public): backup script + exclude file, documented here.
- **homelab-runtime** (private): your `.env` with repo/password/paths/policy.

[restic]: https://restic.net

---

## Architecture

| Repository          | Purpose                                                                                   |
| ------------------- | ----------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base (script `ops/backups/restic-backup.sh`, `exclude.txt`, Make targets).        |
| **homelab-runtime** | Private config (`ops/backups/.env` with credentials, policy and the paths to back up).   |

At runtime:

- A **root-owned systemd service** (`homelab-restic-backup.service`) runs the backup via `restic-backup.sh`.
- The **Makefile** in `homelab-stacks` provides shortcuts (`make restic`, `make restic-*`) that call into that service or into `restic` via `sudo`.

---

## File layout

```text
/opt/homelab-stacks/
└── ops/backups/
    ├── restic-backup.sh
    └── exclude.txt

/opt/homelab-runtime/
└── ops/backups/
    └── .env            # your repo/password/policy/paths (not in git)
````

---

## Requirements

On the **host** (Proxmox node / VM):

* `restic` installed
* `systemd` available (the backup runs as a root oneshot unit)
* A repository target (local dir, S3/B2, rclone remote…)
* Dual-repo layout in place (`/opt/homelab-stacks` + `/opt/homelab-runtime`)

---

## Runtime configuration (`/opt/homelab-runtime/ops/backups/.env`)

Minimal example (aligns with `.env.example`):

```dotenv
# --- Restic ---
export RESTIC_REPOSITORY="/mnt/backups/homelab-restic"   # or s3:..., b2:..., rclone:...
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
export RESTIC_EXCLUDE_FILE="/opt/homelab-stacks/ops/backups/exclude.txt"

# Uptime Kuma (Push monitor)
export KUMA_PUSH_URL="https://uptime-kuma.<YOUR_DOMAIN>/api/push/<YOUR_TOKEN>"
# Optional DNS override for Kuma push (if hairpin NAT/DNS issues)
# export KUMA_RESOLVE_IP="192.168.1.44"

# What to back up (paths may be absent; the script will skip them cleanly)
# NOTE: do NOT put the Nextcloud data volume here; use the dedicated nc-backup.sh flow.
BACKUP_PATHS=(
  # Public infra (scripts, ops, etc.)
  "/opt/homelab-stacks/ops"

  # CouchDB (bind)
  "/opt/homelab-runtime/stacks/couchdb/data"

  # Nextcloud backup artifacts (sql+tar+.sha256), not the data volume
  "/mnt/backups/nextcloud"

  # Uptime Kuma data (bind)
  "/opt/homelab-runtime/stacks/uptime-kuma/data"
)
```

> The script tolerates missing paths and skips them safely.

---

## Deployment (Makefile shortcuts)

From the **stacks** repo (`/opt/homelab-stacks`):

```bash
make restic                # run backup via systemd as root (applies retention if RUN_FORGET=1)
make restic-list           # list snapshots (root via sudo)
make restic-check          # repository integrity (root via sudo)
make restic-stats          # repository stats (root via sudo)
make restic-forget-dry     # preview what would be deleted (no changes; root via sudo)
make restic-forget         # apply retention now (delete & prune; root via sudo)
make restic-diff           # diff last two snapshots (or pass A=.. B=..; root via sudo)
make restic-restore INCLUDE="/path1 /path2" [TARGET=dir]   # selective restore from latest (root via sudo)
make restic-mount [MOUNTPOINT=dir]                         # FUSE mount for browsing (root via sudo)
make restic-show-env       # show repo/policy/group-by/exclude file (root via sudo)
make restic-exclude-show   # print active exclude file (root via sudo)
```

> All `restic-*` targets talk to the repository as **root**.
> By default, `sudo` will ask for your password; you may grant passwordless access for the backup service only via `sudoers` (see below).

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
Environment=ENV_FILE=/opt/homelab-runtime/ops/backups/.env
ExecStart=/opt/homelab-stacks/ops/backups/restic-backup.sh
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

---

## Manual run (portable / debug)

To run the backup script directly (bypassing Makefile and systemd), execute **as root**:

```bash
sudo ENV_FILE=/opt/homelab-runtime/ops/backups/.env \
  /opt/homelab-stacks/ops/backups/restic-backup.sh
```

This matches what the systemd service does and is useful for first-time validation or debugging.

---

## Optional sudoers integration

To allow user `foo` to launch the backup without typing the sudo password, you can add:

```text
# /etc/sudoers.d/homelab-restic (edit with visudo)
foo ALL=(root) NOPASSWD: /usr/bin/systemctl start homelab-restic-backup.service
```

All other `restic-*` targets will continue to require a password, since they use `sudo` directly against `restic`/`bash` and are considered administrative operations on the repository.

---

## Uptime Kuma

If `KUMA_PUSH_URL` is set, the script pushes **up/down** with a short message:

* `up` on success (or `no-op` if nothing to back up)
* `down` with a reason on preflight errors

---

## Troubleshooting

| Symptom                            | Likely cause / fix                                            |
| ---------------------------------- | ------------------------------------------------------------- |
| `restic: command not found`        | Install restic on the host.                                   |
| `RESTIC_REPOSITORY is empty`       | Missing values in `.env`.                                     |
| No changes despite edits           | Check `exclude.txt` and `BACKUP_PATHS`.                       |
| Retention keeps too many snapshots | Verify `RESTIC_GROUP_BY` and `KEEP_*` in `.env`.              |
| Kuma does not flip to OK           | Check `KUMA_PUSH_URL` and host DNS/hairpin issues.            |
| `permission denied` on some paths  | Ensure the backup runs as root and `.env` points to all paths |

---

## Security notes

* `.env` lives in **runtime**, is **not versioned**, and should be owned by root (`chown root:root`, mode `600`).
* The restic repository is encrypted, but you should still:
  * Keep it on a dedicated backups disk (e.g. `/mnt/backups/homelab-restic`).
  * Restrict permissions to root (`chown -R root:root`, mode `700`).
* All repository operations (`make restic*`) run as root via `sudo` or systemd.
* For offsite copies, combine this with `rclone`/object storage lifecycle (S3/B2/etc.).
