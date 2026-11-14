#!/usr/bin/env bash
# Ham dung chung cho cac script. Khong chay truc tiep.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { echo "[$(date +'%H:%M:%S')] $*"; }
die()  { echo "LOI: $*" >&2; exit 1; }
warn() { echo "CANH BAO: $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Thieu lenh '$1'. Hay cai truoc khi chay script nay."
}

# Doi Pod co label selector san sang trong namespace.
wait_pods_ready() {
  local namespace="$1" selector="$2" timeout="${3:-600s}"
  log "Doi Pod san sang (ns=$namespace, selector=$selector, toi da $timeout)..."
  kubectl wait --for=condition=ready pod -l "$selector" -n "$namespace" --timeout="$timeout"
}

# Doi Job hoan thanh, neu that bai thi in log de de debug.
wait_job_complete() {
  local namespace="$1" job="$2" timeout="${3:-600s}"
  log "Doi Job $job hoan thanh (toi da $timeout)..."
  if kubectl wait --for=condition=complete "job/$job" -n "$namespace" --timeout="$timeout"; then
    log "Job $job: Complete."
  else
    echo "--- Log Job $job ---" >&2
    kubectl logs -n "$namespace" "job/$job" --tail=50 >&2 || true
    die "Job $job khong hoan thanh trong $timeout. Xem log o tren."
  fi
}
