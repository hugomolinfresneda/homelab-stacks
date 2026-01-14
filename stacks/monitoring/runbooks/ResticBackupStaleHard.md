# ResticBackupStaleHard Runbook

**Alert:** `ResticBackupStaleHard`
**Severity:** `critical`
**Service:** `restic`
**Component:** `backup`
**Scope:** `infra`
**Policy:** RPO hard limit = **48 hours**
**Signal:** `time() - restic_last_success_timestamp > 48h`

> This runbook also applies to `NextcloudBackupStaleHard`. See **Scope** below.

---

## Purpose

Detect when the last successful backup is older than the defined RPO hard limit (48h). This is a service continuity risk: if a failure occurs now, recent data may be unrecoverable.

## Impact

- RPO is breached: you may lose more than 48h of data if recovery is required.
- Backup repository may be out of date, incomplete, or unavailable.
- Secondary risk: if backups are still running but not succeeding, logs and temporary data may accumulate.

## Scope

### Primary
- `ResticBackupStaleHard` (general system backups via Restic).

### Also covered
- `NextcloudBackupStaleHard` (application-level Nextcloud backups).

The workflow is the same: identify why the job did not succeed and restore successful runs. Metrics names differ; see **Verification**.

---

## Triage (2-5 minutes)

### 1) Confirm this is not a monitoring/metrics issue

If you also have `ResticBackupNeverSucceeded` firing or the metric is missing entirely, handle that first.

Check current metric value (host / node-exporter):

```bash
curl -fsS http://localhost:9100/metrics | grep -E '^restic_last_success_timestamp' || echo "metric missing"
```

Optional: check companion metrics if present:

```bash
curl -fsS http://localhost:9100/metrics | grep -E '^(restic_last_status|restic_last_duration_seconds|restic_last_success_timestamp)' | head -n 50
```

### 2) Confirm storage prerequisites (fast sanity checks)

```bash
findmnt /mnt/backups || true
df -hT /mnt/backups || true
```

If `/mnt/backups` is not mounted, address **BackupDiskNotMounted** first.

### 3) Confirm last successful run time

If you have the timestamp metric, convert it:

```bash
TS="$(curl -fsS http://localhost:9100/metrics | awk '/^restic_last_success_timestamp/ {print $2; exit}')"
date -d "@${TS}" || true
```

---

## Diagnosis

### A) The backup job did not run (scheduler problem)

Identify how the backup is scheduled.

#### Cron
```bash
sudo grep -R "restic" /etc/cron* 2>/dev/null || true
sudo journalctl -u cron -S "72 hours ago" --no-pager | tail -n 200
```

#### systemd timer (recommended)
```bash
systemctl list-timers --all | grep -i restic || true
sudo journalctl -u restic -S "72 hours ago" --no-pager | tail -n 200
```

Common causes:
- timer disabled
- service failing early
- environment/secrets missing (paths changed, permissions)

### B) The job ran but failed (execution error)

Locate the backup logs for the last run (adapt paths to your setup). Typical checks:

```bash
# If you log via journald
sudo journalctl -S "72 hours ago" --no-pager | grep -iE 'restic|backup' | tail -n 300
```

If you use a dedicated script, run it with verbose output (dry-run if supported).

### C) Storage/destination issues

Check for:
- disk full / low space
- repository not reachable
- repository locked
- filesystem errors

```bash
df -hT /mnt/backups
dmesg -T | tail -n 200
```

If you can safely run restic commands, validate repository health:

```bash
# Adjust RESTIC_REPOSITORY / credentials in your environment
restic snapshots
restic check
```

### D) Credentials / secrets / permissions

Typical symptoms:
- repo password missing
- backend credentials invalid
- permissions changed on backup destination

Check secret files and environment used by your backup runner. Ensure the job can read them.

---

## Remediation

### 1) Run the backup manually (capture the real failure)

Run the same command the scheduler uses (preferred), e.g.:

```bash
sudo /ops/backups/restic-backup.sh
```

If the job is systemd-managed:

```bash
sudo systemctl start homelab-restic-backup
sudo journalctl -u homelab-restic-backup -n 200 --no-pager
```

### 2) Fix root cause

Examples:
- Re-mount backup disk (`BackupDiskNotMounted`)
- Free space on `/mnt/backups`
- Restore repository credentials
- Clear stale locks (only if you understand why they exist)

### 3) Ensure metrics are updated (textfile collector)

If your metrics come from node-exporter textfile collector, verify the `.prom` file updates:

```bash
sudo ls -la /var/lib/node_exporter/textfile_collector/ | grep -i restic || true
sudo sed -n '1,120p' /var/lib/node_exporter/textfile_collector/restic.prom 2>/dev/null || true
```

---

## Verification

### Restic (primary)
- `restic_last_success_timestamp` updated to a recent time:
```bash
curl -fsS http://localhost:9100/metrics | grep -E '^restic_last_success_timestamp'
```

- Optional sanity:
```bash
curl -fsS http://localhost:9100/metrics | grep -E '^restic_last_status'
```

### Nextcloud (also covered)
- `nextcloud_backup_last_success_timestamp` updated:
```bash
curl -fsS http://localhost:9100/metrics | grep -E '^nextcloud_backup_last_success_timestamp'
```

### Alerting
- Alert clears in Alertmanager.
- A **RESOLVED** notification is received (if enabled).

---

## Prevention / Hardening

- Keep backup jobs fail-fast if `/mnt/backups` is not mounted.
- Add explicit logging for start/end status and exit code.
- Keep repository credentials and configuration in runtime-only storage.
- Consider a "backup smoke test" on a schedule (e.g., `restic snapshots`).
- Review retention policies to avoid disk growth surprises.

---

## Ownership

- **Primary:** homelab operator
- **Escalation:** none (local infra)
