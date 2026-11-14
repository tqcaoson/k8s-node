#!/usr/bin/env bash
# Deploy toan bo ung dung len K8s theo dung thu tu cua guide:
# namespace -> StorageClass/PVC -> PXC cluster -> db-init -> app-secret
# -> migrate/seed -> web (Deployment/Service/Ingress/HPA) -> CronJob
# (-> NetworkPolicy neu truyen --with-netpol).
#
# Chay tren EC2:
#   IMAGE=<dockerhub-user>/k8s-web-demo:v1 ./scripts/05-deploy.sh [--with-netpol]
#   DOMAIN=app.example.com IMAGE=... ./scripts/05-deploy.sh   # neu co domain that
# Neu khong truyen DOMAIN, script tu lay IP public cua EC2 va dung
# <ip>.nip.io (khong can mua domain, DNS nip.io tu phan giai ve IP do).
set -euo pipefail
source "$(dirname "$0")/common.sh"

PXC_DB_CHART_VERSION="${PXC_DB_CHART_VERSION:-1.17.0}"
WITH_NETPOL=false
for arg in "$@"; do
  case "$arg" in
    --with-netpol) WITH_NETPOL=true ;;
    *) die "Tham so khong biet: $arg (chi ho tro --with-netpol)" ;;
  esac
done

need_cmd kubectl
need_cmd helm
[ -n "${IMAGE:-}" ] || die "Chua dat bien IMAGE (image da push o buoc 04). VD: IMAGE=<dockerhub-user>/k8s-web-demo:v1 $0"

# --- Xac dinh domain ---
if [ -z "${DOMAIN:-}" ]; then
  PUBLIC_IP="$(curl -fsSL --max-time 10 ifconfig.me 2>/dev/null || true)"
  if [ -n "$PUBLIC_IP" ]; then
    DOMAIN="$(echo "$PUBLIC_IP" | tr '.' '-').nip.io"
    log "Khong truyen DOMAIN — dung nip.io theo IP public cua EC2: $DOMAIN"
  else
    DOMAIN="app.example.com"
    warn "Khong lay duoc IP public — dung $DOMAIN. Hay them vao /etc/hosts: <IP-node> $DOMAIN"
  fi
fi

# Render manifest: thay image placeholder va host placeholder.
# Neu da co Secret dockerhub-pull (repo DockerHub private — tao bang
# scripts/08-dockerhub-secret.sh), chen imagePullSecrets vao Pod spec;
# neu khong thi xoa dong marker (repo public pull khong can auth).
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
HAS_PULL_SECRET=""
render() { # render <file-goc> <file-dich>
  if [ -z "$HAS_PULL_SECRET" ]; then
    if kubectl -n production get secret dockerhub-pull >/dev/null 2>&1; then
      HAS_PULL_SECRET=yes
      log "Da thay Secret dockerhub-pull — se gan imagePullSecrets cho cac Pod."
    else
      HAS_PULL_SECRET=no
    fi
  fi
  if [ "$HAS_PULL_SECRET" = yes ]; then
    sed -e "s|my-nodejs-app:v1|${IMAGE}|g" -e "s|app.example.com|${DOMAIN}|g" \
      -e "s|^\( *\)# __IMAGE_PULL_SECRETS__$|\1imagePullSecrets:\n\1  - name: dockerhub-pull|" \
      "$1" > "$2"
  else
    sed -e "s|my-nodejs-app:v1|${IMAGE}|g" -e "s|app.example.com|${DOMAIN}|g" \
      -e "/# __IMAGE_PULL_SECRETS__/d" "$1" > "$2"
  fi
}

log "=== 1/7 Namespace + StorageClass + Shared PVC ==="
kubectl apply -f "$ROOT_DIR/k8s/00-namespace.yaml"
kubectl apply -f "$ROOT_DIR/k8s/storage/storageclass-db.yaml"
kubectl apply -f "$ROOT_DIR/k8s/storage/storageclass-shared.yaml"
kubectl apply -f "$ROOT_DIR/k8s/storage/pvc-shared.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/shared-data -n production --timeout=300s
log "PVC shared-data: Bound."

