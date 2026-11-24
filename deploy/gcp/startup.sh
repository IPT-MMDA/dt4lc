#!/bin/bash
# First-boot provisioning of the DT4LC demo host (runs as root; a marker makes later boots a no-op):
# Docker Engine with the Compose v2 plugin, Caddy, the repository at the requested ref, and a .env
# with every non-secret value of docs/DEPLOY_DEMO.md section 2. Secrets are added by a person.
# On Google Cloud it is the VM's startup script and reads the instance attributes. On a plain Debian
# or Ubuntu host it is fed over SSH with its inputs in the environment (deploy/gcp/README.md):
#   ssh <user>@<host address> "sudo DT4LC_DOMAIN=... DT4LC_REF=... bash -s" < deploy/gcp/startup.sh
# DT4LC_GEE_PROJECT names the Earth Engine project, used there with a service account's key file;
# DT4LC_DEPLOY_KEY, a public key line, creates the account that .github/workflows/deploy.yml uses.
set -euo pipefail
MARK=/var/lib/dt4lc/provisioned
[ -f "$MARK" ] && exit 0
# Each input: the environment variable, else the instance attribute when this is a Google Cloud VM
# (its metadata server answers with its own header; probed once and briefly), else the default.
MD=http://metadata.google.internal/computeMetadata/v1
GCE=false
probe=$(curl -s -m 3 -o /dev/null -D - -H 'Metadata-Flavor: Google' "$MD/" || true)
[[ ${probe,,} == *'metadata-flavor: google'* ]] && GCE=true
md() { $GCE && curl -sf -H 'Metadata-Flavor: Google' "$MD/$1"; }   # md <path>: the value, or fail
DOMAIN=${DT4LC_DOMAIN:-$(md instance/attributes/dt4lc-domain || echo dt4lc.org)}
REF=${DT4LC_REF:-$(md instance/attributes/dt4lc-ref || echo v0.6.2)}
# Image tag: DT4LC_IMAGE_TAG or the dt4lc-image-tag attribute, else derived from the ref as the image
# build tags it: v0.6.2 -> 0.6.2, master -> latest, another branch -> its name with / as - (dev -> dev).
image_tag() {
  case "$1" in
    v[0-9]*) echo "${1#v}" ;;
    master) echo latest ;;
    *) echo "${1//\//-}" ;;
  esac
}
# The Caddyfile for the domain, from the template. The www redirect only for an apex domain (two
# labels): a subdomain such as dev.dt4lc.org has no www record, and Caddy would keep asking for a
# certificate it cannot get.
caddyfile() {  # caddyfile <domain> <template>
  case "$1" in
    *.*.*) sed -e '/^www\.dt4lc\.org {/,/^}/d' -e "s/dt4lc\.org/$1/g" "$2" ;;
    *) sed "s/dt4lc\.org/$1/g" "$2" ;;
  esac
}
# deploy_key_ok <line>: one public key line with no options of its own (the account's line adds
# them). A second line would be a second key, without the restrictions.
deploy_key_ok() {
  local shape='^(ssh|ecdsa|sk)-[a-z0-9@.-]+ [A-Za-z0-9+/]+=*( .*)?$'
  [[ $1 != *[[:cntrl:]]* && $1 =~ $shape ]] && ssh-keygen -lf - <<<"$1" >/dev/null 2>&1
}
if [ -n "${DT4LC_DEPLOY_KEY:-}" ] && ! deploy_key_ok "$DT4LC_DEPLOY_KEY"; then
  echo "dt4lc: DT4LC_DEPLOY_KEY must be one public key line, as in the .pub file of ssh-keygen" >&2
  exit 1
fi
TAG=${DT4LC_IMAGE_TAG:-$(md instance/attributes/dt4lc-image-tag || true)}
[ -n "$TAG" ] || TAG=$(image_tag "$REF")
# Earth Engine. On Google Cloud: this project, as the VM's service account (no key file). Elsewhere,
# with DT4LC_GEE_PROJECT: that project, as a service account whose key a person copies to
# /opt/dt4lc/resources/key_gee.json (resources/ is /app/resources in the backend container).
GEE_PROJECT='' GEE_CREDENTIALS=''
if $GCE; then
  GEE_PROJECT=$(md project/project-id)
  GEE_CREDENTIALS=GEE_USE_DEFAULT_CREDENTIALS=true
