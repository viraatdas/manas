# Manas sync backend

- Project ref: `gdnknuiqxmosuwoytrzc` (org vflvqypmpwkvgbhxuvvr, us-west-1)
- API URL: `https://gdnknuiqxmosuwoytrzc.supabase.co`
- Anon key (publishable; RLS is the security boundary): see
  `Sources/Manas/Sync/SupabaseConfig.swift`
- Table: `public.todos` (migrations/20260723120000_todos.sql), RLS per user,
  last-write-wins by `updated_at`, deletions as tombstones
- Sharing (migrations/20260806120000_shared_groups.sql): `public.shared_groups`
  + `public.shared_group_members`, and `todos.share_id` / `todos.author_id`.
  A todo is visible to another number only when `share_id` points at a group
  that number belongs to — a matching `group_name` never grants access.
  - `public.is_share_member(uuid)` / `public.is_share_owner(uuid)` are
    SECURITY DEFINER on purpose: the policies on `shared_group_members` would
    otherwise consult themselves and recurse.
  - Writes are `(share_id is null and current_phone_id() = user_id) or
    is_share_member(share_id)`. Do **not** loosen this to
    `current_phone_id() = user_id or is_share_member(...)`: `user_id` defaults
    to the caller's own number, so anyone holding a share id could post rows
    into it. Verified against a scratch Postgres, including the PostgREST
    upsert path (`on conflict do update` applies the INSERT `with check` to
    the final row, which is why the rule can't key on `author_id`).
  - `author_id` is stamped by the `todos_stamp_author` trigger when a client
    sends null — a column default alone doesn't fire, because the client
    encodes nullable columns explicitly as JSON null for PostgREST.
- Phone sign-in: test OTP numbers only for now (no real SMS provider)
  - +1 555 555 0100 → code 123456
  - +1 415 555 0137 → code 123456
- Real SMS later: put real Twilio credentials in `[auth.sms.twilio]` in
  supabase/config.toml (auth token via the SUPABASE_AUTH_SMS_TWILIO_AUTH_TOKEN
  env var), add your own number under `[auth.sms.test_otp]` or remove the
  block, then `supabase config push`.
- DB password: supabase/.dbpassword (gitignored)

Verified 2026-07-23: OTP request 200, verify issues a JWT, authed insert/select/
delete work, anonymous select returns nothing (RLS).
