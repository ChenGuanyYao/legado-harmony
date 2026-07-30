import { config } from './config.js';

interface HuaweiTokenResponse {
  access_token?: string;
  id_token?: string;
  expires_in?: number;
  error?: number;
  sub_error?: number;
  error_description?: string;
}

export interface HuaweiUserInfo {
  openID?: string;
  unionID?: string;
  displayName?: string;
  headPictureURL?: string;
  error?: string;
}

export async function exchangeHuaweiAuthorizationCode(code: string): Promise<HuaweiUserInfo> {
  const tokenParams = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    client_id: config.huaweiClientId,
    client_secret: config.huaweiClientSecret
  });
  if (config.huaweiRedirectUri) {
    tokenParams.set('redirect_uri', config.huaweiRedirectUri);
  }

  const tokenResponse = await fetch('https://oauth-login.cloud.huawei.com/oauth2/v3/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: tokenParams,
    signal: AbortSignal.timeout(config.http.upstreamTimeoutMs)
  });
  const token = await tokenResponse.json() as HuaweiTokenResponse;
  if (!tokenResponse.ok || !token.access_token) {
    throw new Error(token.error_description || 'Huawei authorization code exchange failed');
  }

  const userResponse = await fetch(
    'https://account.cloud.huawei.com/rest.php?nsp_svc=GOpen.User.getInfo',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        access_token: token.access_token,
        getNickName: '1'
      }),
      signal: AbortSignal.timeout(config.http.upstreamTimeoutMs)
    }
  );
  const user = await userResponse.json() as HuaweiUserInfo;
  const nspStatus = userResponse.headers.get('NSP_STATUS');
  if (!userResponse.ok || (nspStatus && nspStatus !== '0') || !user.openID) {
    throw new Error(user.error || 'Huawei user identity lookup failed');
  }
  return user;
}
