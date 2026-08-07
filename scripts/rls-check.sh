#!/usr/bin/env bash
# Row-level security, checked without the hosted project.
#
#   scripts/rls-check.sh
#
# A scratch Postgres, a ~10-line stub of the parts of Supabase's auth schema
# the policies reference, then every migration in supabase/migrations replayed
# in order. Scenarios are driven with `set local role authenticated` plus a
# `request.jwt.claims` of the account being impersonated, which is exactly what
# PostgREST does — so the policies are evaluated for real, not approximated.
#
# This is how the sharing policies were verified before they shipped, and it is
# where the phone-identity mismatch is reproduced: a membership row written
# with a national number and no country code, which `is_share_member` can never
# match, so RLS correctly hides the whole group from the person it was for.
#
# Needs Docker, so it is not part of scripts/e2e.sh — CI has no daemon. The
# live half of the same boundary runs there instead, in `share_checks`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CT="${MANAS_RLS_CONTAINER:-manas-rls-check}"
PASS() { printf '\033[32m✔ %s\033[0m\n' "$1"; }
FAIL() { printf '\033[31m✘ %s\033[0m\n' "$1"; exit 1; }

docker rm -f "$CT" >/dev/null 2>&1 || true
trap 'docker rm -f "$CT" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$CT" -e POSTGRES_PASSWORD=pg postgres:15-alpine >/dev/null
for _ in $(seq 1 60); do
  docker exec "$CT" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 0.5
done

q() { docker exec -i "$CT" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
# -q so psql's "SET" command tags stay out of the captured value.
val() { docker exec -i "$CT" psql -U postgres -d postgres -Atqc "$1"; }
# What one account can see, through the real policies.
as() { val "set local role authenticated;
             set local request.jwt.claims = '{\"phone\":\"$1\"}';
             $2"; }

echo "== Scratch Postgres + auth stub"
q -q <<'SQL'
create schema auth;
create table auth.users (id uuid primary key, phone text unique);
create role authenticated;
grant usage on schema auth, public to authenticated;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;
SQL

for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  q -q < "$f" >/dev/null || FAIL "migration $(basename "$f")"
done
q -q -c "grant all on all tables in schema public to authenticated;" >/dev/null
PASS "migrations replay clean ($(ls "$REPO_ROOT"/supabase/migrations/*.sql | wc -l | tr -d ' ') files)"

echo "== Phone identity: the 10-vs-11-digit membership mismatch"

OWNER=13042164370          # the owner's JWT phone, country code and all
INVITEE=13098264765        # the invitee's JWT phone
NATIONAL=3098264765        # the same person, typed as "(309) 826-4765"
STRANGER=15555550100
NO_ACCOUNT=16472992144     # invited, international, but has not signed up yet
SHARE=9eb7c592-0fc3-46cc-9dfe-b3d3228c3881

# Seed the pre-fix shape. The canonicalizing trigger is switched off for the
# seed on purpose: the point is to recreate rows that were written before it
# existed, by clients that are still out there.
q -q <<SQL >/dev/null
insert into auth.users (id, phone) values
  (gen_random_uuid(), '$OWNER'), (gen_random_uuid(), '$INVITEE'),
  (gen_random_uuid(), '$STRANGER');
alter table public.shared_group_members disable trigger shared_group_members_canonical_phone;
insert into public.shared_groups (id, name, owner_id, created_at)
  values ('$SHARE', 'Apt buy list', '$OWNER', now());
insert into public.shared_group_members (id, share_id, phone, created_at) values
  (gen_random_uuid(), '$SHARE', '$OWNER', now()),
  (gen_random_uuid(), '$SHARE', '$NATIONAL', now()),
  (gen_random_uuid(), '$SHARE', '$NO_ACCOUNT', now());
insert into public.todos (id, user_id, author_id, text, day, created_at, share_id) values
  (gen_random_uuid(), '$OWNER', '$OWNER', 'A shared line', current_date, now(), '$SHARE'),
  (gen_random_uuid(), '$OWNER', '$OWNER', 'Another shared line', current_date, now(), '$SHARE');
alter table public.shared_group_members enable trigger shared_group_members_canonical_phone;
SQL

groups_seen() { as "$1" "select count(*) from public.shared_groups;"; }
todos_seen() { as "$1" "select count(*) from public.todos;"; }

[[ "$(groups_seen "$INVITEE")" == "0" ]] || FAIL "expected the old mismatch to hide the group"
[[ "$(todos_seen "$INVITEE")" == "0" ]] || FAIL "expected the old mismatch to hide the todos"
PASS "reproduced: a roster row of $NATIONAL hides the group and both todos from $INVITEE"

[[ "$(groups_seen "$OWNER")" == "1" && "$(todos_seen "$OWNER")" == "2" ]] \
  || FAIL "the owner lost their own group"
PASS "the owner sees everything throughout — which is why this looked fine from their device"

echo "== The repair"
# Replaying the migration a second time is what `supabase db push` will do to a
# project that has never seen it; it must be safe to run against live rows.
q -q < "$REPO_ROOT/supabase/migrations/20260807060000_canonical_member_phones.sql" >/dev/null

repaired="$(val "select phone from public.shared_group_members where phone like '%$NATIONAL';")"
[[ "$repaired" == "$INVITEE" ]] || FAIL "the repair left the roster row as '$repaired'"
PASS "the roster row is now $INVITEE"

bystander="$(val "select phone from public.shared_group_members where phone like '%6472992144';")"
[[ "$bystander" == "$NO_ACCOUNT" ]] || FAIL "the repair rewrote an already-international row ('$bystander')"
PASS "an invite to somebody who has not signed up yet is left exactly as it was"

[[ "$(groups_seen "$INVITEE")" == "1" ]] || FAIL "the group still does not reach the invitee"
[[ "$(todos_seen "$INVITEE")" == "2" ]] || FAIL "the todos still do not reach the invitee"
PASS "the group and both todos now reach $INVITEE"

echo "== The trigger, for clients that have not updated"
q -q -c "delete from public.shared_group_members where phone = '$INVITEE';" >/dev/null
as "$OWNER" "insert into public.shared_group_members (id, share_id, phone, created_at)
             values (gen_random_uuid(), '$SHARE', '$NATIONAL', now());" >/dev/null
written="$(val "select phone from public.shared_group_members where phone like '%$NATIONAL';")"
[[ "$written" == "$INVITEE" ]] || FAIL "an old client's national-number invite was stored as '$written'"
PASS "a shipped client's national-number invite is canonicalized on write"
[[ "$(groups_seen "$INVITEE")" == "1" ]] || FAIL "the re-invite does not reach the invitee"
PASS "the re-invite reaches them"

echo "== The boundary the repair must not move"
[[ "$(groups_seen "$STRANGER")" == "0" ]] || FAIL "RLS breach: an outsider sees the group"
[[ "$(todos_seen "$STRANGER")" == "0" ]] || FAIL "RLS breach: an outsider sees shared todos"
PASS "an outsider still sees nothing"

# Normalization runs before the policy's WITH CHECK, so it has to be proved it
# is not a way in: an outsider writing their own number, country code missing,
# is still an outsider.
joined="$(as "$STRANGER" "insert into public.shared_group_members (id, share_id, phone, created_at)
                          values (gen_random_uuid(), '$SHARE', '5555550100', now()) returning 1;" 2>&1 || true)"
[[ "$joined" != "1" ]] || FAIL "RLS breach: an outsider joined a group by writing a national number"
PASS "an outsider cannot join by leaving off their country code"

echo
echo "== RLS: ALL PASS"
