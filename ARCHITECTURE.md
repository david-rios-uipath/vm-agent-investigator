# Architecture (as built)

How `VmAgent` and `NightlyOrchestrator` are put together. Current shape, not history —
for *why* the reasoning moved onto the VM, read `DESIGN-phase-runner.md`; for the traps
this shape encodes, read `TRAPS.md` and `FINDINGS-uip.md`.

## What this is

`~/code/vm-agent-investigator` builds a UiPath Maestro Flow (`VmAgent`) that investigates a
failing Playwright e2e test in `UiPath/flow-workbench`, on a Windows robot VM driven by one RPA
process (`vm-exec`, a PowerShell runner).

Up to and including 1.0.24 the reasoning lived in the cloud: three inline agents (investigator,
fixer, summarizer) drove the VM through ~34 `vm_exec` tool calls, each its own Orchestrator job.
That only worked because the robot pool has a single VM, so state left on disk survived between
jobs. `DESIGN-phase-runner.md` explains why that had to change; `PLAN.md` describes the
superseded agent-driven shape and its run economics.

The phase runner replaced it and is released: four coarse RPA jobs, the LLM reasoning moved onto
the VM as `claude -p`, every job self-contained — it refreshes the checkout, pulls its state from
the bucket, and pushes it back.

## Phase runner

Everything below `vm/` runs ON the VM; the flow only orchestrates it.

| file | what |
|---|---|
| `vm/run-phase.ps1` | one `switch ($Phase)` over `repro`, `investigate`, `fix`, `pr`; same prologue and epilogue for each |
| `vm/lib/prologue.ps1` | `Ensure-Tools` (rg, gh, pnpm shim, Claude Code — idempotent), `Refresh-Repo`, `Invoke-Cmd`, `Write-Utf8Lf`, `Write-Status` |
| `vm/lib/ci-history.ps1` | the old `ciHistoryInstructions` node, ported to a function |
| `vm/lib/pr-body.ps1` | `New-PrBody`, the reviewer-facing PR description |
| `vm/lib/report.ps1` | `Get-ReportFacts` / `New-ReportBody` / `New-ReportVerdict`, the per-group Slack report |
| `vm/prompts/{investigator,fixer}.md` | the two agent prompts, written for real file tools |
| `vm/selfcheck.ps1` | `pwsh -NoProfile -File vm/selfcheck.ps1` — asserts over the pure logic (status line, patch encoding, PR title, repro routing) |

### The per-group report

The last phase, `report`, renders `report.md` from what is already in `state.zip` — notebook,
evidence, fix summary, patch — and uploads it into the nightly's Slack thread with a one-line
verdict as the upload's `initial_comment`. One message per group, posted the moment that group
finishes, instead of one message per night carrying every group; the orchestrator's `summarize`
is a roll-up after it (counts, spend, covered and deferred groups, capped at 3500 chars).

The VM uploads it, not the flow: `callVmAgent`'s output schema has no room for a notebook, and
routing 4 x 20 KB of one through flow variables is what broke the GitHub-connector PR fetch
("The instance's variables exceed the maximum allowed size"). `vm-exec` already injects and
redacts `SLACK_BOT_TOKEN` (a **Secret** asset, read with `GetSecret` - a bot token has no
username half), so the file never leaves the VM as a flow variable.

Three calls, in `Send-SlackFile` (prologue): `files.getUploadURLExternal`, the bytes, then
`files.completeUploadExternal` with `channel_id`, `thread_ts` and `initial_comment`. An empty
`slackChannel` or `slackThreadTs` renders the report and uploads nothing, which is what keeps a
manual `VmAgent` run and `probe-phase.sh` out of Slack. The phase skips the prologue entirely —
it never touches the checkout — and its failures are caught, never faulted: the run has already
reproduced, fixed and opened a PR by then.

`endNotReproduced` and `terminateSetupFailed` bypass `investigationSummarizer`, so those groups
post no file; they get their line in the roll-up instead.

### PR videos

Both the `repro` run and the verified `fix` run record with `E2E_RECORD=1`; `Save-DemoVideo`
(prologue) converts each webm to mp4+gif with the same arguments as flow-workbench
`scripts/record-demo.sh`, into `bug-demo.*` and `fix-demo.*`. The `pr` phase attaches both with
`gh pr create --attach` (needs gh >= 2.99; the VM has 2.100) and the body names the order, since
gh appends attachments and a video takes no alt text. On the CI-settled path (`source='ci'`) the
spec never runs here, so there is no clip and the body links the failing nightly run instead.
`bug-demo.mp4` rides in `state.zip` from `repro` onward; the raw webms are deleted before the
`test-results` copy so the 25 MB guard still holds.

