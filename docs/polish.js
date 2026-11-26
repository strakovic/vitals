// Small touches that make the page feel alive, all quiet and all off with Reduce Motion:
// cursor spotlight on cards, a gentle tilt on the Mac, word-by-word headlines, counters,
// scroll progress, and a live readout tied to the simulated Mac.
(() => {
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const fine = matchMedia('(pointer: fine)').matches;

  // Scroll progress along the bottom of the nav.
  const bar = document.querySelector('.progressbar');
  const onScroll = () => {
    const max = document.documentElement.scrollHeight - innerHeight;
    if (bar) bar.style.transform = `scaleX(${max > 0 ? scrollY / max : 0})`;
  };
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  if (still) return;

  // Cards light up where the cursor is.
  if (fine) document.querySelectorAll('.card, .agent, .badge, .numbers > div, .install').forEach(el => {
    el.classList.add('spot');
    el.addEventListener('pointermove', e => {
      const r = el.getBoundingClientRect();
      el.style.setProperty('--x', `${e.clientX - r.left}px`);
      el.style.setProperty('--y', `${e.clientY - r.top}px`);
    });
  });

  // The Mac screen leans a degree or two toward the cursor.
  const mac = document.querySelector('.mac');
  if (mac && fine) {
    let raf = 0;
    mac.addEventListener('pointermove', e => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const r = mac.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width - .5, y = (e.clientY - r.top) / r.height - .5;
        mac.style.transform = `perspective(1800px) rotateX(${(-y * 2.2).toFixed(2)}deg) rotateY(${(x * 2.8).toFixed(2)}deg)`;
      });
    });
    mac.addEventListener('pointerleave', () => { mac.style.transform = ''; });
  }

  // Headlines rise in word by word.
  document.querySelectorAll('h1, .head h2, .ch h3, .final h2').forEach(h => {
    const walk = node => {
      [...node.childNodes].forEach(n => {
        if (n.nodeType === 3) {
          const frag = document.createDocumentFragment();
          n.textContent.split(/(\s+)/).forEach(part => {
            if (!part.trim()) { frag.appendChild(document.createTextNode(part)); return; }
            const w = document.createElement('span');
            w.className = 'w';
            w.textContent = part;
            frag.appendChild(w);
          });
          n.replaceWith(frag);
        } else if (n.nodeType === 1 && n.tagName !== 'BR') walk(n);
      });
    };
    walk(h);
    h.querySelectorAll('.w').forEach((w, i) => w.style.transitionDelay = `${i * 55}ms`);
    h.classList.add('words');
  });
  const words = new IntersectionObserver(entries => entries.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add('said'); words.unobserve(e.target); }
  }), { threshold: .3 });
  document.querySelectorAll('.words').forEach(h => {
    // Already on screen when the page opens: say it now, after a breath.
    const r = h.getBoundingClientRect();
    if (r.top < innerHeight && r.bottom > 0) setTimeout(() => h.classList.add('said'), 120);
    else words.observe(h);
  });

  // Big numbers count up when they arrive.
  const count = new IntersectionObserver(entries => entries.forEach(e => {
    if (!e.isIntersecting) return;
    count.unobserve(e.target);
    const b = e.target, node = b.firstChild;
    if (!node || node.nodeType !== 3) return;
    const target = parseFloat(node.textContent.replace(/[^\d.]/g, ''));
    if (!target) return;
    const prefix = node.textContent.match(/^[^\d]*/)[0], decimals = (node.textContent.split('.')[1] || '').replace(/\D/g, '').length;
    const t0 = performance.now();
    const step = now => {
      const p = Math.min(1, (now - t0) / 1100), eased = 1 - Math.pow(1 - p, 3);
      node.textContent = prefix + (target * eased).toFixed(decimals);
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }), { threshold: .6 });
  document.querySelectorAll('.numbers b').forEach(b => count.observe(b));

  // A live readout next to the download button, ticking with the simulated Mac in the panel.
  const readout = document.querySelector('[data-readout]');
  if (readout && window.VitalsLive) {
    const { sim } = window.VitalsLive;
    const tick = () => {
      const busy = sim.sessions.filter(s => !s.stopped && s.tasks.length).length;
      readout.innerHTML = `<i></i>Live demo · CPU <b>${Math.round(sim.cpu * 100)}%</b> · Memory <b>${Math.round(sim.mem * 100)}%</b> · <b>${busy}</b> ${busy === 1 ? 'agent' : 'agents'} working`;
    };
    tick();
    sim.listeners.push(tick);
  }
})();
