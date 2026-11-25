-- 2026-11-25 代表の追加依頼。
--  1) 退勤のときに、スタッフごとに「本日の数字」5項目を入力する。
--     アウトバウンド声かけ母数／アウトバウンド立ち止まり数／什器付き声かけ母数／什器付き立ち話数／名刺お渡し数。
--     出勤の記録（attendance＝人×店舗×日）に持たせ、店舗別・スタッフ別に集計できるようにする。
--  2) 退勤のときに、その人の本日の数字（接客・成約・提案・獲得と、上の5項目）を1通の文にして、
--     Slack送信待ちの表（slack_outbox）に積む。実際の送信は、送信先の承認と設定のあとに足す。
--     文にお客様の情報は入れない。
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- 1) 本日の数字
alter table public.attendance
  add column out_call integer check (out_call between 0 and 9999),
  add column out_stop integer check (out_stop between 0 and 9999),
  add column fix_call integer check (fix_call between 0 and 9999),
  add column fix_talk integer check (fix_talk between 0 and 9999),
  add column cards    integer check (cards between 0 and 9999),
  add column counts_at timestamptz,
  add constraint attendance_counts_all_or_none check (
    (counts_at is null and out_call is null and out_stop is null and fix_call is null and fix_talk is null and cards is null)
    or (counts_at is not null and out_call is not null and out_stop is not null and fix_call is not null and fix_talk is not null and cards is not null
        and out_stop <= out_call and fix_talk <= fix_call));
create index attendance_shop_date_idx on public.attendance(shop_id, work_date);

-- 2) Slack送信待ち
create table public.slack_outbox (
  id bigint generated always as identity primary key,
  shop_id integer not null references public.shops(shop_id),
  kind text not null check (kind in ('day_close','day_close_undo')),
  work_date date not null,
  actor text not null,
  body text not null,
  status text not null default 'pending' check (status in ('pending','sent','failed','skipped')),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);
create index slack_outbox_pending_idx on public.slack_outbox(created_at) where status = 'pending';
alter table public.slack_outbox enable row level security;
revoke all on table public.slack_outbox from public, anon, authenticated;

