# CLAUDE.md

Guidance for working in this repository.

## What this is

A **composite GitHub Action** that runs [Calibrate](https://calibrate.artpark.ai)
agent tests in CI. Given one or more agent names, it triggers all tests linked to
each agent, polls them to completion, reports per-agent pass/fail, and either
**gates** the build (fails on any failure) or just **reports** the numbers. On
pull requests it posts/updates a single summary comment.

There is no build step and no compiled code — the action is a single bash script
driving the Calibrate REST API with `curl` + `jq`. "Releasing" is just pushing a
git tag (e.g. `v1`); consumers reference it as `ARTPARK-SAHAI-ORG/calibrate-github-action@v1`.

## Files

- **`action.yml`** — the action manifest: declares `inputs`, `outputs`, and maps
  each input into a `CALIBRATE_*` env var that `run.sh` reads. This is the
  input/output contract.
- **`run.sh`** — all the logic. Reads env vars, resolves names → UUIDs, triggers
  runs, polls, aggregates, writes the report, posts the PR comment, sets the exit
  code.
- **`README.md`** — user-facing docs. Written for a **new user** in plain
  language; keep it minimal.
- **`examples/specific-agents.yml`** / **`examples/all-agents.yml`** — consumer
  workflows to copy into their repo: one naming specific agents, one omitting
  `agents` to run every agent on the key.

## How a value flows through

```
consumer workflow `with:` → action.yml `inputs.*` (applies defaults)
  → action.yml `env:` (CALIBRATE_*) → run.sh reads the env var
  → run.sh writes `name=value` to $GITHUB_OUTPUT → action.yml `outputs.*`
```

So inputs/defaults live in `action.yml`; behavior lives in `run.sh`. Keep
defaults in **one** place — `action.yml` is the source of truth for default URLs;
`run.sh` trusts the env var is set.

## Backend API (Calibrate REST, auth via `X-API-Key`)

- `POST /agents/resolve` — body `{"names": [...]}`, returns
  `{"resolved": {name: uuid}, "not_found": [...]}`. Org-scoped by the API key;
  names are unique per org. Used to turn agent names into UUIDs.
- `GET /agents` — no params; lists every agent for the API key as a bare array
  `[{"uuid": ..., "name": ..., ...}, ...]`. Used when the `agents` input is
  omitted; both name and UUID come back so no resolve is needed. Empty org →
  `[]`; bad key → `401`.
- `POST /agent-tests/agent/{uuid}/run` — triggers all tests linked to the agent;
  returns `{"task_id": ...}`.
- `GET /agent-tests/run/{task_id}` — run status; terminal states are `done`,
  `failed`, `cancelled`; carries `total_tests`, `passed`, `failed`.

Status-code conventions the script relies on: **401/403** = bad/missing key
(global → fatal); **404** = missing/out-of-org agent; **400** = unrunnable agent
(connection not verified, or no linked tests). Error bodies are FastAPI-style
`{"detail": "..."}`.

## Inputs (defined in `action.yml`)

| Input           | Required | Default                            | Notes                                                                     |
| --------------- | -------- | ---------------------------------- | ------------------------------------------------------------------------- |
| `api-key`       | yes      | —                                  | `sk_…`; pass via a repo secret.                                           |
| `agents`        | no       | _all agents_                       | Agent **names** (not UUIDs), comma- or newline-separated. Omit to run every agent on the key (via `GET /agents`). |
| `base-url`      | no       | `https://pense-backend.artpark.ai` | Backend API; override only for self-hosted.                               |
| `app-url`       | no       | `https://calibrate.artpark.ai`     | Web UI base for `view` links in the report.                               |
| `mode`          | no       | `gate`                             | `gate` fails on any problem; `report` always exits 0.                     |
| `poll-interval` | no       | `5`                                | Seconds between status polls.                                             |
| `timeout`       | no       | `1800`                             | Max seconds to wait for runs.                                             |
| `github-token`  | no       | `${{ github.token }}`              | For the PR comment; needs `pull-requests: write`. Not surfaced in README. |

## run.sh conventions (read before editing)

- **Agents are names only.** UUID input is intentionally **not** supported — every
  token is resolved via `POST /agents/resolve`. Don't reintroduce UUID
  passthrough.
- **`agents` is optional.** Given → resolve those names (explicit mode). Omitted →
  `GET /agents` lists every agent for the key and populates `LABELS`/`AGENTS`
  directly (no resolve). Both modes converge on the same `LABELS`/`AGENTS` arrays,
  so everything downstream (trigger/poll/report) is unchanged.
- **Fail fast on unresolved names.** In explicit mode, if any name doesn't
  resolve, the script prints each miss and exits `2` **before triggering any
  run**. Preserve this.
- **`LABELS` vs `AGENTS`.** Parallel indexed arrays: `LABELS[i]` is the
  user-typed agent name (used in all logs and the report); `AGENTS[i]` is the
  resolved UUID (used in API calls). Always show `LABELS` to users, never the
  raw UUID.
- **bash-3.2 compatible** (macOS default bash). Use parallel **indexed** arrays —
  no associative arrays (`declare -A`), no other bash-4+ features.
- **`api()` sets globals** `API_HTTP_STATUS` / `API_BODY`. Call it as a statement,
  never in `$(...)` — a subshell would discard the globals.
- **GitHub log conventions:** `::error::`, `::warning::`, `::group::`/`::endgroup::`.
- **Exit codes:** `0` ok (or `report` mode); `1` = `gate` failure (tests failed /
  problems); `2` = config/auth/usage error (missing dep, bad key, unresolved name).
- **Defaults stay in `action.yml`**, not duplicated in `run.sh`.

## Verifying changes

There's no test suite. After editing `run.sh`:

```bash
bash -n run.sh   # syntax check — always run this
```

The script only does real work against a live Calibrate backend + GitHub Actions
env, so full runtime testing happens in an actual workflow. Keep changes small and
syntax-checked.

## Docs style

`README.md` targets a **new user**: short sentences, plain language, no jargon
dumps. When changing behavior or inputs, update `README.md`, `action.yml`, and
the `examples/*.yml` workflows together so they stay consistent.
