// Service worker volontairement minimal.
// Cette app change souvent (Supabase, nouvelles features) : on privilégie toujours le
// réseau pour avoir la dernière version, et on ne se rabat sur le cache que hors-ligne.
// Sans ce fichier, Chrome/Android refuse l'installation ("Ajouter à l'écran d'accueil").

const CACHE_NAME = "courses-shell-v1";
const PRECACHE = ["./index.html", "./manifest.json", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(PRECACHE.map((url) => cache.add(url).catch(() => {})))
    )
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  // Ne jamais intercepter les requêtes vers un autre domaine (Supabase API/Auth/Realtime,
  // Google Fonts, etc.) — on les laisse passer nativement, sans cache ni logique réseau.
  // Objectif : le service worker ne gère QUE les fichiers de l'app elle-même.
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => {});
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match("./index.html")))
  );
});
