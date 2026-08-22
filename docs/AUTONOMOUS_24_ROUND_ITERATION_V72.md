# PaperPath V72：可信输出与版本证据链

## 本轮目标

本轮继续对照 PDF Expert、Adobe Acrobat / Acrobat Sign 和 PDFgear，收敛
PaperPath 的可信交付体验。启动审计确认字符级差异、重复模板锚点、版本容量
治理和基础双向入口已经存在，因此没有重复开发提示词中的过期候选，而是处理
一个真实断点：

> Delivery Receipt 能打开已有里程碑，却不能把当前可信输出或匹配的恢复版本
> 一键固化为精确、可回溯的受保护版本。

V72 将 Receipt、SHA-256、内容修订 ID 和本地版本文件组成一条失败关闭的双向
证据链，同时修复小屏信息截断和真实 Accessibility XXXL 下的可达性。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V71、持续迭代约束和当前脏工作区 | 保留既有成果，不机械重复开发 |
| 2 | 审计字符级差异、模板锚点、双向入口和容量治理 | 确认提示词候选多数已落地 |
| 3 | 对照三类竞品的编辑、免费工具和审计能力 | 将目标收敛到本地可信交付证据 |
| 4 | 定位 Receipt 无法主动固化精确版本的流程断点 | 用户不再需要先猜测版本管理入口 |
| 5 | 定义 linked / protectCurrent / protectRecovery / unavailable 四态 | 加载、可保护和失效语义不混淆 |
| 6 | 版本匹配始终要求完整 SHA-256 一致 | 错误 Receipt ID 不能冒充可信关联 |
| 7 | 新 Receipt 额外要求内容修订 ID 一致 | 同字节以外继续校验工作副本身份 |
| 8 | 旧 Receipt 缺修订 ID 时保留 SHA-256 兼容 | 历史数据不会被无理由废弃 |
| 9 | 当前 Receipt 状态改为指纹与修订双校验 | 修订 ID 相同但内容不符时失败关闭 |
| 10 | 当前可信输出无快照时自动创建版本 | 一次操作即可获得可恢复证据 |
| 11 | 工作副本变化时复用精确匹配的历史版本 | 不把新工作副本错误固化到旧 Receipt |
| 12 | 保护前重新校验版本文件指纹 | 索引存在但文件损坏时拒绝关联 |
| 13 | 重复保护返回同一里程碑 | 不产生重复快照和额外存储占用 |
| 14 | 复用 32 项 / 1 GB 固定里程碑预算 | 新能力不绕过既有容量治理 |
| 15 | 保护操作接入文档独占锁 | 避免与写盘、恢复或其他变更并发 |
| 16 | Receipt 增加加载、保护、恢复和不可用状态 | 用户可理解证据当前处境 |
| 17 | Receipt 展示最多四个关联里程碑及总数入口 | 保持信息密度且不形成无限列表 |
| 18 | Receipt 可直接打开目标版本历史 | 从交付结论一步进入恢复证据 |
| 19 | 版本历史只在内容精确匹配时反向打开 Receipt | 错误或过期链接不会显示为可信 |
| 20 | 里程碑编辑器区分当前、匹配、失配和归档关联 | 开关文案与实际数据语义一致 |
| 21 | 编辑器改为可滚动并在大字体下使用大尺寸 sheet | XXXL 下底部开关仍可到达 |
| 22 | 共享工作流标题在 iPhone 改为两列指标和多行标题 | 消除标题、标签、修订号和日期截断 |
| 23 | 修复真实 XXXL 测试参数与自适应菜单定位 | 自动化不再把普通字号误当大字号 |
| 24 | 补齐简中、单元/UI 契约、双架构和静态门禁 | 建立可重复发布基线 |

## 核心实现

### 精确证据匹配

`PDFVersionSnapshot.matchesDeliveryReceipt(_:)` 使用以下规则：

1. Receipt 必须处于已验证状态。
2. 版本指纹和 Receipt SHA-256 必须完整且一致。
3. 新 Receipt 存在 `outputRevisionID` 时，版本修订 ID 必须同时一致。
4. 旧 Receipt 没有修订 ID 时，允许以完整 SHA-256 兼容。

`DocumentRecord.hasCurrentDeliveryReceipt` 同步采用相同强度的规则，不再只比较
修订 ID。

### 幂等保护

`DocumentStore.protectDeliveryReceiptMilestone`：

- 优先复用精确匹配的已有版本。
- 当前工作副本仍匹配时，可创建一次当前快照。
- 工作副本已变化时，只能保护匹配 Receipt 的恢复版本。
- 保护前重新读取版本文件并校验指纹。
- 已固定且已关联时直接返回，不重复写索引或复制 PDF。
- 新固定版本继续服从全局 32 项 / 1 GB 预算。

模型层使用文档独占操作令牌包裹整个流程，避免与恢复、编辑和其他 PDF 写操作
并发。

### 双向导航与失效表达

Receipt 的 `VERSION EVIDENCE` 区域始终存在：

