export type TtsTier = 'STANDARD' | 'PREMIUM';

export interface TtsVoice {
  id: string;
  name: string;
  tier: TtsTier;
  property: string;
  description: string;
  supportsPitch: boolean;
  supportsWordTimestamps: boolean;
}

export interface TtsPackage {
  sku: string;
  tier: TtsTier;
  chars: number;
  points: number;
  validDays: number;
}

export const TTS_TRIAL_VERSION = 1;
export const TTS_TRIAL_VALID_DAYS = 30;
export const TTS_STANDARD_TRIAL_CHARS = 5_000;
export const TTS_PREMIUM_TRIAL_CHARS = 1_000;

export const TTS_VOICES: readonly TtsVoice[] = [
  {
    id: 'xiaoqi',
    name: '小琪',
    tier: 'STANDARD',
    property: 'chinese_xiaoqi_common',
    description: '标准女声 · 客服',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'xiaoyu',
    name: '小宇',
    tier: 'STANDARD',
    property: 'chinese_xiaoyu_common',
    description: '标准男声 · 电销',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'xiaoyan',
    name: '小燕',
    tier: 'STANDARD',
    property: 'chinese_xiaoyan_common',
    description: '温柔女声 · 文学',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'xiaowang',
    name: '小王',
    tier: 'STANDARD',
    property: 'chinese_xiaowang_common',
    description: '童声',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'huaxiaomei',
    name: '华小美',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaomei_common',
    description: '温柔女声 · 客服',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaofei',
    name: '华小飞',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaofei_common',
    description: '朝气男声 · 客服',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaoru',
    name: '华小汝',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaoru_common',
    description: '柔美女声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'huaxiaohan',
    name: '华小涵',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaohan_common',
    description: '知性女声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'huaxiaorui',
    name: '华小蕊',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaorui_common',
    description: '知性女声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'huaxiaolong',
    name: '华小龙',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaolong_common',
    description: '朝气男声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'huaxiaozhen',
    name: '华小珍',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaozhen_common',
    description: '温柔女声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: false
  },
  {
    id: 'huaxiaohe',
    name: '华小荷',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaohe_common',
    description: '嘹亮女声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaoye',
    name: '华小叶',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaoye_common',
    description: '知性女声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaoxue',
    name: '华小雪',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaoxue_common',
    description: '女童声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaojiao',
    name: '华小娇',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaojiao_common',
    description: '成熟女声 · 纯中文',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaohui',
    name: '华小辉',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaohui_common',
    description: '男童声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaokang',
    name: '华小康',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaokang_common',
    description: '朝气男声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaokun',
    name: '华小坤',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaokun_common',
    description: '成熟男声 · 中英混合',
    supportsPitch: true,
    supportsWordTimestamps: true
  },
  {
    id: 'huaxiaoquan',
    name: '华小泉',
    tier: 'PREMIUM',
    property: 'chinese_huaxiaoquan_common',
    description: '朝气男声 · 纯中文',
    supportsPitch: true,
    supportsWordTimestamps: true
  }
] as const;

export const TTS_PACKAGES: readonly TtsPackage[] = [
  { sku: 'tts_standard_100k', tier: 'STANDARD', chars: 100_000, points: 59, validDays: 365 },
  { sku: 'tts_standard_500k', tier: 'STANDARD', chars: 500_000, points: 269, validDays: 365 },
  { sku: 'tts_standard_1m', tier: 'STANDARD', chars: 1_000_000, points: 499, validDays: 365 },
  { sku: 'tts_premium_100k', tier: 'PREMIUM', chars: 100_000, points: 99, validDays: 365 },
  { sku: 'tts_premium_500k', tier: 'PREMIUM', chars: 500_000, points: 449, validDays: 365 },
  { sku: 'tts_premium_1m', tier: 'PREMIUM', chars: 1_000_000, points: 899, validDays: 365 }
] as const;

export function findTtsPackage(sku: string): TtsPackage | undefined {
  return TTS_PACKAGES.find((item) => item.sku === sku);
}

export function findTtsVoice(id: string): TtsVoice | undefined {
  return TTS_VOICES.find((item) => item.id === id);
}

export function ttsBillingUnit(tier: TtsTier): number {
  return tier === 'PREMIUM' ? 50 : 100;
}

export function countTtsCharacters(text: string): number {
  return Array.from(text.normalize('NFC')).length;
}

export function chargedTtsCharacters(text: string, tier: TtsTier): number {
  const raw = countTtsCharacters(text);
  if (raw <= 0) return 0;
  const unit = ttsBillingUnit(tier);
  return Math.ceil(raw / unit) * unit;
}
