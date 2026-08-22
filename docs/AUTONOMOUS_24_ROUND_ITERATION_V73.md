# PaperPath V73：签名可信交付包

## 本轮目标

V72 已经把 Delivery Receipt 与本地版本里程碑连成精确的双向证据链。本轮继续
对照 PDF Expert、Adobe Acrobat 和 PDFgear，处理链路末端仍然存在的体验断点：

> 用户可以分享 PDF，也可以在 App 内查看 Receipt，但无法把两者作为一个不会
> 混淆、可独立携带的交付单元交给收件人。

V73 在 Receipt 页面提供双路径分享：快速分享可读名称的 PDF，或生成同时包含
精确 PDF 与 Ed25519 签名验证清单的 ZIP。所有核验、签名和打包都在本机完成，
不新增账号、网络上传或第三方依赖。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 复核 V72、持续迭代约束和脏工作区 | 保留已有证据链，不重复开发 |
| 2 | 复查 Receipt、版本、分享与临时文件路径 | 将改动限定在真实交付断点 |
| 3 | 核验 PDF Expert、Acrobat 与 PDFgear 的公开能力 | 用事实确定竞品边界 |
| 4 | 将分享明确拆为 PDF 与 PDF + Receipt 两种结果 | 快速需求和审计需求互不干扰 |
| 5 | 单 PDF 分享改用用户可读文件名副本 | 不再暴露沙盒 UUID 文件名 |
| 6 | 定义 `PaperPath PDF Delivery Package V1` | 外部交付结构稳定且可演进 |
| 7 | 清单绑定 PDF 文件名、字节数、页数和完整 SHA-256 | 收件文件与凭证可精确对应 |
| 8 | 清单绑定 Receipt ID、操作、检查时间与修订 ID | 保留核验来源和工作副本身份 |
| 9 | 清单保留页数、渲染、空白页、批注、文本层、元数据与加密结论 | 核验结果可机读 |
| 10 | 排除 OCR 文本、提取正文、私有备注、源路径和源文件名 | 证据包不额外扩散文档内容 |
| 11 | 清单限制单文件 1 GB、页数 10,000、检查项 64 项和字段长度 | 损坏或恶意状态不能无限放大 |
| 12 | 校验文件名、页数语义、字节数、指纹和检查项唯一性 | 非法清单无法被签名 |
| 13 | 打包前重新读取真实文件大小 | 索引与磁盘内容不一致时失败关闭 |
| 14 | 以 4 MB 缓冲流式重算 SHA-256 | 不把完整 PDF 装入内存 |
| 15 | SHA-256 同时匹配 Receipt 与当前内容指纹 | 过期凭证不能包装新内容 |
| 16 | 使用设备本地 Ed25519 身份签署规范化清单 | 清单被改动后可被密码学识别 |
| 17 | 私钥继续存于 ThisDeviceOnly Keychain | 私钥不随备份离开本机 |
| 18 | Receipt 页面显示短 Key ID | 用户可在分享前识别签名身份 |
| 19 | 复用流式 ZIP，将 PDF 与清单放入同一交付包 | 避免两个附件错配 |
| 20 | ZIP CRC 与复制复用同一打开文件句柄并校验实际字节数 | 原子替换或截断不会静默生成错误归档 |
| 21 | SHA-256、ZIP CRC、ZIP 写入映射为连续进度 | 大文件处理不再只有无期限等待 |
| 22 | 打包支持停止并传播到哈希和归档循环 | 用户可中止长任务 |
| 23 | 文档独占令牌、修订复核、磁盘预算、完整文件保护和失败清理闭环 | 并发修改、空间不足和中断均安全退出 |
| 24 | 区分两类准备状态，补齐触觉、VoiceOver 标识、简中和双架构门禁 | 分享动作状态清晰且发布基线完整 |

## 核心实现

### 交付包结构

ZIP 中只包含两个顶层条目：

1. 使用用户可读安全名称的 PDF。
2. `PaperPath-delivery-receipt.json`。

JSON 外层包含清单与签名。清单记录完整 SHA-256、字节数、页数、Receipt ID、
操作类型、检查结果和内容修订 ID；签名区记录 `Ed25519`、Key ID、公钥和签名。
签名输入使用 sorted keys 与 ISO-8601 日期编码的规范化清单。

设备签名用于证明“清单由持有对应私钥的 PaperPath 本地身份生成且之后未被
修改”。它不是数字证书签名、参与者身份认证或法律签署证明。

### 失败关闭

生成交付包必须同时满足：

- Receipt 已通过且仍匹配当前内容修订。
- 磁盘文件是普通文件，大小与 Receipt 一致且不超过 1 GB。
- 重新计算的 SHA-256 同时匹配 Receipt 和当前索引指纹。
- 清单页数、字节数、检查项和修订关系结构有效。
- 打包期间当前修订和 Receipt 关系没有改变。
- ZIP 每个条目的 CRC 与复制使用同一打开文件句柄，两个阶段实际字节数均与
  预检一致。

