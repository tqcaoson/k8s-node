# Hướng dẫn chạy trên laptop Windows 11 + minikube (Dell Latitude 3320, 8GB RAM)

Bản chạy **local** cho laptop Dell Latitude 3320 (Windows 11, 8GB RAM,
Docker Desktop + minikube đã cài, còn trống 100GB disk). Toàn bộ stack
chạy trong minikube trên Docker Desktop (WSL2) — không cần EC2, không
cần DockerHub, không cần IP public.

Mọi lệnh trong guide chạy trong **PowerShell** trên Windows, từ thư mục
project. Nếu bạn đã quen với guide EC2 thì phần deploy (mục 5) gần như
giống hệt — khác biệt chủ yếu ở chỗ tạo cluster, storage và cách mở web.

## 0. Khác biệt so với EC2

| Hạng mục | EC2 (t3.large) | Local (Dell 3320) |
| --- | --- | --- |
| Cluster | kubeadm 1.31 trên AL2023 | minikube 1.31 (Docker driver) trong WSL2 |
| CNI | Calico (hỗ trợ NetworkPolicy) | Mặc định của minikube (không enforce NetworkPolicy — mục 8 của guide EC2 không áp dụng) |
| Storage | Longhorn (RWO + RWX) | minikube-hostpath (chỉ RWO; PVC shared-data đổi sang RWO) |
| Ingress | NodePort 30080 qua IP public + nip.io | port-forward 8080 + `k8s.local` trong hosts file |
| Image | Build trên EC2, push DockerHub, K8s pull về | Build thẳng vào minikube (`minikube image build`), không cần DockerHub |
| Fluent Bit | Có (DaemonSet thu log) | Bỏ — dùng `kubectl logs` |
| RAM | 8GB riêng cho EC2 | 8GB chia với Windows — WSL2 6GB, minikube 5GB |
| PXC / ProxySQL / web / CronJob | — | Giữ nguyên, dùng đúng file EC2 |

**File dùng lại nguyên vẹn (không sửa):** `k8s/00-namespace.yaml`,
`k8s/db/pxc-secrets.yaml`, `k8s/db/pxc-values.yaml`,
`k8s/app/app-secret.yaml`, `k8s/db/db-init-job.yaml`,
`k8s/db/migrate-job.yaml`, `k8s/app/web-deployment.yaml`,
`k8s/app/web-service.yaml`, `k8s/app/web-hpa.yaml`,
`k8s/worker/*`, `k8s/app/web-ingress.yaml` (chỉ thay host bằng lệnh
PowerShell, không sửa file).

**File riêng cho local:** `k8s/storage-local/` (3 file — 2 StorageClass
cùng tên `longhorn-db` / `longhorn-shared` nhưng dùng provisioner
`k8s.io/minikube-hostpath`, và PVC shared-data bản RWO).

**Không dùng ở local:** `k8s/storage/*` (StorageClass Longhorn + PVC
RWX), `k8s/logging/*` (Fluent Bit), `k8s/networkpolicy/*` (CNI mặc định
của minikube không enforce NetworkPolicy), `k8s/backup/*` (như EC2 —
chưa có S3).

## 1. Chuẩn bị

### 1.1. Copy project về máy

Copy thư mục `k8s-native-web-platform` vào máy, ví dụ
`C:\Users\<user>\k8s-native-web-platform`. Từ đây trở đi, mọi lệnh chạy
trong PowerShell tại thư mục này:

```powershell
cd C:\Users\<user>\k8s-native-web-platform
```

### 1.2. Cấp RAM cho WSL2 (bắt buộc — mặc định WSL2 chỉ dùng 50% RAM máy)

WSL2 mặc định chỉ được dùng 50% RAM máy (8GB → 4GB), không đủ cho
minikube 5GB. Tạo file `C:\Users\<user>\.wslconfig` với nội dung:

```ini
[wsl2]
memory=6GB
processors=4
```

