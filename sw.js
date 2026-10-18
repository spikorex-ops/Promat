/* Promat – offline indulás: a program fájljai a telefonon / gépen tárolódnak.
   Stratégia: azonnal a tárolt változat indul (térerő nélkül is), közben a háttérben letölti az újat;
   ha változott, a program „Új programverzió” sávot mutat. Az adatforgalom (Supabase) nem megy át ezen. */
const C = 'promat-app-v1', FILES = ['./', 'index.html', 'manifest.webmanifest', 'icon.svg'];
self.addEventListener('install', e => { e.waitUntil(caches.open(C).then(c => c.addAll(FILES)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== C).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url); if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  const isPage = e.request.mode === 'navigate' || /\/(index\.html)?$/.test(u.pathname);
  const key = isPage ? 'index.html' : e.request;
  e.respondWith(caches.open(C).then(async c => {
    const old = await c.match(key, { ignoreSearch: true });
    const net = fetch(e.request, { cache: 'no-cache' }).then(async r => {
      if (r && r.ok) { const t = await r.clone().text().catch(() => null); const o = old ? await old.clone().text().catch(() => null) : null;
        await c.put(key, r.clone()); if (isPage && old && t != null && o != null && t !== o) (await self.clients.matchAll()).forEach(cl => cl.postMessage('uj-verzio')); }
      return r; }).catch(() => null);
    if (old) { e.waitUntil(net); return old; }
    return (await net) || new Response('Nincs kapcsolat, és a program még nincs eltárolva ezen az eszközön.', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
  }));
});
