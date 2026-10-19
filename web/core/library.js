// Reoler, sektioner, naboer og "Find i reolen"-teksterne.
// Port af Sources/VinylCore/Library.swift og Models.swift (samme tekster som på Mac, Windows og iPhone).
// Data kommer fra kontoens poster (se sync.js), som i SyncDocs.swift.

import { SearchIndex } from "./search.js";

// MARK: Plader og cd'er

export const MEDIA = ["vinyl", "cd"];

export const MEDIUM = {
  vinyl: { title: "Plader", singular: "plade", plural: "plader", shelfWord: "Reol" },
  cd: { title: "Cd'er", singular: "cd", plural: "cd'er", shelfWord: "Cd-reol" },
};

/** Første format uden antal: "2×CD, Album" → "CD", "8×File, MP3" → "FILE". */
function firstFormat(format) {
  // Som Swifts split: tomme stykker springes over (",CD" → "CD").
  const first = (format ?? "").split(",").find((p) => p !== "");
  if (first === undefined) return "";
  const name = first.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "").toUpperCase();
  const x = name.indexOf("×");
  return x >= 0 ? name.slice(x + 1) : name;
}

export function mediumOf(format) {
  return ["CD", "CDR", "SACD", "HDCD"].includes(firstFormat(format)) ? "cd" : "vinyl";
}

/** Hylden, en kopi hører til: brugerens valg, ellers formatet. null = digitale filer (ingen hylde). */
export function shelfOf(override, format) {
  if (override === "vinyl" || override === "cd") return override;
  return firstFormat(format) === "FILE" ? null : mediumOf(format);
}

export const STATUS = {
  home: { label: "På plads", icon: "house" },
  wall: { label: "På væggen", icon: "frame" },
  lent: { label: "Udlånt", icon: "person" },
  stored: { label: "Opbevaret andet sted", icon: "box" },
  missing: { label: "Mangler", icon: "dashed" },
};
export const statusOf = (s) => (Object.hasOwn(STATUS, s) ? s : "home");
export const isOnShelf = (item) => item.copy.status === "home";

/** Én sætning, når pladen ikke står i reolen (som awayMessage på Mac). null, når den står på plads. */
export function awayMessage(item) {
  const note = (item.copy.statusNote ?? "").trim();
  switch (item.copy.status) {
    case "wall": return "Hænger på væggen – står ikke i reolen";
    case "lent": return note ? `Udlånt til ${note} – står ikke i reolen` : "Udlånt – står ikke i reolen";
    case "stored": return note ? `Opbevaret andet sted (${note}) – står ikke i reolen` : "Opbevaret andet sted – står ikke i reolen";
    case "missing": return "Mangler – står ikke i reolen";
    default: return null;
  }
}

export const locationName = (l) => `${MEDIUM[l.medium].shelfWord} ${l.shelf} · Sektion ${l.section}`;
export const shortName = (l) => `${l.shelf}${l.section}`;
export const fullName = (it) => `${it.release.artist} – ${it.release.title}`;

/** "1973 • Harvest • SHVL 804 • Vinyl, LP" */
export function detailLine(r) {
  const parts = [];
  if (r.year && r.year > 0) parts.push(String(r.year));
  if (r.label) parts.push(r.label);
  if (r.catalogNumber && r.catalogNumber.toLowerCase() !== "none") parts.push(r.catalogNumber);
  if (r.format) parts.push(r.format);
  return parts.join(" • ");
}

/** Afslutter en sætning, der ender med et navn: "Low" → "Low.", men "Morning Glory?" forbliver uændret. */
function sentenceEnd(name) {
  const last = Array.from(name).pop();
  return !last || ".!?…".includes(last) ? name : name + ".";
}

// MARK: Ét øjebliksbillede af én hylde

