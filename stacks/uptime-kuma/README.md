# Uptime Kuma — Self-hosted monitoring & status page

Uptime Kuma provides a clean interface for monitoring the availability of your self-hosted services and public endpoints.

This stack follows the **two-repository architecture** of the homelab:

* **homelab-stacks** → public base definitions (no secrets, reusable).
* **homelab-runtime** → private overrides, environment, and persistent data.

---

## Repository structure

| Repository          | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation). |
| **homelab-runtime** | Private overrides (`compose.override.yml`, `.env`, persistent data).    |

---

## Requirements

* Docker + Compose plugin
* Shared external networks:

  ```bash
  docker network create proxy || true
  docker network create monitoring || true
  ```
* Target environment: **Debian rootless Docker**
  Adjust `DOCKER_SOCK` or volume paths if you use rootful mode.

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
cp /opt/homelab-stacks/stacks/uptime-kuma/.env.example \
   /opt/homelab-runtime/stacks/uptime-kuma/.env
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
make up stack=uptime-kuma       # deploy the stack
make ps stack=uptime-kuma       # show container status
make down stack=uptime-kuma     # stop and remove the stack
```

Example output:

```
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
docker compose \
  --env-file /opt/homelab-runtime/stacks/uptime-kuma/.env \
  -f /opt/homelab-stacks/stacks/uptime-kuma/compose.yaml \
  -f /opt/homelab-runtime/stacks/uptime-kuma/compose.override.yml \
  up -d
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

```
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

```
/opt/homelab-runtime/stacks/uptime-kuma/data/
```

Include this path in your backup rotation.

---

## Maintenance

```bash
# Status
make ps stack=uptime-kuma

# Update image and redeploy
make pull stack=uptime-kuma
make up stack=uptime-kuma
```

---

## Observability

Once running, add monitors for:

* Dozzle
* Cloudflared
* Nextcloud
* Proxy endpoints

and enable TLS certificate expiry alerts.

---

## Security notes

* Keep the service within the `proxy` network.
* Avoid exposing ports publicly unless testing locally.
* Protect external access with Cloudflare Access or Basic Auth.
