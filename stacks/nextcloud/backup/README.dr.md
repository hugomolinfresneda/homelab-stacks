# Nextcloud — Disaster Recovery (DR) Runbook

> **Scope**: This runbook covers end‑to‑end recovery of the **Nextcloud** stack deployed with the split repos model
> **public**: `STACKS_DIR` (e.g. `/opt/homelab-stacks`); **runtime**: `RUNTIME_ROOT` (e.g. `/opt/homelab-runtime`).
> It assumes you are using the provided backup scripts: `stacks/nextcloud/backup/nc-backup.sh` and
> `stacks/nextcloud/backup/nc-restore.sh`.

Use the canonical variables for absolute paths in this runbook:
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"    # e.g. /opt/homelab-stacks
export RUNTIME_ROOT="/abs/path/to/homelab-runtime" # e.g. /opt/homelab-runtime
RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"
```

---

## 0) Quick “Panic Card” (TL;DR)

1. **Declare incident** → pick the scenario (A/B/C) below.
2. **Freeze changes** on Nextcloud (announce downtime).
3. **Verify most recent backup**:
   ```bash
   # Public repo
   make backup-verify stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud"
   ```
4. **Restore** (latest backup):
   ```bash
   # Public repo
   make restore stack=nextcloud \
     BACKUP_DIR="$HOME/Backups/nextcloud" \
     RUNTIME_DIR="${RUNTIME_DIR}"
   ```
5. **Smoke tests** → status, HTTP checks (see §6).
6. **Close incident** → write short post‑mortem (what failed, what we fixed, how to prevent).

---

## 1) Assumptions & Objectives

- **RTO target** (time to restore): ≤ 30–60 min on the same host; ≤ 2–3 h on a new host.
- **RPO target** (data loss): up to the last successful dump (typically daily).
- **Backups** contain:
  - DB logical dump: `nc-YYYY-MM-DD_HHMMSS-db.sql`
  - Nextcloud volume archive: `nc-vol-YYYY-MM-DD_HHMMSS.tar.gz`
  - Combined checksum: `nc-YYYY-MM-DD_HHMMSS.sha256`
- **Where**: default `~/Backups/nextcloud` (adjust per environment).

> Future hardening (optional): encrypt & ship offsite (restic/rclone), retention policies, scheduled test restores.

---

## 2) Roles & Contacts (fill in)

- **Incident Lead**: _name / phone / IM_
- **Runtime Owner**: _name / phone / IM_
- **DNS/Proxy Owner**: _name / phone / IM_

---

## 3) Triggers (When to run this)

- Production outage (HTTP 5xx, login loop, stuck maintenance).
- DB corruption / container won’t start / data loss detected.
- Host failure / OS reinstallation / migration to new hardware.
- Security incident requiring rollback to known‑good state.

---

## 4) Pre‑flight Checklist (5 min)

- [ ] Confirm incident scope and expected user impact.
- [ ] Announce downtime (status page / chat).
- [ ] Ensure **backup location is reachable** and **has free space**.
- [ ] Confirm **runtime .env** has correct DB creds (used during restore).
- [ ] (Optional) Snapshot host volumes if using ZFS/btrfs/LVM.
- [ ] Ensure Docker is up: `docker ps`.

---

## 5) Recovery Scenarios

### A) App/config broken, data intact (soft failure)

Symptoms: 502 from `web`, app container crash loop, wrong config, but DB and data likely OK.

**Steps**

1. **Recreate containers** (pull+up):
   ```bash
   # Runtime (preferred)
   cd "${RUNTIME_ROOT}"
   make pull stack=nextcloud
   make up   stack=nextcloud
   make status stack=nextcloud
   ```
2. If still failing, **restore only volume** from latest backup (keeps DB):
   Use full restore and **skip DB import** by temporarily moving the `*-db.sql` aside or restoring a timestamp that only fixes app/config (see §7).

3. Run **repairs**:
   ```bash
   ${STACKS_DIR}/stacks/nextcloud/tools/occ maintenance:repair || true
   ${STACKS_DIR}/stacks/nextcloud/tools/occ db:add-missing-indices || true
   ```

### B) Data corruption or bad upgrade (need to roll back)

Symptoms: unknown errors after upgrade, missing files, broken indices, DB integrity issues.

**Steps**

1. **Verify the backup** you intend to use:
   ```bash
   make backup-verify stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud"
   ```
2. **Restore full** (volume + DB) from **latest known‑good timestamp**:
   ```bash
   make restore stack=nextcloud \
     BACKUP_DIR="$HOME/Backups/nextcloud" \
     RUNTIME_DIR="${RUNTIME_DIR}"
   ```
3. **Post‑restore repairs** will run automatically; if needed, run again:
   ```bash
   ${STACKS_DIR}/stacks/nextcloud/tools/occ maintenance:repair || true
   ```
4. Validate with the smoke tests in §6.

### C) New host / total loss (bare‑metal/cloud re‑provision)

1. **Reinstall prerequisites**:
   ```bash
   # Minimal essentials
   sudo apt-get update && sudo apt-get install -y ca-certificates curl git
   sudo install -m 0755 -d /etc/apt/keyrings
   curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo $ID)/gpg | \
     sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
   echo \
     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
     https://download.docker.com/linux/$(. /etc/os-release; echo $ID) \
     $(. /etc/os-release; echo $VERSION_CODENAME) stable" | \
     sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
   sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
   sudo usermod -aG docker "$USER"
   newgrp docker
   ```
2. **Recover repos**:
   ```bash
   sudo mkdir -p "${STACKS_DIR}" "${RUNTIME_ROOT}"
   sudo chown -R "$USER":"$USER" "${STACKS_DIR}" "${RUNTIME_ROOT}"

   # Clone your repos (adjust remotes/branches)
   git clone <PUBLIC_REPO_URL>  "${STACKS_DIR}"
   git clone <RUNTIME_REPO_URL> "${RUNTIME_ROOT}"
   ```
3. **Prepare runtime**:
   - Ensure `${RUNTIME_DIR}/.env` exists and is correct.
   - Ensure `compose.override.yml` exposes `web` to your reverse proxy (port/bind).
   - Create external proxy network if needed:
     ```bash
     docker network create proxy || true
     ```
4. **Start stack** (no data yet; we will restore next):
   ```bash
   cd "${RUNTIME_ROOT}"
   make up stack=nextcloud
   ```
5. **Restore** from backups:
   ```bash
   cd "${STACKS_DIR}"
   make restore stack=nextcloud \
     BACKUP_DIR="$HOME/Backups/nextcloud" \
     RUNTIME_DIR="${RUNTIME_DIR}"
   ```
6. **Re‑attach reverse proxy / tunnel** (if applicable):
   - Nginx/Traefik: route `cloud.example.com` → `web:8080` (via `proxy` network).
   - Cloudflare Tunnel: ingress → `http://web:8080` (container must be on `proxy` network).
