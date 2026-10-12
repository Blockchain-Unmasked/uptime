# Uptime

Checks OCINT production every 5 minutes and opens an issue in this repo when something stops answering. It runs on GitHub Actions, so it keeps working when the hosting account it watches has a problem.

## What it checks

The targets live in [`targets.json`](targets.json):

| Target | URL | Passes when |
|---|---|---|
| Sherlock app | `https://app.ocint.com/api/health` | 200, `status` is `ok`, `environment` is `production` |
| Sherlock movement watcher | same | the watcher isn't `stale` (skipped while the app itself is down) |
| Evidence Vault | `https://vault.ocint.com/health` | 200, `status` is `ok` |
| ocint.com | `https://ocint.com/` | 200 (turned off until the site is live) |
| Sherlock staging | `https://staging.ocint.com/api/health` | 200, `environment` is `staging` (turned off until staging has this hostname) |

Every HTTPS target also fails when its TLS certificate expires within 14 days. A hostname that stops resolving, a refused connection and a timeout all count as down.

## How alerts work

A target counts as down only when it fails twice in a row, a minute apart, so a single blip doesn't alert anyone. Then:

- **Down:** an issue titled `Down: <target>` opens with the `outage` label. Everyone watching this repo gets an email.
- **Still down:** the same issue is updated on each run with the latest failure. No new email.
- **Back up:** a comment says when it recovered, and the issue closes. Watchers get that email too.

To get the emails, watch this repo: **Watch > Custom > Issues**.

Optional settings (Settings > Secrets and variables > Actions):

| Name | Kind | What it does |
|---|---|---|
| `ALERT_MENTIONS` | variable | Added to each new outage issue, e.g. `@org/oncall @someone`, so they're notified even without watching. |
| `SLACK_WEBHOOK_URL` | secret | Posts down and recovery messages to a Slack channel through an incoming webhook. |

## Adding or changing a target

Edit `targets.json`. Each entry takes:

| Field | Default | Meaning |
|---|---|---|
| `name` | required | Shown in the issue title. Changing it orphans an open issue, so rename only while the target is up. |
| `url` | required | The URL to request. |
| `status` | `200` | The HTTP status that counts as up. |
| `expect` | none | A `jq` expression the JSON response must satisfy. |
| `show` | none | A `jq` expression whose output goes in the issue when `expect` fails. |
| `only_when_up` | `false` | Only fail on `expect`. Use it for a check that piggybacks on another target's URL so one outage doesn't open two issues. |
| `cert` | `true` | Check the TLS certificate's expiry. |
| `enabled` | `true` | Set to `false` to skip the target. |

Only public URLs go here. This repo is public (that's what makes the Actions minutes free), so never add secrets, tokens or internal hostnames.

## Testing

```bash
./tests/run.sh
```

This runs `check.sh` against a local web server and a stand-in for the `gh` CLI, and checks which issue it opens, updates or closes in each case: a 404, an unreachable host, a wrong `environment`, a non-JSON body, a stale watcher, an expiring certificate, a recovery and so on. The Test workflow runs it on every pull request.

To run the real checks now instead of waiting for the schedule: **Actions > Uptime > Run workflow**.

## Keeping the schedule alive

GitHub turns off scheduled workflows in a public repo after 60 days without a commit. When the last commit is 45 days old, the Uptime workflow commits today's date to `.keepalive`, which resets that clock. If `main` ever gets branch protection, let `github-actions[bot]` push or this step will fail.
