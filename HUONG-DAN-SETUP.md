# Hướng dẫn setup đầy đủ trên 1 EC2 — Kubernetes Native Web Platform

Guide này đi theo hướng **làm tay từng bước để hiểu Kubernetes**: mỗi mục
chạy từng lệnh một, kèm giải thích lệnh đó làm gì, tại sao cần, và kiểm tra
kết quả ra sao. Làm xong từ đầu tới cuối bạn sẽ có web chạy được trên EC2,
thao tác được database thật (PXC MySQL Galera), và task tạo ra được CronJob
tự động lấy đi xử lý bằng K8s Job.

Toàn bộ chạy trên **1 EC2 duy nhất**: cài K8s, cài Docker để build image
rồi push lên DockerHub, K8s pull image về chạy.

Giả thiết: bạn đã có sẵn 1 EC2 Ubuntu 22.04 rỗng + Security Group
(phần này bạn tự lo — yêu cầu cụ thể ở mục 1). Mọi env, mật khẩu test,
tên database đã fix sẵn trong project — chỉ còn 1 thứ bạn phải tự điền:
**`IMAGE`** — tên image trên DockerHub của bạn.

## Hai cách đi qua guide này

| Cách | Dành cho ai | Làm thế nào |
| --- | --- | --- |
| **Làm tay (chính)** | Muốn hiểu K8s — đây là cách guide này viết | Chạy từng lệnh trong mỗi mục theo thứ tự, đọc phần giải thích và kiểm tra sau mỗi bước |
| **Chạy script (lối tắt)** | Muốn dựng nhanh, hoặc chạy lại từ đầu | Mỗi mục đều có dòng `→ Chạy nhanh` ghi script tương ứng. Script làm đúng các bước trong mục đó — mở file script ra đối chiếu với lệnh tay để hiểu thêm |

Bảng đối chiếu mục ↔ script nằm ở Phụ lục B. Hai cách cho ra cùng một kết
quả và có thể trộn lẫn: ví dụ làm tay mục 2 để hiểu kubeadm, rồi chạy
script mục 3 cho nhanh.

> ⚠️ Toàn bộ mật khẩu trong project là **test-only** (ghi rõ ở mục 0).
> Đừng dùng cho production, đừng commit Secret lên Git public.
>
> ⚠️ Single-node chỉ để **test chức năng**, không có HA thật: 3 Pod PXC
> cùng nằm trên 1 node, Longhorn replica 1. Mất node là mất cả cụm.

**Quy ước trong guide:** lệnh có `sudo` thì chạy với quyền root. Lệnh
`kubectl`/`helm`/`docker` chạy bằng user thường `ubuntu` (không sudo).
Sau mỗi khối lệnh quan trọng đều có mục **Kiểm tra** — đừng bỏ qua, vì
đó là cách bạn biết bước vừa rồi có thật sự chạy đúng không.

---

## 0. Những gì đã fix sẵn

| Hạng mục | Giá trị cố định | File |
| --- | --- | --- |
| Namespace | `production` | `k8s/00-namespace.yaml` |
| Database / user app | `appdb` / `app` / `AppPass123!` | `k8s/app/app-secret.yaml` |
| DB host trong cluster | `cluster1-haproxy.production.svc.cluster.local:3306` | `k8s/app/app-secret.yaml` |
| PXC root | `PxcRoot123!` | `k8s/db/pxc-secrets.yaml` |
| PXC nội bộ | xtrabackup `PxcXtra123!`, monitor `PxcMon123!`, clustercheck `PxcCheck123!`, proxyadmin `PxcProxy123!`, operator `PxcOper123!`, replication `PxcRepl123!` | `k8s/db/pxc-secrets.yaml` |
| Bảng demo | `tasks` (id, title, description, status, created_at, updated_at) | `app/db/migrate.sql` |
| Seed | 5 công việc mẫu, id 1–5 | `app/db/seed.sql` |
| Shared PVC | `shared-data`, RWX, 5Gi | `k8s/storage/pvc-shared.yaml` |
| Mỗi MySQL PVC | RWO, 10Gi, Longhorn 1 replica (single-node) | `k8s/db/pxc-values.yaml` |
| Xử lý task | CronJob dispatcher mỗi 5 phút, 1 K8s Job / task | `app/src/worker.js`, `app/src/process-task.js` |
| Ingress | NodePort HTTP **30080**, HTTPS **30443** | `scripts/03-install-platform.sh` |
| Domain mặc định | `<IP-public-EC2>.nip.io` (tự sinh ở mục 5, không cần mua domain) | `k8s/app/web-ingress.yaml` |
| Image placeholder | `my-nodejs-app:v1` (thay bằng `$IMAGE` ở mục 5) | `k8s/app/web-deployment.yaml` |

Các khác biệt so với guide gốc (đã ghi chú trong từng file):
**single-node thay vì 4 node** (gỡ taint control-plane, bỏ anti-affinity
hostname của PXC/HAProxy, Longhorn replica 1), PVC test nhỏ lại (5Gi/10Gi
thay vì 100Gi), PXC limits 1 CPU/2Gi thay vì 2 CPU/4Gi, Ingress NodePort
thay vì LoadBalancer (kubeadm trên EC2 không có cloud controller để cấp
LoadBalancer), backup tắt mặc định, thêm Job `db-init` + `db-migrate` để
khỏi chạy tay lệnh MySQL, thêm **dispatcher** (CronJob lấy task `todo`,
tạo K8s Job xử lý từng task), tách probe (readiness `/readyz` kiểm tra
MySQL, liveness `/healthz` chỉ kiểm tra process), và sửa 2 lỗi
NetworkPolicy (rule tới Operator thiếu `namespaceSelector`, HAProxy thiếu
egress tới PXC).

---

## 1. EC2 yêu cầu (bạn tự tạo trước)

Chỉ cần **1 EC2 duy nhất**. Yêu cầu:

| Hạng mục | Yêu cầu |
| --- | --- |
| OS | Ubuntu 22.04 LTS, rỗng (chưa cài gì) |
| Loại instance | **t3.xlarge** (4 vCPU, 16 GB) trở lên — 3 Pod PXC + Longhorn + web + ingress cùng chạy trên 1 node nên t3.large (8 GB) sẽ chật. Có điều kiện thì dùng t3.2xlarge cho thoải mái |
| Disk | 50 GB gp3 trở lên (Longhorn dùng thư mục `/var/lib/longhorn` trên disk root) |
| Public IP | Có (để SSH và để truy cập web qua NodePort) |
| Security Group | Mở **22** (SSH) và **30080, 30443** (Ingress NodePort HTTP/HTTPS) từ IP của bạn (hoặc 0.0.0.0/0 nếu muốn mở rộng). Không cần mở thêm cổng nào khác vì chỉ có 1 node. **Đừng mở 3306** — MySQL chỉ truy cập trong cluster |

### Copy project lên EC2

```bash
# Tren may local (thu muc chua project):
scp -i <key.pem> -r k8s-native-web-platform ubuntu@<IP-EC2>:~/
ssh -i <key.pem> ubuntu@<IP-EC2>
cd ~/k8s-native-web-platform
chmod +x scripts/*.sh
```

Từ đây trở đi, mọi lệnh đều chạy trên EC2 này.

---

## 2. Cài Kubernetes cluster single-node (kubeadm) + Docker

Mục này dựng cluster từ con số 0 trên EC2 rỗng. Các bước theo đúng thứ tự
kubeadm yêu cầu: chuẩn bị hệ thống → cài container runtime → cài công cụ
K8s → `kubeadm init` → cài CNI → cài metrics-server → gỡ taint → cài Docker.

### 2.1. Tắt swap

**Tại sao:** kubelet mặc định từ chối chạy khi swap đang bật. Lý do là
Kubernetes quản lý bộ nhớ bằng cgroup limits — nếu hệ thống swap ra disk,
kubelet không còn đo và giới hạn được RAM thật của Pod, scheduler sẽ xếp
Pod sai. Muốn bật swap thì phải cấu hình riêng, còn mặc định là tắt.

```bash
sudo swapoff -a
# Xoa swap khoi /etc/fstab de reboot xong swap khong bat lai:
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**Kiểm tra:** `free -h` — cột Swap phải hiện `0B`. `grep swap /etc/fstab`
phải chỉ còn dòng đã bị comment (`#` ở đầu).

→ Chạy nhanh: bước này nằm trong `sudo ./scripts/00-prepare-nodes.sh`.

### 2.2. Bật kernel module và sysctl cho Kubernetes

**Tại sao:** Pod giao tiếp qua Linux bridge (cầu nối mạng ảo). Hai module
`overlay` (filesystem cho container) và `br_netfilter` (để iptables
nhìn thấy traffic đi qua bridge) là điều kiện để CNI và kube-proxy hoạt
động. Ba tham số sysctl: 2 dòng `bridge-nf-call-iptables/ip6tables` cho
phép iptables lọc traffic qua bridge (kube-proxy và NetworkPolicy dựa
vào đó), `ip_forward` cho phép node chuyển tiếp gói tin giữa các Pod.

