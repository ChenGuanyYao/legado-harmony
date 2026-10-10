#!/usr/bin/env node
// 图文混排分页规则的回归检查。直接加载 pages/ReadBook.ets 使用的纯 TS 模块
// ReaderMixedPageLayout（以及生成正文的 EpubHtmlConverter），只把原生文本测量替换成
// 确定性的桩（固定行高 / 每行字数），因此分页控制流与应用完全一致。
// Usage: node --experimental-strip-types scripts/epub-mixed-layout-check.mjs

import { loadReaderModules } from './lib/load-reader-modules.mjs';

const { EpubHtmlConverter, EpubImageRef, ReaderImageMarker, ReaderMixedPageLayout, ReaderMixedPageHost, cleanup } =
  await loadReaderModules();

// ---- 确定性测量桩（对应 ReadBook.buildReaderMixedPageHost） ----
const LINE_HEIGHT_PX = 48;
const CHARS_PER_LINE = 24;
const PARAGRAPH_BOUNDARY_PX = 12;
const VIEWPORT_PX = 2200;
const WIDTH_PX = 1080;
const PX_PER_VP = 3;
const MIN_IMAGE_PX = 360;          // toMeasurePx(120)

const isTrimChar = (ch) => ' \t\n\r\u00A0　\uFEFF\u200B\u200C\u200D\u2060'.includes(ch);
const isMarker = (text) => ReaderImageMarker.isMarker(text);
const splitParagraphs = (text) => {
  const paragraphs = [];
  const re = /\n+/g;
  let start = 0;
  let match = re.exec(text);
  while (match) {
    if (match.index > start) paragraphs.push({ text: text.substring(start, match.index), start, end: match.index });
    start = match.index + match[0].length;
    match = re.exec(text);
  }
  if (start < text.length) paragraphs.push({ text: text.substring(start), start, end: text.length });
  return paragraphs;
};
const paragraphHeightPx = (text) => Math.max(1, Math.ceil(text.length / CHARS_PER_LINE)) * LINE_HEIGHT_PX;
const measureTextHeightPx = (text) => splitParagraphs(text)
  .reduce((height, paragraph, index) => height + (index > 0 ? PARAGRAPH_BOUNDARY_PX : 0) +
    paragraphHeightPx(paragraph.text), 0);

// findMeasuredPageEnd 的桩：与真实实现一样，空间不足时仍至少前进一行。
function findTextPageEnd(source, start, availableHeightPx) {
  let safeStart = start;
  while (safeStart < source.length && isTrimChar(source.charAt(safeStart))) safeStart++;
  if (safeStart >= source.length) return source.length;
  let used = 0;
  let end = safeStart;
  const paragraphs = splitParagraphs(source.substring(safeStart));
  for (let index = 0; index < paragraphs.length; index++) {
    const paragraph = paragraphs[index];
    const boundary = index > 0 ? PARAGRAPH_BOUNDARY_PX : 0;
    const height = paragraphHeightPx(paragraph.text);
    if (used + boundary + height <= availableHeightPx) {
      used += boundary + height;
      end = safeStart + paragraph.end;
      continue;
    }
    const lines = Math.floor((availableHeightPx - used - boundary) / LINE_HEIGHT_PX);
    if (lines >= 1) return safeStart + paragraph.start + Math.min(paragraph.text.length, lines * CHARS_PER_LINE);
    break;
  }
  return end > safeStart ? end : safeStart + Math.min(CHARS_PER_LINE, source.length - safeStart);
}

const leftoverPx = (pageText) => {
  const paragraphs = splitParagraphs(pageText);
  const image = paragraphs.map((paragraph) => isMarker(paragraph.text.trim()));
  const textPx = measureTextHeightPx(paragraphs.filter((_, index) => !image[index])
    .map((paragraph) => paragraph.text).join('\n'));
  let boundaryPx = 0;
  for (let index = 0; index < paragraphs.length - 1; index++) {
    if (image[index] || image[index + 1]) boundaryPx += PARAGRAPH_BOUNDARY_PX;
  }
  return VIEWPORT_PX - textPx - boundaryPx;
};

const host = new ReaderMixedPageHost();
host.availableWidthPx = WIDTH_PX;
host.availableHeightPx = VIEWPORT_PX;
host.minImageHeightPx = MIN_IMAGE_PX;
host.pxPerVp = PX_PER_VP;
host.isTrimChar = isTrimChar;
host.findTextPageEnd = (source, start, availableHeightPx) => {
  const marker = source.indexOf(ReaderImageMarker.PREFIX, start);
  return findTextPageEnd(marker < 0 ? source : source.substring(0, marker), start, availableHeightPx);
};
host.measureTextHeightPx = (source, start, end) => measureTextHeightPx(source.substring(start, end).trim());
host.boundaryPx = () => PARAGRAPH_BOUNDARY_PX;
host.isIndependentParagraph = (text) => isMarker(text.trim());
host.leftoverPx = leftoverPx;

