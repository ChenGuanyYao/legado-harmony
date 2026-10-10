import { ReaderActionMarker } from '../book/ReaderActionMarker';
import { ReaderImageMarker } from '../book/ReaderImageMarker';

/**
 * 章节正文归一化（纯逻辑，不依赖 ArkUI）：换行与空白清理、软换行合并、段首缩进、重复标题剥离。
 * 分页偏移以这里的输出为基准，任何规则变化都会让已保存的字符偏移失效，改动前先跑
 * scripts/reader-text-normalizer-check.mjs。
 */
export class ReaderTextNormalizer {
  static readonly PARAGRAPH_INDENT: string = '　　';

  static isTrimChar(value: string): boolean {
    return value === ' ' || value === '\t' || value === '\n' || value === '\r' ||
      value === ' ' || value === '　' || value === '﻿' || value === '​' ||
      value === '‌' || value === '‍' || value === '⁠';
  }

  // "保留段首缩进"开启时分页/分块起点仍要跳过的字符：换行与零宽不可见字符。
  // 空格类字符（全角空格、普通空格等）在此模式下保留，段首缩进因此不被裁掉。
  static isPageStartTrimChar(value: string): boolean {
    return value === '\n' || value === '\r' || value === '﻿' ||
      value === '​' || value === '‌' || value === '‍' || value === '⁠';
  }

  static trim(text: string): string {
    const source = text || '';
    let start = 0;
    let end = source.length;
    while (start < end && ReaderTextNormalizer.isTrimChar(source.charAt(start))) {
      start++;
    }
    while (end > start && ReaderTextNormalizer.isTrimChar(source.charAt(end - 1))) {
      end--;
    }
    return source.substring(start, end);
  }

  static normalizeText(text: string): string {
    return ReaderTextNormalizer.trim((text || '')
      .replace(/\r\n/g, '\n')
      .replace(/ /g, ' ')
      .replace(/\n{3,}/g, '\n\n'));
  }

  static normalizeChapterBody(text: string): string {
    return ReaderTextNormalizer.mergeSoftWrappedLines(ReaderTextNormalizer.normalizeText(text));
  }

  static mergeSoftWrappedLines(text: string): string {
    if (!text || text.indexOf('\n') < 0) {
      return text;
    }
    const rawLines = text.split('\n');
    const result: string[] = [];
    let current = '';
    for (const rawLine of rawLines) {
      const line = rawLine.trim();
      if (!line) {
        if (current) {
          result.push(current);
          current = '';
        }
        if (result.length > 0 && result[result.length - 1] !== '') {
          result.push('');
        }
        continue;
      }
      if (!current) {
        current = line;
        continue;
      }
      if (ReaderTextNormalizer.shouldMergeSoftLine(current, rawLine)) {
        current += ReaderTextNormalizer.softLineJoiner(current, line) + line;
      } else {
        result.push(current);
        current = line;
      }
    }
    if (current) {
      result.push(current);
    }
    return result.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  static softLineJoiner(previous: string, next: string): string {
    const left = (previous || '').trim();
    const right = (next || '').trim();
    if (!left || !right || /[-‐‑‒–—]$/.test(left)) {
      return '';
    }
    return /[A-Za-z0-9,.:;\'"）)\]]$/.test(left) && /^[A-Za-z0-9]/.test(right) ? ' ' : '';
  }

  static shouldMergeSoftLine(previous: string, nextRaw: string): boolean {
    const prev = (previous || '').trim();
    const next = (nextRaw || '').trim();
    if (ReaderActionMarker.has(prev) || ReaderActionMarker.has(next)) {
      return false;
    }
    if (!prev || !next) {
      return false;
    }
    if (/^[　\s]/.test(nextRaw)) {
      return false;
    }
    if (/^[第卷章节回番外序楔引]\s*[\d一二三四五六七八九十百千万零〇壹贰叁肆伍陆柒捌玖拾]/.test(next)) {
      return false;
    }
    if (/^[，,。！？!?；;：:、」』”）)]/.test(next)) {
      return true;
    }
    if (/[。！？!?；;」』”）)]$/.test(prev)) {
      return false;
    }
    return prev.length < 48 && next.length < 48;
  }

  static indentChapterBody(text: string): string {
    const normalized = ReaderTextNormalizer.normalizeChapterBody(text);
    if (!normalized) {
      return '';
    }
    return normalized
      .split('\n')
      .map((line: string) => ReaderTextNormalizer.indentLine(line))
      .join('\n');
  }

  static indentLine(line: string): string {
    if (!line || line.trim().length === 0) {
      return line;
    }
    const trimmed = line.trim();
    // 图片标记是结构数据，不是正文段落；给它添加两个全角空格会被分页器拆成一张不可见的文本页。
    if (ReaderImageMarker.isMarker(trimmed)) {
      return trimmed;
    }
    if (line.startsWith(ReaderTextNormalizer.PARAGRAPH_INDENT)) {
      return line;
    }
    return `${ReaderTextNormalizer.PARAGRAPH_INDENT}${line.replace(/^[　\s]+/g, '')}`;
  }

  static stripDuplicatedTitle(body: string, title: string): string {
    if (!body || !title) {
      return body;
    }
    const lines = body.split('\n');
    const firstLine = (lines[0] || '').replace(/^[　\s]+/g, '').trim();
    if (firstLine !== title) {
      return body;
    }
    return ReaderTextNormalizer.trim(lines.slice(1).join('\n').replace(/^\n+/, ''));
  }

  /**
   * 把 [rawStart, rawEnd) 裁掉首尾空白后追加为一页；裁完为空则不追加。
   * keepIndent 为 true 时页首只跳过换行与零宽字符，保留空格类缩进。
   */
  static pushPage(source: string, rawStart: number, rawEnd: number, pages: string[], starts: number[],
    ends: number[], keepIndent: boolean): void {
    let pageStart = Math.max(0, Math.min(rawStart, source.length));
    let pageEnd = Math.max(pageStart, Math.min(rawEnd, source.length));
    while (pageStart < pageEnd && (keepIndent ?
      ReaderTextNormalizer.isPageStartTrimChar(source.charAt(pageStart)) :
      ReaderTextNormalizer.isTrimChar(source.charAt(pageStart)))) {
      pageStart++;
    }
    while (pageEnd > pageStart && ReaderTextNormalizer.isTrimChar(source.charAt(pageEnd - 1))) {
      pageEnd--;
    }
    const pageText = source.substring(pageStart, pageEnd);
    if (!pageText) {
      return;
    }
    pages.push(pageText);
    starts.push(pageStart);
    ends.push(pageEnd);
  }
}
