# Hướng dẫn setup trên 1 EC2 Amazon Linux 2023

File này là bản riêng cho **Amazon Linux 2023 (AL2023)** — thay thế các
mục 1–4 của `HUONG-DAN-SETUP.md` chính (bản đó viết cho Ubuntu 22.04).
Từ mục 5 trở đi (deploy DB + app, kiểm tra, NetworkPolicy, backup,
troubleshooting, dọn dẹp) giống hệt nhau vì đều là lệnh Kubernetes —
bạn làm theo guide chính, chỉ thay `scripts/` bằng `scripts-al2023/`
(xem mục 5).

**Những gì đã chốt cho project này:**
- **1 EC2 duy nhất**, bạn tự tạo EC2 + Security Group (xem mục 1).
- **Amazon Linux 2023** — không có `apt`, dùng `dnf`; user mặc định
  `ec2-user` (không phải `ubuntu`); SELinux mặc định enforcing.
- **Học tay là đường chính**: mỗi mục chạy từng lệnh có giải thích và
  điểm kiểm tra. Script trong `scripts-al2023/` là lối tắt chạy nhanh
  và để đối chiếu — làm đúng các bước trong guide.
- Thứ duy nhất bạn vẫn phải tự điền: **`IMAGE`** — tên image trên
  DockerHub của bạn (mục 4). Mọi env, mật khẩu test khác đã fix sẵn
  trong project (xem mục 0 của guide chính).

## Đặt file vào đâu

Giải nén zip này **vào trong thư mục project `k8s-native-web-platform`
bạn đã có** (từ zip project chính), để được cấu trúc:

```text
k8s-native-web-platform/
  HUONG-DAN-SETUP.md            # guide goc (Ubuntu) — dung tu muc 5 tro di
  HUONG-DAN-SETUP-AL2023.md     # file nay
  scripts/                      # script Ubuntu (khong dung nua neu chay AL2023)
  scripts-al2023/               # script AL2023 — dung bo nay
  app/  k8s/  docker-compose.yml
```

Các script trong `scripts-al2023/` tự tìm thư mục project qua vị trí của
chúng, nên chỉ cần đặt đúng chỗ là chạy được. Các script 03–08 và
teardown giống hệt bản Ubuntu (chúng chỉ dùng `kubectl`/`helm`/`docker`,
không phụ thuộc hệ điều hành) — chỉ 3 script 00/01/02 là viết lại cho
AL2023.

## Khác biệt chính giữa Ubuntu và AL2023 (để khỏi bỡ ngỡ)

| Hạng mục | Ubuntu 22.04 (guide chính) | Amazon Linux 2023 (file này) |
| --- | --- | --- |
| Trình quản lý gói | `apt` / `apt-get` | `dnf` (`yum` vẫn dùng được, là alias của `dnf`) |
| User mặc định | `ubuntu` | `ec2-user` |
| SELinux | Không có (dùng AppArmor) | **Enforcing mặc định** — phải chuyển sang permissive, nếu không kubeadm preflight lỗi |
| iSCSI (Longhorn cần) | `open-iscsi` | `iscsi-initiator-utils` |
| NFS client (RWX cần) | `nfs-common` | `nfs-utils` |
| Docker | `docker.io` | `docker` (có sẵn trong repo AL2023) |
| Repo Kubernetes | apt repo `pkgs.k8s.io/.../deb/` + keyring | RPM repo `/etc/yum.repos.d/kubernetes.repo`, baseurl `pkgs.k8s.io/.../rpm/` |
| Khóa version K8s | `apt-mark hold` | `dnf versionlock` (cần cài plugin) |
| Gói kubeadm cần thêm | (đã có sẵn trên Ubuntu) | `socat`, `conntrack-tools`, `iptables`, `iproute-tc` — phải cài thêm |
| containerd | `containerd` (apt) | `containerd` (dnf) — AL2023 cấp containerd 2.x, tương thích K8s 1.31 |

Phần Kubernetes (kubeadm init, Calico, metrics-server, Helm, deploy) hoàn
toàn giống nhau trên cả 2 hệ điều hành.

