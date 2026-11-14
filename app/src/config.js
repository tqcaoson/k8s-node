// Cau hinh doc tu bien moi truong.
// Gia tri mac dinh khop voi cac env da fix san trong k8s/app/app-secret.yaml
// va k8s/db/pxc-secrets.yaml, nen chay ngay ca khi khong truyen env.
require('dotenv').config();

module.exports = {
  port: parseInt(process.env.PORT || '3000', 10),
  nodeEnv: process.env.NODE_ENV || 'development',
  // Thu muc dung chung (PVC RWX shared-data) va thu muc tam (emptyDir),
  // duoc mount trong web-deployment.yaml va worker-cronjob.yaml.
  sharedDir: process.env.SHARED_DIR || '/app/shared',
  tmpDir: process.env.TMP_DIR || '/app/tmp',
  db: {
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT || '3306', 10),
    database: process.env.DB_NAME || 'appdb',
    user: process.env.DB_USER || 'app',
    password: process.env.DB_PASSWORD || 'AppPass123!',
  },
  // Chi dung cho Job init-db (tao database + user app bang quyen root).
  dbRoot: {
    host: process.env.DB_HOST || 'localhost',
    port: parseInt(process.env.DB_PORT || '3306', 10),
    user: process.env.DB_ROOT_USER || 'root',
    password: process.env.DB_ROOT_PASSWORD || 'PxcRoot123!',
  },
};
