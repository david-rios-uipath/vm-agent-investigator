// Runs the script-node sources straight out of the .flow. Run: node orchestrator/tests/select-tests.test.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const flow = JSON.parse(readFileSync(new URL('../../vm-agent/NightlyOrchestrator/NightlyOrchestrator.flow', import.meta.url)));
const scriptOf = (id) => {
  const n = flow.nodes.find((n) => n.id === id);
  assert.ok(n, `node ${id} missing`);
  return n.inputs.script.expression;
};
const run = (id, $vars) => new Function('$vars', scriptOf(id))($vars);
const input = JSON.parse(readFileSync(new URL('../../inputs/orchestrator-34015558366.json', import.meta.url)));
const night2 = JSON.parse(readFileSync(new URL('../../inputs/orchestrator-34089391590.json', import.meta.url)));

// selectTests: studio only, dedupe, group by cause, stable order, command shape
{
  const out = run('selectTests', { start: { output: input } });
  assert.equal(out.totalTests, 3, 'three distinct studio-* tests (vsix excluded, duplicates collapsed)');
  assert.equal(out.total, 2, 'the two data-transform tests share a cause');
  assert.deepEqual(out.groups.map((t) => t.file), ['specs/data-transform/data-transform.spec.ts', 'specs/debug/debug-execution.spec.ts']);
  assert.deepEqual(out.groups[0].siblings, ['should write a Custom Script operation in a Data Transform node']);
  assert.equal(out.groups[0].testCommand,
    'corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/specs/data-transform/data-transform.spec.ts --project studio-alpha --grep "should add a Map operation with field mappings"');
}
{
  const out = run('selectTests', { start: { output: { ...input, projects: 'studio-*,vsix-*' } } });
  assert.equal(out.totalTests, 4, 'vsix rows dedupe across platforms into one');
  assert.equal(out.total, 3);
}
{
  const out = run('selectTests', { start: { output: { ...input, failedTests: [{ project: 'studio-alpha', file: 'specs/a.spec.ts', title: 'has "quotes" and (parens) $1' }] } } });
  assert.match(out.groups[0].testCommand, /--grep "has \\"quotes\\" and \\\(parens\\\) \\\$1"$/);
}
{
  // A named Error: groups across files; the biggest group comes first.
  const out = run('selectTests', { start: { output: night2 } });
  assert.equal(out.total, 3); assert.equal(out.totalTests, 6);
  assert.equal(out.groups[0].title, 'should add a Group by operation with aggregations');
  assert.equal(out.groups[0].siblings.length, 2);
  assert.match(out.groups[0].siblings[0], /^hitl-debug-e2e\.spec\.ts › /);
}
console.log('selectTests ok');

// pickTests: open-PR coverage, cap, tolerant of missing GitHub data
const sel2 = run('selectTests', { start: { output: night2 } });
const prs = [
  { number: 3758, title: 'fix(e2e): revive three closed nightly fixes', html_url: 'https://github.com/UiPath/flow-workbench/pull/3758' },
  { number: 3700, title: 'chore: unrelated', html_url: 'https://github.com/UiPath/flow-workbench/pull/3700' },
];
const prsOut = { prs: [
  { number: 3758, title: 'fix(e2e): revive three closed nightly fixes', url: 'https://github.com/UiPath/flow-workbench/pull/3758', state: 'merged', files: ['e2e/pages/StudioProjectsPage.ts', 'packages/canvas/src/components/properties-panel/neighbors/NeighborRail.tsx'] },
  { number: 3700, title: 'chore: unrelated', url: 'https://github.com/UiPath/flow-workbench/pull/3700', state: 'open', files: ['README.md'] },
], ok: true };
// parsePrs: last PRS_JSON= line wins; absence or bad JSON degrades to no PRs
{
  const compact = prsOut.prs.map((p) => ({ n: p.number, t: p.title, s: p.state === 'merged' ? 'm' : 'o', f: p.files.map((x) => x.split('/').pop()) }));
  const stdout = 'noise\n[prcheck] 2 candidate PRs\nPRS_JSON=' + JSON.stringify(compact) + '\n';
  const out = run('parsePrs', { ghPrs: { output: { ExitCode: 0, Stdout: stdout } } });
  assert.equal(out.ok, true); assert.equal(out.prs.length, 2); assert.deepEqual(out.prs[0], { number: 3758, title: prsOut.prs[0].title, url: 'https://github.com/UiPath/flow-workbench/pull/3758', state: 'merged', files: ['StudioProjectsPage.ts', 'NeighborRail.tsx'] });
  assert.deepEqual(run('parsePrs', { ghPrs: { output: { ExitCode: 1, Stdout: 'boom' } } }), { prs: [], ok: false, exitCode: 1 });
  assert.equal(run('parsePrs', { ghPrs: { output: { Stdout: 'PRS_JSON={bad' } } }).ok, false);
  assert.equal(run('parsePrs', { ghPrs: { error: { message: 'x' } } }).ok, false);
}
console.log('parsePrs ok');
{
  const out = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: prsOut } });
  assert.equal(out.covered.length, 1, 'the auth-error group names StudioProjectsPage, which #3758 touches');
  assert.equal(out.covered[0].coveredBy.number, 3758);
  assert.equal(out.covered[0].coveredBy.file.split('/').pop(), 'StudioProjectsPage.ts'); assert.equal(out.covered[0].coveredBy.state, 'merged');
  assert.equal(out.selected.length, 1, 'maxTests 1: the slot goes to the next uncovered group');
  assert.equal(out.selected[0].title, 'should add a Map operation with field mappings');
  assert.equal(out.skipped, 1);
  assert.equal(out.total, 3); assert.equal(out.totalTests, 6);
  assert.deepEqual(out.prs[0].files.length, 2);
}
{
  // A failed GitHub call degrades to "nothing covered".
  const none = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: { prs: [], ok: false } } });
  assert.equal(none.covered.length, 0); assert.equal(none.selected.length, 1); assert.equal(none.skipped, 2);
}
console.log('pickTests ok');

