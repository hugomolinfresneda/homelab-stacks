# Monitoring Stack (Prometheus · Grafana · Loki · Promtail · Blackbox)

This stack provides **metrics + logs + probes** with Docker, split between the **public stacks repo** and your **private runtime**. Images are pinned by **digest**, containers include **healthchecks**, and the base compose keeps things **portable** (no host ports; you only publish what you need via your reverse proxy / tunnel).

**Includes:**

- **Prometheus** — metrics TSDB + scraping
- **Alertmanager** — alert routing to Telegram (critical vs warning), quiet hours, inhibition, and incident links (runbook/dashboard/alert/silence)
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
├── alertmanager
│   ├── alertmanager.yml
│   └── templates
│       └── telegram.tmpl
├── blackbox
│   └── blackbox.yml
├── compose.demo.logs.yaml
├── compose.demo.names.yaml
├── compose.demo.yaml
├── compose.yaml
├── docs
│   └── alerting
│       ├── alertmanager-telegram.md
│       ├── overview.md
│       ├── prometheus-rules.md
│       └── runbooks.md
├── grafana
│   ├── dashboards
│   │   └── exported
│   │       ├── demo
│   │       │   ├── demo-blackbox-targets-probes.json
│   │       │   ├── demo-core-stack-health.json
│   │       │   └── demo-logs-quick-view.json
│   │       └── mon
│   │           ├── 10_infra
│   │           │   ├── containers-docker-overview.json
│   │           │   └── host-system-overview.json
│   │           ├── 20_apps
│   │           │   ├── adguard-service-overview.json
│   │           │   ├── cloudflared-tunnel-overview.json
│   │           │   ├── couchdb-service-overview.json
│   │           │   └── nextcloud-service-overview.json
│   │           ├── 30_logs
│   │           │   └── logs-quick-search.json
│   │           ├── 30_status-incidences
│   │           │   └── uptime-kuma-service-backup-status.json
│   │           └── 40_backups
│   │               └── backups-overview.json
│   ├── provisioning.demo
│   │   ├── dashboards
│   │   │   └── dashboards.yml
│   │   └── datasources
│   │       └── datasources.yml
│   └── provisioning.mon
│       ├── dashboards
│       │   └── dashboards.yml
│       └── datasources
│           └── datasources.yml
├── loki
│   └── config.yaml
├── Makefile.demo
├── prometheus
│   ├── adguard-exporter.yml.example
│   ├── couchdb.yml.example
│   ├── nextcloud-exporters.yml.example
│   ├── prometheus.demo.yml
│   ├── prometheus.yml
│   └── rules
│       ├── adguard.rules.yml
│       ├── backups.rules.yml
│       ├── cloudflared.rules.yml
│       ├── containers.rules.yml
│       ├── couchdb.rules.yml
│       ├── endpoints.rules.yml
│       ├── infra.rules.yml
│       └── nextcloud.rules.yml
├── promtail
│   ├── config.demo.yaml
│   └── config.yaml
├── README.md
├── runbooks
│   ├── BackupDiskNotMounted.md
│   ├── BlackboxExporterDown.md
│   └── ResticBackupStaleHard.md
├── scripts
│   └── blackbox-targets.sh
└── tools
    └── mon
```

**Private runtime** (e.g., `/opt/homelab-runtime`):

```
stacks/monitoring/            # runtime overlay (environment-specific)
├── alertmanager
│   └── alertmanager.yml      # overrides (e.g., real chat_id / env-specific routing)
├── blackbox                  # runtime-only additions (targets, overrides if needed)
├── compose.override.yml      # mounts, secrets, external URLs, environment wiring
├── grafana
│   ├── dashboards
│   │   └── exported
│   │       └── mon           # optional runtime dashboard overrides (if any)
│   └── provisioning.mon
│       ├── dashboards        # provisioning overrides
│       └── datasources       # datasource overrides (URLs, auth, etc.)
├── loki                       # runtime overrides (paths, retention, storage)
├── prometheus                 # runtime overlay (config/secrets/overrides)
│   └── rules                  # (intentionally omitted from README; local patching only)
├── promtail                   # runtime overrides (labels, endpoints, positions)
└── secrets
    └── kuma_password          # example secret (runtime-only)