**Quy ước trong file này:** lệnh có `sudo` thì chạy với quyền root. Lệnh
`kubectl`/`helm`/`docker` chạy bằng user thường `ec2-user` (không sudo).
Sau mỗi khối lệnh quan trọng đều có mục **Kiểm tra** — đừng bỏ qua.

---

## 1. EC2 yêu cầu (bạn tự tạo trước)

Chỉ cần **1 EC2 duy nhất**. Yêu cầu:

| Hạng mục | Yêu cầu |
| --- | --- |
| AMI | **Amazon Linux 2023** (AMI chuẩn của AWS, kiến trúc x86_64), rỗng (chưa cài gì) |
| Loại instance | **t3.xlarge** (4 vCPU, 16 GB) trở lên — 3 Pod PXC + Longhorn + web + ingress cùng chạy trên 1 node nên t3.large (8 GB) sẽ chật. Có điều kiện thì dùng t3.2xlarge cho thoải mái |
| Disk | 50 GB gp3 trở lên (Longhorn dùng thư mục `/var/lib/longhorn` trên disk root) |
| Public IP | Có (để SSH và để truy cập web qua NodePort) |
| Security Group | Mở **22** (SSH) và **30080, 30443** (Ingress NodePort HTTP/HTTPS) từ IP của bạn (hoặc 0.0.0.0/0 nếu muốn mở rộng). Không cần mở thêm cổng nào khác vì chỉ có 1 node. **Đừng mở 3306** — MySQL chỉ truy cập trong cluster |

### Copy project lên EC2

User SSH của AL2023 là `ec2-user` (không phải `ubuntu`):

```bash
# Tren may local (thu muc chua project):
scp -i <key.pem> -r k8s-native-web-platform ec2-user@<IP-EC2>:~/
ssh -i <key.pem> ec2-user@<IP-EC2>
cd ~/k8s-native-web-platform
chmod +x scripts-al2023/*.sh
```

Từ đây trở đi, mọi lệnh đều chạy trên EC2 này.

---

## 2. Cài Kubernetes cluster single-node (kubeadm) + Docker

Mục này dựng cluster từ con số 0 trên EC2 rỗng, theo đúng thứ tự kubeadm
yêu cầu: cập nhật hệ thống → tắt swap → SELinux → kernel/sysctl →
gói Longhorn + kubeadm → container runtime → công cụ K8s → `kubeadm init`
→ CNI → metrics-server → gỡ taint → Docker.

### 2.1. Cập nhật hệ thống

```bash
sudo dnf update -y
```

**Tại sao:** AMI AL2023 có thể cũ vài tháng. Cập nhật trước để các gói
cài sau đó lấy bản mới nhất trong repo, tránh lỗi phụ thuộc do gói cũ.
`dnf update` là lệnh tương đương `apt-get update && apt-get upgrade` trên
Ubuntu (gộp 2 bước làm 1 — `dnf` tự làm mới danh sách gói trước khi cập
nhật).

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.2. Tắt swap

**Tại sao:** kubelet mặc định từ chối chạy khi swap đang bật (Kubernetes
quản lý bộ nhớ bằng cgroup limits — nếu hệ thống swap ra disk, kubelet
không còn đo và giới hạn được RAM thật của Pod). AMI AL2023 thường không
có swap sẵn, nhưng cứ chạy cho chắc — lệnh không có swap thì không làm gì.

```bash
sudo swapoff -a
# Xoa swap khoi /etc/fstab de reboot xong swap khong bat lai:
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**Kiểm tra:** `free -h` — cột Swap phải hiện `0B`.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.3. SELinux sang permissive (bước riêng của AL2023)

**Tại sao:** AL2023 bật SELinux ở chế độ **enforcing** mặc định — mọi
tiến trình chỉ được làm những gì policy cho phép. kubeadm sẽ lỗi ở bước
preflight nếu SELinux đang enforcing (kubelet cần quyền mà policy mặc
định không cấp). Chuyển sang **permissive**: SELinux vẫn ghi log vi phạm
nhưng không chặn nữa. Cần 2 thao tác: `setenforce 0` (áp dụng ngay, mất
hiệu lực khi reboot) và sửa `/etc/selinux/config` (giữ lại sau reboot).

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

**Kiểm tra:** `getenforce` phải in `Permissive`.
`grep ^SELINUX= /etc/selinux/config` phải thấy `SELINUX=permissive`.

> Lưu ý: Longhorn cũng có thể gặp vấn đề với SELinux enforcing trên các
> distro Fedora-family (iscsid bị chặn một số thao tác). Chuyển sang
> permissive ở đây xử lý luôn cả vấn đề đó.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.4. Bật kernel module và sysctl cho Kubernetes

**Tại sao:** giống hệt bản Ubuntu — Pod giao tiếp qua Linux bridge, cần
module `overlay` (filesystem cho container) và `br_netfilter` (để
iptables nhìn thấy traffic qua bridge). Ba tham số sysctl cho phép
iptables lọc traffic qua bridge (kube-proxy và NetworkPolicy dựa vào đó)
và cho node chuyển tiếp gói tin giữa các Pod.

```bash
sudo tee /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

