#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-zero-scale}"

echo "==> Deleting k3d cluster '${CLUSTER_NAME}'..."
if k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  k3d cluster delete "${CLUSTER_NAME}"
  echo "==> Cluster '${CLUSTER_NAME}' deleted."
else
  echo "Cluster '${CLUSTER_NAME}' does not exist; nothing to delete."
fi