-- その人の本日の数字を、Slackに送る1通の文にする（お客様の情報は入れない）
create function public.app__day_text(p_att uuid, p_redo boolean) returns text
language plpgsql security definer set search_path to '' as $$
declare a public.attendance; nm text; shop text; n integer; w integer; r integer; ro integer; rf integer; won text; prop text; act text; t text;
begin
  select * into a from public.attendance where id = p_att;
  if a.id is null then return null; end if;
  select coalesce((select st.display_name from public.staff st where st.staff_id = a.staff_id),
                  (select hp.name from public.helpers hp where hp.id = a.helper_id)) into nm;
  select sh.name into shop from public.shops sh where sh.shop_id = a.shop_id;
  -- 接客した組（担当として記録が1つでもある組）と、そのうち成約した組
  select count(*), count(*) filter (where v.result = 'won') into n, w
    from public.visits v
   where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date
     and exists (select 1 from public.visit_segments g where g.visit_id = v.id
                  and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id)));
  -- 受付した組
  select count(*), count(*) filter (where v.visit_type = 'out'), count(*) filter (where v.visit_type = 'fix') into r, ro, rf
    from public.visits v
   where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date
     and ((a.staff_id is not null and v.reception_staff_id = a.staff_id) or (a.helper_id is not null and v.reception_helper_id = a.helper_id));
  -- 商材ごとの提案・獲得（組で数える。件数は別に出す）
  select string_agg(x.lb || ' ' || x.wn || '組' || case when x.q > x.wn then '（' || x.q || '件）' else '' end, '、' order by x.sort) filter (where x.wn > 0),
         string_agg(x.lb || ' ' || x.pn || '組', '、' order by x.sort) filter (where x.pn > 0)
    into won, prop
    from (select coalesce(p.short, p.label) lb, p.sort,
                 count(distinct g.visit_id) filter (where sp.proposed_at is not null) pn,
                 count(distinct g.visit_id) filter (where sp.won_at is not null) wn,
                 coalesce(sum(sp.qty) filter (where sp.won_at is not null), 0) q
            from public.visits v join public.visit_segments g on g.visit_id = v.id
            join public.segment_products sp on sp.segment_id = g.id join public.m_products p on p.key = sp.product_key
           where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date
             and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id))
           group by 1, 2) x;
  select '見積書 ' || count(*) filter (where sa.action_key = 'estimate') || '・名刺 ' || count(*) filter (where sa.action_key = 'card')
         || '・見込み登録 ' || count(*) filter (where sa.action_key = 'prospect') into act
    from public.visits v join public.visit_segments g on g.visit_id = v.id join public.segment_actions sa on sa.segment_id = g.id
   where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date and sa.undone_at is null
     and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id));
  t := '【退勤' || case when p_redo then '・入れ直し' else '' end || '】' || shop || '　' || nm || 'さん　'
       || to_char(a.work_date, 'FMMM/FMDD') || '（' || (array['日','月','火','水','木','金','土'])[extract(dow from a.work_date)::integer + 1] || '）' || E'\n'
       || '接客 ' || n || '組／成約 ' || w || '組' || case when n > 0 then '（' || round(100.0 * w / n, 1) || '%）' else '' end || E'\n'
       || '受付 ' || r || '組（うちアウトバウンド ' || ro || '組・什器付き ' || rf || '組）' || E'\n'
       || '獲得：' || coalesce(won, 'なし') || E'\n'
       || '提案：' || coalesce(prop, 'なし') || E'\n'
       || '卓での記録：' || act;
  if a.counts_at is not null then
    t := t || E'\n'
       || 'アウトバウンド：声かけ ' || a.out_call || ' → 立ち止まり ' || a.out_stop
       || case when a.out_call > 0 then '（' || round(100.0 * a.out_stop / a.out_call, 1) || '%）' else '' end || E'\n'
       || '什器付き：声かけ ' || a.fix_call || ' → 立ち話 ' || a.fix_talk
       || case when a.fix_call > 0 then '（' || round(100.0 * a.fix_talk / a.fix_call, 1) || '%）' else '' end || E'\n'
       || '名刺お渡し：' || a.cards || '枚';
  end if;
  return t;
end $$;
revoke execute on function public.app__day_text(uuid, boolean) from public, anon, authenticated;

-- 退勤（本日の数字つき）。退勤済みで数字が未入力の人は、数字だけを入れられる
create function public.app_day_close(p_device uuid, p_secret text, p_actor text, p_counts jsonb) returns json
language plpgsql security definer set search_path to '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date;
  a public.attendance; sid integer; hid uuid; oc integer; os integer; fc integer; ft integer; cd integer; redo boolean;
