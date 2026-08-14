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
from_re=re.compile(r'^\s*FROM(?:\s+--platform=(\S+))?\s+(\S+)(?:\s+AS\s+(\S+))?\s*$', re.I)

# The dashboard image is deliberately a source-built repack.  Keep these
# values here (rather than trusting a mutable image tag) so a review-visible
# change to any provenance boundary fails the release gate.
grafana_provenance = {
    'org.opencontainers.image.source': 'https://github.com/grafana/grafana',
    'org.opencontainers.image.version': '13.1.3',
    'org.opencontainers.image.revision': '45a27d64b64a82d666b06aa5c5bb3521587edb0d',
    'org.opencontainers.image.base.name': 'grafana/grafana',
    'org.opencontainers.image.base.digest': 'sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43',
}
grafana_source_commit = grafana_provenance['org.opencontainers.image.revision']
grafana_source_sha256 = 'ef2a9c6da7d6c3ffcd910d5aeb1d00f32f9a36ea49035145ae5bbf902f39567d'
go_image = 'golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df'
tempo_commit = '4aeafc237b8d9a8d62e45735131e8a89eb741a00'
tempo_source_sha256 = '6159f130af77216215137a1033e3f573cc83e7aba69a19d618b521b7ab41d81f'
victorialogs_commit = 'bb1f6d7b0ec2bdf943c2d8c27f2cb17004b147e8'
victorialogs_source_sha256 = 'e748a9aa2f737952b7f02b0e69b671d1608c7ef765413cf1476a247e681a0245'
victorialogs_assets_sha256 = '6b6d7b27354ad972946318aac2a54f04363375e7cd5d1cad9d3bb74d00eb970b'


def require(text, pattern, description, flags=re.M):
    if not re.search(pattern, text, flags):
        errors.append(f'grafana: Dockerfile is missing {description}')


