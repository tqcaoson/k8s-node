#!/usr/bin/env bash
# Cai Docker Engine tren EC2 Amazon Linux 2023 de build + push image app
# len DockerHub (scripts-al2023/04-build-push.sh chay tren chinh EC2 nay).
# Chay bang sudo sau scripts-al2023/01:
#   sudo ./scripts-al2023/02-install-docker.sh
# Dung goi docker co san trong repo AL2023 (dung chung containerd cai o
# buoc 00, khong doi runtime cua Kubernetes). Sau khi cai xong, dang xuat
# SSH roi dang nhap lai (hoac chay `newgrp docker`) de dung docker khong
# can sudo.
set -euo pipefail
source "$(dirname "$0")/common.sh"

K8S_USER="${SUDO_USER:-ec2-user}"

[ "$(id -u)" -eq 0 ] || die "Hay chay bang sudo: sudo $0"

log "Cai docker (repo AL2023)..."
dnf install -y docker
systemctl enable --now docker

log "Them user $K8S_USER vao nhom docker..."
usermod -aG docker "$K8S_USER" || true

log "Kiem tra:"
docker --version
docker info --format 'Docker dang chay, storage driver: {{.Driver}}' 2>/dev/null || true

echo
log "XONG. Dang xuat SSH roi dang nhap lai (hoac chay 'newgrp docker')"
log "de dung lenh docker khong can sudo, roi chay scripts-al2023/03-install-platform.sh."

