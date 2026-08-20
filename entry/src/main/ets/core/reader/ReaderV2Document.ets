import { ReaderActionData, ReaderActionMarker, ReaderActionMatch } from '../book/ReaderActionMarker';

/**
 * V2 阅读文档只保存语义和稳定偏移，不保存任何 ArkUI 组件状态。
 * 书源动作标记在这里被转换为普通可见文字和独立 Action，不再进入排版字符串。
 */
export class ReaderV2OffsetSegment {
  sourceStart: number = 0;
  sourceEnd: number = 0;
  displayStart: number = 0;
  displayEnd: number = 0;

  constructor(sourceStart: number, sourceEnd: number, displayStart: number, displayEnd: number) {
    this.sourceStart = sourceStart;
    this.sourceEnd = sourceEnd;
    this.displayStart = displayStart;
    this.displayEnd = displayEnd;
  }
}

export class ReaderV2InlineAction {
  id: string = '';
  marker: string = '';
  label: string = '';
  title: string = '';
  url: string = '';
  displayStart: number = 0;
  displayEnd: number = 0;
  sourceStart: number = 0;
  sourceEnd: number = 0;

  constructor(id: string, marker: string, label: string, data: ReaderActionData,
    displayStart: number, displayEnd: number, sourceStart: number, sourceEnd: number) {
    this.id = id;
    this.marker = marker;
    this.label = label;
    this.title = data.title || '';
    this.url = data.url || '';
    this.displayStart = displayStart;
    this.displayEnd = displayEnd;
    this.sourceStart = sourceStart;
    this.sourceEnd = sourceEnd;
  }
}

export class ReaderV2Block {
  id: string = '';
  text: string = '';
  displayStart: number = 0;
  displayEnd: number = 0;
  sourceStart: number = 0;
  sourceEnd: number = 0;
  title: boolean = false;

  constructor(id: string, text: string, displayStart: number, displayEnd: number,
    sourceStart: number, sourceEnd: number, title: boolean) {
    this.id = id;
    this.text = text;
    this.displayStart = displayStart;
    this.displayEnd = displayEnd;
    this.sourceStart = sourceStart;
    this.sourceEnd = sourceEnd;
    this.title = title;
  }
}

export class ReaderV2RegexRange {
  start: number = 0;
  end: number = 0;
  ruleIndex: number = -1;

  constructor(start: number, end: number, ruleIndex: number) {
    this.start = start;
    this.end = end;
    this.ruleIndex = ruleIndex;
  }
}

export class ReaderV2Document {
  chapterIndex: number = 0;
  chapterTitle: string = '';
  sourceText: string = '';
  displayText: string = '';
  blocks: ReaderV2Block[] = [];
  actions: ReaderV2InlineAction[] = [];
  offsets: ReaderV2OffsetSegment[] = [];
  regexRanges: ReaderV2RegexRange[] = [];
  identity: string = '';

  sourceOffsetForDisplay(displayOffset: number): number {
    const target = Math.max(0, Math.min(this.displayText.length, displayOffset));
    for (const segment of this.offsets) {
      if (target < segment.displayStart || target > segment.displayEnd) continue;
      const displayLength = segment.displayEnd - segment.displayStart;
      const sourceLength = segment.sourceEnd - segment.sourceStart;
      if (displayLength <= 0 || sourceLength <= 0) return segment.sourceStart;
      const ratio = (target - segment.displayStart) / displayLength;
      return Math.round(segment.sourceStart + ratio * sourceLength);
    }
    return target >= this.displayText.length ? this.sourceText.length : target;
  }

  displayOffsetForSource(sourceOffset: number): number {
    const target = Math.max(0, Math.min(this.sourceText.length, sourceOffset));
    for (const segment of this.offsets) {
      if (target < segment.sourceStart || target > segment.sourceEnd) continue;
      const sourceLength = segment.sourceEnd - segment.sourceStart;
      const displayLength = segment.displayEnd - segment.displayStart;
      if (sourceLength <= 0 || displayLength <= 0) return segment.displayStart;
      const ratio = (target - segment.sourceStart) / sourceLength;
      return Math.round(segment.displayStart + ratio * displayLength);
    }
    return target >= this.sourceText.length ? this.displayText.length : target;
  }

  plainText(start: number = 0, end: number = this.displayText.length): string {
    return this.displayText.substring(Math.max(0, start), Math.max(start, Math.min(this.displayText.length, end)));
  }

  copyText(start: number, end: number): string {
    const safeStart = Math.max(0, Math.min(this.displayText.length, start));
    const safeEnd = Math.max(safeStart, Math.min(this.displayText.length, end));
    let cursor = safeStart;
    let result = '';
    for (const action of this.actions) {
      if (action.displayEnd <= safeStart || action.displayStart >= safeEnd) continue;
      const actionStart = Math.max(safeStart, action.displayStart);
      if (actionStart > cursor) result += this.displayText.substring(cursor, actionStart);
      cursor = Math.max(cursor, Math.min(safeEnd, action.displayEnd));
    }
    if (cursor < safeEnd) result += this.displayText.substring(cursor, safeEnd);
    return result.replace(/\u200B/g, '').trim();
  }
}

