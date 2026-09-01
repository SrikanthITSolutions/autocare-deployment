#!/usr/bin/env bash
#
# deploy.sh - deploy AutoCare to EKS outside of Jenkins (local/manual testing).
#
# Usage:
#   ./scripts/deploy.sh <environment> <image-tag> [ecr-repository] [aws-region] [eks-cluster-name] [namespace]
#
# Positional args 3-6 fall back to environment variables of the same name
# (ECR_REPOSITORY, AWS_REGION, EKS_CLUSTER_NAME, NAMESPACE) if omitted.
#
# Examples:
#   ./scripts/deploy.sh dev abc1234
#   ECR_REPOSITORY=123456789012.dkr.ecr.ap-south-1.amazonaws.com/autocare \
#     ./scripts/deploy.sh prod 9f3c2d1
#
set -euo pipefail

usage() {
  echo "Usage: $0 <environment: dev|prod> <image-tag> [ecr-repository] [aws-region] [eks-cluster-name] [namespace]"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

ENVIRONMENT="$1"
IMAGE_TAG="$2"
ECR_REPOSITORY="${3:-${ECR_REPOSITORY:-}}"
AWS_REGION="${4:-${AWS_REGION:-ap-south-1}}"
EKS_CLUSTER_NAME="${5:-${EKS_CLUSTER_NAME:-autocare-${ENVIRONMENT}-eks}}"
NAMESPACE="${6:-${NAMESPACE:-autocare}}"
RELEASE_NAME="autocare"

if [[ "$ENVIRONMENT" != "dev" && "$ENVIRONMENT" != "prod" ]]; then
  echo "ERROR: environment must be 'dev' or 'prod' (got '${ENVIRONMENT}')"
  exit 1
fi

if [[ -z "$IMAGE_TAG" ]]; then
  echo "ERROR: image-tag must be provided"
  exit 1
fi

if [[ "$ENVIRONMENT" == "prod" && "${IMAGE_TAG,,}" == "latest" ]]; then
  echo "ERROR: 'latest' is not an allowed image tag for production deployments"
  exit 1
fi

if [[ -z "$ECR_REPOSITORY" ]]; then
  echo "ERROR: ECR_REPOSITORY must be provided as the 3rd argument or as an environment variable"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../helm/autocare"
VALUES_FILE="${CHART_DIR}/values-${ENVIRONMENT}.yaml"

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "ERROR: values file not found: ${VALUES_FILE}"
  exit 1
fi

echo "==> Deploying AutoCare"
echo "    Environment  : ${ENVIRONMENT}"
echo "    Image        : ${ECR_REPOSITORY}:${IMAGE_TAG}"
echo "    AWS Region   : ${AWS_REGION}"
echo "    EKS Cluster  : ${EKS_CLUSTER_NAME}"
echo "    Namespace    : ${NAMESPACE}"

echo "==> Verifying AWS credentials"
aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null

echo "==> Verifying ECR image exists"
IMAGE_REPO_NAME="${ECR_REPOSITORY##*/}"
if ! aws ecr describe-images \
      --repository-name "${IMAGE_REPO_NAME}" \
      --image-ids imageTag="${IMAGE_TAG}" \
      --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "ERROR: image tag '${IMAGE_TAG}' was not found in ECR repository '${IMAGE_REPO_NAME}'"
  exit 1
fi

echo "==> Updating kubeconfig for cluster ${EKS_CLUSTER_NAME}"
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}"

echo "==> Verifying EKS access"
kubectl get nodes >/dev/null

echo "==> helm lint"
helm lint "${CHART_DIR}" -f "${VALUES_FILE}"

echo "==> helm upgrade --install --dry-run"
helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --set image.repository="${ECR_REPOSITORY}" \
  --set image.tag="${IMAGE_TAG}" \
  --dry-run

echo "==> helm upgrade --install"
helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --set image.repository="${ECR_REPOSITORY}" \
  --set image.tag="${IMAGE_TAG}" \
  --wait \
  --atomic \
  --timeout 10m

echo "==> Waiting for rollout"
kubectl rollout status deployment/"${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=300s

echo "==> Deployment complete. Running verification"
"${SCRIPT_DIR}/verify.sh" "${NAMESPACE}"
