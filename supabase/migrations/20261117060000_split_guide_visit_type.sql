-- 来店区分「インバウンド 操作説明」を2つに分ける（2026-11-17 代表指示）。来店区分は9種になる。
update public.m_visit_types set label = 'インバウンド操作説明（サポート会員ヒアリングなし）',
       hint = 'サポート会員の操作説明。ヒアリングなしで始められます' where key = 'in_guide';
update public.m_visit_types set sort = sort + 1 where sort >= 2;
insert into public.m_visit_types(key,label,hint,grp,is_inbound,skips_hearing,sort) values
 ('in_guide_h','インバウンド操作説明（ヒアリングあり）','操作説明のご来店で、ヒアリングも行う場合','来店',true,false,2);
