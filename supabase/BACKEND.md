# Manas sync backend

- Project ref: `gdnknuiqxmosuwoytrzc` (org vflvqypmpwkvgbhxuvvr, us-west-1)
- API URL: `https://gdnknuiqxmosuwoytrzc.supabase.co`
- Anon key (publishable; RLS is the security boundary): see
  `Sources/Manas/Sync/SupabaseConfig.swift`
- Table: `public.todos` (migrations/20260723120000_todos.sql), RLS per user,
  last-write-wins by `updated_at`, deletions as tombstones
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
