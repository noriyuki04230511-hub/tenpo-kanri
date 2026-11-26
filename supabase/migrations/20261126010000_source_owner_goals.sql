-- 2026-11-26 代表の追加依頼。
--  1) ヒアリング（お客様記入）に「当店を知ったきっかけ」「ご契約者様ご本人の来店」を追加。
--  2) 出勤のときに本日の個人目標（アウト着座・モバイル契約）を入力。退勤の画面で、目標・実績・達成率を表示。
--     実績は卓での記録から数える：アウト着座＝その人が受付したアウトバウンドの組数、モバイル契約＝その人の担当分で獲得した携帯の件数。
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- 1) ヒアリングの項目
alter table public.visit_hearings add column source text, add column owner_present text;
select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  E'insert into public.visit_hearings(visit_id,age_band,purpose,carrier,family_lines,home_net,extras)
      values (vid, h->>''age'', h->>''purpose'', h->>''carrier'', h->>''lines'', h->>''net'',',
  E'insert into public.visit_hearings(visit_id,age_band,purpose,carrier,family_lines,home_net,source,owner_present,extras)
      values (vid, h->>''age'', h->>''purpose'', h->>''carrier'', h->>''lines'', h->>''net'', left(h->>''src'', 60), left(h->>''own'', 20),');
select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  E'family_lines = excluded.family_lines, home_net = excluded.home_net, extras = excluded.extras;',
  E'family_lines = excluded.family_lines, home_net = excluded.home_net, source = excluded.source, owner_present = excluded.owner_present, extras = excluded.extras;');
select pg_temp.patch('public.app__visit(public.visits)',
  E'''net'',h.home_net,''extra'',to_json(h.extras))',
  E'''net'',h.home_net,''src'',h.source,''own'',h.owner_present,''extra'',to_json(h.extras))');

-- 管理画面：来店のきっかけ・ご契約者様の来店
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  E'    ''byStaff'', coalesce((select json_agg(json_build_object(''name'',x.name,''shop'',x.shop,''visits'',x.n,',
  E'    ''bySource'', coalesce((select json_agg(json_build_object(''src'',a.src,''visits'',a.n,''won'',a.w) order by a.n desc, a.src)
      from (select h.source src, count(*) n, count(*) filter (where v.result = ''won'') w from v join public.visit_hearings h on h.visit_id = v.id where h.source is not null group by 1) a), ''[]''::json),
    ''byOwner'', coalesce((select json_agg(json_build_object(''own'',a.own,''visits'',a.n,''won'',a.w) order by a.own)
      from (select h.owner_present own, count(*) n, count(*) filter (where v.result = ''won'') w from v join public.visit_hearings h on h.visit_id = v.id where h.owner_present is not null group by 1) a), ''[]''::json),
    ''byStaff'', coalesce((select json_agg(json_build_object(''name'',x.name,''shop'',x.shop,''visits'',x.n,');

-- 2) 個人目標
alter table public.attendance
  add column goal_out integer check (goal_out between 0 and 999),
  add column goal_mobile integer check (goal_mobile between 0 and 999),
  add column goals_at timestamptz,
  add constraint attendance_goals_all_or_none check ((goals_at is null and goal_out is null and goal_mobile is null) or (goals_at is not null and goal_out is not null and goal_mobile is not null));

-- その人のその日の目標と実績
create function public.app__day_progress(p_att uuid) returns json
language sql stable security definer set search_path to '' as $$
  select json_build_object(
    'goalOut', a.goal_out, 'goalMobile', a.goal_mobile,
    'outSeat', (select count(*) from public.visits v
                 where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date and v.visit_type = 'out'
                   and ((a.staff_id is not null and v.reception_staff_id = a.staff_id) or (a.helper_id is not null and v.reception_helper_id = a.helper_id))),
    'mobile', (select coalesce(sum(sp.qty), 0) from public.visits v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id
                where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date and sp.product_key = 'carrier' and sp.won_at is not null
                  and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id))))
    from public.attendance a where a.id = p_att;
$$;
revoke execute on function public.app__day_progress(uuid) from public, anon, authenticated;

-- 出勤（本日の目標つき）。出勤済みで目標が未入力の人は、目標だけを入れられる
create function public.app_day_start(p_device uuid, p_secret text, p_actor text, p_goals jsonb) returns json
language plpgsql security definer set search_path to '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date;
  a public.attendance; sid integer; hid uuid; go integer; gm integer; fresh boolean := false;
begin
  if p_goals is null or jsonb_typeof(p_goals) <> 'object'
     or coalesce(p_goals->>'go','') !~ '^[0-9]{1,3}$' or coalesce(p_goals->>'gm','') !~ '^[0-9]{1,3}$' then
    return json_build_object('error', 'bad_goals');
  end if;
  go := (p_goals->>'go')::integer; gm := (p_goals->>'gm')::integer;
  if p_actor ~ '^s[0-9]{1,9}$' then
    sid := substr(p_actor, 2)::integer;
    if not exists (select 1 from public.staff st join public.staff_shops ss on ss.staff_id = st.staff_id where st.staff_id = sid and ss.shop_id = s and st.active) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    select * into a from public.attendance where shop_id = s and work_date = d and staff_id = sid;
    if a.id is null then
      insert into public.attendance(id,shop_id,work_date,staff_id,device_id) values (gen_random_uuid(), s, d, sid, p_device)
        on conflict (shop_id, work_date, staff_id) where staff_id is not null do nothing;
      select * into a from public.attendance where shop_id = s and work_date = d and staff_id = sid;
      fresh := true;
      insert into public.events(shop_id,device_id,actor_staff_id,action,target_table,target_id) values (s, p_device, sid, 'attendance.clock_in', 'attendance', p_actor);
    end if;
  elsif p_actor ~ '^h[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    hid := substr(p_actor, 2)::uuid;
    select x.* into a from public.attendance x join public.helpers h on h.id = x.helper_id where x.helper_id = hid and h.shop_id = s;
  else
    return json_build_object('error', 'bad_request');
  end if;
  if a.id is null then return json_build_object('error', 'not_found'); end if;
  update public.attendance set goal_out = go, goal_mobile = gm, goals_at = now() where id = a.id;
  insert into public.events(shop_id,device_id,actor_staff_id,actor_helper_id,action,target_table,target_id,before,after)
    values (s, p_device, sid, null, 'attendance.goals', 'attendance', p_actor,
            case when a.goals_at is not null then jsonb_build_object('go',a.goal_out,'gm',a.goal_mobile) end, jsonb_build_object('go',go,'gm',gm));
  return public.app_floor(p_device, p_secret);
end $$;
revoke execute on function public.app_day_start(uuid,text,text,jsonb) from public, authenticated;
grant execute on function public.app_day_start(uuid,text,text,jsonb) to anon;

-- 退勤の画面に出す、その人の本日の目標と実績（この2項目だけを返す）
create function public.app_day_progress(p_device uuid, p_secret text, p_actor text) returns json
language plpgsql stable security definer set search_path to '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date; aid uuid;
begin
  if p_actor ~ '^s[0-9]{1,9}$' then
    select a.id into aid from public.attendance a where a.shop_id = s and a.work_date = d and a.staff_id = substr(p_actor, 2)::integer;
  elsif p_actor ~ '^h[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    select x.id into aid from public.attendance x join public.helpers h on h.id = x.helper_id where x.helper_id = substr(p_actor, 2)::uuid and h.shop_id = s;
  end if;
  if aid is null then return json_build_object('error', 'not_found'); end if;
  return public.app__day_progress(aid);
end $$;
revoke execute on function public.app_day_progress(uuid,text,text) from public, authenticated;
grant execute on function public.app_day_progress(uuid,text,text) to anon;

-- フロア：目標が入力済みかどうかだけを返す
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'''outAt'',x.out_at,''cnt'',x.cnt) order by x.ord)',
  E'''outAt'',x.out_at,''cnt'',x.cnt,''gl'',x.gl) order by x.ord)');
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'and a.staff_id = st.staff_id and a.counts_at is not null) as cnt\n',
  E'and a.staff_id = st.staff_id and a.counts_at is not null) as cnt,
               exists (select 1 from public.attendance a where a.shop_id = s and a.work_date = d and a.staff_id = st.staff_id and a.goals_at is not null) as gl\n');
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'exists (select 1 from public.attendance a where a.helper_id = h.id and a.counts_at is not null)\n',
  E'exists (select 1 from public.attendance a where a.helper_id = h.id and a.counts_at is not null),
               exists (select 1 from public.attendance a where a.helper_id = h.id and a.goals_at is not null)\n');

