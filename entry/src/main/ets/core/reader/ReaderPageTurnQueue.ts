/** One queued physical page turn handed back to the page for execution. */
export class ReaderQueuedPageTurn {
  direction: number = 0;
  style: string = '';
  velocity: number = 0;
  generation: number = 0;
}

/**
 * Page turns that arrive while another turn is still animating (or while the previous chapter's tail is being
 * rebuilt). The queue is bounded: rapid input flows into the next animation, but a long backlog cannot run away.
 * Only one direction/style is kept — a turn in another direction replaces what was waiting.
 */
export class ReaderPageTurnQueue {
  static readonly MAX_PENDING: number = 2;
  private direction: number = 0;
  private style: string = '';
  private count: number = 0;
  private velocity: number = 0;
  private generation: number = 0;

  enqueue(direction: number, style: string, velocity: number): void {
    if (this.direction === direction && this.style === style) {
      this.count = Math.min(ReaderPageTurnQueue.MAX_PENDING, this.count + 1);
      this.velocity = Math.max(this.velocity, velocity);
      return;
    }
    this.direction = direction;
    this.style = style;
    this.count = 1;
    this.velocity = velocity;
  }

  /** Something is waiting, so the reader is not idle yet. */
  hasPending(): boolean {
    return this.count > 0 || this.direction !== 0;
  }

  hasPendingBackward(): boolean {
    return this.direction < 0 && this.count > 0;
  }

  hasPendingForward(): boolean {
    return this.direction > 0 && this.count > 0;
  }

  pendingCount(): number {
    return this.count;
  }

  /** Removes one waiting turn; null when nothing can run. */
  take(): ReaderQueuedPageTurn | null {
    if (this.direction === 0 || this.count <= 0) return null;
    const turn = new ReaderQueuedPageTurn();
    turn.direction = this.direction;
    turn.style = this.style;
    turn.velocity = this.velocity;
    turn.generation = this.generation;
    this.count--;
    if (this.count <= 0) this.reset();
    return turn;
  }

  /** False once the queue was cancelled after this turn had been taken. */
  isCurrent(turn: ReaderQueuedPageTurn): boolean {
    return turn.generation === this.generation;
  }

  /** Drops what is waiting. A turn already taken still runs. */
  reset(): void {
    this.direction = 0;
    this.style = '';
    this.count = 0;
    this.velocity = 0;
  }

  /** Drops what is waiting and invalidates turns that were taken but have not started yet. */
  cancel(): void {
    this.reset();
    this.generation++;
  }
}
