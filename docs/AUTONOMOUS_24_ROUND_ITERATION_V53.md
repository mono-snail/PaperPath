# PaperPath V53：有界内存、存储事务与异常 PDF 防护

## 本轮目标

V52 已收敛启动 I/O、资料库索引和异步任务生命周期。本轮继续以性能与稳定性为主，处理大资料库全文语料常驻、存储统计重复遍历、保护写事务空间不足、Core Image 缓存释放、异常表单资源消耗和交付审计取消尾延迟。

本轮没有进行真机性能基准或同机竞品测试，因此只陈述代码可证明的复杂度、资源上限和一致性变化，不宣称已经实测全面超过竞品。

## 24 轮闭环

| 轮次 | 证据 | 实际落地 | 用户价值 |
|---|---|---|---|
| 1 | 工程已完成 V52，且工作区包含大量未提交改动 | 以 V52 报告、当前代码和 Git 状态为实际基线，仅增量修改相关文件 | 避免覆盖既有功能和用户改动 |
| 2 | 资料库启动会为每份文档拼接并小写化完整正文 | 将轻量元数据语料与全文语料拆分 | 启动不再永久复制全部索引正文 |
| 3 | 全文语料缓存原先随资料库规模无界增长 | 增加 12 MB UTF-8 成本预算 | 常驻搜索副本拥有明确上限 |
| 4 | 超预算后若持续逐份淘汰会造成搜索抖动 | 超预算文档标记为逐页匹配，不参与缓存争抢 | 大资料库搜索避免反复构建同一巨大字符串 |
| 5 | 文档更新后全文缓存可能保留旧索引 | `replace`、删除和重建路径统一失效对应缓存 | 搜索结果不读取陈旧正文 |
| 6 | 内存警告只释放比较与预检证据 | 同时释放全文语料缓存 | 系统内存紧张时更快降低常驻占用 |
| 7 | 容量面板分别递归扫描七个目录 | 改为一次根目录枚举并按一级目录累计 | 减少重复枚举和文件系统调用 |
| 8 | 大目录统计无法响应页面退出 | 每 64 个项目检查任务取消 | 离开容量页面后停止无用扫描 |
| 9 | 容量统计取消会被当作普通错误展示 | 模型单独吞掉 `CancellationError` | 正常离开页面不会出现错误提示 |
| 10 | 多文件保护事务未预估暂存文件空间 | 计算全部暂存数据成本 | 低磁盘状态在写入前失败关闭 |
| 11 | 原子写入期间还会产生单文件峰值 | 预算最大原子写临时副本 | 降低写到一半才耗尽空间的概率 |
| 12 | 回滚副本也占用磁盘但此前未计入 | 将现有目标文件大小纳入回滚预算 | 事务保留足够恢复空间 |
| 13 | 事务取消可能发生在多份暂存文件之间 | 暂存和备份循环增加取消检查 | 取消后尽早清理未发布数据 |
| 14 | 发布阶段若响应取消可能留下部分新状态 | 最后一次取消检查放在发布前，发布后完整提交或回滚 | sidecar 与资料库索引保持原子一致 |
| 15 | OCR 增强重试每页创建新的 `CIContext` | 复用共享 Core Image context | 预期减少长文档 OCR 的上下文创建开销 |
| 16 | OCR 候选转换期间缺少取消点 | 每 64 个识别候选检查取消，并在排序前后复核 | 密集页面退出后更快停止后处理 |
| 17 | OCR 和扫描 Core Image context 未接入内存警告 | 两类服务提供缓存释放并由模型统一调用 | 内存压力下主动清理图像管线缓存 |
| 18 | 扫描增强在 Vision 和页面处理边界取消不够及时 | 处理前后及矩形检测前后检查取消 | 取消扫描后减少继续耗能 |
| 19 | 表单自动化使用 `1...numberOfPages`，零页 PDF 可触发非法闭区间 | 零页文档直接返回空自动化结果 | 损坏或异常 PDF 不再触发该崩溃路径 |
| 20 | 表单批注和脚本数量没有总量上限 | 限制 50,000 个批注、10,000 个字段和 20,000 个脚本字段 | 恶意或异常表单不能无界消耗内存 |
| 21 | 表单自动化解析为非抛出流程 | 改为 throwing 流程，在页面、批注、字段和递归计算中传播取消 | 大表单检查可协作式停止，不返回半份结果 |
| 22 | 插入空白页按源页尺寸创建整页位图 | 改为直接创建矢量 `PDFPage` 并设置页面边界 | 避免超大页面触发巨量像素分配 |
| 23 | 全量追加页面、OCR 隐藏文字和页面配对仍有长循环取消缺口 | 为相关循环增加分段取消检查 | 长任务退出后的尾延迟进一步收敛 |
| 24 | 交付审计每页重复读取 `page.string` | 单次提取后复用于指纹和文字片段，完成资源校验与双 Scheme 编译 | 减少 PDFKit 重复解析并保持交付门槛 |

