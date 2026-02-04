# Dozzle — Real-time Docker log viewer

Dozzle provides a lightweight, read-only web interface to view Docker container logs in real time.
This stack follows the **two-repository model** used across the homelab:
a public repository with clean, reusable definitions, and a private runtime repository with local overrides and secrets.

---

## Repo contract (links)
This stack follows the standard repo/runtime split. See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

---

## Repository structure

| Repository          | Purpose                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definitions (`compose.yaml`, `.env.example`, documentation). No local paths or secrets. |
| **homelab-runtime** | Private runtime overrides (`compose.override.yaml`, `.env`, secrets, systemd units, backups).       |

---

## Components
- `dozzle`
- `docker-socket-proxy` (runtime override)
- Network: `proxy`

---

## Requirements

### Software
- Docker Engine + Docker Compose plugin
- GNU Make (`make`)

### Shared Docker network
```bash
docker network create proxy || true
```

### Networking / Ports
| Service | Exposure | Host | Container | Protocol | Notes |
|---|---|---|---:|---|---|
| `dozzle` | Internal only (`expose`) | — | 8080 | tcp | Reachable on the `proxy` network. |
| `dozzle` | Host-published (optional, runtime override) | `${BIND_LOCALHOST:-127.0.0.1}:${HTTP_PORT:-8081}` | 8080 | tcp | Optional local bind for debugging. |

### Storage
No persistent volumes are defined for this stack.

---

## Quickstart (Makefile)

```bash
# 1) Canonical variables (adjust to your host)
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/dozzle"

# 2) Prepare runtime (overrides + environment variables)
mkdir -p "${RUNTIME_DIR}"
cp "stacks/dozzle/compose.override.example.yaml" \
  "${RUNTIME_DIR}/compose.override.yaml"
cp "stacks/dozzle/.env.example" "${RUNTIME_DIR}/.env"
# EDIT: ${RUNTIME_DIR}/compose.override.yaml and ${RUNTIME_DIR}/.env

# 3) Bring up the stack
cd "${STACKS_DIR}"
make up stack=dozzle

# 4) Status
make ps stack=dozzle
```

---

## Configuration

### Variables (.env)
- Example: `stacks/dozzle/.env.example`
- Runtime: `${RUNTIME_DIR}/.env` (not versioned)

| Variable | Required | Example | Description |
|---|---|---|---|
| `TZ` | No | `Etc/UTC` | Container timezone. |
| `DOCKER_SOCK` | Yes | `/var/run/docker.sock` | Host Docker socket path (rootful or rootless). |
| `BIND_LOCALHOST` | No | `127.0.0.1` | Optional host bind (runtime override). |
| `HTTP_PORT` | No | `8081` | Optional host port (runtime override). |

Rootful/rootless examples (comments only):
- Rootful: `/var/run/docker.sock`
- Rootless: `/run/user/<UID>/docker.sock`

### Runtime files (not versioned)
Expected files in `${RUNTIME_DIR}`:
- `${RUNTIME_DIR}/.env`
- `${RUNTIME_DIR}/compose.override.yaml`

---

## Runtime overrides
Files:
- Example: `stacks/dozzle/compose.override.example.yaml`
- Runtime: `${RUNTIME_DIR}/compose.override.yaml`

What goes into runtime overrides:
- `docker-socket-proxy` service
- Optional host `ports:` bind for the UI

---

## Operation (Makefile)

### Logs
```bash
make logs stack=dozzle
```

### Update images
```bash
make pull stack=dozzle
make up stack=dozzle
```

### Stop / start
```bash
make down stack=dozzle
make up stack=dozzle
```

---

## Publishing (Cloudflare Tunnel)

1. Add the ingress rule to your tunnel config:

```yaml
# ${RUNTIME_ROOT}/stacks/cloudflared/config.yaml
ingress:
  - hostname: dozzle.<your-domain>
    service: http://dozzle:8080
  - service: http_status:404
```

2. Create the DNS record in Cloudflare (Dashboard  ^f^r DNS  ^f^r Records):

- Type: **CNAME**
- Name: `dozzle`
- Target: `<TUNNEL_UUID>.cfargotunnel.com`
- Proxy: **Proxied**


3. Restart the tunnel container:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

4. Verify externally:

```bash
curl -I https://dozzle.<your-domain>/
# HTTP/2 200
```

---

## Observability

- Dozzle has **no native Prometheus metrics**.
- Recommended integrations:
  - **Uptime Kuma** → HTTP check on the published domain.
  - **Loki / Promtail** → central log aggregation.

Dozzle is monitored as part of the logging stack:
- The container is labelled with `com.logging="true"` so Promtail picks up its logs and ships them to Loki.
- The `service="dozzle"` label is used as the canonical selector in Grafana (Loki datasource).

Example LogQL:

```logql
{service="dozzle"}
```

---

## Security notes

- Never expose Dozzle publicly without authentication.
- Avoid mounting the Docker socket directly in Dozzle; use a socket proxy with minimal endpoints.
- Keep the proxy internal (no published ports) and on a trusted network.
- Consider Cloudflare Access in front of the hostname for SSO/MFA.

## Why socket proxy

The Docker API is powerful and effectively grants root-equivalent control over the host.
Using `docker-socket-proxy` limits the exposed endpoints to the minimum Dozzle needs,
reducing blast radius if the container is ever compromised.

If Dozzle is missing live updates when containers start/stop, enable the `EVENTS=1`
endpoint in the proxy. Add other endpoints only when you can justify the need.

---

## Persistence / Backups
No persistent data in this stack.

---

## Escape hatch (debug)
> Use only if you need to inspect the raw compose setup.

```bash
cd "${STACKS_DIR}"
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "stacks/dozzle/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  ps
```
