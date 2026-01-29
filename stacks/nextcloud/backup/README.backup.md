# Nextcloud — Backups

## Purpose
Operational guide for “normal” Nextcloud backups (not full DR). It covers how to generate, verify, and minimally restore to recover from accidental deletion, mild corruption, or a failed upgrade. It does **not** cover total host loss (see `README.dr.md`).

## Scope (what gets backed up)
> If it is not listed here, it is not assumed to be covered.

### Data
- **Named volume** containing Nextcloud code/config/data (`nextcloud_nextcloud`).

### Database
- Engine: **MariaDB**.
- Method: **consistent dump** (`mariadb-dump --single-transaction --quick --routines --events`).

### Configuration
- Runtime envs: `${RUNTIME_DIR}/.env` and `${RUNTIME_DIR}/db.env` (not versioned).

---

## Requirements

### Software / Tooling
- Docker Engine + Docker Compose plugin.
- GNU Make (`make`).
- (Optional) `curl` and `sha256sum` for manual verification.

### Permissions
- The backup writes to `BACKUP_DIR` (must be writable by the user running the script).

### Canonical variables
```bash
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"
```

---

## Layout (Repo vs Runtime)
- Repo (versioned): `${STACKS_DIR}/stacks/nextcloud/backup/`
  - `nc-backup.sh`, `nc-restore.sh`, `nc-backup.env.example`
- Runtime (not versioned): `${RUNTIME_DIR}/...`
  - real envs and secrets

Where backup configuration lives:
- **Backup env (recommended)**: `${RUNTIME_ROOT}/ops/backups/nc-backup.env`
- **BACKUP_DIR**: `/abs/path/to/backups` (artifact storage)

---

## Strategy
- Method: **DB dump + volume tar** + checksum.
- Consistency: **maintenance mode**; if it fails, the script stops `app/web/cron` and keeps DB running.
- Verification: combined `.sha256` for dump + tar.

Artifacts per run in `BACKUP_DIR`:
- `nc-<UTC_TS>-db.sql` (DB dump)
- `nc-vol-<UTC_TS>.tar.gz` (Nextcloud volume)
- `nc-<UTC_TS>.sha256` (checksums)

---

## Backup procedure

**Success criteria**
- Artifacts created in `BACKUP_DIR`.
- `.sha256` matches the generated artifacts.
- Logs contain no repeated errors.

### Makefile (recommended)
```bash
cd "${STACKS_DIR}"
make backup stack=nextcloud BACKUP_DIR="/abs/path/to/backups" \
  BACKUP_ENV="${RUNTIME_ROOT}/ops/backups/nc-backup.env"
```

### Manual (escape hatch)
```bash
ENV_FILE="${RUNTIME_ROOT}/ops/backups/nc-backup.env" \
BACKUP_DIR="/abs/path/to/backups" \
bash "${STACKS_DIR}/stacks/nextcloud/backup/nc-backup.sh"
```

---

## Verification procedure

**Success criteria**
- `sha256sum` returns `OK` for both dump and tar.

### Makefile (recommended)
```bash
cd "${STACKS_DIR}"
make backup-verify stack=nextcloud BACKUP_DIR="/abs/path/to/backups"
```

### Manual (escape hatch)
```bash
cd "/abs/path/to/backups"
sha256sum -c nc-<UTC_TS>.sha256
```

---

## Minimal Restore. `TODO: implement restore guardrails`

```bash
cd "${STACKS_DIR}"
make restore stack=nextcloud BACKUP_DIR="/abs/path/to/backups" \
  RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"
```

**Success criteria**
- The script completes without errors.
- Volume and DB are restored for a subsequent `make up`.

---

## Retention / Cleanup
**N/A** — No automated retention in these scripts.
Use your preferred tooling (restic/rclone/ZFS/etc.) for rotation and offsite.

---

## Scheduling (systemd)

**Stack delivery vs host install**
- This stack ships **examples**: `${RUNTIME_DIR}/backup/systemd/homelab-nc-backup.service.example` and
  `${RUNTIME_DIR}/backup/systemd/homelab-nc-backup.timer.example`.
- Host installation is distro-dependent. `/etc/systemd/system` is a **typical default**.

### Install (typical flow)
Systemd unit files do **not** expand `${VARS}` at runtime. Replace example paths with absolute paths.

```bash
STACKS_DIR="/abs/path/to/homelab-stacks"
RUNTIME_ROOT="/abs/path/to/homelab-runtime"
RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"

sudo cp "${RUNTIME_DIR}/backup/systemd/homelab-nc-backup.service.example" \
  /etc/systemd/system/homelab-nc-backup.service
sudo cp "${RUNTIME_DIR}/backup/systemd/homelab-nc-backup.timer.example" \
  /etc/systemd/system/homelab-nc-backup.timer
sudo $EDITOR /etc/systemd/system/homelab-nc-backup.service
sudo $EDITOR /etc/systemd/system/homelab-nc-backup.timer
```

Update the unit files so `/abs/path/to/homelab-stacks` and `/abs/path/to/homelab-runtime`
match your host. The service uses `Environment=` entries (not `EnvironmentFile=`), sets
`ENV_FILE=...`, and the backup script loads it if readable.
The run fails if required variables are missing (notably `NC_DB_NAME`, `NC_DB_USER`,
`NC_DB_PASS`, or `RUNTIME_ROOT`).

If `ENV_FILE` is not set, the script defaults to `~/.config/nextcloud/nc-backup.env`.

The backup script resolves `STACKS_DIR` from its own location, so `WorkingDirectory=`
is not required unless you customize the script.

### Enable and validate
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-nc-backup.timer
systemctl status homelab-nc-backup.service
systemctl list-timers | rg nc-backup
journalctl -u homelab-nc-backup.service -n 200 --no-pager
systemd-analyze verify /etc/systemd/system/homelab-nc-backup.service # if available
```

**Notes**
- If your backups depend on remote mounts, consider systemd's `RequiresMountsFor=` (advanced).

**Success criteria**
- Timer is active.
- Logs show successful runs.
- New artifacts appear in `BACKUP_DIR`.

---

## Troubleshooting

### “Another backup is running. Exiting.”
- **Confirmation**: `BACKUP_DIR/.lock` exists.
- **Fix**: remove the lock only if you are sure no active process is running.

### “Maintenance mode toggle fails (read‑only config)”
- **Confirmation**: script logs show the fallback path.
- **Fix**: the script stops `app/web/cron` and continues; review permissions if it repeats.

### “Missing artifacts” on restore
- **Confirmation**: patterns `nc-*-db.sql[.gz]` and `nc-vol-*.tar.gz` are missing.
- **Fix**: verify `BACKUP_DIR` and the expected timestamp.

---

## References
- `stacks/nextcloud/README.md`
- `stacks/nextcloud/backup/README.dr.md`
- `ops/backups/README.md`
