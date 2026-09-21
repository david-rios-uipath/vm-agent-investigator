# Runbook

Commands, in the order you normally need them. Shape of the system: `ARCHITECTURE.md`.
Current state and what to do next: `STATUS.md`.

## Local checks, free

```bash
pwsh -NoProfile -File vm/selfcheck.ps1        # pure logic asserts, no VM
pwsh -NoProfile -File vm/tests/pr-body.tests.ps1
node --test orchestrator/tests/*.test.mjs     # selectTests / cost
```

## Probe one phase against the VM — do this before releasing

Do **not** wait 30-60 minutes for a full flow run to test a phase.

```bash
export RUNNER_REPO_URL=https://github.com/david-rios-uipath/vm-agent-investigator
SMOKE_ONLY=1 ./probe-phase.sh repro probe-1     # twice: the second prologue must be < 60 s
./probe-phase.sh investigate <runId>
./probe-phase.sh fix <runId>
./probe-phase.sh pr <runId>
./probe-phase.sh report <runId>                 # renders report.md; posts nothing
```

`probe-phase.sh` calls `e2e-investigator/vm-exec-vm` directly with the bootstrap PowerShell that
the flow's `bootstrap<Phase>` node generates — **rendered from `VmAgent.flow` with node, not a
copy**, so the probe cannot drift from what the flow runs — and prints the phase's `STATUS_JSON`.
State comes from and goes back to `<runId>/state.zip`, exactly as in a real run. No pack, no
publish, no deploy.

Levers: `CLAUDE_MODEL` (defaults to Sonnet; set `claude-haiku-4-5-20251001` to test plumbing
rather than reasoning) and `TIMEOUT_MINUTES` (a cold vsix repro outlasts the 15-minute default
and returns `exitCode 124` having proven nothing).

Find a runId with:

```bash
uip or bucket-files list be6369c7-02a4-4b80-957b-e95d06177692 --folder-path "e2e-investigator" --output json
```

**`probe-script.sh <file.ps1> [minutes]`** runs a script that is not a flow node at all, sending
your working tree inline with no push (a `. vm/lib/x.ps1` line is inlined from the working tree
too). That is the cheapest way to ask the VM a question — the vsix session-0 question was
settled with it.

```bash
./probe-script.sh vm/probes/slack-upload.ps1    # set $THREAD_TS in the file first
```

That probe is where a missing `files:write` scope, a placeholder `SLACK_TOKEN` asset or an app
that was never invited to `#flow-dev-frontend` shows up, before the `report` phase depends on
any of them.

## Release

```bash
./release.sh 1.1.13                                                    # starts VmAgent
./release.sh 1.1.13 inputs/orchestrator-34089391590.json NightlyOrchestrator
```

`release.sh` packs, asserts the packaged `bindings_v2.json`, publishes, stops running jobs,
uninstalls + redeploys `Shared/vm-agent 12` and starts the job. The optional third argument is
the process to start (default `VmAgent`); both processes are deployed either way. The
packaged-bindings assertion covers both flows — `VmAgent` must carry
`e2e-investigator.vm-exec-vm`, and `NightlyOrchestrator` must carry the `VmAgent` process binding
`4a7879cf-7494-4ada-9e83-ea487a4b55cb`.

**Never hand-run the pack step** — see `FINDINGS-uip.md`.

`uip solution deploy run` has returned an HTTP 504 once, *after* `release.sh` had already
uninstalled the previous deployment: the folder was left empty and the run never started.
Re-running the same `deploy run` by hand fixes it; the script has no retry there.

### `vm-exec` is a separate release

```bash
./release-vm-exec.sh 1.0.6
```

`release.sh` packs the solution (the flow plus an in-solution `vm-exec` that nothing calls); the
process the phase nodes invoke is `vm-exec-vm` in the standard folder `e2e-investigator`, bound to
the tenant-feed package `vm-exec`. `release-vm-exec.sh` does `uip rpa pack` + `uip rpa publish` +
`uip or processes update-version`, bootstraps the pinned toolchain, and asserts the packaged
`lib/` target is `net8.0` before publishing. Pack it any other way and the job faults in four
seconds with `NU1202: Package vm-exec 1.0.4 is not compatible with net8.0`.

