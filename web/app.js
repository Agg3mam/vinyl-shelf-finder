// Vinyl Shelf som webapp ("Føj til hjemmeskærm"). Samme skærme og tekster som iPhone-appen (ios/VinylShelfiOS):
// Reol, Scan, Søg og Konto, "Find i reolen" og "Spillet". Data kommer fra kontoen og gemmes i browseren,
// så appen virker uden net. Webappen ændrer aldrig reolerne; den skriver kun "Spillet".

import { buildLibraries, MEDIA, MEDIUM, STATUS, isOnShelf, locationName, shortName, fullName, pressingLine, awayMessage,
  FRESHNESS, genres, decades, candidates, pick, noMatchMessage, sortList } from "./core/library.js";
import { mountCoverFlow } from "./coverflow.js";
import { haptic } from "./haptics.js";
import * as cloud from "./core/cloud.js";
import * as db from "./core/store.js";

const DEMO = new URLSearchParams(location.search).has("demo");
const REPLAY_WINDOW = 120; // sekunder: endnu et "Spillet" på samme plade regnes som et dobbelttryk (som på Mac)
const SYNC_EVERY = 5 * 60 * 1000;

const state = {
  records: new Map(),
  libs: { vinyl: null, cd: null },
  plays: [],
  count: new Map(),
  lastPlayed: new Map(),
  byUID: new Map(),
  medium: "vinyl",
  session: null,
  email: "",
  phase: "idle", // "idle" | "syncing" | { failed: tekst }
  lastSync: null,
  loaded: false,
  query: "",
  tab: "reol",
  checked: { vinyl: new Set(), cd: new Set() },
  isAdmin: false,
  stats: null, // { data, error, loading }
  rules: null,
  coverFlow: false,
  flowCenter: new Map(), // sektion → pladen i midten af Cover Flow
};

// MARK: Hjælpere

const $ = (sel, root = document) => root.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const failed = () => (typeof state.phase === "object" ? state.phase.failed : null);
const safeLocal = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* privat browsing */ } },
};

