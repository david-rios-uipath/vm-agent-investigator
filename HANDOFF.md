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

## UPDATE 00:35 UTC — root cause found, fix deployed as 1.0.14

The A/B answered it. `1.0.13` (unmodified cloud source packed with `uip solution pack`) did
**not** 404, but the agent hung for 15 min with zero tool-call jobs and died with
`Serverless.Runtime.JobExecutionTimeout`. Either way the agent never reached the VM.

Diffing the Studio-Web-published `1.0.0` zip (`uip solution packages download "vm-agent 8" 1.0.0
-d /tmp/pub100`) against the locally packed `1.0.13` of the same source:

| artifact | published 1.0.0 | `uip solution pack` |
|---|---|---|
| flow nupkg `content/bindings_v2.json` | `e2e-investigator.vm-exec-vm` **and** bare `vm-exec-vm` | only `e2e-investigator.vm-exec-vm` |
| declaration `runtimeDependencies` | both keys, each with `resourceKey`/`resourceName`, `resourceType`, `isSolutionResource: true` | both keys, no `resourceType`/`isSolutionResource`; `resourceKey`/`resourceName` stripped when the flow's `bindings` array was hand-edited |
| everything else (tool `resource.json`, `agent.json`, `.flow` nodes) | identical | identical |

`pack` regenerates `bindings_v2.json` from the flow's top-level `bindings` array, which only
listed the qualified key, so the agent tool's bare binding was dropped from every locally
built package. The morning's working agent job carried two `ResourceOverwrites`
(`process.e2e-investigator.vm-exec-vm`, `process.vm-exec-vm`); every failing job carried only
the first. The agent runtime looks up its tool by the bare key.

**Fix (commit `16fec0f`):** added `resourceKey: "vm-exec-vm"` `name` + `folderPath` entries to
the flow's `bindings` array. Packed output now contains both `bindings_v2.json` entries
(verified before deploying). Deployed as `1.0.14` to `Shared/vm-agent 11`; smoke job
`67953871-b6fc-445e-afdc-89b7a9fb5ae5` started 00:32:03 UTC with `/tmp/job-input-smoke.json`.

**CONFIRMED 00:34 UTC.** Agent child `71ab58fb` started 00:34:12, went `Suspended` (the normal
serverless suspend while a tool job runs), and a new `vm-exec-vm` job was created in
`e2e-investigator` at 00:34:22 and completed `Successful` at 00:34:34 — the agent's first
tool call reached the Windows VM. Nine failed deploy cycles were all this one dropped binding.

The declaration differences (`resourceType`, `isSolutionResource`, `resourceKey` stripping)
turned out not to matter for resolution. Still worth a CLI bug report: `uip solution pack`
does not reproduce Studio Web's `bindings_v2.json` for inline-agent tool bindings; repro is
the published `1.0.0` zip vs a local pack of `/tmp/cloud8/…` (or of this repo at `dec75c0`).

## UPDATE 12:58 UTC — 1.0.20 ran clean through the fixer; summarizer fault was a second spelling

Run `3bc47073` (1.0.20): investigator 2 passes / **21 successful `vm_exec` calls**, verdict
`investigationComplete: true` (same conclusion — shared-alpha environment flake: identity 429s,
cleanup 400s, slow editor mounts; `git log 6e672a6..c7369f5 -- e2e/pages e2e/fixtures
e2e/specs/debug` is empty). Fixer ran and passed validation this time (optional `confidence`
works). Then `investigationSummarizer` faulted **again** with `400300 … =js:vars.verifyFix.output.Stdout`.
The earlier null-safety patch only matched the `$vars.…` jsExpression spelling; the summarizer's
agent input bindings use the `=js:vars.…` string form. Fixed in `9c55db7` (both spellings,
regex `(\$?vars)\.(verifyFix|openPr)\.output\.Stdout`; 0 unguarded refs remain). Notebook:
`reports/2026-09-04-run-3bc47073-notes.md`.

`release.sh 1.0.21` re-added the bare bindings (so something before it — `validate` this
time — had stripped them again; it *is* nondeterministic), passed both asserts, published and
deployed. The script was cut off by a tool timeout before `jobs start`; job started by hand:
`6d77027a-5f6a-4c8a-8f87-4a891710ef8d` at 12:56:40 UTC with `inputs/debug-execution.json`.
If this one completes, it is the first end-to-end deployed run producing the summarizer report.

## UPDATE 01:55 UTC — 1.0.17–1.0.19 shipped agents with NO tools; 1.0.20 in flight

Runs 1.0.18 (`378e5f5f`) and 1.0.19 (`23264d3b`) failed a new way: the investigator returned
placeholder output in 27 s with zero tool calls, then its retry faulted
`AGENT_RUNTIME.ROUTING_ERROR — The agent attempted to route to 'vm_exec', which is not a
registered tool`. The packaged investigator `agent.json` had `resources: []`. Cause: commit
`89c8587` **deleted both tool `resource.json` files** (`VmAgent/<agent>/resources/<id>/resource.json`,
81 lines each). Something in that edit→validate→commit sequence removed them; tested afterwards,
neither `uip maestro flow validate` nor `uip solution resources refresh` deletes them in
isolation, so the culprit is still unidentified. Restored from `e1ceece` in `12de81a`.

