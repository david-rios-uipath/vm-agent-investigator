# Run log

Append-only, newest last. Nobody has to read this; it is here so a claim about what has run can
be checked. Current state is in `STATUS.md`.

## Known-good baseline (2026-09-03)

`vm-agent 8` 1.0.0, published by Studio Web from solution
`6c998cb3-078b-4c80-dfce-08df093139b4`, ran clean 04:59-06:21 UTC (instance `364f9617`, 25 tool
calls, 0 incidents). 13 nodes, no fixer, no ci-history. `reports/2026-09-03-run-364f9617.md` is a
critique of that run, worth reading for how the agent behaves.

## 1.0.23 — the loop first closed end to end (2026-09-04)

Instance `f282004c-f256-4100-97a2-80390ae1ba17`, 16:22-16:57 UTC, 35 minutes: trigger -> smoke
setup -> resume -> fixer -> verify `FIX_VERIFIED=true` -> openPr -> summarizer -> end. The verify
ran the real spec: `1 passed (3.4m)`. The fixer's patch retargets the two broken locators at
`debug-execution.spec.ts:84,87` to match the new aria-label directly:
`getByRole('button', { name: /^Copy path for \$vars\.\w+\.output\.name$/ })`.

**openPr published nothing**, and `GH_TOKEN` was not the reason. The commit succeeded — hash
`7495ff13d` is in the output — but the exit-code check read `$LASTEXITCODE` after
`| Select-Object -First 1`. See `TRAPS.md`.

## 1.0.24 — whole loop including the PR, 17 minutes (2026-09-04)

Instance `62b22f65-ae3f-4c80-89f2-d295eb59f104`, 17:16-17:33 UTC: smoke setup -> resume -> fixer
(11 min) -> studio-local verify `1 passed (1.9m)` -> draft PR
[flow-workbench#3687](https://github.com/UiPath/flow-workbench/pull/3687) (branch
`e2e-investigator/debug-execution-20260904-143456`, commit `ca8ff4928`, 1 file +2/-2) ->
summarizer -> end. The `GH_TOKEN` asset does have push scope on the repo.

Also in 1.0.24: verify against a local studio bundle (probed green at 17:10 UTC —
`### studio MFE serving on port 3000`, `1 passed (1.7m)`, `FIX_VERIFIED=true`, 4m23s total), the
PR title from `fixSummary` instead of a hardcoded `test(e2e): fix <spec>` that was wrong about
what the patch did, and `smokeOnly` + `resumeRunId` for fast iteration
(`inputs/debug-execution-fixer.json` drives that path).

## 1.0.29 — first full run from the trigger (2026-09-05)

Instance `f5893ef7-3655-4077-9021-fe5e0a49109e`, 03:52-04:27 UTC, 35 minutes, `Successful`:
`repro` (2 min, reproduced) -> `investigate` (6 min) -> `fixVerify` (17 min, attempt 1 not
verified) -> `bumpFixAttempts` -> `fixVerify` (8 min, `FIX_VERIFIED=true`) -> `openPr` ->
`investigationSummarizer` -> `end`. Classification `regression`, `reproduced=true`,
`fixVerified=true`, PR opened on the one-file spec fix. The retry loop is exercised too.

Four bugs stood between the first trigger run and this one, all invisible to `probe-phase.sh`:
the codepage-mangled status line, `deriveRunId` matching `playwright.config.ts`, the summarizer's
unsubstituted prompt placeholders, and the parse nodes advertising `output` as untyped `any`. All
four are in `TRAPS.md`.

`uip solution deploy run` also returned an HTTP 504 once, after `release.sh` had already
uninstalled the previous deployment.

## Second full run, and the reviewer-facing PR body (2026-09-05)

