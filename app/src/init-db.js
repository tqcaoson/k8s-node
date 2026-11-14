// Tao database + user cho ung dung bang quyen root.
// Thay cho lenh mysql chay tay trong muc 6.5 cua guide goc.
// Chay bang: npm run init-db (Job db-init-job.yaml chay lenh nay sau khi PXC Ready).
// Idempotent: chay lai nhieu lan van an toan.
const mysql = require('mysql2/promise');
const config = require('./config');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runInitDb({ retries = 30, delayMs = 5000 } = {}) {
  const { database, user, password } = config.db;
  let lastErr;
  for (let attempt = 1; attempt <= retries; attempt++) {
    let conn;
    try {
      conn = await mysql.createConnection({
        host: config.dbRoot.host,
        port: config.dbRoot.port,
        user: config.dbRoot.user,
        password: config.dbRoot.password,
        multipleStatements: true,
      });
      await conn.query(
        `CREATE DATABASE IF NOT EXISTS \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`
      );
      await conn.query(
        `CREATE USER IF NOT EXISTS ?@'%' IDENTIFIED BY ?`,
        [user, password]
      );
      // Cap nhat mat khau phong truong hop user da ton tai voi mat khau khac.
      await conn.query(`ALTER USER ?@'%' IDENTIFIED BY ?`, [user, password]);
      await conn.query(`GRANT ALL PRIVILEGES ON \`${database}\`.* TO ?@'%'`, [user]);
      await conn.query('FLUSH PRIVILEGES');
      console.log(`[init-db] OK: database '${database}' va user '${user}' san sang.`);
      return true;
    } catch (err) {
      lastErr = err;
      console.log(`[init-db] Lan ${attempt}/${retries} loi: ${err.code || err.message}. Thu lai sau ${delayMs / 1000}s...`);
      await sleep(delayMs);
    } finally {
      if (conn) await conn.end().catch(() => {});
    }
  }
  throw lastErr;
}

if (require.main === module) {
  runInitDb()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error('[init-db] THAT BAI sau nhieu lan thu:', err.message);
      process.exit(1);
    });
}

module.exports = { runInitDb };
