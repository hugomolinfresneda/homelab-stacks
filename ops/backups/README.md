# Restic — dual-repo infrastructure backups

Backs up your **public stacks definition** and **private runtime state** with [restic], integrated with:

- a dual-repo layout (`STACKS_DIR` + `RUNTIME_ROOT`),
- a Makefile-first entrypoint (`make backup stack=restic`),
- an optional root-owned systemd service for scheduling,
- optional health pushes to **Uptime Kuma**,
- optional **Prometheus** metrics via node_exporter’s textfile collector.

What this does **not** do:
- It does **not** back up the Nextcloud data volume (use the dedicated Nextcloud backup flow).
- It does **not** store host-specific paths or secrets in the repo (see the contract below).

[restic]: https://restic.net

---

## Requirements

- `restic` installed on the host.
- `systemd` + `sudo` **if** you use Makefile targets that call systemd.
- `curl` **if** you enable Uptime Kuma pushes (`KUMA_PUSH_URL`).
- `jq` **optional** (used by `make restic-diff` auto-detection and stats in the backup script).
- `node_exporter` textfile collector **if** you want Prometheus metrics.

---

## Contract (repo vs runtime)

This tool follows the public-to-runtime contract:

- Public repo: `${STACKS_DIR}` (versioned scripts, templates, examples)
- Private runtime: `${RUNTIME_ROOT}` (real env files, credentials, runtime data)

See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

---

## Layout on disk

### Repo (versioned)
- `${STACKS_DIR}/ops/backups/`
  - `README.md`
  - `.env.example`
  - `exclude.txt`
  - `restic-backup.sh`
  - `lib/backup-metrics.sh`

### Runtime (not versioned)
- `${RUNTIME_ROOT}/ops/backups/restic.env` (default path **for this repo**; see below)

> Note: system paths like `/etc/systemd/system` or `/var/lib/node_exporter/textfile_collector`
> are **defaults/typical examples** and may vary by distro/installation.

---

## Setup

### 1) Define canonical variables.
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
```

### 2) Create runtime directory for backups
```sh
mkdir -p "${RUNTIME_ROOT}/ops/backups"
```

### 3) Copy environment file
The repo ships an example env file:
- Repo: `${STACKS_DIR}/ops/backups/.env.example`

Default path **in this repo**:
- Runtime: `${RUNTIME_ROOT}/ops/backups/restic.env`

```sh
cp "${STACKS_DIR}/ops/backups/.env.example" \
  "${RUNTIME_ROOT}/ops/backups/restic.env"
# EDIT: ${RUNTIME_ROOT}/ops/backups/restic.env (read next section below)
```

If your environment uses a different env path:
- **Makefile**: set `RESTIC_ENV_FILE=/abs/path/to/restic.env`
- **Script**: set `ENV_FILE=/abs/path/to/restic.env`

### 4) Adjust the exclude file (if applicable)
`exclude.txt` lives in the repo:
- `${STACKS_DIR}/ops/backups/exclude.txt`

Edit it in the repo if you need to exclude additional paths.

---

## Configuration (restic.env)

The backup script reads `restic.env` and exports its values.
Below is a minimal map of variables (from `.env.example`).

| Variable | Required | Example | Description |
|---|---:|---|---|
| `BACKUPS_DIR` | ✅ | `/abs/path/to/backups` | Base path for local backup storage. |
| `RESTIC_REPOSITORY` | ✅ | `${BACKUPS_DIR}/homelab-restic` or `s3:...` | Restic repo location. |
| `RESTIC_PASSWORD` | ✅ | `CHANGE_ME` | Repo password (do not commit). |
| `RESTIC_KEEP_DAILY` | ❌ | `7` | Retention: keep daily snapshots. |
| `RESTIC_KEEP_WEEKLY` | ❌ | `4` | Retention: keep weekly snapshots. |
| `RESTIC_KEEP_MONTHLY` | ❌ | `6` | Retention: keep monthly snapshots. |
| `RESTIC_GROUP_BY` | ❌ | `host` | Grouping for retention. |
| `RUN_FORGET` | ❌ | `1` | Apply retention after each backup. |
| `RESTIC_EXCLUDE_FILE` | ❌ | `${STACKS_DIR}/ops/backups/exclude.txt` | Exclude file (preferred name). |
| `BACKUP_TEXTFILE_DIR` | ❌ | `/abs/path/textfile_collector` | Prometheus textfile dir (overrides default). |
| `KUMA_PUSH_URL` | ❌ | `https://uptime-kuma.<YOUR_DOMAIN>/api/push/<YOUR_TOKEN>` | Kuma push URL (placeholder only). |
| `KUMA_RESOLVE_IP` | ❌ | `<KUMA_LAN_IP>` | Optional DNS override for Kuma. |
| `BACKUP_PATHS` | ✅ | see array below | List of host paths to back up. Missing paths are skipped. |

