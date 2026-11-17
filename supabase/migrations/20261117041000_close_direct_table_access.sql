-- 画面側（anon・authenticated）から表を直接さわる権利をすべて外す。
-- 画面は app_ で始まる入口の関数だけを使うため、表への直接の権利は不要。権限設定（RLS）に加えた二重の鍵。
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;