const ICONS = {
  books: '<rect x="3" y="4" width="4" height="16" rx="1"/><rect x="9" y="4" width="4" height="16" rx="1"/><path d="m15.5 5.2 3.6-1 4 15.4-3.7 1z"/>',
  qr: '<path d="M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3"/><rect x="7" y="7" width="4" height="4" rx=".5"/><rect x="13" y="13" width="4" height="4" rx=".5"/><path d="M13 7h4v2M7 15v2h2"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  person: '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="10" r="3.2"/><path d="M6.2 18.4a7 7 0 0 1 11.6 0"/>',
  play: '<path d="M7 4.5v15l12.5-7.5z" fill="currentColor"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  chevR: '<path d="m9 5 7 7-7 7"/>',
  chevL: '<path d="m15 5-7 7 7 7"/>',
  note: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  house: '<path d="M3 11 12 3l9 8M5 9.5V21h5v-6h4v6h5V9.5"/>',
  frame: '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="m3 17 5-5 4 4 3-3 6 6"/><circle cx="15.5" cy="8.5" r="1.5"/>',
  box: '<path d="M3 7.5 12 3l9 4.5v9L12 21l-9-4.5zM3 7.5 12 12l9-4.5M12 12v9"/>',
  dashed: '<circle cx="12" cy="12" r="9" stroke-dasharray="3 3"/>',
  chart: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  shield: '<path d="M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6z"/><path d="m8.5 12 2.5 2.5 4.5-5"/>',
  palette: '<path d="M12 3a9 9 0 0 0 0 18c1.1 0 1.6-.8 1.6-1.6 0-1-.8-1.4-.8-2.3 0-.9.7-1.6 1.6-1.6H16a5 5 0 0 0 5-5C21 6.6 17 3 12 3z"/><circle cx="7.5" cy="11" r="1.2" fill="currentColor"/><circle cx="10.5" cy="7" r="1.2" fill="currentColor"/><circle cx="15.5" cy="7.5" r="1.2" fill="currentColor"/>',
  checklist: '<path d="M10 6h11M10 12h11M10 18h11"/><path d="m3 6 1.5 1.5L7 5M3 12l1.5 1.5L7 11"/><circle cx="5" cy="18" r="1.6"/>',
  circle: '<circle cx="12" cy="12" r="9"/>',
  checked: '<circle cx="12" cy="12" r="10" fill="currentColor" stroke="none"/><path d="m7.5 12.5 3 3 6-6.5" stroke="#fff"/>',
  restart: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  dice: '<rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="8" cy="8" r="1.3" fill="currentColor"/><circle cx="16" cy="8" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="8" cy="16" r="1.3" fill="currentColor"/><circle cx="16" cy="16" r="1.3" fill="currentColor"/>',
  flow: '<rect x="8" y="5" width="8" height="12" rx="1"/><path d="M5 6.5 2.5 8v7L5 16.5M19 6.5 21.5 8v7L19 16.5M8 20h8"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
  toLeft: '<path d="M4 4v16M20 12H8m4-5-5 5 5 5"/>',
  toRight: '<path d="M20 4v16M4 12h12m-4-5 5 5-5 5"/>',
  stack: '<rect x="3" y="8" width="18" height="13" rx="2"/><path d="M6 5h12M8 2h8"/>',
  listNum: '<path d="M10 6h11M10 12h11M10 18h11M4 4v4M3 18h3l-3 3h3M3 11a1.5 1.5 0 0 1 3 .5c0 1-3 2.5-3 2.5h3"/>',
  sync: '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8m0-4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16m0 4v-4h-4"/>',
  warn: '<path d="M12 3 2 20h20zM12 10v4M12 17.5v.01"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
  key: '<circle cx="7.5" cy="15.5" r="4.5"/><path d="m10.7 12.3 9.3-9.3M17 6l3 3M14 9l2 2"/>',
  logout: '<path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4M10 16l-4-4 4-4M6 12h11"/>',
  login: '<path d="M10 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4M14 16l4-4-4-4M18 12H7"/>',
  cloudDown: '<path d="M7 18a5 5 0 1 1 .9-9.9A6 6 0 0 1 19 10a4 4 0 0 1 0 8M12 12v8m-3-3 3 3 3-3"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
  share: '<path d="M12 3v12M8 7l4-4 4 4M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/>',
};
const icon = (name, extra = "") => `<svg class="i ${extra}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
const STATUS_ICON = { home: "house", wall: "frame", lent: "person", stored: "box", missing: "dashed" };

/** Cover. Uden billede: et blankt omslag i kunstnerens faste farve med forbogstaverne (som på Mac). */
function cover(url, cls = "", release = null) {
  const sleeve = release ? ` style="background:${sleeveColor(release.artist)}" data-initials="${esc(initials(release.artist))}"` : "";
  return `<span class="cover ${release ? "sleeve" : ""} ${cls}"${sleeve}>${release ? "" : icon("note")}${url ? `<img src="${esc(url)}" alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer" onerror="this.remove()">` : ""}</span>`;
}

/** Kunstnerens faste farve (samme mønster som CoverTone.fallback på Mac: FNV-1a, 24 nuancer). */
function sleeveColor(artist) {
  let h = 0xcbf29ce484222325n;
  for (const b of new TextEncoder().encode(artist.toLowerCase())) h = ((h ^ BigInt(b)) * 0x100000001b3n) & 0xffffffffffffffffn;
  const hue = Number(h % 24n) / 24;
  const sat = Math.min(Math.max([0.30, 0.42][Number((h / 24n) % 2n)], 0.5), 0.75), v = 0.34;
  const f = (k) => { const x = (k + hue * 6) % 6; return v - v * sat * Math.max(0, Math.min(x, 4 - x, 1)); };
  return `rgb(${Math.round(f(5) * 255)} ${Math.round(f(3) * 255)} ${Math.round(f(1) * 255)})`;
}

function initials(artist) {
  const w = artist.split(" ").filter((x) => x && x.toLowerCase() !== "the");
  return (w.length >= 2 ? w[0][0] + w[1][0] : (w[0] ?? "").slice(0, 2)).toUpperCase();
}

/** Skillekortets farve: kategoriens farve, ellers accentfarven. */
const CATEGORY_COLOR = { jazz: ["#1F4F8F", "#3A6DB5"], entertainment: ["#85621A", "#A67C24"], classical: ["#6E2433", "#93394B"] };
function dividerColor(loc) {
  const cat = loc.medium.split(".")[1];
  if (!CATEGORY_COLOR[cat]) return "var(--accent)";
  return matchMedia("(prefers-color-scheme: dark)").matches && document.documentElement.dataset.theme !== "light" ? CATEGORY_COLOR[cat][1] : CATEGORY_COLOR[cat][0];
}

function relative(sec) {
  const diff = sec - Date.now() / 1000;
  const rtf = new Intl.RelativeTimeFormat("da", { numeric: "auto" });
  const a = Math.abs(diff);
  if (a < 60) return rtf.format(Math.round(diff), "second");
  if (a < 3600) return rtf.format(Math.round(diff / 60), "minute");
  if (a < 86400) return rtf.format(Math.round(diff / 3600), "hour");
  if (a < 86400 * 30) return rtf.format(Math.round(diff / 86400), "day");
  if (a < 86400 * 365) return rtf.format(Math.round(diff / (86400 * 30)), "month");
  return rtf.format(Math.round(diff / (86400 * 365)), "year");
}

let toastTimer = null;
function toast(text) {
  let el = $(".toast");
  if (!el) { el = document.createElement("div"); el.className = "toast"; el.setAttribute("role", "status"); document.body.append(el); }
  el.textContent = text;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.remove(), 3500);
}

// MARK: Data

function rebuild() {
  const { libraries, plays, checked, rules } = buildLibraries([...state.records.values()]);
  state.libs = libraries;
  state.checked = checked;
  state.rules = rules;
  state.plays = plays;
  state.count = new Map();
  state.lastPlayed = new Map();
  for (const p of plays) {
    state.count.set(p.copyID, (state.count.get(p.copyID) ?? 0) + 1);
    if (!state.lastPlayed.has(p.copyID) || state.lastPlayed.get(p.copyID) < p.at) state.lastPlayed.set(p.copyID, p.at);
  }
  state.byUID = new Map();
  for (const m of MEDIA) for (const c of libraries[m].copies.values()) state.byUID.set(c.uid, { medium: m, id: c.id });
  if (!media().includes(state.medium) && media().length) state.medium = media()[0];
}

/** Hylder med reoler (Plader først). */
const media = () => MEDIA.filter((m) => state.libs[m]?.locations.length);
const hasShelves = () => media().length > 0;
const lib = (m) => state.libs[m];

function search(q) {
  return MEDIA.flatMap((m) => lib(m).index.hits(q).map((h) => ({ medium: m, item: lib(m).item(h.id), track: h.track })).filter((h) => h.item));
}

function sectionForScanCode(code) {
  for (const m of MEDIA) { const l = lib(m).locationForScanCode(code); if (l) return { medium: m, location: l }; }
  return null;
}

function mergeRows(rows) {
  for (const r of rows) {
    const id = `${r.kind}|${r.key}`;
    if (r.deleted || r.data == null) state.records.delete(id);
    else state.records.set(id, { kind: r.kind, key: r.key, data: r.data, updated_at: r.updated_at ?? "" });
  }
}

// MARK: Login og synkronisering

async function saveSession(s) {
  state.session = s;
  await db.setMeta("session", s);
}

async function validSession() {
  let s = state.session;
  if (!s) throw new cloud.CloudError("Du skal logge ind igen.", true);
  if (cloud.isExpired(s)) { s = await cloud.refresh(s); await saveSession(s); }
  return s;
}

async function loggedIn(s) {
  await saveSession(s);
  state.email = s.email || state.email;
  await db.setMeta("email", state.email);
  state.phase = "idle";
  render();
  await sync(true);
}

// MARK: Totrinslogin (som SecondFactorViews.swift på Mac og telefonen)

/** needs: kode-appen, koden mangler fra (null = ingen kode mangler). on: slået til (null = ukendt). */
const mfa = { needs: null, on: null, step: 0, enrollment: null, code: "", error: null, busy: false, copied: false };

/** Én gang efter login: et venligt tilbud om totrinslogin, hvis det ikke allerede er slået til. */
async function offerSecondFactorOnce(s) {
  if (safeLocal.get("mfa_offer_shown") === "1") return;
  let list;
  try { list = await cloud.factors(s); } catch { return; }
  safeLocal.set("mfa_offer_shown", "1");
  mfa.on = list.some((f) => f.verified);
  if (!mfa.on) { Object.assign(mfa, { step: 0, enrollment: null, code: "", error: null }); go("#/totrin"); }
}

async function refreshSecondFactor() {
  if (DEMO || !state.session) return;
  try { mfa.on = (await cloud.factors(await validSession())).some((f) => f.verified); } catch { return; }
  if (parseRoute().name === "konto") { lastRendered = ""; render(); }
}

/** Koden, når kontoen kræver den (fra Konto). */
async function submitNeededCode() {
  if (!mfa.needs || mfa.busy) return;
  mfa.busy = true; mfa.error = null; render();
  try {
    const s2 = await cloud.verifySecondFactor(mfa.needs.id, mfa.code, await validSession());
    await saveSession(s2);
    Object.assign(mfa, { needs: null, on: true, code: "" });
    state.phase = "idle";
    mfa.busy = false;
    await sync(true);
  } catch (e) {
    mfa.error = e.message;
  }
  mfa.busy = false;
  lastRendered = ""; render();
}

async function mfaStart() {
  Object.assign(mfa, { step: 1, error: null, enrollment: null, copied: false });
  render();
  if (DEMO) {
    mfa.enrollment = { factorID: "demo", secret: "JBSWY3DPEHPK3PXP", uri: "otpauth://totp/Vinyl%20Shelf:demo?secret=JBSWY3DPEHPK3PXP&issuer=Vinyl%20Shelf", qr: null };
  } else {
    try { mfa.enrollment = await cloud.enrollSecondFactor(await validSession()); } catch (e) { mfa.error = e.message; }
  }
  lastRendered = ""; render();
}

async function mfaConfirm() {
  if (!mfa.enrollment || mfa.busy || mfa.code.replace(/\D/g, "").length !== 6) return;
  mfa.busy = true; mfa.error = null; render();
  try {
    if (!DEMO) await saveSession(await cloud.verifySecondFactor(mfa.enrollment.factorID, mfa.code, await validSession()));
    Object.assign(mfa, { on: true, step: 3, code: "" });
    haptic("success");
  } catch (e) {
    mfa.error = e.message;
  }
  mfa.busy = false;
  lastRendered = ""; render();
}

async function mfaDisable() {
  if (!confirm("Slå totrinslogin fra? Så er en adgangskode eller et mail-link igen nok til at logge ind på kontoen.")) return;
  try {
    const s = await validSession();
    for (const f of await cloud.factors(s)) await cloud.removeSecondFactor(f.id, s);
    mfa.on = false;
  } catch (e) {
    toast(e.message);
  }
  lastRendered = ""; render();
}

function mfaSection() {
  if (DEMO) return "";
  const needs = mfa.needs ? `<div class="group-title">Skriv koden</div>
    <div class="list"><label class="field code-field"><span class="sr">Kode fra kode-appen</span><input data-mfa="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123 456" value="${esc(mfa.code)}"></label>
      ${mfa.error ? `<div class="message">${icon("warn")}<span>${esc(mfa.error)}</span></div>` : ""}
      <button class="row btn-row" data-action="mfa-submit" ${mfa.busy || mfa.code.replace(/\D/g, "").length !== 6 ? "disabled" : ""}>${icon("shield")}<span>Fortsæt</span></button></div>
    <p class="footnote">Din konto har totrinslogin. Åbn kode-appen (fx Adgangskoder › Koder), og skriv de 6 tal ud for Vinyl Shelf.</p>` : "";
  const state_ = mfa.on === true ? "Til" : mfa.on === false ? "Fra" : "…";
  const action = mfa.on === true
    ? `<button class="row btn-row danger" data-action="mfa-off" ${mfa.needs ? "disabled" : ""}>${icon("shield")}<span>Slå totrinslogin fra</span></button>`
    : mfa.on === false ? `<a class="row btn-row" href="#/totrin" data-nav>${icon("shield")}<span>Slå totrinslogin til</span></a>` : "";
  return `${needs}<div class="group-title">Totrinslogin</div>
    <div class="list"><div class="row kv"><span>Totrinslogin</span><span class="v">${state_}</span></div>${action}</div>
    <p class="footnote">Med totrinslogin skal du også skrive en kode fra telefonen, når du logger ind på en ny enhed.</p>`;
}

/** Guiden: tre trin som på Mac og telefonen. */
function mfaPage() {
  const steps = ["Find en kode-app på telefonen", "Tilføj Vinyl Shelf i appen", "Skriv de 6 tal, appen viser"];
  const dots = `<div class="mfa-dots" aria-label="Trin ${Math.min(mfa.step, 2) + 1} af 3">${[0, 1, 2].map((i) => `<span class="${i === Math.min(mfa.step, 2) ? "on" : ""}"></span>`).join("")}</div>`;
  const err = mfa.error ? `<div class="list" style="margin-top:14px"><div class="message">${icon("warn")}<span>${esc(mfa.error)}</span></div></div>` : "";
  let body;
  if (mfa.step === 0) {
    body = `<div class="welcome"><div class="big-icon">${icon("shield")}</div><h2>Slå totrinslogin til</h2>
        <p>Så kan ingen komme ind på din konto med kun din adgangskode eller din mail. Det tager et par minutter.</p></div>
      <div class="group-title">Sådan gør du</div>
      <div class="list steps">${steps.map((t, i) => `<div class="row"><span class="n">${i + 1}</span><span class="grow">${t}</span></div>`).join("")}</div>
      <p class="footnote">På iPhone kan du bruge appen Adgangskoder, som allerede er der. På Android kan du hente Google Authenticator gratis.</p>
      <div class="list" style="margin-top:22px"><button class="row btn-row" data-action="mfa-start"><span class="grow">Kom i gang</span>${icon("chevR")}</button></div>`;
  } else if (mfa.step === 1) {
    const e = mfa.enrollment;
    body = `<h1 class="large-title" style="font-size:28px">Tilføj Vinyl Shelf</h1>
      ${e ? `<div class="group-title">På denne telefon</div>
        <div class="list"><a class="row btn-row" href="${esc(e.uri)}">${icon("key")}<span>Åbn i kode-appen</span></a></div>
        <p class="footnote">Åbner Adgangskoder (eller din kode-app), som tilføjer koden.</p>
        ${e.qr ? `<div class="group-title">Fra en anden telefon</div><div class="list"><div class="qr"><img src="${esc(e.qr)}" alt="QR-kode til kode-appen"></div></div>
        <p class="footnote">Scan koden med kameraet, og vælg at tilføje den i kode-appen.</p>` : ""}
        <div class="group-title">Kan du ikke scanne?</div>
        <div class="list"><div class="row kv"><span class="secret">${esc(cloud.groupedSecret(e.secret))}</span><button class="link-btn" data-action="mfa-copy">${mfa.copied ? "Kopieret" : "Kopiér"}</button></div></div>
        <div class="list" style="margin-top:22px"><button class="row btn-row" data-action="mfa-next"><span class="grow">Næste</span>${icon("chevR")}</button></div>`
      : `<div class="empty"><span class="spinner"></span></div>`}`;
  } else if (mfa.step === 2) {
    body = `<h1 class="large-title" style="font-size:28px">Skriv koden</h1>
      <p class="footnote" style="margin:0 4px">Skriv de 6 tal, som kode-appen viser ud for Vinyl Shelf. Tallene skifter hvert 30. sekund.</p>
      <div class="list code-field" style="margin-top:14px"><label class="field"><span class="sr">Kode</span><input data-mfa="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123 456" value="${esc(mfa.code)}"></label></div>
      <div class="list" style="margin-top:22px"><button class="row btn-row" data-action="mfa-confirm" ${mfa.busy || mfa.code.replace(/\D/g, "").length !== 6 ? "disabled" : ""}><span class="grow">Slå totrinslogin til</span>${mfa.busy ? '<span class="spinner"></span>' : ""}</button></div>`;
  } else {
    body = `<div class="welcome"><div class="big-icon">${icon("check")}</div><h2>Totrinslogin er slået til</h2>
        <p>Næste gang du logger ind på en ny enhed, skal du også skrive en kode fra kode-appen. Dine enheder, der allerede er logget ind, beder om koden én gang.</p></div>
      <p class="footnote">Mister du telefonen, kan du slå totrinslogin fra på en computer, hvor du stadig er logget ind.</p>
      <div class="list" style="margin-top:22px"><button class="row btn-row" data-action="back" data-fallback="#/konto"><span class="grow">Færdig</span></button></div>`;
  }
  const back = mfa.step === 1 || mfa.step === 2;
  return `<main class="page">${topbar({ backTo: "#/konto", title: "Totrinslogin" })}
    ${body}${err}${mfa.step < 3 ? dots : ""}
    ${back ? `<p class="footnote"><button class="link-btn" data-action="mfa-prev">Tilbage til forrige trin</button></p>` : ""}
  </main>`;
}

let syncing = null;
async function sync(userInitiated = false) {
  if (DEMO || !state.session) return;
  if (syncing) return syncing;
  syncing = (async () => {
    state.phase = "syncing";
    renderStatus();
    try {
      const s = await validSession();
      // En anden konto end sidst: start forfra.
      if ((await db.getMeta("userID")) !== s.userID) {
        await db.clearAll();
        await saveSession(s);
        await db.setMeta("email", state.email);
        await db.setMeta("userID", s.userID);
        state.records.clear();
      }
      // Totrinslogin: kontoen kræver koden, og dette login har den ikke endnu. Intet hentes eller sendes.
      const need = await cloud.pendingSecondFactor(s);
      if (need) {
        Object.assign(mfa, { needs: need, on: true });
        state.phase = { failed: cloud.SECOND_FACTOR_REQUIRED };
        render();
        return;
      }
      const pending = (await db.getMeta("pending")) ?? [];
      if (pending.length) {
        await cloud.upsert(pending, s);
        await db.setMeta("pending", []);
      }
      const { rows, cursor } = await cloud.fetchRecords((await db.getMeta("cursor")) ?? null, s);
      await db.applyRows(rows);
      mergeRows(rows);
      if (cursor) await db.setMeta("cursor", cursor);
      // Administrator? (Så vises Statistik under Konto.) Mangler funktionen i databasen, er svaret bare nej.
      try { state.isAdmin = (await cloud.rpc("is_admin", s)) === true; } catch { state.isAdmin = false; }
      await db.setMeta("isAdmin", state.isAdmin);
      state.lastSync = Date.now();
      await db.setMeta("lastSync", state.lastSync);
      state.phase = "idle";
      if (rows.length) rebuild();
      render();
      offerSecondFactorOnce(s);
    } catch (e) {
      if (e.needsSecondFactor) {
        try { mfa.needs = await cloud.pendingSecondFactor(state.session); } catch { /* prøv igen ved næste synkronisering */ }
        state.phase = { failed: e.message };
      } else if (e.needsLogin) {
        state.session = null;
        await db.setMeta("session", undefined);
        state.phase = { failed: "Du er logget ud af kontoen. Log ind igen for at synkronisere." };
      } else {
        state.phase = { failed: e.message || "Synkroniseringen fejlede." };
      }
      if (userInitiated) toast(failed());
      render();
    } finally {
      syncing = null;
    }
  })();
  return syncing;
}

let debounce = null;
function syncSoon() {
  clearTimeout(debounce);
  debounce = setTimeout(() => sync(), 4000);
}

async function logOut() {
  state.session = null;
  state.records.clear();
  state.phase = "idle";
  state.lastSync = null;
  await db.clearAll();
  rebuild();
  go("#/konto", true);
}

// MARK: Spillet

/** false, hvis det var et dobbelttryk. */
async function logPlay(item) {
  const now = Date.now() / 1000;
  const last = state.lastPlayed.get(item.id);
  if (last && now - last < REPLAY_WINDOW) return false;
  const uuid = crypto.randomUUID ? crypto.randomUUID() : ([1e7] + -1e3 + -4e3 + -8e3 + -1e11).replace(/[018]/g, (c) => (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16));
  // Med decimaler (som på Mac og iPhone), så tidspunktet altid læses som et kommatal.
  const at = Number.isInteger(now) ? now + 0.001 : now;
  const doc = { kind: "play", key: uuid.toLowerCase(), data: { copy: item.copy.uid, at } };
  const row = { ...doc, updated_at: new Date().toISOString() };
  mergeRows([row]);
  rebuild();
  if (!DEMO) {
    await db.applyRows([row]);
    const pending = (await db.getMeta("pending")) ?? [];
    pending.push(doc);
    await db.setMeta("pending", pending);
    syncSoon();
  }
  return true;
}

// MARK: Navigation

function parseRoute() {
  const h = location.hash.replace(/^#\/?/, "");
  const [path, qs] = h.split("?");
  const parts = path.split("/").map(decodeURIComponent);
  const params = new URLSearchParams(qs ?? "");
  return { name: parts[0] || "reol", arg: parts[1], params };
}

const TABS = [
  { id: "reol", label: "Reol", icon: "books" },
  { id: "hor", label: "Hør", icon: "dice" },
  { id: "scan", label: "Scan", icon: "qr" },
  { id: "sog", label: "Søg", icon: "search" },
  { id: "konto", label: "Konto", icon: "person" },
];

let depth = 0;
function go(hash, replace = false) {
  if (replace) history.replaceState(null, "", hash);
  else { history.pushState(null, "", hash); depth += 1; }
  render();
}
function back(fallback) {
  if (depth > 0) { depth -= 1; history.back(); } else go(fallback, true);
}
window.addEventListener("popstate", () => render());

// MARK: Visning

let unmount = null;
let lastRendered = "";

function render() {
  const app = $("#app");
  const r = parseRoute();
  const welcome = !DEMO && !state.session && !hasShelves();
  const key = `${r.name}/${r.arg ?? ""}?${r.params}`;
  if (TABS.some((t) => t.id === r.name)) state.tab = r.name;

  // Søgesiden bygges kun én gang, så feltet beholder fokus, mens man skriver.
  if (r.name === "sog" && lastRendered === key && $("#q")) { renderResults(); renderTabs(welcome); return; }
  // Scanneren startes ikke forfra, når siden tegnes om (fx efter en synkronisering).
  if (r.name === "scan" && lastRendered === key && $("#scan")) { renderTabs(welcome); return; }
  if (unmount) { unmount(); unmount = null; }
  const scroll = lastRendered === key ? window.scrollY : 0;
  lastRendered = key;

  if (!state.loaded) { app.innerHTML = `<div class="page"><div class="empty"><span class="spinner"></span></div></div>`; return; }
  if (welcome && r.name !== "konto") { history.replaceState(null, "", "#/konto"); return render(); }

  let html = "";
  switch (r.name) {
    case "sektion": html = sectionPage(r.arg); break;
    case "plade": html = recordPage(r.arg, r.params.get("sang")); break;
    case "sog": html = searchPage(); break;
    case "scan": html = scanPage(); break;
    case "hor": html = listenPage(); break;
    case "sortering": html = sortPage(); break;
    case "udseende": html = lookPage(); break;
    case "totrin": html = mfaPage(); break;
    case "statistik": html = statsPage(); break;
    case "konto": html = accountPage(welcome); break;
    default: html = shelvesPage();
  }
  app.innerHTML = (DEMO && r.name !== "scan" ? demoBanner() : "") + html;
  renderTabs(welcome);
  window.scrollTo(0, scroll);
  if (r.name === "sog") { renderResults(); }
  if (r.name === "plade") drawSpines();
  if (r.name === "scan") unmount = startScanner();
  if (r.name === "hor") unmount = mountListenFlow();
  if (r.name === "statistik") mountStats();
  if (r.name === "konto" && state.session && mfa.on === null) refreshSecondFactor();
  if (r.name === "sektion" && state.coverFlow) unmount = mountSectionFlow(r.arg);
}

function demoBanner() {
  return `<div style="position:relative;z-index:2;padding:calc(env(safe-area-inset-top) + 8px) 16px 0;max-width:720px;margin:0 auto">
    <div class="demo-banner"><span>Eksempeldata – intet gemmes.</span><a href="./">Afslut</a></div></div>`;
}

function renderTabs(hidden) {
  const bar = $("#tabbar");
  bar.hidden = hidden;
  bar.innerHTML = TABS.map((t) => `<a href="#/${t.id}" data-tab="${t.id}" ${state.tab === t.id ? 'aria-current="page"' : ""}>${icon(t.icon)}<span>${t.label}</span></a>`).join("");
}

/** Kun statusknappen på Reol (så listen ikke tegnes om under en synkronisering). */
function renderStatus() {
  const el = $("#sync-status");
  if (el) el.outerHTML = syncButton();
  const acc = $("#last-sync");
  if (acc) acc.innerHTML = state.phase === "syncing" ? '<span class="spinner"></span>' : esc(lastSyncText());
}

function syncButton() {
  if (DEMO || !state.session) return '<span id="sync-status"></span>';
  if (state.phase === "syncing") return '<span id="sync-status" class="icon-btn plain" aria-label="Synkroniserer"><span class="spinner"></span></span>';
  if (failed()) return `<button id="sync-status" class="icon-btn warn" data-action="sync-failed" aria-label="Synkroniseringen fejlede">${icon("warn")}</button>`;
  return `<button id="sync-status" class="icon-btn" data-action="sync" aria-label="Synkronisér nu">${icon("sync")}</button>`;
}

function topbar({ title, backTo, right = "" }) {
  return `<div class="topbar">
    ${backTo ? `<button class="back" data-action="back" data-fallback="${esc(backTo)}">${icon("chevL")}<span>Tilbage</span></button>` : '<span class="spacer"></span>'}
    ${title ? `<div class="inline-title">${esc(title)}</div>` : '<span class="spacer"></span>'}
    ${right || (backTo ? '<span style="width:88px"></span>' : "")}
  </div>`;
}

function placementBadge(loc) {
  return loc ? `<span class="badge" aria-label="${esc(locationName(loc))}">${esc(shortName(loc))}</span>` : '<span class="badge none">Ingen plads</span>';
}

function statusLine(item) {
  const s = item.copy.status;
  return isOnShelf(item) ? "" : `<div class="status">${icon(STATUS_ICON[s])}<span>${esc(STATUS[s].label)}</span></div>`;
}

function recordRow({ medium, item, track = null, trackIndex = null, number = null }) {
  const loc = lib(medium).locationOf(item.id);
  const q = trackIndex != null ? `?sang=${trackIndex}` : "";
  return `<a class="row ${number != null ? "numbered" : "with-cover"} ${isOnShelf(item) ? "" : "away"}" href="#/plade/${encodeURIComponent(item.copy.uid)}${q}" data-nav>
    ${number != null ? `<span class="num">${number ?? ""}</span>` : ""}
    ${cover(item.release.thumbURL ?? item.release.coverURL, "", item.release)}
    <span class="grow">
      <div class="t1">${esc(item.release.artist)}</div>
      <div class="t2">${esc(item.release.title)}</div>
      ${statusLine(item)}
      ${track ? `<div class="song" aria-label="Sangen ${esc(track.title)}">${icon("note")}<span>${esc(track.position ? `${track.title} · ${track.position}` : track.title)}</span></div>` : ""}
    </span>
    ${number == null ? placementBadge(loc) : ""}
  </a>`;
}

// MARK: Reol

function shelvesPage() {
  const ms = media();
  let body;
  if (hasShelves()) {
    const m = state.medium, L = lib(m);
    body = `${ms.length > 1 ? `<div class="segmented" role="group" aria-label="Hylde">${ms.map((x) => `<button data-action="medium" data-medium="${x}" aria-pressed="${x === m}">${MEDIUM[x].title}</button>`).join("")}</div>` : ""}
      ${L.shelves.map((shelf) => `<div class="group-title">${esc(MEDIUM[m].shelfWord)} ${shelf}</div>
        <div class="list">${L.locations.filter((l) => l.shelf === shelf).map((loc) => sectionRow(L, loc)).join("")}</div>`).join("")}
      ${L.unplaced.length ? `<p class="footnote" style="margin-top:20px">${L.unplaced.length} ${MEDIUM[m].plural} har endnu ingen plads. De får en plads i appen på computeren.</p>` : ""}`;
  } else if (state.phase === "syncing") {
    body = `<div class="empty"><div class="big-icon">${icon("cloudDown")}</div><h2>Henter dine reoler …</h2><span class="spinner"></span></div>`;
  } else {
    body = `<div class="empty"><div class="big-icon">${icon("books")}</div><h2>Ingen reoler endnu</h2>
      <p>Reolerne laves i appen på computeren og kommer hertil via din konto.</p></div>`;
  }
  return `<main class="page">${topbar({ right: syncButton() })}<h1 class="large-title">Reol</h1>${body}</main>`;
}

function sectionRow(L, loc) {
  const onShelf = L.items(loc.id).filter(isOnShelf);
  const first = onShelf[0]?.release.artist, last = onShelf.at(-1)?.release.artist;
  return `<a class="row" href="#/sektion/${encodeURIComponent(loc.uid)}" data-nav>
    <span class="section-tab" style="--divider:${dividerColor(loc)}" aria-hidden="true">${esc(loc.section)}</span>
    <span class="grow">
      <div class="t1">Sektion ${esc(loc.section)}</div>
      ${first ? `<div class="t2">${esc(first === last ? first : `${first} – ${last}`)}</div>` : ""}
      <div class="t3">${L.onShelfCount(loc.id)} ${MEDIUM[loc.medium].plural}</div>
    </span>
    <span class="chev">${icon("chevR")}</span>
  </a>`;
}

function findLocation(uid) {
  for (const m of MEDIA) { const l = lib(m).locations.find((x) => x.uid === uid); if (l) return { medium: m, loc: l }; }
  return null;
}

function sectionPage(uid) {
  const hit = findLocation(uid);
  if (!hit) return `<main class="page">${topbar({ backTo: "#/reol" })}<div class="empty"><div class="big-icon">${icon("books")}</div><h2>Sektionen findes ikke længere</h2></div></main>`;
  const { medium, loc } = hit, L = lib(medium);
  const numbers = L.shelfNumbers(loc.id);
  const toggle = `<button class="icon-btn" data-action="toggle-flow" aria-pressed="${state.coverFlow}" aria-label="${state.coverFlow ? "Vis som liste" : "Vis som Cover Flow"}">${icon(state.coverFlow ? "list" : "flow")}</button>`;
  if (state.coverFlow) {
    return `<main class="page cf-page">${topbar({ backTo: "#/reol", title: `${MEDIUM[medium].shelfWord} ${loc.shelf} · Sektion ${loc.section}`, right: toggle })}
      <div id="flow" class="cf-box" tabindex="0" aria-label="Cover Flow"></div>
      <div id="flow-caption" class="cf-caption"></div>
    </main>`;
  }
  return `<main class="page">${topbar({ backTo: "#/reol", title: `${MEDIUM[medium].shelfWord} ${loc.shelf} · Sektion ${loc.section}`, right: toggle })}
    <h1 class="large-title" style="font-size:28px">${esc(MEDIUM[medium].shelfWord)} ${loc.shelf} · Sektion ${esc(loc.section)}</h1>
    <div class="list">${L.items(loc.id).map((item) => recordRow({ medium, item, number: numbers.get(item.id) ?? "" })).join("")}</div>
    <p class="footnote">Nummereret fra venstre. Plader, der er ude af reolen, tælles ikke med.</p>
  </main>`;
}

// MARK: Cover Flow og "Hvad skal jeg høre?"

/** Titel, kunstner og nummer under midtercoveret (som CoverFlowCaption på Mac). */
function flowCaption(medium, item, locationID) {
  const el = $("#flow-caption");
  if (!el) return;
  if (!item) { el.innerHTML = `<div class="cf-t2">Sektionen er tom.</div>`; return; }
  const L = lib(medium);
  const locID = locationID ?? L.locationOfCopy.get(item.id);
  const nr = locID != null ? L.shelfNumbers(locID).get(item.id) : null;
  const loc = L.location(locID);
  const line = nr ? `Nr. ${nr} af ${L.onShelfCount(locID)}${locationID == null && loc ? ` · ${MEDIUM[medium].shelfWord} ${loc.shelf} · Sektion ${loc.section}` : ""}` : awayMessage(item) ?? "Ude af reolen";
  el.innerHTML = `<div class="cf-t1">${esc(item.release.title)}</div><div class="cf-t2">${esc(item.release.artist)}</div>
    <div class="cf-t3">${esc(line)}</div>
    <a class="cf-find" href="#/plade/${encodeURIComponent(item.copy.uid)}" data-nav>${icon("search")}<span>Find i reolen</span></a>`;
}

function flowOptions(medium, items, onCenter) {
  return {
    items,
    cover: (it) => it.release.coverURL ?? it.release.thumbURL,
    label: (it) => fullName(it),
    away: (it) => !isOnShelf(it),
    onCenter,
    onOpen: (i) => go(`#/plade/${encodeURIComponent(items[i].copy.uid)}`),
  };
}

