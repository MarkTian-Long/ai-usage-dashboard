// dashboard-ui-contract-v1: one render path and one refresh lifecycle.
const q = selector => document.querySelector(selector);
const qa = selector => [...document.querySelectorAll(selector)];
const F = value => value >= 1e9 ? (value / 1e9).toFixed(2) + 'B'
  : value >= 1e6 ? (value / 1e6).toFixed(1) + 'M'
  : value >= 1e3 ? (value / 1e3).toFixed(1) + 'K' : Math.round(value);
const Sec = value => value == null ? '—' : value >= 60
  ? (value / 60).toFixed(value > 600 ? 0 : 1) + ' 分' : value.toFixed(1) + ' 秒';
const Bytes = value => value >= 1073741824 ? (value / 1073741824).toFixed(2) + ' GiB'
  : value >= 1048576 ? (value / 1048576).toFixed(1) + ' MiB' : value >= 1024 ? (value / 1024).toFixed(1) + ' KiB' : value + ' B';
const Esc = value => String(value).replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
}[char]));

let D = { usage: [], tasks: [], compactions: [] };
let U = [], ds = '', de = '', lastUpdated = '', loadBusy = false, refreshBusy = false;
let loadPromise = null, viewMemory = {}, prefsMemory = {};
const VIEW_KEY = 'codexDashboardView';
const PREF_KEY = 'codexPrefs';
const SKILL_SOURCES = { personal: '个人', workspace: '工作区', system: '系统', plugin: '插件', unknown: '未知' };
const DATE_PRESETS = ['today', 'days7', 'days30', 'month', 'all', 'custom'];
const USAGE_SCOPES = { task: '任务用量（含子代理）', auto_review: '自动安全审查', all: '全部 Token' };
let usageScopePreference = 'task';
const SKILL_PRESETS = DATE_PRESETS;
const SKILL_OBSERVATIONS = ['all', 'active', 'unobserved', 'currentUnread', 'notFound', 'ambiguous', 'single', 'unknown', 'duplicate'];
const SKILL_SORTS = ['reads', 'readsAsc', 'tasks', 'recent', 'name'];
const SKILL_CATEGORIES = [
  { id: 'product', label: '产品与规划', pattern: /^(pm-|product|prd)|产品|需求|规划/i },
  { id: 'analysis', label: '数据与分析', pattern: /data|analytics|数据|分析|kpi|metric|dashboard|spreadsheet|图表|报表|sql/i },
  { id: 'documents', label: '文档与交付', pattern: /document|docx|pdf|presentation|slides|文档|报告|演示|prd/i },
  { id: 'visual', label: '视觉与设计', pattern: /image|visual|design|frontend|图像|视觉|设计|原型/i },
  { id: 'engineering', label: '开发与工具', pattern: /api|code|skill|plugin|agent|开发|代码|工具|自动化/i }
];
const SKILL_WORKFLOWS = [
  { id: 'analysis', label: '数据分析', skills: ['plugin|data-analytics:analyze-data-quality', 'plugin|data-analytics:visualize-data', 'plugin|data-analytics:build-report'] },
  { id: 'delivery', label: '文档交付', skills: ['plugin|documents:documents', 'plugin|pdf:pdf'] },
  { id: 'prd', label: '产品需求讨论', skills: ['workspace|pm-advisory-board'] }
];
const BUNDLE_KEY = 'codexSkillBundlesV1';
let skillView = { preset: 'days30', start: '', end: '', search: '', source: 'all', scope: 'history', category: 'all', observation: 'all', sort: 'reads' };
let skillSelected = new Set(), skillBundles = [];
let skillBundleIndex = -1;
let skillTrendState = null;

