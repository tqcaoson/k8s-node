// Web server: phuc vu UI + API CRUD tasks.
// Endpoint /healthz dung cho readinessProbe/livenessProbe trong K8s.
const express = require('express');
const fs = require('fs').promises;
const path = require('path');
const config = require('./config');
const { getPool, checkDb } = require('./db');
const { createTasksRouter } = require('./routes/tasks');
const { runMigrate } = require('./migrate');

const app = express();
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(__dirname, '..', 'public')));

// /healthz: liveness probe — chi can process con song la 200, KHONG phu
// thuoc MySQL (neu khong, mat DB se lam K8s restart Pod lien tuc).
// Truong db chi de tham khao trang thai ket noi.
// /readyz: readiness probe — 200 chi khi noi duoc MySQL, de K8s chi dua
// traffic vao Pod khi Pod that su phuc vu duoc.
app.get('/healthz', async (req, res) => {
  let db = 'up';
  try {
    await checkDb();
  } catch (err) {
    db = 'down';
  }
  res.json({ status: 'ok', db });
});
app.get('/readyz', async (req, res) => {
  try {
    await checkDb();
    res.json({ status: 'ready', db: 'up' });
  } catch (err) {
    res.status(503).json({ status: 'not-ready', db: 'down' });
  }
});

app.use('/api/tasks', createTasksRouter(getPool()));

// Demo volume dung chung (PVC RWX): ghi doc file tren /app/shared.
// Dung de kiem tra Pod nay ghi, Pod khac doc duoc (muc 12.2 cua guide).
app.post('/api/shared/write', async (req, res, next) => {
  try {
    const content = (req.body && req.body.content) || `hello tu Pod ${process.env.HOSTNAME || 'unknown'}`;
    const file = path.join(config.sharedDir, 'demo.txt');
    await fs.mkdir(config.sharedDir, { recursive: true });
    await fs.writeFile(file, `${content}\n`, 'utf8');
    res.json({ ok: true, file, content });
  } catch (err) {
    next(err);
  }
});
app.get('/api/shared/read', async (req, res, next) => {
  try {
    const file = path.join(config.sharedDir, 'demo.txt');
    const content = await fs.readFile(file, 'utf8');
    res.json({ ok: true, file, content, pod: process.env.HOSTNAME || 'unknown' });
  } catch (err) {
    if (err.code === 'ENOENT') return res.status(404).json({ error: 'Chua co file demo.txt, hay ghi truoc' });
    next(err);
  }
});

// 404 cho API khong ton tai.
app.use('/api', (req, res) => res.status(404).json({ error: 'API khong ton tai' }));

// Error handler tap trung.
app.use((err, req, res, next) => {
  const detail = err.message || err.code || 'Unknown error';
  console.error('[server] Loi:', detail);
  res.status(500).json({ error: 'Loi server', detail });
});

async function start() {
  app.listen(config.port, '0.0.0.0', () => {
    console.log(`[server] Web chay tren cong ${config.port} (NODE_ENV=${config.nodeEnv})`);
  });
  // Tu migrate NEN (khong chan listen): dam bao bang tasks ton tai ngay ca
  // khi Job migrate chua chay hoac bi bo qua. An toan khi nhieu Pod cung chay.
  // Trong luc DB chua san sang, /readyz tra 503 nen Pod chua nhan traffic.
  runMigrate({ retries: 12, delayMs: 5000 }).catch((err) => {
    console.error('[server] Migrate chua xong sau nhieu lan thu:', err.message);
    console.error('[server] Web van chay, /readyz se bao 503 den khi DB san sang.');
  });
}

if (require.main === module) start();

module.exports = app;
