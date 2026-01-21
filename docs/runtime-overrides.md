# Runtime Overrides

## What is a runtime override?
A runtime override is a local Compose file (often `compose.override.yml`, or an equivalent
name) that is merged with the public `compose.yaml` at deploy time. It injects
host-specific settings and sensitive runtime inputs without changing the public repo.

## Why it exists
- Keeps the public repo safe and shareable by excluding secrets and host paths.
- Lets each host provide its own mounts, ports, and env files without forking.
- Preserves a portable base definition while allowing local adjustments.

## Operational model (public repo vs runtime)
Public repo:
- `compose.yaml` per stack.
- Env templates such as `.env.example`.
- Documentation (this `docs/` tree).

Runtime:
- `compose.override.yml` (or equivalent) kept outside the repo.
- Real env files with values (not templates).
- `secrets` as files outside the repo.
- Host-specific paths and runtime state.

If a stack needs extra details, consult that stack's README under `stacks/`.

## How to apply
1) Keep the base `compose.yaml` in the public repo.
2) Create a runtime directory anywhere you want.
3) Place the override file, real env files, and secret files in that runtime directory.
4) Run Compose with both files so the override is merged at runtime.

## Example override (generic, safe)
```yaml
services:
  app:
    ports:
      - "127.0.0.1:8080:80"
    env_file:
      - /path/to/runtime/<stack>/.env
    volumes:
      - /path/to/runtime/<stack>/data:/var/lib/app
    secrets:
      - app_password

secrets:
  app_password:
    file: /path/to/runtime/<stack>/secrets/app_password
```

## Relative paths are risky
Using `./` in overrides can break when the override is copied or stored outside the repo,
because Compose resolves `./` relative to the override file's location, not the repo.
Prefer absolute paths or clear placeholders like `/path/to/runtime/<stack>/...`.

## Default layout (if you use the Makefile)
The root `Makefile` defines a default runtime layout:
- `RUNTIME_DIR` defaults to `/opt/homelab-runtime/stacks/<stack>`.
- The override file is expected at `RUNTIME_DIR/compose.override.yml`.
- Env files default to `RUNTIME_DIR/.env` (plus `db.env` for the Nextcloud stack).

This is a configurable convention, not a requirement. If you do not use the Makefile,
use any layout that matches your runtime.
