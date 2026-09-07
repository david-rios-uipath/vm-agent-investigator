# Nightly orchestrator — design

Date: 2026-09-07. Status: approved in chat, not yet implemented.

## Goal

When the flow-workbench nightly Playwright run fails, automatically run the existing `VmAgent`
flow once per failed test (deduplicated), in parallel up to the VM pool size, and post the
results as a reply under Flow Bot's red-circle message in Slack channel `C0AH25MT3L5`.

## Non-goals

- vsix projects (VmAgent cannot reproduce them yet). The project filter is a trigger input so
  enabling them later is a config change.
- Agentic selection of "interesting" failures. Selection is deterministic.
- Filing GitHub issues (issues are disabled on the repo).
- Retrying a faulted VmAgent instance.
- Replacing the Claude triage routine; it keeps running unchanged.

## Components

### 1. CI: emit the failed-test list (`UiPath/flow-workbench`)

`playwright-deploy.yml`, job `merge-reports`:

- Run `merge-reports` with `--reporter html,json`, `PLAYWRIGHT_JSON_OUTPUT_NAME=merged.json`.
- New step: `jq` `merged.json` into `failed-tests.json`, one row per test whose final
  outcome is `unexpected` (failed or timed out on the last attempt; retried-then-passed is
  excluded). Row shape:
  `{ "project": "studio-alpha", "file": "e2e/specs/data-transform/data-transform.spec.ts",
     "title": "should add a Map operation with field mappings", "error": "<first 500 chars>" }`.
- Upload `failed-tests.json` as artifact `failed-tests`.

`playwright-ci.yml`, job `notify-failure`:

- `notify-slack-playwright.sh` writes the posted message `ts` to `$GITHUB_OUTPUT` as `slack_ts`
  (script stays exit-0-safe when Slack is unconfigured).
- New step downloads artifact `failed-tests`, obtains a token from
  `https://cloud.uipath.com/identity_/connect/token` with client credentials
  (secrets `UIPATH_E2E_INVESTIGATOR_CLIENT_ID` / `_CLIENT_SECRET`, scope `OR.Jobs`), and calls
  `odata/Jobs/UiPath.Server.Configuration.OData.StartJobs` with the orchestrator process
  release key and `InputArguments` (JSON string):
  `{ runId, sha, runUrl, reportUrl, slackTs, failedTests }`.
- Step is best-effort: failure logs `::warning::` and does not turn the job red.

### 2. Flow: `NightlyOrchestrator` (new flow in the `vm-agent` solution)

Trigger inputs (manual trigger; these are the job input arguments):

| name | type | default | purpose |
|---|---|---|---|
| runId | string | | GitHub Actions run id |
| sha | string | | commit under test |
| runUrl, reportUrl | string | | links for the Slack reply |
| slackTs | string | "" | Slack message timestamp to reply under; empty = post top-level |
| failedTests | array | | rows from `failed-tests.json` |
| projects | string | `studio-*` | glob list (comma-separated) of projects to investigate |
| maxTests | number | 1 | parallel VmAgent instances; keep equal to VM pool size |
| repoUrl, branch | string | flow-workbench / develop | forwarded to VmAgent |

Nodes:

```
start
 -> selectTests   script: filter by projects glob, dedupe on file+title, sort by file, slice(maxTests);
                  emit [{project,file,title,testCommand}]
 -> anySelected   decision: selected.length > 0
      no  -> slackReply (message: "no studio-* failures to investigate") -> end
      yes -> loop (parallel: true) over selected
              -> callVmAgent   uipath.core.flow.<VmAgent>  inputs: repoUrl, branch, testCommand
                               (error port wired -> recordFailure)
              -> recordResult  script: {test, reproduced, fixVerified, prUrl, hypothesis}
              -> continue
 -> summarize     script: markdown table, one row per test, PR link when present
 -> slackReply    Slack connector chat.postMessage, channel C0AH25MT3L5, thread_ts = slackTs
 -> end
```

`testCommand` is built exactly as the hand-written `inputs/*.json` files do today:
`corepack pnpm exec playwright test --config e2e/playwright.config.ts <file> --project <project>
--grep "<title escaped>"`.

Concurrency: `maxTests` caps the fan-out. With one VM, more than one instance interleaves phase
jobs on the same robot and risks the 45-minute phase timeout, so the cap must track the pool.

### 3. Slack

Reply is sent by the flow through an Integration Service Slack connection (posts as whatever
identity that connection authorized). Format: header line with run link, then one line per
test: `spec › title — reproduced/not, fix verified/not, <PR link | no PR>`, plus a line for
tests skipped by the cap.

## Error handling

- Faulted `callVmAgent` -> recorded as `runnerFailed` for that test; other iterations continue.
- Missing `slackTs` -> top-level post.
- CI StartJobs failure -> warning annotation only.

## Testing

1. `uip maestro flow validate` + `format` on the new flow.
2. Debug run with `inputs/orchestrator-34015558366.json` built from the 2026-09-06 nightly
   (two `data-transform.spec.ts` studio-alpha failures), `maxTests: 1`.
3. Deploy with `release.sh`, then trigger from a `workflow_dispatch` of `playwright-ci.yml`.

## Open risk

`uipath.core.flow.*` calling a sibling flow inside a `parallel: true` loop is unverified on this
tenant. Fallback: loop body calls Orchestrator `StartJobs` for the deployed VmAgent process via an
HTTP node and polls for completion.
