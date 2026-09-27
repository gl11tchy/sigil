const CACHE = 'sidereal-shell-v26';
const SHELL = ['/', '/app.mjs', '/output.mjs', '/crypto.mjs', '/pairing.mjs', '/style.css', '/manifest.webmanifest', '/icon.svg', '/icon-180.png', '/icon-192.png', '/icon-512.png',
  '/fonts/Inter-Regular.woff2', '/fonts/Inter-Medium.woff2', '/fonts/Inter-SemiBold.woff2',
  '/fonts/JetBrainsMono-Regular.woff2', '/fonts/JetBrainsMono-Medium.woff2'];
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
});
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.search || !SHELL.includes(url.pathname)) return;
  // Fonts are immutable: serve the cached copy and skip the network.
  if (url.pathname.startsWith('/fonts/')) {
    event.respondWith(caches.match(url.pathname).then(hit => hit || fetch(event.request)));
    return;
  }
  event.respondWith(fetch(event.request).catch(() => caches.match(url.pathname)));
});
