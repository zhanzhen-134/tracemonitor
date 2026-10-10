#!/usr/bin/env bash
set -euo pipefail
: "${CHANGE_APPROVAL_ID:?External Kafka change approval required}"
: "${KAFKA_BOOTSTRAP:?}"
: "${KAFKA_TOPIC:?Use a dedicated new Tempo topic}"
: "${KAFKA_ADMIN_CONFIG:?Path to a protected client.properties file}"
: "${KAFKA_PRINCIPAL:?For example User:tempo}"
: "${PARTITIONS:?Must match reviewed partition plan}"
kafka-topics.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" \
  --create --topic "$KAFKA_TOPIC" --partitions "$PARTITIONS" --replication-factor 3 \
  --config min.insync.replicas=2 --config retention.ms=86400000 \
  --config cleanup.policy=delete --config max.message.bytes=16000000
bash "$(dirname -- "$0")/grant-acls.sh"
kafka-topics.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --command-config "$KAFKA_ADMIN_CONFIG" --describe --topic "$KAFKA_TOPIC"
