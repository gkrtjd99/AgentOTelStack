#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/config" "$t/data" "$t/state" "$t/run" "$t/repo"
unset COMPOSE_PROFILES
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
printf 'project=%s\n' "${AGENTOTEL_PROJECT_ID:-}"
printf 'args=%s\n' "$*"
EOF
chmod 755 "$t/bin/docker"
run_obs(){
  HOME="$t/home" XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/run" PATH="$t/bin:$PATH" GATEWAY_INGEST_TOKEN=aaaaaaaa GATEWAY_QUERY_TOKEN=bbbbbbbb AGENTOTEL_DEV_MODE=1 "$root/bin/obs" "$@"
}
run_obs_no_profiles(){
  unset COMPOSE_PROFILES
  run_obs "$@"
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
dashboard=$(cd /tmp && AGENTOTEL_PROJECT_ID="$explicit" run_obs compose --profile dashboard up -d dashboard)
printf '%s\n' "$dashboard" | grep -q 'args=compose --profile dashboard up -d dashboard'
profiles=$(cd /tmp && COMPOSE_PROFILES=demo,dashboard AGENTOTEL_PROJECT_ID="$explicit" run_obs compose up -d)
printf '%s\n' "$profiles" | grep -q "project=$explicit"
service_arg=$(cd /tmp && AGENTOTEL_PROJECT_ID="$explicit" run_obs compose up -d dashboard)
printf '%s\n' "$service_arg" | grep -q 'args=compose up -d dashboard'
profile_equal=$(cd /tmp && AGENTOTEL_PROJECT_ID="$explicit" run_obs compose --profile=dashboard ps)
printf '%s\n' "$profile_equal" | grep -q "project=$explicit"
for option in \
  '--env-file app' \
  '-f dashboard' \
  '--file dashboard' \
  '-p app' \
  '--project-name app' \
  '--project-directory dashboard'; do
  read -r -a option_args <<<"$option"
  option_output=$(cd /tmp && AGENTOTEL_PROJECT_ID='' run_obs_no_profiles compose "${option_args[@]}" ps)
  printf '%s\n' "$option_output" | grep -q '^project=$' || {
    echo "Compose option value was mistaken for a service: $option" >&2
    exit 1
  }
done
if (cd /tmp && AGENTOTEL_PROJECT_ID=not-a-uuid run_obs compose --profile demo up -d) >"$t/invalid.out" 2>&1; then
  echo 'invalid explicit project ID was accepted' >&2
  exit 1
fi
grep -q 'must be a UUIDv4' "$t/invalid.out"
if (cd /tmp && COMPOSE_PROFILES=demo AGENTOTEL_PROJECT_ID=not-a-uuid run_obs compose up -d) >"$t/profile-invalid.out" 2>&1; then
  echo 'invalid COMPOSE_PROFILES project ID was accepted' >&2
  exit 1
fi
grep -q 'must be a UUIDv4' "$t/profile-invalid.out"
if (cd /tmp && AGENTOTEL_PROJECT_ID=not-a-uuid run_obs compose up -d dashboard) >"$t/service-invalid.out" 2>&1; then
  echo 'invalid dashboard service project ID was accepted' >&2
  exit 1
fi
grep -q 'must be a UUIDv4' "$t/service-invalid.out"
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