Rồi áp dụng (tắt hẳn WSL2 và khởi động lại Docker Desktop):

```powershell
wsl --shutdown
# Mo lai Docker Desktop, doi icon Docker chuyen sang mau xanh (da chay).
docker info
# Ky vong: khong bao loi — Docker daemon da chay.
```

Lưu ý: WSL2 lấy 6GB thì Windows chỉ còn ~2GB — khi chạy cluster thì
đóng bớt ứng dụng nặng (Chrome nhiều tab, Teams...) để máy không giật.

### 1.3. Cài kubectl + Helm (minikube đã có sẵn)

```powershell
winget install Kubernetes.kubectl
winget install Helm.Helm
# Dong PowerShell roi mo lai, kiem tra:
kubectl version --client
helm version
minikube version
```

### 1.4. Thêm `k8s.local` vào hosts file (để mở web bằng tên miền)

Ingress định tuyến theo Host header (`k8s.local`). Thêm dòng sau vào
`C:\Windows\System32\drivers\etc\hosts` (mở Notepad **bằng quyền Admin**
rồi mở file đó):

```text
127.0.0.1 k8s.local
```

Kiểm tra: `ping k8s.local` phải trả về `127.0.0.1`.

---

## 2. Khởi động minikube

```powershell
minikube start --driver=docker --memory=5120 --cpus=4 --disk-size=40g --kubernetes-version=v1.31.0
```

Giải thích từng flag:

- `--driver=docker` — chạy node K8s như 1 container trong Docker Desktop.
- `--memory=5120` — cấp 5GB RAM cho node (stack cần ~3GB requests;
  5GB đủ chỗ thở; muốn cấp hơn thì sửa `.wslconfig` ở mục 1.2 trước).
- `--cpus=4` — Latitude 3320 có 4 nhân (8 luồng); cấp 4 cho minikube,
  còn lại cho Windows.
- `--disk-size=40g` — ổ của node (image PXC ~1GB + 16Gi volume +
  image app; disk máy còn 100GB nên thoải mái).
- `--kubernetes-version=v1.31.0` — giữ đúng version đã chạy ổn định
  trên EC2. Nếu minikube báo không tải được version này thì bỏ flag
  này (dùng version mặc định — manifest vẫn chạy được).

Bật metrics-server (HPA cần để đo CPU) rồi kiểm tra:

```powershell
minikube addons enable metrics-server
kubectl get nodes
# Ky vong: minikube Ready, ROLE control-plane.
kubectl get pods -A
# Ky vong: cac Pod kube-system Running (CoreDNS, kube-proxy...).
kubectl top nodes
# Ky vong: hien CPU/RAM — metrics-server da chay (neu bao loi thi doi 1 phut roi thu lai).
```

---

## 3. Cài nền tảng bằng Helm (Ingress + PXC Operator)

```powershell
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update

# NGINX Ingress Controller (1 replica — cau hinh nho). Khong can co dinh
# NodePort nhu EC2 vi o local mo web bang port-forward (muc 6).
helm install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx --create-namespace `
  --version 4.12.1 `
  --set controller.replicaCount=1 `
  --set controller.service.type=NodePort

# PXC Operator — watchAllNamespaces=true la BAT BUOC (ly do nhu EC2:
# mac dinh Operator chi theo doi namespace cua chinh no, CR cluster1
# o namespace production se bi bo qua hoan toan).
helm install pxc-operator percona/pxc-operator `
  --namespace pxc-operator --create-namespace `
  --version 1.17.0 `
  --set watchAllNamespaces=true
```

**Kiểm tra:**

```powershell
helm list -A
# Ky vong: 2 release — ingress-nginx, pxc-operator.
kubectl get pods -n ingress-nginx
kubectl get pods -n pxc-operator
# Ky vong: moi Pod 1/1 Running.
kubectl get crd | findstr pxc
# Ky vong: thay perconaxtradbclusters.pxc.percona.com (CRD da dang ky).
```

