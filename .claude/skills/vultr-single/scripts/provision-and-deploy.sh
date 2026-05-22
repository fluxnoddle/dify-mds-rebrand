#!/usr/bin/env bash
# Provision a NEW Vultr VM via vultr-cli + cloud-init, then issue TLS cert and
# flip nginx to HTTPS. End state: https://$DOMAIN serves the MDS-rebranded Dify.
#
# Prereqs:
#   - vultr-cli installed (brew install vultr/vultr-cli/vultr-cli)
#   - VULTR_API_KEY env var set
#   - An SSH key already uploaded to your Vultr account
#
# Env overrides:
#   VULTR_PLAN=vc2-4c-8gb          # 8GB RAM, $40/mo — recommended for Dify
#   VULTR_REGION=sgp               # Singapore — closest to VN
#   VULTR_OS_ID=2284               # Ubuntu 24.04 LTS x64 (check `vultr-cli os list`)
#   VULTR_SSH_KEY_NAME=            # filter by key name; default = first key
#   LABEL=dify-test
#   SSH_ALIAS=vultr-dify
#   DOMAIN=agent.metasolutions.ai
#   CERTBOT_EMAIL=admin.department@metasolutions.software
#   SKIP_CERT=0                    # 1 = stop before cert issuance
#   AUTO_DNS_WAIT=0                # 1 = poll dig until A record matches, instead of read
set -euo pipefail

VULTR_PLAN="${VULTR_PLAN:-vc2-4c-8gb}"
VULTR_REGION="${VULTR_REGION:-sgp}"
VULTR_OS_ID="${VULTR_OS_ID:-2284}"
VULTR_SSH_KEY_NAME="${VULTR_SSH_KEY_NAME:-}"
# Local private key file matching the Vultr SSH key. The wrapper writes this
# into the ~/.ssh/config block so /usr/bin/ssh vultr-agent picks the right key
# without needing the operator to remember -i. Default reuses the existing
# data-platform-core key — override if you maintain separate keys.
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-$HOME/.ssh/vultr_vm_data_platform}"
LABEL="${LABEL:-dify-agent}"
SSH_ALIAS="${SSH_ALIAS:-vultr-agent}"
DOMAIN="${DOMAIN:-agent.metasolutions.ai}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin.department@metasolutions.software}"
SKIP_CERT="${SKIP_CERT:-0}"
AUTO_DNS_WAIT="${AUTO_DNS_WAIT:-0}"

# ---- colors ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { echo "${C_BLUE}[provision]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}[   ok   ]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[  warn  ]${C_RESET} $*"; }
die()  { echo "${C_RED}[  fail  ]${C_RESET} $*" >&2; exit 1; }

# ---- 1. pre-flight --------------------------------------------------------
command -v vultr-cli >/dev/null || die "vultr-cli not installed. brew install vultr/vultr-cli/vultr-cli"
command -v jq        >/dev/null || die "jq not installed. brew install jq"
command -v base64    >/dev/null || die "base64 not installed."

# vultr-cli reads the key from either VULTR_API_KEY env var or ~/.vultr-cli.yaml
# (key 'api-key'). Probe with a cheap call instead of gating on env var so users
# with a configured yaml work too.
if ! vultr-cli ssh list -o json >/dev/null 2>&1; then
  if [[ -z "${VULTR_API_KEY:-}" ]] && [[ ! -s "$HOME/.vultr-cli.yaml" ]]; then
    die "vultr-cli is unauthenticated. Either export VULTR_API_KEY=... or put 'api-key: <key>' in ~/.vultr-cli.yaml"
  fi
  die "vultr-cli failed to list ssh keys. Auth likely stale. Get a fresh key from https://my.vultr.com/settings/#settingsapi and run: export VULTR_API_KEY='<key>'"
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$SKILL_DIR/cloud-init-dify.yaml"
[[ -f "$CI_FILE" ]] || die "cloud-init missing: $CI_FILE"

# ---- 2. resolve SSH key id -----------------------------------------------
log "Looking up Vultr SSH key id ..."
SSH_KEYS_JSON=$(vultr-cli ssh list -o json 2>/dev/null) || die "vultr-cli ssh list failed (auth was OK at probe — race? retry)."
if [[ -n "$VULTR_SSH_KEY_NAME" ]]; then
  SSH_KEY_ID=$(echo "$SSH_KEYS_JSON" | jq -r ".ssh_keys[] | select(.name==\"$VULTR_SSH_KEY_NAME\") | .id" | head -1)
else
  SSH_KEY_ID=$(echo "$SSH_KEYS_JSON" | jq -r '.ssh_keys[0].id // empty')
fi
[[ -n "$SSH_KEY_ID" ]] || die "No SSH key found in Vultr account. Upload one via the console first."
ok "SSH key id: $SSH_KEY_ID"

