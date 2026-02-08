const configRefresh = document.getElementById('configRefresh');
const configSave = document.getElementById('configSave');
const summaryArea = document.getElementById('summaryArea');
const summaryRefresh = document.getElementById('summaryRefresh');
const summarySave = document.getElementById('summarySave');
const logUpload = document.getElementById('logUpload');
const logStatus = document.getElementById('logStatus');
const sessionsList = document.getElementById('sessionsList');
const sessionDetail = document.getElementById('sessionDetail');
const sessionsRefresh = document.getElementById('sessionsRefresh');

const fields = {
  http_listen: document.getElementById('http_listen'),
  xiaozhi_websocket: document.getElementById('xiaozhi_websocket'),
  exit_after_silence_seconds: document.getElementById('exit_after_silence_seconds'),
  summary_rewrite_every: document.getElementById('summary_rewrite_every'),
  context_max_tokens: document.getElementById('context_max_tokens'),
  session_context_max_messages: document.getElementById('session_context_max_messages'),
  history_silence_seconds: document.getElementById('history_silence_seconds'),
  recent_rounds: document.getElementById('recent_rounds'),

  asr_active: document.getElementById('asrActive'),
  asr_add: document.getElementById('asrAdd'),
  asr_delete: document.getElementById('asrDelete'),
  asr_name: document.getElementById('asr_name'),
  asr_use: document.getElementById('asr_use'),
  asr_secret_id: document.getElementById('asr_secret_id'),
  asr_secret_key: document.getElementById('asr_secret_key'),

  tts_active: document.getElementById('ttsActive'),
  tts_add: document.getElementById('ttsAdd'),
  tts_delete: document.getElementById('ttsDelete'),
  tts_name: document.getElementById('tts_name'),
  tts_use: document.getElementById('tts_use'),
  tts_azure_region: document.getElementById('tts_azure_region'),
  tts_azure_api_key: document.getElementById('tts_azure_api_key'),

  llm_active: document.getElementById('llmActive'),
  llm_add: document.getElementById('llmAdd'),
  llm_delete: document.getElementById('llmDelete'),
  llm_name: document.getElementById('llm_name'),
  llm_chat_api_url: document.getElementById('llm_chat_api_url'),
  llm_chat_api_key: document.getElementById('llm_chat_api_key'),
  llm_chat_model: document.getElementById('llm_chat_model'),
  llm_think_api_url: document.getElementById('llm_think_api_url'),
  llm_think_api_key: document.getElementById('llm_think_api_key'),
  llm_think_model: document.getElementById('llm_think_model'),
};

let asrProfiles = [];
let ttsProfiles = [];
let llmProfiles = [];
let asrUseName = '';
let ttsUseName = '';
let llmUseName = '';
let asrCurrentId = '';
let ttsCurrentId = '';
let llmCurrentId = '';

function getNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function genId() {
  return `${Date.now()}_${Math.random().toString(16).slice(2, 8)}`;
}

function ensureIds(profiles, prefix) {
  return profiles.map((p, idx) => ({
    id: p.id || `${prefix}_${idx}_${genId()}`,
    ...p,
  }));
}

function renderSelect(select, profiles, activeId) {
  select.innerHTML = '';
  profiles.forEach((p) => {
    const opt = document.createElement('option');
    opt.value = p.id;
    opt.textContent = p.name;
    if (p.id === activeId) opt.selected = true;
    select.appendChild(opt);
  });
}

function currentProfile(profiles, id) {
  return profiles.find((p) => p.id === id) || profiles[0];
}

function bindAsrForm(profile) {
  fields.asr_name.value = profile?.name || '';
  fields.asr_use.value = profile?.use || '';
  fields.asr_secret_id.value = profile?.tencent?.secret_id || '';
  fields.asr_secret_key.value = profile?.tencent?.secret_key || '';
}

function bindTtsForm(profile) {
  fields.tts_name.value = profile?.name || '';
  fields.tts_use.value = profile?.use || '';
  fields.tts_azure_region.value = profile?.azure?.region || '';
  fields.tts_azure_api_key.value = profile?.azure?.api_key || '';
}

