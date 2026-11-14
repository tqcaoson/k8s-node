#!/usr/bin/env bash
# Kiem tra toan bo he thong sau khi deploy (guide muc 7):
# trang thai resource, healthz, CRUD that qua port-forward, RWX, Galera.
# Ky vong theo CAU HINH NHO: 1 Pod PXC, 1 Pod ProxySQL, wsrep_cluster_size=1.
# Chay tren EC2: ./scripts/06-verify.sh
set -uo pipefail
source "$(dirname "$0")/common.sh"

PASS=0
FAIL=0
check() { # check <ten> <lenh...>
  local name="$1"; shift
  if "$@" >/tmp/verify-out.txt 2>&1; then
    PASS=$((PASS + 1)); log "PASS: $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $name (xem /tmp/verify-out.txt)" >&2
  fi
}

need_cmd kubectl
need_cmd curl

log "=== Trang thai resource ==="
kubectl get nodes
kubectl -n production get pxc,pods,pvc,svc,ingress,hpa,cronjob

log "=== Kiem tra PXC + ProxySQL ==="
check "PXC state=Ready" bash -c '[ "$(kubectl -n production get pxc cluster1 -o jsonpath="{.status.state}")" = "Ready" ]'
check "1 Pod PXC Running (cau hinh nho)" bash -c '[ "$(kubectl -n production get pods -l app.kubernetes.io/component=pxc --field-selector=status.phase=Running --no-headers | wc -l)" = "1" ]'
check "Galera cluster size=1 (cau hinh nho: 1 node, khong co quorum that)" bash -c 'kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -uroot -p"PxcRoot123!" -N -e "SHOW STATUS LIKE '\''wsrep_cluster_size'\'';" | grep -qE "wsrep_cluster_size[[:space:]]+1$"'
check "1 Pod ProxySQL Running" bash -c '[ "$(kubectl -n production get pods -l app.kubernetes.io/component=proxysql --field-selector=status.phase=Running --no-headers | wc -l)" = "1" ]'
check "Service cluster1-proxysql co endpoint" bash -c '[ -n "$(kubectl -n production get endpoints cluster1-proxysql -o jsonpath="{.subsets[0].addresses[0].ip}")" ]'
check "Noi MySQL qua ProxySQL (SELECT 1)" bash -c 'kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -h cluster1-proxysql -uroot -p"PxcRoot123!" -N -e "SELECT 1;" | grep -q 1'

log "=== Kiem tra web qua port-forward + CRUD that ==="
kubectl -n production port-forward svc/nodejs-service 3000:80 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 5
check "GET /healthz = 200 (process song)" bash -c 'curl -fsSL http://localhost:3000/healthz | grep -q "\"status\":\"ok\""'
check "GET /readyz = 200 (noi duoc MySQL)" bash -c 'curl -fsSL http://localhost:3000/readyz | grep -q "\"db\":\"up\""'
check "GET /api/tasks tra ve 5 dong seed" bash -c 'curl -fsSL http://localhost:3000/api/tasks | grep -q "Cai Kubernetes tren EC2"'
# POST truoc, lay id tu response (khong doan id tu danh sach — neu POST
# loi ma van lay id dau danh sach thi PUT/DELETE se sua nham dong seed).
curl -fsSL -X POST http://localhost:3000/api/tasks -H "Content-Type: application/json" \
  -d '{"title":"Task test tu 06-verify.sh","status":"todo"}' > /tmp/new-task.json 2>/dev/null || true
NEW_ID="$(grep -o '"id":[0-9]*' /tmp/new-task.json 2>/dev/null | head -1 | cut -d: -f2)"
if [ -n "$NEW_ID" ]; then
  check "POST tao task moi (id=$NEW_ID)" bash -c 'grep -q "Task test tu" /tmp/new-task.json'
  check "PUT cap nhat task vua tao" bash -c "curl -fsSL -X PUT http://localhost:3000/api/tasks/$NEW_ID -H 'Content-Type: application/json' -d '{\"status\":\"done\"}' | grep -q '\"done\"'"
  check "DELETE xoa task vua tao" bash -c "curl -fsSL -X DELETE http://localhost:3000/api/tasks/$NEW_ID | grep -q deleted"
