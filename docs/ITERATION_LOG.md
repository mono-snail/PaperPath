# PaperPath Prototype Iteration Log

## Round 1 - Product Reason

Defined the differentiator: understand the current document locally and show
the shortest useful next action. Rejected a generic tool-grid product.

## Round 2 - Scope Boundary

Separated feasible V1 work from PDF-engine work. Deferred text reflow, Office
conversion, certificate signing, XFA authoring, and cloud collaboration.

## Round 3 - Domain Architecture

Introduced `DocumentRecord`, `DocumentProfile`, `DocumentKind`, and a closed
`DocumentAction` set so recommendations remain explainable and testable.

## Round 4 - Source Protection

Implemented security-scoped import, immediate sandbox copy, protected local
files, and explicit working-copy language. Source URLs are never mutated.

## Round 5 - Document Inspection

Added bounded PDFKit sampling for text coverage, scanned pages, file size,
permissions, encryption, and interactive form fields.

## Round 6 - Recommendation Engine

Mapped document state to OCR, forms, page organization, inspection, and sharing
without exposing unavailable or speculative actions.

## Round 7 - PDF Workspace

Wrapped `PDFView` with stable reload behavior, continuous vertical reading,
zooming, page breaks, and an explicit mutation refresh token.

## Round 8 - VisionKit Capture

Wrapped `VNDocumentCameraViewController`, added multi-page capture callbacks,
and rendered scans into app-owned PDFs while preserving image aspect ratio.

## Round 9 - Local Vision OCR

Rendered one page at a time, capped image dimensions, enabled accurate
recognition and automatic language detection, and exposed confidence per page.

## Round 10 - Page Operations

Implemented clockwise rotation, adjacent movement, page deletion protection,
atomic PDF writes, and post-mutation reinspection.

## Round 11 - Library Persistence

Added actor-isolated JSON metadata, deterministic sorting, rename/delete flows,
missing-file cleanup, actionable errors, and a gated UI-test fixture.

## Round 12 - Visual System

Created a charcoal/blue-black adaptive palette, cyan and mint semantics,
layered surfaces, serif display typography, restrained gradients, and a custom
app icon.

## Round 13 - Library Experience

Made the product reason visible before the first import, kept one primary
action, added concise privacy evidence, and replaced generic list styling with
a document-first composition.

## Round 14 - Workspace Experience

Added a compact document-state strip and contextual bottom action rail. The PDF
remains the dominant surface rather than being surrounded by permanent tools.

## Round 15 - Supporting Surfaces

Built document insight, recognized-text review, page organization, rename,
share, and deletion confirmation with consistent source-safety language.

## Round 16 - Feedback and Accessibility

Added semantic labels, Dynamic Type, text selection, haptics, reduced-motion
handling, loading states, empty states, and non-haptic visual confirmation.

## Round 17 - SDK Compatibility

Fixed PDFKit subtype bridging and iOS 17 symbol-effect availability. Normalized
form widget detection across `Widget`, `/Widget`, and field-name-only PDFs.

## Round 18 - Automated Coverage

Added eight unit tests for text/scan/form classification, bounded 40-page
sampling, scan rendering, source-copy independence, persistence, and mutations.
Added an end-to-end UI test for library, PDF workspace, and page organizer.

## Round 19 - Fresh iPhone Visual Pass

Moved validation off a shared simulator after another app stole foreground
focus. Re-ran on a clean iPhone 17 Pro simulator and reviewed isolated library,
workspace, and organizer screenshots. Fixed the liquid-glass title truncation.

## Round 20 - iPad, Concurrency, and Accessibility Pass

Validated dark-mode iPad split navigation and sheet presentation, passed strict
Swift concurrency and Clang static analysis, verified no networking APIs, and
adapted the import card and privacy proof to vertical Accessibility Dynamic
Type layouts.

## Round 21 - Persistent Text Index

Added page-scoped native text extraction, bounded 500,000-character indexing,
JSON sidecars, OCR sidecar restoration, and invalidation after page mutations.

## Round 22 - Local Document Understanding

Classified contracts, invoices, receipts, reports, letters, and forms. Extracted
dates, amounts, email addresses, phone numbers, links, and reference numbers
locally, with source evidence attached to every suggested step.

## Round 23 - Document Workflow

Introduced Inbox, Reviewing, Ready, and Archived states, plus pins and tags.
Persisted the new fields with backward-compatible decoding for existing
libraries.

## Round 24 - Private Document Desk

Replaced the repeat-use marketing home with an attention queue, local index
count, recent working copies, full-text search, and stage/type filters.

## Round 25 - Batch Intake

Enabled multi-selection in the Files importer and sequential sandbox imports so
each source becomes an independent, inspectable working copy.

## Round 26 - Ordered PDF Merge

Added an on-device merge flow with explicit tap order, output naming, source
protection, and immediate navigation to the created document.

## Round 27 - Page Extraction

Added page selection, Select All, ordered extraction, and creation of a separate
PDF. Existing move, rotate, and delete controls remain available outside
selection mode.

## Round 28 - Searchable Scan Output

Persisted Vision text blocks with normalized coordinates and added Core Graphics
PDF generation with an invisible Core Text layer. The output remains visually
identical while PDFKit can search and select recognized text.

## Round 29 - Document Brief

Added a local brief with category, summary, detected facts, evidence-backed next
steps, workflow transitions, tags, pinning, index provenance, and direct routes
to the relevant completion action.

## Round 30 - Behavioral and Accessibility Gate

Expanded the suite to 13 unit tests and a deterministic end-to-end flow covering
amount search, merge entry, brief review, and page extraction. Reworked new
surfaces into single-column Accessibility layouts after screenshot review, then
passed standard, dark, Accessibility Extra Extra Large, and iPad regression.

## Round 31 - Completion Routes

Introduced value-based document routes with optional page targets. Page
extraction and searchable-copy generation now dismiss their task surface and
open the created PDF immediately on both navigation-stack and split-view
layouts.

## Round 32 - Evidence Navigation

Made multi-term search return the first matching page and taught PDFKit to
navigate to it. Brief steps for dates, amounts, signatures, and forms now return
to the document at the supporting page instead of leaving users to search again.

## Round 33 - Calm Library

Reframed the home screen from an attention dashboard to a neutral Documents
workspace. Replaced warning language with optional suggestions, retained direct
Import, Scan, and Merge actions, and clarified on-device search coverage.

## Round 34 - Information Consolidation

Made Document Brief the primary place for understanding, workflow, file
structure, and privacy evidence. The separate insight surface remains only as a
fallback for locked documents that cannot produce a brief.

## Round 35 - Surface Reconstruction

Removed routine card shadows, inner gradients, glass materials, and decorative
color layers. Standardized corner radii, used flat semantic surfaces, grouped
document rows and merge order into single containers, and kept depth only where
it communicates hierarchy.

## Round 36 - Native Productivity

Added native document context menus for open, pin, workflow, and share actions,
plus keyboard shortcuts for import, scan, and merge. Reduced-motion now disables
the notice spring while preserving explicit state feedback.

## Round 37 - Privacy Hardening

Applied complete Data Protection to PDFs and metadata sidecars, added a private
app-switcher cover, marked the document hierarchy privacy-sensitive, and changed
copy actions to local-only pasteboard entries that expire after five minutes.

## Round 38 - Performance and Cancellation

Precomputed lowercase search corpora, added cancelable 180 ms search debounce,
moved scan PDF rendering off the main actor, made OCR cancelable on exit or by
the user, and stopped canceled batch imports between files.

## Round 39 - Failure and Permission States

Reported partial batch-import success without hiding skipped files, rejected
damaged PDFs without creating library entries, and added a non-blocking camera
denial alert with Continue/Settings choices. Added a preflight storage check
that prevents partial copies when free space is insufficient. Import remains
available when camera access is refused.

## Round 40 - Simulator Release Gate

Passed the end-to-end flow on dark iPhone, dark 13-inch iPad split view, and
light iPhone at Accessibility Extra Extra Extra Large. The maximum-size pass
found and fixed horizontally crushed document rows. Re-ran strict concurrency,
warnings-as-errors, Clang Analyze, privacy, logging, placeholder, and networking
scans.

## Current Verification

- Standard build: passed
- Strict concurrency build with warnings as errors: passed
- Clang static analysis: passed
- Unit tests: 59 executed, 58 passed, 1 physical-device-only protection test skipped
- iPhone UI test: workspace smoke, form authoring, reading, cross-document pages, and Files surfaces passed; Accessibility Extra Extra Extra Large previously passed
- Dark-mode iPhone UI test: passed
- Dark-mode iPad UI test: passed on an isolated 13-inch simulator
- Privacy manifest: zero collection and zero tracking
- Network API source scan: no networking implementation found
- Sensitive logging source scan: no logging calls found

## Known Validation Gap

VisionKit camera capture cannot run in Simulator. A physical-device pass is
required before release for permission handling, multi-page retakes, low-light
quality, orientation, OCR accuracy, high-resolution memory and energy behavior,
background interruption, and verification of complete file protection while the
device is locked. The automated 100/500/1,000-page budget runs in Simulator;
release still requires Instruments measurements for peak memory, cancellation,
energy, thermal behavior, and sustained scrolling on target iPhone and iPad
hardware.

## Round 61 - Compile Recovery

Removed the accidental iOS 18-only search-focus dependency, corrected PDFKit
password option names and collection type inference, and restored an iOS 17
simulator build across both architectures.

## Round 62 - Persistence Migration

Verified legacy metadata decoding without bookmarks, bookmark persistence and
normalization, and protected signature save/remove behavior.

## Round 63 - Output Correctness

Executed readable compression, password locking, rasterized redaction, standard
Ink annotation, insertion, and crop tests against generated PDFs.

## Round 64 - Responsibility Audit

Kept PDF output, mutation, form inspection, signature storage, scanning, OCR,
and view bridging in dedicated services; no new cross-cutting framework or
unnecessary abstraction was introduced.

## Round 65 - Failure Tests

Expanded coverage for invalid passwords, oversized signature data, backup
exclusion, OCR-only text export, direct reorder, and signature geometry.

## Round 66 - Library Composition

Rebuilt the compact-width header so the editorial title and real-document fan
retain their hierarchy without wrapping on iPhone.

## Round 67 - Document Workspace

Kept the PDF as the primary surface, stabilized the four bottom destinations,
and combined reading and outline navigation under one native toolbar menu.

## Round 68 - Tool Discovery

Turned Mark Up into a native contextual menu instead of duplicating the full
Tools palette, while preserving recent and grouped tools in the complete list.

## Round 69 - Annotation Feedback

Added a current-page undo action, explicit empty-undo feedback, and clearer
annotation review labels for drawings and signatures.

## Round 70 - Pencil and Signature Placement

Confined signature input to a paper canvas, defaulted reusable storage off, and
added compact/regular/large sizing with left/center/right placement.

## Round 71 - Redaction Review

Made pending redaction regions individually removable, preserved them while the
user marks another area, and kept permanent output on a separate rasterized PDF.

## Round 72 - Compression Closure

Retained explicit quality choices, estimated size, cancelable processing, and
automatic navigation to the created working copy.

## Round 73 - Password Boundaries

Aligned UI and service validation to 8-128 characters, disabled autocorrection,
made protection cancelable, and retained session-only unlock credentials.

## Round 74 - Form Navigation

Kept interactive PDF fields in PDFKit and used the form review as a completion
map that reports incomplete fields and returns to the relevant page.

## Round 75 - Page Reordering

Added direct drag/drop reordering in addition to accessible move buttons, and
updated bookmarks across insert, delete, exchange, and arbitrary reorder.

## Round 76 - Scan Memory

Bounded review previews to a 1,600-point longest edge, released page-level
rendering intermediates, and propagated scan-render cancellation.

## Round 77 - Long Document Navigation

Bounded outline depth and entry count, filtered invalid legacy bookmarks, and
moved debounced in-document search filtering off the main actor.

## Round 78 - Reading Preferences

Persisted theme, layout, direction, and page mode across documents, while
clarifying that reading themes change the surround rather than PDF colors.

## Round 79 - Export Lifecycle

Made text export use the OCR/native local index, propagated cancellation to
detached exports, and removed generated text/image files after sharing.

## Round 80 - Light Appearance

Reviewed the warm paper, ink, muted border, real thumbnails, and document fan
on an iPhone simulator and corrected the compact header composition.

## Round 81 - Dark Appearance

Reviewed a separately tuned charcoal, warm-white, muted-blue palette in dark
mode instead of relying on a mechanical color inversion.

## Round 82 - Type and Spacing

