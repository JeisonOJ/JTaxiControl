// Local-only PostgreSQL tests; run npm install first.
const {PGlite}=require('@electric-sql/pglite');
const fs=require('node:fs');
const assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite();
 await db.exec(`create role anon; create role authenticated; create schema auth; create table auth.users(id uuid primary key); create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$; grant usage on schema auth to public; grant execute on function auth.uid() to public;`);
 await db.exec(fs.readFileSync('supabase/migrations/202611160001_initial.sql','utf8'));
 await db.exec(`create or replace function private.today() returns date language sql stable as $$select date '2026-11-16'$$;`);
 const user='00000000-0000-4000-8000-000000000001';
 const outsider='00000000-0000-4000-8000-000000000002';
 await db.query('insert into auth.users values ($1),($2)',[user,outsider]);
 await db.query('insert into private.app_users values ($1,1)',[user]);
 const asUser=async(id)=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('set role authenticated');};
 const fails=async(sql,args)=>{let denied=false;try{await db.query(sql,args)}catch(e){denied=true;}assert(denied,`Expected rejection: ${sql}`);};
 await asUser(outsider);
 assert.equal((await db.query('select * from public.taxis')).rows.length,0);
 await fails("select public.save_taxi(1::smallint,'BAD123')");
 await asUser(user);
 await db.exec("select public.save_taxi(1::smallint,'ABC123');select public.save_taxi(2::smallint,'DEF456');");
 await fails("insert into public.taxis(slot,plate) values(1,'BAD123')");
 await fails("select public.save_taxi(3::smallint,'XYZ789')");
 const driver=(await db.query("select public.save_driver(null,'Conductor anterior','') id")).rows[0].id;
 const driver2=(await db.query("select public.save_driver(null,'Conductor nuevo','') id")).rows[0].id;
 const taxi=(await db.query('select id from public.taxis where slot=1')).rows[0].id;
 const taxi2=(await db.query('select id from public.taxis where slot=2')).rows[0].id;
 const today='2026-11-16';
 const badDays=['NULL',"'{}'::integer[]",'array[0]','array[8]','array[1,NULL]','array[NULL]::integer[]','array[[1,2],[3,4]]'];
 for(const days of badDays) {
   await fails(`select public.assign_driver($1,$2,$3,'fixed',90000,${days})`,[taxi,driver,today]);
   assert.equal((await db.query('select * from public.assignments')).rows.length,0);
 }
 const assignment=(await db.query("select public.assign_driver($1,$2,$3,'fixed',90000,array[1,2,3,4,5,6,7]) id",[taxi,driver,today])).rows[0].id;
 await db.exec('select public.generate_quotas();select public.generate_quotas()');
 assert.equal((await db.query('select * from public.obligations')).rows.length,1);
 const payment='00000000-0000-4000-8000-000000000003';
 const pay="select public.record_payment($1,$2,$3,$4,'Abono')";
 for(const days of badDays) await fails(`select public.change_quota($1,'2026-11-17',100000,${days})`,[assignment]);
 assert.equal((await db.query('select * from public.quota_rules')).rows.length,1);
 await db.query(pay,[payment,assignment,30000,today]);
 await db.query(pay,[payment,assignment,30000,today]);
 assert.equal((await db.query('select * from public.payments')).rows.length,1);
 assert.equal(Number((await db.query('select sum(amount) total from public.allocations')).rows[0].total),30000);
 await fails(pay,[payment,assignment,40000,today]);
 for(const params of [[payment,null,30000,today,'Abono'],[payment,assignment,null,today,'Abono'],[payment,assignment,30000,null,'Abono'],[payment,assignment,30000,today,null]]) {
   await fails('select public.record_payment($1,$2,$3,$4,$5)',params);
 }
 await fails("select public.exempt_day($1,$2,'ReparaciÃ³n')",[assignment,today]);
 await fails("select public.change_quota($1,$2,100000,array[1,2,3,4,5,6])",[assignment,today]);
 await db.query("select public.change_quota($1,$2::date+1,100000,array[1,2,3,4,5,6])",[assignment,today]);
 await db.query("select public.assign_driver($1,$2,$3::date+1,'fixed',100000,array[1,2,3,4,5,6])",[taxi,driver2,today]);
 const scheduled=(await db.query('select * from public.assignments where driver_id=$1',[driver2])).rows[0];
 const correctionDriver=(await db.query("select public.save_driver(null,'CorrecciÃ³n futura','') id")).rows[0].id;
 const corrected=(await db.query("select public.assign_driver($1,$2,'2026-11-17','fixed',105000,array[1,2,3,4,5,6]) id",[taxi,correctionDriver])).rows[0].id;
 assert.equal(corrected,scheduled.id);
 assert.equal((await db.query('select * from public.assignments')).rows.length,2);
 assert.equal((await db.query('select ends_on::text d from public.assignments where id=$1',[assignment])).rows[0].d,today);
 await fails("select public.assign_driver($1,$2,'2026-11-18','fixed',90000,array[1])",[taxi,correctionDriver]);
 await fails("select public.assign_driver($1,$2,'2026-11-17','flexible',0,array[1])",[taxi,correctionDriver]);
 for(const days of badDays) await fails(`select public.assign_driver($1,$2,'2026-11-17','fixed',100000,${days})`,[taxi,driver2]);
 assert.equal((await db.query('select driver_id from public.assignments where id=$1',[scheduled.id])).rows[0].driver_id,correctionDriver);
 // Defensive guard: even a future assignment cannot change driver if an
 // administrator has already attached a financial record to it.
 await db.exec('reset role;begin');
 await db.query("insert into public.obligations(assignment_id,due_on,amount) values($1,'2026-11-17',105000)",[scheduled.id]);
 await db.exec('set role authenticated');
 await fails("select public.assign_driver($1,$2,'2026-11-17','fixed',100000,array[1])",[taxi,driver2]);
 await db.exec('rollback');
 await asUser(user);
 // Restore the intended future driver; no historical debt or assignment is replaced.
 await db.query("select public.assign_driver($1,$2,'2026-11-17','fixed',100000,array[1,2,3,4,5,6])",[taxi,driver2]);
 await db.exec('select public.generate_quotas()');
 assert.equal(Number((await db.query('select amount from public.obligations where assignment_id=$1',[assignment])).rows[0].amount),90000);
 await db.query(pay,['00000000-0000-4000-8000-000000000004',assignment,20000,today]);
 const balance=(await db.query('select o.amount-(select sum(amount) from public.allocations where obligation_id=o.id) balance from public.obligations o where assignment_id=$1',[assignment])).rows[0].balance;
 assert.equal(Number(balance),40000);
 await fails(pay,['00000000-0000-4000-8000-000000000005',assignment,50000,today]);
 await fails("select public.assign_driver($1,$2,$3,'flexible',0,array[1,2,3,4,5,6])",[taxi2,driver,today]);
 const third=(await db.query("select public.save_driver(null,'Conductor flexible','') id")).rows[0].id;
 const flex=(await db.query("select public.assign_driver($1,$2,$3,'flexible',0,array[1,2,3,4,5,6]) id",[taxi2,third,today])).rows[0].id;
 await db.exec('select public.generate_quotas()');
 assert.equal((await db.query('select * from public.obligations where assignment_id=$1',[flex])).rows.length,0);
 await db.query(pay,['00000000-0000-4000-8000-000000000006',flex,120000,today]);
 assert.equal((await db.query('select * from public.allocations where payment_id=$1',['00000000-0000-4000-8000-000000000006'])).rows.length,0);
 await asUser(outsider);
 for(const t of ['taxis','drivers','assignments','quota_rules','obligations','payments','allocations','exemptions']) assert.equal((await db.query(`select * from public.${t}`)).rows.length,0);
 await db.exec('reset role');
 await db.exec(`create or replace function private.today() returns date language sql stable as $$select date '2026-11-17'$$;`);
 await asUser(user);
 await db.exec('select public.generate_quotas()');
 const replacement=(await db.query('select id from public.assignments where driver_id=$1',[driver2])).rows[0].id;
 await fails("select public.assign_driver($1,$2,'2026-11-17','fixed',100000,array[1])",[taxi,correctionDriver]);
 assert.equal(Number((await db.query('select amount from public.obligations where assignment_id=$1',[replacement])).rows[0].amount),100000);
 await db.query("select public.exempt_day($1,'2026-11-17','Pico y placa')",[replacement]);
 assert.equal((await db.query('select exempt_reason from public.obligations where assignment_id=$1',[replacement])).rows[0].exempt_reason,'Pico y placa');
 await db.query("select public.change_quota($1,'2026-11-18',110000,array[1,2,3,4,5,6])",[replacement]);
 await db.exec('reset role');
 await db.exec(`create or replace function private.today() returns date language sql stable as $$select date '2026-11-22'$$;`);
 await asUser(user);
 await db.exec('select public.generate_quotas()');
 assert.equal(Number((await db.query("select amount from public.obligations where assignment_id=$1 and due_on='2026-11-18'",[replacement])).rows[0].amount),110000);
 assert.equal((await db.query("select * from public.obligations where assignment_id=$1 and due_on='2026-11-22'",[replacement])).rows.length,0);
 assert.equal(Number((await db.query('select amount from public.obligations where assignment_id=$1',[assignment])).rows[0].amount),90000);
 await asUser(outsider);
 await fails('select public.generate_quotas()');
 await fails('select public.dashboard()');
 await db.exec('reset role;set role anon');
 await fails('select * from public.payments');
 await fails('select public.generate_quotas()');
 await fails('select public.dashboard()');
 await db.exec('reset role');
 // Apply the actual private membership migration against isolated fake Auth rows.
 const memberOne='11111111-1111-4111-8111-111111111111';
 const owner='22222222-2222-4222-8222-222222222222';
 await db.query('insert into auth.users values ($1),($2)',[memberOne,owner]);
 await db.exec('delete from private.app_users');
 await db.query("select set_config('jtaxi.member_one',$1,false),set_config('jtaxi.member_two',$2,false)",[memberOne,owner]);
 await db.exec(fs.readFileSync('supabase/migrations/202611160002_private_members.sql','utf8'));
 for(const member of [memberOne,owner]) {
   await asUser(member);
   assert.equal((await db.query('select public.dashboard() result')).rows[0].result.taxis.length,2);
   await db.exec("select public.save_taxi(1::smallint,'ABC123')");
   await fails('select * from private.app_users');
 }
 await asUser(outsider);
 await fails('select public.dashboard()');
 // Check effective privileges, not just a failing RPC with possibly invalid inputs.
 await db.exec('reset role');
 const funcs=(await db.query("select p.oid::regprocedure::text signature,n.nspname,p.proname,p.prosecdef,p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' or (n.nspname='public' and p.proname in ('save_taxi','save_driver','assign_driver','change_quota','generate_quotas','exempt_day','record_payment','dashboard'))")).rows;
 for(const f of funcs) {
   // today() is replaced by the deterministic test clock above.
   if(f.proname!=='today') assert(f.proconfig.includes('search_path=""'));
   if(f.proname!=='today') assert.equal(f.prosecdef,true);
   const rights=(await db.query("select has_function_privilege('anon',$1,'execute') anon,has_function_privilege('authenticated',$1,'execute') member",[f.signature])).rows[0];
   assert.equal(rights.anon,false);
   assert.equal(rights.member,f.nspname==='public'||f.proname==='is_member');
 }
 for(const role of ['anon','authenticated']) {
   assert.equal((await db.query("select has_schema_privilege($1,'private','create') allowed",[role])).rows[0].allowed,false);
   assert.equal((await db.query("select has_table_privilege($1,'private.app_users','select') allowed",[role])).rows[0].allowed,false);
 }
 for(const t of ['taxis','drivers','assignments','quota_rules','obligations','payments','allocations','exemptions']) {
   assert.equal((await db.query('select relrowsecurity from pg_class where oid=$1::regclass',['public.'+t])).rows[0].relrowsecurity,true);
   for(const privilege of ['insert','update','delete']) {
     assert.equal((await db.query('select has_table_privilege($1,$2,$3) allowed',['authenticated','public.'+t,privilege])).rows[0].allowed,false);
   }
 }
 await require('./finances.cjs')(db,memberOne,asUser,fails);
 await db.close();
 console.log('PASS: migration, RLS/anonymous/outsider denial, fixed/flexible quotas, partial payments, idempotency, conflicting retries, future rules, replacement, preserved debts, overpayment and paid exemption rejection.');
 console.log('PASS: weekday validation and atomic rollback, safe future correction, financial-history guard, null retry payload rejection, schema/function/table privileges and RLS catalog checks.');
})().catch(e=>{console.error(e);process.exit(1);});


