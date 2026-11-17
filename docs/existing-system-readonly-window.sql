-- 【取り消し済み】2026-11-17 12:57 の代表決定（独立して作る）を受け、同日中に下の2文で取り消した。既存システムには何も残っていない。
-- 以下は、いったん作成したものの記録。

-- 既存システム（Supabase: selectsim-system / lrqjnkewkalnhnzglaxt）に 2026-11-17 に作成したもの
-- 佐藤代表の指示（2026-11-17 12:18）で実行。public の表・データ・関数は変更していない。
-- この文は記録用。新しいデータベース（tenpo-kanri）には実行しない。

create schema tenpo_ro;
create view tenpo_ro.shops as
  select id as shop_id, name, short_name, shop_type, employment_type as operator_type, agency_id, is_active from public.m_shops;
create view tenpo_ro.staff as
  select id as staff_id, name, shop_id, agency_id, outsource_company_id, employment_type, is_active, is_hidden, show_in_shift, is_test_account from public.m_staff;
create view tenpo_ro.staff_shops as
  select staff_id, shop_id from public.m_staff_shops;
create view tenpo_ro.shifts as
  select id as shift_id, staff_id, shop_id, shift_date, start_time, end_time, updated_at from public.t_shifts where shift_date >= current_date - 7;
create view tenpo_ro.outsource_companies as
  select id as company_id, name, is_active from public.m_outsource_companies;
create view tenpo_ro.staff_slack as
  select staff_id, slack_user_id, is_deliverable from public.m_staff_slack;
create role tenpo_reader nologin connection limit 3;
alter role tenpo_reader set default_transaction_read_only = on;
alter role tenpo_reader set statement_timeout = '10s';
grant usage on schema tenpo_ro to tenpo_reader;
grant select on all tables in schema tenpo_ro to tenpo_reader;

-- 取り消すとき（元に戻す）
-- drop schema tenpo_ro cascade;
-- drop role tenpo_reader;