```bash
# Module tu load lai moi lan reboot:
sudo tee /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl ap dung ngay va giu lai sau reboot:
sudo tee /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

**Kiểm tra:** `lsmod | grep -E 'overlay|br_netfilter'` phải thấy 2 module.
`sysctl net.ipv4.ip_forward` phải trả về `= 1`.

→ Chạy nhanh: `sudo ./scripts/00-prepare-nodes.sh`.

### 2.3. Cài open-iscsi và nfs-common (Longhorn cần)

**Tại sao:** Longhorn gắn volume vào node bằng giao thức iSCSI nên cần
`open-iscsi` (dịch vụ `iscsid` phải chạy). Volume RWX của Longhorn thực
chất là một NFS server chạy trong cluster (share-manager), node cần
`nfs-common` để mount được NFS. Thiếu 2 gói này, PVC sẽ kẹt ở `Pending`
mãi ở mục 5 mà lỗi rất khó đoán — nên cài ngay từ đầu.

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  open-iscsi nfs-common apt-transport-https ca-certificates curl gpg
sudo systemctl enable --now iscsid
```

**Kiểm tra:** `systemctl status iscsid --no-pager | head -3` phải thấy
`active (running)`.

→ Chạy nhanh: `sudo ./scripts/00-prepare-nodes.sh`.

### 2.4. Cài containerd (container runtime)

**Tại sao:** kubelet không tự chạy container — nó gọi một runtime qua CRI
(Container Runtime Interface). `containerd` là runtime chuẩn cho kubeadm
(Docker đã không còn làm CRI trực tiếp từ K8s 1.24 — Docker chỉ còn dùng
để build image ở mục 4, còn chạy Pod là việc của containerd).

Điểm quan trọng nhất ở bước này là **cgroup driver**: kubelet dùng
`systemd` làm cgroup driver, nên containerd cũng phải dùng `systemd`
(`SystemdCgroup = true`). Hai bên lệch driver nhau là kubelet crash
ngay khi khởi động — lỗi này rất hay gặp khi cài tay.

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y containerd
sudo mkdir -p /etc/containerd
# Sinh file cau hinh mac dinh, chi doi SystemdCgroup false -> true:
sudo containerd config default \
  | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /tmp/config.toml
sudo mv /tmp/config.toml /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Kiểm tra:** `grep SystemdCgroup /etc/containerd/config.toml` phải thấy
`SystemdCgroup = true`. `sudo systemctl status containerd --no-pager | head -3`
phải thấy `active (running)`. `ctr version` in ra version containerd.

→ Chạy nhanh: `sudo ./scripts/00-prepare-nodes.sh`.

### 2.5. Cài kubelet, kubeadm, kubectl 1.31

**Ba công cụ này khác nhau thế nào:**
- `kubelet` — agent chạy trên node, nhận lệnh từ API server để chạy/dừng Pod.
- `kubeadm` — công cụ dựng cluster (chỉ dùng lúc setup).
- `kubectl` — công cụ dòng lệnh để bạn nói chuyện với cluster.

Repo apt của Kubernetes gắn theo minor version (`v1.31`), nên cài không
cần ghi version — repo đó chỉ chứa 1.31.x. `apt-mark hold` giữ apt không
tự nâng cấp 3 gói này lên minor version khác (nâng cấp K8s phải làm chủ
động từng minor một, không để apt tự động).

```bash
# Them key + repo apt chinh thuc cua Kubernetes (K8s 1.31):
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
```

**Kiểm tra:** `kubeadm version`, `kubectl version --client`,
`kubelet --version` đều in ra 1.31.x. Lưu ý: lúc này kubelet chưa chạy
được (chưa có cluster) nên `systemctl status kubelet` sẽ thấy nó restart
liên tục — đó là bình thường, nó sẽ chạy ổn sau `kubeadm init`.

→ Chạy nhanh: `sudo ./scripts/00-prepare-nodes.sh`.

### 2.6. Cài Helm

**Tại sao:** Helm là "package manager" của Kubernetes — thay vì viết hàng
chục file YAML cho NGINX Ingress hay Longhorn, bạn cài một **chart**
( gói template có sẵn) và chỉnh vài giá trị. Ở mục 3 bạn sẽ dùng Helm để
cài toàn bộ nền tảng. Một **release** là một lần cài đặt của một chart
(ví dụ release `longhorn` trong namespace `longhorn-system`).

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Kiểm tra:** `helm version` in ra version 3.x.

→ Chạy nhanh: `sudo ./scripts/00-prepare-nodes.sh`.

### 2.7. Khởi tạo cluster: kubeadm init

**Lệnh này làm gì:** `kubeadm init` dựng toàn bộ control-plane trên máy
này: tạo chứng chỉ (CA), chạy etcd (nơi lưu mọi trạng thái cluster),
kube-apiserver (cửa ngõ duy nhất để nói chuyện với cluster),
kube-controller-manager, kube-scheduler, và sinh file kubeconfig admin.
Hai flag quan trọng:

- `--pod-network-cidr=10.244.0.0/16` — dải IP cấp cho Pod. Con số này
  **phải khớp** với cấu hình Calico ở mục 2.9 (mặc định Calico dùng
  `192.168.0.0/16`, nên phải sửa lại cho khớp — bạn sẽ làm ở mục 2.9).
- `--apiserver-advertise-address` — IP mà API server lắng nghe. Trên EC2
  lấy IP private đầu tiên của máy (`hostname -I`).

```bash
# Xem IP private cua may (lay IP dau tien):
hostname -I
# Thay <IP-private> bang IP vua thay, roi init:
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=<IP-private>
```

Lệnh chạy khoảng 1–2 phút. Cuối output có đoạn `Your Kubernetes
control-plane has initialized successfully!` và một lệnh `kubeadm join`
— **bỏ qua lệnh join** vì ta chỉ có 1 node, không có worker nào để join.

**Kiểm tra:** `sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes`
— node hiện `NotReady` là đúng lúc này (chưa có CNI, Pod mạng chưa chạy).
`sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system`
phải thấy các Pod `etcd`, `kube-apiserver`, `kube-controller-manager`,
`kube-scheduler`, `coredns` (CoreDNS có thể đang `Pending` vì chưa có CNI).

→ Chạy nhanh: `sudo ./scripts/01-init-control-plane.sh`.

### 2.8. Cấu hình kubectl cho user ubuntu

**Tại sao:** `kubeadm init` chỉ tạo kubeconfig admin ở
`/etc/kubernetes/admin.conf` (quyền root). Để user `ubuntu` dùng được
`kubectl` không cần sudo, copy file đó về `~/.kube/config` và đổi chủ sở
hữu. File kubeconfig chứa địa chỉ API server + chứng chỉ client — chính
là "giấy tờ tùy thân" để kubectl xác thực với cluster.

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Kiểm tra:** `kubectl get nodes` (không sudo) phải chạy được và hiện 1 node.
`kubectl config view --minify` cho xem cluster/user/context đang dùng.

→ Chạy nhanh: `sudo ./scripts/01-init-control-plane.sh`.

### 2.9. Cài Calico (CNI — mạng cho Pod)

**Tại sao cần CNI:** Kubernetes chỉ định nghĩa chuẩn CNI (Container
Network Interface), còn việc cấp IP cho Pod, nối mạng giữa các Pod và
enforce NetworkPolicy là việc của plugin CNI. Không có CNI, node mãi
`NotReady` và Pod kẹt ở `Pending`. Ta chọn **Calico** vì nó hỗ trợ
NetworkPolicy (mục 8) — Flannel thì không.

Calico cài bằng 2 file: **tigera-operator** (operator quản lý vòng đời
Calico) và **custom-resources** (cấu hình Calico, trong đó có dải IP của
Pod — phải sửa `192.168.0.0/16` mặc định thành `10.244.0.0/16` cho khớp
với `--pod-network-cidr` ở mục 2.7, nếu không Pod sẽ không có mạng).

```bash
# 1. Cai operator (phien ban v3.29.0):
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml
# 2. Tai file cau hinh, sua CIDR cho khop roi apply:
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/custom-resources.yaml \
  | sed "s|192.168.0.0/16|10.244.0.0/16|" \
  | kubectl create -f -
```

Muốn nhìn rõ file cấu hình trước khi apply, tải về rồi mở ra xem thay vì
pipe trực tiếp:

```bash
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/custom-resources.yaml -o /tmp/calico-cr.yaml
sed -i "s|192.168.0.0/16|10.244.0.0/16|" /tmp/calico-cr.yaml
grep -A2 cidr /tmp/calico-cr.yaml   # kiem tra da sua dung chua
kubectl create -f /tmp/calico-cr.yaml
```

**Kiểm tra:** chờ 1–2 phút rồi chạy `kubectl get nodes` — node phải chuyển
sang `Ready`. `kubectl -n calico-system get pods` phải thấy các Pod
`calico-node`, `calico-kube-controllers` ở `Running`.