```
> **Note:** The runtime overlay may include a Prometheus rules override directory used only to add environment-specific annotations (e.g., `dashboard_url`). It is not required for a default deployment.

---

## 3) Runtime assumptions: Docker & host

This stack is designed to run on a Linux host, but the public `compose.yaml`
is now **portable** and does **not** mount host paths by default. Host‑coupled
mounts (Docker socket, Docker logs, `/`, `/sys`, etc.) must be provided in a
private runtime override.

In practice, these runtime mounts are required for full fidelity:

- **cAdvisor** (needs host cgroups + Docker runtime):
  - `/` → `/rootfs:ro`
  - `/var/run` → `/var/run:ro`
  - `/var/lib/docker` → `/var/lib/docker:ro`
  - `/sys` → `/sys:ro`
- **node-exporter** (host filesystem + optional textfile collector):
  - `/` → `/host:ro`
  - `${NODE_EXPORTER_TEXTFILE_DIR}` → `/textfile-collector:ro`
- **Promtail** (Docker discovery + JSON logs):
  - `${DOCKER_SOCK}` → `/var/run/docker.sock:ro`
  - `${DOCKER_CONTAINERS_DIR}` → `/var/lib/docker/containers:ro`

If you run Docker in **rootless mode** or with a non‑standard directory layout,
adapt these mounts in your private runtime overrides (for example in a separate
`homelab-runtime` repository) or by using the demo stack and its `.env.demo`
file as a template.


## 4) Prerequisites

- Docker Engine + **Docker Compose v2**
- External docker networks created: `mon-net`, `proxy`
- **Required .env variables** (compose will fail fast if missing):
  - `STACKS_DIR`, `PROM_*_TARGETS`, `ROOT_MOUNTPOINT`, `ROOT_FSTYPE`, `BACKUP_MOUNTPOINT`, `BACKUP_FSTYPE`
  - Empty or missing values stop `docker compose` with a clear error (`:?`).
- **Targets format** (Prometheus env expansion):
  - `PROM_*_TARGETS` values are YAML flow list items (comma-separated)
  - Example: `PROM_NEXTCLOUD_EXPORTER_TARGETS=nc-mysqld-exporter:9104,nc-redis-exporter:9121`
- **Filesystem labels** (alert rules):
  - `ROOT_MOUNTPOINT`/`ROOT_FSTYPE` and `BACKUP_MOUNTPOINT`/`BACKUP_FSTYPE` must match node-exporter metrics
- **Runtime override binds** (rootful or rootless):
  - `${DOCKER_SOCK}` → usually `/run/user/1000/docker.sock` (rootless) or `/var/run/docker.sock` (rootful)
  - `${DOCKER_CONTAINERS_DIR}` → usually `~/.local/share/docker/containers` (rootless) or `/var/lib/docker/containers` (rootful)
  - `${NODE_EXPORTER_TEXTFILE_DIR}` → usually `/var/lib/node_exporter/textfile_collector`
  - `${SELINUX_SUFFIX}` → leave empty unless you need `,Z (or ,z)` on SELinux hosts

---

## 5) Compose files

- **Base (public):** `/opt/homelab-stacks/stacks/monitoring/compose.yaml`
  Pinned digests, healthchecks, no host ports, networks `mon-net` (+ `proxy` for Grafana).
  The base compose expects `STACKS_DIR` to point at the repo root (used for bind mounts).
  Prometheus runs with `--config.expand-env` to inject `PROM_*_TARGETS` and mountpoint vars.

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

    node-exporter:
      volumes:
        - /:/host:ro,rslave
        - ${NODE_EXPORTER_TEXTFILE_DIR}:/textfile-collector:ro${SELINUX_SUFFIX}

    cadvisor:
      privileged: true
      volumes:
        - /:/rootfs:ro
        - /var/run:/var/run:ro
        - /sys:/sys:ro
        - /var/lib/docker:/var/lib/docker:ro

    prometheus:
      volumes:
        - /opt/homelab-runtime/stacks/monitoring/secrets/kuma_password:/etc/prometheus/secrets/kuma_password:ro
  ```

  The Promtail volumes give it access to Docker logs in both rootless and rootful setups.
  The Prometheus volume injects the Uptime Kuma metrics password as a plain read-only file, avoiding Docker Swarm secrets for maximum portability on single-node homelab deployments.

