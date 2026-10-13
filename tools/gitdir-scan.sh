#!/usr/bin/env bash
# gitdir-scan — what git would execute config from under a stack home, for tools/stack-jail.sh.
#
#   gitdir-scan.sh <stack home> <dir>…
#
# One line per finding, tab-separated, over the dirs named (the repo dirs, notes, build):
#   gitdir  <dir>/.git  <inode>   a top-level .git DIRECTORY — the only kind of gitdir there is here;
#                                 the launcher protects it once the record says so (its inode is the identity)
#   refuse  <path>  <why>         stops a launch: a <dir>/.git that is not a directory (a pointer file or a
#                                 symlink — git follows either to a gitdir of the writer's choosing), a
#                                 .git/modules dir (submodules are not supported: each would be one more gitdir
#                                 to protect and audit, and git names them after their path), a directory
#                                 find could not read (a chmod by a session would hide what is under it)
#   nested  <path>                a .git entry (dir, file or link) inside a working tree: an IDE auto-detects
#                                 it and runs git there with ITS config. Reported; deleting is the human's call
# find + ls only, never git: git would read the very configs this is meant to judge. Paths are
# relative to the stack home and raw; a name with a control character is refused instead of printed
# (the caller prints with %q). The last line is always "end": a caller that does not see it did not
# get a scan (the script missing, not executable, a usage error) and must fail closed. Exit 0; 2 on usage.
set -u
home="${1:-}"; shift || true
[ -n "$home" ] && [ -d "$home" ] && [ $# -gt 0 ] || { echo "usage: gitdir-scan.sh <stack home> <dir>..." >&2; exit 2; }
home="${home%/}"
# shellcheck disable=SC2012  # only the inode column is used, so an odd filename cannot mislead
inode() { ls -di "$1" | awk '{print $1}'; }
err=$(mktemp) || exit 1; trap 'rm -f "$err"' EXIT   # no scratch file, no scan (and no "end" line)
for name in "$@"; do
  d="$home/$name"
  [ -d "$d" ] || continue
  g="$d/.git"
  if [ -L "$g" ] || { [ -e "$g" ] && [ ! -d "$g" ]; }; then
    printf 'refuse\t%s/.git\tnot a directory (a .git pointer file or symlink: git follows it to any gitdir)\n' "$name"
  elif [ -d "$g" ]; then
    printf 'gitdir\t%s/.git\t%s\n' "$name" "$(inode "$g")"
    [ ! -e "$g/modules" ] || printf 'refuse\t%s/.git/modules\tsubmodules are not supported here (one gitdir per repo dir)\n' "$name"
  fi
  : > "$err"
  # The top-level gitdir is pruned by identity (-samefile), never by a pattern: a name holding [ ] * ?
  # would otherwise be a glob. A local-only dir has nothing to prune.
  prune=(); [ ! -d "$g" ] || prune=( \( -samefile "$g" -prune \) -o )
  while IFS= read -r -d '' p; do
    p="${p#"$home/"}"
    [ "$p" != "$name/.git" ] || continue                 # the top-level entry itself (a file or link: already refused above)
    case "$p" in
      *[[:cntrl:]]*) printf 'refuse\t%s\tname contains a control character\n' "$(printf '%q' "$p")" ;;
      *) printf 'nested\t%s\n' "$p" ;;
    esac
  done < <(find "$d" -mindepth 1 ${prune[@]+"${prune[@]}"} \( -name .git -print0 -prune \) 2>"$err")
  [ ! -s "$err" ] || while IFS= read -r l; do printf 'refuse\t%s\tunreadable: %s\n' "$name" "$(printf '%q' "$l")"; done < "$err"
done
printf 'end\n'
