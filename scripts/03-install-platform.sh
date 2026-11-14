#!/usr/bin/env bash
# Cai nen tang bang Helm tren EC2 (khong can sudo, can kubectl + helm):
#   ./scripts/03-install-platform.sh
# Gom: NGINX Ingress, Longhorn, PXC Operator, Fluent Bit.
# INGRESS_TYPE: NodePort (mac dinh, dung cho EC2 kubeadm vi khong co cloud
#   controller de cap LoadBalancer) hoac LoadBalancer (neu da cai AWS CCM).
set -euo pipefail
source "$(dirname "$0")/common.sh"

INGRESS_TYPE="${INGRESS_TYPE:-NodePort}"
INGRESS_CHART_VERSION="${INGRESS_CHART_VERSION:-4.12.1}"
LONGHORN_CHART_VERSION="${LONGHORN_CHART_VERSION:-1.9.0}"
PXC_OPERATOR_CHART_VERSION="${PXC_OPERATOR_CHART_VERSION:-1.17.0}"
FLUENT_BIT_CHART_VERSION="${FLUENT_BIT_CHART_VERSION:-0.48.0}"

need_cmd kubectl
need_cmd helm

# Fail nhanh neu kubectl chua noi duoc cluster (vd chua chay 01, hoac
# kubeconfig sai) — tranh chay helm roi moi loi kho hieu.
kubectl cluster-info >/dev/null 2>&1 || die "kubectl khong noi duoc cluster. Kiem tra: kubectl cluster-info; kubeconfig o ~/.kube/config (da chay 01-init-control-plane.sh chua?)"

log "0/5 Them Helm repo..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn https://charts.longhorn.io
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

log "1/5 Cai NGINX Ingress Controller ($INGRESS_TYPE, 1 replica)..."
INGRESS_ARGS=(--namespace ingress-nginx --create-namespace
  --version "$INGRESS_CHART_VERSION"
  --set controller.replicaCount=1
  --set controller.service.type="$INGRESS_TYPE")
if [ "$INGRESS_TYPE" = "NodePort" ]; then
  # Co dinh cong NodePort de mo Security Group truoc duoc: HTTP 30080, HTTPS 30443.
  INGRESS_ARGS+=(--set controller.service.nodePorts.http=30080
    --set controller.service.nodePorts.https=30443)
fi
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx "${INGRESS_ARGS[@]}"
wait_pods_ready ingress-nginx app.kubernetes.io/component=controller 600s

log "2/5 Cai Longhorn (defaultReplicaCount=1 — single-node)..."
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version "$LONGHORN_CHART_VERSION" \
  --set defaultSettings.defaultReplicaCount=1
wait_pods_ready longhorn-system app=longhorn-manager 600s

log "3/5 Cai PXC Operator..."
# watchAllNamespaces=true la BAT BUOC: mac dinh Operator chi theo doi namespace
# cua chinh no (WATCH_NAMESPACE=pxc-operator), CR cluster1 nam o namespace
# production se bi bo qua hoan toan (STATUS trong, khong co event, khong Pod).
helm upgrade --install pxc-operator percona/pxc-operator \
  --namespace pxc-operator --create-namespace \
  --version "$PXC_OPERATOR_CHART_VERSION" \
  --set watchAllNamespaces=true
wait_pods_ready pxc-operator app.kubernetes.io/name=pxc-operator 300s

log "4/5 Cai Fluent Bit (DaemonSet thu log)..."
helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace logging --create-namespace \
  --version "$FLUENT_BIT_CHART_VERSION" \
  -f "$ROOT_DIR/k8s/logging/fluent-bit-values.yaml"
kubectl rollout status daemonset/fluent-bit -n logging --timeout=300s || true

log "5/5 Giam CoreDNS ve 1 replica (giai phong 100m CPU cho cau hinh nho)..."
# CoreDNS mac dinh 2 replica, moi replica xin 100m CPU. Node chi co 2 CPU
# ma he thong (Longhorn/Calico/control-plane/Ingress) da dung ~1490m, cau
# hinh nho can tiet kiem tung chut — 1 replica la du cho test (mat CoreDNS
# thi DNS dung cho toi khi Pod khoi dong lai).
kubectl -n kube-system scale deployment coredns --replicas=1

echo
log "XONG nen tang."
kubectl get pods -n ingress-nginx
kubectl get pods -n longhorn-system | head -8
kubectl get pods -n pxc-operator
if [ "$INGRESS_TYPE" = "NodePort" ]; then
  log "Ingress NodePort: HTTP 30080, HTTPS 30443 tren bat ky node nao."
  log "Buoc tiep: build/push image (scripts/04) roi deploy (scripts/05)."
fi
