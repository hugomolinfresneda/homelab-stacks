# BlackboxExporterDown — Blackbox exporter not scraped

## Summary
Prometheus cannot scrape the blackbox exporter (`job="blackbox"`), so probe-based alerts become unreliable.

## Severity / Urgency
- `severity`: `critical`
- Urgency:
  - **critical**: external checks are blind; endpoint alerts may be suppressed or stale.

## Impact
- Synthetic availability/latency monitoring is unavailable.
- Any alert that depends on `probe_*` metrics may stop firing.

## Context / Scope
- `stack`: `monitoring`
- `service`: `blackbox`
- `job`: `blackbox` (exporter scrape job)
- `instance/target`: `<BLACKBOX_INSTANCE>` (from Alertmanager labels or Prometheus target label)
- Links:
  - Prometheus rule file: `stacks/monitoring/prometheus/rules/infra.rules.yaml`
  - Runbook source: `stacks/monitoring/runbooks/BlackboxExporterDown.md`

## Placeholders / Endpoints
- `STACKS_DIR=<STACKS_DIR>` (path to this repo; set to repo root)
- `PROMETHEUS_URL=<PROMETHEUS_URL>` (get from `stacks/monitoring/compose.yaml` service `prometheus` or stack docs)
- `BLACKBOX_URL=<BLACKBOX_URL>` (get from `stacks/monitoring/compose.yaml` service `blackbox` or stack docs)
- `BB_TARGETS_MAP=<BB_TARGETS_MAP>` (runtime targets mapping; see `stacks/monitoring/README.md` "Makefile wrappers")

---

## Quick confirmation (30–60s)
> Goal: confirm it is the exporter target that is down.

### 1) PromQL checks (source of truth)
```bash
PROMETHEUS_URL=<PROMETHEUS_URL>
curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=up{job="blackbox"} == 0'
```
**Success criteria:**
- Alerting: vector returns `1` for the blackbox target.
- Healthy: vector empty or `up == 1`.

```bash
PROMETHEUS_URL=<PROMETHEUS_URL>
curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
  --data-urlencode 'query=up{job="blackbox"}'
```
**Success criteria:**
- Healthy: `up` is `1` for the blackbox target.

### 2) Stack health
```bash
cd "${STACKS_DIR}"
make ps stack=monitoring
make logs stack=monitoring
```
**Success criteria:**
- `blackbox` and `prometheus` are `running/healthy`.
- Logs do not show repeated scrape failures or crash loops.

---

## What metric triggers this alert
From `stacks/monitoring/prometheus/rules/infra.rules.yaml`:
```promql
up{job="blackbox"} == 0
```
Labels:
- `alertname`: `BlackboxExporterDown`
- `severity`: `critical`
- `service`: `blackbox`
- `component`: `exporter`
- `scope`: `infra`

Related jobs (not part of this alert): `blackbox-http`, `blackbox-icmp`, `blackbox-dns`.

---

## Diagnosis (5–15 min)

### 1) Confirm exporter endpoint is reachable
```bash
BLACKBOX_URL=<BLACKBOX_URL>
curl -fsS "${BLACKBOX_URL}/metrics" | head -n 5
```
**Success criteria:**
- A small set of metrics is returned (non-empty output).

### 2) Validate runtime targets helpers (if needed)
```bash
cd "${STACKS_DIR}"
make bb-ls JOB=blackbox-http BB_TARGETS_MAP="${BB_TARGETS_MAP}"
```
**Success criteria:**
- Target list prints successfully for the selected job.

---

## Likely causes (ordered)
1) Blackbox container is down or crash-looping.
2) Prometheus cannot resolve or reach the blackbox service.
3) Misconfigured scrape target (job name/target mismatch).

---

## Mitigation / Remediation

### Plan A — Minimal impact
1) **Action:** Reconcile the monitoring stack (ensure exporter is up).
   ```bash
   cd "${STACKS_DIR}"
   make up stack=monitoring
   ```
   **Success criteria:**
   - `make ps stack=monitoring` shows `blackbox` running.

2) **Action:** Watch logs briefly for errors.
   ```bash
   cd "${STACKS_DIR}"
   make logs stack=monitoring follow=true
   ```
   **Success criteria:**
   - No repeated crash loop or fatal config errors.

3) **Action:** Re-check `up{job="blackbox"}`.
   ```bash
   PROMETHEUS_URL=<PROMETHEUS_URL>
   curl -fsS "${PROMETHEUS_URL}/api/v1/query" \
     --data-urlencode 'query=up{job="blackbox"}'
   ```
   **Success criteria:**
   - `up` becomes `1` for the blackbox target.

### Plan B — Fix runtime target issues
1) **Action:** Review targets and reload Prometheus if changed.
   ```bash
   cd "${STACKS_DIR}"
   make bb-ls JOB=blackbox-http BB_TARGETS_MAP="${BB_TARGETS_MAP}"
   make reload-prom
   ```
   **Success criteria:**
   - Targets list is correct, and `up{job="blackbox"}` returns `1`.

### Plan C — Escalate
- If the exporter is up but scrape still fails, collect logs and config, then escalate to stack config review.

---

## Final verification
- [ ] `up{job="blackbox"}` is `1`.
- [ ] Prometheus target `blackbox` shows **UP**.
- [ ] Probe metrics (`probe_success`, `probe_duration_seconds`) update again.
- [ ] Alert resolves in Alertmanager.

---

## Post-mortem / Prevention
- Keep blackbox config changes small and validated.
- Ensure runtime targets are managed via helpers (`bb-ls`/`bb-add`/`bb-rm`).
- Add a lightweight self-probe only if it does not create alert loops.

---

## Appendix / Escape hatch
> Use only if `make` is not available or you need container-level details.

```bash
# Container status
cd "${STACKS_DIR}"
docker compose -f stacks/monitoring/compose.yaml ps blackbox

# Logs
cd "${STACKS_DIR}"
docker compose -f stacks/monitoring/compose.yaml logs --tail=200 blackbox

# Prometheus network reachability
cd "${STACKS_DIR}"
docker compose -f stacks/monitoring/compose.yaml \
  exec -T prometheus sh -lc 'getent hosts blackbox && wget -qO- http://blackbox:9115/metrics | head -n 5'
```
