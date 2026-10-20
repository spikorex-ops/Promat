-- =====================================================================
-- Promat konszignáció – Supabase adatbázis (v75: + terepi réteg; v70: + feladatkiosztás; v59: + belépési / használati napló; v58: ember felvétele; v57: felhasználónév, menük, jelszó)
-- Bemásolandó: Supabase → SQL Editor → New query → Run. Többször is
-- lefuttatható (minden "if not exists" / "or replace").
--
-- Felépítés
--   cegek          – kivitelező cégek (id = a program cégazonosítója: gal, baranyi, kulanda, spiko, kinai…)
--   profilok       – belépett emberek: cég + szerep (admin / cegvezeto / rogzito / olvaso)
--   meghivok       – meghívókódok: ezzel regisztrál egy új ember a cégébe
--   ceg_rendszer   – melyik cég melyik rendszeren rögzíthet (ha egy cégnél üres: mindegyiken)
--   docs           – a program összes adata (gyűjtemény + azonosító + JSON), élő frissítéssel
-- Írni a docs táblába CSAK a doc_set / doc_merge / doc_del függvényekkel lehet – ezek ellenőrzik,
-- hogy az adott ember mit rögzíthet. Olvasni a sorszintű szabály (RLS) szerint lehet: a cégek az
-- árakat, elszámolást, fedezetet, alvállalkozói bizonylatokat egyáltalán nem kapják meg.
-- =====================================================================

create table if not exists public.cegek (
  id text primary key,
  nev text not null,
  tip text not null default 'alv' check (tip in ('sajat','alv','kinai','egyeb')),
  gyart boolean not null default true,
  szerel boolean not null default true,
  aktiv boolean not null default true,
  letrehozva timestamptz not null default now()
);

create table if not exists public.profilok (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nev text not null,
  email text,
  ceg_id text references public.cegek(id),
  szerep text not null check (szerep in ('admin','cegvezeto','rogzito','olvaso')),
  aktiv boolean not null default true,
  letrehozva timestamptz not null default now()
);

create table if not exists public.meghivok (
  kod text primary key,
  ceg_id text references public.cegek(id) on delete cascade,
  szerep text not null check (szerep in ('admin','cegvezeto','rogzito','olvaso')),
  letrehozta uuid,
  lejar timestamptz not null,
  max_db int not null default 1,
  hasznalva int not null default 0,
  letrehozva timestamptz not null default now()
);

create table if not exists public.ceg_rendszer (
  ceg_id text references public.cegek(id) on delete cascade,
  sys text not null,
  primary key (ceg_id, sys)
);

create table if not exists public.docs (
  col text not null,
  id text not null,
  data jsonb not null,
  ceg_id text,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (col, id)
);
create index if not exists docs_col_idx on public.docs (col);

insert into public.cegek (id, nev, tip, gyart, szerel) values
  ('spiko', 'Spiko-Rex (saját)', 'sajat', true, true),
  ('gal', 'Gál Zoltán', 'alv', true, true),
  ('baranyi', 'Baranyi Attila', 'alv', true, true),
  ('kulanda', 'Kulánda Tibi', 'alv', true, true),
  ('kinai', 'Kínai csapat', 'kinai', false, true)
on conflict (id) do nothing;

-- ---------- segédfüggvények (ki vagyok én?) ----------
create or replace function public.en_profil() returns public.profilok
language sql stable security definer set search_path = public as $$
  select p.* from public.profilok p where p.user_id = auth.uid() and p.aktiv
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profilok p where p.user_id = auth.uid() and p.aktiv and p.szerep = 'admin')
$$;
create or replace function public.is_tag() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profilok p where p.user_id = auth.uid() and p.aktiv)
$$;
create or replace function public.en_ceg() returns text
language sql stable security definer set search_path = public as $$
  select p.ceg_id from public.profilok p where p.user_id = auth.uid() and p.aktiv
$$;
create or replace function public.docid(s text) returns text
language sql immutable as $$ select regexp_replace(s, '[^A-Za-z0-9_~:@+-]', '_', 'g') $$;

