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
│  ├─ prometheus.demo.yml
│  ├─ adguard-exporter.yml.example
│  ├─ nextcloud-exporters.yml.example
│  ├─ couchdb.yml.example
│  └─ rules/
│     ├─ adguard.rules.yml
│     ├─ backups.rules.yml
│     ├─ cloudflared.rules.yml
│     ├─ couchdb.rules.yml
│     └─ nextcloud.rules.yml
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


## 3) Runtime assumptions: Docker & host

This stack is designed to run on a Linux host with a **rootful Docker daemon**.
The public `compose.yaml` assumes a conventional layout:

- The Docker API is exposed via the Unix socket at `/var/run/docker.sock`.
- Docker data lives under `/var/lib/docker`.
- The host root filesystem `/` can be mounted read‑only inside some monitoring containers.

In particular:

- **cAdvisor**
  - Runs with `privileged: true` and mounts:
    - `/` → `/rootfs:ro`
    - `/var/run` → `/var/run:ro`
    - `/var/lib/docker` → `/var/lib/docker:ro`
    - `/sys` → `/sys:ro`
  - This is required for cgroups and per‑container metrics (CPU, memory, network)
    with Docker / Compose labels. Without these mounts, cAdvisor only sees a
    single aggregate cgroup and the containers overview dashboard becomes useless.

- **node-exporter**
  - Uses `--path.rootfs=/host` and expects the host root filesystem to be
    bound as `/host:ro`. This makes filesystem and memory metrics reflect the
    real host instead of the container.

- **Promtail**
  - Connects to the Docker API at `/var/run/docker.sock`.
  - Reads Docker JSON log files from `/var/lib/docker/containers`.
  - Only containers explicitly labelled with `com.logging="true"` are scraped.

If you run Docker in **rootless mode** or with a non‑standard directory layout, you
should adapt these mounts in your private runtime overrides (for example in a
separate `homelab-runtime` repository) or by using the demo stack and its
`.env.demo` file as a template. The public `compose.yaml` remains opinionated
towards the rootful Docker defaults so that dashboards and alert rules work
out of the box on a typical single‑node homelab host.


## 4) Prerequisites

- Docker Engine + **Docker Compose v2**
- External docker networks created: `mon-net`, `proxy`
- **Rootless-friendly binds** for Promtail in your runtime override:
  - `${DOCKER_SOCK}` → usually `/run/user/1000/docker.sock` (rootless) or `/var/run/docker.sock` (rootful)
  - `${DOCKER_CONTAINERS_DIR}` → usually `~/.local/share/docker/containers` (rootless) or `/var/lib/docker/containers` (rootful)
  - `${SELINUX_SUFFIX}` → leave empty unless you need `:Z` on SELinux hosts

---

## 5) Compose files

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

## 6) Uptime Kuma metrics (runtime password file)

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

## 7) Operations

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

## 8) Reverse proxy / Tunnel (example: Cloudflare Tunnel)

Example `cloudflared` config:

```yaml
ingress:
  - hostname: grafana.<your-domain>
    service: http://grafana:3000
  - service: http_status:404
```

Create a CNAME `grafana` → `<TUNNEL_UUID>.cfargotunnel.com` (proxied). Protect with **Access** if exposing publicly.

---

## 9) Grafana provisioning & dashboards

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

  Detailed backup metrics (age, duration and data volume) are covered by the
  separate **Backups – Overview** dashboard described in section 22.

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

## 10) Health & smoke tests

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

## 11) LogQL quick cheatsheet (Loki)

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

## 12) Notes on Promtail config

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

## 13) Backups (what to keep)

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

## 14) Updates (safe flow)

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

## 15) Quick start (TL;DR)

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

## 16) Demo mode (isolated **demo-** stack)

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

## 17) Blackbox targets manager (script + Makefile)

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

## 18) AdGuard DNS monitoring (exporter + blackbox)

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

## 19) Cloudflared tunnel monitoring (metrics + alerts + logs)

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