## 核心变化

### 大资料库搜索

- 启动仅预计算文件名、标签、分类、摘要和实体等轻量语料。
- 完整正文仅在查询需要时构建，缓存总成本限制为 12 MB。
- 超预算或超大文本索引使用逐页短路匹配，避免缓存反复淘汰。
- 文档内容或分析变化时清除对应全文缓存；内存警告清空全部全文语料。

### 存储与事务

- 本地容量统计从七次目录遍历合并为一次根目录遍历。
- 目录扫描支持取消，页面退出不再显示取消错误。
- 多文件保护事务在落盘前预算暂存、原子写峰值、回滚副本和 8 MB 安全余量。
- 事务只在发布前响应取消；发布开始后必须完成全部替换或执行回滚。

### OCR、扫描与页面处理

- OCR 增强复用 `CIContext`，不再按重试页面重复创建。
- OCR 候选、扫描增强、Vision 矩形检测和隐藏文字写入增加取消检查。
- OCR 与扫描图像缓存接入系统内存警告。
- 插入空白页使用矢量 PDF 页面，避免按异常页面尺寸分配位图。
- 全量追加页面增加逐页取消检查。

### 表单与交付审计

- 表单检查为批注、字段和脚本字段设置明确资源上限。
- 自动化解析覆盖零页 PDF、页面循环、批注循环、字段循环及递归计算取消。
- 交付审计每页只读取一次 PDFKit 正文。
- 页面配对动态规划、锚点分段和回溯过程响应取消。

## 修改文件

- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Services/DocumentStore.swift`
- `PaperPath/Services/VisionOCRService.swift`
- `PaperPath/Services/ScanPDFRenderer.swift`
- `PaperPath/Services/PDFFormInspectionService.swift`
- `PaperPath/Services/PDFFormAutomationService.swift`
- `PaperPath/Services/PDFMutationService.swift`
- `PaperPath/Services/PDFCompositionService.swift`
- `PaperPath/Services/PDFDeliveryAuditService.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `docs/AUTONOMOUS_24_ROUND_ITERATION_V53.md`

## 编译结果

执行：

```bash
xcodebuild -quiet -project PaperPath.xcodeproj -scheme PaperPath -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PaperPath-V53-App-DerivedData build CODE_SIGNING_ALLOWED=NO
xcodebuild -quiet -project PaperPath.xcodeproj -scheme PaperPathShareExtension -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/PaperPath-V53-Share-DerivedData build CODE_SIGNING_ALLOWED=NO
git diff --check
plutil -lint PaperPath/Info.plist PaperPathShareExtension/Info.plist PaperPath/Resources/zh-Hans.lproj/Localizable.strings
```

结果：

- `PaperPath` scheme：**BUILD SUCCEEDED**。
- `PaperPathShareExtension` scheme：**BUILD SUCCEEDED**。
- 主 App、独立 Share Extension 及 App 内嵌扩展均包含 arm64 与 x86_64 Simulator 架构。
- strings、plist 和 diff whitespace 检查通过。
- 按任务约束未运行单元测试、UI 测试、截图回归或发布门禁。

## 竞争优势

- 大资料库搜索、OCR 和扫描拥有明确内存释放路径，不依赖服务端处理。
- 多文件分析状态提交会在磁盘不足时提前失败，并保持整组发布或回滚。
- 异常表单拥有资源上限和取消边界，降低第三方复杂 PDF 拖垮进程的风险。
- 交付审计继续保持逐页证据，同时减少重复 PDFKit 文本提取并允许中止页面配对。

以上优势均来自当前代码和构建证据，不等同于已完成竞品性能领先验证。

## 未验证风险

- 尚未在真机测量 500/1,000 份文档搜索的峰值内存、输入延迟和缓存命中率。
- 尚未通过低磁盘故障注入验证多文件事务的所有 APFS 行为。
- `PDFPage()` 生成的矢量空白页已通过编译，但尚未在多种阅读器中做视觉互操作验证。
- 表单资源上限尚未用真实超大 AcroForm 样本验证错误呈现。
- 本轮未运行自动化测试，取消、容量预算和缓存一致性仍需专项门禁。

## 下一阶段

1. 建立 500/1,000 份文档和 2,000 页 PDF 的真机搜索、内存与能耗基准。
2. 使用低磁盘、锁屏、后台切换和强制退出故障注入验证事务恢复。
3. 使用异常 AcroForm、损坏 xref 和超大页面尺寸样本验证资源上限。
4. 在同一设备、同一 PDF 样本上对比 PDF Expert、Adobe Acrobat 和 PDFgear，再形成可量化竞争结论。
