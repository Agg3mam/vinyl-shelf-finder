// Søgning i samlingen (plader og sange). Port af Sources/VinylCore/Search.swift og
// windows/src/VinylCore/Search.cs: de tre skal give præcis samme rækkefølge (afprøvet med testsættet).
//
// Resultaterne sorteres efter en fast rækkefølge af regler, hvor hver regel kun afgør det, de forrige
// lod stå lige (se kommentaren øverst i Search.swift):
//  1. flest af søgningens ord fundet  2. færrest stavefejl  3. slags træf (plade, sang, katalognummer …)
//  4. fejl i første bogstav, hele ord før påbegyndte  5. hvor præcist titel/kunstner passer
//  6. ord ved siden af hinanden  7. kunstner/titel før resten  8. reolens rækkefølge
// Længder og sammenligninger regnes i Unicode-tegn (kodepunkter), som `unicodeScalars` i Swift.

const MAX = Number.MAX_SAFE_INTEGER;

// MARK: Normalisering

const MARK = /\p{Mn}/u;
const ALNUM = /[\p{L}\p{M}\p{N}]/u;

/** Fjerner accenter ("é" → "e") og folder fuld bredde ("Ａ" → "A"), som Foundation på Mac. */
function fold(s) {
  let out = "";
  for (const c of s.normalize("NFD")) {
    if (MARK.test(c)) continue;
    const v = c.codePointAt(0);
    if (v >= 0xff01 && v <= 0xff5e) out += String.fromCodePoint(v - 0xfee0);
    else if (v === 0x3000) out += " ";
    else out += c;
  }
  return out.normalize("NFC");
}

const isAscii = (s) => /^[\x00-\x7f]*$/.test(s);

/** Små bogstaver, æ→ae, ø→o, ß→ss, &→and, accenter fjernet; alt andet end bogstaver og tal bliver ét mellemrum. */
export function normalize(s) {
  if (isAscii(s)) {
    let out = "";
    let space = true;
    const put = (c) => {
      if (c === " ") { if (!space) { out += " "; space = true; } } else { out += c; space = false; }
    };
    for (let i = 0; i < s.length; i++) {
      let c = s.charCodeAt(i);
      if (c >= 65 && c <= 90) c += 32;
      if (c === 38) { put(" "); put("a"); put("n"); put("d"); put(" "); }
      else if ((c >= 97 && c <= 122) || (c >= 48 && c <= 57)) put(String.fromCharCode(c));
      else put(" ");
    }
    if (out.endsWith(" ")) out = out.slice(0, -1);
    return out;
  }
  const folded = fold(s.toLowerCase().replaceAll("æ", "ae").replaceAll("ø", "o").replaceAll("ß", "ss").replaceAll("&", " and "));
  let mapped = "";
  for (const c of folded) mapped += ALNUM.test(c) ? c : " ";
  return mapped.split(" ").filter(Boolean).join(" ");
}

export function words(s) {
  const n = normalize(s);
  return n ? n.split(" ") : [];
}

const hasDigit = (s) => /[0-9]/.test(s);
const chars = (s) => Array.from(s);
const scalarCount = (s) => { let n = 0; for (const _ of s) n++; return n; };

const SYMBOL_NAMES = new Map([["÷", "divide"], ["×", "multiply"], ["+", "plus"], ["★", "blackstar"], ["=", "equals"], ["−", "minus"]]);

/** Titler af bare tegn ("÷", "★") kan ellers ikke findes: tegnet skrives også som ord. */
function spellSymbols(s) {
  const cs = chars(s);
  if (!cs.some((c) => SYMBOL_NAMES.has(c))) return s;
  return s + " " + cs.filter((c) => SYMBOL_NAMES.has(c)).map((c) => SYMBOL_NAMES.get(c)).join(" ");
}

const ARTICLES = new Set(["the", "a", "an", "de", "det", "den", "en", "et", "le", "la", "les", "die", "der", "das"]);

const ROMANS = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
  "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx"];
