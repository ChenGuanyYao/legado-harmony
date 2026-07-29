export class CloudSyncChangeSnapshot {
  revision: number = 0;
}

export class CloudSyncChangeTracker {
  static readonly STORAGE_DATA_REVISION: string = 'cloudSyncDataChangeRevision';
  static readonly STORAGE_PREFERENCE_REVISION: string = 'cloudSyncPreferenceChangeRevision';
  static readonly STORAGE_APPLICATION_PREFERENCE_REVISION: string =
    'cloudSyncApplicationPreferenceChangeRevision';
  static readonly STORAGE_BOOK_SOURCE_REVISION: string = 'cloudSyncBookSourceChangeRevision';

  private static revision: number = 0;
  private static syncedRevision: number = 0;
  private static remoteApplyDepth: number = 0;

  static initializeStorage(): void {
    AppStorage.setOrCreate(CloudSyncChangeTracker.STORAGE_DATA_REVISION, 0);
    AppStorage.setOrCreate(CloudSyncChangeTracker.STORAGE_PREFERENCE_REVISION, 0);
    AppStorage.setOrCreate(CloudSyncChangeTracker.STORAGE_APPLICATION_PREFERENCE_REVISION, 0);
    AppStorage.setOrCreate(CloudSyncChangeTracker.STORAGE_BOOK_SOURCE_REVISION, 0);
  }

  static markDataChanged(): void {
    if (CloudSyncChangeTracker.remoteApplyDepth > 0 ||
      AppStorage.get<boolean>('cloudSyncReadingDataEnabled') === false) {
      return;
    }
    CloudSyncChangeTracker.bump(CloudSyncChangeTracker.STORAGE_DATA_REVISION);
  }

  static markReadingProgressChanged(): void {
    if (CloudSyncChangeTracker.remoteApplyDepth > 0 ||
      AppStorage.get<boolean>('cloudSyncReadingDataEnabled') === false) {
      return;
    }
    // 阅读过程中只记录待同步状态，不发出 UI 响应式信号。
    // 退出阅读页或应用进入后台时由对应生命周期统一触发同步。
    CloudSyncChangeTracker.revision++;
  }

  static markBookSourceChanged(): void {
    if (CloudSyncChangeTracker.remoteApplyDepth > 0 ||
      AppStorage.get<boolean>('cloudSyncBookSourcesEnabled') !== true) {
      return;
    }
    CloudSyncChangeTracker.bump(CloudSyncChangeTracker.STORAGE_BOOK_SOURCE_REVISION);
  }

  static markPreferenceChanged(): void {
    if (CloudSyncChangeTracker.remoteApplyDepth > 0 ||
      AppStorage.get<boolean>('cloudSyncReadingPreferencesEnabled') === false) {
      return;
    }
    CloudSyncChangeTracker.bump(CloudSyncChangeTracker.STORAGE_PREFERENCE_REVISION);
  }

  static markApplicationPreferenceChanged(): void {
    if (CloudSyncChangeTracker.remoteApplyDepth > 0 ||
      AppStorage.get<boolean>('cloudSyncApplicationPreferencesEnabled') === false) {
      return;
    }
    CloudSyncChangeTracker.bump(CloudSyncChangeTracker.STORAGE_APPLICATION_PREFERENCE_REVISION);
  }

  static beginRemoteApply(): void {
    CloudSyncChangeTracker.remoteApplyDepth++;
  }

  static endRemoteApply(): void {
    CloudSyncChangeTracker.remoteApplyDepth =
      Math.max(0, CloudSyncChangeTracker.remoteApplyDepth - 1);
  }

  static snapshot(): CloudSyncChangeSnapshot {
    const result = new CloudSyncChangeSnapshot();
    result.revision = CloudSyncChangeTracker.revision;
    return result;
  }

  static markSynced(snapshot: CloudSyncChangeSnapshot): void {
    CloudSyncChangeTracker.syncedRevision =
      Math.max(CloudSyncChangeTracker.syncedRevision, snapshot.revision);
  }

  static hasUnsyncedChanges(): boolean {
    return CloudSyncChangeTracker.revision > CloudSyncChangeTracker.syncedRevision;
  }

  private static bump(storageKey: string): void {
    CloudSyncChangeTracker.revision++;
    const current = AppStorage.get<number>(storageKey) || 0;
    AppStorage.setOrCreate(storageKey, current + 1);
  }
}
