import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { util } from '@kit.ArkTS';
import { OpdsServerConfig } from './OpdsModels';

export class OpdsSettingsStore {
  private static readonly STORE_NAME: string = 'opds_settings';
  private static readonly KEY_CONNECTIONS: string = 'servers_v1';
  private static readonly KEY_ACTIVE_ID: string = 'active_server_id';

  static async loadServers(context: Context): Promise<OpdsServerConfig[]> {
    const store = await preferences.getPreferences(context, OpdsSettingsStore.STORE_NAME);
    const raw = await store.get(OpdsSettingsStore.KEY_CONNECTIONS, '');
    if (typeof raw !== 'string' || !raw) return [];
    try {
      const values = JSON.parse(raw) as OpdsServerConfig[];
      if (!Array.isArray(values)) return [];
      return values.map((value: OpdsServerConfig): OpdsServerConfig =>
        OpdsSettingsStore.normalize(value)).filter((value: OpdsServerConfig): boolean => !!value.id);
    } catch (_) {
      return [];
    }
  }

  static async saveServer(context: Context, source: OpdsServerConfig): Promise<OpdsServerConfig> {
    const servers = await OpdsSettingsStore.loadServers(context);
    const value = OpdsSettingsStore.normalize(source);
    const now = Date.now();
    if (!value.id) value.id = util.generateRandomUUID();
    if (!value.createdAt) value.createdAt = now;
    value.updatedAt = now;
    const index = servers.findIndex((item: OpdsServerConfig): boolean => item.id === value.id);
    if (index >= 0) servers[index] = value;
    else servers.push(value);
    const store = await preferences.getPreferences(context, OpdsSettingsStore.STORE_NAME);
    await store.put(OpdsSettingsStore.KEY_CONNECTIONS, JSON.stringify(servers));
    await store.put(OpdsSettingsStore.KEY_ACTIVE_ID, value.id);
    await store.flush();
    return value;
  }

  static async deleteServer(context: Context, serverId: string): Promise<void> {
    const servers = (await OpdsSettingsStore.loadServers(context))
      .filter((item: OpdsServerConfig): boolean => item.id !== serverId);
    const store = await preferences.getPreferences(context, OpdsSettingsStore.STORE_NAME);
    await store.put(OpdsSettingsStore.KEY_CONNECTIONS, JSON.stringify(servers));
    const active = await store.get(OpdsSettingsStore.KEY_ACTIVE_ID, '');
    if (active === serverId) {
      await store.put(OpdsSettingsStore.KEY_ACTIVE_ID, servers.length > 0 ? servers[0].id : '');
    }
    await store.flush();
  }

  static async activeServerId(context: Context): Promise<string> {
    const store = await preferences.getPreferences(context, OpdsSettingsStore.STORE_NAME);
    const value = await store.get(OpdsSettingsStore.KEY_ACTIVE_ID, '');
    return typeof value === 'string' ? value : '';
  }

  static async setActiveServerId(context: Context, serverId: string): Promise<void> {
    const store = await preferences.getPreferences(context, OpdsSettingsStore.STORE_NAME);
    await store.put(OpdsSettingsStore.KEY_ACTIVE_ID, serverId || '');
    await store.flush();
  }

  private static normalize(source: OpdsServerConfig): OpdsServerConfig {
    const result = new OpdsServerConfig();
    if (!source) return result;
    result.id = String(source.id || '').trim();
    result.name = String(source.name || '').trim() || 'OPDS';
    result.baseUrl = OpdsSettingsStore.normalizeBaseUrl(String(source.baseUrl || ''));
    const authType = String(source.authType || '').trim().toLowerCase();
    result.authType = authType === 'basic' ? 'basic' : 'none';
    result.username = String(source.username || '').trim();
    result.rememberPassword = source.rememberPassword !== false;
    result.enabled = source.enabled !== false;
    result.createdAt = Math.max(0, Math.floor(Number(source.createdAt) || 0));
    result.updatedAt = Math.max(0, Math.floor(Number(source.updatedAt) || 0));
    return result;
  }

  static normalizeBaseUrl(value: string): string {
    const result = (value || '').trim();
    if (!/^https:\/\//i.test(result) && !/^http:\/\//i.test(result)) return result;
    if (!result.endsWith('/')) return result;
    const withoutTrailingSlashes = result.replace(/\/+$/, '');
    if (!withoutTrailingSlashes) return result;
    // OPDS 地址去掉尾斜杠；仅根路径（如 http://example.com/）保留单个尾斜杠。
    const pathPart = withoutTrailingSlashes.replace(/^https?:\/\//i, '');
    if (pathPart.indexOf('/') >= 0) return withoutTrailingSlashes;
    return `${withoutTrailingSlashes}/`;
  }
}