// Storage may be disabled, stale, or corrupted. It must never block the dashboard.
function readStorage(kind, key, fallback = {}) {
  try {
    const parsed = JSON.parse(window[kind].getItem(key) || '{}');
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : fallback;
  } catch { return fallback; }
}
function writeStorage(kind, key, value) {
  try { window[kind].setItem(key, JSON.stringify(value)); return true; } catch { return false; }
}
function taskDate(task) { return task.startedDate || task.date; }
// dashboard-usage-scope-v1: classification is explicit; model names alone never define the view.
function hasUsageScopes(data = D) { return data.usageScopeSchema === 1; }
function usageScope(data = D) {
  const selected = q('#usageScope').value;
  return hasUsageScopes(data) && Object.prototype.hasOwnProperty.call(USAGE_SCOPES, selected) ? selected : 'all';
}
function scopeRows(rows, scope, data = D) {
  return !hasUsageScopes(data) || scope === 'all' ? rows : rows.filter(row => row.scope === scope);
}
function restoreUsageScope(saved) {
  usageScopePreference = Object.prototype.hasOwnProperty.call(USAGE_SCOPES, saved) ? saved : 'task';
  q('#usageScope').disabled = !hasUsageScopes();
  q('#usageScope').value = hasUsageScopes() ? usageScopePreference : 'all';
}
function dateBounds(data, scope = 'all') {
  const dates = [...scopeRows(data.usage, scope, data).map(row => row.date), ...scopeRows(data.tasks, scope, data).map(taskDate),
    ...scopeRows(data.compactions, scope, data).map(row => row.date)].filter(Boolean).sort();
  return { start: dates[0] || '', end: dates.at(-1) || '' };
}
function snapshotDay(data) {
  if (calendarDate(data.skills?.asOf)) return data.skills.asOf;
  const generated = typeof data.generated === 'string' ? data.generated.slice(0, 10) : '';
  if (calendarDate(generated)) return generated;
  return dateBounds(data).end || new Date(Date.now() + 8 * 3600000).toISOString().slice(0, 10);
}
// Both filter groups share calendar definitions while keeping their own default and state.
function presetDateRange(asOf, preset, firstDate, custom = {}) {
  if (preset === 'custom') return { start: custom.start, end: custom.end };
  let start = asOf;
  if (preset === 'month') start = asOf.slice(0, 7) + '-01';
  if (preset === 'all') start = firstDate || asOf;
  if (preset === 'days7' || preset === 'days30') {
    const day = new Date(asOf + 'T00:00:00Z'); day.setUTCDate(day.getUTCDate() - (preset === 'days7' ? 6 : 29)); start = day.toISOString().slice(0, 10);
  }
  return { start, end: asOf };
}
function usageDateRange(data, preset, custom, scope = 'all') { return presetDateRange(snapshotDay(data), preset, dateBounds(data, scope).start, custom); }
function defaultRange(data) { return usageDateRange(data, 'month'); }
function usageRangeError(data, start, end) {
  if (!calendarDate(start) || !calendarDate(end)) return '请选择完整、有效的开始和结束日期。';
  if (start > end) return '开始日期晚于结束日期，请调整筛选。';
  if (end > snapshotDay(data)) return '结束日期不能晚于快照截至日 ' + snapshotDay(data) + '。';
  return '';
}
function opts(id, field, keep = '') {
  const values = [...new Set(scopeRows([...D.usage, ...D.tasks, ...D.compactions], usageScope()).map(row => row[field]).filter(Boolean))].sort();
  const element = q(id);
  element.innerHTML = '<option value="">' + (field === 'model' ? '全部模型' : '全部推理强度') + '</option>' + values.map(value =>
    '<option value="' + Esc(value) + '">' + Esc(value) + '</option>').join('');
  element.value = values.includes(keep) ? keep : '';
}
function reconcileUsageDimensions(model, effort) {
  opts('#model', 'model', model); opts('#effort', 'effort', effort);
  const selectedModel = q('#model').value, selectedEffort = q('#effort').value;
  if (selectedModel && selectedEffort && !scopeRows([...D.usage, ...D.tasks, ...D.compactions], usageScope())
    .some(row => row.model === selectedModel && row.effort === selectedEffort)) q('#effort').value = '';
}
function filter(rows, getDate = row => row.date) {
  const start = q('#start').value || ds, end = q('#end').value || de;
  const model = q('#model').value, effort = q('#effort').value;
  return scopeRows(rows, usageScope()).filter(row => (!start || getDate(row) >= start) && (!end || getDate(row) <= end)
    && (!model || row.model === model) && (!effort || row.effort === effort));
}
function Q(values, percentile) {
  if (!values.length) return null;
  return [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) * percentile)];
}
function samples(tasks, field) {
  return tasks.map(task => task[field])
    .filter(value => typeof value === 'number' && Number.isFinite(value) && value >= 0);
}
function totals(rows) {
  const result = { total: 0, input: 0, cached: 0, fresh: 0, output: 0 };
  rows.forEach(row => Object.keys(result).forEach(key => result[key] += Number(row[key]) || 0));
  result.days = new Set(rows.map(row => row.date)).size;
  result.sessions = new Set(rows.map(row => row.session)).size;
  return result;
}
function daily(rows, getValue, getDate = row => row.date) {
  const days = new Map();
  rows.forEach(row => {
    const date = getDate(row);
    if (date) days.set(date, (days.get(date) || 0) + (Number(getValue(row)) || 0));
  });
  return [...days].sort(([a], [b]) => a.localeCompare(b));
}
function calendarTrend(points, start, end) {
  if (!calendarDate(start) || !calendarDate(end) || start > end) {
    start = points[0]?.[0] || ''; end = points.at(-1)?.[0] || '';
  }
  if (!start || !end) return { start, end, span: 0, sparse: false, points: [] };
  const first = Date.parse(start + 'T00:00:00Z'), span = Math.round((Date.parse(end + 'T00:00:00Z') - first) / 86400000) + 1;
  const values = new Map(points.filter(([date]) => date >= start && date <= end)), sparse = span > 366;
  const trend = [];
  if (sparse) {
    for (const [date, value] of values) trend.push({ date, value, observed: true });
  } else {
    for (let offset = 0; offset < span; offset++) {
      const date = new Date(first + offset * 86400000).toISOString().slice(0, 10);
      trend.push({ date, value: values.get(date) || 0, observed: values.has(date) });
    }
  }
  return { start, end, span, sparse, points: trend };
}
function chart(rows, id, getValue, getDate, noteId) {
  const points = daily(rows, getValue, getDate);
  const max = Math.max(1, ...points.map(([, value]) => value));
  const trend = calendarTrend(points, q('#start').value || ds, q('#end').value || de);
  const firstDay = Date.parse(trend.start + 'T00:00:00Z'), element = q(id);
  element.classList.add('usage-calendar');
  element.classList.toggle('usage-sparse', trend.sparse); element.classList.toggle('usage-dense', trend.span > 60);
  element.innerHTML = trend.points.map(({ date, value, observed }) => {
    const offset = Math.round((Date.parse(date + 'T00:00:00Z') - firstDay) / 86400000);
    const position = trend.sparse ? ' style="left:' + (100 * offset / trend.span) + '%;width:' + (100 / trend.span) + '%"' : '';
    const unit = id === '#taskTrend' ? '次请求' : 'Token';
    const label = date + ' · ' + (observed ? F(value) + ' ' + unit + (value === 0 ? '（有记录）' : '') : '无可观测记录');
    const edge = offset / trend.span < .1 ? ' usage-label-left' : offset / trend.span > .85 ? ' usage-label-right' : '';
    return '<div class="barcol usage-day' + (observed ? value === 0 ? ' usage-day-zero' : '' : ' usage-day-missing') + edge
      + '" data-date="' + date + '" data-observed="' + observed + '" tabindex="0" role="img" aria-label="' + Esc(label)
      + '" data-tip="' + Esc(label) + '" title="' + Esc(label) + '"' + position + '><i style="height:' + (100 * value / max) + '%"></i></div>';
  }).join('') || '<span class="hint">当前筛选没有可观测记录</span>';
  if (noteId) q(noteId).textContent = (trend.sparse ? '跨度超过一年，柱按实际日期位置展示。' : '按筛选日历日期展示。')
    + '空白或虚线表示无可观测记录，不等于实际用量为零；有记录的零值以实线标记。'
    + (points.length ? '' : '当前筛选没有可观测记录。');
  return [trend.start, trend.end];
}
function bars(rows, id) {
  q(id).innerHTML = rows.map(row => '<div class="row"><span>' + Esc(row.name)
    + '</span><div class="rail"><div class="fill" style="width:' + Math.min(100, Math.max(0, row.share)).toFixed(1)
    + '%"></div></div><span>' + Esc(row.label || row.share.toFixed(1) + '%') + '</span></div>').join('')
    || '<span class="hint">暂无数据</span>';
}
function groups(rows, field) {
  const grouped = new Map();
  rows.forEach(row => {
    const key = row[field] || 'unknown';
    grouped.set(key, (grouped.get(key) || 0) + (Number(row.total) || 0));
  });
  const sum = [...grouped.values()].reduce((a, b) => a + b, 0) || 1;
  return [...grouped].sort((a, b) => b[1] - a[1]).map(([name, total]) => ({ name, total, share: 100 * total / sum }));
}
function cards(id, items) {
  q(id).innerHTML = items.map(([label, value, hint]) => '<article class="card"><div class="label">'
    + Esc(label) + '</div><div class="value">' + Esc(value) + '</div><div class="hint">'
    + Esc(hint) + '</div></article>').join('');
}
function axis(first, last, dates) {
  q(first).textContent = dates[0] || '—';
  q(last).textContent = dates.at(-1) || '—';
}
function renderTokens(usage, tasks) {
  const sum = totals(usage), days = daily(usage, row => row.total);
  const peak = Math.max(0, ...days.map(([, value]) => value));
  const peakDate = days.find(([, value]) => value === peak)?.[0] || '—';
  cards('#tokenCards', [
    ['筛选 Total', F(sum.total), '累计'], ['活跃日', sum.days, '有 Token 的日期'],
    ['活跃日日均', F(sum.days ? sum.total / sum.days : 0), 'Token'],
    ['单日峰值', F(peak), peakDate], ['会话数', sum.sessions, hasUsageScopes() ? '按实际线程 ID 去重' : '按旧快照会话 ID 去重'],
    ['对话轮数', tasks.length, '按轮次去重']
  ]);
  const key = q('#metric').value;
  q('#tokenTitle').textContent = '每日 ' + q('#metric').selectedOptions[0].textContent;
  axis('#first', '#last', chart(usage, '#tokenTrend', row => row[key], undefined, '#tokenTrendNote'));
  const percent = value => sum.total ? 100 * value / sum.total : 0;
  const reasoning = usage.reduce((total, row) => total + (Number(row.reasoning) || 0), 0);
  const reasoningShare = sum.output ? 100 * reasoning / sum.output : 0;
  bars([
    { name: 'Cache', share: percent(sum.cached) }, { name: 'Fresh', share: percent(sum.fresh) },
    { name: 'Output', share: percent(sum.output) },
    { name: 'Reasoning', share: reasoningShare, label: 'Output 内 ' + reasoningShare.toFixed(1) + '%' }
  ], '#mix');
  q('#mix').innerHTML += '<div class="mix-note">Reasoning 为 Output 子集，不重复计入 Total。</div>';
  bars(groups(usage, 'model'), '#models');
  bars(groups(usage, 'effort'), '#efforts');
}
function renderEfficiency(tasks, compactions) {
  const done = tasks.filter(task => task.completed), good = done.filter(task => !task.error);
  const bad = done.filter(task => task.error), open = tasks.filter(task => task.started && !task.completed);
  const durations = samples(good, 'duration'), firstTokens = samples(good, 'ttfb');
  cards('#effCards', [
    ['去重请求', tasks.length, hasUsageScopes() ? '实际线程 + Turn 合并' : '旧快照会话 + Turn 合并'], ['已完成', done.length, '完成事件'],
    ['首响 P50', Sec(Q(firstTokens, .5)), 'P90 ' + Sec(Q(firstTokens, .9)) + ' · 样本 ' + firstTokens.length],
    ['完成时长 P50', Sec(Q(durations, .5)), 'P90 ' + Sec(Q(durations, .9)) + ' · 样本 ' + durations.length],
    ['压缩率', tasks.length ? (100 * compactions.length / tasks.length).toFixed(1) + '%' : '—', '每百请求'],
    ['未完成请求', open.length, '仅开始、未见完成事件']
  ]);
  q('#status').innerHTML = [['成功完成', good.length], ['完成但报错', bad.length], ['仅开始未完成', open.length]]
    .map(([name, count]) => '<div class="status"><div class="label">' + name + '</div><strong>' + count + '</strong></div>').join('');
  const buckets = [
    ['<10秒', 0, 10], ['10–30秒', 10, 30], ['30–120秒', 30, 120],
    ['2–10分', 120, 600], ['10–30分', 600, 1800], ['≥30分', 1800, Infinity]
  ].map(([name, min, max]) => ({ name, count: durations.filter(value => value >= min && value < max).length }));
  const max = Math.max(1, ...buckets.map(bucket => bucket.count));
  q('#dist').innerHTML = buckets.map(bucket => '<div class="bucket"><div class="bucket-bar"><i style="height:'
    + (100 * bucket.count / max) + '%" title="' + Esc(bucket.name) + ' · ' + bucket.count
    + ' 请求"></i></div><span>' + Esc(bucket.name) + '</span></div>').join('');
  q('#durationSamples').textContent = '有效完成时长样本 ' + durations.length + ' / 成功完成 ' + good.length + '；缺失时长不计为零。';
  q('#compaction').innerHTML = '<div class="value">' + compactions.length
    + '</div><div class="hint">去重后的压缩信号；不同事件类型不直接相加。</div>';
  // Tasks are deduplicated by the generator. Every task counts, including open/error tasks.
  axis('#taskFirst', '#taskLast', chart(tasks, '#taskTrend', () => 1, taskDate, '#taskTrendNote'));
}
function renderLegacySkills() {
  const skills = D.skills;
  q('#skillRows').innerHTML = '';
  q('#skillSummary').textContent = '';
  q('#skillTable').classList.toggle('hidden', !skills?.rows.length);
  q('#skillEmpty').classList.toggle('hidden', Boolean(skills?.rows.length));
  if (!skills) {
    q('#skillRange').textContent = '当前快照尚未包含 Skill 统计。';
    q('#skillEmpty').textContent = '此快照未提供 Skill 说明读取数据，不能按零次解读。点击“立即刷新”生成新版统计。';
    return;
  }
  const { days7, days30 } = skills.windows;
  q('#skillTableHead').innerHTML = '<tr><th scope="col" rowspan="2">Skill</th><th scope="col" rowspan="2">来源</th><th scope="colgroup" colspan="2">近 7 天</th><th scope="colgroup" colspan="2">近 30 天</th></tr>'
    + '<tr><th scope="col">读取轮次</th><th scope="col">涉及任务（会话）</th><th scope="col">读取轮次</th><th scope="col">涉及任务（会话）</th></tr>';
  q('#skillRange').textContent = '快照截至 ' + skills.asOf + '（Asia/Shanghai） · 近 7 天：'
    + days7.start + ' 至 ' + days7.end + ' · 近 30 天：' + days30.start + ' 至 ' + days30.end
    + '。均含首尾日期，不受 Token 筛选影响。';
  q('#skillEmpty').textContent = '近 30 天没有可识别的 Skill 说明读取记录；不代表未使用 Skill。';
  q('#skillSummary').textContent = '共 ' + skills.rows.length + ' 个 Skill · 按近 30 天读取轮次排序';
  const countCell = (value, label) => '<td class="skill-count" data-label="' + label + '">' + Esc(value) + '</td>';
  const metadata = skillMetadataMap(skills);
  q('#skillRows').innerHTML = [...skills.rows].sort((a, b) => b.readTurns30 - a.readTurns30
    || b.readTurns7 - a.readTurns7 || a.skill.localeCompare(b.skill) || a.source.localeCompare(b.source))
    .map(row => '<tr><th scope="row" class="skill-name">' + skillNameMarkup({ ...row, ...currentSkillMetadata(metadata.get(skillKey(row))) }) + '</th><td class="skill-origin"><span class="skill-source skill-source-'
      + row.source + '">' + SKILL_SOURCES[row.source] + '</span></td>'
      + countCell(row.readTurns7, '近 7 天 · 读取轮次') + countCell(row.tasks7, '近 7 天 · 涉及任务（会话）')
      + countCell(row.readTurns30, '近 30 天 · 读取轮次') + countCell(row.tasks30, '近 30 天 · 涉及任务（会话）') + '</tr>').join('');
}
function hasSkillActivity(skills = D.skills) { return skills?.activitySchema === 1 && Array.isArray(skills.activity); }
function hasSkillMetadata(skills = D.skills) { return skills?.metadataSchema === 1 && Array.isArray(skills.metadata); }
function hasSkillInventory(skills = D.skills) { return skills?.inventorySchema === 1 && Array.isArray(skills.inventory); }
function skillMetadataMap(skills) { return new Map((hasSkillMetadata(skills) ? skills.metadata : []).map(row => [skillKey(row), row])); }
function skillInventoryMap(skills) { return new Map((hasSkillInventory(skills) ? skills.inventory : []).map(row => [skillKey(row), row])); }
function skillCategory(row) {
  const identity = row.skill.split(':').at(-1);
  return SKILL_CATEGORIES.find(category => category.pattern.test(identity))?.id
    || SKILL_CATEGORIES.find(category => category.pattern.test([row.currentName, row.currentDescriptionZh, row.currentDescription].join(' ')))?.id || 'other';
}
function currentSkillMetadata(metadata) {
  const description = metadata?.description || '', key = metadata ? metadata.source + '|' + metadata.skill : '';
  const dictionary = typeof SKILL_DESCRIPTION_ZH === 'object' && SKILL_DESCRIPTION_ZH !== null ? SKILL_DESCRIPTION_ZH : {};
  const entry = Object.prototype.hasOwnProperty.call(dictionary, key) ? dictionary[key] : null;
  const translated = metadata?.status === 'available' && description && entry?.original === description && typeof entry.zh === 'string' ? entry.zh : '';
  return { metadataStatus: metadata?.status || 'unavailable', currentName: metadata?.name || '', currentDescription: description, currentDescriptionZh: translated };
}
function skillNameMarkup(row) {
  let result = '<div class="skill-identity">' + Esc(row.skill) + '</div>';
  if (row.currentName && row.currentName !== row.skill) result += '<div class="skill-display-name">' + Esc(row.currentName) + '</div>';
  if (row.currentDescription) {
    const translated = row.currentDescriptionZh || '', letters = Array.from(translated || row.currentDescription), preview = letters.slice(0, 110).join('') + (letters.length > 110 ? '…' : '');
    result += '<details class="skill-description"><summary><span class="skill-description-preview">' + Esc(preview)
      + '</span><span class="skill-description-action skill-description-expand">' + (translated ? '展开中英对照' : '展开完整简介') + '</span><span class="skill-description-collapse">收起简介</span></summary>'
      + (translated ? '<div class="skill-description-language">中文释义</div><p class="skill-description-zh">' + Esc(translated) + '</p><div class="skill-description-language">英文原文</div>' : '')
      + '<p class="skill-description-full">' + Esc(row.currentDescription) + '</p>'
      + (translated ? '<p class="note skill-description-provenance">中文为本地释义，不是 Skill 源文件内容。</p>' : '') + '</details>';
  } else {
    const messages = { available: '当前没有可展示的简介。', missing: '当前未取得可用的本地说明。', ambiguous: '存在多份本地说明，简介待确认。', unavailable: '此快照暂无本地简介，可刷新获取。' };
    result += '<p class="skill-description-missing">' + messages[row.metadataStatus] + '</p>';
  }
  return result;
}
function skillKey(row) { return row.source + '\u0000' + row.skill; }
function calendarDate(value) {
  if (!validDate(value)) return false;
  const time = Date.parse(value + 'T00:00:00Z');
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value;
}
function skillDateRange(skills, view) {
  if (!skills || view.preset === 'custom') return { start: view.start, end: view.end };
  const first = (skills.activity || []).reduce((date, row) => row.date < date ? row.date : date, skills.asOf);
  return presetDateRange(skills.asOf, view.preset, first, view);
}
function restoreSkillView(saved = {}) {
  if (!saved || typeof saved !== 'object' || Array.isArray(saved)) saved = {};
  skillView = {
    preset: SKILL_PRESETS.includes(saved.preset) ? saved.preset : 'days30',
    start: typeof saved.start === 'string' ? saved.start : '', end: typeof saved.end === 'string' ? saved.end : '',
    search: typeof saved.search === 'string' ? saved.search.slice(0, 160) : '',
    source: saved.source === 'all' || Object.prototype.hasOwnProperty.call(SKILL_SOURCES, saved.source) ? saved.source : 'all',
    scope: ['history', 'inventory', 'combined'].includes(saved.scope) ? saved.scope : 'history',
    category: saved.category === 'all' || saved.category === 'other' || SKILL_CATEGORIES.some(row => row.id === saved.category) ? saved.category : 'all',
    observation: SKILL_OBSERVATIONS.includes(saved.observation) ? saved.observation : 'all',
    sort: SKILL_SORTS.includes(saved.sort) ? saved.sort : 'reads'
  };
  Object.assign(skillView, skillDateRange(D.skills, skillView));
  for (const key of ['preset', 'start', 'end', 'search', 'source', 'scope', 'category', 'observation', 'sort']) {
    q('#skill' + key[0].toUpperCase() + key.slice(1)).value = skillView[key];
  }
  q('#skillStart').max = q('#skillEnd').max = D.skills?.asOf || '';
}
function changeSkillFilters(dateChanged = false) {
  if (dateChanged) q('#skillPreset').value = 'custom';
  const saved = {};
  for (const key of ['preset', 'start', 'end', 'search', 'source', 'scope', 'category', 'observation', 'sort']) {
    saved[key] = q('#skill' + key[0].toUpperCase() + key.slice(1)).value;
  }
  // Keep incomplete custom dates visible so the user can finish editing them.
  skillView = saved;
  if (skillView.preset !== 'custom') {
    Object.assign(skillView, skillDateRange(D.skills, skillView));
    q('#skillStart').value = skillView.start; q('#skillEnd').value = skillView.end;
  }
  q('#skillExportState').textContent = '';
  saveView(); renderSkills();
}
function resetSkillFilters() { restoreSkillView(); q('#skillExportState').textContent = ''; saveView(); renderSkills(); }
function skillRangeError(skills, filters) {
  if (!calendarDate(filters.start) || !calendarDate(filters.end)) return '请选择完整、有效的开始和结束日期。';
  if (filters.start > filters.end) return '开始日期晚于结束日期，请调整 Skill 筛选。';
  if (filters.end > skills.asOf) return '结束日期不能晚于快照截至日 ' + skills.asOf + '。';
  return '';
}
// The same report supplies every view and the download. Raw aliases stay inside this function.
function buildSkillReport(skills, filters) {
  filters = { scope: 'history', category: 'all', ...filters };
  const error = skillRangeError(skills, filters);
  if (error) throw Error(error);
  const catalog = new Map(), names = new Map();
  for (const event of skills.activity) {
    if (event.date > filters.end) continue;
    const key = skillKey(event);
    if (!catalog.has(key)) catalog.set(key, { skill: event.skill, source: event.source, lastObservedDate: event.date, turns: new Set(), tasks: new Set() });
    const row = catalog.get(key);
    if (event.date > row.lastObservedDate) row.lastObservedDate = event.date;
    if (event.date >= filters.start && event.date <= filters.end) { row.turns.add(event.turn); row.tasks.add(event.task); }
    const basename = event.skill.split(':').at(-1).toLowerCase();
    if (!names.has(basename)) names.set(basename, new Set());
    names.get(basename).add(key);
  }
  const query = filters.search.trim().toLowerCase(), rows = [], metadata = skillMetadataMap(skills), inventory = skillInventoryMap(skills);
  if (filters.scope !== 'history' && hasSkillInventory(skills)) {
    for (const entry of skills.inventory) {
      const key = skillKey(entry);
      if (!catalog.has(key)) catalog.set(key, { skill: entry.skill, source: entry.source, lastObservedDate: null, turns: new Set(), tasks: new Set() });
      const basename = entry.skill.split(':').at(-1).toLowerCase();
      if (!names.has(basename)) names.set(basename, new Set());
      names.get(basename).add(key);
    }
  }
  for (const row of catalog.values()) {
    const entry = inventory.get(skillKey(row));
    if (filters.scope === 'inventory' && !entry) continue;
    const readTurns = row.turns.size, mainTasks = row.tasks.size;
    const duplicate = names.get(row.skill.split(':').at(-1).toLowerCase()).size > 1;
    const current = currentSkillMetadata(entry || metadata.get(skillKey(row)));
    const directoryState = hasSkillInventory(skills) ? entry ? 'current' : 'not_found' : 'unknown';
    const category = skillCategory({ ...row, ...current });
    const matches = { all: true, active: readTurns > 0, unobserved: Boolean(row.lastObservedDate) && readTurns === 0, single: readTurns === 1, unknown: row.source === 'unknown', duplicate,
      currentUnread: directoryState === 'current' && readTurns === 0, notFound: directoryState === 'not_found', ambiguous: entry?.status === 'ambiguous' || (entry?.copies || 0) > 1 };
    if (query && ![row.skill, current.currentName, current.currentDescription, current.currentDescriptionZh].join('\n').toLowerCase().includes(query)
      || filters.source !== 'all' && row.source !== filters.source || filters.category !== 'all' && filters.category !== category || !matches[filters.observation]) continue;
    const observations = [!row.lastObservedDate ? '截至所选日未观测到读取' : readTurns === 0 ? '本期未观测' : readTurns === 1 ? '本期仅 1 轮' : '本期有读取'];
    if (row.source === 'unknown') observations.push('来源待确认');
    if (duplicate) observations.push('同名多处 · 待复核');
    if (entry?.copies > 1) observations.push('当前定义 ' + entry.copies + ' 份 · 待复核');
    if (entry?.status === 'ambiguous') observations.push('说明冲突 · 待复核');
    rows.push({ skill: row.skill, source: row.source, readTurns, mainTasks, lastObservedDate: row.lastObservedDate, observations, directoryState, category, copies: entry?.copies || 0, ...current });
  }
  const byName = (a, b) => a.skill.localeCompare(b.skill) || a.source.localeCompare(b.source);
  const sorts = {
    reads: (a, b) => b.readTurns - a.readTurns || byName(a, b), readsAsc: (a, b) => a.readTurns - b.readTurns || byName(a, b),
    tasks: (a, b) => b.mainTasks - a.mainTasks || b.readTurns - a.readTurns || byName(a, b),
    recent: (a, b) => (b.lastObservedDate || '').localeCompare(a.lastObservedDate || '') || byName(a, b), name: byName
  };
  rows.sort(sorts[filters.sort] || byName);
  const selected = new Set(rows.map(skillKey)), turns = new Set(), tasks = new Set(), dailyTurns = new Map();
  for (const event of skills.activity) {
    if (!selected.has(skillKey(event)) || event.date < filters.start || event.date > filters.end) continue;
    turns.add(event.turn); tasks.add(event.task);
    if (!dailyTurns.has(event.date)) dailyTurns.set(event.date, new Set());
    dailyTurns.get(event.date).add(event.turn);
  }
  const activeSkills = rows.filter(row => row.readTurns > 0).length;
  const sources = Object.keys(SKILL_SOURCES).map(source => ({ source, activeSkills: rows.filter(row => row.source === source && row.readTurns > 0).length }))
    .filter(row => row.activeSkills).sort((a, b) => b.activeSkills - a.activeSkills || a.source.localeCompare(b.source));
  const span = Math.round((Date.parse(filters.end + 'T00:00:00Z') - Date.parse(filters.start + 'T00:00:00Z')) / 86400000) + 1;
  const trendMode = span <= 366 ? 'daily' : 'sparse_calendar';
  const trend = [];
  if (trendMode === 'daily') {
    const day = new Date(filters.start + 'T00:00:00Z');
    for (let index = 0; index < span; index++) {
      const date = day.toISOString().slice(0, 10); trend.push({ date, readTurns: dailyTurns.get(date)?.size || 0 }); day.setUTCDate(day.getUTCDate() + 1);
    }
  } else {
    for (const [date, values] of [...dailyTurns].sort(([a], [b]) => a.localeCompare(b))) trend.push({ date, readTurns: values.size });
  }
  return {
    filters: { ...filters }, catalogSkills: catalog.size,
    summary: { activeSkills, readTurns: turns.size, mainTasks: tasks.size, skillTurnRecords: rows.reduce((sum, row) => sum + row.readTurns, 0) },
    trendMode, trend,
    sources, rows
  };
}
function skillCountScale(maximum) {
  const target = Math.max(1, maximum / 4), power = 10 ** Math.floor(Math.log10(target));
  const step = [1, 2, 5, 10].map(value => value * power).find(value => value >= target);
  const top = Math.max(step, Math.ceil(maximum / step) * step), ticks = [];
  for (let value = top; value >= 0; value -= step) ticks.push(value);
  return { top, ticks };
}
function selectSkillDay(date) {
  if (!skillTrendState) return;
  if (!calendarDate(date) || date < skillTrendState.start || date > skillTrendState.end) date = skillTrendState.date;
  skillTrendState.date = date;
  const count = skillTrendState.counts.get(date) || 0;
  q('#skillTrendReadout').textContent = date + ' · ' + count + ' 轮' + (count === 0 ? '（无可观测读取）' : '（当前筛选，跨 Skill 去重）');
  q('#skillInspectDate').value = date;
  q('#skillDayPrev').disabled = date === skillTrendState.start; q('#skillDayNext').disabled = date === skillTrendState.end;
  qa('#skillTrend .skill-day').forEach(button => button.setAttribute('aria-pressed', button.dataset.date === date));
}
function skillDayOffset(offset) {
  const first = Date.parse(skillTrendState.start + 'T00:00:00Z'), last = Date.parse(skillTrendState.end + 'T00:00:00Z');
  return new Date(Math.min(last, Math.max(first, first + offset * 86400000))).toISOString().slice(0, 10);
}
function stepSkillDay(delta) {
  if (!skillTrendState) return;
  const offset = Math.round((Date.parse(skillTrendState.date + 'T00:00:00Z') - Date.parse(skillTrendState.start + 'T00:00:00Z')) / 86400000);
  selectSkillDay(skillDayOffset(offset + delta));
}
function inspectSkillPoint(event) {
  if (!skillTrendState) return;
  const button = event.target.closest?.('.skill-day');
  if (button) { selectSkillDay(button.dataset.date); return; }
  if (!Number.isFinite(event.clientX)) return;
  const box = q('#skillTrend').getBoundingClientRect();
  if (!box.width) return;
  const span = Math.round((Date.parse(skillTrendState.end + 'T00:00:00Z') - Date.parse(skillTrendState.start + 'T00:00:00Z')) / 86400000) + 1;
  selectSkillDay(skillDayOffset(Math.floor(Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)) * span)));
}
function renderSkillTrend(report) {
  const sparse = report.trendMode === 'sparse_calendar', firstDay = Date.parse(report.filters.start + 'T00:00:00Z');
  const span = Math.round((Date.parse(report.filters.end + 'T00:00:00Z') - firstDay) / 86400000) + 1;
  const scale = skillCountScale(Math.max(0, ...report.trend.map(row => row.readTurns)));
  const oldDay = skillTrendState?.date;
  skillTrendState = { start: report.filters.start, end: report.filters.end, date: oldDay && oldDay >= report.filters.start && oldDay <= report.filters.end ? oldDay : report.filters.end,
    counts: new Map(report.trend.map(row => [row.date, row.readTurns])) };
  q('#skillYAxis').innerHTML = scale.ticks.map(value => '<span class="skill-y-tick" style="bottom:' + (100 * value / scale.top) + '%">' + value + '</span>').join('');
  q('#skillGrid').innerHTML = scale.ticks.map(value => '<span class="skill-grid-line" style="bottom:' + (100 * value / scale.top) + '%"></span>').join('');
  q('#skillTrend').classList.toggle('skill-sparse', sparse);
  q('#skillTrend').classList.toggle('skill-dense', report.trend.length > 60);
  q('#skillTrend').classList.toggle('skill-labels-sparse', sparse || report.trend.length > 31);
  q('#skillTrend').innerHTML = report.trend.map(row => {
    const offset = Math.round((Date.parse(row.date + 'T00:00:00Z') - firstDay) / 86400000);
    const position = sparse ? ' style="left:' + (100 * offset / span) + '%;width:' + (100 / span) + '%"' : '';
    const edge = span > 1 && offset / span < .1 ? ' skill-label-left' : span > 1 && offset / span > .85 ? ' skill-label-right' : '';
    const height = 100 * row.readTurns / scale.top;
    return '<button type="button" class="barcol skill-day' + (sparse ? ' skill-sparse-day' : '') + edge + '" data-date="' + row.date + '" data-reads="' + row.readTurns
      + '" aria-label="' + row.date + ' · ' + row.readTurns + ' 轮" aria-pressed="false"' + position
      + '><i aria-hidden="true" style="height:' + height + '%"></i><span class="skill-bar-value" aria-hidden="true" style="bottom:calc(' + height + '% + 6px)">' + row.readTurns + '</span></button>';
  }).join('') || '<span class="hint">当前范围无可观测读取</span>';
  axis('#skillFirst', '#skillLast', [report.filters.start, report.filters.end]);
  q('#skillInspectDate').min = report.filters.start; q('#skillInspectDate').max = report.filters.end;
  selectSkillDay(skillTrendState.date);
  q('#skillTrendNote').textContent = (sparse ? '跨度超过一年，柱按实际日期位置展示。' : '按日历日期展示，空白天表示无可观测读取。')
    + '每天跨 Skill 去重；同轮跨日每天各计，总览按整个区间再去重。';
}
function renderSkills() {
  const available = hasSkillActivity();
  qa('#skillPreset,#skillStart,#skillEnd,#skillSearch,#skillSource,#skillScope,#skillCategory,#skillObservation,#skillSort,#skillReset').forEach(element => { element.disabled = !available; });
  q('#skillScope').disabled = !available || !hasSkillInventory();
  if (!hasSkillInventory() && skillView.scope !== 'history') { skillView.scope = 'history'; q('#skillScope').value = 'history'; }
  if (!hasSkillInventory() && ['currentUnread', 'notFound', 'ambiguous'].includes(skillView.observation)) { skillView.observation = 'all'; q('#skillObservation').value = 'all'; }
  q('#skillCards').classList.toggle('hidden', !available); q('#skillCharts').classList.toggle('hidden', !available);
  q('#skillExport').disabled = !available;
  q('#skillLegacyNotice').classList.toggle('hidden', available || !D.skills);
  q('#skillLegacyNotice').textContent = '当前快照仅支持近 7 / 30 天对照，缺少完整历史活动。请立即刷新以使用筛选、去重总览和审计导出；不能把各 Skill 的任务数相加作为总体任务数。';
  q('#skillMetadataNote').textContent = hasSkillInventory()
    ? '当前目录扫描截至 ' + D.skills.inventoryAsOf + '（Asia/Shanghai）；仅覆盖已知本地目录，不证明 Skill 已启用或是安装全集。历史读取截止 ' + D.skills.asOf + '，两种日期独立；目录扫描不增加读取计数。历史中未找到当前文件，不表示已卸载。用途分类为按标识和简介匹配的候选。'
    : hasSkillMetadata()
    ? '简介来自当前本地说明（' + D.skills.metadataAsOf + '），不是历史版本，不改变历史读取计数。匹配的英文简介默认显示本地中文释义，展开可对照原文；无匹配时显示原文。中文释义不是 Skill 源文件内容。'
    : '当前快照暂无本地简介，可立即刷新获取；历史读取统计仍按原口径展示。';
  if (!available) { q('#skillFilterMessage').textContent = '新版历史活动尚不可用，筛选与导出已停用。'; renderLegacySkills(); renderSkillComposer(); return; }
  q('#skillRange').textContent = '快照截至 ' + D.skills.asOf + '（Asia/Shanghai） · 当前范围：' + (skillView.start || '—') + ' 至 ' + (skillView.end || '—') + '（含首尾） · 不受 Token 筛选影响。';
  const error = skillRangeError(D.skills, skillView);
  q('#skillFilterMessage').textContent = error || (hasSkillInventory() ? '默认近 30 天；重置筛选恢复全部来源、全部观察项。卡片、图表和清单均跟随当前 Skill 筛选，与 Token / 请求独立。' : '此快照没有当前目录数据；可继续查看历史读取，刷新后使用目录范围与相关观察项。');
  if (error) {
    q('#skillExport').disabled = true; q('#skillCards').classList.add('hidden'); q('#skillCharts').classList.add('hidden');
    q('#skillTable').classList.add('hidden'); q('#skillRows').innerHTML = ''; q('#skillEmpty').classList.remove('hidden'); q('#skillEmpty').textContent = error; renderSkillComposer(); return;
  }
  const report = buildSkillReport(D.skills, skillView), sum = report.summary;
  cards('#skillCards', [
    ['本期有记录 Skill', sum.activeSkills, '当前筛选内'], ['包含读取的轮次', sum.readTurns, '跨 Skill 去重'],
    ['涉及主任务（会话）', sum.mainTasks, '跨 Skill 去重'], ['Skill × 轮次', sum.skillTurnRecords, '每项 Skill 分别计']
  ]);
  renderSkillTrend(report);
  bars(report.sources.map(row => ({ name: SKILL_SOURCES[row.source], share: 100 * row.activeSkills / (sum.activeSkills || 1), label: row.activeSkills + ' 项' })), '#skillSources');
  q('#skillTableHead').innerHTML = '<tr><th scope="col">Skill</th><th scope="col">来源</th><th scope="col">当前目录</th><th scope="col">用途候选</th><th scope="col">本期读取轮次</th><th scope="col">主任务（会话）</th><th scope="col">最近观测日期</th><th scope="col">观察提示</th></tr>';
  q('#skillSummary').textContent = '显示 ' + report.rows.length + ' 项 · 本期有读取 ' + sum.activeSkills + ' 项 · 非完整安装清单；历史截至所选结束日';
  q('#skillTable').classList.toggle('hidden', !report.rows.length); q('#skillEmpty').classList.toggle('hidden', Boolean(report.rows.length));
  q('#skillEmpty').textContent = D.skills.activity.length ? '当前筛选没有匹配的 Skill。可选择全部来源、全部观察项，或重置 Skill 筛选。' : '没有可识别的 Skill 说明读取历史；不代表未使用 Skill，也无法判断已安装清单。';
  q('#skillRows').innerHTML = report.rows.map(row => '<tr><th scope="row" class="skill-name">' + skillNameMarkup(row)
    + '</th><td class="skill-origin"><span class="skill-source skill-source-' + row.source + '">' + SKILL_SOURCES[row.source]
    + '</span></td><td class="skill-directory">' + ({ current: '已发现', not_found: '本次未发现', unknown: '未扫描' })[row.directoryState] + '</td><td class="skill-category">' + Esc(SKILL_CATEGORIES.find(item => item.id === row.category)?.label || '其他 / 待分类')
    + '</td><td class="skill-count" data-label="本期读取轮次">' + row.readTurns + '</td><td class="skill-count" data-label="主任务（会话）">' + row.mainTasks
    + '</td><td class="skill-date">' + Esc(row.lastObservedDate || '—') + '</td><td class="skill-observations">' + row.observations.map(Esc).join('<br>') + '</td></tr>').join('');
  renderSkillComposer();
}
function availableSkillChoices() {
  if (!hasSkillInventory()) return [];
  return D.skills.inventory.filter(row => row.status === 'available' && row.copies === 1);
}
function selectedSkillRows() {
  const available = new Map(availableSkillChoices().map(row => [skillKey(row), row]));
  return [...skillSelected].map(key => available.get(key));
}
function updateSkillPromptState() {
  const chosen = selectedSkillRows(), task = q('#skillTask').value.trim();
  const valid = hasSkillInventory() && chosen.length > 0 && chosen.every(Boolean) && Boolean(task);
  q('#skillCopyPrompt').disabled = !valid;
  q('#skillBundleSave').disabled = !hasSkillInventory() || !chosen.length || chosen.some(row => !row);
  q('#skillPromptPreview').value = valid ? skillPromptDraft() : '';
  if (skillSelected.size && chosen.some(row => !row)) q('#skillComposerState').textContent = '组合中有当前未找到或说明冲突的 Skill，请重新选择。';
  else if (!hasSkillInventory()) q('#skillComposerState').textContent = '当前快照没有目录清单；刷新后可选择 Skill。';
  else if (!task || !chosen.length) q('#skillComposerState').textContent = '选择 Skill 并填写任务描述后可复制草稿。';
  else q('#skillComposerState').textContent = '可复制草稿；请在执行前核对适用范围。';
}
function renderSkillComposer() {
  const available = availableSkillChoices();
  const stale = [...skillSelected].filter(key => !available.some(row => skillKey(row) === key));
  q('#skillChoices').innerHTML = available.length ? available.map((row, index) => '<label class="skill-choice"><input type="checkbox" data-skill-index="' + index + '"' + (skillSelected.has(skillKey(row)) ? ' checked' : '') + '> <span>' + Esc(row.name || row.skill) + ' <small>[' + SKILL_SOURCES[row.source] + ' · ' + Esc(row.skill) + ']</small></span></label>').join('')
    : '<p class="note">当前没有可唯一定位且说明可用的 Skill。</p>';
  if (stale.length) q('#skillChoices').innerHTML += '<div class="skill-stale">' + stale.map(key => '<span>' + Esc(key.replace('\u0000', ' / ')) + '：当前缺失或说明待确认</span>').join('') + '<button class="btn" id="skillClearStale" type="button">移除失效项</button></div>';
  q('#skillWorkflow').innerHTML = '<option value="">手动选择</option>' + SKILL_WORKFLOWS.map(row => '<option value="' + row.id + '">' + row.label + '</option>').join('');
  q('#skillBundles').innerHTML = '<option value="">选择已存组合</option>' + skillBundles.map((row, index) => '<option value="' + index + '">' + Esc(row.name) + '</option>').join('');
  q('#skillBundles').value = skillBundleIndex < 0 ? '' : String(skillBundleIndex);
  q('#skillBundleDelete').disabled = skillBundleIndex < 0 || !skillBundles[skillBundleIndex];
  updateSkillPromptState();
}
function skillPromptDraft() {
  const rows = selectedSkillRows(), task = q('#skillTask').value.trim();
  if (!hasSkillInventory() || !rows.length || rows.some(row => !row) || !task) throw Error('请选当前说明明确的 Skill 并填写任务描述。');
  return '任务目标：' + task + '\n\n候选 Skill：\n' + rows.map(row => '- ' + SKILL_SOURCES[row.source] + ' / ' + row.skill).join('\n')
    + '\n\n请先核对这些 Skill 的当前适用范围和实际可用性；无法唯一定位时请提示我。完成后核验结果。';
}
function saveSkillBundle() {
  const name = q('#skillBundleName').value.trim().slice(0, 48), rows = selectedSkillRows();
  if (!name || !rows.length || rows.some(row => !row)) { q('#skillComposerState').textContent = '请填写组合名称，并重新选择当前可唯一定位的 Skill。'; return; }
  const existing = skillBundles.findIndex(row => row.name === name);
  if (existing < 0 && skillBundles.length >= 20) { q('#skillComposerState').textContent = '最多保存 20 组；请删除不再需要的组合，或用同名更新。'; return; }
  const bundle = { name, skills: rows.map(row => ({ skill: row.skill, source: row.source })) };
  if (existing < 0) { skillBundles.push(bundle); skillBundleIndex = skillBundles.length - 1; }
  else { skillBundles[existing] = bundle; skillBundleIndex = existing; }
  const persisted = writeStorage('localStorage', BUNDLE_KEY, { bundles: skillBundles });
  renderSkillComposer(); q('#skillComposerState').textContent = persisted ? '组合已保存在当前浏览器，仅含名称和 Skill 标识。' : '组合仅在本页暂存；浏览器未允许持久保存。';
}
function loadSkillBundle(index) {
  const bundle = skillBundles[index];
  if (!bundle) return;
  skillBundleIndex = index; q('#skillBundleName').value = bundle.name;
  skillSelected = new Set(bundle.skills.map(skillKey));
  renderSkillComposer(); q('#skillComposerState').textContent = selectedSkillRows().some(row => !row)
    ? '组合已有 Skill 缺失或冲突，请重新选择后再生成。' : '已载入组合；请填写当前任务描述。';
}
function deleteSkillBundle() {
  if (skillBundleIndex < 0 || !skillBundles[skillBundleIndex]) return;
  skillBundles.splice(skillBundleIndex, 1); skillBundleIndex = -1;
  const persisted = writeStorage('localStorage', BUNDLE_KEY, { bundles: skillBundles });
  renderSkillComposer(); q('#skillComposerState').textContent = persisted ? '所选命名组合已从当前浏览器删除。' : '所选组合已从本页移除；浏览器未允许持久保存。';
}
function loadSkillWorkflow(id) {
  const workflow = SKILL_WORKFLOWS.find(row => row.id === id);
  if (!workflow) return;
  const available = new Map(availableSkillChoices().map(row => [row.source + '|' + row.skill, row]));
  skillSelected = new Set(workflow.skills.filter(name => available.has(name)).map(name => skillKey(available.get(name))));
  const missing = workflow.skills.filter(name => !available.has(name));
  renderSkillComposer(); q('#skillComposerState').textContent = missing.length
    ? '预设中这些 Skill 当前未找到或说明待确认：' + missing.join('、') + '。可手动补选。' : '已选预设候选，请核对后填写任务。';
}
function clearStaleSkills() {
  const available = new Set(availableSkillChoices().map(skillKey));
  skillSelected = new Set([...skillSelected].filter(key => available.has(key)));
  renderSkillComposer();
}
async function copySkillPrompt() {
  try { await navigator.clipboard.writeText(skillPromptDraft()); q('#skillComposerState').textContent = '任务口令草稿已复制；未执行任务。'; }
  catch (error) { q('#skillComposerState').textContent = '复制失败：' + failureMessage(error); }
}
function skillAuditSnapshot() {
  if (!hasSkillActivity()) throw Error('请刷新到包含历史活动的快照后导出。');
  const report = buildSkillReport(D.skills, skillView);
  // Only aggregates are copied. Never export activity or task/turn aliases.
  return {
    schema: 'codex_skill_audit_v1', metric: D.skills.metric, timeZone: D.skills.timeZone, asOf: D.skills.asOf,
    metadataAsOf: hasSkillMetadata() ? D.skills.metadataAsOf : null, metadataScope: 'current_local_instructions',
    inventoryAsOf: hasSkillInventory() ? D.skills.inventoryAsOf : null, inventoryScope: hasSkillInventory() ? D.skills.inventoryScope : null,
    generated: D.generated || null, exportedAt: new Date().toISOString(),
    filters: report.filters, summary: report.summary, catalogSkills: report.catalogSkills,
    trendMode: report.trendMode, trend: report.trend, sources: report.sources, rows: report.rows,
    boundaries: [
      'Skill 说明读取是可观测代理指标，不代表实际调用或任务成功。仅主任务，排除 guardian 与子代理。',
      '记录的是可识别的读取命令，未核验文件实际读取成功。',
      'currentName/currentDescription 是 metadataAsOf 当天的当前本地说明，不是历史版本；缺失或多份冲突时不填简介。简介不会改变历史读取计数。',
      'currentDescriptionZh 是本地中文释义，不是 Skill 源文件内容。仅来源、Skill 标识与英文原文精确匹配时提供；原文变化自动停用旧释义，currentDescription 始终保留原文。',
      'scope=history 仅列截至所选结束日的历史观测项；scope=inventory 列 inventoryAsOf 的已知本地目录定义；scope=combined 合并两者，均非完整安装清单。目录扫描不增加读取计数，本期未观测不等于未使用。',
      '目录清单只覆盖已知本地目录，不证明启用或安装全集；directoryState 为当前目录状态，历史未观测不等于从未使用，历史条目本次未发现不等于已卸载。用途分类仅为候选。',
      '观察提示仅供人工复核，不代表质量结论或停用、删除建议；同名多处可能是不同 Skill。',
      '轮次与主任务在当前筛选内跨 Skill 去重；Skill × 轮次按每项 Skill 分别计。每日跨 Skill 去重，同轮跨日每天各计。',
      '历史读取日期按 Asia/Shanghai 且含首尾，历史最近观测仅截止所选结束日；当前目录状态独立取 inventoryAsOf。daily 趋势包含零值日，sparse_calendar 趋势仅列有记录日并按日历位置绘图。仅导出汇总，不含原始记录、路径、任务或轮次标识。'
    ]
  };
}
function exportSkillAudit() {
  try {
    const snapshot = skillAuditSnapshot(), blob = new Blob([JSON.stringify(snapshot, null, 2)], { type: 'application/json;charset=utf-8' });
    const address = URL.createObjectURL(blob), link = document.createElement('a');
    link.href = address; link.download = 'codex-skill-audit-' + snapshot.filters.start + '-' + snapshot.filters.end + '.json';
    document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(address), 1000);
    q('#skillExportState').textContent = '已导出当前筛选的审计快照，仅包含汇总数据。';
  } catch (error) { q('#skillExportState').textContent = '导出失败：' + failureMessage(error); }
}
function render() {
  const start = q('#start').value, end = q('#end').value, rangeError = usageRangeError(D, start, end);
  if (!rangeError) {
    renderTokens(filter(U), filter(D.tasks, taskDate));
    renderEfficiency(filter(D.tasks, taskDate), filter(D.compactions));
  }
  renderSkills();
  q('#rangeSummary').textContent = rangeError || '默认本月（自然月初至快照截至日）；重置筛选恢复' + (hasUsageScopes() ? '任务用量、' : '') + '全部模型、全部推理强度。当前范围：' + start + ' 至 ' + end + '（含首尾） · Token 与请求共享筛选。';
  q('#usageScopeNote').textContent = hasUsageScopes()
    ? '当前统计：' + USAGE_SCOPES[usageScope()] + '。模型占比按原始 Token 计算，不代表官方套餐额度占比。'
    : '旧快照未区分任务与自动安全审查，当前仅展示全部 Token；模型归属未按新口径核验。点击“立即刷新”后可分开查看。原始 Token 不代表官方套餐额度。';
  const history = D.refresh?.history, hasRetainedHistory = history?.retainedFiles > 0;
  q('#usageHistoryNote').classList.toggle('hidden', !hasRetainedHistory);
  q('#usageHistoryNote').textContent = hasRetainedHistory
    ? '原日志迁移后的历史统计已合并保留' + (history.startDate ? '，最早可见日期为 ' + history.startDate : '') + '。' : '';
  selectPage(q('.tab[aria-selected=true]').dataset.page);
  q('#cacheInfo').textContent = D.refresh
    ? '本次源文件缓存：' + D.refresh.reused + ' 个复用，' + D.refresh.reparsed + ' 个重新解析。'
    : '尚无本次刷新缓存信息。';
  if (Number.isSafeInteger(D.refresh?.sourceBytesRead) && D.refresh.sourceBytesRead >= 0) {
    q('#cacheInfo').textContent += ' 本次需处理源文件体积 ' + Bytes(D.refresh.sourceBytesRead) + '（按文件大小估算）。';
  }
  if (['appended', 'parsedBytes', 'prefixBytesVerified'].every(key => Number.isSafeInteger(D.refresh?.[key]) && D.refresh[key] >= 0)) {
    q('#cacheInfo').textContent += ' 其中 ' + D.refresh.appended + ' 个文件按追加内容更新；实际解析 '
      + Bytes(D.refresh.parsedBytes) + '，旧内容完整性校验 ' + Bytes(D.refresh.prefixBytesVerified) + '。';
  }
  if (typeof D.refresh?.elapsedMs === 'number' && Number.isFinite(D.refresh.elapsedMs) && D.refresh.elapsedMs >= 0) {
    q('#cacheInfo').textContent += ' 汇总阶段耗时 ' + Sec(D.refresh.elapsedMs / 1000) + '。';
  }
  if (Number.isSafeInteger(D.refresh?.supplementalTokenRequests) && D.refresh.supplementalTokenRequests > 0
    && Number.isSafeInteger(D.refresh?.supplementalTokens) && D.refresh.supplementalTokens >= 0) {
    q('#cacheInfo').textContent += ' Token 汇总已补计 ' + D.refresh.supplementalTokenRequests + ' 条逐请求记录（'
      + F(D.refresh.supplementalTokens) + ' Token，已按响应去重）。';
  }
  if (history) {
    q('#cacheInfo').textContent += ' 历史统计：本次恢复 ' + history.recoveredFiles + ' 个文件，留存合并 '
      + history.retainedFiles + ' 个文件，跳过 ' + history.skippedCaches + ' 份缓存。';
  }
}

