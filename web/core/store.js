// Lokal lagring i browseren (IndexedDB), så webappen virker uden net.
// Poster fra kontoen gemmes som de er (kind|key → række). Login og markør ligger i "meta".
// Kan IndexedDB ikke bruges (fx privat browsing), virker appen stadig, men husker intet.

const DB_NAME = "vinylshelf";
let dbPromise = null;

function open() {
  if (!dbPromise) {
    dbPromise = new Promise((resolve) => {
      try {
        const req = indexedDB.open(DB_NAME, 1);
        req.onupgradeneeded = () => {
          req.result.createObjectStore("records");
          req.result.createObjectStore("meta");
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => resolve(null);
      } catch { resolve(null); }
    });
  }
  return dbPromise;
}

const memory = { records: new Map(), meta: new Map() };

async function tx(store, mode, fn) {
  const db = await open();
  if (!db) return fn(null, memory[store]);
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode);
    const os = t.objectStore(store);
    let result;
    Promise.resolve(fn(os, null)).then((r) => { result = r; });
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  });
}

const req = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });

export async function getMeta(key) {
  return tx("meta", "readonly", (os, mem) => (os ? req(os.get(key)) : mem.get(key))).catch(() => undefined);
}

export async function setMeta(key, value) {
  return tx("meta", "readwrite", (os, mem) => {
    if (os) { value === undefined ? os.delete(key) : os.put(value, key); }
    else if (value === undefined) mem.delete(key); else mem.set(key, value);
  }).catch(() => {});
}

export async function allRecords() {
  return tx("records", "readonly", (os, mem) => (os ? req(os.getAll()) : [...mem.values()])).catch(() => []);
}

/** Lægger rækker fra kontoen ind. Slettede poster fjernes. */
export async function applyRows(rows) {
  if (!rows.length) return;
  await tx("records", "readwrite", (os, mem) => {
    for (const r of rows) {
      const id = `${r.kind}|${r.key}`;
      if (r.deleted || r.data == null) { os ? os.delete(id) : mem.delete(id); }
      else {
        const row = { kind: r.kind, key: r.key, data: r.data, updated_at: r.updated_at ?? "" };
        os ? os.put(row, id) : mem.set(id, row);
      }
    }
  });
}

/** Glemmer alt på enheden (ved log ud eller en anden konto). */
export async function clearAll() {
  await tx("records", "readwrite", (os, mem) => (os ? os.clear() : mem.clear())).catch(() => {});
  await tx("meta", "readwrite", (os, mem) => (os ? os.clear() : mem.clear())).catch(() => {});
}
