#!/usr/bin/env bash
# Khoi tao Kubernetes single-node bang kubeadm, cai Calico (CNI ho tro
# NetworkPolicy) va metrics-server (HPA can). Chi chay 1 lan tren EC2:
#   sudo ./scripts-al2023/01-init-control-plane.sh
# Vi chi co 1 node, script go bo taint cua control-plane de Pod ung dung
# (web, PXC, Longhorn...) chay duoc ngay tren node nay. Khong co worker
# rieng, khong co lenh kubeadm join.
set -euo pipefail
source "$(dirname "$0")/common.sh"

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CALICO_VERSION="${CALICO_VERSION:-v3.29.0}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"
K8S_USER="${SUDO_USER:-ec2-user}"

[ "$(id -u)" -eq 0 ] || die "Hay chay bang sudo: sudo $0"

# Neu cluster da duoc khoi tao roi, kubeadm init se loi — bao ro thay vi
# de user doc log kubeadm. Muon lam lai tu dau: kubeadm reset (xem guide muc Go bo).
if [ -f /etc/kubernetes/admin.conf ] && kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes >/dev/null 2>&1; then
  die "Cluster da duoc khoi tao roi (da co /etc/kubernetes/admin.conf). Bo qua buoc nay, chay tiep 02-install-docker.sh. Neu muon khoi tao lai: kubeadm reset --force, xoa /etc/cni/net.d, roi chay lai script nay."
fi

# EC2: advertise bang IP private (API server lang nghe tren mang noi bo cua VPC).
ADVERTISE_ADDRESS="${ADVERTISE_ADDRESS:-$(hostname -I | awk '{print $1}')}"
export KUBECONFIG=/etc/kubernetes/admin.conf

log "1/5 kubeadm init (pod CIDR $POD_CIDR, advertise $ADVERTISE_ADDRESS)..."
kubeadm init --pod-network-cidr="$POD_CIDR" --apiserver-advertise-address="$ADVERTISE_ADDRESS"

log "2/5 Copy kubeconfig cho user $K8S_USER..."
mkdir -p "/home/$K8S_USER/.kube"
cp /etc/kubernetes/admin.conf "/home/$K8S_USER/.kube/config"
chown "$K8S_USER:$K8S_USER" "/home/$K8S_USER/.kube/config"

log "3/5 Cai Calico $CALICO_VERSION (CNI ho tro NetworkPolicy)..."
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
# Operator cai CRD Installation khong dong bo (Pod operator khoi dong xong
# moi dang ky CRD). Phai doi CRD xuat hien + Established roi moi apply
# custom-resources, neu khong se loi "no matches for kind Installation".
log "Doi CRD Installation cua Calico (toi da ~150s)..."
for i in $(seq 1 30); do
  kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && die "CRD installations.operator.tigera.io khong xuat hien sau 150s. Kiem tra: kubectl -n tigera-operator get pods"
  sleep 5
done
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=120s
curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
  | sed "s|192.168.0.0/16|${POD_CIDR}|" \
  | kubectl create -f -

log "4/5 Cai metrics-server $METRICS_SERVER_VERSION (HPA can)..."
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# Tren kubeadm, kubelet dung cert tu ky — can flag nay de metrics-server noi duoc.
kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

log "5/5 Go taint control-plane (cho Pod chay tren node duy nhat) + doi Ready..."
# Mac dinh kubeadm cam Pod thuong chay tren control-plane. Chi co 1 node
# nen phai go taint nay, neu khong moi Pod ung dung se Pending mai.
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
kubectl wait --for=condition=Ready node --all --timeout=300s

echo
log "XONG single-node cluster."
kubectl get nodes
log "Buoc tiep: sudo ./scripts-al2023/02-install-docker.sh (cai Docker de build image)"
