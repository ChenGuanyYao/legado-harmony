import { BookSource, SearchBook } from '../../model/data/Book';
import { appDb } from '../../model/data/AppDatabase';
import { HttpClient, HttpResponse } from '../http/HttpClient';
import { AnalyzeUrl } from '../rule/AnalyzeUrl';
import { AnalyzeRule } from '../rule/AnalyzeRule';
import { RuleContext } from '../rule/RuleContext';
import { ScriptCompatibility } from '../rule/ScriptCompatibility';
import { JsRuntime } from '../rule/JsRuntime';
import { VerificationSupport } from '../http/VerificationSupport';
import { EncodedSourceUrl } from './EncodedSourceUrl';
import { BookSourceDataUrlSupport } from './BookSourceDataUrlSupport';
import { BookUrlResolver } from './BookUrlResolver';
import { BookFieldSanitizer } from '../../utils/BookFieldSanitizer';
import { BookSourceMetadataSupport } from './BookSourceMetadataSupport';
import { BookSourceRuntimeRouter, SourceRuntimeStage } from './BookSourceRuntimeRouter';
import { BookSourceStageWebRuntime, StageWebRuntimeRequest } from './BookSourceStageWebRuntime';
import { BookSourceStageRuleSupport } from './BookSourceStageRuleSupport';
import { RuleExecutionService } from '../rule/RuleExecutionService';
import { RuleBatchExecutionRequest, RuleFieldRequest } from '../rule/RuleExecutionModels';
import { CooperativeScheduler } from '../concurrency/CooperativeScheduler';

export interface SearchProgress {
  done: number;
  total: number;
  results: SearchBook[];
  deltaResults?: SearchBook[];
  finished: boolean;
  status: string;
  needVerification?: boolean;
  verificationUrl?: string;
  verificationTitle?: string;
}

export type SearchCallback = (progress: SearchProgress) => void;

export interface SearchSourceResult {
  books: SearchBook[];
  validationStatus: number;
  reason: string;
}

const MAX_SEARCH_CONCURRENCY = 12;
const MAX_VALIDATION_CONCURRENCY = 1;
// Batch source results so background searching does not continuously interrupt list gestures.
const SEARCH_PROGRESS_EMIT_INTERVAL_MS = 500;
const MAX_SEARCH_RESPONSE_BYTES = 2 * 1024 * 1024;
const MAX_VALIDATION_RESPONSE_BYTES = 512 * 1024;
const MAX_VALIDATION_STAGE_RESPONSE_BYTES = 512 * 1024;
const MAX_VALIDATION_STAGE_TOTAL_RESPONSE_BYTES = 2 * 1024 * 1024;
const MAX_RESULTS_PER_SOURCE = 30;
const MAX_TOTAL_SEARCH_RESULTS = 300;
const MAX_VALIDATION_RULE_CHARS = 32 * 1024;
// Keep preflight validation aligned with ScriptEngine's executable script ceiling. Aggregated
// sources commonly share a 100-300 KiB jsLib even when each search rule itself remains small.
const MAX_VALIDATION_CONFIG_CHARS = 512 * 1024;
const ENABLE_SEARCH_DEBUG_LOG = false;

export interface SearchOptions {
  exactMatch?: boolean;
  exactMatchAuthor?: boolean;
  sourceGroups?: string[];
  targetSources?: BookSource[];
  onSourceComplete?: (source: BookSource, result: SearchSourceResult) => Promise<void>;
  validationOnly?: boolean;
  leanResult?: boolean;
  excludeSourceUrls?: string[];
  maxResultsPerSource?: number;
  maxTotalResults?: number;
  stopAfterResults?: number;
  maxCandidatesPerSource?: number;
}

interface ScoredSearchBook {
  book: SearchBook;
  index: number;
  score: number;
}

export class SearchCoordinator {
  private static stageRuntimeOwnerSerial: number = 0;
  private http: HttpClient;
  private concurrency: number;
  private cancelled: boolean = false;
  private stageRuntimeOwnerId: string = '';
  private lastFailureReason: string = '';

  getLastFailureReason(): string {
    return this.lastFailureReason;
  }

  constructor(concurrency: number = 8) {
    this.http = new HttpClient(8000);
    this.concurrency = Math.max(1, Math.min(Math.floor(concurrency), MAX_SEARCH_CONCURRENCY));
  }

  cancel(): void {
    this.cancelled = true;
    this.http.cancelAll();
    if (this.stageRuntimeOwnerId) {
      RuleExecutionService.get().cancelOwner(this.stageRuntimeOwnerId);
    }
  }

