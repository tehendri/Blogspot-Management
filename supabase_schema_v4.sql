-- Blog Management Online v4.0
-- Supabase / PostgreSQL schema
-- Run this once in Supabase SQL Editor for a new project.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  timezone text not null default 'Asia/Jakarta',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.gmail_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  status text not null default 'active' check (status in ('active','inactive','blocked')),
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, email)
);

create table if not exists public.blogs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  domain text not null,
  category text not null default 'General',
  status text not null default 'available' check (status in ('available','creating','claimed','active','inactive')),
  notes text not null default '',
  account_id uuid references public.gmail_accounts(id) on delete set null,
  creation_started_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, name)
);

create table if not exists public.creation_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  blog_id uuid references public.blogs(id) on delete set null,
  account_id uuid references public.gmail_accounts(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  default_browser text not null default 'default',
  dark_mode boolean not null default false,
  timezone text not null default 'Asia/Jakarta',
  updated_at timestamptz not null default now()
);

create index if not exists idx_gmail_accounts_user_id on public.gmail_accounts(user_id);
create index if not exists idx_blogs_user_id on public.blogs(user_id);
create index if not exists idx_blogs_user_account on public.blogs(user_id, account_id);
create index if not exists idx_blogs_user_status on public.blogs(user_id, status);
create index if not exists idx_creation_logs_user_created on public.creation_logs(user_id, created_at desc);
create index if not exists idx_creation_logs_user_account on public.creation_logs(user_id, account_id, created_at desc);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do update set email = excluded.email, updated_at = now();
  insert into public.user_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at before update on public.profiles for each row execute procedure public.set_updated_at();
drop trigger if exists trg_gmail_accounts_updated_at on public.gmail_accounts;
create trigger trg_gmail_accounts_updated_at before update on public.gmail_accounts for each row execute procedure public.set_updated_at();
drop trigger if exists trg_blogs_updated_at on public.blogs;
create trigger trg_blogs_updated_at before update on public.blogs for each row execute procedure public.set_updated_at();

create or replace function public.validate_blog_owner()
returns trigger
language plpgsql
security invoker
as $$
begin
  if new.user_id <> auth.uid() then
    raise exception 'Invalid user ownership';
  end if;
  if new.account_id is not null then
    if not exists (select 1 from public.gmail_accounts a where a.id = new.account_id and a.user_id = new.user_id) then
      raise exception 'Account does not belong to current user';
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if old.user_id <> auth.uid() then
      raise exception 'Invalid existing row owner';
    end if;
    if old.status <> 'available' and old.account_id is distinct from new.account_id and new.account_id is not null then
      raise exception 'Started blogs cannot be reassigned to another account';
    end if;
    if old.status = 'available' and new.status in ('creating','claimed','active') then
      if not exists (
        select 1 from public.creation_logs l
        where l.blog_id = new.id
          and l.account_id = new.account_id
          and l.user_id = new.user_id
      ) then
        raise exception 'Creation must be started through start_blog_creation()';
      end if;
    end if;
  elsif tg_op = 'INSERT' and new.status in ('creating','claimed') then
    raise exception 'Creation must be started through start_blog_creation()';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_blog_owner on public.blogs;
create trigger trg_validate_blog_owner
before insert or update on public.blogs
for each row execute procedure public.validate_blog_owner();

