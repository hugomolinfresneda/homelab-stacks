# Cloudflare Tunnel — Outbound reverse proxy (CGNAT-friendly)

This stack establishes a persistent Cloudflare Tunnel to expose your internal Docker services (e.g. Dozzle, Uptime Kuma, Nextcloud) securely **without opening ports** on your router.

It runs a minimal container (`cloudflare/cloudflared`) that maintains outbound connections to Cloudflare’s edge.

---

## Repo contract (links)
This stack follows the standard repo/runtime split. See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

---

## Architecture

| Repository          | Purpose                                                                                   |
| ------------------- | ----------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation).                   |
| **homelab-runtime** | Private overrides (`compose.override.yaml`, `.env`, real `config.yaml`, credentials JSON). |

---

## Components
- `cloudflared` (Cloudflare Tunnel client)
- Networks: `proxy`, `mon-net`

---

## Requirements

### Software
- Docker Engine + Docker Compose plugin
- GNU Make (`make`)

### Shared Docker network
```bash
docker network create proxy || true
docker network create mon-net || true
```

### Cloudflare prerequisites
- A **Cloudflare account** with a domain already added to Cloudflare.
- One created **Tunnel ID (UUID)** and its **JSON credential** file.

### Networking / Ports
| Service | Exposure | Host | Container | Protocol | Notes |
|---|---|---|---:|---|---|
| `cloudflared` metrics | Internal only (`expose` via metrics flag) | — | 8081 | tcp | `--metrics 0.0.0.0:8081` in compose. No host ports published. |

### Storage
> Host paths are **runtime-only** (no hardcoded paths in the repo).

| Purpose | Host (runtime) | Container | RW | Notes |
|---|---|---|---:|---|
| Tunnel config | `${RUNTIME_ROOT}/stacks/cloudflared/config.yaml` | `/etc/cloudflared/config.yaml` | No | Mounted from runtime. |
| Credentials | `${RUNTIME_ROOT}/stacks/cloudflared/credentials.json` | `${CLOUDFLARED_CRED_FILE}` | No | Container path set in `.env`. |

---

## Quickstart (Makefile)

```bash
# 1) Canonical variables (adjust to your host)
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/cloudflared"

# 2) Prepare runtime (overrides + environment variables)
mkdir -p "${RUNTIME_DIR}"
cp "stacks/cloudflared/compose.override.example.yaml" \
  "${RUNTIME_DIR}/compose.override.yaml"
cp "stacks/cloudflared/.env.example" "${RUNTIME_DIR}/.env"
# EDIT: ${RUNTIME_DIR}/compose.override.yaml and ${RUNTIME_DIR}/.env

# 3) Configure tunnel (runtime)
# - ${RUNTIME_DIR}/config.yaml
# - ${RUNTIME_DIR}/credentials.json

# 4) Bring up the stack
cd "${STACKS_DIR}"
make up stack=cloudflared

# 5) Status
make ps stack=cloudflared
```

---

## Configuration

### Runtime `config.yaml`
Example `${RUNTIME_DIR}/config.yaml` (see `stacks/cloudflared/cloudflared/config.yaml.example`):

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: <CLOUDFLARED_CRED_FILE>

ingress:
  - hostname: <SERVICE_SUBDOMAIN>.<YOUR_DOMAIN>
    service: http://<SERVICE_NAME>:<SERVICE_PORT>
  - service: http_status:404
```

### Variables (.env)
- Example: `stacks/cloudflared/.env.example`
- Runtime: `${RUNTIME_DIR}/.env` (not versioned)

| Variable | Required | Example | Description |
|---|---|---|---|
| `TZ` | No | `Etc/UTC` | Container timezone. |
| `CLOUDFLARED_UID` | No | `65532` | UID to run the container. |
| `CLOUDFLARED_GID` | No | `65532` | GID to run the container. |
| `CLOUDFLARED_CRED_FILE` | Yes | `/etc/cloudflared/<TUNNEL_UUID>.json` | Container path for credentials JSON. |

### Runtime files (not versioned)
Expected paths in `${RUNTIME_DIR}` (from override example):
- `${RUNTIME_DIR}/config.yaml`
- `${RUNTIME_DIR}/credentials.json`

---

## Runtime overrides
Files:
- Example: `stacks/cloudflared/compose.override.example.yaml`
- Runtime: `${RUNTIME_DIR}/compose.override.yaml`

What goes into runtime overrides:
- Mounts for `config.yaml` and credentials JSON

---

## Operation (Makefile)

### Logs
```bash
make logs stack=cloudflared
```

### Update images
```bash
make pull stack=cloudflared
make up stack=cloudflared
```

### Stop / start
```bash
make down stack=cloudflared
make up stack=cloudflared
```

---

## Creating the CNAMEs (via Cloudflare dashboard)

Each `hostname:` in your `config.yaml` must have a **DNS CNAME** record in Cloudflare pointing to the tunnel.

1. Open your domain in Cloudflare → **DNS → Records**
2. Create one CNAME per service:

| Type  | Name                | Target                          | Proxy Status |
| ----- | ------------------- | ------------------------------- | ------------ |
| CNAME | `<SERVICE_SUBDOMAIN>` | `<TUNNEL_UUID>.cfargotunnel.com` | Proxied      |

3. Save changes. No TTL or proxy tweaks needed — Cloudflare handles routing automatically.

To verify:

```bash
dig +short <SERVICE_SUBDOMAIN>.<YOUR_DOMAIN>
```

Should return:

```
<TUNNEL_UUID>.cfargotunnel.com.
```

---

## Add new services

1. Add the rule in your `config.yaml`:

```yaml
- hostname: <SERVICE_SUBDOMAIN>.<YOUR_DOMAIN>
  service: http://<SERVICE_NAME>:<SERVICE_PORT>
```

2. Create the CNAME in Cloudflare’s **DNS → Records**,
   pointing to your `<TUNNEL_UUID>.cfargotunnel.com`.
3. Restart the tunnel:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

---

## Security notes

- Never version the JSON credential file.
- Do **not** expose ports 80/443.
- Keep the `proxy` network shared among your web services.
- Cloudflare handles TLS and authentication at the edge.

---

## Persistence / Backups
Persistence lives under `${RUNTIME_ROOT}/stacks/cloudflared/...`.
Backups: see `ops/backups/README.md`.

---

## Troubleshooting

| Symptom                           | Likely cause                                                  |
| --------------------------------- | ------------------------------------------------------------- |
| Crash-loop or `permission denied` | Wrong path or perms on `$CLOUDFLARED_CRED_FILE`               |
| 404 from Cloudflare               | Missing or wrong `ingress` rule                               |
| Connection refused                | Target container not in `proxy` network                       |
| Host not resolving                | Missing CNAME record in Cloudflare                            |

---

## Observability

This tunnel stack is designed to integrate with the monitoring stack
(`stacks/monitoring`). The `cloudflared` container exposes Prometheus metrics
on an internal port and joins the monitoring network so that Prometheus can
scrape it directly.

Key points from `compose.yaml`:
- `--metrics 0.0.0.0:8081` enables the `/metrics` endpoint inside the container.
- The service joins both `proxy` and `mon-net` networks.
- No host ports are published; metrics are only reachable from Docker networks.

---

## Escape hatch (debug)
> Use only if you need to inspect the raw compose setup.

```bash
cd "${STACKS_DIR}"
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "stacks/cloudflared/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  ps
```
