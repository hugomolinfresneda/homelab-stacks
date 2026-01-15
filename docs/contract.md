# Public-to-Runtime Contract

## Scope and Intent
This document defines the boundary between the public repository and the private runtime. It clarifies what belongs in each place, how configuration is parameterized, and what must never be published. It is designed for operational clarity and safe collaboration.

## Public Repository (This Repo)
- Declarative templates, examples, and documentation.
- Non-sensitive defaults and placeholders for configuration.
- Runbooks, onboarding notes, and contribution guidance.
- Schema-level references for environment variables (names, purpose, and allowed formats).

## Runtime (Private / Local)
- Real deployment artifacts and operational state.
- Host-specific paths, mounts, and device mappings.
- Runtime credentials and secret material.
- Logs, volumes, caches, and generated data.

## Parameterization (Environment Variables)
- Variables are defined by name and purpose only, with safe example formats.
- Real values are provided at runtime via local `.env` or secret stores.
- Defaults, if any, are non-sensitive and safe for public display.

## Never Publish in This Repo
- Secrets, tokens, API keys, or passwords.
- Real host paths, IPs, or infrastructure identifiers.
- Private registry credentials or deployment endpoints.
- Any runtime-generated files that include sensitive context.

## Demo-Only Usage (No Runtime)
This repository can be read and reviewed without a live runtime. The following applies:
- Works: documentation review, configuration schema review, and static inspection.
- Does not work: service startup, real integrations, or data persistence.

## Change Control
Any change that affects the public-to-runtime boundary must update this contract and the root README link.