// recordResult: related PRs from the hypothesis
{
  const pick = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: prsOut } });
  const t = pick.selected[0];
  const out = run('recordResult', { investigate: { currentItem: t }, pickTests: { output: pick },
    callVmAgent: { output: { reproduced: true, fixVerified: false, prUrl: '', hypothesis: 'The rail in NeighborRail.tsx:112 overlaps the close button' } } });
  assert.equal(out.failed, false);
  assert.deepEqual(out.relatedPrs.map((p) => p.number), [3758]);
  const failed = run('recordResult', { investigate: { currentItem: t }, pickTests: { output: pick }, callVmAgent: { output: {}, error: { message: 'boom' } } });
  assert.equal(failed.failed, true); assert.equal(failed.errorMessage, 'boom');
}
console.log('recordResult ok');

// summarize
{
  const pick = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: prsOut } });
  const row = { project: 'studio-alpha', file: 'specs/data-transform/data-transform.spec.ts', title: 'should add a Map operation with field mappings',
    reproduced: true, fixVerified: true, prUrl: 'https://github.com/UiPath/flow-workbench/pull/3729', hypothesis: 'neighbor rail intercepts click', failed: false, errorMessage: '',
    siblings: ['should write a Custom Script operation in a Data Transform node'], relatedPrs: [{ number: 3758, title: 't', url: 'https://github.com/UiPath/flow-workbench/pull/3758', state: 'merged' }] };
  const text = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [{ recordResult: { output: row } }] } }).text;
  assert.match(text, /VmAgent investigated 1 of 3 studio failure groups\* \(6 tests, <https:\/\/github\.com\/UiPath\/flow-workbench\/actions\/runs\/34089391590\|run 34089391590>\) · <https:\/\/theater\.uipath\.co\/flow\/[0-9a-f]+\/\|report>/);
  assert.match(text, /data-transform\.spec\.ts › should add a Map operation with field mappings` \(\+1 same cause: `should write a Custom Script operation in a Data Transform node`\) — reproduced, fix verified, <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3729\|draft PR>, related merged <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3758\|PR #3758>/);
  assert.match(text, /should add a Group by operation with aggregations` \(\+2 same cause\) — likely already fixed by merged <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3758\|PR #3758> \(touches `StudioProjectsPage\.ts`\)/);
  assert.match(text, /1 not investigated \(maxTests=1\)/);
  const flat = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [row] } }).text;
  assert.match(flat, /should add a Map operation with field mappings/);
  const none = run('summarize', { start: { output: night2 }, pickTests: { output: { total: 0, skipped: 0, selected: [], covered: [], totalTests: 0 } }, investigate: { output: [] } }).text;
  assert.match(none, /no studio failures to investigate/);
}
console.log('summarize ok');
