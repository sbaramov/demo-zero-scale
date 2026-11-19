#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="task-org"
DEPLOYMENT="task-org-webapp"
URL="${URL:-http://localhost:8080/api/projects}"

wait_for_zero() {
  echo "Waiting for ${DEPLOYMENT} to scale to 0 replicas..."
  for _ in $(seq 1 90); do
    local count
    count=$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${count}" == "0" ]]; then
      echo "Scaled to 0 replicas."
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for scale-to-zero." >&2
  return 1
}

run_case() {
  local label="$1"
  local java_opts="$2"

  echo ""
  echo "============================================================"
  echo "Benchmark: ${label}"
  echo "============================================================"

  if [[ -z "${java_opts}" ]]; then
    kubectl set env deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" JAVA_TOOL_OPTIONS- >/dev/null
  else
    kubectl set env deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" JAVA_TOOL_OPTIONS="${java_opts}" >/dev/null
  fi

  wait_for_zero
  sleep 3

  echo "Triggering cold-start request: GET ${URL}"
  local curl_out
  curl_out=$(curl -sS -o /tmp/zero-scale-resp.json -w "HTTP %{http_code} | Total time: %{time_total}s | TTFB: %{time_starttransfer}s" "${URL}")
  echo "Response: ${curl_out}"

  local pod
  pod=$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" -o jsonpath='{.items[0].metadata.name}')
  echo "Pod: ${pod}"
  kubectl logs -n "${NAMESPACE}" "${pod}" -c "${DEPLOYMENT}" | grep "Started TaskOrgWebappApplication" || true
}

run_case "Baseline JVM (no AOT cache)" ""
run_case "Project Leyden AOT Cache (-XX:AOTCache=app.aot)" "-XX:AOTCache=app.aot"
