#!/bin/sh
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/config" "$t/data" "$t/state" "$t/run" "$t/repo"
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
printf 'project=%s\n' "${AGENTOTEL_PROJECT_ID:-}"
printf 'args=%s\n' "$*"
EOF
chmod 755 "$t/bin/docker"
run_obs(){
  HOME="$t/home" XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/run" PATH="$t/bin:$PATH" GATEWAY_INGEST_TOKEN=aaaaaaaa GATEWAY_QUERY_TOKEN=bbbbbbbb GF_SECURITY_ADMIN_PASSWORD=cccccccc AGENTOTEL_DEV_MODE=1 "$root/bin/obs" "$@"
}
git init -q "$t/repo"
git -C "$t/repo" config user.email test@example.invalid
git -C "$t/repo" config user.name test
id1=$(cd "$t/repo" && run_obs compose --profile demo up -d | sed -n 's/^project=//p')
printf '%s\n' "$id1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
(cd "$t/repo" && run_obs project rekey >/dev/null)
id2=$(cd "$t/repo" && run_obs compose --profile demo up -d | sed -n 's/^project=//p')
[ "$id1" != "$id2" ]
explicit=00000000-0000-4000-8000-000000000000
id3=$(cd /tmp && AGENTOTEL_PROJECT_ID="$explicit" run_obs compose --profile demo up -d | sed -n 's/^project=//p')
[ "$id3" = "$explicit" ]
if (cd /tmp && AGENTOTEL_PROJECT_ID=not-a-uuid run_obs compose --profile demo up -d) >"$t/invalid.out" 2>&1; then
  echo 'invalid explicit project ID was accepted' >&2
  exit 1
fi
grep -q 'must be a UUIDv4' "$t/invalid.out"
if (cd /tmp && run_obs compose --profile demo up -d) >"$t/missing.out" 2>&1; then
  echo 'demo outside Git without explicit identity was accepted' >&2
  exit 1
fi
grep -q 'not a git project' "$t/missing.out"
infra=$(cd /tmp && run_obs compose up -d)
printf '%s\n' "$infra" | grep -q 'project='
if grep -Eq 'aaaaaaaa|bbbbbbbb|cccccccc' "$t"/*.out; then
  echo 'compose failure output leaked a credential' >&2
  exit 1
fi
echo 'compose project identity checks passed'