Retained serif editorial anchors, system body text, monospaced changing values,
the 4/8-point spacing scale, and constrained reading widths on iPad.

## Round 83 - Surface Restraint

Kept shadows for paper and floating hierarchy only, used grouped rows where
appropriate, and avoided converting every action or metric into a card.

## Round 84 - Motion and Feedback

Added selection feedback for scan modes and pages, preserved operation success
feedback, and disabled button scale and transition animations under Reduce Motion.

## Round 85 - Accessibility

Reviewed Accessibility XXXL screenshots, changed narrow controls to vertical
layouts, expanded truncated suggestion copy, and retained keyboard and
VoiceOver labels for workspace, drawing, page, and privacy controls.

## Round 86 - Concurrency and Memory

Passed complete strict concurrency with warnings as errors, replaced a
Sendable PDFKit notification closure with a main-actor selector, memory-mapped
OCR input, and added autorelease pools to page-level image work.

## Round 87 - Privacy Boundary

Excluded the local document and signature roots from system backup, retained
complete file protection, verified no network implementation, and found no
sensitive logging calls.

## Round 88 - Bounded Inputs and Failures

Bounded search, names, notes, passwords, PDF size, signature storage, Ink
strokes, outline depth, and export cleanup while retaining calm actionable errors.

## Round 89 - Multi-Device Regression

Passed the complete search, merge, evidence-page, Brief, page-selection,
extraction, and result-opening flow on isolated iPhone and 13-inch iPad
simulators; manually reviewed light, dark, split-view, and Accessibility layouts.

## Round 90 - Verified Competitive Gate

Published the verified 33-capability rescore. The local private-document
workflow reached 9.2, while Office conversion, original-content reflow editing,
tabs, cloud collaboration, and physical-device gates remain explicitly unclaimed.

## R90 Verification

- Standard build: passed
- Strict concurrency plus warnings-as-errors: passed
- Clang static analysis: passed
- Unit tests: 30 executed, 29 passed, 1 physical-device-only test skipped
- iPhone end-to-end UI flow: passed
- 13-inch iPad split-view end-to-end UI flow: passed
- Manual screenshots: light, dark, Accessibility XXXL, workspace, Brief,
  page selection, and iPad split view reviewed
- Privacy manifest: zero collection and zero tracking
- Network implementation scan: none found
- Sensitive logging scan: none found

## Round 91 - Paper Material

Replaced the flat canvas treatment with restrained desk light and sparse paper
fiber, then introduced a paper-only surface so ordinary controls no longer
inherit document shadows and card styling.

## Round 92 - Document Still Life

Turned the library hero into a real PDF composition with page edges, a binder
clip, annotation pencil, page tab, local stamp, and contact shadow. Decorative
labels are excluded from accessibility scaling and reading order.

## Round 93 - Editorial Library

Replaced the three equal action cards with a linear import/scan/merge tool rail,
moved filters into underlined native menus, and changed the document list into
a continuous indexed folio with larger real-page thumbnails.

## Round 94 - Dossier Brief

Rebuilt Document Brief around the current PDF cover, paperclip, page marker,
analysis stamp, editorial facts, numbered next steps, file specification rules,
and a local-index seal instead of a dashboard of independent cards.

## Round 95 - Image-Led States

Reused the paper scan, text lines, magnifier, check mark, and paper stack for
empty and split-view states. Reduced capsule use in document context and kept
transient processing feedback as the only pill-shaped workspace status.

## Round 96 - Visual Regression

Reviewed dedicated light, dark, Accessibility XXXL, iPhone, and 13-inch iPad
simulators. Corrected a compact Brief metric wrap, excessive paper grain,
decorative Dynamic Type growth, and object overlap in the document still life.

## R96 Verification

- Strict concurrency plus warnings-as-errors build: passed
- Unit tests: 30 executed, 29 passed, 1 physical-device-only test skipped
- Isolated iPhone end-to-end UI flow: passed
- Dedicated 13-inch iPad end-to-end UI flow: passed
- Manual screenshots: light, dark, Accessibility XXXL, library, workspace,
  Brief, empty split view, and iPad reviewed

## Round 97 - Visible PDF Tools

Replaced the merge-only library impression with a visible 12-tool PDF surface
grouped into Create, Pages, Edit & Secure, and Convert. Added direct routing
from each tool through document selection to split, organize, compress, sign,
redact, protect, OCR, text export, or page-image export. Search and filters now
collapse the tool surface so results remain immediate.

Added multi-image PDF creation through the system photo picker without broad
photo-library permission. Replaced the workspace Brief shortcut with Find,
made quick Split enter page-selection mode, and kept Brief available as a
secondary document capability.

## R97 Verification

- Strict concurrency plus warnings-as-errors build: passed
- Unit tests: 30 executed, 29 passed, 1 physical-device-only test skipped
- Existing search, merge, reading, find, page selection, and extraction UI
  flow: passed
- New Compress PDF -> document selection -> compression UI flow: passed
- Manual iPhone library tool-surface screenshot reviewed

## Round 98 - Reliability Baseline

Reproduced the complete unit suite and fixed delivery-receipt timestamps so
ISO-8601 persistence round trips without equality drift.

## Round 99 - Unified Discovery

Extended the library search field to return both document matches and PDF tool
matches without adding a second search surface.

## Round 100 - First-Look Focus

Reduced the initial PDF tool surface from fourteen equal choices to four common
tasks. The complete catalog remains available through one explicit expansion.

## Round 101 - Persistent Quick Tools

Added a native customization menu for two to six quick tools and persisted the
selection with AppStorage. Recent document tools now persist across workspaces.

## Round 102 - Capability Matching

Filtered task document pickers by page count, lock state, scan state, and form
structure. An imported incompatible document now opens normally with an
explanation instead of entering a dead-end task.

## Round 103 - Executable Next Action

Added one contextual action above the PDF and prioritized OCR, form completion,
signature, page organization, evidence review, or sharing from document state.

## Round 104 - Form Closure

Changed form recommendations from passive copy to direct incomplete-field
review and page navigation.

## Round 105 - Safe Share Closure

Made verified Safe Share a first-class library task and direct focused export
route instead of burying it in the general export list.

## Round 106 - Professional Stamps

Added Approved, Draft, Confidential, Final, and Void as standard PDF Stamp
annotations with interoperable names, review visibility, and removal support.

## Round 107 - iOS Quality Gate

Passed strict concurrency with warnings as errors, 37 unit tests with one
physical-device-only skip, three complete iPhone UI tests, and the full
library-to-output flow on a 13-inch iPad Pro simulator. Coverage includes
existing document work plus quick tasks, recommendations, and unified search.

## Remaining Release Gates

- VisionKit camera capture, Apple Pencil feel, locked-device Data Protection,
  high-resolution scan memory/energy, and password interoperability with
  third-party readers require physical devices.
- High-fidelity Office conversion and arbitrary original-content editing
  require a dedicated licensed engine.

## R137 - 去 AI 感与图形资源迭代（10 轮）

本轮按“只确认能编译，不跑测试套件”的要求执行，目标是继续压低模板感、线框感和廉价色块感，让 PaperPath 更像一个有明确审美和产品判断的 iOS PDF 工具。

1. 空库首屏改为“从结果开始”的 PDF 工作台入口，使用本地矢量纸张插画承接导入、扫描和任务选择。
2. 空库默认快速工具改为 Scan to PDF、Images to PDF、Merge PDFs、Compress PDF，避免把用户推向依赖已有文档的后置任务。
3. PDF Tools 区从“Common tasks”改为“Choose what you need”，并加入工具插画，强调先选任务也能自然进入导入路径。
4. 新增 `PPIllustration` 系统，用 SwiftUI 矢量绘制纸张、扫描光带、放大镜、盾牌、工具块和本地标签，替代单一 SF Symbol 空态。
5. 新增 `ToolSymbolPlate`，统一工具图标的底板、描边、阴影和语义色，减少普通列表图标的拼装感。
6. 工具面板从系统 `List` 重构为自定义纸面卡片、工具插画、分组计数和最近工具区，保留搜索与 Done 关闭逻辑。
7. 工作区推荐操作改为完整“下一步卡片”，包含动作徽章、WHY 依据和 Open 反馈，不再像一条临时分割线信息。
8. 受保护 PDF 遮罩、隐私遮罩、iPad 空详情页统一使用产品化插画，避免出现孤立系统图标。
9. 搜索、OCR、批注复核、页面整理等空/加载/异常状态统一改为 `PPEmptyState`，文案保持克制、可操作。
10. 处理中反馈从单纯转圈扩展为 PaperPath 风格的本地处理图形，和“Working on device”语义保持一致。

## R137 Verification

- 编译确认：`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -destination 'generic/platform=iOS Simulator' -derivedDataPath .r137-build build` 通过。
- 按本轮要求未运行单元测试和 UI 测试，留待统一验收。

## R1 - 首页与文档卡任务包（20 轮）

目标：把首页从“工具清单”改成“结果入口”，让每份文档直接给出唯一下一步。

1. 新增 `PDFTaskPackage`，将底层工具组织成用户可理解的任务结果。
2. 增加 Ready to send，串联填表、签名与 Safe Share。
3. 增加 Make searchable，扫描件直接进入本地 OCR。
4. 增加 Fit for email，大文件直接进入压缩副本。
5. 增加 Hide private info，文本 PDF 直接进入永久脱敏。
6. 增加 Fix pages，多页 PDF 直接进入整理页面。
7. 空库默认展示四个任务包，不再先展示十四个平级工具。
8. 有文档时按类型、大小、状态和已完成动作重排任务包。
9. 首个推荐任务使用轻量强调，不使用大面积色块。
10. 全部工具改为按需展开，保持首页视觉克制。
11. 支持先点任务、后选 PDF，减少用户反向寻找工具。
12. 单个兼容 PDF 自动直达，不再多弹一次选择页。
13. 多个兼容 PDF 使用专用选择面板，并显示实际执行动作。
14. 锁定或不兼容文档不进入错误任务路径。
15. 搜索同时匹配任务包和底层工具。
16. 增加中英文意图词：发出去、太大、签字、脱敏、页面等。
17. 文档列表由整块列表改为独立纸面卡片。
18. 每张文档卡只显示一个 NEXT 入口和一句依据。
19. 表单、合同、扫描件、大文件、多页文件分别直达对应动作。
20. 精简首页、空库、选择器和无结果文案，删除大段说明。

## R1 Verification

- 编译确认：`xcodebuild -project PaperPath.xcodeproj -scheme PaperPath -destination 'generic/platform=iOS Simulator' -derivedDataPath .r1-task-packages build` 通过。
- 按当前研发约定未运行单元测试和 UI 测试。

## R21–R25 - 发出前预检

21. Safe Share 增加本地预检模型，先判断 PDF 是否可打开、可渲染。
22. 预检识别空白页和大文件，并要求用户在发送前复核。
23. 预检统计可编辑批注，明确说明 Safe Share 将执行扁平化。
24. 预检识别个人元数据和可恢复文字层，列出将自动清理的项目。
25. Safe Share 页面改为“检查 → 创建 → 验证”，输出前不再提前显示 VERIFIED。

提交验收：

- Safe Share 页面可看到页数、文件大小、自动修复项和复核项。
- 锁定或无法完整渲染的 PDF 会阻止创建安全副本。
- 原文件保持不变，并在预检结果中明确说明。
- 编译通过；未运行单元测试和 UI 测试。

## R26–R30 - 可信输出历史

26. 输出副本持久化 `sourceDocumentID`，记录与源文档的本地血缘关系。
27. 模型层增加可信输出查询，并按 Receipt 时间倒序排列。
28. 源文档工作区增加 OUTPUTS 徽章和菜单入口。
29. 新增可信输出历史页，集中展示类型、时间、大小和缩略图。
30. Delivery Receipt 增加 CREATED FROM 与 SOURCE KEPT 来源说明。

提交验收：

- 从源文档可重新找到所有已验证输出，不再依赖文件名猜测。
- 历史页只展示审计通过的副本，可直接打开对应工作区。
- 旧版资料库记录缺少血缘字段时仍能正常解码。
- 编译通过；未运行单元测试和 UI 测试。

## R31–R35 - 任务理解与证据

31. 文档类型判断增加 High、Likely、Possible 三档置信度。
32. 摘要根据置信度使用确定、可能或保守措辞，避免伪确定性。
33. 建议动作持久化准确证据页，点击后不再依赖二次模糊搜索。
34. 增加带明确标签的 SSN、Tax ID、Passport、IBAN 私人标识检测。
35. 只有邮箱、电话、私人 ID 等敏感实体才触发脱敏建议。

提交验收：

