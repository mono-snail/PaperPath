# PaperPath V66：可移植签名 Delivery 匹配报告

## 本轮目标

V65 能把签名 Delivery Report 与实际 Office 交付文件逐份匹配，但匹配结果仍是会话态。本轮完成版本化 JSON、独立 Ed25519 签名、受保护分享、跨设备导入、结论重算、双签名和双签名者信任展示。

报告仅在用户主动分享时生成；它包含源 PDF 名、交付输出名、候选文件名、大小与 SHA-256，不包含 PDF 或 Office 文件字节。

## 24 轮实际完成

| 轮次 | 实际落地 | 用户价值 |
|---|---|---|
| 1 | 以 V65 脏工作区为基线继续开发 | 不覆盖前序成果 |
| 2 | 审计 Bates 可移植报告模式 | 复用成熟边界而不复制业务含义 |
| 3 | 定义 `paperpath.office-match-report.v1` | 报告格式可识别、可演进 |
| 4 | 内嵌原始签名 Delivery Report | 匹配结论可追溯到交付清单 |
| 5 | 编码全部候选与逐输出结论 | 不丢失 Missing、Ambiguous 或 Extra |
| 6 | 限制编码报告为 4 MB | 导入和分享资源可控 |
| 7 | 验证候选 ID、名称、扩展名、大小和 SHA-256 | 畸形清单失败关闭 |
| 8 | 从候选全集重新推导 Exact | 不信任 JSON 保存的状态文字 |
| 9 | 重新推导 Missing、Ambiguous 和 Metadata mismatch | 异常类型不可被篡改 |
| 10 | 重新推导 Extra 集合和总字节 | 隐藏或伪增候选会失败 |
| 11 | 对规范 JSON 使用 Ed25519 签名 | 报告内容变化可被检测 |
| 12 | 在 `DocumentStore` actor 中完成编码和签名 | 密钥及文件 I/O 不占主线程 |
| 13 | 使用完整文件保护写临时 JSON | 分享前的本地副本受保护 |
| 14 | 分享结束、取消或离开页面后删除临时文件 | 不积累敏感报告 |
| 15 | 分享前披露名称、大小和哈希范围 | 用户明确知道离开设备的数据 |
| 16 | 实时结果页增加自适应分享与重选操作 | 不离开当前任务即可交付 |
| 17 | Office Production 增加匹配报告导入 | 接收方可从 Files 直接复核 |
| 18 | 导入只接受 4 MB 内的常规 JSON 文件 | 拒绝错误类型和超限输入 |
| 19 | 分别验证外层匹配报告和内嵌 Delivery 报告 | 任一签名失效都会显式失败 |
| 20 | 分别解析外层核验者和原交付签名者信任 | 两个身份不会被混为一人 |
| 21 | 复用同一结果页展示导入报告 | 实时与归档结论保持一致 |
| 22 | 无效报告的标题、指标和逐项结果统一使用风险色 | 不让伪造结果保留绿色暗示 |
| 23 | 处理异常文件名、取消、重复分享、Dynamic Type 和 VoiceOver | 边界状态完整 |
| 24 | 完成本地化、静态检查和双目标编译 | 保持发布前工程门槛 |

## 核心变化

### 可重算的签名载荷

- 报告嵌入原始 `PDFOfficeSignedVerificationReport` 和完整 `PDFOfficeExternalMatchReport`。
- 导入时按内嵌清单重新建立允许格式、哈希所有者和候选全集。
- 逐条核对输出条目顺序、候选引用、大小及状态。
- 重新计算 Extra 集合、候选总数和总字节，不能靠修改计数字段通过。
- 控制字符文件名在匹配阶段转换为有界展示名，不影响 SHA-256 证据。

### 双签名与双信任

- 内层 Delivery Report 继续证明交付清单来源和输出哈希。
- 外层 Office Match Report 证明某台设备在指定时间记录了哪些候选和匹配结论。
- 导入界面分别显示两层签名状态、两层签名者信任和外层 Key ID。
- 两层签名都有效但任一签名者未知时，整体使用琥珀色并提示复核签名者。
- 签名有效、身份可信、文件字节匹配仍是三个独立结论。

### 分享与导入

- 实时匹配结果页增加可横排或纵排的 Choose Again 与 Share Signed Report。
- 分享确认明确列出源 PDF 名、输出名、候选名、大小和 SHA-256，声明不包含文件字节。
- 输出写入完整保护临时目录，并在 Share Sheet 关闭或页面退出后清除。
- Office Production 菜单新增 Verify Delivery Match Report。
- 导入报告复用现有高密度结果页，无效报告的已保存结论统一降为风险视觉。

## 修改文件

- `PaperPath/Models/DocumentModels.swift`
  - 匹配模型 Codable 化、版本化 payload、签名封装、结构重算和导入结果。
- `PaperPath/Services/DocumentStore.swift`
  - 报告签发、保护写入、导入、双签名验证和双签名者信任解析。
- `PaperPath/App/PaperPathModel.swift`
  - 签名报告导出和导入验证协调。
- `PaperPath/Views/LibraryView.swift`
  - 分享确认、自适应操作、报告导入和双层验证界面。
- `PaperPath/Resources/zh-Hans.lproj/Localizable.strings`
  - 新增分享、导入、签名者和失败状态中文。
- `README.md`
  - 更新可移植签名 Delivery 匹配报告能力。

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

失败：本机缺少当前 Xcode 所需的 iOS 26.2 platform，无法解析通用 Simulator destination；未进入源码编译。

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
- plist、strings、重复键和 `git diff --check` 检查通过。
- 按快速迭代约束未运行单元测试、UI 测试或截图回归。

## 竞品证据

沿用 V65 于 2026-08-22 查阅的 Adobe Acrobat、Foxit PDF Editor 和 Xodo PDF Studio 官方数字签名资料。这些页面聚焦 PDF 内嵌证书签名和文档完整性验证，未展示用独立本地签名报告携带并重算异构 Office 交付集合匹配结论的相同路径。

这只是对已查阅公开材料的描述，不推断竞品不存在其他未公开能力，也不把 PaperPath 的设备签名表述为证书签名。

## 竞争优势

- 接收方无需原设备、账号或网络，即可验证匹配报告、原始交付报告和全部保存结论。
- 外层核验者与原始交付签名者可以不同，界面会分别展示其密码学状态和本地信任关系。
- 报告无法通过单独修改 `Exact`、计数或 Extra 列表伪造通过状态，因为导入时会重新推导。

## 未验证风险

- 尚未用真实 AirDrop、邮件和第三方文件提供器做跨设备报告往返。
- 接近 4 MB、128 个输出及大量共享哈希的报告尚未专项压力测试。
- 旧版本客户端不会识别 V1 Office Match Report，需要当前或后续兼容版本。
- 最大 Dynamic Type、横屏和多窗口下尚未截图回归。
- 标准 Scheme 仍需安装匹配的 iOS 26.2 platform 后复跑。

## 下一阶段

1. 真机验证 Office Match Report 的 AirDrop、Files、邮件和第三方文件提供器往返。
2. 评估直接验证完整 Office Delivery ZIP 的安全解析与 zip bomb 资源边界。
3. 用版本化报告样本验证未来 schema 的向后兼容策略。
4. 返回扫描替换复核或固定版本容量治理等尚未闭环的高价值核心路径。
