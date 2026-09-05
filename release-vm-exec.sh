#!/usr/bin/env bash
# Publish the vm-exec process package and point e2e-investigator/vm-exec-vm at it.
#
#   ./release-vm-exec.sh 1.0.4
#
# vm-exec does NOT go through release.sh. release.sh packs the *solution* (the VmAgent flow
# plus an in-solution copy of vm-exec that nothing calls); the process the flow's phase nodes
# actually invoke is `vm-exec-vm` in the standard folder `e2e-investigator`, bound to the
# tenant-feed package `vm-exec`. Editing Main.xaml reaches the VM only through this script.
set -euo pipefail
VERSION="${1:?version, e.g. 1.0.4}"
FOLDER="e2e-investigator"; PROC="vm-exec-vm"; OUT=/tmp/vm-exec-pkg
cd "$(dirname "$0")"

python3 - "$VERSION" <<'PY'
import json, sys
p = 'vm-agent/vm-exec/project.json'
d = json.load(open(p))
d['projectVersion'] = sys.argv[1]
open(p, 'w').write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
print('project.json projectVersion ->', sys.argv[1])
PY

mkdir -p "$OUT"
uip rpa pack vm-agent/vm-exec "$OUT" --package-version "$VERSION" --output json | grep -E '"Result"|"Message"' | head -2
uip rpa publish "$OUT/vm-exec.$VERSION.nupkg" --output json | grep -E '"Result"|"Message"|"Version"' | head -3

KEY=$(uip or processes list --folder-path "$FOLDER" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:])
items=d['Data'] if isinstance(d['Data'],list) else d['Data']['Processes']
print(next(x['Key'] for x in items if x['Name']=='$PROC'))")
uip or processes update-version "$KEY" --package-version "$VERSION" --folder-path "$FOLDER" --output json | grep -E '"Result"|"ProcessVersion"|"Message"' | head -3

uip or processes list --folder-path "$FOLDER" --output json | python3 -c "
import sys,json;t=sys.stdin.read();i=t.find('{');d=json.loads(t[i:])
items=d['Data'] if isinstance(d['Data'],list) else d['Data']['Processes']
for x in items:
    if x['Name']=='$PROC': print('now:', x['Name'], x.get('ProcessVersion'))"
