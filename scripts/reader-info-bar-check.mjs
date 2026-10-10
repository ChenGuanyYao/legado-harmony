#!/usr/bin/env node
// 页眉页脚槽位配置的回归检查：旧设置迁移后显示不变、损坏配置能回退、
// 槽位文字与进度计算正确，以及只有影响高度的项才会改变分页标识。
// Usage: node --experimental-strip-types scripts/reader-info-bar-check.mjs

import { loadReaderModules } from './lib/load-reader-modules.mjs';

const { ReaderInfoBarConfig: Config, ReaderInfoBarContext, ReaderInfoBarText: T, ReaderInfoItem: Item,
  ReaderInfoProgressBar: Bar, cleanup } = await loadReaderModules();

let failures = 0;
function check(condition, label, detail = '') {
  if (condition) return;
  failures++;
  console.error(`FAIL ${label}${detail ? `\n  ${detail}` : ''}`);
}
function equal(actual, expected, label) {
  check(actual === expected, label, `期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`);
}

check(Item.VALUES.length === Item.LABELS.length, '信息项的值与名称一一对应');
check(new Set(Item.VALUES).size === Item.VALUES.length, '信息项的值不重复');

// 旧设置迁移：默认值。
const defaults = Config.fromLegacy('chapter', 'chapter', 'page', false);
equal(defaults.headerLeft, Item.CHAPTER_TITLE, '旧默认页眉 → 章节标题');
equal(defaults.footerLeft, Item.CHAPTER_INDEX_TITLE, '旧默认页脚左侧 → 章节序号 + 标题');
equal(defaults.footerRight, Item.PAGE, '旧默认阅读进度 → 页码');
equal(defaults.progressBar, Bar.NONE, '旧默认不显示进度条');
equal(defaults.serialize(), new Config().serialize(), '旧默认值迁移结果等于新默认配置');

// 旧设置迁移：非默认值。
const migrated = Config.fromLegacy('book_chapter', 'title', 'book', true);
equal(migrated.headerLeft, Item.BOOK_CHAPTER, '旧页眉"书名 + 章节标题"');
equal(migrated.footerLeft, Item.CHAPTER_TITLE, '旧页脚左侧"章节标题"');
equal(migrated.footerRight, Item.BOOK_PERCENT, '旧阅读进度"全书进度"');
equal(migrated.progressBar, Bar.FOOTER, '旧进度条开关 → 页脚上方');
equal(migrated.progressScope, Bar.SCOPE_BOOK, '旧全书进度模式下进度条表示全书');
equal(Config.fromLegacy('none', 'none', 'none', false).headerVisible(), false, '旧页眉"不显示"时页眉不占位');
equal(Config.fromLegacy('chapter', 'chapter', 'percentage', false).footerRight, Item.CHAPTER_PERCENT,
  '旧阅读进度"阅读百分比"');
equal(Config.fromLegacy('chapter', 'chapter', 'chapter', false).footerRight, Item.CHAPTER_PROGRESS,
  '旧阅读进度"章节进度"');

// 解析与回退。
equal(Config.parse(''), null, '空字符串解析为 null');
equal(Config.parse('{oops'), null, '损坏的 JSON 解析为 null');
const roundTrip = Config.parse(migrated.serialize());
equal(roundTrip.serialize(), migrated.serialize(), '序列化后再解析结果不变');
const dirty = Config.parse(JSON.stringify({ headerLeft: 'bogus', fontSize: 99, opacity: 1, progressBar: 'x' }));
equal(dirty.headerLeft, Item.CHAPTER_TITLE, '未知信息项回退到默认');
equal(dirty.fontSize, Config.FONT_SIZE_MAX, '字号被限制在上限');
equal(dirty.opacity, Config.OPACITY_MIN, '不透明度被限制在下限');
equal(dirty.progressBar, Bar.NONE, '未知进度条位置回退到不显示');

