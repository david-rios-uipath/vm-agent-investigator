# vm-agent — handoff

Last updated 2026-09-08 ~19:45 UTC. Written for an agent or human with no prior context.
Read this file, then `FINDINGS-uip.md` (CLI/platform traps — several will bite you), then
`DESIGN-phase-runner.md` (the restructure that is now implemented and released).

## What this is

`~/code/vm-agent-investigator` builds a UiPath Maestro Flow (`VmAgent`) that investigates a
failing Playwright e2e test in `UiPath/flow-workbench`, on a Windows robot VM driven by one RPA
process (`vm-exec`, a PowerShell runner).

Up to and including 1.0.24 the reasoning lived in the cloud: three inline agents (investigator,
fixer, summarizer) drove the VM through ~34 `vm_exec` tool calls, each its own Orchestrator job.
That only worked because the robot pool has a single VM, so state left on disk survived between
jobs. `DESIGN-phase-runner.md` explains why that had to change.

**The phase runner is released and has run clean end to end** — see "First full run" below.
The shape: four coarse RPA jobs,
the LLM reasoning moved onto the VM as `claude -p`, and every job self-contained — it refreshes
the checkout, pulls its state from the bucket, and pushes it back. See "Phase runner" below.
`PLAN.md` describes the superseded agent-driven shape and the run economics.

**Goal:** a deployed (not Studio-Web-debug) run that goes start → investigate → fix → verify →
summarize without human intervention.

## Phase runner (in the tree, not yet released)

Everything below `vm/` is new and runs ON the VM; the flow only orchestrates it.

| file | what |
|---|---|
| `vm/run-phase.ps1` | one `switch ($Phase)` over `repro`, `investigate`, `fix`, `pr`; same prologue and epilogue for each |
| `vm/lib/prologue.ps1` | `Ensure-Tools` (rg, gh, pnpm shim, Claude Code — idempotent), `Refresh-Repo`, `Invoke-Cmd`, `Write-Utf8Lf`, `Write-Status` |
| `vm/lib/ci-history.ps1` | the old `ciHistoryInstructions` node, ported to a function |
| PR video | both the `repro` run and the verified `fix` run record with `E2E_RECORD=1`; `Save-DemoVideo` (prologue) converts each webm to mp4+gif with the same arguments as flow-workbench `scripts/record-demo.sh`, into `bug-demo.*` and `fix-demo.*`. The `pr` phase attaches both with `gh pr create --attach` (needs gh >= 2.99; the VM has 2.100) and the body names the order, since gh appends attachments and a video takes no alt text. On the CI-settled path (`source='ci'`) the spec never runs here, so there is no clip and the body links the failing nightly run instead. `bug-demo.mp4` rides in `state.zip` from `repro` onward; the raw webms are deleted before the `test-results` copy so the 25 MB guard still holds. |
| `vm/prompts/{investigator,fixer}.md` | the two agent prompts, rewritten for real file tools |
| `vm/selfcheck.ps1` | `pwsh -NoProfile -File vm/selfcheck.ps1` — 23 asserts over the pure logic (status line, patch encoding, PR title, repro routing). Passes. |
| `release-vm-exec.sh` | publish `vm-exec` and repoint `e2e-investigator/vm-exec-vm`: `./release-vm-exec.sh 1.0.4` |
| `probe-phase.sh` | run one phase through `vm-exec-vm` without packing: `RUNNER_REPO_URL=… ./probe-phase.sh repro <runId>` |

Flow shape now: `start -> deriveRunId -> decisionResume -> bootstrap<Phase> -> <phase RPA node>
-> parseStatus<Phase> -> decision… -> investigationSummarizer -> end`, 29 nodes. The four
`bootstrap*` script nodes emit a ~15-line PowerShell that clones this repo to
`C:\vm-agent\runner` at `runnerRef` and invokes `vm/run-phase.ps1` — so a runner change is a
git push, not a solution release. Each phase prints one `STATUS_JSON=<json>` line as its last
line of stdout and `parseStatus*` parses only that; its absence routes to `endSetupFailed`.

New trigger inputs: `maxFixAttempts` (3), `runnerRepoUrl`, `runnerRef` (`master`), and
`claudeModel` — **defaults to `claude-sonnet-5`**, and `NightlyOrchestrator` passes the same value
to every child rather than an empty string. Empty means the CLI's account default on the VM, which
is Opus: a single investigate pass cost $4.51 and a fix pass $2.29 on 2026-09-08, which is the
wrong default for a job that is meant to run nightly. Set `claude-haiku-4-5-20251001` when testing
plumbing rather than reasoning — `probe-phase.sh` reads the same lever from `CLAUDE_MODEL`, and
also defaults to Sonnet now. The summarizer agent node stays on `anthropic.claude-opus-4-8`: it runs through the LLM gateway,
which is billed separately from the Claude Code account the phases use. If it ever does move, that
model lives in `VmAgent.flow` **and** in two `agent.json` copies, all three of which must be
patched together.
`probe-phase.sh` reads the same lever from `CLAUDE_MODEL`. `maxIterations`
and the `iteration` global are gone with the investigator loop.

`vm-exec` (`vm-agent/vm-exec/Main.xaml`) gained: an `ANTHROPIC_API_KEY` Credential asset,
injected as an env var and added to the redaction list; a `StateKey` in-argument; defaults
raised to 45 minutes and 32000 output chars.

Three deliberate deviations from `DESIGN-phase-runner.md`:

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

