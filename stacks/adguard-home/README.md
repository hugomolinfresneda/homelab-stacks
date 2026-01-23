# AdGuard Home — DNS filtering for your LAN (rootless, no DHCP)

This stack provides network-level ad/tracker blocking via **AdGuard Home**.
It follows the **two-repository model** used across the homelab: a public base and a private runtime.

---

## Architecture

| Repository          | Purpose                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation). No host ports or secrets.   |
| **homelab-runtime** | Private overrides (`compose.override.yml`, `.env`, real `conf/AdGuardHome.yaml`, `work/`, backups). |

---

Use the canonical variables for absolute paths:
```sh
export STACKS_DIR="/abs/path/to/homelab-stacks"    # e.g. /opt/homelab-stacks
export RUNTIME_ROOT="/abs/path/to/homelab-runtime" # e.g. /opt/homelab-runtime
RUNTIME_DIR="${RUNTIME_ROOT}/stacks/adguard-home"
```

## File layout

```text
${STACKS_DIR}/stacks/adguard-home/
├── compose.yaml
├── .env.example
└── README.md

${RUNTIME_DIR}/
├── compose.override.yml
├── .env
├── conf/AdGuardHome.yaml
└── work/
````

---

## Requirements

* Docker + Compose plugin (Debian host; **rootless** supported).

* Shared Docker network:

  ```bash
  docker network create proxy || true
  docker network create mon-net || true    # shared monitoring network
  ```

* For **rootless Docker** binding directly to port 53, lower the unprivileged port range:

  ```bash
  echo 'net.ipv4.ip_unprivileged_port_start=53' | sudo tee /etc/sysctl.d/99-rootless-lower-ports.conf
  echo 'net.ipv6.ip_unprivileged_port_start=53' | sudo tee -a /etc/sysctl.d/99-rootless-lower-ports.conf
  sudo sysctl --system
  ```

* If `systemd-resolved` is holding `127.0.0.53:53`, disable its stub listener:

  ```bash
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf "[Resolve]\nDNSStubListener=no\n" | sudo tee /etc/systemd/resolved.conf.d/10-adguard.conf
  sudo systemctl restart systemd-resolved || true
  ```

  *(If the unit doesn’t exist, you can ignore this step.)*

---

## Environment configuration

Copy the example env file into the runtime:

```bash
cp ${STACKS_DIR}/stacks/adguard-home/.env.example \
   ${RUNTIME_DIR}/.env
```

Typical contents:

```dotenv
# Core service
TZ=Europe/Madrid
WEB_PORT=3000
DNS_PORT=53
# BIND_LOCALHOST=127.0.0.1   # set to keep UI bound to loopback on the host

# AdGuard API / Prometheus exporter
ADGUARD_PROTOCOL=http
ADGUARD_HOSTNAME=adguard-home
ADGUARD_PORT=3000
ADGUARD_USER=<your_adguard_admin_user>
ADGUARD_PASS=<your_password>
ADGUARD_EXPORTER_PORT=9617
ADGUARD_SCRAPE_INTERVAL=15s
```

`WEB_PORT`, `DNS_PORT` and `BIND_LOCALHOST` are consumed by the private `compose.override.yml` in **homelab-runtime** to bind host ports. The public compose file never binds host ports directly.

---

## Deployment workflow (Makefile shortcuts)

From the **runtime** repo:

```bash
make up stack=adguard-home
make ps stack=adguard-home
make logs stack=adguard-home [follow=true]
```

Expected ports:

* **DNS**: `:53/tcp` + `:53/udp` on the host (LAN/VPN only).
* **UI**: as per `BIND_LOCALHOST` (recommended `127.0.0.1:3000`) — Cloudflared will access `adguard-home:3000` on the Docker network.

---

## Manual deploy (portable)

```bash
docker compose \
  --env-file "${RUNTIME_DIR}/.env" \
  -f "${STACKS_DIR}/stacks/adguard-home/compose.yaml" \
  -f "${RUNTIME_DIR}/compose.override.yml" \
  up -d
```

Nota: si en tu runtime el override es `compose.override.yaml`, usa ese fichero.

---

## Publishing (UI via Cloudflare Tunnel)

Keep **DNS strictly in LAN/VPN**. Publish **UI only** through the tunnel:

**cloudflared `config.yml`:**

```yaml
ingress:
  - hostname: adguard.<your-domain>
    service: http://adguard-home:3000
  - service: http_status:404
