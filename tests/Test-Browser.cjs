// Real-browser acceptance against loopback, or an isolated synthetic browser route.
// node tests/Test-Browser.cjs [--playwright <package-path>] [--synthetic] [--refresh]
// --synthetic serves current sources through Playwright routing; it creates no service.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const args = process.argv.slice(2);
const option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
const { chromium } = require(option('--playwright') || 'playwright');
const url = option('--url') || 'http://127.0.0.1:8765';
assert.equal(new URL(url).hostname, '127.0.0.1', 'Acceptance is restricted to loopback');
const synthetic = args.includes('--synthetic');
const output = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-dashboard-browser-'));
const sources = { personal: '个人', workspace: '工作区', system: '系统', plugin: '插件', unknown: '未知' };
const identity = row => row.source + '\u0000' + row.skill;
const dayMs = 86400000;
const translationScript = fs.readFileSync(path.join(__dirname, '..', 'web', 'skill-descriptions.zh-CN.js'), 'utf8');
const localTranslations = vm.runInNewContext(translationScript + '\nSKILL_DESCRIPTION_ZH;');
const syntheticEnglish = 'Review audit evidence and preserve observable usage counts. ' + 'Summarize the business context for human review. '.repeat(7) + '<strong>Plain text only.</strong>';
const syntheticChinese = '整理审计证据，保留可观测的使用统计，概括业务背景供人工复核。中文是本地释义，不替代英文原文。';
const syntheticTranslations = { 'personal|alpha': { original: syntheticEnglish, zh: syntheticChinese } };
const translations = synthetic ? { ...localTranslations, ...syntheticTranslations } : localTranslations;
function fixture() {
  const event = (date, skill, source, task, turn) => ({ date, skill, source, task, turn });
  const activity = [event('2026-08-01', 'old-skill', 'personal', 1, 1),
    event('2026-09-21', 'alpha', 'personal', 2, 2), event('2026-09-22', 'alpha', 'personal', 2, 2),
    event('2026-09-22', 'pack:alpha', 'plugin', 2, 2), event('2026-09-24', 'alpha', 'personal', 3, 3),
    event('2026-09-24', 'workspace-' + 'long-name-'.repeat(18), 'workspace', 3, 3),
    event('2026-09-28', 'imagegen', 'system', 4, 4), event('2026-09-28', 'unknown-skill', 'unknown', 4, 4)];
  const skillRows = [...new Map(activity.filter(row => row.date >= '2026-08-30').map(row => [identity(row), row])).values()]
    .map(row => ({ skill: row.skill, source: row.source, readTurns7: row.skill === 'alpha' ? 2 : 1, tasks7: row.skill === 'alpha' ? 2 : 1,
      readTurns30: row.skill === 'alpha' ? 2 : 1, tasks30: row.skill === 'alpha' ? 2 : 1 }));
  const metadata = [...new Map(activity.map(row => [identity(row), row])).values()].map(row => ({ skill: row.skill, source: row.source, status: 'available', name: '', description: '当前本地功能说明。' }));
  for (const row of metadata) {
    if (row.skill === 'alpha') { row.name = 'Review helper'; row.description = syntheticEnglish; }
    if (row.skill === 'old-skill') { row.status = 'missing'; row.name = ''; row.description = ''; }
    if (row.skill === 'unknown-skill') { row.status = 'ambiguous'; row.name = ''; row.description = ''; }
    if (row.skill === 'imagegen') { row.name = '图像工具'; row.description = ''; }
  }
  const inventory = metadata.filter(row => row.status !== 'missing').map(row => ({ ...row, copies: 1 }));
  inventory.push({ skill: 'fresh-report', source: 'personal', status: 'available', name: '新报告工具', description: '汇总报告。', copies: 1 });
  inventory.push({ skill: 'conflicted', source: 'plugin', status: 'ambiguous', name: '', description: '', copies: 2 });
  return { generated: 'synthetic-browser', month: '2026-09',
    usage: [{ date: '2026-08-10', session: 1, model: 'synthetic', effort: 'high', input: 80, cached: 30, fresh: 50, output: 20, reasoning: 5, total: 100 }],
    tasks: [], compactions: [], refresh: { reused: 1, reparsed: 1, sourceBytesRead: 2048, elapsedMs: 20 },
    skills: { metric: 'skill_instruction_reads', timeZone: 'Asia/Shanghai', asOf: '2026-09-28', scope: 'main_sessions', activitySchema: 1, activity,
      metadataSchema: 1, metadataAsOf: '2026-10-01', metadata,
      inventorySchema: 1, inventoryAsOf: '2026-10-01', inventoryScope: 'known_local_skill_roots', inventory,
      windows: { days7: { start: '2026-09-22', end: '2026-09-28' }, days30: { start: '2026-08-30', end: '2026-09-28' } }, rows: skillRows } };
}
// Independent sets over API records establish expected card, row and chart values.
function reference(data, filters) {
  const past = data.skills.activity.filter(event => event.date <= filters.end);
  const keys = [...new Set(past.map(identity))], names = new Map(), metadata = new Map((data.skills.metadata || []).map(row => [identity(row), row]));
  for (const key of keys) {
    const row = past.find(event => identity(event) === key), name = row.skill.split(':').at(-1).toLowerCase();
    if (!names.has(name)) names.set(name, new Set()); names.get(name).add(key);
  }
  const rows = keys.map(key => {
    const all = past.filter(event => identity(event) === key), period = all.filter(event => event.date >= filters.start), first = all[0];
    const row = { skill: first.skill, source: first.source, readTurns: new Set(period.map(event => event.turn)).size,
      mainTasks: new Set(period.map(event => event.task)).size, lastObservedDate: all.map(event => event.date).sort().at(-1) };
    const description = metadata.get(key);
    row.currentName = description?.name || ''; row.currentDescription = description?.description || ''; row.metadataStatus = description?.status || 'unavailable';
    const translated = translations[row.source + '|' + row.skill];
    row.currentDescriptionZh = row.metadataStatus === 'available' && translated?.original === row.currentDescription ? translated.zh : '';
    row.duplicate = names.get(row.skill.split(':').at(-1).toLowerCase()).size > 1; return row;
  }).filter(row => (!filters.search.trim() || [row.skill, row.currentName, row.currentDescription, row.currentDescriptionZh].join('\n').toLowerCase().includes(filters.search.trim().toLowerCase()))
    && (filters.source === 'all' || row.source === filters.source)
    && ({ all: true, active: row.readTurns > 0, unobserved: row.readTurns === 0, single: row.readTurns === 1, unknown: row.source === 'unknown', duplicate: row.duplicate })[filters.observation]);
  const byName = (a, b) => a.skill.localeCompare(b.skill) || a.source.localeCompare(b.source);
  rows.sort(({ reads: (a, b) => b.readTurns - a.readTurns || byName(a, b), readsAsc: (a, b) => a.readTurns - b.readTurns || byName(a, b),
    tasks: (a, b) => b.mainTasks - a.mainTasks || b.readTurns - a.readTurns || byName(a, b),
    recent: (a, b) => b.lastObservedDate.localeCompare(a.lastObservedDate) || byName(a, b), name: byName })[filters.sort]);
  const selected = new Set(rows.map(identity)), events = past.filter(event => event.date >= filters.start && selected.has(identity(event)));
  const summary = { activeSkills: rows.filter(row => row.readTurns > 0).length, readTurns: new Set(events.map(event => event.turn)).size,
    mainTasks: new Set(events.map(event => event.task)).size, skillTurnRecords: rows.reduce((sum, row) => sum + row.readTurns, 0) };
  const counts = new Map();
  for (const event of events) { if (!counts.has(event.date)) counts.set(event.date, new Set()); counts.get(event.date).add(event.turn); }
  const start = Date.parse(filters.start + 'T00:00:00Z'), span = Math.round((Date.parse(filters.end + 'T00:00:00Z') - start) / dayMs) + 1;
  const dates = span <= 366 ? Array.from({ length: span }, (_, i) => new Date(start + i * dayMs).toISOString().slice(0, 10)) : [...counts.keys()].sort();
  const trend = dates.map(date => ({ date, readTurns: counts.get(date)?.size || 0 }));
  const sourceRows = Object.keys(sources).map(source => ({ source, activeSkills: rows.filter(row => row.source === source && row.readTurns > 0).length }))
    .filter(row => row.activeSkills).sort((a, b) => b.activeSkills - a.activeSkills || a.source.localeCompare(b.source));
  return { rows, summary, trend, sources: sourceRows };
}
function noIdentifiers(value) {
  if (!value || typeof value !== 'object') return;
  for (const [key, item] of Object.entries(value)) {
    assert.ok(!['activity', 'task', 'turn', 'session_id', 'turn_id', 'path', 'cmd', 'arguments'].includes(key), 'Export excludes ' + key);
    noIdentifiers(item);
  }
}

