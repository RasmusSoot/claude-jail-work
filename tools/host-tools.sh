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
# Exact versions only; no init_hook is ever run from here.
_ht_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_ht_bin="$_ht_here/.devbox/nix/profile/default/bin"
if command -v devbox >/dev/null; then
  devbox install --config "$_ht_here" --quiet >/dev/null 2>&1 \
    || echo "⚠ host-tools: devbox install failed in $_ht_here — falling back to host PATH" >&2
else
  echo "⚠ host-tools: devbox not found — using host kubectl/kind/gh as-is" >&2
fi
[ ! -d "$_ht_bin" ] || export PATH="$_ht_bin:$PATH"
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
