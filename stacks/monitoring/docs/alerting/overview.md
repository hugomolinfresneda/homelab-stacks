# Alerting Overview

## Purpose
Provide a predictable, low-noise alerting flow for the monitoring stack. This doc explains how alerts move through the system, which files are the source of truth, and the minimum conventions you must follow. Details about rules, receivers, and runbooks live in their dedicated docs.

## End-to-end flow
1) **Prometheus rules** evaluate signals and raise alerts. See `prometheus-rules.md`.
2) **Alertmanager** routes and groups alerts based on labels. Config lives in `stacks/monitoring/alertmanager/alertmanager.yml`.
3) **Receiver integration** delivers notifications (Telegram). See `alertmanager-telegram.md`.
4) **Runbooks** provide the operational response. See `runbooks.md`.

Note: Alert/Silence links in Telegram require `--web.external-url` to be set in a runtime override; see `alertmanager-telegram.md`.

## Map of files
- Prometheus rules: `stacks/monitoring/prometheus/rules/*.yml`
- Prometheus config: `stacks/monitoring/prometheus/prometheus.yml` (demo: `stacks/monitoring/prometheus/prometheus.demo.yml`)
- Alertmanager config: `stacks/monitoring/alertmanager/alertmanager.yml`
- Alertmanager templates: `stacks/monitoring/alertmanager/templates/telegram.tmpl`
- Runbooks: `stacks/monitoring/runbooks/*.md`
- Alerting docs: `stacks/monitoring/docs/alerting/*.md`

Runtime/private: `${RUNTIME_ROOT}/stacks/monitoring/...` for secrets and environment-specific overrides.

## Severity model
- `critical`
  - 24/7 notification (oncall).
  - Used for infra-tier incidents and hard RPO breaches.
- `warning`
  - Notifies during daytime; muted during quiet hours.
  - Used for service health signals and lab degradation.

## Labels (summary)
Minimum required labels:
- `severity`
- `service` (sometimes derived in the expression, e.g. via `label_replace`)

Strongly recommended labels:
- `component`
- `scope`

These improve context and silence filters in Telegram, but are not strictly required by the contract. For the full contract and examples, see `prometheus-rules.md`.

## Routing & inhibition (summary)
Alertmanager routes primarily by `severity`, and uses `service` (plus other labels) for grouping and inhibition. The source of truth is `stacks/monitoring/alertmanager/alertmanager.yml`.

## Runbooks and `runbook_url`
Runbooks live under `stacks/monitoring/runbooks/`. When available, rules include a `runbook_url` annotation that should point to the runbook for that alert. Conventions and the index live in `runbooks.md`.

## Testing minimum
Repository-level validation (safe, read-only):
```bash
cd "${STACKS_DIR}"
make validate
make check-prom
```

Receiver tests and cleanup (Telegram) are documented in `alertmanager-telegram.md`.

## Related docs
- `prometheus-rules.md` — alert rule contract, labels, and `runbook_url`
- `alertmanager-telegram.md` — Telegram receiver setup, tests, and silences
- `runbooks.md` — runbook index and conventions

## Out-of-band monitoring
Some failures (e.g., “Prometheus is dead”) are not observable from inside Prometheus. Those are covered externally via Uptime Kuma health checks.
