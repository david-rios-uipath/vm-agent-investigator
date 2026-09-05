# vm-agent — handoff

Last updated 2026-09-04 ~19:00 UTC. Written for an agent or human with no prior context.
Read this file, then `FINDINGS-uip.md` (CLI/platform traps — several will bite you), then
`DESIGN-phase-runner.md` (the restructure that is now implemented but unreleased).

## What this is

`~/code/vm-agent-investigator` builds a UiPath Maestro Flow (`VmAgent`) that investigates a
failing Playwright e2e test in `UiPath/flow-workbench`, on a Windows robot VM driven by one RPA
process (`vm-exec`, a PowerShell runner).

Up to and including 1.0.24 the reasoning lived in the cloud: three inline agents (investigator,
fixer, summarizer) drove the VM through ~34 `vm_exec` tool calls, each its own Orchestrator job.
That only worked because the robot pool has a single VM, so state left on disk survived between
jobs. `DESIGN-phase-runner.md` explains why that had to change.

**The tree now holds the phase-runner restructure (unreleased, unrun):** four coarse RPA jobs,
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
`claudeModel` — empty means the account default, set it to e.g.
`claude-haiku-4-5-20251001` to run the investigate and fix phases cheaply while testing.
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

## Current state (as released)

- **Deployment:** `Shared/vm-agent 11` @ **1.0.24**, package identity `vm-agent 8`.
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
   `Shared/vm-agent 11` and starts the job. **Never hand-run the pack step** — see FINDINGS.

4. **The old verify step**, for reference while the port is unproven:
   ```bash
   # parent + agent children
   uip or jobs list --folder-path "Shared/vm-agent 11" --output json
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
     python3 -c "import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(next(x['Key'] for x in d['Data'] if x['Path']=='Shared/vm-agent 11'))")
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
through `vm-exec-vm` this way.

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
- The `Shared/vm-agent 11` folder is recreated on every redeploy, which drops machine
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