function bindLlmForm(profile) {
  fields.llm_name.value = profile?.name || '';
  fields.llm_chat_api_url.value = profile?.chat?.api_url || '';
  fields.llm_chat_api_key.value = profile?.chat?.api_key || '';
  fields.llm_chat_model.value = profile?.chat?.model || '';
  fields.llm_think_api_url.value = profile?.think?.api_url || '';
  fields.llm_think_api_key.value = profile?.think?.api_key || '';
  fields.llm_think_model.value = profile?.think?.model || '';
}

function updateAsrProfileFromForm() {
  const p = currentProfile(asrProfiles, asrCurrentId);
  if (!p) return;
  p.name = fields.asr_name.value.trim() || p.name;
  p.use = fields.asr_use.value.trim();
  p.tencent = {
    secret_id: fields.asr_secret_id.value.trim(),
    secret_key: fields.asr_secret_key.value.trim(),
  };
}

function updateTtsProfileFromForm() {
  const p = currentProfile(ttsProfiles, ttsCurrentId);
  if (!p) return;
  p.name = fields.tts_name.value.trim() || p.name;
  p.use = fields.tts_use.value.trim();
  p.azure = {
    region: fields.tts_azure_region.value.trim(),
    api_key: fields.tts_azure_api_key.value.trim(),
  };
}

function updateLlmProfileFromForm() {
  const p = currentProfile(llmProfiles, llmCurrentId);
  if (!p) return;
  p.name = fields.llm_name.value.trim() || p.name;
  p.chat = {
    api_url: fields.llm_chat_api_url.value.trim(),
    api_key: fields.llm_chat_api_key.value.trim(),
    model: fields.llm_chat_model.value.trim(),
  };
  p.think = {
    api_url: fields.llm_think_api_url.value.trim(),
    api_key: fields.llm_think_api_key.value.trim(),
    model: fields.llm_think_model.value.trim(),
  };
}

async function refreshConfig() {
  const resp = await fetch('/manager/config');
  const data = await resp.json();
  fields.http_listen.value = data.http_listen || '';
  fields.xiaozhi_websocket.value = data.xiaozhi_websocket || '';
  fields.exit_after_silence_seconds.value = data.exit_after_silence_seconds ?? '';

  const history = data.history || {};
  fields.summary_rewrite_every.value = history.summary_rewrite_every ?? '';
  fields.context_max_tokens.value = history.context_max_tokens ?? '';
  fields.session_context_max_messages.value = history.session_context_max_messages ?? '';
  fields.history_silence_seconds.value = history.silence_seconds ?? '';
  fields.recent_rounds.value = history.recent_rounds ?? '';

  const asr = data.asr || {};
  asrProfiles = ensureIds(asr.profiles || [], 'asr');
  asrUseName = asr.use_name || (asrProfiles[0]?.name || '');
  const asrActive = asrProfiles.find((p) => p.name === asrUseName) || asrProfiles[0];
  asrCurrentId = asrActive?.id || '';
  renderSelect(fields.asr_active, asrProfiles, asrCurrentId);
  bindAsrForm(currentProfile(asrProfiles, asrCurrentId));

  const tts = data.tts || {};
  ttsProfiles = ensureIds(tts.profiles || [], 'tts');
  ttsUseName = tts.use_name || (ttsProfiles[0]?.name || '');
  const ttsActive = ttsProfiles.find((p) => p.name === ttsUseName) || ttsProfiles[0];
  ttsCurrentId = ttsActive?.id || '';
  renderSelect(fields.tts_active, ttsProfiles, ttsCurrentId);
  bindTtsForm(currentProfile(ttsProfiles, ttsCurrentId));

  const llm = data.llm || {};
  llmProfiles = ensureIds(llm.profiles || [], 'llm');
  llmUseName = llm.use_name || (llmProfiles[0]?.name || '');
  const llmActive = llmProfiles.find((p) => p.name === llmUseName) || llmProfiles[0];
  llmCurrentId = llmActive?.id || '';
  renderSelect(fields.llm_active, llmProfiles, llmCurrentId);
  bindLlmForm(currentProfile(llmProfiles, llmCurrentId));
}