任一条件失败都会删除临时目录，不生成可分享结果。

### 性能与生命周期

- SHA-256 使用 4 MB 缓冲，ZIP 使用 256 KB 分块，不读取完整 PDF 或 ZIP。
- 归档沿用已有无压缩流式 ZIP 服务，不增加第三方依赖。
- 进度分为 SHA-256 核验、CRC 和归档写入三个阶段。
- 整个任务持有文档独占令牌，支持取消传播。
- 临时目录使用完整文件保护并排除备份。
- 分享 Sheet 关闭、页面退出、取消、失败和下次启动都会清理临时文件。
- 本轮只完成实现级性能收敛，没有真机耗时、峰值内存或能耗数据。

## 体验结果

- `Share verified PDF` 保持最快的单文件路径。
- `Share PDF + Receipt` 是清晰的次级动作，不增加默认路径认知成本。
- 打包行展示用途与设备签名 Key ID；PDF 准备和 ZIP 打包状态不会互相冒充。
- 长任务展示字节进度和停止动作。
- 成功准备分享时提供系统触觉反馈。
- 所有新增可见文案均有简体中文资源；正文使用 Dynamic Type 语义字号并允许
  多行，动作带稳定 Accessibility identifier。

## 竞品对照

### PDF Expert

PDF Expert 的公开能力继续体现成熟的 Apple 平台阅读、编辑、批注、表单、
扫描、转换和订阅体系。本轮不主张 PaperPath 的编辑工具总量超过 PDF Expert。

在本轮检索的公开 iOS 能力资料中，没有发现与“写后重开验证 + 完整 SHA-256
Receipt + 设备本地签名 + PDF/凭证单包交付”等价的说明。PaperPath 在这个
限定交付闭环中的证据表达更完整。

### Adobe Acrobat

Acrobat 强于跨平台云协作、AI、企业管理和 Acrobat Sign 的参与者身份及服务端
审计。PaperPath 不替代这些能力。

PaperPath 的差异是个人本地工作流：无需账号或上传 PDF，即可把已核验的精确
文件和签名清单作为一个 ZIP 交付。对不希望引入云端处理的合同、票据和审批
材料，这条路径更短，数据边界也更明确。

### PDFgear

PDFgear 继续以免费编辑、转换、表单、签名和 AI 交互形成高功能密度。
PaperPath 不在免费工具数量或 AI 问答上宣称领先；V73 的优势集中在原件隔离、
写后验证、失败关闭以及可携带的本地证据。

参考（检索日期：2026-08-22）：

- [PDF Expert Pricing](https://pdfexpert.com/pricing)
- [PDF Expert for Business](https://pdfexpert.com/business)
- [Adobe Acrobat Reader](https://www.adobe.com/acrobat/pdf-reader.html)
- [Adobe Acrobat mobile subscriptions](https://helpx.adobe.com/acrobat/mobile/subscription-refunds/about-subscriptions.html)
- [PDFgear](https://www.pdfgear.com/)
- [PDFgear for iOS](https://www.pdfgear.com/pdfgear-for-ios/)

## 工程验证

执行：

```text
xcodebuild -quiet -project PaperPath.xcodeproj -scheme PaperPath \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/PaperPath-V73-DerivedData \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build
```

结果：

- 主 App：`arm64 + x86_64` 通过。
- 独立 Share Extension：`arm64 + x86_64` 通过。
- App 内嵌 Share Extension：`arm64 + x86_64` 通过。
- `Localizable.strings`、两个 Info plist 和重复键检查通过。
- `git diff --check` 通过。
- 按本轮约束未运行单元测试、UI 测试或截图回归。

## 修改文件

V73 直接涉及：

- `PaperPath/App/PaperPathModel.swift`
- `PaperPath/Models/DocumentModels.swift`
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
- `PaperPath/Services/DOCXExportService.swift`
- `PaperPath/Services/DocumentStore.swift`
- `PaperPath/Views/DeliveryReceiptView.swift`
- `docs/COMPETITIVE_BENCHMARK_2026_ZH.md`

工作区同时保留 V72 尚未提交的代码、测试与文档改动；本轮没有回退或覆盖。

## 当前胜负线与风险

V73 可以支持以下限定结论：

> 在无账号、本机生成可信输出并将精确 PDF 与可机读签名证据一起交付的个人
> 工作流中，PaperPath 形成了比三款对标产品公开资料更完整的一体化闭环。

仍不能支持“产品整体完全超过竞品”的结论：

- Acrobat 的企业签署身份、服务端审计和协作生态仍更强。
- PDF Expert 的成熟编辑、阅读和 Apple Pencil 体验仍需真机长期对比。
- PDFgear 的免费能力广度和 AI 交互仍更有吸引力。
- PaperPath 尚未提供面向收件人的独立交付包导入验证界面。
- 高分辨率大文件的耗时、峰值内存和能耗仍需真机量化。
