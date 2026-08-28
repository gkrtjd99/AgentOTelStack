#!/bin/sh
# Verify every Go format boundary preserves a formatter's nonzero status,
# including when the formatter emits no diagnostics.
set -eu
root=$(CDPATH=; cd -- "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT HUP INT TERM
mkdir -p "$t/bin"
cat >"$t/bin/fake-gofmt" <<'EOF'
#!/bin/sh
case "${FAKE_GOFMT_MODE:-pass}" in
  pass) exit 0 ;;
  fail-empty) exit 17 ;;
  fail-output) printf 'formatter diagnostic\n'; exit 19 ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$t/bin/fake-gofmt"

for module in mcp gateway dashboard; do
  test -d "$root/src/$module"
  GOFMT_BIN="$t/bin/fake-gofmt" FAKE_GOFMT_MODE=pass \
    "$root/scripts/check-gofmt.sh" "$root/src/$module"
  for mode in fail-empty fail-output; do
    if GOFMT_BIN="$t/bin/fake-gofmt" FAKE_GOFMT_MODE="$mode" \
      "$root/scripts/check-gofmt.sh" "$root/src/$module" >"$t/$module-$mode.out" 2>&1; then
      echo "$module accepted fake formatter mode $mode" >&2
      exit 1
    fi
  done
done

grep -Fq 'check-gofmt.sh' "$root/.github/workflows/ci.yml"
grep -Fq 'check-gofmt.sh' "$root/scripts/test-ci-local.sh"
if grep -Fq 'test -z ' "$root/.github/workflows/ci.yml" && grep -Fq 'gofmt -d -e' "$root/.github/workflows/ci.yml"; then
  echo 'workflow still masks gofmt status behind command substitution' >&2
  exit 1
fi
if grep -Fq 'test -z ' "$root/scripts/test-ci-local.sh" && grep -Fq 'gofmt -d -e' "$root/scripts/test-ci-local.sh"; then
  echo 'local CI still masks gofmt status behind command substitution' >&2
  exit 1
fi

echo 'gofmt contract: PASS (MCP, Gateway, Dashboard, and local fallback fail closed)'
