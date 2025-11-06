# Restic — Dual‑repo infrastructure backups

Backs up your **public stacks definition** and **private runtime state** with [restic], integrated with your Makefile and optional health pushes to **Uptime Kuma**.

- **homelab-stacks** (public): backup script + exclude file, documented here.
- **homelab-runtime** (private): your `.env` with repo/password/paths/policy.

[restic]: https://restic.net

---

## Architecture

| Repository          | Purpose                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base (script `ops/backups/restic-backup.sh`, `exclude.txt`, Make targets).        |
| **homelab-runtime** | Private config (`ops/backups/.env` with credentials, policy and the paths to back up).  |

---

## File layout

```
/opt/homelab-stacks/
└── ops/backups/
    ├── restic-backup.sh
    └── exclude.txt

/opt/homelab-runtime/
└── ops/backups/
    └── .env            # your repo/password/policy/paths (not in git)
```

---

## Requirements

- restic installed on the host
- A repository target (local dir, S3/B2, rclone remote…)
- Dual‑repo layout in place

---

## Runtime configuration (`/opt/homelab-runtime/ops/backups/.env`)

Minimal example:

```dotenv
RESTIC_REPOSITORY=$HOME/Backups/homelab-restic
RESTIC_PASSWORD=CHANGE_ME
RESTIC_KEEP_DAILY=7
RESTIC_KEEP_WEEKLY=4
RESTIC_KEEP_MONTHLY=6
RUN_FORGET=1

# Optional grouping for retention (e.g., by host)
# RESTIC_GROUP_BY=host

# Excludes
RESTIC_EXCLUDE_FILE=/opt/homelab-stacks/ops/backups/exclude.txt

# Uptime Kuma push (optional)
KUMA_PUSH_URL=https://uptime-kuma.example.org/api/push/<token>

BACKUP_PATHS=(
  /opt/homelab-stacks/ops
  /opt/homelab-runtime/stacks/couchdb/data
  $HOME/Backups/nextcloud
  /opt/homelab-runtime/stacks/uptime-kuma/data
)
```

> The script tolerates missing paths and skips them safely.

---

## Deployment (Makefile shortcuts)

From the **stacks** repo:

```bash
make restic                # run backup (applies retention if RUN_FORGET=1)
make restic-list           # list snapshots
make restic-check          # repository integrity
make restic-stats          # repository stats
make restic-forget-dry     # preview what would be deleted (no changes)
make restic-forget         # apply retention now (delete & prune)
make restic-diff           # diff last two snapshots (or pass A=.. B=..)
make restic-restore INCLUDE="/path1 /path2" [TARGET=dir]   # selective restore from latest
make restic-mount [MOUNTPOINT=dir]                         # FUSE mount for browsing
make restic-show-env       # show repo/policy/group-by/exclude file
make restic-exclude-show   # print active exclude file
```

---

## Manual run (portable)

```bash
ENV_FILE=/opt/homelab-runtime/ops/backups/.env \
/opt/homelab-stacks/ops/backups/restic-backup.sh
```

---

## Uptime Kuma

If `KUMA_PUSH_URL` is set, the script pushes **up/down** with a short message:
- `up` on success (or `no-op` if nothing to back up)
- `down` with a reason on preflight errors

---

## Troubleshooting

| Symptom                                  | Likely cause / fix                                    |
| ---------------------------------------- | ----------------------------------------------------- |
| `restic: command not found`              | Install restic on the host.                           |
| `RESTIC_REPOSITORY is empty`             | Missing values in `.env`.                             |
| No changes despite edits                 | Check `exclude.txt` and `BACKUP_PATHS`.               |
| Retention keeps too many snapshots       | Verify `RESTIC_GROUP_BY` and `KEEP_*` in `.env`.      |
| Kuma does not flip to OK                 | Check `KUMA_PUSH_URL` and host DNS/hairpin issues.    |

---

## Security notes

- `.env` lives in **runtime** and is **not** versioned.
- The restic repository is encrypted; still protect storage and permissions.
- For offsite copies, combine with `rclone`/object storage lifecycle.