- Document Brief 同时展示文档类型和置信度。
- 日期、金额、签名和表单建议可显示并打开证据页。
- 低置信度私人信息只提示复核，不直接宣称已经发现。
- 编译通过；未运行单元测试和 UI 测试。

## R36–R40 - 已验证副本分享闭环

36. 已验证输出的 Ready to send 入口改为 Share verified PDF，不再重复生成副本。
37. 源文档存在当前有效的可信输出时，自动分享最近一份。
38. 增加内容版本标识；页面、表单、签名或批注变化后不再复用旧输出。
39. Delivery Receipt 工具栏增加直接分享已验证 PDF。
40. Export 页面识别已验证副本，展示指纹并隐藏重复 Safe Share 动作。

提交验收：

- 已验证副本一键打开系统分享页，不经过二次 Safe Share。
- 源文档只有在内容版本一致时才复用最近可信输出。
- 旧输出仍保留在历史中，但修改源内容后不会被误当成当前版本。
- 编译通过；未运行单元测试和 UI 测试。

## R41–R45 - 可信状态与处理性能

41. Delivery Receipt 增加输出内容版本；已验证副本被再次批注、裁切或整理后立即显示 CHANGED，不再继续作为可信文件直接分享。
42. 旧资料库缺少内容版本时使用稳定的文档 ID 迁移，避免同一记录重复解码产生不同版本关系。
43. 页面修改与 PDF 合并改为直接写入临时 PDF 后原子替换，去掉额外的整文件 `Data` 副本，降低大文件峰值内存。
44. 压缩、脱敏、保护、扁平化和 Safe Share 增加逐页进度，并在工作区与输出面板显示稳定百分比。
45. 已验证的栅格输出不再重复执行文档理解；重启后同样跳过无意义分析，减少 CPU、能耗和等待。

提交验收：

- Receipt 只有在输出版本仍一致时显示 VERIFIED，发生内容变化后分享入口自动失效。
- 旧记录的版本关系在多次读取后保持稳定。
- PDF 修改不再通过 `dataRepresentation()` 额外复制整份文档。
- 长输出任务展示实际页级进度，完成后自动清理状态。
- 编译通过；未运行单元测试和 UI 测试。

## R46–R50 - 结果预估与任务直达

46. 压缩页改为抽样首、中、尾页按当前质量实际编码，展示预计大小和节省比例；不适合压缩的 PDF 会明确提示可能无收益。
47. OCR 结果增加低置信度复核队列、All/Review 分段筛选，并可从识别文本直接回到对应原始页面。
48. Safe Share 预检为空白页附加证据页入口，点击复核项可关闭面板并定位问题页面。
49. 首页在空库和有文档两种状态下都把结果任务包前置，导入、扫描与合并退到任务入口之后。
50. 文档工具面板缩短头部，最近工具与高频动作合并为自适应 Quick moves；大字体自动切为单列。

提交验收：

- 切换压缩质量会取消旧估算，并基于页面样本重新计算输出大小。
- OCR 低于 72% 或无文本的页面集中显示，并能一键回到 PDF 页复核。
- 空白页预检项具有清晰的页面跳转反馈。
- 首页首屏优先回答“要完成什么”，工具面板优先展示最多四个高频动作。
- 编译通过；未运行单元测试和 UI 测试。

## R51–R55 - 同类基准与原生视觉

51. 新建 2026 中文同类产品基准，以 PDF Expert、PDFgear、Xodo Mobile、Smallpdf Mobile 官方资料建立证据、权重、边界和胜负线。
52. 首页任务区由四张等权卡片改成一条主路径和三条次级路径，消除规则化 Dashboard 观感。
53. 五个任务包各自使用签名纸、扫描光束、压缩标签、脱敏红线和页序纸张视觉，不再只替换 SF Symbol。
54. 文档工具面板用当前 PDF 首页作为视觉锚点；Quick moves 改为原生横向工具带，分组取消连续卡片容器。
55. PDF 阅读器取消圆角阴影预览框，文档全幅进入工作区；任务和工具选择补充克制的原生触觉反馈。

提交验收：

- 对标基准明确区分官方事实、内部评分和战略性不参评能力。
- 首页只保留一个视觉主任务，次级任务通过真实纸张状态区分。
- 工具面板优先呈现当前文档，而不是通用工具插画。
- PDF 本身成为工作区最大视觉主体，不再显示为装饰卡片。
- iPhone 浅色模拟器视觉复核无文字重叠；编译通过，未运行测试。

## R56–R60 - 批量可信交付

56. Ready to send 文件选择页增加 Prepare several 入口，批量页默认选中全部可处理源文档，并使用真实 PDF 首页展示队列。
57. 每份文件独立执行 Safe Share 预检；锁定、损坏和空白页问题归属到单份记录，不阻断其余文件。
58. Safe Share 严格顺序生成，复用页级实际进度与取消链路，避免多个大 PDF 同时抬高峰值内存。
59. 每份输出继续执行重新打开、逐页渲染、元数据、文字层、批注和 SHA-256 审计；结果汇总为 VERIFIED、REVIEW、BLOCKED、FAILED。
60. 已有有效可信副本直接复用，完成页只将可信输出交给系统批量分享；每份 Receipt、版本关系和源文件血缘保持独立。

提交验收：

- 队列只列出源文档，不把 Safe Share 输出再次当作输入。
- 一份文件失败不影响后续文件，错误原因显示在对应行。
- 大文件提示允许继续，但处理始终保持单文件顺序执行。
- REVIEW 项可回到证据页；分享数组只包含当前有效的可信输出。
- iPhone 浅色批量选择页视觉复核无重叠；编译通过，未运行测试。

## R61–R65 - 功能差异与第二页原生化

61. 竞品基准新增逐项功能差异表，区分官方明确支持、部分支持和不参赛能力，并集中突出 PaperPath 四项可防守优势。
62. 对首页进入后的文档工作区建立浅色基线截图，确认 NEXT 渐变卡和双层信息区是第二页主要 AI 感来源。
63. 文档类型、摘要、可信状态合并成一条紧凑状态栏，保留证据但减少重复标题和装饰容器。
64. 推荐动作改成原生单行操作：直接使用语义图标、Serif 动作名、原因和 disclosure，移除渐变、圆角卡和图标底板。
65. PDF 首屏上移约 80pt，让真实文档更早成为视觉主体；完成浅色与深色模拟器视觉复核。

提交验收：

- 竞品表格同时呈现竞品强项、PaperPath 优势和主动不参评边界。
- 第二页顶部不存在渐变功能卡、卡片套卡片或无意义装饰框。
- 文档状态和下一步仍在首屏直接可见，PDF 可用区域明显增加。
- 浅色与深色模式无控件重叠、截断和对比度异常。
- 编译通过；未运行单元测试和 UI 测试。

## R66–R70 - 批量性能与错误归属

66. Safe Share 预检按文档内容版本缓存；同一 PDF 未变化时，重复进入批量页或失败重试不再重新扫描全部页面。
67. 批量预检采用最多两路受控并发，重型栅格输出和审计保持单路顺序；逐页快照加入 `autoreleasepool` 及时释放图像。
68. 输出管线拆分 Source、Preflight、Create、Verify、Save、Stopped 六个错误阶段，每份文件记录短码、原因、恢复建议和可重试性。
69. 完成页增加 Retry Unfinished，只重跑 FAILED / STOPPED 文件；已有 VERIFIED / REUSED 输出继续保留并可立即分享。
70. 取消后所有未完成项明确收敛为 Stopped；若当前文件已完成验证，则先记录 VERIFIED 再停止后续任务，不产生假失败。

提交验收：

- 未变化文件的预检缓存与内容版本一致，PDF 修改后缓存自动失效。
- 同时最多运行两份预检，栅格化和审计不并发占用大块图片内存。
- 错误显示在对应文件行，不通过全局弹窗覆盖整批结果。
- 失败重试不会重复生成已经验证的输出，停止后可以恢复未完成文件。
- 三份内置 PDF 实际批量运行得到 3 VERIFIED / 0 REVIEW / 0 UNFINISHED；编译通过，未运行测试。

## R71–R75 - 批量吞吐与跨启动缓存

71. 单份输出导入后直接增量更新内存资料库，不再额外解码整份 `library.json`；批量输出减少一次重复索引读取和排序。
72. 预检结果写入受文件保护的本地 sidecar，并绑定 `contentRevisionID`；App 重启后可复用，PDF 内容变化或删除时自动失效。
73. 批量预检完成即逐份推送 READY、REVIEW、BLOCKED 或 FAILED，不再等待全部轻量检查结束后才刷新队列。
74. 预检并发度结合处理器数量与系统热状态；正常最多两路，严重或临界热状态自动降为单路，重型输出继续严格顺序。
75. 栅格输出进度按整数百分比节流，超长 PDF 最多产生约 100 次进度回调，避免逐页创建大量 MainActor 任务。

提交验收：

- 批量输出新增记录后保持资料库原有排序，不进行冗余全量 reload。
- 预检 sidecar 使用完整文件保护，且只在记录 ID 与内容版本同时匹配时加载。
- 每份检查完成后立即出现稳定状态，问题文件不再长时间停留在 Checking。
- 设备热状态升高时预检并发自动收敛，不影响取消和错误归属。
- 编译通过；未运行单元测试和 UI 测试。

## R76–R80 - 批次恢复、错误详情与第二页适配

76. 批次建立稳定运行 ID 和受文件保护的恢复记录；开始时立即保存，阶段变化以 240ms 节流保存，结束时强制写入最终结果。
77. 恢复时重新校验源文件内容版本、锁定状态和当前可信输出；中断在 Queued、Checking、Ready 或 Creating 的项目统一归为 `STOPPED · B-001`。
78. 单份问题增加原生详情页，以真实 PDF 首页、稳定短码和 Source → Preflight → Create → Verify → Save 时间线解释错误归属。
79. 支持 Retry This PDF、Open Source 和 All / Needs attention 筛选；单份重试只更新目标文件，其他 VERIFIED / REUSED 输出保持可分享。
80. 第二页增加 iPad 阅读宽度约束和辅助字号布局；顶部状态 UI 设置合理 Dynamic Type 上限，摘要与推荐原因限制为两行并保留完整 VoiceOver 描述。

提交验收：

- App 被中断后重新进入批量页，可恢复有效源文件和未完成状态，不显示已经删除、锁定或内容变化的旧任务。
- 旧可信输出重新核对当前 Receipt；失效输出不会继续显示为 VERIFIED。
- 问题行可打开阶段时间线并只重试该 PDF，批次中的其他可信输出不会重新创建。
- 大批结果可只看需处理项目，分享数组仍只包含当前有效可信输出。
- iPhone 浅色、深色、辅助字号 XXXL 和 iPad 分栏截图无文字重叠；PDF 保持第二页主视觉。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R81–R85 - 阅读可访问性与完成直达交付

81. 重新核对四个竞品的 2026 官方能力、价格和 Sensor Tower 月度估算；对比表升级到 R85，并增加付费意愿、三档收入情景和 PaperPath 混合定价建议。
82. 阅读菜单增加 Focus Reader，复用受保护的本地文字索引，以 Serif 正文、Dynamic Type、文本选择和 iPad 阅读宽度呈现内容。
83. Focus Reader 支持当前页离线朗读，使用系统语言识别与 `AVSpeechSynthesizer`；页面切换或退出时立即停止，不上传文档文本。
84. 表单字段全部完成后直接显示 Prepare Verified Copy，减少返回工作区再寻找 Safe Share 的一步。
85. 签名页增加 Place & Prepare 主动作和 Place Only 次动作；签名模式隐藏会遮挡按钮的 Pencil 工具条，增加 Clear，并改用全高 Sheet 提升落笔面积。

提交验收：

- Focus Reader 只读取当前文档的本地 `DocumentTextIndex`，无网络依赖。
- 朗读支持播放、暂停、停止、前后页和返回 PDF 原页；切页不会继续朗读旧页面。
- XXXL Dynamic Type 下正文继续放大，页眉元数据和底部控制保持稳定尺寸，无重叠。
- 签名操作按钮不再被 `PKToolPicker` 遮挡，未签名时正确禁用，绘图模式仍保留完整 Pencil 工具。
- 表单完成和签名放置均可一个动作进入交付预检，不跳过预检与输出审计。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R86–R90 - 精确签名放置

