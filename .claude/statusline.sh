#!/usr/bin/env bash
# Claude Code custom status line: model + context % + 5-hour usage %.
# stdin = JSON from Claude Code (model.id, transcript_path, etc.).
set -u

input=$(cat)
model=$(jq -r '.model.id // "?"' <<<"$input")
cwd=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$input")
session_name=$(jq -r '.session_name // ""' <<<"$input")
five_pct=$(jq -r '.rate_limits.five_hour.used_percentage // ""' <<<"$input")
five_reset=$(jq -r '.rate_limits.five_hour.resets_at // ""' <<<"$input")
seven_pct=$(jq -r '.rate_limits.seven_day.used_percentage // ""' <<<"$input")
seven_reset=$(jq -r '.rate_limits.seven_day.resets_at // ""' <<<"$input")
transcript=$(jq -r '.transcript_path // ""' <<<"$input")

# Context tokens: latest "assistant" message's usage block in the active transcript.
ctx=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  ctx=$(tac "$transcript" 2>/dev/null \
    | awk '/"type":"assistant"/ { print; exit }' \
    | jq -r '
        (.message.usage // {})
        | (.cache_read_input_tokens // 0)
        + (.cache_creation_input_tokens // 0)
        + (.input_tokens // 0)
        + (.output_tokens // 0)
      ' 2>/dev/null) || ctx=0
fi
ctx=${ctx:-0}

# Model context window. 1M variants encode it in the id.
case "$model" in
  *1m*) ctx_max=1000000 ;;
  *)               ctx_max=200000  ;;
esac

# 5h sum is cached briefly — scanning every project's JSONL on every status
# refresh would lag the UI.
fivh_cache="/tmp/claude-5h-tokens.$(id -u)"
fivh_ttl=30
now=$(date +%s)
if [ -f "$fivh_cache" ] && [ $((now - $(stat -c %Y "$fivh_cache" 2>/dev/null || echo 0))) -lt "$fivh_ttl" ]; then
  fivh=$(cat "$fivh_cache" 2>/dev/null || echo 0)
else
  since=$(date -u -d '5 hours ago' +%s 2>/dev/null || date -u -v-5H +%s)
  since_iso=$(date -u -d '5 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -v-5H '+%Y-%m-%d %H:%M:%S')
  fivh=$(find /home/node/.claude/projects -name '*.jsonl' -newermt "$since_iso" 2>/dev/null -print0 \
    | xargs -0 -r cat 2>/dev/null \
    | jq -rs --argjson since "$since" '
        [ .[]
          | select(.type == "assistant")
          | select(((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) >= $since)
          | (.message.usage // {})
          | (.input_tokens // 0) + (.output_tokens // 0)
        ] | add // 0
      ' 2>/dev/null) || fivh=0
  fivh=${fivh:-0}
  echo "$fivh" > "$fivh_cache" 2>/dev/null || true
fi

# Derive actual limit from API percentage. rate_limits is only present once THIS session has
# made an API request (the CLI learns it from its own traffic) — so a fresh/idle session gets
# none. Cache the last derived limit (persistent ~/.claude survives container rebuilds) and
# reuse it, marked "~", instead of inventing a wrong percentage against the 200k default.
limit_cache="/home/node/.claude/five-hour-limit.cached"
fivh_max_approx=""
if [[ -n "$five_pct" && "$five_pct" != "null" && "$five_pct" != "0" && "$fivh" -gt 0 ]]; then
  fivh_max=$(awk -v t="$fivh" -v p="$five_pct" 'BEGIN { printf "%d", t * 100 / p }')
  echo "$fivh_max" > "$limit_cache" 2>/dev/null || true
elif [[ -s "$limit_cache" ]]; then
  fivh_max=$(cat "$limit_cache")
  fivh_max_approx="~"
else
  fivh_max="${CLAUDE_5H_LIMIT:-200000}"
  fivh_max_approx="?"
fi

fmt_left() {
  local resets_at="$1"
  [[ -z "$resets_at" || "$resets_at" == "null" ]] && return
  local secs=$(( resets_at - now ))
  (( secs < 0 )) && secs=0
  local mins=$(( (secs + 30) / 60 ))
  if (( mins >= 60 )); then
    printf '%dh%02dm' $(( mins / 60 )) $(( mins % 60 ))
  else
    printf '%dm' "$mins"
  fi
}

fmt_when() {
  local resets_at="$1"
  [[ -z "$resets_at" || "$resets_at" == "null" ]] && return
  TZ="${TZ:-Europe/Tallinn}" date -d "@$resets_at" +'%a %H:%M %Z'
}

fmt() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%.1fk", n/1000;
    else printf "%d", n
  }'
}
pct() {
  awk -v n="${1:-0}" -v d="${2:-1}" 'BEGIN { if (d+0 == 0) print 0; else printf "%d", (n*100)/d }'
}

fivh_suffix=""
left=$(fmt_left "$five_reset")
[[ -n "$left" ]] && fivh_suffix=" · resets in $left"

# CWD label: map container paths back to host-visible paths.
case "$cwd" in
  /workspace)    cwd_short="jail" ;;
  /workspace/*)  cwd_short="jail/${cwd#/workspace/}" ;;
  /home/node)    cwd_short="~" ;;
  /home/node/*)  cwd_short="~/${cwd#/home/node/}" ;;
  "")            cwd_short="" ;;
  *)             cwd_short="$cwd" ;;
esac

# Terminal window title: claude · <cwd> [· <session_name>]
title="claude · $cwd_short"
[[ -n "$session_name" && "$session_name" != "null" ]] && title+=" · $session_name"
printf '\033]2;%s\007' "$title"

out=""
[[ -n "$cwd_short" ]] && out="$cwd_short │ "
out+="$model │ ctx $(fmt "$ctx")/$(fmt "$ctx_max") ($(pct "$ctx" "$ctx_max")%) │ 5h $(fmt "$fivh")/${fivh_max_approx}$(fmt "$fivh_max") ($(pct "$fivh" "$fivh_max")%)$fivh_suffix"

if [[ -n "$seven_pct" && "$seven_pct" != "null" ]]; then
  when=$(fmt_when "$seven_reset")
  seven_pct_int=$(printf '%.0f' "$seven_pct")
  [[ -n "$when" ]] && out+=" │ 7d ${seven_pct_int}% · resets $when"
fi

printf '%s' "$out"
