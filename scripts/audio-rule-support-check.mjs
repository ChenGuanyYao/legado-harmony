// 有声书规则辅助模块的回归：sourceRegex（Java 方言 / 字面量 / 响应体捕获组）、
// 地址携带的请求头、跨站请求头收敛、@webjs: 识别。
// 应用代码的相对 import 不带扩展名，这里拷到临时目录补上 '.ts' 后再加载。

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const etsDir = path.join(root, 'entry', 'src', 'main', 'ets');
const MODULES = ['core/rule/JavaRegexCompat.ts', 'core/book/AudioRuleSupport.ts'];

const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'audio-rule-check-'));
let assertions = 0;

function assert(condition, message) {
  assertions++;
  if (!condition) throw new Error(message);
}

function equal(actual, expected, message) {
  assert(JSON.stringify(actual) === JSON.stringify(expected),
    `${message}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
}

try {
  for (const relative of MODULES) {
    const target = path.join(stagingDir, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, fs.readFileSync(path.join(etsDir, relative), 'utf8')
      .replace(/(from\s+['"])(\.{1,2}\/[^'"]+?)(['"])/g, (all, head, specifier, tail) =>
        /\.[a-z]+$/i.test(specifier) ? all : `${head}${specifier}.ts${tail}`));
  }
  const { AudioRuleSupport } = await import(pathToFileURL(path.join(stagingDir, MODULES[1])).href);

  // sourceRegex：空规则退回媒体扩展名，只接受 HTTP(S)。
  assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/a/1.mp3?sign=1', ''), '空规则应匹配 mp3');
  assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/a/1.M4A', ''), '扩展名不区分大小写');
  assert(!AudioRuleSupport.matchesSourceRegex('https://example.com/play/1', ''), '空规则不匹配普通页面');
  assert(!AudioRuleSupport.matchesSourceRegex('blob:https://example.com/1.mp3', ''), '只接受 HTTP(S) 地址');

  // Android 书源里的 Java 写法：内联标志、占有量词、\Q…\E。
  assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/AUDIO/1.MP3', '(?i).*\\.(mp3|m4a).*'),
    '内联标志 (?i) 应生效');
  assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/stream/abc', '.*+/stream/.*'),
    '占有量词应降级后可用');
  assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/a.b/1', '\\Qa.b\\E/\\d+'), '\\Q…\\E 应按字面量');
  // 字面量形式的 g 标志不能让第二次匹配受 lastIndex 影响。
  for (let round = 0; round < 3; round++) {
    assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/x.m3u8', '/\\.m3u8/g'), '字面量 g 标志应无状态');
  }
  assert(!AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/x.m3u8', '/\\.MP3$/'), '字面量默认区分大小写');
  // 无法编译的规则退回扩展名判断，而不是抛异常。
  assert(AudioRuleSupport.matchesSourceRegex('https://cdn.example.com/x.mp3', '(((('), '非法规则退回扩展名');
  equal(AudioRuleSupport.compileSourceRegex('(((('), null, '非法规则编译结果为 null');

  // 响应体捕获：捕获组优先，完整匹配兜底。
  equal(AudioRuleSupport.captureFromBody('{"play":"https://cdn.example.com/1.mp3","x":1}', '"play":"(.*?)"'),
    ['https://cdn.example.com/1.mp3', '"play":"https://cdn.example.com/1.mp3"'], '捕获组排在完整匹配之前');
  equal(AudioRuleSupport.captureFromBody('src=https://cdn.example.com/2.m4a ', 'https?://\\S+\\.m4a'),
    ['https://cdn.example.com/2.m4a'], '没有捕获组时取完整匹配');
  equal(AudioRuleSupport.captureFromBody('nothing here', '\\.mp3'), [], '未命中返回空');
  equal(AudioRuleSupport.captureFromBody('abc', ''), [], '空规则不扫描响应体');

  // @webjs:
  equal(AudioRuleSupport.webJsCode('@webjs: document.querySelector("audio").src '),
    'document.querySelector("audio").src', '@webjs: 取脚本');
  equal(AudioRuleSupport.webJsCode('@WebJs:player.url'), 'player.url', '前缀不区分大小写');
  equal(AudioRuleSupport.webJsCode('@js:result'), '', '@js: 不是网页脚本');
  equal(AudioRuleSupport.webJsCode('$.data.url'), '', '普通规则不是网页脚本');

  // 地址携带的请求头。
  const withHeaders = AudioRuleSupport.splitRequestOptions(
    'https://cdn.example.com/1.mp3,{"headers":{"Referer":"https://audio.example.com/","X-N":1}}');
  equal(withHeaders.url, 'https://cdn.example.com/1.mp3', '拆出地址');
  equal(withHeaders.headers, { 'Referer': 'https://audio.example.com/', 'X-N': '1' }, '拆出请求头并转字符串');
  equal(AudioRuleSupport.splitRequestOptions(
    "https://cdn.example.com/1.mp3, {'header': {'Referer': 'https://a.example.com/'}}").headers,
    { 'Referer': 'https://a.example.com/' }, '宽松引号与 header 别名');
  equal(AudioRuleSupport.splitRequestOptions(
    'https://cdn.example.com/1.mp3,{"headers":"{\\"Range\\":\\"bytes=0-\\"}"}').headers,
    { 'Range': 'bytes=0-' }, '请求头为 JSON 字符串');
  equal(AudioRuleSupport.splitRequestOptions('"https://cdn.example.com/1.mp3,{\\"headers\\":{\\"A\\":\\"b\\"}}"').headers,
    { 'A': 'b' }, 'JSON 字符串包裹的规则值');
  const plain = AudioRuleSupport.splitRequestOptions('https://cdn.example.com/a,b/1.mp3?x={1}');
  equal(plain.url, 'https://cdn.example.com/a,b/1.mp3?x={1}', '地址内的逗号和花括号不当作选项');
  equal(plain.headers, {}, '没有选项时请求头为空');
  equal(AudioRuleSupport.splitRequestOptions('{"url":"https://cdn.example.com/1.mp3"}').headers, {},
    'JSON 对象不是地址选项');
  equal(AudioRuleSupport.splitRequestOptions('https://c.example.com/1.mp3,{"headers":{"A":"x\\r\\nB: y"}}').headers,
    {}, '含换行的请求头值被丢弃');
  equal(AudioRuleSupport.joinRequestOptions('https://c.example.com/1.mp3', {}), 'https://c.example.com/1.mp3',
    '没有请求头时不追加选项');
  equal(AudioRuleSupport.splitRequestOptions(
    AudioRuleSupport.joinRequestOptions('https://c.example.com/1.mp3', { 'Referer': 'https://a.example.com/' })).headers,
    { 'Referer': 'https://a.example.com/' }, '拼接后可原样拆回');

  // 跨站收敛：凭据留在书源自己的站点，Referer/UA 保留。
  const sourceHeaders = {
    'User-Agent': 'UA', 'Referer': 'https://www.example.com/', 'Cookie': 'sid=1',
    'authorization': 'Bearer t', 'Origin': 'https://www.example.com', 'X-Token': 'k'
  };
  equal(AudioRuleSupport.scopeHeadersToMediaHost(sourceHeaders, 'https://www.example.com', 'https://audio.example.com/1.mp3'),
    sourceHeaders, '同站子域保留全部请求头');
  equal(AudioRuleSupport.scopeHeadersToMediaHost(sourceHeaders, 'https://www.example.com', 'https://cdn.other.net/1.mp3'),
    { 'User-Agent': 'UA', 'Referer': 'https://www.example.com/', 'X-Token': 'k' }, '跨站去掉站点凭据');
  equal(AudioRuleSupport.scopeHeadersToMediaHost({ 'Cookie': 'a=1' }, 'https://a.example.com.cn', 'https://b.example.com.cn/1'),
    { 'Cookie': 'a=1' }, 'com.cn 下同一注册域视为同站');
  equal(AudioRuleSupport.scopeHeadersToMediaHost({ 'Cookie': 'a=1' }, 'https://a.one.com.cn', 'https://a.two.com.cn/1'),
    {}, 'com.cn 下不同注册域视为跨站');
  equal(AudioRuleSupport.scopeHeadersToMediaHost({ 'Cookie': 'a=1' }, 'http://192.168.1.2:8080', 'http://192.168.1.3/1.mp3'),
    {}, '不同 IP 视为跨站');
  equal(AudioRuleSupport.scopeHeadersToMediaHost({ 'Cookie': 'a=1' }, '示例聚合源', 'https://cdn.example.com/1.mp3'),
    {}, '书源地址不是 URL 时按跨站处理');

  equal(AudioRuleSupport.mergeHeaders({ 'referer': 'a', 'User-Agent': 'UA' }, { 'Referer': 'b' }),
    { 'User-Agent': 'UA', 'Referer': 'b' }, '同名请求头大小写无关地覆盖');

  console.log(`audio-rule-support-check: ${assertions} assertions passed`);
} finally {
  fs.rmSync(stagingDir, { recursive: true, force: true });
}
