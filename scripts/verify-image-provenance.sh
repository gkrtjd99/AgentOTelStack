#!/bin/sh
# Validate image provenance policy from the resolved Compose model.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/.." && pwd)
compose=${1:-docker-compose.yml}
case "$compose" in /*) compose_abs=$compose ;; *) compose_abs=$root/$compose ;; esac
compose_abs=$(CDPATH=; cd -- "$(dirname "$compose_abs")" && pwd)/$(basename "$compose_abs")
compose_dir=$(dirname "$compose_abs")
cd "$compose_dir"

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
AGENTOTEL_STACK_UUID=${AGENTOTEL_STACK_UUID:-00000000-0000-4000-8000-000000000001} \
GATEWAY_INGEST_TOKEN=${GATEWAY_INGEST_TOKEN:-ci-ingest-token} \
GATEWAY_QUERY_TOKEN=${GATEWAY_QUERY_TOKEN:-ci-query-token} \
GF_SECURITY_ADMIN_PASSWORD=${GF_SECURITY_ADMIN_PASSWORD:-ci-grafana-password} \
docker compose -f "$compose_abs" --profile demo --profile dashboard config --format json >"$tmp"

python3 - "$tmp" "$compose_dir" <<'PY'
import json, pathlib, re, sys
model=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2]); errors=[]
digest=re.compile(r'@sha256:[0-9a-f]{64}$', re.I)
from_re=re.compile(r'^\s*FROM\s+(\S+)(?:\s+AS\s+(\S+))?\s*$', re.I)
for name, svc in model.get('services', {}).items():
    image=svc.get('image'); build=svc.get('build')
    if not build and (not image or not digest.search(image)):
        errors.append(f'{name}: external image must use a full @sha256 digest ({image or "missing image"})')
    if not build:
        continue
    if isinstance(build,str): context=build; dockerfile='Dockerfile'
    else: context=build.get('context','.'); dockerfile=build.get('dockerfile','Dockerfile')
    df=(root / context / dockerfile).resolve()
    if not df.is_file(): errors.append(f'{name}: missing Dockerfile {df}'); continue
    stages=set()
    for n,line in enumerate(df.read_text().splitlines(),1):
        m=from_re.match(line)
        if not m: continue
        base, stage=m.group(1), m.group(2)
        if base.lower() in stages: pass
        elif not digest.search(base): errors.append(f'{name}: {df}:{n}: FROM must use full @sha256 digest ({base})')
        if stage: stages.add(stage.lower())
    args=build.get('args',{}) if isinstance(build,dict) else {}
    if args: errors.append(f'{name}: mutable build args are not permitted')
if errors:
    print('IMAGE PROVENANCE: FAIL', file=sys.stderr)
    print('\n'.join(' - '+e for e in errors), file=sys.stderr); sys.exit(1)
print(f'IMAGE PROVENANCE: PASS ({len(model.get("services",{}))} services)')
PY
