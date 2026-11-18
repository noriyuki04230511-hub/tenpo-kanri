-- 工程C（2026-11-19）：IDとパスワードのログイン、役割（卓・店長・本部）、兼務の名簿、管理画面の集計、管理画面デモ用の見本データ
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- 名簿・アカウント・役割 ----------
alter table public.shops add column code text unique;
create table public.staff_shops (
  staff_id integer not null references public.staff,
  shop_id  integer not null references public.shops,
  primary key (staff_id, shop_id)
);
insert into public.staff_shops select staff_id, shop_id from public.staff where shop_id is not null;

-- ログイン用のアカウント。パスワードはハッシュだけを持つ（元の文字は保存しない）
create table public.accounts (
  login_id     text primary key,
  kind         text not null check (kind in ('table','manager','hq')),
  shop_id      integer references public.shops,
  pass_hash    text,
  pass_set_at  timestamptz,
  failed       integer not null default 0,
  locked_until timestamptz,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  check ((kind = 'hq') = (shop_id is null))
);
alter table public.devices alter column shop_id drop not null;
alter table public.devices
  add column role text not null default 'table' check (role in ('table','manager','hq','demo')),
  add column login_id text references public.accounts,
  add column last_seen_at timestamptz;
update public.devices d set role = 'demo' where exists (select 1 from public.shops s where s.shop_id = d.shop_id and s.is_demo);
alter table public.staff_shops enable row level security;
alter table public.accounts enable row level security;

-- ---------- 既存の関数の手直し ----------
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- スタッフの一覧と出勤は、兼務を含む名簿（staff_shops）で見る
select pg_temp.patch('public.app_floor(uuid,text)',
  'from public.staff st where st.shop_id = s and st.active',
  'from public.staff st where st.active and exists (select 1 from public.staff_shops ss where ss.staff_id = st.staff_id and ss.shop_id = s)');
select pg_temp.patch('public.app_clock_in(uuid,text,text)',
  'if not exists (select 1 from public.staff where staff_id = sid and shop_id = s and active) then',
  'if not exists (select 1 from public.staff st join public.staff_shops ss on ss.staff_id = st.staff_id where st.staff_id = sid and ss.shop_id = s and st.active) then');
-- ヒアリングの5問がそろっていない保存は、データベース側でも受け付けない
select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  'if h is not null and jsonb_typeof(h) = ''object'' and h->>''age'' is not null then',
  'if h is not null and jsonb_typeof(h) = ''object'' and h->>''age'' is not null then
    if h->>''purpose'' is null or h->>''carrier'' is null or h->>''lines'' is null or h->>''net'' is null then
      raise exception ''hearing_incomplete'' using errcode = ''22023'';
    end if;');
-- 見本店に登録した端末は「見本用」の役割にする
select pg_temp.patch('public.app_enroll_demo(text)',
  'insert into public.devices(id,shop_id,label,secret_hash) values (did, s,',
  'insert into public.devices(id,shop_id,role,label,secret_hash) values (did, s, ''demo'',');
select pg_temp.patch('public.app_enroll_demo(text)',
  'return json_build_object(''device'', did, ''secret'', sec);',
  'return json_build_object(''device'', did, ''secret'', sec, ''role'', ''demo'');');

-- 卓用の端末には、スタッフ別の数字のもとになる記録・ヒアリングのお知らせ・アンケートの件数を返さない
alter function public.app_floor(uuid,text) rename to app__floor_full;
revoke execute on function public.app__floor_full(uuid,text) from public, anon, authenticated;
create function public.app_floor(p_device uuid, p_secret text) returns json
language plpgsql security definer set search_path = '' as $$
declare f jsonb := public.app__floor_full(p_device, p_secret)::jsonb; r text;
begin
  select role into r from public.devices where id = p_device;
  update public.devices set last_seen_at = now() where id = p_device and (last_seen_at is null or last_seen_at < now() - interval '10 minutes');
  if r = 'table' then
    f := f || jsonb_build_object('closed', '[]'::jsonb, 'feed', '[]'::jsonb, 'surveys', null, 'surveyAvg', null);
  end if;
  return (f || jsonb_build_object('role', r))::json;
