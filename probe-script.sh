#!/usr/bin/env bash
# Run one local PowerShell file on the robot VM through e2e-investigator/vm-exec-vm.
#
#   ./probe-script.sh vm/probes/vsix-desktop.ps1 [timeoutMinutes]
#
# No pack, no publish, no deploy, and - unlike probe-phase.sh - no push either: the script is
# sent inline, so what runs is your working tree. Prints the job's stdout and its STATUS_JSON.
set -euo pipefail
FILE="${1:?path to a .ps1}"
TIMEOUT="${2:-10}"
VMEXEC=CA36341D-ECEC-4BA6-AA76-134D0AFE4BA7   # e2e-investigator/vm-exec-vm
cd "$(dirname "$0")"

python3 - "$FILE" "$TIMEOUT" > /tmp/script_probe.json <<'PY'
import json, sys
script = open(sys.argv[1], encoding='utf-8').read()
print(json.dumps({'Script': script, 'WorkDir': 'C:\\vm-agent',
                  'TimeoutMinutes': int(sys.argv[2]), 'MaxOutputChars': 32000}))
PY

KEY=$(uip or jobs start "$VMEXEC" --folder-path "e2e-investigator" --input-arguments "$(cat /tmp/script_probe.json)" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(d['Data']['Jobs'][0]['Key'])")
echo "probe job $KEY  script=$FILE"
while :; do
  ST=$(uip or jobs get "$KEY" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(d.get('Data',{}).get('State'))")
  case "$ST" in Running|Pending) sleep 20;; *) break;; esac
done
uip or jobs get "$KEY" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);x=d.get('Data',{})
print('state:',x.get('State'),'|',x.get('StartTime','')[11:19],'->',x.get('EndTime','')[11:19])
if x.get('Info'): print('info:',x['Info'])
o=x.get('OutputArguments')
if o:
    s=json.loads(o).get('Stdout','')
    print(s[-8000:])
    line=[l for l in s.splitlines() if l.startswith('STATUS_JSON=')]
    print()
    print('STATUS:', json.dumps(json.loads(line[-1][len('STATUS_JSON='):]), indent=1) if line else 'MISSING - the script broke before its last line')"
