# Nextcloud Backups — Enterprise-Friendly Guide

This document explains the **backup & restore** workflow for the Nextcloud stack, aligned with the repo split you are using:

- **Public stacks repo** (for example, `/opt/homelab-stacks`)
- **Private runtime repo** (for example, `/opt/homelab-runtime`)

It covers **how the scripts work**, **required environment**, **usage from both repos**, **verification**, **scheduling**, **observability** and **troubleshooting**—with a focus on **reproducibility**, **safety**, and **boring operations**.

---

## 0) What gets backed up

Artifacts are written to `BACKUP_DIR` as **three files per run**:

- `nc-<UTC_TS>-db.sql` — MariaDB dump (transactionally consistent).
- `nc-vol-<UTC_TS>.tar.gz` — Tarball of the **named** volume that stores Nextcloud code/config/data.
- `nc-<UTC_TS>.sha256` — Combined checksums for both artifacts above.

> The **Nextcloud data/code/config** live in the **named volume** (default `nextcloud_nextcloud`). **Do not** bind-mount `/var/www/html` from the host; keep it as a named volume.

---

## 1) Where the scripts live

Public repo:

```text
/opt/homelab-stacks/stacks/nextcloud/backup/
├─ nc-backup.sh          # DB dump + volume archive + .sha256 + optional Kuma/Prometheus metrics
├─ nc-restore.sh         # Volume restore + DB import (with verification)
└─ nc-backup.env.example # Example env for backups (copy to your home)
```

You can call these directly or through **Makefile** targets (see §4 and §5).

---

## 2) One-time setup

### 2.1 Create your backup environment file

Copy the example to your home (or any location you prefer):

```bash
mkdir -p ~/.config/nextcloud
cp /opt/homelab-stacks/stacks/nextcloud/backup/nc-backup.env.example    ~/.config/nextcloud/nc-backup.env
$EDITOR ~/.config/nextcloud/nc-backup.env
```

Recommended content (edit to match **your** runtime):

```dotenv
# Compose services (legacy nc-* names are accepted and auto-mapped)
NC_APP_CONT=app
NC_DB_CONT=db
NC_WEB_CONT=web
NC_CRON_CONT=cron

# Named data volume for Nextcloud code/config/data
# Tip: docker volume ls | grep nextcloud
NC_VOL=nextcloud_nextcloud

# Database credentials (MUST match runtime .env)
NC_DB_NAME=nextcloud
NC_DB_USER=ncuser
NC_DB_PASS=CHANGE_ME

# Where to store artifacts
BACKUP_DIR=$HOME/Backups/nextcloud

# Optional: push backup result to Uptime Kuma (Push monitor)
# Create a "Push" monitor in Uptime Kuma and paste its URL here.
# KUMA_PUSH_URL="https://uptime-kuma.example.com/api/push/<TOKEN>"

# Optional: force the IP used when pushing to Uptime Kuma
# (useful with hairpin NAT or split DNS)
# KUMA_RESOLVE_IP=192.168.1.11

# --- Notes --------------------------------------------------------------------
# - Do not source your runtime .env here. Keep this file minimal and scoped to
#   backup needs only (containers, volume name, DB credentials, optional Kuma).
# - Do not quote NC_VOL.
```

> **Do not** put secrets in git. This file stays in your **home** (or in a private runtime path if you override `ENV_FILE`).

### 2.2 Requirements on the host

- Docker Engine + Docker Compose v2.
- The Nextcloud stack is deployed per the main README (named volumes in use).
- Sufficient disk space under `BACKUP_DIR` for tarballs and SQL dumps.
- Optional observability:
  - `node_exporter` with the textfile collector enabled if you want Prometheus metrics.
  - Uptime Kuma if you want to track the job as a Push monitor.

---

## 3) How the scripts work (safety model)

### 3.1 `nc-backup.sh`

1. Loads a **minimal** environment from `ENV_FILE` (defaults to `~/.config/nextcloud/nc-backup.env`), robust to:
   - Spaces around `=`.
   - CRLF line endings.
   - Unquoted values.
