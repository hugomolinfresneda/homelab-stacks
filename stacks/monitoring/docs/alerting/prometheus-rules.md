# Prometheus rules (contract)

## Purpose
Define the minimal, verifiable contract for alert rules in this repo: where rules live, which labels are required, how severities are used, and how rules connect to runbooks and Alertmanager.

**In scope**
- Rules under `stacks/monitoring/prometheus/rules/`
- Alert labels/annotations used for routing and runbooks
- Validation/testing workflow

**Out of scope**
- Receiver integration details (see `alertmanager-telegram.md`)
- Runbook content (see `runbooks.md`)

---

## Map of files
- Rules: `stacks/monitoring/prometheus/rules/*.yml`
- Prometheus config: `stacks/monitoring/prometheus/prometheus.yml` (demo: `stacks/monitoring/prometheus/prometheus.demo.yml`)
- Runbooks: `stacks/monitoring/runbooks/*.md`
- Alerting docs: `stacks/monitoring/docs/alerting/*.md`

Runtime/private overrides and secrets (placeholders only): `${RUNTIME_ROOT}/stacks/monitoring/...`.

---

## Rule file layout (current)
Rules are split by domain to keep ownership and reviews sane:

- `prometheus/rules/infra.rules.yml`
  - Tier-0 exporter health and root filesystem capacity alerts.
- `prometheus/rules/infra.backups.rules.yml.example`
  - Backup disk mountpoint alerts; copy to `infra.backups.rules.yml` and replace `<BACKUPS_MOUNTPOINT>` for your host.
- `prometheus/rules/containers.rules.yml`
  - Container restart-loop detection (infra + service).
- `prometheus/rules/endpoints.rules.yml`
  - Blackbox probes against public FQDN endpoints.
- `prometheus/rules/backups.rules.yml`
  - Backup freshness and hard RPO breaches (Restic baseline).
- `prometheus/rules/cloudflared.rules.yml`
  - Cloudflared exporter health and tunnel connectivity.
- `prometheus/rules/nextcloud.rules.yml`
  - Nextcloud public endpoint health and dependency signals.
- `prometheus/rules/couchdb.rules.yml`
  - CouchDB exporter + endpoint health and error-rate signals.
- `prometheus/rules/adguard.rules.yml`
  - AdGuard exporter + service-level performance/protection signals.

---

## Label contract
### Minimum required labels
Based on current rules, every alert should have:
- `severity`
- `service`

Note: some alerts derive `service` in the PromQL expression (e.g., `InfraContainerRestartLoop` uses `label_replace`).

### Strongly recommended labels
- `component`
- `scope`

These are used by grouping/templates and improve context/silence filters in Telegram, but are not strictly required by the contract.

Definitions and examples:
- `component`: the failing part or layer (exporter, endpoint, backup, db, tunnel, host, etc.).
- `scope`: the impact domain (infra, service, lab).

---

## Severity model
- `critical`
  - Always notify (oncall).
  - Used for infra-tier incidents and hard RPO breaches.
- `warning`
  - Notifies during daytime; muted during quiet hours.
  - Used for service health signals and lab degradation.

---

## Annotations
Recommended (when applicable):
- `summary` — one short line for the notification.
- `description` — what is wrong and the first thing to check.
- `runbook_url` — runbook link/path for the alert.
- `dashboard_url` — runtime-owned Grafana link (environment-specific).

---

## `runbook_url` convention
Some rules already include `runbook_url` annotations (currently as full GitHub URLs). Going forward, the recommended format is a **repo-relative path** to the runbook:

```yaml
runbook_url: stacks/monitoring/runbooks/<AlertName>.md
```

Not all rules have `runbook_url` yet; this is being extended incrementally.

---

## Example rule snippets (from the repo)
**Example A — exporter down (infra)**
```yaml
- alert: BlackboxExporterDown
  labels:
    severity: critical
    service: blackbox
    component: exporter
    scope: infra
  annotations:
    summary: Blackbox Exporter is down
    runbook_url: https://github.com/hugomolinfresneda/homelab-stacks/blob/main/stacks/monitoring/runbooks/BlackboxExporterDown.md
```

**Example B — backup stale (infra)**
```yaml
- alert: ResticBackupStaleHard
  labels:
    severity: critical
    service: restic
    component: backup
    scope: infra
  annotations:
    summary: Restic backup is stale (>48h)
    runbook_url: https://github.com/hugomolinfresneda/homelab-stacks/blob/main/stacks/monitoring/runbooks/ResticBackupStaleHard.md
```

---

## How to add a rule (minimal process)
1) Pick the primary symptom alert (one per service when possible).
2) Decide `severity` (critical vs warning).
3) Apply minimum labels (`severity`, `service`).
4) Add `summary`/`description`, and `runbook_url` when available.
5) Update `runbooks.md` (index table).
6) Validate and test (see below).

**Success criteria**
- `make validate` and `make check-prom` pass.
- Prometheus loads config without errors.
- Alert routes to the expected receiver in Alertmanager.

---

## Testing / validation (minimum)
```bash
cd "${STACKS_DIR}"
make validate
make check-prom
```

---

## References
- `overview.md`
- `runbooks.md`
- `alertmanager-telegram.md`
