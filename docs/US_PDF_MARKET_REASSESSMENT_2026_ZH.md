# PaperPath 美区 PDF 市场复评

更新日期：2026 年 8 月 16 日
市场能力基线：PaperPath R212
定位实施：PaperPath R191

## 1. 结论

美区 PDF App 不是一个缺工具的市场，而是一个高度拥挤、头部收入集中、
长尾严重同质化的成熟市场。

- Apple Search API 对 `PDF editor`、`PDF reader`、`PDF scanner` 和
  `PDF converter` 四个关键词分别返回约 181–186 个结果。
- 四组结果合并后有 575 个不同 App，其中 547 个标题直接包含 PDF。
- 102 个 PDF 标题 App 已有至少 1,000 条美区评分，43 个超过 10,000 条，
  19 个超过 50,000 条。
- 头部产品确实赚钱，但收入高度集中。Acrobat、CamScanner 和 PDF Expert
  三款产品占本报告样本月收入约 98%。
- 免费全能型 PDFgear 有约 9 万月下载，但 App Store 月收入低于
  US$5,000，证明“功能多”本身不是付费理由。

PaperPath 不能以“又一个全能 PDF 编辑器”进入市场。这个位置已经被
Acrobat、PDF Expert、PDFgear、Foxit 和 PDFelement 占满。

PaperPath 当前能够成立的产品定义是：

> 在 iPhone 和 iPad 上私密完成重要 PDF，保留原件，并在分享前重新打开、
> 检查和验证输出副本。

在这个范围内，PaperPath 已经形成真实、可防守的产品差异；在完整 PDF
编辑器总量、全球化、真机证据和市场信任上，仍未超过成熟竞品。

## 2. 数据口径

### 2.1 可直接核验

- 美区 App Store 的名称、评分、评分量、公开价格、IAP 档位和官方功能描述。
- Apple Search API 在 2026 年 8 月 15 日返回的搜索结果。
- PaperPath 当前源码、测试记录、Privacy Manifest 和迭代记录。

### 2.2 只能作为估算

- 下载和收入采用 Sensor Tower 免费公开页的 `Worldwide · Last Month`
  iOS 估算。
- URL 虽使用 `country=US`，免费页公开的下载和收入 KPI 仍是全球口径，
  不能写成美区下载或美区收入。
- 厂商未公开 App 级利润、获客成本、退款、团队成本和 Web/企业收入，
  因此本报告只能判断消费流水规模，不能证明净利润。
- 月度估算按当前值乘以 12 仅用于理解量级，不是全年预测。

## 3. 代表产品价格、下载与收入

| 产品 | 美区公开价格 | 美区评分量 | 全球 iOS 月下载估算 | 全球 iOS 月收入估算 | 年化流水量级 |
|---|---|---:|---:|---:|---:|
| CamScanner | US$4.99–9.99/月；US$49.99–59.99/年 | 约 186 万 | 约 300 万 | 约 US$800 万 | 约 US$9,600 万 |
| Adobe Acrobat | US$12.99/月；US$69.99/年；AI US$6.99/月 | 约 64.2 万 | 约 100 万 | 约 US$900 万 | 约 US$1.08 亿 |
| PDF Expert | US$9.99/月；US$49.99 或 79.99/年；Basic US$9.99 | 约 21.6 万 | 约 10 万 | 约 US$100 万 | 约 US$1,200 万 |
| iLovePDF | US$5.49/月；US$44.99/年 | 约 5.1 万 | 约 20 万 | 约 US$20 万 | 约 US$240 万 |
| PDFelement | US$6.99/月；US$29.99/年；US$39.99 买断 | 约 7,500 | 约 2 万 | 约 US$7 万 | 约 US$84 万 |
| GoodReader | US$5.99 下载；Pro US$2.99/月、US$17.99/年或 US$79.99 买断 | 约 1.4 万 | < 5,000 | 约 US$3 万 | 约 US$36 万 |
| Smallpdf | US$7.99–14.99/月；US$49.99–119.99/年 | 约 6,900 | 约 9,000 | 约 US$3 万 | 约 US$36 万 |
| Xodo | US$11.99/月；US$39.99–107.99/年 | 约 1,700 | 约 1 万 | 约 US$2 万 | 约 US$24 万 |
| Foxit | US$6.99/月；US$39.99/年；Editor+ US$139.99/年 | 约 4,800 | 约 9,000 | 约 US$2 万 | 约 US$24 万 |
| PDFgear | 完全免费，无 IAP | 约 8,300 | 约 9 万 | < US$5,000 | < US$6 万 |

