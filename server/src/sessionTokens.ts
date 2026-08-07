import { SignJWT } from 'jose';

export const SESSION_ISSUER = 'legado-account-commerce';
export const SESSION_AUDIENCE = 'legado-harmony';

export function sessionExpiresAt(ttlDays: number, now: number = Date.now()): Date {
  return new Date(now + ttlDays * 24 * 60 * 60 * 1000);
}

export async function signSessionToken(
  sessionKey: Uint8Array,
  userId: string,
  sessionId: string,
  expiresAt: Date
): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer(SESSION_ISSUER)
    .setAudience(SESSION_AUDIENCE)
    .setSubject(userId)
    .setJti(sessionId)
    .setIssuedAt()
    .setExpirationTime(expiresAt)
    .sign(sessionKey);
}
