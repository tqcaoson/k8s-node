#!/usr/bin/env bash
# Do sach toan bo ung dung + nen tang khoi cluster.
#   ./scripts/teardown.sh [--yes] [--clean-longhorn-orphans]
# Luu y:
# - StorageClass dung reclaimPolicy Retain nen PV Longhorn van giu lai du
#   lieu sau khi xoa PVC — script xoa luon PV Released cua namespace
#   production (du lieu tren volume Longhorn van con cho toi khi xoa
#   volume — xem muc volume mo coi ben duoi).
# - PVC cua StatefulSet (datadir PXC, proxydata ProxySQL) KHONG tu xoa khi
#   xoa StatefulSet/CR — script xoa tay 2 PVC nay.
# - Volume Longhorn mo coi (khong con PV nao tham chieu) chi duoc LIET KE,
#   khong tu xoa — truyen --clean-longhorn-orphans de xoa (can than:
#   volume da xoa la mat du lieu tren do). Neu de sot, volume mo coi chiem
#   cho scheduled tren disk va co the lam volume moi bi faulted khi cai lai.
set -euo pipefail
source "$(dirname "$0")/common.sh"

YES=false
CLEAN_ORPHANS=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --clean-longhorn-orphans) CLEAN_ORPHANS=true ;;
    *) die "Tham so khong biet: $arg (chi ho tro --yes, --clean-longhorn-orphans)" ;;
  esac
done

if [ "$YES" != true ]; then
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
# CR co the ket lai do finalizer cua Operator (gap khi CR chua tao xong da
# bi xoa — helm uninstall tra ve nhung CR van con). Neu CR van con sau 30s,
# go finalizer roi xoa truc tiep.
sleep 5
if kubectl -n production get pxc cluster1 >/dev/null 2>&1; then
  warn "CR cluster1 van con sau helm uninstall — go finalizer va xoa truc tiep."
  kubectl -n production patch pxc cluster1 --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  kubectl -n production delete pxc cluster1 --ignore-not-found --timeout=60s || true
fi
# Don sach StatefulSet/Service do Operator quan ly (phong khi Operator chua
# kip don truoc khi bi go o buoc sau). Namespace production se bi xoa o
# cuoi nen buoc nay chi la bao hiem, khong bat buoc phai thanh cong.
kubectl delete statefulset cluster1-pxc cluster1-proxysql -n production --ignore-not-found || true
kubectl delete svc cluster1-proxysql cluster1-pxc cluster1-pxc-unready -n production --ignore-not-found || true
kubectl delete -f "$ROOT_DIR/k8s/db/pxc-secrets.yaml" --ignore-not-found
kubectl delete -f "$ROOT_DIR/k8s/app/app-secret.yaml" --ignore-not-found

log "Xoa PVC (shared + datadir PXC + proxydata ProxySQL)..."
kubectl delete -f "$ROOT_DIR/k8s/storage/pvc-shared.yaml" --ignore-not-found
kubectl delete pvc datadir-cluster1-pxc-0 proxydata-cluster1-proxysql-0 -n production --ignore-not-found
log "Xoa StorageClass + PV Released con sot lai (reclaimPolicy Retain)..."
kubectl delete -f "$ROOT_DIR/k8s/storage/" --ignore-not-found
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="production")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  kubectl delete pv "$pv" --ignore-not-found || true
done

# Liet ke (va tuy chon xoa) volume Longhorn mo coi — phai lam TRUOC khi go
# Longhorn, vi go Longhorn xong thi CRD volume.longhorn.io khong con nua.
log "Liet ke volume Longhorn mo coi (khong con PV nao tham chieu)..."
if kubectl -n longhorn-system get volume.longhorn.io >/dev/null 2>&1; then
  PV_HANDLES="$(kubectl get pv -o jsonpath='{.items[*].spec.csi.volumeHandle}' 2>/dev/null || true)"
  ORPHANS=""
  for v in $(kubectl -n longhorn-system get volume.longhorn.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    case " $PV_HANDLES " in
      *" $v "*) ;;
      *) ORPHANS="$ORPHANS $v" ;;
    esac
  done
  if [ -z "$ORPHANS" ]; then
    log "Khong co volume Longhorn mo coi."
  elif [ "$CLEAN_ORPHANS" = true ]; then
    log "Xoa volume Longhorn mo coi:$ORPHANS"
    for v in $ORPHANS; do
      kubectl -n longhorn-system delete volume.longhorn.io "$v" --ignore-not-found || true
    done
  else
    warn "Con volume Longhorn mo coi (chiem cho scheduled tren disk, co the lam volume moi bi faulted khi cai lai):$ORPHANS"
    warn "De xoa: kubectl -n longhorn-system delete volume.longhorn.io <ten-volume> — hoac chay lai teardown voi --clean-longhorn-orphans"
  fi
else
  log "Khong thay Longhorn (bo qua buoc liet ke volume mo coi)."
fi

log "Xoa platform (fluent-bit, pxc-operator, longhorn, ingress)..."
helm uninstall fluent-bit -n logging || true
helm uninstall pxc-operator -n pxc-operator || true
helm uninstall longhorn -n longhorn-system || true
helm uninstall ingress-nginx -n ingress-nginx || true

log "Xoa namespace production..."
kubectl delete namespace production --ignore-not-found

log "XONG teardown."
