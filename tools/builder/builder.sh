#!/usr/bin/env bash
# jail-builder — the build sidecar's loop. Runs INSIDE the Paketo builder image (tools/builder/
# Dockerfile), started by tools/stack-jail.sh into the jail's network namespace. The jail side is
# tools/build-image. No daemon, no socket: this is `pack build` with the container already running.
#
# Protocol, over the shared build directory (/build here, /workspace/build in the jail):
#   /build/<id>/app/            the application directory (an exploded Spring Boot jar)
#   /build/<id>/chart.tgz       optional, a packaged Helm chart to push after the image
#   /build/<id>/request.env     IMAGE=<name>:<tag>  CHART=<chart name>  BP_*=…  (one KEY=value per line)
#   /build/<id>/request         marker: the request is complete, build it
#   /build/<id>/log             appended while building (the one file written while reading the request;
#                               the request itself is read from a tmpfs copy, see build_one)
#   /build/<id>/result.env      STATUS=ok|failed  IMAGE=<ref>  IMAGE_DIGEST=…  CHART=…  CHART_DIGEST=…
# Policy, for any caller: <name> and <chart name> must be in BUILD_NAMES; every push goes to
# BUILD_REGISTRY; the registry credential (REGISTRY_PUSH_USER/PASSWORD, if any) is read once here
# and never written anywhere the jail can read. Requests are built one at a time, oldest first.
set -euo pipefail

