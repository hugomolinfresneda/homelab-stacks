# Nextcloud Stack (App · Cron · MariaDB · Mysqld-exporter · Redis · Redis-exporter · Web)

## Overview
This stack provides a Nextcloud deployment with app/web/db/redis/cron services, split between the public stacks repo and your private runtime. Images are pinned by digest, containers include healthchecks, and the base compose stays portable (no host ports; you only publish what you need via your reverse proxy / tunnel).

---

## Components
- `app` (PHP‑FPM): Nextcloud core.
- `web` (Nginx internal): serves static assets and forwards PHP to `app`.
- `db` (MariaDB): database.
- `redis`: cache/locking.
- `cron`: runs `cron.php`.
- `mysqld-exporter` (Prometheus): MariaDB metrics exporter (optional, monitoring profile).
- `redis-exporter` (Prometheus): Redis metrics exporter (optional, monitoring profile).

---

## Architecture

```
                        (HTTPS)                                                      
Client  ─────►  Tunnel  ───────────────────────────────────┐                         
                                                           │                         
                                                           │                         
                                                           │ docker network: proxy   
                                                           ▼                         
                                                    ┌─────────────┐                  
                                                    │ web (Nginx) │                  
                                                    │   :8080     │                  
                                                    └──────┬──────┘                  
                                                           │                         
                                                           │                         
                      ┌────────────────────────────────────┼────────────────────────┐
                      ▼                     docker network:│nc-net                  ▼
                                                           ▼                         
                                                    ┌─────────────┐                  
                                                    │ app         │                  
                               ┌───────────────────►│ (Nextcloud) │                  
                               │                    │    :9000    │                  
                  runs cron.php│(PHP CLI)           └─────────┬───┘                  
                               │                              │                      
                               │                     ┌────────┴──────────┐           
                        ┌──────┴──────┐              │                   │           
                        │ cron        │       cache +│locks            DB│queries    
                        │ (Nextcloud) │              │                   │           
                        │    :9000    │              ▼                   ▼           
                        └─────────────┘          ┌────────┐        ┌──────────────┐  
                                                 │ redis  │        │ db (MariaDB) │  
                                                 │  :6379 │        │   :3306      │  
                                                 └────────┘        └──────────────┘  
                                                     ▲                    ▲          
                                                Redis│protocol      status│queries   
                                                ┌────┴─────┐         ┌────┴─────┐    
                                                │ redis-   │         │ mysqld-  │    
                                                │ exporter │         │ exporter │    
                                                │  :9121   │         │  :9104   │    
                                                └──────────┘         └──────────┘    
                                                     ▲                    ▲          
                               ┌─────────────────────┼────────────────────┼─────────┐
                               ▼ docker network:     │                    │         ▼
                                        mon-net      └───────────┬────────┘          
                                                          scrapes│/metrics           
                                                          ┌──────┴─────┐             
                                                          │ Prometheus │             
                                                          │   :9090    │             
                                                          └────────────┘             
```

> **Networks**: `nc-net` (internal Nextcloud network), `proxy` (reverse proxy / tunnel),
> and `mon-net` (monitoring exporters; only needed with `PROFILES=monitoring`). Create them if missing:
>
> ```bash
> docker network create nc-net  || true
> docker network create proxy   || true
> docker network create mon-net || true
> ```

---

## Repo contract and file layout
This stack follows the standard repo/runtime split. See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

Use the canonical variables for absolute paths:
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"
```

**Public repo** (`${STACKS_DIR}`):
```
stacks/nextcloud/
├── .env.example
├── README.md
├── backup/
│   ├── README.backup.md
│   ├── README.dr.md
│   ├── nc-backup.env.example
│   ├── nc-backup.sh
│   └── nc-restore.sh
├── compose.override.example.yaml
├── compose.yaml
├── config/
│   ├── 10-redis.config.php.example
│   └── 20-proxy.config.php.example
├── exporters/
│   └── mysqld-exporter.my.cnf.example
├── nginx.conf
├── php.ini
├── secrets/
│   └── db.env.example
└── tools/
    ├── nc
    └── occ
