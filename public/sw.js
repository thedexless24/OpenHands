// Pass-through service worker: no caching, every request hits the network.
// Together with the web app manifest this makes the frontend installable as
// a PWA.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) =>
  event.waitUntil(self.clients.claim()),
);
self.addEventListener("fetch", () => {});
