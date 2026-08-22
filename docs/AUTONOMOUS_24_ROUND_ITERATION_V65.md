# PaperPath V65：跨设备 Delivery 文件集合匹配

## 本轮目标

V64 已完成 Bates 专用匹配报告，但通用 Office Delivery Report 仍只能验证 JSON 签名，接收方无法确认手中的 DOCX、XLSX、PPTX、RTF、Markdown 和文本文件是否就是报告声明的交付产物。本轮补齐签名报告到实际文件集合的本地 SHA-256 匹配。

文件匹配不修改、不导入、不持久化用户选择的外部文件，也不把本机 Ed25519 签名宣传为证书签名、法律身份或可信时间戳。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 以 V64 脏工作区为基线继续开发 | 不覆盖前序成果 |
| 2 | 审计 Delivery Report 导入和验签路径 | 确认现有能力只验证 JSON |
| 3 | 审计输出条目、格式和哈希契约 | 匹配建立在真实清单字段上 |
| 4 | 定义外部交付文件候选模型 | 文件名、大小和哈希边界明确 |
| 5 | 定义逐输出匹配模型与总体报告 | 每份交付产物可独立判断 |
| 6 | 区分 Exact、Missing、Ambiguous、Metadata mismatch 和 Extra | 异常不会被合并成模糊失败 |
| 7 | 限制为 128 个候选、单文件 1 GB、总计 8 GB | 外部输入保持有界 |
| 8 | 只允许报告声明的输出扩展名 | 避免扫描无关或意外文件 |
| 9 | 每个文件单独申请并释放安全作用域 | 不长期持有 Files 权限 |
| 10 | 使用 1 MB 缓冲流式计算 SHA-256 | 避免整文件加载内存 |
| 11 | 每轮读取检查任务取消 | 停止后不继续处理剩余数据 |
| 12 | 提供文件数、字节数和当前文件进度 | 大文件匹配状态可见 |
| 13 | 检测重复候选和共享哈希所有权 | 多重对应不会武断通过 |
| 14 | 文件名仅用于展示 | 重命名不改变匹配证据 |
| 15 | 有效报告结果区增加就近匹配入口 | 无需切换到其他工具 |
| 16 | 支持 DOCX、XLSX、PPTX、RTF、MD 和 TXT | 覆盖报告真实声明的全部格式 |
| 17 | 匹配期间提供 Stop 并冻结冲突入口 | 生命周期行为一致 |
| 18 | 增加 Exact、Review、Extra 高密度摘要 | 快速判断文件集合完整性 |
| 19 | 按签名清单顺序展示逐文件结果 | 便于按交付顺序复核 |
| 20 | 单独列出报告外文件 | 混入文件不会被忽略 |
| 21 | 报告验签前新增 schema、名称、大小和哈希结构门禁 | 有效签名不掩盖畸形清单 |
| 22 | 区分报告签名、签名者信任和文件字节匹配 | 三种结论不互相替代 |
| 23 | 修正未知签名者的颜色语义并适配动态布局 | 有效但未知不再显示为完全可信 |
| 24 | 完成本地化、静态检查和双目标编译 | 保持发布前工程门槛 |

## 核心变化

### Delivery Report 结构门禁

- 只接受 `PaperPath Office Delivery V34`。
- 输出条目必须非空且不超过 128 个，`verified_outputs` 必须与条目数一致。
- Receipt ID 和归档文件名必须唯一。
- 文件名拒绝控制字符、路径穿越和反斜杠。
- 扩展名必须与声明格式一致。
- 每条必须包含 64 位小写 SHA-256，单文件不超过 1 GB，清单总字节不超过 8 GB。
- App 自己签发报告时也执行同一门禁，避免产生无法可靠验证的清单。

### 外部文件集合匹配

- 用户验证签名报告后，可选择 1 至 128 个实际交付文件。
- 文件读取使用安全作用域和流式 SHA-256，不复制文件，不读取文档正文。
- Exact 需要完整哈希、签名大小和唯一哈希所有权同时匹配。
- 同一文件重复选择、多个条目共享同一哈希或多个候选命中时显示 Ambiguous。
- 哈希命中但签名大小矛盾时显示 Signed metadata mismatch。
- 未找到对应文件显示 Missing，未出现在报告中的候选显示 Extra。

