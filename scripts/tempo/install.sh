#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
check_bundle
: "${CHANGE_APPROVAL_ID:?Record approval for namespace, rollout operator CRDs/webhooks, external integrations}"
: "${GATEWAY_MODE:?Set new or reuse}"
case "$GATEWAY_MODE" in new|reuse) ;; *) echo 'Invalid GATEWAY_MODE' >&2; exit 1;; esac
k get namespace "$TEMPO_NAMESPACE" >/dev/null
k get secret tempo-credentials tempo-ca >/dev/null
if [[ "$GATEWAY_MODE" == new ]]; then k get secret otel-gateway-tls >/dev/null; fi
k apply --dry-run=server -f "$ROOT/build/manifests/tempo/networkpolicy.yaml"
k apply -f "$ROOT/build/manifests/tempo/networkpolicy.yaml"
# CRDs installed by Helm are not automatically upgraded or removed on rollback.
h upgrade --install tempo "$ROOT/charts/tempo/tempo-distributed-3.11.1.tgz" \
  --values "$ROOT/build/charts/tempo/values-production.yaml" --wait --timeout 20m
k apply --dry-run=server -f "$ROOT/build/manifests/tempo/networkpolicy.yaml" -f "$ROOT/build/manifests/tempo/prometheusrule.yaml"
k apply -f "$ROOT/build/manifests/tempo/networkpolicy.yaml" -f "$ROOT/build/manifests/tempo/prometheusrule.yaml"
if [[ "$GATEWAY_MODE" == new ]]; then
  k apply --dry-run=server -f "$ROOT/build/manifests/otel-gateway"
  k apply -f "$ROOT/build/manifests/otel-gateway"
  k rollout status deployment/otel-gateway --timeout=5m
fi
h status tempo