86. 签名从单页表单重构为 Capture → Placement 两步任务，先专注书写，再在真实 PDF 页面上确认位置。
87. 新增页面归一化矩形坐标，PDFKit 按实际 CropBox 映射签名，不再局限左、中、右和三档尺寸；旧载荷仍保持兼容。
88. 签名框支持页面内拖拽、双指缩放和尺寸滑杆，并约束在页面边界内。
89. 增加页边距、水平中心和垂直中心吸附；吸附可关闭，VoiceOver 可调节签名大小。
90. 签名工作区改为全屏呈现，iPad 与辅助字号下仍保留足够页面面积；Place & Prepare 继续直达交付预检。

提交验收：

- 签名预览使用真实 PDF 页面比例，不用通用占位纸张。
- 笔迹以自身边界归一化，避免签名画布空白区域压缩实际线条。
- 拖拽、捏合与滑杆都写入同一归一化位置模型，输出不会因设备尺寸改变位置。
- iPhone 普通字号和 iPad XXXL 截图中页面、签名框与底部操作无重叠。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R91–R95 - 专业 Pencil 工作区

91. Pencil 画布按 PDF 实际 CropBox 比例全屏呈现，页面图像直接置于 `PKCanvasView` 底层，笔迹坐标与最终 PDF 批注一一对应。
92. 增加 Pen、Marker、Pencil 和 Vector Eraser 四个稳定预设，不再依赖会遮挡内容的系统浮动工具条。
93. 增加蓝、黑、红、黄四色与连续线宽控制；每笔颜色、透明度和宽度随矢量路径写入 PDF，不在保存后退化为统一蓝线。
94. 增加 Touch & Pencil / Pencil Only 输入模式、原生撤销重做和整页清空，状态不可用时按钮自动禁用。
95. Pencil 工作区升级为全屏并适配 iPad、深色模式和辅助字号；保存后继续触发内容版本更新、预检缓存失效与可信凭证失效。

提交验收：

- PDF 页面在 Pencil 画布中完整可见，不被 UIKit 绘图层的背景遮挡。
- 页面背景只用于书写参照，不进入 `PKDrawing`，输出仍是独立矢量 Ink annotation。
- 笔迹归一化使用画布实际尺寸，设备和窗口尺寸变化不改变 PDF 落点。
- iPhone 浅色普通字号与 iPad 深色 XXXL 截图中工具栏无裁切、重叠或卡片堆叠。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R96–R100 - Pencil 对象编辑与几何形状

96. Pencil 工具增加原生 `PKLassoTool`，选中笔迹后使用系统交互移动、缩放或删除，不建立第二套手势引擎。
97. 增加直线、矩形、椭圆和箭头四种矢量形状；矩形使用四条独立直线，避免 PencilKit 曲线平滑破坏直角。
98. 插入形状后自动切换套索，形状插入和整页清空进入同一撤销/重做历史。
99. 工具、颜色、线宽和 Touch & Pencil / Pencil Only 输入模式跨启动保留。
100. 工具栏压缩为单行专业工具入口，iPhone 实页截图验证形状、套索、撤销和 Save 状态均可见。

提交验收：

- 套索使用 PencilKit 原生对象选择能力，可操作现有笔迹与新增形状。
- 形状保存为 `PKStroke`，与手写笔迹共享矢量 PDF 写入和版本失效链路。
- 形状插入不是静态预览：Save 可用，撤销可用，套索状态自动选中。
- 工具偏好只保存在设备端，不写入 PDF 元数据。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R101–R105 - 已验证内容编辑副本

101. 工作区新增 Add Content 全屏入口，在真实 PDF 页面上放置可移动、可缩放的文字。
102. 增加标准 HTTP(S) 链接，输出包含可打印标签和可点击 `PDFActionURL`，拒绝无效协议与空地址。
103. 增加照片放置；照片在设备端完成方向归一化、最长边 1,800px 降采样和 JPEG 压缩，单图与总载荷均设内存上限。
104. 文字和链接保存为标准 PDF annotation；照片绘入独立编辑副本，原有 annotation 复制保留，源工作副本不变。
105. 编辑副本纳入输出重开审计、逐页渲染、空白页检查、SHA-256 Receipt 和输出血缘；iPhone、iPad 深色及 XXXL 完成视觉复核。

提交验收：

- 文字编辑副本经 Quick Look 重新打开，文字位置与预览一致且原页面内容完整。
- 图片编辑副本经 Quick Look 重新打开，方向正确、比例保持、未发生上下翻转。
- Receipt 验证页数、逐页渲染和空白页检查，并记录 `edited` 操作与 SHA-256。
- Add Content 只生成独立副本，不直接改写或栅格化源工作副本。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R106–R110 - 结构化导出

106. 文本导出从单一 TXT 扩展为 Word-compatible RTF、Markdown 和 UTF-8 Plain Text。
107. RTF 增加文档标题、导出来源、页标题和分页符，Word 与系统文本工具可直接识别。
108. Markdown 保留文档一级标题和页面二级标题；三种文本格式统一复用页级文字提取，避免重复读取 PDF。
109. 页面图片增加高质量 JPEG、紧凑 JPEG 和无损 PNG；紧凑模式同时降低最长边和编码质量。
110. 文本与图片导出增加页级进度、取消清理和受保护临时文件，导出 Sheet 按 Editable Text / Page Images 原生分区。

提交验收：

- RTF 文件被系统 `file` 工具识别为 Rich Text Format，包含文档标题和两页内容。
- Markdown 包含 `# Project handoff` 与逐页 `## Page N` 标题。
- 高质量 JPEG 为 1,854 × 2,400；紧凑 JPEG 为 1,236 × 1,600，示例体积显著下降。
- PNG 保持 1,854 × 2,400 无损输出；iPhone 导出 Sheet 无文字裁切或控件重叠。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R111–R115 - 可验证的受限原文替换

111. Mark Up 新增 Replace Selected Text，直接捕获 PDFKit 真实单页文字选择、页坐标、字号、颜色、行数与旋转状态。
112. 增加替换兼容性引擎：阻断混合字体、旋转页、批注冲突、纹理背景、超出原框和超过四行的选择。
113. 编辑页仅在兼容时高分辨率重建；原选择不进入新文字层，非冲突批注作为可编辑对象恢复，其余页面保持原 PDF。
114. 未编辑文字按原行坐标重建不可见搜索层，新文字以真实 PDF 文本写入；Sans / Serif / Mono 使用可嵌入标准字体。
115. 输出重新打开并比较旧词、新词出现次数；只有旧词减少且新词增加才导入，并继续执行页面渲染、空白页、血缘与 SHA-256 审计。

提交验收：

- PDFKit burn-in 探针证实普通遮罩不会删除底层旧字，因此未采用伪原文编辑方案。
- 示例 `pages reviewed → pages checked` 输出中旧词消失、新词可搜索，无不可见残余字符。
- Quick Look 中替换文字位置、颜色和 Sans 风格与原标签一致，其余页面未重建。
- iPhone 与 iPad 深色 XXXL 编辑器中页面、选择框、字体模式和状态反馈无重叠。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R116–R120 - 本地 DOCX 导出

116. Editable Text 新增真实 `.docx` 导出，不依赖改扩展名或远端转换；文件完全在设备端生成。
117. 实现无第三方依赖的 OOXML ZIP 打包器，写入 Content Types、Relationships、Core Properties、Styles、Settings 和主文档部件。
118. PDFKit 按真实文字行提取边界、字号、粗斜体和位置，依据行距、缩进与字号变化推断正文、标题、列表和段落边界。
119. DOCX 保留 PDF 页边界，并把推断结果写成可编辑 Word 段落；原生文字不可用时才使用本地 OCR 文字索引降级。
120. DOCX 任务沿用页级进度、取消和完整文件保护；导出入口直接进入系统 Share Sheet。

提交验收：

- 系统 `file` 将样本识别为 `Microsoft OOXML`，不是 RTF 或 ZIP 改名文件。
- `unzip -t` 验证 8 个 OOXML 部件均完整，主文档、样式与 Content Types 通过 `xmllint`。
- macOS `textutil` 可直接读取导出样本，标题、正文和列表内容完整。
- 关闭 OCR/索引回退后，Core Text 原生 PDF 仍能提取并生成可读 DOCX。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R121–R125 - 复杂段落选区重排

121. 原文编辑从最多四行扩展为单页最多 24 行、4,000 字符的真实 PDF 文字选区。
122. 字体兼容性改为按字体族和字符占比判断，允许粗体、斜体及少量符号回退，不再把同一字体家族误判为混排。
123. 新增左、中、右对齐；布局引擎使用与最终 Core Text 输出一致的字号、行距和换行参数实时评估。
124. 段落在原选区内自动换行，并在原字号到最低 80% 之间寻找最大可用字号；仍无法容纳时明确阻断，不裁切文字。
125. 输出审计改为折叠空白后比较旧段落与新段落，兼容视觉换行变化；旧内容必须减少、新内容必须增加才允许导入。

提交验收：

- 编辑器显示实际重排行数和最终字号，预览与 PDF 绘制共用字体、行距和对齐结果。
- 长单词超过选区宽度时阻断，不用截断或省略号冒充成功。
- 段落重排继续执行单页高分辨率重建、搜索层恢复、重开验证、页面渲染和 SHA-256 Receipt。
- 旋转页、显著混合字体族、批注冲突和纹理背景仍保持安全阻断。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R126–R130 - DOCX 表格与图片保真

126. DOCX 文字提取细化到词级坐标，依据同一行内的大间距拆分单元格，不再把表格行合并成普通段落。
127. 连续行按列数和列起点容差聚合成表格，只有至少两行稳定对齐时才生成表格，降低正文误判。
128. 输出真实 Word `<w:tbl>`、固定列宽、单元格边距、边框和可重复表头；正文、表格和分页保持原阅读顺序。
129. 递归检查 PDF Page/Form Resources 中的 Image XObject；仅图片型页面生成最长边 1,400px 的压缩视觉参考。
130. OOXML 增加 DrawingML、图片 Relationships、JPEG Content Type 和 `word/media` 二进制部件，文本仍保持可编辑。

提交验收：

- 原生 PDF 样本导出为 3 行 × 3 列真实 Word 表格，XML 包含 1 个 `<w:tbl>`、3 个 `<w:tr>` 和 9 个 `<w:tc>`。
- 图片样本生成 1 个 `<w:drawing>`、`rId3` 图片关系及有效的 1,081 × 1,399 JPEG 媒体部件。
- `unzip -t`、`xmllint` 和系统 `textutil` 均可读取增强后的 DOCX，正文和表格文字完整。
- 图片视觉参考只用于保留复杂页面外观，不冒充可独立编辑的原始图片对象。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R131–R135 - 跨文本框内容流

131. 单页文字选择上限扩展为 48 行、8 个文本框和 8,000 字符，并按列对齐、阅读方向及垂直连续性自动分组。
132. 评估引擎升级为 Core Text 多 Frame 连续排版，同一份文字按框容量顺序流动，不在每个框重复绘制。
133. 字号、行距、长词溢出和完整容纳检查覆盖所有文本框；任一框过小、纹理背景或批注冲突都会整体阻断。
134. 多框背景检测改为单次页面渲染和批量采样；最终输出逐框覆盖旧内容，并重建未编辑搜索层。
135. 编辑器逐框显示实际分流文字和顺序编号；重开审计按各框文字片段验证新内容增加，并确认旧内容消失。

提交验收：

- 两个独立 Frame 的 Core Text 探针返回 `FLOW_OK`，输出 PDF 重开后文字顺序完整且可搜索。
- 预览和最终 PDF 共用文本框顺序、字号、行距、对齐及分流结果。
- 最多 8 个框只渲染一次页面缩略图，不随文本框数量重复执行高成本页面渲染。
- 多框输出继续生成独立副本，并执行逐页渲染、空白页、血缘和 SHA-256 Receipt。
- `xcodebuild` 编译通过；按研发约定未运行单元测试和 UI 测试。

## R136–R140 - AcroForm 创建与兼容性

136. 表单字段从名称/类型摘要升级为稳定身份、页内边界、必填、只读、多行、最大长度、选项数、外观流和字段级问题。
137. 检查文档 Catalog 中的 XFA、JavaScript 和 `NeedAppearances`；XFA 明确保留但不编辑，脚本不会在设备上执行。
138. 检测无名字段、无效边界、密码字段、选项/导出值不匹配、未知 Widget 及同名异型字段，不以“能显示”冒充兼容。
139. 在真实 PDF 页面预览上拖动并缩放文本框、复选框和签名字段；支持跨页定位、必填和多行设置。
140. Widget 写入使用原子工作副本替换，拒绝重名、越界和不支持类型；空签名不再因自动外观流被误判为已完成。

提交验收：

