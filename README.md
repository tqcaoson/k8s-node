# Kubernetes Native Web Platform — Demo đầy đủ trên 1 EC2

Project triển khai hệ thống Node.js trên Kubernetes **single-node**
(1 EC2 duy nhất) theo guide `Kubernetes_Native_Web_Platform.md`:
NGINX Ingress, web 2 Pod (HPA), PXC MySQL + ProxySQL, Longhorn
(RWO + RWX), CronJob dispatcher, Fluent Bit, 7 NetworkPolicy — kèm
**source Node.js CRUD thật**, migrate + seed sẵn, env đã fix sẵn, và
script setup từng bước.

Toàn bộ chạy trên 1 EC2: cài K8s, cài Docker để build image rồi push
lên DockerHub, K8s pull image về chạy. EC2 và Security Group bạn tự tạo
trước — project bắt đầu từ 1 EC2 rỗng (Amazon Linux 2023 hoặc
Ubuntu 22.04).

**Cấu hình mặc định là cấu hình nhỏ** (cho t3.large 2 CPU/8GB, disk
30 GB): PXC **1 Pod**, ProxySQL **1 Pod**, web **2 Pod**, Ingress
**1 Pod**, CoreDNS 1 replica, logcollector tắt. Đủ để test đầy đủ chức
năng; không phải HA thật (xem lưu ý cuối README).

## Hướng dẫn (2 bản cho AL2023, 1 bản cho Ubuntu)

| File | Dùng khi nào |
| --- | --- |
| **[HUONG-DAN-SHELL-AL2023.md](HUONG-DAN-SHELL-AL2023.md)** | Muốn chạy nhanh: chạy các script `scripts-al2023/` theo thứ tự |
| **[HUONG-DAN-SETUP-AL2023.md](HUONG-DAN-SETUP-AL2023.md)** | Muốn hiểu K8s: chạy tay từng lệnh có giải thích (AL2023) |
| **[HUONG-DAN-SETUP.md](HUONG-DAN-SETUP.md)** | Dùng Ubuntu 22.04 (bản làm tay; script trong `scripts/`) |

## Kiến trúc (tất cả trên 1 EC2)

```text
Internet -> EC2 NodePort 30080 -> NGINX Ingress (1 Pod)
  -> Service nodejs-service -> Deployment nodejs-web (2 Pod, HPA toi 4)
       |-> emptyDir /app/tmp (tam, rieng tung Pod)
       |-> PVC shared-data RWX (Longhorn, dung chung voi Job)
       |-> ProxySQL (cluster1-proxysql:3306)
             -> PXC 1 Pod Galera, 1 PVC RWO 10Gi (longhorn-db)
CronJob task-worker (moi 5 phut, dispatcher):
  lay task todo -> tao 1 K8s Job xu ly tung task -> task chuyen sang done
DaemonSet Fluent Bit (1 Pod) -> thu log
```

> ⚠️ Cấu hình nhỏ chỉ để **test chức năng**, không có HA thật: PXC 1 Pod
> nên không có quorum Galera (`wsrep_cluster_size=1`), mất Pod là DB
> ngừng tới khi Pod khởi động lại (dữ liệu vẫn còn trên PVC); Longhorn
> replica 1; mất node là mất cả cụm. Muốn HA thật cần 3 node + 3 Pod PXC
> như guide gốc.

## Chạy thử nhanh trên máy local (không cần K8s)

```bash
docker compose up --build
# Mo http://localhost:3000 — CRUD cong viec, du lieu vao MySQL 8.0
```

## Chạy trên EC2 (AL2023)

**Cách nhanh:** chạy các script theo thứ tự (xem
[HUONG-DAN-SHELL-AL2023.md](HUONG-DAN-SHELL-AL2023.md)):

