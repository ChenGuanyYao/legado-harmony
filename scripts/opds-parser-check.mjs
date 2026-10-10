import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixturesDir = path.join(root, 'scripts', 'opds-fixtures');
const moduleDir = path.join(root, 'entry', 'src', 'main', 'ets', 'opds');

// node --experimental-strip-types 要求相对 import 必须带扩展名，而应用代码遵循
// ArkTS 惯例不带后缀。把两个纯 TS 文件拷到临时目录，并给解析器的相对导入补上
// '.ts' 后缀后再加载，应用源码保持规范写法不变。
const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'opds-parser-check-'));
let OpdsXmlParser;
let opdsFormatOfType;
try {
  for (const name of ['OpdsXmlParser.ts', 'OpdsModels.ts']) {
    let text = fs.readFileSync(path.join(moduleDir, name), 'utf8');
    if (name === 'OpdsXmlParser.ts') {
      const rewritten = text.replace(/(from\s+['"])(\.\/OpdsModels)(['"])/g, '$1$2.ts$3');
      if (rewritten === text && !/from\s+['"]\.\/OpdsModels\.ts['"]/.test(text)) {
        throw new Error(`无法为 node 回归改写 OpdsXmlParser.ts 的相对导入: ${name}`);
      }
      text = rewritten;
    }
    fs.writeFileSync(path.join(stagingDir, name), text);
  }
  const parserUrl = pathToFileURL(path.join(stagingDir, 'OpdsXmlParser.ts')).href;
  const modelsUrl = pathToFileURL(path.join(stagingDir, 'OpdsModels.ts')).href;
  OpdsXmlParser = (await import(parserUrl)).OpdsXmlParser;
  opdsFormatOfType = (await import(modelsUrl)).opdsFormatOfType;
} finally {
  fs.rmSync(stagingDir, { recursive: true, force: true });
}

let assertions = 0;

function fixture(name) {
  return fs.readFileSync(path.join(fixturesDir, name), 'utf8');
}

function assertEquals(actual, expected, label) {
  assertions++;
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`${label}\n    实际: ${actualJson}\n    期望: ${expectedJson}`);
  }
}

function assertTrue(condition, message) {
  assertions++;
  if (!condition) throw new Error(message);
}

function assertThrows(fn, fragments, label) {
  assertions++;
  let message = '';
  try {
    fn();
  } catch (error) {
    message = error.message;
  }
  if (message === '') {
    throw new Error(`${label}：本应抛出错误但未抛出`);
  }
  for (const fragment of fragments) {
    if (message.indexOf(fragment) < 0) {
      throw new Error(`${label}：错误信息缺少「${fragment}」\n    实际: ${message}`);
    }
  }
}

function main() {
  // ---- calibre-root.xml：导航 feed，xml:base + 相对 href 解析，rel=search ----
  const rootFeed = OpdsXmlParser.parseFeed(fixture('calibre-root.xml'),
    'http://opds.example.com/opds');
  assertEquals(rootFeed.title, 'Calibre 图书馆', 'root: feed title');
  assertEquals(rootFeed.id, 'urn:calibre:main', 'root: feed id');
  assertEquals(rootFeed.subtitle, '基于 Calibre 的个人书库', 'root: feed subtitle');
  assertEquals(rootFeed.updated, '2026-10-01T08:00:00Z', 'root: feed updated');
  assertEquals(rootFeed.logoUrl, 'http://opds.example.com/static/calibre-logo.png', 'root: logo');
  assertEquals(rootFeed.entries.length, 3, 'root: 导航条目数');
  assertTrue(rootFeed.isNavigationFeed(), 'root: 无 acquisition 条目应判定为导航 feed');
  assertEquals(rootFeed.entries[0].title, '按作者', 'root: 条目 0 标题');
  assertEquals(rootFeed.entries[0].displayText(), '按作者浏览全部书目', 'root: content 优先作为显示文本');
  const authorsNav = rootFeed.entries[0].navigationLink();
  assertTrue(authorsNav !== null, 'root: 按作者条目应有导航链接');
  if (authorsNav !== null) {
    assertEquals(authorsNav.href, 'http://opds.example.com/opds/authors',
      'root: 相对 href 应按 feed 级 xml:base 解析');
    assertTrue(authorsNav.isCatalogFeed(), 'root: navigation 链接应识别为目录 feed');
  }
  const newestNav = rootFeed.entries[1].navigationLink();
  assertTrue(newestNav !== null, 'root: 最新加入条目应有导航链接');
  if (newestNav !== null) {
    assertEquals(newestNav.href, 'http://opds.example.com/opds/newest',
      'root: 第二个条目的相对 href 解析');
  }
  const rootSearch = rootFeed.searchLink();
  assertTrue(rootSearch !== null, 'root: 应存在 rel=search 链接');
  if (rootSearch !== null) {
    assertTrue(rootSearch.isSearchDescription(), 'root: search 链接类型应识别为 opensearch 描述');
    assertEquals(rootSearch.href, 'http://opds.example.com/opds/opensearch.xml',
      'root: search 指向 opensearch 描述文档');
  }

  // ---- opensearch.xml：描述文档模板提取，优先 opds-catalog 类型的 Url ----
  const searchTemplate = OpdsXmlParser.parseSearchTemplate(fixture('opensearch.xml'));
  assertEquals(searchTemplate.urlTemplate, 'http://opds.example.com/opds/search?q={searchTerms}',
    'opensearch: 模板提取');
  assertEquals(searchTemplate.indexOffset, 1, 'opensearch: indexOffset 缺省为 1');
  assertEquals(searchTemplate.pageOffset, 3, 'opensearch: pageOffset 应解析属性值');
  assertTrue(searchTemplate.urlTemplate.indexOf('text/html') < 0,
    'opensearch: 不应选中 text/html 模板');

  // ---- calibre-books.xml：图书条目、实体解码、嵌套 xml:base、分页与 opensearch 统计 ----
  const books = OpdsXmlParser.parseFeed(fixture('calibre-books.xml'),
    'http://opds.example.com/opds');
  assertEquals(books.totalResults, 128, 'books: opensearch:totalResults');
  assertEquals(books.itemsPerPage, 20, 'books: opensearch:itemsPerPage');
  assertEquals(books.entries.length, 3, 'books: 图书条目数');
  assertTrue(!books.isNavigationFeed(), 'books: 含 acquisition 条目不应判定为导航 feed');
  const book1 = books.entries[0];
  assertEquals(book1.title, '三体 & 黑暗森林', 'books: 标题实体 &amp; 应解码');
  assertEquals(book1.authors, ['刘慈欣'], 'books: 作者');
  assertEquals(book1.displayAuthor(), '刘慈欣', 'books: displayAuthor');
  assertEquals(book1.language, 'zh', 'books: dcterms:language 按 localName 匹配');
  assertEquals(book1.publisher, '重庆出版社', 'books: dcterms:publisher 按 localName 匹配');
  assertEquals(book1.series, '三体全集', 'books: calibre:series 按 localName 匹配');
  assertEquals(book1.categories, ['科幻'], 'books: category term');
  assertEquals(book1.artworkThumbnail(), 'http://opds.example.com/opds/covers/1.jpg',
    'books: 缩略图相对 href 应解析为绝对地址');
  const book1Acq = book1.acquisitionLinks();
  assertEquals(book1Acq.length, 1, 'books: 第一个条目的 acquisition 链接数');
  assertEquals(book1Acq[0].type, 'application/epub+zip', 'books: acquisition type');
  assertEquals(opdsFormatOfType(book1Acq[0].type), 'epub', 'books: epub 格式映射');
  assertEquals(book1Acq[0].length, 1048576, 'books: acquisition length 属性');
  assertEquals(book1Acq[0].acquisitionKind(), 'generic', 'books: 裸 acquisition rel 的 kind');
  assertEquals(book1Acq[0].href, 'http://opds.example.com/opds/books/1.epub',
    'books: 下载链接相对 href 解析');
  assertTrue(book1.isPublication(), 'books: 有 acquisition 的条目应判定为出版物');
  const next = books.nextLink();
  assertTrue(next !== null, 'books: 应存在 rel=next 分页链接');
  if (next !== null) {
    assertEquals(next.href, 'http://opds.example.com/opds/allbooks?page=2',
      'books: next 相对 href 解析并保留查询串');
  }
  const booksSearch = books.searchLink();
  assertTrue(booksSearch !== null, 'books: 应存在 rel=search 链接');
  if (booksSearch !== null) {
    assertEquals(booksSearch.href, 'http://opds.example.com/opensearch.xml',
      'books: ../ 相对路径应折叠点段');
  }
  const book2 = books.entries[1];
  assertEquals(book2.authors, ['作者甲', '作者乙'], 'books: 多作者收集');
  assertEquals(book2.displayAuthor(), '作者甲, 作者乙', 'books: 多作者 displayAuthor');
  assertEquals(book2.artworkThumbnail(), 'http://opds.example.com/opds/sub/covers/2.jpg',
    'books: entry 级 xml:base 应覆盖 feed 级');
  assertEquals(book2.artworkImage(), 'http://opds.example.com/static/2.png',
    'books: link 级 xml:base 应再覆盖 entry 级');
  const book3 = books.entries[2];
  assertEquals(book3.content, '<p>第三册<br/>简介正文</p>', 'books: content 实体应解码');
  assertTrue(book3.contentIsHtml, 'books: content type=html 应标记');
  assertEquals(book3.displayText(), book3.content, 'books: displayText 应优先 content');
  assertEquals(book3.categories, ['奇幻'], 'books: 无 term 时 category 回退 label');
  assertTrue(book3.summaryIsHtml === false, 'books: 无 type 的 summary 不应标记为 html');

  // ---- komga.xml：facet 分组、thr:count、pse 属性、CDATA 原样保留 ----
  const komga = OpdsXmlParser.parseFeed(fixture('komga.xml'), 'http://komga.example.com/opds/v1.2/series');
  const facetGroups = komga.facetGroups();
  assertEquals(facetGroups.length, 2, 'komga: facet 分组数');
  assertEquals(facetGroups[0].group, '状态', 'komga: 第一个 facet 分组名');
  assertEquals(facetGroups[0].links.length, 3, 'komga: 状态分组链接数');
  assertEquals(facetGroups[1].group, '类型', 'komga: 第二个 facet 分组名');
  assertEquals(facetGroups[1].links.length, 2, 'komga: 类型分组链接数');
  const activeFacetLink = facetGroups[0].links[0];
  assertEquals(activeFacetLink.title, '全部', 'komga: facet 链接标题');
  assertTrue(activeFacetLink.activeFacet, 'komga: activeFacet=true 应识别为激活');
  assertEquals(activeFacetLink.facetCount, 245, 'komga: thr:count 应计入 facetCount');
  assertTrue(!facetGroups[0].links[1].activeFacet, 'komga: 未标记的 facet 不应激活');
  assertEquals(facetGroups[0].links[1].facetCount, 38, 'komga: 第二个 facet 的 thr:count');
  assertEquals(komga.entries.length, 1, 'komga: 条目数');
  const komgaEntry = komga.entries[0];
  assertEquals(komgaEntry.summary, '卷一 <b>加粗</b> 原始文本',
    'komga: CDATA 内容应原样保留（含标签、不做实体解码）');
  assertTrue(!komgaEntry.summaryIsHtml, 'komga: CDATA summary 无 type 不应标记为 html');
  const komgaAcq = komgaEntry.acquisitionLinks();
  assertEquals(komgaAcq.length, 1, 'komga: acquisition 链接数');
  assertEquals(komgaAcq[0].pseCount, 12, 'komga: pse:count 应解析到 pseCount');
  assertEquals(komgaAcq[0].pseLastRead, 4, 'komga: pse:lastRead 应解析');
  assertEquals(komgaAcq[0].facetCount, 0, 'komga: pse:count 不应误写入 facetCount');
  assertTrue(komga.searchLink() !== null, 'komga: 应存在 rel=search 链接');
  assertEquals(komgaEntry.artworkThumbnail(),
    'http://komga.example.com/opds/v1.2/series/ABC123/thumbnail',
    'komga: 绝对 href 原样保留');

  // ---- kavita.xml：多格式 acquisition 链接 ----
  const kavita = OpdsXmlParser.parseFeed(fixture('kavita.xml'), 'http://kavita.example.com/api/opds');
  const kavitaAcq = kavita.entries[0].acquisitionLinks();
  assertEquals(kavitaAcq.length, 3, 'kavita: 三个 acquisition 链接');
  assertEquals(kavitaAcq.map((link) => opdsFormatOfType(link.type)), ['epub', 'pdf', 'cbz'],
    'kavita: epub/pdf/cbz 格式映射');
  assertEquals(kavitaAcq[0].length, 2097152, 'kavita: 第一个链接的 length');
  assertEquals(kavitaAcq[1].length, 0, 'kavita: 缺 length 缺省 0');
  assertTrue(kavitaAcq.every((link) => link.acquisitionKind() === 'generic'),
    'kavita: acquisition kind 应为 generic');

  // ---- buy-entry.xml：Complete Catalog Entry，buy 链接、价格与间接获取 ----
  const buyEntry = OpdsXmlParser.parseEntry(fixture('buy-entry.xml'), 'http://shop.example.com/');
  assertEquals(buyEntry.title, '付费示例书', 'buy: 条目标题');
  assertEquals(buyEntry.summary, '一本需要购买的书', 'buy: 条目简介');
  const buyLinks = buyEntry.acquisitionLinks();
  assertEquals(buyLinks.length, 2, 'buy: buy 链接数');
  assertTrue(buyLinks.every((link) => link.acquisitionKind() === 'buy'),
    'buy: acquisitionKind 应为 buy');
  assertEquals(buyLinks[0].price, '12.99', 'buy: 美元价格');
  assertEquals(buyLinks[0].priceCurrency, 'USD', 'buy: 美元币种');
  assertEquals(buyLinks[0].indirectTypes, ['application/epub+zip'], 'buy: 间接获取类型');
  assertEquals(buyLinks[1].price, '45.00', 'buy: 人民币价格');
  assertEquals(buyLinks[1].priceCurrency, 'CNY', 'buy: 人民币币种');
  assertEquals(buyLinks[1].indirectTypes.length, 2, 'buy: 第二个链接的间接获取数');
  assertEquals(opdsFormatOfType('application/x-mobipocket-ebook'), 'mobi',
    'buy: mobi 格式映射（indirectTypes 内容）');

  // ---- broken.xml：损坏文档必须抛出含中文的可读错误 ----
  assertThrows(() => OpdsXmlParser.parseFeed(fixture('broken.xml'), 'http://opds.example.com/'),
    ['XML 解析失败', '不匹配'], 'broken: 标签不匹配应报错');
  assertThrows(() => OpdsXmlParser.parseFeed(
    '<feed xmlns="http://www.w3.org/2005/Atom"><title>截断的文档</title>', 'http://x.example/'),
    ['XML 解析失败', '未闭合'], 'broken: EOF 未闭合标签应报错');
  assertThrows(() => OpdsXmlParser.parseFeed(
    '<feed><link href="abc></feed>', 'http://x.example/'),
    ['XML 解析失败', '引号'], 'broken: 属性引号未闭合应报错');
  assertThrows(() => OpdsXmlParser.parseFeed('', 'http://x.example/'),
    ['XML 解析失败'], 'broken: 空文档应报错');
  assertThrows(() => OpdsXmlParser.parseEntry(fixture('calibre-root.xml'), 'http://x.example/'),
    ['XML 解析失败', 'entry'], 'broken: parseEntry 收到 feed 根应报错');
  assertThrows(() => OpdsXmlParser.parseSearchTemplate('<feed/>'),
    ['XML 解析失败', 'OpenSearch'], 'broken: parseSearchTemplate 收到 feed 根应报错');

  // ---- resolveUrl：URL 拼接规则 ----
  assertEquals(OpdsXmlParser.resolveUrl('http://a.example/x?y=1', 'http://b.example/z'),
    'http://a.example/x?y=1', 'resolveUrl: 绝对地址原样返回');
  assertEquals(OpdsXmlParser.resolveUrl('//cdn.example.com/cover.png', 'https://h.example/opds/'),
    'https://cdn.example.com/cover.png', 'resolveUrl: 协议相对沿用 base 协议');
  assertEquals(OpdsXmlParser.resolveUrl('/root.png', 'http://h.example/a/b'),
    'http://h.example/root.png', 'resolveUrl: 根相对路径');
  assertEquals(OpdsXmlParser.resolveUrl('c/d.png', 'http://h.example/a/b?x=1#f'),
    'http://h.example/a/c/d.png', 'resolveUrl: 同级相对路径忽略 base 查询与锚点');
  assertEquals(OpdsXmlParser.resolveUrl('../up.png', 'http://h.example/a/b/'),
    'http://h.example/a/up.png', 'resolveUrl: 点段折叠');
  assertEquals(OpdsXmlParser.resolveUrl('?q=1', 'http://h.example/a/b'),
    'http://h.example/a/b?q=1', 'resolveUrl: 仅查询串替换');
  assertEquals(OpdsXmlParser.resolveUrl('#frag', 'http://h.example/a/b'),
    'http://h.example/a/b#frag', 'resolveUrl: 仅锚点追加');
  assertEquals(OpdsXmlParser.resolveUrl('book/1.epub', ''),
    'book/1.epub', 'resolveUrl: 无 base 时保持原样');

  // ---- 行内补充用例：baseUrl 回落、数字实体、属性实体、未知内容容忍、空 feed ----
  const fallbackFeed = OpdsXmlParser.parseFeed(
    '<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>回落</title>' +
    '<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="book/1.epub"/>' +
    '</entry></feed>', 'http://fallback.example/base/');
  assertEquals(fallbackFeed.entries[0].acquisitionLinks()[0].href,
    'http://fallback.example/base/book/1.epub',
    'inline: 无 xml:base 时 href 应回落到 parse 传入的 baseUrl');

  const entityFeed = OpdsXmlParser.parseFeed(
    '<feed><title>A&#66;C&#x44;</title><weird attr="1">忽略我</weird>' +
    '<link rel="search" type="application/opensearchdescription+xml" href="s?a=1&amp;b=2"/></feed>',
    'http://h.example/opds/');
  assertEquals(entityFeed.title, 'ABCD', 'inline: 十进制与十六进制数字引用应解码');
  assertEquals(entityFeed.links[0].href, 'http://h.example/opds/s?a=1&b=2',
    'inline: 属性值里的 &amp; 应解码后参与拼接');
  assertEquals(entityFeed.entries.length, 0, 'inline: 未知子元素应忽略');

  const emptyFeed = OpdsXmlParser.parseFeed('<feed xmlns="http://www.w3.org/2005/Atom"/>',
    'http://h.example/');
  assertEquals(emptyFeed.entries.length, 0, 'inline: 空 feed 条目数为 0');
  assertEquals(emptyFeed.totalResults, -1, 'inline: 缺 totalResults 时为 -1');
  assertEquals(emptyFeed.itemsPerPage, -1, 'inline: 缺 itemsPerPage 时为 -1');
  assertTrue(emptyFeed.isNavigationFeed(), 'inline: 空 feed 按导航 feed 处理');
}

try {
  main();
} catch (error) {
  console.error(`OPDS parser check failed:\n- ${error.message}`);
  process.exit(1);
}
console.log(`OPDS parser check passed: 7 fixtures, ${assertions} assertions.`);
