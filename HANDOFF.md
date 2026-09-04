# Handoff — why does the agent's `vm_exec` tool 404 in locally packed deployments?

Written 2026-09-04 ~00:10 UTC for an agent with fresh context. Read this whole file before running anything.

## Goal

Get a deployed `VmAgent` flow (not a Studio Web debug run) to complete an investigation of
`e2e/specs/debug/debug-execution.spec.ts` in `UiPath/flow-workbench`, with the inline agent
successfully calling its `vm_exec` tool. Everything else — cleanup, private folders, faster
loops — is secondary.

## What is known to work

A deployed run **did** succeed this morning:

- Folder `Shared/vm-agent 8`, package `vm-agent.7.flow.VmAgent:1.0.0`, instance `364f9617`.
- 04:59–06:21 UTC, 0 incidents, investigator made **25 `vm_exec` tool calls**, correct root cause.
- Report: `reports/2026-09-03-run-364f9617.md`.
- That package was published by **Studio Web** from solution `vm-agent 8` (SolutionId
  `6c998cb3-078b-4c80-dfce-08df093139b4`) and deployed with `deploy.sh` + `deploy-config.json`.
- Its wiring is cross-folder: flow runs in `Shared/vm-agent 8`, `vm-exec-vm` lives in
  `e2e-investigator` (the only folder with the Windows VM pool). Tool resource has
  `location: "solution"`, `referenceKey: ca36341d-…`, `properties.folderPath: e2e-investigator`,
  `processName: vm-exec-vm`. Flow `bindings` keyed `e2e-investigator.vm-exec-vm`.
- A pristine copy of that solution is downloaded at
  `/tmp/cloud8/6c998cb3-078b-4c80-dfce-08df093139b4/` (re-download with
  `uip solution download 6c998cb3-078b-4c80-dfce-08df093139b4 -d /tmp/cloud8 --extract` if gone).

## What fails

Every package built from this repo with `uip solution pack` (versions 1.0.2 through 1.0.12)
fails identically: the flow's RPA nodes call `e2e-investigator/vm-exec-vm` successfully, then
the investigator agent's first tool call faults:

```
AGENT_RUNTIME.HTTP_ERROR — Failed to execute tool 'vm_exec'
404 Could not start process for tool 'vm_exec': an item required to start the job was not
found. Server message: The job's associated process could not be found
```

Things that were tried and did **not** fix it (all reverted in commit `dec75c0`):
`location: "external"`, adding `folderKey` to the tool binding, adding an `id` to the tool
binding, re-importing `vm-exec-vm` as a remote resource, and moving to a single folder
(which fixes resolution but the process then runs on serverless Linux, not the VM).

Verified equal between the working 1.0.0 source and the failing 1.0.2 package: tool
`resource.json`, flow `bindings`, `bindings_v2.json`, and the flow declaration's
`runtimeDependencies` (`resourceKey`/`resourceName`/`folderKey` all present).

## The experiment in flight

