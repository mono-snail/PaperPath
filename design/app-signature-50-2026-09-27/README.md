# PaperPath · 50轮体验打磨截图

2026-09-28 完成。42张原始PNG来自本轮iPhone17 Pro、iPad Pro13-inch(M5)模拟器，系统iOS26.3.1，常规字号。8张JPG拼图仅按比例缩放和排版，没有裁去界面内容。

[50轮结果与发布边界](../../docs/APP_SIGNATURE_50_2026_09_27_ZH.md) · [逐图来源、尺寸及SHA-256](screenshots.json)

## 总览

- [浅色英文](overview-light.jpg)
- [深色中文](overview-dark.jpg)
- [与上一候选版本的视觉对比](before-after.jpg)
- [阅读与工具](review-reader-tools.jpg)
- [iPhone零选、确认、空库与隐藏预览](review-phone.jpg)
- [iPad零选、确认、空库与隐藏预览](review-ipad.jpg)
- [OCR结果与过滤](review-ocr.jpg)
- [触控绘制、缩放与系统分享](review-ink-share.jpg)

## 核心路径原图

| 页面 | iPhone英文浅色 | iPhone中文深色 | iPad英文浅色 | iPad中文深色 |
| --- | --- | --- | --- | --- |
| 首页 | [原图](phone-light-home.png) | [原图](phone-dark-home.png) | [原图](ipad-light-home.png) | [原图](ipad-dark-home.png) |
| 工具 | [原图](phone-light-tools.png) | [原图](phone-dark-tools.png) | [原图](ipad-light-tools.png) | [原图](ipad-dark-tools.png) |
| 阅读 | [原图](phone-light-reader.png) | [原图](phone-dark-reader.png) | [原图](ipad-light-reader.png) | [原图](ipad-dark-reader.png) |
| 隐私零选择 | [原图](phone-light-privacy-zero.png) | [原图](phone-dark-privacy-zero.png) | [原图](ipad-light-privacy-zero.png) | [原图](ipad-dark-privacy-zero.png) |
| 隐私全选 | [原图](phone-light-privacy-review.png) | [原图](phone-dark-privacy-review.png) | [原图](ipad-light-privacy-review.png) | [原图](ipad-dark-privacy-review.png) |
| 不可恢复确认 | [原图](phone-light-confirmation.png) | [原图](phone-dark-confirmation.png) | [原图](ipad-light-confirmation.png) | [原图](ipad-dark-confirmation.png) |
| 真实验证副本 | [原图](phone-light-verified-copy.png) | [原图](phone-dark-verified-copy.png) | [原图](ipad-light-verified-copy.png) | [原图](ipad-dark-verified-copy.png) |

## 补充状态原图

| 状态 | iPhone | iPad |
| --- | --- | --- |
| 绘制与插入图形 | [原图](phone-ink-before.png) | [原图](ipad-ink-before.png) |
| 触控手柄缩放 | [原图](phone-ink-resize.png) | [原图](ipad-ink-resize.png) |
| PDF、笔迹与图形同步缩放 | [原图](phone-ink-zoom.png) | [原图](ipad-ink-zoom.png) |
| 真实副本系统分享 | [原图](phone-privacy-share.png) | [原图](ipad-privacy-share.png) |
| 干净安装后空库 | [原图](phone-empty.png) | [原图](ipad-empty.png) |
| 隐藏文档预览 | [原图](phone-hidden.png) | [原图](ipad-hidden.png) |

OCR：[实际识别结果](phone-ocr.png) · [过滤结果与复制入口](phone-ocr-filtered.png)。

## 来源与验收

38张原图取自本轮XCTest附件，4张空库/隐藏预览原图由`simctl io screenshot`捕获；来源、测试标识、命令证据及像素尺寸均在`screenshots.json`。原始附件与失败尝试保留在`.artifacts/app-signature-50-2026-09-27/`。

浅色隐私和首页使用最终修正版测试结果；绘制界面在后续修正中未改变。完成页通过正常隐私扫描、不可恢复确认和实际脱敏生成，缩略图对应真实输出文件，不是展示专用夹具。系统分享截取于测试打开分享面板之后，未对外发送文件。

已审阅主次层级、首条发现命中区、零选禁用、确认取消、真实文件预览、隐藏预览、阅读面积、笔迹/图形缩放及中英文文案。iPad最终明暗核心旅程开启“减少动态效果”；完成后已恢复并关闭专用模拟器。

前后对比图使用上一批真实截图，样例选择数量和列表排序可能不同，只用于界面比较。此目录用于开发验收，不能替代iOS17/真机验收或正式App Store截图与资料检查。
