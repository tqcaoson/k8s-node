// Pool ket noi MySQL (PXC qua HAProxy). Dung chung cho web, migrate va worker.
const mysql = require('mysql2/promise');
const config = require('./config');

let pool = null;

function getPool() {
  if (!pool) {
    pool = mysql.createPool({
      host: config.db.host,
      port: config.db.port,
      database: config.db.database,
      user: config.db.user,
      password: config.db.password,
      waitForConnections: true,
      connectionLimit: 10,
      queueLimit: 0,
      // PXC/HAProxy co the dong ket noi idle; giu timeout vua phai.
      enableKeepAlive: true,
    });
  }
  return pool;
}

// Kiem tra DB con song khong, dung cho /healthz va /readyz.
async function checkDb() {
  const p = getPool();
  await p.query('SELECT 1');
  return true;
}

async function closePool() {
  if (pool) {
    await pool.end();
    pool = null;
  }
}

module.exports = { getPool, checkDb, closePool };
