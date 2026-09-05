#!/usr/bin/env bash
# Publish the vm-exec process package and point e2e-investigator/vm-exec-vm at it.
#
#   ./release-vm-exec.sh 1.0.4
#
# vm-exec does NOT go through release.sh. release.sh packs the *solution* (the VmAgent flow
# plus an in-solution copy of vm-exec that nothing calls); the process the flow's phase nodes
# actually invoke is `vm-exec-vm` in the standard folder `e2e-investigator`, bound to the
# tenant-feed package `vm-exec`. Editing Main.xaml reaches the VM only through this script.
#
# PACK WITH THE PINNED TOOLCHAIN. Robot 25.10 on this pool runs .NET 8; the current uip CLI
# (1.201) packs net10.0 and the job dies at install with
#   NU1202: Package vm-exec X is not compatible with net8.0 ... supports: net10.0
# in about four seconds. 1.0.4 shipped that way. CLI 1.197 + a local .NET 8 SDK emit a genuine
# net8.0 package; both are bootstrapped below if missing.
set -euo pipefail
VERSION="${1:?version, e.g. 1.0.5}"
FOLDER="e2e-investigator"; PROC="vm-exec-vm"; OUT=/tmp/vm-exec-pkg
CLI_DIR=/tmp/uipcli197; CLI_VER=1.197.0-dev.7683; DOTNET8="$HOME/.dotnet8"
cd "$(dirname "$0")"

if [ ! -x "$CLI_DIR/node_modules/.bin/uip" ]; then
  echo "bootstrapping uip CLI $CLI_VER into $CLI_DIR"
  mkdir -p "$CLI_DIR" && (cd "$CLI_DIR" && npm i --silent "@uipath/cli@$CLI_VER")
fi
if [ ! -x "$DOTNET8/dotnet" ]; then
  echo "no .NET 8 SDK at $DOTNET8 - install it first:"
  echo "  curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 --install-dir $DOTNET8"
  exit 1
fi

python3 - "$VERSION" <<'PY'
import json, sys
p = 'vm-agent/vm-exec/project.json'
d = json.load(open(p))
d['projectVersion'] = sys.argv[1]
open(p, 'w').write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
print('project.json projectVersion ->', sys.argv[1])
PY

rm -rf "$OUT" && mkdir -p "$OUT"
DOTNET_ROOT="$DOTNET8" PATH="$DOTNET8:$PATH" \
  "$CLI_DIR/node_modules/.bin/uip" rpa pack vm-agent/vm-exec "$OUT" --package-version "$VERSION" --output json \
  | grep -E '"Result"|"PackagePath"' | head -2

# Refuse to publish anything the robot cannot install.
python3 - "$OUT/vm-exec.$VERSION.nupkg" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
libs = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
print('packaged lib target(s):', libs)
assert libs == ['net8.0'], f'robot 25.10 runs .NET 8; this package targets {libs} - not publishing'
PY
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
