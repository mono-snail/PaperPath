# PaperPath V64：可移植签名 Bates 匹配报告

## 本轮目标

V63 已能对外部 PDF 做 Bates 字节匹配，但结果只存在于当前界面，关闭后无法留档、交接或复核。本轮把匹配结果升级为受保护的签名 JSON 报告，并补齐导出、分享、临时清理、重新导入、结构重算、双签名验证和信任展示。

报告仅在用户主动创建时包含凭据文档名、候选文件名、大小和 SHA-256，不包含 PDF 字节；本机 Ed25519 签名不表述为证书签名、法律身份或可信时间戳。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 保护 V63 脏工作区并核对最新状态 | 不覆盖前序成果 |
| 2 | 审计外部 Bates 匹配数据流 | 找到关闭即丢失的证据断点 |
| 3 | 复用现有签名身份和临时导出模式 | 不引入第二套密钥体系 |
| 4 | 定义 `paperpath.bates-match-report.v1` | 报告拥有稳定、可演进契约 |
| 5 | 内嵌原始签名 Bates 凭据 | 结论可追溯到编号批次 |
| 6 | 记录候选文件名、大小和完整 SHA-256 | 文件名只展示，字节指纹用于证据 |
| 7 | 记录 Numbered、Cleared、Source、Missing、Ambiguous | 保留完整结论边界 |
| 8 | 沿用 64 份、单份 1 GB、总计 8 GB 上限 | 匹配输入保持有界 |
| 9 | 将签名报告限制为 2 MB | 防止异常 JSON 消耗资源 |
| 10 | 对规范 JSON 使用 Ed25519 签名 | 报告内容变化可被发现 |
| 11 | 在 `DocumentStore` actor 中生成报告 | 密钥和文件 I/O 不占用主线程 |
| 12 | 使用完整文件保护写临时 JSON | 分享前的本地副本保持受保护 |
| 13 | 分享结束、取消或离开页面后删除临时文件 | 不积累敏感报告副本 |
| 14 | 在匹配结果底部增加“分享签名报告” | 完成核验后可就地交付 |
| 15 | 分享前明确披露名称和哈希边界 | 用户知道将离开设备的元数据 |
| 16 | 防止重复导出、关闭和任务泄漏 | 长操作状态保持一致 |
| 17 | Receipts 工具栏增加匹配报告导入 | 接收方可从 Files 直接验证 |
| 18 | 导入时校验扩展名、常规文件和大小 | 拒绝非预期或超限输入 |
| 19 | 重新推导每条匹配结论 | 不能只修改状态字段伪造结果 |
| 20 | 分别验证报告签名和内嵌凭据签名 | 两层证据任一失效都会明确失败 |
| 21 | 区分本机、可信、未知、无效和不支持签名者 | 密码学有效不等于身份可信 |
| 22 | 无效报告统一使用风险视觉语义 | 不以绿色结论误导用户 |
| 23 | 底部操作适配小屏、大字号和 VoiceOver | 分享与重选不会挤压重叠 |
| 24 | 完成本地化、差异检查和双目标编译 | 保持发布前工程门槛 |

## 核心变化

### 可重算报告

- 报告包含原始签名 Bates 凭据、核验时间、候选文件摘要、逐文档结论和未识别文件。
- 导入时根据完整候选集合与凭据中的 source、numbered、cleared SHA-256 重新计算每条状态。
- 重新检查候选唯一性、哈希所有权、总文件数、总字节数和未识别集合，不直接信任保存的计数或状态。
- 文件名不能包含控制字符，SHA-256 必须是 64 位小写十六进制。

### 双层签名验证

- 原始 Bates 凭据继续验证自身 Ed25519 签名及可选移除签名。
- 外层匹配报告使用当前设备交付密钥独立签名。
- 导入界面分别显示报告签名、报告签名者、Key ID 和内嵌凭据状态。
- 签名者身份复用现有可信签名者列表，但未知签名者不会被自动信任。

### 分享与重新验证

