# Dozzle — Real-time Docker log viewer

Dozzle provides a lightweight, read-only web interface to view Docker container logs in real time.
This stack follows the **two-repository model** used across the homelab:
a public repository with clean, reusable definitions, and a private runtime repository with local overrides and secrets.

---

## Repository structure

| Repository          | Purpose                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definitions (`compose.yaml`, `.env.example`, documentation). No local paths or secrets. |
| **homelab-runtime** | Private runtime overrides (`compose.override.yml`, `.env`, secrets, systemd units, backups).        |

---

Use the canonical variables for absolute paths:
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"    # e.g. /opt/homelab-stacks
export RUNTIME_ROOT="/abs/path/to/homelab-runtime" # e.g. /opt/homelab-runtime
RUNTIME_DIR="${RUNTIME_ROOT}/stacks/dozzle"
```

## Requirements

* Docker + Compose plugin
* Shared network for reverse proxy / Cloudflare tunnel:
  ```bash
  docker network create proxy || true
  ```

* Debian (rootless Docker) is the target environment.
  For rootful setups, adjust `DOCKER_SOCK` in the `.env`.

---

## File layout

```
${STACKS_DIR}/stacks/dozzle/
├── compose.yaml
├── .env.example
└── README.md

${RUNTIME_DIR}/
├── compose.override.yml
└── .env
```

---

## Environment configuration

Copy the example environment file from the stacks repository into the runtime path:

```bash
cp ${STACKS_DIR}/stacks/dozzle/.env.example \
   ${RUNTIME_DIR}/.env
```

Typical contents:

```dotenv
TZ=<REGION/CITY>
DOCKER_SOCK=<DOCKER_SOCK>   # rootless (e.g., /run/user/<UID>/docker.sock)
# DOCKER_SOCK=/var/run/docker.sock       # rootful
# BIND_LOCALHOST=127.0.0.1   # recommended if you need host access
# HTTP_PORT=8081
```

---

## Deployment workflow

From the **runtime repository**:

```bash
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "${STACKS_DIR}/stacks/dozzle/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yml" \
  up -d

docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "${STACKS_DIR}/stacks/dozzle/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yml" \
  ps
```

Nota: usa el fichero real existente en runtime. Si tu override es `compose.override.yaml`, usa ese fichero.

**Recommended `compose.override.yml`:**

```yaml
services:
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy@sha256:1f3a6f303320723d199d2316a3e82b2e2685d86c275d5e3deeaf182573b47476
    environment:
      - CONTAINERS=1
      # - EVENTS=1 # uncomment if you need live container start/stop updates
    volumes:
      # Rootless example: /run/user/<UID>/docker.sock
      - ${DOCKER_SOCK:-<ROOTLESS_DOCKER_SOCK>}:/var/run/docker.sock:ro
    networks:
      - proxy
    restart: unless-stopped

  dozzle:
    environment:
      DOCKER_HOST: tcp://docker-socket-proxy:2375
    # Optional: bind locally for debugging
    # ports:
    #   - "${BIND_LOCALHOST:-127.0.0.1}:${HTTP_PORT:-8081}:8080"
```

---

## Network exposure

### Option A — Cloudflare Tunnel

Add the ingress rule to your Cloudflare configuration:

```yaml
ingress:
  - hostname: dozzle.<your-domain>
    service: http://dozzle:8080
  - service: http_status:404
```

Restart the tunnel container:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

### Option B — Reverse proxy (Nginx)

Include a virtual host configuration such as:

```
server {
    server_name dozzle.<your-domain>;
    location / {
        proxy_pass http://dozzle:8080;
        include proxy_params;
    }
}
```

Ensure TLS (Let’s Encrypt) and proper access control (Basic Auth or Cloudflare Access).

---

## Observability

* Dozzle has **no native Prometheus metrics**.
* Recommended integrations:
  * **Uptime Kuma** → HTTP check on the published domain.
  * **Loki / Promtail** → central log aggregation.
* Example alert conditions:
  * `probe_failure{target="dozzle"}`
  * `reverse_proxy_cert_expiry_days < 7`

---

## Security notes

* Never expose Dozzle publicly without authentication.
* Avoid mounting the Docker socket directly in Dozzle; use a socket proxy with minimal endpoints.
* Keep the proxy internal (no published ports) and on a trusted network.
* Keep it isolated within the shared `proxy` network.
* When running rootless Docker, use `<ROOTLESS_DOCKER_SOCK>`.

## Why socket proxy

The Docker API is powerful and effectively grants root-equivalent control over the host.
Using `docker-socket-proxy` limits the exposed endpoints to the minimum Dozzle needs,
reducing blast radius if the container is ever compromised.

If Dozzle is missing live updates when containers start/stop, enable the `EVENTS=1`
endpoint in the proxy. Add other endpoints only when you can justify the need.

---

## Maintenance

```bash
# Status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep dozzle

# Update image and redeploy
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "${STACKS_DIR}/stacks/dozzle/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yml" \
  pull
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "${STACKS_DIR}/stacks/dozzle/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yml" \
  up -d
```

Dozzle does not persist application data — backups are not required.

---

## Observability

Dozzle is also monitored as part of the logging stack:

- The container is labelled with `com.logging="true"` so that Promtail
  picks up its logs and ships them to Loki.
- The `service="dozzle"` label is used as the canonical selector in
  Grafana (Loki datasource), for example:

```logql
{service="dozzle"}
