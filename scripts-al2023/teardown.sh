#!/usr/bin/env bash
# Do sach toan bo ung dung + nen tang khoi cluster.
#   ./scripts-al2023/teardown.sh [--yes]
# Luu y: StorageClass dung reclaimPolicy Retain nen PV Longhorn van giu lai
# du lieu sau khi xoa PVC — xoa tay tren Longhorn UI neu muon sach han.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ "${1:-}" != "--yes" ]; then
  read -r -p "Xoa toan bo ung dung + PXC + Longhorn + Ingress? (ghi YES de xac nhan) " CONFIRM
  [ "$CONFIRM" = "YES" ] || die "Da huy."
fi

need_cmd kubectl
need_cmd helm

log "Xoa app, Job, CronJob, HPA, Ingress..."
kubectl delete -f "$ROOT_DIR/k8s/app/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/worker/" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/networkpolicy/" --ignore-not-found
kubectl delete job db-init db-migrate -n production --ignore-not-found

log "Xoa PXC cluster..."
helm uninstall cluster1 -n production || true
kubectl delete -f "$ROOT_DIR/k8s/db/pxc-secrets.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/app/app-secret.yaml" --ignore-not-found

log "Xoa PVC shared + StorageClass..."
kubectl delete -f "$ROOT_DIR/k8s/storage/pvc-shared.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/storage/" --ignore-not-found

log "Xoa platform (fluent-bit, pxc-operator, longhorn, ingress)..."
helm uninstall fluent-bit -n logging || true
helm uninstall pxc-operator -n pxc-operator || true
helm uninstall longhorn -n longhorn-system || true
helm uninstall ingress-nginx -n ingress-nginx || true

log "Xoa namespace production..."
kubectl delete namespace production --ignore-not-found

log "XONG teardown."