function mountSectionFlow(uid) {
  const hit = findLocation(uid), el = $("#flow");
  if (!hit || !el) return null;
  const items = lib(hit.medium).items(hit.loc.id);
  const start = Math.max(0, items.findIndex((it) => it.copy.uid === state.flowCenter.get(uid)));
  const show = (i) => { state.flowCenter.set(uid, items[i]?.copy.uid); flowCaption(hit.medium, items[i], hit.loc.id); };
  const cf = mountCoverFlow(el, { ...flowOptions(hit.medium, items, show), center: start });
  show(cf.center);
  return () => cf.destroy();
}

const listen = { genre: null, decade: null, freshness: "any", recent: [], current: null };
let listenFlow = null;

/** Hele hylden i reolens rækkefølge (det, Cover Flow snurrer igennem). */
function shelfItems(m) { return lib(m).globalOrderItems(); }

function listenPage() {
  if (!hasShelves()) {
    return `<main class="page">${topbar({})}<h1 class="large-title">Hvad skal jeg høre?</h1><div class="empty"><div class="big-icon">${icon("dice")}</div>
      <h2>Ingen reoler endnu</h2><p>Reolerne laves i appen på computeren og kommer hertil via din konto.</p></div></main>`;
  }
  const m = state.medium, L = lib(m), all = L.allItems;
  const ms = media();
  const cands = candidates(all, L, listen, state.lastPlayed);
  const gs = genres(all), ds = decades(all);
  const option = (v, label, sel) => `<option value="${esc(v)}" ${sel ? "selected" : ""}>${esc(label)}</option>`;
  return `<main class="page cf-page">${topbar({})}
    <h1 class="large-title">Hvad skal jeg høre?</h1>
    ${ms.length > 1 ? `<div class="segmented" role="group" aria-label="Hylde">${ms.map((x) => `<button data-action="medium" data-medium="${x}" aria-pressed="${x === m}">${MEDIUM[x].title}</button>`).join("")}</div>` : ""}
    <div id="flow" class="cf-box" tabindex="0" aria-label="Cover Flow"></div>
    <div id="flow-caption" class="cf-caption"></div>
    <button class="pick-btn" data-action="pick" ${cands.length ? "" : "disabled"}>${icon("dice")}<span>Giv mig en plade</span></button>
    <p class="footnote" id="listen-note">${cands.length
      ? `${cands.length} ${MEDIUM[m].plural} matcher · ${MEDIUM[m].plural} du ikke har hørt længe foreslås oftere`
      : esc(noMatchMessage(all, L, listen, state.lastPlayed))}</p>
    <div class="list filters">
      <label class="row kv"><span>Hvilke</span><select data-filter="freshness">${FRESHNESS.map((f) => option(f.id, f.label, listen.freshness === f.id)).join("")}</select></label>
      ${gs.length ? `<label class="row kv"><span>Genre</span><select data-filter="genre">${option("", "Alle genrer", !listen.genre)}${gs.map((g) => option(g, g, listen.genre === g)).join("")}</select></label>` : ""}
      <label class="row kv"><span>Årti</span><select data-filter="decade">${option("", "Alle årtier", listen.decade == null)}${ds.map((d) => option(d, `${d}'erne`, listen.decade === d)).join("")}</select></label>
    </div>
  </main>`;
}

function mountListenFlow() {
  const el = $("#flow");
  if (!el) return null;
  const m = state.medium, items = shelfItems(m);
  const start = Math.max(0, items.findIndex((it) => it.id === listen.current));
  const show = (i) => flowCaption(m, items[i], null);
  listenFlow = mountCoverFlow(el, { ...flowOptions(m, items, show), center: start });
  show(listenFlow.center);
  const cf = listenFlow;
  return () => { cf.destroy(); if (listenFlow === cf) listenFlow = null; };
}

function pickRecord() {
  const m = state.medium, L = lib(m);
  const p = pick(candidates(L.allItems, L, listen, state.lastPlayed), state.lastPlayed, listen.recent);
  if (!p || !listenFlow) return;
  listen.current = p.id;
  listen.recent.push(p.id);
  if (listen.recent.length > 20) listen.recent.shift();
  const i = shelfItems(m).findIndex((it) => it.id === p.id);
  const btn = $("[data-action=pick]");
  if (btn) btn.disabled = true;
  listenFlow.spinTo(i, () => { const b = $("[data-action=pick]"); if (b) b.disabled = false; });
}

// MARK: Sorteringsliste (som på Mac og Windows; fluebenene følger med via kontoen)

function sortEntries() { return sortList(lib(state.medium), state.rules); }

function sortMeta(it) {
  const parts = [];
  if (it.copy.status !== "home") parts.push(STATUS[it.copy.status].label);
  if (it.release.year) parts.push(String(it.release.year));
  const f = (it.release.format ?? "").split(",")[0]?.trim();
  if (f) parts.push(f);
  return parts.join(" · ");
}

function sortRow(e, done) {
  const it = e.item, on = done.has(it.id), away = e.number == null;
  return `<button class="row sort-row ${on ? "on" : ""} ${away ? "away" : ""}" data-action="sort-check" data-id="${it.id}" id="sort-${it.id}" ${away ? 'aria-disabled="true"' : ""}
      aria-label="${esc(`${e.number ? e.number + ". " : ""}${fullName(it)}`)}" aria-pressed="${on}">
    <span class="sort-check">${icon(away ? "dashed" : on ? "checked" : "circle")}</span>
    <span class="num">${e.number ?? "–"}</span>
    <span class="grow"><div class="t1 wrap">${esc(fullName(it))}</div>${sortMeta(it) ? `<div class="t3">${esc(sortMeta(it))}</div>` : ""}</span>
  </button>`;
}

function sortHeader(entries, done) {
  const m = state.medium;
  const countable = entries.filter((e) => e.number != null);
  const total = countable.length, n = countable.filter((e) => done.has(e.item.id)).length;
  return `<div class="list sort-head">
    <p>${m === "vinyl" ? "Rækkefølgen for pladehylden, fra første til sidste plade. Cd'erne har deres egen liste." : "Rækkefølgen for cd-hylden, fra første til sidste cd. Pladerne har deres egen liste."}</p>
    <div class="progress"><span style="width:${total ? (n / total) * 100 : 0}%"></span></div>
    <p class="count">${n === total && total > 0 ? `Alle ${total} ${MEDIUM[m].plural} står på plads` : `${n} af ${total} sat på plads`}</p>
    <div class="sort-buttons">
      <button class="cf-find" data-action="sort-next" ${n === total ? "disabled" : ""}>${icon("chevR")}<span>Næste</span></button>
      <button class="glass-btn" data-action="sort-restart" ${n === 0 ? "disabled" : ""}>${icon("restart")}<span>Start forfra</span></button>
    </div>
  </div>`;
}

function sortPage() {
  const m = state.medium, L = lib(m), ms = media();
  const entries = sortEntries(), done = state.checked[m] ?? new Set();
  const parts = [];
  for (const e of entries) {
    const key = e.location ? e.location.uid : "none";
    if (!parts.length || parts.at(-1).key !== key) parts.push({ key, loc: e.location, entries: [] });
    parts.at(-1).entries.push(e);
  }
  const body = parts.map((p) => {
    let title, note;
    if (p.loc) { const n = L.items(p.loc.id).length; title = locationName(p.loc); note = n === 1 ? `1 ${MEDIUM[m].singular}` : `${n} ${MEDIUM[m].plural}`; }
    else if (!L.locations.length) { title = "Hele hylden"; note = null; }
    else { title = "Uden plads endnu"; note = `Nye ${MEDIUM[m].plural}, der ikke har fået en plads. Rækkefølgen viser, hvor de hører til.`; }
    return `<div class="group-title big" style="margin-bottom:2px">${esc(title)}</div>${note ? `<p class="footnote" style="margin:0 4px 8px">${esc(note)}</p>` : ""}
      <div class="list">${p.entries.map((e) => sortRow(e, done)).join("")}</div>`;
  }).join("");
  return `<main class="page">${topbar({ backTo: "#/konto", title: "Sorteringsliste" })}
    ${ms.length > 1 ? `<div class="segmented" role="group" aria-label="Hylde" style="margin-top:8px">${ms.map((x) => `<button data-action="medium" data-medium="${x}" aria-pressed="${x === m}">${MEDIUM[x].title}</button>`).join("")}</div>` : ""}
    <div id="sort-head">${sortHeader(entries, done)}</div>
    ${entries.length ? body : `<div class="empty"><h2>Ingen ${MEDIUM[m].plural}</h2><p>Der er ingen ${MEDIUM[m].plural} i samlingen endnu.</p></div>`}
  </main>`;
}

/** Gemmer fluebenene som kontoens post `sort_checked_<hylde>` (fælles ID'er, sorteret, som på Mac). */
async function saveChecked(m) {
  const L = lib(m);
  const uids = [...(state.checked[m] ?? [])].map((id) => L.copies.get(id)?.uid).filter(Boolean).sort();
  const doc = { kind: "setting", key: `sort_checked_${m}`, data: { value: uids } };
  const row = { ...doc, updated_at: new Date().toISOString() };
  mergeRows([row]);
  if (DEMO) return;
  await db.applyRows([row]);
  const pending = ((await db.getMeta("pending")) ?? []).filter((d) => !(d.kind === doc.kind && d.key === doc.key));
  pending.push(doc);
  await db.setMeta("pending", pending);
  syncSoon();
}

function toggleSortCheck(id) {
  const m = state.medium, L = lib(m), it = L.item(id);
  if (!it || !isOnShelf(it)) return;
  const set = state.checked[m] ??= new Set();
  if (set.has(id)) set.delete(id); else set.add(id);
  haptic("tick");
  // Kun linjen og tælleren tegnes om, så listen ikke hopper.
  const e = sortEntries();
  const entry = e.find((x) => x.item.id === id);
  const el = $(`#sort-${id}`);
  if (el && entry) el.outerHTML = sortRow(entry, set);
  const head = $("#sort-head");
  if (head) head.innerHTML = sortHeader(e, set);
  saveChecked(m);
}