`release.sh` now asserts **both** that the packaged `bindings_v2.json` contains `vm-exec-vm` and
that the packaged investigator `agent.json` lists the `vm_exec` tool. The first 1.0.20 attempt
was refused by the binding assert even though the source was correct; two probe packs of the
same tree (HEAD and `e1ceece`) immediately after were both correct, so `pack` output is not
fully deterministic — the assert is load-bearing, never bypass it.

1.0.20 published and deployed to `Shared/vm-agent 11`; full run
`3bc47073-c356-4ba3-9649-f82cb6aa8ea8` started 01:53:22 UTC. Same expected path as before;
this is the first build since 1.0.16 that has the tool binding, the tool, the null-safe
summarizer and the optional fixer `confidence` all together.

## UPDATE 01:50 UTC — full run d99c4204 result, fixer fix, use `release.sh` from now on

Full run `d99c4204` (1.0.16) worked end to end for the investigator: **3 passes, 34 `vm_exec`
calls, all successful**, verdict confirmed and strengthened with the new per-night env signals —
`debug-execution.spec.ts:17` fails from identity-service 429 rate limiting of the single shared
alpha studio account used by all 5 parallel shards (`playwright-action.yml:183-185`), not a code
regression; `cleanup400` is shard-wide teardown noise. Notebook:
`reports/2026-09-04-run-d99c4204-notes.md`. It then faulted in the **fixer**:
`AGENT_RUNTIME.OUTPUT_VALIDATION_ERROR — confidence: Field required` (the model wrote
`confidence` inline instead of as a field). Fixed by making `confidence` optional in the fixer's
`agent.json` and `entry-points.json` (`89c8587`). Also told the agent in the tool description
that `rg` lives in `C:\vm-agent\bin` and is not on PATH.

1.0.17 shipped **without the agent tool binding again** (caught by the assert, but the shell
chain did not stop — fixed). 1.0.18 verified good and deployed; full run
`378e5f5f-3183-4566-987e-b0657832d370` started 01:45:15 UTC.

**Use `./release.sh <version> [input.json]` for every release from now on.** It re-adds the
binding, packs, discards pack's source rewrites, asserts on the packaged `bindings_v2.json`,
publishes, stops jobs, uninstalls/redeploys `vm-agent 11`, and starts a job. Inputs are checked
in under `inputs/`.

## UPDATE 01:15 UTC — smoke result, two more fixes, full run in flight (1.0.16)

Smoke run `67953871` (1.0.14): investigator made 16 successful `vm_exec` calls and reached a
verdict — infra flakiness (identity-service 429s on the shared studio-alpha account), not a code
regression; notebook saved at `reports/2026-09-04-run-67953871-notes.md`. The flow then faulted
in `investigationSummarizer`: `400300 … =js:vars.verifyFix.output.Stdout — Cannot read property
'Stdout' of null` (verifyFix never ran because no fix was written).

Shipped in **1.0.16** (commits `baa6a52`, `6aa25de`, `e1ceece`):
- null-safe `$vars.verifyFix/openPr.output.Stdout` in summarizer, fixer, decisionVerify, decisionPr
- `ciHistory` now scans every sampled night's job log for environment signals (identity 429,
  cleanup 400, editor-load failure, network) and keeps an 800-char failure excerpt per failing
  night; `classifyFailure` passes the `runs` table through; `testEvidence.ciHistory` folds the
  other nights in so the agent gets the cross-check without extra tool calls
- the bare `vm-exec-vm` binding re-added — see the trap below

**Trap that bit twice:** `uip solution pack` rewrites `VmAgent.flow` in the source tree and
strips the bare `vm-exec-vm` bindings (also touches `agent.json` files and the flow
declaration). 1.0.15 shipped broken because a later commit captured the stripped flow. The pack
step must be: pack → `git status` → `git checkout -- vm-agent/` → assert `vm-exec-vm` in the
nupkg's `content/bindings_v2.json` → publish.

**Full run in flight:** job `d99c4204-4f63-4847-ac27-15f9a958f130`, `Shared/vm-agent 11` @1.0.16,
started 01:12:11 UTC with `/tmp/job-input.json` (no smoke flag). Expect setup ~1.5 min,
ci-history ~1 min (longer now: it downloads every failing night's log), then — since history
should classify `flaky` — no `runTest`, investigator, fixer, summarizer. Read `OutputArguments`
on the parent when it finishes; if it faults, `uip maestro flow instance incidents <jobKey> -f
<folderKey>` (folder key changes on every redeploy: `uip or folders list --all --name "vm-agent 11"`).

Open items:
- `smokeOnly: true` did **not** take effect in the 1.0.14 smoke run (setup ran the real clone,
  82 s; ci-history real, 30 s). `$vars.start.output.smokeOnly` is probably not populated from
  the job input; unverified.
- `rg` is not on PATH in the agent's `vm_exec` sessions (setup only prepends `C:\vm-agent\bin`
  for its own session; the agent fell back to `Select-String`). Fix in the tool description or
  have setup install rg somewhere already on the robot's PATH.
- Cleanup: single-folder leftovers in `Shared/vm-agent 11` (machine template `685f30b9`,
  placeholder assets — recreated folder may have dropped them already), `vm-agent-priv` in the
  personal workspace.

The section below is the plan as written before this result; the deploy loop and cleanup notes
still apply. Cleanup progress: `Shared/vm-agent 8` finally uninstalled — it had two `Running`
flow jobs from 04:35/04:41 UTC on 09-03 blocking it (`jobs stop` both, then uninstall
succeeded).

## The experiment in flight (superseded — kept for context)

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
