-- Opening balances are historical balances, never payments or owner advances.
-- Apply after 003. No existing rows are changed or initialized implicitly.
begin;
create table public.taxi_openings (
 taxi_id uuid primary key references public.taxis,
 id uuid not null unique,
 opened_on date not null check(opened_on between date '2000-01-01' and date '2100-01-01'),
 cash bigint not null default 0 check(cash between 0 and 1000000000000),
 owner_debt bigint not null default 0 check(owner_debt between 0 and 1000000000000),
 created_by uuid not null references auth.users,
 created_at timestamptz not null default now()
);
alter table public.taxi_openings enable row level security;
revoke all on public.taxi_openings from public,anon,authenticated;
grant select on public.taxi_openings to authenticated;
create policy member_read on public.taxi_openings for select to authenticated using(private.is_member());
create function public.initialize_taxi(p_id uuid,p_taxi uuid,p_day date,p_cash bigint default 0,p_owner_debt bigint default 0) returns uuid
language plpgsql security definer set search_path='' as $$ declare old public.taxi_openings; begin
 perform private.require_member();
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,2));
 perform 1 from public.taxis where id=p_taxi for update;
 if not found then raise exception 'Taxi no encontrado'; end if;
 select * into old from public.taxi_openings where taxi_id=p_taxi;
 if found then
 if row(old.id,old.opened_on,old.cash,old.owner_debt) is distinct from row(p_id,p_day,p_cash,p_owner_debt) then
 raise exception 'Este taxi ya tiene saldos iniciales confirmados; no se pueden sobrescribir'; end if;
 return old.id; end if;
 if p_day is null or p_day>private.today() then raise exception 'Fecha de apertura inválida'; end if;
 if exists(select 1 from public.finance_entries where taxi_id=p_taxi)
 or exists(select 1 from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=p_taxi) then
 raise exception 'Ya hay movimientos financieros. Los saldos iniciales deben configurarse antes del primer cobro, gasto o aporte'; end if;
 insert into public.taxi_openings(taxi_id,id,opened_on,cash,owner_debt,created_by) values(p_taxi,p_id,p_day,p_cash,p_owner_debt,auth.uid());
 return p_id;
end $$;
revoke all on function public.initialize_taxi(uuid,uuid,date,bigint,bigint) from public,anon,authenticated;
grant execute on function public.initialize_taxi(uuid,uuid,date,bigint,bigint) to authenticated;

-- Replace only the financial calculations and payment guard; preserve RPC signatures.
create or replace function public.record_finance(p_id uuid,p_taxi uuid,p_kind text,p_amount bigint,p_day date,p_category text,p_note text,p_due uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare old public.finance_entries; due public.finance_dues; begin
 perform private.require_member();
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,1));
 select * into old from public.finance_entries where id=p_id;
 if found then
 if row(old.taxi_id,old.kind,old.amount,old.day,old.category,old.note,old.due_id) is distinct from row(p_taxi,p_kind,p_amount,p_day,p_category,p_note,p_due) then raise exception 'Identificador reutilizado con otros datos'; end if;
 return old.id; end if;
 perform 1 from public.taxis where id=p_taxi for update;
 if not found then raise exception 'Taxi no encontrado'; end if;
 if p_day is null or p_day>private.today() or p_day<date '2000-01-01' then raise exception 'Fecha de movimiento inválida'; end if;
 if exists(select 1 from public.taxi_openings where taxi_id=p_taxi and opened_on>p_day) then raise exception 'La fecha es anterior al saldo inicial'; end if;
 if p_due is not null then
 select * into due from public.finance_dues where id=p_due for update;
 if not found or due.taxi_id<>p_taxi or p_kind is distinct from 'expense' or p_category is distinct from due.category or (due.amount is not null and due.amount is distinct from p_amount) then raise exception 'Obligación o importe incompatible'; end if;
 select * into old from public.finance_entries where due_id=p_due;
 if found then
 if row(old.taxi_id,old.kind,old.amount,old.day,old.category,old.note) is distinct from row(p_taxi,p_kind,p_amount,p_day,p_category,p_note) then raise exception 'La obligación ya tiene un gasto registrado'; end if;
 return old.id; end if;
 end if;
 insert into public.finance_entries(id,taxi_id,kind,amount,day,category,note,due_id,created_by)
 values(p_id,p_taxi,p_kind,p_amount,p_day,p_category,p_note,p_due,auth.uid());
 -- Validate every daily prefix, so backdated expenses cannot spend later income.
 if exists(select 1 from (
 select sum(cash) over(order by day) cash,sum(owner_debt) over(order by day) debt from (
 select day,sum(cash) cash,sum(owner_debt) owner_debt from (
 select opened_on as day,cash,owner_debt from public.taxi_openings where taxi_id=p_taxi
 union all select p.paid_on as day,p.amount cash,0::bigint owner_debt from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=p_taxi
 union all select day,case when kind='advance' then amount else -amount end,case when kind='advance' then amount when kind='repayment' then -amount else 0 end from public.finance_entries where taxi_id=p_taxi
 ) movements group by day) daily) running where cash<0 or debt<0) then
 raise exception 'Fondos insuficientes o devolución superior a la deuda con el propietario en esa fecha'; end if;
 return p_id;
