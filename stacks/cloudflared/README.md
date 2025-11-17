# Cloudflare Tunnel — Outbound reverse proxy (CGNAT-friendly)

This stack establishes a persistent Cloudflare Tunnel to expose your internal Docker services (e.g. Dozzle, Uptime Kuma, Nextcloud) securely **without opening ports** on your router.

It runs a minimal container (`cloudflare/cloudflared`) that maintains outbound connections to Cloudflare’s edge.

---

## Architecture

| Repository          | Purpose                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation).                  |
| **homelab-runtime** | Private overrides (`compose.override.yml`, `.env`, real `config.yml`, credentials JSON). |

---

## File layout

```
/opt/homelab-stacks/stacks/cloudflared/
├── compose.yaml
└── README.md

/opt/homelab-runtime/stacks/cloudflared/
├── compose.override.yml
├── .env
└── cloudflared/config.yml
/srv/secrets/cloudflared/<UUID>.json
```

---

## Requirements

* A **Cloudflare account** with a domain already added to Cloudflare.
* One created **Tunnel ID (UUID)** and its **JSON credential** file.
* Shared Docker network:

  ```bash
  docker network create proxy || true
  ```
* Debian host (rootless Docker supported).

---

## Runtime configuration

Example `/opt/homelab-runtime/stacks/cloudflared/cloudflared/config.yml`:

```yaml
tunnel: 41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46
credentials-file: /etc/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json

ingress:
  - hostname: dozzle.atardecer-naranja.es
    service: http://dozzle:8080
  - hostname: uptime-kuma.atardecer-naranja.es
    service: http://uptime-kuma:3001
  - hostname: cloud.atardecer-naranja.es
    service: http://nc-web:8080
  - service: http_status:404
```

The JSON credential lives outside the repo:

```
/srv/secrets/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json
```

Set permissions once:

```bash
sudo mkdir -p /srv/secrets/cloudflared
sudo mv ~/.cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json /srv/secrets/cloudflared/
sudo chmod 700 /srv/secrets/cloudflared
sudo chmod 644 /srv/secrets/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json
sudo chown 65532:65532 /srv/secrets/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json
```

---

## Deployment (Makefile shortcuts)

From the runtime repository:

```bash
make up stack=cloudflared     # deploy tunnel
make ps stack=cloudflared     # show status
make logs stack=cloudflared   # view tunnel logs
```

Expected log output:

```
Connected to Cloudflare edge
Registered tunnel connection
```

---

## Manual deploy (portable method)

```bash
docker compose \
  --env-file /opt/homelab-runtime/stacks/cloudflared/.env \
  -f /opt/homelab-stacks/stacks/cloudflared/compose.yaml \
  -f /opt/homelab-runtime/stacks/cloudflared/compose.override.yml \
  up -d
```

---

## Creating the CNAMEs (via Cloudflare dashboard)

Each `hostname:` in your `config.yml` must have a **DNS CNAME** record in Cloudflare pointing to the tunnel.

