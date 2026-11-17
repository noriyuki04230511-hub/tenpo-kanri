-- 店舗管理システム データ設計 v1.0（2026-11-17・工程A）
-- 新しいデータベース専用。既存システム（selectsim-system）には実行しない。
-- 方針：①IDは端末側で作る（通信が切れて再送しても二重にならない）②時刻は自動 ③削除しない（取消は状態と理由で残す）
--      ④全ての表に権限設定（RLS）を掛け、方針を書くまでは誰も読めない状態にする ⑤お客様の氏名・電話番号の列を作らない

-- ========== 1. 既存システムの写し（読み取り専用。新アプリの画面からは編集しない） ==========
create table ref_shops (
  shop_id      integer primary key,
  name         text not null,
  is_partner   boolean not null default false,
  closes_at    time,
  in_scope     boolean not null default false,
  synced_at    timestamptz not null default now()
);
create table ref_staff (
  staff_id        integer primary key,
  display_name    text not null,
  home_shop_id    integer references ref_shops,
  role            text,
  employment_type text,
  slack_user_id   text,
  synced_at       timestamptz not null default now()
);
create table ref_shifts (
  shift_id    bigint primary key,
  staff_id    integer not null references ref_staff,
  shop_id     integer not null references ref_shops,
  shift_date  date not null,
  start_time  time,
  end_time    time,
  synced_at   timestamptz not null default now()
);
create index ref_shifts_shop_date on ref_shifts (shop_id, shift_date);
create table ref_outsource_companies (
  company_id  integer primary key,
  name        text not null,
  synced_at   timestamptz not null default now()
);

-- ========== 2. 本部が管理する共通の項目 ==========
create table m_visit_types (
  key            text primary key,
  label          text not null,
  hint           text not null,
  grp            text not null,
  is_inbound     boolean not null default false,
  skips_hearing  boolean not null default false,
  sort           integer not null,
  active         boolean not null default true
);
create table m_products (
  key     text primary key,
  label   text not null,
  sort    integer not null,
  active  boolean not null default true
);
create table m_hearing_questions (
  key     text primary key,
  label   text not null,
  prompt  text not null,
  sort    integer not null,
  active  boolean not null default true
);
create table m_hearing_options (
  id            uuid primary key default gen_random_uuid(),
  question_key  text not null references m_hearing_questions,
  label         text not null,
  sort          integer not null,
  active        boolean not null default true,
  unique (question_key, label)
);
create table m_suggest_rules (
  id           uuid primary key default gen_random_uuid(),
  product_key  text not null references m_products,
  condition    jsonb not null,
  reason       text not null,
  approved_by  text,
  approved_at  timestamptz,
  active       boolean not null default false
);
create table shop_custom_items (
  id          uuid primary key default gen_random_uuid(),
  shop_id     integer not null references ref_shops,
  label       text not null,
  options     jsonb not null default '[]',
  active      boolean not null default true,
  created_by  integer references ref_staff,
  created_at  timestamptz not null default now()
);