end $$;

-- ---------- ログイン ----------
-- 失敗しても例外にしない（失敗回数を確実に記録するため）。5回続けて間違えると5分間は入れない
create function public.app_login(p_id text, p_password text, p_label text) returns json
language plpgsql security definer set search_path = '' as $$
declare a public.accounts; did uuid := gen_random_uuid();
  sec text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  select * into a from public.accounts where login_id = lower(trim(p_id)) and active;
  if a.login_id is null then perform pg_sleep(0.3); return json_build_object('error', 'login_failed'); end if;
  if a.locked_until is not null and a.locked_until > now() then return json_build_object('error', 'locked'); end if;
  if a.pass_hash is null then return json_build_object('need_setup', true); end if;
  if p_password is null or a.pass_hash <> extensions.crypt(p_password, a.pass_hash) then
    update public.accounts set failed = case when failed + 1 >= 5 then 0 else failed + 1 end,
           locked_until = case when failed + 1 >= 5 then now() + interval '5 minutes' end where login_id = a.login_id;
    insert into public.events(shop_id,action,target_table,target_id) values (a.shop_id, 'login.failed', 'accounts', a.login_id);
    return json_build_object('error', 'login_failed');
  end if;
  update public.accounts set failed = 0, locked_until = null where login_id = a.login_id;
  insert into public.devices(id,shop_id,role,login_id,label,secret_hash)
    values (did, a.shop_id, a.kind, a.login_id, left(coalesce(nullif(p_label,''),'端末'),60), encode(sha256(convert_to(sec,'UTF8')),'hex'));
  insert into public.events(shop_id,device_id,action,target_table,target_id) values (a.shop_id, did, 'login.ok', 'accounts', a.login_id);
  return json_build_object('device', did, 'secret', sec, 'role', a.kind,
    'shop', (select name from public.shops where shop_id = a.shop_id));
end $$;

-- 最初の1回だけ、パスワードを決める（すでに決まっているアカウントには使えない）
create function public.app_set_password(p_id text, p_new text) returns json
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_new is null or length(p_new) < 8 then return json_build_object('error', 'too_short'); end if;
  update public.accounts set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), pass_set_at = now()
   where login_id = lower(trim(p_id)) and active and pass_hash is null;
  get diagnostics n = row_count;
  if n = 0 then return json_build_object('error', 'already_set'); end if;
  insert into public.events(action,target_table,target_id) values ('password.first_set', 'accounts', lower(trim(p_id)));
  return json_build_object('ok', true);
end $$;

create function public.app_change_password(p_id text, p_old text, p_new text) returns json
language plpgsql security definer set search_path = '' as $$
declare a public.accounts;
begin
  if p_new is null or length(p_new) < 8 then return json_build_object('error', 'too_short'); end if;
  select * into a from public.accounts where login_id = lower(trim(p_id)) and active;
  if a.login_id is null or a.pass_hash is null or (a.locked_until is not null and a.locked_until > now())
     or a.pass_hash <> extensions.crypt(p_old, a.pass_hash) then
    perform pg_sleep(0.3); return json_build_object('error', 'login_failed');
  end if;
  update public.accounts set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), pass_set_at = now() where login_id = a.login_id;
  update public.devices set revoked_at = now() where login_id = a.login_id and revoked_at is null;
  insert into public.events(shop_id,action,target_table,target_id) values (a.shop_id, 'password.changed', 'accounts', a.login_id);
  return json_build_object('ok', true);
end $$;

create function public.app_logout(p_device uuid, p_secret text) returns json
language plpgsql security definer set search_path = '' as $$
begin
  update public.devices set revoked_at = now()
   where id = p_device and revoked_at is null and secret_hash = encode(sha256(convert_to(p_secret,'UTF8')),'hex');
  return json_build_object('ok', true);
end $$;

