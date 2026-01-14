# Alerting Overview

## Purpose

Provide a predictable and low-noise alerting layer for a single-node homelab:
- **Critical** = infrastructure failure that must page.
- **Warning** = service degradation / lab signals that should not wake you up.
- Prefer **one "symptom" alert per service**, with secondary "diagnostic" alerts inhibited by that symptom.

## Severity model

- `severity="critical"`
  - Must notify 24/7.
  - Reserved for infra-tier incidents: exporters down, storage unavailable, backups breaching hard RPO, etc.

- `severity="warning"`
  - Notifies during daytime, muted during quiet hours (see Alertmanager config).
  - Used for service health signals (Nextcloud endpoint down, Cloudflared tunnel down, CouchDB endpoint down, etc.).

## Label standard

All alerts are expected to carry these labels:

- `severity`: `critical | warning`
- `service`: a stable service identifier (e.g., `monitoring`, `backup`, `restic`, `nextcloud`, `cloudflared`, `couchdb`, `adguard`)
- `component`: what failed (e.g., `exporter`, `endpoint`, `host`, `container`, `backup`, `db`, `redis`, `tunnel`)
- `scope`: `infra | service | lab`

Recommended optional labels (used for better Telegram rendering and filtering):
- `target` (Blackbox endpoint target)
- `via` (probe path, e.g., `blackbox-exporter:9115`)
- `mountpoint`, `device` (filesystem-related alerts)
- `container` (container-related alerts)

## Routing
Alertmanager routes based primarily on `severity`:
- `critical` → `oncall` receiver (Telegram)
- `warning` → `notify` receiver (Telegram), but muted during quiet hours

Grouping is designed to reduce spam while keeping incidents actionable.

## Inhibition (signal hygiene)

The inhibition policy follows the "symptom > diagnostics" model:

- **Critical inhibits warning** for the same incident family (same `alertname` / `instance`, depending on the rule).
- **Service symptom alerts** (e.g., endpoint down) inhibit secondary warnings for that service (e.g., redis down).

This keeps notifications focused on the top-level failure, while still preserving diagnostic alerts in Alertmanager/Grafana for triage.

## Out-of-band monitoring

Some failures are not self-detectable from inside Prometheus (e.g., "Prometheus is dead").
Those are covered externally via Uptime Kuma health checks (internal monitor).
