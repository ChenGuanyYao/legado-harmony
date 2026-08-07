import assert from 'node:assert/strict';
import test from 'node:test';
import { jwtVerify } from 'jose';
import {
  SESSION_AUDIENCE,
  SESSION_ISSUER,
  sessionExpiresAt,
  signSessionToken
} from './sessionTokens.js';

test('session expiration uses the configured sliding lifetime', () => {
  const now = Date.UTC(2026, 7, 7, 0, 0, 0);
  assert.equal(
    sessionExpiresAt(7, now).getTime(),
    now + 7 * 24 * 60 * 60 * 1000
  );
});

test('renewed session token keeps the user and session identities', async () => {
  const key = new TextEncoder().encode('test-session-secret-that-is-long-enough');
  const expiresAt = sessionExpiresAt(7);
  const token = await signSessionToken(key, 'user-1', 'session-1', expiresAt);
  const verified = await jwtVerify(token, key, {
    issuer: SESSION_ISSUER,
    audience: SESSION_AUDIENCE,
    algorithms: ['HS256']
  });

  assert.equal(verified.payload.sub, 'user-1');
  assert.equal(verified.payload.jti, 'session-1');
  assert.equal(verified.payload.exp, Math.floor(expiresAt.getTime() / 1000));
});
