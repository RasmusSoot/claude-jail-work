#!/bin/sh
# Run as PID 1 by tini. Starts the upload server in the background, composes the session card for
# the login jail, then hands the terminal to the main command (claude). A client jail composes its
# own card (with the per-client env card prepended) in tools/client-jail-init.sh.
set -e

# Fresh token per container, handed to the server only (not exported to claude). The URL is printed
# here because only the terminal user should get it; UPLOAD_HOST_PORT is the loopback port on the host.
_upload_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')
UPLOAD_TOKEN="$_upload_token" python3 /workspace/tools/upload/upload.py \
  --dir "${UPLOAD_DIR:-/workspace/uploads}" \
  --port 8000 \
  --host 0.0.0.0 \
  >/tmp/upload-server.log 2>&1 &
echo "upload: http://127.0.0.1:${UPLOAD_HOST_PORT:-8000}/?t=$_upload_token" >&2
unset _upload_token

if [ -z "${CLIENT_NAME:-}" ]; then
  if [ -f /workspace/tools/jail-card.md ]; then
    { echo '<!-- composed at container start by tools/jail-entrypoint.sh from tools/jail-card.md — edit THAT file, not this one -->'
      cat /workspace/tools/jail-card.md
    } > /workspace/CLAUDE.local.md
  else
    echo "jail-entrypoint: tools/jail-card.md missing — this session has NO ground-rules card" >&2
  fi
fi

# Git credential store, container-local and rebuilt each start from the env; the helper is injected
# via GIT_CONFIG_* because /home/node/.gitconfig is a bind mount here (git config's rename would
# EBUSY). Keeps tokens out of remote URLs. Client jails build their own per-host store in init.
if [ -n "${GH_TOKEN:-}" ] && [ -z "${CLIENT_NAME:-}" ]; then
  ( umask 077; printf 'https://x-access-token:%s@github.com\n' "$GH_TOKEN" > /home/node/.git-credentials )
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=credential.helper
  export GIT_CONFIG_VALUE_0='store --file /home/node/.git-credentials'
fi

exec "$@"
