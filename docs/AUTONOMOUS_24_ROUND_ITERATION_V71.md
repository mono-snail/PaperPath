# PaperPath V71：高频工作区与可靠复核

## 本轮目标

本轮面向发布前的高频体验收敛，对照 PDF Expert、Adobe Acrobat 和
PDFgear 的 iPhone / iPad 工作流，改善工具发现、工作区直达、批注交付、
版本比较和辅助功能。所有改动继续服从本地优先、原件不覆盖和可信输出定位，
不通过接入云端 AI 或扩大不可靠编辑边界追求功能数量。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V70、当前脏工作区和持续迭代约束 | 不覆盖既有扫描与可信交付成果 |
| 2 | 对照 PDF Expert、Acrobat 和 PDFgear 官方移动端能力 | 只选择符合 PaperPath 定位的高频差距 |
| 3 | 修复工作区父级无障碍标识覆盖子按钮 | 自动化与辅助技术可准确识别每个操作 |
| 4 | 将含糊的 More 改为明确的 Tools | 用户无需猜测入口内容 |
| 5 | 工作区长按 Tools 直达收藏工具 | 高频工具无需重复进入完整面板 |
| 6 | 收藏与最近工具分区展示并去重 | 快捷入口稳定且不会重复 |
| 7 | 无快捷项时提供简洁 VoiceOver 提示 | 辅助功能不会宣告不存在的操作 |
| 8 | 工具搜索增加标题、别名、详情和分组权重 | 精确命中优先于弱相关结果 |
| 9 | 多词搜索保持全部词项匹配 | 降低宽泛结果噪声 |
| 10 | 搜索结果取消分组阻隔并统一排序 | 最佳工具不再被类别位置埋没 |
| 11 | 搜索评分增加稳定同分排序 | 相同输入始终得到可预测顺序 |
| 12 | 缩短任务包与页面整理摘要 | 双列布局在小屏和大字体下更稳定 |
| 13 | 补齐推荐原因与风险提示简体中文 | 中文用户可理解推荐依据 |
| 14 | 收藏按钮动态 VoiceOver 文案本地化 | 添加和移除状态表达准确 |
| 15 | 验证分享标签和提示本地化 | 明确分享的是已检查产物而非工作副本 |
| 16 | 状态信号动态组合改用格式化本地化 | 检查结果在中英文下都可完整朗读 |
| 17 | 书签、前进、后退和缩略图页码本地化 | 阅读导航对 VoiceOver 更连续 |
| 18 | 批注摘要类型和 PaperPath 批注名称本地化 | 导出摘要与当前语言一致 |
| 19 | 文档名、范围、标题和正文进行 Markdown 转义 | 外部内容不能破坏摘要结构 |
| 20 | 批注摘要改为单一字符串增量构建并预留有界容量 | 大批注集合减少中间数组和完整副本峰值 |
| 21 | 版本候选统一使用同源、最近查看、名称兜底排序 | 默认比较对象相关且可预测 |
| 22 | 锁定文档过滤和最终 UUID 兜底进入统一候选契约 | 两个比较入口行为一致且确定 |
| 23 | PDFKit 页变更回调退出同步视图更新栈后再写状态 | 消除工作区打开时的 SwiftUI 状态重入警告 |
| 24 | 新增回归契约并完成单测、UI、双架构和静态门禁 | 体验优化拥有可重复验证基线 |

## 核心变化

### 工具发现与工作区效率

- 工具面板在搜索时展示统一的相关度结果，不再先按分组切断最佳匹配。
- 完全匹配、标题前缀、标题词、别名、详情和分组依次降权。
- 工作区底栏使用明确的 Tools 入口；长按先显示收藏，再显示未重复的最近工具。
- 收藏仍在完整工具面板维护，避免在紧凑工作区增加新的常驻控件。
- 任务摘要缩短为用户目标和核心动作，避免为了罗列功能破坏双列扫描效率。

### 批注摘要可靠性

- Markdown 导出对换行、反斜杠、标题、链接、强调、引用和表格标记转义。
- PDF 内部或用户输入的文本不能伪造新的标题、列表或链接结构。
- 批注类型及 PaperPath 生成类型在导出前本地化。
- 摘要按页排序后直接追加到单一字符串，避免字符串数组与最终拼接结果同时
  常驻；容量预留上限为 6 MB。
- 每条批注正文仍限制为 500 个字符，并在循环中传播取消。

以上内存收益来自实现结构，属于预期改善，尚未通过真机 Instruments 量化。

### 版本比较确定性

候选排序由模型层统一定义：

1. 当前文档的直接来源或直接派生版本。
2. 与当前文档共享来源的同级版本。
3. 最近查看的兼容文档。
4. 未查看文档按本地化名称稳定排序。
5. 同名时按修改时间和 UUID 兜底。

锁定 PDF 不进入比较候选。工作区检查器和完整比较页使用同一规则，避免同一
资料库在不同入口默认选择不同文档。

### SwiftUI 与 PDFKit 状态边界

运行时日志确认 `PDFViewPageChanged` 会在 `UIViewRepresentable` 创建或更新
期间同步发出。旧实现立即写回 SwiftUI 页码状态，产生
`Modifying state during view update`。V71 保留 PDFKit 通知，但将回调安排到
下一次主队列执行。

修复前后使用同一版本比较 UI 流程验证：

- 修复前：页变更日志后立即出现三条状态重入警告。
- 修复后：流程通过，`xcresult` 中不再出现该运行时警告。

### 本地化与辅助功能