  async search(keyword: string, callback: SearchCallback, options: SearchOptions = {}): Promise<SearchBook[]> {
    this.cancelled = false;
    this.lastFailureReason = '';
    VerificationSupport.clearVerification();
    const safeCallback = (progress: SearchProgress): void => {
      try {
        callback(progress);
      } catch (e) {
        console.error('[SC] search progress callback failed:', e);
      }
    };
    let enabledSources: BookSource[];
    if (options.targetSources && options.targetSources.length > 0) {
      enabledSources = options.targetSources.slice();
    } else {
      enabledSources = await appDb.getEnabledBookSourcesForSearch();
    }
    const selectedGroups = this.normalizeSelectedGroups(options.sourceGroups || []);
    const groupedSources = selectedGroups.length > 0 ?
      enabledSources.filter((source: BookSource) => selectedGroups.includes(this.normalizeGroupName(source.bookSourceGroup))) :
      enabledSources;
    const excludedSourceUrls = new Set<string>((options.excludeSourceUrls || [])
      .map((value: string): string => (value || '').trim()).filter((value: string): boolean => !!value));
    const sources = excludedSourceUrls.size > 0 ?
      groupedSources.filter((source: BookSource): boolean => !excludedSourceUrls.has(source.bookSourceUrl || '')) :
      groupedSources;
    if (sources.length === 0) {
      safeCallback({ done: 0, total: 0, results: [], finished: true, status: '没有符合设置的启用书源' });
      return [];
    }
    const runtimeOwnerId = `search_${Date.now()}_${++SearchCoordinator.stageRuntimeOwnerSerial}`;
    this.stageRuntimeOwnerId = runtimeOwnerId;

    const all: SearchBook[] = [];
    let displayResultCount = 0;
    let done = 0;
    let nextIndex = 0;
    let lastProgressEmitAt = 0;
    let currentSourceLabel = '';
    let pendingDeltaResults: SearchBook[] = [];
    const validationOnly = options.validationOnly === true;
    const totalResultLimit = validationOnly ? 0 : this.normalizedLimit(options.maxTotalResults,
      MAX_TOTAL_SEARCH_RESULTS, 1, MAX_TOTAL_SEARCH_RESULTS);
    const stopAfterResults = validationOnly ? 0 : this.normalizedLimit(options.stopAfterResults,
      totalResultLimit, 1, totalResultLimit);
    const effectiveConcurrency = validationOnly ? Math.min(this.concurrency, MAX_VALIDATION_CONCURRENCY) : this.concurrency;
    const workerCount = Math.min(effectiveConcurrency, sources.length);

    const emitProgress = (force: boolean = false): void => {
      const now = Date.now();
      if (!force && done < sources.length && now - lastProgressEmitAt < SEARCH_PROGRESS_EMIT_INTERVAL_MS) {
        return;
      }
      lastProgressEmitAt = now;
      const verifyUrl = AppStorage.get<string>('pendingVerificationUrl') || '';
      const finished = force || done >= sources.length;
      const deltaResults = finished ? [] : pendingDeltaResults;
      pendingDeltaResults = [];
      safeCallback({
        done: done, total: sources.length,
        results: finished && !validationOnly ? this.filterAndSortSearchResults(all, keyword, options) : [],
        deltaResults: validationOnly ? [] : deltaResults,
        finished: finished,
        status: verifyUrl ?
          `已搜索 ${done}/${sources.length}，当前：${currentSourceLabel || '准备中'}，找到 ${displayResultCount} 本；有书源需要网页验证` :
          `已搜索 ${done}/${sources.length}，当前：${currentSourceLabel || '准备中'}，找到 ${displayResultCount} 本`,
        needVerification: verifyUrl.length > 0,
        verificationUrl: verifyUrl,
        verificationTitle: AppStorage.get<string>('pendingVerificationTitle') || '网页验证'
      });
    };

    const runWorker = async (): Promise<void> => {
      while (!this.cancelled) {
        if (!validationOnly && stopAfterResults > 0 && all.length >= stopAfterResults) break;
        const sourceIndex = nextIndex;
        nextIndex++;
        if (sourceIndex >= sources.length) break;

        currentSourceLabel = sources[sourceIndex].bookSourceName || `书源 ${sourceIndex + 1}`;
        AppStorage.setOrCreate('searchLastSource', currentSourceLabel);
        AppStorage.setOrCreate('searchLastSourceIndex', sourceIndex + 1);
        const sourceResult = await this.searchOne(sources[sourceIndex], keyword, options);
        if (sourceResult.books.length === 0 && sourceResult.reason && sourceResult.reason !== '未搜索到结果') {
          this.lastFailureReason = `${sources[sourceIndex].bookSourceName || '书源'}：${sourceResult.reason}`;
        }
        const books = sourceResult.books;
        if (this.cancelled) break;
        if (options.onSourceComplete) {
          try {
            await options.onSourceComplete(sources[sourceIndex], sourceResult);
          } catch (e) {
            console.error('[SC] source completion callback failed:', e);
          }
        }
        const remainingCapacity = Math.max(0, totalResultLimit - all.length);
        const acceptedBooks = validationOnly ? [] : books.slice(0, remainingCapacity);
        const displayBooks = this.filterSearchResults(acceptedBooks, keyword, options);

        done++;
        displayResultCount += displayBooks.length;
        if (!validationOnly) {
          pendingDeltaResults.push(...displayBooks);
          all.push(...acceptedBooks);
        }
        emitProgress();
      }
    };

    const workers: Promise<void>[] = [];
    for (let i = 0; i < workerCount; i++) {
      workers.push(runWorker());
    }
    try {
      await Promise.all(workers);
      emitProgress(true);
      return validationOnly ? [] : this.filterAndSortSearchResults(all, keyword, options);
    } finally {
      RuleExecutionService.get().clearOwner(runtimeOwnerId);
      if (this.stageRuntimeOwnerId === runtimeOwnerId) this.stageRuntimeOwnerId = '';
    }
  }

  private async searchOne(source: BookSource, keyword: string, options: SearchOptions): Promise<SearchSourceResult> {
    try {
      if (this.cancelled) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
      }
      if (options.validationOnly === true) {
        const compatibilityIssue = this.validationCompatibilityIssue(source);
        if (compatibilityIssue) {
          AppStorage.setOrCreate('searchLastSourceError',
            `${source.bookSourceName || source.bookSourceUrl}: ${compatibilityIssue}`);
          console.warn('[SC] skip unsafe validation source:', source.bookSourceName, compatibilityIssue);
          return this.sourceResult([], BookSource.VALIDATION_FAILED, compatibilityIssue);
        }
      }
      const responseLimit = options.validationOnly === true ?
        MAX_VALIDATION_RESPONSE_BYTES : MAX_SEARCH_RESPONSE_BYTES;
      const resultLimit = options.validationOnly === true ? 1 : this.normalizedLimit(options.maxResultsPerSource,
        MAX_RESULTS_PER_SOURCE, 1, MAX_RESULTS_PER_SOURCE);
      if (this.cancelled) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
      }
      if (!source.searchUrl || !source.searchRule?.bookList || !source.searchRule?.name || !source.searchRule?.bookUrl) {
        if (ENABLE_SEARCH_DEBUG_LOG) {
          console.warn('[SC] skip source without search rules:', source.bookSourceName);
        }
        return this.sourceResult([], BookSource.VALIDATION_FAILED, '缺少搜索地址或必要搜索规则');
      }
      const js = new JsRuntime();
      js.setVar('key', encodeURIComponent(keyword));
      js.setVar('searchKey', encodeURIComponent(keyword));
      js.setVar('keyword', encodeURIComponent(keyword));
      js.setVar('searchKeyRaw', keyword);
      js.setVar('page', '1');

