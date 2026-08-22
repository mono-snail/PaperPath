# PaperPath V59：跨文档连续 Bates 与可恢复批次事务

## 本轮目标

V58 已完成单文档 Bates 编号，但合同附件、证据材料、医疗记录和审批卷宗仍需人工计算每份 PDF 的起始号。本轮补齐跨文档连续 Bates：用户可选择并排序多份私有工作副本，预览每份编号范围，再通过一次批次事务统一提交。

本轮同时修复 V58 中误放到普通页码流程的 Bates 冲突检查。所有结果只基于当前源码、构建和官方公开资料，不把“全球领先”当作未经同机任务验证的事实。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 将 Bates 冲突检查从普通页码流程移回 Bates 写入 | 普通页码不再被无关 Bates 内容阻断 |
| 2 | 定义跨文档 Bates 批次计划和逐文档条目 | 预览与执行共享同一数据契约 |
| 3 | 限制单批最多 64 份 PDF、10,000 页 | 大批任务保持有界 |
| 4 | 使用有序文档 ID 保存用户编排 | 编号顺序明确且可重复 |
| 5 | 为每份 PDF 计算连续起止号 | 无需人工推算下一文件起始号 |
| 6 | 使用 `Int64` 校验整批末号和数字宽度 | 序列不会溢出或静默扩位 |
| 7 | 将前后缀规范化提升为共享领域校验 | 单文档与跨文档规则一致 |
| 8 | 每份结果先在受保护临时副本写入 | 工作副本在准备阶段保持不变 |
| 9 | 提交前一次获取全部文档独占租约 | 其他长任务不能并发改写同一批文件 |
| 10 | 在模型层与存储层双重核对源修订 | 过期计划不会覆盖较新内容 |
| 11 | 按暂存、回滚、最大原子写和保留空间计算预算 | 空间不足时在发布前失败关闭 |
| 12 | 暂存、回滚、事务日志和撤销副本均应用完整文件保护 | 锁屏后的敏感副本边界一致 |
| 13 | 将全部 PDF 与 `library.json` 作为同一发布集合 | 文件内容和模型修订同步切换 |
| 14 | 任一写入或核验失败时逆序恢复全部旧文件 | 不留下部分文档已编号的混合状态 |
| 15 | 发布后复核指纹、页数和索引修订 | 已写入不等于未经验证 |
| 16 | 每份工作副本写入前创建版本快照 | 可从版本历史追溯批次前状态 |
| 17 | 全批次共用一个 Undo 动作 | 一次恢复全部受影响 PDF |
| 18 | 发布前传播取消，发布开始后只允许完成或回滚 | 停止操作不会制造半提交 |
| 19 | 提供快照、准备、发布三阶段进度 | 用户知道当前文件与整体进展 |
| 20 | 新增可搜索的合格 PDF 多选工作台 | 锁定、空页和忙碌文档不会进入批次 |
| 21 | 为已选文档提供上移、下移和顺序号 | 法律材料的编号顺序可直接控制 |
| 22 | 展示整批首末号及每份 PDF 的编号范围 | 提交前即可复核边界 |
| 23 | 接入首页命令、添加菜单和 Library 多选批处理 | 从发现、选择到执行路径完整 |
| 24 | 补齐简体中文、README、工程引用和双架构构建 | 保持发布构建与资源一致性 |

## 核心变化

### 跨文档连续编号

- 多份 PDF 共用一个固定宽度序列。
- 支持 3 至 15 位数字、起始号、前缀、后缀和六个页眉/页脚位置。
- 用户可以搜索来源、选择文件、上移或下移，并逐份查看起止编号。
- 批次只接受未锁定、至少一页的私有工作副本。

### 多文件事务

- 所有 PDF 先在临时副本中完成 Bates 写入和重开核验。
- 提交前再次校验每份源修订，拒绝覆盖已变化内容。
- 空间预算包含暂存副本、原文件回滚副本、最大原子写和安全余量。
- PDF 与 `library.json` 一起发布；失败时逆序恢复。
- 发布前写入受保护事务日志；App 下次启动会优先恢复中断批次。
- 恢复日志记录旧文件指纹，恢复流程可重复执行并验证结果。

