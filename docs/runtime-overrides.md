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

## Canonical paths (setup for examples)
Use the canonical variables in docs and examples:
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"    # e.g. /opt/homelab-stacks
export RUNTIME_ROOT="/abs/path/to/homelab-runtime" # e.g. /opt/homelab-runtime
```

If you want a stack-specific shortcut in examples:
```sh
RUNTIME_DIR="${RUNTIME_ROOT}/stacks/<stack>"
```

## Example override (generic, safe)
```yaml
services:
  app:
    ports:
      - "127.0.0.1:8080:80"
    env_file:
      - ${RUNTIME_DIR}/.env
    volumes:
      - ${RUNTIME_DIR}/data:/var/lib/app
    secrets:
      - app_password

secrets:
  app_password:
    file: ${RUNTIME_DIR}/secrets/app_password
```

## Relative paths are risky
Using `./` in overrides can break when the override is copied or stored outside the repo,
because Compose resolves `./` relative to the override file's location, not the repo.
Prefer absolute paths or clear placeholders like `${RUNTIME_DIR}/...`.

## Default layout (if you use the Makefile)
The root `Makefile` assumes a runtime layout per stack:
- Set `RUNTIME_DIR` to the runtime stack directory (e.g.,
  `${RUNTIME_ROOT}/stacks/<stack>`; e.g. `/opt/homelab-runtime/stacks/<stack>`).
- The override file is expected at `${RUNTIME_DIR}/compose.override.yml`
  (use the real override file present in your runtime; if it is
  `compose.override.yaml`, use that).
- Env files are expected at `${RUNTIME_DIR}/.env` (plus `db.env` for the Nextcloud stack).

This is a configurable convention, not a requirement. If you do not use the Makefile,
use any layout that matches your runtime.
