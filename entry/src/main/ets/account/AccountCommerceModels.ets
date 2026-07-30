export class ThemeEntitlement {
  themeId: string = '';
  expiresAt: number = 0;
}

export class AccountSnapshot {
  userId: string = '';
  displayName: string = '华为用户';
  avatarUrl: string = '';
  points: number = 0;
  paidPoints: number = 0;
  promoPoints: number = 0;
  iapDebtPoints: number = 0;
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
  debtOffsetPoints: number = 0;
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

export class TtsVoiceInfo {
  id: string = '';
  name: string = '';
  tier: string = 'STANDARD';
  description: string = '';
  supportsPitch: boolean = false;
  supportsWordTimestamps: boolean = false;
}

export class TtsPackageInfo {
  sku: string = '';
  tier: string = 'STANDARD';
  chars: number = 0;
  points: number = 0;
  validDays: number = 365;
}

export class TtsTrialInfo {
  standardChars: number = 0;
  premiumChars: number = 0;
  validDays: number = 0;
}

export class TtsCatalogResponse {
  voices: TtsVoiceInfo[] = [];
  packages: TtsPackageInfo[] = [];
  trial: TtsTrialInfo = new TtsTrialInfo();
}

export class TtsWalletSnapshot {
  standardChars: number = 0;
  premiumChars: number = 0;
  standardNextExpiry: number | null = null;
  premiumNextExpiry: number | null = null;
}

export class TtsPackageRedeemResponse {
  account: AccountSnapshot = new AccountSnapshot();
  ttsWallet: TtsWalletSnapshot = new TtsWalletSnapshot();
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
