import { ReaderV2PageLayout } from './ReaderV2PageLayout';
import { ReaderV2LayoutSnapshot } from './ReaderV2LayoutSnapshot';

export class ReaderV2TapResult {
  kind: string = 'none';
  marker: string = '';
  zone: number = -1;
}

/** A single deterministic hit-test router shared by comments and the configurable 3x3 tap zones. */
export class ReaderV2GestureRouter {
  static hitTest(page: ReaderV2PageLayout | null, snapshot: ReaderV2LayoutSnapshot | null,
    x: number, y: number): ReaderV2TapResult {
    const result = new ReaderV2TapResult();
    if (!page || !snapshot) return result;
    const action = page.actionAt(x, y, snapshot.commentHitSlopXPx, snapshot.commentHitSlopYPx);
    if (action) {
      result.kind = 'action';
      result.marker = action.marker;
      return result;
    }
    const viewport = snapshot.viewport;
    if (!viewport.contains(x, y) || viewport.width() <= 0 || viewport.height() <= 0) return result;
    const column = Math.max(0, Math.min(2, Math.floor((x - viewport.left) / (viewport.width() / 3))));
    const row = Math.max(0, Math.min(2, Math.floor((y - viewport.top) / (viewport.height() / 3))));
    result.kind = 'zone';
    result.zone = row * 3 + column;
    return result;
  }
}

export class ReaderV2SelectionController {
  start: number = -1;
  end: number = -1;
  active: boolean = false;

  begin(wordRange: number[]): void {
    if (wordRange.length < 2 || wordRange[1] <= wordRange[0]) {
      this.clear();
      return;
    }
    this.start = wordRange[0];
    this.end = wordRange[1];
    this.active = true;
  }

  moveHandle(offset: number, leading: boolean): void {
    if (!this.active || offset < 0) return;
    if (leading) this.start = Math.min(offset, this.end - 1);
    else this.end = Math.max(offset, this.start + 1);
  }

  clear(): void {
    this.start = -1;
    this.end = -1;
    this.active = false;
  }
}
