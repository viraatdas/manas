-- Move the todos' identity from a Supabase-native user UUID to the phone
-- number, so the same person reaches the same todos whether they signed in
-- through Supabase phone auth (mac — 'phone' claim, e.g. '15555550100') or
-- Firebase phone auth (iOS — 'phone_number' claim, e.g. '+15555550100').
-- Normalizing to digits makes both formats resolve to one identity.

create or replace function public.current_phone_id() returns text
language sql stable as $$
  select regexp_replace(
    coalesce(nullif(auth.jwt() ->> 'phone_number', ''), auth.jwt() ->> 'phone'),
    '[^0-9]', '', 'g')
$$;

-- The uuid FK to auth.users no longer applies (Firebase users have no
-- auth.users row), and the policies reference the old uuid identity.
alter table public.todos drop constraint if exists todos_user_id_fkey;
drop policy if exists "own todos select" on public.todos;
drop policy if exists "own todos insert" on public.todos;
drop policy if exists "own todos update" on public.todos;
drop policy if exists "own todos delete" on public.todos;

-- Switch user_id to the phone identity. Existing rows were keyed by the
-- +15555550100 test account's UUID; re-key them to that number's digits.
alter table public.todos alter column user_id drop default;
alter table public.todos alter column user_id type text using user_id::text;
update public.todos set user_id = '15555550100'
  where user_id = '4dab823f-44ea-46f9-862b-d0654b286397';
alter table public.todos alter column user_id set default public.current_phone_id();

create policy "own todos select" on public.todos for select using (public.current_phone_id() = user_id);
create policy "own todos insert" on public.todos for insert with check (public.current_phone_id() = user_id);
create policy "own todos update" on public.todos for update using (public.current_phone_id() = user_id);
create policy "own todos delete" on public.todos for delete using (public.current_phone_id() = user_id);
