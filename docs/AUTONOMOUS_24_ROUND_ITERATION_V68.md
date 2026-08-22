# PaperPath V68：逐页扫描复核与可视化替换

## 本轮目标

本轮对照 Adobe Scan、PDF Expert 和 Xodo 的移动扫描路径，收敛扫描生成与页面
替换中的高频误操作风险。目标不是以扫描功能数量宣称全面领先，而是在不上传
文档的前提下，让每页处理、处理前后核对和原子替换形成更清晰的闭环。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V56-V67 与当前脏工作区 | 不覆盖既有实现 |
| 2 | 核验三款竞品的官方扫描路径 | 只处理有公开证据的差距 |
| 3 | 审计 `ScanReviewView` 状态模型 | 找到整批共享设置的问题 |
| 4 | 审计页面替换的来源和提交链 | 确认照片会绕过扫描复核 |
| 5 | 复核 Receipt、里程碑和容量治理 | 排除已经完成的旧候选方向 |
| 6 | 为 `ScanPageImage` 增加可选逐页参数 | 保持旧调用兼容 |
| 7 | 渲染器按页选择处理参数 | 一批扫描可混合不同处理方式 |
| 8 | 模型层增加逐页扫描导入入口 | UI 参数完整进入最终 PDF |
| 9 | 外部替换源增加逐页处理入口 | 扫描替换与普通扫描使用同一语义 |
| 10 | Scan Review 保存逐页设置 | 当前页调整不再意外改动其他页 |
| 11 | 页面重排同步交换处理参数 | 图像与设置始终绑定 |
| 12 | 页面删除同步删除处理参数 | 不产生设置错位 |
| 13 | 增加“应用到全部页面” | 保留批量统一处理效率 |
| 14 | 增加原图/处理后切换 | 可直接判断增强是否过度 |
| 15 | 选项变化时清除旧预览并显示进度 | 不把陈旧图像误认为当前结果 |
| 16 | 预览 worker 接入取消传播 | 快速切换页面时停止过期处理 |
| 17 | 高清旋转改为方向元数据变换 | 避免主线程整图重绘和额外位图峰值 |
| 18 | 页面工具触控区提升到 44pt | 小屏和辅助操作更可靠 |
| 19 | 辅助字号下缩略图和工具拆为两行 | 页面工具不再挤压缩略图 |
| 20 | 辅助字号下预览模式改为 Menu | 原图/处理后选择保持可读 |
| 21 | 照片替换统一进入 Scan Review | 照片也可旋转、裁切和增强后替换 |
| 22 | 替换前并列展示当前页和候选页 | 降低替错页面的概率 |
| 23 | 大字体下来源与来源操作拆为两行 | Library / Files / Photos / Camera 不拥挤 |
| 24 | 补齐中文、静态检查和双目标编译 | 保持可构建交付基线 |

## 核心变化

### 逐页处理

- `ScanPageImage` 可携带当前页的 `ScanProcessingOptions`。
- 扫描复核分别保存每页的滤镜、自动裁切、阴影处理和边缘清理设置。
- 重排和删除会同步移动或删除对应设置。
- “应用到全部页面”可把当前页设置复制到整批，兼顾逐页精度和批量效率。
- 旧调用不提供逐页设置时继续使用原有批次参数，不改变既有输出。

### 准确预览

- 增加 Original / Processed 模式，用户可核对增强是否损失印章、细线或浅色文字。
- 参数变化时旧预览立即失效，并显示明确的更新状态。
- SwiftUI `.task(id:)` 的取消会传递给 detached 预览 worker，过期 Vision/Core
  Image 任务可尽早停止。
- 原图模式不触发处理预览，避免不必要计算。

### 旋转性能

旧实现使用 `UIGraphicsImageRenderer` 在主线程重绘完整扫描位图。V68 改为更新
`UIImage.Orientation`，旋转操作本身不再创建同尺寸像素副本。

这是基于实现的预期改善：旋转操作由像素级工作降为常量级方向变换，并降低瞬时
位图峰值；尚未通过真机 Instruments 得出耗时、能耗或内存百分比。

### 页面替换

- Camera 和 Photos 现在都先进入统一 Scan Review。
- 处理完成后仍生成临时受保护 PDF，再执行现有原子页面替换。
- 替换页增加 Current / Replacement 并列预览，来源页切换时同步更新。
- 原有页面尺寸、方向差异提示继续基于处理后的临时 PDF 计算。
- 辅助字号下来源模式使用 Menu，并与来源操作拆成上下两行。

## 修改文件

- `PaperPath/Services/ScanPDFRenderer.swift`
- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Views/ScanReviewView.swift`
- `PaperPath/Views/PageOrganizerView.swift`
- `PaperPath/Views/LibraryView.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`

## 竞品结论

- Adobe Scan 官方文档明确提供逐页裁边、旋转、滤镜、亮度/对比度和 Apply to
  all pages；其手工裁边、亮度/对比度和多页选择仍比 PaperPath 当前扫描复核深。
- PDF Expert 官方流程覆盖扫描、多页保存、后续重排和编辑，但公开页面未描述
  与 PaperPath 相同的处理前后核对及原子替换证据。
- Xodo 2026 移动端指南强调内置扫描、扫描结果微调和跨端工具覆盖，但未公开
  PaperPath 的私有工作副本、替换前几何检查或原子回滚模型。
- PaperPath V68 的可防守优势是：逐页处理参数、本地原图/处理后核对、受保护
  临时来源、替换前双页预览、原子写入和完整撤销处于同一工作流。

参考：

- [Adobe Scan: Modify your scans](https://www.adobe.com/devnet-docs/adobescan/ios/en/modify.html)
- [PDF Expert: Scan PDFs on iPhone and iPad](https://pdfexpert.com/ios/how-to-scan-pdfs)
- [Xodo Mobile 2026 guide](https://xodo.com/blog/how-to-use-xodo-pdf-reader-and-editor-mobile-app)

## 工程验证

标准 Scheme 命令：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

结果：退出码 `70`。本机 Xcode 报告 iOS 26.2 platform 未安装，未进入源码编译。

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
- 构建日志无新增源码警告或错误。
- `Localizable.strings`、Info plist、重复键和 `git diff --check` 通过。
- 按本轮约束未运行单元测试、UI 测试或截图回归。

## 未验证风险

- 方向元数据在第三方来源的 mirrored、CIImage-backed 和异常 EXIF 图片上仍需
  真机样本验证。
- 各页混合 Auto Crop、Document、B&W 和 Original 的最终 PDF 需与预览逐页
  对照。
- VisionKit 相机、照片选择器转场和高分辨率多页扫描仍需真机内存与能耗测量。
- 最大 Dynamic Type、VoiceOver、横屏和 iPad 多窗口尚未截图及人工走查。
- Adobe Scan 已公开的手工裁边、亮度/对比度和多页批量选择尚未实现。

## 下一阶段

1. 真机验证 mirrored/EXIF 方向、12 页高分辨率扫描和快速切换参数。
2. 为扫描页增加可撤销的手工四角裁边，不降低自动裁切的快速路径。
3. 评估亮度/对比度滑杆及多页选择，避免复制无价值滤镜。
4. 用真实票据、合同印章和浅色铅笔样本校验预览与最终 PDF 一致性。
