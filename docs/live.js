// A working copy of the Vitals panel for the website: the same screens, driven by a simulated Mac.
// Every panel on the page reads one shared simulation, so they always agree with each other.
(() => {
  'use strict';
  const LEN = 90;
  const TICK = 1000;
  const C = { lime: '#d5ff5f', green: '#399947', blue: '#73adff', purple: '#bd8cff', orange: '#ffa83d', red: '#ff5c52', other: 'rgba(255,255,255,.28)', sys: 'rgba(255,255,255,.14)' };
  const rnd = (a, b) => a + Math.random() * (b - a);
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const pct = v => (v < 10 ? v.toFixed(1) : Math.round(v)) + '%';
  const gbs = gb => gb >= 1 ? gb.toFixed(1) + ' GB' : Math.round(gb * 1024) + ' MB';
  const rate = b => b >= 1e6 ? (b / 1e6).toFixed(1) + 'M' : Math.round(b / 1e3) + 'K';
  const ago = back => { const s = back; return s < 2 ? 'now' : s < 60 ? s + ' s ago' : Math.floor(s / 60) + ' min ' + (s % 60 ? (s % 60) + ' s ' : '') + 'ago'; };
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // ---------- The simulated Mac ----------
  const sim = {
    t: 0, cpu: .34, gpu: .26, mem: .68, temp: 57, power: 13, net: 1.8e6, battery: 80,
    target: { cpu: .34, gpu: .26 },
    hist: { cpu: [], gpu: [], mem: [], temp: [], power: [], net: [] },
    cores: [.42, .38, .47, .35, .71, .64, .22, .12],
    apps: [
      { id: 'xcode', name: 'Xcode', procs: 14, cpu: 11, gpu: 3, mem: 3.1, ic: ['#1c7cf4', '#0f5dc0'], g: '⚒' },
      { id: 'claude', name: 'Claude Code', procs: 22, cpu: 8, gpu: 0, mem: 1.6, ic: ['#d97757', '#b85a3b'], g: '✳', ai: true },
      { id: 'figma', name: 'Figma', procs: 9, cpu: 4, gpu: 12, mem: 1.4, ic: ['#a259ff', '#f24e1e'], g: 'F' },
      { id: 'safari', name: 'Safari', procs: 18, cpu: 3, gpu: 4, mem: 1.9, ic: ['#3aa0ff', '#1361d6'], g: '◎' },
      { id: 'docker', name: 'Docker', procs: 7, cpu: 1.8, gpu: 0, mem: 2.2, ic: ['#2496ed', '#1a6fb5'], g: '▦' },
      { id: 'cursor', name: 'Cursor', procs: 16, cpu: 2.6, gpu: 1, mem: 1.2, ic: ['#2b2b2b', '#111'], g: '◆', aiApp: true },
      { id: 'chatgpt', name: 'ChatGPT', procs: 6, cpu: 1.1, gpu: 2, mem: .6, ic: ['#10a37f', '#0b7a5f'], g: '✺', aiApp: true },
      { id: 'spotify', name: 'Spotify', procs: 5, cpu: .9, gpu: 1, mem: .4, ic: ['#1db954', '#14873c'], g: '♫' },
      { id: 'mail', name: 'Mail', procs: 3, cpu: .2, gpu: 0, mem: .3, ic: ['#4ca2ff', '#1f6fe0'], g: '✉' },
    ],
    sessions: [
      { id: 's1', name: 'Ship the onboarding flow', folder: 'atlas', age: 5400, tool: 'Claude Code', tasks: [], script: ['swift build -c release', 'swift test --filter Onboarding', 'npm run lint', 'git diff --stat'] },
      { id: 's2', name: 'Fix flaky checkout tests', folder: 'shop', age: 2700, tool: 'Claude Code', tasks: [], script: ['pytest tests/checkout -x', 'pytest tests/checkout -k retry', 'ruff check .'] },
      { id: 's3', name: 'Write the release notes', folder: 'atlas', age: 9800, tool: 'Claude Code', tasks: [], script: [] },
      { id: 's4', name: 'api-server', folder: 'api-server', age: 1300, tool: 'Codex', tasks: [], script: ['cargo test', 'cargo clippy', 'cargo build --release'] },
    ],
    listeners: [],
  };
  sim.apps.forEach(a => { a.base = { cpu: a.cpu, gpu: a.gpu, mem: a.mem }; a.gone = 0; });
  sim.sessions.forEach(s => { s.step = 0; s.cpu = 0; s.mem = .3 + Math.random() * .4; s.stopped = 0; s.next = Math.floor(rnd(1, 5)); });
  // A believable last 90 seconds to start from.
  for (let i = 0; i < LEN; i++) {
    const x = i / 6;
    sim.hist.cpu.push(clamp(.3 + Math.sin(x) * .07 + Math.sin(x * 2.7) * .04 + rnd(-.02, .02), .05, .95));
    sim.hist.gpu.push(clamp(.24 + Math.sin(x + 2) * .06 + rnd(-.02, .02), .02, .95));
    sim.hist.mem.push(clamp(.67 + Math.sin(x / 3) * .01, .3, .95));
    sim.hist.temp.push(56 + Math.sin(x / 2) * 2 + rnd(-.4, .4));
    sim.hist.power.push(12 + Math.sin(x) * 3 + rnd(-1, 1));
    sim.hist.net.push(Math.max(1e5, 1.5e6 + Math.sin(x * 1.3) * 1e6 + rnd(-3e5, 3e5)));
  }
  const push = (k, v) => { const h = sim.hist[k]; h.push(v); if (h.length > LEN) h.shift(); };

  // External work (the terminal demo) can run tasks inside a session.
  sim.run = (sessionId, command) => {
    const s = sim.sessions.find(x => x.id === sessionId);
    if (!s) return null;
    const task = { cmd: command, age: 0, cpu: rnd(4, 9), ext: true };
    s.tasks.unshift(task);
    sim.target.cpu = Math.min(.8, sim.target.cpu + .16);
    return task;
  };
  sim.finish = (sessionId, task) => {
    const s = sim.sessions.find(x => x.id === sessionId);
    if (s) s.tasks = s.tasks.filter(t => t !== task);
    sim.target.cpu = Math.max(.25, sim.target.cpu - .14);
  };
  sim.addSession = s => { Object.assign(s, { step: 0, cpu: 0, mem: .25, stopped: 0, next: 999, tasks: [], script: [] }); sim.sessions.unshift(s); };

  function tick() {
    sim.t++;
    if (sim.t % 7 === 0) { sim.target.cpu = rnd(.22, .5); sim.target.gpu = rnd(.15, .4); }
    sim.cpu = clamp(sim.cpu + (sim.target.cpu - sim.cpu) * .35 + rnd(-.04, .04), .04, .97);
    sim.gpu = clamp(sim.gpu + (sim.target.gpu - sim.gpu) * .3 + rnd(-.03, .03), .02, .97);
    const goneMem = sim.apps.filter(a => a.gone > sim.t).reduce((s, a) => s + a.mem, 0);
    sim.mem = clamp(.68 + Math.sin(sim.t / 40) * .015 - goneMem / 16 + rnd(-.004, .004), .3, .95);
    sim.temp = clamp(sim.temp + (50 + sim.cpu * 25 - sim.temp) * .08 + rnd(-.3, .3), 40, 99);
    sim.power = clamp(5 + sim.cpu * 22 + sim.gpu * 8 + rnd(-.8, .8), 3, 60);
    sim.net = Math.max(4e4, sim.net * rnd(.7, 1.3) + (Math.random() < .1 ? 2e6 : 0) - 2e5);
    sim.cores = sim.cores.map((c, i) => clamp(c + (sim.cpu * (i < 4 ? .9 : 1.5) - c) * .4 + rnd(-.08, .08), .02, 1));
    push('cpu', sim.cpu); push('gpu', sim.gpu); push('mem', sim.mem); push('temp', sim.temp); push('power', sim.power); push('net', sim.net);
    for (const a of sim.apps) {
      a.cpu = clamp(a.base.cpu * (sim.cpu / .34) * rnd(.6, 1.4), 0, 60);
      a.gpu = clamp(a.base.gpu * (sim.gpu / .26) * rnd(.7, 1.3), 0, 80);
      a.mem = clamp(a.base.mem * rnd(.985, 1.015), .05, 8);
      if (a.gone && a.gone <= sim.t) a.gone = 0;
    }
    // Agents pick up work from their scripts.
    for (const s of sim.sessions) {
      if (s.stopped && s.stopped <= sim.t) { s.stopped = 0; s.next = sim.t + 3; }
      s.age++;
      for (const t of s.tasks) { t.age++; if (!t.ext) t.cpu = clamp(t.cpu * rnd(.8, 1.2), .2, 15); }
      s.tasks = s.tasks.filter(t => t.ext || t.age < t.life);
      if (!s.stopped && s.script.length && sim.t >= s.next && s.tasks.filter(t => !t.ext).length === 0) {
        s.tasks.push({ cmd: s.script[s.step++ % s.script.length], age: 0, cpu: rnd(1.5, 7), life: Math.floor(rnd(4, 11)) });
        s.next = sim.t + Math.floor(rnd(6, 14));
      }
      s.cpu = s.stopped ? 0 : s.tasks.reduce((x, t) => x + t.cpu, 0) + rnd(0, .4);
    }
    sim.listeners.forEach(f => f());
  }
  setInterval(tick, TICK);

  const load = a => a.cpu + a.gpu * .6 + a.mem / 16 * 100 * .4;
  const visibleApps = () => sim.apps.filter(a => !(a.gone > sim.t));
  const busy = s => !s.stopped && s.tasks.length > 0;

  // ---------- Small drawing helpers ----------
  function linePath(values, w, h, len = LEN, lo = 0, hi = 1) {
    const step = w / (len - 1), start = w - step * (values.length - 1);
    return values.map((v, i) => (i ? 'L' : 'M') + (start + i * step).toFixed(1) + ' ' + (2 + (h - 4) * (1 - clamp((v - lo) / (hi - lo), 0, 1))).toFixed(1)).join('');
  }
  function sparkPath(values, w, h) {
    const lo = Math.min(...values), hi = Math.max(...values, lo + 1e-6);
    const pts = values.slice(-60);
    const step = w / (pts.length - 1);
    return pts.map((v, i) => (i ? 'L' : 'M') + (i * step).toFixed(1) + ' ' + (h - (v - lo) / (hi - lo) * h).toFixed(1)).join('');
  }

  // ---------- The panel ----------
  class Panel {
    constructor(el, opts = {}) {
      this.el = el;
      this.opts = opts;
      this.tab = opts.tab || 'apps';
      this.view = 'main';
      this.back = null;
      this.holding = false;
      this.order = [];
      this.reordered = 0;
      this.limit = 80;
      this.fullOnce = false;
      this.heat = true;
      this.metric = 'cpu';
      this.range = 1;
      this.bar = { cpu: true, gpu: true, ram: true, temp: true, power: false, net: false, battery: false, ai: true };
      this.picks = new Set(['docker', 'spotify', 'mail']);
      this.el.classList.add('vp');
      this.el.innerHTML = this.shell();
      this.q = s => this.el.querySelector(s);
      this.bind();
      this.update();
      sim.listeners.push(() => this.update());
    }

    shell() {
      const stat = (k, label, color) => `
        <div class="vp-stat vp-hl" data-open="${k}">
          <div class="lab"><i style="background:${color}"></i><span class="caps" style="color:${color}">${label}</span></div>
          <div class="val num light" data-v="${k}"></div><div class="cap" data-c="${k}"></div>
        </div>`;
      const mini = (k, label) => `
        <div class="vp-mini vp-hl click" data-open="${k}">
          <div class="caps" data-ml="${k}">${label}</div><div class="val num light" data-mv="${k}"></div>
          <svg viewBox="0 0 100 12" preserveAspectRatio="none"><path data-ms="${k}" fill="none" stroke="${C.lime}" stroke-opacity=".7" stroke-width="1.2" vector-effect="non-scaling-stroke"/></svg>
        </div>`;
      return `
      <div class="vp-head" data-zone="head">
        <span class="dot"></span><span class="title">VITALS</span>
        <span class="vp-chip click" data-open="temp"><span>🔥</span><span data-thermal>COOL</span></span>
        <span class="vp-boost click" data-go="boost">⚡ Boost</span>
      </div>
      <div class="vp-body">
        <div class="vp-view vp-main" data-view="main" style="display:flex;flex-direction:column">
          <div class="vp-card vp-live" data-zone="live">
            <div class="vp-stats3">${stat('cpu', 'CPU', C.lime)}${stat('gpu', 'GPU', C.blue)}${stat('mem', 'Memory', C.purple)}</div>
            <div class="vp-chart" data-chart>
              <svg viewBox="0 0 334 66" preserveAspectRatio="none">
                <g stroke="rgba(255,255,255,.06)" stroke-dasharray="2 3"><line x1="0" x2="334" y1="16.5" y2="16.5"/><line x1="0" x2="334" y1="33" y2="33" stroke="rgba(255,255,255,.09)"/><line x1="0" x2="334" y1="49.5" y2="49.5"/></g>
                <line x1="0" x2="334" y1="65.5" y2="65.5" stroke="rgba(255,255,255,.08)"/>
                <defs>${['mem', 'gpu', 'cpu'].map(k => `<linearGradient id="g-${k}-${this.uid()}" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="${this.color(k)}" stop-opacity=".16"/><stop offset="1" stop-color="${this.color(k)}" stop-opacity="0"/></linearGradient>`).join('')}</defs>
                ${['mem', 'gpu', 'cpu'].map(k => `<path data-f="${k}" fill="url(#g-${k}-${this._uid})"/><path data-l="${k}" fill="none" stroke="${this.color(k)}" stroke-width="1.5" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>`).join('')}
                <line data-guide x1="0" x2="0" y1="0" y2="66" stroke="rgba(255,255,255,.35)" vector-effect="non-scaling-stroke" style="display:none"/>
              </svg>
              ${['mem', 'gpu', 'cpu'].map(k => `<span data-dot="${k}" style="position:absolute;width:6px;height:6px;margin:-3px 0 0 -3px;border-radius:50%;background:${this.color(k)};box-shadow:0 0 6px ${this.color(k)};pointer-events:none"></span>`).join('')}
            </div>
            <div class="vp-cores"><span class="caps" style="color:rgba(255,255,255,.28);font-size:7px">CORES</span><div class="bars">${sim.cores.map((_, i) => `<div class="bar"><b data-core="${i}" style="background:${i < 4 ? 'rgba(57,153,71,.95)' : 'var(--vgrad)'}"></b></div>`).join('')}</div></div>
          </div>
          <div class="vp-card vp-strip" data-zone="strip">
            ${mini('temp', 'Temp')}<div class="vp-div"></div>${mini('power', 'Power')}<div class="vp-div"></div>${mini('net', 'Network')}<div class="vp-div"></div>
            <div class="vp-mini vp-hl click" data-go="battery">
              <div class="caps">Battery</div>
              <div class="vp-batt"><span class="val num light" data-batt>80%</span><span class="vp-glyph"><b data-glyph style="width:80%"></b></span></div>
              <div class="vp-held" data-held>held at 80%</div>
            </div>
          </div>
          <div class="vp-tabs" data-zone="list">
            <div class="vp-tab click" data-tab="apps">Apps</div>
            <div class="vp-tab click" data-tab="ai">AI<span class="badge" data-badge>2</span></div>
            <div class="vp-tab click" data-tab="bar">Settings</div>
          </div>
          <div class="vp-pane" data-zone="list" style="position:relative;flex:1;margin-top:8px;top:auto">
            <div data-pane="apps" style="position:absolute;inset:0">
              <div class="vp-thead"><span class="caps" data-hold style="flex:1;color:rgba(255,255,255,.45)">By load on your Mac</span>
                <span class="caps vp-col" style="width:46px;color:rgba(255,255,255,.45)">CPU</span><span class="caps vp-col" style="width:62px;color:rgba(255,255,255,.45)">Memory</span><span class="caps vp-col" style="width:40px;color:rgba(255,255,255,.45)">GPU</span><span style="width:24px"></span></div>
              <div class="vp-rows" data-rows></div>
            </div>
            <div data-pane="ai" style="position:absolute;inset:0"><div class="vp-scroll" data-ai></div></div>
            <div data-pane="bar" style="position:absolute;inset:0"><div class="vp-scroll" data-bar></div></div>
          </div>
        </div>

        <div class="vp-view out" data-view="boost"><div class="vp-scroll" style="padding-top:10px" data-boost></div></div>
        <div class="vp-view out" data-view="battery"><div class="vp-scroll" style="padding-top:10px" data-battery></div></div>
        <div class="vp-view out" data-view="history"><div class="vp-scroll" style="padding-top:10px" data-history></div></div>
      </div>
      <div class="vp-foot" data-zone="foot"><span class="vp-quiet click">↗ Activity Monitor</span><span class="vp-quiet click">Quit</span></div>
      <div class="vp-toast" data-toast></div>`;
    }

    uid() { this._uid = this._uid || Math.random().toString(36).slice(2, 8); return this._uid; }
    color(k) { return k === 'cpu' ? C.lime : k === 'gpu' ? C.blue : C.purple; }

    toast(text) {
      const t = this.q('[data-toast]');
      t.textContent = text;
      t.classList.add('on');
      clearTimeout(this._toast);
      this._toast = setTimeout(() => t.classList.remove('on'), 2200);
    }

    go(view) {
      this.view = view;
      this.el.querySelectorAll('[data-view]').forEach(v => {
        const on = v.dataset.view === view;
        v.classList.toggle('out', !on && v.dataset.view !== 'main');
        v.classList.toggle('under', !on && v.dataset.view === 'main');
      });
      this.update();
    }

    setTab(tab) { this.tab = tab; this.update(); }

    /** Used by the tour: put the panel on a screen. */
    show(state) {
      // Light up the part of the panel the chapter is about; dim the rest.
      const focus = { main: 'live', apps: 'list', ai: 'list' }[state];
      if (focus) this.el.dataset.focus = focus; else delete this.el.dataset.focus;
      if (state === 'boost' || state === 'battery' || state === 'history') { if (state === 'history') this.metric = 'cpu'; this.go(state); }
      else { this.tab = state === 'ai' ? 'ai' : 'apps'; this.go('main'); }
    }

    bind() {
      const el = this.el;
      el.addEventListener('click', e => {
        const t = e.target.closest('[data-tab],[data-go],[data-open],[data-quit],[data-stop],[data-back],[data-limit],[data-once],[data-heat],[data-pick],[data-free],[data-bar],[data-range]');
        if (!t) return;
        const d = t.dataset;
        if (d.tab) this.setTab(d.tab);
        else if (d.go) this.go(d.go);
        else if (d.open) { this.metric = d.open; this.range = 1; this.go('history'); }
        else if (d.back !== undefined) this.go('main');
        else if (d.quit) this.quit(d.quit);
        else if (d.stop) this.stop(d.stop);
        else if (d.limit) { this.limit = +d.limit; this.fullOnce = false; this.toast(this.limit === 100 ? 'Charge limit off: charges to 100%' : 'macOS now stops charging at ' + this.limit + '%'); this.update(); }
        else if (d.once !== undefined) { this.fullOnce = true; this.toast('Charging to 100% this once'); this.update(); }
        else if (d.heat !== undefined) { this.heat = !this.heat; this.update(); }
        else if (d.pick) { this.picks.has(d.pick) ? this.picks.delete(d.pick) : this.picks.add(d.pick); this.update(); }
        else if (d.free !== undefined) this.boost();
        else if (d.bar) { this.bar[d.bar] = !this.bar[d.bar]; this.update(); }
        else if (d.range) { this.range = +d.range; this.update(); }
      });
      // Hover the live chart: the numbers above rewind to that moment.
      const chart = this.q('[data-chart]');
      chart.addEventListener('mousemove', e => {
        const r = chart.getBoundingClientRect();
        const step = r.width / (LEN - 1);
        this.back = clamp(Math.round((r.right - e.clientX) / step), 0, sim.hist.cpu.length - 1);
        this.update();
      });
      chart.addEventListener('mouseleave', () => { this.back = null; this.update(); });
      const rows = this.q('[data-rows]');
      rows.addEventListener('mouseenter', () => { this.holding = true; this.update(); });
      rows.addEventListener('mouseleave', () => { this.holding = false; this.update(); });
    }

    quit(id) {
      const a = sim.apps.find(x => x.id === id);
      if (!a) return;
      const row = this.q(`[data-row="${id}"]`);
      if (row) row.classList.add('gone');
      setTimeout(() => { a.gone = sim.t + 25; this.update(); }, 380);
      this.toast(`Quit ${a.name} · ${gbs(a.mem)} back`);
    }

    stop(id) {
      const s = sim.sessions.find(x => x.id === id);
      if (!s) return;
      s.stopped = sim.t + 14;
      s.tasks = s.tasks.filter(t => t.ext);
      this.toast(`Stopped “${s.name}”`);
      this.update();
    }

    boost() {
      const picked = sim.apps.filter(a => this.picks.has(a.id) && !(a.gone > sim.t));
      if (!picked.length) return;
      this.freeing = new Set(picked.map(a => a.id));
      this.update();
      setTimeout(() => {
        const freed = picked.reduce((s, a) => s + a.mem, 0);
        picked.forEach(a => a.gone = sim.t + 30);
        this.freeing = null;
        this.toast(`Freed ${gbs(freed)} for Claude`);
        this.update();
      }, 900);
    }

    // ---------- Updates ----------
    update() {
      if (this.view === 'main') this.updateMain();
      if (this.view === 'boost') this.updateBoost();
      if (this.view === 'battery') this.updateBattery();
      if (this.view === 'history') this.updateHistory();
      this.updateMenubar();
    }

    value(k) {
      const h = sim.hist[k];
      return this.back == null ? h[h.length - 1] : h[h.length - 1 - this.back];
    }

    updateMain() {
      const q = this.q;
      const past = this.back != null;
      const caps = { cpu: '8 cores', gpu: gbs(1.3 * (sim.gpu / .26)) + ' used', mem: gbs(sim.mem * 16) + ' of 16 GB' };
      for (const k of ['cpu', 'gpu', 'mem']) {
        const v = q(`[data-v="${k}"]`), c = q(`[data-c="${k}"]`);
        v.textContent = Math.round(this.value(k) * 100) + '%';
        v.style.color = past ? this.color(k) : '#fff';
        c.textContent = past ? ago(this.back) : caps[k];
        c.style.color = past ? this.color(k) : '';
      }
      // chart
      const W = 334, H = 66;
      for (const k of ['mem', 'gpu', 'cpu']) {
        const d = linePath(sim.hist[k], W, H);
        q(`[data-l="${k}"]`).setAttribute('d', d);
        q(`[data-f="${k}"]`).setAttribute('d', d + `L${W} ${H}L${W - (W / (LEN - 1)) * (sim.hist[k].length - 1)} ${H}Z`);
        const dot = q(`[data-dot="${k}"]`);
        const back = this.back ?? 0;
        const x = 1 - back / (LEN - 1);
        const v = sim.hist[k][sim.hist[k].length - 1 - back];
        dot.style.left = (x * 100) + '%';
        dot.style.top = ((2 + (H - 4) * (1 - v)) / H * 100) + '%';
      }
      const guide = q('[data-guide]');
      if (past) { const x = W - (W / (LEN - 1)) * this.back; guide.setAttribute('x1', x); guide.setAttribute('x2', x); guide.style.display = ''; }
      else guide.style.display = 'none';
      sim.cores.forEach((c, i) => q(`[data-core="${i}"]`).style.width = Math.max(4, c * 100) + '%');
      // strip
      const minis = { temp: [Math.round(sim.temp) + '°', sim.hist.temp], power: [sim.power.toFixed(sim.power < 10 ? 1 : 0) + 'W', sim.hist.power], net: [rate(sim.net), sim.hist.net] };
      for (const k in minis) {
        q(`[data-mv="${k}"]`).textContent = minis[k][0];
        q(`[data-ms="${k}"]`).setAttribute('d', sparkPath(minis[k][1], 100, 12));
      }
      q('[data-thermal]').textContent = sim.temp > 85 ? 'HOT' : sim.temp > 70 ? 'WARM' : 'COOL';
      const charging = this.fullOnce || this.limit === 100;
      q('[data-held]').textContent = charging ? (this.fullOnce ? 'charging to 100%' : 'charges to 100%') : 'held at ' + this.limit + '%';
      // tabs
      this.el.querySelectorAll('[data-tab]').forEach(t => t.classList.toggle('on', t.dataset.tab === this.tab));
      this.el.querySelectorAll('[data-pane]').forEach(p => p.style.display = p.dataset.pane === this.tab ? '' : 'none');
      q('[data-badge]').textContent = sim.sessions.filter(busy).length;
      if (this.tab === 'apps') this.updateApps();
      if (this.tab === 'ai') this.updateAI();
      if (this.tab === 'bar') this.updateBar();
    }

    updateApps() {
      const q = this.q;
      q('[data-hold]').innerHTML = this.holding ? '<span style="color:#d5ff5f">❚❚ Order held</span>' : 'By load on your Mac';
      const list = visibleApps();
      const ranked = [...list].sort((a, b) => load(b) - load(a)).map(a => a.id);
      if (!this.order.length || (!this.holding && sim.t - this.reordered >= 4)) { this.order = ranked; this.reordered = sim.t; }
      else { this.order = this.order.filter(id => ranked.includes(id)).concat(ranked.filter(id => !this.order.includes(id))); }
      const rows = q('[data-rows]');
      const top = Math.max(...list.map(load), .001);
      // keep the DOM rows keyed by app, and move them with transforms
      const existing = new Map([...rows.children].map(r => [r.dataset.row, r]));
      this.order.forEach((id, i) => {
        const a = sim.apps.find(x => x.id === id);
        let r = existing.get(id);
        if (!r) {
          r = document.createElement('div');
          r.className = 'vp-row';
          r.dataset.row = id;
          r.innerHTML = `<div class="ic" style="background:linear-gradient(160deg,${a.ic[0]},${a.ic[1]})">${a.g}</div>
            <div class="nm"><b>${esc(a.name)}${a.ai ? ' <span style="color:#d5ff5f;font-size:9px">✦</span>' : ''}</b><span>${a.procs} processes</span></div>
            <div class="cell num" data-cpu style="width:46px"></div><div class="cell num" data-mem style="width:62px"></div><div class="cell num" data-gpu style="width:40px"></div>
            <div class="vp-x" data-quit="${id}" title="Quit ${esc(a.name)}">✕</div><div class="load"></div>`;
          r.style.transform = `translateY(${i * 42}px)`;
          rows.appendChild(r);
        }
        existing.delete(id);
        r.classList.remove('gone');
        r.style.transform = `translateY(${i * 42}px)`;
        const heat = (v, lim) => v / lim >= 1 ? C.red : v / lim >= .45 ? C.orange : v / lim < .02 ? 'rgba(255,255,255,.28)' : 'rgba(255,255,255,.88)';
        const cpu = r.querySelector('[data-cpu]'), mem = r.querySelector('[data-mem]'), gpu = r.querySelector('[data-gpu]');
        cpu.textContent = pct(a.cpu); cpu.style.color = heat(a.cpu, 40);
        mem.textContent = gbs(a.mem); mem.style.color = heat(a.mem / 16, .25);
        gpu.textContent = a.gpu >= .5 ? Math.round(a.gpu) + '%' : '–'; gpu.style.color = heat(a.gpu, 50);
        r.querySelector('.load').style.width = `calc((100% - 48px) * ${clamp(load(a) / top, .01, 1)})`;
      });
      existing.forEach(r => r.remove());
      rows.style.height = this.order.length * 42 + 'px';
    }

    updateAI() {
      const box = this.q('[data-ai]');
      const sessions = sim.sessions;
      const working = sessions.filter(busy).length;
      const tasks = sessions.reduce((n, s) => n + s.tasks.length, 0);
      const cpu = sessions.reduce((n, s) => n + s.cpu, 0);
      const groups = [...new Set(sessions.map(s => s.tool))];
      const card = s => {
        const b = busy(s);
        const color = s.stopped ? 'rgba(255,255,255,.3)' : b ? C.lime : 'rgba(255,255,255,.3)';
        return `<div class="vp-card2 ${b ? 'busy' : ''} ${s.stopped ? 'stopped' : ''}">
          <div class="top"><span class="vp-pulse ${b ? 'on' : ''}" style="--c:${color}"></span><b>${esc(s.name)}</b>
            <span class="met num">${pct(s.cpu)}&nbsp;&nbsp;${gbs(s.mem)}</span>
            <span class="caps st" style="color:${color};font-size:7.5px">${s.stopped ? 'STOPPED' : b ? 'BUSY' : 'IDLE'}</span>
            <span class="vp-x" data-stop="${s.id}" title="End this ${esc(s.tool)} session">✕</span></div>
          <div class="sub">${esc(s.folder)} · ${Math.floor(s.age / 3600) ? Math.floor(s.age / 3600) + 'h ' : ''}${Math.floor(s.age / 60) % 60}m</div>
          ${s.tasks.map(t => `<div class="vp-task"><i>›</i><span class="c">${esc(t.cmd)}</span><span class="a">${t.age}s</span><span class="p num" style="color:${t.cpu > 12 ? C.orange : 'rgba(255,255,255,.7)'}">${pct(t.cpu)}</span></div>`).join('')}
        </div>`;
      };
      const sig = sessions.map(s => s.id + s.stopped + s.tasks.map(t => t.cmd).join()).join('|');
      const scroll = box.scrollTop;
      box.innerHTML = `
        <div class="vp-sum">${[[working + '/' + sessions.length, 'Working'], [tasks, 'Tasks'], [Math.round(cpu) + '%', 'CPU'], [gbs(sessions.reduce((n, s) => n + s.mem, 0)), 'Memory']].map(([v, l]) => `<div><b class="num">${v}</b><span class="caps">${l}</span></div>`).join('')}</div>
        ${groups.map(g => { const list = sessions.filter(s => s.tool === g); return `<div class="vp-sect"><span class="caps" style="color:rgba(213,255,95,.8)">${esc(g)}</span><span>${list.filter(busy).length} of ${list.length} working</span></div>${list.map(card).join('')}`; }).join('')}
        <div class="vp-sect"><span class="caps" style="color:rgba(213,255,95,.8)">AI apps</span><span>2 open</span></div>
        ${sim.apps.filter(a => a.aiApp).map(a => `<div class="vp-card2" style="display:flex;align-items:center;gap:10px"><div class="ic" style="width:20px;height:20px;border-radius:6px;display:grid;place-items:center;font-size:10px;background:linear-gradient(160deg,${a.ic[0]},${a.ic[1]})">${a.g}</div><b style="flex:1;font-weight:400">${a.name}</b><span class="met num">${pct(a.cpu)}&nbsp;&nbsp;${gbs(a.mem)}</span></div>`).join('')}`;
      box.scrollTop = scroll;
      this._aiSig = sig;
    }

    updateBar() {
      const box = this.q('[data-bar]');
      const names = { cpu: ['Processor', pct(sim.cpu * 100)], gpu: ['Graphics', pct(sim.gpu * 100)], ram: ['Memory', Math.round(sim.mem * 100) + '%'], temp: ['Temperature', Math.round(sim.temp) + '°'], power: ['Power draw', sim.power.toFixed(1) + 'W'], net: ['Network', rate(sim.net)], battery: ['Battery', '80%'], ai: ['AI agents', sim.sessions.filter(busy).length + '/' + sim.sessions.length] };
      box.innerHTML = `<div class="caps" style="color:rgba(255,255,255,.45);padding:2px 4px 8px">Show in menu bar · click to toggle</div>
        <div class="vp-card" style="border-radius:14px">${Object.keys(names).map(k => `<div class="vp-mrow click" data-bar="${k}"><b style="${this.bar[k] ? '' : 'color:rgba(255,255,255,.5)'}">${names[k][0]}</b><span class="num">${names[k][1]}</span><span class="vp-switch ${this.bar[k] ? 'on' : ''}"></span></div>`).join('')}</div>`;
    }

    updateMenubar() {
      const m = this.opts.menubar;
      if (!m) return;
      const items = { cpu: ['CPU', Math.round(sim.cpu * 100) + '%'], gpu: ['GPU', Math.round(sim.gpu * 100) + '%'], ram: ['RAM', Math.round(sim.mem * 100) + '%'], temp: ['TEMP', Math.round(sim.temp) + '°', sim.temp > 85], power: ['PWR', sim.power.toFixed(1) + 'W'], net: ['NET', rate(sim.net)], battery: ['BAT', '80%'], ai: ['AI', sim.sessions.filter(busy).length + '/' + sim.sessions.length] };
      m.innerHTML = Object.keys(items).filter(k => this.bar[k]).map(k => `<div class="${items[k][2] ? 'hot' : ''}"><small>${items[k][0]}</small><span class="num">${items[k][1]}</span></div>`).join('') || '<div>Vitals</div>';
    }

    updateBoost() {
      const box = this.q('[data-boost]');
      const apps = visibleApps().filter(a => !a.ai && a.id !== 'xcode');
      const featured = [...visibleApps()].filter(a => !a.ai).sort((a, b) => b.mem - a.mem).slice(0, 4);
      const palette = [C.orange, C.blue, C.purple, '#4cd9c7'];
      const colorOf = id => { const i = featured.findIndex(a => a.id === id); return i >= 0 ? palette[i] : C.other; };
      const total = 16;
      const claude = sim.apps.filter(a => a.ai).reduce((s, a) => s + a.mem, 0);
      const feat = featured.map(a => ({ id: a.id, name: a.name, v: a.mem, c: colorOf(a.id) }));
      const others = visibleApps().filter(a => !a.ai && !featured.includes(a)).reduce((s, a) => s + a.mem, 0);
      const used = sim.mem * total;
      const sys = Math.max(0, used - claude - feat.reduce((s, f) => s + f.v, 0) - others);
      const segs = [{ name: 'Claude', v: claude, c: C.lime }, ...feat, { name: 'Everything else', v: others, c: C.other }, { name: 'macOS', v: sys, c: C.sys }];
      const freeing = this.freeing || new Set();
      const selected = apps.filter(a => this.picks.has(a.id)).reduce((s, a) => s + a.mem, 0);
      box.innerHTML = `
        <div style="display:flex;justify-content:space-between;align-items:center"><span class="vp-back" data-back><span>‹</span> Back</span><span style="color:#d5ff5f;font-size:15px">⚡ Boost</span></div>
        <div class="vp-card" style="padding:14px;margin-top:12px">
          <div style="display:flex;justify-content:space-between;align-items:baseline"><span class="caps">Memory</span><span><b class="num" style="font-weight:400;font-size:12px">${gbs(used)}</b> <span style="color:rgba(255,255,255,.28);font-size:10px">of 16 GB</span></span></div>
          <div class="vp-stack" style="margin-top:8px">${segs.map(s => `<i class="${s.id && (freeing.has(s.id) || (this.picks.has(s.id))) ? 'free' : ''}" style="width:${s.v / total * 100}%;background:${s.c};opacity:${freeing.has(s.id) ? .12 : ''}"></i>`).join('')}</div>
          <div class="vp-legend">${segs.filter(s => s.v > .05).map(s => `<div><i style="background:${s.c}"></i>${esc(s.name)} <span class="num">${gbs(s.v)}</span></div>`).join('')}</div>
          <div style="margin-top:10px;font-size:10.5px;color:rgba(255,255,255,.45)">Boost frees about <b style="color:#d5ff5f;font-weight:500">${gbs(selected)}</b> (striped)</div>
        </div>
        <div class="caps" style="color:rgba(255,255,255,.45);padding:14px 4px 6px">Apps in the background</div>
        ${apps.map(a => `<div class="vp-pick ${this.picks.has(a.id) ? 'on' : ''}" data-pick="${a.id}"><span class="vp-check ${this.picks.has(a.id) ? 'on' : ''}"></span><div class="ic" style="width:20px;height:20px;border-radius:6px;display:grid;place-items:center;font-size:10px;background:linear-gradient(160deg,${a.ic[0]},${a.ic[1]})">${a.g}</div><b style="flex:1;font-weight:400">${a.name}</b><span class="num" style="color:${a.mem > 1 ? C.orange : 'rgba(255,255,255,.8)'}">${gbs(a.mem)}</span></div>`).join('')}
        <div class="vp-go ${selected ? '' : 'off'}" data-free>⚡ Free up ${gbs(selected)}</div>`;
    }

    updateBattery() {
      const box = this.q('[data-battery]');
      const on = this.limit < 100;
      const temp = 32 + (sim.temp - 50) / 6;
      const protectedNow = on && temp < 35;
      box.innerHTML = `
        <div style="display:flex;justify-content:space-between;align-items:center"><span class="vp-back" data-back><span>‹</span> Back</span><span style="font-size:16px;font-weight:300">Battery</span></div>
        <div style="font-size:40px;font-weight:200;margin:10px 0 2px" class="num">80%</div>
        <div style="font-size:10.5px;color:rgba(255,255,255,.45)">${this.fullOnce ? 'Charging to 100% this once' : on ? 'Held at ' + this.limit + '% on the adapter' : 'On the adapter, charging to full'}</div>
        <div class="vp-card" style="margin-top:12px;border-radius:14px">
          <div class="vp-brow"><span style="font-size:20px;color:${protectedNow ? C.lime : C.orange}">${protectedNow ? '🛡' : '⚠︎'}</span>
            <div class="t"><b style="font-size:13px">${protectedNow ? 'Battery is protected' : on ? 'Battery is running warm' : 'Battery charges to full'}</b><span style="white-space:normal;color:rgba(255,255,255,.45)">${protectedNow ? 'Kept below full and cool, the two things that slow wear most' : on ? 'Heat wears a battery fastest' : 'Set a limit so it doesn’t sit at 100% on the adapter'}</span></div></div>
          <div class="vp-brow line" style="flex-direction:column;align-items:stretch">
            <div style="display:flex;align-items:center;gap:10px"><span class="ico">⌁</span><div class="t"><b>Charge limit</b><span>${this.fullOnce ? 'Charging to 100% this once, then back to ' + this.limit + '%' : on ? 'Stops charging at ' + this.limit + '% on the adapter' : 'Off: charges to 100% every time'}</span></div><span class="num" style="font-size:13px;color:${on ? C.lime : C.orange}">${on ? this.limit + '%' : 'Off'}</span></div>
            <div class="vp-seg" style="margin-top:8px">${[80, 85, 90, 95, 100].map(v => `<div class="${this.limit === v ? 'on' : ''}" data-limit="${v}">${v === 100 ? 'Off' : v + '%'}</div>`).join('')}</div>
            ${on ? `<div class="vp-outline ${this.fullOnce ? 'on' : ''}" data-once>⚡ ${this.fullOnce ? 'Charging to 100% once' : 'Charge to 100% once'}</div>` : ''}
          </div>
          <div class="vp-brow"><span class="ico">🌡</span><div class="t"><b>Heat alert</b><span>Notify me at 38° with the app heating it · now ${Math.round(temp)}°</span></div><span class="vp-switch ${this.heat ? 'on' : ''}" data-heat></span></div>
          <div class="vp-brow"><span class="ico">♡</span><div class="t"><b>Health</b><span>Holds 5,360 of 5,760 mAh it had new</span></div><span class="num" style="font-size:13px">93%</span></div>
          <div class="vp-brow"><span class="ico">↻</span><div class="t"><b>Cycles</b><span>Full charges used so far; rated for 1,000</span></div><span class="num" style="font-size:13px">212</span></div>
        </div>`;
    }

    updateHistory() {
      const box = this.q('[data-history]');
      const meta = { cpu: ['Processor', C.lime, 100, v => Math.round(v) + '%'], gpu: ['Graphics', C.blue, 100, v => Math.round(v) + '%'], mem: ['Memory', C.purple, 100, v => Math.round(v) + '%'], temp: ['Temperature', C.lime, 100, v => Math.round(v) + '°'], power: ['Power draw', C.lime, 40, v => v.toFixed(1) + 'W'], net: ['Network', C.lime, 6e6, v => rate(v)] };
      const [title, color, max, fmt] = meta[this.metric] || meta.cpu;
      const ranges = ['15 m', '1 h', '6 h', '24 h', 'Week', 'Month'];
      // A smooth series for the range: live seconds for 15 m, a seeded day-shaped curve beyond.
      const n = 120, seed = this.range * 1.7 + this.metric.length;
      const now = this.metric === 'mem' ? sim.mem * 100 : this.metric === 'cpu' ? sim.cpu * 100 : this.metric === 'gpu' ? sim.gpu * 100 : this.metric === 'temp' ? sim.temp : this.metric === 'power' ? sim.power : sim.net;
      const series = Array.from({ length: n }, (_, i) => {
        const x = i / n * (2 + this.range * 3) + seed;
        return Math.max(0, now * (0.8 + Math.sin(x) * .18 + Math.sin(x * 3.1) * .08 + Math.sin(x * 9.3) * .03));
      });
      series[n - 1] = now;
      const avg = series.reduce((a, b) => a + b, 0) / n;
      const hi = Math.max(...series), lo = Math.min(...series);
      const W = 360, H = 120;
      const top = Math.max(max * (this.metric === 'net' ? .3 : 1), hi * 1.15);
      const d = series.map((v, i) => (i ? 'L' : 'M') + (i / (n - 1) * W).toFixed(1) + ' ' + (H - v / top * H).toFixed(1)).join('');
      const hv = this._hv;
      box.innerHTML = `
        <div style="display:flex;justify-content:space-between;align-items:center"><span class="vp-back" data-back><span>‹</span> Back</span><span style="font-size:16px;font-weight:300">${title}</span></div>
        <div style="display:flex;justify-content:space-between;align-items:flex-end;margin-top:12px"><span class="num" style="font-size:38px;font-weight:200">${fmt(hv != null ? series[hv] : now)}</span><span class="caps" style="color:${hv != null ? 'rgba(255,255,255,.45)' : C.lime}">${hv != null ? (n - 1 - hv) + ' / ' + n + ' back' : 'Live'}</span></div>
        <svg data-hchart viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;height:130px;margin-top:6px;overflow:visible;cursor:crosshair">
          <defs><linearGradient id="hg-${this.uid()}" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="${color}" stop-opacity=".25"/><stop offset="1" stop-color="${color}" stop-opacity="0"/></linearGradient></defs>
          <g stroke="rgba(255,255,255,.06)"><line x1="0" x2="${W}" y1="${H / 2}" y2="${H / 2}"/><line x1="0" x2="${W}" y1="${H}" y2="${H}"/></g>
          <path d="${d}L${W} ${H}L0 ${H}Z" fill="url(#hg-${this._uid})"/>
          <path d="${d}" fill="none" stroke="${color}" stroke-width="1.6" vector-effect="non-scaling-stroke"/>
          ${hv != null ? `<line x1="${hv / (n - 1) * W}" x2="${hv / (n - 1) * W}" y1="0" y2="${H}" stroke="rgba(255,255,255,.4)" vector-effect="non-scaling-stroke"/>` : ''}
        </svg>
        <div class="vp-seg" style="margin-top:10px">${ranges.map((r, i) => `<div class="${this.range === i ? 'on' : ''}" data-range="${i}">${r}</div>`).join('')}</div>
        <div class="vp-card" style="display:flex;margin-top:10px;padding:10px 0;border-radius:14px">${[['Average', avg], ['Peak', hi], ['Low', lo]].map(([l, v]) => `<div style="flex:1;text-align:center"><b class="num" style="display:block;font-size:16px;font-weight:300">${fmt(v)}</b><span class="caps">${l}</span></div>`).join('')}</div>
        <div class="caps" style="padding:12px 4px 6px">Using it · ${ranges[this.range]}</div>
        ${[...sim.apps].sort((a, b) => b.cpu - a.cpu).slice(0, 4).map((a, i) => `<div style="display:flex;justify-content:space-between;padding:5px 8px;margin-bottom:3px;border-radius:7px;background:linear-gradient(90deg,rgba(213,255,95,.14) ${100 - i * 22}%,transparent ${100 - i * 22}%)"><span>${a.name}</span><span class="num" style="color:rgba(255,255,255,.45)">${pct(a.cpu)}</span></div>`).join('')}`;
      const svg = box.querySelector('[data-hchart]');
      svg.addEventListener('mousemove', e => { const r = svg.getBoundingClientRect(); this._hv = clamp(Math.round((e.clientX - r.left) / r.width * (n - 1)), 0, n - 1); this.updateHistory(); }, { once: true });
      svg.addEventListener('mouseleave', () => { this._hv = null; this.updateHistory(); }, { once: true });
    }
  }

  // ---------- Terminal: an agent at work, mirrored live in the panel next to it ----------
  function terminal(pre, panel) {
    sim.addSession({ id: 'term', name: 'Make onboarding faster', folder: 'atlas', age: 40, tool: 'Claude Code' });
    const script = [
      ['type', '~/code/atlas $ ', 'agent "make the onboarding screen open faster"'],
      ['out', '<span class="m">● Reading 14 files in Sources/Onboarding</span>', 900],
      ['run', 'swift build -c release', '  Compiled Atlas (182 files)', 4200],
      ['run', 'swift test --filter Onboarding', '  <span class="ok">✓ 48 tests passed</span>', 3600],
      ['out', '<span class="m">● Caching the layout pass in OnboardingView.swift</span>', 1400],
      ['run', 'swift build -c release', '  Compiled Atlas (3 files)', 2400],
      ['run', 'npm run lint', '  <span class="ok">✓ no problems</span>', 2000],
      ['out', '<span class="ok">● Done.</span> Onboarding opens in 180 ms, was 410 ms.', 1500],
    ];
    let html = '';
    const render = cursor => { pre.innerHTML = html + (cursor ? '<span class="cur"></span>' : ''); pre.scrollTop = pre.scrollHeight; };
    const wait = ms => new Promise(r => setTimeout(r, ms));
    async function play() {
      for (;;) {
        html = '';
        for (const step of script) {
          if (step[0] === 'type') {
            html += `<span class="p">${step[1]}</span>`;
            for (const ch of step[2]) { html += esc(ch); render(true); await wait(28 + Math.random() * 40); }
            html += '\n'; render(true); await wait(600);
          } else if (step[0] === 'out') {
            html += step[1] + '\n'; render(true); await wait(step[2]);
          } else {
            html += `<span class="p">● Running</span> ${esc(step[1])}\n`; render(true);
            const task = sim.run('term', step[1]);
            panel.update();
            await wait(step[3]);
            sim.finish('term', task);
            html += step[2] + '\n'; render(true); panel.update();
            await wait(500);
          }
        }
        await wait(5000);
      }
    }
    play();
  }

  // ---------- Wire up the page ----------
  const panels = {};
  document.querySelectorAll('[data-live]').forEach(el => {
    const name = el.dataset.live;
    const menubar = name === 'hero' ? document.querySelector('[data-menubar]') : null;
    panels[name] = new Panel(el, { tab: el.dataset.tab, menubar });
    if (menubar) menubar.addEventListener('click', () => {
      const holder = el.closest('.panel-holder');
      const open = holder.classList.toggle('closed') === false;
      menubar.classList.toggle('open', open);
    });
  });
  const pre = document.querySelector('[data-terminal]');
  if (pre && panels.code) terminal(pre, panels.code);
  window.VitalsLive = { panels, sim };
})();
