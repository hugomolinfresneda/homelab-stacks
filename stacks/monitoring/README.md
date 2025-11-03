# Monitoring Stack (Prometheus · Grafana · Loki · Promtail · Blackbox)

This stack provides **metrics + logs + probes** with Docker, split between the **public stacks repo** and your **private runtime**. Images are pinned by **digest**, containers include **healthchecks**, and the base compose keeps things **portable** (no host ports; you only publish what you need via your reverse proxy / tunnel).

**Includes:**

- **Prometheus** — metrics TSDB + scraping
- **Alertmanager** — alert routing (stub config to extend)
- **Grafana** — dashboards (pre-provisioned datasources; dashboards optional)
- **Loki** — log store (boltdb-shipper + filesystem chunks)
- **Promtail** — log shipper (Docker service discovery + stable labels)
- **Blackbox Exporter** — HTTP(S)/ICMP probing
- **Node Exporter** — basic host metrics

---

## 1) Architecture

```
(HTTPS)                           docker network: proxy
Client ──▶ Reverse Proxy / Tunnel ────────────────┐
                                                  │
                                                  ▼
                                            ┌─────────┐
                                            │ Grafana │   (UI; publish if needed)
                                            └─┬─────┬─┘
                                              │     │
                         datasource = Prometheus    │    datasource = Loki
                                              │     │
docker network: monitoring                    │     │
                                              │     │
   ┌───────────────────┐                      │     │        ┌───────────┐
   │    Prometheus     │◄─────────────────────┘     └──────▶ │   Loki    │
   │      (:9090)      │              scrape                 │  (:3100)  │
   └─────────┬─────────┘                                     └─────┬─────┘
             │                                                     │
             │ scrapes                                             │ push logs
             │                                                     │
   ┌─────────▼─────────┐          ┌──────────────┐                 │
   │   Alertmanager    │          │ Blackbox Exp.│ ── /probe ──────┘
   │     (:9093)       │          │   (:9115)    │
   └───────────────────┘          └───────┬──────┘
                                          │
                                  ┌───────▼───────┐
                                  │ Node Exporter │
                                  │    (:9100)    │
                                  └───────────────┘

   ┌───────────┐
   │ Promtail  │   (Docker SD; labels: job, container, compose_service, repo, stack, env)
   │  (:9080)  │ ───────────────────────────────────────────────────────────────▶ Loki
   └───────────┘
```

> **Networks**: `monitoring` (internal) and `proxy` (your reverse proxy/tunnel network). Create them if missing:
>
> ```bash
> docker network create monitoring || true
> docker network create proxy || true
> ```

---

## 2) Repos layout

**Public repo** (e.g., `/opt/homelab-stacks`):
```
stacks/monitoring/
├─ compose.yaml
├─ README.md
├─ alertmanager/
│  └─ alertmanager.yml
├─ blackbox/
│  └─ blackbox.yml
├─ grafana/
│  └─ provisioning/
│     └─ datasources/
│        └─ datasources.yml
├─ loki/
│  └─ config.yaml
├─ prometheus/
│  └─ prometheus.yml
├─ promtail/
│  └─ config.yaml
└─ tools/
   └─ mon     # helper: status, loki-check
```

**Private runtime** (e.g., `/opt/homelab-runtime`):
```
stacks/monitoring/
├─ compose.override.yml
└─ secrets/
   └─ kuma_password
```

---

## 3) Prerequisites

- Docker Engine + **Docker Compose v2**
- External docker networks created: `monitoring`, `proxy`
- **Rootless-friendly binds** for Promtail in your runtime override:
  - `${DOCKER_SOCK}` → usually `/run/user/1000/docker.sock` (rootless) or `/var/run/docker.sock` (rootful)
  - `${DOCKER_CONTAINERS_DIR}` → usually `~/.local/share/docker/containers` (rootless) or `/var/lib/docker/containers` (rootful)
  - `${SELINUX_SUFFIX}` → leave empty unless you need `:Z` on SELinux hosts

---

## 4) Compose files

- **Base (public):** `/opt/homelab-stacks/stacks/monitoring/compose.yaml`
  Pinned digests, healthchecks, no host ports, networks `monitoring` (+ `proxy` for Grafana).
  **Named volumes** (portable, human-friendly names):
  ```yaml
  volumes:
    mon-prom-data:
      name: mon-prom-data
    mon-grafana-data:
      name: mon-grafana-data
    mon-loki-data:
      name: mon-loki-data
    mon-promtail-positions:
      name: mon-promtail-positions
  ```

- **Runtime override (private):** `/opt/homelab-runtime/stacks/monitoring/compose.override.yml`
  ```yaml
  services:
    promtail:
      volumes:
        - ${DOCKER_SOCK}:/var/run/docker.sock:ro${SELINUX_SUFFIX}
        - ${DOCKER_CONTAINERS_DIR}:/var/lib/docker/containers:ro${SELINUX_SUFFIX}
    prometheus:
      secrets:
        - source: kuma_password
          target: uptime-kuma

  secrets:
    kuma_password:
      file: /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
  ```

---

## 5) Uptime Kuma metrics (runtime secret)

Create the secret file in the runtime and make it world-readable:

```bash
mkdir -p /opt/homelab-runtime/stacks/monitoring/secrets
printf '%s
' 'your-kuma-password' > /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
chmod 0444 /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
```

