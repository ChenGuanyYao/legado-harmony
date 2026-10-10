// OPDS Atom/OPDS XML 解析器。纯 TypeScript，无平台 API 依赖，可在 Node 中直接运行。

import { OpdsEntry, OpdsFeed, OpdsLink, OpdsSearchTemplate } from './OpdsModels';

const XML_NS_PREFIX: string = 'xml';
const HTML_CONTENT_TYPES: string[] = ['html', 'xhtml'];
const ACTIVE_FACET_TRUE_VALUES: string[] = ['true', 'yes', '1'];

class XmlAttr {
  rawName: string = '';
  prefix: string = '';
  localName: string = '';
  value: string = '';
}

class XmlNode {
  rawName: string = '';
  prefix: string = '';
  localName: string = '';
  attributes: XmlAttr[] = [];
  children: XmlNode[] = [];
  text: string = '';
}

function codePointToString(codePoint: number): string {
  if (!isFinite(codePoint) || codePoint <= 0 || codePoint > 0x10FFFF ||
    (codePoint >= 0xD800 && codePoint <= 0xDFFF)) return '�';
  return String.fromCodePoint(codePoint);
}

function decodeOneEntity(name: string): string {
  if (name === 'amp') return '&';
  if (name === 'lt') return '<';
  if (name === 'gt') return '>';
  if (name === 'quot') return '"';
  if (name === 'apos') return '\'';
  if (name.indexOf('#x') === 0 || name.indexOf('#X') === 0) {
    const hexDigits: string = name.substring(2);
    if (/^[0-9a-fA-F]+$/.test(hexDigits)) return codePointToString(parseInt(hexDigits, 16));
    return '';
  }
  if (name.indexOf('#') === 0) {
    const decimalDigits: string = name.substring(1);
    if (/^[0-9]+$/.test(decimalDigits)) return codePointToString(parseInt(decimalDigits, 10));
    return '';
  }
  return '';
}

// 命名实体之外的引用保持原样：未注册的 &foo; 按字面文本容忍，不当作错误。
function decodeXmlEntities(text: string): string {
  if (text.indexOf('&') < 0) return text;
  let result: string = '';
  let cursor: number = 0;
  while (cursor < text.length) {
    const amp: number = text.indexOf('&', cursor);
    if (amp < 0) {
      result += text.substring(cursor);
      break;
    }
    result += text.substring(cursor, amp);
    const semi: number = text.indexOf(';', amp + 1);
    if (semi < 0 || semi - amp > 32) {
      result += '&';
      cursor = amp + 1;
      continue;
    }
    const decoded: string = decodeOneEntity(text.substring(amp + 1, semi));
    if (decoded === '') {
      result += '&';
      cursor = amp + 1;
    } else {
      result += decoded;
      cursor = semi + 1;
    }
  }
  return result;
}

// 轻量 pull 式 tokenizer：把文档读成一棵仅含 localName 的树，良构性错误抛中文可读信息。
class XmlPullReader {
  private source: string = '';
  private position: number = 0;

