#!/bin/bash
# Ask GitHub (one GraphQL call + the notifications endpoint, via the gh CLI's
# login) for the viewer's contribution calendar, open PRs, PRs waiting on
# their review, unread notifications, and CI/PR/issue state for the given
# repos. Prints one JSON object; on failure {"ok": false, "error": ...} so the
# widget can keep showing the last good data.
#
# Usage: remote.sh [owner/name:branch]...
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1

fail() { jq -cn --arg e "$1" '{ ok: false, error: $e }'; exit 0; }
command -v gh > /dev/null || fail "gh CLI not installed"

vars=() decls=() fields=()
i=0
for arg in "$@"; do
  slug=${arg%%:*} branch=${arg#*:}
  [[ $slug == */* && -n $branch ]] || continue
  vars+=(-f "o$i=${slug%%/*}" -f "n$i=${slug#*/}" -f "b$i=refs/heads/$branch")
  decls+=("\$o$i: String!, \$n$i: String!, \$b$i: String!")
  fields+=("r$i: repository(owner: \$o$i, name: \$n$i) { ...repo ref(qualifiedName: \$b$i) { target { ... on Commit { oid statusCheckRollup { state } } } } }")
  ((i++))
done

decl=""
((${#decls[@]})) && decl="($(IFS=,; echo "${decls[*]}"))"

query="query$decl {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks { contributionDays { contributionCount contributionLevel weekday date } }
      }
    }
    pullRequests(states: OPEN, first: 10, orderBy: { field: UPDATED_AT, direction: DESC }) { nodes { ...pr } }
  }
  reviews: search(query: \"is:pr is:open archived:false review-requested:@me\", type: ISSUE, first: 10) { nodes { ...pr } }
  ${fields[*]}
}
fragment pr on PullRequest {
  number title url isDraft updatedAt reviewDecision
  repository { nameWithOwner }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
}
"
# GraphQL rejects unused fragments, so only send this one when repos were given.
((i)) && query+="
fragment repo on Repository {
  nameWithOwner url isPrivate stargazerCount
  defaultBranchRef { name }
  pullRequests(states: OPEN) { totalCount }
  issues(states: OPEN) { totalCount }
}"
# gh exits non-zero when any alias errors (a renamed or deleted repo), but the
# body still carries the data for everything else, so only fail without data.
errfile=$(mktemp); trap 'rm -f "$errfile"' EXIT
data=$(timeout 25 gh api graphql -f query="$query" "${vars[@]}" 2> "$errfile")
jq -e '.data.viewer' > /dev/null 2>&1 <<< "$data" || fail "$(head -c 300 "$errfile")"
notifications=$(timeout 15 gh api 'notifications?per_page=50' --jq length 2>/dev/null || echo -1)

jq -c --argjson notifications "${notifications:-0}" --arg now "$(date +%s)" '
  def pr: {
    number, title, url, draft: .isDraft, updatedAt, review: (.reviewDecision // ""),
    repo: .repository.nameWithOwner,
    ci: (.commits.nodes[0].commit.statusCheckRollup.state // "")
  };
  if .errors and (.data == null) then { ok: false, error: (.errors[0].message // "GraphQL error") }
  else
    .data as $d
    | ($d.viewer.contributionsCollection.contributionCalendar) as $cal
    | ([$cal.weeks[].contributionDays[]]) as $days
    | {
        ok: true,
        at: ($now | tonumber),
        login: $d.viewer.login,
        notifications: $notifications,
        contributions: {
          total: $cal.totalContributions,
          today: ($days[-1].contributionCount // 0),
          streak: (
            ($days | reverse) as $r
            | (if ($r[0].contributionCount // 0) == 0 then $r[1:] else $r end)
            | (map(.contributionCount > 0) | index(false)) // length
          ),
          weeks: [$cal.weeks[] | [.contributionDays[] | {
            c: .contributionCount, d: .date, wd: .weekday,
            l: ({ NONE: 0, FIRST_QUARTILE: 1, SECOND_QUARTILE: 2, THIRD_QUARTILE: 3, FOURTH_QUARTILE: 4 }[.contributionLevel] // 0)
          }]]
        },
        prs: [$d.viewer.pullRequests.nodes[] | pr],
        reviews: [$d.reviews.nodes[] | select(.number != null) | pr],
        repos: ([$d | to_entries[] | select(.key | test("^r[0-9]+$")) | .value | select(. != null) | {
          key: .nameWithOwner,
          value: {
            url, private: .isPrivate, stars: .stargazerCount,
            defaultBranch: (.defaultBranchRef.name // ""),
            prs: .pullRequests.totalCount, issues: .issues.totalCount,
            pushed: (.ref != null),
            remoteOid: (.ref.target.oid // ""),
            ci: (.ref.target.statusCheckRollup.state // "")
          }
        }] | from_entries)
      }
  end' <<< "$data" 2>/dev/null || fail "unexpected response from GitHub"