def validate_grafana(df, text):
    # OCI labels are the identity exposed by the resulting local image.  The
    # Dockerfile must carry the upstream source identity, not the local image
    # name from Compose.
    for key, expected in grafana_provenance.items():
        actual = re.search(
            rf'(?m)(?:^|\s){re.escape(key)}\s*=\s*"([^"]+)"', text
        )
        if not actual:
            errors.append(f'grafana: {df}: missing OCI label {key}')
        elif actual.group(1) != expected:
            errors.append(
                f'grafana: {df}: OCI label {key}={actual.group(1)!r}, '
                f'expected {expected!r}'
            )

    require(
        text,
        rf'^FROM grafana/grafana@sha256:{re.escape(grafana_provenance["org.opencontainers.image.base.digest"][7:])} AS grafana-assets\s*$',
        'the pinned Grafana 13.1.3 asset image',
    )
    require(
        text,
        rf'^ADD https://github\.com/grafana/grafana/archive/{grafana_source_commit}\.tar\.gz\s+\S+',
        f'Grafana source archive at commit {grafana_source_commit}',
    )
    require(text, re.escape(grafana_source_sha256), 'the Grafana source archive checksum', re.M)

    expected_add_urls = {
        f'https://github.com/grafana/grafana/archive/{grafana_source_commit}.tar.gz',
        f'https://github.com/grafana/tempo/archive/{tempo_commit}.tar.gz',
        f'https://github.com/VictoriaMetrics/victorialogs-datasource/archive/{victorialogs_commit}.tar.gz',
        'https://github.com/VictoriaMetrics/victorialogs-datasource/releases/download/v0.31.0/victoriametrics-logs-datasource-v0.31.0.tar.gz',
    }
    actual_add_urls = set(re.findall(r'^ADD\s+(https?://\S+)\s+', text, re.M))
    if actual_add_urls != expected_add_urls:
        errors.append(
            f'grafana: {df}: external sources must be exactly the four pinned '
            f'Grafana/Tempo/VictoriaLogs URLs (extra={sorted(actual_add_urls - expected_add_urls)}, '
            f'missing={sorted(expected_add_urls - actual_add_urls)})'
        )

    # Both Go builders use the same pinned compiler; no floating toolchain may
    # enter either the Grafana server or VictoriaLogs backend.
    if len(re.findall(rf'^FROM --platform=\$BUILDPLATFORM {re.escape(go_image)} AS ', text, re.M)) != 2:
        errors.append(f'grafana: {df}: both source builders must use pinned Go 1.26.6')
    require(text, r'\bgo mod verify\b', 'Go module verification', re.M)

    require(
        text,
        rf'^ADD https://github\.com/grafana/tempo/archive/{tempo_commit}\.tar\.gz\s+\S+',
        f'Tempo v2.10.3 source at commit {tempo_commit}',
    )
    require(text, re.escape(tempo_source_sha256), 'the Tempo source archive checksum', re.M)
    require(text, r'github\.com/grafana/tempo/v2 v2\.10\.3', 'the semver-correct Tempo v2.10.3 module', re.M)

    require(
        text,
        rf'^ADD https://github\.com/VictoriaMetrics/victorialogs-datasource/archive/{victorialogs_commit}\.tar\.gz\s+\S+',
        f'VictoriaLogs datasource source at commit {victorialogs_commit}',
    )
    require(text, re.escape(victorialogs_source_sha256), 'the VictoriaLogs source archive checksum', re.M)
    require(
        text,
        r'^ADD https://github\.com/VictoriaMetrics/victorialogs-datasource/releases/download/v0\.31\.0/victoriametrics-logs-datasource-v0\.31\.0\.tar\.gz\s+\S+',
        'the VictoriaLogs v0.31.0 frontend asset archive',
    )
    require(text, re.escape(victorialogs_assets_sha256), 'the VictoriaLogs frontend checksum', re.M)

    # The release archive supplies only frontend/static files.  The Linux
    # backend in the final image must come from the reviewed source build.
    require(text, r'\bgo build\b', 'a source-built VictoriaLogs backend', re.M)
    require(text, r'\./pkg\b', 'the VictoriaLogs backend package build', re.M)
    require(
        text,
        r'^COPY --from=victorialogs-builder /out/victoriametrics_logs_backend_plugin\s+',
        'the source-built VictoriaLogs backend in the final image',
    )
    require(
        text,
        r'^COPY --from=victorialogs-assets /out/victoriametrics-logs-datasource\s+',
        'the verified VictoriaLogs frontend assets in the final image',
    )

    # Never copy the upstream server binary, data/plugins-bundled, or the
    # upstream plugin directory into the runtime.  Comments may mention these
    # forbidden paths as rationale, so inspect COPY instructions only.
    for n, line in enumerate(text.splitlines(), 1):
        instruction = re.match(r'^\s*(RUN|COPY|ADD)\b', line, re.I)
        if instruction and re.search(r'plugins-bundled|/data/plugins-bundled', line, re.I):
            errors.append(f'grafana: {df}:{n}: forbidden bundled Grafana runtime asset copy')
        if not re.match(r'^\s*COPY\s+--from=grafana-assets\b', line, re.I):
            continue
        if re.search(r'(/bin(?:\s|$)|/data(?:\s|$)|plugins-bundled)', line, re.I):
            errors.append(f'grafana: {df}:{n}: forbidden bundled Grafana runtime asset copy')
    for n, line in enumerate(text.splitlines(), 1):
        if re.match(r'^\s*COPY\b', line, re.I) and '/opt/grafana-plugins/' in line \
                and '/opt/grafana-plugins/victoriametrics-logs-datasource' not in line:
            errors.append(f'grafana: {df}:{n}: plugin outside the supported VictoriaLogs scope')
    if re.search(r'^\s*COPY\s+--from=grafana-assets\s+/usr/share/grafana\s+', text, re.M):
        errors.append(f'grafana: {df}: broad Grafana asset copy may include bundled plugins')

    require(text, r'GF_PATHS_PLUGINS="/opt/grafana-plugins"', 'the isolated plugin directory', re.M)
    require(text, r'GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS="victoriametrics-logs-datasource"', 'the supported plugin allowlist', re.M)
    require(text, r'allow_loading_unsigned_plugins = victoriametrics-logs-datasource', 'the config plugin allowlist', re.M)
    # There is exactly one supported plugin.  Reject plugin installs/catalog
    # fetches and any second plugin directory in the build instructions.
    if re.search(r'(?i)(grafana-cli\s+plugins\s+install|grafana-cli\s+plugins\s+update|plugin_catalog_url\s*=\s*https?://)', text):
        errors.append(f'grafana: {df}: forbidden bundled or runtime-installed plugin path')

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
        platform, base, stage=m.group(1), m.group(2), m.group(3)
        if base.lower() in stages: pass
        elif not digest.search(base): errors.append(f'{name}: {df}:{n}: FROM must use full @sha256 digest ({base})')
        if stage: stages.add(stage.lower())
    args=build.get('args',{}) if isinstance(build,dict) else {}
    if args: errors.append(f'{name}: mutable build args are not permitted')
    if name == 'grafana':
        validate_grafana(df, df.read_text())

# Health probes are compiled in a BuildKit stage and copied into multi-arch
# Victoria/OTel images.  Requiring the automatic target arguments here catches
# the common regression where a hard-coded amd64 probe is silently copied into
# an arm64 image.  The fallback to the builder's native Go target keeps plain
# `docker build` usable while BuildKit supplies TARGETOS/TARGETARCH in CI.
health_dir = root / 'src/backend-health'
for df in sorted(health_dir.glob('Dockerfile.*')):
    text = df.read_text()
    if not re.search(r'^ARG\s+TARGETOS\s*$', text, re.M) or not re.search(r'^ARG\s+TARGETARCH\s*$', text, re.M):
        errors.append(f'{df}: health build must declare BuildKit TARGETOS and TARGETARCH')
    if not re.search(r'^FROM\s+--platform=\$BUILDPLATFORM\s+\S+\s+AS\s+build\s*$', text, re.M):
        errors.append(f'{df}: health builder must use native BuildKit $BUILDPLATFORM')
    if re.search(r'GOARCH\s*=\s*amd64\b', text):
        errors.append(f'{df}: health build must not hard-code GOARCH=amd64')
    if not re.search(r'GOOS="\$\{TARGETOS:-\$\(go env GOOS\)\}"', text) or not re.search(r'GOARCH="\$\{TARGETARCH:-\$\(go env GOARCH\)\}"', text):
        errors.append(f'{df}: health build must compile for TARGETOS/TARGETARCH')
if errors:
    print('IMAGE PROVENANCE: FAIL', file=sys.stderr)
    print('\n'.join(' - '+e for e in errors), file=sys.stderr); sys.exit(1)
print(f'IMAGE PROVENANCE: PASS ({len(model.get("services",{}))} services)')
PY
