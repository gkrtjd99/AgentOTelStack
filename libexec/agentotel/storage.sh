#!/bin/sh
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/volumes.sh"
if ! volume_inventory_load; then
  if [ "${AGENTOTEL_JSON:-0}" = 1 ]; then
    printf '%s\n' '{"status":"unavailable","check":"volumes","reason":"unable to inspect Docker volume inventory"}'
  else
    printf '%s\n' 'storage: unavailable (unable to inspect Docker volume inventory)'
  fi
  exit 2
fi
json=${AGENTOTEL_JSON:-0}; root=${AGENTOTEL_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}; gw=${GATEWAY_URL:-http://127.0.0.1:17777}; load_query_credential; token=$GATEWAY_QUERY_TOKEN; curl_bin=${AGENTOTEL_CURL_CMD:-curl}
case "${1:-storage}" in
 storage|disk)
   legacy=$(legacy_volume_list)
   expected=''; [ -f "$STATE/stack.uuid" ] && expected=$(cat "$STATE/stack.uuid"); mismatch=$(volume_mismatch_list "$expected")
   [ -z "$legacy$mismatch" ] || { if [ "$json" = 1 ]; then printf '{"status":"warn","check":"volumes","migration_required":true,"legacy_volumes":'; printf '%s' "$(printf '%s\n' "$legacy" | volume_json_array)"; printf ',"mismatched_volumes":'; printf '%s' "$(printf '%s\n' "$mismatch" | volume_json_array)"; printf ',"guidance":"backup and verify before any manual migration"}\n'; else printf 'storage: warn (migration_required; legacy or mismatched volumes)\n%s\n%s\n' "$legacy" "$mismatch"; fi; exit 1; }
   ;;
 cardinality)
   service=${2:-sample-app}; body=$($curl_bin -fsS -H "Authorization: Bearer $token" --get "$gw/v1/context" --data-urlencode "service=$service" --data-urlencode 'lookback=15m' --data-urlencode 'limit=500') || { [ "$json" = 1 ] && printf '{"status":"unavailable","check":"cardinality"}\n' || printf 'cardinality: unavailable\n'; exit 2; }
   count=$(printf '%s' "$body" | jq '[.data.metrics.data.result[]? // .data.metrics.result[]? // empty] | length' 2>/dev/null || echo 0); status=ok; [ "$count" -ge 100 ] && status=warn; [ "$count" -ge 500 ] && status=critical
   if [ "$json" = 1 ]; then printf '{"status":"%s","check":"cardinality","service":"%s","series":%s,"warn_at":100,"critical_at":500}\n' "$status" "$service" "$count"; else printf 'cardinality: %s (service=%s series=%s)\n' "$status" "$service" "$count"; fi
   [ "$status" = critical ] && exit 2; [ "$status" = warn ] && exit 1; exit 0;;
 canary)
   health=$($curl_bin -fsS -H "Authorization: Bearer $token" "$gw/v1/health") || { [ "$json" = 1 ] && printf '{"status":"unavailable","check":"canary"}\n' || printf 'canary: gateway unavailable\n'; exit 2; }
   services=$($curl_bin -fsS -H "Authorization: Bearer $token" "$gw/v1/services") || { [ "$json" = 1 ] && printf '{"status":"unavailable","check":"canary"}\n' || printf 'canary: services unavailable\n'; exit 2; }
   # A gateway may be healthy while its data plane is partial or has no backend
   # data. Keep these distinct so automation can decide whether to retry.
   canary_status=$(printf '%s' "$services" | jq -r 'if .partial == true then "partial" elif (([.backends[]?.status] | length) == 0) then "no_data" elif ([.backends[]?.status] | all(. == "ok")) then "ok" else "degraded" end' 2>/dev/null || printf no_data)
   [ "$canary_status" = ok ] || { rc=1; [ "$canary_status" = no_data ] && rc=2; [ "$json" = 1 ] && printf '{"status":"%s","check":"canary"}\n' "$canary_status" || printf 'canary: %s\n' "$canary_status"; exit "$rc"; }
   if [ "$json" = 1 ]; then printf '{"status":"ok","check":"canary","health":%s,"services":%s}\n' "$(printf '%s' "$health" | jq -c .)" "$(printf '%s' "$services" | jq -c .)"; else printf 'canary: ok (gateway health and services query)\n'; fi; exit 0;;
 *) die 'invalid storage command';; esac
df_tool=${AGENTOTEL_DF_CMD:-df}; df_snapshot=$($df_tool -Pk "$root"); used=$(printf '%s\n' "$df_snapshot" | awk 'NR==2{print $3}'); avail=$(printf '%s\n' "$df_snapshot" | awk 'NR==2{print $4}');
case "$used:$avail" in *[!0-9:]*|:*) used=0; avail=0;; esac
total=$((used+avail)); pct=0; [ "$total" -gt 0 ] && pct=$((used*100/total)); status=ok; [ "$pct" -ge 80 ] && status=warn; [ "$pct" -ge 90 ] && status=critical

