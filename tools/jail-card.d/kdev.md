- **kdev**: the CLIENT DEV cluster, read-only through a proxy that holds the token (no credential
  is in this jail): anything but GET, and any secrets, exec, attach, port-forward or proxy request,
  gets 403. `kdev auth can-i` does not work (it is a POST). Never merge its kubeconfig with kind's.
  Every `kdev` call prints its cluster banner — read it.
- **Two clusters means every claim names its cluster.** "Works" is not a finding; "works on kind,
  dev shows X" is.
