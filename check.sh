#!/usr/bin/env bash
# Checks every enabled target in targets.json and keeps one GitHub issue per
# target that is down:
#   down, no open issue  -> open one (watchers and ALERT_MENTIONS get an email)
#   down, open issue     -> refresh its body (no new notification)
#   up, open issue       -> comment that it recovered and close it
#
# A target only counts as down when it fails ATTEMPTS checks in a row,
# RETRY_DELAY seconds apart, so a single blip doesn't alert anyone.
set -euo pipefail

TARGETS="${TARGETS:-targets.json}"
ATTEMPTS="${ATTEMPTS:-2}"
RETRY_DELAY="${RETRY_DELAY:-60}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
GH="${GH:-gh}"
LABEL="outage"

now() { date -u +"%Y-%m-%d %H:%M UTC"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# probe <index> -> prints the failure reason and returns 1, or returns 0.
probe() {
  local t url expect_status expect only_when_up show code err body
  t="$(jq -c ".[$1]" "$TARGETS")"
  url="$(jq -r '.url' <<<"$t")"
  expect_status="$(jq -r '.status // 200' <<<"$t")"
  expect="$(jq -r '.expect // empty' <<<"$t")"
  only_when_up="$(jq -r '.only_when_up // false' <<<"$t")"
  show="$(jq -r '.show // empty' <<<"$t")"
  body="$work/body"

  if ! code="$(curl -sS -m 20 -o "$body" -w '%{http_code}' "$url" 2>"$work/err")"; then
    [[ "$only_when_up" == true ]] && return 0
    err="$(tr -d '\r' <"$work/err" | sed 's/^curl: ([0-9]*) //' | head -c 300)"
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
      echo "Response doesn't match \`$expect\`.$detail"
      return 1
    fi
  fi
  if [[ "$url" == https://* && "$(jq -r '.cert != false' <<<"$t")" == true ]]; then
    local host
    host="$(sed -E 's#^https://([^/:]+).*#\1#' <<<"$url")"
    openssl s_client -servername "$host" -connect "$host:443" </dev/null 2>/dev/null \
      | openssl x509 >"$work/cert" 2>/dev/null || true
    if [[ -s "$work/cert" ]] && ! openssl x509 -in "$work/cert" -noout -checkend $((CERT_WARN_DAYS * 86400)) >/dev/null; then
      echo "TLS certificate for $host expires within $CERT_WARN_DAYS days ($(openssl x509 -in "$work/cert" -noout -enddate | sed 's/^notAfter=//'))"
      return 1
    fi
  fi
  return 0
}

notify_slack() {
  [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && return 0
  curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
    --data "$(jq -n --arg text "$1" '{text: $text}')" "$SLACK_WEBHOOK_URL" >/dev/null \
    || echo "::warning::Slack notification failed"
}

"$GH" label create "$LABEL" --color B60205 --description "A production check is failing" --force >/dev/null 2>&1 || true
open_issues="$("$GH" issue list --label "$LABEL" --state open --limit 100 --json number,title,createdAt)"

count="$(jq 'length' "$TARGETS")"
reason=()
pending=()
for ((i = 0; i < count; i++)); do
  [[ "$(jq -r ".[$i].enabled != false" "$TARGETS")" == true ]] && pending+=("$i")
done

# Check everything, then re-check only what failed, so one slow target doesn't
# hold up the rest.
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
for ((i = 0; i < count; i++)); do
  [[ "$(jq -r ".[$i].enabled != false" "$TARGETS")" == true ]] || continue
  name="$(jq -r ".[$i].name" "$TARGETS")"
  url="$(jq -r ".[$i].url" "$TARGETS")"
  title="Down: $name"
  issue="$(jq -c --arg t "$title" 'map(select(.title == $t)) | first // empty' <<<"$open_issues")"

  if [[ -n "${reason[$i]+x}" ]]; then
    down=$((down + 1))
    echo "DOWN  $name: ${reason[$i]}"
    if [[ -z "$issue" ]]; then
      body="$(printf '**%s** is not answering correctly.\n\n- URL: %s\n- Detected: %s\n- Failure: %s\n\nThis issue closes itself when the check passes again.\n' \
        "$name" "$url" "$(now)" "${reason[$i]}")"
      [[ -n "${ALERT_MENTIONS:-}" ]] && body+=$'\n'"cc ${ALERT_MENTIONS}"
      "$GH" issue create --title "$title" --label "$LABEL" --body "$body" >/dev/null
      notify_slack ":red_circle: $title ($url): ${reason[$i]}"
    else
      number="$(jq -r '.number' <<<"$issue")"
      since="$(jq -r '.createdAt' <<<"$issue")"
      body="$(printf '**%s** is not answering correctly.\n\n- URL: %s\n- Down since: %s\n- Last checked: %s\n- Failure: %s\n\nThis issue closes itself when the check passes again.\n' \
        "$name" "$url" "$since" "$(now)" "${reason[$i]}")"
      [[ -n "${ALERT_MENTIONS:-}" ]] && body+=$'\n'"cc ${ALERT_MENTIONS}"
      "$GH" issue edit "$number" --body "$body" >/dev/null
    fi
  else
    echo "UP    $name"
    if [[ -n "$issue" ]]; then
      number="$(jq -r '.number' <<<"$issue")"
      since="$(jq -r '.createdAt' <<<"$issue")"
      "$GH" issue comment "$number" --body "Back up at $(now). Down since $since." >/dev/null
      "$GH" issue close "$number" >/dev/null
      notify_slack ":large_green_circle: $name is back up ($url)"
    fi
  fi
done

echo "$down target(s) down"