else
  FAIL=$((FAIL + 3))
  echo "FAIL: POST tao task moi (khong tao duoc task — bo qua PUT/DELETE)" >&2
  cat /tmp/new-task.json >&2 || true
fi
log "=== Kiem tra dispatcher: CronJob tao Job xu ly task ==="
# Tao 1 task todo, kich hoat dispatcher ngay (khong doi lich 5 phut),
# doi Job xu ly xong roi kiem tra task da chuyen sang done.
curl -fsSL -X POST http://localhost:3000/api/tasks -H "Content-Type: application/json" \
  -d '{"title":"Task test dispatcher","status":"todo"}' > /tmp/dispatch-task.json 2>/dev/null || true
DISPATCH_ID="$(grep -o '"id":[0-9]*' /tmp/dispatch-task.json 2>/dev/null | head -1 | cut -d: -f2)"
if [ -n "$DISPATCH_ID" ]; then
  kubectl delete job dispatch-test -n production --ignore-not-found
  kubectl create job dispatch-test --from=cronjob/task-worker -n production
  wait_job_complete production dispatch-test 300s
  kubectl wait --for=condition=complete job -l task-id="$DISPATCH_ID" -n production --timeout=300s
  check "Task duoc dispatcher xu ly xong (status=done)" bash -c "curl -fsSL http://localhost:3000/api/tasks/$DISPATCH_ID | grep -q '\"done\"'"
  check "Ket qua xu ly co trong shared volume" bash -c "kubectl -n production exec deploy/nodejs-web -- cat /app/shared/results/task-$DISPATCH_ID.json | grep -q '\"result\": \"ok\"'"
  curl -fsSL -X DELETE "http://localhost:3000/api/tasks/$DISPATCH_ID" >/dev/null 2>&1 || true
  kubectl delete job dispatch-test -n production --ignore-not-found
else
  FAIL=$((FAIL + 2))
  echo "FAIL: Khong tao duoc task test dispatcher" >&2
fi

kill $PF_PID 2>/dev/null || true
trap - EXIT

log "=== Kiem tra shared PVC (RWX): Pod 1 ghi, Pod 2 doc ==="
POD1="$(kubectl -n production get pods -l app=nodejs-web -o jsonpath='{.items[0].metadata.name}')"
POD2="$(kubectl -n production get pods -l app=nodejs-web -o jsonpath='{.items[1].metadata.name}')"
if [ -n "$POD1" ] && [ -n "$POD2" ] && [ "$POD1" != "$POD2" ]; then
  check "RWX ghi/doc qua 2 Pod" bash -c "kubectl -n production exec $POD1 -- sh -c 'echo hello-rwx > /app/shared/verify.txt' && kubectl -n production exec $POD2 -- cat /app/shared/verify.txt | grep -q hello-rwx"
else
  warn "Can 2 Web Pod de test RWX, hien chi co 1 — bo qua."
fi

log "=== Kiem tra Ingress (qua NodePort tren node nay) ==="
DOMAIN="$(kubectl -n production get ingress nodejs-ingress -o jsonpath='{.spec.rules[0].host}')"
HTTP_PORT="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo 30080)"
check "Ingress tra /readyz 200" bash -c "curl -fsSL -H 'Host: $DOMAIN' http://127.0.0.1:$HTTP_PORT/readyz | grep -q '\"db\":\"up\"'"
log "Mo web tu trinh duyet: http://${DOMAIN}:${HTTP_PORT}"

log "=== CronJob ==="
kubectl -n production get cronjob task-worker
kubectl -n production get jobs -l app=task-worker 2>/dev/null || log "(chua co Job nao chay — CronJob chay moi 5 phut)"

echo
log "KET QUA: $PASS pass, $FAIL fail."
[ "$FAIL" -eq 0 ] || die "Co $FAIL kiem tra that bai. Xem lai log o tren."
