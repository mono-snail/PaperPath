# PaperPath App Store Connect 准备包

准备日期：2026-10-26。Connect 条目、双语资料与 US$9.99 定价已保存，1.1.0 (6) 已成功上传；未提交审核，销售地区未设置。当前外部状态见 `CONNECT_STATUS_ZH.md`。以用户确定的 **US$9.99 付费下载、无免费层、无内购、无订阅** 为目标。正文可复制，但只能用于完成收费模式迁移后的构建，不证明当前二进制已符合目标。

## 使用文件

- `en-US.json` / `en-US.txt`：英文商店字段与候选链接。
- `zh-Hans.json` / `zh-Hans.txt`：简体中文商店字段与候选链接。
- `APP_REVIEW_NOTES.txt`：完成付费下载迁移后使用的英文审核备注。
- `ASSET_STORYBOARD.md`：双语截图脚本和交付规格。
- `PRIVACY_ANSWERS_ZH.md`：隐私问卷的代码证据与待核实项。

`docs/APP_STORE_METADATA.md` 已改为本包入口。旧文案归档在 `LEGACY_METADATA_2026_09_26.md`，旧审核备注和隐私/支持草稿仍描述免费加内购模式，勿混用。官网购买段落已同步为付费下载计划。

已制作 12 张双语 iPhone/iPad 展示图和一张社交预览图，见 `design/launch-2026-10-26/store-assets/README.md`。中文标题图当前仍含英文 UI，需最终构建重截；该目录不等于已经上传 Connect。官网 SEO 与上线说明见 `SEO_AND_LAUNCH_ZH.md`。

## 提交前清单

- [ ] **主目录合并事项：移除应用内收费门槛。** 独立发布工作树已完成迁移，并以构建 6 通过专项验证和上传；以下路径描述的是未被覆盖的主目录快照。 `PaperPath/App/AppExperience.swift:144` 仍包含 `com.monoware.paperpath.full-unlock`；同文件 276–280 行仍描述首次免费和终身解锁，`PaperPath/App/PaperPathModel.swift:9108` 仍阻止未购买者进行批量可信输出。`ReleaseExperienceViews.swift` 仍有购买/恢复购买界面。需要实现迁移，以全新安装、无 StoreKit 内购记录的环境验证单份、连续多份、批量可信输出。
- [ ] 清除迁移后的内购、试用、恢复购买文案，更新应用内隐私说明、网站和支持文档的购买段落；审核备注必须与最终构建相符。
- [ ] Account Holder 接受有效 Paid Apps Agreement，完成银行和税务信息。Connect → Pricing and Availability 中，以美国为基准设置 US$9.99，检查生效日期和其他地区自动换算价；不创建免费层、订阅或额外功能解锁 IAP。账户状态和实际价格尚未核实。[Apple：设置价格](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price)、[税务资料](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information/)
- [ ] 核实 Bundle ID `com.monoware.paperpath`、版本和构建。当前工程为 1.1.0 (5)，部署目标 iOS 17.0；最终以签名归档及上传记录为准。首次上架无需 What's New；如果是更新，依据最终变更写更新说明。
- [ ] 主类别建议 Productivity（效率）；次类别可选 Utilities。版权方填真实法定名称，不从 MonoWare 品牌推定。审核联系人姓名、电话和邮箱必须核实，公开支持邮箱不自动等于审核联系人。
- [ ] 核实 `https://paperpath.monoware.app/`、英文页、隐私页和 `https://www.monoware.app/support` 已上线且可访问。网址来自现有网站。`hello@monoware.app` 为现有公开邮箱，投递可用性、法律主体及政策生效日期仍需确认。
- [ ] 完成隐私问卷、年龄分级、内容权利、出口合规与地区信息，依据实际构建声明；本包不代填法律或加密分类。若选择欧盟发行，核实 trader 身份和所需公开资料。
- [ ] 上传真实 iPhone/iPad 界面截图，检查图文与付费构建一致。准备材料不等于已上线。无 Mac 支持宣传；Mac 上架选项待单独验证再决定。
- [ ] 真机复核扫描权限、表单/签名、隐私候选→永久脱敏、OCR 修正、输出回执、Files 导入与分享、断网核心流程、备份提醒、iCloud 开关与删除。导出质量与压缩效果按实际文件检查。
- [ ] 签名归档、上传、选择构建、审核联系人、提交及发布时间另行核实。本次仅准备材料，没有执行这些外部操作。

## 字段与搜索原则

名称和副标题各最多 30 字符；推广文本最多 170；描述最多 4000；关键词最多 **100 UTF-8 字节**。已对本包逐项验证。中文关键词按字节计算，避免把 100 字符误作 100 汉字。描述使用纯文本，不填固定美元价格，避免地区价差。[Apple：应用信息](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)、[版本信息](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)、[产品页建议](https://developer.apple.com/app-store/product-page/)

卖点顺序为「填写签名 → 隐私复核 → 检查分享副本」，本机 OCR 和保留原件为支撑。关键词覆盖真实使用意图，无竞品名、排名保证、无损转换或法律认证。网站 SEO 与商店 ASO 应共享真实卖点，分别优化，不能承诺自然排名。
