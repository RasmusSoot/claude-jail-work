# Cluster add-ons

An add-on is something a stack's kind cluster needs that the jail cannot install: it brings
cluster-scoped objects (CRDs, ClusterRoles, admission webhooks), and the jail's ServiceAccount is
admin in one namespace only. The host installs it; the cluster's Argo CD keeps it in sync.

Each file here, `<name>.yaml`, is one Argo CD `Application`. A stack opts in with
`KIND_ADDONS="<name> …"` in `stacks/<stack>.conf`; `tools/kind-stack.sh <stack> up` checks every
listed file, applies the AppProject `platform` built from them (only their chart repos, only their
namespaces, every cluster-scoped kind) and then the files. `kind-stack.sh <stack> addons-render`
prints that project. Removing a name from the conf does not uninstall anything.

Rules, enforced by `kind-stack.sh` where they can be:

- **Public chart repo only**, over `https://`: never the stack registry, which the jail pushes to
  (a jail-pushed chart in this project would be cluster-admin).
- **Pinned version**: an exact chart version in `targetRevision`, bumped by hand.
- **Its own namespace** (`CreateNamespace=true`): not `argocd`, not the stack namespace, not a
  `kube-*` or `default` one.
- **`metadata.name` = the file name, `metadata.namespace: argocd`, `project: platform`**, one
  document, one `spec.source`, block-style YAML. Values go inline in the Application.
- **No client fact.** Like the confs, these files are generic.
- **The host applies them, the jail cannot.** They live in this repo, never in a stack's tree, and
  nothing in a jail is granted on project `platform`: a session can see the apps and cannot sync
  them.

| Add-on | What a stack gets |
|---|---|
| `kube-prometheus-stack` | Prometheus selecting ServiceMonitors, PodMonitors, PrometheusRules and Probes from every namespace (a chart ships a ServiceMonitor to get scraped), kube-state-metrics, Grafana (anonymous Viewer for the stack's pods; admin via `kind-stack.sh <stack> grafana`) |
