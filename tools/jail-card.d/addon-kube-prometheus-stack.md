- **monitoring (add-on kube-prometheus-stack)**: a ServiceMonitor in the stack's chart is how an
  app gets scraped; Prometheus and Grafana's dashboard sidecar pick up objects from every
  namespace. The CRDs exist only on stacks with this add-on, and a chart that ships one without
  them fails its whole sync, so guard the template with
  `.Capabilities.APIVersions.Has "monitoring.coreos.com/v1"`.
  To see what Prometheus and Grafana made of it, run a throwaway curl pod in the stack namespace,
  commands on stdin (that survives `devbox run` quoting and keeps the pod alive until kubectl
  attaches; without the sleep the output is empty):
  `printf '%s\n' 'sleep 3' "curl -s 'http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/targets?state=active'" | kubectl -n <stack> run prom-check --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -s`.
  Prometheus: `/api/v1/rules?type=alert` for rules, `/api/v1/query` with `-G --data-urlencode`
  for PromQL. Grafana answers anonymous Viewer requests on
  `http://kube-prometheus-stack-grafana.monitoring`: `/api/search?type=dash-db` lists the loaded
  dashboards, `/api/dashboards/uid/<uid>` reads one. kubectl appends a `pod "..." deleted` line;
  strip it before `jq`. This is the sanctioned route: both are open to the stack's pods by design
  and Argo ignores the pod. There is deliberately no proxy grant into `monitoring` (the kind gate
  refuses any `*/proxy` outside the stack namespace), no NodePort for either (it would expose every
  stack's metrics on the shared kind network) and no Grafana admin login in the jail; do not ask
  for them.