  parse(xml: string): XmlNode {
    let body: string = xml;
    if (body.charCodeAt(0) === 0xFEFF) body = body.substring(1);
    this.source = body;
    this.position = 0;
    const stack: XmlNode[] = [];
    let root: XmlNode | null = null;
    let rootComplete: boolean = false;
    while (this.position < this.source.length) {
      if (this.startsWith('<!--')) {
        this.skipComment();
      } else if (this.startsWith('<![CDATA[')) {
        this.readCdata(stack);
      } else if (this.startsWith('<!')) {
        this.skipDeclaration();
      } else if (this.startsWith('<?')) {
        this.skipProcessingInstruction();
      } else if (this.startsWith('</')) {
        const closingName: string = this.readClosingTagName();
        if (stack.length === 0) {
          throw this.error(`存在没有匹配开始标签的结束标签 </${closingName}>`);
        }
        const openNode: XmlNode = stack[stack.length - 1];
        if (openNode.rawName !== closingName) {
          throw this.error(`结束标签 </${closingName}> 与开始标签 <${openNode.rawName}> 不匹配`);
        }
        stack.pop();
        if (stack.length === 0) rootComplete = true;
      } else if (this.currentChar() === '<' && this.isNameStartChar(this.peekChar(1))) {
        const node: XmlNode = new XmlNode();
        const selfClosing: boolean = this.readStartTag(node);
        if (stack.length === 0) {
          if (rootComplete || root !== null) {
            throw this.error(`文档包含多个根元素 <${node.rawName}>`);
          }
          root = node;
        } else {
          stack[stack.length - 1].children.push(node);
        }
        if (selfClosing) {
          if (stack.length === 0) rootComplete = true;
        } else {
          stack.push(node);
        }
      } else {
        const rawText: string = this.readTextRun();
        if (stack.length > 0) {
          stack[stack.length - 1].text += decodeXmlEntities(rawText);
        }
      }
    }
    if (stack.length > 0) {
      const unclosed: XmlNode = stack[stack.length - 1];
      throw this.error(`标签 <${unclosed.rawName}> 未闭合，文档意外结束`);
    }
    if (root === null) {
      throw this.error('文档为空或缺少根元素');
    }
    return root;
  }

  private startsWith(token: string): boolean {
    return this.source.startsWith(token, this.position);
  }

  private currentChar(): string {
    return this.source.charAt(this.position);
  }

  private peekChar(offset: number): string {
    return this.source.charAt(this.position + offset);
  }

  private isNameStartChar(ch: string): boolean {
    return /[A-Za-z_:]/.test(ch);
  }

  private isNameChar(ch: string): boolean {
    return /[A-Za-z0-9._:-]/.test(ch);
  }

  private isWhitespace(ch: string): boolean {
    return ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n';
  }

  private skipWhitespace(): void {
    while (this.position < this.source.length && this.isWhitespace(this.currentChar())) {
      this.position++;
    }
  }

  private readName(): string {
    const start: number = this.position;
    while (this.position < this.source.length && this.isNameChar(this.currentChar())) {
      this.position++;
    }
    return this.source.substring(start, this.position);
  }

  private splitName(rawName: string, target: XmlNode): void {
    target.rawName = rawName;
    const colon: number = rawName.indexOf(':');
    if (colon > 0) {
      target.prefix = rawName.substring(0, colon);
      target.localName = rawName.substring(colon + 1);
    } else {
      target.prefix = '';
      target.localName = rawName;
    }
  }

  private makeAttr(rawName: string, value: string): XmlAttr {
    const attr: XmlAttr = new XmlAttr();
    const colon: number = rawName.indexOf(':');
    if (colon > 0) {
      attr.prefix = rawName.substring(0, colon);
      attr.localName = rawName.substring(colon + 1);
    } else {
      attr.prefix = '';
      attr.localName = rawName;
    }
    attr.rawName = rawName;
    attr.value = value;
    return attr;
  }

