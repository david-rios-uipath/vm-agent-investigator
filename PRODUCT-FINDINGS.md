# What the agent found in flow-workbench

Product findings, not tooling state. **None of these is filed anywhere** — the agent searched
GitHub and found no tracked issue for them. They are real independent of this repo; someone should
take them.

## 1. Identity-service 429 flakiness (infra)

Runs `67953871`, `d99c4204`, `3bc47073`. All 5 parallel shards authenticate the *same* shared
alpha studio account (`playwright-action.yml:183-185`), so identity rate-limits. Env-signal counts
across 8 nights: `identity429` 12 and 6 on the two failed nights vs 2-4 on passing nights;
`cleanup400` (14-16) only on failed nights, and it is shard-wide teardown noise from
`StudioProjectsManager.deleteSolution`, not a cause.

The vsix legs have the same shape: `playwright-vsix.yml:126-133` signs one account in from three
OS legs at once with no `max-parallel`, which is the environment cause behind the observed platform
split.

## 2. apollo-react regression breaking `debug-execution.spec.ts` (real fix available)

Run `6d77027a`. The bump to 6.38.0 (`3df679ace`) made `JsonTree`'s `NodeKey.js` set
`aria-label="Copy path for {path}"` on every row button; that overrides the accessible name and
breaks `getByRole('button', { name: 'output'|'name', exact: true })` at
`debug-execution.spec.ts:84,87`. Proven with `git merge-base --is-ancestor`: the bump is *not* an
ancestor of the 429 night `c7369f5`, *is* an ancestor of the nights showing this locator failure.

Verified fix: retarget both locators —
`getByRole('button', { name: /^Copy path for \$vars\.\w+\.output\.name$/ })`. Shipped as draft PR
[#3687](https://github.com/UiPath/flow-workbench/pull/3687) and verified by a real test run.

## 3. `launcher.ts` reads the POSIX `HOME` on Windows (portability)

`e2e/vsix/launcher.ts:191` reads `process.env.HOME` for the `seedAuth` copy, so it is a silent
no-op on Windows. The same repo resolves the same path correctly with `os.homedir()` at
`package-nested-solution.spec.ts:3`. Not a cause of any failure — the CLI has an `os.homedir()`
fallback — but a portability defect.

## 4. `UiPath: Package` palette row gated on a racing auth probe

Established on `vsix-pkg-3` (see `LOG.md`). The command is contributed only under
`when: "uipath.authenticated"` (`packages/vsix/package.json:531-534`), which is false until a
background `uip` probe succeeds (`authService.ts:940, 954-984`). When that probe is slowed by
finding 1's 429s, the row never renders and the wait at `VsixWorkbenchPage.ts:140` times out.

## Notebooks

`reports/2026-09-04-run-d99c4204-notes.md` (fullest), `…-3bc47073-notes.md`,
`…-67953871-notes.md`, plus `reports/2026-09-03-run-364f9617.md`.
