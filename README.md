# 开源轻页

开源轻页是一款使用 ArkTS / ArkUI 开发的 HarmonyOS NEXT 本地阅读应用，面向手机、平板和 PC/2in1，提供书架、搜索、发现、书源管理、正文阅读、漫画、有声书、朗读与个性化设置等能力。

| 项目 | 信息 |
| --- | --- |
| 应用包名 | `io.legado.read` |
| 当前版本 | `3.6.818`（以 `AppScope/app.json5` 为准） |
| 支持设备 | `phone`、`tablet`、`2in1` |
| 最低 API | HarmonyOS API 12 |
| 目标 API | HarmonyOS API 23 |
| 开源协议 | GPL-3.0 |

> [!IMPORTANT]
> 本项目不内置、不托管、不分发小说正文、章节、封面、付费资源或书源订阅。应用仅处理用户自行导入且具备合法使用权限的书源规则与本地文件。使用前请确认内容授权、目标站点协议及所在地法律法规要求。

## 快速开始

1. 使用 DevEco Studio 打开项目，配置 HarmonyOS SDK 与本地签名。
2. 构建并安装 `entry` 模块。
3. 进入「我的 → 书源管理」，导入自有或已获授权的书源 JSON。
4. 根据需要启用搜索、发现或书源登录，并先执行书源校验。
5. 在「搜索」或「发现」中查找书籍，加入书架后开始阅读。
6. 阅读本地文件时，在「书架设置 → 添加书籍」中选择一个或多个 TXT/EPUB 文件。
7. 在阅读页呼出菜单，调整排版、翻页、主题、预缓存与朗读设置。

## 核心能力

### 书架与本地书籍

- 管理普通书、漫画和有声书，支持继续阅读、分组、排序、换源、缓存、批量操作和删除。
- 支持平铺、紧凑和宽松布局，以及封面、简介、标签、阅读进度、最近阅读大卡片和类型标识。
- 本地书籍可一次多选导入 TXT/EPUB，使用应用自身的文件访问能力，不依赖公共目录扫描。
- 支持指定章节缓存和全文后台缓存，并可通过通知查看进度或取消任务。
- 支持最近阅读记录、桌面快捷项和桌面服务卡片。

### 搜索与发现

- 对已启用书源执行并发搜索，增量展示结果，并支持停止搜索、精准搜索、作者匹配、分组筛选和单书源搜索。
- 搜索链路包含异常地址过滤、模板残留清理、结果隔离与网页验证识别。
- 发现页读取书源的站点、分类和榜单入口，支持书源切换、刷新、缓存与排序。
- 搜索和发现设置集中管理，并发数、展示项和书源启用状态可独立配置。

### 书源管理

- 支持从 URL、剪贴板、本地 JSON 或文本文件导入书源。
- URL 导入可依次尝试应用 HTTP、明文 HTTP TCP、ArkWeb 下载和系统下载服务，并输出可读错误。
- 导入时保留标准字段、原始 JSON、未知字段、登录配置与运行参数；导出时尽量保持往返完整性。
- 支持编辑、分组、锁定、导出、删除，以及批量启用/禁用搜索与发现。
- 支持校验单个或所选书源，并区分“通过、失败、无结果、需要验证、暂时异常”。明确失败项可批量禁用或删除。
- 校验进度聚焦已完成数量和状态，不使用“命中 X 本”作为规则有效性的判断。
- 支持动态 `loginUi`、登录检测 JS、网页验证、同站点 Cookie 同步和登录状态持久化。

### 阅读

- 支持书籍详情、章节目录、正文解析与本地章节缓存。
- 支持字号、行距、段落间距、四周边距、自定义字体、背景、深色模式和沉浸式布局。
- 支持横向滑动、仿真翻页、滚动阅读、横屏双页，以及章节间预览和预缓存。
- 支持正文扩展至状态栏、书签、正文替换规则、章节评论和书源显式提供的网页交互标记。
- 支持漫画连续全宽阅读，以及携带书源请求头、Cookie 或解码规则的远程图片。
- 网页动作、图片和媒体标记不会混入朗读文本。

### 朗读与有声书

