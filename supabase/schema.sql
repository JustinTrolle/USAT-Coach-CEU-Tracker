-- CEU Tracker schema. Applied to Supabase project "USAT Education".
create extension if not exists pgcrypto;

-- Who may read/write dashboard data. Auth users not on this list get nothing.
create table if not exists public.allowed_users (
  email text primary key,
  display_name text,
  added_at timestamptz not null default now()
);

create or replace function public.is_allowed()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.allowed_users
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

create or replace function public.norm_key(t text)
returns text language sql immutable
as $$ select lower(regexp_replace(trim(coalesce(t, '')), '\s+', ' ', 'g')); $$;

create table if not exists public.catalog_products (
  id bigserial primary key,
  product_code text,
  name text not null,
  name_key text generated always as (public.norm_key(name)) stored,
  product_type text,
  ceu_raw text,
  ceu_value numeric not null default 0,
  ceu_type text not null default 'official' check (ceu_type in ('official','adjunct','none')),
  price text,
  source text not null default 'upload' check (source in ('upload','manual')),
  updated_at timestamptz not null default now(),
  updated_by text
);
create unique index if not exists catalog_products_name_key_idx on public.catalog_products(name_key);

create table if not exists public.coaches (
  credential_number text primary key,
  level text not null,
  level_rank int not null default 1,
  name text,
  name_key text generated always as (public.norm_key(name)) stored,
  city text,
  state text,
  type text,
  status text,
  phone text,
  email text,
  email_key text generated always as (public.norm_key(email)) stored,
  bg_status text,
  bg_expiration date,
  ss_status text,
  ss_expiration date,
  active boolean,
  list_name text,
  uploaded_at timestamptz not null default now()
);
create index if not exists coaches_email_key_idx on public.coaches(email_key);
create index if not exists coaches_name_key_idx on public.coaches(name_key);

create table if not exists public.orders (
  order_id bigint primary key,
  order_number text,
  student text,
  student_key text generated always as (public.norm_key(student)) stored,
  email text,
  email_key text generated always as (public.norm_key(email)) stored,
  order_date date,
  current_value numeric,
  status text,
  payment_method text,
  product text,
  product_key text generated always as (public.norm_key(product)) stored,
  instructors text,
  coupon_code text,
  user_id text,
  uploaded_at timestamptz not null default now()
);
create index if not exists orders_email_key_idx on public.orders(email_key);
create index if not exists orders_student_key_idx on public.orders(student_key);
create index if not exists orders_product_key_idx on public.orders(product_key);
create index if not exists orders_order_date_idx on public.orders(order_date);

create table if not exists public.coach_notes (
  id bigserial primary key,
  credential_number text not null,
  note text not null,
  author_email text,
  created_at timestamptz not null default now()
);
create index if not exists coach_notes_cred_idx on public.coach_notes(credential_number);

-- Name-fallback matches the staff have confirmed or rejected.
create table if not exists public.coach_aliases (
  credential_number text not null,
  email_key text not null,
  status text not null check (status in ('confirmed','rejected')),
  decided_by text,
  decided_at timestamptz not null default now(),
  primary key (credential_number, email_key)
);

create table if not exists public.uploads (
  id bigserial primary key,
  kind text not null check (kind in ('coaches','orders','catalog')),
  file_name text,
  row_count int,
  detail jsonb,
  uploaded_by text,
  uploaded_at timestamptz not null default now()
);

