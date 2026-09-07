# Nightly Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the flow-workbench nightly Playwright run fails, start one `VmAgent` investigation per deduplicated failed studio test (capped at the VM pool size) and reply with the results under Flow Bot's Slack message.

**Architecture:** flow-workbench CI gains a `failed-tests.json` artifact (from the merged Playwright JSON report) and a job that starts the deployed `NightlyOrchestrator` process through the Orchestrator `StartJobs` API. `NightlyOrchestrator` is a second Maestro Flow in the existing `vm-agent` solution: filter + dedupe + cap in a script node, a `parallel: true` loop that calls the in-solution `VmAgent` flow node, and a Slack connector node that replies in-thread.

**Tech Stack:** GitHub Actions + bash/jq/curl; UiPath Maestro Flow (`uip maestro flow` CLI 1.201), `.flow` JSON; Integration Service Slack connector (`uipath-salesforce-slack`); Orchestrator OData API.

**Spec:** `docs/superpowers/specs/2026-09-07-nightly-orchestrator-design.md`

## Global Constraints

- Two repos. CI work goes on a branch of `~/code/flow-workbench` (trunk `develop`) and ends in a **draft PR**. Flow work commits straight to `~/code/vm-agent-investigator` `master`.
- Trigger inputs and defaults, verbatim from the spec: `projects` default `studio-*`; `maxTests` default `1`; `slackTs` default `""`; `repoUrl` default `https://github.com/UiPath/flow-workbench`; `branch` default `develop`.
- `maxTests` must equal the VM pool size (1 as of 2026-09-07). Never raise it in the flow; it is a trigger input.
- Slack channel: `C0AH25MT3L5`. Reply must go in-thread when `slackTs` is non-empty, top-level otherwise.
- Only tests whose Playwright test-level `status` is `unexpected` count as failed (retried-then-passed = `flaky`, excluded).
- CI additions must never turn the nightly red on their own: every new step is `continue-on-error` or exits 0 with a `::warning::`.
- `uip` must be logged in for every tenant-touching step (`uip login status`). If it says not logged in, stop and ask David to run `! uip login` (interactive, cannot be automated).
- Never hand-edit `bindings_v2.json`, `definitions[]` of connector nodes, or `layout`; run `uip maestro flow format` after every `.flow` edit.
- `release.sh` runs `uip solution pack`, which rewrites source files; the script already does `git checkout -- vm-agent/` afterwards. Keep that.
- Commit messages: imperative subject, no trailer besides `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## File map

flow-workbench (branch `feat/nightly-investigator-hook`):

- Create `.github/scripts/failed-tests.sh` — merged Playwright JSON → `failed-tests.json`.
- Create `.github/scripts/start-nightly-investigation.sh` — client-credentials token, resolve folder + release by name, `StartJobs`.
- Create `.github/scripts/tests/failed-tests.test.sh` + fixture `.github/scripts/tests/fixtures/merged-report.json`.
- Modify `.github/scripts/notify-slack-playwright.sh` — write `slack_ts` to `$GITHUB_OUTPUT`.
- Modify `.github/workflows/playwright-deploy.yml` — `--reporter html,json`, run `failed-tests.sh`, upload artifact `failed-tests`.
- Modify `.github/workflows/playwright-ci.yml` — `notify-failure` exposes `outputs.slack_ts`; new job `investigate-nightly`.

vm-agent-investigator (`master`):

- Create `vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow` (+ scaffold files from `uip maestro flow init`).
- Create `orchestrator/tests/select-tests.test.mjs` — runs the `selectTests` and `summarize` script sources extracted from the `.flow`.
- Create `inputs/orchestrator-34015558366.json` — sample trigger input from the 2026-09-06 nightly.
- Modify `deploy-config.json` — add the `NightlyOrchestrator` process resource.
- Modify `release.sh` — optional 3rd arg selects which process to start after deploy.
- Modify `HANDOFF.md` — one section on the orchestrator.

---

### Task 1: `failed-tests.sh` — merged report → failed-tests.json (flow-workbench)

**Files:**
- Create: `.github/scripts/failed-tests.sh`
- Create: `.github/scripts/tests/fixtures/merged-report.json`
- Create: `.github/scripts/tests/failed-tests.test.sh`

**Interfaces:**
- Produces: `failed-tests.json` = JSON array of `{ "project": string, "file": string, "title": string, "error": string }`. `file` is the path as Playwright reports it (relative to the config's `rootDir`, i.e. `specs/<dir>/<name>.spec.ts`; the flow prepends `e2e/`). `error` ≤ 500 chars, may be `""`.

- [ ] **Step 1: Create the branch**

```bash
cd ~/code/flow-workbench && git fetch origin develop && git checkout -b feat/nightly-investigator-hook origin/develop
```

- [ ] **Step 2: Write the fixture** (Playwright JSON reporter shape: nested `suites`, `specs[]` with `tests[]`; test-level `status` is `expected|unexpected|flaky|skipped`)

`.github/scripts/tests/fixtures/merged-report.json`:
```json
{
  "config": { "rootDir": "/work/e2e" },
  "suites": [
    {
      "title": "specs/data-transform/data-transform.spec.ts",
      "file": "specs/data-transform/data-transform.spec.ts",
      "suites": [
        {
          "title": "Data Transform",
          "file": "specs/data-transform/data-transform.spec.ts",
          "specs": [
            {
              "title": "should add a Map operation with field mappings",
              "file": "specs/data-transform/data-transform.spec.ts",
              "tests": [
                { "projectName": "studio-alpha", "status": "unexpected",
                  "results": [
                    { "status": "failed", "error": { "message": "attempt 1 error" } },
                    { "status": "failed", "error": { "message": "locator.click: <div class=\"neighbor-rail-downstream\"> intercepts pointer events" } }
                  ] },
                { "projectName": "studio-staging", "status": "expected",
                  "results": [ { "status": "passed" } ] }
              ]
            },
            {
              "title": "should write a Custom Script operation",
              "file": "specs/data-transform/data-transform.spec.ts",
              "tests": [
                { "projectName": "studio-alpha", "status": "flaky",
                  "results": [ { "status": "failed", "error": { "message": "x" } }, { "status": "passed" } ] }
              ]
            }
          ]
        }
      ]
    },
    {
      "title": "specs/mfe/mfe-edit.spec.ts",
      "file": "specs/mfe/mfe-edit.spec.ts",
      "specs": [
        {
          "title": "persists an edit",
          "file": "specs/mfe/mfe-edit.spec.ts",
          "tests": [
            { "projectName": "vsix-staging-linux", "status": "unexpected",
              "results": [ { "status": "timedOut", "error": { "message": "no project \"poc\" in this solution" } } ] },
            { "projectName": "vsix-staging-macos", "status": "unexpected",
              "results": [ { "status": "failed" } ] }
          ]
        }
      ]
    }
  ]
}
```

- [ ] **Step 3: Write the failing test**

`.github/scripts/tests/failed-tests.test.sh`:
```bash
#!/usr/bin/env bash
# Checks failed-tests.sh against the fixture. Run: bash .github/scripts/tests/failed-tests.test.sh
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp)"
../failed-tests.sh fixtures/merged-report.json "$out"