**Kiểm tra:** `lsmod | grep -E 'overlay|br_netfilter'` phải thấy 2 module.
`sysctl net.ipv4.ip_forward` phải trả về `= 1`.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.5. Cài gói Longhorn cần + gói kubeadm cần

**Longhorn cần gì trên AL2023:**
- `iscsi-initiator-utils` — cung cấp dịch vụ `iscsid` để Longhorn gắn
  volume vào node (tương đương gói `open-iscsi` trên Ubuntu). Cài theo
  đúng hướng dẫn của Longhorn cho RHEL-family, kèm
  `--setopt=tsflags=noscripts` (bỏ qua scriptlet của gói — Longhorn
  khuyên dùng vì scriptlet mặc định có thể gây lỗi trên một số bản).
- `nfs-utils` — NFS client để mount volume RWX (tương đương `nfs-common`
  trên Ubuntu).

**kubeadm cần thêm gì:** kubeadm kiểm tra (preflight) sự tồn tại của
`socat` và `conntrack` (kubelet/kube-proxy dùng chúng), `iptables`
(luật chuyển tiếp traffic của Pod) và `iproute-tc` (công cụ `tc` quản lý
traffic shaping). Trên Ubuntu các gói này có sẵn, trên AL2023 minimal
thì chưa — phải cài thêm.

```bash
sudo dnf --setopt=tsflags=noscripts install -y iscsi-initiator-utils
sudo dnf install -y nfs-utils socat conntrack-tools iptables iproute-tc
sudo systemctl enable --now iscsid
```

**Kiểm tra:** `systemctl status iscsid --no-pager | head -3` phải thấy
`active (running)`. `which socat conntrack iptables tc` phải in ra cả
4 đường dẫn.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.6. Cài containerd (container runtime)

**Tại sao:** kubelet không tự chạy container — nó gọi một runtime qua CRI
(Container Runtime Interface). `containerd` là runtime chuẩn cho kubeadm
(Docker đã không còn làm CRI trực tiếp từ K8s 1.24 — Docker chỉ còn dùng
để build image ở mục 2.14, còn chạy Pod là việc của containerd).

Điểm quan trọng nhất là **cgroup driver**: kubelet dùng `systemd` làm
cgroup driver, nên containerd cũng phải dùng `systemd`
(`SystemdCgroup = true`). Hai bên lệch driver nhau là kubelet crash ngay
khi khởi động — lỗi này rất hay gặp khi cài tay.

