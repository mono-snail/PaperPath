# PaperPath V74：收件端可信交付验证

## 本轮目标

V73 可以把精确 PDF 与签名 Receipt 打成一个本地交付包，但收件人仍需借助
其他工具理解 JSON 和手工核对哈希。V74 补齐接收端闭环：

> 用户从 Files 选择 PaperPath 交付包后，App 在原位置只读、流式验证 ZIP、
> PDF、Receipt 签名和本机信任关系，并给出可操作且不夸大的结论。

该能力不导入或解压 PDF，不创建账号，不上传文件，也不把设备 Ed25519 身份
宣传为数字证书或法律身份。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V72/V73、脏工作区与持续迭代硬约束 | 避免重复版本证据链与交付包生成 |
| 2 | 审计版本归档验证器和现有签名信任模型 | 复用成熟安全边界 |
| 3 | 核验 PDF Expert、Acrobat、PDFgear 的签署与验证资料 | 区分视觉签名、证书验证和 PaperPath 包验证 |
| 4 | 确认 V73 的真实断点是收件端无法直接验证 | 将迭代集中到完整交付闭环 |
| 5 | 新增交付包验证报告模型 | 完整性、签名、信任状态可独立表达 |
| 6 | Outputs 工作区新增“验证交付包”入口 | 接收文件时无需进入存储管理 |
| 7 | 首页“+”菜单增加同一入口 | 无文档状态也能直接验证收到的包 |
| 8 | Files 选择器限定单个 ZIP | 输入意图明确，避免误选多文件 |
| 9 | 使用安全作用域原地只读文件 | 不复制、不导入、不修改外部包 |
| 10 | 限制归档为 1.1 GB、2 个条目、清单 1 MB | 大文件与恶意清单资源有界 |
| 11 | 仅接受未加密、无 data descriptor 的 STORE ZIP | 拒绝压缩炸弹和不确定流式结构 |
| 12 | 拒绝路径、隐藏名、反斜杠、重复名与超长 UTF-8 名 | 阻断目录穿越和条目混淆 |
| 13 | 校验 EOCD、Local Header 与 Central Directory 一致性 | 截断、重叠和伪造目录失败关闭 |
| 14 | 逐条目流式计算 CRC32 | ZIP 层损坏可被识别 |
| 15 | 以 256 KB 分块同步计算 PDF SHA-256 | 不把最大 1 GB PDF 装入内存 |
| 16 | 校验 PDF 文件头、字节数和清单文件名 | 错附件和非 PDF 伪装可被识别 |
| 17 | 校验 V1 清单结构、页数、修订关系和检查项上限 | 不信任仅能成功解码的 JSON |
| 18 | 重新编码规范化清单并验证 Ed25519 | Receipt 或签名封装变化会失败 |
| 19 | 复用本机身份与可信签名者列表 | 本设备、已信任、未知、无效四态连续 |
| 20 | 完整性失败时禁止登记签名者 | 不能从损坏包建立信任 |
| 21 | 未知签名者信任前增加 Key ID 核对确认 | 降低误信陌生密钥风险 |
| 22 | 4 MB 节流的字节进度、底部状态条与停止动作 | 大包验证可理解、可取消且不过度刷新 UI |
| 23 | 结果页展示完整预期/实际 SHA、包与 Receipt ID、签名声明 | 人工复核和故障定位不依赖截断摘要 |
| 24 | 补齐 Dynamic Type 布局、VoiceOver 标识、触觉和简中资源 | 小屏、大字体和辅助技术路径完整 |

## 核心实现

### 流式只读验证

`PDFVersionArchiveVerificationService` 的 ZIP 读取过程被收敛为共享检查入口，
版本归档与交付包共同使用以下门禁：

- 文件必须是普通文件，ZIP 总大小不超过 1.1 GB。
- EOCD 必须位于文件末尾，不接受多磁盘或带注释归档。
- Local Header 与 Central Directory 的名称、大小、CRC 和偏移必须一致。
- 条目必须为未加密 STORE 数据，不接受压缩内容或 data descriptor。
- 文件名不能包含路径、反斜杠或隐藏名前缀。
- 每个条目使用 256 KB 分块，同时计算 CRC32、SHA-256 和五字节文件头。

交付包进一步限定为最多两个条目，且清单必须是
`PaperPath-delivery-receipt.json`。验证只读取外部 URL，不将 PDF 解压或保存
到 PaperPath 沙盒。

### 三层结论

1. **包完整性**：ZIP 结构、目录、CRC、PDF 头、字节数和 SHA-256。
2. **Receipt 签名**：规范化 V1 清单与 Ed25519 公钥、Key ID、签名字节。
3. **签名者信任**：本机身份、用户已登记签名者、未知签名者或无效来源。