- 补齐推荐原因、隐私风险、收藏工具、验证分享和动态页码的简体中文。
- 动态 VoiceOver 文案统一通过格式化本地化生成，不再拼接固定英文。
- 删除覆盖整组工作区按钮的父级 identifier，保留每个实际操作自己的稳定
  identifier。
- UI 测试对 SwiftUI 转场中的重复 accessibility 快照使用可见首项，避免把
  XCUITest 快照竞态误判为双入口。

## 竞品对照

### PDF Expert

PDF Expert 官方资料强调阅读模式、搜索历史与书签、可定制工具栏，以及可搜索
和导出的批注摘要。V71 吸收的是高频操作可达性和批注汇总模式：

- 收藏与最近工具从工作区直接触达。
- 工具搜索按相关度统一排序。
- 批注摘要可本地生成 Markdown，并对不可信内容转义。
- 书签和前进/后退历史保留动态页码。

PDF Expert 的文本重排阅读、工具栏定制深度和 Apple 设备间成熟度仍更强。

### Adobe Acrobat

Adobe 官方移动端资料列出阅读、搜索、批注、填表、签名和安全分享；高级编辑、
导出、密码保护、PDF Spaces 与 AI Assistant 属于订阅能力。PaperPath 不复制
云协作或在线 AI，而强化另一条路径：

- PDF、文件名、OCR 文本和提取内容不新增自建上传路径。
- 工作副本与已验证分享产物明确分离。
- 交付前重开审计、SHA-256 Receipt 和来源追溯在同一本地工作流内完成。
- 无账号、无广告、无订阅，完整功能采用一次性买断。

Acrobat 的云协作、跨平台生态、任意版式编辑和 AI 能力仍明显更广。

### PDFgear

PDFgear 官方 iOS 页面强调免费文本编辑、批注、表单、签名、页面整理和 AI
问答。PaperPath 不在免费功能数量或聊天能力上宣称领先，本轮形成的差异是：

- 核心输出有原件保护、失败关闭、重开验证和 Receipt 证据。
- 版本比较默认对象具备明确、可测试的确定性规则。
- 批注摘要不依赖云端分析，且输出结构防止文档内容注入 Markdown。
- 所有高频改进继续在本机完成。

PDFgear 的免费功能广度和 AI 文档交互仍更有吸引力。

参考（检索日期：2026-08-22）：

- [PDF Expert 官方功能页](https://pdfexpert.com/)
- [PDF Expert 批注列表与搜索](https://support.readdle.com/pdfexpert/en_US/annotate-pdfs/view-and-export-annotation-summary)
- [Adobe Acrobat Reader](https://www.adobe.com/acrobat/pdf-reader.html)
- [Adobe Acrobat Mobile FAQ](https://helpx.adobe.com/ph_en/acrobat/mobile/get-started/faqs.html)
- [PDFgear for iOS](https://www.pdfgear.com/pdfgear-for-ios/)

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
- `PaperPath/Views/DocumentToolPalette.swift`
- `PaperPath/Views/DocumentWorkspaceView.swift`
- `PaperPath/Views/AnnotationReviewView.swift`
- `PaperPath/Views/DeliveryReceiptView.swift`
- `PaperPath/Views/PDFKitViews.swift`
- `PaperPath/Views/RootView.swift`
- `PaperPath/Components/ProductComponents.swift`
- `PaperPath/Core/Localization.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `PaperPathTests/PaperPathTests.swift`
- `PaperPathUITests/PaperPathUITests.swift`

## 工程验证

### 单元测试

- 总数：167。
- 通过：166。
- 跳过：1 项真机限定测试。
- 失败：0。

新增或扩展的契约覆盖 Markdown 转义、工具搜索相关度、比较候选关系与稳定
排序。

### UI 测试

- 总数：12。
- 通过：12。
- 失败：0。
- 最终完整运行耗时：313.63 秒。
- `xcresult` 中没有 `Modifying state during view update`。

### Release Simulator

- `PaperPath` arm64：通过。
- `PaperPathShareExtension` arm64：通过。
- `PaperPath` x86_64：通过。
- `PaperPathShareExtension` x86_64：通过。

### 静态门禁

- Info plist 语法通过。
- StoreKit JSON 语法通过。
- 简体中文重复键检查通过。
- `git diff --check` 通过。

## 可验证竞争优势

- 高频工具具备搜索相关度、收藏和最近使用三条互补路径。
- 本地批注摘要兼顾类型本地化、结构转义、取消传播和有界容量预留。
- 版本比较候选不依赖资料库瞬时数组顺序。
- PDFKit 与 SwiftUI 状态桥接不再产生已复现的同步更新警告。
- 核心交付继续提供源文件隔离、输出复核和可追溯 Receipt。

这些优势限定于上述工作流，不代表功能总量全面超过 Acrobat、PDF Expert 或
PDFgear。

## 未验证风险

- 批注摘要峰值内存下降尚未通过真机 Instruments 量化。
- 收藏工具长按菜单仍需 VoiceOver 真机手势走查。
- 搜索排序尚未基于真实用户查询日志调权。
- iPad 多窗口、外接键盘和 Apple Pencil 未在本轮人工回归。
- 第三方密码 PDF、VisionKit 相机和真实 iCloud 账号传播仍需真机门禁。

## 下一阶段

1. 真机量化一万条批注摘要的峰值内存、耗时和能耗。
2. 用真实任务语料评估工具搜索首位命中率，再决定是否调整权重。
3. 补齐 Receipt 与版本里程碑的双向跳转。
4. 继续字符级差异证据和重复模板锚点，但不得弱化现有区域级证据。
5. 完成 iPad 多窗口、Apple Pencil、锁屏文件保护和第三方密码 PDF 门禁。
