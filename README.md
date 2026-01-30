# homelab-stacks

## Overview
- Public repo with Docker Compose stacks and ops tooling for homelab/self-hosting.
- Does not include secrets, persistent data, or private runtime; those live outside the repo.
- Intended to be operated via the Makefile as the primary interface.

## Paths & runtime contract
This repo relies on a dual layout:
- **Repo (public/versioned)**: `${STACKS_DIR}` -> code, base compose, examples.
- **Runtime (private/not versioned)**: `${RUNTIME_ROOT}` -> secrets, persistent data, overrides.

Read first:
- [docs/contract.md](docs/contract.md)
- [docs/runtime-overrides.md](docs/runtime-overrides.md)

## Quickstart
> Goal: bring up a stack with the Makefile following the `STACKS_DIR` + `RUNTIME_ROOT` contract.

If a stack needs persistent data/secrets, create runtime overrides under ${RUNTIME_ROOT}/stacks/<stack> (see [docs/runtime-overrides.md](docs/runtime-overrides.md)).

```bash
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"

cd "${STACKS_DIR}"
# Run `make` to see available targets
make validate
make up stack=<name>
make ps stack=<name>
make logs stack=<name> follow=true
make down stack=<name>
make pull stack=<name>
```

## Repository structure
- `stacks/` -> deployable stacks (each with its README)
- `ops/` -> operational tooling (backups, etc.)
- `docs/` -> contract and shared guides

## Available stacks
> Concise list with links. Avoid duplicating instructions: each stack owns its README.

| Stack | README | Notes |
|---|---|---|
| `adguard-home` | [stacks/adguard-home/README.md](stacks/adguard-home/README.md) | See stack README. |
| `cloudflared` | [stacks/cloudflared/README.md](stacks/cloudflared/README.md) | See stack README. |
| `couchdb` | [stacks/couchdb/README.md](stacks/couchdb/README.md) | See stack README. |
| `dozzle` | [stacks/dozzle/README.md](stacks/dozzle/README.md) | See stack README. |
| `monitoring` | [stacks/monitoring/README.md](stacks/monitoring/README.md) | See stack README. |
| `nextcloud` | [stacks/nextcloud/README.md](stacks/nextcloud/README.md) | See stack README. |
| `uptime-kuma` | [stacks/uptime-kuma/README.md](stacks/uptime-kuma/README.md) | See stack README. |

## Operations and maintenance
### Backups (infra and/or stack-specific)
- Infra backups (Restic): [ops/backups/README.md](ops/backups/README.md)
- Nextcloud backups/DR: [stacks/nextcloud/backup/README.backup.md](stacks/nextcloud/backup/README.backup.md) and [stacks/nextcloud/backup/README.dr.md](stacks/nextcloud/backup/README.dr.md)

### Monitoring / Alerting
- Stack monitoring: [stacks/monitoring/README.md](stacks/monitoring/README.md)
- Alerting docs: [stacks/monitoring/docs/alerting/](stacks/monitoring/docs/alerting/)
- Runbooks: [stacks/monitoring/runbooks/](stacks/monitoring/runbooks/)

## Changelog / Releases
- Repo changelog: [CHANGELOG.md](CHANGELOG.md)

## License
- See [LICENSE](LICENSE) (Apache-2.0).