begin
  if p_actor ~ '^s[0-9]{1,9}$' then
    sid := substr(p_actor, 2)::integer;
    select * into a from public.attendance where shop_id = s and work_date = d and staff_id = sid;
  elsif p_actor ~ '^h[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    hid := substr(p_actor, 2)::uuid;
    select x.* into a from public.attendance x join public.helpers h on h.id = x.helper_id where x.helper_id = hid and h.shop_id = s;
  else
    return json_build_object('error', 'bad_request');
  end if;
  if a.id is null then return json_build_object('error', 'not_found'); end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'object'
     or coalesce(p_counts->>'oc','') !~ '^[0-9]{1,4}$' or coalesce(p_counts->>'os','') !~ '^[0-9]{1,4}$'
     or coalesce(p_counts->>'fc','') !~ '^[0-9]{1,4}$' or coalesce(p_counts->>'ft','') !~ '^[0-9]{1,4}$'
     or coalesce(p_counts->>'cd','') !~ '^[0-9]{1,4}$' then
    return json_build_object('error', 'bad_counts');
  end if;
  oc := (p_counts->>'oc')::integer; os := (p_counts->>'os')::integer; fc := (p_counts->>'fc')::integer;
  ft := (p_counts->>'ft')::integer; cd := (p_counts->>'cd')::integer;
  if os > oc or ft > fc then return json_build_object('error', 'bad_counts'); end if;
  if a.clocked_out_at is null and exists (select 1 from public.visits v where v.shop_id = s and v.ended_at is null and (
        (not exists (select 1 from public.visit_segments g where g.visit_id = v.id) and (v.reception_staff_id = sid or v.reception_helper_id = hid))
        or exists (select 1 from (select g.staff_id, g.helper_id from public.visit_segments g where g.visit_id = v.id order by g.started_at desc, g.id desc limit 1) l
                    where l.staff_id = sid or l.helper_id = hid))) then
    return json_build_object('error', 'serving');
  end if;
  redo := a.counts_at is not null;
  update public.attendance set clocked_out_at = coalesce(clocked_out_at, now()),
         out_call = oc, out_stop = os, fix_call = fc, fix_talk = ft, cards = cd, counts_at = now() where id = a.id;
  insert into public.events(shop_id,device_id,actor_staff_id,actor_helper_id,action,target_table,target_id,before,after)
    values (s, p_device, sid, hid, 'attendance.day_close', 'attendance', p_actor,
            case when redo then jsonb_build_object('oc',a.out_call,'os',a.out_stop,'fc',a.fix_call,'ft',a.fix_talk,'cd',a.cards) end,
            jsonb_build_object('oc',oc,'os',os,'fc',fc,'ft',ft,'cd',cd));
  insert into public.slack_outbox(shop_id,kind,work_date,actor,body,status)
    values (s, 'day_close', a.work_date, p_actor, public.app__day_text(a.id, redo),
            case when (select sh.is_demo from public.shops sh where sh.shop_id = s) then 'skipped' else 'pending' end);
  return public.app_floor(p_device, p_secret);
end $$;
revoke execute on function public.app_day_close(uuid,text,text,jsonb) from public, authenticated;
grant execute on function public.app_day_close(uuid,text,text,jsonb) to anon;

-- 退勤の取り消し：本日の数字も一緒に取り消し、Slack送信待ちに「取り消し」を積む
select pg_temp.patch('public.app_undo(uuid,text,text,text)',
  'update public.attendance set clocked_out_at = null where id = a.id;',
  'update public.attendance set clocked_out_at = null, out_call = null, out_stop = null, fix_call = null, fix_talk = null, cards = null, counts_at = null where id = a.id;
    if a.counts_at is not null then
      insert into public.slack_outbox(shop_id,kind,work_date,actor,body,status)
        select s, ''day_close_undo'', a.work_date, p_id,
               ''【退勤の取り消し】'' || sh.name || ''　'' || coalesce((select st.display_name from public.staff st where st.staff_id = a.staff_id), (select hp.name from public.helpers hp where hp.id = a.helper_id))
               || ''さん　'' || to_char(a.work_date, ''FMMM/FMDD'') || E''\n先ほどの「本日の数字」は取り消されました。退勤のときに入れ直されます。'',
               case when sh.is_demo then ''skipped'' else ''pending'' end
          from public.shops sh where sh.shop_id = s;
    end if;');

-- フロア：数字が入力済みかどうかだけを返す（数字そのものは卓の画面に返さない）
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'''inAt'',x.in_at,''outAt'',x.out_at) order by x.ord)',
  E'''inAt'',x.in_at,''outAt'',x.out_at,''cnt'',x.cnt) order by x.ord)');
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'               lpad(st.sort::text, 6, ''0'') || lpad(st.staff_id::text, 12, ''0'') as ord\n',
  E'               lpad(st.sort::text, 6, ''0'') || lpad(st.staff_id::text, 12, ''0'') as ord,
               exists (select 1 from public.attendance a where a.shop_id = s and a.work_date = d and a.staff_id = st.staff_id and a.counts_at is not null) as cnt\n');
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'               ''z''||h.created_at::text\n',
  E'               ''z''||h.created_at::text,
               exists (select 1 from public.attendance a where a.helper_id = h.id and a.counts_at is not null)\n');

