# BackupDiskNotMounted — Backup disk not mounted

## Summary
Backup mountpoint metrics are absent, so the backup disk is likely not mounted. Backups can fail or write to the wrong filesystem.

## Severity / Urgency
- `severity`: `critical`
- Urgency:
  - **critical**: backups are not reliable until the mount is restored.

## Impact
- Backups may fail or write into the root filesystem.
- RPO is at risk; disk exhaustion on `/` is possible if jobs write to an unmounted path.

## Context / Scope
- `stack`: `monitoring`
- `service`: `backup`
- `job`: `node`
- `instance/target`: `<NODE_INSTANCE>` (from Alertmanager labels or Prometheus target label)
- Links:
  - Prometheus rule file: `stacks/monitoring/prometheus/rules/infra.backups.rules.yml.example`
  - Runbook source: `stacks/monitoring/runbooks/BackupDiskNotMounted.md`

## Placeholders / Endpoints
- `STACKS_DIR=<STACKS_DIR>` (path to this repo; set to repo root)
- `PROMETHEUS_URL=<PROMETHEUS_URL>` (get from `stacks/monitoring/compose.yaml` service `prometheus` or stack docs)
- `NODE_EXPORTER_URL=<NODE_EXPORTER_URL>` (get from `stacks/monitoring/compose.yaml` service `node-exporter`)
- `<BACKUPS_MOUNTPOINT>` (from `/etc/fstab` or systemd mount unit; see below)
- `<BACKUP_DEVICE>` (block device from `lsblk -f`)
- `<MOUNT_UNIT>` (systemd mount unit name if used)

---

## Quick confirmation (30–60s)
> Goal: confirm the alert is real and not just a scrape issue.

### 1) PromQL checks (source of truth)
```bash
# Is the metric absent? (alerting expr)
PROMETHEUS_URL=<PROMETHEUS_URL>
curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=absent(node_filesystem_size_bytes{job="node",mountpoint="<BACKUPS_MOUNTPOINT>",fstype="ext4"})'
```
**Success criteria:**
- Healthy: empty result vector (metric exists).
- Alerting: a non-empty vector (metric absent).

```bash
# Does the mountpoint metric exist?
PROMETHEUS_URL=<PROMETHEUS_URL>
curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=node_filesystem_size_bytes{job="node",mountpoint="<BACKUPS_MOUNTPOINT>",fstype="ext4"}'
```
**Success criteria:**
- Healthy: at least one series returned for the mountpoint.

### 2) Stack health
```bash
cd "${STACKS_DIR}"
make ps stack=monitoring
make logs stack=monitoring
```
**Success criteria:**
- Prometheus and node-exporter are `running/healthy`.
- No persistent scrape errors for node-exporter in recent logs.

---

## What metric triggers this alert
From `stacks/monitoring/prometheus/rules/infra.backups.rules.yml.example`:
```promql
absent(node_filesystem_size_bytes{job="node",mountpoint="<BACKUPS_MOUNTPOINT>",fstype="ext4"})
```
Labels:
- `alertname`: `BackupDiskNotMounted`
- `severity`: `critical`
- `service`: `backup`
- `component`: `host`
- `scope`: `infra`

---

## Expected mountpoint
- `<BACKUPS_MOUNTPOINT>` is the path that must be mounted for backups.

### Where it is defined
- `/etc/fstab` (default typical path; may vary by distro/installation).
- If systemd mounts are used: `<MOUNT_UNIT>` (e.g., check `systemctl status <MOUNT_UNIT>`).

---

## Diagnosis (5–15 min)

### 1) Confirm node-exporter is reachable
```bash
NODE_EXPORTER_URL=<NODE_EXPORTER_URL>
curl -fsS "${NODE_EXPORTER_URL}/metrics" >/dev/null
```
**Success criteria:**
- Exit code 0 and no connection errors.

