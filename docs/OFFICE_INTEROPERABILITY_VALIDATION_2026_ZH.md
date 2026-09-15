# PaperPath Office / iWork 互操作验证

> 2026-09-14 补充：本页为历史“可打开/可渲染”验证，不是转换质量证明。
> 新增 [公开原稿完整转换对照与发版判断](OFFICE_RELEASE_GATE_2026_09_14_ZH.md)，
> 已确认编号层级、表格结构和图表保留问题。下文历史评分不作为当前发版依据。

更新日期：2026 年 8 月 16 日
固定 Simulator：`2BDDA0A7-5C5A-49DF-B9CB-C11A86B35472`
样本版本：R213

## 1. 验证边界

本轮只使用固定 iOS Simulator，不连接物理 iPhone 或 iPad。

iOS Simulator 不能安装并运行 App Store 发布的 Word、Excel、PowerPoint、
Pages、Numbers 和 Keynote。当前 Mac 也未安装这六个应用。因此本轮把结果分成：

1. Simulator 系统 Office Quick Look 实际解析与渲染。
2. Microsoft Office / iWork 真实应用打开门禁。

两者不能互相替代。

## 2. Simulator 结果

生产导出器从同一份四页混合几何 PDF 生成三个 OOXML 文件。测试只接受
`QLThumbnailRepresentationType.thumbnail`，文件图标回退不算通过。

| 输出 | Simulator 解析器 | 渲染结果 | 状态 |
|---|---|---:|---|
| DOCX | iOS Quick Look | `612 × 792` 页面预览 | 通过 |
| XLSX | iOS Spreadsheet Quick Look | `47 × 35` 已用单元格范围预览 | 通过 |
| PPTX | iOS Quick Look | `720 × 540` 幻灯片预览 | 通过 |

XLSX 的缩略图按首个工作表已用单元格范围裁切，不是通用文件图标。三份输出同时
通过 ZIP CRC、XML、Relationship、Content Types 和必需部件门禁。

定向测试：

```text
PDFCoreServiceRegressionTests/
testOfficeExports_renderInSimulatorQuickLook_BitsUT
```

结果：`1 executed, 0 failures, 1.905s`。

## 3. 公共 Office 语料

R214 从 [Apache POI](https://github.com/apache/poi) 官方测试语料库下载 9 份
Office 2007+ OOXML 文件，总计约 `1.2 MB`：

| 格式 | 样本能力 |
|---|---|
| DOCX × 3 | 多种图片、复杂编号、Unicode 页眉页脚 |
| XLSX × 3 | 条件格式、数据透视表、三个图表 |
| PPTX × 3 | SmartArt、多主题、日文文字 |

语料位于
[`PaperPathTests/Fixtures/OfficeInteropCorpus`](../PaperPathTests/Fixtures/OfficeInteropCorpus)，
并包含 Apache License 2.0、NOTICE、原始下载 URL 和每个文件的 SHA-256。
测试运行时不访问网络。

`testPublicOfficeCorpusRendersInSimulatorQuickLook_BitsUT` 对每份文件执行：

1. SHA-256 来源完整性校验。
2. OOXML ZIP 签名校验；宿主 `unzip -t` 独立验证 CRC 和目录。
3. 固定 Simulator Quick Look `.thumbnail` 渲染。
4. 非空尺寸和 PNG 数据门禁，并保存 9 张预览附件。

结果：`9/9` 文件通过，`1 executed, 0 failures, 5.311s`。视觉抽查确认图片、
编号、Unicode、条件格式表、数据透视表数据、图表数据、SmartArt、主题和日文内容
均被系统解析，而不是文件图标占位。

该语料证明 Simulator 系统解析器可以覆盖更多真实 OOXML 结构。它不是 PaperPath
生成文件在 Microsoft Office 或 iWork 中的替代验证。

## 4. 真实应用矩阵

| 文件 | 目标应用 | 环境探测 | 状态 |
|---|---|---|---|
| DOCX | Microsoft Word | 未安装 | BLOCKED |
| DOCX | Apple Pages | 未安装 | BLOCKED |
| XLSX | Microsoft Excel | 未安装 | BLOCKED |
| XLSX | Apple Numbers | 未安装 | BLOCKED |
| PPTX | Microsoft PowerPoint | 未安装 | BLOCKED |
| PPTX | Apple Keynote | 未安装 | BLOCKED |

`BLOCKED` 只表示当前环境没有目标应用，不表示文件不兼容。安装 macOS 版目标应用
后，可直接使用本轮持久化样本执行打开、警告、分页、方向、字体替换和搜索文字验收，
仍不需要使用物理 iOS 设备。

## 5. 证据

- [DOCX 样本](../.artifacts/office-interoperability/R213-20260816-samples/PaperPath-R213.docx)
- [XLSX 样本](../.artifacts/office-interoperability/R213-20260816-samples/PaperPath-R213.xlsx)
- [PPTX 样本](../.artifacts/office-interoperability/R213-20260816-samples/PaperPath-R213.pptx)
- [DOCX Simulator 预览](../.artifacts/office-interoperability/R213-20260816-samples/PaperPath-R213-docx-preview.png)
- [XLSX Simulator 预览](../.artifacts/office-interoperability/R213-20260816-samples/PaperPath-R213-xlsx-preview.png)
- [PPTX Simulator 预览](../.artifacts/office-interoperability/R213-20260816-samples/PaperPath-R213-pptx-preview.png)
- [XCTest 结果](../.artifacts/office-interoperability/R213-20260816-pass.xcresult)
- [公共语料 XCTest 结果](../.artifacts/office-interoperability/R214-public-corpus-render.xcresult)
- [公共语料 9 张预览](../.artifacts/office-interoperability/R214-public-corpus-previews)

## 6. 评分处理

本轮证明 iOS Simulator 系统解析器可以实际渲染三种输出，但没有完成六个目标应用
的真实打开。因此竞争评分保持 `9.6335`，不因 Quick Look 通过而增加。
