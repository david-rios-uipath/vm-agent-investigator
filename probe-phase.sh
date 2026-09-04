#!/usr/bin/env bash
# Run ONE phase of the investigator on the VM without packing or deploying the flow.
#
#   ./probe-phase.sh repro       <runId> [test-command]
#   ./probe-phase.sh investigate <runId>
#   ./probe-phase.sh fix         <runId>
#   ./probe-phase.sh pr          <runId>
#
# Calls e2e-investigator/vm-exec-vm directly with the bootstrap PowerShell that the flow's
# bootstrap<Phase> node generates - rendered from VmAgent.flow with node, not a copy, so the
# probe cannot drift from what the flow runs. State is pulled from and pushed back to
# <runId>/state.zip in the e2e-investigations bucket, exactly as in a real run.
#
# Budget: repro ~10 min (or ~2 with smokeOnly=1), investigate ~10, fix ~25, pr ~3.
set -euo pipefail
PHASE="${1:?phase: repro | investigate | fix | pr}"
RUNID="${2:?runId, e.g. debug-execution-20260904-143456}"
CMD="${3:-$(python3 -c "import json;print(json.load(open('inputs/debug-execution.json'))['testCommand'])")}"
VMEXEC=CA36341D-ECEC-4BA6-AA76-134D0AFE4BA7   # e2e-investigator/vm-exec-vm
: "${RUNNER_REPO_URL:?export RUNNER_REPO_URL to the clone URL of this repo}"
RUNNER_REF="${RUNNER_REF:-main}"
SMOKE="${SMOKE_ONLY:-0}"
declare -A TIMEOUT=([repro]=15 [investigate]=20 [fix]=45 [pr]=10)
cd "$(dirname "$0")"

python3 - "$PHASE" "$RUNID" "$CMD" "$RUNNER_REPO_URL" "$RUNNER_REF" "$SMOKE" > /tmp/phase_probe.js <<'PY'
import json, sys
phase, runid, cmd, runner, ref, smoke = sys.argv[1:7]
node = 'bootstrap' + phase[0].upper() + phase[1:]
d = json.load(open('vm-agent/VmAgent/VmAgent.flow'))
expr = [n for n in d['nodes'] if n['id'] == node][0]['inputs']['script']['expression']
vars_ = {'deriveRunId': {'output': runid}, 'fixAttempts': 1,
         'start': {'output': {'testCommand': cmd, 'repoUrl': '', 'branch': '',
                              'runnerRepoUrl': runner, 'runnerRef': ref,
                              'smokeOnly': smoke == '1', 'maxFixAttempts': 3}}}
inp = json.load(open('inputs/debug-execution.json'))
vars_['start']['output']['repoUrl'] = inp['repoUrl']
vars_['start']['output']['branch'] = inp['branch']
print('const $vars = %s;' % json.dumps(vars_))
print('const script = (() => {%s})();' % expr)
print('process.stdout.write(JSON.stringify({Script: script, WorkDir: "C:\\\\vm-agent", RunId: %s, StateKey: %s, TimeoutMinutes: %s, MaxOutputChars: 32000}));'
      % (json.dumps(runid), json.dumps(runid + '/state.zip'), json.dumps(int(sys.argv[7]) if len(sys.argv) > 7 else 45)))
PY
node /tmp/phase_probe.js "${TIMEOUT[$PHASE]}" > /tmp/phase_probe.json

KEY=$(uip or jobs start "$VMEXEC" --folder-path "e2e-investigator" --input-arguments "$(cat /tmp/phase_probe.json)" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(d['Data']['Jobs'][0]['Key'])")
echo "probe job $KEY  phase=$PHASE runId=$RUNID"
while :; do
  ST=$(uip or jobs get "$KEY" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(d.get('Data',{}).get('State'))")
  case "$ST" in Running|Pending) sleep 20;; *) break;; esac
done
uip or jobs get "$KEY" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);x=d.get('Data',{})
print('state:',x.get('State'),'|',x.get('StartTime','')[11:19],'->',x.get('EndTime','')[11:19])
o=x.get('OutputArguments')
if o:
    s=json.loads(o)['Stdout']
    print(s[-4000:])
    line=[l for l in s.splitlines() if l.startswith('STATUS_JSON=')]
    print()
    print('STATUS:', json.dumps(json.loads(line[-1][len('STATUS_JSON='):]), indent=1)[:2000] if line else 'MISSING - the runner broke')"
