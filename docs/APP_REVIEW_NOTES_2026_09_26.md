# App Store review notes — PaperPath PDF 1.1.0 (4)

Draft for App Store Connect. No submission has been made.

## English review notes

PaperPath is a native iPhone/iPad PDF application. No PaperPath account or login is required.

On first launch, choose “Try a Sample PDF” to explore local sample documents, or “Go to Home” to import a PDF through Files. If documents already exist, the introduction offers “Open My PDF”. Sample material is fictional.

Core reading, editing, scan review, OCR, form filling, handwritten signatures, page organization, and privacy review are available without the lifetime purchase. Camera capture requires a physical device; importing PDFs and exploring sample documents does not require camera permission.

The first successful single Verified Output is free. The non-consumable product `com.monoware.paperpath.full-unlock` unlocks unlimited single and batch Verified Output. This is a one-time purchase, not a subscription. Settings → Unlock Verified Output opens the purchase screen; “Restore Purchase” restores a prior purchase. The price is loaded from StoreKit. Purchase approval can remain pending while the rest of the app is available.

Verified Output creates a separate image-based PDF and a local check receipt. Searchable text, links, forms, and editable layers are flattened out of that copy. Warnings remain visible before sharing. These checks do not certify the accuracy of the document, the identity of a signer, or legal compliance.

Privacy detection runs on device and may miss information. The user reviews candidates, checks locations, selects items, and explicitly confirms permanent redaction. The imported original is preserved. A handwritten signature is a visual mark.

Optional iCloud metadata sync is disabled by default. It syncs reading position, bookmarks, tags, workflow state, fingerprints, and receipt metadata, not PDF files or extracted text. Settings → Privacy & Data describes these boundaries offline.

## 中文审核说明

无需注册或登录。首次启动可选择“试用示例 PDF”，也可进入首页从“文件”导入。示例材料均为虚构；真实相机扫描需要 iPhone/iPad 真机。

首次成功的单份可信输出免费；非消耗型内购 `com.monoware.paperpath.full-unlock` 一次性解锁不限次数的单份及批量可信输出。设置中可进入购买页并恢复购买，价格取自 StoreKit，无订阅续费。

可信输出是独立的图像型副本，会移除可搜索文字、链接、交互表单和可编辑图层。文件检查不等于内容准确、签署人身份或法律合规认证。隐私检测在设备端运行，可能遗漏；永久脱敏需用户复核并确认，保留导入原件。

## 提交前需要填入的外部信息

- App Store Connect 的审核联系人及有效联系方式。
- 正式产品与内购的销售地区、价格、审核截图及提交关联。
- 对外可访问的隐私政策 URL 和支持 URL。应用内的离线说明不能替代这两个商店字段。
- 最终签名归档、导出和上传。项目内的 StoreKit 文件只用于本地测试，不代表真实内购已配置。

商店产品文案见 `APP_STORE_METADATA.md`；隐私政策正文草稿见 `PRIVACY_POLICY_DRAFT.md`。不将本文件中未核实的外部配置标为已完成。
