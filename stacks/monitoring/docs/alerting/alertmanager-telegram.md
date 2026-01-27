# Alertmanager → Telegram

## Goals
- Route alerts to Telegram with a consistent, low-noise presentation.
- Support quiet hours for warning-level signals.
- Surface incident links (Runbook / Dashboard / Alert / Silence) in notifications.
- Keep the public repo portable by pushing environment-specific values into runtime.

## Scope
This doc covers **configuration, testing, and cleanup** of the Telegram receiver. It does not define alert rules (see `prometheus-rules.md`).

---

## Where things live (repo vs runtime)
**Repo:**
- Alertmanager config: `stacks/monitoring/alertmanager/alertmanager.yml`
- Telegram template: `stacks/monitoring/alertmanager/templates/telegram.tmpl`

**Runtime:**
- Secrets and environment-specific overrides under `${RUNTIME_ROOT}/stacks/monitoring/...`

---

## Prerequisites
- Telegram bot token (secret)
- Telegram chat/group ID (not a secret, but environment-specific)
- Access to the `monitoring` stack runtime to mount secrets/overrides

---

## Runtime secrets and permissions
Alertmanager expects the bot token at `/run/secrets/telegram_bot_token` (see `alertmanager.yml`).
- Store the secret in runtime and mount it into the container.
- Recommended permissions: mode `600`, owner `<user>:<group>`.

Chat IDs are **not secrets**, but should be kept environment-specific (do not commit real IDs in the repo). The repo config ships with a placeholder chat ID; override it in runtime if needed.

---

## Configuration touchpoints (repo)
- `stacks/monitoring/alertmanager/alertmanager.yml`
  - Receivers: `notify` (warning) and `oncall` (critical)
  - Routing: `severity`-based
  - Templates: `stacks/monitoring/alertmanager/templates/telegram.tmpl`

If you need to override `chat_id` or other env-specific values, do it in runtime (do not edit the repo file with real IDs or tokens).

---


## External URL (runtime-only)
Alertmanager templates use `.ExternalURL` to build Alert/Silence links. Set the public URL in a runtime override (do not hardcode it in the repo):

```yaml
# ${RUNTIME_ROOT}/stacks/monitoring/compose.override.yml
services:
  alertmanager:
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--web.external-url=https://alertmanager.<your-domain>"
```
## Testing (end-to-end)
The simplest test is an injected alert from inside the Alertmanager container:

```bash
docker compose -f stacks/monitoring/compose.yaml exec -T alertmanager \
  amtool --alertmanager.url=http://localhost:9093 \
  alert add TestTelegram \
  severity=warning service=monitoring \
  --annotation=summary="Test alert" \
  --annotation=description="Telegram receiver test" \
  --annotation=runbook_url="stacks/monitoring/runbooks/BlackboxExporterDown.md"
```

**Success criteria**
- The notification arrives in Telegram.
- Alertmanager logs show no receiver errors.

---

## Cleanup (silences)
Alerts resolve automatically when the condition clears.

Create a short silence for the test alert:
```bash
docker compose -f stacks/monitoring/compose.yaml exec -T alertmanager \
  amtool --alertmanager.url=http://localhost:9093 \
  silence add alertname="TestTelegram" --duration=10m --comment="telegram test"
```

List silences:
```bash
docker compose -f stacks/monitoring/compose.yaml exec -T alertmanager \
  amtool --alertmanager.url=http://localhost:9093 silence query
```

Expire a test silence (use the silence ID from the query):
```bash
docker compose -f stacks/monitoring/compose.yaml exec -T alertmanager \
  amtool --alertmanager.url=http://localhost:9093 silence expire <SILENCE_ID>
```

---

## Rollback
1) Remove or disable Telegram receivers/routes in runtime overrides.
2) Reload/restart Alertmanager.
3) Confirm no Telegram deliveries are happening.

---

## References
- `overview.md`
- `prometheus-rules.md`
- `runbooks.md`
