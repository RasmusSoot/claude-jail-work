#!/usr/bin/env bash
# stack-env — create a stack's env file from the template if it does not exist, print its path.
#
#   stack-env.sh <stack>
#
# $JAIL_HOME/.env.<stack> holds the stack's tokens and client FACTS. It is gitignored, mode 600, and
# never copied into any repo. Used by tools/stack-fork.sh and tools/stack-jail.sh; an existing file
# is never touched.
set -euo pipefail
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"
STACK="${1:-}"
[ -n "$STACK" ] || { echo "usage: stack-env.sh <stack>" >&2; exit 2; }
ENV_FILE="$JAIL_HOME/.env.$STACK"
if [ ! -f "$ENV_FILE" ]; then
  mkdir -p "$JAIL_HOME"
  ( umask 077; cat > "$ENV_FILE" <<EOT
# $STACK jail — tokens + client FACTS. Gitignored; never copy values into any repo.
# GitHub (gh, optional): the ONE token that enters the jail, so it must be harmless if leaked —
#   fine-grained PAT, resource owner = you, "Public repositories" only, NO permissions. It buys
#   the authenticated rate limit for gh reads; every write is refused by GitHub. The launcher
#   refuses it unless it is a fine-grained token that sees no private repository. Only for stacks
#   whose upstreams and forks are all public.
GH_PUBLIC_TOKEN=
# No git token below ever enters the jail: the launcher hands them to a sidecar that forwards git
# smart-HTTP only and accepts pushes only for FORK_ORG/<repo> and GITLAB_FORK_PATH.
# GitHub (git): fine-grained PAT, resource owner = your trust-domain org, All repositories,
#   Contents R/W + Metadata only — git needs nothing else and the sidecar exposes nothing else.
GH_TOKEN=
# Repo setup (tools/stack-fork.sh): upstream owner + the trust-domain org that holds the forks.
UPSTREAM_OWNER=
FORK_ORG=
# Client GitLab (optional). READ token: personal PAT with read_repository only.
# WRITE: a deploy token with write_repository on YOUR personal fork inside the client's GitLab.
GITLAB_HOST=
GITLAB_READ_TOKEN=
GITLAB_FORK_PATH=            # e.g. group/you/iac-fork  (the path the deploy token is scoped to)
GITLAB_DEPLOY_USER=
GITLAB_DEPLOY_TOKEN=
# Kind registry push credential (build sidecar only): the user/password the stack's registry (Zot,
#   anonymous pull) wants for pushes. Leave empty: tools/kind-stack.sh <stack> up generates both and
#   writes them here. Held by the build sidecar, never by the jail; worth only this stack's names.
REGISTRY_PUSH_USER=
REGISTRY_PUSH_PASSWORD=
# Client dev cluster (optional): HOST kubeconfig context + the read-only SA to mint from.
DEV_KUBE_CONTEXT=
DEV_KUBE_NS=
DEV_KUBE_SA=
DEV_KUBE_SERVER=             # optional: API URL as containers reach it, if not the context's
EOT
  )
  echo "→ created $ENV_FILE — fill it in (stack-fork needs UPSTREAM_OWNER + FORK_ORG)" >&2
fi
echo "$ENV_FILE"
