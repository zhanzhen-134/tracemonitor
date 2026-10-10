#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TEMPO_NAMESPACE:?Set TEMPO_NAMESPACE to the rendered namespace}"
k() { kubectl --namespace "$TEMPO_NAMESPACE" "$@"; }
h() { helm --namespace "$TEMPO_NAMESPACE" "$@"; }
check_bundle() {
  test -f "$ROOT/build/tempo-rendered.yaml"
  test "$(cat "$ROOT/build/render-mode.txt")" = production || { echo 'Production script refuses dev bundle' >&2; exit 1; }
  if grep -RE '<[A-Z][A-Z0-9_]*>' "$ROOT/build/manifests" "$ROOT/build/charts"; then
    echo 'Unresolved environment placeholders' >&2; exit 1
  fi
  # Namespace mismatch would install Helm and standalone objects into different namespaces.
  python -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["metadata"]["name"] == sys.argv[2]' \
    "$ROOT/build/manifests/tempo/namespace.yaml" "$TEMPO_NAMESPACE"
}