function saveView() {
  viewMemory = { start: q('#start').value, end: q('#end').value, model: q('#model').value,
    rangePreset: q('#usagePreset').value, usageScope: usageScopePreference,
    effort: q('#effort').value, metric: q('#metric').value,
    skills: { ...skillView },
    page: q('.tab[aria-selected=true]').dataset.page };
  writeStorage('sessionStorage', VIEW_KEY, viewMemory);
}
function selectPage(page) {
  if (!['token', 'eff', 'skill'].includes(page)) page = 'token';
  const rangeError = usageRangeError(D, q('#start').value, q('#end').value);
  qa('.tab').forEach(button => button.setAttribute('aria-selected', button.dataset.page === page));
  q('#token').classList.toggle('hidden', page !== 'token' || Boolean(rangeError));
  q('#eff').classList.toggle('hidden', page !== 'eff' || Boolean(rangeError));
  q('#usageRangeError').classList.toggle('hidden', page === 'skill' || !rangeError);
  q('#usageRangeError').textContent = rangeError;
  q('#skill').classList.toggle('hidden', page !== 'skill');
  q('#usageFilters').classList.toggle('hidden', page === 'skill');
  q('#metricBox').classList.toggle('hidden', page !== 'token');
}
function validDate(value) { return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value); }
function restoreView() {
  const view = Object.keys(viewMemory).length ? viewMemory : readStorage('sessionStorage', VIEW_KEY, viewMemory);
  restoreUsageScope(view.usageScope);
  const initial = defaultRange(D);
  // Old saved dates had no preset marker. Preserve them as a custom historical range.
  const preset = DATE_PRESETS.includes(view.rangePreset) ? view.rangePreset : calendarDate(view.start) || calendarDate(view.end) ? 'custom' : 'month';
  const range = usageDateRange(D, preset, { start: typeof view.start === 'string' ? view.start : initial.start, end: typeof view.end === 'string' ? view.end : initial.end }, usageScope());
  q('#usagePreset').value = preset; q('#start').value = range.start; q('#end').value = range.end;
  q('#start').max = q('#end').max = snapshotDay(D);
  reconcileUsageDimensions(view.model, view.effort);
  q('#metric').value = ['total', 'cached', 'fresh', 'output'].includes(view.metric) ? view.metric : 'total';
  selectPage(view.page);
  restoreSkillView(view.skills);
}
function localDay(date) {
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}
function chooseUsageRange(preset) {
  if (preset !== 'custom') {
    const range = usageDateRange(D, preset, undefined, usageScope()); q('#start').value = range.start; q('#end').value = range.end;
  }
  saveView(); render();
}
function changeUsageScope() {
  const model = q('#model').value, effort = q('#effort').value;
  restoreUsageScope(q('#usageScope').value);
  reconcileUsageDimensions(model, effort);
  chooseUsageRange(q('#usagePreset').value);
}
function changeUsageModel() {
  reconcileUsageDimensions(q('#model').value, q('#effort').value);
  saveView(); render();
}
function reset() {
  const initial = defaultRange(D);
  q('#start').value = initial.start; q('#end').value = initial.end;
  q('#usagePreset').value = 'month';
  restoreUsageScope('task');
  opts('#model', 'model'); opts('#effort', 'effort'); q('#metric').value = 'total';
  saveView(); render();
}