- 40 页样本的字段放在第 39 页，仍能被完整字段遍历识别，文档正确分类为 Form。
- 创建文本和签名字段后重开 PDF，字段类型、必填标记、最大长度和边界保持。
- 重复字段名第二次写入被阻断，原文件只保留一个 Widget。
- XFA、脚本和复杂字段只报告可验证事实，不宣称已编辑或已执行。

## R141–R145 - 长文档有界管线

141. 页面缩略图改为 actor 串行生成，同一时刻不并发打开大量 PDF；缓存最多 64 张、12 MB 和两个文档实例。
142. OCR 增加真实逐页进度、页前页后取消检查和有界页面结果预分配，工作区可直接停止长任务。
143. 文档检查把文字采样限制为 12 页，同时轻量遍历全部页面 Widget，避免长表单字段落在未采样页时漏报。
144. 组合、提取、可搜索副本、预检、哈希和导出统一增加页级或块级取消边界；取消中的临时扫描输出会删除。
145. 建立 100、500、1,000 页耗时与驻留内存采样、250ms 取消和首/中/末页抽取顺序探针。

提交验收：

- 100、500、1,000 页模拟器检查均保持 12 页文字采样，低于 2.5 秒与 250 MB 峰值增量预算。
- 1,000 页源文件抽取第 1、500、1,000 页后重开为 3 页，文字标记和升序输出一致。
- 取消探针从发出取消到任务返回低于 250ms。
- 以上是自动化预算证据，不替代发布目标 iPhone/iPad 的 Instruments、能耗和温升门禁。

## R146–R150 - 扫描几何与光照增强

146. 使用 `VNDetectRectanglesRequest` 检测纸张四角，置信度不足时保留完整画面并显示 Full frame，不伪造裁切成功。
147. 检测成功后以 `CIPerspectiveCorrection` 校正斜拍页面，预览和最终 PDF 共用同一几何管线。
148. 使用系统 `CIDocumentEnhancer` 去除不均匀阴影、提白背景，并按彩色/文档模式控制强度。
149. 透视后按页面短边内收清理黑边；新增 Otsu 自适应黑白模式，保留彩色、文档和灰度选择。
150. 扫描预览提供独立 Auto crop、Shadows、Clean edges 开关；最终处理最长边限制为 3,200px 并逐页释放中间图像。

提交验收：

- 斜四边形纸张样本可检测边缘并输出校正后的纵向页面。
- Otsu 黑白、自动裁切、阴影和清边组合可生成两页 PDF，进度从 0 到 1，重开后两页均可渲染。
- 检测状态、滤镜和三个二元设置均有原生控件、Dynamic Type 与无障碍名称。
- 原图模式、检测失败和任务取消都有明确、非破坏性降级。

## R151–R155 - 长文阅读与导航

151. `DocumentRecord` 增加最后阅读页和最近阅读时间，旧资料库记录无字段时安全回退到第一页。
152. PDF 翻页状态以 450ms 防抖落盘，离开工作区立即提交；页位变化不修改文件 `modifiedAt`，不会打乱资料库排序。
153. 重新打开文档自动回到最后页位；阅读菜单直接列出最近文档及其最后页码，不经资料库中转。
154. Bookmarks & Outline 增加页码精确跳转、目录标题搜索和页码搜索；2,000 项/24 层边界内支持取消。
155. 无目录和书签时显示原生空状态，仍保留跳页和当前页书签入口，不留不可解释的大面积空白。

提交验收：

- 4 页样本保存第 4 页后重启 Store，页位和最近阅读时间保持，文件修改时间不变。
- 工作区 UI 可从阅读菜单进入页码定位，并在最近文档间一跳切换。
- iPhone 截图确认跳页、书签入口、搜索栏和空状态无重叠或文字截断。

## R156–R160 - 批量与跨文档页面工作流

156. 页面选择增加全选、奇数页、偶数页和闭区间范围，不要求在长文档中逐页点击。
157. 多页旋转和删除在一次 `PDFDocument.write` 中完成；批量删除强制至少保留一页。
158. 选中页可按升序复制到资料库内另一份未锁定 PDF，源文档保持不变，目标文档重新分析。
159. 每次页面变更前创建受保护恢复快照；成功后开放一级撤销，失败不覆盖上一次有效快照。
160. 撤销恢复页面内容、页数和书签映射，再次重建文字索引与文档理解，不只回滚 UI 状态。

提交验收：

- 6 页样本批量旋转 1/3/5、删除 2/4 后页数和内容顺序正确。
- 从一份 PDF 复制 2/4/6 页到另一份 PDF 后重开，目标追加顺序为 2、4、6，重复选择只复制一次。
- 删除中间页后一级撤销恢复 3 页原文和 `[2, 3]` 书签位置。
- 页面工作区 UI smoke 覆盖全选、跨文档目标列表和独立提取副本。

## R161–R165 - 对象级图片与跨页内容流

161. 文字流区域增加页号、原始片段和精确文字范围；PDFKit 可捕获最多 4 页、96 行、16 个区域的连续选择。
162. Core Text 评估、背景采样、页面预览和输出重建升级为跨页管线；每页只渲染一次，并按页恢复未编辑搜索层。
163. 输出重开后逐页确认旧片段减少、新片段增加；较短替换可让后续区域留空，不以重复文字填满空框。
164. 增加直接 JPEG Image XObject 扫描与真实边界预览；只允许 64 MB 内、未复用对象进入替换，复用、加密、线性化和压缩对象流明确阻断；逐页扫描只保留候选摘要。
165. 对经典 xref PDF 重写原图片间接对象并重建完整交叉引用，不叠加遮罩、不栅格化整页；输出确认旧 JPEG 字节消失、新对象摘要变化并可重新渲染。

提交验收：

- 跨页探针在两页 PDF 上返回两个不同分流片段；输出重开后两页旧文字均消失，新文字保持可搜索。
- 图片探针构造真实经典 xref、内容流和 JPEG XObject；替换后原 JPEG 字节在输出中不存在，对象号保持不变，像素尺寸与摘要更新。
- 图片编辑器直接在真实 PDF 页上显示对象边界和原始对象缩略图；复用对象以虚线标记且不可选择。
- 所有编辑继续生成独立私有副本，并进入页面渲染、空白页、血缘、Receipt 和 SHA-256 审计。
- 两个定向结构测试、完整单元测试和 iPhone 工作区 smoke 通过；严格并发与 warnings-as-errors 编译通过。

## R166–R170 - Files 与 iCloud 原生协作

166. 从 Files 导入时保存系统安全书签、源文件名和分块 SHA-256；应用生成的临时 PDF 不伪装成外部源位置。
167. Files & Source 显示私有副本、源未变、源已外部修改、位置失效和不可用五种状态，并标识 iCloud Drive 项。
168. Save Working Copy to Files 使用系统文档导出控制器处理带用户显示名的受保护临时副本，不把大 PDF 全量读入内存；成功、取消、页面离开和下次启动都会清理副本。
169. Replace Original 仅在当前源指纹与导入基线一致时开放；`NSFileCoordinator` 写入块内再次校验，消除确认到写入之间的竞态。
170. 外部源变化时 fail-closed，只允许导入为新的私有副本；成功写回后刷新指纹与书签，原私有副本继续保留。

提交验收：

- 外部源未变化时可协调写回两页工作副本，重开源文件页数和文字正确，状态回到 Source unchanged。
- 外部修改源文件后状态变为 changed，写回被阻断且外部内容不被覆盖。
- 阅读、跨文档页面和 Files UI 流程在 iPhone 模拟器通过，系统 Files 选择器实际打开，四张实际尺寸截图无重叠或截断。
- 严格并发与 warnings-as-errors 编译通过；59 项单元测试执行，58 通过，1 项仅真机文件保护测试跳过。

## R171–R175 - 现有链接与复杂 AcroForm

171. Edit Links 从只能新增链接扩展为扫描整份 PDF 的现有链接，按页稳定定位 URL、Destination、`PDFActionURL` 和 `PDFActionGoTo`。
172. 现有链接可在真实 PDF 页面上选择、拖动和双指缩放，并编辑可打印标签；不支持的 Action 只显示事实，不伪装成可改目标。
173. Web URL 与页内跳转可以互转，删除前要求确认；整份文档没有当前页链接时自动打开最近的链接页，并提供链接页菜单。
174. 每次修改生成独立副本；输出重新打开后核对链接数量、标题、目标和归一化边界，失败输出立即删除。
175. AcroForm 创建增加同名 Radio 组和 Choice 下拉/列表，限制 2–12 个唯一选项及单项 64 字符，并保留原有字段标志。

提交验收：

- 现有 Web 链接可改为页内跳转再删除；两次输出均重新打开并通过链接结构断言。
- Radio 与 Choice 创建后重开，字段名、导出值、选项、必填和列表模式保持。
- Widget 检查只统计真实 Widget，不把 Radio 的 FreeText 标签误算为字段。
- 链接与表单 UI 路径在完整 iPhone 模拟器套件中通过。

## R176–R180 - XLSX、轻量元数据同步与回归收口

176. Editable Text 增加真实 `.xlsx` 导出，在设备本地生成 Content Types、Workbook、Relationships、Styles 和逐页 Worksheet。
177. 原生 PDF 按文字坐标间距推断行列，OCR 索引按制表符或连续空格降级；数字写为 Excel 数值单元格，不混入字符串。
178. XLSX 设置 1,000 页、500,000 单元格、12,000,000 字符和每行 64 单元格上限；ZIP 签名、关键部件、`unzip -t` 与全部 XML 均完成验证。
179. 使用 `NSUbiquitousKeyValueStore` 同步页位、书签、流程状态、置顶、标签、完成动作和 Receipt；不上传 PDF 字节、名称、OCR 或提取文字。
180. 以当前工作副本 SHA-256 作为跨设备身份，并使用字段级时间戳和本地 shadow 合并；不同内容指纹不合并，晚导入的空默认值不覆盖远端有效状态。

提交验收：

- XLSX 样本含两个工作表和真实数值单元格，OOXML 九个部件通过 ZIP 与 XML 外部校验。
- 两个模拟设备状态按字段合并；修改后的工作副本建立独立云条目，Receipt 仅在本地哈希与页数一致时恢复。
- iCloud KVS 上限为 128 项、900 KB、180 天；同一内容的本地重复记录只同步最活跃副本。
- 字段合并使用内存 KVS 双端探针验证；当前模拟器无 iCloud 账号，真实账号跨设备传播仍待后续验证，不计作已完成门禁。
- 首页默认公开 Quick tools，并补齐 Safe Share 与 Compress；搜索空态统一为 documents or tools，辅助功能 XXXL 可达。
- 完整单元测试执行 64 项，63 通过、1 项真机文件保护测试跳过；完整 UI 套件 7/7 通过。
- Swift Strict Concurrency complete 与 Swift/Clang warnings-as-errors 构建通过。
- 严格全能力分按 11 项加权为 `9.129`，四舍五入 `9.1`；未达到 `9.5`，不启动真机门禁。

## R181–R185 - OCR、批注保真与发布隐私收口

181. OCR 增加 Automatic / Choose Languages 配置、最多四种识别语言和最多 50 个本地自定义词；已有结果可从复核页重新识别，取消或失败不会覆盖旧索引。
182. OCR 结果按 Vision 坐标稳定恢复自上而下、同行自左向右的阅读顺序，并持久化实际配置；旧 sidecar 缺少配置时兼容回退为 Automatic。
183. Page Images 增加 Original JPEGs，直接导出 PDF 中可安全读取的 DCTDecode 字节流，按 SHA-256 去重并逐文件回读校验；256 张、192 MB、单流 16 MB 与 1,000 页边界内支持取消和临时目录清理。
184. Annotation Review 增加备注、颜色和线宽编辑并在原子替换前重开验证；签名和不支持对象保持只读。字段级写入只在可见文字或样式实际变化时重建 appearance stream，FreeText 独立字体色不会被边框色覆盖。
185. 将 “No upload / Everything stays on device” 收紧为“私有 PDF 副本和内容留在设备”，明确轻量状态可经 iCloud KVS 合并；Privacy Manifest 补齐 UserDefaults、磁盘空间和文件时间戳 Required Reason API，仍保持零跟踪、零开发者数据收集。

提交验收：

