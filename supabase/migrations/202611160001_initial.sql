-- Review before applying. No remote changes are performed by the Flutter app.
begin;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
create table private.app_users (
  user_id uuid primary key references auth.users(id),
  slot smallint not null unique check (slot in (1,2))
);
alter table private.app_users enable row level security;
revoke all on private.app_users from public, anon, authenticated;
-- Only the SQL editor / administrator can maintain this two-person allowlist.
create function private.is_member() returns boolean language sql stable security definer
set search_path = '' as $$
  select exists(select 1 from private.app_users where user_id = auth.uid());
$$;
revoke all on function private.is_member() from public;
grant execute on function private.is_member() to authenticated;
create function private.require_member() returns void language plpgsql security definer
set search_path = '' as $$ begin
  if not private.is_member() then raise exception 'Acceso no autorizado'; end if;
end $$;
create function private.today() returns date language sql stable set search_path = '' as $$
 select (now() at time zone 'America/Bogota')::date;
$$;

create table public.taxis (
 id uuid primary key default gen_random_uuid(),
 slot smallint unique not null check(slot in (1,2)),
 plate text not null unique check(length(trim(plate)) between 3 and 12)
);
create table public.drivers (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(trim(name)) between 2 and 100),
 phone text not null default '' check(length(phone)<=30)
);
create table public.assignments (
 id uuid primary key default gen_random_uuid(),
 taxi_id uuid not null references public.taxis,
 driver_id uuid not null references public.drivers,
 starts_on date not null, ends_on date,
 mode text not null check(mode in ('fixed','flexible')),
 check(ends_on is null or ends_on >= starts_on)
);
create unique index one_open_assignment on public.assignments(taxi_id) where ends_on is null;
create table public.quota_rules (
 id uuid primary key default gen_random_uuid(),
 assignment_id uuid not null references public.assignments,
 effective_on date not null,
 amount bigint not null check(amount between 0 and 100000000),
 -- NOT NULL rejects a null array; containment also rejects null elements.
 weekdays integer[] not null check(array_ndims(weekdays)=1 and weekdays <@ array[1,2,3,4,5,6,7] and cardinality(weekdays)>0),
 unique(assignment_id,effective_on)
);
create table public.obligations (
 id uuid primary key default gen_random_uuid(),
 assignment_id uuid not null references public.assignments,
 due_on date not null, amount bigint not null check(amount>=0),
 exempt_reason text check(length(trim(exempt_reason)) between 2 and 200),
 unique(assignment_id,due_on)
);
create table public.exemptions (
 assignment_id uuid not null references public.assignments,
 day date not null, reason text not null check(length(trim(reason)) between 2 and 200),
 primary key(assignment_id,day)
);
create table public.payments (
 id uuid primary key, -- client-generated idempotency token, retained on retries
 assignment_id uuid not null references public.assignments,
 amount bigint not null check(amount between 1 and 100000000),
 paid_on date not null, note text not null default '' check(length(note)<=200),
 created_by uuid not null references auth.users,
 created_at timestamptz not null default now()
);
create table public.allocations (
 payment_id uuid not null references public.payments,
 obligation_id uuid not null references public.obligations,
 amount bigint not null check(amount>0),
 primary key(payment_id,obligation_id)
);
create index obligations_assignment on public.obligations(assignment_id,due_on);
create index payments_assignment on public.payments(assignment_id,paid_on);
create index allocations_obligation on public.allocations(obligation_id);

