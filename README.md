# Calibrate Agent Tests — GitHub Action

Run [Calibrate](https://calibrate.example) agent tests from CI. Trigger all tests
linked to one or more agents, wait for them to finish, and either **gate** the
build on failures or just **report** the numbers. On pull requests it
auto-posts a per-agent summary comment (Codecov-style — one comment, updated in
place).

It talks only to the Calibrate REST API using an **API key**, so there's nothing
to install on the runner beyond `curl` and `jq` (both present on
`ubuntu-latest`).

> This is a composite action (a single `run.sh` driving the Calibrate REST API).
> Pin it by tag: `artpark/calibrate-github-action@v1`.

## Setup

1. **Create an API key** in Calibrate: `POST /api-keys` (or the UI), scoped to
   the workspace/org that owns your agents. The raw `sk_…` key is shown
   **once** — copy it.
2. **Add it as a repo secret**, e.g. `CALIBRATE_API_KEY`.
3. **Add a workflow** (below). Grant `pull-requests: write` if you want the PR
   comment.

## Usage

```yaml
# .github/workflows/calibrate.yml
name: Calibrate
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  pull-requests: write   # needed only for the PR comment

jobs:
  agent-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: artpark/calibrate-github-action@v1
        with:
          api-key: ${{ secrets.CALIBRATE_API_KEY }}
          base-url: https://api.calibrate.example
          app-url: https://app.calibrate.example   # optional, for report links
          agents: 7f3c…,9a21…                       # one or more agent UUIDs
          mode: gate                                # gate | report
```

## Inputs

| Input          | Required | Default            | Description |
|----------------|----------|--------------------|-------------|
| `api-key`      | yes      | —                  | `sk_…` key. Use a secret. |
| `agents`       | yes      | —                  | Comma-separated agent UUIDs. Runs **all** tests linked to each. |
| `base-url`     | yes      | —                  | Calibrate backend API base URL. |
| `app-url`      | no       | `""`               | Web UI base URL; turns run IDs into `view` links in the report. |
| `mode`         | no       | `gate`             | `gate` fails the job on any test failure; `report` always succeeds. |
| `poll-interval`| no       | `5`                | Seconds between status polls. |
| `timeout`      | no       | `1800`             | Max seconds to wait for all runs to finish. |
| `github-token` | no       | `${{ github.token }}` | Token for the PR comment; needs `pull-requests: write`. |

## Outputs

| Output   | Description |
|----------|-------------|
| `total`  | Total test cases across all agents. |
| `passed` | Total passed. |
| `failed` | Total failed. |

## Behavior notes

- **`gate` vs `report`** — `gate` exits non-zero (red ❌ check) if any test
  fails, any run errors/times out, or an agent fails to start. `report` runs the
  same and prints the numbers but always exits 0.
- **PR comment** — posted automatically on `pull_request` events (no flag).
  It's found-or-updated via a hidden marker, so re-runs edit the same comment.
- **Scoping** — the API key is bound to one org; agents outside it return 404
  (the action reports them as "not started", which fails `gate` mode).
- **Auth header** — the key works as `Authorization: Bearer sk_…` or
  `X-API-Key: sk_…`; this action uses the latter.
