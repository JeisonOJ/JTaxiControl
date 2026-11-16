-- Payment cancellation preserves original rows and allocations for audit.
begin;
alter table public.payments
 add column cancelled_at timestamptz,
 add column cancelled_by uuid references auth.users,
 add column cancellation_reason text check(length(cancellation_reason)<=300),
 add column cancellation_id uuid unique,
 add constraint cancellation_complete check (
 (cancelled_at is null and cancelled_by is null and cancellation_id is null and cancellation_reason is null)
 or (cancelled_at is not null and cancelled_by is not null and cancellation_id is not null));
alter table public.allocations add column reversed_at timestamptz;

create function public.cancel_payment(p_id uuid,p_payment uuid,p_reason text default '') returns uuid
language plpgsql security definer set search_path='' as $$
declare original public.payments; taxi uuid; stamp timestamptz; begin
 perform private.require_member();
 if p_id is null or p_payment is null or p_reason is null or length(p_reason)>300 then raise exception 'Datos de anulación inválidos'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,3));
 select a.taxi_id into taxi from public.payments p join public.assignments a on a.id=p.assignment_id where p.id=p_payment;
 if taxi is null then raise exception 'Pago no encontrado'; end if;
 -- Same order as payment/finance writers: taxi, assignment, payment.
 perform 1 from public.taxis where id=taxi for update;
 perform 1 from public.assignments a join public.payments p on p.assignment_id=a.id where p.id=p_payment for update of a;
 select * into original from public.payments where id=p_payment for update;
 if original.cancelled_at is not null then
  if original.cancellation_id=p_id and original.cancellation_reason=p_reason then return original.id; end if;
  raise exception 'Este pago ya fue anulado. Actualiza el historial';
 end if;
 stamp:=clock_timestamp();
 update public.payments set cancelled_at=stamp,cancelled_by=auth.uid(),cancellation_reason=p_reason,cancellation_id=p_id where id=p_payment;
 update public.allocations set reversed_at=stamp where payment_id=p_payment;
 -- Recompute the entire daily cash/debt history without the cancelled payment.
 if exists(select 1 from (
 select sum(cash) over(order by day) cash,sum(owner_debt) over(order by day) debt from (
 select day,sum(cash) cash,sum(owner_debt) owner_debt from (
 select opened_on as day,cash,owner_debt from public.taxi_openings where taxi_id=taxi
 union all select p.paid_on,p.amount,0::bigint from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=taxi and p.cancelled_at is null
 union all select day,case when kind='advance' then amount else -amount end,case when kind='advance' then amount when kind='repayment' then -amount else 0 end from public.finance_entries where taxi_id=taxi
 ) movements group by day) daily) running where cash<0 or debt<0) then
 raise exception 'No se puede anular: el dinero respalda gastos o devoluciones y la anulación dejaría un saldo histórico negativo'; end if;
 return original.id;
end $$;
revoke all on function public.cancel_payment(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.cancel_payment(uuid,uuid,text) to authenticated;

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
 union all select p.paid_on as day,p.amount cash,0::bigint owner_debt from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=p_taxi and p.cancelled_at is null
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
 coalesce((select sum(p.amount) from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id and p.cancelled_at is null and p.paid_on between month_start and month_end),0) income,
 coalesce((select sum(e.amount) from public.finance_entries e where e.taxi_id=t.id and e.kind='expense' and e.day between month_start and month_end),0) expenses,
 coalesce((select cash from public.taxi_openings where taxi_id=t.id and opened_on<=month_end),0)+coalesce((select sum(p.amount) from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id and p.cancelled_at is null and p.paid_on<=month_end),0)+coalesce((select sum(case when e.kind='advance' then e.amount else -e.amount end) from public.finance_entries e where e.taxi_id=t.id and e.day<=month_end),0) fund,
 coalesce((select owner_debt from public.taxi_openings where taxi_id=t.id and opened_on<=month_end),0)+coalesce((select sum(case when e.kind='advance' then e.amount when e.kind='repayment' then -e.amount else 0 end) from public.finance_entries e where e.taxi_id=t.id and e.day<=month_end),0) owner_debt,
 coalesce((select sum(o.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=o.id and al.reversed_at is null),0)) from public.obligations o join public.assignments a on a.id=o.assignment_id where a.taxi_id=t.id and o.exempt_reason is null and o.due_on<=private.today()),0) driver_debt
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
 select coalesce(sum(o.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=o.id and al.reversed_at is null),0)),0) into total from public.obligations o where o.assignment_id=a.id and o.exempt_reason is null and o.due_on<=p_day;
 if p_amount>total then raise exception 'El pago supera la deuda. No se admiten anticipos en esta versión'; end if;
 end if;
 insert into public.payments(id,assignment_id,amount,paid_on,note,created_by) values(p_id,a.id,p_amount,p_day,p_note,auth.uid());
 if a.mode='fixed' then
 for item in select ob.id,ob.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=ob.id and al.reversed_at is null),0) as balance from public.obligations ob where ob.assignment_id=a.id and ob.exempt_reason is null and ob.due_on<=p_day order by ob.due_on,ob.id loop
 part:=least(remaining,item.balance); if part>0 then insert into public.allocations values(p_id,item.id,part); remaining:=remaining-part; end if;
 exit when remaining=0;
 end loop;
 end if; return p_id;
end $$;



create or replace function public.exempt_day(p_assignment uuid,p_day date,p_reason text) returns void
language plpgsql security definer set search_path = '' as $$ declare a public.assignments; begin
 perform private.require_member();
 select * into a from public.assignments where id=p_assignment for update;
 if a.id is null or a.mode<>'fixed' or p_day<a.starts_on or (a.ends_on is not null and p_day>a.ends_on) then raise exception 'Fecha fuera de la asignación fija'; end if;
 if exists(select 1 from public.allocations al join public.obligations o on o.id=al.obligation_id where al.reversed_at is null and o.assignment_id=a.id and o.due_on=p_day) then
 raise exception 'No se puede eximir una cuota que ya recibió abonos'; end if;
 insert into public.exemptions values(p_assignment,p_day,trim(p_reason)) on conflict(assignment_id,day) do update set reason=excluded.reason;
 update public.obligations set exempt_reason=trim(p_reason) where assignment_id=p_assignment and due_on=p_day;
end $$;


-- Existing RLS and restricted RPC grants are preserved by CREATE OR REPLACE.
commit;