-- Read-only financial tables for approved members. All writes go through narrow RPCs.
do $$ declare t text; begin
 foreach t in array array['taxis','drivers','assignments','quota_rules','obligations','exemptions','payments','allocations'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public, anon, authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy member_read on public.%I for select to authenticated using (private.is_member())',t);
 end loop;
end $$;

create function public.save_taxi(p_slot smallint, p_plate text) returns void
language plpgsql security definer set search_path = '' as $$ begin
 perform private.require_member();
 insert into public.taxis(slot,plate) values(p_slot,upper(trim(p_plate)))
 on conflict(slot) do update set plate=excluded.plate;
end $$;
create function public.save_driver(p_id uuid, p_name text, p_phone text) returns uuid
language plpgsql security definer set search_path = '' as $$ declare v_id uuid; begin
 perform private.require_member();
 if p_id is null then
 insert into public.drivers(name,phone) values(trim(p_name),trim(p_phone)) returning id into v_id;
 else update public.drivers set name=trim(p_name),phone=trim(p_phone) where id=p_id returning id into v_id;
 if v_id is null then raise exception 'Conductor no encontrado'; end if;
 end if; return v_id;
end $$;

create function public.assign_driver(p_taxi uuid,p_driver uuid,p_start date,p_mode text,p_amount bigint,p_days integer[]) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_old public.assignments; begin
 perform private.require_member();
 perform 1 from public.taxis where id=p_taxi for update;
 if not found then raise exception 'Taxi no encontrado'; end if;
 select * into v_old from public.assignments where taxi_id=p_taxi and ends_on is null for update;
 if p_start is null or p_start < private.today() or p_start > private.today()+365 then raise exception 'Inicio fuera de rango'; end if;
 -- Correct an unstarted assignment in place; never move its dates, rewrite
 -- historical assignments, or transfer obligations/payments to another driver.
 if v_old.id is not null and v_old.starts_on > private.today() then
  if p_start<>v_old.starts_on or p_mode is distinct from v_old.mode then
   raise exception 'Para corregir la asignación futura conserve su fecha de inicio y modalidad';
  end if;
  if exists(select 1 from public.obligations where assignment_id=v_old.id)
     or exists(select 1 from public.payments where assignment_id=v_old.id) then
   raise exception 'No se puede corregir una asignación con movimientos financieros';
  end if;
  perform 1 from public.drivers where id=p_driver for update;
  if not found then raise exception 'Conductor no encontrado'; end if;
  if exists(select 1 from public.assignments where driver_id=p_driver and id<>v_old.id and (ends_on is null or ends_on>=p_start)) then
   raise exception 'Conductor con otra asignación vigente';
  end if;
  update public.assignments set driver_id=p_driver where id=v_old.id;
  update public.quota_rules set amount=case when p_mode='flexible' then 0 else p_amount end, weekdays=p_days
   where assignment_id=v_old.id and effective_on=v_old.starts_on;
  return v_old.id;
 end if;
 if v_old.id is not null then
  if v_old.starts_on >= p_start or p_start <= private.today() then raise exception 'El reemplazo debe iniciar mañana o después de la asignación actual'; end if;
  update public.assignments set ends_on=p_start-1 where id=v_old.id;
 end if;
 if exists(select 1 from public.assignments where driver_id=p_driver and (ends_on is null or ends_on>=p_start)) then
 raise exception 'Conductor con otra asignación vigente'; end if;
 -- Serialize across taxis when assigning the same driver.
 perform 1 from public.drivers where id=p_driver for update;
 if not found then raise exception 'Conductor no encontrado'; end if;
 -- Recheck after acquiring the shared driver lock.
 if exists(select 1 from public.assignments where driver_id=p_driver and (ends_on is null or ends_on>=p_start)) then
 raise exception 'Conductor con otra asignación vigente'; end if;
 insert into public.assignments(taxi_id,driver_id,starts_on,mode) values(p_taxi,p_driver,p_start,p_mode) returning id into v_id;
 insert into public.quota_rules(assignment_id,effective_on,amount,weekdays) values(v_id,p_start,case when p_mode='flexible' then 0 else p_amount end,p_days);
 return v_id;
end $$;

create function public.change_quota(p_assignment uuid,p_effective date,p_amount bigint,p_days integer[]) returns void
language plpgsql security definer set search_path = '' as $$ declare a public.assignments; begin
 perform private.require_member();
 select * into a from public.assignments where id=p_assignment for update;
 if a.id is null or a.mode<>'fixed' then raise exception 'Asignación fija no encontrada'; end if;
 if p_effective<=private.today() or p_effective<a.starts_on or (a.ends_on is not null and p_effective>a.ends_on) then
 raise exception 'La cuota solo puede cambiar para fechas futuras de la asignación'; end if;
 insert into public.quota_rules(assignment_id,effective_on,amount,weekdays) values(p_assignment,p_effective,p_amount,p_days)
 on conflict(assignment_id,effective_on) do update set amount=excluded.amount,weekdays=excluded.weekdays;
end $$;

create function private.generate(p_assignment uuid) returns void
language plpgsql security definer set search_path = '' as $$ declare a public.assignments; begin
 select * into a from public.assignments where id=p_assignment for update;
 if a.mode<>'fixed' then return; end if;
 insert into public.obligations(assignment_id,due_on,amount,exempt_reason)
 select a.id,d.day::date,r.amount,e.reason
 from generate_series(a.starts_on::timestamp,least(coalesce(a.ends_on,private.today()),private.today())::timestamp,interval '1 day') d(day)
 cross join lateral(select * from public.quota_rules where assignment_id=a.id and effective_on<=d.day::date order by effective_on desc limit 1) r
 left join public.exemptions e on e.assignment_id=a.id and e.day=d.day::date
 where extract(isodow from d.day)::integer=any(r.weekdays)
 on conflict(assignment_id,due_on) do nothing;
end $$;
create function public.generate_quotas() returns void
language plpgsql security definer set search_path = '' as $$ declare a record; begin
 perform private.require_member();
 for a in select id from public.assignments order by id loop perform private.generate(a.id); end loop;
end $$;

create function public.exempt_day(p_assignment uuid,p_day date,p_reason text) returns void
language plpgsql security definer set search_path = '' as $$ declare a public.assignments; begin
 perform private.require_member();
 select * into a from public.assignments where id=p_assignment for update;
 if a.id is null or a.mode<>'fixed' or p_day<a.starts_on or (a.ends_on is not null and p_day>a.ends_on) then raise exception 'Fecha fuera de la asignación fija'; end if;
 if exists(select 1 from public.allocations al join public.obligations o on o.id=al.obligation_id where o.assignment_id=a.id and o.due_on=p_day) then
 raise exception 'No se puede eximir una cuota que ya recibió abonos'; end if;
 insert into public.exemptions values(p_assignment,p_day,trim(p_reason)) on conflict(assignment_id,day) do update set reason=excluded.reason;
 update public.obligations set exempt_reason=trim(p_reason) where assignment_id=p_assignment and due_on=p_day;
end $$;

create function public.record_payment(p_id uuid,p_assignment uuid,p_amount bigint,p_day date,p_note text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare a public.assignments; old public.payments; item record; remaining bigint:=p_amount; part bigint; total bigint; begin
 perform private.require_member();
 -- A token is serialized even if a buggy client submits it for two assignments.
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
 select * into old from public.payments where id=p_id;
 if old.id is not null then
 if old.assignment_id is distinct from p_assignment or old.amount is distinct from p_amount or old.paid_on is distinct from p_day or old.note is distinct from p_note then raise exception 'Identificador de pago reutilizado con otros datos'; end if;
 return old.id; end if;
 select * into a from public.assignments where id=p_assignment for update;
 if a.id is null or p_day<a.starts_on or p_day>private.today() or p_amount is null or p_amount<=0 then raise exception 'Datos de pago inválidos'; end if;
 perform private.generate(a.id);
 if a.mode='fixed' then
 select coalesce(sum(o.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=o.id),0)),0) into total from public.obligations o where o.assignment_id=a.id and o.exempt_reason is null and o.due_on<=p_day;
 if p_amount>total then raise exception 'El pago supera la deuda. No se admiten anticipos en esta versión'; end if;
 end if;
 insert into public.payments(id,assignment_id,amount,paid_on,note,created_by) values(p_id,a.id,p_amount,p_day,p_note,auth.uid());
 if a.mode='fixed' then
 for item in select ob.id,ob.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=ob.id),0) as balance from public.obligations ob where ob.assignment_id=a.id and ob.exempt_reason is null and ob.due_on<=p_day order by ob.due_on,ob.id loop
 part:=least(remaining,item.balance); if part>0 then insert into public.allocations values(p_id,item.id,part); remaining:=remaining-part; end if;
 exit when remaining=0;
 end loop;
 end if; return p_id;
