# 书源规则开发文档

开源轻页和简听共用书源解析内核 [harmony-book-source-engine](https://github.com/wip3l/harmony-book-source-engine)，规则格式、字段、表达式、选择器及示例都在内核仓库统一维护，本文只保留入口和轻页自己的宿主说明，不再维护副本。

- [公共书源规则开发文档](https://github.com/wip3l/harmony-book-source-engine/blob/main/docs/book-source-development.md)：第一部分原生书源（推荐），第二部分兼容书源（已过时）
- [封面解密 coverDecode](https://github.com/wip3l/harmony-book-source-engine/blob/main/docs/book-source-development.md#加密封面-coverdecode)
- [宿主图片加载接入](https://github.com/wip3l/harmony-book-source-engine/blob/main/docs/cover-decoding.md)
- [内核 HAR 接入说明](https://github.com/wip3l/harmony-book-source-engine/blob/main/sourceengine/README.md)

本仓库以子模块 `harmony-book-source-engine/` 引用内核，克隆后先执行 `git submodule update --init`，本地也可以直接阅读 `harmony-book-source-engine/docs/book-source-development.md`。轻页使用子模块固定的内核提交，内核新增的规则能力要等子模块升级后才在轻页里生效。

## 轻页的宿主差异

| 能力 | 轻页现状（4.1.924） |
| --- | --- |
| 原生书源 | 支持编辑、书源设置（变量、音色、账号登录、动作按钮）、搜索、发现、详情、目录、正文、听书、视频播放与漫画图片解密；书源管理和发现页的长按菜单可进入书源设置 |
| 封面解密 `coverDecode` | 已接入：封面下载时识别 `SourceCoverUrl` 标记，从数据库取该书源后调用 `SourceCoverLoader` 解密并缓存到本地；书架、搜索与发现结果、详情页、听书页、目录面板、阅读统计、桌面卡片和朗读媒体卡片都显示解密后的封面，解密完成前显示占位。局域网阅读的封面接口同样转发解密后的图片。解密结果按封面地址缓存，书源改了 `coverDecode` 参数后，已缓存的封面不会自动重新解密 |
| 脚本提示 `java.toast` | 详情、目录、正文阶段的提示显示为应用内提示，同一书源的同一条提示 15 秒内只显示一次 |
| 网络错误 | 域名解析失败、超时、连接被拒等直接显示真实原因，不会误报“需要登录或网页验证” |
| 书源导入 | URL、剪贴板、本地文件（可一次多选，合并后统一勾选）和系统“打开方式” |
| 书籍类型 | 以详情阶段的结果为准：搜索或发现列表里标为有声、漫画、视频的书，如果详情接口返回的是小说信息，进入详情后按小说处理；书源的有声版与小说版不要共用同一个书籍 ID。有声书在详情页点“开始听书”直接进入听书页 |
| 可选宿主端口 `SourceEngineHost` | 不安装，按内核默认行为运行 |

修改规则格式与开发说明请到内核仓库提交。轻页只维护自己的页面、导入与调试操作和宿主接入说明。
