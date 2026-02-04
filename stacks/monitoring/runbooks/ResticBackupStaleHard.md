# ResticBackupStaleHard — Restic backup stale (>48h)

## Summary
The last successful Restic backup is older than the RPO hard limit (48h). Data recovery would miss recent changes.

## Severity / Urgency
- `severity`: `critical`
- Urgency:
  - **critical**: RPO breach; fix backup pipeline immediately.

## Impact
- Data loss window exceeds 48 hours.
- Backup repository may be stale or inaccessible.

## Context / Scope
- `stack`: `monitoring`
- `service`: `restic`
- `job`: `node` (textfile collector metrics scraped by node-exporter)
- `instance/target`: `<NODE_INSTANCE>` (from Alertmanager labels or Prometheus target label)
- Links:
  - Prometheus rule file: `stacks/monitoring/prometheus/rules/backups.rules.yaml`
  - Runbook source: `stacks/monitoring/runbooks/ResticBackupStaleHard.md`

## Placeholders / Endpoints
- `STACKS_DIR=<STACKS_DIR>` (path to this repo; set to repo root)
- `PROMETHEUS_URL=<PROMETHEUS_URL>` (get from `stacks/monitoring/compose.yaml` service `prometheus` or stack docs)
- `NODE_EXPORTER_URL=<NODE_EXPORTER_URL>` (get from `stacks/monitoring/compose.yaml` service `node-exporter`)
- `BACKUP_TEXTFILE_DIR=<BACKUP_TEXTFILE_DIR>` (only if your textfile collector dir is non-default)
- `RESTIC_TIMER=<RESTIC_TIMER>` (systemd timer name; identify via `systemctl list-timers --all | rg -n "restic"`)
- `RESTIC_SERVICE=<RESTIC_SERVICE>` (systemd service name; identify via `systemctl list-units --type=service | rg -n "restic"`)
- `<BACKUPS_MOUNTPOINT>` (mountpoint defined in backups config)
- `<BACKUP_DEVICE>` (block device from `lsblk -f`)

---

## Quick confirmation (30–60s)
> Goal: confirm the metric is stale (not missing) and the stack is up.

### 1) PromQL checks (source of truth)
```bash
PROMETHEUS_URL=<PROMETHEUS_URL>
curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=(time() - restic_last_success_timestamp) > 48 * 60 * 60'
```
**Success criteria:**
- Alerting: query returns `1`.
- Healthy: query returns empty or `0`.

```bash
PROMETHEUS_URL=<PROMETHEUS_URL>
curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=restic_last_success_timestamp'
```
**Success criteria:**
- A recent timestamp is present.

### 2) Stack health
```bash
cd "${STACKS_DIR}"
make ps stack=monitoring
make logs stack=monitoring
```
**Success criteria:**
- Prometheus and node-exporter are `running/healthy`.
- No repeated scrape errors for node-exporter in recent logs.

---

## What metric triggers this alert
From `stacks/monitoring/prometheus/rules/backups.rules.yaml`:
```promql
(time() - restic_last_success_timestamp) > 48 * 60 * 60
```
Labels:
- `alertname`: `ResticBackupStaleHard`
- `severity`: `critical`
- `service`: `restic`
- `component`: `backup`
- `scope`: `infra`

### Variant (Nextcloud)
```promql
(time() - nextcloud_backup_last_success_timestamp) > 48 * 60 * 60
```
Labels:
- `alertname`: `NextcloudBackupStaleHard`
- `severity`: `critical`
- `service`: `nextcloud`
- `component`: `backup`
- `scope`: `infra`

---

## Textfile collector (metric source)
- Default typical path: `/var/lib/node_exporter/textfile_collector` (may vary by distro/installation).
- If your setup uses a different path, identify it in your node-exporter configuration or stack documentation and replace the placeholder accordingly.

---

## Diagnosis (5–15 min)

### 1) Confirm metric presence at node-exporter
```bash
NODE_EXPORTER_URL=<NODE_EXPORTER_URL>
curl -fsS "${NODE_EXPORTER_URL}/metrics" | rg -n '^restic_last_success_timestamp'
```
**Success criteria:**
- Metric line exists; value should be recent when healthy.

