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
# No git token below ever enters the jail: the launcher hands them to a sidecar that forwards git
# smart-HTTP only and accepts pushes only for FORK_ORG/<repo> and GITLAB_FORK_PATH.
# GitHub: fine-grained PAT, resource owner = your trust-domain org, All repositories,
#   Contents R/W + Metadata, NO Pull requests. Reaches only the forks.
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