export class Library {
  /**
   * @param releases Map discogsID → release
   * @param copies Map copyID → {id, uid, releaseID, status, statusNote}
   * @param locations [{id, uid, shelf, section, sortIndex, scanCode, medium}]
   * @param placements [{copyID, locationID, position}]
   */
  constructor(medium, releases, copies, locations, placements) {
    this.medium = medium;
    this.releases = releases;
    this.copies = copies;
    this.locations = [...locations].sort((a, b) => a.sortIndex - b.sortIndex || a.id - b.id);
    const bySection = new Map();
    for (const p of placements) {
      if (!bySection.has(p.locationID)) bySection.set(p.locationID, []);
      bySection.get(p.locationID).push(p);
    }
    this.sections = new Map();
    this.locationOfCopy = new Map();
    this.indexInSection = new Map();
    this.globalIndex = new Map();
    let g = 0;
    for (const loc of this.locations) {
      const ids = (bySection.get(loc.id) ?? []).sort((a, b) => a.position - b.position).map((p) => p.copyID);
      this.sections.set(loc.id, ids);
      ids.forEach((c, i) => {
        this.locationOfCopy.set(c, loc.id);
        this.indexInSection.set(c, i);
        this.globalIndex.set(c, g++);
      });
    }
    this.unplaced = [...copies.keys()].filter((c) => !this.locationOfCopy.has(c)).sort((a, b) => a - b);
    this._index = null;
  }

  item(copyID) {
    const c = this.copies.get(copyID);
    const r = c && this.releases.get(c.releaseID);
    return r ? { id: c.id, copy: c, release: r } : null;
  }

  get allItems() { return [...this.copies.keys()].map((id) => this.item(id)).filter(Boolean); }

  /** Alle placerede plader i reolens rækkefølge (sektion for sektion). */
  globalOrderItems() { return this.locations.flatMap((l) => this.items(l.id)); }

  get index() {
    if (!this._index) this._index = new SearchIndex(this.allItems, this.globalIndex);
    return this._index;
  }

  location(id) { return id == null ? null : this.locations.find((l) => l.id === id) ?? null; }
  locationOf(copyID) { return this.location(this.locationOfCopy.get(copyID)); }

  /** Sektionen bag en scannet QR-kode (`vinylshelf://section/<id>`): koden på det trykte skilt følger sektionen. */
  locationForScanCode(code) {
    return this.locations.find((l) => l.scanCode && l.scanCode === code) ?? null;
  }

  items(locationID) { return (this.sections.get(locationID) ?? []).map((id) => this.item(id)).filter(Boolean); }

  get shelves() { return [...new Set(this.locations.map((l) => l.shelf))].sort((a, b) => a - b); }

  isOnShelf(copyID) { const it = this.item(copyID); return !!it && isOnShelf(it); }

  physicalOrder(locationID, including = null) {
    return (this.sections.get(locationID) ?? []).filter((id) => id === including || this.isOnShelf(id));
  }

  /** copyID → fysisk nummer (1…n) for de plader i sektionen, der står i reolen. */
  shelfNumbers(locationID) {
    const m = new Map();
    this.physicalOrder(locationID).forEach((id, i) => m.set(id, i + 1));
    return m;
  }

  onShelfCount(locationID) { return this.physicalOrder(locationID).length; }

  // MARK: Naboer

  neighbors(copyID, count = 1) {
    const target = this.item(copyID);
    if (!target) return null;
    const locID = this.locationOfCopy.get(copyID);
    const loc = this.location(locID);
    const ids = this.sections.get(locID);
    const idx = this.indexInSection.get(copyID);
    if (!loc || !ids || idx === undefined) {
      return { target, location: null, position: null, sectionCount: 0, before: [], after: [], reachedSectionStart: false, reachedSectionEnd: false };
    }
    const collect = (range) => {
      const present = [], absent = [];
      for (const i of range) {
        const it = this.item(ids[i]);
        if (!it) continue;
        if (isOnShelf(it)) {
          present.push(it);
          if (present.length === count) return { present, absent, reachedEnd: false };
        } else if (present.length === 0) absent.push(it);
      }
      return { present, absent, reachedEnd: true };
    };
    const range = (a, b) => { const r = []; for (let i = a; i < b; i++) r.push(i); return r; };
    const b = collect(range(0, idx).reverse());
    const a = collect(range(idx + 1, ids.length));
    const locIdx = this.locations.findIndex((l) => l.id === locID);
    let previousSection = null, nextSection = null;
    if (b.reachedEnd && locIdx > 0) {
      const pl = this.locations[locIdx - 1];
      previousSection = { location: pl, last: this.items(pl.id).reverse().find(isOnShelf) ?? null };
    }
    if (a.reachedEnd && locIdx + 1 < this.locations.length) {
      const nl = this.locations[locIdx + 1];
      nextSection = { location: nl, first: this.items(nl.id).find(isOnShelf) ?? null };
    }
    const shelf = this.physicalOrder(locID, copyID);
    return {
      target, location: loc, position: shelf.indexOf(copyID) + 1, sectionCount: shelf.length,
      before: b.present, after: a.present, reachedSectionStart: b.reachedEnd, reachedSectionEnd: a.reachedEnd,
      previousSection, nextSection,
    };
  }