// MARK: Statistik over brugerne (kun for administratorer; se supabase/admin-stats.sql)

const DEVICE_NAMES = { mac: "Mac", windows: "Windows", iphone: "iPhone", web: "Webapp" };
const daysAgo = (iso) => (iso ? (Date.now() - new Date(iso).getTime()) / 86400000 : Infinity);
const shortDate = (iso) => (iso ? new Date(iso).toLocaleDateString("da-DK", { day: "numeric", month: "short", year: "numeric" }) : "–");

async function loadStats(force = false) {
  if (!state.session || (state.stats?.loading) || (state.stats?.data && !force)) return;
  state.stats = { ...(state.stats ?? {}), loading: true, error: null };
  try {
    const s = await validSession();
    state.stats = { data: await cloud.rpc("admin_stats", s), loading: false, error: null, at: Date.now() };
  } catch (e) {
    state.stats = { data: null, loading: false, error: e.message };
  }
  if (parseRoute().name === "statistik") { lastRendered = ""; render(); }
}

function mountStats() { loadStats(); }

/** Søjlediagram (én serie, accentfarven). Tryk eller hold over en søjle for tallet; ellers vises den seneste. */
function barChart(id, points, unit) {
  if (!points.length) return `<p class="footnote">Ingen data endnu.</p>`;
  const W = 340, H = 120, pad = 18, gap = 2;
  const max = Math.max(1, ...points.map((p) => p.value));
  const bw = (W - gap * (points.length - 1)) / points.length;
  const bars = points.map((p, i) => {
    const h = p.value ? Math.max(3, (p.value / max) * (H - pad)) : 0;
    const x = i * (bw + gap), y = H - h, r = Math.min(4, bw / 2, h);
    const path = h ? `M${x},${H}V${y + r}Q${x},${y} ${x + r},${y}H${x + bw - r}Q${x + bw},${y} ${x + bw},${y + r}V${H}Z` : "";
    return `<g class="bar" data-chart="${id}" data-tip="${esc(`${p.label}: ${p.value} ${unit(p.value)}`)}">
      <rect x="${x}" y="0" width="${bw + gap}" height="${H}" fill="transparent"/>${path ? `<path d="${path}"/>` : ""}</g>`;
  }).join("");
  const last = points.at(-1);
  return `<div class="chart" id="chart-${id}">
    <svg viewBox="0 0 ${W} ${H + 1}" preserveAspectRatio="none" role="img" aria-label="${esc(points.map((p) => `${p.label}: ${p.value}`).join(", "))}">
      <line x1="0" x2="${W}" y1="${pad}" y2="${pad}" class="grid"/><line x1="0" x2="${W}" y1="${H}" y2="${H}" class="base"/>${bars}
    </svg>
    <div class="chart-axis"><span>${esc(points[0].label)}</span><span>højst ${max}</span><span>${esc(last.label)}</span></div>
    <div class="chart-tip" id="tip-${id}">${esc(`${last.label}: ${last.value} ${unit(last.value)}`)}</div>
  </div>`;
}

