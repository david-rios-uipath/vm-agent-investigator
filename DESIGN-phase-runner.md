# Design: phase-runner restructure of `VmAgent`

Written 2026-09-04 for an agent or human implementing this without prior context.
Read `HANDOFF.md` and `FINDINGS-uip.md` first; the traps there still apply.

## Problem

`VmAgent.flow` keeps the reasoning in the cloud (three inline agents: Investigator, Fixer,
Investigation Summarizer) and drives the VM through 34 `vm_exec` tool calls. Every tool call is
a separate Orchestrator job. The flow works today only because the robot pool has one VM, so
`C:\vm-agent\repo`, `C:\vm-agent\bin` and `C:\vm-agent\notes\<runId>` written by one job are
still there for the next. With two or more VMs in the pool, consecutive jobs land on different
machines and that state is gone. Orchestrator gives no cheap, reliable way to pin a chain of
jobs to one machine.

Secondary costs of the current shape: the 8 KB / 32 KB tool-output cap, the inline-agent tool
binding that `uip solution pack` drops (the reason `release.sh` exists), and 34 job dispatches
per run.

## Decision

Accept that consecutive jobs may run on different VMs. Make every job a complete, self-contained
unit of work:

- Each job starts by refreshing the checkout and pulling its state from the bucket by `runId`.
  It never assumes anything left on disk by a previous job.
- Each job ends by pushing its state back to the bucket and returning a small JSON status.
- The LLM reasoning moves onto the VM (`claude -p`). The flow becomes a thin orchestrator:
  roughly four coarse RPA jobs with decisions between them.

VMs are long-lived, so tool installs (rg, gh, node toolchain, Claude Code) are paid once per VM
and then skipped by idempotent "ensure" checks. The repo checkout is treated as a cache and
refreshed on every job, never wiped.

## Target flow

```
start (manual trigger: repoUrl, branch, testCommand, maxFixAttempts, smokeOnly, resumeRunId)
  -> deriveRunId                       (script, unchanged)
  -> repro          vm_exec phase=repro     -> status.reproduced, evidence in bucket
  -> decisionRepro  (not reproduced -> endNotReproduced)
  -> investigate    vm_exec phase=investigate -> notebook.md in bucket
  -> fixVerify      vm_exec phase=fix       -> status.fixVerified, fix.patch in bucket
  -> decisionVerify (verified -> openPr; else bumpFixAttempts -> fixVerify, up to maxFixAttempts)
  -> openPr         vm_exec phase=pr        -> status.prUrl
  -> summarizer     inline agent (unchanged; reads notebook + status from flow vars, no VM)
  -> end
```

`resumeRunId` set: skip `repro` and `investigate`, start at `fixVerify`. The state is already in
the bucket, so nothing else is needed. This replaces today's `decisionResume` / `readNotes` path.

Nodes removed: `investigator`, `fixer` (agent nodes), `vmExecTool`, `vmExecToolFixer` (agent
tool resources), `setupVm`, `runTest`, `ciHistory`, `readNotes`, `verifyFix` and their
`*Instructions` script nodes. `classifyFailure` / `testEvidence` logic moves into the `repro`
phase on the VM (it needs the CI job log, which the VM fetches with `gh`).

Nodes kept: `deriveRunId`, `investigationSummarizer`, all `decision*`, `bumpFixAttempts`,
the three `end*` nodes.

## The phase runner: `vm/run-phase.ps1`

Lives in this repo. One script, one `switch ($Phase)`. Every phase runs the same prologue and
epilogue.

```powershell
param(
  [Parameter(Mandatory)][ValidateSet('repro','investigate','fix','pr')] $Phase,
  [Parameter(Mandatory)] $RunId,
  [Parameter(Mandatory)] $RepoUrl,
  [Parameter(Mandatory)] $Branch,
  [Parameter(Mandatory)] $TestCommand,
  [switch] $SmokeOnly
)
```

Prologue (`vm/lib/prologue.ps1`, dot-sourced):

1. `Ensure-Tools`: `rg`, `gh`, `node`/`corepack`, `claude` present in `C:\vm-agent\bin` or PATH.
   Install only what is missing. Second run on the same VM must complete this in seconds.
2. `Refresh-Repo` at `C:\vm-agent\repo`: clone if absent, else
   `git fetch origin --prune; git checkout -B $Branch origin/$Branch; git reset --hard origin/$Branch;
   git clean -fdx -e node_modules`, then `corepack pnpm install --frozen-lockfile --prefer-offline`.
   Skip the install when the lockfile did not change between `HEAD@{1}` and `HEAD`.
