# Monitoring Stack (Prometheus · Grafana · Loki · Promtail · Blackbox)

This stack provides **metrics + logs + probes** with Docker, split between the **public stacks repo** and your **private runtime**. Images are pinned by **digest**, containers include **healthchecks**, and the base compose keeps things **portable** (no host ports; you only publish what you need via your reverse proxy / tunnel).

**Includes:**

- **Prometheus** — metrics TSDB + scraping
- **Alertmanager** — alert routing (stub config to extend)
- **Grafana** — dashboards (pre-provisioned datasources; dashboards provisioned from JSON files)
- **Loki** — log store (boltdb-shipper + filesystem chunks)
- **Promtail** — log shipper (Docker service discovery + stable labels)
- **Blackbox Exporter** — HTTP(S) / ICMP / DNS probing
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
                                            └───┬─────┘
                                                │
                    ┌───────────────────────────┼───────────────────────────┐
                    │                           │                           │
                    │   datasource → Prometheus │   datasource → Loki       │
                    │                           │                           │
docker network: mon-net                         │                           │
                                                │                           │
   ┌───────────────────┐                        │                           │
   │    Prometheus     │                        │                    ┌──────▼──────┐
   │      (:9090)      │                        │                    │    Loki     │
   └─────────┬─────────┘                        │                    │   (:3100)   │
             │                                  │                    └─────────────┘
             │ scrapes                          │
             │                                  │
   ┌─────────▼─────────┐           ┌────────────┴─┐
   │   Alertmanager    │           │ Blackbox Exp.│ ── /probe
   │     (:9093)       │           │   (:9115)    │
   └───────────────────┘           └───────┬──────┘
                                           │
                                   ┌───────▼───────┐
                                   │ Node Exporter │
                                   │    (:9100)    │
                                   └───────────────┘

   ┌───────────┐
   │ Promtail  │   (Docker SD; labels: job, container, container_name, compose_service, repo, stack, env, service)
   │  (:9080)  │ ───────────────────────────────────────────────────────────────▶ Loki
   └───────────┘
```

> **Networks**: `mon-net` (internal monitoring network) and `proxy` (reverse proxy / tunnel network). Create them if missing:
>
> ```bash
> docker network create mon-net || true
> docker network create proxy   || true
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
│  ├─ provisioning/
│  │  └─ datasources/
│  │     └─ datasources.yml
│  └─ dashboards/
│     └─ exported/
│        └─ mon/
│           └─ 30_status-incidences/
│              └─ uptime-kuma-service-backup-status.json
├─ loki/
│  └─ config.yaml
├─ prometheus/
│  ├─ prometheus.yml
│  ├─ adguard-exporter.yml.example
│  └─ rules/
│     ├─ adguard.rules.yml
│     └─ couchdb.rules.yml
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
- External docker networks created: `mon-net`, `proxy`
- **Rootless-friendly binds** for Promtail in your runtime override:
  - `${DOCKER_SOCK}` → usually `/run/user/1000/docker.sock` (rootless) or `/var/run/docker.sock` (rootful)
  - `${DOCKER_CONTAINERS_DIR}` → usually `~/.local/share/docker/containers` (rootless) or `/var/lib/docker/containers` (rootful)
  - `${SELINUX_SUFFIX}` → leave empty unless you need `:Z` on SELinux hosts

---

## 4) Compose files