function weekLabel(d) {
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const week = Math.ceil(((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
  return `Uge ${week}`;
}

function statsPage() {
  const st = state.stats;
  const head = topbar({ backTo: "#/konto", title: "Statistik", right: `<button class="icon-btn" data-action="stats-refresh" aria-label="Opdatér">${st?.loading ? '<span class="spinner"></span>' : icon("sync")}</button>` });
  if (!state.session) return `<main class="page">${head}<div class="empty"><h2>Log ind først</h2></div></main>`;
  if (!st || (st.loading && !st.data)) return `<main class="page">${head}<div class="empty"><span class="spinner"></span></div></main>`;
  if (st.error) {
    return `<main class="page">${head}<div class="empty"><div class="big-icon">${icon("warn")}</div><h2>Statistikken kunne ikke hentes</h2>
      <p>${esc(st.error)} Er <b>supabase/admin-stats.sql</b> kørt i Supabase, og står du i admin_users?</p></div></main>`;
  }
  const users = st.data.users ?? [];
  const active7 = users.filter((u) => daysAgo(u.last_active) <= 7).length;
  const active30 = users.filter((u) => daysAgo(u.last_active) <= 30).length;
  const now = new Date();
  const newMonth = users.filter((u) => { const d = new Date(u.created_at); return d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth(); }).length;

  // Afspilninger pr. uge: de seneste 26 uger, også uger uden afspilninger.
  const byWeek = new Map((st.data.plays_by_week ?? []).map((w) => [w.week, w.plays]));
  const monday = new Date(now); monday.setHours(0, 0, 0, 0); monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7));
  const weeks = [];
  for (let i = 25; i >= 0; i--) {
    const d = new Date(monday); d.setDate(d.getDate() - i * 7);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    weeks.push({ label: weekLabel(d), value: byWeek.get(key) ?? 0 });
  }
  // Nye brugere pr. måned: de seneste 12 måneder.
  const months = [];
  for (let i = 11; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const value = users.filter((u) => { const c = new Date(u.created_at); return c.getFullYear() === d.getFullYear() && c.getMonth() === d.getMonth(); }).length;
    months.push({ label: d.toLocaleDateString("da-DK", { month: "short", year: "2-digit" }), value });
  }
  const devices = Object.keys(DEVICE_NAMES).map((k) => ({ k, n: users.filter((u) => (u.devices ?? []).includes(k)).length }));
  const tile = (n, label) => `<div class="tile"><div class="tile-n">${n}</div><div class="tile-l">${esc(label)}</div></div>`;
  return `<main class="page">${head}
    <h1 class="large-title">Statistik</h1>
    <div class="tiles">${tile(users.length, users.length === 1 ? "bruger i alt" : "brugere i alt")}${tile(active7, "aktive de sidste 7 dage")}${tile(active30, "aktive de sidste 30 dage")}${tile(newMonth, "nye i denne måned")}</div>
    <h2 class="group-title big">Spillet pr. uge</h2>
    <div class="list chart-card">${barChart("plays", weeks, (n) => (n === 1 ? "afspilning" : "afspilninger"))}</div>
    <h2 class="group-title big">Nye brugere pr. måned</h2>
    <div class="list chart-card">${barChart("signups", months, (n) => (n === 1 ? "ny bruger" : "nye brugere"))}</div>
    <h2 class="group-title big">Enheder</h2>
    <div class="list">${devices.map((d) => `<div class="row kv"><span>${DEVICE_NAMES[d.k]}</span><span class="v">${d.n} ${d.n === 1 ? "bruger" : "brugere"}</span></div>`).join("")}</div>
    <p class="footnote">En bruger tælles med på en enhed, når den har sendt noget til kontoen derfra.</p>
    <h2 class="group-title big">Brugere</h2>
    <div class="list">${users.map((u) => `<div class="row user-row"><span class="grow">
        <div class="t1">${esc(u.email ?? "(uden e-mail)")}</div>
        <div class="t3">Oprettet ${esc(shortDate(u.created_at))} · ${u.last_active ? `sidst aktiv ${esc(relative(new Date(u.last_active).getTime() / 1000))}` : "aldrig brugt"}</div>
        <div class="t3">${u.copies} ${u.copies === 1 ? "plade" : "plader"} · ${u.sections} ${u.sections === 1 ? "sektion" : "sektioner"} · ${u.plays}× spillet</div>
      </span><span class="devices">${(u.devices ?? []).map((d) => `<span class="badge">${esc(DEVICE_NAMES[d] ?? d)}</span>`).join("")}</span></div>`).join("")}</div>
    <p class="footnote">Hentet ${esc(new Date(st.at).toLocaleString("da-DK", { dateStyle: "medium", timeStyle: "short" }))}. Kun du kan se denne side.</p>
  </main>`;
}

// MARK: Pladen ("Find i reolen")

function recordPage(uid, trackParam) {
  const where = state.byUID.get(uid);
  const item = where && lib(where.medium).item(where.id);
  if (!item) return `<main class="page">${topbar({ backTo: `#/${state.tab}` })}<div class="empty"><div class="big-icon">${icon("dashed")}</div><h2>Pladen findes ikke længere</h2></div></main>`;
  const L = lib(where.medium);
  const track = trackParam != null ? Number(trackParam) : null;
  const loc = L.locationOf(item.id), adv = L.referenceAdvice(item.id), n = L.neighbors(item.id);
  const r = item.release;
  let place;
  if (loc && adv && n) {
    const away = !isOnShelf(item);
    const position = n.position ?? 1;
    const hint = `${away ? "Plads" : "Nr."} ${position} af ${n.sectionCount} fra venstre`;
    const dc = dividerColor(loc);
    place = `<section class="card" aria-label="${esc(locationName(loc))}" style="--divider:${dc}">
        <div class="eyebrow">${away ? "Her plejer den at stå" : "Gå til"}</div>
        <div class="divider"><span class="tab">${esc(loc.section)}</span><span class="names"><span class="shelf">${esc(MEDIUM[loc.medium].shelfWord)} ${loc.shelf}</span><span class="sec">Sektion ${esc(loc.section)}</span></span></div>
        <svg class="spines" data-position="${position}" data-count="${n.sectionCount}" role="img" aria-label="Plade ${position} af ${n.sectionCount} i sektionen"></svg>
        <div class="hint">${esc(hint)}</div>
      </section>
      ${away ? `<div class="away-line">${icon(STATUS_ICON[item.copy.status])}<span>${esc(STATUS[item.copy.status].label)}${item.copy.statusNote ? `: ${esc(item.copy.statusNote)}` : ""}</span></div>` : ""}
      ${refCard("Start ved", adv.primary)}
      ${adv.secondary ? refCard("Så", adv.secondary) : ""}
      ${adv.artistBlockHint || adv.sectionEdgeHint ? `<div class="hints">
        ${adv.artistBlockHint ? `<div>${icon("stack")}<span>${esc(adv.artistBlockHint)}</span></div>` : ""}
        ${adv.sectionEdgeHint ? `<div>${icon(n.reachedSectionEnd ? "toRight" : "toLeft")}<span>${esc(adv.sectionEdgeHint)}</span></div>` : ""}
      </div>` : ""}
      <a class="glass-btn" href="#/sektion/${encodeURIComponent(loc.uid)}" data-nav>${icon("listNum")}<span>Vis hele sektion ${esc(shortName(loc))}</span></a>`;
  } else {
    place = `<section class="card"><div style="display:flex;gap:10px;align-items:center;font-size:20px">${icon("dashed")}<span>Pladen har endnu ingen fysisk placering.</span></div></section>`;
  }
  const count = state.count.get(item.id) ?? 0, last = state.lastPlayed.get(item.id);
  const plays = count > 0 && last ? `<div class="plays">${icon("note")}<span>Spillet ${count} ${count === 1 ? "gang" : "gange"}, senest ${esc(relative(last))}</span></div>` : "";
  const tracks = r.tracks.length ? `<details class="tracks" ${track != null ? "open" : ""}>
      <summary><span>Sange (${r.tracks.length})</span><span class="chev">${icon("chevR")}</span></summary>
      <div style="margin-top:8px">${r.tracks.map((t, i) => `<div class="track ${i === track ? "hit" : ""}"><span class="pos">${esc(t.position)}</span><span class="ttl">${esc(t.title)}</span>${t.duration ? `<span class="dur">${esc(t.duration)}</span>` : ""}</div>`).join("")}</div>
    </details>` : "";
  const img = r.coverURL ?? r.thumbURL;
  return `<div class="backdrop" aria-hidden="true">${img ? `<img src="${esc(img)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">` : ""}</div>
    <main class="page has-play">${topbar({ backTo: `#/${state.tab}`, title: r.artist })}
      <header class="record-head">${cover(img, "", r)}<div style="min-width:0">
        <div class="artist">${esc(r.artist)}</div><div class="title">${esc(r.title)}</div>
        ${pressingLine(r) ? `<div class="detail">${esc(pressingLine(r))}</div>` : ""}${r.format ? `<div class="detail faint">${esc(r.format)}</div>` : ""}
      </div></header>
      ${place}
      ${plays}
      ${tracks}
    </main>
    <div class="play-bar"><button class="play-btn" data-action="play" data-uid="${esc(uid)}">${icon("play")}<span>Spillet</span></button></div>`;
}

function refCard(title, ref) {
  const it = ref.item;
  const pic = it ? cover(it.release.thumbURL ?? it.release.coverURL, "", it.release)
    : `<span class="cover">${icon(ref.side === "sectionStart" ? "toLeft" : "toRight")}</span>`;
  return `<section class="card thin"><div class="ref">${pic}<div style="min-width:0">
    <div class="eyebrow">${esc(title)}</div>
    ${it ? `<div class="name">${esc(fullName(it))}</div>` : ""}
    <div class="why">${esc(ref.reason)}</div>
  </div></div></section>`;
}

/** Sektionen som pladerygge set forfra: én streg pr. plade, målet fremhævet (som på Mac og iPhone). */
function drawSpines() {
  for (const svg of document.querySelectorAll("svg.spines")) {
    const width = svg.clientWidth || 300, height = 30;
    const n = Math.max(Number(svg.dataset.count), 1);
    const idx = Math.min(Math.max(Number(svg.dataset.position) - 1, 0), n - 1);
    const slot = width / n;
    let out = "";
    if (slot >= 3) {
      // Rygge i forskellig tykkelse, som rigtige plader (samme mønster som på Mac).
      const maxW = Math.min(Math.max(slot * 0.8, 2), 14);
      for (let i = 0; i < n; i++) {
        const r = Number((BigInt(i) * 2654435761n) % 1000n) / 1000, t = i === idx;
        const w = t ? maxW : maxW * (0.45 + 0.55 * r), h = t ? height : height * (0.72 + 0.16 * (1 - r));
        const x = slot * (i + 0.5) - w / 2;
        out += `<rect x="${x.toFixed(1)}" y="${(height - h).toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}" rx="1" fill="${t ? "var(--divider, var(--accent))" : "var(--tertiary)"}"/>`;
      }
    } else {
      const x = n > 1 ? (idx / (n - 1)) * (width - 6) : 0;
      out = `<rect x="0" y="${height - 6}" width="${width}" height="6" rx="3" fill="var(--tertiary)"/><rect x="${x.toFixed(1)}" y="0" width="6" height="${height}" rx="2" fill="var(--divider, var(--accent))"/>`;
    }
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.innerHTML = out;
  }
}
window.addEventListener("resize", () => drawSpines());

// MARK: Søg

function searchPage() {
  return `<main class="page">
    <div class="search-field"><label class="search-box">${icon("search")}
      <span class="sr">Søg</span>
      <input id="q" type="search" enterkeyhint="search" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="Kunstner, titel, sang …" value="${esc(state.query)}">
      <button class="clear" data-action="clear" aria-label="Ryd" ${state.query ? "" : "hidden"}>${icon("close")}</button>
    </label></div>
    <div id="results"></div>
  </main>`;
}

function renderResults() {
  const el = $("#results");
  if (!el) return;
  const q = state.query.trim();
  if (!q) {
    const recent = recentlyPlayed();
    el.innerHTML = recent.length
      ? `<h2 class="group-title big">Senest spillet</h2><div class="list">${recent.map((h) => recordRow(h)).join("")}</div>`
      : `<div class="empty"><div class="big-icon">${icon("search")}</div><h2>Søg i din samling</h2><p>Skriv kunstner, titel, en sang, pladeselskab eller katalognummer.</p></div>`;
    return;
  }
  const hits = search(q);
  el.innerHTML = hits.length
    ? `<div class="list">${hits.map((h) => recordRow({ ...h, trackIndex: h.track ? h.item.release.tracks.indexOf(h.track) : null })).join("")}</div>`
    : `<div class="empty"><div class="big-icon">${icon("search")}</div><h2>Ingen resultater for “${esc(q)}”</h2><p>Tjek stavningen, eller prøv en ny søgning.</p></div>`;
}

/** Op til 10 forskellige plader, nyeste først. */
function recentlyPlayed() {
  const seen = new Set(), out = [];
  for (const p of state.plays) {
    if (seen.has(p.copyID)) continue;
    seen.add(p.copyID);
    for (const m of MEDIA) { const it = lib(m).item(p.copyID); if (it) { out.push({ medium: m, item: it }); break; } }
    if (out.length === 10) break;
  }
  return out;
}

// MARK: Scan

function scanPage() {
  return `<div class="scan" id="scan">
    <video id="cam" playsinline muted autoplay></video>
    <div class="frame" aria-hidden="true"></div>
    <div class="head">Scan skilt</div>
    <div class="note"><span id="scan-note">Peg kameraet på QR-koden på et reolskilt.</span></div>
  </div>`;
}

function scanUnavailable(text) {
  const el = $("#scan");
  if (!el) return;
  el.outerHTML = `<main class="page"><h1 class="large-title">Scan skilt</h1><div class="empty"><div class="big-icon">${icon("qr")}</div>
    <h2>Kameraet kan ikke scanne her</h2><p>${esc(text)}</p></div></main>`;
}

let jsQRLoading = null;
function loadJsQR() {
  if (window.jsQR) return Promise.resolve(window.jsQR);
  jsQRLoading ??= new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "vendor/jsQR.js";
    s.onload = () => resolve(window.jsQR);
    s.onerror = reject;
    document.head.append(s);
  });
  return jsQRLoading;
}

function startScanner() {
  let stream = null, stopped = false, timer = null, lastCode = "";
  const stop = () => {
    stopped = true;
    clearTimeout(timer);
    stream?.getTracks().forEach((t) => t.stop());
  };
  (async () => {
    if (!navigator.mediaDevices?.getUserMedia) {
      scanUnavailable("Denne browser kan ikke bruge kameraet. Åbn siden i Safari.");
      return;
    }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false });
    } catch {
      scanUnavailable("Giv adgang til kameraet, når telefonen spørger. Har du sagt nej, så åbn Indstillinger › Safari › Kamera, og vælg Spørg eller Tillad.");
      return;
    }
    if (stopped) { stream.getTracks().forEach((t) => t.stop()); return; }
    const video = $("#cam");
    video.srcObject = stream;
    await video.play().catch(() => {});
    let detect;
    if ("BarcodeDetector" in window && (await BarcodeDetector.getSupportedFormats?.().catch(() => []))?.includes("qr_code")) {
      const det = new BarcodeDetector({ formats: ["qr_code"] });
      detect = async () => (await det.detect(video))[0]?.rawValue ?? null;
    } else {
      const jsQR = await loadJsQR();
      const canvas = document.createElement("canvas");
      const ctx = canvas.getContext("2d", { willReadFrequently: true });
      detect = async () => {
        const vw = video.videoWidth, vh = video.videoHeight;
        if (!vw || !vh) return null;
        const scale = Math.min(1, 720 / Math.max(vw, vh));
        canvas.width = Math.round(vw * scale); canvas.height = Math.round(vh * scale);
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
        return jsQR(img.data, img.width, img.height, { inversionAttempts: "dontInvert" })?.data ?? null;
      };
    }
    const tick = async () => {
      if (stopped) return;
      let code = null;
      try { code = await detect(); } catch { /* næste billede */ }
      if (code && code !== lastCode) {
        lastCode = code;
        const hit = sectionForScanCode(code);
        if (hit) { stop(); go(`#/sektion/${encodeURIComponent(hit.location.uid)}`); return; }
        const note = $("#scan-note");
        if (note) note.textContent = "Koden hører ikke til en af dine sektioner.";
      }
      timer = setTimeout(tick, 150);
    };
    tick();
  })();
  return stop;
}

