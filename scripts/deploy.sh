#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-zero-scale}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl config use-context "k3d-${CLUSTER_NAME}"

echo "==> 1. Building and importing task-org-webapp:latest into k3d '${CLUSTER_NAME}'..."
docker build -t task-org-webapp:latest "${ROOT_DIR}/task-org-webapp"
k3d image import task-org-webapp:latest -c "${CLUSTER_NAME}"

echo "==> 2. Applying Postgres StatefulSet, app, KEDA, and Istio manifests..."
kubectl apply -f "${ROOT_DIR}/k8s/00-namespace.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/01-postgres/"
kubectl rollout status statefulset/postgres -n task-org --timeout=180s

kubectl apply -f "${ROOT_DIR}/k8s/02-app/"
kubectl rollout restart deployment/task-org-webapp -n task-org
kubectl rollout status deployment/task-org-webapp -n task-org --timeout=180s

kubectl apply -f "${ROOT_DIR}/k8s/03-keda/"
kubectl apply -f "${ROOT_DIR}/k8s/04-istio/"

echo "==> Deployment complete! Visit http://localhost:8080"
