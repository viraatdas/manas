#!/usr/bin/env bash
# Brings up the Manas sync backend on Supabase from nothing, end to end:
# project → schema → phone-OTP auth (test numbers) → smoke test. Idempotent —
# safe to re-run after a partial failure.
#
#   scripts/backend-up.sh            # create (or reuse) the project + configure
#
# Requires an authenticated supabase CLI and one free active-project slot on
# the account (the free plan allows two; pause or upgrade one on
# https://supabase.com/dashboard if creation is rejected).
#
# After success it prints the project URL + anon key and writes
# supabase/BACKEND.md; paste the two values into
# Sources/Manas/Sync/SupabaseConfig.swift and rebuild both apps.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPA_DIR="$REPO_ROOT/supabase"
ORG_ID="mnsursgxxpajjocvmvwb"
NAME="manas"
REGION="us-west-1"

mkdir -p "$SUPA_DIR"
if [[ ! -f "$SUPA_DIR/.dbpassword" ]]; then
  openssl rand -base64 24 | tr -d '/+=' | head -c 28 > "$SUPA_DIR/.dbpassword"
fi
PW="$(cat "$SUPA_DIR/.dbpassword")"

REF="$(supabase projects list --output json \
  | python3 -c 'import json,sys; print(next((p["id"] for p in json.load(sys.stdin) if p["name"]=="'"$NAME"'"), ""))')"

if [[ -z "$REF" ]]; then
  echo "==> Creating project $NAME ($REGION)"
  supabase projects create "$NAME" --org-id "$ORG_ID" --region "$REGION" --db-password "$PW"
  REF="$(supabase projects list --output json \
    | python3 -c 'import json,sys; print(next((p["id"] for p in json.load(sys.stdin) if p["name"]=="'"$NAME"'"), ""))')"
fi
[[ -n "$REF" ]] || { echo "error: project ref not found after create" >&2; exit 1; }
echo "==> Project ref: $REF"

echo "==> Waiting for the project to come up"
for _ in $(seq 1 30); do
  STATUS="$(supabase projects list --output json \
    | python3 -c 'import json,sys; print(next((p.get("status","") for p in json.load(sys.stdin) if p["id"]=="'"$REF"'"), ""))')"
  [[ "$STATUS" == "ACTIVE_HEALTHY" ]] && break
  echo "   status: $STATUS — waiting"
  sleep 20
done
[[ "$STATUS" == "ACTIVE_HEALTHY" ]] || { echo "error: project never became healthy" >&2; exit 1; }

echo "==> Linking + pushing schema"
(cd "$REPO_ROOT" && supabase link --project-ref "$REF" --password "$PW")
(cd "$REPO_ROOT" && supabase db push --password "$PW")

echo "==> Pushing auth config (phone sign-in, test OTP numbers)"
(cd "$REPO_ROOT" && yes | supabase config push)

ANON_KEY="$(supabase projects api-keys --project-ref "$REF" --output json \
  | python3 -c 'import json,sys; keys=json.load(sys.stdin); print(next(k["api_key"] for k in keys if k.get("name")=="anon"))')"
URL="https://$REF.supabase.co"

echo "==> Smoke test: phone OTP with a test number"
curl -sf -X POST "$URL/auth/v1/otp" -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" -d '{"phone":"+15555550100"}' > /dev/null
TOKEN="$(curl -sf -X POST "$URL/auth/v1/verify" -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"phone":"+15555550100","token":"123456","type":"sms"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
[[ -n "$TOKEN" ]] && echo "   auth OK (access token issued)"

cat > "$SUPA_DIR/BACKEND.md" <<MD
# Manas sync backend

- Project ref: \`$REF\` (org $ORG_ID, $REGION)
- API URL: \`$URL\`
- Anon key (publishable): \`$ANON_KEY\`
- Table: \`public.todos\` (see migrations/), RLS per user
- Phone sign-in: test OTP numbers (no SMS provider yet)
  - +1 555 555 0100 → code 123456
  - +1 415 555 0137 → code 123456
- Real SMS later: add [auth.sms.twilio] credentials to supabase/config.toml
  and re-run \`supabase config push\`.

Client config lives in Sources/Manas/Sync/SupabaseConfig.swift.
MD
echo "==> Wrote supabase/BACKEND.md"
echo "==> URL:      $URL"
echo "==> anon key: $ANON_KEY"
