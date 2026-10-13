// Run with Node.js. Synthetic fixtures only; no browser, network, or user logs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'web/dashboard.html'), 'utf8');
const script = fs.readFileSync(path.join(root, 'web/dashboard.js'), 'utf8').replace(/initialize\(\);\s*$/, '');
const translationScript = fs.readFileSync(path.join(root, 'web/skill-descriptions.zh-CN.js'), 'utf8');
const fixture = () => ({
  month: '2026-09', generated: '2026-09-28 12:00',
  usage: [
    { date: '2026-08-20', session: 1, model: 'a', effort: 'high', total: 100, input: 80, cached: 30, fresh: 50, output: 20, reasoning: 10 },
    { date: '2026-09-07', session: 2, model: 'b', effort: 'low', total: 20, input: 10, cached: 0, fresh: 10, output: 10, reasoning: 0 }
  ],
  tasks: [
    { date: '2026-09-08', startedDate: '2026-08-20', session: 1, model: 'a', effort: 'high', started: true, completed: true, duration: null, ttfb: null },
    { date: '2026-08-20', session: 1, model: 'a', effort: 'high', started: true, completed: false },
    { date: '2026-08-20', session: 1, model: 'a', effort: 'high', started: true, completed: true, duration: 20, ttfb: 0 },
    { date: '2026-09-07', session: 2, model: 'b', effort: 'low', started: true, completed: false }
  ],
  compactions: [], refresh: { reused: 2, reparsed: 1 }
});
const skillFixture = () => ({
  ...fixture(),
  skills: {
    metric: 'skill_instruction_reads', timeZone: 'Asia/Shanghai', asOf: '2026-09-28', scope: 'main_sessions',
    windows: { days7: { start: '2026-09-22', end: '2026-09-28' }, days30: { start: '2026-08-30', end: '2026-09-28' } },
    rows: [
      { skill: 'writer<em>"&\'测试', source: 'personal', readTurns7: 3, tasks7: 2, readTurns30: 8, tasks30: 3 },
      { skill: 'workspace-' + 'long-skill-name-'.repeat(12), source: 'workspace', readTurns7: 1, tasks7: 1, readTurns30: 3, tasks30: 2 },
      { skill: 'imagegen', source: 'system', readTurns7: 0, tasks7: 0, readTurns30: 2, tasks30: 1 },
      { skill: 'pdf', source: 'plugin', readTurns7: 1, tasks7: 1, readTurns30: 2, tasks30: 2 },
      { skill: 'unclassified', source: 'unknown', readTurns7: 0, tasks7: 0, readTurns30: 1, tasks30: 1 }
    ]
  }
});
const activityFixture = () => {
  const data = skillFixture();
  const event = (date, skill, source, task, turn) => ({ date, skill, source, task, turn });
  data.skills.activitySchema = 1;
  data.skills.activity = [
    event('2026-08-10', 'archive', 'personal', 9, 90),
    event('2026-09-21', 'alpha', 'personal', 1, 10),
    event('2026-09-22', 'alpha', 'personal', 1, 10),
    event('2026-09-22', 'beta', 'plugin', 1, 10),
    event('2026-09-23', 'alpha', 'personal', 2, 20),
    event('2026-09-24', 'pack:alpha', 'plugin', 2, 21),
    event('2026-09-24', 'workspace-' + 'long-skill-name-'.repeat(12), 'workspace', 2, 21),
    event('2026-09-28', 'mystery', 'unknown', 3, 30),
    event('2026-09-28', 'imagegen', 'system', 3, 30)
  ];
  // Consistent fixed-window data remains available to old clients.
  data.skills.rows = [...new Map(data.skills.activity.filter(row => row.skill !== 'archive').map(row => [row.source + ':' + row.skill, row])).values()]
    .map(row => ({ skill: row.skill, source: row.source, readTurns7: row.skill === 'alpha' ? 2 : 1, tasks7: row.skill === 'alpha' ? 2 : 1,
      readTurns30: row.skill === 'alpha' ? 2 : 1, tasks30: row.skill === 'alpha' ? 2 : 1 }));
  return data;
};
const metadataFixture = () => {
  const data = activityFixture();
  data.skills.metadataSchema = 1;
  data.skills.metadataAsOf = '2026-10-01'; // Current local descriptions can postdate a historical usage snapshot.
  data.skills.metadata = [...new Map(data.skills.activity.map(row => [row.source + ':' + row.skill, row])).values()].map(row => ({
    skill: row.skill, source: row.source, status: 'available', name: '', description: '当前本地说明。'
  }));
  for (const row of data.skills.metadata) {
    if (row.skill === 'alpha') { row.name = '研究助手'; row.description = '财务对账与公开资料整理。' + '这是当前本地简介，支持详细的业务说明。'.repeat(12) + ' <script>doNotRun()</script> 完整尾句。'; }
    if (row.skill === 'archive' || row.skill === 'mystery') { row.status = 'missing'; row.name = ''; row.description = ''; }
    if (row.skill === 'beta') { row.status = 'ambiguous'; row.name = ''; row.description = ''; }
    if (row.skill === 'imagegen') { row.name = '图像工具'; row.description = ''; }
  }
  return data;
};
const reply = (data, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => data });
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

function harness({ local = '{invalid', session = '{}', storageThrows = false, translations } = {}) {
  const elements = new Map();
  let focused;
  function element(id, dataset = {}) {
    const classes = new Set();
    const attrs = {};
    return { id, dataset, value: '', textContent: '', innerHTML: '', disabled: false, checked: true,
      selectedOptions: [{ textContent: 'Total Token' }],
      classList: { toggle(name, force) { const yes = force === undefined ? !classes.has(name) : force; yes ? classes.add(name) : classes.delete(name); },
        add(name) { classes.add(name); }, remove(name) { classes.delete(name); }, contains(name) { return classes.has(name); } },
      setAttribute(name, value) { attrs[name] = String(value); }, getAttribute(name) { return attrs[name]; },
      focus() { focused = this; }, closest() { return null; }
    };
  }
  for (const match of html.matchAll(/\bid="([^"]+)"/g)) elements.set('#' + match[1], element(match[1]));
  const tabs = [...html.matchAll(/class="tab" data-page="([^"]+)"/g)]
    .map((match, index) => { const tab = element(match[1] + '-tab', { page: match[1] }); tab.setAttribute('aria-selected', index === 0); return tab; });
  const prefs = ['break', 'dist', 'compact'].map(key => element(key, { pref: key }));
  const close = element('info-close');
  elements.get('#infoModal').classList.add('hidden');
  const events = {};
  const document = {
    get activeElement() { return focused; },
    querySelector(selector) {
      if (selector === '.tab[aria-selected=true]') return tabs.find(tab => tab.getAttribute('aria-selected') === 'true');
      if (selector === '.info-close') return close;
      const pref = selector.match(/^\[data-pref="(.+)"\]$/);
      if (pref) return prefs.find(item => item.dataset.pref === pref[1]);
      if (!elements.has(selector)) throw Error('Missing HTML element: ' + selector);
      return elements.get(selector);
    },
    querySelectorAll(selector) {
      if (selector === '.tab') return tabs;
      if (selector === '[data-pref]') return prefs;
      if (selector === '#skillTrend .skill-day') return [];
      if (selector.startsWith('.pref-') || selector === '[data-range]') return [];
      return selector.split(',').map(item => this.querySelector(item));
    },
    addEventListener(event, listener) { events[event] = listener; }
  };
  function storage(initial) {
    let value = initial;
    return { getItem() { if (storageThrows) throw Error('storage disabled'); return value; },
      setItem(key, next) { if (storageThrows) throw Error('storage disabled'); value = next; } };
  }
  const timers = [], calls = [];
  let api = () => { throw Error('Unexpected fetch'); };
  const context = vm.createContext({ document, window: { localStorage: storage(local), sessionStorage: storage(session) },
    console, Date, setTimeout: callback => timers.push(callback), setInterval: () => {},
    fetch: async (url, options) => { calls.push({ url, options }); return api(url, options); } });
  vm.runInContext(translations === undefined ? translationScript : 'const SKILL_DESCRIPTION_ZH = ' + JSON.stringify(translations) + ';', context);
  vm.runInContext(script, context);
  return { elements, tabs, timers, calls, events, run: code => vm.runInContext(code, context),
    api(handler) { api = handler; }, tick() { const next = timers.shift(); assert.ok(next, 'a poll is pending'); next(); },
    focus: () => focused, data: value => { context.synthetic = value; } };
}
let count = 0;
async function test(name, action) { await action(); console.log('PASS ' + name); count++; }