export class ReaderV2SpeechSegment {
  speechStart: number = 0;
  speechEnd: number = 0;
  sourceStart: number = 0;
  sourceEnd: number = 0;

  constructor(speechStart: number, speechEnd: number, sourceStart: number, sourceEnd: number) {
    this.speechStart = speechStart;
    this.speechEnd = speechEnd;
    this.sourceStart = sourceStart;
    this.sourceEnd = sourceEnd;
  }
}

/** Text sent to TTS plus an exact mapping back to the source document. */
export class ReaderV2SpeechText {
  text: string = '';
  sourceStart: number = 0;
  segments: ReaderV2SpeechSegment[] = [];

  sourceOffsetAt(speechOffset: number): number {
    const target = Math.max(0, Math.min(this.text.length, speechOffset));
    for (let index = 0; index < this.segments.length; index++) {
      const segment = this.segments[index];
      if (target < segment.speechStart || target > segment.speechEnd) continue;
      // Hidden action markers do not occupy speech text. The segment before and after a marker
      // therefore share one speech boundary. Prefer the following segment at that boundary so
      // the first sentence after a paragraph comment maps after the marker instead of jumping
      // back to the previous page.
      const next = index + 1 < this.segments.length ? this.segments[index + 1] : null;
      if (target === segment.speechEnd && next && next.speechStart === target) continue;
      return segment.sourceStart + Math.max(0, Math.min(segment.sourceEnd - segment.sourceStart,
        target - segment.speechStart));
    }
    return this.segments.length > 0 ? this.segments[this.segments.length - 1].sourceEnd : this.sourceStart;
  }

  speechOffsetAt(sourceOffset: number): number {
    const target = Math.max(this.sourceStart, sourceOffset);
    for (const segment of this.segments) {
      if (target < segment.sourceStart) return segment.speechStart;
      if (target <= segment.sourceEnd) {
        return segment.speechStart + Math.max(0, Math.min(segment.speechEnd - segment.speechStart,
          target - segment.sourceStart));
      }
    }
    return this.text.length;
  }

  static build(document: ReaderV2Document, sourceStart: number): ReaderV2SpeechText {
    const result = new ReaderV2SpeechText();
    result.sourceStart = Math.max(0, Math.min(document.sourceText.length, sourceStart));
    let sourceCursor = result.sourceStart;
    const containingMarker = ReaderActionMarker.findRawRangeContaining(document.sourceText, sourceCursor);
    if (containingMarker.length >= 2) {
      // A saved page boundary from an older layout can point into a compact action marker. Starting a speech
      // substring there bypasses the normal marker scanner and exposes dimensions/scripts as spoken正文.
      sourceCursor = containingMarker[1];
      result.sourceStart = sourceCursor;
    }
    let speechCursor = 0;
    let text = '';
    while (sourceCursor < document.sourceText.length) {
      const bounds = ReaderActionMarker.findFirstRawRange(document.sourceText, sourceCursor);
      const actionStart = bounds.length >= 2 ? bounds[0] : document.sourceText.length;
      if (actionStart > sourceCursor) {
        const plain = document.sourceText.substring(sourceCursor, actionStart);
        text += plain;
        result.segments.push(new ReaderV2SpeechSegment(speechCursor, speechCursor + plain.length,
          sourceCursor, actionStart));
        speechCursor += plain.length;
      }
      if (bounds.length < 2) break;
      sourceCursor = bounds[1];
    }
    result.text = text;
    return result;
  }
}

export class ReaderV2DocumentParser {
  private static readonly MAX_ACTIONS_PER_CHAPTER: number = 320;