- OCR 双语、自定义词去重、非法语言拒绝和旧结果解码通过定向测试。
- 批注样式重开验证通过；FreeText 仅改文字后字体色保持不变。
- 两页重复 JPEG 样本导出为一个逐字节一致文件，源 PDF 未改变；无 JPEG 时不残留临时目录。
- `PrivacyInfo.xcprivacy` 通过 `plutil`，声明 `CA92.1`、`E174.1`、`C617.1` 与 `3B52.1`。
- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 的 arm64 与 x86_64 构建通过。
- `Release` 全模块优化构建与 Clang Analyze 通过。
- 完整单元测试执行 68 项，67 通过、1 项仅真机文件保护测试跳过；完整 iPhone UI 套件 7/7 通过。
- 复核普通字号、Accessibility XXXL、资料库、工作区、链接、表单与 Files 实际尺寸截图，无文字重叠、按钮裁切或工具栏遮挡。
- VisionKit 相机、Apple Pencil 手感、锁屏文件保护、高分辨率内存/能耗、第三方密码阅读器及真实 iCloud 账号传播仍属于真机门禁，未宣称完成。

## R186–R188 - 资料库首屏信息密度与展开关系

186. 将原本上下堆叠的资料库标题、摘要和装饰图重排为紧凑横向 Hero：左侧 `Documents` 与单行数量摘要，右侧保留由真实 PDF 缩略图、夹子、铅笔和 LOCAL 印章组成的文档扇面；导航栏恢复 `PaperPath` 品牌。右上角 `+` 在任意文档数量下均提供导入和扫描，两份以上时增加合并。
187. 普通字号 Hero 约 106pt 高，Import / Scan / Merge 紧随其后；推荐流程改为 64pt 级紧凑行，在普通 iPhone 首屏同时露出品牌插图、采集动作、四个建议流程和 PDF tools 入口。
188. 删除建议流程标题旁与内容脱节的 `All tools / Hide tools`；在 `PDF tools` 面板内部提供 `Show all / Show less`，展开内容从按钮正下方连续出现，Quick Access 自定义入口保持同区。

提交验收：

- UI 测试确认展开按钮位于 `pdfToolsSection` 框内，点击后 VoiceOver 名称从 “Show all PDF tools” 切换为 “Show quick PDF tools only”，并出现折叠前不可见的 Images to PDF。
- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 的 arm64 与 x86_64 构建通过。
- 完整 iPhone UI 套件 7/7 通过；横向 Hero 调整后资料库主流程与 Accessibility XXXL 定向复跑通过。
- 复核普通字号默认/展开态与 Accessibility XXXL Hero 的 1206×2622 截图，无文字重叠、按钮裁切、插图越界或工具区跳变。

## R189 - 建议流程 2×2 紧凑网格

189. `For your PDFs` 的四个建议流程由四行改为两列两行；每格保留定制文档插图、标题和用途，推荐项继续使用 `RECOMMENDED` 标识、表面和左侧强调线。普通字号最小内容高度收至 68pt，辅助字号和搜索结果保留单列布局。

提交验收：

- UI 自动化验证第一/第二项同一行、第三/第四项同一行，且两列顺序正确。
- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 的 arm64 与 x86_64 构建通过。
- 资料库到工作区主流程及 Accessibility XXXL 定向测试通过。
- 复核默认与工具展开态 1206×2622 截图，四项无文字截断、重叠或高度跳变。

## R190 - 品牌标题与副标题

190. 品牌标题统一为 `PaperPath: PDF Studio`，副标题统一为 `Pro PDF tools, on device`；两者分别为 21/30 和 24/30 字符，符合 App Store 字段上限。导航栏优先显示完整标题，窄宽度视觉回退为 `PaperPath`，VoiceOver 始终读取完整标题；首屏 Hero 在不增加高度的前提下显示副标题。桌面短名称、Bundle ID、模块名和本地数据目录保持不变。

提交验收：

- 新增 `AppBrand` 单一文案源和 `docs/APP_STORE_METADATA.md` 发布元数据口径。
- 构建产物确认 `CFBundleDisplayName` 为 `PaperPath`、`CFBundleIdentifier` 为 `com.monoware.paperpath`。
- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 的 arm64 与 x86_64 构建通过。
- UI 自动化确认完整标题和副标题可访问；资料库主流程与 Accessibility XXXL 定向测试通过。
- 复核 1206×2622 实机尺寸模拟器截图，导航标题与 Hero 副标题无截断、重叠或插图挤压。

## R191 - 美区定位与 Verified Output 统一

191. 将通用的 `Pro PDF tools, on device` 收敛为
`Private PDFs. Verified output.`；用户可见的 `Safe Share` 统一改为
`Verify & Share`、`Verified Copy` 和 `Verify Several PDFs`。内部
`safeShare` 枚举、Codable 值、Receipt operation 和处理实现保持不变，避免
破坏既有文档状态与持久化兼容性。

提交验收：

- `PaperPath: PDF Studio` 为 21/30 字符，新副标题为 30/30 字符；正常字号
  1206×2622 截图确认 Hero 高度、装饰图、Import / Scan / Merge 和 2×2
  建议流程不受影响。
- 完整单元测试执行 68 项，67 项通过、1 项仅真机文件保护测试跳过。
- 资料库到工作区主流程与 Accessibility XXXL 定向 UI 测试 2/2 通过。
- Release 配置通过 Swift Strict Concurrency complete 与 Swift/Clang
  warnings-as-errors 构建。
- 新增 `docs/US_MARKET_ENTRY_ROADMAP_2026_ZH.md`，以前五所需的
  4 万月下载、US$4 万月流水、4.7 评分和 200 条有效评分作为真实市场目标；
  未用内部功能分宣称市场领先。

## R192 - Fill / Sign / Verify 黄金路径

192. 表单复核只让未完成的必填字段阻塞交付，可选空字段保留在清单中但不再
阻止 `Verify & Share`。点击未完成的签名字段会直接打开对应页的签名采集，
并以字段边界作为初始定位；签名落在字段内后，重开 PDF 会按实际重叠范围将
该字段识别为完成。签名主动作统一为 `Place & Verify`，仍保留
`Place Signature` 供需要继续编辑的用户使用。

提交验收：

- 不相交的签名墨迹不会误判字段完成；与签名字段重叠至少 45% 的 PaperPath
  签名会完成该字段，普通 Ink 或其他页面签名不会参与判定。
- `PDFFormInspectionReport.isReadyForVerifiedOutput` 统一表单 UI 与
  `DocumentActionPlanner` 的完成语义：至少一个字段、无缺失必填项、非 XFA
  只读表单；可选空字段不阻塞。
- UI 自动化从 `Approval signature` 一步直达 `Add signature` 第 2 页，
  截图确认表单清单显示 `tap to sign`，签名画布没有文字截断或控件遮挡。
- 完整单元测试执行 70 项，69 项通过、1 项仅真机文件保护测试跳过；
  完整 iPhone UI 套件 7/7 通过。
- Release 配置在 arm64 与 x86_64 模拟器架构通过 Swift Strict Concurrency
  complete 与 Swift/Clang warnings-as-errors 构建。
- 本轮证明路径和完成判定正确；Apple Pencil 手感、真实 AcroForm 输入法行为
  与第三方阅读器中的最终签名外观归入 R203–R206 发布门禁。

## R193 - Verified Output 结果优先

193. Verified Output 工作区不再用扫描类型或技术摘要作为第一信号，而是直接
显示 `Ready to share`、警告数量或 `Output changed`，并说明 PaperPath 实际
重开和检查了多少页。Delivery Receipt 首屏改为“结果 → 分享 → 来源保留 →
交付事实 → 逐项检查”，SHA-256 指纹和认证范围继续保留在下方证据层。

提交验收：

- `PDFDeliveryReceipt` 新增稳定的 `outcomeTitle`、`outcomeDetail` 与
  `warningCount`；失败、警告和全部通过使用不同、可测试的用户表述。
- 当前 Receipt 在首屏显示 `FINAL COPY CHECKED`、`Ready to share` 和
  `Share verified PDF`；修改后的输出显示 `Verify again`，不提供过期凭证下
  的主分享动作。
- 新增真实端到端 UI 测试：从首页 `Verify & Share` 选择 Project handoff，
  完成预检、创建、重开与审计，再进入 Delivery Receipt；不是静态 fixture。
- 1206×2622 截图确认结果标题、缩略图、印章、主分享按钮、`SOURCE KEPT`、
  Delivery Facts 和前三项 Checks 同屏，无裁切、重叠或技术信息抢占主结论。
- 完整单元测试执行 70 项，69 项通过、1 项仅真机文件保护测试跳过；
  完整 iPhone UI 套件扩展为 8 项并全部通过。
- Release 配置在 arm64 与 x86_64 模拟器架构通过 Swift Strict Concurrency
  complete 与 Swift/Clang warnings-as-errors 构建。

## R194 - 任务恢复与受限 PDF 替代路径

194. 新增只保存在受文件保护本地索引中的 `DocumentTaskCheckpoint`，记录
Fill / Sign / Verify 阶段、页码、字段名和签名框位。资料库和工作区优先展示
`Continue filling`、`Continue signing` 或 `Continue verification`；彻底终止
App 后可回到原页和签名框位。签名完成后重新检查全部表单字段，仍有必填项时
不会提前进入 Verify。

受限 PDF 不再只有错误提示：

- XFA、只读或不兼容必填字段保留原表单数据，并提供
  `Open a copy in another app`。
- 密码 PDF 的密码只保留在当前文档会话；成功解锁后可创建独立、无密码、
  保留页面和 AcroForm 字段的 editable private copy，原始 PDF 继续加密。
- 损坏或无法重开的 PDF 预检 fail closed，不改工作副本，并提供外部打开和
  `Check this PDF again`。
- editable copy 的重开、页数、加密状态和 SHA-256 Receipt 与最终交付 Receipt
  分开；它继续进入填写/签名流程，不进入 verified delivery history。

提交验收：

- 终止并重启 App 的真实 UI 测试确认资料库出现 `Continue signing`，点击后
  直接回到第 2 页签名界面；1206×2622 截图无截断或布局挤压。
- 检查点 JSON 往返、页码边界、清除、规划器优先级和 Verified Output 成功后
  自动清除均有单元覆盖。
- 跳过未填姓名直接签名时，规划器仍优先 `Recipient name`，不会把
  `Verify & Share` 插到未完成必填项之前。
- XFA 样本被识别为 viewing-only 和 compatible-reader 路径；原 PDF 仍可打开。
- 加密样本生成无密码副本后保留 AcroForm 必填字段，原文件仍锁定；源和输出
  均被重开，encryption check 通过。
- 损坏样本预检失败后字节未改变；锁定样本返回明确 blocked assessment。
- 完整单元测试执行 77 项，76 项通过、1 项仅真机文件保护测试跳过；
  完整 iPhone UI 套件扩展为 9 项并全部通过。
- Release 配置在 arm64 与 x86_64 模拟器架构通过 Swift Strict Concurrency
  complete、Swift/Clang warnings-as-errors；Clang Analyze 通过。
- 本轮未宣称第三方 XFA 编辑器、真实密码 PDF 生态兼容或锁屏保护真机完成；
  这些发布门禁按后续优先级调整移至 R203–R206。

## R195 - 本地 PDF 到 PowerPoint

195. 将主开发线从后置真机协议排障调整回专业功能领先，新增完全本地的真实
`.pptx` 导出。每个 PDF 页面生成一张保持原纵横比的高分辨率视觉幻灯片；
原生文字层或已有本地 OCR 索引写入透明可搜索文本层。输出包含标准 OOXML
Content Types、Presentation、Master、Blank Layout、Theme、逐页 Slide、
Relationships 和 JPEG Media，不通过改扩展名伪装格式，也不上传 PDF。

用户入口同步调整：

- Quick Task 从 `PDF to Text` 提升为 `PDF to Office`。
- 导出 Sheet 将 `Editable Text` 改为 `Office & Text`。
- Word、Excel、PowerPoint、RTF、Markdown 和纯文本在同一层可见。
- PowerPoint 明确说明为“一页一张高保真幻灯片 + 可搜索文字”，不宣称复杂
  PDF 版式已转换成可自由重排的 PowerPoint 对象。

安全与边界：

- 锁定、空白、无效页面尺寸、渲染失败和写入失败均 fail closed。
- 单次限制 500 页、源文件 512 MB、渲染媒体 240 MB，支持取消。
- 页面最长边按 2,200 px 渲染，输出文件继续应用 Complete File Protection。
- 幻灯片按第一页方向建立自定义尺寸；其他尺寸页面等比居中，不裁切内容。

提交验收：

- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 的模拟器
  Debug 构建通过。
- 两页真实 PDF 定向测试通过：第 1 页验证原生文字层，第 2 页验证 OCR
  fallback；确认逐页 Slide、Image Relationship、JPEG Media、搜索文字、
  Slide 数量和 `.pptx` 扩展名。
