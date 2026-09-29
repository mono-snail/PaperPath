# PaperPath 本轮截图

版本 1.1.0 (4)，iPhone 17 Pro / iPad Pro 13-inch (M5)，iOS 26.3.1 Simulator，常规系统字号。14 张 PNG 来自本轮 XCTest 附件，逐图的原始路径、测试名称、结果包和 SHA-256 保存在 [screenshots.json](screenshots.json)。

[查看总览](overview.jpg)

| 已审阅画面 | 核验结果 |
| --- | --- |
| [iPhone 首页](iphone-home.png) | 导入、扫描、继续任务和文档列表可辨，底部三个入口分层明确 |
| [中文隐私说明](iphone-privacy-zh.png) / [iPad 版本](ipad-privacy-zh.png) | 私有库排除自动设备备份、元数据不备份 PDF、换机前导出均清楚可读 |
| [永久脱敏确认](iphone-redaction-confirm.png) | 明确确认与取消；完成结果和分享分别保留截图 |
| [iPhone 隐私分享](iphone-privacy-share.png) / [iPad 分享弹层](ipad-privacy-share.png) | 系统面板显示实际脱敏副本；双设备打开、关闭并返回结果的测试通过 |
| [iPhone 图形缩放](iphone-shape-resize.png) / [iPad 图形缩放](ipad-shape-resize.png) | 使用实际手柄；自动化要求宽度变化并保持左边缘，随后缩放页面并保存通过 |
| [iPad 绘制缩放](ipad-drawing-zoom.png) | PDF 与笔迹位于统一缩放容器，放大后位置一致 |
| [iPad 横屏阅读](ipad-landscape.png) | 按 EXIF 转正后，侧栏、页签、纸面和底部操作完整可见 |
| [图片导出](iphone-images-share.png) / [文件输出](ipad-files-export.png) | 保留实际系统交接画面；不把仅出现原导出页面视作成功 |

iPad 绘制输入模式在底部系统分段控件内有文字省略，完整模式仍显示在顶部状态区。未发现核心确认、取消、保存按钮被遮挡。

PNG 是未改动的原始附件；横屏 PNG 带 EXIF 方向信息。`overview.jpg` 只按 EXIF 转正、等比缩放和添加说明，没有裁切或改造应用画面。本目录用于验收，不代表已经完成全部商店截图规格和包装。

统计、已修复问题与上架缺口见 [50 轮最终报告](../../docs/LAUNCH_CLOSURE_50_2026_09_27_ZH.md)。
