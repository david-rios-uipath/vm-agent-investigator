# vm-agent — handoff

Last updated 2026-09-04 ~17:40 UTC. Written for an agent or human with no prior context.
Read this file, then `FINDINGS-uip.md` (CLI/platform traps — several will bite you).

## What this is

`~/code/vm-agent-investigator` builds a UiPath Maestro Flow (`VmAgent`) that investigates a
failing Playwright e2e test in `UiPath/flow-workbench`. Three inline agents — investigator,
fixer, summarizer — drive a Windows robot VM through one RPA tool (`vm_exec`, a PowerShell
runner). See `PLAN.md` for the original design and run economics.

**Goal:** a deployed (not Studio-Web-debug) run that goes start → investigate → fix → verify →
summarize without human intervention.

## Current state

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

It calls `e2e-investigator/vm-exec-vm` directly with the PowerShell that
`verifyFixInstructions` generates - **rendered from `VmAgent.flow` with node, not a copy**, so
the probe cannot drift from what the flow runs - against a `fix.patch` a previous fixer already
wrote on the VM. Prints the patch's first bytes, the `git apply` result, the studio dev server
port and the test tail. ~10 minutes now that it boots the studio bundle; no pack/publish/deploy,
no agents, no LLM cost. Find a runId with:

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
