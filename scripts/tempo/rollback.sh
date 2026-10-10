#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
: "${REVISION:?Set reviewed Helm revision}"
: "${ROLLBACK_COMPATIBILITY_APPROVAL:?Confirm data-format compatibility and rollout CRD impact}"
[[ "$REVISION" =~ ^[0-9]+$ ]] || exit 1
h history tempo
h rollback tempo "$REVISION" --wait --timeout 20m
h status tempo
echo 'Only Helm-managed resources rolled back. Kafka, S3, CRDs and standalone Collector manifests are not restored.'