1. Open [dash.cloudflare.com](https://dash.cloudflare.com) → your domain → **DNS → Records**
2. Create one CNAME per service:

| Type  | Name          | Target                                                  | Proxy Status |
| ----- | ------------- | ------------------------------------------------------- | ------------ |
| CNAME | `dozzle`      | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |
| CNAME | `uptime-kuma` | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |
| CNAME | `cloud`       | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |
| CNAME | `couchdb`     | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |

3. Save changes.
   No TTL or proxy tweaks needed — Cloudflare handles routing automatically.

To verify:

```bash
dig +short dozzle.atardecer-naranja.es
```

Should return:

```
41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com.
```

---

## Add new services

1. Add the rule in your `config.yml`:

   ```yaml
   - hostname: newapp.atardecer-naranja.es
     service: http://newapp:port
   ```
2. Create the CNAME in Cloudflare’s **DNS → Records**,
   pointing to your `<UUID>.cfargotunnel.com`.
3. Restart the tunnel:

   ```bash
   make restart stack=cloudflared
   ```

---

## Troubleshooting

| Symptom                           | Likely cause                                                  |
| --------------------------------- | ------------------------------------------------------------- |
| Crash-loop or `permission denied` | Wrong path or perms on `/srv/secrets/cloudflared/<UUID>.json` |
| 404 from Cloudflare               | Missing or wrong `ingress` rule                               |
| Connection refused                | Target container not in `proxy` network                       |
| Host not resolving                | Missing CNAME record in Cloudflare                            |

---

## Security notes

* Never version the JSON credential file.
* Do **not** expose ports 80/443.
* Keep the `proxy` network shared among your web services.
* Cloudflare handles TLS and authentication at the edge.

---

## Maintenance

```bash
# Update image and redeploy
make pull stack=cloudflared
make up stack=cloudflared

# View logs
make logs stack=cloudflared
```

---

## Metrics & monitoring integration

This tunnel stack is designed to integrate tightly with the monitoring stack
(`stacks/monitoring`). The `cloudflared` container exposes Prometheus metrics
on an internal port and joins the monitoring network so that Prometheus can
scrape it directly.

### Container wiring

The base compose (`stacks/cloudflared/compose.yaml`) starts the tunnel with:

```yaml
services:
  cloudflared:
    command: >
      tunnel --config /etc/cloudflared/config.yml --metrics 0.0.0.0:8081 run
    networks:
      - proxy
      - mon-net
```

Key points:

- The `--metrics 0.0.0.0:8081` flag enables the `/metrics` endpoint inside
  the container. **No host port is published**; metrics are only reachable
  from Docker networks.
- The service joins both `proxy` (for talking to internal apps such as
  Dozzle, Uptime Kuma, Nextcloud…) and `mon-net` (so Prometheus can reach
  `cloudflared:8081`). Both networks are created as external networks, so
  they can be shared across stacks.

In the runtime override (`homelab-runtime/stacks/cloudflared/compose.override.yml`)
you still mount your real `config.yml` and credentials JSON; the metrics wiring
remains unchanged.

### Prometheus job (monitoring stack)

The monitoring stack defines a dedicated job to scrape the tunnel metrics
from `mon-net`:

```yaml
# stacks/monitoring/prometheus/prometheus.yml

- job_name: 'cloudflared'
  scrape_interval: 30s
  metrics_path: /metrics
  static_configs:
    - targets:
        - 'cloudflared:8081'
      labels:
        stack: proxy
        service: cloudflared
        env: home
```

This follows the same labelling model as the rest of the homelab:

- `stack="proxy"` — this tunnel belongs to the reverse-proxy / ingress layer.
- `service="cloudflared"` — used in Grafana dashboards and alerts.
- `env="home"` — environment tag; adjust if you run multiple environments.

### Alerting rules

Prometheus alert rules for the tunnel live in:

- `stacks/monitoring/prometheus/rules/cloudflared.rules.yml`

Current rules:

- **CloudflaredDown** — fires when `up{job="cloudflared"} == 0` for more than 2 minutes.
- **CloudflaredHighErrorRate** — fires when the percentage of failed requests
  through the tunnel stays above 5% for 10 minutes, based on the
  `cloudflared_tunnel_request_errors` and `cloudflared_tunnel_total_requests`
  counters exported by the container.

These rules are labelled with `stack="proxy"`, `service="cloudflared"` and
`env="home"` for consistent routing and dashboard filtering.

### Grafana dashboards & logs

The monitoring stack provides a dedicated Grafana dashboard:

- **Cloudflared – Tunnel Overview**

It surfaces at a glance:

- Current tunnel status (`up{job="cloudflared"}`).
- 24-hour success rate (percentage of successful requests).
- Edge connections and QUIC RTT.
- Requests per second and error rate (%).
- Active TCP / UDP sessions.
- A log panel filtered to `service="cloudflared"` with only error-level lines.

Logs are ingested by Promtail from the Docker JSON logs for the
`cloudflared` container. The container is labelled with `com.logging="true"`
and `service="cloudflared"`, so log streams arrive in Loki with
`job="dockerlogs", service="cloudflared"` and can be joined conceptually
with the metrics above in Grafana.

In practice, this gives you a full observability loop for the tunnel:
**status → SLO → error spikes → logs** in a single place.