### 专业交互

- Office Production 的报告验证区直接提供 Match Delivery Files。
- 匹配期间显示当前文件、完成数量、处理字节和总体进度。
- 顶部 Done 切换为 Stop，交互式关闭和报告切换入口暂时禁用。
- 结果页使用清单顺序、格式标识、原 PDF 名和候选文件名并行呈现。
- 签名有效但签名者未知使用琥珀色，而不是与本机或可信签名者共用绿色。
- 结果页再次明确：签名有效、签名者可信和文件字节匹配是三个独立结论。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - Delivery Report 结构验证、候选、状态、结果和进度模型。
- `PaperPath/Services/DocumentStore.swift`
  - 签发前门禁、导入报告强化验证、安全作用域、流式哈希和集合匹配。
- `PaperPath/App/PaperPathModel.swift`
  - 匹配任务、进度、取消和签名报告状态保留。
- `PaperPath/Views/LibraryView.swift`
  - 文件选择、匹配进度、信任层级和逐输出结果页。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - 新增匹配、异常、进度和证据边界文案。
- `README.md`
  - 更新跨设备 Delivery 文件匹配能力。

## 编译结果

标准 Scheme：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

失败：本机未安装当前 Xcode 所需的 iOS 26.2 Simulator platform，无法解析通用 Simulator destination；未进入源码编译。

源码降级门禁：

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

- `PaperPath`：源码编译与链接成功。
- `PaperPathShareExtension`：源码编译与链接成功。
- 产物包含 `arm64` 和 `x86_64`。
- plist、strings、重复本地化键和 `git diff --check` 检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞品证据

本轮于 2026-08-22 查阅：

- Adobe Acrobat 2025-11-05 官方文档提供 PDF 内数字签名、证书和时间戳验证：
  - <https://helpx.adobe.com/ph_en/acrobat/desktop/e-sign-documents/manage-digital-signatures/validate-digital-sign.html>
- Foxit 官方文档提供 PDF 数字签名、证书信任和长期验证：
  - <https://help.foxit.com/manuals/pdf-editor/mac/en-us/12.1.0/PDF_Sign.html>
- Xodo PDF Studio 2024-06-18 官方文档提供 PDF 签名完整性和证书信任验证：
  - <https://feedback.xodo.com/support/solutions/articles/35000251550-validating-a-digital-signature>

这些资料聚焦 PDF 内嵌证书签名。本轮查阅页面未展示用一个独立本地签名清单，逐份匹配异构 DOCX、XLSX、PPTX、RTF、Markdown 和 TXT 交付集合的相同流程。这里只陈述资料覆盖范围，不推断竞品不存在其他未公开能力。

## 竞争优势

- 一个签名报告可以在另一台设备上核对整个异构 Office 交付集合，而不是只证明报告 JSON 自身未变化。
- 文件名不参与证据判断，重命名不会导致错误失效；完整 SHA-256、大小和唯一所有权共同决定 Exact。
- 全过程本地完成，无账号、无网络、不复制外部文件，并准确区分签名、信任和字节匹配。

## 未验证风险

- 尚未用真实 Word、Excel、PowerPoint、Pages、Numbers 和第三方文件提供器做跨设备往返。
- 128 个文件或接近 8 GB 的取消延迟、热量、能耗和文件提供器稳定性尚未实测。
- 某些文件提供器可能只在下载完成后提供稳定字节，当前会在大小变化时失败关闭。
- 结果目前是会话态，尚未导出为独立签名匹配报告。
- 标准 Scheme 仍需安装匹配的 iOS 26.2 Simulator platform 后复跑。

## 下一阶段

1. 在真机对 iCloud Drive、OneDrive、Dropbox 和 AirDrop 文件执行匹配与取消验证。
2. 为通用 Delivery 匹配结果增加与 V64 相同的可选签名导出和重新导入。
3. 用接近资源上限的混合格式集合测量内存、能耗和进度更新频率。
4. 根据实际需求决定是否支持直接验证完整 PaperPath Office Delivery ZIP，避免盲目扩大 ZIP 解析边界。