-- ---------- 管理画面の集計 ----------
-- 店長用＝自店だけ、本部用＝本物の全店、見本用＝見本の店だけ。卓用の端末は使えない
create function public.app_report(p_device uuid, p_secret text, p_from date, p_to date, p_shop integer) returns json
language plpgsql security definer set search_path = '' as $$
declare dv public.devices; ids integer[]; out json;
begin
  select * into dv from public.devices d where d.id = p_device and d.revoked_at is null
     and d.secret_hash = encode(sha256(convert_to(p_secret,'UTF8')),'hex');
  if dv.id is null then raise exception 'device_not_registered' using errcode = '28000'; end if;
  if dv.role = 'table' then raise exception 'forbidden' using errcode = '42501'; end if;
  if dv.role = 'demo' then perform public.app__demo_history(); end if;
  select array_agg(s.shop_id) into ids from public.shops s
   where s.active and case dv.role when 'manager' then s.shop_id = dv.shop_id when 'hq' then not s.is_demo else s.is_demo end
     and (p_shop is null or dv.role = 'manager' or s.shop_id = p_shop);
  ids := coalesce(ids, '{}');
  if p_to - p_from > 92 then p_from := p_to - 92; end if;
  with sh as (select shop_id, name from public.shops where shop_id = any(ids)),
  v as (
    select v.*, (v.started_at at time zone 'Asia/Tokyo')::date as day,
           exists (select 1 from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id
                    where g.visit_id = v.id and sp.proposed_at is not null) as proposed
      from public.visits v where v.shop_id = any(ids) and (v.started_at at time zone 'Asia/Tokyo')::date between p_from and p_to),
  sv as (select s.* from public.surveys s where s.shop_id = any(ids) and (s.created_at at time zone 'Asia/Tokyo')::date between p_from and p_to)
  select json_build_object(
    'now', public.app__ms(now()), 'role', dv.role, 'from', p_from, 'to', p_to,
    'allShops', coalesce((select json_agg(json_build_object('id',s.shop_id,'name',s.name) order by s.shop_id) from public.shops s
                  where s.active and case dv.role when 'manager' then s.shop_id = dv.shop_id when 'hq' then not s.is_demo else s.is_demo end), '[]'::json),
    'total', (select json_build_object('visits',count(*),'guide',count(*) filter (where visit_type = 'in_guide'),
                'proposed',count(*) filter (where proposed),'won',count(*) filter (where result = 'won'),'open',count(*) filter (where ended_at is null)) from v),
    'byShop', coalesce((select json_agg(json_build_object('id',sh.shop_id,'name',sh.name,'visits',c.n,'guide',c.g,'proposed',c.p,'won',c.w,'sat',c.sat,'satN',c.satn) order by sh.shop_id)
      from sh left join lateral (
        select count(*) n, count(*) filter (where visit_type = 'in_guide') g, count(*) filter (where proposed) p, count(*) filter (where result = 'won') w,
               (select count(*) from sv where sv.shop_id = sh.shop_id and sv.answered) satn,
               (select round(avg((q_service + q_clarity)/2.0),1) from sv where sv.shop_id = sh.shop_id and sv.answered) sat
          from v where v.shop_id = sh.shop_id) c on true), '[]'::json),
    'byDay', (select json_agg(json_build_object('day',dd::date,'visits',c.n,'proposed',c.p,'won',c.w) order by dd)
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') dd
      left join lateral (select count(*) n, count(*) filter (where proposed) p, count(*) filter (where result = 'won') w from v where v.day = dd::date) c on true),
    'byType', (select json_agg(json_build_object('label',t.label,'visits',c.n,'won',c.w) order by t.sort)
      from public.m_visit_types t left join lateral (select count(*) n, count(*) filter (where result = 'won') w from v where v.visit_type = t.key) c on true),
    'byAge', coalesce((select json_agg(json_build_object('age',a.age,'visits',a.n,'won',a.w) order by a.age)
      from (select h.age_band age, count(*) n, count(*) filter (where v.result = 'won') w from v join public.visit_hearings h on h.visit_id = v.id group by 1) a), '[]'::json),
    'byStaff', coalesce((select json_agg(json_build_object('name',x.name,'shop',x.shop,'visits',x.n,'proposed',x.p,'won',x.w) order by x.n desc, x.name)
      from (select coalesce(st.display_name, hp.name) as name, sn.name as shop, count(distinct v.id) n,
                   count(distinct v.id) filter (where exists (select 1 from public.segment_products sp where sp.segment_id = g.id and sp.proposed_at is not null)) p,
                   count(distinct v.id) filter (where exists (select 1 from public.segment_products sp where sp.segment_id = g.id and sp.won_at is not null)) w
              from v join public.visit_segments g on g.visit_id = v.id
              left join public.staff st on st.staff_id = g.staff_id left join public.helpers hp on hp.id = g.helper_id
              join public.shops sn on sn.shop_id = v.shop_id group by 1, 2) x), '[]'::json),
    'byProduct', (select json_agg(json_build_object('label',p.label,'proposed',c.p,'won',c.w) order by p.sort)
      from public.m_products p left join lateral (
        select count(distinct v.id) filter (where sp.proposed_at is not null) p, count(distinct v.id) filter (where sp.won_at is not null) w
          from v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id where sp.product_key = p.key) c on true),
    'actions', coalesce((select json_object_agg(a.k, a.n) from (select sa.action_key k, count(*) n from v join public.visit_segments g on g.visit_id = v.id
              join public.segment_actions sa on sa.segment_id = g.id where sa.undone_at is null group by 1) a), '{}'::json),
    'proc', (select json_build_object(
        'setupN', count(*) filter (where p.kind = 'setup'), 'setupAvg', round(avg(extract(epoch from (p.ended_at - p.started_at))/60) filter (where p.kind = 'setup')),
        'setupOver', count(*) filter (where p.kind = 'setup' and p.ended_at - p.started_at > interval '30 minutes'),
        'moveN', count(*) filter (where p.kind = 'move'), 'moveAvg', round(avg(extract(epoch from (p.ended_at - p.started_at))/60) filter (where p.kind = 'move')),
        'moveOver', count(*) filter (where p.kind = 'move' and p.ended_at - p.started_at > interval '30 minutes'))
      from v join public.visit_procedures p on p.visit_id = v.id where p.started_at is not null and p.ended_at is not null),
    'resv', (select json_build_object('total',count(*),'came',count(*) filter (where status in ('arrived','done')),
        'noshow',count(*) filter (where status = 'noshow'),'cancel',count(*) filter (where status = 'cancel'))
      from public.reservations r where r.shop_id = any(ids) and (r.reserved_at at time zone 'Asia/Tokyo')::date between p_from and p_to),
    'survey', (select json_build_object('shown',count(*),'n',count(*) filter (where answered),
        'service', case when count(*) filter (where answered) >= 5 then round(avg(q_service),1) end,
        'clarity', case when count(*) filter (where answered) >= 5 then round(avg(q_clarity),1) end,
        'returnYes', case when count(*) filter (where answered) >= 5 then round(100.0 * count(*) filter (where q_return = 'yes') / count(*) filter (where answered)) end) from sv),
    'recent', coalesce((select json_agg(r) from (
        select public.app__ms(v.started_at) as at, sn.name as shop, tb.name as tbl, t.label as type, h.age_band as age, h.purpose, v.result, v.phase,
               (select string_agg(distinct coalesce(st.display_name, hp.name), '・') from public.visit_segments g
                  left join public.staff st on st.staff_id = g.staff_id left join public.helpers hp on hp.id = g.helper_id where g.visit_id = v.id) as staff,
               (select count(distinct sp.product_key) from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id where g.visit_id = v.id and sp.proposed_at is not null) as p,
               (select count(distinct sp.product_key) from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id where g.visit_id = v.id and sp.won_at is not null) as w
          from v join public.shops sn on sn.shop_id = v.shop_id join public.tables tb on tb.id = v.table_id
          join public.m_visit_types t on t.key = v.visit_type left join public.visit_hearings h on h.visit_id = v.id
         order by v.started_at desc limit 40) r), '[]'::json)
  ) into out;
  return out;
