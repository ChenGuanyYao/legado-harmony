import http from '@ohos.net.http';
import { AccountCommerceConfig } from './AccountCommerceConfig';
import {
  AccountApiError,
  AccountSnapshot,
  HuaweiLoginResponse,
  IapCreditResponse
} from './AccountCommerceModels';

class ApiErrorBody {
  code: string = '';
  message: string = '';
}

export class AccountCommerceApi {
  static async login(authorizationCode: string): Promise<HuaweiLoginResponse> {
    const value = await AccountCommerceApi.request('/v1/auth/huawei', 'POST',
      JSON.stringify({ authorizationCode: authorizationCode }), '');
    const response = JSON.parse(value) as HuaweiLoginResponse;
    response.account = AccountCommerceApi.normalizeAccount(response.account);
    return response;
  }

  static async fetchAccount(sessionToken: string): Promise<AccountSnapshot> {
    const value = await AccountCommerceApi.request('/v1/me', 'GET', '', sessionToken);
    return AccountCommerceApi.normalizeAccount(JSON.parse(value) as AccountSnapshot);
  }

  static async updateProfile(displayName: string, avatarBase64: string, removeAvatar: boolean,
    sessionToken: string): Promise<AccountSnapshot> {
    const value = await AccountCommerceApi.request('/v1/me/profile', 'POST',
      JSON.stringify({
        displayName: displayName,
        avatarBase64: avatarBase64,
        removeAvatar: removeAvatar
      }), sessionToken);
    return AccountCommerceApi.normalizeAccount(JSON.parse(value) as AccountSnapshot);
  }

  static async redeemTheme(themeId: string, requestId: string,
    sessionToken: string): Promise<AccountSnapshot> {
    const value = await AccountCommerceApi.request(`/v1/themes/${encodeURIComponent(themeId)}/redeem`,
      'POST', JSON.stringify({ requestId: requestId }), sessionToken);
    return AccountCommerceApi.normalizeAccount(JSON.parse(value) as AccountSnapshot);
  }

  static async creditIapPurchase(purchaseData: string, sessionToken: string): Promise<IapCreditResponse> {
    const value = await AccountCommerceApi.request('/v1/iap/credit', 'POST',
      JSON.stringify({ purchaseData: purchaseData }), sessionToken);
    const response = JSON.parse(value) as IapCreditResponse;
    response.account = AccountCommerceApi.normalizeAccount(response.account);
    return response;
  }

  private static async request(path: string, method: string, body: string, sessionToken: string): Promise<string> {
    if (!AccountCommerceConfig.isServerConfigured()) {
      throw new AccountApiError('账号服务端尚未配置', 0, 'SERVER_NOT_CONFIGURED');
    }
    const client = http.createHttp();
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'application/json;charset=UTF-8'
    };
    if (sessionToken) {
      headers['Authorization'] = `Bearer ${sessionToken}`;
    }
    try {
      const response = await client.request(`${AccountCommerceConfig.API_BASE_URL}${path}`, {
        method: AccountCommerceApi.resolveMethod(method),
        header: headers,
        extraData: body || undefined,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      const statusCode = Number(response.responseCode);
      const value = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      if (statusCode < 200 || statusCode >= 300) {
        const error = AccountCommerceApi.parseError(value);
        throw new AccountApiError(error.message || `服务请求失败（${statusCode}）`, statusCode, error.code);
      }
      return value;
    } finally {
      client.destroy();
    }
  }

  private static resolveMethod(method: string): http.RequestMethod {
    if (method === 'GET') {
      return http.RequestMethod.GET;
    }
    return http.RequestMethod.POST;
  }

  private static parseError(value: string): ApiErrorBody {
    try {
      return JSON.parse(value) as ApiErrorBody;
    } catch (e) {
      const result = new ApiErrorBody();
      result.message = value;
      return result;
    }
  }

  private static normalizeAccount(account: AccountSnapshot): AccountSnapshot {
    const result = new AccountSnapshot();
    result.userId = account?.userId || '';
    result.displayName = account?.displayName || '华为用户';
    result.avatarUrl = account?.avatarUrl || '';
    result.points = Math.max(0, Math.floor(Number(account?.points) || 0));
    result.welcomeGranted = account?.welcomeGranted === true;
    result.entitlements = account?.entitlements || [];
    return result;
  }
}
