# Hướng dẫn setup trên 1 EC2 Amazon Linux 2023 (bản làm tay)

File này là bản **làm tay đầy đủ, độc lập** cho **Amazon Linux 2023
(AL2023)**: mỗi bước chạy từng lệnh có giải thích và điểm kiểm tra, từ
EC2 trống tới khi web chạy được. Muốn chạy nhanh bằng script thì dùng
bản shell [`HUONG-DAN-SHELL-AL2023.md`](HUONG-DAN-SHELL-AL2023.md)
(cùng nội dung, chạy các script trong `scripts-al2023/` theo thứ tự).
Bản cho Ubuntu 22.04 nằm ở `HUONG-DAN-SETUP.md` (cùng kiến trúc, khác
lệnh hệ điều hành ở mục 1–4).

**Những gì đã chốt cho project này:**
- **1 EC2 duy nhất**, bạn tự tạo EC2 + Security Group (xem mục 1).
- **Amazon Linux 2023** — không có `apt`, dùng `dnf`; user mặc định
  `ec2-user` (không phải `ubuntu`); SELinux mặc định enforcing.
- **Học tay là đường chính**: mỗi mục chạy từng lệnh có giải thích và
  điểm kiểm tra. Script trong `scripts-al2023/` là lối tắt chạy nhanh
  và để đối chiếu — làm đúng các bước trong guide.
- Thứ duy nhất bạn vẫn phải tự điền: **`IMAGE`** — tên image trên
  DockerHub của bạn (mục 4). Mọi env, mật khẩu test khác đã fix sẵn
  trong project (xem mục 0).

## 0. Những giá trị đã fix sẵn (đừng sửa khi chưa hiểu)

| Hạng mục | Giá trị |
| --- | --- |
| Namespace | `production` |
| Database / user / mật khẩu app | `appdb` / `app` / `AppPass123!` |
| MySQL root | `PxcRoot123!` (Secret `cluster1-secrets`; các mật khẩu PXC khác trong `k8s/db/pxc-secrets.yaml`) |
| DB_HOST app dùng | `cluster1-proxysql.production.svc.cluster.local:3306` (qua ProxySQL) |
| Image placeholder | `my-nodejs-app:v1` (script 05 thay bằng `$IMAGE` của bạn) |
| Domain mặc định | `<IP-public-cua-EC2>.nip.io` (script 05 tự sinh; có domain thật thì đặt `DOMAIN`) |
| Ingress NodePort | HTTP **30080**, HTTPS **30443** |
| K8s / Calico / metrics-server | 1.31 / v3.29.0 / v0.7.2; POD_CIDR `10.244.0.0/16` |
| Chart | ingress-nginx 4.12.1, longhorn 1.9.0, pxc-operator 1.17.0, pxc-db 1.17.0, fluent-bit 0.48.0 |

Đây là mật khẩu test, ghi thẳng trong repo để dễ học — đừng dùng cho
production thật.

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
| Loại instance | **t3.large** (2 vCPU, 8 GB) — vừa đủ cho cấu hình nhỏ mặc định của project. Muốn cấu hình đầy đủ (3 Pod PXC) thì dùng t3.xlarge (4 vCPU, 16 GB) trở lên |
| Disk | **30 GB gp3 trở lên** (đã kiểm chứng chạy được với cấu hình nhỏ; 50 GB thì thoải mái hơn). Longhorn dùng thư mục `/var/lib/longhorn` trên disk root — Longhorn tính dung lượng theo size PVC đã đặt trước (10Gi DB + 5Gi shared-data + 1Gi proxydata = 16Gi), nên disk chật hoặc còn volume mồ côi sẽ làm volume mới bị `faulted` (xem mục 10) |
| Public IP | Có (để SSH và để truy cập web qua NodePort) |
| Security Group | Mở **22** (SSH) và **30080, 30443** (Ingress NodePort HTTP/HTTPS) từ IP của bạn (hoặc 0.0.0.0/0 nếu muốn mở rộng). Không cần mở thêm cổng nào khác vì chỉ có 1 node. **Đừng mở 3306** — MySQL chỉ truy cập trong cluster |

