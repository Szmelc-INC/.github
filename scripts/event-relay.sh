#!/usr/bin/env bash
# Relay notable GitHub events to the maintainer: stars, forks, members, repos made public,
# releases by others, and PRs / issues / comments by others on the personal account's repos.
# Sinks: a comment on the inbox issue (GitHub e-mails the maintainer), Discord, and SMTP when set.
# Usage: scripts/event-relay.sh [--dry-run] [--since-hours N]
# Env: GH_TOKEN, ORG, USER_ACCOUNT, MAINTAINERS, STATE_FILE, WINDOW_HOURS, INBOX_REPO, INBOX_ISSUE,
#      DISCORD_WEBHOOK, SMTP_URL, SMTP_USER, SMTP_PASS, MAIL_TO (sinks are optional), EVENTS_FILE (tests).
set -euo pipefail

ORG=${ORG:-Szmelc-INC}
USER_ACCOUNT=${USER_ACCOUNT:-sernik77}
MAINTAINERS=${MAINTAINERS:-$USER_ACCOUNT}
STATE_FILE=${STATE_FILE:-.relay/seen-ids} # one event id per line, newest last
WINDOW_HOURS=${WINDOW_HOURS:-48}          # the Events API can lag by hours; ids seen inside it are deduped
SEEN_CAP=5000
MAX_LINES=60

dry=0 since_hours=''
while (($#)); do
  case $1 in
    --dry-run) dry=1 ;;
    --since-hours) since_hours=${2:?hours}; shift ;;
    -h | --help) sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# events SCOPE PATH: one page of events tagged with its scope (org | user).
# An org feed error fails the run; a single personal repo error is only logged.
events() {
  local out
  if ! out=$(gh api --paginate "$2" 2>&1); then # org feed: up to 3 pages (300 events)
    echo "WARN: $2: ${out:0:200}" >&2
    [[ $1 == org ]] && return 1
    return 0
  fi
  jq -c --arg s "$1" '.[] | . + {scope: $s}' <<<"$out"
}

all=$(
  if [[ -n ${EVENTS_FILE:-} ]]; then jq -c '.[]' "$EVENTS_FILE"; else
    events org "orgs/$ORG/events?per_page=100" || exit 1 # $( ) does not inherit errexit
    gh api --paginate "users/$USER_ACCOUNT/repos?type=owner&per_page=100" --jq '.[] | select(.private | not) | .full_name' |
      while read -r r; do events user "repos/$r/events?per_page=100"; done
  fi | jq -sc 'unique_by(.id) | sort_by(.created_at)'
)
echo "fetched $(jq length <<<"$all") events: $(jq -r 'group_by(.scope + ":" + .type) | map("\(.[0].scope):\(.[0].type)=\(length)") | join(" ")' <<<"$all")" >&2

first=0
[[ -s $STATE_FILE ]] || first=1
legacy=$(dirname "$STATE_FILE")/last-id # v1 single-id watermark: migrate silently
seenraw=$([[ -s $STATE_FILE ]] && cat "$STATE_FILE" || true)

lines=''
if ((first)) && [[ -z $since_hours ]]; then
  echo "seeding state with $(jq length <<<"$all") current events" >&2
