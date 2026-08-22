# PaperPath V56：可审查批量水印与即时恢复

## 本轮目标

V55 已补齐可见页码，但源码复核发现页码只创建版本快照，没有接入页面工作台承诺的一步撤销；同时产品仍缺少合同、报价、内部材料和审阅稿常用的整份文档水印。V56 将两者收敛为同一套可恢复文档标记工作流。

本轮只声明源码和编译可证明的能力，不把“全球领先”作为未经同机任务验证的结论。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 以 V55 和当前已暂存工作区为基线 | 保护已有实现与用户修改 |
| 2 | 复核页码、标准章、自由文本和批注审查链 | 避免重复开发已有能力 |
| 3 | 审计原子写入、版本快照、独占操作和撤销实现 | 找到页码即时恢复断层 |
| 4 | 核对 Adobe、PDF Expert 与 Xodo 的当前官方能力 | 确认范围水印是专业工具的真实需求 |
| 5 | 页码添加改走页面可恢复变更 | 添加后可从工作台一步撤销 |
| 6 | 页码移除改走页面可恢复变更 | 误删页码也可一步恢复 |
| 7 | 为可恢复变更增加不失效分析结果的模式 | 纯批注变化不重复 OCR 和理解分析 |
| 8 | 修正取消恰逢原子提交后的状态刷新语义 | 已提交变化不会被误报为取消 |
| 9 | 定义 Sendable 水印载荷、预设、布局、色调和强度 | UI 与 PDF 写入边界明确 |
| 10 | 提供机密、草稿、内部使用、禁止复制和自定义文字 | 覆盖常见专业分发场景 |
| 11 | 自定义文字限制为单行 1 至 64 个字符 | 防止异常外观和无界输入 |
| 12 | 支持全部、范围、奇数页和偶数页 | 封面跳过与双面材料可直接完成 |
| 13 | 支持对角、居中、页眉和页脚四种布局 | 兼顾显著标记与克制页边标记 |
| 14 | 支持红、石墨、蓝三种语义色和三级强度 | 适配警示、内部审阅与一般分发 |
| 15 | 批量写入限制为 10,000 页并传播取消 | 极端输入有界且长任务可停止 |
| 16 | 按每页 CropBox 独立计算边距、字号和范围 | 混合尺寸与非零原点页面不会共用错误坐标 |
| 17 | 使用 `PaperPath Watermark` 作者标记隔离生成内容 | 不会误删第三方水印、自由文本或页码 |
| 18 | 重复应用只替换所选页的旧生成水印 | 调整样式不会形成重叠标记 |
| 19 | 写入后重开核验文字、角度、透明度及显示/打印状态 | 编码成功不再等同于交付成功 |
| 20 | 实现全局定向移除并保留其他批注和页码 | 可安全回退水印而不破坏审阅内容 |
| 21 | 文档工具面板增加可搜索的 Watermark 直达入口 | 打开 PDF 后可按任务直接进入 |
| 22 | 页面工作台增加 Watermark 命令和一步 Undo 状态 | 批量标记与页面整理处于同一专业路径 |
| 23 | 增加实时纸张预览、范围摘要、Dynamic Type、VoiceOver 和停止操作 | 提交前可判断结果，小屏与辅助字号可用 |
| 24 | 补齐简体中文、生成批注分类、资源检查和双架构编译 | 保持发布前一致性与审计能力 |

## 核心变化

### 专业水印

- 预设：Confidential、Draft、Internal Use、Do Not Copy、自定义。
- 范围：全部、指定范围、奇数页、偶数页。
- 布局：对角、居中、页眉、页脚。
- 外观：红、石墨、蓝与淡化、标准、醒目三级强度。
- 每次最多 10,000 页；界面使用 O(1) 范围计数，只在提交时生成页索引。

### 数据安全

- 水印和页码均通过文档独占操作、版本快照、临时文件原子替换和一步撤销。
- 水印写入后重新打开，核验每个目标页只存在一个生成标记，且文字、角度、透明度、显示和打印状态一致。
- 重新应用只替换目标页上的 PaperPath 水印。
- 全局移除只识别 `PaperPath Watermark` 作者标记，不修改第三方自由文本、页码或其他批注。
- 已完成原子替换后，即使外层任务同时收到取消，也会刷新模型状态，避免磁盘与界面修订不一致。

### 交互与审查

