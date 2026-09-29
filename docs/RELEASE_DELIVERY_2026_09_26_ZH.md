# PaperPath PDF 1.1.0 (4) 发布交付

本轮聚焦既有功能，逐项记录在 [20 轮执行表](RELEASE_20_2026_09_26_ZH.md)。原有工作区修改与删除均保留；没有上传 App Store Connect。

**当前结论：界面与交互改进已交付，最终构建与开发签名归档通过；尚不具备直接提交上架的全部条件。**

## 用户能直接感知的变化

- 首页：导入、扫描、更多操作更易区分；欢迎页根据已有文档显示“打开我的 PDF”。
- 扫描：复核标题更短，页数、裁切和生成路径保持清楚。
- 隐私复核：显示当前文件名，手机选择范围更紧凑，全选和取消全选降低视觉干扰；定位往返保留进度，永久脱敏仍需确认。
- 密码保护：输入和权限重新分组，长度要求提前解释，正在输入正确前缀时不再过早报错。
- OCR：复制按钮明确页数，解释复制的是命中页面的完整文字；修正英文单复数与空复核文案。
- 购买：商品不可用时可重试；检查待批准状态与重新打开购买页时保留等待状态。
- 设置：隐私与数据说明可离线阅读，购买规则与恢复入口更清楚，版本来自实际 Bundle。
- 分享扩展：重试时保留先前跳过文件的数量，操作按钮允许换行。

## 交付文件

| 产物 | 位置 |
| --- | --- |
| 发布材料压缩包（不含 IPA） | `.artifacts/release-20/PaperPath-1.1.0-4-release-materials.zip` |
| 最终设备归档 | `.artifacts/release-20/PaperPath-1.1.0-4.xcarchive` |
| 原尺寸 RGB 截图 | `.artifacts/release-20/store-screenshots/` |
| 界面总览 | `.artifacts/release-20/final/overview.png` |
| 构建与验证记录 | `.artifacts/release-20/validation/` |
| 本轮前的可恢复基线 | `.artifacts/release-20/baseline/` |
| 双语商店文案 | `docs/APP_STORE_METADATA.md` |
| 双语审核说明 | `docs/APP_REVIEW_NOTES_2026_09_26.md` |
| 双语隐私政策正文草稿 | `docs/PRIVACY_POLICY_DRAFT.md` |
| App Store 导出设置 | `ExportOptions-AppStore.plist` |

截图为真实模拟器界面和虚构样本文档；手机为 1320×2868，iPad 为 2064×2752。文件名与来源、校验值在截图目录的 `manifest.json` 中。它们不包含另外设计的广告标题或设备外框。

## 已通过的核验

- 最新 Debug 编译、Release 模拟器双架构构建，以及 iOS 设备 Release 归档。
- 主 App 与分享扩展均为 1.1.0 (4)，签名验证通过，各自包含隐私清单；发布 App 中没有 `.storekit` 文件。
- 6 项针对性 UI 场景：手机隐私脱敏、OCR 复制、密码保护、扫描复核、设置/版本，以及 iPad 中文辅助字号隐私说明。OCR 文案修正后另行复验通过，没有将重复执行计作新增场景。
- 11 个资源文件、6112 个本地化资源键解析通过；39 条用户旅程的自动化映射门禁通过。这是映射与资源校验，不表示本轮运行了全部测试。
- 手机与 iPad 共 8 张原尺寸 RGB 截图已检查，另保留辅助字号与深色模式的原始证据。
- iPhone 15 Pro Max（iOS 26.6.1 Beta）完成当前 Debug 包安装、冷启动和重启；真机 Golden Path 的表单填写/签名/交付核验、永久脱敏、扫描渲染/OCR、OCR 断点恢复及批处理事务恢复共 5 项全部通过。报告为 `.artifacts/device-validation/golden-path/PaperPath-device-golden-path.json`。

设备归档约 182.67 MiB，包含符号文件，并非商店下载体积。构建检查记录在 `validation/final-build-inspection.json`，源码/资源 SHA-256 在 `validation/source-sha256.json`。本轮未增加应用运行时日志插桩。

## 购买验证的限制

专用 `PaperPathCommerce` scheme 和本地 StoreKit 测试计划已加入工程，用例覆盖价格加载、待批准、重查、关闭重开及批准后解锁。当前模拟器 iOS 26.3.1 的测试未通过：`SKTestSession` 报 `SKInternalErrorDomain Code=3`，系统日志明确显示 `com.monoware.paperpath.uitests.xctrunner is not installed for development`，App 随后连接 Sandbox 且没有可用商品。

这份证据只说明本地交易测试未接通，不能证明真实购买成功或失败。保留失败结果 `/tmp/PaperPathRelease20Commerce.xcresult` 与 `validation/storekit-runtime.log`。Apple 开发者论坛记录了[同类命令行 StoreKit 测试故障](https://developer.apple.com/forums/thread/826971)；其他版本的结论不能直接替代当前环境验证。需在可正常运行 StoreKit Test 的环境及真实 Sandbox/TestFlight 中完成购买核验。

## 提交前的实际阻碍

1. **分发签名配置。** 本机 App Store 导出实际失败：`com.monoware.paperpath` 与 `com.monoware.paperpath.share` 缺少可用分发描述文件。设备开发签名归档不等于可上传 IPA。日志为 `.artifacts/release-20/validation/app-store-export.log`。
2. **真实内购与审核配置。** 需在 App Store Connect 核实 `com.monoware.paperpath.full-unlock` 的非消耗型产品、价格、地区、协议及审核关联；本地 StoreKit 目录不代表线上商品已配置。
3. **公开网址与身份资料。** 隐私政策需加入发布主体、有效联系方式和生效日期并公开托管；商店还需有效支持 URL 与审核联系人。应用内离线说明不能代替商店 URL。
4. **剩余真机边界。** iPhone 核心 PDF、OCR、脱敏与恢复路径已通过真机诊断；真实相机取景与拍摄仍需一次人工操作确认。Apple Pencil 按当前发布范围不再作为验收项；真实 Sandbox/TestFlight 购买仍未验证。

外部配置补齐后，可在 Xcode Organizer 选择最终归档，执行 App Store Connect 分发。也可使用：

```sh
xcodebuild -exportArchive \
  -archivePath .artifacts/release-20/PaperPath-1.1.0-4.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore.plist \
  -exportPath .artifacts/release-20/AppStore
```

此命令仅导出；导出成功后才具备可进一步验证、上传的包。Apple 审核与商店生效时间尚未确定，不能承诺次日已对外可下载。
