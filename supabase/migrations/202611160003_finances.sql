-- Phase 2 is additive: no Phase 1 rows, functions or identifiers are rewritten.
begin;
create table public.finance_templates (
 id uuid primary key, taxi_id uuid not null references public.taxis,
 title text not null check(length(trim(title)) between 2 and 120),
 category text not null check(category in ('maintenance','parts','insurance','tax','administration','other')),
 amount bigint check(amount between 1 and 100000000),
 first_due date not null check(first_due between date '2000-01-01' and date '2100-01-01'),
 every_months integer not null check(every_months in (0,1,3,6,12)),
 created_by uuid not null references auth.users, created_at timestamptz not null default now()
);
create table public.finance_dues (
 id uuid primary key default gen_random_uuid(), template_id uuid not null references public.finance_templates,
 taxi_id uuid not null references public.taxis, due_on date not null,
 title text not null, category text not null, amount bigint,
 unique(template_id,due_on)
);
create table public.finance_entries (
 id uuid primary key, taxi_id uuid not null references public.taxis,
 kind text not null check(kind in ('expense','advance','repayment')),
 amount bigint not null check(amount between 1 and 100000000), day date not null,
 category text not null check(category in ('maintenance','parts','insurance','tax','administration','other')),
 note text not null check(length(trim(note)) between 2 and 300),
 due_id uuid unique references public.finance_dues,
 created_by uuid not null references auth.users, created_at timestamptz not null default now(),
 check(due_id is null or kind='expense')
);
create index finance_entries_taxi_day on public.finance_entries(taxi_id,day);
create index finance_dues_taxi_date on public.finance_dues(taxi_id,due_on);
do $$ declare t text; begin
 foreach t in array array['finance_templates','finance_dues','finance_entries'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy member_read on public.%I for select to authenticated using (private.is_member())',t);
 end loop;
end $$;
create function private.finance_generate() returns void
language sql security definer set search_path='' as $$
 -- Anchor every occurrence to first_due, not to the previous occurrence:
 -- Jan 29/30/31 -> Feb 28 (29 in leap years) -> Mar 29/30/31.
 -- A Feb 28 anchor recurs on Mar 28; this is not a last-day-of-month rule.
 -- Derive the series bound from the actual 62-day cutoff: that window may
 -- span three month boundaries. The WHERE clause checks the exact day.
 insert into public.finance_dues(template_id,taxi_id,due_on,title,category,amount)
 select t.id,t.taxi_id,(t.first_due+make_interval(months=>n.i*t.every_months))::date,t.title,t.category,t.amount
 from public.finance_templates t
 cross join lateral generate_series(0,case when t.every_months=0 then 0 else
 greatest(0,((extract(year from (private.today()+62))::int-extract(year from t.first_due)::int)*12+extract(month from (private.today()+62))::int-extract(month from t.first_due)::int)/t.every_months) end) n(i)
 where n.i=0 or (t.first_due+make_interval(months=>n.i*t.every_months))::date<=private.today()+62
 on conflict(template_id,due_on) do nothing;
$$;
create function public.create_finance_template(p_id uuid,p_taxi uuid,p_title text,p_category text,p_amount bigint,p_first date,p_every integer) returns uuid
language plpgsql security definer set search_path='' as $$ declare old public.finance_templates; begin
 perform private.require_member();
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,1));
 select * into old from public.finance_templates where id=p_id;
 if found then
 if row(old.taxi_id,old.title,old.category,old.amount,old.first_due,old.every_months) is distinct from row(p_taxi,p_title,p_category,p_amount,p_first,p_every) then raise exception 'Identificador reutilizado con otros datos'; end if;
 return old.id; end if;
 insert into public.finance_templates values(p_id,p_taxi,p_title,p_category,p_amount,p_first,p_every,auth.uid(),now());
 perform private.finance_generate(); return p_id;
end $$;
create function public.record_finance(p_id uuid,p_taxi uuid,p_kind text,p_amount bigint,p_day date,p_category text,p_note text,p_due uuid default null) returns uuid
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
 select p.paid_on as day,p.amount cash,0::bigint owner_debt from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=p_taxi
 union all select day,case when kind='advance' then amount else -amount end,case when kind='advance' then amount when kind='repayment' then -amount else 0 end from public.finance_entries where taxi_id=p_taxi
 ) movements group by day) daily) running where cash<0 or debt<0) then
 raise exception 'Fondos insuficientes o devolución superior a la deuda con el propietario en esa fecha'; end if;
 return p_id;
end $$;
create function public.finance_dashboard(p_month date) returns jsonb
language plpgsql security definer set search_path='' as $$ declare result jsonb; month_start date; month_end date; begin
 perform private.require_member();
 if p_month is null or p_month<date '2000-01-01' or p_month>private.today() then raise exception 'Mes inválido'; end if;
 month_start:=date_trunc('month',p_month)::date; month_end:=least((month_start+interval '1 month - 1 day')::date,private.today());
 perform private.finance_generate();
 select jsonb_build_object(
 'summaries',(select coalesce(jsonb_agg(s order by slot),'[]'::jsonb) from (
 select t.id,t.slot,t.plate,
 coalesce((select sum(p.amount) from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id and p.paid_on between month_start and month_end),0) income,
 coalesce((select sum(e.amount) from public.finance_entries e where e.taxi_id=t.id and e.kind='expense' and e.day between month_start and month_end),0) expenses,
 coalesce((select sum(p.amount) from public.payments p join public.assignments a on a.id=p.assignment_id where a.taxi_id=t.id and p.paid_on<=month_end),0)+coalesce((select sum(case when e.kind='advance' then e.amount else -e.amount end) from public.finance_entries e where e.taxi_id=t.id and e.day<=month_end),0) fund,
 coalesce((select sum(case when e.kind='advance' then e.amount when e.kind='repayment' then -e.amount else 0 end) from public.finance_entries e where e.taxi_id=t.id and e.day<=month_end),0) owner_debt,
 coalesce((select sum(o.amount-coalesce((select sum(al.amount) from public.allocations al where al.obligation_id=o.id),0)) from public.obligations o join public.assignments a on a.id=o.assignment_id where a.taxi_id=t.id and o.exempt_reason is null and o.due_on<=private.today()),0) driver_debt
 from public.taxis t) s),
 'entries',(select coalesce(jsonb_agg(e order by e.day desc,e.created_at desc),'[]'::jsonb) from public.finance_entries e where e.day between month_start and month_end),
 'dues',(select coalesce(jsonb_agg(d order by d.due_on,d.id),'[]'::jsonb) from (select d.*,e.id payment_id,e.amount paid_amount from public.finance_dues d left join public.finance_entries e on e.due_id=d.id) d)
 ) into result;
 return result;
end $$;
revoke all on function private.finance_generate() from public,anon,authenticated;
revoke all on function public.create_finance_template(uuid,uuid,text,text,bigint,date,integer) from public,anon,authenticated;
revoke all on function public.record_finance(uuid,uuid,text,bigint,date,text,text,uuid) from public,anon,authenticated;
revoke all on function public.finance_dashboard(date) from public,anon,authenticated;
grant execute on function public.create_finance_template(uuid,uuid,text,text,bigint,date,integer), public.record_finance(uuid,uuid,text,bigint,date,text,text,uuid), public.finance_dashboard(date) to authenticated;
commit;

