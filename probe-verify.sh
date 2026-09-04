#!/usr/bin/env bash
# Validate the fix/verify mechanism in ~5 minutes without deploying or running the flow.
#
#   ./probe-verify.sh <runId-folder-on-vm> [test-command]
#   ./probe-verify.sh debug-execution-20260904-143456
#
# Calls vm-exec-vm directly in e2e-investigator with the same PowerShell the flow's
# verifyFixInstructions generates: normalise the patch, git apply, run the real Playwright
# test, revert. Prints '### patch first bytes', the apply result and the test tail.
# Requires a fix.patch already written on the VM by a previous fixer run.
set -euo pipefail
RUNID="${1:?runId folder under C:\\vm-agent\\notes, e.g. debug-execution-20260904-143456}"
CMD="${2:-$(python3 -c "import json;print(json.load(open('inputs/debug-execution.json'))['testCommand'])")}"
VMEXEC=CA36341D-ECEC-4BA6-AA76-134D0AFE4BA7   # e2e-investigator/vm-exec-vm
cd "$(dirname "$0")"

python3 - "$RUNID" "$CMD" > /tmp/verify_probe.json <<'PY'
import json,sys
runid,cmd=sys.argv[1],sys.argv[2]
script = r'''$ErrorActionPreference = 'Continue'
$repo = 'C:\vm-agent\repo'
$bin  = 'C:\vm-agent\bin'
$env:PATH = "$bin;$env:PATH"
$patch = 'C:\vm-agent\notes\__RUNID__\fix.patch'
Set-Location $repo
if (-not (Test-Path $patch)) { Write-Output 'PROBE_RESULT=no_patch'; exit 0 }
$bytes = [System.IO.File]::ReadAllBytes($patch)
Write-Output ('### patch first bytes: ' + ((($bytes | Select-Object -First 8) | ForEach-Object { $_.ToString('x2') }) -join ' '))
$isUtf16 = $bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))
if ($isUtf16) { Write-Output '### re-encoding UTF-16 -> UTF-8'; $text = [System.IO.File]::ReadAllText($patch) }
else { $text = [System.Text.Encoding]::UTF8.GetString($bytes) }
$lf = [string][char]10
$text = $text.TrimStart([char]0xFEFF).Replace([string][char]13 + $lf, $lf)
if (-not $text.EndsWith($lf)) { $text = $text + $lf }
[System.IO.File]::WriteAllText($patch, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output '### git apply --check'
git apply --check $patch 2>&1 | ForEach-Object { Write-Output "$_" }
if ($LASTEXITCODE -ne 0) { Write-Output 'PROBE_RESULT=apply_failed'; exit 0 }
git apply $patch 2>&1 | ForEach-Object { Write-Output "$_" }
git diff --stat 2>&1 | ForEach-Object { Write-Output "$_" }
$cmd = '__CMD__ --retries=0 --reporter=line'
Write-Output "### test $cmd"
cmd.exe /c "set PATH=$bin;%PATH% && set CI=true && $cmd"
$exit = $LASTEXITCODE
Write-Output "### test exit $exit"
git checkout -- . 2>&1 | Out-Null
git clean -fd -- e2e 2>&1 | Out-Null
Write-Output "PROBE_RESULT=$(if ($exit -eq 0) {'FIX_WORKS'} else {'test_failed'})"
'''.replace('__RUNID__',runid).replace('__CMD__',cmd)
print(json.dumps({"Script":script,"WorkDir":"C:\\vm-agent","RunId":"verify-probe","TimeoutMinutes":15,"MaxOutputChars":16000}))
PY

KEY=$(uip or jobs start "$VMEXEC" --folder-path "e2e-investigator" --input-arguments "$(cat /tmp/verify_probe.json)" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(d['Data']['Jobs'][0]['Key'])")
echo "probe job $KEY (usually 3-6 min)"
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