---

## X) Alerting & runbooks

This stack implements an opinionated alerting model designed for a single-node homelab:

- **Critical** alerts are infrastructure failures and must notify 24/7.
- **Warning** alerts are service/lab signals and are muted during quiet hours.
- Alert rules are structured to favor a single primary symptom per service, with secondary diagnostics inhibited.

For the full design, routing and operational details, see:

- `docs/alerting/overview.md`
- `docs/alerting/prometheus-rules.md`
- `docs/alerting/alertmanager-telegram.md`
- `docs/alerting/runbooks.md`


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
    - targets: [${PROM_UPTIME_KUMA_TARGETS}]
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
docker compose   -f ${STACKS_DIR}/stacks/monitoring/compose.yaml   -f /opt/homelab-runtime/stacks/monitoring/compose.override.yml   up -d
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

- **Datasources** are pre-provisioned (`grafana/provisioning.mon/datasources/datasources.yml`):

  - `Prometheus` → `http://prometheus:9090` (uid: `prometheus`, **default**)
  - `Loki` → `http://loki:3100` (uid: `loki`)

- **Dashboards** are provisioned from JSON files under the exported dashboards tree:

  Host-side path:

  ```
  stacks/monitoring/grafana/dashboards/exported/mon/30_status-incidences/uptime-kuma-service-backup-status.json
  ```

  Demo-side path:

  ```
  stacks/monitoring/grafana/dashboards/exported/demo/demo-blackbox-targets-probes.json
  ```

  The demo tree contains three minimal, portable dashboards designed for interviews:

  - **Demo – Blackbox Targets & Probes** (targets lifecycle + probe latency)
  - **Demo – Core Stack Health** (Prometheus/Loki/Promtail/Alertmanager health snapshot)
  - **Demo – Logs Quick View** (Loki/Promtail “is it alive?” + simple error-like triage)


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

### Loki - late samples

Loki is configured to **reject old samples**, but it allows a small, explicit
late-arrival window to tolerate Promtail backfill after downtime or position
resets:

- `reject_old_samples: true`
- `reject_old_samples_max_age: 336h` (14 days)

This setting is **independent** from log retention (`retention_period`): it only
controls how far back in time Loki will accept timestamps at ingest.

If you see Promtail/Loki errors like `HTTP 400 ... timestamp too old`, it means
some log streams are being pushed with timestamps older than the allowed window.


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
sum by (container) (rate({job="dockerlogs"}[1m]))
```

Top 5 chatty services (Explore → Metrics):

```logql
topk(5, sum by (compose_service) (rate({job="dockerlogs"}[1m])))
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
  into the `mon-promtail` container by your runtime override, so Promtail can discover
  running containers in both rootful and rootless setups.

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

## 16) Demo mode (isolated demo stack)

**Note**: all demo operation is centralized in `stacks/monitoring/Makefile.demo`. Run commands from the repo root:

```bash
make -f stacks/monitoring/Makefile.demo <target>
```

This demo is designed to be **self-contained** and **portable**: it provisions Prometheus + Blackbox + Loki/Promtail + Alertmanager + Grafana with pre-wired datasources (`uid: prometheus`, `uid: loki`) and a small set of demo dashboards.

### Naming model (avoid collisions)

The demo does **not** hardcode `demo-*` names anymore.

Instead, `DEMO_PROJECT` (defaults to `mon-demo`) is used as `COMPOSE_PROJECT_NAME`, and every resource is derived from it:

- Containers: `${DEMO_PROJECT}-grafana`, `${DEMO_PROJECT}-prometheus`, ...
- Network: `${DEMO_PROJECT}-net`
- Volumes: `${DEMO_PROJECT}-grafana-data`, `${DEMO_PROJECT}-loki-data`, `${DEMO_PROJECT}-promtail-positions`

This lets an interviewer run the demo even if they already have some random `demo-grafana` lying around (because of course they do).

### Quick start

1) Create the demo env file (no secrets):

```bash
cp stacks/monitoring/.env.demo.example stacks/monitoring/.env.demo
```

2) Optional: pick a project name (recommended on shared machines):

```bash
export DEMO_PROJECT=demo
```

3) Validate the composed stack (syntax + interpolation):

```bash
make -f stacks/monitoring/Makefile.demo demo-config DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}
```

4) Bring the demo up:

```bash
make -f stacks/monitoring/Makefile.demo demo-up DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}
```

5) List services:

```bash
make -f stacks/monitoring/Makefile.demo demo-ps DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}
```

6) Tear down (and clean project-scoped volumes):

```bash
make -f stacks/monitoring/Makefile.demo demo-down DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}
```

### What is included

- **Prometheus (demo)** scraping:
  - `prometheus`, `alertmanager`, `node`, `loki`, `promtail`
  - `blackbox` exporter
  - blackbox probe jobs: `blackbox-http`, `blackbox-icmp`
- **Alertmanager (demo)**
- **Loki + Promtail (demo)** for Docker logs (`job="dockerlogs"`)
  - Promtail is scoped to the demo stack via `PROMTAIL_COMPOSE_PROJECT` to avoid ingesting unrelated host containers (and to prevent “timestamp too old” rejections from old logs).
- **Grafana (demo)** with datasources + dashboards provisioned
- **Optional logspammer** (for predictable, non-depressing log volume)

### Demo dashboards (Grafana)

Provisioned JSON files (repo path):

- `stacks/monitoring/grafana/dashboards/exported/demo/demo-blackbox-targets-probes.json`
- `stacks/monitoring/grafana/dashboards/exported/demo/demo-core-stack-health.json`
- `stacks/monitoring/grafana/dashboards/exported/demo/demo-logs-quick-view.json`

### Blackbox target workflow (the point of the demo)

```bash
# list job targets
make -f stacks/monitoring/Makefile.demo ls-targets-demo  JOB=blackbox-http

# add a target
make -f stacks/monitoring/Makefile.demo add-target-demo JOB=blackbox-http TARGET=https://example.org

# apply changes (reload Prometheus demo)
make -f stacks/monitoring/Makefile.demo demo-reload-prom DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}

# remove a target
make -f stacks/monitoring/Makefile.demo rm-target-demo  JOB=blackbox-http TARGET=https://example.org
```

### Notes & pitfalls

- **Promtail Docker access**: if Promtail cannot connect to the Docker daemon, set `DOCKER_SOCK` and `DOCKER_CONTAINERS_DIR` in `stacks/monitoring/.env.demo` to match your engine (rootful vs rootless). On SELinux enforcing hosts, set `SELINUX_SUFFIX=,z (or ,Z)`.
- **“timestamp too old” (Loki 400)**: typically caused by Promtail tailing old container logs from outside the demo scope or by reusing a stale positions file. Confirm `PROMTAIL_COMPOSE_PROJECT` is set correctly and, if needed, run `demo-down` to wipe `${DEMO_PROJECT}-promtail-positions` and restart cleanly.
- Demo does **not** require any secrets.

---

## 17) Blackbox targets manager (script + Makefile)

Manage the HTTP/ICMP probe target lists that Prometheus scrapes via **Blackbox Exporter**.

The helper uses containerized **yq** and **promtool**, so you only need Docker on the host.
Changes are **idempotent** (deduplicate + sort) and validated with `promtool`.

### 17.1 Direct script usage

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
make -f stacks/monitoring/Makefile.demo demo-reload-prom    # demo stack
```

> SELinux: if enforcing, the script automatically uses `:Z` on bind mounts.

### 17.2 Makefile wrappers (easier)

These delegate to the script above and pick the right file automatically:

```bash
# Main stack (mon-)
make bb-ls                 [JOB=blackbox-http]
make bb-add  TARGET=<url>  [JOB=blackbox-http]
make bb-rm   TARGET=<url>  [JOB=blackbox-http]
make reload-prom