### 商业判断

1. Acrobat 和 CamScanner 证明 PDF 阅读、编辑、扫描和 OCR 都是强付费需求。
2. PDF Expert 以远低于 Acrobat 的新增下载维持约 US$100 万月收入，说明
   Apple 平台的专业体验、留存和订阅存量比单月下载更重要。
3. iLovePDF 的下载高于 PDF Expert，但收入只有约五分之一，说明 Web 品牌
   能带来流量，不必然带来同等移动端付费深度。
4. PDFgear 证明免费功能可以快速获客，同时把普通编辑、签名和页面工具的
   市场价格压到接近零。
5. 中腰部 PDF App 可以产生 US$2 万–7 万月流水，但很难仅靠工具数量进入
   头部。
6. App 级净利润无法从公开数据判断；Acrobat、PDF Expert 和 CamScanner
   的流水足以证明商业成立，其他产品只能判断有收入，不能判断利润率。

### PDF Expert 为什么能卖到 US$49.99 以上

高价并不是因为工具按钮更多，而是因为用户相信它能长期处理重要文件：

1. 原文、图片和链接编辑成熟，复杂文档的临时修改成功率高。
2. 阅读、批注、Apple Pencil、表单、签名、OCR 和 Office 转换形成高频闭环。
3. iPhone、iPad 和 Mac 之间连续工作，覆盖个人专业用户的多设备成本。
4. 多年品牌、用户量、兼容性样本和持续更新降低了“改坏文件”的心理风险。
5. 订阅还承担跨设备能力、兼容维护和支持成本，不只是一次性本地计算。

PaperPath 可以在不做账号、团队协作和服务端 AI 的前提下覆盖大多数本地专业
任务，并在原件保护、逐页变化和分享前验证上做得更深；但不能把这种子赛道领先
写成已经拥有 PDF Expert 的品牌、跨设备连续性和长期兼容信任。

## 4. 市场真正分成五类

| 类型 | 代表产品 | 用户购买理由 | PaperPath 是否应直接竞争 |
|---|---|---|---|
| 企业完整套件 | Acrobat、Foxit | 兼容性、Office、协作、证书、品牌 | 否 |
| Apple 专业编辑器 | PDF Expert | 原生体验、编辑、阅读、Pencil | 部分 |
| 免费全能工具 | PDFgear | 免费、功能密度 | 否 |
| Web 服务延伸 | iLovePDF、Smallpdf | 转换、压缩、跨端服务 | 否 |
| 扫描入口 | CamScanner | 高频扫描、OCR、归档和分享 | 只竞争私密扫描与交付 |

PaperPath 应建立第六类：

| 类型 | 产品 | 用户购买理由 |
|---|---|---|
| 私密可信交付 | PaperPath | 本地完成、原件保留、建议可解释、输出重新验证 |

## 5. 功能对比

符号：`●` 明确成熟，`◐` 部分支持或范围受限，`—` 未见明确能力或主动不做。

| 能力 | PaperPath R212 | Acrobat | PDF Expert | PDFgear | Xodo | Foxit / PDFelement | iLovePDF / Smallpdf |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 阅读、搜索、目录、书签 | ● | ● | ● | ● | ● | ● | ● |
| 专业批注与 Pencil | ● | ● | ● | ● | ● | ● | ◐ |
| 任意原文、图片、链接编辑 | ◐ | ● | ● | ● | ◐ | ● | ◐ |
| 页面整理、拆分、合并 | ● | ● | ● | ● | ● | ● | ● |
| 表单填写与签名 | ● | ● | ● | ● | ● | ● | ● |
| AcroForm 字段创建 | ● | ● | ● | ◐ | ● | ● | ◐ |
| AcroForm 标准计算、格式与范围校验 | ◐ | ● | ● | ◐ | ◐ | ● | — |
| 扫描增强与 OCR | ● | ● | ● | ● | ● | ● | ● |
| PDF 到 DOCX / XLSX / PPTX / 图片 | ● | ● | ● | ◐ | ● | ● | ● |
| Office 导入、PPT 可编辑重排与双向全格式转换 | — | ● | ● | ● | ● | ● | ● |
| 密码、压缩、永久脱敏 | ● | ● | ● | ◐ | ● | ● | ● |
| 图层、测量、证书签名、音频批注 | — | ● | ● | ◐ | ● | ● | — |
| 云盘、跨平台、在线协作 | ◐ | ● | ● | ◐ | ● | ● | ● |
| AI 问答、摘要和翻译 | — | ● | ● | ◐ | — | ● | — |
| 默认私有工作副本、原件不覆盖 | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ◐ |
| 输出重新打开和逐页验证 | ● | — | — | — | — | — | ◐ |
| 本地版本逐页变化对比 | ● | ● | ◐ | ◐ | ◐ | ● | ◐ |
| SHA-256 Receipt 与失效检测 | ● | — | — | — | — | — | — |
| 批量逐份预检、失败隔离和定向重试 | ● | ◐ | ◐ | ◐ | ● | ◐ | ● |

