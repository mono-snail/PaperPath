# PaperPath V67：交互连续性与有界性能

## 本轮目标

本轮对照 PDF Expert、Adobe Acrobat 和 Xodo 的移动端公开路径，集中优化高频
使用体验、长文档搜索成本、批量任务可控性和 Outputs 状态表达。

PaperPath 不以功能总量或云服务广度宣称全面领先。可防守的目标是：在设备本地
完成 PDF、形成可信输出并恢复中断任务时，比同类产品提供更短、更明确且有证据
的闭环。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V54-V66 和当前脏工作区 | 避免覆盖既有成果或重复开发 |
| 2 | 核对三款竞品的移动端公开能力 | 只处理真实差距，不凭印象堆功能 |
| 3 | 重审 Home / Tasks / Outputs 信息架构 | 工作副本、工具和交付产物边界更明确 |
| 4 | 重审工作区主操作和阅读导航 | 高频动作保持在当前 PDF 上下文 |
| 5 | 重审工具搜索、收藏和最近工具 | 降低重复寻找工具的成本 |
| 6 | 复核 Library 搜索历史与筛选恢复 | 搜索状态不会因切换工作区被无意混用 |
| 7 | 复核最近文档与跨文档跳转 | 不引入多标签复杂度也能快速切换 |
| 8 | 为全库页搜索建立请求快照 | SwiftUI 重绘不再同步反复扫描全文 |
| 9 | 将全库页搜索移到可取消后台任务 | 输入变化会取消过期搜索 |
| 10 | 限制全库 500、单文档 200 个匹配页 | 极端语料不会无限增长结果状态 |
| 11 | 显式展示搜索中与结果截断状态 | 用户不会把有界结果误认为完整结果 |
| 12 | 搜索详情复用快照 | 打开结果页不再二次扫描全部索引 |
| 13 | 页内搜索只保留 220 字符摘录 | 长文档结果状态不再保存整页正文 |
| 14 | 增加上一项、下一项和当前位置 | Find Sheet 内可连续审阅命中页 |
| 15 | 搜索预览保持 Sheet 打开 | 跳页后无需反复重新进入搜索 |
| 16 | 辅助字号下工作区切换改为 Menu | Home / Tasks / Outputs 不再挤压 |
| 17 | 辅助字号下搜索范围和工具视图改为 Menu | 大字体仍保留完整选择语义 |
| 18 | 工作区底部主操作支持横向滚动 | Find、Markup、Pages、Verify 和 More 不重叠 |
| 19 | 增加页码、书签键盘快捷键 | iPad 键盘阅读路径更高效 |
| 20 | 首页主推荐从全量排序改为单次选择 | 最高优先级文档选择由 O(n log n) 降为 O(n) |
| 21 | 命令摘要改为单次遍历 | 减少首页多轮 filter/map/reduce |
| 22 | Outputs 四阶段集合一次构造 | Source、Producing、Review、Verified 同帧一致 |
| 23 | 批量验证增加 64 份硬门禁和安全停止 | 峰值可控，已验证结果可保留和恢复 |
| 24 | 自动缩略图策略感知低电量与热状态 | 资源受限时主动降低缓存与渲染压力 |

## 核心变化

### 搜索与阅读连续性

- 全库页搜索以查询、文档 ID 和索引时间戳组成请求标识，旧请求结果不会覆盖
  新查询。
- 搜索任务支持取消传播；结果上限为全库 500 页、单文档 200 页。
- 搜索摘要和详情均显示是否截断，避免把“前 500 项”表述为全部结果。
- 页内搜索保存有界摘录而不是完整页正文，并可在半高 Sheet 中连续预览。
- `Command + [`、`Command + ]`、`Command + J` 和 `Command + B` 分别对应
  上一页、下一页、跳页和书签。

### 大字体与操作可达性

- Home / Tasks / Outputs、搜索范围、工具视图和批量结果筛选在辅助字号下使用
  Menu，不强行压缩 segmented control。
- 工作区主工具栏在辅助字号下横向滚动，并保持稳定最小宽度。
- 收藏按钮、最近文档和搜索导航保持至少 42-44pt 的操作区域。
- Reduce Motion 路径继续关闭非必要的 snappy 动画。