```bash
sudo dnf install -y containerd
sudo mkdir -p /etc/containerd
# Sinh file cau hinh mac dinh, chi doi SystemdCgroup false -> true:
sudo containerd config default \
  | sed 's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /tmp/config.toml
sudo mv /tmp/config.toml /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

Lưu ý: repo AL2023 hiện cấp **containerd 2.x**, tương thích với K8s 1.31
(K8s hỗ trợ containerd 2.0 từ 1.31 trở đi). Cấu hình `SystemdCgroup`
vẫn nằm ở chỗ cũ nên lệnh `sed` trên vẫn đúng.

**Kiểm tra:** `grep SystemdCgroup /etc/containerd/config.toml` phải thấy
`SystemdCgroup = true`. `sudo systemctl status containerd --no-pager | head -3`
phải thấy `active (running)`. `ctr version` in ra version containerd.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.7. Cài kubelet, kubeadm, kubectl 1.31 (repo RPM)

**Ba công cụ này khác nhau thế nào:**
- `kubelet` — agent chạy trên node, nhận lệnh từ API server để chạy/dừng Pod.
- `kubeadm` — công cụ dựng cluster (chỉ dùng lúc setup).
- `kubectl` — công cụ dòng lệnh để bạn nói chuyện với cluster.

Trên RHEL-family, Kubernetes phát hành gói RPM qua repo `pkgs.k8s.io`
(tương đương repo deb trên Ubuntu). Repo gắn theo minor version (`v1.31`)
nên cài không cần ghi version. Thêm repo bằng cách viết file
`/etc/yum.repos.d/kubernetes.repo` — `dnf` đọc mọi file `.repo` trong thư
mục này (thư mục vẫn tên `yum.repos.d` dù dùng `dnf` — giữ tên cũ cho
tương thích). `gpgcheck=1` + `gpgkey` để dnf kiểm tra chữ ký của gói.

**Khóa version:** sau khi cài, khóa 3 gói lại bằng plugin `versionlock`
(tương đương `apt-mark hold` trên Ubuntu) để `dnf update` sau này không
tự nâng K8s lên minor khác. Plugin này chưa có sẵn trên AL2023 nên phải
cài thêm (`dnf-command(versionlock)` là tên "khả năng" mà dnf tự tìm gói
cung cấp nó).

```bash
# Them repo RPM cua Kubernetes (K8s 1.31):
sudo tee /etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF
sudo dnf install -y kubelet kubeadm kubectl
# Khoa version (dnf update se khong tu nang cap K8s):
sudo dnf install -y 'dnf-command(versionlock)'
sudo dnf versionlock add kubelet kubeadm kubectl
sudo systemctl enable kubelet
```

Lúc cài, dnf có thể hỏi có chấp nhận import GPG key của repo Kubernetes
không — trả lời `y`. (Chạy bằng script với `-y` thì tự động chấp nhận.)

**Kiểm tra:** `kubeadm version`, `kubectl version --client`,
`kubelet --version` đều in ra 1.31.x. `dnf versionlock list` phải thấy
3 gói. Lưu ý: lúc này kubelet chưa chạy được (chưa có cluster) nên
`systemctl status kubelet` sẽ thấy nó restart liên tục — đó là bình
thường, nó sẽ chạy ổn sau `kubeadm init`.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.8. Cài Helm

**Tại sao:** Helm là "package manager" của Kubernetes — thay vì viết hàng
chục file YAML cho NGINX Ingress hay Longhorn, bạn cài một **chart**
(gói template có sẵn) và chỉnh vài giá trị. Ở mục 3 bạn sẽ dùng Helm để
cài toàn bộ nền tảng. Script cài Helm tải binary về `/usr/local/bin`,
không phụ thuộc hệ điều hành nên giống hệt bản Ubuntu.

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Kiểm tra:** `helm version` in ra version 3.x.

→ Chạy nhanh: `sudo ./scripts-al2023/00-prepare-nodes.sh`.

### 2.9. Khởi tạo cluster: kubeadm init

**Lệnh này làm gì:** `kubeadm init` dựng toàn bộ control-plane trên máy
này: tạo chứng chỉ (CA), chạy etcd (nơi lưu mọi trạng thái cluster),
kube-apiserver (cửa ngõ duy nhất để nói chuyện với cluster),
kube-controller-manager, kube-scheduler, và sinh file kubeconfig admin.
Hai flag quan trọng:

- `--pod-network-cidr=10.244.0.0/16` — dải IP cấp cho Pod. Con số này
  **phải khớp** với cấu hình Calico ở mục 2.11 (mặc định Calico dùng
  `192.168.0.0/16`, nên phải sửa lại cho khớp).
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

→ Chạy nhanh: `sudo ./scripts-al2023/01-init-control-plane.sh`.

### 2.10. Cấu hình kubectl cho user ec2-user

**Tại sao:** `kubeadm init` chỉ tạo kubeconfig admin ở
`/etc/kubernetes/admin.conf` (quyền root). Để user `ec2-user` dùng được
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

→ Chạy nhanh: `sudo ./scripts-al2023/01-init-control-plane.sh`.

### 2.11. Cài Calico (CNI — mạng cho Pod)

**Tại sao cần CNI:** Kubernetes chỉ định nghĩa chuẩn CNI (Container
Network Interface), còn việc cấp IP cho Pod, nối mạng giữa các Pod và
enforce NetworkPolicy là việc của plugin CNI. Không có CNI, node mãi
`NotReady` và Pod kẹt ở `Pending`. Ta chọn **Calico** vì nó hỗ trợ
NetworkPolicy (mục 8 của guide chính) — Flannel thì không.

Calico cài bằng 2 file: **tigera-operator** (operator quản lý vòng đời
Calico) và **custom-resources** (cấu hình Calico, trong đó có dải IP của
Pod — phải sửa `192.168.0.0/16` mặc định thành `10.244.0.0/16` cho khớp
với `--pod-network-cidr` ở mục 2.9, nếu không Pod sẽ không có mạng).

```bash
# 1. Cai operator (phien ban v3.29.0):
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml
# 1b. DOI CRD Installation xuat hien truoc khi sang buoc 2. Operator cai CRD
# khong dong bo (Pod operator khoi dong xong moi dang ky CRD voi API server).
# Apply custom-resources ngay se loi "no matches for kind Installation":
for i in $(seq 1 30); do kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && break; sleep 5; done
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=120s
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

