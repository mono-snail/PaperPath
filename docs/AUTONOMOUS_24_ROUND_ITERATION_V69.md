# PaperPath V69：扫描精调与多页批处理

## 本轮目标

本轮延续 V68 的逐页扫描模型，对照 Adobe Scan 已公开的亮度、对比度和多页
操作能力，补齐真实高频差距，并控制连续预览的计算成本。

PaperPath 的胜负线仍是本地私有处理、复核明确和原子替换。未实现手工四角裁边
前，不宣称扫描功能整体超过 Adobe Scan。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V68 与脏工作区 | 不覆盖已有逐页扫描成果 |
| 2 | 复核 Adobe Scan 官方逐页调节证据 | 选择真实差距而非堆滤镜 |
| 3 | 审计扫描参数兼容性 | 新字段不破坏旧初始化调用 |
| 4 | 审计连续预览计算成本 | 找到滑杆高频触发风险 |
| 5 | 审计缩略图多页操作 | 确认只能逐页旋转和删除 |
| 6 | 增加有界亮度参数 | 可恢复浅色文字和暗部 |
| 7 | 增加有界对比度参数 | 可改善低反差票据和复印件 |
| 8 | 为旧参数初始化提供默认值 | 现有调用和测试源码保持兼容 |
| 9 | Core Image 管线应用色调调整 | 最终 PDF 使用真实参数 |
| 10 | 预览和最终渲染共用处理函数 | 避免两套视觉结果 |
| 11 | 预览请求标识纳入色调值 | 过期结果不能覆盖当前滑杆状态 |
| 12 | 连续输入增加 100ms 去抖 | 快速拖动只执行稳定后的预览 |
| 13 | 亮度滑杆使用 0.05 步进 | 调整准确且不会过度敏感 |
| 14 | 对比度滑杆使用 0.05 步进 | 数值变化稳定可控 |
| 15 | 增加中性色调重置 | 一步恢复亮度 0、对比度 1 |
| 16 | 建立缩略图多选模式 | 无需逐页重复执行 |
| 17 | 增加全选和清除选择 | 长扫描件选择更快 |
| 18 | 增加所选页面批量旋转 | 多页方向错误可一次修正 |
| 19 | 增加所选页面批量删除 | 可集中清理误拍页面 |
| 20 | 禁止删除全部扫描页 | 保持扫描输出至少一页 |
| 21 | 批量删除增加确认 | 降低误删多页风险 |
| 22 | 支持复制当前参数到所选页面 | 在逐页和全部之间增加精确范围 |
| 23 | 完善多选 VoiceOver、触觉和大字体滚动 | 辅助路径不被新控件破坏 |
| 24 | 补齐中文并完成双目标编译 | 保持交付基线 |

## 核心变化

### 色调精调

- `ScanProcessingOptions` 新增 `brightness` 与 `contrast`。
- 模型层接受范围分别限制为 `-0.5...0.5` 和 `0.5...1.5`。
- UI 提供更保守的 `-0.35...0.35` 与 `0.7...1.4` 范围，步进均为 `0.05`。
- 数值使用稳定的等宽数字，并提供独立重置按钮。
- 原有四参数初始化调用继续有效，新参数默认保持中性。

### 预览性能

- 亮度和对比度加入预览请求标识。
- 滑杆输入先等待 100ms；新的输入会取消旧任务及其 detached worker。
- 等待期间旧预览会降低不透明度并显示更新状态，不会被误认为最终结果。
- 只有非中性色调才创建额外 `CIColorControls`，默认路径没有新增滤镜开销。

以上是实现层面的预期改善，尚未通过真机 Instruments 量化 CPU、内存和能耗。

### 多页批处理

- “选择页面”进入明确的多选模式，缩略图显示选择标记。
- 支持全选、清除选择、批量旋转和批量删除。
- 批量旋转继续使用 V68 的方向元数据变换，不重绘完整像素。
- 批量删除按倒序移除图像和逐页参数，避免索引偏移。
- 删除全部页面被禁用；批量删除前必须确认。
- 当前页参数可复制到所选页面，仍保留“应用到全部页面”。

### 适配与反馈

- 批量选择数量进入顶部指标。
- VoiceOver 会朗读页面选择状态和点击行为。
- 滑杆变化不触发连续触觉反馈；选择变化、应用和重置提供独立反馈。
- 辅助字号下控制面板变为有界垂直滚动，防止挤压预览和页面工具。

## 修改文件

- `PaperPath/Services/ScanPDFRenderer.swift`
- `PaperPath/Views/ScanReviewView.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`

## 竞品结论

Adobe Scan 官方文档明确支持亮度/对比度、Apply to all pages，以及多页旋转和
删除。V69 已补齐这些能力的核心任务结果，并额外提供：

- 参数按页存储并可复制到任意所选范围。
- 原图/处理后对照。
- 可取消、带修订保护的本地预览。
- 照片和相机统一复核。
- 受保护临时 PDF、替换前并列预览、几何检查、原子写入与撤销。

PDF Expert 和 Xodo 继续在产品成熟度、跨端或工具覆盖方面有优势；其公开扫描
页面没有提供与 PaperPath 同口径的原子替换和本地证据链说明。

参考：

- [Adobe Scan: Modify your scans](https://www.adobe.com/devnet-docs/adobescan/ios/en/modify.html)
- [PDF Expert: Scan PDFs on iPhone and iPad](https://pdfexpert.com/ios/how-to-scan-pdfs)
- [Xodo Mobile 2026 guide](https://xodo.com/blog/how-to-use-xodo-pdf-reader-and-editor-mobile-app)

## 工程验证

目标级双架构门禁：

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
- 构建日志无新增源码警告或错误；仅有全架构构建提示。
- `Localizable.strings`、Info plist、重复键和 `git diff --check` 通过。
- 同一环境下 V68 已确认标准 Scheme 因缺少 iOS 26.2 platform 无法解析目标，
  本轮未重复该环境失败。
- 按约束未运行单元测试、UI 测试或截图回归。

## 未验证风险

- 亮度和对比度对印章、铅笔、热敏票据及 B&W 阈值的效果需真实样本验证。
- 12 页高分辨率扫描连续拖动滑杆的 CPU、内存和能耗仍需真机测量。
- 多页旋转、删除和参数复制尚未进行 VoiceOver 人工走查。
- 最大 Dynamic Type、横屏和 iPad 多窗口下的控制区滚动尚未截图验证。
- Adobe Scan 的手工四角裁边、清理画笔和多种扫描模式仍更完整。

## 下一阶段

1. 增加可撤销的手工四角裁边，并与自动检测结果互相切换。
2. 用真实票据、印章和浅色文字样本建立亮度/对比度推荐范围。
3. 真机量化连续预览去抖前后的 CPU、内存、热状态和能耗。
4. 根据实际需求评估多页拖拽重排，避免复制已有单页移动能力。