function buildPayload() {
  return {
    http_listen: fields.http_listen.value.trim(),
    xiaozhi_websocket: fields.xiaozhi_websocket.value.trim(),
    exit_after_silence_seconds: getNumber(fields.exit_after_silence_seconds.value),
    history: {
      summary_rewrite_every: getNumber(fields.summary_rewrite_every.value),
      context_max_tokens: getNumber(fields.context_max_tokens.value),
      session_context_max_messages: getNumber(fields.session_context_max_messages.value),
      silence_seconds: getNumber(fields.history_silence_seconds.value),
      recent_rounds: getNumber(fields.recent_rounds.value),
    },
    asr: {
      use_name: asrUseName,
      profiles: asrProfiles,
    },
    tts: {
      use_name: ttsUseName,
      profiles: ttsProfiles,
    },
    llm: {
      use_name: llmUseName,
      profiles: llmProfiles,
    },
  };
}

async function persistConfig() {
  const payload = buildPayload();
  const resp = await fetch('/manager/config', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!resp.ok) {
    alert('保存失败');
    return false;
  }
  return true;
}

async function saveConfig() {
  updateAsrProfileFromForm();
  updateTtsProfileFromForm();
  updateLlmProfileFromForm();
  renderSelect(fields.asr_active, asrProfiles, asrCurrentId);
  renderSelect(fields.tts_active, ttsProfiles, ttsCurrentId);
  renderSelect(fields.llm_active, llmProfiles, llmCurrentId);
  const ok = await persistConfig();
  if (!ok) return;
  configSave.textContent = '已保存';
  setTimeout(() => (configSave.textContent = '保存配置'), 1200);
}

async function refreshSummary() {
  const resp = await fetch('/manager/summary');
  const text = await resp.text();
  summaryArea.value = text;
}

async function saveSummary() {
  const resp = await fetch('/manager/summary', {
    method: 'POST',
    headers: { 'content-type': 'text/plain' },
    body: summaryArea.value || '',
  });
  if (!resp.ok) {
    alert('保存失败');
    return;
  }
  summarySave.textContent = '已保存';
  setTimeout(() => (summarySave.textContent = '保存总结'), 1200);
}

function formatTs(ts) {
  if (!ts) return '';
  const date = new Date(ts * 1000);
  return date.toLocaleString();
}

async function refreshSessions() {
  const resp = await fetch('/manager/sessions');
  const list = await resp.json();
  sessionsList.innerHTML = '';
  list.forEach((item) => {
    const btn = document.createElement('button');
    btn.className = 'button secondary';
    btn.style.marginBottom = '8px';
    btn.textContent = `${item.session_id} (${item.count}) ${formatTs(item.last_ts)}`;
    btn.addEventListener('click', () => loadSession(item.session_id));
    sessionsList.appendChild(btn);
  });
}

async function loadSession(sessionId) {
  const resp = await fetch(`/manager/session?session_id=${encodeURIComponent(sessionId)}`);
  const list = await resp.json();
  const lines = list.map((m) => `[${m.role}] ${m.content}`).join('\n');
  sessionDetail.value = lines;
}

fields.asr_active.addEventListener('change', async () => {
  updateAsrProfileFromForm();
  asrCurrentId = fields.asr_active.value;
  asrUseName = currentProfile(asrProfiles, asrCurrentId)?.name || '';
  bindAsrForm(currentProfile(asrProfiles, asrCurrentId));
  await persistConfig();
});
fields.tts_active.addEventListener('change', async () => {
  updateTtsProfileFromForm();
  ttsCurrentId = fields.tts_active.value;
  ttsUseName = currentProfile(ttsProfiles, ttsCurrentId)?.name || '';
  bindTtsForm(currentProfile(ttsProfiles, ttsCurrentId));
  await persistConfig();
});
fields.llm_active.addEventListener('change', async () => {
  updateLlmProfileFromForm();
  llmCurrentId = fields.llm_active.value;
  llmUseName = currentProfile(llmProfiles, llmCurrentId)?.name || '';
  bindLlmForm(currentProfile(llmProfiles, llmCurrentId));
  await persistConfig();
});

