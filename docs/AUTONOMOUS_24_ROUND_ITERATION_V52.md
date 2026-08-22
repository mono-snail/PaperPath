# PaperPath V52：资料库热路径、启动 I/O 与异步任务稳定性

## 本轮目标

V51 已收敛工作副本、交付产物、Office 队列和页面任务连续性。本轮以性能和稳定性为主，优先处理有代码证据的启动重复 I/O、SwiftUI 高频全量扫描、无界搜索、取消不传播和陈旧异步结果写回。

本轮不使用缺少实测依据的“全面超越竞品”结论。已确认的是复杂度、线程占用和状态提交边界得到改善；启动耗时、能耗、内存峰值和竞品差异仍需真机基准验证。

## 24 轮闭环

| 轮次 | 证据 | 实际落地 | 用户价值 |
|---|---|---|---|
| 1 | 提示词名义基线为 V46，工程已完成 V51 | 以最新代码、V51 报告和当前脏工作区为基线 | 避免重复开发和覆盖既有成果 |
| 2 | 工作区存在大量未提交修改 | 仅增量修改性能与稳定性相关文件 | 降低无关回归风险 |
| 3 | 启动分别调用 `load`、`loadDeleted` 和三类 sidecar loader | 新增聚合 `DocumentStoreBootstrapSnapshot` | 启动状态从同一份存储快照产生 |
| 4 | library index 在启动阶段被重复解码 | 快照只读取并清理 index 一次 | 预期减少启动磁盘 I/O，尚未真机计时 |
| 5 | 旧 `load` API 一度误走完整 sidecar 快照 | 恢复为仅加载轻量文档索引 | 避免普通刷新触发全量 sidecar 读取 |
| 6 | sidecar 装载取消时会静默返回部分结果 | 改为抛出 `CancellationError` | 不再把不完整缓存当成完整启动状态 |
| 7 | `record(id:)` 在模型内高频线性查找 | 建立 `documentRecordsByID` | 文档 ID 查询由 O(n) 降为预期 O(1) |
| 8 | 工作副本和交付产物每次访问都重新过滤 | 缓存两个角色集合并统一重建 | 降低 SwiftUI 重算期间的重复过滤 |
| 9 | 每次查询 Verified Output 都重建字典并扫描全部文档 | 预计算有效来源链索引并保留循环保护 | 多级来源查询不再重复全库遍历 |
| 10 | 分享目标在命令摘要中按每份文档重复求解 | 预计算当前分享目标索引 | 首页摘要避免 O(n²) 级产物查找 |
| 11 | 当前批次恢复再次创建文档字典 | 复用统一 ID 索引 | 批次状态计算减少重复分配 |
| 12 | Duplicates 智能视图对每份文档再次过滤全库 | 建立工作副本 fingerprint 计数索引 | 重复识别从 O(n²) 降为 O(n) 预计算 |
| 13 | Smart Views 先判断可见、渲染时又逐项计数 | 一次遍历生成可见视图及计数摘要 | 首页重算减少重复集合遍历 |
| 14 | 页面搜索页数和文档数分别扫描同一全文索引 | 一次匹配同时累计两个统计值，并用首命中短路入口判断 | 搜索摘要减少重复文本扫描 |
| 15 | 文档内查找会返回全部命中页 | 结果上限设为 200，并明确显示截断状态 | 超长 PDF 不再创建无界结果数组 |
| 16 | `.task` 取消不会自动停止 detached 搜索 | cancellation handler 显式取消 worker，逐页检查取消 | 快速输入和退出搜索后更快释放 CPU |
| 17 | 旧查询可能晚于新查询完成 | 发布前校验规范化 query 快照 | 旧结果不能覆盖当前搜索 |
| 18 | 延迟启动分析任务未被模型持有 | 保存并在重启 bootstrap、清除数据和析构时取消任务 | 避免重复后台分析和生命周期泄漏 |
| 19 | 文档理解仍可能在主 actor 执行 | OCR 索引、原生文字提取和理解分析统一移入 worker | 预期减少长文档分析造成的界面阻塞 |
| 20 | 分析完成后可能覆盖较新的文档状态 | 模型和存储 actor 双重校验 revision；存储基于最新记录合并 brief | 陈旧分析不再回写，元数据更新不被旧快照覆盖 |
| 21 | 版本比较和双 PDF 比较缺少完整父任务取消 | 显式传播取消，缓存前复核参与文档 revision | 退出比较或文档变化后不提交陈旧证据 |
| 22 | 链接、图片对象、批注、技术检查、附件、页标签和表单读取仍有裸 `.value` | 统一接入取消桥接和 revision guard | 读取型工具在页面退出或源变化后安全停止 |
| 23 | 收件箱目录扫描位于主 actor，部分 PDFKit 循环缺少取消点 | 收件箱扫描移至 utility worker；批注、页标签、技术检查和文本理解补取消检查 | 降低导入卡顿并缩短大文档取消尾延迟 |
| 24 | 新搜索状态需本地化并验证双目标 | 补齐简体中文，完成主 App 与 Share Extension 独立双架构编译 | 保持交付资源与构建门槛完整 |