  // MARK: Find i reolen

  /** Bedste fysiske referencepunkter og forklaringen, set fra målpladen ("din plade"), med venstre/højre. */
  referenceAdvice(copyID) { return this.advice(copyID, false); }
  returnAdvice(copyID) { return this.advice(copyID, true); }

  advice(copyID, putBack) {
    const n = this.neighbors(copyID, 1);
    if (!n || !n.location || !n.position) return null;
    const loc = n.location, position = n.position;
    const target = n.target;
    const targetArtist = target.release.artist;
    const before = n.before[0] ?? null, after = n.after[0] ?? null;
    const m = MEDIUM[this.medium];
    const word = m.singular, words = m.plural;
    const capWord = word.charAt(0).toUpperCase() + word.slice(1);

    const shelf = this.physicalOrder(loc.id, copyID);
    const sIdx = position - 1;
    let blockStart = sIdx, blockEnd = sIdx;
    const artistAt = (i) => this.item(shelf[i])?.release.artist;
    while (blockStart > 0 && artistAt(blockStart - 1) === targetArtist) blockStart -= 1;
    while (blockEnd + 1 < shelf.length && artistAt(blockEnd + 1) === targetArtist) blockEnd += 1;
    const blockSize = blockEnd - blockStart + 1;

    const ref = (side, item, reason) => ({ side, item, reason });
    const called = (it, first = false) => {
      if (it.release.artist === targetArtist && it.release.title === target.release.title) {
        return `${first ? "Et" : "et"} andet eksemplar af ${it.release.title}`;
      }
      return putBack && it.release.artist !== targetArtist ? fullName(it) : it.release.title;
    };
    const leftOf = (it) => putBack ? `Sæt den lige til højre for ${sentenceEnd(called(it))}`
      : `${called(it, true)} står lige til venstre for din ${word}.`;
    const rightOf = (it) => putBack ? `Sæt den lige til venstre for ${sentenceEnd(called(it))}`
      : `${called(it, true)} står lige til højre for din ${word}.`;
    const atLeftEdge = putBack ? "Sæt den yderst til venstre i sektionen." : `Din ${word} står yderst til venstre i sektionen.`;
    const atRightEdge = putBack ? "Sæt den yderst til højre i sektionen." : `Din ${word} står yderst til højre i sektionen.`;
    const otherArtist = "Det er en anden kunstner, så den er let at få øje på.";

    let primary, secondary = null, countsInPrimary = false;
    if (n.reachedSectionStart && !before) {
      primary = ref("sectionStart", null, atLeftEdge);
      secondary = after && ref("after", after, rightOf(after));
    } else if (n.reachedSectionEnd && !after) {
      primary = ref("sectionEnd", null, atRightEdge);
      secondary = before && ref("before", before, leftOf(before));
    } else if (before && after) {
      const bDiff = before.release.artist !== targetArtist, aDiff = after.release.artist !== targetArtist;
      if (bDiff && !aDiff) {
        primary = ref("before", before, `${leftOf(before)} ${otherArtist}`);
        secondary = ref("after", after, rightOf(after));
      } else if (aDiff && !bDiff) {
        primary = ref("after", after, `${rightOf(after)} ${otherArtist}`);
        secondary = ref("before", before, leftOf(before));
      } else if (!bDiff && !aDiff && blockSize > 2) {
        countsInPrimary = true;
        const fromStart = sIdx - blockStart, fromEnd = blockEnd - sIdx;
        const among = putBack ? `Din ${word} skal stå blandt ${blockSize} ${targetArtist}-${words} i træk.`
          : `Din ${word} står blandt ${blockSize} ${targetArtist}-${words} i træk.`;
        const count = (nr, side, it) => putBack
          ? `din ${word} skal stå som nr. ${nr}, lige til ${side} for ${sentenceEnd(called(it))}`
          : `din ${word} er nr. ${nr}, lige til ${side} for ${sentenceEnd(called(it))}`;
        if (fromStart <= fromEnd) {
          const s = blockStart > 0 ? this.item(shelf[blockStart - 1]) : null;
          const start = s ? `Find ${fullName(s)}, som står lige til venstre for dem` : null;
          primary = ref("before", before, `${among} ${start ?? "Start ved sektionens venstre kant"}, og tæl mod højre: ${count(fromStart + 1, "højre", before)}`);
          secondary = ref("after", after, rightOf(after));
        } else {
          const s = blockEnd + 1 < shelf.length ? this.item(shelf[blockEnd + 1]) : null;
          const start = s ? `Find ${fullName(s)}, som står lige til højre for dem` : null;
          primary = ref("after", after, `${among} ${start ?? "Start ved sektionens højre kant"}, og tæl mod venstre: ${count(fromEnd + 1, "venstre", after)}`);
          secondary = ref("before", before, leftOf(before));
        }
      } else {
        primary = ref("before", before, leftOf(before));
        secondary = ref("after", after, rightOf(after));
      }
    } else {
      primary = ref("before", before, before ? leftOf(before) : atLeftEdge);
      secondary = after && ref("after", after, rightOf(after));
    }

    let artistBlockHint = null;
    const atSectionEdge = primary.side === "sectionStart" || primary.side === "sectionEnd";
    if (blockSize > 1 && !countsInPrimary && !atSectionEdge) {
      const side = sIdx === blockStart ? "venstre" : sIdx === blockEnd ? "højre" : null;
      if (side) {
        artistBlockHint = putBack
          ? `Din ${word} skal stå længst til ${side} blandt ${blockSize} ${targetArtist}-${words} i træk.`
          : `Der står ${blockSize} ${targetArtist}-${words} i træk, og din ${word} er den længst til ${side}.`;
      }
    }

    const edge = [];
    if (n.reachedSectionStart && n.previousSection?.last) {
      edge.push(`Forrige sektion (${shortName(n.previousSection.location)}) slutter med ${sentenceEnd(fullName(n.previousSection.last))}`);
    }
    if (n.reachedSectionEnd && n.nextSection?.first) {
      edge.push(`Næste sektion (${shortName(n.nextSection.location)}) begynder med ${sentenceEnd(fullName(n.nextSection.first))}`);
    }
    const placementHint = `${putBack ? "Plads" : capWord} ${position} af ${n.sectionCount} fra venstre`;
    return { primary, secondary: secondary || null, artistBlockHint, placementHint, sectionEdgeHint: edge.length ? edge.join(" ") : null };
  }
}

