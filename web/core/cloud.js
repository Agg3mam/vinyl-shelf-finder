// Kontoen i skyen (Supabase): login og hentning af poster. Port af Sources/VinylCore/Cloud.swift.
// Kun den offentlige nøgle (publishable) står her. Rækkesikkerheden i supabase/schema.sql
// giver kun adgang til egne poster efter login. Webappen læser alt og skriver kun "Spillet".

export const CLOUD_URL = "https://vbtxbnwcsipapnfiphlw.supabase.co";
export const PUBLISHABLE_KEY = "sb_publishable_q7aX_h3J1W6uyvzQsYEk4Q_85bkkwQm";
export const DEVICE = "web";

export class CloudError extends Error {
  constructor(message, needsLogin = false, needsSecondFactor = false) {
    super(message); this.needsLogin = needsLogin; this.needsSecondFactor = needsSecondFactor;
  }
}

export const WRONG_SECOND_FACTOR = "Koden passer ikke. Skriv de 6 tal, kode-appen viser lige nu, ud for Vinyl Shelf.";
export const SECOND_FACTOR_REQUIRED = "Skriv koden fra din kode-app for at synkronisere.";

export const WRONG_PASSWORD = "Forkert e-mail eller adgangskode. Har du valgt en adgangskode under Konto i appen på computeren?";
const EXPIRED_CODE = "Koden er forkert eller udløbet. Bed om en ny kode.";
const USED_LINK = "Linket er allerede brugt eller er ikke fra den nyeste mail. Hvert link virker kun én gang – også hvis du har klikket på det. Bed om en ny mail, og klik ikke på linket.";

const DATABASE_DENIED = "Kontoen afviste synkroniseringen (ingen adgang til databasen). Kør den nyeste supabase/mfa.sql i Supabase › SQL Editor.";

function errorFor(status, body) {
  const code = body?.error_code ?? body?.code ?? body?.error ?? "";
  switch (code) {
    case "otp_expired": return new CloudError(EXPIRED_CODE);
    case "invalid_credentials": return new CloudError(WRONG_PASSWORD);
    case "weak_password": return new CloudError("Adgangskoden er for kort. Brug mindst 8 tegn.");
    case "over_email_send_rate_limit": case "over_request_rate_limit":
      return new CloudError("Der er sendt for mange koder for nylig. Vent lidt, og prøv igen.");
    case "email_address_invalid": case "validation_failed": return new CloudError("E-mailadressen ser forkert ud.");
    case "mfa_verification_failed": case "mfa_challenge_expired": return new CloudError(WRONG_SECOND_FACTOR);
    case "insufficient_aal": return new CloudError(SECOND_FACTOR_REQUIRED, false, true);
    // "permission denied" er en regel i databasen, der ikke må det, den prøver (fx den første supabase/mfa.sql, der
    // læste auth.mfa_factors direkte). Kun en afvist række er den manglende kode.
    case "42501":
      if (String(body?.message ?? "").includes("permission denied")) return new CloudError(DATABASE_DENIED);
      return new CloudError(SECOND_FACTOR_REQUIRED, false, true);
    case "invalid_grant": case "refresh_token_not_found": case "refresh_token_already_used": case "session_not_found": case "bad_jwt":
      return new CloudError("Du skal logge ind igen.", true);
  }
  if (status === 401) return new CloudError("Du skal logge ind igen.", true);
  if (status === 429) return new CloudError("Der er sendt for mange forespørgsler. Vent lidt, og prøv igen.");
  return new CloudError(`Kontoen svarede med en fejl (${status}). Prøv igen senere.`);
}

async function send(method, path, body, token, headers = {}) {
  let res;
  try {
    res = await fetch(`${CLOUD_URL}/${path}`, {
      method,
      headers: {
        apikey: PUBLISHABLE_KEY,
        Authorization: `Bearer ${token ?? PUBLISHABLE_KEY}`,
        "Content-Type": "application/json",
        ...headers,
      },
      body: body == null ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout ? AbortSignal.timeout(30000) : undefined,
    });
  } catch {
    throw new CloudError("Kontoen kunne ikke nås. Tjek internetforbindelsen, og prøv igen.");
  }
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* tomt eller ikke JSON */ }
  if (!res.ok) throw errorFor(res.status, json);
  return json;
}

