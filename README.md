# Uptime

Checks OCINT production every 5 minutes and opens an issue in this repo when something stops answering. It runs on GitHub Actions, so it keeps working when the hosting account it watches has a problem.

## What it checks

The targets live in [`targets.json`](targets.json):

| Target | URL | Passes when |
|---|---|---|
| Sherlock app | `https://app.ocint.com/api/health` | 200, `status` is `ok`, `environment` is `production` |
| Sherlock movement watcher | same | the watcher isn't `stale` (skipped while the app itself is down) |
| Sherlock chain data (Etherscan) | same | `intel_clients.chaindata` isn't `failing`, meaning Etherscan's recent answers weren't errors such as a dead key (skipped while the app is down) |
| Evidence Vault | `https://vault.ocint.com/health` | 200, `status` is `ok` |
| ocint.com | `https://ocint.com/` | 200 (turned off until the site is live) |
| Sherlock staging | `https://staging.ocint.com/api/health` | 200, `environment` is `staging` (turned off until staging has this hostname) |

A hostname that stops resolving, a refused connection and a timeout all count as down. Every HTTPS target also gets a certificate check while it's up.

## How alerts work

A target counts as down only when it fails twice in a row, a minute apart, so a single blip doesn't alert anyone. Then:

- **Down:** an issue titled `Down: <target>` opens with the `outage` label. Everyone watching this repo gets an email.
- **Still down:** the same issue is updated on each run with the latest failure. No new email.
- **Resolved:** a comment says when it passed again, and the issue closes. Watchers get that email too.

A TLS certificate that expires within 14 days opens a separate `Certificate expiring: <target>` issue, which closes once the certificate is renewed.

Issues for a target that's removed from `targets.json` or turned off are closed with a note, since nothing would ever resolve them. Issues filed by hand with the `outage` label are left alone.

What a target sent back (an error, part of a response) is shown in a code block, so it can't format the issue or mention anyone.

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
| `name` | required | Shown in the issue title. Renaming closes the old name's open issue as no longer monitored; if the target is still down, an issue opens under the new name. |
| `url` | required | The URL to request. |
| `status` | `200` | The HTTP status that counts as up. |
| `expect` | none | A `jq` expression the JSON response must satisfy. |
| `show` | none | A `jq` expression whose output goes in the issue when `expect` fails. |
| `only_when_up` | `false` | Only fail on `expect`. Use it for a check that piggybacks on another target's URL so one outage doesn't open two issues. |
| `cert` | `true` | Check the TLS certificate's expiry. |
| `enabled` | `true` | Set to `false` to skip the target. |

`./check.sh --validate` checks the file (every target has a name and URL, and the `jq` expressions compile), and the Test workflow runs it on every pull request. If a broken expression reaches `main` anyway, that target is skipped and the Uptime run fails with the error instead of reporting a false outage.

Only public URLs go here. This repo is public (that's what makes the Actions minutes free), so never add secrets, tokens or internal hostnames.

## Testing

```bash
./tests/run.sh
```

This runs `check.sh` against a local web server and a stand-in for the `gh` CLI, and checks which issue it opens, updates or closes in each case: a 404, an unreachable host, a wrong `environment`, a non-JSON body, a stale watcher, an expiring certificate, a recovery, a typo in `targets.json`, a response that tries to format the issue, a removed target and so on. The Test workflow runs it on every pull request.

To run the real checks now instead of waiting for the schedule: **Actions > Uptime > Run workflow**.

## Keeping the schedule alive

GitHub turns off scheduled workflows in a public repo after 60 days without a commit. When the last commit is 45 days old, the Uptime workflow's `keepalive` job commits today's date to `.keepalive`, which resets that clock. It's the only job that can push; the checks run with read access to the code and write access to issues only. If `main` ever gets branch protection, let `github-actions[bot]` push or this step will fail.