elif [ -n "${DT4LC_GEE_PROJECT:-}" ]; then
  GEE_PROJECT=$DT4LC_GEE_PROJECT
  GEE_CREDENTIALS=GEE_SERVICE_ACCOUNT_KEY=/app/resources/key_gee.json
fi
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -y -q ca-certificates curl git gnupg openssl python3
install -m 0755 -d /etc/apt/keyrings
# Docker's repository for this distribution (debian or ubuntu): their own docker.io package has no
# Compose plugin.
DISTRO=$(. /etc/os-release && echo "$ID")
curl -fsSL "https://download.docker.com/linux/$DISTRO/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DISTRO $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
# Caddy's repository (the same line for Debian and Ubuntu).
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin caddy
systemctl enable --now docker

[ -d /opt/dt4lc/.git ] || git clone -q https://github.com/IPT-MMDA/dt4lc.git /opt/dt4lc
git -C /opt/dt4lc fetch -q --tags
git -C /opt/dt4lc checkout -q "$REF"

caddyfile "$DOMAIN" /opt/dt4lc/deploy/gcp/Caddyfile > /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy

# .env: the template, then the demo values set in place by configure.sh (never a second copy).
ENV=/opt/dt4lc/.env
if [ ! -f "$ENV" ]; then
  cp /opt/dt4lc/.env.example "$ENV"
  chmod 600 "$ENV"
  # Published images (docker-compose.ghcr.yml); drop that file from COMPOSE_FILE to build from source.
  # Earth Engine as chosen above; an empty value is skipped.
  DT4LC_ENV="$ENV" bash /opt/dt4lc/deploy/gcp/configure.sh <<PAIRS
COMPOSE_FILE=docker-compose.yml:docker-compose.demo.yml:docker-compose.ghcr.yml
DT4LC_IMAGE_TAG=$TAG
COMPOSE_PROFILES=demo
SESSION_SECRET=$(openssl rand -hex 32)
SESSION_COOKIE_SECURE=true
GUEST_ANALYSES_PER_HOUR=5
GUEST_SESSION_HOURS=24
GUEST_CLEANUP_MINUTES=60
OAUTH_REDIRECT_BASE=https://$DOMAIN
FRONTEND_PORT=127.0.0.1:8080
LLM_ENABLE_OLLAMA=false
GEE_PROJECT_ID=$GEE_PROJECT
$GEE_CREDENTIALS
PAIRS
  cat >> "$ENV" <<'NOTE'

# ---- fill in before deploy/gcp/finish.sh (docs/DEPLOY_DEMO.md sections 2 and 5) ----
# GITHUB_CLIENT_ID=            GITHUB_CLIENT_SECRET=         (the OAuth app; callback https://<domain>/v1/auth/github/callback)
# OPERATOR_EMAILS=             ALLOWED_EMAILS=               (primary verified GitHub emails, comma-separated)
# LLM_PROVIDER_ORDER=gemini    GEMINI_API_KEY=               (any provider you have a key for)
NOTE
fi
mkdir -p /opt/dt4lc/resources/.cache