log "=== 2/7 PXC cluster (3 MySQL Pod + 2 HAProxy) ==="
kubectl apply -f "$ROOT_DIR/k8s/db/pxc-secrets.yaml"
helm upgrade --install cluster1 percona/pxc-db \
  --namespace production \
  --version "$PXC_DB_CHART_VERSION" \
  -f "$ROOT_DIR/k8s/db/pxc-values.yaml"
log "Doi PXC Ready (co the mat 5-15 phut lan dau, PXC phai khoi tao Galera)..."
for i in $(seq 1 90); do
  STATE="$(kubectl -n production get pxc cluster1 -o jsonpath='{.status.state}' 2>/dev/null || echo '')"
  if [ "$STATE" = "Ready" ]; then
    log "PXC Ready."
    break
  fi
  [ $((i % 6)) -eq 0 ] && log "... dang cho PXC (trang thai hien tai: ${STATE:-chua co}, lan $i/90)"
  sleep 10
  [ "$i" -eq 90 ] && die "PXC chua Ready sau 15 phut. Kiem tra: kubectl -n production get pxc,pods,pvc"
done

log "=== 3/7 Tao database appdb + user app (Job db-init) ==="
kubectl apply -f "$ROOT_DIR/k8s/app/app-secret.yaml"
kubectl delete job db-init -n production --ignore-not-found
render "$ROOT_DIR/k8s/db/db-init-job.yaml" "$RENDER_DIR/db-init-job.yaml"
kubectl apply -f "$RENDER_DIR/db-init-job.yaml"
wait_job_complete production db-init 600s

log "=== 4/7 Migrate + seed bang tasks (Job db-migrate) ==="
kubectl delete job db-migrate -n production --ignore-not-found
render "$ROOT_DIR/k8s/db/migrate-job.yaml" "$RENDER_DIR/migrate-job.yaml"
kubectl apply -f "$RENDER_DIR/migrate-job.yaml"
wait_job_complete production db-migrate 600s
kubectl logs -n production job/db-migrate --tail=5

log "=== 5/7 Deploy web (Deployment/Service/Ingress/HPA) ==="
render "$ROOT_DIR/k8s/app/web-deployment.yaml" "$RENDER_DIR/web-deployment.yaml"
render "$ROOT_DIR/k8s/app/web-ingress.yaml" "$RENDER_DIR/web-ingress.yaml"
kubectl apply -f "$RENDER_DIR/web-deployment.yaml"
kubectl apply -f "$ROOT_DIR/k8s/app/web-service.yaml"
kubectl apply -f "$RENDER_DIR/web-ingress.yaml"
kubectl apply -f "$ROOT_DIR/k8s/app/web-hpa.yaml"
kubectl wait --for=condition=Available deployment/nodejs-web -n production --timeout=300s
log "Web Available."

log "=== 6/7 CronJob dispatcher + RBAC ==="
render "$ROOT_DIR/k8s/worker/worker-cronjob.yaml" "$RENDER_DIR/worker-cronjob.yaml"
kubectl apply -f "$ROOT_DIR/k8s/worker/dispatcher-rbac.yaml"
kubectl apply -f "$RENDER_DIR/worker-cronjob.yaml"

if [ "$WITH_NETPOL" = true ]; then
  log "=== 7/7 NetworkPolicy (theo yeu cau --with-netpol) ==="
  kubectl apply -f "$ROOT_DIR/k8s/networkpolicy/"
else
  log "=== 7/7 Bo qua NetworkPolicy (mac dinh) ==="
  log "Hay kiem tra web chay on truoc, roi bat sau: kubectl apply -f k8s/networkpolicy/"
fi

echo
HTTP_PORT="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo 30080)"
log "XONG. Mo web tai:  http://${DOMAIN}:${HTTP_PORT}"
log "Kiem tra nhanh:    curl -H 'Host: ${DOMAIN}' http://127.0.0.1:${HTTP_PORT}/readyz"
log "Kiem tra day du:   ./scripts/06-verify.sh"
kubectl -n production get pxc,pods,pvc,svc,ingress,hpa,cronjob
