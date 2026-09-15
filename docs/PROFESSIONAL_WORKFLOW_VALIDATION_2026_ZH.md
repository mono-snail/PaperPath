# PaperPath 职业工作流仿真验收

更新时间：2026-09-03

## 目的

本验收不以功能清单代替用户任务，而是把美国目标职业常见的输入、约束和交付结果组织成可重复运行的测试。

它能够回答：

- PaperPath 是否能完成一条真实工作的技术链路；
- 原件、页序、敏感内容和最终产物是否满足明确的不变量；
- 用户能否从界面找到关键步骤；
- 当前能力适用于哪一类任务，以及哪些场景不应宣称支持。

它不能替代：

- 真实组织的内部审批、命名和归档规则；
- 各州、法院、客户或公司的具体合规要求；
- 真实用户对价值、价格和长期使用意愿的判断。

## 依据

- 美国法院 CM/ECF 仅接收 PDF，并要求提交者自行处理社会安全号码、出生日期、未成年人姓名和金融账户等个人标识信息：
  <https://www.uscourts.gov/court-records/file-case-cm-ecf/faqs-case-management-electronic-case-files-cm-ecf>
- Federal Rule of Civil Procedure 34 要求电子材料保持通常保存形式，或以合理可用的形式提供：
  <https://www.govinfo.gov/content/pkg/USCODE-2010-title28/html/USCODE-2010-title28-app-federalru-dup1-rule34.htm>
- IRS 要求企业保存收据、账单、发票、付款证明等支持文件，并按年份和收入/费用类型有序保存；审计时发送副本而非原件：
  <https://www.irs.gov/businesses/small-businesses-self-employed/what-kind-of-records-should-i-keep>
- E-SIGN 认可电子记录和电子签名，但仍要求签署意图、当事方接受以及记录可访问和保留：
  <https://www.govinfo.gov/content/pkg/USCODE-2020-title15/html/USCODE-2020-title15-chap96-subchapI-sec7001.htm>

## 仿真角色

### 1. Litigation Paralegal

任务：

1. 保留收到的诉讼材料原件；
2. 对公开提交副本中的个人标识信息做永久脱敏；
3. 合并正文和附件；
4. 为全部页面添加连续、可见、可打印的 Bates 编号；
5. 生成可重开的最终副本和 SHA-256 Receipt。

机器验收：

- 两个原始输入文件逐字节不变；
- 脱敏副本不包含可恢复文本层和个人元数据；
- 合并后页数及顺序正确；
- `ACME-000001...ACME-000004` 每页唯一并可显示、打印；
- 最终文件逐页重开，Receipt 通过且包含 64 位 SHA-256。

适用结论：

- 适合公开提交前的脱敏、较小材料集整理和可追踪交付。
- `Verified Output` 会栅格化并去除整份文本层。要求 searchable PDF、load file、native file 或特定元数据的 eDiscovery production 必须按案件协议另行处理，不能宣称完整支持。

### 2. Bookkeeper / Tax Operations

任务：

1. 扫描三张不同供应商的票据；
2. 在设备上执行英文 OCR；
3. 创建三页可搜索 PDF；
4. 按年月和费用类别归档并记录私有备注；
5. 导出结构有效的 Excel 工作簿；
6. 创建独立的密码保护副本，保留私有工作副本。

机器验收：

- OCR 能识别票据类型、供应商和金额；
- 搜索文本层覆盖全部三页；
- 标签及私有备注持久化；
- XLSX 中所有 XML 和关系引用均有效，并包含金额；
- 密码副本可重开、加密状态通过 Receipt；
- 原始扫描逐字节不变。

适用结论：

- 适合票据归档、检索、汇总前整理和人工复核后的 Excel 导出。
- 当前不是完整记账系统：没有账户科目映射、税类判断、重复报销检测或与 QuickBooks/Xero 的同步。
- 自动化使用的是清晰、高对比度合成票据；热敏纸、折痕、阴影和手写票据仍需真机压力样本。

### 3. Operations Coordinator

任务：

1. 从不可变原件创建工作副本；
2. 填写必填接收人字段；
3. 在指定签名字段内添加手写签名；
4. 合并项目范围附件；
5. 创建去除可编辑注释和个人元数据的最终副本；
6. 重开并验证三页交付物。