---

## 20) Host & containers monitoring (infra overview)

The monitoring stack also exposes two base Grafana dashboards for the Docker host and the
containers it runs. They are intended to be the **landing pages** for infrastructure health:
CPU, memory, filesystems and basic network saturation at node level, plus a cAdvisor-based
view of stacks and containers on the same node.

- `stacks/monitoring/grafana/dashboards/exported/mon/10_infra/host-system-overview.json`
  (appears in Grafana under **10_Infra / Host – System overview**).
- `stacks/monitoring/grafana/dashboards/exported/mon/10_infra/containers-docker-overview.json`
  (appears in Grafana under **10_Infra / Containers – Docker overview**).

The only assumptions are:

- The monitoring stack (Prometheus, Loki, etc.) runs on the same Docker host as the containers
  you care about.
- `mon-node-exporter` is attached to the `mon-net` network and scrapes the host via the
  `/host` bind-mount (see the monitoring compose).
- `mon-cadvisor` is attached to `mon-net`, runs `privileged: true` with the host mounts
  described above, and Docker containers are started via Compose so that standard
  `com.docker.compose.*` labels are present (used to derive `stack`, `service` and
  `container` in the dashboard).

### 1) Grafana – Host – System overview

The **Host – System overview** dashboard is meant to answer, on a single screen:

1. Is the node-exporter scrape healthy?
2. How busy is the host in terms of CPU and load averages?
3. Is memory (and swap) usage within reasonable limits?
4. Are the main filesystems close to full?
5. Is the host network behaving normally?

Layout summary (the dashboard lives in **10_Infra / Host – System overview**):

**Top row – health & saturation**

- **Node-exporter status** — stat panel based on `up{job="node"}`, with a time range
  override to *Last 5 minutes*. If this is down, host-level metrics are stale or missing.
- **CPU usage (last 5 minutes)** — percentage of host CPU used, computed from
  `node_cpu_seconds_total` (all cores) and normalised to 0–100%.
- **Load average (1 / 5 / 15 min)** — time series for `node_load1`, `node_load5` and
  `node_load15`, with thresholds relative to the host core count. This gives an early
  signal of sustained overload or CPU contention.
- **Filesystem usage (%)** — stat panel showing the percentage of space used on the root
  filesystem (`/`). The panel is wired to the `node_filesystem_` metrics and filters out
  pseudo-mounts and bind-mount noise.

**Second row – memory & swap**

- **Memory usage** — percentage of RAM used, computed from
  `node_memory_MemTotal_bytes` and `node_memory_MemAvailable_bytes`. This is more
  meaningful than “used vs free” in modern kernels with cache and buffers.
- **Swap usage** — percentage of swap used. In a healthy homelab node this is expected
  to stay close to `0%`; any sustained swap usage usually points to memory pressure or
  mis-sized containers/VMs.

**Third row – host network**

- **Network throughput (Rx / Tx)** — time series based on
  `node_network_receive_bytes_total` and `node_network_transmit_bytes_total`, filtered to
  the primary network interface. This gives a quick sense of whether the host is idle,
  under normal load or saturated from a bandwidth perspective.

### 2) Grafana – Containers – Docker overview

The **Containers – Docker overview** dashboard is the companion to the host view and
answers the question “which stacks and containers are actually using the host?”.

Layout summary (the dashboard lives in **10_Infra / Containers – Docker overview**):

**Top row – health & footprint**

- **cAdvisor exporter status** — stat panel based on `up{job="cadvisor"}`, with a time
  range override to *Last 5 minutes*. If this is down, container-level metrics are stale.
- **Running containers** — approximate count of containers seen by cAdvisor in the last
  5 minutes.
- **Containers CPU vs host** — share of total host CPU currently consumed by all Docker
  containers (5-minute average).
- **Containers memory vs host** — share of host RAM used by all containers (working set).

**Middle rows – per-stack view**

