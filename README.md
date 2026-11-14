# Kubernetes Native Web Platform — Demo đầy đủ trên 1 EC2

Project triển khai hệ thống Node.js trên Kubernetes **single-node**
(1 EC2 duy nhất) theo guide `Kubernetes_Native_Web_Platform.md`:
NGINX Ingress, web 2 Pod (HPA), PXC MySQL 3 Pod (Galera),
Longhorn (RWO + RWX), CronJob dispatcher, Fluent Bit, 7 NetworkPolicy —
kèm **source Node.js CRUD thật**, migrate + seed sẵn, env đã fix sẵn,
và script setup từng bước.

Toàn bộ chạy trên 1 EC2: cài K8s, cài Docker để build image rồi push
lên DockerHub, K8s pull image về chạy. EC2 và Security Group bạn tự tạo
trước — project bắt đầu từ 1 EC2 Ubuntu 22.04 rỗng.

Hướng dẫn chi tiết: **[HUONG-DAN-SETUP.md](HUONG-DAN-SETUP.md)** — viết theo
hướng **làm tay từng lệnh để hiểu K8s** (mỗi lệnh có giải thích và điểm
kiểm tra). Các script trong `scripts/` chỉ là lối tắt chạy nhanh, làm đúng
các bước trong guide — mở ra đối chiếu khi cần.

## Kiến trúc (tất cả trên 1 EC2)

```text
Internet -> EC2 NodePort 30080 -> NGINX Ingress (2 Pod)
  -> Service nodejs-service -> Deployment nodejs-web (2 Pod, HPA toi 4)
       |-> emptyDir /app/tmp (tam, rieng tung Pod)
       |-> PVC shared-data RWX (Longhorn, dung chung voi Job)
       |-> PXC HAProxy (cluster1-haproxy:3306)
             -> PXC 3 Pod Galera tren cung 1 node, moi Pod 1 PVC RWO
CronJob task-worker (moi 5 phut, dispatcher):
  lay task todo -> tao 1 K8s Job xu ly tung task -> task chuyen sang done
DaemonSet Fluent Bit (1 Pod) -> thu log
```

> ⚠️ Single-node chỉ để **test chức năng**, không có HA thật: 3 Pod PXC
> cùng nằm trên 1 node (Galera quorum vẫn chạy về logic), Longhorn
> replica 1. Mất node là mất cả cụm. Muốn HA thật cần 3 node như guide gốc.

## Chạy thử nhanh trên máy local (không cần K8s)

```bash
docker compose up --build
# Mo http://localhost:3000 — CRUD cong viec, du lieu vao MySQL 8.0
```

## Chạy trên EC2

**Cách học (khuyến nghị):** làm theo **[HUONG-DAN-SETUP.md](HUONG-DAN-SETUP.md)**,
chạy tay từng lệnh từ mục 2 tới mục 7 — mỗi lệnh có giải thích làm gì, tại
sao cần, và kiểm tra kết quả ra sao. Các bước lớn:

1. Chuẩn bị node (tắt swap, kernel, containerd, kubeadm/kubectl, Helm)
2. `kubeadm init` + Calico + metrics-server + gỡ taint + cài Docker
3. Cài nền tảng bằng Helm (ingress, Longhorn, PXC Operator, Fluent Bit)
4. Build + push image lên DockerHub
5. Deploy DB + app theo từng bước (storage → PXC → Job → web → CronJob)
6. Kiểm tra toàn bộ bằng tay (CRUD, dispatcher, RWX, Galera, failover)

**Cách nhanh:** chạy các script theo thứ tự (mỗi script làm đúng các bước
trong mục guide tương ứng — xem Phụ lục B trong guide để đối chiếu):

```bash
sudo ./scripts/00-prepare-nodes.sh
sudo ./scripts/01-init-control-plane.sh
sudo ./scripts/02-install-docker.sh
# Dang xuat SSH roi dang nhap lai (de nhan nhom docker), roi:
./scripts/03-install-platform.sh
export IMAGE=<dockerhub-user>/k8s-web-demo:v1
docker login
./scripts/04-build-push.sh
# Chi khi repo DockerHub la private (repo public bo qua):
DOCKERHUB_USER=<dockerhub-user> ./scripts/08-dockerhub-secret.sh
IMAGE=<dockerhub-user>/k8s-web-demo:v1 ./scripts/05-deploy.sh
./scripts/06-verify.sh
```

Mở web tại `http://<IP-public-EC2-dang-nip-io>:30080` (mục 5.7 trong guide
hướng dẫn cách lấy URL chính xác).

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
| DB_HOST | `cluster1-haproxy.production.svc.cluster.local` | `k8s/app/app-secret.yaml` |
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
scripts/              Loi tat chay nhanh (moi script lam dung cac buoc
                      trong muc guide tuong ung — xem Phu luc B):
                      00-prepare -> 01-init -> 02-docker -> 03-platform
                      -> 04-build-push -> 05-deploy -> 06-verify
                      -> 07-db-shell, 08-dockerhub-secret, teardown
docker-compose.yml    Test local: MySQL 8.0 + app
HUONG-DAN-SETUP.md    Guide setup day du tren EC2
```

## Khác biệt so với guide gốc (đều có ghi chú trong file)

- **Single-node thay vì 4 node:** bỏ taint control-plane để Pod chạy trên
  node duy nhất; bỏ anti-affinity hostname của PXC/HAProxy (để lại thì
  2/3 PXC Pod Pending); Longhorn replica 1 thay vì 3.
- PVC test nhỏ lại: shared 5Gi, mỗi MySQL 10Gi (gốc 100Gi) — tăng sau được.
- PXC limits 1 CPU / 2Gi (gốc 2 CPU / 4Gi) cho vừa instance t3.xlarge.
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
  `namespaceSelector` (Operator ở namespace khác), và HAProxy thiếu egress
  tới PXC (bị default-deny chặn).
