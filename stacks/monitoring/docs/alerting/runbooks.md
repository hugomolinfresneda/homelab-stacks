# Runbooks

## What is a runbook in this repo?
A runbook is the **operational response** for a specific alert: what it means, how to confirm it quickly, and how to recover safely. This file is the **index of runbooks** and the source of truth for alert-to-runbook mapping.

---

## Where runbooks live
- Runbooks: `stacks/monitoring/runbooks/*.md`
- Alert rules: `stacks/monitoring/prometheus/rules/*.yaml`
- Alerting docs: `stacks/monitoring/docs/alerting/*.md`

---

## Minimum content (short contract)
A runbook should include, at minimum:
- Summary / purpose
- Impact
- Quick confirmation (fast checks)
- Diagnosis
- Mitigation / remediation steps
- Verification

(Use the existing runbook files as the format reference.)

---

## Linking runbooks to alerts
- When a rule includes `runbook_url`, it should point to the runbook for that alert.
- The table below is the **canonical index** and must stay in sync with the rules.

---

## Alert → Runbook index
| alertname | severity | service (or component) | runbook_url | owner |
|---|---|---|---|---|
| `BlackboxExporterDown` | `critical` | `blackbox` | `stacks/monitoring/runbooks/BlackboxExporterDown.md` | `TBD` |
| `ResticBackupStaleHard` | `critical` | `restic` | `stacks/monitoring/runbooks/ResticBackupStaleHard.md` | `TBD` |
| `BackupDiskNotMounted` | `critical` | `backup` | `stacks/monitoring/runbooks/BackupDiskNotMounted.md` | `TBD` |

---

## Maintenance
- If an alert changes meaning, update its runbook in the same PR.
- If a new alert is added, add it to the index here.
- If a runbook is missing, add a TODO in the table and document why.
