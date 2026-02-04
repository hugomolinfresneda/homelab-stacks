# Runtime Overrides

## Purpose
This document explains how to define runtime overrides for stacks without modifying
public repo files. It shows the recommended layout, the Makefile requirements (when
using it), and a step-by-step flow with copiable examples.

**In scope**
- How overrides are structured and applied.
- Naming and location conventions for overrides.
- Safe, portable examples using placeholders.

**Out of scope**
- Stack-specific runtime behavior (see each stack README).
- Global contract rules (see `docs/contract.md`).

---

## Contract (rules and guarantees)
> This section inherits the public-to-runtime contract; it adds override specifics.

### Contract linkage
- The public-to-runtime boundary is defined in `docs/contract.md` and applies here.

### Override-specific rules
- The override file lives in runtime, not in the repo.
- Use canonical variables (`STACKS_DIR`, `RUNTIME_ROOT`, `RUNTIME_DIR`) and placeholders.
- Avoid relative paths (`./`) in overrides; prefer `${RUNTIME_DIR}/...`.

### Makefile requirement vs recommendation
- **Makefile requirement**: if you use `make up` (or similar targets), the Makefile
  derives `RUNTIME_DIR` from `RUNTIME_ROOT` and `STACK` (or from an explicit
  `RUNTIME_DIR`) and auto-includes the first existing override at:
  - `${RUNTIME_DIR}/compose.override.yaml`
  - `${RUNTIME_DIR}/compose.override.yaml`
- **Recommendation**: standardize on `${RUNTIME_DIR}/compose.override.yaml` for
  consistency; `.yaml` remains supported by the Makefile.

### Canonical variables
- `STACKS_DIR="/abs/path/to/homelab-stacks"`
- `RUNTIME_ROOT="/abs/path/to/homelab-runtime"`
- `RUNTIME_DIR="${RUNTIME_ROOT}/stacks/<stack>"`

---

## Disk layout (mental model)
- Public repo (versioned): `${STACKS_DIR}/...`
- Private runtime (not versioned): `${RUNTIME_ROOT}/...`

Example tree (illustrative):
```text
${RUNTIME_ROOT}/
  stacks/<stack>/
    compose.override.yaml
    .env
    data/
    secrets/
```

---

## How to use (full flow)

### 1) Define canonical variables
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
```
Why: keeps examples portable and avoids hardcoded host paths.

### 2) Create the runtime directory for the stack
```sh
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/<stack>"
mkdir -p "${RUNTIME_DIR}"
```
Why: all runtime-only files live outside the repo.

### 3) Install the override file in runtime
```sh
example="${STACKS_DIR}/stacks/<stack>/compose.override.example.yaml"
target="${RUNTIME_DIR}/compose.override.yaml"

if [ -f "$example" ]; then
  cp "$example" "$target"
else
  cat >"$target" <<'YAML'
# Runtime override (created because no example was shipped by the stack).
# TODO: add host-specific mounts/env/secrets for this stack.
services: {}
YAML
fi
```
Why: host-specific mounts and secrets must not be committed.

### 4) Create runtime env files (if applicable)
```sh
cp "${STACKS_DIR}/stacks/<stack>/.env.example" "${RUNTIME_DIR}/.env"
# edit: ${RUNTIME_DIR}/.env
```
Why: real values and secrets belong in runtime.

### 5) Run with Makefile (recommended) or Compose
```sh
cd "${STACKS_DIR}"
make up stack=<stack>
make ps stack=<stack>
```
Why: the Makefile auto-adds the runtime override when present.

If you do not use the Makefile, run Compose with both files:
```sh
docker compose \
  -f "${STACKS_DIR}/stacks/<stack>/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  up -d
```
Why: Compose only merges overrides when both files are provided.

---

## Examples (copiable)

### Example A: override for persistence (bind mounts)
```yaml
# ${RUNTIME_DIR}/compose.override.yaml
services:
  app: # TODO: rename "app" to the actual service name
    volumes:
      - ${RUNTIME_ROOT:?set RUNTIME_ROOT}/stacks/<stack>/data:/var/lib/app/data # TODO: rename "app" to the actual service name
```

### Example B: secrets as files in runtime
```text
${RUNTIME_DIR}/secrets/<file>  # mode 600
```

---

## Common cases

### Case 1: override not applied with Makefile
- **Situation**: containers start but changes in override do not apply.
- **Solution**: ensure the override file exists at `${RUNTIME_DIR}/compose.override.yaml`
  (or `.yaml`) and that `RUNTIME_DIR` is set.
- **Verification**: `make -n up stack=<stack>` shows wether the override is present or not.

### Case 2: relative paths break after moving runtime
- **Situation**: using `./data:/var/lib/app` stops working after relocation.
- **Solution**: use `${RUNTIME_DIR}/data:/var/lib/app`.
- **Verification**: stack starts regardless of runtime directory location.

---

## Anti-patterns (what NOT to do)
- Do not keep overrides or real `.env` files inside the repo.
- Do not hardcode host paths in overrides; use `${RUNTIME_DIR}`.
- Do not rely on relative paths (`./`) in runtime overrides.

---

## Migration (paths to placeholders)
Examples that previously used real host paths must be updated to placeholders and
canonical variables (`/abs/path/...`, `RUNTIME_ROOT`, `RUNTIME_DIR`). Keep runtime
values local and out of version control.

---

## Troubleshooting

### Error: override not detected
- **Cause**: `RUNTIME_DIR` not set or override file name does not match Makefile
  candidates (`compose.override.yaml` / `compose.override.yaml`).
- **Check**: `make echo-vars stack=<stack>` and verify `RUNTIME_DIR`.
- **Fix**: set `RUNTIME_ROOT` or `RUNTIME_DIR`, and ensure the override file exists.

### Error: "permission denied" on runtime files
- **Cause**: owner/mode mismatch in runtime directory.
- **Check**: `ls -l "${RUNTIME_DIR}"`.
- **Fix**: correct ownership/permissions for runtime files.

---

## References
- `docs/contract.md`
- `Makefile`
- `stacks/<stack>/README.md` (if present)