```

**Private runtime** (`${RUNTIME_ROOT}`):
```
stacks/nextcloud/            # runtime overlay (environment-specific)
├── .env
├── db.env                   # DB secrets (real values)
├── exporters/
│   └── mysqld-exporter.my.cnf  # DB credentials for the exporter
└── compose.override.yaml    # host binds, secrets mounts, environment wiring
```

---

## Requirements

### Software
- Docker Engine + Docker Compose plugin (v2)
- GNU Make
- (Optional) `curl` for internal smoke tests.

### Shared Docker networks
See the **Networks** note above for required external networks.

### Network / Ports
The base compose does **not** publish host ports (`ports:` is empty); it only exposes internal ports via `expose:`. Publish UI access (`web`) via your reverse proxy or runtime override.

| Service | Host published (`ports`) | Container (`expose`) | Notes |
|---|---|---|---|
| `web` | No (publish via proxy/override) | `8080` | UI. Publish via runtime override only for local testing; production access should go through reverse proxy/tunnel to `web:8080` on the `proxy` network. |
| `app` | N/A (internal only) | `9000` | PHP‑FPM internal. |
| `db` | N/A (internal only) | `3306` | MariaDB internal. |
| `redis` | N/A (internal only) | `6379` | Redis internal. |
| `cron` | N/A (internal only) | — | No exposed port. |
| `mysqld-exporter` | N/A (internal only) | `9104` | Prometheus scrape on `mon-net` (monitoring profile). |
| `redis-exporter` | N/A (internal only) | `9121` | Prometheus scrape on `mon-net` (monitoring profile). |

### Storage
Host paths are defined in runtime; named volumes are managed by Docker.

| Purpose | Host (runtime) | Container | RW | Notes |
|---|---|---|---:|---|
| Nextcloud data/code/config | Docker named volume `nextcloud_nextcloud` | `/var/www/html` | ✅ | Do not bind‑mount `/var/www/html`. |
| MariaDB data | Docker named volume `nextcloud_db` | `/var/lib/mysql` | ✅ | DB persistence. |
| Redis AOF | Docker named volume `nextcloud_redis` | `/data` | ✅ | Redis persistence. |

---

## Helper commands
This repo ships with helper targets for the Nextcloud stack.
> You can invoke them either as `make <target> stack=nextcloud` or via the `make nc-<target>` alias.
> Discovery: run `make nc-help` to list all Nextcloud shortcuts.

| Target | Description | Invoke (full) | Invoke (alias) |
|---|---|---|---|
| Install | Bootstrap Nextcloud on first run (one‑time setup). | `make install stack=nextcloud` | `make nc-install` |
| Post | Post configuration (cron, trusted_domains, basic repairs). | `make post stack=nextcloud` | `make nc-post` |
| Status | Print Nextcloud status and HTTP checks. | `make status stack=nextcloud` | `make nc-status` |
| Reset DB | Drop DB volume only (app data remains). | `make reset-db stack=nextcloud` | `make nc-reset-db` |
| Logs (follow) | Tail app logs with follow. | `make logs stack=nextcloud follow=true` | `make nc-logs follow=true` |

---

## Quickstart (Makefile + helper)

```bash
# 1) Canonical variables (adjust for your host)
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/nextcloud"

# 2) Prepare runtime override
mkdir -p "${RUNTIME_DIR}"
cp "${STACKS_DIR}/stacks/nextcloud/compose.override.example.yaml" \
  "${RUNTIME_DIR}/compose.override.yaml"
# EDIT: ${RUNTIME_DIR}/compose.override.yaml

# 3) Prepare env/runtime config
cp "${STACKS_DIR}/stacks/nextcloud/.env.example" "${RUNTIME_DIR}/.env"
cp "${STACKS_DIR}/stacks/nextcloud/secrets/db.env.example" "${RUNTIME_DIR}/db.env"
# EDIT: ${RUNTIME_DIR}/.env and ${RUNTIME_DIR}/db.env

# 4) Bring up the stack
cd "${STACKS_DIR}"
make nc-up

# 5) Install and post-config (helper flow)
make nc-install
make nc-post

# 6) Verify Nextcloud status (should show installed:true)
make nc-status

# 7) Docker stack status
make nc-ps

# 8) Logs
make nc-logs follow=true
```

### Optional monitoring exporters profile
```bash
cp "${STACKS_DIR}/stacks/nextcloud/exporters/mysqld-exporter.my.cnf.example" "${RUNTIME_DIR}/exporters/mysqld-exporter.my.cnf"
# EDIT: ${RUNTIME_DIR}/exporters/mysqld-exporter.my.cnf

# Ensure the runtime override mounts the credentials file:
# EDIT: ${RUNTIME_DIR}/compose.override.yaml (uncomment the mysqld-exporter bind)

