# PaperPath V58：可验证 Bates 连续编号

## 本轮目标

V57 完成有界批注治理后，重新核对提示词候选方向发现：Delivery Receipt 与版本里程碑双向导航、固定里程碑容量预警/批量治理/导出归档、扫描替换复核均已在当前代码实现。继续修改这些能力会重复开发。

V58 选择当前仍缺失、且与合同附件、证据材料、医疗记录和大型审批文档直接相关的 Bates 连续编号。目标是在 iPhone/iPad 上提供固定数字宽度、前后缀、页范围、位置、重开核验、定向移除和一步恢复；不把编号宣传为法律认证，也不在本轮冒险扩展到跨文档多文件事务。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 保护 V57 未暂存改动和既有暂存基线 | 不覆盖前序功能与用户修改 |
| 2 | 复核 Receipt、里程碑、容量中心与扫描替换代码 | 避免重复开发已闭环能力 |
| 3 | 审计普通页码、水印、生成批注和撤销链 | 复用成熟原子写入边界 |
| 4 | 核对 Acrobat、PDF Expert、Xodo 的 Bates 参数 | 采用行业可识别的字段语义 |
| 5 | 定义独立 `PDFBatesNumberingPayload` | UI 与写入服务之间拥有明确契约 |
| 6 | 支持 3 至 15 位固定数字宽度 | 可生成 `000001` 等稳定页面 ID |
| 7 | 使用 `Int64` 检查起始号、末号和数字宽度 | 序列不会溢出或静默扩位 |
| 8 | 前缀、后缀分别限制 24 字符，拒绝 `#` 和换行 | 避免不兼容或无法放置的编号 |
| 9 | 复用全部、范围、奇数页、偶数页作用域 | 封面与双面材料可以跳过 |
| 10 | 复用左中右、页眉页脚六种位置 | 编号可避开签名和正文区域 |
| 11 | 新增 `PaperPath Bates Numbers` 作者标记 | 普通页码、水印和 Bates 可独立识别 |
| 12 | 重复应用只替换所选页旧 Bates 编号 | 调整序列不会叠加重复外观 |
| 13 | 未选页、普通页码、水印和第三方批注保持不变 | 修改边界可解释且可审计 |
| 14 | 每页按 CropBox 独立计算范围与字号 | 混合尺寸和非零原点页面不共用坐标 |
| 15 | 单次限制 10,000 页并在循环中传播取消 | 极端文档任务保持有界 |
| 16 | 写入后重开核验文本、数量、显示和打印状态 | 编码成功不等同于交付成功 |
| 17 | 实现仅移除 PaperPath Bates 编号 | 清理编号不会误删其他标记 |
| 18 | 接入文档独占、版本快照、原子替换和一步撤销 | 错误操作可恢复且不破坏源文件 |
| 19 | 文档工具面板增加 Bates Numbering 直达入口 | 打开 PDF 后可按任务进入 |
| 20 | 页面工作台增加 Bates 命令 | 页面整理与页面标识位于同一工作区 |
| 21 | 实时预览首号、末号、页数和纸张位置 | 提交前可确认整个编号范围 |
| 22 | 覆盖空输入、位数不足、过长、处理中、停止和移除确认 | 正常与失败状态完整 |
| 23 | 补齐中英文搜索、简体中文、VoiceOver 和 Dynamic Type | 小屏与辅助功能路径可用 |
| 24 | 增加未选页编号冲突检测并完成静态/双架构检查 | 防止同一文档出现重复 Bates ID |

## 核心变化

### Bates 序列

- 数字宽度为 3–15 位，默认 6 位。
- 起始号使用 `Int64`，末号必须容纳在当前数字宽度内。
- 前缀与后缀各最多 24 字符；外侧空白自动清理。
- 拒绝控制字符、换行和 Adobe 明确建议避免的 `#`。
- 默认不强加前缀，预览从 `000001` 开始。

### 页面与外观

- 支持全部页面、指定范围、奇数页和偶数页。
- 支持页眉/页脚的左、中、右六个位置。
- 使用等宽数字字体；根据每页 CropBox、可用宽度和文字长度缩放。
- 若最小可读字号仍无法容纳，整批失败，不写入部分结果。

