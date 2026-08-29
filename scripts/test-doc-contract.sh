#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail(){ echo "doc-contract: $*" >&2; exit 1; }

grep -Fq "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20\${GATEWAY_INGEST_TOKEN}" .env.example \
  || fail '.env.example must show the Gateway bearer header'
! grep -Fq 'http://otel-collector:4318' .env.example \
  || fail '.env.example must not direct apps to the collector'
grep -Fq 'authenticated OTLP/HTTP' AGENTS.md \
  || fail 'AGENTS.md must describe the Gateway write path'
! grep -Fq 'it emitting OTLP to the collector' AGENTS.md \
  || fail 'AGENTS.md contains a stale direct-collector claim'
grep -Fq 'authenticated Gateway' README.md \
  || fail 'README.md must identify the authenticated Gateway'
! grep -Fq '앱은 컬렉터로 텔레메트리를 쓰고' README.md \
  || fail 'README.md contains a stale Korean direct-collector claim'
grep -Fq 'callers cannot provide an arbitrary project' docs/CONNECT.md \
  || fail 'CONNECT.md must document workspace project scope'
grep -Fq 'workspace provenance and query selection' docs/SECURITY.md \
  || fail 'SECURITY.md must document workspace project scope'
grep -Fq 'not accept an arbitrary project' docs/AGENT_SETUP.md \
  || fail 'AGENT_SETUP.md must document fixed MCP project scope'

# Installed operational lifecycle commands must come from the global launcher.
# Keep checkout-only Makefile aliases out of operator-facing setup/lifecycle
# guidance; development instructions should use explicit dev targets or the
# AGENTOTEL_DEV_MODE wrapper instead.
for doc in README.md AGENTS.md docs/AGENT_SETUP.md docs/CONNECT.md; do
  ! grep -Eq 'make (setup|up|down|clean|doctor|storage|migrate|reset|smoke|ps)([[:space:]]|$)' "$doc" \
    || fail "$doc contains stale operational make lifecycle guidance"
  ! grep -Eq '^[[:space:]]*\./bin/obs (setup|up|down|doctor)([[:space:]]|$)' "$doc" \
    || fail "$doc uses checkout launcher for installed lifecycle"
done

# Checkout helper examples must opt into the checkout dispatcher explicitly;
# a bare ./bin/obs can resolve only an installed runtime or fail outside dev mode.
for doc in AGENTS.md README.md docs/QUERY.md docs/CONNECT.md docs/ko/QUERY.md docs/ko/CONNECT.md; do
  ! grep -Eq '(^|[[:space:]`])\\./bin/obs credentials run' "$doc" \
    || fail "$doc uses an unqualified checkout helper launcher"
done

grep -Fq 'obs setup' README.md || fail 'README.md must show global obs setup'
grep -Fq 'obs up' README.md || fail 'README.md must show global obs up'
grep -Fq 'obs down' README.md || fail 'README.md must show global obs down'
grep -Fq 'obs doctor' README.md || fail 'README.md must show global obs doctor'
grep -Fq 'obs setup' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs setup'
grep -Fq 'obs up' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs up'
grep -Fq 'obs doctor' docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must show global obs doctor'
grep -Fq 'obs down' docs/OPERATIONS.md || fail 'OPERATIONS.md must show global obs down'

# Browser lifecycle is intentionally Make-only. Keep the supported entry points
# visible and make a direct npm journey an explicit rejection rather than a
# runnable recipe.
for doc in AGENTS.md docs/DASHBOARD.md docs/DEVELOPMENT.md; do
  grep -Fq 'make e2e' "$doc" || fail "$doc must document make e2e"
  grep -Fq 'make e2e-app' "$doc" || fail "$doc must document make e2e-app"
  grep -Fq 'make e2e-dashboard' "$doc" || fail "$doc must document make e2e-dashboard"
  if grep -Fq 'cd e2e && npm test' "$doc"; then
    grep -Eqi 'unsupported|reject' "$doc" || fail "$doc mentions direct e2e npm without rejecting it"
  fi