Instance from job `fe223250-a461-4e30-9729-4ecb8dae5944`, 13:00-13:28 UTC, 28 minutes,
`Successful`, on a spec it had never seen: `data-transform.spec.ts` "should add a Map operation
with field mappings", the neighbor-rail regression from that night's triage. Evidence source `ci`
(no local Playwright artifacts), classification `regression`, fix verified on attempt 1, draft PR
[flow-workbench#3729](https://github.com/UiPath/flow-workbench/pull/3729) on a two-file product
patch under `packages/canvas/`.

The description is now written for a reviewer, in `vm/lib/pr-body.ps1` (`New-PrBody`), checked by
`vm/tests/pr-body.tests.ps1`:

- one sentence of Problem, one of Solution, everything else behind `<details>` — failure output
  and CI window, then the fix with its file list and verification log, then the notebook verbatim.
- the fixer returns `problem` and `solution` one-liners plus `fixSummary` as bullets; the
  investigator writes a `Ruled out:` line per pass, since the notebook is published now.
- built line by line, not from a here-string: notebooks and logs contain `$` and backticks.

#3729 exposed three defects in that first body, all fixed in `c933ef1`: the spec name resolving to
`playwright.config`, codepage mojibake and raw ANSI escapes in the fenced logs, and a verification
sentence that claimed a pass without reading `verified`.

## 1.1.0 — first deployed NightlyOrchestrator run, blocked on the robot pool (2026-09-07)

Parent job `66304ff4-336f-467d-b346-925cdbce32e1`, instance `NightlyOrchestrator-56249860`,
started 17:54:49 UTC. It reached `investigate` and stayed there:

- `start -> selectTests -> investigate -> callVmAgent` all ran; the child `VmAgent` job
  `58bd94d1-dbef-46b0-8f76-c1ce6622be07` started 8 s after the parent. **The in-solution process
  binding resolves in a deployed folder** — that was the main unknown and it is settled.
- `Incidents: null` throughout. The orchestrator had no fault of its own.
- The child never left `repro`: its `vm-exec-vm` job `de5a3c2c-66b7-48d6-b2b6-0992c16c9b0e` sat
  `Pending` with no host. No robot in the `e2e test investigation` pool had sent a heartbeat since
  2026-09-06T21:05:12Z.
- Polled to 19:30 UTC (95 min): the three states never changed.

Two deploy details that are easy to get wrong:

- The orchestrator's `deploy-config.json` `packageName` is **`vm-agent.8.Flow.NightlyOrchestrator`**
  — capital `Flow`, and `8` not `7`. `pack` derives it from the solution package name (`vm-agent 8`)
  for projects that have no stored `spec.packageName`; the two older projects still carry the
  `vm-agent.7.…` names they were packed with. Read the name out of the zip rather than guessing:
  `unzip -l /tmp/vm-agent-pkg/*.zip | grep nupkg`.
- Its `resourceKey` is `dfa7e85b-4aa9-4549-a0f3-008bcf2dbc29`, from
  `vm-agent/resources/solution_folder/process/flow/NightlyOrchestrator.json` (`resource.key`) —
  `project.uiproj` does not carry one.

## vsix proven end to end, `vsix-pkg-3` (2026-09-08)

`e2e/specs/vsix/package-nested-solution.spec.ts:48` on `vsix-alpha-windows`, one phase at a time
through `probe-phase.sh`, no flow and no deployment:

- `repro` — reproduced from CI evidence. History after the two ci-history fixes:
  `09-08 failed (Linux failed, macOS flaky, Windows failed); 09-07 failed (Linux failed, macOS
  passed, Windows failed); 09-06 passed; 09-05 failed (Linux passed, macOS passed, Windows failed)`.
  Windows broke two nights before Linux did.
- `investigate` — four passes, 13 min, $4.51. Cause: `UiPath: Package` is contributed to the
  palette only under `when: "uipath.authenticated"` (`packages/vsix/package.json:531-534`), false
  until a background `uip` probe succeeds (`authService.ts:940, 954-984`); on nights carrying
  identity-429s the row never renders and the wait at `VsixWorkbenchPage.ts:140` times out. The
  429s come from `playwright-vsix.yml:126-133` signing one account in from three OS legs at once.
  It refuted its own Pass 3 claim in Pass 4 and left the Windows-only 09-05 night explicitly
  unexplained.
- `fix` — `fixVerified=true` in 11 min, $2.29: patch -> build (cache recovery fired) -> real VS
  Code run -> `1 passed (2.1m)`. `confidence: medium`, which is the honest reading: the established
  cause cannot occur on the VM.

## 1.1.12 — NightlyOrchestrator proven end to end (2026-09-08 04:15 UTC)

Deployed `vm-agent 8` 1.1.12 as `vm-agent 12` (folder `Shared/vm-agent 12`). On the 2026-09-07
nightly (`inputs/orchestrator-34089391590.json`, thread `1788766695.830989`): 6 failed tests -> 3
causes; 2 causes attributed to merged flow-workbench#3758 by the PR check; the third investigated
by VmAgent (reproduced, no verified fix, related PR #3758 named); one Slack reply, posted as David.

Runs that day: 1.1.1 (Slack `channel_not_found`), 1.1.2 (Slack OK, stale code republished), 1.1.3
(grouping OK), 1.1.4-1.1.11 (PR check via the GitHub connector: wrong `repo` param, loop typo, 153
PRs stall, variable-size cap), 1.1.12 (PR check on the VM, OK).

Deployment moved to `vm-agent 12` the same day: `vm-agent 11` is wedged with three Maestro jobs
stuck in `Terminating` after `jobs stop --strategy Kill`, so its uninstall fails validation. Leave
it. CI (`start-nightly-investigation.sh`) targets the new folder.

## Bugs fixed, with commits

| what | commit |
|---|---|
| agent tool 404: `pack` drops the bare `vm-exec-vm` binding from `bindings_v2.json` | `16fec0f` |
| `rg --version \| Select-Object -First 1` zeroed `$LASTEXITCODE`, aborting setup at 13 s | `b36ec3f` |
| tool `resource.json` files deleted → agents shipped with no tools | `12de81a` |
| summarizer null-deref on `verifyFix.output.Stdout`, two spellings | `baa6a52`, `9c55db7` |
| fixer's `confidence` required but written inline by the model | `89c8587` |
| fixer tool `RunId` bound to a nonexistent trigger input → logs in `manual/` | `ea140a8` |
| patch written as UTF-16 by PowerShell `>`, so `git apply` never applied it | `2d91e20` |
| `pack` nondeterministically drops the binding → retry loop in `release.sh` | `3685e89` |
| `testCommand` missing `--config e2e/playwright.config.ts` | `097b75e` |
| `smokeOnly` never declared in `variables.globals`, so the stubs never fired | `4e24810` |
| ci-history: `.mfe-cache` recovery for vsix builds | `b51192c` |
| verify ran `studio-alpha` (deployed bundle), so product fixes were unverifiable | (1.0.24) |
| `set VAR=v &&` in cmd.exe put a trailing space in `E2E_STUDIO_PORT` / `E2E_SKIP_WEBSERVER` | (1.0.24) |
| rsbuild's index.html fallback made `/remoteEntry.js` look ready mid-build | (1.0.24) |
| openPr read `$LASTEXITCODE` after `\| Select-Object -First 1`, so a good commit "failed" | (1.0.24) |
| PR body: spec name, mojibake, unverified pass claim | `c933ef1` |
| repro: a non-zero exit is not a reproduction unless a test ran | `55c49b3` |
| `fetchFailures`: enumerate `ConvertFrom-Json` the way 5.1 does | `9ff249b` |

Also added: `ciHistory` scans every sampled night's job log for environment signatures and keeps
per-night excerpts, so the agent gets the cross-night pattern as evidence instead of spending tool
calls on it (`6aa25de`).

## Before all this

The blow-by-blow of the first session (including several wrong turns worth not repeating — nine
deploy cycles spent "fixing" a configuration that was already correct) is in the git log from
`d502723` onward.