-- ========== 3. 端末・利用者・通知先 ==========
create table devices (
  id             uuid primary key default gen_random_uuid(),
  shop_id        integer not null references ref_shops,
  label          text not null,
  secret_hash    text not null,
  registered_by  integer references ref_staff,
  registered_at  timestamptz not null default now(),
  revoked_at     timestamptz
);
create table app_users (
  id               uuid primary key default gen_random_uuid(),
  auth_user_id     uuid unique,
  staff_id         integer unique references ref_staff,
  role             text not null check (role in ('manager','area','hq')),
  can_view_survey  boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
create table app_user_shops (
  user_id  uuid not null references app_users,
  shop_id  integer not null references ref_shops,
  primary key (user_id, shop_id)
);
create table notify_routes (
  shop_id               integer primary key references ref_shops,
  responsible_staff_id  integer references ref_staff,
  fallback_staff_id     integer references ref_staff,
  responsible_slack_id  text,
  fallback_slack_id     text,
  admin_channel         text not null,
  updated_by            uuid references app_users,
  updated_at            timestamptz not null default now()
);

-- ========== 4. 出勤・応援スタッフ ==========
create table helpers (
  id             uuid primary key,
  shop_id        integer not null references ref_shops,
  work_date      date not null,
  kind           text not null check (kind in ('event','outsource','carrier')),
  company_id     integer references ref_outsource_companies,
  company_other  text,
  name           text not null,
  device_id      uuid references devices,
  created_at     timestamptz not null default now()
);
create table attendance (
  id             uuid primary key,
  shop_id        integer not null references ref_shops,
  work_date      date not null,
  staff_id       integer references ref_staff,
  helper_id      uuid references helpers,
  shift_id       bigint references ref_shifts,
  clocked_in_at  timestamptz not null default now(),
  device_id      uuid references devices,
  check ((staff_id is null) <> (helper_id is null))
);
create unique index attendance_staff_once on attendance (shop_id, work_date, staff_id) where staff_id is not null;
create unique index attendance_helper_once on attendance (helper_id) where helper_id is not null;

-- ========== 5. 卓・予約 ==========
create table reservations (
  id             uuid primary key,
  shop_id        integer not null references ref_shops,
  no             text not null unique,
  reserved_at    timestamptz not null,
  purpose        text not null,
  staff_id       integer references ref_staff,
  status         text not null default 'booked' check (status in ('booked','seated','arrived','done','cancel','noshow')),
  seated_at      timestamptz,
  arrived_at     timestamptz,
  closed_at      timestamptz,
  created_by     integer references ref_staff,
  device_id      uuid references devices,
  created_at     timestamptz not null default now()
);
create index reservations_shop_time on reservations (shop_id, reserved_at);
create table tables (
  id              uuid primary key,
  shop_id         integer not null references ref_shops,
  name            text not null,
  is_auto         boolean not null default false,
  reservation_id  uuid references reservations,
  created_at      timestamptz not null default now(),
  removed_at      timestamptz
);
create index tables_shop_open on tables (shop_id) where removed_at is null;

-- ========== 6. 接客の記録（1組＝1行） ==========
create table visits (
  id                   uuid primary key,
  shop_id              integer not null references ref_shops,
  table_id             uuid not null references tables,
  visit_type           text not null references m_visit_types,
  reception_staff_id   integer references ref_staff,
  reception_helper_id  uuid references helpers,
  hearing_by           text check (hearing_by in ('customer','staff','none')),
  phase                text not null default 'hearing' check (phase in ('hearing','ready','serving','after','closed')),
  result               text check (result in ('won','lost')),
  started_at           timestamptz not null default now(),
  won_at               timestamptz,
  ended_at             timestamptz,
  auto_closed          boolean not null default false,
  reservation_id       uuid references reservations,
  member_code          text,
  device_id            uuid references devices,
  check ((reception_staff_id is null) <> (reception_helper_id is null))
);
create index visits_shop_started on visits (shop_id, started_at);
create index visits_open on visits (shop_id) where ended_at is null;
create table visit_hearings (
  visit_id      uuid primary key references visits,
  age_band      text not null,
  purpose       text,
  carrier       text,
  family_lines  text,
  home_net      text,
  extras        text[] not null default '{}',
  custom        jsonb not null default '{}',
  answered_at   timestamptz not null default now()
);
create table visit_segments (
  id          uuid primary key,
  visit_id    uuid not null references visits,
  staff_id    integer references ref_staff,
  helper_id   uuid references helpers,
  stage       text not null check (stage in ('serve','after')),
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  check ((staff_id is null) <> (helper_id is null))
);
create index visit_segments_visit on visit_segments (visit_id);
create table segment_products (
  segment_id   uuid not null references visit_segments,
  product_key  text not null references m_products,
  proposed_at  timestamptz,
  won_at       timestamptz,
  primary key (segment_id, product_key)
);
create table segment_actions (
  segment_id  uuid not null references visit_segments,
  action_key  text not null check (action_key in ('estimate','card','prospect')),
  done_at     timestamptz not null default now(),
  undone_at   timestamptz,
  primary key (segment_id, action_key)
);
create table visit_procedures (
  visit_id    uuid not null references visits,
  kind        text not null check (kind in ('setup','move')),
  started_at  timestamptz,
  ended_at    timestamptz,
  skipped     boolean not null default false,
  primary key (visit_id, kind)
);

-- ========== 7. お客様アンケート（個別の回答は閲覧者9名だけ。店長は月ごとの集計だけ） ==========
create table surveys (
  id          uuid primary key,
  shop_id     integer not null references ref_shops,
  visit_id    uuid not null unique references visits,
  answered    boolean not null,
  q_service   smallint check (q_service between 1 and 5),
  q_clarity   smallint check (q_clarity between 1 and 5),
  q_return    text check (q_return in ('yes','neutral','no')),
  created_at  timestamptz not null default now()
);

-- ========== 8. お知らせ・Slack送信の記録 ==========
create table alerts (
  id           uuid primary key default gen_random_uuid(),
  shop_id      integer not null references ref_shops,
  kind         text not null check (kind in ('clockin','setup','move','reservation_soon','reservation_late','unclosed')),
  ref_id       text not null,
  level        text not null check (level in ('warn','crit')),
  opened_at    timestamptz not null default now(),
  resolved_at  timestamptz
);
create unique index alerts_one_open on alerts (kind, ref_id) where resolved_at is null;
create index alerts_shop_open on alerts (shop_id) where resolved_at is null;
create table notification_sends (
  id         bigint generated always as identity primary key,
  alert_id   uuid not null references alerts,
  channel    text not null check (channel in ('slack_dm','slack_channel')),
  recipient  text not null,
  nth        integer not null default 1,
  sent_at    timestamptz not null default now(),
  status     text not null check (status in ('sent','failed','skipped')),
  error      text
);

-- ========== 9. 操作の履歴（誰が・どの端末で・いつ。追記だけで、変更も削除もできない） ==========
create table events (
  id               bigint generated always as identity primary key,
  at               timestamptz not null default now(),
  shop_id          integer references ref_shops,
  device_id        uuid references devices,
  actor_staff_id   integer references ref_staff,
  actor_helper_id  uuid references helpers,
  actor_user_id    uuid references app_users,
  action           text not null,
  target_table     text not null,
  target_id        text not null,
  before           jsonb,
  after            jsonb,
  reason           text
);
create index events_target on events (target_table, target_id);
create index events_shop_at on events (shop_id, at);

create function events_block_change() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '操作の履歴は変更・削除できません';
end;
$$;
create trigger events_no_update before update or delete on events
  for each row execute function events_block_change();

-- ========== 10. 全ての表に権限設定を掛ける（方針を書くまでは、画面側からは誰も読めない） ==========
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end;
$$;
