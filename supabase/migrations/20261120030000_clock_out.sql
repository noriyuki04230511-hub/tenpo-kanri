-- 退勤（代表の指示 2026-11-20 12:56）。
-- 出勤の欄に「退勤」を足す。退勤した人は、受付・接客の担当として選べなくなる。
-- 押し間違えた退勤は、取り消して出勤中に戻せる（取り消した事実は操作の履歴に残す）。
alter table public.attendance add column clocked_out_at timestamptz;

create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- 画面へ返す内容に、退勤の時刻（outAt）を足す
select pg_temp.patch('public.app__floor_full(uuid,text)',
  '''inAt'',x.in_at) order by x.ord)',
  '''inAt'',x.in_at,''outAt'',x.out_at) order by x.ord)');
select pg_temp.patch('public.app__floor_full(uuid,text)',
  'and a.staff_id = st.staff_id) as in_at,',
  'and a.staff_id = st.staff_id) as in_at,
               (select public.app__ms(a.clocked_out_at) from public.attendance a where a.shop_id = s and a.work_date = d and a.staff_id = st.staff_id) as out_at,');
select pg_temp.patch('public.app__floor_full(uuid,text)',
  '(select public.app__ms(a.clocked_in_at) from public.attendance a where a.helper_id = h.id),',
  '(select public.app__ms(a.clocked_in_at) from public.attendance a where a.helper_id = h.id),
               (select public.app__ms(a.clocked_out_at) from public.attendance a where a.helper_id = h.id),');

-- 退勤。いま接客の担当になっている人は退勤できない（error を返す）
create function public.app_clock_out(p_device uuid, p_secret text, p_actor text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date;
  a public.attendance; sid integer; hid uuid;
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
  if a.clocked_out_at is null then
    if exists (select 1 from public.visits v where v.shop_id = s and v.ended_at is null and (
          (not exists (select 1 from public.visit_segments g where g.visit_id = v.id) and (v.reception_staff_id = sid or v.reception_helper_id = hid))
          or exists (select 1 from (select g.staff_id, g.helper_id from public.visit_segments g where g.visit_id = v.id order by g.started_at desc, g.id desc limit 1) l
                      where l.staff_id = sid or l.helper_id = hid))) then
      return json_build_object('error', 'serving');
    end if;
    update public.attendance set clocked_out_at = now() where id = a.id;
    insert into public.events(shop_id,device_id,actor_staff_id,action,target_table,target_id)
      values (s, p_device, sid, 'attendance.clock_out', 'attendance', p_actor);
  end if;
  return public.app_floor(p_device, p_secret);
end $$;
revoke execute on function public.app_clock_out(uuid,text,text) from public, authenticated;
grant execute on function public.app_clock_out(uuid,text,text) to anon;

-- 押し間違えた退勤の取り消し（app_undo に種類 clock_out を足す）
select pg_temp.patch('public.app_undo(uuid,text,text,text)',
  E'  elsif p_kind in (''helper'',''table'',''reservation'') and p_id ~',
  E'  elsif p_kind = ''clock_out'' and (p_id ~ ''^s[0-9]{1,9}$'' or p_id ~ ''^h[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'') then
    if p_id like ''s%'' then
      select * into a from public.attendance where shop_id = s and work_date = d and staff_id = substr(p_id, 2)::integer;
    else
      select x.* into a from public.attendance x join public.helpers hh on hh.id = x.helper_id where x.helper_id = substr(p_id, 2)::uuid and hh.shop_id = s;
    end if;
    if a.id is null or a.clocked_out_at is null then return json_build_object(''error'', ''not_found''); end if;
    update public.attendance set clocked_out_at = null where id = a.id;
    insert into public.events(shop_id,device_id,actor_staff_id,action,target_table,target_id,before,reason)
      values (s, p_device, a.staff_id, ''attendance.clock_out_undo'', ''attendance'', p_id, to_jsonb(a), ''押し間違いの取り消し'');
  elsif p_kind in (''helper'',''table'',''reservation'') and p_id ~');
