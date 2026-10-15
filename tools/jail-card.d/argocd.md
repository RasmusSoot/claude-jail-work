- **argocd**: the session card carries an 8h token for an account that can `get`, `sync` and read
  `logs` on this stack's Applications and nothing else — no app, repo, project or account writes;
  the API answers those with permission denied, which is the policy, not a bug. Applications track
  the chart in the stack registry (any version), so the loop is: change the chart,
  `build-image --chart`, `argocd app sync`. Self-heal is on: a `kubectl` edit in the namespace is
  reverted; put it in the chart. `helm install/upgrade` stay denied and are not needed. Platform
  add-ons are host-installed in project `platform`: the session sees them with
  `kubectl -n argocd get app` (not `argocd app list`, whose view is this stack's project) and
  cannot sync them.