- **Base (public):** `/opt/homelab-stacks/stacks/monitoring/compose.yaml`
  Pinned digests, healthchecks, no host ports, networks `mon-net` (+ `proxy` for Grafana).

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
      volumes:
        - /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password:/etc/prometheus/secrets/kuma_password:ro
  ```

  The Promtail volumes give it access to Docker logs in both rootless and rootful setups.
  The Prometheus volume injects the Uptime Kuma metrics password as a plain read-only file, avoiding Docker Swarm secrets for maximum portability on single-node homelab deployments.

---

## 5) Uptime Kuma metrics (runtime password file)

Prometheus scrapes Uptime Kuma’s `/metrics` endpoint using HTTP basic auth.
The username is deliberately left empty; authentication is performed via the password file only.

Create the password file in the runtime and make it world-readable (inside the container it is mounted read-only):

```bash
mkdir -p /opt/homelab-runtime/stacks/monitoring/secrets
printf '%s
' 'your-kuma-password' > /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
chmod 0444 /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
```

Prometheus job (present in the public repo):

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

Key metrics:

- `monitor_status` — per-monitor UP/DOWN state.
- `monitor_response_time` — HTTP response time per monitor.
- Global count of UP/DOWN monitors for high-level status views.

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

Example `cloudflared` config:

```yaml
ingress:
  - hostname: grafana.<your-domain>
    service: http://grafana:3000
  - service: http_status:404
```

Create a CNAME `grafana` → `<TUNNEL_UUID>.cfargotunnel.com` (proxied). Protect with **Access** if exposing publicly.

---

## 8) Grafana provisioning & dashboards

- **Datasources** are pre-provisioned (`grafana/provisioning/datasources/datasources.yml`):

  - `Prometheus` → `http://prometheus:9090` (uid: `prometheus`, **default**)
  - `Loki` → `http://loki:3100` (uid: `loki`)

- **Dashboards** are provisioned from JSON files under the exported dashboards tree:

  Host-side path:

  ```
  stacks/monitoring/grafana/dashboards/exported/mon/30_status-incidences/uptime-kuma-service-backup-status.json
  ```

  This dashboard provides:

  - Global UP/DOWN count for all Uptime Kuma monitors.
  - HTTP response time per monitored HTTP endpoint.
  - Status tables for public-facing services (Nextcloud, CouchDB, Dozzle, Uptime Kuma).
  - Status of backup jobs (Nextcloud application backup + Restic repository backup).
  - Infra checks for gateway and Internet reachability.

  Example file provider for Grafana:

  ```yaml
  apiVersion: 1
  providers:
    - name: homelab
      type: file
      options:
        path: /etc/grafana/provisioning/dashboards/exported
  ```

  Bind `stacks/monitoring/grafana/dashboards/exported` from the host into `/etc/grafana/provisioning/dashboards/exported` in the Grafana container and restart Grafana to have the dashboard automatically available.

---

## 9) Health & smoke tests

**Loki**

```bash
docker run --rm --network mon-net curlimages/curl:8.10.1 -fsS http://loki:3100/ready

docker run --rm --network mon-net curlimages/curl:8.10.1 -G -sS   --data-urlencode 'query=count_over_time({job="dockerlogs"}[5m])'   http://loki:3100/loki/api/v1/query | jq -r '.data.result[0].value[1]'
```

**Promtail**

```bash
docker run --rm --network mon-net curlimages/curl:8.10.1 -fsS   http://promtail:9080/metrics | grep -E 'promtail_targets_active|promtail_entries_(total|dropped_total)'
```

**Prometheus / Blackbox**

```bash
docker run --rm --network mon-net curlimages/curl:8.10.1 -fsS http://prometheus:9090/-/ready
docker run --rm --network mon-net curlimages/curl:8.10.1 -fsS http://blackbox:9115/ | head
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

The shipped config (`promtail/config.yaml`) uses **Docker service discovery** and ingests
Docker container logs into Loki with a small, explicit label set that matches the dashboards.

**Discovery**

- Uses `docker_sd` against `unix:///var/run/docker.sock`. The Docker socket is mounted
  into the `mon-promtail` container by the monitoring stack, so Promtail can discover
  running containers even in a rootless Docker setup.

**Selection**

- Only containers explicitly labelled with `com.logging="true"` are kept. This makes
  log ingestion an **opt-in** decision and avoids pulling noise from auxiliary or
  transient containers by default.

**Labelling model**

Promtail normalises a small number of labels that are used consistently across queries
and dashboards:

- `job="dockerlogs"` — constant for all Docker-based streams.
- `container` and `container_name` — derived from the Docker container name (without
  the leading slash).
