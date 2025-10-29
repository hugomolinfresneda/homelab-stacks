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

## File layout

```
/opt/homelab-stacks/stacks/adguard-home/
├── compose.yaml
├── .env.example
└── README.md

/opt/homelab-runtime/stacks/adguard-home/
├── compose.override.yml
├── .env
├── conf/AdGuardHome.yaml
└── work/
```

---

## Requirements

* Docker + Compose plugin (Debian host; **rootless** supported).
* Shared Docker network:

  ```bash
  docker network create proxy || true
  ```
* Bind to privileged DNS port in rootless (recommended):

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
cp /opt/homelab-stacks/stacks/adguard-home/.env.example \
   /opt/homelab-runtime/stacks/adguard-home/.env
```

Typical contents:

```dotenv
TZ=Europe/Madrid
WEB_PORT=3000
DNS_PORT=53
# BIND_LOCALHOST=127.0.0.1   # set to keep UI bound to loopback on the host
```

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
  --env-file /opt/homelab-runtime/stacks/adguard-home/.env \
  -f /opt/homelab-stacks/stacks/adguard-home/compose.yaml \
  -f /opt/homelab-runtime/stacks/adguard-home/compose.override.yml \
  up -d
```

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

* **Uptime Kuma**:

  * **DNS monitor** → Server `<HOST_LAN_IP>`, Port `53`, Record `A` (and optionally `AAAA`).
  * **HTTP monitor (internal)** → `http://adguard-home:3000` (same Docker network; bypasses Access).
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

* **Do not** expose port 53 over the tunnel; keep DNS to LAN/VPN.
* Prefer **UI via Cloudflared + Access**; optionally keep the host bind on `127.0.0.1` or remove it entirely.
* Strong admin password; keep `conf/AdGuardHome.yaml` under backup.
* Run as rootless Docker; volumes are bind-mounted under the runtime path.

---

## Maintenance

```bash
# Update image and redeploy
docker compose -f /opt/homelab-stacks/stacks/adguard-home/compose.yaml \
               -f /opt/homelab-runtime/stacks/adguard-home/compose.override.yml \
               pull && \
docker compose -f /opt/homelab-stacks/stacks/adguard-home/compose.yaml \
               -f /opt/homelab-runtime/stacks/adguard-home/compose.override.yml \
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
' /opt/homelab-stacks/stacks/adguard-home/compose.yaml > "$tmp" \
  && mv "$tmp" /opt/homelab-stacks/stacks/adguard-home/compose.yaml
( cd /opt/homelab-stacks && make validate )
```

---

## Troubleshooting

| Symptom                          | Likely cause / fix                                                                |
| -------------------------------- | --------------------------------------------------------------------------------- |
| `404` via tunnel                 | Missing/wrong ingress rule or rule below catch-all; restart `cloudflared`.        |
| Tunnel OK but UI no carga        | Access policy blocks (test with “Show block page” and your email in **Allow**).   |
| `connection refused` from tunnel | `adguard-home` not reachable on `proxy` network; check `expose: "3000"` and nets. |
| Port `53` busy on host           | Another DNS service bound to 53; free it or lower rootless port threshold.        |
| Permission warning on `work`     | Set `chmod 700 /opt/homelab-runtime/stacks/adguard-home/work`.                    |

---

## Backups

Include these runtime paths in your backup plan (e.g., restic):

```
/opt/homelab-runtime/stacks/adguard-home/conf/AdGuardHome.yaml
/opt/homelab-runtime/stacks/adguard-home/work/
```

---

## Notes

* The public compose keeps the service portable and environment-agnostic (no host ports/paths).
* DNS remains a **local** service; the **UI** is the only piece published via the tunnel.
