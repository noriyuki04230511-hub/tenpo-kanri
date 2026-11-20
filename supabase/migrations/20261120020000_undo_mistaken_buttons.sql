-- 押し間違いの取り消し（代表の指示 2026-11-20 11:58）。
-- 出勤・応援スタッフ・卓・予約の押し間違いを、記録ごと消す。集計には入らない。
-- 消した事実と消す前の中身は、操作の履歴（events）にだけ残す。
-- すでに接客の記録に使われているものは消さない（error を返す。画面に理由を出す）。
create function public.app_undo(p_device uuid, p_secret text, p_kind text, p_id text) returns json
language plpgsql security definer set search_path = '' as $$
declare s integer := public.app__shop(p_device, p_secret); d date := (now() at time zone 'Asia/Tokyo')::date;
  sid integer; uid uuid; a public.attendance; h public.helpers; t public.tables; r public.reservations;
begin
  if p_kind = 'clock_in' and p_id ~ '^s[0-9]{1,9}$' then
    sid := substr(p_id, 2)::integer;
    select * into a from public.attendance where shop_id = s and work_date = d and staff_id = sid;
    if a.id is null then return json_build_object('error', 'not_found'); end if;
    if exists (select 1 from public.visits v where v.shop_id = s and (v.started_at at time zone 'Asia/Tokyo')::date = d
                and (v.reception_staff_id = sid or exists (select 1 from public.visit_segments g where g.visit_id = v.id and g.staff_id = sid))) then
      return json_build_object('error', 'in_use');
    end if;
    delete from public.attendance where id = a.id;
    insert into public.events(shop_id,device_id,actor_staff_id,action,target_table,target_id,before,reason)
      values (s, p_device, sid, 'attendance.undo', 'attendance', p_id, to_jsonb(a), '押し間違いの取り消し');
  elsif p_kind in ('helper','table','reservation') and p_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    uid := p_id::uuid;
    if p_kind = 'helper' then
      select * into h from public.helpers where id = uid and shop_id = s;
      if h.id is null then return json_build_object('error', 'not_found'); end if;
      if exists (select 1 from public.visits v where v.reception_helper_id = uid)
         or exists (select 1 from public.visit_segments g where g.helper_id = uid)
         or exists (select 1 from public.events e where e.actor_helper_id = uid) then
        return json_build_object('error', 'in_use');
      end if;
      delete from public.attendance where helper_id = uid;
      delete from public.helpers where id = uid;
      insert into public.events(shop_id,device_id,action,target_table,target_id,before,reason)
        values (s, p_device, 'helper.undo', 'helpers', p_id, to_jsonb(h), '押し間違いの取り消し');
    elsif p_kind = 'table' then
      select * into t from public.tables where id = uid and shop_id = s and removed_at is null;
      if t.id is null then return json_build_object('error', 'not_found'); end if;
      if t.is_auto then return json_build_object('error', 'auto_table'); end if;
      if exists (select 1 from public.visits v where v.table_id = uid and v.ended_at is null) then return json_build_object('error', 'in_use'); end if;
      if (select count(*) from public.tables x where x.shop_id = s and x.removed_at is null and not x.is_auto) <= 1 then
        return json_build_object('error', 'last_table');
      end if;
      if exists (select 1 from public.visits v where v.table_id = uid) then
        update public.tables set removed_at = now() where id = uid;   -- 過去の接客がある卓は、接客の記録を守るため行は残す
      else
        delete from public.tables where id = uid;
      end if;
      insert into public.events(shop_id,device_id,action,target_table,target_id,before,reason)
        values (s, p_device, 'table.undo', 'tables', p_id, to_jsonb(t), '押し間違いの取り消し');
    else
      select * into r from public.reservations where id = uid and shop_id = s;
      if r.id is null then return json_build_object('error', 'not_found'); end if;
      if r.status not in ('booked','seated') or exists (select 1 from public.visits v where v.reservation_id = uid)
         or exists (select 1 from public.tables x join public.visits v on v.table_id = x.id where x.reservation_id = uid) then
        return json_build_object('error', 'in_use');
      end if;
      delete from public.tables where reservation_id = uid;
      delete from public.reservations where id = uid;
      insert into public.events(shop_id,device_id,action,target_table,target_id,before,reason)
        values (s, p_device, 'reservation.undo', 'reservations', p_id, to_jsonb(r), '登録の間違いの取り消し');
    end if;
  else
    return json_build_object('error', 'bad_request');
  end if;
  return public.app_floor(p_device, p_secret);
end $$;
revoke execute on function public.app_undo(uuid,text,text,text) from public, authenticated;
grant execute on function public.app_undo(uuid,text,text,text) to anon;