// MARK: Fra kontoens poster til hylder

/**
 * Bygger plade- og cd-hylden ud fra posterne (som applySyncDocs + loadLibrary i Swift).
 * @param records [{kind, key, data, updated_at}] – kun ikke-slettede, i den rækkefølge serveren ændrede dem
 */
export function buildLibraries(records) {
  const releases = new Map();
  const copies = new Map(); // uid → kopi
  const locs = [];
  const sectionDocs = [];
  const plays = [];
  const sorted = [...records].sort((a, b) => (a.updated_at < b.updated_at ? -1 : a.updated_at > b.updated_at ? 1 : 0));
  let nextCopyID = 1;
  for (const r of sorted) {
    const d = r.data;
    if (!d) continue;
    if (r.kind === "release") {
      const id = Number(r.key);
      if (!Number.isInteger(id)) continue;
      releases.set(id, {
        id, artist: d.artist ?? "", title: d.title ?? "", year: Number.isFinite(d.year) ? d.year : null,
        label: d.label ?? null, catalogNumber: d.catalog ?? null, format: d.format ?? null,
        coverURL: d.cover ?? null, thumbURL: d.thumb ?? null, genres: d.genres ?? null,
        tracks: Array.isArray(d.tracks) ? d.tracks.filter((t) => typeof t?.t === "string").map((t) => ({ position: t.p ?? "", title: t.t, duration: t.d ?? null })) : [],
      });
    } else if (r.kind === "copy") {
      if (!Number.isFinite(d.release)) continue;
      // Kopier fra Discogs har deres kopinummer som ID (som på computeren); andre får et løbenummer.
      const inst = /^i(\d+)$/.exec(r.key);
      copies.set(r.key, {
        id: inst ? Number(inst[1]) : -(nextCopyID++), uid: r.key, releaseID: d.release,
        status: statusOf(d.status), statusNote: d.note ?? null, medium: d.medium ?? null,
      });
    } else if (r.kind === "location") {
      locs.push({
        id: locs.length + 1, uid: r.key, shelf: Number.isFinite(d.shelf) ? d.shelf : 1, section: d.section ?? "A",
        sortIndex: Number.isFinite(d.sortIndex) ? d.sortIndex : 0, medium: d.medium === "cd" ? "cd" : "vinyl",
        scanCode: typeof d.code === "string" ? d.code : null,
      });
    } else if (r.kind === "section") {
      sectionDocs.push(r);
    } else if (r.kind === "play") {
      if (typeof d.copy === "string" && Number.isFinite(d.at)) plays.push({ uid: r.key, copyUID: d.copy, at: d.at });
    }
  }
  // Nyeste kode vinder, hvis to sektioner har fået samme skilt (som i SyncDocs.apply).
  const codeOwner = new Map();
  for (const l of locs) if (l.scanCode) codeOwner.set(l.scanCode, l);
  for (const l of locs) if (l.scanCode && codeOwner.get(l.scanCode) !== l) l.scanCode = null;

  const locByUID = new Map(locs.map((l) => [l.uid, l]));
  // En kopi står kun ét sted: den senest ændrede sektion vinder (som ON CONFLICT(copy_id) i databasen).
  const placementOf = new Map();
  for (const s of sectionDocs) {
    const loc = locByUID.get(s.key);
    if (!loc) continue;
    for (const p of [...placementOf.entries()]) if (p[1].locationID === loc.id) placementOf.delete(p[0]);
    (Array.isArray(s.data.copies) ? s.data.copies : []).forEach((uid, i) => {
      const c = copies.get(uid);
      if (c) placementOf.set(c.id, { copyID: c.id, locationID: loc.id, position: i + 1 });
    });
  }

  const libraries = {};
  for (const m of MEDIA) {
    const cs = new Map();
    for (const c of copies.values()) {
      const r = releases.get(c.releaseID);
      if (r && shelfOf(c.medium, r.format) === m) cs.set(c.id, c);
    }
    const ls = locs.filter((l) => l.medium === m);
    const ids = new Set(ls.map((l) => l.id));
    const ps = [...placementOf.values()].filter((p) => cs.has(p.copyID) && ids.has(p.locationID));
    libraries[m] = new Library(m, releases, cs, ls, ps);
  }
  const copyByUID = new Map([...copies.values()].map((c) => [c.uid, c]));
  const playList = plays.map((p) => ({ ...p, copyID: copyByUID.get(p.copyUID)?.id })).filter((p) => p.copyID !== undefined)
    .sort((a, b) => b.at - a.at);
  return { libraries, plays: playList, copyByID: new Map([...copies.values()].map((c) => [c.id, c])) };
}

