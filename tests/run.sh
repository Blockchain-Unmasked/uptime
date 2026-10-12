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

fail() {
  echo "FAIL  $1: $2"
  sed 's/^/        /' "$tmp/out"
  failures=$((failures + 1))
}

# scenario <description> <targets json> <open issues json> <expectation>...
# Each expectation is a regex one logged gh call must match, "!regex" for one
# none may match, or "-none" for no issue calls at all. EXIT sets the expected
# exit code (default 0).
scenario() {
  local desc="$1" targets="$2" issues="$3" rc=0 log e
  shift 3
  printf '%s' "$targets" >"$tmp/targets.json"
  printf '%s' "$issues" >"$tmp/issues.json"
  : >"$tmp/gh.log"
  TARGETS="$tmp/targets.json" FAKE_ISSUES="$tmp/issues.json" FAKE_GH_LOG="$tmp/gh.log" \
    GH="$PWD/tests/fake-gh" ATTEMPTS=2 RETRY_DELAY=0 CERT_WARN_DAYS="${CERT_DAYS:-14}" \
    SLACK_WEBHOOK_URL="" ALERT_MENTIONS="${MENTIONS:-}" ./check.sh >"$tmp/out" 2>&1 || rc=$?
  if ((rc != ${EXIT:-0})); then fail "$desc" "exit $rc, expected ${EXIT:-0}"; return; fi
  log="$(grep -v '^label create' "$tmp/gh.log" || true)"
  for e in "$@"; do
    if [[ "$e" == "-none" ]]; then
      [[ -z "$log" ]] || { fail "$desc" "expected no issue calls, got: $log"; return; }
    elif [[ "$e" == !* ]]; then
      ! grep -Eq -- "${e#!}" <<<"$log" || { fail "$desc" "didn't expect /${e#!}/, got: $log"; return; }
    else
      grep -Eq -- "$e" <<<"$log" || { fail "$desc" "expected /$e/, got: ${log:-nothing}"; return; }
    fi
  done
  echo "ok    $desc"
}

none='[]'
open_app='[{"number":7,"title":"Down: App","createdAt":"2026-10-12T15:00:00Z"}]'
open_cert='[{"number":8,"title":"Certificate expiring: App","createdAt":"2026-10-12T15:00:00Z"}]'
app() { printf '[{"name":"App","url":"%s"%s}]' "$1" "${2:+,$2}"; }

scenario "healthy target, no issue: nothing happens" "$(app "$base/ok.json" '"expect":".status == \"ok\""')" "$none" -none
scenario "404 opens an issue" "$(app "$base/missing")" "$none" '^issue create --title Down: App --label outage --body .*HTTP 404'
scenario "unreachable host opens an issue" "$(app "http://127.0.0.1:9/")" "$none" '^issue create --title Down: App .*No response'
scenario "still down: refreshes the open issue instead of opening another" "$(app "$base/missing")" "$open_app" \
  '^issue edit 7 --body .*First seen: 2026-10-12T15:00:00Z' '!issue create'
scenario "back up: comments and closes the issue" "$(app "$base/ok.json")" "$open_app" \
  '^issue comment 7 --body Resolved at .* First seen 2026-10-12T15:00:00Z' '^issue close 7$'
scenario "wrong environment fails the JSON check" \
  "$(app "$base/staging.json" '"expect":".environment == \"production\"","show":"{environment}"')" "$none" \
  'issue create .*doesn.t match: \.environment == "production"\. Got: \{"environment":"staging"\}'
scenario "HTML where JSON is expected fails" "$(app "$base/page.html" '"expect":".status == \"ok\""')" "$none" "issue create .*isn't JSON"
scenario "stale watcher opens an issue" "$(app "$base/stale.json" '"expect":".monitor.status != \"stale\"","only_when_up":true')" "$none" \
  'issue create --title Down: App'
scenario "watcher check stays quiet when the app itself is down" \
  "$(app "$base/missing" '"expect":".monitor.status != \"stale\"","only_when_up":true')" "$none" -none
scenario "disabled targets are skipped" "$(app "$base/missing" '"enabled":false')" "$none" -none
scenario "a manually filed outage issue is left alone" "$(app "$base/ok.json")" \
  '[{"number":9,"title":"Database slow","createdAt":"2026-10-12T15:00:00Z"}]' -none
MENTIONS="@example-team" scenario "ALERT_MENTIONS is added to new issues" "$(app "$base/missing")" "$none" 'cc @example-team'

# Review fixes on uptime#1.
EXIT=1 scenario "a jq typo is a config error, not an outage" \
  "[{\"name\":\"Typo\",\"url\":\"$base/ok.json\",\"expect\":\".status == \\\"ok\\\" and\"},{\"name\":\"App\",\"url\":\"$base/missing\"}]" "$none" \
  '!Down: Typo' '^issue create --title Down: App'
EXIT=1 scenario "a config error keeps that target's open issue open" \
  "[{\"name\":\"App\",\"url\":\"$base/ok.json\",\"show\":\"{\"}]" "$open_app" -none
# shellcheck disable=SC2016 # backticks are literal here
scenario "response text can't break out of the code block or format the issue" \
  "$(app "$base/inject.json" '"expect":".status == \"ok\"","show":"{environment}"')" "$none" \
  '^issue create [^`]*```[^`]*@everyone \[login here\][^`]*```[^`]*$'
scenario "a target removed from targets.json has its issue closed" "[{\"name\":\"Vault\",\"url\":\"$base/ok.json\"}]" "$open_app" \
  '^issue comment 7 --body This target is no longer monitored' '^issue close 7$'
scenario "a target turned off has its issue closed" "$(app "$base/missing" '"enabled":false')" "$open_app" '^issue close 7$'
CERT_DAYS=100000 scenario "an expiring certificate opens a certificate issue, not a Down one (needs network)" \
  "$(app "https://github.com/")" "$none" \
  '^issue create --title Certificate expiring: App .*is up, but its TLS certificate needs renewing.*expires in [0-9]+ day' '!Down: App'
scenario "a renewed certificate closes the certificate issue (needs network)" "$(app "https://github.com/")" "$open_cert" '^issue close 8$'
scenario "a certificate issue stays open while the target is down" "$(app "$base/missing")" "$open_cert" '!issue close 8' '!comment 8'
scenario "a healthy certificate passes (needs network)" "$(app "https://github.com/")" "$none" -none

# --validate
printf '[{"name":"A","url":"https://a"},{"name":"B","url":"https://b","show":".x |"}]' >"$tmp/bad.json"
if TARGETS="$tmp/bad.json" ./check.sh --validate >"$tmp/out" 2>&1; then fail "--validate rejects a bad expression" "exited 0"
elif ! grep -q "target 2 (B): show isn't a valid jq expression" "$tmp/out"; then fail "--validate rejects a bad expression" "wrong message"
else echo "ok    --validate rejects a bad expression"; fi
if ./check.sh --validate >"$tmp/out" 2>&1; then echo "ok    --validate accepts targets.json"; else fail "--validate accepts targets.json" "exited non-zero"; fi

if ((failures > 0)); then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "all scenarios passed"