The investigator's allowed-tools list includes `Write` (the notebook is its deliverable) on top
of the design's read-only set.

### What is NOT verified

Nothing here has run. In particular:

- The runner repo is `https://github.com/david-rios-uipath/vm-agent-investigator` (public,
  branch **`master`** — `runnerRef` defaults to `master`, not `main`). It is public so the VM
  needs no token to clone it, but `GIT_TOKEN` has never actually fetched it from the VM.
  **Every runner edit must be pushed before a phase job runs it**; the bootstrap fetches the
  ref, it does not read your working tree.
- `claude -p` has never been run on a Windows robot account. `Ensure-Tools` installs it with
  `npm install -g --prefix C:\vm-agent\node-global` and pins `CLAUDE_CONFIG_DIR` to
  `C:\vm-agent\claude-home`, on the assumption `%USERPROFILE%` is not dependable there.
- `ANTHROPIC_API_KEY` exists in `e2e-investigator` as a **Secret** asset, so `vm-exec` reads it
  with `ui:GetSecret`, not `ui:GetRobotCredential` (the other three tokens are Credential
  assets). Both hand back a `SecureString`, so the env-var injection is identical. **Verified
  on the VM 2026-09-05:** the key arrives (108 chars), `GH_TOKEN` and `GIT_TOKEN` are present,
  `SLACK_TOKEN` is not.
- **State pushes fail silently if any file in the state directory is locked.** The studio dev
  server holds `studio-dev.log` open past the end of the fix phase, so `Compress-Archive` threw
  `IOException` for the whole set and, with `-ErrorAction SilentlyContinue`, several fix runs
  pushed nothing at all while still reporting success. The `pr` phase only worked because the
  single-VM pool still had the files on local disk - exactly the assumption this restructure
  exists to remove. Fixed: the dev log lives outside the state dir, the archive is staged
  through a copy that skips unreadable files, and a failure is printed rather than swallowed.
- **`vm-exec` 1.0.5 is published and live** (`vm-exec-vm` points at it). `StateKey` round-trips
  through the bucket in both directions, proven by wiping the VM's local copies from a job with
  no `StateKey` and then pulling them back from one with it.
  **`vm-exec` does not ship through `release.sh`.** `release.sh` packs the solution (the flow
  plus an in-solution `vm-exec` that nothing calls); the process the phase nodes invoke is
  `vm-exec-vm` in the standard folder `e2e-investigator`, bound to the tenant-feed package
  `vm-exec` — published with `uip rpa pack` + `uip rpa publish`, then `uip or processes
  update-version`. `./release-vm-exec.sh <version>` does all three.

  **Pack it with the pinned toolchain, which that script now bootstraps.** Robot 25.10 on this
  pool runs .NET 8; `uip` 1.201 packs `net10.0`, and the job faults in four seconds with
  `NU1202: Package vm-exec 1.0.4 is not compatible with net8.0`. 1.0.4 shipped exactly that way
  and had to be rolled forward to 1.0.5, packed with CLI `1.197.0-dev.7683` plus a local .NET 8
  SDK at `~/.dotnet8`. The script now asserts the packaged `lib/` target is `net8.0` before it
  publishes. (This trap was already in the session memory and I walked into it anyway.)
- The migration order in the design (one phase at a time through `probe-phase.sh`) is still the
  right way to bring this up — start with two consecutive `repro` probes on the same VM.

## First full run from the trigger (1.0.29, 2026-09-05)

Instance `f5893ef7-3655-4077-9021-fe5e0a49109e`, 03:52-04:27 UTC, 35 minutes, `Successful`:
`repro` (2 min, reproduced) -> `investigate` (6 min) -> `fixVerify` (17 min, attempt 1 not
verified) -> `bumpFixAttempts` -> `fixVerify` (8 min, `FIX_VERIFIED=true`) -> `openPr`
-> `investigationSummarizer` -> `end`. Classification `regression`, `reproduced=true`,
`fixVerified=true`, PR opened on the one-file spec fix. The retry loop
(`decisionVerify` false -> `bumpFixAttempts` -> `fixVerify`) is now exercised too.

Draft PRs from a test run get closed and their branch deleted straight away - do not leave
them on `UiPath/flow-workbench`. #3717, #3719 and #3720 were all closed this way.

Four bugs stood between the first trigger run and that one. All four were invisible to
`probe-phase.sh`, which drives `vm-exec-vm` directly and never evaluates a flow expression:

- **The status line was mangled by a codepage.** The VM printed valid `STATUS_JSON=`, but
  stdout returns through a legacy codepage, so an em-dash in the notebook arrived as bytes
  ending in a literal `"`; `JSON.parse` died at column 440 and `parseStatusInvestigate`
  reported `runnerFailed` after a perfect 7-minute investigation. `Write-Status` now escapes
  every non-ASCII char to `\uXXXX`; two selfcheck asserts cover it.
- **`deriveRunId` matched the first `.ts` in the test command**, which is
  `playwright.config.ts`, so runs were named `playwright.config-<stamp>`. It prefers a
  `.spec.ts` match now.
- **The agent package, not the flow node, is what runs.** The summarizer's prompt mixed
  `{{input.NAME}}` (substituted) with `{{ (($agent.X || {}).y) }}` expressions (not
  substituted), so every field sourced from a phase status reached the model as literal
  braces and it terminated with `AGENT_RUNTIME.TERMINATION_LLM_RAISED_ERROR`, "investigation
  inputs are unresolved template placeholders" - twice, each time after a verified fix and an
  opened PR. Every placeholder is a plain `{{input.a__b__c}}` now, mirroring the flow node's
  `{{ $vars.a.b.c }}`, with the null guards in the bindings. **Editing `VmAgent.flow` by hand
  does not regenerate `<agentId>/agent.json`; patch both, plus `.agent-builder/agent.json`.**
