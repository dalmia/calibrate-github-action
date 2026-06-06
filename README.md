# Calibrate GitHub Action

This action runs your [Calibrate](https://calibrate.artpark.ai) agent tests
automatically in GitHub.

You give it one or more agents. It runs all the tests attached to those agents,
waits for them to finish, and reports the results.

You can choose what happens when a test fails:

- **gate** (default) — the check fails, so a broken agent can block a merge.
- **report** — the check always passes; it just shows the numbers.

If the run is on a pull request, it also adds a comment to the PR with the
results. Re-running updates that same comment instead of adding a new one.

## Setup

1. Create an API key in the Calibrate UI.
2. In your GitHub repo, save it as a secret named `CALIBRATE_API_KEY`
   (Settings → Secrets and variables → Actions).
3. Add the workflow file below to your repo.

The workflow includes a `permissions` block that lets the action post its
results as a comment on your pull requests. Keep it if you want the PR comment;
remove it if you don't.

## Usage

```yaml
# .github/workflows/calibrate.yml
name: Calibrate
on: [pull_request]

permissions:
  contents: read
  pull-requests: write # for the PR comment

jobs:
  agent-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: ARTPARK-SAHAI-ORG/calibrate-github-action@v1
        with:
          api-key: ${{ secrets.CALIBRATE_API_KEY }}
          agents: checkout-bot, support-agent
```

You can also list agents one per line:

```yaml
agents: |
  checkout-bot
  support-agent
```

## Inputs

| Input           | Required | Default                            | Description                                                                      |
| --------------- | -------- | ---------------------------------- | -------------------------------------------------------------------------------- |
| `api-key`       | yes      | —                                  | `sk_…` key. Use a secret.                                                        |
| `agents`        | yes      | —                                  | Agent names, separated by commas or newlines. Runs **all** tests linked to each. |
| `base-url`      | no       | `https://pense-backend.artpark.ai` | Backend API. Override only for self-hosted.                                      |
| `app-url`       | no       | `https://calibrate.artpark.ai`     | Web UI base for `view` links in the report.                                      |
| `mode`          | no       | `gate`                             | `gate` fails the job on any failure; `report` always succeeds.                   |
| `poll-interval` | no       | `5`                                | Seconds between status polls.                                                    |
| `timeout`       | no       | `1800`                             | Max seconds to wait for runs to finish.                                          |

## Outputs

`total`, `passed`, `failed` — test-case counts across all agents.