- `repo`, `stack`, `env`, `compose_service` — derived from existing container labels
  (`com.repo`, `com.stack`, `com.env`, `com.docker_compose_service`).
- `service` — derived from the container label `service` (for example `service="dozzle"`);
  this is the canonical join key between logs and metrics in Grafana.
- `host` — populated from the container hostname where available.
- `__path__` — derived from the container ID and pointing at the underlying Docker log file:
  `/var/lib/docker/containers/<id>/<id>-json.log`.

Promtail also uses the `docker` pipeline stage (`pipeline_stages: docker: {}`) to parse
Docker JSON log lines into structured fields. Combined with the explicit label mapping,
this keeps streams small, queries predictable and avoids excessive label cardinality
in Loki.

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

4. Validate:

   - Grafana loads and datasources are healthy.
   - Loki has recent data.
   - Prometheus targets are `UP`.

---

## 14) Quick start (TL;DR)

```bash
# 0) Networks (once)
docker network create mon-net || true
docker network create proxy   || true

# 1) Runtime password file for Uptime Kuma
mkdir -p /opt/homelab-runtime/stacks/monitoring/secrets
printf '%s
' 'your-kuma-password' > /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password
chmod 0444 /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password

# 2) Up the monitoring stack
make up stack=monitoring
make ps stack=monitoring

# 3) Sanity checks
docker run --rm --network mon-net curlimages/curl:8.10.1 -fsS http://loki:3100/ready

docker run --rm --network mon-net curlimages/curl:8.10.1 -G -sS   --data-urlencode 'query=count_over_time({job="dockerlogs"}[5m])'   http://loki:3100/loki/api/v1/query | jq -r '.data.result[0].value[1]'
```

---

## 15) Demo mode (isolated **demo-** stack)

Run a full, self-contained demo without touching your runtime secrets. The demo uses **container/volume/network prefixes `demo-*`** and stops the base stack first to avoid port conflicts.

**What’s included**

- **Prometheus (demo)** scraping public targets:
  - `https://example.org`
  - `https://httpstat.us/200`
  - `https://example.com`
  - ICMP pings `1.1.1.1` and `8.8.8.8`
- **Loki + Promtail** with a **logspammer** (1 line/sec) for instant logs.
- **Alertmanager (demo)** “blackhole” (UI visible, no external notifiers).
- Optional **Grafana bind** to `127.0.0.1:3003` (controlled by the demo compose files).

**Naming conventions (demo)**

- Containers: `demo-*`
- Network: `demo-net`
- Volumes: `demo-grafana-data`, `demo-loki-data`, `demo-promtail-positions`

**Demo env file**

The demo composes use the same `DOCKER_SOCK`, `DOCKER_CONTAINERS_DIR`, `SELINUX_SUFFIX` variables as the runtime.
Create `.env.demo` at the repo root if you need rootless paths:

```dotenv
# .env.demo (example rootless)
DOCKER_SOCK=/run/user/1000/docker.sock
DOCKER_CONTAINERS_DIR=/home/<user>/.local/share/docker/containers
SELINUX_SUFFIX=
```

**Makefile.demo targets**

```bash
# Validate combined compose for demo (syntax & interpolation)
make -f Makefile.demo demo-config

# Stop base stack (mon-*) and bring up demo (demo-*)
make -f Makefile.demo demo-up

# List demo services
make -f Makefile.demo demo-ps

# Reload Prometheus in demo (SIGHUP)
make -f Makefile.demo demo-reload-prom

# Tear down demo and clean volumes/network
make -f Makefile.demo demo-down
```

**Demo targets helper (requires `yq` v4)**

```bash
make -f Makefile.demo ls-targets-demo JOB=blackbox-http
make -f Makefile.demo add-target-demo JOB=blackbox-http TARGET=http://127.0.0.1:65535
make -f Makefile.demo rm-target-demo  JOB=blackbox-http TARGET=http://127.0.0.1:65535
```

**Notes & pitfalls**

