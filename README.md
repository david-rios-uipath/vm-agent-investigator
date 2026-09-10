# vm-agent-investigator

Autonomous triage and investigation of failing Playwright e2e tests in
[`UiPath/flow-workbench`](https://github.com/UiPath/flow-workbench), running on a
Windows Cloud Robot VM.

A UiPath Maestro Flow (`VmAgent`) orchestrates four coarse phases — `repro`,
`investigate`, `fix`, `pr` — each executed as one Orchestrator job through a single
generic PowerShell-runner RPA process (`vm-exec`). The reasoning happens on the VM
via `claude -p`, not in the cloud; every phase is self-contained (refreshes the
checkout, pulls its state from a storage bucket, pushes it back) and emits one
`STATUS_JSON=<json>` line the flow parses to route the next step.

`NightlyOrchestrator` fans the flow out over the nightly test failures.

## Layout

| path | what |
|---|---|
| `vm/` | everything that runs on the VM: `run-phase.ps1`, `lib/`, `prompts/`, `selfcheck.ps1` |
| `vm-agent/` | the UiPath solution: `vm-exec` process, `VmAgent` + `NightlyOrchestrator` flows, inline agents |
| `release.sh` | pack, publish, redeploy the solution, start a job: `./release.sh 1.0.25` |
| `release-vm-exec.sh` | publish `vm-exec` and repoint `e2e-investigator/vm-exec-vm` |
| `probe-phase.sh` | run one phase against the VM without packing (~5 min) |
| `inputs/`, `reports/` | job inputs and run write-ups |

## Phases

1. **`repro`** — reproduce the failure locally on the VM, if the nightly CI history
   has not already settled it.
2. **`investigate`** — find the root cause and write it up.
3. **`fix`** — attempt a fix, only when it is short and self-contained:
   1. validate it by re-running the spec;
   2. **`pr`** — open a PR with the fix, bug and fix demo videos attached.

## Docs for agents

Read in this order:

1. `HANDOFF.md` — current state, how to run it, what is verified
2. `FINDINGS-uip.md` — UiPath CLI/platform traps
3. `DESIGN-phase-runner.md` — why the reasoning moved onto the VM

## Local checks

```
pwsh -NoProfile -File vm/selfcheck.ps1     # pure logic asserts
```

Always release with `release.sh` — a plain `uip solution pack` drops the agent tool
binding and every phase job then fails to start.