BUILD="${BUILD_ROOT:-/build}"; CNB="${CNB_ROOT:-/cnb}"; REQ_TMP="${REQ_TMP_DIR:-/tmp}"   # overridable for tests only
# The app and layers directories are pack's fixed /workspace and /layers, not paths under the
# request dir: a CNB layer tar carries its absolute path, so the exported image and the cache image
# both bake the layers dir in. Per-request paths meant the running image had its layers under
# /build/<id>/ and every cache restore was skipped as "path escapes destination root". Both dirs
# are bind mounts the launcher owns (host-only, under ~/claude/jail/.run-<stack>/builder/), cleared
# before each build like pack's fresh volumes; builds are serialized, so one of each is enough.
WORK="${WORK_DIR:-/workspace}"; LAYERS="${LAYERS_DIR:-/layers}"
REGISTRY="${BUILD_REGISTRY:?BUILD_REGISTRY unset}"
NAMES=" ${BUILD_NAMES:?BUILD_NAMES unset} "
log() { echo "jail-builder: $*"; }
allowed() { case "$NAMES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# helm: everything it writes goes to tmpfs; its registry config is a docker-style auth file
mkdir -p /tmp/helm/cache /tmp/helm/config /tmp/helm/data
export HELM_CACHE_HOME=/tmp/helm/cache HELM_CONFIG_HOME=/tmp/helm/config HELM_DATA_HOME=/tmp/helm/data
export HELM_REGISTRY_CONFIG=/tmp/helm/registry.json
auth=no
if [ -n "${REGISTRY_PUSH_USER:-}" ]; then
  b64=$(printf '%s:%s' "$REGISTRY_PUSH_USER" "${REGISTRY_PUSH_PASSWORD:-}" | base64 | tr -d '\n')
  export CNB_REGISTRY_AUTH="{\"$REGISTRY\":\"Basic $b64\"}"              # the lifecycle's auth input
  ( umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$REGISTRY" "$b64" > "$HELM_REGISTRY_CONFIG" )
  unset b64; auth=yes
else
  printf '{"auths":{}}\n' > "$HELM_REGISTRY_CONFIG"
fi
unset REGISTRY_PUSH_USER REGISTRY_PUSH_PASSWORD
export CNB_INSECURE_REGISTRIES="${REGISTRY%%/*}"                      # the kind registry is plain HTTP

# The run image: the builder's own run.toml (platform API 0.12+), or BUILDER_RUN_IMAGE.
RUN_IMAGE="${BUILDER_RUN_IMAGE:-$(sed -n 's/^ *image *= *"\([^"]*\)".*/\1/p' "$CNB/run.toml" 2>/dev/null | head -1)}"
[ -n "$RUN_IMAGE" ] || { log "FATAL: no run image — $CNB/run.toml has none and BUILDER_RUN_IMAGE is unset"; exit 2; }
[ -x "$CNB/lifecycle/creator" ] || { log "FATAL: $CNB/lifecycle/creator missing — BUILDER_IMAGE is not a CNB builder"; exit 2; }
for d in "$WORK" "$LAYERS"; do [ -d "$d" ] && [ -w "$d" ] || { log "FATAL: $d is not a writable directory — the launcher mounts it"; exit 2; }; done
# The lifecycle needs the platform API version it should speak (pack sets it): the highest one the
# builder's lifecycle descriptor supports, or BUILDER_PLATFORM_API. 0.12+ is assumed above (run.toml).
if [ -z "${BUILDER_PLATFORM_API:-}" ]; then
  BUILDER_PLATFORM_API=$(awk '/^[[:space:]]*\[apis\.platform\]/{f=1;next} /^[[:space:]]*\[/{f=0} f && /supported/' "$CNB/lifecycle/lifecycle.toml" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+' | sort -t. -k1,1n -k2,2n | tail -1) || true
fi
if [ -z "$BUILDER_PLATFORM_API" ]; then
  # shellcheck disable=SC2012  # a diagnostic listing, not parsed
  log "$CNB/lifecycle contains: $(ls "$CNB/lifecycle" 2>&1 | tr '\n' ' ')"
  log "descriptor head: $(head -c 400 "$CNB/lifecycle/lifecycle.toml" 2>&1 | tr '\n' ' ')"
  log "FATAL: cannot read the platform API from $CNB/lifecycle/lifecycle.toml — the launcher passes it from the image label; set BUILDER_PLATFORM_API in the conf to force one"; exit 2
fi
export CNB_PLATFORM_API="$BUILDER_PLATFORM_API"
# The lifecycle chowns layers, app and cache dirs to CNB_USER_ID/CNB_GROUP_ID (the builder's own
# cnb ids) before detect, and with every capability dropped that chown cannot succeed. This runs as
# the host user so the bind-mounted build dir is writable; point the lifecycle at that user and the
# check is a no-op. Parity cost: exported layers carry this uid, not cnb's, so the run image's
# process (cnb) owns none of its files — they stay readable (0644/0755), and the app cannot write
# into its own layers, which a pack build forbids by convention anyway.
export CNB_USER_ID; CNB_USER_ID="$(id -u)"
export CNB_GROUP_ID; CNB_GROUP_ID="$(id -g)"

result() { # <dir> KEY=value… — written whole, then renamed: the jail never sees a partial file
  local d="$1"; shift
  printf '%s\n' "$@" > "$d/result.env.tmp" && mv "$d/result.env.tmp" "$d/result.env"
}

build_one() { # <request dir>
  local d="$1" t bad
  t="$REQ_TMP/req-$(basename "$d")"
  # The request is copied into this sidecar's own tmpfs first, links kept as links (-RP), and the
  # COPY is checked and built from. A check on the shared dir would be check-then-use: the jail
  # sees `started` and can swap `app` or `request.env` for a symlink to /tmp/helm/registry.json
  # between the check and the cp/read, and the credential would land in the build dir or the log.
  # A FIFO would hang the read. Only `log` (streamed to the jail) and `result.env` go back.
  rm -rf "$t"
  if ! cp -RP "$d" "$t" 2>>"$d/log"; then echo "refused: could not copy the request" >> "$d/log"; result "$d" STATUS=failed; rm -rf "$t"; return; fi
  bad=$(find "$t" ! -type f ! -type d -print -quit 2>/dev/null)
  if [ -n "$bad" ]; then
    echo "refused: the request contains a symlink or special file ($d${bad#"$t"})" >> "$d/log"; result "$d" STATUS=failed; rm -rf "$t"; return
  fi
  build_copy "$d" "$t" || log "$(basename "$d"): unexpected error (see its log)"
  rm -rf "$t"
}

build_copy() { # <request dir: log and result go here> <its copy in tmpfs: everything is read from here>
  local d="$1" t="$2" id image="" chart="" name tag ref line k v idig="" cdig="" cname ctgz
  id=$(basename "$d")
  mkdir -p "$t/platform/env"
  { echo "── $id: $(date -u +%FT%TZ)"; } >> "$d/log"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      IMAGE) image="$v" ;;
      CHART) chart="$v" ;;
      *) if [[ $k =~ ^BPL?_[A-Z0-9_]+$ ]]; then printf '%s' "$v" > "$t/platform/env/$k"   # buildpack inputs, as files; the regex admits no "/" (a case glob would)
         else echo "ignoring key: $k" >> "$d/log"; fi ;;
    esac
  done < "$t/request.env"

  # Validate before anything leaves: name:tag shape, name on the allowlist, an app dir to build.
  if ! printf '%s' "$image" | grep -qE '^[a-z0-9][a-z0-9._-]*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'; then
    echo "refused: IMAGE='$image' is not <name>:<tag>" >> "$d/log"; result "$d" STATUS=failed "IMAGE=$image"; return
  fi
  name="${image%%:*}"; tag="${image#*:}"
  if ! allowed "$name"; then
    echo "refused: image name '$name' is not in BUILD_NAMES (${BUILD_NAMES})" >> "$d/log"; result "$d" STATUS=failed "IMAGE=$image"; return
  fi
  if [ ! -d "$t/app" ] || [ -z "$(ls -A "$t/app" 2>/dev/null)" ]; then
    echo "refused: $d/app is missing or empty" >> "$d/log"; result "$d" STATUS=failed "IMAGE=$image"; return
  fi
  ctgz=""
  if [ -n "$chart" ] || [ -f "$t/chart.tgz" ]; then
    [ -f "$t/chart.tgz" ] || { echo "refused: CHART=$chart but no chart.tgz" >> "$d/log"; result "$d" STATUS=failed "IMAGE=$image"; return; }
    ctgz="$t/chart.tgz"                                      # validated and pushed from the tmpfs copy: the jail cannot swap it between the two
    cname=$(helm show chart "$ctgz" 2>>"$d/log" | sed -n 's/^name: *//p' | head -1)
    if [ -z "$cname" ] || [ "$cname" != "$chart" ] || ! allowed "$cname"; then
      echo "refused: chart.tgz is '$cname', CHART=$chart; must match and be in BUILD_NAMES" >> "$d/log"; result "$d" STATUS=failed "IMAGE=$image"; return
    fi
  fi

  ref="$REGISTRY/$name:$tag"
  log "$id: building $ref${chart:+ + chart $chart}"
  find "$WORK" "$LAYERS" -mindepth 1 -delete 2>/dev/null || true
  cp -a "$t/app/." "$WORK/"
  # The creator = detect+analyze+restore+build+export in one process, as this (unprivileged) user,
  # the app and layers at pack's paths, platform and report under the request dir, the cache as an
  # image in the same registry (one per name; restored into /layers, so rebuilds reuse the JRE etc.).
  if ! "$CNB/lifecycle/creator" -app "$WORK" -layers "$LAYERS" -platform "$t/platform" \
        -run-image "$RUN_IMAGE" -cache-image "$REGISTRY/$name-cache" -report "$t/report.toml" \
        -log-level info "$ref" >> "$d/log" 2>&1; then
    log "$id: image build FAILED"; result "$d" STATUS=failed "IMAGE=$ref"; return
  fi
  idig=$(sed -n 's/^ *digest *= *"\([^"]*\)".*/\1/p' "$t/report.toml" 2>/dev/null | head -1)
  if [ -n "$chart" ]; then
    if ! helm push "$ctgz" "oci://$REGISTRY/charts" --plain-http > "$t/chart-push.out" 2>&1; then
      cat "$t/chart-push.out" >> "$d/log"; log "$id: chart push FAILED"
      result "$d" STATUS=failed "IMAGE=$ref" "IMAGE_DIGEST=$idig" "CHART=$chart"; return
    fi
    cat "$t/chart-push.out" >> "$d/log"
    cdig=$(sed -n 's/^Digest: *//p' "$t/chart-push.out" | head -1)
  fi
  log "$id: done $ref${idig:+@$idig}${chart:+; chart $chart${cdig:+@$cdig}}"
  result "$d" STATUS=ok "IMAGE=$ref" "IMAGE_DIGEST=$idig" "CHART=$chart" "CHART_DIGEST=$cdig"
}

REFUSED_LINKS=""
log "serving: registry=$REGISTRY names=[${BUILD_NAMES}] run-image=$RUN_IMAGE platform-api=$CNB_PLATFORM_API uid=$CNB_USER_ID:$CNB_GROUP_ID auth=$auth app=$WORK layers=$LAYERS"
while :; do
  for d in "$BUILD"/*/; do
    d="${d%/}"
    if [ -L "$d" ]; then                                      # a symlinked request dir points the sidecar's writes elsewhere
      case " $REFUSED_LINKS " in *" $d "*) ;; *) log "$(basename "$d"): refused — the request dir is a symlink"; REFUSED_LINKS="$REFUSED_LINKS $d" ;; esac
      continue
    fi
    [ -f "$d/request" ] && [ ! -e "$d/result.env" ] && [ ! -e "$d/started" ] || continue
    : > "$d/started"
    build_one "$d"
  done
  sleep 1
done
