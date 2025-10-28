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
* Cloudflared Tunnel running on the same `proxy` network (see the `cloudflared` stack).

---

## Runtime configuration

### `.env` (copied from `.env.example`)

```dotenv
COUCHDB_USER=admin
COUCHDB_PASSWORD=change-me

# Optional local bind for testing only
# BIND_LOCALHOST=127.0.0.1
# HTTP_PORT=5984
```

### `local.d/` (real config mounted into the container)

* **Required:** `30-auth.ini` with a unique secret

  ```ini
  [chttpd_auth]
  secret = <HEX_64>  ; generate with: openssl rand -hex 32
  ```

  Create it once:

  ```bash
  mkdir -p /opt/homelab-runtime/stacks/couchdb/local.d
  printf "[chttpd_auth]\nsecret = %s\n" "$(openssl rand -hex 32)" \
    > /opt/homelab-runtime/stacks/couchdb/local.d/30-auth.ini
  chmod 600 /opt/homelab-runtime/stacks/couchdb/local.d/30-auth.ini
  ```

* **Optional:** `10-cors.ini` (useful for LiveSync or web frontends)

  ```ini
  [cors]
  origins = https://couchdb.<your-domain>
  credentials = true
  methods = GET, PUT, POST, HEAD, DELETE
  headers = accept, authorization, content-type, origin, referer, user-agent

  [chttpd]
  enable_cors = true
  ```

* **Optional:** `00-local.ini`

  ```ini
  [chttpd]
  bind_address = 0.0.0.0
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
