# Promat program – frissítési rend (internetes változat)

Érvényes: v54-től (2026-10-19)

**Cím:** https://spikorex-ops.github.io/Promat/

**Kód:** GitHub, spikorex-ops/Promat (nyilvános, csak programkód, projektadat nincs benne)

**Adatok:** Supabase, „Debrecen - EVE - Promat” projekt (privát)

## 1. Mi frissül magától, és mi nem

| Mi változik | Hova kerül | Mit kell tenni |
|---|---|---|
| Rögzítés a programban (pipálás, ki szerelte, fotó, hiba, ütem) | Supabase, azonnal | Semmit. A többi gépen pár másodperc alatt megjelenik. |
| A program maga (új funkció, javítás) | GitHub → internetes cím | Lásd 2. pont. Mindenkinél magától átvált. |
| Adatbázis-szerkezet (ritka, külön szólok) | Supabase SQL | Lásd 4. pont. |
| Alapadatok (új rendszerek, idomok, modell) | Supabase tároló | Lásd 5. pont, külön szólok. |

## 2. Programfrissítés – rendes eset (Claude csinálja)

1. Claude elkészíti az új verziót (vNN). A verziószám a program fejlécében látszik.
2. Claude feltölti a GitHubra a négy fájlt: `index.html`, `sw.js`, `manifest.webmanifest`, `icon.svg`.
3. 1–2 perc múlva élesedik az internetes címen.
4. **Mindenkinél automatikusan az új verzió fut:**
   - Megnyitáskor mindig a legújabb töltődik be (hálózat először).
   - Ha valaki nyitva hagyta a programot, 10 percen belül észleli az újat. Ekkor felül sáv jelenik meg, és a program magától újratölt, amint a felhasználó nem gépel, nincs nyitva ablak, és minden rögzítés feltöltődött.
   - Gyenge térerőnél 5 másodperc után a tárolt változat indul. Amint az új megjött, átvált rá.
   - Net nélkül a tárolt változat indul. A rögzítések helyben várnak, és netnél feltöltődnek.
5. Ellenőrzés (Sándor): nyisd meg a címet, és nézd meg a fejlécben a verziószámot.
6. Tartalékként Claude az önálló fájlt (Promat_konszignacio_vNN.html) a Program mappába is leteszi. A régiek a „Régi verziók” mappába kerülnek.

## 3. Programfrissítés – kézi út (ha Claude nem tud feltölteni)

Claude ilyenkor elküldi a négy fájlt.

1. Töltsd le őket egy mappába.
2. Nyisd meg: https://github.com/spikorex-ops/Promat (bejelentkezve).
3. Kattints: **Add file → Upload files**.
4. Húzd rá a négy fájlt. A régieket felülírja, ez így jó.
5. Lent írd be a „Commit changes” mezőbe: `vNN – rövid leírás`. Kattints: **Commit changes**.
6. Várj 1–2 percet. Az **Actions** fülön a zöld pipa jelzi a kész élesítést.
7. Nyisd meg a programot, és ellenőrizd a verziószámot.

**Soha ne töltsd fel a GitHubra:**
- az önálló `Promat_konszignacio_vNN.html` fájlt (ebben benne vannak az adatok és az árak);
- a `promat-alapadatok-vNN.json` fájlt;
- adatmentést.

A tároló nyilvános.

## 4. Adatbázis-módosítás (csak ha Claude kifejezetten kéri)

1. Supabase → a „Debrecen - EVE - Promat” projekt → **SQL Editor** → **New query**.
2. Másold be a `promat-supabase-vNN.sql` teljes tartalmát → **Run**.
3. Csak ezután töltsd fel az új programot (2. vagy 3. pont).
   - Sorrend: előbb az adatbázis, utána a program.

## 5. Alapadatok cseréje (külön egyeztetés)

- Új IFC-modell, új rendszerek vagy idomok esetén Claude külön megadja a lépéseket és a fájlt (`promat-alapadatok-vNN.json`).
- A rögzítéseket ez nem törli.

## 6. Szabályok

- Rögzíteni csak az internetes változatban szabad. A gépen lévő önálló fájl nincs összekötve vele, ami abban változik, nem kerül fel.
- Minden programváltozás új verziószámot kap.
- Az ingyenes Supabase 1 hét teljes tétlenség után szünetel. Ilyenkor a Supabase oldalán a „Restore” gombbal újraindítható, az adatok megmaradnak.
