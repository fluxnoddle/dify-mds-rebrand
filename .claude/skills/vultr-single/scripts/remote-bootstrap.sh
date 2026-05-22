#!/usr/bin/env bash
# Vultr single-VM deploy for Dify (MDS rebrand). Coexists with data-platform-core
# on the same VM. Ships origin/<BRANCH> to vultr-dp and runs docker compose with
# project name 'dify' (containers prefixed dify-*).
#
# Idempotent — first run installs Docker + scaffolds .env; subsequent runs rsync,
# rebuild the MDS web image, and re-up the stack.
#
# Env overrides:
#   BRANCH=rebrand-mds-metasolutions  # branch to deploy
#   SSH_HOST=vultr-dp                 # SSH alias / hostname
#   REMOTE_PATH=/opt/dify
#   COMPOSE_PROJECT=dify              # container name prefix
#   DOMAIN=agent.metasolutions.ai
#   CERTBOT_EMAIL=admin.department@metasolutions.software
#   ENABLE_TLS=1                      # 1=NGINX_HTTPS_ENABLED=true (cert must exist),
#                                     # 0=HTTP-only (use for first-run cert challenge)
#   REBUILD_WEB=1                     # 1=make build-mds-web before up, 0=skip
#   SKIP_DB_BACKUP=0                  # 1=skip pre-deploy pg_dump
#   SKIP_HEALTH_WAIT=0                # 1=don't poll /console/api/version after deploy
set -euo pipefail

BRANCH="${BRANCH:-rebrand-mds-metasolutions}"
SSH_HOST="${SSH_HOST:-vultr-dp}"
REMOTE_PATH="${REMOTE_PATH:-/opt/dify}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-dify}"
DOMAIN="${DOMAIN:-agent.metasolutions.ai}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin.department@metasolutions.software}"
ENABLE_TLS="${ENABLE_TLS:-1}"
REBUILD_WEB="${REBUILD_WEB:-1}"
SKIP_DB_BACKUP="${SKIP_DB_BACKUP:-0}"
SKIP_HEALTH_WAIT="${SKIP_HEALTH_WAIT:-0}"

# ---- colors --------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { echo "${C_BLUE}[deploy]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[ ok  ]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[warn ]${C_RESET} $*"; }
die()  { echo "${C_RED}[fail ]${C_RESET} $*" >&2; exit 1; }

# ---- pre-flight ----------------------------------------------------------
# Hard rule: never operate against the data-platform-core footprint. Refuse to
# run if REMOTE_PATH is empty, root, or any prefix of /opt/data-platform-core /
# /opt/litellm. See SKILL.md "Hard rule — DO NOT touch data-platform-core".
case "$REMOTE_PATH" in
  ""|"/"|"/opt"|"/opt/"|"/opt/data-platform-core"|"/opt/data-platform-core/"*|"/opt/litellm"|"/opt/litellm/"*)
    die "Refusing: REMOTE_PATH='${REMOTE_PATH}' overlaps data-platform-core / host root. Set REMOTE_PATH=/opt/dify (or another isolated path)."
    ;;
esac

log "Pre-flight: SSH to ${SSH_HOST} ..."
ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" "true" \
  || die "Cannot SSH to ${SSH_HOST}. Check ~/.ssh/config and that ssh-copy-id has been run."
ok "SSH reachable."

# Snapshot data-platform-core container state BEFORE we touch anything, so the
# post-deploy assertion has a baseline. Empty result = dp not running on this
# VM (likely a dedicated Dify-only VM), which is fine — assertion is skipped.
DP_BASELINE="$(ssh "$SSH_HOST" "docker ps --format '{{.Names}}\t{{.Status}}' \
  | grep -E '^(data-platform-core|litellm)-' || true")"
DP_BASELINE_COUNT="$(echo -n "$DP_BASELINE" | grep -c . || true)"
if [[ "$DP_BASELINE_COUNT" -gt 0 ]]; then
  ok "data-platform-core baseline: ${DP_BASELINE_COUNT} container(s) Up — will verify after deploy."
else
  log "No data-platform-core containers detected on ${SSH_HOST} — solo Dify VM, dp guardrail will no-op."
fi

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

log "Fetching origin/${BRANCH} ..."
git fetch origin "$BRANCH" --quiet || die "git fetch origin ${BRANCH} failed. Push your local commits first."
COMMIT="$(git rev-parse "origin/${BRANCH}")"
ok "origin/${BRANCH} = ${COMMIT:0:12}"