- If you previously ran the demo and see `... name already in use ...`, run `make -f Makefile.demo demo-down` to clean leftovers.
- For **rootless Docker**, ensure `.env.demo` points to your user’s `docker.sock` and `containers` path; otherwise Promtail cannot read Docker logs.
- Demo does **not** require any secrets.

---

## 16) Blackbox targets manager (script + Makefile)

Manage the HTTP/ICMP probe target lists that Prometheus scrapes via **Blackbox Exporter**.

The helper uses containerized **yq** and **promtool**, so you only need Docker on the host.
Changes are **idempotent** (deduplicate + sort) and validated with `promtool`.

### 16.1 Direct script usage

```bash
# Main stack (mon-)
stacks/monitoring/scripts/blackbox-targets.sh ls [blackbox-http]

stacks/monitoring/scripts/blackbox-targets.sh add blackbox-http https://example.org

stacks/monitoring/scripts/blackbox-targets.sh rm  blackbox-http https://example.org
```

**Demo stack** (isolated `demo-*` services):

```bash
stacks/monitoring/scripts/blackbox-targets.sh --demo ls
stacks/monitoring/scripts/blackbox-targets.sh --demo add blackbox-http https://httpstat.us/200
stacks/monitoring/scripts/blackbox-targets.sh --demo rm  blackbox-http https://httpstat.us/200
```

**Explicit file selection** (advanced):

```bash
stacks/monitoring/scripts/blackbox-targets.sh   --file stacks/monitoring/prometheus/prometheus.yml   add blackbox-http https://cloudflare.com
```

After a change the script runs `promtool check config`.
To apply the new targets, reload Prometheus:

```bash
make reload-prom         # main stack
make demo-reload-prom    # demo stack
```

> SELinux: if enforcing, the script automatically uses `:Z` on bind mounts.

### 16.2 Makefile wrappers (easier)

These delegate to the script above and pick the right file automatically:

```bash
# Main stack (mon-)
make bb-ls                 [JOB=blackbox-http]
make bb-add  TARGET=<url>  [JOB=blackbox-http]
make bb-rm   TARGET=<url>  [JOB=blackbox-http]
make reload-prom

# Demo stack (demo-)
make bb-ls-demo            [JOB=blackbox-http]
make bb-add-demo TARGET=<url>  [JOB=blackbox-http]
make bb-rm-demo  TARGET=<url>  [JOB=blackbox-http]
make demo-reload-prom
```

**Examples**

```bash
make bb-ls
make bb-add TARGET=https://cloudflare.com
make reload-prom

make bb-ls-demo
make bb-add-demo TARGET=https://example.com
make demo-reload-prom
```

**Notes**

- Jobs must already exist in the Prometheus config (see `stacks/monitoring/prometheus/*.yml`).
- The helper ensures the `static_configs[0].targets` list exists, appends the target, runs `unique | sort`, and writes back safely.
- If you see `error: no prometheus.(yml|yaml)…`, check the files exist in `stacks/monitoring/prometheus/`.

---

## 17) AdGuard DNS monitoring (exporter + blackbox)

The monitoring stack integrates **AdGuard Home** as a first-class DNS service, using both **direct metrics** and **end-to-end probes**.

### 17.1 Prometheus scrape jobs

Two jobs are responsible for AdGuard visibility:

```yaml
# AdGuard exporter (metrics via ebrianne/adguard-exporter)
- job_name: 'adguard-exporter'
  scrape_interval: 15s
  static_configs:
    - targets:
        - 'adguard-exporter:9617'

# AdGuard DNS resolution (blackbox → AdGuard)
- job_name: 'blackbox-dns'
  metrics_path: /probe
  params:
    module: [dns_udp]
  static_configs:
    - targets:
        - 'adguard-home:53'
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target   # target = DNS server under test
    - source_labels: [__address__]
      target_label: instance
    - target_label: __address__
      replacement: blackbox:9115     # blackbox exporter endpoint
```

These jobs live in:

- `stacks/monitoring/prometheus/prometheus.yml`

