'use strict';

const API = 'cgi-bin/api.sh';
const LS_TOKEN = 'ayu.token';  // session-only: never persisted to disk
let token = sessionStorage.getItem(LS_TOKEN) || '';
let view = 'overview';
let timer = null;

/* ---------- helpers ---------- */

function $(sel) { return document.querySelector(sel); }
function $$(sel) { return Array.from(document.querySelectorAll(sel)); }

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function bytes(n) {
  n = Number(n) || 0;
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
  return (n / 1073741824).toFixed(2) + ' GB';
}

function kbBytes(kb) { return bytes((Number(kb) || 0) * 1024); }

function duration(sec) {
  sec = Math.max(0, Math.floor(Number(sec) || 0));
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d) return d + ' 天 ' + h + ' 小时';
  if (h) return h + ' 小时 ' + m + ' 分';
  return m + ' 分';
}

function setConn(ok, text) {
  const dot = $('#status-dot');
  dot.className = 'dot ' + (ok ? 'ok' : 'err');
  $('#status-text').textContent = text;
}

/* ---------- api ---------- */

async function api(action, params) {
  const qs = new URLSearchParams(Object.assign({ action, token }, params || {}));
  const res = await fetch(API + '?' + qs.toString(), { cache: 'no-store' });
  if (res.status === 403) { const e = new Error('forbidden'); e.code = 403; throw e; }
  if (!res.ok) throw new Error('HTTP ' + res.status);
  return res.json();
}

/* ---------- views ---------- */

function statCard(label, value, cls) {
  return '<div class="stat"><div class="stat-label">' + esc(label) + '</div>' +
         '<div class="stat-value ' + (cls || '') + '">' + value + '</div></div>';
}

function renderOverview(d) {
  const p = d.platforms || {};
  const flag = (on) => on ? '<span class="stat-value ok">已配置</span>' : '<span class="stat-value off">未配置</span>';
  let html = '';
  html += statCard('运行时长', esc(duration(d.uptime_s)), '');
  html += '<div class="stat"><div class="stat-label">QQ</div>' + flag(p.qq) + '</div>';
  html += '<div class="stat"><div class="stat-label">Telegram</div>' + flag(p.telegram) + '</div>';
  html += '<div class="stat"><div class="stat-label">Discord</div>' + flag(p.discord) + '</div>';
  html += statCard('服务端口', esc(d.host + ':' + d.port), '');
  $('#stat-grid').innerHTML = html;

  const st = d.state || {}, lg = d.logs || {}, md = d.media || {};
  $('#storage-table').innerHTML =
    row('消息映射 (msg-map)', (st.msg_map || 0) + ' 条 / ' + (st.groups || 0) + ' 个会话') +
    row('反向映射 (msg-map-rev)', (st.msg_map_rev || 0) + ' 条') +
    row('state 占用', kbBytes(st.dir_kb)) +
    row('转发媒体缓存 (/tmp/img)', (md.cache_files || 0) + ' 个 / ' + kbBytes(md.cache_kb)) +
    row('日志体积', 'bot ' + bytes(lg.bot) + ' · error ' + bytes(lg.error) + ' · cron ' + bytes(lg.cron)) +
    row('日志目录占用', kbBytes(lg.dir_kb));
}

function row(k, v) {
  return '<tr><td>' + esc(k) + '</td><td>' + v + '</td></tr>';
}

function renderSync(d) {
  const pairs = d.pairs || [];
  $('#sync-count').textContent = pairs.length ? '(' + pairs.length + ' 组)' : '';
  const tbody = $('#sync-table tbody');
  if (!pairs.length) {
    tbody.innerHTML = '<tr><td colspan="2" class="muted">sync.conf 中没有有效映射</td></tr>';
    return;
  }
  tbody.innerHTML = pairs.map(function (p) {
    const targets = (p.targets || []).map(function (t) { return '<code>' + esc(t) + '</code>'; }).join('<br>');
    return '<tr><td><code>' + esc(p.source) + '</code></td><td>' + targets + '</td></tr>';
  }).join('');
}

