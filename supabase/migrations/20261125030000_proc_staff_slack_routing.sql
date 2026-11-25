-- 2026-11-25 代表の指示。
--  1) 顧客登録・データ移行は、担当を選んでから時間の計測を始める。手続きごとに担当を記録する。
--  2) 退勤時の文は、本人と、組織図で確かめた上司に送る。代表には、1日の終わりに店舗ごとの合計を1通で送る。
--     送信は slack_settings の mode（off／owner_only／on）で止められる。鍵は Vault にだけ置く。
create function pg_temp.patch(fn regprocedure, a text, b text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(fn);
begin
  if position(a in d) = 0 then raise exception 'patch target not found in %: %', fn, left(a, 50); end if;
  execute replace(d, a, b);
end $$;

-- 1) 手続きの担当
alter table public.visit_procedures
  add column staff_id integer references public.staff(staff_id),
  add column helper_id uuid references public.helpers(id);

select pg_temp.patch('public.app_save_visit(uuid,text,jsonb)',
  E'insert into public.visit_procedures(visit_id,kind,started_at,ended_at,skipped)
        values (vid, k, public.app__ts(p_visit->k->>''s''), public.app__ts(p_visit->k->>''e''), coalesce((p_visit->k->>''none'')::boolean, false))
        on conflict (visit_id, kind) do update set',
  E'insert into public.visit_procedures(visit_id,kind,started_at,ended_at,skipped,staff_id,helper_id)
        values (vid, k, public.app__ts(p_visit->k->>''s''), public.app__ts(p_visit->k->>''e''), coalesce((p_visit->k->>''none'')::boolean, false),
                (select ss.staff_id from public.staff_shops ss where ss.shop_id = s and (p_visit->k->>''by'') ~ ''^s[0-9]{1,9}$'' and ss.staff_id::text = substr(p_visit->k->>''by'', 2)),
                (select hp.id from public.helpers hp where hp.shop_id = s and (p_visit->k->>''by'') ~ ''^h[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'' and hp.id::text = lower(substr(p_visit->k->>''by'', 2))))
        on conflict (visit_id, kind) do update set
          staff_id = case when excluded.staff_id is not null or excluded.helper_id is not null then excluded.staff_id else public.visit_procedures.staff_id end,
          helper_id = case when excluded.staff_id is not null or excluded.helper_id is not null then excluded.helper_id else public.visit_procedures.helper_id end,');
select pg_temp.patch('public.app__visit(public.visits)',
  E'json_build_object(''s'',public.app__ms(p.started_at),''e'',public.app__ms(p.ended_at)',
  E'json_build_object(''s'',public.app__ms(p.started_at),''e'',public.app__ms(p.ended_at),''by'',coalesce(''s''||p.staff_id, ''h''||p.helper_id)');

-- 退勤時の文に、手続きの件数と平均時間を足す
select pg_temp.patch('public.app__day_text(uuid,boolean)',
  E'       || ''■卓での記録'' || E''\\n'' || act;',
  E'       || ''■卓での記録'' || E''\\n'' || act || E''\\n''
       || ''■手続き（担当した分）'' || E''\\n'' || (
            select ''顧客登録 '' || count(*) filter (where vp.kind = ''setup'') || ''件''
                   || coalesce(''（平均 '' || round(avg(extract(epoch from (vp.ended_at - vp.started_at))/60) filter (where vp.kind = ''setup'')) || ''分）'', '''')
                   || ''／データ移行 '' || count(*) filter (where vp.kind = ''move'') || ''件''
                   || coalesce(''（平均 '' || round(avg(extract(epoch from (vp.ended_at - vp.started_at))/60) filter (where vp.kind = ''move'')) || ''分）'', '''')
              from public.visits v join public.visit_procedures vp on vp.visit_id = v.id
             where v.shop_id = a.shop_id and (v.started_at at time zone ''Asia/Tokyo'')::date = a.work_date
               and vp.started_at is not null and vp.ended_at is not null
               and ((a.staff_id is not null and vp.staff_id = a.staff_id) or (a.helper_id is not null and vp.helper_id = a.helper_id)));');

-- 2) 送信先
alter table public.staff add column boss_name text, add column boss_slack_id text;
alter table public.slack_outbox
  add column to_user text,
  add column to_role text check (to_role in ('self','boss','owner')),
  add column request_id bigint,
  alter column shop_id drop not null,
  drop constraint slack_outbox_kind_check,
  drop constraint slack_outbox_status_check,
  add constraint slack_outbox_kind_check check (kind in ('day_close','day_close_undo','day_summary','test')),
  add constraint slack_outbox_status_check check (status in ('pending','sending','sent','failed','skipped'));
create table public.slack_settings (key text primary key, value text not null);
alter table public.slack_settings enable row level security;
revoke all on table public.slack_settings from public, anon, authenticated;
insert into public.slack_settings(key, value) values ('mode', 'off');

-- 送信（鍵が無い・mode が off のときは何もしない。失敗しても、呼び出し元の処理は止めない）
create function public.app__slack_flush() returns integer
language plpgsql security definer set search_path to '' as $$
declare md text; owner text; tok text; r record; rid bigint; n integer := 0;
begin
  select value into md from public.slack_settings where key = 'mode';
  if coalesce(md, 'off') not in ('owner_only', 'on') then return 0; end if;
  select value into owner from public.slack_settings where key = 'owner_slack_id';
  update public.slack_outbox set status = 'skipped', error = 'expired'
   where status = 'pending' and created_at < now() - interval '12 hours';
  update public.slack_outbox o
     set status = case when resp.status_code = 200 and resp.content like '%"ok":true%' then 'sent' else 'failed' end,
         error = case when resp.status_code = 200 and resp.content like '%"ok":true%' then null
                      else left(coalesce(substring(resp.content from '"error":"([^"]+)"'), resp.error_msg, 'http ' || coalesce(resp.status_code::text, '?')), 200) end
    from net._http_response resp
   where o.status = 'sending' and resp.id = o.request_id;
  update public.slack_outbox set status = 'failed', error = 'no_response'
   where status = 'sending' and sent_at < now() - interval '15 minutes';
  select ds.decrypted_secret into tok from vault.decrypted_secrets ds where ds.name = 'slack_bot_token' limit 1;
  if tok is null or tok = '' then return 0; end if;
  for r in select o.id, o.to_user, o.body from public.slack_outbox o
            where o.status = 'pending' and o.to_user is not null and (md = 'on' or o.to_user = owner)
            order by o.id limit 40 for update skip locked loop
    rid := net.http_post(
      url := 'https://slack.com/api/chat.postMessage',
      headers := jsonb_build_object('Authorization', 'Bearer ' || tok, 'Content-Type', 'application/json; charset=utf-8'),
      body := jsonb_build_object('channel', r.to_user, 'text', r.body, 'unfurl_links', false),
      timeout_milliseconds := 5000);
    update public.slack_outbox set status = 'sending', request_id = rid, sent_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
exception when others then
  return -1;
end $$;
revoke execute on function public.app__slack_flush() from public, anon, authenticated;

-- 退勤時の文を、本人と上司あてに積む。上司＝スタッフごとの指定（staff.boss_slack_id）→ 店舗の責任者 → 責任者本人のときはその上の人
create function public.app__slack_queue(p_shop integer, p_kind text, p_day date, p_actor text, p_body text) returns void
language plpgsql security definer set search_path to '' as $$
declare sid integer; self_id text; boss_id text;
begin
  if p_body is null then return; end if;
  if (select sh.is_demo from public.shops sh where sh.shop_id = p_shop) then
    insert into public.slack_outbox(shop_id,kind,work_date,actor,body,status) values (p_shop, p_kind, p_day, p_actor, p_body, 'skipped');
    return;
  end if;
  if p_actor ~ '^s[0-9]{1,9}$' then
    sid := substr(p_actor, 2)::integer;
    select st.slack_user_id, st.boss_slack_id into self_id, boss_id from public.staff st where st.staff_id = sid;
  end if;
  if boss_id is null then
    select case when sid is not null and nr.responsible_staff_id = sid then nr.fallback_slack_id else nr.responsible_slack_id end
      into boss_id from public.notify_routes nr where nr.shop_id = p_shop;
  end if;
  if boss_id is not distinct from self_id then boss_id := null; end if;
  if self_id is not null then
    insert into public.slack_outbox(shop_id,kind,work_date,actor,body,to_user,to_role) values (p_shop, p_kind, p_day, p_actor, p_body, self_id, 'self');
  end if;
  if boss_id is not null then
    insert into public.slack_outbox(shop_id,kind,work_date,actor,body,to_user,to_role) values (p_shop, p_kind, p_day, p_actor, p_body, boss_id, 'boss');
  end if;
  if self_id is null and boss_id is null then
    insert into public.slack_outbox(shop_id,kind,work_date,actor,body,status,error) values (p_shop, p_kind, p_day, p_actor, p_body, 'skipped', 'no_recipient');
  end if;
  perform public.app__slack_flush();
end $$;
revoke execute on function public.app__slack_queue(integer, text, date, text, text) from public, anon, authenticated;

select pg_temp.patch('public.app_day_close(uuid,text,text,jsonb)',
  E'insert into public.slack_outbox(shop_id,kind,work_date,actor,body,status)
    values (s, ''day_close'', a.work_date, p_actor, public.app__day_text(a.id, redo),
            case when (select sh.is_demo from public.shops sh where sh.shop_id = s) then ''skipped'' else ''pending'' end);',
  E'perform public.app__slack_queue(s, ''day_close'', a.work_date, p_actor, public.app__day_text(a.id, redo));');
select pg_temp.patch('public.app_undo(uuid,text,text,text)',
  E'insert into public.slack_outbox(shop_id,kind,work_date,actor,body,status)
        select s, ''day_close_undo'', a.work_date, p_id,
               ''【退勤の取り消し】'' || sh.name || ''　'' || coalesce((select st.display_name from public.staff st where st.staff_id = a.staff_id), (select hp.name from public.helpers hp where hp.id = a.helper_id))
               || ''さん　'' || to_char(a.work_date, ''FMMM/FMDD'') || E''\\n先ほどの「本日の数字」は取り消されました。退勤のときに入れ直されます。'',
               case when sh.is_demo then ''skipped'' else ''pending'' end
          from public.shops sh where sh.shop_id = s;',
  E'perform public.app__slack_queue(s, ''day_close_undo'', a.work_date, p_id, (select
               ''【退勤の取り消し】'' || sh.name || ''　'' || coalesce((select st.display_name from public.staff st where st.staff_id = a.staff_id), (select hp.name from public.helpers hp where hp.id = a.helper_id))
               || ''さん　'' || to_char(a.work_date, ''FMMM/FMDD'') || E''\\n先ほどの「本日の数字」は取り消されました。退勤のときに入れ直されます。''
          from public.shops sh where sh.shop_id = s));');

-- 代表あて：1日の終わりに、店舗ごとの合計を1通にまとめる
create function public.app__daily_summary_text(p_day date) returns text
language plpgsql stable security definer set search_path to '' as $$
declare sh record; t text := ''; n integer; w integer; pr integer; op integer; prods text; oc integer; os integer; fc integer; ft integer; cd integer;
  ov integer; ow integer; fv integer; fw integer; ai integer; ao integer; ae integer; shops integer := 0; tn integer := 0; tw integer := 0;
begin
  for sh in select s.shop_id, s.name from public.shops s
             where s.active and not s.is_demo
               and (exists (select 1 from public.visits v where v.shop_id = s.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = p_day)
                    or exists (select 1 from public.attendance a where a.shop_id = s.shop_id and a.work_date = p_day))
             order by s.shop_id loop
    select count(*), count(*) filter (where v.result = 'won'), count(*) filter (where v.ended_at is null),
           count(*) filter (where exists (select 1 from public.visit_segments g join public.segment_products sp on sp.segment_id = g.id where g.visit_id = v.id and sp.proposed_at is not null)),
           count(*) filter (where v.visit_type = 'out'), count(*) filter (where v.visit_type = 'out' and v.result = 'won'),
           count(*) filter (where v.visit_type = 'fix'), count(*) filter (where v.visit_type = 'fix' and v.result = 'won')
      into n, w, op, pr, ov, ow, fv, fw
      from public.visits v where v.shop_id = sh.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = p_day;
    with vp as (
      select g.visit_id, sp.product_key k, bool_or(sp.proposed_at is not null) p, bool_or(sp.won_at is not null) w,
             coalesce(sum(sp.qty) filter (where sp.won_at is not null), 0) q
        from public.visits v join public.visit_segments g on g.visit_id = v.id join public.segment_products sp on sp.segment_id = g.id
       where v.shop_id = sh.shop_id and (v.started_at at time zone 'Asia/Tokyo')::date = p_day group by 1, 2),
    x as (select vp.k, count(*) filter (where vp.p) pn, count(*) filter (where vp.w) wn, coalesce(sum(vp.q), 0) q from vp group by 1)
    select string_agg(coalesce(mp.short, mp.label) || ' ' || x.pn || '→' || x.wn || '組' || case when x.q > x.wn then '（' || x.q || '件）' else '' end, '、' order by mp.sort)
      into prods from x join public.m_products mp on mp.key = x.k where x.pn > 0 or x.wn > 0;
    select coalesce(sum(a.out_call), 0), coalesce(sum(a.out_stop), 0), coalesce(sum(a.fix_call), 0), coalesce(sum(a.fix_talk), 0), coalesce(sum(a.cards), 0),
           count(*), count(a.clocked_out_at), count(a.counts_at)
      into oc, os, fc, ft, cd, ai, ao, ae
      from public.attendance a where a.shop_id = sh.shop_id and a.work_date = p_day;
    shops := shops + 1; tn := tn + n; tw := tw + w;
    t := t || E'\n' || '■' || sh.name || E'\n'
       || '来店 ' || n || '組／成約 ' || w || '組' || case when n > 0 then '（' || round(100.0 * w / n, 1) || '%）' else '' end
       || '／提案した組 ' || pr || '組' || case when op > 0 then '／終了していない接客 ' || op || '件' else '' end || E'\n'
       || '商材（提案→獲得）：' || coalesce(prods, '提案なし') || E'\n'
       || 'アウトバウンド：声かけ ' || oc || '→立ち止まり ' || os || case when oc > 0 then '（' || round(100.0 * os / oc, 1) || '%）' else '' end || '→受付 ' || ov || '組→成約 ' || ow || '組' || E'\n'
       || '什器付き：声かけ ' || fc || '→立ち話 ' || ft || case when fc > 0 then '（' || round(100.0 * ft / fc, 1) || '%）' else '' end || '→受付 ' || fv || '組→成約 ' || fw || '組' || E'\n'
       || '名刺お渡し：' || cd || '枚' || E'\n'
       || '出勤 ' || ai || '名／退勤 ' || ao || '名／本日の数字の入力 ' || ae || '名' || case when ai > ae then '（未入力 ' || (ai - ae) || '名）' else '' end;
  end loop;
  t := '【店舗別の本日の実績】' || to_char(p_day, 'FMMM/FMDD') || '（' || (array['日','月','火','水','木','金','土'])[extract(dow from p_day)::integer + 1] || '）'
       || case when shops = 0 then E'\n' || '本日は、どの店舗にも記録がありません。'
               else t || case when shops > 1 then E'\n' || '■合計（' || shops || '店）' || E'\n' || '来店 ' || tn || '組／成約 ' || tw || '組'
                                                 || case when tn > 0 then '（' || round(100.0 * tw / tn, 1) || '%）' else '' end else '' end end;
  return t;
end $$;
revoke execute on function public.app__daily_summary_text(date) from public, anon, authenticated;

create function public.app__daily_summary_queue() returns void
language plpgsql security definer set search_path to '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date; owner text;
begin
  select value into owner from public.slack_settings where key = 'owner_slack_id';
  if owner is null or exists (select 1 from public.slack_outbox o where o.kind = 'day_summary' and o.work_date = d) then return; end if;
  insert into public.slack_outbox(kind,work_date,actor,body,to_user,to_role)
    values ('day_summary', d, 'system', public.app__daily_summary_text(d), owner, 'owner');
  perform public.app__slack_flush();
end $$;
revoke execute on function public.app__daily_summary_queue() from public, anon, authenticated;

-- 管理画面の文面の確認に、あて先の区別を出す
select pg_temp.patch('public.app__act_report(integer[],date,date)',
  E'select so.created_at, sn.name as shop, so.status, so.body from public.slack_outbox so',
  E'select so.created_at, sn.name as shop, so.status, so.to_role, so.body from public.slack_outbox so');
select pg_temp.patch('public.app__act_report(integer[],date,date)',
  E'''status'',o.status,''body'',o.body)',
  E'''status'',o.status,''to'',o.to_role,''body'',o.body)');
select pg_temp.patch('public.app__act_report(integer[],date,date)',
  E'order by so.created_at desc limit 8) o)',
  E'order by so.created_at desc, so.id limit 12) o)');

-- 送信に使う拡張と、定期実行（5分ごとに送信結果の確認と送り直し、毎日22:00に代表あての集計）。手元の試験用データベースには無いので飛ばす
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('tenpo-slack-flush', '*/5 * * * *', 'select public.app__slack_flush()');
    perform cron.schedule('tenpo-daily-summary', '0 13 * * *', 'select public.app__daily_summary_queue()');
  end if;
end $$;