# The deploy account, only with DT4LC_DEPLOY_KEY: deploy.yml reaches a host outside Google Cloud over
# SSH. The key's line forces one command whatever the client asks: sudo runs a root-owned copy of
# deploy/gcp/ssh-deploy.sh, which deploys a release, master or dev and refuses anything else, and
# the key opens no shell and forwards nothing. The copy is this script's own, because the checkout
# may be a release older than the program; tests/test_release_workflow.py keeps the two identical.
if [ -n "${DT4LC_DEPLOY_KEY:-}" ]; then
  id -u dt4lc-deploy >/dev/null 2>&1 \
    || useradd --system --create-home --home-dir /home/dt4lc-deploy --shell /bin/sh dt4lc-deploy
  install -d -m 700 -o dt4lc-deploy -g dt4lc-deploy /home/dt4lc-deploy/.ssh
  printf 'restrict,command="/usr/bin/sudo -n /usr/local/sbin/dt4lc-deploy" %s\n' "$DT4LC_DEPLOY_KEY" \
    | install -m 600 -o dt4lc-deploy -g dt4lc-deploy /dev/stdin /home/dt4lc-deploy/.ssh/authorized_keys
  install -m 755 -o root -g root /dev/stdin /usr/local/sbin/dt4lc-deploy <<'PROGRAM'
#!/usr/bin/env bash
# The only command of the deploy account on a host outside Google Cloud. startup.sh installs this
# file as /usr/local/sbin/dt4lc-deploy (root, 755) when it is given DT4LC_DEPLOY_KEY, and that key's
# line in the account's authorized_keys forces `sudo -n /usr/local/sbin/dt4lc-deploy` whatever the
# client asks to run. .github/workflows/deploy.yml connects with
#   ssh dt4lc-deploy@<host address> <ref> <tag>     (the environment's NAME=VALUE lines on stdin)
# Why: that key is stored in GitHub, so whoever holds it may deploy a release, master or dev, and do
# nothing else. The client's words (SSH_ORIGINAL_COMMAND, which sudo keeps for this program alone)
# must match the shapes deploy.yml accepts, as a whole; they never reach a shell, and anything else
# is refused. The key opens no shell and forwards nothing (restrict). The steps are those of the
# Google Cloud path: the checkout moves to the ref, then that ref's configure.sh writes the values
# into .env and its update.sh moves the stack to the images.
set -euo pipefail
export LC_ALL=C   # the client may send LANG and LC_*; the ranges below must mean ASCII
ref='v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?|master|dev'
tag='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?|latest|dev'
words=${SSH_ORIGINAL_COMMAND:-}
shape="^($ref) ($tag)\$"
if ! [[ $words =~ $shape ]]; then
  echo "dt4lc-deploy: refused; expected '<ref> <tag>': a release tag, master or dev, and its image tag" >&2
  exit 1
fi
REF=${words% *}
TAG=${words#* }
cd /opt/dt4lc
git fetch -q --tags origin
case "$REF" in
  master | dev) git checkout -q --detach "origin/$REF" ;;
  *) git checkout -q --detach "$REF" ;;
esac
deploy/gcp/configure.sh
exec deploy/gcp/update.sh "$REF" "$TAG"
PROGRAM
  sudoers=$(mktemp)
  cat > "$sudoers" <<'SUDOERS'
# The deploy account may run its one program as root, with no arguments; the words its client sent
# reach the program in SSH_ORIGINAL_COMMAND (deploy/gcp/startup.sh, deploy/gcp/ssh-deploy.sh).
Defaults!/usr/local/sbin/dt4lc-deploy env_keep += "SSH_ORIGINAL_COMMAND"
dt4lc-deploy ALL=(root) NOPASSWD: /usr/local/sbin/dt4lc-deploy ""
SUDOERS
  visudo -cqf "$sudoers"
  install -m 440 -o root -g root "$sudoers" /etc/sudoers.d/dt4lc-deploy
  rm -f "$sudoers"
  echo "dt4lc: the deploy account dt4lc-deploy accepts $(ssh-keygen -lf - <<<"$DT4LC_DEPLOY_KEY")"
fi

mkdir -p "$(dirname "$MARK")" && date -u +%FT%TZ > "$MARK"
if [[ $GEE_CREDENTIALS == GEE_SERVICE_ACCOUNT_KEY=* ]]; then
  echo "dt4lc: copy the Earth Engine service account's key to /opt/dt4lc/resources/key_gee.json (root, mode 600)"
fi
echo "dt4lc: provisioned for $DOMAIN at $REF; complete /opt/dt4lc/.env and run deploy/gcp/finish.sh"