→ Chạy nhanh: `sudo ./scripts/01-init-control-plane.sh`.

### 2.10. Cài metrics-server (để HPA đo CPU)

**Tại sao:** HPA (mục 5) scale Pod dựa trên CPU, mà dữ liệu CPU lấy từ
**metrics-server** — một service thu thập metrics từ kubelet của từng
node qua Metrics API. Không có nó, `kubectl top` lỗi và HPA không hoạt động.

Một điểm hay gây lỗi trên kubeadm: kubelet dùng chứng chỉ tự ký, nên
metrics-server không tin được kubelet và phải thêm flag
`--kubelet-insecure-tls` (bỏ qua kiểm tra chứng chỉ kubelet). Chỉ dùng
cho test — production thì cấp chứng chỉ đúng cho kubelet.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
# Them flag bo qua cert kubelet vao Deployment metrics-server:
kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**Kiểm tra:** chờ 1–2 phút rồi chạy `kubectl top nodes` — phải hiện CPU/RAM
của node. Nếu báo lỗi `metrics not available yet`, đợi thêm rồi thử lại.

→ Chạy nhanh: `sudo ./scripts/01-init-control-plane.sh`.

### 2.11. Gỡ taint control-plane + kiểm tra cluster

**Tại sao:** mặc định kubeadm gắn **taint**
`node-role.kubernetes.io/control-plane:NoSchedule` lên control-plane để
cấm Pod thường chạy trên đó (dành máy cho control-plane). Nhưng ta chỉ có
1 node — không gỡ taint này thì mọi Pod ứng dụng (web, PXC, Longhorn...)
đều `Pending` mãi vì scheduler không tìm được node nào cho phép chạy.
Dấu `-` ở cuối lệnh taint có nghĩa là **gỡ** taint đó đi.

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get nodes
```

**Kiểm tra tổng kết mục 2:**

```bash
kubectl get nodes
# Ky vong: 1 node Ready, vai tro control-plane
kubectl get pods -A
# Ky vong: moi Pod o Running hoac Completed (CoreDNS, Calico, metrics-server...)
kubectl top nodes
# Ky vong: hien CPU/RAM — metrics-server da chay
```

→ Chạy nhanh: `sudo ./scripts/01-init-control-plane.sh`.

### 2.12. Cài Docker (để build image ở mục 4)

**Tại sao cần Docker riêng:** containerd (mục 2.4) chỉ **chạy** container,
không **build** image. Docker ở đây chỉ dùng để build image app rồi push
lên DockerHub ở mục 4. Ta cài gói `docker.io` của Ubuntu vì nó dùng chung
containerd đã cài sẵn, không đụng vào runtime của Kubernetes.

Sau khi thêm user vào nhóm `docker`, bạn phải đăng xuất SSH rồi đăng nhập
lại (hoặc chạy `newgrp docker`) thì nhóm mới có hiệu lực — nếu không lệnh
`docker` sẽ báo permission denied.

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu
```

**Kiểm tra:** đăng xuất rồi đăng nhập lại SSH, chạy `docker --version`
(không sudo) và `docker info --format '{{.ServerVersion}}'` — phải in ra
version mà không báo lỗi quyền.

→ Chạy nhanh: `sudo ./scripts/02-install-docker.sh`.

---

## 3. Cài nền tảng bằng Helm

Mục này cài 4 thành phần hạ tầng bằng Helm: NGINX Ingress Controller,
Longhorn, PXC Operator, Fluent Bit. Tất cả lệnh chạy bằng user thường
(không sudo) trên EC2.

### 3.0. Thêm Helm repo

**Helm repo là gì:** một kho chứa các chart (giống apt repo chứa package).
`helm repo add` đăng ký địa chỉ kho, `helm repo update` tải danh sách
chart mới nhất về. Mỗi thành phần dưới đây nằm ở một repo khác nhau.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn https://charts.longhorn.io
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update
```

**Kiểm tra:** `helm repo list` phải thấy 4 repo. `helm search repo ingress-nginx`
phải thấy chart `ingress-nginx/ingress-nginx` kèm version.

Muốn xem trước một chart có những giá trị nào chỉnh được, chạy ví dụ
`helm show values ingress-nginx/ingress-nginx --version 4.12.1 | head -50`
— đây là cách đọc "hướng dẫn sử dụng" của chart, rất hữu ích khi bạn muốn
đổi cấu hình sau này.

Lưu ý: các lệnh dưới đây dùng `helm install` (cài mới — chạy lại khi
release đã tồn tại sẽ báo lỗi). Muốn chạy lại được nhiều lần thì dùng
`helm upgrade --install` thay cho `helm install` (chưa có thì cài mới,
có rồi thì nâng cấp) — các script trong project dùng dạng này để chạy
lại được.

→ Chạy nhanh: `./scripts/03-install-platform.sh`.

### 3.1. NGINX Ingress Controller

**Ingress Controller khác Ingress thế nào:** **Ingress** (resource, tạo ở
mục 5) chỉ là "bản khai" — nó khai rằng domain X trỏ về Service Y. Còn
**Ingress Controller** là chương trình thật sự đọc bản khai đó và cấu hình
NGINX để định tuyến traffic. Không có Controller, Ingress chỉ là một mẩu
YAML nằm im, không ai phục vụ traffic.

**Tại sao NodePort:** trên AWS EKS thì Service `LoadBalancer` sẽ được AWS
cấp một load balancer thật. Nhưng cluster kubeadm tự dựng không có cloud
controller nào làm việc đó, nên Service LoadBalancer sẽ kẹt ở `<pending>`
mãi. Dùng `NodePort` thay thế: Kubernetes mở một cổng cố định
(30080/30443) trên chính EC2, traffic từ Internet vào cổng đó rồi đi qua
Ingress. Cố định cổng NodePort để mở Security Group trước được.

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version 4.12.1 \
  --set controller.replicaCount=2 \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443
```

Giải thích từng `--set`:
- `controller.replicaCount=2` — chạy 2 Pod Ingress (1 Pod chết vẫn còn 1 Pod).
- `controller.service.type=NodePort` — mở cổng trên node thay vì chờ LoadBalancer.
- `controller.service.nodePorts.http/https` — cố định cổng 30080/30443.

**Kiểm tra:**

```bash
kubectl get pods -n ingress-nginx
# Ky vong: 2 Pod ingress-nginx-controller Running
kubectl get svc -n ingress-nginx
# Ky vong: Service ingress-nginx-controller co 80:30080/TCP, 443:30443/TCP
```

Lệnh `helm list -n ingress-nginx` cho xem release vừa cài. Muốn xem chart
đã tạo ra những resource nào: `kubectl get all -n ingress-nginx`.

→ Chạy nhanh: `./scripts/03-install-platform.sh`.

### 3.2. Longhorn (storage trong cluster)

**Longhorn là gì:** Kubernetes không tự có ổ đĩa — nó cần một **CSI driver**
(Container Storage Interface) để cấp phát volume. Longhorn là CSI driver
chạy hoàn toàn trong cluster: nó lấy disk trống trên node, tạo volume,
nhân bản dữ liệu (replica) và cung cấp cả volume RWO (1 Pod mount) lẫn
RWX (nhiều Pod cùng mount qua NFS). Ở mục 5, StorageClass sẽ trỏ về driver
`driver.longhorn.io` của nó.

Các thành phần chính Longhorn tạo ra (xem bằng `kubectl -n longhorn-system get pods`):

| Thành phần | Việc nó làm |
| --- | --- |
| `longhorn-manager` (DaemonSet) | Chạy trên mỗi node, quản lý volume và replica |
| `longhorn-driver-deployer` | Cài CSI driver vào kubelet |
| `instance-manager` | Chạy engine và replica của từng volume |
| `share-manager` (tạo động) | NFS server phục vụ volume RWX |
| `longhorn-ui` | Giao diện web quản lý volume |

`defaultReplicaCount=1` vì single-node: để 3 như guide gốc thì replica
không có node khác để đặt, volume sẽ báo degraded. Đánh đổi: mất node là
mất dữ liệu — chấp nhận được khi test.

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version 1.9.0 \
  --set defaultSettings.defaultReplicaCount=1
```

**Kiểm tra:** `kubectl -n longhorn-system get pods` — chờ đến khi mọi Pod
`Running` (mất 1–3 phút, `longhorn-manager` và `instance-manager` khởi
động hơi lâu). `kubectl get storageclass` lúc này vẫn chưa thấy gì —
StorageClass sẽ do bạn tạo ở mục 5, Longhorn chỉ cung cấp driver.

→ Chạy nhanh: `./scripts/03-install-platform.sh`.

### 3.3. PXC Operator (toán tử quản lý MySQL)

**Operator là gì:** một chương trình chạy trong cluster, liên tục quan sát
một loại resource tùy chỉnh (CRD — Custom Resource Definition) rồi "lái"
hệ thống về trạng thái mong muốn. PXC Operator quan sát resource
`PerconaXtraDBCluster`: khi bạn tạo 1 resource đó (mục 5.2), Operator tự
tạo StatefulSet 3 Pod MySQL, Service HAProxy, PVC, và tự xử lý failover,
đồng bộ Galera. Nếu không có Operator, bạn phải tự viết StatefulSet +
script đồng bộ Galera bằng tay — rất nhiều việc và dễ sai.

Cài Operator trước, tạo cluster sau — thứ tự này bắt buộc, vì Helm chart
`pxc-db` ở mục 5 tạo resource `PerconaXtraDBCluster`, mà Kubernetes chỉ
hiểu resource đó sau khi Operator đã đăng ký CRD.

```bash
helm install pxc-operator percona/pxc-operator \
  --namespace pxc-operator --create-namespace \
  --version 1.17.0
