/** Records externally visible effects so a replayed ArkWeb script cannot apply them twice. */
export class BookSourceExecutionJournal {
  responses: Record<string, string> = {};
  private startedRequestIds: string[] = [];
  private completedRequestIds: string[] = [];
  private appliedOperationIds: string[] = [];
  sideEffectsStarted: boolean = false;

  reset(): void {
    this.responses = {};
    this.startedRequestIds = [];
    this.completedRequestIds = [];
    this.appliedOperationIds = [];
    this.sideEffectsStarted = false;
  }

  hasResponse(request: string): boolean {
    return Object.prototype.hasOwnProperty.call(this.responses, request || '');
  }

  response(request: string): string {
    return this.responses[request || ''] || '';
  }

  markRequestStarted(request: string): boolean {
    const id = this.stableId(`request\n${request || ''}`);
    if (this.startedRequestIds.includes(id)) return false;
    this.startedRequestIds.push(id);
    this.sideEffectsStarted = true;
    return true;
  }

  recordResponse(request: string, response: string): void {
    const key = request || '';
    this.responses[key] = response || '';
    const id = this.stableId(`request\n${key}`);
    if (!this.completedRequestIds.includes(id)) this.completedRequestIds.push(id);
  }

  markOperationApplied(kind: string, payload: string): boolean {
    const id = this.stableId(`${kind || 'operation'}\n${payload || ''}`);
    if (this.appliedOperationIds.includes(id)) return false;
    this.appliedOperationIds.push(id);
    this.sideEffectsStarted = true;
    return true;
  }

  canFallback(): boolean {
    return !this.sideEffectsStarted;
  }

  private stableId(value: string): string {
    let hash = 2166136261;
    for (let index = 0; index < value.length; index++) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return `${hash >>> 0}`;
  }
}
