// UI goi API /api/tasks, khong dung framework.
const $ = (id) => document.getElementById(id);
const STATUS_LABEL = { todo: 'Chưa làm', doing: 'Đang làm', done: 'Đã xong' };

async function api(path, options) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function showError(msg) {
  const el = $('error');
  el.textContent = msg;
  el.hidden = !msg;
}

async function checkHealth() {
  try {
    // /readyz tra 200 chi khi noi duoc MySQL.
    const res = await fetch('/readyz');
    $('health').textContent = res.ok
      ? '● Database: kết nối tốt (MySQL qua HAProxy)'
      : '● Database: chưa kết nối được';
    $('health').className = 'health ' + (res.ok ? 'ok' : 'bad');
  } catch {
    $('health').textContent = '● Không gọi được /readyz';
    $('health').className = 'health bad';
  }
}

async function loadTasks() {
  showError('');
  try {
    const params = new URLSearchParams();
    if ($('filter').value) params.set('status', $('filter').value);
    if ($('search').value.trim()) params.set('q', $('search').value.trim());
    const tasks = await api('/api/tasks?' + params.toString());
    const tbody = $('task-list');
    tbody.innerHTML = '';
    $('empty').hidden = tasks.length > 0;
    for (const t of tasks) {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${t.id}</td>
        <td><strong></strong></td>
        <td></td>
        <td><span class="badge ${t.status}">${STATUS_LABEL[t.status] || t.status}</span></td>
        <td>${new Date(t.updated_at).toLocaleString('vi-VN')}</td>
        <td class="actions"></td>`;
      tr.children[1].querySelector('strong').textContent = t.title;
      tr.children[2].textContent = t.description || '';
      const edit = document.createElement('button');
      edit.textContent = 'Sửa';
      edit.onclick = () => startEdit(t);
      const del = document.createElement('button');
      del.textContent = 'Xóa';
      del.className = 'danger';
      del.onclick = () => deleteTask(t.id, t.title);
      tr.children[5].append(edit, del);
      tbody.appendChild(tr);
    }
  } catch (err) {
    showError('Không tải được danh sách: ' + err.message);
  }
}

function startEdit(t) {
  $('task-id').value = t.id;
  $('title').value = t.title;
  $('description').value = t.description || '';
  $('status').value = t.status;
  $('form-title').textContent = 'Sửa công việc #' + t.id;
  $('submit-btn').textContent = 'Lưu thay đổi';
  $('cancel-btn').hidden = false;
  $('title').focus();
}

function resetForm() {
  $('task-form').reset();
  $('task-id').value = '';
  $('form-title').textContent = 'Thêm công việc';
  $('submit-btn').textContent = 'Thêm';
  $('cancel-btn').hidden = true;
}

async function deleteTask(id, title) {
  if (!confirm(`Xóa công việc "${title}"?`)) return;
  try {
    await api('/api/tasks/' + id, { method: 'DELETE' });
    await loadTasks();
  } catch (err) {
    showError('Xóa thất bại: ' + err.message);
  }
}

$('task-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  showError('');
  const body = {
    title: $('title').value.trim(),
    description: $('description').value.trim() || null,
    status: $('status').value,
  };
  try {
    const id = $('task-id').value;
    if (id) await api('/api/tasks/' + id, { method: 'PUT', body: JSON.stringify(body) });
    else await api('/api/tasks', { method: 'POST', body: JSON.stringify(body) });
    resetForm();
    await loadTasks();
  } catch (err) {
    showError('Lưu thất bại: ' + err.message);
  }
});
$('cancel-btn').addEventListener('click', resetForm);
$('refresh-btn').addEventListener('click', loadTasks);
$('filter').addEventListener('change', loadTasks);
$('search').addEventListener('input', () => {
  clearTimeout(window._t);
  window._t = setTimeout(loadTasks, 300);
});

$('shared-write-btn').addEventListener('click', async () => {
  try {
    const r = await api('/api/shared/write', {
      method: 'POST',
      body: JSON.stringify({ content: $('shared-content').value }),
    });
    $('shared-result').textContent = 'Đã ghi: ' + r.file + '\nNội dung: ' + r.content;
  } catch (err) {
    $('shared-result').textContent = 'Ghi thất bại: ' + err.message;
  }
});
$('shared-read-btn').addEventListener('click', async () => {
  try {
    const r = await api('/api/shared/read');
    $('shared-result').textContent = `Đọc từ Pod ${r.pod}:\n${r.content}`;
  } catch (err) {
    $('shared-result').textContent = 'Đọc thất bại: ' + err.message;
  }
});

checkHealth();
loadTasks();
setInterval(checkHealth, 30000);
