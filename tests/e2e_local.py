import asyncio, json, re, subprocess, os
from playwright.async_api import async_playwright
P='file:///home/claude/tenpo-kanri/public/index.html'
T={'p_device':'uuid','p_secret':'text','p_visit':'jsonb','p_resv':'jsonb','p_actor':'text','p_id':'uuid','p_kind':'text','p_company':'text','p_name':'text','p_op':'text','p_answered':'boolean','p_service':'integer','p_clarity':'integer','p_return':'text','p_label':'text','p_password':'text','p_new':'text','p_old':'text','p_from':'date','p_to':'date','p_shop':'integer','p_counts':'jsonb','p_goals':'jsonb'}
ENV=dict(os.environ,PGPASSWORD='x')
OFF={'v':False}; CALLS={'n':0,'err':[]}
def psql(sql,j=None,role=True):
    a=['psql','-h','127.0.0.1','-p','5544','-U','authenticator' if role else 'postgres','-d','tk2','-Atq','-v','ON_ERROR_STOP=1']
    if j is not None: a+=['-v','j='+j]
    return subprocess.run(a,input=sql,capture_output=True,text=True,env=ENV)
def admin(sql): 
    r=psql(sql,role=False); return (r.stdout+r.stderr).strip()
async def handler(route):
    if OFF['v']: return await route.abort()
    req=route.request; fn=req.url.rsplit('/',1)[1]
    assert re.fullmatch(r'app_[a-z_]+',fn), fn
    assert req.headers.get('apikey'), 'no apikey'
    body=json.loads(req.post_data or '{}')
    ty=lambda k:'uuid' if (fn=='app_survey' and k=='p_visit') else 'text' if (k=='p_id' and fn in ('app_login','app_set_password','app_change_password','app_undo')) else T[k]
    args=', '.join(f"{k} => "+(f"(:'j'::jsonb->'{k}')" if ty(k)=='jsonb' else f"(:'j'::jsonb->>'{k}')::{ty(k)}") for k in body)
    r=psql(f"set role anon;\nselect public.{fn}({args});\n",json.dumps(body))
    CALLS['n']+=1
    if r.returncode!=0:
        CALLS['err'].append((fn,r.stderr.strip()[:200]))
        return await route.fulfill(status=403 if ('device_not_registered' in r.stderr or 'forbidden' in r.stderr) else 400,content_type='application/json',body=json.dumps({'message':r.stderr}))
    await route.fulfill(status=200,content_type='application/json',body=r.stdout.strip())
async def newpage(b,w,h):
    ctx=await b.new_context(viewport={'width':w,'height':h}); pg=await ctx.new_page(); errs=[]
    pg.on('pageerror',lambda e:errs.append(str(e)))
    await pg.route('**/rest/v1/rpc/*',handler); await pg.goto(P); await pg.click('#start-demo'); await pg.wait_for_selector('#add-table',timeout=15000)
    return pg,errs
async def saved(pg): await pg.wait_for_function("document.getElementById('net').textContent==='保存済み'",timeout=20000)
tiles=lambda pg: pg.locator('button.tile:not(.addt)')
async def gone(pg): await pg.wait_for_function("!document.querySelector('#modal .dlg')",timeout=20000)
ATT="select count(*) from attendance where shop_id=9000 and work_date=(now() at time zone 'Asia/Tokyo')::date"
async def hear(pg,age):
    b=pg.locator(f'[data-k="age"][data-v="{age}"]')
    if await b.get_attribute('aria-pressed')!='true': await b.click()
    for k in ['purpose','carrier','lines','net']: await pg.locator(f'[data-k="{k}"]').first.click()
