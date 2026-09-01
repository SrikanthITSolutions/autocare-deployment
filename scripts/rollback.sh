#!/usr/bin/env bash
#
# rollback.sh - roll the AutoCare Helm release back to a previous revision.
#
# Usage:
#   ./scripts/rollback.sh <namespace> [revision]
#
#   namespace   Kubernetes namespace the release is deployed in (e.g. autocare)
#   revision    Optional Helm revision number to roll back to.
#               Omit it to roll back to the previous successful revision.
#
# Examples:
#   ./scripts/rollback.sh autocare        # rollback to the previous revision
#   ./scripts/rollback.sh autocare 3      # rollback to revision 3 explicitly
#
# How to identify a release / inspect history manually:
#   helm list -n autocare
#   helm history autocare -n autocare
#
set -euo pipefail

usage() {
  echo "Usage: $0 <namespace> [revision]"
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

NAMESPACE="$1"
REVISION="${2:-}"
RELEASE_NAME="autocare"

if ! helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: release '${RELEASE_NAME}' not found in namespace '${NAMESPACE}'"
  exit 1
fi

echo "==> Release history (before rollback)"
helm history "${RELEASE_NAME}" -n "${NAMESPACE}"

if [[ -z "${REVISION}" ]]; then
  echo "==> Rolling back to the previous revision"
  helm rollback "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 10m
else
  echo "==> Rolling back to revision ${REVISION}"
  helm rollback "${RELEASE_NAME}" "${REVISION}" -n "${NAMESPACE}" --wait --timeout 10m
fi

echo "==> Waiting for rollout to stabilize"
kubectl rollout status deployment/"${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=300s

echo "==> Release history (after rollback)"
helm history "${RELEASE_NAME}" -n "${NAMESPACE}"

echo "==> Pods"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}"

echo "==> Rollback complete"
