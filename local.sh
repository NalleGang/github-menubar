#!/bin/bash
# Print the local git repos under the given roots as one JSON array: branch,
# upstream, ahead/behind, working-tree counts, GitHub slug, last fetch time and
# the most recent commits. Everything here is local (no network), so it is
# cheap enough to poll every few seconds.
#
# Usage: local.sh <root>...   (repos are <root> itself or its direct children)
shopt -s nullglob
export GIT_OPTIONAL_LOCKS=0   # never take index.lock while the user works
roots=("$@")
((${#roots[@]})) || roots=("$HOME/Projects")
US=$'\x1f'
commits=${GITHUB_WIDGET_COMMITS:-8}

repos=()
for root in "${roots[@]}"; do
  root=${root/#\~/$HOME}
  root=${root%/}
  [[ -d $root ]] || continue
  [[ -e $root/.git ]] && repos+=("$root")
  for git in "$root"/*/.git; do repos+=("${git%/.git}"); done
done

for repo in "${repos[@]}"; do
  IFS=$US read -r head upstream ahead behind staged modified untracked conflicts stash < <(
    git -C "$repo" status --porcelain=v2 --branch --show-stash 2>/dev/null | awk -v OFS="$US" '
      /^# branch.head /     { head = $3 }
      /^# branch.upstream / { up = $3 }
      /^# branch.ab /       { a = substr($3, 2); b = substr($4, 2) }
      /^# stash /           { st = $3 }
      /^[12] / { if (substr($2, 1, 1) != ".") s++; if (substr($2, 2, 1) != ".") m++ }
      /^u /    { c++ }
      /^\? /   { u++ }
      END { print head, up, a + 0, b + 0, s + 0, m + 0, u + 0, c + 0, st + 0 }')
  [[ -n $head ]] || continue

  remote=$(git -C "$repo" remote 2>/dev/null | grep -m1 -x origin || git -C "$repo" remote 2>/dev/null | head -1)
  url=""
  [[ -n $remote ]] && url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null)
  slug=""
  if [[ $url =~ github\.com[:/]+([^/]+)/([^/]+)$ ]]; then
    slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  fi
  # No upstream: count the commits no remote has seen, so a fresh branch still
  # shows what a push would send.
  if [[ -z $upstream && -n $remote && $head != "(detached)" ]]; then
    ahead=$(git -C "$repo" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
  fi
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)
  fetched=$(stat -c %Y "$gitdir/FETCH_HEAD" 2>/dev/null || echo 0)

  printf 'R%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$US" "$repo" "$US" "${repo##*/}" "$US" "$head" "$US" "$upstream" "$US" "$ahead" "$US" "$behind" \
    "$US" "$staged" "$US" "$modified" "$US" "$untracked" "$US" "$conflicts" "$US" "$stash" \
    "$US" "$remote" "$US" "$slug" "$US" "$fetched"
  git -C "$repo" log -n "$commits" --no-show-signature --format="C${US}%h${US}%ct${US}%an${US}%s" 2>/dev/null
done | jq -R -s -c '
  split("\n")
  | map(select(length > 0) | split("\u001f"))
  | reduce .[] as $f ([];
      if $f[0] == "R" then
        . + [{
          path: $f[1], name: $f[2], branch: $f[3], upstream: $f[4],
          ahead: ($f[5] | tonumber), behind: ($f[6] | tonumber),
          staged: ($f[7] | tonumber), modified: ($f[8] | tonumber),
          untracked: ($f[9] | tonumber), conflicts: ($f[10] | tonumber),
          stash: ($f[11] | tonumber), remote: $f[12], slug: $f[13],
          fetchedAt: ($f[14] | tonumber), commits: []
        }]
      elif $f[0] == "C" and length > 0 then
        .[-1].commits += [{ hash: $f[1], time: ($f[2] | tonumber), author: $f[3], subject: ($f[4:] | join("\u001f")) }]
      else . end)
  | map(. + { lastCommit: (.commits[0].time // 0) })' 2>/dev/null || echo '[]'
