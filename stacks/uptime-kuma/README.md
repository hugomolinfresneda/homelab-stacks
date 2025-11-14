# Uptime Kuma — Self-hosted monitoring & status page

Uptime Kuma provides a clean interface for monitoring the availability of your self-hosted services and public endpoints.

This stack follows the **two-repository architecture** of the homelab:

- **homelab-stacks** → public base definitions (no secrets, reusable).
- **homelab-runtime** → private overrides, environment, and persistent data.

---

## Repository structure

| Repository          | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation). |
| **homelab-runtime** | Private overrides (`compose.override.yml`, `.env`, persistent data).    |

---

## Requirements

- Docker + Compose plugin
- Shared external networks:

  ```bash
  docker network create proxy   || true
  docker network create mon-net || true
  ```

- Target environment: **Debian rootless Docker**
  Adjust `DOCKER_SOCK` or volume paths if you use rootful mode.

Uptime Kuma attaches to both `proxy` (for HTTP ingress through your reverse proxy or tunnel) and `mon-net` so that the monitoring stack (Prometheus) can reach its `/metrics` endpoint.

---

## File layout

```
/opt/homelab-stacks/stacks/uptime-kuma/
├── compose.yaml
├── .env.example
└── README.md

/opt/homelab-runtime/stacks/uptime-kuma/
├── compose.override.yml
├── .env
└── data/
```

---

## Environment configuration

Copy the environment file to the runtime path:

```bash
cp /opt/homelab-stacks/stacks/uptime-kuma/.env.example    /opt/homelab-runtime/stacks/uptime-kuma/.env
```

Example:

```dotenv
TZ=Europe/Madrid
# BIND_LOCALHOST=127.0.0.1
# HTTP_PORT=3001
```

---

## Deployment (Makefile shortcuts)

From the runtime repository root:

```bash
make up   stack=uptime-kuma    # deploy the stack
make ps   stack=uptime-kuma    # show container status
make down stack=uptime-kuma    # stop and remove the stack
```

Example output:

```text
🚀 Starting runtime stack 'uptime-kuma'...
[+] Running 1/1
 ✔ Container uptime-kuma  Started

NAME          STATUS                   PORTS
uptime-kuma   Up (healthy)             3001/tcp
```

---

## Manual deployment (portable method)

If you’re not using the Makefile helper:

```bash
docker compose   --env-file /opt/homelab-runtime/stacks/uptime-kuma/.env   -f /opt/homelab-stacks/stacks/uptime-kuma/compose.yaml   -f /opt/homelab-runtime/stacks/uptime-kuma/compose.override.yml   up -d
```

---

## Runtime override

```yaml
services:
  uptime-kuma:
    volumes:
      - /opt/homelab-runtime/stacks/uptime-kuma/data:/app/data
    # Optional bind for local access
    # ports:
    #   - "${BIND_LOCALHOST:-127.0.0.1}:${HTTP_PORT:-3001}:3001"
```

The runtime override is responsible for:

- Persisting application data on the host.
- Optionally binding the HTTP port to localhost only for direct browser access.

---

## Network exposure

### Option A — Cloudflare Tunnel

Add the rule in `/opt/homelab-runtime/systemd/cloudflared/config.yml`:

```yaml
ingress:
  - hostname: uptime-kuma.<your-domain>
    service: http://uptime-kuma:3001
  - service: http_status:404
```

Restart:

```bash
STACK=cloudflared make restart
```

### Option B — Reverse proxy (Nginx)

```nginx
server {
    server_name uptime-kuma.<your-domain>;
    location / {
        proxy_pass http://uptime-kuma:3001;
        include proxy_params;
    }
}
```

---

## Data persistence

Application data is stored under:

```text
/opt/homelab-runtime/stacks/uptime-kuma/data/
```

Include this path in your backup rotation.

---

## Prometheus metrics integration

Uptime Kuma can expose a Prometheus-compatible `/metrics` endpoint, protected with HTTP basic auth.
The monitoring stack scrapes this endpoint and feeds Grafana dashboards.

### 1) Enable metrics in Uptime Kuma

In the Uptime Kuma UI:

1. Go to **Settings → Advanced → Prometheus metrics**.
2. Enable the feature and set a strong password.
3. Leave the username empty (we authenticate with the password only).
4. Save changes.

The endpoint will be available at:

```text
http://uptime-kuma:3001/metrics
```

from within the `mon-net` network.

### 2) Runtime password file (used by Prometheus)

On the monitoring side, the password is stored in a simple file in the runtime repo:

```bash
mkdir -p /opt/homelab-runtime/stacks/monitoring/secrets
printf '%s
' 'the-same-password-you-set-in-kuma'   > /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
chmod 0444 /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
```

The monitoring stack’s runtime override mounts this file into Prometheus:

```yaml
services:
  prometheus:
    volumes:
      - /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password:/etc/prometheus/secrets/kuma_password:ro
```

### 3) Prometheus scrape job (defined in the monitoring stack)

The corresponding Prometheus job lives in the monitoring stack:

```yaml
- job_name: 'uptime-kuma'
  scrape_interval: 30s
  metrics_path: /metrics
  static_configs:
    - targets:
        - 'uptime-kuma:3001'
      labels:
        stack: monitoring
        service: uptime-kuma
        env: home
  basic_auth:
    username: ""
    password_file: /etc/prometheus/secrets/kuma_password
```

Once this is in place and the monitoring stack is running, you should see:

- Target `uptime-kuma` **UP** in Prometheus (`Status → Targets`).
- Metrics such as `monitor_status` and `monitor_response_time` available in the Prometheus UI and Grafana.

---

## Observability

Once Uptime Kuma is online and metrics are exposed:

- Add monitors for key services:

  - Nextcloud
  - CouchDB
  - Dozzle
  - Uptime Kuma itself
  - Gateway / Internet reachability (ICMP)
  - Backup jobs (Push monitors for Nextcloud and Restic)

- The monitoring stack’s Grafana dashboard:

  - `Uptime Kuma – Service and Backup Status`

  consumes `monitor_status` and `monitor_response_time` to provide:

  - A high-level view of monitor UP vs DOWN.
  - HTTP response time per monitored service.
  - Tables for public-facing services, infrastructure checks, and backup monitors.

This keeps **health, latency and backup status** in a single place, while leaving Uptime Kuma as the source of truth for availability and alerts.

---

## Security notes

- Keep the service within the `proxy` and `mon-net` networks; avoid exposing container ports directly to the Internet.
- Protect external access to the Uptime Kuma UI with Cloudflare Access, HTTP authentication, or a VPN.
- Restrict Prometheus metrics access to internal networks only (no direct Internet exposure of `/metrics`).