end $$;

-- The final read has one statement snapshot across all eight tables. At READ
-- COMMITTED, generation and that read may see different committed snapshots;
-- this is not a serializable snapshot of the entire RPC or multiple RPC calls.
create function public.dashboard() returns jsonb
language plpgsql security definer set search_path = '' as $$ begin
 perform private.require_member();
 perform public.generate_quotas();
 return jsonb_build_object(
  'taxis',(select coalesce(jsonb_agg(t order by t.slot),'[]'::jsonb) from public.taxis t),
  'drivers',(select coalesce(jsonb_agg(t order by t.name),'[]'::jsonb) from public.drivers t),
  'assignments',(select coalesce(jsonb_agg(t order by t.starts_on desc,t.id),'[]'::jsonb) from public.assignments t),
  'quota_rules',(select coalesce(jsonb_agg(t order by t.effective_on,t.id),'[]'::jsonb) from public.quota_rules t),
  'obligations',(select coalesce(jsonb_agg(t order by t.due_on desc,t.id),'[]'::jsonb) from public.obligations t),
  'exemptions',(select coalesce(jsonb_agg(t order by t.day desc,t.assignment_id),'[]'::jsonb) from public.exemptions t),
  'payments',(select coalesce(jsonb_agg(t order by t.created_at desc,t.id),'[]'::jsonb) from public.payments t),
  'allocations',(select coalesce(jsonb_agg(t order by t.payment_id,t.obligation_id),'[]'::jsonb) from public.allocations t)
 );
end $$;

-- Explicit execution grants: no anonymous RPC access, private helpers not callable.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_member() to authenticated;
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('save_taxi','save_driver','assign_driver','change_quota','generate_quotas','exempt_day','record_payment','dashboard') loop
 execute format('revoke all on function %s from public, anon, authenticated',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end $$;
commit;

