#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-zero-scale}"
NAMESPACE="${NAMESPACE:-task-org}"
DEPLOYMENT="${DEPLOYMENT:-task-org-webapp}"
URL="${URL:-http://localhost:8008/api/projects}"
ITERATIONS="${ITERATIONS:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
CSV_OUT="${CSV_OUT:-}"

LEIDEN_JAVA_OPTS="-XX:AOTMode=on -XX:AOTCache=app.aot"

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

RESP_FILE="$(mktemp)"
CSV_FILE="${CSV_OUT:-$(mktemp)}"
ORIG_JAVA_OPTS="$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JAVA_TOOL_OPTIONS")].value}' 2>/dev/null || true)"

cleanup() {
  rm -f "${RESP_FILE}"
  if [[ -z "${CSV_OUT}" ]]; then
    rm -f "${CSV_FILE}"
  fi
  echo ""
  echo "Restoring original JAVA_TOOL_OPTIONS on deployment/${DEPLOYMENT}..."
  if [[ -z "${ORIG_JAVA_OPTS}" ]]; then
    kubectl set env deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" JAVA_TOOL_OPTIONS- >/dev/null 2>&1 || true
  else
    kubectl set env deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" JAVA_TOOL_OPTIONS="${ORIG_JAVA_OPTS}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

now_epoch() {
  python3 -c 'import time; print(f"{time.time():.6f}")'
}

wait_for_zero() {
  local start_ts elapsed
  start_ts="$(now_epoch)"
  echo "Waiting for ${DEPLOYMENT} to scale to 0 replicas..."
  for _ in $(seq 1 120); do
    local count
    count=$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${count}" == "0" ]]; then
      elapsed=$(python3 -c "import time; print(f'{time.time() - ${start_ts}:.1f}')")
      echo "Scaled to 0 replicas in ${elapsed}s."
      SCALE_TO_ZERO_S="${elapsed}"
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for scale-to-zero." >&2
  return 1
}

echo "iteration,mode,http_code,ttfb_s,total_s,spring_startup_s,jvm_process_s,keda_k8s_boot_s,probe_and_route_s,scale_to_zero_s,pod_created,container_started,pod_ready" > "${CSV_FILE}"

run_case() {
  local iter="$1"
  local mode="$2"
  local label="$3"
  local java_opts="$4"

  echo ""
  echo "============================================================"
  echo "Iteration ${iter}/${ITERATIONS} — ${label}"
  echo "============================================================"

  if [[ -z "${java_opts}" ]]; then
    kubectl set env deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" JAVA_TOOL_OPTIONS- >/dev/null
  else
    kubectl set env deployment/"${DEPLOYMENT}" -n "${NAMESPACE}" JAVA_TOOL_OPTIONS="${java_opts}" >/dev/null
  fi

  SCALE_TO_ZERO_S=""
  wait_for_zero
  sleep 3

  echo "Triggering cold-start request: GET ${URL}"
  local req_start_ts curl_out http_code ttfb_s total_s
  req_start_ts="$(now_epoch)"
  curl_out=$(curl -sS --max-time "${CURL_MAX_TIME}" -o "${RESP_FILE}" \
    -w "%{http_code} %{time_starttransfer} %{time_total}" "${URL}")
  read -r http_code ttfb_s total_s <<< "${curl_out}"
  echo "Response: HTTP ${http_code} | TTFB: ${ttfb_s}s | Total: ${total_s}s"

  local pod
  pod=$(kubectl get pods -n "${NAMESPACE}" -l app="${DEPLOYMENT}" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}')
  echo "Pod: ${pod}"

  local pod_json started_line
  pod_json=$(kubectl get pod -n "${NAMESPACE}" "${pod}" -o json)
  started_line=$(kubectl logs -n "${NAMESPACE}" "${pod}" -c "${DEPLOYMENT}" | grep "Started TaskOrgWebappApplication" | tail -n 1 || true)
  echo "${started_line}"

  local row
  row=$(POD_JSON="${pod_json}" STARTED_LINE="${started_line}" REQ_START="${req_start_ts}" \
    ITER="${iter}" MODE="${mode}" HTTP_CODE="${http_code}" TTFB_S="${ttfb_s}" TOTAL_S="${total_s}" \
    SCALE_TO_ZERO_S="${SCALE_TO_ZERO_S}" python3 - <<'PY'
import datetime, json, os, re

pod = json.loads(os.environ["POD_JSON"])
line = os.environ["STARTED_LINE"]
req_start = float(os.environ["REQ_START"])
ttfb_s = float(os.environ["TTFB_S"])
total_s = float(os.environ["TOTAL_S"])

pod_created = pod.get("metadata", {}).get("creationTimestamp", "")
container_started = ""
cs = pod.get("status", {}).get("containerStatuses", [])
if cs:
    container_started = cs[0].get("state", {}).get("running", {}).get("startedAt", "")
pod_ready = ""
for cond in pod.get("status", {}).get("conditions", []):
    if cond.get("type") == "Ready":
        pod_ready = cond.get("lastTransitionTime", "")

spring_startup_s = ""
jvm_process_s = ""
keda_k8s_boot_s = ""
probe_and_route_s = ""

m = re.match(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(?:Z|[+-]\d{2}:\d{2}))\s+.*Started TaskOrgWebappApplication in ([0-9.]+) seconds \(process running for ([0-9.]+)\)",
    line.strip(),
)
if m:
    started_ts = datetime.datetime.fromisoformat(m.group(1).replace("Z", "+00:00")).timestamp()
    spring_s = float(m.group(2))
    proc_s = float(m.group(3))
    jvm_start_ts = started_ts - proc_s
    ttfb_ts = req_start + ttfb_s
    boot_s = jvm_start_ts - req_start
    probe_s = ttfb_ts - started_ts
    spring_startup_s = f"{spring_s:.3f}"
    jvm_process_s = f"{proc_s:.3f}"
    keda_k8s_boot_s = f"{boot_s:.3f}"
    probe_and_route_s = f"{probe_s:.3f}"

print(",".join([
    os.environ["ITER"],
    os.environ["MODE"],
    os.environ["HTTP_CODE"],
    f"{ttfb_s:.3f}",
    f"{total_s:.3f}",
    spring_startup_s,
    jvm_process_s,
    keda_k8s_boot_s,
    probe_and_route_s,
    os.environ["SCALE_TO_ZERO_S"],
    pod_created,
    container_started,
    pod_ready,
]))
PY
)
  echo "${row}" >> "${CSV_FILE}"
}

