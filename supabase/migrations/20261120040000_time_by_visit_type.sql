-- 管理画面「現場の時間の使い方」用に、来店区分ごとの所要時間を集計に足す。
-- 所要時間＝受付から卓が空くまで。4時間を超えた記録は「終了の押し忘れ」として時間の集計から除き、件数だけ返す。
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  'json_build_object(''label'',t.label,''visits'',c.n,''won'',c.w) order by t.sort)',
  'json_build_object(''label'',t.label,''visits'',c.n,''won'',c.w,''key'',t.key,''timed'',c.e,''avgMin'',c.am,''sumMin'',c.sm,''longN'',c.ln) order by t.sort)');
select pg_temp.patch('public.app_report(uuid,text,date,date,integer)',
  '(select count(*) n, count(*) filter (where result = ''won'') w from v where v.visit_type = t.key) c on true)',
  '(select count(*) n, count(*) filter (where result = ''won'') w,
               count(*) filter (where ended_at - started_at <= interval ''4 hours'') e,
               round(avg(extract(epoch from (ended_at - started_at))/60) filter (where ended_at - started_at <= interval ''4 hours'')) am,
               coalesce(round(sum(extract(epoch from (ended_at - started_at))/60) filter (where ended_at - started_at <= interval ''4 hours'')), 0) sm,
               count(*) filter (where ended_at - started_at > interval ''4 hours'') ln
          from v where v.visit_type = t.key) c on true)');