-- 退勤時の文に、目標・実績・達成率を足す
select pg_temp.patch('public.app__day_text(uuid,boolean)',
  E'  if a.counts_at is not null then',
  E'  if a.goals_at is not null then
    t := t || E''\\n'' || ''■目標と実績'' || E''\\n'' || (
      select ''アウト着座：目標 '' || a.goal_out || ''件／実績 '' || (pg->>''outSeat'') || ''件''
             || case when a.goal_out > 0 then ''／達成率 '' || round(100.0 * (pg->>''outSeat'')::numeric / a.goal_out) || ''%'' else '''' end || E''\\n''
             || ''モバイル契約：目標 '' || a.goal_mobile || ''件／実績 '' || (pg->>''mobile'') || ''件''
             || case when a.goal_mobile > 0 then ''／達成率 '' || round(100.0 * (pg->>''mobile'')::numeric / a.goal_mobile) || ''%'' else '''' end
        from (select public.app__day_progress(a.id) pg) q);
  end if;
  if a.counts_at is not null then');

-- 代表あての集計に、店舗ごとの目標の合計と実績を足す
select pg_temp.patch('public.app__daily_summary_text(date)',
  E'       || ''名刺お渡し：'' || cd || ''枚'' || E''\\n''',
  E'       || ''名刺お渡し：'' || cd || ''枚'' || E''\\n''
       || coalesce((select ''目標と実績：アウト着座 目標 '' || sum(a.goal_out) || ''件／実績 '' || ov || ''件''
                           || case when sum(a.goal_out) > 0 then ''（'' || round(100.0 * ov / sum(a.goal_out)) || ''%）'' else '''' end
                           || ''、モバイル契約 目標 '' || sum(a.goal_mobile) || ''件／実績 '' || mw.q || ''件''
                           || case when sum(a.goal_mobile) > 0 then ''（'' || round(100.0 * mw.q / sum(a.goal_mobile)) || ''%）'' else '''' end || E''\\n''
                      from public.attendance a
                      cross join (select coalesce(sum(sp.qty), 0) q from public.visits v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id
                                   where v.shop_id = sh.shop_id and (v.started_at at time zone ''Asia/Tokyo'')::date = p_day and sp.product_key = ''carrier'' and sp.won_at is not null) mw
                     where a.shop_id = sh.shop_id and a.work_date = p_day and a.goals_at is not null
                     group by mw.q), '''')');

-- 管理画面：目標と実績（店舗別・スタッフ別）
create function public.app__goal_report(p_ids integer[], p_from date, p_to date) returns json
language sql stable security definer set search_path to '' as $$
  with at as (
    select a.shop_id, coalesce('s'||a.staff_id, 'h'||a.helper_id) as person, coalesce(st.display_name, hp.name) as name, a.goal_out, a.goal_mobile, a.goals_at
      from public.attendance a left join public.staff st on st.staff_id = a.staff_id left join public.helpers hp on hp.id = a.helper_id
     where a.shop_id = any(p_ids) and a.work_date between p_from and p_to),
  v as (select v.id, v.shop_id, v.visit_type, coalesce('s'||v.reception_staff_id, 'h'||v.reception_helper_id) as person
          from public.visits v where v.shop_id = any(p_ids) and (v.started_at at time zone 'Asia/Tokyo')::date between p_from and p_to),
  mw as (select v.shop_id, coalesce('s'||g.staff_id, 'h'||g.helper_id) as person, sum(sp.qty) q
           from v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id
          where sp.product_key = 'carrier' and sp.won_at is not null group by 1, 2),
  sg as (select shop_id, count(*) days, count(goals_at) ent, coalesce(sum(goal_out),0) go, coalesce(sum(goal_mobile),0) gm from at group by 1),
  pg as (select at.person, max(at.name) as name, string_agg(distinct sn.name, '・') as shop, count(*) days, count(at.goals_at) ent, coalesce(sum(at.goal_out),0) go, coalesce(sum(at.goal_mobile),0) gm
           from at join public.shops sn on sn.shop_id = at.shop_id group by 1)
  select json_build_object(
    'all', json_build_object('name','全体','days',(select coalesce(sum(days),0) from sg),'ent',(select coalesce(sum(ent),0) from sg),'go',(select coalesce(sum(go),0) from sg),'gm',(select coalesce(sum(gm),0) from sg),
                             'os',(select count(*) from v where visit_type = 'out'),'mw',(select coalesce(sum(q),0) from mw)),
    'shops', coalesce((select json_agg(json_build_object('name',sh.name,'sub',coalesce(sh.area,''),'days',g.days,'ent',g.ent,'go',g.go,'gm',g.gm,
                     'os',(select count(*) from v where v.shop_id = sh.shop_id and v.visit_type = 'out'),'mw',(select coalesce(sum(m.q),0) from mw m where m.shop_id = sh.shop_id)) order by sh.shop_id)
               from sg g join public.shops sh on sh.shop_id = g.shop_id), '[]'::json),
    'staff', coalesce((select json_agg(json_build_object('name',g.name,'sub',g.shop,'days',g.days,'ent',g.ent,'go',g.go,'gm',g.gm,
                     'os',(select count(*) from v where v.person = g.person and v.visit_type = 'out'),'mw',(select coalesce(sum(m.q),0) from mw m where m.person = g.person)) order by g.go + g.gm desc, g.name)
               from pg g), '[]'::json));
$$;
revoke execute on function public.app__goal_report(integer[], date, date) from public, anon, authenticated;
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  E'    ''act'', public.app__act_report(ids, p_from, p_to),',
  E'    ''act'', public.app__act_report(ids, p_from, p_to),
    ''goal'', public.app__goal_report(ids, p_from, p_to),');

-- 応援スタッフの操作の履歴には、応援スタッフへの参照を持たせない（追加の取り消しを妨げないため）。手続きの担当になった人は取り消せない
select pg_temp.patch('public.app_day_close(uuid,text,text,jsonb)',
  E'values (s, p_device, sid, hid, ''attendance.day_close'', ''attendance'', p_actor,',
  E'values (s, p_device, sid, null, ''attendance.day_close'', ''attendance'', p_actor,');
select pg_temp.patch('public.app_undo(uuid,text,text,text)',
  E'or exists (select 1 from public.events e where e.actor_helper_id = uid) then',
  E'or exists (select 1 from public.visit_procedures vp where vp.helper_id = uid)
         or exists (select 1 from public.events e where e.actor_helper_id = uid) then');
select pg_temp.patch('public.app_undo(uuid,text,text,text)',
  E'and (v.reception_staff_id = sid or exists (select 1 from public.visit_segments g where g.visit_id = v.id and g.staff_id = sid))) then',
  E'and (v.reception_staff_id = sid or exists (select 1 from public.visit_segments g where g.visit_id = v.id and g.staff_id = sid)
                     or exists (select 1 from public.visit_procedures vp where vp.visit_id = v.id and vp.staff_id = sid))) then');

-- 見本の出勤に、目標の見本を入れる
select pg_temp.patch('public.app__demo_counts(integer,date)',
  E'insert into public.attendance(id,shop_id,work_date,staff_id,clocked_in_at,clocked_out_at,out_call,out_stop,fix_call,fix_talk,cards,counts_at)
        values (gen_random_uuid(), p_shop, p_day, sid, t0, t0 + interval ''9 hours'',',
  E'insert into public.attendance(id,shop_id,work_date,staff_id,clocked_in_at,clocked_out_at,goal_out,goal_mobile,goals_at,out_call,out_stop,fix_call,fix_talk,cards,counts_at)
        values (gen_random_uuid(), p_shop, p_day, sid, t0, t0 + interval ''9 hours'', 1 + (sid % 3), 1 + (sid % 2), t0,');
update public.attendance a set goal_out = 1 + (a.staff_id % 3), goal_mobile = 1 + (a.staff_id % 2), goals_at = a.clocked_in_at
  from public.shops s where s.shop_id = a.shop_id and s.is_demo and a.shop_id <> 9000 and a.goals_at is null and a.staff_id is not null and a.clocked_in_at is not null;
