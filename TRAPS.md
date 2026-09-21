# Traps

Things that were silently wrong and cost a run to find. Append-only; nothing here goes stale.
UiPath CLI / Orchestrator / Studio Web traps live in `FINDINGS-uip.md`.

## PowerShell and Windows

- **`$LASTEXITCODE` after a pipeline that closes early is meaningless.**
  `rg --version | Select-Object -First 1` zeroed it and aborted setup at 13 s (`b36ec3f`); the
  identical trap in `openPr` made a *successful* commit report failure, so `Reset-Tree` deleted
  the branch and `gh pr create` never ran (fixed in 1.0.24). Capture the exit code before any
  pipeline.
- **PowerShell `>` writes UTF-16.** The fixer's patch was written that way, so `git apply` never
  applied it (`2d91e20`). Use `Write-Utf8Lf`.
- **`cmd.exe /c "set VAR=value && ..."` puts the trailing space in the value.**
  `E2E_STUDIO_PORT` became `"3000 "`, Playwright fetched `http://localhost:3000 /remoteEntry.js`
  and threw; `E2E_SKIP_WEBSERVER` became `"1 "` and never matched `!== '1'`. Quote the whole
  assignment — `set ""VAR=value""` (doubled, because the string is already inside a double-quoted
  PowerShell string; a backtick escape would collide with the JS template literal that generates
  it).
- **Robot stdout returns through a legacy codepage.** The VM printed valid `STATUS_JSON=`, but an
  em-dash in the notebook arrived as bytes ending in a literal `"`; `JSON.parse` died at column
  440 and `parseStatusInvestigate` reported `runnerFailed` after a perfect 7-minute
  investigation. `Write-Status` escapes every non-ASCII char to `\uXXXX`; two selfcheck asserts
  cover it. The same mojibake, plus raw ANSI escapes, showed up in the first PR body's fenced
  logs.
- **Jobs run as `NT AUTHORITY\LOCAL SERVICE` in session 0.** No window ever appears
  (`MainWindowHandle` stays 0) and `Graphics.CopyFromScreen` throws "The handle is invalid".
  Anything that needs a desktop must instead go through CDP.
- **`ConvertFrom-Json` in PowerShell 5.1 does not enumerate like 7 does** (`9ff249b`).

## State and the single-VM pool

- **State pushes fail silently if any file in the state directory is locked.** The studio dev
  server holds `studio-dev.log` open past the end of the fix phase, so `Compress-Archive` threw
  `IOException` for the whole set and, with `-ErrorAction SilentlyContinue`, several fix runs
  pushed nothing at all while still reporting success. The `pr` phase only worked because the
  single-VM pool still had the files on local disk — exactly the assumption the restructure exists
  to remove. Fixed: the dev log lives outside the state dir, the archive is staged through a copy
  that skips unreadable files, and a failure is printed rather than swallowed.
- **A poisoned cache outlives the job that made it.** `Build-Vsix` clears
  `packages/vsix/.mfe-cache` and retries once: `fetch-mfe-assets.mjs` stages through renames, and
  one EPERM leaves that cache in a state every later build trips over — the next build fails at
  `rebuildCache`'s rename, the one after at `stageDestination`'s, so it reads as permanent. Two
  builds failed that way and a third succeeded with nothing changed but the cache removed.

## Test-history parsing

- **Windows runners print ASCII marks.** Playwright's list reporter emits `ok`/`x` where the
  terminal cannot do Unicode. The mark regex took only the checkmark and ballot-X, so **every
  Windows job had always parsed as "the spec never ran there"** — invisible while the only jobs
  read were the Linux studio shards.
- **The job filter missed vsix jobs entirely.** Studio shards are `E2E (studio-alpha) [2/5]`, but
  a vsix job carries its platform inside the same parens: `E2E (vsix-alpha, Linux)`. Matching only
  `($project)` found nothing, so every vsix spec classified as `absent` and the investigator got
  no history at all.
- **`deriveRunId` matched the first `.ts` in the test command**, which is `playwright.config.ts`,
  so runs were named `playwright.config-<stamp>`. It prefers a `.spec.ts` match now — and the same
  trap bit `New-PrBody`'s spec name a second time.
- **A non-zero exit is not a reproduction unless a test actually ran** (`55c49b3`).

## Verify

- **rsbuild answers `/remoteEntry.js` with the SPA index.html fallback while still building.** A
  bare 200 is not readiness — the probe also requires the body not to start with `<`, otherwise the
  test starts mid-build against a remote that is not there yet.
- **`studio-alpha` loads alpha's deployed bundle**, so a patch to product source applies cleanly,
  runs, and changes nothing. Verify rewrites the project to `studio-local`. The earlier conclusion
  that "no locator fix can ever return `FIX_VERIFIED=true` because the test dies at line 46" was
  **wrong**: line 46 is the identity-429 flake, not a hard blocker.
- **A verify finishing in under 20 s never ran the test.**

## Flows and agents

- **The agent package, not the flow node, is what runs.** The summarizer's prompt mixed
  `{{input.NAME}}` (substituted) with `{{ (($agent.X || {}).y) }}` expressions (not substituted),
  so every field sourced from a phase status reached the model as literal braces and it terminated
  with `AGENT_RUNTIME.TERMINATION_LLM_RAISED_ERROR`, "investigation inputs are unresolved template
  placeholders" — twice, each time after a verified fix and an opened PR. Every placeholder is a
  plain `{{input.a__b__c}}` now, mirroring the flow node's `{{ $vars.a.b.c }}`, with null guards
  in the bindings.
- **Editing `VmAgent.flow` regenerates the nested `agent.json` and the tool `resource.json`**, and
  silently reverts hand-made fixes in them (the rg-not-on-PATH hint and the fixer tool's `RunId`
  binding both came back — that is the "kept reverting" in `ea140a8`). Check `git diff` on those
  files after every flow edit, and patch `<agentId>/agent.json` plus `.agent-builder/agent.json`
  alongside the flow.
- **Script nodes advertise `output` as untyped `any`**, so the designer showed `output 0 keys` and
  every `$vars.parseStatusX.output.field` was an unresolvable red pill (RPA nodes' own fields
  resolve because they carry a schema). Each `parseStatus*` node declares the union of its success
  payload and its `runnerFailed` fallback.
- **Keep flow variables small.** The Integration Service GitHub connector returns ~20 KB per PR
  and Maestro faulted with "The instance's variables exceed the maximum allowed size" even at 10
  PRs; 153 PRs with patches also stalled a parallel loop for 10+ minutes. That check moved onto
  the VM.
- **A trigger input that does not exist in `variables.globals` silently never fires.** `smokeOnly`
  was declared nowhere, so its stubs did nothing (`4e24810`); the fixer tool's `RunId` was bound to
  a nonexistent trigger input and wrote its logs to `manual/` (`ea140a8`).
- **Bugs invisible to `probe-phase.sh`.** The probe drives `vm-exec-vm` directly and never
  evaluates a flow expression, so status-parsing, `deriveRunId`, agent-prompt and node-schema
  defects all survive a green probe. Four such bugs stood between the first trigger run and the
  first clean one.