# ---- 1. ensure prerequisites on the VM (idempotent, coexists with dp) ----
log "Ensuring git/rsync/docker on ${SSH_HOST} ..."
ssh "$SSH_HOST" "bash -s" <<'REMOTE_PREREQ'
set -euo pipefail

need_install=0
command -v git    >/dev/null || need_install=1
command -v curl   >/dev/null || need_install=1
command -v rsync  >/dev/null || need_install=1
command -v docker >/dev/null || need_install=1

if [[ $need_install -eq 1 ]]; then
  echo "[vm] installing prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git curl rsync ca-certificates >/dev/null
fi

if ! command -v docker >/dev/null; then
  echo "[vm] installing docker via get.docker.com ..."
  curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "[vm] installing docker-compose-plugin..."
  apt-get install -y -qq docker-compose-plugin >/dev/null
fi

# Combined Dify + data-platform-core stack peaks ~10 GB. Add 8 GB swap if total
# RAM < 6 GB so first boot doesn't OOM. Idempotent — skip if active.
total_mb=$(free -m | awk '/^Mem:/{print $2}')
if [[ "$total_mb" -lt 6000 ]]; then
  if ! swapon --show | grep -q '^/swapfile'; then
    echo "[vm] RAM ${total_mb}MB < 6GB; creating 8GB swapfile ..."
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo "[vm] swap active: $(swapon --show --noheadings)"
  fi
fi

mkdir -p /opt/dify
echo "[vm] prerequisites OK ($(docker --version), $(docker compose version | head -1))"
echo "[vm] memory: $(free -h | awk '/^Mem:/{print $2" total, "$7" available"} /^Swap:/{print "swap "$2}')"
REMOTE_PREREQ
ok "VM prerequisites OK."

# ---- 2. defense in depth: pg_dump Dify postgres BEFORE rsync -------------
# Same rule as data-platform-core: take a logical dump before touching code on
# the VM. Lands under /opt/dify/.local/backups/ (gitignored, not rsync'd).
if [[ "$SKIP_DB_BACKUP" != "1" ]]; then
  log "Snapshotting Dify postgres before rsync (if container exists) ..."
  ssh "$SSH_HOST" "bash -s" <<REMOTE_BACKUP
set -euo pipefail
TS=\$(date -u +%Y-%m-%d-%H%M)
BACKUP_DIR="${REMOTE_PATH}/.local/backups/pre-deploy-\${TS}"
if docker ps --format '{{.Names}}' | grep -q '^${COMPOSE_PROJECT}-db_postgres-1\$'; then
  mkdir -p "\$BACKUP_DIR"
  echo "[vm]   pg_dump dify → \$BACKUP_DIR/dify.sql.gz"
  docker exec ${COMPOSE_PROJECT}-db_postgres-1 pg_dump \
      -U postgres -d dify --clean --if-exists \
    | gzip > "\$BACKUP_DIR/dify.sql.gz"
  gunzip -t "\$BACKUP_DIR/dify.sql.gz"
  # Retention: keep last 14 pre-deploy snapshots
  ls -1dt "${REMOTE_PATH}/.local/backups/pre-deploy-"* 2>/dev/null \
    | tail -n +15 | xargs -r rm -rf
  du -sh "\$BACKUP_DIR" || true
else
  echo "[vm]   no ${COMPOSE_PROJECT}-db_postgres-1 container yet — skipping backup."
fi
REMOTE_BACKUP
  ok "Pre-deploy backup step complete."
else
  log "SKIP_DB_BACKUP=1 — skipping pg_dump."
fi

# ---- 3. ship code (git archive + rsync) ---------------------------------
log "Exporting origin/${BRANCH} as tarball ..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
git archive --format=tar "origin/${BRANCH}" | tar -x -C "$TMPDIR"
ok "Exported $(find "$TMPDIR" -type f | wc -l | tr -d ' ') files to $TMPDIR"

log "Rsyncing to ${SSH_HOST}:${REMOTE_PATH} (preserving .env + bind-mounted data) ..."
# Excludes mirror the rule used by data-platform-core: every path that is a
# host bind-mount target on the VM goes here, otherwise --delete will wipe
# live data. Dify bind-mounts live under docker/volumes/.
rsync -az --delete \
  --exclude='/.git' \
  --exclude='/.env' \
  --exclude='/.local' \
  --exclude='/docker/.env' \
  --exclude='/docker/volumes' \
  --exclude='/docker/certbot' \
  --exclude='/docker/nginx/ssl' \
  --exclude='/docker/docker-compose.override.yaml' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='node_modules' \
  -e "ssh" \
  "$TMPDIR/" "${SSH_HOST}:${REMOTE_PATH}/"
