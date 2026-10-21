// 通过真实 JWT/数据库授权与 HTTPS 路由验收；临时账号最后删除，不输出凭据。
const { createRequire } = require('node:module');
const { resolve } = require('node:path');
const { readFileSync } = require('node:fs');
const { randomBytes } = require('node:crypto');
const appRequire = createRequire(resolve('package.json'));
const { Client } = appRequire('pg');
const jwt = appRequire('jsonwebtoken');
const origin = process.env.OCR_SMOKE_ORIGIN || 'https://kushui.shop';
const fixtures = process.env.OCR_SMOKE_FIXTURES;
if (!fixtures || !process.env.JWT_SECRET) throw new Error('Smoke environment required');
const db = new Client({ host: process.env.DB_HOST, port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER, password: process.env.DB_PASSWORD, database: process.env.DB_NAME });
const users = [], jobs = [];
const started = Date.now();
const evidence = { origin, startedAt: new Date().toISOString(), checks: [] };

async function request(token, method, path, body) {
  const result = await fetch(origin + '/uapi/ocr/' + path, {
    method, redirect: 'error', signal: AbortSignal.timeout(30000),
    headers: { Authorization: 'Bearer ' + token, ...(body ? { 'Content-Type': 'application/octet-stream' } : {}) },
    ...(body ? { body } : {}),
  });
  const raw = await result.json();
  return { status: result.status, data: raw.data };
}
function assert(value, label) { if (!value) throw new Error(label); }
async function create(token, name, kind, pages) {
  const id = randomBytes(16).toString('hex');
  jobs.push([token, id]);
  const result = await request(token, 'POST', `jobs/${id}?kind=${kind}${pages ? '&pages=' + pages : ''}`,
    readFileSync(resolve(fixtures, name)));
  assert([200, 201].includes(result.status), 'job_create_' + result.status);
  return id;
}
async function complete(token, id) {
  for (let count = 0; count < 120; count++) {
    const response = await request(token, 'GET', 'jobs/' + id);
    assert(response.status === 200, 'poll_' + response.status);
    if (response.data.state === 'completed') return response.data.result;
    assert(!['failed', 'cancelled'].includes(response.data.state), 'job_' + response.data.state + '_' + (response.data.error || ''));
    await new Promise(resolve => setTimeout(resolve, 2000));
  }
  throw new Error('smoke_timeout');
}
async function main() {
  await db.connect();
  try {
    for (let index = 0; index < 2; index++) {
      const userName = 'ocr-smoke-' + randomBytes(12).toString('hex');
      const row = (await db.query('INSERT INTO users ("userName", role, banned, "tokenVersion") VALUES ($1, $2, false, 0) RETURNING id', [userName, 'user'])).rows[0];
      const token = jwt.sign({ userId: row.id, userName, role: 'user', tokenVersion: 0 }, process.env.JWT_SECRET, { expiresIn: '10m', algorithm: 'HS256' });
      users.push({ id: row.id, token });
    }
    const token = users[0].token;
    assert((await request('invalid', 'GET', 'capabilities')).status === 401, 'jwt_guard');
    assert((await request(token, 'GET', 'capabilities')).data.available === true, 'capabilities');
    evidence.checks.push('JWT required and worker available');
    const imageJob = await create(token, 'chatai-ocr-test.png', 'image');
    assert((await request(users[1].token, 'GET', 'jobs/' + imageJob)).status === 404, 'other_owner_read');
    assert((await request(users[1].token, 'DELETE', 'jobs/' + imageJob)).status === 404, 'other_owner_cancel');
    const image = await complete(token, imageJob);
    assert(image.pages[0].text.includes('OCR') && image.pages[0].text.includes('2026'), 'image_text');
    assert(image.pages[0].lines.length > 0 && image.pages[0].lines[0].box.length === 4, 'image_boxes');
    evidence.checks.push('real image text, boxes and confidence; cross-account read/cancel denied');
    await request(token, 'DELETE', 'jobs/' + imageJob);
    assert(!(await request(token, 'GET', 'jobs/' + imageJob)).data.result, 'result_deleted');
    const chineseJob = await create(token, 'chatai-ocr-chinese.png', 'image');
    const chinese = await complete(token, chineseJob);
    assert(chinese.pages[0].text.includes('服务器') && chinese.pages[0].text.includes('知识库'), 'chinese_text');
    evidence.checks.push('real Chinese image recognition');
    await request(token, 'DELETE', 'jobs/' + chineseJob);
    const pdfJob = await create(token, 'chatai-ocr-test.pdf', 'pdf');
    const pdf = await complete(token, pdfJob);
    assert(pdf.totalPages === 1 && pdf.pages[0].page === 1 && pdf.pages[0].text.includes('2026'), 'pdf_text');
    evidence.checks.push('real scanned PDF text and original page number');
    await request(token, 'DELETE', 'jobs/' + pdfJob);
    const mixedJob = await create(token, 'chatai-ocr-mixed.pdf', 'pdf', '2,4');
    const mixed = await complete(token, mixedJob);
    assert(mixed.totalPages === 5 && mixed.pages.map(p => p.page).join(',') === '2,4', 'selected_pdf_pages');
    evidence.checks.push('5-page PDF recognizes only pages 2 and 4');
    await request(token, 'DELETE', 'jobs/' + mixedJob);
    const cancelled = await create(token, 'chatai-ocr-mixed.pdf', 'pdf');
    await request(token, 'DELETE', 'jobs/' + cancelled);
    const cancelledJob = await request(token, 'GET', 'jobs/' + cancelled);
    assert(cancelledJob.data.state === 'cancelled' && !cancelledJob.data.result, 'cancelled_job');
    evidence.checks.push('cancelled task cannot publish a result');
    if (process.env.OCR_SMOKE_STRESS === 'true') {
      const stressStarted = Date.now();
      const stressJob = await create(token, 'chatai-ocr-stress.pdf', 'pdf');
      const stress = await complete(token, stressJob);
      assert(stress.totalPages === 20 && stress.pages.length === 20, '20_page_pdf');
      assert(stress.pages.every(page => page.text.includes('2026')), '20_page_text');
      await request(token, 'DELETE', 'jobs/' + stressJob);
      evidence.stressSeconds = Math.round((Date.now() - stressStarted) / 1000);
      evidence.checks.push('20-page Chinese scanned PDF completed under worker limits');
    }
    assert((await fetch(origin + '/healthz', { signal: AbortSignal.timeout(10000) })).ok, 'api_health');
    evidence.elapsedSeconds = Math.round((Date.now() - started) / 1000);
    console.log(JSON.stringify(evidence));
  } finally {
    for (const [token, id] of jobs) { try { await request(token, 'DELETE', 'jobs/' + id); } catch {} }
    for (const user of users) await db.query('DELETE FROM users WHERE id=$1', [user.id]);
    await db.end();
  }
}
main().catch(error => { console.error('OCR smoke failed: ' + error.message); process.exitCode = 1; });
