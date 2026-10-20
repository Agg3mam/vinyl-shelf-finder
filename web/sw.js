// Gør webappen brugbar uden net: appens egne filer hentes fra nettet, når det kan nås (så en ny udgave
// slår igennem med det samme), ellers fra lageret. Covers gemmes, når de først er vist.
// Kald til kontoen (Supabase) går aldrig gennem lageret.

const SHELL = "vinylshelf-app-v5";
const COVERS = "vinylshelf-covers-v1";
const FILES = [
  "./", "index.html", "app.css", "app.js", "coverflow.js", "haptics.js", "manifest.webmanifest",
  "core/search.js", "core/library.js", "core/cloud.js", "core/store.js",
  "vendor/jsQR.js", "icons/icon-180.png", "icons/icon-192.png", "icons/icon-512.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== SHELL && k !== COVERS).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("timeout")), ms);
    promise.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  if (url.origin === self.location.origin) {
    e.respondWith((async () => {
      const cache = await caches.open(SHELL);
      try {
        const res = await withTimeout(fetch(req), 4000);
        if (res.ok) cache.put(req, res.clone());
        return res;
      } catch {
        return (await cache.match(req, { ignoreSearch: true })) ?? (req.mode === "navigate" ? cache.match("index.html") : Response.error());
      }
    })());
    return;
  }

  if (url.hostname.endsWith("discogs.com") && req.destination === "image") {
    e.respondWith((async () => {
      const cache = await caches.open(COVERS);
      const hit = await cache.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok || res.type === "opaque") cache.put(req, res.clone());
      return res;
    })());
  }
});