- 文档工具面板提供 Watermark 直接入口，并支持英文与中文任务搜索。
- 页面工作台同时提供页码、水印和一步撤销。
- 水印面板显示真实文字、布局、色调、强度、作用页数和 10,000 页限制。
- 普通字号使用分段控件，大号 Dynamic Type 使用菜单。
- 应用或移除期间禁止交互式关闭，可显式停止后台任务。
- 批注审查新增 Generated 分类，并把页码和水印标为各自类型。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 水印领域模型、生成批注身份和工具发现语义。
- `PaperPath/Services/PDFMutationService.swift`
  - 水印应用、替换、移除、页面几何、取消和重开验证。
- `PaperPath/App/PaperPathModel.swift`
  - 水印事务接入、页码即时撤销和原子提交后的状态刷新。
- `PaperPath/Views/StampPickerView.swift`
  - 水印配置、预览、范围、移除和取消交互；页码范围性能与取消改进。
- `PaperPath/Views/PageOrganizerView.swift`
  - 页面工作台水印入口。
- `PaperPath/Views/DocumentWorkspaceView.swift`
  - 文档工具面板水印直达。
- `PaperPath/Views/AnnotationReviewView.swift`
  - 生成批注筛选与类型识别。
- `PaperPath/Services/PDFDocumentStructureService.swift`
  - 只读批注扫描中的生成身份恢复。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - 水印与恢复流程简体中文。
- `README.md`
  - 更新能力清单。

## 编译结果

本轮实现过程中，以下标准命令两次完成主 App 编译：

```bash
xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

最终复跑时，本机 Xcode 26.3 只提供 iOS Simulator 26.2 SDK，而 CoreSimulator 仅安装 26.5 runtime，标准 Scheme 在目标解析阶段失败，未进入代码编译。使用不编译 Asset Catalog 的目标级降级命令重新验证当前源码：

```bash
xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -target PaperPath \
  -configuration Debug \
  -sdk iphonesimulator \
  build CODE_SIGNING_ALLOWED=NO \
  SUPPORTED_PLATFORMS=iphonesimulator \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets
```

- `PaperPath`：源码编译与链接成功，产物包含 `arm64`、`x86_64`。
- 内嵌 `PaperPathShareExtension`：源码编译与链接成功，产物包含 `arm64`、`x86_64`。
- 独立 `PaperPathShareExtension`：源码编译与链接成功，产物包含 `arm64`、`x86_64`。
- `git diff --check`、两个 plist、strings 语法及重复键检查通过。
- 按项目快速迭代约束未运行单元测试、UI 测试或截图回归。
- 标准双 Scheme 发布门禁仍需安装与 SDK 匹配的 Simulator runtime 后复跑。

## 竞品证据

- Adobe 2026 官方资料将 Header、Footer、Watermark 列为专业 PDF 编辑工具，并支持页面范围、更新和移除：
  - https://helpx.adobe.com/acrobat/desktop/use-acrobat-ai/get-started-with-smart-actions/edit-pdfs-via-chat-overview.html
  - https://helpx.adobe.com/acrobat/using/add-watermarks-pdfs.html
- PDF Expert 官方资料强调 iPhone/iPad 上的标准章、自定义章、移动缩放与扁平化：
  - https://pdfexpert.com/how-to-stamps-to-a-pdf
- Xodo 2026 移动端资料强调小屏下的完整 PDF 工具入口与撤销：
  - https://xodo.com/blog/how-to-use-xodo-pdf-reader-and-editor-mobile-app

PaperPath 本轮新增的差异不是“有水印按钮”，而是本地私有副本、版本快照、一步撤销、专用标记、写后重开核验和后续 Safe Share 扁平化可以组成同一条可信交付链。该优势仍需第三方阅读器和真机样本验证。

## 未验证风险

- PDFKit FreeText 的任意角度与透明度尚未在 Acrobat、Preview、PDF Expert、Xodo 中进行视觉互操作检查。
- 旋转 90/270 度、非零 CropBox 原点和极窄自定义页面尚未做真实样本截图对比。
- 100、500、2,000 页批量水印的时间、峰值内存、能耗和取消尾延迟尚未真机测量。
- Safe Share 扁平化后的水印字体、透明度和打印效果尚未做多阅读器对比。
- 本轮未运行自动化测试；标准双 Scheme 最终复跑被本机 Simulator runtime 错配阻断。

## 下一阶段

1. 修复 Xcode SDK 与 Simulator runtime 配对后，复跑标准主 App 与 Share Extension Scheme。
2. 用旋转页、混合尺寸、非零 CropBox 和复杂批注样本验证水印互操作。
3. 在真机测量大批量水印、页码、移除和取消。
4. 验证水印经过 Safe Share 扁平化后的显示、打印和 Delivery Receipt。
5. 根据真实法律与企业用户任务决定是否增加 Bates 前后缀和批量多文件水印。
