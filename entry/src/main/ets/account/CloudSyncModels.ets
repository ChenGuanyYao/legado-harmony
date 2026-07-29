export class CloudSyncOperation {
  opId: string = '';
  entityType: string = '';
  entityId: string = '';
  operation: string = 'upsert';
  baseRevision: number = 0;
  payload: Object | null = null;
}

export class CloudSyncExchangeRequest {
  protocolVersion: number = 1;
  deviceId: string = '';
  deviceName: string = '';
  platform: string = 'HarmonyOS';
  appVersion: string = '';
  deviceKind: string = 'unknown';
  conflictPolicy: string = 'cloud';
  cursor: number = 0;
  operations: CloudSyncOperation[] = [];
}

export class CloudSyncConflict {
  payload: Object | null = null;
  deleted: boolean = false;
}

export class CloudSyncAcknowledgement {
  opId: string = '';
  accepted: boolean = false;
  revision: number = 0;
  sequenceId: number | null = null;
  conflict: CloudSyncConflict | null = null;
}

export class CloudSyncChange {
  sequenceId: number = 0;
  entityType: string = '';
  entityId: string = '';
  revision: number = 0;
  operation: string = '';
  payload: Object | null = null;
  deviceId: string = '';
  createdAt: number = 0;
}

export class CloudSyncExchangeResponse {
  protocolVersion: number = 1;
  acknowledgements: CloudSyncAcknowledgement[] = [];
  changes: CloudSyncChange[] = [];
  nextCursor: number = 0;
  hasMore: boolean = false;
  serverTime: number = 0;
}

export class CloudSyncDevice {
  deviceId: string = '';
  deviceName: string = '';
  platform: string = '';
  appVersion: string = '';
  deviceKind: string = 'unknown';
  createdAt: number = 0;
  lastSeenAt: number = 0;
  revokedAt: number | null = null;
}

export class CloudSyncDeviceListResponse {
  devices: CloudSyncDevice[] = [];
}

export class CloudSyncSummary {
  activeEntityCount: number = 0;
}