- **The parse nodes advertised `output` as untyped `any`**, so the designer showed
  `output 0 keys` and every `$vars.parseStatusX.output.field` was an unresolvable red pill
  (the RPA nodes' own fields resolve because they carry a schema). Each `parseStatus*` node
  now declares the union of its success payload and its `runnerFailed` fallback.

`uip solution deploy run` also returned an HTTP 504 once, after `release.sh` had already
uninstalled the previous deployment - the folder was left empty and the run never started.
Re-running the same `deploy run` by hand fixed it; the script has no retry there.

## Second full run, and the PR description (2026-09-05)

Instance from job `fe223250-a461-4e30-9729-4ecb8dae5944`, 13:00-13:28 UTC, 28 minutes,
`Successful`, on a spec it had never seen: `data-transform.spec.ts` "should add a Map operation
with field mappings", the neighbor-rail regression from that night's triage. Evidence source was
`ci` (no local Playwright artifacts), classification `regression`, fix verified on attempt 1,
draft PR **flow-workbench#3729** on a two-file product patch under `packages/canvas/`. Left open
as a draft deliberately, as the sample of the new description - close it when done reading.

The description is now written for a reviewer, in `vm/lib/pr-body.ps1` (`New-PrBody`), checked by
`vm/tests/pr-body.tests.ps1` (runs anywhere pwsh runs, no VM):

- one sentence of Problem, one of Solution, everything else behind `<details>` - failure output
  and CI window, then the fix with its file list and verification log, then the notebook verbatim.
- the fixer returns `problem` and `solution` one-liners plus `fixSummary` as bullets; the
  investigator writes a `Ruled out:` line per pass, since the notebook is published now.
- built line by line, not from a here-string: notebooks and logs contain `$` and backticks.

#3729 exposed three defects in that first body, all fixed in `c933ef1`: the spec name resolved to
`playwright.config` (the pattern's plain `.ts` branch wins over `.spec.ts` - the deriveRunId trap
again), the fenced logs carried codepage mojibake and raw ANSI escapes, and the verification
sentence claimed a pass without reading `verified`.

## NightlyOrchestrator

> Deployment moved to **`vm-agent 12`** (folder `Shared/vm-agent 12`) on 2026-09-08: `vm-agent 11` is wedged with three
> Maestro jobs stuck in `Terminating` after `jobs stop --strategy Kill`, so its uninstall fails validation. Leave it; do not
> kill Maestro flow jobs, cancel the instance instead. CI (`start-nightly-investigation.sh`) targets the new folder.

A second flow in the same solution (`vm-agent/NightlyOrchestrator/`). It takes one nightly
Playwright run's failures, fans the first `maxTests` of them out over `VmAgent` (one child job
each), and posts a single summary back into the Slack thread that reported the failure.

Shape: `start -> selectTests -> investigate` (parallel loop: `callVmAgent -> recordResult`)
`-> summarize -> replyInSlackThread1 -> end`. Eight nodes.

Trigger inputs:

| input | type | default | what |
|---|---|---|---|
| `runId` | string | — | GitHub Actions run id, used in the summary and as the VmAgent runId seed |
| `sha` | string | — | commit under test |
| `runUrl` | string | — | link to the Actions run |
| `reportUrl` | string | — | link to the Playwright report |
| `slackTs` | string | `""` | `thread_ts` of the Slack message to reply under; empty posts top-level |
| `failedTests` | array | — | `[{ project, file, title, error }]` from the nightly |
| `projects` | string | `studio-*` | glob; `selectTests` drops tests from non-matching projects |
| `maxTests` | number | `1` | how many of the surviving tests to investigate |
| `repoUrl` | string | `https://github.com/UiPath/flow-workbench` | repo VmAgent checks out |
| `branch` | string | `develop` | branch VmAgent checks out |
| `claudeModel` | string | `claude-sonnet-5` | model the phases pass to `claude -p` on the VM; empty would fall through to the CLI's account default, which is Opus |

Sample payloads: `inputs/orchestrator-34015558366.json` (2026-09-06 nightly),
`inputs/orchestrator-34089391590.json` (2026-09-07 nightly, 6 tests, 3 causes).

- **One `VmAgent` per failure cause, not per test.** `selectTests` dedupes `file + title` across
  shards, then groups by the first error line (digits/hashes ignored): a named `Error:` groups
  across spec files (shared infra failure, e.g. the auth-redirect error), a bare
  `TimeoutError`/locator message only within its file. Biggest group is investigated first; the
  rest of a group is listed as siblings in the Slack row. `total` counts groups, `totalTests` tests.

- **`maxTests` must equal the robot pool's VM count — today that is 1.** The loop is
  `parallel: true`, so each selected test starts its own `VmAgent` job at once; with one VM the
  extra jobs queue behind the first and time out. Grow `maxTests` only when the pool grows.
- Second reason: `recordResult` reads `$vars.callVmAgent.output`, which is node-scoped, while
  `currentItem` is iteration-scoped; with `parallel: true` and more than one iteration,
  cross-iteration reads are possible unless the runtime scopes node outputs per iteration.
  Unproven — verify with 2 tests before raising `maxTests` above 1.
