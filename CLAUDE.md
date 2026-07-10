# Perfai-Security — Guide

## 1. Purpose

Published GitHub **composite Action** ("Perfai Actions") that runs a Perfai security scan from a CI/CD pipeline. It wraps a single bash script (`multiple-service-deploy.sh`) that authenticates to the Perfai cloud API, triggers a `sensitive_data` chain-execution against an app catalog, optionally waits for completion, and prints the resulting security-issue summary. Consumes the public API at `api.perfai.ai`; **not a deployed service** — no Docker image, no Kubernetes. Sibling to `cicd-integrations`.

## 2. Repo Structure

```
action.yml                    Composite Action — declares inputs, runs the script via ${GITHUB_ACTION_PATH}
multiple-service-deploy.sh    Core bash script — auth, chain-execution, poll, fetch issues
README.md                     Marketing / quickstart (legacy generic content — see §8)
```

## 3. How It Works (step-by-step)

`action.yml` (composite) `chmod +x`es the script, then runs it with the mapped inputs. `multiple-service-deploy.sh` then:

1. **Auth** — POST `https://api.perfai.ai/api/v1/auth/token` (header `x-org-id: <orgId>`, body `{username,password}`) → extracts `id_token` as the bearer token.
2. **Vision-agent scan** — present but **commented out / disabled** (the `vision-agent-tasks/*` calls).
3. **Chain-execution** — POST `https://api.perfai.ai/chain-execution/execute` with `catalog_id` + a single-step `chain_config`: `step_id: sensitive_data_run`, `service: sensitive_data`, `mode: run`, `is_critical: true`, plus a fixed `categories_to_run` list (~30 checks: `Authorization_*`, `RBAC`, `DB_Read/Write`, `BOLA*`, `SSRF`, `CORS_Exist`, `Privilege_Escalation`, token/logout checks, …). Captures `chain_execution_id`.
4. **Wait** (when `wait-for-completion=true`) — poll GET `https://api.perfai.ai/chain-execution/chain/<id>` every 30s until `status` leaves `PENDING`/`RUNNING` (≤3 retries on empty/non-JSON responses). On success: GET `/api/v1/api-catalog/apps/summary/<catalogId>` → `sensitive_app_id`, then poll GET `/api/v1/sensitive-data-service/apps/app_issues_security?app_id=<sensitive_app_id>&page=1&pageSize=100&sortBy=severity&sortOrder=DESC` for up to ~5 min and print totals (total / critical / high / medium-low / bounty savings). On `FAILED` or an unexpected status → `exit 1`. When `wait-for-completion=false` → print the chain id and `exit 0`.

## 4. Inputs (`action.yml`)

| Input | Required | Default | Consumed by script? |
|---|---|---|---|
| `username` | yes | — | ✅ auth |
| `password` | yes | — | ✅ auth |
| `orgId` | yes | — | ✅ `x-org-id` header |
| `catalogId` | yes | — | ✅ chain-execution + summary |
| `appId` | yes | — | ❌ not parsed by the script (see §8) |
| `wait-for-completion` | no | `"true"` | ✅ gates the polling block |
| `fail-on-new-leaks` | no | `"false"` | ❌ parsed but never referenced (see §8) |

## 5. Outputs & Build Gating

No `outputs:` are declared — results are printed to the Actions log. Pass/fail is by **exit code**: the script exits non-zero on auth failure, a missing `chain_execution_id`, chain `status=FAILED`, an unexpected terminal status, repeated bad API responses, or a missing `sensitive_app_id`. It does **not** currently fail based on issue count or severity.

## 6. API Consumed — `api.perfai.ai`

| Purpose | Method + Path |
|---|---|
| Login | POST `/api/v1/auth/token` |
| Start scan | POST `/chain-execution/execute` |
| Poll status | GET `/chain-execution/chain/<id>` |
| Resolve app | GET `/api/v1/api-catalog/apps/summary/<catalogId>` |
| Fetch issues | GET `/api/v1/sensitive-data-service/apps/app_issues_security` |

All hosts are hardcoded to `api.perfai.ai` (the `--hostname` arg is parsed but unused).

## 7. Local / Direct Script Usage

```bash
chmod +x multiple-service-deploy.sh
./multiple-service-deploy.sh \
  --username "you@example.com" --password "…" \
  --orgId "<orgId>" --catalogId "<catalogId>" \
  --wait-for-completion true
```

Requires `curl` and `jq` on PATH.

## 8. Known Gaps / Gotchas (current state)

- **`appId` is not wired.** `action.yml` passes `--appId`, but it is absent from the script's `getopt` long-option list, so on util-linux `getopt` (GitHub `ubuntu-latest`) the call returns `unknown option -- appId` (exit 1) and the script aborts before auth. The issues app id is derived from the catalog summary (`sensitive_app_id`) instead — `appId` is not needed.
- **`fail-on-new-leaks` is a no-op** — parsed into `FAIL_ON_NEW_LEAKS` but never referenced; the build is not gated on findings.
- **Bearer token is echoed to the CI log** — the script prints `Access Token is: $ACCESS_TOKEN`. Remove it; never echo the token / `--password` / `Authorization` headers.
- **Vestigial args** — `hostname`, `openApiUrl`, `basePath`, `label`, `appUrl`, and the `authentication*` / `authorizationHeaders*` options are parsed but unused (template leftovers).
- **`README.md` is legacy** — it documents an unrelated `docker://…/perfai-engine` action with `apiSpecURL`/`licenseKey` inputs and does not match `action.yml`.

## 9. Logging & Error Handling (script & Action)

> **Directive for Claude Code:** On every change to the script or `action.yml`, make failures loud and meaningful — **especially error paths.** A security gate that fails silently (or passes when it should fail) is worse than no gate.

- **Check every external call.** Capture the curl exit status and the response, and on failure print a clear message and `exit 1` (the script already does this for auth, chain-execution, status polling, and issue fetch — keep the pattern).
- **Log progress at each phase** (auth, chain started, status transitions, issues ready) so CI logs are followable; the status poller already de-dupes repeated snapshots.
- **Never echo secrets into CI logs.** ⚠️ The script currently prints the bearer token — remove it, and never echo `--password`, the `id_token`/`ACCESS_TOKEN`, or `Authorization` headers. Mark secret inputs as masked in the calling workflow.
- **Exit codes are the contract.** Return non-zero on any failure so the pipeline fails; return `0` only on a successful (or intentionally non-waiting) run.

## 10. Keeping This File Current (Docs-as-Code)

> **Directive for Claude Code:** This `CLAUDE.md` is part of the repo, not separate documentation. When a change you make renders anything here inaccurate, update this file **in the same PR — automatically, without being asked.**

**Update this file in the same PR when a change affects:** repo structure (§2), the scan flow / API calls (§3, §6), the Action inputs (§4), outputs / build gating (§5), or the error-handling conventions (§9).

**Current-state only — never a changelog.** Do **not** add audit history, dated entries, or "previously X, now Y" notes. Describe how the Action works *now*; "what changed and when" belongs in git history and the PR description. When a fact stops being true, replace or delete it.

Keep edits surgical and consistent with the existing format; keep this file concise.
