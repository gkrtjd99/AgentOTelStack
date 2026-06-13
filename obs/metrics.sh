#!/usr/bin/env bash
# Query metrics from VictoriaMetrics with PromQL.
#
# Usage:
#   obs/metrics.sh '<PromQL>'                 # instant query (now)
#   obs/metrics.sh '<PromQL>' range <step>    # range query over the last 15m
#
# Examples:
#   obs/metrics.sh 'sum by (outcome) (orders_processed_total)'
#   obs/metrics.sh 'rate(orders_processed_total{outcome="error"}[1m])' range 15s
#   obs/metrics.sh 'histogram_quantile(0.95, sum by (le) (rate(order_processing_seconds_bucket[5m])))'
#
# Docs: https://docs.victoriametrics.com/victoriametrics/metricsql/

source "$(dirname "$0")/common.sh"

query="${1:?usage: metrics.sh '<PromQL>' [range <step>]}"
mode="${2:-instant}"

if [[ "$mode" == "range" ]]; then
  step="${3:-15s}"
  # last 15 minutes; VictoriaMetrics accepts relative durations for start/end
  curl -s "${VM_URL}/api/v1/query_range" \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=-15m" \
    --data-urlencode "end=now" \
    --data-urlencode "step=${step}" | pp '.data.result'
else
  curl -s "${VM_URL}/api/v1/query" \
    --data-urlencode "query=${query}" | pp '.data.result'
fi
