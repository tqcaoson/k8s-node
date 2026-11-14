-- Seed: 5 cong viec mau, id co dinh 1-5.
-- ON DUPLICATE KEY UPDATE giup chay lai nhieu lan khong tao dong trung
-- (an toan khi ca migrate Job va web cung chay migrate luc khoi dong).
INSERT INTO tasks (id, title, description, status) VALUES
  (1, 'Cai Kubernetes tren EC2', 'kubeadm init control-plane, join 3 worker, cai Calico', 'done'),
  (2, 'Cai Longhorn va PXC', 'Helm install longhorn, pxc-operator, cluster 3 node Galera', 'done'),
  (3, 'Deploy web len K8s', 'Build image, apply Deployment/Service/Ingress/HPA', 'doing'),
  (4, 'Test CRUD qua giao dien web', 'Them/sua/xoa cong viec tren UI, kiem tra du lieu vao MySQL', 'todo'),
  (5, 'Test failover MySQL', 'Xoa 1 Pod PXC, kiem tra web van doc ghi duoc qua HAProxy', 'todo')
ON DUPLICATE KEY UPDATE
  title = VALUES(title),
  description = VALUES(description),
  status = VALUES(status);
