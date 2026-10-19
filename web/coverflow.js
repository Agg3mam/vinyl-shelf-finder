// Cover Flow som på en iPod classic (CoverFlowView.swift på Mac): hvid baggrund, covers drejet i 3D med
// spejling. Stryg med fingeren, tryk på et sidecover for at hente det frem, og på midten for at åbne pladen.
// Kun de synlige covers tegnes, så det virker også med tusindvis af plader.

import { CF } from "./core/library.js";
import { haptic } from "./haptics.js";

const reduceMotion = () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

/**
 * @param el beholderen (får klassen "cf")
 * @param opts { items, center, cover(item) → url, label(item), away(item), onCenter(i), onOpen(i) }
 */
export function mountCoverFlow(el, opts) {
  const items = opts.items;
  let center = Math.min(Math.max(opts.center ?? 0, 0), Math.max(items.length - 1, 0));
  let shift = 0;
  let spinTimer = null;
  const nodes = new Map(); // indeks → element
  el.classList.add("cf");
  el.innerHTML = '<div class="cf-stage"></div>';
  const stage = el.firstChild;

  const sideNow = () => CF.side(el.clientWidth || 360, el.clientHeight || 320);

  function nodeFor(i) {
    let n = nodes.get(i);
    if (n) return n;
    const it = items[i];
    n = document.createElement("button");
    n.className = "cf-cover";
    n.setAttribute("aria-label", opts.label(it));
    const url = opts.cover(it);
    n.innerHTML = `<span class="cf-ph" aria-hidden="true">♪</span>${url ? `<img alt="" draggable="false" referrerpolicy="no-referrer" src="${url.replace(/"/g, "&quot;")}" onerror="this.remove()">` : ""}`;
    if (opts.away?.(it)) n.classList.add("away");
    n.addEventListener("click", (e) => {
      if (moved) { e.preventDefault(); return; }
      if (i === center) opts.onOpen?.(i);
      else go(i, true);
    });
    stage.append(n);
    nodes.set(i, n);
    return n;
  }

  function layout(animate) {
    const side = sideNow();
    el.style.setProperty("--side", `${side}px`);
    el.classList.toggle("cf-anim", !!animate && !reduceMotion());
    const [a, b] = CF.visibleRange(center, items.length);
    for (const [i, n] of nodes) if (i < a - 1 || i > b) { n.remove(); nodes.delete(i); }
    for (let i = a; i < b; i++) {
      const o = i - center - shift;
      // CSS drejer modsat vej af SwiftUI's rotation3DEffect (som PlaneProjection på Windows).
      const n = nodeFor(i);
      n.style.transform = `translate(-50%, -50%) translateX(${CF.x(o, side).toFixed(1)}px) rotateY(${(-CF.angle(o)).toFixed(2)}deg) scale(${CF.scale(o).toFixed(3)})`;
      n.style.zIndex = String(1000 - Math.round(Math.abs(o) * 10));
      n.setAttribute("aria-current", i === center ? "true" : "false");
      n.tabIndex = i === center ? 0 : -1;
    }
  }

  function go(i, animate) {
    const t = Math.min(Math.max(i, 0), items.length - 1);
    if (t === center && shift === 0) return;
    if (t !== center) haptic("tick");
    center = t;
    shift = 0;
    layout(animate);
    opts.onCenter?.(center);
  }

  // Stryg: rækken følger fingeren; passerer den en halv plade, skifter midten.
  let startX = 0, lastX = 0, dragging = false, moved = false, atEdge = false, samples = [], stopped = false;
  const perCover = () => Math.max(24, sideNow() * 0.25);
  el.addEventListener("pointerdown", (e) => {
    if (!items.length) return;
    // En finger på rækken stopper et glid, der er i gang (og er så ikke et tryk på et cover).
    stopped = spinTimer !== null;
    stopSpin();
    dragging = true; moved = false; startX = lastX = e.clientX;
    samples = [{ x: e.clientX, t: e.timeStamp }];
  });
  el.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    if (!moved && Math.abs(e.clientX - startX) < 6) return;
    if (!moved) { moved = true; el.setPointerCapture?.(e.pointerId); }
    const d = e.clientX - lastX;
    lastX = e.clientX;
    samples.push({ x: e.clientX, t: e.timeStamp });
    while (samples.length > 2 && e.timeStamp - samples[0].t > 100) samples.shift();
    const g = CF.glide(center, shift - d / perCover(), items.length);
    const changed = g.center !== center;
    // Et klik for hver plade, der passerer midten, og et tydeligere ved enden af sektionen.
    const edge = (g.center === 0 && g.shift <= -0.3) || (g.center === items.length - 1 && g.shift >= 0.3);
    if (changed) haptic("tick");
    else if (edge && !atEdge) haptic("edge");
    atEdge = edge;
    center = g.center; shift = g.shift;
    layout(false);
    if (changed) opts.onCenter?.(center);
  });
  const end = () => {
    if (!dragging) return;
    dragging = false;
    if (moved) {
      // Fingerens fart de sidste 100 ms (plader pr. sekund; mod venstre = næste plade).
      const a = samples[0], b = samples.at(-1), dt = (b.t - a.t) / 1000;
      fling(dt > 0 ? -(b.x - a.x) / dt / perCover() : 0);
    } else if (shift !== 0) { shift = 0; layout(true); }
    if (stopped) { moved = true; stopped = false; }
    // Et klik lige efter et stryg skal ikke åbne pladen.
    setTimeout(() => { moved = false; }, 0);
  };
  el.addEventListener("pointerup", end);
  el.addEventListener("pointercancel", end);
  el.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") { go(center - 1, true); e.preventDefault(); }
    if (e.key === "ArrowRight") { go(center + 1, true); e.preventDefault(); }
  });
  const onResize = () => layout(false);
  window.addEventListener("resize", onResize);

  function stopSpin() { if (spinTimer) cancelAnimationFrame(spinTimer); spinTimer = null; }

  /** Snurrer hen til pladen `i` (forslaget i "Hør"): glider, bremser jævnt op og popper, når den lander. */
  function spinTo(i, done) {
    if (!items.length) return;
    const target = Math.min(Math.max(i, 0), items.length - 1);
    const total = target - (center + shift);
    if (reduceMotion() || Math.abs(total) < 0.5) { stopSpin(); finish(target, true, done); return; }
    // Længere afstande tager lidt længere tid, men aldrig over ca. 2,7 sekunder. Samme kurve som iPhone-appen.
    glide(target, 1300 + Math.min(1400, Math.abs(total) * 35), true, done);
  }

  /** Fortsætter et kraftigt stryg med farten og bremser jævnt op (som at scrolle på iPhone). Plader pr. sekund. */
  function fling(velocity) {
    const from = center + shift;
    const target = Math.min(Math.max(Math.round(from + velocity * 0.45), 0), items.length - 1);
    const total = target - from;
    if (reduceMotion() || Math.abs(velocity) < 2.5 || Math.abs(total) < 0.5) { shift = 0; layout(true); return; }
    // Kurven starter med samme fart som fingeren (ease-out i fjerde potens starter med 4 × afstand / tid).
    glide(target, Math.min(2500, Math.max(350, (4 * Math.abs(total) / Math.abs(velocity)) * 1000)), false);
  }

  function finish(target, landing, done) {
    center = target; shift = 0; layout(false);
    opts.onCenter?.(center);
    spinTimer = null;
    if (landing) {
      haptic("success");
      const n = nodes.get(center);
      if (n && !reduceMotion()) { n.classList.remove("cf-pop"); void n.offsetWidth; n.classList.add("cf-pop"); }
    }
    done?.();
  }

  /** Rækken glider hen til `target`: hurtigt først, bremser jævnt op. Et klik for hver plade, der passerer midten,
   *  hele vejen (højst ét pr. 35 ms). */
  function glide(target, duration, landing, done) {
    stopSpin();
    const from = center + shift, total = target - from;
    const begin = performance.now();
    let lastTick = -1e9;
    const frame = (now) => {
      const t = Math.min(1, (now - begin) / duration);
      const pos = from + total * (1 - (1 - t) ** 4); // ease-out (kvart)
      const c = Math.min(Math.max(Math.round(pos), 0), items.length - 1);
      if (c !== center) {
        if (now - lastTick >= 35) { haptic("tick", true); lastTick = now; }
        center = c;
        opts.onCenter?.(center);
      }
      shift = pos - c;
      layout(false);
      if (t >= 1) { finish(target, landing, done); return; }
      spinTimer = requestAnimationFrame(frame);
    };
    spinTimer = requestAnimationFrame(frame);
  }

  layout(false);
  return {
    get center() { return center; },
    go: (i) => go(i, true),
    spinTo,
    destroy() { stopSpin(); window.removeEventListener("resize", onResize); },
  };
}
