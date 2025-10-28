# Cloudflare Tunnel — Outbound reverse proxy (CGNAT-friendly)

This stack establishes a persistent Cloudflare Tunnel to expose your internal Docker services (e.g. Dozzle, Uptime Kuma, Nextcloud) securely **without opening ports** on your router.

It runs a minimal container (`cloudflare/cloudflared`) that maintains outbound connections to Cloudflare’s edge.

---

## Architecture

| Repository          | Purpose                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| **homelab-stacks**  | Public base definition (`compose.yaml`, `.env.example`, documentation).                  |
| **homelab-runtime** | Private overrides (`compose.override.yml`, `.env`, real `config.yml`, credentials JSON). |

---

## File layout

```
/opt/homelab-stacks/stacks/cloudflared/
├── compose.yaml
└── README.md

/opt/homelab-runtime/stacks/cloudflared/
├── compose.override.yml
├── .env
└── cloudflared/config.yml
/srv/secrets/cloudflared/<UUID>.json
```

---

## Requirements

* A **Cloudflare account** with a domain already added to Cloudflare.
* One created **Tunnel ID (UUID)** and its **JSON credential** file.
* Shared Docker network:

  ```bash
  docker network create proxy || true
  ```
* Debian host (rootless Docker supported).

---

## Runtime configuration

Example `/opt/homelab-runtime/stacks/cloudflared/cloudflared/config.yml`:

```yaml
tunnel: 41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46
credentials-file: /etc/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json

ingress:
  - hostname: dozzle.atardecer-naranja.es
    service: http://dozzle:8080
  - hostname: uptime-kuma.atardecer-naranja.es
    service: http://uptime-kuma:3001
  - hostname: cloud.atardecer-naranja.es
    service: http://nc-web:8080
  - service: http_status:404
```

The JSON credential lives outside the repo:

```
/srv/secrets/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json
```

Set permissions once:

```bash
sudo mkdir -p /srv/secrets/cloudflared
sudo mv ~/.cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json /srv/secrets/cloudflared/
sudo chmod 700 /srv/secrets/cloudflared
sudo chmod 644 /srv/secrets/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json
sudo chown 65532:65532 /srv/secrets/cloudflared/41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.json
```

---

## Deployment (Makefile shortcuts)

From the runtime repository:

```bash
make up stack=cloudflared     # deploy tunnel
make ps stack=cloudflared     # show status
make logs stack=cloudflared   # view tunnel logs
```

Expected log output:

```
Connected to Cloudflare edge
Registered tunnel connection
```

---

## Manual deploy (portable method)

```bash
docker compose \
  --env-file /opt/homelab-runtime/stacks/cloudflared/.env \
  -f /opt/homelab-stacks/stacks/cloudflared/compose.yaml \
  -f /opt/homelab-runtime/stacks/cloudflared/compose.override.yml \
  up -d
```

---

## Creating the CNAMEs (via Cloudflare dashboard)

Each `hostname:` in your `config.yml` must have a **DNS CNAME** record in Cloudflare pointing to the tunnel.

1. Open [dash.cloudflare.com](https://dash.cloudflare.com) → your domain → **DNS → Records**
2. Create one CNAME per service:

| Type  | Name          | Target                                                  | Proxy Status |
| ----- | ------------- | ------------------------------------------------------- | ------------ |
| CNAME | `dozzle`      | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |
| CNAME | `uptime-kuma` | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |
| CNAME | `cloud`       | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |
| CNAME | `couchdb`     | `41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com` | ☁️ Proxied   |

3. Save changes.
   No TTL or proxy tweaks needed — Cloudflare handles routing automatically.

To verify:

```bash
dig +short dozzle.atardecer-naranja.es
```

Should return:

```
41f9cc7c-019d-4c8e-a0ae-efa8fbc92e46.cfargotunnel.com.
```

---

## Add new services

1. Add the rule in your `config.yml`:

   ```yaml
   - hostname: newapp.atardecer-naranja.es
     service: http://newapp:port
   ```
2. Create the CNAME in Cloudflare’s **DNS → Records**,
   pointing to your `<UUID>.cfargotunnel.com`.
3. Restart the tunnel:

   ```bash
   make restart stack=cloudflared
   ```

---

## Troubleshooting

| Symptom                           | Likely cause                                                  |
| --------------------------------- | ------------------------------------------------------------- |
| Crash-loop or `permission denied` | Wrong path or perms on `/srv/secrets/cloudflared/<UUID>.json` |
| 404 from Cloudflare               | Missing or wrong `ingress` rule                               |
| Connection refused                | Target container not in `proxy` network                       |
| Host not resolving                | Missing CNAME record in Cloudflare                            |

---

## Security notes

* Never version the JSON credential file.
* Do **not** expose ports 80/443.
* Keep the `proxy` network shared among your web services.
* Cloudflare handles TLS and authentication at the edge.

---

## Maintenance

```bash
# Update image and redeploy
make pull stack=cloudflared
make up stack=cloudflared

# View logs
make logs stack=cloudflared
```
