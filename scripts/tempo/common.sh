#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TEMPO_NAMESPACE:?Set TEMPO_NAMESPACE to the rendered namespace}"
# Python 3.10+ (validated with 3.10.12); Ubuntu 22.04 only provides python3.
PYTHON="${PYTHON:-$(command -v python3 || command -v python || true)}"
[[ -n "$PYTHON" ]] && "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
  || { echo 'Python 3.10+ is required (set PYTHON=/path/to/python3)' >&2; exit 1; }
k() { kubectl --namespace "$TEMPO_NAMESPACE" "$@"; }
h() { helm --namespace "$TEMPO_NAMESPACE" "$@"; }
check_bundle() {
  test -f "$ROOT/build/tempo-rendered.yaml"
  test "$(cat "$ROOT/build/render-mode.txt")" = production || { echo 'Production script refuses dev bundle' >&2; exit 1; }
  if grep -RE '<[A-Z][A-Z0-9_]*>' "$ROOT/build/manifests" "$ROOT/build/charts"; then
    echo 'Unresolved environment placeholders' >&2; exit 1
  fi
  # Namespace mismatch would install Helm and standalone objects into different namespaces.
  "$PYTHON" -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["metadata"]["name"] == sys.argv[2]' \
    "$ROOT/build/manifests/tempo/namespace.yaml" "$TEMPO_NAMESPACE"
}
