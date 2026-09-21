# Plan: better PR descriptions from the VmAgent flow

Status: proposed, not implemented. Written 2026-09-06.

## Problem

The `openPr` node writes the PR body from a template that pastes the fixer agent's
`fixSummary` verbatim:

```
## Fix summary
${$vars.fixer.output.fixSummary}
```

`fixSummary` is declared as a plain string with the description *"What was changed and
why, or why no fix was written"* and the system prompt says nothing about formatting.
The model therefore returns one unbroken 300-400 word paragraph, which is what PR #3687
shows.

Two secondary defects visible in the same PR body:

- Bare identifiers containing `$` and `_` (`$vars.script1.output.name`, `\w+`) are
  rendered as LaTeX by GitHub, so the summary contains italic maths in the middle of a
  sentence.
- The body never states what actually changed on disk. A reviewer has to open the Files
  tab to learn that it is a two-line edit in one file.

## Where the code is

| what | location |
|---|---|
| PR body template + title derivation | `vm-agent/VmAgent/VmAgent.flow:1584` (`openPr` expression) |
| fixer system prompt, "Output fields" block | `vm-agent/VmAgent/VmAgent.flow:1071` |
| `fixSummary` output-variable description | `vm-agent/VmAgent/VmAgent.flow:1136` |
| summarizer prompt that also consumes `fixSummary` | `vm-agent/VmAgent/VmAgent.flow:744` |

## Approach

Keep `fixSummary` a single string. Constrain its shape through the prompt and the schema
description rather than splitting it into new output fields — splitting would require
touching the summarizer prompt and the PR-title derivation for no additional benefit.

### Change 1 — tell the fixer how to format `fixSummary`

In the fixer system prompt (line 1071), replace the current bullet

```
- fixSummary: what you changed and why, or what a human needs to change and why you declined.
```

with:

```
- fixSummary: markdown, under 120 words, in exactly this shape:
  **Cause:** one sentence naming file:line and the wrong value.
  **Change:** one sentence describing the edit.
  Then at most 3 `-` bullets of supporting evidence.
  Never write a single long paragraph. Wrap every identifier, locator string, path and
  regex in backticks — unbackticked `$` and `_` render as LaTeX on GitHub.
  If you declined, use the same shape and say what a human must change instead.
```

Mirror the shape constraint and the backtick rule into the `fixSummary` description at
line 1136; the output-variable description is also sent to the model and currently
contradicts the prompt by implying free text.

### Change 2 — put the diff in the body

The `openPr` script already has the commit in hand. After the successful commit, add a
diffstat section to the body template:

```
## Files changed
$(git show --stat --format= HEAD | Out-String)
```

This requires switching the here-string from `@'...'@` (literal) to `@"..."@`
(expanding). Audit the rest of the template for `$` when doing so — the JS-side
`${...}` interpolations are resolved before PowerShell sees the string, so only literal
`$` characters in prose are at risk.

### Change 3 (optional) — reviewer line

Add one line under `## Verification` naming what a human should re-check, e.g. the spec
path and the fact that the run used `--project studio-local`, not `studio-alpha`. Skip
if Change 1 and 2 already make the body readable.

## Verification

1. Apply the edits to `VmAgent.flow`.
2. `git diff` the nested `agent.json` and the tool `resource.json` files — editing the
   flow regenerates them and silently reverts hand-made fixes (see `TRAPS.md`, `ea140a8`).
3. `./release.sh 1.0.25 inputs/debug-execution-fixer.json` — the fixer-resume input path,
   so the run reaches `openPr` without a full investigation.
4. Read the resulting draft PR body. Success is: a `**Cause:**`/`**Change:**` pair, at
   most 3 bullets, no italic maths, and a diffstat.

`probe-verify.sh` does not cover this — it exercises the verify step, not `openPr`. There
is no cheaper check than one release cycle, so batch these edits with any other pending
flow change.

## Risks

- Prompt-only constraints are advisory. If the model still overruns, the next step is
  splitting `fixSummary` into `cause` / `change` / `evidence` output variables and
  composing the body from them; that is the fallback, not the first attempt.
- Every verified fix opens a real draft PR on `UiPath/flow-workbench`. Re-running the
  same `runId` force-pushes the same branch rather than opening a second PR, so iterate
  on one `runId` to avoid PR spam.
- The `Run URL` and `Jira` sections of the body come from a `github-actions` bot editing
  the comment after the fact, not from this flow. They are out of scope here.
