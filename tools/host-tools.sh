# shellcheck shell=bash
# host-tools — sourced (bash) by every HOST-side script in tools/ before it calls kubectl, kind or gh.
#
# The versions come from this repo's devbox.json, so the host does not depend on hand-installed
# binaries that go stale (a 2021 kubectl once broke token minting here) nor on a stack repo's devbox,
# which may not exist, may not be cleared for use, and is writable from inside a jail.
#
# PATH order:
#   - inside a `devbox shell` of another repo (DEVBOX_SHELL_ENABLED set): that shell's pins win and
#     this profile only fills gaps — e.g. an IaC repo pinning the cluster's exact kubectl.
#   - otherwise this profile goes first, ahead of whatever the host has in /usr/bin.
# Exact versions only; no init_hook is ever run from here.
_ht_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_ht_bin="$_ht_here/.devbox/nix/profile/default/bin"
if command -v devbox >/dev/null; then
  devbox install --config "$_ht_here" --quiet >/dev/null 2>&1 \
    || echo "⚠ host-tools: devbox install failed in $_ht_here — falling back to host PATH" >&2
else
  echo "⚠ host-tools: devbox not found — using host kubectl/kind/gh as-is" >&2
fi
if [ -d "$_ht_bin" ]; then
  if [ -n "${DEVBOX_SHELL_ENABLED:-}" ]; then export PATH="$PATH:$_ht_bin"; else export PATH="$_ht_bin:$PATH"; fi
fi
unset _ht_here _ht_bin