7. Run **smoke tests** (§6) and close incident.

---

## 6) Validation & Smoke Tests (post‑restore)

1. **Runtime health**:
   ```bash
   docker compose \
     -f "${STACKS_DIR}/stacks/nextcloud/compose.yaml" \
     -f "${RUNTIME_DIR}/compose.override.yml" \
     --env-file "${RUNTIME_DIR}/.env" ps
   ```

   Nota: si en tu runtime el override es `compose.override.yaml`, usa ese fichero.

2. **OCC / Nextcloud status**:
   ```bash
   ${STACKS_DIR}/stacks/nextcloud/tools/nc status
   # or directly:
   ${STACKS_DIR}/stacks/nextcloud/tools/occ status
   ```

3. **HTTP check inside the docker network** (200/302/403 acceptable during bootstrap):
   ```bash
   docker run --rm --network nextcloud_default curlimages/curl:8.10.1 -sSI http://web:8080 | head -n1
   ```

4. **Status endpoint with Host header**:
   ```bash
   docker run --rm --network nextcloud_default curlimages/curl:8.10.1 \
     -sSI -H "Host: ${NC_DOMAIN}" http://web:8080/status.php | head -n1
   ```

5. **Basic UX**: login works, file list loads, uploads OK, previews generate, search indexes update.

---

## 7) Picking a Specific Timestamp

By default `nc-restore.sh` selects the **latest** pair. To restore a specific timestamp, temporarily move undesired artifacts
out of the folder so the script picks the pair you want:

```bash
# Keep only the desired triplet in the backup folder:
#   nc-<TS>-db.sql[.gz], nc-vol-<TS>.tar.gz, nc-<TS>.sha256
mkdir -p "$HOME/Backups/nextcloud/_tmp"
find "$HOME/Backups/nextcloud" -maxdepth 1 -type f -name 'nc-*' \
  ! -name 'nc-2025-10-30_101346*' -exec mv {} "$HOME/Backups/nextcloud/_tmp/" \;
```