# Observability is deliberately obtained from the Gateway's fixed, projected
# endpoints.  This keeps backend query syntax and credentials out of the CLI.
service=${AGENTOTEL_SERVICE:-sample-app}
storage_tmp=$(mktemp -d "${TMPDIR:-/tmp}/agentotel-storage.XXXXXX") || { printf '%s\n' 'storage: unable to create temporary directory' >&2; exit 2; }
trap 'rm -rf "$storage_tmp"' EXIT HUP INT TERM
ctx_rc=0; err_rc=0
$curl_bin -fsS -H "Authorization: Bearer $token" --get "$gw/v1/context" --data-urlencode "service=$service" --data-urlencode 'lookback=15m' --data-urlencode 'limit=500' >"$storage_tmp/context" 2>/dev/null & ctx_pid=$!
$curl_bin -fsS -H "Authorization: Bearer $token" --get "$gw/v1/errors" --data-urlencode "service=$service" --data-urlencode 'lookback=15m' --data-urlencode 'limit=500' >"$storage_tmp/errors" 2>/dev/null & err_pid=$!
wait "$ctx_pid" || ctx_rc=$?
wait "$err_pid" || err_rc=$?

# Decode each envelope once. The compact status/count records preserve the
# previous signal_status semantics while avoiding repeated jq processes and
# keeping malformed/partial responses unavailable.
ctx_stats='unavailable:null'
[ "$ctx_rc" -eq 0 ] && ctx_stats=$(jq -r '
  if (type != "object" or .partial == true or .data == null) then
    "unavailable:null"
  elif (((.data | type) == "array" and (.data | length) > 0) or
        ((.data | type) == "object" and (.data | length) > 0)) then
    ((.data.metrics.data.result // .data.metrics.result // []) | length) as $series |
    "ok:\($series)"
  else "no_data:0" end
' "$storage_tmp/context" 2>/dev/null || printf '%s' 'unavailable:null')
err_stats='unavailable:null:null:null'
[ "$err_rc" -eq 0 ] && err_stats=$(jq -r '
  if (type != "object" or .partial == true or .data == null) then
    "unavailable:null:null:null"
  elif (((.data | type) == "array" and (.data | length) > 0) or
        ((.data | type) == "object" and (.data | length) > 0)) then
    ((.data.logs.data? // .data.logs.result? // .data.logs? // []) |
      map((.service_name // "unknown") | tostring) | unique | length) as $logs |
    ((.data.traces.data? // .data.traces.result? // .data.traces? // []) |
      map((.service_name // "unknown") | tostring) | unique | length) as $traces |
    ((.data.traces.data? // .data.traces.result? // .data.traces? // []) |
      map(.spans // []) | add // [] |
      map((.name // .span_name // "unknown") | tostring) | unique | length) as $spans |
    "ok:\($logs):\($traces):\($spans)"
  else "no_data:0:0:0" end
' "$storage_tmp/errors" 2>/dev/null || printf '%s' 'unavailable:null:null:null')
cs=${ctx_stats%%:*}; series=${ctx_stats#*:}
es=${err_stats%%:*}; err_values=${err_stats#*:}; logs=${err_values%%:*}; err_values=${err_values#*:}; traces=${err_values%%:*}; spans=${err_values#*:}
[ -z "$cs" ] && { cs=unavailable; series=null; }
[ -z "$es" ] && { es=unavailable; logs=null; traces=null; spans=null; }
[ "$cs" = ok ] && [ "$series" = 0 ] && cs=no_data
[ "$es" = ok ] && [ "$logs" = 0 ] && [ "$traces" = 0 ] && es=no_data
if [ "$json" = 1 ]; then
  jq -cn --arg status "$status" --arg cs "$cs" --arg es "$es" --argjson series "$series" --argjson logs "$logs" --argjson traces "$traces" --argjson spans "$spans" --argjson used "$((used*1024))" --argjson total "$((total*1024))" --argjson free "$((avail*1024))" --argjson pct "$pct" '{status:$status,volume:{used_bytes:$used,total_bytes:$total,free_bytes:$free,used_percent:$pct},retention:{logs:"7d",metrics:"30d",traces:"7d",disk_cap_bytes:2147483648,min_free_bytes:209715200},signals:{ingest_rate:{status:(if $cs=="ok" then "ok" else $cs end),value:(if $cs=="ok" then $series else null end),rate:(if $cs=="ok" and ($series|type)=="number" then ($series/900) else null end),unit:"observed_evidence_rate",window_seconds:900,source:"gateway_context_projected_metrics",interpretation:"Bounded projected-series evidence rate; not backend ingest throughput."},metric_series:{status:$cs,value:(if $cs=="ok" then $series else null end),rate:null,unit:"series",window_seconds:900,source:"gateway_context_projected_metrics",interpretation:"Count of projected metric series only."},log_stream_churn:{status:$es,value:(if $es=="ok" then $logs else null end),rate:(if $es=="ok" and ($logs|type)=="number" then ($logs/900) else null end),unit:"observed_evidence_rate",window_seconds:900,source:"gateway_errors_projected_logs",interpretation:"Distinct low-cardinality service keys in projected records."},trace_service_span_churn:{status:$es,value:(if $es=="ok" then {services:$traces,span_names:$spans} else null end),rate:(if $es=="ok" and ($traces|type)=="number" and ($spans|type)=="number" then (($traces+$spans)/900) else null end),unit:"observed_evidence_rate",window_seconds:900,source:"gateway_errors_projected_traces",interpretation:"Distinct service and span-name keys in projected records."}},policy:{window:"15m",max_items:500,low_cardinality:true}}'
else printf 'storage: %s (used %s%%, free %s KiB)\nobservability: observed_evidence=%s/900s metric_series=%s logs=%s traces=%s (%s/%s)\n' "$status" "$pct" "$avail" "$series" "$series" "$logs" "$traces" "$cs" "$es"; fi
[ "$status" = critical ] && exit 2; [ "$status" = warn ] && exit 1; exit 0