## Operational contract: `maxTests` and `budgetMinutes`

- `maxTests: 0` is a **no-child canary** — how a release gets smoke-tested without spending a
  `VmAgent` run.
- `budgetMinutes: 0` is an **immediate-break canary** — the loop breaks on its first
  `withinBudget` check before starting anything.
- The normal, automatic nightly run uses the defaults: 4 groups, 240 minutes.
- An exceptional manual run must use an explicitly calculated budget, no greater than `240` minus
  the minutes elapsed since 02:00 ET. If that calculation is not done, use `budgetMinutes: 0`.
- **Do not manually kick off a non-zero-budget run after 02:00 ET** — the three-hour child
  reserve no longer fits before the working day starts.
- If an observed child tail ever runs longer than three hours, reduce the default budget
  immediately; do not raise `maxTests`.

Cost: at 4 groups a night and roughly $5-7 of model spend per investigation, a bad night costs
$20-28, versus roughly $6 at one group. Promoting the default from 4 to 6 (a $30-42 bad night)
needs explicit approval after reviewing actual cost and observed tail duration — it should not
happen as an incidental bump.

## Read a run

```bash
# parent + agent children
uip or jobs list --folder-path "Shared/vm-agent 12" --output json
# every phase job lands here
uip or jobs list --folder-path "e2e-investigator" --output json
# a fix job's output contains '### patch first bytes' and FIX_VERIFIED=
uip or jobs get <job-key> --output json
```

Success looks like: `### studio MFE serving on port 3000` (studio path), no `git apply` error, a
test run lasting **minutes**, then `FIX_VERIFIED=true`. A verify finishing in <20 s means it never
ran the test.

## When it faults

Get the real reason from Maestro, not Orchestrator — the parent job stays `Running` after the
instance has faulted:

```bash
FK=$(uip or folders list --all --name "vm-agent 12" --output json | \
  python3 -c "import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(next(x['Key'] for x in d['Data'] if x['Path']=='Shared/vm-agent 12'))")
uip maestro flow instance get       <parent-job-key> -f $FK --output json   # LatestRunStatus, Cursors
uip maestro flow instance incidents <parent-job-key> -f $FK --output json   # the actual error
```

The folder key changes on every redeploy, so always re-resolve it.

A `Pending` phase job with `HostMachineName: None` means the **robot pool**, not the flow. Check
the heartbeat first:

```bash
uip or sessions unattended list --folder-path e2e-investigator     # read ReportingTime
```

**Do not `jobs stop --strategy Kill` a Maestro flow job** — cancel the instance instead. Three
killed jobs stuck in `Terminating` are what wedged the `vm-agent 11` deployment permanently.

## Save a notebook

```bash
uip or bucket-files list be6369c7-02a4-4b80-957b-e95d06177692 \
  --folder-path "e2e-investigator" --prefix "debug-execution-<runid>" --output json
uip or bucket-files download be6369c7-02a4-4b80-957b-e95d06177692 "<...>/read/<...>.log" \
  --folder-path "e2e-investigator" --destination reports/<date>-run-<key>-notes.md
```

Or download `<runId>/state.zip` and unzip it.

## Draft PRs from test runs

`openPr` **pushes to a shared repo**, so every verified fix creates a real draft PR and a real
remote branch on `UiPath/flow-workbench`, named `e2e-investigator/<runId>`. Close them and delete
the branch straight away (#3717, #3719, #3720 were all closed this way). `resumeRunId` reuses a
runId, so re-running the same runId force-pushes over the previous branch rather than opening a
second PR.

## Known-good baseline, if things go sideways

Package `vm-agent 8` **1.0.0**, published by Studio Web from solution
`6c998cb3-078b-4c80-dfce-08df093139b4`, ran clean on 2026-09-03 04:59-06:21 UTC (instance
`364f9617`, 25 tool calls, 0 incidents).

```bash
uip solution packages download "vm-agent 8" 1.0.0 -d /tmp/pub100
uip solution download 6c998cb3-078b-4c80-dfce-08df093139b4 -d /tmp/cloud8 --extract
```

That flow is smaller (13 nodes, no fixer, no ci-history) — useful as a diff target, not as a
replacement.
