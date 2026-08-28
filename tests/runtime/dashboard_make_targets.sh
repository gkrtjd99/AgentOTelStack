#!/bin/sh
# Contract checks for the Make-managed dashboard and browser lifecycle.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)

dashboard=$(make -C "$root" -n dashboard)
printf '%s\n' "$dashboard" | grep -Fq './scripts/make-compose.sh dashboard'
! printf '%s\n' "$dashboard" | grep -Eqi 'grafana|dashboard-lite|curl .*dashboard.*\/$' || {
  echo 'dashboard target retains a retired UI or static-root-only readiness path' >&2
  exit 1
}

dashboard_down=$(make -C "$root" -n dashboard-down)
printf '%s\n' "$dashboard_down" | grep -Fq './scripts/make-compose.sh compose --profile dashboard stop dashboard'
! printf '%s\n' "$dashboard_down" | grep -Eqi ' down( |$)|--remove-orphans' || {
  echo 'dashboard-down must not tear down the whole Compose project' >&2
  exit 1
}

for target in e2e e2e-app e2e-dashboard; do
  recipe=$(make -C "$root" -n "$target")
  printf '%s\n' "$recipe" | grep -Fq "./scripts/run-e2e.sh"
  ! printf '%s\n' "$recipe" | grep -Eqi 'npm install|npm run install-browsers|cd e2e' || {
    echo "$target retains an unmanaged npm lifecycle" >&2
    exit 1
  }
done

grep -Fq 'dashboard-readiness.sh' "$root/scripts/make-compose.sh"
grep -Fq 'generate_dashboard_token' "$root/scripts/make-compose.sh"
grep -Fq 'dashboard bootstrap URL' "$root/scripts/make-compose.sh"
grep -Fq -- "-f \"\$ROOT/docker-compose.yml\"" "$root/scripts/make-compose.sh"
grep -Fq -- "-p \"\$project\"" "$root/scripts/make-compose.sh"
for name in COMPOSE_FILE COMPOSE_ENV_FILES COMPOSE_PATH_SEPARATOR COMPOSE_PROFILES; do
  grep -Fq -- "-u $name" "$root/scripts/make-compose.sh" || {
    echo "Make Compose boundary does not scrub $name" >&2
    exit 1
  }
done
if test -e "$root/scripts/start-dashboard.sh"; then
  echo 'start-dashboard.sh should be absorbed by make-compose.sh' >&2
  exit 1
fi
if test -e "$root/scripts/controlled-compose.sh"; then
  echo 'controlled-compose.sh should be absorbed by make-compose.sh' >&2
  exit 1
fi

# Semantic survivor check: dashboard-down must stop only dashboard and preserve the
# Gateway, collector, Victoria stores, and demo app services.
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home" "$t/config/agentotel" "$t/data" "$t/state" "$t/run" "$t/services"
printf '%s\n' '{"ingest_token":"aaaaaaaa","query_token":"bbbbbbbb"}' >"$t/config/agentotel/credentials"
chmod 600 "$t/config/agentotel/credentials"
for service in gateway otel-collector victorialogs victoriametrics victoriatraces app dashboard; do : >"$t/services/$service"; done
cat >"$t/bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = compose ] || exit 90
[ -z "${COMPOSE_PROFILES:-}" ] || { echo 'inherited COMPOSE_PROFILES crossed Make Compose boundary' >&2; exit 92; }
shift
printf '%s\n' "$*" >>"$FAKE_COMPOSE_LOG"
case " $* " in
  *' stop dashboard '*) rm -f "$FAKE_SERVICES/dashboard";;
  *) echo 'dashboard-down invoked a non-dashboard lifecycle operation' >&2; exit 91;;
esac
EOF
chmod 755 "$t/bin/docker"
if ! env PATH="$t/bin:$PATH" HOME="$t/home" XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" XDG_STATE_HOME="$t/state" XDG_RUNTIME_DIR="$t/run" AGENTOTEL_DEV_MODE=1 COMPOSE_PROFILES=hostile FAKE_COMPOSE_LOG="$t/compose.log" FAKE_SERVICES="$t/services" make -C "$root" dashboard-down >"$t/down.out" 2>&1; then
  cat "$t/down.out" >&2
  exit 1
fi
grep -q 'stop dashboard' "$t/compose.log"
if grep -Eq '(^| )down( |$)|--remove-orphans' "$t/compose.log"; then
  echo 'dashboard-down invoked whole-project teardown' >&2
  exit 1
fi
[ ! -e "$t/services/dashboard" ]
for service in gateway otel-collector victorialogs victoriametrics victoriatraces app; do
  [ -e "$t/services/$service" ] || { echo "dashboard-down removed survivor: $service" >&2; exit 1; }
done

printf '%s\n' 'dashboard Make targets: PASS (pinned Compose context and Gateway-backed readiness)'