### Flow shape

`start -> deriveRunId -> decisionResume -> bootstrap<Phase> -> <phase RPA node>
-> parseStatus<Phase> -> decision… -> investigationSummarizer -> bootstrapReport -> report
-> parseStatusReport -> end`, 28 nodes plus the sticky notes.

The five `bootstrap*` script nodes emit a ~15-line PowerShell that clones this repo to
`C:\vm-agent\runner` at `runnerRef` and invokes `vm/run-phase.ps1` — so a runner change is a
git push, not a solution release. Each phase prints one `STATUS_JSON=<json>` line as its last
line of stdout and `parseStatus*` parses only that; its absence routes to `endSetupFailed`.

**Every runner edit must be pushed before a phase job runs it** — the bootstrap fetches the ref,
it does not read your working tree. The runner repo is
`https://github.com/david-rios-uipath/vm-agent-investigator`, public (so the VM needs no token to
clone it), branch **`master`** — `runnerRef` defaults to `master`, not `main`.

### Trigger inputs

`maxFixAttempts` (3), `runnerRepoUrl`, `runnerRef` (`master`), `claudeModel`, and the report
phase's Slack context — `slackChannel`, `slackThreadTs`, `runUrl`, `reportUrl`, all defaulting
to `''`, which `NightlyOrchestrator` fills in and a manual run leaves empty. `claudeModel` —
**defaults to `claude-sonnet-5`**, and `NightlyOrchestrator` passes the same value to every child
rather than an empty string. Empty means the CLI's account default on the VM, which is Opus: a
single investigate pass cost $4.51 and a fix pass $2.29 on 2026-09-08, the wrong default for a
job meant to run nightly. Set `claude-haiku-4-5-20251001` when testing plumbing rather than
reasoning; `probe-phase.sh` reads the same lever from `CLAUDE_MODEL` and also defaults to Sonnet.

The summarizer agent node runs on `anthropic.claude-sonnet-5` (moved from Opus 4.8 on
2026-09-22: it has no tools and only restates the notebook, so Opus bought nothing). It runs
through the LLM gateway, which is billed separately from the Claude Code account the phases use.
If it ever moves, that model lives in `VmAgent.flow` **and** in two `agent.json` copies, all
three of which must be patched together.

`maxIterations` and the `iteration` global are gone with the investigator loop.

### `vm-exec` (`vm-agent/vm-exec/Main.xaml`)

An `ANTHROPIC_API_KEY` asset injected as an env var and added to the redaction list; a `StateKey`
in-argument; defaults of 45 minutes and 32000 output chars. `ANTHROPIC_API_KEY`,
`GH_NPM_REGISTRY_TOKEN`, `PLAYWRIGHT_PASSWORD` and `SLACK_BOT_TOKEN` are **Secret** assets in
`e2e-investigator`, read with `ui:GetSecret`; `GH_TOKEN` and `SLACK_COOKIE` are Credentials,
read with `ui:GetRobotCredential`. A bot token has no username half, which is why `SLACK_BOT_TOKEN`
is a Secret. Both activities hand back a `SecureString`, so the env-var injection is identical.

`vm-exec` **does not ship through `release.sh`** — see `RUNBOOK.md`.

### Deviations from `DESIGN-phase-runner.md`

- **State is one archive, `<runId>/state.zip`, not a `<runId>/state/` prefix.** Per-file sync
  needs `ListStorageFiles`, whose XAML signature is unverified here; a single
  `DownloadStorageFile` / `UploadStorageFile` pair uses only the activity shape this workflow
  already proves. `run-phase.ps1` expands the archive into `C:\vm-agent\notes\<runId>` on entry
  and rewrites it in a `finally`, so early exits still push state. To read a notebook by hand:
  download `<runId>/state.zip` and unzip it.
- **One in-argument `StateKey`, not `StatePullPrefix` + `StatePushDir`.** The local path is
  derived from `RunId` in both the XAML and the script.
- **Two extra decision nodes**, `decisionReproRan` and `decisionInvestigated`, so a runner that
  never printed a status is reported as infrastructure instead of "not reproduced".
- The investigator's allowed-tools list includes `Write` (the notebook is its deliverable) on top
  of the design's read-only set.

### Verify runs against a local studio bundle

`studio-alpha` loads the flow MFE from **alpha's deployed bundle**, so a patch to product source
under `packages/` or `apps/` would apply cleanly, run, and change nothing. Verify rewrites
`--project studio-alpha` to `--project studio-local`, which keeps the alpha backend but points
the `remoteflow` Module Federation remote at a locally served bundle
(`e2e/fixtures/base-test.ts:213`, via `SW_MFE_OVERRIDES` in localStorage).

