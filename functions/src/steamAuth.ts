import {createHash, randomBytes} from "node:crypto";

export const STEAM_ENDPOINT = "https://steamcommunity.com/openid/login";
const NS = "http://specs.openid.net/auth/2.0";
export const LOGIN_TTL_MS = 10 * 60 * 1000;

export function newSteamLogin(callback: string) {
  const sessionId = randomBytes(32).toString("hex");
  const returnTo = new URL(callback);
  returnTo.searchParams.set("state", sessionId);
  const loginUrl = new URL(STEAM_ENDPOINT);
  loginUrl.search = new URLSearchParams({
    "openid.ns": NS,
    "openid.mode": "checkid_setup",
    "openid.return_to": returnTo.toString(),
    "openid.realm": returnTo.origin + "/",
    "openid.identity": NS + "/identifier_select",
    "openid.claimed_id": NS + "/identifier_select",
  }).toString();
  return {sessionId, returnTo: returnTo.toString(), loginUrl: loginUrl.toString()};
}

export function sessionKey(sessionId: unknown): string {
  if (typeof sessionId !== "string" || !/^[a-f0-9]{64}$/.test(sessionId)) {
    throw new Error("Invalid login session");
  }
  return createHash("sha256").update(sessionId).digest("hex");
}

/** Steam is the only supported identity provider. Never fetch a client URL. */
export async function verifySteamAssertion(
  assertion: unknown,
  returnTo: string,
  nowMs = Date.now(),
  fetcher: typeof fetch = fetch,
): Promise<string> {
  if (!assertion || typeof assertion !== "object" || Array.isArray(assertion)) {
    throw new Error("Missing Steam assertion");
  }
  const fields: Record<string, string> = {};
  const entries = Object.entries(assertion);
  if (entries.length > 30) throw new Error("Invalid assertion");
  for (const [key, value] of entries) {
    if (!key.startsWith("openid.") || typeof value !== "string" || value.length > 4096) {
      throw new Error("Invalid assertion field");
    }
    fields[key] = value;
  }
  const identity = fields["openid.claimed_id"] ?? "";
  const steamId = /^https:\/\/steamcommunity\.com\/openid\/id\/(\d{17})$/.exec(identity)?.[1];
  const signed = new Set((fields["openid.signed"] ?? "").split(","));
  const required = ["op_endpoint", "claimed_id", "identity", "return_to", "response_nonce", "assoc_handle"];
  const nonce = fields["openid.response_nonce"] ?? "";
  const nonceTime = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/.test(nonce) ?
    Date.parse(nonce.slice(0, 20)) : NaN;
  if (!steamId || fields["openid.identity"] !== identity ||
      fields["openid.ns"] !== NS || fields["openid.mode"] !== "id_res" ||
      fields["openid.op_endpoint"] !== STEAM_ENDPOINT ||
      fields["openid.return_to"] !== returnTo || !fields["openid.sig"] ||
      !fields["openid.assoc_handle"] || !required.every((key) => signed.has(key)) ||
      nonce.length > 255 || !Number.isFinite(nonceTime) ||
      nowMs - nonceTime > LOGIN_TTL_MS || nonceTime - nowMs > 60_000) {
    throw new Error("Invalid or expired Steam assertion");
  }
  const response = await fetcher(STEAM_ENDPOINT, {
    method: "POST",
    headers: {"Content-Type": "application/x-www-form-urlencoded"},
    body: new URLSearchParams({...fields, "openid.mode": "check_authentication"}),
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
  });
  const body = await response.text();
  if (!response.ok || !body.split(/\r?\n/).includes("is_valid:true")) {
    throw new Error("Steam rejected the login");
  }
  return steamId;
}
