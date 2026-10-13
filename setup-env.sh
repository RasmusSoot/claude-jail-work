#!/usr/bin/env bash
# Host-side setup: writes .env (UID/GID, JAIL_HOME), pre-creates the bind-mounted state files
# (docker would otherwise create root-owned directories in their place). Re-run after changes.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"

set_env() {
  local key="$1" value="$2" file="$DIR/.env"
  touch "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then sed -i "s|^${key}=.*|${key}=${value}|" "$file"; else echo "${key}=${value}" >> "$file"; fi
}
set_env HOST_UID "$(id -u)"
set_env HOST_GID "$(id -g)"
set_env JAIL_HOME "$JAIL_HOME"

mkdir -p "$JAIL_HOME/.claude-data"
[ -f "$JAIL_HOME/.claude-data.json" ] || echo '{}' > "$JAIL_HOME/.claude-data.json"
# .credentials.json must exist as a FILE before the single-file mount, or docker creates a dir.
[ -f "$JAIL_HOME/.claude-data/.credentials.json" ] || { echo '{}' > "$JAIL_HOME/.claude-data/.credentials.json"; chmod 600 "$JAIL_HOME/.claude-data/.credentials.json"; }
GITCONFIG="$JAIL_HOME/.claude-data.gitconfig"
[ -f "$GITCONFIG" ] || cat > "$GITCONFIG" <<'GITCFG'
# Jail git identity — fill in for commits made inside the jails. Separate from the host ~/.gitconfig.
# [user]
# 	name = Your Name
# 	email = you@example.com
GITCFG

echo ".env written (UID=$(id -u), GID=$(id -g), JAIL_HOME=$JAIL_HOME)."
