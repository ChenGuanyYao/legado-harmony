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
  static readonly SOURCE_SCRIPT_SCHEME: string = 'legado-source-action:';
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

  /** Persist a user-triggered action supplied by the imported source without interpreting it. */
  static createSourceScript(label: string, script: string, title: string = ''): string {
    const code = (script || '').trim();
    if (!code || code.length > 4096) return '';
    return this.create(label, `${this.SOURCE_SCRIPT_SCHEME}${encodeURIComponent(code)}`, title);
  }

  static sourceScript(url: string): string {
    const value = (url || '').trim();
    if (!value.startsWith(this.SOURCE_SCRIPT_SCHEME)) return '';
    try {
      return decodeURIComponent(value.substring(this.SOURCE_SCRIPT_SCHEME.length));
    } catch (_) {
      return '';
    }
  }

  /** Compact provider action. Secrets and repeated endpoint data stay in the provider, outside measured text. */
  static createProviderComment(providerId: string, label: string, bookId: string, chapterId: string,
    paragraphId: string, mode: string = 'paragraph'): string {
    const safeLabel = (label || '').trim() || '段评';
    const safeProviderId = (providerId || '').trim();
    const safeBookId = (bookId || '').trim();
    const safeChapterId = (chapterId || '').trim();
    const safeParagraphId = (paragraphId || '').trim();
    if (!safeProviderId || !safeBookId || !safeChapterId || !safeParagraphId) return '';
    const modeCode = mode === 'chapterTitle' || mode === 'chapter' ? 'c' : 'p';
    const fields = [safeProviderId, safeLabel, safeBookId, safeChapterId, safeParagraphId]
      .map((value: string): string => encodeURIComponent(value));
    return `${ReaderActionMarker.PREFIX}P|${fields.join('|')}|${modeCode}${ReaderActionMarker.SUFFIX}`;
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
      if (encoded.startsWith('P|')) {
        const fields = encoded.split('|');
        if (fields.length !== 7) return null;
        const providerId = decodeURIComponent(fields[1] || '');
        const label = decodeURIComponent(fields[2] || '') || '段评';
        const bookId = decodeURIComponent(fields[3] || '');
        const chapterId = decodeURIComponent(fields[4] || '');
        const paragraphId = decodeURIComponent(fields[5] || '');
        if (!providerId || !bookId || !chapterId || !paragraphId) return null;
        const data = new ReaderActionData();
        data.label = label;
        data.url = `legado-provider-action://${encodeURIComponent(providerId)}/${encodeURIComponent(bookId)}/` +
          `${encodeURIComponent(chapterId)}/${encodeURIComponent(paragraphId)}?mode=` +
          `${fields[6] === 'c' ? 'chapterTitle' : 'paragraph'}`;
        data.title = fields[6] === 'c' ? '章评' : '段评';
        return data;
      }
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