- **Slack replies work through the `thread_ts` body field** of the connector's
  `send_message_to_channel_v2`. `thread_ts` is `=js:$vars.start.output.slackTs || undefined`, so
  an empty `slackTs` posts a top-level message instead of failing (unverified: no run has reached
  the Slack node yet). Channel `C0AH25MT3L5`,
  connection `david.rios` (`uipath-salesforce-slack`), **`send_as=user`** — the bot identity got
  `channel_not_found` on run 55f82a07 (the app is not a member of `#flow-dev-frontend`), the user
  token is. The node id is
  **`replyInSlackThread1`** — `uip maestro flow node add` does not let you choose an id.
- **Open/merged PR check before investigating.** `ghPrs` is a `vm-exec-vm` job (no state key, 5 min) whose
  PowerShell calls the GitHub API with the injected `GH_TOKEN`: the 40 most recently updated PRs, kept if open
  (updated ≤14 days) or merged ≤48 h, each with its changed-file basenames, printed as one compact
  `PRS_JSON=[{n,t,s,f}]` line (≈20 KB). `parsePrs` expands it; `pickTests` marks a group covered when a PR
  touches its spec file or a page object named in its error line (`StudioProjectsPage`, `…Dialog`, `…Rail`…),
  and gives the `maxTests` slots to uncovered groups. `recordResult` also relates VmAgent's hypothesis to those
  PRs. Why on the VM: the Integration Service GitHub connector returns ~20 KB per PR and Maestro faulted with
  "The instance's variables exceed the maximum allowed size" even at 10 PRs; 153 PRs with patches also stalled a
  parallel loop for 10+ minutes. Keep flow variables small.
