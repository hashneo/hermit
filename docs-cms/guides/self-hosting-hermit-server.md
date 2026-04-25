---
title: Self-Hosting the Hermit Server
type: guide
status: Active
related_rfcs: [rfc-013]
related_adrs: [adr-009]
---

# Self-Hosting the Hermit Server

This guide covers deploying the Hermit Go server so that macOS and iPad clients
can reach it over the internet (Mode 3 — Remote URL).

## When to self-host

| Scenario | Recommended mode |
|---|---|
| Single Mac, no iPad | Mode 1 (embedded, no server needed) |
| Mac + iPad on same Wi-Fi | Mode 2 (Bonjour auto-discovery) |
| Remote access / multiple networks | Mode 3 (self-hosted, this guide) |

---

## Minimum server requirements

- **CPU**: 1 vCPU (the server is mostly I/O-bound against the GitHub API)
- **RAM**: 128 MB
- **Disk**: 1 GB for the thread-store SQLite/JSON data dir
- **OS**: Linux (amd64 or arm64), macOS, or any platform supported by Go 1.22+
- **Inbound port**: 443 (HTTPS via reverse proxy) or 8080 (plain HTTP, not recommended for remote)

---

## Building the server binary

```bash
git clone https://github.com/hashicorp/hermit.git
cd hermit
go build -o hermit-server ./cmd/server
```

Or use the pre-built Docker image (see below).

---

## Configuration

The server reads configuration from environment variables or a YAML file
passed via `--config`.

| Variable | YAML key | Description |
|---|---|---|
| `HERMIT_BASE_URL` | `baseURL` | GitHub API base (default `https://api.github.com`) |
| `HERMIT_OWNER` | `owner` | GitHub org or user |
| `HERMIT_REPO` | `repo` | Repository name |
| `HERMIT_DOCS_PATH` | `docsPath` | Path to RFC docs in repo (e.g. `docs-cms/rfcs`) |
| `HERMIT_RFC_LABEL` | `rfcLabel` | PR label used to identify RFC pull requests |
| `HERMIT_DATA_DIR` | `dataDir` | Directory for thread-store persistence (default `data`) |
| `HERMIT_PORT` | `port` | TCP port to listen on (default `8080`) |

**GitHub PAT**: each device sends its own PAT in the `Authorization: Bearer <pat>`
request header. The server forwards it to the GitHub API on every request, so
no PAT needs to be stored server-side. The PAT must have `repo` scope.

---

## Deployment options

### Bare VM (systemd)

```ini
# /etc/systemd/system/hermit.service
[Unit]
Description=Hermit Server
After=network.target

[Service]
User=hermit
WorkingDirectory=/opt/hermit
EnvironmentFile=/etc/hermit/env
ExecStart=/opt/hermit/hermit-server --port 8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now hermit
```

### Docker

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
RUN go build -o /hermit-server ./cmd/server

FROM alpine:3.19
COPY --from=build /hermit-server /hermit-server
VOLUME /data
ENV HERMIT_DATA_DIR=/data
EXPOSE 8080
ENTRYPOINT ["/hermit-server"]
```

```bash
docker run -d \
  -e HERMIT_OWNER=myorg \
  -e HERMIT_REPO=myrepo \
  -e HERMIT_DOCS_PATH=docs-cms/rfcs \
  -e HERMIT_RFC_LABEL=rfc \
  -v hermit-data:/data \
  -p 8080:8080 \
  ghcr.io/hashicorp/hermit-server:latest
```

### fly.io

```toml
# fly.toml
app = "hermit-myorg"
primary_region = "iad"

[build]
  dockerfile = "Dockerfile"

[env]
  HERMIT_OWNER     = "myorg"
  HERMIT_REPO      = "myrepo"
  HERMIT_DOCS_PATH = "docs-cms/rfcs"
  HERMIT_RFC_LABEL = "rfc"
  HERMIT_DATA_DIR  = "/data"

[[mounts]]
  source      = "hermit_data"
  destination = "/data"

[[services]]
  internal_port = 8080
  protocol      = "tcp"
  [[services.ports]]
    port     = 443
    handlers = ["tls", "http"]
```

```bash
fly launch --name hermit-myorg
fly secrets set HERMIT_PAT=ghp_... # optional server-side default; per-device PAT takes precedence
fly deploy
```

---

## TLS termination

Run the Hermit server on `localhost:8080` behind a reverse proxy that handles TLS.

### nginx + Certbot

```nginx
server {
    listen 443 ssl;
    server_name hermit.example.com;

    ssl_certificate     /etc/letsencrypt/live/hermit.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/hermit.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Authorization $http_authorization;
    }
}
```

```bash
certbot --nginx -d hermit.example.com
```

### Caddy (automatic HTTPS)

```
hermit.example.com {
    reverse_proxy localhost:8080
}
```

---

## Connecting the Hermit app

1. Open **Settings → Server** in the Hermit app.
2. Select **Remote**.
3. Enter your server URL (e.g. `https://hermit.example.com`).
4. Tap/click **Validate Connection** — the app performs a health-check `GET /health`.
5. Enter your GitHub PAT in **Settings → GitHub** if not already set.

The PAT is sent as `Authorization: Bearer <pat>` on every API request and is
never stored on the server.

---

## Known limitations

- **Local network / Bonjour (Mode 2)** requires that the Mac and iPad be on the
  same subnet with multicast traffic allowed. VPNs that block multicast
  (common in corporate environments) prevent Bonjour discovery; use Mode 3
  (remote URL) in those environments.
- **Per-device PAT**: each device needs its own GitHub PAT with `repo` scope.
  A shared service account PAT can be used if individual PATs are undesirable,
  but this reduces auditability.
- **No built-in authentication layer**: the server trusts any client that
  presents a valid GitHub PAT. If the server is publicly reachable, anyone
  with a valid PAT for the configured repository can use it. Restrict access
  via firewall rules or a VPN if you need to limit who can reach the server.

---

## Future work

- SSO / OAuth flow as an alternative to per-device PAT entry (tracked in RFC-013
  Adoption Strategy — not yet scheduled).
- Webhook push support to eliminate polling (tracked separately).

---

*Ref: RFC-013 §Mode 3, ADR-009*
