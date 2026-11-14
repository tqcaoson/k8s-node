#!/usr/bin/env bash
# Chuan bi EC2 Amazon Linux 2023 duy nhat de lam Kubernetes single-node.
# Chay tren EC2 bang sudo:
#   sudo ./scripts-al2023/00-prepare-nodes.sh
# Cai: SELinux permissive, iscsi-initiator-utils + nfs-utils (Longhorn can),
# socat/conntrack/iptables (kubeadm can), containerd, kubeadm/kubelet/kubectl,
# helm. AL2023 dung dnf, khong co apt.
# Docker cai rieng o scripts-al2023/02-install-docker.sh (sau khi khoi tao cluster).
set -euo pipefail
source "$(dirname "$0")/common.sh"

K8S_VERSION="${K8S_VERSION:-1.31}"

[ "$(id -u)" -eq 0 ] || die "Hay chay bang sudo: sudo $0"

log "0/7 Cap nhat he thong (dnf)..."
dnf update -y

log "1/7 Tat swap (Kubernetes yeu cau)..."
swapoff -a || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab || true

log "2/7 SELinux sang permissive (kubeadm khong chay duoc khi enforcing)..."
# AL2023 mac dinh SELinux enforcing. kubeadm preflight se loi neu de enforcing.
# Permissive: SELinux van ghi log vi pham nhung khong chan nua.
setenforce 0 || true
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi

log "3/7 Kernel modules + sysctl cho Kubernetes..."
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

log "4/7 Cai iscsi-initiator-utils + nfs-utils (Longhorn can) + goi kubeadm can..."
# Longhorn can iscsid de attach volume (goi iscsi-initiator-utils tren RHEL-family,
# tuong duong open-iscsi tren Ubuntu) va NFS client de mount volume RWX.
# --setopt=tsflags=noscripts theo huong dan cua Longhorn cho RHEL-family.
dnf --setopt=tsflags=noscripts install -y iscsi-initiator-utils
dnf install -y nfs-utils socat conntrack-tools iptables iproute-tc
systemctl enable --now iscsid

log "5/7 Cai containerd..."
dnf install -y containerd
mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

log "6/7 Cai kubelet, kubeadm, kubectl ${K8S_VERSION} (repo RPM cua Kubernetes)..."
# Repo RPM cua K8s gan theo minor version (v1.31) nen cai khong can ghi version.
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
dnf install -y kubelet kubeadm kubectl
# Khoa version (tuong duong apt-mark hold tren Ubuntu): dnf update se khong
# tu nang cap K8s len minor khac. Can plugin versionlock (chua co san tren AL2023).
dnf install -y 'dnf-command(versionlock)'
dnf versionlock add kubelet kubeadm kubectl
systemctl enable kubelet

log "7/7 Cai Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

log "Xong. Kiem tra:"
kubeadm version
kubectl version --client
helm version
ctr version | head -1
getenforce
systemctl is-active iscsid containerd

echo
log "Buoc tiep: sudo ./scripts-al2023/01-init-control-plane.sh (khoi tao cluster)"