→ Chạy nhanh: `sudo ./scripts-al2023/01-init-control-plane.sh`.

### 2.12. Cài metrics-server (để HPA đo CPU)

**Tại sao:** HPA (mục 5 của guide chính) scale Pod dựa trên CPU, mà dữ
liệu CPU lấy từ **metrics-server** — một service thu thập metrics từ
kubelet của từng node qua Metrics API. Không có nó, `kubectl top` lỗi
và HPA không hoạt động.

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

→ Chạy nhanh: `sudo ./scripts-al2023/01-init-control-plane.sh`.

### 2.13. Gỡ taint control-plane + kiểm tra cluster

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

→ Chạy nhanh: `sudo ./scripts-al2023/01-init-control-plane.sh`.

### 2.14. Cài Docker (để build image ở mục 4)

**Tại sao cần Docker riêng:** containerd (mục 2.6) chỉ **chạy** container,
không **build** image. Docker ở đây chỉ dùng để build image app rồi push
lên DockerHub ở mục 4. Trên AL2023, gói `docker` có sẵn trong repo mặc
định của AWS — cài trực tiếp bằng `dnf`, không cần thêm repo của Docker.

Sau khi thêm user vào nhóm `docker`, bạn phải đăng xuất SSH rồi đăng nhập
lại (hoặc chạy `newgrp docker`) thì nhóm mới có hiệu lực — nếu không lệnh
`docker` sẽ báo permission denied.

```bash
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
```

**Kiểm tra:** đăng xuất rồi đăng nhập lại SSH, chạy `docker --version`
(không sudo) và `docker info --format '{{.ServerVersion}}'` — phải in ra
version mà không báo lỗi quyền.

→ Chạy nhanh: `sudo ./scripts-al2023/02-install-docker.sh`.

---

## 3. Cài nền tảng bằng Helm

Mục này giống hệt guide chính (mục 3) — toàn bộ là lệnh Helm/kubectl,
không phụ thuộc hệ điều hành. Dưới đây là các lệnh đầy đủ để bạn làm tay;
phần giải thích chi tiết từng thành phần (Ingress Controller khác Ingress
thế nào, Longhorn gồm những gì, Operator pattern, DaemonSet) xem ở mục 3
của guide chính.

```bash
# 0. Them Helm repo:
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn https://charts.longhorn.io
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# 1. NGINX Ingress Controller (NodePort 30080/30443, 2 replica):
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version 4.12.1 \
  --set controller.replicaCount=2 \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443

# 2. Longhorn (replica 1 vi single-node):
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version 1.9.0 \
  --set defaultSettings.defaultReplicaCount=1

# 3. PXC Operator (quan ly cluster MySQL o muc 5 cua guide chinh):
helm install pxc-operator percona/pxc-operator \
  --namespace pxc-operator --create-namespace \
  --version 1.17.0

# 4. Fluent Bit (DaemonSet thu log):
helm install fluent-bit fluent/fluent-bit \
  --namespace logging --create-namespace \
  --version 0.48.0 \
  -f k8s/logging/fluent-bit-values.yaml
```