-- 管理画面：声かけの活動（退勤時の入力）の集計。入力の対象は、この機能を入れた 2026-11-25 以降の出勤（見本店は全期間）
create function public.app__act_report(p_ids integer[], p_from date, p_to date) returns json
language sql stable security definer set search_path to '' as $$
  with td as (select (now() at time zone 'Asia/Tokyo')::date as today),
  at as (
    select a.shop_id, a.work_date, coalesce('s'||a.staff_id, 'h'||a.helper_id) as person,
           coalesce(st.display_name, hp.name) as name, a.clocked_out_at, a.counts_at,
           a.out_call, a.out_stop, a.fix_call, a.fix_talk, a.cards,
           ((sx.is_demo or a.work_date >= date '2026-11-25') and (a.work_date < td.today or a.clocked_out_at is not null)) as due
      from public.attendance a cross join td join public.shops sx on sx.shop_id = a.shop_id
      left join public.staff st on st.staff_id = a.staff_id left join public.helpers hp on hp.id = a.helper_id
     where a.shop_id = any(p_ids) and a.work_date between p_from and p_to),
  v as (
    select v.shop_id, v.visit_type, v.result, coalesce('s'||v.reception_staff_id, 'h'||v.reception_helper_id) as person
      from public.visits v
     where v.shop_id = any(p_ids) and (v.started_at at time zone 'Asia/Tokyo')::date between p_from and p_to and v.visit_type in ('out','fix')),
  sa as (select shop_id, count(*) filter (where due) due, count(counts_at) ent, coalesce(sum(out_call),0) oc, coalesce(sum(out_stop),0) os,
                coalesce(sum(fix_call),0) fc, coalesce(sum(fix_talk),0) ft, coalesce(sum(cards),0) cd from at group by 1),
  sv as (select shop_id, count(*) filter (where visit_type = 'out') ov, count(*) filter (where visit_type = 'out' and result = 'won') ow,
                count(*) filter (where visit_type = 'fix') fv, count(*) filter (where visit_type = 'fix' and result = 'won') fw from v group by 1),
  pa as (select at.person, max(at.name) as name, string_agg(distinct sn.name, '・') as shop, count(*) filter (where at.due) due, count(at.counts_at) ent,
                coalesce(sum(out_call),0) oc, coalesce(sum(out_stop),0) os, coalesce(sum(fix_call),0) fc, coalesce(sum(fix_talk),0) ft, coalesce(sum(cards),0) cd
           from at join public.shops sn on sn.shop_id = at.shop_id group by 1),
  pv as (select person, count(*) filter (where visit_type = 'out') ov, count(*) filter (where visit_type = 'out' and result = 'won') ow,
                count(*) filter (where visit_type = 'fix') fv, count(*) filter (where visit_type = 'fix' and result = 'won') fw from v group by 1)
  select json_build_object(
    'all', (select json_build_object('name','全体','due',coalesce(sum(a.due),0),'ent',coalesce(sum(a.ent),0),'oc',coalesce(sum(a.oc),0),'os',coalesce(sum(a.os),0),
                     'fc',coalesce(sum(a.fc),0),'ft',coalesce(sum(a.ft),0),'cd',coalesce(sum(a.cd),0),
                     'ov',(select count(*) filter (where visit_type = 'out') from v),'ow',(select count(*) filter (where visit_type = 'out' and result = 'won') from v),
                     'fv',(select count(*) filter (where visit_type = 'fix') from v),'fw',(select count(*) filter (where visit_type = 'fix' and result = 'won') from v)) from sa a),
    'shops', coalesce((select json_agg(json_build_object('name',sh.name,'sub',coalesce(sh.area,''),'due',coalesce(a.due,0),'ent',coalesce(a.ent,0),'oc',coalesce(a.oc,0),'os',coalesce(a.os,0),
                     'fc',coalesce(a.fc,0),'ft',coalesce(a.ft,0),'cd',coalesce(a.cd,0),'ov',coalesce(b.ov,0),'ow',coalesce(b.ow,0),'fv',coalesce(b.fv,0),'fw',coalesce(b.fw,0)) order by sh.shop_id)
               from public.shops sh left join sa a on a.shop_id = sh.shop_id left join sv b on b.shop_id = sh.shop_id
              where sh.shop_id = any(p_ids) and (a.shop_id is not null or b.shop_id is not null)), '[]'::json),
    'staff', coalesce((select json_agg(json_build_object('name',a.name,'sub',a.shop,'due',a.due,'ent',a.ent,'oc',a.oc,'os',a.os,'fc',a.fc,'ft',a.ft,'cd',a.cd,
                     'ov',coalesce(b.ov,0),'ow',coalesce(b.ow,0),'fv',coalesce(b.fv,0),'fw',coalesce(b.fw,0)) order by a.oc + a.fc desc, a.name)
               from pa a left join pv b on b.person = a.person where a.due > 0 or a.ent > 0), '[]'::json),
    'missN', (select count(*) from at where due and counts_at is null),
    'miss', coalesce((select json_agg(json_build_object('day',m.work_date,'shop',m.shop,'name',m.name) order by m.work_date desc, m.shop, m.name)
               from (select at.work_date, sn.name as shop, at.name from at join public.shops sn on sn.shop_id = at.shop_id
                      where at.due and at.counts_at is null order by at.work_date desc, sn.name, at.name limit 30) m), '[]'::json),
    'outbox', coalesce((select json_agg(json_build_object('at',public.app__ms(o.created_at),'shop',o.shop,'status',o.status,'body',o.body) order by o.created_at desc)
               from (select so.created_at, sn.name as shop, so.status, so.body from public.slack_outbox so join public.shops sn on sn.shop_id = so.shop_id
                      where so.shop_id = any(p_ids) and so.work_date between p_from and p_to order by so.created_at desc limit 8) o), '[]'::json),
    'outboxPending', (select count(*) from public.slack_outbox so where so.shop_id = any(p_ids) and so.status = 'pending')
  );
