#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-zero-scale}"
K3S_VERSION="${K3S_VERSION:-v1.35.5-k3s1}"
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.21.1}"
KEDA_HTTP_CHART_VERSION="${KEDA_HTTP_CHART_VERSION:-0.16.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1. Creating k3d cluster '${CLUSTER_NAME}' (k3s ${K3S_VERSION} with built-in Traefik Ingress)..."
if k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  echo "Cluster '${CLUSTER_NAME}' already exists; reusing it."
else
  k3d cluster create "${CLUSTER_NAME}" \
    --image "rancher/k3s:${K3S_VERSION}" \
    -p "8008:80@loadbalancer" \
    --k3s-arg "--kubelet-arg=image-gc-high-threshold=96@server:0" \
    --k3s-arg "--kubelet-arg=image-gc-low-threshold=92@server:0"
fi
kubectl config use-context "k3d-${CLUSTER_NAME}"

echo "==> 2. Installing KEDA Core (${KEDA_CHART_VERSION}) and KEDA HTTP Add-on (${KEDA_HTTP_CHART_VERSION})..."
kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f -

helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update

helm upgrade --install keda kedacore/keda \
  --version "${KEDA_CHART_VERSION}" \
  --namespace keda \
  --set image.pullPolicy=IfNotPresent \
  --wait \
  --timeout 10m

helm upgrade --install http-add-on kedacore/keda-add-ons-http \
  --version "${KEDA_HTTP_CHART_VERSION}" \
  --namespace keda \
  --wait \
  --timeout 10m

echo "==> 3. Building and deploying task-org-webapp and manifests..."
CLUSTER_NAME="${CLUSTER_NAME}" "${ROOT_DIR}/scripts/deploy.sh"

echo "==> Setup complete! Visit http://localhost:8008 or run ./scripts/benchmark-cold-start.sh"