fail() { echo "FAIL: $1"; echo "got:"; cat "$out"; exit 1; }
[[ "$(jq length "$out")" == "3" ]] || fail "expected 3 rows (2 vsix + 1 studio; flaky and passing excluded)"
jq -e '.[0] == {project:"studio-alpha", file:"specs/data-transform/data-transform.spec.ts",
  title:"should add a Map operation with field mappings",
  error:"locator.click: <div class=\"neighbor-rail-downstream\"> intercepts pointer events"}' "$out" >/dev/null \
  || fail "studio-alpha row: last attempt's error, exact fields"
jq -e '.[2] == {project:"vsix-staging-macos", file:"specs/mfe/mfe-edit.spec.ts", title:"persists an edit", error:""}' "$out" >/dev/null \
  || fail "missing error must become empty string"
jq -e 'all(.[]; (.error | length) <= 500)' "$out" >/dev/null || fail "error must be capped at 500 chars"
echo "ok"
```

- [ ] **Step 4: Run it, confirm it fails**

```bash
chmod +x .github/scripts/tests/failed-tests.test.sh && bash .github/scripts/tests/failed-tests.test.sh
```
Expected: `../failed-tests.sh: No such file or directory`.

- [ ] **Step 5: Write the script**

`.github/scripts/failed-tests.sh`:
```bash
#!/usr/bin/env bash
# Reduce a Playwright JSON report to the tests that failed on their final attempt.
#
#   failed-tests.sh <merged-report.json> <failed-tests.json>
#
# A test-level status of "unexpected" means the last retry still failed; "flaky"
# (failed then passed) and "expected" are excluded. One row per (project, file, title);
# the error is the final attempt's message, capped at 500 chars, "" when absent.
set -euo pipefail
in="${1:?merged report json}"; out="${2:?output path}"
jq '[ .. | objects | select(has("specs")) | .specs[] | . as $spec
      | .tests[] | select(.status == "unexpected")
      | { project: .projectName,
          file: $spec.file,
          title: $spec.title,
          error: ((.results[-1].error.message // "") | .[0:500]) } ]' "$in" > "$out"
echo "failed-tests: $(jq length "$out") rows -> $out"
```

- [ ] **Step 6: Run the test, confirm it passes**

```bash
chmod +x .github/scripts/failed-tests.sh && bash .github/scripts/tests/failed-tests.test.sh
```
Expected: `failed-tests: 3 rows -> ...` then `ok`.

- [ ] **Step 7: Commit**

```bash
git add .github/scripts/failed-tests.sh .github/scripts/tests
git commit -m "ci: reduce the merged Playwright report to a failed-tests.json list"
```

---

### Task 2: Emit the `failed-tests` artifact from merge-reports (flow-workbench)

**Files:**
- Modify: `.github/workflows/playwright-deploy.yml` (the `Merge reports` step at ~line 38 and after `Upload merged HTML report` at ~line 42)

**Interfaces:**
- Produces: workflow artifact `failed-tests` containing `failed-tests.json` (Task 1 shape), 14-day retention.

- [ ] **Step 1: Add the json reporter to merge-reports**

Replace the `run:` line of the `Merge reports` step:
```yaml
        run: pnpm exec playwright merge-reports --config e2e/playwright.config.ts --reporter html,json ./all-blob-reports
        env:
          PLAYWRIGHT_HTML_OUTPUT_DIR: ${{ github.workspace }}/playwright-report
          PLAYWRIGHT_JSON_OUTPUT_FILE: ${{ github.workspace }}/merged-report.json
```

- [ ] **Step 2: Add the reduce + upload steps** directly after `Upload merged HTML report`:

```yaml
      # One row per test that failed on its final attempt. Consumed by the
      # investigate-nightly job in playwright-ci.yml, which hands the list to the
      # UiPath NightlyOrchestrator flow. Best-effort: never fails the deploy.
      - name: Extract failed tests
        continue-on-error: true
        run: ./.github/scripts/failed-tests.sh merged-report.json failed-tests.json

      - name: Upload failed-tests
        if: hashFiles('failed-tests.json') != ''
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4
        with:
          name: failed-tests
          path: failed-tests.json
          retention-days: 14
```

- [ ] **Step 3: Lint the workflow**

```bash
npx --yes action-validator .github/workflows/playwright-deploy.yml || python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/playwright-deploy.yml')); print('yaml ok')"
```
Expected: no error.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/playwright-deploy.yml
git commit -m "ci: publish failed-tests.json from the merged nightly report"
```

---

### Task 3: Slack `ts` output and the `investigate-nightly` job (flow-workbench)

**Files:**
- Modify: `.github/scripts/notify-slack-playwright.sh` (after the `RESPONSE=` check, ~line 75)
- Create: `.github/scripts/start-nightly-investigation.sh`
- Modify: `.github/workflows/playwright-ci.yml` (`notify-failure` job ~line 201; new job after it)

**Interfaces:**
- Consumes: artifact `failed-tests` (Task 2).
- Produces: Orchestrator job on process `NightlyOrchestrator` in folder `Shared/vm-agent 11` with `InputArguments` = `{ runId, sha, runUrl, reportUrl, slackTs, failedTests }` (`failedTests` = the array, not a string). Secrets `UIPATH_INVESTIGATOR_CLIENT_ID`, `UIPATH_INVESTIGATOR_CLIENT_SECRET`; repo variables `UIPATH_INVESTIGATOR_ORG`, `UIPATH_INVESTIGATOR_TENANT` (Task 9 creates them).

- [ ] **Step 1: Make the Slack script export the message ts**

Append after the `ok` check in `notify-slack-playwright.sh`, before the final echo:
```bash
# Expose the message ts so a later job can reply in this thread.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "slack_ts=$(echo "$RESPONSE" | jq -r '.ts // ""')" >> "$GITHUB_OUTPUT"
fi
```
Also add to the header comment's env list: `GITHUB_OUTPUT — when set, the posted message ts is written as slack_ts`.

- [ ] **Step 2: Write the start script**

`.github/scripts/start-nightly-investigation.sh`:
```bash
#!/usr/bin/env bash
# Start the UiPath NightlyOrchestrator flow for a failed nightly.
#
# Resolves the folder and the process release by name so only the org/tenant and the
# external-app credentials are configuration. Exits 0 with a ::warning:: on any
# failure: this must never turn the nightly red.
#
# Env: UIPATH_ORG, UIPATH_TENANT, UIPATH_CLIENT_ID, UIPATH_CLIENT_SECRET,
#      RUN_ID, SHA, RUN_URL, REPORT_URL, SLACK_TS (may be empty),
#      FAILED_TESTS_FILE (path to failed-tests.json)
# Optional: UIPATH_FOLDER (default "Shared/vm-agent 11"), UIPATH_PROCESS (default NightlyOrchestrator)
set -uo pipefail
warn() { echo "::warning::start-nightly-investigation: $*"; exit 0; }
for v in UIPATH_ORG UIPATH_TENANT UIPATH_CLIENT_ID UIPATH_CLIENT_SECRET RUN_ID SHA RUN_URL FAILED_TESTS_FILE; do
  [[ -n "${!v:-}" ]] || warn "$v not set, skipping"
done
[[ -s "$FAILED_TESTS_FILE" ]] || warn "no failed-tests.json, skipping"
FOLDER="${UIPATH_FOLDER:-Shared/vm-agent 11}"; PROCESS="${UIPATH_PROCESS:-NightlyOrchestrator}"
BASE="https://cloud.uipath.com/${UIPATH_ORG}/${UIPATH_TENANT}/orchestrator_"

TOKEN="$(curl -sS -X POST https://cloud.uipath.com/identity_/connect/token \
  -d grant_type=client_credentials -d "client_id=${UIPATH_CLIENT_ID}" \
  -d "client_secret=${UIPATH_CLIENT_SECRET}" -d "scope=OR.Jobs OR.Folders OR.Execution" \
  | jq -r '.access_token // empty')" || true
[[ -n "$TOKEN" ]] || warn "token request failed"
auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

FOLDER_ID="$(curl -sS "${auth[@]}" --get "${BASE}/odata/Folders" \
  --data-urlencode "\$filter=FullyQualifiedName eq '${FOLDER}'" | jq -r '.value[0].Id // empty')"
[[ -n "$FOLDER_ID" ]] || warn "folder '${FOLDER}' not found"
RELEASE_KEY="$(curl -sS "${auth[@]}" -H "X-UIPATH-OrganizationUnitId: ${FOLDER_ID}" --get "${BASE}/odata/Releases" \
  --data-urlencode "\$filter=Name eq '${PROCESS}'" | jq -r '.value[0].Key // empty')"
[[ -n "$RELEASE_KEY" ]] || warn "process '${PROCESS}' not found in '${FOLDER}'"

# InputArguments is a JSON *string* inside the body.
ARGS="$(jq -c --arg runId "$RUN_ID" --arg sha "$SHA" --arg runUrl "$RUN_URL" \
  --arg reportUrl "${REPORT_URL:-}" --arg slackTs "${SLACK_TS:-}" \
  '{runId:$runId, sha:$sha, runUrl:$runUrl, reportUrl:$reportUrl, slackTs:$slackTs, failedTests:.}' "$FAILED_TESTS_FILE")"
BODY="$(jq -n --arg key "$RELEASE_KEY" --arg args "$ARGS" \
  '{startInfo:{ReleaseKey:$key, Strategy:"ModernJobsCount", JobsCount:1, InputArguments:$args}}')"
RESP="$(curl -sS "${auth[@]}" -H "X-UIPATH-OrganizationUnitId: ${FOLDER_ID}" \
  -X POST "${BASE}/odata/Jobs/UiPath.Server.Configuration.OData.StartJobs" --data "$BODY")"
JOB="$(echo "$RESP" | jq -r '.value[0].Key // empty')"
[[ -n "$JOB" ]] || warn "StartJobs failed: $(echo "$RESP" | jq -c . 2>/dev/null || echo "$RESP")"
echo "Started ${PROCESS} job ${JOB} with $(jq length "$FAILED_TESTS_FILE") failed tests."
```

- [ ] **Step 3: Smoke-test the script's guard paths locally** (no network needed)

```bash
chmod +x .github/scripts/start-nightly-investigation.sh
UIPATH_ORG=x UIPATH_TENANT=x UIPATH_CLIENT_ID=x UIPATH_CLIENT_SECRET=x RUN_ID=1 SHA=abc RUN_URL=u \
  FAILED_TESTS_FILE=/nonexistent .github/scripts/start-nightly-investigation.sh; echo "exit=$?"
```
Expected: `::warning::start-nightly-investigation: no failed-tests.json, skipping` and `exit=0`.

- [ ] **Step 4: Wire the workflow**

In `playwright-ci.yml`, give `notify-failure` an output. Add under `notify-failure:` after `permissions:`:
```yaml
    outputs:
      slack_ts: ${{ steps.slack.outputs.slack_ts }}
```
and add `id: slack` to its `Post to Slack` step.

Add a new job after `notify-failure`:
```yaml
  # ── hand failures to the VM investigator ────────────────
  # Starts the UiPath NightlyOrchestrator flow with the failed-tests list from the
  # deploy job. The flow runs VmAgent per failed studio test and replies in the
  # Slack thread above. Best-effort by construction: the script exits 0 on any
  # problem, so this job can never turn the nightly red.
  investigate-nightly:
    name: Start nightly investigation
    needs: [deploy, notify-failure]
    if: always() && github.event_name == 'schedule' && needs.notify-failure.result == 'success'
    runs-on: uipath-ubuntu-latest
    permissions:
      contents: read
      actions: read
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4
      - name: Download failed-tests
        continue-on-error: true
        uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093  # v4
        with:
          name: failed-tests
      - name: Start NightlyOrchestrator
        env:
          UIPATH_ORG: ${{ vars.UIPATH_INVESTIGATOR_ORG }}
          UIPATH_TENANT: ${{ vars.UIPATH_INVESTIGATOR_TENANT }}
          UIPATH_CLIENT_ID: ${{ secrets.UIPATH_INVESTIGATOR_CLIENT_ID }}
          UIPATH_CLIENT_SECRET: ${{ secrets.UIPATH_INVESTIGATOR_CLIENT_SECRET }}
          RUN_ID: ${{ github.run_id }}
          SHA: ${{ github.sha }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          REPORT_URL: https://theater.uipath.co/flow/${{ github.sha }}/
          SLACK_TS: ${{ needs.notify-failure.outputs.slack_ts }}
          FAILED_TESTS_FILE: failed-tests.json
        run: ./.github/scripts/start-nightly-investigation.sh
```

`notify-failure` only runs on `schedule`, so a `workflow_dispatch` test needs a temporary override: for the end-to-end test in Task 9, dispatch with `github.event_name == 'schedule'` conditions relaxed on the branch is NOT allowed (it would spam Slack). Instead Task 9 tests the script directly from a laptop with the same env.

- [ ] **Step 5: Validate YAML and commit**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/playwright-ci.yml')); print('yaml ok')"
git add .github/scripts/notify-slack-playwright.sh .github/scripts/start-nightly-investigation.sh .github/workflows/playwright-ci.yml
git commit -m "ci: start the UiPath nightly investigation flow after a red nightly"
```

- [ ] **Step 6: Push and open the draft PR**

```bash
git push -u origin feat/nightly-investigator-hook
gh pr create --draft --base develop --title "ci: hand nightly Playwright failures to the VM investigator flow" --body "$(cat <<'MD'
## Problem
A red nightly is triaged by hand (or by a read-only Claude routine) and nothing reproduces or fixes the failing tests automatically.

## Solution
The merge-reports job now also emits `failed-tests.json` (final-attempt failures only). After the Slack alert, a new `investigate-nightly` job starts the UiPath `NightlyOrchestrator` flow with that list and the Slack message `ts`; the flow runs one `VmAgent` investigation per failed studio test on the robot VM and replies in the Slack thread with reproduction status and any draft PR it opened.

<details><summary>Details</summary>

- `.github/scripts/failed-tests.sh` reduces the Playwright JSON report; tested by `.github/scripts/tests/failed-tests.test.sh`.
- `.github/scripts/start-nightly-investigation.sh` resolves folder and release by name and calls `StartJobs`. It exits 0 with a `::warning::` on any failure, so it cannot turn the nightly red.
- New repo variables `UIPATH_INVESTIGATOR_ORG` / `UIPATH_INVESTIGATOR_TENANT` and secrets `UIPATH_INVESTIGATOR_CLIENT_ID` / `UIPATH_INVESTIGATOR_CLIENT_SECRET` (external app, client credentials, scopes `OR.Jobs OR.Folders OR.Execution`).
- Flow side lives in https://github.com/david-rios-uipath/vm-agent-investigator.
</details>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
MD
)"
```

---

### Task 4: Scaffold `NightlyOrchestrator` with trigger inputs and `selectTests` (vm-agent-investigator)

**Files:**
- Create: `vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow` (via `uip maestro flow init`)
- Create: `orchestrator/tests/select-tests.test.mjs`
- Create: `inputs/orchestrator-34015558366.json`

**Interfaces:**
- Produces: node `selectTests` returning `{ selected: [{project,file,title,testCommand}], skipped: number, total: number }` where `testCommand` = `corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/<file> --project <project> --grep "<title with regex chars and quotes escaped>"`.
- Globals (all `direction: in`, `triggerNodeId: start`): `runId` string, `sha` string, `runUrl` string, `reportUrl` string, `slackTs` string default `""`, `failedTests` array, `projects` string default `studio-*`, `maxTests` number default `1`, `repoUrl` string default `https://github.com/UiPath/flow-workbench`, `branch` string default `develop`.

- [ ] **Step 1: Scaffold inside the existing solution**

```bash
cd ~/code/vm-agent-investigator/vm-agent && uip maestro flow init NightlyOrchestrator --output json && cd NightlyOrchestrator && uip maestro flow registry pull && ls && uip solution projects list --output json | head -40
```
Expected: `NightlyOrchestrator/NightlyOrchestrator.flow` exists; `projects list` shows both `VmAgent` and `NightlyOrchestrator`. Exactly one new `project.uiproj`; no stray `NightlyOrchestratorSolution/` folder (delete if created).

- [ ] **Step 2: Write the sample input** from the 2026-09-06 nightly (Slack thread `1788680141.527759`, run 34015558366):

`inputs/orchestrator-34015558366.json`:
```json
{
  "runId": "34015558366",
  "sha": "17321eae2d8f79f7f15610f8c8173ca824311f47",
  "runUrl": "https://github.com/UiPath/flow-workbench/actions/runs/34015558366",
  "reportUrl": "https://theater.uipath.co/flow/17321eae2d8f79f7f15610f8c8173ca824311f47/",
  "slackTs": "1788680141.527759",
  "projects": "studio-*",
  "maxTests": 1,
  "repoUrl": "https://github.com/UiPath/flow-workbench",
  "branch": "develop",
  "failedTests": [
    { "project": "studio-alpha", "file": "specs/data-transform/data-transform.spec.ts", "title": "should add a Map operation with field mappings", "error": "locator.click: <nav class=\"neighbor-rail-downstream\"> intercepts pointer events" },
    { "project": "studio-alpha", "file": "specs/data-transform/data-transform.spec.ts", "title": "should write a Custom Script operation in a Data Transform node", "error": "locator.click: <nav class=\"neighbor-rail-downstream\"> intercepts pointer events" },
    { "project": "vsix-staging-linux", "file": "specs/mfe/mfe-edit.spec.ts", "title": "persists an edit", "error": "frame.evaluate: Error: no project \"poc\" in this solution" },
    { "project": "vsix-staging-macos", "file": "specs/mfe/mfe-edit.spec.ts", "title": "persists an edit", "error": "frame.evaluate: Error: no project \"poc\" in this solution" },
    { "project": "studio-alpha", "file": "specs/debug/debug-execution.spec.ts", "title": "should run a debug session and show execution results", "error": "429 Too Many Requests" }
  ]
}
```

- [ ] **Step 3: Write the failing test** — it extracts the script source from the `.flow` so the test runs the real node code.

`orchestrator/tests/select-tests.test.mjs`:
```js
// Runs the selectTests / summarize script-node sources straight out of the .flow.
// Run: node orchestrator/tests/select-tests.test.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const flow = JSON.parse(readFileSync(new URL('../../vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow', import.meta.url)));
const scriptOf = (id) => {
  const n = flow.nodes.find((n) => n.id === id);
  assert.ok(n, `node ${id} missing`);
  return n.inputs.script.expression;
};
const run = (id, $vars) => new Function('$vars', scriptOf(id))($vars);
const input = JSON.parse(readFileSync(new URL('../../inputs/orchestrator-34015558366.json', import.meta.url)));

// selectTests: studio only, dedupe, cap, stable order, command shape
{
  const out = run('selectTests', { start: { output: { ...input, maxTests: 5 } } });
  assert.equal(out.total, 3, 'three distinct studio-* tests (vsix excluded, duplicates collapsed)');
  assert.equal(out.selected.length, 3);
  assert.equal(out.skipped, 0);
  assert.deepEqual(out.selected.map((t) => t.file), [
    'specs/data-transform/data-transform.spec.ts',
    'specs/data-transform/data-transform.spec.ts',
    'specs/debug/debug-execution.spec.ts',
  ].sort());
  assert.equal(out.selected[0].testCommand,
    'corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/specs/data-transform/data-transform.spec.ts --project studio-alpha --grep "should add a Map operation with field mappings"');
}
{
  const out = run('selectTests', { start: { output: input } }); // maxTests 1
  assert.equal(out.selected.length, 1);
  assert.equal(out.skipped, 2);
}
{
  const out = run('selectTests', { start: { output: { ...input, projects: 'studio-*,vsix-*', maxTests: 10 } } });
  assert.equal(out.total, 4, 'vsix rows dedupe across platforms into one');
}
{
  const out = run('selectTests', { start: { output: { ...input, failedTests: [{ project: 'studio-alpha', file: 'specs/a.spec.ts', title: 'has "quotes" and (parens) $1' }] } }) ;
  assert.match(out.selected[0].testCommand, /--grep "has \\"quotes\\" and \\\(parens\\\) \\\$1"$/);
}
console.log('selectTests ok');
```

- [ ] **Step 4: Run it, confirm it fails**

```bash
cd ~/code/vm-agent-investigator && node orchestrator/tests/select-tests.test.mjs
```
Expected: `AssertionError: node selectTests missing`.

- [ ] **Step 5: Author the trigger globals and `selectTests`**

Read the scaffolded `.flow` first (`cat vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow`). It has a `start` manual trigger and probably a default `end`. Replace `variables.globals` with:
```json
[
  { "id": "runId", "direction": "in", "type": "string", "triggerNodeId": "start" },
  { "id": "sha", "direction": "in", "type": "string", "triggerNodeId": "start" },
  { "id": "runUrl", "direction": "in", "type": "string", "triggerNodeId": "start" },
  { "id": "reportUrl", "direction": "in", "type": "string", "triggerNodeId": "start" },
  { "id": "slackTs", "direction": "in", "type": "string", "defaultValue": "", "triggerNodeId": "start" },
  { "id": "failedTests", "direction": "in", "type": "array", "triggerNodeId": "start" },
  { "id": "projects", "direction": "in", "type": "string", "defaultValue": "studio-*", "triggerNodeId": "start" },
  { "id": "maxTests", "direction": "in", "type": "number", "defaultValue": 1, "triggerNodeId": "start" },
  { "id": "repoUrl", "direction": "in", "type": "string", "defaultValue": "https://github.com/UiPath/flow-workbench", "triggerNodeId": "start" },
  { "id": "branch", "direction": "in", "type": "string", "defaultValue": "develop", "triggerNodeId": "start" }
]
```

Get the script definition version and add the node (copy the `core.action.script` entry from `VmAgent.flow`'s `definitions[]` into this flow's `definitions[]` if `registry get core.action.script --output json` is unavailable offline):
```bash
uip maestro flow registry get core.action.script --output json 2>/dev/null | python3 -c "import json,sys;t=sys.stdin.read();d=json.loads(t[t.find('{'):])['Data'];print((d.get('Node') or d)['version'])"
```

Add to `nodes[]`:
```json
{
  "id": "selectTests",
  "type": "core.action.script",
  "typeVersion": "1.1",
  "display": { "label": "Select tests", "subLabel": "filter by project, dedupe, cap at maxTests", "icon": "code" },
  "inputs": {
    "script": {
      "type": "literal",
      "fieldType": "string",
      "expression": "const s = $vars.start.output;\nconst globs = String(s.projects || 'studio-*').split(',').map(g => g.trim()).filter(Boolean);\nconst matches = (p) => globs.some(g => new RegExp('^' + g.split('*').map(x => x.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&')).join('.*') + '$').test(p));\nconst seen = new Set();\nconst rows = [];\nfor (const t of (s.failedTests || [])) {\n  if (!t || !matches(t.project || '')) continue;\n  const key = t.file + '::' + t.title;\n  if (seen.has(key)) continue;\n  seen.add(key);\n  rows.push(t);\n}\nrows.sort((a, b) => (a.file + a.title).localeCompare(b.file + b.title));\nconst grep = (title) => String(title).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\"/g, '\\\\\"');\nconst max = Number(s.maxTests) > 0 ? Number(s.maxTests) : 1;\nconst selected = rows.slice(0, max).map(t => ({\n  project: t.project, file: t.file, title: t.title, error: t.error || '',\n  testCommand: `corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/${t.file} --project ${t.project} --grep \"${grep(t.title)}\"`\n}));\nreturn { selected, skipped: rows.length - selected.length, total: rows.length };"
    }
  },
  "outputs": {
    "output": {
      "type": "any", "description": "The return value of the script", "source": "=result.response", "var": "output",
      "schema": { "type": "object", "properties": {
        "selected": { "type": "array", "items": { "type": "object", "properties": {
          "project": { "type": "string" }, "file": { "type": "string" }, "title": { "type": "string" },
          "error": { "type": "string" }, "testCommand": { "type": "string" } } } },
        "skipped": { "type": "number" }, "total": { "type": "number" } } }
    },
    "error": { "type": "object", "description": "Error information if the node fails", "source": "=Error", "var": "error" }
  }
}
```
(The `expression` above is one JSON string; the JS inside, unescaped, is:)
```js
const s = $vars.start.output;
const globs = String(s.projects || 'studio-*').split(',').map(g => g.trim()).filter(Boolean);
const matches = (p) => globs.some(g => new RegExp('^' + g.split('*').map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(p));
const seen = new Set();
const rows = [];
for (const t of (s.failedTests || [])) {
  if (!t || !matches(t.project || '')) continue;
  const key = t.file + '::' + t.title;
  if (seen.has(key)) continue;
  seen.add(key);
  rows.push(t);
}
rows.sort((a, b) => (a.file + a.title).localeCompare(b.file + b.title));
const grep = (title) => String(title).replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/"/g, '\\"');
const max = Number(s.maxTests) > 0 ? Number(s.maxTests) : 1;
const selected = rows.slice(0, max).map(t => ({
  project: t.project, file: t.file, title: t.title, error: t.error || '',
  testCommand: `corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/${t.file} --project ${t.project} --grep "${grep(t.title)}"`
}));
return { selected, skipped: rows.length - selected.length, total: rows.length };
```
Write the node with a small Python snippet that reads the JS from a heredoc and does `json.dumps` — do not hand-escape.

Edge: `start.output -> selectTests.input`, then temporarily `selectTests.success -> end.input` so the flow validates.

- [ ] **Step 6: Validate, format, run the test**

```bash
cd ~/code/vm-agent-investigator/vm-agent/NightlyOrchestrator && uip maestro flow validate NightlyOrchestrator.flow && uip maestro flow format NightlyOrchestrator.flow && cd ~/code/vm-agent-investigator && node orchestrator/tests/select-tests.test.mjs
```
Expected: validate OK, `selectTests ok`.

- [ ] **Step 7: Commit**

```bash
cd ~/code/vm-agent-investigator && git add vm-agent inputs/orchestrator-34015558366.json orchestrator && git commit -m "NightlyOrchestrator: trigger inputs and test selection"
```

---

### Task 5: Parallel loop calling `VmAgent` (vm-agent-investigator)

**Files:**
- Modify: `vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow`

**Interfaces:**
- Consumes: `$vars.selectTests.output.selected[]` (Task 4).
- Produces: `$vars.investigate.output` = array, one entry per iteration, shape `{ callVmAgent: { output: {hypothesis, evidence, reproduced, fixVerified, prUrl} | undefined, error: {...} | undefined }, recordResult: { output: {project,file,title,reproduced,fixVerified,prUrl,hypothesis,failed:boolean} } }`. Downstream reads `item.recordResult.output`.

- [ ] **Step 1: Pull definitions**

```bash
cd ~/code/vm-agent-investigator/vm-agent/NightlyOrchestrator && uip maestro flow registry get core.logic.loop --output json 2>/dev/null | python3 -c "import json,sys;t=sys.stdin.read();d=json.loads(t[t.find('{'):])['Data'];n=d.get('Node') or d;print(n['version']);print(json.dumps(n['handleConfiguration']))" && uip maestro flow registry get uipath.core.flow.4a7879cf-7494-4ada-9e83-ea487a4b55cb --local --output json 2>/dev/null | python3 -c "import json,sys;t=sys.stdin.read();d=json.loads(t[t.find('{'):])['Data'];print(json.dumps(d['Node']))" > /tmp/vmagent-def.json && echo saved
```
Copy `/tmp/vmagent-def.json` verbatim as a new entry in `definitions[]`, and add the `core.logic.loop` definition from `registry get` the same way.

- [ ] **Step 2: Add the loop, the flow node, and the recorder**

Nodes (`typeVersion` from Step 1):
```json
{ "id": "investigate", "type": "core.logic.loop", "typeVersion": "<LOOP_VERSION>",
  "display": { "label": "Investigate each test", "subLabel": "parallel, one VmAgent per test" },
  "inputs": { "collection": "=js:$vars.selectTests.output.selected", "parallel": true } },

{ "id": "callVmAgent", "type": "uipath.core.flow.4a7879cf-7494-4ada-9e83-ea487a4b55cb", "typeVersion": "1.0.0",
  "parentId": "investigate",
  "display": { "label": "VmAgent" },
  "inputs": {
    "repoUrl": { "type": "jsExpression", "expression": "$vars.start.output.repoUrl", "fieldType": "string" },
    "branch": { "type": "jsExpression", "expression": "$vars.start.output.branch", "fieldType": "string" },
    "testCommand": { "type": "jsExpression", "expression": "$vars.investigate.currentItem.testCommand", "fieldType": "string" },
    "maxFixAttempts": { "type": "literal", "expression": "3", "fieldType": "number" },
    "smokeOnly": { "type": "literal", "expression": "false", "fieldType": "boolean" },
    "resumeRunId": { "type": "literal", "expression": "", "fieldType": "string" },
    "runnerRepoUrl": { "type": "literal", "expression": "https://github.com/david-rios-uipath/vm-agent-investigator", "fieldType": "string" },
    "runnerRef": { "type": "literal", "expression": "master", "fieldType": "string" },
    "claudeModel": { "type": "literal", "expression": "", "fieldType": "string" },
    "errorHandlingEnabled": true
  },
  "outputs": { "error": { "type": "object", "description": "Error information if the flow fails", "source": "=Error", "var": "error" } } },

{ "id": "recordResult", "type": "core.action.script", "typeVersion": "1.1", "parentId": "investigate",
  "display": { "label": "Record result", "icon": "code" },
  "inputs": { "script": { "type": "literal", "fieldType": "string", "expression": "<JS below>" } },
  "outputs": { "output": { "type": "any", "source": "=result.response", "var": "output", "description": "The return value of the script",
    "schema": { "type": "object", "properties": {
      "project": {"type":"string"}, "file": {"type":"string"}, "title": {"type":"string"},
      "reproduced": {"type":"boolean"}, "fixVerified": {"type":"boolean"}, "prUrl": {"type":"string"},
      "hypothesis": {"type":"string"}, "failed": {"type":"boolean"}, "errorMessage": {"type":"string"} } } },
    "error": { "type": "object", "description": "Error information if the node fails", "source": "=Error", "var": "error" } } }
```
`recordResult` JS:
```js
const t = $vars.investigate.currentItem;
const r = ($vars.callVmAgent && $vars.callVmAgent.output) || null;
const e = ($vars.callVmAgent && $vars.callVmAgent.error) || null;
return {
  project: t.project, file: t.file, title: t.title,
  reproduced: !!(r && r.reproduced), fixVerified: !!(r && r.fixVerified),
  prUrl: (r && r.prUrl) || '', hypothesis: (r && r.hypothesis) || '',
  failed: !r, errorMessage: e ? String(e.message || e.code || 'VmAgent faulted') : ''
};
```
Check the exact input-field shape the flow node expects by looking at how `VmAgent.flow` passes inputs to its RPA node (`{type, expression, fieldType}` objects) and at `registry get`'s `form.sections[0].fields[*].name` (`inputs.repoUrl`, ...). If `flow validate` rejects the object form for a flow node, use the `"=js:..."` string form instead.

Edges:
```json
{ "id": "e_select_loop", "sourceNodeId": "selectTests", "sourcePort": "success", "targetNodeId": "investigate", "targetPort": "input" },
{ "id": "e_loop_start", "sourceNodeId": "investigate", "sourcePort": "start", "targetNodeId": "callVmAgent", "targetPort": "input" },
{ "id": "e_vm_ok", "sourceNodeId": "callVmAgent", "sourcePort": "output", "targetNodeId": "recordResult", "targetPort": "input" },
{ "id": "e_vm_err", "sourceNodeId": "callVmAgent", "sourcePort": "error", "targetNodeId": "recordResult", "targetPort": "input" },
{ "id": "e_record_continue", "sourceNodeId": "recordResult", "sourcePort": "success", "targetNodeId": "investigate", "targetPort": "continue" },
{ "id": "e_loop_end", "sourceNodeId": "investigate", "sourcePort": "success", "targetNodeId": "end", "targetPort": "input" }
```
Remove the temporary `selectTests -> end` edge from Task 4.

Top-level `bindings[]` (resourceKey must equal the definition's `model.bindings.resourceKey`, which is the GUID):
```json
[
  { "id": "bVmAgentName", "name": "name", "type": "string", "resource": "process", "resourceKey": "4a7879cf-7494-4ada-9e83-ea487a4b55cb", "default": "VmAgent", "propertyAttribute": "name", "resourceSubType": "Flow" },
  { "id": "bVmAgentFolderPath", "name": "folderPath", "type": "string", "resource": "process", "resourceKey": "4a7879cf-7494-4ada-9e83-ea487a4b55cb", "default": "", "propertyAttribute": "folderPath", "resourceSubType": "Flow" }
]
```
`variables.nodes`: add `investigate.currentItem` (any), `investigate.currentIteration` (number), `investigate.collection` (array), `investigate.output` (array), `callVmAgent.output` (object), `callVmAgent.error` (object), `recordResult.output` (object). `format` regenerates this block; run it and confirm the entries appear.

- [ ] **Step 3: Validate + format**

```bash
uip maestro flow validate NightlyOrchestrator.flow && uip maestro flow format NightlyOrchestrator.flow && python3 -c "import json;f=json.load(open('NightlyOrchestrator.flow'));print([v['id'] for v in f['variables']['nodes']])"
```
Expected: validate OK; the printed ids include `investigate.currentItem` and `callVmAgent.output`.

- [ ] **Step 4: Debug-run the loop with `maxTests: 1`** (requires `uip login status` OK; ~30 min because VmAgent really runs)

```bash
cd ~/code/vm-agent-investigator && python3 -c "import json;d=json.load(open('inputs/orchestrator-34015558366.json'));d['failedTests']=d['failedTests'][:1];json.dump(d,open('/tmp/orch-1.json','w'))" && cd vm-agent/NightlyOrchestrator && uip maestro flow debug NightlyOrchestrator.flow --input-file /tmp/orch-1.json --output json
```
Expected: run reaches `end`; the debug output shows `investigate.output[0].recordResult.output.reproduced` as a boolean. If debug provisions into the personal `Debug_` folder and VmAgent's RPA node cannot find `vm-exec-vm`, skip debug and rely on the deployed run in Task 7 (the same routing trap as documented in HANDOFF.md).

- [ ] **Step 5: Commit**

```bash
cd ~/code/vm-agent-investigator && git add vm-agent && git commit -m "NightlyOrchestrator: parallel loop over VmAgent with per-test result capture"
```

---

### Task 6: Summary + Slack reply (vm-agent-investigator)

**Files:**
- Modify: `vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow`
- Modify: `orchestrator/tests/select-tests.test.mjs` (add `summarize` case)

**Interfaces:**
- Consumes: `$vars.investigate.output[]` (Task 5), `$vars.selectTests.output` (Task 4).
- Produces: `$vars.summarize.output.text` (Slack mrkdwn string); node `slackReply` posting to `C0AH25MT3L5`.

- [ ] **Step 1: Add the failing `summarize` test** to `orchestrator/tests/select-tests.test.mjs`:

```js
{
  const text = run('summarize', {
    start: { output: input },
    selectTests: { output: { total: 3, skipped: 2, selected: [input.failedTests[0]] } },
    investigate: { output: [ { recordResult: { output: {
      project: 'studio-alpha', file: 'specs/data-transform/data-transform.spec.ts',
      title: 'should add a Map operation with field mappings', reproduced: true, fixVerified: true,
      prUrl: 'https://github.com/UiPath/flow-workbench/pull/3729', hypothesis: 'neighbor rail intercepts click', failed: false, errorMessage: '' } } } ] },
  }).text;
  assert.match(text, /VmAgent investigated 1 of 3 studio-\* failures/);
  assert.match(text, /data-transform\.spec\.ts › should add a Map operation with field mappings/);
  assert.match(text, /reproduced, fix verified, <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3729\|draft PR>/);
  assert.match(text, /2 not investigated \(maxTests=1\)/);
  const none = run('summarize', { start: { output: input }, selectTests: { output: { total: 0, skipped: 0, selected: [] } }, investigate: { output: [] } }).text;
  assert.match(none, /no studio-\* failures to investigate/);
  console.log('summarize ok');
}
```
Run: `node orchestrator/tests/select-tests.test.mjs` → expected `node summarize missing`.

- [ ] **Step 2: Add `summarize`** (script node, same output pattern as `selectTests`, schema `{ text: string }`), JS:

```js
const s = $vars.start.output;
const sel = $vars.selectTests.output || { total: 0, skipped: 0, selected: [] };
const rows = ($vars.investigate.output || []).map(i => i.recordResult && i.recordResult.output).filter(Boolean);
const head = `:robot_face: *VmAgent investigated ${rows.length} of ${sel.total} ${s.projects || 'studio-*'} failures* (<${s.runUrl}|run ${s.runId}>)`;
if (sel.total === 0) return { text: `:robot_face: VmAgent: no ${s.projects || 'studio-*'} failures to investigate in <${s.runUrl}|run ${s.runId}>.` };
const spec = (f) => String(f).split('/').pop();
const lines = rows.map(r => {
  if (r.failed) return `• \`${spec(r.file)} › ${r.title}\` — investigation faulted: ${r.errorMessage}`;
  const parts = [r.reproduced ? 'reproduced' : 'not reproduced', r.fixVerified ? 'fix verified' : 'no verified fix', r.prUrl ? `<${r.prUrl}|draft PR>` : 'no PR'];
  return `• \`${spec(r.file)} › ${r.title}\` — ${parts.join(', ')}` + (r.hypothesis ? `\n    _${r.hypothesis.slice(0, 300)}_` : '');
});
if (sel.skipped > 0) lines.push(`_${sel.skipped} not investigated (maxTests=${s.maxTests})_`);
return { text: [head, ...lines].join('\n') };
```
Edge: `investigate.success -> summarize.input` (replace the `investigate -> end` edge).

- [ ] **Step 3: Add the Slack node via CLI** (needs login)

```bash
uip login status --output json && uip is connections list uipath-salesforce-slack --all-folders --output json 2>/dev/null | python3 -c "import json,sys;[print({k:c.get(k) for k in ('Id','Name','State','Folder','FolderKey')}) for c in json.load(sys.stdin)['Data']]"
```
Pick the connection named `david.rios` in folder `e2e-investigator` (it is already a linked resource in `deploy-config.json`, key `ccf82d4b-3c2a-492f-bf8f-939b565366a2`). Then:
```bash
uip maestro flow node add NightlyOrchestrator.flow uipath.connector.uipath-salesforce-slack.send-message-to-channel --label "Reply in Slack thread" --output json
uip maestro flow registry get uipath.connector.uipath-salesforce-slack.send-message-to-channel --connection-id <CONN_ID> --output json 2>/dev/null > /tmp/slack-def.json
python3 -c "import json;d=json.load(open('/tmp/slack-def.json'))['Data'];n=d.get('Node') or d;print(n.get('connectorMethodInfo',{}).get('method'), n.get('connectorMethodInfo',{}).get('path'));[print(f.get('name'), f.get('required'), f.get('description','')[:80]) for f in (n.get('inputDefinition',{}).get('fields') or [])]; [print('PARAM',p.get('name'),p.get('type'),p.get('required')) for p in n.get('connectorMethodInfo',{}).get('parameters',[])]"
```
Find the body field for the message text (expected `messageToSend`), the channel field (expected `channel`, resolved to the ID `C0AH25MT3L5`), and the thread field. **If a field like `thread_ts` / `threadTs` / `parentMessageTs` exists**, bind it to `=js:$vars.start.output.slackTs || undefined`. **If none exists**, post top-level and add a line to `summarize`'s head with the Slack permalink built from `slackTs`: `https://uipath-product.slack.com/archives/C0AH25MT3L5/p${slackTs.replace('.', '')}` — record which case applied in HANDOFF.md.

```bash
uip maestro flow node configure NightlyOrchestrator.flow <NODE_ID> --output json --detail '{
  "connectionId": "<CONN_ID>", "folderKey": "<FOLDER_KEY>",
  "method": "<METHOD>", "endpoint": "<PATH>",
  "bodyParameters": { "channel": "C0AH25MT3L5", "messageToSend": "=js:$vars.summarize.output.text", "<THREAD_FIELD>": "=js:$vars.start.output.slackTs || undefined" }
}'
```
Rename the node id to `slackReply` only if `node add` let you set it; otherwise keep the generated id and use it in the edges. Edges: `summarize.success -> <slackNode>.input`, `<slackNode>.output -> end.input`.

- [ ] **Step 4: Validate, format, test, commit**

```bash
uip maestro flow validate NightlyOrchestrator.flow && uip maestro flow format NightlyOrchestrator.flow && cd ~/code/vm-agent-investigator && node orchestrator/tests/select-tests.test.mjs && git add vm-agent orchestrator && git commit -m "NightlyOrchestrator: summary and Slack thread reply"
```
Expected: `selectTests ok`, `summarize ok`.

---

### Task 7: Deploy config, release script, first deployed run (vm-agent-investigator)

**Files:**
- Modify: `deploy-config.json`
- Modify: `release.sh`
- Modify: `HANDOFF.md`

**Interfaces:**
- Produces: process `NightlyOrchestrator` in folder `Shared/vm-agent 11` (the name Task 3's script resolves). `./release.sh <version> <input.json> [ProcessName]` starts the named process, default `VmAgent`.

- [ ] **Step 1: Add the process to `deploy-config.json`** — copy the `VmAgent` entry, change `name` to `NightlyOrchestrator`, `packageName` to `vm-agent.7.flow.NightlyOrchestrator` (confirm the exact string from the packed zip: `unzip -l /tmp/vm-agent-pkg/*.zip | grep flow.`), and `resourceKey` to the value in `vm-agent/NightlyOrchestrator/project.uiproj` (`grep -i '"id"\|projectId' project.uiproj`).

- [ ] **Step 2: Let `release.sh` start either process**

Change the `KEY=` lookup to use `PROCESS="${3:-VmAgent}"` and `x['Name']==sys.argv[1]` with `"$PROCESS"` passed in; also extend the packaged-bindings assertion so it checks the orchestrator's nupkg contains `bindings_v2.json` with the VmAgent flow binding (`'4a7879cf-7494-4ada-9e83-ea487a4b55cb'` in the keys or names). Keep the `git checkout -- vm-agent/` line.

- [ ] **Step 3: Release and run with one test**

```bash
cd ~/code/vm-agent-investigator && uip login status --output json && ./release.sh 1.1.0 /tmp/orch-1.json NightlyOrchestrator
```
Expected: `JOB <key> Pending ...`. Then watch:
```bash
uip or jobs list --folder-path "Shared/vm-agent 11" --output json | python3 -c "import sys,json;t=sys.stdin.read();d=json.loads(t[t.find('{'):]);[print(j['ReleaseName'],j['State'],j['StartTime']) for j in d['Data']]"
```
Expected within ~40 min: `NightlyOrchestrator Successful`, a child `VmAgent Successful`, and a reply in Slack thread `1788680141.527759`. Close and delete the branch of any draft PR VmAgent opened on `UiPath/flow-workbench` during this test.

If the `NightlyOrchestrator` instance faults at `callVmAgent` with a folder/binding error, inspect `uip maestro flow instance incidents <jobKey> -f <folderKey>`; the usual cause is `bindings[]` `resourceKey` not matching the definition. Fix, bump to 1.1.1, rerun.

- [ ] **Step 4: Document and commit**

Add a `## NightlyOrchestrator` section to `HANDOFF.md`: trigger inputs table, the `maxTests == VM count` rule, the Slack thread-field outcome from Task 6, the release command, and the flow-workbench PR link. Then:
```bash
git add deploy-config.json release.sh HANDOFF.md && git commit -m "Release NightlyOrchestrator alongside VmAgent" && git push origin master
```

---

### Task 8: External app + CI configuration, end-to-end from a laptop (both repos)

**Files:** none in git besides the PR update. Tenant + GitHub settings.

- [ ] **Step 1: Create the external app** in Automation Cloud admin (David does this in the browser; not automatable): Admin → External Applications → Add → *Confidential*, name `flow-workbench-nightly-investigator`, scopes `OR.Jobs`, `OR.Folders`, `OR.Execution` (application scope). Record the client id and secret. Assign the app to folder `Shared/vm-agent 11` with a role that can start jobs (Automation User is enough).

- [ ] **Step 2: Set GitHub repo variables and secrets**

```bash
cd ~/code/flow-workbench && ORG=$(uip login status --output json | python3 -c "import json,sys;d=json.load(sys.stdin)['Data'];print(d.get('OrganizationName') or d.get('organization'))") && echo "$ORG"
gh variable set UIPATH_INVESTIGATOR_ORG --body "<org>" && gh variable set UIPATH_INVESTIGATOR_TENANT --body "<tenant>"
gh secret set UIPATH_INVESTIGATOR_CLIENT_ID && gh secret set UIPATH_INVESTIGATOR_CLIENT_SECRET   # paste when prompted; never echo them
```
If `gh` lacks admin on `UiPath/flow-workbench`, list the four names in the PR description for a repo admin.

- [ ] **Step 3: Run the CI script from the laptop against the real tenant**

```bash
cd ~/code/flow-workbench && UIPATH_ORG=<org> UIPATH_TENANT=<tenant> UIPATH_CLIENT_ID=<id> UIPATH_CLIENT_SECRET=<secret> \
  RUN_ID=34015558366 SHA=17321eae2d8f79f7f15610f8c8173ca824311f47 \
  RUN_URL=https://github.com/UiPath/flow-workbench/actions/runs/34015558366 \
  REPORT_URL=https://theater.uipath.co/flow/17321eae2d8f79f7f15610f8c8173ca824311f47/ SLACK_TS=1788680141.527759 \
  FAILED_TESTS_FILE=<(python3 -c "import json;print(json.dumps(json.load(open('$HOME/code/vm-agent-investigator/inputs/orchestrator-34015558366.json'))['failedTests'][:1]))") \
  ./.github/scripts/start-nightly-investigation.sh
```
Expected: `Started NightlyOrchestrator job <key> with 1 failed tests.` and, ~35 min later, a reply in the Slack thread. Close any draft PR the run opens.

- [ ] **Step 4: Verify the artifact path on a real CI run**

Trigger `workflow_dispatch` of `Playwright CI` on the branch with a narrow `grep` and `project: studio-alpha` (Actions UI or `gh workflow run playwright-ci.yml --ref feat/nightly-investigator-hook -f project=studio-alpha -f grep="<a test title>"`). When it finishes, download `failed-tests` and check its `file` values start with `specs/` (Task 4's `e2e/` prefix assumption). If they start with `e2e/` instead, drop the prefix in `selectTests` and re-release the flow.

- [ ] **Step 5: Update the PR** with the verification results (job key, Slack permalink, artifact check) and mark it ready when David says so. Leave it draft otherwise.

---

## Self-review

- Spec coverage: CI emit (T1–2), StartJobs + best-effort (T3), trigger inputs/defaults (T4), filter/dedupe/cap (T4), parallel loop + error port (T5), summary + in-thread reply + empty case (T6), deploy (T7), secrets + e2e (T8). Open risk (flow node in parallel loop) is exercised in T5 step 4 and T7 step 3; fallback described in the spec, not planned here on purpose.
- Placeholders: `<LOOP_VERSION>`, `<CONN_ID>`, `<FOLDER_KEY>`, `<METHOD>`, `<PATH>`, `<THREAD_FIELD>`, `<NODE_ID>`, `<org>`, `<tenant>` are all resolved by a command in the same task, never guessed.
- Names consistent: `selectTests`, `investigate`, `callVmAgent`, `recordResult`, `summarize`, artifact `failed-tests`, process `NightlyOrchestrator`, folder `Shared/vm-agent 11`, secrets `UIPATH_INVESTIGATOR_*`.
