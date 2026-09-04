#!/usr/bin/env bash
# Pack, publish and redeploy the vm-agent solution into the fixed folder, then start a job.
#
#   ./release.sh 1.0.19 [job-input.json]
#
# Encodes the traps learned on 2026-09-03/04 (see FINDINGS-uip.md):
#   * `uip solution pack` rewrites files in the source tree -> git checkout after packing
#   * the packaged bindings_v2.json must still carry e2e-investigator.vm-exec-vm, or every
#     phase job fails to start; assert it before publishing
#   * `deploy uninstall` fails while any job in the folder is Running -> stop them first
#   * `deploy upgrade` and `processes update-version` do not work for this solution
set -euo pipefail
VERSION="${1:?version, e.g. 1.0.19}"
INPUT="${2:-/tmp/job-input.json}"
PKG="vm-agent 8"; DEPLOY="vm-agent 11"; FOLDER="Shared/vm-agent 11"; OUT=/tmp/vm-agent-pkg
cd "$(dirname "$0")"

mkdir -p "$OUT"
ZIP="$OUT/${PKG}_${VERSION}.zip"
rm -f "$ZIP"
uip solution pack vm-agent "$OUT" -n "$PKG" -v "$VERSION" --repository-commit "$(git rev-parse HEAD)" >/dev/null
git checkout -- vm-agent/   # pack rewrites source files; discard
python3 - "$ZIP" <<'PY'
import sys, zipfile, io, json
z = zipfile.ZipFile(sys.argv[1])
p = [x for x in z.namelist() if 'flow.VmAgent' in x and x.endswith('.nupkg')][0]
inner = zipfile.ZipFile(io.BytesIO(z.read(p)))
keys = [r.get('key') for r in json.loads(inner.read('content/bindings_v2.json'))['resources']]
print('packaged bindings_v2:', keys)
assert 'e2e-investigator.vm-exec-vm' in keys, 'RPA node binding missing from package - not publishing'
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
