-- 商材別の成約率を「全体・エリア・店舗・個人」で見られるようにする。
-- あわせて、1組で2件以上の獲得（1組2件口）を「件数」として記録できるようにする。
--   来店と成約率は「組」で数える（1卓＝1組）。件数は別の数字として持つ。

-- 1) エリアと、表の見出し用の短い商材名
alter table public.shops add column area text;
alter table public.m_products add column short text;
update public.m_products set short = case key
  when 'carrier' then '携帯' when 'net' then 'ネット' when 'support' then '店頭サポート' when 'security' then 'セキュリティ'
  when 'used' then '中古スマホ' when 'coat' then 'コーティング' when 'energy' then '電気・ガス' when 'water' then 'ウォーター'
  when 'repair' then '修理' else label end;
-- 仮置き（代表の確認待ち）：アマスタ・梅田・関西外販は「関西」に入れている
update public.shops set area = '関西' where code in ('amasta','doicho','kishiwada','tenri','katano','wakayama','nishinomiya','umeda','gaihan','tawaramoto');
update public.shops set area = '関東' where code in ('kurihashi','namegawa','sakura');
update public.shops set area = '見本・東エリア' where shop_id in (9000, 9100);
update public.shops set area = '見本・西エリア' where shop_id in (9200, 9300);

-- 2) 獲得の件数（獲得したときだけ意味を持つ。ふつうは1）
alter table public.segment_products add column qty integer not null default 1 check (qty between 1 and 99);

create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- 保存：担当ごとの記録に q（商材→件数）が付いていれば件数を入れる。付いていなければ1
select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  'delete from public.segment_products sp where sp.segment_id = gid',
  'update public.segment_products sp
       set qty = case when sp.won_at is not null and (seg->''q''->>sp.product_key) ~ ''^[1-9][0-9]?$'' then (seg->''q''->>sp.product_key)::integer else 1 end
     where sp.segment_id = gid;
    delete from public.segment_products sp where sp.segment_id = gid');