create or replace function public.start_blog_creation(p_blog_id uuid, p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  acc_status text;
  blog_status text;
  blog_owner uuid;
  total_count integer;
  daily_count integer;
  hourly_count integer;
  last_creation timestamptz;
  user_tz text := 'Asia/Jakarta';
  now_ts timestamptz := now();
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select timezone into user_tz from public.profiles where id = uid;
  if user_tz is null or user_tz = '' then user_tz := 'Asia/Jakarta'; end if;

  select status into acc_status
  from public.gmail_accounts
  where id = p_account_id and user_id = uid
  for update;
  if acc_status is null then raise exception 'Akun Gmail tidak ditemukan'; end if;
  if acc_status <> 'active' then raise exception 'Akun Gmail tidak aktif'; end if;

  select status, user_id into blog_status, blog_owner
  from public.blogs
  where id = p_blog_id and user_id = uid
  for update;
  if blog_owner is null then raise exception 'Blog tidak ditemukan'; end if;
  if blog_status <> 'available' then raise exception 'Blog tidak lagi berstatus Available'; end if;

  select count(*) into total_count
  from public.blogs
  where user_id = uid and account_id = p_account_id and status in ('creating','claimed','active');

  select count(*) into daily_count
  from public.creation_logs
  where user_id = uid and account_id = p_account_id
    and ((created_at at time zone user_tz)::date = (now_ts at time zone user_tz)::date);

  select count(*) into hourly_count
  from public.creation_logs
  where user_id = uid and account_id = p_account_id
    and created_at >= now_ts - interval '1 hour';

  select max(created_at) into last_creation
  from public.creation_logs
  where user_id = uid and account_id = p_account_id;

  if total_count >= 100 then raise exception 'Quota total akun sudah penuh'; end if;
  if daily_count >= 10 then raise exception 'Quota pembuatan hari ini sudah habis'; end if;
  if hourly_count >= 3 then raise exception 'Quota pembuatan per jam sudah habis'; end if;
  if last_creation is not null and last_creation > now_ts - interval '5 minutes' then
    raise exception 'Cooldown 5 menit belum selesai';
  end if;

  insert into public.creation_logs(user_id, blog_id, account_id, created_at)
  values (uid, p_blog_id, p_account_id, now_ts);

  update public.blogs
  set account_id = p_account_id,
      status = 'creating',
      creation_started_at = now_ts,
      updated_at = now_ts
  where id = p_blog_id and user_id = uid;

  return jsonb_build_object('ok', true, 'blog_id', p_blog_id, 'account_id', p_account_id,
    'totalBlogs', total_count + 1, 'todayCount', daily_count + 1, 'hourCount', hourly_count + 1);
end;
$$;

grant execute on function public.start_blog_creation(uuid, uuid) to authenticated;
revoke execute on function public.start_blog_creation(uuid, uuid) from anon;

create or replace function public.clear_all_user_data()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  delete from public.creation_logs where user_id = uid;
  delete from public.blogs where user_id = uid;
  delete from public.gmail_accounts where user_id = uid;
  delete from public.user_settings where user_id = uid;
  insert into public.user_settings(user_id) values (uid);
end;
$$;

grant execute on function public.clear_all_user_data() to authenticated;
revoke execute on function public.clear_all_user_data() from anon;

-- RLS
alter table public.profiles enable row level security;
alter table public.gmail_accounts enable row level security;
alter table public.blogs enable row level security;
alter table public.creation_logs enable row level security;
alter table public.user_settings enable row level security;

revoke all on table public.profiles from anon, authenticated;
revoke all on table public.gmail_accounts from anon, authenticated;
revoke all on table public.blogs from anon, authenticated;
revoke all on table public.creation_logs from anon, authenticated;
revoke all on table public.user_settings from anon, authenticated;
grant select, update on table public.profiles to authenticated;
grant select, insert, update, delete on table public.gmail_accounts to authenticated;
grant select, insert, update, delete on table public.blogs to authenticated;
grant select on table public.creation_logs to authenticated;
grant select, insert, update, delete on table public.user_settings to authenticated;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using ((select auth.uid()) = id);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

drop policy if exists accounts_select_own on public.gmail_accounts;
create policy accounts_select_own on public.gmail_accounts for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists accounts_insert_own on public.gmail_accounts;
create policy accounts_insert_own on public.gmail_accounts for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists accounts_update_own on public.gmail_accounts;
create policy accounts_update_own on public.gmail_accounts for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists accounts_delete_own on public.gmail_accounts;
create policy accounts_delete_own on public.gmail_accounts for delete to authenticated using ((select auth.uid()) = user_id);

 drop policy if exists blogs_select_own on public.blogs;
create policy blogs_select_own on public.blogs for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists blogs_insert_own on public.blogs;
create policy blogs_insert_own on public.blogs for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists blogs_update_own on public.blogs;
create policy blogs_update_own on public.blogs for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists blogs_delete_own on public.blogs;
create policy blogs_delete_own on public.blogs for delete to authenticated using ((select auth.uid()) = user_id);

 drop policy if exists logs_select_own on public.creation_logs;
create policy logs_select_own on public.creation_logs for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists settings_select_own on public.user_settings;
create policy settings_select_own on public.user_settings for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists settings_insert_own on public.user_settings;
create policy settings_insert_own on public.user_settings for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists settings_update_own on public.user_settings;
create policy settings_update_own on public.user_settings for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists settings_delete_own on public.user_settings;
create policy settings_delete_own on public.user_settings for delete to authenticated using ((select auth.uid()) = user_id);

-- Realtime: add the tables to supabase_realtime publication.
do $$
declare t text;
begin
  foreach t in array array['gmail_accounts','blogs','creation_logs','user_settings'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