done
grep -Fq 'make dashboard-down' README.md || fail 'README.md must document dashboard-down lifecycle'
grep -Fq 'make dashboard-down' docs/DASHBOARD.md || fail 'DASHBOARD.md must document dashboard-down lifecycle'
grep -Fq 'stable checkout-owned lifecycle is Make-only' docs/DASHBOARD.md || fail 'DASHBOARD.md must document the stable dashboard project'
! grep -Fq 'npm install' Makefile || fail 'Makefile E2E lifecycle must not use npm install'
grep -Fq 'npm ci --ignore-scripts --no-audit' scripts/run-browser-e2e.sh || fail 'E2E helper must use lock-preserving npm ci'
grep -Fq "node \"\$playwright_cli\"" scripts/run-browser-e2e.sh || fail 'E2E helper must invoke the installed Playwright CLI directly'

# Task #32 dashboard architecture contract. These checks deliberately look for
# security-relevant wording rather than merely a port number: the sole active UI,
# network boundary, image hardening, migration semantics, and lifecycle must all
# remain documented when the module is split into another repository.
grep -Fq 'The Go Dashboard is' AGENTS.md || fail 'AGENTS.md must name the sole Go dashboard UI'
if ! grep -Fq 'dedicated ' AGENTS.md || ! grep -Fq 'network shared with Gateway' AGENTS.md; then
  fail 'AGENTS.md must document the dashboard-Gateway network'
fi
grep -Fq 'standalone default of loopback' AGENTS.md || fail 'AGENTS.md must document the standalone loopback default'
grep -Fq 'non-root numeric user in a scratch image' docs/DASHBOARD.md || fail 'DASHBOARD.md must document the hardened scratch image'
grep -Fq 'CA bundle' docs/DASHBOARD.md || fail 'DASHBOARD.md must document the CA bundle'
grep -Fq 'self-health' docs/DASHBOARD.md || fail 'DASHBOARD.md must document the self-health probe'
grep -Fq "distinct \`ingest_token\` and \`query_token\` keys" docs/AGENT_SETUP.md || fail 'AGENT_SETUP.md must document two-key credentials'
grep -Fq 'manual migration or backup state' docs/ARCHITECTURE.md || fail 'ARCHITECTURE.md must document manual legacy grafana-data handling'
grep -Fq 'stable checkout-owned lifecycle is Make-only' docs/DASHBOARD.md || fail 'DASHBOARD.md must document the stable Make dashboard lifecycle'
if ! grep -Fq 'Make-only' docs/DASHBOARD.md || ! grep -Fq 'make e2e-dashboard' docs/DASHBOARD.md; then
  fail 'DASHBOARD.md must document Make-only E2E entry points'
fi
grep -Fq 'not declared by active Compose' docs/ARCHITECTURE.md || fail 'ARCHITECTURE.md must document that Grafana is not active'
! grep -Eq '^[[:space:]]*(grafana|dashboard-lite):' docker-compose.yml || fail 'active Compose must not declare Grafana/dashboard-lite services'

python3 - <<'PY'
from pathlib import Path
import posixpath
import re
import sys
from urllib.parse import unquote

root = Path('.').resolve()
pairs = [
    'AGENT_SETUP', 'ARCHITECTURE', 'CONNECT', 'DASHBOARD', 'DEVELOPMENT',
    'JSON_CONTRACT', 'OPERATIONS', 'QUERY', 'README', 'RELEASING',
    'REPLACE_SAMPLE_APP', 'SAMPLING_AND_COMPLETENESS', 'SECURITY',
    'TROUBLESHOOTING',
]
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

def read(path):
    try:
        return path.read_text(encoding='utf-8')
    except OSError as error:
        errors.append(f'{path}: unable to read: {error}')
        return ''

def without_fences(text):
    return re.sub(r'^```[^\n]*\n.*?^```[ \t]*$', '', text, flags=re.MULTILINE | re.DOTALL)

def markdown_links(text):
    # Links inside fenced examples are commands/data, not Markdown edges.
    text = without_fences(text)
    pattern = re.compile(r'(?<!!)\[[^\]\n]+\]\(\s*(?:<([^>\n]*)>|([^\s)]+))')
    for match in pattern.finditer(text):
        yield match.group(1) or match.group(2)

def local_target(source, target):
    target = unquote(target.strip())
    if target.startswith(('#', '?')):
        path_part = ''
    else:
        path_part = target.split('#', 1)[0].split('?', 1)[0]
    if not path_part:
        return source
    return (source.parent / path_part).resolve()