`1.0.13` = the **unmodified** cloud solution packed locally
(`cd /tmp/cloud8/6c99…/ && uip solution pack . /tmp/cloudpkg -n "vm-agent 8" -v 1.0.13`),
published to the tenant feed, deployed to `Shared/vm-agent 11`, job `bc434d4a-789d-4685-b3f4-6aa4182300d8`
started 00:07:38 UTC with `/tmp/job-input.json` (full run, no smoke flag — expect ~12 min before
the agent's first tool call).

### Step 1 — read the A/B result

```bash
cd ~/code/vm-agent-investigator
uip or jobs list --folder-path "Shared/vm-agent 11" --output json   # parent + child jobs
uip or jobs get <child-job-key> --output json                       # Info / ErrorCode on a Faulted child
uip or jobs list --folder-path "e2e-investigator" --output json      # vm-exec-vm jobs = tool calls landing
```

Signal: after `setupVm` (~2 min) and `runTest` (~10 min), do new `vm-exec-vm` jobs keep
appearing in `e2e-investigator` **while the agent child job stays Running**? That is the agent
calling its tool.

### Step 2 — branch on the result

**1.0.13 works** → `uip solution pack` is fine; the breakage is in content added since the
cloud copy. Bisect on the local flow, keeping `smokeOnly: true` in the job input for ~2-min
cycles. Order of suspicion:

1. Remove the Fixer agent (`vm-agent/VmAgent/86439ed0-…/`, nodes `fixer`, `vmExecToolFixer`,
   `decisionFix`, `verifyFix*`, `bumpFixAttempts`, `decisionPr`, `openPr*`) — the working
   flow has one agent tool node; the local flow has two pointing at the same process.
2. Remove the CI-history gate (`ciHistory*`, `classifyFailure`, `decisionRepro`, `testEvidence`).
3. `vm-agent/vm-exec/Main.xaml` / `project.json` changes (local project lacks the
   `MaxOutputChars` argument that the deployed 1.0.3 process has).

**1.0.13 fails** → `uip solution pack` does not reproduce what Studio Web publishes. That is a
CLI bug. File it with: the two solution zips, the 404 text above, the job's
`ResourceOverwrites` (only `process.e2e-investigator.vm-exec-vm` is present), and the fact
that RPA nodes resolve while the agent tool does not. Workaround meanwhile: iterate in Studio
Web and publish from there, or `uip solution upload --force` to `vm-agent 9`
(SolutionId `ed157df9…`, which is what the local `.uipx` maps to) and publish from the UI.

## Repo state

- `HEAD` = `dec75c0`: working cross-folder wiring restored + Fixer registered in
  `entry-points.json` + tonight's keepers (`rg` guard fix `b36ec3f`, CI-history gate
  `d502723`, `smokeOnly` flag from `1131f28`).
- One uncommitted change: `vm-agent/resources/solution_folder/process/flow/VmAgent.json` lost
  `resourceKey`/`resourceName`/`folderKey` on both bindings. `uip solution pack` rewrote it
  during the 1.0.12 pack. **Discard it** (`git checkout -- <file>`) — the committed version
  matches the working cloud copy.
- Job inputs: `/tmp/job-input.json` (full) and `/tmp/job-input-smoke.json` (`smokeOnly: true`,
  `maxIterations: 2`). Recreate from the `repoUrl`/`branch`/`testCommand` fields in
  `PLAN.md` if `/tmp` was cleared. Consider checking them into `inputs/`.

## Deploy/iterate loop that works (same folder every time)

```bash
cd ~/code/vm-agent-investigator
uip solution pack vm-agent /tmp/vm-agent-pkg -n "vm-agent 8" -v 1.0.<N> --repository-commit $(git rev-parse HEAD)
uip solution publish "/tmp/vm-agent-pkg/vm-agent 8_1.0.<N>.zip"
# stop any Running job in the folder first, or uninstall fails with "Validation failed."
uip or jobs stop <job-key>
uip solution deploy uninstall "vm-agent 11" --yes
uip solution deploy run -n "vm-agent 11" --package-name "vm-agent 8" --package-version 1.0.<N> \
  --folder-name "vm-agent 11" --parent-folder-path "Shared" --config-file deploy-config.json --timeout 600
uip or processes list --folder-path "Shared/vm-agent 11" --output json   # get the VmAgent process key
uip or jobs start <VmAgent-key> --folder-path "Shared/vm-agent 11" --input-arguments "$(cat /tmp/job-input-smoke.json)"
```

Do **not** use `deploy upgrade` (wedges into `VersionChange / Draft`) or
`processes update-version` (404: inner nupkg not in the process feed).

## Cleanup still owed

- `Shared/vm-agent 8` deployment `1f230647` — `Uninstall` fails with `Validation failed.`
  even with no running job. Not resolved. Stale 1.0.0 processes still there.
- `Shared/vm-agent 11` has leftovers from the single-folder experiment: the VM machine template
  `685f30b9` assigned, and placeholder credential assets `GH_TOKEN`/`SLACK_TOKEN`/`SLACK_COOKIE`.
  Harmless for cross-folder runs; remove when settled.
- Personal-workspace deployment `vm-agent-priv` (1.0.3) — dead end, uninstall it.
- 9 Studio Web solutions `vm-agent` … `vm-agent 9` — David declined bulk deletion; leave.

See `FINDINGS-uip.md` for every CLI/Studio Web behavior learned tonight.