end $$;
create or replace function public.finance_dashboard(p_month date) returns jsonb
language plpgsql security definer set search_path='' as $$ declare result jsonb; month_start date; month_end date; begin
 perform private.require_member();
 if p_month is null or p_month<date '2000-01-01' or p_month>private.today() then raise exception 'Mes inválido'; end if;
 month_start:=date_trunc('month',p_month)::date; month_end:=least((month_start+interval '1 month - 1 day')::date,private.today());
 perform private.finance_generate();
 select jsonb_build_object(
 'summaries',(select coalesce(jsonb_agg(s order by slot),'[]'::jsonb) from (
 select t.id,t.slot,t.plate,
 exists(select 1 from public.taxi_openings where taxi_id=t.id) opening_initialized,
 (select opened_on from public.taxi_openings where taxi_id=t.id) opened_on,
 coalesce((select cash from public.taxi_openings where taxi_id=t.id),0) opening_cash,
 coalesce((select owner_debt from public.taxi_openings where taxi_id=t.id),0) opening_owner_debt,
 not exists(select 1 from public.taxi_openings where taxi_id=t.id)
 and not exists(select 1 from public.finance_entries where taxi_id=t.id)
 and not exists(select 1 from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id) can_initialize,
 coalesce((select sum(p.amount) from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id and p.paid_on between month_start and month_end),0) income,
 coalesce((select sum(e.amount) from public.finance_entries e where e.taxi_id=t.id and e.kind='expense' and e.day between month_start and month_end),0) expenses,
 coalesce((select cash from public.taxi_openings where taxi_id=t.id and opened_on<=month_end),0)+coalesce((select sum(p.amount) from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id and p.paid_on<=month_end),0)+coalesce((select sum(case when e.kind='advance' then e.amount else -e.amount end) from public.finance_entries e where e.taxi_id=t.id and e.day<=month_end),0) fund,
 coalesce((select owner_debt from public.taxi_openings where taxi_id=t.id and opened_on<=month_end),0)+coalesce((select sum(case when e.kind='advance' then e.amount when e.kind='repayment' then -e.amount else 0 end) from public.finance_entries e where e.taxi_id=t.id and e.day<=month_end),0) owner_debt,
 coalesce((select sum(o.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=o.id),0)) from public.obligations o join public.assignments a on a.id=o.assignment_id where a.taxi_id=t.id and o.exempt_reason is null and o.due_on<=private.today()),0) driver_debt
 from public.taxis t) s),
 'entries',(select coalesce(jsonb_agg(e order by e.day desc,e.created_at desc),'[]'::jsonb) from public.finance_entries e where e.day between month_start and month_end),
 'dues',(select coalesce(jsonb_agg(d order by d.due_on,d.id),'[]'::jsonb) from (select d.*,e.id payment_id,e.amount paid_amount from public.finance_dues d left join public.finance_entries e on e.due_id=d.id) d)
 ) into result;
 return result;
end $$;

create or replace function public.record_payment(p_id uuid,p_assignment uuid,p_amount bigint,p_day date,p_note text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_taxi uuid; a public.assignments; old public.payments; item record; remaining bigint:=p_amount; part bigint; total bigint; begin
 perform private.require_member();
 -- A token is serialized even if a buggy client submits it for two assignments.
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,0));
 select * into old from public.payments where id=p_id;
 if old.id is not null then
 if old.assignment_id is distinct from p_assignment or old.amount is distinct from p_amount or old.paid_on is distinct from p_day or old.note is distinct from p_note then raise exception 'Identificador de pago reutilizado con otros datos'; end if;
 return old.id; end if;
 -- All cash mutations and opening setup serialize on the same taxi first.
 select taxi_id into v_taxi from public.assignments where id=p_assignment;
 perform 1 from public.taxis where id=v_taxi for update;
 if exists(select 1 from public.taxi_openings where taxi_id=v_taxi and opened_on>p_day) then raise exception 'La fecha es anterior al saldo inicial'; end if;
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


-- CREATE OR REPLACE retains the restricted existing execution ACLs.
commit;
