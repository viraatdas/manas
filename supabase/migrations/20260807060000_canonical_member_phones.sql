-- Membership rows must be keyed by the same digits the JWT gives up.
--
-- `current_phone_id()` is E.164 digits — country code and all — because a JWT
-- phone always is. But the invite field took the number as a person says it,
-- and a US number said out loud has no country code in it: "(309) 826-4765"
-- was stored as its bare ten digits while the account it names authenticates
-- as eleven. `is_share_member()` compares the two with `=`, so it was false
-- forever, and row-level security did exactly what it should — it hid the
-- group, and every todo in it, from the person it had been shared with. The
-- share looked complete on the owner's device and empty on theirs.
--
-- Fixing the client is necessary but not sufficient: the rows already written
-- stay wrong, and the shipped clients keep writing more until everybody
-- updates. So the server takes over the rule, in three parts — a function
-- that canonicalizes a number against a reference, a trigger that applies it
-- to every write, and a one-time repair of what is already stored.

-- The reference is a number known to be canonical from the same country:
-- the caller's own identity for a live write, the group owner's for the
-- repair below. Within one country every national number is the same length,
-- so whatever the reference carries in front of a number this long *is* its
-- country code. That is the whole rule, and it needs no table of national
-- formats — which is what keeps it from being a `+1` special case wearing a
-- general name.
--
-- Deliberately conservative in both directions: a number already at least as
-- long as the reference is left exactly as it is (it is already
-- international, or it is from somewhere else and we have nothing to say
-- about it), and a country code of more than four digits is not one, so the
-- value is returned untouched rather than mangled. The client applies the
-- same rule and is stricter still — it also checks the derived code against
-- the calling codes it knows and refuses the write otherwise, so it can ask
-- for a `+` instead of storing something that reaches nobody.
create or replace function public.canonical_phone_id(
  p_phone text,
  p_reference text
)
returns text
language plpgsql
immutable
as $$
declare
  digits text;
  reference text;
  dial text;
begin
  digits := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  reference := regexp_replace(coalesce(p_reference, ''), '[^0-9]', '', 'g');

  if digits = '' or reference = '' then
    return digits;
  end if;

  -- The single leading zero most countries dial in front of a national number
  -- and drop when writing it internationally. No calling code begins with a
  -- zero, so this can never be eating one; the reference check keeps it off
  -- the regions that have no trunk prefix, where a leading zero is a typo.
  if length(digits) > 1 and left(digits, 1) = '0' and left(reference, 1) <> '0' then
    digits := substr(digits, 2);
  end if;

  if length(digits) >= length(reference) then
    return digits;
  end if;

  dial := left(reference, length(reference) - length(digits));
  if length(dial) > 4 then
    return digits;
  end if;
  return dial || digits;
end;
$$;

-- Every write, from every client version. A BEFORE trigger runs ahead of the
-- policy's WITH CHECK, so the row the policy judges is the canonical one —
-- which also means a member whose device still holds the old ten-digit form
-- of their own number can push it and have it accepted, rather than being
-- rejected for writing "somebody else's" row.
--
-- The reference is the caller: whoever is inviting. It is null for the
-- service role, and then this is a no-op, which is what the repair below
-- relies on.
create or replace function public.canonicalize_member_phone()
returns trigger
language plpgsql
as $$
begin
  new.phone := public.canonical_phone_id(new.phone, public.current_phone_id());
  return new;
end;
$$;

drop trigger if exists shared_group_members_canonical_phone on public.shared_group_members;
create trigger shared_group_members_canonical_phone
  before insert or update on public.shared_group_members
  for each row execute function public.canonicalize_member_phone();

-- The repair. Two independent rules, strongest evidence first, applied only
-- to rows that are demonstrably short — a row already as long as its group's
-- owner is international and is left alone (an invite to somebody who has not
-- signed up yet looks exactly like that, and must survive untouched).

-- 1. An account whose number ends with these digits, with one to four extra
--    in front — the shape of a national number written without its country
--    code. Only when there is exactly one such account: two would make it a
--    guess, and a guess would hand somebody else's group to the wrong person.
--    This branch reads auth.users, which is why it lives in the migration and
--    not in the trigger: run on every client write it would turn a membership
--    row into an oracle for "which registered number ends in these digits?".
with resolved as (
  select m.id, u.phone as canonical
  from public.shared_group_members m
  join public.shared_groups g on g.id = m.share_id
  join auth.users u
    on u.phone like '%' || m.phone
   and length(u.phone) - length(m.phone) between 1 and 4
  where length(m.phone) < length(g.owner_id)
  group by m.id, u.phone
  having count(*) = 1
)
update public.shared_group_members m
set phone = r.canonical,
    -- Bumped on purpose: share rows converge by last-write-wins on
    -- updated_at, so without this every device that still holds the broken
    -- row would win the next merge and write it straight back.
    updated_at = now()
from resolved r
where m.id = r.id
  and m.phone <> r.canonical
  -- Never collide with the same person already correctly on the roster.
  and not exists (
    select 1 from public.shared_group_members other
    where other.share_id = m.share_id and other.phone = r.canonical
  );

-- 2. Whatever is left: borrow the country code from the group's owner, whose
--    identity came from their own JWT and so is canonical by construction.
update public.shared_group_members m
set phone = public.canonical_phone_id(m.phone, g.owner_id),
    updated_at = now()
from public.shared_groups g
where g.id = m.share_id
  and length(m.phone) < length(g.owner_id)
  and public.canonical_phone_id(m.phone, g.owner_id) <> m.phone
  and not exists (
    select 1 from public.shared_group_members other
    where other.share_id = m.share_id
      and other.phone = public.canonical_phone_id(m.phone, g.owner_id)
  );

-- A row that survived both rules is a duplicate of one already canonical on
-- the same roster — the same person invited twice, once each way. Tombstone
-- the short one so no client keeps trying to push it.
update public.shared_group_members m
set deleted = true,
    updated_at = now()
from public.shared_groups g
where g.id = m.share_id
  and not m.deleted
  and length(m.phone) < length(g.owner_id)
  and exists (
    select 1 from public.shared_group_members other
    where other.share_id = m.share_id
      and other.phone = public.canonical_phone_id(m.phone, g.owner_id)
  );