- 导出样本通过 `unzip -t`，17 个 OOXML 部件全部完整；所有 XML 通过
  `xmllint`，macOS 内置 Office Quick Look 成功解析并渲染第一页。
- 严格全能力分按同一权重从 R180 的 9.1 重算为 R195 的 **9.2**，仍低于
  PDF Expert 9.4；未用单项新增虚报全面超越。
- 下一轮改为 R196 图片对象兼容面；真机门禁移至功能达到 9.5 后的发布阶段。

## R196 - 嵌入图片兼容导出

196. `Embedded Images` 不再只识别顶层直接 JPEG。扫描器可递归进入最多四层
Form XObject，并沿用页面与 Form 的变换矩阵定位真实图片使用；同一资源多次
使用继续按内容 SHA-256 去重。

导出结果分级：

- DCT JPEG 与 JPEG 2000：保留 Core Graphics 返回的原始压缩流，分别输出
  `.jpg` / `.jp2`。
- 常见 8-bit DeviceGray、DeviceRGB 和 DeviceCMYK raw/Flate 图像：解码为
  无损 `.png`，不再增加有损压缩。
- SMask：要求同尺寸 8-bit Gray 数据，合成真实 alpha 后输出 PNG。
- 自定义 Decode、硬 Mask、ImageMask、Indexed/ICCBased 等当前无法证明颜色
  还原正确的对象继续计入 unsupported，不输出可能错误的图片。

UI 从 `Original JPEGs` 改为 `Embedded Images`，完成提示分别显示原始流文件数、
无损 PNG 数、去重使用次数和跳过的不支持对象数。

提交验收：

- 手工构造的真实 PDF 同时包含 Page -> Form XObject -> Flate RGB Image ->
  Flate Gray SMask；导出得到 4×2 带 alpha PNG，页内 occurrence 为 1，
  原 PDF 前后字节完全一致。
- 原始 JPEG 重复跨页使用样本继续只导出一个字节完全一致的 `.jpg`；
  occurrence 为 2，原始流/PNG 分类正确。
- 经典 xref JPEG 对象替换回归通过，扩展导出扫描器没有扩大替换引擎的安全
  范围。
- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 构建
  通过；R195 PPTX 定向回归继续通过。
- 严格加权精确分由 R195 的 9.221 提升到约 **9.24**，一位小数仍为 9.2；
  下一轮必须继续攻 14% 权重的图片编辑，而不是通过四舍五入虚报领先。

## R197 - 图片对象替换兼容面（进行中）

已完成第一项：经典 xref PDF 中，同一直接 JPEG Image XObject 被多页或多处
复用时，不再禁用替换。用户选择该对象后会看到 `Used N times`，创建副本前
必须确认 `Replace All N Uses`；底层只重写共享对象一次，因此所有引用保持
一致，不制造多个分叉资源。

当前验收：

- 两页共同引用 object 5 的样本从 `usageCount = 2` 正确识别为共享图片。
- 替换后旧 JPEG 字节消失，两页仍引用 object 5，摘要一致、usageCount 仍为
  2，像素尺寸同步更新为新图片。
- 单次使用对象原路径继续通过；共享图片在画布上使用琥珀虚线和堆叠图标，
  不会被误解为只影响当前页。
- 严格加权精确分约由 9.239 提升到 **9.253**，一位小数为 9.3。

R197 第一阶段结束时尚未完成：

- xref stream / object stream 中的压缩图片对象替换。
- 带 SMask 的透明图片对象级替换和 alpha 重建。
- 上述两项没有结构验证前继续阻断，不计入完成分。

### R197 完成补记

- 澄清 PDF 规范边界：Image stream 本身不能位于 object stream；真实缺口是由
  xref stream 索引的 Image XObject。现已解析 `/W`、`/Index` 和 type 0/1/2
  条目，替换后重建完整 xref stream，而非增量附加旧图。
- xref stream 样本替换后旧 JPEG 字节完全消失，PDFKit 可重开，图片对象编号
  和新尺寸保持可验证。
- Flate RGB + Gray SMask 支持透明 PNG 替换；RGB 与 alpha 分别无损压缩并
  重建两个对象，输出仍识别为透明图片。

## R198 - 语义重排长文阅读

- Focus Reader 增加连续页、页锚点、阅读位置恢复、Serif/Sans/Rounded、
  15–30 pt 字号、三档段宽和中日韩无空格拼接。
- 语义重排合并硬换行与断词，保留标题、项目符号和自然段。
- Read Aloud 支持从当前页跨页连续朗读、自动跟随页位和语速控制。

## R199 - 自适应 OCR 与直接纠错

- 低置信度、短文本或弱块过多页面自动进入 3,200 px 文档增强二次识别，仅在
  加权质量分提高时采用。
- 增加双栏检测和列优先阅读顺序，置信度按字符长度加权。
- 低置信度行可直接修改；人工确认写入受保护本地 OCR 结果，并同步重建搜索、
  摘要、Focus Reader 和可搜索 PDF 的文字来源。

## R200 - 原生控制、权限与目录

- Apple Pencil 双击遵循系统切换橡皮/上一个工具偏好；Pencil Pro 挤压提供
  上下文工具。当前仅完成模拟器编译，未宣称物理 Pencil 手感验证。
- 密码副本使用独立随机 owner key，不再让 user password 同时拥有 owner
  权限；可控制打印、复制、批注、填表和页面管理，并在写出后重开核对权限位。
- App 本地页书签可生成标准 PDF Outline 独立副本，跨阅读器保留目录入口。
- 模拟器严格构建与 R197 两个深度样本通过；首页模拟器实看无布局回归。
- 同权重严格分约 **9.51**，首次达到 `>= 9.5` 功能线；市场前五目标仍未完成。

## R201 - 页面标签、附件与审阅对象

201. 增加标准 PDF 页面标签、嵌入附件提取和结构级审阅对象兼容，继续抬高
`9.5` 功能线之上的领先余量。

页面标签：

- Bookmarks & Outline 增加 Page Labels，支持最多 16 段编号范围。
- 支持十进制、大小写罗马数字、大小写字母、前缀和仅前缀标签。
- 输出直接更新 Catalog `/PageLabels` Number Tree；经典 xref 与 xref stream
  都会完整重建交叉引用，不使用增量追加。
- 结构不兼容时可先在临时副本中归一化，但输出必须重新核对页数、逐页标签、
  附件、只读审阅对象、批注数量和 Outline；任一变化即删除输出并失败。

附件：

- 解析文档 `/Names /EmbeddedFiles` 名称树、页面 FileAttachment 注解，以及
  PDF 2.0 文档/页面 `/AF` 关联文件。
- 展示文件名、MIME、字节数、页码、说明和 SHA-256 摘要。
- 支持单个和批量提取；文件名会去路径化并消毒，临时目录应用 Complete File
  Protection 且排除备份。
- 每个文件限制 64 MB，单文档解码预算 192 MB；超限文件可见但不可提取。
- 写出后重新读取字节并核对长度与 SHA-256，Share Sheet 关闭后清理临时目录。

审阅对象：

- Core Graphics 结构扫描补充 PDFKit 当前不支持的 Squiggly、Caret、Polygon
  和 PolyLine。
- 这些对象进入 Annotations 清单，可跳回原页并显示 note、颜色和 appearance
  状态；由于 PDFKit 无安全写入能力，保持只读且不提供误导性的删除/编辑。
- FileAttachment 不混入普通批注清单，统一进入 Attachments 工作区。

验证：

- iOS Simulator Debug 双架构构建通过；未运行 XCTest，未使用物理设备。
- 三页结构样本实际发现并提取 2 个附件，原字节和 SHA-256 一致；读取页面标签
  `i / ii / 1`，并识别一个带 appearance 的 Squiggly 对象。
- iOS Simulator 内直接调用实际页面标签写入器，输出重开得到
  `i / ii / Body 1`，同时附件、审阅对象、批注数和 Outline 保持一致。
- 首页 1206×2622 模拟器截图确认原有高密度布局无回归。
- 严格加权精确分保守更新为约 **9.55**；音频批注、附件插入和第三方阅读器
  互操作未计入完成分。

## R202 - AcroForm 逻辑与 Office 异常版式

202. 在不引入通用 JavaScript 引擎的前提下支持常见计算表单，并收紧本地
Office 输出的旋转、混合方向和极端宽高比。

AcroForm：

- 解析 Widget 与 Parent 继承链中的 `/AA`，支持 `AFSimple_Calculate`
  的 SUM/PRD/AVG/MIN/MAX，建立跨计算字段依赖并检测循环、缺失源字段和
  非有限结果。
- 支持 `AFNumber_Format`、`AFPercent_Format`、`AFDate_FormatEx`、
  `AFTime_FormatEx`、对应 Keystroke 和 `AFRange_Validate`。
- Number format 支持 0–10 位小数、五种分隔符、负数括号和货币前后缀；
  日期/时间仅接受已知 Acrobat 模式，不猜测任意脚本。
- Form check 展示计算来源、格式预览、范围错误和待刷新状态；自定义
  JavaScript 明确转交兼容阅读器，不执行 `event`、`this` 或任意表达式。
- 首次样本暴露 PDFKit 写回会删除字段 `/AA`。因此最终实现改为直接更新
  间接字段对象 `/V`、移除目标旧 `/AP`、设置 `NeedAppearances`，并重建
  classic xref 或 xref stream；不再让 PDFKit 重建整份计算表单。
- 写出后重新解析字段数、计算/格式/范围规则和字段值；任一脚本或值变化即
  删除输出。

Office 异常版式：

- 统一使用 CropBox 与标准化页面 rotation 得到显示几何。
- DOCX 为每个源页写入独立 section；Letter、旋转横页、超长和超宽页分别
  得到受限的纵向/横向纸张，最短边不低于 5 英寸。
- XLSX 每页工作表写入 portrait/landscape、`fitToWidth=1`、打印居中和边距。
- PPTX 不再由第一页决定全部画布；使用全部页的中位宽高比，限制在
  `9:16...16:9`，混合方向中性值使用标准 `4:3`。
- 极端页使用 2,400–6,000 px 有界长边渲染，保持原始比例，不拉伸或裁切。

验证：

- 模拟器结构样本识别 4 个字段；Quantity `2` 与 UnitPrice `12.5` 计算得到
  Total `/V = 25`，预览 `$25.00`，范围和 `08/30/2026` 日期格式通过。
- 自定义 `event.value = ...` 样本识别为 1 个不支持脚本，未进入本地执行。
- 结构写回后 `AFSimple_Calculate`、`AFNumber_Format`、
  `AFRange_Validate` 和 `/AA` 引用仍在，字段重开值为 `25`。
- 四页 Office 样本覆盖 portrait、`/Rotate 90`、`300×1800` 和
  `1800×300`；PPTX JPEG 分别为 `1854×2400`、`2400×1854`、
  `400×2400`、`2400×400`。
- DOCX/XLSX/PPTX 全部通过 ZIP CRC 和所有 XML/RELS 的 `xmllint`；
  DOCX 四段 section 方向正确，XLSX 四表方向正确，PPTX 为标准 4:3
  `9144000×6858000`。
- 仅使用 iOS Simulator；未运行 XCTest，未使用物理设备或发布门禁。
- 严格加权精确分保守更新为约 **9.60**。

### R202 第二阶段 - 跨页重排溢出与取消边界

实现：

- 跨页重排只接受连续页面；文本框必须保持页序和源文字范围顺序，提交前逐框
  核对原文字节范围，跳页、范围重叠或源内容变化直接阻断。
- Core Text 测量记录安全最小字号下已消费的 UTF-16 长度；仍放不下时报告
  剩余字符数。区域边界落在单词内部时明确阻断，不跨页拆词。
- 提交不再信任旧预览：用当前源文件、替换文本、字体和对齐重新评估，并比较
  字号、行距、分区文字和背景采样；任一变化要求重新检查。
- 同页多个文字框保留独立源范围，重建搜索层时只排除真正选中的范围，不再用
  最小到最大范围吞掉中间未选文字。
- 编辑 Sheet 保存期间将 `Cancel` 切换为 `Stop` 并锁定输入；取消传播至
  detached 评估、PDF 页面重建、输出审计和文档导入。
- `replaceText` 未完成时删除目标文件；DocumentStore 在复制、检查、指纹和
  索引提交前检查取消。导入前还核对源 `contentRevisionID`，避免保存过期结果。

验证：

- iOS Simulator Debug 构建通过；未运行 XCTest，未使用物理设备。
- 直接 Simulator harness 验证三页正常跨页重排，第三页文字和页数保持不变，
  两页旧文字移除且新文字可搜索。
