# BlackboxExporterDown Runbook

**Alert:** `BlackboxExporterDown`
**Severity:** `critical`
**Service:** `blackbox`
**Component:** `exporter`
**Scope:** `infra`
**Signal:** `up{job="blackbox"} == 0` (for 5m)

---

## Purpose

Detect when Prometheus cannot scrape the Blackbox Exporter. This breaks synthetic endpoint monitoring and makes any alert based on `probe_*` metrics unreliable.

## Impact

- Synthetic availability/latency monitoring is unavailable (false negatives likely).
- Endpoint-based alerts (e.g., `*EndpointDown`, `*EndpointSlow`) may stop firing even if services are down.
- Troubleshooting becomes harder because outside-in signal is missing.

---

## Triage (2-3 minutes)

### 1) Confirm this is a scrape/availability problem (not just a noisy target)

In Prometheus Targets, check the `blackbox` job is **DOWN** and capture the error message (timeout, connection refused, DNS, etc.).

### 2) Confirm the exporter is reachable from the Prometheus network

From the Prometheus container (preferred, same network path as scraping):

```bash
docker exec -t mon-prometheus sh -lc 'getent hosts blackbox && wget -qO- http://blackbox:9115/metrics | head -n 5'
```

If this succeeds, the issue is likely Prometheus configuration or target label mismatch rather than the exporter itself.

### 3) Check container state and recent logs

```bash
docker ps --filter name=blackbox
docker inspect mon-blackbox --format '{{.State.Status}} restarting={{.State.Restarting}} restarts={{.RestartCount}}' 2>/dev/null || true
docker logs --tail=200 mon-blackbox 2>/dev/null || true
```

---

## Diagnosis

### A) Container is not running / restart loop

Common causes:
- invalid `blackbox.yml`
- wrong volume mount path/permissions
- image update/regression
- failing DNS inside container

Actions:
- Inspect logs for configuration parsing errors.
- Inspect the mounted config exists inside the container:

```bash
docker exec -t mon-blackbox sh -lc 'ls -la /etc/blackbox_exporter/ && sed -n "1,120p" /etc/blackbox_exporter/blackbox.yml 2>/dev/null || true'
```

*(Adjust path if your container uses a different config location.)*

### B) Networking / DNS issues inside Docker network

If Prometheus cannot resolve `blackbox` or connect:
- Confirm both containers are on the same Docker network (e.g., `mon-net`).
- Check name resolution from Prometheus:

```bash
docker exec -t mon-prometheus sh -lc 'getent hosts blackbox || (echo "DNS failed" && exit 1)'
```

If DNS fails intermittently, check Docker DNS (`127.0.0.11`) and network health.

### C) Exporter is up but Prometheus target is misconfigured

If you can curl `/metrics` but Prometheus shows DOWN:
- Validate Prometheus `scrape_config` for blackbox.
- Confirm port/host match the running container.
- Confirm any relabeling does not drop the target.

Fast check of Prometheus current config (inside container, if available):

```bash
docker exec -t mon-prometheus sh -lc 'wget -qO- http://localhost:9090/api/v1/status/config | head -n 40'
```

### D) Resource exhaustion / host-level issues

If multiple services start failing:
- Check host CPU/memory pressure.
- Check Docker daemon health.

```bash
docker stats --no-stream | head
```

---

## Remediation

### 1) Restart blackbox exporter

```bash
docker restart mon-blackbox
```

### 2) Fix configuration errors

If logs indicate config parsing issues:
- Revert last change to `blackbox.yml`.
- Validate YAML and module definitions.
- Restart the container and re-test `/metrics`.

### 3) Fix networking issues

- Ensure `blackbox` and `prometheus` share the same network.
- If you changed service names, align scrape target names accordingly.
- If Docker DNS is unstable, restart the Docker network stack (last resort).

---

## Verification

1) Exporter endpoint responds:

```bash
docker exec -t mon-prometheus sh -lc 'wget -qO- http://blackbox:9115/metrics | head -n 5'
```

2) Prometheus target `blackbox` is **UP**.

3) Synthetic probe metrics update again (`probe_success`, `probe_duration_seconds`, etc.).

4) Alert clears in Alertmanager and a **RESOLVED** notification is received (if enabled).

---

## Follow-ups / Hardening

- Keep blackbox config changes small and validated.
- Pin images by digest (already done).
- Consider adding a lightweight “self-probe” (blackbox probing itself) only if it provides signal without creating alert loops.
- Ensure endpoint alerts are designed so that blackbox outages are explicit (this alert) and do not masquerade as endpoint health.

---

## Ownership

- **Primary:** homelab operator
- **Escalation:** none (local infra)
