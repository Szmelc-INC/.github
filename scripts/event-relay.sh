#!/usr/bin/env bash
# Relay notable GitHub events to the maintainer: stars, forks, members, repos made public,
# releases by others, and PRs / issues / comments by others on the personal account's repos.
# Sinks: a comment on the inbox issue (GitHub e-mails the maintainer), Discord, and SMTP when set.
# Usage: scripts/event-relay.sh [--dry-run] [--since-hours N]
# Env: GH_TOKEN, ORG, USER_ACCOUNT, MAINTAINERS, STATE_FILE, INBOX_REPO, INBOX_ISSUE,
#      DISCORD_WEBHOOK, SMTP_URL, SMTP_USER, SMTP_PASS, MAIL_TO (sinks are optional).
set -euo pipefail

ORG=${ORG:-Szmelc-INC}
USER_ACCOUNT=${USER_ACCOUNT:-sernik77}
MAINTAINERS=${MAINTAINERS:-$USER_ACCOUNT}
STATE_FILE=${STATE_FILE:-.relay/last-id}
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

# events SCOPE PATH: one page of events, each tagged with its scope (org | user).
events() { gh api "$2" 2>/dev/null | jq -c --arg s "$1" '.[] | . + {scope: $s}' || true; }

all=$(
  if [[ -n ${EVENTS_FILE:-} ]]; then jq -c '.[]' "$EVENTS_FILE"; else # test input: a JSON array of events
    events org "orgs/$ORG/events?per_page=100"
    gh api --paginate "users/$USER_ACCOUNT/repos?type=owner&per_page=100" --jq '.[] | select(.private | not) | .full_name' |
      while read -r r; do events user "repos/$r/events?per_page=100"; done
  fi | jq -sc 'unique_by(.id) | sort_by(.id | tonumber)'
)

last=0
[[ -s $STATE_FILE ]] && last=$(<"$STATE_FILE")
max=$(jq -r 'map(.id | tonumber) | max // 0' <<<"$all")

if [[ -z $since_hours && $last == 0 ]]; then
  # First run: remember where we are, report nothing old.
  if ((!dry)); then mkdir -p "$(dirname "$STATE_FILE")"; echo "$max" >"$STATE_FILE"; fi
  echo "seeded state at event $max"
  armed=1
else
  armed=0
fi

lines=$(jq -r --arg last "$last" --arg since "$since_hours" --arg m "$MAINTAINERS" --argjson armed "$armed" '
  ($m | split(" ")) as $maint
  | def who: .actor.login;
    def link(u; t): "[\(t)](\(u))";
    def user: link("https://github.com/\(who)"; who);
    def repo: link("https://github.com/\(.repo.name)"; .repo.name);
    def safe: (. // "") | gsub("[`\r\n]"; " ") | .[0:120] | "`\(.)`";
    def other: who as $w | (any($maint[]; . == $w) | not) and ($w | endswith("[bot]") | not);
  if $armed == 1 then empty else . end
  | .[]
  | select(if $since != "" then (.created_at | fromdateiso8601) > (now - ($since | tonumber) * 3600)
           else (.id | tonumber) > ($last | tonumber) end)
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

if ((!dry)) && [[ -z $since_hours ]] && ((max > last)); then
  mkdir -p "$(dirname "$STATE_FILE")"; echo "$max" >"$STATE_FILE"
fi

if ((armed)); then
  text="Event relay armed: new stars, forks, members, public repos and outside activity on @$USER_ACCOUNT's repos will be posted here."
  count=0
else
  count=$(grep -c . <<<"$lines" || true)
  ((count)) || { echo "no new notable events (state $last → $max)"; exit 0; }
  shown=$(head -n "$MAX_LINES" <<<"$lines")
  ((count > MAX_LINES)) && shown+=$'\n'"- … and $((count - MAX_LINES)) more"
  stars=$(grep -c '^- ⭐' <<<"$lines" || true)
  forks=$(grep -c '^- 🍴' <<<"$lines" || true)
  text="**$count new event(s)** · ⭐ $stars · 🍴 $forks"$'\n\n'"$shown"
fi

if ((dry)); then printf '%s\n' "$text"; exit 0; fi

# Sink 1: inbox issue comment; GitHub notifies (and e-mails) the issue author and the mention.
if [[ -n ${INBOX_ISSUE:-} && -n ${INBOX_REPO:-} ]]; then
  gh issue comment "$INBOX_ISSUE" -R "$INBOX_REPO" -F - --silent 2>/dev/null <<<"$text"$'\n\n'"cc @$USER_ACCOUNT" ||
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
