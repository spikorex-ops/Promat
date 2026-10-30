/* Promat – programfájlok kezelése.
   Stratégia (v54-től): HÁLÓZAT ELŐSZÖR. Megnyitáskor mindig a GitHubon lévő legújabb változat indul.
   Ha 5 mp-en belül nincs válasz (gyenge térerő) vagy nincs net, a tárolt változat indul, és amint az új
   megjött, a program magától átvált rá (a rögzítések a helyi sorban megmaradnak).
   Az adatforgalom (Supabase) nem megy át ezen. */
const C = 'promat-app-v2', FILES = ['./', 'index.html', 'manifest.webmanifest', 'icon.svg'], WAIT = 5000;
self.addEventListener('install', e => { e.waitUntil(caches.open(C).then(c => c.addAll(FILES)).catch(() => { }).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== C).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
const notify = async () => (await self.clients.matchAll()).forEach(cl => cl.postMessage('uj-verzio'));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url); if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  if (/\/sw\.js$/.test(u.pathname)) return;
  const isPage = e.request.mode === 'navigate' || /\/(index\.html)?$/.test(u.pathname);
  const key = isPage ? 'index.html' : e.request;
  e.respondWith(caches.open(C).then(async c => {
    const old = await c.match(key, { ignoreSearch: true });
    let servedOld = false;
    const net = fetch(isPage ? new Request('index.html', { cache: 'no-cache' }) : e.request, isPage ? undefined : { cache: 'no-cache' }).then(async r => {
      if (r && r.ok) {
        let changed = false;
        if (isPage && old) { const t = await r.clone().text().catch(() => null), o = await old.clone().text().catch(() => null); changed = t != null && o != null && t !== o; }
        await c.put(key, r.clone());
        if (changed && servedOld) await notify();   // a régit kapta meg, közben megjött az új → átváltás
      }
      return r;
    }).catch(() => null);
    if (!old) return (await net) || new Response('Nincs kapcsolat, és a program még nincs eltárolva ezen az eszközön.', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    if (!isPage) { e.waitUntil(net); return old; }
    const r = await Promise.race([net, new Promise(res => setTimeout(() => res('timeout'), WAIT))]);
    if (r && r !== 'timeout') return r;
    servedOld = true; e.waitUntil(net); return old;
  }));
});
// a nyitva hagyott program kérésére: van-e újabb változat a szerveren
self.addEventListener('message', e => {
  if (e.data !== 'ellenoriz') return;
  e.waitUntil(caches.open(C).then(async c => {
    const old = await c.match('index.html'); const r = await fetch(new Request('index.html', { cache: 'no-cache' })).catch(() => null);
    if (!r || !r.ok) return;
    const t = await r.clone().text(), o = old ? await old.text() : null;
    if (o !== t) { await c.put('index.html', r); if (o != null) await notify(); }
  }));
});

// v165: értesítésre kattintva a program előjön (vagy megnyílik) a feladattal
self.addEventListener('notificationclick', e => { e.notification.close(); const id = e.notification.data || ''; e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => { for (const c of cs) { c.postMessage('feladat:' + id); return c.focus(); } return self.clients.openWindow('./'); })); });
