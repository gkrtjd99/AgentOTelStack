#!/usr/bin/env bash
# Shared Bash loopback port selection for Make-managed and CI Compose lifecycles.
# Callers set requested_* variables to validated explicit values (or leave them
# empty) and call port_selection_select. The selected values are exported.
port_selection_in_list() {
  local needle="$1" list="$2"
  case " $list " in
    *" $needle "*) return 0 ;;
  esac
  return 1
}

port_selection_validate_requested() {
  local name value
  reserved_ports=""
  for name in GATEWAY_INGEST_HOST_PORT GATEWAY_QUERY_HOST_PORT APP_HOST_PORT DASHBOARD_HOST_PORT; do
    case "$name" in
      GATEWAY_INGEST_HOST_PORT) value="${requested_gateway_ingest_port:-}" ;;
      GATEWAY_QUERY_HOST_PORT) value="${requested_gateway_query_port:-}" ;;
      APP_HOST_PORT) value="${requested_app_port:-}" ;;
      DASHBOARD_HOST_PORT) value="${requested_dashboard_port:-}" ;;
    esac
    [[ -z "$value" ]] && continue
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" =~ ^0[0-9]+$ ]]; then
      echo "FAIL: $name must be a canonical decimal TCP port (leading zeros are rejected), got '$value'" >&2
      return 2
    fi
    if ! (( 10#$value >= 1024 && 10#$value <= 65535 )); then
      echo "FAIL: $name must be a TCP port (1024-65535), got '$value'" >&2
      return 2
    fi
    if port_selection_in_list "$value" "$reserved_ports"; then
      echo "FAIL: $name=$value duplicates another explicitly selected host port" >&2
      return 2
    fi
    reserved_ports+=" $value"
  done
}

port_selection_is_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

port_selection_pick() {
  local value="$1" name="$2" candidate
  if [[ -n "$value" ]]; then
    if port_selection_in_list "$value" "${selected_ports:-}"; then
      echo "FAIL: $name=$value duplicates another selected host port" >&2
      return 2
    fi
    port_selection_is_free "$value" || {
      echo "FAIL: $name=$value is unavailable on loopback; user-selected ports are never changed" >&2
      return 2
    }
    printf '%s' "$value"
    return 0
  fi
  for _ in 1 2 3 4 5 6 7 8; do
    candidate="$(python3 <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
    if ! port_selection_in_list "$candidate" "${selected_ports:-} ${reserved_ports:-}"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  echo "FAIL: could not select a unique loopback port for $name" >&2
  return 2
}

port_selection_select() {
  requested_gateway_ingest_port="${requested_gateway_ingest_port:-}"
  requested_gateway_query_port="${requested_gateway_query_port:-}"
  requested_app_port="${requested_app_port:-}"
  requested_dashboard_port="${requested_dashboard_port:-}"
  port_selection_validate_requested || return $?
  selected_ports=""
  auto_port_count=0
  [[ -n "$requested_gateway_ingest_port" ]] || auto_port_count=$((auto_port_count + 1))
  [[ -n "$requested_gateway_query_port" ]] || auto_port_count=$((auto_port_count + 1))
  [[ -n "$requested_app_port" ]] || auto_port_count=$((auto_port_count + 1))
  [[ -n "$requested_dashboard_port" ]] || auto_port_count=$((auto_port_count + 1))
  GATEWAY_INGEST_HOST_PORT="$(port_selection_pick "$requested_gateway_ingest_port" GATEWAY_INGEST_HOST_PORT)" || return $?
  selected_ports+=" $GATEWAY_INGEST_HOST_PORT"
  GATEWAY_QUERY_HOST_PORT="$(port_selection_pick "$requested_gateway_query_port" GATEWAY_QUERY_HOST_PORT)" || return $?
  selected_ports+=" $GATEWAY_QUERY_HOST_PORT"
  APP_HOST_PORT="$(port_selection_pick "$requested_app_port" APP_HOST_PORT)" || return $?
  selected_ports+=" $APP_HOST_PORT"
  DASHBOARD_HOST_PORT="$(port_selection_pick "$requested_dashboard_port" DASHBOARD_HOST_PORT)" || return $?
  selected_ports+=" $DASHBOARD_HOST_PORT"
  export GATEWAY_INGEST_HOST_PORT GATEWAY_QUERY_HOST_PORT APP_HOST_PORT DASHBOARD_HOST_PORT
  export GATEWAY_URL="http://127.0.0.1:${GATEWAY_QUERY_HOST_PORT}"
  export APP_URL="http://127.0.0.1:${APP_HOST_PORT}"
  export DASHBOARD_URL="http://127.0.0.1:${DASHBOARD_HOST_PORT}"
}