- 当前输出可保护：`Protect verified version`。
- 匹配历史版本可保护：`Protect matching recovery version`。
- 已保护：显示关联里程碑并可打开版本历史。
- 无匹配：明确显示 `Matching version unavailable`。

版本历史反向入口只有在 Receipt ID、SHA-256 和新格式修订 ID 全部满足时才能
打开。失配与 Receipt 已删除分别使用不同状态，不能被误读为可信。

## 体验与辅助功能

- iPhone 的 `WorkflowCommandHeader` 使用两列指标，值与标签上下排列。
- 标题允许两行，说明允许三行；本地处理徽标与眉题共享首行空间。
- `StudioSectionRule` 按文本真实宽度切换纵向布局，日期不再被压成竖排。
- 里程碑编辑器支持滚动；Accessibility 字号使用大尺寸 sheet。
- 新增稳定 identifier 覆盖保护、正向打开、反向打开、编辑器和 Receipt 开关。
- 修正 UI 测试的 Accessibility XXXL 原始值，并兼容大字号下的 Workspace
  菜单形态。

## 竞品对照

### Adobe Acrobat / Acrobat Sign

Adobe 官方资料将 Audit Report 定义为交易事件和里程碑的权威记录，并包含服务
端 Transaction ID、参与者和身份验证等企业审计信息。PaperPath 不宣称替代
该法律和身份体系。

V72 的差异是个人本地工作流：无账号、无自建 PDF 上传路径，Receipt 可以固化
并双向打开与其 SHA-256 / 修订 ID 精确匹配的本地 PDF 版本。

### PDF Expert

PDF Expert 官方能力目录体现了成熟的阅读、编辑、批注、表单、扫描、转换和
Apple 平台体验。V72 不主张工具总量超过 PDF Expert；本轮检索的官方 iOS 能力
目录未展示与 Delivery Receipt 绑定、可双向导航且校验内容指纹的本地版本链。

### PDFgear

PDFgear 官方 iOS 指南强调免费的阅读、编辑、表单、签名、页面整理、转换、
压缩和 AI 助手。PaperPath 不在免费工具数量或 AI 问答上宣称领先；V72 的优势
集中在原件保护、失败关闭、写后验证和可恢复版本证据。

参考（检索日期：2026-08-22）：

- [Adobe Acrobat Sign Audit Reports](https://learn.adobe.com/sign/using/audit-reports-transaction-history.html)
- [Adobe Acrobat Sign 2026 Release Notes](https://helpx.adobe.com/sign/archive/release-notes/2026.html)
- [PDF Expert 官方能力目录](https://support.readdle.com/pdfexpert/en_US/using-pdf-expert)
- [PDFgear for iOS 官方指南](https://www.pdfgear.com/ios-user-guide/intro-to-pdfgear-ios.htm)

## 工程验证

### 单元测试

- 总数：169。
- 通过：168。
- 跳过：1 项真机限定测试。
- 失败：0。
- 覆盖当前版本创建、历史恢复版本保护、幂等、SHA-256 / 修订 ID 双匹配和旧
  Receipt 兼容。

### UI 测试

- 总数：13。
- 通过：13。
- 失败：0。
- 完整运行耗时：354.32 秒。
- 新增普通字号双向证据链与真实 Accessibility XXXL 持久化回归。
- `xcresult` 未检出 SwiftUI 状态重入或 Main Thread Checker 警告。

### Release Simulator

- `PaperPath`：`arm64 + x86_64` 通过。
- `PaperPathShareExtension`：`arm64 + x86_64` 通过。

### 静态门禁

- 主 App 与 Share Extension Info plist 通过。
- StoreKit JSON 通过。
- 简体中文 strings 语法及重复键检查通过。
- `git diff --check` 通过。

## 性能与边界

- Receipt 展示只读取有界版本索引并比较元数据，不在列表加载阶段重新哈希 PDF。
- 用户真正保护版本时才重新校验目标文件指纹。
- 幂等复用避免重复 PDF 副本和重复存储预算消耗。
- 保护任务支持取消 UI 回写，写操作受 actor 串行化和文档独占令牌保护。
- 本轮没有真机耗时、内存或能耗数据，不据此提高绝对性能评分。
- PaperPath 的优势限定在本地可信交付闭环；Acrobat 的企业签署审计、PDF
  Expert 的成熟编辑体验、PDFgear 的免费功能广度仍各有明显优势。

## 修改文件

- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Components/ProductComponents.swift`
- `PaperPath/Models/DocumentModels.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `PaperPath/Services/DocumentStore.swift`
- `PaperPath/Views/DeliveryReceiptView.swift`
- `PaperPath/Views/DocumentInsightView.swift`
- `PaperPathTests/PDFCoreServiceRegressionTests.swift`
- `PaperPathTests/PaperPathTests.swift`
- `PaperPathUITests/PaperPathUITests.swift`

## 下一阶段

1. 在真机上量化首次创建受保护版本的耗时、峰值内存和能耗。
2. 用长期样本验证 32 项 / 1 GB 预算接近上限时的治理体验。
3. 为版本归档增加可验证 manifest，延伸本地证据链到 App 外部备份。
