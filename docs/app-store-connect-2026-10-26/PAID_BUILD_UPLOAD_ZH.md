# PaperPath 付费下载候选版

2026-10-26，版本 **1.1.0 (6)**，Apple App ID **6827073389**，Bundle ID `com.monoware.paperpath`。

## 已完成

- 当前工作区开始时的用户修改已复制到独立工作树，再迁移为付费下载。未改动仍在进行完整发布测试的主目录 App 源码。
- 删除 StoreKit 商品查询、购买、恢复购买、交易监听和 IAP 状态刷新。已付费下载即可使用全部工具，包含连续可信输出和批量交付。
- 移除设置中的付费墙入口，改为全部工具已包含。移除首次免费和按次数阻断逻辑；旧缓存为未解锁、旧试用次数已用完也不会阻断。
- 更新应用内隐私收费说明和中文字符串，候选构建号递增为 6。
- 功能覆盖契约通过，发布门禁自身 9 项测试通过。收费与发布体验专项 **15 项通过、0 失败、0 跳过**，包括连续两次输出、两份文件批量输出、原件不变、无交易记录重启、设置无购买入口。
- arm64 Release 自动签名归档通过，App Store 导出通过。xcodebuild 上传日志明确记录 `Upload succeeded`，Apple 已接收并开始处理构建。

## 构建证据

- 归档：`.artifacts/PaperPath-1.1.0-6.xcarchive`
- IPA：`.artifacts/AppStoreExport/PaperPath.ipa`
- IPA SHA-256：`a7ab343ae4b0eb822b39e26e913f32eb966fd92f7fffeb6191bd1a34e750f3ed`
- 日志：`.artifacts/paid-archive.log`、`paid-export.log`、`paid-upload.log`
- 专项测试：`.artifacts/paid-access-tests.xcresult` 和 `paid-access-tests.log`
- 测试实际截图：`.artifacts/paid-test-screens/`

## 发布边界

此次上传构建用于 Connect/TestFlight 处理，不代表审核通过或已公开发布。没有提交 App Review。专项测试不是完整发行回归，也不能替代相机、文件保护、签名、分享扩展和低版本系统真机验证。

主目录另有正在进行的完整回归和后续修复；本候选构建基于隔离时的源码快照。继续准备正式上架时，应汇合最终修复后增加构建号重新归档。独立工作树保留迁移源代码，未自动覆盖主目录。

商店中文配图目前仍为中文标题配英文实际界面，需要最终构建中文版重截。正式域名部署、隐私主体、审核联系人、隐私与年龄问卷及销售地区仍需完成并核实。