export function jwtClaims(jwt) {
  const part = (jwt ?? "").split(".")[1];
  if (!part) return null;
  try {
    let b = part.replace(/-/g, "+").replace(/_/g, "/");
    while (b.length % 4) b += "=";
    const bin = atob(b);
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0))));
  } catch { return null; }
}

function sessionFrom(o, email) {
  const id = o?.user?.id;
  if (!o?.access_token || !o?.refresh_token || !id) throw new CloudError("Svaret fra kontoen kunne ikke læses.");
  const expiresAt = o.expires_at ?? Date.now() / 1000 + (o.expires_in ?? 3600);
  return { accessToken: o.access_token, refreshToken: o.refresh_token, expiresAt, userID: id, email: o.user.email ?? email };
}

export const isExpired = (s) => Date.now() / 1000 > s.expiresAt - 60;

// MARK: Login

export async function signIn(email, password) {
  return sessionFrom(await send("POST", "auth/v1/token?grant_type=password", { email, password }), email);
}

export async function refresh(s) {
  return sessionFrom(await send("POST", "auth/v1/token?grant_type=refresh_token", { refresh_token: s.refreshToken }), s.email);
}

/** Sender en login-mail. Linket fører tilbage til webappen (adressen skal stå under Redirect URLs i Supabase). */
export async function requestMail(email, redirect) {
  await send("POST", `auth/v1/otp?redirect_to=${encodeURIComponent(redirect)}`, { email, create_user: true });
}

/** Koden fra mailen (hvis skabelonen viser den). */
export async function verifyCode(email, code) {
  return sessionFrom(await send("POST", "auth/v1/verify", { type: "email", email, token: code }), email);
}

/** Linket fra mailen, kopieret og indsat (https://….supabase.co/auth/v1/verify?token=…&type=…). null, hvis det ikke er sådan et link. */
export async function verifyEmailLink(text) {
  let u;
  try { u = new URL(text.trim()); } catch { return null; }
  const token = u.searchParams.get("token");
  if (!u.pathname.endsWith("/auth/v1/verify") || !token) return null;
  const type = u.searchParams.get("type") ?? "magiclink";
  try {
    return sessionFrom(await send("POST", "auth/v1/verify", { type, token_hash: token }), "");
  } catch (e) {
    if (e.message === EXPIRED_CODE) throw new CloudError(USED_LINK);
    throw e;
  }
}

