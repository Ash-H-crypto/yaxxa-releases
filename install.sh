#!/usr/bin/env bash
# Installs Yaxxa Engagement Orchestrator on a new server (ADR-0009).
#
# Yaxxa gives you the command, with your install code in it:
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Ash-H-crypto/yaxxa-releases/main/install.sh)" \
#     install --code YX-XXXXX-XXXXX-XXXXX-XXXXX
#
# The only question is the first operator's email (or --email). The domain
# is optional (--domain): without one, the server gets a working address from
# its IP (203-0-113-10.sslip.io) that can be changed later. Everything else
# is worked out or generated here. Unattended:
#
#   … install --code YX-… --email ops@client.co.za --domain contact.client.co.za
#
# (--version X.Y.Z installs a particular release instead of the latest.)
#
# An install code is for one server. The first install binds it to this
# server; another server with the same code is refused. Yaxxa can release it
# for a replacement server.
#
# In order, stopping at the first thing that is not right:
#   1. checks the machine, and the install code with Yaxxa (which also says
#      what this server's public address is);
#   2. installs Docker (from Docker's own repository) if it is missing;
#   3. downloads the release, believing the manifest only if the key pinned
#      below signed it, and every image by the digest it names;
#   4. writes /opt/uceo/.env with a fresh, strong secret for everything;
#   5. starts everything, sets up sign-in, stores the licence;
#   6. creates the first platform operator with a one-time password;
#   7. installs updates, licence renewal, nightly media restart and backups;
#   8. opens the server's firewall (ufw) for the platform if it is on, and checks the
#      platform answers on its own address.
#
# Running it again on an installed server keeps its .env and secrets.
set -euo pipefail
umask 077

DIR=/opt/uceo
LICENCE_URL="${UCEO_LICENCE_URL:-https://orchestrator.yaxxa.co.za}"
LATEST_URL="${UCEO_RELEASE_MANIFEST_URL:-https://raw.githubusercontent.com/Ash-H-crypto/yaxxa-releases/main/latest.json}"
# The release signing key (Ed25519). A manifest this key did not sign is
# refused, whatever served it.
RELEASE_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAkGo2h3Py4stc9EBS3N2Z6QQUyDxpkEX20UtKtGq/Wck=
-----END PUBLIC KEY-----'

while [ $# -gt 0 ]; do
  case "$1" in
    install) ;;
    --code) UCEO_INSTALL_CODE="${2:-}"; shift ;;
    --email) UCEO_ADMIN_EMAIL="${2:-}"; shift ;;
    --domain) UCEO_DOMAIN="${2:-}"; shift ;;
    --version) UCEO_VERSION_WANTED="${2:-}"; shift ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
log() { echo "$(date '+%F %T') $*"; }
die() { echo; printf '\033[31mStopped: %s\033[0m\n' "$*" >&2; exit 1; }
ask() { # variable prompt
  local var="$1" prompt="$2" v="${!1:-}"
  if [ -z "$v" ]; then
    [ -t 0 ] || die "$prompt is needed (there is no terminal to ask)"
    read -r -p "$prompt: " v
  fi
  [ -n "$v" ] || die "$prompt is needed"
  printf -v "$var" '%s' "$v"
}
# Letters and digits only, so a secret is safe in a URL or a .env line.
secret() { openssl rand -hex "$(( ${1:-40} / 2 ))"; }

bold "Yaxxa Engagement Orchestrator — installer"
echo

# --- 1. The machine -----------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root (with sudo)"
. /etc/os-release 2>/dev/null || die "cannot tell which operating system this is"
# Debian 13 is what Yaxxa runs itself; Ubuntu LTS works the same way.
case "${ID:-}:${VERSION_ID:-}" in
  debian:13|ubuntu:22.04|ubuntu:24.04) ;;
  debian:*|ubuntu:*) echo "Note: tested on Debian 13 and Ubuntu 22.04/24.04; this is ${PRETTY_NAME:-unknown}." ;;
  *) die "this installer is for Debian 13 (recommended) or Ubuntu 22.04/24.04 (found ${PRETTY_NAME:-unknown})" ;;
esac
mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
cpus=$(nproc)
disk_gb=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
echo "This server: ${cpus} CPUs, ${mem_gb} GB memory, ${disk_gb} GB free disk."
[ "$mem_gb" -ge 7 ] || die "at least 8 GB of memory is needed (found ${mem_gb} GB)"
[ "$disk_gb" -ge 40 ] || die "at least 40 GB of free disk is needed (found ${disk_gb} GB)"
[ "$cpus" -ge 4 ] || echo "Note: 4 or more CPUs are recommended for calls; this server has ${cpus}."