- **CI hand-off:** flow-workbench PR
  [#3756](https://github.com/UiPath/flow-workbench/pull/3756) posts this payload from the
  nightly workflow. It resolves the release by process name `NightlyOrchestrator`, so do not
  rename the process.

Release and run it:

```bash
./release.sh 1.1.2 inputs/orchestrator-34089391590.json NightlyOrchestrator
```

`release.sh` now takes an optional third argument, the process to start (default `VmAgent`);
both processes are deployed either way. The packaged-bindings assertion covers both flows now —
`VmAgent` must still carry `e2e-investigator.vm-exec-vm`, and `NightlyOrchestrator` must carry
the `VmAgent` process binding `4a7879cf-7494-4ada-9e83-ea487a4b55cb`.

### Status 2026-09-08 04:15 UTC

Deployed: `vm-agent 8` **1.1.12** as `vm-agent 12` (folder `Shared/vm-agent 12`). Proven end to end on the 2026-09-07
nightly (`inputs/orchestrator-34089391590.json`, thread `1788766695.830989`): 6 failed tests -> 3 causes; 2 causes
attributed to merged flow-workbench#3758 by the PR check; the third investigated by VmAgent (reproduced, no verified
fix, related PR #3758 named); one Slack reply, posted as David. Runs today: 1.1.1 (Slack `channel_not_found`), 1.1.2
(Slack OK, stale code republished), 1.1.3 (grouping OK), 1.1.4-1.1.11 (PR check via the GitHub connector: wrong
`repo` param, loop typo, 153 PRs stall, variable-size cap), 1.1.12 (PR check on the VM, OK).

Open:
- flow-workbench PR #3756 (CI hook) is still a draft; CI vars/secrets are set (`UIPATH_INVESTIGATOR_*`). The CI
  script has not been run against the tenant yet (token exchange unverified).
- `vm-agent 11` deployment is wedged (three Maestro jobs `Terminating` after `jobs stop --strategy Kill`). Uninstall
  it once Orchestrator clears them; report the Kill behaviour to the Maestro team.
- Slack "edit one message" request: the connector has no update op; needs an HTTP `chat.update` with a token asset.
- vsix runs on the VM now (see "vsix projects" below); `projects` defaults to `studio-*,vsix-*`.
- `maxTests` stays 1 until the pool grows; also verify iteration scoping before raising it.
- Slack renders `<`/`>` from the hypothesis escaped (`&lt;nav&gt;`); strip them in `summarize`.
- VmAgent still reproduced the Map-operation failure on `develop` after #3758 merged; #3758 may not cover it.

## vsix projects (2026-09-08)

The vsix Playwright projects drive a real VS Code through `e2e/vsix/launcher.ts` rather than a
browser. They run on this pool.

**A window is not required, and that was the one thing that could have killed this.** Jobs run as
`NT AUTHORITY\LOCAL SERVICE` in session 0: a headed VS Code never gets a window
(`MainWindowHandle` stays 0) and `Graphics.CopyFromScreen` throws "The handle is invalid". But
Playwright attaches over the debug port and records via CDP screencast, neither of which needs a
desktop - `--remote-debugging-port` exposes the `workbench.html` target and `Page.captureScreenshot`
returns a real painted frame. Established with `vm/probes/vsix-desktop.ps1` and
`vm/probes/vsix-cdp.ps1`, run through the new **`probe-script.sh <file.ps1>`**, which sends a local
script to `vm-exec-vm` inline - no push, no pack, no deploy. That script is the cheapest way to ask
the VM a question.

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
- **`Ensure-VsixAuth` picks the environment from the project name** - `vsix-staging` logs into
  `ap4ao`/`euTenant`, `vsix-alpha` into `experiencestest`/`DefaultTenant` - and re-logs in when the
  environment changes, since one credential file cannot serve both.
- **Verify has no dev server on this path.** `studio-local` exists because `studio-alpha` loads a
  deployed bundle; a vsix run already launches the extension built from the working tree, so the
  fix phase builds after the patch and runs the command unchanged. The fixer is told which of the
  two shapes it is looking at (`{{VERIFY_NOTE}}`).
- **`Build-Vsix` clears `packages/vsix/.mfe-cache` and retries once.** `fetch-mfe-assets.mjs` stages
  through renames; one EPERM leaves that cache in a state every later build trips over - the next
  build fails at `rebuildCache`'s rename, the one after at `stageDestination`'s, so it reads as
  permanent. Two builds failed that way on the pool VM and a third succeeded with nothing changed
  but the cache removed. The single-VM pool means a poisoned cache outlives the job that made it.
- **`probe-phase.sh` takes `TIMEOUT_MINUTES`.** A cold vsix repro outlasts the 15-minute default and
  returns `exitCode 124` having proven nothing.

Two ci-history bugs came out of this, both of which had been quietly wrong:

- **Windows runners print ASCII marks.** Playwright's list reporter emits `ok`/`x` where the terminal
  cannot do Unicode. The mark regex took only the checkmark and ballot-X, so **every Windows job had
  always parsed as "the spec never ran there"** - invisible while the only jobs read were the Linux
  studio shards.
- **The job filter missed vsix jobs entirely.** Studio shards are `E2E (studio-alpha) [2/5]`, but a
  vsix job carries its platform inside the same parens: `E2E (vsix-alpha, Linux)`. Matching only
  `($project)` found nothing, so every vsix spec classified as `absent` and the investigator got no
  history at all.

Verdicts are now computed per platform as well as per night, printed when they disagree, and
summarised as a `PLATFORM SPLIT` line. `absent` does not count as disagreement - counting it made the
split fire on 8 of 8 runs, and a signal that always fires is noise.

### Proven end to end, `vsix-pkg-3` (2026-09-08)

`e2e/specs/vsix/package-nested-solution.spec.ts:48` on `vsix-alpha-windows`, one phase at a time
through `probe-phase.sh`, no flow and no deployment:

- `repro` - reproduced from CI evidence. History after the two fixes above:
  `09-08 failed (Linux failed, macOS flaky, Windows failed); 09-07 failed (Linux failed, macOS
  passed, Windows failed); 09-06 passed; 09-05 failed (Linux passed, macOS passed, Windows failed)`.
  Windows broke two nights before Linux did.
- `investigate` - four passes, 13 min, $4.51. Cause: `UiPath: Package` is contributed to the palette
  only under `when: "uipath.authenticated"` (`packages/vsix/package.json:531-534`), false until a
  background `uip` probe succeeds (`authService.ts:940, 954-984`); on nights carrying identity-429s
  the row never renders and the wait at `VsixWorkbenchPage.ts:140` times out. The 429s come from
  `playwright-vsix.yml:126-133` signing one account in from three OS legs at once. It refuted its own
  Pass 3 claim in Pass 4 and left the Windows-only 09-05 night explicitly unexplained.
- `fix` - `fixVerified=true` in 11 min, $2.29: patch -> build (cache recovery fired) -> real VS Code
  run -> `1 passed (2.1m)`.

**A green verify is not evidence the fix repairs the nightly.** The established cause is an identity
429 that cannot occur on the VM, which logs in fresh as a single leg. It means the patch is sound and
the spec passes; the fixer said `confidence: medium` and that is the honest reading.

Two defects for flow-workbench found along the way, both real independent of this tooling:

- `e2e/vsix/launcher.ts:191` reads the POSIX `process.env.HOME` for the `seedAuth` copy, so it is a
  silent no-op on Windows. The same repo resolves the same path correctly with `os.homedir()` at
  `package-nested-solution.spec.ts:3`. Not a cause - the CLI has an `os.homedir()` fallback - but a
  portability defect.
- The three OS legs share one tester account with no `max-parallel`, which is the environment cause
  behind the platform split.

Still unproven for vsix: the `pr` phase (platform-agnostic and proven for studio), and any run
driven by the flow rather than by `probe-phase.sh`.

### First deployed run (1.1.0, 2026-09-07) — blocked on the robot pool, not the flow

Parent job `66304ff4-336f-467d-b346-925cdbce32e1`, instance `NightlyOrchestrator-56249860`,
started 17:54:49 UTC. It reached `investigate` and stayed there:

- `start -> selectTests -> investigate -> callVmAgent` all ran; the child `VmAgent` job
  `58bd94d1-dbef-46b0-8f76-c1ce6622be07` started 8 s after the parent. **The in-solution process
  binding resolves in a deployed folder** — that was the main unknown and it is settled.
- `Incidents: null` throughout. The orchestrator has no fault of its own.
- The child never left `repro`: its `vm-exec-vm` job `de5a3c2c-66b7-48d6-b2b6-0992c16c9b0e` sat
  `Pending` with no host. **No robot in the `e2e test investigation` pool has sent a heartbeat
  since 2026-09-06T21:05:12Z** — check with
  `uip or sessions unattended list --folder-path e2e-investigator` and read `ReportingTime`.
  A `Pending` phase job with `HostMachineName: None` means the pool, not the flow.
- Polled to 19:30 UTC (95 min): the three states never changed. So `recordResult`, `summarize`
  and `replyInSlackThread1` are still unrun and no Slack reply has been posted. Bring the pool
  back, then `./release.sh 1.1.1 /tmp/orch-1.json NightlyOrchestrator`.

Two deploy details that are easy to get wrong:

- The orchestrator's `deploy-config.json` `packageName` is **`vm-agent.8.Flow.NightlyOrchestrator`**
  — capital `Flow`, and `8` not `7`. `pack` derives it from the solution package name (`vm-agent 8`)
  for projects that have no stored `spec.packageName`; the two older projects still carry the
  `vm-agent.7.…` names they were packed with. Read the name out of the zip rather than guessing:
  `unzip -l /tmp/vm-agent-pkg/*.zip | grep nupkg`.
- Its `resourceKey` is `dfa7e85b-4aa9-4549-a0f3-008bcf2dbc29`, from
  `vm-agent/resources/solution_folder/process/flow/NightlyOrchestrator.json` (`resource.key`) —
  `project.uiproj` does not carry one.

## Current state (as released)

- **Deployment:** `Shared/vm-agent 12` @ **1.0.24**, package identity `vm-agent 8`.
- **1.0.24 ran the whole loop including the PR, in 17 minutes** - instance
  `62b22f65-ae3f-4c80-89f2-d295eb59f104`, 17:16-17:33 UTC: smoke setup -> resume -> fixer
  (11 min) -> studio-local verify `1 passed (1.9m)` -> **draft PR
  https://github.com/UiPath/flow-workbench/pull/3687** (branch
  `e2e-investigator/debug-execution-20260904-143456`, commit `ca8ff4928`, 1 file +2/-2)
  -> summarizer -> end. The `GH_TOKEN` asset does have push scope on the repo.