### 2) Confirm the mount exists on the host
```bash
findmnt <BACKUPS_MOUNTPOINT> || true
mount | rg -n " <BACKUPS_MOUNTPOINT> " || true
df -hT <BACKUPS_MOUNTPOINT> || true
```
**Success criteria:**
- The mountpoint appears and shows a filesystem type (expected `ext4`).

### 3) Check device presence
```bash
lsblk -f
```
**Success criteria:**
- `<BACKUP_DEVICE>` is present and has the expected filesystem.

### 4) Check recent kernel/mount errors
```bash
dmesg -T | tail -n 200
```
**Success criteria:**
- No repeated I/O, disconnect, or fsck errors for the backup device.

---

## Likely causes (ordered)
1) Backup disk is disconnected or not detected by the host.
2) Mount failed (fstab entry, permissions, or systemd mount unit error).
3) Node-exporter scrape path excludes the mountpoint (less common).

---

## Mitigation / Remediation
> Each step includes an expected result; stop when the alert condition clears.

### Plan A — Minimal impact
1) **Action:** Mount the filesystem.
   ```bash
   sudo mount <BACKUPS_MOUNTPOINT>
   ```
   **Success criteria:**
   - `findmnt <BACKUPS_MOUNTPOINT>` shows the mountpoint and filesystem.

2) **Action:** Re-run the PromQL check.
   ```bash
   PROMETHEUS_URL=<PROMETHEUS_URL>
   curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
     --data-urlencode 'query=node_filesystem_size_bytes{job="node",mountpoint="<BACKUPS_MOUNTPOINT>",fstype="ext4"}'
   ```
   **Success criteria:**
   - Series exists; `absent(...)` query is empty.

### Plan B — Fix mount definition
1) **Action:** Validate fstab entry (default path; may vary by distro/installation).
   ```bash
   rg -n "<BACKUPS_MOUNTPOINT>" /etc/fstab
   ```
   **Success criteria:**
   - An entry exists and points to the correct device/UUID.

2) **Action:** Create mountpoint directory if missing.
   ```bash
   sudo mkdir -p <BACKUPS_MOUNTPOINT>
   ```
   **Success criteria:**
   - Directory exists and is accessible.

3) **Action:** Remount and validate.
   ```bash
   sudo mount -a
   findmnt <BACKUPS_MOUNTPOINT>
   ```
   **Success criteria:**
   - Mountpoint is present with the expected filesystem.

### Plan C — Disk repair (only if corruption is indicated)
1) **Action:** Unmount then run fsck.
   ```bash
   sudo umount <BACKUPS_MOUNTPOINT>
   sudo fsck -f /dev/<BACKUP_DEVICE>
   ```
   **Success criteria:**
   - `fsck` completes without fatal errors.

2) **Action:** Re-mount and re-check metrics.
   ```bash
   sudo mount <BACKUPS_MOUNTPOINT>
   ```
   **Success criteria:**
   - Mountpoint visible and PromQL check returns series.

---

## Final verification
- [ ] `absent(node_filesystem_size_bytes{job="node",mountpoint="<BACKUPS_MOUNTPOINT>",fstype="ext4"})` returns empty.
- [ ] `node_filesystem_size_bytes{job="node",mountpoint="<BACKUPS_MOUNTPOINT>",fstype="ext4"}` returns series.
- [ ] Alert resolves in Alertmanager.

---

## Post-mortem / Prevention
- Use UUIDs in `/etc/fstab` to avoid device renames.
- Add a pre-flight check in backup scripts to fail if `<BACKUPS_MOUNTPOINT>` is not mounted.
- Consider automounts (`x-systemd.automount`) if boot order causes missed mounts.

---

## Appendix / Escape hatch
> Use only if `make` is not available.

```bash
# Stack health
cd "${STACKS_DIR}"
docker compose -f stacks/monitoring/compose.yaml ps

# Logs (node-exporter)
docker compose -f stacks/monitoring/compose.yaml logs --tail=200 node-exporter
```
