// Xu ly 1 task. Chay trong Job do dispatcher tao (1 Job = 1 task):
//   node src/process-task.js <task-id>   (hoac env TASK_ID)
// Luong: doc task -> xu ly (hien mo phong bang sleep 3s + ghi ket qua
// ra shared volume) -> danh dau done. Idempotent: task da done hoac da
// bi xoa thi thoat 0, khong loi.
const fs = require('fs').promises;
const path = require('path');
const config = require('./config');
const { getPool, closePool } = require('./db');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const id = Number(process.argv[2] || process.env.TASK_ID);
  if (!id) {
    console.error('[processor] Thieu task id. Cach dung: node src/process-task.js <task-id>');
    process.exit(2);
  }
  const pool = getPool();
  const [rows] = await pool.query('SELECT * FROM tasks WHERE id = ?', [id]);
  if (rows.length === 0) {
    console.log(`[processor] Task ${id} khong ton tai (da bi xoa?), thoat.`);
    await closePool();
    process.exit(0);
  }
  const task = rows[0];
  if (task.status === 'done') {
    console.log(`[processor] Task ${id} da done tu truoc, thoat.`);
    await closePool();
    process.exit(0);
  }
  // Phong truong hop chay tay (khong qua dispatcher): claim neu con todo.
  await pool.query("UPDATE tasks SET status='doing' WHERE id=? AND status='todo'", [id]);

  console.log(`[processor] Dang xu ly task ${id}: "${task.title}"`);
  // --- CHO XU LY THAT: thay khoi sleep nay bang logic nghiep vu
  // (goi API ben ngoai, xu ly file trong /app/shared, ...) ---
  await sleep(3000);

  // Ghi ket qua ra shared volume de web/Pod khac doc duoc.
  const result = {
    taskId: id,
    title: task.title,
    processedAt: new Date().toISOString(),
    pod: process.env.HOSTNAME || 'unknown',
    result: 'ok',
  };
  const dir = path.join(config.sharedDir, 'results');
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, `task-${id}.json`), JSON.stringify(result, null, 2), 'utf8');

  await pool.query("UPDATE tasks SET status='done' WHERE id=?", [id]);
  console.log(`[processor] Xong task ${id}, ket qua da ghi ra ${path.join('results', `task-${id}.json`)}.`);
  await closePool();
  process.exit(0);
}

main().catch(async (err) => {
  console.error('[processor] LOI:', err.message);
  await closePool().catch(() => {});
  process.exit(1);
});