```

**Kiểm tra:**

```bash
kubectl get pods -n pxc-operator
# Ky vong: 1 Pod percona-xtradb-cluster-operator Running
kubectl get crd | grep -i pxc
# Ky vong: thay perconaxtradbclusters.pxc.percona.com (CRD da dang ky)
```

→ Chạy nhanh: `./scripts/03-install-platform.sh`.

### 3.4. Fluent Bit (thu log)

**Tại sao:** mỗi Pod ghi log ra stdout, nhưng log đó nằm rải rác theo Pod
và mất khi Pod bị xóa. Fluent Bit chạy dạng **DaemonSet** — Kubernetes đảm
bảo mỗi node có đúng 1 Pod Fluent Bit — đọc log container từ
`/var/log/containers` trên node rồi chuyển đi nơi lưu trữ. Bản cấu hình
trong project để output ra stdout (xem bằng `kubectl logs`), muốn gửi sang
Loki thì sửa `k8s/logging/fluent-bit-values.yaml`.

```bash
helm install fluent-bit fluent/fluent-bit \
  --namespace logging --create-namespace \
  --version 0.48.0 \
  -f k8s/logging/fluent-bit-values.yaml
```

**Kiểm tra:** `kubectl get pods -n logging` — 1 Pod `fluent-bit` Running
(1 node nên chỉ có 1 Pod). `kubectl rollout status daemonset/fluent-bit -n logging`
phải báo thành công.

**Kiểm tra tổng kết mục 3:**

```bash
helm list -A
# Ky vong: 4 release — ingress-nginx, longhorn, pxc-operator, fluent-bit
kubectl get pods -n ingress-nginx
kubectl -n longhorn-system get pods
kubectl get pods -n pxc-operator
kubectl get pods -n logging
```

→ Chạy nhanh: `./scripts/03-install-platform.sh`.

---

## 4. Build và push Docker image

Mục này build image của app rồi đẩy lên DockerHub để K8s kéo về ở mục 5.
Chạy trên chính EC2 (Docker đã cài ở mục 2.12).

### 4.1. Build image

**Docker build làm gì:** đọc `app/Dockerfile`, chạy từng chỉ thị (cài
Node 20 Alpine → `npm ci` cài dependency → copy source → đổi user `node`)
và đóng gói thành image với tên bạn đặt. Mẹo đọc Dockerfile: thứ tự các
lệnh được sắp để tận dụng **layer cache** — copy `package.json` và cài
dependency trước, copy source sau, nên khi bạn chỉ sửa code thì lần build
sau không phải cài lại dependency.

```bash
# Dat ten image (thay <dockerhub-user> bang username DockerHub cua ban):
export IMAGE=<dockerhub-user>/k8s-web-demo:v1
# Build, context la thu muc app/ (noi co Dockerfile):
docker build -t $IMAGE app/
```

**Kiểm tra:** `docker images | grep k8s-web-demo` phải thấy image vừa build.
`docker history $IMAGE` cho xem từng layer của image và dung lượng.

### 4.2. Push lên DockerHub

```bash
docker login
# Nhap username + mat khau (hoac access token) DockerHub khi duoc hoi.
docker push $IMAGE
```

**Kiểm tra:** mở DockerHub trên trình duyệt (hub.docker.com), vào repo
`<user>/k8s-web-demo` — phải thấy tag `v1` vừa push. Hoặc kiểm tra từ
dòng lệnh: `docker pull $IMAGE` ở một máy khác (hoặc sau khi
`docker rmi $IMAGE` rồi pull lại) phải tải về được.

→ Chạy nhanh: `./scripts/04-build-push.sh` (làm đúng 2 bước trên).

### 4.3. Repo public hay private?

- **Repo public** (mặc định khi push repo mới lên Docker Hub): không cần
  làm gì thêm. K8s pull image về không cần đăng nhập.
- **Repo private**: K8s cần một **Secret loại docker-registry** chứa tài
  khoản DockerHub, rồi Pod phải khai `imagePullSecrets` trỏ tới Secret đó
  thì kubelet mới pull được image private. Tạo Secret bằng lệnh sau
  (chạy **trước** mục 5):

```bash
# Nen dung access token thay vi mat khau:
# DockerHub -> Account Settings -> Personal Access Tokens -> Generate
kubectl create secret docker-registry dockerhub-pull \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<dockerhub-user> \
  --docker-password=<access-token> \
  --namespace production \
  --dry-run=client -o yaml | kubectl apply -f -
```

Giải thích: `kubectl create secret docker-registry` tạo Secret chứa file
`.dockerconfigjson` (đúng định dạng Docker dùng để đăng nhập).
`--dry-run=client -o yaml | kubectl apply -f -` là mẹo để lệnh này chạy
được nhiều lần (tạo mới hoặc cập nhật) thay vì lỗi "already exists" khi
chạy lại. Lưu ý: lệnh này cần namespace `production` tồn tại — nếu chưa
có, tạo trước bằng `kubectl create namespace production` (mục 5.1 cũng
tạo namespace này).

**Kiểm tra:** `kubectl -n production get secret dockerhub-pull` phải thấy
Secret loại `kubernetes.io/dockerconfigjson`.

Việc gắn `imagePullSecrets` vào Pod sẽ làm ở mục 5.5 (phần render manifest).

→ Chạy nhanh: `DOCKERHUB_USER=<user> ./scripts/08-dockerhub-secret.sh`
(hỏi token một cách an toàn, không hiện trên màn hình).

### Test app trước bằng Docker Compose (khuyến nghị, tùy chọn)

Trước khi đưa lên K8s, test CRUD ngay trên máy local (máy bạn có Docker):

```bash
docker compose up --build
# Mo http://localhost:3000 — them/sua/xoa cong viec
docker compose down
```

Compose chạy MySQL 8.0 + app với cùng env đã fix sẵn, giúp bạn chắc chắn
app chạy được trước khi debug tới K8s.

---

## 5. Deploy database + app (làm tay từng bước)

Mục này là phần chính: dựng database rồi deploy app theo đúng thứ tự phụ
thuộc — namespace → storage → PXC → user DB → migrate → web → CronJob.
Mỗi bước đều có kiểm tra, đừng nhảy cóc vì bước sau phụ thuộc bước trước.

Trước khi bắt đầu, đặt 2 biến dùng xuyên suốt mục này:

```bash
export IMAGE=<dockerhub-user>/k8s-web-demo:v1
# Domain mac dinh: lay IP public cua EC2, dung nip.io (khong can mua domain):
export DOMAIN=$(curl -fsSL ifconfig.me | tr '.' '-').nip.io
echo $DOMAIN
# VD: 52-12-34-56.nip.io — nip.io tu phan giai ve IP 52.12.34.56.
# Neu co domain that, dat: export DOMAIN=app.example.com (va tro DNS ve IP EC2)
```

### 5.1. Namespace, StorageClass, Shared PVC

**Namespace** gom tài nguyên của ứng dụng lại một chỗ (`production`) để
quản lý và phân quyền dễ hơn. **StorageClass** là "khuôn" để tạo volume
động: khi bạn tạo PVC, Kubernetes nhìn `storageClassName` để biết nhờ
driver nào cấp volume với tham số nào. **PVC** (PersistentVolumeClaim) là
"đơn xin" volume — Kubernetes sẽ tạo **PV** (PersistentVolume) tương ứng
qua driver Longhorn.

Mở 2 file StorageClass ra đọc trước khi apply để hiểu từng trường
(`k8s/storage/storageclass-db.yaml`, `k8s/storage/storageclass-shared.yaml`):
`provisioner: driver.longhorn.io` (dùng driver Longhorn),
`allowVolumeExpansion: true` (tăng dung lượng sau được),
`reclaimPolicy: Retain` (xóa PVC không xóa dữ liệu),
`numberOfReplicas: "1"` (single-node), `nfsOptions` (chỉ có ở bản RWX).

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/storage/storageclass-db.yaml
kubectl apply -f k8s/storage/storageclass-shared.yaml
kubectl apply -f k8s/storage/pvc-shared.yaml
```

**Kiểm tra:**