- 支持系统 TTS、自定义 HTTP TTS、语速、定时停止、章节切换、后台朗读和系统媒体控制。
- 可导入原版 `HttpTTS` JSON，并配置请求 URL、请求头、Content-Type、并发数、登录地址、脚本库和 Cookie jar。
- 系统 TTS 与 HTTP TTS 优先通过 PCM 和 `AudioRenderer` 输出，并结合音频预取与播放状态保护提升连续性。
- 有声书使用独立远程播放器，支持进度、倍速、目录跳转、定时停止和音色代码。
- 有声书可在返回书架或进入后台后继续播放，并复用全局播放胶囊与 AVSession。锁屏媒体卡片由系统策略决定，应用无法强制使用音乐播放器样式。

### 数据、同步与个性化

- 支持应用数据备份/恢复、WebDAV 和账号云同步。
- 书源、书架、章节进度、阅读设置、主题、书架展示配置和 TTS 配置按各自策略保存。
- 支持浅色/深色模式、主题包、按钮色、强调色、自定义字体、阅读背景、封面图库和应用图标。
- 正则字体支持文字强调、高亮色块、胶囊、纸笺、霓虹及主题专属样式。

## 书源规则兼容

当前重点支持以下规则能力：

- HTTP GET/POST、请求头、请求体、URL 模板、Cookie 注入和 `Set-Cookie` 保存。
- JSONPath、CSS、基础 XPath、旧式链式规则、属性提取、规则分段和正则后处理。
- `<js>` / `@js:` 混合规则；复杂 JavaScript 可按搜索、发现、详情、目录和正文阶段路由到受控 ArkWeb 环境。
- 常见 `java.xxx`、`source.xxx`、`book.xxx`、`cache.xxx` 和 `cookie.xxx` 主机函数。
- Base64、Hex、摘要、URL/HTML 编解码、对称加密和标准 `data:` 数据。
- 动态登录面板、`startBrowserAwait`、登录页脚本、验证码跳转和跨地址 Cookie 同步。
- 普通文本、漫画和有声书类型识别，以及正文中的显式网页操作、图片和媒体标记。

完整字段、请求格式、解析语法和调试方法见 [书源开发文档](docs/book-source-development.md)。

## 项目结构

```text
legado-harmony/
├── AppScope/                         # 应用级配置与资源
├── entry/                            # 主应用模块
│   └── src/main/ets/
│       ├── components/               # 通用 ArkUI 组件
│       ├── core/
│       │   ├── book/                 # 搜索、发现、详情、目录和正文协调
│       │   ├── concurrency/          # 协作式调度与耗时保护
│       │   ├── http/                 # HTTP、Cookie、TLS 与验证支持
│       │   ├── rule/                 # URL、选择器、正则和 JS 规则解析
│       │   └── script/               # 通用脚本运行支持
│       ├── entryability/             # 应用入口 Ability
│       ├── model/                    # 数据模型与本地数据库
│       ├── pages/                    # 页面与设置界面
│       ├── theme/                    # 主题模型、注册表和运行时令牌
│       └── utils/                    # 设置、缓存、字体、TTS 与音频工具
├── quickjs/                          # QuickJS 原生模块
├── docs/                             # 开发文档
└── scripts/                          # 构建前与架构回归检查
```

主要模块：

- `SearchCoordinator` / `ExploreCoordinator`：搜索与发现的并发、进度、解析和结果汇总。
- `WebBookService` / `ReadBookEngine`：详情、目录、正文、缓存和阅读状态。
- `AnalyzeUrl` / `AnalyzeRule`：请求描述、选择器、正则与脚本规则解析。
- `BookSourceRuntimeRouter` / `BookSourceStageWebRuntime`：复杂 JavaScript 的分阶段运行与受控桥接。
- `BookSourceLoginWebRuntime`：登录面板、WebView、Cookie、加密和状态持久化。
- `SystemTtsReader` / `HttpTtsReader` / `RemoteAudioPlayback`：系统朗读、HTTP TTS 与有声书播放。
- `AppDatabase`：书源、书籍、章节、搜索历史、分页缓存和本地配置。

## 开发与构建

### 环境要求

- DevEco Studio
- HarmonyOS SDK `6.1.0(23)`
- ArkTS / ArkUI
- hvigor

当前应用配置：

