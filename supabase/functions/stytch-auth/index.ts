// Stytch phone-OTP bridge. Stytch delivers the real SMS and verifies the code
// (a pure API — no web view, so sign-in can never redirect). On success we
// exchange that proof for a genuine Supabase session using a server-derived
// password, so the app's existing PostgREST + RLS sync layer works unchanged.
// This creates the sync account when mobile is the first device and reuses the
// same phone-keyed account when desktop was first. Secrets stay server-side.
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
const encoder = new TextEncoder();

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function normalizedPhone(phone: string): string {
  const digits = phone.replace(/[^0-9]/g, "");
  return `+${digits}`;
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index++) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function passwordForPhone(phone: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(INTERNAL_OTP),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(`manas:${normalizedPhone(phone)}`),
    ),
  );
  const encoded = btoa(String.fromCharCode(...signature))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
  return `Mn!${encoded}`;
}

function adminHeaders(): Record<string, string> {
  return {
    apikey: SERVICE_ROLE,
    Authorization: `Bearer ${SERVICE_ROLE}`,
    "Content-Type": "application/json",
  };
}

async function findSupabaseUser(phone: string): Promise<{ id: string } | null> {
  const wanted = normalizedPhone(phone);
  for (let page = 1; page <= 10; page++) {
    const response = await fetch(
      `${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=1000`,
      { headers: adminHeaders() },
    );
    const body = await response.json();
    if (!response.ok) throw new Error("Supabase user lookup failed.");
    const users = body.users ?? [];
    const user = users.find(
      (candidate: { phone?: string }) =>
        candidate.phone && normalizedPhone(candidate.phone) === wanted,
    );
    if (user?.id) return user;
    if (users.length < 1000) return null;
  }
  throw new Error("Supabase user lookup exceeded its safe page limit.");
}

async function passwordSession(
  phone: string,
  password: string,
): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ phone: normalizedPhone(phone), password }),
  });
}

async function supabaseSessionFor(
  phone: string,
): Promise<Record<string, unknown>> {
  const resolvedPhone = normalizedPhone(phone);
  const password = await passwordForPhone(resolvedPhone);

  // The common path does not need the service role after the account exists.
  let signIn = await passwordSession(resolvedPhone, password);
  let session = await signIn.json();
  if (signIn.ok && session.access_token) return session;

  const existing = await findSupabaseUser(resolvedPhone);
  const path = existing
    ? `${SUPABASE_URL}/auth/v1/admin/users/${existing.id}`
    : `${SUPABASE_URL}/auth/v1/admin/users`;
  const provision = await fetch(path, {
    method: existing ? "PUT" : "POST",
    headers: adminHeaders(),
    body: JSON.stringify({
      phone: resolvedPhone,
      password,
      phone_confirm: true,
    }),
  });

  // A concurrent first sign-in can win the create race. Resolve that user and
  // set the same deterministic password before retrying the session exchange.
  if (!provision.ok && !existing) {
    const raced = await findSupabaseUser(resolvedPhone);
    if (!raced) throw new Error("Supabase account provisioning failed.");
    const update = await fetch(
      `${SUPABASE_URL}/auth/v1/admin/users/${raced.id}`,
      {
        method: "PUT",
        headers: adminHeaders(),
        body: JSON.stringify({
          phone: resolvedPhone,
          password,
          phone_confirm: true,
        }),
      },
    );
    if (!update.ok) throw new Error("Supabase account provisioning failed.");
  } else if (!provision.ok) {
    throw new Error("Supabase account provisioning failed.");
  }

  signIn = await passwordSession(resolvedPhone, password);
  session = await signIn.json();
  if (!signIn.ok || !session.access_token) {
    throw new Error("Supabase session exchange failed.");
  }
  return session;
}

