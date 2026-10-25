// Webappens checks: JavaScript-udgaven skal give præcis det samme som Swift (søgning og "Find i reolen").
// Køres med JavaScriptCore (samme motor som Safari på iPhone) af web/checks/run.sh:
//   jsc -m web/checks/checks.mjs -- <facit.json fra dump/main.swift>

import { buildLibraries, mediumOf, shelfOf, MEDIA, MEDIUM, parseRules, sortList } from "../core/library.js";
import { normalize } from "../core/search.js";
import { sessionFromHash } from "../core/cloud.js";

// JavaScriptCore alene har ikke browserens atob/TextDecoder (bruges til at læse login-nøglen).
globalThis.atob ??= (b) => {
  const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let bits = 0, n = 0, out = "";
  for (const c of b.replace(/=+$/, "")) { bits = (bits << 6) | abc.indexOf(c); n += 6; if (n >= 8) { n -= 8; out += String.fromCharCode((bits >> n) & 255); } }
  return out;
};
globalThis.TextDecoder ??= class { decode(u8) { return decodeURIComponent(Array.from(u8, (x) => "%" + x.toString(16).padStart(2, "0")).join("")); } };

const want = JSON.parse(readFile(globalThis.arguments[0]));
let passed = 0, failed = 0;
function check(ok, label) {
  if (ok) passed++;
  else { failed++; print("FEJL: " + label); }
}
const norm = (x) => JSON.stringify(x, (k, v) => (v && typeof v === "object" && !Array.isArray(v)
  ? Object.fromEntries(Object.keys(v).sort().map((q) => [q, v[q]])) : v));

const { libraries } = buildLibraries(want.records);

// Søgning: samme top-20 som Swift for hver søgning (plader først, så cd'er).
let same = 0;
for (const r of want.results) {
  const got = MEDIA.flatMap((m) => libraries[m].index.hits(r.q, 20).map((h) => `${libraries[m].item(h.id).copy.uid}|${h.track?.title ?? ""}`));
  if (norm(got) === norm(r.hits)) same++;
  else check(false, `søgning "${r.q}"\n  swift: ${r.hits.slice(0, 4)}\n  js:    ${got.slice(0, 4)}`);
}
check(same === want.results.length, `søgning: ${same} af ${want.results.length} ens med Swift`);
if (same === want.results.length) passed += same - 1;

// Find i reolen og Sæt tilbage: samme tekster, plads og antal for hver plade.
const ref = (r) => (r ? { side: r.side, item: r.item ? r.item.copy.uid : null, reason: r.reason } : null);
const adv = (a) => (a ? { primary: ref(a.primary), secondary: ref(a.secondary), artistBlockHint: a.artistBlockHint, placementHint: a.placementHint, sectionEdgeHint: a.sectionEdgeHint } : null);
let copies = 0;
for (const m of MEDIA) {
  const lib = libraries[m];
  for (const id of lib.copies.keys()) {
    copies++;
    const c = lib.copies.get(id), w = want.advice[c.uid];
    const n = lib.neighbors(id);
    const got = { find: adv(lib.referenceAdvice(id)), putBack: adv(lib.returnAdvice(id)), position: n?.position ?? null, count: n?.sectionCount ?? 0, medium: m };
    check(!!w && norm(got) === norm(w), `Find i reolen for ${c.uid}:\n  swift: ${norm(w?.find)}\n  js:    ${norm(got.find)}`);
  }
}
check(copies === Object.keys(want.advice).length, `samme plader på hylderne (${copies} / ${Object.keys(want.advice).length})`);

// Hylder og tekst.
check(mediumOf("2×CD, Album") === "cd" && mediumOf("Vinyl, LP") === "vinyl" && mediumOf(null) === "vinyl" && mediumOf(",CD") === "cd", "format → plade eller cd");
check(shelfOf(null, "File, MP3") === null && shelfOf("vinyl", "File, MP3") === "vinyl" && shelfOf("cd", "Vinyl") === "cd", "digitale filer står ikke på en hylde");
check(normalize("Ágætis Byrjun") === "agaetis byrjun" && normalize("AC/DC & Co") === "ac dc and co" && normalize("Ｆｕｌｌ") === "full", "normalisering");