`RESTIC_EXCLUDE_FILE` is preferred; the script also accepts `EXCLUDE_FILE` and legacy
`RESTIC_EXCLUDES_FILE` (precedence: `EXCLUDE_FILE` > `RESTIC_EXCLUDE_FILE` > `RESTIC_EXCLUDES_FILE`).

Example `BACKUP_PATHS` (from `.env.example`):
```bash
BACKUP_PATHS=(
  /abs/path/to/homelab-stacks/ops
  /abs/path/to/homelab-runtime/stacks/couchdb/data
  /abs/path/to/homelab-runtime/backups/nextcloud
  /abs/path/to/homelab-runtime/stacks/uptime-kuma/data
)
```

> NOTE: do **not** put the Nextcloud data volume here; use the dedicated Nextcloud backup flow.

---

## Daily operation (Makefile-first)

Targets (from `Makefile`):

```text
make backup stack=restic                      - Run Restic backup via systemd (root)
make restic-list                              - Show snapshots
make restic-check                             - Check repository integrity
make restic-stats                             - Show repository stats
make restic-forget                            - Apply retention now (delete & prune)
make restic-forget-dry                        - Preview retention (no changes)
make restic-diff A=<id> B=<id>                - Diff between two snapshots
make restic-restore INCLUDE="/path ..."       - Selective restore (latest snapshot)
make restic-restore-full                      - Restore exactly BACKUP_PATHS to TARGET (default staging dir)
make restic-mount [MOUNTPOINT=/path/to/mount] - Mount repository (background)
make restic-show-env                          - Show effective repo/policy/Kuma URL
```

### Recommended route
```bash
cd "${STACKS_DIR}"
make backup stack=restic
```

**Success criteria**
- `systemctl start` returns exit code 0 (Makefile target succeeds).
- Logs show `Backup completed successfully` (or `no-op` if no paths exist).
- `make restic-list` shows a new snapshot.

### Notes per target (minimum criteria)
- `make restic-list`: output includes snapshot IDs and timestamps.
- `make restic-check`: exits 0 with repository integrity OK.
- `make restic-stats`: prints repository statistics.
- `make restic-forget-dry`: prints the retention command with `--dry-run`.
- `make restic-forget`: exits 0 and prunes per policy.
- `make restic-diff A=.. B=..`: prints a diff between snapshots.
  - If `A`/`B` are not set, the target auto-detects the last two snapshots **only if** `jq` is installed.
- `make restic-restore INCLUDE="/path ..." [TARGET=dir]`:
  - If `TARGET` is not set, the target prints a temp dir and restores there.
  - Success: restored files exist under the target dir.
- `make restic-restore-full [SNAPSHOT=latest] [TARGET=dir] [ALLOW_INPLACE=1]`:
  - Restores **exactly** the items listed in `BACKUP_PATHS` from `restic.env`.
  - If `TARGET` is not set, the target prints a temp dir and restores there.
  - `TARGET=/` is destructive and **requires** `ALLOW_INPLACE=1`.
- `make restic-mount [MOUNTPOINT=dir]`:
  - Success: mountpoint is accessible; unmount with `sudo fusermount -u <mountpoint>`.
