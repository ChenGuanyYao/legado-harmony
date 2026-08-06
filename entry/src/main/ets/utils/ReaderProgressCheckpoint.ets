/**
 * Bridges UIAbility lifecycle events to the currently active reader page.
 *
 * Locking the screen does not consistently dispatch page-level onPageHide on every HarmonyOS device,
 * while UIAbility.onBackground is guaranteed for both Home and lock-screen background transitions.
 */
export class ReaderProgressCheckpoint {
  private static ownerId: string = '';
  private static saveAction: (() => Promise<void>) | null = null;

  static attach(ownerId: string, saveAction: () => Promise<void>): void {
    ReaderProgressCheckpoint.ownerId = ownerId;
    ReaderProgressCheckpoint.saveAction = saveAction;
  }

  static detach(ownerId: string): void {
    if (!ownerId || ReaderProgressCheckpoint.ownerId !== ownerId) return;
    ReaderProgressCheckpoint.ownerId = '';
    ReaderProgressCheckpoint.saveAction = null;
  }

  static request(reason: string): Promise<void> {
    const action = ReaderProgressCheckpoint.saveAction;
    if (!action) return Promise.resolve();
    return action().catch((error: Error) => {
      console.warn(`[ReaderProgressCheckpoint] ${reason} save failed:`, error);
    });
  }
}
