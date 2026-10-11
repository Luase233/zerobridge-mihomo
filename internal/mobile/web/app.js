'use strict';
const $ = id => document.getElementById(id);
let token = '', state = null, groupName = '', busy = false, operation = '', loading = false;
let connected = false, pending = null, noticeTimer, readController = null, revision = 0;
const storage = {
 get(key) { try { return localStorage.getItem(key) || sessionStorage.getItem(key) || '' } catch { return '' } },
 save(value, remember) { try { localStorage.removeItem('zb-token'); sessionStorage.removeItem('zb-token'); (remember ? localStorage : sessionStorage).setItem('zb-token', value) } catch {} },
 clear() { try { localStorage.removeItem('zb-token'); sessionStorage.removeItem('zb-token') } catch {} }
};
function notify(message) {
 $('notice').textContent = message; $('notice').hidden = false;
 clearTimeout(noticeTimer); noticeTimer = setTimeout(() => $('notice').hidden = true, 6500);
}
function status(ok, text) {
 connected = ok; $('connection').classList.toggle('online', ok); $('connectionText').textContent = text;
 controls();
}
function page(name) {
 for (const id of ['proxies', 'history', 'settings']) $(id).hidden = id !== name;
 document.querySelectorAll('[data-page]').forEach(b => b.classList.toggle('active', b.dataset.page === name));
}
async function api(path, body, options = {}) {
 const ctrl = options.controller || new AbortController();
 const timer = setTimeout(() => ctrl.abort(), options.timeout || 25000);
 try {
  const res = await fetch(path, {
   method: body ? 'POST' : 'GET',
   headers: { Authorization: 'Bearer ' + token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
   body: body ? JSON.stringify(body) : undefined, cache: 'no-store', signal: ctrl.signal
  });
  if (res.status === 401) throw Error('访问密钥无效，请重新配对');
  if (!res.ok) {
   let detail; try { detail = await res.json() } catch {}
   throw Error(detail?.error || '连接失败（' + res.status + '）');
  }
  return await res.json();
 } finally { clearTimeout(timer) }
}
function element(tag, text, className) {
 const el = document.createElement(tag);
 if (text !== undefined) el.textContent = text;
 if (className) el.className = className;
 return el;
}
function currentGroup() { return state?.groups.find(g => g.name === groupName) }
function controls() {
 const g = currentGroup();
 $('groups').disabled = busy || !connected || !state?.groups.length;
 $('refresh').disabled = busy;
 $('testDelay').disabled = busy || !connected || !g?.all?.length;
 $('testDelay').textContent = operation === 'delay' ? '正在测速…' : '测本组延迟';
 $('sort').disabled = busy || !connected || !g;
 $('apply').disabled = busy || !connected || !pending;
 $('logout').disabled = busy;
}
function acceptState(next) {
 const changedMode = state?.mode !== next.mode;
 state = next;
 if (changedMode || !state.groups.some(g => g.name === groupName)) {
  const fallback = state.mode === 'rule' ? state.groups.find(g => g.selectable && g.name !== 'GLOBAL') : state.groups[0];
  groupName = state.groups.find(g => g.name === state.preferred_group)?.name || fallback?.name || state.groups[0]?.name || '';
 }
 status(state.online, state.online ? '已连接电脑 · ' + new Date(state.updated).toLocaleTimeString() : '电脑在线 · Clash 暂不可用');
 $('login').hidden = true; $('tabs').hidden = false;
 if ($('proxies').hidden && $('history').hidden && $('settings').hidden) page('proxies');
 render();
}
function render() {
 if (!state) { controls(); return }
 $('mode').textContent = ({ global: '全局模式', rule: '规则模式', direct: '直连模式' })[state.mode] || state.mode;
 if (state.version) $('version').textContent = state.version.startsWith('v') ? state.version : 'v' + state.version;
 const select = $('groups'); select.replaceChildren();
 for (const g of state.groups) {
  const name = g.name + (state.mode === 'rule' && state.routing_known !== false && g.name === 'GLOBAL' && g.routing_used === false ? ' · 非规则出站' : '') + (g.selectable ? '' : ' · 自动');
  const option = element('option', name); option.value = g.name; select.append(option);
 }
 select.value = groupName;
 renderNodes(); renderEvents(); controls();
}
function routingHint(g) {
 if (state.mode === 'direct') return '当前为直连模式。代理组内的选择不会用于当前直连出站。';
 if (g.routing_used === false) {
  if (g.routing_note) return g.routing_note;
  if (state.mode === 'rule' && g.name === 'GLOBAL') return '当前规则没有使用 GLOBAL；请优先选择规则引用的代理组。';
  return '此组未用于当前模式的出站链路。切换只会更新组内选择，请选择当前路由使用的代理组。';
 }
 if (g.routing_used === true && g.routing_note) return g.routing_note;
 if (state.mode === 'global' && g.name !== 'GLOBAL') return '当前为全局模式。此组只有被 GLOBAL 当前选择引用时才影响全局出口。';
 return g.routing_note || '此组用于当前模式的路由选择；规则和已有连接仍会影响实际出口。';
}
function delayInfo(name) {
 const value = state?.latencies && Object.prototype.hasOwnProperty.call(state.latencies, name) ? state.latencies[name] : null;
 const delay = value?.delay_ms;
 if (value?.status === 'ok' && typeof delay === 'number' && Number.isFinite(delay) && delay >= 0) {
  return { text: Math.round(delay) + ' ms', className: delay < 150 ? 'fast' : delay < 500 ? 'medium' : 'slow', rank: 0, delay, tested: value.tested_at };
 }
 const info = { timeout: ['超时', 'timeout', 1], error: ['测速失败', 'timeout', 2] }[value?.status];
 return { text: info?.[0] || '未测速', className: info?.[1] || 'untested', rank: info?.[2] || 3, delay: Infinity, tested: value?.tested_at };
}
function renderNodes() {
 const g = currentGroup(), q = $('search').value.toLocaleLowerCase();
 $('currentNode').textContent = g?.now || '未选择';
 $('groupHint').textContent = !g ? '没有可用代理组' : routingHint(g) + (g.selectable ? ' 确认切换后，两端同步显示组内结果。' : ' 此组由 Clash 自动选择，请选择手动代理组进行切换。');
 $('groupHint').classList.toggle('routingWarning', !!g && (g.routing_used === false || state.mode === 'direct'));
 const list = $('nodes'); list.replaceChildren();
 const names = (g?.all || []).map((name, index) => ({ name, index, latency: delayInfo(name) })).filter(n => n.name.toLocaleLowerCase().includes(q));
 if ($('sort').value === 'latency') names.sort((a, b) => a.latency.rank - b.latency.rank || a.latency.delay - b.latency.delay || a.index - b.index);
 $('nodeCount').textContent = names.length + ' 项';
 for (const { name, latency } of names) {
  const selected = name === g.now, button = element('button', undefined, 'node' + (selected ? ' selected' : ''));
  button.type = 'button'; button.disabled = busy || !connected || !g.selectable || selected;
  const meta = element('span', undefined, 'nodeMeta'), badge = element('span', latency.text, 'latency ' + latency.className);
  if (latency.tested) badge.title = '电脑测速 · ' + new Date(latency.tested).toLocaleString();
  meta.append(badge, element('small', selected ? '组内当前' : g.selectable ? '选择' : '自动'));
  button.append(element('span', undefined, 'indicator'), element('span', name, 'name'), meta);
  button.addEventListener('click', () => {
   if (busy || !connected) return;
   pending = { group: g.name, name };
   $('confirmGroup').textContent = '代理组 · ' + g.name; $('confirmNode').textContent = name;
   $('confirmHint').textContent = routingHint(g) + ' 结果将在两端同步显示。';
   controls(); $('confirm').showModal();
  });
  list.append(button);
 }
 if (!names.length) list.append(element('div', '没有匹配的节点', 'empty'));
 controls();
}
function outcome(e) {
 let text = ({ success: '组内选择已确认 · Clash 已回读', pending: '命令执行中', unconfirmed: '结果待确认，请刷新当前选择' })[e.status] || e.status;
 if (e.routing_used === false) text += '；' + (e.routing_note || '此组未用于当前模式的出站链路');
 return text;
}
function renderEvents() {
 const list = $('events'); list.replaceChildren();
 for (const e of [...(state.events || [])].reverse()) {
  const warning = e.routing_used === false, card = element('article', undefined, 'event'), row = element('div', undefined, 'row');
  row.append(element('span', new Date(e.time).toLocaleTimeString()), element('span', e.status === 'success' ? warning ? '组内已同步' : '已同步' : '待确认', 'pill'));
  card.append(row, element('strong', e.group + ' → ' + e.target), element('p', '原选择：' + e.before), element('p', outcome(e), e.status === 'success' && !warning ? 'result' : 'warning'), element('p', '来源 ' + e.client));
  list.append(card);
 }
 if (!state.events?.length) list.append(element('div', '还没有切换记录。手机命令将在这里和电脑端同时显示。', 'empty'));
}
function abortRead() {
 revision++; readController?.abort(); readController = null; loading = false;
}
async function refresh(silent = false) {
 if (!token || loading || busy) return;
 const current = ++revision, ctrl = new AbortController(); readController = ctrl; loading = true;
 try {
  const next = await api('/api/state', undefined, { controller: ctrl });
  if (current !== revision || busy) return;
  acceptState(next);
  if (!state.online && !silent) notify('Clash 暂不可用，请检查电脑上的 Clash');
 } catch (e) {
  if (current !== revision) return;
  status(false, '未连接 · 请检查 ZeroTier 和电脑');
  if (state) renderNodes();
  if (!silent) notify(e.name === 'AbortError' ? '连接超时，请检查电脑和 ZeroTier' : e.message);
  if (e.message.includes('密钥')) forget('访问密钥无效，请重新配对');
 } finally {
  if (current === revision) { loading = false; readController = null }
 }
}
function beginOperation(name) {
 busy = true; operation = name; abortRead(); render();
}
async function finishOperation() { busy = false; operation = ''; render(); await refresh(true) }
function forget(text) {
 abortRead(); storage.clear(); token = ''; state = null; groupName = ''; pending = null;
 if ($('confirm').open) $('confirm').close();
 status(false, text); $('login').hidden = false; $('tabs').hidden = true;
 for (const id of ['proxies', 'history', 'settings']) $(id).hidden = true;
}
$('loginForm').addEventListener('submit', async e => {
 e.preventDefault(); abortRead(); token = $('token').value.trim(); storage.save(token, $('remember').checked);
 await refresh(); if (connected) $('token').value = '';
});
$('groups').addEventListener('change', () => { groupName = $('groups').value; renderNodes() });
$('search').addEventListener('input', renderNodes);
$('sort').addEventListener('change', renderNodes);
$('refresh').addEventListener('click', () => refresh());
$('cancel').addEventListener('click', () => { pending = null; $('confirm').close(); controls() });
$('confirm').addEventListener('cancel', () => { pending = null; controls() });
$('apply').addEventListener('click', async () => {
 if (busy || !connected || !pending) return;
 const command = pending; pending = null; $('confirm').close();
 const g = state.groups.find(group => group.name === command.group);
 if (!g?.selectable || !g.all.includes(command.name)) { notify('代理组已改变，请刷新后重新选择'); return }
 beginOperation('select');
 const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
 const id = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
 try {
  const result = await api('/api/select', { id, group: command.group, name: command.name });
  notify(outcome(result));
 } catch (e) {
  status(false, '命令结果待确认');
  notify('命令结果未确认：' + (e.name === 'AbortError' ? '请求超时' : e.message) + '。请先查看记录和当前选择。');
 } finally { await finishOperation() }
});
$('testDelay').addEventListener('click', async () => {
 const g = currentGroup();
 if (busy || !connected || !g?.all?.length) return;
 const commandGroup = g.name; beginOperation('delay');
 notify('正在由电脑测试本组节点延迟，请稍候…');
 try {
  const next = await api('/api/delay', { group: commandGroup }, { timeout: 90000 });
  acceptState(next); notify('本组测速完成，超时或失败的节点已单独标记。');
 } catch (e) {
  notify('测速未完成：' + (e.name === 'AbortError' ? '请求超时，请刷新查看已完成的结果' : e.message));
 } finally { await finishOperation() }
});
document.querySelectorAll('[data-page]').forEach(b => b.addEventListener('click', () => page(b.dataset.page)));
$('logout').addEventListener('click', () => { if (!busy) forget('已忘记此设备') });
$('address').textContent = location.origin;
const fragment = new URLSearchParams(location.hash.slice(1));
if (fragment.has('token')) { $('token').value = fragment.get('token'); history.replaceState(null, '', location.pathname) }
else { token = storage.get('zb-token'); if (token) refresh() }
controls();
setInterval(() => { if (!document.hidden) refresh(true) }, 5000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(true) });
