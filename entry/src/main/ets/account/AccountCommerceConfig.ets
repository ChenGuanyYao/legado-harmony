import { RechargeProduct } from './AccountCommerceModels';

export class AccountCommerceConfig {
  /**
   * Must be an HTTPS origin that hosts the companion service in /server.
   * Keep Huawei client secrets and IAP private keys on that service only.
   */
  static readonly API_BASE_URL: string = 'https://qingye.icynol.com';
  static readonly THEME_PRICE_POINTS: number = 60;
  static readonly THEME_VALID_DAYS: number = 365;

  static readonly PRODUCT_POINTS_10: string = 'legado_points_10';
  static readonly PRODUCT_POINTS_60: string = 'legado_points_60';
  static readonly PRODUCT_POINTS_100: string = 'legado_points_100';
  static readonly PRODUCT_POINTS_300: string = 'legado_points_300';

  static isServerConfigured(): boolean {
    const value = AccountCommerceConfig.API_BASE_URL.trim();
    return value.startsWith('https://') && !value.includes('example.com');
  }

  static rechargeProducts(): RechargeProduct[] {
    return [
      new RechargeProduct(AccountCommerceConfig.PRODUCT_POINTS_10, 10, 1),
      new RechargeProduct(AccountCommerceConfig.PRODUCT_POINTS_60, 60, 6),
      new RechargeProduct(AccountCommerceConfig.PRODUCT_POINTS_100, 100, 10),
      new RechargeProduct(AccountCommerceConfig.PRODUCT_POINTS_300, 300, 30)
    ];
  }
}