// Kategorier (som på Mac): egne reoler, mappe fra Discogs og kategorier til sidst.
check(parseRules('{"categories":{"jazz":"own","polka":"end","classical":"?"}}').categories.jazz === "own"
  && Object.keys(parseRules('{"categories":{"jazz":"own","polka":"end","classical":"?"}}').categories).length === 1
  && Object.keys(parseRules('{"numbersLast":true}').categories).length === 0, "kategorierne læses; ukendte springes over, gamle regler: fra");
check(MEDIA.length === 8 && MEDIUM["vinyl.jazz"].shelfWord === "Jazz-reol" && MEDIUM["cd.classical"].shelfWord === "Klassisk-cd-reol"
  && MEDIUM["cd.entertainment"].title === "Underholdning (cd'er)", "hylder og navne som på Mac");
const rec = (kind, key, data, t) => ({ kind, key, data, updated_at: `2026-10-23T10:00:0${t}Z` });
const catRecords = [
  rec("release", "1", { artist: "Coltrane", title: "A", format: "Vinyl, LP", genres: "Jazz" }, 0),
  rec("release", "2", { artist: "Beatles", title: "B", format: "Vinyl, LP", genres: "Rock" }, 0),
  rec("release", "3", { artist: "Bach", title: "C", format: "Vinyl, LP", genres: "Classical" }, 0),
  rec("release", "4", { artist: "Kim Larsen", title: "D", format: "Vinyl, LP", genres: "Pop" }, 0),
  rec("copy", "i1", { release: 1, status: "home", rank: 2 }, 1), rec("copy", "i2", { release: 2, status: "home", rank: 0 }, 1),
  rec("copy", "i3", { release: 3, status: "home", rank: 1 }, 1), rec("copy", "i4", { release: 4, status: "home", rank: 3, folder: "Underholdning" }, 1),
  rec("location", "L1", { shelf: 1, section: "A", sortIndex: 0, medium: "vinyl" }, 2),
  rec("location", "J1", { shelf: 1, section: "A", sortIndex: 1, medium: "vinyl", category: "jazz" }, 2),
  rec("section", "J1", { copies: ["i1"] }, 3),
  rec("setting", "sort_rules", { value: '{"useDiscogsOrder":true,"categories":{"jazz":"own","entertainment":"end","classical":"end"}}' }, 3),
];
const cat = buildLibraries(catRecords);
check(cat.libraries["vinyl.jazz"].copies.size === 1 && cat.libraries["vinyl.jazz"].locations.length === 1 && cat.libraries["vinyl.jazz"].unplaced.length === 0
  && cat.libraries.vinyl.copies.size === 3 && cat.libraries.vinyl.locations.length === 1, "egne reoler: jazz står på jazz-reolen");
check(sortList(cat.libraries.vinyl, cat.rules).map((e) => e.item.release.artist).join(",") === "Beatles,Kim Larsen,Bach",
  "sidst på reolerne: Underholdning (Discogs-mappen) før Klassisk");

// Login fra mail-linket.
const hash = "#access_token=x.eyJzdWIiOiJ1MSIsImVtYWlsIjoidEBleC5kayIsImV4cCI6MTk5OTk5OTk5OX0.y&refresh_token=r&expires_at=1999999999";
const s = sessionFromHash(hash);
check(s?.userID === "u1" && s.email === "t@ex.dk" && s.refreshToken === "r" && s.expiresAt === 1999999999, "login fra linket i mailen");
check(sessionFromHash("#/reol") === null, "en almindelig adresse er ikke et login");
let threw = "";
try { sessionFromHash("#error=access_denied&error_description=Email+link+is+invalid+or+has+expired"); } catch (e) { threw = e.message; }
check(threw === "Linket er brugt eller udløbet. Bed om en ny mail.", "brugt link giver en dansk besked");

print(`webapp-checks: ${passed} bestået, ${failed} fejlet`);
if (failed) throw new Error(`${failed} checks fejlede`);
