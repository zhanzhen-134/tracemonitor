#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
check_bundle
: "${CHANGE_APPROVAL_ID:?Record approval for namespace, CRDs/webhooks, external integrations}"
: "${GATEWAY_MODE:?Set new or reuse}"
case "$GATEWAY_MODE" in new|reuse) ;; *) echo 'Invalid GATEWAY_MODE' >&2; exit 1;; esac
M="$ROOT/build/manifests"
k get namespace "$TEMPO_NAMESPACE" >/dev/null
k get secret tempo-credentials >/dev/null
if [[ "$GATEWAY_MODE" == new ]]; then k get secret otel-gateway-tls >/dev/null; fi
k apply --dry-run=server -f "$M/tempo/networkpolicy.yaml"
k apply -f "$M/tempo/networkpolicy.yaml"

# Dedicated Kafka and RustFS for Tempo, in the same namespace.
deps=(-f "$M/kafka/service.yaml" -f "$M/kafka/statefulset.yaml" -f "$M/kafka/networkpolicy.yaml"
      -f "$M/rustfs/service.yaml" -f "$M/rustfs/statefulset.yaml" -f "$M/rustfs/networkpolicy.yaml")
k apply --dry-run=server "${deps[@]}"
k apply "${deps[@]}"
k rollout status statefulset/tempo-kafka --timeout=10m
k rollout status statefulset/tempo-rustfs --timeout=10m
# Jobs are immutable: delete the previous run before re-applying. Both Jobs are idempotent.
for job in kafka/job-create-topic rustfs/job-create-bucket; do
  name=$(basename "$job"); name="tempo-${job%%/*}-${name#job-}"
  k delete job "$name" --ignore-not-found
  k apply -f "$M/$job.yaml"
  k wait "job/$name" --for=condition=complete --timeout=5m
  k logs "job/$name" --tail=20
done

# CRDs installed by Helm are not automatically upgraded or removed on rollback.
h upgrade --install tempo "$ROOT/charts/tempo/tempo-distributed-3.11.1.tgz" \
  --values "$ROOT/build/charts/tempo/values-production.yaml" --wait --timeout 20m
k apply --dry-run=server -f "$M/tempo/networkpolicy.yaml" -f "$M/tempo/prometheusrule.yaml"
k apply -f "$M/tempo/networkpolicy.yaml" -f "$M/tempo/prometheusrule.yaml"
if [[ "$GATEWAY_MODE" == new ]]; then
  k apply --dry-run=server -f "$M/otel-gateway"
  k apply -f "$M/otel-gateway"
  k rollout status deployment/otel-gateway --timeout=5m
fi
h status tempo