“签名有效但签名者未知”不会被显示为损坏，也不会被显示为可信身份。用户必须
通过其他渠道核对 Key ID，确认后才能将该公钥加入本机可信列表。包完整性失败
时，信任操作不可用。

### 体验路径

- Outputs 首屏将“验证交付包”与“验证并分享”“Office 生产”并列。
- 首页“+”菜单保留全局入口，空资料库也可使用。
- 验证期间底部显示本机读取进度、已处理字节和停止按钮。
- 结果页先给结论，再依次展示完整性、来源、签名 Receipt 和交付检查。
- SHA-256 显示完整 64 位并支持文本选择；发生不匹配时同时显示实际值。
- 未知签名者的“信任”动作增加确认提示，不以一次点击建立长期信任。

## 竞品对照

### PDF Expert

PDF Expert 官方 iOS 页面重点是填写、手写签名、一次性签名、扁平副本和快速
分享。本轮没有在其公开 iOS 能力页发现与 PaperPath 自有 ZIP + Receipt
收件验证相同的流程。PDF Expert 在 Apple Pencil、阅读和编辑成熟度上仍更强。

### Adobe Acrobat

Acrobat 的数字签名验证覆盖证书真实性、证书信任链、撤销状态、时间戳和 PDF
签后完整性；Acrobat Sign 还提供参与者和服务端审计。这些身份与法律能力明显
强于 PaperPath，本轮不声称替代。

PaperPath 的不同价值是无需账号或上传，在 iPhone/iPad 上直接验证自有交付包
中“Receipt 所指的 PDF 是否就是当前收到的字节”，并展示本机信任关系。

### PDFgear

PDFgear 2026 年官方资料说明其支持查看 PDF 数字签名状态、证书与文档完整性，
但 iOS 指南主要列出阅读、编辑、表单、签名、转换和 AI。PaperPath 不宣称
证书验证能力领先；V74 的优势限定为 PaperPath Receipt 包的原地流式验证、
结构门禁和逐字节绑定。

来源（检索日期：2026-08-22）：

- [PDF Expert iOS signing and sharing](https://pdfexpert.com/ios/features/pdf-sign-ios)
- [PDF Expert iOS features](https://pdfexpert.com/ios/features)
- [Adobe: Validating digital signatures](https://learn.adobe.com/au/acrobat/current/validating-digital-signatures.html)
- [Adobe Acrobat Sign 2026 release notes](https://helpx.adobe.com/sign/archive/release-notes/2026.html)
- [PDFgear: Verify a PDF signature](https://www.pdfgear.com/sign-pdf/how-to-validate-digital-signatures.htm)
- [PDFgear for iOS guide](https://www.pdfgear.com/ios-user-guide/intro-to-pdfgear-ios.htm)

## 工程验证

编译命令：

```text
xcodebuild -quiet -project PaperPath.xcodeproj -scheme PaperPath \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

当前结果：

- 主 App Release Simulator `arm64 + x86_64` 编译通过。
- App 内嵌 Share Extension `arm64 + x86_64` 编译通过。
- 独立 Share Extension `arm64 + x86_64` 编译通过。
- 全量测试执行 182 项：180 项首次通过，1 项真机限定跳过；唯一 UI 失败由
  当时仅剩约 181 MB 磁盘空间导致新 PDF 无法写入，释放测试附件后该用例
  单独重跑通过。因此 181 项可运行测试全部通过。
- `Localizable.strings`、Info plist、重复键和 `git diff --check` 通过。
- 未执行独立截图基线回归或真机性能测量。

## 修改文件

V74 直接涉及：

- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Models/DocumentModels.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `PaperPath/Services/DOCXExportService.swift`
- `PaperPath/Services/DocumentStore.swift`
- `PaperPath/Views/LibraryView.swift`
- `docs/COMPETITIVE_BENCHMARK_2026_ZH.md`

工作区同时保留 V72/V73 尚未提交的改动，本轮没有回退、覆盖或格式化它们。

## 当前胜负线与风险

V74 可以支持以下限定结论：

> 在 PaperPath 自有可信交付包的移动端接收场景中，用户无需账号、上传、解压
> 或手工比对，即可在本机完成结构、字节、Receipt 签名与本地信任验证。

仍不能支持“产品整体完全超过竞品”的结论：

- PaperPath 不验证 X.509 证书链、撤销状态、可信时间戳或法律身份。
- 不支持任意第三方 ZIP 或任意 PDF 数字签名验证。
- 当前不从交付包中提取或导入 PDF，这是刻意的只读安全边界。
- 未执行真机大文件耗时、峰值内存、能耗和 Files/iCloud Provider 稳定性测试。
- 未执行 VoiceOver、最大 Dynamic Type 和多窗口截图回归。
