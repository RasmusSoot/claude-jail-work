#!/usr/bin/env bash
# pin-aliases — review .aliases and pin a copy for the host shell. Host-side.
#
# The repo is writable from jail-main, and the host shell would otherwise source .aliases on every
# start. Instead ~/.zshrc sources a pinned COPY that only changes here, after you saw the diff:
#
#   [ -f ~/claude/jail/.aliases.pinned ] && source ~/claude/jail/.aliases.pinned
#   cmp -s ~/claude/claude-jail-work/.aliases ~/claude/jail/.aliases.pinned 2>/dev/null \
#     || print -u2 "⚠ jail .aliases differs from the pinned copy — review with: jail-pin"
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"
src="$HERE/.aliases"
pin="$JAIL_HOME/.aliases.pinned"

if [ -f "$pin" ] && cmp -s "$src" "$pin"; then
  echo "pinned copy is up to date ($pin)"
  exit 0
fi
snap=$(mktemp) && cp "$src" "$snap"                        # what is shown is what gets pinned: jail-main can edit $src during the prompt
trap 'rm -f "$snap"' EXIT
if [ -f "$pin" ]; then
  diff -u --label "pinned" --label "repo .aliases" "$pin" "$snap" | cat -v || true   # -v: an escape sequence cannot hide a line from the reviewer
else
  echo "no pinned copy yet — full file:"; cat -v "$snap"
fi
echo
read -r -p "Pin this for every new host shell? [y/N] " answer
case "$answer" in
  y|Y) install -m 644 "$snap" "$pin"; echo "pinned → $pin (new shells pick it up; current: source it)" ;;
  *)   echo "not pinned"; exit 1 ;;
esac