-- Row level security: only allow-listed, signed-in staff.
do $$
declare t text;
begin
  foreach t in array array['allowed_users','catalog_products','coaches','orders','coach_notes','coach_aliases','uploads'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists staff_all on public.%I', t);
    execute format('create policy staff_all on public.%I for all to authenticated using (public.is_allowed()) with check (public.is_allowed())', t);
  end loop;
end $$;

-- Atomic replace of the coach list.
create or replace function public.replace_coaches(p_rows jsonb, p_list_name text, p_file_name text)
returns int
language plpgsql security invoker
set search_path = public
as $$
declare n int;
begin
  if not public.is_allowed() then raise exception 'not allowed'; end if;
  -- "where true" satisfies pg_safeupdate, which the API role runs with.
  delete from public.coaches where true;
  insert into public.coaches (credential_number, level, level_rank, name, city, state, type, status, phone, email,
                              bg_status, bg_expiration, ss_status, ss_expiration, active, list_name)
  select r->>'credential_number', r->>'level', (r->>'level_rank')::int, r->>'name', r->>'city', r->>'state',
         r->>'type', r->>'status', r->>'phone', r->>'email',
         r->>'bg_status', nullif(r->>'bg_expiration','')::date, r->>'ss_status', nullif(r->>'ss_expiration','')::date,
         (r->>'active')::boolean, p_list_name
  from jsonb_array_elements(p_rows) r
  on conflict (credential_number) do nothing;
  get diagnostics n = row_count;
  insert into public.uploads (kind, file_name, row_count, detail, uploaded_by)
  values ('coaches', p_file_name, n, jsonb_build_object('list_name', p_list_name), auth.jwt() ->> 'email');
  return n;
end $$;

-- Upsert a chunk of orders keyed on Thinkific Order ID.
create or replace function public.upsert_orders(p_rows jsonb)
returns int
language plpgsql security invoker
set search_path = public
as $$
declare n int;
begin
  if not public.is_allowed() then raise exception 'not allowed'; end if;
  insert into public.orders (order_id, order_number, student, email, order_date, current_value, status, payment_method,
                             product, instructors, coupon_code, user_id)
  select (r->>'order_id')::bigint, r->>'order_number', r->>'student', r->>'email', nullif(r->>'order_date','')::date,
         nullif(r->>'current_value','')::numeric, r->>'status', r->>'payment_method', r->>'product',
         r->>'instructors', r->>'coupon_code', r->>'user_id'
  from jsonb_array_elements(p_rows) r
  where r->>'order_id' is not null
  on conflict (order_id) do update set
    order_number = excluded.order_number, student = excluded.student, email = excluded.email,
    order_date = excluded.order_date, current_value = excluded.current_value, status = excluded.status,
    payment_method = excluded.payment_method, product = excluded.product, instructors = excluded.instructors,
    coupon_code = excluded.coupon_code, user_id = excluded.user_id, uploaded_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.log_upload(p_kind text, p_file_name text, p_row_count int, p_detail jsonb)
returns void
language sql security invoker
set search_path = public
as $$
  insert into public.uploads (kind, file_name, row_count, detail, uploaded_by)
  values (p_kind, p_file_name, p_row_count, p_detail, auth.jwt() ->> 'email');
$$;

-- Replace uploaded catalog rows; manual rows survive unless the upload names the same product.
create or replace function public.replace_catalog(p_rows jsonb, p_file_name text)
returns int
language plpgsql security invoker
set search_path = public
as $$
declare n int;
begin
  if not public.is_allowed() then raise exception 'not allowed'; end if;
  delete from public.catalog_products where source = 'upload';
  insert into public.catalog_products (product_code, name, product_type, ceu_raw, ceu_value, ceu_type, price, source, updated_by)
  select distinct on (public.norm_key(r->>'name'))
         r->>'product_code', r->>'name', r->>'product_type', r->>'ceu_raw',
         coalesce(nullif(r->>'ceu_value','')::numeric, 0), coalesce(r->>'ceu_type','official'), r->>'price', 'upload', auth.jwt() ->> 'email'
  from jsonb_array_elements(p_rows) r
  where nullif(trim(r->>'name'), '') is not null
  on conflict (name_key) do update set
    product_code = excluded.product_code, name = excluded.name, product_type = excluded.product_type,
    ceu_raw = excluded.ceu_raw, ceu_value = excluded.ceu_value, ceu_type = excluded.ceu_type,
    price = excluded.price, source = 'upload', updated_at = now(), updated_by = excluded.updated_by;
  get diagnostics n = row_count;
  insert into public.uploads (kind, file_name, row_count, uploaded_by)
  values ('catalog', p_file_name, n, auth.jwt() ->> 'email');
  return n;
end $$;