- `make restic-show-env`: prints effective repo/policy/Kuma URL and exclude file.

---

## Direct Restic usage (advanced operations)

Use a **single canonical pattern** to load the env and call restic directly:

```bash
set -a; . "<ENV_FILE>"; set +a; restic snapshots
```

Choose `<ENV_FILE>` as follows:
- If you set `RESTIC_ENV_FILE` for Makefile targets, use that same path.
- Otherwise, use the repo default: `${RUNTIME_ROOT}/ops/backups/restic.env`.

(If you need a different path for the backup script itself, set `ENV_FILE=/abs/path/to/restic.env`.)

---

## Verification

```bash
cd "${STACKS_DIR}"
make restic-list
make restic-check
```

**Success criteria**
- `restic-list` shows snapshots with recent timestamps.
- `restic-check` exits 0.

If Prometheus metrics are enabled, validate the textfile output:
```bash
cat "${BACKUP_TEXTFILE_DIR}/restic_backup.prom"
```
`BACKUP_TEXTFILE_DIR` defaults to `/var/lib/node_exporter/textfile_collector` (typical default; may vary by distro).

---

## Restore / Recovery

### Selective restore (file or path)
```bash
cd "${STACKS_DIR}"
make restic-restore INCLUDE="/path/in/backup ..." [TARGET=/abs/path/to/restore-target]
```

**Success criteria**
- Files appear under the target directory.
- The command exits 0.

### Full restore (everything included in BACKUP_PATHS)
```bash
cd "${STACKS_DIR}"
make restic-restore-full
make restic-restore-full TARGET=/abs/path/to/restore-target
make restic-restore-full SNAPSHOT=<id> TARGET=/abs/path/to/restore-target
make restic-restore-full TARGET=/ ALLOW_INPLACE=1
```

**What it does**
- Restores **exactly** the items listed in `BACKUP_PATHS` from `restic.env`.
- Defaults to a safe staging directory if `TARGET` is not set.
- Requires an explicit opt-in for in-place restore: `TARGET=/` with `ALLOW_INPLACE=1`.

**Guardrails**
- `TARGET=/` is destructive and requires `ALLOW_INPLACE=1` or the command hard-fails.
- `BACKUP_PATHS` must exist and be non-empty in `restic.env` or the command hard-fails.
- The target prints the snapshot, target, and include list before running `restic restore`.

**Snapshot selection**
- Default: `SNAPSHOT=latest`
- Set `SNAPSHOT=<id>` to restore a specific snapshot.

**BACKUP_PATHS format (repo-verified)**
- `BACKUP_PATHS` is a **bash array** (the env file is sourced by bash, not parsed as dotenv; see `ops/backups/.env.example` and `ops/backups/restic-backup.sh`).
- Example:
```bash
BACKUP_PATHS=(
  "/abs/path/to/homelab-stacks/ops"
  "/abs/path/to/homelab-runtime/stacks/couchdb/data"
  "/abs/path/to/backups/nextcloud"
  "/abs/path/to/homelab-runtime/stacks/uptime-kuma/data"
)
```
- `BACKUP_PATHS` represents host paths to include in the backup (normally absolute).
  `restic-restore-full` strips any leading `/` when building `--include` because Restic typically stores
  absolute paths without the leading slash. You do not need to remove the `/` in `BACKUP_PATHS`.

**Success criteria**
- Exit code 0.
- Under `TARGET`, the restored paths exist with the expected layout.
- If `TARGET=/`, files land in their real locations on the host.

---

## Scheduling (systemd)

**Repo delivery vs host install**
- This repo ships **examples**: `ops/backups/systemd/homelab-restic-backup.service.example` and
  `ops/backups/systemd/homelab-restic-backup.timer.example`.
- Host installation is distro-dependent. `/etc/systemd/system` is a **typical default**.

### Install (typical flow)
Systemd unit files do **not** expand `${VARS}` at runtime. Replace example paths with absolute paths.