      const au = new AnalyzeUrl(source, this.http);
      let urlTemplate = await this.evalAndBuild(js, source, keyword, responseLimit,
        options.validationOnly === true);
      if (!urlTemplate) {
        return this.sourceResult([], BookSource.VALIDATION_FAILED, '搜索地址无法解析');
      }
      if (ENABLE_SEARCH_DEBUG_LOG) {
        console.log('[SC] search source:', source.bookSourceName, 'url:', urlTemplate);
      }
      const resp = EncodedSourceUrl.canHandle(urlTemplate) ?
        await this.fetchEncodedDataUrl(urlTemplate, source, responseLimit) : await au.fetch(urlTemplate, responseLimit);
      if (this.cancelled) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
      }

      if (ENABLE_SEARCH_DEBUG_LOG) {
        console.log('[SC] response:', source.bookSourceName, resp.statusCode, 'len:', resp.body?.length || 0);
      }
      if (VerificationSupport.shouldRequestBrowserVerification(source, resp.body, resp.statusCode, source.searchUrl)) {
        const verifyUrl = VerificationSupport.pickVerificationUrl(source, urlTemplate, source.searchUrl);
        VerificationSupport.requestVerification(verifyUrl, `${source.bookSourceName} 验证`, source);
        if (ENABLE_SEARCH_DEBUG_LOG) {
          console.warn('[SC] source needs browser verification:', source.bookSourceName, verifyUrl);
        }
        return this.sourceResult([], BookSource.VALIDATION_NEEDS_VERIFICATION, '需要登录或网页验证');
      }
      if (!resp.success) {
        return this.validationHttpFailure(resp);
      }
      if (!resp.body) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '服务器返回空响应');
      }

      const baseUrl = BookUrlResolver.effectiveBase(resp, urlTemplate, source.bookSourceUrl);
      const rule = new AnalyzeRule(resp.body, baseUrl);
      this.seedSourceVariables(rule.getContext(), source);
      const encodedVariables = EncodedSourceUrl.scalarVariables(urlTemplate);
      for (const key in encodedVariables) rule.getContext().put(key, encodedVariables[key]);
      rule.setJsVar('key', encodeURIComponent(keyword));
      rule.setJsVar('searchKey', encodeURIComponent(keyword));
      rule.setJsVar('keyword', encodeURIComponent(keyword));
      rule.setJsVar('page', '1');
      const searchRule = source.searchRule;
      const stageItems = await BookSourceStageRuleSupport.getElements(source, resp.body, baseUrl,
        searchRule.bookList || '', SourceRuntimeStage.SEARCH, this.stageRuntimeOwnerId,
        options.validationOnly === true ? MAX_VALIDATION_STAGE_RESPONSE_BYTES : 8 * 1024 * 1024,
        options.validationOnly === true ? MAX_VALIDATION_STAGE_TOTAL_RESPONSE_BYTES : 16 * 1024 * 1024,
        encodedVariables);
      if (this.cancelled) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
      }
      const allItems = stageItems === null ? rule.getElements(searchRule.bookList || '') : stageItems;
      const candidateLimit = this.normalizedLimit(options.maxCandidatesPerSource,
        options.leanResult === true ? 60 : 120, 1, 200);
      const items = allItems.length > candidateLimit ? allItems.slice(0, candidateLimit) : allItems;
      if (this.cancelled) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
      }
      if (ENABLE_SEARCH_DEBUG_LOG) {
        console.log('[SC] parsed list:', source.bookSourceName, 'rule:', searchRule.bookList, 'count:', items.length);
      }

      const books: SearchBook[] = [];
      const seenBookKeys = new Set<string>();
      const normalizedKeyword = this.normalizeSearchText(keyword);
      const sourceBackendHost = BookSourceDataUrlSupport.sourceBackendHost(source);
      const fieldRequest = new RuleBatchExecutionRequest();
      fieldRequest.source = source;
      fieldRequest.stage = SourceRuntimeStage.SEARCH;
      fieldRequest.ownerId = this.stageRuntimeOwnerId;
      fieldRequest.contents = items;
      fieldRequest.baseUrl = baseUrl || source.bookSourceUrl;
      fieldRequest.fields = [
        new RuleFieldRequest('name', searchRule.name || ''),
        new RuleFieldRequest('author', searchRule.author || ''),
        new RuleFieldRequest('bookUrl', searchRule.bookUrl || '')
      ];
      if (!options.leanResult) {
        fieldRequest.fields.push(new RuleFieldRequest('coverUrl', searchRule.coverUrl || ''));
        fieldRequest.fields.push(new RuleFieldRequest('intro', searchRule.intro || ''));
        fieldRequest.fields.push(new RuleFieldRequest('kind', searchRule.kind || ''));
        fieldRequest.fields.push(new RuleFieldRequest('lastChapter', searchRule.lastChapter || ''));
        fieldRequest.fields.push(new RuleFieldRequest('wordCount', searchRule.wordCount || ''));
      }
      if (sourceBackendHost) {
        fieldRequest.contextValues['host'] = sourceBackendHost;
        fieldRequest.contextValues['backend'] = sourceBackendHost;
      }
      for (const key in encodedVariables) fieldRequest.contextValues[key] = encodedVariables[key];
      fieldRequest.timeoutMs = options.validationOnly === true ? 15000 : 30000;
      const fieldBatch = await RuleExecutionService.get().executeBatch(fieldRequest);
      if (fieldBatch.cancelled || this.cancelled) {
        return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
      }
      if (fieldBatch.errors.length > 0) {
        console.warn('[SC] unified field errors:', source.bookSourceName, fieldBatch.errors.join('; '));
      }
      const parsingSlice = CooperativeScheduler.createTimeSlice();
      for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
        // Parsing a large response used to keep every result-field rule in one native callback. Even individually
        // fast selectors could then accumulate past HarmonyOS' 3-second foreground freeze threshold.
        if (itemIndex > 0) await parsingSlice.checkpoint();
        const item = items[itemIndex];
        if (this.cancelled) {
          return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, '校验已取消');
        }
        const ir = new AnalyzeRule(item, baseUrl);
        this.seedSourceVariables(ir.getContext(), source);
        if (sourceBackendHost) {
          ir.getContext().put('host', sourceBackendHost);
          ir.getContext().put('backend', sourceBackendHost);
        }
        const book = new SearchBook();
        const fieldValues = itemIndex < fieldBatch.values.length ? fieldBatch.values[itemIndex] : {};
        book.name = fieldValues['name'] || '';
        book.author = fieldValues['author'] || '';
        const sourceApiRecord = this.parseJsonRecord(item);
        if (sourceApiRecord) {
          if (!book.name) book.name = String(sourceApiRecord['name'] || sourceApiRecord['bookName'] ||
            sourceApiRecord['title'] || '');
          if (!book.author) book.author = String(sourceApiRecord['author'] || sourceApiRecord['writer'] || '');
        }
        book.bookUrl = BookUrlResolver.resolve(fieldValues['bookUrl'] || '', baseUrl);
        this.fillSearchFallbackFields(source, ir, book, baseUrl, item);
        if (options.exactMatch) {
          if (!this.matchesExactSearch(this.normalizeSearchText(book.name), this.normalizeSearchText(book.author),
            normalizedKeyword, options)) {
            continue;
          }
        }

        book.coverUrl = BookSourceDataUrlSupport.normalizeCoverUrlFromItem(source,
          fieldValues['coverUrl'] || '', item, baseUrl);
        book.intro = fieldValues['intro'] || '';
        book.kind = fieldValues['kind'] || '';
        book.latestChapterTitle = fieldValues['lastChapter'] || '';
        book.wordCount = fieldValues['wordCount'] || '';
        if (sourceApiRecord) {
          if (!book.coverUrl) book.coverUrl = String(sourceApiRecord['cover'] || sourceApiRecord['coverUrl'] || '');
          if (!book.intro) book.intro = String(sourceApiRecord['desc'] || sourceApiRecord['intro'] ||
            sourceApiRecord['description'] || '');
          if (!book.latestChapterTitle) book.latestChapterTitle = String(sourceApiRecord['lastChapter'] ||
            sourceApiRecord['latestChapterTitle'] || '');
          if (!book.wordCount) book.wordCount = String(sourceApiRecord['wordsCount'] ||
            sourceApiRecord['wordCount'] || '');
          if (!book.kind) {
            book.kind = [sourceApiRecord['status'], sourceApiRecord['category'], sourceApiRecord['subCategory']]
              .map((value: Object): string => String(value || '').trim()).filter((value: string): boolean => !!value)
              .join(' ');
          }
        }
        book.variable = itemIndex < fieldBatch.contextValues.length ? fieldBatch.contextValues[itemIndex] :
          ir.getContext().toPersistentJson();
        // 如果解析后仍含 JSONPath 表达式，直接从 item 提取
        if (!book.bookUrl || book.bookUrl.startsWith('$') || book.bookUrl.includes('$._id') || book.bookUrl.includes('$..')) {
          // 尝试常见字段
          book.bookUrl = ir.analyzeFirst('bookUrl') || ir.analyzeFirst('url') || ir.analyzeFirst('link') ||
            ir.analyzeFirst('_id') || ir.analyzeFirst('id') || ir.analyzeFirst('nid') || ir.analyzeFirst('enid') || '';
          // 如果还是路径表达式，直接从原始 JSON 提取
          if (book.bookUrl && (book.bookUrl.startsWith('$') || book.bookUrl.includes('$..'))) {
            try {
              const raw = JSON.parse(item) as Record<string, Object>;
              book.bookUrl = String(raw['url'] || raw['bookUrl'] || raw['link'] || raw['href'] || raw['nid'] || '');
            } catch (_) {}
          }
          book.bookUrl = BookUrlResolver.resolve(book.bookUrl, baseUrl);
        }
        if (!book.bookUrl || /["']\s*\+\s*result|\bresult\s*\+\s*["']|@js:/.test(book.bookUrl) ||
          (/result/.test(searchRule.bookUrl || '') && /\+/.test(searchRule.bookUrl || ''))) {
          const repaired = this.repairResultConcatUrl(searchRule.bookUrl || '', ir, baseUrl);
          if (repaired) book.bookUrl = repaired;
        }
        const searchBookId = this.extractBookId(ir, item, book.bookUrl);
        const responseCoverUrl = BookSourceDataUrlSupport.normalizeCoverUrlFromResponse(source, resp.body, searchBookId,
          baseUrl);
        if (responseCoverUrl && this.shouldReplaceCover(book.coverUrl)) {
          book.coverUrl = responseCoverUrl;
          if (ENABLE_SEARCH_DEBUG_LOG) {
            console.log('[SC] cover from response:', source.bookSourceName, book.name, searchBookId);
          }
        }
        book.origin = source.bookSourceUrl;
        BookSourceMetadataSupport.applySearchBook(source, book, [book.bookUrl]);
        book.bookSourceComment = source.bookSourceComment;
        book.customOrder = source.customOrder;
        book.weight = source.weight;

        if (options.leanResult) this.stripLeanFieldValues(book);
        this.sanitizeSearchBook(book);
        const bookKey = `${book.origin || ''}::${book.bookUrl || ''}`;
        if (book.name && book.bookUrl && !seenBookKeys.has(bookKey)) {
          seenBookKeys.add(bookKey);
          if (ENABLE_SEARCH_DEBUG_LOG && books.length === 0) {
            console.log('[SC] 第一条结果:', book.name, book.bookUrl, 'from:', source.bookSourceName);
          }
          books.push(book);
          if (books.length >= resultLimit) {
            break;
          }
        }
      }
      if (books.length === 0 && items.length > 0) {
        if (ENABLE_SEARCH_DEBUG_LOG) {
          console.warn('[SC] list matched but no valid book:', source.bookSourceName,
            'nameRule:', searchRule.name, 'urlRule:', searchRule.bookUrl,
            'firstItem:', items[0].substring(0, Math.min(items[0].length, 240)));
        }
      }
      if (books.length > 0) {
        return this.sourceResult(books, BookSource.VALIDATION_PASSED, '');
      }
      if (items.length > 0) {
        return this.sourceResult([], BookSource.VALIDATION_FAILED, '搜索规则未能解析出有效书名和详情地址');
      }
      return this.sourceResult([], BookSource.VALIDATION_NO_RESULTS, '未搜索到结果');
    } catch (e) {
      if (ENABLE_SEARCH_DEBUG_LOG) {
        console.error('[SC] search failed:', source.bookSourceName, e);
      }
      const reason = e instanceof Error ? e.message : String(e);
      return this.sourceResult([], this.isExplicitRuleError(reason) ?
        BookSource.VALIDATION_FAILED : BookSource.VALIDATION_TEMPORARY_ERROR,
      reason || '搜索过程中发生异常');
    }
  }

  private sourceResult(books: SearchBook[], validationStatus: number, reason: string): SearchSourceResult {
    return {
      books: books,
      validationStatus: validationStatus,
      reason: reason
    };
  }

  private pendingVerificationMatchesSource(source: BookSource): boolean {
    return (AppStorage.get<string>('pendingVerificationSourceUrl') || '') === source.bookSourceUrl;
  }

  private validationHttpFailure(response: HttpResponse): SearchSourceResult {
    const statusCode = response.statusCode;
    if (statusCode === 401 || statusCode === 403) {
      return this.sourceResult([], BookSource.VALIDATION_NEEDS_VERIFICATION,
        `请求需要身份验证（HTTP ${statusCode}）`);
    }
    if (statusCode === 408 || statusCode === 425 || statusCode === 429 || statusCode >= 500 ||
      statusCode === 0 || (response.error || '').includes('response too large')) {
      const reason = statusCode > 0 ? `服务器暂时异常（HTTP ${statusCode}）` :
        (response.error || '网络请求失败');
      return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR, reason);
    }
    if ((statusCode >= 300 && statusCode < 400) || (statusCode >= 400 && statusCode < 500)) {
      return this.sourceResult([], BookSource.VALIDATION_FAILED, `搜索请求错误（HTTP ${statusCode}）`);
    }
    return this.sourceResult([], BookSource.VALIDATION_TEMPORARY_ERROR,
      response.error || '搜索请求暂时异常');
  }

  private isExplicitRuleError(reason: string): boolean {
    return /(?:rule|规则|selector|选择器|xpath|jsonpath|regexp|regex|regular expression|正则|syntax|语法|parse error|解析错误)/i
      .test(reason || '');
  }

  private validationCompatibilityIssue(source: BookSource): string {
    const searchRule = source.searchRule;
    const executableRules = [
      source.searchUrl || '',
      searchRule?.bookList || '',
      searchRule?.name || '',
      searchRule?.author || '',
      searchRule?.bookUrl || '',
      searchRule?.coverUrl || '',
      searchRule?.intro || '',
      searchRule?.kind || '',
      searchRule?.lastChapter || ''
    ];
    for (const rule of executableRules) {
      if (rule.length > MAX_VALIDATION_RULE_CHARS) return '搜索规则过大';
    }
    const executable = executableRules.join('\n');
    const hostCode = [source.jsLib || '', executable].join('\n');
    if (hostCode.length > MAX_VALIDATION_CONFIG_CHARS) return '书源脚本配置过大';
    const usesScript = /(?:@js:|<js>|\bjava\.|\bsource\.|\bcache\.)/i.test(executable);
    const routed = BookSourceRuntimeRouter.decide(SourceRuntimeStage.SEARCH, hostCode);
    const unsupportedScript = usesScript && routed.runtime !== 'arkweb' ? ScriptCompatibility.unsupportedReason(hostCode) : '';
    if (unsupportedScript) return unsupportedScript;
    if (this.containsRiskyNestedQuantifier(executable)) return '包含高风险嵌套正则';
    return '';
  }

  private containsRiskyNestedQuantifier(value: string): boolean {
    const candidates = (value || '').match(/\/(?:\\.|[^/\r\n]){1,300}\/[gimsuy]*/g) || [];
    for (const candidate of candidates) {
      const body = candidate.replace(/^\/|\/[gimsuy]*$/g, '');
      if (/\((?:\\.|[^()]){0,200}(?:\.\*|\.\+|[^\\][+*])(?:\\.|[^()]){0,200}\)\s*(?:[+*]|\{\d*,?\d*\})/
        .test(body)) {
        return true;
      }
    }
    return false;
  }

  private sortSearchResults(results: SearchBook[], keyword: string): SearchBook[] {
    const normalizedKeyword = this.normalizeSearchText(keyword);
    if (!normalizedKeyword) return [...results];
    const scored: ScoredSearchBook[] = results.map((book: SearchBook, index: number): ScoredSearchBook => {
      return {
        book: book,
        index: index,
        score: this.searchRelevanceScore(book, normalizedKeyword)
      };
    });
    scored.sort((a: ScoredSearchBook, b: ScoredSearchBook): number => {
      const scoreDiff = b.score - a.score;
      if (scoreDiff !== 0) return scoreDiff;
      const weightDiff = (b.book.weight || 0) - (a.book.weight || 0);
      if (weightDiff !== 0) return weightDiff;
      const orderDiff = (a.book.customOrder || 0) - (b.book.customOrder || 0);
      if (orderDiff !== 0) return orderDiff;
      return a.index - b.index;
    });
    return scored.map((item: ScoredSearchBook): SearchBook => item.book);
  }

  private sanitizeSearchBook(book: SearchBook): void {
    book.name = this.cleanTextField(book.name, 120);
    book.author = this.cleanTextField(book.author, 120);
    book.kind = this.cleanTextField(book.kind, 240);
    book.intro = this.cleanTextField(book.intro, 1200);
    book.latestChapterTitle = this.cleanTextField(book.latestChapterTitle, 160);
    book.wordCount = this.cleanTextField(book.wordCount, 80);
    book.bookUrl = this.cleanUrlField(book.bookUrl, 2048);
    book.tocUrl = this.cleanUrlField(book.tocUrl, 2048);
    book.coverUrl = this.cleanUrlField(book.coverUrl, 4096);
    book.origin = this.cleanUrlField(book.origin, 2048);
    book.originName = this.cleanTextField(book.originName, 160);
    book.bookSourceComment = this.cleanTextField(book.bookSourceComment, 1200);
    book.variable = this.cleanJsonField(book.variable, 8192);
  }

  private sanitizeSearchBooks(books: SearchBook[], limit: number, leanResult: boolean = false): SearchBook[] {
    const cleaned: SearchBook[] = [];
    const seen = new Set<string>();
    for (const book of books || []) {
      if (leanResult) this.stripLeanFieldValues(book);
      this.sanitizeSearchBook(book);
      if (!book.name || !book.bookUrl) continue;
      const key = `${book.origin || ''}::${book.bookUrl || ''}`;
      if (seen.has(key)) continue;
      seen.add(key);
      cleaned.push(book);
      if (cleaned.length >= limit) break;
    }
    return cleaned;
  }

  private stripLeanFields(books: SearchBook[]): void {
    for (const book of books) this.stripLeanFieldValues(book);
  }

  private stripLeanFieldValues(book: SearchBook): void {
    book.coverUrl = '';
    book.intro = '';
    book.kind = '';
    book.latestChapterTitle = '';
    book.wordCount = '';
    book.bookSourceComment = '';
  }

  private normalizedLimit(value: number | undefined, fallback: number, minimum: number, maximum: number): number {
    if (value === undefined || value === null || !Number.isFinite(value)) return fallback;
    return Math.max(minimum, Math.min(Math.floor(value), maximum));
  }

  private fillSearchFallbackFields(source: BookSource, ir: AnalyzeRule, book: SearchBook, baseUrl: string,
    item: string): void {
    if (!book.name) {
      book.name = this.cleanFallbackTitle(ir.analyzeFirst('a@title') || ir.analyzeFirst('a@text') ||
        ir.analyzeFirst('span.sr-only@text') || ir.analyzeFirst('.sr-only@text'));
    }
    if (!book.bookUrl) {
      book.bookUrl = BookUrlResolver.resolve(ir.analyzeFirst('a@href') || ir.analyzeFirst('[href]@href'), baseUrl);
    }
  }

  private cleanFallbackTitle(value: string): string {
    return (value || '')
      .replace(/^复选框\s*/, '')
      .replace(/Html|PDF下载|评审材料/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  private cleanTextField(value: string, maxLength: number): string {
    const text = BookFieldSanitizer.clean(this.safeString(value));
    return text.length > maxLength ? text.substring(0, maxLength) : text;
  }

  private cleanUrlField(value: string, maxLength: number): string {
    const text = this.safeString(value).trim();
    if (!text || BookFieldSanitizer.isUnresolved(text)) return '';
    return text.length > maxLength ? text.substring(0, maxLength) : text;
  }

  private cleanJsonField(value: string, maxLength: number): string {
    const text = this.safeString(value).trim();
    return text.length > maxLength ? text.substring(0, maxLength) : text;
  }

  private safeString(value: Object | string | null | undefined): string {
    if (value === null || value === undefined) return '';
    if (typeof value === 'string') return value;
    if (typeof value === 'number' || typeof value === 'boolean') return String(value);
    try {
      return JSON.stringify(value);
    } catch (_) {
      return '';
    }
  }

  private repairResultConcatUrl(rule: string, ir: AnalyzeRule, baseUrl: string): string {
    const jsIndex = String(rule || '').indexOf('@js:');
    if (jsIndex < 0) return '';
    const baseExpr = String(rule || '').substring(0, jsIndex).trim();
    const jsExpr = String(rule || '').substring(jsIndex + 4).trim();
    const baseValue = ir.analyzeFirst(baseExpr);
    if (!baseValue) return '';
    const prefixMatch = jsExpr.match(/^["']([\s\S]*?)["']\s*\+\s*result(?:\s*\+\s*["']([\s\S]*?)["'])?$/);
    const suffixMatch = jsExpr.match(/^result\s*\+\s*["']([\s\S]*?)["']$/);
    const headMatch = jsExpr.match(/^["']([\s\S]*?)["']\s*\+\s*result$/);
    if (prefixMatch) return BookUrlResolver.resolve(prefixMatch[1] + baseValue + (prefixMatch[2] || ''), baseUrl);
    if (suffixMatch) return BookUrlResolver.resolve(baseValue + suffixMatch[1], baseUrl);
    if (headMatch) return BookUrlResolver.resolve(headMatch[1] + baseValue, baseUrl);
    return '';
  }

  private parseJsonRecord(value: string): Record<string, Object> | null {
    let current: Object;
    try {
      current = JSON.parse(value || '{}') as Object;
    } catch (_) {
      return null;
    }
    // Some full-JS list runtimes return each JSON object as a quoted JSON string.
    // Unwrap that representation so ordinary field rules and native API fallbacks
    // receive the same record shape as Legado's JavaScript runtime.
    for (let depth = 0; depth < 2 && typeof current === 'string'; depth++) {
      try {
        current = JSON.parse(current as string) as Object;
      } catch (_) {
        return null;
      }
    }
    if (!current || typeof current !== 'object' || Array.isArray(current)) return null;
    return current as Record<string, Object>;
  }

  private searchRelevanceScore(book: SearchBook, normalizedKeyword: string): number {
    let score = 0;
    score += this.fieldMatchScore(this.normalizeSearchText(book.name), normalizedKeyword, 1200, 900, 700, 240);
    score += this.fieldMatchScore(this.normalizeSearchText(book.author), normalizedKeyword, 260, 220, 180, 70);
    score += this.fieldMatchScore(this.normalizeSearchText(book.kind), normalizedKeyword, 90, 70, 50, 20);
    score += this.fieldMatchScore(this.normalizeSearchText(book.latestChapterTitle), normalizedKeyword, 50, 40, 30, 0);
    score += this.fieldMatchScore(this.normalizeSearchText(book.intro), normalizedKeyword, 40, 30, 20, 0);
    return score;
  }

  private fieldMatchScore(value: string, keyword: string, exactScore: number, startsScore: number,
    containsScore: number, looseScore: number): number {
    if (!value || !keyword) return 0;
    if (value === keyword) return exactScore;
    if (value.startsWith(keyword)) return startsScore + this.shortTextBonus(value, keyword);
    const index = value.indexOf(keyword);
    if (index >= 0) {
      return containsScore + Math.max(0, 80 - index) + this.shortTextBonus(value, keyword);
    }
    return this.looseKeywordScore(value, keyword, looseScore);
  }

  private shortTextBonus(value: string, keyword: string): number {
    return Math.max(0, Math.min(80, 80 - Math.max(0, value.length - keyword.length) * 4));
  }

  private looseKeywordScore(value: string, keyword: string, maxScore: number): number {
    if (keyword.length <= 1 || maxScore <= 0) return 0;
    let hitCount = 0;
    for (let i = 0; i < keyword.length; i++) {
      if (value.includes(keyword.charAt(i))) hitCount++;
    }
    const ratio = hitCount / keyword.length;
    if (ratio >= 0.8) return Math.floor(maxScore * ratio);
    if (ratio >= 0.5) return Math.floor(maxScore * ratio * 0.5);
    return 0;
  }

  private normalizeSearchText(value: string): string {
    return (value || '').trim().toLowerCase()
      .replace(/\s+/g, '')
      .replace(/[《》【】\[\]（）()「」『』"“”'‘’.,，。:：;；!！?？、·_\-]/g, '');
  }

  private filterAndSortSearchResults(results: SearchBook[], keyword: string, options: SearchOptions): SearchBook[] {
    const sorted = this.sortSearchResults(this.filterSearchResults(results, keyword, options), keyword);
    return sorted;
  }

  private filterSearchResults(results: SearchBook[], keyword: string, options: SearchOptions): SearchBook[] {
    if (!options.exactMatch) {
      return results;
    }
    const normalizedKeyword = this.normalizeSearchText(keyword);
    return results.filter((book: SearchBook) => {
      if (this.normalizeSearchText(book.name) === normalizedKeyword) {
        return true;
      }
      return options.exactMatchAuthor === true &&
        this.normalizeSearchText(book.author) === normalizedKeyword;
    });
  }

  private matchesExactSearch(normalizedName: string, normalizedAuthor: string, normalizedKeyword: string,
    options: SearchOptions): boolean {
    if (normalizedName === normalizedKeyword) {
      return true;
    }
    return options.exactMatchAuthor === true && normalizedAuthor === normalizedKeyword;
  }

  private normalizeSelectedGroups(groups: string[]): string[] {
    const result: string[] = [];
    for (const group of groups) {
      const normalized = this.normalizeGroupName(group);
      if (normalized && !result.includes(normalized)) {
        result.push(normalized);
      }
    }
    return result;
  }

  private normalizeGroupName(group: string): string {
    const value = (group || '').trim();
    return value || '未分组';
  }

  private extractBookId(ir: AnalyzeRule, itemJson: string, bookUrl: string): string {
    const fromContext = ir.getContext().get('book_id') || ir.getContext().get('bookId') || ir.getContext().get('id');
    if (fromContext) return fromContext;
    const fromUrl = this.extractQueryValue(bookUrl, 'book_id') || this.extractQueryValue(bookUrl, 'bookId') ||
      this.extractQueryValue(bookUrl, 'bookid') || this.extractQueryValue(bookUrl, 'id');
    if (fromUrl) return fromUrl;
    try {
      const item = JSON.parse(itemJson || '{}') as Record<string, Object>;
      return String(item['book_id'] || item['bookId'] || item['id'] || '');
    } catch (_) {
      return '';
    }
  }

  private extractQueryValue(url: string, key: string): string {
    if (!url || !key) return '';
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = url.match(new RegExp(`[?&]${escaped}=([^&#]+)`, 'i'));
    return match && match[1] ? decodeURIComponent(match[1]) : '';
  }

  private shouldReplaceCover(url: string): boolean {
    const value = (url || '').trim().toLowerCase();
    return !value || value === 'thumb_url' || value === 'cover' || value === 'audio_thumb_uri' ||
      value.includes('{{') || value.includes('}}') || value.includes('$..') || value.includes('$.') ||
      value.includes('.heic') ||
      /\/(?:thumb_url|cover|audio_thumb_uri)$/.test(value);
  }

  private async evalAndBuild(js: JsRuntime, source: BookSource, keyword: string,
    maxResponseBytes: number, validationOnly: boolean): Promise<string> {
    const searchUrl = source.searchUrl;
    const baseUrl = source.bookSourceUrl;
    if (!searchUrl) return `${baseUrl}/search?q={{key}}`;
    const isFullJsSearchUrl = this.isFullJsUrl(searchUrl);
    // A plain URL whose template uses only built-in deterministic expressions does not need the
    // source's unrelated jsLib. Keeping it on the lightweight path avoids both semantic pollution
    // from top-level library state and unnecessary ArkWeb compilation.
    if (!isFullJsSearchUrl && this.isLightweightUrlTemplate(searchUrl)) {
      let lightweightUrl = this.applySourceTemplate(searchUrl, source);
      lightweightUrl = js.evalTemplate(lightweightUrl).replace(/\{\{[^}]+\}\}/g, '');
      if (lightweightUrl) return lightweightUrl;
    }
    const searchRuntimeDecision = BookSourceRuntimeRouter.decide(SourceRuntimeStage.SEARCH,
      `${source.jsLib || ''}\n${searchUrl}`);
    const requiresStageRuntime = isFullJsSearchUrl ||
      (searchUrl.includes('{{') && searchRuntimeDecision.runtime === 'arkweb');
    const stageUrl = await this.tryBuildStageRuntimeSearchUrl(source, keyword, validationOnly);
    if (stageUrl) return stageUrl;
    const scriptedFormUrl = await this.tryBuildScriptedFormSearchUrl(source, keyword, maxResponseBytes);
    if (scriptedFormUrl) return scriptedFormUrl;
    const buildRequestUrl = BookSourceDataUrlSupport.buildRequestUrl(source, searchUrl, '1', keyword);
    if (buildRequestUrl) return buildRequestUrl;
    // Complete or complex JavaScript URLs are never retried in the synchronous compatibility
    // interpreter. A failed ArkWeb execution should fail this source, not freeze the UI thread.
    if (requiresStageRuntime) return '';
    let url = searchUrl;
    url = this.stripLeadingJsUrl(url);
    if (url.startsWith('@js:')) {
      const assignMatch = url.match(/\burl\s*=\s*(["'])([\s\S]*?)\1\s*;/);
      if (assignMatch) {
        url = assignMatch[2];
      }
      const baseJoin = url.match(/baseUrl\s*\+\s*(".*?"|'.*?')/);
      if (baseJoin) {
        url = baseUrl + baseJoin[1].substring(1, baseJoin[1].length - 1);
        const optionMatch = searchUrl.match(/,\{[\s\S]*\}/);
        if (optionMatch && !url.includes(',{')) url += optionMatch[0];
      } else if (url.startsWith('@js:')) {
        const resultMatch = url.match(/result\s*=\s*["']([^"']+)["']/);
        const directUrlMatch = url.match(/["'](https?:\/\/[^"']+)["']/);
        const relativeOptionMatch = url.match(/["'](\/[^"']+,\{[\s\S]*?\})["']/);
        url = resultMatch ? resultMatch[1] : (relativeOptionMatch ? relativeOptionMatch[1] : (directUrlMatch ? directUrlMatch[1] : ''));
      }
    }
    url = this.applySourceTemplate(url, source);
    url = js.evalTemplate(url);
    // 清理残留模板
    url = url.replace(/\{\{[^}]+\}\}/g, '');
    return url;
  }

  private async tryBuildStageRuntimeSearchUrl(source: BookSource, keyword: string,
    validationOnly: boolean): Promise<string> {
    const rawSearchUrl = source.searchUrl || '';
    const isFullJsUrl = this.isFullJsUrl(rawSearchUrl);
    const hostCode = `${source.jsLib || ''}\n${source.searchUrl || ''}`;
    const decision = BookSourceRuntimeRouter.decide(SourceRuntimeStage.SEARCH, hostCode);
    if (!isFullJsUrl && decision.runtime !== 'arkweb') return '';
    const runtime = BookSourceStageWebRuntime.get();
    if (!runtime.isAvailable()) {
      const available = await runtime.waitUntilAvailable(5000);
      if (!available) return '';
    }
    const request = new StageWebRuntimeRequest();
    request.applyStageBudget(SourceRuntimeStage.SEARCH);
    request.source = source;
    request.baseUrl = source.bookSourceUrl;
    request.ownerId = this.stageRuntimeOwnerId;
    if (validationOnly) {
      request.maxResponseBytes = MAX_VALIDATION_STAGE_RESPONSE_BYTES;
      request.maxTotalResponseBytes = MAX_VALIDATION_STAGE_TOTAL_RESPONSE_BYTES;
    }
    request.variables = {
      key: isFullJsUrl ? keyword : encodeURIComponent(keyword),
      searchKey: isFullJsUrl ? keyword : encodeURIComponent(keyword),
      keyword: isFullJsUrl ? keyword : encodeURIComponent(keyword),
      searchKeyRaw: keyword,
      page: '1',
      pageIndex: '1'
    };
    if (isFullJsUrl) {
      // A full-JS URL must run as code. Treating it as a template returns the literal "@js:..."
      // text, so AnalyzeUrl never sees request options such as an Authorization header.
      request.code = this.unwrapFullJsUrl(rawSearchUrl);
    } else {
      const template = JSON.stringify(rawSearchUrl);
      request.code = `const __searchTemplate=${template};result=__searchTemplate.replace(/\\{\\{([\\s\\S]*?)\\}\\}/g,` +
        `function(_,expr){try{return String(eval(expr));}catch(e){return '';}});result;`;
    }
    try {
      const result = await runtime.execute(request);
      return result.value || '';
    } catch (error) {
      console.warn('[SC] stage runtime search URL failed:', source.bookSourceName, error);
      return '';
    }
  }

  private applySourceTemplate(url: string, source: BookSource): string {
    return (url || '')
      .replace(/\{\{\s*source\.bookSourceUrl\s*\}\}/g, source.bookSourceUrl || '')
      .replace(/\{\{\s*source\.bookSourceName\s*\}\}/g, source.bookSourceName || '')
      .replace(/\{\{\s*source\.bookSourceGroup\s*\}\}/g, source.bookSourceGroup || '');
  }

  private isFullJsUrl(value: string): boolean {
    const raw = (value || '').trim();
    return /^@?js:/i.test(raw) || /^<js>[\s\S]*<\/js>$/i.test(raw);
  }

  private unwrapFullJsUrl(value: string): string {
    return (value || '').trim()
      .replace(/^@?js:\s*/i, '')
      .replace(/^<js>\s*|\s*<\/js>$/gi, '');
  }

  private isLightweightUrlTemplate(value: string): boolean {
    const raw = value || '';
    if (!raw.includes('{{')) return true;
    const allowedCalls = [
      'Date.now', 'Math.round', 'Math.floor', 'Math.ceil', 'String',
      'encodeURIComponent', 'encodeURI', 'java.urlEncode', 'java.encodeURI',
      'java.base64Encode', 'java.base64EncodeToString', 'java.base64Decode',
      'java.base64DecodeToString', 'java.hexEncodeToString', 'java.hexDecodeToString'
    ];
    const expression = /\{\{([\s\S]*?)\}\}/g;
    let match: RegExpExecArray | null;
    while ((match = expression.exec(raw)) !== null) {
      const code = match[1] || '';
      if (/=>|\b(?:let|const|var|return|if|try|new)\b/.test(code)) return false;
      const call = /\b([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)\s*\(/g;
      let callMatch: RegExpExecArray | null;
      while ((callMatch = call.exec(code)) !== null) {
        if (!allowedCalls.includes(callMatch[1] || '')) return false;
      }
    }
    return true;
  }

  private seedSourceVariables(ctx: RuleContext, source: BookSource): void {
    ctx.put('source.bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('bookSourceUrl', source.bookSourceUrl || '');
    ctx.put('source.bookSourceName', source.bookSourceName || '');
    ctx.put('bookSourceName', source.bookSourceName || '');
    ctx.put('source.bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('bookSourceGroup', source.bookSourceGroup || '');
    ctx.put('source.bookSourceComment', source.bookSourceComment || '');
    ctx.put('bookSourceComment', source.bookSourceComment || '');
    ctx.put('source.jsLib', source.jsLib || '');
    ctx.put('jsLib', source.jsLib || '');
    if (!ctx.has('source.variable')) ctx.put('source.variable', source.variable || '');
  }

  private async tryBuildScriptedFormSearchUrl(source: BookSource, keyword: string,
    maxResponseBytes: number): Promise<string> {
    const script = source.searchUrl || '';
    if (!script.startsWith('@js:') || !script.includes('java.ajax') || !script.includes('input[name=act]')) {
      return '';
    }
    const baseUrl = BookUrlResolver.cleanBaseUrl(source.bookSourceUrl);
    const formBaseUrl = this.extractScriptBaseUrl(script, baseUrl);
    const appendPath = this.extractAppendedPath(script);
    if (!formBaseUrl || !appendPath) return '';

    const resp = await this.http.execute({
      url: formBaseUrl,
      method: 'GET',
      headers: this.parseSourceHeaders(source.header),
      maxResponseBytes: maxResponseBytes
    });
    if (!resp.success || !resp.body) return '';

    const act = this.extractInputValue(resp.body, 'act');
    if (!act) return '';
    const submit = /\/www/i.test(formBaseUrl) ? '搜索 ' : '快速搜书';
    const body = `act=${encodeURIComponent(act)}&q=${encodeURIComponent(keyword)}&submit=${encodeURIComponent(submit)}`;
    const targetUrl = BookUrlResolver.resolve(appendPath, formBaseUrl);
    const option = JSON.stringify({
      body: body,
      method: 'POST',
      charset: 'GBK',
      headers: { Referer: formBaseUrl }
    });
    return `${targetUrl},${option}`;
  }

  private extractScriptBaseUrl(script: string, fallbackUrl: string): string {
    if (script.includes('source.key') || script.includes('source.getKey()')) return fallbackUrl;
    const literalMatch = script.match(/\burl\s*=\s*["'](https?:\/\/[^"']+)["']/);
    if (literalMatch && literalMatch[1]) return literalMatch[1];
    if (script.includes('baseUrl')) return fallbackUrl;
    return fallbackUrl;
  }

  private extractAppendedPath(script: string): string {
    const appendMatch = script.match(/\burl\s*\+=\s*["']([^"']+)["']/);
    if (appendMatch && appendMatch[1]) return appendMatch[1];
    const pathMatch = script.match(/["'](\/[^"']*search[^"']*)["']/i) ||
      script.match(/["'](\/[^"']*ss[^"']*)["']/i);
    return pathMatch && pathMatch[1] ? pathMatch[1] : '';
  }

  private extractInputValue(html: string, name: string): string {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const nameFirst = new RegExp(`<input\\b[^>]*\\bname=["']${escaped}["'][^>]*\\bvalue=["']([^"']*)["'][^>]*>`, 'i');
    const valueFirst = new RegExp(`<input\\b[^>]*\\bvalue=["']([^"']*)["'][^>]*\\bname=["']${escaped}["'][^>]*>`, 'i');
    const match = html.match(nameFirst) || html.match(valueFirst);
    return match && match[1] ? match[1] : '';
  }

  private parseSourceHeaders(header: string): Record<string, string> {
    if (!header) return {};
    try {
      return JSON.parse(header.replace(/'/g, '"')) as Record<string, string>;
    } catch (_) {
      const result: Record<string, string> = {};
      for (const line of header.split(/[\n\r]+/)) {
        const idx = line.indexOf(':');
        if (idx > 0) result[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
      return result;
    }
  }

  private async fetchEncodedDataUrl(url: string, source: BookSource,
    maxResponseBytes: number): Promise<{ url: string, statusCode: number, headers: Record<string, string>, body: string, success: boolean, error?: string }> {
    const root = await EncodedSourceUrl.requestJsonForDataUrl(this.http, url, source, maxResponseBytes);
    if (!root) {
      return { url: url, statusCode: 0, headers: {}, body: '', success: false, error: 'encoded data url request failed' };
    }
    return { url: url, statusCode: 200, headers: {}, body: JSON.stringify(root), success: true };
  }

  private stripLeadingJsUrl(url: string): string {
    const end = url.lastIndexOf('</js>');
    if (end >= 0) {
      const tail = url.substring(end + 5).trim();
      if (tail) return tail;
      const head = url.substring(0, end);
      const pathWithOption = head.match(/(\/[^"'`;]+,\{[\s\S]*?\})/);
      if (pathWithOption) return pathWithOption[1];
      const path = head.match(/(\/[A-Za-z0-9_./?=&%{}-]+)/);
      if (path) return path[1];
    }
    return url.replace(/<js>[\s\S]*?<\/js>/gi, '').trim();
  }

}