## 核心变化

### 启动与资料库热路径

- 启动只解码一次 library index，并在同一 actor 快照中加载 URL、文本索引、OCR 和交付预检缓存。
- 文档 ID、工作副本、交付产物、Verified Output 来源链、当前分享目标和重复指纹均由文档集合统一派生。
- 批次恢复和首页命令摘要复用索引，不再各自重建全量映射。

### 搜索与 SwiftUI 重算

- Duplicates 不再执行嵌套全库过滤。
- Smart Views 在一次文档遍历中生成计数摘要。
- 资料库页面命中数与文档命中数合并计算。
- 文档内查找最多发布 200 个页面结果，支持 debounce、取消传播和旧查询拦截。

### 后台任务与一致性

- 延迟启动分析拥有明确生命周期，可在重复启动、清除数据和模型释放时取消。
- 文档理解完全离开主 actor；原生文字提取与实体分析增加协作式取消。
- `saveAnalysis` 在存储 actor 内校验内容修订，并在最新记录上合并分析字段。
- 版本比较、双 PDF 比较和高频只读 PDF worker 在返回前复核修订。
- 模板、扫描、合并、外部页面准备、表单检查、文件导出和撤销快照统一传播父任务取消。
- Share Extension 收件箱枚举移出主 actor，并在目录和文件循环中响应取消。

### 缓存与临时文件

- 比较、页面评估和交付预检内存缓存继续在系统内存警告时释放。
- 缩略图缓存保持按字节/条目 LRU，编辑器预览保持独立 LRU，并共同响应内存警告。
- 搜索结果有界；导出、页面源、附件和撤销临时文件继续在失败或取消路径清理。
- 派生文档索引只保存值类型视图，不持有额外 PDFKit 对象。

## 修改文件

- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Services/DocumentStore.swift`
- `PaperPath/Services/DocumentUnderstandingService.swift`
- `PaperPath/Services/ExternalPDFInbox.swift`
- `PaperPath/Services/PDFMutationService.swift`
- `PaperPath/Services/PDFDocumentStructureService.swift`
- `PaperPath/Views/LibraryView.swift`
- `PaperPath/Views/DocumentFindView.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `docs/AUTONOMOUS_24_ROUND_ITERATION_V52.md`

## 编译与静态校验

执行：

```bash
xcodebuild -quiet -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PaperPath-V52-App-DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -quiet -project PaperPath.xcodeproj -scheme PaperPathShareExtension -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PaperPath-V52-Share-DerivedData build CODE_SIGNING_ALLOWED=NO
git diff --check
plutil -lint PaperPath/Resources/zh-Hans.lproj/Localizable.strings PaperPath/Info.plist PaperPathShareExtension/Info.plist
```

结果：

- `PaperPath` scheme：**BUILD SUCCEEDED**。
- `PaperPathShareExtension` scheme：**BUILD SUCCEEDED**。
- 两个 scheme 均生成 arm64 + x86_64 Simulator 产物。
- Share Extension 嵌入与二进制验证成功。
- strings、plist、重复本地化键和 diff whitespace 检查通过。
- 按任务约束未运行单元测试、UI 测试、截图回归或发布门禁。

## 可验证的竞争优势

- 本地、无账号的启动索引和文档理解链不依赖网络，保持隐私定位。
- Verified Output 的多级来源关系已从临时全库推导变为一致性索引，兼顾复杂资料库响应与可追溯性。
- 长任务普遍具备取消传播和 revision guard，降低离开页面后继续耗能或回写陈旧结果的风险。
- 搜索、缓存和 sidecar 加载均有明确上限或取消边界，更适合大页数 PDF 与大资料库。

以上为代码与构建证据，不等同于已完成竞品性能领先验证。

## 未验证风险

- 尚未在 500 至 1,000 份文档资料库上测量冷启动、首页重算和搜索延迟。
- 尚未真机测量长 PDF 分析、OCR、对比过程的取消尾延迟、峰值内存与能耗。
- PDFKit 在不同供应商超大或损坏 PDF 上的取消粒度仍受系统框架单次调用时长影响。
- 本轮未运行自动化测试；索引契约、并发 revision guard 和取消清理仍应补充定向单元测试。

## 下一阶段

1. 建立冷启动、500/1,000 文档资料库、2,000 页搜索和 500 MB PDF 对比基准。
2. 在真机覆盖后台切换、锁屏、低内存、低磁盘和连续取消。
3. 为派生索引与原扫描实现建立等价性契约测试。
4. 基于同机同样本实测对比 PDF Expert、Acrobat 和 PDFgear，再判断是否达到具体领先目标。