Verify boots `corepack pnpm run dev:studio` (rsbuild, ~1m11s cold) before the test, probes
3000/3001 for `remoteEntry.js`, pins the winner via `E2E_STUDIO_PORT`, and `taskkill /T /F`s the
tree afterwards. `TimeoutMinutes` is 30. The fixer's system prompt does not forbid product
source; it forbids dependency bumps, lockfiles and generated files.

## NightlyOrchestrator

A second flow in the same solution (`vm-agent/NightlyOrchestrator/`). It takes one nightly
Playwright run's failures and works through the first `maxTests` of them one at a time over
`VmAgent` (one child job each, sequentially, until the wall-clock budget runs out). Each child
posts its own report into the Slack thread as it finishes; the orchestrator adds a roll-up at
the end.

Shape: `start -> selectTests -> investigate` (sequential loop with a budget check:
`withinBudget -> callVmAgent -> recordResult`) `-> summarize -> replyInSlackThread1 -> end`.
17 nodes.

### Trigger inputs

| input | type | default | what |
|---|---|---|---|
| `runId` | string | — | GitHub Actions run id, used in the summary and as the VmAgent runId seed |
| `sha` | string | — | commit under test |
| `runUrl` | string | — | link to the Actions run |
| `reportUrl` | string | — | link to the Playwright report |
| `slackTs` | string | `""` | `thread_ts` of the Slack message to reply under; empty posts top-level |
| `failedTests` | array | — | `[{ environment, file, title, error }]` from the nightly |
| `environments` | string | `studio-*,vsix-*` | glob over Playwright project names; `selectTests` drops non-matching tests |
| `maxTests` | number | `4` | how many uncovered failure groups to investigate tonight (workload cap, not concurrency) |
| `budgetMinutes` | number | `240` | wall-clock budget for the investigate queue; the loop admits no new child past the deadline |
| `repoUrl` | string | `https://github.com/UiPath/flow-workbench` | repo VmAgent checks out |
| `branch` | string | `develop` | branch VmAgent checks out |
| `claudeModel` | string | `claude-sonnet-5` | model the phases pass to `claude -p` on the VM; empty would fall through to the CLI's account default, which is Opus |

Sample payloads: `inputs/orchestrator-34015558366.json` (2026-09-06 nightly),
`inputs/orchestrator-34089391590.json` (2026-09-07 nightly, 6 tests, 3 causes).

The operational contract for `maxTests` and `budgetMinutes` — which values are canaries, what a
manual run may use, and the cost of raising the default — is in `RUNBOOK.md`.

### Behaviour

- **One `VmAgent` per failure cause, not per test.** `selectTests` dedupes `file + title` across
  shards, then groups by the first error line (digits/hashes ignored): a named `Error:` groups
  across spec files (shared infra failure, e.g. the auth-redirect error), a bare
  `TimeoutError`/locator message only within its file. Biggest group is investigated first; the
  rest of a group is listed as siblings in the Slack row. `total` counts groups, `totalTests` tests.
- **The loop is sequential, so concurrency is 1 by construction.** `investigate` runs
  `parallel: false` with `breakEnabled: true`: one `VmAgent` child at a time, in order, rather
  than fanning every selected group out at once. `maxTests` is the *nightly workload cap*, not a
  concurrency limit — it says how many groups we are willing to spend the night on. Going
  sequential also retires the earlier worry about `recordResult` reading node-scoped
  `$vars.callVmAgent.output` while `currentItem` is iteration-scoped: that only mattered under
  `parallel: true`, where more than one iteration could be in flight at once. A bigger robot pool
  is not an excuse to raise `maxTests` further — it calls for batching instead: chunk `selected`
  into groups of N and nest a parallel inner loop inside a sequential outer one.
- **Wall-clock budget.** `budgetMinutes` (default 240) is turned into a `deadline` inside
  `pickTests`, and a `withinBudget` decision node runs between iterations of the loop — before
  each new `VmAgent` child is started, not while one is running. So the worst-case overrun is the
  budget plus one child run: a VmAgent child has no timeout input of its own, but its four phase
  nodes are each `TimeoutMinutes: 45`, so once a child has been admitted, reserve three hours for
  it. The scheduled run starts around 02:00 ET, so with the 240-minute default the loop admits no
  new child after roughly 06:00 ET and the whole run finishes by roughly 09:00 ET, ahead of the
  working day.
