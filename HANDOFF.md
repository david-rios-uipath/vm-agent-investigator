# vm-agent — handoff

Last updated 2026-09-04 ~16:00 UTC. Written for an agent or human with no prior context.
Read this file, then `FINDINGS-uip.md` (CLI/platform traps — several will bite you).

## What this is

`~/code/vm-agent-investigator` builds a UiPath Maestro Flow (`VmAgent`) that investigates a
failing Playwright e2e test in `UiPath/flow-workbench`. Three inline agents — investigator,
fixer, summarizer — drive a Windows robot VM through one RPA tool (`vm_exec`, a PowerShell
runner). See `PLAN.md` for the original design and run economics.

**Goal:** a deployed (not Studio-Web-debug) run that goes start → investigate → fix → verify →
summarize without human intervention.

## Current state

- **Deployment:** `Shared/vm-agent 11` @ **1.0.22**, package identity `vm-agent 8`.
- **Working:** trigger → setup → ci-history → classify → investigator (with real `vm_exec`
  tool calls on the VM) → fixer → patch → **verify applies the patch and runs the real test**.
- **Verify mechanism validated 16:00 UTC** with `./probe-verify.sh` (see below): patch
  normalised (`64 69 66 66` = clean UTF-8), `git apply` clean, and the real Playwright test ran
  for 4m43s with the corrected `--config`. So the loop's plumbing is done.
- **Not yet proven end to end:** a verify that returns `FIX_VERIFIED=true`, and therefore the
  summarizer producing the final report. The blocker is now *fix content*, not plumbing — see
  "The fix the agent proposes cannot pass" below.
- **Live run when this was written:** `5d99ea9b-9954-4cca-a982-5a59365bce1f` (started 14:34:51
  UTC on 1.0.22). It reached fix attempt 1 verify at 15:20 — patch normalisation worked, test
  ran, then failed on a bad `--project` (see next section). It was left running; it will burn
  through 3 fix attempts and stop.

## Do this next

1. **Release 1.0.23 with the fixed test command** (already committed, `097b75e`): the
   `testCommand` in `inputs/*.json` was missing `--config e2e/playwright.config.ts`, so
   verify's Playwright run died with `Project(s) "studio-alpha" not found. Available projects: ""`.

   ```bash
   cd ~/code/vm-agent-investigator
   ./release.sh 1.0.23 inputs/debug-execution.json
   ```
   Before spending a full run, consider `./probe-verify.sh <runId>` (see below) — it validates
   the verify step in ~5 minutes.
   `release.sh` does everything: re-add the fragile binding, pack (with retry), assert the
   package is good, publish, stop running jobs, uninstall+redeploy the same folder, start the
   job. **Never hand-run the pack step** — see FINDINGS.

2. **Watch the verify step**, which is the current frontier:
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

## Fast validation: `./probe-verify.sh`

Do **not** wait 30-60 minutes for a full flow run to test a change to the fix/verify step:

```bash
./probe-verify.sh debug-execution-20260904-143456          # runId folder on the VM
./probe-verify.sh <runId> "<alternate test command>"
```

It calls `e2e-investigator/vm-exec-vm` directly with the same PowerShell that
`verifyFixInstructions` generates, against a `fix.patch` a previous fixer already wrote on the
VM, and prints the patch's first bytes, the `git apply` result and the test tail. ~5 minutes,
no pack/publish/deploy, no agents, no LLM cost. Find a runId with:

```bash
uip or bucket-files list be6369c7-02a4-4b80-957b-e95d06177692 --folder-path "e2e-investigator" --output json
# or read $patch out of any past verify job's Stdout
```

Same trick generalises: any single flow step whose script you want to test can be run straight
through `vm-exec-vm` this way.

## The fix the agent proposes cannot pass

Probe result 2026-09-04 16:00 UTC, patch applied and test run properly:

```
1) debug-execution.spec.ts:17 › start a debug session and wait for completion
   Error: expect(getByText('Successful')).toBeVisible() failed   ← line 46, 60s timeout
```

The patch retargets the locators at **lines 84/87**; the test dies at **line 46**, the
debug-run-completion badge. The apollo-react `aria-label` finding is real but downstream — the
test never reaches those lines. So no locator fix can ever return `FIX_VERIFIED=true` while the
debug run itself fails to reach "Successful".

What that means for the next iteration:
- With the old broken verify, the fixer only ever saw `git apply --check failed`, so it kept
  re-emitting the same patch. It now receives the **real test output** in
  `verifyFix__output__Stdout`, so it has a chance to notice the failing line is not the one it
  patched. Worth watching whether it self-corrects, and worth a prompt line telling it
  explicitly: *if verify fails at a different line than your patch targets, your patch is
  irrelevant to the primary failure — go back to investigating.*
- The primary failure (badge never appears) is the identity-429/shared-account story, or a
  genuine product bug in the debug run. Neither is fixable by editing the spec, so the honest
  outcome for this test may be "no fix, report the cause" — which the flow supports
  (`patchWritten: false`).

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

- `smokeOnly` may not be wired to the trigger input correctly — the one smoke run still did a
  real clone and ci-history. Verify before relying on it for fast loops.
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
