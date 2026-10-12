#!/usr/bin/env bash
set -euo pipefail
: "${CHANGE_APPROVAL_ID:?External Kafka ACL approval required}"
: "${KAFKA_BOOTSTRAP:?}"
: "${KAFKA_TOPIC:?}"
: "${KAFKA_ADMIN_CONFIG:?}"
: "${KAFKA_PRINCIPAL:?}"
# Exact groups for fullnameOverride=tempo, Tempo 3.1.0. Single-zone live-store uses tempo-live-store;
# multi-zone (ZONE_MODE=multi) uses one group per zone. Review when renaming the release or zones.
if [[ "${ZONE_MODE:-single}" == multi ]]; then
  groups=(block-builder metrics-generator tempo-live-store-zone-a tempo-live-store-zone-b)
else
  groups=(block-builder metrics-generator tempo-live-store)
fi
kafka-acls.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" \
  --add --allow-principal "$KAFKA_PRINCIPAL" --operation Read --operation Write --operation Describe --topic "$KAFKA_TOPIC"
for group in "${groups[@]}"; do
  kafka-acls.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" \
    --add --allow-principal "$KAFKA_PRINCIPAL" --operation Read --operation Describe --group "$group"
done
