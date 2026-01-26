# Public-to-Runtime Contract

## Purpose
This document defines the boundary between the public repository and the private runtime.
It explains what belongs in each place, how configuration is parameterized, and what
must never be published. After reading it, you should know which files live in the
repo, which live in runtime, and which variables are canonical.

**In scope**
- Public vs runtime separation rules and guarantees.
- Canonical variables and placeholder usage.
- What must never be committed to the repo.

**Out of scope**
- Stack-specific implementation details.
- Runtime operational procedures (see `docs/runtime-overrides.md`).

---

## Contract (rules and guarantees)
> This section is the law. If it changes, it is a contract change.

### Terms and definitions
- **`STACKS_DIR`**: absolute path to the public repository root.
- **`RUNTIME_ROOT`**: absolute path to the private runtime root (not versioned).
- **`RUNTIME_DIR`**: runtime directory for a stack (`${RUNTIME_ROOT}/stacks/<stack>`).
- **runtime override**: a Compose file that overlays `compose.yaml` with host-specific
  settings at deploy time.
- **secrets**: credentials, tokens, or files that must never be committed.

### Canonical variables
- `STACKS_DIR="/abs/path/to/homelab-stacks"`
- `RUNTIME_ROOT="/abs/path/to/homelab-runtime"`
- `RUNTIME_DIR="${RUNTIME_ROOT}/stacks/<stack>"`

### Mandatory rules
- Host paths are never hardcoded in the repo; use variables/placeholders and runtime
  overrides instead.
- Secrets and sensitive files live in runtime only; the repo contains templates
  (for example `.env.example`, `compose.override.example.yaml`).
- Examples in the repo use placeholders (`/abs/path/...`, `<stack>`, `<uid>`) and
  never real host paths.
- The base `compose.yaml` in the repo must be portable; host-specific mounts, devices,
  and endpoints belong in runtime overrides.
- If a stack interacts with Docker socket/logs or other host resources, its README
  must document rootful vs rootless and expose variables (for example `DOCKER_SOCK`,
  `DOCKER_CONTAINERS_DIR`). Details live in stack READMEs, not here.
- Real targets (hostnames/IPs) belong only in runtime. In repo examples, use
  placeholders or documentation ranges (RFC5737 IPv4 and RFC3849 IPv6).

### Recommended rules
- Keep a consistent runtime layout based on `RUNTIME_ROOT` and `RUNTIME_DIR`.
- Provide `.env.example` and `compose.override.example.yaml` when a stack needs
  runtime-only inputs.

### What this contract guarantees
- Portability between hosts by changing runtime only.
- Clear separation between public repo and private runtime.
- Reviews without environment-specific diffs.

---

## Disk layout (mental model)
- Public repo (versioned): `${STACKS_DIR}/...`
- Private runtime (not versioned): `${RUNTIME_ROOT}/...`

Example tree (illustrative):
```text
${STACKS_DIR}/
  stacks/<stack>/
    compose.yaml
    compose.override.example.yaml
    .env.example
  docs/
  ops/

${RUNTIME_ROOT}/
  stacks/<stack>/
    compose.override.yaml
    .env
    data/
    config/
  ops/backups/
```

---

## How to use (short)
1) Set `STACKS_DIR` and `RUNTIME_ROOT` to absolute paths.
2) Create `RUNTIME_DIR` for the stack you are operating.
3) Apply runtime overrides and run the stack following `docs/runtime-overrides.md`.

---

## Examples (copiable)

### Example A: override for persistence (bind mount)
```yaml
# ${RUNTIME_DIR}/compose.override.yaml
services:
  app: # TODO: rename "app" to the real service name
    volumes:
      - ${RUNTIME_DIR}/data:/var/lib/app/data # TODO: rename "app" to the real service name
```

### Example B: secrets outside the repo
```text
${RUNTIME_DIR}/.env            # not versioned
${RUNTIME_DIR}/secrets/<file>  # mode 600
```

---

## Common cases

### Case 1: move a host path out of the repo
- **Situation**: a `compose.yaml` contains `- /abs/path/on/host:/data`.
- **Solution**: move the mount to a runtime override and use `${RUNTIME_DIR}/data`.
- **Verification**:
  - `make validate`
  - data persists after container recreation

---

## Anti-patterns (what NOT to do)
- Do not hardcode host paths in the repo.
- Do not commit real `.env` files, secrets, or overrides with real values.
- Do not mix host paths and container paths without making the host side explicit.

---

## Migration (paths to placeholders)
Examples previously showing real host paths must be replaced with placeholders and
canonical variables (`/abs/path/...`, `RUNTIME_ROOT`, `RUNTIME_DIR`). Update local
notes accordingly; no real paths should remain in the repo.

---

## Troubleshooting

### Error: "set RUNTIME_ROOT=..."
- **Cause**: `RUNTIME_ROOT` is missing.
- **Check**: `echo "$RUNTIME_ROOT"` is empty.
- **Fix**: export a valid absolute path for `RUNTIME_ROOT`.

### Data is not persisting
- **Cause**: override not applied or runtime path incorrect.
- **Check**: the override file exists at `${RUNTIME_DIR}/compose.override.yaml`.
- **Fix**: review `docs/runtime-overrides.md` and re-run with overrides applied.

---

## Change control

If you change the canonical variables, runtime layout, or override naming conventions in this document:
- Update `docs/runtime-overrides.md` to keep procedures and examples aligned.
- Review the root `README.md` summary/links (when it is updated) to avoid documentation drift.

---

## References
- `docs/runtime-overrides.md`
