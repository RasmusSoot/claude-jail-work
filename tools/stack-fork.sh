#!/usr/bin/env bash
# stack-fork — host-side repo setup for a stack: fork, clone, wire remotes.
#
#   stack-fork.sh <stack>
#
# For each repo in stacks/<stack>.conf REPOS, with FORK_ORG and UPSTREAM_OWNER from
# $JAIL_HOME/.env.<stack>:
#   1. fork UPSTREAM_OWNER/<repo> into FORK_ORG if missing (default branch only), and wait for it —
#      a fork into an org is created asynchronously;
#   2. clone the upstream into $JAIL_HOME/<stack>/<repo> if missing, remote named `upstream`;
#   3. make `upstream` fetch-only (push URL no_push://disabled);
#   4. add `origin` = the fork if missing, and fetch it.
#   5. record a clone it MADE in $JAIL_HOME/.run-<stack>/gitdirs (path + inode): the launcher
#      protects, trusts and reads remotes from RECORDED gitdirs only (tools/stack-jail.sh, "Terms").
#      A clone that already exists must be recorded already, or this script refuses to touch it
#      (its config would be run through git here first): inspect it, then
#      `stack-jail.sh <stack> --adopt <repo>/.git`. Submodules are not supported.
# Idempotent: re-run after adding a repo to REPOS. Existing branches and their tracking are left
# alone. A REPOS entry that is a plain directory without .git (a local-only stack home) is passed
# over. No rulesets or branch protection are set on the forks.
#
# Runs on the HOST with your own `gh` login (the jail's token cannot create repositories), and it is
# the only place remotes can change: inside a stack jail each repo's .git/config is read-only.
# Every git call into an existing clone is hardened, because the jail writes those working trees:
# GIT_DIR/GIT_COMMON_DIR are explicit (a planted .git/commondir is ignored) and fsmonitor and hooks
# are off.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/host-tools.sh
. "$HERE/tools/host-tools.sh"                        # gh pinned by this repo's devbox.json
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"
STACK="${1:-}"
[ -n "$STACK" ] || { echo "usage: stack-fork.sh <stack>" >&2; exit 2; }

CONF="$HERE/stacks/$STACK.conf"
ENV_FILE="$JAIL_HOME/.env.$STACK"
[ -f "$CONF" ] || { echo "FATAL: $CONF missing" >&2; exit 2; }
"$HERE/tools/stack-env.sh" "$STACK" >/dev/null || exit 2              # creates the template if missing
# shellcheck source=/dev/null
. "$CONF"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
: "${REPOS:?stacks/$STACK.conf must set REPOS}"
[ -n "${FORK_ORG:-}" ] && [ -n "${UPSTREAM_OWNER:-}" ] \
  || { echo "FATAL: set FORK_ORG and UPSTREAM_OWNER in $ENV_FILE" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "FATAL: gh is not logged in on this host (gh auth login)" >&2; exit 2; }

hgit() { # <worktree> <git args…> — hardened git for a jail-written clone
  local w="$1"; shift
  GIT_DIR="$w/.git" GIT_COMMON_DIR="$w/.git" GIT_WORK_TREE="$w" \
    git -c core.fsmonitor= -c core.hooksPath=/dev/null "$@"
}
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
RECORD="$JAIL_HOME/.run-$STACK/gitdirs"                # record_* come from host-tools.sh
LOCK="$JAIL_HOME/.run-$STACK/lock"                      # the launcher's: one actor per stack (a clone mid-launch would be mounted unprotected)
mkdir -p "$(dirname "$LOCK")"; chmod 700 "$(dirname "$LOCK")"
mkdir "$LOCK" 2>/dev/null || { echo "FATAL: $LOCK exists — a $STACK launch, session, --adopt or stack-fork.sh is running; one at a time (a crashed one left it? rmdir $LOCK)" >&2; exit 2; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

wait_for_fork() { # <owner/repo>: until the fork reports its default branch and that branch exists
  local repo="$1" db
  for _ in $(seq 1 60); do
    db=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null || true)
    if [ -n "$db" ] && gh api "repos/$repo/branches/$db" --silent 2>/dev/null; then
      echo "   fork ready: $repo ($db)"; return 0
    fi
    sleep 2
  done
  echo "   ✗ $repo still not ready after 120 s — re-run later" >&2; return 1
}

