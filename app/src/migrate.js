// Migrate + seed: tao bang tasks neu chua co, nap 5 dong mau neu chua co.
// Chay bang: npm run migrate (Job migrate-job.yaml chay lenh nay),
// va web cung tu chay luc khoi dong de dam bao bang luon ton tai.
const fs = require('fs');
const path = require('path');
const mysql = require('mysql2/promise');
const config = require('./config');

const MIGRATE_SQL = fs.readFileSync(path.join(__dirname, '..', 'db', 'migrate.sql'), 'utf8');
const SEED_SQL = fs.readFileSync(path.join(__dirname, '..', 'db', 'seed.sql'), 'utf8');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Thu lai nhieu lan vi luc Job chay, PXC co the chua san sang.
async function runMigrate({ retries = 30, delayMs = 5000 } = {}) {
  let lastErr;
  for (let attempt = 1; attempt <= retries; attempt++) {
    let conn;
    try {
      conn = await mysql.createConnection({
        host: config.db.host,
        port: config.db.port,
        database: config.db.database,
        user: config.db.user,
        password: config.db.password,
        multipleStatements: true,
      });
      await conn.query(MIGRATE_SQL);
      await conn.query(SEED_SQL);
      const [rows] = await conn.query('SELECT COUNT(*) AS n FROM tasks');
      console.log(`[migrate] OK: bang tasks san sang, hien co ${rows[0].n} dong.`);
      return true;
    } catch (err) {
      lastErr = err;
      console.log(`[migrate] Lan ${attempt}/${retries} loi: ${err.code || err.message}. Thu lai sau ${delayMs / 1000}s...`);
      await sleep(delayMs);
    } finally {
      if (conn) await conn.end().catch(() => {});
    }
  }
  throw lastErr;
}

// Chay truc tiep: node src/migrate.js
if (require.main === module) {
  runMigrate()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error('[migrate] THAT BAI sau nhieu lan thu:', err.message);
      process.exit(1);
    });
}

module.exports = { runMigrate };