# ---- 4. create instance --------------------------------------------------
# vultr-cli v3.10 flag names: --host (not --hostname), --userdata-file accepts
# plain text from a path (CLI does the base64 encoding for the API itself).
log "Creating VM (plan=$VULTR_PLAN region=$VULTR_REGION os=$VULTR_OS_ID label=$LABEL) ..."
INSTANCE_JSON=$(vultr-cli instance create \
  --plan "$VULTR_PLAN" --region "$VULTR_REGION" --os "$VULTR_OS_ID" \
  --ssh-keys "$SSH_KEY_ID" --label "$LABEL" --host "$LABEL" \
  --userdata-file "$CI_FILE" \
  -o json)
INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.instance.id // empty')
[[ -n "$INSTANCE_ID" ]] || die "Instance create failed. Response: $INSTANCE_JSON"
ok "VM created: $INSTANCE_ID"
echo "  Destroy command (save it): vultr-cli instance delete $INSTANCE_ID"

# ---- 5. wait for IP + active --------------------------------------------
log "Waiting for VM to reach 'active' state ..."
PUB_IP=""
for i in $(seq 1 60); do
  STATUS_JSON=$(vultr-cli instance get "$INSTANCE_ID" -o json 2>/dev/null || echo '{}')
  STATUS=$(echo "$STATUS_JSON" | jq -r '.instance.status // "unknown"')
  PUB_IP=$(echo "$STATUS_JSON" | jq -r '.instance.main_ip // empty')
  if [[ "$STATUS" == "active" && -n "$PUB_IP" && "$PUB_IP" != "0.0.0.0" ]]; then
    ok "VM active: $PUB_IP"
    break
  fi
  if [[ $i -eq 60 ]]; then
    die "VM didn't reach 'active' in 5 min. status=$STATUS ip=$PUB_IP"
  fi
  sleep 5
done

# ---- 6. SSH alias --------------------------------------------------------
log "Ensuring SSH alias '$SSH_ALIAS' → $PUB_IP in ~/.ssh/config ..."
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
if grep -qE "^Host[[:space:]]+$SSH_ALIAS([[:space:]]|$)" "$SSH_CONFIG"; then
  warn "Alias '$SSH_ALIAS' already exists — leaving as-is. If wrong, edit ~/.ssh/config."
else
  IDENTITY_LINE=""
  if [[ -f "$SSH_IDENTITY_FILE" ]]; then
    IDENTITY_LINE="    IdentityFile $SSH_IDENTITY_FILE"
  else
    warn "SSH_IDENTITY_FILE=$SSH_IDENTITY_FILE not found — alias added WITHOUT IdentityFile. You'll need ssh-agent or to add it manually."
  fi
  cat >> "$SSH_CONFIG" <<EOF

# Added by provision-and-deploy.sh on $(date -u +%FT%TZ)
Host $SSH_ALIAS
    HostName $PUB_IP
    User root
    StrictHostKeyChecking accept-new
$IDENTITY_LINE
EOF
  ok "Added SSH alias $SSH_ALIAS (identity: ${SSH_IDENTITY_FILE})."
fi

# Vultr recycles IPs across instances. If an earlier VM had this IP, the host
# key in ~/.ssh/known_hosts won't match the new VM and StrictHostKeyChecking
# rejects the connection (even with 'accept-new'). Purge the stale entry so
# the next SSH attempt records the new key cleanly.
if ssh-keygen -F "$PUB_IP" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
  log "Purging stale known_hosts entry for $PUB_IP (likely recycled IP) ..."
  ssh-keygen -R "$PUB_IP" >/dev/null 2>&1 || true
fi

# ---- 7. wait for SSH -----------------------------------------------------
log "Waiting for sshd on $SSH_ALIAS (up to 5 min) ..."
for i in $(seq 1 60); do
  if /usr/bin/ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_ALIAS" "true" 2>/dev/null; then
    ok "SSH reachable."
    break
  fi
  if [[ $i -eq 60 ]]; then die "sshd not reachable after 5 min."; fi
  sleep 5
done

# ---- 8. wait for cloud-init sentinel ------------------------------------
log "Waiting for cloud-init bootstrap to complete (build is slow — up to 30 min) ..."
SENTINEL=/var/lib/cloud/dify-bootstrap-done
LAST_LOG=""
for i in $(seq 1 360); do
  if /usr/bin/ssh "$SSH_ALIAS" "test -f $SENTINEL" 2>/dev/null; then
    ok "Cloud-init complete after ${i}*5s."
    break
  fi
  if [[ $((i % 12)) -eq 0 ]]; then
    TAIL=$(/usr/bin/ssh "$SSH_ALIAS" "tail -1 /var/log/dify-cloud-init.log 2>/dev/null || echo 'waiting for log...'")
    if [[ "$TAIL" != "$LAST_LOG" ]]; then
      log "  [vm] $TAIL"
      LAST_LOG="$TAIL"
    fi
  fi
  if [[ $i -eq 360 ]]; then
    warn "Sentinel not found after 30 min. Inspect: /usr/bin/ssh $SSH_ALIAS 'tail -200 /var/log/dify-cloud-init.log'"
    die "Cloud-init timeout."
  fi
  sleep 5