def is_external(target):
    lowered = target.lower()
    return lowered.startswith((
        'http://', 'https://', 'mailto:', 'tel:', 'data:', 'javascript:', '//'
    ))

def heading_ids(text):
    # Validate fragments conservatively. GitHub-style heading IDs cover normal
    # headings; raw text fallback preserves anchors such as #한국어 in README.
    ids = set()
    counts = {}
    for match in re.finditer(r'^#{1,6}\s+(.+?)\s*#*\s*$', without_fences(text), re.MULTILINE):
        value = re.sub(r'<[^>]+>', '', match.group(1)).strip().lower()
        value = re.sub(r'[^\w\u0080-\uffff -]', '', value, flags=re.UNICODE)
        value = re.sub(r'\s+', '-', value).strip('-')
        count = counts.get(value, 0)
        counts[value] = count + 1
        ids.add(value if count == 0 else f'{value}-{count}')
    return ids

# Every public authority and every paired translation must exist.
public_paths = [root / 'docs' / 'README.md', root / 'docs' / 'ko' / 'README.md']
for name in pairs:
    public_paths.extend((root / 'docs' / f'{name}.md', root / 'docs' / 'ko' / f'{name}.md'))
for path in public_paths:
    require(path.is_file(), f'missing public documentation: {path.relative_to(root)}')

# Resolve every local Markdown edge in the landing pages, authorities, and
# machine-facing contract. This catches stale paths without treating external
# documentation URLs as repository inputs.
markdown_paths = [root / 'README.md', root / 'AGENTS.md'] + public_paths
for source in markdown_paths:
    text = read(source)
    for target in markdown_links(text):
        if is_external(target):
            continue
        candidate = local_target(source, target)
        try:
            candidate.relative_to(root)
        except ValueError:
            errors.append(f'{source.relative_to(root)}: local link escapes repository: {target}')
            continue
        require(candidate.exists(), f'{source.relative_to(root)}: broken local link: {target}')
        if '#' in target and candidate.is_file():
            fragment = unquote(target.split('#', 1)[1].split('?', 1)[0]).strip().lower()
            if fragment:
                target_text = read(candidate)
                ids = heading_ids(target_text)
                # Explicit text anchors are used by the bilingual root landing.
                raw_anchor = fragment in target_text.lower()
                require(fragment in ids or raw_anchor,
                        f'{source.relative_to(root)}: missing local link fragment: {target}')

# Every language pair has explicit reciprocal navigation and the same section
# shape. Prose is allowed to differ; heading levels and machine-readable blocks
# are intentionally not translated.
for name in pairs:
    english = root / 'docs' / f'{name}.md'
    korean = root / 'docs' / 'ko' / f'{name}.md'
    english_text = read(english)
    korean_text = read(korean)
    english_links = [target for target in markdown_links(english_text) if not is_external(target)]
    korean_links = [target for target in markdown_links(korean_text) if not is_external(target)]
    require(any(local_target(english, target) == korean for target in english_links),
            f'docs/{name}.md: missing reciprocal Korean navigation link')
    require(any(local_target(korean, target) == english for target in korean_links),
            f'docs/ko/{name}.md: missing reciprocal English navigation link')

    english_headings = [len(match.group(1)) for match in re.finditer(
        r'^(#{1,6})\s+.+$', without_fences(english_text), re.MULTILINE)]
    korean_headings = [len(match.group(1)) for match in re.finditer(
        r'^(#{1,6})\s+.+$', without_fences(korean_text), re.MULTILINE)]
    require(english_headings == korean_headings,
            f'{name}: English/Korean heading structure differs')

    fence_pattern = re.compile(r'^```([^\n]*)\n(.*?)^```[ \t]*$', re.MULTILINE | re.DOTALL)
    english_fences = [(m.group(1).strip(), m.group(2).strip()) for m in fence_pattern.finditer(english_text)]
    korean_fences = [(m.group(1).strip(), m.group(2).strip()) for m in fence_pattern.finditer(korean_text)]
    require(english_fences == korean_fences,
            f'{name}: English/Korean fenced command blocks differ')

