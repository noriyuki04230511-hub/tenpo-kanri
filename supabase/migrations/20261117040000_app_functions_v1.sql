-- 店舗管理システム 工程B：画面からの入口（関数）と見本店（2026-11-17）
-- 新しいデータベース専用。画面側は表を直接読まず、ここにある app_ で始まる関数だけを呼ぶ。
-- 関数は「登録済みの端末か」を毎回確かめ、その端末の店舗の分だけを読み書きする。

alter table public.ref_shops add column is_demo boolean not null default false;
create sequence public.reservation_no_seq start 1001;

insert into public.m_visit_types(key,label,hint,grp,is_inbound,skips_hearing,sort) values
 ('in_guide','インバウンド 操作説明','サポート会員の操作説明。ヒアリングなしで始められます','来店',true,true,1),
 ('in_meo','インバウンド MEO広告','地図の検索や広告を見て来店した、新しいお客様','来店',true,false,2),
 ('in_req','インバウンド（要件あり）','プラン変更・料金収納など、用件が決まっている来店','来店',true,false,3),
 ('in','インバウンド','上の3つに当てはまらない来店','来店',true,false,4),
 ('out','アウトバウンド','店の外での声掛けから着席','声掛け',false,false,5),
 ('fix','什器付き','什器での声掛けから着席','声掛け',false,false,6),
 ('event','イベント','イベント会場での接客','声掛け',false,false,7),
 ('revisit','見込再来店','以前に見込みだったお客様の再来店','再来店',false,false,8);
insert into public.m_products(key,label,sort) values
 ('carrier','携帯（SB／YM／UQ／ERA）',1),('net','自宅のインターネット',2),('support','店頭サポート（保証込み）',3),
 ('security','セキュリティ・広告ブロック',4),('used','中古・新古スマホ',5),('coat','コーティング・カバー',6),
 ('energy','電気・ガス',7),('water','ウォーターサーバー',8),('repair','スマホ・PC修理',9);

-- 見本店（試作用。本物の店舗・スタッフではない）
insert into public.ref_shops(shop_id,name,is_demo) values (9000,'見本店',true);
insert into public.ref_staff(staff_id,display_name,home_shop_id,role) values
 (9001,'青山',9000,'責任者'),(9002,'森',9000,'スタッフ'),(9003,'河野',9000,'スタッフ'),(9004,'石田',9000,'スタッフ');

-- ---------- 内部用（画面からは呼べない） ----------
create function public.app__shop(p_device uuid, p_secret text) returns integer
language plpgsql security definer set search_path = '' as $$
declare v integer;
begin
  select d.shop_id into v from public.devices d
   where d.id = p_device and d.revoked_at is null
     and d.secret_hash = encode(sha256(convert_to(p_secret,'UTF8')),'hex');
  if v is null then raise exception 'device_not_registered' using errcode = '28000'; end if;
  return v;
end $$;

create function public.app__ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as $$ select (extract(epoch from t)*1000)::bigint $$;

-- 端末の時刻を受け取る。12時間より前や未来の時刻は受け付けず、サーバの時刻に丸める
create function public.app__ts(p_ms text) returns timestamptz
language sql stable set search_path = '' as $$
  select case when p_ms is null then null
    else least(greatest(to_timestamp(p_ms::double precision/1000), now() - interval '12 hours'), now()) end $$;

