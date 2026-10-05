#!/bin/sh
# Run as PID 1 by tini. Starts the upload server in the background, composes the session card for
# the login jail, then hands the terminal to the main command (claude). A client jail composes its
# own card (with the per-client env card prepended) in tools/client-jail-init.sh.
set -e

python3 /workspace/tools/upload/upload.py \
  --dir "${UPLOAD_DIR:-/workspace}" \
  --port 8000 \
  --host 0.0.0.0 \
  >/tmp/upload-server.log 2>&1 &

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
