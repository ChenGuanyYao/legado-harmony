export class ReaderActionData {
  label: string = '';
  url: string = '';
  title: string = '';
}

export class ReaderActionMatch {
  marker: string = '';
  start: number = -1;
  end: number = -1;
  data: ReaderActionData = new ReaderActionData();
}

/** A persisted reader marker for source-provided actions such as paragraph comments. */
export class ReaderActionMarker {
  static readonly PREFIX: string = '[[LEGADO_READER_ACTION_V3:';
  static readonly LEGACY_PREFIX: string = '[[LEGADO_READER_ACTION_V2:';
  static readonly ORIGINAL_PREFIX: string = '[[LEGADO_READER_ACTION:';
  static readonly SUFFIX: string = ']]';

  static create(label: string, url: string, title: string = ''): string {
    const data = new ReaderActionData();
    data.label = (label || '').trim() || '打开';
    data.url = (url || '').trim();
    data.title = (title || '').trim();
    if (!data.url) return '';
    return `${ReaderActionMarker.PREFIX}${encodeURIComponent(JSON.stringify(data))}${ReaderActionMarker.SUFFIX}`;
  }

  static parse(value: string): ReaderActionData | null {
    const text = (value || '').trim();
    const prefix = text.startsWith(ReaderActionMarker.PREFIX) ? ReaderActionMarker.PREFIX :
      (text.startsWith(ReaderActionMarker.LEGACY_PREFIX) ? ReaderActionMarker.LEGACY_PREFIX :
        (text.startsWith(ReaderActionMarker.ORIGINAL_PREFIX) ? ReaderActionMarker.ORIGINAL_PREFIX : ''));
    if (!prefix || !text.endsWith(ReaderActionMarker.SUFFIX)) return null;
    const encoded = text.substring(prefix.length,
      text.length - ReaderActionMarker.SUFFIX.length);
    try {
      const record = JSON.parse(decodeURIComponent(encoded)) as Record<string, Object>;
      const data = new ReaderActionData();
      data.label = String(record['label'] || '打开');
      data.url = String(record['url'] || '');
      data.title = String(record['title'] || '');
      return data.url ? data : null;
    } catch (_) {
      return null;
    }
  }

  static has(value: string): boolean {
    const text = value || '';
    return text.includes(ReaderActionMarker.PREFIX) || text.includes(ReaderActionMarker.LEGACY_PREFIX) ||
      text.includes(ReaderActionMarker.ORIGINAL_PREFIX);
  }

  static hasLegacy(value: string): boolean {
    const text = value || '';
    return text.includes(ReaderActionMarker.LEGACY_PREFIX) || text.includes(ReaderActionMarker.ORIGINAL_PREFIX);
  }

  static strip(value: string, preserveOffsets: boolean = false): string {
    let source = value || '';
    for (const prefix of [ReaderActionMarker.PREFIX, ReaderActionMarker.LEGACY_PREFIX,
      ReaderActionMarker.ORIGINAL_PREFIX]) {
      const pattern = new RegExp(`${this.escape(prefix)}[^\\]]+${this.escape(ReaderActionMarker.SUFFIX)}`, 'g');
      source = source.replace(pattern, (marker: string): string => preserveOffsets ? ' '.repeat(marker.length) : '');
    }
    return source;
  }

  static findFirst(value: string): ReaderActionMatch | null {
    const source = value || '';
    let start = -1;
    for (const prefix of [ReaderActionMarker.PREFIX, ReaderActionMarker.LEGACY_PREFIX,
      ReaderActionMarker.ORIGINAL_PREFIX]) {
      const index = source.indexOf(prefix);
      if (index >= 0 && (start < 0 || index < start)) start = index;
    }
    if (start < 0) return null;
    const endIndex = source.indexOf(ReaderActionMarker.SUFFIX, start);
    if (endIndex < 0) return null;
    const end = endIndex + ReaderActionMarker.SUFFIX.length;
    const marker = source.substring(start, end);
    const data = ReaderActionMarker.parse(marker);
    if (!data) return null;
    const match = new ReaderActionMatch();
    match.marker = marker;
    match.start = start;
    match.end = end;
    match.data = data;
    return match;
  }

  private static escape(value: string): string {
    return (value || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
}