async def run(b,tag,w,h):
    pg,errs=await newpage(b,w,h)
    async def shot(n):
        r=await pg.evaluate("({sw:document.documentElement.scrollWidth,cw:document.documentElement.clientWidth})")
        if r['sw']>r['cw']+1: print(tag,n,'OVERFLOW',r)
        await pg.screenshot(path=f'/home/claude/a_{tag}_{n}.png')
    GL="""select coalesce(string_agg(coalesce('s'||staff_id,'h')||':'||coalesce(goal_out::text,'-')||'/'||coalesce(goal_mobile::text,'-'),' ' order by clocked_in_at),'none') from attendance where shop_id=9000 and work_date=(now() at time zone 'Asia/Tokyo')::date"""
    print(tag,'tables',await tiles(pg).count(),'not clocked',await pg.locator('[id^="in-"]').count(),'| goal-missing marks',await pg.locator('[id^="gls-"]').count())
    a0=admin(ATT); await pg.locator('[id^="in-"]').first.click(); print(tag,'clock-in -> screen',await pg.text_content('#tb-t'),'|',await pg.text_content('.box h2'),'| inputs',await pg.locator('.cnt-g input').count(),'| attendance before save',a0,'->',admin(ATT))
    await pg.click('#gs-save'); print(tag,'goals empty ->',await pg.text_content('#gs-err')); await pg.fill('#gs-go','1x0'); print(tag,'non-digit stripped ->',await pg.input_value('#gs-go')); await pg.fill('#gs-gm','5'); await shot('daystart'); await ov(pg,tag,'daystart')
    await pg.click('#gs-cancel'); print(tag,'cancel -> screen',await pg.text_content('#tb-t'),'| attendance',admin(ATT))
    await pg.locator('[id^="in-"]').first.click(); await pg.fill('#gs-go','10'); await pg.fill('#gs-gm','5'); await pg.click('#gs-save'); await saved(pg); print(tag,'clocked in with goals: attendance',admin(ATT),'| goals',admin(GL))
    lid=await pg.locator('[id^="gl-"]').first.get_attribute('data-id'); await pg.locator('[id^="gl-"]').first.click(); print(tag,'late goals -> title',await pg.text_content('#tb-t'),'| save label',(await pg.text_content('#gs-save')).strip()); await pg.fill('#gs-go','3'); await pg.fill('#gs-gm','1'); await pg.click('#gs-save'); await saved(pg); print(tag,'late goals saved: mark',await pg.locator(f'#gls-{lid}').count(),'| goals',admin(GL))
    await shot('home'); await saved(pg)
    # 押し間違いの取り消し：出勤
    a0=admin(ATT); await pg.locator('.person .un').last.click(); await shot('modal')
    print(tag,'popup:',await pg.text_content('#dlg-t'),'|',await pg.text_content('#dlg-gone'),'| focus on',await pg.evaluate("document.activeElement.id"))
    await pg.click('#dlg-no'); print(tag,'cancel keeps data: modal',await pg.locator('#modal .dlg').count(),'attendance',a0,'->',admin(ATT))
    await pg.locator('.person .un').last.click(); await pg.click('#dlg-yes'); await gone(pg)
    print(tag,'clock-in undone: attendance',a0,'->',admin(ATT),'| not clocked',await pg.locator('[id^="in-"]').count(),'| history',admin("select count(*) from events where action='attendance.undo' and before is not null"))
    await pg.locator('[id^="in-"]').first.click(); await pg.fill('#gs-go','10'); await pg.fill('#gs-gm','5'); await pg.click('#gs-save'); await saved(pg)
    # 退勤と、その取り消し
    OUT="select count(*) from attendance where shop_id=9000 and clocked_out_at is not null and work_date=(now() at time zone 'Asia/Tokyo')::date"
    CNT="select coalesce(out_call::text,'null')||'/'||coalesce(out_stop::text,'null')||'/'||coalesce(fix_call::text,'null')||'/'||coalesce(fix_talk::text,'null')||'/'||coalesce(cards::text,'null')||' counts_at '||(counts_at is not null) from attendance where shop_id=9000 and work_date=(now() at time zone 'Asia/Tokyo')::date order by clocked_out_at desc nulls last limit 1"
    await pg.locator('[data-a="clockout"]').last.click(); print(tag,'day-end form:',await pg.text_content('#tb-t'),'|',await pg.text_content('.box h2'),'| inputs',await pg.locator('.cnt-g input').count(),'| db out before save',admin(OUT))
    await pg.click('#de-save'); print(tag,'empty ->',await pg.text_content('#de-err'))
    await pg.fill('#de-oc','10'); await pg.fill('#de-os','12'); await pg.fill('#de-fc','20'); await pg.fill('#de-ft','5'); await pg.fill('#de-cd','3'); await pg.click('#de-save'); print(tag,'stop>call ->',(await pg.text_content('#de-err'))[:30],'| db out',admin(OUT))
    await pg.fill('#de-os','4a'); print(tag,'non-digit stripped ->',await pg.input_value('#de-os')); await pg.fill('#de-os','4'); await pg.wait_for_selector('#pg-dl,#pg-ng',timeout=15000); print(tag,'progress box:',(await pg.text_content('#de-pg'))[:86]); await pg.locator('section.box').first.screenshot(path=f'/home/claude/a_{tag}_dayendbox.png'); await shot('dayend'); await ov(pg,tag,'dayend')
    await pg.click('#de-cancel'); print(tag,'cancel -> screen',await pg.text_content('#tb-t'),'| db out',admin(OUT))
    await pg.locator('[data-a="clockout"]').last.click(); await pg.fill('#de-oc','40'); await pg.fill('#de-os','8'); await pg.fill('#de-fc','25'); await pg.fill('#de-ft','6'); await pg.fill('#de-cd','5'); await pg.click('#de-save'); await saved(pg); await shot('out')
    print(tag,'saved: db counts',admin(CNT),'| card',(await pg.locator('.person.off').last.text_content()).strip()[:60],'| outbox',admin("select kind||'/'||status||'/'||replace(left(body,26),E'\\n',' ') from slack_outbox order by id desc limit 1"))
    await tiles(pg).nth(0).click(); rc=await pg.locator('[data-a="recv"]').count(); await pg.click('#go-home')
    print(tag,'clock-out: db',admin(OUT),'| status',await pg.locator('.person.off .st').last.text_content(),'| selectable at reception',rc,'of 4')
    await pg.locator('[data-k="clock_out"]').first.click(); print(tag,'clock-out undo popup:',await pg.text_content('#dlg-t'),'|',await pg.text_content('#dlg-gone'),'|',(await pg.text_content('#dlg-sub'))[:22]); await pg.click('#dlg-yes'); await gone(pg)
    print(tag,'undo clears counts:',admin("select count(*) from attendance where shop_id=9000 and counts_at is not null"),'| outbox',admin("select kind from slack_outbox order by id desc limit 1"))
    # 古い画面で退勤だけした人は、あとから数字を入れられる
    oid=await pg.evaluate("(async()=>{const s=S.staff.filter(x=>x.inAt&&!x.outAt).pop(); await call('app_clock_out',{p_device:DEV.device,p_secret:DEV.secret,p_actor:s.id}); await poll(); render(); return s.id})()")
    print(tag,'out w/o counts: status',await pg.text_content(f'#cs-{oid}'),'| enter button',await pg.locator(f'#cnt-{oid}').count()); await pg.click(f'#cnt-{oid}'); print(tag,'late form: title',await pg.text_content('#tb-t'),'| save label',(await pg.text_content('#de-save')).strip())
    for k,v in (('oc','0'),('os','0'),('fc','7'),('ft','2'),('cd','1')): await pg.fill(f'#de-{k}',v)
    await pg.click('#de-save'); await saved(pg); print(tag,'late saved: status',await pg.text_content(f'#cs-{oid}'),'| enter button',await pg.locator(f'#cnt-{oid}').count(),'| db',admin(CNT))
    await pg.click(f'#uo-{oid}'); await pg.click('#dlg-yes'); await gone(pg)
    print(tag,'clock-out undone: db',admin(OUT),'| on duty buttons',await pg.locator('[data-a="clockout"]').count(),'| history',admin("select count(*) from events where action in ('attendance.clock_out','attendance.clock_out_undo')"))
    # 応援スタッフ
    await pg.click('#add-help'); print(tag,'company options',await pg.locator('#help-co option').all_text_contents(),'| other input before',await pg.locator('#help-co-other').count())
    await pg.select_option('#help-co','その他（会社名を入力）'); await pg.fill('[data-f="name"]','試験'); await pg.click('#help-save'); print(tag,'other w/o name:',await pg.text_content('#help-err'),'| helpers',admin("select count(*) from helpers"))
    await pg.fill('#help-co-other','試験商事'); await pg.click('#help-save'); print(tag,'after helper add -> screen',await pg.text_content('#tb-t'),'|',(await pg.text_content('#gs-save')).strip()); await pg.fill('#gs-go','6'); await pg.fill('#gs-gm','0'); await pg.click('#gs-save'); await saved(pg); print(tag,'helper goals',admin("select goal_out||'/'||goal_mobile from attendance where helper_id is not null order by clocked_in_at desc limit 1")); print(tag,'other saved:',admin("select company_other||'/'||coalesce(company_id::text,'-') from helpers order by created_at desc limit 1"),'| card',(await pg.locator('.person:not(.add)').last.text_content()).strip()[:40])
    await pg.locator('[data-k="helper"]').last.click(); await pg.click('#dlg-yes'); await gone(pg)
    await pg.click('#add-help'); await pg.fill('[data-f="name"]','試験'); await pg.click('#help-save'); await pg.click('#gs-cancel'); await saved(pg); h0=admin("select count(*) from helpers"); p0=await pg.locator('.person:not(.add)').count()
    await pg.locator('[data-k="helper"]').last.click(); t=await pg.text_content('#dlg-t'); await pg.click('#dlg-yes'); await gone(pg)
    print(tag,'helper undone:',t,'| helpers',h0,'->',admin("select count(*) from helpers"),'| cards',p0,'->',await pg.locator('.person:not(.add)').count())
    # full flow
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-out')
    await pg.click('[data-k="age"][data-v="70〜74歳"]'); await pg.click('#extra-0'); print(tag,'age only: disabled',await pg.is_disabled('#sh-done'),'|',await pg.text_content('#sh-left')); await hear(pg,'70〜74歳'); print(tag,'all 5: disabled',await pg.is_disabled('#sh-done'),'|',await pg.text_content('#sh-left')); await pg.click('#sh-done'); await pg.locator('[data-a="pick"]').first.click()
    await pg.click('#p-net'); await pg.click('#w-carrier'); await pg.click('#act-est'); await saved(pg)
    await pg.click('#go-back'); print(tag,'back ->',await pg.text_content('#tb-t')); await saved(pg)
    print(tag,'segments after back',admin("select count(*) from visit_segments g join visits v on v.id=g.visit_id where v.ended_at is null"))
    await pg.locator('[data-a="pick"]').first.click(); await pg.click('#p-net'); print(tag,'qty hidden before win',await pg.locator('#q-carrier').count()==0); await pg.click('#w-carrier'); print(tag,'qty default',(await pg.text_content('#qv-carrier')),'minus disabled',await pg.is_disabled('#qm-carrier'))
    await pg.click('#qp-carrier'); await pg.click('#qp-carrier'); await pg.click('#qm-carrier'); await saved(pg); await shot('qty')
    print(tag,'qty ui',await pg.text_content('#qv-carrier'),'| sum',(await pg.text_content('.action .sum')).strip(),'| db',admin("select sp.product_key||'='||sp.qty from segment_products sp join visit_segments g on g.id=sp.segment_id join visits v on v.id=g.visit_id where v.ended_at is null and sp.won_at is not null"))
    print(tag,'end disabled with win',await pg.is_disabled('#serve-end'),'| why shown',await pg.locator('#end-why').count())
    srv=await pg.evaluate("(async()=>{const p=JSON.parse(JSON.stringify(V())); p.closed=true; p.result='lost'; try{await call('app_save_visit',{p_device:DEV.device,p_secret:DEV.secret,p_visit:p}); return 'accepted'}catch(e){return e.status+' '+String(e.body).slice(0,90)}})()")
    print(tag,'server on lost close with win:',srv,'| still open',admin("select count(*) from visits where ended_at is null"))
    await pg.click('#w-carrier'); print(tag,'after unpress: end disabled',await pg.is_disabled('#serve-end'),'| why shown',await pg.locator('#end-why').count(),'| won disabled',await pg.is_disabled('#serve-won'),'|',await pg.text_content('#won-why')); await saved(pg); await shot('nowin')
    srv=await pg.evaluate("(async()=>{const p=JSON.parse(JSON.stringify(V())); p.phase='after'; p.result='won'; try{await call('app_save_visit',{p_device:DEV.device,p_secret:DEV.secret,p_visit:p}); return 'accepted'}catch(e){return e.status+' '+String(e.body).slice(0,90)}})()")
    print(tag,'server on won with 0 product:',srv,'| result in db',admin("select coalesce(result,'null')||'/'||phase from visits where ended_at is null"))
    await pg.click('#w-carrier'); print(tag,'with win: won disabled',await pg.is_disabled('#serve-won'),'| won-why',await pg.locator('#won-why').count()); await pg.click('#qp-carrier'); await saved(pg)
    sv=await pg.evaluate("(async()=>{const id=seg(V()).sid; const r=await call('app_clock_out',{p_device:DEV.device,p_secret:DEV.secret,p_actor:id}); A.clockout({id}); render(); return (r.error||'accepted')+' | '+document.getElementById('dlg-t').textContent+' | '+document.getElementById('dlg-err').textContent})()")
    print(tag,'clock-out while serving:',sv); await pg.click('#dlg-no'); await gone(pg)
    await pg.click('#serve-won'); await pg.locator('[data-a="pick"]').nth(1).click()
    PR="select coalesce(string_agg(p.kind||':'||(p.started_at is not null)||':'||coalesce('s'||p.staff_id,'h'||p.helper_id,'none'),' ' order by p.kind),'no rows') from visit_procedures p join visits v on v.id=p.visit_id where v.ended_at is null"
    print(tag,'after pick -> screen',await pg.text_content('#tb-t'),'|',await pg.text_content('.sec h2'),'| setup-start button',await pg.locator('#setup-start').count(),'| staff choices',await pg.locator('[data-a="procwho"]').count(),'| skip link',await pg.locator('#pw-back').count()); await saved(pg); await shot('procwho'); await ov(pg,tag,'procwho')
    print(tag,'before choosing: db procedures',admin(PR)); tid=await pg.evaluate("S.tid"); await pg.click('#go-home'); await pg.click(f'[data-a="table"][data-id="{tid}"]'); print(tag,'reopen table -> screen',await pg.text_content('#tb-t'))
    who=await pg.locator('[data-a="procwho"]').nth(1).get_attribute('data-id'); await pg.locator('[data-a="procwho"]').nth(1).click(); await saved(pg); print(tag,'chosen',who,'-> screen',await pg.text_content('#tb-t'),'| shown',await pg.text_content('#setup-by'),'| db',admin(PR))
    await pg.click('#move-start'); print(tag,'move start -> screen',await pg.text_content('#tb-t'),'|',await pg.text_content('.sec h2'),'| skip link',await pg.locator('#pw-back').count()); await pg.click('#pw-back'); print(tag,'not yet -> screen',await pg.text_content('#tb-t'),'| db',admin(PR))
    await pg.click('#move-start'); await pg.locator('[data-a="procwho"]').first.click(); await saved(pg); print(tag,'move chosen: shown',await pg.text_content('#move-by'),'| db',admin(PR))
    await pg.wait_for_timeout(5600); await shot('after')
    print(tag,'carrier hidden',await pg.query_selector('#p-carrier') is None, 'title',await pg.text_content('#tb-t'))
    await pg.click('#setup-end'); await pg.click('#move-end'); await pg.click('#a-5'); await pg.click('#b-4'); await pg.click('#c-0'); await pg.click('#sv-send'); await pg.click('#thanks-back'); await saved(pg)
    print(tag,'end ->',await pg.text_content('#tb-t'),'tables',await tiles(pg).count())
    # guide skip
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').nth(1).click(); await pg.click('#type-in_guide'); print(tag,'guide ->',await pg.text_content('#tb-t')); await pg.click('#serve-end'); await saved(pg)
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').nth(1).click(); await pg.click('#type-in_guide_h'); print(tag,'guide with hearing ->',await pg.text_content('#tb-t'),'| types',await pg.evaluate("9")); await pg.click('#mode-staff'); await hear(pg,'60〜64歳'); await pg.click('#sh-done'); await pg.locator('[data-a="pick"]').first.click(); await pg.click('#serve-end'); await saved(pg)
    # ヒアリングの途中で終了（成約なし）
    LAST="select phase||'/'||coalesce(result,'null')||'/'||coalesce(hearing_by,'null')||'/h'||(select count(*) from visit_hearings h where h.visit_id=v.id)||'/g'||(select count(*) from visit_segments g where g.visit_id=v.id)||'/ended '||(ended_at is not null) from visits v order by started_at desc limit 1"
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').nth(1).click(); await pg.click('#type-in_guide_h'); await pg.click('#hear-end'); await shot('endhear')
    print(tag,'end at mode: dlg',await pg.text_content('#dlg-t'),'|',(await pg.text_content('#dlg-sub'))[:40],'| gone text',await pg.locator('#dlg-gone').count()); await pg.click('#dlg-no'); await gone(pg)
    await pg.click('#mode-cust'); print(tag,'cust screen link',(await pg.text_content('#hear-end')).strip()); await pg.click('#opt-0'); await pg.click('#q-next'); await pg.click('#hear-end'); await pg.click('#dlg-yes'); await gone(pg); await saved(pg)
    print(tag,'ended at cust q2 ->',await pg.text_content('#tb-t'),'| db',admin(LAST),'| open',admin("select count(*) from visits where ended_at is null"))
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-out'); await pg.click('[data-k="age"][data-v="70〜74歳"]'); await pg.click('#hear-end'); await pg.click('#dlg-yes'); await gone(pg); await saved(pg)
    print(tag,'ended at staffhear (1 of 5) -> db',admin(LAST))
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-out'); await hear(pg,'60〜64歳'); await pg.click('#sh-done'); await pg.click('#hear-end'); await pg.click('#dlg-yes'); await gone(pg); await saved(pg)
    print(tag,'ended at pick (hearing done) -> db',admin(LAST),'| tables',await tiles(pg).count())
    # お客様記入：7問（きっかけ → 5問 → ご契約者様）
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-in_guide_h'); await pg.click('#mode-cust')
    print(tag,'cust Q1:',await pg.text_content('.paper h2'),'| options',await pg.locator('.opt').count(),'|',(await pg.text_content('.lead span')).strip()); await shot('q1'); await ov(pg,tag,'q1')
    await pg.click('#opt-1'); await pg.click('#q-next'); await pg.click('#opt-4'); await pg.click('#q-next'); await pg.click('#opt-0'); await pg.click('#q-next'); await pg.click('#opt-0'); await pg.click('#q-next'); await pg.click('#opt-1'); await pg.click('#q-next')
    print(tag,'cust Q6:',await pg.text_content('.paper h2'),'| options',await pg.locator('.opt').all_text_contents()); await shot('q6'); await ov(pg,tag,'q6'); await pg.click('#opt-2'); await pg.click('#q-next')
    print(tag,'cust Q7 note:',(await pg.text_content('#q-note'))[:30],'|',await pg.text_content('.paper h2'),'| options',await pg.locator('.opt').all_text_contents(),'| next',(await pg.text_content('#q-next')).strip()); await shot('q7'); await ov(pg,tag,'q7')
    await pg.click('#opt-1'); await pg.click('#q-next'); await pg.click('#cust-done'); await pg.locator('[data-a="pick"]').first.click(); await saved(pg)
    print(tag,'serve: owner warning',await pg.locator('#own-warn').count(),'| memo',(await pg.text_content('.memo'))[-58:],'| cable suggestion','ケーブルテレビ' in (await pg.text_content('.box .grid')))
    print(tag,'db hearing',admin("select source||' / '||owner_present||' / '||home_net from visit_hearings order by answered_at desc limit 1")); await shot('ownwarn'); await ov(pg,tag,'ownwarn')
    await pg.click('#serve-end'); await saved(pg)
    # back = void
    n0=admin("select count(*) from visits")
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-in_meo'); await saved(pg)
    n1=admin("select count(*) from visits"); await pg.click('#go-back'); print(tag,'void popup:',await pg.text_content('#dlg-t'),'|',await pg.text_content('#dlg-gone')); await pg.click('#dlg-no'); print(tag,'void cancelled: visits',admin("select count(*) from visits"),'title',await pg.text_content('#tb-t')); await pg.click('#go-back'); await pg.click('#dlg-yes'); await saved(pg)
    print(tag,'void: visits',n0,'->',n1,'->',admin("select count(*) from visits"),'title',await pg.text_content('#tb-t'))
    await pg.click('#go-home')
    # reservation register + cancel
    await pg.click('#role-resv'); await pg.click('#resv-new')
    d=await pg.evaluate("(()=>{const d=new Date(Date.now()+3*3600e3);const p=n=>String(n).padStart(2,'0');return [d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate()),p(d.getHours())+':'+p(d.getMinutes())]})()")
    await pg.fill('#rf-date',d[0]); await pg.fill('#rf-time',d[1]); await pg.click('#rf-save'); await saved(pg); await shot('resv')
    print(tag,'resv rows',await pg.locator('.rv').count(),'nos',await pg.evaluate("[...document.querySelectorAll('.rv .w span')].map(e=>(e.textContent.match(/R-\\d+|採番中/)||[''])[0]).join(',')"))
    r0=admin("select count(*) from reservations where shop_id=9000"); await pg.locator('[data-k="reservation"]').last.click(); tt=await pg.text_content('#dlg-t'); sub=await pg.text_content('#dlg-sub'); await pg.click('#dlg-yes'); await gone(pg)
    print(tag,'resv deleted:',tt,'| rows',await pg.locator('.rv').count(),'| db',r0,'->',admin("select count(*) from reservations where shop_id=9000"),'| cancel note','キャンセル' in sub,'| counted as cancel',admin("select count(*) from reservations where shop_id=9000 and status='cancel'"))
    await pg.click('#resv-new'); await pg.fill('#rf-date',d[0]); await pg.fill('#rf-time',d[1]); await pg.click('#rf-save'); await saved(pg)
    n1=await pg.locator('.rv').count(); print(tag,'first at this time: no dialog',await pg.locator('#modal .dlg').count(),'rows',n1)
    await pg.click('#resv-new'); await pg.fill('#rf-date',d[0]); await pg.fill('#rf-time',d[1]); await pg.click('#rf-save'); await shot('dupresv')
    print(tag,'dup dialog:',await pg.text_content('#dlg-t'),'|',await pg.text_content('#dlg-sub'),'|',(await pg.text_content('#dlg-no')).strip(),'/',(await pg.text_content('#dlg-yes')).strip()); await pg.click('#dlg-no'); await gone(pg)
    print(tag,'dup cancel -> screen',await pg.text_content('#tb-t'),'| db',admin("select count(*) from reservations where shop_id=9000 and status='booked'"))
    await pg.click('#rf-save'); await pg.click('#dlg-yes'); await gone(pg); await saved(pg); print(tag,'dup accepted: rows',n1,'->',await pg.locator('.rv').count(),'| db same time',admin("select max(c) from (select count(*) c from reservations where shop_id=9000 and status='booked' group by reserved_at) x"))
    await pg.locator('[data-k="reservation"]').last.click(); await pg.click('#dlg-yes'); await gone(pg)
    await pg.locator('[data-a="rcancel"]').last.click(); await saved(pg)
    # reservation due -> auto table -> no-show
    admin("update reservations set reserved_at=now()+interval '10 minutes' where id=(select id from reservations where status='booked' order by reserved_at limit 1)")
    await pg.click('#role-staff'); await pg.wait_for_function("document.querySelectorAll('button.tile.rsv').length===1",timeout=15000); await shot('rsv')
    print(tag,'auto table: tiles',await tiles(pg).count(),'alert badge',await pg.text_content('.b-alert') if await pg.locator('.b-alert').count() else '-')
    await pg.locator('button.tile.rsv').click(); await pg.click('#resv-noshow'); await saved(pg); print(tag,'after noshow tiles',await tiles(pg).count())
    await pg.click('#add-table'); await saved(pg); a=await tiles(pg).count(); t0=admin("select count(*) from tables where shop_id=9000"); await pg.click('#rm-table'); tt=await pg.text_content('#dlg-t'); await pg.click('#dlg-yes'); await gone(pg); print(tag,'add/remove',a,'->',await tiles(pg).count(),'|',tt,'| table rows',t0,'->',admin("select count(*) from tables where shop_id=9000"))
    await pg.locator('.person .un').first.click(); await pg.click('#dlg-yes'); await pg.wait_for_selector('#dlg-err'); print(tag,'in use ->',await pg.text_content('#dlg-err'),'| attendance',admin(ATT)); await pg.click('#dlg-no'); await gone(pg)
    await pg.click('#role-mgr'); await shot('mgr'); print(tag,'mgr kpi',await pg.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join('/')"))
    # offline
    await pg.click('#role-staff'); OFF['v']=True
    await tiles(pg).nth(0).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-fix'); await hear(pg,'30代'); await pg.click('#sh-done'); await pg.locator('[data-a="pick"]').first.click(); await pg.click('#p-coat')
    await pg.wait_for_timeout(1500); print(tag,'offline msg:',await pg.text_content('#net'),'| screen',await pg.text_content('#tb-t')); await shot('offline')
    OFF['v']=False; await saved(pg)
    print(tag,'after reconnect:',admin("select v.visit_type||' '||v.phase||' h='||(select age_band from visit_hearings h where h.visit_id=v.id)||' prod='||(select count(*) from segment_products sp join visit_segments g on g.id=sp.segment_id where g.visit_id=v.id) from visits v where v.ended_at is null"))
    await pg.click('#serve-end'); await saved(pg)
    print(tag,'errors',errs); return pg
K='file:///home/claude/tenpo-kanri/public/kanri.html'
async def ov(pg,tag,n):
    r=await pg.evaluate("({sw:document.documentElement.scrollWidth,cw:document.documentElement.clientWidth})")
    if r['sw']>r['cw']+1: print(tag,n,'OVERFLOW',r)
    await pg.screenshot(path=f'/home/claude/a_{tag}_{n}.png')
async def run_login(b,tag,w,h,first):
    ctx=await b.new_context(viewport={'width':w,'height':h}); pg=await ctx.new_page(); errs=[]
    pg.on('pageerror',lambda e:errs.append(str(e)))
    await pg.route('**/rest/v1/rpc/*',handler); await pg.goto(P); await pg.wait_for_selector('#lg-id'); await ov(pg,tag,'start')
    PW='local-test-pass-1'
    await pg.fill('#lg-id','shiken'); await pg.fill('#lg-pw','wrong-one'); await pg.click('#lg-go')
    if first:
        await pg.wait_for_selector('#lg-new'); await pg.fill('#lg-new','short'); await pg.fill('#lg-new2','short'); await pg.click('#lg-go'); print(tag,'short ->',await pg.text_content('#lg-err'))
        await pg.fill('#lg-new',PW); await pg.fill('#lg-new2',PW+'x'); await pg.click('#lg-go'); print(tag,'mismatch ->',await pg.text_content('#lg-err'))
        await pg.fill('#lg-new',PW); await pg.fill('#lg-new2',PW); await pg.click('#lg-go')
    else:
        await pg.wait_for_selector('#lg-err'); print(tag,'wrong pw ->',await pg.text_content('#lg-err'))
        await pg.fill('#lg-pw',PW); await pg.click('#lg-go')
    await pg.wait_for_selector('#add-table',timeout=15000)
    print(tag,'logged in: shop',await pg.text_content('.b-box b'),'| bar',await pg.text_content('#who'),'| staff',await pg.locator('.person:not(.add)').count(),'| mgr tab',await pg.text_content('#mgr-label'),'| kanri link',await pg.locator('#to-kanri').count(),'| reset btn',await pg.locator('#demo-reset').count())
    if await pg.locator('[id^="in-"]').count(): await pg.locator('[id^="in-"]').first.click(); await pg.fill('#gs-go','2'); await pg.fill('#gs-gm','1'); await pg.click('#gs-save'); await saved(pg)
    if await tiles(pg).count()==0: await pg.click('#add-table'); await saved(pg)
    await tiles(pg).nth(0).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-in_guide'); await pg.click('#p-support'); await pg.click('#serve-end'); await saved(pg)
    await pg.click('#role-mgr'); print(tag,'table role: kpi tiles',await pg.locator('.kpi').count(),'title',await pg.text_content('#tb-t')); await ov(pg,tag,'notice')
    await pg.click('#logout'); await pg.wait_for_selector('#lg-id'); print(tag,'after logout: start screen',await pg.locator('#start-demo').count())
    # パスワードを変える（手元の使い捨てデータベースの試験用の値。最後に元へ戻す）
    PW2='local-test-pass-9'
    await pg.fill('#lg-id','shiken'); await pg.fill('#lg-pw',PW); await pg.click('#lg-go'); await pg.wait_for_selector('#add-table',timeout=15000)   # 1台ログインした状態にする
    dv0=admin("select count(*) from devices where login_id='shiken' and revoked_at is null")
    await pg.evaluate("store.del('tk_dev')"); await pg.reload(); await pg.wait_for_selector('#lg-id')
    await pg.fill('#lg-id','shiken'); await pg.click('#lg-chg'); await pg.wait_for_selector('#cg-old'); print(tag,'change form: id carried',await pg.input_value('#cg-id'))
    await pg.fill('#cg-old','wrong-one'); await pg.fill('#cg-new',PW2); await pg.fill('#cg-new2',PW2); await pg.click('#lg-go'); await pg.wait_for_selector('#lg-err'); print(tag,'wrong old ->',await pg.text_content('#lg-err'))
    await pg.fill('#cg-old',PW); await pg.fill('#cg-new',PW2); await pg.fill('#cg-new2',PW2+'x'); await pg.click('#lg-go'); await pg.wait_for_function("document.getElementById('lg-err')&&document.getElementById('lg-err').textContent.includes('同じでは')"); print(tag,'mismatch ->',await pg.text_content('#lg-err'))
    await pg.fill('#cg-old',PW); await pg.fill('#cg-new',PW2); await pg.fill('#cg-new2',PW2); await pg.click('#lg-go'); await pg.wait_for_selector('#lg-msg',timeout=15000)
    print(tag,'changed ->',await pg.text_content('#lg-msg'),'| devices of this id still in',dv0,'->',admin("select count(*) from devices where login_id='shiken' and revoked_at is null"),'| history',admin("select count(*) from events where action='password.changed'"))
    await pg.fill('#lg-id','shiken'); await pg.fill('#lg-pw',PW); await pg.click('#lg-go'); await pg.wait_for_selector('#lg-err'); print(tag,'old password ->',await pg.text_content('#lg-err'))
    await pg.fill('#lg-pw',PW2); await pg.click('#lg-go'); await pg.wait_for_selector('#add-table',timeout=15000); print(tag,'new password -> logged in'); await pg.click('#logout'); await pg.wait_for_selector('#lg-id'); await ov(pg,tag,'chg')
    await pg.click('#lg-chg'); await pg.fill('#cg-id','shiken'); await pg.fill('#cg-old',PW2); await pg.fill('#cg-new',PW); await pg.fill('#cg-new2',PW); await pg.screenshot(path=f'/home/claude/a_{tag}_chg.png'); await pg.click('#lg-go'); await pg.wait_for_selector('#lg-msg',timeout=15000)
    print(tag,'login errors',errs); await ctx.close()
async def run_kanri(b,tag,w,h,first):
    ctx=await b.new_context(viewport={'width':w,'height':h}); pg=await ctx.new_page(); errs=[]
    pg.on('pageerror',lambda e:errs.append(str(e)))
    await pg.route('**/rest/v1/rpc/*',handler); await pg.goto(K); await pg.wait_for_selector('#lg-id'); await ov(pg,tag,'klogin')
    await pg.click('#demo-go'); await pg.wait_for_selector('.kpi',timeout=20000); await ov(pg,tag,'kdemo')
    print(tag,'demo: kpi',await pg.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join(' / ')"),'| shops',await pg.evaluate("document.querySelector('table tbody').rows.length"),'| recent rows',await pg.evaluate("[...document.querySelectorAll('table')].pop().tBodies[0].rows.length"))
    await pg.click('[data-a="days"][data-v="30"]'); await pg.wait_for_timeout(1500); print(tag,'30 days: kpi',await pg.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join(' / ')"),'| bars',await pg.locator('svg rect').count()); await ov(pg,tag,'k30')
    lv=await pg.evaluate("[...document.querySelectorAll('#prod .tabs2:not(.sm) button')].map(b=>b.textContent).join('/')"); print(tag,'prod levels',lv,'| all rows',await pg.evaluate("document.querySelector('#prod table').tBodies[0].rows.length"),'| pills',await pg.evaluate("[...document.querySelectorAll('#prod .pill')].map(e=>e.textContent).join(' | ')"))
    db=admin("select count(distinct v.id) filter (where sp.proposed_at is not null)||'/'||count(distinct v.id) filter (where sp.won_at is not null)||'/'||coalesce(sum(sp.qty) filter (where sp.won_at is not null),0) from segment_products sp join visit_segments g on g.id=sp.segment_id join visits v on v.id=g.visit_id join shops s on s.shop_id=v.shop_id where s.is_demo and sp.product_key='carrier' and (v.started_at at time zone 'Asia/Tokyo')::date > (now() at time zone 'Asia/Tokyo')::date-30")
    print(tag,'carrier all row (p/rate/w/close/visit/q/per):',await pg.evaluate("[...document.querySelector('#prod table').tBodies[0].rows[0].cells].map(c=>c.textContent).join(' , ')"),'| db p/w/q',db)
    for k in ['areas','shops','staff']:
        await pg.click('#lv-'+k); print(tag,k,'rows',await pg.evaluate("document.querySelector('#mx').tBodies[0].rows.length"),'| row1',await pg.evaluate("[...document.querySelector('#mx').tBodies[0].rows[1].cells].slice(0,4).map(c=>c.textContent).join(' , ')"),'| marks',await pg.locator('#mx td.hi').count(),await pg.locator('#mx td.lo').count(),await pg.locator('#mx td.thin').count()); await ov(pg,tag,'kp_'+k)
    for m in ['visit','prop','qty','close']:
        await pg.click('#mt-'+m); print(tag,'metric',m,await pg.evaluate("[...document.querySelector('#mx').tBodies[0].rows[0].cells].slice(0,4).map(c=>c.textContent).join(' , ')"))
    await pg.locator('#mx td.nm button').first.click(); await pg.wait_for_selector('#dt'); print(tag,'drill',await pg.text_content('#dt h3'),'| rows',await pg.evaluate("document.querySelector('#dt table').tBodies[0].rows.length")); await pg.locator('#prod').screenshot(path=f'/home/claude/a_{tag}_kprod.png'); await ov(pg,tag,'kp_drill')
    await pg.click('#lv-shops'); await pg.locator('#prod').screenshot(path=f'/home/claude/a_{tag}_kprod_shops.png'); await pg.click('#lv-all')
    print(tag,'time section: rows',await pg.evaluate("document.querySelector('#time table').tBodies[0].rows.length"),'| pills',await pg.evaluate("[...document.querySelectorAll('#time .pill')].map(e=>e.textContent).join(' | ')"),'| row1',await pg.evaluate("[...document.querySelector('#time table').tBodies[0].rows[0].cells].map(c=>c.textContent).join(' , ')")); await pg.locator('#time').screenshot(path=f'/home/claude/a_{tag}_ktime.png'); await ov(pg,tag,'ktime')
    print(tag,'src section:',await pg.evaluate("(document.querySelector('#src .box')||{}).innerText||'none'")); print(tag,'goal section: pills',await pg.evaluate("[...document.querySelectorAll('#goal .pill')].map(e=>e.textContent).join(' | ')"),'| tables',await pg.evaluate("document.querySelectorAll('#goal table').length")); await pg.locator('#goal').screenshot(path=f'/home/claude/a_{tag}_kgoal.png'); await ov(pg,tag,'kgoal')
    print(tag,'act section: pills',await pg.evaluate("[...document.querySelectorAll('#act .pill')].map(e=>e.textContent).join(' | ')"),'| tables',await pg.evaluate("document.querySelectorAll('#act table').length"),'| staff rows',await pg.evaluate("[...document.querySelectorAll('#act table')].slice(-2)[0].tBodies[0].rows.length"),'| miss',await pg.evaluate("(document.getElementById('act-miss')||{}).textContent||'none'"),'| slack',await pg.evaluate("(document.getElementById('act-slack')||{}).textContent||'none'")); await pg.locator('#act').screenshot(path=f'/home/claude/a_{tag}_kact.png'); await ov(pg,tag,'kact')
    await pg.select_option('#shop-sel',index=2); await pg.wait_for_timeout(1500); print(tag,'one shop: shop table shown',await pg.evaluate("[...document.querySelectorAll('h2')].some(h=>h.textContent==='店舗別')"),'| kpi',await pg.evaluate("document.querySelector('.kpi .v').textContent"))
    await pg.screenshot(path=f'/home/claude/a_{tag}_kfull.png',full_page=True)
    await pg.click('[data-a="logout"]'); await pg.wait_for_selector('#lg-id')
    await pg.fill('#lg-id','shiken'); await pg.fill('#lg-pw','local-test-pass-1'); await pg.click('#lg-go'); await pg.wait_for_selector('#lg-err'); print(tag,'table id on kanri ->',(await pg.text_content('#lg-err'))[:24])
    await pg.fill('#lg-id','shiken-tencho'); await pg.fill('#lg-pw','x'); await pg.click('#lg-go')
    await pg.wait_for_selector('#lg-new, #lg-err')
    if await pg.locator('#lg-new').count():
        await pg.fill('#lg-new','local-test-pass-2'); await pg.fill('#lg-new2','local-test-pass-2'); await pg.click('#lg-go')
    else:
        await pg.fill('#lg-pw','local-test-pass-2'); await pg.click('#lg-go')
    await pg.wait_for_selector('.kpi',timeout=20000); await pg.click('[data-a="days"][data-v="1"]'); await pg.wait_for_timeout(1500)
    print(tag,'manager: kpi',await pg.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join(' / ')"),'| shop table',await pg.evaluate("[...document.querySelectorAll('h2')].some(h=>h.textContent==='店舗別')"),'| recent',await pg.evaluate("[...document.querySelectorAll('table')].pop().tBodies[0].rows[0].cells[3].textContent"),'| band',await pg.evaluate("document.querySelector('.band span').textContent"))
    print(tag,'manager prod levels',await pg.evaluate("[...document.querySelectorAll('#prod .tabs2:not(.sm) button')].map(b=>b.textContent).join('/')")); await pg.click('#lv-staff'); print(tag,'manager staff rows',await pg.evaluate("document.querySelector('#mx').tBodies[0].rows.length"))
    await ov(pg,tag,'kmgr'); print(tag,'kanri errors',errs); await ctx.close()
async def main():
    async with async_playwright() as p:
        b=await p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--no-sandbox','--allow-file-access-from-files'])
        import os
        if os.environ.get('KONLY'):
            await run_kanri(b,'t',1280,800,False); await run_kanri(b,'m',390,844,False); await b.close(); return
        if os.environ.get('SKIP'):
            await run_login(b,'t',1024,768,os.environ.get('SKIP')=='first'); await run_login(b,'m',390,844,False); await run_kanri(b,'t',1280,800,os.environ.get('SKIP')=='first'); await run_kanri(b,'m',390,844,False); print('rpc errors',CALLS['err'][:5]); await b.close(); return
        admin("update accounts set pass_hash=null, pass_set_at=null, failed=0, locked_until=null")
        pg1=await run(b,'t',1024,768)
        admin("select public.app__demo_seed(9000,true)")
        pg2=await run(b,'m',390,844)
        await pg1.bring_to_front(); await pg1.wait_for_timeout(6000); await pg1.click('#role-mgr')
        print('device1 sees device2 data: kpi',await pg1.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join('/')"))
        print('db: devices',admin("select count(*) from devices"),'visits',admin("select count(*)||' closed '||count(*) filter (where ended_at is not null) from visits"),'events',admin("select count(*) from events"),'surveys',admin("select count(*) from surveys"))
        await run_login(b,'t',1024,768,True); await run_login(b,'m',390,844,False)
        await run_kanri(b,'t',1280,800,True); await run_kanri(b,'m',390,844,False)
        print('rpc calls',CALLS['n'],'rpc errors',CALLS['err'][:5])
        await b.close()
asyncio.run(main())
