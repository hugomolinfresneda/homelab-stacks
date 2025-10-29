# Nextcloud Stack (Docker) — Enterprise-Friendly README

This stack deploys **Nextcloud** using Docker with a clean separation between the **public stacks repo** and your **private runtime**. It includes:

- `nc-app` (PHP-FPM) — core Nextcloud
- `nc-web` (Nginx internal) — serves static assets and proxies PHP to `nc-app`
- `nc-db` (MariaDB) — database
- `nc-redis` — caching/locking
- `nc-cron` — runs `cron.php` every 5 min

Designed for reproducibility (images pinned by **digest**), operational clarity, and minimal host binds (no bind-mount of `/var/www/html`).

---

## 1) Architecture

```
Client ──(HTTPS)──▶ Reverse Proxy / Tunnel
                        │
                        └──▶ docker network 'proxy' ───→  nc-web (Nginx :8080)
                                                          ├─→ nc-app  (php-fpm :9000)
                                                          ├─→ nc-db   (MariaDB)
                                                          ├─→ nc-redis
                                                          └─→ nc-cron
```

- The **reverse proxy / tunnel** (e.g., Nginx front, Cloudflare Tunnel) terminates TLS and proxies to `http://nc-web:8080` on the `proxy` network.
- `nc-web` uses the included `nginx.conf` (from the **public** repo) and forwards PHP to `nc-app:9000`.
- **No host port** in the base compose. Host binding is defined in **runtime** via `compose.override.yml`.

> **Note**: Create the external docker network used by your reverse proxy if it does not exist:
>
> ```bash
> docker network create proxy || true
> ```

---

## 2) Repos layout

**Public repo** (e.g., `/opt/homelab-stacks`):
```
stacks/nextcloud/
├─ compose.yaml
├─ nginx.conf
├─ php.ini
├─ .env.example
├─ config/
│  ├─ 10-redis.config.php.example
│  └─ 20-proxy.config.php.example
└─ tools/
   ├─ nc     # helper wrapper (idempotent CLI flow)
   └─ occ    # OCC convenience
```

**Private runtime** (e.g., `/opt/homelab-runtime`):
```
stacks/nextcloud/
├─ .env
└─ compose.override.yml
```

- The **runtime** keeps local, environment-specific settings out of git.
- The **public** stack ships sane defaults and helper scripts.

---

## 3) Prerequisites

- Docker Engine + **Docker Compose v2** (`docker compose ...` syntax)
- An external docker network used by your reverse proxy: `proxy`
- DNS for your public domain (e.g., `cloud.example.com`) pointing to your reverse proxy or tunnel endpoint
- TLS termination at the edge (reverse proxy or Cloudflare Tunnel)

---

## 4) Environment variables

Copy the template from the **public** repo and adjust it in your **runtime**:

```bash
cp /opt/homelab-stacks/stacks/nextcloud/.env.example \
   /opt/homelab-runtime/stacks/nextcloud/.env

$EDITOR /opt/homelab-runtime/stacks/nextcloud/.env
```

**Key variables** (excerpt):
```dotenv
COMPOSE_PROJECT_NAME=nextcloud
TZ=Europe/Madrid

# Public fqdn and trusted domains (space-separated)
NC_DOMAIN=cloud.example.com
NEXTCLOUD_TRUSTED_DOMAINS=${NC_DOMAIN} nc-web localhost

# DB credentials (duplicated for Nextcloud's CLI)
NC_DB_NAME=nextcloud
NC_DB_USER=ncuser
NC_DB_PASS=change-me
NC_DB_ROOT=change-me-too

# Nextcloud admin bootstrap
NC_ADMIN_USER=admin
NC_ADMIN_PASS=change-me
NEXTCLOUD_ADMIN_USER=${NC_ADMIN_USER}
NEXTCLOUD_ADMIN_PASSWORD=${NC_ADMIN_PASS}

# PHP limits
PHP_MEMORY_LIMIT=1024M
PHP_UPLOAD_LIMIT=2G

# Local bind for the internal Nginx (runtime-only)
BIND_LOCALHOST=127.0.0.1
HTTP_PORT=8082
```

> Keeping **both** `NC_*` and `NEXTCLOUD_*`/`MYSQL_*` is deliberate to avoid warnings and ensure CLI operations have all the data.

---

## 5) Compose files

