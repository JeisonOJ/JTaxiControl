const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs');const assert=require('node:assert/strict');
module.exports=async()=>{
 const db=new PGlite();
 try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to public;grant execute on function auth.uid() to public;`);
 await db.exec(fs.readFileSync('supabase/migrations/202611160001_initial.sql','utf8'));
 const user='22222222-2222-4222-8222-222222222222';
 await db.query('insert into auth.users values($1)',[user]);await db.query('insert into private.app_users values($1,1)',[user]);
 const login=async()=>{await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);await db.exec('set role authenticated');};
 const clock=async(day)=>{await db.exec(`reset role;create or replace function private.today() returns date language sql stable as $$select date '${day}'$$;`);await login();};
 await clock('2026-11-16');
 await db.exec("select public.save_taxi(1::smallint,'REVIEW-1');select public.save_taxi(2::smallint,'REVIEW-2')");
 const taxi=(await db.query('select id from public.taxis where slot=1')).rows[0].id;
 const other=(await db.query('select id from public.taxis where slot=2')).rows[0].id;
 const driver=(await db.query("select public.save_driver(null,'Sample Driver','') id")).rows[0].id;
 const assignment=(await db.query("select public.assign_driver($1,$2,'2026-11-16','fixed',90000,array[1,2,3,4,5,6,7]) id",[taxi,driver])).rows[0].id;
 await db.query("select public.record_payment('22222222-2222-4222-8222-000000000001',$1,90000,'2026-11-16','PRUEBA')",[assignment]);
 await db.exec('reset role');
 const tables=['taxis','drivers','assignments','quota_rules','obligations','exemptions','payments','allocations'];
 const snapshots={};for(const t of tables)snapshots[t]=JSON.stringify((await db.query(`select * from public.${t}`)).rows);
 await db.exec(fs.readFileSync('supabase/migrations/202611160003_finances.sql','utf8'));
 await clock('2026-11-22');
 let seq=10;const id=()=>`22222222-2222-4222-8222-${String(seq++).padStart(12,'0')}`;
 const summary=async(month='2026-11-01')=>(await db.query('select public.finance_dashboard($1) d',[month])).rows[0].d.summaries;
 const state=async()=> (await summary()).find(t=>t.id===taxi);
 const move=async(kind,amount,day)=>db.query("select public.record_finance($1,$2,$3,$4,$5,'maintenance','PRUEBA',null)",[id(),taxi,kind,amount,day]);
 const rejects=async(fn)=>{let rejected=false;try{await fn();}catch(e){assert.equal(e.code,'P0001');rejected=true;}assert(rejected);};
 const unchanged=async(fn)=>{const before=JSON.stringify(await summary());const count=(await db.query('select count(*) n from public.finance_entries')).rows[0].n;await rejects(fn);assert.equal(JSON.stringify(await summary()),before);assert.equal((await db.query('select count(*) n from public.finance_entries')).rows[0].n,count);};
 const baselineOther=(await summary()).find(t=>t.id===other);
 await move('advance',50000,'2026-11-17');await move('expense',120000,'2026-11-18');
 let s=await state();assert.equal(Number(s.fund),20000);assert.equal(Number(s.owner_debt),50000);assert.equal(Number(s.income)-Number(s.expenses),-30000);
 await move('repayment',20000,'2026-11-19');s=await state();assert.equal(Number(s.fund),0);assert.equal(Number(s.owner_debt),30000);assert.equal(Number(s.income)-Number(s.expenses),-30000);
 assert.deepEqual((await summary()).find(t=>t.id===other),baselineOther);
 // Current funds suffice, but the new backdated debit would break a later day.
 await move('advance',100000,'2026-11-22');
 await unchanged(()=>move('expense',1000,'2026-11-16'));
 // Owner debt is positive now; on the backdated date there was no owner advance.
 await unchanged(()=>move('repayment',1000,'2026-11-16'));
 // Historical zero on Nov 19 cannot be financed by the Nov 22 advance.
 await unchanged(()=>move('expense',1,'2026-11-19'));
 assert.deepEqual((await summary()).find(t=>t.id===other),baselineOther);
 const recurrence=async(first)=>{const token=id();await db.query("select public.create_finance_template($1,$2,'PRUEBA calendario','other',null,$3,1)",[token,taxi,first]);return (await db.query('select due_on::text d from public.finance_dues where template_id=$1 order by due_on',[token])).rows.map(r=>r.d);};
 await clock('2026-03-31');
 for(const day of [29,30,31]){const dates=await recurrence(`2026-01-${day}`);assert(dates.includes('2026-02-28'));assert(dates.includes(`2026-03-${day}`));}
 const feb=await recurrence('2026-02-28');assert(feb.includes('2026-03-28'));assert(!feb.includes('2026-03-31'));
 await clock('2028-03-31');
 for(const day of [29,30,31]){const dates=await recurrence(`2028-01-${day}`);assert(dates.includes('2028-02-29'));assert(dates.includes(`2028-03-${day}`));}
 // 62 days can cross THREE month boundaries (Jan 31 -> Apr 3).
 await clock('2026-01-31');
 for(const cadence of [1,3]){const token=id();await db.query("select public.create_finance_template($1,$2,'PRUEBA horizonte','other',null,'2026-01-01',$3)",[token,taxi,cadence]);assert.equal((await db.query("select count(*)::int n from public.finance_dues where template_id=$1 and due_on='2026-04-01'",[token])).rows[0].n,1,`Missing April due for cadence ${cadence}`);}
 await db.exec('reset role');for(const t of tables)assert.equal(JSON.stringify((await db.query(`select * from public.${t}`)).rows),snapshots[t]);
 console.log('PASS final review: exact COP scenario, backdated cash/debt prefixes and rollback, taxi isolation, Jan 29–31/February/leap years, no recurrence drift, 62-day horizon, unchanged Phase 1 history.');
 }finally{await db.close();}
};
if(require.main===module)module.exports().catch(e=>{console.error(e);process.exit(1);});
