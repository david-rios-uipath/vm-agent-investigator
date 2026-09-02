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