const PAIRS = { pt: "part", part: "pt", vol: "volume", volume: "vol", st: "saint", saint: "st", og: "and", and: "og" };

/** Ord, der betyder det samme: romertal og tal, forkortelser, "og"/"and" og "aa"/"oe"/"ue" for å/ø/ü. */
function synonyms(t) {
  if (/^[0-9]+$/.test(t)) {
    const n = Number(t);
    if (n >= 1 && n <= ROMANS.length) return [ROMANS[n - 1]];
  }
  const ri = ROMANS.indexOf(t);
  if (ri >= 0) return [String(ri + 1)];
  if (Object.hasOwn(PAIRS, t)) return [PAIRS[t]];
  const alt = [];
  for (const [from, to] of [["aa", "a"], ["oe", "o"], ["ue", "u"]]) {
    if (t.includes(from)) alt.push(t.replaceAll(from, to));
  }
  return alt;
}

// MARK: Indeks

class Vocabulary {
  constructor() { this.words = []; this.ids = new Map(); }
  id(w) {
    let i = this.ids.get(w);
    if (i === undefined) { i = this.words.length; this.words.push(w); this.ids.set(w, i); }
    return i;
  }
}

const isWhitespace = (c) => /\s/u.test(c);
const isLetterOrNumber = /[\p{L}\p{N}\p{M}]/u;

/** Ét felt: ordene (som numre i ordlisten), sammentrukne ord ("AC/DC" → "acdc") og hele feltet. */
function makeField(text, vocab) {
  const w = words(spellSymbols(text));
  const full = w.join(" ");
  const bare = ARTICLES.has(w[0] ?? "") && w.length > 1 ? w.slice(1).join(" ") : full;
  const joined = [];
  const hasInnerMark = isAscii(text) ? /[^ 0-9A-Za-z]/.test(text) : true;
  if (hasInnerMark) {
    for (const part of text.split(/\s+/u)) {
      if (!part || !chars(part).some((c) => !isLetterOrNumber.test(c))) continue;
      const pw = words(part);
      if (pw.length > 1) joined.push(vocab.id(pw.join("")));
    }
  }
  if (w.length > 1) joined.push(vocab.id(w.join("")));
  return { words: w.map((x) => vocab.id(x)), joined, full, bare };
}

/** Damerau-Levenshtein (optimal string alignment) med tidlig afbrydelse. */
function editDistance(x, y, limit) {
  if (Math.abs(x.length - y.length) > limit) return limit + 1;
  if (x.length === 0) return y.length;
  if (y.length === 0) return x.length;
  const n = y.length + 1;
  let prev2 = new Array(n).fill(0), prev = new Array(n), cur = new Array(n);
  for (let j = 0; j < n; j++) prev[j] = j;
  for (let i = 1; i <= x.length; i++) {
    cur[0] = i;
    let rowMin = cur[0];
    for (let j = 1; j <= y.length; j++) {
      const cost = x[i - 1] === y[j - 1] ? 0 : 1;
      let v = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
      if (i > 1 && j > 1 && x[i - 1] === y[j - 2] && x[i - 2] === y[j - 1]) v = Math.min(v, prev2[j - 2] + 1);
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > limit) return limit + 1;
    const t = prev2; prev2 = prev; prev = cur; cur = t;
  }
  return prev[y.length];
}

function containsRun(hay, needle) {
  if (needle.length === 0 || needle.length > hay.length) return false;
  outer: for (let s = 0; s <= hay.length - needle.length; s++) {
    if (hay[s] !== needle[0]) continue;
    for (let k = 1; k < needle.length; k++) if (hay[s + k] !== needle[k]) continue outer;
    return true;
  }
  return false;
}

const startsWithChars = (wc, tc) => { for (let k = 0; k < tc.length; k++) if (wc[k] !== tc[k]) return false; return true; };

