# CouchDB — Self-hosted database (Obsidian LiveSync ready)

This stack deploys **CouchDB 3** using a two-repo model (public **homelab-stacks** + private **homelab-runtime**).
It is intended to be published via **Cloudflare Tunnel** (no host ports exposed).

---

## Architecture

| Repository          | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition: `compose.yaml`, `.env.example`, docs, examples. |
| **homelab-runtime** | Private overrides: `compose.override.yml`, `.env`, `data/`, `local.d/`. |

---

## File layout

```
/opt/homelab-stacks/stacks/couchdb/
├── compose.yaml
├── .env.example
└── README.md

/opt/homelab-runtime/stacks/couchdb/
├── compose.override.yml
├── .env
├── data/
└── local.d/
    ├── 00-local.ini
    ├── 10-cors.ini
    └── 30-auth.ini
```

---

## Requirements

* Docker + Docker Compose available to your user.
* External Docker network shared by published services:

  ```bash
  docker network create proxy || true
  ```

* External Docker network shared with the monitoring stack:

  ```bash
  docker network create mon-net || true
  ```

* Cloudflared Tunnel running on the same `proxy` network (see the `cloudflared` stack).


---

## Runtime configuration

### `.env` (copied from `.env.example`)

```dotenv
# Copy to homelab-runtime/stacks/couchdb/.env and CHANGE the password
COUCHDB_USER=admin
COUCHDB_PASSWORD=change-me

# Local bind for testing and troubleshooting
# BIND_LOCALHOST=127.0.0.1
# HTTP_PORT=5984
```

### `local.d/` (runtime config)

* **Required:** `00-local.ini` (single-node + bind)

  ```ini
  [couchdb]
  single_node = true

  [chttpd]
  bind_address = 0.0.0.0
````

* **Required:** `30-auth.ini` (auth cookie secret)

  ```ini
  [chttpd_auth]
  secret = <HEX_64>  ; openssl rand -hex 32
  ```

  Template: `local.d/30-auth.ini.example` in `homelab-stacks`.
  Real file: `/opt/homelab-runtime/stacks/couchdb/local.d/30-auth.ini` (mode `600`, not versioned).

* **Optional:** `10-cors.ini` (CORS for LiveSync / web frontends)

  ```ini
  [cors]
  origins = https://couchdb.<your-domain>
  credentials = true
  methods = GET, PUT, POST, HEAD, DELETE
  headers = accept, authorization, content-type, origin, referer, user-agent

  [chttpd]
  enable_cors = true
  ```

---

## Deployment (Makefile shortcuts)

From the runtime repository:

```bash
make up stack=couchdb
make ps stack=couchdb
make logs stack=couchdb
```

Expected internal health:

```bash
docker run --rm --network=proxy curlimages/curl -sS http://couchdb:5984/_up
# {"status":"ok"}
```

---

## Manual deploy (portable)

```bash
docker compose \
  --env-file /opt/homelab-runtime/stacks/couchdb/.env \
  -f /opt/homelab-stacks/stacks/couchdb/compose.yaml \
  -f /opt/homelab-runtime/stacks/couchdb/compose.override.yml \
  up -d
```

---

## Publishing (Cloudflare Tunnel)

1. Add the ingress rule to your tunnel config:

```yaml
# /opt/homelab-runtime/stacks/cloudflared/cloudflared/config.yml
ingress:
  - hostname: couchdb.<your-domain>
    service: http://couchdb:5984
  - service: http_status:404
```

2. Create the DNS record in Cloudflare (Dashboard → DNS → Records):

* Type: **CNAME**
* Name: `couchdb`
* Target: `<TUNNEL_UUID>.cfargotunnel.com`
* Proxy: **Proxied**

3. Verify externally:

```bash
curl -I https://couchdb.<your-domain>/_up
# HTTP/2 200
```

---

## Maintenance

Update image and redeploy:

```bash
make pull stack=couchdb
make up stack=couchdb
```

Backups (include in your restic policy):

```
/opt/homelab-runtime/stacks/couchdb/data/
```

---

## Security notes

* Change the default password in `.env`.
* Keep `30-auth.ini` out of version control.
* Do not expose port 5984 on the host; publish only via the tunnel.
* Consider Cloudflare Access in front of the hostname for SSO/MFA.

---

## Troubleshooting

| Symptom                                    | Likely cause / fix                                                |
| ------------------------------------------ | ----------------------------------------------------------------- |
| `Unable to reach origin service` in tunnel | CouchDB not on `proxy` network or wrong service/port in ingress.  |
| `{"error":"unauthorized"}` on requests     | Wrong `COUCHDB_USER`/`COUCHDB_PASSWORD` or missing CORS settings. |
| `_up` fails internally                     | Container not healthy; check `make logs stack=couchdb`.           |
| Data not persisted                         | Missing `./data:/opt/couchdb/data` bind in runtime override.      |

---

## Monitoring

This stack ships with a Prometheus exporter for CouchDB metrics.

### Exporter container

A `couchdb-exporter` container based on
[`gesellix/couchdb-prometheus-exporter`](https://hub.docker.com/r/gesellix/couchdb-prometheus-exporter)
is started alongside the main `couchdb` service.

The exporter is attached to two Docker networks:

- `proxy`: used to reach the `couchdb` container at `http://couchdb:5984`.
- `mon-net`: shared with the monitoring stack so that Prometheus can
  scrape the exporter.

The exporter exposes Prometheus metrics on:

```text
http://couchdb-exporter:9984/metrics
```

### Authentication

For simplicity in this homelab setup, the exporter reuses the CouchDB
admin credentials defined in the `.env` file:

```env
COUCHDB_USER=
COUCHDB_PASSWORD=
```

These are passed to the exporter via:

```yaml
environment:
  COUCHDB_USERNAME: ${COUCHDB_USER}
  COUCHDB_PASSWORD: ${COUCHDB_PASSWORD}
```

No additional CouchDB user is created for monitoring. If you need
separate credentials in the future, you can introduce a dedicated
`COUCHDB_MON_USER` / `COUCHDB_MON_PASSWORD` pair and adjust the
exporter configuration accordingly.

### Prometheus integration

The `couchdb` scrape job is defined in the monitoring stack and targets
the exporter on `mon-net`. An example scrape config is provided in:

```text
stacks/monitoring/prometheus/couchdb.yml.example
```

For details on alerting rules and dashboards that consume these
metrics, refer to the `stacks/monitoring/README.md` document.

### Grafana dashboard

The monitoring stack ships a dedicated Grafana dashboard for CouchDB:

- `stacks/monitoring/grafana/dashboards/exported/mon/20_apps/couchdb-service-overview.json`

Dashboard scope:

- **Health (last 5m):** exporter scrape status and public endpoint status (Blackbox probe).
- **Traffic & errors:** request throughput and HTTP status distribution (req/s), plus 5xx share (%, last 5m) and 5xx rate (req/s).
- **Capacity:** internal counters such as open databases and open OS files to surface resource pressure.

Security: CouchDB is published via the tunnel; treat hostnames and endpoint metadata as operationally sensitive when sharing screenshots or exports.



---

## Useful commands

```bash
# Effective compose (debug)
docker compose \
  -f /opt/homelab-stacks/stacks/couchdb/compose.yaml \
  -f /opt/homelab-runtime/stacks/couchdb/compose.override.yml \
  config

# Quick version check
docker run --rm --network=proxy curlimages/curl -s http://couchdb:5984/ | jq .
```
