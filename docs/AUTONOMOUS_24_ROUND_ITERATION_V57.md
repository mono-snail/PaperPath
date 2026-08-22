# PaperPath V57：有界批注审查与可恢复批量治理

## 本轮目标

V56 已补齐批量水印与生成批注识别。本轮复核确认，批注审查仍存在三个真实缺口：PDFKit 扫描未设置全局展示上限、长文档缺少批注正文搜索、清理交付稿时只能逐条删除且没有当前工作台内的一步恢复。

V57 将批注列表收敛为本地、有界、可搜索、可批量治理且可验证恢复的专业工作台，不引入账号、云评论、在线协作或新的隐私边界。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 以 V56 未暂存改动和既有暂存工作区为基线 | 不覆盖前序功能和用户修改 |
| 2 | 复核批注读取、筛选、编辑、删除、摘要与撤销链 | 确认真实缺口而非重复加入口 |
| 3 | 核对 Acrobat Mobile、Xodo 的评论筛选与导航模式 | 选择符合专业审阅习惯的交互 |
| 4 | 可编辑批注扫描支持显式结果上限 | 恶意或异常 PDF 不再无限扩张列表 |
| 5 | 定义批注清单、截断状态和展示上限模型 | UI 能准确表达不完整清单 |
| 6 | 可编辑与只读批注共享 10,000 条展示预算 | 保持内存与界面成本有界 |
| 7 | 搜索输入限制为 200 字符 | 避免无界查询状态 |
| 8 | 搜索覆盖正文、批注类型、中英文标题和页码 | 长文档可直接定位审阅项 |
| 9 | 增加符合 iOS 习惯的批注多选模式 | 不再依赖逐条删除 |
| 10 | 只读或无法安全移除的批注不可被选中 | 保留第三方复杂外观和未知类型 |
| 11 | 支持选择或取消选择当前筛选结果 | 可按类型和查询批量治理 |
| 12 | 选择跨筛选保留，重载后自动剔除失效 ID | 批量任务状态连续且不会引用旧对象 |
| 13 | 增加选中数量、当前可移除数量和 2,000 条上限 | 提交前明确影响范围 |
| 14 | 定义携带页、索引、预期类型、正文和生成身份的删除契约 | 后台操作不只相信易漂移索引 |
| 15 | 删除前一次性验证所有目标身份 | 任一批注已变化则整批失败 |
| 16 | 按页分组并按索引倒序移除 | 避免同页删除导致后续索引漂移 |
| 17 | 写入后重开并比较目标页幸存批注多重签名 | 检测误删、丢失和意外变化 |
| 18 | 单次批量移除限制为 2,000 条并传播取消 | 长任务可停止且资源使用有界 |
| 19 | 批量移除接入文档独占、版本快照、原子替换和一步撤销 | 清理交付稿仍可安全恢复 |
| 20 | 单条编辑与删除统一接入即时撤销 | 单次误操作不必进入版本历史 |
| 21 | 摘要可选择全部批注或当前搜索/筛选结果 | 导出内容与用户当前审查目标一致 |
| 22 | Markdown 摘要在后台生成，正文单条限制 500 字符 | 避免大量字符串处理阻塞主线程 |
| 23 | 补齐简体中文、VoiceOver 状态和 Dynamic Type 自适应底栏 | 小屏与辅助功能路径完整 |
| 24 | 完成差异、资源、双架构目标级编译检查 | 保持当前环境可证明的构建门槛 |

## 核心变化

### 有界清单

- `PDFAnnotationInventory` 同时返回批注、截断状态和展示上限。
- 审查工作台最多承载 10,000 条批注；达到上限时明确说明搜索和选择只作用于当前有界清单。
- 可编辑批注先占用预算，只读保留项使用剩余预算，不再形成无界数组。
- 分类计数只在清单加载时生成；搜索或筛选变化时只重建一次可见投影，减少 SwiftUI 重绘中的重复全量扫描。

### 搜索与多选

- 搜索支持批注正文、原始类型、本地化类型标题、`page 12`、`p12`、`页 12` 和 `第 12 页`。
- 当前结果可以一键全选或取消选择；跨筛选选择会保留。
- 只读批注显示锁定状态且不可选择。
- 单次最多选择 2,000 条；达到上限后工具栏明确显示 Limit Reached。

### 可信批量移除

