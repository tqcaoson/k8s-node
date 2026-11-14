// Dispatcher: chay theo CronJob moi 5 phut (worker-cronjob.yaml).
// Luong xu ly task:
//   1. Reset cac task ket o 'doing' qua STALE_MINUTES phut ve 'todo'
//      (Job xu ly truoc do chet giua chung).
//   2. Lay toi da BATCH_SIZE task 'todo' cu nhat.
//   3. Voi moi task: claim nguyen tu (todo -> doing, chi claim duoc neu
//      task van todo — tranh 2 dispatcher cung xu ly 1 task), roi tao
//      1 K8s Job chay src/process-task.js de xu ly task do.
//      Neu tao Job loi, tra task ve 'todo' de lan sau thu lai.
//   4. Ghi heartbeat ra shared + tmp.
// Dispatcher can quyen tao Job (xem k8s/worker/dispatcher-rbac.yaml).
const fs = require('fs').promises;
const path = require('path');
const config = require('./config');
const { getPool, closePool } = require('./db');
const { createJob, secretExists } = require('./k8s-client');

const BATCH_SIZE = parseInt(process.env.DISPATCH_BATCH_SIZE || '10', 10);
const STALE_MINUTES = parseInt(process.env.DISPATCH_STALE_MINUTES || '10', 10);

// Manifest cua Job xu ly 1 task. Dung cung image voi dispatcher
// (APP_IMAGE duoc set trong CronJob, script 05 thay bang $IMAGE).
function buildProcessorJob(task, usePullSecret) {
  const suffix = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  const podSpec = {
    restartPolicy: 'Never',
    containers: [
      {
        name: 'processor',
        image: process.env.APP_IMAGE || 'my-nodejs-app:v1',
        imagePullPolicy: 'IfNotPresent',
        command: ['node', 'src/process-task.js'],
        args: [String(task.id)],
        envFrom: [{ secretRef: { name: 'app-secret' } }],
        env: [{ name: 'TASK_ID', value: String(task.id) }],
        resources: {
          requests: { cpu: '100m', memory: '128Mi' },
          limits: { cpu: '500m', memory: '256Mi' },
        },
        volumeMounts: [
          { name: 'temp', mountPath: '/app/tmp' },
          { name: 'shared', mountPath: '/app/shared' },
        ],
      },
    ],
    volumes: [
      { name: 'temp', emptyDir: { sizeLimit: '512Mi' } },
      { name: 'shared', persistentVolumeClaim: { claimName: 'shared-data' } },
    ],
  };
  // Repo DockerHub private: gan secret de Job pull duoc image.
  if (usePullSecret) podSpec.imagePullSecrets = [{ name: 'dockerhub-pull' }];
  return {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: {
      name: `task-${task.id}-${suffix}`,
      labels: { app: 'task-processor', 'task-id': String(task.id) },
    },
    spec: {
      backoffLimit: 1,
      ttlSecondsAfterFinished: 600,
      activeDeadlineSeconds: 300,
      template: {
        metadata: { labels: { app: 'task-processor', 'task-id': String(task.id) } },
        spec: podSpec,
      },
    },
  };
}

async function main() {
  const pool = getPool();

  // 1. Reset task ket 'doing' qua lau.
  const [stale] = await pool.query(
    "UPDATE tasks SET status='todo' WHERE status='doing' AND updated_at < (NOW() - INTERVAL ? MINUTE)",
    [STALE_MINUTES]
  );
  const staleCount = stale.affectedRows || 0;

  // 2. Lay task todo cu nhat.
  const [todos] = await pool.query(
    'SELECT * FROM tasks WHERE status=? ORDER BY id ASC LIMIT ?',
    ['todo', BATCH_SIZE]
  );

  // 3. Claim + tao Job cho tung task.
  let usePullSecret = false;
  if (todos.length > 0) {
    try {
      usePullSecret = await secretExists('dockerhub-pull');
    } catch (err) {
      console.error(`[dispatcher] Khong kiem tra duoc Secret dockerhub-pull: ${err.message}. Tiep tuc khong co pull secret.`);
    }
  }
  const dispatched = [];
  const failed = [];
  for (const task of todos) {
    const [claimed] = await pool.query(
      "UPDATE tasks SET status='doing' WHERE id=? AND status='todo'",
      [task.id]
    );
    if (claimed.affectedRows === 0) continue; // task da duoc claim/xu ly boi noi khac
    try {
      const job = await createJob(buildProcessorJob(task, usePullSecret));
      dispatched.push({ id: task.id, job: job.metadata.name });
      console.log(`[dispatcher] Task ${task.id} -> Job ${job.metadata.name}`);
    } catch (err) {
      await pool.query("UPDATE tasks SET status='todo' WHERE id=?", [task.id]);
      failed.push({ id: task.id, error: err.message });
      console.error(`[dispatcher] Tao Job cho task ${task.id} loi: ${err.message} (da tra task ve todo)`);
    }
  }

  // 4. Heartbeat + thong ke.
  const [rows] = await pool.query('SELECT status, COUNT(*) AS n FROM tasks GROUP BY status');
  const counts = { todo: 0, doing: 0, done: 0 };
  for (const r of rows) counts[r.status] = Number(r.n);
  const heartbeat = {
    pod: process.env.HOSTNAME || 'unknown',
    at: new Date().toISOString(),
    staleReset: staleCount,
    dispatched,
    failed,
    total: counts.todo + counts.doing + counts.done,
    counts,
  };
  await fs.mkdir(config.sharedDir, { recursive: true });
  await fs.mkdir(config.tmpDir, { recursive: true });
  await fs.writeFile(
    path.join(config.sharedDir, 'worker-heartbeat.json'),
    JSON.stringify(heartbeat, null, 2),
    'utf8'
  );
  await fs.writeFile(
    path.join(config.tmpDir, 'worker-last-run.json'),
    JSON.stringify(heartbeat, null, 2),
    'utf8'
  );

  console.log(
    `[dispatcher] Xong: reset ket ${staleCount}, dispatch ${dispatched.length}/${todos.length} task` +
    ` (todo=${counts.todo}, doing=${counts.doing}, done=${counts.done}).`
  );
  await closePool();
  process.exit(failed.length > 0 && dispatched.length === 0 ? 1 : 0);
}

main().catch(async (err) => {
  console.error('[dispatcher] LOI:', err.message);
  await closePool().catch(() => {});
  process.exit(1);
});
