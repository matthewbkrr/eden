# Deploying eden (Debian 12, single host)

eden ships as an OTP release in Docker. This kit runs it behind Caddy
(reverse proxy + automatic TLS) with Postgres, on one box. You bring it up first
on the **bare IP over HTTP**, then flip to **`chat.ihi.ru` over HTTPS** by
changing a few env values — same image, no rebuild.

```
browser ──▶ Caddy (:80 / :443, TLS) ──▶ app (:4000) ──▶ Postgres
                                          └─ media on the `uploads` volume
```

## 0. Prerequisites
- A server (Debian 12, x86_64) with root/sudo. Here: `95.169.166.216`.
- This repo on GitHub with Actions enabled (the deploy workflow builds + ships).

## 1. Install Docker on the server
```sh
ssh root@95.169.166.216
apt-get update && apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker   # start on boot
docker compose version          # sanity
```
(Optional) a non-root deploy user that the CD workflow SSHes in as:
```sh
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
mkdir -p /home/deploy/.ssh && cp ~/.ssh/authorized_keys /home/deploy/.ssh/ 2>/dev/null || true
# add the CD public key to /home/deploy/.ssh/authorized_keys
```

## 2. Lay down the deploy dir
```sh
mkdir -p /opt/eden && cd /opt/eden
# copy deploy/docker-compose.yml, deploy/Caddyfile, deploy/.env.example,
# deploy/backup.sh here (scp from your machine, or curl from the repo).
cp .env.example .env
```

## 3. Fill in `.env` (IP phase)
```sh
# generate a secret on your machine: mix phx.gen.secret   (or: openssl rand -base64 48)
nano /opt/eden/.env
```
Set: `SECRET_KEY_BASE`, a strong `POSTGRES_PASSWORD` (mirror it into `DATABASE_URL`),
and keep the IP-phase address block:
```
PHX_HOST=95.169.166.216
PHX_SCHEME=http
PHX_PORT=80
SITE_ADDRESS=:80
```
Lock down the secrets file:
```sh
chmod 600 /opt/eden/.env
```

## 4. GitHub secrets (Settings → Secrets and variables → Actions)
- `DEPLOY_HOST` = `95.169.166.216`
- `DEPLOY_USER` = `deploy` (or `root`)
- `DEPLOY_SSH_KEY` = the **private** key whose public half is on the server
- `GHCR_PULL_TOKEN` = a PAT with **read:packages** (lets the server pull the image)

## 5. First deploy
> Steps 1–4 (Docker, `/opt/eden` with the compose/Caddyfile/`.env`) must be done
> **before** this — the workflow's SSH step does `cd /opt/eden` and expects `.env`.

Actions → **Deploy** → *Run workflow* (ref `main`). It builds the image, pushes to
GHCR, then on the server: pulls, runs `bin/migrate`, and `docker compose up -d`.
Caddy starts on `:80`. Only **backward-compatible (expand/contract)** migrations
are safe via this path — the old container serves until `up -d` recreates it.