- **Slack replies work through the `thread_ts` body field** of the connector's
  `send_message_to_channel_v2`. `thread_ts` is `=js:$vars.start.output.slackTs || undefined`, so
  an empty `slackTs` posts a top-level message instead of failing. Channel `C0AH25MT3L5`,
  connection `david.rios` (`uipath-salesforce-slack`), **`send_as=user`** — the bot identity got
  `channel_not_found` on run 55f82a07 (the app is not a member of `#flow-dev-frontend`), the user
  token is. The node id is **`replyInSlackThread1`**; `uip maestro flow node add` does not let you
  choose an id. The per-group file upload is the one Slack call that does *not* go through the
  connector — it needs `files.completeUploadExternal`, which the connector has no operation for,
  so it runs on the VM against the `SLACK_BOT_TOKEN` asset and therefore posts as the app. That app
  must be a member of `#flow-dev-frontend` or the upload gets the same `channel_not_found`.
- **Open/merged PR check before investigating.** `ghPrs` is a `vm-exec-vm` job (no state key,
  5 min) whose PowerShell calls the GitHub API with the injected `GH_TOKEN`: the 40 most recently
  updated PRs, kept if open (updated ≤14 days) or merged ≤48 h, each with its changed-file
  basenames, printed as one compact `PRS_JSON=[{n,t,s,f}]` line (≈20 KB). `parsePrs` expands it;
  `pickTests` marks a group covered when a PR touches its spec file or a page object named in its
  error line (`StudioProjectsPage`, `…Dialog`, `…Rail`…), and gives the `maxTests` slots to
  uncovered groups. `recordResult` also relates VmAgent's hypothesis to those PRs. Why on the VM:
  the Integration Service GitHub connector returns ~20 KB per PR and Maestro faulted with "The
  instance's variables exceed the maximum allowed size" even at 10 PRs; 153 PRs with patches also
  stalled a parallel loop for 10+ minutes. Keep flow variables small.
- **CI hand-off:** flow-workbench PR
  [#3756](https://github.com/UiPath/flow-workbench/pull/3756) posts this payload from the nightly
  workflow. It resolves the release by process name `NightlyOrchestrator`, so do not rename the
  process.

## vsix projects

The vsix Playwright projects drive a real VS Code through `e2e/vsix/launcher.ts` rather than a
browser. They run on this pool.

**A window is not required, and that was the one thing that could have killed this.** Jobs run as
`NT AUTHORITY\LOCAL SERVICE` in session 0: a headed VS Code never gets a window
(`MainWindowHandle` stays 0) and `Graphics.CopyFromScreen` throws "The handle is invalid". But
Playwright attaches over the debug port and records via CDP screencast, neither of which needs a
desktop — `--remote-debugging-port` exposes the `workbench.html` target and
`Page.captureScreenshot` returns a real painted frame. Established with
`vm/probes/vsix-desktop.ps1` and `vm/probes/vsix-cdp.ps1`, run through `probe-script.sh`.

What the runner does for a vsix command:

| step | where |
|---|---|
| drop the platform/host segments (`vsix-staging-linux` -> `vsix-staging`) | `Resolve-TestCommand`, prologue |
| pin `HOME`/`USERPROFILE` to `C:\vm-agent\home` | `Set-VsixHome` |
| install `@uipath/cli` through the repo's `.npmrc` | `Ensure-UipCli` |
| write `<home>\.uipath\.auth` by running the repo's own `.github/scripts/vsix-interactive-login.mjs` | `Ensure-VsixAuth` |
| build the extension before the repro test, and after the fixer's patch | `Build-Vsix` |

- **The platform segment is dropped for execution and kept as evidence.** It names the runner that
  produced the failure and this VM is a different one, but "red on Linux, green on macOS" is the
  difference between a product bug and a runner-environment one. `evidence.json` carries
  `requestedProject` and the investigator prompt states it.
- **`Ensure-VsixAuth` picks the environment from the project name** — `vsix-staging` logs into
  `ap4ao`/`euTenant`, `vsix-alpha` into `experiencestest`/`DefaultTenant` — and re-logs in when the
  environment changes, since one credential file cannot serve both.
- **Verify has no dev server on this path.** `studio-local` exists because `studio-alpha` loads a
  deployed bundle; a vsix run already launches the extension built from the working tree, so the
  fix phase builds after the patch and runs the command unchanged. The fixer is told which of the
  two shapes it is looking at (`{{VERIFY_NOTE}}`).

### ci-history verdicts

Verdicts are computed per platform as well as per night, printed when they disagree, and
summarised as a `PLATFORM SPLIT` line. `absent` does not count as disagreement — counting it made
the split fire on 8 of 8 runs, and a signal that always fires is noise. The two parsing bugs this
replaced are in `TRAPS.md`.