> **Cấu hình nhỏ (mặc định của project này, cho t3.large 2 CPU/8GB):**
> PXC **1 Pod** (`pxc.size: 1`, requests 200m) + ProxySQL **1 Pod**
> (100m), web **2 Pod** × 100m, dispatcher 100m, `logcollector` tắt,
> CoreDNS giảm xuống **1 replica** (`kubectl -n kube-system scale
> deployment coredns --replicas=1`, làm ở mục 3). Chỉ có **1 PVC** dữ
> liệu DB (`datadir-cluster1-pxc-0`, 10Gi) + 1 PVC ProxySQL
> (`proxydata-cluster1-proxysql-0`, 1Gi) + 1 PVC shared
> (`shared-data`, 5Gi RWX).
> Hệ quả so với kiến trúc HA gốc: kiểm tra Galera ở mục 7 sẽ thấy
> `wsrep_cluster_size=1` (không phải 3); **không có test failover**
> (1 Pod — xóa Pod là DB ngừng tới khi Pod khởi động lại, dữ liệu vẫn
> còn trên PVC); HPA tối đa 4 Pod nhưng Pod web thứ 4 có thể Pending vì
> hết CPU. Muốn cấu hình đầy đủ (3 Pod PXC) thì dùng t3.xlarge trở lên
> và trả lại `pxc.size: 3`, `proxysql.size: 2` trong
> `k8s/db/pxc-values.yaml` (đồng thời bỏ `unsafeFlags` nếu đủ 3 Pod).

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
NetworkPolicy (mục 8 của guide này) — Flannel thì không.

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

**Tại sao:** HPA (mục 5.5 của guide này) scale Pod dựa trên CPU, mà dữ
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

Mục này toàn bộ là lệnh Helm/kubectl, không phụ thuộc hệ điều hành.
Các thành phần: **NGINX Ingress Controller** (nhận traffic HTTP từ
ngoài vào, qua NodePort 30080/30443), **Longhorn** (cấp volume bền cho
Pod: ổ RWO cho MySQL, ổ RWX cho thư mục shared), **PXC Operator**
(quản lý cluster MySQL theo kiểu Operator: bạn khai báo 1 CR
`PerconaXtraDBCluster`, Operator tự tạo StatefulSet/Service/Secret),
**Fluent Bit** (DaemonSet thu log toàn cluster).

```bash
# 0. Them Helm repo:
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add longhorn https://charts.longhorn.io
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# 0b. Giam CoreDNS xuong 1 replica (giai phong 100m CPU cho cau hinh nho).
# Node chi co 2 CPU; he thong (Longhorn/Calico/control-plane/Ingress...)
# da chiem ~1.5 CPU. CoreDNS mac dinh 2 replica (moi replica xin 100m) —
# giam xuong 1 de du cho cho PXC (200m) + ProxySQL (100m) + web (2x100m).
kubectl -n kube-system scale deployment coredns --replicas=1
kubectl -n kube-system wait --for=condition=Available deployment/coredns --timeout=180s

# 1. NGINX Ingress Controller (NodePort 30080/30443, 1 replica — cau hinh nho):
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version 4.12.1 \
  --set controller.replicaCount=1 \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443

# 2. Longhorn (replica 1 vi single-node):
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version 1.9.0 \
  --set defaultSettings.defaultReplicaCount=1

# 3. PXC Operator (quan ly cluster MySQL o muc 5):
# --set watchAllNamespaces=true la BAT BUOC: mac dinh Operator chi theo doi
# namespace cua chinh no (WATCH_NAMESPACE=pxc-operator), CR cluster1 nam o
# namespace production se bi bo qua hoan toan (STATUS trong, khong co event).
helm install pxc-operator percona/pxc-operator \
  --namespace pxc-operator --create-namespace \
  --version 1.17.0 \
  --set watchAllNamespaces=true

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

Toàn bộ là lệnh Docker chạy trên chính EC2 (Docker đã cài ở mục 2.14).
Dockerfile của app dùng layer cache (copy `package*.json` và `npm ci`
trước, copy source sau) nên build lại sau khi sửa code sẽ nhanh. Image
đẩy lên DockerHub để K8s pull về; repo public thì K8s pull không cần
đăng nhập, repo private thì cần Secret `dockerhub-pull` (xem dưới).

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
khi sang mục 5 của guide này (nên dùng access token thay vì mật khẩu:
DockerHub → Account Settings → Personal Access Tokens → Generate):

```bash
# Tao namespace truoc — Secret nam trong namespace production, ma namespace
# nay chi duoc tao o muc 5 neu khong tao o day (thieu buoc nay se loi
# "namespaces production not found"). Tao som khong anh huong gi: muc 5
# apply lai cung file nay, kubectl apply la idempotent.
kubectl apply -f k8s/00-namespace.yaml
kubectl create secret docker-registry dockerhub-pull \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<dockerhub-user> \
  --docker-password=<access-token> \
  --namespace production \
  --dry-run=client -o yaml | kubectl apply -f -
```

→ Chạy nhanh: `./scripts-al2023/04-build-push.sh` (build + push),
`DOCKERHUB_USER=<user> ./scripts-al2023/08-dockerhub-secret.sh`
(tạo Secret, hỏi token an toàn không hiện trên màn hình).

---

## 5. Deploy database + ứng dụng

### 5.1. Namespace + StorageClass + PVC shared

```bash
# Namespace production (moi thu cua app deu nam o day):
kubectl apply -f k8s/00-namespace.yaml

