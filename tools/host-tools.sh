# shellcheck shell=bash
# host-tools — sourced (bash) by every HOST-side script in tools/ before it calls kubectl, kind or gh.
#
# The versions come from this repo's devbox.json, so the host does not depend on hand-installed
# binaries that go stale (a 2021 kubectl once broke token minting here) nor on a stack repo's devbox,
# which may not exist, may not be cleared for use, and is writable from inside a jail.
#
# PATH order: this profile goes first, always — ahead of the host's /usr/bin and ahead of any
# `devbox shell` the command runs in. (It used to yield to such a shell so an IaC repo could pin
# the cluster's exact kubectl; but a stack repo's devbox is jail-written, and a launcher run from
# that shell would mint with a kubectl the jail chose. Minting tolerates kubectl version skew.)
# Exact versions only; no init_hook is ever run from here. No fallback: without this profile the
# script stops, because "whatever kubectl is on PATH" is, from inside a stack repo's `devbox shell`,
# the jail's choice.
_ht_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_ht_bin="$_ht_here/.devbox/nix/profile/default/bin"
command -v devbox >/dev/null || { echo "✖ host-tools: devbox not found on the host — install it (https://www.jetify.com/devbox) and re-run" >&2; exit 2; }
devbox install --config "$_ht_here" --quiet >/dev/null 2>&1 \
  || echo "⚠ host-tools: devbox install failed in $_ht_here — using its last profile, if any" >&2
[ -d "$_ht_bin" ] || { echo "✖ host-tools: no devbox profile at $_ht_bin — run: devbox install --config $_ht_here" >&2; exit 2; }
export PATH="$_ht_bin:$PATH"
unset _ht_here _ht_bin

# Status lines for the host-side scripts, coloured when the stream is a terminal (NO_COLOR unsets
# it). Launch output flies by; the colour is what the eye catches, the glyph is what survives a
# paste:  ✔ green = a gate passed or a thing is up   · blue = not configured this session, by design
#         ⚠ yellow = degraded, continuing without X   ✖ red = refused or fatal
_ht_color() { [ -t "$1" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; }
if _ht_color 1; then _c_ok=$'\e[32m' _c_info=$'\e[34m' _c_off=$'\e[0m'; else _c_ok="" _c_info="" _c_off=""; fi
if _ht_color 2; then _c_warn=$'\e[33m' _c_fail=$'\e[31;1m' _c_off2=$'\e[0m'; else _c_warn="" _c_fail="" _c_off2=""; fi
ok()   { printf '%s✔%s %s\n' "$_c_ok" "$_c_off" "$*"; }
info() { printf '%s·%s %s\n' "$_c_info" "$_c_off" "$*"; }
warn() { printf '%s⚠ %s%s\n' "$_c_warn" "$*" "$_c_off2" >&2; }
fail() { printf '%s✖ %s%s\n' "$_c_fail" "$*" "$_c_off2" >&2; }
unset -f _ht_color

# The gitdir record (tools/stack-jail.sh, "Terms"): ~/claude/jail/.run-<stack>/gitdirs, one line per
# trusted gitdir, "<path relative to the stack home>\t<inode>". A gitdir absent at a launch is
# pruned; the inode tells a directory replaced by hand on the host from the one recorded (a session
# cannot replace one: in the jail the gitdir is a mountpoint).
# shellcheck disable=SC2012  # only the inode column is used, so an odd filename cannot mislead
gitdir_inode() { ls -di "$1" | awk '{print $1}'; }
record_has()  { [ -f "$1" ] && grep -qxF -- "$2"$'\t'"$3" "$1"; }                       # <record> <rel> <inode>
record_line() { [ -f "$1" ] && awk -F'\t' -v p="$2" '$1 == p { f = 1 } END { exit !f }' "$1"; }   # <record> <rel>: any inode
record_add()  { # <record> <rel> <inode>: replaces an older line for the same path
  local tmp; mkdir -p "$(dirname "$1")"; chmod 700 "$(dirname "$1")"
  tmp=$(mktemp "$(dirname "$1")/.gitdirs.XXXXXX") || return 1
  { [ ! -f "$1" ] || awk -F'\t' -v p="$2" '$1 != p' "$1"; printf '%s\t%s\n' "$2" "$3"; } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$1"
}
record_prune() { # <record> <stack home>: drop lines whose gitdir is gone — a path that comes back is a new gitdir, unrecorded
  local tmp rel ino; [ -f "$1" ] || return 0
  tmp=$(mktemp "$(dirname "$1")/.gitdirs.XXXXXX") || return 1
  while IFS=$'\t' read -r rel ino; do                     # gone = the parent is searchable and nothing is at the path; an unsearchable
    if [ -x "$2/${rel%/.git}" ] && [ ! -e "$2/$rel" ] && [ ! -L "$2/$rel" ]; then :; else printf '%s\t%s\n' "$rel" "$ino"; fi   # parent (a chmod by a session) keeps the line, and the scan refuses it
  done < "$1" > "$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$1"
}