// MARK: Konto

const login = { email: "", password: "", useMail: false, mailSent: false, code: "", busy: false };

function lastSyncText() {
  return state.lastSync ? new Date(state.lastSync).toLocaleString("da-DK", { dateStyle: "medium", timeStyle: "short" }) : "Ikke endnu";
}

// MARK: Udseende (tema og stil). Gemmes kun på denne enhed (appearance.js sætter dem, før siden tegnes).

const LOOK_THEMES = [
  { id: "", name: "Automatisk", note: "Følger telefonen" },
  { id: "light", name: "Lys" },
  { id: "dark", name: "Mørk" },
];
const LOOK_STYLES = [
  { id: "", name: "Standard", note: "Rent og enkelt, som iPhones egne apps", swatch: ["#F2F2F7", "#FFFFFF", "#1C6E66"] },
  { id: "kasse", name: "Pladekasse", note: "Varm benhvid som pap og papir, rustfarvede knapper", swatch: ["#EAE2D3", "#16130F", "#A9572A"] },
  { id: "cover", name: "Farve fra coveret", note: "Varm papirfarve. Pladeskærmen farves af coveret", swatch: ["#F3EFE8", "#6E2F45", "#E58C6A"] },
  { id: "fokus", name: "Covers i fokus", note: "Varm papirfarve. Store covers på pladeskærmen og i listerne", swatch: ["#F3EFE8", "#FFFDF9", "#8A7560"] },
];
const look = { theme: safeLocal.get("theme") ?? "", style: safeLocal.get("style") ?? "" };
if (!LOOK_THEMES.some((x) => x.id === look.theme)) look.theme = "";
if (!LOOK_STYLES.some((x) => x.id === look.style)) look.style = "";

