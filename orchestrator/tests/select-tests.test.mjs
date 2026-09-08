// Runs the selectTests / summarize script-node sources straight out of the .flow.
// Run: node orchestrator/tests/select-tests.test.mjs
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

// selectTests: studio only, dedupe, cap, stable order, command shape
{
  const out = run('selectTests', { start: { output: { ...input, maxTests: 5 } } });
  assert.equal(out.totalTests, 3, 'three distinct studio-* tests (vsix excluded, duplicates collapsed)');
  assert.equal(out.total, 2, 'the two data-transform tests share a cause');
  assert.equal(out.selected.length, 2);
  assert.deepEqual(out.selected[0].siblings, ['should write a Custom Script operation in a Data Transform node']);
  assert.deepEqual(out.selected[1].siblings, []);
  assert.equal(out.skipped, 0);
  assert.deepEqual(out.selected.map((t) => t.file), [
    'specs/data-transform/data-transform.spec.ts',
    'specs/debug/debug-execution.spec.ts',
  ]);
  assert.equal(out.selected[0].testCommand,
    'corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/specs/data-transform/data-transform.spec.ts --project studio-alpha --grep "should add a Map operation with field mappings"');
}
{
  // A named Error: groups across files; the biggest group is investigated first.
  const ft = [
    { project: 'studio-alpha', file: 'specs/a/a.spec.ts', title: 'a1', error: 'Error: StudioProjectsPage.validate: the portal redirected to an auth error after 3 attempts (https://x/1)' },
    { project: 'studio-alpha', file: 'specs/b/b.spec.ts', title: 'b1', error: 'Error: StudioProjectsPage.validate: the portal redirected to an auth error after 3 attempts (https://x/2)' },
    { project: 'studio-alpha', file: 'specs/a/a.spec.ts', title: 'a2', error: 'TimeoutError: locator.click: Timeout 10000ms exceeded.' },
    { project: 'studio-alpha', file: 'specs/b/b.spec.ts', title: 'b2', error: 'TimeoutError: locator.click: Timeout 10000ms exceeded.' },
  ];
  const out = run('selectTests', { start: { output: { ...input, failedTests: ft, maxTests: 10 } } });
  assert.equal(out.total, 3, 'auth error groups across files; timeouts stay per file');
  assert.equal(out.selected[0].title, 'a1');
  assert.deepEqual(out.selected[0].siblings, ['b.spec.ts › b1']);
  assert.deepEqual(out.selected.slice(1).map((s) => s.siblings), [[], []]);
}
{
  const out = run('selectTests', { start: { output: input } }); // maxTests 1
  assert.equal(out.selected.length, 1);
  assert.equal(out.skipped, 1);
}
{
  const out = run('selectTests', { start: { output: { ...input, projects: 'studio-*,vsix-*', maxTests: 10 } } });
  assert.equal(out.totalTests, 4, 'vsix rows dedupe across platforms into one');
  assert.equal(out.total, 3);
}
{
  const out = run('selectTests', { start: { output: { ...input, failedTests: [{ project: 'studio-alpha', file: 'specs/a.spec.ts', title: 'has "quotes" and (parens) $1' }] } } });
  assert.match(out.selected[0].testCommand, /--grep "has \\"quotes\\" and \\\(parens\\\) \\\$1"$/);
}
console.log('selectTests ok');

// summarize: Slack mrkdwn digest
{
  const text = run('summarize', {
    start: { output: input },
    selectTests: { output: { total: 3, skipped: 2, selected: [input.failedTests[0]] } },
    investigate: { output: [ { recordResult: { output: {
      project: 'studio-alpha', file: 'specs/data-transform/data-transform.spec.ts',
      title: 'should add a Map operation with field mappings', reproduced: true, fixVerified: true,
      prUrl: 'https://github.com/UiPath/flow-workbench/pull/3729', hypothesis: 'neighbor rail intercepts click', failed: false, errorMessage: '', siblings: ['should write a Custom Script operation in a Data Transform node'] } } } ] },
  }).text;
  assert.match(text, /VmAgent investigated 1 of 3 studio-\* failure groups/);
  assert.match(text, /data-transform\.spec\.ts › should add a Map operation with field mappings/);
  assert.match(text, /reproduced, fix verified, <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3729\|draft PR>/);
  assert.match(text, /2 not investigated \(maxTests=1\)/);
  assert.match(text, /\(\+1 same cause: `should write a Custom Script operation in a Data Transform node`\)/);
  assert.match(text, /<https:\/\/theater\.uipath\.co\/flow\/[0-9a-f]+\/\|report>/);
  const none = run('summarize', { start: { output: input }, selectTests: { output: { total: 0, skipped: 0, selected: [] } }, investigate: { output: [] } }).text;
  assert.match(none, /no studio-\* failures to investigate/);
  const flat = run('summarize', {
    start: { output: input },
    selectTests: { output: { total: 3, skipped: 2, selected: [input.failedTests[0]] } },
    investigate: { output: [ {
      project: 'studio-alpha', file: 'specs/data-transform/data-transform.spec.ts',
      title: 'should add a Map operation with field mappings', reproduced: true, fixVerified: true,
      prUrl: 'https://github.com/UiPath/flow-workbench/pull/3729', hypothesis: 'neighbor rail intercepts click', failed: false, errorMessage: '' } ] },
  }).text;
  assert.match(flat, /data-transform\.spec\.ts › should add a Map operation with field mappings/);
  console.log('summarize ok');
}