/** Mindst først, felt for felt. */
export function compareKeys(a, b) {
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

/** Hvor mange stavefejl et ord må have: 0 under 4 tegn, 1 fra 4, 2 fra 6; ingen i ord med tal. */
function budget(t) {
  if (hasDigit(t)) return 0;
  const n = scalarCount(t);
  return n >= 6 ? 2 : n >= 4 ? 1 : 0;
}

/** Én søgning med en hukommelse for ord, der allerede er sammenlignet. */
class Query {
  constructor(tokens, allPrefix, mayMiss, index) {
    this.tokens = tokens;
    this.allPrefix = allPrefix;
    this.mayMiss = mayMiss;
    this.vocab = index.vocab;
    this.vocabChars = index.vocabChars;
    this.vocabHasDigit = index.vocabHasDigit;
    this.tokenSynonyms = tokens.map(synonyms);
    this.tokenBudget = tokens.map(budget);
    this.tokenChars = tokens.map(chars);
    this.phrase = tokens.join(" ");
    this.barePhrase = ARTICLES.has(tokens[0]) && tokens.length > 1 ? tokens.slice(1).join(" ") : this.phrase;
    this.compact = tokens.join("");
    this.optional = tokens.map((t, i) => tokens.length > 1 && i < tokens.length - 1 && ARTICLES.has(t));
    // -2 ikke regnet ud, -1 passer ikke, ellers stavefejl × 8 + påbegyndt 4 + synonym 2 + forkert første bogstav 1.
    this.cache = tokens.map(() => new Int16Array(this.vocab.length).fill(-2));
  }

  match(i, id) {
    let c = this.cache[i][id];
    if (c === -2) {
      const m = this.computeMatch(i, id);
      c = m ? m.cost * 8 + (m.prefix ? 4 : 0) + (m.synonym ? 2 : 0) + (m.firstLetter ? 1 : 0) : -1;
      this.cache[i][id] = c;
    }
    return c < 0 ? null : { cost: c >> 3, prefix: (c & 4) !== 0, synonym: (c & 2) !== 0, firstLetter: (c & 1) !== 0 };
  }

  computeMatch(i, id) {
    const t = this.tokens[i], w = this.vocab[id];
    const tc = this.tokenChars[i], wc = this.vocabChars[id];
    const last = this.allPrefix || i === this.tokens.length - 1;
    if (w === t) return { cost: 0, prefix: false };
    // Et enkelt bogstav, der stadig skrives, er ikke et romertal ("back i" → Back In Black, ikke "1").
    if (!(last && tc.length === 1 && !hasDigit(t)) && this.tokenSynonyms[i].includes(w)) return { cost: 0, prefix: false, synonym: true };
    if (last && wc.length > tc.length && startsWithChars(wc, tc)) return { cost: 0, prefix: true };
    const b = this.tokenBudget[i];
    if (b > 0 && !this.vocabHasDigit[id]) {
      const first = tc[0] === wc[0] ? 0 : 1;
      if (Math.abs(wc.length - tc.length) <= b) {
        const d = editDistance(tc, wc, b) + first;
        if (d <= b) return { cost: d - first, prefix: false, firstLetter: first === 1 };
      }
      if (last && wc.length > tc.length) {
        const d = editDistance(tc, wc.slice(0, tc.length), b) + first;
        if (d <= b) return { cost: d - first, prefix: true, firstLetter: first === 1 };
      }
    }
    // Sidste udvej: ordet står inde i et længere ord ("sommer" i "sommerfugl").
    if (tc.length >= 4 && wc.length > tc.length && containsRun(wc, tc)) return { cost: 2, prefix: true };
    return null;
  }

  /** Bedste træf i feltet for hvert søgeord (null = ordet står ikke i feltet). */
  bests(f, useSynonyms = true) {
    return this.tokens.map((_, i) => {
      let best = null;
      const consider = (m, pos) => {
        if (!m || (!useSynonyms && m.synonym)) return;
        if (best) {
          const bp = best.match.prefix ? 1 : 0, mp = m.prefix ? 1 : 0;
          if (compareKeys([best.match.cost, bp, best.position], [m.cost, mp, pos]) <= 0) return;
        }
        best = { match: m, position: pos };
      };
      f.words.forEach((w, p) => consider(this.match(i, w), p));
      // Sammentrukne ord ("acdc", "okcomputer") kun helt eller påbegyndt – ikke med stavefejl.
      for (const w of f.joined) { const m = this.match(i, w); if (m && m.cost === 0) consider(m, 0); }
      return best;
    });
  }

  key(fields, entity, exactness, requireRank, shelf, id) {
    let allInArtist = true, realMatched = 0, matched = 0, typos = 0, firstLetters = 0, lastPrefix = 0;
    let bestRank = MAX, worstRank = 0, firstPos = MAX, missing = 0;
    let hitRequired = requireRank === null;
    const placed = [];
    for (let i = 0; i < this.tokens.length; i++) {
      let best = null;
      fields.forEach((f, fi) => {
        const b = f.bests[i];
        if (!b) return;
        if (best && compareKeys([best.match.cost, best.match.prefix ? 1 : 0, best.rank, best.position],
          [b.match.cost, b.match.prefix ? 1 : 0, f.rank, b.position]) <= 0) return;
        best = { match: b.match, position: b.position, field: fi, rank: f.rank };
      });
      if (!best) {
        if (this.optional[i]) { placed.push(null); continue; }
        missing += 1;
        if (missing > this.mayMiss) return null;
        placed.push(null);
        continue;
      }
      matched += 1;
      if (!this.optional[i]) realMatched += 1;
      typos += best.match.cost;
      if (best.match.firstLetter) firstLetters += 1;
      if (best.match.prefix) lastPrefix = 1;
      bestRank = Math.min(bestRank, best.rank);
      worstRank = Math.max(worstRank, best.rank);
      if (best.field !== 0) allInArtist = false;
      firstPos = Math.min(firstPos, best.position);
      if (best.rank === requireRank) hitRequired = true;
      placed.push({ field: best.field, pos: best.position });
    }
    if (!hitRequired || realMatched === 0) return null;
    let adjacent = 0;
    for (let i = 1; i < placed.length; i++) {
      const a = placed[i - 1], b = placed[i];
      if (!a || !b) continue;
      if (a.field === b.field ? b.pos === a.pos + 1 : (a.field === 0 && b.field === 1)) adjacent += 1;
    }
    const ex = exactness();
    let tier;
    if (entity === 0) tier = worstRank > 0 ? 5 : lastPrefix === 0 ? 0 : 2;
    else tier = ex.level === 0 ? 1 : lastPrefix === 0 ? 3 : 4;
    const position = entity === 0 && (ex.level <= 1 || allInArtist) ? 0 : firstPos;
    return [-matched, typos, tier, firstLetters, lastPrefix, ex.level, ex.length, -adjacent, bestRank, position, shelf, id];
  }

  albumKey(e, artist) {
    const { compact, phrase, barePhrase, tokens } = this;
    if (scalarCount(compact) >= 3 && hasDigit(compact) && e.compactCatalog && e.compactCatalog.startsWith(compact)) {
      const exact = e.compactCatalog === compact ? 0 : 1;
      return [-tokens.length, 0, exact === 0 ? 0 : 2, 0, exact, exact, 0, 0, 2, 0, e.shelfOrder, e.id];
    }
    if (tokens.length === 1 && tokens[0] === e.releaseID) return [-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, e.shelfOrder, e.id];
    const equals = (f) => f.full === phrase || f.bare === barePhrase || f.full === barePhrase;
    const starts = (f) => f.full.startsWith(phrase) || f.bare.startsWith(barePhrase);
    const contains = (f) => ` ${f.full} `.includes(` ${barePhrase}`);
    const exactness = () => {
      if (equals(e.title) || `${e.artist.bare} ${e.title.bare}` === barePhrase || `${e.artist.full} ${e.title.full}` === phrase) return { level: 0, length: 0 };
      if (equals(e.artist)) return { level: 1, length: 0 };
      if (starts(e.title)) return { level: 2, length: 0 };
      if (starts(e.artist)) return { level: 3, length: e.artist.words.length };
      if (contains(e.title) || contains(e.artist)) return { level: 4, length: 0 };
      return { level: 5, length: 0 };
    };
    if (scalarCount(phrase) === 1) {
      if (!(starts(e.artist) || starts(e.title))) return null;
      return this.key([{ bests: artist, rank: 0 }, { bests: this.bests(e.title), rank: 0 }], 0, exactness, null, e.shelfOrder, e.id);
    }
    return this.key([
      { bests: artist, rank: 0 }, { bests: this.bests(e.title), rank: 0 },
      { bests: this.bests(e.catalog, false), rank: 2 }, { bests: this.bests(e.label, false), rank: 3 },
      { bests: this.bests(e.other, false), rank: 4 },
    ], 0, exactness, null, e.shelfOrder, e.id);
  }

  songKey(e, f, artist, song) {
    const { phrase, barePhrase } = this;
    if (scalarCount(phrase) === 1 && !(f.full.startsWith(phrase) || f.bare.startsWith(barePhrase))) return null;
    const exactness = () => f.full === phrase || f.bare === barePhrase ? { level: 0, length: 0 }
      : f.full.startsWith(phrase) ? { level: 2, length: 0 }
        : ` ${f.full} `.includes(` ${barePhrase}`) ? { level: 4, length: 0 } : { level: 5, length: 0 };
    return this.key([{ bests: artist, rank: 0 }, { bests: song, rank: 1 }], 1, exactness, 1, e.shelfOrder, e.id);
  }
}

export class SearchIndex {
  /**
   * @param items [{id, release: {id, artist, title, year, label, catalogNumber, format, tracks: [{position, title}]}}]
   * @param shelfOrder Map copyID → plads i reolens rækkefølge (uplacerede mangler)
   */
  constructor(items, shelfOrder) {
    const v = new Vocabulary();
    this.entries = items.map((it) => {
      const r = it.release;
      return {
        id: it.id,
        artist: makeField(r.artist, v),
        title: makeField(r.title, v),
        catalog: makeField(r.catalogNumber ?? "", v),
        label: makeField(r.label ?? "", v),
        other: makeField([r.year == null ? "" : String(r.year), r.format ?? ""].join(" "), v),
        compactCatalog: normalize(r.catalogNumber ?? "").replace(/\s/gu, ""),
        releaseID: String(r.id),
        shelfOrder: shelfOrder.get(it.id) ?? MAX,
        tracks: (r.tracks ?? []).map((t) => ({ track: t, field: makeField(t.title, v) })),
      };
    });
    this.vocab = v.words;
    this.vocabChars = v.words.map(chars);
    this.vocabHasDigit = v.words.map(hasDigit);
  }

  /** [{id, track}], hvor `track` er sat, når det er en sang på pladen, der passede. */
  hits(query, limit = 60) {
    // Højst 10 ord: en lang indsat tekst må ikke få appen til at hænge.
    const tokens = words(spellSymbols(query)).slice(0, 10);
    if (tokens.length === 0) return [];
    let found = this.rank(tokens, false, 0);
    if (found.length === 0 && tokens.length > 1) found = this.rank(tokens, true, 0);
    if (found.length === 0 && tokens.length > 1) found = this.rank(tokens, true, tokens.length >= 5 ? 2 : 1);
    return found.slice(0, limit).map((f) => ({ id: f.id, track: f.track }));
  }

  rank(tokens, allPrefix, mayMiss) {
    const q = new Query(tokens, allPrefix, mayMiss, this);
    const out = [];
    for (const e of this.entries) {
      let best = null;
      const artist = q.bests(e.artist);
      const k = q.albumKey(e, artist);
      if (k) best = { track: null, key: k };
      for (const t of e.tracks) {
        const song = q.bests(t.field);
        if (!song.some((b) => b !== null)) continue;
        const sk = q.songKey(e, t.field, artist, song);
        if (sk && (!best || compareKeys(sk, best.key) < 0)) best = { track: t.track, key: sk };
      }
      if (best) out.push({ id: e.id, track: best.track, key: best.key });
    }
    return out.sort((a, b) => compareKeys(a.key, b.key));
  }
}
