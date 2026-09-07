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
  assert.equal(out.total, 3, 'three distinct studio-* tests (vsix excluded, duplicates collapsed)');
  assert.equal(out.selected.length, 3);
  assert.equal(out.skipped, 0);
  assert.deepEqual(out.selected.map((t) => t.file), [
    'specs/data-transform/data-transform.spec.ts',
    'specs/data-transform/data-transform.spec.ts',
    'specs/debug/debug-execution.spec.ts',
  ].sort());
  assert.equal(out.selected[0].testCommand,
    'corepack pnpm exec playwright test --config e2e/playwright.config.ts e2e/specs/data-transform/data-transform.spec.ts --project studio-alpha --grep "should add a Map operation with field mappings"');
}
{
  const out = run('selectTests', { start: { output: input } }); // maxTests 1
  assert.equal(out.selected.length, 1);
  assert.equal(out.skipped, 2);
}
{
  const out = run('selectTests', { start: { output: { ...input, projects: 'studio-*,vsix-*', maxTests: 10 } } });
  assert.equal(out.total, 4, 'vsix rows dedupe across platforms into one');
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
      prUrl: 'https://github.com/UiPath/flow-workbench/pull/3729', hypothesis: 'neighbor rail intercepts click', failed: false, errorMessage: '' } } } ] },
  }).text;
  assert.match(text, /VmAgent investigated 1 of 3 studio-\* failures/);
  assert.match(text, /data-transform\.spec\.ts › should add a Map operation with field mappings/);
  assert.match(text, /reproduced, fix verified, <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3729\|draft PR>/);
  assert.match(text, /2 not investigated \(maxTests=1\)/);
  const none = run('summarize', { start: { output: input }, selectTests: { output: { total: 0, skipped: 0, selected: [] } }, investigate: { output: [] } }).text;
  assert.match(none, /no studio-\* failures to investigate/);
  console.log('summarize ok');
}