```bash
sudo ./scripts-al2023/00-prepare-nodes.sh
sudo ./scripts-al2023/01-init-control-plane.sh
sudo ./scripts-al2023/02-install-docker.sh
# Dang xuat SSH roi dang nhap lai (de nhan nhom docker), roi:
./scripts-al2023/03-install-platform.sh
export IMAGE=<dockerhub-user>/k8s-web-demo:v1
docker login
./scripts-al2023/04-build-push.sh
# Chi khi repo DockerHub la private (repo public bo qua):
DOCKERHUB_USER=<dockerhub-user> ./scripts-al2023/08-dockerhub-secret.sh
IMAGE=<dockerhub-user>/k8s-web-demo:v1 ./scripts-al2023/05-deploy.sh
./scripts-al2023/06-verify.sh
```

**Cách học (khuyến nghị):** làm theo
[HUONG-DAN-SETUP-AL2023.md](HUONG-DAN-SETUP-AL2023.md), chạy tay từng
lệnh từ mục 2 tới mục 7 — mỗi lệnh có giải thích làm gì, tại sao cần,
và kiểm tra kết quả ra sao.

Mở web tại `http://<IP-public-EC2-dang-nip-io>:30080` (script 05 in ra URL
chính xác khi chạy xong).

## App demo: 1 bảng `tasks` + xử lý tự động

| Cột | Kiểu | Ghi chú |
| --- | --- | --- |
| id | INT AUTO_INCREMENT PK | |
| title | VARCHAR(255) NOT NULL | Tiêu đề công việc |
| description | TEXT NULL | Mô tả |
| status | ENUM(todo, doing, done) | Mặc định `todo` |
| created_at / updated_at | TIMESTAMP | Tự động |

API: `GET/POST /api/tasks`, `GET/PUT/DELETE /api/tasks/:id`,
`GET /healthz` (process sống), `GET /readyz` (nối được MySQL).
Seed sẵn 5 công việc mẫu.
Migrate + seed chạy 2 lớp: Job `db-migrate` và web tự migrate lúc khởi động.

**Luồng xử lý task:** task tạo ra ở trạng thái `todo` sẽ được CronJob
`task-worker` (dispatcher, mỗi 5 phút) lấy về, claim nguyên tử sang
`doing`, rồi tạo **1 K8s Job riêng xử lý từng task**
(`src/process-task.js`, kết quả ghi ra `/app/shared/results/task-<id>.json`).
Xử lý xong task chuyển sang `done`. Task kẹt ở `doing` quá 10 phút
(Job chết giữa chừng) được dispatcher tự reset về `todo` để xử lý lại.
Tạo task trên UI rồi đợi tối đa 5 phút là thấy nó tự chuyển sang done.

## Env đã fix sẵn (chỉ dùng để TEST)

| Biến | Giá trị | Ở đâu |
| --- | --- | --- |
| DB_HOST | `cluster1-proxysql.production.svc.cluster.local` | `k8s/app/app-secret.yaml` |
| DB_PORT / DB_NAME / DB_USER | `3306` / `appdb` / `app` | `k8s/app/app-secret.yaml` |
| DB_PASSWORD | `AppPass123!` | `k8s/app/app-secret.yaml` |
| PXC root | `PxcRoot123!` | `k8s/db/pxc-secrets.yaml` |
| PXC nội bộ (xtrabackup/monitor/clustercheck/proxyadmin/operator/replication) | `PxcXtra123!` / `PxcMon123!` / `PxcCheck123!` / `PxcProxy123!` / `PxcOper123!` / `PxcRepl123!` | `k8s/db/pxc-secrets.yaml` |
| Image placeholder | `my-nodejs-app:v1` (script 05 thay bằng `$IMAGE`) | `k8s/app/web-deployment.yaml` |
| Domain mặc định | `<IP-public>.nip.io` (script 05 tự sinh) | `k8s/app/web-ingress.yaml` |

> ⚠️ Mật khẩu trên là **test-only**. Lên production phải đổi hết và dùng
> Sealed Secrets / External Secrets, không commit Secret lên Git.

## Cấu trúc project

