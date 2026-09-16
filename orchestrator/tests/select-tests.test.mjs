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

// selectTests reading the VM's compact line instead of an inline payload. The fixture is the real
// stdout of fetchFailures' PowerShell over run 35062181090 (101 tests, 60 KB of JSON: the night
// that broke StartJobs' 10000-char InputArguments cap).
{
  const Stdout = readFileSync(new URL('../../inputs/fetch-failures-35062181090.stdout.txt', import.meta.url), 'utf8');
  const out = run('selectTests', { start: { output: { runId: '35062181090', failedCount: 101 } }, fetchFailures: { output: { Stdout } } });
  assert.equal(out.fetched, 101, 'every row survives the VM hop');
  assert.equal(out.totalTests, 94, 'same file+title across shards collapses');
  assert.equal(out.total, 4, '94 tests, 4 causes');
  assert.equal(out.groups[0].siblings.length, 85, 'one broken tenant explains 86 tests across many specs');
  assert.match(out.groups[0].error, /^Error: StudioCanvasPage/);
  assert.ok(out.groups[0].error.length <= 160, 'the VM truncates to what causeKey reads');
  // A trigger that still sends failures inline keeps working; the VM line wins when both exist.
  const inline = run('selectTests', { start: { output: { ...input } }, fetchFailures: { output: { Stdout: '' } } });
  assert.equal(inline.fetched, 0);
  assert.equal(inline.totalTests, 3);
}

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
  const out = run('selectTests', { start: { output: { ...input, environments: 'studio-*,vsix-*' } } });
  assert.equal(out.totalTests, 4, 'vsix rows dedupe across platforms into one');
  assert.equal(out.total, 3);
}
{
  // The fixtures all set `environments`, so the default was never exercised - and the default is
  // what the nightly actually runs with when the payload omits it.
  const { environments, ...noEnvironments } = input;
  const out = run('selectTests', { start: { output: noEnvironments } });
  assert.equal(out.totalTests, 4, 'the default includes vsix');
  assert.ok(out.groups.some((g) => g.environment.startsWith('vsix-')), 'a vsix group survives the default filter');
}
{
  const out = run('selectTests', { start: { output: { ...input, failedTests: [{ environment: 'studio-alpha', file: 'specs/a.spec.ts', title: 'has "quotes" and (parens) $1' }] } } });
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
  const costed = run('recordResult', { investigate: { currentItem: t }, pickTests: { output: pick },
    callVmAgent: { output: { reproduced: true, costUsd: 4.5 } } });
  assert.equal(costed.costUsd, 4.5);
  assert.equal(failed.costUsd, 0, 'a faulted run contributes nothing');
}
console.log('recordResult ok');

// summarize: total Claude spend is the sum over the runs
{
  const pick = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: { prs: [], ok: false } } });
  const row = (costUsd) => ({ environment: 'studio-alpha', file: 'specs/a.spec.ts', title: 'a test', siblings: [],
    reproduced: false, fixVerified: false, prUrl: '', hypothesis: '', failed: false, errorMessage: '', relatedPrs: [], costUsd });
  // Spend is its own follow-up message now, so the digest never carries it.
  const paid = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [row(4.25), row(2.5)] } });
  assert.doesNotMatch(paid.text, /Claude spend/);
  assert.match(paid.costText, /\$6\.75 Claude spend\* on 2 investigations/);
  // Zero still posts, saying so: silence left it unclear whether the run was free or the number lost.
  const free = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [row(0)] } });
  assert.doesNotMatch(free.text, /Claude spend/);
  assert.match(free.costText, /No Claude spend/);
  // Every exit path carries one, including the two early returns.
  const none = run('summarize', { start: { output: night2 }, pickTests: { output: { total: 0, skipped: 0, selected: [], covered: [], totalTests: 0 } }, investigate: { output: [] } });
  assert.match(none.costText, /No Claude spend/);
  const unread = run('summarize', { start: { output: { ...night2, failedCount: 101 } }, pickTests: { output: { total: 0, skipped: 0, selected: [], covered: [], totalTests: 0, fetched: 0 } }, investigate: { output: [] } });
  assert.match(unread.costText, /No Claude spend/);
}
console.log('spend ok');

// summarize: the cap names what it dropped, not just how many
{
  const pick = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: { prs: [], ok: false } } });
  assert.equal(pick.skipped, 2);
  assert.deepEqual(pick.skippedGroups.map((g) => g.title), pick.selected.length === 1
    ? sel2.groups.slice(1).map((g) => g.title) : []);
  const text = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [] } }).text;
  assert.match(text, /2 not investigated \(maxTests=1\): `[^`]+ \u203a [^`]+`(?: \(\+\d+\))?, `[^`]+ \u203a [^`]+`/);
  // A pickTests output from before this change still renders the bare count.
  const legacy = run('summarize', { start: { output: night2 }, pickTests: { output: { total: 3, totalTests: 6, skipped: 2, selected: [], covered: [] } }, investigate: { output: [] } }).text;
  assert.match(legacy, /_2 not investigated \(maxTests=1\)_/);
}
console.log('skipped naming ok');