**Không cài ở local (đã nói ở mục 0):** Longhorn (thay bằng
minikube-hostpath, mục 5.1), Fluent Bit (dùng `kubectl logs`), Calico
(minikube dùng CNI mặc định của nó; NetworkPolicy không được enforce
nên mục 8 của guide EC2 không áp dụng ở local).

---

## 4. Build image app vào trong minikube

```powershell
minikube image build -t my-nodejs-app:v1 ./app
minikube image ls | findstr my-nodejs-app
# Ky vong: thay my-nodejs-app:v1 trong danh sach.
```

Lưu ý:

- Tag **phải đúng** `my-nodejs-app:v1` — đây là tên image trong 4
  manifest (web, db-init, migrate, CronJob) và trong biến `APP_IMAGE`
  của dispatcher. Build đúng tag này thì deploy không cần sửa/sed gì.
- `imagePullPolicy` là `IfNotPresent` (đã ghi sẵn trong manifest web
  và CronJob; 2 Job dùng mặc định `IfNotPresent` vì tag không phải
  `:latest`) nên K8s dùng image local, không pull từ DockerHub.
- Đừng dùng `docker build` trên Windows — image đó nằm ở Docker
  Desktop, minikube không thấy. Phải dùng `minikube image build`
  (hoặc build rồi `minikube image load`).
- Lần đầu build mất vài phút (`npm ci`). Sửa code sau này thì build
  lại lệnh trên rồi `kubectl -n production rollout restart
  deployment/nodejs-web` để Pod nhận image mới.


---

## 5. Deploy database + ứng dụng

### 5.1. Namespace + StorageClass local + PVC shared local

```powershell
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/storage-local/storageclass-db-local.yaml
kubectl apply -f k8s/storage-local/storageclass-shared-local.yaml
kubectl apply -f k8s/storage-local/pvc-shared-local.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/shared-data -n production --timeout=300s
```

**Kiểm tra:** `kubectl -n production get pvc` — `shared-data` phải là
`Bound`. `kubectl get storageclass` phải thấy `longhorn-db`,
`longhorn-shared` (provisioner `k8s.io/minikube-hostpath`) và `standard`
(mặc định của minikube — ProxySQL sẽ dùng class này vì values không ghi
storageClass cho nó).

### 5.2. Cài cluster PXC (MySQL + ProxySQL) — dùng nguyên file EC2

```powershell
kubectl apply -f k8s/db/pxc-secrets.yaml
helm install cluster1 percona/pxc-db --namespace production --version 1.17.0 -f k8s/db/pxc-values.yaml

# Doi cluster Ready (lan dau 5-15 phut: PXC pull image ~1GB + khoi tao Galera):
kubectl -n production get pxc cluster1 -w
# Ky vong: STATUS chuyen initializing -> Ready, PXC 1, PROXYSQL 1.
# Bam Ctrl+C de thoat watch khi thay Ready.
```

File `pxc-values.yaml` dùng nguyên như EC2 (PXC 1 Pod, ProxySQL 1 Pod,
`fullnameOverride: cluster1`, `unsafeFlags`, proxydata 1Gi) — không cần
sửa vì StorageClass `longhorn-db` đã tồn tại ở local (mục 5.1).

**Kiểm tra:**

```powershell
kubectl -n production get pods
# Ky vong: cluster1-pxc-0 1/1 Running, cluster1-proxysql-0 Ready.
kubectl -n production get endpoints cluster1-proxysql
# Ky vong: co ENDPOINTS (IP cua Pod ProxySQL).
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -h cluster1-proxysql -uroot -p'PxcRoot123!' -e "SELECT 1;"
# Ky vong: tra ve 1 — noi duoc MySQL qua ProxySQL.
```

### 5.3. Tạo database + user app (Job db-init) và migrate + seed (Job db-migrate)

Không cần `sed` thay image như EC2 — image `my-nodejs-app:v1` đã có
sẵn trong minikube (mục 4), manifest dùng đúng tag này:

```powershell
kubectl apply -f k8s/app/app-secret.yaml
kubectl apply -f k8s/db/db-init-job.yaml
kubectl wait --for=condition=complete job/db-init -n production --timeout=600s
kubectl -n production logs job/db-init
# Ky vong: "[init-db] OK: database 'appdb' va user 'app' san sang."

kubectl apply -f k8s/db/migrate-job.yaml
kubectl wait --for=condition=complete job/db-migrate -n production --timeout=600s
kubectl -n production logs job/db-migrate
# Ky vong: "[migrate] OK: bang tasks san sang, hien co 5 dong."
```

### 5.4. Deploy web (Deployment + Service + Ingress + HPA)

```powershell
kubectl apply -f k8s/app/web-deployment.yaml
kubectl apply -f k8s/app/web-service.yaml
# Ingress: thay host app.example.com -> k8s.local (khong sua file goc):
(Get-Content k8s/app/web-ingress.yaml) -replace 'app.example.com','k8s.local' | kubectl apply -f -
kubectl apply -f k8s/app/web-hpa.yaml
kubectl wait --for=condition=Available deployment/nodejs-web -n production --timeout=300s
```

### 5.5. CronJob dispatcher + RBAC

```powershell
kubectl apply -f k8s/worker/dispatcher-rbac.yaml
kubectl apply -f k8s/worker/worker-cronjob.yaml
kubectl -n production get cronjob task-worker
# Ky vong: task-worker, SCHEDULE moi 5 phut.
```

Dispatcher tạo Job bằng image `my-nodejs-app:v1` (biến `APP_IMAGE`
trong CronJob đã ghi đúng tag này) — không cần sửa gì.

---

## 6. Mở web

`minikube ip` không truy cập được từ Windows (mạng của container nằm
trong máy ảo WSL2 của Docker Desktop), nên mở web bằng port-forward
tới Ingress Controller. **Giữ nguyên cửa sổ PowerShell này** trong lúc
dùng web:

```powershell
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
```

Mở trình duyệt: **http://k8s.local:8080** — phải thấy trang Tasks với
5 dòng seed, thêm/sửa/xóa được task.

Giải thích: `k8s.local` phân giải về `127.0.0.1` (hosts file, mục 1.4)
→ port-forward chuyển traffic tới Ingress Controller → Ingress định
tuyến theo Host `k8s.local` tới web. Tắt cửa sổ port-forward là web
không mở được nữa (mở lại bằng lệnh trên).

---

## 7. Kiểm tra toàn bộ

Lưu ý: trong PowerShell, `curl` là alias của `Invoke-WebRequest` (cú
pháp khác curl thật). Guide này dùng **`curl.exe`** (curl thật, có sẵn
trên Windows 10/11) cho mọi lệnh curl.

### 7.1. Trạng thái chung + PXC + ProxySQL

```powershell
kubectl -n production get pxc,pods,pvc,svc,ingress,hpa,cronjob
# Ky vong: PXC Ready; PXC 1/1, ProxySQL Ready, web 2/2 Running;
# PVC datadir + proxydata + shared-data deu Bound.
kubectl -n production get endpoints cluster1-proxysql
# Ky vong: co ENDPOINTS (khong rong).
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -h cluster1-proxysql -uroot -p'PxcRoot123!' -e "SELECT 1;"
# Ky vong: tra ve 1.
```

### 7.2. Web + CRUD (mở 1 cửa sổ PowerShell khác cho port-forward)

```powershell
# Cua so PowerShell thu 2 (giu nguyen trong luc test):
kubectl -n production port-forward svc/nodejs-service 3000:80
```

