#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
check_bundle
h status tempo
k get deploy,statefulset,pod,pvc,svc,pdb,servicemonitor -o wide
k wait pod -l app.kubernetes.io/name=tempo --for=condition=Ready --timeout=10m
: "${TEMPO_QUERY_URL:?Set authenticated query URL or local port-forward URL}"
: "${TRACE_ID:?Set the actual 32-character trace ID from the demo}"
[[ "$TRACE_ID" =~ ^[0-9a-f]{32}$ ]] || exit 1
curl --fail --silent --show-error "$TEMPO_QUERY_URL/api/traces/$TRACE_ID" -o "$ROOT/build/trace-recent.json"
"$PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("batches") or d.get("resourceSpans"), "No spans returned"' "$ROOT/build/trace-recent.json"
echo 'Recent trace found. Backend-only lookup, metric/log correlation and failure drills remain mandatory; see docs/tempo/06-validation.md.'