机器验收：

- 必填字段和签名字段均被判定为完成；
- 合并后页数及顺序正确；
- 最终副本没有残留注释或个人元数据；
- Receipt 通过并包含 SHA-256；
- 外部原件逐字节不变。

适用结论：

- 适合已经由双方约定接受手写电子签名的普通内部确认和供应商交接。
- PaperPath 的手写签名不是身份认证、数字证书或远程在线公证；不得宣传为身份验证型电子签署或公证服务。

## 自动化位置

职业链路测试位于：

- `PaperPathTests/PaperPathTests.swift`
  - `testProfessionalWorkflow_litigationParalegalProducesRedactedBatesSet`
  - `testProfessionalWorkflow_bookkeeperBuildsSearchableOrganizedAuditPacket`
  - `testProfessionalWorkflow_operationsCoordinatorCompletesSignedHandoff`

相关 UI 到达性由以下测试覆盖：

- `testLibraryAndWorkspaceSmokeFlow`
- `testDocumentFindSearchNavigationAndHistory`
- `testRedactionModeHasStablePrimaryActionAndExplicitExit`
- `testVerifyAndShareShowsOutcomeBeforeTechnicalEvidence`
- `testFormReviewAndFieldPlacementScreens`
- `testInterruptedSignatureResumesAfterRelaunch`

## 2026-09-03 执行结果

执行环境：

- iPhone 16e 模拟器，iOS 26.3.1，arm64；
- 单元及服务集成测试结果：`262 passed / 3 skipped / 0 failed`；
- 本文列出的职业 UI 主链路结果：`6 passed / 0 skipped / 0 failed`；
- 三条职业端到端测试全部通过。

三个跳过项不属于已通过能力：

- 两项 Office 输出的系统 Quick Look 渲染，模拟器服务不可用；
- 一项完整文件保护，必须在锁定的真机上验证。

本轮自动化实际发现并修复了两个会破坏职业任务的问题：

1. 签名任务进入第 2 页后中断，重新启动曾被第 1 页未填字段覆盖。现在仅在原恢复目标完成、消失或修订失效时重建恢复点，跨启动 UI 测试确认继续回到第 2 页签名。
2. 混合选择 Trash 内外记录执行批量永久删除时，曾在报错前删除合法子集。现在提交前完整预检，批量删除保持全有或全无。

这些结果证明受控任务中的转换、恢复和交付链路可执行，不证明所有真实文档格式、设备条件或组织流程均已覆盖。

## 职业适配与上线顺序

### 第一优先：Litigation Paralegal 的窄场景

当前最有辨识度、验证最完整的组合是：

`永久脱敏 -> 合并 -> 连续 Bates -> Verified Output -> SHA-256 Receipt`

建议只定位为“小型材料集的公开提交前准备与可追踪交付”。在完成真实复杂样本、打印和第三方阅读器门禁前，不宣传法院提交保证、完整 eDiscovery、load file 或 native production。

### 第二优先：Operations Coordinator

填表、指定位置手写签名、附件合并、最终副本和中断续办链路成立，适合普通内部确认和供应商交接。产品必须持续明确：手写签名表示用户在文档上留下签名笔迹，不提供签署人身份认证、数字证书或在线公证。

### 第三优先：Bookkeeper / Tax Operations

扫描、OCR、搜索、私有归档、Excel 和密码副本可以辅助票据整理，但尚不足以成为财务系统。缺少真实低质量票据压力样本、会计科目和税类规则、重复检测及 QuickBooks/Xero 对接，因此不应作为首发核心定位。

## 发布判定

当前判定为“受控职业任务可用，真机发布门禁未完成”。

可以据此确定首发产品方向和继续做发布候选版本，但不能仅凭本结果宣称已经适配美国职业环境，也不能用自动化结果推断购买意愿。

正式发布前仍需满足：

1. 全量单元与 UI 测试可编译并通过；
2. iPhone/iPad 真机完成扫描、OCR、Apple Pencil、后台、锁屏和大文件测试；
3. StoreKit 沙盒覆盖购买、恢复、退款与家庭共享；
4. 使用公开但已脱敏的复杂样本验证第三方阅读器、打印和法院/客户上传门户；
5. 产品文案明确区分手写签名、完整性 Receipt 与身份认证。
