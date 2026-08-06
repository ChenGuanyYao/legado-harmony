import { Book, BookChapter, BookSource } from '../../model/data/Book';

export class RuleExecutionPriority {
  static readonly BACKGROUND: number = 0;
  static readonly PRELOAD: number = 1;
  static readonly VISIBLE: number = 2;
  static readonly INTERACTIVE: number = 3;
}

export class RuleFieldRequest {
  name: string = '';
  rule: string = '';
  resolveUrl: boolean = false;
  listResult: boolean = false;

  constructor(name: string = '', rule: string = '', resolveUrl: boolean = false,
    listResult: boolean = false) {
    this.name = name;
    this.rule = rule;
    this.resolveUrl = resolveUrl;
    this.listResult = listResult;
  }
}

export class RuleBatchExecutionRequest {
  source: BookSource = new BookSource();
  book: Book | null = null;
  chapter: BookChapter | null = null;
  stage: string = '';
  ownerId: string = '';
  contents: string[] = [];
  baseUrl: string = '';
  fields: RuleFieldRequest[] = [];
  contextValues: Record<string, string> = {};
  priority: number = RuleExecutionPriority.VISIBLE;
  timeoutMs: number = 15000;
  uiSliceMs: number = 6;
  readerActionMode: boolean = false;
}

export class RuleBatchExecutionResult {
  values: Record<string, string>[] = [];
  contextValues: string[] = [];
  errors: string[] = [];
  elapsedMs: number = 0;
  yieldedCount: number = 0;
  cancelled: boolean = false;
}
