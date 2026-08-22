# PaperPath V70：可撤销手工四角裁边

## 本轮目标

本轮对照 Adobe Scan 已公开的手工裁边能力，补齐 V69 后仍然明确存在的扫描质量
差距。目标是让自动检测、手工修正、处理预览和最终 PDF 使用同一组坐标，同时
避免拖动过程中持续运行 Vision 或 Core Image。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V69 与脏工作区 | 不覆盖既有扫描精调成果 |
| 2 | 复核 Adobe Scan 手工裁边证据 | 选择真实质量缺口 |
| 3 | 审计 Vision 与 Core Image 坐标方向 | 避免上下颠倒或角点错位 |
| 4 | 定义归一化四角模型 | 参数不依赖预览或原图分辨率 |
| 5 | 增加坐标范围钳制 | 控制点不能离开图像 |
| 6 | 增加最小面积和边长校验 | 阻止退化裁边 |
| 7 | 增加凸性校验 | 阻止边界交叉 |
| 8 | 保持旧扫描参数初始化兼容 | 既有调用无需修改 |
| 9 | 手工四角接入透视校正 | 最终 PDF 使用真实裁边 |
| 10 | 手工裁边优先于自动检测 | 用户修正不会被 Vision 覆盖 |
| 11 | 无效几何失败关闭 | 不向 Core Image 提交危险参数 |
| 12 | 预览结果返回自动检测四角 | 手工编辑可从检测结果开始 |
| 13 | 裁边坐标进入预览请求标识 | 旧结果不能覆盖新裁边 |
| 14 | 建立原图等比显示坐标映射 | 覆盖层与图像保持一致 |
| 15 | 绘制外部遮罩和裁边边界 | 裁切范围一眼可见 |
| 16 | 增加四个 44pt 拖动控制点 | 小屏操作更可靠 |
| 17 | 拖动实时执行防交叉约束 | 始终保留最后一个有效四边形 |
| 18 | 增加专注裁边模式 | 隐藏无关批处理控件 |
| 19 | 增加重置、取消和应用 | 裁边具备完整退出路径 |
| 20 | 未应用草稿保持隔离 | 取消不会污染页面参数 |
| 21 | 自动/手工裁边互斥切换 | 状态来源明确 |
| 22 | 旋转时同步迁移裁边坐标 | 页面方向与裁边继续一致 |
| 23 | VoiceOver 提供四方向微调 | 控制点不只依赖拖动 |
| 24 | 补齐中文并完成双目标编译 | 保持交付基线 |

## 核心变化

### 四角数据模型

- `ScanCropPoint` 使用 `0...1` 的归一化坐标。
- `ScanCropQuad` 按左上、右上、右下、左下保存四角。
- 校验包含坐标范围、最小面积、最小边长和四边形凸性。
- 拖动产生无效几何时保留上一有效状态，不允许边界交叉。
- 裁边键使用千分位量化坐标，参与异步预览修订保护。

### 自动检测与手工修正

- 自动 Vision 检测结果会转换为屏幕左上原点的归一化四角。
- 进入手工编辑时优先使用当前手工参数，其次使用最近的自动检测结果，最后才
  使用全幅。
- 手工裁边应用后关闭 Auto Crop；重新开启 Auto Crop 会清除当前手工裁边。
- Clean Edges 同时支持自动与手工裁边，全幅模式下保持禁用。

### 编辑体验

- 裁边按钮位于预览右下角，已有手工裁边时使用完成状态颜色。
- 编辑期间强制显示原图，并隐藏页面队列和普通处理控件。
- 图像外部使用遮罩，裁边边界使用高对比细线。
- 四角控制点的可见直径为 20pt，实际触控区域为 44pt。
- 工具栏和底部操作均可取消裁边；交互式下拉关闭在编辑期间禁用。
- Reset Corners、Cancel 和 Apply Crop 在窄宽度或大字体下自动改为纵向布局。

### 性能与一致性

- 拖动只更新 SwiftUI 覆盖层，不运行 Vision、透视校正或图像增强。
- Apply 后才触发现有 100ms 去抖预览；最终 PDF 继续使用相同
  `ScanProcessingOptions`。
- 手工四角优先进入 `CIPerspectiveCorrection`，输出仍执行最小尺寸检查。
- 页面旋转使用方向元数据变换，并同步将裁边坐标顺时针旋转。
- 将当前参数复制到其他页面时，不复制当前页的手工几何，避免把一个页面的
  四角错误套用到另一页。

以上性能判断来自实现结构，尚未通过真机 Instruments 量化。

## 修改文件

- `PaperPath/Services/ScanPDFRenderer.swift`
- `PaperPath/Views/ScanReviewView.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`

## 竞品结论

Adobe Scan 官方文档明确提供手工裁边、旋转、滤镜、亮度/对比度及多页操作。
V68-V70 已覆盖这些能力的核心结果，并增加：

- 自动检测结果直接作为可编辑四角起点。
- 四角几何失败关闭和异步结果修订保护。
- 拖动阶段不持续执行图像处理。
- 逐页、所选页面、全部页面三级参数范围。
- 原图/处理后核对。
- 私有工作副本、受保护临时源、替换前双页预览、几何检查、原子写入和撤销。

PaperPath 在“本地扫描后安全替换 PDF 页面”的完整闭环上形成可防守优势，但
Adobe Scan 的清理画笔、更多扫描模式和大规模真机验证仍然更成熟。

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
- 同一环境下标准 Scheme 仍受缺少 iOS 26.2 platform 阻断，本轮未重复环境失败。
- 按约束未运行单元测试、UI 测试或截图回归。

## 未验证风险

- Vision 四角在 mirrored EXIF、超广角畸变和严重倾斜照片上需真机样本验证。
- 四角覆盖层与最终 PDF 的像素级一致性尚未做截图和样本比对。
- 最大 Dynamic Type、VoiceOver 四方向动作、横屏和 iPad 多窗口需人工走查。
- 手工裁边后的印章、细线、浅色文字和 Clean Edges 组合仍需真实材料验证。
- Adobe Scan 的清理画笔和更多扫描模式尚未实现。

## 下一阶段

1. 用真实票据、合同、印章和 mirrored EXIF 图片验证裁边坐标。
2. 评估局部清理画笔，只允许作用于 App 私有扫描副本并提供撤销。
3. 真机量化 12 页扫描、连续裁边和最终渲染的内存与能耗。
4. 在收到真实使用证据前停止继续增加扫描滤镜或模式。
