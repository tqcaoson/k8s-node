#!/usr/bin/env bash
# Build Docker image va push len registry de K8s pull ve.
# Chay tren chinh EC2 (Docker da cai o scripts-al2023/02):
#   export IMAGE=<dockerhub-user>/k8s-web-demo:v1
#   docker login
#   ./scripts-al2023/04-build-push.sh
# Dung ECR: xem HUONG-DAN-SETUP.md muc 4 (IMAGE dang
#   <account-id>.dkr.ecr.<region>.amazonaws.com/k8s-web-demo:v1).
set -euo pipefail
source "$(dirname "$0")/common.sh"

need_cmd docker
# Neu vua cai Docker o buoc 02 ma chua dang xuat/dang nhap lai (hoac newgrp
# docker), user chua vao nhom docker — docker build se loi permission denied.
docker info >/dev/null 2>&1 || die "Khong chay duoc docker (quyen bi tu choi?). Hay dang xuat SSH roi dang nhap lai, hoac chay 'newgrp docker', roi chay lai script nay."
[ -n "${IMAGE:-}" ] || die "Chua dat bien IMAGE. VD: export IMAGE=<dockerhub-user>/k8s-web-demo:v1"
case "$IMAGE" in
  */*) ;;
  *) die "IMAGE phai co registry/user (VD: <dockerhub-user>/k8s-web-demo:v1). Hien tai: $IMAGE" ;;
esac

log "Build image $IMAGE..."
docker build -t "$IMAGE" "$ROOT_DIR/app"

log "Push image $IMAGE..."
docker push "$IMAGE"

log "XONG. Buoc tiep: IMAGE=$IMAGE ./scripts-al2023/05-deploy.sh"
