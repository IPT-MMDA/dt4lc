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