// 分页标识：换内容不变，换高度相关项才变。
const base = new Config();
const contentOnly = base.copy();
contentOnly.headerRight = Item.TIME;
contentOnly.footerCenter = Item.BATTERY;
contentOnly.opacity = 60;
contentOnly.followMargin = true;
equal(contentOnly.layoutIdentity(), base.layoutIdentity(), '只换内容与外观不改变分页标识');
const bigger = base.copy();
bigger.fontSize = 14;
check(bigger.layoutIdentity() !== base.layoutIdentity(), '字号变化改变分页标识');
const withBar = base.copy();
withBar.progressBar = Bar.FOOTER;
check(withBar.layoutIdentity() !== base.layoutIdentity(), '进度条变化改变分页标识');
equal(base.headerLineHeight(), 18, '默认字号下页眉行高保持 18');
equal(base.footerExtraHeight(), 0, '默认配置页脚没有附加高度');
equal(withBar.footerExtraHeight(), 5, '页脚进度条附加高度保持 5');

// 时钟需求。
equal(base.usesClock(true, true), false, '默认配置不需要时钟');
equal(contentOnly.usesClock(true, false), true, '页眉用到时间时需要时钟');
equal(contentOnly.usesClock(false, false), false, '页眉页脚都关闭时不需要时钟');

// 槽位文字。
const context = new ReaderInfoBarContext();
context.bookName = '三体';
context.author = '刘慈欣';
context.chapterTitle = '第三章 红岸';
context.chapterIndex = 2;
context.chapterCount = 10;
context.pageIndex = 4;
context.pageCount = 20;
context.timeText = '21:05';
context.batteryPercent = 76;
equal(T.of(Item.NONE, context), '', '不显示');
equal(T.of(Item.BOOK, context), '三体', '书名');
equal(T.of(Item.AUTHOR, context), '刘慈欣', '作者');
equal(T.of(Item.CHAPTER_TITLE, context), '第三章 红岸', '章节标题');
equal(T.of(Item.CHAPTER_INDEX_TITLE, context), '3/10 第三章 红岸', '章节序号 + 标题');
equal(T.of(Item.BOOK_CHAPTER, context), '三体 · 第三章 红岸', '书名 + 章节标题');
equal(T.of(Item.PAGE, context), '5/20', '页码');
equal(T.of(Item.PAGES_LEFT, context), '剩余 15 页', '本章剩余页数');
equal(T.of(Item.CHAPTER_PERCENT, context), '25%', '本章百分比');
equal(T.of(Item.CHAPTER_PROGRESS, context), '3/10 章', '章节进度');
equal(T.of(Item.BOOK_PERCENT, context), '22.5%', '全书百分比包含章内进度');
equal(T.of(Item.TIME, context), '21:05', '时间');
equal(T.of(Item.BATTERY, context), '76%', '电量');
equal(T.leading(Item.BATTERY, context), '', '电量项没有前置文字');
equal(T.leading(Item.TIME_BATTERY, context), '21:05', '时间 + 电量的前置文字是时间');
equal(T.battery(Item.TIME_BATTERY, context), 76, '时间 + 电量需要画电池');
equal(T.battery(Item.PAGE, context), -1, '非电量项不画电池');

context.doublePage = true;
equal(T.of(Item.PAGE, context), '5-6/20', '双页页码');
equal(T.of(Item.PAGES_LEFT, context), '剩余 14 页', '双页剩余页数');
context.doublePage = false;

context.chapterIndex = 9;
context.pageIndex = 19;
equal(T.bookPercent(context), 100, '最后一章最后一页为 100%');
context.pageCount = 0;
context.pageIndex = 0;
equal(T.of(Item.PAGE, context), '1/1', '尚未分页时页码为 1/1');
context.batteryPercent = -1;
equal(T.battery(Item.BATTERY, context), -1, '读不到电量时不画电池');
context.chapterCount = 0;
equal(T.of(Item.CHAPTER_INDEX_TITLE, context), '三体', '没有目录时显示书名');

cleanup();

if (failures > 0) {
  console.error(`reader-info-bar-check: ${failures} 项失败`);
  process.exit(1);
}
console.log('reader-info-bar-check: ok');
