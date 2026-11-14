# Hướng dẫn chạy nhanh bằng shell (AL2023)

Bản chạy nhanh cho **1 EC2 Amazon Linux 2023**: chạy các script trong
`scripts-al2023/` theo đúng thứ tự, mỗi bước có điểm kiểm tra. Muốn hiểu
từng lệnh làm gì, xem bản tay
[`HUONG-DAN-SETUP-AL2023.md`](HUONG-DAN-SETUP-AL2023.md) (cùng nội dung,
chạy từng lệnh có giải thích).

**Đã chốt:** 1 EC2 duy nhất (bạn tự tạo), t3.large 2 CPU/8GB, disk
30 GB, cấu hình nhỏ (PXC 1 Pod, ProxySQL 1 Pod, web 2 Pod). Mọi env và
mật khẩu test đã fix sẵn trong project — thứ duy nhất bạn phải điền là
**`IMAGE`** (tên image trên DockerHub của bạn, mục 4).

## 0. Chuẩn bị

| Hạng mục | Yêu cầu |
| --- | --- |
| EC2 | Amazon Linux 2023, **t3.large** (2 vCPU, 8 GB), disk **30 GB** gp3, có public IP |
| Security Group | Mở **22** (SSH) + **30080, 30443** (Ingress NodePort). **Đừng mở 3306** |
| DockerHub | Có tài khoản + access token (nếu dùng repo private) |
| Máy local | Đã giải nén project `k8s-native-web-platform/` |

Copy project lên EC2 rồi vào trong đó:

```bash
scp -i <key.pem> -r k8s-native-web-platform ec2-user@<IP-EC2>:~/
ssh -i <key.pem> ec2-user@<IP-EC2>
cd ~/k8s-native-web-platform
chmod +x scripts-al2023/*.sh
```

Từ đây trở đi, mọi lệnh chạy trên EC2.

## Thứ tự chạy (đừng bỏ bước nào)

| # | Lệnh | Làm gì | Mất bao lâu |
| --- | --- | --- | --- |
| 0 | `sudo ./scripts-al2023/00-prepare-nodes.sh` | Cài containerd, kubeadm/kubelet/kubectl, Helm; SELinux permissive; iscsi/nfs | ~5–10 phút |
| 1 | `sudo ./scripts-al2023/01-init-control-plane.sh` | `kubeadm init` + Calico + metrics-server, gỡ taint | ~3–5 phút |
| 2 | `sudo ./scripts-al2023/02-install-docker.sh` | Cài Docker để build image | ~2 phút |
| 3 | `./scripts-al2023/03-install-platform.sh` | Helm: Ingress + Longhorn + PXC Operator + Fluent Bit; CoreDNS về 1 replica | ~5–10 phút |
| 4 | `docker login` rồi `export IMAGE=...` + `./scripts-al2023/04-build-push.sh` | Build + push image app lên DockerHub | ~3–5 phút |
| 4b | `DOCKERHUB_USER=<user> ./scripts-al2023/08-dockerhub-secret.sh` | **Chỉ khi repo là private**: tạo Secret pull image | ~1 phút |
| 5 | `IMAGE=... ./scripts-al2023/05-deploy.sh` | Deploy namespace, PXC + ProxySQL, db-init, migrate, web, CronJob | ~10–20 phút |
| 6 | `./scripts-al2023/06-verify.sh` | Kiểm tra toàn bộ (PXC, ProxySQL, CRUD, dispatcher, RWX, Ingress) | ~5 phút |

## 1. Chuẩn bị node + cluster (bước 0–2)

```bash
sudo ./scripts-al2023/00-prepare-nodes.sh
sudo ./scripts-al2023/01-init-control-plane.sh
sudo ./scripts-al2023/02-install-docker.sh
# Dang xuat SSH roi dang nhap lai (hoac chay 'newgrp docker')
# de dung docker khong can sudo.
newgrp docker
kubectl get nodes
# Ky vong: 1 node Ready, vai tro control-plane.
```

## 2. Cài nền tảng (bước 3)

```bash
./scripts-al2023/03-install-platform.sh
helm list -A
# Ky vong: 4 release — ingress-nginx, longhorn, pxc-operator, fluent-bit.
kubectl get pods -n pxc-operator
# Ky vong: Pod operator 1/1 Running (label app.kubernetes.io/name=pxc-operator).
```

## 3. Build + push image (bước 4)

```bash
export IMAGE=<dockerhub-user>/k8s-web-demo:v1
docker login
./scripts-al2023/04-build-push.sh

# Chi khi repo DockerHub la PRIVATE (bo qua neu repo public):
DOCKERHUB_USER=<dockerhub-user> ./scripts-al2023/08-dockerhub-secret.sh
# Nhap access token khi duoc hoi (khong hien tren man hinh).
```

