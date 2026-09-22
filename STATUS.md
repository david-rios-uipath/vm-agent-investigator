# Status

Rewrite this file; do not append to it. Dated run write-ups belong in `LOG.md`, traps in
`TRAPS.md` / `FINDINGS-uip.md`, commands in `RUNBOOK.md`, shape in `ARCHITECTURE.md`.

Last updated 2026-09-21.

## Released

- **Deployment:** `Shared/vm-agent 12`, package identity `vm-agent 8`, version **1.1.12**.
- **`vm-exec` 1.0.5** is published and live (`vm-exec-vm` points at it).
- **CI hook:** flow-workbench PR
  [#3756](https://github.com/UiPath/flow-workbench/pull/3756) posts the nightly payload.

## Proven

- `VmAgent` end to end from the trigger: `repro -> investigate -> fixVerify (with retry) -> openPr
  -> summarizer -> end`, twice, on two different specs, with a real draft PR both times.
- `NightlyOrchestrator` end to end on the 2026-09-07 nightly: 6 failed tests -> 3 causes, 2
  attributed to a merged PR by the PR check, the third investigated, one Slack reply posted.
- The in-solution `VmAgent` process binding resolves in a deployed folder.
- vsix phases `repro` / `investigate` / `fix` on `vsix-alpha-windows`, one at a time through
  `probe-phase.sh`.
- `StateKey` round-trips through the bucket both ways, proven by wiping the VM's local copies.
- On the VM: `ANTHROPIC_API_KEY` arrives (108 chars), `GH_TOKEN` and `GIT_TOKEN` are present.

Details and dates: `LOG.md`.

## Not verified

- The **`pr` phase on a vsix run** (it is platform-agnostic and proven for studio).
- **Any vsix run driven by the flow** rather than by `probe-phase.sh`.
- The CI script (`start-nightly-investigation.sh`) against the tenant — token exchange unverified.
  PR #3756 is still a draft; CI vars/secrets are set (`UIPATH_INVESTIGATOR_*`).
- `GIT_TOKEN` has never actually fetched the runner repo from the VM (it is public, so nothing
  needs it to).
- **A green verify is not evidence the fix repairs the nightly.** On `vsix-pkg-3` the established
  cause was an identity 429 that cannot occur on the VM, which logs in fresh as a single leg. The
  patch is sound and the spec passes; the fixer said `confidence: medium` and that is the honest
  reading.

## Blocked on a human

**The Slack app is not approved for the workspace yet**, so there is no token with
`files:write` to put in the asset. The `SLACK_BOT_TOKEN` Secret asset in folder
**`e2e-investigator`** is still empty: `vm-exec` injects nothing, and the `report` phase
renders its file into `state.zip` and uploads nothing. That is
the safe state - no fault, no silence - but it is also why `summarize` **still carries the
per-group cause / repro / finding lines**. Deleting them before the upload works would make
the nightly say less than it does today; the block to delete is marked in the `summarize`
script. Until then the only net change to the nightly message is the 3500-char cap.

To turn the per-group reports on:

1. Get a Slack app token with the **`files:write`** scope.
2. **Invite that app to `#flow-dev-frontend` (`C0AH25MT3L5`)** — a bot identity previously got
   `channel_not_found` there precisely because it was not a member, which is why the connector
   nodes run `send_as=user`.
3. Set it as the value of the `SLACK_BOT_TOKEN` **Secret** asset in `e2e-investigator` (the
   process folder for `vm-exec-vm`). Not the deployment folder: `release.sh` recreates that
   one every time. A bot token has no username half, so this is a Secret, not a Credential -
   `vm-exec` reads it with `GetSecret`, and the switch needs a `./release-vm-exec.sh <version>`
   to reach the VM.

Then `./probe-script.sh vm/probes/slack-upload.ps1` proves it in ~5 minutes, and the marked
block in `summarize` comes out.

## In the tree, not released

- Per-group Slack reports: the `report` phase, `vm/lib/report.ps1`, `Send-SlackFile`, and the
  shrunken `summarize` roll-up (this branch).
- The VM-side `fetchFailures` process, the cost report, and the queued (rather than dropped)
  failure groups — PR
  [#1](https://github.com/david-rios-uipath/vm-agent-investigator/pull/1). `ARCHITECTURE.md` does
  not describe these yet.

## Do this next

1. **Per-group Slack reports.** `vm/selfcheck.ps1` passes locally; nothing else is verified,
   and the upload is blocked on the app approval above. What does not need the token:
   `./probe-phase.sh report <runId>` against a runId whose `state.zip` still has a
   `notebook.md` (push first — the bootstrap fetches the ref), which proves the rendering and
   the STATUS line. Once the token exists: `./probe-script.sh vm/probes/slack-upload.ps1`,
   then one `VmAgent` group end to end with `slackThreadTs` set to a scratch thread, then drop
   the marked block in `summarize`.
2. **Release and run the queued-groups work.** `./release.sh <version>
   inputs/orchestrator-<latest>.json NightlyOrchestrator`, starting with a `maxTests: 0` canary.
3. **Take PR #3756 out of draft** once one tenant-side CI run has proven the token exchange.
4. **Uninstall the wedged `vm-agent 11` deployment** once Orchestrator clears its three
   `Terminating` Maestro jobs, and report the Kill behaviour to the Maestro team.
5. **Prove the `pr` phase on a vsix run**, then one flow-driven vsix run end to end.
6. **File the two flow-workbench defects** in `PRODUCT-FINDINGS.md` — they are real independent of
   this tooling and are currently filed nowhere.

## Open items / cleanup owed

- Slack "edit one message" is dropped rather than owed: with one report per group there is
  nothing left to edit. The upload path needs a real `SLACK_BOT_TOKEN` (see below).
- Slack renders `<`/`>` from the hypothesis escaped (`&lt;nav&gt;`); strip them in `summarize`.
- VmAgent still reproduced the Map-operation failure on `develop` after flow-workbench #3758
  merged; #3758 may not cover it.
- The PR title is derived from `fixSummary` and truncated to a word boundary. #3687 was opened
  before that fix and reads `... (lines 84 an (automated investigator)`.
- `rg` is not on PATH in the agent's `vm_exec` sessions (setup only prepends `C:\vm-agent\bin` for
  its own session). The tool description says so; better would be fixing the PATH or installing rg
  machine-wide.
- The `Shared/vm-agent 12` folder is recreated on every redeploy, which drops machine assignments
  and hand-made assets. The three placeholder credential assets
  (`GH_TOKEN`/`SLACK_COOKIE`, and `SLACK_BOT_TOKEN` before it became a Secret) and the VM machine
  template assignment from the
  abandoned single-folder experiment may or may not still be there; they are harmless.
- `vm-agent-priv` deployment in the personal workspace — dead end, uninstall it.
- Nine Studio Web solutions `vm-agent` … `vm-agent 9` exist; David declined bulk deletion.
- Two CLI bugs worth filing: `pack` not reproducing Studio Web's `bindings_v2.json` for
  inline-agent tool bindings (repro: published 1.0.0 zip vs local pack of the same source), and
  `deploy upgrade` wedging a deployment into `VersionChange / Draft` permanently.