- 删除契约包含页索引、批注索引、预期类型、正文和 PaperPath 生成身份。
- 所有目标先完成身份校验，再执行任何删除。
- 同页批注按索引倒序删除。
- 临时 PDF 重开后，对每个受影响页面比较排序后的幸存批注签名；数组顺序变化不会误报，内容丢失仍会失败关闭。
- 成功后工作台底部提供 Undo，并复用全局版本快照与原子替换机制。

### 摘要导出

- 操作菜单可导出全部批注，或只导出当前筛选/搜索结果。
- 排序、Markdown 生成、文件写入和保护属性设置均在 utility 后台任务执行。
- 每条正文最多写入 500 字符，避免异常注释制造超大临时摘要。
- 临时文件继续使用完整文件保护、排除备份，并在分享结束或取消后清理。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 新增批注清单与批量移除契约。
- `PaperPath/Services/PDFMutationService.swift`
  - 有界扫描、批量身份校验、倒序删除和幸存者重开核验。
- `PaperPath/Services/PDFDocumentStructureService.swift`
  - 只读批注扫描支持共享结果预算。
- `PaperPath/App/PaperPathModel.swift`
  - 有界清单聚合、批量移除事务及编辑/删除即时恢复。
- `PaperPath/Views/AnnotationReviewView.swift`
  - 搜索、多选、批量移除、本地 Undo、截断提示和后台摘要。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - V57 简体中文文案。
- `README.md`
  - 更新批注审查能力清单。

## 编译结果

标准项目命令：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

当前机器仍由环境阻断：Xcode 26.3 提供 iOS Simulator 26.2 SDK，但 CoreSimulator 只安装 26.5 runtime，Scheme 在目标解析阶段报告 `Unable to find a destination`，没有进入代码编译。

当前源码使用目标级降级命令完成验证：

```bash
xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -target PaperPath \
  -configuration Debug \
  -sdk iphonesimulator \
  build CODE_SIGNING_ALLOWED=NO \
  SUPPORTED_PLATFORMS=iphonesimulator \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets

xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -target PaperPathShareExtension \
  -configuration Debug \
  -sdk iphonesimulator \
  build CODE_SIGNING_ALLOWED=NO \
  SUPPORTED_PLATFORMS=iphonesimulator \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets
```

- `PaperPath`：源码编译与链接成功。
- 内嵌与独立 `PaperPathShareExtension`：源码编译与链接成功。
- 产物架构：`arm64`、`x86_64`。
- `git diff --check`、plist、strings 语法与重复键检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞品证据

- Adobe Acrobat Mobile 在 2026 年官方文档中提供评论列表、筛选、跳转、编辑和逐条删除，但共享评论操作依赖 Adobe ID 与云端审阅：
  - https://helpx.adobe.com/acrobat/mobile/review-files/manage-comments.html
  - https://helpx.adobe.com/acrobat/mobile/review-files/review-documents.html
- Xodo Mobile 官方资料提供文档内批注入口；Xodo PDF Studio 的评论面板支持搜索、筛选、选择删除与多格式导出：
  - https://xodo.com/blog/how-to-use-xodo-pdf-reader-and-editor-mobile-app
  - https://feedback.xodo.com/support/solutions/articles/35000251228-comments-panel

PaperPath 当前可证明的差异是：批量删除完全在私有工作副本上执行，具有目标身份校验、原子替换、幸存者重开核验和一步恢复，不要求 PDF 上传或审阅账号。尚无同机任务数据证明整体领先。

## 未验证风险

- 复杂第三方批注在 PDFKit 重写后的外观一致性仍需 Acrobat、Preview、PDF Expert 和 Xodo 样本验证。
- 10,000 条清单、2,000 条批量移除及大正文搜索的真机时间、峰值内存和能耗尚未测量。
- 批注数组在特殊增量更新 PDF 中的索引稳定性只通过写前身份校验保护，尚未做真实异常样本验证。
- 工作台多选、键盘搜索和大号 Dynamic Type 尚未做截图及 VoiceOver 实机走查。
- 标准 Scheme 仍需匹配 Simulator runtime 后复跑。

## 下一阶段

1. 修复 Xcode SDK 与 Simulator runtime 配对并恢复标准双 Scheme 门禁。
2. 使用含重复批注、损坏外观流、超长正文和混合只读类型的样本验证批量治理。
3. 真机测量 1,000、5,000、10,000 条清单搜索和 2,000 条删除。
4. 评估增加作者、颜色和审阅状态筛选所需的标准 PDF 元数据兼容范围。
5. 基于法律与企业用户任务评估 Bates 编号与跨文档连续编号。