/** Login fra adressen, linket i mailen sendte browseren til (…#access_token=…&refresh_token=…). */
export function sessionFromHash(hash) {
  const raw = (hash ?? "").replace(/^#/, "");
  if (!raw.includes("access_token=") && !raw.includes("error=")) return null;
  // Som CloudClient.session(fromLink:) i Swift.
  const p = new Map();
  for (const pair of raw.split("&")) {
    const i = pair.indexOf("=");
    if (i < 0) continue;
    const dec = (x) => { try { return decodeURIComponent(x); } catch { return x; } };
    p.set(dec(pair.slice(0, i)), dec(pair.slice(i + 1)));
  }
  const desc = p.get("error_description") ?? p.get("error");
  if (desc) {
    throw new CloudError(desc.includes("expired") || desc.includes("invalid")
      ? "Linket er brugt eller udløbet. Bed om en ny mail." : `Login mislykkedes: ${desc.replaceAll("+", " ")}`);
  }
  const access = p.get("access_token"), refreshToken = p.get("refresh_token");
  const claims = jwtClaims(access);
  if (!access || !refreshToken || !claims?.sub) throw new CloudError("Linket kunne ikke læses. Bed om en ny mail.");
  const expiresAt = Number(p.get("expires_at")) || claims.exp || Date.now() / 1000 + (Number(p.get("expires_in")) || 3600);
  return { accessToken: access, refreshToken, expiresAt, userID: claims.sub, email: claims.email ?? "" };
}

// MARK: Totrinslogin (TOTP), som CloudClient i Cloud.swift

/** "aal1" (adgangskode eller mail) eller "aal2" (også koden fra kode-appen). */
export const assurance = (s) => jwtClaims(s?.accessToken)?.aal ?? "aal1";

/** Kontoens kode-apps: [{ id, verified }]. */
export async function factors(s) {
  const u = await send("GET", "auth/v1/user", null, s.accessToken);
  return (u?.factors ?? []).filter((f) => f.factor_type === "totp" && f.id).map((f) => ({ id: f.id, verified: f.status === "verified" }));
}

/** Kontoen har totrinslogin, men loginnet mangler koden: den kode-app, koden skal komme fra. Ellers null. */
export async function pendingSecondFactor(s) {
  if (assurance(s) === "aal2") return null;
  return (await factors(s)).find((f) => f.verified) ?? null;
}

/** Begynder at slå totrinslogin til: { factorID, secret, uri, qr }. Halvfærdige forsøg fjernes først. */
export async function enrollSecondFactor(s) {
  for (const f of await factors(s)) if (!f.verified) await send("DELETE", `auth/v1/factors/${f.id}`, null, s.accessToken);
  const o = await send("POST", "auth/v1/factors",
    { factor_type: "totp", friendly_name: `Vinyl Shelf ${Math.floor(Date.now() / 1000)}`, issuer: "Vinyl Shelf" }, s.accessToken);
  if (!o?.id || !o?.totp?.secret || !o?.totp?.uri) throw new CloudError("Svaret fra kontoen kunne ikke læses.");
  return { factorID: o.id, secret: o.totp.secret, uri: o.totp.uri, qr: o.totp.qr_code ?? null };
}

/** Bekræfter en kode fra kode-appen og giver et nyt, sikrere login ("aal2"). */
export async function verifySecondFactor(factorID, code, s) {
  const digits = String(code).replace(/\D/g, "");
  if (digits.length !== 6) throw new CloudError(WRONG_SECOND_FACTOR);
  const ch = await send("POST", `auth/v1/factors/${factorID}/challenge`, {}, s.accessToken);
  if (!ch?.id) throw new CloudError("Svaret fra kontoen kunne ikke læses.");
  return sessionFrom(await send("POST", `auth/v1/factors/${factorID}/verify`, { challenge_id: ch.id, code: digits }, s.accessToken), s.email);
}

/** Slår totrinslogin fra (kræver et login, hvor koden er skrevet). */
export async function removeSecondFactor(factorID, s) {
  await send("DELETE", `auth/v1/factors/${factorID}`, null, s.accessToken);
}

/** Hemmeligheden i grupper á 4, så den er nem at skrive af. */
export const groupedSecret = (x) => (x.match(/.{1,4}/g) ?? []).join(" ");

// MARK: Poster

/** Serverens tidsstempel minus 5 sekunder, så en ændring gemt samtidig med sidste hentning ikke tabes. */
function overlap(since) {
  const d = new Date(since.replace(/(\.\d{3})\d+/, "$1"));
  return Number.isNaN(d.getTime()) ? null : new Date(d.getTime() - 5000).toISOString();
}

/** Poster ændret siden `since` (serverens tid), og den nye markør. Henter i sider á 1000. */
export async function fetchRecords(since, s) {
  const rows = [];
  let cursor = since;
  let offset = 0;
  const from = since ? overlap(since) : null;
  for (;;) {
    let path = `rest/v1/sync_records?select=kind,key,data,deleted,updated_at&order=updated_at.asc,kind.asc,key.asc&limit=1000&offset=${offset}`;
    if (from) path += `&updated_at=gte.${encodeURIComponent(from)}`;
    const page = await send("GET", path, null, s.accessToken);
    if (!Array.isArray(page)) throw new CloudError("Svaret fra kontoen kunne ikke læses.");
    for (const r of page) {
      if (typeof r.kind !== "string" || typeof r.key !== "string") continue;
      rows.push(r);
      if (r.updated_at) cursor = r.updated_at;
    }
    if (page.length < 1000) break;
    offset += page.length;
  }
  return { rows, cursor };
}

/** Sender poster (her kun afspilninger). */
export async function upsert(docs, s) {
  const rows = docs.map((d) => ({ user_id: s.userID, kind: d.kind, key: d.key, deleted: d.data == null, device: DEVICE, data: d.data ?? null }));
  if (!rows.length) return;
  await send("POST", "rest/v1/sync_records?on_conflict=user_id,kind,key", rows, s.accessToken,
    { Prefer: "resolution=merge-duplicates,return=minimal" });
}

// MARK: Statistik (kun administratorer, se supabase/admin-stats.sql)

/** Kalder en funktion i databasen. Findes funktionen ikke (SQL'en er ikke kørt), giver det en fejl. */
export async function rpc(name, s, args = {}) {
  return send("POST", `rest/v1/rpc/${name}`, args, s.accessToken);
}