# 2 StorageClass Longhorn: longhorn-db (RWO, cho du lieu MySQL),
# longhorn-shared (RWX, cho thu muc shared giua cac Pod):
kubectl apply -f k8s/storage/storageclass-db.yaml
kubectl apply -f k8s/storage/storageclass-shared.yaml

# PVC shared-data 5Gi RWX: web + dispatcher + Job xu ly task dung chung
# de luu ket qua (file /app/shared/results/task-<id>.json):
kubectl apply -f k8s/storage/pvc-shared.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/shared-data -n production --timeout=300s
```

**Kiểm tra:** `kubectl -n production get pvc` — `shared-data` phải là
`Bound`.

### 5.2. Cài cluster PXC (MySQL + ProxySQL)

Trước hết tạo Secret chứa mật khẩu PXC (root, xtrabackup, monitor... —
giá trị fix sẵn trong file, xem mục 0):

```bash
kubectl apply -f k8s/db/pxc-secrets.yaml
```

Rồi cài cluster bằng Helm. File `k8s/db/pxc-values.yaml` đã chỉnh sẵn
cho cấu hình nhỏ, có 4 điểm quan trọng (đừng sửa khi chưa hiểu):

- **`fullnameOverride: cluster1`** — nếu không đặt, chart tự ghép tên
  release + tên chart thành `cluster1-pxc-db` làm tên CR, kéo theo
  Service `cluster1-pxc-db-proxysql` và Secret `cluster1-pxc-db-secrets`
  (chart suy tên Secret từ fullname) — lệch với mọi lệnh trong guide
  và với Secret `cluster1-secrets` đã tạo.
- **`unsafeFlags: {pxcSize: true, proxySize: true}`** — Operator từ
  chối chạy PXC dưới 3 Pod và proxy dưới 2 Pod nếu không bật 2 cờ này
  (cluster rơi vào trạng thái `error`).
- **ProxySQL thay HAProxy** — project này dùng ProxySQL làm proxy cho
  MySQL. HAProxy của Operator 1.17 dùng external-check (fork script
  kiểm tra Galera); trong môi trường này tiến trình con fork ra bị kẹt
  spin, không chạy được script, server mãi DOWN — đã thử mọi cách config
  (kể cả `nbthread 1`) đều không sửa được. ProxySQL tự kiểm tra MySQL
  bằng kết nối trực tiếp nên không gặp lỗi này. Lưu ý: Operator **cấm**
  đổi proxy trên cluster đã tạo (MySQL 8.0), nên phải dùng ProxySQL ngay
  từ lúc cài đầu tiên.
- **`proxysql.persistence.size: 1Gi`** — ProxySQL có PVC riêng, mặc
  định 8Gi; trên disk 30G thì 10Gi (DB) + 5Gi (shared) + 8Gi đã là 23Gi
  đặt trước, Longhorn không đủ chỗ tạo replica. ProxySQL chỉ lưu config
  và thống kê nên 1Gi là đủ.

```bash
helm install cluster1 percona/pxc-db \
  --namespace production \
  --version 1.17.0 \
  -f k8s/db/pxc-values.yaml

# Doi cluster Ready (lan dau 5-15 phut, PXC phai khoi tao Galera):
kubectl -n production get pxc cluster1 -w
# Ky vong: STATUS chuyen initializing -> Ready, PXC 1, PROXYSQL 1.
# Bam Ctrl+C de thoat watch khi thay Ready.
```

**Kiểm tra:**

```bash
kubectl -n production get pods
# Ky vong: cluster1-pxc-0 1/1 Running, cluster1-proxysql-0 Ready.
kubectl -n production get endpoints cluster1-proxysql
# Ky vong: co ENDPOINTS (IP cua Pod ProxySQL). Rong nghia la ProxySQL chua Ready.
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -h cluster1-proxysql -uroot -p'PxcRoot123!' -e "SELECT 1;"
# Ky vong: tra ve 1 — noi duoc MySQL qua ProxySQL.
```

Nếu `get pxc` đứng ở `initializing` quá 15 phút hoặc rơi vào `error`,
xem mục 10 (thường gặp nhất: volume Longhorn `faulted` vì hết chỗ đặt
trước, hoặc Pod PXC `Pending` vì hết CPU).

### 5.3. Tạo database + user app (Job db-init)

```bash
# Secret app-secret chua DB_HOST/DB_USER/DB_PASSWORD cho app doc:
kubectl apply -f k8s/app/app-secret.yaml

# Job db-init tao database appdb + user app (doc mat khau tu app-secret,
# noi MySQL qua ProxySQL):
kubectl apply -f <(sed "s|my-nodejs-app:v1|$IMAGE|g" k8s/db/db-init-job.yaml)
kubectl wait --for=condition=complete job/db-init -n production --timeout=600s
kubectl -n production logs job/db-init
# Ky vong: "[init-db] OK: database 'appdb' va user 'app' san sang."
```

Lưu ý: `sed` thay placeholder `my-nodejs-app:v1` bằng `$IMAGE` của bạn
(đã export ở mục 4). Nếu repo DockerHub là private thì Job cần
`imagePullSecrets` — file có sẵn marker `# __IMAGE_PULL_SECRETS__`,
script 05 tự xử lý; làm tay thì thêm `imagePullSecrets: [{name:
dockerhub-pull}]` vào Pod spec của Job (xem mẫu trong file).