for i in $(seq 1 "${ITERATIONS}"); do
  if (( i % 2 == 1 )); then
    run_case "${i}" "baseline" "Baseline JVM (no AOT cache)" ""
    run_case "${i}" "leyden" "Project Leyden AOT Cache (${LEIDEN_JAVA_OPTS})" "${LEIDEN_JAVA_OPTS}"
  else
    run_case "${i}" "leyden" "Project Leyden AOT Cache (${LEIDEN_JAVA_OPTS})" "${LEIDEN_JAVA_OPTS}"
    run_case "${i}" "baseline" "Baseline JVM (no AOT cache)" ""
  fi
done

echo ""
echo "============================================================"
echo "Summary across ${ITERATIONS} alternating iterations"
echo "============================================================"
CSV_FILE="${CSV_FILE}" python3 - <<'PY'
import csv, math, os, statistics

with open(os.environ["CSV_FILE"], newline="") as f:
    rows = list(csv.DictReader(f))

def pct(vals, p):
    s = sorted(vals)
    if not s:
        return float("nan")
    k = (len(s) - 1) * (p / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)

metrics = [
    ("spring_startup_s", "Spring Boot startup (s)"),
    ("jvm_process_s",    "JVM process to Started (s)"),
    ("keda_k8s_boot_s",  "KEDA + K8s boot to JVM (s)"),
    ("probe_and_route_s","Probe + route to TTFB (s)"),
    ("ttfb_s",           "End-to-end HTTP TTFB (s)"),
]

for mode in ("baseline", "leyden"):
    mrows = [r for r in rows if r["mode"] == mode]
    errs = sum(1 for r in mrows if r["http_code"] != "200")
    print(f"\nMode: {mode} (n={len(mrows)}, non-200={errs})")
    print(f"  {'Metric':<28} {'min':>7} {'median':>7} {'p90':>7} {'max':>7}")
    for key, label in metrics:
        vals = [float(r[key]) for r in mrows if r[key]]
        if vals:
            print(f"  {label:<28} {min(vals):7.3f} {statistics.median(vals):7.3f} {pct(vals, 90):7.3f} {max(vals):7.3f}")

scale_vals = [float(r["scale_to_zero_s"]) for r in rows if r["scale_to_zero_s"]]
if scale_vals:
    print(f"\nScale-to-zero wait (s): min={min(scale_vals):.1f} median={statistics.median(scale_vals):.1f} max={max(scale_vals):.1f}")
PY

if [[ -n "${CSV_OUT}" ]]; then
  echo ""
  echo "Raw CSV written to ${CSV_OUT}"
fi