- **Base**: `/opt/homelab-stacks/stacks/nextcloud/compose.yaml`
  - Pinned image digests for `nextcloud`, `nginx`, `mariadb`, `redis`
  - Mounts `nginx.conf` from the **public** repo into `nc-web`
  - Uses named volumes for data: `nextcloud_db`, `nextcloud_redis`, `nextcloud_nextcloud` (Docker auto-prefixes by project)

- **Runtime override**: `/opt/homelab-runtime/stacks/nextcloud/compose.override.yml`
  ```yaml
  services:
    app:
      volumes:
        - ./php.ini:/usr/local/etc/php/conf.d/zzz-custom.ini:ro

    web:
      ports:
        - "${BIND_LOCALHOST:-127.0.0.1}:${HTTP_PORT:-8082}:8080"
  ```

> The runtime does **not** override `nginx.conf` or the `config/` tree. This avoids “Cannot write into config directory” and other bind headaches.

---

## 6) Operations (two options)

### Option A — Using the **helper** (recommended first run)

The helper lives in the **public** repo and orchestrates idempotent install + post-setup:

```bash
# Up in two phases: (db,redis) → (app,web,cron)
/opt/homelab-stacks/stacks/nextcloud/tools/nc up

# Install (waits for container-side bootstrap and seeds config snippets)
/opt/homelab-stacks/stacks/nextcloud/tools/nc install

# Post-setup (cron mode, trusted_domains, basic repairs)
/opt/homelab-stacks/stacks/nextcloud/tools/nc post

# Status (occ + HTTP check)
/opt/homelab-stacks/stacks/nextcloud/tools/nc status

# Logs (follow app logs)
/opt/homelab-stacks/stacks/nextcloud/tools/nc logs

# Down
/opt/homelab-stacks/stacks/nextcloud/tools/nc down
```

What the helper does for you:

- Ensures the Nextcloud code is present and OCC is callable
- Waits for container-driven installation (avoids partial installs)
- Seeds `config/10-redis.config.php` and `config/20-proxy.config.php` **inside** the container if missing
- Sets `trusted_domains` (incl. `nc-web` and `localhost`) and switches background jobs to `cron`
- Runs basic DB repairs and shows a final status
- Has a `QUIET=1` mode to reduce noise

### Option B — Using **make** from the runtime

The runtime Makefile special-cases Nextcloud so relative binds (e.g. `nginx.conf` from the **public** repo) resolve correctly.

```bash
# Start containers (base + override)
make up stack=nextcloud

# Stop
make down stack=nextcloud

# Status (delegates to the helper)
make status stack=nextcloud

# First-time install and post-setup (delegates to the helper)
make install stack=nextcloud
make post    stack=nextcloud
```

> For Nextcloud, the runtime Makefile intentionally **does not** use `--project-directory`, preventing path resolution issues with binds from the public repo.

---

## 7) Reverse proxy / Tunnel

- **Nginx front**: proxy to `http://nc-web:8080`. Ensure large body sizes (`client_max_body_size 2G`) and forward headers (`X-Forwarded-*`). The internal `nginx.conf` already has sane defaults for PHP, caching and well-known routes.
- **Cloudflare Tunnel**: point your ingress to `http://nc-web:8080` on the **`proxy`** network. A 502 typically means wrong service/port or the service is not on the same network.

---

## 8) Health & smoke tests

From the runtime host:
```bash
# Docker-level health
docker compose \
  -f /opt/homelab-stacks/stacks/nextcloud/compose.yaml \
  -f /opt/homelab-runtime/stacks/nextcloud/compose.override.yml \
  --env-file /opt/homelab-runtime/stacks/nextcloud/.env \
  ps

# Intra-network HTTP check (200/302/403 are ok during bootstrap)
docker run --rm --network nextcloud_default curlimages/curl:8.10.1 -sSI http://nc-web:8080 | head -n1
```

If you see `HTTP/1.1 400 Bad Request` without a `Host`, try with your domain header:
```bash
docker run --rm --network nextcloud_default curlimages/curl:8.10.1 \
  -sSI -H "Host: ${NC_DOMAIN}" http://nc-web:8080/status.php | head -n1
```

---

## 9) Data & backups (quick notes)

**Named volumes** (auto-prefixed by `COMPOSE_PROJECT_NAME=nextcloud`):
- `nextcloud_db` — MariaDB data
- `nextcloud_redis` — Redis AOF
- `nextcloud_nextcloud` — Nextcloud code tree, incl. `/var/www/html/config` and `/var/www/html/data`

