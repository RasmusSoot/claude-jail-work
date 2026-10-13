#!/usr/bin/env bash
# Claude Code status line, shared by the login jail (project settings) and every stack jail
# (tools/stack-jail.sh pins statusLine here on each launch; tools/ is mounted read-only there).
# stdin = JSON from Claude Code. Everything shown comes from it — no transcript scanning: each
# jail has its own ~/.claude, so local token sums never matched the account-wide rate limits.
set -u

# One jq pass; \x1f (non-whitespace) as separator so empty fields survive `read`.
IFS=$'\x1f' read -r model cwd session_name ctx ctx_max ctx_pct five_pct five_reset seven_pct seven_reset < <(
  jq -r '[
      .model.id // "?",
      .workspace.current_dir // .cwd // "",
      .session_name // "",
      ((.context_window.current_usage // null)
        | if . == null then "" else
            (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
          end),
      .context_window.context_window_size // "",
      .context_window.used_percentage // "",
      .rate_limits.five_hour.used_percentage // "",
      .rate_limits.five_hour.resets_at // "",
      .rate_limits.seven_day.used_percentage // "",
      .rate_limits.seven_day.resets_at // ""
    ] | map(tostring) | join("\u001f")'
)
now=$(date +%s)

fmt() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%.1fk", n/1000;
    else printf "%d", n
  }'
}

fmt_left() {
  local resets_at="$1"
  [[ -z "$resets_at" ]] && return
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
  [[ -z "$1" ]] && return
  TZ="${TZ:-Europe/Tallinn}" date -d "@$1" +'%a %H:%M %Z'
}

# CWD label: stack jails show the stack name, the login jail shows "jail".
root="${STACK_NAME:-jail}"
# shellcheck disable=SC2088  # "~/…" is display text, not a path
case "$cwd" in
  /workspace)    cwd_short="$root" ;;
  /workspace/*)  cwd_short="$root/${cwd#/workspace/}" ;;
  /home/claude)    cwd_short="~" ;;
  /home/claude/*)  cwd_short="~/${cwd#/home/claude/}" ;;
  *)             cwd_short="$cwd" ;;
esac

# Terminal window title: claude · <cwd> [· <session_name>]
title="claude · $cwd_short"
[[ -n "$session_name" ]] && title+=" · $session_name"
printf '\033]2;%s\007' "$title"

out=""
[[ -n "$cwd_short" ]] && out="$cwd_short │ "
out+="$model"

# Context: null usage before the session's first API call — show the window, no fake numbers.
if [[ -n "$ctx_max" ]]; then
  if [[ -n "$ctx_pct" ]]; then
    out+=" │ ctx $(fmt "${ctx:-0}")/$(fmt "$ctx_max") ($(printf '%.0f' "$ctx_pct")%)"
  else
    out+=" │ ctx –/$(fmt "$ctx_max")"
  fi
fi

# Rate limits: present only once this session has made a request.
if [[ -n "$five_pct" ]]; then
  out+=" │ 5h $(printf '%.0f' "$five_pct")%"
  left=$(fmt_left "$five_reset")
  [[ -n "$left" ]] && out+=" · resets in $left"
fi
if [[ -n "$seven_pct" ]]; then
  out+=" │ 7d $(printf '%.0f' "$seven_pct")%"
  when=$(fmt_when "$seven_reset")
  [[ -n "$when" ]] && out+=" · resets $when"
fi

printf '%s' "$out"