### 不能夸大的地方

- PaperPath 的原文和图片编辑是经过兼容性阻断的安全子集，不是 Acrobat 或
  PDF Expert 那种任意版式编辑引擎；第二阶段补齐的是连续跨页、溢出说明、
  精确源范围、过期预览复验和可取消提交，不改变这一能力边界。
- PaperPath 可以生成真实 DOCX、XLSX 和逐页高保真 PPTX；PPTX 保留视觉外观
  和可搜索文字，并处理旋转、混合横竖和极端比例，但不冒充可编辑版式重排，
  也不做 Office 到 PDF 双向转换。
- R212 已在写出前验证必需 OOXML 部件、XML、内部 Relationship、Content
  Types 和重复 ZIP 路径，并统一清理 XML 1.0 非法字符；这证明包结构更可靠，
  R213 又在固定 Simulator 由系统 Quick Look 实际渲染三种格式；但 Simulator
  和本机均没有 Microsoft Office、Pages、Numbers 或 Keynote。R214 下载的
  9 份公共复杂语料也全部完成 Simulator 渲染，但六个目标应用的真实打开仍是
  外部门禁，不计为已通过。
- PaperPath 只本地执行已知 Acrobat 标准计算/格式函数；任意 JavaScript、
  XFA 和数字签名继续交给兼容阅读器。
- PaperPath 的 iCloud KVS 只同步轻量状态和 Receipt，不是 PDF 文件云盘。
- PaperPath 没有在线 AI、团队协作、证书签名、工程测量、多层 PDF 或音频批注。

## 6. R181–R212 带来的真实提升

| 新能力 | 市场意义 | 是否形成优势 |
|---|---|---|
| 最多四种 OCR 语言和 50 个自定义词 | 从“有 OCR”提升到可控制、可安全重跑的专业 OCR | 是，尤其适合合同、票据和专有名词 |
| OCR 阅读顺序和低置信度复核 | 用户能回到证据页修正判断 | 是，优于只返回一段文字 |
| 嵌入图片原始流/无损 PNG 导出、去重和回读 | JPEG/JP2 保留原流；Flate、SMask、Form XObject 可无损提取 | 是，补齐专业资源复用能力 |
| 标准计算表单与异常 Office 几何 | 白名单计算、格式和范围校验；DOCX/XLSX/PPTX 保留混合页面方向 | 是，减少合同、报价和长页转换失败 |
| 变化页直达与 OOXML 包级门禁 | 新增页进入修订版、删除页回到基础版；Office 输出前校验部件、关系、Content Types 和 XML | 是，减少审阅跳转成本并提前阻断结构损坏输出 |
| 跨页重排提交边界 | 连续页面、稳定文字锚点、断词与容量检查；过期预览和取消提交 fail closed | 是，安全性和可解释性强于只显示“导出成功” |
| 批注备注、颜色和线宽安全编辑 | 补齐日常复核能力，同时保护 appearance stream | 达到专业基线 |
| 隐私文案与 iCloud KVS 行为对齐 | 避免“完全不上云”的失实宣传 | 是，提升可信度 |
| 首页横向 Hero、首屏 Import / Scan / Merge | 核心入口可见，信息密度达到工具型 App 要求 | 到位 |
| `For your PDFs` 2×2 网格 | 结果路径更早出现，减少首页纵向浪费 | 到位 |
| Verified Output 逐页变化与 Compare Versions | 用户能直接看见像素、文字、页数和几何变化，不再只看到“导出成功” | 是，强化核心定位 |

