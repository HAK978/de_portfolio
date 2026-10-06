// Persistence helpers for the Steam refresh token.
//
// The refresh token is the most sensitive secret in the project: whoever
// holds it can log in to the owner's Steam account as a client. It lives
// in a single owner-only file next to the service.

const fs = require('fs');

// Ask Steam for a new token once the current one is this close to expiry.
const RENEW_WITHIN_MS = 30 * 24 * 60 * 60 * 1000;

/** Returns the saved token, or null if the file is missing or empty. */
function readToken(file) {
  try {
    return fs.readFileSync(file, 'utf8').trim() || null;
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

/**
 * Saves [token] with owner-only permissions. Writes to a temp file and
 * renames it over the old one, so a crash mid-write can never leave a
 * truncated token behind (which would cost a manual Steam Guard login).
 */
function writeToken(file, token) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, token, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

/**
 * Expiry of a Steam refresh token (a JWT) in epoch milliseconds, or null
 * if it can't be decoded. The signature isn't checked; this is only used
 * to decide when to ask Steam for a renewal.
 */
function tokenExpiryMs(token) {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    return Number.isFinite(payload.exp) ? payload.exp * 1000 : null;
  } catch {
    return null;
  }
}

/**
 * True once [token] is within the renewal window. An undecodable token
 * returns false: forcing a re-logon every day wouldn't help, and every
 * logOn already asks Steam for a renewal (renewRefreshTokens).
 */
function shouldRenew(token, nowMs = Date.now()) {
  const expiry = tokenExpiryMs(token);
  return expiry !== null && expiry - nowMs <= RENEW_WITHIN_MS;
}

module.exports = { readToken, writeToken, tokenExpiryMs, shouldRenew, RENEW_WITHIN_MS };
