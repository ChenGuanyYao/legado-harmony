import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const moduleUrl = pathToFileURL(
  path.join(root, 'entry', 'src', 'main', 'ets', 'opds', 'OpdsKavita.ts')).href;
const { OpdsKavita } = await import(moduleUrl);

let assertions = 0;

function assertEquals(actual, expected, label) {
  assertions++;
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`${label}\n    实际: ${actualJson}\n    期望: ${expectedJson}`);
  }
}

// ---- OPDS 地址识别与站点地址还原 ----
assertEquals(OpdsKavita.isOpdsUrl('http://nas.example.com:5000/api/opds/abc-123'), true, 'opds: 标准地址');
assertEquals(OpdsKavita.isOpdsUrl('https://example.com/kavita/api/opds/abc/libraries?pageNumber=2'), true,
  'opds: 子路径部署 + 下级目录');
assertEquals(OpdsKavita.isOpdsUrl('http://nas.example.com:5000/'), false, 'opds: 网页根地址不是');
assertEquals(OpdsKavita.isOpdsUrl('http://nas.example.com:5000/api/opds'), false, 'opds: 缺密钥不是');
assertEquals(OpdsKavita.isOpdsUrl('http://calibre.example.com:8080/opds'), false, 'opds: 其他书库不是');
assertEquals(OpdsKavita.siteOfOpdsUrl('http://nas.example.com:5000/api/opds/abc-123'),
  'http://nas.example.com:5000', 'site: 标准地址');
assertEquals(OpdsKavita.siteOfOpdsUrl('https://example.com/kavita/api/opds/abc/series/3'),
  'https://example.com/kavita', 'site: 保留反向代理子路径');
assertEquals(OpdsKavita.siteOfOpdsUrl('http://nas.example.com:5000/'), '', 'site: 非 OPDS 地址返回空');

// ---- 登录接口候选站点 ----
assertEquals(OpdsKavita.siteCandidates('http://nas.example.com:5000/'), ['http://nas.example.com:5000'],
  'candidates: 根地址只有一个');
assertEquals(OpdsKavita.siteCandidates('http://nas.example.com:5000/login?x=1#top'),
  ['http://nas.example.com:5000/login', 'http://nas.example.com:5000'], 'candidates: 页面路径后再试站点根');
assertEquals(OpdsKavita.siteCandidates('https://example.com/kavita/'),
  ['https://example.com/kavita', 'https://example.com'], 'candidates: 子路径部署优先');
assertEquals(OpdsKavita.siteCandidates('nas.example.com'), [], 'candidates: 非 http 地址');
assertEquals(OpdsKavita.loginUrl('https://example.com/kavita'), 'https://example.com/kavita/api/account/login',
  'login: 接口地址');
assertEquals(JSON.parse(OpdsKavita.loginBody('reader', 'p"a\ss')), { username: 'reader', password: 'p"a\ss' },
  'login: 请求体对特殊字符做 JSON 转义');
assertEquals(OpdsKavita.opdsUrl('http://nas.example.com:5000', 'abc-123'),
  'http://nas.example.com:5000/api/opds/abc-123', 'opds: 拼出目录地址');

// ---- 登录响应取密钥 ----
assertEquals(OpdsKavita.keyFromLoginResponse(JSON.stringify({ username: 'reader', apiKey: 'legacy-key' })),
  'legacy-key', 'key: 旧版只有 apiKey');
assertEquals(OpdsKavita.keyFromLoginResponse(JSON.stringify({
  apiKey: 'fallback',
  authKeys: [{ name: 'image-only', key: 'img' }, { name: 'opds', key: 'opds-key' }]
})), 'opds-key', 'key: 新版优先取名为 opds 的 authKey');
assertEquals(OpdsKavita.keyFromLoginResponse(JSON.stringify({
  apiKey: 'fallback', authKeys: [{ name: 'image-only', key: 'img' }, null]
})), 'fallback', 'key: 没有 opds authKey 时回落到 apiKey');
assertEquals(OpdsKavita.keyFromLoginResponse(JSON.stringify({ username: 'reader', apiKey: null })), '',
  'key: apiKey 为空');
assertEquals(OpdsKavita.keyFromLoginResponse('<html>login</html>'), '', 'key: 非 JSON 响应');
assertEquals(OpdsKavita.keyFromLoginResponse('"just a string"'), '', 'key: JSON 但不是对象');
assertEquals(OpdsKavita.keyFromLoginResponse(''), '', 'key: 空响应');

// ---- 展示时遮住密钥 ----
assertEquals(OpdsKavita.maskedUrl('http://nas.example.com:5000/api/opds/abc-123'),
  'http://nas.example.com:5000/api/opds/••••', 'mask: 遮住密钥');
assertEquals(OpdsKavita.maskedUrl('http://calibre.example.com:8080/opds/'), 'http://calibre.example.com:8080/opds/',
  'mask: 其他地址原样');

console.log(`OPDS Kavita check passed: ${assertions} assertions.`);