- 匹配结果页新增自适应底部操作区，可重新选择 PDF 或分享报告。
- 分享前明确提示 JSON 会包含凭据文档名、候选文件名、大小和 SHA-256，但不包含 PDF 字节。
- 报告写入完整保护临时文件，并在 Share Sheet 关闭或结果页消失时删除。
- Bates Receipts 的验证菜单可分别导入原始凭据或签名匹配报告。
- 无效报告仍可查看其声明内容，但标题、指标和逐条状态统一使用风险色，避免冒充有效证据。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 可编码的匹配模型、签名报告 payload、封装、结构重算和导入结果。
- `PaperPath/Services/DocumentStore.swift`
  - 报告签发、保护写入、资源边界、双签名验证和签名者信任解析。
- `PaperPath/App/PaperPathModel.swift`
  - 报告导出与导入验证的异步协调和错误呈现。
- `PaperPath/Views/BatchBatesNumberingView.swift`
  - 匹配结果分享、隐私确认、导入菜单和签名报告详情。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - 报告导出、验证、信任和失败状态的简体中文。
- `README.md`
  - 更新可移植签名 Bates 匹配报告能力。

## 编译结果

标准 Scheme 命令：

```bash
xcodebuild \
  -project PaperPath.xcodeproj \
  -scheme PaperPath \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

失败：本机未安装当前 Xcode 所需的 iOS 26.2 Simulator platform，无法解析通用模拟器 destination；未进入源码编译。

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
- 目标级构建覆盖 `arm64` 和 `x86_64`。
- plist、strings、重复本地化键和 `git diff --check` 检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞品证据

本轮于 2026-08-22 查阅：

- Adobe Acrobat 官方 2025-11-05 文档确认支持跨文件 Bates 添加、排序、输出选项和单文档移除：
  - <https://helpx.adobe.com/ph_en/acrobat/desktop/edit-documents/apply-bates-numbering/add-bates.html>
  - <https://helpx.adobe.com/africa/acrobat/desktop/edit-documents/apply-bates-numbering/remove-bates.html>
- Foxit PDF Editor 官方 Mac v13 手册确认提供 Bates 管理和多文件输出路径：
  - <https://help.foxit.com/manuals/pdf-editor/mac/en-us/v13/Organize_PDF_Pages.html#Manage_Bates_Numbering>
- PDFgear 2025-03-21 厂商材料将专业 Bates 路径指向 Acrobat、Nitro 和 Foxit，其自身示例聚焦页码：
  - <https://www.pdfgear.com/pdf-editor-reader/how-to-add-bates-stamp-to-pdf.htm>

上述本轮查阅材料未展示“把候选 PDF 的完整字节匹配结论、原始 Bates 凭据和独立设备签名封装成可重新验证报告”的同类流程。这里只说明材料覆盖范围，不推断竞品不存在未公开能力。

## 竞争优势

- Bates 匹配结果不再只是瞬时界面状态，而是可携带、可复核的本地签名证据。
- 接收方无需 PaperPath 账号或网络即可验证报告签名、原始凭据签名和逐条结论一致性。
- 报告明确区分密码学有效性与签名者信任，并准确披露名称、哈希和 PDF 字节的分享边界。

## 未验证风险

- 尚未使用真实跨设备 AirDrop、邮件和第三方文件提供器验证报告往返。
- 报告 schema 的长期向前兼容和跨版本迁移尚未经过历史版本样本验证。
- 极端重复哈希、64 文件歧义集合和接近 2 MB 的报告尚未做专项压力测试。
- 分享界面在全部 iPhone/iPad 尺寸、横竖屏和最大 Dynamic Type 下尚未截图回归。
- 标准 Scheme 仍需安装匹配的 iOS 26.2 Simulator platform 后复跑。

## 下一阶段

1. 真机验证签名匹配报告的 AirDrop、Files、邮件和第三方文件提供器往返。
2. 为通用 Delivery Receipt 补齐同等级的“外部文件集合匹配报告”能力，避免只服务 Bates。
3. 用版本化样本验证 V1 报告在未来 schema 下的兼容策略。
4. 根据真实法律卷宗反馈决定是否增加人类可读 PDF 摘要；在此之前避免复制一份可能被误读为原始证据的渲染报告。
