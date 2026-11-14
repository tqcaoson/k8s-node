#!/usr/bin/env bash
# Build Docker image va push len registry de K8s pull ve.
# Chay tren chinh EC2 (Docker da cai o scripts/02):
#   export IMAGE=<dockerhub-user>/k8s-web-demo:v1
#   docker login
#   ./scripts/04-build-push.sh
# Dung ECR: xem HUONG-DAN-SETUP.md muc 4 (IMAGE dang
#   <account-id>.dkr.ecr.<region>.amazonaws.com/k8s-web-demo:v1).
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Fail nhanh neu chua cai Docker (loi thuong gap: bo qua buoc 02 roi chay
# thang script nay) — bao ro phai chay buoc nao thay vi loi mo ho o docker build.
command -v docker >/dev/null 2>&1 || die "Thieu lenh 'docker' — ban da bo qua buoc 02. Hay chay: sudo ./scripts/02-install-docker.sh, dang xuat/dang nhap lai SSH (hoac 'newgrp docker'), roi chay lai script nay."
[ -n "${IMAGE:-}" ] || die "Chua dat bien IMAGE. VD: export IMAGE=<dockerhub-user>/k8s-web-demo:v1"
case "$IMAGE" in
  */*) ;;
  *) die "IMAGE phai co registry/user (VD: <dockerhub-user>/k8s-web-demo:v1). Hien tai: $IMAGE" ;;
esac

log "Build image $IMAGE..."
docker build -t "$IMAGE" "$ROOT_DIR/app"

log "Push image $IMAGE..."
docker push "$IMAGE"

log "XONG. Buoc tiep: IMAGE=$IMAGE ./scripts/05-deploy.sh"