  private readStartTag(node: XmlNode): boolean {
    this.position++;
    const name: string = this.readName();
    if (name === '') {
      throw this.error('标签名缺失');
    }
    this.splitName(name, node);
    while (true) {
      this.skipWhitespace();
      if (this.position >= this.source.length) {
        throw this.error(`标签 <${name}> 缺少结束符 '>'，文档意外结束`);
      }
      const ch: string = this.currentChar();
      if (ch === '>') {
        this.position++;
        return false;
      }
      if (ch === '/') {
        this.position++;
        this.skipWhitespace();
        if (this.position < this.source.length && this.currentChar() === '>') {
          this.position++;
          return true;
        }
        throw this.error(`标签 <${name}> 中 '/' 之后应是 '>'`);
      }
      const attrName: string = this.readName();
      if (attrName === '') {
        throw this.error(`标签 <${name}> 的属性名缺失`);
      }
      this.skipWhitespace();
      let attrValue: string = '';
      if (this.position < this.source.length && this.currentChar() === '=') {
        this.position++;
        this.skipWhitespace();
        if (this.position >= this.source.length) {
          throw this.error(`标签 <${name}> 的属性 ${attrName} 缺少值`);
        }
        const quote: string = this.currentChar();
        if (quote === '"' || quote === '\'') {
          this.position++;
          const valueStart: number = this.position;
          while (this.position < this.source.length && this.currentChar() !== quote) {
            this.position++;
          }
          if (this.position >= this.source.length) {
            throw this.error(`标签 <${name}> 的属性 ${attrName} 的值缺少结束引号`);
          }
          attrValue = decodeXmlEntities(this.source.substring(valueStart, this.position));
          this.position++;
        } else {
          const valueStart: number = this.position;
          while (this.position < this.source.length && !this.isWhitespace(this.currentChar()) &&
            this.currentChar() !== '>' && this.currentChar() !== '/') {
            this.position++;
          }
          attrValue = decodeXmlEntities(this.source.substring(valueStart, this.position));
        }
      }
      let duplicated: boolean = false;
      for (const existing of node.attributes) {
        if (existing.rawName === attrName) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        node.attributes.push(this.makeAttr(attrName, attrValue));
      }
    }
  }

  private readClosingTagName(): string {
    this.position += 2;
    this.skipWhitespace();
    const name: string = this.readName();
    if (name === '') {
      throw this.error('结束标签名缺失');
    }
    this.skipWhitespace();
    while (this.position < this.source.length && this.currentChar() !== '>') {
      this.position++;
    }
    if (this.position >= this.source.length) {
      throw this.error(`结束标签 </${name}> 缺少 '>'，文档意外结束`);
    }
    this.position++;
    return name;
  }

  private readTextRun(): string {
    const start: number = this.position;
    while (this.position < this.source.length && this.currentChar() !== '<') {
      this.position++;
    }
    return this.source.substring(start, this.position);
  }

  private readCdata(stack: XmlNode[]): void {
    const end: number = this.source.indexOf(']]>', this.position + 9);
    if (end < 0) {
      throw this.error('CDATA 段未闭合，文档意外结束');
    }
    if (stack.length > 0) {
      stack[stack.length - 1].text += this.source.substring(this.position + 9, end);
    }
    this.position = end + 3;
  }

  private skipComment(): void {
    const end: number = this.source.indexOf('-->', this.position + 4);
    if (end < 0) {
      throw this.error('注释未闭合，文档意外结束');
    }
    this.position = end + 3;
  }

  private skipProcessingInstruction(): void {
    const end: number = this.source.indexOf('?>', this.position + 2);
    if (end < 0) {
      this.position = this.source.length;
      return;
    }
    this.position = end + 2;
  }

  // DTD/声明跳过：内部子集用方括号配对、字符串用引号配对，避免把声明里的 '>' 当作结束。
  private skipDeclaration(): void {
    let index: number = this.position + 2;
    let quote: string = '';
    let bracketDepth: number = 0;
    while (index < this.source.length) {
      const ch: string = this.source.charAt(index);
      if (quote !== '') {
        if (ch === quote) quote = '';
      } else if (ch === '"' || ch === '\'') {
        quote = ch;
      } else if (ch === '[') {
        bracketDepth++;
      } else if (ch === ']') {
        if (bracketDepth > 0) bracketDepth--;
      } else if (ch === '>' && bracketDepth === 0) {
        this.position = index + 1;
        return;
      }
      index++;
    }
    this.position = this.source.length;
  }

  private error(message: string): Error {
    const upto: string = this.source.substring(0, this.position);
    const line: number = upto.split('\n').length;
    const lastNewline: number = upto.lastIndexOf('\n');
    const column: number = this.position - lastNewline;
    return new Error(`XML 解析失败：第 ${line} 行第 ${column} 列，${message}`);
  }
}