### 5.4. Migrate + seed bảng tasks (Job db-migrate)

```bash
kubectl apply -f <(sed "s|my-nodejs-app:v1|$IMAGE|g" k8s/db/migrate-job.yaml)
kubectl wait --for=condition=complete job/db-migrate -n production --timeout=600s
kubectl -n production logs job/db-migrate
# Ky vong: "[migrate] OK: bang tasks san sang, hien co 5 dong."
```

Job này tạo bảng `tasks` (id, title, description, status, created_at,
updated_at) và seed 5 dòng mẫu. Chạy lại nhiều lần vẫn an toàn
(idempotent — migrate/seed kiểm tra trước khi tạo).

### 5.5. Deploy web (Deployment + Service + Ingress + HPA)

```bash
# Domain: neu co domain that thi export truoc; khong co thi dung nip.io
# theo IP public cua EC2 (khong can mua domain):
export DOMAIN="$(curl -fsSL --max-time 10 ifconfig.me | tr '.' '-').nip.io"
echo $DOMAIN

# Render 2 file co placeholder (image + host) roi apply:
# (Repo private: web-deployment.yaml cung co marker # __IMAGE_PULL_SECRETS__
# — thay bang khoi imagePullSecrets nhu o muc 5.3, hoac dung script 05.)
sed -e "s|my-nodejs-app:v1|$IMAGE|g" k8s/app/web-deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/app/web-service.yaml
sed -e "s|app.example.com|$DOMAIN|g" k8s/app/web-ingress.yaml | kubectl apply -f -
kubectl apply -f k8s/app/web-hpa.yaml
kubectl wait --for=condition=Available deployment/nodejs-web -n production --timeout=300s
```

Web có 2 Pod (cấu hình nhỏ), mỗi Pod có 2 probe: `/healthz` (liveness —
chỉ kiểm tra process còn sống) và `/readyz` (readiness — kiểm tra nối
được MySQL; Pod chỉ nhận traffic khi readiness pass). HPA scale 2–4 Pod
theo CPU; lưu ý Pod web thứ 4 có thể Pending vì hết CPU trên node 2 CPU.

**Kiểm tra:**

```bash
kubectl -n production get pods -l app=nodejs-web
# Ky vong: 2 Pod 1/1 Running.
kubectl -n production get ingress nodejs-ingress
# Ky vong: HOSTS = $DOMAIN.
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/readyz
# Ky vong: {"status":"ok","db":"up",...}
```

### 5.6. CronJob dispatcher + RBAC

Dispatcher chạy mỗi 5 phút: lấy task `todo` (tối đa 10 task/lần), đánh
dấu `doing`, tạo 1 Kubernetes Job cho mỗi task để xử lý; Job xử lý xong
thì task chuyển `done` và ghi kết quả ra thư mục shared. Dispatcher cần
quyền tạo Job nên phải có ServiceAccount + Role riêng:

```bash
kubectl apply -f k8s/worker/dispatcher-rbac.yaml
# (Repo private: worker-cronjob.yaml cung co marker # __IMAGE_PULL_SECRETS__ —
# thay bang khoi imagePullSecrets nhu o muc 5.3, hoac dung script 05.)
sed -e "s|my-nodejs-app:v1|$IMAGE|g" k8s/worker/worker-cronjob.yaml | kubectl apply -f -
kubectl -n production get cronjob task-worker
```

→ Chạy nhanh cả mục 5: `IMAGE=$IMAGE ./scripts-al2023/05-deploy.sh`
(thêm `--with-netpol` để bật NetworkPolicy ngay — khuyến nghị để sau
mục 7, khi web đã chạy ổn).

---

## 6. Mở web và thao tác database

Mở bằng trình duyệt: `http://<DOMAIN>:30080` (lấy domain bằng
`echo $DOMAIN`). Phải thấy trang Tasks với 5 dòng seed, thêm/sửa/xóa
được task. Task mới tạo ở trạng thái `todo` sẽ được dispatcher xử lý
trong vòng ~5 phút (hoặc kích hoạt ngay — xem mục 7.4).

Shell MySQL vào thẳng Pod PXC:

```bash
./scripts-al2023/07-db-shell.sh "SELECT id, title, status FROM tasks;"
./scripts-al2023/07-db-shell.sh   # shell tuong tac (database mac dinh appdb)
```

Trong shell MySQL:

```sql
SHOW TABLES;
SELECT * FROM tasks;
SHOW STATUS LIKE 'wsrep_cluster_size';   -- ky vong: 1 (cau hinh nho)
SHOW STATUS LIKE 'wsrep_local_state_comment';  -- ky vong: Synced
```

Port-forward để gọi API từ máy local (chạy trên EC2, mở `localhost`
trên chính EC2; muốn mở từ máy local thì SSH kèm `-L 3000:localhost:3000`):

```bash
kubectl -n production port-forward svc/nodejs-service 3000:80
curl http://localhost:3000/api/tasks
```

---

## 7. Kiểm tra toàn bộ

→ Chạy nhanh: `./scripts-al2023/06-verify.sh` (làm đúng các kiểm tra
dưới đây, in PASS/FAIL). Phần này là bản làm tay từng kiểm tra.

### 7.1. Trạng thái chung

```bash
kubectl -n production get pxc,pods,pvc,svc,ingress,hpa,cronjob
# Ky vong: PXC Ready; PXC 1/1, ProxySQL Ready, web 2/2 Running;
# PVC datadir + proxydata + shared-data deu Bound.
```

### 7.2. PXC + ProxySQL

```bash
kubectl -n production get pxc cluster1
# Ky vong: STATUS Ready, ENDPOINT cluster1-proxysql.production.
kubectl -n production get endpoints cluster1-proxysql
# Ky vong: co ENDPOINTS (khong rong).
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -h cluster1-proxysql -uroot -p'PxcRoot123!' -e "SELECT 1;"
# Ky vong: tra ve 1.
```

### 7.3. Web + CRUD

```bash
kubectl -n production port-forward svc/nodejs-service 3000:80 &
sleep 5
curl http://localhost:3000/healthz   # {"status":"ok",...}
curl http://localhost:3000/readyz     # {"status":"ok","db":"up",...}
curl http://localhost:3000/api/tasks   # 5 dong seed
curl -X POST http://localhost:3000/api/tasks -H "Content-Type: application/json" \
  -d '{"title":"Task test","status":"todo"}'     # tra ve task moi co id
curl -X PUT http://localhost:3000/api/tasks/<id> -H "Content-Type: application/json" \
  -d '{"status":"done"}'                          # status doi thanh done
curl -X DELETE http://localhost:3000/api/tasks/<id>  # tra ve deleted
kill %1
```

### 7.4. Dispatcher: task todo → Job → done

```bash
# Tao 1 task todo (lay id tu response):
curl -X POST http://localhost:3000/api/tasks -H "Content-Type: application/json" \
  -d '{"title":"Task test dispatcher","status":"todo"}'
# Kich hoat dispatcher ngay (khong doi lich 5 phut):
kubectl create job dispatch-test --from=cronjob/task-worker -n production
kubectl wait --for=condition=complete job/dispatch-test -n production --timeout=300s
# Doi Job xu ly task xong:
kubectl wait --for=condition=complete job -l task-id=<id> -n production --timeout=300s
curl http://localhost:3000/api/tasks/<id>   # ky vong: "status":"done"
# Ket qua xu ly co trong shared volume:
kubectl -n production exec deploy/nodejs-web -- cat /app/shared/results/task-<id>.json
# Ky vong: {"result": "ok", ...}
kubectl delete job dispatch-test -n production
```

### 7.5. Shared PVC (RWX): Pod 1 ghi, Pod 2 đọc

```bash
POD1=$(kubectl -n production get pods -l app=nodejs-web -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl -n production get pods -l app=nodejs-web -o jsonpath='{.items[1].metadata.name}')
kubectl -n production exec $POD1 -- sh -c 'echo hello-rwx > /app/shared/verify.txt'
kubectl -n production exec $POD2 -- cat /app/shared/verify.txt
# Ky vong: hello-rwx
```

### 7.6. Galera (cấu hình nhỏ: 1 node)

```bash
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' -N -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Ky vong: 1. Khong co quorum that — chi de test chuc nang.
# Test khoi dong lai (thay cho test failover 3-node): xoa Pod PXC,
# StatefulSet tao lai Pod moi, du lieu van con tren PVC:
kubectl -n production delete pod cluster1-pxc-0
kubectl -n production get pods -w   # doi Pod moi 1/1 Running
./scripts-al2023/07-db-shell.sh "SELECT COUNT(*) FROM tasks;"   # ky vong: 5 (+ task da tao)
```

### 7.7. Ingress

```bash
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/readyz
# Ky vong: {"status":"ok","db":"up",...}
# Mo web tu trinh duyet: http://<DOMAIN>:30080
```

### 7.8. HPA

```bash
kubectl -n production get hpa nodejs-hpa
# Ky vong: TARGETS hien CPU% (metrics-server da chay). Luu y: HPA toi da
# 4 Pod nhung Pod web thu 4 co the Pending vi het CPU tren node 2 CPU.
```


---

## 8. NetworkPolicy (bật cuối cùng)

