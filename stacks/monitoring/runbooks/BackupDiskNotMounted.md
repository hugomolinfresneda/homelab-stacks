# BackupDiskNotMounted Runbook

**Alert:** `BackupDiskNotMounted`
**Severity:** `critical`
**Service:** `backup`
**Component:** `host`
**Scope:** `infra`
**Signal:** `absent(node_filesystem_size_bytes{mountpoint="/mnt/backups", fstype="ext4"})`

---

## Purpose

Detect when the backup filesystem mountpoint (`/mnt/backups`) is **not mounted** or is **not visible** via node-exporter filesystem metrics. This is a hard failure mode: backups may fail, or worse, write to the wrong disk.

## Impact

- Backups may stop running, fail mid-run, or silently write to the root filesystem.
- RPO guarantees are no longer meaningful.
- Risk of disk exhaustion on `/` if jobs write to an unmounted directory.

## Preconditions

- Host uses `ext4` for the backups filesystem.
- Expected mountpoint: `/mnt/backups`.
- Prometheus scrapes node-exporter for `node_filesystem_*` metrics.

---

## Triage (2-3 minutes)

### 1) Confirm node-exporter is healthy (avoid chasing ghosts)

On the Prometheus Targets page, confirm the `node` job is **UP**.

From the host (or wherever node-exporter is reachable):

```bash
curl -fsS http://localhost:9100/metrics >/dev/null && echo "node-exporter OK"
```

If node-exporter is down, handle **`NodeExporterDown`** first (this alert becomes unreliable without it).

### 2) Confirm the mount is missing (real-world check)

```bash
findmnt /mnt/backups || true
mount | grep -E ' /mnt/backups ' || true
df -hT /mnt/backups || true
```

Expected: `/mnt/backups` appears as a mounted filesystem (`ext4`).

### 3) Confirm the metric is absent (signal check)

```bash
curl -fsS http://localhost:9100/metrics | grep -E 'node_filesystem_size_bytes.*mountpoint="/mnt/backups"' | head -n 3 || echo "metric absent"
```

---

## Diagnosis

### A) The disk is missing / disconnected

Check block devices and filesystem IDs:

```bash
lsblk -f
blkid
```

Check kernel logs for disconnects, I/O errors, or filesystem issues:

```bash
dmesg -T | tail -n 200
```

### B) The mount failed (fstab / systemd / permissions)

Inspect the fstab entry (UUID recommended):

```bash
grep -nE '(/mnt/backups|mnt/backups)' /etc/fstab
```

Attempt a clean mount and capture errors:

```bash
sudo mount /mnt/backups
# or, to test all entries:
sudo mount -a
```

Check journal for mount failures:

```bash
sudo journalctl -b --no-pager | grep -iE 'mnt/backups|mount|ext4|fsck|sdb' | tail -n 200
```

### C) The mount exists, but node-exporter cannot "see" it (less common)

If `findmnt` shows mounted but the metric is still absent:

- Confirm node-exporter has not been started with filesystem exclude flags.
- Confirm mountpoint path matches exactly (`/mnt/backups`, not `/mnt/backup` or a bind mount elsewhere).

Quick grep for node-exporter flags (adapt as needed):

```bash
ps aux | grep -E '[n]ode_exporter'
```

---

## Remediation

### 1) Mount the filesystem

If the disk is present and healthy:

```bash
sudo mount /mnt/backups
```

### 2) Fix fstab issues (persistent fix)

- Prefer `UUID=` entries to avoid device renames (`/dev/sdb1` → `/dev/sdc1`).
- Ensure mountpoint exists:

```bash
sudo mkdir -p /mnt/backups
```

After editing `/etc/fstab`, validate:

```bash
sudo mount -a
findmnt /mnt/backups
```

### 3) Filesystem repair (only when needed)

If `dmesg`/journal indicates filesystem corruption:

> **Caution:** Run `fsck` only when the filesystem is **unmounted**.

```bash
sudo umount /mnt/backups
sudo fsck -f /dev/<device>
sudo mount /mnt/backups
```

### 4) Prevent "writing to /" by mistake (operational safety)

If your backup jobs can run while `/mnt/backups` is missing, consider adding a hard check in scripts:

```bash
findmnt -rno TARGET /mnt/backups >/dev/null || exit 1
```

---

## Verification

1) Mount is present:

```bash
findmnt /mnt/backups
df -hT /mnt/backups
```

2) node-exporter metric exists again:

```bash
curl -fsS http://localhost:9100/metrics | grep -E 'node_filesystem_size_bytes.*mountpoint="/mnt/backups"' | head -n 3
```

3) Alert clears in Alertmanager and (if configured) a **RESOLVED** notification is received.

---

## Prevention / Hardening

- Use `UUID=` in `/etc/fstab`.
- Consider `x-systemd.automount` to make mounts more resilient on boot.
- Ensure backup jobs fail hard if the mount is missing (avoid filling `/`).
- Add a periodic “storage sanity check” (optional) that validates:
  - mount present
  - free space > threshold
  - write test to a temp file (if safe)

---

## Ownership

- **Primary:** homelab operator
- **Escalation:** none (local infra)