export class OpdsXmlParser {
  static parseFeed(xml: string, baseUrl: string): OpdsFeed {
    const root: XmlNode = new XmlPullReader().parse(xml);
    if (root.localName !== 'feed') {
      throw new Error(`XML 解析失败：期望 <feed> 根元素，实际是 <${root.rawName}>`);
    }
    const feed: OpdsFeed = new OpdsFeed();
    const feedBase: string = OpdsXmlParser.withBase(baseUrl, root);
    for (const child of root.children) {
      if (child.localName === 'id') {
        feed.id = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'title') {
        feed.title = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'subtitle') {
        feed.subtitle = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'updated') {
        feed.updated = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'logo') {
        feed.logoUrl = OpdsXmlParser.resolveUrl(OpdsXmlParser.textOf(child).trim(), feedBase);
      } else if (child.localName === 'totalResults') {
        feed.totalResults = OpdsXmlParser.toInt(OpdsXmlParser.textOf(child), -1);
      } else if (child.localName === 'itemsPerPage') {
        feed.itemsPerPage = OpdsXmlParser.toInt(OpdsXmlParser.textOf(child), -1);
      } else if (child.localName === 'link') {
        feed.links.push(OpdsXmlParser.parseLink(child, feedBase));
      } else if (child.localName === 'entry') {
        feed.entries.push(OpdsXmlParser.parseEntryNode(child, feedBase));
      }
    }
    return feed;
  }

  static parseEntry(xml: string, baseUrl: string): OpdsEntry {
    const root: XmlNode = new XmlPullReader().parse(xml);
    if (root.localName !== 'entry') {
      throw new Error(`XML 解析失败：期望 <entry> 根元素，实际是 <${root.rawName}>`);
    }
    return OpdsXmlParser.parseEntryNode(root, baseUrl);
  }

  static parseSearchTemplate(xml: string): OpdsSearchTemplate {
    const root: XmlNode = new XmlPullReader().parse(xml);
    if (root.localName !== 'OpenSearchDescription') {
      throw new Error(`XML 解析失败：期望 OpenSearch 描述文档根元素，实际是 <${root.rawName}>`);
    }
    let chosen: XmlNode | null = null;
    for (const child of root.children) {
      if (child.localName !== 'Url') continue;
      const type: string = OpdsXmlParser.attrValue(child, 'type').toLowerCase();
      if (type.indexOf('opds-catalog') >= 0) {
        chosen = child;
        break;
      }
    }
    if (chosen === null) {
      for (const child of root.children) {
        if (child.localName !== 'Url') continue;
        const type: string = OpdsXmlParser.attrValue(child, 'type').toLowerCase();
        if (type.indexOf('atom+xml') >= 0) {
          chosen = child;
          break;
        }
      }
    }
    if (chosen === null) {
      throw new Error('XML 解析失败：OpenSearch 描述文档缺少可用的 Url 模板');
    }
    const template: OpdsSearchTemplate = new OpdsSearchTemplate();
    template.urlTemplate = OpdsXmlParser.attrValue(chosen, 'template');
    template.indexOffset = OpdsXmlParser.toInt(OpdsXmlParser.attrValue(chosen, 'indexOffset'), 1);
    template.pageOffset = OpdsXmlParser.toInt(OpdsXmlParser.attrValue(chosen, 'pageOffset'), 1);
    return template;
  }

