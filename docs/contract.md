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

## Never Publish in This Repo
- Secrets, tokens, API keys, or passwords.
- Runtime overrides, real env files, or secret files.
- Real host paths, IPs, or infrastructure identifiers.
- Private registry credentials or deployment endpoints.
- Any runtime-generated files that include sensitive context.

## Demo-Only Usage (No Runtime)
This repository can be read and reviewed without a live runtime. The following applies:
- Works: documentation review, configuration schema review, and static inspection.
- Does not work: service startup, real integrations, or data persistence.

## Change Control
Any change that affects the public-to-runtime boundary must update this contract, the
runtime overrides doc, and the root README links.
