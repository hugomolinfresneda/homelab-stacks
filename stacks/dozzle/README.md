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
/opt/homelab-stacks/stacks/dozzle/
├── compose.yaml
├── .env.example
└── README.md

/opt/homelab-runtime/stacks/dozzle/
├── compose.override.yml
└── .env
```

---

## Environment configuration

Copy the example environment file from the stacks repository into the runtime path:

```bash
cp /opt/homelab-stacks/stacks/dozzle/.env.example \
   /opt/homelab-runtime/stacks/dozzle/.env
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
  --env-file ./.env \
  -f /opt/homelab-stacks/stacks/dozzle/compose.yaml \
  -f compose.override.yml \
  up -d

docker compose \
  --env-file ./.env \
  -f /opt/homelab-stacks/stacks/dozzle/compose.yaml \
  -f compose.override.yml \
  ps
```

**Recommended `compose.override.yml`:**

```yaml
services:
  dozzle:
    volumes:
      # Rootless example: /run/user/<UID>/docker.sock
      - ${DOCKER_SOCK:-<ROOTLESS_DOCKER_SOCK>}:/var/run/docker.sock:ro
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
* Mount the Docker socket **read-only**.
* Keep it isolated within the shared `proxy` network.
* When running rootless Docker, use `<ROOTLESS_DOCKER_SOCK>`.

---

## Maintenance

```bash
# Status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep dozzle

# Update image and redeploy
docker compose \
  --env-file ./.env \
  -f /opt/homelab-stacks/stacks/dozzle/compose.yaml \
  -f compose.override.yml \
  pull
docker compose \
  --env-file ./.env \
  -f /opt/homelab-stacks/stacks/dozzle/compose.yaml \
  -f compose.override.yml \
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