and follow the same label conventions used elsewhere in the homelab:

- `job="adguard-exporter"` and `job="blackbox-dns"`
- `stack="dns"`, `service="adguard-home"`, `env="home"` (used consistently in alerting rules and dashboards)

A reusable template for the exporter scrape job is also provided as:

- `stacks/monitoring/prometheus/adguard-exporter.yml.example`

This file mirrors the `adguard-exporter` job in `prometheus.yml` and can be used as a starting point for other environments or as a snippet in more complex setups.

---

### 17.2 Blackbox DNS module

DNS probing uses the dedicated `dns_udp` module shipped with Blackbox:

```yaml
modules:
  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      transport_protocol: "udp"
      preferred_ip_protocol: "ip4"
      query_name: "www.google.com"
      query_type: "A"
      valid_rcodes: ["NOERROR"]
```

The AdGuard DNS job (`blackbox-dns`) configures:

- `module=dns_udp`
- `target=adguard-home:53`

so that each probe resolves `www.google.com` **through AdGuard**, while Prometheus collects the result via Blackbox’s `/probe` endpoint.

Key metrics:

- `probe_success{job="blackbox-dns"}` — `1` when resolution succeeds, `0` on failure.
- `probe_duration_seconds{job="blackbox-dns"}` — end-to-end probe duration.

---

### 17.3 Alerting rules for AdGuard

Alert rules for AdGuard are stored under:

- `stacks/monitoring/prometheus/rules/adguard.rules.yml`

and are loaded by Prometheus via:

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml
```

Current rules:

```yaml
groups:
  - name: adguard.home
    rules:
      - alert: AdGuardExporterDown
        expr: up{job="adguard-exporter"} == 0
        for: 5m
        labels:
          severity: warning
          service: adguard-home
          stack: dns
        annotations:
          summary: "AdGuard metrics exporter is not reachable"
          description: "Prometheus has not been able to scrape job="adguard-exporter" for more than 5 minutes. Verify container status and Docker networking."

      - alert: AdGuardProtectionDisabled
        expr: protection_enabled{job="adguard-exporter"} == 0
        for: 10m
        labels:
          severity: warning
          service: adguard-home
          stack: dns
        annotations:
          summary: "AdGuard DNS protection is disabled"
          description: "AdGuard DNS protection flag has been set to disabled for at least 10 minutes. Review configuration and re-enable filtering if intentional."

      - alert: AdGuardHighLatency
        expr: adguard_avg_processing_time{job="adguard-exporter"} > 0.15
        for: 10m
        labels:
          severity: warning
          service: adguard-home
          stack: dns
        annotations:
          summary: "AdGuard DNS average processing time is high"
          description: "Average AdGuard DNS processing time is above 150ms for 10 minutes. Investigate upstream DNS, network latency or AdGuard resource usage."
```

Additional HTTP health rules are defined in:

- `stacks/monitoring/prometheus/rules/couchdb.rules.yml`

This file contains `CouchDBEndpointDown`, which fires when the Blackbox HTTP
probe against `https://couchdb.atardecer-naranja.es/_up` has been failing
for more than 5 minutes. The rule helps detect issues in CouchDB itself, the
reverse proxy or the Cloudflare tunnel before they escalate into
application-level errors in the Nextcloud stack.

In practice:

- `AdGuardExporterDown` ensures that the **metrics path itself** is reachable and scraped.
- `AdGuardProtectionDisabled` tracks the AdGuard **protection flag** for sustained misconfiguration or manual disablement.
- `AdGuardHighLatency` watches the average processing time exported by the AdGuard exporter and raises an alert above 150 ms.

All three rules are labelled for consistent routing and dashboarding:

- `severity="warning"`
- `service="adguard-home"`
- `stack="dns"`



---

### 17.4 Grafana & dashboards (overview)

From the monitoring stack’s perspective, Grafana is expected to surface AdGuard metrics via:

- `job="adguard-exporter"` — volumetry (queries, blocked ratio, processing time),
- `job="blackbox-dns"` — probe status and latency (`probe_success`, `probe_duration_seconds`).

Typical panels for a `DNS / AdGuard` dashboard:

- **DNS QPS** and **blocked percentage** over time.
- **Average processing time** (and/or P95 if derived via recording rules).
- **Top clients / top blocked domains** (using exporter metrics).
- **Probe status** from `blackbox-dns` (stat panel mapping `probe_success` 0/1 to FAIL/OK).

The JSON definition of the dashboard lives under the Grafana dashboards tree (see above) and keeps the public repo free of secrets and environment-specific details.

---

## 18) Cloudflared tunnel monitoring (metrics + alerts + logs)

The monitoring stack treats the Cloudflare Tunnel (`cloudflared`) as a
first-class infrastructure component. Although the tunnel lives in its own
stack (`stacks/cloudflared`), it is wired into the monitoring network and
labelled consistently so that you can observe it like any other service.

### 18.1 Prometheus scrape job

`cloudflared` exposes Prometheus metrics on an **internal** HTTP endpoint
(`--metrics 0.0.0.0:8081`). The monitoring stack scrapes these metrics via a
dedicated job in `stacks/monitoring/prometheus/prometheus.yml`:

```yaml
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

Notes:

- The target name `cloudflared:8081` resolves on the shared `mon-net` Docker
  network; the container joins `mon-net` in its own stack compose.
- The label set follows the homelab conventions and is used by alerting and
  dashboards:
  - `stack="proxy"` — reverse-proxy / ingress layer.
  - `service="cloudflared"` — canonical service name.
  - `env="home"` — environment tag.

Key metrics exported by the tunnel include, among others:

- `cloudflared_tunnel_total_requests` — total number of requests proxied.
- `cloudflared_tunnel_request_errors` — total number of failed proxied
  requests.
- `cloudflared_tunnel_ha_connections` — active HA connections to the edge.
- `cloudflared_tunnel_quic_rtt_milliseconds` — measured RTT over QUIC.

These are used directly or via PromQL (e.g. request rate, error rate,
24-hour success percentage) in the Grafana dashboard.

### 18.2 Alert rules

Alert rules for the tunnel are defined in:

- `stacks/monitoring/prometheus/rules/cloudflared.rules.yml`

Current rules:

```yaml
groups:
  - name: cloudflared.availability
    rules:
      - alert: CloudflaredDown
        expr: up{job="cloudflared"} == 0
        for: 2m
        labels:
          severity: critical
          stack: proxy
          service: cloudflared
          env: home

      - alert: CloudflaredHighErrorRate
        expr: 100 * sum(rate(cloudflared_tunnel_request_errors{job="cloudflared"}[5m])) /
              sum(rate(cloudflared_tunnel_total_requests{job="cloudflared"}[5m])) > 5
        for: 10m
        labels:
          severity: warning
          stack: proxy
          service: cloudflared
          env: home