# Demo stack (project-scoped)
make -f stacks/monitoring/Makefile.demo bb-ls-demo            [JOB=blackbox-http]
make -f stacks/monitoring/Makefile.demo bb-add-demo TARGET=<url>  [JOB=blackbox-http]
make -f stacks/monitoring/Makefile.demo bb-rm-demo  TARGET=<url>  [JOB=blackbox-http]
make -f stacks/monitoring/Makefile.demo demo-reload-prom DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}
```

**Examples**

```bash
make bb-ls
make bb-add TARGET=https://cloudflare.com
make reload-prom

make -f stacks/monitoring/Makefile.demo bb-ls-demo
make -f stacks/monitoring/Makefile.demo bb-add-demo TARGET=https://example.com
make -f stacks/monitoring/Makefile.demo demo-reload-prom DEMO_PROJECT=${DEMO_PROJECT:-mon-demo}
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
    - targets: [${PROM_ADGUARD_EXPORTER_TARGETS}]

# AdGuard DNS resolution (blackbox → AdGuard)
- job_name: 'blackbox-dns'
  metrics_path: /probe
  params:
    module: [dns_udp]
  static_configs:
    - targets: [${PROM_ADGUARD_DNS_TARGETS}]
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

### 17.4 Grafana – AdGuard – Service Overview

The monitoring stack ships a dedicated Grafana dashboard for AdGuard Home under the exported dashboards tree:

```text
stacks/monitoring/grafana/dashboards/exported/mon/20_apps/adguard-service-overview.json
```

In Grafana it appears under **20_Apps / AdGuard – Service Overview**.

This dashboard is exporter-centric by design: it focuses on AdGuard’s own service and filtering signals (`job="adguard-exporter"`). End-to-end DNS probing is still available via the `blackbox-dns` job (see sections 18.1–18.2), but it is not the primary signal in this overview.

**Top row – health & current state (panel override: *Last 5 minutes*)**

* **AdGuard – Status** — binary `UP/DOWN` state derived from `adguard_running` (latest value).
* **AdGuard – Protection** — binary `Enabled/Disabled` state derived from `adguard_protection_enabled` (latest value).
* **AdGuard – DNS processing time** — near-real-time processing time from `adguard_avg_processing_time` (latest value).

**Traffic & blocking (dashboard time range)**

* **AdGuard – DNS queries (all types)** — total DNS query volume (`adguard_num_dns_queries`).
* **AdGuard – Ads blocked** — blocked queries (`adguard_num_blocked_filtering`).
* **AdGuard – Ads blocked (%)** — blocking ratio computed as:
  `100 * adguard_num_blocked_filtering / adguard_num_dns_queries`.

**Query mix (dashboard time range)**

* **AdGuard – DNS query types** — query type distribution (`adguard_query_types`) split by type.

**Top domains (instant snapshot tables)**

* **AdGuard – Top queried domains** — instant ranking table from `adguard_top_queried_domains`.
* **AdGuard – Top blocked domains** — instant ranking table from `adguard_top_blocked_domains`.

These tables are configured for readability: long domain names are truncated (no wrapping) and the time column is hidden to avoid repeated rows and layout overflow.

**Panel description standard**

Panel descriptions follow the standard used across the monitoring dashboards:

* `Context`
* `Focus`
* `Implementation`
* `Security` (only where it applies)

Security: top domains can reveal user/device behaviour and internal service names; treat them as operationally sensitive and redact before sharing publicly.

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
    - targets: [${PROM_CLOUDFLARED_TARGETS}]
      labels:
        stack: proxy
        service: cloudflared
        env: home
