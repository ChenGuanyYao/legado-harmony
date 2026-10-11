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

  // 尾斜杠原样保留：有的服务器只认 /opds/（talebook），有的只认不带斜杠的地址（Komga），
  // 两种写法都连不上时由 OpdsClient.fetchCatalog 自动换另一种再试。
  static normalizeBaseUrl(value: string): string {
    return (value || '').trim();
  }
}