create function public.app__visit(v public.visits) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'id', v.id, 'tid', v.table_id,
    'recv', coalesce('s'||v.reception_staff_id, 'h'||v.reception_helper_id),
    'type', v.visit_type, 'at', public.app__ms(v.started_at), 'phase', v.phase, 'by', v.hearing_by,
    'result', v.result, 'rid', v.reservation_id,
    'h', (select json_build_object('age',h.age_band,'purpose',h.purpose,'carrier',h.carrier,'lines',h.family_lines,'net',h.home_net,'extra',to_json(h.extras))
            from public.visit_hearings h where h.visit_id = v.id),
    'segs', coalesce((select json_agg(json_build_object(
              'id', g.id, 'sid', coalesce('s'||g.staff_id, 'h'||g.helper_id), 'stage', g.stage,
              'p', coalesce((select json_agg(sp.product_key) from public.segment_products sp where sp.segment_id = g.id and sp.proposed_at is not null), '[]'::json),
              'w', coalesce((select json_agg(sp.product_key) from public.segment_products sp where sp.segment_id = g.id and sp.won_at is not null), '[]'::json),
              'a', coalesce((select json_agg(case sa.action_key when 'estimate' then 'est' when 'prospect' then 'pros' else 'card' end)
                              from public.segment_actions sa where sa.segment_id = g.id and sa.undone_at is null), '[]'::json)
            ) order by g.started_at, g.id) from public.visit_segments g where g.visit_id = v.id), '[]'::json),
    'setup', coalesce((select json_strip_nulls(json_build_object('s',public.app__ms(p.started_at),'e',public.app__ms(p.ended_at)))
                         from public.visit_procedures p where p.visit_id = v.id and p.kind = 'setup'), '{}'::json),
    'move', coalesce((select json_strip_nulls(json_build_object('s',public.app__ms(p.started_at),'e',public.app__ms(p.ended_at),'none',nullif(p.skipped,false)))
                         from public.visit_procedures p where p.visit_id = v.id and p.kind = 'move'), '{}'::json),
    'survey', exists(select 1 from public.surveys sv where sv.visit_id = v.id)) $$;

