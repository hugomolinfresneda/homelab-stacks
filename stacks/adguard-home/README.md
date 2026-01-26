# AdGuard Home — DNS filtering for your LAN (rootless, no DHCP)

This stack provides network-level ad/tracker blocking via **AdGuard Home**.
It follows the **two-repository model** used across the homelab: a public base and a private runtime.

---

## Repo contract (links)
This stack follows the standard repo/runtime split. See:
- `docs/contract.md`
- `docs/runtime-overrides.md`

---

## Components
- `adguard-home`: DNS filtering + web UI
- `adguard-exporter`: Prometheus exporter for AdGuard API
- Networks: `proxy`, `mon-net`

---

## Requirements

### Software
- Docker Engine + Docker Compose plugin
- GNU Make (`make`)

### Shared Docker networks
```bash
docker network create proxy || true
docker network create mon-net || true
```

### Rootless DNS bind (optional)
For **rootless Docker** binding directly to port 53, lower the unprivileged port range:

```bash
echo 'net.ipv4.ip_unprivileged_port_start=53' | sudo tee /etc/sysctl.d/99-rootless-lower-ports.conf
echo 'net.ipv6.ip_unprivileged_port_start=53' | sudo tee -a /etc/sysctl.d/99-rootless-lower-ports.conf
sudo sysctl --system
```

If `systemd-resolved` is holding `127.0.0.53:53`, disable its stub listener:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf "[Resolve]\nDNSStubListener=no\n" | sudo tee /etc/systemd/resolved.conf.d/10-adguard.conf
sudo systemctl restart systemd-resolved || true
```

*(If the unit doesn’t exist, you can ignore this step.)*

### Networking / Ports
| Service | Exposure | Host | Container | Protocol | Notes |
|---|---|---|---:|---|---|
| `adguard-home` UI | Internal only (`expose`) | — | 3000 | tcp | Reachable on Docker networks (`proxy`, `mon-net`). |
| `adguard-home` UI | Host-published (optional, runtime override) | `${BIND_LOCALHOST:-127.0.0.1}:${WEB_PORT:-3000}` | 3000 | tcp | Optional local bind. |
| `adguard-home` DNS | Host-published (optional, runtime override) | `${BIND_LOCALHOST:-127.0.0.1}:${DNS_PORT:-53}` | 53 | tcp/udp | Optional local bind. Rootless may require sysctl tweak. |
| `adguard-exporter` | Internal only (`expose`) | — | `${ADGUARD_EXPORTER_PORT}` | tcp | Port set via `.env`. |

### Storage
> Host paths are **runtime-only** (no hardcoded paths in the repo).

| Purpose | Host (runtime) | Container | RW | Notes |
|---|---|---|---:|---|
| Config | `${RUNTIME_ROOT}/stacks/adguard-home/conf` | `/opt/adguardhome/conf` | Yes | Contains AdGuard configuration. |
| Data | `${RUNTIME_ROOT}/stacks/adguard-home/work` | `/opt/adguardhome/work` | Yes | Runtime data. |

---

## Quickstart (Makefile)

```bash
# 1) Canonical variables (adjust to your host)
export STACKS_DIR="/abs/path/to/homelab-stacks"
export RUNTIME_ROOT="/abs/path/to/homelab-runtime"
export RUNTIME_DIR="${RUNTIME_ROOT}/stacks/adguard-home"

# 2) Prepare runtime (overrides + environment variables)
mkdir -p "${RUNTIME_DIR}"
cp "stacks/adguard-home/compose.override.example.yaml" \
  "${RUNTIME_DIR}/compose.override.yaml"
cp "stacks/adguard-home/.env.example" "${RUNTIME_DIR}/.env"
# EDIT: ${RUNTIME_DIR}/compose.override.yaml and ${RUNTIME_DIR}/.env

# 3) Bring up the stack
cd "${STACKS_DIR}"
make up stack=adguard-home

# 4) Status
make ps stack=adguard-home
```

---

## Configuration

### Variables (.env)
- Example: `stacks/adguard-home/.env.example`
- Runtime: `${RUNTIME_DIR}/.env` (not versioned)

| Variable | Required | Example | Description |
|---|---|---|---|
| `TZ` | No | `Etc/UTC` | Container timezone. |
| `WEB_PORT` | No | `3000` | Host UI port (runtime override only). |
| `DNS_PORT` | No | `53` | Host DNS port (runtime override only). |
| `BIND_LOCALHOST` | No | `127.0.0.1` | Bind UI/DNS to loopback (runtime override only). |
| `ADGUARD_PROTOCOL` | No (exporter) | `http` | AdGuard API protocol for exporter. |
| `ADGUARD_HOSTNAME` | No (exporter) | `adguard-home` | AdGuard API hostname for exporter. |
| `ADGUARD_PORT` | No (exporter) | `3000` | AdGuard API port for exporter. |
| `ADGUARD_USER` | No (exporter) | `<user>` | AdGuard API user for exporter. |
| `ADGUARD_PASS` | No (exporter) | `<secret>` | AdGuard API password for exporter. |
| `ADGUARD_EXPORTER_PORT` | No (exporter) | `9617` | Exporter listen port. |
| `ADGUARD_SCRAPE_INTERVAL` | No (exporter) | `30s` | Exporter scrape interval. |

### Runtime files (not versioned)
Expected paths in `${RUNTIME_DIR}` (from override example):
- `${RUNTIME_DIR}/conf/` (AdGuard config directory)
- `${RUNTIME_DIR}/work/` (runtime data directory)

---

## Runtime overrides
Files:
- Example: `stacks/adguard-home/compose.override.example.yaml`
- Runtime: `${RUNTIME_DIR}/compose.override.yaml`

What goes into runtime overrides:
- `volumes:` for host persistence paths
- Optional host `ports:` binds for UI/DNS

---

## Operation (Makefile)

### Logs
```bash
make logs stack=adguard-home
```

### Update images
```bash
make pull stack=adguard-home
make up stack=adguard-home
```

### Stop / start
```bash
make down stack=adguard-home
make up stack=adguard-home
```

### Validation (repo-wide)
```bash
make lint
make validate
```

---

## Publishing (UI via Cloudflare Tunnel)

Keep **DNS strictly in LAN/VPN**. Publish **UI only** through the tunnel:

1. Add the ingress rule to your tunnel config:

```yaml
# ${RUNTIME_ROOT}/stacks/cloudflared/config.yml
ingress:
  - hostname: adguard.<your-domain>
    service: http://adguard-home:3000
  - service: http_status:404
