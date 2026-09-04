#!/usr/bin/env bash
# Validate the fix/verify step in ~10 minutes without deploying or running the flow.
#
#   ./probe-verify.sh <runId-folder-on-vm> [test-command]
#   ./probe-verify.sh debug-execution-20260904-143456
#
# Calls vm-exec-vm directly in e2e-investigator with the PowerShell the flow's
# verifyFixInstructions node generates - rendered from VmAgent.flow, not a copy, so the
# probe cannot drift from what the flow actually runs. Requires a fix.patch already
# written on the VM by a previous fixer run.
#
# Verify now boots `pnpm run dev:studio` and runs the spec under --project studio-local,
# so a product-source patch is genuinely exercised; budget ~10 min, not ~5.
set -euo pipefail
RUNID="${1:?runId folder under C:\\vm-agent\\notes, e.g. debug-execution-20260904-143456}"
CMD="${2:-$(python3 -c "import json;print(json.load(open('inputs/debug-execution.json'))['testCommand'])")}"
VMEXEC=CA36341D-ECEC-4BA6-AA76-134D0AFE4BA7   # e2e-investigator/vm-exec-vm
cd "$(dirname "$0")"

# Render the node's script expression exactly as the flow engine would.
python3 - "$RUNID" "$CMD" > /tmp/verify_probe.js <<'PY'
import json,sys
runid,cmd=sys.argv[1],sys.argv[2]
d=json.load(open('vm-agent/VmAgent/VmAgent.flow'))
expr=[n for n in d['nodes'] if n['id']=='verifyFixInstructions'][0]['inputs']['script']['expression']
print('const $vars = %s;' % json.dumps({'deriveRunId':{'output':runid},'start':{'output':{'testCommand':cmd}}}))
print('const script = (() => {%s})();' % expr)
print('process.stdout.write(JSON.stringify({Script:script,WorkDir:"C:\\\\vm-agent",RunId:"verify-probe",TimeoutMinutes:30,MaxOutputChars:16000}));')
PY
node /tmp/verify_probe.js > /tmp/verify_probe.json

KEY=$(uip or jobs start "$VMEXEC" --folder-path "e2e-investigator" --input-arguments "$(cat /tmp/verify_probe.json)" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(d['Data']['Jobs'][0]['Key'])")
echo "probe job $KEY (usually 8-12 min: rsbuild dev boot + the spec)"
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
    s=json.loads(o)['Stdout']; j=s.rfind('### patch first bytes')
    print(s[j:] if j>=0 else s[-3000:])"
