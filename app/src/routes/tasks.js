// CRUD cho bang tasks. Router nhan pool qua tham so de de test.
const express = require('express');

const STATUSES = ['todo', 'doing', 'done'];

function isValidStatus(v) {
  return STATUSES.includes(v);
}

function createTasksRouter(pool) {
  const router = express.Router();

  // GET /api/tasks?status=todo&q=tu-khoa — danh sach, moi nhat truoc.
  router.get('/', async (req, res, next) => {
    try {
      const where = [];
      const params = [];
      if (req.query.status) {
        if (!isValidStatus(req.query.status)) {
          return res.status(400).json({ error: 'status phai la todo, doing hoac done' });
        }
        where.push('status = ?');
        params.push(req.query.status);
      }
      if (req.query.q) {
        where.push('(title LIKE ? OR description LIKE ?)');
        params.push(`%${req.query.q}%`, `%${req.query.q}%`);
      }
      const sql = `SELECT * FROM tasks ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY id DESC`;
      const [rows] = await pool.query(sql, params);
      res.json(rows);
    } catch (err) {
      next(err);
    }
  });

  // GET /api/tasks/:id — chi tiet 1 cong viec.
  router.get('/:id', async (req, res, next) => {
    try {
      const [rows] = await pool.query('SELECT * FROM tasks WHERE id = ?', [req.params.id]);
      if (rows.length === 0) return res.status(404).json({ error: 'Khong tim thay cong viec' });
      res.json(rows[0]);
    } catch (err) {
      next(err);
    }
  });

  // POST /api/tasks — tao moi. Body: { title, description?, status? }
  router.post('/', async (req, res, next) => {
    try {
      const { title, description = null, status = 'todo' } = req.body || {};
      if (!title || typeof title !== 'string' || !title.trim()) {
        return res.status(400).json({ error: 'title la bat buoc' });
      }
      if (title.trim().length > 255) {
        return res.status(400).json({ error: 'title toi da 255 ky tu' });
      }
      if (!isValidStatus(status)) {
        return res.status(400).json({ error: 'status phai la todo, doing hoac done' });
      }
      const [result] = await pool.query(
        'INSERT INTO tasks (title, description, status) VALUES (?, ?, ?)',
        [title.trim(), description, status]
      );
      const [rows] = await pool.query('SELECT * FROM tasks WHERE id = ?', [result.insertId]);
      res.status(201).json(rows[0]);
    } catch (err) {
      next(err);
    }
  });

  // PUT /api/tasks/:id — cap nhat (cho phep cap nhat tung phan).
  router.put('/:id', async (req, res, next) => {
    try {
      const { title, description, status } = req.body || {};
      const fields = [];
      const params = [];
      if (title !== undefined) {
        if (typeof title !== 'string' || !title.trim() || title.trim().length > 255) {
          return res.status(400).json({ error: 'title khong hop le (1-255 ky tu)' });
        }
        fields.push('title = ?');
        params.push(title.trim());
      }
      if (description !== undefined) {
        fields.push('description = ?');
        params.push(description);
      }
      if (status !== undefined) {
        if (!isValidStatus(status)) {
          return res.status(400).json({ error: 'status phai la todo, doing hoac done' });
        }
        fields.push('status = ?');
        params.push(status);
      }
      if (fields.length === 0) {
        return res.status(400).json({ error: 'Khong co truong nao de cap nhat' });
      }
      params.push(req.params.id);
      const [result] = await pool.query(
        `UPDATE tasks SET ${fields.join(', ')} WHERE id = ?`,
        params
      );
      if (result.affectedRows === 0) {
        return res.status(404).json({ error: 'Khong tim thay cong viec' });
      }
      const [rows] = await pool.query('SELECT * FROM tasks WHERE id = ?', [req.params.id]);
      res.json(rows[0]);
    } catch (err) {
      next(err);
    }
  });

  // DELETE /api/tasks/:id — xoa.
  router.delete('/:id', async (req, res, next) => {
    try {
      const [result] = await pool.query('DELETE FROM tasks WHERE id = ?', [req.params.id]);
      if (result.affectedRows === 0) {
        return res.status(404).json({ error: 'Khong tim thay cong viec' });
      }
      res.json({ deleted: true, id: Number(req.params.id) });
    } catch (err) {
      next(err);
    }
  });

  return router;
}

module.exports = { createTasksRouter, STATUSES };