function verifiedStytchPhone(
  authentication: Record<string, unknown>,
  methodID: string,
): string | null {
  const user = authentication.user as
    | { phone_numbers?: Array<{ phone_id?: string; phone_number?: string }> }
    | undefined;
  const method = user?.phone_numbers?.find((candidate) =>
    candidate.phone_id === methodID
  );
  return method?.phone_number ? normalizedPhone(method.phone_number) : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let payload: {
    action?: string;
    phone?: string;
    method_id?: string;
    code?: string;
  };
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
      return json(
        { error: "Sign in again before deleting your account." },
        401,
      );
    }

    const userResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: ANON, Authorization: authorization },
    });
    const user = await userResponse.json();
    if (!userResponse.ok || !user.id || !user.phone) {
      return json(
        { error: "Your session expired. Sign in again and retry." },
        401,
      );
    }

    const e164Phone = user.phone.startsWith("+")
      ? user.phone
      : `+${user.phone}`;
    const phoneID = e164Phone.replace(/[^0-9]/g, "");

    // Resolve the matching Stytch record before deleting anything. Dev/test
    // accounts may exist only in Supabase, in which case this is an empty list.
    const searchResponse = await fetch(`${STYTCH_BASE}/v1/users/search`, {
      method: "POST",
      headers: {
        Authorization: STYTCH_AUTH,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        limit: 10,
        query: {
          operator: "AND",
          operands: [{
            filter_name: "phone_number",
            filter_value: [e164Phone],
          }],
        },
      }),
    });
    const search = await searchResponse.json();
    if (!searchResponse.ok) {
      return json({
        error: "Account deletion couldn’t reach the identity service.",
      }, 502);
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
      const stytchDelete = await fetch(
        `${STYTCH_BASE}/v1/users/${result.user_id}`,
        {
          method: "DELETE",
          headers: { Authorization: STYTCH_AUTH },
        },
      );
      if (!stytchDelete.ok) {
        return json(
          { error: "Your identity record couldn’t be deleted." },
          502,
        );
      }
    }

    const supabaseDelete = await fetch(
      `${SUPABASE_URL}/auth/v1/admin/users/${user.id}`,
      {
        method: "DELETE",
        headers: {
          apikey: SERVICE_ROLE,
          Authorization: `Bearer ${SERVICE_ROLE}`,
        },
      },
    );
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
      headers: {
        Authorization: STYTCH_AUTH,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ phone_number: phone, expiration_minutes: 10 }),
    });
    const d = await r.json();
    if (!r.ok) {
      return json({ error: d.error_message || "Couldn't send the code." }, 400);
    }
    // phone_id is the method_id the authenticate call needs.
    return json({ method_id: d.phone_id });
  }

  // Step 2 — verify the code with Stytch, then mint a Supabase session.
  if (action === "verify") {
    if (!method_id || !code || !phone) {
      return json({ error: "Missing code." }, 400);
    }
    if (isDev && code === DEV_CODE) {
      try {
        return json({ session: await supabaseSessionFor(phone) });
      } catch {
        return json({
          error: "Signed in, but the session couldn't be created.",
        }, 500);
      }
    }
    const a = await fetch(`${STYTCH_BASE}/v1/otps/authenticate`, {
      method: "POST",
      headers: {
        Authorization: STYTCH_AUTH,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ method_id, code, session_duration_minutes: 5 }),
    });
    const ad = await a.json();
    if (!a.ok) {
      return json(
        { error: ad.error_message || "That code didn't match." },
        401,
      );
    }

    // Trust the phone Stytch authenticated, not the phone echoed by the
    // client. This prevents a valid code for one number from minting a session
    // for a different number.
    const verifiedPhone = verifiedStytchPhone(ad, method_id);
    if (
      !verifiedPhone ||
      !constantTimeEqual(verifiedPhone, normalizedPhone(phone))
    ) {
      return json(
        { error: "The verified number did not match this sign-in." },
        401,
      );
    }

    try {
      return json({ session: await supabaseSessionFor(verifiedPhone) });
    } catch {
      return json(
        { error: "Signed in, but the session couldn't be created." },
        500,
      );
    }
  }

  return json({ error: "Unknown action." }, 400);
});
