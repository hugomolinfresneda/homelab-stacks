# CouchDB — Self-hosted database (Obsidian LiveSync ready)

This stack deploys **CouchDB 3** using a two-repo model (public **homelab-stacks** + private **homelab-runtime**).
It is intended to be published via **Cloudflare Tunnel** (no host ports exposed by default).

---

## Repo contract (links)
This stack follows the standard repo/runtime split. See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

---

## Architecture

| Repository          | Purpose                                                                  |
| ------------------- | ------------------------------------------------------------------------ |
| **homelab-stacks**  | Public base definition: `compose.yaml`, `.env.example`, docs, examples.  |
| **homelab-runtime** | Private overrides: `compose.override.yaml`, `.env`, `data/`, `local.d/`. |

---

## Components
- `couchdb`
- `couchdb-exporter`
- Networks: `proxy`, `mon-net`

---

## Requirements

### Software
- Docker Engine + Docker Compose plugin
- GNU Make (`make`)

### Shared Docker networks
```bash
docker network create proxy || true
docker network create mon-net || true
```

### Networking / Ports
| Service | Exposure | Host | Container | Protocol | Notes |
|---|---|---|---:|---|---|
| `couchdb` | Internal only (`expose`) | — | 5984 | tcp | Accessible on `proxy` network. |
| `couchdb` | Host-published (optional, runtime override) | `${BIND_LOCALHOST:-127.0.0.1}:${HTTP_PORT:-5984}` | 5984 | tcp | Optional local bind for testing. |
| `couchdb-exporter` | Internal only (`expose`) | — | 9984 | tcp | Scraped by Prometheus at `couchdb-exporter:9984` (monitoring example). |

### Storage
> Host paths are **runtime-only** (no hardcoded paths in the repo).

| Purpose | Host (runtime) | Container | RW | Notes |
|---|---|---|---:|---|
| Data | `${RUNTIME_ROOT}/stacks/couchdb/data` | `/opt/couchdb/data` | Yes | CouchDB database files. |
| Config | `${RUNTIME_ROOT}/stacks/couchdb/local.d` | `/opt/couchdb/etc/local.d` | No | INI snippets (runtime). |

---

## Quickstart (Makefile)

```bash
# 1) Canonical variables (adjust to your host)
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/couchdb"

# 2) Prepare runtime (overrides + environment variables)
mkdir -p "${RUNTIME_DIR}"
cp "stacks/couchdb/compose.override.example.yaml" \
  "${RUNTIME_DIR}/compose.override.yaml"
cp "stacks/couchdb/.env.example" "${RUNTIME_DIR}/.env"
# EDIT: ${RUNTIME_DIR}/compose.override.yaml and ${RUNTIME_DIR}/.env

# 3) Prepare local.d (runtime)
mkdir -p "${RUNTIME_DIR}/local.d"
cp stacks/couchdb/local.d/*.example "${RUNTIME_DIR}/local.d/"
# Edit the .ini files in runtime according to your needs.

# 4) Bring up the stack
cd "${STACKS_DIR}"
make up stack=couchdb

# 5) Status
make ps stack=couchdb
```

---

## Configuration

### Variables (.env)
- Example: `stacks/couchdb/.env.example`
- Runtime: `${RUNTIME_DIR}/.env` (not versioned)

| Variable | Required | Example | Description |
|---|---|---|---|
| `COUCHDB_USER` | Yes | `<user>` | Admin username for bootstrap. |
| `COUCHDB_PASSWORD` | Yes | `<secret>` | Admin password for bootstrap. |
| `COUCHDB_CORS_ORIGINS` | No | `https://app.example` | CORS origins for `local.d/10-cors.ini`. |
| `BIND_LOCALHOST` | No | `127.0.0.1` | Optional host bind (runtime override). |
| `HTTP_PORT` | No | `5984` | Optional host port (runtime override). |

### Runtime files (not versioned)
Expected paths in `${RUNTIME_DIR}` (from override example):
- `${RUNTIME_DIR}/data/`
- `${RUNTIME_DIR}/local.d/`

Templates are in `stacks/couchdb/local.d/*.ini.example`.

---

## Runtime overrides
Files:
- Example: `stacks/couchdb/compose.override.example.yaml`
- Runtime: `${RUNTIME_DIR}/compose.override.yaml`

What goes into runtime overrides:
- `volumes:` for host persistence paths
- Optional host `ports:` bind for local testing

---

## Operation (Makefile)

### Logs
```bash
make logs stack=couchdb
```

### Update images
```bash
make pull stack=couchdb
make up stack=couchdb
```

### Stop / start
```bash
make down stack=couchdb
make up stack=couchdb
```

---

## Publishing (Cloudflare Tunnel)

1. Add the ingress rule to your tunnel config:

```yaml
# ${RUNTIME_ROOT}/stacks/cloudflared/config.yml
ingress:
  - hostname: couchdb.<your-domain>
    service: http://couchdb:5984
  - service: http_status:404
```

2. Create the DNS record in Cloudflare (Dashboard → DNS → Records):

- Type: **CNAME**
- Name: `couchdb`
- Target: `<TUNNEL_UUID>.cfargotunnel.com`
- Proxy: **Proxied**

3. Restart the tunnel container:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

4. Verify externally:

```bash
curl -I https://couchdb.<your-domain>/_up
# HTTP/2 200
```

---

## Security notes

- Change the default password in `.env`.
- Keep runtime `local.d` out of version control.
- Do not expose port 5984 on the host; publish only via the tunnel.
- Consider Cloudflare Access in front of the hostname for SSO/MFA.

---

## Persistence / Backups
Persistence lives under `${RUNTIME_ROOT}/stacks/couchdb/...`.
Backups: see `ops/backups/README.md`.

---

## Troubleshooting

| Symptom                                    | Likely cause / fix                                                |
| ------------------------------------------ | ----------------------------------------------------------------- |
| `Unable to reach origin service` in tunnel | CouchDB not on `proxy` network or wrong service/port in ingress.  |
| `{"error":"unauthorized"}` on requests     | Wrong `COUCHDB_USER`/`COUCHDB_PASSWORD` or missing CORS settings. |
| `_up` fails internally                     | Container not healthy; check `make logs stack=couchdb`.           |
| Data not persisted                         | Missing bind in runtime override for `${RUNTIME_DIR}/data`.       |

---

## Observability

This stack includes a `couchdb-exporter` service (see `compose.yaml`).
Prometheus scrapes the exporter at `couchdb-exporter:9984`.

---

## Escape hatch (debug)
> Use only if you need to inspect the raw compose setup.

```bash
cd "${STACKS_DIR}"
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "stacks/couchdb/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  ps
```