- **The loop closed end to end on 1.0.23**, instance `f282004c-f256-4100-97a2-80390ae1ba17`,
  16:22-16:57 UTC: trigger -> smoke setup -> resume -> fixer -> verify `FIX_VERIFIED=true`
  -> openPr -> summarizer -> end, 35 minutes. The verify ran the real spec: `1 passed (3.4m)`.
- The fixer's patch retargets the two broken locators at `debug-execution.spec.ts:84,87` to
  match the new aria-label directly:
  `getByRole('button', { name: /^Copy path for \$vars\.\w+\.output\.name$/ })`.
- **openPr did not publish anything on 1.0.23**, and `GH_TOKEN` was not the reason (the
  script exits early with `[pr] GH_TOKEN not set` and that never printed). The commit
  succeeded - its hash `7495ff13d` is in the output - but the exit-code check read
  `$LASTEXITCODE` after `| Select-Object -First 1`, which closes the pipeline early and
  makes the code unreliable. The identical trap as `b36ec3f`. So a good commit reported
  failure, `Reset-Tree` deleted the branch, and push / `gh pr create` never ran.
  Fixed in 1.0.24; the PR title now comes from the fixer's `fixSummary` instead of a
  hardcoded `test(e2e): fix <spec>` that was wrong about what the patch did.
- **Fast iteration works now:** `smokeOnly` stubs setup + ci-history, and the new
  `resumeRunId` trigger input reuses an existing notebook on the VM and skips the
  investigator entirely (`decisionResume` routes `testEvidence -> readNotes`).
  `inputs/debug-execution-fixer.json` drives that path.

## Do this next

1. **Give the runner repo a remote and set `runnerRepoUrl`.** Until then no phase can start.
   Check `GIT_TOKEN`'s read scope on it from the VM in the same breath.

2. **Create the `ANTHROPIC_API_KEY` Credential asset** in `e2e-investigator`
   (`uip or assets create ANTHROPIC_API_KEY <key> --type Credential --credential-store-key <k>`),
   release `vm-exec`, and confirm in a job log that `claude --version` works and the key shows
   as `***ANTHROPIC_API_KEY***`.

3. **Probe the phases one at a time**, cheapest first:
   ```bash
   export RUNNER_REPO_URL=https://github.com/<owner>/vm-agent-investigator
   SMOKE_ONLY=1 ./probe-phase.sh repro probe-1     # twice: the second prologue must be < 60 s
   ./probe-phase.sh investigate <runId>
   ./probe-phase.sh fix <runId>
   ./probe-phase.sh pr <runId>
   ```
   Only then `./release.sh <version> inputs/debug-execution.json`. `release.sh` packs, asserts
   the packaged `bindings_v2.json`, publishes, stops running jobs, uninstalls + redeploys
   `Shared/vm-agent 12` and starts the job. **Never hand-run the pack step** — see FINDINGS.

4. **The old verify step**, for reference while the port is unproven:
   ```bash
   # parent + agent children
   uip or jobs list --folder-path "Shared/vm-agent 12" --output json
   # every vm_exec tool call lands here
   uip or jobs list --folder-path "e2e-investigator" --output json
   # a verify job's output contains '### patch first bytes' and FIX_VERIFIED=
   uip or jobs get <job-key> --output json
   ```
   Success looks like: `### patch was UTF-16 … re-encoding`, no `git apply` error, a test run
   lasting **minutes**, then `FIX_VERIFIED=true`. A verify finishing in <20 s means it never
   ran the test.

3. **If it faults**, get the real reason from Maestro, not Orchestrator (the parent job stays
   `Running` after the instance has faulted):
   ```bash
   FK=$(uip or folders list --all --name "vm-agent 11" --output json | \
     python3 -c "import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(next(x['Key'] for x in d['Data'] if x['Path']=='Shared/vm-agent 12'))")
   uip maestro flow instance get       <parent-job-key> -f $FK --output json   # LatestRunStatus, Cursors
   uip maestro flow instance incidents <parent-job-key> -f $FK --output json   # the actual error
   ```
   The folder key changes on every redeploy, so always re-resolve it.