(async () => {
  const browser = await chromium.launch({ headless: true, channel: 'msedge' });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, acceptDownloads: true, hasTouch: true });
  const errors = [], results = [];
  let syntheticData = fixture(), syntheticVersion = 1;
  const state = () => ({ status: 'ready', updated: 'synthetic-' + syntheticVersion });
  if (synthetic) {
    const root = path.join(__dirname, '..', 'web');
    const html = fs.readFileSync(path.join(root, 'dashboard.html'), 'utf8')
      .replace('/*__DASHBOARD_CSS__*/', fs.readFileSync(path.join(root, 'dashboard.css'), 'utf8'))
      .replace('//__SKILL_DESCRIPTIONS_ZH__', translationScript + '\nObject.assign(SKILL_DESCRIPTION_ZH, ' + JSON.stringify(syntheticTranslations) + ');')
      .replace('//__DASHBOARD_JS__', fs.readFileSync(path.join(root, 'dashboard.js'), 'utf8'));
    await page.route(url + '/**', route => {
      const pathname = new URL(route.request().url()).pathname;
      if (pathname === '/') return route.fulfill({ contentType: 'text/html; charset=utf-8', body: html });
      if (pathname === '/api/refresh') { syntheticVersion++; return route.fulfill({ json: {} }); }
      if (pathname === '/api/status') return route.fulfill({ json: state() });
      if (pathname === '/api/data') return route.fulfill({ json: syntheticData });
      return route.fulfill({ status: 204 });
    });
  }
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error' && !message.location().url?.endsWith('/favicon.ico')) errors.push(message.text()); });
  const record = name => results.push({ name, passed: true });
  async function apiSnapshot() {
    if (synthetic) return { state: state(), data: structuredClone(syntheticData) };
    const read = route => fetch(url + route).then(response => { assert.ok(response.ok); return response.json(); });
    const before = await read('/api/status'), data = await read('/api/data'), after = await read('/api/status');
    assert.equal(before.status, 'ready'); assert.equal(after.status, 'ready'); assert.equal(before.updated, after.updated);
    return { state: after, data };
  }
  async function filters() {
    return page.evaluate(() => Object.fromEntries(['preset', 'start', 'end', 'search', 'source', 'scope', 'category', 'observation', 'sort']
      .map(key => [key, document.querySelector('#skill' + key[0].toUpperCase() + key.slice(1))?.value ?? ({ scope: 'history', category: 'all' })[key]])));
  }
  async function compare() {
    const { state, data } = await apiSnapshot(), chosen = await filters();
    assert.equal(await page.evaluate(() => lastUpdated), state.updated); assert.equal(data.skills.activitySchema, 1);
    const expected = reference(data, chosen);
    const rows = await page.locator('#skillRows tr').evaluateAll(elements => elements.map(row => [...row.children].map((cell, index) => index === 0 ? cell.querySelector('.skill-identity').textContent : cell.textContent.trim())));
    assert.deepEqual(rows.map(row => [row[0], row[1], row[4], row[5], row[6]]), expected.rows.map(row => [row.skill, sources[row.source], String(row.readTurns), String(row.mainTasks), row.lastObservedDate]));
    assert.deepEqual((await page.locator('#skillCards .value').allTextContents()).map(Number), Object.values(expected.summary));
    const trend = await page.locator('#skillTrend .barcol').evaluateAll(elements => elements.map(row => ({ date: row.dataset.date, readTurns: Number(row.dataset.reads) })));
    assert.deepEqual(trend, expected.trend);
    const distribution = await page.locator('#skillSources .row').evaluateAll(elements => elements.map(row => [row.firstElementChild.textContent.trim(), row.lastElementChild.textContent.trim()]));
    assert.deepEqual(distribution, expected.sources.map(row => [sources[row.source], row.activeSkills + ' 项']));
    assert.equal(await page.locator('#skillFirst').innerText(), chosen.start); assert.equal(await page.locator('#skillLast').innerText(), chosen.end);
    if (['days7', 'days30'].includes(chosen.preset) && chosen.source === 'all' && chosen.observation === 'all' && !chosen.search) {
      const suffix = chosen.preset === 'days7' ? '7' : '30', fixed = new Map(data.skills.rows.map(row => [identity(row), row]));
      for (const row of expected.rows) {
        assert.equal(row.readTurns, fixed.get(identity(row))?.['readTurns' + suffix] || 0);
        assert.equal(row.mainTasks, fixed.get(identity(row))?.['tasks' + suffix] || 0);
      }
    }
    assert.match(await page.locator('#skillRange').innerText(), /Asia\/Shanghai/);
    assert.doesNotMatch(JSON.stringify(data.skills), /(?:[\s"'(=][a-z]:[\\/]|\/Users\/|\/home\/|"(?:cmd|command|arguments|session_id|turn_id)"\s*:)/i);
    return { data, chosen, expected };
  }
  async function quantities(touch = false) {
    let current = await compare();
    const ticks = (await page.locator('#skillYAxis .skill-y-tick').allTextContents()).map(Number);
    assert.ok(ticks.length >= 2 && ticks.at(-1) === 0 && ticks[0] >= Math.max(0, ...current.expected.trend.map(row => row.readTurns)));
    const positive = current.expected.trend.find(row => row.readTurns > 0);
    if (positive) {
      const bar = page.locator('#skillTrend .skill-day[data-date="' + positive.date + '"]');
      if (touch) await bar.tap(); else await bar.hover();
      assert.match(await page.locator('#skillTrendReadout').innerText(), new RegExp(positive.date + ' · ' + positive.readTurns + ' 轮'));
      assert.equal(await bar.locator('.skill-bar-value').isVisible(), true);
      assert.equal(await bar.locator('.skill-bar-value').innerText(), String(positive.readTurns));
      if (!touch) { await bar.focus(); assert.equal(await bar.getAttribute('aria-pressed'), 'true'); }
    }
    let zero = current.expected.trend.find(row => row.readTurns === 0);
    if (!zero) {
      const first = current.data.skills.activity.map(row => row.date).sort()[0] || current.data.skills.asOf;
      const date = new Date(Date.parse(first + 'T00:00:00Z') - dayMs).toISOString().slice(0, 10);
      await page.locator('#skillStart').fill(date); await page.locator('#skillEnd').fill(date); await page.locator('#skillEnd').blur();
      current = await compare(); zero = { date, readTurns: 0 };
    }
    const emptyBar = page.locator('#skillTrend .skill-day[data-date="' + zero.date + '"]');
    if (touch) await emptyBar.tap(); else { await emptyBar.hover(); await emptyBar.focus(); }
    assert.equal(await page.locator('#skillTrendReadout').innerText(), zero.date + ' · 0 轮（无可观测读取）');
    assert.ok((await emptyBar.boundingBox()).height >= 44, 'Zero days remain interactive across the full plot height');
    await page.locator('#skillInspectDate').fill(current.chosen.end); await page.locator('#skillInspectDate').blur();
    assert.match(await page.locator('#skillTrendReadout').innerText(), new RegExp(current.chosen.end + ' · '));
    assert.equal(await page.locator('#skillDayNext').isDisabled(), true);
    if (!touch && current.chosen.start !== current.chosen.end) {
      await page.locator('#skillDayPrev').click(); assert.notEqual(await page.locator('#skillInspectDate').inputValue(), current.chosen.end);
      await emptyBar.focus(); await page.keyboard.press('Home'); assert.equal(await page.locator('#skillInspectDate').inputValue(), current.chosen.start);
    }
    await page.locator('#skillReset').click();
    record(touch ? 'Touch tap and date controls expose exact counts including zero days at 390px' : 'Visible integer axis, value labels, hover, keyboard focus and zero-day inspection work');
  }
  async function captureDescription(label, touch = false) {
    const current = await compare();
    let index = current.expected.rows.findIndex(row => row.currentDescriptionZh);
    if (index < 0) index = current.expected.rows.findIndex(row => row.currentDescription);
    if (index < 0) return;
    const row = page.locator('#skillRows tr').nth(index), details = row.locator('.skill-description');
    if (touch) await details.locator('summary').tap(); else await details.locator('summary').click();
    assert.equal(await details.locator('.skill-description-full').isVisible(), true);
    assert.equal(await details.locator('.skill-description-full').textContent(), current.expected.rows[index].currentDescription);
    if (current.expected.rows[index].currentDescriptionZh) {
      assert.equal(await details.locator('.skill-description-zh').textContent(), current.expected.rows[index].currentDescriptionZh);
      assert.match(await details.locator('.skill-description-provenance').innerText(), /不是 Skill 源文件内容/);
    }
    await details.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(output, 'skill-description-' + label + '.png') });
    await row.screenshot({ path: path.join(output, 'skill-description-' + label + '-full.png') });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    if (touch) await details.locator('summary').tap(); else await details.locator('summary').click();
  }
  try {
    await page.goto(url);
    await page.waitForFunction(() => typeof D !== 'undefined' && D.skills?.activitySchema === 1 && D.skills?.metadataSchema === 1 && lastUpdated, { timeout: 30000 });
    // One requested live refresh also loads newly bundled HTML before testing new controls.
    if (args.includes('--refresh') && !synthetic) {
      const oldData = await apiSnapshot(), oldDate = oldData.data.usage.map(row => row.date).sort()[0] || oldData.data.skills.asOf;
      await page.locator('[data-page="token"]').click();
      await page.locator('#start').fill(oldDate); await page.locator('#end').fill(oldDate); await page.locator('#end').blur();
      await page.locator('[data-page="skill"]').click();
      await page.locator('#skillPreset').selectOption('custom');
      const saved = await filters(), prior = await page.evaluate(() => lastUpdated);
      await page.locator('#refresh').click();
      await page.waitForFunction(old => !refreshBusy && lastUpdated !== old && document.querySelector('#state').textContent === '刷新完成', prior, { timeout: 900000 });
      await page.reload(); await page.waitForFunction(() => typeof DATE_PRESETS !== 'undefined' && D.skills?.metadataSchema === 1 && lastUpdated);
      assert.deepEqual(await filters(), saved); assert.equal(await page.locator('#start').inputValue(), oldDate);
      assert.equal(await page.locator('#usagePreset').inputValue(), 'custom');
      record('Real refresh loads the current HTML and preserves or migrates both saved date scopes');
    }
    await page.locator('[data-page="token"]').click();
    await page.locator('#reset').click();
    const panels = await page.locator('#token .side > .panel').evaluateAll(nodes => nodes.map(node => {
      const box = node.getBoundingClientRect(); return { x: box.x, y: box.y };
    }));
    assert.equal(panels.length, 3); assert.ok(panels.every(box => Math.abs(box.y - panels[0].y) < 2));
    assert.ok(panels[1].x > panels[0].x && panels[2].x > panels[1].x); record('Desktop Token panels retain their original layout');
    const calendarStart = await page.locator('#start').inputValue(), calendarEnd = await page.locator('#end').inputValue();
    const calendarDays = Math.round((Date.parse(calendarEnd + 'T00:00:00Z') - Date.parse(calendarStart + 'T00:00:00Z')) / dayMs) + 1;
    assert.ok(calendarDays > 0 && calendarDays <= 366);
    assert.equal(await page.locator('#tokenTrend .usage-day').count(), calendarDays);
    assert.equal(await page.locator('#first').innerText(), calendarStart);
    assert.equal(await page.locator('#last').innerText(), calendarEnd);
    const absentTokenDay = page.locator('#tokenTrend .usage-day-missing').first();
    if (await absentTokenDay.count()) { await absentTokenDay.focus(); assert.match(await absentTokenDay.getAttribute('aria-label'), /无可观测记录/); }
    await page.locator('[data-page="eff"]').click();
    assert.equal(await page.locator('#taskTrend .usage-day').count(), calendarDays);
    assert.equal(await page.locator('#taskFirst').innerText(), calendarStart);
    assert.equal(await page.locator('#taskLast').innerText(), calendarEnd);
    await page.locator('[data-page="token"]').click();
    record('Token and request trends preserve the selected calendar with explicit absent-record labels');
    if (synthetic) {
      const scoped = fixture(); scoped.usageScopeSchema = 1; scoped.usage[0].scope = 'task';
      const row = (model, scope, total, session, effort) => ({ date: '2026-09-25', model, scope, total, session, effort,
        input: total - 10, cached: 0, fresh: total - 10, output: 10, reasoning: 2 });
      scoped.usage.push(row('scope-main', 'task', 100, 2, 'max'), row('scope-helper', 'task', 50, 3, 'high'), row('codex-auto-review', 'auto_review', 1000, 4, 'low'));
      scoped.tasks = scoped.usage.slice(1).map(item => ({ date: item.date, startedDate: item.date, model: item.model, effort: item.effort,
        scope: item.scope, session: item.session, started: true, completed: true, duration: 2, ttfb: .5, error: false }));
      scoped.compactions = scoped.tasks.map(({ date, model, effort, scope, session }) => ({ date, model, effort, scope, session }));
      syntheticData = scoped; syntheticVersion++;
      await page.evaluate(() => autoRefresh());
      await page.waitForFunction(() => D.usageScopeSchema === 1 && !loadBusy);
      await page.locator('#reset').click();
      assert.equal(await page.locator('#usageScope').inputValue(), 'task');
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '150');
      const modelShares = await page.locator('#models .row').evaluateAll(nodes => nodes.map(node => [node.firstElementChild.textContent, node.lastElementChild.textContent]));
      assert.deepEqual(modelShares, [['scope-main', '66.7%'], ['scope-helper', '33.3%']]);
      assert.doesNotMatch(await page.locator('#model').innerText(), /codex-auto-review/);
      record('Default task model shares exclude automatic review and retain ordinary helpers');
      const priorValidVersion = await page.evaluate(() => lastUpdated);
      syntheticData = { ...scoped, usage: scoped.usage.map((item, index) => index ? item : { ...item, total: 'bad' }) }; syntheticVersion++;
      await page.evaluate(() => autoRefresh());
      assert.equal(await page.evaluate(() => lastUpdated), priorValidVersion);
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '150');
      assert.match(await page.locator('#state').innerText(), /数据格式无效/);
      syntheticData = scoped; syntheticVersion++; await page.evaluate(() => autoRefresh());
      record('A malformed numeric snapshot retains the last valid charts and version in the real browser');
      await page.locator('#model').selectOption('scope-main'); await page.locator('#effort').selectOption('max');
      await page.locator('#model').selectOption('scope-helper');
      assert.equal(await page.locator('#effort').inputValue(), '');
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '50');
      assert.equal(await page.locator('#start').inputValue(), calendarStart);
      assert.equal(await page.locator('#end').inputValue(), calendarEnd);
      await page.locator('#reset').click();
      record('Ordinary model switches clear unsupported effort without losing the date range');
      await page.locator('[data-page="eff"]').click();
      assert.equal(await page.locator('#effCards .value').first().innerText(), '2');
      await page.locator('#usageScope').selectOption('auto_review');
      assert.equal(await page.locator('#effCards .value').first().innerText(), '1');
      await page.locator('[data-page="token"]').click();
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '1.0K');
      assert.match(await page.locator('#models').innerText(), /codex-auto-review[\s\S]*100\.0%/);
      record('Automatic review filters Token and request counts together');
      await page.locator('#start').fill('2026-09-25'); await page.locator('#end').fill('2026-09-25'); await page.locator('#end').blur();
      await page.locator('#model').selectOption('codex-auto-review'); await page.locator('#effort').selectOption('low');
      await page.reload(); await page.waitForFunction(() => lastUpdated && D.usageScopeSchema === 1);
      assert.equal(await page.locator('#usageScope').inputValue(), 'auto_review');
      assert.equal(await page.locator('#usagePreset').inputValue(), 'custom');
      assert.equal(await page.locator('#model').inputValue(), 'codex-auto-review');
      assert.equal(await page.locator('#effort').inputValue(), 'low');
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '1.0K');
      record('Scope and model filters survive a real browser reload');
      await page.locator('#usageScope').selectOption('task');
      assert.equal(await page.locator('#model').inputValue(), ''); assert.equal(await page.locator('#effort').inputValue(), '');
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '150');
      await page.locator('#usageScope').selectOption('all');
      const allShares = await page.locator('#models .row').evaluateAll(nodes => nodes.map(node => [node.firstElementChild.textContent, node.lastElementChild.textContent]));
      assert.deepEqual(allShares, [['codex-auto-review', '87.0%'], ['scope-main', '8.7%'], ['scope-helper', '4.3%']]);
      record('All raw tokens retain both scopes with a reconciled percentage denominator');
      await page.locator('#reset').click();
      await page.screenshot({ path: path.join(output, 'token-scopes-desktop.png'), fullPage: true });
      await page.setViewportSize({ width: 390, height: 844 });
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
      const mobilePanels = await page.locator('#token .side > .panel').evaluateAll(nodes => nodes.map(node => {
        const box = node.getBoundingClientRect(); return { x: box.x, y: box.y };
      }));
      assert.ok(mobilePanels.every(box => Math.abs(box.x - mobilePanels[0].x) < 2));
      assert.ok(mobilePanels[1].y > mobilePanels[0].y && mobilePanels[2].y > mobilePanels[1].y);
      await page.locator('#usageScope').selectOption('auto_review');
      assert.equal(await page.locator('#tokenCards .value').first().innerText(), '1.0K');
      await page.locator('#reset').click();
      await page.screenshot({ path: path.join(output, 'token-scopes-mobile.png'), fullPage: true });
      record('390px scope controls work and Token panels remain a single column without overflow');
      await page.setViewportSize({ width: 1440, height: 1000 });
      syntheticData = fixture(); syntheticVersion++;
      await page.evaluate(() => autoRefresh()); await page.waitForFunction(() => !D.usageScopeSchema && !loadBusy);
      await page.locator('#reset').click();
      assert.equal(await page.locator('#usageScope').inputValue(), 'all');
      assert.equal(await page.locator('#usageScope').isDisabled(), true);
      assert.match(await page.locator('#usageScopeNote').innerText(), /旧快照未区分/);
      record('Legacy browser snapshots disclose their boundary and disable unsupported scopes');
    } else {
      const live = await apiSnapshot();
      if (live.data.usageScopeSchema === 1) {
        const format = value => value >= 1e9 ? (value / 1e9).toFixed(2) + 'B' : value >= 1e6 ? (value / 1e6).toFixed(1) + 'M'
          : value >= 1e3 ? (value / 1e3).toFixed(1) + 'K' : String(Math.round(value));
        for (const scope of ['task', 'auto_review', 'all']) {
          await page.locator('#usageScope').selectOption(scope);
          const start = await page.locator('#start').inputValue(), end = await page.locator('#end').inputValue();
          const usage = live.data.usage.filter(item => item.date >= start && item.date <= end && (scope === 'all' || item.scope === scope));
          const total = usage.reduce((sum, item) => sum + item.total, 0), grouped = new Map();
          usage.forEach(item => grouped.set(item.model, (grouped.get(item.model) || 0) + item.total));
          const expectedShares = [...grouped].sort((a, b) => b[1] - a[1]).map(([name, tokens]) => [name, (100 * tokens / total).toFixed(1) + '%']);
          assert.equal(await page.locator('#tokenCards .value').first().innerText(), format(total));
          const actualShares = await page.locator('#models .row').evaluateAll(nodes => nodes.map(node => [node.firstElementChild.textContent, node.lastElementChild.textContent]));
          assert.deepEqual(actualShares, expectedShares);
          await page.locator('[data-page="eff"]').click();
          const tasks = live.data.tasks.filter(item => (item.startedDate || item.date) >= start && (item.startedDate || item.date) <= end && (scope === 'all' || item.scope === scope));
          assert.equal(await page.locator('#effCards .value').first().innerText(), String(tasks.length));
          await page.locator('[data-page="token"]').click();
          record('Live ' + scope + ' Token/model/request values match independent API totals');
        }
        await page.locator('#reset').click();
        await page.screenshot({ path: path.join(output, 'token-scopes-desktop.png'), fullPage: true });
        await page.setViewportSize({ width: 390, height: 844 });
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        await page.locator('#usageScope').selectOption('auto_review');
        assert.equal(await page.locator('#usageScope').inputValue(), 'auto_review');
        await page.locator('#reset').click();
        await page.screenshot({ path: path.join(output, 'token-scopes-mobile.png'), fullPage: true });
        await page.setViewportSize({ width: 1440, height: 1000 });
        record('Live scope controls remain usable at 390px without horizontal overflow');
      }
    }
    const initial = await apiSnapshot(), historic = initial.data.usage.map(row => row.date).sort()[0];
    const usageChoices = await page.locator('#usagePreset option').evaluateAll(nodes => nodes.map(node => [node.value, node.textContent]));
    const skillChoices = await page.locator('#skillPreset option').evaluateAll(nodes => nodes.map(node => [node.value, node.textContent]));
    assert.deepEqual(usageChoices, skillChoices);
    assert.deepEqual(usageChoices.map(row => row[0]), ['today', 'days7', 'days30', 'month', 'all', 'custom']);
    assert.equal(await page.locator('#usagePreset').inputValue(), 'month');
    assert.equal(await page.locator('#start').inputValue(), initial.data.skills.asOf.slice(0, 7) + '-01');
    assert.equal(await page.locator('#model option').first().textContent(), '全部模型');
    assert.equal(await page.locator('#effort option').first().textContent(), '全部推理强度');
    assert.equal(await page.locator('#reset').innerText(), '重置筛选'); assert.equal(await page.locator('#skillReset').innerText(), '重置筛选');
    for (const preset of ['today', 'days7', 'days30', 'month']) {
      await page.locator('#usagePreset').selectOption(preset);
      const tokenRange = [await page.locator('#start').inputValue(), await page.locator('#end').inputValue()];
      await page.locator('[data-page="skill"]').click(); await page.locator('#skillPreset').selectOption(preset);
      assert.deepEqual([await page.locator('#skillStart').inputValue(), await page.locator('#skillEnd').inputValue()], tokenRange);
      await page.locator('[data-page="eff"]').click();
      assert.deepEqual([await page.locator('#start').inputValue(), await page.locator('#end').inputValue()], tokenRange);
      await page.locator('[data-page="token"]').click();
    }
    await page.locator('#start').fill(''); await page.locator('#start').blur();
    assert.equal(await page.locator('#usagePreset').inputValue(), 'custom'); assert.equal(await page.locator('#token').isVisible(), false);
    assert.match(await page.locator('#usageRangeError').innerText(), /完整/);
    await page.locator('#reset').click();
    record('Both filter groups use matching date controls, calendar meanings, reset labels and explicit invalid-range feedback');
    if (historic) { await page.locator('#start').fill(historic); await page.locator('#end').fill(historic); await page.locator('#end').blur(); }
    await page.locator('[data-page="skill"]').click(); await page.locator('#skillReset').click();
    assert.equal(await page.locator('#usageFilters').isVisible(), false);
    assert.match(await page.locator('#skill').innerText(), /不代表实际调用或任务成功/);
    await compare();
    await quantities();
    if (synthetic) {
      await page.locator('#skillScope').selectOption('inventory');
      assert.ok(await page.locator('#skillRows').innerText().then(text => text.includes('fresh-report')));
      assert.match(await page.locator('#skillRows').innerText(), /截至所选日未观测到读取/);
      await page.locator('#skillScope').selectOption('combined');
      assert.match(await page.locator('#skillRows').innerText(), /本次未发现/);
      await page.locator('#skillCategory').selectOption('visual');
      assert.ok(await page.locator('#skillRows tr').count() > 0);
      await page.locator('#skillReset').click();
      await page.locator('#skillChoices input[data-skill-index="0"]').check();
      await page.locator('#skillTask').fill('整理本周公开资料');
      assert.match(await page.locator('#skillPromptPreview').inputValue(), /整理本周公开资料/);
      await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: url });
      await page.locator('#skillCopyPrompt').click();
      assert.match(await page.evaluate(() => navigator.clipboard.readText()), /候选 Skill/);
      await page.locator('#skillBundleName').fill('周报组合'); await page.locator('#skillBundleSave').click();
      assert.match(await page.locator('#skillComposerState').innerText(), /已保存在当前浏览器/);
      await page.locator('#skillTask').fill(''); assert.equal(await page.locator('#skillPromptPreview').inputValue(), '');
      record('Current directory, category, prompt preview, copy and local bundle work in the browser');
    }
    const cardBoxes = await page.locator('#skillCards .card').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().y));
    assert.ok(cardBoxes.every(y => Math.abs(y - cardBoxes[0]) < 2));
    await page.screenshot({ path: path.join(output, 'skills-desktop.png'), fullPage: true }); record('Desktop Skill cards, calendar trend, source bars and table match API sets');
    await page.locator('#skillTrendPanel').screenshot({ path: path.join(output, 'skill-quantities-desktop.png') });
    for (const preset of ['today', 'days7', 'month', 'all', 'days30']) { await page.locator('#skillPreset').selectOption(preset); await compare(); }
    record('All date presets match API activity and fixed 7/30-day counts');
    for (const observation of ['active', 'unobserved', 'single', 'unknown', 'duplicate', 'all']) { await page.locator('#skillObservation').selectOption(observation); await compare(); }
    for (const source of ['personal', 'workspace', 'system', 'plugin', 'unknown', 'all']) { await page.locator('#skillSource').selectOption(source); await compare(); }
    for (const sort of ['readsAsc', 'tasks', 'recent', 'name', 'reads']) { await page.locator('#skillSort').selectOption(sort); await compare(); }
    await page.locator('#skillSearch').fill('no-such-synthetic-skill-928'); await compare();
    assert.match(await page.locator('#skillEmpty').innerText(), /没有匹配/);
    await page.locator('#skillReset').click();
    assert.deepEqual(await filters(), { preset: 'days30', start: initial.data.skills.windows.days30.start, end: initial.data.skills.asOf, search: '', source: 'all', scope: 'history', category: 'all', observation: 'all', sort: 'reads' });
    record('Name, source, objective observation and sorting filters work; reset returns to all within 30 days');
    const described = initial.data.skills.metadata.find(row => row.status === 'available' && row.description.trim());
    assert.match(await page.locator('#skillMetadataNote').innerText(), /当前目录扫描截至.*历史读取截止.*目录扫描不增加读取计数/);
    if (described) {
      await page.locator('#skillSearch').fill(described.description.trim().split(/\r?\n/)[0].slice(0, 35));
      const matches = await compare(); assert.ok(matches.expected.rows.some(row => identity(row) === identity(described)));
      const index = matches.expected.rows.findIndex(row => row.currentDescription), details = page.locator('#skillRows tr').nth(index).locator('.skill-description');
      assert.equal(await details.getAttribute('open'), null); await details.locator('summary').click();
      assert.equal(await details.locator('.skill-description-full').isVisible(), true);
      assert.equal(await details.locator('.skill-description-full').textContent(), matches.expected.rows[index].currentDescription);
      assert.equal(await details.locator('.skill-description-full strong, .skill-description-full script').count(), 0, 'Descriptions render only as plain text');
      await details.locator('summary').click(); assert.equal(await details.locator('.skill-description-full').isVisible(), false);
      await page.locator('#skillReset').click();
    }
    record('Current local metadata can be searched and expanded without changing historical counts');
    const translatedMetadata = initial.data.skills.metadata.find(row => translations[row.source + '|' + row.skill]?.original === row.description && row.status === 'available');
    if (translatedMetadata) {
      const zh = translations[translatedMetadata.source + '|' + translatedMetadata.skill].zh;
      await page.locator('#skillSearch').fill(zh.slice(0, 12));
      const matched = await compare(), index = matched.expected.rows.findIndex(row => identity(row) === identity(translatedMetadata));
      assert.ok(index >= 0, 'Chinese interpretation is searchable');
      const details = page.locator('#skillRows tr').nth(index).locator('.skill-description');
      assert.match(await details.locator('summary').innerText(), /展开中英对照/);
      assert.equal(await details.locator('.skill-description-full').isVisible(), false);
      assert.equal(await details.locator('.skill-description-preview').textContent(), Array.from(zh).slice(0, 110).join('') + (Array.from(zh).length > 110 ? '…' : ''));
      await page.locator('#skillTable').screenshot({ path: path.join(output, 'chinese-default-desktop.png') });
      await details.locator('summary').click();
      assert.equal(await details.locator('.skill-description-zh').textContent(), zh);
      assert.equal(await details.locator('.skill-description-full').textContent(), translatedMetadata.description);
      await page.locator('#skillTable').screenshot({ path: path.join(output, 'chinese-comparison-desktop.png') });
      const downloadChinese = page.waitForEvent('download'); await page.locator('#skillExport').click();
      const savedChinese = await downloadChinese, exportPath = path.join(output, 'audit-chinese-snapshot.json'); await savedChinese.saveAs(exportPath);
      const exportedChinese = JSON.parse(fs.readFileSync(exportPath, 'utf8')), exportedRow = exportedChinese.rows.find(row => identity(row) === identity(translatedMetadata));
      assert.equal(exportedRow.currentDescription, translatedMetadata.description); assert.equal(exportedRow.currentDescriptionZh, zh); noIdentifiers(exportedChinese);
      await page.locator('#skillReset').click();
      record('Exact local Chinese interpretations are the default, searchable, shown with original text and exported without replacing it');
    }
    const first = [...initial.data.skills.activity].sort((a, b) => a.date.localeCompare(b.date))[0], customDate = first?.date || initial.data.skills.asOf;
    await page.locator('#skillStart').fill(customDate); await page.locator('#skillEnd').fill(customDate); await page.locator('#skillEnd').blur();
    if (first) { await page.locator('#skillSource').selectOption(first.source); await page.locator('#skillSearch').fill(first.skill); }
    await page.locator('#skillSort').selectOption('recent');
    const current = await compare(); assert.equal(current.chosen.preset, 'custom');
    assert.ok(current.expected.rows.every(row => row.lastObservedDate <= customDate));
    const downloadPromise = page.waitForEvent('download'); await page.locator('#skillExport').click();
    const download = await downloadPromise, auditPath = path.join(output, 'audit-snapshot.json'); await download.saveAs(auditPath);
    const exported = JSON.parse(fs.readFileSync(auditPath, 'utf8'));
    assert.deepEqual(exported.filters, current.chosen); assert.deepEqual(exported.summary, current.expected.summary); assert.deepEqual(exported.trend, current.expected.trend);
    assert.deepEqual(exported.sources, current.expected.sources);
    assert.equal(exported.metadataAsOf, current.data.skills.metadataAsOf);
    assert.deepEqual(exported.rows.map(row => [row.skill, row.source, row.readTurns, row.mainTasks, row.lastObservedDate]), current.expected.rows.map(row => [row.skill, row.source, row.readTurns, row.mainTasks, row.lastObservedDate]));
    assert.deepEqual(exported.rows.map(row => [row.metadataStatus, row.currentName, row.currentDescription, row.currentDescriptionZh]), current.expected.rows.map(row => [row.metadataStatus, row.currentName, row.currentDescription, row.currentDescriptionZh]));
    noIdentifiers(exported); assert.doesNotMatch(JSON.stringify(exported), /[\s"'(=][a-z]:[\\/]|\/Users\/|\/home\//i);
    record('Historical audit ignores later observations; clicked download matches the current view without identifiers');
    await page.reload(); await page.waitForFunction(() => typeof D !== 'undefined' && D.skills?.activitySchema === 1 && lastUpdated);
    assert.equal(await page.locator('[data-page="skill"]').getAttribute('aria-selected'), 'true'); assert.deepEqual(await filters(), current.chosen);
    if (historic) assert.equal(await page.locator('#start').inputValue(), historic);
    await compare(); record('Custom Skill filters, sort, tab and independent Token filters survive reload');
    if (synthetic) {
      const prior = await page.evaluate(() => lastUpdated); await page.locator('#refresh').click();
      await page.waitForFunction(old => !refreshBusy && lastUpdated !== old && document.querySelector('#state').textContent === '刷新完成', prior, { timeout: 900000 });
      assert.deepEqual(await filters(), current.chosen); await compare(); record(synthetic ? 'Synthetic manual-refresh lifecycle retains filters' : 'Real manual refresh commits new API data and retains filters');
    }
    // Reload the newly generated HTML as well as its data before taking final UI evidence.
    await page.reload(); await page.waitForFunction(() => typeof D !== 'undefined' && D.skills?.metadataSchema === 1 && lastUpdated);
    assert.deepEqual(await filters(), current.chosen);
    await page.locator('#skillReset').click(); await compare();
    await page.screenshot({ path: path.join(output, 'skills-desktop.png'), fullPage: true });
    await page.locator('#skillTrendPanel').screenshot({ path: path.join(output, 'skill-quantities-desktop.png') });
    await captureDescription('desktop');
    await page.locator('#skillReset').click(); await page.setViewportSize({ width: 390, height: 844 }); await compare();
    await quantities(true);
    assert.equal(await page.locator('#skillTable thead').isVisible(), false);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    const mobileCards = await page.locator('#skillCards .card').evaluateAll(nodes => nodes.map(node => ({ x: node.getBoundingClientRect().x, y: node.getBoundingClientRect().y })));
    assert.ok(Math.abs(mobileCards[0].y - mobileCards[1].y) < 2 && mobileCards[2].y > mobileCards[0].y);
    if (initial.data.skills.activity.length) assert.equal(await page.locator('#skillRows tr').first().evaluate(row => getComputedStyle(row).display), 'grid');
    await page.screenshot({ path: path.join(output, 'skills-mobile.png'), fullPage: true });
    await page.locator('#skillTrendPanel').screenshot({ path: path.join(output, 'skill-quantities-mobile.png') });
    if (initial.data.skills.activity.length) await page.locator('#skillTable').screenshot({ path: path.join(output, 'skills-mobile-table.png') });
    await captureDescription('mobile', true);
    record('390px Skill overview, controls and long names fit without horizontal page overflow');
    await page.locator('[data-page="token"]').click();
    const mobile = await page.locator('#token .side > .panel').evaluateAll(nodes => nodes.map(node => ({ x: node.getBoundingClientRect().x, y: node.getBoundingClientRect().y })));
    assert.ok(mobile.every(box => Math.abs(box.x - mobile[0].x) < 2)); assert.ok(mobile[1].y > mobile[0].y && mobile[2].y > mobile[1].y);
    if (historic) assert.equal(await page.locator('#start').inputValue(), historic); record('390px Token panels and original filters remain intact');
    if (synthetic) {
      await page.locator('[data-page="skill"]').click();
      syntheticData = fixture(); delete syntheticData.skills.metadata; delete syntheticData.skills.metadataAsOf; delete syntheticData.skills.metadataSchema;
      delete syntheticData.skills.inventory; delete syntheticData.skills.inventoryAsOf; delete syntheticData.skills.inventorySchema; delete syntheticData.skills.inventoryScope; syntheticVersion++;
      await page.evaluate(() => autoRefresh()); await compare();
      assert.match(await page.locator('#skillMetadataNote').innerText(), /暂无本地简介/);
      delete syntheticData.skills.activity; delete syntheticData.skills.activitySchema; syntheticVersion++;
      await page.evaluate(() => autoRefresh());
      assert.equal(await page.locator('#skillExport').isDisabled(), true); assert.equal(await page.locator('#skillPreset').isDisabled(), true);
      assert.equal(await page.locator('#skillCards').isVisible(), false); assert.equal(await page.locator('#skillRows tr').count(), syntheticData.skills.rows.length);
      syntheticData = fixture(); syntheticData.skills.activity = []; syntheticData.skills.rows = []; syntheticData.skills.metadata = []; syntheticVersion++; await page.evaluate(() => autoRefresh());
      assert.match(await page.locator('#skillEmpty').innerText(), /不代表未使用/); await compare();
      const oldVersion = await page.evaluate(() => lastUpdated);
      syntheticData = fixture(); syntheticData.skills.activity.push({ ...syntheticData.skills.activity[0] }); syntheticVersion++; await page.evaluate(() => autoRefresh());
      assert.equal(await page.evaluate(() => lastUpdated), oldVersion); assert.match(await page.locator('#state').innerText(), /数据格式无效/);
      record('Old, empty and invalid activity snapshots retain honest availability and commit behavior');
    }
    assert.deepEqual(errors, []); record('No browser JavaScript or console errors');
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({ passed: true, mode: synthetic ? 'synthetic_browser' : 'live_loopback', results }, null, 2));
    console.log(JSON.stringify({ passed: true, mode: synthetic ? 'synthetic_browser' : 'live_loopback', checks: results.length, artifacts: output }));
  } catch (error) {
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({ passed: false, error: error.message, errors, results }, null, 2)); throw error;
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