### 2) Confirm backups mount is available
```bash
findmnt <BACKUPS_MOUNTPOINT> || true
df -hT <BACKUPS_MOUNTPOINT> || true
```
**Success criteria:**
- Mountpoint is present and has free space.

### 3) Check scheduler

#### Cron
```bash
# /etc/cron* is a default typical location; may vary by distro/installation.
rg -n "restic" /etc/cron* 2>/dev/null || true
```
**Success criteria:**
- A scheduled job exists for restic backups.

#### systemd
```bash
# systemd timers (default on many distros)
systemctl list-timers --all | rg -n "restic" || true
systemctl status <RESTIC_TIMER> <RESTIC_SERVICE> --no-pager || true
sudo journalctl -u <RESTIC_SERVICE> -S "72 hours ago" --no-pager | tail -n 200
```
**Success criteria:**
- The timer is active and the last run completed without repeated errors.

### 4) Check backup logs for failure
```bash
sudo journalctl -S "72 hours ago" --no-pager | rg -n "restic|backup" | tail -n 200
```
**Success criteria:**
- Logs show successful runs or clear, actionable errors.

### 5) Validate repository health
```bash
restic snapshots
restic check
```
**Success criteria:**
- Commands succeed without repository errors.

---

## Likely causes (ordered)
1) Backup job did not run (scheduler disabled, service failed early).
2) Backup ran but failed (auth, repo lock, permissions).
3) Backup destination is missing or full.
4) Textfile collector not updating metrics.

---

## Mitigation / Remediation

### Plan A — Minimal impact
1) **Action:** Run the repo script manually to capture the real failure.
   ```bash
   cd "${STACKS_DIR}"
   ops/backups/restic-backup.sh
   ```
   **Success criteria:**
   - Script completes successfully and updates metrics.

2) **Action:** Re-check the PromQL condition.
   ```bash
   PROMETHEUS_URL=<PROMETHEUS_URL>
   curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
     --data-urlencode 'query=(time() - restic_last_success_timestamp) > 48 * 60 * 60'
   ```
   **Success criteria:**
   - Query returns empty or `0`.

### Plan B — Fix scheduler/metrics
1) **Action:** Ensure the textfile collector output is updating.
   ```bash
   # Default typical path; may vary by distro/installation.
   ls -la /var/lib/node_exporter/textfile_collector | rg -n "restic" || true
   ```
   **Success criteria:**
   - A `restic.prom` (or similar) file is present and updated recently.

2) **Action:** If using a non-default collector dir, check it directly.
   ```bash
   BACKUP_TEXTFILE_DIR=<BACKUP_TEXTFILE_DIR>
   ls -la "${BACKUP_TEXTFILE_DIR}" | rg -n "restic" || true
   ```
   **Success criteria:**
   - The metrics file exists and updates after a run.

### Plan C — Restore mount or disk health
1) **Action:** Fix mount or free space issues on `<BACKUPS_MOUNTPOINT>`.
   ```bash
   df -hT <BACKUPS_MOUNTPOINT>
   ```
   **Success criteria:**
   - Sufficient free space and healthy mount.

---

## Final verification
- [ ] `restic_last_success_timestamp` is recent.
- [ ] `(time() - restic_last_success_timestamp) > 48 * 60 * 60` is false.
- [ ] Alert resolves in Alertmanager.
- [ ] No repeated errors in backup logs.

---

## Post-mortem / Prevention
- Fail fast if `<BACKUPS_MOUNTPOINT>` is not mounted.
- Add explicit logging for start/end status and exit code.
- Review retention to avoid disk growth surprises.

---

## Appendix / Escape hatch
> Use only if `make` is not available or you need container-level details.

```bash
# Container status
cd "${STACKS_DIR}"
docker compose -f stacks/monitoring/compose.yaml ps

# Logs
cd "${STACKS_DIR}"
docker compose -f stacks/monitoring/compose.yaml logs --tail=200
```