2. Enters **maintenance mode** via `occ`. If `config_is_read_only` prevents that:
   - Falls back to **stopping** `app/web/cron` while keeping the database up.
3. Dumps MariaDB with:

   ```bash
   mariadb-dump --single-transaction --quick --routines --events
   ```

4. Archives the **named volume** with a minimal BusyBox container (read-only mount).
5. Writes a combined `.sha256` file with checksums for both artifacts.
6. Uses a simple lock (`$BACKUP_DIR/.lock`) to prevent concurrent runs.
7. Optionally:
   - pushes the result to **Uptime Kuma** if `KUMA_PUSH_URL` is configured (see §15),
   - emits backup metrics for **Prometheus** if it can write to the node_exporter textfile collector directory (see §16).

### 3.2 `nc-restore.sh`

1. Loads runtime `.env` **safely** (no `eval`), tolerating spaces and CRLF.
2. Picks the **latest** `db.sql[.gz]` and `vol-*.tar.gz` in `BACKUP_DIR`.
3. If a matching `.sha256` exists, it **verifies** checksums.
4. Stops writers (`app/web/cron`) and **enables maintenance** (best effort).
5. **Wipes** the target volume contents and extracts the tarball.
6. Ensures `db` and `redis` are up; **imports** the database.
7. Brings back `app → web/cron`, runs `occ maintenance:repair`, and disables maintenance.

---

## 4) Usage from the **runtime** repo

From `/opt/homelab-runtime`:

```bash
# Backup (env in your home)
make backup stack=nextcloud   BACKUP_DIR=$HOME/Backups/nextcloud   BACKUP_ENV=$HOME/.config/nextcloud/nc-backup.env

# Verify last backup
make backup-verify stack=nextcloud   BACKUP_DIR=$HOME/Backups/nextcloud

# Restore (latest artifacts; confirm interactive prompt)
make restore stack=nextcloud   BACKUP_DIR=$HOME/Backups/nextcloud
```

The runtime Makefile special-cases Nextcloud to avoid `--project-directory` path traps and uses your runtime `.env` and `compose.override.yml` automatically.

---

## 5) Usage from the **public** repo

From `/opt/homelab-stacks`:

```bash
# Backup with extra trace (optional)
make backup stack=nextcloud   BACKUP_DIR="$HOME/Backups/nextcloud"   BACKUP_ENV="$HOME/.config/nextcloud/nc-backup.env"   BACKUP_TRACE=1

# Verify last backup
make backup-verify stack=nextcloud   BACKUP_DIR="$HOME/Backups/nextcloud"

# Restore (point to your runtime dir explicitly)
make restore stack=nextcloud   BACKUP_DIR="$HOME/Backups/nextcloud"   RUNTIME_DIR=/opt/homelab-runtime/stacks/nextcloud   BACKUP_TRACE=1
```

The `BACKUP_TRACE=1` flag prints which script and paths are being used for easier diagnosis.

---

## 6) Manual invocation (optional)

If you prefer to call the scripts directly:

```bash
# Backup
ENV_FILE="$HOME/.config/nextcloud/nc-backup.env" BACKUP_DIR="$HOME/Backups/nextcloud" bash /opt/homelab-stacks/stacks/nextcloud/backup/nc-backup.sh

# Restore (public compose base + runtime override)
COMPOSE_FILE="/opt/homelab-stacks/stacks/nextcloud/compose.yaml" RUNTIME_DIR="/opt/homelab-runtime/stacks/nextcloud" BACKUP_DIR="$HOME/Backups/nextcloud" bash /opt/homelab-stacks/stacks/nextcloud/backup/nc-restore.sh
```

---

## 7) Verifying integrity

### 7.1 Quick verify of the **latest** backup

Both Makefiles provide:

```bash
make backup-verify stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud"
```

### 7.2 Manual verify of a specific stamp

```bash
cd "$HOME/Backups/nextcloud"
sha256sum -c nc-2025-10-30_105334.sha256
```

You should see `OK` for both the tarball and the SQL dump.

