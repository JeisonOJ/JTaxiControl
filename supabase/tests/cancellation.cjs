const {PGlite}=require('@electric-sql/pglite');const fs=require('node:fs'),assert=require('node:assert/strict');
(async()=>{const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to public;grant execute on function auth.uid() to public;`);
 for(const file of ['202611160001_initial.sql','202611160003_finances.sql','202611160004_opening_balances.sql'])await db.exec(fs.readFileSync('supabase/migrations/'+file,'utf8'));
 const member='11111111-1111-4111-8111-111111111111',outsider='55555555-5555-4555-8555-555555555555';await db.query('insert into auth.users values($1),($2)',[member,outsider]);await db.query('insert into private.app_users values($1,1)',[member]);
 const login=async(user=member)=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);await db.exec('set role authenticated');};
 await db.exec(`create or replace function private.today() returns date language sql stable as $$select date '2026-11-16'$$;`);await login();
 let serial=0;const id=()=>`66666666-6666-4666-8666-${String(++serial).padStart(12,'0')}`;
 const fail=async(fn)=>{let error;try{await fn()}catch(e){error=e}assert(error,'Expected rejection');return error;};
 await db.exec("select public.save_taxi(1::smallint,'CANCEL-1');select public.save_taxi(2::smallint,'CANCEL-2')");
 const [t1,t2]=(await db.query('select id from public.taxis order by slot')).rows.map(t=>t.id);
 await db.query("select public.initialize_taxi($1,$2,'2026-11-16',0,100000)",[id(),t1]);
 const driver=async(name)=>(await db.query("select public.save_driver(null,$1,'') id",[name])).rows[0].id;
 const a1=(await db.query("select public.assign_driver($1,$2,'2026-11-16','fixed',90000,array[1,2,3,4,5,6,7]) id",[t1,await driver('FIXED')])).rows[0].id;
 const a2=(await db.query("select public.assign_driver($1,$2,'2026-11-16','flexible',0,array[1,2,3,4,5,6,7]) id",[t2,await driver('FLEX')])).rows[0].id;
 const pay=(token,a,amount,day='2026-11-16')=>db.query("select public.record_payment($1,$2,$3,$4,'TEST')",[token,a,amount,day]);
 const p1=id(),p2=id(),flex=id();await pay(p1,a1,30000);await pay(p2,a1,60000);await pay(flex,a2,45000);
 const before=(await db.query('select * from public.payments order by id')).rows;
 await db.exec('reset role');await db.exec(fs.readFileSync('supabase/migrations/202611160005_payment_cancellation.sql','utf8'));await login();
 assert.equal((await db.query('select * from public.payments')).rows.length,3);for(const r of (await db.query('select * from public.payments order by id')).rows){const original=before.find(p=>p.id===r.id);for(const k in original)assert.deepEqual(r[k],original[k]);assert.equal(r.cancelled_at,null);}
 const cancel=(token,p,reason='Error de prueba')=>db.query('select public.cancel_payment($1,$2,$3) id',[token,p,reason]);
 const dash=async()=>(await db.query("select public.finance_dashboard('2026-11-01') d")).rows[0].d;
 const summary=async(t)=>(await dash()).summaries.find(s=>s.id===t);
 const debt=async(a)=>Number((await db.query('select sum(o.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=o.id and al.reversed_at is null),0)) total from public.obligations o where assignment_id=$1',[a])).rows[0].total??0);
 const token=id();const concurrent=await Promise.all([cancel(token,p1),cancel(token,p1)]);assert.equal(concurrent[0].rows[0].id,p1);assert.equal(concurrent[1].rows[0].id,p1);
 assert.equal(await debt(a1),30000);assert.equal(Number((await summary(t1)).fund),60000);assert.equal(Number((await summary(t1)).income),60000);assert.equal(Number((await summary(t1)).owner_debt),100000);
 const original=(await db.query('select * from public.payments where id=$1',[p1])).rows[0];assert.equal(original.cancelled_by,member);assert(original.cancelled_at);assert.equal(original.cancellation_reason,'Error de prueba');
 await fail(()=>cancel(id(),p1));await fail(()=>cancel(token,p1,'Otro motivo'));await pay(p1,a1,30000);assert.equal(await debt(a1),30000);assert.equal(Number((await summary(t1)).fund),60000);
 await pay(id(),a1,30000);assert.equal(await debt(a1),0);assert.equal((await db.query('select * from public.allocations where payment_id=$1',[p1])).rows.length,1);
 const otherBefore=await summary(t1);await cancel(id(),flex);assert.equal(Number((await summary(t2)).fund),0);assert.equal(Number((await summary(t2)).income),0);assert.equal(await debt(a2),0);assert.deepEqual(await summary(t1),otherBefore);
 // Reverted allocations no longer block exempting an otherwise unpaid quota.
 await db.exec('begin');await cancel(id(),p2);
 const lastFixed=(await db.query('select id from public.payments where assignment_id=$1 and cancelled_at is null',[a1])).rows[0].id;
 await cancel(id(),lastFixed);await db.query("select public.exempt_day($1,'2026-11-16','Descanso')",[a1]);await db.exec('rollback');
 await db.exec('begin');const spentFlex=id();await pay(spentFlex,a2,30000);
 await db.query("select public.record_finance($1,$2,'expense',30000,'2026-11-16','other','TEST',null)",[id(),t2]);
 await db.exec('savepoint before_cancel');await fail(()=>cancel(id(),spentFlex));await db.exec('rollback to savepoint before_cancel');assert.equal((await db.query('select cancelled_at from public.payments where id=$1',[spentFlex])).rows[0].cancelled_at,null);await db.exec('rollback');
 // Subsequent allocations remain active when the earlier payment is cancelled.
 const freshFlex=id();await pay(freshFlex,a2,10000);
 const outcomes=await Promise.allSettled([cancel(id(),freshFlex),cancel(id(),freshFlex)]);assert.equal(outcomes.filter(x=>x.status==='fulfilled').length,1);assert.equal(outcomes.filter(x=>x.status==='rejected').length,1);
 // Funds positive today cannot hide a historical deficit yesterday.
 await db.exec('reset role');await db.exec(`create or replace function private.today() returns date language sql stable as $$select date '2026-11-18'$$;`);await login();
 await db.query("select public.record_finance($1,$2,'expense',50000,'2026-11-17','other','TEST',null)",[id(),t1]);
 await db.query("select public.record_finance($1,$2,'advance',100000,'2026-11-18','other','TEST',null)",[id(),t1]);
 const stateBefore=await summary(t1);const e=await fail(()=>cancel(id(),p2));assert(e.message.includes('histórico negativo'));assert.deepEqual(await summary(t1),stateBefore);assert.equal((await db.query('select cancelled_at from public.payments where id=$1',[p2])).rows[0].cancelled_at,null);assert.equal((await db.query('select reversed_at from public.allocations where payment_id=$1',[p2])).rows[0].reversed_at,null);
 // Remaining active cash also drives the validation of later expenses.
 await fail(()=>db.query("select public.record_finance($1,$2,'expense',140001,'2026-11-18','other','TEST',null)",[id(),t1]));
 // An independently cancelled fixed payment restores debt and permits exemption.
 await db.exec('begin');await db.query("select public.record_finance($1,$2,'advance',50000,'2026-11-16','other','TEST',null)",[id(),t1]);await cancel(id(),p2);assert.equal(await debt(a1),60000);await db.exec('rollback');
 await login(outsider);assert.equal((await db.query('select * from public.payments')).rows.length,0);await fail(()=>cancel(id(),p2));await db.exec('reset role;set role anon');await fail(()=>cancel(id(),p2));
 await login();await fail(()=>db.query('update public.payments set cancelled_at=now() where id=$1',[p2]));await fail(()=>db.query('update public.allocations set reversed_at=now() where payment_id=$1',[p2]));
 const acl=(await db.query("select has_function_privilege('anon','public.cancel_payment(uuid,uuid,text)','execute') anon,has_function_privilege('authenticated','public.cancel_payment(uuid,uuid,text)','execute') member")).rows[0];assert(!acl.anon);assert(acl.member);
 console.log('PASS cancellation: fixed/flexible, restored debt, retained audit, active subsequent allocations, original-token retries, duplicate and conflicting requests, historical insufficient cash rollback, opening debt unchanged, taxi isolation, RLS/RPC denial. Single-engine concurrent queue covered here; independent-session concurrency is not exercised by this portable test suite.');
}finally{await db.close();}})().catch(e=>{console.error(e);process.exit(1)});

