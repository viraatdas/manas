-- Shared groups: a todo group that more than one phone number can see and add
-- to. Identity is already the phone number (see 20260723200000_phone_identity),
-- so sharing is simply "this group is also visible to these other numbers".
--
-- Two tables rather than an array column, because membership is edited one
-- person at a time from two devices and needs its own last-write-wins row.
-- Both carry `deleted` + `updated_at` like `todos` do, so revoking a share
-- converges offline instead of needing a live DELETE to land.

create table public.shared_groups (
  id uuid primary key,
  name text not null,
  emoji text,
  owner_id text not null default public.current_phone_id(),
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

create table public.shared_group_members (
  id uuid primary key,
  share_id uuid not null references public.shared_groups (id) on delete cascade,
  phone text not null,
  display_name text,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false,
  unique (share_id, phone)
);

create index shared_group_members_phone on public.shared_group_members (phone);
create index shared_groups_owner on public.shared_groups (owner_id);

-- The membership test every policy below is built on.
--
-- SECURITY DEFINER is required, not decorative: the select policy on
-- shared_group_members has to ask "is the caller in this share?", which reads
-- shared_group_members, which would re-enter its own policy forever. Running
-- the lookup as the definer steps outside RLS and breaks the cycle; the pinned
-- search_path keeps those definer rights from resolving anything unexpected.
-- auth.jwt() still reads the request's claims inside a definer function, so
-- current_phone_id() remains the *caller's* number, not the definer's.
create or replace function public.is_share_member(p_share_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.shared_group_members m
    where m.share_id = p_share_id
      and m.phone = public.current_phone_id()
      and not m.deleted
  );
$$;

-- Deliberately does not exclude tombstoned groups: revoking a share is itself
-- an owner write, and it marks the group and its members deleted in the same
-- pass. Losing ownership the moment the group row flips would reject the
-- member tombstones that have to follow it.
create or replace function public.is_share_owner(p_share_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.shared_groups g
    where g.id = p_share_id
      and g.owner_id = public.current_phone_id()
  );
$$;

alter table public.shared_groups enable row level security;
alter table public.shared_group_members enable row level security;

-- A share is readable by its owner and by everyone in it; only the owner
-- writes it, so a member can't rename or revoke someone else's group.
create policy "shared groups select" on public.shared_groups for select
  using (owner_id = public.current_phone_id() or public.is_share_member(id));
create policy "shared groups insert" on public.shared_groups for insert
  with check (owner_id = public.current_phone_id());
create policy "shared groups update" on public.shared_groups for update
  using (owner_id = public.current_phone_id())
  with check (owner_id = public.current_phone_id());
create policy "shared groups delete" on public.shared_groups for delete
  using (owner_id = public.current_phone_id());

-- Membership is readable by the whole group (that is how the avatars know who
-- is in it). The owner adds and removes people; a member may edit only their
-- own row, which is how they set the name they appear under and how they
-- leave a group they were invited to.
--
-- The self-write branch is `phone = me AND already a member`, never `phone =
-- me` alone: without the second half, anyone holding a share's id could write
-- themselves a membership row and walk into somebody else's group. Requiring
-- existing membership means the row can be edited but not conjured.
create policy "shared group members select" on public.shared_group_members for select
  using (public.is_share_member(share_id) or public.is_share_owner(share_id));
create policy "shared group members insert" on public.shared_group_members for insert
  with check (
    public.is_share_owner(share_id)
    or (phone = public.current_phone_id() and public.is_share_member(share_id))
  );
create policy "shared group members update" on public.shared_group_members for update
  using (
    public.is_share_owner(share_id)
    or (phone = public.current_phone_id() and public.is_share_member(share_id))
  )
  with check (
    public.is_share_owner(share_id)
    or (phone = public.current_phone_id() and public.is_share_member(share_id))
  );
create policy "shared group members delete" on public.shared_group_members for delete
  using (public.is_share_owner(share_id) or phone = public.current_phone_id());

-- Todos gain the two columns sharing needs: which shared group the row belongs
-- to (null = private, the default for every existing row), and who wrote it.
alter table public.todos
  add column share_id uuid references public.shared_groups (id) on delete set null,
  add column author_id text;

-- Backfill: everything written so far was written by its owner.
update public.todos set author_id = user_id where author_id is null;

-- Stamp the author server-side when the client leaves it out. A default alone
-- is not enough: the client encodes nullable columns explicitly as JSON null
-- (PostgREST rejects a bulk upsert with uneven keys), and an explicit null
-- suppresses a column default.
create or replace function public.stamp_todo_author()
returns trigger
language plpgsql
as $$
begin
  if new.author_id is null then
    new.author_id := public.current_phone_id();
  end if;
  return new;
end;
$$;

create trigger todos_stamp_author
  before insert on public.todos
  for each row execute function public.stamp_todo_author();

create index todos_share on public.todos (share_id) where share_id is not null;

-- Access widens from "my rows" to "my rows, plus every row in a group shared
-- with me". Members can update and delete each other's rows in a shared group
-- on purpose: checking off a shared todo is the point of sharing one.
--
-- Reading is the plain union. Writing is deliberately narrower: a *private*
-- row must be your own, and a *shared* row requires membership. Written as
-- the looser `user_id = me OR is_share_member(...)`, anyone holding a share's
-- id could post rows into it — user_id defaults to their own number, so the
-- first branch would wave it through and every member would then see it.
--
-- Note what the write rule does not allow: pulling somebody else's row out of
-- a shared group. The final row would be private and not yours, which fails
-- both branches. That is the intended shape — their line in a shared list is
-- theirs to be checked off or deleted, not re-filed — and the client mirrors
-- it so the case never reaches the server as a rejected write.
--
-- The rule cannot be tightened to `author_id = me` for writes: PostgREST
-- upserts with ON CONFLICT DO UPDATE, and Postgres applies the INSERT
-- policy's WITH CHECK to the *final* row, so that would block a member from
-- ever ticking a box on a row somebody else wrote. Within one shared group,
-- then, a member can write a row attributed to another member — inside the
-- trust the user created by sharing, and reachable nowhere else.
drop policy if exists "own todos select" on public.todos;
drop policy if exists "own todos insert" on public.todos;
drop policy if exists "own todos update" on public.todos;
drop policy if exists "own todos delete" on public.todos;

create policy "todos select" on public.todos for select
  using (public.current_phone_id() = user_id or public.is_share_member(share_id));
create policy "todos insert" on public.todos for insert
  with check (
    (share_id is null and public.current_phone_id() = user_id)
    or public.is_share_member(share_id)
  );
create policy "todos update" on public.todos for update
  using (public.current_phone_id() = user_id or public.is_share_member(share_id))
  with check (
    (share_id is null and public.current_phone_id() = user_id)
    or public.is_share_member(share_id)
  );
create policy "todos delete" on public.todos for delete
  using (public.current_phone_id() = user_id or public.is_share_member(share_id));
