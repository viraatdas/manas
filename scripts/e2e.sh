#!/usr/bin/env bash
# The whole system, verified in one command:
#
#   scripts/e2e.sh              # everything below
#   scripts/e2e.sh backend      # just the live-backend checks (fast, curl-only)
#
# 1. macOS build + full unit suite
# 2. Live backend contract: phone sign-in ENABLED (the guard that catches the
#    "config push silently disabled phone login" class of bug), OTP request,
#    verify -> JWT, authed CRUD, RLS blocking anonymous reads
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

if [[ "$MODE" == "backend" ]]; then
  backend_checks
  echo "== Backend contract: ALL PASS"
  exit 0
fi

echo "== macOS build"
swift build 2>&1 | grep -E "error" && FAIL "macOS build" || PASS "macOS build"

echo "== Unit suite"
swift test > /tmp/manas-unit-tests.log 2>&1 || { tail -30 /tmp/manas-unit-tests.log; FAIL "unit suite"; }
PASS "unit suite ($(grep -cE "' passed \(" /tmp/manas-unit-tests.log) cases)"

backend_checks

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