```powershell
# Cua so PowerShell thu 3 — test API:
curl.exe http://localhost:3000/healthz
# {"status":"ok",...}
curl.exe http://localhost:3000/readyz
# {"status":"ok","db":"up",...}
curl.exe http://localhost:3000/api/tasks
# 5 dong seed
curl.exe -X POST http://localhost:3000/api/tasks -H "Content-Type: application/json" -d '{"title":"Task test","status":"todo"}'
# Tra ve task moi co id — ghi nho id nay cho 2 lenh sau:
curl.exe -X PUT http://localhost:3000/api/tasks/<id> -H "Content-Type: application/json" -d '{"status":"done"}'
curl.exe -X DELETE http://localhost:3000/api/tasks/<id>
```

### 7.3. Dispatcher: task todo → Job → done

```powershell
# Tao 1 task todo (lay id tu response):
curl.exe -X POST http://localhost:3000/api/tasks -H "Content-Type: application/json" -d '{"title":"Task test dispatcher","status":"todo"}'
# Kich hoat dispatcher ngay (khong doi lich 5 phut):
kubectl create job dispatch-test --from=cronjob/task-worker -n production
kubectl wait --for=condition=complete job/dispatch-test -n production --timeout=300s
# Doi Job xu ly task xong:
kubectl wait --for=condition=complete job -l task-id=<id> -n production --timeout=300s
curl.exe http://localhost:3000/api/tasks/<id>
# Ky vong: "status":"done"
# Ket qua xu ly co trong shared volume:
kubectl -n production exec deploy/nodejs-web -- cat /app/shared/results/task-<id>.json
# Ky vong: {"result": "ok", ...}
kubectl delete job dispatch-test -n production
```

### 7.4. Shared PVC: Pod 1 ghi, Pod 2 đọc (bản local dùng RWO)

```powershell
$POD1 = kubectl -n production get pods -l app=nodejs-web -o jsonpath='{.items[0].metadata.name}'
$POD2 = kubectl -n production get pods -l app=nodejs-web -o jsonpath='{.items[1].metadata.name}'
kubectl -n production exec $POD1 -- sh -c 'echo hello-rwx > /app/shared/verify.txt'
kubectl -n production exec $POD2 -- cat /app/shared/verify.txt
# Ky vong: hello-rwx — chung minh 2 Pod cung mount duoc PVC RWO tren 1 node.
```

### 7.5. Galera + Ingress + HPA

```powershell
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' -N -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Ky vong: 1 (cau hinh nho).
# Test khoi dong lai (thay cho test failover 3-node): xoa Pod PXC,
# StatefulSet tao lai Pod moi, du lieu van con tren PVC:
kubectl -n production delete pod cluster1-pxc-0
kubectl -n production get pods -w   # doi Pod moi 1/1 Running
kubectl -n production exec cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' appdb -N -e "SELECT COUNT(*) FROM tasks;"
# Ky vong: 5 (+ task da tao).

# Ingress qua port-forward muc 6 (cua so port-forward phai dang chay):
curl.exe http://k8s.local:8080/readyz
# Ky vong: {"status":"ok","db":"up",...}

kubectl -n production get hpa nodejs-hpa
# Ky vong: TARGETS hien CPU% (metrics-server da chay).
```

---

## 8. Lệnh dùng hằng ngày

```powershell
minikube stop              # tam dung cluster (du lieu PVC van giu nguyen)
minikube start             # khoi dong lai cluster cu (khong can truyen lai flag)
minikube status            # trang thai cluster
minikube dashboard         # mo Kubernetes dashboard tren trinh duyet
minikube ssh               # shell vao trong node (VD: df -h xem disk)
kubectl -n production logs deploy/nodejs-web --tail=50
kubectl -n production get jobs
kubectl -n production exec -it cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' appdb
# Shell MySQL (trong shell: SHOW TABLES; SELECT * FROM tasks;)
```

**Sửa code app rồi deploy lại:**

```powershell
minikube image build -t my-nodejs-app:v1 ./app
kubectl -n production rollout restart deployment/nodejs-web
# Job/CronJob: Job la immutable — xoa Job cu roi apply lai neu can chay ban moi ngay:
kubectl -n production delete job db-init db-migrate --ignore-not-found
```

---

