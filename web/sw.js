/* Català ASR — service worker.
 * Xarxa primer, cache com a reserva: cada desplegament arriba a la primera càrrega
 * (també a la PWA de la pantalla d'inici) i sense xarxa l'app encara obre.
 * La funció de token i qualsevol no-GET passen sempre per xarxa. */
const CACHE = 'catala-asr-v6';
const SHELL = [
  '/',
  '/index.html',
  '/styles.css',
  '/app.js',
  '/worklet.js',
  '/manifest.webmanifest',
  '/icon.svg',
  '/fonts/inter-latin.woff2',
  '/fonts/inter-latin-ext.woff2',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/maskable-512.png',
  '/icons/apple-touch-icon.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE)
      .then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;
  if (url.pathname.startsWith('/.netlify/')) return; // token: sempre xarxa

  const key = req.mode === 'navigate' ? '/index.html' : url.pathname;
  e.respondWith(
    fetch(req, { cache: 'no-cache' }).then((res) => {
      if (res.ok && res.type === 'basic') {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(key, copy));
      }
      return res;
    }).catch(() => caches.match(key).then((hit) => hit || caches.match(req)))
  );
});
