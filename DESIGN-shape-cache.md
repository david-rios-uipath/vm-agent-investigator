# Design: failure-shape cache and a backlog that drains

Status: proposed, 2026-09-08. Nothing here is built.

## The problem, in one run

The 2026-09-08 nightly produced 21 failing test rows -> 18 distinct tests -> 10 cause groups.
`maxTests` is 1, so the orchestrator investigated **one** group and dropped the other nine. Worse,
the one it picked (`agent-tools-vsix.spec.ts`) was already fixed by flow-workbench#3780, which the
PR check could not see: #3780 touches `agent-rename.spec.ts`, `e2e/utils/inline-agent.ts` and the
workflow, never the failing spec, and coverage matches on the spec file.

So: 10% of the red looked at, and that 10% spent on solved work. Nothing carries to tomorrow - the
next run starts from the next nightly's failures with no memory.

## What already exists

- **A failure-shape key.** `selectTests` normalises the first error line (ANSI stripped, digits and
  hashes -> `#`, 160 chars) and groups by it: a named `Error:` groups across spec files, a bare
  `TimeoutError` only within its file.
- **A PR check.** `ghPrs` is a `vm-exec-vm` job that pulls the 40 most recently updated PRs with
  their changed files; `pickTests` marks a group covered when a PR touches its spec or a page object
  named in the error.
- **A bucket.** `e2e-investigations`, already used for per-run `state.zip` and notebooks.

The cache is the missing third thing: what we learned, kept.

## The record

`cache/shapes.jsonl`, one object per line so a human diffs it and reads fifty entries in half a
minute. Field names say what they hold - this file is meant to be read by people, and a saved byte
is worth nothing next to a reviewer having to look up what `k` meant.

```json
{"shape":"Error: locator.click: Timeout #ms exceeded|toolbox-item-agent.tool.#",
 "example":"agent-tools-vsix.spec.ts > tools handle: a published RPA workflow tool",
 "nightsSeen":4,"firstSeen":"2026-09-05","lastSeen":"2026-09-08","platform":"linux-only",
 "fix":{"pr":3780,"mergedAt":"2026-09-09","mergeSha":"f77b048"},
 "fixNote":"Linux Xvfb screen 1280x960 -> 1600x1200"}
```

| field | meaning |
|---|---|
| `shape` | the failure-shape key, as computed today |
| `example` | one example, `spec > test title` |
| `nightsSeen` | how many nightlies this shape has appeared in |
| `firstSeen` / `lastSeen` | dates of the first and most recent appearance |
| `platform` | platform pattern when one exists (`linux-only`) |
| `fix` | **merged PR only**: `pr`, `mergedAt`, `mergeSha` |
| `fixNote` | one sentence, what the fix did |
| `hypothesis` | an agent's unconfirmed conclusion: `text` plus the `runId` that wrote it |
| `agreedWithFix` | set when a merged PR later lands on a shape that carried a `hypothesis`: did the PR touch what the hypothesis named |

Caps: `fixNote` and `hypothesis.text` one sentence each. No prose, no analysis, no model output.
Reasoning stays in the notebook in the bucket and is referenced by path.

## Two rules

1. **Only a merged PR suppresses work.** `fix` is written when the PR is approved and merged. An
   agent's own conclusion goes in `hypothesis`, is advisory to the investigator's prompt, and never removes
   a group from selection.
2. **Recurrence after merge invalidates the entry.** A shape whose `lastSeen` is later than
   `fix.mergedAt` is wrong by construction: it flips to stale, stops suppressing anything, and is
   surfaced. This is what stops one bad line from hiding a real regression forever.

Rule 1 is a starting posture, not a law. It relaxes on evidence:

| level | who can suppress | promotion criterion |
|---|---|---|
| 0 (now) | merged PRs only | - |
| 1 | a `fixVerified=true` run a human acknowledged | `agreedWithFix` true on a stated majority of shapes over a stated sample |
| 2 | verified fixes open PRs and suppress pending review | level 1 held for a stated period with no stale flips |

`agreedWithFix` is recorded from day one precisely so the promotion is an argument from data rather than a
feeling that it seems to be working.

## Every line has a lever

Nothing is recorded that cannot be re-checked by a machine.

| field | lever | fails when |
|---|---|---|
| `fix.pr` | `gh pr view <n> --json state,mergedAt,files` | not `MERGED`, or reverted |
| `fix` + `lastSeen` | date comparison | the shape recurred after the merge |
| `hypothesis` | the notebook blob still exists | the run's state was pruned |
| `example` | run URL + job id | - a human opens the exact log line |

A verifier job - same shape as `ghPrs`, so no new plumbing - re-runs every lever each night and
reports. Anything failing stops influencing selection until a human or a merged PR restores it. The
worst a wrong entry can do is waste one night's slot.

## Selection becomes a queue

`pickTests`, in order:

1. shapes never investigated, most tests first
2. recurring unresolved shapes (`nightsSeen >= 2`, no `fix`)
3. shapes with a `hypothesis` but no `fix` - worth a second pass
4. never re-pick a shape with a live `fix`, unless rule 2 flipped it stale

## Throughput: sequential, not parallel

`maxTests` is pinned at 1 because the loop is `parallel: true` - every selected test starts its own
`VmAgent` job at once and the extras queue behind the single VM until they time out. A VmAgent run
is 10-35 minutes and the nightly fires once a day.

A **sequential loop with a wall-clock budget** (say 4 hours) gets 6-10 groups a night on the same one
VM, and sidesteps the unproven iteration-scoping question, which only bites with `parallel: true`.

Cost: at ~$5-7 of model spend per investigation, 8 groups a night is roughly $50/night. That number
should be a decision, not a surprise.

## Out of scope

- Auto-applying a cached fix to a new failure. The cache informs the investigator and the queue; it
  does not patch anything.
- Cross-repo sharing.
- Any storage that is not a plain file in the bucket.

## First steps, cheapest first

1. **Validate the key before building anything.** Run the 21 rows from run 34193167310 through the
   existing shape key: does the auth-429 shape collapse the Windows and Linux rows together while
   keeping the Xvfb-clipping shape separate? If the key is wrong, everything above is built on sand.
2. Write `cache/shapes.jsonl` from the last week of nightlies by hand, and read it in review. Fifty
   lines of real data will say more about the schema than more design will.
3. Extend `ghPrs` to also emit `SHAPES_JSON=`; `pickTests` consumes it for ordering only.
4. Write back after each run: `hypothesis`, `nightsSeen`, `lastSeen`.
5. Add the verifier job.
6. Sequential budget, as its own change, once the queue has something to work through.
