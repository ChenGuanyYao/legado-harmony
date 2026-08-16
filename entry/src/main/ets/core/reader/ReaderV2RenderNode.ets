import drawing from '@ohos.graphics.drawing';
import { UIContext } from '@ohos.arkui.UIContext';
import {
  DrawContext,
  FrameNode,
  LayoutConstraint,
  NodeController,
  Position
} from '@ohos.arkui.node';
import graphicsText from '@ohos.graphics.text';
import { ReaderV2PageFragment, ReaderV2PageLayout } from './ReaderV2PageLayout';

class ReaderV2PageFrameNode extends FrameNode {
  private page: ReaderV2PageLayout | null = null;
  private highlightStart: number = -1;
  private highlightEnd: number = -1;
  private highlightColor: number = 0x55FFE58A;
  private selectionStart: number = -1;
  private selectionEnd: number = -1;
  private selectionColor: number = 0x553B82F6;

  constructor(uiContext: UIContext) {
    super(uiContext);
  }

  update(page: ReaderV2PageLayout | null, highlightStart: number, highlightEnd: number,
    selectionStart: number, selectionEnd: number): void {
    this.page = page;
    this.highlightStart = highlightStart;
    this.highlightEnd = highlightEnd;
    this.selectionStart = selectionStart;
    this.selectionEnd = selectionEnd;
    const renderNode = this.getRenderNode();
    if (renderNode) renderNode.invalidate();
  }

  setOverlayColors(highlightColor: number, selectionColor: number): void {
    this.highlightColor = highlightColor;
    this.selectionColor = selectionColor;
  }

  onMeasure(constraint: LayoutConstraint): void {
    this.setMeasuredSize({
      width: Math.max(constraint.minSize.width, constraint.maxSize.width),
      height: Math.max(constraint.minSize.height, constraint.maxSize.height)
    });
  }

  onLayout(position: Position): void {
    this.setLayoutPosition(position);
  }

  onDraw(context: DrawContext): void {
    if (!this.page) return;
    const canvas = context.canvas;
    for (const fragment of this.page.fragments) {
      if (!fragment.paragraph) continue;
      canvas.save();
      canvas.clipRect({
        left: fragment.clipRect.left,
        top: fragment.clipRect.top,
        right: fragment.clipRect.right,
        bottom: fragment.clipRect.bottom
      }, drawing.ClipOp.INTERSECT, true);
      this.drawRange(canvas, fragment, this.selectionStart, this.selectionEnd, this.selectionColor);
      this.drawRange(canvas, fragment, this.highlightStart, this.highlightEnd, this.highlightColor);
      fragment.paragraph.paint(canvas, fragment.paragraphX, fragment.paragraphY);
      canvas.restore();
    }
  }

  private drawRange(canvas: drawing.Canvas, fragment: ReaderV2PageFragment,
    absoluteStart: number, absoluteEnd: number, color: number): void {
    if (!fragment.paragraph || absoluteStart < 0 || absoluteEnd <= absoluteStart ||
      absoluteEnd <= fragment.displayStart || absoluteStart >= fragment.displayEnd) return;
    const localStart = Math.max(0, absoluteStart - fragment.displayStart);
    const localEnd = Math.min(fragment.localEnd - fragment.localStart,
      absoluteEnd - fragment.displayStart);
    if (localEnd <= localStart) return;
    const boxes = fragment.paragraph.getRectsForRange({ start: localStart, end: localEnd },
      graphicsText.RectWidthStyle.TIGHT, graphicsText.RectHeightStyle.MAX);
    const brush = new drawing.Brush();
    brush.setColor(color);
    canvas.attachBrush(brush);
    for (const box of boxes) {
      const left = Math.max(fragment.clipRect.left, fragment.paragraphX + box.rect.left);
      const top = Math.max(fragment.clipRect.top, fragment.paragraphY + box.rect.top);
      const right = Math.min(fragment.clipRect.right, fragment.paragraphX + box.rect.right);
      const bottom = Math.min(fragment.clipRect.bottom, fragment.paragraphY + box.rect.bottom);
      if (right > left && bottom > top) canvas.drawRect(left, top, right, bottom);
    }
    canvas.detachBrush();
  }
}

export class ReaderV2PageNodeController extends NodeController {
  private node: ReaderV2PageFrameNode | null = null;
  private page: ReaderV2PageLayout | null = null;
  private highlightStart: number = -1;
  private highlightEnd: number = -1;
  private selectionStart: number = -1;
  private selectionEnd: number = -1;

  makeNode(uiContext: UIContext): FrameNode | null {
    this.node = new ReaderV2PageFrameNode(uiContext);
    this.node.update(this.page, this.highlightStart, this.highlightEnd, this.selectionStart, this.selectionEnd);
    return this.node;
  }

  updatePage(page: ReaderV2PageLayout | null): void {
    this.page = page;
    this.publish();
  }

  updateHighlight(start: number, end: number): void {
    this.highlightStart = start;
    this.highlightEnd = end;
    this.publish();
  }

  updateSelection(start: number, end: number): void {
    this.selectionStart = start;
    this.selectionEnd = end;
    this.publish();
  }

  glyphDisplayOffsetAt(x: number, y: number): number {
    if (!this.page) return -1;
    for (const fragment of this.page.fragments) {
      if (!fragment.paragraph || !fragment.clipRect.contains(x, y)) continue;
      const position = fragment.paragraph.getGlyphPositionAtCoordinate(
        x - fragment.paragraphX, y - fragment.paragraphY).position;
      return Math.max(fragment.displayStart, Math.min(fragment.displayEnd, fragment.displayStart + position));
    }
    return -1;
  }

  wordRangeAt(x: number, y: number): number[] {
    if (!this.page) return [];
    for (const fragment of this.page.fragments) {
      if (!fragment.paragraph || !fragment.clipRect.contains(x, y)) continue;
      const position = fragment.paragraph.getGlyphPositionAtCoordinate(
        x - fragment.paragraphX, y - fragment.paragraphY).position;
      const range = fragment.paragraph.getWordBoundary(position);
      return [fragment.displayStart + range.start, fragment.displayStart + range.end];
    }
    return [];
  }

  private publish(): void {
    if (this.node) {
      this.node.update(this.page, this.highlightStart, this.highlightEnd,
        this.selectionStart, this.selectionEnd);
    }
  }
}