```text
app/                  Source Node.js (Express + mysql2)
  src/server.js       Web + API CRUD + /healthz + /readyz
  src/routes/tasks.js CRUD bang tasks
  src/migrate.js      Migrate + seed (idempotent)
  src/init-db.js      Tao database + user app bang quyen root
  src/worker.js       Dispatcher CronJob: lay task todo, tao Job xu ly
  src/process-task.js Xu ly 1 task (chay trong Job do dispatcher tao)
  src/k8s-client.js   Client toi thieu goi K8s API (tao Job, kiem tra Secret)
  src/db.js, config.js Pool MySQL + cau hinh env
  db/migrate.sql, seed.sql
  public/             UI CRUD tieng Viet
  Dockerfile
k8s/                  Manifest theo guide (namespace, storage, PXC, app,
                      worker, networkpolicy, logging, backup) + kustomization
scripts-al2023/       Script chay nhanh cho Amazon Linux 2023:
                      00-prepare -> 01-init -> 02-docker -> 03-platform
                      -> 04-build-push -> 05-deploy -> 06-verify
                      -> 07-db-shell, 08-dockerhub-secret, teardown
scripts/              Script chay nhanh cho Ubuntu 22.04 (cung thu tu)
docker-compose.yml    Test local: MySQL 8.0 + app
HUONG-DAN-SHELL-AL2023.md   Guide chay nhanh bang shell (AL2023)
HUONG-DAN-SETUP-AL2023.md   Guide lam tay tung lenh (AL2023)
HUONG-DAN-SETUP.md          Guide lam tay tung lenh (Ubuntu 22.04)
```

## Khác biệt so với guide gốc (đều có ghi chú trong file)

- **Single-node thay vì 4 node:** bỏ taint control-plane để Pod chạy trên
  node duy nhất; bỏ anti-affinity hostname của PXC/proxy (để lại thì
  Pod Pending); Longhorn replica 1 thay vì 3.
- **Cấu hình nhỏ cho t3.large (2 CPU/8GB):** PXC 1 Pod (requests 200m,
  limits 1 CPU/2Gi), ProxySQL 1 Pod (100m), web 2 Pod × 100m, dispatcher
  100m, logcollector tắt, CoreDNS 1 replica, Ingress 1 replica.
  `unsafeFlags` bật để Operator cho chạy dưới 3 Pod.
- **ProxySQL thay HAProxy:** HAProxy của Operator 1.17 dùng external-check
  (fork script kiểm tra Galera) — trong môi trường này tiến trình con
  fork ra bị kẹt spin, server mãi DOWN, không sửa được bằng config
  (đã thử `nbthread 1`). ProxySQL tự kiểm tra MySQL bằng kết nối trực
  tiếp nên không gặp lỗi này. Operator cấm đổi proxy trên cluster đã
  tạo nên phải dùng ProxySQL ngay từ đầu.
- PVC test nhỏ lại: shared 5Gi, mỗi MySQL 10Gi (gốc 100Gi), proxydata
  1Gi (mặc định 8Gi — quá lớn cho disk 30G); tăng sau được.
- Ingress mặc định **NodePort 30080/30443** thay vì LoadBalancer, vì kubeadm
  trên EC2 không có cloud controller để cấp LoadBalancer.
- `backup.enabled=false` mặc định (gốc bật nhưng chưa có storage S3);
  bật sau theo `k8s/backup/`.
- Thêm Job `db-init` + `db-migrate` để không phải chạy tay lệnh MySQL.
- Thêm **dispatcher**: CronJob không chỉ đếm task mà lấy task `todo` và
  tạo K8s Job xử lý từng task, kèm RBAC least-privilege.
- Probe tách ra: readiness dùng `/readyz` (kiểm tra MySQL), liveness dùng
  `/healthz` (chỉ kiểm tra process) — guide gốc dùng `/healthz` cho cả hai,
  khi mất DB sẽ làm K8s restart Pod liên tục.
- Sửa 2 lỗi NetworkPolicy của guide gốc: rule tới Operator thiếu
  `namespaceSelector` (Operator ở namespace khác), và proxy thiếu egress
  tới PXC (bị default-deny chặn).
- Operator cài với `watchAllNamespaces=true` (bắt buộc — mặc định Operator
  chỉ theo dõi namespace của chính nó nên CR ở `production` bị bỏ qua).
