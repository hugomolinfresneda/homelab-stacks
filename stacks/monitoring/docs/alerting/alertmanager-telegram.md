# Alertmanager → Telegram

## Goals

- Route alerts to Telegram with a consistent, low-noise presentation.
- Support quiet hours for warning-level signals.
- Surface incident links (Runbook / Dashboard / Alert / Silence) in notifications.
- Keep the public repo portable by pushing environment-specific values into runtime.

## Receivers and routing

Two Telegram receivers are used:

- `oncall` — receives `severity="critical"` alerts (24/7).
- `notify` — receives `severity="warning"` alerts (muted during quiet hours).

Routing and inhibition rules live in `alertmanager/alertmanager.yml`.

## Quiet hours

Warning notifications are muted during quiet hours via `time_intervals` + `mute_time_intervals`.
Critical alerts are not muted.

## Templates

Telegram messages are rendered via a custom template:

- `alertmanager/templates/telegram.tmpl`

The template uses HTML formatting and short, clickable hyperlinks.

## External URL

To generate correct "Alert" and "Silence" links, Alertmanager must know its external URL.

Set it via the container command:

- `--web.external-url=https://alertmanager.<your-domain>`

This is environment-specific and should live in the runtime overlay.

## Secrets and runtime/public split

Telegram bot tokens are secrets and must not be committed.

Recommended pattern:

- Public repo:
  - ships Alertmanager config + template
  - may keep chat IDs as placeholders
- Runtime:
  - mounts secrets (Telegram bot token)
  - overrides chat IDs and any environment URLs as needed

## Operational commands

Validate configuration inside the container:

- `amtool check-config /etc/alertmanager/alertmanager.yml`

Health endpoints:

- `GET http://localhost:9093/-/ready`
- `GET http://localhost:9093/api/v2/status`

Synthetic alert injection for testing (example):

- `amtool --alertmanager.url=http://localhost:9093 alert add <AlertName> ...`