for tool in curl openssl python3; do
  command -v "$tool" >/dev/null || { apt-get update -qq && apt-get install -y -qq "$tool" >/dev/null; }
done

ENV="$DIR/.env"
INSTALLED=0
if [ -f "$ENV" ]; then
  INSTALLED=1
  echo "Found an installation in $DIR: keeping its settings and secrets."
  # A new domain (PUBLIC_HOSTNAME changed by hand): every address that
  # follows from it moves too; sign-in is set up again below with it.
  host="$(grep -E '^PUBLIC_HOSTNAME=' "$ENV" | tail -1 | cut -d= -f2-)"
  sed -i -E \
    -e "s|^KEYCLOAK_HOSTNAME=.*|KEYCLOAK_HOSTNAME=https://$host/auth|" \
    -e "s|^OIDC_ISSUER_URL=.*|OIDC_ISSUER_URL=https://$host/auth/realms/uceo|" \
    -e "s|^CORS_ORIGINS=.*|CORS_ORIGINS=https://$host|" "$ENV"
  set -a; . "$ENV"; set +a
  UCEO_DOMAIN="$PUBLIC_HOSTNAME"
  UCEO_PUBLIC_IP="$VOICE_PUBLIC_IP"
  UCEO_ADMIN_EMAIL="${UCEO_ADMIN_EMAIL:-${PLATFORM_NOTIFY_EMAILS:-}}"
  UCEO_INSTALL_CODE="${UCEO_INSTALL_CODE:-}"
  LICENCE_URL="${UCEO_LICENCE_URL:-$LICENCE_URL}"
else
  # Ports the platform listens on. Something already on them would fail
  # halfway through, so say so now.
  busy=""
  for p in 80 443 5060 5432 8080 3000; do
    ss -ltnuH "sport = :$p" 2>/dev/null | grep -q . && busy="$busy $p"
  done
  [ -z "$busy" ] || die "these ports are already in use:$busy (another web server, SIP server or database?)"
fi
# This server's own identity, which the install code is bound to. Kept for
# ever once made, so reinstalling on the same server is not "another server".
mkdir -p /var/lib/uceo
[ -s /var/lib/uceo/server-id ] || python3 -c 'import uuid; print(uuid.uuid4())' > /var/lib/uceo/server-id
SERVER_ID="$(cat /var/lib/uceo/server-id)"

# --- The install code, and what Yaxxa says about it ---------------------------
ask UCEO_INSTALL_CODE "Install code (from Yaxxa)"
log "checking the install code with Yaxxa"
body=$(python3 -c 'import json,sys; print(json.dumps({"code": sys.argv[1], "serverId": sys.argv[2], "hostname": sys.argv[3], "credentials": True}))' \
  "$UCEO_INSTALL_CODE" "$SERVER_ID" "$(hostname -f 2>/dev/null || hostname)")
answer=$(curl -sS --max-time 30 -w '\n%{http_code}' -H 'content-type: application/json' -d "$body" \
  "${LICENCE_URL%/}/api/v1/licence/check") || die "could not reach Yaxxa at $LICENCE_URL: this server needs internet access to install"