Prometheus job (already present in the public repo):
```yaml
- job_name: 'uptime-kuma'
  metrics_path: /metrics
  static_configs:
    - targets: ['uptime-kuma:3001']
  basic_auth:
    username: admin
    password_file: /run/secrets/uptime-kuma
```

---

## 6) Operations

**Using the runtime Makefile (recommended)**
```bash
make up   stack=monitoring     # start
make ps   stack=monitoring     # status
make logs stack=monitoring     # logs (add: follow=true)
make down stack=monitoring     # stop
```

**Manual compose (portable)**
```bash
docker compose   -f /opt/homelab-stacks/stacks/monitoring/compose.yaml   -f /opt/homelab-runtime/stacks/monitoring/compose.override.yml   up -d
```

---

## 7) Reverse proxy / Tunnel (example: Cloudflare Tunnel)

`cloudflared` example:
```yaml
ingress:
  - hostname: grafana.<your-domain>
    service: http://grafana:3000
  - service: http_status:404
```
Create a CNAME `grafana` → `<TUNNEL_UUID>.cfargotunnel.com` (proxied). Protect with **Access** if public.

---

## 8) Grafana provisioning & dashboards

- **Datasources** are pre-provisioned (`grafana/provisioning/datasources/datasources.yml`):
  - `Prometheus` → `http://prometheus:9090` (uid: `prometheus`, **default**)
  - `Loki` → `http://loki:3100` (uid: `loki`)
- **Dashboards**: none in this commit. Later, add file provisioning:
  ```yaml
  apiVersion: 1
  providers:
    - name: homelab
      type: file
      options:
        path: /etc/grafana/provisioning/dashboards/exported
  ```
  Place JSON files under `grafana/provisioning/dashboards/exported/` and restart Grafana.

---

## 9) Health & smoke tests

**Loki**
```bash
docker run --rm --network monitoring curlimages/curl:8.10.1 -fsS http://loki:3100/ready
docker run --rm --network monitoring curlimages/curl:8.10.1 -G -sS   --data-urlencode 'query=count_over_time({job="dockerlogs"}[5m])'   http://loki:3100/loki/api/v1/query | jq -r '.data.result[0].value[1]'
```

**Promtail**
```bash
docker run --rm --network monitoring curlimages/curl:8.10.1 -fsS   http://promtail:9080/metrics | grep -E 'promtail_targets_active|promtail_entries_(total|dropped_total)'
```

**Prometheus / Blackbox**
```bash
docker run --rm --network monitoring curlimages/curl:8.10.1 -fsS http://prometheus:9090/-/ready
docker run --rm --network monitoring curlimages/curl:8.10.1 -fsS http://blackbox:9115/ | head
```

---

## 10) LogQL quick cheatsheet (Loki)

Raw logs:
```logql
{job="dockerlogs"}
```

Parse Docker JSON:
```logql
{job="dockerlogs"} | logfmt
```

Rate by container (Explore → Metrics):
```logql
sum by (container) (rate({job="dockerlogs"}[$__interval]))
```

Top 5 chatty services (Explore → Metrics):
```logql
topk(5, sum by (compose_service) (rate({job="dockerlogs"}[$__rate_interval])))
```

Find a marker inside promtail logs:
```logql
{job="dockerlogs", container="promtail"} |= "LOKI_SMOKE_"
```

---

## 11) Notes on Promtail config

The shipped config (`promtail/config.yaml`) uses **Docker service discovery** and applies a minimal label set that matches the dashboards:
- `job="dockerlogs"` (constant), `container`, `compose_service`, `repo`, `stack`, `env`, `host`
- `__path__` from container ID → `/var/lib/docker/containers/<id>/<id>-json.log`
- `pipeline_stages: docker: {}` parses Docker JSON
We intentionally **avoid** a blanket `labelmap` to keep streams small and prevent Loki `400` on “too many labels”.

---

## 12) Backups (what to keep)

- **Prometheus TSDB:** `mon-prom-data`
- **Grafana:** `mon-grafana-data`
- **Loki:** `mon-loki-data`
- **Promtail positions:** `mon-promtail-positions`

Ad-hoc archive:
```bash
for v in mon-prom-data mon-grafana-data mon-loki-data mon-promtail-positions; do
  docker run --rm -v ${v}:/vol -v "$PWD":/backup busybox tar czf /backup/${v}.tgz -C /vol .
done
```

---

## 13) Updates (safe flow)

1. Ensure a recent backup of the volumes above.
2. When ready, bump image **digests** in `compose.yaml` (dedicated PR).
3. Redeploy:
   ```bash
   make up stack=monitoring
   ```
4. Validate: Grafana loads, Loki has recent data, Prometheus targets `UP`.

---

## 14) Quick start (TL;DR)

```bash
# 0) Networks (once)
docker network create monitoring || true
docker network create proxy || true

# 1) Runtime secret for Uptime Kuma
mkdir -p /opt/homelab-runtime/stacks/monitoring/secrets
printf '%s
' 'your-kuma-password' > /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
chmod 0444 /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password

# 2) Up
make up stack=monitoring
make ps stack=monitoring

# 3) Sanity checks
docker run --rm --network monitoring curlimages/curl:8.10.1 -fsS http://loki:3100/ready
docker run --rm --network monitoring curlimages/curl:8.10.1 -G -sS   --data-urlencode 'query=count_over_time({job="dockerlogs"}[5m])'   http://loki:3100/loki/api/v1/query | jq -r '.data.result[0].value[1]'
```

---

**Done.** Portable monitoring with sane defaults, reproducible images, and a clean split between public and runtime.