```

Semantics:

- **CloudflaredDown** — fires when Prometheus cannot scrape the tunnel for
  more than 2 minutes (container down, network issue, or credentials
  problem).
- **CloudflaredHighErrorRate** — fires when more than 5% of requests
  proxied through the tunnel are failing for at least 10 minutes, indicating
  a persistent problem with the tunnel or one of the upstream origins.

Both rules use the standard label set so they can be routed and filtered in
the same way as the rest of the stack.

### 18.3 Grafana dashboard (Cloudflared – Tunnel Overview)

A dedicated dashboard is expected under the exported dashboards tree, for
example:

```text
stacks/monitoring/grafana/dashboards/exported/mon/20_apps/cloudflared-tunnel-overview.json
```

The **Cloudflared – Tunnel Overview** dashboard surfaces:

- **Tunnel status** — stat based on `up{job="cloudflared"}`.
- **Success rate (last 24h)** — SLO-style stat computed from the 24-hour
  ratio of successful vs failed requests.
- **HA connections (edge)** — number of active connections to Cloudflare's
  edge.
- **Edge RTT (QUIC)** — round-trip time to the edge, from the tunnel metrics.
- **Requests per second** — rate of `cloudflared_tunnel_total_requests`.
- **Error rate (requests & %)** — absolute error rate and percentage of
  failed requests over time.
- **Active TCP / UDP sessions** — session-level view from the tunnel
  metrics.
- **Cloudflared logs (errors only)** — Loki panel showing only error-level
  lines from the `cloudflared` container.

The log panel uses the same label model as the rest of the stack; Promtail
ingests Docker logs for containers labelled with `com.logging="true"` and
maps `service="cloudflared"`, so a typical LogQL filter is:

```logql
{service="cloudflared"} |= " ERR "
```

This completes the observability loop for the tunnel: you can see whether
it is up, how well it has behaved in the last 24 hours, how much traffic
it is carrying, when/where errors occur and what the underlying logs say
for the same time window.

## 19) Nextcloud monitoring (service, DB/Redis and logs)

This stack also exposes a small observability bundle for the Nextcloud stack defined in this repository:

- One Prometheus rule file:

  - `stacks/monitoring/prometheus/rules/nextcloud.rules.yml`

- One Grafana dashboard:

  - `stacks/monitoring/grafana/dashboards/exported/mon/20_apps/nextcloud-service-overview.json`
    (appears in Grafana under **20_Apps / Nextcloud – Service overview**).

The only assumption is that the Nextcloud stack is running on the same Docker host and that:

- The `nextcloud` stack is attached to the `mon-net` network.
- The exporters `nc-mysqld-exporter` and `nc-redis-exporter` are running (see the Nextcloud README).
- The public HTTPS endpoint you actually use in production is the one configured in the
  Blackbox HTTP probe to `status.php` in the monitoring stack.

### 1) Prometheus rules

The `nextcloud.rules.yml` file adds basic "is it alive?" alerts for Nextcloud:

- Blackbox probe to `status.php` failing for several minutes.
- `mysql_up` for the Nextcloud mysqld_exporter staying at `0` (exporter cannot reach MariaDB).
- `redis_up` for the Nextcloud redis_exporter staying at `0` (exporter cannot reach Redis).

All rules follow the same pattern: if the condition stays bad for 5 minutes the alert fires
at *warning* level. This gives you early signal that the service or one of its dependencies
is down, or that the monitoring side is misconfigured (wrong network, credentials, etc.).

Exact rule names and labels are not important for day‑to‑day usage; they only drive
Alertmanager.

### 2) Grafana – Nextcloud – Service overview

The dashboard is meant to answer three questions in one screen:

1. Is the public Nextcloud endpoint up and within its SLO?
2. Are MariaDB and Redis behaving normally for this instance?
3. Are there unexpected application errors in the logs?

Layout summary (the dashboard lives in **20_Apps / Nextcloud – Service overview**):

**Top row – availability & SLO**

- Status of the public `status.php` probe (panel override: *Last 5 minutes*).
- 24‑hour HTTP probe success rate for `status.php`.
- Availability of the mysqld_exporter and redis_exporter (panels overridden to *Last 5 minutes*).

**Second row – behaviour under normal load**

- HTTP latency to `status.php` from the Blackbox exporter.
- MariaDB queries per second and active connections.
- Redis commands per second and connected clients.

**Third row – application logs**

- *Nextcloud – Application errors (filtered)* – Loki query that shows application‑level errors
  from the `nc-app` container, excluding known noisy diagnostics.
- *Nextcloud – Known noisy diagnostics* – Loki query that keeps recurring diagnostic
  messages (for example *dirty table reads* or *The loading of lazy AppConfig values have been requested*)
  in a dedicated panel so that they do not pollute the main error stream.

No additional promtail configuration is required: logs are collected via the generic
`dockerlogs` pipeline; the only expectation is that Nextcloud is configured to log to
PHP's `error_log`. The Nextcloud README shows the `occ config:system:set` commands used
to enforce this inside the container.