http="${answer##*$'\n'}"; json="${answer%$'\n'*}"
reason=$(python3 -c 'import json,sys
try: print(json.loads(sys.argv[1])["error"]["message"])
except Exception: print("")' "$json")
[ "$http" != 404 ] || die "Yaxxa does not recognise that install code. Check it was copied in full."
[ "$http" != 409 ] || die "${reason:-this install code is already in use on another server}"
[ "$http" = 200 ] || die "Yaxxa could not check the install code ($http)${reason:+: $reason}"
mapfile -t L < <(python3 - "$json" <<'PY'
import json, sys
a = json.loads(sys.argv[1]); r = a.get("registry") or {}
for v in (a["status"], a.get("message") or "", a.get("yourIp") or "", r.get("user", ""), r.get("token", ""),
          a.get("channel") or "live", a.get("manifestUrl") or "", a.get("domain") or "", a.get("operatorEmail") or ""):
    print(v)
PY
)
L_STATUS="${L[0]:-}"; L_MESSAGE="${L[1]:-}"; L_IP="${L[2]:-}"; L_USER="${L[3]:-}"; L_TOKEN="${L[4]:-}"
# Which releases this server follows (staging: every release, installed by
# itself; live: what Yaxxa released to live), and, for a staging server, its
# address and operator: the command then asks nothing.
L_CHANNEL="${L[5]:-live}"; L_MANIFEST="${L[6]:-}"; L_DOMAIN="${L[7]:-}"; L_EMAIL="${L[8]:-}"
[ -z "$L_MANIFEST" ] || LATEST_URL="$L_MANIFEST"
UCEO_DOMAIN="${UCEO_DOMAIN:-$L_DOMAIN}"
UCEO_ADMIN_EMAIL="${UCEO_ADMIN_EMAIL:-$L_EMAIL}"
[ "$L_STATUS" = ACTIVE ] || die "this install code is ${L_STATUS,,}${L_MESSAGE:+: $L_MESSAGE}"
[ -n "$L_TOKEN" ] || die "Yaxxa sent no download credentials. Tell Yaxxa: the release registry is not set up."

if [ "$INSTALLED" = 0 ]; then
  # The address Yaxxa saw this server connect from is its public address.
  UCEO_PUBLIC_IP="${UCEO_PUBLIC_IP:-$L_IP}"
  [[ "$UCEO_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not tell this server's public IPv4 address; run again with UCEO_PUBLIC_IP=<address>"
  ask UCEO_ADMIN_EMAIL "Email of the first platform operator (you)"
  UCEO_ADMIN_EMAIL="${UCEO_ADMIN_EMAIL,,}"
  [[ "$UCEO_ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "\"$UCEO_ADMIN_EMAIL\" is not an email address"
  # No domain yet: a working address from the IP, changeable later.
  UCEO_DOMAIN="${UCEO_DOMAIN:-${UCEO_PUBLIC_IP//./-}.sslip.io}"
  UCEO_DOMAIN="${UCEO_DOMAIN,,}"
  [[ "$UCEO_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || die "\"$UCEO_DOMAIN\" is not a domain name"
  # Keycloak's own administration: from where this install is being run, and
  # the server itself. More networks can be added to .env later.
  ssh_ip="${SSH_CLIENT%% *}"
  # Space-separated, as the web proxy reads them (a comma is not a separator there).
  UCEO_ADMIN_CIDRS="${UCEO_ADMIN_CIDRS:-${ssh_ip:+$ssh_ip/32 }127.0.0.1/32}"
  UCEO_ADMIN_CIDRS="${UCEO_ADMIN_CIDRS//,/ }"
fi
echo "Installing for $UCEO_ADMIN_EMAIL at https://$UCEO_DOMAIN (this server: $UCEO_PUBLIC_IP)."

# The certificate is issued for the domain only if it points here.
# Not found yet (a new record, or a resolver still remembering it was not
# there) is said below, not a silent stop.
dns_ip=$(getent ahostsv4 "$UCEO_DOMAIN" | awk 'NR==1 {print $1}' || true)
[ "$dns_ip" = "$UCEO_PUBLIC_IP" ] || die "$UCEO_DOMAIN points to ${dns_ip:-nothing}, not to $UCEO_PUBLIC_IP. Add a DNS A record for it and run this again — or leave out --domain to start on ${UCEO_PUBLIC_IP//./-}.sslip.io."

# --- 2. Docker ----------------------------------------------------------------
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  # From Docker's own repository, as on Yaxxa's servers: the distributions'
  # packages lag behind and name the compose plugin differently.
  log "installing Docker"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc \
    || die "could not fetch Docker's signing key"
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null \
    || die "Docker could not be installed"
  systemctl enable --now docker >/dev/null
fi
docker info >/dev/null 2>&1 || die "Docker is installed but not running"

# --- 3. The release -----------------------------------------------------------
WORK=$(mktemp -d)
MANIFEST_URL="$LATEST_URL"
[ -z "${UCEO_VERSION_WANTED:-}" ] || MANIFEST_URL="${LATEST_URL%/*}/versions/$UCEO_VERSION_WANTED.json"
log "fetching the release"
curl -fsSL --max-time 30 "$MANIFEST_URL" -o "$WORK/manifest.json" || die "could not fetch the release manifest from $MANIFEST_URL"
printf '%s\n' "$RELEASE_KEY" > "$WORK/key.pem"
python3 - "$WORK" <<'PY' || die "the release manifest is malformed"
import json, sys, base64
w = sys.argv[1]
m = json.load(open(f"{w}/manifest.json"))
open(f"{w}/payload", "w").write(m["payload"])
open(f"{w}/sig", "wb").write(base64.b64decode(m["signature"]))
PY
openssl pkeyutl -verify -pubin -inkey "$WORK/key.pem" -rawin -in "$WORK/payload" -sigfile "$WORK/sig" >/dev/null 2>&1 \
  || die "the release manifest's signature is not valid — refusing it"
read -r VERSION PREFIX < <(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["version"], p["imagePrefix"])' "$WORK/payload")
log "release $VERSION, signed"

# Logged in only for the download: the token is never written to this server.
trap 'docker logout "${PREFIX%%/*}" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
printf '%s' "$L_TOKEN" | docker login "${PREFIX%%/*}" -u "$L_USER" --password-stdin >/dev/null 2>&1 \
  || die "the release registry refused Yaxxa's credentials. Tell Yaxxa."
python3 -c 'import json,sys; [print(k, v) for k, v in json.load(open(sys.argv[1]))["images"].items()]' "$WORK/payload" > "$WORK/images"
while read -r name digest; do
  log "downloading $name"
  docker pull -q "$PREFIX/$name@$digest" >/dev/null || die "could not download $name"
  docker tag "$PREFIX/$name@$digest" "$PREFIX/$name:$VERSION"
done < "$WORK/images"
docker logout "${PREFIX%%/*}" >/dev/null 2>&1 || true

mkdir -p "$DIR"
cid=$(docker create "$PREFIX/bundle:$VERSION" /none)
docker cp "$cid:/bundle/." "$WORK/bundle" >/dev/null && docker rm "$cid" >/dev/null
cp -a "$WORK/bundle/infrastructure" "$WORK/bundle/scripts" "$DIR/"
chmod 755 "$DIR" "$DIR"/scripts/*.sh "$DIR"/scripts/ops/*.sh 2>/dev/null || true

# --- 4. Settings and secrets --------------------------------------------------
if [ "$INSTALLED" = 0 ]; then
  log "writing $ENV with new secrets"
  pg=$(secret); app=$(secret); plat=$(secret); edge=$(secret)
  cat > "$ENV" <<EOF
# Written by the installer on $(date -u '+%F %T UTC'). Every secret here was
# generated on this server. Readable by root only; back it up with care.
NODE_ENV=production
SERVICE_NAME=uceo-api
API_HOST=127.0.0.1
API_PORT=3000
LOG_LEVEL=info
DEPLOYMENT_TOPOLOGY=single-node

PUBLIC_HOSTNAME=$UCEO_DOMAIN
ADMIN_ALLOWED_CIDRS="$UCEO_ADMIN_CIDRS"
VOICE_PUBLIC_IP=$UCEO_PUBLIC_IP
EDGE_PUBLIC_IP=$UCEO_PUBLIC_IP
# Call audio ports, both media nodes together (the firewall lets these in).
RTP_START_PORT=16384
RTP_END_PORT=32767

POSTGRES_DB=uceo
POSTGRES_USER=uceo
POSTGRES_PASSWORD=$pg
APP_DB_PASSWORD=$app
PLATFORM_DB_PASSWORD=$plat
EDGE_DB_PASSWORD=$edge
DATABASE_URL=postgres://uceo_app:$app@localhost:5432/uceo
DATABASE_PLATFORM_URL=postgres://uceo_platform:$plat@localhost:5432/uceo
DATABASE_MIGRATION_URL=postgres://uceo:$pg@localhost:5432/uceo
REDIS_URL=redis://localhost:6379
NATS_URL=nats://localhost:4222

S3_ENDPOINT=http://localhost:9000
S3_REGION=us-east-1
S3_BUCKET=uceo
S3_ACCESS_KEY_ID=uceo
S3_SECRET_ACCESS_KEY=$(secret)

KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=$(secret)
KEYCLOAK_DB_PASSWORD=$(secret)
KEYCLOAK_COMMAND=start
KEYCLOAK_HOSTNAME=https://$UCEO_DOMAIN/auth
KEYCLOAK_INTERNAL_URL=
OIDC_ISSUER_URL=https://$UCEO_DOMAIN/auth/realms/uceo
OIDC_AUDIENCE=uceo-api
OIDC_WEB_CLIENT_ID=uceo-web
CORS_ORIGINS=https://$UCEO_DOMAIN

ESL_HOST=127.0.0.1
ESL_PORT=8021
ESL_PASSWORD=$(secret)
# FREESWITCH_NODES: the compose files' default (both media nodes here). Not
# written: its semicolons would end the line when this file is read back.
OPENSIPS_MI=127.0.0.1:8888
INTEGRATION_SECRET_KEY=$(openssl rand -hex 32)

OTEL_ENABLED=false
READINESS_REQUIRED_DEPENDENCIES=postgres
READINESS_PROBE_TIMEOUT_MS=2000
DB_POOL_MAX=20
DB_PLATFORM_POOL_MAX=5

# Email from the platform (approvals, alerts): set later in the console.
NOTIFY_SMTP_URL=
NOTIFY_FROM=
PLATFORM_NOTIFY_EMAILS=$UCEO_ADMIN_EMAIL

# Sign in with Google / Microsoft: optional, see the operator guide.
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=

# Release and licence (ADR-0009): what runs here, where updates come from,
# and the install code this server renews its licence with.
UCEO_IMAGE_PREFIX=$PREFIX
UCEO_VERSION=$VERSION
UCEO_RELEASE_MANIFEST_URL=$LATEST_URL
UCEO_INSTALL_CODE=$UCEO_INSTALL_CODE
UCEO_LICENCE_URL=$LICENCE_URL
# staging: Yaxxa's staging server (a banner says so; every release installs itself).
UCEO_ENVIRONMENT=$([ "$L_CHANNEL" = staging ] && echo staging || echo production)
UCEO_AUTO_UPDATE=$([ "$L_CHANNEL" = staging ] && echo 1 || echo 0)
EOF
  chmod 600 "$ENV"
fi
set -a; . "$ENV"; set +a

# --- 5. Start ----------------------------------------------------------------
BASE=(docker compose -p uceo -f "$DIR/infrastructure/compose/docker-compose.yml" --env-file "$ENV")
# A server of a pair (ADR-0011) runs its database under Patroni: never start
# it without that layer, or the copy would run on its own.
HA_ENV="${UCEO_STATE_DIR:-/var/lib/uceo}/ha.env"
[ -f "$HA_ENV" ] && BASE=(docker compose -p uceo -f "$DIR/infrastructure/compose/docker-compose.yml" \
  -f "$DIR/infrastructure/compose/docker-compose.ha.yml" --env-file "$ENV" --env-file "$HA_ENV")
APP=(docker compose -p uceo-app -f "$DIR/infrastructure/compose/docker-compose.app.yml" --env-file "$ENV")

log "starting the core services (database, storage, sign-in, voice)"
"${BASE[@]}" up -d --no-build --wait >/dev/null 2>&1 || "${BASE[@]}" up -d --no-build \
  || die "the core services did not start: see '${BASE[*]} ps'"
if [ -x "$DIR/infrastructure/freeswitch/scripts/ensure-wss-cert.sh" ]; then
  "$DIR/infrastructure/freeswitch/scripts/ensure-wss-cert.sh" >/dev/null 2>&1 || true
fi

log "waiting for sign-in (Keycloak)"
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 http://127.0.0.1:8080/auth/realms/master >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS --max-time 3 http://127.0.0.1:8080/auth/realms/master >/dev/null 2>&1 || die "Keycloak did not start within five minutes"

kc() { # script [extra docker run flags...]
  local script="$1"; shift
  docker run --rm --network host \
    -e KEYCLOAK_URL=http://127.0.0.1:8080/auth -e KEYCLOAK_ADMIN -e KEYCLOAK_ADMIN_PASSWORD \
    -e PUBLIC_BASE_URL="https://$PUBLIC_HOSTNAME" -e OIDC_AUDIENCE \
    -e GOOGLE_CLIENT_ID -e GOOGLE_CLIENT_SECRET -e MICROSOFT_CLIENT_ID -e MICROSOFT_CLIENT_SECRET \
    "$@" "$UCEO_IMAGE_PREFIX/migrate:$UCEO_VERSION" node "keycloak/$script"
}
log "setting up sign-in"
kc provision-realm.mjs >/dev/null || die "sign-in could not be set up (provision-realm)"

log "starting the platform (migrations first)"
"${APP[@]}" up -d --no-build || die "the platform did not start: see '${APP[*]} ps' and '${APP[*]} logs migrate'"
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 http://127.0.0.1:3000/api/v1/health/ready >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS --max-time 3 http://127.0.0.1:3000/api/v1/health/ready >/dev/null 2>&1 \
  || die "the platform did not become ready within five minutes: see '${APP[*]} logs api'"

log "storing the licence"
"$DIR/scripts/uceo-licence.sh" >/dev/null || die "the licence could not be stored"

# --- 6. The first operator ---------------------------------------------------
OPERATOR_PASSWORD=""
if [ "$INSTALLED" = 0 ]; then
  log "creating the first platform operator"
  docker exec uceo-postgres-1 psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -v ON_ERROR_STOP=1 \
    -v email="$UCEO_ADMIN_EMAIL" \
    -c "INSERT INTO platform_admin_invites (email, invited_by) VALUES (:'email', 'installer') ON CONFLICT DO NOTHING" \
    >/dev/null || die "could not record the operator invitation"
  OPERATOR_PASSWORD="$(secret 16)"
  made=$(kc bootstrap-operator.mjs -e OPERATOR_EMAIL="$UCEO_ADMIN_EMAIL" -e OPERATOR_PASSWORD="$OPERATOR_PASSWORD") \
    || die "could not create the operator's sign-in"
  [ "$made" = created ] || OPERATOR_PASSWORD=""
fi

# --- 7. Keeping it running ----------------------------------------------------
log "installing updates, licence renewal, nightly media restart and backups"
cp "$DIR"/infrastructure/host/uceo-*.service "$DIR"/infrastructure/host/uceo-*.timer /etc/systemd/system/
systemctl daemon-reload
# One at a time: a unit a release does not have must not keep the others off.
for unit in uceo-update-agent.timer uceo-licence.timer uceo-host-agent.service; do
  [ -f "/etc/systemd/system/$unit" ] || continue
  systemctl enable --now "$unit" >/dev/null 2>&1 || echo "Note: $unit did not start; see 'systemctl status $unit'."
done
cat > /etc/cron.d/uceo <<EOF
# Yaxxa Engagement Orchestrator (installer). Times are the server's zone.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Media nodes, one at a time, never over a live call.
0 4 * * * root $DIR/scripts/fs-nightly-restart.sh >> /var/log/uceo-fs-restart.log 2>&1
# Database, storage and settings; the newest 7 are kept.
30 2 * * * root UCEO_ROOT=$DIR BACKUP_ROOT=/var/backups/uceo $DIR/scripts/ops/backup.sh >> /var/log/uceo-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/uceo

# --- 8. The firewall, and from the outside -------------------------------------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "opening the platform's ports in the firewall (ufw)"
  for rule in 80/tcp 443/tcp 5060/udp 5060/tcp 16384:32767/udp; do ufw allow "$rule" >/dev/null; done
fi
log "checking https://$PUBLIC_HOSTNAME"
ok=0
for _ in $(seq 1 24); do
  curl -fsS --max-time 5 "https://$PUBLIC_HOSTNAME/api/v1/health" >/dev/null 2>&1 && { ok=1; break; }
  sleep 5
done

echo
bold "Installed: release $UCEO_VERSION"
echo
echo "  Sign in:   https://$PUBLIC_HOSTNAME/"
echo "  Operator:  ${UCEO_ADMIN_EMAIL:-}"
if [ -n "$OPERATOR_PASSWORD" ]; then
  echo "  One-time password (shown once; you choose your own when you first sign in):"
  echo
  echo "      $OPERATOR_PASSWORD"
fi
echo
[ "$ok" = 1 ] || echo "  Note: https://$PUBLIC_HOSTNAME did not answer yet. The certificate can take a minute; if it persists, check ports 80 and 443 are open to the internet."
echo "  Settings:  $ENV (root only — keep a copy somewhere safe)"
echo "  Updates:   Platform → Updates in the console, or: sudo $DIR/scripts/uceo-update.sh"
echo
echo "  Behind a cloud firewall (AWS, Azure, Google…)? Open there: 80 and 443 TCP (web),"
echo "  5060 UDP/TCP (SIP from your carrier) and 16384-32767 UDP (call audio)."
case "$PUBLIC_HOSTNAME" in *.sslip.io)
  echo
  echo "  This address works now. To use your own domain later: point it at $UCEO_PUBLIC_IP,"
  echo "  change PUBLIC_HOSTNAME in $ENV, and run this installer again." ;;
esac