mkdir -p "$JAIL_HOME/$STACK"
failed=""
for r in $REPOS; do
  up="$UPSTREAM_OWNER/$r"; fork="$FORK_ORG/$r"; dir="$JAIL_HOME/$STACK/$r"
  echo "── $r"
  # A plain directory (no .git) is a local-only entry — a stack home holding CLAUDE.md, lab files —
  # not a clone to fork or wire. Leave it alone.
  if [ -d "$dir" ] && [ ! -e "$dir/.git" ]; then echo "   local-only dir, no .git — not a fork, left alone (a .git made here later needs stack-jail.sh $STACK --adopt $r/.git)"; continue; fi

  # 1. fork
  if parent=$(gh api "repos/$fork" --jq 'if .fork then .parent.full_name else "" end' 2>/dev/null); then
    if [ "$(lc "$parent")" != "$(lc "$up")" ]; then
      echo "   ✗ $fork exists but is ${parent:+a fork of $parent}${parent:-not a fork} — skipping" >&2
      failed="$failed $r"; continue
    fi
    echo "   fork exists: $fork"
  else
    echo "   forking $up → $FORK_ORG (default branch only)"
    # --remote is rejected when a repository argument is given; with --clone=false none is added anyway.
    gh repo fork "$up" --org "$FORK_ORG" --default-branch-only --clone=false >/dev/null \
      || { echo "   ✗ gh repo fork of $up failed — no such upstream? A local-only dir (a stack home like $r) is not forked: mkdir $dir" >&2; failed="$failed $r"; continue; }
    wait_for_fork "$fork" || { failed="$failed $r"; continue; }
  fi

  # 2. clone
  if [ ! -e "$dir" ]; then
    echo "   cloning $up → $dir"
    git -c core.hooksPath=/dev/null clone -q --origin upstream "https://github.com/$up.git" "$dir" \
      || { echo "   ✗ clone failed" >&2; failed="$failed $r"; continue; }
    record_add "$RECORD" "$r/.git" "$(gitdir_inode "$dir/.git")"; echo "   recorded $r/.git in $RECORD"
  elif [ ! -d "$dir/.git" ]; then
    echo "   ✗ $dir/.git is not a directory (worktree/submodule?) — skipping" >&2; failed="$failed $r"; continue
  elif [ -e "$dir/.git/modules" ]; then
    echo "   ✗ $dir/.git/modules exists — submodules are not supported; skipping" >&2; failed="$failed $r"; continue
  elif ! record_has "$RECORD" "$r/.git" "$(gitdir_inode "$dir/.git")"; then
    # Not a clone this script made, or deleted and recreated since: git must not run through its
    # config from here (fetch would honour remote.*.uploadpack, core.sshCommand, …) before the human has looked.
    echo "   ✗ $dir/.git is not recorded (or was recreated since): inspect its config and hooks, then: tools/stack-jail.sh $STACK --adopt $r/.git — skipping" >&2; failed="$failed $r"; continue
  fi
  cd_ok=$(cat "$dir/.git/commondir" 2>/dev/null || echo .)
  [ "$cd_ok" = "." ] || { echo "   ✗ $dir/.git/commondir points to '$cd_ok' — inspect before touching it" >&2; failed="$failed $r"; continue; }

  # 3. upstream fetch-only
  up_url=$(hgit "$dir" config --get remote.upstream.url) \
    || { echo "   ✗ no 'upstream' remote in $dir — skipping" >&2; failed="$failed $r"; continue; }
  case "$(lc "$up_url")" in
    *"github.com/$(lc "$up")"|*"github.com/$(lc "$up").git"|*"github.com:$(lc "$up").git") ;;
    *) echo "   ⚠ upstream is $up_url (expected $up) — left as is" >&2 ;;
  esac
  if [ "$(hgit "$dir" config --get remote.upstream.pushurl || true)" != "no_push://disabled" ]; then
    hgit "$dir" remote set-url --push upstream no_push://disabled
    echo "   upstream: push disabled"
  fi

  # 4. origin = fork. An existing origin may use any URL shape (https, scp-style ssh, ssh://): the
  # host pushes with its own keys or helpers, and the jail rewrites every shape to its sidecar.
  want="https://github.com/$fork.git"
  if have=$(hgit "$dir" config --get remote.origin.url); then
    # Anchored: the host must really be github.com (not a path or a look-alike), any scheme/user/port.
    if ! printf '%s' "$(lc "$have")" | grep -qE "^(https?://([^@/]+@)?|ssh://([^@/]+@)?|[^@/]+@)github\.com(:[0-9]+)?[:/]$(lc "$fork")(\.git)?/?$"; then
      echo "   ⚠ origin is $have (expected $fork on github.com) — left as is" >&2
    fi
  else
    hgit "$dir" remote add origin "$want"
    echo "   origin: $want"
  fi
  if hgit "$dir" fetch -q origin; then echo "   fetched origin"; else echo "   ✗ fetch origin failed" >&2; failed="$failed $r"; fi
done

[ -z "$failed" ] || { echo "✗ not done:$failed" >&2; exit 1; }
echo "✓ $STACK: all repos forked, cloned and wired (upstream fetch-only, origin = $FORK_ORG)"
