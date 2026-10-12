#!/usr/bin/env bash
# Runs check.sh against a local server and a fake gh, and checks which issue
# calls it makes in each situation.
set -euo pipefail
cd "$(dirname "$0")/.."

port=8765
python3 -m http.server "$port" --bind 127.0.0.1 --directory tests/fixtures >/dev/null 2>&1 &
server=$!
tmp="$(mktemp -d)"
trap 'kill "$server" 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/ok.json" && break; sleep 0.1; done

base="http://127.0.0.1:$port"
failures=0

# scenario <description> <targets json> <open issues json> <expected log regex|-none>
scenario() {
  local desc="$1"
  printf '%s' "$2" >"$tmp/targets.json"
  printf '%s' "$3" >"$tmp/issues.json"
  : >"$tmp/gh.log"
  TARGETS="$tmp/targets.json" FAKE_ISSUES="$tmp/issues.json" FAKE_GH_LOG="$tmp/gh.log" \
    GH="$PWD/tests/fake-gh" ATTEMPTS=2 RETRY_DELAY=0 CERT_WARN_DAYS="${CERT_DAYS:-14}" SLACK_WEBHOOK_URL="" ALERT_MENTIONS="${MENTIONS:-}" \
    ./check.sh >"$tmp/out" 2>&1 || { echo "FAIL  $desc: check.sh exited non-zero"; cat "$tmp/out"; failures=$((failures + 1)); return; }
  local log
  log="$(grep -v '^label create' "$tmp/gh.log" || true)"
  if [[ "$4" == "-none" ]]; then
    if [[ -n "$log" ]]; then echo "FAIL  $desc: expected no issue calls, got: $log"; failures=$((failures + 1)); return; fi
  elif ! grep -Eq "$4" <<<"$log"; then
    echo "FAIL  $desc: expected /$4/, got: ${log:-nothing}"; cat "$tmp/out"; failures=$((failures + 1)); return
  fi
  echo "ok    $desc"
}

none='[]'
open_app='[{"number":7,"title":"Down: App","createdAt":"2026-10-12T15:00:00Z"}]'

scenario "healthy target, no issue: nothing happens" \
  "[{\"name\":\"App\",\"url\":\"$base/ok.json\",\"expect\":\".status == \\\"ok\\\"\"}]" "$none" -none
scenario "404 opens an issue" \
  "[{\"name\":\"App\",\"url\":\"$base/missing\"}]" "$none" '^issue create --title Down: App --label outage --body .*HTTP 404'
scenario "unreachable host opens an issue" \
  "[{\"name\":\"App\",\"url\":\"http://127.0.0.1:9/\"}]" "$none" '^issue create --title Down: App .*No response'
scenario "still down: refreshes the open issue instead of opening another" \
  "[{\"name\":\"App\",\"url\":\"$base/missing\"}]" "$open_app" '^issue edit 7 --body .*Down since: 2026-10-12T15:00:00Z'
scenario "back up: comments and closes the issue" \
  "[{\"name\":\"App\",\"url\":\"$base/ok.json\"}]" "$open_app" '^issue comment 7 --body Back up at .* Down since 2026-10-12T15:00:00Z'
scenario "back up: the issue is closed" \
  "[{\"name\":\"App\",\"url\":\"$base/ok.json\"}]" "$open_app" '^issue close 7$'
scenario "wrong environment fails the JSON check" \
  "[{\"name\":\"App\",\"url\":\"$base/staging.json\",\"expect\":\".environment == \\\"production\\\"\",\"show\":\"{environment}\"}]" "$none" 'issue create .*doesn.t match.*Got: \{"environment":"staging"\}'
scenario "HTML where JSON is expected fails" \
  "[{\"name\":\"App\",\"url\":\"$base/page.html\",\"expect\":\".status == \\\"ok\\\"\"}]" "$none" "issue create .*isn't JSON"
scenario "stale watcher opens an issue" \
  "[{\"name\":\"App\",\"url\":\"$base/stale.json\",\"expect\":\".monitor.status != \\\"stale\\\"\",\"only_when_up\":true}]" "$none" 'issue create --title Down: App'
scenario "watcher check stays quiet when the app itself is down" \
  "[{\"name\":\"App\",\"url\":\"$base/missing\",\"expect\":\".monitor.status != \\\"stale\\\"\",\"only_when_up\":true}]" "$none" -none
scenario "disabled targets are skipped" \
  "[{\"name\":\"App\",\"url\":\"$base/missing\",\"enabled\":false}]" "$none" -none
scenario "an issue for another target is left alone" \
  "[{\"name\":\"Vault\",\"url\":\"$base/ok.json\"}]" "$open_app" -none
MENTIONS="@example-team" scenario "ALERT_MENTIONS is added to new issues" \
  "[{\"name\":\"App\",\"url\":\"$base/missing\"}]" "$none" 'cc @example-team'
CERT_DAYS=100000 scenario "a certificate close to expiry opens an issue (needs network)" \
  '[{"name":"App","url":"https://github.com/"}]' "$none" 'issue create .*TLS certificate for github.com expires within 100000 days'
scenario "a healthy certificate passes (needs network)" \
  '[{"name":"App","url":"https://github.com/"}]' "$none" -none

if ((failures > 0)); then echo "$failures scenario(s) failed"; exit 1; fi
echo "all scenarios passed"
