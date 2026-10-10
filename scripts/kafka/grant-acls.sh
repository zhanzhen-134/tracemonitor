#!/usr/bin/env bash
set -euo pipefail
: "${CHANGE_APPROVAL_ID:?External Kafka ACL approval required}"
: "${KAFKA_BOOTSTRAP:?}"
: "${KAFKA_TOPIC:?}"
: "${KAFKA_ADMIN_CONFIG:?}"
: "${KAFKA_PRINCIPAL:?}"
# Exact groups for fullnameOverride=tempo and zones zone-a / zone-b, Tempo 3.1.0.
# Update and review this list when renaming the release or changing zones.
groups=(block-builder metrics-generator tempo-live-store-zone-a tempo-live-store-zone-b)
kafka-acls.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" \
  --add --allow-principal "$KAFKA_PRINCIPAL" --operation Read --operation Write --operation Describe --topic "$KAFKA_TOPIC"
for group in "${groups[@]}"; do
  kafka-acls.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" \
    --add --allow-principal "$KAFKA_PRINCIPAL" --operation Read --operation Describe --group "$group"
done
