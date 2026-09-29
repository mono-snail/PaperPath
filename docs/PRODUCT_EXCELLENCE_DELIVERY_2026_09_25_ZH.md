# PaperPath 50 轮产品迭代交付

50 轮已完成。主要落地于 18 个产品 Swift 文件，覆盖操作层级、阅读空间、扫描/OCR、隐私复核和交付；稳定底层经查证保留。证据和边界逐轮记录，不以测试数量代替产品成果。

## 产品方向

围绕三条已有路径打磨：填写签名后交付、隐私复核后交付、整理压缩后交付。PaperPath 的产品表达是“在设备上完成重要文件，保留原件，检查副本后分享”。具体能力、竞争依据和每轮取舍见 [50 轮记录](PRODUCT_EXCELLENCE_50_2026_09_25_ZH.md)。

Apple Preview 已覆盖基础阅读、扫描和签名；PDF Expert、Acrobat 的编辑能力成熟；PDFgear 官方宣传免费。因此，“功能多”或“基础签名”不足以独立构成购买理由。本次重点是操作容易发现、完成过程清楚、分享对象明确。上述定位是产品判断，尚无真实用户留存或付费转化数据支持。

## 用户可见变化

| 场景 | 本轮结果 |
| --- | --- |
| 首次使用 | 第一屏即可试用示例或进入首页；手机说明纵向排列，避免文字被插画挤窄 |
| 文档库 | 导入操作显示文字；继续入口去重；空库不显示无内容的半屏预览；搜索和筛选空态提供直接恢复 |
| 阅读和工具 | 手机压缩模式工具栏；搜索工具时优先显示结果；书签、页码、选中状态补齐朗读上下文 |
| 合并 | 手机先选文件，再调顺序和命名；排序按钮与文件信息分行；零选择时不展示无用统计 |
| 编辑和签名 | 可展开查看完整替换原文；对齐操作适配窄屏；清除/移除按钮扩大触控范围 |
| 扫描 | 保留大幅预览、裁切、旋转、页序和效果；亮度等精细调整按需展开；手机控制区限高并可滚动 |
| OCR | 核对与复制操作提前；待复核模式先显示不确定行；创建可搜索副本固定在底部并说明处理范围 |
| 隐私复核 | 零选择时先引导选择；保留定位后进度；永久脱敏继续明确数量、页数、取消和不可恢复后果 |
| 交付 | 先给结论和警告，再分享；删除主要区域的重复分享/复制哈希入口；原件/输出摘要随后展示，完整技术回执仍可展开 |
| 保护和设置 | 密码输入边界更清楚；默认权限摘要常显，自定义权限按需展开；隐私设置和购买页优先展示核心操作 |

签名缩略图不再在每次界面计算时按原图生成，而按数据与生命周期刷新，输出限制在 174×96 像素内；最终签名输出保持原质量。该数字是缩略图预算，不是进程内存或耗时实测。

## 界面证据

完整图片保存在 `.artifacts/product-excellence-50/final/`。扫描与隐私截图使用现有 DEBUG 示例；用于检查布局，不作为摄像头、OCR 准确率或真实文档内容质量证明。

- [iPad 首页](../.artifacts/product-excellence-50/final/ipad-home-zh.png)
- [iPad 扫描复核](../.artifacts/product-excellence-50/final/ipad-scan-zh.png)
- [iPad 隐私复核](../.artifacts/product-excellence-50/final/ipad-privacy-zh.png)
- [iPad 深色及辅助字号](../.artifacts/product-excellence-50/final/ipad-privacy-dark-accessibility-zh.png)
- [iPad 深色阅读](../.artifacts/product-excellence-50/final/ipad-reader-dark-zh.png)
- [iPad 辅助字号阅读](../.artifacts/product-excellence-50/final/ipad-reader-dark-accessibility-zh.png)
- [iPad 截图总览](../.artifacts/product-excellence-50/final/ipad-overview.jpg)
- [iPhone 截图总览](../.artifacts/product-excellence-50/final/iphone-overview.jpg)
- [iPhone 扫描复核](../.artifacts/product-excellence-50/final/iphone-scan-en.png)
- [iPhone OCR](../.artifacts/product-excellence-50/final/iphone-ocr-en.png)
- [iPhone 保护](../.artifacts/product-excellence-50/final/iphone-protection-en.png)
- [iPhone 合并](../.artifacts/product-excellence-50/final/iphone-merge-en.png)
- [iPhone 交付](../.artifacts/product-excellence-50/final/iphone-delivery-en.png)
- [iPhone 辅助字号查找](../.artifacts/product-excellence-50/final/iphone-find-accessibility-en.png)
- [手机欢迎页前后对照](../.artifacts/product-excellence-50/final/onboarding-before-after.jpg)
- [手机中文首页](../.artifacts/product-excellence-50/final/iphone-home-zh.png)
- [手机中文隐私复核](../.artifacts/product-excellence-50/final/iphone-privacy-zh.png)

## 验收边界

已有页面修改/撤销、扫描输出、签名定位、裁切坐标、隐私选择、取消后禁止迟到提交、永久脱敏定向检查通过。资源解析、本地化唯一键、任务所有权、选择恢复、文件分享及修订隔离门禁通过。

逻辑结果：`/tmp/PaperPathExcellenceFinalLogic.xcresult`；iPad 中文普通及辅助字号阅读结果：`/tmp/PaperPathExcellenceFinalPadUI.xcresult`。iPad 阅读截图保留了打开文档时的短暂状态提示，没有修图隐藏。

手机合并、OCR 复制、密码保护、扫描生成两页 PDF 通过：`/tmp/PaperPathExcellenceFinalPhoneUI.xcresult`。该批次的查找和交付断言未通过：前者将真实可点的底部按钮误判为越界，后者要求 LazyVGrid 屏外内容预先出现在可访问性树中。已修正为滚动到达验证；查找与最终精简后的交付流程均通过，结果为 `/tmp/PaperPathExcellenceFinalFollowupUI.xcresult`。最后两条也实际验证了清除后重新查找、警告分享确认、展开证据、建立检查点和返回关联回执。

最新 Release 构建成功，主 App 和分享扩展均包含 `arm64 + x86_64`；这是模拟器 Release 构建，不是签名的 App Store Archive。隐私清单、Entitlements 和 6074 个本地化键检查通过。构建与定向验证日志已留存于 `.artifacts/product-excellence-50/validation/`。

未修改已有稳定能力的轮次采用源码复核并保留，不能解释为重新执行了全部历史自动化。VisionKit 摄像头、Apple Pencil、完整 VoiceOver 手势和真实 StoreKit 购买仍需发布前真机验证。

## 交付范围

商店中英文文案和八张取景脚本已更新至 [APP_STORE_METADATA.md](APP_STORE_METADATA.md)，未对外发布，价格仍需商业确认。工作区原有未提交修改与删除保持原状；本轮源码基线及差异依据保存在 `.artifacts/product-excellence-50/baseline/`。