  static parse(source: string, chapterIndex: number, chapterTitle: string): ReaderV2Document {
    const document = new ReaderV2Document();
    document.chapterIndex = chapterIndex;
    document.chapterTitle = (chapterTitle || '').trim();
    document.sourceText = ReaderV2DocumentParser.normalizeSource(source || '');

    let sourceCursor = 0;
    let displayCursor = 0;
    let actionIndex = 0;
    let display = '';
    while (sourceCursor < document.sourceText.length) {
      // Search the original chapter with an absolute cursor. Repeatedly slicing the entire remaining chapter
      // made a comment-heavy source allocate O(actions * chapterLength) temporary strings while opening.
      const rawBounds = ReaderActionMarker.findFirstRawRange(document.sourceText, sourceCursor);
      if (rawBounds.length < 2) {
        const tail = document.sourceText.substring(sourceCursor);
        display += tail;
        document.offsets.push(new ReaderV2OffsetSegment(sourceCursor, document.sourceText.length,
          displayCursor, displayCursor + tail.length));
        displayCursor += tail.length;
        sourceCursor = document.sourceText.length;
        break;
      }

      const absoluteStart = rawBounds[0];
      const absoluteEnd = rawBounds[1];
      if (absoluteStart > sourceCursor) {
        const before = document.sourceText.substring(sourceCursor, absoluteStart);
        display += before;
        document.offsets.push(new ReaderV2OffsetSegment(sourceCursor, absoluteStart,
          displayCursor, displayCursor + before.length));
        displayCursor += before.length;
      }

      const actionMatch = ReaderActionMarker.findFirst(document.sourceText, sourceCursor);
      const validAction = actionMatch && actionMatch.start === absoluteStart && actionMatch.end === absoluteEnd &&
        actionIndex < ReaderV2DocumentParser.MAX_ACTIONS_PER_CHAPTER;
      if (!validAction || !actionMatch) {
        // Damaged and excessive markers are provider metadata, not正文. Drop only the marker and retain an
        // explicit zero-width mapping so progress/TTS offsets continue past it without exposing its payload.
        document.offsets.push(new ReaderV2OffsetSegment(absoluteStart, absoluteEnd,
          displayCursor, displayCursor));
        sourceCursor = absoluteEnd;
        continue;
      }
      const label = ReaderV2DocumentParser.actionLabel(actionMatch);
      const labelStart = displayCursor;
      display += label;
      displayCursor += label.length;
      document.offsets.push(new ReaderV2OffsetSegment(absoluteStart, absoluteEnd, labelStart, displayCursor));
      document.actions.push(new ReaderV2InlineAction(`action_${chapterIndex}_${actionIndex++}`,
        actionMatch.marker, label, actionMatch.data, labelStart, displayCursor, absoluteStart, absoluteEnd));
      sourceCursor = absoluteEnd;
    }

    document.displayText = display;
    ReaderV2DocumentParser.buildBlocks(document);
    document.identity = ReaderV2DocumentParser.hashIdentity(document.sourceText, chapterIndex);
    return document;
  }

  private static normalizeSource(source: string): string {
    return source.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\n{3,}/g, '\n\n');
  }

  private static actionLabel(match: ReaderActionMatch): string {
    const configured = (match.data.label || '').trim();
    const count = configured.match(/(99\+|\d+)\s*$/);
    if (count && count[1]) {
      const raw = count[1];
      const value = raw === '99+' ? 100 : Number.parseInt(raw, 10);
      const displayCount = !Number.isFinite(value) || value <= 0 ? '0' : (value > 99 ? '99+' : `${value}`);
      return `\u2060  ◌ ${displayCount}  `;
    }
    if (/本章说/.test(configured)) return '\u2060  ◌ 本章说  ';
    if (/段评|评论|神评论/.test(configured)) return '\u2060  ◌ 段评  ';
    return `\u2060  ${configured || '打开'}  `;
  }

  private static buildBlocks(document: ReaderV2Document): void {
    const text = document.displayText;
    let cursor = 0;
    let blockIndex = 0;
    const separator = /\n+/g;
    let match = separator.exec(text);
    while (match) {
      const end = match.index;
      const blockText = text.substring(cursor, end);
      // A run of source newlines is one semantic paragraph boundary. Empty Text paragraphs used to create
      // their own line box and paragraph gap, so "\n\n" became three independent vertical reservations.
      // Keeping the delimiter in displayText preserves source/TTS offsets while excluding it from geometry.
      if (blockText.length > 0) {
        const sourceStart = document.sourceOffsetForDisplay(cursor);
        const sourceEnd = document.sourceOffsetForDisplay(end);
        const title = blockIndex === 0 && !!document.chapterTitle && blockText.startsWith(document.chapterTitle);
        document.blocks.push(new ReaderV2Block(`block_${document.chapterIndex}_${blockIndex++}`, blockText,
          cursor, end, sourceStart, sourceEnd, title));
      }
      cursor = match.index + match[0].length;
      match = separator.exec(text);
    }
    if (cursor < text.length) {
      const blockText = text.substring(cursor);
      const sourceStart = document.sourceOffsetForDisplay(cursor);
      const sourceEnd = document.sourceOffsetForDisplay(text.length);
      const title = blockIndex === 0 && !!document.chapterTitle && blockText.startsWith(document.chapterTitle);
      document.blocks.push(new ReaderV2Block(`block_${document.chapterIndex}_${blockIndex}`, blockText,
        cursor, text.length, sourceStart, sourceEnd, title));
    }
  }

  private static hashIdentity(text: string, chapterIndex: number): string {
    let hash = 2166136261;
    for (let index = 0; index < text.length; index++) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return `reader_document_v2_${chapterIndex}_${text.length}_${hash >>> 0}`;
  }
}