Lưu ý: các lệnh trên dùng `helm install` (cài mới — chạy lại khi release
đã tồn tại sẽ báo lỗi). Muốn chạy lại được nhiều lần thì dùng
`helm upgrade --install` thay cho `helm install`.

**Kiểm tra:**

```bash
helm list -A
# Ky vong: 4 release — ingress-nginx, longhorn, pxc-operator, fluent-bit
kubectl get pods -n ingress-nginx
kubectl -n longhorn-system get pods
kubectl get pods -n pxc-operator
kubectl get pods -n logging
# Ky vong: moi Pod o Running (Longhorn mat 1-3 phut de khoi dong xong)
kubectl get crd | grep -i pxc
# Ky vong: thay perconaxtradbclusters.pxc.percona.com (CRD da dang ky)
```

→ Chạy nhanh: `./scripts-al2023/03-install-platform.sh`.

---

## 4. Build và push Docker image

Giống hệt guide chính (mục 4) — toàn bộ là lệnh Docker. Dưới đây là các
lệnh đầy đủ; phần giải thích (layer cache trong Dockerfile, repo public
hay private, Secret docker-registry) xem ở mục 4 của guide chính.

```bash
# Dat ten image (thay <dockerhub-user> bang username DockerHub cua ban):
export IMAGE=<dockerhub-user>/k8s-web-demo:v1
docker build -t $IMAGE app/
docker login
# Nhap username + mat khau (hoac access token) DockerHub khi duoc hoi.
docker push $IMAGE
```

**Kiểm tra:** `docker images | grep k8s-web-demo` phải thấy image vừa
build. Mở DockerHub trên trình duyệt — repo `<user>/k8s-web-demo` phải
thấy tag `v1` vừa push.

**Repo private** (repo public thì bỏ qua): tạo Secret pull image trước
khi sang mục 5 của guide chính (nên dùng access token thay vì mật khẩu:
DockerHub → Account Settings → Personal Access Tokens → Generate):

```bash
kubectl create secret docker-registry dockerhub-pull \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<dockerhub-user> \
  --docker-password=<access-token> \
  --namespace production \
  --dry-run=client -o yaml | kubectl apply -f -
```

(Lệnh này cần namespace `production` tồn tại — nếu chưa có, tạo trước
bằng `kubectl create namespace production`.)

→ Chạy nhanh: `./scripts-al2023/04-build-push.sh` (build + push),
`DOCKERHUB_USER=<user> ./scripts-al2023/08-dockerhub-secret.sh`
(tạo Secret, hỏi token an toàn không hiện trên màn hình).

---

## 5. Từ đây trở đi: làm theo guide chính

Mục 5 (deploy DB + app), 6 (mở web và thao tác database), 7 (kiểm tra
toàn bộ), 8 (NetworkPolicy), 9 (backup), 10 (troubleshooting), 11 (dọn
dẹp) trong `HUONG-DAN-SETUP.md` chính đều là lệnh Kubernetes thuần túy —
không khác gì giữa Ubuntu và AL2023. Bạn làm theo đúng guide chính, chỉ
cần thay 2 chỗ:

1. **Mọi chỗ guide chính viết `scripts/`** → dùng **`scripts-al2023/`**.
   Ví dụ: guide chính viết `IMAGE=... ./scripts/05-deploy.sh` thì bạn
   chạy `IMAGE=... ./scripts-al2023/05-deploy.sh`.
2. **User `ubuntu`** (nếu gặp) → **`ec2-user`**.

Ngoài ra, 2 lưu ý nhỏ khi đi qua guide chính:

- Mục 5.7: mở web tại `http://<DOMAIN>:30080` — lấy domain bằng
  `echo $DOMAIN` sau khi đã `export DOMAIN=...` ở đầu mục 5.
- Mục 6.4/7.3/7.8 dùng `kubectl port-forward` — chạy trên EC2 thì mở
  `localhost` trên chính EC2; muốn mở từ máy local thì SSH kèm
  `-L 3000:localhost:3000` (hoặc chạy port-forward qua SSH tunnel).

## 6. Đối chiếu mục guide ↔ script AL2023

