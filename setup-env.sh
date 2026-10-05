#!/usr/bin/env bash
# Host-side setup: writes .env (UID/GID, JAIL_HOME), pre-creates the bind-mounted state files
# (docker would otherwise create root-owned directories in their place), and generates
# docker-compose.override.yml with whichever zsh dotfiles exist on this host. Re-run after changes.
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
touch "$JAIL_HOME/.claude-data.zsh_history"
# .credentials.json must exist as a FILE before the single-file mount, or docker creates a dir.
[ -f "$JAIL_HOME/.claude-data/.credentials.json" ] || { echo '{}' > "$JAIL_HOME/.claude-data/.credentials.json"; chmod 600 "$JAIL_HOME/.claude-data/.credentials.json"; }
GITCONFIG="$JAIL_HOME/.claude-data.gitconfig"
[ -f "$GITCONFIG" ] || cat > "$GITCONFIG" <<'GITCFG'
# Jail git identity — fill in for commits made inside the jails. Separate from the host ~/.gitconfig.
# [user]
# 	name = Your Name
# 	email = you@example.com
GITCFG

OVERRIDE="$DIR/docker-compose.override.yml"
gen_service() { # <service> <history-file-or-empty>
  echo "  $1:"
  echo "    environment:"
  echo "      TZ: ${TZ:-Europe/Tallinn}"
  echo "      TERM: xterm-256color"
  echo "      COLORTERM: truecolor"
  echo "    volumes:"
  [ -f "$HOME/.zshrc" ]      && echo "      - $HOME/.zshrc:/home/node/.zshrc:ro"
  [ -d "$HOME/.oh-my-zsh" ]  && echo "      - $HOME/.oh-my-zsh:/home/node/.oh-my-zsh"
  [ -d "$HOME/.config/zsh" ] && echo "      - $HOME/.config/zsh:/home/node/.config/zsh"
  [ -f "$HOME/.p10k.zsh" ]   && echo "      - $HOME/.p10k.zsh:/home/node/.p10k.zsh:ro"
  [ -n "$2" ]                && echo "      - $2:/home/node/.zsh_history"
  true
}
{ echo "services:"; gen_service claude "$JAIL_HOME/.claude-data.zsh_history"; gen_service client ""; } > "$OVERRIDE"
echo ".env + docker-compose.override.yml written (UID=$(id -u), GID=$(id -g), JAIL_HOME=$JAIL_HOME)."
