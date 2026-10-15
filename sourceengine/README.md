# @legado/sourceengine

开源轻页的书源解析内核，以 HAR 形式供应用模块依赖。它包含：

- 兼容书源（阅读格式）的规则解析：`AnalyzeUrl`、`AnalyzeRule`、`JsonPathEvaluator`、`JavaRegexCompat` 与 JS 兼容层。
- 请求层：`HttpClient`、`CookieStore`、`TlsTrustStore`、`HttpAuth`、限流与网页验证支持。
- 原生书源：`NativeSourceSpec`、`NativeExpr`、`NativeSourceRunner`、`NativeSourceService`。
- 脚本运行时：QuickJS 运行、迁移与诊断，以及需要 ArkWeb 的阶段脚本运行时 `BookSourceStageWebRuntime` 和网页抓取 `WebBookFetchRuntime`。
- 数据模型：`model/data/Book.ts` 里的 `Book`、`BookChapter`、`BookSource` 等。

搜索、发现以及详情/目录/正文的调度（`SearchCoordinator`、`ExploreCoordinator`、`WebBookService`）仍在 `entry` 模块里。

## 引入

```json5
// 应用模块的 oh-package.json5
"dependencies": {
  "@legado/sourceengine": "file:../sourceengine"
}
```

`build-profile.json5` 的 `modules` 里还要注册 `sourceengine`。

`Index.ts` 是主入口，只导出 `.ts` 文件，`.ts` 和 `.ets` 都可以从这里导入。`QuickJsDiagnostics` 和 `QuickJsShadowExecutor` 用到了 `@Concurrent`，必须是 `.ets` 文件，所以单独从子入口导入：

```ts
import { QuickJsDiagnostics } from '@legado/sourceengine/Diagnostics';
```

新增公开类型时，把它追加到 `Index.ts`（或 `Diagnostics.ets`）对应的文件分组里。

## 宿主应用需要接入的部分

内核不访问应用数据库，也不包含界面。下面这些由宿主提供：

| 接入点 | 做法 |
| --- | --- |
| 书源运行时状态持久化 | 实现 `BookSourceRuntimePersistence`（读取书源、写回 `variable` / `loginHeader` / `loginInfo`），在启动时调用 `BookSourceRuntimeStore.install(...)`。不安装时读到 `null`，写入被跳过。 |
| ArkWeb 宿主 | `BookSourceStageWebRuntime.get().attach(controller)`、`WebBookFetchRuntime` 需要页面里挂一个 `Web` 组件提供控制器；参考 `entry/src/main/ets/components/BookSourceStageRuntimeHost.ets`、`WebBookFetchRuntimeHost.ets`。 |
| Context | `TlsTrustStore.load(context)`、`QuickJsDiagnostics.initialize(context)` 等 Preferences 存储需要传入应用上下文。 |
| 网页验证 | 遇到验证页时 `VerificationSupport` 写入 AppStorage：`pendingVerificationUrl`、`pendingVerificationTitle`、`pendingVerificationTime`、`pendingVerificationSourceUrl`、`pendingVerificationLoginUrl`。宿主的验证页读取这些值。 |
| QuickJS 诊断刷新 | 存储变化时更新 AppStorage 的 `quickJsMigrationRevision`、`quickJsValidationRevision`、`quickJsRegressionArtifactRevision`，界面可以监听这些值来刷新。 |

## 回归检查

`scripts/` 里的 Node 回归脚本通过 `scripts/lib/ets-module-staging.mjs` 加载本模块的源码。这个工具把 `entry` 和 `sourceengine` 两个源码根合并成同一棵目录树，并把 `@legado/sourceengine` 的导入按名字改写成指向定义文件的相对导入。改动内核后至少运行：

```bash
node --experimental-strip-types scripts/native-source-check.mjs
node scripts/neutral-source-engine-check.mjs
```