| Mục (làm tay) | Script tương ứng (chạy nhanh) |
| --- | --- |
| AL2023 2.1–2.8 Chuẩn bị node (dnf, SELinux, iscsi/nfs, containerd, K8s RPM, Helm) | `sudo ./scripts-al2023/00-prepare-nodes.sh` |
| AL2023 2.9–2.13 kubeadm init + Calico + metrics-server + gỡ taint | `sudo ./scripts-al2023/01-init-control-plane.sh` |
| AL2023 2.14 Cài Docker | `sudo ./scripts-al2023/02-install-docker.sh` |
| AL2023 3. Cài nền tảng Helm | `./scripts-al2023/03-install-platform.sh` |
| AL2023 4. Build + push image | `./scripts-al2023/04-build-push.sh` (cần `IMAGE` + `docker login` trước) |
| AL2023 4. Secret repo private | `DOCKERHUB_USER=<user> ./scripts-al2023/08-dockerhub-secret.sh` |
| Guide chính 5. Deploy DB + app | `IMAGE=... ./scripts-al2023/05-deploy.sh` (thêm `--with-netpol` để bật NetworkPolicy ngay) |
| Guide chính 6.3 Shell MySQL | `./scripts-al2023/07-db-shell.sh ["<lenh SQL>"]` |
| Guide chính 7. Kiểm tra toàn bộ | `./scripts-al2023/06-verify.sh` |
| Guide chính 8. Bật NetworkPolicy | `kubectl apply -f k8s/networkpolicy/` (không có script riêng — chỉ 1 lệnh) |
| Guide chính 11. Dọn dẹp | `./scripts-al2023/teardown.sh` |

## 7. Troubleshooting riêng cho AL2023

(Bảng troubleshooting chung nằm ở mục 10 của guide chính. Dưới đây chỉ
có các lỗi đặc thù AL2023.)

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| `kubeadm init` lỗi preflight về SELinux | SELinux còn enforcing | `getenforce` phải là `Permissive`. Chạy lại mục 2.3: `sudo setenforce 0` + sửa `/etc/selinux/config` |
| `kubeadm init` lỗi thiếu `socat`/`conntrack` | Chưa cài gói kubeadm cần | `sudo dnf install -y socat conntrack-tools iptables iproute-tc` (mục 2.5) rồi chạy lại |
| `dnf install kubelet...` lỗi 404 / không thấy gói | Sai version trong repo file, hoặc repo K8s đã ngừng hỗ trợ v1.31 | Kiểm tra `/etc/yum.repos.d/kubernetes.repo` — baseurl phải là `https://pkgs.k8s.io/core:/stable:/v1.31/rpm/`; chạy `sudo dnf clean all` rồi thử lại |
| dnf hỏi import GPG key | Lần đầu dùng repo Kubernetes | Trả lời `y` — key từ `pkgs.k8s.io` (repo chính thức của Kubernetes) |
| `dnf versionlock` báo không có lệnh | Chưa cài plugin versionlock | `sudo dnf install -y 'dnf-command(versionlock)'` rồi chạy lại `dnf versionlock add kubelet kubeadm kubectl` |
| `systemctl status iscsid` không chạy | Quên enable iscsid, hoặc gói iscsi chưa cài | `sudo dnf --setopt=tsflags=noscripts install -y iscsi-initiator-utils` rồi `sudo systemctl enable --now iscsid` |
| PVC `Pending` + Longhorn báo lỗi iSCSI | iscsid chưa chạy, hoặc SELinux chặn | Kiểm tra `systemctl status iscsid` và `getenforce` (phải là `Permissive`) |
| `docker` báo permission denied | User chưa vào nhóm docker | Đăng xuất SSH rồi đăng nhập lại, hoặc chạy `newgrp docker` |
| `kubectl` báo `command not found` sau khi cài | Chưa cài xong, hoặc PATH chưa có `/usr/bin` | `rpm -q kubectl` kiểm tra đã cài chưa; cài lại theo mục 2.7 |
| `containerd config default` lỗi | containerd chưa cài, hoặc version quá mới | `rpm -q containerd` kiểm tra; AL2023 cấp containerd 2.x, lệnh trên vẫn đúng với 2.x |
