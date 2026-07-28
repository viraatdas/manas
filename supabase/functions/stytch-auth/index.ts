// Stytch phone-OTP bridge. Stytch delivers the real SMS and verifies the code
// (a pure API — no web view, so sign-in can never redirect). On success we
// exchange that proof for a genuine Supabase session using a server-only
// internal code, so the app's existing PostgREST + RLS sync layer works
// unchanged. The Stytch secret lives only here, never in the app binary.
//
// Deploy: supabase functions deploy stytch-auth --no-verify-jwt
// Secrets: STYTCH_PROJECT_ID, STYTCH_SECRET, INTERNAL_OTP

const STYTCH_PROJECT_ID = Deno.env.get("STYTCH_PROJECT_ID")!;
const STYTCH_SECRET = Deno.env.get("STYTCH_SECRET")!;
const INTERNAL_OTP = Deno.env.get("INTERNAL_OTP")!;
// Defaults to production; set to https://test.stytch.com for the test env.
const STYTCH_BASE = Deno.env.get("STYTCH_BASE_URL") ?? "https://api.stytch.com";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const STYTCH_AUTH = "Basic " + btoa(`${STYTCH_PROJECT_ID}:${STYTCH_SECRET}`);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let payload: { action?: string; phone?: string; method_id?: string; code?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  const { action, phone, method_id, code } = payload;

  // Account deletion is authenticated independently because this function is
  // also the public entry point for requesting an OTP. Identity comes only
  // from the verified Supabase bearer token, never from request JSON.
  if (action === "delete") {
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return json({ error: "Sign in again before deleting your account." }, 401);
    }

    const userResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: ANON, Authorization: authorization },
    });
    const user = await userResponse.json();
    if (!userResponse.ok || !user.id || !user.phone) {
      return json({ error: "Your session expired. Sign in again and retry." }, 401);
    }

    const e164Phone = user.phone.startsWith("+") ? user.phone : `+${user.phone}`;
    const phoneID = e164Phone.replace(/[^0-9]/g, "");

    // Resolve the matching Stytch record before deleting anything. Dev/test
    // accounts may exist only in Supabase, in which case this is an empty list.
    const searchResponse = await fetch(`${STYTCH_BASE}/v1/users/search`, {
      method: "POST",
      headers: { Authorization: STYTCH_AUTH, "Content-Type": "application/json" },
      body: JSON.stringify({
        limit: 10,
        query: {
          operator: "AND",
          operands: [{ filter_name: "phone_number", filter_value: [e164Phone] }],
        },
      }),
    });
    const search = await searchResponse.json();
    if (!searchResponse.ok) {
      return json({ error: "Account deletion couldn’t reach the identity service." }, 502);
    }

    const todosResponse = await fetch(
      `${SUPABASE_URL}/rest/v1/todos?user_id=eq.${encodeURIComponent(phoneID)}`,
      {
        method: "DELETE",
        headers: {
          apikey: ANON,
          Authorization: authorization,
          Prefer: "return=minimal",
        },
      },
    );
    if (!todosResponse.ok) {
      return json({ error: "Your synced todos couldn’t be deleted." }, 502);
    }

    for (const result of search.results ?? []) {
      const stytchDelete = await fetch(`${STYTCH_BASE}/v1/users/${result.user_id}`, {
        method: "DELETE",
        headers: { Authorization: STYTCH_AUTH },
      });
      if (!stytchDelete.ok) {
        return json({ error: "Your identity record couldn’t be deleted." }, 502);
      }
    }

    const supabaseDelete = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${user.id}`, {
      method: "DELETE",
      headers: {
        apikey: SERVICE_ROLE,
        Authorization: `Bearer ${SERVICE_ROLE}`,
      },
    });
    if (!supabaseDelete.ok) {
      return json({ error: "Your account couldn’t be deleted." }, 502);
    }

    return json({ deleted: true });
  }

  // Beta allowlist: while Stytch live SMS is pending billing, one allowlisted
  // phone can sign in with a private fixed code (set as function secrets, never
  // in the app). Remove DEV_PHONE/DEV_CODE once Stytch billing is enabled and
  // this becomes real SMS for everyone.
  const DEV_PHONE = Deno.env.get("DEV_PHONE");
  const DEV_CODE = Deno.env.get("DEV_CODE");
  const isDev = DEV_PHONE && DEV_CODE && phone === DEV_PHONE;

  // Step 1 — send the OTP via Stytch (real SMS).
  if (action === "send") {
    if (!phone) return json({ error: "Missing phone number." }, 400);
    if (isDev) return json({ method_id: "dev" });
    // login_or_create signs new numbers up as well as returning users.
    const r = await fetch(`${STYTCH_BASE}/v1/otps/sms/login_or_create`, {
      method: "POST",
      headers: { Authorization: STYTCH_AUTH, "Content-Type": "application/json" },
      body: JSON.stringify({ phone_number: phone, expiration_minutes: 10 }),
    });
    const d = await r.json();
    if (!r.ok) return json({ error: d.error_message || "Couldn't send the code." }, 400);
    // phone_id is the method_id the authenticate call needs.
    return json({ method_id: d.phone_id });
  }

  // Step 2 — verify the code with Stytch, then mint a Supabase session.
  if (action === "verify") {
    if (!method_id || !code || !phone) return json({ error: "Missing code." }, 400);
    if (isDev && code === DEV_CODE) {
      const v = await fetch(`${SUPABASE_URL}/auth/v1/verify`, {
        method: "POST",
        headers: { apikey: ANON, "Content-Type": "application/json" },
        body: JSON.stringify({ phone, token: INTERNAL_OTP, type: "sms" }),
      });
      const session = await v.json();
      if (!v.ok || !session.access_token) return json({ error: "exchange failed" }, 500);
      return json({ session });
    }
    const a = await fetch(`${STYTCH_BASE}/v1/otps/authenticate`, {
      method: "POST",
      headers: { Authorization: STYTCH_AUTH, "Content-Type": "application/json" },
      body: JSON.stringify({ method_id, code, session_duration_minutes: 5 }),
    });
    const ad = await a.json();
    if (!a.ok) return json({ error: ad.error_message || "That code didn't match." }, 401);

    // Exchange the verified phone for a real Supabase session via the phone's
    // internal test OTP (server-side only), so RLS/sync work unchanged.
    const v = await fetch(`${SUPABASE_URL}/auth/v1/verify`, {
      method: "POST",
      headers: { apikey: ANON, "Content-Type": "application/json" },
      body: JSON.stringify({ phone, token: INTERNAL_OTP, type: "sms" }),
    });
    const session = await v.json();
    if (!v.ok || !session.access_token) {
      return json({ error: "Signed in, but the session couldn't be created." }, 500);
    }
    return json({ session });
  }

  return json({ error: "Unknown action." }, 400);
});
