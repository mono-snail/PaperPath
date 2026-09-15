# 专业工作流十轮验收

实施说明：[十轮迭代](../../docs/PROFESSIONAL_POLISH_2026_09_15_ZH.md)。
测试设备为专用 iPhone 与 iPad，最终 xcresult 记录 iOS Simulator 26.3.1
（设备列表的 runtime 名为 26.3）；不是相机/Pencil 真机证据。

## 范围与数据

- UI 仅使用独立模拟器中的演示资料、已有 Office 公开样本及隔离扫描样本。
- `UITEST_POLISH_OCR` 创建两页真实位图 PDF，再经生产导入与 Vision OCR；
  不伪造识别结果。仅 DEBUG 有此入口，库在 `PolishOCRFixture`，不使用原资料库。
- 测试含 `UITEST_RESET_DEMO`，只能在上述专用测试设备运行。
- App 与 Share Extension 构建通过；未跑完整 XCTest、性能基准或真机锁屏/多窗口压力。

## 证据分层

| 证据 | 结论 |
| --- | --- |
| `picker-evidence.ndjson` | 1-3 行旧代码文字点击有效，中心空白无 action；4-6 行修复后中心点击完成导航 |
| `PaperPath-Polish-picker-post.log` | 原 iPad 选择器中心点击测试通过 |
| `ipad-final` | Office 输出、OCR、选择器、三种阅读布局全部通过 |
| `iphone-final` | Office、选择器、三种阅读布局通过；OCR 搜索收起工具栏暴露入口缺失，随后修复 |
| `*-verified` 日志 | 收藏/识别局部通过；已恢复模式与自动化菜单假设不一致，不作整轮通过依据 |
| `ipad-complete` / `iphone-complete` | 各 4 条测试 0 失败，阅读测试包含普通/最大字号/中文三个完整路径 |
| `PaperPath-Polish-copy-provenance.log` | 复制保留源页码后，手机真实 OCR 复制回归通过 |
| [手机最终阅读摘要](iphone-reading-finish/summary.json) | 最后图标与中文计数修正后，1 条完整阅读测试通过 |
| [平板最终阅读摘要](ipad-reading-finish/summary.json) | 同一版修正，1 条完整阅读测试通过 |
| `resources.log` | 本地化键唯一及资源语法 |
| `contracts.log` | 分享占用/取消/保护数据/表格值分类/预览修订合同 |
| `usability.log` / `recovery.log` | 文字状态与精确多选/批次选择 |

旧失败日志按轮保留，不以截图替代交互通过。
两个 `reading-finish` 结果均为 1 passed、0 failed、0 skipped；
每条内部包含普通英文、最大辅助字号英文、普通中文三条阅读路径。
它们是 `complete` 四项回归后的最终修正复测，不重复计作新的功能轮次。
包含本机绝对路径的原始构建日志只在本地保留，不进入 Git。

## 最终截图

| 页面 | iPhone | iPad |
| --- | --- | --- |
| 阅读设置 | [中文](final/iphone-reading-settings-zh.png) | [中文](final/ipad-reading-settings-zh.png) |
| 书签与定位 | [中文](final/iphone-navigation-zh.png) | [中文](final/ipad-navigation-zh.png) |
| 专注阅读 | [中文](final/iphone-focus-reader-zh.png) | [中文](final/ipad-focus-reader-zh.png) |
| 页面整理 | [中文](final/iphone-page-organizer-zh.png) | [中文](final/ipad-page-organizer-zh.png) |
| 工具面板 | [中文](final/iphone-tools-zh.png) | [中文](final/ipad-tools-zh.png) |
| 文件选择 | [搜索结果](final/iphone-document-picker.png) | [搜索结果](final/ipad-document-picker.png) |
| 收藏去重 | [截图](final/iphone-favorites.png) | [截图](final/ipad-favorites.png) |
| OCR 筛选复制 | [截图](final/iphone-ocr-filtered-copy.png) | [截图](final/ipad-ocr-filtered-copy.png) |
| 大字号整理 | [截图](final/iphone-page-organizer-accessibility.png) | [截图](final/ipad-page-organizer-accessibility.png) |
| 大字号阅读设置 | [截图](final/iphone-reading-settings-accessibility.png) | [截图](final/ipad-reading-settings-accessibility.png) |

`final` 的 20 张图片全部来自 XCTest 附件，不修图：
阅读相关 14 张更新自 `iphone-reading-finish` / `ipad-reading-finish`，
文件选择、收藏与 OCR 的 6 张保留自对应 `complete`。
附件原名与设备对应关系保留在各目录的 `manifest.json`。
已人工复核最后中文计数与最大字号工具图标，未再出现此前的英文后缀或图标越界。
大字号整理截图是跳到第 2 页后的实际滚动位置，不是顶部完整页面截图。
最终源码摘要在 [source-sha256.txt](source-sha256.txt)，
截图摘要在 [screenshots-sha256.txt](screenshots-sha256.txt)。
资源检查：11 个文件、5,864 个逐文件唯一键通过。

## 能力边界

- 这次新增的是选择、定位、续读、筛选复制和状态完整性，不是原生 Office 对象重建。
- 自动预览大小阈值、超额复制拒绝、源修订改变时不续用位置经过实现检查；
  没有把这些所有极端情况都声称为 UI 自动化实测。
- 专注阅读验证的是页级恢复，不是精确到行或段落的滚动位置。
- OCR 复制依旧本机限定、五分钟到期。操作状态和筛选页入口已验证；
  UI 测试不读取宿主机剪贴板或用户资料。
- 两份最终阅读结果各保留 2 个运行时诊断附件，内容为
  `Adding '_UIReparentingView' as a subview of UIHostingController.view is not supported`。
  xcresult 总结仍为 Passed、testFailures 为空；未据此声称零运行时诊断。
  本轮未定位该诊断根因，附件保留供后续专项排查。
- 运行时调试会话 `picker-row-hit` 保持 OPEN；环境门控 DEBUG 插桩默认不启用。
  不清理之前其他会话的文件，不新增生产网络上传。
- 收尾时两台专用模拟器均以无诊断参数普通启动成功，随后正常关闭模拟器；
  未清除测试资料，未操作其他项目设备。
