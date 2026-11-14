// Client toi thieu goi Kubernetes API tu trong Pod, khong dung thu vien ngoai.
// Doc token + CA tu ServiceAccount duoc mount san trong Pod
// (/var/run/secrets/kubernetes.io/serviceaccount/).
// De test local: dat K8S_API_URL + K8S_API_TOKEN (vd API gia chay tren localhost).
const fs = require('fs');
const http = require('http');
const https = require('https');

const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';

function getApiConfig() {
  if (process.env.K8S_API_URL && process.env.K8S_API_TOKEN) {
    return { baseUrl: process.env.K8S_API_URL, token: process.env.K8S_API_TOKEN, ca: undefined };
  }
  const host = process.env.KUBERNETES_SERVICE_HOST;
  const port = process.env.KUBERNETES_SERVICE_PORT || '443';
  if (!host) throw new Error('Khong chay trong K8s (thieu KUBERNETES_SERVICE_HOST)');
  const token = fs.readFileSync(`${SA_DIR}/token`, 'utf8').trim();
  const ca = fs.readFileSync(`${SA_DIR}/ca.crt`);
  return { baseUrl: `https://${host}:${port}`, token, ca };
}

function getNamespace() {
  if (process.env.POD_NAMESPACE) return process.env.POD_NAMESPACE;
  try {
    return fs.readFileSync(`${SA_DIR}/namespace`, 'utf8').trim();
  } catch {
    return 'production';
  }
}

function requestJson(method, url, token, body, ca) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const lib = u.protocol === 'https:' ? https : http;
    const data = body ? JSON.stringify(body) : null;
    const req = lib.request(
      {
        hostname: u.hostname,
        port: u.port,
        path: u.pathname + u.search,
        method,
        headers: {
          Authorization: `Bearer ${token}`,
          ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}),
        },
        ca,
        timeout: 15000,
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let json = null;
          try { json = text ? JSON.parse(text) : null; } catch { /* body khong phai JSON */ }
          resolve({ status: res.statusCode, body: json, text });
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('K8s API timeout sau 15s')));
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

// Tao 1 Job trong namespace hien tai. Tra ve Job da tao (HTTP 201).
async function createJob(job) {
  const { baseUrl, token, ca } = getApiConfig();
  const namespace = getNamespace();
  const { status, body, text } = await requestJson(
    'POST', `${baseUrl}/apis/batch/v1/namespaces/${namespace}/jobs`, token, job, ca
  );
  if (status !== 201) {
    const detail = (body && body.message) || text || '';
    throw new Error(`Tao Job that bai (HTTP ${status}): ${detail}`.slice(0, 300));
  }
  return body;
}

// Kiem tra 1 Secret co ton tai khong (dung de biet co can gan
// imagePullSecrets cho Job xu ly hay khong). 404 -> false.
async function secretExists(name) {
  const { baseUrl, token, ca } = getApiConfig();
  const namespace = getNamespace();
  const { status } = await requestJson(
    'GET', `${baseUrl}/api/v1/namespaces/${namespace}/secrets/${name}`, token, null, ca
  );
  if (status === 200) return true;
  if (status === 404) return false;
  throw new Error(`Kiem tra Secret ${name} that bai (HTTP ${status})`);
}

module.exports = { createJob, secretExists, getNamespace };
