import { Book, BookChapter, BookSource } from '../../model/data/Book';

/**
 * Reader content is returned exactly as produced by the imported source rules. The application
 * does not identify a publisher, append a private comment service, or add platform credentials.
 * Generic HTML/content normalization remains in WebBookService.
 */
export class BookSourceInteractionPostProcessor {
  static shouldRequestParagraphComments(source: BookSource, chapter?: BookChapter): boolean {
    return false;
  }

  static shouldRequestGodComments(source: BookSource, chapter?: BookChapter): boolean {
    return false;
  }

  static interactionCacheIdentity(source: BookSource): string {
    return '';
  }

  static async process(source: BookSource, book: Book | null, chapter: BookChapter,
    content: string): Promise<string> {
    return content || '';
  }
}