### 交互与恢复

- Home 命令中心与添加菜单提供 Bates 批处理入口。
- Library 多选底栏将标签、Bates 和 Office 收纳到 Batch 菜单，避免小屏按钮拥挤。
- 运行期间冻结参数与文档顺序，显示当前阶段、文件名和总进度。
- 停止只在统一发布前生效；发布阶段完成或回滚。
- 成功后一个 Undo 同时恢复整批工作副本。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 批次计划、逐文档编号范围、进度模型和批量撤销动作。
- `PaperPath/Services/PDFMutationService.swift`
  - 共享 Bates 输入校验并修正冲突检查位置。
- `PaperPath/Services/DocumentStore.swift`
  - 多工作副本事务、磁盘预算、原子发布、回滚日志与启动恢复。
- `PaperPath/App/PaperPathModel.swift`
  - 批次租约、快照、临时准备、进度、提交和一键恢复。
- `PaperPath/Views/BatchBatesNumberingView.swift`
  - 多选、排序、范围预览、参数配置、进度和停止交互。
- `PaperPath/Views/LibraryView.swift`
  - Home、添加菜单和多选批处理入口。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - V59 简体中文文案。
- `PaperPath.xcodeproj/project.pbxproj`
  - 新增批次工作台编译引用。
- `README.md`
  - 更新跨文档 Bates 能力清单。

## 编译结果

标准 Scheme 命令仍被本机环境阻断：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

Xcode 26.3 当前提供 iOS Simulator 26.2 SDK，但 CoreSimulator 只安装 26.5 runtime，目标解析报告 `Unable to find a destination`。

源码使用目标级降级命令验证：

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

- 主 App、内嵌 Share Extension 和独立 Share Extension：源码编译与链接成功。
- 产物架构：`arm64`、`x86_64`。
- `git diff --check`、工程文件、plist、strings 语法和重复键检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞品证据

- Adobe Acrobat Pro 官方帮助（2025-11-05 更新）支持添加多份文件、调整文件顺序、3 至 15 位数字、起始号、前后缀和输出目录：
  - https://helpx.adobe.com/africa/acrobat/desktop/edit-documents/apply-bates-numbering/add-bates.html
- PDF Expert 官方公开流程支持 Bates 前后缀、数字宽度、外观和位置，但页面明确描述 Mac 版：
  - https://pdfexpert.com/how-to-add-page-numbers-pdf
- Xodo 2025 官方资料支持桌面端批量 Header/Footer 与 Bates 参数：
  - https://xodo.com/blog/how-to-add-page-numbers-to-pdf

PaperPath 当前可证明的差异，是在 iPhone/iPad 原生私有工作区中把跨文档连续编号与源修订校验、磁盘预算、批量原子提交、跨启动回滚、版本快照和整批 Undo 组合为一条本地链路。公开资料与本轮构建不能证明整体产品已全面领先上述竞品。

## 未验证风险

- 尚未用真实法律卷宗验证第三方阅读器中的字体、打印、旋转页和非零 CropBox 外观。
- 64 份或 10,000 页上限下的耗时、峰值内存、能耗和停止尾延迟尚未真机量化。
- 跨启动回滚已做静态审查和编译验证，尚未通过强制杀进程故障注入。
- 当前批次作用于私有工作副本，不生成独立输出包，也不支持文件夹导入。
- 本轮未运行自动化测试；标准双 Scheme 门禁仍需匹配 Simulator runtime。

## 下一阶段

1. 在真机执行提交阶段强制退出、磁盘耗尽和文件保护故障注入。
2. 使用真实多卷证据材料验证顺序、打印、第三方阅读器和 Safe Share 扁平化。
3. 将批次编号范围写入 Delivery Receipt 或独立批次清单，形成可交付索引。
4. 根据真实任务数据评估批量移除 Bates、文件夹导入和输出副本模式。