4. **Save the notebook** from any completed investigation into `reports/`:
   ```bash
   uip or bucket-files list be6369c7-02a4-4b80-957b-e95d06177692 \
     --folder-path "e2e-investigator" --prefix "debug-execution-<runid>" --output json
   uip or bucket-files download be6369c7-02a4-4b80-957b-e95d06177692 "<...>/read/<...>.log" \
     --folder-path "e2e-investigator" --destination reports/<date>-run-<key>-notes.md
   ```

## Fast validation: `./probe-phase.sh`

Do **not** wait 30-60 minutes for a full flow run to test a phase. `probe-phase.sh` calls
`e2e-investigator/vm-exec-vm` directly with the bootstrap PowerShell that the flow's
`bootstrap<Phase>` node generates — **rendered from `VmAgent.flow` with node, not a copy**, so
the probe cannot drift from what the flow runs — and prints the phase's `STATUS_JSON`. State
comes from and goes back to `<runId>/state.zip`, exactly as in a real run. No pack, no publish,
no deploy. (It replaces `probe-verify.sh`, which rendered `verifyFixInstructions`; that node no
longer exists.) Find a runId with:

```bash
uip or bucket-files list be6369c7-02a4-4b80-957b-e95d06177692 --folder-path "e2e-investigator" --output json
# or read $patch out of any past verify job's Stdout
```

Same trick generalises: any single flow step whose script you want to test can be run straight
through `vm-exec-vm` this way - and `./probe-script.sh <file.ps1> [minutes]` does it for a script
that is not a flow node at all, sending your working tree inline with no push.

## Verify now runs against a local studio bundle (1.0.24, unreleased)

The earlier conclusion in this file - "no locator fix can ever return FIX_VERIFIED=true
because the test dies at line 46" - was **wrong**. Line 46 (the debug-run "Successful"
badge) is the identity-429 flake, not a hard blocker: the 16:22 run sailed past it and the
locator fix at 84/87 made the spec pass. The apollo-react finding the investigator made four
runs ago was correct and is now verified by a real test run.

What changed in 1.0.24:

- `studio-alpha` loads the flow MFE from **alpha's deployed bundle**, so a patch to product
  source under `packages/` or `apps/` would apply cleanly, run, and change nothing. Verify now
  rewrites `--project studio-alpha` to `--project studio-local`, which keeps the alpha backend
  but points the `remoteflow` Module Federation remote at a locally served bundle
  (`e2e/fixtures/base-test.ts:213`, via `SW_MFE_OVERRIDES` in localStorage).
- Verify boots `corepack pnpm run dev:studio` (rsbuild, ~1m11s cold) before the test, probes
  3000/3001 for `remoteEntry.js`, pins the winner via `E2E_STUDIO_PORT`, and `taskkill /T /F`s
  the tree afterwards. `TimeoutMinutes` raised 15 -> 30.
- The fixer's system prompt no longer forbids product source; it forbids dependency bumps,
  lockfiles and generated files instead.

Two traps found while building this, both now encoded in the script:

- **`cmd.exe /c "set VAR=value && ..."` puts the trailing space in the value.**
  `E2E_STUDIO_PORT` became `"3000 "`, Playwright fetched `http://localhost:3000 /remoteEntry.js`
  and threw; `E2E_SKIP_WEBSERVER` became `"1 "` and never matched `!== '1'`. Quote the whole
  assignment - `set ""VAR=value""` (doubled, because the string is already inside a
  double-quoted PowerShell string; a backtick escape would collide with the JS template
  literal that generates it).
- **rsbuild answers `/remoteEntry.js` with the SPA index.html fallback while still building.**
  A bare 200 is not readiness - the probe also requires the body not to start with `<`,
  otherwise the test starts mid-build against a remote that is not there yet.

Probed green at 17:10 UTC: `### studio MFE serving on port 3000`, `1 passed (1.7m)`,
`FIX_VERIFIED=true`, 4m23s total.

## What the agent has actually found (the product answer)

Two distinct failure modes on `e2e/specs/debug/debug-execution.spec.ts`, established
independently across four runs with 16-34 successful `vm_exec` calls each:

1. **Identity-service 429 flakiness** (runs `67953871`, `d99c4204`, `3bc47073`). All 5 parallel
   shards authenticate the *same* shared alpha studio account (`playwright-action.yml:183-185`),
   so identity rate-limits. Env-signal counts across 8 nights: `identity429` 12 and 6 on the two
   failed nights vs 2-4 on passing nights; `cleanup400` (14-16) only on failed nights, and it is
   shard-wide teardown noise from `StudioProjectsManager.deleteSolution`, not a cause.
2. **An apollo-react regression** (run `6d77027a`, the deeper one). The bump to 6.38.0
   (`3df679ace`) made `JsonTree`'s `NodeKey.js` set `aria-label="Copy path for {path}"` on every
   row button; that overrides the accessible name and breaks
   `getByRole('button', { name: 'output'|'name', exact: true })` at
   `debug-execution.spec.ts:84,87`. Proven with `git merge-base --is-ancestor`: the bump is
   *not* an ancestor of the 429 night `c7369f5`, *is* an ancestor of the nights showing this
   locator failure. Its proposed patch retargets both locators to
   `.filter({ hasText: /^output$/ })`.