Bật NetworkPolicy **sau khi web đã chạy ổn** (mục 7 pass hết) — nếu bật
sớm mà có lỗi thì khó biết lỗi do app hay do policy chặn traffic. Có 7
policy:

| File | Tác dụng |
| --- | --- |
| `netpol-default-deny.yaml` | Chặn hết traffic vào namespace `production` mặc định |
| `netpol-web-ingress.yaml` | Cho Ingress Controller gọi vào web |
| `netpol-app-to-db.yaml` | Cho web gọi ProxySQL |
| `netpol-app-egress-db.yaml` | Cho web ra ngoài tới ProxySQL (egress) |
| `netpol-pxc-internal.yaml` | Cho ProxySQL + Operator gọi vào PXC |
| `netpol-dispatcher-api.yaml` | Cho dispatcher gọi kube-apiserver (tạo Job) |
| `netpol-allow-dns.yaml` | Cho mọi Pod phân giải DNS (kube-dns) |

```bash
kubectl apply -f k8s/networkpolicy/
kubectl -n production get networkpolicy
# Kiem tra lai web van chay sau khi bat policy:
curl -H "Host: $DOMAIN" http://127.0.0.1:30080/readyz
# Ky vong: {"status":"ok","db":"up",...} — neu timeout thi 1 policy dang chan sai.
```

---

## 9. Backup

Project có sẵn `k8s/backup/pxc-backup-values.yaml` (cấu hình backup PXC
lên S3) và `k8s/backup/backup-s3-secret.yaml.example` (mẫu Secret chứa
key S3). Backup đang **tắt** (`backup.enabled: false` trong
`pxc-values.yaml`) vì chưa có S3 — bật khi chưa cấu hình storage sẽ làm
Operator báo lỗi. Khi nào có bucket S3 thì điền Secret theo mẫu, đổi
`backup.enabled: true`, rồi `helm upgrade`.

---

## 10. Xử lý sự cố

### 10.1. Lỗi riêng AL2023

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

### 10.2. Lỗi cluster / platform

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| `kubectl create -f custom-resources.yaml` lỗi `no matches for kind "Installation"` | Tigera-operator đăng ký CRD `Installation` không đồng bộ — apply custom-resources quá sớm | Đợi CRD xuất hiện + Established rồi apply lại: `kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=120s` |
| Script 03 lỗi `no matching resources found` khi đợi Operator | Selector sai tên, hoặc Pod chưa được tạo kịp | Pod Operator mang label `app.kubernetes.io/name=pxc-operator` (tên chart), KHÔNG phải `percona-xtradb-cluster-operator` (tên image). Script đã sửa; làm tay thì đợi Pod xuất hiện trước rồi mới `kubectl wait` |
| CR `cluster1` STATUS trống hoàn toàn, không event, Operator log chỉ có dòng khởi động | Operator mặc định chỉ theo dõi namespace của chính nó (`WATCH_NAMESPACE`), CR ở `production` bị bỏ qua | Cài/nâng cấp Operator với `--set watchAllNamespaces=true` |
| `helm upgrade` Operator lỗi Service `cannot be imported into the current release` | Service webhook `percona-xtradb-cluster-operator` đã tồn tại ngoài Helm (không có label/annotation Helm) — chart chỉ render Service này khi có `watchAllNamespaces=true` | Nhận Service vào release rồi upgrade lại: `kubectl -n pxc-operator label svc percona-xtradb-cluster-operator app.kubernetes.io/managed-by=Helm` + annotate `meta.helm.sh/release-name=pxc-operator` và `meta.helm.sh/release-namespace=pxc-operator` |
| `kubectl get nodes` chỉ thấy node `NotReady` | CNI chưa chạy (Calico chưa Ready) | `kubectl -n calico-system get pods`; đợi Calico Running rồi node sẽ Ready |

