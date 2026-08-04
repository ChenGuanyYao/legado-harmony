import { authentication } from '@kit.AccountKit';
import { common, Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AccountCommerceApi } from './AccountCommerceApi';
import { AccountSnapshot, HuaweiLoginResponse, IapCreditResponse } from './AccountCommerceModels';
import { AccountSessionStore } from './AccountSessionStore';
import { CloudSyncSettingsStore } from './CloudSyncSettingsStore';

export class HuaweiAccountService {
  static async initialize(context: Context): Promise<void> {
    await AccountSessionStore.load(context);
  }

  static async login(context: common.UIAbilityContext): Promise<AccountSnapshot> {
    const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
    request.forceLogin = true;
    request.state = util.generateRandomUUID();
    const controller = new authentication.AuthenticationController(context);
    const response =
      await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;
    if (response.state && response.state !== request.state) {
      throw new Error('华为账号登录状态校验失败');
    }
    const authorizationCode = response.data?.authorizationCode || '';
    if (!authorizationCode) {
      throw new Error('华为账号未返回授权码');
    }
    const loginResponse: HuaweiLoginResponse = await AccountCommerceApi.login(authorizationCode);
    if (!loginResponse.sessionToken || !loginResponse.account?.userId) {
      throw new Error('账号服务返回的数据不完整');
    }
    await AccountSessionStore.saveLogin(context, loginResponse);
    await CloudSyncSettingsStore.load(context, AccountSessionStore.account().userId);
    return AccountSessionStore.account();
  }

  static async refresh(context: Context): Promise<AccountSnapshot> {
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      return AccountSessionStore.account();
    }
    const snapshot = await AccountCommerceApi.fetchAccount(AccountSessionStore.token());
    await AccountSessionStore.updateSnapshot(context, snapshot);
    return AccountSessionStore.account();
  }

  static async redeemTheme(context: Context, themeId: string, expectedPricePoints: number,
    expectedValidDays: number): Promise<AccountSnapshot> {
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      throw new Error('请先登录华为账号');
    }
    const snapshot = await AccountCommerceApi.redeemTheme(
      themeId, util.generateRandomUUID(), expectedPricePoints, expectedValidDays,
      AccountSessionStore.token());
    await AccountSessionStore.updateSnapshot(context, snapshot);
    return AccountSessionStore.account();
  }

  static async updateProfile(context: Context, displayName: string, avatarBase64: string,
    removeAvatar: boolean): Promise<AccountSnapshot> {
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      throw new Error('请先登录华为账号');
    }
    const snapshot = await AccountCommerceApi.updateProfile(
      displayName, avatarBase64, removeAvatar, AccountSessionStore.token());
    await AccountSessionStore.updateSnapshot(context, snapshot);
    return AccountSessionStore.account();
  }

  static async creditIapPurchase(context: Context, purchaseData: string): Promise<IapCreditResponse> {
    await AccountSessionStore.load(context);
    if (!AccountSessionStore.isLoggedIn()) {
      throw new Error('请先登录华为账号');
    }
    const result = await AccountCommerceApi.creditIapPurchase(purchaseData, AccountSessionStore.token());
    await AccountSessionStore.updateSnapshot(context, result.account);
    return result;
  }

  static async logout(context: Context): Promise<void> {
    const sessionToken = AccountSessionStore.token();
    if (sessionToken) {
      try {
        await AccountCommerceApi.logout(sessionToken);
      } catch {
        // Local logout must still succeed when the network is unavailable.
      }
    }
    await AccountSessionStore.clear(context);
    await CloudSyncSettingsStore.load(context, '');
  }
}
