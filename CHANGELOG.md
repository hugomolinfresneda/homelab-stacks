# Changelog

## [Unreleased]
- Nextcloud ops documented with guardrails: staged restore by default, explicit in-place opt-in; status/reset-db workflow.
- Systemd examples added for running Nextcloud backups reliably.
- Monitoring notes for Nextcloud: exporters + DB credential wiring examples.
- README turned into a repo hub: quickstart, contract, stack index, and links to ops docs.
- Licensed under Apache-2.0; SPDX headers applied to eligible scripts.

## Since v1.0.0 (high-level, non-exhaustive)
Non-exhaustive summary; see Git history/PRs for full detail.
- Established a public/runtime contract with runtime-only overrides and canonical path placeholders.
- Defined a Makefile-first ops workflow plus stricter lint/validate checks.
- Introduced monitoring (Grafana/Prometheus/Loki): alerting, runbooks, dashboards, demo guidance, and integrations.
- Standardized Compose conventions and routed docker_sd/logs via docker-socket-proxy.
- Enabled backup/restore tooling for Restic and Nextcloud with guardrails and systemd units.
- Documented Nextcloud ops and env templates, including monitoring profile and networks.
- Shipped CouchDB stack with observability plus CORS/auth templates.
- Shipped AdGuard Home stack with DNS and exporter monitoring.

## [1.0.0] - 2025-10-28 (baseline)
### Initial release
- **Dozzle stack** — lightweight Docker log viewer with base `compose.yaml`, `.env.example` and runtime override.
- **Uptime Kuma stack** — uptime and certificate monitoring dashboard, integrated with proxy network.
- **Cloudflared stack** — Cloudflare Tunnel for secure outbound publishing, with pinned digest and simplified healthcheck.
- Unified `Makefile` across all stacks with consistent commands:
  - `make up`, `make down`, `make ps`, `make logs`, `make pull`
  - `make lint`, `make validate`