$$;
revoke execute on function public.app__act_report(integer[], date, date) from public, anon, authenticated;

select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  E'    ''actions'', coalesce((select json_object_agg(a.k, a.n)',
  E'    ''act'', public.app__act_report(ids, p_from, p_to),
    ''actions'', coalesce((select json_object_agg(a.k, a.n)');

-- 見本の3店に、退勤時の入力の見本を用意する（見本の日のうち、出勤の記録が無い日だけ）
create function public.app__demo_counts(p_shop integer, p_day date) returns void
language plpgsql security definer set search_path to '' as $$
declare sid integer; oc integer; fc integer; t0 timestamptz; ent boolean;
begin
  if not exists (select 1 from public.shops where shop_id = p_shop and is_demo) then return; end if;
  for sid in select ss.staff_id from public.staff_shops ss where ss.shop_id = p_shop loop
    if random() < 0.78 then
      oc := case when random() < 0.25 then 0 else 15 + floor(random()*70)::integer end;
      fc := case when random() < 0.35 then 0 else 8 + floor(random()*40)::integer end;
      ent := random() < 0.93;
      t0 := (p_day::timestamp + interval '9 hours 45 minutes' + random()*interval '20 minutes') at time zone 'Asia/Tokyo';
      insert into public.attendance(id,shop_id,work_date,staff_id,clocked_in_at,clocked_out_at,out_call,out_stop,fix_call,fix_talk,cards,counts_at)
        values (gen_random_uuid(), p_shop, p_day, sid, t0, t0 + interval '9 hours',
                case when ent then oc end,
                case when ent then floor(oc * (0.12 + random()*0.2) * (0.8 + (sid % 4) * 0.12))::integer end,
                case when ent then fc end,
                case when ent then floor(fc * (0.2 + random()*0.25) * (0.8 + (sid % 3) * 0.15))::integer end,
                case when ent then floor(random()*9)::integer end,
                case when ent then t0 + interval '9 hours' end);
    end if;
  end loop;
end $$;
revoke execute on function public.app__demo_counts(integer, date) from public, anon, authenticated;
select pg_temp.patch('public.app__demo_history()',
  E'        perform public.app__demo_fill_day(s, d);\n      end if;',
  E'        perform public.app__demo_fill_day(s, d);\n      end if;
      if not exists (select 1 from public.attendance a where a.shop_id = s and a.work_date = d) then
        perform public.app__demo_counts(s, d);
      end if;');