function renderLogs(d) {
  const body = d.lines || [];
  const box = $('#log-body');
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
  box.innerHTML = body.map(function (l) {
    const cls = /\b(ERROR|FAIL|fatal)\b/i.test(l) ? 'err' : (/\bWARN\b/i.test(l) ? 'warn' : '');
    return cls ? '<span class="' + cls + '">' + esc(l) + '</span>' : esc(l);
  }).join('\n');
  if (atBottom) box.scrollTop = box.scrollHeight;
}

function renderConfig(d) {
  const rows = [
    ['监听地址', esc(d.bot_host) + ':' + esc(d.bot_port)],
    ['QQ API', '<code>' + esc(d.qq_api_base || '-') + '</code>'],
    ['Telegram API', '<code>' + esc(d.tg_api_base || '-') + '</code>'],
    ['Discord API', '<code>' + esc(d.dc_api_base || '-') + '</code>'],
    ['Telegram Token', d.token_masked ? '<span class="muted">已配置（隐藏）</span>' : '<span class="muted">未配置</span>'],
    ['转发单文件上限', bytes(d.max_file_size)],
    ['日志级别', esc(d.log_level)]
  ];
  $('#config-table').innerHTML = rows.map(function (r) { return row(r[0], r[1]); }).join('');
}

/* ---------- loading ---------- */

async function load() {
  try {
    if (view === 'overview') {
      const [status, cfg] = await Promise.all([api('status'), api('config')]);
      renderOverview(status);
      renderConfig(cfg);
      const m = status.maintenance || {};
      $('#maint-table').innerHTML =
        row('最近维护', '<span class="muted">' + esc(m.last_run || '暂无记录') + '</span>') +
        row('日志轮转', '单个日志超过阈值自动归档为 .1 / .2') +
        row('临时文件清理', '每日 04:17 及启动时清理请求/上传残留') +
        row('保留内容', '聊天映射、转发媒体缓存一律不删除');
      setConn(true, '已连接');
    } else if (view === 'sync') {
      renderSync(await api('sync'));
      setConn(true, '已连接');
    } else if (view === 'logs') {
      renderLogs(await api('logs', { which: $('#log-which').value, lines: 200 }));
      setConn(true, '已连接');
    } else if (view === 'config') {
      const status = await api('status');
      renderConfig(await api('config'));
      $('#maint-table').innerHTML = row('上次维护记录', '<span class="muted">' + esc((status.maintenance || {}).last_run || '暂无记录') + '</span>');
      setConn(true, '已连接');
    }
  } catch (e) {
    if (e.code === 403) { logout(); return; }
    setConn(false, '连接失败');
  }
}

function schedule() {
  clearInterval(timer);
  if (view === 'logs' && !$('#log-follow').checked) return;
  timer = setInterval(load, view === 'logs' ? 5000 : 15000);
}

function switchView(v) {
  view = v;
  $$('.tab').forEach(function (t) { t.classList.toggle('active', t.dataset.view === v); });
  $$('.view').forEach(function (s) { s.classList.toggle('hidden', s.id !== 'view-' + v); });
  load();
  schedule();
}

function logout() {
  sessionStorage.removeItem(LS_TOKEN);
  token = '';
  clearInterval(timer);
  $('#app').classList.add('hidden');
  $('#gate').classList.remove('hidden');
  $('#gate-err').textContent = '密钥无效或已失效，请重新输入';
}

function start() {
  $('#gate').classList.add('hidden');
  $('#app').classList.remove('hidden');
  load();
  schedule();
}

/* ---------- events ---------- */

$('#gate-form').addEventListener('submit', async function (ev) {
  ev.preventDefault();
  token = $('#token').value.trim();
  if (!token) return;
  try {
    await api('status');
    sessionStorage.setItem(LS_TOKEN, token);
    $('#gate-err').textContent = '';
    $('#token').value = '';
    start();
  } catch (e) {
    $('#gate-err').textContent = '密钥错误，请重试';
  }
});

$$('.tab').forEach(function (t) { t.addEventListener('click', function () { switchView(t.dataset.view); }); });
$('#refresh').addEventListener('click', load);
$('#logout').addEventListener('click', logout);
$('#log-which').addEventListener('change', load);
$('#log-follow').addEventListener('change', schedule);
document.addEventListener('visibilitychange', function () { document.hidden ? clearInterval(timer) : schedule(); });

if (token) start(); else $('#gate').classList.remove('hidden');
