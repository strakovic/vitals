// The hero's heart monitor: a sweep draws one fine line across the page, leaving a trace that fades
// like phosphor. Each pass draws a real heartbeat (P, QRS, T) exactly behind the app icon, and the
// icon answers with a small pulse. Faint ECG paper underneath, fading out at the edges.
(() => {
  const canvas = document.getElementById('pulse');
  const icon = document.querySelector('.hero-icon');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const LIME = [213, 255, 95];
  const SWEEP = 3.4;          // seconds per pass across the page
  const FADE = 2.6;           // seconds a trace stays visible
  let W = 0, H = 0, dpr = 1, cx = 0, cy = 0, ys = [], ts = [], start = performance.now(), lastX = 0, beatDone = false;

  const g = (x, m, s) => Math.exp(-((x - m) * (x - m)) / (2 * s * s));
  // One heartbeat in units of the beat width: a small P wave, the sharp QRS, a broad T wave.
  const ecg = u => .12 * g(u, -.95, .11) - .1 * g(u, -.2, .045) + 1 * g(u, 0, .038) - .38 * g(u, .13, .045) + .24 * g(u, .78, .16);

  function size() {
    dpr = Math.min(2, devicePixelRatio || 1);
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = W * dpr; canvas.height = H * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const r = icon ? icon.getBoundingClientRect() : null, c = canvas.getBoundingClientRect();
    cx = r ? r.left + r.width / 2 - c.left : W / 2;
    cy = H / 2;
    ys = new Float32Array(Math.ceil(W) + 2);
    ts = new Float64Array(Math.ceil(W) + 2).fill(-1e9);
  }

  const unit = () => Math.min(130, W * .09);           // beat width in px
  const amp = () => Math.min(64, H * .32);              // beat height in px
  // The beat lands just before the icon, so you see it arrive and the icon answer.
  const beatX = () => cx - Math.max(90, unit() * 1.35);
  const yAt = x => cy - ecg((x - beatX()) / unit()) * amp() + (Math.random() - .5) * .5;

  function grid() {
    // ECG paper: a faint dot every 24 px, strongest near the middle.
    const step = 24;
    for (let x = (cx % step); x < W; x += step) {
      for (let y = (cy % step); y < H; y += step) {
        const fx = 1 - Math.min(1, Math.abs(x - cx) / (W * .5));
        const fy = 1 - Math.min(1, Math.abs(y - cy) / (H * .5));
        const a = .07 * fx * fx * fy;
        if (a < .004) continue;
        ctx.fillStyle = `rgba(255,255,255,${a})`;
        ctx.fillRect(x, y, 1, 1);
      }
    }
  }

  function frame(now) {
    const t = (now - start) / 1000;
    const head = ((t % SWEEP) / SWEEP) * (W + 60) - 30;
    // Write every column the head passed since the last frame.
    const from = Math.max(0, Math.floor(head < lastX ? 0 : lastX)), to = Math.min(W, Math.floor(head));
    for (let x = from; x <= to; x++) { ys[x] = yAt(x); ts[x] = t; }
    if (head < lastX) beatDone = false;
    lastX = head;
    // The icon beats as the head crosses it.
    if (!beatDone && head >= beatX() + 8 && icon) { beatDone = true; icon.classList.remove('beat'); void icon.offsetWidth; icon.classList.add('beat'); }

    ctx.clearRect(0, 0, W, H);
    grid();
    // Trace, drawn in short runs of equal brightness: bright behind the head, fading to nothing.
    ctx.lineJoin = ctx.lineCap = 'round';
    const run = 6;
    for (let x = 0; x < W - 1; x += run) {
      const age = t - ts[x];
      if (age > FADE || age < 0) continue;
      const life = 1 - age / FADE;
      const edge = Math.min(1, x / 140, (W - x) / 140);          // soften the page edges
      const a = Math.pow(life, 1.6) * edge;
      if (a < .01) continue;
      ctx.beginPath();
      ctx.moveTo(x, ys[x]);
      for (let k = 1; k <= run && x + k < W; k++) if (ts[x + k] > -1e8) ctx.lineTo(x + k, ys[x + k]);
      // a soft wide pass for the glow, then the fine line
      ctx.strokeStyle = `rgba(${LIME},${.08 * a})`; ctx.lineWidth = 6; ctx.stroke();
      ctx.strokeStyle = `rgba(${LIME},${.75 * a})`; ctx.lineWidth = 1.4; ctx.stroke();
    }
    // The writing head: a point of light with a bloom.
    if (head > 0 && head < W) {
      const hy = ys[Math.min(W, Math.max(0, Math.floor(head)))] || cy;
      const edge = Math.min(1, head / 140, (W - head) / 140);
      const bloom = ctx.createRadialGradient(head, hy, 0, head, hy, 26);
      bloom.addColorStop(0, `rgba(${LIME},${.5 * edge})`);
      bloom.addColorStop(1, `rgba(${LIME},0)`);
      ctx.fillStyle = bloom;
      ctx.fillRect(head - 26, hy - 26, 52, 52);
      ctx.fillStyle = `rgba(255,255,255,${.95 * edge})`;
      ctx.beginPath(); ctx.arc(head, hy, 1.8, 0, Math.PI * 2); ctx.fill();
    }
  }

  function drawStill() {
    ctx.clearRect(0, 0, W, H);
    grid();
    ctx.beginPath();
    for (let x = 0; x < W; x++) { const y = cy - ecg((x - beatX()) / unit()) * amp(); x ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
    ctx.strokeStyle = `rgba(${LIME},.35)`; ctx.lineWidth = 1.2; ctx.stroke();
  }

  size();
  addEventListener('resize', () => { size(); if (still) drawStill(); });
  // Only animate while the hero is on screen.
  let running = false;
  new IntersectionObserver(([e]) => {
    if (still) { drawStill(); return; }
    if (e.isIntersecting && !running) { running = true; start = performance.now(); lastX = 0; requestAnimationFrame(function loop(n) { if (!running) return; frame(n); requestAnimationFrame(loop); }); }
    else if (!e.isIntersecting) running = false;
  }).observe(canvas);
})();
