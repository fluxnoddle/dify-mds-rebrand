---
name: "Vultr Single VM Deploy (Dify)"
description: "Deploy the MDS-rebranded Dify stack to the shared Vultr VM (207.148.120.195, host alias `vultr-dp`) at `https://agent.metasolutions.ai`. Use when the user mentions deploying Dify to the test VM, vultr-dp host, pushing the rebrand branch to Vultr, refreshing the Dify deployment, restarting Dify services on the VM, viewing Dify logs from the VM, renewing the TLS cert for agent.metasolutions.ai, or running docker compose for Dify on Vultr. **This VM also runs `data-platform-core`** under `/opt/data-platform-core` (its own skill in that repo); both stacks share the same Docker daemon, RAM, disk, and network — treat any host-wide action (prune, reboot, package upgrade) as affecting both."
---

# Vultr Single VM Deploy (Dify MDS rebrand)

Single-VM coexistence deploy of the full Dify docker-compose stack on the same Vultr VM that hosts `data-platform-core`. Public URL: `https://agent.metasolutions.ai`. The skill runs `git`/`docker compose` over SSH — no Kubernetes, no Terraform, no image registry.

## 📍 Current deployment snapshot (as of 2026-05-22)

The first production deployment used **option B** (fresh dedicated VM, not shared with dp). Keep this table updated when re-provisioning.

| Field | Value |
|---|---|
| Vultr instance ID | `6787a136-7a70-440e-b935-b9b94d5bf65c` |
| Plan / region | `vc2-4c-8gb` ($40/mo) · `sgp` (Singapore) · Ubuntu 24.04 LTS x64 |
| Public IP | `139.180.152.22` (DNS-pinned, see below) |
| SSH alias | `vultr-agent` (in `~/.ssh/config`, identity `~/.ssh/vultr_vm_data_platform`) |
| Vultr SSH key | id `f8f76a2b-c84b-405a-9a6e-86fac8bb11e1` name `MDS Dify Local` (fingerprint `SHA256:KL3gapnzMibk2yTO1Rx+ChQ1zvDtszLxUCum4vlVyFI`) |
| Public URL | `https://agent.metasolutions.ai` |
| TLS cert | Let's Encrypt E7, valid 2026-05-22 → 2026-08-20 (90 d) |
| DNS provider | Vercel (NS `ns1.vercel-dns.com` / `ns2.vercel-dns.com`) — domain registered third-party, NS pointed at Vercel |
| Stack | Dify 1.13.3 base + local `metasolutions/mds-web:latest` (Next.js with MDS rebrand) |
| Compose project | `dify` (container prefix `dify-*`, isolates from dp's `data-platform-core-*` even though they're on different VMs) |
| Owner accounts | `quoc.khanh.ut.0212@gmail.com` (migrated from local), `admin.department@metasolutions.software` (company admin) |
| Migrated data | 1 tenant `akatekhanh's Workspace`, 5 apps, plugin_daemon + app/storage volumes |
| **Does this VM also host data-platform-core?** | **No.** Fresh VM dedicated to Dify. The dp-guardrail in `remote-bootstrap.sh` no-ops on this host (no dp containers detected). |

## 🛑 Hard rule — DO NOT touch `data-platform-core`

`data-platform-core` is the existing tenant on this VM and is treated as **read-only** by this skill. Every action here must stay strictly inside Dify's footprint. **No exceptions, no "just this once".**

| Domain | Allowed (Dify only) | Forbidden (data-platform-core / host-wide) |
|---|---|---|
| Filesystem | read/write under `/opt/dify/` only | `cd`, `cp`, `mv`, `rm`, `chown` against `/opt/data-platform-core/` or `/opt/litellm/` |
| Containers | services prefixed `${COMPOSE_PROJECT}` (default `dify-*`) | `docker stop`/`rm`/`exec` on `data-platform-core-*` or `litellm-*` |
| Volumes | only `/opt/dify/docker/volumes/` | any path outside `/opt/dify/` |
| Compose | always `docker compose -p dify ...` from `/opt/dify/docker` | `docker compose` from `/opt/data-platform-core` |
| Host actions | the swapfile created by this script | `docker system prune`, `docker volume prune`, `docker network prune`, `apt upgrade docker*`, `systemctl restart docker`, `reboot`, removing the swapfile |
| Networking | dify's compose default bridge | editing the host iptables / nftables / ufw rules that govern dp's ports `3000/8001/9001/5433/5434` |

