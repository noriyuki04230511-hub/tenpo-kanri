-- 2026-11-25 代表の指示：Slackに送る文を細かくする（商材ごとの提案数・獲得数など）。
-- 退勤のたびに作る1通の文に、来店区分ごとの接客→成約、全商材の提案→獲得（件数・率）、
-- 声かけ→立ち止まり（立ち話）→受付→成約 を入れる。お客様の情報は入れない。
create or replace function public.app__day_text(p_att uuid, p_redo boolean) returns text
language plpgsql security definer set search_path to '' as $$
declare a public.attendance; nm text; shop text; n integer; w integer; r integer; ro integer; rf integer; row_ integer; rfw integer;
  types text; prods text; pp integer; pw integer; pq integer; act text; t text;
begin
  select * into a from public.attendance where id = p_att;
  if a.id is null then return null; end if;
  select coalesce((select st.display_name from public.staff st where st.staff_id = a.staff_id),
                  (select hp.name from public.helpers hp where hp.id = a.helper_id)) into nm;
  select sh.name into shop from public.shops sh where sh.shop_id = a.shop_id;
  -- 接客した組（担当として記録が1つでもある組）と、そのうち成約した組。来店区分ごとにも出す
  with sv as (
    select v.visit_type, v.result from public.visits v
     where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date
       and exists (select 1 from public.visit_segments g where g.visit_id = v.id
                    and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id))))
  select (select count(*) from sv), (select count(*) from sv where result = 'won'),
         (select string_agg(mt.label || '：' || c.n || '組→成約 ' || c.w || '組', E'\n' order by mt.sort)
            from public.m_visit_types mt join (select visit_type, count(*) n, count(*) filter (where result = 'won') w from sv group by 1) c on c.visit_type = mt.key)
    into n, w, types;
  -- 受付した組（アウトバウンド・什器付きは、成約した組も）
  select count(*), count(*) filter (where v.visit_type = 'out'), count(*) filter (where v.visit_type = 'fix'),
         count(*) filter (where v.visit_type = 'out' and v.result = 'won'), count(*) filter (where v.visit_type = 'fix' and v.result = 'won')
    into r, ro, rf, row_, rfw
    from public.visits v
   where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date
     and ((a.staff_id is not null and v.reception_staff_id = a.staff_id) or (a.helper_id is not null and v.reception_helper_id = a.helper_id));
  -- 商材ごとの提案→獲得（組で数える。件数は別に出す）。扱っている商材はすべて並べる
  with x as (
    select sp.product_key k,
           count(distinct g.visit_id) filter (where sp.proposed_at is not null) pn,
           count(distinct g.visit_id) filter (where sp.won_at is not null) wn,
           coalesce(sum(sp.qty) filter (where sp.won_at is not null), 0) q
      from public.visits v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id
     where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date
       and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id))
     group by 1)
  select string_agg(coalesce(p.short, p.label) || '：提案 ' || coalesce(x.pn, 0) || '組'
           || case when coalesce(x.pn, 0) > 0 or coalesce(x.wn, 0) > 0
                   then '→獲得 ' || coalesce(x.wn, 0) || '組' || case when x.q > x.wn then '（' || x.q || '件）' else '' end
                        || case when x.pn > 0 then '　' || round(100.0 * x.wn / x.pn, 1) || '%' else '' end
                   else '' end, E'\n' order by p.sort),
         coalesce(sum(x.pn), 0), coalesce(sum(x.wn), 0), coalesce(sum(x.q), 0)
    into prods, pp, pw, pq
    from public.m_products p left join x on x.k = p.key where p.active;
  select '見積書お渡し ' || count(*) filter (where sa.action_key = 'estimate') || '・名刺お渡し ' || count(*) filter (where sa.action_key = 'card')
         || '・見込み登録 ' || count(*) filter (where sa.action_key = 'prospect') into act
    from public.visits v join public.visit_segments g on g.visit_id = v.id join public.segment_actions sa on sa.segment_id = g.id
   where v.shop_id = a.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = a.work_date and sa.undone_at is null
     and ((a.staff_id is not null and g.staff_id = a.staff_id) or (a.helper_id is not null and g.helper_id = a.helper_id));
  t := '【退勤' || case when p_redo then '・入れ直し' else '' end || '】' || shop || '　' || nm || 'さん　'
       || to_char(a.work_date, 'FMMM/FMDD') || '（' || (array['日','月','火','水','木','金','土'])[extract(dow from a.work_date)::integer + 1] || '）' || E'\n'
       || '■接客' || E'\n'
       || '接客 ' || n || '組／成約 ' || w || '組' || case when n > 0 then '（成約率 ' || round(100.0 * w / n, 1) || '%）' else '' end || '／受付 ' || r || '組' || E'\n'
       || '■来店区分ごと（接客した組→成約）' || E'\n' || coalesce(types, '接客なし') || E'\n'
       || '■商材ごと（提案→獲得）' || E'\n' || coalesce(prods, 'なし') || E'\n'
       || '合計：提案 のべ' || pp || '組→獲得 のべ' || pw || '組（' || pq || '件）' || E'\n'
       || '■卓での記録' || E'\n' || act;
  if a.counts_at is not null then
    t := t || E'\n' || '■声かけ（退勤時の入力）' || E'\n'
       || 'アウトバウンド：声かけ ' || a.out_call || '→立ち止まり ' || a.out_stop
       || case when a.out_call > 0 then '（' || round(100.0 * a.out_stop / a.out_call, 1) || '%）' else '' end || '→受付 ' || ro || '組→成約 ' || row_ || '組' || E'\n'
       || '什器付き：声かけ ' || a.fix_call || '→立ち話 ' || a.fix_talk
       || case when a.fix_call > 0 then '（' || round(100.0 * a.fix_talk / a.fix_call, 1) || '%）' else '' end || '→受付 ' || rf || '組→成約 ' || rfw || '組' || E'\n'
       || '名刺お渡し：' || a.cards || '枚';
  end if;
  return t;
end $$;