# Compare only technical literals, not translated prose or relative language
# navigation. This covers environment names, endpoint/path literals, JSON keys,
# and documented machine state names while avoiding false positives such as the
# ordinary English word "current" in a sentence.
env_pattern = re.compile(r'\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b')
path_pattern = re.compile(r'(?<![\w])/(?:[A-Za-z0-9_.:{}*-]+/)*[A-Za-z0-9_.:{}*-]+')
endpoint_pattern = re.compile(r'\b(?:127\.0\.0\.1|localhost|gateway):[0-9]{2,5}\b')
key_pattern = re.compile(
    r'(?<![\w.])(?:agentotel\.project\.id|trace_id|span_id|severity_text|'
    r'schema_version|content_trust|ingest_token|query_token|project_id|'
    r'grafana_admin_password|DASHBOARD_CLIENT_TOKEN)(?![\w.])'
)
state_names = {
    'partial', 'truncated', 'no_data', 'no_matching_data', 'trace_not_stored',
    'signal_not_observed', 'backend_unavailable', 'backend_decode_error',
    'timeout', 'unavailable', 'warning', 'ok', 'dirty', 'ready',
}

def technical_tokens(text):
    no_fences = without_fences(text)
    no_links = re.sub(r'!?\[[^\]\n]+\]\([^)]*\)', '', no_fences)
    values = set(env_pattern.findall(no_links))
    values.update(endpoint_pattern.findall(no_links))
    values.update(key_pattern.findall(no_links))
    values.update(
        path for path in path_pattern.findall(no_links)
        if not path.startswith('/ko/') and not path.endswith('.md') and path != '/'
    )
    inline = ' '.join(re.findall(r'`([^`\n]+)`', no_fences))
    values.update(
        state for state in state_names
        if re.search(r'(?<![\w])' + re.escape(state) + r'(?![\w])', inline)
    )
    return values

for name in pairs:
    english_text = read(root / 'docs' / f'{name}.md')
    korean_text = read(root / 'docs' / 'ko' / f'{name}.md')
    english_tokens = technical_tokens(english_text)
    korean_tokens = technical_tokens(korean_text)
    require(english_tokens == korean_tokens,
            f'{name}: technical literal parity differs; English-only={sorted(english_tokens - korean_tokens)}, Korean-only={sorted(korean_tokens - english_tokens)}')

# The high-value operational contracts are checked in both languages. These are
# deliberately stable literals (commands, routes, keys, and formats), not prose.
paired_contracts = {
    'CONNECT': ('obs run', 'obs project ensure', 'agentotel.project.id',
                'Authorization=Bearer%20', '127.0.0.1:4318'),
    'ARCHITECTURE': ('127.0.0.1:4318', '127.0.0.1:17777', 'raw LogQL', 'PromQL', 'Jaeger'),
    'DASHBOARD': ('/api/services', '/api/context', '/api/errors', '/api/correlate',
                  'raw LogQL', 'PromQL', 'Jaeger', '64-lowercase-hex'),
    'DEVELOPMENT': ('make e2e', 'make e2e-app', 'make e2e-dashboard',
                    'cd e2e && npm test', 'AGENTOTEL_DEV_MODE=1'),
    'RELEASING': ('sha256sum', 'shasum', 'RELEASE_SOURCE_MODE=dirty'),
    'TROUBLESHOOTING': ('config-debug.yaml',),
    'OPERATIONS': ('obs migrate volumes --confirm', 'grafana_admin_password'),
    'SECURITY': ('ingest_token', 'query_token'),
}
for name, literals in paired_contracts.items():
    for language_dir in ('docs', 'docs/ko'):
        path = root / language_dir / f'{name}.md'
        text = read(path).lower()
        for literal in literals:
            require(literal.lower() in text,
                    f'{path.relative_to(root)}: missing required contract literal: {literal}')

# Deleted operational inputs must not reappear in active documentation.
for path in [root / 'README.md', root / 'AGENTS.md'] + public_paths:
    text = read(path)
    for stale in ('docs/DASHBOARD_PLAN.md', 'scripts/benchmark_batch_timeout.sh'):
        require(stale not in text,
                f'{path.relative_to(root)}: stale deleted-file reference: {stale}')

if errors:
    for error in errors:
        print(f'doc-contract: {error}', file=sys.stderr)
    raise SystemExit(1)
PY

echo 'doc-contract: PASS (Gateway-only app examples, bilingual links/parity, hardened sole Go dashboard, Make-only browser lifecycle, and workspace-scoped MCP docs)'
