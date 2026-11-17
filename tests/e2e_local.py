import asyncio, json, re, subprocess, os
from playwright.async_api import async_playwright
P='file:///home/claude/tenpo-kanri/public/index.html'
T={'p_device':'uuid','p_secret':'text','p_visit':'jsonb','p_resv':'jsonb','p_actor':'text','p_id':'uuid','p_kind':'text','p_company':'text','p_name':'text','p_op':'text','p_answered':'boolean','p_service':'integer','p_clarity':'integer','p_return':'text','p_label':'text'}
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
    ty=lambda k:'uuid' if (fn=='app_survey' and k=='p_visit') else T[k]
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
    await pg.route('**/rest/v1/rpc/*',handler); await pg.goto(P); await pg.wait_for_selector('#add-table',timeout=15000)
    return pg,errs
async def saved(pg): await pg.wait_for_function("document.getElementById('net').textContent==='保存済み'",timeout=20000)
tiles=lambda pg: pg.locator('button.tile:not(.addt)')
async def run(b,tag,w,h):
    pg,errs=await newpage(b,w,h)
    async def shot(n):
        r=await pg.evaluate("({sw:document.documentElement.scrollWidth,cw:document.documentElement.clientWidth})")
        if r['sw']>r['cw']+1: print(tag,n,'OVERFLOW',r)
        await pg.screenshot(path=f'/home/claude/a_{tag}_{n}.png')
    print(tag,'tables',await tiles(pg).count(),'not clocked',await pg.locator('[data-a="clockin"]').count())
    if await pg.locator('[data-a="clockin"]').count(): await pg.locator('[data-a="clockin"]').first.click()
    await shot('home')
    # full flow
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-out')
    await pg.click('[data-k="age"][data-v="70〜74歳"]'); await pg.click('#extra-0'); await pg.click('#sh-done'); await pg.locator('[data-a="pick"]').first.click()
    await pg.click('#p-net'); await pg.click('#w-carrier'); await pg.click('#act-est'); await saved(pg)
    await pg.click('#go-back'); print(tag,'back ->',await pg.text_content('#tb-t')); await saved(pg)
    print(tag,'segments after back',admin("select count(*) from visit_segments g join visits v on v.id=g.visit_id where v.ended_at is null"))
    await pg.locator('[data-a="pick"]').first.click(); await pg.click('#p-net'); await pg.click('#w-carrier'); await pg.click('#serve-won'); await pg.locator('[data-a="pick"]').nth(1).click()
    await pg.click('#setup-start'); await saved(pg); await pg.wait_for_timeout(5600); await shot('after')
    print(tag,'carrier hidden',await pg.query_selector('#p-carrier') is None, 'title',await pg.text_content('#tb-t'))
    await pg.click('#setup-end'); await pg.click('#move-none'); await pg.click('#a-5'); await pg.click('#b-4'); await pg.click('#c-0'); await pg.click('#sv-send'); await pg.click('#thanks-back'); await saved(pg)
    print(tag,'end ->',await pg.text_content('#tb-t'),'tables',await tiles(pg).count())
    # guide skip
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').nth(1).click(); await pg.click('#type-in_guide'); print(tag,'guide ->',await pg.text_content('#tb-t')); await pg.click('#serve-end'); await saved(pg)
    # back = void
    n0=admin("select count(*) from visits")
    await tiles(pg).nth(2).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-in_meo'); await saved(pg)
    n1=admin("select count(*) from visits"); await pg.click('#go-back'); await saved(pg)
    print(tag,'void: visits',n0,'->',n1,'->',admin("select count(*) from visits"),'title',await pg.text_content('#tb-t'))
    await pg.click('#go-home')
    # reservation register + cancel
    await pg.click('#role-resv'); await pg.click('#resv-new')
    d=await pg.evaluate("(()=>{const d=new Date(Date.now()+3*3600e3);const p=n=>String(n).padStart(2,'0');return [d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate()),p(d.getHours())+':'+p(d.getMinutes())]})()")
    await pg.fill('#rf-date',d[0]); await pg.fill('#rf-time',d[1]); await pg.click('#rf-save'); await saved(pg); await shot('resv')
    print(tag,'resv rows',await pg.locator('.rv').count(),'nos',await pg.evaluate("[...document.querySelectorAll('.rv .w span')].map(e=>(e.textContent.match(/R-\\d+|採番中/)||[''])[0]).join(',')"))
    await pg.locator('[data-a="rcancel"]').last.click(); await saved(pg)
    # reservation due -> auto table -> no-show
    admin("update reservations set reserved_at=now()+interval '10 minutes' where id=(select id from reservations where status='booked' order by reserved_at limit 1)")
    await pg.click('#role-staff'); await pg.wait_for_function("document.querySelectorAll('button.tile.rsv').length===1",timeout=15000); await shot('rsv')
    print(tag,'auto table: tiles',await tiles(pg).count(),'alert badge',await pg.text_content('.b-alert') if await pg.locator('.b-alert').count() else '-')
    await pg.locator('button.tile.rsv').click(); await pg.click('#resv-noshow'); await saved(pg); print(tag,'after noshow tiles',await tiles(pg).count())
    await pg.click('#add-table'); await saved(pg); a=await tiles(pg).count(); await pg.click('#rm-table'); await saved(pg); print(tag,'add/remove',a,'->',await tiles(pg).count())
    await pg.click('#role-mgr'); await shot('mgr'); print(tag,'mgr kpi',await pg.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join('/')"))
    # offline
    await pg.click('#role-staff'); OFF['v']=True
    await tiles(pg).nth(0).click(); await pg.locator('[data-a="recv"]').first.click(); await pg.click('#type-fix'); await pg.click('[data-k="age"][data-v="30代"]'); await pg.click('#sh-done'); await pg.locator('[data-a="pick"]').first.click(); await pg.click('#p-coat')
    await pg.wait_for_timeout(1500); print(tag,'offline msg:',await pg.text_content('#net'),'| screen',await pg.text_content('#tb-t')); await shot('offline')
    OFF['v']=False; await saved(pg)
    print(tag,'after reconnect:',admin("select v.visit_type||' '||v.phase||' h='||(select age_band from visit_hearings h where h.visit_id=v.id)||' prod='||(select count(*) from segment_products sp join visit_segments g on g.id=sp.segment_id where g.visit_id=v.id) from visits v where v.ended_at is null"))
    await pg.click('#serve-end'); await saved(pg)
    print(tag,'errors',errs); return pg
async def main():
    async with async_playwright() as p:
        b=await p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--no-sandbox','--allow-file-access-from-files'])
        pg1=await run(b,'t',1024,768)
        admin("select public.app__demo_seed(9000,true)")
        pg2=await run(b,'m',390,844)
        await pg1.bring_to_front(); await pg1.wait_for_timeout(6000); await pg1.click('#role-mgr')
        print('device1 sees device2 data: kpi',await pg1.evaluate("[...document.querySelectorAll('.kpi .v')].map(e=>e.textContent).join('/')"))
        print('db: devices',admin("select count(*) from devices"),'visits',admin("select count(*)||' closed '||count(*) filter (where ended_at is not null) from visits"),'events',admin("select count(*) from events"),'surveys',admin("select count(*) from surveys"))
        print('rpc calls',CALLS['n'],'rpc errors',CALLS['err'][:5])
        await b.close()
asyncio.run(main())