-- v75: terepi réteg – a nem admin rögzítők saját rétegbe rögzítenek (col 'terep', id = <uid>_<rendszer>); a hivatalosat csak az admin írja
create or replace function public.terep_on() returns boolean language sql stable as $$ select true $$;

-- v70: feladatkiosztás – kié a feladat (címzett vagy a kijelölt csoport tagja / vezetője), ki zárhatja le (egyéni címzett vagy csoportvezető)
create or replace function public.fel_enyem(d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(d->'felh', '[]'::jsonb) ? auth.uid()::text
      or exists (select 1 from public.docs g where g.col = 'csoport'
                 and g.id in (select public.docid(x) from jsonb_array_elements_text(coalesce(d->'csop', '[]'::jsonb)) x)
                 and (coalesce(g.data->'tagok', '[]'::jsonb) ? auth.uid()::text or g.data->>'vezeto' = auth.uid()::text)) $$;
create or replace function public.fel_vezeto(d jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(d->'felh', '[]'::jsonb) ? auth.uid()::text
      or exists (select 1 from public.docs g where g.col = 'csoport'
                 and g.id in (select public.docid(x) from jsonb_array_elements_text(coalesce(d->'csop', '[]'::jsonb)) x)
                 and g.data->>'vezeto' = auth.uid()::text) $$;

-- mit olvashat egy nem-admin tag (árak, elszámolás, költségek: semmit)
create or replace function public.doc_olvashato(p_col text, p_id text, p_data jsonb) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if public.is_admin() then return true; end if;
  if not public.is_tag() then return false; end if;
  if p_col in ('szereles','fotok','hibak','modositas','kezi') then return true; end if;
  if p_col = 'beall' and p_id in ('utem','fold','maradek') then return true; end if;
  if p_col = 'csoport' then return true; end if;
  if p_col = 'terep' then return p_data->>'uid' = auth.uid()::text; end if;
  if p_col = 'feladat' then return public.fel_enyem(p_data); end if;
  if p_col = 'naplo' and p_data->>'uid' = auth.uid()::text then return true; end if;
  if p_col = 'naplo_undo' then
    return exists (select 1 from public.docs n where n.col = 'naplo' and n.id = p_id and n.data->>'uid' = auth.uid()::text);
  end if;
  return false;
end $$;

create or replace function public.jsonb_merge(a jsonb, b jsonb) returns jsonb
language plpgsql immutable as $$
declare k text; v jsonb; r jsonb;
begin
  if a is null or jsonb_typeof(a) <> 'object' or jsonb_typeof(b) <> 'object' then return b; end if;
  r := a;
  for k, v in select * from jsonb_each(b) loop
    if r ? k and jsonb_typeof(r->k) = 'object' and jsonb_typeof(v) = 'object' then
      r := jsonb_set(r, array[k], public.jsonb_merge(r->k, v));
    else
      r := jsonb_set(r, array[k], v);
    end if;
  end loop;
  return r;
end $$;

-- ---------- írásjog-ellenőrzés ----------
create or replace function public.doc_jog(p_col text, p_id text, p_data jsonb, p_op text) returns void
language plpgsql stable security definer set search_path = public as $$
declare me public.profilok; c public.cegek; cur jsonb; curceg text; curby uuid; k text; v jsonb; ph text; sysn text;
begin
  select * into me from public.profilok where user_id = auth.uid() and aktiv;
  if me.user_id is null then raise exception 'not_granted: nincs aktív belépés' using errcode = '42501'; end if;
  if me.szerep = 'admin' then return; end if;
  if me.szerep = 'olvaso' then raise exception 'not_granted: csak olvasási jog' using errcode = '42501'; end if;
  select * into c from public.cegek where id = me.ceg_id and aktiv;
  if c.id is null then raise exception 'not_granted: a cég nincs aktiválva' using errcode = '42501'; end if;
  select d.data, d.ceg_id, d.updated_by into cur, curceg, curby from public.docs d where d.col = p_col and d.id = p_id;

  if p_col = 'szereles' then
    raise exception 'not_granted: a hivatalos állapotot csak az admin rögzíti – a te rögzítésed a saját (terepi) rétegedbe kerül' using errcode = '42501';
  end if;

  if p_col = 'terep' then
    if p_op = 'del' then raise exception 'not_granted: terepi jelölést csak az admin törölhet' using errcode = '42501'; end if;
    if coalesce(p_data->>'uid', '') <> auth.uid()::text or (cur is not null and coalesce(cur->>'uid', '') <> auth.uid()::text)
       or left(p_id, length(public.docid(auth.uid()::text)) + 1) <> public.docid(auth.uid()::text) || '_' then
      raise exception 'not_granted: csak a saját rétegedbe rögzíthetsz' using errcode = '42501'; end if;
    if coalesce(p_data->>'ceg', '') not in ('', me.ceg_id) then raise exception 'not_granted: más cég nevére nem rögzíthet' using errcode = '42501'; end if;
    sysn := coalesce(cur->>'sys', p_data->>'sys');
    if exists (select 1 from public.ceg_rendszer r where r.ceg_id = me.ceg_id)
       and not exists (select 1 from public.ceg_rendszer r where r.ceg_id = me.ceg_id and r.sys = sysn) then
      raise exception 'not_granted: ezen a rendszeren a cég nem rögzíthet (%)', sysn using errcode = '42501';
    end if;
    for k, v in select * from jsonb_each(coalesce(p_data->'p', '{}'::jsonb)) loop
      for ph in select jsonb_object_keys(v) loop
        if ph = 'pid' then continue; end if;
        if ph in ('kesz','helyszin') and not c.gyart then raise exception 'not_granted: a cég nem gyárt' using errcode = '42501'; end if;
        if ph = 'szerelve' and not c.szerel then raise exception 'not_granted: a cég nem szerel' using errcode = '42501'; end if;
        if ph not in ('kesz','helyszin','szerelve') then raise exception 'not_granted: ezt a lépést (%) csak az admin rögzítheti', ph using errcode = '42501'; end if;
        if jsonb_typeof(v->ph) = 'object' and coalesce(v->ph->>'ceg', '') not in ('', me.ceg_id) then
          raise exception 'not_granted: más cég nevére nem rögzíthet' using errcode = '42501'; end if;
        if coalesce((select d.data->'p'->k->ph->>'ceg' from public.docs d where d.col = 'szereles' and d.id = public.docid(sysn)), '') not in ('', me.ceg_id) then
          raise exception 'not_granted: ezt a darabot már más cég rögzítette (hivatalos)' using errcode = '42501'; end if;
      end loop;
    end loop;
    return;
  end if;

  if false then
    sysn := coalesce(cur->>'sys', p_data->>'sys', p_id);
    if exists (select 1 from public.ceg_rendszer r where r.ceg_id = me.ceg_id)
       and not exists (select 1 from public.ceg_rendszer r where r.ceg_id = me.ceg_id and (r.sys = sysn or public.docid(r.sys) = p_id)) then
      raise exception 'not_granted: ezen a rendszeren a cég nem rögzíthet (%)', sysn using errcode = '42501';
    end if;
    for k, v in select * from jsonb_each(coalesce(p_data->'p', '{}'::jsonb)) loop
      for ph in select jsonb_object_keys(v) loop
        if ph = 'pid' then continue; end if;
        if ph in ('kesz','helyszin') and not c.gyart then raise exception 'not_granted: a cég nem gyárt' using errcode = '42501'; end if;
        if ph = 'szerelve' and not c.szerel then raise exception 'not_granted: a cég nem szerel' using errcode = '42501'; end if;
        if ph not in ('kesz','helyszin','szerelve') then raise exception 'not_granted: ezt a lépést (%) csak az admin rögzítheti', ph using errcode = '42501'; end if;
        if jsonb_typeof(v->ph) = 'object' and coalesce(v->ph->>'ceg', '') not in ('', me.ceg_id) then
          raise exception 'not_granted: más cég nevére nem rögzíthet' using errcode = '42501'; end if;
        if coalesce(cur->'p'->k->ph->>'ceg', '') not in ('', me.ceg_id) then
          raise exception 'not_granted: más cég rögzítését nem írhatja felül' using errcode = '42501'; end if;
      end loop;
    end loop;
    return;
  end if;

  if p_col in ('fotok','hibak') then
    if cur is not null and coalesce(curceg, '') <> me.ceg_id then raise exception 'not_granted: más cég adata' using errcode = '42501'; end if;
    if p_op = 'del' and me.szerep <> 'cegvezeto' and curby is distinct from me.user_id then
      raise exception 'not_granted: csak a saját bejegyzés törölhető' using errcode = '42501'; end if;
    return;
  end if;

  if p_col in ('naplo','naplo_undo') then
    if p_op = 'del' then raise exception 'not_granted' using errcode = '42501'; end if;
    if cur is not null and curby is distinct from me.user_id then raise exception 'not_granted' using errcode = '42501'; end if;
    return;
  end if;

  if p_col = 'feladat' then
    if p_op <> 'merge' or cur is null or not public.fel_enyem(cur) then raise exception 'not_granted: feladatot csak az admin oszthat ki / módosíthat' using errcode = '42501'; end if;
    for k in select jsonb_object_keys(p_data) loop
      if k = 'elf' then
        if jsonb_typeof(p_data->'elf') <> 'object' or (select count(*) from jsonb_object_keys(p_data->'elf')) <> 1 or not (p_data->'elf' ? auth.uid()::text) then
          raise exception 'not_granted: csak a saját elfogadásodat jelezheted' using errcode = '42501'; end if;
      elsif k = 'kesz' then
        if not public.fel_vezeto(cur) then raise exception 'not_granted: befejezettnek csak a csoportvezető (vagy az egyéni címzett) jelölheti' using errcode = '42501'; end if;
        if jsonb_typeof(p_data->'kesz') <> 'object' then raise exception 'not_granted: lezárást csak az admin vonhat vissza' using errcode = '42501'; end if;
      else raise exception 'not_granted: a feladatnál csak az elfogadás és a befejezés jelezhető' using errcode = '42501'; end if;
    end loop;
    return;
  end if;

  raise exception 'not_granted: ezt az adatot (%) csak az admin módosíthatja', p_col using errcode = '42501';
end $$;

create or replace function public.doc_set(p_col text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.doc_jog(p_col, p_id, p_data, 'set');
  insert into public.docs (col, id, data, ceg_id, updated_by, updated_at)
  values (p_col, p_id, p_data, public.en_ceg(), auth.uid(), now())
  on conflict (col, id) do update set data = excluded.data, updated_by = excluded.updated_by, updated_at = now(),
    ceg_id = coalesce(public.docs.ceg_id, excluded.ceg_id);
end $$;

create or replace function public.doc_merge(p_col text, p_id text, p_patch jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.doc_jog(p_col, p_id, p_patch, 'merge');
  insert into public.docs (col, id, data, ceg_id, updated_by, updated_at)
  values (p_col, p_id, p_patch, public.en_ceg(), auth.uid(), now())
  on conflict (col, id) do update set data = public.jsonb_merge(public.docs.data, excluded.data), updated_by = excluded.updated_by, updated_at = now();
end $$;

create or replace function public.doc_del(p_col text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.doc_jog(p_col, p_id, null, 'del');
  delete from public.docs where col = p_col and id = p_id;
end $$;

-- több írás egy hívásban (offline sor gyors feltöltése); sorrendben, egy tranzakcióban
create or replace function public.doc_batch(p_ops jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare o jsonb; n int := 0;
begin
  for o in select * from jsonb_array_elements(p_ops) loop
    if o->>'k' = 'set' then perform public.doc_set(o->>'col', o->>'id', o->'data');
    elsif o->>'k' = 'merge' then perform public.doc_merge(o->>'col', o->>'id', o->'data');
    elsif o->>'k' = 'del' then perform public.doc_del(o->>'col', o->>'id');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- tagság: első admin, meghívó, csatlakozás, emberek kezelése ----------
create or replace function public.admin_igenyles(p_nev text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_granted: nincs belépve' using errcode = '42501'; end if;
  if exists (select 1 from public.profilok where szerep = 'admin') then
    raise exception 'not_granted: már van admin – kérj meghívókódot' using errcode = '42501'; end if;
  insert into public.profilok (user_id, nev, email, ceg_id, szerep)
  values (auth.uid(), p_nev, (select email from auth.users where id = auth.uid()), 'spiko', 'admin')
  on conflict (user_id) do update set szerep = 'admin', aktiv = true, nev = excluded.nev;
  return 'admin';
end $$;

create or replace function public.meghivo_uj(p_ceg text, p_szerep text, p_napok int default 14, p_db int default 1) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profilok; kod text;
begin
  select * into me from public.profilok where user_id = auth.uid() and aktiv;
  if me.user_id is null then raise exception 'not_granted' using errcode = '42501'; end if;
  if me.szerep = 'cegvezeto' then
    if p_ceg is distinct from me.ceg_id or p_szerep <> 'rogzito' then
      raise exception 'not_granted: cégvezető csak a saját cégébe hívhat rögzítőt' using errcode = '42501'; end if;
  elsif me.szerep <> 'admin' then raise exception 'not_granted' using errcode = '42501'; end if;
  if p_szerep not in ('admin','cegvezeto','rogzito','olvaso') then raise exception 'invalid_argument: szerep' using errcode = '22023'; end if;
  kod := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
  insert into public.meghivok (kod, ceg_id, szerep, letrehozta, lejar, max_db)
  values (kod, p_ceg, p_szerep, auth.uid(), now() + make_interval(days => greatest(1, least(coalesce(p_napok, 14), 90))), greatest(1, least(coalesce(p_db, 1), 50)));
  return kod;
end $$;

create or replace function public.csatlakozas(p_kod text, p_nev text) returns text
language plpgsql security definer set search_path = public as $$
declare m public.meghivok;
begin
  if auth.uid() is null then raise exception 'not_granted: nincs belépve' using errcode = '42501'; end if;
  if exists (select 1 from public.profilok where user_id = auth.uid()) then
    raise exception 'invalid_argument: ez a fiók már tag' using errcode = '22023'; end if;
  select * into m from public.meghivok where kod = upper(trim(p_kod)) for update;
  if m.kod is null or m.lejar < now() or m.hasznalva >= m.max_db then
    raise exception 'not_granted: érvénytelen vagy lejárt meghívókód' using errcode = '42501'; end if;
  if coalesce(trim(p_nev), '') = '' then raise exception 'invalid_argument: név kell' using errcode = '22023'; end if;
  insert into public.profilok (user_id, nev, email, ceg_id, szerep)
  values (auth.uid(), trim(p_nev), (select email from auth.users where id = auth.uid()), m.ceg_id, m.szerep);
  update public.meghivok set hasznalva = hasznalva + 1 where kod = m.kod;
  return m.szerep;
end $$;

create or replace function public.profil_allit(p_user uuid, p_aktiv boolean, p_szerep text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profilok; t public.profilok;
begin
  select * into me from public.profilok where user_id = auth.uid() and aktiv;
  select * into t from public.profilok where user_id = p_user;
  if me.user_id is null or t.user_id is null then raise exception 'not_granted' using errcode = '42501'; end if;
  if p_user = me.user_id then raise exception 'not_granted: saját magát nem állíthatja' using errcode = '42501'; end if;
  if me.szerep = 'cegvezeto' then
    if t.ceg_id is distinct from me.ceg_id or t.szerep <> 'rogzito' or coalesce(p_szerep, 'rogzito') <> 'rogzito' then
      raise exception 'not_granted: cégvezető csak a saját rögzítőit kapcsolhatja ki/be' using errcode = '42501'; end if;
  elsif me.szerep <> 'admin' then raise exception 'not_granted' using errcode = '42501'; end if;
  update public.profilok set aktiv = p_aktiv, szerep = coalesce(p_szerep, szerep) where user_id = p_user;
end $$;

create or replace function public.ceg_ment(p_id text, p_nev text, p_tip text, p_gyart boolean, p_szerel boolean, p_aktiv boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_granted' using errcode = '42501'; end if;
  insert into public.cegek (id, nev, tip, gyart, szerel, aktiv) values (p_id, p_nev, coalesce(p_tip, 'alv'), p_gyart, p_szerel, p_aktiv)
  on conflict (id) do update set nev = excluded.nev, tip = excluded.tip, gyart = excluded.gyart, szerel = excluded.szerel, aktiv = excluded.aktiv;
end $$;

create or replace function public.ceg_rendszerek(p_ceg text, p_sys text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_granted' using errcode = '42501'; end if;
  delete from public.ceg_rendszer where ceg_id = p_ceg;
  insert into public.ceg_rendszer (ceg_id, sys) select p_ceg, s from unnest(coalesce(p_sys, '{}')) s where coalesce(s, '') <> '' on conflict do nothing;
end $$;

create or replace function public.meghivo_torol(p_kod text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_admin() or exists (select 1 from public.meghivok m join public.profilok p on p.user_id = auth.uid() and p.aktiv and p.szerep = 'cegvezeto' and p.ceg_id = m.ceg_id where m.kod = p_kod)) then
    raise exception 'not_granted' using errcode = '42501'; end if;
  delete from public.meghivok where kod = p_kod;
end $$;

-- ---------- v57: személyre szabott menük és jelszó-visszaállítás ----------
-- tilt: azok a menüpontok, amelyeket ez az ember NEM lát (a szerepe által engedettekből vesz el; árat / elszámolást
-- ettől függetlenül csak az admin kap az adatbázistól). Felhasználónév: a program <név>@promat.invalid címen tárolja.
alter table public.profilok add column if not exists tilt text[] not null default '{}';
create extension if not exists pgcrypto with schema extensions;

create or replace function public.kezelheti(p_user uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare me public.profilok; t public.profilok;
begin
  select * into me from public.profilok where user_id = auth.uid() and aktiv;
  select * into t from public.profilok where user_id = p_user;
  if me.user_id is null or t.user_id is null or p_user = me.user_id then return false; end if;
  if me.szerep = 'admin' then return true; end if;
  return me.szerep = 'cegvezeto' and t.ceg_id is not distinct from me.ceg_id and t.szerep in ('rogzito','olvaso');
end $$;

create or replace function public.profil_tilt(p_user uuid, p_tilt text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.kezelheti(p_user) then raise exception 'not_granted: ennek az embernek a menüit nem állíthatod' using errcode = '42501'; end if;
  update public.profilok set tilt = coalesce((select array_agg(distinct x) from unnest(p_tilt) x where coalesce(x, '') <> ''), '{}') where user_id = p_user;
end $$;

create or replace function public.jelszo_allit(p_user uuid, p_jelszo text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.kezelheti(p_user) then raise exception 'not_granted: ennek az embernek a jelszavát nem állíthatod' using errcode = '42501'; end if;
  if length(coalesce(p_jelszo, '')) < 8 then raise exception 'invalid_argument: a jelszó legalább 8 karakter legyen' using errcode = '22023'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_jelszo, extensions.gen_salt('bf', 10)), updated_at = now() where id = p_user;
end $$;

-- ---------- v58: új ember felvétele közvetlenül (admin / cégvezető), meghívókód nélkül ----------
-- A program előbb létrehozza a bejelentkezési fiókot (felhasználónév + jelszó), majd ezzel a cégéhez és szerepéhez köti.
-- Csak az utolsó 30 percben létrehozott, még semmihez nem kötött fiók köthető be – meglévő fiókot így nem lehet elvenni.
create or replace function public.felh_letrehoz(p_user uuid, p_nev text, p_ceg text, p_szerep text, p_tilt text[] default '{}') returns void
language plpgsql security definer set search_path = public as $$
declare me public.profilok; u record;
begin
  select * into me from public.profilok where user_id = auth.uid() and aktiv;
  if me.user_id is null then raise exception 'not_granted' using errcode = '42501'; end if;
  if p_szerep not in ('admin','cegvezeto','rogzito','olvaso') then raise exception 'invalid_argument: szerep' using errcode = '22023'; end if;
  if me.szerep = 'cegvezeto' then
    if p_ceg is distinct from me.ceg_id or p_szerep not in ('rogzito','olvaso') then
      raise exception 'not_granted: cégvezető csak a saját cégébe vehet fel rögzítőt / olvasót' using errcode = '42501'; end if;
  elsif me.szerep <> 'admin' then raise exception 'not_granted' using errcode = '42501'; end if;
  if coalesce(trim(p_nev), '') = '' then raise exception 'invalid_argument: név kell' using errcode = '22023'; end if;
  if not exists (select 1 from public.cegek where id = p_ceg) then raise exception 'invalid_argument: ismeretlen cég' using errcode = '22023'; end if;
  select id, email, created_at into u from auth.users where id = p_user;
  if u.id is null then raise exception 'invalid_argument: nincs ilyen fiók' using errcode = '22023'; end if;
  if exists (select 1 from public.profilok where user_id = p_user) then raise exception 'invalid_argument: ez a fiók már tag' using errcode = '22023'; end if;
  if u.created_at < now() - interval '30 minutes' then raise exception 'not_granted: csak most létrehozott fiók köthető be' using errcode = '42501'; end if;
  insert into public.profilok (user_id, nev, email, ceg_id, szerep, tilt)
  values (p_user, trim(p_nev), u.email, p_ceg, p_szerep, coalesce((select array_agg(distinct x) from unnest(p_tilt) x where coalesce(x, '') <> ''), '{}'));
end $$;

-- ---------- v59: belépési és használati napló (csak az admin látja) ----------
-- Minden belépés egy munkamenet; a program percenként jelez: melyik oldalon van, mennyi ideig használta ténylegesen
-- (aktív = látható az ablak és az utolsó 3 percben volt kattintás / gépelés). 180 napnál régebbi sorok törlődnek.
create table if not exists public.munkamenet (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kezdet timestamptz not null default now(),
  utolso timestamptz not null default now(),
  aktiv_mp int not null default 0,
  eszkoz text,
  oldalak jsonb not null default '{}',
  vege timestamptz
);
alter table public.munkamenet add column if not exists vege timestamptz;
create index if not exists munkamenet_kezdet on public.munkamenet (kezdet desc);
create index if not exists munkamenet_user on public.munkamenet (user_id, kezdet desc);
alter table public.munkamenet enable row level security;
drop policy if exists munkamenet_olv on public.munkamenet;
create policy munkamenet_olv on public.munkamenet for select to authenticated using (public.is_admin());
revoke all on public.munkamenet from anon;
grant select on public.munkamenet to authenticated;
revoke insert, update, delete on public.munkamenet from authenticated;

create or replace function public.mm_kezd(p_eszkoz text) returns bigint
language plpgsql security definer set search_path = public as $$
declare nid bigint;
begin
  if not public.is_tag() then raise exception 'not_granted' using errcode = '42501'; end if;
  delete from public.munkamenet where kezdet < now() - interval '180 days';
  insert into public.munkamenet (user_id, eszkoz) values (auth.uid(), left(coalesce(p_eszkoz, ''), 120)) returning id into nid;
  return nid;
end $$;

create or replace function public.mm_jel(p_id bigint, p_mp int, p_oldal text) returns void
language plpgsql security definer set search_path = public as $$
declare d int := greatest(0, least(coalesce(p_mp, 0), 900)); o text := left(coalesce(nullif(trim(p_oldal), ''), '—'), 60);
begin
  update public.munkamenet
     set utolso = now(), aktiv_mp = aktiv_mp + d,
         oldalak = case when d > 0 then jsonb_set(oldalak, array[o], to_jsonb(coalesce((oldalak->>o)::int, 0) + d)) else oldalak end
   where id = p_id and user_id = auth.uid() and kezdet > now() - interval '2 days';
end $$;

create or replace function public.mm_vege(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.munkamenet set vege = now(), utolso = now() where id = p_id and user_id = auth.uid() and vege is null;
end $$;

-- ---------- sorszintű olvasási szabályok ----------
alter table public.cegek enable row level security;
alter table public.profilok enable row level security;
alter table public.meghivok enable row level security;
alter table public.ceg_rendszer enable row level security;
alter table public.docs enable row level security;

drop policy if exists cegek_olv on public.cegek;
create policy cegek_olv on public.cegek for select to authenticated using (public.is_tag());
drop policy if exists profilok_olv on public.profilok;
create policy profilok_olv on public.profilok for select to authenticated
  using (user_id = auth.uid() or public.is_admin() or (ceg_id = public.en_ceg() and (public.en_profil()).szerep = 'cegvezeto'));
drop policy if exists meghivok_olv on public.meghivok;
create policy meghivok_olv on public.meghivok for select to authenticated
  using (public.is_admin() or (ceg_id = public.en_ceg() and (public.en_profil()).szerep = 'cegvezeto'));
drop policy if exists ceg_rendszer_olv on public.ceg_rendszer;
create policy ceg_rendszer_olv on public.ceg_rendszer for select to authenticated using (public.is_tag());
drop policy if exists docs_olv on public.docs;
create policy docs_olv on public.docs for select to authenticated using (public.doc_olvashato(col, id, data));
-- közvetlen írás egyik táblába sincs engedve: minden írás a fenti függvényeken keresztül megy

revoke all on public.cegek, public.profilok, public.meghivok, public.ceg_rendszer, public.docs from anon;
grant select on public.cegek, public.profilok, public.meghivok, public.ceg_rendszer, public.docs to authenticated;
revoke insert, update, delete on public.cegek, public.profilok, public.meghivok, public.ceg_rendszer, public.docs from authenticated;
revoke execute on all functions in schema public from anon;
grant execute on function public.doc_set(text, text, jsonb), public.doc_merge(text, text, jsonb), public.doc_del(text, text), public.doc_batch(jsonb),
  public.admin_igenyles(text), public.meghivo_uj(text, text, int, int), public.csatlakozas(text, text), public.profil_allit(uuid, boolean, text),
  public.ceg_ment(text, text, text, boolean, boolean, boolean), public.ceg_rendszerek(text, text[]), public.meghivo_torol(text),
  public.en_profil(), public.is_admin(), public.is_tag(), public.en_ceg(),
  public.kezelheti(uuid), public.profil_tilt(uuid, text[]), public.jelszo_allit(uuid, text),
  public.felh_letrehoz(uuid, text, text, text, text[]), public.mm_kezd(text), public.mm_jel(bigint, int, text), public.mm_vege(bigint) to authenticated;

-- ---------- élő frissítés (más gépen rögzített adat azonnal megjelenik) ----------
alter table public.docs replica identity full;
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    execute 'alter publication supabase_realtime add table public.docs';
  end if;
end $$;

-- ---------- fájltároló: alapadatok, fotók, mentések (privát) ----------
--   adat/data.json   – a modell (rendszerek, idomok): minden tag olvassa
--   adat/seed.json   – árak, bizonylatok, TIG-ek alapadatai: csak admin
--   foto/<cég>/…     – fotók: tag a saját cége mappájába tölthet, minden tag láthatja
--   mentes/…         – teljes mentések: csak admin
insert into storage.buckets (id, name, public) values ('promat', 'promat', false) on conflict (id) do nothing;

drop policy if exists promat_olv on storage.objects;
create policy promat_olv on storage.objects for select to authenticated using (
  bucket_id = 'promat' and (public.is_admin() or (public.is_tag() and (name = 'adat/data.json' or name like 'foto/%'))));
drop policy if exists promat_ir on storage.objects;
create policy promat_ir on storage.objects for insert to authenticated with check (
  bucket_id = 'promat' and (public.is_admin() or (public.is_tag() and (public.en_profil()).szerep in ('cegvezeto','rogzito') and name like 'foto/' || public.en_ceg() || '/%')));
drop policy if exists promat_mod on storage.objects;
create policy promat_mod on storage.objects for update to authenticated using (bucket_id = 'promat' and public.is_admin());
drop policy if exists promat_tor on storage.objects;
create policy promat_tor on storage.objects for delete to authenticated using (bucket_id = 'promat' and public.is_admin());

-- v70: feladatkiosztás segédfüggvényei
revoke execute on function public.fel_enyem(jsonb), public.fel_vezeto(jsonb) from anon, public;
grant execute on function public.fel_enyem(jsonb), public.fel_vezeto(jsonb) to authenticated;

-- v75: terepi réteg
revoke execute on function public.terep_on() from anon, public;
grant execute on function public.terep_on() to authenticated;