`remote-bootstrap.sh` enforces this with two guardrails:

1. **Pre-flight refusal**: the script aborts if `REMOTE_PATH` is empty, `/`, or any prefix of `/opt/data-platform-core`.
2. **Post-deploy assertion**: after Dify is up, the script counts dp containers (`data-platform-core-*` and `litellm-*`) and exits non-zero if **any** container that was `Up` before the deploy is no longer `Up`.

If a Dify task **appears to require** touching dp (it shouldn't), stop and surface it to the operator. Never decide unilaterally.

## Pinned facts

| Field | Value |
|---|---|
| Public IP | `207.148.120.195` |
| SSH alias | `vultr-dp` (in `~/.ssh/config`, set up by data-platform-core skill) |
| SSH user | `root` |
| SSH key | `~/.ssh/vultr_vm_data_platform` (ed25519, shared) |
| Dify repo path on VM | `/opt/dify` |
| Compose project name | `dify` (container prefix `dify-*`, isolates from `data-platform-core-*` / `litellm-*`) |
| Branch | `rebrand-mds-metasolutions` (override with `BRANCH=...`) |
| Repo URL | `https://github.com/fluxnoddle/dify-mds-rebrand.git` |
| Domain | `agent.metasolutions.ai` (A record → 207.148.120.195) |
| Public URL | `https://agent.metasolutions.ai` |
| Certbot email | `admin.department@metasolutions.software` (override with `CERTBOT_EMAIL=...`) |

> ⚠️ **Shared VM.** `data-platform-core` already runs on this host. Do **not** run `docker system prune -af --volumes` — it will nuke dp's images and (if `-v`) named volumes. Use targeted `docker rmi` / `docker compose down` instead. RAM and disk are shared.
>
> 🤖 **Claude Code Bash gotcha.** Always invoke ssh via `/usr/bin/ssh`, never bare `ssh`. The harness denies bare `ssh` regardless of `Bash(ssh *)` allow rules. Same applies to `scp` / `rsync`. Shell scripts under `scripts/` are unaffected — they invoke `ssh` through the OS shell. Humans in their own terminal can use bare `ssh`.

## RAM accounting (read before first deploy)

| Stack | Steady-state | Peak (boot) |
|---|---|---|
| `data-platform-core` | ~3.5 GB | ~5 GB (first Spark Maven download) |
| Dify (full) | ~3.0–4.0 GB | ~5 GB (api/worker/web boot) |
| **Combined** | **~7 GB** | **~10 GB** |

- `vc2-2c-4gb` (current, $20/mo) + 8 GB swap: works for ad-hoc testing but Dify boot is **slow** (~5–8 min) and any traffic burst will OOM-kill. Acceptable for demos, not for shared use.
- `vc2-4c-8gb` ($40/mo): comfortable for both stacks. Recommended before exposing the URL to anyone.
- `vc2-4c-16gb` ($80/mo): headroom for plugin_daemon + Weaviate growth.

Check live: `/usr/bin/ssh vultr-dp 'free -h && swapon --show'`. If `Swap` shows >4 GB used persistently, upgrade.

## DNS prerequisite (one-time)

Before the first deploy, point the domain at the VM:

```text
agent.metasolutions.ai.   A   207.148.120.195
```

Verify propagation: `dig +short agent.metasolutions.ai` (must return `207.148.120.195`). Wait 5–10 min if cached.

## Pre-flight (one-time per laptop)

Same SSH setup as the data-platform-core skill — skip if `/usr/bin/ssh vultr-dp uname -a` already works.

```bash
test -f ~/.ssh/vultr_vm_data_platform || \
  ssh-keygen -t ed25519 -f ~/.ssh/vultr_vm_data_platform -N ""

# Append ~/.ssh/config if `vultr-dp` alias not already there
grep -q '^Host vultr-dp' ~/.ssh/config || cat >> ~/.ssh/config <<'EOF'

Host vultr-dp
    HostName 207.148.120.195
    User root
    IdentityFile ~/.ssh/vultr_vm_data_platform
    StrictHostKeyChecking accept-new
EOF

ssh-copy-id -i ~/.ssh/vultr_vm_data_platform.pub root@207.148.120.195
/usr/bin/ssh vultr-dp "uname -a && free -h && df -h /"
```

## Quick start

### Zero-to-running on a NEW Vultr VM (option B — recommended for solo Dify)

One command provisions a fresh VM via Vultr API, runs cloud-init to bootstrap Docker + clone repo + build the MDS web image, then issues TLS and flips to HTTPS. End state: `https://agent.metasolutions.ai` live.

```bash
# Prereqs (one-time on laptop):
#   brew install vultr/vultr-cli/vultr-cli jq
#   export VULTR_API_KEY="<personal access token from my.vultr.com>"
#   Upload your SSH public key to Vultr console (any pre-existing key works)

# Run
./.claude/skills/vultr-single/scripts/provision-and-deploy.sh
```

Defaults: plan `vc2-4c-8gb` ($40/mo) · region `sgp` (Singapore) · OS `2284` (Ubuntu 24.04) · label/SSH alias `dify-test` / `vultr-dify` · domain `agent.metasolutions.ai`. Override with env vars (see top of script).

What it does end-to-end (~25–35 min, most of it is the Next.js build):

1. Looks up your SSH key id in Vultr account
2. `vultr-cli instance create` with the cloud-init YAML as `--userdata`
3. Polls until VM is `active` with a public IP
4. Appends an `~/.ssh/config` block for the `vultr-dify` alias
5. Waits for `sshd` to come up
6. Polls `/var/lib/cloud/dify-bootstrap-done` sentinel (cloud-init finishing on the VM)
7. Pauses for you to update the DNS A record (or `AUTO_DNS_WAIT=1` polls `dig` for you)
8. Issues Let's Encrypt cert via certbot inside the Dify compose
9. Flips `NGINX_HTTPS_ENABLED=true` and recreates nginx
10. Health-checks `https://$DOMAIN/console/api/version`

Stop early with `SKIP_CERT=1 ./scripts/provision-and-deploy.sh` if you want to inspect before TLS. Pick the VM up later with the printed cert / flip commands.

After this, **subsequent deploys** (when you push new commits) use the regular flow:

```bash
SSH_HOST=vultr-dify ./.claude/skills/vultr-single/scripts/remote-bootstrap.sh
```

The dp guardrails in `remote-bootstrap.sh` no-op automatically when no `data-platform-core-*` containers are present on the VM.

### First deploy on the SHARED `vultr-dp` VM (option A — coexists with data-platform-core)

Use this **only** if you explicitly want to share the existing VM. Otherwise prefer option B above — fresh VM is safer and the dp guardrail story becomes moot. Two stages: (1) bring stack up with HTTP-only for cert challenge, (2) issue cert and switch nginx to HTTPS.

```bash
# Stage 1 — bootstrap + HTTP-only nginx (so certbot ACME challenge works)
ENABLE_TLS=0 ./.claude/skills/vultr-single/scripts/remote-bootstrap.sh
```

What the script does (idempotent, safe to re-run):
1. SSHes into `vultr-dp`, ensures `git`/`docker`/`rsync` present, creates 8 GB swap if RAM <6 GB
2. Snapshots Dify postgres if it exists (defense in depth, lands under `/opt/dify/.local/backups/`)
3. Rsyncs `origin/${BRANCH}` source to `/opt/dify/`
4. Scaffolds `.env` if missing (NGINX_SERVER_NAME, COMPOSE_PROJECT_NAME, SECRET_KEY auto-generated, domain placeholder)
5. Builds local web image `metasolutions/mds-web:<git-describe>-mds` via `make build-mds-web` (slow first time — Next.js build on small VM)
6. Writes `docker/docker-compose.override.yaml` pinning `web` to the local MDS image
7. Runs `docker compose -p dify up -d` (HTTP-only at this stage)
8. Polls `http://localhost/console/api/version` until healthy

```bash
# Stage 2 — issue Let's Encrypt cert (one-time, after DNS is propagated)
/usr/bin/ssh vultr-dp 'cd /opt/dify/docker && docker compose -p dify --profile certbot run --rm certbot \
  certonly --webroot --webroot-path=/var/www/html \
  --email admin.department@metasolutions.software --agree-tos --no-eff-email \
  -d agent.metasolutions.ai'

# Flip nginx to HTTPS and re-up
ENABLE_TLS=1 ./.claude/skills/vultr-single/scripts/remote-bootstrap.sh
```

After Stage 2: `https://agent.metasolutions.ai` serves the MDS Dify console.

### Regular deploy (already-bootstrapped VM, TLS already set up)

```bash
./.claude/skills/vultr-single/scripts/remote-bootstrap.sh
```

Same script — bootstrap steps no-op, rebuilds the web image only if source changed, brings stack up with HTTPS (script defaults to `ENABLE_TLS=1` once cert exists). Skip the web rebuild with `REBUILD_WEB=0` if you only changed i18n or config.

Deploy a different branch:

```bash
BRANCH=feature/something ./.claude/skills/vultr-single/scripts/remote-bootstrap.sh
```

## Day-2 operations

All operations target the `dify` compose project to keep them isolated from data-platform-core. Run from operator's laptop.

### Status

```bash
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify ps"
/usr/bin/ssh vultr-dp "curl -sk https://agent.metasolutions.ai/console/api/version"
```

### Tail logs

```bash
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify logs -f --tail=200 api"
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify logs -f --tail=200 worker"
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify logs -f --tail=200 web"
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify logs -f --tail=200 nginx"
```

### Restart one service (no rebuild)

```bash
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify restart api"
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify restart worker"
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify restart web"
```

### psql into the Dify DB

```bash
ssh -t vultr-dp "docker exec -it dify-db_postgres-1 psql -U postgres -d dify"
```

### Run a one-off Flask command (alembic migrate, etc.)

```bash
/usr/bin/ssh vultr-dp "docker exec -it dify-api-1 flask db upgrade"
```

### Stop the stack (preserves DB + uploaded files)

```bash
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify down"
```

> **Never** use `-v` here. Dify bind-mounts under `/opt/dify/docker/volumes/{db,redis,weaviate,app/storage}`. `-v` removes named volumes (Dify doesn't use any by default), but the muscle-memory rule prevents accidents.

### Force rebuild of MDS web image

```bash
/usr/bin/ssh vultr-dp "cd /opt/dify && make build-mds-web"
/usr/bin/ssh vultr-dp "cd /opt/dify/docker && docker compose -p dify up -d --force-recreate --no-deps web"
```

### Renew TLS cert

Certbot inside the dify compose has its own profile. Run manually monthly (or wire a cron — not in this skill yet):

```bash
/usr/bin/ssh vultr-dp 'cd /opt/dify/docker && docker compose -p dify --profile certbot run --rm certbot renew \
  && docker compose -p dify exec nginx nginx -s reload'
```

### Wipe Dify only (DESTRUCTIVE — does NOT touch data-platform-core)

```bash
/usr/bin/ssh vultr-dp 'cd /opt/dify/docker && docker compose -p dify down \
  && rm -rf /opt/dify/docker/volumes/{db,redis,weaviate,app/storage}'
# Then re-deploy
ENABLE_TLS=1 ./.claude/skills/vultr-single/scripts/remote-bootstrap.sh
```

## Migrating data from a local Dify

Workflow used to move local `docker-*` Dify (Mac Docker Desktop) → fresh VPS. Total data was ~230 MB (postgres 78 MB + plugin_daemon 144 MB + app/storage 5 MB), scp took ~10 s.

```bash
# === On laptop ===
# 0. Inventory (so you know what's being shipped)
docker exec docker-db_postgres-1 du -sh /var/lib/postgresql/data
du -sh ~/Documents/git_personal/hong_ngoc_ha_demo/dify/docker/volumes/{app,weaviate,plugin_daemon}/

# 1. Freeze writes (keeps db/redis up for pg_dump but stops api/worker)
cd ~/Documents/git_personal/hong_ngoc_ha_demo/dify/docker
docker compose stop api worker worker_beat

# 2. Dump postgres + tar bind-mount volumes
docker exec docker-db_postgres-1 pg_dump -U postgres -d dify --clean --if-exists | gzip > /tmp/dify-pg.sql.gz
tar -C volumes -czf /tmp/dify-volumes.tar.gz app weaviate plugin_daemon
ls -lh /tmp/dify-pg.sql.gz /tmp/dify-volumes.tar.gz

# 3. Ship to VPS
scp /tmp/dify-pg.sql.gz /tmp/dify-volumes.tar.gz vultr-agent:/tmp/

# === On VPS ===
# 4. SECRET_KEY must match the local Dify's, or encrypted fields (LLM API keys,
#    OAuth tokens) in DB won't decrypt. Local default is the inline value in
#    docker-compose.yaml. Sync via:
/usr/bin/ssh vultr-agent "sed -i 's|^SECRET_KEY=.*|SECRET_KEY=sk-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U|' /opt/dify/docker/.env"

# 5. Stop dify services that lock the volumes, restore, restart
/usr/bin/ssh vultr-agent 'set -e
cd /opt/dify/docker
docker compose -p dify stop api worker worker_beat web plugin_daemon weaviate
gunzip < /tmp/dify-pg.sql.gz | docker exec -i dify-db_postgres-1 psql -U postgres -d dify
cd /opt/dify/docker/volumes
TS=$(date +%s)
for d in app weaviate plugin_daemon; do [ -d "$d" ] && mv "$d" "${d}.bak.${TS}"; done
tar -xzf /tmp/dify-volumes.tar.gz
chown -R 1001:1001 app weaviate plugin_daemon
cd /opt/dify/docker
docker compose -p dify up -d'

# 6. First call to API likely hangs (gunicorn cold start); restart api once:
/usr/bin/ssh vultr-agent "cd /opt/dify/docker && docker compose -p dify restart api"

# 7. Restart local stack (optional — if you still want local working)
cd ~/Documents/git_personal/hong_ngoc_ha_demo/dify/docker && docker compose start api worker worker_beat
```

### Adding a second owner to the migrated tenant

Useful when you migrated under a personal email but want a company admin too (without losing the original 5 apps). Done with a CLI hack + raw SQL:

```bash
# 1. CLI creates a NEW account (and a throwaway tenant) — needs both feature flags
/usr/bin/ssh vultr-agent "docker exec -e ALLOW_REGISTER=true -e ALLOW_CREATE_WORKSPACE=true dify-api-1 \
  flask create-tenant --email <new-admin>@<domain> --name 'Throwaway' --language en-US"
# Note the printed temp password — reset it later with `flask reset-password`.

# 2. SQL: attach the new account to the original tenant as owner, then drop the throwaway
/usr/bin/ssh vultr-agent "docker exec dify-db_postgres-1 psql -U postgres -d dify -c \"
  BEGIN;
  INSERT INTO tenant_account_joins (tenant_id, account_id, role, current)
    VALUES ('<ORIGINAL_TENANT_ID>', '<NEW_ACCOUNT_ID>', 'owner', false);
  DELETE FROM tenant_account_joins WHERE tenant_id = '<THROWAWAY_TENANT_ID>';
  DELETE FROM tenants WHERE id = '<THROWAWAY_TENANT_ID>';
  COMMIT;\""
```

## Coexistence checklist (do this before exposing)

- [ ] DNS `agent.metasolutions.ai` → `207.148.120.195` propagated
- [ ] VM upgraded to `vc2-4c-8gb` (or confirm 4GB+swap is acceptable for use)
- [ ] Cert issued (Stage 2 above), `/usr/bin/ssh vultr-dp 'ls /etc/letsencrypt/live/agent.metasolutions.ai/'` shows `fullchain.pem` + `privkey.pem`
- [ ] `data-platform-core` still healthy after Dify boots: `/usr/bin/ssh vultr-dp 'curl -s http://localhost:8001/api/scheduler/status'`
- [ ] Set strong `SECRET_KEY` + `INIT_PASSWORD` in `/opt/dify/docker/.env` (script auto-generates `SECRET_KEY` on first scaffold; rotate before public exposure)
- [ ] Set up a non-root admin account via `/install` on first visit; lock down `INIT_PASSWORD`

## Gotchas

- **Vultr SSH key may not match local key**: the Vultr-account-registered key with comment `data-platform-core` might be a different keypair than `~/.ssh/vultr_vm_data_platform` on your laptop (fingerprint mismatch). Before provisioning, run `ssh-keygen -lf ~/.ssh/vultr_vm_data_platform.pub` and compare with `vultr-cli ssh list | jq -r '.ssh_keys[].ssh_key' | ssh-keygen -lf -`. If different, upload your local `.pub` as a NEW Vultr key (`vultr-cli ssh create --name "MDS Dify Local" --key "$(cat ~/.ssh/vultr_vm_data_platform.pub)"`) and pass `VULTR_SSH_KEY_NAME="MDS Dify Local"` to the wrapper.
- **Recycled IP host-key collision**: Vultr reassigns IPs across instances. After destroying a VM and provisioning a new one with the same IP, `~/.ssh/known_hosts` still has the old host key → SSH fails with `REMOTE HOST IDENTIFICATION HAS CHANGED!` even with `StrictHostKeyChecking=accept-new`. The wrapper now auto-runs `ssh-keygen -R "$PUB_IP"` after VM is active. If you SSH manually before the wrapper finishes: `ssh-keygen -R 139.180.152.22`.
- **Private repo on cloud-init clone**: `fluxnoddle/dify-mds-rebrand` was originally private; cloud-init's `git clone` failed with `could not read Username`. Either make the repo public (`gh repo edit ... --visibility public`), embed a deploy token in `REPO_URL`, or switch to SSH+deploy-key (most secure).
- **Dify gunicorn first-boot hang**: after fresh boot, `dify-api-1`'s first request can hang 30s+ (gevent worker init), making `/install` "treo". Symptom: api container shows `(unhealthy)`, no "Booting worker" log line. Fix: `docker compose -p dify restart api` — boots cleanly on 2nd try.
- **Certbot wrapper entrypoint quirk**: Dify wraps `certbot` with `/docker-entrypoint.sh` that `exec "$@"`. Running `docker compose --profile certbot run --rm certbot certonly ...` fails (`certonly: not found`). **Must invoke the binary explicitly**: `docker compose --profile certbot run --rm certbot certbot certonly --webroot ...`.
- **Let's Encrypt cert filename != defaults**: after `certbot certonly`, certs land at `/etc/letsencrypt/live/$DOMAIN/{fullchain.pem,privkey.pem}` but Dify nginx defaults look for `dify.crt`/`dify.key`. After issuing the cert, append to `.env`: `NGINX_SSL_CERT_FILENAME=fullchain.pem` + `NGINX_SSL_CERT_KEY_FILENAME=privkey.pem`, then recreate nginx.
- **Adding a 2nd owner to an existing tenant via CLI**: `flask create-tenant` creates account + tenant. It also requires `ALLOW_REGISTER=true` and `ALLOW_CREATE_WORKSPACE=true` (pass via `docker exec -e ...`). It can't add to an EXISTING tenant — do that with raw SQL: `INSERT INTO tenant_account_joins (tenant_id, account_id, role, current) VALUES ('<tenant>', '<new_account>', 'owner', false);` then delete the throwaway tenant.
- **Port conflicts**: Dify nginx binds host `80` and `443`. Data-platform-core uses `3000/8001/9001/5433/5434` — no overlap. If you add Caddy/Traefik as a host-level reverse proxy, move dify's `EXPOSE_NGINX_PORT` off 80/443.
- **Container name collision**: without `-p dify`, compose defaults to project name `docker` (the directory it sits in) — same as data-platform-core would if you ran from `docker/`. **Always pass `-p dify`** for dify commands. The `COMPOSE_PROJECT_NAME=dify` line in `.env` makes this the default for ad-hoc `docker compose ...` invocations from `/opt/dify/docker`.
- **First web build is slow**: `make build-mds-web` runs `pnpm install` + `next build` inside Docker on a 4 GB VM. Plan for 10–20 min. Cached on subsequent builds.
- **Image registry**: this skill does **not** push images. If you set up GHCR/Docker Hub for `metasolutions/mds-web`, swap the `make build-mds-web` step for `docker pull` and remove the override file. Faster but needs registry credentials on the VM.
- **`updates.dify.ai` ping**: Dify api hits `https://updates.dify.ai` for update checks. Set `CHECK_UPDATE_URL=` (empty) in `.env` if you want to mute this.
- **Marketplace**: defaults to `https://marketplace.dify.ai` — fine to keep. Override to self-hosted via `MARKETPLACE_URL=` if needed.
- **`docker system prune` is forbidden**: would nuke data-platform-core images too. Clean up Dify-specific cruft with `docker images | grep -E 'mds-web|dify-' | awk '{print $3}' | xargs -r docker rmi`.
- **Shared docker network**: both stacks live on default bridge networks per their compose. No cross-talk needed; if you ever do need it, create a shared external network with `docker network create shared` and reference it from both compose files.

## Tear-down checklist (destroy VM + clean up local + Vultr artifacts)

When the test/demo is done. Reversible only by re-running the full provision.

```bash
# === Before destroying — take a final backup if data matters ===
/usr/bin/ssh vultr-agent "docker exec dify-db_postgres-1 pg_dump -U postgres -d dify --clean --if-exists | gzip" \
  > ~/dify-pg-final-$(date +%F).sql.gz
/usr/bin/ssh vultr-agent "tar -C /opt/dify/docker/volumes -czf - app weaviate plugin_daemon" \
  > ~/dify-volumes-final-$(date +%F).tar.gz
ls -lh ~/dify-*-final-*.gz

# === Stop containers gracefully (optional — destroy implies this) ===
/usr/bin/ssh vultr-agent "cd /opt/dify/docker && docker compose -p dify down" || true

# === Destroy the Vultr instance (this also removes the SSD/disk) ===
vultr-cli instance delete 6787a136-7a70-440e-b935-b9b94d5bf65c

# === Delete the Vultr-side SSH key (only the one we created for this VM) ===
# Skip if you want to reuse 'MDS Dify Local' for future VMs.
vultr-cli ssh delete f8f76a2b-c84b-405a-9a6e-86fac8bb11e1

# === Local cleanup ===
# 1. Remove the SSH alias block. Edit ~/.ssh/config manually OR (macOS sed):
#    Look for the block starting with "# Added by provision-and-deploy.sh ..."
#    immediately above "Host vultr-agent" and delete to the next blank line.

# 2. Purge known_hosts entry (Vultr will reassign this IP eventually)
ssh-keygen -R 139.180.152.22

# 3. Optional: remove the docker-compose.override.yaml created on the laptop
rm -f docker/docker-compose.override.yaml

# 4. Optional: remove the locally built MDS web image
docker rmi metasolutions/mds-web:latest metasolutions/mds-web:rebrand 2>/dev/null || true

# === DNS — keep or remove ===
# The 'agent A 139.180.152.22' record at Vercel DNS becomes a dangling pointer
# once the IP is released. Either delete it from Vercel Dashboard → Domains →
# metasolutions.ai → DNS Records, or update it next time you redeploy.
# Let's Encrypt certificate auto-expires in 90 days; no cleanup needed.

# === Revoke Vultr API key (if it was created just for this test) ===
# my.vultr.com/settings/#settingsapi → revoke the personal access token
# (especially if it was leaked in chat during setup — rotate regardless).
```

After destruction, `/usr/bin/ssh vultr-agent` will fail (`Connection refused`); that's the signal teardown is complete. Re-provision with `./.claude/skills/vultr-single/scripts/provision-and-deploy.sh` whenever needed — the skill is fully repeatable.

## What this skill does NOT do

- ❌ Provision the VM (already done by `data-platform-core` skill — share the same VM)
- ❌ Manage the DNS A record (set manually in registrar, one-time)
- ❌ Push images to a registry (build-on-VM only)
- ❌ Manage TLS auto-renewal cron (manual `renew` for now)
- ❌ Reverse-proxy Dify + dp behind a single Caddy (each stack owns its own ports)
- ❌ Migrate Dify data between VMs (use Dify's export/import flows + `pg_dump` of the postgres volume)