Run restore as usual, then move files back.

---

## 8) Running from Public vs Runtime

**Public repository** (`STACKS_DIR`; e.g. `/opt/homelab-stacks`):
```bash
# Backup
make backup stack=nextcloud \
  BACKUP_DIR="$HOME/Backups/nextcloud" \
  BACKUP_ENV="$HOME/.config/nextcloud/nc-backup.env"

# Verify
make backup-verify stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud"

# Restore
make restore stack=nextcloud \
  BACKUP_DIR="$HOME/Backups/nextcloud" \
  RUNTIME_DIR="${RUNTIME_DIR}"
```

**Runtime repository** (`RUNTIME_ROOT`; e.g. `/opt/homelab-runtime`):
```bash
make backup         stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud" BACKUP_ENV="$HOME/.config/nextcloud/nc-backup.env"
make backup-verify  stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud"
make restore        stack=nextcloud BACKUP_DIR="$HOME/Backups/nextcloud"
```

> Both paths are supported. Public `restore` needs `RUNTIME_DIR` to load the override and `.env` correctly.

---

## 9) Known Pitfalls & Fixes

- **Left in maintenance mode** after a failed run:
  ```bash
  ${STACKS_DIR}/stacks/nextcloud/tools/occ maintenance:mode --off || true
  ```

- **502 from reverse proxy** right after recovery:
  - `app` not ready yet; wait 30–60 seconds and check logs.
  - Tunnel/proxy not on the same network as `web`, or wrong upstream (`web:8080`).

- **“Cannot write into config directory!”**
  - Do **not** bind‑mount `/var/www/html` from host. Use named volume (`nextcloud_nextcloud`).

- **DB import permission errors**
  - Ensure runtime `.env` has the correct `NC_DB_USER`, `NC_DB_PASS`, `NC_DB_NAME` used by the restore script.

- **Backups folder cluttered**
  - Move old triplets to an archive folder. Keep 3–7 days locally, ship older offsite (policy dependent).

---

## 10) Scheduled Tests & Retention (Policy Suggestion)

- **Backup cadence**: daily DB dump + volume archive (nightly).
- **Verification**: `make backup-verify …` after each run (cron).
- **Test restore**: at least **monthly** on a scratch host/VM. Keep a log of test results.
- **Retention**: 7 daily + 4 weekly locally; offsite 90+ days (encrypted).
- **Offsite**: restic to S3-compatible (WORM), or rclone to a cloud bucket (budget‑dependent).

---

## 11) Post‑Incident Checklist

- [ ] Service availability restored; users confirmed.
- [ ] Document exact timestamp restored and reason for failure.
- [ ] Capture diffs between pre/post config if relevant.
- [ ] Create follow‑up issues (monitoring gaps, automation, retention).
- [ ] Schedule a test restore if none in the last 30 days.

---

## 12) Appendix: Manual One‑Liners

- **Manual DB dump** (bypass script):
  ```bash
  docker compose -f ${STACKS_DIR}/stacks/nextcloud/compose.yaml \
    -f ${RUNTIME_DIR}/compose.override.yml \
    --env-file ${RUNTIME_DIR}/.env \
    exec -T db sh -lc 'exec mariadb-dump -u"$$MARIADB_USER" -p"$$MARIADB_PASSWORD" "$$MARIADB_DATABASE"' > nextcloud.sql
  ```

- **Manual volume tar**:
  ```bash
  docker run --rm -v nextcloud_nextcloud:/vol -v "$PWD":/backup busybox sh -lc 'cd /vol && tar czf /backup/nextcloud-vol.tgz .'
  ```

- **Wipe & reinstall** (only for labs; **dangerous** on prod):
  ```bash
  ${STACKS_DIR}/stacks/nextcloud/tools/nc down
  docker volume rm nextcloud_db nextcloud_nextcloud nextcloud_redis || true
  ${STACKS_DIR}/stacks/nextcloud/tools/nc up
  ${STACKS_DIR}/stacks/nextcloud/tools/nc install
  ${STACKS_DIR}/stacks/nextcloud/tools/nc post
  ${STACKS_DIR}/stacks/nextcloud/tools/nc status
  ```

---

### Change Log

- **2025‑10‑30** — Initial version aligned with backup/restore scripts and Makefile targets.