## 7. PaperPath 已经超越的部分

以下判断有源码和自动化证据支撑，且竞品公开移动端页面未展示同等闭环：

1. 输出不是“写入成功”即结束，而是重新打开、渲染页面、检查异常空白、
   批注、文字层、元数据、加密和文件指纹。
2. 每份可信输出保留 Receipt、源文件血缘和内容版本；输出再次修改后旧凭证
   自动失效。
3. Receipt 自动列出重大变化；独立版本对比在本机解释可见像素、文字层、页数
   和页面几何差异。
4. 多份 PDF 逐份预检、逐份输出、逐份审计；某一份失败不会掩盖或拖垮其他
   已验证结果。
5. 默认使用私有工作副本，源文件不被静默改写；写回 Files 时再次校验源文件
   指纹，外部变化时 fail closed。
6. 文档理解给出置信度、证据页和可执行下一步，不只是通用工具列表或无来源摘要。
7. PDF 字节和提取内容没有 App 自建网络上传路径；Privacy Manifest 声明零跟踪、
   零开发者数据收集，iCloud KVS 只合并受限元数据。

## 8. 还没有做到位的部分

### 发布证据

- VisionKit 相机、Apple Pencil 手感、锁屏文件保护、高分辨率扫描能耗、
  第三方密码兼容和真实 iCloud 账号传播仍未完成真机门禁。
- 当前证据足以证明实现完整，尚不足以证明真实设备上的长期稳定和手感超过
  PDF Expert。

### 全球化

- English、简体中文和跟随系统已完整接入，并支持应用内即时切换。
- 尚未覆盖西班牙语、德语、法语、日语等 PDF 头部市场语言，不能把中英双语
  写成完整全球化。

### 商业化

- 当前源码没有 StoreKit、付费墙或 Full Unlock 实现。
- 没有 App Store 真实转化、留存、退款、崩溃率或用户评价，不能用内部功能分
  替代市场验证。

### 完整编辑能力

- 任意字体、复杂版式、自定义 JavaScript、压缩字段 object stream、XFA、
  数字证书和工程图仍需要成熟商业引擎。
- 这些不是可信交付主线的发布阻塞项，但决定 PaperPath 不能宣传为
  “功能最全”或“全面超过 PDF Expert”。

## 9. 用户为什么选择 PaperPath

### R190 表达的问题

R190 首页品牌副标题是：

> Pro PDF tools, on device

这句话真实，但过于通用。PDFgear、PDF Expert 和大量长尾产品都可以使用类似
表述，它没有解释 PaperPath 为什么值得替换现有工具。

产品内已经出现 `Ready to send`、`Hide private info` 和重新验证能力，方向正确；
但最强价值分散在多个页面，首次看到 App 的用户未必能立刻理解 Receipt 和重新
验证为何重要。

R191 已将副标题改为 `Private PDFs. Verified output.`，并把用户可见的
`Safe Share` 统一为 `Verify & Share` / `Verified Copy`。内部持久化枚举继续使用
`safeShare`，不破坏已有数据兼容性。

### 建议的一句话

> Finish important PDFs privately, then verify the copy before you share it.

中文内部表述：

> 私密完成重要 PDF，并在分享前验证最终副本。

### 完整价值主张

> PaperPath keeps PDF content on your device, preserves the original, guides
> you to the next task, and reopens the finished copy to check it before sharing.

这句话包含四个可证明的理由：

1. PDF 内容留在设备。
2. 原文件默认保留。
3. App 根据文档给出下一步。
4. 输出在分享前被重新打开和检查。

SHA-256、Receipt、错误短码和版本失效属于证明机制，不应成为第一层广告文案。
用户先理解“发出去前真的检查过”，再在详情页看到技术证据。

## 10. 推荐的商店表达

### Subtitle

`Private PDFs, verified output`

### 首组三张截图

1. `Keep sensitive PDFs on device`
2. `Finish the task, not the tool hunt`
3. `Verify the final copy before sharing`

### 后续截图

4. `Preserve the original automatically`
5. `Review low-confidence OCR pages`
6. `Batch-check every PDF separately`
7. `Reopen outputs and keep a receipt`

### 不应使用

- All-in-one PDF editor
- The most powerful PDF app
- Better than Acrobat
- Everything stays on device
- Certified or legally verified PDF