// MARK: "Hvad skal jeg høre?" (port af ListenPicker i Listening.swift)

export const FRESHNESS = [
  { id: "any", label: "Alle plader" },
  { id: "neverPlayed", label: "Aldrig spillet" },
  { id: "notIn3Months", label: "Ikke hørt i 3 måneder" },
  { id: "notInYear", label: "Ikke hørt i et år" },
];

const genreList = (r) => (r.genres ?? "").split(",").map((g) => g.trim()).filter(Boolean);

export function genres(items) { return [...new Set(items.flatMap((it) => genreList(it.release)))].sort(); }

export function decades(items) {
  return [...new Set(items.filter((it) => Number.isFinite(it.release.year)).map((it) => Math.floor(it.release.year / 10) * 10))].sort((a, b) => a - b);
}

/** Plader, der opfylder filteret og står i reolen. `lastPlayed`: copyID → sekunder. */
export function candidates(items, library, filter, lastPlayed, now = Date.now() / 1000) {
  return items.filter((it) => {
    if (!isOnShelf(it) || !library.locationOfCopy.has(it.id)) return false;
    if (filter.genre && !genreList(it.release).includes(filter.genre)) return false;
    if (filter.decade != null && (Number.isFinite(it.release.year) ? Math.floor(it.release.year / 10) * 10 : null) !== filter.decade) return false;
    const last = lastPlayed.get(it.id);
    switch (filter.freshness) {
      case "neverPlayed": return last === undefined;
      case "notIn3Months": return last === undefined || now - last > 90 * 86400;
      case "notInYear": return last === undefined || now - last > 365 * 86400;
      default: return true;
    }
  });
}

