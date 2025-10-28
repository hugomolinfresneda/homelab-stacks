# Changelog

## [v1.3.0] - 2025-10-28
### Added
- **Dozzle stack** — lightweight Docker log viewer with base `compose.yaml`, `.env.example` and runtime override.
- **Uptime Kuma stack** — uptime and certificate monitoring dashboard, integrated with proxy network.
- **Cloudflared stack** — Cloudflare Tunnel for secure outbound publishing, with pinned digest and simplified healthcheck.
- Unified `Makefile` across all stacks with consistent commands:
  - `make up`, `make down`, `make ps`, `make logs`, `make pull`
  - `make lint`, `make validate`

### Improved
- Documentation now aligned with two-repo architecture (`homelab-stacks` / `homelab-runtime`).
- README files rewritten for clarity, including quick-start sections and network topology examples.

### Notes
- Each stack now deployable independently via `make up stack=<name>`.
- Runtime secrets (`.env`, credentials, tunnel JSON) remain private under `/opt/homelab-runtime`.