function failureMessage(error) { return error?.message || '未知错误'; }
function serviceFailure(state) {
  const message = state.lastError || '';
  const exit = message.match(/^Refresh exited with code (-?\d+)\./);
  if (exit) return '后台汇总进程异常退出（退出码 ' + exit[1] + '）';
  if (message.startsWith('Refresh produced no new data snapshot.')) return '后台汇总未生成新版数据';
  if (message.startsWith('Refresh could not publish a valid data snapshot.')) return '后台汇总未能生成有效数据';
  if (message.startsWith('Refresh could not start.')) return '后台汇总进程未能启动';
  if (message.startsWith('Dashboard data is not ready.')) return '统计数据尚未就绪，请启动刷新';
  return message || '后台汇总失败';
}
function showFailure(prefix, error) {
  q('#state').textContent = prefix + '：' + failureMessage(error) + '。保留已加载数据，可点击“立即刷新”重试。';
}
function statusMessage(state) {
  if (state.status === 'failed') return '上次刷新失败：' + serviceFailure(state) + '。当前为上一版数据，可重试。';
  if (state.status === 'refreshing') return '正在汇总…当前显示上一版数据';
  return '已更新';
}
async function status() {
  const response = await fetch('/api/status?ts=' + Date.now(), { cache: 'no-store' });
  if (!response.ok) throw Error('无法读取刷新状态（HTTP ' + response.status + '）');
  const state = await response.json();
  if (!['ready', 'refreshing', 'failed'].includes(state.status)) throw Error('刷新状态格式无效');
  return state;
}
function validateData(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data) || !['usage', 'tasks', 'compactions'].every(key => Array.isArray(data[key]))) {
    throw Error('数据格式无效');
  }
  if (Object.prototype.hasOwnProperty.call(data, 'usageScopeSchema')) {
    if (data.usageScopeSchema !== 1 || !['usage', 'tasks', 'compactions'].every(key => data[key].every(row =>
      row && ['task', 'auto_review'].includes(row.scope)))) throw Error('Token 统计范围数据格式无效');
  }
  if (Object.prototype.hasOwnProperty.call(data.refresh || {}, 'history')) {
    const history = data.refresh.history;
    if (!history || typeof history !== 'object' || Array.isArray(history) || history.schema !== 1
      || !['retainedFiles', 'recoveredFiles', 'skippedCaches'].every(key => Number.isSafeInteger(history[key]) && history[key] >= 0)
      || history.startDate !== null && !calendarDate(history.startDate)) throw Error('历史统计数据格式无效');
  }
  const identity = row => row && typeof row === 'object' && !Array.isArray(row) && calendarDate(row.date)
    && Number.isSafeInteger(row.session) && row.session >= 1
    && ['model', 'effort'].every(key => typeof row[key] === 'string' && Boolean(row[key].trim()));
  const timing = value => value == null || typeof value === 'number' && Number.isFinite(value) && value >= 0;
  for (const row of data.usage) {
    if (!identity(row) || !['total', 'input', 'cached', 'fresh', 'output', 'reasoning'].every(key => Number.isSafeInteger(row[key]) && row[key] >= 0)
      || row.cached > row.input || row.reasoning > row.output || row.total !== row.input + row.output || row.fresh !== row.input - row.cached) {
      throw Error('Token 用量数据格式无效');
    }
  }
  for (const row of data.tasks) {
    if (!identity(row) || typeof row.started !== 'boolean' || typeof row.completed !== 'boolean' || !row.started && !row.completed
      || row.startedDate != null && !calendarDate(row.startedDate)
      || row.error !== undefined && typeof row.error !== 'boolean' || row.error && !row.completed
      || !timing(row.duration) || !timing(row.ttfb)) throw Error('请求统计数据格式无效');
  }
  if (!data.compactions.every(identity)) throw Error('上下文压缩数据格式无效');
  if (Object.prototype.hasOwnProperty.call(data, 'skills')) validateSkills(data.skills);
  return data;
}
function validateSkills(skills) {
  const fail = () => { throw Error('Skill 说明读取数据格式无效'); };
  if (!skills || skills.metric !== 'skill_instruction_reads' || skills.timeZone !== 'Asia/Shanghai'
    || skills.scope !== 'main_sessions' || !validDate(skills.asOf) || !Array.isArray(skills.rows)) fail();
  const end = new Date(skills.asOf + 'T00:00:00Z');
  if (!Number.isFinite(end.getTime()) || end.toISOString().slice(0, 10) !== skills.asOf) fail();
  for (const days of [7, 30]) {
    const window = skills.windows?.['days' + days], start = new Date(end);
    start.setUTCDate(start.getUTCDate() - days + 1);
    if (!window || window.end !== skills.asOf || window.start !== start.toISOString().slice(0, 10)) fail();
  }
  const rowKeys = new Set();
  for (const row of skills.rows) {
    if (!row || typeof row.skill !== 'string' || !row.skill.trim()
      || typeof row.source !== 'string' || !Object.prototype.hasOwnProperty.call(SKILL_SOURCES, row.source)
      || !['readTurns7', 'tasks7', 'readTurns30', 'tasks30'].every(key => Number.isSafeInteger(row[key]) && row[key] >= 0)
      || row.tasks7 > row.readTurns7 || row.tasks30 > row.readTurns30
      || row.readTurns7 > row.readTurns30 || row.tasks7 > row.tasks30) fail();
    if (rowKeys.has(skillKey(row))) fail(); rowKeys.add(skillKey(row));
  }
  const activityPresent = Object.prototype.hasOwnProperty.call(skills, 'activity') || Object.prototype.hasOwnProperty.call(skills, 'activitySchema');
  if (activityPresent) {
    if (skills.activitySchema !== 1 || !Array.isArray(skills.activity)) fail();
    const eventKeys = new Set(), turnTasks = new Map();
    for (const row of skills.activity) {
      if (!row || typeof row.skill !== 'string' || !row.skill.trim() || row.skill.length > 256 || /[\\/\u0000-\u001f]/.test(row.skill)
        || typeof row.source !== 'string' || !Object.prototype.hasOwnProperty.call(SKILL_SOURCES, row.source)
        || !calendarDate(row.date) || row.date > skills.asOf
        || !Number.isSafeInteger(row.task) || row.task < 1 || !Number.isSafeInteger(row.turn) || row.turn < 1) fail();
      if (turnTasks.has(row.turn) && turnTasks.get(row.turn) !== row.task) fail(); turnTasks.set(row.turn, row.task);
      const key = row.date + '\u0000' + skillKey(row) + '\u0000' + row.task + '\u0000' + row.turn;
      if (eventKeys.has(key)) fail(); eventKeys.add(key);
    }
  }
  const metadataPresent = ['metadataSchema', 'metadataAsOf', 'metadata'].some(key => Object.prototype.hasOwnProperty.call(skills, key));
  if (metadataPresent) {
    if (skills.metadataSchema !== 1 || !calendarDate(skills.metadataAsOf) || !Array.isArray(skills.metadata)) fail();
    const expected = new Set((hasSkillActivity(skills) ? skills.activity : skills.rows).map(skillKey)), found = new Set();
    for (const row of skills.metadata) {
      if (!row || typeof row.skill !== 'string' || !row.skill.trim() || /[\\/\u0000-\u001f]/.test(row.skill)
        || typeof row.source !== 'string' || !Object.prototype.hasOwnProperty.call(SKILL_SOURCES, row.source)
        || !['available', 'missing', 'ambiguous'].includes(row.status) || typeof row.name !== 'string' || typeof row.description !== 'string'
        || row.status !== 'available' && (row.name !== '' || row.description !== '')
        || /(?:^|[\s"'(=])(?:[a-z]:[\\/]|\\\\[^\\\s]+\\)|\/(?:Users|home)\//i.test(row.name + '\n' + row.description)) fail();
      const key = skillKey(row);
      if (found.has(key) || hasSkillActivity(skills) && !expected.has(key)) fail(); found.add(key);
    }
    for (const key of expected) if (!found.has(key)) fail();
  }
  const inventoryPresent = ['inventorySchema', 'inventoryAsOf', 'inventoryScope', 'inventory'].some(key => Object.prototype.hasOwnProperty.call(skills, key));
  if (inventoryPresent) {
    if (skills.inventorySchema !== 1 || !calendarDate(skills.inventoryAsOf) || skills.inventoryScope !== 'known_local_skill_roots' || !Array.isArray(skills.inventory)) fail();
    const found = new Set();
    for (const row of skills.inventory) {
      if (!row || typeof row.skill !== 'string' || !row.skill.trim() || row.skill.length > 256 || /[\\/\u0000-\u001f]/.test(row.skill)
        || typeof row.source !== 'string' || !Object.prototype.hasOwnProperty.call(SKILL_SOURCES, row.source)
        || !['available', 'missing', 'ambiguous'].includes(row.status) || typeof row.name !== 'string' || typeof row.description !== 'string'
        || !Number.isSafeInteger(row.copies) || row.copies < 1 || row.status !== 'available' && (row.name !== '' || row.description !== '')
        || /(?:^|[\s"'(=])(?:[a-z]:[\\/]|\\\\[^\\\s]+\\)|\/(?:Users|home)\//i.test(row.name + '\n' + row.description)) fail();
      const key = skillKey(row); if (found.has(key)) fail(); found.add(key);
    }
  }
}
async function loadData({ expectedUpdated = '', showState = true, knownStatus = null } = {}) {
  if (loadPromise) {
    await loadPromise;
    if (!expectedUpdated || lastUpdated === expectedUpdated) return lastUpdated;
  }
  loadBusy = true;
  loadPromise = (async () => {
    const before = knownStatus || await status();
    if (expectedUpdated && (before.status !== 'ready' || before.updated !== expectedUpdated)) {
      throw Error('数据版本已变化，等待下一次刷新');
    }
    const response = await fetch('/api/data?ts=' + Date.now(), { cache: 'no-store' });
    if (!response.ok) throw Error('无法加载统计数据（HTTP ' + response.status + '）');
    const next = validateData(await response.json());
    const after = await status();
    if (before.updated !== after.updated || (expectedUpdated && after.status !== 'ready')) {
      throw Error('读取期间数据版本变化，请重试');
    }
    // Commit only after data and its version have both been checked.
    D = next; U = D.usage;
    const bounds = dateBounds(D); ds = bounds.start; de = bounds.end;
    restoreView(); render();
    lastUpdated = after.updated || '';
    q('#sub').textContent = '本机只读统计 · 数据生成于 ' + (D.generated || '未知时间');
    if (showState) q('#state').textContent = statusMessage(after);
    return lastUpdated;
  })();
  try { return await loadPromise; }
  finally { loadBusy = false; loadPromise = null; }
}
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function waitRefresh(previousUpdated, timeoutMs = 900000, pollMs = 250) {
  const started = Date.now();
  let statusFailures = 0;
  while (Date.now() - started < timeoutMs) {
    let state;
    try { state = await status(); statusFailures = 0; }
    catch (error) {
      if (++statusFailures >= 3) throw error;
      q('#state').textContent = '正在重连本机服务…当前数据继续可用';
      await delay(pollMs); continue;
    }
    if (state.status === 'failed') throw Error(serviceFailure(state));
    if (state.status === 'ready' && state.updated && state.updated !== previousUpdated) {
      await loadData({ expectedUpdated: state.updated, showState: false, knownStatus: state });
      return state.updated;
    }
    q('#state').textContent = state.status === 'refreshing' ? '正在汇总…当前数据继续可用' : '等待新版数据…';
    await delay(pollMs);
  }
  throw Error('等待刷新超时，后台可能仍在运行');
}
async function manualRefresh() {
  if (refreshBusy) return;
  refreshBusy = true;
  const button = q('#refresh'); button.disabled = true; button.textContent = '刷新中…';
  q('#state').textContent = '正在启动';
  try {
    const before = await status();
    const response = await fetch('/api/refresh', { method: 'POST', headers: { 'X-Codex-Dashboard': '1' } });
    if (response.status !== 409 && !response.ok) throw Error('无法启动刷新（HTTP ' + response.status + '）');
    if (response.status === 409) q('#state').textContent = '已有刷新进行中…';
    await waitRefresh(before.updated || '');
    q('#state').textContent = '刷新完成';
  } catch (error) { showFailure('刷新失败', error); }
  finally { button.disabled = false; button.textContent = '立即刷新'; refreshBusy = false; }
}
async function autoRefresh() {
  if (refreshBusy || loadBusy) return;
  try {
    const state = await status();
    if (state.updated && state.updated !== lastUpdated) await loadData();
    else q('#state').textContent = statusMessage(state);
  } catch (error) { showFailure('自动更新失败', error); }
}

let pref = readStorage('localStorage', PREF_KEY, prefsMemory);
const defaults = { break: true, dist: true, compact: true };
function applyPreferences() {
  Object.keys(defaults).forEach(key => {
    const visible = typeof pref[key] === 'boolean' ? pref[key] : defaults[key];
    qa('.pref-' + key).forEach(element => element.classList.toggle('hidden', !visible));
    q('[data-pref="' + key + '"]').checked = visible;
  });
}
let previousFocus = null;
function openInfo() {
  previousFocus = document.activeElement;
  q('#infoModal').classList.remove('hidden');
  q('.info-close').focus();
}
function closeInfo() {
  q('#infoModal').classList.add('hidden');
  previousFocus?.focus();
}
function initialize() {
  const storedBundles = readStorage('localStorage', BUNDLE_KEY).bundles;
  skillBundles = Array.isArray(storedBundles) ? storedBundles.slice(0, 20).filter(row => row && typeof row.name === 'string' && row.name.length <= 48 && Array.isArray(row.skills)
    && row.skills.length <= 30 && row.skills.every(item => item && typeof item.skill === 'string' && item.skill.length <= 256 && typeof item.source === 'string' && Object.prototype.hasOwnProperty.call(SKILL_SOURCES, item.source)))
    .map(row => ({ name: row.name, skills: row.skills.map(item => ({ skill: item.skill, source: item.source })) })) : [];
  q('#skillCategory').innerHTML = '<option value="all">全部用途</option>' + SKILL_CATEGORIES.map(row => '<option value="' + row.id + '">' + row.label + '</option>').join('') + '<option value="other">其他 / 待分类</option>';
  q('#reset').onclick = reset; q('#refresh').onclick = manualRefresh;
  qa('#start,#end').forEach(element => element.onchange = () => { q('#usagePreset').value = 'custom'; saveView(); render(); });
  q('#model').onchange = changeUsageModel;
  qa('#effort,#metric').forEach(element => element.onchange = () => { saveView(); render(); });
  q('#usagePreset').onchange = () => chooseUsageRange(q('#usagePreset').value);
  q('#usageScope').onchange = changeUsageScope;
  qa('.tab').forEach(button => button.onclick = () => { selectPage(button.dataset.page); saveView(); });
  qa('#skillPreset,#skillSource,#skillScope,#skillCategory,#skillObservation,#skillSort').forEach(element => element.onchange = () => changeSkillFilters());
  qa('#skillStart,#skillEnd').forEach(element => element.onchange = () => changeSkillFilters(true));
  q('#skillSearch').oninput = () => changeSkillFilters();
  q('#skillReset').onclick = resetSkillFilters; q('#skillExport').onclick = exportSkillAudit;
  q('#skillChoices').onclick = event => { if (event.target?.id === 'skillClearStale') clearStaleSkills(); };
  q('#skillChoices').onchange = event => {
    const index = Number(event.target?.dataset?.skillIndex), row = availableSkillChoices()[index];
    if (!Number.isSafeInteger(index) || !row) return;
    if (event.target.checked) skillSelected.add(skillKey(row)); else skillSelected.delete(skillKey(row));
    updateSkillPromptState();
  };
  q('#skillTask').oninput = updateSkillPromptState;
  q('#skillWorkflow').onchange = () => loadSkillWorkflow(q('#skillWorkflow').value);
  q('#skillBundles').onchange = () => loadSkillBundle(Number(q('#skillBundles').value));
  q('#skillBundleSave').onclick = saveSkillBundle;
  q('#skillBundleDelete').onclick = deleteSkillBundle;
  q('#skillCopyPrompt').onclick = copySkillPrompt;
  q('#skillTrend').onpointermove = event => { if (event.pointerType !== 'touch') inspectSkillPoint(event); };
  q('#skillTrend').onfocusin = inspectSkillPoint; q('#skillTrend').onclick = inspectSkillPoint;
  q('#skillTrend').onkeydown = event => {
    if (!skillTrendState || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    if (event.key === 'Home' || event.key === 'End') selectSkillDay(event.key === 'Home' ? skillTrendState.start : skillTrendState.end);
    else stepSkillDay(event.key === 'ArrowLeft' ? -1 : 1);
    const target = qa('#skillTrend .skill-day').find(button => button.dataset.date === skillTrendState.date);
    (target || q('#skillInspectDate')).focus();
  };
  q('#skillInspectDate').onchange = () => selectSkillDay(q('#skillInspectDate').value);
  q('#skillDayPrev').onclick = () => stepSkillDay(-1); q('#skillDayNext').onclick = () => stepSkillDay(1);
  qa('[data-pref]').forEach(element => element.onchange = () => {
    pref[element.dataset.pref] = element.checked; prefsMemory = pref;
    writeStorage('localStorage', PREF_KEY, pref); applyPreferences();
  });
  q('#set').onclick = () => q('#menu').classList.toggle('hidden');
  q('#restore').onclick = () => { pref = {}; prefsMemory = {}; writeStorage('localStorage', PREF_KEY, pref); applyPreferences(); };
  q('#infoButton').onclick = openInfo; q('.info-close').onclick = closeInfo;
  q('#infoModal').onclick = event => { if (event.target.id === 'infoModal') closeInfo(); };
  document.addEventListener('keydown', event => {
    if (q('#infoModal').classList.contains('hidden')) return;
    if (event.key === 'Escape') closeInfo();
    // The information dialog has one interactive control.
    if (event.key === 'Tab') { event.preventDefault(); q('.info-close').focus(); }
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('.settings')) q('#menu').classList.add('hidden');
  });
  applyPreferences();
  setInterval(autoRefresh, 30000);
  loadData().catch(error => showFailure('数据加载失败', error));
}
initialize();