- 400 组超量文字返回容量阻断和剩余字符说明；第 1、3 页跳页选择被阻断。
- 使用旧评估提交不同文字被阻断且不留下输出；80 页文档在重建中取消后目标
  文件不存在。
- 严格评分仅调整“原文、图片和链接编辑”`9.55 -> 9.65` 与“性能、兼容性
  与稳定证据”`8.75 -> 8.85`，精确加权分为 **9.6155**，展示为 **9.62**。

### R202 第三阶段 - 英文 / 简体中文双语界面

实现：

- 新增 `AppLanguage` 与 `AppLocalization`，支持跟随系统、English 和简体中文；
  语言设置使用 `@AppStorage` 持久化，并通过 SwiftUI `locale` 环境即时刷新。
- 首页右上角增加语言菜单。文档库、工具面板、文档工作区、页面与文本编辑、
  表单、OCR、Office 导出、Verified Output、完成提示和错误反馈均接入中文。
- SwiftUI 静态字面量使用本地化资源；枚举标题、运行时状态、插值文案和错误
  统一通过显式本地化层处理。
- 文档摘要和推荐步骤继续保存稳定英文语义值，显示时动态翻译；切换语言不会
  让旧文档永久保留创建时的界面语言。
- 中文格式字符串使用位置参数，避免省略英文复数后缀后造成参数错位。文件名、
  PDF 原文、表单实际字段名、链接标题、Outline 标题和 SHA-256 不做翻译。
- 新增简体中文 `InfoPlist.strings`，相机用途说明与应用界面语言保持一致。

验证：

- 最终 Simulator Debug 构建通过；`Localizable.strings` 与
  `InfoPlist.strings` 均通过 `plutil` 校验，无重复键。
- Xcode 从最终源码提取 524 个静态 `Localizable` 键，简体中文覆盖
  **524/524**，缺失 **0**；中文资源另包含运行时模板，共 1,040 个唯一键。
- 最终 `PaperPath.debug.dylib` 的 Simulator harness 验证中英文切换、中文
  位置参数、动态错误、文档摘要和旧英文持久化内容，输出
  `dynamic=zh/en formats=stable persisted=language-neutral`。
- 正式应用视觉抽查覆盖首页、表单检查、文档工作区、工具搜索和 Office 导出；
  修复工作区分类/摘要/续填说明、工具面板短标题及 PDF 导出选项的动态漏翻。
- 在系统语言保持 English 时将应用语言设为 `zh-Hans`，正式应用仍完整显示
  中文；切回 English 后同一数据恢复英文。
- 仅使用 iOS Simulator；未运行 XCTest，未使用物理设备。

## R203–R207 - 本地版本对比与逐页变化审阅

203. 重新审计 PDF 功能广度与用户路径，停止向首页继续增加同权重工具卡。
当前基础能力已足够，下一项高价值缺口确定为“完成后看懂最终副本改了什么”。

204. 在 `PDFDeliveryAuditService` 中建立有界逐页对比引擎：

- 每页生成固定 `48×48` RGB 视觉采样，不保存完整页面位图。
- 对归一化可搜索文字计算 SHA-256，并比较 CropBox、页面旋转和页数。
- 输出新增、删除、可见像素、文字层和页面几何变化；每页检查取消。
- 版本对比使用高灵敏度阈值，交付门禁使用高置信度阈值，避免 Safe Share
  重绘产生的抗锯齿差异被误报为交付失败。

205. 将逐页变化报告写入 `PDFDeliveryReceipt`。Verified Output 自动展示重大
变化，不要求用户先理解新工具；旧 Receipt 通过可选字段继续兼容。

206. 新增 `Compare Versions` 文档工具，路径固定为：

```text
打开 PDF → Tools → Compare Versions → 选择对比对象 → Compare PDFs
```

结果先显示变化总数，再显示 Visible、Text layer、Page size 分类，最后列出
最多 12 个变化页面及原因。入口只位于文档上下文，不占用首页首屏。

207. 完成中英双语、性能和交互收口，并修复批注颜色归一化缺陷：

- Compare Versions 的 34 个界面与结果键补齐简体中文。
- 200 页一致 PDF 对比两次约 `0.199–0.237s`，峰值 RSS 增量低于
  `192 MiB` 门禁。
- 固定 Simulator UI 路径在 `17.122s` 内完成，输入页和结果页无重叠。
- 批注颜色写入、变更判断和重开验证统一使用 `[0,1]` 归一化分量；原稳定失败
  的超范围颜色回归用例现于 `0.036s` 通过。
- 完整 `PaperPathTests` 执行 99 项，98 项通过、1 项真机文件保护用例跳过、
  0 项失败。

评分：

- 密码、脱敏与可信交付：`9.90 -> 9.95`
- 性能、兼容性与稳定证据：`8.85 -> 8.90`
- iOS 原生体验与成熟度：`9.60 -> 9.65`
- 严格加权精确分约 `9.6245`，展示仍为 **9.62**。单项领先没有被用来虚报
  全面市场领先；Office 导入、云端连续性、长期真机证据和品牌信任仍是差距。

## R208–R212 - 变化页直达与 Office 互操作基础

208. 为每个 `PDFPageChange` 建立统一目标语义：

- 修订页存在时打开修订 PDF；修订页不存在即删除页，回到基础 PDF。
- Compare Versions 和 Verified Output Receipt 共用这一判断，不在视图层重复
  推断新增、删除和普通变化。

209. 将变化行改为整行可点击的原生 Button，尾部显示 `BASE` 或 `REVISED`
及 chevron，并补齐中英文 VoiceOver hint。入口仍在结果层级内，没有增加第二个
Open 按钮或首页工具卡。

210. 页直达复用现有工作区：

- 同文档关闭结果 Sheet 后调用现有页码导航。
- 跨文档关闭 Sheet 后使用 `DocumentRoute(recordID:pageIndex:)` 打开目标工作区。
- 目标记录已删除时 fail closed，不进入无效页面。

211. 为 DOCX、XLSX、PPTX 增加写出前 OPC/OOXML profile 校验：

- 阻止重复和非法 ZIP part path。
- 核对格式必需部件，并解析所有 XML 与 `.rels`。
- 归一化内部 Relationship target，阻止越过包根目录并验证目标存在。
- 解析 `[Content_Types].xml`，要求每个部件被 Default 或 Override 覆盖，
  并核对三种格式主部件的精确 Content Type。
- 校验通过后才生成 Local Header、Central Directory、CRC-32 和 EOCD。

212. 收紧跨阅读器兼容基础：

- DOCX/XLSX/PPTX 共用 XML 1.0 非法字符清理，避免控制字符破坏整个包。
- XLSX 扩展属性改为标准 `HeadingPairs` 和 `TitlesOfParts`。
- DOCX、XLSX 和 PPTX Theme 使用 Arial 作为更广泛的 Office/iWork 字体回退，
  不再依赖 Aptos 或 Apple 独有字体。

验证：

- 新增页目标为修订版、删除页目标为基础版的逻辑测试通过。
- 固定 Simulator 端到端路径
  `Compare Versions → changePage-1 → Site review report` 在 `20.848s`
  内通过，确认 Sheet 关闭、跨文档导航和目标工作区均正确。
- 四页混合几何 DOCX/XLSX/PPTX 样本通过 ZIP CRC、XML、RELS、Content
  Types、非法 XML scalar 清理、标准工作簿属性和字体断言；定向用例耗时
  `0.409s`。
- 完整 `PaperPathTests` 执行 100 项，99 项通过、1 项真机文件保护用例跳过、
  0 项失败。
- `Localizable.strings` 通过 `plutil`，相关改动通过 `git diff --check`。
- 本机没有 Word、Excel、PowerPoint、Pages、Numbers、Keynote 或 LibreOffice；
  真实第三方打开和视觉一致性仍是外部门禁，未宣称完成。

评分：

- 格式转换与导出：`9.65 -> 9.70`
- 性能、兼容性与稳定证据：`8.90 -> 8.95`
- iOS 原生体验与成熟度：`9.65 -> 9.70`
- 严格加权精确分约 `9.6335`，展示为 **9.63**。该提升只计入已自动证明的
  包结构和导航闭环，不计入尚未执行的第三方应用实际打开。

## R213 - Simulator Office 渲染门禁

213. 启动 Office/iWork 打开验证，并严格限定为固定 Simulator：

- 启动 `2BDDA0A7-5C5A-49DF-B9CB-C11A86B35472`，确认 Simulator 与本机均未
  安装 Word、Excel、PowerPoint、Pages、Numbers 或 Keynote。
- 新增 `testOfficeExports_renderInSimulatorQuickLook_BitsUT`，使用生产导出器
  生成四页混合几何 DOCX、XLSX 和 PPTX，再要求 iOS Quick Look 返回真实
  `.thumbnail`；通用文件图标不算通过。
- DOCX 渲染为 `612×792` 页面，XLSX 渲染为 `47×35` 已用单元格范围，
  PPTX 渲染为 `720×540` 幻灯片。定向用例 `1.905s`、0 失败。
- 三份原始 OOXML 文件和三张 Simulator 预览作为 XCTest keepAlways 附件，
  持久化到 `.artifacts/office-interoperability/R213-20260816-samples/`。
- Word/Pages、Excel/Numbers、PowerPoint/Keynote 六项真实应用打开均记录为
  `BLOCKED: app unavailable`。Simulator Quick Look 不冒充真实应用通过。
- 本轮不调整 `9.6335` 竞争评分。

完整环境、结果矩阵和证据路径见
`docs/OFFICE_INTEROPERABILITY_VALIDATION_2026_ZH.md`。

## Release Brand Finalization - 2026-08-22

- App Store 与应用内正式名称统一为
  `PaperPath: Secure PDF Studio`（28/30 字符）。
- 桌面图标与 Share Extension 使用较短的 `PaperPath PDF`，避免系统截断。
- `PaperPath` 模块名、Bundle ID、URL Scheme、数据目录与签名兼容标识保持不变。
- 发布版本保持 `0.1.0`，构建号提升为 `2`。
- iPhone 窄宽度工具栏继续视觉回退到 `PaperPath`，辅助功能标签始终提供完整正式名称。

## R214 - 公共 Office 语料回归

214. 在不安装 Office/iWork、也不使用真机的前提下扩展互操作证据：

- 从 Apache POI 官方测试语料下载 9 份 Office 2007+ OOXML 文件，总计约
  `1.2 MB`，覆盖 DOCX 图片、复杂编号和 Unicode，XLSX 条件格式、数据透视表
  和图表，以及 PPTX SmartArt、主题和日文。
- 测试资源随 `PaperPathTests` 离线分发；LICENSE、NOTICE、源 URL、用途和
  SHA-256 均保存在 `OfficeInteropCorpus`，运行时不依赖网络。
- 宿主 `unzip -t` 验证 9 份 ZIP 的 CRC 和目录；固定 Simulator 逐份要求
  Quick Look 返回 `.thumbnail`，并检查非空尺寸和 PNG 数据。
- `testPublicOfficeCorpusRendersInSimulatorQuickLook_BitsUT` 于 `5.311s`
  通过，9/9 文件成功渲染；视觉抽查确认不是文件图标占位。
- 现有测试解析器只支持 PaperPath 输出的 Stored ZIP，不能解析公共样本的
  Deflate ZIP；公共语料因此使用系统 `unzip -t`，没有把测试工具边界误判成
  文档损坏。
- Microsoft Office 与 iWork 真实应用打开仍需目标应用本身；本轮评分不变。

## R215 - 加密 PDF 结构保留与解锁审计

215. 修复密码移除和交付审计的两个 P0：

- `protect` 在 PDFKit 完成 AESV2 加密后，以标准 PDF 增量修订恢复加密的
  EmbeddedFiles 与显式 PageLabels；附件流、文件名和标签字符串均使用同一
  文档密钥加密，不写入明文 sidecar。
- `removePassword` 从已解锁源文件提取附件、页标签和 Outline，重建独立无密码
  副本，并在提交前比较附件 checksum、标签、只读审阅语义、Outline 和批注数。
- `.unlocked` 交付审计新增 `document-structure` 门禁；页面视觉相同但附件、
  标签、只读审阅对象或 Outline 丢失时，不再签发 verified receipt。
- 结构读取显式接收当前会话密码；错误密码、超限附件、无法安全合并的结构均
  失败闭合，并清理临时文件和不完整输出。
- 两项 P0 定向回归通过；完整 `PaperPathTests` 执行 108 项，107 通过、1 项
  真机文件保护测试跳过、0 失败。
- Swift Strict Concurrency complete、Swift/Clang warnings-as-errors 的
  Release arm64 + x86_64 通用模拟器构建通过。