```bash
kubectl get storageclass
# Ky vong: longhorn-db + longhorn-shared
kubectl -n production get pvc shared-data
# Cho den khi STATUS = Bound (Longhorn mat 1-2 phut de tao PV):
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/shared-data -n production --timeout=300s
kubectl -n production get pvc shared-data
kubectl get pv
# Ky vong: co 1 PV RWX 5Gi, STATUS Bound, CLAIM production/shared-data
```

### 5.2. Cài PXC cluster (MySQL Galera)

**Thứ tự:** tạo Secret mật khẩu trước, rồi mới cài cluster — Operator đọc
mật khẩu từ Secret `cluster1-secrets` khi khởi tạo MySQL. Mở file
`k8s/db/pxc-secrets.yaml` ra xem: 7 key bắt buộc của Operator
(`root`, `xtrabackup`, `monitor`, `clustercheck`, `proxyadmin`,
`operator`, `replication`). `stringData` cho phép viết mật khẩu dạng text,
Kubernetes tự mã hóa base64 khi lưu.

```bash
kubectl apply -f k8s/db/pxc-secrets.yaml
```

Tiếp theo, cài cluster bằng Helm chart `pxc-db`. Mở file
`k8s/db/pxc-values.yaml` ra đọc trước — đây là nơi khai "tôi muốn cluster
MySQL như thế nào": 3 Pod PXC, mỗi Pod 1 PVC 10Gi dùng StorageClass
`longhorn-db`, 2 Pod HAProxy, tắt backup (chưa có S3) và tắt ProxySQL
(chỉ dùng HAProxy). Lưu ý file này **không có affinity** — cố tình bỏ để
3 Pod PXC chạy được trên 1 node (xem giải thích trong file).

```bash
helm install cluster1 percona/pxc-db \
  --namespace production \
  --version 1.17.0 \
  -f k8s/db/pxc-values.yaml
```

**Operator sẽ làm gì tiếp theo:** nó tạo StatefulSet `cluster1-pxc`
(3 Pod MySQL), Deployment HAProxy (2 Pod), 3 PVC `datadir-cluster1-pxc-*`,
và các Service. Pod MySQL đầu tiên khởi tạo cluster Galera, 2 Pod sau
đồng bộ dữ liệu về (SST — State Snapshot Transfer) nên lần đầu mất
5–15 phút. Đây là bước lâu nhất trong toàn bộ guide.

**Kiểm tra — theo dõi quá trình khởi tạo:**

```bash
# Xem trang thai tong quan cua cluster (STATE se di: initializing -> Ready):
kubectl -n production get pxc cluster1 -w
# (Nhan Ctrl+C de thoat watch khi STATE = Ready)
```

Trong lúc chờ, mở terminal thứ hai quan sát từng lớp:

```bash
kubectl -n production get pods -l app.kubernetes.io/instance=cluster1
# Ky vong cuoi cung: 3 Pod cluster1-pxc-* Running + 2 Pod cluster1-haproxy-* Running
kubectl -n production get pvc
# Ky vong: 3 PVC datadir-cluster1-pxc-* Bound (10Gi, longhorn-db) + shared-data
kubectl -n production get svc | grep haproxy
# Ky vong: Service cluster1-haproxy (ClusterIP, port 3306) — endpoint app se noi toi
kubectl -n production logs cluster1-pxc-0 -c pxc --tail=20
# Xem log khoi tao Galera cua Pod dau tien neu muon hieu qua trinh nay
```

Chỉ đi tiếp khi `kubectl -n production get pxc cluster1` báo `STATE = Ready`
và cả 3 Pod PXC đều `Running`.

### 5.3. Tạo database và user cho ứng dụng (Job db-init)

**Tại sao dùng Job:** việc tạo database + user chỉ cần chạy **một lần**
rồi thôi — đúng bản chất của **Job** (chạy tới khi xong thì dừng), khác
với Deployment (chạy mãi). Job này dùng cùng image với web nhưng chạy
lệnh `node src/init-db.js` thay vì server: nối MySQL bằng quyền root để
tạo database `appdb` và user `app`, rồi thoát. File `k8s/db/db-init-job.yaml`
lấy mật khẩu root từ Secret `cluster1-secrets` và mật khẩu app từ
Secret `app-secret` (chưa tạo — tạo ngay dưới đây).

Trước hết tạo Secret cho ứng dụng (mở `k8s/app/app-secret.yaml` ra xem:
5 biến `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` — web sẽ
đọc các biến này qua `envFrom`):

```bash
kubectl apply -f k8s/app/app-secret.yaml
```

Job dùng image placeholder `my-nodejs-app:v1` nên phải thay bằng `$IMAGE`
trước khi apply. Dùng `sed` thay chuỗi rồi pipe vào `kubectl apply -f -`
(đọc manifest từ stdin, không sửa file gốc):

```bash
sed "s|my-nodejs-app:v1|$IMAGE|g" k8s/db/db-init-job.yaml | kubectl apply -f -
# Doi Job chay xong (co the mat vai phut neu PXC vua Ready):
kubectl wait --for=condition=complete job/db-init -n production --timeout=600s
kubectl logs -n production job/db-init
# Ky vong: "[init-db] OK: database 'appdb' va user 'app' san sang."
```

**Nếu Job lỗi:** `kubectl -n production logs job/db-init` xem lỗi gì.
Script `init-db.js` tự thử lại 30 lần (mỗi lần cách 5s) nên PXC chưa nhận
kết nối thì nó sẽ chờ. Chạy lại Job (sau khi sửa): Job không apply đè
được — phải xóa rồi tạo lại:
`kubectl delete job db-init -n production` rồi chạy lại lệnh `sed ... | kubectl apply`.

### 5.4. Migrate + seed bảng tasks (Job db-migrate)

Job này chạy `node src/migrate.js`: tạo bảng `tasks` nếu chưa có
(`app/db/migrate.sql`) rồi nạp 5 dòng mẫu (`app/db/seed.sql`). Cả 2 file
SQL đều **idempotent** (chạy lại nhiều lần vẫn an toàn): `CREATE TABLE IF
NOT EXISTS` và `INSERT ... ON DUPLICATE KEY UPDATE` — nên Job này và web
(tự migrate lúc khởi động) có chạy cùng lúc cũng không tạo dòng trùng.

```bash
sed "s|my-nodejs-app:v1|$IMAGE|g" k8s/db/migrate-job.yaml | kubectl apply -f -
kubectl wait --for=condition=complete job/db-migrate -n production --timeout=600s
kubectl logs -n production job/db-migrate
# Ky vong: "[migrate] OK: bang tasks san sang, hien co 5 dong."
```

**Kiểm tra dữ liệu thật trong MySQL:**

```bash
kubectl -n production exec -it cluster1-pxc-0 -c pxc -- \
  mysql -uroot -p'PxcRoot123!' -e "USE appdb; SHOW TABLES; SELECT id, title, status FROM tasks;"
# Ky vong: bang tasks voi 5 dong seed
```

### 5.5. Deploy web (Deployment, Service, Ingress, HPA)

**Bốn resource này mỗi cái làm gì:**
- **Deployment** `nodejs-web` — khai "luôn giữ 2 Pod web chạy image này",
  kèm rolling update (đổi image không gián đoạn), probe, resource limits,
  và mount 2 volume (`emptyDir` tạm + PVC RWX dùng chung).
- **Service** `nodejs-service` (ClusterIP) — địa chỉ ổn định trong cluster
  để Ingress gọi tới, tự phân phối tới các Pod đang Ready.
- **Ingress** `nodejs-ingress` — khai domain nào trỏ về Service nào
  (Ingress Controller ở mục 3.1 sẽ thực thi).
- **HPA** `nodejs-hpa` — tự scale 2–4 Pod theo CPU (cần metrics-server
  ở mục 2.10).

Mở 4 file trong `k8s/app/` ra đọc trước khi apply — mỗi file đều có
comment giải thích từng khối cấu hình. Lưu ý 2 chỗ cần thay trước khi apply:

1. **Image:** file Deployment ghi placeholder `my-nodejs-app:v1`, thay
   bằng `$IMAGE`.
2. **Domain:** file Ingress ghi placeholder `app.example.com`, thay bằng
   `$DOMAIN`.
3. **Repo private:** nếu bạn đã tạo Secret `dockerhub-pull` ở mục 4.3,
   trong 4 file có Pod (web-deployment, worker-cronjob, 2 Job) có dòng
   comment `# __IMAGE_PULL_SECRETS__` — thay dòng đó bằng 2 dòng sau
   (giữ đúng thụt lề của file):
   ```yaml
   imagePullSecrets:
     - name: dockerhub-pull
   ```
   Repo public thì cứ xóa dòng comment đó đi (hoặc để nguyên — comment
   không ảnh hưởng gì).

```bash
# 1. Deployment (thay image):
sed "s|my-nodejs-app:v1|$IMAGE|g" k8s/app/web-deployment.yaml | kubectl apply -f -
# 2. Service (khong co placeholder, apply truc tiep):
kubectl apply -f k8s/app/web-service.yaml
# 3. Ingress (thay domain):
sed "s|app.example.com|$DOMAIN|g" k8s/app/web-ingress.yaml | kubectl apply -f -
# 4. HPA:
kubectl apply -f k8s/app/web-hpa.yaml
```

