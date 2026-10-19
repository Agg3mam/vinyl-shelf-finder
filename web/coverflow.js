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
  let startX = 0, lastX = 0, dragging = false, moved = false, atEdge = false;
  const perCover = () => Math.max(24, sideNow() * 0.25);
  el.addEventListener("pointerdown", (e) => {
    if (!items.length) return;
    stopSpin();
    dragging = true; moved = false; startX = lastX = e.clientX;
  });
  el.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    if (!moved && Math.abs(e.clientX - startX) < 6) return;
    if (!moved) { moved = true; el.setPointerCapture?.(e.pointerId); }
    const d = e.clientX - lastX;
    lastX = e.clientX;
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
    if (shift !== 0) { shift = 0; layout(true); }
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

  function stopSpin() { clearTimeout(spinTimer); spinTimer = null; }

  /** Snurrer hen til pladen `i`: hurtigt først, langsommere til sidst (som et lykkehjul). */
  function spinTo(i, done) {
    stopSpin();
    if (!items.length) return;
    const target = Math.min(Math.max(i, 0), items.length - 1);
    if (reduceMotion()) { go(target, false); done?.(); return; }
    const dir = target >= center ? 1 : -1;
    let steps = Math.abs(target - center);
    // Lange afstande: spring tæt på, og snur de sidste plader (mindst en lille runde, også ved samme plade).
    const run = Math.min(Math.max(steps, 8), 16);
    if (steps !== run) {
      const startAt = Math.min(Math.max(target - dir * run, 0), items.length - 1);
      center = startAt; shift = 0; layout(false);
      steps = Math.abs(target - center);
    }
    let k = 0;
    const tick = () => {
      if (center === target) { haptic("success"); opts.onCenter?.(center); done?.(); spinTimer = null; return; }
      k += 1;
      center += target > center ? 1 : -1;
      haptic("tick");
      layout(true);
      opts.onCenter?.(center);
      const left = Math.abs(target - center);
      spinTimer = setTimeout(tick, 45 + (steps - left) ** 1.6 * 4 + (left < 3 ? 90 : 0));
    };
    tick();
  }

  layout(false);
  return {
    get center() { return center; },
    go: (i) => go(i, true),
    spinTo,
    destroy() { stopSpin(); window.removeEventListener("resize", onResize); },
  };
}
