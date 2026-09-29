# PaperPath 1.1.0 (4)：提交材料核对

本地准备文件，不表示已提交或已通过审核。正式运行结果以 `LAUNCH_CLOSURE_50_2026_09_27_ZH.md` 为准。

| Apple 要求 | 对应材料或实现 | 提交前放行条件 |
| --- | --- | --- |
| 2.1(a) 完整应用、有效链接和设备稳定性 | 应用回归、Release 构建、设备报告及本轮截图 | 最终签名归档可安装，必要的真机路径完成；网址不能是空页或占位符 |
| 2.1(b)、3.1.1 可用的内购和恢复购买 | `com.monoware.paperpath.full-unlock`，设置中的购买与恢复入口 | App Store Connect 产品关联、合同、地区、价格及沙盒购买/恢复均核实；本地 StoreKit 不替代这些条件 |
| 2.3 准确元数据和实际界面截图 | `APP_STORE_METADATA.md`，`APP_REVIEW_NOTES_2026_09_26.md` | 不宣传无损转换、绝对隐私或身份认证；截图符合最终界面与对应设备尺寸 |
| 1.5 支持及联系信息 | `SUPPORT_DRAFT.md` | 填入真实联系人，发布可访问的支持页；应用内也提供可用联系方式 |
| 5.1.1 隐私政策、权限与数据处理说明 | 应用内 Privacy & Data、`PRIVACY_POLICY_DRAFT.md` | 添加发布主体、有效联系方式、生效日期和公开隐私 URL，复核商店隐私问卷 |
| Required Reason API 隐私清单 | 主应用与分享扩展的 `PrivacyInfo.xcprivacy` | 从最终包确认清单存在且声明用途符合实际调用，不仅检查源码文件 |
| 出口合规与销售地区信息 | 最终包和商店问卷 | 由真实发布主体根据使用的加密能力填写，不能用本地构建成功替代申报 |

## 可复用材料

- 名称、副标题、关键词、中英文描述、更新说明及八张截图取景：`APP_STORE_METADATA.md`。本次重新计数：名称英文 28/30、中文 21/30，副标题英文 30/30、中文 17/30，关键词英文 73/100、中文 43/100。
- 中英文审核路径及内购说明：`APP_REVIEW_NOTES_2026_09_26.md`。
- 中英文隐私正文：`PRIVACY_POLICY_DRAFT.md`，已补充私有库不进入自动设备备份。
- 中英文支持正文：`SUPPORT_DRAFT.md`。
- 竞品定位与表达边界：`LAUNCH_COMPETITIVE_GAPS_2026_09_27_ZH.md`。
- 截图应直接来自本轮或有明确版本来源的模拟器/设备。原图与商店包装图分别标注，未制作的包装图不计入完成数量。

## 尚需外部信息

本次实际生成了 arm64 Release 开发签名归档，并通过主应用/扩展的隐私清单、Entitlements、版本和资源检查。随后本地执行 App Store 导出，因 `com.monoware.paperpath` 与 `.share` 均缺少正式分发描述文件而失败；没有可提交的分发 IPA，也没有上传。日志：`.artifacts/launch-closure-2026-09-27/validation/app-store-local-export.log`。

真实发布主体、支持/隐私联系方式、公开托管 URL、审核联系人，以及 App Store Connect 的合同、税务、收款、销售地区、价格和内购关联。当前工作区不能证明这些信息，本文没有虚构或代填。

无 PaperPath 账户，因此审核不需要演示账号；相机采集、Face ID、跨应用分享及真实商店交易的设备边界需按验收报告处理。最低支持版本的编译设置不等于在 iOS 17 上实际运行过。

## 官方依据

- 审核指南（访问于 2026-09-27/28）：https://developer.apple.com/cn/app-store/review/guidelines/
- 隐私清单 Required Reason API：https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- 商店截图规格：https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications
- App 隐私填写：https://developer.apple.com/app-store/app-privacy-details/

若发布时官方要求已变化，以当时 App Store Connect 和 Apple 最新规则为准。
