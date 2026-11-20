-- 獲得した商材が1つ以上ある接客は、「成約なし」で終了できないようにする（代表の指示 2026-11-20 11:35）。
-- 画面側で「成約なしで終了」を押せなくしたうえで、データベース側でも同じ内容を確かめる。
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  E'\n  if closed then\n',
  E'\n  if closed and (select v.result from public.visits v where v.id = vid) is distinct from ''won''
     and exists (select 1 from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id
                  where g.visit_id = vid and sp.won_at is not null) then
    raise exception ''won_product_needs_won_close'' using errcode = ''22023'';
  end if;\n  if closed then\n');
