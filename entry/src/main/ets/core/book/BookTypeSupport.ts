import { Book, BookSource, SearchBook } from '../../model/data/Book';

/** Legado-compatible remote book type bits. Local TXT/EPUB keep their existing 1/2 values. */
export class BookTypeSupport {
  static readonly TEXT: number = 8;
  static readonly AUDIO: number = 32;
  static readonly IMAGE: number = 64;
  static readonly WEB_FILE: number = 128;

  static typeFromSource(source: BookSource | null): number {
    if (!source) return 0;
    if (source.bookSourceType === 1) return this.AUDIO;
    if (source.bookSourceType === 2) return this.IMAGE;
    if (source.bookSourceType === 3) return this.TEXT | this.WEB_FILE;
    return 0;
  }

  static typeFromTab(tab: string): number {
    const value = String(tab || '').trim().toLowerCase();
    if (value === 'audio' || value === 'listen' || value === 'audiobook' || value === '听书' || value === '音频') {
      return this.AUDIO;
    }
    if (value === 'comic' || value === 'image' || value === 'manga' || value === '漫画') return this.IMAGE;
    if (value === 'novel' || value === 'text' || value === '小说') return this.TEXT;
    return 0;
  }

  static applySearchBookType(book: SearchBook, source: BookSource | null, tab: string = ''): void {
    const resolved = this.typeFromTab(tab) || this.typeFromVariable(book.variable) || this.typeFromSource(source);
    if (resolved) book.type = resolved;
  }

  static applyBookType(book: Book, source: BookSource | null = null, tab: string = ''): void {
    if (book.origin === 'local') return;
    const resolved = this.typeFromTab(tab) || this.typeFromVariable(book.variable) || this.typeFromSource(source) ||
      this.typeFromIdentity(book.originName, book.kind);
    if (resolved) book.type = resolved;
  }

  static isAudio(book: Book | SearchBook | null): boolean {
    if (!book || book.origin === 'local') return false;
    if ((Number(book.type) & this.AUDIO) !== 0) return true;
    return this.typeFromVariable(book.variable) === this.AUDIO ||
      this.typeFromIdentity(book.originName, book.kind) === this.AUDIO;
  }

  static isImage(book: Book | SearchBook | null): boolean {
    if (!book) return false;
    if (book.origin === 'local') return this.isLocalImageVariable(book.variable);
    if ((Number(book.type) & this.IMAGE) !== 0) return true;
    return this.typeFromVariable(book.variable) === this.IMAGE ||
      this.typeFromIdentity(book.originName, book.kind) === this.IMAGE;
  }

  static typeFromVariable(variable: string): number {
    if (!variable) return 0;
    try {
      const record = JSON.parse(variable) as Record<string, Object>;
      const tab = String(record['tab'] || record['type'] || record['mediaType'] || '');
      return this.typeFromTab(tab);
    } catch (_) {
      const match = variable.match(/["']?(?:tab|mediaType)["']?\s*:\s*["']([^"']+)["']/i);
      return match ? this.typeFromTab(match[1] || '') : 0;
    }
  }

  private static typeFromIdentity(originName: string, kind: string): number {
    const value = `${originName || ''}\n${kind || ''}`;
    if (/听书|有声|音频|audiobook/i.test(value)) return this.AUDIO;
    if (/漫画|漫改|comic|manga/i.test(value)) return this.IMAGE;
    return 0;
  }

  private static isLocalImageVariable(variable: string): boolean {
    if (!variable) return false;
    try {
      const record = JSON.parse(variable) as Record<string, Object>;
      const manualMode = String(record['readerComicManualMode'] || '').trim().toLowerCase();
      if (manualMode === 'text') return false;
      if (manualMode === 'comic') return true;
      const autoDetected = String(record['readerComicAutoDetected'] || '').trim().toLowerCase();
      const comicMode = String(record['readerComicMode'] || '').trim().toLowerCase();
      return autoDetected === '1' || autoDetected === 'true' ||
        comicMode === '1' || comicMode === 'true';
    } catch (_) {
      return false;
    }
  }
}
