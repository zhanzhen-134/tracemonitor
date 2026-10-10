#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
check_bundle
for tool in kubectl helm python; do command -v "$tool" >/dev/null; done
k version
k get nodes -L topology.kubernetes.io/zone
k get storageclass
k get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
k auth can-i create deployments.apps
k auth can-i create statefulsets.apps
k auth can-i create secrets
k auth can-i create customresourcedefinitions.apiextensions.k8s.io
echo 'Read-only preflight complete. Verify dependency connectivity and approval checklist before install.'