// 对应 paginateReaderImageSourceText + pushReaderPage
function paginate(source) {
  const pages = [];
  const starts = [];
  const ends = [];
  let cursor = 0;
  let guard = 0;
  while (cursor < source.length) {
    if (++guard > 10000) throw new Error('分页没有前进');
    const end = ReaderMixedPageLayout.findPageEnd(source, cursor, host);
    if (end <= cursor) break;
    let pageStart = cursor;
    let pageEnd = Math.min(end, source.length);
    while (pageStart < pageEnd && isTrimChar(source.charAt(pageStart))) pageStart++;
    while (pageEnd > pageStart && isTrimChar(source.charAt(pageEnd - 1))) pageEnd--;
    if (pageEnd > pageStart) {
      pages.push(source.substring(pageStart, pageEnd));
      starts.push(pageStart);
      ends.push(pageEnd);
    }
    cursor = end;
  }
  return { pages, starts, ends };
}

const markersOf = (page) => splitParagraphs(page).map((paragraph) => paragraph.text.trim()).filter(isMarker);
const boxesOf = (page) => ReaderMixedPageLayout.imageBoxes(markersOf(page), leftoverPx(page), host);
// 渲染后的页面总高度：文字 + 间距 + 各图片盒子。
const renderedHeightPx = (page) => VIEWPORT_PX - leftoverPx(page) +
  boxesOf(page).reduce((sum, box) => sum + box.heightPx, 0);

let failures = 0;
const check = (condition, message, detail = '') => {
  if (condition) {
    console.log(`  ok - ${message}`);
  } else {
    failures++;
    console.error(`  FAIL - ${message}${detail ? `\n         ${detail}` : ''}`);
  }
};

// ---- 夹具：图片尺寸为原始像素 ----
const sizes = {
  'cover.jpg': [1200, 1800], 'illus.jpg': [800, 1200], 'wide.jpg': [1600, 900], 'divider.png': [600, 40],
  'icon.png': [96, 96], 'figure.png': [300, 200],
};
const resolve = (src) => {
  const ref = new EpubImageRef();
  ref.path = `/book/${src}`;
  if (sizes[src]) {
    ref.width = sizes[src][0];
    ref.height = sizes[src][1];
  }
  return ref;
};
const content = (body) => EpubHtmlConverter.convertBody(body, resolve).content;
const para = (chars) => `<p>${'文'.repeat(chars)}</p>`;
const describe = (pages) => pages.map((page) => `[${splitParagraphs(page)
  .map((paragraph) => (isMarker(paragraph.text.trim()) ? 'IMG' : `T${paragraph.text.length}`)).join(' ')}]`).join(' ');

function invariants(name, source, result) {
  const { pages, starts, ends } = result;
  check(pages.length > 0, `${name}：产出 ${pages.length} 页`, describe(pages));
  let ordered = true;
  for (let index = 0; index < pages.length; index++) {
    if (ends[index] <= starts[index] || (index > 0 && starts[index] < ends[index - 1])) ordered = false;
  }
  check(ordered, `${name}：页边界有内容、不重叠`);
  const total = source.split(ReaderImageMarker.PREFIX).length - 1;
  check(pages.reduce((sum, page) => sum + markersOf(page).length, 0) === total, `${name}：所有图片都被分页覆盖`);
  check(pages.join('').replace(/\s/g, '') === source.replace(/\s/g, ''), `${name}：正文无丢失、无重复`);
  const overflow = pages.map(renderedHeightPx).filter((height) => height > VIEWPORT_PX + 1);
  check(overflow.length === 0, `${name}：每页渲染高度不超过页高`, `overflow=${overflow.join(',')} ${describe(pages)}`);
}

