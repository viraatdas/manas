-- The one table behind cross-device sync: each user's todos, last-write-wins
-- by updated_at, deletions kept as tombstones so they propagate instead of
-- resurrecting. Row-level security scopes every operation to the signed-in
-- user; clients never filter by user_id themselves.
create table public.todos (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  text text not null,
  day date not null,
  group_name text,
  is_done boolean not null default false,
  verdict jsonb,
  position double precision not null default 0,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public.todos enable row level security;

create policy "own todos select" on public.todos for select using (auth.uid() = user_id);
create policy "own todos insert" on public.todos for insert with check (auth.uid() = user_id);
create policy "own todos update" on public.todos for update using (auth.uid() = user_id);
create policy "own todos delete" on public.todos for delete using (auth.uid() = user_id);

create index todos_user_updated on public.todos (user_id, updated_at);