> **Rollback caveat (#268).** The flow is forward-only. A few early migrations are
> **not data-reversible** — notably `room_access_general_only` (its `up/0` deletes
> membership rows; `down/0` only drops the `is_general` column, it can't restore them).
> `Release.rollback/2` past such a point would leave data missing. Roll forward with a
> new migration instead of rolling back below these versions.

Verify:
```sh
curl -s http://95.169.166.216/healthz   # → ok
```
Open `http://95.169.166.216` in a browser and log in. (No HTTPS yet — fine for the
shared smoke test; don't onboard real testers until step 6.)

Invite the first users: create invite links from within the app (or via
`iex`/release as the project documents).

## 6. Flip to the domain (`chat.ihi.ru`)
1. DNS: add an **A record** `chat.ihi.ru → 95.169.166.216` (AAAA → IPv6 if you
   want). Wait for it to resolve (`dig +short chat.ihi.ru`).
2. Edit `/opt/eden/.env`:
   ```
   PHX_HOST=chat.ihi.ru
   PHX_SCHEME=https
   PHX_PORT=443
   SITE_ADDRESS=chat.ihi.ru
   ```
3. `cd /opt/eden && docker compose up -d` — Caddy fetches a Let's Encrypt cert
   automatically (no email needed; it auto-renews). Verify
   `https://chat.ihi.ru/healthz`. To also get expiry-notice emails, add a global
   `{ email you@domain }` block to `Caddyfile` (see the note there) and `up -d`.

Later, to ship a fix: merge the PR to `main`, then run the **Deploy** workflow.

## 6a. Put Cloudflare in front (lower latency for far users)

The box has a fat pipe and a tuned stack (BBR + `fq` + 33 MB buffers), so for a
distant audience the bottleneck is pure round-trip distance (~160 ms). Cloudflare
terminates TLS at an edge ~20 ms from the user and serves static/media from cache,
which cuts cold page loads (~480 → ~60 ms), static, media downloads and uploads.
(Live per-click actions still need the origin, so they stay ~1 RTT.)

**Real client IP is already handled** by `Caddyfile`: it lists Cloudflare's ranges
under `servers > trusted_proxies` and forwards `{client_ip}`, so `conn.remote_ip`
(and the #236 per-IP throttle) stays the true visitor rather than a Cloudflare edge.
Keep the range list in sync with <https://www.cloudflare.com/ips/>.

Cutover (do the TLS switch **with** the DNS flip, or the origin's Let's Encrypt cert
will fail to renew once ACME challenges land on Cloudflare):

1. **Add the zone** `ihi.ru` to Cloudflare (Free plan) and point the registrar's
   nameservers at Cloudflare.
2. **Origin cert** (no more ACME on the box): Cloudflare dashboard → SSL/TLS →
   *Origin Server* → *Create Certificate* (15-year). Save the cert + key on the
   server:
   ```sh
   install -m 644 origin.pem     /opt/eden/origin.pem
   install -m 600 origin-key.pem /opt/eden/origin-key.pem
   ```
   Mount them into Caddy (add under the `caddy` service `volumes:` in
   `docker-compose.yml`):
   ```yaml
   - ./origin.pem:/etc/caddy/origin.pem:ro
   - ./origin-key.pem:/etc/caddy/origin-key.pem:ro
   ```
   and switch the site's TLS in `Caddyfile` (inside the `{$SITE_ADDRESS::80}` block):
   ```
   tls /etc/caddy/origin.pem /etc/caddy/origin-key.pem
   ```
3. **DNS**: in Cloudflare, `chat` A → `95.169.166.216`, **Proxied** (orange cloud).
4. **SSL/TLS mode**: *Full (strict)* (validates the origin cert end-to-end).
5. `cd /opt/eden && docker compose up -d` (or `docker compose restart caddy`).
6. **Verify** — the client IP still resolves correctly (not a Cloudflare IP), so the
   throttle isn't keyed on the edge:
   ```sh
   docker compose logs --since 5m app | grep -i "log_in"   # after a test login
   curl -sI https://chat.ihi.ru/healthz | grep -i "cf-ray"  # served via Cloudflare
   ```
   Then re-run the speed check from a far client (`curl -w` from README's perf notes).

**Harden (recommended):** firewall the origin so only Cloudflare can reach `:80/:443`
(hides the origin IP and blocks anyone from bypassing CF to spoof the client IP).

## 7. Backups
```sh
chmod +x /opt/eden/backup.sh
# daily at 03:30:
( crontab -l 2>/dev/null; echo "30 3 * * * /opt/eden/backup.sh >> /opt/eden/backup.log 2>&1" ) | crontab -
```
Backups land in `/opt/eden/backups/` (last 14 kept). **Ship them off-box**
(R2/scp) — a backup on the same disk dies with the disk.

## 8. Disk watch
Media lives on the `uploads` volume (local). 50 GB lasts months, driven by
photo/video volume — not text. Watch it and move media to R2 (set `EDEN_S3_*` in
`.env`, `up -d`) before it fills:
```sh
df -h /var/lib/docker        # overall
# simple 80% alert via cron:
( crontab -l 2>/dev/null; echo "0 * * * * [ \$(df --output=pcent /var/lib/docker | tail -1 | tr -dc 0-9) -ge 80 ] && echo 'eden disk >=80%' | logger -t eden-disk" ) | crontab -
```

## Operations cheatsheet
```sh
cd /opt/eden
docker compose ps                      # status
docker compose logs -f app             # app logs
docker compose logs -f caddy           # TLS / proxy logs
docker compose run --rm app /app/bin/migrate   # run migrations manually
docker compose exec app /app/bin/eden remote   # IEx into the running release
docker compose up -d                   # apply .env changes / restart
```
Rollback: set `APP_IMAGE` in `.env` to a previous `ghcr.io/...:<sha>` and
`docker compose up -d` (the deploy prunes dangling images, so a rollback may
re-pull the older tag from GHCR — fine while it's retained there).