## 4. Deploy (bước 5)

```bash
IMAGE=$IMAGE ./scripts-al2023/05-deploy.sh
# Script tu lay IP public cua EC2 lam domain <ip>.nip.io.
# Co domain that thi: DOMAIN=app.example.com IMAGE=$IMAGE ./scripts-al2023/05-deploy.sh
# Muon bat NetworkPolicy ngay: them --with-netpol (khuyen nghi: kiem tra
# web chay on truoc roi moi bat sau bang: kubectl apply -f k8s/networkpolicy/)
```

Cuối script in ra địa chỉ web, ví dụ `http://1-2-3-4.nip.io:30080`.
Mở bằng trình duyệt — phải thấy trang Tasks với 5 dòng seed.

## 5. Kiểm tra toàn bộ (bước 6)

```bash
./scripts-al2023/06-verify.sh
# Ky vong: tat ca PASS, 0 FAIL.
```

## Lệnh dùng hằng ngày

```bash
./scripts-al2023/07-db-shell.sh "SELECT * FROM tasks;"   # shell MySQL / chay 1 lenh SQL
kubectl -n production get pxc,pods,pvc                    # trang thai DB
kubectl -n production logs deploy/nodejs-web --tail=50    # log web
kubectl -n production get jobs                            # Job xu ly task (dispatcher tao)
kubectl apply -f k8s/networkpolicy/                       # bat NetworkPolicy (sau khi web chay on)
```

## Cài lại từ đầu (khi muốn làm lại sạch)

```bash
./scripts-al2023/teardown.sh --yes
# Teardown xoa app + PXC + platform + volume Longhorn mo coi + PV Released.
# Sau do chay lai tu buoc 3 (platform) — cluster K8s van giu nguyen.
./scripts-al2023/03-install-platform.sh
# ... roi tiep buoc 4, 5, 6 nhu tren (image da push roi thi co the bo qua buoc 4).
```

Chỉ cài lại riêng PXC (giữ nguyên platform + app image):

```bash
helm uninstall cluster1 -n production
kubectl -n production delete pvc datadir-cluster1-pxc-0 proxydata-cluster1-proxysql-0
# Xoa volume Longhorn mo coi neu con (kiem tra truoc):
kubectl -n longhorn-system get volume.longhorn.io
kubectl -n longhorn-system delete volume.longhorn.io <ten-volume-cu>  # neu co
helm install cluster1 percona/pxc-db --namespace production --version 1.17.0 -f k8s/db/pxc-values.yaml
kubectl -n production get pods -w   # doi cluster1-pxc-0 1/1 va cluster1-proxysql-0 Ready
IMAGE=$IMAGE ./scripts-al2023/05-deploy.sh   # chay lai deploy (db-init/migrate/web)
```

## Xử lý sự cố (gọn — bảng đầy đủ xem guide bản tay, mục 10)

| Triệu chứng | Cách xử lý nhanh |
| --- | --- |
| Script 04 báo không chạy được docker | Chưa vào nhóm docker: đăng xuất SSH rồi đăng nhập lại, hoặc `newgrp docker` |
| Script 05 báo chưa có CRD PerconaXtraDBCluster | Chưa chạy bước 3: chạy `./scripts-al2023/03-install-platform.sh` trước |
| PXC `initializing` mãi, Pod PXC kẹt `Init:0/1` | Volume Longhorn bị `faulted` vì hết chỗ đặt trước: `kubectl -n longhorn-system get volume.longhorn.io`, xóa volume mồ côi (không còn PVC nào trỏ tới) bằng `kubectl -n longhorn-system delete volume.longhorn.io <tên-volume>` |
| PXC `error`, message nhắc `unsafeFlags` | File `k8s/db/pxc-values.yaml` thiếu `unsafeFlags` — lấy lại file đúng trong project rồi `helm upgrade` |
| Pod PXC `Pending` vì `Insufficient cpu` | Node hết CPU: kiểm tra `kubectl describe node` xem requests; cấu hình nhỏ trong project đã tính đủ cho t3.large — đừng tăng size/resource khi chưa tính lại |
| PXC `Ready` nhưng web báo `db:down` | Kiểm tra Service ProxySQL có endpoint: `kubectl -n production get endpoints cluster1-proxysql`; kiểm tra Secret `app-secret` (DB_HOST phải là `cluster1-proxysql...`) |
| `helm upgrade` operator báo Service `cannot be imported` | Service webhook đã tồn tại ngoài Helm: gắn label/annotation Helm cho Service rồi upgrade lại (xem guide bản tay, mục 10) |
| Muốn đổi HAProxy ↔ ProxySQL trên cluster đã tạo | Operator cấm (MySQL 8.0). Phải cài lại PXC từ đầu với proxy mong muốn ngay từ lúc tạo |