try {
  // 1. 封面页：标题 + 作者 + 封面图同页，简介从下一页开始（整页插图结束当前页）。
  const intro = content(`<h1>书名</h1><p>作者</p><img src="cover.jpg"/>${para(200)}${para(300)}`);
  const introResult = paginate(intro);
  invariants('封面页', intro, introResult);
  check(markersOf(introResult.pages[0]).length === 1 && introResult.pages[0].startsWith('书名') &&
    !introResult.pages[0].includes('文'), '封面页：标题与封面同页，简介不挤进封面页', describe(introResult.pages));
  check(boxesOf(introResult.pages[0])[0].fill && boxesOf(introResult.pages[0])[0].heightPx > VIEWPORT_PX * 0.8,
    '封面页：封面填满标题之外的空间');

  // 2. 插图章：页眉与第一张图同页，之后每图一页。
  const gallery = content(`<p>第一卷 插图</p>${'<img src="illus.jpg"/>'.repeat(13)}`);
  const galleryResult = paginate(gallery);
  invariants('插图章', gallery, galleryResult);
  check(galleryResult.pages.length === 13 && galleryResult.pages.every((page) => markersOf(page).length === 1),
    '插图章：13 张整页插图各占一页', describe(galleryResult.pages));

  // 3. 分隔线、小图随文排版：不再独占一页，后面的文字接在同一页。
  const flow = content(`${para(120)}<img src="divider.png"/>${para(120)}<p>图标<img src="icon.png"/></p>` +
    `<img src="figure.png"/>${para(100)}`);
  const flowResult = paginate(flow);
  invariants('随文小图', flow, flowResult);
  check(flowResult.pages.length === 1 && markersOf(flowResult.pages[0]).length === 3,
    '随文小图：三张小图与前后文字排在同一页', describe(flowResult.pages));
  const flowBoxes = boxesOf(flowResult.pages[0]);
  check(flowBoxes.every((box) => !box.fill) && flowBoxes[0].widthPx === WIDTH_PX &&
    Math.round(flowBoxes[0].heightPx) === 72 && flowBoxes[1].widthPx === 288 && flowBoxes[1].heightPx === 288,
    '随文小图：按原始尺寸显示，超宽时等比缩到栏宽', JSON.stringify(flowBoxes));

  // 4. 整页插图前只剩很少空间：插图移到下一页，而不是被压扁或溢出页脚。
  const tight = content(`${para(24 * 40)}<img src="illus.jpg"/>${para(60)}`);
  const tightResult = paginate(tight);
  invariants('空间不足', tight, tightResult);
  check(tightResult.pages.length === 3 && markersOf(tightResult.pages[0]).length === 0 &&
    tightResult.pages[1].trim() === markersOf(tightResult.pages[1])[0],
    '空间不足：插图独占下一页', describe(tightResult.pages));

  // 5. 小图放不下时整体移到下一页开头，后面的文字接着排。
  const carry = content(`${para(24 * 44)}<img src="figure.png"/>${para(60)}`);
  const carryResult = paginate(carry);
  invariants('小图换页', carry, carryResult);
  check(carryResult.pages.length === 2 && markersOf(carryResult.pages[0]).length === 0 &&
    isMarker(splitParagraphs(carryResult.pages[1])[0].text.trim()) && carryResult.pages[1].includes('文'),
    '小图换页：小图在下一页开头，其后文字同页', describe(carryResult.pages));

  // 6. 小图后的文字放不下一行时不硬塞（文本分页器在空间不足时也会前进一行）。
  const squeeze = content(`${para(24 * 39)}<img src="figure.png"/>${para(24 * 6)}`);
  const squeezeResult = paginate(squeeze);
  invariants('图后文字', squeeze, squeezeResult);

  // 7. 横图：高度不足页高 40% 时随文，否则按整页插图处理。
  const wideBox = ReaderMixedPageLayout.naturalBox(ReaderImageMarker.create('/book/wide.jpg', 1600, 900), host);
  check(wideBox.widthPx === WIDTH_PX && Math.round(wideBox.heightPx) === 608 && !wideBox.fill,
    '横图：缩到栏宽后高度不足页高 40%，随文排版', JSON.stringify(wideBox));
  const tallBox = ReaderMixedPageLayout.naturalBox(ReaderImageMarker.create('/book/illus.jpg', 800, 1200), host);
  check(tallBox.fill, '竖版插图：按整页插图处理');

  // 8. 不带尺寸的旧标记：保持原有行为（填满剩余空间并结束当前页），但不再溢出。
  const legacy = `标题\n\n${ReaderImageMarker.create('/book/unknown.jpg')}\n\n${'文'.repeat(300)}`;
  const legacyResult = paginate(legacy);
  invariants('无尺寸标记', legacy, legacyResult);
  check(markersOf(legacyResult.pages[0]).length === 1 && !legacyResult.pages[0].includes('文'),
    '无尺寸标记：图片结束当前页', describe(legacyResult.pages));
  const legacyTight = `${'文'.repeat(24 * 44)}\n\n${ReaderImageMarker.create('/book/unknown.jpg')}`;
  const legacyTightResult = paginate(legacyTight);
  invariants('无尺寸标记（空间不足）', legacyTight, legacyTightResult);
  check(legacyTightResult.pages.length === 2, '无尺寸标记（空间不足）：图片移到下一页', describe(legacyTightResult.pages));

  // 9. 纯文本与边界输入。
  const plain = content(para(24 * 100));
  invariants('纯文本', plain, paginate(plain));
  check(paginate('').pages.length === 0 && paginate('\n\n  \n').pages.length === 0, '空输入不产生页面');
  const broken = `正文\n\n${ReaderImageMarker.PREFIX}broken`;
  check(paginate(broken).pages.length >= 1, '损坏的标记不会造成死循环');

  // 10. 增量分页（每次只取一页）与一次性分页一致。
  const mixed = content(`<h1>章</h1>${para(500)}<img src="illus.jpg"/>${para(900)}<img src="divider.png"/>` +
    `${para(700)}<img src="figure.png"/><img src="cover.jpg"/>${para(50)}`);
  const mixedResult = paginate(mixed);
  invariants('综合', mixed, mixedResult);
  const incremental = [];
  let cursor = 0;
  while (cursor < mixed.length) {
    const end = ReaderMixedPageLayout.findPageEnd(mixed, cursor, host);
    if (end <= cursor) break;
    const text = mixed.substring(cursor, end).trim();
    if (text) incremental.push(text);
    cursor = end;
  }
  check(JSON.stringify(incremental) === JSON.stringify(mixedResult.pages.map((page) => page.trim())),
    '增量分页与一次性分页结果一致');
} finally {
  cleanup();
}

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
