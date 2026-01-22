# Public-to-Runtime Contract

## Scope and Intent
This document defines the boundary between the public repository and the private runtime.
It clarifies what belongs in each place, how configuration is parameterized, and what
must never be published. For runtime overrides, see `docs/runtime-overrides.md`.

## Public Repository (This Repo)
- `compose.yaml` per stack and other declarative templates.
- Env templates such as `.env.example` with safe placeholders.
- Documentation, runbooks, and contribution guidance.
- Schema-level references for environment variables (names, purpose, and formats).

## Runtime (Private / Local)
- `compose.override.yml` (or equivalent) kept outside the repo.
- Real env files with values (not templates).
- Secrets stored as files outside the repo.
- Host-specific paths, mounts, device mappings, and operational state.

## Parameterization (Environment Variables)
- Variables are defined by name and purpose only, using env templates.
- Real values are provided at runtime via local env files or secret stores.
- Defaults, if any, are non-sensitive and safe for public display.

## Paths and Targets (Sensitive vs Default)
- Sensitive/personal path: host-specific absolute paths that reveal real mounts, usernames,
  devices, or data locations (e.g., `/home/<user>/...`, `/mnt/<disk>/...`). Keep these
  only in runtime overrides or local env files.
- Default configurable convention: repo-safe defaults used in docs/templates (e.g.,
  `/opt/homelab-stacks`, `/opt/homelab-runtime`, `/path/to/runtime/<stack>`). These are
  conventions/placeholders and must be overridable via runtime config (see
  `docs/runtime-overrides.md`).
- Real targets (hostnames/IPs, including private IPv4 RFC1918 and private IPv6/ULA) belong
  only in runtime. Examples in the repo must use placeholders or documentation ranges:
  RFC5737 IPv4 (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and RFC3849 IPv6
  (`2001:db8::/32`).

## Never Publish in This Repo
- Secrets, tokens, API keys, or passwords.
- Runtime overrides with real values, real env files, or secret files (templates like
  `.env.example` and `compose.override.example.yaml` are ok).
- Sensitive/personal host paths or real infrastructure identifiers (see "Paths and Targets").
- Private registry credentials or real deployment endpoints/targets.
- Any runtime-generated files that include sensitive context.

## Demo-Only Usage (No Runtime)
This repository can be read and reviewed without a live runtime. The following applies:
- Works: documentation review, configuration schema review, and static inspection.
- Does not work: service startup, real integrations, or data persistence.

## Change Control
Any change that affects the public-to-runtime boundary must update this contract, the
runtime overrides doc, and the root README links.
