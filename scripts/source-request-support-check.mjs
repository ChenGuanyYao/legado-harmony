// 书源请求支撑模块的回归：Set-Cookie 拆分、相对地址解析、concurrentRate 解析、规则变量表。
// 这些模块的相对 import 不带扩展名，个别还引用了系统 API 模块；这里拷到临时目录，
// 补上 '.ts' 并替换掉与被测逻辑无关的依赖后再加载。

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { readEtsModule } from './lib/ets-module-staging.mjs';

const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'source-request-check-'));

let assertions = 0;

function equal(actual, expected, message) {
  assertions++;
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  }
}

async function load(relative, rewrite = (text) => text) {
  const target = path.join(stagingDir, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, rewrite(readEtsModule(relative)));
  return await import(pathToFileURL(target).href);
}

try {
  const { SetCookieParser } = await load('core/http/SetCookieParser.ts');
  // HttpResponse 只是类型；BookSource 只是类型；sleepMs 与解析无关。
  const { BookUrlResolver } = await load('core/book/BookUrlResolver.ts',
    (text) => text.replace(/^import \{ HttpResponse \}.*$/m, 'type HttpResponse = { url?: string };'));
  const { BookSourceRateLimiter } = await load('core/http/BookSourceRateLimiter.ts',
    (text) => text.replace(/^import \{ BookSource \}.*$/m, 'type BookSource = { concurrentRate: string, bookSourceUrl: string, bookSourceName: string };')
      .replace(/^import \{ sleepMs \}.*$/m, 'const sleepMs = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));')
      // Node 的类型剥离不支持 enum：换成等值的常量对象。
      .replace(/export enum RateLimitAcquireResult \{[\s\S]*?\n\}/,
        'export const RateLimitAcquireResult = { Acquired: 0, Cancelled: 1, RateLimited: 2 };')
      .replace(/Promise<RateLimitAcquireResult>/g, 'Promise<number>'));
  const { RuleContext } = await load('core/rule/RuleContext.ts');

  // ---- Set-Cookie 拆分 ----
  equal(SetCookieParser.split('sid=abc; Expires=Thu, 01 Jan 2030 00:00:00 GMT; Path=/; HttpOnly'),
    ['sid=abc; Expires=Thu, 01 Jan 2030 00:00:00 GMT; Path=/; HttpOnly'], '日期里的逗号不拆分 Cookie');
  equal(SetCookieParser.split('a=1; Expires=Thu, 01 Jan 2030 00:00:00 GMT; Path=/, b=2; Max-Age=60; Secure'),
    ['a=1; Expires=Thu, 01 Jan 2030 00:00:00 GMT; Path=/', 'b=2; Max-Age=60; Secure'], '多条 Set-Cookie 按逗号拆开');
  equal(SetCookieParser.split('a=1,b=2'), ['a=1', 'b=2'], '紧凑的多条 Cookie');
  equal(SetCookieParser.split('token=xyz; deviceId=42; theme=dark'), ['token=xyz', 'deviceId=42', 'theme=dark'],
    'Cookie 请求头形式逐个拆出');
  equal(SetCookieParser.split('token=xyz; Path=/; deviceId=42; HttpOnly'), ['token=xyz; Path=/', 'deviceId=42; HttpOnly'],
    '属性留在各自的 Cookie 上');
  equal(SetCookieParser.split('v="a,b=c"; Path=/'), ['v="a,b=c"; Path=/'], '引号内的逗号不拆分');
  equal(SetCookieParser.split('list=1,2,3; Path=/'), ['list=1,2,3; Path=/'], '值里的逗号后面不是 name= 时不拆分');
  equal(SetCookieParser.split(''), [], '空输入');

  // ---- 相对地址 ----
  equal(BookUrlResolver.resolve('list.html', 'https://example.com'), 'https://example.com/list.html',
    '书源地址不带路径时，相对路径落在站点根目录');
  equal(BookUrlResolver.resolve('list.html', 'https://example.com/'), 'https://example.com/list.html', '带尾斜杠的根地址');
  equal(BookUrlResolver.resolve('list.html', 'https://example.com?x=1'), 'https://example.com/list.html',
    '不带路径但带查询的基地址');
  equal(BookUrlResolver.resolve('c.html', 'https://example.com/a/b.html?x=1'), 'https://example.com/a/c.html',
    '普通相对路径取所在目录');
  equal(BookUrlResolver.resolve('../x/y.html', 'https://example.com/a/b/c.html'), 'https://example.com/a/x/y.html',
    '../ 被折叠');
  equal(BookUrlResolver.resolve('./y.html?k=../v', 'https://example.com/a/b/c.html'),
    'https://example.com/a/b/y.html?k=../v', './ 被折叠，查询串原样保留');
  equal(BookUrlResolver.resolve('../../../z', 'https://example.com/a/b.html'), 'https://example.com/z',
    '越过根目录的 ../ 停在根目录');
  equal(BookUrlResolver.resolve('/a/./b/../c', 'https://example.com/x/y'), 'https://example.com/a/c',
    '根相对地址里的点段也折叠');
  equal(BookUrlResolver.resolve('..', 'https://example.com/a/b/c.html'), 'https://example.com/a/', '末尾的 .. 保留目录斜杠');
  equal(BookUrlResolver.resolve('/book/1', 'https://example.com/a/b'), 'https://example.com/book/1', '根相对地址');
  equal(BookUrlResolver.resolve('?page=2', 'https://example.com/read.php?name=a&page=1'),
    'https://example.com/read.php?page=2', '查询相对地址保留文档路径');
  equal(BookUrlResolver.resolve('#p2', 'https://example.com/a?x=1#p1'), 'https://example.com/a?x=1#p2', '片段相对地址');
  equal(BookUrlResolver.resolve('//cdn.example.com/a.jpg', 'https://example.com'), 'https://cdn.example.com/a.jpg',
    '协议相对地址');
  equal(BookUrlResolver.resolve('HTTPS://Example.com/a', 'https://other.example'), 'HTTPS://Example.com/a',
    '协议大小写不影响绝对地址判断');
  equal(BookUrlResolver.resolve('https://example.com/a/../b', 'https://example.com'), 'https://example.com/a/../b',
    '绝对地址原样返回');
  equal(BookUrlResolver.resolve('a.html', ''), 'a.html', '没有基地址时原样返回');

  // ---- concurrentRate ----
  equal(BookSourceRateLimiter.parse('20/60000'), { limit: 20, windowMs: 60000 }, '次数/窗口');
  equal(BookSourceRateLimiter.parse(' 5 / 1000 '), { limit: 5, windowMs: 1000 }, '容忍空白');
  equal(BookSourceRateLimiter.parse('1000'), { limit: 1, windowMs: 1000 }, '纯数字是请求间隔');
  equal(BookSourceRateLimiter.parse('50'), { limit: 1, windowMs: 50 }, '短间隔不被抬高到窗口下限');
  equal(BookSourceRateLimiter.parse('0'), null, '0 表示不限流');
  equal(BookSourceRateLimiter.parse(''), null, '空值不限流');
  equal(BookSourceRateLimiter.parse('abc'), null, '无法识别时不限流');
  equal(BookSourceRateLimiter.parse('99999999'), { limit: 1, windowMs: 3600000 }, '间隔最长一小时');

  // 间隔形式真的会让第二个请求等待；书源标识是内置属性名时也不出错。
  const source = { concurrentRate: '120', bookSourceUrl: 'constructor', bookSourceName: '' };
  const startedAt = Date.now();
  equal(await BookSourceRateLimiter.acquire(source), 0, '第一个请求立即放行');
  equal(await BookSourceRateLimiter.acquire(source), 0, '第二个请求等待后放行');
  assertions++;
  if (Date.now() - startedAt < 100) throw new Error('间隔形式没有让第二个请求等待');
  equal(await BookSourceRateLimiter.acquire(source, () => true), 1, '已取消的等待不占用名额');

  // ---- 规则变量表 ----
  const context = new RuleContext();
  equal(context.get('constructor'), '', '内置属性名不是变量');
  equal(context.has('toString'), false, '内置属性名不算已有变量');
  context.put('constructor', 'x');
  equal(context.get('constructor'), 'x', '内置属性名可以当普通变量用');
  context.loadFromJson('{"__proto__":{"polluted":"1"},"bookId":"7"}');
  equal(context.get('bookId'), '7', '从 JSON 载入变量');
  equal(context.get('polluted'), '', '__proto__ 键不会变成继承来的变量');
  equal({}.polluted, undefined, '全局原型不受影响');
  context.loadFromJson('"abc"');
  equal(context.get('0'), '', '非对象 JSON 不会展开成下标变量');
  context.loadFromJson('not json');
  equal(JSON.parse(context.toJson()).bookId, '7', '序列化保留已有变量');
  context.put('source.jsLib', 'lib');
  equal('source.jsLib' in context.toPersistentRecord(), false, '持久化结果不含每次重新注入的书源字段');
  equal(context.toRecord().bookId, '7', 'toRecord 返回普通对象');

  console.log(`source-request-support-check: ${assertions} assertions passed`);
} finally {
  fs.rmSync(stagingDir, { recursive: true, force: true });
}