### 10.3. Lỗi PXC / ProxySQL / Longhorn

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| `helm install cluster1` xong nhưng `get pxc cluster1` NotFound, chỉ thấy CR `cluster1-pxc-db` | Thiếu `fullnameOverride: cluster1` — chart ghép tên release + tên chart làm tên CR, kéo theo secretsName sai | Thêm `fullnameOverride: cluster1` vào `k8s/db/pxc-values.yaml` rồi cài lại (file trong project đã có sẵn dòng này) |
| Cluster `error`, message `PXC size must be at least 3. Set spec.unsafeFlags.pxcSize to true` | Operator từ chối chạy PXC dưới 3 Pod khi không bật cờ test | Thêm `unsafeFlags: {pxcSize: true, proxySize: true}` vào `pxc-values.yaml` (file đã có sẵn) rồi `helm upgrade`. Lưu ý cờ proxy tên là `proxySize`, không phải `haproxySize` |
| Pod PXC `Pending` vì `Insufficient cpu` | Node 2 CPU hết chỗ: Pod PXC xin 900m (mặc định, gồm 2 sidecar logcollector) trong khi node chỉ còn ~410m trống | Cấu hình nhỏ trong project đã sửa: PXC 200m, `logcollector.enabled: false`, CoreDNS 1 replica. Đừng tăng size/resource khi chưa tính lại ngân sách CPU (`kubectl describe node` xem requests) |
| Đổi spec PXC xong mà Pod cũ vẫn Pending mãi, CR đã mới | Operator cập nhật CR nhưng không tạo lại Pod đang Pending (SmartUpdate đợi Pod cũ) | Xóa Pod Pending tay: `kubectl -n production delete pod cluster1-pxc-0` — StatefulSet tạo lại theo template mới |
| CR kẹt `Terminating` sau `helm uninstall` | Finalizer của Operator không được gỡ (CR chưa tạo tài nguyên nào) | Gỡ tay: `kubectl -n production patch pxc cluster1 --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'` |
| Pod PXC kẹt `Init:0/1`, event `FailedAttachVolume: volume is not ready for workloads`, volume Longhorn `faulted` | Longhorn tính dung lượng theo size PVC đã đặt trước (scheduled), không phải dữ liệu thực tế; volume cũ của PVC đã xóa vẫn nằm lại, cộng dồn vượt disk 30G | `kubectl -n longhorn-system get volume.longhorn.io` tìm volume mồ côi (kiểm tra không còn PV nào trỏ tới: `kubectl get pv \| grep <tên-volume>`), xóa bằng `kubectl -n longhorn-system delete volume.longhorn.io <tên-volume>`; volume mới tự tạo replica lại sau ~30s |
| Volume `proxydata` bị `faulted` | ProxySQL PVC mặc định 8Gi, cộng với datadir 10Gi + shared 5Gi = 23Gi đặt trước trên disk 30G | `pxc-values.yaml` đã đặt `proxysql.persistence.size: 1Gi`. Nếu cluster đã tạo với 8Gi: `helm upgrade` với values mới rồi xóa StatefulSet + PVC ProxySQL để Operator tạo lại (PVC không thu nhỏ được) |
| Operator log lỗi `for mysql version 8.0 you can't switch from HAProxy to ProxySQL` | Operator cấm đổi proxy trên cluster MySQL 8.0 đã tạo | Không sửa được bằng upgrade — phải xóa cluster và cài lại từ đầu với ProxySQL ngay từ lúc tạo (xem mục 11) |
| (Tham khảo) HAProxy server mãi `DOWN * PROCTOUT`, Pod 1/2, Service không có endpoint | Tiến trình con fork để chạy external-check bị kẹt spin, không exec được script — lỗi của HAProxy trong môi trường này, đã thử `nbthread 1` vẫn không sửa được | Project đã chuyển sang ProxySQL nên không gặp nữa. Nếu bạn tự đổi lại HAProxy và gặp lỗi này thì đó là nguyên nhân |

### 10.4. Lỗi app / deploy

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| `docker: command not found` khi chạy script 04 | Bỏ qua bước 02 (cài Docker) | Chạy `sudo ./scripts-al2023/02-install-docker.sh`, đăng xuất/đăng nhập lại rồi chạy lại 04 |
| Tạo Secret dockerhub lỗi `namespaces "production" not found` | Namespace chỉ được tạo ở mục 5.1, chưa chạy tới đó | `kubectl apply -f k8s/00-namespace.yaml` trước rồi tạo Secret lại (script 08 đã tự làm việc này) |
| Web báo `db:down` (`/readyz` 503) | App không nối được MySQL: sai DB_HOST, ProxySQL chưa Ready, hoặc Secret sai | Kiểm tra `kubectl -n production get endpoints cluster1-proxysql` (phải có endpoint); kiểm tra `app-secret` (DB_HOST phải là `cluster1-proxysql.production.svc.cluster.local`); kiểm tra `kubectl -n production get pxc` (phải Ready) |
| Pod web `ImagePullBackOff` | Repo private nhưng thiếu Secret, hoặc sai tên image | Repo private: tạo Secret bằng script 08 rồi deploy lại. Kiểm tra tên image: `kubectl -n production describe pod <web-pod> \| grep Image` |
| Job db-init/db-migrate `Failed` | DB chưa Ready, hoặc sai DB_HOST/mật khẩu | Xem log: `kubectl -n production logs job/db-init`. Đợi PXC Ready rồi xóa Job và chạy lại (`kubectl delete job db-init -n production` rồi apply lại) |
| Dispatcher không tạo Job | CronJob chưa tới lịch (5 phút/lần), hoặc RBAC thiếu quyền | Kích hoạt tay: `kubectl create job <tên> --from=cronjob/task-worker -n production`; kiểm tra Role `task-dispatcher` có quyền `create jobs` |
| HPA Pod web thứ 4 `Pending` | Hết CPU trên node 2 CPU | Bình thường với cấu hình nhỏ — HPA tối đa 4 Pod nhưng node chỉ đủ chỗ cho ~3 Pod web. Muốn đủ 4 Pod thì dùng instance lớn hơn |