**Kiểm tra:**

```bash
# Doi Deployment san sang (2/2 Pod Available):
kubectl wait --for=condition=Available deployment/nodejs-web -n production --timeout=300s
kubectl -n production get pods -l app=nodejs-web
# Ky vong: 2 Pod Running, READY 1/1
kubectl -n production get svc nodejs-service
kubectl -n production get ingress nodejs-ingress
# Ky vong: HOSTS = <domain cua ban>
kubectl -n production get hpa
# Ky vong: nodejs-hpa, TARGETS hien CPU% (can vai phut de co so lieu dau tien)
kubectl -n production logs -l app=nodejs-web --tail=10
# Ky vong: "[server] Web chay tren cong 3000" + "[migrate] OK..."
```

Thử gọi web ngay từ trong EC2 (qua NodePort, giả Host header):

```bash
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/readyz
# Ky vong: {"status":"ready","db":"up"}
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/api/tasks | head -c 300
# Ky vong: JSON 5 task seed
```

### 5.6. RBAC + CronJob dispatcher

**Dispatcher làm gì:** mỗi 5 phút, CronJob chạy `src/worker.js` — lấy tối
đa 10 task `todo` (cũ nhất trước), claim nguyên tử sang `doing`, rồi tạo
**1 K8s Job riêng** chạy `src/process-task.js` xử lý từng task. Xong task
chuyển sang `done`, kết quả ghi ra `/app/shared/results/task-<id>.json`.
Task kẹt ở `doing` quá 10 phút được reset về `todo` ở lần chạy sau.

**Tại sao cần RBAC:** mặc định Pod chạy với ServiceAccount `default`
không có quyền gì trên API server. Dispatcher cần quyền **tạo Job** nên
phải có bộ 3 RBAC riêng (file `k8s/worker/dispatcher-rbac.yaml`, mở ra
đọc — rất ngắn):
- **ServiceAccount** `task-dispatcher` — "danh tính" của dispatcher.
- **Role** — "được làm gì": tạo/get/list Job, và get Secret `dockerhub-pull`
  (để biết có cần gắn pull secret vào Job xử lý không). Chỉ trong namespace
  `production`, không có quyền gì khác (least privilege).
- **RoleBinding** — "gắn" Role đó cho ServiceAccount đó.

CronJob (`k8s/worker/worker-cronjob.yaml`) trỏ `serviceAccountName:
task-dispatcher` và đặt biến `APP_IMAGE` (image để dispatcher dùng khi
tạo Job xử lý — cũng là placeholder cần thay bằng `$IMAGE`).

```bash
kubectl apply -f k8s/worker/dispatcher-rbac.yaml
sed "s|my-nodejs-app:v1|$IMAGE|g" k8s/worker/worker-cronjob.yaml | kubectl apply -f -
```

**Kiểm tra:**

```bash
kubectl -n production get cronjob task-worker
# Ky vong: SCHEDULE */5 * * * *, SUSPEND False
kubectl -n production get sa/task-dispatcher role/task-dispatcher rolebinding/task-dispatcher
# Ky vong: ca 3 ton tai
```

### 5.7. Mở web + deploy lại sau khi sửa code

Mở web trên trình duyệt tại:

```text
http://<DOMAIN>:30080
# VD: http://52-12-34-56.nip.io:30080 (chay echo $DOMAIN de xem)
```

**Deploy lại sau khi sửa code:** build image tag mới, push, rồi đổi image
của Deployment và CronJob. Lưu ý phải cập nhật cả biến `APP_IMAGE` của
CronJob để dispatcher tạo Job xử lý bằng image mới:

```bash
export IMAGE=<dockerhub-user>/k8s-web-demo:v2
docker build -t $IMAGE app/
docker push $IMAGE
kubectl -n production set image deployment/nodejs-web nodejs=$IMAGE
kubectl -n production set image cronjob/task-worker worker=$IMAGE
kubectl -n production set env cronjob/task-worker APP_IMAGE=$IMAGE
kubectl -n production rollout status deployment/nodejs-web
```

→ Chạy nhanh toàn bộ mục 5: `IMAGE=... ./scripts/05-deploy.sh`
(làm đúng các bước trên, có chờ từng bước; thêm `--with-netpol` để bật
NetworkPolicy ngay — nhưng nên làm tay mục 8 sau khi kiểm tra xong).

---

## 6. Mở web và thao tác database

### 6.1. Qua giao diện web

Mở URL ở mục 5.7 (`http://<domain>:30080`). Giao diện tiếng Việt:

- **Thêm/Sửa/Xóa** công việc bằng form và nút trên từng dòng.
- **Lọc** theo trạng thái, **tìm** theo tiêu đề.
- Dòng trạng thái database (gọi `/readyz` mỗi 30 giây).
- Mục **Test thư mục dùng chung**: ghi file `demo.txt` từ Pod này, bấm
  đọc lại — request có thể rơi vào Pod khác, vẫn đọc được nhờ PVC RWX.

Dữ liệu seed ban đầu có sẵn 5 công việc mẫu. Lưu ý: 2 task seed ở trạng
thái `todo` sẽ được dispatcher tự động xử lý (chuyển sang `done`) trong
vòng 5 phút sau khi deploy — đó là tính năng, không phải lỗi.

### 6.2. Qua API (curl)

```bash
BASE=http://<domain>:30080   # hoac http://127.0.0.1:30080 -H "Host: <domain>" tren EC2

curl $BASE/healthz
curl $BASE/api/tasks
curl -X POST $BASE/api/tasks -H 'Content-Type: application/json' \
  -d '{"title":"Viec moi","description":"Mo ta","status":"todo"}'
curl -X PUT $BASE/api/tasks/1 -H 'Content-Type: application/json' \
  -d '{"status":"done"}'
curl -X DELETE $BASE/api/tasks/6
```

Bảng API:

| Method | Endpoint | Mô tả |
| --- | --- | --- |
| GET | `/healthz` | Liveness: 200 khi process còn sống (kèm trạng thái DB để tham khảo) |
| GET | `/readyz` | Readiness: 200 chỉ khi nối được MySQL |
| GET | `/api/tasks?status=&q=` | Danh sách, lọc theo trạng thái/từ khóa |
| GET | `/api/tasks/:id` | Chi tiết 1 task |
| POST | `/api/tasks` | Tạo (`title` bắt buộc, `status` ∈ todo/doing/done) |
| PUT | `/api/tasks/:id` | Cập nhật từng phần |
| DELETE | `/api/tasks/:id` | Xóa |
| POST/GET | `/api/shared/write`, `/api/shared/read` | Test PVC RWX |

### 6.3. Qua MySQL trực tiếp

```bash
# Shell tuong tac (database appdb, user root):
kubectl -n production exec -it cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' appdb
# Hoac chay 1 lenh (script tien ich, cung lenh tren):
./scripts/07-db-shell.sh "SELECT * FROM tasks;"
./scripts/07-db-shell.sh "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

Trong shell:

```sql
SHOW TABLES;
SELECT id, title, status FROM tasks ORDER BY id;
INSERT INTO tasks (title, status) VALUES ('Viec them tu SQL', 'doing');
```

### 6.4. Qua port-forward (khi không mở Ingress)

`kubectl port-forward` mở một đường hầm từ máy bạn tới Service/Pod trong
cluster — hữu ích khi debug mà không muốn đi qua Ingress:

```bash
kubectl -n production port-forward svc/nodejs-service 3000:80
# Mo http://localhost:3000 tren may chay kubectl
kubectl -n production port-forward svc/cluster1-haproxy 3306:3306
# Noi MySQL client toi localhost:3306, user app / AppPass123!
```

### 6.5. Xem task được xử lý tự động (dispatcher + Job)

1. Tạo 1 task mới trên UI (trạng thái `todo`).
2. Đợi tối đa 5 phút (lịch CronJob) rồi tải lại trang — task tự chuyển
   sang `done`. Muốn xử lý ngay không cần đợi lịch, tạo Job từ CronJob
   bằng tay (`--from` copy y hệt template của CronJob):
   ```bash
   kubectl create job dispatch-now --from=cronjob/task-worker -n production
   kubectl wait --for=condition=complete job/dispatch-now -n production --timeout=300s
   ```
3. Xem các Job xử lý đã tạo (1 Job / 1 task) và log của chúng:
   ```bash
   kubectl -n production get jobs -l app=task-processor
   kubectl -n production logs -l app=task-processor --tail=20
   kubectl -n production logs -l app=task-worker --tail=30  # log dispatcher
   ```
4. Xem kết quả xử lý trong shared volume:
   ```bash
   kubectl -n production exec deploy/nodejs-web -- ls /app/shared/results/
   kubectl -n production exec deploy/nodejs-web -- cat /app/shared/results/task-<id>.json
   kubectl -n production exec deploy/nodejs-web -- cat /app/shared/worker-heartbeat.json
   ```

Dispatcher xử lý tối đa 10 task `todo` mỗi lần chạy (cũ nhất trước),
claim nguyên tử nên không xử lý trùng. Task kẹt ở `doing` quá 10 phút
(Job chết giữa chừng) sẽ tự được reset về `todo` ở lần chạy sau.

---

## 7. Kiểm tra toàn bộ (làm tay từng mục)

Chạy từng nhóm kiểm tra dưới đây và đối chiếu kết quả kỳ vọng. Nhóm nào
lỗi thì xem mục 10 Troubleshooting.

### 7.1. Trạng thái tổng quan

```bash
kubectl get nodes
kubectl -n production get pxc,pods,pvc,svc,ingress,hpa,cronjob
kubectl get pods -n ingress-nginx
kubectl -n longhorn-system get pods
kubectl get pods -n pxc-operator
kubectl get pods -n logging
```

Kỳ vọng: 1 node Ready; PXC `Ready`; 3 Pod PXC + 2 Pod HAProxy + 2 Pod web
Running; PVC đều `Bound`; Ingress có HOSTS; HPA có chỉ số CPU.

### 7.2. Galera đồng bộ

```bash
kubectl -n production exec cluster1-pxc-0 -c pxc -- \
  mysql -uroot -p'PxcRoot123!' -N -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Ky vong: wsrep_cluster_size = 3