end $$;

-- ---------- 管理画面デモ用の見本データ ----------
create function public.app__demo_fill_day(p_shop integer, p_day date) returns void
language plpgsql security definer set search_path = '' as $$
declare
  n integer := 6 + floor(random()*9)::integer + case when extract(isodow from p_day) in (6,7) then 4 else 0 end;
  i integer; j integer; np integer; mins integer; vid uuid; gid uuid; tb uuid; ty text; t0 timestamptz; sid integer; won boolean; k text; ans boolean;
  staff_ids integer[];
  types text[] := array['in_guide','in_guide','in_guide_h','in_meo','in_req','in_req','in','in','out','out','fix','event','revisit'];
  ages text[] := array['20代','30代','40代','50代','60〜64歳','65〜69歳','65〜69歳','70〜74歳','70〜74歳','75〜79歳','80〜84歳'];
  purposes text[] := array['機種変更・乗り換えの相談','料金の見直し','料金の見直し','使い方を知りたい','修理・故障','その他'];
  carriers text[] := array['ソフトバンク','ワイモバイル','ドコモ','ドコモ','au','UQモバイル','楽天モバイル'];
  prods text[] := array['carrier','carrier','net','support','support','security','used','coat','energy','water','repair'];
begin
  select array_agg(staff_id) into staff_ids from public.staff_shops where shop_id = p_shop;
  select id into tb from public.tables where shop_id = p_shop and removed_at is null order by created_at, name limit 1;
  if tb is null or staff_ids is null then return; end if;
  for i in 1..n loop
    vid := gen_random_uuid(); gid := gen_random_uuid(); won := false;
    ty := types[1 + floor(random()*array_length(types,1))::integer];
    sid := staff_ids[1 + floor(random()*array_length(staff_ids,1))::integer];
    t0 := (p_day::timestamp + interval '10 hours' + random()*interval '8 hours') at time zone 'Asia/Tokyo';
    insert into public.visits(id,shop_id,table_id,visit_type,reception_staff_id,hearing_by,phase,result,started_at,ended_at)
      values (vid, p_shop, tb, ty, sid, case when ty = 'in_guide' then 'none' when random() < 0.5 then 'customer' else 'staff' end,
              'closed', 'lost', t0, t0 + interval '20 minutes' + random()*interval '40 minutes');
    if ty <> 'in_guide' then
      insert into public.visit_hearings(visit_id,age_band,purpose,carrier,family_lines,home_net,answered_at)
        values (vid, ages[1 + floor(random()*array_length(ages,1))::integer], purposes[1 + floor(random()*array_length(purposes,1))::integer],
                carriers[1 + floor(random()*array_length(carriers,1))::integer], (array['1台','2台','2台','3台','4台以上'])[1 + floor(random()*5)::integer],
                (array['光回線がある','光回線がある','置くだけのWi-Fiがある','ない','分からない'])[1 + floor(random()*5)::integer], t0 + interval '3 minutes');
    end if;
    insert into public.visit_segments(id,visit_id,staff_id,stage,started_at) values (gid, vid, sid, 'serve', t0 + interval '5 minutes');
    np := case when ty = 'in_guide' then floor(random()*2)::integer else floor(random()*4)::integer end;
    for j in 1..np loop
      k := prods[1 + floor(random()*array_length(prods,1))::integer];
      ans := random() < 0.32;
      insert into public.segment_products(segment_id,product_key,proposed_at,won_at)
        values (gid, k, t0 + interval '10 minutes', case when ans then t0 + interval '30 minutes' end) on conflict do nothing;
      if ans and exists (select 1 from public.segment_products where segment_id = gid and product_key = k and won_at is not null) then won := true; end if;
    end loop;
    if random() < 0.25 then
      insert into public.segment_actions(segment_id,action_key,done_at)
        values (gid, (array['estimate','card','prospect'])[1 + floor(random()*3)::integer], t0 + interval '25 minutes');
    end if;
    if won then
      mins := 12 + floor(random()*38)::integer;
      insert into public.visit_procedures(visit_id,kind,started_at,ended_at) values (vid, 'setup', t0 + interval '35 minutes', t0 + make_interval(mins => 35 + mins));
      if random() < 0.6 then
        insert into public.visit_procedures(visit_id,kind,started_at,ended_at) values (vid, 'move', t0 + interval '40 minutes', t0 + make_interval(mins => 50 + floor(random()*35)::integer));
      else
        insert into public.visit_procedures(visit_id,kind,skipped) values (vid, 'move', true);
      end if;
      update public.visits set result = 'won', won_at = t0 + interval '30 minutes', ended_at = t0 + interval '100 minutes' where id = vid;
      ans := random() < 0.7;
      insert into public.surveys(id,shop_id,visit_id,answered,q_service,q_clarity,q_return,created_at)
        values (gen_random_uuid(), p_shop, vid, ans, case when ans then 3 + floor(random()*3)::integer end, case when ans then 3 + floor(random()*3)::integer end,
                case when ans then (array['yes','yes','yes','neutral','no'])[1 + floor(random()*5)::integer] end, t0 + interval '100 minutes');
    end if;
  end loop;
  for i in 1..floor(random()*3)::integer loop
    insert into public.reservations(id,shop_id,no,reserved_at,purpose,status,closed_at)
      values (gen_random_uuid(), p_shop, 'R-'||nextval('public.reservation_no_seq'),
              (p_day::timestamp + interval '11 hours' + random()*interval '6 hours') at time zone 'Asia/Tokyo',
              purposes[1 + floor(random()*array_length(purposes,1))::integer], (array['done','done','done','noshow','cancel'])[1 + floor(random()*5)::integer], now());
  end loop;