## 9. Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| `minikube start` lỗi, hoặc Pod bị OOMKilled | WSL2 chỉ có 4GB (mặc định 50% RAM) | Kiểm tra `.wslconfig` có `memory=6GB` chưa (mục 1.2), chạy `wsl --shutdown`, khởi động lại Docker Desktop rồi `minikube start` lại |
| `docker: command not found` / Docker daemon không chạy | Docker Desktop chưa mở | Mở Docker Desktop, đợi icon xanh rồi thử lại |
| Pod PXC `Pending` vì `Insufficient cpu` / `Insufficient memory` | Node hết tài nguyên (máy đang chạy nhiều app) | Đóng bớt ứng dụng nặng; kiểm tra `kubectl describe node minikube` xem requests còn trống bao nhiêu. Cấu hình nhỏ đã là tối thiểu — đừng tăng size/resource |
| PVC `Pending` mãi | StorageClass local chưa apply, hoặc storage-provisioner tắt | `kubectl get storageclass` phải thấy `longhorn-db`, `longhorn-shared`; `minikube addons list \| findstr storage-provisioner` phải là enabled (mặc định đã bật) |
| Pod web `ImagePullBackOff` / `ErrImagePull` | Image chưa build vào minikube (build bằng `docker build` trên Windows thì minikube không thấy) | `minikube image build -t my-nodejs-app:v1 ./app`, kiểm tra `minikube image ls \| findstr my-nodejs-app`, rồi `kubectl -n production rollout restart deployment/nodejs-web` |
| Mở `http://k8s.local:8080` báo không tới được | Port-forward đã tắt, hoặc thiếu hosts entry | Kiểm tra cửa sổ port-forward (mục 6) còn chạy không; `ping k8s.local` phải ra `127.0.0.1`, nếu không thì thêm lại dòng vào hosts file (mục 1.4, cần Notepad Admin) |
| `curl` trong PowerShell báo lỗi cú pháp / kết quả lạ | `curl` là alias của `Invoke-WebRequest` | Dùng `curl.exe` thay cho `curl` (mọi lệnh curl trong guide đều viết `curl.exe`) |
| PXC `initializing` rất lâu lần đầu | Image PXC ~1GB đang pull + Galera khởi tạo 5–15 phút | Theo dõi `kubectl -n production get pods -w`; xem log `kubectl -n production logs cluster1-pxc-0 -c pxc --tail=20`. Chỉ lo khi quá 20 phút |
| `minikube ip` không mở được từ Windows | Bình thường với Docker driver — IP của container nằm trong mạng WSL2, Windows không tới được trực tiếp | Dùng port-forward như mục 6, không dùng `minikube ip` |
| Sau khi laptop sleep/hibernate, cluster không phản hồi | WSL2/Docker bị gián đoạn khi máy ngủ | `minikube stop` rồi `minikube start` lại. Nên `minikube stop` trước khi gập máy |
| `kubectl` báo `command not found` sau khi cài | Chưa mở lại PowerShell sau khi winget cài xong | Đóng PowerShell rồi mở lại; kiểm tra `kubectl version --client` |

---

## 10. Dọn dẹp

```powershell
# Don sach ung dung + PXC + platform (giu lai cluster minikube):
kubectl delete namespace production
helm uninstall cluster1 -n production
helm uninstall pxc-operator -n pxc-operator
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete storageclass longhorn-db longhorn-shared

# Xoa toan bo cluster (ca du lieu PVC):
minikube delete
# Sau do chay lai tu muc 2 neu muon dung lai.
```

**Lưu ý về dữ liệu:** `minikube stop`/`start` giữ nguyên dữ liệu PVC
(volume nằm trong container minikube). Chỉ `minikube delete` mới xóa
hết. Backup dữ liệu trước khi delete: `kubectl -n production exec
cluster1-pxc-0 -c pxc -- mysqldump -uroot -p'PxcRoot123!' appdb >
backup-appdb.sql` (chạy trong PowerShell tại thư mục project).