(async () => {
  await test('missing timing samples are excluded while genuine zero remains', () => {
    const h = harness();
    assert.equal(h.run('JSON.stringify(samples([{ttfb:null},{},{ttfb:""},{ttfb:0},{ttfb:5},{ttfb:-1},{ttfb:"bad"}], "ttfb"))'), '[0,5]');
    assert.equal(h.run('Q(samples([{duration:null}], "duration"), .5)'), null);
  });
  await test('all dates include task-only days and default range stays in current month', () => {
    const h = harness(); h.data(fixture());
    assert.equal(h.run('JSON.stringify(dateBounds(synthetic))'), '{"start":"2026-08-20","end":"2026-09-07"}');
    assert.equal(h.run('JSON.stringify(defaultRange(synthetic))'), '{"start":"2026-09-01","end":"2026-09-28"}');
    assert.equal(h.run('dateBounds({usage:[],tasks:[{startedDate:"2026-07-01"}],compactions:[]}).start'), '2026-07-01');
  });
  await test('daily request count includes open tasks and uses start date across midnight', () => {
    const h = harness(); h.data(fixture());
    assert.equal(h.run('JSON.stringify(daily(synthetic.tasks, () => 1, taskDate))'), '[["2026-08-20",3],["2026-09-07",1]]');
    h.run('chart([{date:"2026-08-20",n:0}], "#taskTrend", row => row.n)');
    assert.match(h.elements.get('#taskTrend').innerHTML, /height:0%/);
  });
  await test('historic range survives reload and auto-update with corrupt local preferences', async () => {
    const h = harness({ session: JSON.stringify({ start: '2026-08-01', end: '2026-08-31', page: 'eff' }) });
    let version = 'v1';
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : fixture()));
    await h.run('loadData()');
    assert.equal(h.elements.get('#start').value, '2026-08-01');
    assert.equal(h.elements.get('#end').value, '2026-08-31');
    assert.equal(h.elements.get('#usagePreset').value, 'custom', 'legacy saved dates migrate without drifting');
    assert.match(h.elements.get('#taskTrend').innerHTML, /2026-08-20 · 3/);
    assert.match(h.elements.get('#effCards').innerHTML, /样本 1/);
    assert.match(h.elements.get('#durationSamples').textContent, /样本 1 \/ 成功完成 2/);
    assert.match(h.elements.get('#mix').innerHTML, /Output 内 50.0%/);
    version = 'v2'; await h.run('autoRefresh()');
    assert.equal(h.elements.get('#start').value, '2026-08-01');
    assert.equal(h.run('lastUpdated'), 'v2');
  });
  await test('disabled storage preserves active range in memory during refresh', async () => {
    const h = harness({ storageThrows: true });
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : fixture()));
    await h.run('loadData()');
    h.elements.get('#start').value = '2026-08-01'; h.elements.get('#end').value = '2026-08-31';
    h.run('q("#usagePreset").value = "custom"; saveView()'); await h.run('loadData()');
    assert.equal(h.elements.get('#start').value, '2026-08-01');
  });
  await test('initial failed or refreshing state still loads the previous successful snapshot', async () => {
    for (const state of ['failed', 'refreshing']) {
      const h = harness();
      h.api(url => reply(url.startsWith('/api/status') ? { status: state, updated: 'old', lastError: 'synthetic failure' } : fixture()));
      await h.run('loadData()');
      assert.match(h.elements.get('#tokenCards').innerHTML, /筛选 Total/);
      assert.match(h.elements.get('#state').textContent, state === 'failed' ? /synthetic failure/ : /正在汇总/);
    }
  });
  await test('refresh remains busy through polling; failure never announces success', async () => {
    const h = harness(); let state = { status: 'ready', updated: 'old' }, posts = 0;
    h.api((url, options) => {
      if (options?.method === 'POST') { posts++; state = { status: 'refreshing', updated: 'old' }; return reply({}); }
      return reply(url.startsWith('/api/status') ? state : fixture());
    });
    await h.run('loadData()'); const prior = h.elements.get('#tokenCards').innerHTML;
    const pending = h.run('manualRefresh()'); await flush();
    assert.equal(h.elements.get('#refresh').disabled, true); assert.equal(h.run('refreshBusy'), true);
    await h.run('manualRefresh()'); assert.equal(posts, 1);
    state = { status: 'failed', updated: 'old', lastError: 'synthetic exit 9' }; h.tick(); await pending;
    assert.equal(h.elements.get('#refresh').disabled, false);
    assert.match(h.elements.get('#state').textContent, /synthetic exit 9/);
    assert.doesNotMatch(h.elements.get('#state').textContent, /刷新完成/);
    assert.equal(h.elements.get('#tokenCards').innerHTML, prior);
  });
  await test('409 joins an existing refresh and success waits for the new data version', async () => {
    const h = harness(); let state = { status: 'refreshing', updated: 'old' };
    h.api((url, options) => options?.method === 'POST' ? reply({}, 409)
      : reply(url.startsWith('/api/status') ? state : fixture()));
    const pending = h.run('manualRefresh()'); await flush();
    assert.equal(h.elements.get('#refresh').disabled, true);
    state = { status: 'ready', updated: 'old' }; h.tick(); await flush();
    assert.equal(h.elements.get('#refresh').disabled, true, 'same-version ready is not completion');
    state = { status: 'ready', updated: 'new' }; h.tick(); await pending;
    assert.equal(h.run('lastUpdated'), 'new');
    assert.equal(h.elements.get('#state').textContent, '刷新完成');
    assert.equal(h.elements.get('#refresh').disabled, false);
  });
  await test('new-version data failure propagates and preserves old charts', async () => {
    const h = harness(); let state = { status: 'ready', updated: 'old' }, dataFails = false;
    h.api((url, options) => {
      if (options?.method === 'POST') { state = { status: 'ready', updated: 'new' }; dataFails = true; return reply({}); }
      return url.startsWith('/api/status') ? reply(state) : reply(fixture(), dataFails ? 503 : 200);
    });
    await h.run('loadData()'); const prior = h.elements.get('#tokenCards').innerHTML;
    await h.run('manualRefresh()');
    assert.match(h.elements.get('#state').textContent, /503/);
    assert.doesNotMatch(h.elements.get('#state').textContent, /刷新完成/);
    assert.equal(h.run('lastUpdated'), 'old'); assert.equal(h.elements.get('#tokenCards').innerHTML, prior);
    await assert.rejects(h.run('loadData()'), /503/);
  });
  await test('version changing during data read is rejected before committing', async () => {
    const h = harness(); let statusReads = 0;
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: ++statusReads === 1 ? 'v1' : 'v2' } : fixture()));
    await assert.rejects(h.run('loadData()'), /版本变化/);
    assert.equal(h.run('D.usage.length'), 0); assert.equal(h.run('lastUpdated'), '');
  });
  await test('Skill reads render both fixed windows, source labels and escaped names', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'skills-v1' } : skillFixture()));
    await h.run('loadData()');
    const rows = h.elements.get('#skillRows').innerHTML;
    assert.equal((rows.match(/<tr>/g) || []).length, 5);
    assert.match(rows, /writer&lt;em&gt;&quot;&amp;&#39;测试/);
    assert.doesNotMatch(rows, /<em>/);
    for (const label of ['个人', '工作区', '系统', '插件', '未知']) assert.ok(rows.includes(label), label);
    assert.match(rows, /近 7 天 · 读取轮次">3<\/td>/);
    assert.match(rows, /近 7 天 · 涉及任务（会话）">2<\/td>/);
    assert.match(rows, /近 30 天 · 读取轮次">8<\/td>/);
    assert.match(rows, /近 30 天 · 涉及任务（会话）">3<\/td>/);
    assert.match(rows, /近 7 天 · 读取轮次">0<\/td>/);
    assert.match(h.elements.get('#skillRange').textContent, /2026-09-28（Asia\/Shanghai）/);
    assert.match(h.elements.get('#skillRange').textContent, /2026-09-22 至 2026-09-28/);
    assert.match(h.elements.get('#skillRange').textContent, /2026-08-30 至 2026-09-28/);
    assert.equal(h.elements.get('#skillTable').classList.contains('hidden'), false);
    assert.equal(h.elements.get('#skillEmpty').classList.contains('hidden'), true);
    assert.match(h.elements.get('#skillSummary').textContent, /共 5 个 Skill/);
  });
  await test('Skill windows ignore Token filters and switching back keeps the filters', async () => {
    const h = harness({ session: JSON.stringify({ start: '2026-08-01', end: '2026-08-31', model: 'a', effort: 'high', metric: 'cached', page: 'token' }) });
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : skillFixture()));
    await h.run('loadData()');
    const before = h.elements.get('#skillRows').innerHTML, range = h.elements.get('#skillRange').textContent;
    h.run('selectPage("skill"); saveView(); render()');
    assert.equal(h.elements.get('#usageFilters').classList.contains('hidden'), true);
    assert.equal(h.elements.get('#skill').classList.contains('hidden'), false);
    assert.equal(h.elements.get('#token').classList.contains('hidden'), true);
    h.elements.get('#start').value = '2030-01-01'; h.elements.get('#end').value = '2030-01-02';
    h.elements.get('#model').value = 'b'; h.elements.get('#effort').value = 'low'; h.run('render()');
    assert.equal(h.elements.get('#skillRows').innerHTML, before);
    assert.equal(h.elements.get('#skillRange').textContent, range);
    h.run('selectPage("eff")');
    assert.equal(h.elements.get('#usageFilters').classList.contains('hidden'), false);
    assert.equal(h.elements.get('#metricBox').classList.contains('hidden'), true);
    h.run('selectPage("token")');
    assert.equal(h.elements.get('#metricBox').classList.contains('hidden'), false);
    assert.equal(h.elements.get('#start').value, '2030-01-01');
    assert.equal(h.elements.get('#model').value, 'b');
    assert.equal(h.elements.get('#metric').value, 'cached');
  });
  await test('Skill tab survives reload, automatic update and manual refresh', async () => {
    const h = harness({ session: JSON.stringify({ start: '2026-08-01', end: '2026-08-31', page: 'skill' }) });
    let version = 'v1';
    h.api((url, options) => {
      if (options?.method === 'POST') { version = 'v3'; return reply({}); }
      return reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : skillFixture());
    });
    h.run('initialize()'); await flush();
    assert.equal(h.tabs.find(tab => tab.dataset.page === 'skill').getAttribute('aria-selected'), 'true');
    assert.equal(h.elements.get('#skill').classList.contains('hidden'), false);
    version = 'v2'; await h.run('autoRefresh()');
    assert.equal(h.elements.get('#usageFilters').classList.contains('hidden'), true);
    assert.equal(h.run('lastUpdated'), 'v2');
    await h.run('manualRefresh()');
    assert.equal(h.run('lastUpdated'), 'v3');
    assert.equal(h.elements.get('#state').textContent, '刷新完成');
    assert.equal(h.elements.get('#skill').classList.contains('hidden'), false);
    assert.equal(h.elements.get('#start').value, '2026-08-01');
    h.tabs.find(tab => tab.dataset.page === 'token').onclick();
    h.tabs.find(tab => tab.dataset.page === 'skill').onclick();
    assert.equal(h.run('JSON.parse(window.sessionStorage.getItem(VIEW_KEY)).page'), 'skill');
  });
  await test('missing Skill snapshot is unavailable while an empty valid snapshot is explicitly inconclusive', async () => {
    const h = harness({ session: JSON.stringify({ page: 'skill' }) }); let data = fixture();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data));
    await h.run('loadData()');
    assert.equal(h.elements.get('#skillTable').classList.contains('hidden'), true);
    assert.match(h.elements.get('#skillEmpty').textContent, /未提供.*不能按零次解读/);
    assert.equal(h.elements.get('#skillRows').innerHTML, '');
    data = skillFixture(); data.skills.rows = [];
    await h.run('loadData()');
    assert.match(h.elements.get('#skillEmpty').textContent, /没有可识别.*不代表未使用/);
    assert.doesNotMatch(h.elements.get('#skillEmpty').textContent, /未提供/);
    assert.equal(h.elements.get('#skillTable').classList.contains('hidden'), true);
    assert.equal(h.elements.get('#skillEmpty').classList.contains('hidden'), false);
    assert.match(h.elements.get('#skillRange').textContent, /Asia\/Shanghai/);
  });
  await test('malformed Skill schema is rejected before replacing the previous complete snapshot', async () => {
    const h = harness(); let version = 'v1', data = skillFixture();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    await h.run('loadData()');
    const prior = h.elements.get('#skillRows').innerHTML;
    const mutations = [
      d => { d.skills = null; }, d => { d.skills = []; },
      d => { d.skills.metric = 'skill_calls'; }, d => { d.skills.scope = 'all_agents'; },
      d => { d.skills.timeZone = 'UTC'; }, d => { d.skills.asOf = '2026-02-30'; },
      d => { d.skills.windows = null; }, d => { d.skills.windows.days7.start = '2026-09-21'; },
      d => { d.skills.windows.days30.end = '2026-09-27'; }, d => { d.skills.rows = {}; },
      d => { d.skills.rows[0] = null; }, d => { d.skills.rows[0].skill = ''; },
      d => { d.skills.rows[0].source = '__proto__'; }, d => { d.skills.rows[0].source = '<img>'; },
      d => { d.skills.rows[0].readTurns7 = '3'; }, d => { d.skills.rows[0].readTurns7 = -1; },
      d => { d.skills.rows[0].tasks7 = 1.5; }, d => { d.skills.rows[0].tasks7 = 4; },
      d => { d.skills.rows[0].readTurns30 = 2; }, d => { d.skills.rows[0].tasks30 = 1; },
      d => { delete d.skills.rows[0].tasks30; }, d => { d.skills.rows[0].readTurns30 = Infinity; }
    ];
    version = 'v2';
    for (const mutate of mutations) {
      data = skillFixture(); mutate(data);
      await assert.rejects(h.run('loadData()'), /Skill 说明读取数据格式无效/);
      assert.equal(h.run('lastUpdated'), 'v1');
      assert.equal(h.elements.get('#skillRows').innerHTML, prior);
    }
    await h.run('autoRefresh()');
    assert.match(h.elements.get('#state').textContent, /Skill 说明读取数据格式无效/);
    assert.doesNotMatch(h.elements.get('#state').textContent, /刷新完成/);
  });
  await test('Skill activity overview unions turns and main tasks across Skills and dates', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'activity-v1' } : activityFixture()));
    await h.run('loadData()');
    const report = JSON.parse(h.run('JSON.stringify(buildSkillReport(D.skills, skillView))'));
    assert.deepEqual(report.summary, { activeSkills: 6, readTurns: 4, mainTasks: 3, skillTurnRecords: 7 });
    assert.equal(report.catalogSkills, 7); assert.equal(report.rows.length, 7);
    assert.equal(report.rows.find(row => row.skill === 'archive').readTurns, 0);
    assert.equal(report.rows.find(row => row.skill === 'alpha').lastObservedDate, '2026-09-23');
    assert.equal(report.trend.length, 30);
    assert.deepEqual(report.trend.filter(row => row.readTurns).map(row => row.readTurns), [1, 1, 1, 1, 1]);
    assert.equal(report.trend.find(row => row.date === '2026-09-25').readTurns, 0);
    assert.equal(report.trend.reduce((sum, row) => sum + row.readTurns, 0), 5, 'daily sum can exceed the interval turn union');
    assert.equal(report.sources.reduce((sum, row) => sum + row.activeSkills, 0), 6);
    assert.match(h.elements.get('#skillCards').innerHTML, /包含读取的轮次/);
    assert.match(h.elements.get('#skillSummary').textContent, /非完整安装清单/);
    assert.equal(h.elements.get('#skillExport').disabled, false);
    assert.equal(h.elements.get('#skillCards').classList.contains('hidden'), false);
    assert.match(h.elements.get('#skillRows').innerHTML, /本期未观测/);
  });
  await test('Skill filters select objective audit clues and reset restores the entire current window', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : activityFixture()));
    h.run('initialize()'); await flush();
    const report = () => JSON.parse(h.run('JSON.stringify(buildSkillReport(D.skills, skillView))'));
    h.elements.get('#skillObservation').value = 'unobserved'; h.elements.get('#skillObservation').onchange();
    assert.deepEqual(report().rows.map(row => row.skill), ['archive']);
    assert.deepEqual(report().summary, { activeSkills: 0, readTurns: 0, mainTasks: 0, skillTurnRecords: 0 });
    h.elements.get('#skillObservation').value = 'duplicate'; h.elements.get('#skillObservation').onchange();
    assert.deepEqual(report().rows.map(row => row.skill), ['alpha', 'pack:alpha']);
    h.elements.get('#skillObservation').value = 'single'; h.elements.get('#skillObservation').onchange();
    assert.equal(report().rows.length, 5); assert.equal(report().summary.readTurns, 3);
    h.elements.get('#skillObservation').value = 'unknown'; h.elements.get('#skillObservation').onchange();
    assert.equal(report().rows[0].skill, 'mystery');
    h.elements.get('#skillObservation').value = 'active'; h.elements.get('#skillObservation').onchange();
    assert.equal(report().rows.length, 6);
    h.elements.get('#skillObservation').value = 'all'; h.elements.get('#skillObservation').onchange();
    h.elements.get('#skillSource').value = 'personal'; h.elements.get('#skillSource').onchange();
    assert.equal(report().rows.length, 2); assert.equal(report().summary.mainTasks, 2);
    h.elements.get('#skillSource').value = 'all'; h.elements.get('#skillSource').onchange();
    h.elements.get('#skillSearch').value = ' ALPHA '; h.elements.get('#skillSearch').oninput();
    assert.equal(report().rows.length, 2);
    h.elements.get('#skillSearch').value = ''; h.elements.get('#skillSearch').oninput();
    h.elements.get('#skillSort').value = 'readsAsc'; h.elements.get('#skillSort').onchange();
    assert.equal(report().rows[0].skill, 'archive');
    h.elements.get('#skillPreset').value = 'all'; h.elements.get('#skillPreset').onchange();
    assert.equal(h.elements.get('#skillStart').value, '2026-08-10'); assert.equal(report().summary.activeSkills, 7);
    h.elements.get('#skillReset').onclick();
    assert.equal(h.elements.get('#skillPreset').value, 'days30'); assert.equal(h.elements.get('#skillStart').value, '2026-08-30');
    assert.equal(h.elements.get('#skillSource').value, 'all'); assert.equal(h.elements.get('#skillObservation').value, 'all');
    assert.equal(h.elements.get('#skillSearch').value, ''); assert.equal(h.elements.get('#skillSort').value, 'reads');
    assert.equal(report().rows.length, 7);
  });
  await test('Skill custom dates and filters persist separately; presets advance with the snapshot day', async () => {
    const h = harness({ session: JSON.stringify({ start: '2026-08-01', end: '2026-08-31', page: 'skill' }) });
    let data = activityFixture(), version = 'v1';
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    h.run('initialize()'); await flush();
    h.elements.get('#skillPreset').value = 'days7'; h.elements.get('#skillPreset').onchange();
    assert.equal(h.elements.get('#skillStart').value, '2026-09-22');
    data.skills.asOf = '2026-09-29'; data.skills.windows = { days7: { start: '2026-09-23', end: '2026-09-29' }, days30: { start: '2026-08-31', end: '2026-09-29' } };
    version = 'v2'; await h.run('autoRefresh()');
    assert.equal(h.elements.get('#skillStart').value, '2026-09-23');
    h.elements.get('#skillStart').value = '2026-09-21'; h.elements.get('#skillEnd').value = '2026-09-22'; h.elements.get('#skillEnd').onchange();
    h.elements.get('#skillSource').value = 'personal'; h.elements.get('#skillSource').onchange();
    h.elements.get('#skillSearch').value = 'alpha'; h.elements.get('#skillSearch').oninput();
    h.elements.get('#skillSort').value = 'name'; h.elements.get('#skillSort').onchange();
    assert.equal(h.elements.get('#skillPreset').value, 'custom');
    const saved = h.run('window.sessionStorage.getItem(VIEW_KEY)');
    const reloaded = harness({ session: saved });
    reloaded.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    await reloaded.run('loadData()');
    assert.equal(reloaded.elements.get('#skillStart').value, '2026-09-21');
    assert.equal(reloaded.elements.get('#skillEnd').value, '2026-09-22');
    assert.equal(reloaded.elements.get('#skillSource').value, 'personal'); assert.equal(reloaded.elements.get('#skillSearch').value, 'alpha');
    assert.equal(reloaded.elements.get('#skillSort').value, 'name'); assert.equal(reloaded.elements.get('#start').value, '2026-08-01');
    version = 'v3'; await reloaded.run('autoRefresh()');
    assert.equal(reloaded.elements.get('#skillStart').value, '2026-09-21'); assert.equal(reloaded.elements.get('#end').value, '2026-08-31');
    assert.equal(JSON.parse(reloaded.run('JSON.stringify(skillAuditSnapshot())')).summary.readTurns, 1);
  });
  await test('Skill audit export equals the filtered overview and contains no activity or identity aliases', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : activityFixture()));
    await h.run('loadData()');
    h.run('restoreSkillView({preset:"custom",start:"2026-09-21",end:"2026-09-22",search:"alpha",source:"personal",observation:"active",sort:"name"}); renderSkills()');
    const snapshot = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.deepEqual(snapshot.summary, { activeSkills: 1, readTurns: 1, mainTasks: 1, skillTurnRecords: 1 });
    assert.equal(snapshot.filters.preset, 'custom'); assert.equal(snapshot.filters.start, '2026-09-21'); assert.equal(snapshot.filters.end, '2026-09-22');
    assert.equal(snapshot.filters.source, 'personal'); assert.equal(snapshot.filters.search, 'alpha');
    assert.equal(snapshot.rows.length, 1); assert.equal(snapshot.rows[0].readTurns, 1);
    assert.deepEqual(snapshot.trend, [{ date: '2026-09-21', readTurns: 1 }, { date: '2026-09-22', readTurns: 1 }]);
    const forbidden = new Set(['activity', 'task', 'turn', 'session_id', 'turn_id', 'path', 'cmd', 'arguments']);
    function check(value) { if (!value || typeof value !== 'object') return; for (const [key, item] of Object.entries(value)) { assert.equal(forbidden.has(key), false, key); check(item); } }
    check(snapshot);
    assert.doesNotMatch(JSON.stringify(snapshot), /[a-z]:[\\/]|\/Users\/|\/home\//i);
    assert.ok(snapshot.boundaries.some(note => note.includes('不代表实际调用或任务成功')));
  });
  await test('historical audit catalog and last observation exclude later knowledge; long trends preserve calendar positions', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : activityFixture()));
    await h.run('loadData()');
    h.run('restoreSkillView({preset:"custom",start:"2026-09-21",end:"2026-09-22"}); renderSkills()');
    const historical = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.deepEqual(historical.rows.map(row => row.skill).sort(), ['alpha', 'archive', 'beta']);
    assert.equal(historical.rows.find(row => row.skill === 'alpha').lastObservedDate, '2026-09-22');
    assert.equal(historical.rows.some(row => row.observations.some(note => note.includes('同名多处'))), false);
    h.run('restoreSkillView({preset:"custom",start:"2000-01-01",end:"2026-09-28"}); renderSkills()');
    const long = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.equal(long.trendMode, 'sparse_calendar'); assert.ok(long.trend.length <= 9);
    assert.equal(h.elements.get('#skillFirst').textContent, '2000-01-01'); assert.equal(h.elements.get('#skillLast').textContent, '2026-09-28');
    assert.match(h.elements.get('#skillTrend').innerHTML, /style="left:/);
    assert.equal(h.elements.get('#skillTrend').classList.contains('skill-sparse'), true);
  });
  await test('Skill invalid ranges and no matches are explicit; old and empty activity snapshots never invent totals', async () => {
    const h = harness(); let data = activityFixture();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data));
    h.run('initialize()'); await flush();
    h.elements.get('#skillStart').value = '2026-09-29'; h.elements.get('#skillEnd').value = '2026-09-28'; h.elements.get('#skillStart').onchange();
    assert.equal(h.elements.get('#skillExport').disabled, true); assert.match(h.elements.get('#skillEmpty').textContent, /开始日期晚于/);
    assert.throws(() => h.run('skillAuditSnapshot()'), /开始日期晚于/);
    h.elements.get('#skillReset').onclick();
    h.elements.get('#skillSearch').value = 'no-such-skill'; h.elements.get('#skillSearch').oninput();
    assert.match(h.elements.get('#skillEmpty').textContent, /当前筛选没有匹配/);
    h.elements.get('#skillReset').onclick();
    data = skillFixture(); await h.run('loadData()');
    assert.equal(h.elements.get('#skillExport').disabled, true); assert.equal(h.elements.get('#skillPreset').disabled, true);
    assert.equal(h.elements.get('#skillCards').classList.contains('hidden'), true);
    assert.match(h.elements.get('#skillLegacyNotice').textContent, /不能把各 Skill 的任务数相加/);
    assert.throws(() => h.run('skillAuditSnapshot()'), /刷新/);
    data = activityFixture(); data.skills.activity = []; data.skills.rows = []; await h.run('loadData()');
    assert.match(h.elements.get('#skillEmpty').textContent, /没有可识别.*不代表未使用/);
    assert.equal(h.elements.get('#skillPreset').disabled, false);
    assert.deepEqual(JSON.parse(h.run('JSON.stringify(skillAuditSnapshot().summary)')), { activeSkills: 0, readTurns: 0, mainTasks: 0, skillTurnRecords: 0 });
  });
  await test('invalid activity aliases, dates, duplicate records and conflicting ownership preserve the prior snapshot', async () => {
    const h = harness(); let data = activityFixture(), version = 'v1';
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    await h.run('loadData()'); const prior = h.elements.get('#skillCards').innerHTML;
    const mutations = [
      d => { delete d.skills.activitySchema; }, d => { d.skills.activitySchema = 2; }, d => { delete d.skills.activity; },
      d => { d.skills.activity = {}; }, d => { d.skills.activity[0] = null; },
      d => { d.skills.activity[0].date = '2026-02-30'; }, d => { d.skills.activity[0].date = '2026-09-29'; },
      d => { d.skills.activity[0].source = '__proto__'; }, d => { d.skills.activity[0].task = 0; },
      d => { d.skills.activity[0].turn = -1; }, d => { d.skills.activity[0].task = 1.5; },
      d => { d.skills.activity[0].turn = '90'; }, d => { d.skills.activity[0].turn = Number.MAX_SAFE_INTEGER + 1; },
      d => { d.skills.activity.push({ ...d.skills.activity[0] }); }, d => { d.skills.activity[2].task = 99; },
      d => { d.skills.activity[0].skill = 'C:/private/SKILL.md'; }, d => { d.skills.rows.push({ ...d.skills.rows[0] }); }
    ];
    version = 'v2';
    for (const mutate of mutations) {
      data = activityFixture(); mutate(data);
      await assert.rejects(h.run('loadData()'), /Skill 说明读取数据格式无效/);
      assert.equal(h.run('lastUpdated'), 'v1'); assert.equal(h.elements.get('#skillCards').innerHTML, prior);
    }
  });
  await test('refresh cost labels distinguish file volume from exact I/O and preserve older snapshots', async () => {
    const h = harness(); const data = fixture();
    data.refresh.sourceBytesRead = 1048576; data.refresh.elapsedMs = 12500;
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data));
    await h.run('loadData()');
    assert.match(h.elements.get('#cacheInfo').textContent, /本次重解析文件体积 1.0 MiB（按文件大小估算）/);
    assert.match(h.elements.get('#cacheInfo').textContent, /汇总阶段耗时 12.5 秒/);
  });
  await test('Skill trend has integer quantity ticks, visible values and zero-day readouts for pointer, focus and date controls', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : activityFixture()));
    h.run('initialize()'); await flush();
    assert.equal(h.run('JSON.stringify(skillCountScale(19))'), '{"top":20,"ticks":[20,15,10,5,0]}');
    assert.equal(h.run('JSON.stringify(skillCountScale(0))'), '{"top":1,"ticks":[1,0]}');
    assert.match(h.elements.get('#skillYAxis').innerHTML, /skill-y-tick/);
    assert.match(h.elements.get('#skillYAxis').innerHTML, />0<\/span>/);
    assert.match(h.elements.get('#skillTrend').innerHTML, /<button type="button" class="barcol skill-day/);
    assert.match(h.elements.get('#skillTrend').innerHTML, /aria-label="2026-09-25 · 0 轮"/);
    assert.match(h.elements.get('#skillTrend').innerHTML, /class="skill-bar-value"/);
    const point = { dataset: { date: '2026-09-25' } };
    h.elements.get('#skillTrend').onpointermove({ pointerType: 'mouse', target: { closest: () => point } });
    assert.equal(h.elements.get('#skillTrendReadout').textContent, '2026-09-25 · 0 轮（无可观测读取）');
    point.dataset.date = '2026-09-22'; h.elements.get('#skillTrend').onfocusin({ target: { closest: () => point } });
    assert.match(h.elements.get('#skillTrendReadout').textContent, /2026-09-22 · 1 轮/);
    point.dataset.date = '2026-09-26'; h.elements.get('#skillTrend').onclick({ target: { closest: () => point } });
    assert.match(h.elements.get('#skillTrendReadout').textContent, /2026-09-26 · 0 轮/);
    h.elements.get('#skillInspectDate').value = '2026-09-23'; h.elements.get('#skillInspectDate').onchange();
    assert.match(h.elements.get('#skillTrendReadout').textContent, /2026-09-23 · 1 轮/);
    h.elements.get('#skillDayNext').onclick(); assert.match(h.elements.get('#skillTrendReadout').textContent, /2026-09-24 · 1 轮/);
    h.elements.get('#skillDayPrev').onclick(); assert.match(h.elements.get('#skillTrendReadout').textContent, /2026-09-23 · 1 轮/);
    let prevented = false;
    h.elements.get('#skillTrend').onkeydown({ key: 'Home', preventDefault() { prevented = true; } });
    assert.equal(prevented, true); assert.equal(h.elements.get('#skillDayPrev').disabled, true);
    assert.match(h.elements.get('#skillTrendReadout').textContent, /2026-08-30 · 0 轮/);
    h.run('restoreSkillView({preset:"custom",start:"2000-01-01",end:"2026-09-28"});renderSkills();selectSkillDay("2001-06-01")');
    assert.equal(h.elements.get('#skillTrendReadout').textContent, '2001-06-01 · 0 轮（无可观测读取）');
  });
  await test('current metadata joins descriptions without changing historical counts; description and display-name search work', async () => {
    const h = harness(); let data = activityFixture();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data));
    await h.run('loadData()');
    const before = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    data = metadataFixture(); await h.run('loadData()');
    const after = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.deepEqual(after.summary, before.summary); assert.deepEqual(after.trend, before.trend);
    assert.equal(after.metadataAsOf, '2026-10-01'); assert.equal(after.asOf, '2026-09-28');
    assert.match(h.elements.get('#skillMetadataNote').textContent, /2026-10-01.*不是历史版本.*不改变历史读取计数/);
    assert.match(h.elements.get('#skillRows').innerHTML, /展开完整简介/);
    assert.match(h.elements.get('#skillRows').innerHTML, /完整尾句/);
    assert.match(h.elements.get('#skillRows').innerHTML, /&lt;script&gt;doNotRun\(\)&lt;\/script&gt;/);
    assert.doesNotMatch(h.elements.get('#skillRows').innerHTML, /<script>/);
    assert.match(h.elements.get('#skillRows').innerHTML, /当前未取得可用的本地说明/);
    assert.match(h.elements.get('#skillRows').innerHTML, /存在多份本地说明，简介待确认/);
    assert.match(h.elements.get('#skillRows').innerHTML, /当前没有可展示的简介/);
    h.run('restoreSkillView({search:"财务对账"});renderSkills()');
    const searched = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.deepEqual(searched.rows.map(row => row.skill), ['alpha']);
    assert.equal(searched.rows[0].metadataStatus, 'available');
    assert.equal(searched.rows[0].currentName, '研究助手'); assert.match(searched.rows[0].currentDescription, /完整尾句/);
    assert.deepEqual(searched.summary, { activeSkills: 1, readTurns: 2, mainTasks: 2, skillTurnRecords: 2 });
    h.run('restoreSkillView({search:"图像工具"});renderSkills()');
    assert.deepEqual(JSON.parse(h.run('JSON.stringify(skillAuditSnapshot().rows.map(row=>row.skill))')), ['imagegen']);
    h.run('restoreSkillView({preset:"custom",start:"2026-09-21",end:"2026-09-22",search:"财务对账"});renderSkills()');
    const historic = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.equal(historic.summary.readTurns, 1); assert.equal(historic.rows[0].lastObservedDate, '2026-09-22');
    assert.equal(historic.metadataAsOf, '2026-10-01'); assert.match(historic.rows[0].currentDescription, /财务对账/);
    assert.doesNotMatch(JSON.stringify(historic), /"(?:activity|task|turn|path|session_id|turn_id)"\s*:/);
    data = activityFixture(); h.run('restoreSkillView()'); await h.run('loadData()');
    assert.match(h.elements.get('#skillMetadataNote').textContent, /暂无本地简介/);
    assert.equal(JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())')).metadataAsOf, null);
  });
  await test('invalid metadata is rejected before replacing counts while safe public URL text remains plain content', async () => {
    const h = harness(); let data = metadataFixture(), version = 'v1';
    data.skills.metadata.find(row => row.skill === 'pack:alpha').description = '参考公开资料 https://example.com/guide 。';
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    await h.run('loadData()'); const before = h.elements.get('#skillRows').innerHTML;
    const mutations = [
      d => { delete d.skills.metadataSchema; }, d => { d.skills.metadataSchema = 2; }, d => { delete d.skills.metadataAsOf; },
      d => { d.skills.metadataAsOf = '2026-02-30'; }, d => { d.skills.metadata = {}; }, d => { d.skills.metadata[0] = null; },
      d => { d.skills.metadata[0].source = 'elsewhere'; }, d => { d.skills.metadata[0].status = 'ok'; },
      d => { d.skills.metadata[0].name = 7; }, d => { d.skills.metadata[0].description = null; },
      d => { d.skills.metadata[0].name = 'unexpected missing name'; }, d => { d.skills.metadata.pop(); },
      d => { d.skills.metadata.push({ ...d.skills.metadata[0] }); }, d => { d.skills.metadata[0].skill = 'new-unobserved-skill'; },
      d => { d.skills.metadata.find(row => row.skill === 'alpha').description = '打开 C:/private/SKILL.md'; }
    ];
    version = 'v2';
    for (const mutate of mutations) {
      data = metadataFixture(); mutate(data);
      await assert.rejects(h.run('loadData()'), /Skill 说明读取数据格式无效/);
      assert.equal(h.run('lastUpdated'), 'v1'); assert.equal(h.elements.get('#skillRows').innerHTML, before);
    }
  });
  await test('local Chinese interpretation requires exact source, Skill and original text; raw descriptions remain exportable', async () => {
    const original = 'Review evidence and preserve the original audit records.';
    const zh = '整理证据并保留原始审计记录；这是中文释义。';
    const h = harness({ translations: { 'personal|alpha': { original, zh }, 'plugin|alpha': { original: 'different original', zh: '不应生效' } } });
    let data = metadataFixture(), version = 'v1';
    data.skills.metadata.find(row => row.skill === 'alpha').description = original;
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    await h.run('loadData()');
    const before = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    const row = before.rows.find(row => row.skill === 'alpha');
    assert.equal(row.currentDescription, original); assert.equal(row.currentDescriptionZh, zh);
    assert.match(h.elements.get('#skillRows').innerHTML, /展开中英对照/);
    assert.match(h.elements.get('#skillRows').innerHTML, /英文原文/);
    assert.match(h.elements.get('#skillRows').innerHTML, /不是 Skill 源文件内容/);
    assert.equal(before.rows.find(row => row.skill === 'pack:alpha').currentDescriptionZh, '', 'Chinese originals stay unchanged');
    h.run('restoreSkillView({search:"保留原始审计"});renderSkills()');
    const searched = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.deepEqual(searched.rows.map(row => row.skill), ['alpha']);
    assert.equal(searched.rows[0].currentDescription, original); assert.equal(searched.rows[0].currentDescriptionZh, zh);
    h.data({ skill: 'alpha', source: 'workspace', status: 'available', description: original, name: '' });
    assert.equal(h.run('currentSkillMetadata(synthetic).currentDescriptionZh'), '', 'source isolation');
    h.data({ skill: 'alpha', source: 'plugin', status: 'available', description: original, name: '' });
    assert.equal(h.run('currentSkillMetadata(synthetic).currentDescriptionZh'), '', 'exact original text is mandatory');
    data.skills.metadata.find(row => row.skill === 'alpha').description = original + ' Revised.'; version = 'v2';
    h.run('resetSkillFilters()'); await h.run('autoRefresh()');
    const updated = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.equal(updated.rows.find(row => row.skill === 'alpha').currentDescriptionZh, '');
    assert.deepEqual(updated.summary, before.summary); assert.deepEqual(updated.trend, before.trend);
    assert.ok(updated.boundaries.some(text => text.includes('currentDescriptionZh') && text.includes('原文变化')));
  });
  await test('Token and Skill date presets share calendar definitions but keep defaults and scopes separate', async () => {
    const h = harness(); let data = activityFixture(), version = 'v1';
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data));
    h.run('initialize()'); await flush();
    assert.equal(h.elements.get('#usagePreset').value, 'month'); assert.equal(h.elements.get('#start').value, '2026-09-01');
    assert.equal(h.elements.get('#skillPreset').value, 'days30'); assert.equal(h.elements.get('#skillStart').value, '2026-08-30');
    for (const [preset, start] of [['today', '2026-09-28'], ['days7', '2026-09-22'], ['days30', '2026-08-30'], ['month', '2026-09-01']]) {
      h.elements.get('#usagePreset').value = preset; h.elements.get('#usagePreset').onchange();
      h.elements.get('#skillPreset').value = preset; h.elements.get('#skillPreset').onchange();
      assert.equal(h.elements.get('#start').value, start); assert.equal(h.elements.get('#skillStart').value, start);
      assert.equal(h.elements.get('#end').value, '2026-09-28'); assert.equal(h.elements.get('#skillEnd').value, '2026-09-28');
    }
    h.elements.get('#usagePreset').value = 'all'; h.elements.get('#usagePreset').onchange();
    h.elements.get('#skillPreset').value = 'all'; h.elements.get('#skillPreset').onchange();
    assert.equal(h.elements.get('#start').value, '2026-08-20'); assert.equal(h.elements.get('#skillStart').value, '2026-08-10');
    h.elements.get('#usagePreset').value = 'custom'; h.elements.get('#usagePreset').onchange();
    assert.equal(h.elements.get('#start').value, '2026-08-20', 'custom selection preserves the displayed range');
    h.elements.get('#reset').onclick(); h.elements.get('#skillReset').onclick();
    assert.equal(h.elements.get('#usagePreset').value, 'month'); assert.equal(h.elements.get('#skillPreset').value, 'days30');
    assert.match(h.elements.get('#model').innerHTML, /全部模型/); assert.match(h.elements.get('#effort').innerHTML, /全部推理强度/);
    data.skills.asOf = '2026-10-02'; data.skills.windows = { days7: { start: '2026-09-26', end: '2026-10-02' }, days30: { start: '2026-09-03', end: '2026-10-02' } };
    version = 'v2'; await h.run('autoRefresh()');
    assert.equal(h.elements.get('#start').value, '2026-10-01'); assert.equal(h.elements.get('#end').value, '2026-10-02');
    assert.equal(h.elements.get('#skillStart').value, '2026-09-03');
    h.elements.get('#start').value = '2026-08-01'; h.elements.get('#end').value = '2026-08-31'; h.elements.get('#start').onchange();
    assert.equal(h.elements.get('#usagePreset').value, 'custom'); h.run('selectPage("eff");saveView()');
    const reload = harness({ session: h.run('window.sessionStorage.getItem(VIEW_KEY)') });
    reload.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v3' } : data));
    await reload.run('loadData()');
    assert.equal(reload.elements.get('#start').value, '2026-08-01'); assert.equal(reload.elements.get('#end').value, '2026-08-31');
    assert.equal(reload.elements.get('#usagePreset').value, 'custom'); assert.equal(reload.elements.get('#eff').classList.contains('hidden'), false);
  });
  await test('both date filters expose missing, inverted and future ranges instead of showing misleading zero totals', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : activityFixture()));
    h.run('initialize()'); await flush();
    for (const [start, end, message] of [['', '2026-09-28', /完整/], ['2026-09-28', '2026-09-27', /晚于/], ['2026-09-28', '2026-09-29', /截至日/]]) {
      h.elements.get('#start').value = start; h.elements.get('#end').value = end; h.elements.get('#start').onchange();
      assert.match(h.elements.get('#usageRangeError').textContent, message); assert.equal(h.elements.get('#token').classList.contains('hidden'), true);
      assert.equal(h.elements.get('#usageRangeError').classList.contains('hidden'), false);
      h.elements.get('#skillStart').value = start; h.elements.get('#skillEnd').value = end; h.elements.get('#skillStart').onchange();
      assert.match(h.elements.get('#skillEmpty').textContent, message); assert.equal(h.elements.get('#skillCards').classList.contains('hidden'), true);
    }
    h.elements.get('#start').value = ''; h.elements.get('#start').onchange();
    h.elements.get('#skillStart').value = ''; h.elements.get('#skillStart').onchange();
    await h.run('loadData()');
    assert.equal(h.elements.get('#usagePreset').value, 'custom'); assert.equal(h.elements.get('#start').value, '');
    assert.equal(h.elements.get('#skillPreset').value, 'custom'); assert.equal(h.elements.get('#skillStart').value, '');
    h.elements.get('#reset').onclick(); h.elements.get('#skillReset').onclick();
    assert.equal(h.elements.get('#token').classList.contains('hidden'), false); assert.equal(h.elements.get('#skillCards').classList.contains('hidden'), false);
  });
  await test('dialog opens with focus and Escape restores the trigger', async () => {
    const h = harness();
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : fixture()));
    h.run('initialize()'); await flush();
    h.elements.get('#infoButton').focus(); h.run('openInfo()');
    assert.equal(h.focus().id, 'info-close');
    assert.equal(h.elements.get('#infoModal').classList.contains('hidden'), false);
    h.events.keydown({ key: 'Escape' });
    assert.equal(h.elements.get('#infoModal').classList.contains('hidden'), true);
    assert.equal(h.focus().id, 'infoButton');
  });
  await test('inventory scope adds current definitions without adding historical reads', async () => {
    const h = harness(), data = metadataFixture();
    data.skills.inventorySchema = 1; data.skills.inventoryAsOf = '2026-10-01'; data.skills.inventoryScope = 'known_local_skill_roots';
    data.skills.inventory = [{ skill: 'alpha', source: 'personal', status: 'available', name: '研究助手', description: '财务对账', copies: 1 },
      { skill: 'fresh-report', source: 'personal', status: 'available', name: '报告工具', description: '报告交付', copies: 1 },
      { skill: 'duplicate', source: 'plugin', status: 'ambiguous', name: '', description: '', copies: 2 }];
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data)); await h.run('loadData()');
    const before = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    h.run('restoreSkillView({scope:"combined"});renderSkills()');
    const combined = JSON.parse(h.run('JSON.stringify(skillAuditSnapshot())'));
    assert.equal(combined.rows.find(row => row.skill === 'fresh-report').readTurns, 0);
    assert.equal(combined.rows.find(row => row.skill === 'fresh-report').lastObservedDate, null);
    assert.equal(combined.rows.find(row => row.skill === 'archive').directoryState, 'not_found');
    assert.deepEqual(combined.summary, before.summary); assert.deepEqual(combined.trend, before.trend);
    h.run('restoreSkillView({scope:"inventory",observation:"currentUnread"});renderSkills()');
    assert.deepEqual(JSON.parse(h.run('JSON.stringify(skillAuditSnapshot().rows.map(row=>row.skill))')), ['duplicate', 'fresh-report']);
    assert.match(h.elements.get('#skillMetadataNote').textContent, /2026-10-01.*2026-09-28/);
    h.run('restoreSkillView({scope:"combined",category:"product"});renderSkills()');
    assert.equal(JSON.parse(h.run('JSON.stringify(skillAuditSnapshot().rows.length)')), 0);
  });
  await test('saved combinations revalidate and task text stays outside local storage', async () => {
    const h = harness(), data = activityFixture();
    data.skills.inventorySchema = 1; data.skills.inventoryAsOf = '2026-09-28'; data.skills.inventoryScope = 'known_local_skill_roots';
    data.skills.inventory = [{ skill: 'alpha', source: 'personal', status: 'available', name: '研究助手', description: '分析', copies: 1 },
      { skill: 'alpha', source: 'plugin', status: 'available', name: '另一个工具', description: '分析', copies: 1 },
      { skill: 'conflict', source: 'plugin', status: 'ambiguous', name: '', description: '', copies: 2 }];
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data)); await h.run('loadData()');
    h.run('skillSelected.add(skillKey(D.skills.inventory[0]));skillSelected.add(skillKey(D.skills.inventory[1]))');
    h.elements.get('#skillTask').value = '本轮敏感任务正文'; h.run('updateSkillPromptState()');
    assert.match(h.elements.get('#skillPromptPreview').value, /本轮敏感任务正文/);
    h.elements.get('#skillBundleName').value = '双来源'; h.run('saveSkillBundle()');
    assert.doesNotMatch(h.run('window.localStorage.getItem(BUNDLE_KEY)'), /本轮敏感任务正文/);
    assert.equal(JSON.parse(h.run('JSON.stringify(skillBundles[0].skills)')).length, 2);
    data.skills.inventory = [data.skills.inventory[0]]; await h.run('loadData()');
    assert.equal(h.elements.get('#skillCopyPrompt').disabled, true); assert.equal(h.elements.get('#skillPromptPreview').value, '');
    assert.match(h.elements.get('#skillChoices').innerHTML, /移除失效项/);
    h.run('clearStaleSkills()'); assert.equal(h.elements.get('#skillCopyPrompt').disabled, false);
    h.run('loadSkillBundle(0)'); assert.equal(h.elements.get('#skillBundleName').value, '双来源'); h.run('clearStaleSkills()');
    h.run('skillBundles = Array.from({length:20},(_,i)=>({name:"组合"+i,skills:[{skill:"alpha",source:"personal"}]}));skillBundleIndex=-1');
    h.elements.get('#skillBundleName').value = '第21组'; h.run('saveSkillBundle()');
    assert.equal(h.run('skillBundles.length'), 20); assert.match(h.elements.get('#skillComposerState').textContent, /最多保存 20 组/);
    h.run('loadSkillBundle(0);deleteSkillBundle()'); assert.equal(h.run('skillBundles.length'), 19);
    const disabled = harness({ storageThrows: true });
    disabled.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: 'v1' } : data)); disabled.run('initialize()'); await flush();
    disabled.run('skillSelected.add(skillKey(D.skills.inventory[0]))'); disabled.elements.get('#skillBundleName').value = '暂存'; disabled.run('saveSkillBundle()');
    assert.match(disabled.elements.get('#skillComposerState').textContent, /仅在本页暂存/);
  });
  await test('invalid inventory is rejected and old snapshots keep history-only controls', async () => {
    const h = harness(); let data = activityFixture(), version = 'v1';
    h.api(url => reply(url.startsWith('/api/status') ? { status: 'ready', updated: version } : data)); await h.run('loadData()');
    assert.equal(h.elements.get('#skillScope').disabled, true);
    assert.match(h.elements.get('#skillFilterMessage').textContent, /没有当前目录数据/);
    data = activityFixture(); data.skills.inventorySchema = 1; data.skills.inventoryAsOf = '2026-09-28';
    data.skills.inventoryScope = 'known_local_skill_roots';
    data.skills.inventory = [{ skill: 'alpha', source: 'personal', status: 'available', name: '', description: '', copies: 1 }];
    version = 'v2'; await h.run('loadData()'); assert.equal(h.elements.get('#skillScope').disabled, false);
    const prior = h.run('lastUpdated');
    data.skills.inventory[0].copies = 0; version = 'v3';
    await assert.rejects(h.run('loadData()'), /Skill 说明读取数据格式无效/);
    assert.equal(h.run('lastUpdated'), prior);
  });
  console.log(`Frontend behavior checks passed: ${count}. Browser layout acceptance remains separate.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
