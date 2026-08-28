#!/usr/bin/env bash
# shellcheck disable=SC2154
# Exact-resource ownership and cleanup primitives for isolated CI stacks.
# Callers provide project, uuid, volumes, networks, setup_attempted,
# compose_attempted, ci_failed, and a compose_raw() function. Set ci_xdg_root
# when the caller owns a temporary XDG tree that should be removed on exit.

ci_resource_absence_check() {
  local phase="$1" found name
  found="$(docker ps -a --filter "label=com.docker.compose.project=$project" -q)"
  if [[ -n "$found" ]]; then
    if [[ "$phase" == preflight ]]; then
      echo "FAIL: generated project already owns containers; refusing cleanup target: $project" >&2
    else
      echo "cleanup: containers remain for $project" >&2
    fi
    return 1
  fi
  found="$(docker network ls --filter "label=com.docker.compose.project=$project" -q)"
  if [[ -n "$found" ]]; then
    if [[ "$phase" == preflight ]]; then
      echo "FAIL: generated project already owns networks; refusing cleanup target: $project" >&2
    else
      echo "cleanup: labeled networks remain for $project" >&2
    fi
    return 1
  fi
  for name in "${networks[@]}"; do
    if docker network inspect "$name" >/dev/null 2>&1; then
      if [[ "$phase" == preflight ]]; then
        echo "FAIL: generated project network already exists; refusing cleanup target: $name" >&2
      else
        echo "cleanup: network remains: $name" >&2
      fi
      return 1
    fi
  done
  for name in "${volumes[@]}"; do
    if docker volume inspect "$name" >/dev/null 2>&1; then
      if [[ "$phase" == preflight ]]; then
        echo "FAIL: generated project volume already exists; refusing cleanup target: $name" >&2
      else
        echo "cleanup: volume remains: $name" >&2
      fi
      return 1
    fi
  done
}

ci_resource_inventory_preflight() {
  ci_resource_absence_check preflight
}

ci_resource_exact_volume_labels() {
  local name="$1" inspected expected
  inspected="$(docker volume inspect -f '{{.Name}}|{{ index .Labels "com.agentotel.stack" }}|{{ index .Labels "com.docker.compose.project" }}' "$name" 2>/dev/null)" || return 1
  printf -v expected '%s|%s|%s' "$name" "$uuid" "$project"
  [[ "$inspected" == "$expected" ]]
}

ci_resource_post_cleanup_zero() {
  ci_resource_absence_check post_cleanup
}

ci_resource_cleanup() {
  local original_status="$?" cleanup_failed=0 name
  set +e
  if [[ "${ci_failed:-0}" == 1 ]]; then
    echo '== CI failure diagnostics (safe metadata/log tail) ==' >&2
    compose_raw ps >&2 || true
    compose_raw images >&2 || true
    compose_raw logs --no-color --tail=80 gateway dashboard otel-collector victorialogs victoriametrics victoriatraces >&2 || true
  fi
  if [[ "${compose_attempted:-0}" == 1 ]]; then
    if ! compose_raw --profile demo --profile dashboard down --remove-orphans >/dev/null; then
      echo 'cleanup: Compose down failed' >&2
      cleanup_failed=1
    fi
  fi
  # Setup ran only after the empty-resource proof. Any exact volume that now
  # exists is therefore a creation candidate, but labels are checked before
  # every external-volume deletion so a race or mismatch is never deleted.
  if [[ "${setup_attempted:-0}" == 1 ]]; then
    for name in "${volumes[@]}"; do
      if docker volume inspect "$name" >/dev/null 2>&1; then
        if ci_resource_exact_volume_labels "$name"; then
          if ! docker volume rm "$name" >/dev/null; then
            echo "cleanup: failed to remove owned volume $name" >&2
            cleanup_failed=1
          fi
        else
          echo "cleanup: refusing volume with mismatched ownership labels: $name" >&2
          cleanup_failed=1
        fi
      fi
    done
  fi
  if ! ci_resource_post_cleanup_zero; then cleanup_failed=1; fi
  if [[ -n "${ci_xdg_root:-}" ]]; then
    rm -rf "$ci_xdg_root" || cleanup_failed=1
  fi
  if [[ "$original_status" != 0 ]]; then
    echo "integration: preserving original test failure status=$original_status" >&2
  fi
  if [[ "$cleanup_failed" == 1 ]]; then
    echo 'integration: cleanup failed' >&2
    exit 1
  fi
  exit "$original_status"
}
