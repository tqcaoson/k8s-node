#!/usr/bin/env bash
# Do sach toan bo ung dung + PXC + Longhorn + Ingress khoi cluster.
#   ./scripts-al2023/teardown.sh [--yes]
# Luu y quan trong:
# - StorageClass dung reclaimPolicy Retain nen PV van giu lai sau khi xoa
#   PVC; script se xoa cac PV o trang thai Released thuoc namespace production.
# - Longhorn volume co the nam lai sau khi xoa PVC (volume mo coi) va chiem
#   cho dat truoc tren disk, lam lan cai lai sau bi faulted vi het cho;
#   script se xoa cac volume Longhorn khong con PV nao tham chieu.
# - Neu CR PXC ket o Terminating (finalizer cua Operator khong duoc go),
#   script se patch go finalizer de xoa dut diem.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ "${1:-}" != "--yes" ]; then
  read -r -p "Xoa toan bo ung dung + PXC + Longhorn + Ingress? (ghi YES de xac nhan) " CONFIRM
  [ "$CONFIRM" = "YES" ] || die "Da huy."
fi

need_cmd kubectl
need_cmd helm
need_cluster

log "1/7 Xoa app, Job, CronJob, HPA, Ingress..."
kubectl delete -f "$ROOT_DIR/k8s/app/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/worker/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/networkpolicy/" --ignore-not-found
kubectl delete job db-init db-migrate -n production --ignore-not-found

log "2/7 Xoa PXC cluster (helm uninstall)..."
helm uninstall cluster1 -n production || true
# CR co the ket o Terminating vi finalizer cua Operator khong duoc go
# (dac biet khi cluster chua tung chay thanh cong). Doi 30s, neu CR con
# thi patch go finalizer de xoa dut diem.
sleep 30
if kubectl -n production get pxc cluster1 >/dev/null 2>&1; then
  warn "CR cluster1 van con sau 30s — go finalizer de xoa dut diem."
  kubectl -n production patch pxc cluster1 --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]' || true
  kubectl -n production wait --for=delete pxc/cluster1 --timeout=120s || true
fi

log "3/7 Xoa PVC du lieu cua PXC/ProxySQL (StatefulSet khong tu xoa PVC)..."
kubectl delete pvc datadir-cluster1-pxc-0 proxydata-cluster1-proxysql-0 \
  -n production --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/storage/pvc-shared.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/storage/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/db/pxc-secrets.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/app/app-secret.yaml" --ignore-not-found

log "4/7 Xoa namespace production..."
kubectl delete namespace production --ignore-not-found
kubectl wait --for=delete namespace/production --timeout=180s || true

log "5/7 Xoa PV Released thuoc du an (reclaimPolicy Retain giu lai PV)..."
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  claim_ns="$(kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null || echo '')"
  if [ "$claim_ns" = "production" ]; then
    log "Xoa PV Released: $pv"
    kubectl delete pv "$pv" --ignore-not-found
  fi
done

log "6/7 Xoa volume Longhorn mo coi (khong con PV nao tham chieu)..."
# Longhorn tinh dung luong theo size da dat truoc; volume mo coi chiem cho
# va lam lan cai lai sau bi faulted. Chi xoa volume khong con PV nao tro toi.
sleep 30
for vol in $(kubectl -n longhorn-system get volume.longhorn.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  if ! kubectl get pv 2>/dev/null | grep -q "$vol"; then
    log "Xoa volume Longhorn mo coi: $vol"
    kubectl -n longhorn-system delete volume.longhorn.io "$vol" --ignore-not-found
  fi
done

log "7/7 Xoa platform (fluent-bit, pxc-operator, longhorn, ingress)..."
helm uninstall fluent-bit -n logging || true
helm uninstall pxc-operator -n pxc-operator || true
helm uninstall longhorn -n longhorn-system || true
helm uninstall ingress-nginx -n ingress-nginx || true

log "XONG teardown. Cluster sach, co the chay lai tu scripts-al2023/03."
