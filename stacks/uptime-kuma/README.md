# Uptime Kuma — Self-hosted monitoring & status page

Uptime Kuma provides a clean interface for monitoring the availability of your self-hosted services and public endpoints.

This stack follows the **two-repository architecture** of the homelab:

- **homelab-stacks** → public base definitions (no secrets, reusable).
- **homelab-runtime** → private overrides, environment, and persistent data.

---

## Repo contract (links)
This stack follows the standard repo/runtime split. See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

---

## Repository structure

| Repository          | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation). |
| **homelab-runtime** | Private overrides (`compose.override.yaml`, `.env`, persistent data).   |

---

## Components
- `uptime-kuma`
- Networks: `proxy`, `mon-net`

---

## Requirements

### Software
- Docker Engine + Docker Compose plugin
- GNU Make (`make`)

### Shared Docker networks
```bash
docker network create proxy   || true
docker network create mon-net || true
```

### Networking / Ports
| Service | Exposure | Host | Container | Protocol | Notes |
|---|---|---|---:|---|---|
| `uptime-kuma` | Internal only (`expose`) | — | 3001 | tcp | Reachable on `proxy` and `mon-net`. |
| `uptime-kuma` | Host-published (optional, runtime override) | `${BIND_LOCALHOST:-127.0.0.1}:${HTTP_PORT:-3001}` | 3001 | tcp | Optional local bind for direct access. |

### Storage
> Host paths are **runtime-only** (no hardcoded paths in the repo).

| Purpose | Host (runtime) | Container | RW | Notes |
|---|---|---|---:|---|
| Data | `${RUNTIME_ROOT}/stacks/uptime-kuma/data` | `/app/data` | Yes | Application data. |

---

## Quickstart (Makefile)

```bash
# 1) Canonical variables (adjust to your host)
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/uptime-kuma"

# 2) Prepare runtime (overrides + environment variables)
mkdir -p "${RUNTIME_DIR}"
cp "stacks/uptime-kuma/compose.override.example.yaml" \
  "${RUNTIME_DIR}/compose.override.yaml"
cp "stacks/uptime-kuma/.env.example" "${RUNTIME_DIR}/.env"
# EDIT: ${RUNTIME_DIR}/compose.override.yaml and ${RUNTIME_DIR}/.env

# 3) Bring up the stack
cd "${STACKS_DIR}"
make up stack=uptime-kuma

# 4) Status
make ps stack=uptime-kuma
```

---

## Configuration

### Variables (.env)
- Example: `stacks/uptime-kuma/.env.example`
- Runtime: `${RUNTIME_DIR}/.env` (not versioned)

| Variable | Required | Example | Description |
|---|---|---|---|
| `TZ` | No | `Etc/UTC` | Container timezone. |
| `RUNTIME_DIR` | No (informational) | `/abs/path/to/runtime/stacks/uptime-kuma` | Optional reference path used in examples. |
| `BIND_LOCALHOST` | No | `127.0.0.1` | Optional host bind (runtime override). |
| `HTTP_PORT` | No | `3001` | Optional host port (runtime override). |

### Runtime files (not versioned)
Expected paths in `${RUNTIME_DIR}` (from override example):
- `${RUNTIME_DIR}/data/`

---

## Runtime overrides
Files:
- Example: `stacks/uptime-kuma/compose.override.example.yaml`
- Runtime: `${RUNTIME_DIR}/compose.override.yaml`

What goes into runtime overrides:
- `volumes:` for host persistence paths
- Optional host `ports:` bind for local UI access

---

## Operation (Makefile)

### Logs
```bash
make logs stack=uptime-kuma
```

### Update images
```bash
make pull stack=uptime-kuma
make up stack=uptime-kuma
```

### Stop / start
```bash
make down stack=uptime-kuma
make up stack=uptime-kuma
```

---

## Publishing (Cloudflare Tunnel)

1. Add the ingress rule to your tunnel config:

```yaml
# ${RUNTIME_ROOT}/stacks/cloudflared/config.yml
ingress:
  - hostname: uptime-kuma.<your-domain>
    service: http://uptime-kuma:3001
  - service: http_status:404
```

2. Create the DNS record in Cloudflare (Dashboard  ^f^r DNS  ^f^r Records):

- Type: **CNAME**
- Name: `uptime-kuma`
- Target: `<TUNNEL_UUID>.cfargotunnel.com`
- Proxy: **Proxied**

3. Restart the tunnel container:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

4. Verify externally:

```bash
curl -I https://uptime-kuma.<your-domain>/dashboard
# HTTP/2 200
```

---

## Observability

Uptime Kuma can expose a Prometheus-compatible `/metrics` endpoint, protected with HTTP basic auth.
The monitoring stack scrapes this endpoint and feeds Grafana dashboards.

### 1) Enable metrics in Uptime Kuma

In the Uptime Kuma UI:

1. Go to **Settings → Advanced → Prometheus metrics**.
2. Enable the feature and set a strong password.
3. Leave the username empty (we authenticate with the password only).
4. Save changes.

The endpoint will be available at:

```text
http://uptime-kuma:3001/metrics
```

from within the `mon-net` network.

### 2) Runtime password file (used by Prometheus)

On the monitoring side, the password is stored in a file in the runtime repo:

```bash
mkdir -p "${RUNTIME_ROOT}/stacks/monitoring/secrets"
printf '%s\n' 'the-same-password-you-set-in-kuma' \
  > "${RUNTIME_ROOT}/stacks/monitoring/secrets/kuma_password"
chmod 0444 "${RUNTIME_ROOT}/stacks/monitoring/secrets/kuma_password"
```

The monitoring stack’s runtime override mounts this file into Prometheus:

```yaml
services:
  prometheus:
    volumes:
      - ${RUNTIME_ROOT}/stacks/monitoring/secrets/kuma_password:/etc/prometheus/secrets/kuma_password:ro
```

### 3) Prometheus scrape job (defined in the monitoring stack)

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

---

## Security notes

- Keep the service within the `proxy` and `mon-net` networks; avoid exposing container ports directly to the Internet.
- Restrict Prometheus metrics access to internal networks only (no direct Internet exposure of `/metrics`).
- Consider Cloudflare Access in front of the hostname for SSO/MFA.

---

## Persistence / Backups
Persistence lives under `${RUNTIME_ROOT}/stacks/uptime-kuma/...`.
Backups: see `ops/backups/README.md`.

---

## Escape hatch (debug)
> Use only if you need to inspect the raw compose setup.

```bash
cd "${STACKS_DIR}"
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "stacks/uptime-kuma/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  ps
```