```bash
STACKS_DIR="/abs/path/to/homelab-stacks"
RUNTIME_ROOT="/abs/path/to/homelab-runtime"
RUNTIME_DIR="${RUNTIME_ROOT}/stacks/<stack>"

sudo cp "${STACKS_DIR}/ops/backups/systemd/homelab-restic-backup.service.example" \
  /etc/systemd/system/homelab-restic-backup.service
sudo cp "${STACKS_DIR}/ops/backups/systemd/homelab-restic-backup.timer.example" \
  /etc/systemd/system/homelab-restic-backup.timer
sudo $EDITOR /etc/systemd/system/homelab-restic-backup.service
sudo $EDITOR /etc/systemd/system/homelab-restic-backup.timer
```

Update the unit files so `/abs/path/to/homelab-stacks` and `/abs/path/to/homelab-runtime`
match your host. The service uses `EnvironmentFile=` and **fails hard** if the env file
is missing; this is intentional to avoid running without credentials.

The backup script resolves `STACKS_DIR` from its own location, so `WorkingDirectory=`
is not required unless you customize the script.

### Enable and validate
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-restic-backup.timer
systemctl status homelab-restic-backup.service
systemctl list-timers | rg restic
journalctl -u homelab-restic-backup.service -n 200 --no-pager
systemd-analyze verify /etc/systemd/system/homelab-restic-backup.service # if available
```

The Makefile uses `RESTIC_SYSTEMD_SERVICE` (default: `homelab-restic-backup.service`).
See `Makefile:304`. If your unit name differs, set `RESTIC_SYSTEMD_SERVICE` accordingly.

**Notes**
- Variables defined with `Environment=` in the unit file override values from `EnvironmentFile=`.
- If your backups depend on remote mounts, consider systemd's `RequiresMountsFor=` (advanced).

---

## Observability

The backup script sources:
```text
${STACKS_DIR}/ops/backups/lib/backup-metrics.sh
```

If enabled and writable, it writes:
```text
${BACKUP_TEXTFILE_DIR}/restic_backup.prom
```

Notes:
- `BACKUP_TEXTFILE_DIR` can be overridden in `restic.env`.
- Default is `/var/lib/node_exporter/textfile_collector` (typical; may vary by distro).
- If the directory is not writable, the helper **fails soft** and the backup still completes.

Validate metrics:
```bash
cat "${BACKUP_TEXTFILE_DIR}/restic_backup.prom"
```

---

## Troubleshooting

### Env file missing or unreadable
- **Confirmation**: log shows `ENV_FILE not found or not readable`.
- **Solution**: copy `.env.example` to runtime and set `RESTIC_ENV_FILE`/`ENV_FILE` if needed.

### `RESTIC_REPOSITORY` / `RESTIC_PASSWORD` empty
- **Confirmation**: log shows `RESTIC_REPOSITORY is empty` or `RESTIC_PASSWORD is empty`.
- **Solution**: fill values in `restic.env` (runtime, not versioned).

### `restic: command not found`
- **Confirmation**: log shows `restic not found in PATH`.
- **Solution**: install `restic` on the host.

### No existing paths in `BACKUP_PATHS`
- **Confirmation**: log shows `No existing paths in BACKUP_PATHS; skipping backup run`.
- **Solution**: ensure paths exist in `BACKUP_PATHS`.

### Permission denied in runtime or textfile dir
- **Confirmation**: `ls -l ${RUNTIME_ROOT}/ops/backups` or the textfile dir shows wrong owner/mode.
- **Solution**: fix ownership/permissions; use `600` for secrets/env files.

### `BACKUP_TEXTFILE_DIR` incorrect
- **Confirmation**: `.prom` file missing in expected dir.
- **Solution**: set `BACKUP_TEXTFILE_DIR` to the correct textfile collector path.

---

## Security

- `restic.env` lives in runtime and must not be committed.
- Recommended permissions: `chmod 600` on env/secrets; restrict repo access to root where needed.
- See `docs/contract.md` for the repo/runtime boundary.

---

## References

- `docs/contract.md`
- `docs/runtime-overrides.md`
- [Restic docs](https://restic.readthedocs.io/en/latest/manual_rest.html)