```

Create a **CNAME** `adguard` → `<TUNNEL_UUID>.cfargotunnel.com` (proxied).
Protect the app with **Cloudflare Access** (Self-hosted app; policy “Allow” your email; optionally MFA/Geo/mTLS).

---

## Observability

### Prometheus / Grafana

AdGuard is instrumented for metrics and DNS probing:

* **Exporter**: `ebrianne/adguard-exporter` runs as `adguard-exporter` in the same stack.

* **Prometheus jobs** (configured in the `monitoring` stack):

  * `job="adguard-exporter"` scrapes the HTTP metrics endpoint exposed by the exporter.
  * `job="blackbox-dns"` uses Blackbox Exporter to probe DNS resolution via `adguard-home:53`.

* **Alert rules** are defined in the Prometheus rules directory (public repo):

  * `AdGuardExporterDown` — exporter unreachable for several minutes.
  * `AdGuardProtectionDisabled` — AdGuard DNS protection flag turned off for a sustained period.
  * `AdGuardHighLatency` — average DNS processing time above threshold.

  These rules are label-aligned with the rest of the homelab (`stack=dns`, `service=adguard-home`, `env=home`) and expect no secrets in the public repo; credentials are injected via the runtime `.env`.

* A dedicated Grafana dashboard (e.g. `DNS / AdGuard`) can visualise:

  * Queries per second and blocked ratio.
  * Average processing time.
  * Top clients and top blocked domains.
  * Probe status from `blackbox-dns` (`probe_success`).

Dashboard provisioning and JSON definitions are managed under the `monitoring` stack.

**Grafana dashboard:** `AdGuard – Service Overview` (folder `20_apps`)

- **Health (last 5m):** `adguard_running` (UP/DOWN), `adguard_protection_enabled` (Enabled/Disabled), and DNS processing time (ms).
- **Traffic & blocking:** DNS queries (all types), blocked queries, and blocked ratio (%).
- **Query mix:** record type breakdown (A/AAAA/CNAME/HTTPS/…).
- **Top domains (instant snapshot):** most queried and most blocked domains (tables; long domains are truncated to keep the layout readable).

Panel descriptions follow the CFIS convention: **Context / Focus / Implementation / Security**.

Security: domain lists can reveal device/user behaviour and internal services; redact before sharing.


### Uptime Kuma

* **DNS monitor** → Server `<HOST_LAN_IP>`, Port `53`, Record `A` (and optionally `AAAA`).
* **HTTP monitor (internal)** → `http://adguard-home:3000` (same Docker network; bypasses Access).
  *If you prefer external monitoring through Access, use a Service Token and add the CF Access headers in the monitor.*

Quick checks:

```bash
# DNS resolves via AdGuard
dig @<HOST_LAN_IP> example.com A +short

# UI reachable inside Docker network
docker run --rm --network proxy curlimages/curl:8.10.1 -sSI http://adguard-home:3000 | head -n1

# Exporter metrics reachable from Prometheus network
docker compose -f "${STACKS_DIR}/stacks/monitoring/compose.yaml" \
  exec -T prometheus wget -qO- http://adguard-exporter:9617/metrics | head
```

---

## Security notes

* **Do not** expose port 53 over the tunnel; keep DNS to LAN/VPN.
* Prefer **UI via Cloudflared + Access**; optionally keep the host bind on `127.0.0.1` or remove it entirely.
* Strong admin password; keep `conf/AdGuardHome.yaml` under backup.
* Run as rootless Docker; volumes are bind-mounted under the runtime path.
* API credentials for the exporter (`ADGUARD_USER` / `ADGUARD_PASS`) must never be committed to the public repository.

---

## Maintenance

```bash
# Update image and redeploy
docker compose -f "${STACKS_DIR}/stacks/adguard-home/compose.yaml" \
               -f "${RUNTIME_DIR}/compose.override.yml" \
               pull && \
docker compose -f "${STACKS_DIR}/stacks/adguard-home/compose.yaml" \
               -f "${RUNTIME_DIR}/compose.override.yml" \
               up -d
```

**Pin image by digest (recommended):**

```bash
digest=$(docker pull adguard/adguardhome:latest >/dev/null 2>&1 \
  && docker inspect adguard/adguardhome:latest -f '{{index .RepoDigests 0}}' | awk -F@ '{print $2}')
tmp=$(mktemp)
awk -v d="$digest" '
  $0 ~ /^[[:space:]]*image:[[:space:]]*adguard\/adguardhome/ {
    sub(/image:[[:space:]]*adguard\/adguardhome[^ ]*/, "image: adguard/adguardhome@" d)
  } { print }
' "${STACKS_DIR}/stacks/adguard-home/compose.yaml" > "$tmp" \
  && mv "$tmp" "${STACKS_DIR}/stacks/adguard-home/compose.yaml"
( cd "${STACKS_DIR}" && make validate )
```

---

## Troubleshooting

| Symptom                          | Likely cause / fix                                                                |
| -------------------------------- | --------------------------------------------------------------------------------- |
| `404` via tunnel                 | Missing/wrong ingress rule or rule below catch-all; restart `cloudflared`.        |
| Tunnel OK but UI no carga        | Access policy blocks (test with “Show block page” and your email in **Allow**).   |
| `connection refused` from tunnel | `adguard-home` not reachable on `proxy` network; check `expose: "3000"` and nets. |
| Port `53` busy on host           | Another DNS service bound to 53; free it or lower rootless port threshold.        |
| Permission warning on `work`     | Set `chmod 700 ${RUNTIME_DIR}/work`.                                               |
| No AdGuard metrics in Prometheus | Check `adguard-exporter` logs and API credentials in runtime `.env`.              |
| `blackbox-dns` target stays UP   | Blackbox alive; inspect `probe_success{job="blackbox-dns"}` for DNS failures.     |

---

## Backups

Include these runtime paths in your backup plan (e.g., restic):

```text
${RUNTIME_DIR}/conf/AdGuardHome.yaml
${RUNTIME_DIR}/work/
```

---

## Notes

* The public compose keeps the service portable and environment-agnostic (no host ports/paths or secrets).
* DNS remains a **local** service; the **UI** is the only piece published via the tunnel.
* Monitoring integration is split: this stack exposes metrics and API parameters, while the `monitoring` stack owns Prometheus jobs, rules and dashboards.