```

Notes:

- The target name (for example `cloudflared:8081`) resolves on the shared `mon-net` Docker
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

Cloudflared alerts are intentionally **warning-level** by policy. The tunnel is a user-facing entry point, but it is still treated as a service-layer signal (no 24/7 paging). During quiet hours, warning notifications may be muted by Alertmanager.

Alert rules live in:

- `stacks/monitoring/prometheus/rules/cloudflared.rules.yml`

Current signal set:

- `CloudflaredExporterDown` (`warning`)
  Triggers when Prometheus cannot scrape Cloudflared metrics (`up{job="cloudflared"} == 0`).

- `CloudflaredTunnelDown` (`warning`)
  Triggers when the tunnel reports zero HA connections (`cloudflared_tunnel_ha_connections == 0`).
  This is the primary tunnel health signal used for alerting.

These alerts follow the global label standard (`severity`, `service`, `component`, `scope`) and are routed by Alertmanager based on `severity`.

### 18.3 Grafana dashboard (Cloudflared – Tunnel Overview)

A dedicated dashboard is expected under the exported dashboards tree, for
example:

```text
stacks/monitoring/grafana/dashboards/exported/mon/20_apps/cloudflared-tunnel-overview.json
```

The **Cloudflared – Tunnel Overview** dashboard surfaces:

- **Tunnel status (scrape status)** — stat based on `max_over_time(up{job="cloudflared"}[5m])` (panel override: *Last 5 minutes*).
- **Success rate (last 24h)** — SLO-style stat computed from 24-hour request counters (panel override: *Last 24 hours*).
- **HA connections (edge)** — number of active connections to Cloudflare’s edge (panel override: *Last 5 minutes*).
- **Edge RTT (QUIC)** — QUIC round-trip time to the edge (panel override: *Last 5 minutes*).
- **Requests proxied per second** — request throughput derived from `cloudflared_tunnel_total_requests`.
- **Error rate (requests & %)** — absolute error rate and error percentage derived from `cloudflared_tunnel_request_errors` and `cloudflared_tunnel_total_requests`.
- **WARP routing – Active TCP/UDP sessions** — session-level L4 view (may stay at 0 for pure HTTP(S) ingress).
- **Cloudflared logs (errors only)** — Loki panel showing error-level lines from the `cloudflared` container (panel override: *Last 30 minutes*).

Panel descriptions follow the standard `Context / Focus / Implementation / Security` format used across the monitoring dashboards.

The log panel uses the same label model as the rest of the stack; Promtail
ingests Docker logs for containers labelled with `com.logging="true"` and
maps `service="cloudflared"`, so a typical LogQL filter is:

```logql
{service="cloudflared"} |= " ERR "
```

Security: This dashboard reflects Internet ingress; treat hostnames, tunnel identifiers and log content as operationally sensitive and redact before sharing.


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
    (appears in Grafana under **20_Apps / Nextcloud – Service Overview**).

The only assumption is that the Nextcloud stack is running on the same Docker host and that:

- The `nextcloud` stack is attached to the `mon-net` network.
- The exporters `nc-mysqld-exporter` and `nc-redis-exporter` are running (see the Nextcloud README).
- The public HTTPS endpoint you actually use in production is the one configured in the
  Blackbox HTTP probe to `status.php` in the monitoring stack.

### 1) Alert rules and incident links

Alert rules for Nextcloud are defined in:

- `stacks/monitoring/prometheus/rules/nextcloud.rules.yml`

They follow the global label standard (`severity`, `service`, `component`, `scope`) and the Alertmanager routing/inhibition model documented under `docs/alerting/`.

Operationally, the key signals are:

- Public endpoint availability (`NextcloudEndpointDown`)
- Public endpoint latency/SLO degradation (`NextcloudEndpointSlow`)
- Dependency exporter health (MariaDB / Redis) as secondary diagnostics

Runbook and dashboard links (if present) are exposed in Telegram notifications.

### 2) Grafana – Nextcloud – Service overview

The dashboard is meant to answer three questions in one screen:

1. Is the public Nextcloud endpoint up and within its SLO?
2. Are MariaDB and Redis behaving normally for this instance?
3. Are there unexpected application errors in the logs?

Layout summary (the dashboard lives in **20_Apps / Nextcloud – Service Overview**):

**Top row – availability & SLO**

- Status of the public `status.php` probe (panel override: *Last 5 minutes*).
- 24‑hour HTTP probe success rate for `status.php`.
- Availability of the mysqld_exporter and redis_exporter (panels overridden to *Last 5 minutes*).

**Second row – behaviour under normal load**

- HTTP latency to `status.php` from the Blackbox exporter.
- MariaDB queries per second and active connections.
- Redis commands per second and connected clients.

**Third row – application logs**

- *Nextcloud – Application errors* – Loki query that surfaces application-level failures from the `nc-app` container logs. The panel is intentionally focused on error/exception-like messages; use the “View logs in Loki (Nextcloud)” link for deeper triage and surrounding context.

Security: This dashboard includes public service endpoints and may surface sensitive log content; restrict access and redact before sharing.

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

### 1) Alert rules and incident links

Backup alert rules are defined in:

- `stacks/monitoring/prometheus/rules/backups.rules.yml`
- `stacks/monitoring/prometheus/rules/infra.rules.yml` (host-level backup disk signals)

The policy is:
- Hard RPO breaches are **critical**.
- “Failed last run” and “duration/growth anomalies” are typically **warning**.
- Missing backup metrics are treated as **critical** (instrumentation failure is operationally equivalent to “no backups”).

For the full catalog and thresholds, see `docs/alerting/prometheus-rules.md`.

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
    (appears in Grafana under **20_Apps / CouchDB – Service Overview**).

The only assumptions are that:

- The CouchDB stack is attached to the `mon-net` network and runs the
  `couchdb-exporter` container as documented in the CouchDB README.
- The exporter is scraped by Prometheus under `job="couchdb"` and labelled
  consistently with the rest of the homelab (`stack="couchdb"`,
  `service="couchdb"`, `env="home|lab"`).
- The public HTTPS endpoint exposed through the reverse proxy / tunnel is
  the one configured in the Blackbox HTTP probe to `/_up`.

### 1) Alert rules and incident links

Alert rules for CouchDB are defined in:

- `stacks/monitoring/prometheus/rules/couchdb.rules.yml`

The rule set focuses on:
- Public endpoint health (Blackbox probe)
- Exporter scrape availability
- Elevated 5xx error share under load

All alerts are warning-level by policy for this service tier.
Refer to `docs/alerting/overview.md` for routing and quiet hours.

### 2) Grafana – CouchDB – Service Overview

The **CouchDB – Service Overview** dashboard is meant to answer, on a
single screen:

1. Is CouchDB reachable both from Prometheus and from the public HTTP
   entrypoint?
2. How much traffic is the node handling and how clean are the responses?
3. Are there signs of internal resource pressure inside the Erlang VM?

Layout summary (the dashboard lives in **20_Apps / CouchDB – Service Overview**):

**Top row – health & external reachability**

- Exporter scrape status via `up{job="couchdb"}` with a time override to
  *Last 5 minutes*.
- Public HTTPS endpoint health via the Blackbox probe to `/_up`.
- HTTP 5xx error share (%, last 5 minutes).
- HTTP 5xx error rate (req/s) to quantify failures under load.

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

---

Notes:

- Panel descriptions follow the CFIS convention: `Context / Focus / Implementation / Security`.
- The top-row health panels use a *Last 5 minutes* relative time override to reflect current state.

## 24) Loki logs quick search (logs overview)

The monitoring stack also exposes a dedicated Grafana dashboard for exploring
Loki logs coming from Docker workloads. The goal is to provide a single,
opinionated entry point for log-based troubleshooting that reuses the same
`stack → service → container` model as the Docker infra dashboards, instead of
sending you straight to Grafana Explore.

- One Grafana dashboard:

  - `stacks/monitoring/grafana/dashboards/exported/mon/30_logs/logs-quick-search.json`
    (appears in Grafana under **30_Logs / Loki – Logs quick search**).

The only assumptions are that:

- Promtail is scraping Docker container logs with `job="dockerlogs"` and
  attaching the standard labels used in the homelab (`stack`, `compose_service`,
  `container`, `env`, `repo`, etc.).
- Loki is configured as a Grafana datasource and uses the same retention,
  RBAC and access controls as the rest of the monitoring stack.
- Loki is configured with a defined retention period and an ingest window that
  rejects samples older than 14 days (`reject_old_samples_max_age=336h`), to
  prevent badly-timestamped backfills from polluting the log store.
- Service dashboards (Nextcloud, AdGuard, Cloudflared, CouchDB) and the
  Docker containers overview use labels compatible with those Loki log
  streams (`stack` and `compose_service` in particular).

### 1) Loki label model and error definition

All log exploration in this dashboard is built on top of the following label
conventions:

- `job="dockerlogs"` for all container logs ingested from the Docker host.
- `stack` → logical stack (`nextcloud`, `monitoring`, `cloudflared`,
  `adguard-home`, `couchdb`, …).
- `compose_service` → Docker Compose service name (`grafana`, `loki`,
  `nc-web`, `cloudflared`, `adguard-home`, `couchdb`, …).
- `container` → concrete container name (`mon-grafana`, `mon-loki`, etc.).

For error-focused panels, the dashboard uses a consistent definition of
“error-level logs”:

- Only log lines where the `level` field is one of
  `error`, `critical`, `fatal` or `panic` are considered.
- This is implemented via a Loki filter:

  - `|~ "level=(error|critical|fatal|panic)"`

Panels that show raw logs on purpose **do not** apply this filter; they are
meant to display all log levels and rely on a free-text search field for
ad-hoc investigations.

### 2) Grafana – Loki – Logs quick search

The **Loki – Logs quick search** dashboard is designed to answer, on a small
number of screens:

1. Which stack is currently generating the most error-level logs?
2. Within that stack, which services are the noisiest?
3. How have error rates evolved over time for a given service?
4. What do the actual error log lines look like, and what else is the service
   logging around those errors?

Layout summary (the dashboard lives in **30_Logs / Loki – Logs quick search**):

**Row 1 – stack and service error overview**

- **Error log volume by stack**
  Time series showing error-level log counts per `stack` over the selected
  time range, aggregated from `{job="dockerlogs"}` and filtered with
  `level=(error|critical|fatal|panic)`.

- **Top services by error volume**
  Top-10 `compose_service` entries per stack by error-level log count, based
  on the same filter and restricted to the selected `$stack` value.

**Row 2 – selected service error detail**

- **Errors over time (selected service)**
  Error-level log counts for the selected `stack` / `service`
  (and `container`, if specified) in 5-minute buckets. This helps distinguish
  between brief spikes and sustained error periods.

- **Recent error samples (selected service)**
  Recent error-level log lines for the same filters, to quickly see what kind
  of failures are happening (timeouts, auth issues, backend errors, etc.)
  without having to jump straight into Explore.

**Row 3 – raw logs with search**

- **Raw logs (selected service, with search)**
  Full Loki log view for the same `stack` / `service` / `container` filters,
  without any log-level restrictions, plus a `$search` text box that applies
  a simple `|= "$search"` filter to match arbitrary substrings such as host
  names, SQLSTATE codes or request IDs.

To avoid having to rebuild filters manually, several dashboards expose direct
links into this logs quick search:

- **20_Apps / AdGuard, Cloudflared, CouchDB, Nextcloud**
  Each service overview dashboard includes a `View logs in Loki (…)` link
  that opens the logs quick search with the corresponding `stack` and
  `service` pre-selected and the current time range preserved.

- **10_Infra / Containers – Docker overview**
  Provides a `View logs in Loki (selected container)` link that passes the
  currently selected `stack`, `service` and `container` to the logs quick
  search dashboard, acting as a natural second step after spotting CPU/RAM
  or restart anomalies in Docker.

Taken together, the Loki logs quick search dashboard and these data links
provide a clear, repeatable troubleshooting path: from service or infra
overviews, to error-level log behaviour, and finally to raw logs and
free-text search when deeper analysis is required.