function applyLook() {
  const root = document.documentElement;
  if (look.theme) root.dataset.theme = look.theme; else delete root.dataset.theme;
  if (look.style) root.dataset.style = look.style; else delete root.dataset.style;
  // Statuslinjen og browserens kant følger baggrunden.
  const bg = getComputedStyle(root).getPropertyValue("--bg").trim();
  document.querySelectorAll('meta[name="theme-color"]').forEach((m) => { m.content = bg; });
}
applyLook();
window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", applyLook);

function lookRow(action, x, current) {
  const on = x.id === current;
  const swatch = x.swatch ? `<span class="swatch" aria-hidden="true">${x.swatch.map((c) => `<span style="background:${c}"></span>`).join("")}</span>` : "";
  return `<button class="row look-row" data-action="${action}" data-v="${x.id}" aria-pressed="${on}">${swatch}
    <span class="grow"><div>${esc(x.name)}</div>${x.note ? `<div class="t3" style="white-space:normal">${esc(x.note)}</div>` : ""}</span>
    ${on ? `<span class="check">${icon("check")}</span>` : ""}</button>`;
}

function lookPage() {
  return `<main class="page">${topbar({ backTo: "#/konto", title: "Udseende" })}
    <h1 class="large-title" style="font-size:28px">Udseende</h1>
    <div class="group-title">Tema</div>
    <div class="list">${LOOK_THEMES.map((x) => lookRow("look-theme", x, look.theme)).join("")}</div>
    <div class="group-title">Stil</div>
    <div class="list">${LOOK_STYLES.map((x) => lookRow("look-style", x, look.style)).join("")}</div>
    <p class="footnote">Hver stil har en lys og en mørk udgave. Valget gælder kun på denne enhed.</p>
  </main>`;
}

/** "Indstillinger" øverst under Konto (som i iPhone-appen). */
function settingsGroup(welcome) {
  if (welcome) return "";
  return `<div class="group-title">Indstillinger</div>
    <div class="list"><a class="row" href="#/udseende" data-nav>${icon("palette")}<span class="grow">Udseende</span><span class="t2">${esc(LOOK_STYLES.find((x) => x.id === look.style).name)}</span><span class="chev">${icon("chevR")}</span></a>
      ${hasShelves() ? `<a class="row" href="#/sortering" data-nav>${icon("checklist")}<span class="grow">Sorteringsliste</span><span class="chev">${icon("chevR")}</span></a>` : ""}
      ${state.isAdmin && state.session ? `<a class="row" href="#/statistik" data-nav>${icon("chart")}<span class="grow">Statistik over brugerne</span><span class="chev">${icon("chevR")}</span></a>` : ""}</div>
    ${hasShelves() ? `<p class="footnote">Sorteringslisten er hele rækkefølgen med flueben, så du kan have telefonen med, når du stiller reolen op. Fluebenene er de samme som på computeren.</p>` : ""}`;
}

function accountPage(welcome) {
  const msg = failed() ? `<div class="message">${icon("warn")}<span>${esc(failed())}</span></div>` : "";
  if (state.session) {
    return `<main class="page">${topbar({})}<h1 class="large-title">Konto</h1>
      ${settingsGroup(false)}
      <div class="group-title">Konto</div>
      <div class="list">
        <div class="row kv"><span>Logget ind som</span><span class="v">${esc(state.email || state.session.email)}</span></div>
        <div class="row kv"><span>Senest synkroniseret</span><span class="v" id="last-sync">${state.phase === "syncing" ? '<span class="spinner"></span>' : esc(lastSyncText())}</span></div>
        ${msg}
      </div>
      <p class="footnote">Reoler, placeringer og lyttelog er de samme som på din computer (Mac eller Windows). Appen synkroniserer selv, når den åbnes, kort efter "Spillet" og hvert 5. minut.</p>
      ${mfaSection()}
      <div class="list" style="margin-top:22px">
        <button class="row btn-row" data-action="sync" ${state.phase === "syncing" ? "disabled" : ""}>${icon("sync")}<span>Synkronisér nu</span></button>
        <button class="row btn-row danger" data-action="logout">${icon("logout")}<span>Log ud</span></button>
      </div>
      <p class="footnote">Når du logger ud, fjernes reolerne fra denne telefon. De ligger stadig på kontoen.</p>
      ${installHint()}
    </main>`;
  }
  const L = login;
  const footer = !L.useMail
    ? "Adgangskoden vælger du under Konto i appen på din computer, mens du er logget ind der."
    : L.mailSent
      ? `Vi har sendt en mail til ${L.email}. Hold fingeren på linket i mailen, vælg Kopiér, og sæt det ind ovenfor. Tryk ikke på linket – hvert link virker kun én gang. Kun den nyeste mail virker.`
      : "Du får en mail med et link – ingen adgangskode. Der kan højst sendes 2 mails i timen.";
  const busy = L.busy ? '<span class="spinner" style="margin-left:auto"></span>' : "";
  let buttons;
  if (!L.useMail) {
    buttons = `<button class="row btn-row" data-action="signin" ${L.busy || !L.email.includes("@") || !L.password ? "disabled" : ""}>${icon("login")}<span>Log ind</span>${busy}</button>
      <button class="row btn-row" data-action="use-mail">${icon("mail")}<span>Har ingen adgangskode – send en mail i stedet</span></button>`;
  } else if (L.mailSent) {
    buttons = `<button class="row btn-row" data-action="complete" ${L.busy || !L.code.trim() ? "disabled" : ""}>${icon("login")}<span>Log ind</span>${busy}</button>
      <button class="row btn-row" data-action="new-mail">${icon("mail")}<span>Send en ny mail</span></button>`;
  } else {
    buttons = `<button class="row btn-row" data-action="send-mail" ${L.busy || !L.email.includes("@") ? "disabled" : ""}>${icon("mail")}<span>Send mail</span>${busy}</button>`;
  }
  if (L.useMail) buttons += `<button class="row btn-row" data-action="use-password">${icon("key")}<span>Log ind med adgangskode i stedet</span></button>`;
  return `<main class="page">${topbar({})}<h1 class="large-title">${welcome ? "Vinyl Shelf" : "Konto"}</h1>
    ${settingsGroup(welcome)}
    ${welcome ? `<div class="welcome"><div class="big-icon">${icon("books")}</div><h2>Find dine plader i reolen</h2>
      <p>Log ind med den samme e-mail og adgangskode som i appen på din computer. Så kommer dine reoler, placeringer og lyttelog hertil.</p></div>` : ""}
    <div class="group-title">Log ind på din konto</div>
    <form class="list" data-form="login" autocomplete="on">
      <label class="field"><span class="sr">E-mail</span><input name="email" type="email" inputmode="email" autocomplete="username" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="dig@eksempel.dk" value="${esc(L.email)}" ${L.mailSent ? "disabled" : ""}></label>
      ${!L.useMail ? `<label class="field"><span class="sr">Adgangskode</span><input name="password" type="password" autocomplete="current-password" placeholder="Adgangskode" value="${esc(L.password)}"></label>`
        : L.mailSent ? `<label class="field"><span class="sr">Linket eller koden fra mailen</span><textarea name="code" rows="2" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="Linket eller koden fra mailen">${esc(L.code)}</textarea></label>` : ""}
      ${msg}
      <button type="submit" hidden></button>
    </form>
    <p class="footnote">${esc(footer)}</p>
    <div class="list" style="margin-top:22px">${buttons}</div>
    ${welcome ? `<p class="footnote" style="margin-top:22px"><a href="?demo">Prøv med eksempeldata</a></p>` : ""}
    ${installHint()}
  </main>`;
}