### 批量与 Outputs

- 单批 Verified Output 最多 64 份 PDF；UI 与模型层均执行门禁。
- 旧版本遗留的大批次按每次最多 64 份分段重试，不会被新门禁整体拒绝。
- 处理中禁止下拉关闭，关闭按钮先解释停止后果；已验证产物继续可用，未完成项
  写为可恢复状态。
- Outputs 标签只统计 Producing、Review 和 Verified，不把全部 Source 工作副本
  误算为交付产物。
- Verified 卡片就近提供 Receipt 和分享入口，四阶段看板在单次刷新中使用同一
  集合快照。

### 性能与资源策略

- 首页最高优先级选择使用 O(n) `max`，命令摘要用单次遍历累计。
- 全库搜索、页内搜索和 Outputs 看板均使用有界或一次性派生数据。
- 自动缩略图质量同时考虑物理内存、Low Power Mode 和 Thermal State。
- 资源受限时自动配置降为 1x 渲染、24 个缓存条目、5 MB 图像缓存和 1 个
  `PDFDocument`；用户显式选择 Detailed 时不擅自降级。
- 长任务状态移到 PDF 右上角，复用实际阶段、百分比、字节、吞吐和停滞信息，
  不再遮挡页面中央。

## 修改文件

- `PaperPath/Views/LibraryView.swift`
- `PaperPath/Views/DocumentFindView.swift`
- `PaperPath/Views/DocumentWorkspaceView.swift`
- `PaperPath/Views/DocumentToolPalette.swift`
- `PaperPath/Views/DocumentOutputSheets.swift`
- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/App/AppExperience.swift`
- `PaperPath/Views/PDFKitViews.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`

## 竞品结论

- PDF Expert 的公开能力继续体现 Apple 平台阅读、批注、编辑和工具成熟度。
- Adobe Acrobat 的优势继续集中在完整套件、账号云服务、企业流程和 AI。
- Xodo 的优势继续集中在跨端与工具覆盖。
- 三者公开页面不提供可与 PaperPath 同口径比较的启动耗时、内存、能耗或
  取消恢复数据，因此本轮不编造竞品性能分。
- PaperPath 本轮形成的优势是：私有索引搜索有界、结果可连续预览、批量输出
  可停止恢复、每份结果可追溯、资源策略适配设备状态。这些优势只适用于
  “本地完成并可信交付”路径。

参考：

- [PDF Expert for iPhone and iPad](https://pdfexpert.com/ios/features)
- [Adobe Acrobat mobile FAQ](https://helpx.adobe.com/acrobat/mobile/get-started/faqs.html)
- [Xodo mobile apps](https://xodo.com/mobile-apps)

## 工程验证

标准 Scheme 仍因本机缺少可用的 iOS 26.2 Simulator runtime 而无法解析
`generic/platform=iOS Simulator`，未进入源码编译。

目标级降级门禁：

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

- `PaperPath`：通过。
- `PaperPathShareExtension`：通过。
- 两个 Mach-O 产物均包含 `arm64` 和 `x86_64`。
- `Localizable.strings`、两个 Info plist 和重复键检查通过。
- `git diff --check` 通过。
- 按本轮约束未运行单元测试、UI 测试或截图回归。

## 未验证风险

- 搜索耗时、峰值内存、缩略图热降级和能耗收益仍需真机量化。
- 500 页全库结果和 200 页单文档结果需要真实超长合同语料验证排序手感。
- 最大 Dynamic Type、横屏、多窗口和 VoiceOver 连续预览尚未截图及人工走查。
- 64 份批量任务的停止、杀进程、重启和分段恢复尚未做端到端故障注入。
- 标准 Scheme 需安装匹配的 Simulator runtime 后复跑。

## 下一阶段

1. 在真机建立搜索、首屏、缩略图和 64 份批量任务的时间、内存、能耗基线。
2. 用最大 Dynamic Type、VoiceOver、横屏和多窗口完成高频路径人工验收。
3. 为批量停止与跨启动恢复增加故障注入测试。
4. 继续补齐 Receipt 与版本里程碑双向导航，不扩大不可靠功能边界。
