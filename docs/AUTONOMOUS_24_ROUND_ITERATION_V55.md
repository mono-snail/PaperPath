# PaperPath V55：可见页码工作流

## 本轮目标

V54 已补齐专业页面整理操作。本轮重新审计后确认：PaperPath 已支持逻辑页标签和当前页标准印章，但缺少面向整份文档的可见页码。V55 在不引入新渲染引擎的前提下，基于 PDFKit FreeText 批注实现本地、批量、可编辑、可撤销、可移除和重开验证的页码工作流。

本轮没有进行真机任务计时或竞品同机测试，不使用“全球领先”替代外部证据。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 以 V54 和当前脏工作区为基线 | 保护已有实现和未提交修改 |
| 2 | 审计逻辑页标签、标准 Stamp 和批注审查能力 | 明确可见页码是真实缺口 |
| 3 | 选择 PDFKit FreeText 作为页码载体 | 保持原生、可编辑和可审查 |
| 4 | 定义仅数字、Page N、Page N of M 三种格式 | 覆盖简洁与正式文档编号 |
| 5 | 定义顶部/底部的左、中、右六种位置 | 适配合同、报告和扫描材料 |
| 6 | 定义 `Sendable` 批量页码载荷 | UI 与 PDF 服务边界明确 |
| 7 | 页码正文使用现有本地化层生成 | 中英文文档输出与界面语言一致 |
| 8 | 一次打开 PDF 完成整批页码写入 | 避免逐页重复保存 |
| 9 | 页索引去重、排序并校验范围 | 输入顺序不会造成错号或重复 |
| 10 | 单次最多处理 10,000 页 | 异常输入拥有明确资源边界 |
| 11 | 起始编号限制为 1 至 999,999 | 避免溢出与异常超长编号 |
| 12 | 根据 CropBox 动态计算页码宽度、边距和字号 | 不同页面尺寸保持稳定布局 |
| 13 | 极窄或异常页面失败关闭 | 不生成越界批注 |
| 14 | 使用专用作者标记识别 PaperPath 页码 | 不与普通 FreeText 混淆 |
| 15 | 重复应用时只替换选中页的旧生成页码 | 调整格式无需手工逐页删除 |
| 16 | 写入后重新打开并逐页核对标记与内容 | “保存成功”不等于未经验证 |
| 17 | 支持一次移除全部 PaperPath 页码 | 可安全回退且不影响其他批注 |
| 18 | 添加和移除均接入版本快照与一级撤销 | 误操作可恢复 |
| 19 | 支持全部、范围、奇数页和偶数页作用域 | 常见装订和封面跳过场景可完成 |
| 20 | 支持起始编号、格式和位置配置 | 满足正式交付排版需求 |
| 21 | 提供实时纸张预览、作用页数和末页编号 | 提交前可判断结果 |
| 22 | Dynamic Type 下分段控件自动改为菜单，并补齐 VoiceOver | 小屏和辅助字号不挤压 |
| 23 | 页面工作台增加页码入口，工具搜索补充 page number/页码语义 | 用户能按任务找到功能 |
| 24 | 补齐中文资源，完成静态检查与双 Scheme 双架构编译 | 保持发布构建门槛 |

## 核心变化

### 页码能力

- 三种格式：数字、`Page N`、`Page N of M`。
- 六种位置：顶部或底部的左、中、右。
- 四种范围：全部、指定范围、奇数页、偶数页。
- 可设置起始编号，范围变化会自动约束编号上限。
- 页码为可打印、可编辑的 PDF FreeText 批注。

### 数据安全

- 批量应用只进行一次 PDF 写入。
- 每次应用和移除前创建版本快照，复用一级撤销。
- 只移除作者标记为 `PaperPath Page Numbers` 的生成批注。
- 写入后重新打开文件，逐页校验生成数量和文字内容。
- 异常页尺寸、越界页码、空范围和超大批次均失败关闭。

### 交互

- 页面工作台新增 `Page numbers` 命令。
- 配置页同时展示作用页数、起始编号、位置和真实文本预览。
- 应用期间禁止重复提交和交互式关闭。
- 移除全部页码通过显式危险操作确认。
- 普通字号使用分段控件，大号 Dynamic Type 自动使用菜单。
- Organize Pages 和 Fix Pages 搜索语义包含 number/paginate/页码/编号。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 页码格式、位置和批量载荷。
- `PaperPath/Services/PDFMutationService.swift`
  - 批量添加、替换、移除、几何计算和重开验证。
- `PaperPath/App/PaperPathModel.swift`
  - 快照、撤销、任务互斥和结果反馈。
- `PaperPath/Views/StampPickerView.swift`
  - 页码配置、预览、范围和移除界面。
- `PaperPath/Views/PageOrganizerView.swift`
  - 页面工作台入口。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - 页码工作流简体中文。
- `docs/AUTONOMOUS_24_ROUND_ITERATION_V55.md`

## 编译结果

```bash
xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PaperPath-V55-App-DerivedData \
  build CODE_SIGNING_ALLOWED=NO

xcodebuild -quiet \
  -project PaperPath.xcodeproj \
  -scheme PaperPathShareExtension \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PaperPath-V55-Share-DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

- 首次编译发现预览使用了不存在的 `PPColor.paper`，改为现有 `PPColor.surface`。
- `PaperPath` 最终：**BUILD SUCCEEDED**
- `PaperPathShareExtension` 最终：**BUILD SUCCEEDED**
- 主 App、内嵌扩展和独立扩展均覆盖 arm64 与 x86_64 Simulator。
- `git diff --check`、plist、strings 和重复本地化键检查通过。
- 按规范未运行单元测试、UI 测试或截图回归。

## 竞争优势

- 可见页码不是导出后不可追踪的像素覆盖，而是可审查、可移除、可撤销的标准 PDF 批注。
- 批量写入后重新打开并逐页验证，延续 PaperPath 的可信修改路径。
- 页码可继续进入现有安全分享和扁平化流程，无需上传 PDF 或依赖服务端。
- 大字号、VoiceOver、范围状态和危险移除均有明确交互。

这些是当前代码可证明的实现优势，不代表已经量化超过 PDF Expert、Adobe Acrobat 或 PDFgear。

## 未验证风险

- 尚未在 Acrobat、Preview、PDF Expert 等阅读器中验证 FreeText 外观一致性。
- 旋转 90/270 度、非零 CropBox 原点和极端自定义页面仍需真实样本视觉检查。
- 尚未在数千页真机样本上测量写入时间、内存和取消尾延迟。
- 页码扁平化后的字体外观尚未纳入截图回归。
- 本轮未运行自动化测试。

## 下一阶段

1. 使用旋转页、混合尺寸、非零 CropBox 和复杂批注样本验证页码互操作。
2. 在真机上测量 100/500/2,000 页批量编号与移除。
3. 验证页码经过安全分享扁平化后的外观和 Delivery Receipt。
4. 基于用户任务判断是否继续扩展页眉、页脚或水印，避免把相近功能堆成复杂面板。
