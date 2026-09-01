#!/usr/bin/env bash
#
# verify.sh - post-deployment validation for AutoCare.
#
# Usage:
#   ./scripts/verify.sh [namespace]
#
# Checks namespace, deployment rollout, pod health (CrashLoopBackOff /
# ImagePullBackOff detection), service, ingress, and - if the ALB hostname
# is already assigned - the /actuator/health endpoint.
#
# Exits non-zero on any failed check.
#
set -euo pipefail

NAMESPACE="${1:-autocare}"
RELEASE_NAME="autocare"

echo "==> Namespace"
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: namespace '${NAMESPACE}' not found"
  exit 1
fi

echo "==> Deployment"
if ! kubectl get deployment "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: deployment '${RELEASE_NAME}' not found in namespace '${NAMESPACE}'"
  exit 1
fi
kubectl get deployment "${RELEASE_NAME}" -n "${NAMESPACE}"
kubectl rollout status deployment/"${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=120s

echo "==> Pods"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide

echo "==> Checking for unhealthy pods (CrashLoopBackOff / ImagePullBackOff / ErrImagePull / not Running)"
BAD_PODS=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}')

FAILED=0
while IFS='|' read -r POD_NAME POD_PHASE WAITING_REASONS; do
  [[ -z "${POD_NAME}" ]] && continue
  if [[ "${WAITING_REASONS}" == *CrashLoopBackOff* || "${WAITING_REASONS}" == *ImagePullBackOff* || "${WAITING_REASONS}" == *ErrImagePull* ]]; then
    echo "ERROR: pod ${POD_NAME} is in a bad state: ${WAITING_REASONS}"
    FAILED=1
  elif [[ "${POD_PHASE}" != "Running" && "${POD_PHASE}" != "Succeeded" ]]; then
    echo "ERROR: pod ${POD_NAME} is not Running (phase=${POD_PHASE})"
    FAILED=1
  fi
done <<< "${BAD_PODS}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo "ERROR: one or more pods are unhealthy"
  exit 1
fi
echo "All pods healthy."

echo "==> Service"
kubectl get svc "${RELEASE_NAME}" -n "${NAMESPACE}"

echo "==> Ingress"
if kubectl get ingress "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl get ingress "${RELEASE_NAME}" -n "${NAMESPACE}"
  ALB_HOSTNAME=$(kubectl get ingress "${RELEASE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${ALB_HOSTNAME}" ]]; then
    echo "==> Application URL: http://${ALB_HOSTNAME}"
    echo "==> Checking application health endpoint"
    if curl -sf --max-time 10 "http://${ALB_HOSTNAME}/actuator/health" >/dev/null; then
      echo "Application health endpoint is reachable."
    else
      echo "WARNING: could not reach /actuator/health yet (ALB may still be provisioning/propagating DNS)"
    fi
  else
    echo "WARNING: ALB hostname not yet assigned - it can take a few minutes after first deploy"
  fi
else
  echo "Ingress is not enabled for this release"
fi

echo "==> Recent events"
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -n 20

echo "==> Verification complete"
