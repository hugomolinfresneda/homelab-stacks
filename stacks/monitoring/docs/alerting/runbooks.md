# Runbooks

## Convention

Runbooks live under:

- `stacks/monitoring/runbooks/`

Naming rule:

- `<Alertname>.md` (must match the Prometheus `alert:` name)

## Minimum runbook structure

Recommended sections:

- Summary
- Impact
- Preconditions / dependencies
- Diagnosis
- Mitigation / remediation
- Verification
- Follow-ups / prevention

## Linking runbooks to alerts

Use the `runbook_url` annotation on the Prometheus alert rule:

- `runbook_url: "<stable URL>"`

Portability note:
- If you do not have a stable URL that is safe to publish in the public repo, keep `runbook_url` empty in public and override rules in runtime.
- Alternatively, publish runbooks via a docs site (GitHub Pages or an internal static site) and point `runbook_url` there from runtime.

## Dashboards

Similarly, use `dashboard_url` for first-click triage.
This is typically runtime-owned because Grafana URLs are environment-specific.
