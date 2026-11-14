#!/bin/bash
# Run one git action for the widget and report the result as a notification.
# Usage: action.sh push|pull|lazygit <repo>   |   action.sh fetch <repo>...
export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
action=$1; shift
notify() { omarchy-notification-send --app-name GitHub -g 󰊤 "$@" 2>/dev/null || notify-send -a GitHub "$@"; }

case $action in
  fetch)
    printf '%s\0' "$@" | xargs -0 -P 4 -I{} timeout 60 git -C {} fetch --all --quiet 2>/dev/null
    exit 0 ;;
  lazygit)
    exec omarchy-launch-tui lazygit -p "$1" ;;
esac

repo=$1 name=${1##*/}
case $action in
  push)
    if git -C "$repo" rev-parse --abbrev-ref '@{push}' > /dev/null 2>&1; then
      out=$(timeout 90 git -C "$repo" push 2>&1)
    else
      remote=$(git -C "$repo" remote | grep -m1 -x origin || git -C "$repo" remote | head -1)
      # Keep an existing (differently named) upstream; only set one when none exists.
      if git -C "$repo" rev-parse --abbrev-ref '@{u}' > /dev/null 2>&1; then
        out=$(timeout 90 git -C "$repo" push "$remote" HEAD 2>&1)
      else
        out=$(timeout 90 git -C "$repo" push -u "$remote" HEAD 2>&1)
      fi
    fi ;;
  pull) out=$(timeout 90 git -C "$repo" pull --ff-only 2>&1) ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac
status=$?
if ((status == 0)); then
  notify "${action^}ed $name" "$(tail -n 2 <<< "$out")"
else
  notify -u critical "${action^} failed: $name" "$(tail -n 4 <<< "$out")"
fi
exit $status
