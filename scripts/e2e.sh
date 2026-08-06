#!/usr/bin/env bash
# The whole system, verified in one command:
#
#   scripts/e2e.sh              # everything below
#   scripts/e2e.sh backend      # just the live-backend checks (fast, curl-only)
#
# 1. macOS build + full unit suite
# 2. Live backend contract: phone sign-in ENABLED (the guard that catches the
#    "config push silently disabled phone login" class of bug), OTP request,
#    verify -> JWT, authed CRUD, RLS blocking anonymous reads, and the
#    shared-group boundary driven from two real accounts at once
# 3. Live client integration: the shipped auth + sync code driving a full
#    two-device conversation through the real backend (MANAS_E2E=1 tests)
# 4. iOS app + widget simulator build
#
# Exits non-zero on the first failure. CI runs this on every push.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-all}"
PASS() { printf '\033[32m✔ %s\033[0m\n' "$1"; }
FAIL() { printf '\033[31m✘ %s\033[0m\n' "$1"; exit 1; }

# Read the live backend coordinates straight from the client config, so the
# tests can never drift from what the apps actually ship with.
URL="$(sed -n 's/.*URL(string: "\(https[^"]*\)").*/\1/p' Sources/Manas/Sync/SupabaseConfig.swift)"
ANON="$(sed -n 's/.*anonKey = "\([^"]*\)".*/\1/p' Sources/Manas/Sync/SupabaseConfig.swift)"
[[ -n "$URL" && -n "$ANON" && "$ANON" != REPLACE* ]] || FAIL "SupabaseConfig.swift has no live backend"

backend_checks() {
  echo "== Live backend contract ($URL)"

  local phone_enabled
  phone_enabled="$(curl -sf "$URL/auth/v1/settings" -H "apikey: $ANON" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("external",{}).get("phone"))')"
  [[ "$phone_enabled" == "True" ]] || FAIL "phone sign-in is DISABLED on the backend (auth settings external.phone=$phone_enabled)"
  PASS "phone sign-in enabled"

  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL/auth/v1/otp" \
    -H "apikey: $ANON" -H "Content-Type: application/json" -d '{"phone":"+14155550137"}')"
  # 429 means the 5s per-number throttle from a very recent run — not a fault.
  [[ "$code" == "200" || "$code" == "429" ]] || FAIL "OTP request returned $code"
  PASS "OTP request accepted ($code)"

  local token
  token="$(curl -sf -X POST "$URL/auth/v1/verify" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d '{"phone":"+14155550137","token":"123456","type":"sms"}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
  [[ -n "$token" ]] || FAIL "verify did not issue an access token"
  PASS "verify issues a JWT"

  local rid="deadbeef-0000-4000-8000-00000000e2e0"
  local insert
  insert="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL/rest/v1/todos" \
    -H "apikey: $ANON" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"id\":\"$rid\",\"text\":\"e2e probe\",\"day\":\"2026-01-01\",\"created_at\":\"2026-01-01T00:00:00Z\",\"position\":0}")"
  [[ "$insert" == "201" ]] || FAIL "authed insert returned $insert"
  local fetched
  fetched="$(curl -sf "$URL/rest/v1/todos?id=eq.$rid&select=text" -H "apikey: $ANON" -H "Authorization: Bearer $token")"
  [[ "$fetched" == '[{"text":"e2e probe"}]' ]] || FAIL "authed select returned $fetched"
  PASS "authed insert + select"

  local anon_read
  anon_read="$(curl -sf "$URL/rest/v1/todos?select=id" -H "apikey: $ANON")"
  [[ "$anon_read" == "[]" ]] || FAIL "RLS breach: anonymous select returned $anon_read"
  PASS "RLS blocks anonymous reads"

  curl -s -o /dev/null -X DELETE "$URL/rest/v1/todos?id=eq.$rid" \
    -H "apikey: $ANON" -H "Authorization: Bearer $token"
  PASS "cleanup"
}

# Sharing widens the todos policies from "my rows" to "my rows plus every row
# in a group shared with me", which is the only place in this system where one
# account can reach another's data at all. One signed-in account cannot test
# that boundary — it takes two, which the two test numbers in
# supabase/BACKEND.md make possible without a single secret in CI.
#
# The positive case (a shared row travels) is covered by the client suite. What
# lives here is the negative half: the things a member of one group must NOT be
# able to do to a row that is not theirs. Every assertion re-reads the row
# afterwards rather than trusting the status code, because a policy that denies
# a write via USING returns a cheerful 200 and zero rows changed.
share_checks() {
  echo "== Shared-group RLS boundary (two accounts)"

  local a_token b_token
  a_token="$(curl -sf -X POST "$URL/auth/v1/verify" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d '{"phone":"+14155550137","token":"123456","type":"sms"}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
  b_token="$(curl -sf -X POST "$URL/auth/v1/verify" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d '{"phone":"+15555550100","token":"123456","type":"sms"}' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
  [[ -n "$a_token" && -n "$b_token" ]] || FAIL "could not sign in both test accounts"

  local a_id="14155550137" b_id="15555550100"
  local sg_a="deadbeef-0000-4000-8000-0000000005a1"
  local sg_b="deadbeef-0000-4000-8000-0000000005b1"
  local row="deadbeef-0000-4000-8000-0000000005c1"
  local mem_a="deadbeef-0000-4000-8000-00000000a001"
  local mem_b="deadbeef-0000-4000-8000-00000000a002"
  local mem_c="deadbeef-0000-4000-8000-00000000b001"

  as_a() { curl -s -H "apikey: $ANON" -H "Authorization: Bearer $a_token" -H "Content-Type: application/json" "$@"; }
  as_b() { curl -s -H "apikey: $ANON" -H "Authorization: Bearer $b_token" -H "Content-Type: application/json" "$@"; }

  # Clean any wreckage from an interrupted run before asserting anything.
  as_a -o /dev/null -X DELETE "$URL/rest/v1/todos?id=eq.$row"
  as_a -o /dev/null -X DELETE "$URL/rest/v1/shared_groups?id=eq.$sg_a"
  as_b -o /dev/null -X DELETE "$URL/rest/v1/shared_groups?id=eq.$sg_b"

  # A shares a group with B. B owns a second group that A is not in.
  #
  # The owner goes on the roster too, exactly as AppStore+Sharing.createShare
  # does it: rows enter a share by membership, so an owner who skipped their
  # own membership row could not file anything into their own group.
  as_a -o /dev/null -X POST "$URL/rest/v1/shared_groups" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$sg_a\",\"name\":\"e2e shared\",\"created_at\":\"2026-01-01T00:00:00Z\"}"
  as_a -o /dev/null -X POST "$URL/rest/v1/shared_group_members" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$mem_a\",\"share_id\":\"$sg_a\",\"phone\":\"$a_id\",\"created_at\":\"2026-01-01T00:00:00Z\"}"
  as_a -o /dev/null -X POST "$URL/rest/v1/shared_group_members" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$mem_b\",\"share_id\":\"$sg_a\",\"phone\":\"$b_id\",\"created_at\":\"2026-01-01T00:00:00Z\"}"
  as_b -o /dev/null -X POST "$URL/rest/v1/shared_groups" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$sg_b\",\"name\":\"e2e bystanders\",\"created_at\":\"2026-01-01T00:00:00Z\"}"
  as_b -o /dev/null -X POST "$URL/rest/v1/shared_group_members" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$mem_c\",\"share_id\":\"$sg_b\",\"phone\":\"$b_id\",\"created_at\":\"2026-01-01T00:00:00Z\"}"

  local created
  created="$(as_a -o /dev/null -w "%{http_code}" -X POST "$URL/rest/v1/todos" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$row\",\"text\":\"e2e shared line\",\"day\":\"2026-01-01\",\"created_at\":\"2026-01-01T00:00:00Z\",\"position\":0,\"share_id\":\"$sg_a\"}")"
  [[ "$created" == "201" ]] || FAIL "A could not create a todo in the group it shares (got $created)"

  # Sharing works at all: B sees A's row.
  local seen
  seen="$(as_b "$URL/rest/v1/todos?id=eq.$row&select=text" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  [[ "$seen" == "1" ]] || FAIL "a shared row is not visible to the member it was shared with"
  PASS "a shared row reaches the member"

  # B may tick it off — that is the point of sharing a list.
  as_b -o /dev/null -X PATCH "$URL/rest/v1/todos?id=eq.$row" -d '{"is_done":true}'
  local ticked
  ticked="$(as_a "$URL/rest/v1/todos?id=eq.$row&select=is_done" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["is_done"])')"
  [[ "$ticked" == "True" ]] || FAIL "a member could not tick off a shared todo"
  PASS "a member can tick off a shared todo"

  # The boundary: B must not be able to carry A's row into B's own group,
  # where people A never shared with would read it.
  as_b -o /dev/null -X PATCH "$URL/rest/v1/todos?id=eq.$row" -d "{\"share_id\":\"$sg_b\"}"
  local landed
  landed="$(as_a "$URL/rest/v1/todos?id=eq.$row&select=share_id" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["share_id"])')"
  [[ "$landed" == "$sg_a" ]] || FAIL "RLS breach: a member moved someone else's todo into another group ($landed)"
  PASS "a member cannot re-file someone else's shared todo"

  # ...nor sign it over to themselves, which would make the move legal next pass.
  as_b -o /dev/null -X PATCH "$URL/rest/v1/todos?id=eq.$row" -d "{\"user_id\":\"$b_id\"}"
  local owner
  owner="$(as_a "$URL/rest/v1/todos?id=eq.$row&select=user_id" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["user_id"])')"
  [[ "$owner" == "$a_id" ]] || FAIL "RLS breach: a member took ownership of someone else's todo ($owner)"
  PASS "a member cannot take ownership of someone else's todo"

  # An outsider holding a share id must not be able to write themselves in.
  # B is a member of sg_a, so B stands in for "somebody who knows the id" here
  # against sg_b's roster, which B owns — the reverse: A is in neither.
  local intruded
  intruded="$(as_a -o /dev/null -w "%{http_code}" -X POST "$URL/rest/v1/shared_group_members" -H "Prefer: return=minimal" \
    -d "{\"id\":\"$sg_b\",\"share_id\":\"$sg_b\",\"phone\":\"$a_id\",\"created_at\":\"2026-01-01T00:00:00Z\"}")"
  [[ "$intruded" != "201" ]] || FAIL "RLS breach: an outsider wrote themselves into a group they hold the id of"
  PASS "an outsider cannot join a group by id"

  # A's private rows stay private through all of the above.
  local leak
  leak="$(as_b "$URL/rest/v1/todos?share_id=is.null&user_id=eq.$a_id&select=id" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  [[ "$leak" == "0" ]] || FAIL "RLS breach: a member read $leak of another account's private rows"
  PASS "sharing one group exposes nothing else"

  as_a -o /dev/null -X DELETE "$URL/rest/v1/todos?id=eq.$row"
  as_a -o /dev/null -X DELETE "$URL/rest/v1/shared_groups?id=eq.$sg_a"
  as_b -o /dev/null -X DELETE "$URL/rest/v1/shared_groups?id=eq.$sg_b"
  PASS "cleanup"
}

if [[ "$MODE" == "backend" ]]; then
  backend_checks
  share_checks
  echo "== Backend contract: ALL PASS"
  exit 0
fi

echo "== macOS build"
swift build 2>&1 | grep -E "error" && FAIL "macOS build" || PASS "macOS build"

echo "== Unit suite"
swift test > /tmp/manas-unit-tests.log 2>&1 || { tail -30 /tmp/manas-unit-tests.log; FAIL "unit suite"; }
PASS "unit suite ($(grep -cE "' passed \(" /tmp/manas-unit-tests.log) cases)"

backend_checks
share_checks

echo "== Live client integration (real auth + two-device sync)"
MANAS_E2E=1 swift test --filter SyncEndToEndTests > /tmp/manas-e2e-tests.log 2>&1 \
  || { tail -30 /tmp/manas-e2e-tests.log; FAIL "live client integration"; }
PASS "live client integration ($(grep -cE "' passed \(" /tmp/manas-e2e-tests.log) cases)"

echo "== iOS app + widget build"
(cd ios && xcodegen generate > /dev/null 2>&1 \
  && xcodebuild -project Manas.xcodeproj -scheme Manas -configuration Debug \
       -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build \
       > /tmp/manas-ios-build.log 2>&1) \
  || { grep -E "error:" /tmp/manas-ios-build.log | head -10; FAIL "iOS build"; }
PASS "iOS app + widget build"

echo
echo "== E2E: ALL PASS"