/** Tilfældig plade, vægtet mod plader, der ikke er hørt længe. Undgår de seneste forslag. */
export function pick(cands, lastPlayed, recent, now = Date.now() / 1000, random = Math.random) {
  let pool = cands.filter((it) => !recent.includes(it.id));
  if (!pool.length) pool = cands;
  if (!pool.length) return null;
  // Vægt: aldrig spillet = 4, ellers 1 + år siden sidst (højst 4).
  const weights = pool.map((it) => {
    const last = lastPlayed.get(it.id);
    return last === undefined ? 4 : Math.min(4, 1 + Math.max(0, now - last) / (365 * 86400));
  });
  let r = random() * weights.reduce((a, b) => a + b, 0);
  for (let i = 0; i < pool.length; i++) { if (r < weights[i]) return pool[i]; r -= weights[i]; }
  return pool.at(-1);
}

/** Ingen plader matcher: sig venligt, hvilket filter man kan løsne (som NoMatchNote på Mac). */
export function noMatchMessage(items, library, filter, lastPlayed) {
  const matches = (g) => candidates(items, library, g, lastPlayed).length > 0;
  const tips = [];
  if (filter.genre && matches({ ...filter, genre: null })) tips.push("“Alle genrer”");
  if (filter.decade != null && matches({ ...filter, decade: null })) tips.push("“Alle årtier”");
  if (filter.freshness !== "any" && matches({ ...filter, freshness: "any" })) tips.push("“Alle plader”");
  if (!tips.length) {
    return matches({ genre: null, decade: null, freshness: "any" })
      ? "Ingen plader passer til den kombination. Nulstil et par af filtrene, så kommer der forslag igen."
      : "Der står ingen plader i reolen endnu, som kan foreslås.";
  }
  const list = tips.length === 1 ? tips[0] : tips.slice(0, -1).join(", ") + " eller " + tips.at(-1);
  return `Ingen plader passer til filtrene lige nu. Prøv ${list} – så er der plader at vælge imellem.`;
}

// MARK: Cover Flow (port af CoverFlowGeometry i CoverFlow.swift)

export const CF = {
  visible: 6, tilt: 65, sideScale: 0.9, reflectionHeight: 0.28, reflectionOpacity: 0.25, firstGap: 0.62, stackGap: 0.25,
  side(width, height) { return Math.max(80, Math.min(height * 0.62, width * 0.36, 360)); },
  clamped(o) { return Math.min(Math.max(o, -1), 1); },
  x(o, side) { const c = CF.clamped(o); return side * (CF.firstGap * c + CF.stackGap * (o - c)); },
  angle(o) { return -CF.tilt * CF.clamped(o); },
  scale(o) { return 1 - (1 - CF.sideScale) * Math.abs(CF.clamped(o)); },
  visibleRange(center, count) {
    if (count <= 0) return [0, 0];
    const c = Math.min(Math.max(center, 0), count - 1);
    return [Math.max(0, c - CF.visible), Math.min(count, c + CF.visible + 1)];
  },
  glide(center, shift, count) {
    if (count <= 0) return { center: 0, shift: 0 };
    let c = Math.min(Math.max(center, 0), count - 1), s = shift;
    while (s > 0.5 && c < count - 1) { s -= 1; c += 1; }
    while (s < -0.5 && c > 0) { s += 1; c -= 1; }
    if (c === 0) s = Math.max(s, -0.3);
    if (c === count - 1) s = Math.min(s, 0.3);
    return { center: c, shift: s };
  },
};