-- 見本店のデータを用意する（p_force=true で最初の状態に戻す）
create function public.app__demo_seed(p_shop integer, p_force boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t0 timestamp := (now() at time zone 'Asia/Tokyo');
  d date := (now() at time zone 'Asia/Tokyo')::date;
  r record; st timestamp; fresh boolean;
begin
  if not exists (select 1 from public.ref_shops where shop_id = p_shop and is_demo) then return; end if;
  if p_force then
    delete from public.surveys where shop_id = p_shop;
    delete from public.visit_procedures where visit_id in (select id from public.visits where shop_id = p_shop);
    delete from public.segment_actions where segment_id in (select g.id from public.visit_segments g join public.visits v on v.id = g.visit_id where v.shop_id = p_shop);
    delete from public.segment_products where segment_id in (select g.id from public.visit_segments g join public.visits v on v.id = g.visit_id where v.shop_id = p_shop);
    delete from public.visit_segments where visit_id in (select id from public.visits where shop_id = p_shop);
    delete from public.visit_hearings where visit_id in (select id from public.visits where shop_id = p_shop);
    delete from public.visits where shop_id = p_shop;
    delete from public.tables where shop_id = p_shop;
    delete from public.reservations where shop_id = p_shop;
    delete from public.attendance where shop_id = p_shop;
    delete from public.helpers where shop_id = p_shop;
    delete from public.ref_shifts where shop_id = p_shop;
  end if;
  fresh := not exists (select 1 from public.tables where shop_id = p_shop);
  if not exists (select 1 from public.ref_shifts where shop_id = p_shop and shift_date = d) then
    for r in select * from (values (9001,190,true),(9002,190,true),(9003,12,false),(9004,130,true)) as x(staff_id, mins, clocked) loop
      st := t0 - make_interval(mins => r.mins);
      if st::date < d then st := d::timestamp; end if;
      insert into public.ref_shifts(shift_id,staff_id,shop_id,shift_date,start_time)
        values (to_char(d,'YYYYMMDD')::bigint*100000 + r.staff_id, r.staff_id, p_shop, d, st::time);
      if r.clocked then
        insert into public.attendance(id,shop_id,work_date,staff_id,shift_id,clocked_in_at)
          values (gen_random_uuid(), p_shop, d, r.staff_id, to_char(d,'YYYYMMDD')::bigint*100000 + r.staff_id, (st at time zone 'Asia/Tokyo') - interval '3 minutes');
      end if;
    end loop;
  end if;
  if not exists (select 1 from public.tables where shop_id = p_shop and removed_at is null) then
    insert into public.tables(id,shop_id,name) values (gen_random_uuid(),p_shop,'卓1'),(gen_random_uuid(),p_shop,'卓2'),(gen_random_uuid(),p_shop,'卓3');
  end if;
  if fresh then
    insert into public.reservations(id,shop_id,no,reserved_at,purpose,staff_id) values
      (gen_random_uuid(), p_shop, 'R-'||nextval('public.reservation_no_seq'), date_trunc('minute', now()) + interval '25 minutes', '機種変更・乗り換えの相談', 9002),
      (gen_random_uuid(), p_shop, 'R-'||nextval('public.reservation_no_seq'), date_trunc('minute', now()) + interval '95 minutes', '使い方を知りたい', null);
  end if;
end $$;

-- ---------- 画面から呼ぶ入口 ----------
-- 店舗のいまの状態をまとめて返す。予約の15分前になっていれば、ここで卓を1つ用意する
create function public.app_floor(p_device uuid, p_secret text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  s integer := public.app__shop(p_device, p_secret);
  d date := (now() at time zone 'Asia/Tokyo')::date;
  r record; n integer; cnt integer; av numeric;
begin
  perform public.app__demo_seed(s, false);
  for r in select id from public.reservations
            where shop_id = s and status = 'booked'
              and now() >= reserved_at - interval '15 minutes' and reserved_at > now() - interval '12 hours'
            for update skip locked loop
    select coalesce(max(nullif(regexp_replace(name,'\D','','g'),'')::integer),0)+1 into n
      from public.tables where shop_id = s and removed_at is null;
    insert into public.tables(id,shop_id,name,is_auto,reservation_id) values (gen_random_uuid(), s, '卓'||n, true, r.id);
    update public.reservations set status = 'seated', seated_at = now() where id = r.id;
  end loop;
  select count(*), round(avg((q_service + q_clarity)/2.0),1) into cnt, av from public.surveys
   where shop_id = s and answered and date_trunc('month', created_at at time zone 'Asia/Tokyo') = date_trunc('month', d::timestamp);
  return json_build_object(
    'now', public.app__ms(now()),
    'shop', (select json_build_object('id',shop_id,'name',name,'demo',is_demo) from public.ref_shops where shop_id = s),
    'staff', coalesce((select json_agg(json_build_object('id',x.id,'name',x.name,'kind',x.kind,'shift',x.shift,'inAt',x.in_at) order by x.ord)
      from (
        select 's'||st.staff_id as id, st.display_name as name, coalesce(st.role,'スタッフ') as kind,
               public.app__ms((sh.shift_date + sh.start_time) at time zone 'Asia/Tokyo') as shift,
               (select public.app__ms(a.clocked_in_at) from public.attendance a where a.shop_id = s and a.work_date = d and a.staff_id = st.staff_id) as in_at,
               lpad(st.staff_id::text, 12, '0') as ord
          from public.ref_shifts sh join public.ref_staff st on st.staff_id = sh.staff_id
         where sh.shop_id = s and sh.shift_date = d and sh.start_time is not null
        union all
        select 'h'||h.id, h.name,
               (case h.kind when 'event' then 'イベント応援' when 'outsource' then '業務委託' else 'キャリアのヘルパー' end) || coalesce('・'||nullif(h.company_other,''),''),
               public.app__ms(h.created_at),
               (select public.app__ms(a.clocked_in_at) from public.attendance a where a.helper_id = h.id),
               'z'||h.created_at::text
          from public.helpers h where h.shop_id = s and h.work_date = d
      ) x), '[]'::json),
    'tables', coalesce((select json_agg(json_build_object('id',t.id,'name',t.name,'auto',t.is_auto,'rid',t.reservation_id,
        'v',(select public.app__visit(v) from public.visits v where v.table_id = t.id and v.ended_at is null order by v.started_at desc limit 1))
        order by t.created_at, length(t.name), t.name)
      from public.tables t where t.shop_id = s and t.removed_at is null), '[]'::json),
    'closed', coalesce((select json_agg(json_build_object('type',v.visit_type,'result',v.result,'segs',public.app__visit(v)->'segs') order by v.started_at)
      from public.visits v where v.shop_id = s and v.ended_at is not null and (v.started_at at time zone 'Asia/Tokyo')::date = d), '[]'::json),
    'resv', coalesce((select json_agg(json_build_object('id',rv.id,'no',rv.no,'at',public.app__ms(rv.reserved_at),'purpose',rv.purpose,
        'staff','s'||rv.staff_id,'st',rv.status,
        'tid',(select t.id from public.tables t where t.reservation_id = rv.id and t.removed_at is null limit 1)) order by rv.reserved_at)
      from public.reservations rv where rv.shop_id = s and (rv.reserved_at at time zone 'Asia/Tokyo')::date >= d), '[]'::json),
    'feed', coalesce((select json_agg(json_build_object('at',f.at,'text',f.text) order by f.at desc) from (
        select public.app__ms(h.answered_at) as at, t.name||'　'||h.age_band||'　ご用件：'||coalesce(h.purpose,'未記入') as text
          from public.visit_hearings h join public.visits v on v.id = h.visit_id join public.tables t on t.id = v.table_id
         where v.shop_id = s and (v.started_at at time zone 'Asia/Tokyo')::date = d
         order by h.answered_at desc limit 20) f), '[]'::json),
    'surveys', cnt,
    'surveyAvg', case when cnt >= 5 then av end);
end $$;

-- 見本店に端末を登録する（試作用。本物の店舗への登録は工程Cで責任者のログインを必須にする）
create function public.app_enroll_demo(p_label text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer; did uuid := gen_random_uuid(); sec text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  select shop_id into s from public.ref_shops where is_demo order by shop_id limit 1;
  if s is null then raise exception 'demo_shop_not_found'; end if;
  insert into public.devices(id,shop_id,label,secret_hash) values (did, s, left(coalesce(nullif(p_label,''),'試作用の端末'),60), encode(sha256(convert_to(sec,'UTF8')),'hex'));
  insert into public.events(shop_id,device_id,action,target_table,target_id) values (s, did, 'device.enroll_demo', 'devices', did::text);
  return json_build_object('device', did, 'secret', sec);
end $$;

create function public.app_clock_in(p_device uuid, p_secret text, p_actor text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date; sid integer;
begin
  if p_actor like 's%' then
    sid := substr(p_actor,2)::integer;
    insert into public.attendance(id,shop_id,work_date,staff_id,shift_id,device_id)
      values (gen_random_uuid(), s, d, sid, (select shift_id from public.ref_shifts where shop_id = s and shift_date = d and staff_id = sid limit 1), p_device)
      on conflict (shop_id, work_date, staff_id) where staff_id is not null do nothing;
    insert into public.events(shop_id,device_id,actor_staff_id,action,target_table,target_id) values (s, p_device, sid, 'attendance.clock_in', 'attendance', p_actor);
  end if;
  return public.app_floor(p_device, p_secret);
end $$;

create function public.app_add_helper(p_device uuid, p_secret text, p_id uuid, p_kind text, p_company text, p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  insert into public.helpers(id,shop_id,work_date,kind,company_other,name,device_id)
    values (p_id, s, d, p_kind, left(p_company,60), left(p_name,40), p_device) on conflict (id) do nothing;
  if exists (select 1 from public.helpers where id = p_id and shop_id = s) then
    insert into public.attendance(id,shop_id,work_date,helper_id,device_id) values (gen_random_uuid(), s, d, p_id, p_device)
      on conflict (helper_id) where helper_id is not null do nothing;
    insert into public.events(shop_id,device_id,action,target_table,target_id) values (s, p_device, 'helper.add', 'helpers', p_id::text);
  end if;
  return public.app_floor(p_device, p_secret);
end $$;

create function public.app_table(p_device uuid, p_secret text, p_op text, p_id uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret); n integer;
begin
  if p_op = 'add' then
    select coalesce(max(nullif(regexp_replace(name,'\D','','g'),'')::integer),0)+1 into n from public.tables where shop_id = s and removed_at is null;
    insert into public.tables(id,shop_id,name) values (p_id, s, '卓'||n) on conflict (id) do nothing;
  elsif p_op = 'remove' then
    update public.tables t set removed_at = now()
     where t.id = p_id and t.shop_id = s and not t.is_auto and t.removed_at is null
       and not exists (select 1 from public.visits v where v.table_id = t.id and v.ended_at is null);
  end if;
  insert into public.events(shop_id,device_id,action,target_table,target_id) values (s, p_device, 'table.'||p_op, 'tables', p_id::text);
  return public.app_floor(p_device, p_secret);
end $$;

create function public.app_reservation(p_device uuid, p_secret text, p_resv jsonb) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret); rid uuid := (p_resv->>'id')::uuid; ex public.reservations; st text := p_resv->>'st';
begin
  select * into ex from public.reservations where id = rid;
  if not found then
    insert into public.reservations(id,shop_id,no,reserved_at,purpose,staff_id,device_id)
      values (rid, s, 'R-'||nextval('public.reservation_no_seq'), to_timestamp((p_resv->>'at')::double precision/1000), left(p_resv->>'purpose',60),
              case when p_resv->>'staff' like 's%' then substr(p_resv->>'staff',2)::integer end, p_device);
  elsif ex.shop_id <> s then
    raise exception 'forbidden' using errcode = '42501';
  elsif st in ('cancel','noshow') and ex.status in ('booked','seated') then
    update public.reservations set status = st, closed_at = now() where id = rid;
    update public.tables t set removed_at = now()
     where t.reservation_id = rid and t.is_auto and t.removed_at is null
       and not exists (select 1 from public.visits v where v.table_id = t.id and v.ended_at is null);
  end if;
  insert into public.events(shop_id,device_id,action,target_table,target_id,after) values (s, p_device, 'reservation.'||coalesce(st,'save'), 'reservations', rid::text, p_resv);
  return public.app_floor(p_device, p_secret);
end $$;

-- 1組の接客の「いまの姿」を丸ごと受け取り、保存する。同じ内容を何度送っても結果は同じ（通信が切れたあとの再送に使う）
create function public.app_save_visit(p_device uuid, p_secret text, p_visit jsonb) returns json
language plpgsql security definer set search_path = '' as $$
declare
  s integer := public.app__shop(p_device, p_secret);
  vid uuid := (p_visit->>'id')::uuid;
  ex public.visits; tb public.tables; seg jsonb; gid uuid; k text;
  recv text := p_visit->>'recv'; h jsonb := p_visit->'h';
  closed boolean := coalesce((p_visit->>'closed')::boolean, false);
begin
  select * into ex from public.visits where id = vid;
  if ex.id is not null and ex.shop_id <> s then raise exception 'forbidden' using errcode = '42501'; end if;
  -- 「1つ前に戻る」で受付そのものを取り消したとき。記録は消すが、取り消した事実と中身は操作の履歴に残す
  if coalesce((p_visit->>'void')::boolean, false) then
    if ex.id is not null and ex.ended_at is null then
      delete from public.visit_procedures where visit_id = vid;
      delete from public.segment_actions where segment_id in (select id from public.visit_segments where visit_id = vid);
      delete from public.segment_products where segment_id in (select id from public.visit_segments where visit_id = vid);
      delete from public.visit_segments where visit_id = vid;
      delete from public.visit_hearings where visit_id = vid;
      delete from public.surveys where visit_id = vid;
      delete from public.visits where id = vid;
      update public.reservations set status = 'seated', arrived_at = null where id = ex.reservation_id and status = 'arrived';
      insert into public.events(shop_id,device_id,action,target_table,target_id,before,reason)
        values (s, p_device, 'visit.void', 'visits', vid::text, to_jsonb(ex), '1つ前に戻る');
    end if;
    return public.app_floor(p_device, p_secret);
  end if;
  if ex.id is not null then
    if ex.ended_at is not null then return public.app_floor(p_device, p_secret); end if;
  else
    select * into tb from public.tables where id = (p_visit->>'tid')::uuid and shop_id = s and removed_at is null;
    if not found then raise exception 'table_not_found' using errcode = '42501'; end if;
    insert into public.visits(id,shop_id,table_id,visit_type,reception_staff_id,reception_helper_id,started_at,reservation_id,device_id)
      values (vid, s, tb.id, p_visit->>'type',
              case when recv like 's%' then substr(recv,2)::integer end, case when recv like 'h%' then substr(recv,2)::uuid end,
              coalesce(public.app__ts(p_visit->>'at'), now()), tb.reservation_id, p_device);
    update public.reservations set status = 'arrived', arrived_at = now() where id = tb.reservation_id and status in ('booked','seated');
  end if;

  update public.visits set
      hearing_by = coalesce(p_visit->>'by', hearing_by),
      phase = case when closed then 'closed' else coalesce(p_visit->>'phase', phase) end,
      result = coalesce(p_visit->>'result', result),
      won_at = case when p_visit->>'result' = 'won' then coalesce(won_at, now()) else won_at end,
      ended_at = case when closed then now() end
   where id = vid;

  if h is not null and jsonb_typeof(h) = 'object' and h->>'age' is not null then
    insert into public.visit_hearings(visit_id,age_band,purpose,carrier,family_lines,home_net,extras)
      values (vid, h->>'age', h->>'purpose', h->>'carrier', h->>'lines', h->>'net',
              array(select jsonb_array_elements_text(case when jsonb_typeof(h->'extra') = 'array' then h->'extra' else '[]'::jsonb end)))
      on conflict (visit_id) do update set age_band = excluded.age_band, purpose = excluded.purpose, carrier = excluded.carrier,
              family_lines = excluded.family_lines, home_net = excluded.home_net, extras = excluded.extras;
  end if;

  for seg in select * from jsonb_array_elements(case when jsonb_typeof(p_visit->'segs') = 'array' then p_visit->'segs' else '[]'::jsonb end) loop
    gid := (seg->>'id')::uuid;
    insert into public.visit_segments(id,visit_id,staff_id,helper_id,stage,started_at)
      values (gid, vid, case when seg->>'sid' like 's%' then substr(seg->>'sid',2)::integer end,
              case when seg->>'sid' like 'h%' then substr(seg->>'sid',2)::uuid end, coalesce(seg->>'stage','serve'), clock_timestamp())
      on conflict (id) do nothing;
    if not exists (select 1 from public.visit_segments where id = gid and visit_id = vid) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    insert into public.segment_products(segment_id,product_key,proposed_at,won_at)
      select gid, q.key,
             case when q.key in (select jsonb_array_elements_text(coalesce(seg->'p','[]'::jsonb))) then now() end,
             case when q.key in (select jsonb_array_elements_text(coalesce(seg->'w','[]'::jsonb))) then now() end
        from (select distinct jsonb_array_elements_text(coalesce(seg->'p','[]'::jsonb) || coalesce(seg->'w','[]'::jsonb)) as key) q
      on conflict (segment_id, product_key) do update set
        proposed_at = case when excluded.proposed_at is null then null else coalesce(public.segment_products.proposed_at, excluded.proposed_at) end,
        won_at = case when excluded.won_at is null then null else coalesce(public.segment_products.won_at, excluded.won_at) end;
    delete from public.segment_products sp where sp.segment_id = gid
       and sp.product_key not in (select jsonb_array_elements_text(coalesce(seg->'p','[]'::jsonb) || coalesce(seg->'w','[]'::jsonb)));
    insert into public.segment_actions(segment_id,action_key)
      select gid, case a when 'est' then 'estimate' when 'pros' then 'prospect' else 'card' end
        from jsonb_array_elements_text(coalesce(seg->'a','[]'::jsonb)) a
      on conflict (segment_id, action_key) do update set undone_at = null;
    update public.segment_actions sa set undone_at = now() where sa.segment_id = gid and sa.undone_at is null
       and sa.action_key not in (select case a when 'est' then 'estimate' when 'pros' then 'prospect' else 'card' end
                                   from jsonb_array_elements_text(coalesce(seg->'a','[]'::jsonb)) a);
  end loop;
  -- 「1つ前に戻る」で担当の選択を取り消したとき：送られてきた内容に無い担当の区間は消す
  if jsonb_typeof(p_visit->'segs') = 'array' then
    delete from public.segment_actions where segment_id in (select g.id from public.visit_segments g where g.visit_id = vid
        and g.id::text not in (select e->>'id' from jsonb_array_elements(p_visit->'segs') e));
    delete from public.segment_products where segment_id in (select g.id from public.visit_segments g where g.visit_id = vid
        and g.id::text not in (select e->>'id' from jsonb_array_elements(p_visit->'segs') e));
    delete from public.visit_segments g where g.visit_id = vid
        and g.id::text not in (select e->>'id' from jsonb_array_elements(p_visit->'segs') e);
  end if;

  foreach k in array array['setup','move'] loop
    if jsonb_typeof(p_visit->k) = 'object' and p_visit->k <> '{}'::jsonb then
      insert into public.visit_procedures(visit_id,kind,started_at,ended_at,skipped)
        values (vid, k, public.app__ts(p_visit->k->>'s'), public.app__ts(p_visit->k->>'e'), coalesce((p_visit->k->>'none')::boolean, false))
        on conflict (visit_id, kind) do update set
          started_at = coalesce(public.visit_procedures.started_at, excluded.started_at),
          ended_at = coalesce(public.visit_procedures.ended_at, excluded.ended_at),
          skipped = excluded.skipped;
    end if;
  end loop;

  if closed then
    update public.tables t set removed_at = now() where t.id = (select table_id from public.visits where id = vid) and t.is_auto;
    update public.reservations set status = 'done', closed_at = now()
     where id = (select reservation_id from public.visits where id = vid) and status = 'arrived';
  end if;
  insert into public.events(shop_id,device_id,action,target_table,target_id,after)
    values (s, p_device, case when closed then 'visit.close' else 'visit.save' end, 'visits', vid::text, p_visit);
  return public.app_floor(p_device, p_secret);
end $$;

-- アンケート。回答の中身は、どの画面にも返さない（返すのは月の件数と、5件以上のときの平均だけ）
create function public.app_survey(p_device uuid, p_secret text, p_visit uuid, p_answered boolean, p_service integer, p_clarity integer, p_return text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret);
begin
  if not exists (select 1 from public.visits where id = p_visit and shop_id = s) then raise exception 'forbidden' using errcode = '42501'; end if;
  insert into public.surveys(id,shop_id,visit_id,answered,q_service,q_clarity,q_return)
    values (gen_random_uuid(), s, p_visit, p_answered,
            case when p_answered then p_service end, case when p_answered then p_clarity end, case when p_answered then p_return end)
    on conflict (visit_id) do nothing;
  insert into public.events(shop_id,device_id,action,target_table,target_id) values (s, p_device, 'survey.'||case when p_answered then 'answered' else 'skipped' end, 'surveys', p_visit::text);
  return public.app_floor(p_device, p_secret);
end $$;

create function public.app_reset_demo(p_device uuid, p_secret text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret);
begin
  if not exists (select 1 from public.ref_shops where shop_id = s and is_demo) then raise exception 'forbidden' using errcode = '42501'; end if;
  perform public.app__demo_seed(s, true);
  insert into public.events(shop_id,device_id,action,target_table,target_id) values (s, p_device, 'demo.reset', 'ref_shops', s::text);
  return public.app_floor(p_device, p_secret);
end $$;

-- 呼べる人を絞る：内部用は誰にも公開しない。入口は画面側（anon）にだけ公開する
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.app_floor(uuid,text), public.app_enroll_demo(text), public.app_clock_in(uuid,text,text),
  public.app_add_helper(uuid,text,uuid,text,text,text), public.app_table(uuid,text,text,uuid),
  public.app_reservation(uuid,text,jsonb), public.app_save_visit(uuid,text,jsonb),
  public.app_survey(uuid,text,uuid,boolean,integer,integer,text), public.app_reset_demo(uuid,text)
  to anon;
