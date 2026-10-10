#!/usr/bin/env node
// 图文混排里图片尺寸判定规则的回归检查：哪些图随文排版，哪些图是整页插图。
// 分页本身由 V2 原生段落引擎完成，无法在 Node 里运行，这里只覆盖它依赖的纯规则。
// Usage: node --experimental-strip-types scripts/epub-mixed-layout-check.mjs

import { loadReaderModules } from './lib/load-reader-modules.mjs';

const { ReaderMixedPageLayout: L, cleanup } = await loadReaderModules();

const WIDTH_PX = 1080;
const HEIGHT_PX = 2200;
const PX_PER_VP = 3;

let failures = 0;
function check(condition, label, detail = '') {
  if (condition) return;
  failures++;
  console.error(`FAIL ${label}${detail ? `\n  ${detail}` : ''}`);
}
const box = (width, height) => L.naturalBoxForSize(width, height, WIDTH_PX, HEIGHT_PX, PX_PER_VP);

try {
  check(box(0, 0) === null, '尺寸未知时没有原始盒子');
  check(box(300, 0) === null && box(0, 300) === null, '只有一边尺寸时按未知处理');

  const icon = box(40, 40);
  check(icon.widthPx === 120 && icon.heightPx === 120, '小图按 vp 解释原始像素', JSON.stringify(icon));
  check(icon.fill === false, '小图随文排版');

  const divider = box(600, 12);
  check(divider.widthPx === WIDTH_PX, '宽图收到版心宽度', JSON.stringify(divider));
  check(Math.abs(divider.heightPx - WIDTH_PX * 12 / 600) < 0.001, '收窄后保持宽高比');
  check(divider.fill === false, '分隔线随文排版');

  const illustration = box(800, 1200);
  check(illustration.widthPx === WIDTH_PX && illustration.fill === true, '竖幅插图是整页插图',
    JSON.stringify(illustration));

  const wide = box(1600, 900);
  check(wide.fill === false, '横幅图高度不足页高四成时随文排版', JSON.stringify(wide));

  // 判定边界：收到版心后的高度恰好达到页高的 INLINE_HEIGHT_RATIO 即算整页插图。
  const thresholdHeight = HEIGHT_PX * L.INLINE_HEIGHT_RATIO;
  const atThreshold = L.naturalBoxForSize(WIDTH_PX, thresholdHeight, WIDTH_PX, HEIGHT_PX, 1);
  const belowThreshold = L.naturalBoxForSize(WIDTH_PX, thresholdHeight - 1, WIDTH_PX, HEIGHT_PX, 1);
  check(atThreshold.fill === true && belowThreshold.fill === false, '整页插图的高度阈值');

  const tiny = L.naturalBoxForSize(1, 1, WIDTH_PX, HEIGHT_PX, 0);
  check(tiny.widthPx >= 1 && tiny.heightPx >= 1, '异常的像素比不会得到零尺寸盒子');
  check(L.FILL_MIN_RATIO > 0 && L.FILL_MIN_RATIO <= 1, '整页插图的最小压缩比例在合理范围');
} finally {
  cleanup();
}

if (failures > 0) {
  console.error(`epub-mixed-layout-check: ${failures} 项失败`);
  process.exit(1);
}
console.log('epub-mixed-layout-check: ok');
