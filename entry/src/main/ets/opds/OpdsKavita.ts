// Kavita 适配：它的 OPDS 靠地址里的密钥认证（/api/opds/<密钥>），不支持账号密码直连。
// 这里只放地址与登录响应的纯逻辑，无平台 API 依赖，可在 Node 中直接运行。

const KAVITA_OPDS_URL: RegExp = /^(https?:\/\/[^?#]*?)\/api\/opds\/([^/?#]+)/i;

export class OpdsKavita {
  // 是否为带密钥的 Kavita OPDS 地址。这类地址本身就是凭据，不应再附带账号密码。
  static isOpdsUrl(url: string): boolean {
    return KAVITA_OPDS_URL.test((url || '').trim());
  }

  // 从 Kavita OPDS 地址取回站点地址（含反向代理的子路径），不是 Kavita 地址时返回空串。
  static siteOfOpdsUrl(url: string): string {
    const match: RegExpMatchArray | null = (url || '').trim().match(KAVITA_OPDS_URL);
    return match === null ? '' : match[1];
  }

  // 用户填的网页地址可能带着页面路径（/login、/home 等），登录接口依次按原路径、站点根去试。
  static siteCandidates(pageUrl: string): string[] {
    const value: string = (pageUrl || '').trim().split('#')[0].split('?')[0].replace(/\/+$/, '');
    const origin: RegExpMatchArray | null = value.match(/^https?:\/\/[^/]+/i);
    if (origin === null) return [];
    const candidates: string[] = [value];
    if (candidates.indexOf(origin[0]) < 0) candidates.push(origin[0]);
    return candidates;
  }

  static loginUrl(site: string): string {
    return `${site}/api/account/login`;
  }

  static loginBody(username: string, password: string): string {
    return JSON.stringify({ username: username, password: password });
  }

  static opdsUrl(site: string, key: string): string {
    return `${site}/api/opds/${encodeURIComponent(key)}`;
  }

  // 登录响应里的 OPDS 密钥：新版放在 authKeys 里名为 opds 的那一项，apiKey 字段新旧版本都有。
  static keyFromLoginResponse(body: string): string {
    let data: Record<string, Object> | null = null;
    try {
      data = JSON.parse(body || '') as Record<string, Object> | null;
    } catch (_) {
      return '';
    }
    if (data === null || typeof data !== 'object') return '';
    const authKeys: Object = data['authKeys'];
    if (Array.isArray(authKeys)) {
      for (const item of authKeys as Record<string, Object>[]) {
        if (item === null || typeof item !== 'object') continue;
        const key: Object = item['key'];
        if (String(item['name'] || '').toLowerCase() === 'opds' && typeof key === 'string' && key !== '') {
          return key as string;
        }
      }
    }
    const apiKey: Object = data['apiKey'];
    return typeof apiKey === 'string' ? apiKey as string : '';
  }

  // 界面展示用：密钥等同于密码，列表里不整串显示。
  static maskedUrl(url: string): string {
    const match: RegExpMatchArray | null = (url || '').match(KAVITA_OPDS_URL);
    if (match === null) return url || '';
    return `${match[1]}/api/opds/••••${(url || '').substring(match[0].length)}`;
  }
}
