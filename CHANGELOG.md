# Changelog

## [Unreleased]
### Added
- _None yet._

### Changed
- _None yet._

### Fixed
- _None yet._

## [2.0.0] - 2026-02-04 (portfolio baseline)
### Added
- Expanded monitoring/alerting with domain Prometheus rules, Alertmanager Telegram templates, runbooks, and dashboards for infra/apps/logs/backups, including Nextcloud exporter and DB-credential wiring.
- Added backup observability for Restic + Nextcloud health metrics and backup-status dashboards.
- Added systemd scheduling examples for Restic and Nextcloud backup workflows.

### Changed
- Formalized the public/runtime contract and standardized runtime-only override templates/placeholders across stacks.
- Standardized compose/runtime conventions (service naming/anchors/networks), including the monitoring network model and documented rootful runtime assumptions.
- Updated Nextcloud restore defaults to staged recovery; in-place restore requires explicit opt-in guardrails.
- Standardized YAML file extensions from `.yml` to `.yaml` across the repository; updated CI, Makefiles, docs, and helper scripts to match.
- Reworked operator documentation across root README, monitoring, backups, and Nextcloud runbooks.
- Added Apache-2.0 license and SPDX headers for eligible scripts and tools.

### Fixed
- Fixed Nextcloud helper commands (`make nc-status`, `make nc-reset-db`) to fail fast with timeouts and clearer output; `make nc-reset-db` now safely targets the actual DB volume.

### Verification
- `make lint`
- `make validate`

## Legacy (pre-portfolio) — high-level
Non-exhaustive summary; see Git history/PRs for full detail.
- Established a public/runtime contract with runtime-only overrides and canonical path placeholders.
- Defined a Makefile-first ops workflow plus stricter lint/validate checks.
- Introduced monitoring (Grafana/Prometheus/Loki): alerting, runbooks, dashboards, demo guidance, and integrations.
- Standardized Compose conventions and routed docker_sd/logs via docker-socket-proxy.
- Enabled backup/restore tooling for Restic and Nextcloud with guardrails and systemd units.
- Documented Nextcloud ops and env templates, including monitoring profile and networks.
- Shipped CouchDB stack with observability plus CORS/auth templates.
- Shipped AdGuard Home stack with DNS and exporter monitoring.

## [legacy/v1.0.0] — 2025-10-28
### Initial release
- **Dozzle stack** — lightweight Docker log viewer with base `compose.yaml`, `.env.example` and runtime override.
- **Uptime Kuma stack** — uptime and certificate monitoring dashboard, integrated with proxy network.
- **Cloudflared stack** — Cloudflare Tunnel for secure outbound publishing, with pinned digest and simplified healthcheck.
- Unified `Makefile` across all stacks with consistent commands:
  - `make up`, `make down`, `make ps`, `make logs`, `make pull`
  - `make lint`, `make validate`