- **CPU by stack** — per-stack CPU usage as a percentage of total host CPU, grouped by
  Docker Compose project (`stack` label) and averaged over the last 5 minutes.
- **Memory by stack** — aggregated working set memory per stack, in MiB/GiB.
- **Disk I/O by stack** — combined read+write throughput per stack.
- **Network by stack** — combined receive+transmit throughput per stack.

Each of these panels is meant to answer “which stack is driving CPU / RAM / disk / network
right now?” before you drill down.

**Right column – top containers**

Three tables show the top containers per resource in the last 5 minutes, grouped by
`stack`, `service` and `container`:

- **Top containers – CPU**
- **Top containers – memory**
- **Top containers – disk I/O**
- **Top containers – network**

They are the bridge between “stack X is noisy” and “this specific container inside that
stack is the culprit”.

**Bottom row – container detail**

The last row exposes per-container detail controlled by three Grafana variables:
`$stack`, `$service` and `$container`. For the selected container it shows:

- CPU usage as a share of host CPU (5-minute average).
- Working set memory in MiB/GiB.
- Disk I/O throughput (read+write).
- Network throughput (Rx+Tx).

This makes it possible to go from “the host is slow” → “this stack is the heavy one”
→ “this container is actually burning CPU / RAM / I/O” without leaving a single
dashboard.

---

## 21) Nextcloud monitoring (service, DB/Redis and logs)

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

---

## 22) Backups monitoring (Restic + Nextcloud overview)

The monitoring stack also ships a small bundle for backup observability, focused on
the Restic repository and the application-level Nextcloud backup:

- One Prometheus rule file:

  - `stacks/monitoring/prometheus/rules/backups.rules.yml`

- One Grafana dashboard:

  - `stacks/monitoring/grafana/dashboards/exported/mon/40_backups/backups-overview.json`
    (appears in Grafana under **40_Backups / Backups – Overview**).

The only assumption is that the backup scripts in the Restic and Nextcloud stacks are
already exporting textfile metrics via node_exporter, as documented in their respective
READMEs. The dashboard is a pure consumer of those metrics; it does not introduce any
new runtime requirements.

### 1) Prometheus rules

`backups.rules.yml` adds basic "is it running and fresh?" alerts on top of the textfile
metrics:

- Restic backup considered *stale* when the last successful run timestamp is too old.
- Nextcloud backup considered *stale* under the same condition.
- Optional rules for suspiciously small Restic runs or other sanity checks.

All rules follow the existing labelling conventions:

- `stack="backups"`
- `service="restic"` or `service="nextcloud-backup"`
- `severity="warning"` / `severity="critical"`

so they can be routed alongside the rest of the monitoring stack.

### 2) Grafana – Backups – Overview

The **Backups – Overview** dashboard is meant to answer, on a single screen:

1. Are the Restic and Nextcloud backups running successfully and within their expected
   freshness window?
2. How long do the latest backup runs take at each layer?
3. How much data is being added to the Restic repository, and how does that relate to
   the logical size of the Nextcloud backup?

Layout summary (the dashboard lives in **40_Backups / Backups – Overview**):

**Top row – freshness & status**

- **Restic – age** and **Nextcloud – age** — stat panels showing hours since the last
  successful backup run for each layer, with thresholds aligned with the Prometheus
  "backup stale" rules.
- **Restic – status** and **Nextcloud – status** — last exit code of each backup job
  (0 = OK, non-zero = failed).
- **Backup metrics – sanity** — simple sanity check that both Restic and Nextcloud
  backup metrics are currently being scraped.

**Second row – duration**

- **Restic – backup duration** — time series of the last backup duration in seconds.
- **Nextcloud – backup duration** — same for the application-level backup.
- **Backups – duration overlay (Restic vs Nextcloud)** — both durations on a single
  panel to highlight shared bottlenecks vs app-only slowdowns.

**Third row – data volume & growth**