done

# Smoke-test HTTP nginx (cert challenge endpoint must be reachable)
if /usr/bin/ssh "$SSH_ALIAS" "curl -fsS -m 3 http://localhost/.well-known/acme-challenge/ >/dev/null 2>&1"; then
  ok "ACME challenge endpoint reachable on :80."
else
  warn "ACME endpoint not responding cleanly yet. Containers may still be settling."
fi

# ---- 9. DNS gate ---------------------------------------------------------
if [[ "$SKIP_CERT" == "1" ]]; then
  ok "SKIP_CERT=1 — stopping before TLS issuance."
  echo "  Next step (manual):"
  echo "    1. Update DNS: $DOMAIN A $PUB_IP"
  echo "    2. Issue cert: /usr/bin/ssh $SSH_ALIAS 'cd /opt/dify/docker && docker compose -p dify --profile certbot run --rm certbot certonly --webroot --webroot-path=/var/www/html --email $CERTBOT_EMAIL --agree-tos --no-eff-email -d $DOMAIN'"
  echo "    3. Flip HTTPS: /usr/bin/ssh $SSH_ALIAS \"sed -i 's/^NGINX_HTTPS_ENABLED=.*/NGINX_HTTPS_ENABLED=true/' /opt/dify/docker/.env && cd /opt/dify/docker && docker compose -p dify up -d nginx\""
  exit 0
fi

echo
warn "DNS step (manual):"
echo "  Set A record:  $DOMAIN  →  $PUB_IP"
echo "  Verify:        dig +short $DOMAIN  (must return $PUB_IP)"
if [[ "$AUTO_DNS_WAIT" == "1" ]]; then
  log "AUTO_DNS_WAIT=1 — polling dig for up to 15 min ..."
  for i in $(seq 1 90); do
    RESOLVED=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -1)
    if [[ "$RESOLVED" == "$PUB_IP" ]]; then
      ok "DNS propagated: $DOMAIN → $PUB_IP"
      break
    fi
    sleep 10
    [[ $i -eq 90 ]] && die "DNS not propagated after 15 min. Resolved='$RESOLVED'. Try again later or rerun with SKIP_CERT=1."
  done
else
  read -rp "Press Enter when DNS is propagated (or Ctrl-C to abort) ... "
fi

# ---- 10. issue cert ------------------------------------------------------
log "Issuing Let's Encrypt cert via certbot --webroot ..."
/usr/bin/ssh "$SSH_ALIAS" "cd /opt/dify/docker && docker compose -p dify --profile certbot run --rm certbot \
  certonly --webroot --webroot-path=/var/www/html \
  --email $CERTBOT_EMAIL --agree-tos --no-eff-email -d $DOMAIN" \
  || die "Cert issuance failed. Check: /usr/bin/ssh $SSH_ALIAS 'docker compose -p dify --profile certbot logs certbot'"
ok "Cert issued."

# ---- 11. flip nginx to HTTPS --------------------------------------------
log "Flipping nginx to HTTPS ..."
/usr/bin/ssh "$SSH_ALIAS" "sed -i 's/^NGINX_HTTPS_ENABLED=.*/NGINX_HTTPS_ENABLED=true/' /opt/dify/docker/.env && \
  cd /opt/dify/docker && docker compose -p dify up -d --force-recreate --no-deps nginx"

# ---- 12. final health check ---------------------------------------------
log "Polling https://$DOMAIN/console/api/version ..."
for i in $(seq 1 30); do
  if curl -fkSs -m 5 "https://$DOMAIN/console/api/version" >/dev/null 2>&1; then
    ok "HTTPS healthy."
    break
  fi
  [[ $i -eq 30 ]] && warn "HTTPS not healthy after 2.5 min — check /usr/bin/ssh $SSH_ALIAS 'docker compose -p dify logs --tail=200 nginx api'"
  sleep 5
done

# ---- 13. summary ---------------------------------------------------------
echo
ok "Provision + deploy complete."
echo
echo "  VM id    : $INSTANCE_ID"
echo "  IP       : $PUB_IP"
echo "  SSH      : /usr/bin/ssh $SSH_ALIAS"
echo "  Console  : https://$DOMAIN/install   (first visit sets up admin)"
echo
echo "  Subsequent deploys (same VM, after pushing new commits):"
echo "    SSH_HOST=$SSH_ALIAS ./.claude/skills/vultr-single/scripts/remote-bootstrap.sh"
echo
echo "  Destroy VM (when done testing):"
echo "    vultr-cli instance delete $INSTANCE_ID"
echo
