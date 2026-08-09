# Legado Harmony 书源开发文档

> 适用范围：`legado-harmony` `3.5.806` 当前书源实现（2026-08-03 工作区）。
> 本文描述的是本项目**已经实现并实际调用**的规则，而不是 Android「阅读」全部规则的等价清单。导入其他项目的书源时，应特别留意[兼容性与当前限制](#13-兼容性与当前限制)。

## 1. 书源是什么

书源是一份 JSON 配置。它告诉应用：

1. 去哪里搜索书籍；
2. 如何从搜索或发现响应中找出每一本书；
3. 如何打开详情页并提取书籍信息和目录地址；
4. 如何从目录响应中提取章节；
5. 如何请求章节并提取、净化正文。

一条书源的典型数据流如下：

```text
搜索地址 / 发现地址
  -> HTTP 响应
  -> bookList 选出“书籍元素”
  -> 在每个元素内解析 name / author / bookUrl 等
  -> 请求 bookUrl
  -> init 可选地缩小详情解析范围
  -> 解析详情字段和 tocUrl
  -> 请求 tocUrl
  -> chapterList 选出“章节元素”
  -> 在每个元素内解析 chapterName / chapterUrl
  -> 请求 chapterUrl
  -> content / images 提取正文、漫画图片或音频地址
  -> replaceRegex 净化
  -> 交互后处理（可选：段评、本章说、图片、视频/媒体动作）
  -> 文本阅读 / 漫画阅读 / 有声书播放
```

书源可以使用 `data:`/Base64 地址承载文本或显式请求元数据。应用只解码书源给出的值，或执行其中明确声明的 HTTP(S) 请求；不会选择镜像、补造第三方接口或执行站点专用解密。普通 HTTP/HTML/JSON 书源沿用同一通用解析路径。

这里最重要的概念是“当前元素”：

- `bookList`、`chapterList` 在完整响应上运行，返回多个元素；
- 书名、作者、章节名等子规则分别在单个元素上运行；
- JSON 元素会被序列化为 JSON 字符串，HTML 元素会保留该元素的完整 HTML；
- 所以子规则通常从 `$.字段` 或元素内部的 CSS 选择器开始，而不必重复列表的完整路径。

## 2. 最小可用书源

下面是一个 JSON API 书源骨架。实际开发时优先从这种小配置开始，先跑通“搜索 → 详情 → 目录 → 正文”，再补发现和可选字段。

```json
[
  {
    "bookSourceName": "示例小说",
    "bookSourceGroup": "API",
    "bookSourceUrl": "https://api.example.com",
    "enabled": true,
    "enabledExplore": true,
    "header": "{\"User-Agent\":\"Mozilla/5.0\"}",
    "searchUrl": "/search?keyword={{key}}&page={{page}}",
    "exploreUrl": "热门::/books/hot?page={{page}}",
    "ruleSearch": {
      "bookList": "$.data.books[*]",
      "name": "$.title",
      "author": "$.author",
      "coverUrl": "$.cover",
      "intro": "$.intro",
      "kind": "$.category",
      "lastChapter": "$.lastChapter",
      "bookUrl": "/book/{{$.id}}",
      "wordCount": "$.wordCount"
    },
    "ruleExplore": {
      "bookList": "$.data.books[*]",
      "name": "$.title",
      "author": "$.author",
      "coverUrl": "$.cover",
      "intro": "$.intro",
      "kind": "$.category",
      "lastChapter": "$.lastChapter",
      "bookUrl": "/book/{{$.id}}",
      "wordCount": "$.wordCount"
    },
    "ruleBookInfo": {
      "init": "$.data",
      "name": "$.title",
      "author": "$.author",
      "coverUrl": "$.cover",
      "intro": "$.intro",
      "kind": "$.category",
      "lastChapter": "$.lastChapter",
      "wordCount": "$.wordCount",
      "updateTime": "$.updateTime",
      "tocUrl": "/book/{{$.id}}/chapters"
    },
    "ruleToc": {
      "chapterList": "$.data.chapters[*]",
      "chapterName": "$.title",
      "chapterUrl": "/chapter/{{$.id}}",
      "isVip": "$.isVip",
      "isPay": "$.isPay",
      "updateTime": "$.updateTime"
    },
    "ruleContent": {
      "content": "$.data.content",
      "replaceRegex": "本章未完，请点击下一页继续阅读"
    }
  }
]
```

搜索阶段目前固定使用第 1 页，因此 `{{page}}` 在搜索地址中为 `1`；发现页会传入实际页码。

## 3. JSON 顶层结构与导入格式

应用支持四种常见导入外壳：

```json
[{ "bookSourceUrl": "...", "bookSourceName": "..." }]
```

```json
{ "value": [{ "bookSourceUrl": "...", "bookSourceName": "..." }] }
```

```json
{ "bookSourceUrl": "...", "bookSourceName": "..." }
```

以及剪贴板或分享文本中的 HTTP/HTTPS 导入地址。URL 导入不是简单调用一次下载接口，而是按顺序尝试：

1. 应用 HTTP 客户端（含 HTTPS 候选和响应大小限制）；
2. 明文 HTTP 的受控 TCP 兜底；
3. ArkWeb 下载回调；
4. HarmonyOS 系统下载服务。

每一层都会先校验响应确实是 JSON 对象或数组，错误信息会尽量保留 HTTP、网络或下载服务原因，而不是显示 `[object Object]`。导入对话框提交后会主动收起键盘。

只有同时具有 `bookSourceUrl` 和 `bookSourceName` 的项目才会被写入数据库。`bookSourceUrl` 也是书源的唯一身份标识；修改它通常会被视为另一个书源。导入后会重新读取数据库并核对原始 JSON、脚本库、登录配置、各规则组和运行字段，避免“提示成功但复杂字段被截断或漏存”。

应用同时保存导入对象的完整 `rawSourceJson`。已识别字段进入结构化数据库列；尚未映射的未来字段仍保留在原始对象中，导出时再与当前结构化值合并。因此“完整保存”不等于“所有未知字段都已具备执行语义”。

规则组推荐使用 Android 阅读常见的导出键名：

- `ruleSearch`
- `ruleExplore`
- `ruleBookInfo`
- `ruleToc`
- `ruleContent`

导入器也接受本项目内部键名 `searchRule`、`exploreRule`、`bookInfoRule`、`tocRule`、`contentRule`。规则组既可为对象，也可为紧凑字符串；为便于审阅、转义和版本管理，推荐使用对象。

紧凑字符串示例：

```text
@{bookList=$.data;name=$.title;author=$.author;bookUrl=/book/{{$.id}}}
```

字段以顶层分号分隔，字段名和值以第一个 `=` 分隔。复杂 JS、正则或包含分号的值更容易产生歧义，不建议新书源使用此格式。

## 4. 顶层字段

| JSON 字段 | 编辑器名称 | 类型/默认值 | 当前作用 |
| --- | --- | --- | --- |
| `bookSourceName` | 书源名称 | 字符串，必填 | UI 展示名称。 |
| `bookSourceUrl` | 书源地址 | 字符串，必填 | 书源唯一键，也是相对请求地址的基础地址。建议写协议和主机，不带末尾业务路径。 |
| `bookSourceType` | 书源类型 | 数字，默认 `0` | `0` 普通书，`1` 有声书，`2` 漫画，`3` 文本/Web 文件；还会结合书籍 `type`、标签和编码协议推断。 |
| `bookSourceGroup` | 书源分组 | 字符串 | 搜索筛选和管理分组。 |
| `bookSourceComment` | 书源备注 | 字符串 | 管理页说明，也会注入规则上下文。 |
| `loginUrl` | 登录地址 | 字符串 | 网页登录/验证入口。检测到登录或验证页时可打开该地址并同步 Cookie。 |
| `loginUi` | 登录界面 | JSON 字符串或动态 JS | 管理页可渲染文本、密码、开关、选择项和按钮；控件值、开关状态与按钮状态可持久化。 |
| `loginCheckJs` | 登录检测JS | 字符串 | 导入、保存及登录能力识别；登录检查和登录动作复用 ArkWeb JavaScript/受控主机桥。 |
| `loginHeader` | 登录密钥 | 字符串 | 可用于特定登录源；通用请求头仍应写在 `header`。 |
| `loginInfo` | 登录运行信息 | JSON 字符串 | 保存登录控件值及受控运行状态。导出公共书源时不应携带账号、Token 或 Cookie。 |
| `bookUrlPattern` | URL正则 | 字符串 | 保存和导入支持，用于描述书籍 URL；当前主解析链不依赖它。 |
| `searchUrl` | 搜索地址 | 字符串 | 搜索请求模板。 |
| `exploreUrl` | 发现地址 | 字符串 | 发现分类及请求模板。 |
| `jsLib` | JS库 | 字符串 | 搜索、发现、详情、目录、正文和登录动作共用。简单代码走轻量引擎，复杂语义可按阶段路由到 ArkWeb，但只开放受控主机能力。 |
| `header` | 请求头 | 字符串 | 书源全局 HTTP 请求头。支持 JSON/宽松对象或每行一个 `名称: 值`。 |
| `variableComment` | 暂无编辑项 | 字符串 | 书源变量的说明文本。 |
| `variable` | 书源变量 | 字符串 | 作为 `source.variable` 注入上下文并独立持久化，登录按钮可通过 `source.setVariable()` 修改。 |
| `enabledCookieJar` | 启用 Cookie | 布尔，默认 `true` | 导入并保存 Cookie 偏好；登录 Cookie 仍按实际请求域名隔离和附加。 |
| `enabled` | 启用书源 | 布尔，默认 `true` | 是否参与搜索和书源选择。 |
| `enabledExplore` | 启用发现 | 布尔，默认 `true` | 是否显示此源的发现入口。 |
| `weight` | 权重 | 数字，默认 `0` | 搜索相关度相同时，权重较大者优先。 |
| `customOrder` | 暂无编辑项 | 数字 | 可导入、保存和导出，并作为结果排序的次级依据。 |
| `lastUpdateTime` | 暂无编辑项 | 数字 | 可导入、保存和导出；缺失时使用导入时间。 |
| `respondTime` | 暂无编辑项 | 数字，默认 `180000` | 可导入、保存和导出，作为书源响应时间/超时相关运行字段。 |
| `concurrentRate` | 暂无编辑项 | 字符串 | 导入并保存；`次数/毫秒窗口`，例如 `20/60000`。普通 HTTP 请求、重试和重定向都会按书源限流。 |
| `isPinned` / `isLocked` | 置顶/锁定 | 布尔 | 可导入并持久化；锁定源不会被同地址导入直接覆盖。 |
| `customButton` / `eventListener` | 扩展标记 | 布尔 | 可导入、保存和导出；目前主要用于保留 Android 阅读书源元数据。 |

原始 JSON 中的其他未知字段会被保留，但只有进入模型、规则组或专用兼容层的字段才会影响执行。

## 5. URL 与 HTTP 请求规则

### 5.1 相对地址

请求地址可以是：

- 完整地址：`https://api.example.com/search`；
- 协议相对地址：`//cdn.example.com/cover.jpg`，解析为 HTTPS；
- 根相对地址：`/search`，拼到 `bookSourceUrl` 的主机；
- 普通相对地址：`search`，拼到基础地址后；
- `data:` URL，支持普通百分号编码和 Base64 内容。

列表中提取的详情地址、封面地址和章节地址也会按响应最终 URL 解析相对路径。HTTP 3xx 最多跟随 3 次；301、302、303 对非 GET/HEAD 请求会切换为 GET。

为了避免不同阶段对“普通相对路径”的基准处理差异，书源地址建议只写站点根地址，业务请求和规则生成的 URL 优先写 `/` 开头的根相对地址；尤其是详情规则的 `tocUrl`，不要依赖 `chapters/list` 这类无前导斜杠的路径。

### 5.2 搜索变量

搜索地址可使用：

| 模板 | 值 |
| --- | --- |
| `{{key}}` | `encodeURIComponent` 编码后的关键字。 |
| `{{searchKey}}` | 同 `key`。 |
| `{{keyword}}` | 同 `key`。 |
| `{{searchKeyRaw}}` | 未编码的原始关键字。最终 URL 参数仍会按请求字符集编码。 |
| `{{page}}` | 当前实现为 `1`。 |
| `{{source.bookSourceUrl}}` | 当前书源地址。 |
| `{{source.bookSourceName}}` | 当前书源名称。 |
| `{{source.bookSourceGroup}}` | 当前书源分组。 |

示例：

```text
/search?q={{key}}&page={{page}}
/search.asp?word={{searchKeyRaw}},{"charset":"gb2312"}
```

避免对 `{{key}}` 再手工 URL 编码，否则可能双重编码。目标站要求 GBK/GB2312 时，使用 `searchKeyRaw` 配合 `charset`。

### 5.3 发现变量与分类格式

发现页支持 `{{page}}` 和 `{{pageIndex}}`。最稳定的配置是一行一个分类：

```text
热门::/rank/hot?page={{page}}
完结::/rank/finished?page={{page}}
```

也支持 JSON 数组：

```json
[
  { "title": "排行榜", "url": "" },
  { "title": "热门", "url": "/rank/hot?page={{page}}" },
  { "title": "完结", "url": "/rank/finished?page={{page}}" }
]
```

数组中没有 `url` 的条目会成为后续条目的分组标题。指向“我的书架”、用户页或登录页的个人入口会被过滤。

### 5.4 URL 选项对象

在 URL 后追加逗号和对象可配置请求：

```text
/api/search,{"method":"POST","body":"keyword={{searchKeyRaw}}&page={{page}}","charset":"utf-8","headers":{"Referer":"https://example.com/"},"retry":1}
```

支持的选项：

| 选项 | 说明 |
| --- | --- |
| `method` | HTTP 方法，默认 `GET`。 |
| `body` | 字符串或对象；对象会 JSON 序列化。 |
| `charset` | URL 查询和表单编码字符集，如 `utf-8`、`gbk`、`gb2312`、`gb18030`、`escape`。 |
| `headers` | 本次请求头；同名项覆盖书源全局请求头。 |
| `retry` | 响应不可用时的额外重试次数。 |
| `type` | 会被解析并保存到请求配置，当前 HTTP 执行链没有额外分支行为。 |
| `webView` | 会被解析为布尔值，当前通用请求仍走 HTTP 客户端。 |
| `webJs` | 会被解析并保存，当前通用请求不会执行。 |

选项对象支持单引号、无引号键和尾逗号等宽松写法，但推荐使用标准 JSON，减少转义差异。

POST 还有一种简写：地址以 `@` 开头，`?` 后内容作为 body。

```text
@/api/search?keyword={{searchKeyRaw}}&page={{page}}
```

表单 body 会编码为空格使用 `+` 的形式。未显式提供 `Content-Type` 时：JSON 对象 body 使用 `application/json; charset=utf-8`，其他 body 使用 `application/x-www-form-urlencoded`。

### 5.5 请求头

推荐 JSON：

```json
{
  "User-Agent": "Mozilla/5.0",
  "Accept": "application/json",
  "Referer": "https://example.com/"
}
```

也支持逐行格式：

```text
User-Agent: Mozilla/5.0
Accept: application/json
```

URL 内还支持：

```text
/path@Header:{"Referer":"https://example.com/"}@End
```

合并顺序是“书源全局请求头 → 本次请求头”，因此本次请求头优先。若未显式设置 Cookie，应用会按请求地址从登录/验证 Cookie 存储中补充。

## 6. 通用解析语法

一个字段规则通常由三部分构成：

```text
提取规则##正则##替换文本@js:后处理
```

并非每部分都必须存在。执行顺序是先提取，再执行 `@js:` 后处理，最后执行 `##` 正则替换。尽量让规则保持单一职责，复杂转换分成 `init`、字段提取和净化三步。

### 6.1 JSONPath

JSON 响应优先使用 JSONPath：

```text
$.data.books[*]
$.title
$['data']['title']
$..chapters[*]
$.items[0]
$.items[-1]
$.items[0,2,4]
$.items[1:5]
$.items[::-1]
$.items[?(@.status == 1)]
$.items[?(@.name =~ /小说/i)]
```

当前支持：

- 点号属性、方括号引号属性；
- `*` 通配；
- `..` 递归属性和递归通配；
- 正负数组下标、下标列表；
- `[start:end:step]` 切片；
- 过滤器中的 `&&`、`||`、`!`；
- 比较操作 `==`、`!=`、`>`、`<`、`>=`、`<=`；
- 正则比较 `=~ /pattern/i`；
- 属性是否存在判断。

`@.field` 会按当前 JSON 对象的 `$.field` 处理。JSON 内容中还允许 `.field` 或简单裸字段 `field`，但推荐显式写 `$.field`，可读性和可移植性更好。`@json:路径` 可以强制按 JSONPath 解析。

### 6.2 CSS 选择器

HTML 响应优先使用 CSS 风格规则：

```text
.book-item
.book-item .title@text
a.detail@href
img.cover@data-src
meta[name=description]@content
ul.list > li
li:contains(完结)
li:has(a[href*=book])
a:not(.disabled)
a:not([rel=nofollow])
li:first
li:last
li:eq(2)
li:lt(5)
li:gt(2)
li:nth-child(2)
li:nth-of-type(2)
```

已实现的主要能力：

- 标签、`#id`、`.class`，可组合多个 class；
- 后代和直接子代 `>`；
- 逗号分组；
- 属性存在及 `=`、`^=`、`$=`、`*=`、`~=`、`|=`；
- `:contains()`、单层 `:has()`、`:not()`；
- `:first`、`:last`、`:eq(n)`、`:lt(n)`、`:gt(n)`；
- 数字形式的 `:nth-child(n)`、`:nth-of-type(n)`；
- `@text`、`@html`、`@ownText`、`@textNodes` 和属性提取。

未写提取后缀时，普通 CSS 字段默认返回文本；列表规则会保留完整元素供子规则继续解析。

常用提取后缀：

| 后缀 | 结果 |
| --- | --- |
| `@text` | 去标签后的全部文本。 |
| `@ownText` | 元素自身直接文本，尽量排除子元素内容。 |
| `@textNodes` | 直接文本节点按换行连接。 |
| `@html` | 完整元素 HTML。 |
| `@href`、`@src`、`@content`、`@title` 等 | 对应属性值。自定义合法属性名也可提取。 |

选择器解析由项目内轻量解析器完成，并非完整浏览器 DOM/CSS 引擎。不要依赖复杂嵌套伪类、`an+b` 形式的 `nth-child`、伪元素或现代 CSS 全集。单个 HTML 响应超过 4 MiB 时，列表 CSS/正则解析会受保护性限制；大接口优先使用 JSONPath 或缩小响应。

### 6.3 基础 XPath

支持一部分可转换为 CSS 的 XPath：

```text
//div[@class='book']/a/text()
//a[contains(@href,'book')]/@href
//li[contains(.,'完结')]
//ul/li[1]
//li[last()]
```

支持属性相等、`contains(@attr, ...)`、`starts-with(@attr, ...)`、文本包含、数字位置、`last()`、属性存在以及末尾 `/@attr`、`/text()`。复杂轴、函数、变量和完整 XPath 表达式不受支持；新源推荐 JSONPath 或 CSS。

### 6.4 组合规则

| 运算符 | 行为 | 示例 |
| --- | --- | --- |
| `规则1||规则2` | 依次尝试，返回第一个非空结果。 | `.title@text||h1@text` |
| `规则1&&规则2` | 将各规则的结果顺序拼接为一个结果列表。 | `.name@text&&.alias@text` |
| `规则1%%规则2` | 按索引交错合并多个结果列表。 | `.name@text%%.url@href` |

分隔符在引号、圆括号、方括号和花括号内不会拆分，因此 JSONPath 过滤器中的 `&&`、`||` 可以正常使用。

### 6.5 模板拼接

双花括号会在当前元素中求值：

```text
/book/{{$.book_id}}
{{$.category}},{{$.status}}
https://cdn.example.com/{{$.cover}}
```

同时兼容部分单花括号 JSONPath：

```text
/book/{$.book_id}
```

模板中可读取上下文变量：

```text
{{source.bookSourceUrl}}
{{source.bookSourceName}}
{{source.bookSourceGroup}}
{{source.bookSourceComment}}
{{source.getKey()}}
{{source.getVariable()}}
```

详情、目录、正文阶段还会注入 `book.bookUrl`、`bookUrl`，并尽量从详情 URL 提取 `book`、`book_id`、`id`。

### 6.6 正则提取与替换

字段后处理使用：

```text
原规则##正则##替换文本
原规则##正则
```

示例：

```text
$.author##^作者：
title@text##^《|》$
$.status##^1$##连载
```

正则以 JavaScript `RegExp` 的全局模式执行。第三段省略时替换为空字符串；替换文本支持 `$1` 等捕获组引用。字面量 `##` 可写成 `\##`。

还支持直接正则规则：

- 以 `%` 开头时，对完整内容运行一次非全局正则，并返回完整匹配和捕获组；
- 普通“像正则”的规则会以全局模式运行。有捕获组时，每个匹配会变为 `{"$0":"...","$1":"..."}`，后续可用 `$['$1']` 一类路径读取。

直接正则的兼容行为较特殊，稳定书源更适合用 CSS/JSONPath 提取后再用 `##` 净化。

### 6.7 上下文变量 `@put` / `@get`

可以在规则中保存并读取字符串变量：

```text
@put:{bookId:$.id}$.title
@get:{bookId}
/chapter/@get:{bookId}/{{$.id}}
```

`@put:{key:value}` 中可用逗号或分号分隔多项；值会先按普通规则求值。上下文会从搜索结果保存到书籍，并在详情、目录和正文阶段恢复，因此可用于跨阶段携带站点 ID。章节还会保存其解析时的 `baseUrl`。

注意：列表中的每个搜索/发现元素会创建自己的规则上下文，搜索得到的变量会写入该书籍；目录中的章节共用书籍上下文。避免用相同键保存会在章节之间互相覆盖的临时值。

### 6.8 JavaScript 兼容层

规则支持以下形态：

```text
<js>表达式</js>
$.status@js:result.replace(/1/g, "连载")
@js:'https://example.com/chapter/'+$.id
js:表达式
```

当前不是“只有一个受限表达式解释器”，而是两层执行体系：

1. **轻量规则引擎**：优先处理模板、简单表达式和常见 Android/Java 别名，启动成本低；
2. **分阶段 ArkWeb 引擎**：能力路由器发现箭头函数、模板字符串、`try`、数组高阶函数、`Set/Map`、解构或较大脚本时，仅将相应阶段交给 ArkWeb 的真实 JavaScript 引擎。

搜索、发现、详情、目录和正文分别路由，启用某一阶段的 ArkWeb 不会把所有书源或所有阶段一起改道。无副作用的失败可以回退轻量引擎；含网络、Cookie 或持久化写入的动作会避免双重执行。`jsLib` 中声明的顶层函数会暴露给当前阶段规则，并在下一书源执行前清理，防止跨源污染。

轻量层和桥接层合计覆盖的常用能力包括：

- 字符串拼接和简单变量赋值；
- `result.replace(/正则/g, "文本")` 等常见替换链；
- 简单数值 `+ - * / %` 和 `Math.round/floor/ceil`；
- `Date.now()`、部分 `new Date()` 取值；
- `encodeURIComponent`、`encodeURI`；
- `java.urlEncode/urlDecode`；
- Base64、Hex、MD5、SHA-1、SHA-256；
- SHA-512、Base64 URL、HTML 实体编解码；
- AES、DES/3DES 的常见 Base64 加解密；
- `java.getString`、`java.getStringList` 读取当前 JSON；
- `java.timeFormat`；
- `java.getCookie`、`cookie.getCookie/setCookie/removeCookie`；
- `java.randomUUID()`、`java.androidId()`；
- `java.put/get`、`source.get/put/getVariable/setVariable`、`book.getVariable/putVariable`；
- `source.getLoginInfo/getLoginInfoMap/putLoginInfo`、`source.getLoginHeader` 和 `cache.get/put/delete`；
- `android.util.Base64`、`java.util.Base64`、`URLEncoder/URLDecoder`、`System.currentTimeMillis` 等常见 Java/Android 别名；
- `StringBuilder`、`HashMap`、`ArrayList` 及常用 Java 字符串/集合方法；
- 使用 `MessageDigest` 或 `Cipher/SecretKeySpec/IvParameterSpec` 封装的常见摘要、AES、DES/3DES 函数。

ArkWeb 提供真实 ECMAScript 语义，但**不等于完整 Android、Rhino、Node.js 或无限制浏览器环境**。阶段脚本的网络必须经过 `java.ajax` 等受控桥接；`fetch`、`XMLHttpRequest`、`WebSocket` 会被判定为未托管网络。任意 Java 导入、文件、进程、反射、系统组件和第三方原生库不会自动可用。DOM 主要用于登录面板生成的页面；普通搜索/目录/正文规则不应假定目标网页已在可操作 DOM 中。

能力路由会分析 `java`、`source`、`cache` 和 `cookie` 方法，并在登录动作失败时提示缺少的桥接方法。复杂源仍应逐阶段实机验证；书源中的私有函数、接口和凭据始终属于该书源配置，不会成为应用内置 API。

### 6.9 编码 `data:` 地址与显式请求

应用支持标准 `data:` 文本以及 `data:;base64,<负载>,{...}` 形式。Base64 负载和尾部选项会分别解析，避免把请求选项误当成正文。

编码请求只有在选项明确使用通用 `type: "request"`，并明确提供 HTTP(S) `url`/`requestUrl` 时才会执行。方法、请求体和请求头也必须来自书源配置。应用不会：

- 根据书源名称、平台名或负载类型推断内容站点；
- 选择内置聚合后端、镜像、代理或回退主机；
- 自动加入第三方 API Key、账号、设备标识或平台参数；
- 把一个站点的 Cookie 自动复制到另一个站点；
- 在规则之外实现第三方接口签名、付费内容解密或评论接口适配。

需要加密、摘要、Cookie、音频或图片处理时，应把相应逻辑和有权使用的参数明确写在书源规则中。`BookSourceInteractionPostProcessor` 不再识别具体平台，只保留规则已经产出的正文。

## 7. 各阶段规则字段

### 7.1 搜索规则 `ruleSearch`

当前要让书源参与搜索，至少必须配置：`searchUrl`、`bookList`、`name`、`bookUrl`。

| 字段 | 必需 | 解析上下文 | 当前用途 |
| --- | --- | --- | --- |
| `bookList` | 是 | 完整搜索响应 | 选出书籍元素。 |
| `name` | 是 | 单个书籍元素 | 书名；空书名的结果会被丢弃。 |
| `author` | 否 | 单个书籍元素 | 作者。 |
| `coverUrl` | 否 | 单个书籍元素 | 封面；相对地址会解析。 |
| `intro` | 否 | 单个书籍元素 | 简介。 |
| `kind` | 否 | 单个书籍元素 | 分类/标签。 |
| `lastChapter` | 否 | 单个书籍元素 | 最新章节标题。 |
| `bookUrl` | 是 | 单个书籍元素 | 详情页；空地址的结果会被丢弃。 |
| `wordCount` | 否 | 单个书籍元素 | 字段可导入，但当前常规搜索链没有赋值；可在详情规则补全。 |

每个源常规搜索最多保留 50 条有效结果，总搜索最多保留 1000 条，并按“来源 + URL”去重。搜索并发数最大为 12；后台结果每约 500 ms 合并一次，避免每条回调都打断列表手势，因此搜索未结束时仍可滑动已出现的结果。搜索会清理超长或异常字段；书名约 120 字符、作者约 120、简介约 1200、URL 约 2048 字符。

主页面中的搜索组件在书架、发现、搜索和“我的”之间切换时不会主动清空结果；发起下一次搜索或清除单书源模式时才重置。本行为是页面会话缓存，不是长期数据库搜索快照，应用进程结束后不保证恢复。

### 7.2 发现规则 `ruleExplore`

至少需要：`exploreUrl`、`bookList`、`name`、`bookUrl`。字段语义与搜索相同。发现链会读取 `wordCount`，并按“来源 + 详情 URL”去重。

当 `ruleExplore` 为 `null`、空数组、空对象或缺少必要字段时，会自动回退到 `ruleSearch`。`exploreUrl` 以 `@js:` / `js:` 开头时会交给受限脚本引擎执行，结果应为分类对象数组的 JSON 字符串；脚本运行具有操作次数、数组大小、代码长度和输出长度限制。

### 7.3 详情规则 `ruleBookInfo`

详情请求地址来自搜索/发现的 `bookUrl`。

| 字段 | 当前用途 |
| --- | --- |
| `init` | 先在完整详情响应上执行；非空结果成为其余详情字段的新解析内容。适合 `$.data` 或 `.book-info@html`。 |
| `name` | 更新书名；空结果保留列表页值。 |
| `author` | 更新作者；空结果保留列表页值。 |
| `coverUrl` | 补充封面。当前逻辑优先保留列表页已有封面。 |
| `intro` | 更新简介，经过字段清理后择优保留。 |
| `kind` | 更新分类。 |
| `lastChapter` | 更新最新章节。 |
| `wordCount` | 更新字数。 |
| `updateTime` | 字段可导入和编辑，但当前通用详情链尚未写入书籍。 |
| `tocUrl` | 目录请求地址；以 URL 模式解析相对地址。为空时会尝试依据书籍 URL 和规则模板兜底。 |

`init` 返回的是字符串。如果 JSONPath 命中对象，会被序列化成 JSON，因此后续仍可用 JSONPath；如果 CSS 命中元素，建议显式用 `@html` 保留 HTML。

### 7.4 目录规则 `ruleToc`

| 字段 | 必需 | 当前用途 |
| --- | --- | --- |
| `chapterList` | 是 | 在完整目录响应中选出章节元素。 |
| `chapterName` | 建议 | 章节标题；空时自动使用“第 N 章”。 |
| `chapterUrl` | 是 | 正文请求地址；空地址的章节会被丢弃。 |
| `nextTocUrl` | 否 | 当前目录页的下一页地址；逐页请求、按章节 URL 去重，遇到空地址、重复页或 100 页上限时停止。 |
| `isVip` | 否 | 只有解析结果严格等于字符串 `true` 时标记 VIP。 |
| `isPay` | 否 | 可导入和编辑；普通目录链目前不写入 `BookChapter.isPay`，专用/编码协议可直接返回付费状态。 |
| `updateTime` | 否 | 通用目录和 ArkWeb 目录结果会解析，并保存到章节变量 `updateTime`。 |
| `chapterListAddition` | 否 | 模型字段；当前导入映射和通用目录链未使用。 |

目录规则产生的顺序就是阅读目录顺序。负索引、切片或 CSS 位置规则可用于排除卷名、广告项。章节标题会清理多余空白。

### 7.5 正文规则 `ruleContent`

| 字段 | 当前用途 |
| --- | --- |
| `content` | 小说正文提取规则；纯漫画书源可留空并配置 `images`。 |
| `replaceRegex` | 对提取后的正文做全局正则替换。 |
| `title` | 可导入和编辑，当前正文返回链不读取。 |
| `images` | 漫画图片提取规则；支持返回单个地址、地址列表或图片标签，相对地址会按章节响应地址补全。 |
| `nextContentUrl` | 正文下一页地址；逐页解析并拼接，遇到空地址、重复页、50 页或 8 MiB 正文上限时停止。 |
| `imageDecode` | 图片二进制解密规则；当前允许受限的 AES-CBC-PKCS5/PKCS7 解密，不执行文件、进程或反射 API。 |
| `imageStyle` | `FULL`、`comic`、`manga`、`webtoon` 会让阅读器优先使用连续全宽漫画模式。 |
| `payAction` | 紧凑规则可导入到模型，当前通用正文链不执行。 |

`replaceRegex` 支持两种形式：

```text
广告正则
广告正则##替换文本
```

之后应用还会执行基本 HTML 清理：`<br>` 转换为换行、`</p>` 转换为双换行、移除其他标签、解码部分实体、压缩连续空行。正文中的 `img`/SVG `image`、Markdown 图片和独立图片地址会保留为阅读器图片页；配置 `images` 时优先按该规则返回的图片顺序分页。其他复杂 HTML 布局通常不会原样保留。

在 HTML 清理前，以下交互标记会转换为阅读器内部动作，而不是作为代码显示：

```html
<p>一段正文<comment ident="https://example.com/comments" count="12" /></p>
<p><img ident="https://example.com/god-comment" src="data:image/svg+xml;base64,..." /></p>
```

阅读页会把动作显示为跟随段落的可点击气泡/入口；分页器会保证标记不被切断，TTS 和快速朗读面板会剥离内部动作编码。点击动作会打开内置动作页面或媒体播放器。普通 HTML `onclick`、任意 DOM 事件和任意 JavaScript URL 不会直接执行。

漫画图片支持阅读书源常见的请求参数写法：

```text
https://img.example/page.jpg,{"headers":{"Referer":"https://example.com/"}}
```

带参数或 `imageDecode` 的图片由应用 HTTP 客户端携带 Cookie/白名单请求头下载，在最多 20 MiB 的限制内完成解密并写入应用缓存，再以本地文件交给阅读器。单章图片按最多 4 路并发处理。

## 8. HTML 书源示例

假设搜索页结构：

```html
<div class="book-item">
  <a class="title" href="/book/123">《示例书》</a>
  <span class="author">作者：张三</span>
  <img class="cover" data-src="/cover/123.jpg">
  <p class="intro">内容简介</p>
</div>
```

对应搜索规则：

```jsonc
"ruleSearch": {
  "bookList": ".book-item",
  "name": ".title@text##^《|》$",
  "author": ".author@text##^作者：",
  "coverUrl": ".cover@data-src",
  "intro": ".intro@text",
  "kind": "",
  "lastChapter": "",
  "bookUrl": ".title@href",
  "wordCount": ""
}
```

假设详情、目录、正文分别为常见 HTML：

```jsonc
"ruleBookInfo": {
  "init": ".book-detail@html",
  "name": "h1@text",
  "author": ".author@text##^作者：",
  "coverUrl": "img.cover@src",
  "intro": ".intro@text",
  "kind": ".tags a@text",
  "lastChapter": ".latest@text",
  "wordCount": ".word-count@text",
  "updateTime": "",
  "tocUrl": ".catalog-link@href"
},
"ruleToc": {
  "chapterList": ".chapter-list a[href*=chapter]",
  "chapterName": "text",
  "chapterUrl": "href",
  "isVip": "",
  "isPay": "",
  "updateTime": ""
},
"ruleContent": {
  "content": "#chapter-content@html",
  "replaceRegex": "请收藏本站|最新网址.*"
}
```

当当前元素本身就是 `<a>` 时，`text` 和 `href` 可直接操作当前元素；也可以写 `@text`、`@href` 风格，但推荐在可读性更高时写完整选择器。

## 9. JSON API 书源示例解析

公开仓库不提供指向真实第三方站点的完整可导入书源。开发和测试时，请使用 `https://example.com`、本地测试服务器或开发者自行控制且明确获得授权的服务，并使用虚构数据验证以下能力：

- 搜索和发现地址可使用 `{{key}}`、`{{page}}`；
- `$.data` 可直接取得数组，列表解析器会将数组元素逐项转成当前 JSON 元素；
- 详情 `init` 可用 `$.data` 把解析根缩到实际书籍对象；
- `/api/books/{{$.book_id}}` 可在元素上下文中构造详情 URL；
- `##` 可用于清理或格式化测试文本；
- `@js:result.replace(...)` 可用于转换合成状态码。

完整字段骨架见本文末尾的模板；模板故意不包含可用的真实站点地址、接口、凭据或内容规则。

## 10. 登录、Cookie 与网页验证

应用会综合 HTTP 状态、响应内容、规则中的验证提示以及登录字段判断是否需要网页验证。常见流程：

1. 为书源设置 `loginUrl`；
2. 搜索、发现、详情、目录或正文命中登录/验证页；
3. 应用打开验证页面；
4. 用户在 WebView 中完成登录或验证；
5. Cookie 同步到书源请求；
6. 返回后重试原操作。

### 10.1 `loginUi` 控件

静态 `loginUi` 通常是控件数组，当前识别：

| `type` | 显示/行为 |
| --- | --- |
| `text`、`input`、`email`、`number` | 普通输入框。 |
| `password` | 密码输入框。 |
| `toggle` | 开关，使用 `chars` 的第 1/2 项作为关闭/开启值。 |
| `select` | 选择框，候选值来自 `chars`。 |
| `button` 或其他带 `action` 的项 | 执行登录/接口动作。 |

控件可使用 `name`、`viewName`、`placeholder`、`value`、`default`/`defaultValue`、`chars`、`action` 和 `style`。输入、开关与选择值写入 `source.loginInfo`；重新打开面板会恢复。对于原书源把开关伪装成按钮的情况，应用还会根据名称、动作及脚本持久化状态推断“已开启/已关闭”，但新书源应优先使用明确的 `toggle`/`select`。

`loginUi` 也可以是动态 `@js:`/`<js>` 脚本，返回控件数组 JSON。动态控件生成和按钮动作均有超时、输出大小和网络响应限制。

### 10.2 登录动作 ArkWeb 桥

登录动作使用独立 ArkWeb 运行环境，不会让搜索或正文自动改走登录页面。当前桥接包括：

- `java.ajax` 的受控 HTTP 请求与逐步响应回填；
- `source.variable`、`loginHeader`、`loginInfo`、`source.get/put` 和 `cache` 状态；
- Cookie 获取、设置、替换、按名称删除及网页 Cookie 回写；
- Base64/Base64URL、Hex、URL/HTML 编解码、字节数组和 UUID；
- `createSymmetricCrypto` 的 AES/DES/3DES 常见变换；
- `startBrowser`、`startBrowserAwait`、`showBrowser`、`openUrl`；
- 登录动作中的 `java.webView`（加载指定 URL 并执行脚本后回传结果）；
- `searchBook`、`refreshExplore`、`reLoginView` 等 UI 动作。

`startBrowserAwait` 会暂停当前脚本，打开网页，用户点击完成后将页面返回值交回同一动作继续执行。浏览器关闭、取消、网络失败或脚本超时会结束执行并恢复按钮状态，不应永久停在“执行中”。用于“书源更新”的按钮可以打开源提供的更新页面；页面是否真正更新配置取决于该脚本是否返回并保存了新数据，不能仅凭打开网页判定更新成功。

请求规则中的 `<js>startBrowserAwait(...)`、`getVerificationCode(...)` 等提示也可触发验证逻辑，但不是完整 Android WebView/Activity API。需要账号口令签名、动态参数或复杂验证码的网站，必须实机确认；部分已知站点在项目代码中有专用适配，不能据此推断所有同类源都通用支持。

### 10.3 有声书登录与音色

有声书源可通过 `bookSourceType: 1`、书籍 `type` 的音频位或编码协议元数据标记。正文规则应最终返回一个可播放的 HTTP/HTTPS 音频地址，或由已适配协议返回包含音频地址的 JSON。播放页支持：

- 播放/暂停、进度、倍速、上一章/下一章和目录跳转；
- 定时停止；
- 音色代码输入，留空表示书源默认值；
- 将音色写入 `book.getVariable('custom')`，刷新当前音频地址；
- 返回书架或进入后台继续播放，并通过全局胶囊/系统 AVSession 控制。

音色代码只有在书源规则实际读取 `book.getVariable('custom')` 或编码协议把该值带入音频请求时才会生效。若音频接口要求账号、Token、设备 ID 或购买权限，空音色或更换音色不能替代登录；应先确认接口返回的是真实音频而不是 401/JSON 错误页。

不要把账号、密码、长期 Token 直接提交到公共书源 JSON。优先通过登录页获取短期 Cookie，或仅在本机编辑 `loginHeader`。

## 11. 开发与调试流程

### 11.1 先在浏览器/抓包工具确认接口

记录每一阶段：

- 请求 URL、方法、query、body；
- 必须的 User-Agent、Referer、Cookie、Content-Type；
- 响应编码；
- 搜索列表路径和唯一书籍 ID；
- 详情页到目录的关系；
- 章节 ID、正文路径；
- 是否有重定向、登录、验证码、签名、加密。

优先选择站点公开且稳定的 JSON 接口；HTML 结构常改，复杂 JS 签名和反爬验证的维护成本最高。

### 11.2 按阶段增量开发

1. 只写顶层字段、`searchUrl` 和 `ruleSearch`；确保至少出现一条有书名、有详情 URL 的结果。
2. 写 `ruleBookInfo`；确认详情信息和 `tocUrl` 正确。
3. 写 `ruleToc`；确认章节数、顺序、名称、URL。
4. 写 `ruleContent`；先只提正文，再添加净化正则。
5. 最后复制/调整搜索规则为发现规则，补充分类和分页。
6. 再处理登录、Cookie、字符集、加密和 JS 兼容表达式。

### 11.3 在应用内验证

书源可从文件或 URL 导入，也可在“我的 → 书源管理 → 新建书源”逐字段填写。完整验收清单：

- [ ] JSON 可导入，书源名称和地址正确；
- [ ] 导出后 `jsLib`、`loginUrl`、`loginUi`、五组规则和原始扩展字段没有丢失；
- [ ] 启用书源后能搜索到结果；
- [ ] 搜索未结束时可以滑动结果，停止搜索后不会继续追加旧会话结果；
- [ ] 搜索中文、空格、特殊字符时编码正确；
- [ ] 书名和详情 URL 不为空；
- [ ] 相对详情 URL 和封面 URL 能正确补全；
- [ ] 详情字段不会被登录页或错误页污染；
- [ ] 目录 URL 正确，章节数和顺序合理；
- [ ] 第一章、中间章、最后一章都能加载；
- [ ] 正文没有导航、广告、脚本或整页错误信息；
- [ ] 开启段评后气泡跟随正确段落、可点击，翻页没有异常大空行；关闭段评后正文排版恢复；
- [ ] 朗读文本不包含 `LEGADO_READER_ACTION`、`<comment>` 或其他内部代码；
- [ ] 漫画源图片顺序、请求头、长图宽度和上一/下一章行为正确；
- [ ] 有声书源能播放、暂停、切章、目录跳转、切换音色，并在后台/书架胶囊中继续控制；
- [ ] 发现分类可打开，翻页后内容变化；
- [ ] 登录/验证后 Cookie 能继续用于后续请求；
- [ ] 登录面板中的输入、开关、选择项和按钮状态关闭后重开仍保持；
- [ ] `startBrowserAwait` 完成或取消后按钮不会一直显示“执行中”；
- [ ] 站点 301/302、HTTP/HTTPS 或镜像变化时行为可接受。

运行应用时，搜索、发现和 WebBook 服务会输出包含 `[SC]`、`[ExploreCoordinator]`、`[WS]` 的日志，可重点查看：最终 URL、状态码、响应长度、列表命中数量和第一条结果。

### 11.4 常见故障定位

| 现象 | 优先检查 |
| --- | --- |
| 书源完全不参与搜索 | `enabled`，以及 `searchUrl`、`bookList`、`name`、`bookUrl` 是否都非空。 |
| 浏览器能下载 JSON，但 URL 导入失败 | 确认返回体不是 HTML 跳转页；查看错误来自应用 HTTP、TCP、ArkWeb 下载还是系统下载；必要时改用本地文件导入。 |
| 导入提示 `[object Object]` | 当前版本会展开 `message/msg/reason/code`；若仍出现，保留完整错误和 URL，检查服务是否返回了非标准对象或空下载错误。 |
| HTTP 成功但列表为 0 | 响应实际是 JSON 还是 HTML；列表规则是否在完整响应运行；字符集和登录页。 |
| 列表命中但无结果 | 子规则上下文是否错误；最常见是 `name` 或 `bookUrl` 为空。 |
| 中文搜索乱码 | 使用 `{{searchKeyRaw}}` 并在 URL 选项中指定 `gb2312`/`gbk`。 |
| URL 中出现 `%257B`、关键字双重编码 | 不要预编码 `{{key}}`，或改用 `{{searchKeyRaw}}`。 |
| 详情能开但无目录 | `tocUrl` 是否在 `init` 后的上下文解析；是否错误拼到详情页目录；相对地址基准是否正确。 |
| 目录有标题但章节被丢弃 | `chapterUrl` 为空或仍含未解析的模板/JSONPath。 |
| 正文返回整页文字 | `content` 选择器太宽；先缩到正文容器，再用 `replaceRegex`。 |
| 正文是空字符串 | 请求失败、被验证拦截、提取规则为空，或提取结果被净化正则全部删除。 |
| 正文显示 `JSON.parse(undefined)` | 检查脚本变量是否由 `data:` 负载、`java.ajax` 或上一条规则提供；不要假定不存在的字段会自动变成 `{}`。 |
| 开启段评后正文显示内部代码 | 确认返回的是 `<comment ident count>` 或 `<img ident>` 支持格式，并在正文清理前进入统一交互后处理；TTS 必须使用剥离动作标记后的文本。 |
| 段评气泡存在但无法点击 | `ident` 必须是完整或可补全 URL，并包含正确书籍/章节 ID；同时检查段评开关、登录 Cookie 和后端返回。 |
| 登录按钮脚本超时 | 检查动作是否等待未完成的网页、反复请求同一 URL、调用未映射的主机方法，或超过网络/脚本限制；错误提示中的“缺少兼容能力”优先处理。 |
| 登录面板开关没有状态 | 新源使用 `type: "toggle"`/`"select"`、`chars` 和默认值；旧按钮式开关需确保动作把状态写入 `source`、`java` 或 `loginInfo`。 |
| 有声书有目录但不能播放 | 正文规则必须返回最终音频 URL；检查登录、Token、音色代码是否真的进入请求，以及响应是否为 401/JSON 错误。 |
| CSS 在小页面可用、大页面失效 | HTML 超过 4 MiB 保护阈值；寻找 JSON API 或减少响应。 |
| Android 阅读中可用、此处不可用 | 查看该阶段是否路由 ArkWeb、是否调用未映射 `java/source/cache/cookie` 方法、浏览器直连网络、复杂 XPath/CSS 或未消费字段。 |

### 11.5 批量书源校验状态

书源管理中的校验不是简单的“成功/失败”二值：

| 状态 | 含义 |
| --- | --- |
| 通过 | 搜索请求成功并解析出至少一条有效书籍。 |
| 失败 | 缺少必要规则、明确的 4xx 请求错误、规则/选择器语法错误或预检判定不安全。 |
| 无结果 | 请求和规则执行完成，但测试关键字没有有效书籍。 |
| 需要验证 | HTTP 401/403，或响应被识别为登录/验证码页面。 |
| 暂时异常 | 超时、取消、429、5xx、空响应、响应过大或其他暂时网络问题。 |

校验模式使用更保守的限制：并发 1、单响应 512 KiB、单条可执行规则 32 KiB、书源脚本配置 512 KiB，并拒绝高风险嵌套正则。日常搜索允许更大的响应和聚合脚本，因此“校验失败：配置过大”不必然等于日常链路完全不能运行，但仍应缩小测试脚本或按阶段验证。401/403 应归类为“需要验证”，不应批量禁用或删除。

## 12. 编写质量建议

- 只使用目标站授权或允许访问的内容，并遵守服务条款、版权和访问频率限制。
- `bookSourceUrl` 使用稳定的站点根地址，不要把搜索参数当作唯一键。
- 规则尽量短、确定；优先明确 ID/class/JSON 字段，少用跨整页的贪婪正则。
- 列表规则只负责选元素，字段规则只负责取字段，净化规则只负责清理文本。
- 必填字段不要依赖兜底逻辑；应用中的站点特例主要用于兼容已有源，不是稳定 API。
- 请求头只保留必要项。伪造过多浏览器安全头可能比缺省更容易失效。
- `replaceRegex` 从小到大增加，并用第一章、VIP 章、最后一章验证，避免误删全文。
- 对 JSON 中的反斜杠进行双重转义。例如正则 `\s+` 在 JSON 字符串中写作 `"\\s+"`。
- 提交公共书源前删除 Cookie、Token、账号、设备标识和调试接口。
- 在备注中说明源类型、登录要求、已知限制和维护日期。

## 13. 兼容性与当前限制

### 13.1 字段能力矩阵

| 状态 | 字段/能力 |
| --- | --- |
| 通用链已实际使用 | 搜索/发现的列表、书名、作者、封面、简介、分类、最新章节、详情 URL；`jsLib` URL 构建和持久化源变量；分阶段 ArkWeb；动态登录输入/开关/选择/按钮、同站点 Cookie、书源内加密、浏览器等待；详情 `init`、书籍字段、目录 URL；目录列表、章节名、章节 URL、下一页、VIP、更新时间；正文内容、图片、图片请求头、书源规则内图片解码、漫画模式、下一页、净化正则和 JS；普通书/漫画/有声书类型；书源请求限流。 |
| 编码数据已实际使用 | 标准 `data:` 文本、Base64 负载，以及带明确 HTTP(S) URL 的通用 `type: "request"` 请求描述。应用不提供平台协议、候选后端或站点专用转换。 |
| 可导入/编辑，但通用链目前未消费 | 详情 `updateTime`；目录 `isPay`；正文 `title`；非登录请求的 `webView`、`webJs` URL 选项。 |
| 模型或紧凑格式存在，但通用导入/UI/执行不完整 | `chapterListAddition`、`payAction`、`bookListRule` 等。 |
| 不应假定与 Android 版等价 | 任意 Java/Android 类导入、全部 `java.*` API、浏览器直连网络、任意 WebView DOM 抓取、完整 XPath/CSS、付费购买动作及非白名单二进制解码流程。 |

### 13.2 实现中的通用兜底

当前项目只保留与站点无关的容错，例如清理模板残留、解析标准相对 URL、从通用字段回退详情地址、提取可读 HTML 和处理明确的编码数据。应用不会根据站点名称或私有接口提供自动修复；书源应完整声明请求和解析规则。

### 13.3 与 Android 阅读书源互导

导入 Android 阅读书源时建议：

1. 保留标准对象形式的 `ruleSearch` 等规则组；
2. 删除当前不需要的字段，先验证最小链路；
3. 将复杂 XPath 改为 JSONPath/CSS；
4. 简单 JS 优先改为模板或 `##`；确需完整语义时确认该阶段已路由 ArkWeb，且只调用已桥接主机方法；
5. 普通搜索/目录/正文的 WebView 抓取仍优先改成 HTTP 接口；登录动作可使用已支持的 `startBrowserAwait`/`java.webView`；
6. 对登录、Cookie、加密源逐项实机验证；
7. 对普通书、漫画、有声书和段评分别验证正文后处理与播放器；
8. 不以“导入成功”或“校验通过”作为全链路兼容的证明。

## 14. 完整模板

下面模板列出当前可导入的主要字段，复制后删除不需要的项：

```json
[
  {
    "bookSourceName": "",
    "bookSourceUrl": "https://example.com",
    "bookSourceType": 0,
    "bookSourceGroup": "",
    "bookSourceComment": "",
    "loginUrl": "",
    "loginUi": "",
    "loginCheckJs": "",
    "loginHeader": "",
    "bookUrlPattern": "",
    "searchUrl": "",
    "exploreUrl": "",
    "jsLib": "",
    "header": "{}",
    "variableComment": "",
    "enabled": true,
    "enabledExplore": true,
    "enabledCookieJar": true,
    "isPinned": false,
    "isLocked": false,
    "weight": 0,
    "customOrder": 0,
    "respondTime": 180000,
    "concurrentRate": "",
    "customButton": false,
    "eventListener": false,
    "ruleSearch": {
      "bookList": "",
      "name": "",
      "author": "",
      "coverUrl": "",
      "intro": "",
      "kind": "",
      "lastChapter": "",
      "bookUrl": "",
      "wordCount": ""
    },
    "ruleExplore": {
      "bookList": "",
      "name": "",
      "author": "",
      "coverUrl": "",
      "intro": "",
      "kind": "",
      "lastChapter": "",
      "bookUrl": "",
      "wordCount": ""
    },
    "ruleBookInfo": {
      "init": "",
      "name": "",
      "author": "",
      "coverUrl": "",
      "intro": "",
      "kind": "",
      "lastChapter": "",
      "wordCount": "",
      "updateTime": "",
      "tocUrl": ""
    },
    "ruleToc": {
      "chapterList": "",
      "chapterName": "",
      "chapterUrl": "",
      "nextTocUrl": "",
      "isVip": "",
      "isPay": "",
      "updateTime": "",
      "chapterListAddition": ""
    },
    "ruleContent": {
      "content": "",
      "title": "",
      "images": "",
      "nextContentUrl": "",
      "replaceRegex": "",
      "imageDecode": "",
      "imageStyle": "",
      "payAction": ""
    }
  }
]
```

## 15. 实现索引

需要继续扩展规则能力时，可从这些实现入口核对：

- 数据模型：`entry/src/main/ets/model/data/Book.ts`
- JSON 导入兼容：`entry/src/main/ets/pages/BookSource.ets`
- 编辑器字段：`entry/src/main/ets/pages/BookSourceEdit.ets`
- URL 和请求选项：`entry/src/main/ets/core/rule/AnalyzeUrl.ts`
- 通用规则解析：`entry/src/main/ets/core/rule/AnalyzeRule.ts`
- JSONPath：`entry/src/main/ets/core/rule/JsonPathEvaluator.ts`
- JS 兼容层：`entry/src/main/ets/core/rule/JsRuntime.ts`
- 分阶段运行路由：`entry/src/main/ets/core/book/BookSourceRuntimeRouter.ts`
- 搜索/发现/详情/目录/正文 ArkWeb：`entry/src/main/ets/core/book/BookSourceStageWebRuntime.ts`
- 阶段规则识别：`entry/src/main/ets/core/book/BookSourceStageRuleSupport.ts`
- 登录面板 ArkWeb：`entry/src/main/ets/core/book/BookSourceLoginWebRuntime.ts`
- 搜索流程：`entry/src/main/ets/core/book/SearchCoordinator.ts`
- 发现流程：`entry/src/main/ets/core/book/ExploreCoordinator.ts`
- 详情、目录、正文：`entry/src/main/ets/core/book/WebBookService.ts`
- 编码地址与快捷协议：`entry/src/main/ets/core/book/BookSourceDataUrlSupport.ts`、`entry/src/main/ets/core/book/EncodedSourceUrl.ts`
- 正文交互后处理：`entry/src/main/ets/core/book/BookSourceInteractionPostProcessor.ts`、`entry/src/main/ets/core/book/ReaderActionMarker.ts`
- 书籍类型识别：`entry/src/main/ets/core/book/BookTypeSupport.ts`
- 有声书页面与后台播放：`entry/src/main/ets/pages/AudioBook.ets`、`entry/src/main/ets/utils/RemoteAudioPlayback.ets`、`entry/src/main/ets/utils/ReaderTtsFloatingSession.ets`
- 数据库存储：`entry/src/main/ets/model/data/AppDatabase.ts`