## 11. 价格复评

旧建议的 US$5.99 永久解锁适合作为限时首发价，不适合作为长期价格：

- 它与 GoodReader 的基础下载价相同，但 PaperPath 当前已包含 OCR、DOCX/XLSX、
  批量可信交付和输出审计等更深能力。
- 过低价格会把产品放回普通一次性工具的比较框架，削弱“重要文件可信交付”
  的专业定位。
- 当前没有云端持续成本，不适合首发即采用高价月订阅。

建议：

| 档位 | 价格 | 内容 |
|---|---:|---|
| Free | 免费 | 阅读、导入、基础批注、完整演示和一次真实 Verified Output |
| Launch Lifetime | US$9.99 一次性 | 首发期完整解锁 |
| Regular Lifetime | US$19.99 一次性 | 当前全部本地专业能力 |

在完成真机门禁、兼容性样本和首批真实评价前，不建议上 US$49.99 年订阅。
后续只有在持续提供跨设备能力、专业模板、重大编辑引擎或团队服务时，才重新
评估订阅。

## 12. 最终判断

### 已做到位

- 高频 PDF 基线完整。
- 首页信息密度与功能发现已到位。
- 私密工作副本、逐页变化、可信输出和批量错误归属形成明确差异。
- R181–R212 让 OCR、Office、表单、版本审阅、变化页直达和中英双语达到专业闭环。

### 尚未做到位

- 商店元数据仍需围绕“重要 PDF 分享前验证”统一，而不是铺陈全部工具。
- 真机质量证据、更多市场语言和商业化实现未完成。
- 没有用户评价和留存数据，不能宣布已经获得市场验证。

### 是否超越

- **完整 PDF 工具总量：没有超过 Acrobat、PDF Expert、Foxit 或 PDFelement。**
- **免费功能性价比：无法超过 PDFgear 的零价格。**
- **私密完成与可信交付：已经有明确、可证明的领先路径。**

用户选择 PaperPath 的理由可以讲清楚，而且应该只讲这一件事：

> 当 PDF 很重要、很私密、不能发错时，用 PaperPath 完成它，并确认最终副本
> 真的可以交付。

## 13. 主要来源

### App Store 与 Apple Search API

- [PDF Expert](https://apps.apple.com/us/app/pdf-expert-editor-converter/id743974925)
- [Adobe Acrobat](https://apps.apple.com/us/app/acrobat-reader-pdf-editor/id469337564)
- [PDFgear](https://apps.apple.com/us/app/pdf-gear-pdf-editor-reader/id6465897558)
- [iLovePDF](https://apps.apple.com/us/app/ilovepdf-pdf-editor-scan/id1207332399)
- [Xodo](https://apps.apple.com/us/app/pdf-reader-editor-xodo/id805075929)
- [Smallpdf](https://apps.apple.com/us/app/smallpdf-scanner-pdf-editor/id1485259500)
- [Foxit](https://apps.apple.com/us/app/foxit-pdf-editor/id507040546)
- [PDFelement](https://apps.apple.com/us/app/pdfelement-pdf-editor-viewer/id1516765045)
- [GoodReader](https://apps.apple.com/us/app/goodreader-pdf-editor-viewer/id777310222)

### Sensor Tower 免费公开页

- [PDF Expert](https://app.sensortower.com/overview/743974925?country=US)
- [Adobe Acrobat](https://app.sensortower.com/overview/469337564?country=US)
- [PDFgear](https://app.sensortower.com/overview/6465897558?country=US)
- [iLovePDF](https://app.sensortower.com/overview/1207332399?country=US)
- [Xodo](https://app.sensortower.com/overview/805075929?country=US)
- [Smallpdf](https://app.sensortower.com/overview/1485259500?country=US)
- [Foxit](https://app.sensortower.com/overview/507040546?country=US)
- [PDFelement](https://app.sensortower.com/overview/1516765045?country=US)
- [GoodReader](https://app.sensortower.com/overview/777310222?country=US)
- [CamScanner](https://app.sensortower.com/overview/388627783?country=US)

### 官方功能与价格页

- [PDF Expert Pricing](https://pdfexpert.com/pricing)
- [PDF Expert iOS Features](https://pdfexpert.com/ios/features)
- [Adobe Compare PDFs](https://www.adobe.com/ca/acrobat/features/compare-pdfs.html)