Notebooks: `reports/2026-09-04-run-d99c4204-notes.md` (fullest), `…-3bc47073-notes.md`,
`…-67953871-notes.md`, plus `reports/2026-09-03-run-364f9617.md` (a critique of the first
successful run, worth reading for how the agent behaves).

Neither finding has been filed anywhere. Item 2 is a real, actionable e2e fix if someone wants
to take it; item 1 is an infra problem (shared account) with no tracked issue — the agent
searched GitHub and found none.

## Bugs fixed in this session (all committed)

| what | commit |
|---|---|
| agent tool 404: `pack` drops the bare `vm-exec-vm` binding from `bindings_v2.json` | `16fec0f` |
| `rg --version \| Select-Object -First 1` zeroed `$LASTEXITCODE`, aborting setup at 13 s | `b36ec3f` |
| tool `resource.json` files deleted → agents shipped with no tools | `12de81a` |
| summarizer null-deref on `verifyFix.output.Stdout`, two spellings | `baa6a52`, `9c55db7` |
| fixer's `confidence` required but written inline by the model | `89c8587` |
| fixer tool `RunId` bound to a nonexistent trigger input → logs in `manual/` | `ea140a8` |
| **patch written as UTF-16 by PowerShell `>`, so `git apply` never applied it** | `2d91e20` |
| `pack` nondeterministically drops the binding → retry loop in `release.sh` | `3685e89` |
| `testCommand` missing `--config e2e/playwright.config.ts` | `097b75e` |
| `smokeOnly` never declared in `variables.globals`, so the stubs never fired | `4e24810` |
| verify ran `studio-alpha` (deployed bundle), so product fixes were unverifiable | (1.0.24) |
| `set VAR=v &&` in cmd.exe put a trailing space in `E2E_STUDIO_PORT` / `E2E_SKIP_WEBSERVER` | (1.0.24) |
| rsbuild's index.html fallback made `/remoteEntry.js` look ready mid-build | (1.0.24) |
| openPr read `$LASTEXITCODE` after `\| Select-Object -First 1`, so a good commit "failed" | (1.0.24) |

Also added: `ciHistory` scans every sampled night's job log for environment signatures and keeps
per-night excerpts, so the agent gets the cross-night pattern as evidence instead of spending
tool calls on it (`6aa25de`); a `smokeOnly` trigger input that stubs setup and ci-history for
~2-minute iterations (`1131f28`, though it did not appear to take effect in the one run that
used it — unverified).

## Known-good baseline, if things go sideways

Package `vm-agent 8` **1.0.0**, published by Studio Web from solution
`6c998cb3-078b-4c80-dfce-08df093139b4`, ran clean on 2026-09-03 04:59-06:21 UTC (instance
`364f9617`, 25 tool calls, 0 incidents). Download it for comparison:
`uip solution packages download "vm-agent 8" 1.0.0 -d /tmp/pub100`, or the solution source with
`uip solution download 6c998cb3-078b-4c80-dfce-08df093139b4 -d /tmp/cloud8 --extract`.
That flow is smaller (13 nodes, no fixer, no ci-history) — useful as a diff target, not as a
replacement.

## Open items / cleanup owed

- ~~`smokeOnly` may not be wired~~ — fixed in `4e24810`; it was missing from
  `variables.globals`. Confirmed working (setup + ci-history stubbed, `classifyFailure` reached
  in ~4 min).
- `openPr` works end to end as of 1.0.24 (PR #3687). Note it **pushes to a shared repo**, so
  every verified fix from now on creates a real draft PR and a real remote branch. The branch
  name is `e2e-investigator/<runId>`, and `resumeRunId` reuses a runId - so re-running the
  same runId force-pushes over the previous branch rather than opening a second PR.
- The PR title is derived from `fixSummary` and truncated to a word boundary. #3687 was
  opened before that fix and reads `... (lines 84 an (automated investigator)`.
- **Editing `VmAgent.flow` regenerates the nested `agent.json` and the tool `resource.json`**,
  and silently reverts hand-made fixes in them (the rg-not-on-PATH hint and the fixer tool's
  `RunId` binding both came back). That is the "kept reverting" in `ea140a8`. Check
  `git diff` on those two files after every flow edit.
- `rg` is not on PATH in the agent's `vm_exec` sessions (setup only prepends
  `C:\vm-agent\bin` for its own session). The tool description now says so; better would be
  fixing the PATH or installing rg machine-wide.
- The `Shared/vm-agent 12` folder is recreated on every redeploy, which drops machine
  assignments and hand-made assets. The three placeholder credential assets
  (`GH_TOKEN`/`SLACK_TOKEN`/`SLACK_COOKIE`) and the VM machine template assignment from the
  abandoned single-folder experiment may or may not still be there; they are harmless.
- `vm-agent-priv` deployment in the personal workspace — dead end, uninstall it.
- Nine Studio Web solutions `vm-agent` … `vm-agent 9` exist; David declined bulk deletion.
- Two CLI bugs worth filing: `pack` not reproducing Studio Web's `bindings_v2.json` for
  inline-agent tool bindings (repro: published 1.0.0 zip vs local pack of the same source), and
  `deploy upgrade` wedging a deployment into `VersionChange / Draft` permanently.

## History

The blow-by-blow of this session (including several wrong turns worth not repeating — nine
deploy cycles spent "fixing" a configuration that was already correct) is in
`/tmp/HANDOFF-old.md` if it still exists, and in the git log from `d502723` onward.