---

## 8) Scheduling (recommended)

### Option A — crontab (simple)

Edit root’s crontab:

```bash
sudo crontab -e
```

Add a nightly run at 02:15 (UTC) with a seven-day retention as a simple example:

```cron
15 2 * * * ENV_FILE=$HOME/.config/nextcloud/nc-backup.env BACKUP_DIR=$HOME/Backups/nextcloud   bash /opt/homelab-stacks/stacks/nextcloud/backup/nc-backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

> Rotation and offsite sync are not handled by the script. Use your preferred tooling (for example, `restic`, `rclone`, ZFS/Btrfs snapshots, object storage versions).

### Option B — systemd timer (more control)

`/etc/systemd/system/nextcloud-backup.service`:

```ini
[Unit]
Description=Nextcloud backup (DB + volume)

[Service]
Type=oneshot
Environment=ENV_FILE=$HOME/.config/nextcloud/nc-backup.env
Environment=BACKUP_DIR=$HOME/Backups/nextcloud
ExecStart=/usr/bin/bash /opt/homelab-stacks/stacks/nextcloud/backup/nc-backup.sh
```

`/etc/systemd/system/nextcloud-backup.timer`:

```ini
[Unit]
Description=Nightly Nextcloud backup

[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup.timer
systemctl list-timers | grep nextcloud-backup
```

---

## 9) Disaster-recovery drill (5-minute sanity test)

1. Create a fresh backup and verify checksums (see §4, §5 and §7).
2. Stop writers in production (`app/web/cron` will be stopped by the restore script anyway).
3. Restore in place (or to a staging host) using `make restore` or the script directly.
4. Ensure `app` reaches **healthy**, browse the UI, and check **OCC status**:

   ```bash
   /opt/homelab-stacks/stacks/nextcloud/tools/occ status
   ```

5. Validate that recent files exist and that login works.

---

## 10) Troubleshooting

- **“Another backup is running. Exiting.”**
  A lock file exists (`$BACKUP_DIR/.lock`). If you are sure nothing is running, remove it.

- **Maintenance mode toggle fails with “read-only configuration”**
  The backup script will **stop** `app/web/cron` as a fallback and proceed safely.

- **`nc-restore.sh` complains about missing artifacts**
  Check your `BACKUP_DIR`. File patterns must be `nc-*-db.sql[.gz]` and `nc-vol-*.tar.gz`.

- **HTTP 502 after restore**
  `app` may still be warming up. Check `docker compose -f /opt/homelab-stacks/stacks/nextcloud/compose.yaml -f /opt/homelab-runtime/stacks/nextcloud/compose.override.yml --env-file /opt/homelab-runtime/stacks/nextcloud/.env logs app web`. The script brings services back in the correct order.

- **Wrong volume name**
  Confirm with:

  ```bash
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/www/html"}}{{.Name}}{{end}}{{end}}' \
    "$(docker compose -f /opt/homelab-stacks/stacks/nextcloud/compose.yaml -f /opt/homelab-runtime/stacks/nextcloud/compose.override.yml --env-file /opt/homelab-runtime/stacks/nextcloud/.env ps -q app)"
  ```

  Then set `NC_VOL` accordingly in your `nc-backup.env`.

---

## 11) Security and hygiene

- Keep your `nc-backup.env` **out of git** (home directory or private runtime).
- Ensure `BACKUP_DIR` is on **trustworthy storage** and protect filesystem permissions.
- Consider **encryption** of offsite copies (for example, restic or rclone).
- Always **verify** backups and **test** restores before upgrades.

---

## 12) Reference: Makefile targets

### Public repo (`/opt/homelab-stacks`)

```bash
make backup         stack=nextcloud BACKUP_DIR=... BACKUP_ENV=... [BACKUP_TRACE=1]
make backup-verify  stack=nextcloud BACKUP_DIR=...
make restore        stack=nextcloud BACKUP_DIR=... RUNTIME_DIR=/opt/homelab-runtime/stacks/nextcloud
```

### Runtime repo (`/opt/homelab-runtime`)

```bash
make backup         stack=nextcloud BACKUP_DIR=... BACKUP_ENV=...
make backup-verify  stack=nextcloud BACKUP_DIR=...
make restore        stack=nextcloud BACKUP_DIR=...
```

Both paths are fully supported and validated.

---

## 13) Change management tips

- Run a backup **immediately** before:
  - Upgrading Nextcloud or pinned image digests.
  - Changing database settings or PHP limits.
  - Modifying reverse proxy ingress.
- Keep one **golden restore** transcript (commands and timestamps) in your team wiki.
- Automate **retention** and **offsite** handling as separate concerns.

---

## 14) Appendix: What the scripts deliberately do **not** do

- They do not handle **retention** or **offsite** storage.
- They do not snapshot the **database volume** directly—DB contents are captured by a consistent **dump**.
- They do not bind-mount `/var/www/html`; restores always target the **named volume**.

---

## 15) Optional: Uptime Kuma integration

The backup script can report its status to **Uptime Kuma** using a **Push** monitor.
This mirrors the Restic backup integration and allows you to see both jobs in the same Grafana dashboard.

### 15.1 How it works

- On every successful run, the script calls:

  ```bash
  push_kuma up "OK"
  ```

- If any step fails (and is not explicitly masked with `|| true`), the global `ERR` trap fires and sends:

  ```bash
  push_kuma down "nc-backup-error"
  ```

- If `KUMA_RESOLVE_IP` is set, the script uses `curl --resolve` to talk to the Uptime Kuma host at a specific IP, which is useful when hairpin NAT or split DNS would otherwise break the push.

The result is:

- A **`Backup Nextcloud`** monitor in Kuma that goes **UP** on successful runs.
- A clear **DOWN** state whenever the backup script fails or does not complete.

### 15.2 Configuration steps

1. In Uptime Kuma, create a **Push** monitor (for example: `Backup Nextcloud`).
2. Copy the generated URL.
3. Set `KUMA_PUSH_URL` in your `nc-backup.env`:

   ```dotenv
   KUMA_PUSH_URL="https://uptime-kuma.example.com/api/push/<TOKEN>"
   ```

4. (Optional) If the URL does not resolve correctly from the backup host, set:

   ```dotenv
   KUMA_RESOLVE_IP=192.168.1.11
   ```

5. Verify that the monitor flips to **UP** after a successful backup run.

Once configured, the Uptime-Kuma-based Grafana dashboard can surface this status next to the Restic backup monitor, giving you a consolidated view of backup health.

---

## 16) Optional: Prometheus metrics and Backups overview

When `nc-backup.sh` is able to source the shared helper:

```text
/opt/homelab-stacks/ops/backups/lib/backup-metrics.sh
```

and has permission to write to the node_exporter textfile directory:

```text
/var/lib/node_exporter/textfile_collector
```

it emits a file:

```text
/var/lib/node_exporter/textfile_collector/nextcloud_backup.prom
```

with these gauges:

- `nextcloud_backup_last_success_timestamp` — Unix timestamp of the last successful Nextcloud backup.
- `nextcloud_backup_last_duration_seconds` — Duration in seconds of the last backup run.
- `nextcloud_backup_last_size_bytes` — Size in bytes of the latest tarball (volume archive).
- `nextcloud_backup_last_status` — Exit code of the last run (0=success, non-zero=failure).

These metrics are combined with the Restic metrics in:

- the `NextcloudBackup*` alert rules in `stacks/monitoring/prometheus/rules/backups.rules.yml`, and
- the `Backups – Overview` dashboard (`40_Backups`) that shows age, duration and size for each job.

If you run the backup as a **non-root** user and the script cannot write to the textfile collector directory, the helper remains **silent** (it does not break the backup). In that case you still have:

- artifacts on disk (`db.sql`, tarball, `.sha256`), and
- a monitor in Uptime Kuma,

but you will not see Prometheus metrics for that job.

---

## 17) See also

**DR Runbook:** [`backup/README.dr.md`](./README.dr.md)