```

### 7.3. CRUD thật qua port-forward

```bash
kubectl -n production port-forward svc/nodejs-service 3000:80 &
# Cho port-forward len (sleep 3), roi chay tung lenh, quan sat ket qua:
curl -s http://localhost:3000/healthz
# Ky vong: {"status":"ok","db":"up"}
curl -s http://localhost:3000/readyz
# Ky vong: {"status":"ready","db":"up"}
curl -s http://localhost:3000/api/tasks | grep -o '"title":[^,]*'
# Ky vong: thay 5 title seed
curl -s -X POST http://localhost:3000/api/tasks -H 'Content-Type: application/json' \
  -d '{"title":"Task test tay","status":"todo"}'
# Ky vong: JSON task moi co id (ghi nho id nay, VD 6)
curl -s -X PUT http://localhost:3000/api/tasks/<id> -H 'Content-Type: application/json' \
  -d '{"status":"done"}'
# Ky vong: task co status "done"
curl -s -X DELETE http://localhost:3000/api/tasks/<id>
# Ky vong: {"deleted":true,...}
# Xong thi tat port-forward: fg roi Ctrl+C, hoac kill %1
```

### 7.4. Dispatcher thật

```bash
# Tao 1 task todo qua API (dung port-forward o muc 7.3, hoac qua Ingress):
curl -s -X POST http://localhost:3000/api/tasks -H 'Content-Type: application/json' \
  -d '{"title":"Task test dispatcher","status":"todo"}'
# Ghi nho id tra ve, VD 7. Kich hoat dispatcher ngay:
kubectl create job dispatch-test --from=cronjob/task-worker -n production
kubectl wait --for=condition=complete job/dispatch-test -n production --timeout=300s
# Doi Job xu ly task do xong:
kubectl wait --for=condition=complete job -l task-id=7 -n production --timeout=300s
# Kiem tra task da done va file ket qua da co:
curl -s http://localhost:3000/api/tasks/7
# Ky vong: "status":"done"
kubectl -n production exec deploy/nodejs-web -- cat /app/shared/results/task-7.json
# Ky vong: JSON co "result": "ok"
# Don dep:
curl -s -X DELETE http://localhost:3000/api/tasks/7
kubectl delete job dispatch-test -n production
```

### 7.5. Shared PVC (RWX): Pod 1 ghi, Pod 2 đọc

```bash
POD1=$(kubectl -n production get pods -l app=nodejs-web -o name | sed -n 1p)
POD2=$(kubectl -n production get pods -l app=nodejs-web -o name | sed -n 2p)
kubectl -n production exec $POD1 -- sh -c "echo hello-rwx > /app/shared/verify.txt"
kubectl -n production exec $POD2 -- cat /app/shared/verify.txt
# Ky vong: Pod 2 in ra "hello-rwx" — chung minh 2 Pod dung chung 1 filesystem
```

### 7.6. Ingress qua NodePort

```bash
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/readyz
# Ky vong: {"status":"ready","db":"up"}
```

### 7.7. Failover MySQL

Xóa 1 Pod PXC, xem cluster có tiếp tục phục vụ không:

```bash
kubectl -n production delete pod cluster1-pxc-1
kubectl -n production get pods -l app.kubernetes.io/component=pxc -w
# (Ctrl+C sau khi thay Pod moi Running)
kubectl -n production exec cluster1-pxc-0 -c pxc -- \
  mysql -uroot -p'PxcRoot123!' -N -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Trong luc Pod khoi dong lai, size xuong 2 roi ve 3.
# Thu CRUD lai o muc 6.2 — web van doc ghi duoc qua HAProxy trong luc do.
```

### 7.8. HPA và Longhorn UI

```bash
kubectl -n production get hpa
kubectl -n production top pods
# Longhorn UI (xem volume/replica):
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Mo http://localhost:8080 tren may chay kubectl
```

→ Chạy nhanh toàn bộ mục 7: `./scripts/06-verify.sh` (chạy đúng các kiểm
tra trên và in PASS/FAIL — mở file ra đối chiếu từng bước).

---

## 8. Bật NetworkPolicy (sau cùng)

Chỉ bật khi mục 7 đã pass hết, vì default-deny rất dễ chặn nhầm.
**NetworkPolicy là gì:** luật tường lửa ở tầng Pod — khai Pod nào được nói
chuyện với Pod nào, qua port nào. Nó chỉ có tác dụng khi CNI hỗ trợ
(Calico có, Flannel không — đó là lý do mục 2.9 chọn Calico).

Mở từng file trong `k8s/networkpolicy/` ra đọc trước khi apply. Bộ 7 policy:

| File | Tác dụng |
| --- | --- |
| `netpol-default-deny.yaml` | Chặn **mọi** traffic vào/ra của mọi Pod trong namespace — các policy sau mở lại từng luồng cần thiết |
| `netpol-allow-dns.yaml` | Mở egress DNS (UDP/TCP 53) tới CoreDNS — không có rule này Pod không phân giải được tên miền |
| `netpol-web-ingress.yaml` | Chỉ NGINX Ingress (namespace `ingress-nginx`) được vào Web Pod qua port 3000 |
| `netpol-app-to-db.yaml` | Web/Job/Dispatcher/Processor được vào HAProxy qua 3306; HAProxy được ra PXC qua 3306 |
| `netpol-app-egress-db.yaml` | Chiều ngược lại: Web/Job/Dispatcher/Processor được ra HAProxy qua 3306 |
| `netpol-pxc-internal.yaml` | Các MySQL Pod giao tiếp Galera nội bộ (3306, 4444, 4567, 4568) và với Operator |
| `netpol-dispatcher-api.yaml` | Dispatcher được gọi kube-apiserver (port 443) để tạo Job xử lý task |

Áp dụng và kiểm tra:

```bash
kubectl apply -f k8s/networkpolicy/
kubectl -n production get networkpolicy
# Ky vong: 7 policy