3. `Pull-State`: download `e2e-investigations/<runId>/state/*` into `C:\vm-agent\notes\<runId>\`.
   Missing prefix is fine for `repro`.

Epilogue:

4. `Push-State`: upload `C:\vm-agent\notes\<runId>\*` to `e2e-investigations/<runId>/state/`.
5. Print exactly one line `STATUS_JSON=<single-line json>` as the last line of stdout. The flow
   parses that line and nothing else. Exit 0 even on a "negative" result (not reproduced, fix
   not verified); non-zero exit means the runner itself broke.

State layout in bucket `e2e-investigations` (existing bucket, key
`be6369c7-02a4-4b80-957b-e95d06177692`, folder `e2e-investigator`):

```
<runId>/state/evidence.json     repro: exitCode, source (vm|ci), excerpt, ciHistory summary
<runId>/state/test-output.log   repro: full test stdout
<runId>/state/notebook.md       investigate: hypothesis, evidence, files, rationale
<runId>/state/fix.patch         fix: UTF-8, LF, produced by `git diff`
<runId>/state/fix-summary.json  fix: fixSummary, confidence, attempts, verified
<runId>/state/pr.json           pr: prUrl, branch, commit
<runId>/<ts>-exec.log           vm_exec's own full log per job (already exists)
```

Bucket upload/download from PowerShell: use `UploadStorageFile` / `DownloadStorageFile` in the
XAML rather than REST from the script, so the robot's own identity is used and no extra token is
needed. That means `vm_exec` grows two optional arguments (see below); keep the script free of
Orchestrator API calls.

### Phases

`repro`: run `$TestCommand` (as today's `runTest`), then the CI-history lookup that
`ciHistoryInstructions` + `classifyFailure` do today, write `evidence.json`. Status:
`{ reproduced: bool, source: "vm"|"ci", exitCode }`. With `-SmokeOnly` skip the test and emit
`reproduced: true` with a canned excerpt.

`investigate`: `claude -p` with `vm/prompts/investigator.md`, cwd `C:\vm-agent\repo`, allowed
tools `Read,Grep,Glob,Bash(rg:*),Bash(git log:*),Bash(git show:*)`, `--output-format json`,
`--max-turns 40`. The prompt receives `evidence.json` inline and must write `notebook.md`.
Status: `{ investigationComplete: bool, hypothesis }`.

`fix`: `claude -p` with `vm/prompts/fixer.md`, allowed tools `Read,Edit,Write,Grep,Glob,Bash`,
cwd repo. The prompt receives `notebook.md` and the test command with `--project studio-alpha`
rewritten to `--project studio-local` (see `verifyFixInstructions` for why). Claude edits files
and runs the test itself; the inner patch/test loop lives here, not in the flow. After Claude
exits the script runs the test once more itself as the arbiter, writes `fix.patch` from
`git diff` (UTF-8, no BOM, LF; see the encoding trap in `verifyFixInstructions`), writes
`fix-summary.json`. Status: `{ patchWritten, fixVerified, fixSummary, confidence }`.

`pr`: apply `fix.patch` on a fresh branch `e2e-investigator/<runId>`, commit with `fixSummary`
as title, push, `gh pr create --draft`. Port `openPrInstructions` verbatim except for the
`$LASTEXITCODE` after `Select-Object -First 1` bug, which is already fixed in 1.0.24. Status:
`{ prUrl }`.

### Prompts

Extract the system prompts from the three `agent.json` files under `vm-agent/VmAgent/<uuid>/`
into `vm/prompts/investigator.md` and `vm/prompts/fixer.md`. Drop the tool-usage instructions
that talk about `vm_exec`; Claude now has real file tools. Keep the notebook format so the
summarizer's prompt needs no change. The summarizer's `agent.json` stays where it is.

## How the VM gets the runner

The flow passes `vm_exec` a fixed 10-line bootstrap `Script`, not the phase logic:

```powershell
$runner = 'C:\vm-agent\runner'
if (-not (Test-Path $runner)) { git clone --depth 1 <this repo url> $runner }
git -C $runner fetch --depth 1 origin <ref>; git -C $runner checkout -q FETCH_HEAD
& "$runner\vm\run-phase.ps1" -Phase <phase> -RunId <runId> -RepoUrl <..> -Branch <..> -TestCommand <..>
```

`<ref>` is a flow input defaulting to `main`, so a runner change is a git push, not a solution
release. The four `*Instructions` script nodes collapse into one `bootstrapScript` script node
parameterised by phase. `GIT_TOKEN` must have read access to this repo; verify before relying
on it.

## `vm_exec` process changes (`vm-agent/vm-exec/Main.xaml`)

1. Inject `ANTHROPIC_API_KEY` from a Credential asset of that name, same pattern as `GH_TOKEN`,
   and add it to the redaction list. Without it `claude -p` cannot authenticate on a robot
   account.
2. New optional in-arguments `StatePullPrefix` and `StatePushDir`. When set, download
   `<StatePullPrefix>*` into `C:\vm-agent\notes\<RunId>\` before the script and upload that
   directory back to the same prefix after it. Use `DownloadStorageFile` / `UploadStorageFile`
   with the existing bucket name.
3. Raise the default `TimeoutMinutes` to 45; `fix` runs ten minutes of Claude plus a
   multi-minute Playwright run.
4. Raise `MaxOutputChars` default to 32000. There is no agent tool limit any more; the flow
   only needs the `STATUS_JSON=` tail.

Repacking `vm-exec` goes through `release.sh` like everything else.

## Flow node contracts

Each phase RPA node maps inputs identically:

| input        | value                                                                    |
|--------------|--------------------------------------------------------------------------|
| Script       | `$vars.bootstrapScript.output` for that phase                             |
| RunId        | `$vars.deriveRunId.output`                                                |
| TimeoutMinutes | 15 repro, 20 investigate, 45 fix, 10 pr                                 |
| StatePullPrefix / StatePushDir | `<runId>/state/`                                         |

One script node `parseStatus` after each RPA node: find the last line starting with
`STATUS_JSON=`, `JSON.parse` the rest, return it. Decisions read `parseStatus*.output.<field>`.
If the line is absent, return `{ runnerFailed: true }` and route to `endSetupFailed` with the
exec log blob path in `evidence`.

## Migration order

Do these one at a time, each verified on the VM before the next. `./probe-verify.sh` already
shows how to call `vm-exec-vm` directly with an arbitrary script; use the same trick with the
bootstrap script to test a phase without packing or deploying the flow.

1. `vm/run-phase.ps1` with `Ensure-Tools`, `Refresh-Repo` and the `repro` phase only. Run it
   twice through `vm-exec-vm`; second run must show `[ensure] all tools present` and finish the
   prologue in under 60 s.
2. `vm_exec` changes 1 to 4. Release. Confirm `claude --version` works in a job and the key is
   redacted in the log.
3. `investigate` phase with the extracted prompt. Compare its `notebook.md` with a notebook in
   `reports/` from a cloud-agent run of the same failure.
4. `fix` phase. Reuse a `runId` whose notebook already exists (the `resumeRunId` idea).
   Success is `fixVerified: true` and a `fix.patch` that `git apply --check` accepts.
5. `pr` phase, ported from `openPrInstructions`.
6. Flow rewrite: remove the listed nodes, add the four RPA nodes, `bootstrapScript`,
   `parseStatus*`. Release, run end to end from a manual trigger, then run with `resumeRunId`.
7. Delete `probe-verify.sh`'s flow-rendering logic (it existed to keep the probe in sync with
   `verifyFixInstructions`, which no longer exists); the probe becomes "call `vm-exec-vm` with
   the bootstrap script for phase X".

## Verification checklist

- Two consecutive `repro` jobs on the same VM: second prologue under 60 s, no reinstall lines.
- `fix` job on a VM that has never seen `<runId>`: pulls `notebook.md` from the bucket and
  proceeds. Simulate by deleting `C:\vm-agent\notes\<runId>` before the job.
- Exec log contains `***ANTHROPIC_API_KEY***`, never the key.
- Full run from manual trigger ends at `end` with `prUrl` set; job count in `e2e-investigator`
  folder for that run is 4, not 30+.
- `release.sh` no longer needs the binding re-add step once the agent tool resources are gone.
  Remove it and the retry loop only after one clean pack proves it.

## Risks and open points

- **Claude Code on a Windows robot account.** Confirm `claude -p` runs non-interactively as the
  robot user with only `ANTHROPIC_API_KEY` set, and that its config dir is writable
  (`%USERPROFILE%\.claude`). See the LocalService notes in the memory / FINDINGS; the robot must
  run as a real user.
- **Losing Maestro agent traces.** Reasoning is no longer visible per tool call in Studio Web.
  Mitigation: `--output-format json` output and `--verbose` transcript go into
  `<runId>/state/claude-<phase>.jsonl` so a run is still debuggable from the bucket.
- **Concurrency on one VM.** Two flows on the same VM share `C:\vm-agent\repo`. Out of scope
  now; if needed, key the repo dir by `runId` and accept a clone per run.
- **Bucket round trip size.** `node_modules` is never in state; only text artefacts. Fine.
- **Runner repo access from the VM** depends on `GIT_TOKEN` scope. Check on day one.

## Out of scope

Elastic / ephemeral robots, VM image baking, pinning jobs to machines, parallel fix attempts.