-- 画面へ返す：2件以上の商材だけ q に入れて返す
select pg_temp.patch('public.app__visit(public.visits)',
  '''w'', coalesce((select json_agg(sp.product_key) from public.segment_products sp where sp.segment_id = g.id and sp.won_at is not null), ''[]''::json),',
  '''w'', coalesce((select json_agg(sp.product_key) from public.segment_products sp where sp.segment_id = g.id and sp.won_at is not null), ''[]''::json),
              ''q'', coalesce((select json_object_agg(sp.product_key, sp.qty) from public.segment_products sp where sp.segment_id = g.id and sp.won_at is not null and sp.qty > 1), ''{}''::json),');

-- 見本データ：携帯は3割ほどを2〜3件口にする
select pg_temp.patch('public.app__demo_fill_day(integer,date)',
  'insert into public.segment_products(segment_id,product_key,proposed_at,won_at)',
  'insert into public.segment_products(segment_id,product_key,proposed_at,won_at,qty)');
select pg_temp.patch('public.app__demo_fill_day(integer,date)',
  'case when ans then t0 + interval ''30 minutes'' end) on conflict do nothing;',
  'case when ans then t0 + interval ''30 minutes'' end,
                case when ans and k = ''carrier'' then (array[1,1,1,1,1,1,1,2,2,3])[1 + floor(random()*10)::integer]
                     when ans and k in (''coat'',''used'') and random() < 0.2 then 2 else 1 end) on conflict do nothing;');
-- 見本データ：商材・店舗・人で獲得のしやすさに差を付ける（全部が同じ率だと、画面の見え方を確認できないため）
select pg_temp.patch('public.app__demo_fill_day(integer,date)',
  'ans := random() < 0.32;',
  'ans := random() < (case k when ''carrier'' then 0.36 when ''net'' then 0.18 when ''support'' then 0.44 when ''security'' then 0.38 when ''used'' then 0.22
                              when ''coat'' then 0.48 when ''energy'' then 0.14 when ''water'' then 0.09 else 0.55 end)
                         * (case p_shop when 9100 then 1.15 when 9200 then 0.8 else 1.0 end) * (0.75 + (sid % 4) * 0.17);');
-- 見本の3店（9100・9200・9300）の30日分を作り直す。本物の店舗のデータには触れない
do $$
begin
  if exists (select 1 from public.shops where shop_id = 9100 and is_demo) then
    delete from public.surveys where shop_id in (9100,9200,9300);
    delete from public.visit_procedures where visit_id in (select id from public.visits where shop_id in (9100,9200,9300));
    delete from public.segment_actions where segment_id in (select g.id from public.visit_segments g join public.visits v on v.id = g.visit_id where v.shop_id in (9100,9200,9300));
    delete from public.segment_products where segment_id in (select g.id from public.visit_segments g join public.visits v on v.id = g.visit_id where v.shop_id in (9100,9200,9300));
    delete from public.visit_segments where visit_id in (select id from public.visits where shop_id in (9100,9200,9300));
    delete from public.visit_hearings where visit_id in (select id from public.visits where shop_id in (9100,9200,9300));
    delete from public.visits where shop_id in (9100,9200,9300);
    delete from public.reservations where shop_id in (9100,9200,9300);
    perform public.app__demo_history();
  end if;
end $$;
update public.segment_products sp
   set qty = case abs(hashtext(sp.segment_id::text)) % 10 when 7 then 2 when 8 then 2 when 9 then 3 else 1 end
  from public.visit_segments g join public.visits v on v.id = g.visit_id join public.shops s on s.shop_id = v.shop_id
 where g.id = sp.segment_id and s.is_demo and sp.product_key = 'carrier' and sp.won_at is not null and v.ended_at is not null;

-- 3) 管理画面の集計：商材別の数字を「全体・エリア・店舗・個人」で返す
--    p＝提案した組、w＝獲得した組、q＝獲得した件数。成約率などの割り算は画面側で行う。
create or replace function public.app_report(p_device uuid, p_secret text, p_from date, p_to date, p_shop integer) returns json
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
  with sh as (select shop_id, name, coalesce(area, 'エリア未設定') as area from public.shops where shop_id = any(ids)),
  v as (
    select v.*, (v.started_at at time zone 'Asia/Tokyo')::date as day,
           exists (select 1 from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id
                    where g.visit_id = v.id and sp.proposed_at is not null) as proposed
      from public.visits v where v.shop_id = any(ids) and (v.started_at at time zone 'Asia/Tokyo')::date between p_from and p_to),
  sv as (select s.* from public.surveys s where s.shop_id = any(ids) and (s.created_at at time zone 'Asia/Tokyo')::date between p_from and p_to),
  -- 1組 × 担当した人 × 商材
  gp as (
    select v.id as visit_id, v.shop_id, coalesce('s'||g.staff_id, 'h'||g.helper_id) as person, sp.product_key as k,
           bool_or(sp.proposed_at is not null) as p, bool_or(sp.won_at is not null) as w,
           coalesce(sum(sp.qty) filter (where sp.won_at is not null), 0)::integer as q
      from v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id
     group by 1, 2, 3, 4),
  -- 1組 × 商材（担当が代わっても1組は1組）
  vp as (select visit_id, shop_id, k, bool_or(p) as p, bool_or(w) as w, sum(q)::integer as q from gp group by 1, 2, 3),
  -- 人ごとの接客した組
  pn as (
    select coalesce('s'||g.staff_id, 'h'||g.helper_id) as person, coalesce(max(st.display_name), max(hp.name)) as name,
           string_agg(distinct sn.name, '・') as shop, count(distinct v.id) as n
      from v join public.visit_segments g on g.visit_id = v.id
      left join public.staff st on st.staff_id = g.staff_id left join public.helpers hp on hp.id = g.helper_id
      join public.shops sn on sn.shop_id = v.shop_id group by 1)
  select json_build_object(
    'now', public.app__ms(now()), 'role', dv.role, 'from', p_from, 'to', p_to,
    'allShops', coalesce((select json_agg(json_build_object('id',s.shop_id,'name',s.name) order by s.shop_id) from public.shops s
                  where s.active and case dv.role when 'manager' then s.shop_id = dv.shop_id when 'hq' then not s.is_demo else s.is_demo end), '[]'::json),
    'total', (select json_build_object('visits',count(*),'guide',count(*) filter (where visit_type = 'in_guide'),
                'proposed',count(*) filter (where proposed),'won',count(*) filter (where result = 'won'),'open',count(*) filter (where ended_at is null)) from v),
    'byShop', coalesce((select json_agg(json_build_object('id',sh.shop_id,'name',sh.name,'area',sh.area,'visits',c.n,'guide',c.g,'proposed',c.p,'won',c.w,'sat',c.sat,'satN',c.satn) order by sh.shop_id)
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
      from (select pn.name, pn.shop, pn.n,
                   (select count(distinct gp.visit_id) from gp where gp.person = pn.person and gp.p) as p,
                   (select count(distinct gp.visit_id) from gp where gp.person = pn.person and gp.w) as w from pn) x), '[]'::json),
    'byProduct', (select json_agg(json_build_object('label',p.label,'proposed',coalesce(c.p,0),'won',coalesce(c.w,0)) order by p.sort)
      from public.m_products p left join (select k, count(*) filter (where p) p, count(*) filter (where w) w from vp group by k) c on c.k = p.key),
    'products', (select json_agg(json_build_object('k',p.key,'label',p.label,'short',coalesce(p.short,p.label)) order by p.sort) from public.m_products p where p.active),
    'prod', json_build_object(
      'all', json_build_object('name','全体','visits',(select count(*) from v),
        'cells', coalesce((select json_object_agg(c.k, json_build_object('p',c.p,'w',c.w,'q',c.q))
                   from (select k, count(*) filter (where p) p, count(*) filter (where w) w, coalesce(sum(q),0) q from vp group by k) c), '{}'::json)),
      'areas', coalesce((select json_agg(json_build_object('name',a.area,'sub',a.shops||'店','visits',a.n,'cells',a.cells) order by a.area)
        from (select x.area, count(*) as shops, (select count(*) from v join sh s2 on s2.shop_id = v.shop_id where s2.area = x.area) as n,
                     coalesce((select json_object_agg(c.k, json_build_object('p',c.p,'w',c.w,'q',c.q))
                        from (select vp.k, count(*) filter (where vp.p) p, count(*) filter (where vp.w) w, coalesce(sum(vp.q),0) q
                                from vp join sh s3 on s3.shop_id = vp.shop_id where s3.area = x.area group by vp.k) c), '{}'::json) as cells
                from sh x group by x.area) a), '[]'::json),
      'shops', coalesce((select json_agg(json_build_object('name',sh.name,'sub',sh.area,'visits',(select count(*) from v where v.shop_id = sh.shop_id),
                 'cells', coalesce((select json_object_agg(c.k, json_build_object('p',c.p,'w',c.w,'q',c.q))
                    from (select k, count(*) filter (where p) p, count(*) filter (where w) w, coalesce(sum(q),0) q from vp where vp.shop_id = sh.shop_id group by k) c), '{}'::json))
                 order by sh.area, sh.shop_id) from sh), '[]'::json),
      'staff', coalesce((select json_agg(json_build_object('name',pn.name,'sub',pn.shop,'visits',pn.n,
                 'cells', coalesce((select json_object_agg(c.k, json_build_object('p',c.p,'w',c.w,'q',c.q))
                    from (select k, count(*) filter (where p) p, count(*) filter (where w) w, coalesce(sum(q),0) q from gp where gp.person = pn.person group by k) c), '{}'::json))
                 order by pn.n desc, pn.name) from pn), '[]'::json)),
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
               (select count(*) from vp where vp.visit_id = v.id and vp.p) as p,
               (select count(*) from vp where vp.visit_id = v.id and vp.w) as w,
               (select coalesce(sum(vp.q),0) from vp where vp.visit_id = v.id and vp.w) as q
          from v join public.shops sn on sn.shop_id = v.shop_id join public.tables tb on tb.id = v.table_id
          join public.m_visit_types t on t.key = v.visit_type left join public.visit_hearings h on h.visit_id = v.id
         order by v.started_at desc limit 40) r), '[]'::json)
  ) into out;
  return out;
end $$;
revoke execute on function public.app_report(uuid,text,date,date,integer) from public, authenticated;
grant execute on function public.app_report(uuid,text,date,date,integer) to anon;
