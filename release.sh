#!/usr/bin/env bash
# Pack, publish and redeploy the vm-agent solution into the fixed folder, then start a job.
#
#   ./release.sh 1.0.19 [job-input.json]
#
# Encodes the traps learned on 2026-09-03/04 (see FINDINGS-uip.md):
#   * the agent tool's bare `vm-exec-vm` binding is dropped from VmAgent.flow by the
#     pack/validate cycle -> re-add it before packing and ASSERT it is in the packaged
#     content/bindings_v2.json, or the agent's tool call 404s at runtime
#   * `uip solution pack` rewrites files in the source tree -> git checkout after packing
#   * `deploy uninstall` fails while any job in the folder is Running -> stop them first
#   * `deploy upgrade` and `processes update-version` do not work for this solution
set -euo pipefail
VERSION="${1:?version, e.g. 1.0.19}"
INPUT="${2:-/tmp/job-input.json}"
PKG="vm-agent 8"; DEPLOY="vm-agent 11"; FOLDER="Shared/vm-agent 11"; OUT=/tmp/vm-agent-pkg
cd "$(dirname "$0")"

python3 - <<'PY'
import json
p='vm-agent/VmAgent/VmAgent.flow'; d=json.load(open(p))
want=[
 {"id":"bVmExecToolName","name":"name","type":"string","resource":"process","resourceKey":"vm-exec-vm","default":"vm-exec-vm","propertyAttribute":"name","resourceSubType":"Process"},
 {"id":"bVmExecToolFolderPath","name":"folderPath","type":"string","resource":"process","resourceKey":"vm-exec-vm","default":"e2e-investigator","propertyAttribute":"folderPath","resourceSubType":"Process"}]
added=0
for b in want:
    if not any(x['resourceKey']==b['resourceKey'] and x['name']==b['name'] for x in d['bindings']): d['bindings'].append(b); added+=1
if added: open(p,'w').write(json.dumps(d,indent=2,ensure_ascii=False))
print(f're-added {added} agent tool binding(s)')
PY
if ! git diff --quiet -- vm-agent/VmAgent/VmAgent.flow; then
  git add vm-agent/VmAgent/VmAgent.flow && git commit -q -m "Re-add bare vm-exec-vm tool binding before release $VERSION"
fi

mkdir -p "$OUT"
uip solution pack vm-agent "$OUT" -n "$PKG" -v "$VERSION" --repository-commit "$(git rev-parse HEAD)" >/dev/null
git checkout -- vm-agent/   # pack rewrites source files; discard
ZIP="$OUT/${PKG}_${VERSION}.zip"
python3 - "$ZIP" <<'PY'
import sys,zipfile,io,json
z=zipfile.ZipFile(sys.argv[1]); p=[x for x in z.namelist() if 'flow.VmAgent' in x and x.endswith('.nupkg')][0]
keys=[r.get('key') for r in json.loads(zipfile.ZipFile(io.BytesIO(z.read(p))).read('content/bindings_v2.json'))['resources']]
print('packaged bindings_v2:',keys)
assert 'vm-exec-vm' in keys, 'agent tool binding missing from package - not publishing'
ag=json.loads(zipfile.ZipFile(io.BytesIO(z.read(p))).read('content/e41af830-1e4b-4d6b-a7e0-5595f152ea88/agent.json'))
tools=[r.get('name') for r in (ag.get('resources') or [])]
print('packaged investigator tools:',tools)
assert 'vm_exec' in tools, 'investigator has no vm_exec tool in package (tool resource.json missing?) - not publishing'
PY
uip solution publish "$ZIP" --output json | grep '"PackageVersion"'

# stop anything running in the folder, then replace the deployment in place
for k in $(uip or jobs list --folder-path "$FOLDER" --output json 2>/dev/null | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:])
print(' '.join(x['Key'] for x in d['Data'] if x.get('State') in ('Running','Pending','Suspended')))"); do
  uip or jobs stop "$k" >/dev/null 2>&1 || true
done
n=0; until [ $n -ge 18 ] || [ "$(uip or jobs list --folder-path "$FOLDER" --output json 2>/dev/null | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);print(len([x for x in d['Data'] if x.get('State') in ('Running','Stopping','Pending','Suspended')]))")" = "0" ]; do sleep 10; n=$((n+1)); done
uip solution deploy uninstall "$DEPLOY" --yes --output json | grep -E '"Status"|"Message"' | head -1 || true
uip solution deploy run -n "$DEPLOY" --package-name "$PKG" --package-version "$VERSION" --folder-name "${DEPLOY}" \
  --parent-folder-path "Shared" --config-file deploy-config.json --timeout 600 --output json | grep -E '"Status"|"Message"' | head -2

KEY=$(uip or processes list --folder-path "$FOLDER" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:]);items=d['Data'] if isinstance(d['Data'],list) else d['Data']['Processes']
print(next(x['Key'] for x in items if x['Name']=='VmAgent'))")
uip or jobs start "$KEY" --folder-path "$FOLDER" --input-arguments "$(cat "$INPUT")" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:])
for j in d['Data']['Jobs']: print('JOB',j['Key'],j['State'],j['CreationTime'])"
