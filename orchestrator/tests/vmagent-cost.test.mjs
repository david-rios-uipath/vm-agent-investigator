// Runs the VmAgent phase-status parsers straight out of the .flow.
// Run: node orchestrator/tests/vmagent-cost.test.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const flow = JSON.parse(readFileSync(new URL('../../vm-agent/VmAgent/VmAgent.flow', import.meta.url)));
const scriptOf = (id) => flow.nodes.find((n) => n.id === id).inputs.script.expression;
const run = (id, $vars) => new Function('$vars', scriptOf(id))($vars);

// The exact line vm/run-phase.ps1 prints after each claude call.
const costLine = (n) => `[claude] ended success after 12 turns in 340s, cost $${n}`;

{
  const stdout = [costLine('1.2345'), 'noise', 'STATUS_JSON={"reproduced":true,"source":"rerun"}'].join('\n');
  const out = run('parseStatusRepro', { repro: { output: { Stdout: stdout, ExitCode: 0 } } });
  assert.equal(out.reproduced, true, 'the status still parses');
  assert.equal(out.costUsd, 1.2345);
}
{
  // A phase that calls claude twice (fix then verify) reports both.
  const stdout = [costLine('0.5'), costLine('0.25'), 'STATUS_JSON={"fixVerified":false}'].join('\n');
  assert.equal(run('parseStatusFix', { fixVerify: { output: { Stdout: stdout } } }).costUsd, 0.75);
}
{
  // A runner that died before STATUS_JSON still reports what it burned.
  const out = run('parseStatusInvestigate', { investigate: { output: { Stdout: costLine('2'), ExitCode: 124 } } });
  assert.equal(out.runnerFailed, true);
  assert.equal(out.costUsd, 2);
}
{
  // No claude call at all (openPr is often pure git) costs nothing, not NaN.
  const out = run('parseStatusPr', { openPr: { output: { Stdout: 'STATUS_JSON={"prUrl":"https://x/1"}' } } });
  assert.equal(out.costUsd, 0);
  assert.equal(out.prUrl, 'https://x/1');
}
console.log('vmagent cost ok');