---

## 11. Dọn dẹp và cài lại

### 11.1. Dọn sạch toàn bộ (teardown)

```bash
./scripts-al2023/teardown.sh --yes
# Xoa app + PXC + platform + volume Longhorn mo coi + PV Released.
# Cluster K8s van giu nguyen — chay lai tu buoc 3 (muc 3) neu muon dung lai.
```

Làm tay (đúng thứ tự teardown làm): xóa app/worker/netpol/Job →
`helm uninstall cluster1` (CR kẹt Terminating thì patch gỡ finalizer,
xem mục 10.3) → xóa PVC datadir + proxydata + shared + StorageClass →
xóa namespace `production` → xóa PV Released thuộc `production` → xóa
volume Longhorn mồ côi (không còn PV nào trỏ tới) → `helm uninstall`
fluent-bit, pxc-operator, longhorn, ingress-nginx.

Muốn dọn cả cluster K8s (về EC2 trống):

```bash
sudo kubeadm reset --force
sudo rm -rf /etc/cni/net.d /var/lib/longhorn
sudo rm -rf $HOME/.kube/config
```

### 11.2. Chỉ cài lại PXC (giữ nguyên platform)

```bash
helm uninstall cluster1 -n production
kubectl -n production delete pvc datadir-cluster1-pxc-0 proxydata-cluster1-proxysql-0
# Kiem tra + xoa volume Longhorn mo coi neu con:
kubectl -n longhorn-system get volume.longhorn.io
kubectl -n longhorn-system delete volume.longhorn.io <ten-volume-cu>  # neu co
helm install cluster1 percona/pxc-db --namespace production --version 1.17.0 -f k8s/db/pxc-values.yaml
kubectl -n production get pods -w   # doi cluster1-pxc-0 1/1 va cluster1-proxysql-0 Ready
# Chay lai tu muc 5.3 (db-init) tro di — app-secret da co, Job cu da xoa.
```

---

## Phụ lục A. Đối chiếu mục guide ↔ script AL2023

| Mục (làm tay) | Script tương ứng (chạy nhanh) |
| --- | --- |
| 2.1–2.8 Chuẩn bị node (dnf, SELinux, iscsi/nfs, containerd, K8s RPM, Helm) | `sudo ./scripts-al2023/00-prepare-nodes.sh` |
| 2.9–2.13 kubeadm init + Calico + metrics-server + gỡ taint | `sudo ./scripts-al2023/01-init-control-plane.sh` |
| 2.14 Cài Docker | `sudo ./scripts-al2023/02-install-docker.sh` |
| 3. Cài nền tảng Helm (+ CoreDNS 1 replica) | `./scripts-al2023/03-install-platform.sh` |
| 4. Build + push image | `./scripts-al2023/04-build-push.sh` (cần `IMAGE` + `docker login` trước) |
| 4. Secret repo private | `DOCKERHUB_USER=<user> ./scripts-al2023/08-dockerhub-secret.sh` |
| 5. Deploy DB + app | `IMAGE=... ./scripts-al2023/05-deploy.sh` (thêm `--with-netpol` để bật NetworkPolicy ngay) |
| 6. Shell MySQL | `./scripts-al2023/07-db-shell.sh ["<lenh SQL>"]` |
| 7. Kiểm tra toàn bộ | `./scripts-al2023/06-verify.sh` |
| 8. Bật NetworkPolicy | `kubectl apply -f k8s/networkpolicy/` (không có script riêng — chỉ 1 lệnh) |
| 11. Dọn dẹp | `./scripts-al2023/teardown.sh` |

## Phụ lục B. Kiến trúc (tóm tắt)

```text
Internet -> Security Group (30080/30443) -> NodePort Service
  -> NGINX Ingress Controller (1 Pod) -> Ingress nodejs-ingress
  -> Service nodejs-service -> web Deployment (2 Pod, HPA 2-4)
  -> Secret app-secret (DB_HOST) -> Service cluster1-proxysql
  -> ProxySQL (1 Pod) -> PXC MySQL (1 Pod, PVC longhorn-db 10Gi)
CronJob task-worker (5 phut/lan) -> Job xu ly task (1 Job/task)
  -> ket qua ghi vao PVC shared-data (RWX 5Gi, Longhorn)
Fluent Bit (DaemonSet) thu log toan cluster.
```

**Giới hạn của cấu hình nhỏ (đã nói ở mục 1):** 1 node duy nhất nên
không có HA thật — mất node là mất hết; PXC 1 Pod nên không có quorum
Galera, mất Pod là DB ngừng tới khi Pod khởi động lại (dữ liệu vẫn còn
trên PVC). Đây là môi trường test/học, không phải production.