// maxTests=0 selects nothing. A release smoke test sets it to prove fetch + grouping without
// spending a VmAgent run; 1.1.15 coerced 0 to 1 and investigated for real.
{
  const sel = run('selectTests', { start: { output: input } });
  const prsOut = { prs: [], ok: false };
  const dry = run('pickTests', { start: { output: { ...input, maxTests: 0 } }, selectTests: { output: sel }, parsePrs: { output: prsOut } });
  assert.equal(dry.selected.length, 0, 'nothing is investigated');
  assert.equal(dry.skipped, sel.total, 'every group is reported as skipped instead');
  // Absent still means one, which is what the nightly relies on.
  const { maxTests, ...noMax } = input;
  assert.equal(run('pickTests', { start: { output: noMax }, selectTests: { output: sel }, parsePrs: { output: prsOut } }).selected.length, 1);
}
console.log('maxTests=0 ok');

// The Slack gates: no slackTs, no post. 1.1.15 sent both messages to the channel root because
// thread_ts resolved to undefined, which Slack accepts as a top-level message.
{
  const gate = (id, slackTs) => {
    const n = flow.nodes.find((x) => x.id === id);
    assert.equal(n.type, 'core.logic.decision', `${id} is a decision`);
    return new Function('$vars', `return (${n.inputs.expression.expression});`)({ start: { output: { slackTs } } });
  };
  for (const id of ['hasSlackThreadStart', 'hasSlackThreadEnd']) {
    assert.equal(gate(id, '1789544198.781659'), true, `${id} posts when a thread exists`);
    assert.equal(gate(id, ''), false, `${id} stays silent without one`);
    assert.equal(gate(id, undefined), false, `${id} stays silent when the field is absent`);
  }
  // False must bypass the connector, not dead-end the flow.
  const to = (src, port) => flow.edges.filter((e) => e.sourceNodeId === src && e.sourcePort === port).map((e) => e.targetNodeId);
  assert.deepEqual(to('hasSlackThreadStart', 'false'), ['fetchFailures']);
  assert.deepEqual(to('hasSlackThreadStart', 'true'), ['ackInSlackThread']);
  assert.deepEqual(to('hasSlackThreadEnd', 'false'), ['end']);
  assert.deepEqual(to('hasSlackThreadEnd', 'true'), ['replyInSlackThread1']);
}
console.log('slack gates ok');

// summarize
{
  const pick = run('pickTests', { start: { output: night2 }, selectTests: { output: sel2 }, parsePrs: { output: prsOut } });
  // error and testCommand come from the group, carried through recordResult.
  const g0 = sel2.groups.find((g) => g.file === 'specs/data-transform/data-transform.spec.ts');
  const row = { environment: 'studio-alpha', file: 'specs/data-transform/data-transform.spec.ts', title: 'should add a Map operation with field mappings',
    reproduced: true, fixVerified: true, prUrl: 'https://github.com/UiPath/flow-workbench/pull/3729', hypothesis: 'neighbor rail intercepts click', failed: false, errorMessage: '',
    error: 'Error: a `.flow` entry never appeared', testCommand: g0.testCommand,
    siblings: ['should write a Custom Script operation in a Data Transform node'], relatedPrs: [{ number: 3758, title: 't', url: 'https://github.com/UiPath/flow-workbench/pull/3758', state: 'merged' }] };
  const text = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [{ recordResult: { output: row } }] } }).text;
  assert.match(text, /VmAgent investigated 1 of 3 studio failure groups\* \(6 tests, <https:\/\/github\.com\/UiPath\/flow-workbench\/actions\/runs\/34089391590\|run 34089391590>\) · <https:\/\/theater\.uipath\.co\/flow\/[0-9a-f]+\/\|report>/);
  // Siblings are a count, not a list: one cause used to print 86 test names.
  assert.match(text, /data-transform\.spec\.ts › should add a Map operation with field mappings` \+1 more in this spec — reproduced, fix verified, <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3729\|draft PR>, related merged <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3758\|PR #3758>/);
  assert.doesNotMatch(text, /should write a Custom Script operation in a Data Transform node/);
  // Cause and repro replace the names, and the repro path must be the one that exists on disk.
  assert.match(text, /\*repro\* `corepack pnpm exec playwright test --config e2e\/playwright\.config\.ts e2e\/specs\/data-transform\/data-transform\.spec\.ts --project studio-alpha/);
  // Backticks inside the error would close the code span early; they are swapped for quotes.
  assert.match(text, /\*cause\* `Error: a '\.flow' entry never appeared`/);
  assert.match(text, /should add a Group by operation with aggregations` \(\+2 same cause\) — likely already fixed by merged <https:\/\/github\.com\/UiPath\/flow-workbench\/pull\/3758\|PR #3758> \(touches `StudioProjectsPage\.ts`\)/);
  assert.match(text, /1 not investigated \(maxTests=1\)/);
  const flat = run('summarize', { start: { output: night2 }, pickTests: { output: pick }, investigate: { output: [row] } }).text;
  assert.match(flat, /should add a Map operation with field mappings/);
  const none = run('summarize', { start: { output: night2 }, pickTests: { output: { total: 0, skipped: 0, selected: [], covered: [], totalTests: 0 } }, investigate: { output: [] } }).text;
  assert.match(none, /no studio failures to investigate/);
}
console.log('summarize ok');
