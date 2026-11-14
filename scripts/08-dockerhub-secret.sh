#!/usr/bin/env bash
# Tao Secret dockerhub-pull de K8s pull image tu repo DockerHub PRIVATE.
# CHI CAN khi repo la private. Repo public thi bo qua script nay —
# K8s pull image public khong can dang nhap.
# Chay tren EC2 TRUOC scripts/05-deploy.sh:
#   DOCKERHUB_USER=<user> ./scripts/08-dockerhub-secret.sh
# Nen dung DockerHub Access Token thay vi mat khau tai khoan:
#   DockerHub -> Account Settings -> Personal Access Tokens -> Generate.
# Co the truyen san qua bien moi truong:
#   DOCKERHUB_USER=<user> DOCKERHUB_TOKEN=<token> ./scripts/08-dockerhub-secret.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

need_cmd kubectl

DOCKERHUB_USER="${DOCKERHUB_USER:-}"
if [ -z "$DOCKERHUB_USER" ]; then
  read -r -p "DockerHub username: " DOCKERHUB_USER
fi
[ -n "$DOCKERHUB_USER" ] || die "Thieu DockerHub username."

DOCKERHUB_PASS="${DOCKERHUB_TOKEN:-${DOCKERHUB_PASSWORD:-}}"
if [ -z "$DOCKERHUB_PASS" ]; then
  read -r -s -p "DockerHub access token (hoac mat khau): " DOCKERHUB_PASS
  echo
fi
[ -n "$DOCKERHUB_PASS" ] || die "Thieu token/mat khau DockerHub."

kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry dockerhub-pull \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="$DOCKERHUB_USER" \
  --docker-password="$DOCKERHUB_PASS" \
  --namespace production \
  --dry-run=client -o yaml | kubectl apply -f -

log "XONG. Secret dockerhub-pull da co trong namespace production."
log "Bay gio chay scripts/05-deploy.sh — script se tu gan imagePullSecrets cho cac Pod."
log "Neu da deploy roi moi tao secret: chay lai scripts/05-deploy.sh de Pod nhan secret."