end $$;

-- 見本の店3つに、きのうまでの30日分の記録を用意する（足りない日だけを足す）
create function public.app__demo_history() returns void
language plpgsql security definer set search_path = '' as $$
declare today date := (now() at time zone 'Asia/Tokyo')::date; s integer; d date;
begin
  if not exists (select 1 from public.shops where shop_id = 9100) then
    insert into public.shops(shop_id,name,is_demo,opens_at,closes_at) values
      (9100,'見本A店（駅前）',true,'10:00','19:00'),(9200,'見本B店（モール）',true,'10:00','19:00'),(9300,'見本C店（郊外）',true,'10:00','20:00');
    insert into public.staff(staff_id,display_name,shop_id,role) values
      (9101,'佐々木',9100,'責任者'),(9102,'高田',9100,'スタッフ'),(9103,'中野',9100,'スタッフ'),(9104,'三浦',9100,'スタッフ'),
      (9201,'小川',9200,'責任者'),(9202,'藤井',9200,'スタッフ'),(9203,'岡本',9200,'スタッフ'),
      (9301,'西田',9300,'責任者'),(9302,'原',9300,'スタッフ'),(9303,'村上',9300,'スタッフ'),(9304,'平野',9300,'スタッフ');
    insert into public.staff_shops select staff_id, shop_id from public.staff where shop_id in (9100,9200,9300);
    insert into public.tables(id,shop_id,name) select gen_random_uuid(), x, '卓1' from unnest(array[9100,9200,9300]) x;
  end if;
  for s in select unnest(array[9100,9200,9300]) loop
    for d in select g::date from generate_series((today - 30)::timestamp, (today - 1)::timestamp, interval '1 day') g loop
      if not exists (select 1 from public.visits v where v.shop_id = s and (v.started_at at time zone 'Asia/Tokyo')::date = d) then
        perform public.app__demo_fill_day(s, d);
      end if;
    end loop;
  end loop;
end $$;
select public.app__demo_history();

-- ---------- 呼べる人を絞る ----------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.app_floor(uuid,text), public.app_enroll_demo(text), public.app_clock_in(uuid,text,text),
  public.app_add_helper(uuid,text,uuid,text,text,text), public.app_table(uuid,text,text,uuid),
  public.app_reservation(uuid,text,jsonb), public.app_save_visit(uuid,text,jsonb),
  public.app_survey(uuid,text,uuid,boolean,integer,integer,text), public.app_reset_demo(uuid,text),
  public.app_login(text,text,text), public.app_set_password(text,text), public.app_change_password(text,text,text),
  public.app_logout(uuid,text), public.app_report(uuid,text,date,date,integer)
  to anon;
