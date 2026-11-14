#!/usr/bin/env bash
# Cai Docker Engine tren EC2 de build + push image app len DockerHub
# (scripts/04-build-push.sh chay tren chinh EC2 nay).
# Chay bang sudo sau scripts/01:
#   sudo ./scripts/02-install-docker.sh
# Dung goi docker.io cua Ubuntu (da phu hop voi containerd cai o buoc 00,
# khong doi runtime cua Kubernetes). Sau khi cai xong, dang xuat SSH roi
# dang nhap lai (hoac chay `newgrp docker`) de dung docker khong can sudo.
set -euo pipefail
source "$(dirname "$0")/common.sh"

K8S_USER="${SUDO_USER:-ubuntu}"

[ "$(id -u)" -eq 0 ] || die "Hay chay bang sudo: sudo $0"

log "Cai docker.io..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
systemctl enable --now docker

log "Them user $K8S_USER vao nhom docker..."
usermod -aG docker "$K8S_USER" || true

log "Kiem tra:"
docker --version
docker info --format 'Docker dang chay, storage driver: {{.Driver}}' 2>/dev/null || true

echo
log "XONG. Dang xuat SSH roi dang nhap lai (hoac chay 'newgrp docker')"
log "de dung lenh docker khong can sudo, roi chay scripts/04-build-push.sh."