# Web van phuc vu duoc:
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/readyz
# Web Pod van noi duoc MySQL:
kubectl -n production exec deploy/nodejs-web -- sh -c "nc -zv cluster1-haproxy 3306"
# Dispatcher van tao duoc Job xu ly (can egress toi API server):
kubectl create job dispatch-netpol-test --from=cronjob/task-worker -n production
kubectl wait --for=condition=complete job/dispatch-netpol-test -n production --timeout=300s
kubectl delete job dispatch-netpol-test -n production
```

Nếu web mất kết nối DB sau khi bật: kiểm tra label thật của Pod HAProxy/PXC
(`kubectl -n production get pods --show-labels`) rồi đối chiếu selector
trong `k8s/networkpolicy/`. Gỡ nhanh khi cần debug:

```bash
kubectl delete -f k8s/networkpolicy/
```

→ Chạy nhanh: `IMAGE=... ./scripts/05-deploy.sh --with-netpol` (bật
NetworkPolicy ngay khi deploy — chỉ dùng khi đã hiểu và kiểm tra xong).

---

## 9. Backup (tùy chọn)

PXC backup ra S3 theo guide mục 13:

1. Copy `k8s/backup/backup-s3-secret.yaml.example` thành
   `backup-s3-secret.yaml`, điền key S3/MinIO thật, rồi
   `kubectl apply -f k8s/backup/backup-s3-secret.yaml`.
2. Sửa `bucket`/`endpointUrl` trong `k8s/backup/pxc-backup-values.yaml`.
3. `helm upgrade cluster1 percona/pxc-db -n production -f k8s/db/pxc-values.yaml -f k8s/backup/pxc-backup-values.yaml`.

Backup chạy 2h sáng hằng ngày, giữ 7 bản. Nhớ **restore thử định kỳ** —
backup chưa từng restore thử thì chưa tính là backup.

---

## 10. Troubleshooting

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| Node `NotReady` sau khi init | Calico chưa chạy xong | `kubectl -n calico-system get pods`; chờ 1–2 phút rồi kiểm tra lại |
| Pod ứng dụng `Pending` mãi | Quên gỡ taint control-plane | `kubectl describe node` xem taint; chạy `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` |
| Pod PXC `Pending` | Longhorn chưa Ready, hoặc thiếu tài nguyên (RAM/CPU) | `kubectl -n longhorn-system get pods`; `kubectl describe pod` xem event; kiểm tra `kubectl top nodes` và dung lượng disk |
| PVC `Pending` | Longhorn chưa sẵn sàng, hoặc thiếu `open-iscsi` | Kiểm tra Longhorn Pod Running; trên node: `systemctl status iscsid` |
| PXC mãi không `Ready` | Pod PXC CrashLoop, hoặc disk đầy | `kubectl -n production logs cluster1-pxc-0 -c pxc --tail=100`; `kubectl -n production describe pxc cluster1` |
| Job `db-init`/`db-migrate` Failed | PXC chưa nhận kết nối, hoặc sai mật khẩu | `kubectl -n production logs job/db-init`; Job tự retry — chờ rồi chạy lại bước đó (Job phải xóa rồi tạo lại, không apply đè được) |
| Web `ImagePullBackOff` | Image chưa push, sai tên `$IMAGE`, hoặc repo private chưa có Secret | `docker pull $IMAGE` thử trên EC2; nếu repo private: tạo Secret theo mục 4.3 rồi deploy lại mục 5.5; kiểm tra `kubectl -n production describe pod -l app=nodejs-web` |
| `docker` báo permission denied | User chưa vào nhóm docker | Đăng xuất SSH rồi đăng nhập lại, hoặc chạy `newgrp docker` |
| `/readyz` 503 | Web chưa nối được MySQL | `kubectl -n production logs -l app=nodejs-web`; kiểm tra PXC Ready và Service `cluster1-haproxy` tồn tại |
| Task mãi ở `todo` | Dispatcher lỗi (thường do RBAC hoặc không gọi được K8s API) | `kubectl -n production logs -l app=task-worker --tail=50`; kiểm tra RBAC: `kubectl -n production get sa/task-dispatcher role/task-dispatcher rolebinding/task-dispatcher` — nếu thiếu, chạy lại `kubectl apply -f k8s/worker/dispatcher-rbac.yaml` |
| Task kẹt ở `doing` | Job xử lý chết giữa chừng | Dispatcher tự reset về `todo` sau 10 phút ở lần chạy sau; kiểm tra log Job: `kubectl -n production logs -l app=task-processor` |
| Sau khi bật NetworkPolicy thì dispatcher lỗi | Thiếu policy mở egress tới API server | Kiểm tra `netpol-dispatcher-api.yaml` đã apply chưa: `kubectl -n production get networkpolicy` |
| Vào web bị 404 (NGINX) | Sai Host/domain | Ingress chỉ nhận đúng host đã cấu hình — mở đúng URL mục 5.7, hoặc `curl -H 'Host: <domain>'` |
| Vào web không được gì | Security Group chưa mở 30080 | Mở cổng 30080 (và 30443) trong SG của EC2 |
| Sau khi bật NetworkPolicy thì web lỗi DB | Label HAProxy/PXC khác với selector | Xem mục 8: đối chiếu label thật, sửa selector |
| `kubectl top` lỗi | metrics-server chưa chạy | `kubectl -n kube-system get pods -l k8s-app=metrics-server`; chờ 1–2 phút sau khi cài |
| Disk node đầy | Longhorn volume + log + image Docker | `df -h /var/lib/longhorn`; `docker system prune` để dọn image cũ; xóa volume test cũ trên Longhorn UI |

---

## 11. Dọn dẹp và chi phí

Dọn tay từng phần (ngược thứ tự lúc dựng):

```bash
# 1. Xoa app + CronJob + Job:
kubectl delete -f k8s/app/ --ignore-not-found
kubectl delete -f k8s/worker/ --ignore-not-found
kubectl delete -f k8s/networkpolicy/ --ignore-not-found
kubectl delete job db-init db-migrate -n production --ignore-not-found
# 2. Xoa PXC cluster + Secret:
helm uninstall cluster1 -n production
kubectl delete -f k8s/db/pxc-secrets.yaml --ignore-not-found
kubectl delete -f k8s/app/app-secret.yaml --ignore-not-found
# 3. Xoa PVC + StorageClass (PV gi lai du lieu do reclaimPolicy Retain):
kubectl delete -f k8s/storage/pvc-shared.yaml --ignore-not-found
kubectl delete -f k8s/storage/ --ignore-not-found
# 4. Xoa nen tang:
helm uninstall fluent-bit -n logging
helm uninstall pxc-operator -n pxc-operator
helm uninstall longhorn -n longhorn-system
helm uninstall ingress-nginx -n ingress-nginx
# 5. Xoa namespace:
kubectl delete namespace production --ignore-not-found
```

→ Chạy nhanh: `./scripts/teardown.sh` (làm đúng các bước trên, hỏi xác
nhận trước khi xóa).

Để dừng tốn tiền hẳn: **terminate EC2** trên AWS Console sau khi test xong.
Ước tính chi phí test (tham khảo, theo giá on-demand us-east-1, kiểm tra lại
trên AWS Pricing): 1 × t3.xlarge ≈ 0,17 USD/giờ ≈ 4 USD/ngày. Nhớ tắt khi
không dùng.

---

## Phụ lục A. Cấu trúc project

```text
app/                  Source Node.js
  src/server.js       Web + API CRUD + /healthz + /readyz + test shared volume
  src/routes/tasks.js CRUD bang tasks
  src/migrate.js      Migrate + seed (idempotent, tu retry)
  src/init-db.js      Tao database + user app (thay lenh mysql tay)
  src/worker.js       Dispatcher CronJob: lay task todo, tao Job xu ly
  src/process-task.js Xu ly 1 task (chay trong Job do dispatcher tao)
  src/k8s-client.js   Client toi thieu goi K8s API (tao Job, kiem tra Secret)
  src/db.js, config.js
  db/migrate.sql, seed.sql
  public/             UI CRUD tieng Viet (index.html, app.js, style.css)
  Dockerfile          Node 20 Alpine, 1 image cho moi vai tro
k8s/
  00-namespace.yaml
  storage/            2 StorageClass + PVC shared-data (RWX)
  db/                 pxc-secrets, pxc-values, db-init-job, migrate-job
  app/                app-secret, deployment, service, ingress, hpa
  worker/             CronJob task-worker + RBAC dispatcher
  networkpolicy/      7 policy (bat sau cung)
  logging/            fluent-bit-values
  backup/             pxc-backup-values + mau secret S3
  kustomization.yaml  Apply cac manifest tinh: kubectl apply -k k8s/
scripts/              Loi tat chay nhanh — moi script lam dung cac buoc
                      trong muc guide tuong ung (xem Phu luc B). Mo file
                      ra doc de doi chieu voi lenh tay.
  00-prepare-nodes.sh, 01-init-control-plane.sh, 02-install-docker.sh,
  03-install-platform.sh, 04-build-push.sh, 05-deploy.sh, 06-verify.sh,
  07-db-shell.sh, 08-dockerhub-secret.sh, teardown.sh, common.sh
docker-compose.yml    Test local: MySQL 8.0 + app
README.md             Tom tat nhanh
```

## Phụ lục B. Đối chiếu mục guide ↔ script

| Mục guide (làm tay) | Script tương ứng (chạy nhanh) |
| --- | --- |
| 2.1–2.6 Chuẩn bị node | `sudo ./scripts/00-prepare-nodes.sh` |
| 2.7–2.11 kubeadm init + Calico + metrics-server + gỡ taint | `sudo ./scripts/01-init-control-plane.sh` |
| 2.12 Cài Docker | `sudo ./scripts/02-install-docker.sh` |
| 3.0–3.4 Cài nền tảng Helm | `./scripts/03-install-platform.sh` |
| 4.1–4.2 Build + push image | `./scripts/04-build-push.sh` (cần `IMAGE` + `docker login` trước) |
| 4.3 Secret repo private | `DOCKERHUB_USER=<user> ./scripts/08-dockerhub-secret.sh` |
| 5.1–5.6 Deploy DB + app | `IMAGE=... ./scripts/05-deploy.sh` (thêm `--with-netpol` để bật NetworkPolicy ngay) |
| 6.3 Shell MySQL | `./scripts/07-db-shell.sh ["<lenh SQL>"]` |
| 7.1–7.8 Kiểm tra toàn bộ | `./scripts/06-verify.sh` |
| 8. Bật NetworkPolicy | `kubectl apply -f k8s/networkpolicy/` (không có script riêng — chỉ 1 lệnh) |
| 11. Dọn dẹp | `./scripts/teardown.sh` |