### 数据安全

- 每个目标页只保留一个 PaperPath Bates 标记。
- 应用前扫描未选页面；若新序列与已有 PaperPath Bates ID 重复，整批拒绝。
- 普通页码、水印、第三方 FreeText 和其他批注不被替换。
- 写入临时文件后重新打开，逐页核验作者标记、文本、数量及显示/打印状态。
- 全局移除只识别 `PaperPath Bates Numbers`。
- 应用与移除均进入文档独占操作、版本快照和一步撤销。

### 专业交互

- Document Tools 提供 Bates Numbering 直达入口。
- Page Bench 在 Page numbers 后提供 Bates 命令。
- 面板并行显示目标页数、完整首末编号和位置。
- 普通字号使用分段页范围控件，大号 Dynamic Type 切换为菜单。
- 停止操作不会立即重新开放提交；若取消恰逢原子提交完成，界面关闭并使用已刷新结果。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - Bates 载荷、64 位格式化、独立生成身份与工具发现语义。
- `PaperPath/Services/PDFMutationService.swift`
  - Bates 应用、冲突检查、长文本适配、重开核验与定向移除。
- `PaperPath/App/PaperPathModel.swift`
  - 独占事务、版本快照和一步撤销接入。
- `PaperPath/Views/StampPickerView.swift`
  - Bates 配置、范围、预览、输入验证、取消和移除工作流。
- `PaperPath/Views/DocumentWorkspaceView.swift`
  - 文档工具直达入口。
- `PaperPath/Views/PageOrganizerView.swift`
  - 页面工作台 Bates 命令。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - V58 简体中文文案。
- `README.md`
  - 更新页面标识能力清单。

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

当前机器仍由环境阻断：Xcode 26.3 提供 iOS Simulator 26.2 SDK，而 CoreSimulator 只安装 26.5 runtime，Scheme 在目标解析阶段失败。

当前源码使用目标级降级命令验证：

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
- `git diff --check`、plist、strings 语法与重复键检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞品证据

- Adobe Acrobat Pro 2025/2026 官方帮助定义了 3–15 位宽度、起始号、前缀、后缀和多文件顺序，并明确部分加密文件与表单类型不支持：
  - https://helpx.adobe.com/africa/acrobat/desktop/edit-documents/apply-bates-numbering/add-bates.html
- PDF Expert 官方页面提供前缀、后缀、数字宽度、位置和外观，但公开路径针对 Mac：
  - https://pdfexpert.com/how-to-add-page-numbers-pdf
- Xodo 2025 官方资料提供前缀、后缀、数字宽度、位置及批量配置，但路径属于桌面 PDF Studio：
  - https://xodo.com/blog/how-to-add-page-numbers-to-pdf

PaperPath 当前可证明的差异是：在 iPhone/iPad 原生工作区中把 Bates 编号接入私有副本、冲突检测、原子替换、重开核验和一步恢复。没有真机任务数据支撑“整体全球领先”结论。

## 未验证风险

- Bates FreeText 在 Acrobat、Preview、PDF Expert、Xodo 中的字体、打印和透明度一致性尚未做互操作验证。
- 旋转页面、极窄页面、非零 CropBox 与 63 字符最长标识尚未做截图对比。
- 10,000 页冲突扫描、写入和取消尾延迟尚未真机测量。
- 当前冲突检查只能识别 PaperPath 生成的 Bates 标记，无法可靠推断第三方任意自由文本是否属于 Bates 序列。
- 标准 Scheme 仍需匹配 Simulator runtime 后复跑。

## 下一阶段

1. 修复 Xcode SDK 与 Simulator runtime 配对，恢复标准双 Scheme 门禁。
2. 用真实法律材料验证 Bates 字号、边距、打印与第三方阅读器兼容性。
3. 真机测量 1,000、5,000、10,000 页编号及冲突扫描。
4. 设计跨文档连续编号事务：文件排序、序列预留、磁盘预算、失败回滚和输出映射。
5. 根据用户证据评估 Bates 范围写入 Delivery Receipt 或版本归档清单。