else
  lines=$(jq -r --arg seenraw "$seenraw" --arg since "$since_hours" --arg window "$WINDOW_HOURS" --arg m "$MAINTAINERS" '
    ($m | split(" ")) as $maint
    | ($seenraw | split("\n") | map(select(. != "") | {(.): true}) | add // {}) as $seen
    | def who: .actor.login;
      def link(u; t): "[\(t)](\(u))";
      def user: link("https://github.com/\(who)"; who);
      def repo: link("https://github.com/\(.repo.name)"; .repo.name);
      def safe: (. // "") | gsub("[`\r\n]"; " ") | .[0:120] | "`\(.)`";
      def other: who as $w | (any($maint[]; . == $w) | not) and ($w | endswith("[bot]") | not);
      def age_ok($h): (.created_at | fromdateiso8601) > (now - ($h | tonumber) * 3600);
    .[]
    | select(if $since != "" then age_ok($since) else ($seen[.id] | not) and age_ok($window) end)
    | select(other)
    | (.created_at | sub(":[0-9]+Z$"; "Z") | sub("T"; " ")) as $t
    | if .type == "WatchEvent" then "⭐ \(user) starred \(repo)"
      elif .type == "ForkEvent" then "🍴 \(user) forked \(repo) → \(link(.payload.forkee.html_url; .payload.forkee.full_name))"
      elif .type == "MemberEvent" then "👥 \(user) \(.payload.action) \(link("https://github.com/\(.payload.member.login)"; .payload.member.login)) on \(repo)"
      elif .type == "PublicEvent" then "🌍 \(repo) is now public (by \(user))"
      elif .type == "ReleaseEvent" and .payload.action == "published" then "🚀 \(user) published \(link(.payload.release.html_url; .payload.release.tag_name)) in \(repo)"
      elif .scope == "user" and .type == "PullRequestEvent" and .payload.action == "opened" then "🔀 \(user) opened \(link(.payload.pull_request.html_url; "PR #\(.payload.pull_request.number)")) \(.payload.pull_request.title | safe) in \(repo)"
      elif .scope == "user" and .type == "IssuesEvent" and .payload.action == "opened" then "🐛 \(user) opened \(link(.payload.issue.html_url; "issue #\(.payload.issue.number)")) \(.payload.issue.title | safe) in \(repo)"
      elif .scope == "user" and .type == "IssueCommentEvent" then "💬 \(user) commented on \(link(.payload.comment.html_url; "#\(.payload.issue.number)")) in \(repo)"
      elif .scope == "user" and .type == "PullRequestReviewEvent" then "👀 \(user) reviewed \(link(.payload.pull_request.html_url; "PR #\(.payload.pull_request.number)")) in \(repo)"
      else empty end
    | "- \(.) · \($t)"' <<<"$all")
fi

# Remember every fetched id (old ones first, so the cap keeps the newest).
if ((!dry)) && [[ -z $since_hours ]]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  { printf '%s\n' "$seenraw"; jq -r '.[].id' <<<"$all"; } | awk 'NF && !seen[$0]++' | tail -n "$SEEN_CAP" >"$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

if ((first)) && [[ -z $since_hours ]]; then
  [[ -e $legacy ]] && { echo "migrated from $legacy; nothing to announce"; exit 0; }
  text="Event relay armed: new stars, forks, members, public repos and outside activity on @$USER_ACCOUNT's repos will be posted here."
  count=0
else
  count=$(grep -c . <<<"$lines" || true)
  ((count)) || { echo "no new notable events"; exit 0; }
  shown=$(head -n "$MAX_LINES" <<<"$lines")
  ((count > MAX_LINES)) && shown+=$'\n'"- … and $((count - MAX_LINES)) more"
  stars=$(grep -c '^- ⭐' <<<"$lines" || true)
  forks=$(grep -c '^- 🍴' <<<"$lines" || true)
  text="**$count new event(s)** · ⭐ $stars · 🍴 $forks"$'\n\n'"$shown"
fi

if ((dry)); then printf '%s\n' "$text"; exit 0; fi

# Sink 1: inbox issue comment; GitHub notifies (and e-mails) the issue author and the mention.
if [[ -n ${INBOX_ISSUE:-} && -n ${INBOX_REPO:-} ]]; then
  gh issue comment "$INBOX_ISSUE" -R "$INBOX_REPO" -F - <<<"$text"$'\n\n'"cc @$USER_ACCOUNT" >/dev/null
  echo "inbox: commented on $INBOX_REPO#$INBOX_ISSUE"
fi

# Sink 2: Discord embed, no pings.
if [[ -n ${DISCORD_WEBHOOK:-} ]]; then
  jq -n --arg d "${text:0:4000}" --arg u "https://github.com/${INBOX_REPO:-$ORG}/issues/${INBOX_ISSUE:-}" \
    '{username: "GitHub events", allowed_mentions: {parse: []},
      embeds: [{title: "Szmelc™ GitHub events", url: $u, description: $d, color: 1072220}]}' |
    curl -fsS -H 'Content-Type: application/json' --data-binary @- "$DISCORD_WEBHOOK" >/dev/null
  echo "discord: sent"
fi

# Sink 3: e-mail over SMTP (optional secrets).
if [[ -n ${SMTP_URL:-} && -n ${SMTP_USER:-} && -n ${SMTP_PASS:-} && -n ${MAIL_TO:-} ]]; then
  msg=$(mktemp)
  {
    printf 'From: GitHub event relay <%s>\r\nTo: <%s>\r\n' "$SMTP_USER" "$MAIL_TO"
    printf 'Subject: [Szmelc] %s new GitHub event(s)\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n' "$count"
    sed -E 's/\[([^]]*)\]\(([^)]*)\)/\1 <\2>/g; s/\*\*//g' <<<"$text"
  } >"$msg"
  curl -fsS --ssl-reqd --url "$SMTP_URL" --user "$SMTP_USER:$SMTP_PASS" \
    --mail-from "$SMTP_USER" --mail-rcpt "$MAIL_TO" --upload-file "$msg"
  rm -f "$msg"
  echo "smtp: sent"
fi
