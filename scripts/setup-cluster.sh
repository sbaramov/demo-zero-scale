#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-zero-scale}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1. Creating k3d cluster '${CLUSTER_NAME}' (Traefik disabled)..."
if k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  echo "Cluster '${CLUSTER_NAME}' already exists; reusing it."
else
  k3d cluster create "${CLUSTER_NAME}" \
    -p "8080:80@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0"
fi
kubectl config use-context "k3d-${CLUSTER_NAME}"

echo "==> 2. Installing Istio Service Mesh..."
istioctl install --set profile=default -y
kubectl rollout status deployment/istiod -n istio-system --timeout=180s
kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout=180s

echo "==> 3. Installing KEDA Core and KEDA HTTP Add-on..."
kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace keda istio-injection=disabled --overwrite

helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --set image.pullPolicy=IfNotPresent \
  --wait \
  --timeout 10m

helm upgrade --install http-add-on kedacore/keda-add-ons-http \
  --namespace keda \
  --set images.pullPolicy=IfNotPresent \
  --wait \
  --timeout 10m

echo "==> 4. Building and importing task-org-webapp:latest into k3d..."
docker build -t task-org-webapp:latest "${ROOT_DIR}/task-org-webapp"
k3d image import task-org-webapp:latest -c "${CLUSTER_NAME}"

echo "==> 5. Deploying Postgres StatefulSet, app, KEDA, and Istio resources..."
kubectl apply -f "${ROOT_DIR}/k8s/00-namespace.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/01-postgres/"
kubectl rollout status statefulset/postgres -n task-org --timeout=180s

kubectl apply -f "${ROOT_DIR}/k8s/02-app/"
kubectl rollout status deployment/task-org-webapp -n task-org --timeout=180s

kubectl apply -f "${ROOT_DIR}/k8s/03-keda/"
kubectl apply -f "${ROOT_DIR}/k8s/04-istio/"

echo "==> Setup complete! Visit http://localhost:8080 or run ./scripts/benchmark-cold-start.sh"
