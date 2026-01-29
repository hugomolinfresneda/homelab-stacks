# Nextcloud — Disaster Recovery (DR)

## Purpose
This runbook covers **disaster recovery** for Nextcloud: total or partial loss, severe corruption, or host rebuild. It restores service, data, and minimum configuration. It does **not** cover performance tuning or advanced observability reconstruction.

## RTO / RPO (Indicative)
- **RTO**: 30–60 minutes on the same host; 2–3 hours on a new host.
- **RPO**: up to the last valid backup (typically daily).
- Assumptions: backups are executed and verified regularly.

---

## Prerequisites

### Canonical variables
```bash
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"
```

### What must be available
- Stacks repo: `${STACKS_DIR}`.
- Private runtime: `${RUNTIME_ROOT}` (or the ability to reconstruct it).
- Access to `BACKUP_DIR` (backup storage).
- Minimum credentials: DB and reverse proxy/tunnel access.

### External dependencies (minimal validation)
- **DNS records**
  - Validation: `dig +short <your-domain>` or `nslookup <your-domain>`.
- **Reverse proxy / tunnel**
  - Validation: service is up and endpoint responds (e.g., `curl -I https://<your-domain>/status.php`).
- **Storage / mounts**
  - Validation: `df -h <BACKUP_DIR>` and `test -w <BACKUP_DIR>`.

### Material to gather (if in incident mode)
- Timestamp of the “last known good” state.
- Most recent verified backup (id/date).
- Failure logs (if the host is still alive).
- Recent changes (upgrade/config).

---

## Covered scenarios
1) **S1 — Total host loss** (new host from scratch)
2) **S2 — Data corruption/loss** (host alive, data damaged)
3) **S3 — Credentials/secrets loss**
4) **S4 — Rollback after failed upgrade**

---

## Common Plan (Applies to all)

### 0) Freeze changes
```bash
cd "${STACKS_DIR}"
make down stack=nextcloud
```

**Success criteria**
- `make ps stack=nextcloud` shows no active services.

### 1) Choose the restore point
- Select a **verified** backup (not just “the latest that exists”).

**Success criteria**
- A verified backup timestamp is identified.

---

## Recommended Recovery Flow (Summary)
> Use this when the environment is controlled and backups are valid.

1) Prepare minimum runtime (`${RUNTIME_DIR}` + envs).
2) Restore backup:
   ```bash
   cd "${STACKS_DIR}"
   make restore stack=nextcloud BACKUP_DIR="/abs/path/to/backups" \
     RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud" \
     ALLOW_INPLACE=1
   ```
   (Optionally set `BACKUP_TS=YYYY-MM-DD_HHMMSS` to restore a specific verified backup.)
3) Start the stack:
   ```bash
   make up stack=nextcloud
   ```
4) Verify (see “Final validation”).

**Success criteria**
- UI responds via reverse proxy/tunnel and `make ps` shows OK services.

---

## S1 — Total Host Loss (Rebuild from Scratch)

### 1) Prepare a new host
- Install Docker + compose plugin.
- Mount backup storage (`BACKUP_DIR`).

**Verification**
```bash
docker --version
docker compose version
df -h
```

### 2) Recover public repo + private runtime
- Clone/restore `${STACKS_DIR}`.
- Restore/obtain `${RUNTIME_ROOT}`.

**Success criteria**
- `${STACKS_DIR}/stacks/nextcloud/compose.yaml` exists.
- `${RUNTIME_DIR}` exists or can be created.

### 3) Recreate minimum runtime
```bash
mkdir -p "${RUNTIME_DIR}"
# Restore ${RUNTIME_DIR}/.env and ${RUNTIME_DIR}/db.env (secrets)
```

**Success criteria**
- `.env` and `db.env` are present with restrictive permissions.

### 4) Restore data from backups
```bash
cd "${STACKS_DIR}"
make restore stack=nextcloud BACKUP_DIR="/abs/path/to/backups" \
  RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud" \
  ALLOW_INPLACE=1
```

**Success criteria**
- Restore completes without errors.

### 5) Start the stack
```bash
cd "${STACKS_DIR}"
make up stack=nextcloud
make ps stack=nextcloud
```

**Success criteria**
- Services are `running/healthy`.
- Public endpoint responds.

---

## S2 — Data Corruption/Loss (Host Alive)

### 1) Stop the stack
```bash
cd "${STACKS_DIR}"
make down stack=nextcloud
```

### 2) (Optional) Preserve evidence
- Take a quick snapshot/copy of the current state if useful.

### 3) Restore from backup
```bash
cd "${STACKS_DIR}"
make restore stack=nextcloud BACKUP_DIR="/abs/path/to/backups" \
  RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud" \
  ALLOW_INPLACE=1
```

### 4) Start and validate
```bash
make up stack=nextcloud
make ps stack=nextcloud
```

**Success criteria**
- The original symptom disappears and logs do not repeat corruption errors.

---

## S3 — Credentials/Secrets Loss

### 1) Identify the missing secret
- DB user/pass, admin bootstrap, certificates, tokens, etc.

### 2) Recover from runtime/backup
- Restore files in `${RUNTIME_DIR}` (e.g., `db.env`).

### 3) Controlled rotation (if required)
- Generate new secrets and apply them in runtime.

**Success criteria**
- Authentication works and logs show no credential errors.

---

## S4 — Rollback After Failed Upgrade

### 1) Identify previous version + pre‑upgrade backup
- Prior image/tag.
- Valid backup before the change.

### 2) Restore consistent data
- Restore DB + volume from the correct timestamp.

### 3) Start and validate
```bash
cd "${STACKS_DIR}"
make up stack=nextcloud
make ps stack=nextcloud
```

**Success criteria**
- Service is stable and functional on the previous version.

---

## Final Validation (Checklist)
- [ ] `make ps stack=nextcloud` shows services `running/healthy`.
- [ ] Public endpoint responds (login/status).
- [ ] A read/write test succeeds without errors.
- [ ] Logs show no repeated errors in the last few minutes.
- [ ] Timers/cron re‑enabled (if applicable).
- [ ] `backup-verify` executed after recovery.

Commands:
```bash
cd "${STACKS_DIR}"
make ps stack=nextcloud
make logs stack=nextcloud
make backup-verify stack=nextcloud BACKUP_DIR="/abs/path/to/backups"
```

---

## Rollback / Safety Notes
- Do not restore onto a live production system without freezing changes.
- Avoid overwriting a live environment without confirming the timestamp.
- Document the point of no return (restore start = current data is lost).

---

## Post‑DR (Required Actions)
- Document root cause and improvement actions.
- Run a fresh backup and verify it.
- Review retention/capacity and scheduling adjustments.

---

## Appendix

### Runtime inventory
- `${RUNTIME_DIR}/.env`
- `${RUNTIME_DIR}/db.env`
- `${RUNTIME_DIR}/compose.override.yaml`

### Docker volumes (reference)
- `nextcloud_nextcloud`
- `nextcloud_db`
- `nextcloud_redis`