function installHint() {
  const standalone = window.matchMedia?.("(display-mode: standalone)").matches || navigator.standalone;
  if (standalone || DEMO) return "";
  return `<div class="group-title">Læg appen på hjemmeskærmen</div>
    <div class="list"><div class="message">${icon("share")}<span>Tryk på Del-knappen i Safari, og vælg <b>Føj til hjemmeskærm</b>. Så åbner Vinyl Shelf i fuld skærm som en app.</span></div></div>`;
}

async function doSignIn() {
  login.busy = true; render();
  try {
    const s = await cloud.signIn(login.email.trim().toLowerCase(), login.password);
    login.password = "";
    state.email = s.email;
    await db.setMeta("email", state.email);
    login.busy = false;
    await loggedIn(s);
    go("#/reol", true);
  } catch (e) {
    state.phase = { failed: e.message };
    login.busy = false;
    render();
  }
}

async function doSendMail() {
  login.busy = true; render();
  try {
    await cloud.requestMail(login.email.trim().toLowerCase(), location.origin + location.pathname);
    login.mailSent = true;
    state.phase = "idle";
  } catch (e) { state.phase = { failed: e.message }; }
  login.busy = false;
  render();
}

async function doComplete() {
  const t = login.code.trim();
  login.busy = true; render();
  try {
    let s = null;
    if (t.includes("/") || t.includes(":")) {
      s = await cloud.verifyEmailLink(t);
      if (!s) {
        const hash = t.includes("#") ? t.slice(t.indexOf("#")) : "";
        s = cloud.sessionFromHash(hash);
      }
      if (!s) throw new cloud.CloudError("Det indsatte er ikke et login-link. Kopiér linket fra mailen (hold fingeren på linket › Kopiér).");
    } else {
      s = await cloud.verifyCode(login.email.trim().toLowerCase(), t.replace(/\D/g, ""));
    }
    if (!s.email) s.email = login.email.trim().toLowerCase();
    state.email = s.email;
    Object.assign(login, { code: "", mailSent: false, useMail: false, busy: false });
    await loggedIn(s);
    go("#/reol", true);
  } catch (e) {
    state.phase = { failed: e.message };
    login.busy = false;
    render();
  }
}

// MARK: Hændelser

document.addEventListener("click", async (ev) => {
  const nav = ev.target.closest("a[data-nav], .tabbar a");
  if (nav && !ev.defaultPrevented && ev.button === 0 && !ev.metaKey && !ev.ctrlKey) {
    ev.preventDefault();
    haptic("tick", true);
    const href = nav.getAttribute("href");
    if (nav.closest(".tabbar")) {
      // En fane åbner sin forside; trykkes på den aktive fane, rulles til toppen.
      if (state.tab === nav.dataset.tab && parseRoute().name === nav.dataset.tab) { window.scrollTo({ top: 0, behavior: "smooth" }); return; }
      depth = 0;
      go(href, true);
    } else go(href);
    return;
  }
  const el = ev.target.closest("[data-action]");
  if (!el || el.disabled) return;
  const a = el.dataset.action;
  // Et let klik ved hvert tryk på en knap. Det skal ske med det samme: iPhone giver kun haptik under selve trykket
  // (ikke efter en ventetid, fx når "Spillet" er sendt). Fluebenet i sorteringslisten klikker selv.
  if (a !== "sort-check") haptic("tick", true);
  if (a === "back") back(el.dataset.fallback);
  else if (a === "medium") { state.medium = el.dataset.medium; safeLocal.set("medium", state.medium); render(); }
  else if (a === "sync") sync(true);
  else if (a === "sync-failed") { toast(failed()); sync(true); }
  else if (a === "logout") logOut();
  else if (a === "clear") { state.query = ""; const q = $("#q"); q.value = ""; q.focus(); el.hidden = true; renderResults(); }
  else if (a === "signin") doSignIn();
  else if (a === "toggle-flow") { state.coverFlow = !state.coverFlow; safeLocal.set("coverFlow", state.coverFlow ? "1" : ""); lastRendered = ""; render(); }
  else if (a === "pick") pickRecord();
  else if (a === "stats-refresh") loadStats(true);
  else if (a === "sort-check") toggleSortCheck(Number(el.dataset.id));
  else if (a === "mfa-start") mfaStart();
  else if (a === "mfa-next") { mfa.step = 2; mfa.error = null; lastRendered = ""; render(); }
  else if (a === "mfa-prev") { mfa.step = Math.max(0, mfa.step - 1); mfa.error = null; lastRendered = ""; render(); }
  else if (a === "mfa-confirm") mfaConfirm();
  else if (a === "mfa-submit") submitNeededCode();
  else if (a === "mfa-off") mfaDisable();
  else if (a === "mfa-copy") { navigator.clipboard?.writeText(mfa.enrollment?.secret ?? "").catch(() => {}); mfa.copied = true; lastRendered = ""; render(); }
  else if (a === "look-theme" || a === "look-style") {
    const k = a === "look-theme" ? "theme" : "style";
    look[k] = el.dataset.v;
    safeLocal.set(k, look[k]);
    applyLook();
    lastRendered = "";
    render();
  }
  else if (a === "sort-next") {
    const next = sortEntries().find((e) => e.number != null && !(state.checked[state.medium] ?? new Set()).has(e.item.id));
    if (next) $(`#sort-${next.item.id}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
  }
  else if (a === "sort-restart") {
    if (confirm(`Fjern fluebenene ved alle ${MEDIUM[state.medium].plural} på denne hylde?`)) {
      state.checked[state.medium] = new Set();
      saveChecked(state.medium);
      lastRendered = "";
      render();
    }
  }
  else if (a === "send-mail") doSendMail();
  else if (a === "complete") doComplete();
  else if (a === "use-mail") { login.useMail = true; state.phase = "idle"; render(); }
  else if (a === "use-password") { Object.assign(login, { useMail: false, mailSent: false, code: "" }); state.phase = "idle"; render(); }
  else if (a === "new-mail") { Object.assign(login, { mailSent: false, code: "" }); render(); }
  else if (a === "play") {
    const where = state.byUID.get(el.dataset.uid);
    const item = where && lib(where.medium).item(where.id);
    if (!item) return;
    const ok = await logPlay(item);
    const label = el.querySelector("span");
    el.classList.add("done");
    el.querySelector("svg").outerHTML = icon("check");
    label.textContent = ok ? "Registreret" : "Allerede registreret";
    haptic(ok ? "success" : "edge");
    const plays = $(".plays");
    const count = state.count.get(item.id) ?? 0, last = state.lastPlayed.get(item.id);
    const html = `<div class="plays">${icon("note")}<span>Spillet ${count} ${count === 1 ? "gang" : "gange"}, senest ${esc(relative(last))}</span></div>`;
    if (plays) plays.outerHTML = html; else $(".page.has-play").insertAdjacentHTML("beforeend", html);
    setTimeout(() => {
      if (!el.isConnected) return;
      el.classList.remove("done");
      el.querySelector("svg").outerHTML = icon("play");
      label.textContent = "Spillet";
    }, 2000);
  }
});

// Statistikkens søjler: tryk eller hold over en søjle, så står tallet under diagrammet.
function showBarTip(ev) {
  const g = ev.target.closest?.("g.bar");
  if (!g) return;
  const tip = $(`#tip-${g.dataset.chart}`);
  if (tip) tip.textContent = g.dataset.tip;
  g.closest("svg").querySelectorAll("g.bar.on").forEach((x) => x.classList.remove("on"));
  g.classList.add("on");
}
document.addEventListener("pointerover", showBarTip);
document.addEventListener("pointerdown", showBarTip);

let searchTimer = null;
document.addEventListener("input", (ev) => {
  const t = ev.target;
  if (t.id === "q") {
    state.query = t.value;
    const clear = $(".search-box .clear");
    if (clear) clear.hidden = !t.value;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(renderResults, 60);
    return;
  }
  if (t.dataset.filter) {
    const v = t.value;
    listen[t.dataset.filter] = t.dataset.filter === "decade" ? (v === "" ? null : Number(v)) : (v || (t.dataset.filter === "freshness" ? "any" : null));
    lastRendered = "";
    render();
    return;
  }
  if (t.dataset.mfa === "code") {
    mfa.code = t.value;
    // Kun knappen opdateres, så feltet beholder fokus.
    const b = $("[data-action=mfa-confirm], [data-action=mfa-submit]");
    if (b) b.disabled = mfa.busy || mfa.code.replace(/\D/g, "").length !== 6;
    return;
  }
  const form = t.closest("form[data-form=login]");
  if (form) {
    login[t.name] = t.value;
    // Kun knapperne opdateres, så feltet beholder fokus.
    const ok = !login.busy && login.email.includes("@");
    const set = (action, enabled) => { const b = $(`[data-action=${action}]`); if (b) b.disabled = !enabled; };
    set("signin", ok && !!login.password);
    set("send-mail", ok);
    set("complete", !login.busy && !!login.code.trim());
  }
});

document.addEventListener("submit", (ev) => {
  if (!ev.target.matches("form[data-form=login]")) return;
  ev.preventDefault();
  if (!login.useMail) { if (login.email.includes("@") && login.password) doSignIn(); }
  else if (login.mailSent) { if (login.code.trim()) doComplete(); }
  else if (login.email.includes("@")) doSendMail();
});

document.addEventListener("keydown", (ev) => {
  if (ev.key === "Enter" && ev.target.id === "q") ev.target.blur(); // skjul tastaturet
});

document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") sync(); });
setInterval(() => { if (document.visibilityState === "visible") sync(); }, SYNC_EVERY);

// MARK: Start

async function start() {
  state.medium = MEDIA.includes(safeLocal.get("medium")) ? safeLocal.get("medium") : "vinyl";
  state.coverFlow = safeLocal.get("coverFlow") === "1";
  if (DEMO) {
    try {
      const rows = await (await fetch("demo-records.json")).json();
      mergeRows(rows);
    } catch { toast("Eksempeldata kunne ikke hentes."); }
  } else {
    for (const r of await db.allRecords()) state.records.set(`${r.kind}|${r.key}`, r);
    state.session = (await db.getMeta("session")) ?? null;
    state.email = (await db.getMeta("email")) ?? "";
    state.lastSync = (await db.getMeta("lastSync")) ?? null;
    state.isAdmin = (await db.getMeta("isAdmin")) === true;
    login.email = state.email;
  }
  rebuild();
  state.loaded = true;

  // Login fra linket i mailen (Supabase sender browseren hertil med #access_token=…).
  if (!DEMO && /access_token=|error=/.test(location.hash)) {
    const hash = location.hash;
    history.replaceState(null, "", location.pathname + location.search + "#/reol");
    try {
      const s = cloud.sessionFromHash(hash);
      if (s) { if (!s.email) s.email = state.email; state.email = s.email; await db.setMeta("email", s.email); render(); await loggedIn(s); }
    } catch (e) { state.phase = { failed: e.message }; history.replaceState(null, "", "#/konto"); }
  }
  render();
  sync();

  if ("serviceWorker" in navigator && location.protocol === "https:") {
    navigator.serviceWorker.register("sw.js").catch(() => {});
  }
}

start();
