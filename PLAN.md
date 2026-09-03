# vm-agent-investigator — plan

Goal: prove a low-code Agent Builder agent can drive a Cloud Robot VM through
a generic "run this script" RPA process, and use it to investigate failing
flow-workbench e2e runs. Later, the same tool runs `claude -p` on the VM (#2).

Existing experiment `~/code/automated-e2e-investigator` (solution
`e2e-investigation`: `e2e-reproduce` process + `E2eInvestigation` flow +
Python diagnosis agent) is **not touched**. Everything below is a new git repo
and a new Studio Web solution.

## Layout

```
~/code/vm-agent-investigator/
  PLAN.md
  vm-agent/                       # new solution (uip solution init vm-agent)
    vm-agent.uipx
    vm-exec/                      # Process, XAML + Invoke Code (C#), Portable
    VmAgent/                      # Flow: manual trigger -> agent node -> end
    VmAgent/<uuid>/               # inline agent project (agent.json, resources/)
```

## Step 1 — `vm-exec` process (this step, ~45 min)

Copy `e2e-reproduce` as the starting point (same project.json runtime options,
`UiPath.System.Activities 25.10.5`, Portable, VB expressions, one
`ui:InvokeCode` C# block — the pattern Studio Web already accepts).

Arguments:

| dir | name            | type   | notes                                                    |
|-----|-----------------|--------|----------------------------------------------------------|
| in  | Script          | String | PowerShell text, run with `powershell -NoProfile -NonInteractive -Command -` via stdin (Windows) / `sh -c` elsewhere |
| in  | WorkDir         | String | optional; default `%TEMP%\vm-agent`. Persists across calls within a VM's life so clone/install happen once |
| in  | RunId           | String | bucket prefix, default `manual`                          |
| in  | TimeoutMinutes  | Int32  | default 30                                               |
| out | ExitCode        | Int32  | 124 = timeout, -1 = runner exception                     |
| out | Stdout          | String | merged stdout+stderr, **tail-truncated to 32 KB** (agent-tool arg limit) |
| out | OutputBlobPath  | String | full untruncated log in bucket `e2e-investigations`, `<RunId>/<utc-stamp>-exec.log` |

Behavior changes vs `e2e-reproduce`:
- No clone/test opinion in the process; the agent decides what to run.
- Secrets: same env-var inheritance (`GIT_TOKEN`, `GH_NPM_REGISTRY_TOKEN`,
  `PLAYWRIGHT_PASSWORD`); token values redacted from Stdout and log.
- WorkDir is *not* deleted at the end (deliberate: reuse between tool calls).
  ponytail: no cleanup, VM pool recycles; add TTL sweep if disk fills.
- Keep `UploadStorageFile` to bucket so Claude JSON / long logs never hit the
  argument size limit (keeps door open for #2).

Local proof: `uip rpa` validate/build in the solution dir; no local run
(needs Windows robot).

## Step 2 — pack + publish (~30 min)

- Pack with `.env`'s tenant/folder, using the net8 toolchain from memory:
  `/tmp/oldcli` (CLI 1.197) + `~/.dotnet8` — verify both still exist first.
- Publish to alpha `popoc/DefaultTenant`, same folder as `e2e-reproduce`, new
  process name `vm-exec`, bound to pool `e2e test investigation`.
- Smoke: start job with `Script = "git --version; node --version; corepack pnpm --version"`; expect ExitCode 0 and versions in Stdout.

## Step 3 — Flow with inline agent (~1h)

- `uip maestro flow init VmAgent` inside the solution; `uip agent init --inline-in-flow`
  scaffolds the agent project under `VmAgent/<uuid>/`.
- Nodes: manual trigger -> `uipath.agent.autonomous` -> end. Flow inputs
  `RepoUrl`, `Branch`, `TestCommand`, `RunId` pass into the agent; agent
  output `Report` -> flow `out`.
- Tool: `vm-exec` as `uipath.agent.resource.tool.process.<release-key>`
  resource node on the agent's `tool` port, hand-authored `resource.json`
  (`type: "process"`, `location: "solution"`), then
  `uip agent refresh --inline-in-flow --bindings-target VmAgent/bindings_v2.json`
  + `uip solution resources refresh`. Only `Script` is meaningful to the
  model; prompt fixes `RunId`/`TimeoutMinutes`.
- System prompt (`agent.json`): clone once into WorkDir and reuse, run specs
  with `--reporter=line`, max N tool calls, finish with hypothesis +
  evidence + OutputBlobPath list.
- `uip maestro flow validate`; then `flow debug` (asks first) with the
  known-failing `inline-agents/agent-prompts.spec.ts` case.

Agent Builder standalone agent dropped: inline agent gives same tool loop
with one fewer project. Switch to standalone only if inline agent hits a
tool-call or timeout cap that a published agent does not.

## Step 4 — measure (~15 min)

Record per run: tool calls, jobs dispatched, wall time, whether the
hypothesis matches the earlier manual triage.

## Step 5 — split the flow into deterministic stages (done 2026-09-02)

Flow is now: manual trigger → `setupVm` (RPA) → `runTest` (RPA) → `investigator`
(inline agent, `vm_exec` tool) → End. Both RPA nodes are the *same*
`vm-exec-vm` process with different `Script` inputs, so no new project.

- `setupVm` — idempotent: clone-or-fetch into `C:\vm-agent\repo`, inject
  `GIT_TOKEN` into the URL when present, `corepack enable pnpm`,
  `pnpm install --frozen-lockfile`, `playwright install chromium`.
  Re-running is cheap and a cold VM self-heals, so a reschedule to another
  pool VM costs time rather than correctness.
- `runTest` — runs the CI command in the existing clone, uploads the full log,
  returns `ExitCode` / `Stdout` tail / `OutputBlobPath`.
- `investigator` — receives those three plus the original inputs, so its first
  LLM call already has the failure. Prompt covers narrowing only; the tool-call
  cap is left at 6 deliberately (tune by iteration, not up front).

Why: in the 2026-09-02 16:16 run the agent spent 16 tool calls, most of them
re-deriving setup. Determinism moves that cost out of the LLM loop and makes a
setup failure fail loudly at its own node.

## Open risks

- Agent tool call timeout: Orchestrator process as tool may have its own
  cap; if < job time, agent needs a poll pattern. Check in step 3 before
  writing the prompt.
- Stdout 32 KB cap is a guess; confirm tool output limit in Agent Builder.
- Pool VM cold start ~3 min per job when no VM is warm.

## Path to #2 (not built now)

Same `vm-exec`; single call with
`Script = "claude -p '<task>' --output-format json > $env:TEMP\claude.json"`.
VM image needs machine-scope `claude` install + Bedrock/Vertex env vars +
`Restart-Service UiRobotSvc`. Raise TimeoutMinutes.

## Step 6 — decide whether a repro is needed (2026-09-03)

Prompted by Harry's "do we need to repro on the VM?" in the nightly-failure
thread. A repro is unreliable signal for a flaky test and redundant for a
deterministic one; CI history is cheaper than either.

Flow is now: setupVm → `ciHistory` (RPA, same `vm-exec-vm`) → `classifyFailure`
(script) → `decisionRepro` → [`runTest` → `decisionTest`] → `testEvidence` (script)
→ investigator.

- `ciHistory` — PowerShell generated by `ciHistoryInstructions`. With the VM's
  `GH_TOKEN` it lists the last 8 scheduled `playwright-ci.yml` runs on the
  branch, downloads the E2E job logs for the spec's `--project`, and reads the
  list-reporter marks (`✘`/`✓`/`-`) for the spec. Per run: failed / flaky
  (✘ then ✓ on retry) / passed / skipped / absent. Saves the newest failing
  job log to `C:\vm-agent\ctx\<runId>\ci-job.log` and the spec's failure
  section (≤6 KB) as the CI excerpt. Last stdout line is
  `[ci-history] {json}`.
- Classification: `consistent` (failed in every sampled run), `regression`
  (newest N failed, older passed; carries `firstFailSha`/`lastPassSha`),
  `flaky` (mixed or retry-recovered), `passing`, `absent`, `unknown` (no
  token / API error / no spec in the command).
- `decisionRepro` — repro only for `passing` / `absent` / `unknown`, i.e. when
  CI history cannot settle it. `regression`, `consistent` and `flaky` skip
  `runTest`; the CI excerpt becomes the test evidence.
- `testEvidence` — one shape for the agents: `source` (`vm` | `ci`),
  `exitCode`, `stdout`, `blobPath`, `ciHistory`. Investigator, fixer and
  summarizer bind to it instead of `runTest.output`; the investigator prompt
  tells the model which source it has (no local Playwright artifacts on `ci`)
  and to bisect `lastPass..firstFail` on a regression.
- Verified locally with a portable pwsh (`/tmp/pwsh`) against real GitHub
  data for `agent-prompts.spec.ts`: `regression`, failing since 9cd0d0f
  (2026-08-29), last pass eb1f3ae — matches Harry's fix PR #3615. ~40 s.
- Gotcha: `uip maestro flow validate` resolves script-node outputs from the
  manifest (`type: any`) and rejects dotted deep references, so the decision
  uses `$vars.classifyFailure.output['needsRepro']`.
- Not done: nightly workflow file name is hard-coded; `.agent-builder/`
  copies of the investigator/summarizer agent.json were already out of sync
  with the flow and only got the id renames.
- Smoke (2026-09-03, jobs 5a0ac883 / 49b2669d on `vm-exec-vm`): the `GH_TOKEN`
  credential asset holds an 11-char placeholder (GitHub 401 on everything);
  the VM's `GIT_TOKEN` env var (fine-grained PAT) returns 200 for user, repo,
  actions runs and job-log download. `ciHistory` now probes `/user` and takes
  the first accepted token. `SLACK_TOKEN` / `SLACK_COOKIE` credential assets
  were created with a single-space password (Orchestrator rejects empty) so
  vm-exec can start; vm-exec treats whitespace as unset.