- **Restic – data added per run** — amount of new data written to the Restic repository
  on the last run, derived from the corresponding `*_added_bytes` metric.
- **Nextcloud – backup size** — logical size of the latest Nextcloud backup snapshot.
- **Restic vs Nextcloud – data relationship** — combined view that compares Restic's
  added data with the total Nextcloud snapshot size, useful to spot mismatches between
  logical growth and repository growth.

Taken together with the Uptime Kuma service/backup status dashboard, this gives you a
full picture of "are backups running, recent and roughly the right size and duration?"
from both a **status** and a **metrics** perspective.

---

## 23) CouchDB monitoring (service overview)

The monitoring stack also exposes a small observability bundle for the
CouchDB instance used by the homelab. It covers both the internal exporter
metrics and the public HTTPS health check used by Nextcloud and other
clients.

- One Prometheus rule file:

  - `stacks/monitoring/prometheus/rules/couchdb.rules.yml`

- One Grafana dashboard:

  - `stacks/monitoring/grafana/dashboards/exported/mon/20_apps/couchdb-service-overview.json`
    (appears in Grafana under **20_Apps / CouchDB – Service overview**).

The only assumptions are that:

- The CouchDB stack is attached to the `mon-net` network and runs the
  `couchdb-exporter` container as documented in the CouchDB README.
- The exporter is scraped by Prometheus under `job="couchdb"` and labelled
  consistently with the rest of the homelab (`stack="couchdb"`,
  `service="couchdb"`, `env="home|lab"`).
- The public HTTPS endpoint exposed through the reverse proxy / tunnel is
  the one configured in the Blackbox HTTP probe to `/_up`.

### 1) Prometheus rules

`couchdb.rules.yml` adds basic availability and quality-of-service alerts
on top of the exporter and blackbox metrics:

- **CouchDBEndpointDown**

  Fires when the Blackbox HTTP probe against the public `/_up` endpoint
  (`https://couchdb.atardecer-naranja.es/_up`) has been failing for more
  than 5 minutes. This captures issues in the HTTP path (DNS, reverse
  proxy, Cloudflare tunnel) as well as CouchDB itself.

- **CouchDBDown**

  Raised when `up{job="couchdb"}` stays at `0` for more than 5 minutes.
  This usually points to a broken exporter, container or `mon-net` wiring
  rather than an application-level error.

- **CouchDBHigh5xxErrorRate**

  Warns when the share of HTTP 5xx responses reported by the exporter is
  above a small threshold for several minutes, indicating server-side
  failures under otherwise healthy load.

All rules follow the standard labelling conventions:

- `stack="couchdb"`
- `service="couchdb"`
- `severity="warning"` / `severity="critical"`

so they can be routed and filtered alongside the rest of the monitoring
stack.

### 2) Grafana – CouchDB – Service overview

The **CouchDB – Service overview** dashboard is meant to answer, on a
single screen:

1. Is CouchDB reachable both from Prometheus and from the public HTTP
   entrypoint?
2. How much traffic is the node handling and how clean are the responses?
3. Are there signs of internal resource pressure inside the Erlang VM?

Layout summary (the dashboard lives in **20_Apps / CouchDB – Service overview**):

**Top row – health & external reachability**

- Exporter scrape status via `up{job="couchdb"}` with a time override to
  *Last 5 minutes*.
- Public HTTPS endpoint health via the Blackbox probe to `/_up`.
- HTTP 5xx error share over the last 5 minutes.

**Second row – traffic & status codes**

- Total HTTP requests per second derived from `couchdb_httpd_status_codes`.
- HTTP requests per second broken down by status code (2xx / 3xx / 4xx / 5xx).

**Third row – internals**

- Erlang VM memory usage broken down by atom, binary and code segments.
- Internal resource counters such as open databases and open OS file
  descriptors for the CouchDB node.

Taken together with the CouchDB alert rules, this dashboard provides a
clear landing page for CouchDB-related incidents before you need to jump
into logs or lower-level debugging.