make up stack=nextcloud PROFILES=monitoring
# or the shortcut:
make up-mon stack=nextcloud
```
Enables `mysqld-exporter` (9104) and `redis-exporter` (9121) on `mon-net`.
Create `${RUNTIME_ROOT}/stacks/nextcloud/exporters/mysqld-exporter.my.cnf` from the example and mount it in the runtime override.

---

## Configuration

### Variables (.env)
- Example: `stacks/nextcloud/.env.example`
- Runtime: `${RUNTIME_DIR}/.env` (**not versioned**)

| Variable | Required | Example | Description |
|---|---:|---|---|
| `COMPOSE_PROJECT_NAME` | ✅ | `nextcloud` | Container/volume prefix. |
| `TZ` | ✅ | `Region/City` | Timezone. |
| `PUID` / `PGID` | ✅ | `1000` | UID/GID for processes (cron). |
| `NC_DOMAIN` | ✅ | `cloud.example.com` | Public FQDN for trusted domains. |
| `NC_DB_NAME` | ✅ | `nextcloud` | DB name. |
| `NC_DB_USER` | ✅ | `ncuser` | DB user. |
| `NC_DB_PASS` | ✅ | `<secret>` | DB password. |
| `NC_DB_ROOT` | ✅ | `<secret>` | DB root password. |
| `NC_ADMIN_USER` | ✅ | `admin` | Initial admin user. |
| `NC_ADMIN_PASS` | ✅ | `<secret>` | Initial admin password. |
| `PHP_MEMORY_LIMIT` | ❌ | `512M` | PHP memory limit. |
| `PHP_UPLOAD_LIMIT` | ❌ | `2G` | PHP upload limit. |
| `BIND_LOCALHOST` | ❌ | `127.0.0.1` | Optional host bind for `web:8080` (runtime override). |
| `HTTP_PORT` | ❌ | `8082` | Optional host port for `web:8080` (runtime override). |


> `compose.yaml` maps `NEXTCLOUD_ADMIN_*` and `MYSQL_*` from `NC_*`.

---

## Runtime overrides
Files:
- Example: `stacks/nextcloud/compose.override.example.yaml`
- Runtime: `${RUNTIME_DIR}/compose.override.yaml`

What goes into runtime overrides:
- `ports:` (host bind) and host‑specific mounts.
- secrets/sensitive config.
- host‑specific tuning (UID/GID, SELinux, etc.).

---

## Operations (Makefile + helper)

### Logs
```bash
make nc-logs follow=true
```

### Stop / start
```bash
make down stack=nextcloud

# Standard start (no exporters)
make up stack=nextcloud
# OR start with monitoring exporters
make up-mon stack=nextcloud
```

### Update images
```bash
make pull stack=nextcloud
make up stack=nextcloud
```

### Validation (repo‑wide)
```bash
make lint
make validate
```

---

## Publishing (Cloudflare Tunnel)

1. Add the ingress rule to your tunnel config:

```yaml
# ${RUNTIME_ROOT}/stacks/cloudflared/config.yml
ingress:
  - hostname: nextcloud.<your-domain>
    service: http://web:8080
  - service: http_status:404
```

2. Create the DNS record in Cloudflare (Dashboard → DNS → Records):

- Type: **CNAME**
- Name: `nextcloud`
- Target: `<TUNNEL_UUID>.cfargotunnel.com`
- Proxy: **Proxied**

3. Restart the tunnel container:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

4. Verify externally:

```bash
curl -I https://nextcloud.<your-domain>/status.php
# HTTP/2 200
```

---

## Security notes

- Keep secrets in `${RUNTIME_DIR}` with restrictive permissions (`chmod 600`).
- Avoid bind‑mounting `/var/www/html` (can break config writes).
- Public exposure must be behind a reverse proxy/tunnel with TLS.

---

## Backups and DR
Nextcloud uses **dedicated backup/restore** (not Restic infra):
- Backup/restore guide: `stacks/nextcloud/backup/README.backup.md`
- DR guide: `stacks/nextcloud/backup/README.dr.md`

Makefile targets:
- `make backup stack=nextcloud BACKUP_DIR=... [BACKUP_ENV=...]`
- `make backup-verify stack=nextcloud BACKUP_DIR=...`
- `make restore stack=nextcloud BACKUP_DIR=... [RUNTIME_DIR=...]`

Infra backups (Restic): `ops/backups/README.md`.

---

## Troubleshooting

### Quick checks
```bash
make nc-ps
make logs stack=nextcloud follow=true
```

### Escape hatch (debug)
```bash
cd "${STACKS_DIR}"
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "stacks/nextcloud/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  ps
```

### Common issues
- **“Cannot write into config directory!”**
  - **Likely cause**: host bind‑mount of `/var/www/html`.
  - **Fix**: use named volume and let the container manage `config/`.
- **HTTP 502 from reverse proxy**
  - **Likely cause**: `app` not ready or upstream mismatch.
  - **Fix**: check `app`/`web` logs and confirm upstream to `web:8080` on `proxy` network.
- **HTTP 400 on `/status.php`**
  - **Likely cause**: missing `Host` header.
  - **Fix**: send the request with `Host: ${NC_DOMAIN}`.
