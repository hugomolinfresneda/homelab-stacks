# Prometheus Rules Catalog

## Rulefile layout

Rules are split by domain to keep ownership and reviews sane:

- `prometheus/rules/infra.rules.yml`
  - Host storage signals (`BackupDiskNotMounted`, disk space low), Tier-0 exporter health, etc.

- `prometheus/rules/containers.rules.yml`
  - Container restart-loop detection (tiered: infra vs service).

- `prometheus/rules/endpoints.rules.yml`
  - Blackbox probes against public FQDN endpoints ("outside-ish" checks).

- `prometheus/rules/backups.rules.yml`
  - Backup freshness and hard RPO breaches (Restic baseline).
  - Metric absence checks to detect instrumentation failures.

- `prometheus/rules/cloudflared.rules.yml`
  - Cloudflared exporter health and tunnel connectivity (warning by policy).

- `prometheus/rules/nextcloud.rules.yml`
  - Nextcloud public endpoint health and dependency exporter signals (warning by policy).

- `prometheus/rules/couchdb.rules.yml`
  - CouchDB exporter + endpoint health and error-rate signals (warning by policy).

- `prometheus/rules/adguard.rules.yml`
  - AdGuard exporter + service-level performance/protection signals (warning by policy).

## Annotations: incident links

The stack supports optional incident links via annotations:

- `runbook_url` — points to the operational runbook for this alert.
- `dashboard_url` — points to a Grafana dashboard relevant to this incident.

Recommendation:
- Keep `runbook_url` in the public repo only if it can remain stable and non-personal.
- Keep `dashboard_url` in the runtime overlay (Grafana URLs are environment-specific).

## Required labels

All alerts should include, at minimum:
- `severity`, `service`, `component`, `scope`

This is not bureaucracy. The routing, grouping, and Telegram templates depend on these fields to produce consistent notifications.

## Adding a new alert (checklist)

1. Pick the **primary symptom** alert first (the one you want to notify on).
2. Decide severity:
   - critical → infra failure (notify always)
   - warning → service/lab signal (muted at night)
3. Apply the label standard:
   - `severity`, `service`, `component`, `scope`
4. Add `runbook_url` if it is Tier-0 / critical and the link is stable.
5. Add `dashboard_url` in runtime if it is useful for first-click triage.
6. Ensure the alert is "inhibit-friendly" (use stable labels such as `service` / `instance`).

## Notes on probe strategy (Blackbox)

Blackbox probes are intentionally "outside-ish":
- Probe public FQDN endpoints from within the Docker network.
- Avoid targets gated behind MFA/Zero Trust flows (not automatable by design).