ok "Rsync complete."

# ---- 4. ensure docker/.env, override file, then up ----------------------
log "Configuring .env + override + bringing stack up ..."
ssh "$SSH_HOST" "bash -s" <<REMOTE_DEPLOY
set -euo pipefail
cd "${REMOTE_PATH}"

# 4a. Scaffold docker/.env from .env.example on first deploy. Subsequent runs
# preserve operator edits.
if [[ ! -f docker/.env ]]; then
  echo "[vm] scaffolding docker/.env from .env.example ..."
  cp docker/.env.example docker/.env

  # Inject our shared-VM defaults. Use printf to avoid sed special-char headaches.
  SECRET_KEY="\$(openssl rand -base64 42)"
  {
    echo ""
    echo "# --- MDS rebrand / shared-VM overrides (managed by remote-bootstrap.sh) ---"
    echo "COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT}"
    echo "SECRET_KEY=\$SECRET_KEY"
    echo "NGINX_SERVER_NAME=${DOMAIN}"
    echo "CERTBOT_DOMAIN=${DOMAIN}"
    echo "CERTBOT_EMAIL=${CERTBOT_EMAIL}"
    echo "CHECK_UPDATE_URL="
  } >> docker/.env
  echo "[vm] docker/.env scaffolded with SECRET_KEY generated."
fi

# 4b. Toggle NGINX_HTTPS_ENABLED + ACME challenge based on ENABLE_TLS.
# Stage 1 (ENABLE_TLS=0): HTTPS off, ACME challenge endpoint on — for first cert.
# Stage 2 (ENABLE_TLS=1): HTTPS on, ACME challenge still on for renewal.
if [[ "${ENABLE_TLS}" == "1" ]]; then
  sed -i 's/^NGINX_HTTPS_ENABLED=.*/NGINX_HTTPS_ENABLED=true/' docker/.env
  grep -q '^NGINX_HTTPS_ENABLED=' docker/.env || echo 'NGINX_HTTPS_ENABLED=true' >> docker/.env
else
  sed -i 's/^NGINX_HTTPS_ENABLED=.*/NGINX_HTTPS_ENABLED=false/' docker/.env
  grep -q '^NGINX_HTTPS_ENABLED=' docker/.env || echo 'NGINX_HTTPS_ENABLED=false' >> docker/.env
fi
sed -i 's/^NGINX_ENABLE_CERTBOT_CHALLENGE=.*/NGINX_ENABLE_CERTBOT_CHALLENGE=true/' docker/.env
grep -q '^NGINX_ENABLE_CERTBOT_CHALLENGE=' docker/.env || echo 'NGINX_ENABLE_CERTBOT_CHALLENGE=true' >> docker/.env

# 4c. Pin web service to our MDS image via override (separate from gitignored
# laptop-side override). Idempotent.
cat > docker/docker-compose.override.yaml <<'EOF_OVERRIDE'
services:
  web:
    image: metasolutions/mds-web:latest
EOF_OVERRIDE

# 4d. Build MDS web image on the VM (slow first time — Next.js + pnpm install).
if [[ "${REBUILD_WEB}" == "1" ]]; then
  echo "[vm] make build-mds-web ..."
  make build-mds-web
else
  echo "[vm] REBUILD_WEB=0 — skipping web image rebuild."
fi

# 4e. Mark which commit is deployed.
echo "${COMMIT}" > .deployed-commit
echo "${BRANCH}" > .deployed-branch

# 4f. Bring stack up. Explicit -p so we never collide with data-platform-core.
cd docker
echo "[vm] docker compose -p ${COMPOSE_PROJECT} up -d ..."
docker compose -p ${COMPOSE_PROJECT} \
  -f docker-compose.yaml \
  -f docker-compose.override.yaml \
  up -d

echo "[vm] services:"
docker compose -p ${COMPOSE_PROJECT} ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}"
REMOTE_DEPLOY
ok "Stack started."

