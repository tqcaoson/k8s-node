#!/usr/bin/env bash
# Chuan bi EC2 Ubuntu 22.04 duy nhat de lam Kubernetes single-node.
# Chay tren EC2 bang sudo:
#   sudo ./scripts/00-prepare-nodes.sh
# Cai: open-iscsi + nfs-common (Longhorn can), containerd, kubeadm/kubelet/kubectl, helm.
# Docker cai rieng o scripts/02-install-docker.sh (sau khi khoi tao cluster).
set -euo pipefail
source "$(dirname "$0")/common.sh"

K8S_VERSION="${K8S_VERSION:-1.31}"

[ "$(id -u)" -eq 0 ] || die "Hay chay bang sudo: sudo $0"

log "1/6 Tat swap (Kubernetes yeu cau)..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

log "2/6 Kernel modules + sysctl cho Kubernetes..."
cat <<'EOF' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat <<'EOF' > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

log "3/6 Cai open-iscsi + nfs-common (Longhorn can de attach volume va RWX)..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y open-iscsi nfs-common apt-transport-https ca-certificates curl gpg
systemctl enable --now iscsid

log "4/6 Cai containerd..."
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

log "5/6 Cai kubelet, kubeadm, kubectl ${K8S_VERSION}..."
# Repo apt cua K8s da gan theo minor version (v1.31) nen cai khong can ghi version.
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

log "6/6 Cai Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

log "Xong. Kiem tra:"
kubeadm version
kubectl version --client
helm version
ctr version | head -1