  // 相对 href 按当前有效 base 拼绝对地址；base 逐级被 xml:base 覆盖，最终回落到传入的 baseUrl。
  static resolveUrl(href: string, base: string): string {
    const target: string = href.trim();
    if (target === '') return '';
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(target)) return target;
    const source: string = base.trim();
    if (source === '') return target;
    const schemeMatch: RegExpMatchArray | null = source.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//);
    if (target.indexOf('//') === 0) {
      if (schemeMatch === null) return target;
      return schemeMatch[1] + ':' + target;
    }
    if (schemeMatch === null) return target;
    const scheme: string = schemeMatch[1];
    const afterScheme: string = source.substring(scheme.length + 3);
    let authority: string = afterScheme;
    let basePath: string = '/';
    const pathStart: number = afterScheme.indexOf('/');
    if (pathStart >= 0) {
      authority = afterScheme.substring(0, pathStart);
      const remainder: string = afterScheme.substring(pathStart);
      const queryIndex: number = remainder.indexOf('?');
      const fragmentIndex: number = remainder.indexOf('#');
      let pathEnd: number = remainder.length;
      if (fragmentIndex >= 0) pathEnd = Math.min(pathEnd, fragmentIndex);
      if (queryIndex >= 0) pathEnd = Math.min(pathEnd, queryIndex);
      basePath = remainder.substring(0, pathEnd);
    }
    const origin: string = scheme + '://' + authority;
    let fragment: string = '';
    let withoutFragment: string = target;
    const hashIndex: number = target.indexOf('#');
    if (hashIndex >= 0) {
      fragment = target.substring(hashIndex);
      withoutFragment = target.substring(0, hashIndex);
    }
    let query: string = '';
    let targetPath: string = withoutFragment;
    const queryMark: number = withoutFragment.indexOf('?');
    if (queryMark >= 0) {
      query = withoutFragment.substring(queryMark);
      targetPath = withoutFragment.substring(0, queryMark);
    }
    if (targetPath === '') {
      return origin + basePath + query + fragment;
    }
    if (targetPath.indexOf('/') === 0) {
      return origin + OpdsXmlParser.removeDotSegments(targetPath) + query + fragment;
    }
    let baseDir: string = basePath;
    const lastSlash: number = basePath.lastIndexOf('/');
    if (lastSlash >= 0) baseDir = basePath.substring(0, lastSlash + 1);
    return origin + OpdsXmlParser.removeDotSegments(baseDir + targetPath) + query + fragment;
  }

  private static parseEntryNode(node: XmlNode, inheritedBase: string): OpdsEntry {
    const entry: OpdsEntry = new OpdsEntry();
    const entryBase: string = OpdsXmlParser.withBase(inheritedBase, node);
    for (const child of node.children) {
      if (child.localName === 'id') {
        entry.id = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'title') {
        entry.title = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'updated') {
        entry.updated = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'author') {
        OpdsXmlParser.collectAuthors(child, entry);
      } else if (child.localName === 'summary') {
        entry.summary = OpdsXmlParser.textOf(child).trim();
        entry.summaryIsHtml = OpdsXmlParser.isHtmlContent(child);
      } else if (child.localName === 'content') {
        entry.content = OpdsXmlParser.textOf(child).trim();
        entry.contentIsHtml = OpdsXmlParser.isHtmlContent(child);
      } else if (child.localName === 'category') {
        const term: string = OpdsXmlParser.attrValue(child, 'term');
        const label: string = OpdsXmlParser.attrValue(child, 'label');
        const category: string = (term !== '' ? term : label).trim();
        if (category !== '') entry.categories.push(category);
      } else if (child.localName === 'language') {
        entry.language = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'publisher') {
        entry.publisher = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'series') {
        entry.series = OpdsXmlParser.textOf(child).trim();
      } else if (child.localName === 'link') {
        entry.links.push(OpdsXmlParser.parseLink(child, entryBase));
      }
    }
    return entry;
  }

  private static parseLink(node: XmlNode, inheritedBase: string): OpdsLink {
    const link: OpdsLink = new OpdsLink();
    const linkBase: string = OpdsXmlParser.withBase(inheritedBase, node);
    link.href = OpdsXmlParser.resolveUrl(OpdsXmlParser.attrValue(node, 'href'), linkBase);
    link.rel = OpdsXmlParser.attrValue(node, 'rel').trim();
    link.type = OpdsXmlParser.attrValue(node, 'type').trim();
    link.title = OpdsXmlParser.attrValue(node, 'title');
    link.length = OpdsXmlParser.toInt(OpdsXmlParser.attrValue(node, 'length'), 0);
    link.facetGroup = OpdsXmlParser.attrValue(node, 'facetGroup');
    const activeFacet: string = OpdsXmlParser.attrValue(node, 'activeFacet').trim().toLowerCase();
    link.activeFacet = ACTIVE_FACET_TRUE_VALUES.indexOf(activeFacet) >= 0;
    const pseCount: string = OpdsXmlParser.attrValueExact(node, 'pse', 'count');
    if (pseCount !== '') {
      link.pseCount = OpdsXmlParser.toInt(pseCount, 0);
    } else {
      const anyCount: string = OpdsXmlParser.attrValue(node, 'count');
      if (anyCount !== '') link.facetCount = OpdsXmlParser.toInt(anyCount, 0);
    }
    link.pseLastRead = OpdsXmlParser.toInt(
      OpdsXmlParser.attrValueExact(node, 'pse', 'lastRead'), 0);
    for (const child of node.children) {
      if (child.localName === 'price') {
        link.price = OpdsXmlParser.textOf(child).trim();
        link.priceCurrency = OpdsXmlParser.attrValue(child, 'currencyCode').trim();
      } else if (child.localName === 'indirectAcquisition') {
        const indirectType: string = OpdsXmlParser.attrValue(child, 'type').trim();
        if (indirectType !== '') link.indirectTypes.push(indirectType);
      }
    }
    return link;
  }

  private static collectAuthors(authorNode: XmlNode, entry: OpdsEntry): void {
    for (const child of authorNode.children) {
      if (child.localName !== 'name') continue;
      const name: string = OpdsXmlParser.textOf(child).trim();
      if (name !== '') entry.authors.push(name);
    }
    if (entry.authors.length === 0) {
      const direct: string = authorNode.text.trim();
      if (direct !== '') entry.authors.push(direct);
    }
  }

  private static withBase(inherited: string, node: XmlNode): string {
    const baseAttr: string = OpdsXmlParser.baseAttrValue(node);
    if (baseAttr === '') return inherited;
    return OpdsXmlParser.resolveUrl(baseAttr, inherited);
  }

  private static baseAttrValue(node: XmlNode): string {
    for (const attr of node.attributes) {
      if (attr.prefix === XML_NS_PREFIX && attr.localName === 'base') return attr.value.trim();
    }
    for (const attr of node.attributes) {
      if (attr.prefix === '' && attr.localName === 'base') return attr.value.trim();
    }
    return '';
  }

  private static attrValue(node: XmlNode, localName: string): string {
    for (const attr of node.attributes) {
      if (attr.localName === localName) return attr.value;
    }
    return '';
  }

  private static attrValueExact(node: XmlNode, prefix: string, localName: string): string {
    for (const attr of node.attributes) {
      if (attr.prefix === prefix && attr.localName === localName) return attr.value;
    }
    return '';
  }

  private static textOf(node: XmlNode): string {
    let text: string = node.text;
    for (const child of node.children) {
      text += OpdsXmlParser.textOf(child);
    }
    return text;
  }

  private static isHtmlContent(node: XmlNode): boolean {
    const type: string = OpdsXmlParser.attrValue(node, 'type').trim().toLowerCase();
    return HTML_CONTENT_TYPES.indexOf(type) >= 0;
  }

  private static toInt(text: string, fallback: number): number {
    const value: number = parseInt(text.trim(), 10);
    if (isNaN(value)) return fallback;
    return value;
  }

  private static removeDotSegments(path: string): string {
    const leadingSlash: boolean = path.indexOf('/') === 0;
    const trailingSlash: boolean =
      path.endsWith('/') || path.endsWith('/.') || path.endsWith('/..');
    const kept: string[] = [];
    for (const part of path.split('/')) {
      if (part === '' || part === '.') continue;
      if (part === '..') {
        kept.pop();
        continue;
      }
      kept.push(part);
    }
    let result: string = (leadingSlash ? '/' : '') + kept.join('/');
    if (result === '') result = '/';
    if (trailingSlash && !result.endsWith('/')) result += '/';
    return result;
  }
}