```

2. Create the DNS record in Cloudflare (Dashboard  ^f^r DNS  ^f^r Records):

- Type: **CNAME**
- Name: `adguard`
- Target: `<TUNNEL_UUID>.cfargotunnel.com`
- Proxy: **Proxied**

3. Restart the tunnel container:

```bash
make down stack=cloudflared
make up   stack=cloudflared
```

4. Verify externally:

```bash
curl -I https://adguard.<your-domain>/login.html
# HTTP/2 200
```

---

## Observability

### Prometheus / Grafana

AdGuard is instrumented for metrics and DNS probing:

- **Exporter**: `ebrianne/adguard-exporter` runs as `adguard-exporter` in the same stack.

- **Prometheus jobs** (configured in the `monitoring` stack):

  - `job="adguard-exporter"` scrapes the HTTP metrics endpoint exposed by the exporter.
  - `job="blackbox-dns"` uses Blackbox Exporter to probe DNS resolution via `adguard-home:53`.

- **Alert rules** are defined in the Prometheus rules directory (public repo):

  - `AdGuardExporterDown` — exporter unreachable for several minutes.
  - `AdGuardProtectionDisabled` — AdGuard DNS protection flag turned off for a sustained period.
  - `AdGuardHighLatency` — average DNS processing time above threshold.

  These rules are label-aligned with the rest of the homelab (`stack=dns`, `service=adguard-home`, `env=home`) and expect no secrets in the public repo; credentials are injected via the runtime `.env`.

- A dedicated Grafana dashboard (e.g. `DNS / AdGuard`) can visualise:

  - Queries per second and blocked ratio.
  - Average processing time.
  - Top clients and top blocked domains.
  - Probe status from `blackbox-dns` (`probe_success`).

Dashboard provisioning and JSON definitions are managed under the `monitoring` stack.

**Grafana dashboard:** `AdGuard – Service Overview` (folder `20_apps`)

- **Health (last 5m):** `adguard_running` (UP/DOWN), `adguard_protection_enabled` (Enabled/Disabled), and DNS processing time (ms).
- **Traffic & blocking:** DNS queries (all types), blocked queries, and blocked ratio (%).
- **Query mix:** record type breakdown (A/AAAA/CNAME/HTTPS/…).
- **Top domains (instant snapshot):** most queried and most blocked domains (tables; long domains are truncated to keep the layout readable).

### Uptime Kuma

- **DNS monitor** → Server `<HOST_LAN_IP>`, Port `53`, Record `A` (and optionally `AAAA`).
- **HTTP monitor (internal)** → `http://adguard-home:3000` (same Docker network; bypasses Access).
  *If you prefer external monitoring through Access, use a Service Token and add the CF Access headers in the monitor.*

Quick checks:

```bash
# DNS resolves via AdGuard
dig @<HOST_LAN_IP> example.com A +short

# UI reachable inside Docker network
docker run --rm --network proxy curlimages/curl:8.10.1 -sSI http://adguard-home:3000 | head -n1
```

---

## Security notes

- **Do not** expose port 53 over the tunnel; keep DNS to LAN/VPN.
- Prefer **UI via Cloudflared + Access**; optionally keep the host bind on `127.0.0.1` or remove it entirely.
- Strong admin password; keep `conf/` under backup.
- Run as rootless Docker; volumes are bind-mounted under the runtime path.
- API credentials for the exporter (`ADGUARD_USER` / `ADGUARD_PASS`) must never be committed to the public repository.
- Consider Cloudflare Access in front of the hostname for SSO/MFA.

---

## Persistence / Backups
Persistence lives under `${RUNTIME_ROOT}/stacks/adguard-home/...`.
Backups: see `ops/backups/README.md`.

---

## Troubleshooting

| Symptom                          | Likely cause / fix                                                                      |
| -------------------------------- | --------------------------------------------------------------------------------------- |
| `404` via tunnel                 | Missing/wrong ingress rule or rule below catch-all; restart `cloudflared`.              |
| Tunnel OK but UI no carga        | Access policy blocks (test with “Show block page” and your email in **Allow**). |
| `connection refused` from tunnel | `adguard-home` not reachable on `proxy` network; check `expose: "3000"` and nets.       |
| Port `53` busy on host           | Another DNS service bound to 53; free it or lower rootless port threshold.              |
| Permission warning on `work`     | Check runtime directory permissions.                                                    |
| No AdGuard metrics in Prometheus | Check `adguard-exporter` logs and API credentials in runtime `.env`.                    |
| `blackbox-dns` target stays UP   | Blackbox alive; inspect `probe_success{job="blackbox-dns"}` for DNS failures.           |

---

## Escape hatch (debug)
> Use only if you need to inspect the raw compose setup.

```bash
cd "${STACKS_DIR}"
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "stacks/adguard-home/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yaml" \
  ps
```
