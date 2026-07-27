export class ThemeEntitlement {
  themeId: string = '';
  expiresAt: number = 0;
}

export class AccountSnapshot {
  userId: string = '';
  displayName: string = '华为用户';
  avatarUrl: string = '';
  points: number = 0;
  welcomeGranted: boolean = false;
  entitlements: ThemeEntitlement[] = [];
}

export class HuaweiLoginResponse {
  sessionToken: string = '';
  account: AccountSnapshot = new AccountSnapshot();
}

export class IapCreditResponse {
  account: AccountSnapshot = new AccountSnapshot();
  purchaseOrderId: string = '';
  purchaseToken: string = '';
  productType: number = 0;
  creditedPoints: number = 0;
}

export class RechargeProduct {
  productId: string = '';
  points: number = 0;
  expectedPriceYuan: number = 0;
  localPrice: string = '';

  constructor(productId: string, points: number, expectedPriceYuan: number) {
    this.productId = productId;
    this.points = points;
    this.expectedPriceYuan = expectedPriceYuan;
  }
}

export class AccountApiError extends Error {
  statusCode: number = 0;
  errorCode: string = '';

  constructor(message: string, statusCode: number = 0, errorCode: string = '') {
    super(message);
    this.name = 'AccountApiError';
    this.statusCode = statusCode;
    this.errorCode = errorCode;
  }
}
