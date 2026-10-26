# App Privacy 暂定答案与证据

状态：仅为提交准备，未在 Connect 保存答案。需要在移除内购后的最终归档、依赖清单、实际网络行为及网站支持流程核对后定稿。

| 项目 | 暂定结论 | 证据与限制 |
| --- | --- | --- |
| Tracking | 预计 No | `PaperPath/Resources/PrivacyInfo.xcprivacy` 的 NSPrivacyTracking=false，tracking domains 为空；仍需核实最终依赖和网络行为 |
| Data collection | 候选为 Data Not Collected，暂不确认为最终答案 | 隐私清单 collected types 为空；PDF/文字/签名在本地处理，无 PaperPath 登录。隐私清单不是完整运行审计，也不自动完成商店问卷 |
| 文档、OCR、签名 | 本地内容不因使用相机/OCR就自动成为开发者收集 | 见 `docs/PRIVACY_POLICY_DRAFT.md` 的数据边界、应用内 Privacy & Data；需确认最终无新增上传或第三方处理 |
| iCloud 元数据 | 必须在政策明示，并单独核实问卷归类 | `AppExperience.swift:36` 默认关闭；`Services/PDFMetadataSyncService.swift` 使用 NSUbiquitousKeyValueStore，包含阅读位置、书签、标签、工作流、指纹及回执元数据，不是 PDF 备份。不能只以“可选”推导可免披露，须确认开发者/第三方访问能力及 Apple 当前规则 |
| 诊断与支持 | 不能一概宣称从不收集任何数据 | `AppExperience.swift` 的诊断生成逻辑和现有支持草稿显示由用户选择生成与分享；邮件或支持表单收到的信息另有实际存储和处理流程，需要核实是否符合可选披露全部条件 |
| Purchases | 迁移后由 Apple 处理付费下载 | 当前 StoreKit IAP 尚存；最终应更新政策，不再写内购终身解锁。开发者不得声称获取银行卡信息 |
| 相机、Face ID、通知 | 按实际用途披露权限 | 相机扫描；系统认证用于应用锁；可选到期通知。不要把系统权限等同于开发者获得生物识别模板 |

Apple 以数据是否离开设备并可由开发者或合作方访问、保留来界定收集。可选披露需要满足全部条件；“用户选择发送”本身不足以证明免披露。应对支持表单、邮件附件、诊断和 iCloud 行为分别核实。[Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

## 对外政策发布前必须补齐

- 发布者法定身份、适用联系地址/方式、隐私政策生效日期及控制者信息，不能仅由 MonoWare 品牌名推定。
- 现有公开邮箱 `hello@monoware.app` 的可投递性、隐私请求接收责任、删除/保留流程。
- 支持页 `https://www.monoware.app/support` 的表单提供者、字段、存储地点、保留期限及使用目的；本次未核实后台。
- 网站访问日志/分析、Cookie、托管供应商与应用数据边界分别描述；网站自身可能记录访问，不据此宣称 app 一定收集或不收集。
- 将旧政策的“购买与恢复、终身内购解锁”替换为最终付费下载实际行为，核对应用内隐私文本。

不宣传“全部数据永不联网”。可以表述“核心 PDF 处理、OCR 与隐私检测在本机完成；可选 iCloud 元数据同步与主动分享有各自的存储边界”。私有文档库不参与自动设备备份的重要提醒应保留。
