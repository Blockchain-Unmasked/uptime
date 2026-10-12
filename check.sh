#!/usr/bin/env bash
# Checks every enabled target in targets.json and keeps one GitHub issue per
# problem:
#   failing, no open issue  -> open one (watchers and ALERT_MENTIONS get an email)
#   failing, open issue     -> refresh its body (no new notification)
#   passing, open issue     -> comment that it's resolved and close it
# A target that is down gets a "Down: <name>" issue; one whose TLS certificate
# expires within CERT_WARN_DAYS gets a "Certificate expiring: <name>" issue.
#
# A target only counts as down when it fails ATTEMPTS checks in a row,
# RETRY_DELAY seconds apart, so a single blip doesn't alert anyone.
#
# `check.sh --validate` only checks targets.json (names, urls, and that the jq
# expressions compile) and exits non-zero if it isn't valid.
set -euo pipefail

TARGETS="${TARGETS:-targets.json}"
ATTEMPTS="${ATTEMPTS:-2}"
RETRY_DELAY="${RETRY_DELAY:-60}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
GH="${GH:-gh}"
LABEL="outage"
DOWN_PREFIX="Down: "
CERT_PREFIX="Certificate expiring: "

now() { date -u +"%Y-%m-%d %H:%M UTC"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

field() { jq -r ".[$1].$2 // empty" "$TARGETS"; }
enabled() { [[ "$(jq -r ".[$1].enabled != false" "$TARGETS")" == true ]]; }

# Whether a jq expression compiles. Exit 3 is jq's compile error; any other
# failure is the expression running against null, which is fine here.
compiles() {
  local rc=0
  jq -n "$1" >/dev/null 2>&1 || rc=$?
  ((rc != 3))
}

# Prints what's wrong with a target's config, if anything.
config_error() {
  local i="$1" expr f
  if [[ -z "$(field "$i" name)" || -z "$(field "$i" url)" ]]; then
    echo "needs a name and a url"
    return
  fi
  for f in expect show; do
    expr="$(field "$i" "$f")"
    if [[ -n "$expr" ]] && ! compiles "$expr"; then
      echo "$f isn't a valid jq expression: $expr"
      return
    fi
  done
}

count="$(jq 'length' "$TARGETS")"
bad=0
config_ok=()
for ((i = 0; i < count; i++)); do
  enabled "$i" || continue
  err="$(config_error "$i")"
  if [[ -n "$err" ]]; then
    echo "::error file=$TARGETS::target $((i + 1)) ($(field "$i" name)): $err"
    bad=$((bad + 1))
  else
    config_ok+=("$i")
  fi
done
if [[ "${1:-}" == "--validate" ]]; then
  ((bad == 0)) && echo "$TARGETS is valid"
  exit $((bad > 0 ? 1 : 0))
fi

# Text from a target (a response body, an error message) ends up in a public
# issue and in Slack. Backticks are removed so it can't break out of the code
# block it's shown in, and the length is capped.
plain() { tr -d '`\r' <<<"$1" | head -c 400; }
# Slack reads <, > and & as markup (links, @channel): escape them.
slack_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

# probe <index> -> prints why the target is down and returns 1, or returns 0.
probe() {
  local url expect_status expect only_when_up show code err body
  url="$(field "$1" url)"
  expect_status="$(field "$1" status)"
  expect_status="${expect_status:-200}"
  expect="$(field "$1" expect)"
  only_when_up="$(jq -r ".[$1].only_when_up == true" "$TARGETS")"
  show="$(field "$1" show)"
  body="$work/body"

  if ! code="$(curl -sS -m 20 -o "$body" -w '%{http_code}' "$url" 2>"$work/err")"; then
    [[ "$only_when_up" == true ]] && return 0
    err="$(sed 's/^curl: ([0-9]*) //' "$work/err")"
    echo "No response: ${err:-request failed}"
    return 1
  fi
  if [[ "$code" != "$expect_status" ]]; then
    [[ "$only_when_up" == true ]] && return 0
    echo "HTTP $code (expected $expect_status)"
    return 1
  fi
  if [[ -n "$expect" ]]; then
    if ! jq -e . "$body" >/dev/null 2>&1; then
      [[ "$only_when_up" == true ]] && return 0
      echo "Response isn't JSON"
      return 1
    fi
    if ! jq -e "$expect" "$body" >/dev/null 2>&1; then
      local detail=""
      [[ -n "$show" ]] && detail=" Got: $(jq -c "$show" "$body" 2>/dev/null | head -c 300)"
      echo "Response doesn't match: $expect.$detail"
      return 1
    fi
  fi
  return 0
}

# Seconds since the epoch for an openssl date ("Jan  5 12:00:00 2027 GMT"):
# GNU date on the runner, BSD date on a Mac.
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%b %e %T %Y %Z" "$1" +%s; }

# cert_check <index> -> prints a warning when the certificate expires soon.
cert_check() {
  local url host port enddate days
  url="$(field "$1" url)"
  [[ "$url" == https://* && "$(jq -r ".[$1].cert != false" "$TARGETS")" == true ]] || return 0
  host="$(sed -E 's#^https://([^/:]+).*#\1#' <<<"$url")"
  port="$(sed -nE 's#^https://[^/:]+:([0-9]+).*#\1#p' <<<"$url")"
  openssl s_client -servername "$host" -connect "$host:${port:-443}" </dev/null 2>/dev/null \
    | openssl x509 >"$work/cert" 2>/dev/null || true
  [[ -s "$work/cert" ]] || return 0
  openssl x509 -in "$work/cert" -noout -checkend $((CERT_WARN_DAYS * 86400)) >/dev/null && return 0
  enddate="$(openssl x509 -in "$work/cert" -noout -enddate | sed 's/^notAfter=//')"
  days=$((($(epoch "$enddate") - $(date -u +%s)) / 86400))
  if ((days < 0)); then
    echo "The TLS certificate for $host expired on $enddate."
  else
    echo "The TLS certificate for $host expires in $days day(s), on $enddate."
  fi
}

notify_slack() {
  [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && return 0
  curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
    --data "$(jq -n --arg text "$1" '{text: $text}')" "$SLACK_WEBHOOK_URL" >/dev/null \
    || echo "::warning::Slack notification failed"
}

"$GH" label create "$LABEL" --color B60205 --description "A production check is failing" --force >/dev/null 2>&1 || true
open_issues="$("$GH" issue list --label "$LABEL" --state open --limit 100 --json number,title,createdAt)"

# sync <title> <failing|passing> <url> [headline] [failure]
sync() {
  local title="$1" state="$2" url="$3" headline="${4:-}" failure="${5:-}" issue number since body
  issue="$(jq -c --arg t "$title" 'map(select(.title == $t)) | first // empty' <<<"$open_issues")"
  if [[ "$state" == failing ]]; then
    body="$headline"$'\n\n'"- URL: $url"
    if [[ -n "$issue" ]]; then
      body+=$'\n'"- First seen: $(jq -r '.createdAt' <<<"$issue")"$'\n'"- Last checked: $(now)"
    else
      body+=$'\n'"- Detected: $(now)"
    fi
    body+=$'\n\n''```'$'\n'"$(plain "$failure")"$'\n''```'$'\n\n'"This issue closes itself when the check passes again."
    [[ -n "${ALERT_MENTIONS:-}" ]] && body+=$'\n\n'"cc ${ALERT_MENTIONS}"
    if [[ -z "$issue" ]]; then
      "$GH" issue create --title "$title" --label "$LABEL" --body "$body" >/dev/null
      notify_slack ":red_circle: $(slack_escape "$title ($url)") \`$(slack_escape "$(plain "$failure")")\`"
    else
      "$GH" issue edit "$(jq -r '.number' <<<"$issue")" --body "$body" >/dev/null
    fi
  elif [[ -n "$issue" ]]; then
    number="$(jq -r '.number' <<<"$issue")"
    since="$(jq -r '.createdAt' <<<"$issue")"
    "$GH" issue comment "$number" --body "Resolved at $(now). First seen $since." >/dev/null
    "$GH" issue close "$number" >/dev/null
    notify_slack ":large_green_circle: $(slack_escape "Resolved: $title ($url)")"
  fi
}

# Check everything, then re-check only what failed, so one slow target doesn't
# hold up the rest.
reason=()
pending=("${config_ok[@]+"${config_ok[@]}"}")
for ((attempt = 1; attempt <= ATTEMPTS && ${#pending[@]} > 0; attempt++)); do
  ((attempt > 1)) && sleep "$RETRY_DELAY"
  still=()
  for i in "${pending[@]}"; do
    if r="$(probe "$i")"; then
      unset 'reason[$i]'
    else
      reason[i]="$r"
      still+=("$i")
    fi
  done
  pending=("${still[@]+"${still[@]}"}")
done

down=0
for i in "${config_ok[@]+"${config_ok[@]}"}"; do
  name="$(field "$i" name)"
  url="$(field "$i" url)"
  if [[ -n "${reason[$i]+x}" ]]; then
    down=$((down + 1))
    echo "DOWN  $name: ${reason[$i]}"
    sync "$DOWN_PREFIX$name" failing "$url" "**$name** is not answering correctly." "${reason[$i]}"
    # The certificate can't be read while the target is down, so any
    # certificate issue is left as it is.
  else
    echo "UP    $name"
    sync "$DOWN_PREFIX$name" passing "$url"
    warning="$(cert_check "$i")"
    if [[ -n "$warning" ]]; then
      echo "CERT  $name: $warning"
      sync "$CERT_PREFIX$name" failing "$url" "**$name** is up, but its TLS certificate needs renewing." "$warning"
    else
      sync "$CERT_PREFIX$name" passing "$url"
    fi
  fi
done

# Close issues for targets that were removed or turned off, since nothing would
# ever resolve them. A target with a config error is still monitored, so its
# issues stay open.
managed="$(for ((i = 0; i < count; i++)); do
  if enabled "$i"; then printf '%s\n%s\n' "$DOWN_PREFIX$(field "$i" name)" "$CERT_PREFIX$(field "$i" name)"; fi
done | jq -R . | jq -s .)"
jq -c --argjson managed "$managed" --arg d "$DOWN_PREFIX" --arg c "$CERT_PREFIX" \
  '.[] | select((.title | startswith($d) or startswith($c)) and (.title as $t | $managed | index($t) | not))' \
  <<<"$open_issues" | while read -r orphan; do
  number="$(jq -r '.number' <<<"$orphan")"
  echo "CLOSE $(jq -r '.title' <<<"$orphan") (no longer monitored)"
  "$GH" issue comment "$number" --body "This target is no longer monitored (removed or turned off in targets.json), so this is closed without a recovery check." >/dev/null
  "$GH" issue close "$number" >/dev/null
done

echo "$down target(s) down"
if ((bad > 0)); then
  echo "::error::$bad target(s) in $TARGETS have a config error and weren't checked"
  exit 1
fi