# ---- 4b. dp safety assertion --------------------------------------------
# Compare current dp container state against the baseline captured pre-deploy.
# Any regression (dropped name, status no longer 'Up ...') is a hard fail —
# this skill must never collateral-damage data-platform-core.
if [[ "$DP_BASELINE_COUNT" -gt 0 ]]; then
  log "Verifying data-platform-core containers are still Up ..."
  DP_AFTER="$(ssh "$SSH_HOST" "docker ps --format '{{.Names}}\t{{.Status}}' \
    | grep -E '^(data-platform-core|litellm)-' || true")"
  DP_AFTER_COUNT="$(echo -n "$DP_AFTER" | grep -c . || true)"

  # Names that were Up before but are now missing entirely
  REGRESSED="$(comm -23 \
    <(echo "$DP_BASELINE" | awk -F'\t' '{print $1}' | sort) \
    <(echo "$DP_AFTER"    | awk -F'\t' '{print $1}' | sort) || true)"
  # Names that exist after but are no longer 'Up ...' (e.g., Restarting / Exited)
  NOT_UP="$(echo "$DP_AFTER" | awk -F'\t' '$2 !~ /^Up/ {print $1}')"

  if [[ -n "$REGRESSED" ]] || [[ -n "$NOT_UP" ]]; then
    warn "data-platform-core regression detected!"
    [[ -n "$REGRESSED" ]] && warn "  Missing now: $(echo $REGRESSED)"
    [[ -n "$NOT_UP"    ]] && warn "  Not Up now:  $(echo $NOT_UP)"
    warn "Baseline ($DP_BASELINE_COUNT):"
    echo "$DP_BASELINE"   | sed 's/^/  /' >&2
    warn "After ($DP_AFTER_COUNT):"
    echo "$DP_AFTER"      | sed 's/^/  /' >&2
    die "Refusing to claim success — data-platform-core lost containers during Dify deploy. Investigate before re-running."
  fi
  ok "data-platform-core still healthy (${DP_AFTER_COUNT} Up, matches baseline)."
fi

# ---- 5. health wait ------------------------------------------------------
if [[ "$SKIP_HEALTH_WAIT" != "1" ]]; then
  if [[ "$ENABLE_TLS" == "1" ]]; then
    HEALTH_URL="https://${DOMAIN}/console/api/version"
    CURL_OPTS="-fkSs"
  else
    HEALTH_URL="http://localhost/console/api/version"
    CURL_OPTS="-fsS"
  fi
  log "Polling ${HEALTH_URL} (up to 180s — first-run Next.js boot is slow) ..."
  for i in $(seq 1 60); do
    if ssh "$SSH_HOST" "curl ${CURL_OPTS} -m 3 ${HEALTH_URL} >/dev/null 2>&1"; then
      ok "Dify console API healthy after ${i} attempt(s)."
      break
    fi
    if [[ $i -eq 60 ]]; then
      warn "Not healthy after 180s. Check: /usr/bin/ssh ${SSH_HOST} 'cd ${REMOTE_PATH}/docker && docker compose -p ${COMPOSE_PROJECT} logs --tail=200 api worker nginx'"
      break
    fi
    sleep 3
  done
fi

# ---- 6. summary ----------------------------------------------------------
echo
ok "Deployed origin/${BRANCH} (${COMMIT:0:12}) to ${SSH_HOST}:${REMOTE_PATH}"
echo
if [[ "$ENABLE_TLS" == "1" ]]; then
  echo "  Console   : https://${DOMAIN}/install   (first visit sets up admin)"
  echo "  API root  : https://${DOMAIN}/console/api/version"
else
  echo "  Console   : http://${DOMAIN}/install   (TLS not yet enabled)"
  echo "  Next step : issue cert, then rerun with ENABLE_TLS=1:"
  echo "              /usr/bin/ssh ${SSH_HOST} 'cd ${REMOTE_PATH}/docker && docker compose -p ${COMPOSE_PROJECT} --profile certbot run --rm certbot \\"
  echo "                certonly --webroot --webroot-path=/var/www/html \\"
  echo "                --email ${CERTBOT_EMAIL} --agree-tos --no-eff-email -d ${DOMAIN}'"
fi
echo
echo "  Logs      : /usr/bin/ssh ${SSH_HOST} 'cd ${REMOTE_PATH}/docker && docker compose -p ${COMPOSE_PROJECT} logs -f api'"
echo "  Status    : /usr/bin/ssh ${SSH_HOST} 'cd ${REMOTE_PATH}/docker && docker compose -p ${COMPOSE_PROJECT} ps'"
echo "  Coexist   : data-platform-core still at http://207.148.120.195:3000"
echo