| 配置 | 值 |
| --- | --- |
| 主模块 | `entry` |
| 入口 Ability | `EntryAbility` |
| `versionName` | `3.6.818` |
| `versionCode` / `buildVersion` | `360818` |
| `minAPIVersion` | `12` |
| `targetAPIVersion` | `23` |
| 权限 | `INTERNET`、`KEEP_BACKGROUND_RUNNING` |

### 命令行构建

以下命令以 DevEco Studio 默认安装目录为例：

```powershell
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
```

构建调试 HAP：

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

构建默认 APP：

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  assembleApp --no-daemon
```

构建 release APP：

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
  --mode project -p product=release assembleApp --no-daemon
```

常用输出位置：

- 调试 HAP：`entry/build/default/outputs/default/entry-default-signed.hap`
- release APP：`build/outputs/release/legado-harmony-release-signed.app`

release 构建依赖本机有效的签名证书、Profile 和 keystore。请使用本地签名配置，不要向仓库提交私钥、证书密码或个人绝对路径。构建产生的 `build`、`oh_modules` 等中间目录也不应提交。

### 回归检查

```powershell
node scripts/neutral-source-engine-check.mjs
node scripts/thread-blocking-check.mjs
node scripts/theme-framework-check.mjs
```

- `neutral-source-engine-check`：检查是否引入固定内容接口、默认凭据或站点专用后端。
- `thread-blocking-check`：检查协作式调度、分页和运行时隔离约束。
- `theme-framework-check`：检查主题注册、令牌和资源安全约束。

这些脚本用于代码回归，不能替代授权审查、安全审计或法律意见。

## 调试

关键日志标签：

| 标签 | 范围 |
| --- | --- |
| `[SC]` | 搜索请求、响应、结果清洗和进度 |
| `[ExploreCoordinator]` | 发现站点、分类和列表解析 |
| `[WS]` | 详情、目录、正文和验证响应 |
| `[RE]` | 阅读引擎、目录缓存和章节加载 |
| `[InteractionPostProcessor]` | 评论、正文动作和媒体标记 |
| `[TTS]` / `[HttpTtsReader]` | 系统 TTS 与 HTTP TTS |
| `[RemoteAudioPlayback]` | 有声书请求、预取和播放状态 |

建议按“搜索结果 → 详情地址 → 详情解析 → 目录 → 正文 → 发现”的顺序排查。遇到登录或验证码响应时，先在验证页完成登录并同步 Cookie，再重试相应链路。

## 已知限制

- 书源兼容层不是完整的 Android Java/WebView 环境。
- 分阶段 ArkWeb 只开放受控桥接；`fetch`、`XMLHttpRequest`、`WebSocket`、任意 Java 导入、文件、进程、反射和系统组件不会自动可用。
- 非登录阶段的 `webView` / `webJs` 选项不会自动把普通请求切换为完整页面渲染抓取。
- 依赖浏览器指纹、长期动态渲染、强反爬、付费权限或私有登录流程的站点不保证支持。
- 私有评论、音频或聚合协议仍受服务授权、会话 Token 和接口变更影响。
- 自定义 HTTP TTS 依赖第三方音源的授权方式、Cookie 和返回格式，无法保证全部兼容。
- 当前正文体验以自研 ArkUI 阅读页为主，Reader Kit 深度能力仍在验证中。
- UI、主题和设置项仍在持续迭代。

## 文档

- [书源开发文档](docs/book-source-development.md)
- [主题开发指南](docs/theme-development.md)
- [主题图片提示词](docs/theme-cat-pipi-image-prompts.md)
- [华为账号与 IAP 发布检查清单](docs/huawei-account-iap-release-checklist.md)

## 合规与免责声明

- 本项目不推荐、维护或背书任何第三方内容站点。
- 公开仓库不提供真实书源、订阅地址或指向第三方内容站点的可导入配置。
- 开发与测试应使用本地受控服务、合成数据或已获得明确授权的内容。
- 项目不会以内置方式破解付费内容、绕过登录或访问控制、规避反爬机制，也不以批量抓取受保护内容为目标。
- 用户应对自行导入的规则、访问行为和内容使用承担责任。

本项目用于阅读器能力学习、技术验证与开源交流，不提供内容分发、内容推荐、书源订阅或资源代取服务。

## 许可证

本项目采用 [GPL-3.0](LICENSE) 许可证。