fields.asr_add.addEventListener('click', async () => {
  const name = prompt('请输入配置名');
  if (!name) return;
  const id = genId();
  asrProfiles.push({ id, name, use: 'tencent', tencent: { secret_id: '', secret_key: '' } });
  asrCurrentId = id;
  asrUseName = name;
  renderSelect(fields.asr_active, asrProfiles, asrCurrentId);
  bindAsrForm(currentProfile(asrProfiles, asrCurrentId));
  await persistConfig();
});

fields.asr_delete.addEventListener('click', async () => {
  const active = asrCurrentId;
  asrProfiles = asrProfiles.filter((p) => p.id !== active);
  if (asrProfiles.length === 0) {
    const id = genId();
    asrProfiles.push({ id, name: '默认', use: 'tencent', tencent: { secret_id: '', secret_key: '' } });
  }
  asrCurrentId = asrProfiles[0].id;
  asrUseName = asrProfiles[0].name;
  renderSelect(fields.asr_active, asrProfiles, asrCurrentId);
  bindAsrForm(currentProfile(asrProfiles, asrCurrentId));
  await persistConfig();
});

fields.tts_add.addEventListener('click', async () => {
  const name = prompt('请输入配置名');
  if (!name) return;
  const id = genId();
  ttsProfiles.push({ id, name, use: 'edge', azure: { region: '', api_key: '' } });
  ttsCurrentId = id;
  ttsUseName = name;
  renderSelect(fields.tts_active, ttsProfiles, ttsCurrentId);
  bindTtsForm(currentProfile(ttsProfiles, ttsCurrentId));
  await persistConfig();
});

fields.tts_delete.addEventListener('click', async () => {
  const active = ttsCurrentId;
  ttsProfiles = ttsProfiles.filter((p) => p.id !== active);
  if (ttsProfiles.length === 0) {
    const id = genId();
    ttsProfiles.push({ id, name: '默认', use: 'edge', azure: { region: '', api_key: '' } });
  }
  ttsCurrentId = ttsProfiles[0].id;
  ttsUseName = ttsProfiles[0].name;
  renderSelect(fields.tts_active, ttsProfiles, ttsCurrentId);
  bindTtsForm(currentProfile(ttsProfiles, ttsCurrentId));
  await persistConfig();
});

fields.llm_add.addEventListener('click', async () => {
  const name = prompt('请输入配置名');
  if (!name) return;
  const id = genId();
  llmProfiles.push({
    id,
    name,
    chat: { api_url: '', api_key: '', model: '' },
    think: { api_url: '', api_key: '', model: '' },
  });
  llmCurrentId = id;
  llmUseName = name;
  renderSelect(fields.llm_active, llmProfiles, llmCurrentId);
  bindLlmForm(currentProfile(llmProfiles, llmCurrentId));
  await persistConfig();
});

fields.llm_delete.addEventListener('click', async () => {
  const active = llmCurrentId;
  llmProfiles = llmProfiles.filter((p) => p.id !== active);
  if (llmProfiles.length === 0) {
    const id = genId();
    llmProfiles.push({
      id,
      name: '默认',
      chat: { api_url: '', api_key: '', model: '' },
      think: { api_url: '', api_key: '', model: '' },
    });
  }
  llmCurrentId = llmProfiles[0].id;
  llmUseName = llmProfiles[0].name;
  renderSelect(fields.llm_active, llmProfiles, llmCurrentId);
  bindLlmForm(currentProfile(llmProfiles, llmCurrentId));
  await persistConfig();
});

configRefresh.addEventListener('click', refreshConfig);
configSave.addEventListener('click', saveConfig);
summaryRefresh.addEventListener('click', refreshSummary);
summarySave.addEventListener('click', saveSummary);
sessionsRefresh.addEventListener('click', refreshSessions);

logUpload.addEventListener('change', async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const text = await file.text();
  const resp = await fetch('/manager/log/upload', {
    method: 'POST',
    headers: { 'content-type': 'text/plain' },
    body: text,
  });
  logStatus.textContent = resp.ok ? '日志上传成功' : '日志上传失败';
  logUpload.value = '';
  refreshSessions();
});

refreshConfig();
refreshSummary();
refreshSessions();
