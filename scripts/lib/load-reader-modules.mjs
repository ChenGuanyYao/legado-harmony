// 把 entry 下与系统 API 无关的纯 TS 阅读器模块加载进 Node。
// node --experimental-strip-types 要求相对 import 带扩展名，而应用代码遵循 ArkTS 惯例不带后缀：
// 这里把文件拷到临时目录并补上 '.ts' 后再加载，应用源码保持规范写法不变。

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const etsDir = path.join(root, 'entry', 'src', 'main', 'ets');

const MODULES = [
  'core/book/ReaderImageMarker.ts',
  'core/book/EpubHtmlConverter.ts',
  'core/book/EpubChapterPlanner.ts',
  'core/reader/ReaderMixedPageLayout.ts',
];

export async function loadReaderModules() {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'reader-modules-check-'));
  const cleanup = () => fs.rmSync(stagingDir, { recursive: true, force: true });
  try {
    const exported = {};
    for (const relative of MODULES) {
      const sourcePath = path.join(etsDir, relative);
      if (!fs.existsSync(sourcePath)) continue;
      const target = path.join(stagingDir, relative);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      const text = fs.readFileSync(sourcePath, 'utf8')
        .replace(/(from\s+['"])(\.{1,2}\/[^'"]+?)(['"])/g, (all, head, specifier, tail) =>
          /\.[a-z]+$/i.test(specifier) ? all : `${head}${specifier}.ts${tail}`);
      fs.writeFileSync(target, text);
    }
    for (const relative of MODULES) {
      const target = path.join(stagingDir, relative);
      if (!fs.existsSync(target)) continue;
      Object.assign(exported, await import(pathToFileURL(target).href));
    }
    return { ...exported, cleanup };
  } catch (error) {
    cleanup();
    throw error;
  }
}
