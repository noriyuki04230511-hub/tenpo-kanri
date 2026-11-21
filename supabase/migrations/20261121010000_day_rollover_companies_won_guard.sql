-- 2026-11-21 の代表の回答を反映する。
--  1) 日付が変わったら、前の日に終了していない接客を自動で区切る（フロアは毎日まっさらで始まる）。
--     区切った接客は来店として残し、auto_closed に印を付ける。時間の集計には入れない。
--     前の日の予約で受付されなかったものは「来店なし」にする。
--  2) 応援スタッフの会社名の一覧を、名簿（outsource_companies）から画面へ返す（見本店には見本の名前だけ）。
--     名簿にある会社を選んだときは、helpers.company_id にも入れる。
--  3) 獲得した商材が0個の接客は「成約」にできない。
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- 1) 日付の区切り
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'  perform public.app__demo_seed(s, false);\n',
  E'  perform public.app__demo_seed(s, false);
  if exists (select 1 from public.visits v where v.shop_id = s and v.ended_at is null and v.started_at < (d::timestamp at time zone ''Asia/Tokyo'')) then
    with c as (
      update public.visits v set phase = ''closed'', auto_closed = true,
             ended_at = greatest(v.started_at, least(now(),
               (((v.started_at at time zone ''Asia/Tokyo'')::date + coalesce((select sh.closes_at from public.shops sh where sh.shop_id = s), time ''23:59'')) at time zone ''Asia/Tokyo'')))
       where v.shop_id = s and v.ended_at is null and v.started_at < (d::timestamp at time zone ''Asia/Tokyo'')
      returning v.id, v.table_id, v.reservation_id),
    t as (update public.tables t set removed_at = now() where t.is_auto and t.removed_at is null and t.id in (select c.table_id from c)),
    r as (update public.reservations rr set status = ''done'', closed_at = now() where rr.status = ''arrived'' and rr.id in (select c.reservation_id from c))
    insert into public.events(shop_id,device_id,action,target_table,target_id,reason)
      select s, p_device, ''visit.auto_close'', ''visits'', c.id::text, ''日付が変わったため、終了していない接客を自動で区切った'' from c;
  end if;
  if exists (select 1 from public.reservations rr where rr.shop_id = s and rr.status in (''booked'',''seated'') and rr.reserved_at < (d::timestamp at time zone ''Asia/Tokyo'')) then
    update public.tables t set removed_at = now()
     where t.shop_id = s and t.is_auto and t.removed_at is null
       and t.reservation_id in (select rr.id from public.reservations rr where rr.shop_id = s and rr.status in (''booked'',''seated'') and rr.reserved_at < (d::timestamp at time zone ''Asia/Tokyo''))
       and not exists (select 1 from public.visits v where v.table_id = t.id and v.ended_at is null);
    update public.reservations rr set status = ''noshow'', closed_at = now()
     where rr.shop_id = s and rr.status in (''booked'',''seated'') and rr.reserved_at < (d::timestamp at time zone ''Asia/Tokyo'');
  end if;
');

-- 時間の集計：自動で区切った接客は「終了の押し忘れ」として除く
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  'count(*) filter (where ended_at - started_at <= interval ''4 hours'') e,',
  'count(*) filter (where not auto_closed and ended_at - started_at <= interval ''4 hours'') e,');
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  'round(avg(extract(epoch from (ended_at - started_at))/60) filter (where ended_at - started_at <= interval ''4 hours'')) am,',
  'round(avg(extract(epoch from (ended_at - started_at))/60) filter (where not auto_closed and ended_at - started_at <= interval ''4 hours'')) am,');
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  'coalesce(round(sum(extract(epoch from (ended_at - started_at))/60) filter (where ended_at - started_at <= interval ''4 hours'')), 0) sm,',
  'coalesce(round(sum(extract(epoch from (ended_at - started_at))/60) filter (where not auto_closed and ended_at - started_at <= interval ''4 hours'')), 0) sm,');
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  'count(*) filter (where ended_at - started_at > interval ''4 hours'') ln',
  'count(*) filter (where auto_closed or ended_at - started_at > interval ''4 hours'') ln');
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  'h.age_band as age, h.purpose, v.result, v.phase,',
  'h.age_band as age, h.purpose, v.result, v.phase, v.auto_closed as auto,');

-- 2) 会社名の一覧
select pg_temp.patch('public.app__floor_full(uuid,text)',
  E'    ''staff'', coalesce((select json_agg(json_build_object(''id'',x.id,',
  E'    ''companies'', case when (select sh.is_demo from public.shops sh where sh.shop_id = s) then ''["見本A社","見本B社","見本C社"]''::json
                    else coalesce((select json_agg(c.name order by c.company_id) from public.outsource_companies c where c.active), ''[]''::json) end,
    ''staff'', coalesce((select json_agg(json_build_object(''id'',x.id,');
select pg_temp.patch('public.app_add_helper(uuid,text,uuid,text,text,text)',
  'insert into public.helpers(id,shop_id,work_date,kind,company_other,name,device_id)
    values (p_id, s, d, p_kind, left(p_company,60), left(p_name,40), p_device)',
  'insert into public.helpers(id,shop_id,work_date,kind,company_id,company_other,name,device_id)
    values (p_id, s, d, p_kind, (select c.company_id from public.outsource_companies c where c.active and c.name = left(p_company,60) order by c.company_id limit 1),
            left(p_company,60), left(p_name,40), p_device)');

-- 3) 獲得0個では成約にできない
select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  E'\n  if closed and (select v.result from public.visits v where v.id = vid) is distinct from ''won''',
  E'\n  if (p_visit->>''result'') = ''won'' and not exists (select 1 from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id
                  where g.visit_id = vid and sp.won_at is not null) then
    raise exception ''won_needs_product'' using errcode = ''22023'';
  end if;
  if closed and (select v.result from public.visits v where v.id = vid) is distinct from ''won''');