**Ad-hoc DB dump** (example):
```bash
docker exec -i nc-db sh -lc 'exec mysqldump -u"$$MARIADB_USER" -p"$$MARIADB_PASSWORD" "$$MARIADB_DATABASE"' > nextcloud.sql
```

**Full stop & copy** (cold backup; example outline):
```bash
/opt/homelab-stacks/stacks/nextcloud/tools/nc down
docker run --rm -v nextcloud_nextcloud:/vol -v "$PWD":/backup busybox tar czf /backup/nextcloud-data.tgz -C /vol .
docker run --rm -v nextcloud_db:/vol -v "$PWD":/backup busybox tar czf /backup/mariadb.tgz -C /vol .
```

> For production-grade backups: schedule DB dumps + volume snapshots and test restores regularly.

---

## 10) Updates (safe flow)

1. Ensure a recent backup.
2. Pull images:
   ```bash
   make pull stack=nextcloud
   ```
3. Recreate:
   ```bash
   make up stack=nextcloud
   ```
4. Inside `nc-app`, run post-maintenance (idempotent):
   ```bash
   /opt/homelab-stacks/stacks/nextcloud/tools/occ upgrade || true
   /opt/homelab-stacks/stacks/nextcloud/tools/occ db:add-missing-indices || true
   /opt/homelab-stacks/stacks/nextcloud/tools/occ maintenance:repair || true
   ```

> Image **digests** are pinned in `compose.yaml`. Bump digests in a dedicated PR when you decide to upgrade.

---

## 11) Troubleshooting

- **“Cannot write into config directory!”**
  - Do **not** bind-mount `/var/www/html` from the host.
  - Let the helper create `config/` **inside** the container and seed snippets.
- **HTTP 502 from `nc-web`**
  - `nc-app` not ready yet (check `docker logs nc-web`/`nc-app`).
  - Wrong upstream — ensure `fastcgi_pass nc-app:9000` is intact in `nginx.conf`.
- **HTTP 400 on `/status.php`**
  - Missing `Host` header. Test with your domain using `-H "Host: ${NC_DOMAIN}"`.
- **DB errors on fresh installs**
  - If you reinstalled many times: wipe controlled (only if safe to do):
    ```bash
    /opt/homelab-stacks/stacks/nextcloud/tools/nc down
    docker volume rm nextcloud_db nextcloud_nextcloud nextcloud_redis || true
    /opt/homelab-stacks/stacks/nextcloud/tools/nc up
    /opt/homelab-stacks/stacks/nextcloud/tools/nc install
    /opt/homelab-stacks/stacks/nextcloud/tools/nc post
    /opt/homelab-stacks/stacks/nextcloud/tools/nc status
    ```

---

## 12) Makefile integration (what happens under the hood)

- The **runtime Makefile** special-cases `stack=nextcloud` to **avoid** `--project-directory`. This ensures paths like `./nginx.conf` in the **public** compose resolve **relative to the public repo**, not the runtime (prevents the “mounting directory onto file” errors).
- The **public Makefile** auto-detects `tools/nc` and **delegates** extra ops (`install`, `post`, `status`, `reset-db`) to the helper.

This yields **parity** between `make` and `tools/nc` and keeps a single source of truth for operational quirks.

---

## 13) File trees (reference)

**Public**:
```
/opt/homelab-stacks/stacks/nextcloud
├─ compose.yaml
├─ nginx.conf
├─ php.ini
├─ .env.example
├─ config/
│  ├─ 10-redis.config.php.example
│  └─ 20-proxy.config.php.example
└─ tools/
   ├─ nc
   └─ occ
```

**Runtime**:
```
/opt/homelab-runtime/stacks/nextcloud
├─ .env
└─ compose.override.yml
```

---

## 14) Quick start (TL;DR)

```bash
# 0) One-time: ensure reverse-proxy docker network exists
docker network create proxy || true

# 1) Prepare env
cp /opt/homelab-stacks/stacks/nextcloud/.env.example \
   /opt/homelab-runtime/stacks/nextcloud/.env
$EDITOR /opt/homelab-runtime/stacks/nextcloud/.env

# 2) Bring up + install + post + verify (helper way)
/opt/homelab-stacks/stacks/nextcloud/tools/nc up
/opt/homelab-stacks/stacks/nextcloud/tools/nc install
/opt/homelab-stacks/stacks/nextcloud/tools/nc post
/opt/homelab-stacks/stacks/nextcloud/tools/nc status

# (or) Runtime make
make up stack=nextcloud
make install stack=nextcloud
make post stack=nextcloud
make status stack=nextcloud
```
