import Foundation

enum AppNoticeKind: String, Hashable, Sendable {
    case success
    case recovery
    case warning
}

enum AppNoticeAction: Hashable, Sendable {
    case restoreTrash(recordIDs: [UUID])
    case undoPageChange(recordID: UUID)
    case undoPageChanges(recordIDs: [UUID])

    var title: String {
        switch self {
        case .restoreTrash:
            return "Restore"
        case .undoPageChange, .undoPageChanges:
            return "Undo"
        }
    }
}

struct AppActionNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let message: String
    let detail: String?
    let kind: AppNoticeKind
    let action: AppNoticeAction
    let targetSceneID: UUID?

    init(
        id: UUID = UUID(),
        message: String,
        detail: String? = nil,
        kind: AppNoticeKind,
        action: AppNoticeAction,
        targetSceneID: UUID? = nil
    ) {
        self.id = id
        self.message = message
        self.detail = detail
        self.kind = kind
        self.action = action
        self.targetSceneID = targetSceneID
    }

    func targetingScene(_ sceneID: UUID?) -> AppActionNotice {
        AppActionNotice(
            id: id,
            message: message,
            detail: detail,
            kind: kind,
            action: action,
            targetSceneID: sceneID
        )
    }
}

struct AppTransientNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let message: String
    let targetSceneID: UUID?

    init(
        id: UUID = UUID(),
        message: String,
        targetSceneID: UUID? = nil
    ) {
        self.id = id
        self.message = message
        self.targetSceneID = targetSceneID
    }

    func targetingScene(_ sceneID: UUID?) -> AppTransientNotice {
        AppTransientNotice(
            id: id,
            message: message,
            targetSceneID: sceneID
        )
    }
}

struct AppPresentationError: Identifiable, Hashable, Sendable {
    let id: UUID
    let message: String
    let offersSettings: Bool
    let targetSceneID: UUID?

    init(
        id: UUID = UUID(),
        message: String,
        offersSettings: Bool = false,
        targetSceneID: UUID? = nil
    ) {
        self.id = id
        self.message = message
        self.offersSettings = offersSettings
        self.targetSceneID = targetSceneID
    }

    func targetingScene(
        _ sceneID: UUID?
    ) -> AppPresentationError {
        AppPresentationError(
            id: id,
            message: message,
            offersSettings: offersSettings,
            targetSceneID: sceneID
        )
    }
}

struct DocumentRoute: Hashable {
    let recordID: UUID
    let pageIndex: Int?
    let quickTask: PDFQuickTask?
    let expectedContentRevisionID: UUID?
    let invocationID: UUID?

    init(
        recordID: UUID,
        pageIndex: Int? = nil,
        quickTask: PDFQuickTask? = nil,
        expectedContentRevisionID: UUID? = nil,
        invocationID: UUID? = nil
    ) {
        self.recordID = recordID
        self.pageIndex = pageIndex
        self.quickTask = quickTask
        self.expectedContentRevisionID = expectedContentRevisionID
        self.invocationID =
            invocationID ?? quickTask.map { _ in UUID() }
    }

    func bindingExpectedRevision(
        _ contentRevisionID: UUID?
    ) -> DocumentRoute {
        guard expectedContentRevisionID == nil,
              let contentRevisionID
        else { return self }
        return DocumentRoute(
            recordID: recordID,
            pageIndex: pageIndex,
            quickTask: quickTask,
            expectedContentRevisionID: contentRevisionID,
            invocationID: invocationID
        )
    }
}

enum PDFQuickTaskGroup: String, CaseIterable, Identifiable {
    case create
    case pages
    case finish
    case convert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: return "Create a PDF"
        case .pages: return "Fix pages"
        case .finish: return "Finish & protect"
        case .convert: return "Convert & extract"
        }
    }
}

enum PDFQuickTask: String, CaseIterable, Identifiable, Hashable {
    case scanToPDF
    case imagesToPDF
    case mergePDFs
    case splitPDF
    case organizePages
    case compressPDF
    case fillForms
    case signPDF
    case redactPDF
    case protectPDF
    case safeShare
    case recognizeText
    case exportText
    case exportImages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanToPDF: return "Scan to PDF"
        case .imagesToPDF: return "Images to PDF"
        case .mergePDFs: return "Merge PDFs"
        case .splitPDF: return "Split PDF"
        case .organizePages: return "Organize Pages"
        case .compressPDF: return "Compress PDF"
        case .fillForms: return "Fill Forms"
        case .signPDF: return "Sign PDF"
        case .redactPDF: return "Redact PDF"
        case .protectPDF: return "Protect PDF"
        case .safeShare: return "Verify & Share"
        case .recognizeText: return "OCR PDF"
        case .exportText: return "PDF to Office"
        case .exportImages: return "PDF to Images"
        }
    }

    var detail: String {
        switch self {
        case .scanToPDF: return "Capture paper pages"
        case .imagesToPDF: return "Combine selected photos"
        case .mergePDFs: return "Join files in order"
        case .splitPDF: return "Extract selected pages"
        case .organizePages:
            return "Reorder, rotate, crop"
        case .compressPDF: return "Reduce sharing size"
        case .fillForms: return "Complete interactive fields"
        case .signPDF: return "Draw or reuse a signature"
        case .redactPDF: return "Remove sensitive content"
        case .protectPDF: return "Add an open password"
        case .safeShare: return "Clean, reopen, and verify"
        case .recognizeText: return "Read image-based pages"
        case .exportText: return "Word, Excel, PowerPoint, or text"
        case .exportImages: return "Export pages as PNG"
        }
    }

    var symbol: String {
        switch self {
        case .scanToPDF: return "viewfinder"
        case .imagesToPDF: return "photo.on.rectangle.angled"
        case .mergePDFs: return "square.stack.3d.up"
        case .splitPDF: return "rectangle.split.3x1"
        case .organizePages: return "square.grid.2x2"
        case .compressPDF:
            return "arrow.down.right.and.arrow.up.left"
        case .fillForms: return "pencil.and.list.clipboard"
        case .signPDF: return "signature"
        case .redactPDF: return "eye.slash"
        case .protectPDF: return "lock.doc"
        case .safeShare: return "checkmark.shield"
        case .recognizeText: return "text.viewfinder"
        case .exportText: return "doc.richtext"
        case .exportImages: return "photo.stack"
        }
    }

    var group: PDFQuickTaskGroup {
        switch self {
        case .scanToPDF, .imagesToPDF:
            return .create
        case .mergePDFs, .splitPDF, .organizePages:
            return .pages
        case .compressPDF, .fillForms, .signPDF, .redactPDF,
             .protectPDF, .safeShare:
            return .finish
        case .recognizeText, .exportText, .exportImages:
            return .convert
        }
    }

    var requiresDocument: Bool {
        switch self {
        case .scanToPDF, .imagesToPDF, .mergePDFs:
            return false
        case .splitPDF, .organizePages, .compressPDF, .signPDF,
             .fillForms, .redactPDF, .protectPDF, .safeShare,
             .recognizeText, .exportText, .exportImages:
            return true
        }
    }

    var isDefaultQuickAccess: Bool {
        switch self {
        case .organizePages, .compressPDF, .signPDF, .safeShare:
            return true
        default:
            return false
        }
    }

    var searchAliases: String {
        switch self {
        case .scanToPDF:
            return "camera capture digitize paper 扫描 拍照 纸质"
        case .imagesToPDF:
            return "photos pictures jpg jpeg convert 照片 图片 转pdf"
        case .mergePDFs:
            return "combine join append 合并 拼接"
        case .splitPDF:
            return "extract separate pages 拆分 拆页 提取页面"
        case .organizePages:
            return "reorder number paginate bates stamp watermark rotate crop delete sort 页面 页码 连续编号 水印 排序 旋转 裁切 删除"
        case .compressPDF:
            return "smaller shrink reduce size optimize too large attachment message 瘦身 压缩 变小 太大 发邮件 发微信"
        case .fillForms:
            return "form field type complete 表单 填写 填表"
        case .signPDF:
            return "signature autograph sign here 签名 签字"
        case .redactPDF:
            return "remove hide sensitive blackout mask 打码 遮挡 脱敏 隐私"
        case .protectPDF:
            return "password encrypt lock 加密 密码 上锁"
        case .safeShare:
            return "send share finish flatten clean metadata verify secure delivery ready final 发出去 发送 分享 扁平化 清理 检查 交付 最终版"
        case .recognizeText:
            return "recognise vision image text scan searchable copy 文字识别 扫描件 可搜索 搜文字"
        case .exportText:
            return "docx xlsx pptx word excel powerpoint text office convert 导出 转换"
        case .exportImages:
            return "png jpg render pages 导出图片 转图片"
        }
    }

    func matchScore(_ query: String) -> Int? {
        let normalizedQuery = Self.normalizedSearchText(query)
        let terms = SearchTextNormalizer.meaningfulTerms(in: query)
        guard !terms.isEmpty else { return nil }

        let normalizedTitle = Self.normalizedSearchText(title)
        let searchableText = Self.normalizedSearchText(
            "\(title) \(detail) \(group.title) \(searchAliases)"
        )
        let matchedTermCount = terms.reduce(into: 0) { count, term in
            if searchableText.contains(term) {
                count += 1
            }
        }
        let intentHitCount = SearchTextNormalizer.intentHitCount(
            query: normalizedQuery,
            searchableText: searchableText
        )
        guard matchedTermCount == terms.count || intentHitCount > 0 else {
            return nil
        }
        if normalizedTitle == normalizedQuery { return 100 }
        if normalizedTitle.hasPrefix(normalizedQuery) { return 80 }
        if normalizedTitle.contains(normalizedQuery) { return 60 }
        return 30 + matchedTermCount * 8 + min(intentHitCount, 3) * 6
    }

    func matches(_ query: String) -> Bool {
        matchScore(query) != nil
    }

    func supports(_ record: DocumentRecord) -> Bool {
        switch self {
        case .splitPDF, .organizePages:
            return record.profile.pageCount > 1 && !record.profile.isLocked
        case .fillForms:
            return record.profile.kind == .form && !record.profile.isLocked
        case .recognizeText:
            return (
                record.profile.kind == .scan
                    || record.profile.kind == .mixed
            ) && !record.profile.isLocked
        case .redactPDF:
            return record.profile.kind != .scan && !record.profile.isLocked
        case .compressPDF, .signPDF, .protectPDF, .safeShare,
             .exportText, .exportImages:
            return !record.profile.isLocked
        case .scanToPDF, .imagesToPDF, .mergePDFs:
            return true
        }
    }

    func compatibilityNote(for record: DocumentRecord) -> String {
        switch self {
        case .splitPDF:
            return "\(record.profile.pageCount) pages ready to extract"
        case .organizePages:
            return "\(record.profile.pageCount) pages ready to organize"
        case .fillForms:
            return "\(record.profile.formFieldCount) interactive field\(record.profile.formFieldCount == 1 ? "" : "s")"
        case .recognizeText:
            return "Image-based pages detected"
        case .compressPDF:
            return "\(record.profile.formattedSize) working copy"
        case .safeShare:
            return "Ready for verified delivery"
        case .signPDF:
            return record.brief?.category == .contract
                ? "Contract signature workflow"
                : "Ready for signature"
        case .redactPDF:
            return "Selectable text available"
        case .protectPDF:
            return "Ready for password protection"
        case .exportText:
            return "Office and text formats are created locally"
        case .exportImages:
            return "\(record.profile.pageCount) page\(record.profile.pageCount == 1 ? "" : "s") to render"
        case .scanToPDF, .imagesToPDF, .mergePDFs:
            return detail
        }
    }

    private static func normalizedSearchText(_ value: String) -> String {
        SearchTextNormalizer.normalize(value)
    }
}

enum PDFTaskPackage: String, CaseIterable, Identifiable, Hashable {
    case prepareToSend
    case makeSearchable
    case convertForWork
    case compressForEmail
    case redactAndProve
    case fixPages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prepareToSend: return "Finish & share"
        case .makeSearchable: return "Make searchable"
        case .convertForWork: return "Use in Office"
        case .compressForEmail: return "Fit for email"
        case .redactAndProve: return "Hide private info"
        case .fixPages: return "Fix pages"
        }
    }

    var detail: String {
        switch self {
        case .prepareToSend: return "Fill, sign, verify"
        case .makeSearchable: return "Read scanned pages"
        case .convertForWork:
            return "Word, Excel, or PowerPoint"
        case .compressForEmail: return "Create a smaller copy"
        case .redactAndProve: return "Remove, then verify"
        case .fixPages:
            return "Reorder, crop, extract"
        }
    }

    var symbol: String {
        switch self {
        case .prepareToSend: return "checkmark.shield"
        case .makeSearchable: return "text.viewfinder"
        case .convertForWork: return "doc.badge.arrow.up"
        case .compressForEmail:
            return "arrow.down.right.and.arrow.up.left"
        case .redactAndProve: return "eye.slash"
        case .fixPages: return "square.grid.2x2"
        }
    }

    var defaultTask: PDFQuickTask {
        switch self {
        case .prepareToSend: return .safeShare
        case .makeSearchable: return .recognizeText
        case .convertForWork: return .exportText
        case .compressForEmail: return .compressPDF
        case .redactAndProve: return .redactPDF
        case .fixPages: return .organizePages
        }
    }

    var searchAliases: String {
        switch self {
        case .prepareToSend:
            return "send share finish sign form clean verify batch multiple several ready final 发出去 发送 分享 签字 填表 检查 批量 多份 最终版"
        case .makeSearchable:
            return "ocr scan search text searchable find words 扫描 识别 搜索 文字 可搜索 搜文字"
        case .convertForWork:
            return "office word excel powerpoint docx xlsx pptx editable convert 办公 转换 可编辑"
        case .compressForEmail:
            return "email mail message attachment small size compress shrink 邮件 微信 附件 太大 压缩 变小"
        case .redactAndProve:
            return "privacy sensitive redact hide remove 脱敏 隐私 打码 删除"
        case .fixPages:
            return "pages reorder number bates stamp watermark rotate crop split extract 页面 排序 页码 连续编号 水印 旋转 裁切 拆分"
        }
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        let terms = SearchTextNormalizer.meaningfulTerms(in: query)
        guard !terms.isEmpty else { return false }
        let text = SearchTextNormalizer.normalize(
            "\(title) \(detail) \(searchAliases)"
        )
        return terms.allSatisfy(text.contains)
            || SearchTextNormalizer.intentHitCount(
                query: normalizedQuery,
                searchableText: text
            ) > 0
    }

    func supports(_ record: DocumentRecord) -> Bool {
        guard !record.profile.isLocked else { return false }
        switch self {
        case .prepareToSend, .convertForWork, .compressForEmail:
            return true
        case .makeSearchable:
            return record.profile.kind == .scan
                || record.profile.kind == .mixed
        case .redactAndProve:
            return record.profile.kind != .scan
        case .fixPages:
            return record.profile.pageCount > 1
        }
    }
}

struct PDFTaskPackagePlanner {
    struct Recommendation: Equatable {
        let package: PDFTaskPackage
        let task: PDFQuickTask
        let reason: String
        var resumeStage: DocumentTaskStage? = nil

        var title: String {
            if let resumeStage {
                return resumeStage.title
            }
            if reason == "Verified copy ready" {
                return "Share verified PDF"
            }
            if reason == "Output changed since verification" {
                return "Verify changed output"
            }
            if task == .fillForms {
                return "Fill Form"
            }
            return task.title
        }
    }

    static func homePackages(
        for records: [DocumentRecord]
    ) -> [PDFTaskPackage] {
        guard !records.isEmpty else {
            return [
                .prepareToSend,
                .makeSearchable,
                .convertForWork,
                .compressForEmail,
                .fixPages
            ]
        }

        var packages: [PDFTaskPackage] = []
        func append(
            _ package: PDFTaskPackage,
            when condition: Bool = true
        ) {
            guard condition,
                  !packages.contains(package),
                  records.contains(where: package.supports)
            else { return }
            packages.append(package)
        }

        append(
            .prepareToSend,
            when: records.contains {
                $0.workflowStatus == .ready
                    || $0.profile.kind == .form
                    || $0.brief?.category == .contract
                    || $0.completedActions.contains(.sign)
                    || $0.completedActions.contains(.reviewForm)
            }
        )
        append(
            .makeSearchable,
            when: records.contains {
                $0.profile.kind == .scan || $0.profile.kind == .mixed
            }
        )
        append(
            .convertForWork,
            when: records.contains {
                !$0.profile.isLocked
                    && $0.profile.textCoverage > 0.12
            }
        )
        append(
            .compressForEmail,
            when: records.contains { $0.profile.byteCount >= 8_000_000 }
        )
        append(
            .redactAndProve,
            when: records.contains {
                $0.brief?.sensitiveEntityCount ?? 0 > 0
            }
        )
        append(
            .fixPages,
            when: records.contains { $0.profile.pageCount > 1 }
        )

        for fallback in PDFTaskPackage.allCases
        where !packages.contains(fallback)
            && records.contains(where: fallback.supports) {
            packages.append(fallback)
        }
        return Array(packages.prefix(5))
    }

    static func recommendation(
        for record: DocumentRecord,
        hasRecognizedText: Bool
    ) -> Recommendation? {
        if record.isDeliveryArtifact {
            return Recommendation(
                package: .prepareToSend,
                task: .safeShare,
                reason: record.hasCurrentDeliveryReceipt
                    ? "Verified copy ready"
                    : "Output changed since verification"
            )
        }

        guard !record.profile.isLocked else { return nil }

        if let checkpoint = record.taskCheckpoint {
            return Recommendation(
                package: .prepareToSend,
                task: checkpoint.stage.quickTask,
                reason: checkpoint.resumeReason,
                resumeStage: checkpoint.stage
            )
        }

        if record.profile.kind == .form,
           !record.completedActions.contains(.reviewForm) {
            return Recommendation(
                package: .prepareToSend,
                task: .fillForms,
                reason: "Complete the form"
            )
        }

        if record.brief?.category == .contract,
           !record.completedActions.contains(.sign) {
            return Recommendation(
                package: .prepareToSend,
                task: .signPDF,
                reason: "Signature may be needed"
            )
        }

        if record.profile.kind == .scan || record.profile.kind == .mixed {
            if !hasRecognizedText {
                return Recommendation(
                    package: .makeSearchable,
                    task: .recognizeText,
                    reason: "Image-based pages"
                )
            }
        }

        if record.completedActions.contains(.sign)
            || record.completedActions.contains(.reviewForm)
            || record.workflowStatus == .ready {
            return Recommendation(
                package: .prepareToSend,
                task: .safeShare,
                reason: "Check before sharing"
            )
        }

        if record.profile.byteCount >= 8_000_000 {
            return Recommendation(
                package: .compressForEmail,
                task: .compressPDF,
                reason: "Large working copy"
            )
        }

        if record.brief?.sensitiveEntityCount ?? 0 > 0,
           record.profile.kind != .scan {
            let lowConfidence = record.brief?.resolvedConfidence == .low
            return Recommendation(
                package: .redactAndProve,
                task: .redactPDF,
                reason: lowConfidence
                    ? "Review possible private details"
                    : "Private details found"
            )
        }

        if record.profile.pageCount > 1 {
            return Recommendation(
                package: .fixPages,
                task: .organizePages,
                reason: "\(record.profile.pageCount) pages"
            )
        }

        return Recommendation(
            package: .prepareToSend,
            task: .safeShare,
            reason: record.hasCurrentDeliveryReceipt
                ? "Verified copy"
                : "Check before sharing"
        )
    }

    static func task(
        for package: PDFTaskPackage,
        record: DocumentRecord
    ) -> PDFQuickTask {
        if package == .prepareToSend {
            if let checkpoint = record.taskCheckpoint {
                return checkpoint.stage.quickTask
            }
            if record.profile.kind == .form,
               !record.completedActions.contains(.reviewForm) {
                return .fillForms
            }
            if record.brief?.category == .contract,
               !record.completedActions.contains(.sign) {
                return .signPDF
            }
        }
        return package.defaultTask
    }
}

struct PDFQuickTaskPlanner {
    static func quickAccess(
        for records: [DocumentRecord]
    ) -> [PDFQuickTask] {
        if records.isEmpty {
            return [
                .scanToPDF,
                .imagesToPDF,
                .mergePDFs,
                .compressPDF
            ]
        }

        var tasks: [PDFQuickTask] = []

        func append(_ task: PDFQuickTask, when condition: Bool = true) {
            guard condition, !tasks.contains(task) else { return }
            guard records.isEmpty || records.contains(where: task.supports)
            else { return }
            tasks.append(task)
        }

        append(
            .fillForms,
            when: records.contains {
                $0.profile.kind == .form
                    && !$0.completedActions.contains(.reviewForm)
            }
        )
        append(
            .recognizeText,
            when: records.contains {
                ($0.profile.kind == .scan || $0.profile.kind == .mixed)
                    && !$0.completedActions.contains(.recognizeText)
            }
        )
        append(
            .organizePages,
            when: records.contains { $0.profile.pageCount > 1 }
        )

        for fallback in [
            PDFQuickTask.signPDF,
            .safeShare,
            .compressPDF,
            .protectPDF,
            .exportText,
            .organizePages
        ] {
            append(fallback)
        }
        return Array(tasks.prefix(4))
    }
}

private enum SearchTextNormalizer {
    private static let ignoredTerms: Set<String> = [
        "a", "an", "and", "can", "could", "do", "document", "file",
        "for", "help", "i", "in", "into", "it", "me", "my", "of",
        "on", "or", "pdf", "please", "the", "this", "to", "want",
        "with", "you"
    ]
    private static let weakIntentTerms: Set<String> = ignoredTerms.union([
        "create", "make", "open", "tool", "tools"
    ])

    static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    static func meaningfulTerms(in value: String) -> [String] {
        normalize(value)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter {
                $0.count > 1 && !ignoredTerms.contains($0)
            }
    }

    static func intentHitCount(
        query normalizedQuery: String,
        searchableText: String
    ) -> Int {
        guard !normalizedQuery.isEmpty else { return 0 }
        let tokens = Set(
            searchableText
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter {
                    $0.count > 1 && !weakIntentTerms.contains($0)
                }
        )
        return tokens.reduce(into: 0) { count, token in
            if normalizedQuery.contains(token) {
                count += 1
            }
        }
    }
}

enum PDFExportFocus: Hashable {
    case safeShare
    case text
    case images
}

enum PDFTextExportFormat:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Sendable {
    case wordDocument
    case excelWorkbook
    case powerPointPresentation
    case richText
    case markdown
    case plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wordDocument: return "Word Document"
        case .excelWorkbook: return "Excel Workbook"
        case .powerPointPresentation: return "PowerPoint Presentation"
        case .richText: return "Rich Text"
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        }
    }

    var detail: String {
        switch self {
        case .wordDocument:
            return "Editable paragraphs and tables with visual page references"
        case .excelWorkbook:
            return "Page worksheets with detected rows, columns, and numeric cells"
        case .powerPointPresentation:
            return "One high-fidelity slide per page with searchable text"
        case .richText:
            return "Word-compatible RTF with page headings"
        case .markdown:
            return "Structured headings in a portable Markdown file"
        case .plainText:
            return "Simple UTF-8 text with page boundaries"
        }
    }

    var symbol: String {
        switch self {
        case .wordDocument: return "doc.text"
        case .excelWorkbook: return "tablecells"
        case .powerPointPresentation:
            return "rectangle.on.rectangle.angled"
        case .richText: return "doc.richtext"
        case .markdown: return "text.document"
        case .plainText: return "doc.plaintext"
        }
    }

    var fileExtension: String {
        switch self {
        case .wordDocument: return "docx"
        case .excelWorkbook: return "xlsx"
        case .powerPointPresentation: return "pptx"
        case .richText: return "rtf"
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    var editabilityIntent: String {
        switch self {
        case .wordDocument: return "Structured"
        case .excelWorkbook: return "Cells"
        case .powerPointPresentation: return "Text layer"
        case .richText: return "Paragraphs"
        case .markdown: return "Plain structure"
        case .plainText: return "Raw text"
        }
    }

    var appearanceIntent: String {
        switch self {
        case .wordDocument: return "Referenced"
        case .excelWorkbook: return "Rebuilt"
        case .powerPointPresentation: return "High"
        case .richText: return "Basic"
        case .markdown, .plainText: return "None"
        }
    }

    var sizeIntent: String {
        switch self {
        case .wordDocument: return "Moderate"
        case .excelWorkbook: return "Compact"
        case .powerPointPresentation: return "Larger"
        case .richText: return "Compact"
        case .markdown, .plainText: return "Small"
        }
    }

    var bestFor: String {
        switch self {
        case .wordDocument:
            return "Paragraphs, headings, and detected tables"
        case .excelWorkbook:
            return "Rows, columns, values, and page-separated sheets"
        case .powerPointPresentation:
            return "Page appearance with searchable slide text"
        case .richText:
            return "Simple styled text in Word-compatible apps"
        case .markdown:
            return "Portable structured writing and developer workflows"
        case .plainText:
            return "Maximum compatibility and minimal file size"
        }
    }

    var officePageLimit: Int? {
        switch self {
        case .wordDocument, .excelWorkbook:
            return 1_000
        case .powerPointPresentation:
            return 500
        case .richText, .markdown, .plainText:
            return nil
        }
    }

    var isOfficeFormat: Bool {
        switch self {
        case .wordDocument, .excelWorkbook,
             .powerPointPresentation:
            return true
        case .richText, .markdown, .plainText:
            return false
        }
    }
}

enum PDFOfficeExportReadiness:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case strong
    case review
    case limited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strong: return "Strong"
        case .review: return "Review"
        case .limited: return "Limited"
        }
    }

    var symbol: String {
        switch self {
        case .strong: return "checkmark.circle.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .limited: return "xmark.octagon.fill"
        }
    }
}

enum PDFOfficeExportStage:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case analyze
    case rebuild
    case package
    case verify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .analyze: return "Analyze"
        case .rebuild: return "Rebuild"
        case .package: return "Package"
        case .verify: return "Verify"
        }
    }

    var symbol: String {
        switch self {
        case .analyze: return "doc.text.magnifyingglass"
        case .rebuild: return "square.3.layers.3d"
        case .package: return "shippingbox"
        case .verify: return "checkmark.seal"
        }
    }

    var threshold: Double {
        switch self {
        case .analyze: return 0
        case .rebuild: return 0.08
        case .package: return 0.68
        case .verify: return 0.88
        }
    }

    static func current(
        fractionCompleted: Double
    ) -> PDFOfficeExportStage {
        allCases.last {
            fractionCompleted >= $0.threshold
        } ?? .analyze
    }
}

enum PDFOfficeExportFailureKind: Hashable, Sendable {
    case sourceLimit
    case rights
    case missingText
    case busy
    case storage
    case verification
    case sourceChanged
    case unavailableArtifact
    case unknown

    var title: String {
        switch self {
        case .sourceLimit: return "Split source before export"
        case .rights: return "Source rights block reconstruction"
        case .missingText: return "Run OCR before editable export"
        case .busy: return "This PDF is already processing"
        case .storage: return "Free local storage and retry"
        case .verification: return "Output did not pass verification"
        case .sourceChanged: return "Source changed during export"
        case .unavailableArtifact: return "Rebuild this Office output"
        case .unknown: return "Office export stopped"
        }
    }

    var symbol: String {
        switch self {
        case .sourceLimit: return "rectangle.split.3x1"
        case .rights: return "lock.trianglebadge.exclamationmark"
        case .missingText: return "text.viewfinder"
        case .busy: return "hourglass"
        case .storage: return "externaldrive.badge.xmark"
        case .verification: return "xmark.seal.fill"
        case .sourceChanged: return "arrow.triangle.2.circlepath"
        case .unavailableArtifact: return "clock.arrow.circlepath"
        case .unknown: return "exclamationmark.triangle.fill"
        }
    }

    var allowsRetry: Bool {
        switch self {
        case .rights, .sourceLimit, .missingText:
            return false
        case .busy, .storage, .verification, .sourceChanged,
             .unavailableArtifact, .unknown:
            return true
        }
    }

    var recoveryTask: PDFQuickTask? {
        switch self {
        case .sourceLimit:
            return .splitPDF
        case .missingText:
            return .recognizeText
        case .rights, .busy, .storage, .verification,
             .sourceChanged, .unavailableArtifact, .unknown:
            return nil
        }
    }
}

struct PDFOfficeExportFailure: Hashable, Sendable {
    let format: PDFTextExportFormat
    let kind: PDFOfficeExportFailureKind
    let detail: String

    static func sourceLimit(
        format: PDFTextExportFormat,
        pageCount: Int
    ) -> PDFOfficeExportFailure {
        PDFOfficeExportFailure(
            format: format,
            kind: .sourceLimit,
            detail: AppLocalization.format(
                "%lld pages exceed the %@ limit. Split into controlled segments before rebuilding.",
                pageCount,
                format.fileExtension.uppercased()
            )
        )
    }

    static func unavailableArtifact(
        format: PDFTextExportFormat
    ) -> PDFOfficeExportFailure {
        PDFOfficeExportFailure(
            format: format,
            kind: .unavailableArtifact,
            detail: "The retained file expired or belongs to an older source revision. Rebuild to create a current copy."
        )
    }

    static func classify(
        format: PDFTextExportFormat,
        error: Error
    ) -> PDFOfficeExportFailure {
        let kind: PDFOfficeExportFailureKind
        switch error {
        case PaperPathError.lockedPDF,
             PaperPathError.unreadablePDF:
            kind = .rights
        case PaperPathError.missingRecognizedText:
            kind = .missingText
        case PaperPathError.insufficientStorage:
            kind = .storage
        case PaperPathError.fileTooLarge:
            kind = .sourceLimit
        case PaperPathError.outputVerificationFailed(let reason):
            kind = reason.localizedCaseInsensitiveContains("source changed")
                ? .sourceChanged
                : .verification
        case PaperPathError.insufficientSelection(let detail):
            if detail.localizedCaseInsensitiveContains("already")
                || detail.localizedCaseInsensitiveContains("paused")
                || detail.localizedCaseInsensitiveContains("temperature") {
                kind = .busy
            } else if detail.localizedCaseInsensitiveContains("page")
                        || detail.localizedCaseInsensitiveContains("limit") {
                kind = .sourceLimit
            } else {
                kind = .unknown
            }
        case PaperPathError.storageFailure:
            kind = .storage
        default:
            kind = .unknown
        }
        return PDFOfficeExportFailure(
            format: format,
            kind: kind,
            detail: AppLocalization
                .userFacingErrorDescription(error)
        )
    }
}

enum PDFOfficeArtifactAvailability: Hashable, Sendable {
    case reusable
    case sourceChanged
    case expired
    case unavailable

    var title: String {
        switch self {
        case .reusable: return "Ready to share"
        case .sourceChanged: return "Source changed"
        case .expired: return "File expired"
        case .unavailable: return "Receipt only"
        }
    }

    var symbol: String {
        switch self {
        case .reusable: return "arrowshape.turn.up.right.fill"
        case .sourceChanged: return "arrow.triangle.2.circlepath"
        case .expired: return "clock.badge.exclamationmark"
        case .unavailable: return "doc.text.magnifyingglass"
        }
    }
}

struct PDFOfficeContentNotice: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case wordReconstruction, spreadsheetTextOnly, slideImages
        case pagesWithoutText, missingVisualReferences, inferredTableLayout

        var title: String {
            switch self {
            case .wordReconstruction: return "Word layout rebuilt"
            case .spreadsheetTextOnly: return "Spreadsheet contains extracted text and values"
            case .slideImages: return "Slides contain page images"
            case .pagesWithoutText: return "Pages without extracted text"
            case .missingVisualReferences: return "Page reference images not included"
            case .inferredTableLayout: return "Table positions need review"
            }
        }

        var detail: String {
            switch self {
            case .wordReconstruction:
                return "Check paragraph order and numbering. Number labels remain text; headers and footers are ordinary paragraphs. Images, when included, are page references rather than editable objects."
            case .spreadsheetTextOnly:
                return "Charts, images and conditional formatting are not included. Formulas and pivot-table relationships are not recovered. Check headers and values against the source PDF."
            case .slideImages:
                return "Page appearance is preserved as images, not editable shapes or tables. Extracted text is stored separately; search and re-export support varies by Office app."
            case .pagesWithoutText:
                return "These source pages produced no text cells. Their worksheets are empty; check the source PDF for images or other content."
            case .missingVisualReferences:
                return "Reference images could not be included within the rendering or storage limit. Check these pages in the source PDF."
            case .inferredTableLayout:
                return "Some cell positions were inferred without reliable table boundaries. Check empty cells, merged headers and right-aligned values."
            }
        }
    }

    let kind: Kind
    var pageIndices: [Int] = []
    var id: String { kind.rawValue }

    static func defaults(for format: PDFTextExportFormat) -> [Self] {
        switch format {
        case .wordDocument: return [Self(kind: .wordReconstruction)]
        case .excelWorkbook: return [Self(kind: .spreadsheetTextOnly)]
        case .powerPointPresentation: return [Self(kind: .slideImages)]
        default: return []
        }
    }

    func pageSummary(offset: Int = 0) -> String? {
        guard !pageIndices.isEmpty else { return nil }
        let pages = Array(Set(pageIndices.filter { $0 >= 0 })).sorted()
        guard !pages.isEmpty else { return nil }
        var ranges: [String] = []
        var start = pages[0]
        var end = start
        for page in pages.dropFirst() {
            if page == end + 1 { end = page; continue }
            ranges.append(start == end ? "\(start + offset + 1)" : "\(start + offset + 1)-\(end + offset + 1)")
            start = page
            end = page
        }
        ranges.append(start == end ? "\(start + offset + 1)" : "\(start + offset + 1)-\(end + offset + 1)")
        return AppLocalization.format("Source pages: %@", ranges.joined(separator: ", "))
    }
}

struct PDFOfficeRuntimeEvidence:
    Codable,
    Hashable,
    Sendable {
    let sourcePageCount: Int
    let outputPageCount: Int
    let primaryUnitLabel: String
    let primaryUnitCount: Int
    let characterCount: Int
    let searchablePageCount: Int
    let assetCount: Int
    let assetByteCount: Int
    let assetBudgetByteCount: Int
    let assetCompressionFallbackCount: Int
    let assetMinimumQualityPercent: Int
    var contentNotices: [PDFOfficeContentNotice]? = nil

    var pageYieldPercent: Int {
        percentage(outputPageCount, of: sourcePageCount)
    }

    var searchableCoveragePercent: Int {
        percentage(searchablePageCount, of: outputPageCount)
    }

    var assetBudgetUsePercent: Int {
        percentage(assetByteCount, of: assetBudgetByteCount)
    }

    var formattedAssetBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(assetByteCount),
            countStyle: .file
        )
    }

    var formattedAssetBudget: String {
        guard assetBudgetByteCount > 0 else { return "No visual budget" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(assetBudgetByteCount),
            countStyle: .file
        )
    }

    var yieldSummary: String {
        AppLocalization.format(
            "%lld/%lld pages · %lld%% yield",
            outputPageCount,
            sourcePageCount,
            pageYieldPercent
        )
    }

    private func percentage(
        _ value: Int,
        of total: Int
    ) -> Int {
        guard total > 0 else { return 0 }
        return min(
            100,
            max(
                0,
                Int(
                    (
                        Double(value)
                            / Double(total)
                            * 100
                    ).rounded()
                )
            )
        )
    }
}

struct PDFTextExportArtifact: Sendable {
    let url: URL
    let runtimeEvidence: PDFOfficeRuntimeEvidence?
    let sourceProfile: DocumentProfile
}

struct PDFOfficeBatchSegment:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: UUID
    let index: Int
    let startPageIndex: Int
    let endPageIndex: Int

    init(
        id: UUID = UUID(),
        index: Int,
        startPageIndex: Int,
        endPageIndex: Int
    ) {
        self.id = id
        self.index = index
        self.startPageIndex = startPageIndex
        self.endPageIndex = endPageIndex
    }

    var pageCount: Int {
        max(0, endPageIndex - startPageIndex + 1)
    }

    var pageIndices: [Int] {
        guard pageCount > 0 else { return [] }
        return Array(startPageIndex...endPageIndex)
    }

    var pageRangeLabel: String {
        AppLocalization.format(
            "Pages %lld-%lld",
            startPageIndex + 1,
            endPageIndex + 1
        )
    }
}

struct PDFOfficeBatchPlan:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    static let maximumPageCount = 100_000
    static let maximumSegmentCount = 64

    let id: UUID
    let format: PDFTextExportFormat
    let sourceRevisionID: UUID
    let sourcePageCount: Int
    let segmentPageTarget: Int
    let segments: [PDFOfficeBatchSegment]
    let createdAt: Date

    init(
        format: PDFTextExportFormat,
        sourceRevisionID: UUID,
        profile: DocumentProfile
    ) {
        id = UUID()
        self.format = format
        self.sourceRevisionID = sourceRevisionID
        sourcePageCount = max(0, profile.pageCount)
        createdAt = PDFOfficeTimeAnchor.process.trustedDate()

        let visualTarget = PDFOfficeVisualBudgetPlan(
            profile: profile
        ).recommendedChunkSize
        let formatLimit = format.officePageLimit ?? max(
            1,
            profile.pageCount
        )
        let receiptWindowTarget = Int(
            ceil(Double(max(1, profile.pageCount)) / 64)
        )
        segmentPageTarget = max(
            1,
            min(
                max(1, profile.pageCount),
                formatLimit,
                max(visualTarget, receiptWindowTarget)
            )
        )

        var planned: [PDFOfficeBatchSegment] = []
        var start = 0
        while start < profile.pageCount {
            let end = min(
                profile.pageCount - 1,
                start + segmentPageTarget - 1
            )
            planned.append(
                PDFOfficeBatchSegment(
                    index: planned.count,
                    startPageIndex: start,
                    endPageIndex: end
                )
            )
            start = end + 1
        }
        segments = planned
    }

    var segmentCount: Int {
        segments.count
    }

    var isBatchRequired: Bool {
        segmentCount > 1
    }

    var summary: String {
        AppLocalization.format(
            "%lld parts · up to %lld pages each",
            segmentCount,
            segmentPageTarget
        )
    }

    func isStructurallyValid(
        at date: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> Bool {
        guard format.isOfficeFormat,
              (1...Self.maximumPageCount).contains(sourcePageCount),
              (1...sourcePageCount).contains(segmentPageTarget),
              PDFEvidenceContract.isPlausiblePastDate(
                  createdAt,
                  now: date
              ),
              !segments.isEmpty,
              segments.count <= Self.maximumSegmentCount,
              Set(segments.map(\.id)).count == segments.count
        else { return false }

        var expectedStartPage = 0
        for (offset, segment) in segments.enumerated() {
            guard segment.index == offset,
                  segment.startPageIndex == expectedStartPage,
                  segment.endPageIndex >= segment.startPageIndex,
                  segment.endPageIndex < sourcePageCount,
                  segment.pageCount <= segmentPageTarget
            else { return false }
            expectedStartPage = segment.endPageIndex + 1
        }
        return expectedStartPage == sourcePageCount
    }
}

enum PDFOfficeBatchSegmentStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case queued
    case extracting
    case rebuilding
    case retaining
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .extracting: return "Extracting"
        case .rebuilding: return "Rebuilding"
        case .retaining: return "Retaining"
        case .completed: return "Ready"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "circle.dotted"
        case .extracting: return "rectangle.split.3x1"
        case .rebuilding: return "square.3.layers.3d"
        case .retaining: return "internaldrive"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .extracting, .rebuilding, .retaining:
            return false
        }
    }
}

struct PDFOfficeBatchSegmentResult:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let segment: PDFOfficeBatchSegment
    var status: PDFOfficeBatchSegmentStatus
    var fractionCompleted: Double
    var receiptID: UUID?
    var failureDetail: String?

    var id: UUID { segment.id }
}

enum PDFOfficeBatchStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case preparing
    case running
    case paused
    case completed
    case partial
    case failed
    case cancelled

    var title: String {
        switch self {
        case .preparing: return "Planning"
        case .running: return "Exporting"
        case .paused: return "Ready to resume"
        case .completed: return "Batch ready"
        case .partial: return "Review batch"
        case .failed: return "Batch stopped"
        case .cancelled: return "Batch cancelled"
        }
    }
}

struct PDFOfficeBatchRun:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: UUID
    let plan: PDFOfficeBatchPlan
    let startedAt: Date
    var completedAt: Date?
    var status: PDFOfficeBatchStatus
    var segments: [PDFOfficeBatchSegmentResult]

    init(plan: PDFOfficeBatchPlan) {
        id = plan.id
        self.plan = plan
        startedAt = PDFOfficeTimeAnchor.process.trustedDate()
        completedAt = nil
        status = .preparing
        segments = plan.segments.map {
            PDFOfficeBatchSegmentResult(
                segment: $0,
                status: .queued,
                fractionCompleted: 0,
                receiptID: nil,
                failureDetail: nil
            )
        }
    }

    var completedCount: Int {
        segments.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        segments.filter { $0.status == .failed }.count
    }

    var fractionCompleted: Double {
        guard !segments.isEmpty else { return 0 }
        return segments.reduce(0) {
            let fraction = $1.fractionCompleted.isFinite
                ? min(1, max(0, $1.fractionCompleted))
                : 0
            return $0 + fraction
        } / Double(segments.count)
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    var isFinished: Bool {
        switch status {
        case .completed, .partial, .failed, .cancelled:
            return true
        case .preparing, .running, .paused:
            return false
        }
    }

    func isStructurallyValid(
        at date: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> Bool {
        guard id == plan.id,
              plan.isStructurallyValid(at: date),
              PDFEvidenceContract.isPlausiblePastDate(
                  startedAt,
                  now: date
              ),
              startedAt
                >= plan.createdAt.addingTimeInterval(
                    -PDFEvidenceContract.futureTolerance
                ),
              segments.count == plan.segments.count
        else { return false }
        if let completedAt {
            guard PDFEvidenceContract.isPlausiblePastDate(
                completedAt,
                now: date
            ),
                  completedAt >= startedAt
            else { return false }
        }
        for (expected, result) in zip(plan.segments, segments) {
            let failureDetailIsValid = result.failureDetail.map {
                PDFEvidenceContract.isSafeDisplayText(
                    $0,
                    maximumCharacters: 2_000,
                    maximumUTF8Bytes: 8_000
                )
            } ?? true
            guard result.segment == expected,
                  result.fractionCompleted.isFinite,
                  (0...1).contains(result.fractionCompleted),
                  failureDetailIsValid,
                  result.status != .completed
                    || result.receiptID != nil
            else { return false }
        }
        switch status {
        case .preparing, .running, .paused:
            return completedAt == nil
        case .completed:
            return completedAt != nil
                && completedCount == segments.count
        case .partial:
            return completedAt != nil
                && completedCount > 0
                && completedCount < segments.count
        case .failed, .cancelled:
            return completedAt != nil && completedCount == 0
        }
    }

    var retryableSegmentIDs: Set<UUID> {
        Set(
            segments.compactMap { result in
                switch result.status {
                case .completed, .extracting, .rebuilding, .retaining:
                    return nil
                case .queued, .failed, .cancelled:
                    return result.id
                }
            }
        )
    }

    func reconcilingArtifacts(
        currentRevisionID: UUID,
        availableReceiptIDs: Set<UUID>
    ) -> PDFOfficeBatchRun {
        var reconciled = self
        var lostCompletedArtifact = false
        var claimedReceiptIDs = Set<UUID>()
        for index in reconciled.segments.indices {
            guard reconciled.segments[index].status == .completed else {
                reconciled.segments[index].receiptID = nil
                continue
            }
            guard
                  let receiptID = reconciled.segments[index].receiptID,
                  availableReceiptIDs.contains(receiptID),
                  claimedReceiptIDs.insert(receiptID).inserted
            else {
                reconciled.segments[index].status = .failed
                reconciled.segments[index].fractionCompleted = 0
                reconciled.segments[index].receiptID = nil
                reconciled.segments[index].failureDetail =
                    "The retained file for this part is no longer available. Retry to rebuild it."
                lostCompletedArtifact = true
                continue
            }
        }

        guard plan.sourceRevisionID == currentRevisionID else {
            for index in reconciled.segments.indices {
                reconciled.segments[index].status = .failed
                reconciled.segments[index].fractionCompleted = 1
                reconciled.segments[index].receiptID = nil
                reconciled.segments[index].failureDetail =
                    "The source changed after this batch was created."
            }
            reconciled.completedAt = reconciled.completedAt
                ?? PDFOfficeTimeAnchor.process.trustedDate()
            reconciled.status = .failed
            return reconciled
        }

        if lostCompletedArtifact, reconciled.isFinished {
            reconciled.completedAt = reconciled.completedAt
                ?? PDFOfficeTimeAnchor.process.trustedDate()
            reconciled.status = reconciled.completedCount > 0
                ? .partial
                : .failed
        }
        return reconciled
    }

    func restored(
        currentRevisionID: UUID,
        availableReceiptIDs: Set<UUID>
    ) -> PDFOfficeBatchRun {
        var restored = reconcilingArtifacts(
            currentRevisionID: currentRevisionID,
            availableReceiptIDs: availableReceiptIDs
        )
        guard plan.sourceRevisionID == currentRevisionID else {
            return restored
        }
        guard status == .preparing || status == .running else {
            return restored
        }
        for index in restored.segments.indices {
            switch restored.segments[index].status {
            case .extracting, .rebuilding, .retaining:
                restored.segments[index].status = .queued
                restored.segments[index].fractionCompleted = 0
                restored.segments[index].receiptID = nil
                restored.segments[index].failureDetail =
                    "Interrupted before this part completed."
            case .queued:
                restored.segments[index].fractionCompleted = 0
            case .completed, .failed, .cancelled:
                break
            }
        }
        restored.completedAt = nil
        restored.status = .paused
        return restored
    }
}

enum PDFOfficeQueuePriority:
    Int,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case urgent = 0
    case normal = 1
    case background = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .urgent: return "Urgent"
        case .normal: return "Standard"
        case .background: return "Background"
        }
    }

    var symbol: String {
        switch self {
        case .urgent: return "arrow.up.circle.fill"
        case .normal: return "equal.circle.fill"
        case .background: return "arrow.down.circle.fill"
        }
    }
}

enum PDFOfficeQueueJobStage:
    String,
    Codable,
    Hashable,
    Sendable {
    case queued
    case analyzing
    case rebuilding
    case retaining
    case paused
    case completed
    case attention
    case cancelled

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing"
        case .rebuilding: return "Rebuilding"
        case .retaining: return "Retaining"
        case .paused: return "Paused"
        case .completed: return "Ready"
        case .attention: return "Needs attention"
        case .cancelled: return "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .analyzing: return "doc.text.magnifyingglass"
        case .rebuilding: return "square.3.layers.3d"
        case .retaining: return "internaldrive"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .analyzing, .rebuilding, .retaining:
            return true
        case .queued, .paused, .completed, .attention, .cancelled:
            return false
        }
    }

    var isPending: Bool {
        self == .queued || self == .paused
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .attention, .cancelled:
            return true
        case .queued, .analyzing, .rebuilding, .retaining, .paused:
            return false
        }
    }
}

struct PDFOfficeQueueJob:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: UUID
    let recordID: UUID
    let sourceRevisionID: UUID
    let sourceName: String
    let sourcePageCount: Int
    let format: PDFTextExportFormat
    var priority: PDFOfficeQueuePriority
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var stage: PDFOfficeQueueJobStage
    var receiptIDs: [UUID]
    var detail: String

    init(
        id: UUID = UUID(),
        recordID: UUID,
        sourceRevisionID: UUID,
        sourceName: String,
        sourcePageCount: Int,
        format: PDFTextExportFormat,
        priority: PDFOfficeQueuePriority,
        createdAt: Date =
            PDFOfficeTimeAnchor.process.trustedDate()
    ) {
        self.id = id
        self.recordID = recordID
        self.sourceRevisionID = sourceRevisionID
        self.sourceName = sourceName
        self.sourcePageCount = sourcePageCount
        self.format = format
        self.priority = priority
        self.createdAt = createdAt
        startedAt = nil
        completedAt = nil
        stage = .queued
        receiptIDs = []
        detail = "Waiting for local production"
    }

    var isBatch: Bool {
        format.officePageLimit.map {
            sourcePageCount > $0
        } ?? false
    }

    var routeLabel: String {
        AppLocalization.format(
            "%@ · %@",
            format.fileExtension.uppercased(),
            isBatch ? "Segmented" : "Single package"
        )
    }
}

struct PDFOfficeProductionQueue:
    Codable,
    Hashable,
    Sendable {
    var jobs: [PDFOfficeQueueJob]
    var updatedAt: Date
    var isSuspended: Bool

    init(
        jobs: [PDFOfficeQueueJob] = [],
        updatedAt: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        isSuspended: Bool = false
    ) {
        self.jobs = jobs
        self.updatedAt = updatedAt
        self.isSuspended = isSuspended
    }

    var pendingCount: Int {
        jobs.filter { $0.stage.isPending }.count
    }

    var completedCount: Int {
        jobs.filter { $0.stage == .completed }.count
    }

    var attentionCount: Int {
        jobs.filter { $0.stage == .attention }.count
    }

    var activeJob: PDFOfficeQueueJob? {
        jobs.first { $0.stage.isActive }
    }

    var hasRunnableJobs: Bool {
        !isSuspended && jobs.contains { $0.stage.isPending }
    }

    mutating func restoreInterruptedWork() {
        let wasSuspended = isSuspended
        for index in jobs.indices where jobs[index].stage.isActive {
            jobs[index].stage = .paused
            jobs[index].detail =
                "Interrupted safely. Resume to continue this job."
        }
        isSuspended = wasSuspended
            || jobs.contains { $0.stage == .paused }
        updatedAt = PDFOfficeTimeAnchor.process.trustedDate()
        boundHistory()
    }

    mutating func boundHistory() {
        let prioritized = jobs.sorted {
            let lhsDate = $0.completedAt
                ?? $0.startedAt
                ?? $0.createdAt
            let rhsDate = $1.completedAt
                ?? $1.startedAt
                ?? $1.createdAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        var seenIDs = Set<UUID>()
        let unique = prioritized.filter {
            seenIDs.insert($0.id).inserted
        }
        let active = unique.filter { !$0.stage.isTerminal }
        let recent = Array(
            unique
            .filter(\.stage.isTerminal)
            .sorted {
                ($0.completedAt ?? $0.createdAt)
                    > ($1.completedAt ?? $1.createdAt)
            }
            .prefix(40)
        )
        jobs = (active + recent).sorted {
            if $0.stage.isTerminal != $1.stage.isTerminal {
                return !$0.stage.isTerminal
            }
            if $0.stage.isTerminal {
                return ($0.completedAt ?? $0.createdAt)
                    > ($1.completedAt ?? $1.createdAt)
            }
            if $0.priority != $1.priority {
                return $0.priority.rawValue < $1.priority.rawValue
            }
            return $0.createdAt < $1.createdAt
        }
    }
}

enum PDFOfficeResourceMode:
    String,
    Codable,
    Hashable,
    Sendable {
    case ready
    case conserving
    case blocked

    var title: String {
        switch self {
        case .ready: return "Full speed"
        case .conserving: return "Conserving"
        case .blocked: return "Queue paused"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "bolt.fill"
        case .conserving: return "leaf.fill"
        case .blocked: return "thermometer.high"
        }
    }
}

enum PDFOfficeThermalLevel:
    String,
    Codable,
    Hashable,
    Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Device warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
}

struct PDFOfficeResourceSnapshot: Hashable, Sendable {
    let mode: PDFOfficeResourceMode
    let thermalLevel: PDFOfficeThermalLevel
    let isLowPowerModeEnabled: Bool
    let availableCapacityBytes: Int64?
    let capturedAt: Date
    let detail: String

    static let initial = PDFOfficeResourceSnapshot(
        mode: .ready,
        thermalLevel: .unknown,
        isLowPowerModeEnabled: false,
        availableCapacityBytes: nil,
        capturedAt: .distantPast,
        detail: "Checking device resources"
    )

    var formattedAvailableCapacity: String {
        guard let availableCapacityBytes else { return "Checking" }
        return ByteCountFormatter.string(
            fromByteCount: availableCapacityBytes,
            countStyle: .file
        )
    }

    var powerTitle: String {
        isLowPowerModeEnabled ? "Low Power" : "Standard"
    }
}

struct PDFOfficeStorageForecast: Hashable, Sendable {
    let sourceCount: Int
    let packageCount: Int
    let estimatedOutputBytes: Int64
    let requiredWorkingBytes: Int64
    let availableCapacityBytes: Int64?

    var formattedOutputBytes: String {
        ByteCountFormatter.string(
            fromByteCount: estimatedOutputBytes,
            countStyle: .file
        )
    }

    var formattedWorkingBytes: String {
        ByteCountFormatter.string(
            fromByteCount: requiredWorkingBytes,
            countStyle: .file
        )
    }

    var hasCapacity: Bool {
        guard let availableCapacityBytes else { return true }
        return availableCapacityBytes >= requiredWorkingBytes
    }

    var contract: String {
        AppLocalization.format(
            "%@ output · %@ peak · %@",
            formattedOutputBytes,
            formattedWorkingBytes,
            "streamed commit".localizedUI
        )
    }
}

enum PDFOfficeIntegrityStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case verified
    case missing
    case mismatch
    case sourceChanged

    var title: String {
        switch self {
        case .verified: return "Hash verified"
        case .missing: return "File missing"
        case .mismatch: return "Hash mismatch"
        case .sourceChanged: return "Source changed"
        }
    }

    var symbol: String {
        switch self {
        case .verified: return "checkmark.shield.fill"
        case .missing: return "questionmark.folder"
        case .mismatch: return "exclamationmark.shield.fill"
        case .sourceChanged: return "arrow.triangle.2.circlepath"
        }
    }

    var isVerified: Bool {
        self == .verified
    }
}

struct PDFOfficeIntegrityVerification: Hashable, Sendable {
    let recordID: UUID
    let record: DocumentRecord
    let receipt: PDFOfficeExportReceipt
    let status: PDFOfficeIntegrityStatus
    let url: URL?
}

struct PDFOfficeIntegrityReport: Hashable, Sendable {
    let checkedCount: Int
    let verifiedCount: Int
    let failedCount: Int
    let checkedAt: Date

    var isVerified: Bool {
        checkedCount > 0 && failedCount == 0
    }

    var summary: String {
        AppLocalization.format(
            "%lld/%lld outputs verified",
            verifiedCount,
            checkedCount
        )
    }
}

enum PDFByteProgressStage: String, Hashable, Sendable {
    case copying
    case reconstructing
    case packaging
    case checksumming
    case archiving
    case verifying

    var title: String {
        switch self {
        case .copying: return "Copying"
        case .reconstructing: return "Reconstructing"
        case .packaging: return "Building Office package"
        case .checksumming: return "Checksumming"
        case .archiving: return "Packaging ZIP"
        case .verifying: return "Verifying"
        }
    }

    var symbol: String {
        switch self {
        case .copying: return "doc.on.doc"
        case .reconstructing: return "doc.badge.gearshape"
        case .packaging: return "shippingbox"
        case .checksumming: return "number.square"
        case .archiving: return "archivebox"
        case .verifying: return "checkmark.shield"
        }
    }
}

struct PDFByteProgressUpdate: Hashable, Sendable {
    let stage: PDFByteProgressStage
    let processedBytes: Int64
    let totalBytes: Int64
    let completedUnitCount: Int
    let totalUnitCount: Int
    let currentUnitName: String

    init(
        stage: PDFByteProgressStage,
        processedBytes: Int64,
        totalBytes: Int64,
        completedUnitCount: Int = 0,
        totalUnitCount: Int = 0,
        currentUnitName: String = ""
    ) {
        self.stage = stage
        let boundedTotalBytes = max(0, totalBytes)
        self.totalBytes = boundedTotalBytes
        self.processedBytes = boundedTotalBytes > 0
            ? min(max(0, processedBytes), boundedTotalBytes)
            : max(0, processedBytes)
        let boundedTotalUnitCount = max(0, totalUnitCount)
        self.totalUnitCount = boundedTotalUnitCount
        self.completedUnitCount = boundedTotalUnitCount > 0
            ? min(max(0, completedUnitCount), boundedTotalUnitCount)
            : max(0, completedUnitCount)
        self.currentUnitName = currentUnitName
    }
}

typealias PDFByteProgressHandler =
    @Sendable (PDFByteProgressUpdate) -> Void

enum PDFImportProgressStage: Hashable, Sendable {
    case preparing
    case copying
    case inspecting
    case saving
    case complete

    var title: String {
        switch self {
        case .preparing: return "Preparing private copy"
        case .copying: return "Copying private copy"
        case .inspecting: return "Inspecting PDF"
        case .saving: return "Saving to local library"
        case .complete: return "Private copy ready"
        }
    }
}

struct PDFImportProgressUpdate: Hashable, Sendable {
    let stage: PDFImportProgressStage
    let fractionCompleted: Double
    let processedBytes: Int64
    let totalBytes: Int64

    init(
        stage: PDFImportProgressStage,
        fractionCompleted: Double,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0
    ) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted.isFinite
            ? min(1, max(0, fractionCompleted))
            : 0
        let boundedTotalBytes = max(0, totalBytes)
        self.totalBytes = boundedTotalBytes
        self.processedBytes = boundedTotalBytes > 0
            ? min(max(0, processedBytes), boundedTotalBytes)
            : max(0, processedBytes)
    }
}

typealias PDFImportProgressHandler =
    @Sendable (PDFImportProgressUpdate) -> Void

struct PDFOfficeIntegrityProgress: Hashable, Sendable {
    private static let maximumDisplayByteRate =
        Double(Int64.max / 2)
    private static let maximumEstimatedRemainingSeconds:
        TimeInterval = 365 * 24 * 60 * 60

    let completedCount: Int
    let totalCount: Int
    let currentSourceName: String
    let processedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let estimatedRemainingSeconds: TimeInterval?
    let activity: PDFByteProgressStage
    let throughputHistory: [Double]
    let lastByteUpdateAt: Date?

    init(
        completedCount: Int,
        totalCount: Int,
        currentSourceName: String,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        estimatedRemainingSeconds: TimeInterval? = nil,
        activity: PDFByteProgressStage = .verifying,
        throughputHistory: [Double] = [],
        lastByteUpdateAt: Date? = nil
    ) {
        let boundedTotalCount = max(0, totalCount)
        self.totalCount = boundedTotalCount
        self.completedCount = boundedTotalCount > 0
            ? min(max(0, completedCount), boundedTotalCount)
            : max(0, completedCount)
        self.currentSourceName = currentSourceName
        let boundedTotalBytes = max(0, totalBytes)
        self.totalBytes = boundedTotalBytes
        self.processedBytes = boundedTotalBytes > 0
            ? min(max(0, processedBytes), boundedTotalBytes)
            : max(0, processedBytes)
        self.bytesPerSecond = bytesPerSecond.isFinite
            ? min(
                Self.maximumDisplayByteRate,
                max(0, bytesPerSecond)
            )
            : 0
        self.estimatedRemainingSeconds =
            estimatedRemainingSeconds.flatMap {
                guard $0.isFinite, $0 >= 0 else { return nil }
                return min(
                    Self.maximumEstimatedRemainingSeconds,
                    $0
                )
            }
        self.activity = activity
        self.throughputHistory = Array(
            throughputHistory.lazy
                .filter { $0.isFinite && $0 >= 0 }
                .map { min(Self.maximumDisplayByteRate, $0) }
                .suffix(24)
        )
        self.lastByteUpdateAt =
            lastByteUpdateAt?.timeIntervalSince1970.isFinite == true
                ? lastByteUpdateAt
                : nil
    }

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(
                1,
                max(
                    0,
                    Double(processedBytes) / Double(totalBytes)
                )
            )
        }
        guard totalCount > 0 else { return 0 }
        return min(
            1,
            max(0, Double(completedCount) / Double(totalCount))
        )
    }

    var counter: String {
        "\(completedCount)/\(totalCount)"
    }

    var byteSummary: String? {
        guard totalBytes > 0 else { return nil }
        return "\(Self.formatBytes(processedBytes)) / \(Self.formatBytes(totalBytes))"
    }

    var throughputSummary: String? {
        guard bytesPerSecond > 0 else { return nil }
        return "\(Self.formatBytes(Int64(bytesPerSecond)))/s"
    }

    var remainingSummary: String? {
        guard let estimatedRemainingSeconds,
              estimatedRemainingSeconds.isFinite,
              estimatedRemainingSeconds >= 0
        else { return nil }
        let seconds = Int(ceil(estimatedRemainingSeconds))
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    func isStalled(at date: Date) -> Bool {
        guard processedBytes < totalBytes,
              let lastByteUpdateAt
        else { return false }
        return date.timeIntervalSince(lastByteUpdateAt) >= 2
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytes),
            countStyle: .file
        )
    }
}

struct PDFOfficeDeliveryEntry:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: UUID
    let sourceRecordID: UUID
    let sourceRevisionID: UUID
    let sourceName: String
    let receiptID: UUID
    let format: PDFTextExportFormat
    let archiveName: String
    let byteCount: Int64
    let sha256: String

    init(
        sourceRecordID: UUID,
        sourceRevisionID: UUID,
        sourceName: String,
        receiptID: UUID,
        format: PDFTextExportFormat,
        archiveName: String,
        byteCount: Int64,
        sha256: String
    ) {
        id = receiptID
        self.sourceRecordID = sourceRecordID
        self.sourceRevisionID = sourceRevisionID
        self.sourceName = sourceName
        self.receiptID = receiptID
        self.format = format
        self.archiveName = archiveName
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

private enum PDFEvidenceContract {
    static let futureTolerance: TimeInterval = 5 * 60

    static func isPlausiblePastDate(
        _ date: Date,
        now: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite
            && timestamp >= 0
            && date <= now.addingTimeInterval(futureTolerance)
    }

    static func isValidInterval(
        from start: Date,
        through end: Date,
        maximumDuration: TimeInterval,
        now: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> Bool {
        let endTimestamp = end.timeIntervalSince1970
        let duration = end.timeIntervalSince(start)
        return isPlausiblePastDate(start, now: now)
            && endTimestamp.isFinite
            && duration.isFinite
            && duration > 0
            && duration <= maximumDuration
    }

    static func isSafeDisplayText(
        _ value: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int? = nil,
        allowsEmpty: Bool = false
    ) -> Bool {
        guard allowsEmpty || !value.isEmpty,
              value.count <= maximumCharacters,
              maximumUTF8Bytes.map({
                  value.utf8.count <= $0
              }) ?? true
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !isBidirectionalControl
        }
    }
}

func paperPathArchiveLeafNameIdentity(
    _ name: String
) -> String? {
    let normalized = name.precomposedStringWithCanonicalMapping
    guard !name.isEmpty,
          name == normalized,
          name == name.trimmingCharacters(
            in: .whitespacesAndNewlines
          ),
          !name.hasPrefix("."),
          !name.hasSuffix("."),
          !name.contains("/"),
          !name.contains("\\"),
          name.utf8.count <= Int(UInt16.max),
          name.unicodeScalars.allSatisfy({
              let codePoint = $0.value
              let isBidirectionalControl =
                  codePoint == 0x061C
                  || codePoint == 0x200E
                  || codePoint == 0x200F
                  || (0x202A...0x202E).contains(codePoint)
                  || (0x2066...0x2069).contains(codePoint)
              return !CharacterSet.controlCharacters.contains($0)
                  && !CharacterSet.illegalCharacters.contains($0)
                  && !isBidirectionalControl
          })
    else { return nil }
    return normalized.lowercased()
}

func paperPathIsSafeArchiveLeafName(
    _ name: String
) -> Bool {
    paperPathArchiveLeafNameIdentity(name) != nil
}

final class PDFOfficeTimeAnchor: @unchecked Sendable, Hashable {
    static let rollbackTolerance: TimeInterval = 5
    static let process = PDFOfficeTimeAnchor()

    let referenceDate: Date
    let systemUptime: TimeInterval
    private let lock = NSLock()
    private var latestTrustedDate: Date

    init(
        referenceDate: Date = Date(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) {
        let validReferenceDate =
            referenceDate.timeIntervalSince1970.isFinite
            ? referenceDate
            : Date(timeIntervalSince1970: 0)
        self.referenceDate = validReferenceDate
        self.systemUptime = systemUptime.isFinite && systemUptime >= 0
            ? systemUptime
            : 0
        latestTrustedDate = validReferenceDate
    }

    static func == (
        lhs: PDFOfficeTimeAnchor,
        rhs: PDFOfficeTimeAnchor
    ) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    @discardableResult
    func restoreTrustedDate(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0 else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        latestTrustedDate = max(latestTrustedDate, date)
        return true
    }

    func trustedDate(
        wallDate: Date = Date(),
        systemUptime currentUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Date {
        let validWallDate = wallDate.timeIntervalSince1970.isFinite
            ? wallDate
            : referenceDate
        let candidate: Date
        if let monotonicDate = monotonicDate(
            at: currentUptime
        ) {
            candidate = max(validWallDate, monotonicDate)
        } else {
            candidate = max(validWallDate, referenceDate)
        }
        lock.lock()
        defer { lock.unlock() }
        latestTrustedDate = max(latestTrustedDate, candidate)
        return latestTrustedDate
    }

    func evidenceIssuanceDate(
        wallDate: Date = Date(),
        systemUptime currentUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Date? {
        let date = trustedDate(
            wallDate: wallDate,
            systemUptime: currentUptime
        )
        guard !hasWallClockRollback(
            wallDate: wallDate,
            systemUptime: currentUptime
        ) else {
            return nil
        }
        return date
    }

    func hasWallClockRollback(
        wallDate: Date = Date(),
        systemUptime currentUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime,
        tolerance: TimeInterval =
            PDFOfficeTimeAnchor.rollbackTolerance
    ) -> Bool {
        guard wallDate.timeIntervalSince1970.isFinite,
              tolerance.isFinite,
              tolerance >= 0
        else { return false }
        let monotonicDate = monotonicDate(at: currentUptime)
        lock.lock()
        defer { lock.unlock() }
        let expectedDate = max(
            latestTrustedDate,
            monotonicDate ?? referenceDate
        )
        return wallDate.addingTimeInterval(tolerance) < expectedDate
    }

    private func monotonicDate(
        at currentUptime: TimeInterval
    ) -> Date? {
        guard currentUptime.isFinite,
              currentUptime >= systemUptime
        else { return nil }
        let elapsed = currentUptime - systemUptime
        guard elapsed.isFinite else { return nil }
        return referenceDate.addingTimeInterval(elapsed)
    }
}

struct PDFOfficeVerificationPayload:
    Codable,
    Hashable,
    Sendable {
    let schema: String
    let packageID: UUID
    let createdAt: Date
    let expiresAt: Date
    let verifiedOutputs: Int
    let files: [PDFOfficeDeliveryEntry]

    private enum CodingKeys: String, CodingKey {
        case schema
        case packageID = "package_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case verifiedOutputs = "verified_outputs"
        case files
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let archiveNameIdentities = files.compactMap {
            paperPathArchiveLeafNameIdentity($0.archiveName)
        }
        let reservedManifestIdentity =
            paperPathArchiveLeafNameIdentity(
                "PaperPath-delivery-manifest.json"
            ) ?? "paperpath-delivery-manifest.json"
        guard schema == "PaperPath Office Delivery V34",
              PDFEvidenceContract.isValidInterval(
                  from: createdAt,
                  through: expiresAt,
                  maximumDuration: 7 * 24 * 60 * 60,
                  now: date
              ),
              !files.isEmpty,
              files.count
                <= PDFOfficeExternalMatchReport.maximumFileCount,
              verifiedOutputs == files.count,
              Set(files.map(\.receiptID)).count == files.count,
              archiveNameIdentities.count == files.count,
              Set(archiveNameIdentities).count == files.count,
              !archiveNameIdentities.contains(
                reservedManifestIdentity
              )
        else { return false }
        var totalBytes: Int64 = 0
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdef"
        )
        for file in files {
            let (nextBytes, overflow) = totalBytes
                .addingReportingOverflow(file.byteCount)
            guard !overflow,
                  file.id == file.receiptID,
                  file.sourceName.count >= 1,
                  file.sourceName.count <= 160,
                  Self.isSafeDisplayText(file.sourceName),
                  file.archiveName.count >= 1,
                  file.archiveName.count <= 180,
                  file.archiveName.utf8.count <= 240,
                  paperPathIsSafeArchiveLeafName(
                    file.archiveName
                  ),
                  URL(fileURLWithPath: file.archiveName)
                    .pathExtension
                    .lowercased()
                    == file.format.fileExtension.lowercased(),
                  file.byteCount > 0,
                  file.byteCount
                    <= PDFOfficeExternalMatchReport.maximumFileBytes,
                  file.sha256.count == 64,
                  file.sha256.unicodeScalars.allSatisfy(
                      hexadecimal.contains
                  )
            else { return false }
            totalBytes = nextBytes
        }
        return totalBytes
            <= PDFOfficeExternalMatchReport.maximumBatchBytes
    }

    func isActive(
        at date: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> Bool {
        isStructurallyValid(at: date) && expiresAt > date
    }

    private static func isSafeDisplayText(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                let codePoint = scalar.value
                let isBidirectionalControl =
                    codePoint == 0x061C
                    || codePoint == 0x200E
                    || codePoint == 0x200F
                    || (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
                return !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.illegalCharacters.contains(scalar)
                    && !isBidirectionalControl
            }
    }
}

struct PDFOfficeVerificationSignature:
    Codable,
    Hashable,
    Sendable {
    let algorithm: String
    let keyID: String
    let publicKeyBase64: String
    let signatureBase64: String

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case keyID = "key_id"
        case publicKeyBase64 = "public_key"
        case signatureBase64 = "signature"
    }
}

struct PDFOfficeSignedVerificationReport:
    Codable,
    Hashable,
    Sendable {
    let payload: PDFOfficeVerificationPayload
    let signature: PDFOfficeVerificationSignature
}

struct PDFChangeReportSignaturePayload:
    Codable,
    Hashable,
    Sendable {
    static let schema = "PaperPath Change Report Signature V1"
    static let maximumBodyBytes = 4 * 1_024 * 1_024

    let schema: String
    let reportID: UUID
    let generatedAt: Date
    let sourceName: String
    let revisedName: String
    let sourceRevisionID: UUID?
    let revisedRevisionID: UUID?
    let sourceFingerprint: String?
    let revisedFingerprint: String?
    let deliveryReceiptID: UUID?
    let changedPageCount: Int
    let bodyByteCount: Int
    let bodySHA256: String

    private enum CodingKeys: String, CodingKey {
        case schema
        case reportID = "report_id"
        case generatedAt = "generated_at"
        case sourceName = "source_name"
        case revisedName = "revised_name"
        case sourceRevisionID = "source_revision_id"
        case revisedRevisionID = "revised_revision_id"
        case sourceFingerprint = "source_sha256"
        case revisedFingerprint = "revised_sha256"
        case deliveryReceiptID = "delivery_receipt_id"
        case changedPageCount = "changed_page_count"
        case bodyByteCount = "body_byte_count"
        case bodySHA256 = "body_sha256"
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        schema == Self.schema
            && PDFEvidenceContract.isPlausiblePastDate(
                generatedAt,
                now: date
            )
            && Self.isSafeDisplayText(sourceName)
            && sourceName.count <= 240
            && Self.isSafeDisplayText(revisedName)
            && revisedName.count <= 240
            && changedPageCount >= 0
            && changedPageCount <= 100_000
            && bodyByteCount > 0
            && bodyByteCount <= Self.maximumBodyBytes
            && Self.isSHA256(bodySHA256)
            && Self.isOptionalSHA256(sourceFingerprint)
            && Self.isOptionalSHA256(revisedFingerprint)
    }

    private static func isOptionalSHA256(_ value: String?) -> Bool {
        value.map(isSHA256) ?? true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    private static func isSafeDisplayText(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                let codePoint = scalar.value
                let isBidirectionalControl =
                    codePoint == 0x061C
                    || codePoint == 0x200E
                    || codePoint == 0x200F
                    || (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
                return !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.illegalCharacters.contains(scalar)
                    && !isBidirectionalControl
            }
    }
}

struct PDFSignedChangeReportEnvelope:
    Codable,
    Hashable,
    Sendable {
    let payload: PDFChangeReportSignaturePayload
    let signature: PDFOfficeVerificationSignature
}

struct PDFChangeReportVerificationResult:
    Identifiable,
    Hashable,
    Sendable {
    var id: UUID { reportID }

    let status: PDFOfficeReportVerificationStatus
    let reportID: UUID
    let generatedAt: Date
    let sourceName: String
    let revisedName: String
    let changedPageCount: Int
    let deliveryReceiptID: UUID?
    let sourceRevisionID: UUID?
    let revisedRevisionID: UUID?
    let sourceFingerprint: String?
    let revisedFingerprint: String?
    let verifiedBody: String?
    let verifiedBodyByteCount: Int?
    let verifiedBodySHA256: String?
    let keyID: String?
    let detail: String
    let publicKeyBase64: String?
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?

    var isVerified: Bool {
        status == .verified
    }

    var canTrustSigner: Bool {
        isVerified
            && trustStatus == .unknown
            && keyID != nil
            && publicKeyBase64 != nil
    }

    func resolvingTrust(
        _ status: PDFOfficeSignerTrustStatus,
        trustedSignerName: String?
    ) -> PDFChangeReportVerificationResult {
        PDFChangeReportVerificationResult(
            status: self.status,
            reportID: reportID,
            generatedAt: generatedAt,
            sourceName: sourceName,
            revisedName: revisedName,
            changedPageCount: changedPageCount,
            deliveryReceiptID: deliveryReceiptID,
            sourceRevisionID: sourceRevisionID,
            revisedRevisionID: revisedRevisionID,
            sourceFingerprint: sourceFingerprint,
            revisedFingerprint: revisedFingerprint,
            verifiedBody: verifiedBody,
            verifiedBodyByteCount: verifiedBodyByteCount,
            verifiedBodySHA256: verifiedBodySHA256,
            keyID: keyID,
            detail: detail,
            publicKeyBase64: publicKeyBase64,
            trustStatus: status,
            trustedSignerName: trustedSignerName
        )
    }
}

struct PDFRetainedChangeReportLocalLink:
    Codable,
    Hashable,
    Sendable {
    enum Context: String, Codable, Hashable, Sendable {
        case documentPair
        case versionSnapshot
        case deliveryReceipt
    }

    let context: Context
    let sourceDocumentID: UUID?
    let sourceRevisionID: UUID?
    let sourceFingerprint: String?
    let revisedDocumentID: UUID
    let revisedRevisionID: UUID?
    let revisedFingerprint: String?
    let versionSnapshotID: UUID?
    let deliveryReceiptID: UUID?

    var isStructurallyValid: Bool {
        guard sourceFingerprint.map(Self.isSHA256) ?? true,
              revisedFingerprint.map(Self.isSHA256) ?? true
        else { return false }
        switch context {
        case .documentPair:
            return sourceDocumentID != nil
                && sourceDocumentID != revisedDocumentID
                && sourceRevisionID != nil
                && revisedRevisionID != nil
                && sourceFingerprint != nil
                && revisedFingerprint != nil
                && versionSnapshotID == nil
                && deliveryReceiptID == nil
        case .versionSnapshot:
            return sourceDocumentID == revisedDocumentID
                && sourceRevisionID != nil
                && revisedRevisionID != nil
                && sourceFingerprint != nil
                && revisedFingerprint != nil
                && versionSnapshotID != nil
                && deliveryReceiptID == nil
        case .deliveryReceipt:
            return versionSnapshotID == nil
                && revisedFingerprint != nil
                && deliveryReceiptID != nil
        }
    }

    func matches(
        _ verification: PDFChangeReportVerificationResult
    ) -> Bool {
        verification.isVerified
            && sourceRevisionID == verification.sourceRevisionID
            && revisedRevisionID == verification.revisedRevisionID
            && Self.equalFingerprints(
                sourceFingerprint,
                verification.sourceFingerprint
            )
            && Self.equalFingerprints(
                revisedFingerprint,
                verification.revisedFingerprint
            )
            && deliveryReceiptID
                == verification.deliveryReceiptID
    }

    func referencesAnyDocument(
        in documentIDs: Set<UUID>
    ) -> Bool {
        documentIDs.contains(revisedDocumentID)
            || sourceDocumentID.map(documentIDs.contains) == true
    }

    static func documentPair(
        source: DocumentRecord,
        revised: DocumentRecord
    ) -> PDFRetainedChangeReportLocalLink? {
        guard let sourceFingerprint = source.contentFingerprint,
              let revisedFingerprint = revised.contentFingerprint
        else { return nil }
        return PDFRetainedChangeReportLocalLink(
            context: .documentPair,
            sourceDocumentID: source.id,
            sourceRevisionID: source.contentRevisionID,
            sourceFingerprint: sourceFingerprint,
            revisedDocumentID: revised.id,
            revisedRevisionID: revised.contentRevisionID,
            revisedFingerprint: revisedFingerprint,
            versionSnapshotID: nil,
            deliveryReceiptID: nil
        )
    }

    static func versionSnapshot(
        _ snapshot: PDFVersionSnapshot,
        current: DocumentRecord
    ) -> PDFRetainedChangeReportLocalLink? {
        guard snapshot.documentID == current.id,
              let revisedFingerprint = current.contentFingerprint
        else { return nil }
        return PDFRetainedChangeReportLocalLink(
            context: .versionSnapshot,
            sourceDocumentID: current.id,
            sourceRevisionID: snapshot.contentRevisionID,
            sourceFingerprint: snapshot.contentFingerprint,
            revisedDocumentID: current.id,
            revisedRevisionID: current.contentRevisionID,
            revisedFingerprint: revisedFingerprint,
            versionSnapshotID: snapshot.id,
            deliveryReceiptID: nil
        )
    }

    static func deliveryReceipt(
        source: DocumentRecord?,
        revised: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) -> PDFRetainedChangeReportLocalLink {
        PDFRetainedChangeReportLocalLink(
            context: .deliveryReceipt,
            sourceDocumentID: source?.id,
            sourceRevisionID: receipt.sourceRevisionID,
            sourceFingerprint:
                source?.contentRevisionID == receipt.sourceRevisionID
                    ? source?.contentFingerprint
                    : nil,
            revisedDocumentID: revised.id,
            revisedRevisionID: receipt.outputRevisionID,
            revisedFingerprint: receipt.sha256,
            versionSnapshotID: nil,
            deliveryReceiptID: receipt.id
        )
    }

    private static func equalFingerprints(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        default:
            return false
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }
}

enum PDFRetainedChangeReportDestination:
    Hashable,
    Identifiable,
    Sendable {
    case documentPair(
        sourceRecordID: UUID,
        sourceRevisionID: UUID,
        revisedRecordID: UUID,
        revisedRevisionID: UUID
    )
    case versionSnapshot(PDFVersionSnapshot)
    case deliveryReceipt(
        recordID: UUID,
        receipt: PDFDeliveryReceipt
    )

    var id: String {
        switch self {
        case let .documentPair(
            sourceRecordID,
            sourceRevisionID,
            revisedRecordID,
            revisedRevisionID
        ):
            return [
                "documents",
                sourceRecordID.uuidString,
                sourceRevisionID.uuidString,
                revisedRecordID.uuidString,
                revisedRevisionID.uuidString
            ].joined(separator: ":")
        case .versionSnapshot(let snapshot):
            return "version:\(snapshot.documentID):\(snapshot.id)"
        case let .deliveryReceipt(recordID, receipt):
            return "receipt:\(recordID):\(receipt.id)"
        }
    }
}

enum PDFRetainedChangeReportLookup:
    Hashable,
    Sendable {
    case documentPair(
        sourceRecordID: UUID,
        revisedRecordID: UUID
    )
    case versionSnapshot(
        recordID: UUID,
        snapshotID: UUID
    )
    case deliveryReceipt(
        recordID: UUID,
        receiptID: UUID
    )

    func matches(
        _ link: PDFRetainedChangeReportLocalLink?
    ) -> Bool {
        guard let link else { return false }
        switch self {
        case let .documentPair(
            sourceRecordID,
            revisedRecordID
        ):
            return link.context == .documentPair
                && link.sourceDocumentID == sourceRecordID
                && link.revisedDocumentID == revisedRecordID
        case let .versionSnapshot(recordID, snapshotID):
            return link.context == .versionSnapshot
                && link.sourceDocumentID == recordID
                && link.revisedDocumentID == recordID
                && link.versionSnapshotID == snapshotID
        case let .deliveryReceipt(recordID, receiptID):
            return link.context == .deliveryReceipt
                && link.revisedDocumentID == recordID
                && link.deliveryReceiptID == receiptID
        }
    }
}

enum PDFRetainedChangeReportLinkHealthStatus:
    String,
    Hashable,
    Sendable {
    case readyToVerify
    case changed
    case inTrash
    case missing
    case versionUnavailable
    case receiptUnavailable
    case verificationFailed
    case unlinked

    var title: String {
        switch self {
        case .readyToVerify:
            return "Ready to reverify"
        case .changed:
            return "Linked PDF changed"
        case .inTrash:
            return "Linked PDF in Trash"
        case .missing:
            return "Linked PDF missing"
        case .versionUnavailable:
            return "Linked version unavailable"
        case .receiptUnavailable:
            return "Linked receipt unavailable"
        case .verificationFailed:
            return "Reverification failed"
        case .unlinked:
            return "No local evidence link"
        }
    }

    var detail: String {
        switch self {
        case .readyToVerify:
            return "Revision metadata matches; bytes are checked on open"
        case .changed:
            return "The current revision no longer matches this report"
        case .inTrash:
            return "Restore the linked PDF before opening its evidence"
        case .missing:
            return "A linked private copy is no longer available"
        case .versionUnavailable:
            return "The linked recovery version is no longer retained"
        case .receiptUnavailable:
            return "The linked output no longer carries this receipt"
        case .verificationFailed:
            return "The report or linked PDF failed its full integrity check"
        case .unlinked:
            return "This report predates local evidence links"
        }
    }

    var symbol: String {
        switch self {
        case .readyToVerify:
            return "arrow.up.right.square"
        case .changed:
            return "pencil.and.outline"
        case .inTrash:
            return "trash"
        case .missing:
            return "doc.badge.questionmark"
        case .versionUnavailable:
            return "clock.badge.exclamationmark"
        case .receiptUnavailable:
            return "checkmark.seal"
        case .verificationFailed:
            return "xmark.shield.fill"
        case .unlinked:
            return "link.badge.plus"
        }
    }

    var canOpenLocalEvidence: Bool {
        self == .readyToVerify
    }

    var requiresAttention: Bool {
        switch self {
        case .changed, .inTrash, .missing,
             .versionUnavailable, .receiptUnavailable,
             .verificationFailed:
            return true
        case .readyToVerify, .unlinked:
            return false
        }
    }
}

struct PDFRetainedChangeReportInventory:
    Hashable,
    Sendable {
    let reports: [PDFRetainedChangeReport]
    let linkHealthByReportID:
        [UUID: PDFRetainedChangeReportLinkHealthStatus]

    var readyLinkCount: Int {
        linkHealthByReportID.values.filter {
            $0 == .readyToVerify
        }.count
    }

    var attentionLinkCount: Int {
        linkHealthByReportID.values.filter(
            \.requiresAttention
        ).count
    }
}

struct PDFRetainedChangeReport:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    static let maximumReportCount = 24
    static let maximumTotalBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumReportBytes: Int64 = 5 * 1_024 * 1_024

    let id: UUID
    let fileName: String
    let sourceName: String
    let revisedName: String
    let generatedAt: Date
    let retainedAt: Date
    let changedPageCount: Int
    let deliveryReceiptID: UUID?
    let signerKeyID: String?
    let byteCount: Int64
    let sha256: String
    let localLink: PDFRetainedChangeReportLocalLink?

    private enum CodingKeys: String, CodingKey {
        case id = "report_id"
        case fileName = "file_name"
        case sourceName = "source_name"
        case revisedName = "revised_name"
        case generatedAt = "generated_at"
        case retainedAt = "retained_at"
        case changedPageCount = "changed_page_count"
        case deliveryReceiptID = "delivery_receipt_id"
        case signerKeyID = "signer_key_id"
        case byteCount = "byte_count"
        case sha256
        case localLink = "local_link"
    }

    init(
        id: UUID,
        fileName: String,
        sourceName: String,
        revisedName: String,
        generatedAt: Date,
        retainedAt: Date,
        changedPageCount: Int,
        deliveryReceiptID: UUID?,
        signerKeyID: String?,
        byteCount: Int64,
        sha256: String,
        localLink: PDFRetainedChangeReportLocalLink?
    ) {
        self.id = id
        self.fileName = fileName
        self.sourceName = sourceName
        self.revisedName = revisedName
        self.generatedAt = generatedAt
        self.retainedAt = retainedAt
        self.changedPageCount = changedPageCount
        self.deliveryReceiptID = deliveryReceiptID
        self.signerKeyID = signerKeyID
        self.byteCount = byteCount
        self.sha256 = sha256
        self.localLink = localLink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(
            String.self,
            forKey: .fileName
        )
        sourceName = try container.decode(
            String.self,
            forKey: .sourceName
        )
        revisedName = try container.decode(
            String.self,
            forKey: .revisedName
        )
        generatedAt = try container.decode(
            Date.self,
            forKey: .generatedAt
        )
        retainedAt = try container.decode(
            Date.self,
            forKey: .retainedAt
        )
        changedPageCount = try container.decode(
            Int.self,
            forKey: .changedPageCount
        )
        deliveryReceiptID = try container.decodeIfPresent(
            UUID.self,
            forKey: .deliveryReceiptID
        )
        signerKeyID = try container.decodeIfPresent(
            String.self,
            forKey: .signerKeyID
        )
        byteCount = try container.decode(
            Int64.self,
            forKey: .byteCount
        )
        sha256 = try container.decode(
            String.self,
            forKey: .sha256
        )
        localLink = (
            try? container.decodeIfPresent(
                PDFRetainedChangeReportLocalLink.self,
                forKey: .localLink
            )
        ) ?? nil
    }

    func isStructurallyValid(at date: Date) -> Bool {
        fileName == "\(id.uuidString).md"
            && PDFEvidenceContract.isSafeDisplayText(
                sourceName,
                maximumCharacters: 240,
                maximumUTF8Bytes: 960
            )
            && PDFEvidenceContract.isSafeDisplayText(
                revisedName,
                maximumCharacters: 240,
                maximumUTF8Bytes: 960
            )
            && PDFEvidenceContract.isPlausiblePastDate(
                generatedAt,
                now: date
            )
            && PDFEvidenceContract.isPlausiblePastDate(
                retainedAt,
                now: date
            )
            && retainedAt
                >= generatedAt.addingTimeInterval(-5 * 60)
            && changedPageCount >= 0
            && changedPageCount <= 100_000
            && byteCount > 0
            && byteCount <= Self.maximumReportBytes
            && Self.isSHA256(sha256)
            && signerKeyID.map(Self.isSigningKeyID) ?? true
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var shortFingerprint: String {
        String(sha256.prefix(12))
    }

    func removingLocalLink(
        referencing documentIDs: Set<UUID>
    ) -> PDFRetainedChangeReport {
        guard localLink?.referencesAnyDocument(
            in: documentIDs
        ) == true else { return self }
        return replacingLocalLink(nil)
    }

    func sanitizingLocalLink() -> PDFRetainedChangeReport {
        guard let localLink,
              !localLink.isStructurallyValid
        else { return self }
        return replacingLocalLink(nil)
    }

    private func replacingLocalLink(
        _ localLink: PDFRetainedChangeReportLocalLink?
    ) -> PDFRetainedChangeReport {
        PDFRetainedChangeReport(
            id: id,
            fileName: fileName,
            sourceName: sourceName,
            revisedName: revisedName,
            generatedAt: generatedAt,
            retainedAt: retainedAt,
            changedPageCount: changedPageCount,
            deliveryReceiptID: deliveryReceiptID,
            signerKeyID: signerKeyID,
            byteCount: byteCount,
            sha256: sha256,
            localLink: localLink
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    private static func isSigningKeyID(_ value: String) -> Bool {
        value.count == 16
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }
}

struct PDFRetainedChangeReportStorageSummary:
    Hashable,
    Sendable {
    static let empty = PDFRetainedChangeReportStorageSummary(
        reportCount: 0,
        byteCount: 0
    )

    let reportCount: Int
    let byteCount: Int64

    static func measuring<S: Sequence>(
        _ reports: S
    ) -> PDFRetainedChangeReportStorageSummary
    where S.Element == PDFRetainedChangeReport {
        var count = 0
        var total: Int64 = 0
        for report in reports {
            count += 1
            let (sum, overflow) = total.addingReportingOverflow(
                max(0, report.byteCount)
            )
            total = overflow ? .max : sum
        }
        return PDFRetainedChangeReportStorageSummary(
            reportCount: count,
            byteCount: total
        )
    }

    var pressureFraction: Double {
        max(
            Double(reportCount)
                / Double(PDFRetainedChangeReport.maximumReportCount),
            Double(byteCount)
                / Double(PDFRetainedChangeReport.maximumTotalBytes)
        )
    }

    var isNearCapacity: Bool {
        pressureFraction >= 0.8
    }

    var isAtCapacity: Bool {
        reportCount >= PDFRetainedChangeReport.maximumReportCount
            || byteCount >= PDFRetainedChangeReport.maximumTotalBytes
    }

    var remainingReportCount: Int {
        max(
            0,
            PDFRetainedChangeReport.maximumReportCount - reportCount
        )
    }

    var remainingByteCount: Int64 {
        max(
            0,
            PDFRetainedChangeReport.maximumTotalBytes - byteCount
        )
    }

    var formattedRemainingBytes: String {
        ByteCountFormatter.string(
            fromByteCount: remainingByteCount,
            countStyle: .file
        )
    }

    func canAdd(bytes: Int64) -> Bool {
        guard bytes > 0,
              bytes <= PDFRetainedChangeReport.maximumReportBytes,
              reportCount < PDFRetainedChangeReport.maximumReportCount
        else { return false }
        let (projectedBytes, overflow) = byteCount
            .addingReportingOverflow(bytes)
        return !overflow
            && projectedBytes
                <= PDFRetainedChangeReport.maximumTotalBytes
    }

    var formattedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var countContract: String {
        "\(reportCount)/\(PDFRetainedChangeReport.maximumReportCount)"
    }

    var byteContract: String {
        AppLocalization.format(
            "%@ / %@",
            formattedBytes,
            ByteCountFormatter.string(
                fromByteCount:
                    PDFRetainedChangeReport.maximumTotalBytes,
                countStyle: .file
            )
        )
    }
}

struct PDFOfficeSignerIdentityCard:
    Codable,
    Hashable,
    Sendable {
    let schema: String
    let keyID: String
    let publicKeyBase64: String
    let generatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schema
        case keyID = "key_id"
        case publicKeyBase64 = "public_key"
        case generatedAt = "generated_at"
    }

    var qrPayload: String {
        "paperpath-signer:v1:\(keyID):\(publicKeyBase64)"
    }
}

enum PDFOfficeSignerTrustStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case thisDevice
    case trusted
    case unknown
    case invalid
    case unsupported

    var title: String {
        switch self {
        case .thisDevice: return "This device"
        case .trusted: return "Trusted signer"
        case .unknown: return "Unknown signer"
        case .invalid: return "Untrusted content"
        case .unsupported: return "Unsupported"
        }
    }

    var symbol: String {
        switch self {
        case .thisDevice: return "iphone"
        case .trusted: return "person.crop.circle.badge.checkmark"
        case .unknown: return "person.crop.circle.badge.questionmark"
        case .invalid: return "person.crop.circle.badge.xmark"
        case .unsupported: return "questionmark.diamond"
        }
    }
}

struct PDFOfficeTrustedSigner:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    var id: String { keyID }
    let keyID: String
    let publicKeyBase64: String
    var displayName: String
    let trustedAt: Date
    var lastVerifiedAt: Date
    var verificationCount: Int
    var note: String?
}

enum PDFOfficeReportVerificationStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case verified
    case expired
    case invalid
    case unsupported

    var title: String {
        switch self {
        case .verified: return "Valid signature"
        case .expired: return "Expired report"
        case .invalid: return "Invalid signature"
        case .unsupported: return "Unsupported report"
        }
    }

    var symbol: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .invalid: return "xmark.seal.fill"
        case .unsupported: return "questionmark.diamond.fill"
        }
    }
}

struct PDFOfficeVerifiedArtifact:
    Identifiable,
    Hashable,
    Sendable {
    var id: UUID { entry.receiptID }

    let entry: PDFOfficeDeliveryEntry
    let url: URL
    let formatEvidence: PDFOfficeArtifactFormatEvidence

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: entry.byteCount,
            countStyle: .file
        )
    }

    var shortFingerprint: String {
        String(entry.sha256.prefix(12))
    }
}

enum PDFOfficeArtifactFormatEvidence: Hashable, Sendable {
    case ooxml(
        partCount: Int,
        xmlPartCount: Int,
        relationshipCount: Int,
        mediaPartCount: Int
    )
    case richText
    case utf8Text

    var summary: String {
        switch self {
        case .ooxml(
            let partCount,
            let xmlPartCount,
            let relationshipCount,
            let mediaPartCount
        ):
            return AppLocalization.format(
                "%lld parts · %lld XML · %lld relationships · %lld media",
                partCount,
                xmlPartCount,
                relationshipCount,
                mediaPartCount
            )
        case .richText:
            return "RTF structure · UTF-8"
        case .utf8Text:
            return "Valid UTF-8 text"
        }
    }

    var symbol: String {
        switch self {
        case .ooxml:
            return "shippingbox.fill"
        case .richText:
            return "text.document.fill"
        case .utf8Text:
            return "text.alignleft"
        }
    }
}

struct PDFOfficeReportVerificationResult:
    Hashable,
    Sendable {
    let status: PDFOfficeReportVerificationStatus
    let packageID: UUID?
    let keyID: String?
    let sourceCount: Int
    let outputCount: Int
    let createdAt: Date?
    let expiresAt: Date?
    let verifiedAt: Date
    let timeAnchor: PDFOfficeTimeAnchor?
    let detail: String
    let publicKeyBase64: String?
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let signedReport: PDFOfficeSignedVerificationReport?
    let verifiedArtifacts: [PDFOfficeVerifiedArtifact]

    init(
        status: PDFOfficeReportVerificationStatus,
        packageID: UUID?,
        keyID: String?,
        sourceCount: Int,
        outputCount: Int,
        createdAt: Date?,
        expiresAt: Date? = nil,
        verifiedAt: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        timeAnchor: PDFOfficeTimeAnchor? = nil,
        detail: String,
        publicKeyBase64: String?,
        trustStatus: PDFOfficeSignerTrustStatus,
        trustedSignerName: String?,
        signedReport: PDFOfficeSignedVerificationReport? = nil,
        verifiedArtifacts: [PDFOfficeVerifiedArtifact] = []
    ) {
        self.status = status
        self.packageID = packageID
        self.keyID = keyID
        self.sourceCount = sourceCount
        self.outputCount = outputCount
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.verifiedAt = verifiedAt
        self.timeAnchor = timeAnchor
        self.detail = detail
        self.publicKeyBase64 = publicKeyBase64
        self.trustStatus = trustStatus
        self.trustedSignerName = trustedSignerName
        self.signedReport = signedReport
        self.verifiedArtifacts = verifiedArtifacts
    }

    func effectiveStatus(
        at date: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> PDFOfficeReportVerificationStatus {
        guard status == .verified,
              let expiresAt,
              expiresAt <= effectiveDate(
                at: date,
                systemUptime: systemUptime
              )
        else { return status }
        return .expired
    }

    func effectiveDate(
        at date: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Date {
        timeAnchor?.trustedDate(
            wallDate: date,
            systemUptime: systemUptime
        ) ?? date
    }

    func hasClockRollback(
        at date: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        timeAnchor?.hasWallClockRollback(
            wallDate: date,
            systemUptime: systemUptime
        ) ?? false
    }

    func isExpired(
        at date: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        effectiveStatus(
            at: date,
            systemUptime: systemUptime
        ) == .expired
    }

    func isVerified(
        at date: Date,
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        effectiveStatus(
            at: date,
            systemUptime: systemUptime
        ) == .verified
    }

    var isVerified: Bool {
        isVerified(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func canTrustSigner(
        at date: Date,
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        isVerified(at: date, systemUptime: systemUptime)
            && trustStatus == .unknown
            && keyID != nil
            && publicKeyBase64 != nil
    }

    var canTrustSigner: Bool {
        canTrustSigner(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func appendingDetail(
        _ additionalDetail: String
    ) -> PDFOfficeReportVerificationResult {
        PDFOfficeReportVerificationResult(
            status: status,
            packageID: packageID,
            keyID: keyID,
            sourceCount: sourceCount,
            outputCount: outputCount,
            createdAt: createdAt,
            expiresAt: expiresAt,
            verifiedAt: verifiedAt,
            timeAnchor: timeAnchor,
            detail: "\(detail) \(additionalDetail)",
            publicKeyBase64: publicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            signedReport: signedReport,
            verifiedArtifacts: verifiedArtifacts
        )
    }

    func attachingVerifiedArtifacts(
        _ artifacts: [PDFOfficeVerifiedArtifact]
    ) -> PDFOfficeReportVerificationResult {
        PDFOfficeReportVerificationResult(
            status: status,
            packageID: packageID,
            keyID: keyID,
            sourceCount: sourceCount,
            outputCount: outputCount,
            createdAt: createdAt,
            expiresAt: expiresAt,
            verifiedAt: verifiedAt,
            timeAnchor: timeAnchor,
            detail: detail,
            publicKeyBase64: publicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            signedReport: signedReport,
            verifiedArtifacts: artifacts
        )
    }

    func updatingTrust(
        _ status: PDFOfficeSignerTrustStatus,
        signerName: String?
    ) -> PDFOfficeReportVerificationResult {
        PDFOfficeReportVerificationResult(
            status: self.status,
            packageID: packageID,
            keyID: keyID,
            sourceCount: sourceCount,
            outputCount: outputCount,
            createdAt: createdAt,
            expiresAt: expiresAt,
            verifiedAt: verifiedAt,
            timeAnchor: timeAnchor,
            detail: detail,
            publicKeyBase64: publicKeyBase64,
            trustStatus: status,
            trustedSignerName: signerName,
            signedReport: signedReport,
            verifiedArtifacts: verifiedArtifacts
        )
    }
}

struct PDFOfficeExternalCandidate:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    let id: UUID
    let fileName: String
    let fileExtension: String
    let byteCount: Int64
    let sha256: String

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var shortFingerprint: String {
        String(sha256.prefix(12))
    }
}

enum PDFOfficeExternalMatchStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case exact
    case missing
    case ambiguous
    case inconsistent

    var title: String {
        switch self {
        case .exact: return "Exact byte match"
        case .missing: return "No matching file"
        case .ambiguous: return "Multiple matches"
        case .inconsistent: return "Signed metadata mismatch"
        }
    }

    var symbol: String {
        switch self {
        case .exact: return "checkmark.seal.fill"
        case .missing: return "questionmark.diamond.fill"
        case .ambiguous: return "square.stack.3d.up.fill"
        case .inconsistent: return "exclamationmark.shield.fill"
        }
    }
}

struct PDFOfficeExternalEntryMatch:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { entry.receiptID }
    let entry: PDFOfficeDeliveryEntry
    let status: PDFOfficeExternalMatchStatus
    let candidates: [PDFOfficeExternalCandidate]
}

struct PDFOfficeExternalMatchReport:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    static let maximumFileCount = 128
    static let maximumFileBytes: Int64 = 1_024 * 1_024 * 1_024
    static let maximumBatchBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    let id: UUID
    let packageID: UUID
    let checkedAt: Date
    let matches: [PDFOfficeExternalEntryMatch]
    let extraCandidates: [PDFOfficeExternalCandidate]
    let totalCandidateCount: Int
    let totalCandidateBytes: Int64

    var exactCount: Int {
        matches.filter { $0.status == .exact }.count
    }

    var missingCount: Int {
        matches.filter { $0.status == .missing }.count
    }

    var ambiguousCount: Int {
        matches.filter { $0.status == .ambiguous }.count
    }

    var inconsistentCount: Int {
        matches.filter { $0.status == .inconsistent }.count
    }

    var reviewCount: Int {
        missingCount
            + ambiguousCount
            + inconsistentCount
            + extraCandidates.count
    }

    var isComplete: Bool {
        !matches.isEmpty
            && exactCount == matches.count
            && extraCandidates.isEmpty
    }
}

struct PDFOfficeMatchReportPayload:
    Codable,
    Hashable,
    Sendable {
    static let schema = "paperpath.office-match-report.v1"
    static let maximumEncodedBytes = 4 * 1_024 * 1_024

    let schema: String
    let reportID: UUID
    let createdAt: Date
    let deliveryReport: PDFOfficeSignedVerificationReport
    let matchReport: PDFOfficeExternalMatchReport

    private enum CodingKeys: String, CodingKey {
        case schema
        case reportID = "report_id"
        case createdAt = "created_at"
        case deliveryReport = "delivery_report"
        case matchReport = "match_report"
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let deliveryEntries = deliveryReport.payload.files
        guard schema == Self.schema,
              reportID == matchReport.id,
              createdAt == matchReport.checkedAt,
              PDFEvidenceContract.isPlausiblePastDate(
                createdAt,
                now: date
              ),
              deliveryReport.payload.isStructurallyValid(at: date),
              createdAt >= deliveryReport.payload.createdAt,
              createdAt <= deliveryReport.payload.expiresAt,
              matchReport.packageID
                == deliveryReport.payload.packageID,
              matchReport.matches.count == deliveryEntries.count,
              matchReport.totalCandidateCount > 0,
              matchReport.totalCandidateCount
                <= PDFOfficeExternalMatchReport.maximumFileCount,
              matchReport.totalCandidateBytes > 0,
              matchReport.totalCandidateBytes
                <= PDFOfficeExternalMatchReport.maximumBatchBytes,
              zip(
                  matchReport.matches,
                  deliveryEntries
              ).allSatisfy({ pair in
                  pair.0.entry == pair.1
              })
        else { return false }

        let expectedExtensions = Set(
            deliveryEntries.map {
                $0.format.fileExtension.lowercased()
            }
        )
        let allOccurrences = matchReport.matches
            .flatMap(\.candidates)
            + matchReport.extraCandidates
        var candidatesByID: [UUID: PDFOfficeExternalCandidate] = [:]
        for candidate in allOccurrences {
            guard PDFEvidenceContract.isSafeDisplayText(
                      candidate.fileName,
                      maximumCharacters: 180,
                      maximumUTF8Bytes: 240
                  ),
                  expectedExtensions.contains(
                      candidate.fileExtension.lowercased()
                  ),
                  candidate.fileExtension
                    == candidate.fileExtension.lowercased(),
                  candidate.byteCount > 0,
                  candidate.byteCount
                    <= PDFOfficeExternalMatchReport.maximumFileBytes,
                  Self.isSHA256(candidate.sha256)
            else { return false }
            if let existing = candidatesByID[candidate.id],
               existing != candidate {
                return false
            }
            candidatesByID[candidate.id] = candidate
        }
        let candidates = Array(candidatesByID.values)
        guard candidates.count == matchReport.totalCandidateCount
        else { return false }
        var calculatedBytes: Int64 = 0
        for candidate in candidates {
            let (next, overflow) = calculatedBytes
                .addingReportingOverflow(candidate.byteCount)
            guard !overflow else { return false }
            calculatedBytes = next
        }
        guard calculatedBytes == matchReport.totalCandidateBytes else {
            return false
        }

        let recognizedHashes = Set(deliveryEntries.map(\.sha256))
        let expectedExtraIDs = Set(
            candidates.filter {
                !recognizedHashes.contains($0.sha256)
            }.map(\.id)
        )
        guard matchReport.extraCandidates.count
                == Set(matchReport.extraCandidates.map(\.id)).count,
              Set(matchReport.extraCandidates.map(\.id))
                == expectedExtraIDs
        else { return false }

        let ownersByHash = Dictionary(
            grouping: deliveryEntries,
            by: \.sha256
        ).mapValues { Set($0.map(\.receiptID)) }
        for match in matchReport.matches {
            guard match.candidates.count
                    == Set(match.candidates.map(\.id)).count
            else { return false }
            let hashCandidates = candidates.filter {
                $0.sha256 == match.entry.sha256
            }
            guard Set(match.candidates.map(\.id))
                    == Set(hashCandidates.map(\.id))
            else { return false }
            let exactCandidates = hashCandidates.filter {
                $0.byteCount == match.entry.byteCount
            }
            let expectedStatus: PDFOfficeExternalMatchStatus
            if hashCandidates.count == 1,
               ownersByHash[match.entry.sha256]?.count == 1 {
                expectedStatus = exactCandidates.count == 1
                    ? .exact
                    : .inconsistent
            } else if hashCandidates.isEmpty {
                expectedStatus = .missing
            } else {
                expectedStatus = .ambiguous
            }
            guard match.status == expectedStatus else { return false }
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdef"
        )
        return value.count == 64
            && value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }
}

struct PDFSignedOfficeMatchReport:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { payload.reportID }
    let payload: PDFOfficeMatchReportPayload
    let signature: PDFOfficeVerificationSignature

    var shortKeyID: String {
        String(signature.keyID.prefix(8))
    }
}

struct PDFOfficeMatchReportInspection:
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { signedReport.id }
    let sourceFileName: String
    let signedReport: PDFSignedOfficeMatchReport
    let signatureStatus: PDFOfficeReportVerificationStatus
    let deliverySignatureStatus:
        PDFOfficeReportVerificationStatus
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let deliveryTrustStatus: PDFOfficeSignerTrustStatus
    let deliveryTrustedSignerName: String?
    let detail: String

    var isVerified: Bool {
        signatureStatus == .verified
            && deliverySignatureStatus == .verified
    }
}

struct PDFOfficeExternalMatchProgress:
    Hashable,
    Sendable {
    let packageID: UUID
    let completedFileCount: Int
    let totalFileCount: Int
    let processedBytes: Int64
    let totalBytes: Int64
    let currentFileName: String

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(
                1,
                max(0, Double(processedBytes) / Double(totalBytes))
            )
        }
        return min(
            1,
            max(
                0,
                Double(completedFileCount)
                    / Double(max(1, totalFileCount))
            )
        )
    }
}

struct PDFOfficeDeliveryPackage:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: UUID
    let createdAt: Date
    var expiresAt: Date
    var pinnedAt: Date?
    var archiveFileName: String?
    var reportFileName: String?
    var byteCount: Int64
    var sha256: String?
    var reportSHA256: String?
    var signerKeyID: String?
    let entries: [PDFOfficeDeliveryEntry]

    init(
        id: UUID = UUID(),
        createdAt: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        entries: [PDFOfficeDeliveryEntry]
    ) {
        self.id = id
        self.createdAt = createdAt
        expiresAt = Calendar.current.date(
            byAdding: .day,
            value: 3,
            to: createdAt
        ) ?? createdAt.addingTimeInterval(3 * 24 * 60 * 60)
        pinnedAt = nil
        archiveFileName = nil
        reportFileName = nil
        byteCount = 0
        sha256 = nil
        reportSHA256 = nil
        signerKeyID = nil
        self.entries = entries
    }

    var isPinned: Bool {
        pinnedAt != nil
    }

    var isExpired: Bool {
        isExpired(at: PDFOfficeTimeAnchor.process.trustedDate())
    }

    func isExpired(at date: Date) -> Bool {
        !isPinned && expiresAt <= date
    }

    func isReportExpired(
        at date: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> Bool {
        expiresAt <= date
    }

    var sourceCount: Int {
        Set(entries.map(\.sourceRecordID)).count
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var shortFingerprint: String? {
        sha256.map { String($0.prefix(12)) }
    }

    func retentionSummary(
        at date: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> String {
        if isPinned {
            return isReportExpired(at: date)
                ? "Pinned · report expired"
                : AppLocalization.format(
                    "Pinned · report valid until %@",
                    expiresAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
        }
        return AppLocalization.format(
            "Expires %@",
            expiresAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
        )
    }

    var retentionSummary: String {
        retentionSummary(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        let expectedArchive = "\(id.uuidString).zip"
        let expectedReport = "\(id.uuidString)-verification.json"
        let receiptIDs = entries.map(\.receiptID)
        let archiveNameIdentities = entries.compactMap {
            paperPathArchiveLeafNameIdentity($0.archiveName)
        }
        let createdTimestamp = createdAt.timeIntervalSince1970
        let expiryTimestamp = expiresAt.timeIntervalSince1970
        let pinnedTimestamp = pinnedAt?.timeIntervalSince1970
        guard createdTimestamp.isFinite,
              expiryTimestamp.isFinite,
              pinnedTimestamp?.isFinite != false,
              createdTimestamp >= 0,
              expiresAt >= createdAt,
              createdAt <= date.addingTimeInterval(5 * 60),
              (
                  pinnedAt.map { pinnedDate in
                      pinnedDate >= createdAt
                          && pinnedDate
                              <= date.addingTimeInterval(5 * 60)
                  } ?? true
              ),
              !entries.isEmpty,
              entries.count
                <= PDFOfficeExternalMatchReport.maximumFileCount,
              Set(receiptIDs).count == receiptIDs.count,
              archiveNameIdentities.count == entries.count,
              Set(archiveNameIdentities).count
                == archiveNameIdentities.count
        else { return false }

        var totalEntryBytes: Int64 = 0
        for entry in entries {
            let (nextTotal, overflow) =
                totalEntryBytes.addingReportingOverflow(
                    entry.byteCount
                )
            guard !overflow,
                  entry.id == entry.receiptID,
                  entry.sourceName.count <= 160,
                  Self.isSafeDisplayText(entry.sourceName),
                  entry.archiveName.count <= 180,
                  entry.archiveName.utf8.count <= 240,
                  !entry.archiveName.hasPrefix("."),
                  entry.archiveName
                    == (entry.archiveName as NSString)
                        .lastPathComponent,
                  !entry.archiveName.contains("\\"),
                  Self.isSafeDisplayText(entry.archiveName),
                  entry.archiveName.lowercased().hasSuffix(
                    ".\(entry.format.fileExtension)"
                  ),
                  entry.byteCount > 0,
                  entry.byteCount
                    <= PDFOfficeExternalMatchReport.maximumFileBytes,
                  entry.sha256.count == 64,
                  entry.sha256.unicodeScalars.allSatisfy(
                    hexadecimal.contains
                  )
            else { return false }
            totalEntryBytes = nextTotal
        }

        return totalEntryBytes
                <= PDFOfficeExternalMatchReport.maximumBatchBytes
            && archiveFileName == expectedArchive
            && reportFileName == expectedReport
            && byteCount > 0
            && byteCount
                <= PDFOfficeExternalMatchReport.maximumBatchBytes
            && sha256?.count == 64
            && sha256?.unicodeScalars.allSatisfy(
                hexadecimal.contains
            ) == true
            && reportSHA256?.count == 64
            && reportSHA256?.unicodeScalars.allSatisfy(
                hexadecimal.contains
            ) == true
            && signerKeyID?.count == 16
            && signerKeyID?.unicodeScalars.allSatisfy(
                hexadecimal.contains
            ) == true
    }

    private static func isSafeDisplayText(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                let codePoint = scalar.value
                let isBidirectionalControl =
                    codePoint == 0x061C
                    || codePoint == 0x200E
                    || codePoint == 0x200F
                    || (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
                return !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.illegalCharacters.contains(scalar)
                    && !isBidirectionalControl
            }
    }
}

struct PDFOfficePreflightSignal:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let readiness: PDFOfficeExportReadiness

    init(
        id: String,
        title: String,
        value: String,
        detail: String,
        symbol: String,
        readiness: PDFOfficeExportReadiness
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.readiness = readiness
    }
}

enum PDFOfficeRouteConfidence:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case high
    case guarded
    case weak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "High"
        case .guarded: return "Guarded"
        case .weak: return "Weak"
        }
    }

    var symbol: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .guarded: return "shield.lefthalf.filled"
        case .weak: return "exclamationmark.shield.fill"
        }
    }

    var detail: String {
        switch self {
        case .high:
            return "Recommended route has strong structure, budget, and permission evidence"
        case .guarded:
            return "Output is usable, but one route signal should be reviewed"
        case .weak:
            return "Export is available with visible limits; choose a safer fallback when possible"
        }
    }
}

enum PDFOfficeProductionSLA:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case quick
    case steady
    case heavy
    case constrained

    var id: String { rawValue }

    init(
        pageCount: Int,
        sourceBytes: Int64,
        visualBudgetPlan: PDFOfficeVisualBudgetPlan,
        isProtected: Bool
    ) {
        if isProtected {
            self = .constrained
        } else if pageCount > 300
                    || sourceBytes > 256 * 1_024 * 1_024
                    || visualBudgetPlan.chunkCount > 4 {
            self = .heavy
        } else if pageCount > 80
                    || visualBudgetPlan.budgetPressure != .relaxed {
            self = .steady
        } else {
            self = .quick
        }
    }

    var title: String {
        switch self {
        case .quick: return "Quick"
        case .steady: return "Steady"
        case .heavy: return "Heavy"
        case .constrained: return "Constrained"
        }
    }

    var window: String {
        switch self {
        case .quick: return "Short run"
        case .steady: return "Managed run"
        case .heavy: return "Long run"
        case .constrained: return "Review first"
        }
    }

    var symbol: String {
        switch self {
        case .quick: return "bolt.fill"
        case .steady: return "speedometer"
        case .heavy: return "hourglass"
        case .constrained: return "lock.trianglebadge.exclamationmark"
        }
    }

    var detail: String {
        switch self {
        case .quick:
            return "Small source; route should complete without visible budget pressure"
        case .steady:
            return "Medium source; visual anchors are budgeted before export"
        case .heavy:
            return "Large source; PaperPath uses bounded windows to protect memory and package size"
        case .constrained:
            return "Permissions or encryption can limit editable reconstruction"
        }
    }
}

struct PDFOfficeRecoveryAction:
    Identifiable,
    Hashable,
    Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tintRole: PDFOfficeExportReadiness
    let targetFormat: PDFTextExportFormat?
    let targetQuickTask: PDFQuickTask?

    init(
        id: String,
        title: String,
        detail: String,
        symbol: String,
        tintRole: PDFOfficeExportReadiness,
        targetFormat: PDFTextExportFormat? = nil,
        targetQuickTask: PDFQuickTask? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tintRole = tintRole
        self.targetFormat = targetFormat
        self.targetQuickTask = targetQuickTask
    }
}

enum PDFOfficeVisualBudgetMode:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case highDetail
    case balanced
    case bounded
    case largeDocument

    var id: String { rawValue }

    init(pageCount: Int) {
        switch pageCount {
        case ...24:
            self = .highDetail
        case ...100:
            self = .balanced
        case ...300:
            self = .bounded
        default:
            self = .largeDocument
        }
    }

    var storageValue: String {
        switch self {
        case .highDetail: return "high-detail"
        case .balanced: return "balanced"
        case .bounded: return "bounded"
        case .largeDocument: return "large-document"
        }
    }

    var title: String {
        switch self {
        case .highDetail: return "High detail"
        case .balanced: return "Balanced"
        case .bounded: return "Bounded"
        case .largeDocument: return "Large doc"
        }
    }

    var symbol: String {
        switch self {
        case .highDetail: return "sparkle.magnifyingglass"
        case .balanced: return "slider.horizontal.3"
        case .bounded: return "speedometer"
        case .largeDocument: return "externaldrive.badge.checkmark"
        }
    }

    var longestEdge: Int {
        switch self {
        case .highDetail: return 1_600
        case .balanced: return 1_280
        case .bounded: return 960
        case .largeDocument: return 720
        }
    }

    var compressionQualityPercent: Int {
        switch self {
        case .highDetail: return 80
        case .balanced: return 74
        case .bounded: return 68
        case .largeDocument: return 62
        }
    }

    var chunkPageTarget: Int {
        switch self {
        case .highDetail: return 24
        case .balanced: return 80
        case .bounded: return 90
        case .largeDocument: return 120
        }
    }

    var detail: String {
        switch self {
        case .highDetail:
            return "Preserves more page visuals for short documents"
        case .balanced:
            return "Balances reference images and package size"
        case .bounded:
            return "Caps visual anchors for longer documents"
        case .largeDocument:
            return "Prioritizes structure and avoids oversized packages"
        }
    }
}

enum PDFOfficeVisualBudgetPressure:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case relaxed
    case managed
    case tight

    var id: String { rawValue }

    init(
        estimatedVisualBytes: Int,
        totalBudgetBytes: Int
    ) {
        let ratio = Double(estimatedVisualBytes)
            / Double(max(1, totalBudgetBytes))
        if ratio >= 0.74 {
            self = .tight
        } else if ratio >= 0.36 {
            self = .managed
        } else {
            self = .relaxed
        }
    }

    var title: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .managed: return "Managed"
        case .tight: return "Tight"
        }
    }

    var symbol: String {
        switch self {
        case .relaxed: return "gauge.with.dots.needle.0percent"
        case .managed: return "gauge.with.dots.needle.50percent"
        case .tight: return "gauge.with.dots.needle.100percent"
        }
    }
}

enum PDFOfficeVisualAnchorPolicy:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case scanFirst
    case imageFirst
    case tableAware
    case structureFirst

    var id: String { rawValue }

    init(profile: DocumentProfile) {
        if profile.textCoverage < 0.22 {
            self = .scanFirst
        } else if profile.textCoverage < 0.72 {
            self = .tableAware
        } else if profile.imageDominantPageCount > 0 {
            self = .imageFirst
        } else {
            self = .structureFirst
        }
    }

    var title: String {
        switch self {
        case .scanFirst: return "Scan-first"
        case .imageFirst: return "Image-first"
        case .tableAware: return "Table-aware"
        case .structureFirst: return "Structure-first"
        }
    }

    var symbol: String {
        switch self {
        case .scanFirst: return "doc.viewfinder"
        case .imageFirst: return "photo.stack"
        case .tableAware: return "tablecells"
        case .structureFirst: return "text.alignleft"
        }
    }

    var detail: String {
        switch self {
        case .scanFirst:
            return "Prioritize page visuals where editable structure is weak"
        case .imageFirst:
            return "Reserve visual anchors for image-dominant pages"
        case .tableAware:
            return "Protect tables before decorative page visuals"
        case .structureFirst:
            return "Prefer editable text and reduce visual anchors"
        }
    }
}

struct PDFOfficeVisualBudgetPlan:
    Hashable,
    Sendable {
    let mode: PDFOfficeVisualBudgetMode
    let anchorPolicy: PDFOfficeVisualAnchorPolicy
    let longestEdge: Int
    let compressionQualityPercent: Int
    let maximumTotalBytes: Int
    let maximumBytesPerPage: Int
    let estimatedVisualReferencePages: Int
    let recommendedChunkSize: Int
    let chunkCount: Int
    let compressionAttemptCount: Int
    let minimumCompressionQualityPercent: Int
    let budgetPressure: PDFOfficeVisualBudgetPressure

    init(profile: DocumentProfile) {
        let pageCount = max(1, profile.pageCount)
        mode = PDFOfficeVisualBudgetMode(pageCount: pageCount)
        anchorPolicy = PDFOfficeVisualAnchorPolicy(profile: profile)
        longestEdge = mode.longestEdge
        compressionQualityPercent = mode.compressionQualityPercent
        maximumTotalBytes = 72 * 1_024 * 1_024
        maximumBytesPerPage = min(
            3 * 1_024 * 1_024,
            max(
                160 * 1_024,
                maximumTotalBytes / pageCount
            )
        )
        let lowTextEstimate = profile.textCoverage < 0.22
            ? Int((Double(pageCount) * 0.72).rounded())
            : 0
        let mixedStructureEstimate = profile.textCoverage < 0.48
            ? Int((Double(pageCount) * 0.28).rounded())
            : 0
        let longDocumentReserve =
            pageCount > 300 && profile.textCoverage < 0.62
            ? Int((Double(pageCount) * 0.18).rounded())
            : 0
        estimatedVisualReferencePages = min(
            pageCount,
            max(
                profile.imageDominantPageCount,
                lowTextEstimate,
                mixedStructureEstimate,
                longDocumentReserve
            )
        )
        recommendedChunkSize = mode.chunkPageTarget
        chunkCount = Int(
            ceil(Double(pageCount) / Double(recommendedChunkSize))
        )
        compressionAttemptCount = 4
        minimumCompressionQualityPercent = min(
            46,
            compressionQualityPercent
        )
        budgetPressure = PDFOfficeVisualBudgetPressure(
            estimatedVisualBytes:
                estimatedVisualReferencePages * maximumBytesPerPage,
            totalBudgetBytes: maximumTotalBytes
        )
    }

    var formattedTotalBudget: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(maximumTotalBytes),
            countStyle: .file
        )
    }

    var formattedPerPageBudget: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(maximumBytesPerPage),
            countStyle: .file
        )
    }

    var visualReferenceRatioPercent: Int {
        guard chunkCount > 0 else { return 0 }
        return min(
            100,
            max(
                0,
                Int(
                    (
                        Double(estimatedVisualReferencePages)
                            / Double(max(1, chunkCount * recommendedChunkSize))
                            * 100
                    ).rounded()
                )
            )
        )
    }

    var estimatedVisualBytes: Int {
        estimatedVisualReferencePages * maximumBytesPerPage
    }

    var estimatedBudgetUsePercent: Int {
        min(
            100,
            max(
                0,
                Int(
                    (
                        Double(estimatedVisualBytes)
                            / Double(max(1, maximumTotalBytes))
                            * 100
                    ).rounded()
                )
            )
        )
    }

    var formattedEstimatedVisualBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(estimatedVisualBytes),
            countStyle: .file
        )
    }

    var pressureContract: String {
        AppLocalization.format(
            "%@ · %@ used · %@/page",
            budgetPressure.title.localizedUI,
            "\(estimatedBudgetUsePercent)%",
            formattedPerPageBudget
        )
    }

    var chunkSummary: String {
        chunkCount <= 1
            ? "Single package".localizedUI
            : AppLocalization.format(
                "%lld chunks · %lld pages",
                chunkCount,
                recommendedChunkSize
            )
    }

    var compressionLadderSummary: String {
        AppLocalization.format(
            "%lld passes · %lld-%lld%%",
            compressionAttemptCount,
            compressionQualityPercent,
            minimumCompressionQualityPercent
        )
    }

    var anchorPolicySummary: String {
        AppLocalization.format(
            "%@ · %@",
            anchorPolicy.title.localizedUI,
            budgetPressure.title.localizedUI
        )
    }

    var reserveWindowSummary: String {
        AppLocalization.format(
            "%lldp window",
            mode.chunkPageTarget
        )
    }

    var memoryGuardSummary: String {
        AppLocalization.format(
            "%@ · %@ · %@",
            mode.title.localizedUI,
            reserveWindowSummary,
            compressionLadderSummary
        )
    }
}

struct PDFOfficeExportReceipt:
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    let id: UUID
    let format: PDFTextExportFormat
    let fileName: String
    let fileSizeBytes: Int64
    let readiness: PDFOfficeExportReadiness
    let routeScore: Int
    let budgetMode: PDFOfficeVisualBudgetMode
    let budgetPressure: PDFOfficeVisualBudgetPressure
    let anchorPolicy: PDFOfficeVisualAnchorPolicy
    let visualReferenceEstimate: Int
    let routeSummary: String
    let preflightSummary: String
    let preflightSignals: [PDFOfficePreflightSignal]
    let exportedAt: Date
    var sourceRevisionID: UUID?
    var retainedFileName: String?
    var reusableUntil: Date?
    var pinnedAt: Date?
    var runtimeEvidence: PDFOfficeRuntimeEvidence?
    var batchID: UUID?
    var batchSegmentIndex: Int?
    var batchSegmentCount: Int?
    var sourcePageStartIndex: Int?
    var sourcePageEndIndex: Int?
    var artifactSHA256: String?
    var integrityStatus: PDFOfficeIntegrityStatus?
    var integrityCheckedAt: Date?

    var contentNotices: [PDFOfficeContentNotice] {
        runtimeEvidence?.contentNotices ?? PDFOfficeContentNotice.defaults(for: format)
    }

    init(
        format: PDFTextExportFormat,
        fileName: String,
        fileSizeBytes: Int64,
        plan: PDFOfficeExportFormatPlan?,
        budgetPlan: PDFOfficeVisualBudgetPlan,
        portfolio: PDFOfficeExportPortfolio? = nil,
        runtimeEvidence: PDFOfficeRuntimeEvidence? = nil,
        batchPlan: PDFOfficeBatchPlan? = nil,
        batchSegment: PDFOfficeBatchSegment? = nil
    ) {
        id = UUID()
        self.format = format
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        readiness = plan?.readiness ?? .review
        routeScore = plan?.compositeScore ?? 0
        budgetMode = budgetPlan.mode
        budgetPressure = budgetPlan.budgetPressure
        anchorPolicy = budgetPlan.anchorPolicy
        visualReferenceEstimate =
            budgetPlan.estimatedVisualReferencePages
        routeSummary = portfolio?.decisionLine
            ?? AppLocalization.format(
                "%@ · score %lld",
                format.fileExtension.uppercased(),
                plan?.compositeScore ?? 0
            )
        preflightSummary = portfolio?.preflightSummary
            ?? "Local rebuild"
        preflightSignals = portfolio?.preflightSignals ?? []
        exportedAt = PDFOfficeTimeAnchor.process.trustedDate()
        sourceRevisionID = nil
        retainedFileName = nil
        reusableUntil = nil
        pinnedAt = nil
        self.runtimeEvidence = runtimeEvidence
        batchID = batchPlan?.id
        batchSegmentIndex = batchSegment?.index
        batchSegmentCount = batchPlan?.segmentCount
        sourcePageStartIndex = batchSegment?.startPageIndex
        sourcePageEndIndex = batchSegment?.endPageIndex
        artifactSHA256 = nil
        integrityStatus = nil
        integrityCheckedAt = nil
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: fileSizeBytes,
            countStyle: .file
        )
    }

    var shortTime: String {
        exportedAt.formatted(
            date: .omitted,
            time: .shortened
        )
    }

    var leadPreflightSignal: PDFOfficePreflightSignal? {
        preflightSignals.first { $0.readiness == .limited }
            ?? preflightSignals.first { $0.readiness == .review }
            ?? preflightSignals.first
    }

    var receiptSummary: String {
        if let leadPreflightSignal {
            return "\(preflightSummary) · \(leadPreflightSignal.detail)"
        }
        return preflightSummary
    }

    var embedsPreflightEvidence: Bool {
        switch format {
        case .wordDocument, .excelWorkbook,
             .powerPointPresentation:
            return !preflightSignals.isEmpty
        case .richText, .markdown, .plainText:
            return false
        }
    }

    var embeddedEvidenceLabel: String {
        embedsPreflightEvidence ? "File audit" : "App receipt"
    }

    var routeConfidence: PDFOfficeRouteConfidence {
        if readiness == .limited || routeScore < 52 {
            return .weak
        }
        if readiness == .review
            || routeScore < 76
            || budgetPressure == .tight
            || leadPreflightSignal?.readiness == .review {
            return .guarded
        }
        return .high
    }

    var budgetContractSummary: String {
        AppLocalization.format(
            "%@ · %@ · %@",
            budgetMode.title,
            budgetPressure.title,
            anchorPolicy.title
        )
    }

    var auditEvidenceSummary: String {
        AppLocalization.format(
            "%@ · %@ · %@ visual",
            embeddedEvidenceLabel,
            preflightSummary,
            "\(visualReferenceEstimate)"
        )
    }

    var qualityGateSummary: String {
        AppLocalization.format(
            "%@ confidence · score %@ · %@",
            routeConfidence.title,
            "\(routeScore)",
            budgetContractSummary
        )
    }

    func artifactAvailability(
        for currentRevisionID: UUID,
        now: Date = PDFOfficeTimeAnchor.process.trustedDate()
    ) -> PDFOfficeArtifactAvailability {
        guard retainedFileName != nil,
              let sourceRevisionID,
              let reusableUntil
        else {
            return .unavailable
        }
        guard sourceRevisionID == currentRevisionID else {
            return .sourceChanged
        }
        if pinnedAt != nil {
            return .reusable
        }
        guard reusableUntil > now else {
            return .expired
        }
        return .reusable
    }

    var isPinned: Bool {
        pinnedAt != nil
    }

    var isBatchSegment: Bool {
        batchID != nil
            && batchSegmentIndex != nil
            && batchSegmentCount != nil
    }

    var sourcePageSummary: String? {
        guard let start = sourcePageStartIndex,
              let end = sourcePageEndIndex,
              start >= 0, end >= start
        else { return nil }
        return AppLocalization.format("Source pages %lld-%lld", start + 1, end + 1)
    }

    var batchSummary: String? {
        guard let batchSegmentIndex,
              let batchSegmentCount,
              let sourcePageStartIndex,
              let sourcePageEndIndex
        else { return nil }
        return AppLocalization.format(
            "Part %lld/%lld · pages %lld-%lld",
            batchSegmentIndex + 1,
            batchSegmentCount,
            sourcePageStartIndex + 1,
            sourcePageEndIndex + 1
        )
    }

    var retentionSummary: String {
        if pinnedAt != nil {
            return "Pinned until unpinned"
        }
        guard let reusableUntil else {
            return "Audit receipt retained"
        }
        return AppLocalization.format(
            "Reusable until %@",
            reusableUntil.formatted(
                date: .abbreviated,
                time: .shortened
            )
        )
    }

    var shortArtifactFingerprint: String? {
        guard let artifactSHA256, !artifactSHA256.isEmpty else {
            return nil
        }
        return artifactSHA256.prefix(12).enumerated().reduce(
            into: ""
        ) { result, pair in
            if pair.offset > 0, pair.offset.isMultiple(of: 4) {
                result.append(" ")
            }
            result.append(pair.element)
        }
    }

    var integritySummary: String {
        if let integrityStatus, integrityStatus != .verified {
            return integrityStatus.title
        }
        return shortArtifactFingerprint.map {
            "SHA-256 \($0)"
        } ?? "Size verified"
    }
}

func boundedOfficeReceipts(
    _ receipts: [PDFOfficeExportReceipt]
) -> [PDFOfficeExportReceipt] {
    let prioritized = receipts.sorted {
        if $0.isPinned != $1.isPinned {
            return $0.isPinned
        }
        if $0.exportedAt != $1.exportedAt {
            return $0.exportedAt > $1.exportedAt
        }
        return $0.id.uuidString < $1.id.uuidString
    }
    var seenIDs = Set<UUID>()
    let unique = prioritized.filter {
        seenIDs.insert($0.id).inserted
    }
    return Array(unique.prefix(72))
        .sorted { $0.exportedAt > $1.exportedAt }
}

struct PDFOfficeExportFormatPlan:
    Identifiable,
    Hashable,
    Sendable {
    let format: PDFTextExportFormat
    let readiness: PDFOfficeExportReadiness
    let editabilityScore: Int
    let appearanceScore: Int
    let sizeScore: Int
    let primaryEvidence: String
    let riskEvidence: String
    let preferredUse: String
    let fallbackFormat: PDFTextExportFormat?

    var id: String { format.rawValue }

    var compositeScore: Int {
        (editabilityScore + appearanceScore + sizeScore) / 3
    }

    var decisionRole: String {
        switch format {
        case .wordDocument:
            return "Edit text"
        case .excelWorkbook:
            return "Extract tables"
        case .powerPointPresentation:
            return "Keep layout"
        case .richText:
            return "Quick edit"
        case .markdown:
            return "Knowledge base"
        case .plainText:
            return "Index text"
        }
    }

    var compactEvidence: String {
        AppLocalization.format(
            "E%lld A%lld S%lld",
            editabilityScore,
            appearanceScore,
            sizeScore
        )
    }

    var actionTitle: String {
        switch readiness {
        case .strong:
            return "Export"
        case .review:
            return "Export with review"
        case .limited:
            return "Export limited"
        }
    }

    static func plan(
        for format: PDFTextExportFormat,
        profile: DocumentProfile
    ) -> PDFOfficeExportFormatPlan {
        let pageCount = max(1, profile.pageCount)
        let textPercent = min(
            100,
            max(0, Int((profile.textCoverage * 100).rounded()))
        )
        let imagePercent = min(
            100,
            max(
                0,
                Int(
                    (
                        Double(profile.imageDominantPageCount)
                            / Double(pageCount)
                            * 100
                    ).rounded()
                )
            )
        )
        let isLarge = profile.pageCount > 300
            || profile.byteCount > 256 * 1_024 * 1_024
        let isLocked = profile.isLocked || profile.isEncrypted
        let copyingRestricted = !profile.allowsCopying
        let exceedsPageLimit = format.officePageLimit
            .map { pageCount > $0 } ?? false
        let riskPrefix = exceedsPageLimit
            ? AppLocalization.format(
                "%@ limit %lld pages",
                format.fileExtension.uppercased(),
                format.officePageLimit ?? 0
            )
            : isLocked
            ? "Locked source".localizedUI
            : copyingRestricted
                ? "Copy restricted".localizedUI
                : isLarge
                    ? "Large document".localizedUI
                    : imagePercent >= 45
                        ? "Image-heavy".localizedUI
                        : "Local rebuild".localizedUI

        func readiness(
            edit: Int,
            appearance: Int,
            size: Int
        ) -> PDFOfficeExportReadiness {
            if exceedsPageLimit || isLocked || copyingRestricted {
                return .limited
            }
            let score = (edit + appearance + size) / 3
            if score >= 76 {
                return .strong
            }
            if score >= 52 {
                return .review
            }
            return .limited
        }

        switch format {
        case .wordDocument:
            let edit = textPercent >= 80
                ? 92
                : textPercent >= 55 ? 74 : textPercent >= 25 ? 48 : 28
            let appearance = imagePercent >= 35 ? 82 : 64
            let size = isLarge ? 46 : profile.pageCount > 120 ? 64 : 82
            return PDFOfficeExportFormatPlan(
                format: format,
                readiness: readiness(
                    edit: edit,
                    appearance: appearance,
                    size: size
                ),
                editabilityScore: edit,
                appearanceScore: appearance,
                sizeScore: size,
                primaryEvidence: AppLocalization.format(
                    "%lld%% text · %@ source",
                    textPercent,
                    profile.formattedSize
                ),
                riskEvidence: AppLocalization.format(
                    "%@ · %lld image-heavy page%@",
                    riskPrefix,
                    profile.imageDominantPageCount,
                    profile.imageDominantPageCount == 1 ? "" : "s"
                ),
                preferredUse:
                    "Narrative PDFs, briefs, contracts, and mixed text/table pages",
                fallbackFormat: imagePercent >= 55
                    ? .powerPointPresentation
                    : nil
            )
        case .excelWorkbook:
            let edit = textPercent >= 70 ? 84 : textPercent >= 45 ? 62 : 32
            let appearance = 46
            let size = isLarge ? 62 : 90
            return PDFOfficeExportFormatPlan(
                format: format,
                readiness: readiness(
                    edit: edit,
                    appearance: appearance,
                    size: size
                ),
                editabilityScore: edit,
                appearanceScore: appearance,
                sizeScore: size,
                primaryEvidence: AppLocalization.format(
                    "%lld%% text · sheet per page",
                    textPercent
                ),
                riskEvidence: AppLocalization.format(
                    "%@ · %@",
                    riskPrefix,
                    "Tables inferred from spacing".localizedUI
                ),
                preferredUse:
                    "Statements, tabular reports, price lists, and ledgers",
                fallbackFormat: textPercent < 45
                    ? .wordDocument
                    : nil
            )
        case .powerPointPresentation:
            let edit = textPercent >= 45 ? 58 : 34
            let appearance = imagePercent >= 35 ? 96 : 88
            let size = profile.pageCount > 160 ? 44 : 72
            return PDFOfficeExportFormatPlan(
                format: format,
                readiness: readiness(
                    edit: edit,
                    appearance: appearance,
                    size: size
                ),
                editabilityScore: edit,
                appearanceScore: appearance,
                sizeScore: size,
                primaryEvidence: AppLocalization.format(
                    "%lld%% appearance · searchable layer",
                    appearance
                ),
                riskEvidence: AppLocalization.format(
                    "%@ · %@",
                    riskPrefix,
                    "Rendered slides can be larger".localizedUI
                ),
                preferredUse:
                    "Scans, visual reports, layouts, posters, and decks",
                fallbackFormat: profile.pageCount > 220
                    ? .wordDocument
                    : nil
            )
        case .richText:
            let edit = textPercent >= 60 ? 78 : 38
            let appearance = 36
            let size = 94
            return PDFOfficeExportFormatPlan(
                format: format,
                readiness: readiness(
                    edit: edit,
                    appearance: appearance,
                    size: size
                ),
                editabilityScore: edit,
                appearanceScore: appearance,
                sizeScore: size,
                primaryEvidence: AppLocalization.format(
                    "%lld%% text · styled paragraphs",
                    textPercent
                ),
                riskEvidence: AppLocalization.format(
                    "%@ · %@",
                    riskPrefix,
                    "No visual page references".localizedUI
                ),
                preferredUse: "Fast handoff to Word-compatible editors",
                fallbackFormat: nil
            )
        case .markdown:
            let edit = textPercent >= 60 ? 72 : 34
            return PDFOfficeExportFormatPlan(
                format: format,
                readiness: readiness(
                    edit: edit,
                    appearance: 18,
                    size: 98
                ),
                editabilityScore: edit,
                appearanceScore: 18,
                sizeScore: 98,
                primaryEvidence: AppLocalization.format(
                    "%lld%% text · plain structure",
                    textPercent
                ),
                riskEvidence: AppLocalization.format(
                    "%@ · %@",
                    riskPrefix,
                    "Styling is intentionally removed".localizedUI
                ),
                preferredUse: "Knowledge bases, developer notes, and review",
                fallbackFormat: nil
            )
        case .plainText:
            let edit = textPercent >= 40 ? 64 : 26
            return PDFOfficeExportFormatPlan(
                format: format,
                readiness: readiness(
                    edit: edit,
                    appearance: 0,
                    size: 100
                ),
                editabilityScore: edit,
                appearanceScore: 0,
                sizeScore: 100,
                primaryEvidence: AppLocalization.format(
                    "%lld%% text · UTF-8 output",
                    textPercent
                ),
                riskEvidence: AppLocalization.format(
                    "%@ · %@",
                    riskPrefix,
                    "No layout reconstruction".localizedUI
                ),
                preferredUse: "Search, indexing, and maximum compatibility",
                fallbackFormat: nil
            )
        }
    }
}

struct PDFOfficeExportPortfolio: Hashable, Sendable {
    let pageCount: Int
    let sourceBytes: Int64
    let textCoveragePercent: Int
    let imageDominantPageCount: Int
    let formFieldCount: Int
    let isProtected: Bool
    let visualBudgetPlan: PDFOfficeVisualBudgetPlan
    let plans: [PDFOfficeExportFormatPlan]
    let preflightSignals: [PDFOfficePreflightSignal]

    init(profile: DocumentProfile) {
        pageCount = profile.pageCount
        sourceBytes = profile.byteCount
        textCoveragePercent = min(
            100,
            max(0, Int((profile.textCoverage * 100).rounded()))
        )
        imageDominantPageCount = profile.imageDominantPageCount
        formFieldCount = profile.formFieldCount
        isProtected = profile.isLocked
            || profile.isEncrypted
            || !profile.allowsCopying
        visualBudgetPlan = PDFOfficeVisualBudgetPlan(profile: profile)
        plans = [
            .wordDocument,
            .excelWorkbook,
            .powerPointPresentation
        ].map {
            PDFOfficeExportFormatPlan.plan(for: $0, profile: profile)
        }
        preflightSignals = PDFOfficeExportPortfolio
            .makePreflightSignals(
                profile: profile,
                textCoveragePercent: textCoveragePercent,
                isProtected: isProtected,
                visualBudgetPlan: visualBudgetPlan
            )
    }

    var recommendedPlan: PDFOfficeExportFormatPlan? {
        let eligiblePlans = plans.filter {
            $0.readiness != .limited
        }
        return (eligiblePlans.isEmpty ? plans : eligiblePlans).max {
            $0.compositeScore < $1.compositeScore
        }
    }

    var secondChoicePlan: PDFOfficeExportFormatPlan? {
        let eligiblePlans = plans.filter {
            $0.readiness != .limited
        }
        return (eligiblePlans.count > 1 ? eligiblePlans : plans)
            .sorted {
                $0.compositeScore > $1.compositeScore
            }
            .dropFirst()
            .first
    }

    var routeConfidence: PDFOfficeRouteConfidence {
        guard let recommendedPlan else { return .guarded }
        let scoreGap = recommendedPlan.compositeScore
            - (secondChoicePlan?.compositeScore ?? 0)
        if isProtected
            || recommendedPlan.readiness == .limited
            || limitedSignalCount > 1 {
            return .weak
        }
        if recommendedPlan.readiness == .review
            || reviewSignalCount > 0
            || visualBudgetPlan.budgetPressure == .tight
            || scoreGap < 8 {
            return .guarded
        }
        return .high
    }

    var productionSLA: PDFOfficeProductionSLA {
        PDFOfficeProductionSLA(
            pageCount: pageCount,
            sourceBytes: sourceBytes,
            visualBudgetPlan: visualBudgetPlan,
            isProtected: isProtected
        )
    }

    var decisionLine: String {
        guard let recommendedPlan else {
            return "Local Office rebuild".localizedUI
        }
        if let secondChoicePlan {
            return AppLocalization.format(
                "%@ · %@ · score %lld · fallback %@",
                recommendedPlan.format.fileExtension.uppercased(),
                recommendedPlan.decisionRole.localizedUI,
                recommendedPlan.compositeScore,
                secondChoicePlan.format.fileExtension.uppercased()
            )
        }
        return AppLocalization.format(
            "%@ · %@ · score %lld",
            recommendedPlan.format.fileExtension.uppercased(),
            recommendedPlan.decisionRole.localizedUI,
            recommendedPlan.compositeScore
        )
    }

    var decisionDeckLine: String {
        AppLocalization.format(
            "%@ confidence · %@ · %@",
            routeConfidence.title.localizedUI,
            productionSLA.window.localizedUI,
            visualBudgetPlan.pressureContract
        )
    }

    var embeddedAuditSummary: String {
        AppLocalization.format(
            "3 formats · 4 preflight checks · %@",
            visualBudgetPlan.memoryGuardSummary
        )
    }

    var outputBoundaryLine: String {
        if pageCount > 1_000 {
            return AppLocalization.format(
                "%lld pages · split before Office export",
                pageCount
            )
        }
        if pageCount > 500 {
            return AppLocalization.format(
                "%lld pages · split before PPTX · DOCX/XLSX up to 1,000",
                pageCount
            )
        }
        if visualBudgetPlan.chunkCount > 1 {
            return AppLocalization.format(
                "%lld pages · %@ · bounded package",
                pageCount,
                visualBudgetPlan.chunkSummary
            )
        }
        return AppLocalization.format(
            "%lld pages · single package · local only",
            pageCount
        )
    }

    var suggestedSegmentCount: Int {
        guard pageCount > 0 else { return 1 }
        return max(
            1,
            Int(
                ceil(
                    Double(pageCount)
                        / Double(
                            productionSLA == .heavy ? 180 : 300
                        )
                )
            )
        )
    }

    var cautionLine: String {
        preflightLeadSignal?.detail
            ?? "Editable structure and local evidence are preserved"
                .localizedUI
    }

    var preflightLeadSignal: PDFOfficePreflightSignal? {
        preflightSignals.first { $0.readiness == .limited }
            ?? preflightSignals.first { $0.readiness == .review }
            ?? preflightSignals.first
    }

    var limitedSignalCount: Int {
        preflightSignals.filter { $0.readiness == .limited }.count
    }

    var reviewSignalCount: Int {
        preflightSignals.filter { $0.readiness == .review }.count
    }

    var preflightSummary: String {
        if limitedSignalCount > 0 {
            return AppLocalization.format(
                "%lld limited · %lld review",
                limitedSignalCount,
                reviewSignalCount
            )
        }
        if reviewSignalCount > 0 {
            return AppLocalization.format(
                "%lld review · local rebuild",
                reviewSignalCount
            )
        }
        return "Ready · local rebuild".localizedUI
    }

    var routeRankLine: String {
        plans
            .sorted { $0.compositeScore > $1.compositeScore }
            .map {
                AppLocalization.format(
                    "%@ %@",
                    $0.format.fileExtension.uppercased(),
                    "\($0.compositeScore)"
                )
            }
            .joined(separator: " · ")
    }

    var primaryRiskSignal: PDFOfficePreflightSignal? {
        preflightSignals.first { $0.readiness == .limited }
            ?? preflightSignals.first { $0.readiness == .review }
    }

    var recoveryActions: [PDFOfficeRecoveryAction] {
        var actions: [PDFOfficeRecoveryAction] = []
        if isProtected {
            actions.append(
                PDFOfficeRecoveryAction(
                    id: "permissions",
                    title: "Create an unlocked working copy",
                    detail: "Editable Office output is limited until source rights allow reconstruction.",
                    symbol: "lock.open",
                    tintRole: .limited
                )
            )
        }
        if textCoveragePercent < 34 {
            actions.append(
                PDFOfficeRecoveryAction(
                    id: "ocr",
                    title: "Run OCR before Office",
                    detail: "Low text coverage makes visual routes safer than editable paragraphs.",
                    symbol: "text.viewfinder",
                    tintRole: .review
                )
            )
        }
        if imageDominantPageCount > 0,
           pageCount <= (
               PDFTextExportFormat.powerPointPresentation
                   .officePageLimit ?? .max
           ),
           recommendedPlan?.format != .powerPointPresentation {
            actions.append(
                PDFOfficeRecoveryAction(
                    id: "pptx-visual",
                    title: "Use PPTX for visual fidelity",
                    detail: "Image-heavy pages keep their appearance better as searchable slides.",
                    symbol: "rectangle.on.rectangle.angled",
                    tintRole: .strong,
                    targetFormat: .powerPointPresentation
                )
            )
        }
        if visualBudgetPlan.budgetPressure == .tight
            || visualBudgetPlan.chunkCount > 1 {
            actions.append(
                PDFOfficeRecoveryAction(
                    id: "bounded-docx",
                    title: "Prefer bounded DOCX",
                    detail: "Sliding windows protect memory while preserving critical visual anchors.",
                    symbol: "externaldrive.badge.checkmark",
                    tintRole: .review,
                    targetFormat: .wordDocument
                )
            )
        }
        if pageCount > 300 || visualBudgetPlan.chunkCount > 4 {
            actions.insert(
                PDFOfficeRecoveryAction(
                    id: "split-office-source",
                    title: "Split for controlled export",
                    detail: AppLocalization.format(
                        "%lld segments keep each Office package responsive and reviewable.",
                        suggestedSegmentCount
                    ),
                    symbol: "rectangle.split.3x1",
                    tintRole: .review,
                    targetQuickTask: .splitPDF
                ),
                at: min(isProtected ? 1 : 0, actions.count)
            )
        }
        return Array(actions.prefix(3))
    }

    func plan(
        for format: PDFTextExportFormat
    ) -> PDFOfficeExportFormatPlan {
        plans.first { $0.format == format }
            ?? PDFOfficeExportFormatPlan.plan(
                for: format,
                profile: .empty
            )
    }

    private static func makePreflightSignals(
        profile: DocumentProfile,
        textCoveragePercent: Int,
        isProtected: Bool,
        visualBudgetPlan: PDFOfficeVisualBudgetPlan
    ) -> [PDFOfficePreflightSignal] {
        let rights = PDFOfficePreflightSignal(
            id: "rights",
            title: "Rights",
            value: isProtected ? "Limited" : "Rights clear",
            detail: isProtected
                ? "Protected source can limit editable Office output"
                : "Source permissions allow local reconstruction",
            symbol: isProtected
                ? "lock.trianglebadge.exclamationmark"
                : "lock.open.fill",
            readiness: isProtected ? .limited : .strong
        )
        let structureReadiness: PDFOfficeExportReadiness
        let structureValue: String
        let structureDetail: String
        if textCoveragePercent >= 72 {
            structureReadiness = .strong
            structureValue = "\(textCoveragePercent)%"
            structureDetail = "Text layer is strong enough for editable routes"
        } else if textCoveragePercent >= 34 {
            structureReadiness = .review
            structureValue = "\(textCoveragePercent)%"
            structureDetail = "Mixed structure; verify paragraph and table flow"
        } else {
            structureReadiness = .limited
            structureValue = "\(textCoveragePercent)%"
            structureDetail = "Low text coverage; visual routes are safer"
        }
        let structure = PDFOfficePreflightSignal(
            id: "structure",
            title: "Structure",
            value: structureValue,
            detail: structureDetail,
            symbol: "text.magnifyingglass",
            readiness: structureReadiness
        )
        let visualReadiness: PDFOfficeExportReadiness
        switch visualBudgetPlan.budgetPressure {
        case .relaxed:
            visualReadiness = .strong
        case .managed:
            visualReadiness = .review
        case .tight:
            visualReadiness = .review
        }
        let visual = PDFOfficePreflightSignal(
            id: "visual",
            title: "Visual",
            value: visualBudgetPlan.budgetPressure.title,
            detail: visualBudgetPlan.estimatedVisualReferencePages == 0
                ? "No extra visual anchors expected"
                : "Layout anchors are prioritized under budget pressure",
            symbol: visualBudgetPlan.budgetPressure.symbol,
            readiness: visualReadiness
        )
        let packageReadiness: PDFOfficeExportReadiness
        if visualBudgetPlan.chunkCount <= 1 {
            packageReadiness = .strong
        } else if visualBudgetPlan.chunkCount <= 4 {
            packageReadiness = .review
        } else {
            packageReadiness = .limited
        }
        let package = PDFOfficePreflightSignal(
            id: "package",
            title: "Package",
            value: visualBudgetPlan.chunkSummary,
            detail: profile.byteCount > 256 * 1_024 * 1_024
                ? "Large source; package size and export time need review"
                : "Package budget is bounded before export",
            symbol: "shippingbox",
            readiness: packageReadiness
        )
        return [
            rights,
            structure,
            visual,
            package
        ]
    }
}

enum PDFPageImageExportPreset: String, CaseIterable, Identifiable, Sendable {
    case jpegHigh
    case jpegCompact
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpegHigh: return "JPEG Pages"
        case .jpegCompact: return "Compact JPEG Pages"
        case .png: return "PNG Pages"
        }
    }

    var detail: String {
        switch self {
        case .jpegHigh:
            return "High-quality photos and sharing"
        case .jpegCompact:
            return "Smaller files for messaging"
        case .png:
            return "Lossless pages for review and archiving"
        }
    }

    var symbol: String {
        switch self {
        case .jpegHigh: return "photo"
        case .jpegCompact: return "photo.badge.arrow.down"
        case .png: return "photo.on.rectangle.angled"
        }
    }
}

struct PDFEmbeddedImageExportResult: Sendable {
    let urls: [URL]
    let occurrenceCount: Int
    let unsupportedOccurrenceCount: Int
    let originalStreamFileCount: Int
    let losslessPNGFileCount: Int

    var uniqueImageCount: Int {
        urls.count
    }
}

enum DocumentKind: String, Codable, CaseIterable, Identifiable {
    case text
    case scan
    case mixed
    case form
    case protected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text PDF"
        case .scan: return "Scanned PDF"
        case .mixed: return "Mixed PDF"
        case .form: return "Form"
        case .protected: return "Protected"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "doc.text"
        case .scan: return "viewfinder"
        case .mixed: return "square.stack.3d.up"
        case .form: return "list.bullet.clipboard"
        case .protected: return "lock.doc"
        }
    }

}

enum DocumentAction:
    String,
    Codable,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case brief
    case recognizeText
    case makeSearchable
    case organizePages
    case reviewForm
    case sign
    case safeShare
    case inspect
    case shareCopy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Brief"
        case .recognizeText: return "Recognize"
        case .makeSearchable: return "Searchable"
        case .organizePages: return "Pages"
        case .reviewForm: return "Fill"
        case .sign: return "Sign"
        case .safeShare: return "Verify & Share"
        case .inspect: return "Inspect"
        case .shareCopy: return "Share"
        }
    }

    var explanation: String {
        switch self {
        case .brief:
            return "Review locally extracted facts and suggested next steps."
        case .recognizeText:
            return "Extract text locally from image-based pages."
        case .makeSearchable:
            return "Create a new PDF copy with a searchable local text layer."
        case .organizePages:
            return "Rotate, move, or remove pages in the working copy."
        case .reviewForm:
            return "Review the detected form fields in the document."
        case .sign:
            return "Draw or reuse a signature and place it on this page."
        case .safeShare:
            return "Create a flattened copy and verify every output page."
        case .inspect:
            return "See what PaperPath found and why it recommended these actions."
        case .shareCopy:
            return "Export the current private working copy."
        }
    }

    var symbol: String {
        switch self {
        case .brief: return "list.bullet.rectangle.portrait"
        case .recognizeText: return "text.viewfinder"
        case .makeSearchable: return "doc.text.magnifyingglass"
        case .organizePages: return "square.grid.2x2"
        case .reviewForm: return "pencil.and.list.clipboard"
        case .sign: return "signature"
        case .safeShare: return "checkmark.shield"
        case .inspect: return "sparkle.magnifyingglass"
        case .shareCopy: return "square.and.arrow.up"
        }
    }
}

struct DocumentActionPlanner {
    struct Recommendation: Equatable {
        let action: DocumentAction
        let reason: String
    }

    static func actions(
        for record: DocumentRecord,
        hasRecognizedText: Bool,
        hasCurrentVerifiedOutput: Bool = false
    ) -> [DocumentAction] {
        if record.isDeliveryArtifact {
            return record.hasCurrentDeliveryReceipt
                ? [.shareCopy, .inspect]
                : [.safeShare, .inspect]
        }

        if record.profile.isLocked {
            return [.inspect, .shareCopy]
        }

        var actions: [DocumentAction] = []
        if let checkpoint = record.taskCheckpoint {
            actions.append(checkpoint.stage.action)
        }
        if record.profile.kind == .scan || record.profile.kind == .mixed {
            actions.append(
                hasRecognizedText ? .makeSearchable : .recognizeText
            )
        }
        if record.profile.kind == .form {
            actions.append(.reviewForm)
        }
        for step in record.brief?.suggestedSteps ?? [] {
            let action = action(for: step)
            if action == .recognizeText, hasRecognizedText {
                continue
            }
            guard !record.completedActions.contains(action) else { continue }
            if !actions.contains(action) {
                actions.append(action)
            }
        }
        actions.removeAll {
            record.completedActions.contains($0)
                && record.taskCheckpoint?.stage.action != $0
        }
        let shouldPrepareSafeShare = record.taskCheckpoint == nil
            && !hasCurrentVerifiedOutput
            && (
                record.completedActions.contains(.safeShare)
                    || record.completedActions.contains(.sign)
                    || record.completedActions.contains(.reviewForm)
                    || record.workflowStatus == .ready
            )
        if shouldPrepareSafeShare {
            actions.insert(.safeShare, at: 0)
        }
        if record.profile.pageCount > 1 {
            actions.append(.organizePages)
        }
        if record.brief?.entities.isEmpty == false,
           !actions.contains(.brief) {
            actions.append(.brief)
        }
        if hasCurrentVerifiedOutput {
            actions.insert(.shareCopy, at: 0)
        } else {
            actions.append(.safeShare)
        }
        if let checkpoint = record.taskCheckpoint {
            let checkpointAction = checkpoint.stage.action
            actions.removeAll { $0 == checkpointAction }
            actions.insert(checkpointAction, at: 0)
        }
        return Array(uniqued(actions).prefix(5))
    }

    static func recommendation(
        for record: DocumentRecord,
        hasRecognizedText: Bool,
        hasCurrentVerifiedOutput: Bool = false
    ) -> Recommendation {
        let action = actions(
            for: record,
            hasRecognizedText: hasRecognizedText,
            hasCurrentVerifiedOutput: hasCurrentVerifiedOutput
        ).first ?? .safeShare
        return Recommendation(
            action: action,
            reason: reason(
                for: action,
                record: record,
                hasRecognizedText: hasRecognizedText
            )
        )
    }

    static func action(for step: SuggestedStep) -> DocumentAction {
        switch step.kind {
        case .recognize:
            return .recognizeText
        case .completeForm:
            return .reviewForm
        case .reviewSignature:
            return .sign
        case .organize:
            return .organizePages
        case .share:
            return .safeShare
        case .reviewDate, .reviewAmount:
            return .brief
        }
    }

    private static func reason(
        for action: DocumentAction,
        record: DocumentRecord,
        hasRecognizedText: Bool
    ) -> String {
        if let checkpoint = record.taskCheckpoint,
           checkpoint.stage.action == action {
            return checkpoint.resumeReason
        }
        if let step = record.brief?.suggestedSteps.first(
            where: {
                self.action(for: $0) == action
                    && !record.completedActions.contains(action)
            }
        ) {
            return String(step.evidence.prefix(140))
        }
        switch action {
        case .recognizeText:
            return "Image-based pages do not yet contain searchable text."
                .localizedUI
        case .makeSearchable:
            return hasRecognizedText
                ? "Recognized text is ready to embed in a new PDF copy."
                    .localizedUI
                : action.explanation.localizedUI
        case .reviewForm:
            return AppLocalization.format(
                "%lld interactive field%@ detected.",
                record.profile.formFieldCount,
                record.profile.formFieldCount == 1 ? "" : "s"
            )
        case .organizePages:
            return AppLocalization.format(
                "%lld pages are available to reorder, rotate, or extract.",
                record.profile.pageCount
            )
        case .safeShare:
            return "Your completed work is ready for a flattened, verified copy."
                .localizedUI
        case .brief:
            return "PaperPath found evidence worth checking before delivery."
                .localizedUI
        case .shareCopy:
            if let receipt = record.deliveryReceipt {
                return AppLocalization.format(
                    "%@ checked with a SHA-256 receipt.",
                    receipt.operation.title.localizedUI
                )
            }
            if record.completedActions.contains(.safeShare) {
                return "A verified delivery copy has already been created."
                    .localizedUI
            }
            return action.explanation.localizedUI
        case .sign, .inspect:
            return action.explanation.localizedUI
        }
    }

    private static func uniqued(
        _ actions: [DocumentAction]
    ) -> [DocumentAction] {
        var seen: Set<DocumentAction> = []
        return actions.filter { seen.insert($0).inserted }
    }
}

enum DocumentToolGroup: String, CaseIterable, Identifiable {
    case understand
    case markUp
    case finish
    case pages
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .understand: return "Read & understand"
        case .markUp: return "Edit & mark up"
        case .finish: return "Finish & protect"
        case .pages: return "Manage pages"
        case .export: return "Export & share"
        }
    }
}

enum DocumentTool: String, CaseIterable, Identifiable, Hashable {
    case brief
    case find
    case recognize
    case highlight
    case underline
    case strikeOut
    case ink
    case note
    case stamp
    case watermark
    case bates
    case content
    case links
    case annotations
    case attachments
    case compare
    case sign
    case redact
    case fillForm
    case bookmarks
    case organize
    case compress
    case protect
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "Brief"
        case .find: return "Find"
        case .recognize: return "Recognize"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeOut: return "Strike"
        case .ink: return "Draw"
        case .note: return "Note"
        case .stamp: return "Stamp"
        case .watermark: return "Watermark"
        case .bates: return "Bates Numbering"
        case .content: return "Add Content"
        case .links: return "Edit Links"
        case .annotations: return "Annotations"
        case .attachments: return "Attachments"
        case .compare: return "Compare Versions"
        case .sign: return "Sign"
        case .redact: return "Redact"
        case .fillForm: return "Fill Form"
        case .bookmarks: return "Bookmarks"
        case .organize: return "Organize"
        case .compress: return "Compress"
        case .protect: return "Protect"
        case .export: return "Export"
        }
    }

    var compactTitle: String {
        switch self {
        case .recognize: return "OCR"
        case .strikeOut: return "Strike"
        case .content: return "Add"
        case .watermark: return "Watermark"
        case .bates: return "Bates"
        case .annotations: return "Reviews"
        case .attachments: return "Files"
        case .compare: return "Compare"
        case .fillForm: return "Fill"
        case .bookmarks: return "Saved"
        case .organize: return "Pages"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .brief: return "list.bullet.rectangle.portrait"
        case .find: return "text.magnifyingglass"
        case .recognize: return "text.viewfinder"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .ink: return "pencil.tip"
        case .note: return "note.text.badge.plus"
        case .stamp: return "seal"
        case .watermark: return "textformat.alt"
        case .bates: return "number.square.fill"
        case .content: return "text.badge.plus"
        case .links: return "link"
        case .annotations: return "text.bubble"
        case .attachments: return "paperclip"
        case .compare: return "doc.on.doc"
        case .sign: return "signature"
        case .redact: return "eye.slash"
        case .fillForm: return "pencil.and.list.clipboard"
        case .bookmarks: return "bookmark"
        case .organize: return "square.grid.2x2"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .protect: return "lock.doc"
        case .export: return "square.and.arrow.up"
        }
    }

    var detail: String {
        switch self {
        case .brief: return "Facts, evidence, and next steps"
        case .find: return "Locate text in this document"
        case .recognize: return "Index image-based pages on device"
        case .highlight: return "Mark the selected text"
        case .underline: return "Underline the selected text"
        case .strikeOut: return "Strike through the selected text"
        case .ink: return "Write with Pencil or touch"
        case .note: return "Place a comment on this page"
        case .stamp: return "Add a standard review stamp"
        case .watermark:
            return "Mark selected pages for review or distribution"
        case .bates:
            return "Assign fixed-width IDs to selected pages"
        case .content: return "Add movable text, a photo, or a web link"
        case .links: return "Move, resize, retarget, or remove existing links"
        case .annotations: return "Review or remove saved markup"
        case .attachments:
            return "Inspect and extract files embedded in this PDF"
        case .compare:
            return "Find visible, text, and page-size changes"
        case .sign: return "Draw and place a vector signature"
        case .redact: return "Permanently remove selected content"
        case .fillForm: return "Check and complete interactive fields"
        case .bookmarks: return "Open saved pages and document outline"
        case .organize:
            return "Reorder, number, crop, insert, or extract pages"
        case .compress: return "Create a smaller sharing copy"
        case .protect: return "Create a password-protected copy"
        case .export:
            return "PDF, Word, Excel, PowerPoint, text, or images"
        }
    }

    var group: DocumentToolGroup {
        switch self {
        case .brief, .find, .recognize, .compare:
            return .understand
        case .highlight, .underline, .strikeOut, .ink, .note, .stamp,
             .content, .links, .annotations, .attachments:
            return .markUp
        case .watermark, .bates, .sign, .redact, .fillForm, .protect:
            return .finish
        case .bookmarks, .organize:
            return .pages
        case .compress, .export:
            return .export
        }
    }

    var searchAliases: String {
        switch self {
        case .brief: return "summary facts evidence digest 摘要 总结 事实 依据"
        case .find: return "search locate find 查找 搜索 定位"
        case .recognize:
            return "ocr scan text recognize searchable find words 识别 扫描文字 文字识别 可搜索 搜文字"
        case .highlight: return "marker yellow highlight 高亮 标记"
        case .underline: return "line underline 下划线"
        case .strikeOut: return "delete strike strikethrough 删除线 划掉"
        case .ink: return "draw pencil handwriting freehand 画笔 手写 涂写"
        case .note: return "comment sticky note 批注 便签 备注"
        case .stamp: return "approved draft seal stamp 印章 批准 草稿 盖章"
        case .watermark:
            return "confidential draft internal do not copy watermark 机密 草稿 内部 禁止复制 水印"
        case .bates:
            return "bates legal exhibit discovery prefix suffix sequence 连续编号 卷宗 证据 序号 前缀 后缀"
        case .content: return "add text photo image link edit 添加文字 图片 链接 编辑"
        case .links: return "existing link target page url edit 现有链接 目标 跳页"
        case .annotations: return "markup review annotations 批注列表 标记 批注"
        case .attachments:
            return "embedded files paperclip attachment extract 附件 嵌入文件 提取"
        case .compare:
            return "compare diff revision version changes 对比 比较 版本 差异 修改"
        case .sign: return "signature autograph sign 签名 签字 署名"
        case .redact: return "blackout sensitive mask redact 脱敏 打码 遮挡 隐私"
        case .fillForm: return "field type form fill 表单 填写 填表"
        case .bookmarks: return "outline saved page bookmarks 书签 目录 大纲"
        case .organize:
            return "reorder number paginate rotate crop pages organize 页面 页码 编号 排序 旋转 裁切"
        case .compress:
            return "smaller shrink size compress too large attachment message 压缩 瘦身 变小 太大 发邮件 发微信"
        case .protect: return "password encrypt lock protect 密码 加密 上锁"
        case .export:
            return "send share finish flatten images text docx xlsx pptx word excel powerpoint office export convert final 发出去 发送 导出 分享 转换 最终版"
        }
    }

    func matches(_ query: String) -> Bool {
        matchScore(query) != nil
    }

    func matchScore(_ query: String) -> Int? {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        let terms = SearchTextNormalizer.meaningfulTerms(in: query)
        guard !terms.isEmpty else { return nil }
        let normalizedTitle = SearchTextNormalizer.normalize(title)
        let normalizedCompactTitle = SearchTextNormalizer.normalize(
            compactTitle
        )
        let normalizedDetail = SearchTextNormalizer.normalize(detail)
        let normalizedGroup = SearchTextNormalizer.normalize(group.title)
        let normalizedAliases = SearchTextNormalizer.normalize(searchAliases)
        let text = SearchTextNormalizer.normalize(
            "\(title) \(detail) \(group.title) \(searchAliases)"
        )
        let matchedTermCount = terms.reduce(into: 0) { count, term in
            if text.contains(term) {
                count += 1
            }
        }
        let intentHitCount = SearchTextNormalizer.intentHitCount(
            query: normalizedQuery,
            searchableText: text
        )
        guard matchedTermCount == terms.count || intentHitCount > 0 else {
            return nil
        }

        var score = 0
        if normalizedTitle == normalizedQuery
            || normalizedCompactTitle == normalizedQuery {
            score += 1_000
        } else if normalizedTitle.hasPrefix(normalizedQuery)
            || normalizedCompactTitle.hasPrefix(normalizedQuery) {
            score += 700
        }

        for term in terms {
            if normalizedTitle.contains(term)
                || normalizedCompactTitle.contains(term) {
                score += 180
            } else if normalizedAliases.contains(term) {
                score += 90
            } else if normalizedDetail.contains(term) {
                score += 50
            } else if normalizedGroup.contains(term) {
                score += 20
            }
        }
        score += min(intentHitCount, 3) * 30
        return score
    }
}

enum PDFReadingTheme: String, CaseIterable, Identifiable, Codable {
    case paper
    case sepia
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return "Paper"
        case .sepia: return "Warm"
        case .night: return "Night Surround"
        }
    }

    var symbol: String {
        switch self {
        case .paper: return "sun.max"
        case .sepia: return "circle.lefthalf.filled"
        case .night: return "moon.stars"
        }
    }
}

enum PDFReadingLayout: String, CaseIterable, Identifiable, Codable {
    case continuous
    case singlePage
    case twoUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuous: return "Continuous"
        case .singlePage: return "Single Page"
        case .twoUp: return "Two Page"
        }
    }

    var symbol: String {
        switch self {
        case .continuous: return "rectangle.stack"
        case .singlePage: return "doc"
        case .twoUp: return "book.pages"
        }
    }
}

struct PDFReadingPreferences: Equatable, Codable {
    var theme: PDFReadingTheme = .paper
    var layout: PDFReadingLayout = .continuous
    var scrollsHorizontally = false
}

struct PDFProtectionPermissions: Hashable, Sendable {
    var allowsPrinting: Bool
    var allowsCopying: Bool
    var allowsCommenting: Bool
    var allowsFormFilling: Bool
    var allowsPageChanges: Bool

    static let restricted = Self(
        allowsPrinting: true,
        allowsCopying: false,
        allowsCommenting: true,
        allowsFormFilling: true,
        allowsPageChanges: false
    )
}

enum PDFMarkupKind: String, CaseIterable, Identifiable {
    case highlight
    case underline
    case strikeOut

    var id: String { rawValue }
}

enum PDFMarkupColor: String, CaseIterable, Identifiable, Codable {
    case yellow
    case mint
    case blue
    case pink
    case red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: return "Yellow"
        case .mint: return "Mint"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .red: return "Red"
        }
    }
}

enum PDFStampKind: String, CaseIterable, Identifiable, Sendable {
    case approved = "Approved"
    case draft = "Draft"
    case confidential = "Confidential"
    case final = "Final"
    case void = "Void"

    var id: String { rawValue }
    var title: String { rawValue }
    var stampName: String { rawValue }
}

enum PDFPageNumberFormat:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case number
    case page
    case pageOfTotal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .number: return "Number only"
        case .page: return "Page number"
        case .pageOfTotal: return "Page of total"
        }
    }

    func text(number: Int, total: Int) -> String {
        switch self {
        case .number:
            return "\(number)"
        case .page:
            return AppLocalization.format(
                "Page %lld",
                number
            )
        case .pageOfTotal:
            return AppLocalization.format(
                "Page %lld of %lld",
                number,
                total
            )
        }
    }
}

enum PDFPageNumberPosition:
    String,
    CaseIterable,
    Identifiable,
    Codable,
    Hashable,
    Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topCenter: return "arrow.up"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomCenter: return "arrow.down"
        case .bottomRight: return "arrow.down.right"
        }
    }
}

struct PDFPageNumberingPayload: Hashable, Sendable {
    let pageIndices: [Int]
    let startNumber: Int
    let format: PDFPageNumberFormat
    let position: PDFPageNumberPosition
}

struct PDFBatesNumberingPayload: Hashable, Sendable {
    let pageIndices: [Int]
    let startNumber: Int64
    let digitCount: Int
    let prefix: String
    let suffix: String
    let position: PDFPageNumberPosition

    static func maximumNumber(digitCount: Int) -> Int64 {
        guard (3...15).contains(digitCount) else { return 0 }
        return (0..<digitCount).reduce(Int64(0)) {
            value,
            _ in
            value * 10 + 9
        }
    }

    static func text(
        number: Int64,
        digitCount: Int,
        prefix: String,
        suffix: String
    ) -> String {
        let digits = String(number)
        let padding = String(
            repeating: "0",
            count: max(0, digitCount - digits.count)
        )
        return prefix + padding + digits + suffix
    }

    func text(number: Int64) -> String {
        Self.text(
            number: number,
            digitCount: digitCount,
            prefix: prefix,
            suffix: suffix
        )
    }

    static func normalizedAffix(
        _ value: String,
        name: String
    ) throws -> String {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).precomposedStringWithCanonicalMapping
        guard PDFEvidenceContract.isSafeDisplayText(
                  normalized,
                  maximumCharacters: 24,
                  maximumUTF8Bytes: 96,
                  allowsEmpty: true
              ),
              !normalized.contains("#")
        else {
            throw PaperPathError.insufficientSelection(
                name == "prefix"
                    ? "The Bates prefix cannot contain #, line breaks, or direction controls."
                    : "The Bates suffix cannot contain #, line breaks, or direction controls."
            )
        }
        return normalized
    }
}

struct PDFBatesBatchPlanItem: Identifiable, Hashable, Sendable {
    let recordID: UUID
    let sourceRevisionID: UUID
    let sourceName: String
    let pageCount: Int
    let startNumber: Int64
    let endNumber: Int64

    var id: UUID { recordID }
}

struct PDFBatesBatchPlan: Hashable, Sendable {
    static let maximumDocumentCount = 64
    static let maximumPageCount = 10_000

    let items: [PDFBatesBatchPlanItem]
    let digitCount: Int
    let prefix: String
    let suffix: String
    let position: PDFPageNumberPosition

    init(
        records: [DocumentRecord],
        startNumber: Int64,
        digitCount: Int,
        prefix: String,
        suffix: String,
        position: PDFPageNumberPosition
    ) throws {
        guard records.count >= 2 else {
            throw PaperPathError.insufficientSelection(
                "Choose at least two PDFs for continuous Bates numbering."
            )
        }
        guard records.count <= Self.maximumDocumentCount else {
            throw PaperPathError.insufficientSelection(
                "Bates number up to 64 PDFs at a time."
            )
        }
        guard Set(records.map(\.id)).count == records.count,
              records.allSatisfy({
                  $0.deletedAt == nil
                      && $0.isWorkingCopy
                      && !$0.profile.isLocked
                      && $0.profile.pageCount > 0
              })
        else {
            throw PaperPathError.insufficientSelection(
                "Choose unlocked working copies with at least one page."
            )
        }
        guard (3...15).contains(digitCount) else {
            throw PaperPathError.insufficientSelection(
                "Use between 3 and 15 digits."
            )
        }
        let normalizedPrefix = try PDFBatesNumberingPayload
            .normalizedAffix(prefix, name: "prefix")
        let normalizedSuffix = try PDFBatesNumberingPayload
            .normalizedAffix(suffix, name: "suffix")

        var totalPageCount = 0
        for record in records {
            let (nextCount, overflow) = totalPageCount
                .addingReportingOverflow(record.profile.pageCount)
            guard !overflow,
                  nextCount <= Self.maximumPageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "Bates number up to 10,000 pages in one batch."
                )
            }
            totalPageCount = nextCount
        }

        let maximumNumber = PDFBatesNumberingPayload.maximumNumber(
            digitCount: digitCount
        )
        let pageOffset = Int64(totalPageCount - 1)
        guard startNumber >= 1,
              startNumber <= maximumNumber - pageOffset
        else {
            throw PaperPathError.insufficientSelection(
                "The Bates sequence does not fit the selected digit width."
            )
        }

        var nextNumber = startNumber
        items = records.map { record in
            let endNumber = nextNumber
                + Int64(record.profile.pageCount - 1)
            defer { nextNumber = endNumber + 1 }
            return PDFBatesBatchPlanItem(
                recordID: record.id,
                sourceRevisionID: record.contentRevisionID,
                sourceName: record.displayName,
                pageCount: record.profile.pageCount,
                startNumber: nextNumber,
                endNumber: endNumber
            )
        }
        self.digitCount = digitCount
        self.prefix = normalizedPrefix
        self.suffix = normalizedSuffix
        self.position = position
    }

    var totalPageCount: Int {
        items.reduce(0) { $0 + $1.pageCount }
    }

    var firstIdentifier: String {
        guard let first = items.first else { return "" }
        return identifier(for: first.startNumber)
    }

    var lastIdentifier: String {
        guard let last = items.last else { return "" }
        return identifier(for: last.endNumber)
    }

    func identifier(for number: Int64) -> String {
        PDFBatesNumberingPayload.text(
            number: number,
            digitCount: digitCount,
            prefix: prefix,
            suffix: suffix
        )
    }

    func payload(for item: PDFBatesBatchPlanItem)
        -> PDFBatesNumberingPayload {
        PDFBatesNumberingPayload(
            pageIndices: Array(0..<item.pageCount),
            startNumber: item.startNumber,
            digitCount: digitCount,
            prefix: prefix,
            suffix: suffix,
            position: position
        )
    }
}

enum PDFBatesBatchProgressStage: Hashable, Sendable {
    case snapshotting
    case preparing
    case removing
    case committing

    var title: String {
        switch self {
        case .snapshotting: return "Saving recovery versions"
        case .preparing: return "Preparing numbered copies"
        case .removing: return "Preparing cleared copies"
        case .committing: return "Publishing verified changes"
        }
    }
}

struct PDFBatesBatchProgress: Hashable, Sendable {
    let stage: PDFBatesBatchProgressStage
    let completedDocumentCount: Int
    let totalDocumentCount: Int
    let completedPageCount: Int
    let totalPageCount: Int
    let currentDocumentName: String

    var fractionCompleted: Double {
        guard totalPageCount > 0 else { return 0 }
        let rawFraction: Double
        switch stage {
        case .snapshotting:
            rawFraction = 0.1 * Double(completedDocumentCount)
                / Double(max(1, totalDocumentCount))
        case .preparing, .removing:
            rawFraction = 0.1 + 0.78 * Double(completedPageCount)
                / Double(totalPageCount)
        case .committing:
            rawFraction = 0.9 + 0.1 * Double(completedDocumentCount)
                / Double(max(1, totalDocumentCount))
        }
        return min(1, max(0, rawFraction))
    }
}

struct PDFBatesBatchReceiptEntry:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { recordID }
    let recordID: UUID
    let displayName: String
    let pageCount: Int
    let startNumber: Int64
    let endNumber: Int64
    let startIdentifier: String
    let endIdentifier: String
    let sourceRevisionID: UUID
    let outputRevisionID: UUID
    let sourceSHA256: String
    let outputSHA256: String

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case displayName = "display_name"
        case pageCount = "page_count"
        case startNumber = "start_number"
        case endNumber = "end_number"
        case startIdentifier = "start_identifier"
        case endIdentifier = "end_identifier"
        case sourceRevisionID = "source_revision_id"
        case outputRevisionID = "output_revision_id"
        case sourceSHA256 = "source_sha256"
        case outputSHA256 = "output_sha256"
    }

    var shortOutputFingerprint: String {
        guard outputSHA256.count > 12 else { return outputSHA256 }
        return String(outputSHA256.prefix(12))
    }
}

struct PDFBatesBatchReceiptPayload:
    Codable,
    Hashable,
    Sendable {
    static let schema = "paperpath.bates-batch.v1"
    static let maximumReceiptCount = 24
    static let maximumHistoryBytes = 1 * 1_024 * 1_024

    let schema: String
    let batchID: UUID
    let createdAt: Date
    let digitCount: Int
    let prefix: String
    let suffix: String
    let position: PDFPageNumberPosition
    let totalPageCount: Int
    let firstIdentifier: String
    let lastIdentifier: String
    let entries: [PDFBatesBatchReceiptEntry]

    private enum CodingKeys: String, CodingKey {
        case schema
        case batchID = "batch_id"
        case createdAt = "created_at"
        case digitCount = "digit_count"
        case prefix
        case suffix
        case position
        case totalPageCount = "total_page_count"
        case firstIdentifier = "first_identifier"
        case lastIdentifier = "last_identifier"
        case entries
    }

    var documentCount: Int { entries.count }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        guard schema == Self.schema,
              PDFEvidenceContract.isPlausiblePastDate(
                createdAt,
                now: date
              ),
              !entries.isEmpty,
              entries.count
                <= PDFBatesBatchPlan.maximumDocumentCount,
              Set(entries.map(\.recordID)).count == entries.count,
              (3...15).contains(digitCount),
              totalPageCount > 0,
              totalPageCount <= PDFBatesBatchPlan.maximumPageCount,
              (try? PDFBatesNumberingPayload.normalizedAffix(
                  prefix,
                  name: "prefix"
              )) == prefix,
              (try? PDFBatesNumberingPayload.normalizedAffix(
                  suffix,
                  name: "suffix"
              )) == suffix,
              firstIdentifier == entries.first?.startIdentifier,
              lastIdentifier == entries.last?.endIdentifier
        else { return false }

        let maximumNumber = PDFBatesNumberingPayload.maximumNumber(
            digitCount: digitCount
        )
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdef"
        )
        var expectedStart = entries[0].startNumber
        var calculatedPageCount = 0
        for (index, entry) in entries.enumerated() {
            guard entry.pageCount > 0 else { return false }
            let (nextPageCount, pageCountOverflow) =
                calculatedPageCount.addingReportingOverflow(
                    entry.pageCount
                )
            let (expectedEnd, endNumberOverflow) =
                entry.startNumber.addingReportingOverflow(
                    Int64(entry.pageCount - 1)
                )
            guard !pageCountOverflow,
                  nextPageCount <= PDFBatesBatchPlan.maximumPageCount,
                  !endNumberOverflow,
                  PDFEvidenceContract.isSafeDisplayText(
                      entry.displayName,
                      maximumCharacters: 120,
                      maximumUTF8Bytes: 480
                  ),
                  entry.startNumber == expectedStart,
                  entry.startNumber >= 1,
                  entry.endNumber == expectedEnd,
                  entry.endNumber <= maximumNumber,
                  entry.startIdentifier
                    == PDFBatesNumberingPayload.text(
                        number: entry.startNumber,
                        digitCount: digitCount,
                        prefix: prefix,
                        suffix: suffix
                    ),
                  entry.endIdentifier
                    == PDFBatesNumberingPayload.text(
                        number: entry.endNumber,
                        digitCount: digitCount,
                        prefix: prefix,
                        suffix: suffix
                    ),
                  entry.sourceSHA256.count == 64,
                  entry.outputSHA256.count == 64,
                  entry.sourceSHA256.unicodeScalars.allSatisfy(
                      hexadecimal.contains
                  ),
                  entry.outputSHA256.unicodeScalars.allSatisfy(
                      hexadecimal.contains
                  )
            else { return false }
            calculatedPageCount = nextPageCount
            if index < entries.count - 1 {
                expectedStart = entry.endNumber + 1
            }
        }
        return calculatedPageCount == totalPageCount
    }
}

struct PDFBatesRemovalReceiptEntry:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { recordID }
    let recordID: UUID
    let displayName: String
    let pageCount: Int
    let numberedRevisionID: UUID
    let clearedRevisionID: UUID
    let numberedSHA256: String
    let clearedSHA256: String

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case displayName = "display_name"
        case pageCount = "page_count"
        case numberedRevisionID = "numbered_revision_id"
        case clearedRevisionID = "cleared_revision_id"
        case numberedSHA256 = "numbered_sha256"
        case clearedSHA256 = "cleared_sha256"
    }
}

struct PDFBatesRemovalReceiptPayload:
    Codable,
    Hashable,
    Sendable {
    static let schema = "paperpath.bates-removal.v1"

    let schema: String
    let removalID: UUID
    let batesBatchID: UUID
    let createdAt: Date
    let totalPageCount: Int
    let entries: [PDFBatesRemovalReceiptEntry]

    private enum CodingKeys: String, CodingKey {
        case schema
        case removalID = "removal_id"
        case batesBatchID = "bates_batch_id"
        case createdAt = "created_at"
        case totalPageCount = "total_page_count"
        case entries
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdef"
        )
        guard schema == Self.schema,
              PDFEvidenceContract.isPlausiblePastDate(
                createdAt,
                now: date
              ),
              !entries.isEmpty,
              entries.count <= PDFBatesBatchPlan.maximumDocumentCount,
              Set(entries.map(\.recordID)).count == entries.count,
              totalPageCount > 0,
              totalPageCount <= PDFBatesBatchPlan.maximumPageCount
        else { return false }
        var calculatedPageCount = 0
        for entry in entries {
            let (nextPageCount, overflow) =
                calculatedPageCount.addingReportingOverflow(
                    entry.pageCount
                )
            guard entry.pageCount > 0,
                  !overflow,
                  nextPageCount <= PDFBatesBatchPlan.maximumPageCount,
                  PDFEvidenceContract.isSafeDisplayText(
                      entry.displayName,
                      maximumCharacters: 120,
                      maximumUTF8Bytes: 480
                  ),
                  entry.numberedRevisionID != entry.clearedRevisionID,
                  entry.numberedSHA256.count == 64,
                  entry.clearedSHA256.count == 64,
                  entry.numberedSHA256.unicodeScalars.allSatisfy(
                      hexadecimal.contains
                  ),
                  entry.clearedSHA256.unicodeScalars.allSatisfy(
                      hexadecimal.contains
                  )
            else { return false }
            calculatedPageCount = nextPageCount
        }
        return calculatedPageCount == totalPageCount
    }

    func isLinked(
        to batesPayload: PDFBatesBatchReceiptPayload
    ) -> Bool {
        isLinked(
            to: batesPayload,
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isLinked(
        to batesPayload: PDFBatesBatchReceiptPayload,
        at date: Date
    ) -> Bool {
        guard isStructurallyValid(at: date),
              batesPayload.isStructurallyValid(at: date),
              batesBatchID == batesPayload.batchID,
              totalPageCount == batesPayload.totalPageCount,
              entries.count == batesPayload.entries.count
        else { return false }
        return zip(entries, batesPayload.entries).allSatisfy {
            removal,
            numbered in
            removal.recordID == numbered.recordID
                && removal.displayName == numbered.displayName
                && removal.pageCount == numbered.pageCount
                && removal.numberedRevisionID
                    == numbered.outputRevisionID
                && removal.numberedSHA256 == numbered.outputSHA256
        }
    }
}

struct PDFSignedBatesRemovalReceipt:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { payload.removalID }
    let payload: PDFBatesRemovalReceiptPayload
    let signature: PDFOfficeVerificationSignature
}

struct PDFSignedBatesBatchReceipt:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { payload.batchID }
    let payload: PDFBatesBatchReceiptPayload
    let signature: PDFOfficeVerificationSignature
    let removal: PDFSignedBatesRemovalReceipt?

    var shortKeyID: String {
        String(signature.keyID.prefix(8))
    }

    init(
        payload: PDFBatesBatchReceiptPayload,
        signature: PDFOfficeVerificationSignature,
        removal: PDFSignedBatesRemovalReceipt? = nil
    ) {
        self.payload = payload
        self.signature = signature
        self.removal = removal
    }
}

enum PDFBatesBatchEntryStatus:
    String,
    Hashable,
    Sendable {
    case current
    case changed
    case removed
    case inTrash
    case missing
    case untrusted

    var title: String {
        switch self {
        case .current: return "Current"
        case .changed: return "Changed"
        case .removed: return "Removed"
        case .inTrash: return "In Trash"
        case .missing: return "Missing"
        case .untrusted: return "Untrusted"
        }
    }

    var symbol: String {
        switch self {
        case .current: return "checkmark.circle.fill"
        case .changed: return "exclamationmark.triangle.fill"
        case .removed: return "arrow.uturn.backward.circle.fill"
        case .inTrash: return "trash.fill"
        case .missing: return "questionmark.diamond.fill"
        case .untrusted: return "xmark.seal.fill"
        }
    }
}

struct PDFBatesBatchReceiptVerificationItem:
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { entry.recordID }
    let entry: PDFBatesBatchReceiptEntry
    let status: PDFBatesBatchEntryStatus
    let actualRevisionID: UUID?
    let actualSHA256: String?

    var detail: String {
        switch status {
        case .current:
            return "Revision and SHA-256 match"
        case .changed:
            return "The working copy changed after this receipt"
        case .removed:
            return "The signed Bates removal matches this working copy"
        case .inTrash:
            return "The verified revision is currently in Trash"
        case .missing:
            return "The referenced private copy is unavailable"
        case .untrusted:
            return "The signed receipt payload could not be trusted"
        }
    }
}

struct PDFBatesBatchReceiptVerificationReport:
    Hashable,
    Sendable {
    let receiptID: UUID
    let checkedAt: Date
    let signatureStatus: PDFOfficeReportVerificationStatus
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let keyID: String?
    let items: [PDFBatesBatchReceiptVerificationItem]
    let detail: String

    var currentCount: Int {
        items.filter {
            $0.status == .current || $0.status == .removed
        }.count
    }

    var removedCount: Int {
        items.filter { $0.status == .removed }.count
    }

    var attentionCount: Int {
        items.count - currentCount
    }

    var hasMixedRemovalState: Bool {
        items.contains { $0.status == .current }
            && items.contains { $0.status == .removed }
    }

    var isCurrent: Bool {
        let allNumbered = items.allSatisfy { $0.status == .current }
        let allRemoved = items.allSatisfy { $0.status == .removed }
        return signatureStatus == .verified
            && !items.isEmpty
            && attentionCount == 0
            && (allNumbered || allRemoved)
    }
}

struct PDFBatesBatchReceiptInspection:
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { receipt.id }
    let sourceFileName: String
    let receipt: PDFSignedBatesBatchReceipt
    let report: PDFBatesBatchReceiptVerificationReport
}

struct PDFBatesExternalCandidate:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    let id: UUID
    let fileName: String
    let byteCount: Int64
    let sha256: String

    var shortFingerprint: String {
        String(sha256.prefix(12))
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

enum PDFBatesExternalEntryMatchStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case outputMatch
    case removedMatch
    case sourceMatch
    case missing
    case ambiguous

    var title: String {
        switch self {
        case .outputMatch: return "Numbered PDF matches"
        case .removedMatch: return "Cleared PDF matches"
        case .sourceMatch: return "Source PDF matches"
        case .missing: return "No matching PDF"
        case .ambiguous: return "Multiple matches"
        }
    }

    var symbol: String {
        switch self {
        case .outputMatch: return "checkmark.seal.fill"
        case .removedMatch: return "arrow.uturn.backward.circle.fill"
        case .sourceMatch: return "arrow.uturn.backward.circle.fill"
        case .missing: return "questionmark.diamond.fill"
        case .ambiguous: return "square.stack.3d.up.fill"
        }
    }
}

struct PDFBatesExternalEntryMatch:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { entry.recordID }
    let entry: PDFBatesBatchReceiptEntry
    let status: PDFBatesExternalEntryMatchStatus
    let candidates: [PDFBatesExternalCandidate]
}

struct PDFBatesExternalMatchReport:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    static let maximumFileCount = 64
    static let maximumFileBytes: Int64 =
        1 * 1_024 * 1_024 * 1_024
    static let maximumBatchBytes: Int64 =
        8 * 1_024 * 1_024 * 1_024

    let id: UUID
    let receiptID: UUID
    let checkedAt: Date
    let matches: [PDFBatesExternalEntryMatch]
    let unrecognizedCandidates: [PDFBatesExternalCandidate]
    let totalCandidateCount: Int
    let totalCandidateBytes: Int64

    var outputMatchCount: Int {
        matches.filter { $0.status == .outputMatch }.count
    }

    var sourceMatchCount: Int {
        matches.filter { $0.status == .sourceMatch }.count
    }

    var removedMatchCount: Int {
        matches.filter { $0.status == .removedMatch }.count
    }

    var missingCount: Int {
        matches.filter { $0.status == .missing }.count
    }

    var ambiguousCount: Int {
        matches.filter { $0.status == .ambiguous }.count
    }

    var isCompleteOutputSet: Bool {
        !matches.isEmpty
            && outputMatchCount == matches.count
            && unrecognizedCandidates.isEmpty
    }

    var isCompleteRemovedSet: Bool {
        !matches.isEmpty
            && removedMatchCount == matches.count
            && unrecognizedCandidates.isEmpty
    }
}

struct PDFBatesMatchReportPayload:
    Codable,
    Hashable,
    Sendable {
    static let schema = "paperpath.bates-match-report.v1"
    static let maximumEncodedBytes = 2 * 1_024 * 1_024

    let schema: String
    let reportID: UUID
    let createdAt: Date
    let receipt: PDFSignedBatesBatchReceipt
    let report: PDFBatesExternalMatchReport

    private enum CodingKeys: String, CodingKey {
        case schema
        case reportID = "report_id"
        case createdAt = "created_at"
        case receipt
        case report
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        guard schema == Self.schema,
              reportID == report.id,
              createdAt == report.checkedAt,
              PDFEvidenceContract.isPlausiblePastDate(
                createdAt,
                now: date
              ),
              receipt.payload.isStructurallyValid(at: date),
              receipt.removal?.payload.isLinked(
                  to: receipt.payload,
                  at: date
              ) ?? true,
              report.receiptID == receipt.id,
              report.matches.count == receipt.payload.entries.count,
              report.totalCandidateCount > 0,
              report.totalCandidateCount
                <= PDFBatesExternalMatchReport.maximumFileCount,
              report.totalCandidateBytes > 0,
              report.totalCandidateBytes
                <= PDFBatesExternalMatchReport.maximumBatchBytes,
              zip(
                  report.matches,
                  receipt.payload.entries
              ).allSatisfy({ pair in
                  pair.0.entry == pair.1
              })
        else { return false }

        let allOccurrences = report.matches.flatMap(\.candidates)
            + report.unrecognizedCandidates
        var candidatesByID: [UUID: PDFBatesExternalCandidate] = [:]
        for candidate in allOccurrences {
            guard PDFEvidenceContract.isSafeDisplayText(
                      candidate.fileName,
                      maximumCharacters: 160,
                      maximumUTF8Bytes: 240
                  ),
                  candidate.byteCount > 0,
                  candidate.byteCount
                    <= PDFBatesExternalMatchReport.maximumFileBytes,
                  Self.isSHA256(candidate.sha256)
            else { return false }
            if let existing = candidatesByID[candidate.id],
               existing != candidate {
                return false
            }
            candidatesByID[candidate.id] = candidate
        }
        let candidates = Array(candidatesByID.values)
        guard candidates.count == report.totalCandidateCount else {
            return false
        }
        var calculatedBytes: Int64 = 0
        for candidate in candidates {
            let (next, overflow) = calculatedBytes
                .addingReportingOverflow(candidate.byteCount)
            guard !overflow else { return false }
            calculatedBytes = next
        }
        guard calculatedBytes == report.totalCandidateBytes else {
            return false
        }

        let removalByRecordID = Dictionary(
            uniqueKeysWithValues: (
                receipt.removal?.payload.entries ?? []
            ).map { ($0.recordID, $0) }
        )
        let recognizedHashes = Set(
            receipt.payload.entries.flatMap { entry in
                var hashes = [
                    entry.outputSHA256,
                    entry.sourceSHA256
                ]
                if let cleared = removalByRecordID[entry.recordID]?
                    .clearedSHA256 {
                    hashes.append(cleared)
                }
                return hashes
            }
        )
        let expectedUnrecognized = Set(
            candidates.filter {
                !recognizedHashes.contains($0.sha256)
            }.map(\.id)
        )
        guard report.unrecognizedCandidates.count
                == Set(report.unrecognizedCandidates.map(\.id)).count,
              Set(report.unrecognizedCandidates.map(\.id))
                == expectedUnrecognized
        else { return false }

        let ownersByHash = Dictionary(
            grouping: receipt.payload.entries.flatMap { entry in
                var pairs = [
                    (entry.outputSHA256, entry.recordID),
                    (entry.sourceSHA256, entry.recordID)
                ]
                if let cleared = removalByRecordID[entry.recordID]?
                    .clearedSHA256 {
                    pairs.append((cleared, entry.recordID))
                }
                return pairs
            },
            by: { $0.0 }
        ).mapValues { Set($0.map(\.1)) }

        for match in report.matches {
            guard match.candidates.count
                    == Set(match.candidates.map(\.id)).count
            else { return false }
            let entry = match.entry
            let output = candidates.filter {
                $0.sha256 == entry.outputSHA256
            }
            let source = candidates.filter {
                $0.sha256 == entry.sourceSHA256
            }
            let removed = candidates.filter {
                $0.sha256
                    == removalByRecordID[entry.recordID]?.clearedSHA256
            }
            let combinedIDs = Set(
                (output + removed + source).map(\.id)
            )
            guard Set(match.candidates.map(\.id)) == combinedIDs else {
                return false
            }
            let expectedStatus: PDFBatesExternalEntryMatchStatus
            if output.count == 1,
               source.isEmpty,
               removed.isEmpty,
               ownersByHash[entry.outputSHA256]?.count == 1 {
                expectedStatus = .outputMatch
            } else if removed.count == 1,
                      output.isEmpty,
                      source.isEmpty,
                      removalByRecordID[entry.recordID].map({
                          ownersByHash[$0.clearedSHA256]?.count == 1
                      }) == true {
                expectedStatus = .removedMatch
            } else if source.count == 1,
                      output.isEmpty,
                      removed.isEmpty,
                      ownersByHash[entry.sourceSHA256]?.count == 1 {
                expectedStatus = .sourceMatch
            } else if combinedIDs.isEmpty {
                expectedStatus = .missing
            } else {
                expectedStatus = .ambiguous
            }
            guard match.status == expectedStatus else { return false }
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdef"
        )
        return value.count == 64
            && value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }
}

struct PDFSignedBatesMatchReport:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { payload.reportID }
    let payload: PDFBatesMatchReportPayload
    let signature: PDFOfficeVerificationSignature

    var shortKeyID: String {
        String(signature.keyID.prefix(8))
    }
}

struct PDFBatesMatchReportInspection:
    Hashable,
    Identifiable,
    Sendable {
    var id: UUID { signedReport.id }
    let sourceFileName: String
    let signedReport: PDFSignedBatesMatchReport
    let signatureStatus: PDFOfficeReportVerificationStatus
    let receiptSignatureStatus:
        PDFOfficeReportVerificationStatus
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let detail: String

    var isVerified: Bool {
        signatureStatus == .verified
            && receiptSignatureStatus == .verified
    }
}

struct PDFBatesExternalMatchProgress:
    Hashable,
    Sendable {
    let receiptID: UUID
    let completedFileCount: Int
    let totalFileCount: Int
    let processedBytes: Int64
    let totalBytes: Int64
    let currentFileName: String

    var fractionCompleted: Double {
        if totalBytes > 0 {
            return min(
                1,
                max(
                    0,
                    Double(processedBytes) / Double(totalBytes)
                )
            )
        }
        guard totalFileCount > 0 else { return 0 }
        return min(
            1,
            max(
                0,
                Double(completedFileCount) / Double(totalFileCount)
            )
        )
    }
}

struct PDFBatesBatchReceiptVerificationProgress:
    Hashable,
    Sendable {
    let receiptID: UUID
    let completedDocumentCount: Int
    let totalDocumentCount: Int
    let currentDocumentName: String

    var fractionCompleted: Double {
        guard totalDocumentCount > 0 else { return 0 }
        return min(
            1,
            max(
                0,
                Double(completedDocumentCount)
                    / Double(totalDocumentCount)
            )
        )
    }
}

enum PDFGeneratedAnnotationKind:
    String,
    CaseIterable,
    Hashable,
    Sendable {
    case pageNumber
    case watermark
    case batesNumber

    var author: String {
        switch self {
        case .pageNumber: return "PaperPath Page Numbers"
        case .watermark: return "PaperPath Watermark"
        case .batesNumber: return "PaperPath Bates Numbers"
        }
    }

    var title: String {
        switch self {
        case .pageNumber: return "Page Number"
        case .watermark: return "Watermark"
        case .batesNumber: return "Bates Number"
        }
    }

    var symbol: String {
        switch self {
        case .pageNumber: return "number.square"
        case .watermark: return "textformat.alt"
        case .batesNumber: return "number.square.fill"
        }
    }

    static func resolve(author: String?) -> Self? {
        allCases.first { $0.author == author }
    }
}

enum PDFWatermarkPreset:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case confidential
    case draft
    case internalUse
    case doNotCopy
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .confidential: return "Confidential"
        case .draft: return "Draft"
        case .internalUse: return "Internal Use"
        case .doNotCopy: return "Do Not Copy"
        case .custom: return "Custom"
        }
    }

    var defaultText: String {
        switch self {
        case .custom: return ""
        default: return title.uppercased()
        }
    }
}

enum PDFWatermarkLayout:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case diagonal
    case centered
    case header
    case footer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagonal: return "Diagonal"
        case .centered: return "Centered"
        case .header: return "Header"
        case .footer: return "Footer"
        }
    }

    var symbol: String {
        switch self {
        case .diagonal: return "arrow.up.right"
        case .centered: return "scope"
        case .header: return "arrow.up.to.line"
        case .footer: return "arrow.down.to.line"
        }
    }

    var rotationDegrees: Int {
        self == .diagonal ? 315 : 0
    }
}

enum PDFWatermarkTone:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case red
    case graphite
    case blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "Red"
        case .graphite: return "Graphite"
        case .blue: return "Blue"
        }
    }
}

enum PDFWatermarkIntensity:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case subtle
    case standard
    case bold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .standard: return "Standard"
        case .bold: return "Bold"
        }
    }

    var opacity: Double {
        switch self {
        case .subtle: return 0.14
        case .standard: return 0.22
        case .bold: return 0.32
        }
    }

    var scale: Double {
        switch self {
        case .subtle: return 0.82
        case .standard: return 1
        case .bold: return 1.16
        }
    }
}

struct PDFWatermarkPayload: Hashable, Sendable {
    let pageIndices: [Int]
    let text: String
    let layout: PDFWatermarkLayout
    let tone: PDFWatermarkTone
    let intensity: PDFWatermarkIntensity
}

struct PDFViewCommand: Identifiable, Equatable {
    enum Action: Equatable {
        case markup(PDFMarkupKind)
        case addNote(String)
        case markRedaction
        case captureTextForEditing
        case removeAnnotation
        case zoomIn
        case zoomOut
        case fitToWindow
    }

    let id = UUID()
    let action: Action
    let markupColor: PDFMarkupColor?

    init(
        action: Action,
        markupColor: PDFMarkupColor? = nil
    ) {
        self.action = action
        self.markupColor = markupColor
    }
}

struct PDFTextFlowRegion: Hashable, Sendable {
    let pageIndex: Int
    let normalizedX: Double
    let normalizedY: Double
    let normalizedWidth: Double
    let normalizedHeight: Double
    let lineCount: Int
    let originalText: String
    let sourceRangeLocation: Int?
    let sourceRangeLength: Int?

    init(
        pageIndex: Int,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        lineCount: Int,
        originalText: String,
        sourceRangeLocation: Int? = nil,
        sourceRangeLength: Int? = nil
    ) {
        self.pageIndex = pageIndex
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.lineCount = lineCount
        self.originalText = originalText
        self.sourceRangeLocation = sourceRangeLocation
        self.sourceRangeLength = sourceRangeLength
    }
}

struct PDFTextSelectionSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let pageIndex: Int
    let originalText: String
    let normalizedX: Double
    let normalizedY: Double
    let normalizedWidth: Double
    let normalizedHeight: Double
    let fontName: String?
    let fontSize: Double
    let color: PDFInkColor
    let lineCount: Int
    let hasMixedFonts: Bool
    let pageRotation: Int
    let flowRegions: [PDFTextFlowRegion]

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        originalText: String,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        fontName: String?,
        fontSize: Double,
        color: PDFInkColor,
        lineCount: Int,
        hasMixedFonts: Bool,
        pageRotation: Int,
        flowRegions: [PDFTextFlowRegion] = []
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.originalText = originalText
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.lineCount = lineCount
        self.hasMixedFonts = hasMixedFonts
        self.pageRotation = pageRotation
        self.flowRegions = flowRegions.isEmpty
            ? [
                PDFTextFlowRegion(
                    pageIndex: pageIndex,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY,
                    normalizedWidth: normalizedWidth,
                    normalizedHeight: normalizedHeight,
                    lineCount: lineCount,
                    originalText: originalText
                )
            ]
            : flowRegions
    }

    var pageIndices: [Int] {
        Array(Set(flowRegions.map(\.pageIndex))).sorted()
    }

    var isCrossPage: Bool {
        pageIndices.count > 1
    }
}

enum PDFTextReplacementStatus: String, Hashable, Sendable {
    case ready
    case blocked
    case unavailable
}

enum PDFTextReplacementFontStyle: String, CaseIterable, Identifiable, Sendable {
    case sans
    case serif
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }

    var pdfFontName: String {
        switch self {
        case .sans: return "Helvetica"
        case .serif: return "TimesNewRomanPSMT"
        case .monospaced: return "Menlo-Regular"
        }
    }
}

enum PDFTextReplacementAlignment: String, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

struct PDFTextReplacementAssessment: Hashable, Sendable {
    let status: PDFTextReplacementStatus
    let title: String
    let detail: String
    let resolvedFontName: String?
    let resolvedFontSize: Double
    let resolvedLineSpacing: Double
    let reflowedLineCount: Int
    let backgroundColor: PDFInkColor?
    let regionBackgroundColors: [PDFInkColor]
    let flowRegionTexts: [String]
    let fontStyle: PDFTextReplacementFontStyle
    let alignment: PDFTextReplacementAlignment

    var isReady: Bool {
        status == .ready
            && backgroundColor != nil
            && regionBackgroundColors.count == flowRegionTexts.count
            && !flowRegionTexts.isEmpty
    }
}

struct PDFImageObjectSnapshot: Identifiable, Hashable, Sendable {
    enum Storage: String, Hashable, Sendable {
        case jpeg
        case flate
        case flateWithSoftMask

        var detail: String {
            switch self {
            case .jpeg: return "JPEG object"
            case .flate: return "Lossless image object"
            case .flateWithSoftMask:
                return "Transparent image + alpha mask"
            }
        }
    }

    let pageIndex: Int
    let objectNumber: Int
    let generation: Int
    let resourceName: String
    let normalizedBounds: PDFNormalizedRect
    let pixelWidth: Int
    let pixelHeight: Int
    let jpegData: Data
    let sourceStreamData: Data
    let softMaskStreamData: Data?
    let softMaskObjectNumber: Int?
    let softMaskGeneration: Int?
    let storage: Storage
    let sourceDigest: String
    let usageCount: Int

    var id: String {
        "\(objectNumber)-\(generation)-\(pageIndex)-\(resourceName)"
    }

    var isSafelyReplaceable: Bool {
        usageCount > 0
            && pixelWidth > 0
            && pixelHeight > 0
            && !jpegData.isEmpty
            && !sourceStreamData.isEmpty
            && (
                storage != .flateWithSoftMask
                    || (
                        softMaskStreamData?.isEmpty == false
                            && softMaskObjectNumber != nil
                            && softMaskGeneration != nil
                    )
            )
    }

    var replacesMultipleUses: Bool {
        usageCount > 1
    }
}

enum PDFRedactionAppearance: String, Hashable, Sendable {
    case black
    case white
}

struct PDFRedactionMark: Hashable, Sendable {
    let pageIndex: Int
    let normalizedX: Double
    let normalizedY: Double
    let normalizedWidth: Double
    let normalizedHeight: Double
    let appearance: PDFRedactionAppearance

    init(
        pageIndex: Int,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        appearance: PDFRedactionAppearance = .black
    ) {
        self.pageIndex = pageIndex
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.appearance = appearance
    }
}

enum PDFRedactionMarkSanitizer {
    static func clean(
        _ marks: [PDFRedactionMark]
    ) -> [PDFRedactionMark] {
        var keys = Set<String>()
        return marks.compactMap(normalized)
            .filter { mark in
                let precision = 500.0
                let key = [
                    mark.pageIndex,
                    Int((mark.normalizedX * precision).rounded()),
                    Int((mark.normalizedY * precision).rounded()),
                    Int((mark.normalizedWidth * precision).rounded()),
                    Int((mark.normalizedHeight * precision).rounded())
                ].map(String.init).joined(separator: ":")
                    + ":\(mark.appearance.rawValue)"
                return keys.insert(key).inserted
            }
            .sorted {
                if $0.pageIndex != $1.pageIndex {
                    return $0.pageIndex < $1.pageIndex
                }
                if abs($0.normalizedY - $1.normalizedY) > 0.001 {
                    return $0.normalizedY < $1.normalizedY
                }
                return $0.normalizedX < $1.normalizedX
            }
    }

    private static func normalized(
        _ mark: PDFRedactionMark
    ) -> PDFRedactionMark? {
        guard mark.pageIndex >= 0,
              mark.normalizedX.isFinite,
              mark.normalizedY.isFinite,
              mark.normalizedWidth.isFinite,
              mark.normalizedHeight.isFinite
        else { return nil }
        let x = min(max(0, mark.normalizedX), 1)
        let y = min(max(0, mark.normalizedY), 1)
        let width = min(
            max(0, mark.normalizedWidth),
            max(0, 1 - x)
        )
        let height = min(
            max(0, mark.normalizedHeight),
            max(0, 1 - y)
        )
        guard width >= 0.001, height >= 0.001 else {
            return nil
        }
        return PDFRedactionMark(
            pageIndex: mark.pageIndex,
            normalizedX: x,
            normalizedY: y,
            normalizedWidth: width,
            normalizedHeight: height,
            appearance: mark.appearance
        )
    }
}

struct PDFPageCropInsets: Hashable, Sendable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double

    static let none = PDFPageCropInsets(
        top: 0,
        right: 0,
        bottom: 0,
        left: 0
    )

    init(
        top: Double,
        right: Double,
        bottom: Double,
        left: Double
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    var clamped: PDFPageCropInsets {
        PDFPageCropInsets(
            top: min(max(top, 0), 0.42),
            right: min(max(right, 0), 0.42),
            bottom: min(max(bottom, 0), 0.42),
            left: min(max(left, 0), 0.42)
        )
    }

    var retainedWidth: Double {
        max(0, 1 - left - right)
    }

    var retainedHeight: Double {
        max(0, 1 - top - bottom)
    }

    var retainedArea: Double {
        retainedWidth * retainedHeight
    }

    var isValid: Bool {
        retainedWidth >= 0.16
            && retainedHeight >= 0.16
            && retainedArea >= 0.08
    }

    var totalInset: Double {
        top + right + bottom + left
    }

    func addingSafetyPadding(
        _ padding: Double
    ) -> PDFPageCropInsets {
        let value = min(max(padding, 0), 0.12)
        return PDFPageCropInsets(
            top: max(0, top - value),
            right: max(0, right - value),
            bottom: max(0, bottom - value),
            left: max(0, left - value)
        )
    }

    func mappedToPDFBox(
        rotation: Int
    ) -> PDFPageCropInsets {
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            return PDFPageCropInsets(
                top: right,
                right: bottom,
                bottom: left,
                left: top
            )
        case 180:
            return PDFPageCropInsets(
                top: bottom,
                right: left,
                bottom: top,
                left: right
            )
        case 270:
            return PDFPageCropInsets(
                top: left,
                right: top,
                bottom: right,
                left: bottom
            )
        default:
            return self
        }
    }
}

enum PDFPagePaperClass: String, Hashable, Sendable {
    case a4
    case letter
    case legal
    case square
    case custom

    var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        case .legal: return "Legal"
        case .square: return "Square"
        case .custom: return "Custom"
        }
    }
}

enum PDFPageCropConfidence: String, Hashable, Sendable {
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

struct PDFPagePreparationItem: Identifiable, Hashable, Sendable {
    let pageIndex: Int
    let widthPoints: Double
    let heightPoints: Double
    let rotation: Int
    let paperClass: PDFPagePaperClass
    let detectedInsets: PDFPageCropInsets
    let confidence: PDFPageCropConfidence
    let inkCoverage: Double

    var id: Int { pageIndex }

    var isLandscape: Bool {
        widthPoints > heightPoints
    }

    var pointSizeLabel: String {
        "\(Int(widthPoints.rounded()))×\(Int(heightPoints.rounded())) pt"
    }

    var orientationTitle: String {
        isLandscape ? "Landscape" : "Portrait"
    }

    func proposedInsets(
        safetyPadding: Double
    ) -> PDFPageCropInsets {
        detectedInsets.addingSafetyPadding(safetyPadding)
    }

    func isSuggested(
        safetyPadding: Double
    ) -> Bool {
        let proposed = proposedInsets(
            safetyPadding: safetyPadding
        )
        return confidence != .low
            && proposed.isValid
            && proposed.totalInset >= 0.025
            && proposed.retainedArea <= 0.975
    }
}

struct PDFPagePreparationAssessment: Hashable, Sendable {
    let revisionID: UUID
    let pages: [PDFPagePreparationItem]
    let pageCount: Int

    init(
        revisionID: UUID,
        pages: [PDFPagePreparationItem],
        pageCount: Int? = nil
    ) {
        self.revisionID = revisionID
        self.pages = pages
        self.pageCount = max(pages.count, pageCount ?? pages.count)
    }

    var geometryVariantCount: Int {
        Set(
            pages.map {
                "\($0.paperClass.rawValue)-\($0.orientationTitle)"
            }
        ).count
    }

    func suggestedPageCount(
        safetyPadding: Double
    ) -> Int {
        pages.filter {
            $0.isSuggested(safetyPadding: safetyPadding)
        }.count
    }
}

struct PDFExternalPageSource:
    Identifiable,
    Hashable,
    Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let byteCount: Int64
    let assessment: PDFPagePreparationAssessment

    var pageCount: Int {
        assessment.pageCount
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

enum PDFPrintPaperTarget:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case original
    case a4
    case letter
    case legal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .a4: return "A4"
        case .letter: return "Letter"
        case .legal: return "Legal"
        }
    }

    var portraitSize: (width: Double, height: Double)? {
        switch self {
        case .original:
            return nil
        case .a4:
            return (595.28, 841.89)
        case .letter:
            return (612, 792)
        case .legal:
            return (612, 1_008)
        }
    }
}

enum PDFPrintOrientationPolicy:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case automatic
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

enum PDFPrintScaleMode:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case fit
    case fill
    case actual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill Page"
        case .actual: return "Actual Size"
        }
    }

    var symbol: String {
        switch self {
        case .fit: return "arrow.down.right.and.arrow.up.left"
        case .fill: return "arrow.up.left.and.arrow.down.right"
        case .actual: return "ruler"
        }
    }
}

enum PDFPrintProductionRisk:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case clear
    case caution
    case risk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return "Clear"
        case .caution: return "Caution"
        case .risk: return "Risk"
        }
    }
}

struct PDFPrintProductionEvidence:
    Identifiable,
    Hashable,
    Sendable {
    let pageIndex: Int
    let trimBoxInsetPoints: PDFPageCropInsets
    let bleedInsetPoints: PDFPageCropInsets
    let requiredBleedPoints: Double
    let requiredSafeAreaPoints: Double
    let nearestContentToTrimPoints: Double?
    let hasExplicitTrimBox: Bool
    let hasBleedAllowance: Bool
    let safeAreaRisk: PDFPrintProductionRisk
    let bleedRisk: PDFPrintProductionRisk

    var id: Int { pageIndex }

    var overallRisk: PDFPrintProductionRisk {
        if safeAreaRisk == .risk || bleedRisk == .risk {
            return .risk
        }
        if safeAreaRisk == .caution || bleedRisk == .caution {
            return .caution
        }
        return .clear
    }

    var trimSummary: String {
        guard hasExplicitTrimBox else { return "Crop box" }
        return AppLocalization.format(
            "T%.0f R%.0f B%.0f L%.0f pt",
            trimBoxInsetPoints.top,
            trimBoxInsetPoints.right,
            trimBoxInsetPoints.bottom,
            trimBoxInsetPoints.left
        )
    }

    var bleedSummary: String {
        hasBleedAllowance
            ? AppLocalization.format("%.0f pt+", requiredBleedPoints)
            : "Missing"
    }

    var safeAreaSummary: String {
        guard let nearestContentToTrimPoints else {
            return "No text/fields"
        }
        return AppLocalization.format(
            "%.0f pt",
            nearestContentToTrimPoints
        )
    }
}

struct PDFPrintPreparationOptions: Hashable, Sendable {
    var paperTarget: PDFPrintPaperTarget
    var orientation: PDFPrintOrientationPolicy
    var scaleMode: PDFPrintScaleMode
    var marginPoints: Double

    static let standard = PDFPrintPreparationOptions(
        paperTarget: .a4,
        orientation: .automatic,
        scaleMode: .fit,
        marginPoints: 24
    )

    var clampedMarginPoints: Double {
        min(max(marginPoints, 0), 72)
    }
}

struct PDFPrintPreparationPage:
    Identifiable,
    Hashable,
    Sendable {
    let pageIndex: Int
    let sourceWidth: Double
    let sourceHeight: Double
    let outputWidth: Double
    let outputHeight: Double
    let printableWidth: Double
    let printableHeight: Double
    let renderedWidth: Double
    let renderedHeight: Double
    let scale: Double
    let visibleFraction: Double
    let productionEvidence: PDFPrintProductionEvidence

    var id: Int { pageIndex }

    var hasClipping: Bool {
        visibleFraction < 0.997
    }

    var isScaled: Bool {
        abs(scale - 1) >= 0.01
    }

    var hasPadding: Bool {
        renderedWidth < printableWidth - 1
            || renderedHeight < printableHeight - 1
    }

    var sourceSizeLabel: String {
        "\(Int(sourceWidth.rounded()))×\(Int(sourceHeight.rounded())) pt"
    }

    var outputSizeLabel: String {
        "\(Int(outputWidth.rounded()))×\(Int(outputHeight.rounded())) pt"
    }

    var scalePercent: Int {
        Int((scale * 100).rounded())
    }

    var visiblePercent: Int {
        Int((visibleFraction * 100).rounded())
    }

    var outcomeTitle: String {
        if productionEvidence.overallRisk == .risk {
            return "Preflight risk"
        }
        if productionEvidence.overallRisk == .caution {
            return "Review"
        }
        if hasClipping {
            return "Clipped"
        }
        if isScaled {
            return scale < 1 ? "Reduced" : "Enlarged"
        }
        return "Actual size"
    }
}

struct PDFPrintPreparationAssessment: Hashable, Sendable {
    let revisionID: UUID
    let options: PDFPrintPreparationOptions
    let annotationCount: Int
    let pages: [PDFPrintPreparationPage]

    var clippedPageCount: Int {
        pages.filter(\.hasClipping).count
    }

    var scaledPageCount: Int {
        pages.filter(\.isScaled).count
    }

    var paddedPageCount: Int {
        pages.filter(\.hasPadding).count
    }

    var productionRiskPageCount: Int {
        pages.filter {
            $0.productionEvidence.overallRisk == .risk
        }.count
    }

    var productionCautionPageCount: Int {
        pages.filter {
            $0.productionEvidence.overallRisk == .caution
        }.count
    }

    var productionReviewPageCount: Int {
        productionRiskPageCount + productionCautionPageCount
    }

    var bleedRiskPageCount: Int {
        pages.filter {
            $0.productionEvidence.bleedRisk != .clear
        }.count
    }

    var safeAreaRiskPageCount: Int {
        pages.filter {
            $0.productionEvidence.safeAreaRisk != .clear
        }.count
    }

    var averageScalePercent: Int {
        guard !pages.isEmpty else { return 100 }
        return Int(
            (
                pages.reduce(0) { $0 + $1.scale }
                    / Double(pages.count)
                    * 100
            ).rounded()
        )
    }
}

enum PDFBookletBindingEdge:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left Binding"
        case .right: return "Right Binding"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "book.closed"
        case .right: return "book.closed.fill"
        }
    }
}

enum PDFBookletSheetSide:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case front
    case back

    var id: String { rawValue }
    var title: String {
        switch self {
        case .front: return "Front Side"
        case .back: return "Back Side"
        }
    }
}

struct PDFBookletOptions: Hashable, Sendable {
    var paperTarget: PDFPrintPaperTarget
    var bindingEdge: PDFBookletBindingEdge
    var outerMarginPoints: Double
    var gutterPoints: Double
    var showsFoldMarks: Bool
    var signatureSheetLimit: Int
    var creepCompensationPoints: Double

    var clampedOuterMarginPoints: Double {
        min(max(outerMarginPoints, 12), 72)
    }

    var clampedGutterPoints: Double {
        min(max(gutterPoints, 0), 48)
    }

    var normalizedSignatureSheetLimit: Int {
        signatureSheetLimit <= 0
            ? 0
            : min(max(signatureSheetLimit, 1), 32)
    }

    var clampedCreepCompensationPoints: Double {
        min(max(creepCompensationPoints, 0), 18)
    }
}

struct PDFBookletSlot: Hashable, Sendable {
    let sourcePageIndex: Int?
    let scale: Double
    let visibleFraction: Double
    let creepOffsetPoints: Double

    var isBlank: Bool {
        sourcePageIndex == nil
    }

    var pageNumber: Int? {
        sourcePageIndex.map { $0 + 1 }
    }

    var scalePercent: Int {
        Int((scale * 100).rounded())
    }
}

struct PDFBookletSpread:
    Identifiable,
    Hashable,
    Sendable {
    let outputPageIndex: Int
    let signatureNumber: Int
    let signatureSheetCount: Int
    let sheetNumber: Int
    let side: PDFBookletSheetSide
    let left: PDFBookletSlot
    let right: PDFBookletSlot
    let sheetWidth: Double
    let sheetHeight: Double

    var id: Int { outputPageIndex }

    var hasBlankSlot: Bool {
        left.isBlank || right.isBlank
    }

    var pageOrderLabel: String {
        "\(slotLabel(left)) · \(slotLabel(right))"
    }

    private func slotLabel(_ slot: PDFBookletSlot) -> String {
        slot.pageNumber.map(String.init) ?? "Blank"
    }
}

struct PDFBookletAssessment: Hashable, Sendable {
    let revisionID: UUID
    let options: PDFBookletOptions
    let sourcePageCount: Int
    let paddedPageCount: Int
    let annotationCount: Int
    let spreads: [PDFBookletSpread]

    var signatureCount: Int {
        Set(spreads.map(\.signatureNumber)).count
    }

    var insertedBlankCount: Int {
        max(0, paddedPageCount - sourcePageCount)
    }

    var sheetCount: Int {
        paddedPageCount / 4
    }

    var outputPageCount: Int {
        spreads.count
    }

    var maximumCreepOffsetPoints: Int {
        let offsets = spreads.flatMap {
            [
                abs($0.left.creepOffsetPoints),
                abs($0.right.creepOffsetPoints)
            ]
        }
        return Int((offsets.max() ?? 0).rounded())
    }

    var largestSignatureSheetCount: Int {
        spreads.map(\.signatureSheetCount).max() ?? 0
    }

    var averageScalePercent: Int {
        let slots = spreads.flatMap { [$0.left, $0.right] }
            .filter { !$0.isBlank }
        guard !slots.isEmpty else { return 100 }
        return Int(
            (
                slots.reduce(0) { $0 + $1.scale }
                    / Double(slots.count)
                    * 100
            ).rounded()
        )
    }
}

struct PDFInkPoint: Hashable, Sendable {
    let x: Double
    let y: Double
}

struct PDFInkColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

struct PDFInkStroke: Hashable, Sendable {
    let points: [PDFInkPoint]
    let color: PDFInkColor?
    let normalizedLineWidth: Double?

    init(
        points: [PDFInkPoint],
        color: PDFInkColor? = nil,
        normalizedLineWidth: Double? = nil
    ) {
        self.points = points
        self.color = color
        self.normalizedLineWidth = normalizedLineWidth
    }
}

struct PDFNormalizedRect: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        let safeWidth = min(max(width, 0.08), 1)
        let safeHeight = min(max(height, 0.04), 1)
        self.width = safeWidth
        self.height = safeHeight
        self.x = min(max(x, 0), 1 - safeWidth)
        self.y = min(max(y, 0), 1 - safeHeight)
    }
}

enum PDFContentOverlay: Sendable {
    case text(
        pageIndex: Int,
        bounds: PDFNormalizedRect,
        text: String,
        fontSize: Double,
        color: PDFInkColor
    )
    case link(
        pageIndex: Int,
        bounds: PDFNormalizedRect,
        title: String,
        url: URL
    )
    case image(
        pageIndex: Int,
        bounds: PDFNormalizedRect,
        data: Data
    )

    var pageIndex: Int {
        switch self {
        case .text(let pageIndex, _, _, _, _),
             .link(let pageIndex, _, _, _),
             .image(let pageIndex, _, _):
            return pageIndex
        }
    }
}

enum PDFLinkTarget: Hashable, Sendable {
    case web(URL)
    case page(Int)
    case unsupported(String)

    var isEditable: Bool {
        switch self {
        case .web, .page: return true
        case .unsupported: return false
        }
    }

    var title: String {
        switch self {
        case .web(let url):
            return url.absoluteString
        case .page(let pageIndex):
            return "Page \(pageIndex + 1)"
        case .unsupported(let detail):
            return detail
        }
    }
}

struct PDFLinkAnnotationSnapshot: Identifiable, Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
    let normalizedBounds: PDFNormalizedRect
    let title: String
    let target: PDFLinkTarget

    var id: String {
        "\(pageIndex)-\(annotationIndex)"
    }
}

struct PDFLinkEditPayload: Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
    let normalizedBounds: PDFNormalizedRect
    let title: String
    let target: PDFLinkTarget
}

enum PDFLinkMutation: Hashable, Sendable {
    case update(PDFLinkEditPayload)
    case remove(pageIndex: Int, annotationIndex: Int)
}

enum PDFInkPlacement: Sendable, Equatable {
    case page
    case signature
}

enum PDFSignaturePosition: String, CaseIterable, Identifiable, Sendable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }
}

enum PDFSignatureSize: String, CaseIterable, Identifiable, Sendable {
    case compact
    case regular
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }

    var pageWidthFraction: Double {
        switch self {
        case .compact: return 0.28
        case .regular: return 0.40
        case .large: return 0.54
        }
    }
}

struct PDFInkPayload: Sendable {
    static let maximumStrokeCount = 400
    static let maximumPointsPerStroke = 2_000
    static let maximumTotalPointCount = 20_000

    let pageIndex: Int
    let strokes: [PDFInkStroke]
    let placement: PDFInkPlacement
    let signaturePosition: PDFSignaturePosition
    let signatureSize: PDFSignatureSize
    let normalizedBounds: PDFNormalizedRect?

    init(
        pageIndex: Int,
        strokes: [PDFInkStroke],
        placement: PDFInkPlacement,
        signaturePosition: PDFSignaturePosition = .right,
        signatureSize: PDFSignatureSize = .regular,
        normalizedBounds: PDFNormalizedRect? = nil
    ) {
        self.pageIndex = pageIndex
        self.strokes = strokes
        self.placement = placement
        self.signaturePosition = signaturePosition
        self.signatureSize = signatureSize
        self.normalizedBounds = normalizedBounds
    }
}

enum PDFFormFieldKind: String, CaseIterable, Identifiable, Sendable {
    case text
    case checkbox
    case radio
    case choice
    case signature
    case button
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .checkbox: return "Checkbox"
        case .radio: return "Radio"
        case .choice: return "Choice"
        case .signature: return "Signature"
        case .button: return "Button"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.cursor"
        case .checkbox: return "checkmark.square"
        case .radio: return "circle.circle"
        case .choice: return "chevron.up.chevron.down"
        case .signature: return "signature"
        case .button: return "rectangle.and.hand.point.up.left"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    var canCreate: Bool {
        switch self {
        case .text, .checkbox, .radio, .choice, .signature:
            return true
        case .button, .unknown:
            return false
        }
    }
}

enum PDFFormCompatibility: String, Sendable {
    case ready
    case limited
    case unsupported

    var title: String {
        switch self {
        case .ready: return "AcroForm ready"
        case .limited: return "Review compatibility"
        case .unsupported: return "Viewing only"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.seal"
        case .limited: return "exclamationmark.triangle"
        case .unsupported: return "eye"
        }
    }
}

enum PDFFormCalculationOperation:
    String,
    Hashable,
    Sendable {
    case sum
    case product
    case average
    case minimum
    case maximum

    var title: String {
        switch self {
        case .sum: return "Sum"
        case .product: return "Product"
        case .average: return "Average"
        case .minimum: return "Minimum"
        case .maximum: return "Maximum"
        }
    }
}

struct PDFFormCalculationRule: Hashable, Sendable {
    let operation: PDFFormCalculationOperation
    let sourceFieldNames: [String]
}

enum PDFFormFormatKind: String, Hashable, Sendable {
    case number
    case percent
    case date
    case time

    var title: String {
        switch self {
        case .number: return "Number"
        case .percent: return "Percent"
        case .date: return "Date"
        case .time: return "Time"
        }
    }
}

struct PDFFormFormatRule: Hashable, Sendable {
    let kind: PDFFormFormatKind
    let decimalPlaces: Int
    let separatorStyle: Int
    let negativeStyle: Int
    let currencySymbol: String
    let currencyPrecedesValue: Bool
    let pattern: String?
}

struct PDFFormRangeValidationRule: Hashable, Sendable {
    let minimum: Double?
    let maximum: Double?
}

struct PDFFormAutomationFieldSnapshot:
    Identifiable,
    Hashable,
    Sendable {
    let fieldID: String
    let fieldName: String
    let calculation: PDFFormCalculationRule?
    let format: PDFFormFormatRule?
    let rangeValidation: PDFFormRangeValidationRule?
    let expectedValue: String?
    let formattedPreview: String?
    let needsUpdate: Bool
    let validationIssue: String?
    let unsupportedActionCount: Int

    var id: String { fieldID }

    var hasSupportedLogic: Bool {
        calculation != nil
            || format != nil
            || rangeValidation != nil
    }
}

struct PDFFormFieldSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let pageIndex: Int
    let annotationIndex: Int
    let name: String
    let kind: PDFFormFieldKind
    let value: String?
    let normalizedBounds: PDFNormalizedRect
    let isRequired: Bool
    let isReadOnly: Bool
    let isMultiline: Bool
    let maximumLength: Int?
    let optionCount: Int
    let hasAppearanceStream: Bool
    let issue: String?

    var type: String { kind.title }

    var isComplete: Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.lowercased() != "off"
    }
}

struct PDFFormInspectionReport: Sendable {
    let fields: [PDFFormFieldSnapshot]
    let automationFields: [PDFFormAutomationFieldSnapshot]
    let compatibility: PDFFormCompatibility
    let issues: [String]
    let hasXFA: Bool
    let hasJavaScript: Bool
    let needsAppearances: Bool
    let unsupportedJavaScriptCount: Int

    var incompleteRequiredFields: [PDFFormFieldSnapshot] {
        fields.filter { $0.isRequired && !$0.isComplete }
    }

    var incompleteOptionalFields: [PDFFormFieldSnapshot] {
        fields.filter { !$0.isRequired && !$0.isComplete }
    }

    var isReadyForVerifiedOutput: Bool {
        !fields.isEmpty
            && compatibility != .unsupported
            && incompleteRequiredFields.isEmpty
            && fieldsNeedingAutomationUpdate.isEmpty
            && invalidAutomationFields.isEmpty
            && unsupportedJavaScriptCount == 0
    }

    var requiresCompatibleReader: Bool {
        hasXFA
            || unsupportedJavaScriptCount > 0
            || incompleteRequiredFields.contains {
                $0.isReadOnly || $0.issue != nil
            }
    }

    var editableFieldCount: Int {
        fields.filter { !$0.isReadOnly && $0.issue == nil }.count
    }

    var supportedAutomationFields:
        [PDFFormAutomationFieldSnapshot] {
        automationFields.filter(\.hasSupportedLogic)
    }

    var calculatedFields: [PDFFormAutomationFieldSnapshot] {
        automationFields.filter { $0.calculation != nil }
    }

    var fieldsNeedingAutomationUpdate:
        [PDFFormAutomationFieldSnapshot] {
        automationFields.filter {
            $0.hasSupportedLogic
                && $0.needsUpdate
                && $0.validationIssue == nil
        }
    }

    var invalidAutomationFields:
        [PDFFormAutomationFieldSnapshot] {
        automationFields.filter {
            $0.validationIssue != nil
        }
    }

    func automation(
        for field: PDFFormFieldSnapshot
    ) -> PDFFormAutomationFieldSnapshot? {
        automationFields.first {
            $0.fieldID == field.id
        }
    }

    static let empty = Self(
        fields: [],
        automationFields: [],
        compatibility: .ready,
        issues: [],
        hasXFA: false,
        hasJavaScript: false,
        needsAppearances: false,
        unsupportedJavaScriptCount: 0
    )
}

struct PDFFormFieldPayload: Sendable {
    let pageIndex: Int
    let kind: PDFFormFieldKind
    let name: String
    let normalizedBounds: PDFNormalizedRect
    let isRequired: Bool
    let isMultiline: Bool
    let maximumLength: Int?
    let options: [String]
    let isListChoice: Bool

    init(
        pageIndex: Int,
        kind: PDFFormFieldKind,
        name: String,
        normalizedBounds: PDFNormalizedRect,
        isRequired: Bool,
        isMultiline: Bool,
        maximumLength: Int?,
        options: [String] = [],
        isListChoice: Bool = false
    ) {
        self.pageIndex = pageIndex
        self.kind = kind
        self.name = name
        self.normalizedBounds = normalizedBounds
        self.isRequired = isRequired
        self.isMultiline = isMultiline
        self.maximumLength = maximumLength
        self.options = options
        self.isListChoice = isListChoice
    }
}

struct PDFAnnotationSnapshot: Identifiable, Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
    let type: String
    let contents: String?
    let generatedKind: PDFGeneratedAnnotationKind?
    let color: PDFInkColor
    let lineWidth: Double?
    let hasAppearanceStream: Bool
    let canEditContents: Bool
    let canEditStyle: Bool
    let canRemove: Bool
    let mutationIdentity: String?

    init(
        pageIndex: Int,
        annotationIndex: Int,
        type: String,
        contents: String?,
        generatedKind: PDFGeneratedAnnotationKind?,
        color: PDFInkColor,
        lineWidth: Double?,
        hasAppearanceStream: Bool,
        canEditContents: Bool,
        canEditStyle: Bool,
        canRemove: Bool,
        mutationIdentity: String? = nil
    ) {
        self.pageIndex = pageIndex
        self.annotationIndex = annotationIndex
        self.type = type
        self.contents = contents
        self.generatedKind = generatedKind
        self.color = color
        self.lineWidth = lineWidth
        self.hasAppearanceStream = hasAppearanceStream
        self.canEditContents = canEditContents
        self.canEditStyle = canEditStyle
        self.canRemove = canRemove
        self.mutationIdentity = mutationIdentity
    }

    var id: String {
        "\(pageIndex)-\(annotationIndex)-\(type)"
    }

    var canEdit: Bool {
        canEditContents || canEditStyle
    }
}

struct PDFAnnotationInventory: Sendable {
    let annotations: [PDFAnnotationSnapshot]
    let isTruncated: Bool
    let displayLimit: Int

    static let empty = Self(
        annotations: [],
        isTruncated: false,
        displayLimit: 10_000
    )
}

struct PDFAnnotationRemovalTarget: Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
    let expectedType: String
    let expectedContents: String?
    let expectedGeneratedKind: PDFGeneratedAnnotationKind?
    let expectedMutationIdentity: String?

    init(annotation: PDFAnnotationSnapshot) {
        pageIndex = annotation.pageIndex
        annotationIndex = annotation.annotationIndex
        expectedType = annotation.type
        expectedContents = annotation.contents
        expectedGeneratedKind = annotation.generatedKind
        expectedMutationIdentity = annotation.mutationIdentity
    }
}

enum PDFEmbeddedAttachmentOrigin: String, Hashable, Sendable {
    case document
    case pageAnnotation

    var title: String {
        switch self {
        case .document: return "Document attachment"
        case .pageAnnotation: return "Page attachment"
        }
    }
}

struct PDFEmbeddedAttachmentSnapshot:
    Identifiable,
    Hashable,
    Sendable {
    let id: String
    let fileName: String
    let contentType: String?
    let byteCount: Int
    let checksum: String
    let description: String?
    let pageIndex: Int?
    let origin: PDFEmbeddedAttachmentOrigin
    let isExtractable: Bool
    let limitation: String?

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(byteCount),
            countStyle: .file
        )
    }
}

struct PDFPageLabelSnapshot: Identifiable, Hashable, Sendable {
    let pageIndex: Int
    let label: String
    let isExplicit: Bool

    var id: Int { pageIndex }
}

enum PDFPageLabelStyle:
    String,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable {
    case decimal
    case uppercaseRoman
    case lowercaseRoman
    case uppercaseLetters
    case lowercaseLetters
    case prefixOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decimal: return "1, 2, 3"
        case .uppercaseRoman: return "I, II, III"
        case .lowercaseRoman: return "i, ii, iii"
        case .uppercaseLetters: return "A, B, C"
        case .lowercaseLetters: return "a, b, c"
        case .prefixOnly: return "Prefix only"
        }
    }

    var pdfName: String? {
        switch self {
        case .decimal: return "D"
        case .uppercaseRoman: return "R"
        case .lowercaseRoman: return "r"
        case .uppercaseLetters: return "A"
        case .lowercaseLetters: return "a"
        case .prefixOnly: return nil
        }
    }

    func formattedNumber(_ value: Int) -> String {
        let number = max(1, value)
        switch self {
        case .decimal:
            return String(number)
        case .uppercaseRoman:
            return Self.roman(number).uppercased()
        case .lowercaseRoman:
            return Self.roman(number).lowercased()
        case .uppercaseLetters:
            return Self.letters(number).uppercased()
        case .lowercaseLetters:
            return Self.letters(number).lowercased()
        case .prefixOnly:
            return ""
        }
    }

    private static func roman(_ value: Int) -> String {
        let values = [
            (1_000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var remaining = min(max(value, 1), 3_999)
        var result = ""
        for (number, symbol) in values {
            while remaining >= number {
                result += symbol
                remaining -= number
            }
        }
        return result
    }

    private static func letters(_ value: Int) -> String {
        var remaining = max(1, value)
        var result = ""
        while remaining > 0 {
            remaining -= 1
            let scalar = UnicodeScalar(65 + remaining % 26)!
            result.insert(Character(String(scalar)), at: result.startIndex)
            remaining /= 26
        }
        return result
    }
}

struct PDFPageLabelRule: Identifiable, Hashable, Sendable {
    let id: UUID
    var startPageIndex: Int
    var style: PDFPageLabelStyle
    var prefix: String
    var startNumber: Int

    init(
        id: UUID = UUID(),
        startPageIndex: Int,
        style: PDFPageLabelStyle,
        prefix: String = "",
        startNumber: Int = 1
    ) {
        self.id = id
        self.startPageIndex = startPageIndex
        self.style = style
        self.prefix = prefix
        self.startNumber = startNumber
    }

    func label(for pageIndex: Int) -> String {
        let offset = max(0, pageIndex - startPageIndex)
        return prefix + style.formattedNumber(startNumber + offset)
    }
}

struct PDFAnnotationEditPayload: Hashable, Sendable {
    let pageIndex: Int
    let annotationIndex: Int
    let expectedType: String
    let expectedMutationIdentity: String?
    let contents: String
    let color: PDFInkColor
    let lineWidth: Double?

    init(
        pageIndex: Int,
        annotationIndex: Int,
        expectedType: String,
        expectedMutationIdentity: String? = nil,
        contents: String,
        color: PDFInkColor,
        lineWidth: Double?
    ) {
        self.pageIndex = pageIndex
        self.annotationIndex = annotationIndex
        self.expectedType = expectedType
        self.expectedMutationIdentity = expectedMutationIdentity
        self.contents = contents
        self.color = color
        self.lineWidth = lineWidth
    }
}

enum DocumentWorkflowStatus:
    String,
    Codable,
    CaseIterable,
    Identifiable,
    Sendable {
    case inbox
    case reviewing
    case ready
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .reviewing: return "Reviewing"
        case .ready: return "Ready"
        case .archived: return "Archived"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .reviewing: return "eye"
        case .ready: return "checkmark.circle"
        case .archived: return "archivebox"
        }
    }
}

enum DocumentTaskStage: String, Codable, Hashable, Sendable {
    case fillForm
    case sign
    case verify

    var title: String {
        switch self {
        case .fillForm: return "Continue filling"
        case .sign: return "Continue signing"
        case .verify: return "Continue verification"
        }
    }

    var detail: String {
        switch self {
        case .fillForm:
            return "Return to the next required field"
        case .sign:
            return "Return to the saved signature position"
        case .verify:
            return "Check the final copy before sharing"
        }
    }

    var symbol: String {
        switch self {
        case .fillForm: return "pencil.and.list.clipboard"
        case .sign: return "signature"
        case .verify: return "checkmark.shield"
        }
    }

    var action: DocumentAction {
        switch self {
        case .fillForm: return .reviewForm
        case .sign: return .sign
        case .verify: return .safeShare
        }
    }

    var quickTask: PDFQuickTask {
        switch self {
        case .fillForm: return .fillForms
        case .sign: return .signPDF
        case .verify: return .safeShare
        }
    }
}

struct DocumentTaskCheckpoint: Codable, Hashable, Sendable {
    let stage: DocumentTaskStage
    let pageIndex: Int?
    let fieldName: String?
    let normalizedBounds: PDFNormalizedRect?
    let contentRevisionID: UUID?
    let updatedAt: Date

    init(
        stage: DocumentTaskStage,
        pageIndex: Int? = nil,
        fieldName: String? = nil,
        normalizedBounds: PDFNormalizedRect? = nil,
        contentRevisionID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.stage = stage
        self.pageIndex = pageIndex
        let normalizedName = fieldName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.fieldName = if let normalizedName,
                            !normalizedName.isEmpty {
            String(normalizedName.prefix(80))
        } else {
            nil
        }
        self.normalizedBounds = normalizedBounds
        self.contentRevisionID = contentRevisionID
        self.updatedAt = updatedAt
    }

    var resumeReason: String {
        if let fieldName {
            if let pageIndex {
                return AppLocalization.format(
                    "%@ · page %lld",
                    fieldName,
                    pageIndex + 1
                )
            }
            return fieldName
        }
        if let pageIndex {
            return "\(stage.detail) on page \(pageIndex + 1)"
        }
        return stage.detail
    }

    func bounded(toPageCount pageCount: Int) -> Self {
        guard let pageIndex else { return self }
        return DocumentTaskCheckpoint(
            stage: stage,
            pageIndex: min(max(pageIndex, 0), max(0, pageCount - 1)),
            fieldName: fieldName,
            normalizedBounds: normalizedBounds,
            contentRevisionID: contentRevisionID,
            updatedAt: updatedAt
        )
    }

    func rebased(to contentRevisionID: UUID) -> Self {
        guard self.contentRevisionID != contentRevisionID else {
            return self
        }
        return DocumentTaskCheckpoint(
            stage: stage,
            pageIndex: pageIndex,
            fieldName: fieldName,
            normalizedBounds: normalizedBounds,
            contentRevisionID: contentRevisionID,
            updatedAt: updatedAt
        )
    }

    func validated(
        for contentRevisionID: UUID,
        pageCount: Int
    ) -> Self? {
        if let boundRevisionID = self.contentRevisionID,
           boundRevisionID != contentRevisionID {
            return nil
        }
        return rebased(to: contentRevisionID)
            .bounded(toPageCount: pageCount)
    }

    func hasSameResumeTarget(as other: Self) -> Bool {
        stage == other.stage
            && pageIndex == other.pageIndex
            && fieldName == other.fieldName
            && normalizedBounds == other.normalizedBounds
            && contentRevisionID == other.contentRevisionID
    }
}

enum DocumentCategory: String, Codable, CaseIterable, Identifiable {
    case general
    case contract
    case invoice
    case receipt
    case report
    case letter
    case form

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Document"
        case .contract: return "Contract"
        case .invoice: return "Invoice"
        case .receipt: return "Receipt"
        case .report: return "Report"
        case .letter: return "Letter"
        case .form: return "Form"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "doc.text"
        case .contract: return "signature"
        case .invoice: return "doc.text.below.ecg"
        case .receipt: return "receipt"
        case .report: return "chart.bar.doc.horizontal"
        case .letter: return "envelope.open"
        case .form: return "list.bullet.clipboard"
        }
    }
}

enum IndexedTextSource: String, Codable, Sendable {
    case native
    case vision
    case searchableCopy

    var title: String {
        switch self {
        case .native: return "Native PDF text"
        case .vision: return "On-device text recognition"
        case .searchableCopy: return "Searchable PDF text"
        }
    }
}

enum DocumentUnderstandingConfidence: String, Codable, Hashable {
    case high
    case medium
    case low

    var title: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Likely"
        case .low: return "Possible"
        }
    }

    var symbol: String {
        switch self {
        case .high: return "checkmark.circle"
        case .medium: return "circle.lefthalf.filled"
        case .low: return "questionmark.circle"
        }
    }
}

struct DetectedEntity: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case date
        case amount
        case email
        case phone
        case link
        case reference
        case identifier

        var title: String {
            switch self {
            case .date: return "Date"
            case .amount: return "Amount"
            case .email: return "Email"
            case .phone: return "Phone"
            case .link: return "Link"
            case .reference: return "Reference"
            case .identifier: return "Private ID"
            }
        }

        var symbol: String {
            switch self {
            case .date: return "calendar"
            case .amount: return "banknote"
            case .email: return "envelope"
            case .phone: return "phone"
            case .link: return "link"
            case .reference: return "number"
            case .identifier: return "person.text.rectangle"
            }
        }

        var isSensitive: Bool {
            switch self {
            case .email, .phone, .identifier: return true
            case .date, .amount, .link, .reference: return false
            }
        }
    }

    let id: UUID
    let kind: Kind
    let value: String
    let pageIndex: Int?

    init(
        id: UUID = UUID(),
        kind: Kind,
        value: String,
        pageIndex: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.pageIndex = pageIndex
    }
}

struct SuggestedStep: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case recognize
        case reviewDate
        case reviewAmount
        case completeForm
        case reviewSignature
        case organize
        case share

        var symbol: String {
            switch self {
            case .recognize: return "text.viewfinder"
            case .reviewDate: return "calendar.badge.clock"
            case .reviewAmount: return "banknote"
            case .completeForm: return "pencil.and.list.clipboard"
            case .reviewSignature: return "signature"
            case .organize: return "square.grid.2x2"
            case .share: return "square.and.arrow.up"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let evidence: String
    let evidencePageIndex: Int?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        evidence: String,
        evidencePageIndex: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.evidence = evidence
        self.evidencePageIndex = evidencePageIndex
    }
}

struct DocumentBrief: Codable, Hashable {
    var category: DocumentCategory
    var summary: String
    var entities: [DetectedEntity]
    var suggestedSteps: [SuggestedStep]
    var indexedAt: Date
    var textSource: IndexedTextSource?
    var indexedCharacterCount: Int
    var confidence: DocumentUnderstandingConfidence? = nil

    var hasUsefulContent: Bool {
        indexedCharacterCount > 0 || !entities.isEmpty || !suggestedSteps.isEmpty
    }

    var resolvedConfidence: DocumentUnderstandingConfidence {
        confidence ?? .low
    }

    var sensitiveEntityCount: Int {
        entities.filter(\.kind.isSensitive).count
    }
}

struct DocumentProfile: Codable, Hashable {
    var pageCount: Int
    var sampledPageCount: Int
    var textCharacterCount: Int
    var imageDominantPageCount: Int
    var formFieldCount: Int
    var byteCount: Int64
    var isEncrypted: Bool
    var isLocked: Bool
    var allowsCopying: Bool
    var allowsCommenting: Bool
    var kind: DocumentKind
    var recommendedActions: [DocumentAction]

    var textCoverage: Double {
        guard sampledPageCount > 0 else { return 0 }
        return 1 - (Double(imageDominantPageCount) / Double(sampledPageCount))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var summary: String {
        if isLocked {
            return "Unlock this PDF before PaperPath can inspect its contents."
                .localizedUI
        }
        switch kind {
        case .scan:
            return "Mostly image-based. Local text recognition is the useful next step."
                .localizedUI
        case .mixed:
            return "Contains both text and image-based pages.".localizedUI
        case .form:
            return AppLocalization.format(
                "%lld form field%@ detected.",
                formFieldCount,
                formFieldCount == 1 ? "" : "s"
            )
        case .protected:
            return "This document limits one or more editing permissions."
                .localizedUI
        case .text:
            return "Text is available. The document is ready to review or share."
                .localizedUI
        }
    }

    static let empty = DocumentProfile(
        pageCount: 0,
        sampledPageCount: 0,
        textCharacterCount: 0,
        imageDominantPageCount: 0,
        formFieldCount: 0,
        byteCount: 0,
        isEncrypted: false,
        isLocked: false,
        allowsCopying: true,
        allowsCommenting: true,
        kind: .text,
        recommendedActions: [.inspect, .shareCopy]
    )
}

enum PDFDeliveryOperation: String, Codable, Hashable, Sendable {
    case compressed
    case redacted
    case protected
    case unlocked
    case flattened
    case safeShare
    case edited
    case textReplaced
    case printPrepared
    case bookletPrepared

    var title: String {
        switch self {
        case .compressed: return "Compressed copy"
        case .redacted: return "Redacted copy"
        case .protected: return "Protected copy"
        case .unlocked: return "Editable copy"
        case .flattened: return "Flattened copy"
        case .safeShare: return "Verified copy"
        case .edited: return "Edited copy"
        case .textReplaced: return "Text replacement copy"
        case .printPrepared: return "Print-ready copy"
        case .bookletPrepared: return "Booklet copy"
        }
    }

    var symbol: String {
        switch self {
        case .compressed:
            return "arrow.down.right.and.arrow.up.left"
        case .redacted:
            return "eye.slash"
        case .protected:
            return "lock.doc"
        case .unlocked:
            return "lock.open"
        case .flattened:
            return "square.stack.3d.down.right"
        case .safeShare:
            return "checkmark.shield"
        case .edited:
            return "text.badge.plus"
        case .textReplaced:
            return "character.cursor.ibeam"
        case .printPrepared:
            return "printer.fill"
        case .bookletPrepared:
            return "book.pages.fill"
        }
    }
}

struct PDFOperationProgress: Equatable, Sendable {
    private static let maximumDisplayByteRate =
        Double(Int64.max / 2)
    private static let maximumEstimatedRemainingSeconds:
        TimeInterval = 365 * 24 * 60 * 60

    let label: String
    let fractionCompleted: Double
    let byteStage: PDFByteProgressStage?
    let processedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let estimatedRemainingSeconds: TimeInterval?
    let throughputHistory: [Double]
    let lastByteUpdateAt: Date?

    init(
        label: String,
        fractionCompleted: Double,
        byteStage: PDFByteProgressStage? = nil,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        estimatedRemainingSeconds: TimeInterval? = nil,
        throughputHistory: [Double] = [],
        lastByteUpdateAt: Date? = nil
    ) {
        self.label = label
        self.fractionCompleted = fractionCompleted.isFinite
            ? min(1, max(0, fractionCompleted))
            : 0
        self.byteStage = byteStage
        let boundedTotalBytes = max(0, totalBytes)
        self.totalBytes = boundedTotalBytes
        self.processedBytes = boundedTotalBytes > 0
            ? min(max(0, processedBytes), boundedTotalBytes)
            : max(0, processedBytes)
        self.bytesPerSecond = bytesPerSecond.isFinite
            ? min(
                Self.maximumDisplayByteRate,
                max(0, bytesPerSecond)
            )
            : 0
        self.estimatedRemainingSeconds =
            estimatedRemainingSeconds.flatMap {
                guard $0.isFinite, $0 >= 0 else { return nil }
                return min(
                    Self.maximumEstimatedRemainingSeconds,
                    $0
                )
            }
        self.throughputHistory = Array(
            throughputHistory.lazy
                .filter { $0.isFinite && $0 >= 0 }
                .map { min(Self.maximumDisplayByteRate, $0) }
                .suffix(24)
        )
        self.lastByteUpdateAt =
            lastByteUpdateAt?.timeIntervalSince1970.isFinite == true
                ? lastByteUpdateAt
                : nil
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    var byteSummary: String? {
        guard processedBytes > 0 || totalBytes > 0 else { return nil }
        let processed = ByteCountFormatter.string(
            fromByteCount: processedBytes,
            countStyle: .file
        )
        guard totalBytes > 0 else { return processed }
        let total = ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
        return "\(processed) / \(total)"
    }

    var throughputSummary: String? {
        guard bytesPerSecond > 0 else { return nil }
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(bytesPerSecond),
            countStyle: .file
        )
        return "\(formatted)/s"
    }

    var remainingSummary: String? {
        guard let estimatedRemainingSeconds,
              estimatedRemainingSeconds.isFinite,
              estimatedRemainingSeconds >= 0
        else { return nil }
        let seconds = Int(ceil(estimatedRemainingSeconds))
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    func isStalled(at date: Date) -> Bool {
        guard processedBytes < totalBytes,
              let lastByteUpdateAt
        else { return false }
        return date.timeIntervalSince(lastByteUpdateAt) >= 2
    }
}

enum PDFComparisonProgressStage: String, Hashable, Sendable {
    case opening
    case readingSource
    case readingRevised
    case matchingPages
    case inspectingChanges
    case complete

    var title: String {
        switch self {
        case .opening: return "Opening PDFs"
        case .readingSource: return "Reading base PDF"
        case .readingRevised: return "Reading revised PDF"
        case .matchingPages: return "Matching pages"
        case .inspectingChanges: return "Reviewing differences"
        case .complete: return "Comparison ready"
        }
    }

    var symbol: String {
        switch self {
        case .opening: return "doc.on.doc"
        case .readingSource: return "doc"
        case .readingRevised: return "doc.fill"
        case .matchingPages: return "arrow.left.arrow.right"
        case .inspectingChanges: return "viewfinder"
        case .complete: return "checkmark.circle.fill"
        }
    }
}

struct PDFComparisonProgress: Hashable, Sendable {
    let stage: PDFComparisonProgressStage
    let completedPageCount: Int
    let totalPageCount: Int
    let fractionCompleted: Double

    init(
        stage: PDFComparisonProgressStage,
        completedPageCount: Int = 0,
        totalPageCount: Int = 0,
        fractionCompleted: Double
    ) {
        self.stage = stage
        self.totalPageCount = max(0, totalPageCount)
        self.completedPageCount = min(
            max(0, completedPageCount),
            max(0, totalPageCount)
        )
        self.fractionCompleted = fractionCompleted.isFinite
            ? min(max(0, fractionCompleted), 1)
            : 0
    }

    var percentCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    var pageSummary: String? {
        guard totalPageCount > 0 else { return nil }
        return AppLocalization.format(
            "%lld of %lld pages",
            completedPageCount,
            totalPageCount
        )
    }

    static let starting = PDFComparisonProgress(
        stage: .opening,
        fractionCompleted: 0
    )
}

typealias PDFComparisonProgressHandler =
    @Sendable (PDFComparisonProgress) -> Void

enum PDFDeliveryCheckStatus: String, Codable, Hashable, Sendable {
    case passed
    case warning
    case failed
    case notApplicable
}

enum PDFDeliveryPreflightStatus: String, Codable, Hashable, Sendable {
    case ready
    case review
    case blocked

    var title: String {
        switch self {
        case .ready: return "Ready to verify"
        case .review: return "Review before sending"
        case .blocked: return "Cannot create a verified copy"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.shield"
        case .review: return "exclamationmark.triangle"
        case .blocked: return "xmark.octagon"
        }
    }
}

enum PDFDeliveryPreflightItemStatus: String, Codable, Hashable, Sendable {
    case passed
    case willFix
    case review
    case blocked
}

enum PDFDeliveryPreflightRepairAction:
    String,
    Codable,
    Hashable,
    Sendable {
    case organizePages
    case createEditableCopy

    var title: String {
        switch self {
        case .organizePages:
            return "Fix in Pages"
        case .createEditableCopy:
            return "Create Editable Copy"
        }
    }

    var symbol: String {
        switch self {
        case .organizePages:
            return "square.grid.2x2"
        case .createEditableCopy:
            return "lock.open"
        }
    }
}

struct PDFDeliveryPreflightItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: PDFDeliveryPreflightItemStatus
    var reviewPageIndex: Int? = nil
    var repairAction: PDFDeliveryPreflightRepairAction? = nil

    var resolvedRepairAction: PDFDeliveryPreflightRepairAction? {
        if let repairAction {
            return repairAction
        }
        if id == "locked-source", status == .blocked {
            return .createEditableCopy
        }
        guard id == "blank-pages",
              status == .review,
              reviewPageIndex != nil
        else { return nil }
        return .organizePages
    }
}

struct PDFDeliveryPreflightAssessment: Codable, Hashable, Sendable {
    let status: PDFDeliveryPreflightStatus
    let pageCount: Int
    let byteCount: Int64
    let fixCount: Int
    let reviewCount: Int
    let items: [PDFDeliveryPreflightItem]

    var batchAttentionItem: PDFDeliveryPreflightItem? {
        if let blocked = items.first(where: { $0.status == .blocked }) {
            return blocked
        }
        if let review = items.first(where: { $0.status == .review }) {
            return review
        }
        guard status != .ready else { return nil }
        return PDFDeliveryPreflightItem(
            id: "incomplete-preflight",
            title: "Review before sending",
            detail: "The preflight result was incomplete",
            status: status == .blocked ? .blocked : .review
        )
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

struct PDFDeliveryPreflightCacheEntry: Codable, Hashable, Sendable {
    static let currentRulesVersion = 2
    let recordID: UUID
    let revisionID: UUID
    let checkedAt: Date
    let assessment: PDFDeliveryPreflightAssessment
    var rulesVersion: Int? = currentRulesVersion

    var usesCurrentRules: Bool {
        rulesVersion == Self.currentRulesVersion
    }
}

enum PDFBatchDeliveryStage: String, Codable, Hashable, Sendable {
    case queued
    case checking
    case ready
    case creating
    case verified
    case reused
    case needsReview
    case blocked
    case failed
    case stopped

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .checking: return "Checking"
        case .ready: return "Ready"
        case .creating: return "Creating"
        case .verified: return "Verified"
        case .reused: return "Already verified"
        case .needsReview: return "Review"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "circle.dashed"
        case .checking: return "checklist"
        case .ready: return "checkmark.circle"
        case .creating: return "gearshape.2"
        case .verified: return "checkmark.seal.fill"
        case .reused: return "checkmark.circle.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        case .blocked: return "lock.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    var isFinal: Bool {
        switch self {
        case .queued, .checking, .ready, .creating:
            return false
        case .verified, .reused, .needsReview, .blocked, .failed, .stopped:
            return true
        }
    }

    var isShareable: Bool {
        self == .verified || self == .reused
    }
}

enum PDFBatchDeliveryFailurePhase: String, Codable, Hashable, Sendable {
    case source
    case preflight
    case rendering
    case verification
    case saving
    case cancelled

    var title: String {
        switch self {
        case .source: return "Source"
        case .preflight: return "Preflight"
        case .rendering: return "Create"
        case .verification: return "Verify"
        case .saving: return "Save"
        case .cancelled: return "Stopped"
        }
    }
}

struct PDFBatchDeliveryIssue: Codable, LocalizedError, Hashable, Sendable {
    let phase: PDFBatchDeliveryFailurePhase
    let code: String
    let message: String
    let recovery: String
    let isRetryable: Bool

    var errorDescription: String? {
        "\(phase.title): \(message)"
    }

    static func sourceUnavailable(
        _ message: String = "The private working copy could not be found"
    ) -> Self {
        Self(
            phase: .source,
            code: "S-001",
            message: message,
            recovery: "Reimport the source PDF and try again.",
            isRetryable: false
        )
    }

    static let sourceChanged = Self(
        phase: .source,
        code: "S-002",
        message:
            "The PDF changed before this action started. Review the updated PDF.",
        recovery: "Recheck the current version in the batch results.",
        isRetryable: false
    )

    static func preflightFailed(_ message: String) -> Self {
        Self(
            phase: .preflight,
            code: "P-101",
            message: message,
            recovery: "Open the PDF, confirm it is readable, then retry.",
            isRetryable: true
        )
    }

    static func blocked(_ message: String) -> Self {
        Self(
            phase: .preflight,
            code: "P-201",
            message: message,
            recovery: "Resolve the blocked item before creating a copy.",
            isRetryable: false
        )
    }

    static func review(_ message: String) -> Self {
        Self(
            phase: .preflight,
            code: "P-202",
            message: message,
            recovery: "Review this PDF individually before creating a delivery copy.",
            isRetryable: false
        )
    }

    static func renderingFailed(_ message: String) -> Self {
        Self(
            phase: .rendering,
            code: "C-101",
            message: message,
            recovery: "Free device memory or storage, then retry this PDF.",
            isRetryable: true
        )
    }

    static func compressionNotBeneficial(_ message: String) -> Self {
        Self(
            phase: .verification,
            code: "V-102",
            message: message,
            recovery:
                "The original is already smaller. PaperPath kept it unchanged.",
            isRetryable: false
        )
    }

    static func verificationFailed(_ message: String) -> Self {
        Self(
            phase: .verification,
            code: "V-201",
            message: message,
            recovery: "Review the source pages before trying again.",
            isRetryable: true
        )
    }

    static func savingFailed(_ message: String) -> Self {
        Self(
            phase: .saving,
            code: "S-301",
            message: message,
            recovery: "Free storage and retry this PDF.",
            isRetryable: true
        )
    }

    static let cancelled = Self(
        phase: .cancelled,
        code: "B-001",
        message: "Processing stopped before this PDF finished",
        recovery: "Resume unfinished PDFs when ready.",
        isRetryable: true
    )
}

struct PDFBatchDeliveryItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID { sourceRecordID }
    let sourceRecordID: UUID
    var outputRecordID: UUID? = nil
    var stage: PDFBatchDeliveryStage
    var detail: String
    var reviewPageIndex: Int? = nil
    var issue: PDFBatchDeliveryIssue? = nil

    static func changedSource(_ recordID: UUID) -> Self {
        Self(
            sourceRecordID: recordID, stage: .needsReview,
            detail: PDFBatchDeliveryIssue.sourceChanged.message,
            issue: .sourceChanged
        )
    }
}

enum PDFBatchSelection {
    static func adding(
        _ matches: [UUID], to selected: Set<UUID>, limit: Int = 64
    ) -> Set<UUID> {
        var result = selected
        for id in matches where result.count < max(0, limit) {
            result.insert(id)
        }
        return result
    }
}

struct PDFBatchDeliveryRun: Codable, Hashable, Identifiable, Sendable {
    static let maximumDocumentCount = 64

    let id: UUID
    let startedAt: Date
    let updatedAt: Date
    let sourceRecordIDs: [UUID]
    let sourceRevisionIDs: [UUID: UUID]
    let items: [PDFBatchDeliveryItem]

    var needsRecovery: Bool {
        items.contains {
            !$0.stage.isShareable
                && $0.stage != .blocked
                && $0.stage != .needsReview
        }
    }

    var needsAttention: Bool {
        items.contains { !$0.stage.isShareable }
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let sourceIDs = Set(sourceRecordIDs)
        let itemIDs = Set(items.map(\.sourceRecordID))
        let outputIDs = items.compactMap(\.outputRecordID)
        return PDFEvidenceContract.isPlausiblePastDate(
                startedAt,
                now: date
            )
            && PDFEvidenceContract.isPlausiblePastDate(
                updatedAt,
                now: date
            )
            && updatedAt >= startedAt
            && !sourceRecordIDs.isEmpty
            && sourceRecordIDs.count <= Self.maximumDocumentCount
            && sourceIDs.count == sourceRecordIDs.count
            && sourceIDs == Set(sourceRevisionIDs.keys)
            && sourceIDs == itemIDs
            && itemIDs.count == items.count
            && Set(outputIDs).count == outputIDs.count
            && items.allSatisfy {
                ($0.reviewPageIndex ?? 0) >= 0
                    && $0.outputRecordID != $0.sourceRecordID
                    && PDFEvidenceContract.isSafeDisplayText(
                        $0.detail,
                        maximumCharacters: 2_000,
                        maximumUTF8Bytes: 8_000,
                        allowsEmpty: true
                    )
                    && ($0.issue.map {
                        PDFEvidenceContract.isSafeDisplayText(
                            $0.code,
                            maximumCharacters: 32,
                            maximumUTF8Bytes: 64
                        )
                            && PDFEvidenceContract.isSafeDisplayText(
                                $0.message,
                                maximumCharacters: 2_000,
                                maximumUTF8Bytes: 8_000
                            )
                            && PDFEvidenceContract.isSafeDisplayText(
                                $0.recovery,
                                maximumCharacters: 2_000,
                                maximumUTF8Bytes: 8_000
                            )
                    } ?? true)
            }
    }
}

struct PDFDeliveryCheck: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: PDFDeliveryCheckStatus
}

enum PDFChangePageSide: String, Hashable, Sendable {
    case source
    case revised

    var title: String {
        switch self {
        case .source: return "BASE"
        case .revised: return "REVISED"
        }
    }
}

enum PDFPageMatchKind:
    String,
    Codable,
    Hashable,
    Sendable {
    case unchanged
    case modified
    case inserted
    case removed

    var title: String {
        switch self {
        case .unchanged: return "Unchanged"
        case .modified: return "Modified"
        case .inserted: return "Inserted"
        case .removed: return "Removed"
        }
    }
}

enum PDFChangeSeverity:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable {
    case critical
    case major
    case minor

    var title: String {
        switch self {
        case .critical: return "Critical"
        case .major: return "Major"
        case .minor: return "Minor"
        }
    }
}

struct PDFDifferenceRegion:
    Codable,
    Hashable,
    Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let intensity: Double

    var isStructurallyValid: Bool {
        let values = [x, y, width, height, intensity]
        return values.allSatisfy(\.isFinite)
            && x >= 0
            && y >= 0
            && width > 0
            && height > 0
            && x + width <= 1.001
            && y + height <= 1.001
            && (0...1).contains(intensity)
    }
}

enum PDFTextDifferenceKind:
    String,
    Codable,
    Hashable,
    Sendable {
    case removed
    case inserted

    var title: String {
        switch self {
        case .removed: return "Removed text"
        case .inserted: return "Inserted text"
        }
    }
}

enum PDFTextDifferenceGranularity:
    String,
    Codable,
    Hashable,
    Sendable {
    case word
    case character

    var title: String {
        switch self {
        case .word: return "Word"
        case .character: return "Character"
        }
    }
}

struct PDFTextDifferenceEvidence:
    Codable,
    Hashable,
    Sendable {
    let kind: PDFTextDifferenceKind
    let text: String
    let region: PDFDifferenceRegion
    let granularity: PDFTextDifferenceGranularity?

    init(
        kind: PDFTextDifferenceKind,
        text: String,
        region: PDFDifferenceRegion,
        granularity: PDFTextDifferenceGranularity = .word
    ) {
        self.kind = kind
        self.text = text
        self.region = region
        self.granularity = granularity
    }

    var resolvedGranularity: PDFTextDifferenceGranularity {
        granularity ?? .word
    }
}

enum PDFVectorDifferenceKind:
    String,
    Codable,
    Hashable,
    Sendable {
    case removed
    case inserted

    var title: String {
        switch self {
        case .removed: return "Removed vector object"
        case .inserted: return "Added vector object"
        }
    }
}

struct PDFVectorDifferenceEvidence:
    Codable,
    Hashable,
    Sendable {
    let kind: PDFVectorDifferenceKind
    let region: PDFDifferenceRegion
}

enum PDFEvidenceOverlayTone:
    String,
    Hashable,
    Sendable {
    case source
    case revised
}

struct PDFEvidenceOverlay:
    Hashable,
    Sendable {
    let pageIndex: Int
    let regions: [PDFDifferenceRegion]
    let textRegions: [PDFDifferenceRegion]
    let characterTextRegions: [PDFDifferenceRegion]
    let vectorRegions: [PDFDifferenceRegion]
    let tone: PDFEvidenceOverlayTone
    let generation: Int

    init(
        pageIndex: Int,
        regions: [PDFDifferenceRegion],
        textRegions: [PDFDifferenceRegion] = [],
        characterTextRegions: [PDFDifferenceRegion] = [],
        vectorRegions: [PDFDifferenceRegion] = [],
        tone: PDFEvidenceOverlayTone,
        generation: Int
    ) {
        self.pageIndex = pageIndex
        self.regions = regions
        self.textRegions = textRegions
        self.characterTextRegions = characterTextRegions
        self.vectorRegions = vectorRegions
        self.tone = tone
        self.generation = generation
    }
}

enum PDFPageMatchBasis:
    String,
    Codable,
    Hashable,
    Sendable {
    case exactContent
    case repeatedContent
    case pageLabel
    case textMarker
    case barcode
    case context
    case manual
    case similarity

    var title: String {
        switch self {
        case .exactContent: return "Exact page"
        case .repeatedContent: return "Repeated template"
        case .pageLabel: return "Page label"
        case .textMarker: return "Text marker"
        case .barcode: return "Barcode"
        case .context: return "Neighbor context"
        case .manual: return "Manual match"
        case .similarity: return "Visual similarity"
        }
    }

    var evidenceDetail: String {
        switch self {
        case .exactContent:
            return "Identical page content"
        case .repeatedContent:
            return "Same template paired by stable document order"
        case .pageLabel:
            return "Matching PDF page label"
        case .textMarker:
            return "Matching stable text marker"
        case .barcode:
            return "Matching barcode evidence"
        case .context:
            return "Matching neighboring page context"
        case .manual:
            return "Confirmed by you for this comparison"
        case .similarity:
            return "Best bounded visual similarity"
        }
    }

    var symbol: String {
        switch self {
        case .exactContent:
            return "checkmark.square"
        case .repeatedContent:
            return "square.stack.3d.up"
        case .pageLabel:
            return "number.square"
        case .textMarker:
            return "text.magnifyingglass"
        case .barcode:
            return "barcode.viewfinder"
        case .context:
            return "link"
        case .manual:
            return "checkmark.circle"
        case .similarity:
            return "viewfinder"
        }
    }
}

struct PDFManualPageMatch:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    let sourcePageIndex: Int
    let revisedPageIndex: Int

    var id: String {
        "\(sourcePageIndex)-\(revisedPageIndex)"
    }

    func isValid(
        sourcePageCount: Int,
        revisedPageCount: Int
    ) -> Bool {
        sourcePageIndex >= 0
            && sourcePageIndex < sourcePageCount
            && revisedPageIndex >= 0
            && revisedPageIndex < revisedPageCount
    }
}

enum PDFManualPageMatchPersistence:
    String,
    Codable,
    Hashable,
    Sendable {
    case savedOnDevice
    case restoredFromDevice
}

enum PDFManualPageMatchCorrectionContext:
    String,
    Codable,
    Hashable,
    Sendable {
    case documentPair
    case versionSnapshot
}

struct PDFManualPageMatchCorrection:
    Codable,
    Hashable,
    Sendable {
    static let maximumPageCount = 100_000
    static let maximumMatchCount = 1_024

    let context: PDFManualPageMatchCorrectionContext
    let sourceDocumentID: UUID
    let sourceRevisionID: UUID
    let revisedDocumentID: UUID
    let revisedRevisionID: UUID
    let versionSnapshotID: UUID?
    let sourcePageCount: Int
    let revisedPageCount: Int
    let matches: [PDFManualPageMatch]
    let updatedAt: Date

    var comparisonIdentity: String {
        switch context {
        case .documentPair:
            return [
                context.rawValue,
                sourceDocumentID.uuidString,
                revisedDocumentID.uuidString
            ].joined(separator: ":")
        case .versionSnapshot:
            return [
                context.rawValue,
                revisedDocumentID.uuidString,
                versionSnapshotID?.uuidString ?? ""
            ].joined(separator: ":")
        }
    }

    func isStructurallyValid(
        at referenceDate: Date
    ) -> Bool {
        let timestamp = updatedAt.timeIntervalSince1970
        guard timestamp.isFinite,
              timestamp >= 0,
              updatedAt <= referenceDate.addingTimeInterval(5 * 60),
              (1...Self.maximumPageCount).contains(
                sourcePageCount
              ),
              (1...Self.maximumPageCount).contains(
                revisedPageCount
              ),
              !matches.isEmpty,
              matches.count <= Self.maximumMatchCount,
              matches.count <= min(
                sourcePageCount,
                revisedPageCount
              )
        else { return false }

        switch context {
        case .documentPair:
            guard sourceDocumentID != revisedDocumentID,
                  versionSnapshotID == nil
            else { return false }
        case .versionSnapshot:
            guard sourceDocumentID == revisedDocumentID,
                  versionSnapshotID != nil
            else { return false }
        }

        var previousSource = -1
        var previousRevised = -1
        for match in matches {
            guard match.isValid(
                sourcePageCount: sourcePageCount,
                revisedPageCount: revisedPageCount
            ),
                  match.sourcePageIndex > previousSource,
                  match.revisedPageIndex > previousRevised
            else { return false }
            previousSource = match.sourcePageIndex
            previousRevised = match.revisedPageIndex
        }
        return true
    }

    func reversedDocumentPair() -> PDFManualPageMatchCorrection? {
        guard context == .documentPair else { return nil }
        return PDFManualPageMatchCorrection(
            context: .documentPair,
            sourceDocumentID: revisedDocumentID,
            sourceRevisionID: revisedRevisionID,
            revisedDocumentID: sourceDocumentID,
            revisedRevisionID: sourceRevisionID,
            versionSnapshotID: nil,
            sourcePageCount: revisedPageCount,
            revisedPageCount: sourcePageCount,
            matches: matches.map {
                PDFManualPageMatch(
                    sourcePageIndex: $0.revisedPageIndex,
                    revisedPageIndex: $0.sourcePageIndex
                )
            },
            updatedAt: updatedAt
        )
    }
}

struct PDFManualPageMatchCorrectionLookup: Sendable {
    let correction: PDFManualPageMatchCorrection?
    let discardedStaleCorrection: Bool

    static let none = PDFManualPageMatchCorrectionLookup(
        correction: nil,
        discardedStaleCorrection: false
    )
}

struct PDFManualPageMatchStorageSummary: Hashable, Sendable {
    static let maximumCorrectionCount = 256
    static let maximumByteCount: Int64 = 1 * 1_024 * 1_024

    static let empty = PDFManualPageMatchStorageSummary(
        correctionCount: 0,
        pageMatchCount: 0,
        byteCount: 0,
        newestUpdate: nil
    )

    let correctionCount: Int
    let pageMatchCount: Int
    let byteCount: Int64
    let newestUpdate: Date?

    static func measuring<S: Sequence>(
        _ corrections: S,
        byteCount: Int64
    ) -> PDFManualPageMatchStorageSummary
    where S.Element == PDFManualPageMatchCorrection {
        var correctionCount = 0
        var pageMatchCount = 0
        var newestUpdate: Date?
        for correction in corrections {
            correctionCount += 1
            pageMatchCount += correction.matches.count
            newestUpdate = max(
                newestUpdate ?? correction.updatedAt,
                correction.updatedAt
            )
        }
        return PDFManualPageMatchStorageSummary(
            correctionCount: correctionCount,
            pageMatchCount: pageMatchCount,
            byteCount: max(0, byteCount),
            newestUpdate: newestUpdate
        )
    }

    var formattedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var countContract: String {
        "\(correctionCount)/\(Self.maximumCorrectionCount)"
    }

    var byteContract: String {
        AppLocalization.format(
            "%@ / %@",
            formattedBytes,
            ByteCountFormatter.string(
                fromByteCount: Self.maximumByteCount,
                countStyle: .file
            )
        )
    }

    var countUsageFraction: Double {
        min(
            1,
            Double(max(0, correctionCount))
                / Double(Self.maximumCorrectionCount)
        )
    }

    var byteUsageFraction: Double {
        min(
            1,
            Double(max(0, byteCount))
                / Double(Self.maximumByteCount)
        )
    }

    var pressureFraction: Double {
        max(countUsageFraction, byteUsageFraction)
    }

    var isNearCapacity: Bool {
        correctionCount >= Self.maximumCorrectionCount - 32
            || byteUsageFraction >= 0.8
    }
}

struct PDFPageMatch:
    Codable,
    Hashable,
    Identifiable,
    Sendable {
    let id: Int
    let sourcePageIndex: Int?
    let revisedPageIndex: Int?
    let kind: PDFPageMatchKind
    let basis: PDFPageMatchBasis?

    init(
        id: Int,
        sourcePageIndex: Int?,
        revisedPageIndex: Int?,
        kind: PDFPageMatchKind,
        basis: PDFPageMatchBasis? = nil
    ) {
        self.id = id
        self.sourcePageIndex = sourcePageIndex
        self.revisedPageIndex = revisedPageIndex
        self.kind = kind
        self.basis = basis
    }
}

struct PDFPageChange: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        "\(resolvedSourcePageIndex.map(String.init) ?? "x")-\(resolvedRevisedPageIndex.map(String.init) ?? "x")-\(pageIndex)"
    }

    let pageIndex: Int
    let sourcePageIndex: Int?
    let revisedPageIndex: Int?
    let matchKind: PDFPageMatchKind?
    let sourceExists: Bool
    let revisedExists: Bool
    let visibleDifference: Double
    let changedPixelRatio: Double
    let geometryChanged: Bool
    let textChanged: Bool
    let sourceTextCharacterCount: Int
    let revisedTextCharacterCount: Int
    let differenceRegions: [PDFDifferenceRegion]?
    let sourceTextDifferences: [PDFTextDifferenceEvidence]?
    let revisedTextDifferences: [PDFTextDifferenceEvidence]?
    let sourceTextDifferenceOmittedCount: Int?
    let revisedTextDifferenceOmittedCount: Int?
    let sourceVectorDifferences: [PDFVectorDifferenceEvidence]?
    let revisedVectorDifferences: [PDFVectorDifferenceEvidence]?
    let matchBasis: PDFPageMatchBasis?

    init(
        pageIndex: Int,
        sourcePageIndex: Int? = nil,
        revisedPageIndex: Int? = nil,
        matchKind: PDFPageMatchKind? = nil,
        sourceExists: Bool,
        revisedExists: Bool,
        visibleDifference: Double,
        changedPixelRatio: Double,
        geometryChanged: Bool,
        textChanged: Bool,
        sourceTextCharacterCount: Int,
        revisedTextCharacterCount: Int,
        differenceRegions: [PDFDifferenceRegion]? = nil,
        sourceTextDifferences: [PDFTextDifferenceEvidence]? = nil,
        revisedTextDifferences: [PDFTextDifferenceEvidence]? = nil,
        sourceTextDifferenceOmittedCount: Int? = nil,
        revisedTextDifferenceOmittedCount: Int? = nil,
        sourceVectorDifferences: [PDFVectorDifferenceEvidence]? = nil,
        revisedVectorDifferences: [PDFVectorDifferenceEvidence]? = nil,
        matchBasis: PDFPageMatchBasis? = nil
    ) {
        self.pageIndex = pageIndex
        self.sourcePageIndex = sourcePageIndex
        self.revisedPageIndex = revisedPageIndex
        self.matchKind = matchKind
        self.sourceExists = sourceExists
        self.revisedExists = revisedExists
        self.visibleDifference = visibleDifference
        self.changedPixelRatio = changedPixelRatio
        self.geometryChanged = geometryChanged
        self.textChanged = textChanged
        self.sourceTextCharacterCount = sourceTextCharacterCount
        self.revisedTextCharacterCount = revisedTextCharacterCount
        self.differenceRegions = differenceRegions
        self.sourceTextDifferences = sourceTextDifferences
        self.revisedTextDifferences = revisedTextDifferences
        self.sourceTextDifferenceOmittedCount =
            sourceTextDifferenceOmittedCount
        self.revisedTextDifferenceOmittedCount =
            revisedTextDifferenceOmittedCount
        self.sourceVectorDifferences = sourceVectorDifferences
        self.revisedVectorDifferences = revisedVectorDifferences
        self.matchBasis = matchBasis
    }

    var resolvedSourcePageIndex: Int? {
        sourcePageIndex ?? (sourceExists ? pageIndex : nil)
    }

    var resolvedRevisedPageIndex: Int? {
        revisedPageIndex ?? (revisedExists ? pageIndex : nil)
    }

    var resolvedMatchKind: PDFPageMatchKind {
        if let matchKind {
            return matchKind
        }
        if !sourceExists {
            return .inserted
        }
        if !revisedExists {
            return .removed
        }
        return .modified
    }

    var isVisibleChange: Bool {
        !sourceExists
            || !revisedExists
            || geometryChanged
            || changedPixelRatio >= 0.0004
                && visibleDifference >= 0.00005
    }

    var isTextOnlyChange: Bool {
        textChanged && !isVisibleChange
    }

    var textDifferenceCount: Int {
        (sourceTextDifferences?.count ?? 0)
            + (revisedTextDifferences?.count ?? 0)
    }

    var hasLocatedTextDifferences: Bool {
        textDifferenceCount > 0 || hasTruncatedTextDifferences
    }

    var resolvedSourceTextDifferenceOmittedCount: Int {
        max(0, sourceTextDifferenceOmittedCount ?? 0)
    }

    var resolvedRevisedTextDifferenceOmittedCount: Int {
        max(0, revisedTextDifferenceOmittedCount ?? 0)
    }

    var textDifferenceOmittedCount: Int {
        let (total, overflow) =
            resolvedSourceTextDifferenceOmittedCount
                .addingReportingOverflow(
                    resolvedRevisedTextDifferenceOmittedCount
                )
        return overflow ? .max : total
    }

    var hasTruncatedTextDifferences: Bool {
        textDifferenceOmittedCount > 0
    }

    var vectorDifferenceCount: Int {
        (sourceVectorDifferences?.count ?? 0)
            + (revisedVectorDifferences?.count ?? 0)
    }

    var hasLocatedVectorDifferences: Bool {
        vectorDifferenceCount > 0
    }

    var localizedVectorEvidenceCountLabel: String {
        AppLocalization.format(
            "%lld vector boundar%@",
            vectorDifferenceCount,
            vectorDifferenceCount == 1 ? "y" : "ies"
        )
    }

    var characterDifferenceCount: Int {
        (sourceTextDifferences ?? []).filter {
            $0.resolvedGranularity == .character
        }.count
            + (revisedTextDifferences ?? []).filter {
                $0.resolvedGranularity == .character
            }.count
    }

    var wordDifferenceCount: Int {
        max(0, textDifferenceCount - characterDifferenceCount)
    }

    var hasCharacterDifferences: Bool {
        characterDifferenceCount > 0
    }

    var localizedTextEvidenceCountLabel: String {
        let capturedLabel: String
        if characterDifferenceCount > 0, wordDifferenceCount > 0 {
            capturedLabel = [
                localizedTextEvidenceCount(
                    characterDifferenceCount,
                    key: "%lld character mark%@"
                ),
                localizedTextEvidenceCount(
                    wordDifferenceCount,
                    key: "%lld word mark%@"
                )
            ].joined(separator: " · ")
        } else if characterDifferenceCount > 0 {
            capturedLabel = localizedTextEvidenceCount(
                characterDifferenceCount,
                key: "%lld character mark%@"
            )
        } else {
            capturedLabel = localizedTextEvidenceCount(
                wordDifferenceCount,
                key: "%lld word mark%@"
            )
        }
        guard hasTruncatedTextDifferences else {
            return capturedLabel
        }
        let omittedLabel = textDifferenceOmittedCount == 1
            ? "1 additional text mark not shown".localizedUI
            : AppLocalization.format(
                "%lld additional text marks not shown",
                textDifferenceOmittedCount
            )
        return [
            capturedLabel,
            omittedLabel
        ].joined(separator: " · ")
    }

    var resolvedTextDifferenceGranularity:
        PDFTextDifferenceGranularity? {
        guard hasLocatedTextDifferences else { return nil }
        return hasCharacterDifferences ? .character : .word
    }

    var textDifferencePreview: String? {
        let removed = compactTextEvidence(sourceTextDifferences)
        let inserted = compactTextEvidence(revisedTextDifferences)
        switch (removed?.isEmpty == false, inserted?.isEmpty == false) {
        case (true, true):
            return AppLocalization.format(
                "%@ → %@",
                removed ?? "",
                inserted ?? ""
            )
        case (true, false):
            return AppLocalization.format(
                "Deleted text: %@",
                removed ?? ""
            )
        case (false, true):
            return AppLocalization.format(
                "Added text: %@",
                inserted ?? ""
            )
        case (false, false):
            return nil
        }
    }

    private func compactTextEvidence(
        _ evidence: [PDFTextDifferenceEvidence]?
    ) -> String? {
        guard let evidence else { return nil }
        let characterEvidence = evidence.filter {
            $0.resolvedGranularity == .character
        }
        let preferredEvidence = characterEvidence.isEmpty
            ? evidence
            : characterEvidence
        let snippets = preferredEvidence
            .prefix(3)
            .map {
                compactTextFragment(
                    $0.text,
                    limit: $0.resolvedGranularity == .character ? 18 : 48
                )
            }
            .filter { !$0.isEmpty }
        guard !snippets.isEmpty else { return nil }
        let omitted = preferredEvidence.count - snippets.count
        let summary = snippets.joined(separator: " · ")
        return omitted > 0 ? "\(summary) +\(omitted)" : summary
    }

    private func localizedTextEvidenceCount(
        _ count: Int,
        key: String
    ) -> String {
        AppLocalization.format(
            key,
            count,
            count == 1 ? "" : "s"
        )
    }

    private func compactTextFragment(
        _ value: String,
        limit: Int
    ) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let visible = collapsed.isEmpty && !value.isEmpty
            ? visibleWhitespacePreview(value)
            : collapsed
        guard visible.count > limit else { return visible }
        return String(visible.prefix(limit)) + "..."
    }

    private func visibleWhitespacePreview(_ value: String) -> String {
        value.map { character -> String in
            switch character {
            case " ": return "␠"
            case "\n", "\r": return "↵"
            case "\t": return "⇥"
            default: return String(character)
            }
        }
        .joined()
    }

    var isMajorVisibleChange: Bool {
        !sourceExists
            || !revisedExists
            || geometryChanged
            || visibleDifference >= 0.002
            || changedPixelRatio >= 0.03
    }

    var preferredOpenSide: PDFChangePageSide {
        revisedExists ? .revised : .source
    }

    var preferredOpenPageIndex: Int? {
        switch preferredOpenSide {
        case .source:
            return resolvedSourcePageIndex
        case .revised:
            return resolvedRevisedPageIndex
        }
    }

    var severity: PDFChangeSeverity {
        if !sourceExists
            || !revisedExists
            || geometryChanged
            || visibleDifference >= 0.012
            || changedPixelRatio >= 0.16 {
            return .critical
        }
        if visibleDifference >= 0.002
            || changedPixelRatio >= 0.03
            || textChanged {
            return .major
        }
        return .minor
    }
}

struct PDFChangeReview: Codable, Hashable, Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumAlignmentCount = 200_000
    private static let maximumVisualRegionsPerChange = 12
    private static let maximumEvidencePerSide = 24
    private static let maximumEvidenceCharacters = 160
    private static let maximumEvidenceUTF8Bytes = 640

    let sourcePageCount: Int
    let revisedPageCount: Int
    let comparedPageCount: Int
    let changes: [PDFPageChange]
    let pageMatches: [PDFPageMatch]?
    let manualPageMatches: [PDFManualPageMatch]?
    let manualPageMatchPersistence:
        PDFManualPageMatchPersistence?

    init(
        sourcePageCount: Int,
        revisedPageCount: Int,
        comparedPageCount: Int,
        changes: [PDFPageChange],
        pageMatches: [PDFPageMatch]? = nil,
        manualPageMatches: [PDFManualPageMatch]? = nil,
        manualPageMatchPersistence:
            PDFManualPageMatchPersistence? = nil
    ) {
        self.sourcePageCount = sourcePageCount
        self.revisedPageCount = revisedPageCount
        self.comparedPageCount = comparedPageCount
        self.changes = changes
        self.pageMatches = pageMatches
        self.manualPageMatches = manualPageMatches
        self.manualPageMatchPersistence =
            manualPageMatchPersistence
    }

    var visibleChanges: [PDFPageChange] {
        changes.filter(\.isVisibleChange)
    }

    var textChanges: [PDFPageChange] {
        changes.filter(\.textChanged)
    }

    var vectorChanges: [PDFPageChange] {
        changes.filter(\.hasLocatedVectorDifferences)
    }

    var majorVisibleChanges: [PDFPageChange] {
        changes.filter(\.isMajorVisibleChange)
    }

    var geometryChanges: [PDFPageChange] {
        changes.filter(\.geometryChanged)
    }

    var criticalChanges: [PDFPageChange] {
        changes.filter { $0.severity == .critical }
    }

    var insertedPages: [PDFPageChange] {
        changes.filter {
            $0.resolvedMatchKind == .inserted
        }
    }

    var removedPages: [PDFPageChange] {
        changes.filter {
            $0.resolvedMatchKind == .removed
        }
    }

    var visibleChangedPageCount: Int {
        visibleChanges.count
    }

    var textChangedPageCount: Int {
        textChanges.count
    }

    var vectorChangedPageCount: Int {
        vectorChanges.count
    }

    var totalVectorDifferenceCount: Int {
        changes.reduce(0) {
            $0 + $1.vectorDifferenceCount
        }
    }

    var geometryChangedPageCount: Int {
        geometryChanges.count
    }

    var totalChangedPageCount: Int {
        changes.count
    }

    var addedPageCount: Int {
        max(0, revisedPageCount - sourcePageCount)
    }

    var removedPageCount: Int {
        max(0, sourcePageCount - revisedPageCount)
    }

    var visiblyUnchangedPageCount: Int {
        max(0, comparedPageCount - visibleChanges.filter {
            $0.sourceExists && $0.revisedExists
        }.count)
    }

    var isIdentical: Bool {
        sourcePageCount == revisedPageCount && changes.isEmpty
    }

    func isStructurallyValid() -> Bool {
        guard (1...Self.maximumPageCount).contains(sourcePageCount),
              (1...Self.maximumPageCount).contains(revisedPageCount),
              (0...min(sourcePageCount, revisedPageCount))
                .contains(comparedPageCount),
              changes.count <= Self.maximumAlignmentCount,
              (pageMatches?.count ?? 0) <= Self.maximumAlignmentCount,
              (manualPageMatches?.count ?? 0)
                <= PDFManualPageMatchCorrection.maximumMatchCount,
              validChanges(),
              validPageMatches(),
              validManualPageMatches()
        else { return false }
        return true
    }

    private func validChanges() -> Bool {
        var identities: Set<String> = []
        return changes.allSatisfy { change in
            let sourceIndexIsValid =
                change.resolvedSourcePageIndex.map {
                    (0..<sourcePageCount).contains($0)
                } ?? true
            let revisedIndexIsValid =
                change.resolvedRevisedPageIndex.map {
                    (0..<revisedPageCount).contains($0)
                } ?? true
            guard identities.insert(change.id).inserted,
                  change.pageIndex >= 0,
                  change.pageIndex < Self.maximumAlignmentCount,
                  change.visibleDifference.isFinite,
                  (0...1).contains(change.visibleDifference),
                  change.changedPixelRatio.isFinite,
                  (0...1).contains(change.changedPixelRatio),
                  change.sourceTextCharacterCount >= 0,
                  change.revisedTextCharacterCount >= 0,
                  change.sourceExists
                    == (change.resolvedSourcePageIndex != nil),
                  change.revisedExists
                    == (change.resolvedRevisedPageIndex != nil),
                  change.sourceExists || change.revisedExists,
                  validChangeKind(change),
                  sourceIndexIsValid,
                  revisedIndexIsValid,
                  validRegions(
                      change.differenceRegions,
                      maximumCount:
                        Self.maximumVisualRegionsPerChange
                  ),
                  validTextEvidence(change.sourceTextDifferences),
                  validTextEvidence(change.revisedTextDifferences),
                  validVectorEvidence(change.sourceVectorDifferences),
                  validVectorEvidence(change.revisedVectorDifferences),
                  change.resolvedSourceTextDifferenceOmittedCount
                    <= Self.maximumPageCount,
                  change.resolvedRevisedTextDifferenceOmittedCount
                    <= Self.maximumPageCount
            else { return false }
            return true
        }
    }

    private func validPageMatches() -> Bool {
        guard let pageMatches else { return true }
        var identities: Set<Int> = []
        var sourceIndices: Set<Int> = []
        var revisedIndices: Set<Int> = []
        var pairedCount = 0
        for match in pageMatches {
            guard identities.insert(match.id).inserted,
                  match.sourcePageIndex != nil
                    || match.revisedPageIndex != nil,
                  validMatchKind(match)
            else { return false }
            if let sourceIndex = match.sourcePageIndex {
                guard (0..<sourcePageCount).contains(sourceIndex),
                      sourceIndices.insert(sourceIndex).inserted
                else { return false }
            }
            if let revisedIndex = match.revisedPageIndex {
                guard (0..<revisedPageCount).contains(revisedIndex),
                      revisedIndices.insert(revisedIndex).inserted
                else { return false }
            }
            if match.sourcePageIndex != nil,
               match.revisedPageIndex != nil {
                pairedCount += 1
            }
        }
        return pairedCount == comparedPageCount
    }

    private func validManualPageMatches() -> Bool {
        guard let manualPageMatches else { return true }
        var previousSource = -1
        var previousRevised = -1
        for match in manualPageMatches {
            guard match.isValid(
                sourcePageCount: sourcePageCount,
                revisedPageCount: revisedPageCount
            ),
                  match.sourcePageIndex > previousSource,
                  match.revisedPageIndex > previousRevised
            else { return false }
            previousSource = match.sourcePageIndex
            previousRevised = match.revisedPageIndex
        }
        return true
    }

    private func validTextEvidence(
        _ evidence: [PDFTextDifferenceEvidence]?
    ) -> Bool {
        guard let evidence else { return true }
        return evidence.count <= Self.maximumEvidencePerSide
            && evidence.allSatisfy {
                validEvidenceText($0.text)
                    && $0.region.isStructurallyValid
            }
    }

    private func validEvidenceText(_ text: String) -> Bool {
        !text.isEmpty
            && text.count <= Self.maximumEvidenceCharacters
            && text.utf8.count <= Self.maximumEvidenceUTF8Bytes
            && text.unicodeScalars.allSatisfy {
                $0.value != 0
                    && !CharacterSet.illegalCharacters.contains($0)
            }
    }

    private func validVectorEvidence(
        _ evidence: [PDFVectorDifferenceEvidence]?
    ) -> Bool {
        guard let evidence else { return true }
        return evidence.count <= Self.maximumEvidencePerSide
            && evidence.allSatisfy {
                $0.region.isStructurallyValid
            }
    }

    private func validRegions(
        _ regions: [PDFDifferenceRegion]?,
        maximumCount: Int
    ) -> Bool {
        guard let regions else { return true }
        return regions.count <= maximumCount
            && regions.allSatisfy(\.isStructurallyValid)
    }

    private func validChangeKind(_ change: PDFPageChange) -> Bool {
        switch (
            change.sourceExists,
            change.revisedExists,
            change.resolvedMatchKind
        ) {
        case (false, true, .inserted),
             (true, false, .removed),
             (true, true, .modified):
            return true
        default:
            return false
        }
    }

    private func validMatchKind(_ match: PDFPageMatch) -> Bool {
        switch (
            match.sourcePageIndex != nil,
            match.revisedPageIndex != nil,
            match.kind
        ) {
        case (false, true, .inserted),
             (true, false, .removed),
             (true, true, .modified),
             (true, true, .unchanged):
            return true
        default:
            return false
        }
    }

    var pairedPageMatchCount: Int {
        guard let pageMatches,
              !pageMatches.isEmpty
        else {
            return min(sourcePageCount, revisedPageCount)
        }
        return pageMatches.reduce(into: 0) { count, match in
            if match.sourcePageIndex != nil,
               match.revisedPageIndex != nil {
                count += 1
            }
        }
    }

    var stablePageMatchCount: Int {
        guard let pageMatches,
              !pageMatches.isEmpty
        else { return 0 }
        return pageMatches.reduce(into: 0) { count, match in
            if match.sourcePageIndex != nil,
               match.revisedPageIndex != nil,
               let basis = match.basis,
               basis != .similarity {
                count += 1
            }
        }
    }

    var repeatedTemplateMatchCount: Int {
        guard let pageMatches,
              !pageMatches.isEmpty
        else { return 0 }
        return pageMatches.reduce(into: 0) { count, match in
            if match.sourcePageIndex != nil,
               match.revisedPageIndex != nil,
               match.basis == .repeatedContent {
                count += 1
            }
        }
    }

    var similarityPageMatchCount: Int {
        guard let pageMatches,
              !pageMatches.isEmpty
        else { return 0 }
        return pageMatches.reduce(into: 0) { count, match in
            if match.sourcePageIndex != nil,
               match.revisedPageIndex != nil,
               match.basis == .similarity {
                count += 1
            }
        }
    }

    var resolvedManualPageMatches: [PDFManualPageMatch] {
        if let manualPageMatches {
            return manualPageMatches
        }
        guard let pageMatches,
              !pageMatches.isEmpty
        else { return [] }
        return pageMatches.compactMap { match in
            guard match.basis == .manual,
                  let sourcePageIndex = match.sourcePageIndex,
                  let revisedPageIndex = match.revisedPageIndex
            else { return nil }
            return PDFManualPageMatch(
                sourcePageIndex: sourcePageIndex,
                revisedPageIndex: revisedPageIndex
            )
        }
    }

    var manualPageMatchCount: Int {
        resolvedManualPageMatches.count
    }

    func markingManualPageMatchPersistence(
        _ persistence: PDFManualPageMatchPersistence?
    ) -> PDFChangeReview {
        PDFChangeReview(
            sourcePageCount: sourcePageCount,
            revisedPageCount: revisedPageCount,
            comparedPageCount: comparedPageCount,
            changes: changes,
            pageMatches: pageMatches,
            manualPageMatches: manualPageMatches,
            manualPageMatchPersistence:
                resolvedManualPageMatches.isEmpty
                    ? nil
                    : persistence
        )
    }

    var estimatedCacheByteCount: Int64 {
        func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }

        func scaled(_ count: Int, by unit: Int64) -> Int64 {
            let (product, overflow) = Int64(clamping: count)
                .multipliedReportingOverflow(by: unit)
            return overflow ? .max : product
        }

        func evidenceCost(
            _ evidence: [PDFTextDifferenceEvidence]?
        ) -> Int64 {
            (evidence ?? []).reduce(Int64.zero) { total, item in
                adding(
                    total,
                    adding(
                        128,
                        Int64(clamping: item.text.utf8.count)
                    )
                )
            }
        }

        var total = adding(
            256,
            scaled(changes.count, by: 256)
        )
        total = adding(
            total,
            scaled(pageMatches?.count ?? 0, by: 48)
        )
        total = adding(
            total,
            scaled(manualPageMatches?.count ?? 0, by: 24)
        )
        for change in changes {
            total = adding(
                total,
                scaled(
                    change.differenceRegions?.count ?? 0,
                    by: 48
                )
            )
            total = adding(
                total,
                evidenceCost(change.sourceTextDifferences)
            )
            total = adding(
                total,
                evidenceCost(change.revisedTextDifferences)
            )
            total = adding(
                total,
                scaled(
                    change.sourceVectorDifferences?.count ?? 0,
                    by: 64
                )
            )
            total = adding(
                total,
                scaled(
                    change.revisedVectorDifferences?.count ?? 0,
                    by: 64
                )
            )
        }
        return total
    }

    var resolvedPageMatches: [PDFPageMatch] {
        if let pageMatches, !pageMatches.isEmpty {
            return pageMatches
        }
        return (0..<max(sourcePageCount, revisedPageCount)).map {
            index in
            let source = index < sourcePageCount ? index : nil
            let revised = index < revisedPageCount ? index : nil
            return PDFPageMatch(
                id: index,
                sourcePageIndex: source,
                revisedPageIndex: revised,
                kind: source == nil
                    ? .inserted
                    : revised == nil
                        ? .removed
                        : .unchanged
            )
        }
    }

    func revisedPage(matchingSourcePage index: Int) -> Int? {
        guard sourcePageCount > 0,
              index >= 0,
              index < sourcePageCount
        else { return nil }
        guard let pageMatches, !pageMatches.isEmpty else {
            return index < revisedPageCount ? index : nil
        }
        return pageMatches.first {
            $0.sourcePageIndex == index
        }?.revisedPageIndex
    }

    func sourcePage(matchingRevisedPage index: Int) -> Int? {
        guard revisedPageCount > 0,
              index >= 0,
              index < revisedPageCount
        else { return nil }
        guard let pageMatches, !pageMatches.isEmpty else {
            return index < sourcePageCount ? index : nil
        }
        return pageMatches.first {
            $0.revisedPageIndex == index
        }?.sourcePageIndex
    }
}

struct PDFPageMatchLookup: Sendable {
    private static let maximumPageCount = 100_000
    private let revisedBySource: [Int?]
    private let sourceByRevised: [Int?]

    init(review: PDFChangeReview) {
        guard (0...Self.maximumPageCount).contains(
            review.sourcePageCount
        ),
        (0...Self.maximumPageCount).contains(
            review.revisedPageCount
        ) else {
            revisedBySource = []
            sourceByRevised = []
            return
        }

        var revisedBySource = Array<Int?>(
            repeating: nil,
            count: review.sourcePageCount
        )
        var sourceByRevised = Array<Int?>(
            repeating: nil,
            count: review.revisedPageCount
        )
        if let matches = review.pageMatches, !matches.isEmpty {
            for match in matches {
                if let source = match.sourcePageIndex,
                   let revised = match.revisedPageIndex,
                   revisedBySource.indices.contains(source),
                   sourceByRevised.indices.contains(revised),
                   revisedBySource[source] == nil,
                   sourceByRevised[revised] == nil {
                    revisedBySource[source] = revised
                    sourceByRevised[revised] = source
                }
            }
        } else {
            for index in 0..<min(
                review.sourcePageCount,
                review.revisedPageCount
            ) {
                revisedBySource[index] = index
                sourceByRevised[index] = index
            }
        }
        self.revisedBySource = revisedBySource
        self.sourceByRevised = sourceByRevised
    }

    func revisedPage(matchingSourcePage index: Int) -> Int? {
        guard revisedBySource.indices.contains(index) else {
            return nil
        }
        return revisedBySource[index]
    }

    func sourcePage(matchingRevisedPage index: Int) -> Int? {
        guard sourceByRevised.indices.contains(index) else {
            return nil
        }
        return sourceByRevised[index]
    }
}

struct PDFDeliveryReceipt: Codable, Hashable, Identifiable, Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumArtifactBytes: Int64 =
        1_073_741_824
    private static let maximumCheckCount = 64
    private static let maximumCheckIDLength = 64
    private static let maximumCheckTitleLength = 120
    private static let maximumCheckDetailLength = 320
    private static let sha256Characters = CharacterSet(
        charactersIn: "0123456789abcdefABCDEF"
    )

    let id: UUID
    let operation: PDFDeliveryOperation
    let createdAt: Date
    let sourcePageCount: Int
    let outputPageCount: Int
    let renderedPageCount: Int
    let sourceByteCount: Int64
    let outputByteCount: Int64
    let unexpectedBlankPageIndices: [Int]
    let annotationCount: Int
    let textCharacterCount: Int
    let personalMetadataEntryCount: Int
    let isEncrypted: Bool
    let sha256: String
    let checks: [PDFDeliveryCheck]
    var changeReview: PDFChangeReview? = nil
    var sourceRevisionID: UUID? = nil
    var outputRevisionID: UUID? = nil

    var hasWarnings: Bool {
        checks.contains { $0.status == .warning }
    }

    var warningCount: Int {
        checks.filter { $0.status == .warning }.count
    }

    var isVerified: Bool {
        isVerified(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isVerified(at date: Date) -> Bool {
        isStructurallyValid(at: date)
            && !checks.contains { $0.status == .failed }
            && renderedPageCount == outputPageCount
            && hasExpectedPageCount
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let timestamp = createdAt.timeIntervalSince1970
        return timestamp.isFinite
            && timestamp >= 0
            && createdAt <= date.addingTimeInterval(5 * 60)
            && (1...Self.maximumPageCount).contains(sourcePageCount)
            && (1...Self.maximumPageCount).contains(outputPageCount)
            && (0...outputPageCount).contains(renderedPageCount)
            && sourceByteCount > 0
            && sourceByteCount <= Self.maximumArtifactBytes
            && outputByteCount > 0
            && outputByteCount <= Self.maximumArtifactBytes
            && annotationCount >= 0
            && textCharacterCount >= 0
            && personalMetadataEntryCount >= 0
            && hasValidFingerprint
            && !checks.isEmpty
            && checks.count <= Self.maximumCheckCount
            && Set(checks.map(\.id)).count == checks.count
            && checks.allSatisfy(Self.isValidCheck)
            && (
                changeReview.map {
                    $0.sourcePageCount == sourcePageCount
                        && $0.revisedPageCount == outputPageCount
                        && $0.isStructurallyValid()
                } ?? true
            )
            && Set(unexpectedBlankPageIndices).count
                == unexpectedBlankPageIndices.count
            && unexpectedBlankPageIndices.allSatisfy {
                (0..<outputPageCount).contains($0)
            }
            && (
                operation != .protected
                    || isEncrypted
            )
            && (
                operation != .unlocked
                    || !isEncrypted
            )
    }

    private var hasValidFingerprint: Bool {
        sha256.count == 64
            && sha256.unicodeScalars.allSatisfy {
                Self.sha256Characters.contains($0)
            }
    }

    private var hasExpectedPageCount: Bool {
        switch operation {
        case .bookletPrepared:
            return outputPageCount
                == ((sourcePageCount + 3) / 4) * 2
        default:
            return outputPageCount == sourcePageCount
        }
    }

    var isDeliveryOutput: Bool {
        operation != .unlocked
    }

    var outcomeTitle: String {
        guard isVerified else { return "Needs review".localizedUI }
        if operation == .unlocked {
            return "Editable copy ready".localizedUI
        }
        guard warningCount > 0 else {
            return "Ready to share".localizedUI
        }
        return AppLocalization.format(
            "Checked with %lld warning%@",
            warningCount,
            warningCount == 1 ? "" : "s"
        )
    }

    var outcomeDetail: String {
        guard isVerified else {
            return "The final copy did not pass every delivery check."
                .localizedUI
        }
        let pageSummary = renderedPageCount == outputPageCount
            ? AppLocalization.format(
                "PaperPath reopened all %lld page%@",
                outputPageCount,
                outputPageCount == 1 ? "" : "s"
            )
            : AppLocalization.format(
                "PaperPath reopened %lld of %lld pages",
                renderedPageCount,
                outputPageCount
            )
        if operation == .unlocked {
            return AppLocalization.format(
                "%@. The password-free private copy is ready to edit.",
                pageSummary
            )
        }
        if warningCount > 0 {
            return AppLocalization.format(
                "%@. Review %lld warning%@ before sharing.",
                pageSummary,
                warningCount,
                warningCount == 1 ? "" : "s"
            )
        }
        return AppLocalization.format(
            "%@ and checked the final copy.",
            pageSummary
        )
    }

    var formattedOutputSize: String {
        ByteCountFormatter.string(
            fromByteCount: outputByteCount,
            countStyle: .file
        )
    }

    var shortFingerprint: String {
        let prefix = sha256.prefix(12)
        return prefix.enumerated().reduce(into: "") { result, pair in
            if pair.offset > 0, pair.offset.isMultiple(of: 4) {
                result.append(" ")
            }
            result.append(pair.element)
        }
    }

    var milestoneArchiveCopy: PDFDeliveryReceipt {
        PDFDeliveryReceipt(
            id: id,
            operation: operation,
            createdAt: createdAt,
            sourcePageCount: sourcePageCount,
            outputPageCount: outputPageCount,
            renderedPageCount: renderedPageCount,
            sourceByteCount: sourceByteCount,
            outputByteCount: outputByteCount,
            unexpectedBlankPageIndices: unexpectedBlankPageIndices,
            annotationCount: annotationCount,
            textCharacterCount: textCharacterCount,
            personalMetadataEntryCount: personalMetadataEntryCount,
            isEncrypted: isEncrypted,
            sha256: sha256,
            checks: checks,
            changeReview: nil,
            sourceRevisionID: sourceRevisionID,
            outputRevisionID: outputRevisionID
        )
    }

    private static func isValidCheck(
        _ check: PDFDeliveryCheck
    ) -> Bool {
        !check.id.isEmpty
            && check.id.count <= maximumCheckIDLength
            && !check.title.isEmpty
            && check.title.count <= maximumCheckTitleLength
            && !check.detail.isEmpty
            && check.detail.count <= maximumCheckDetailLength
            && isSafeDisplayText(check.id)
            && isSafeDisplayText(check.title)
            && isSafeDisplayText(check.detail)
    }

    private static func isSafeDisplayText(
        _ value: String
    ) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !isBidirectionalControl
        }
    }
}

struct PDFDeliveryPackageManifest:
    Codable,
    Hashable,
    Sendable {
    struct Artifact: Codable, Hashable, Sendable {
        let fileName: String
        let byteCount: Int64
        let pageCount: Int
        let sha256: String
        let contentRevisionID: UUID

        private enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case byteCount = "byte_count"
            case pageCount = "page_count"
            case sha256
            case contentRevisionID = "content_revision_id"
        }
    }

    static let currentSchema = "PaperPath PDF Delivery Package V1"
    static let maximumArtifactBytes: Int64 =
        1_073_741_824
    static let maximumArtifactPageCount = 100_000
    static let maximumCheckCount = 64
    static let maximumCheckIDLength = 64
    static let maximumCheckTitleLength = 120
    static let maximumCheckDetailLength = 320
    static let maximumArtifactFileNameBytes = 255

    let schema: String
    let packageID: UUID
    let createdAt: Date
    let artifact: Artifact
    let deliveryReceiptID: UUID
    let verificationCreatedAt: Date
    let operation: PDFDeliveryOperation
    let sourcePageCount: Int
    let renderedPageCount: Int
    let outputByteCount: Int64
    let warningCount: Int
    let unexpectedBlankPageIndices: [Int]
    let annotationCount: Int
    let textCharacterCount: Int
    let personalMetadataEntryCount: Int
    let isEncrypted: Bool
    let checks: [PDFDeliveryCheck]
    let sourceRevisionID: UUID?
    let outputRevisionID: UUID?

    private enum CodingKeys: String, CodingKey {
        case schema
        case packageID = "package_id"
        case createdAt = "created_at"
        case artifact
        case deliveryReceiptID = "delivery_receipt_id"
        case verificationCreatedAt = "verification_created_at"
        case operation
        case sourcePageCount = "source_page_count"
        case renderedPageCount = "rendered_page_count"
        case outputByteCount = "output_byte_count"
        case warningCount = "warning_count"
        case unexpectedBlankPageIndices =
            "unexpected_blank_page_indices"
        case annotationCount = "annotation_count"
        case textCharacterCount = "text_character_count"
        case personalMetadataEntryCount =
            "personal_metadata_entry_count"
        case isEncrypted = "is_encrypted"
        case checks
        case sourceRevisionID = "source_revision_id"
        case outputRevisionID = "output_revision_id"
    }

    init(
        packageID: UUID = UUID(),
        createdAt: Date =
            PDFOfficeTimeAnchor.process.trustedDate(),
        artifactFileName: String,
        record: DocumentRecord,
        receipt: PDFDeliveryReceipt
    ) {
        schema = Self.currentSchema
        self.packageID = packageID
        self.createdAt = createdAt
        artifact = Artifact(
            fileName: artifactFileName,
            byteCount: receipt.outputByteCount,
            pageCount: receipt.outputPageCount,
            sha256: receipt.sha256.lowercased(),
            contentRevisionID: record.contentRevisionID
        )
        deliveryReceiptID = receipt.id
        verificationCreatedAt = receipt.createdAt
        operation = receipt.operation
        sourcePageCount = receipt.sourcePageCount
        renderedPageCount = receipt.renderedPageCount
        outputByteCount = receipt.outputByteCount
        warningCount = receipt.warningCount
        unexpectedBlankPageIndices =
            receipt.unexpectedBlankPageIndices
        annotationCount = receipt.annotationCount
        textCharacterCount = receipt.textCharacterCount
        personalMetadataEntryCount =
            receipt.personalMetadataEntryCount
        isEncrypted = receipt.isEncrypted
        checks = receipt.checks
        sourceRevisionID = receipt.sourceRevisionID
        outputRevisionID = receipt.outputRevisionID
    }

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        let createdTimestamp = createdAt.timeIntervalSince1970
        let verificationTimestamp =
            verificationCreatedAt.timeIntervalSince1970
        guard sourcePageCount > 0,
              sourcePageCount <= Self.maximumArtifactPageCount,
              createdTimestamp.isFinite,
              verificationTimestamp.isFinite,
              createdTimestamp >= 0,
              verificationTimestamp >= 0,
              createdAt <= date.addingTimeInterval(5 * 60),
              verificationCreatedAt
                <= createdAt.addingTimeInterval(5 * 60)
        else { return false }
        let expectedPageCount: Int
        switch operation {
        case .bookletPrepared:
            expectedPageCount = ((sourcePageCount + 3) / 4) * 2
        default:
            expectedPageCount = sourcePageCount
        }
        return schema == Self.currentSchema
            && artifact.fileName.count >= 5
            && artifact.fileName.count <= 180
            && artifact.fileName.utf8.count
                <= Self.maximumArtifactFileNameBytes
            && artifact.fileName
                == (artifact.fileName as NSString)
                    .lastPathComponent
            && !artifact.fileName.hasPrefix(".")
            && !artifact.fileName.contains("\\")
            && artifact.fileName.lowercased().hasSuffix(".pdf")
            && Self.isSafeDisplayText(artifact.fileName)
            && artifact.byteCount > 0
            && artifact.byteCount <= Self.maximumArtifactBytes
            && artifact.pageCount > 0
            && artifact.pageCount <= Self.maximumArtifactPageCount
            && artifact.pageCount == expectedPageCount
            && artifact.byteCount == outputByteCount
            && artifact.sha256.count == 64
            && artifact.sha256.unicodeScalars.allSatisfy(
                hexadecimal.contains
            )
            && renderedPageCount == artifact.pageCount
            && warningCount
                == checks.filter { $0.status == .warning }.count
            && warningCount >= 0
            && !checks.contains { $0.status == .failed }
            && !checks.isEmpty
            && checks.count <= Self.maximumCheckCount
            && Set(checks.map(\.id)).count == checks.count
            && checks.allSatisfy {
                !$0.id.isEmpty
                    && $0.id.count <= Self.maximumCheckIDLength
                    && Self.isSafeDisplayText($0.id)
                    && !$0.title.isEmpty
                    && $0.title.count <= Self.maximumCheckTitleLength
                    && Self.isSafeDisplayText($0.title)
                    && !$0.detail.isEmpty
                    && $0.detail.count <= Self.maximumCheckDetailLength
                    && Self.isSafeDisplayText($0.detail)
            }
            && Set(unexpectedBlankPageIndices).count
                == unexpectedBlankPageIndices.count
            && unexpectedBlankPageIndices.allSatisfy {
                $0 >= 0 && $0 < artifact.pageCount
            }
            && annotationCount >= 0
            && textCharacterCount >= 0
            && personalMetadataEntryCount >= 0
            && (
                operation != .protected
                    || isEncrypted
            )
            && (
                operation != .unlocked
                    || !isEncrypted
            )
            && (
                outputRevisionID == nil
                    || outputRevisionID
                        == artifact.contentRevisionID
            )
    }

    private static func isSafeDisplayText(
        _ value: String
    ) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !isBidirectionalControl
        }
    }
}

struct PDFSignedDeliveryPackageManifest:
    Codable,
    Hashable,
    Sendable {
    let manifest: PDFDeliveryPackageManifest
    let signature: PDFOfficeVerificationSignature
}

enum PDFDeliveryPackageVerificationFailureKind:
    Hashable,
    Sendable {
    case access
    case integrity
    case sourceLimit
    case storage
    case unknown
}

struct PDFDeliveryPackageVerificationFailure:
    Identifiable,
    Hashable,
    Sendable {
    let id: UUID
    let kind: PDFDeliveryPackageVerificationFailureKind
    let detail: String

    init(
        id: UUID = UUID(),
        kind: PDFDeliveryPackageVerificationFailureKind,
        detail: String
    ) {
        self.id = id
        self.kind = kind
        self.detail = detail
    }

    var title: String {
        switch kind {
        case .access:
            return "Package Unavailable"
        case .integrity:
            return "Package Could Not Be Verified"
        case .sourceLimit:
            return "Package Too Large"
        case .storage:
            return "Free Space Needed"
        case .unknown:
            return "Couldn’t Verify Package"
        }
    }

    var offersStorageRecovery: Bool {
        kind == .storage
    }
}

struct PDFDeliveryPackageVerificationReport:
    Identifiable,
    Hashable,
    Sendable {
    let id: UUID
    let archiveName: String
    let archiveByteCount: Int64
    let packageID: UUID
    let packageCreatedAt: Date
    let verifiedAt: Date
    let artifactFileName: String
    let artifactByteCount: Int64
    let artifactPageCount: Int
    let isEncrypted: Bool
    let operation: PDFDeliveryOperation
    let deliveryReceiptID: UUID
    let expectedSHA256: String
    let actualSHA256: String?
    let checks: [PDFDeliveryCheck]
    let integrityFailures: [String]
    let signatureStatus: PDFOfficeReportVerificationStatus
    let signatureDetail: String
    let signerKeyID: String?
    let signerPublicKeyBase64: String?
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let verifiedArtifactURL: URL?

    init(
        id: UUID = UUID(),
        archiveName: String,
        archiveByteCount: Int64,
        packageID: UUID,
        packageCreatedAt: Date,
        verifiedAt: Date,
        artifactFileName: String,
        artifactByteCount: Int64,
        artifactPageCount: Int,
        isEncrypted: Bool,
        operation: PDFDeliveryOperation,
        deliveryReceiptID: UUID,
        expectedSHA256: String,
        actualSHA256: String?,
        checks: [PDFDeliveryCheck],
        integrityFailures: [String],
        signatureStatus: PDFOfficeReportVerificationStatus,
        signatureDetail: String,
        signerKeyID: String?,
        signerPublicKeyBase64: String?,
        trustStatus: PDFOfficeSignerTrustStatus,
        trustedSignerName: String?,
        verifiedArtifactURL: URL? = nil
    ) {
        self.id = id
        self.archiveName = archiveName
        self.archiveByteCount = archiveByteCount
        self.packageID = packageID
        self.packageCreatedAt = packageCreatedAt
        self.verifiedAt = verifiedAt
        self.artifactFileName = artifactFileName
        self.artifactByteCount = artifactByteCount
        self.artifactPageCount = artifactPageCount
        self.isEncrypted = isEncrypted
        self.operation = operation
        self.deliveryReceiptID = deliveryReceiptID
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.checks = checks
        self.integrityFailures = integrityFailures
        self.signatureStatus = signatureStatus
        self.signatureDetail = signatureDetail
        self.signerKeyID = signerKeyID
        self.signerPublicKeyBase64 = signerPublicKeyBase64
        self.trustStatus = trustStatus
        self.trustedSignerName = trustedSignerName
        self.verifiedArtifactURL = verifiedArtifactURL
    }

    var integrityStatus: PDFVersionArchiveVerificationStatus {
        integrityFailures.isEmpty ? .verified : .failed
    }

    var status: PDFVersionArchiveVerificationStatus {
        integrityStatus == .verified && signatureStatus == .verified
            ? .verified
            : .failed
    }

    var warningCount: Int {
        checks.filter { $0.status == .warning }.count
    }

    var formattedArchiveSize: String {
        ByteCountFormatter.string(
            fromByteCount: archiveByteCount,
            countStyle: .file
        )
    }

    var formattedArtifactSize: String {
        ByteCountFormatter.string(
            fromByteCount: artifactByteCount,
            countStyle: .file
        )
    }

    var hasValidSourceSignature: Bool {
        signatureStatus == .verified
    }

    var hasInvalidSourceSignature: Bool {
        signatureStatus == .invalid
    }

    var canTrustSigner: Bool {
        status == .verified
            && trustStatus == .unknown
            && signerKeyID != nil
            && signerPublicKeyBase64 != nil
    }

    var canOpenArtifact: Bool {
        status == .verified && verifiedArtifactURL != nil
    }

    var canPreviewArtifact: Bool {
        canOpenArtifact && !isEncrypted
    }

    var provenanceTitle: String {
        if hasInvalidSourceSignature {
            return "Invalid source signature"
        }
        return trustedSignerName ?? trustStatus.title
    }

    func resolvingTrust(
        _ trustStatus: PDFOfficeSignerTrustStatus,
        trustedSignerName: String?
    ) -> PDFDeliveryPackageVerificationReport {
        PDFDeliveryPackageVerificationReport(
            id: id,
            archiveName: archiveName,
            archiveByteCount: archiveByteCount,
            packageID: packageID,
            packageCreatedAt: packageCreatedAt,
            verifiedAt: verifiedAt,
            artifactFileName: artifactFileName,
            artifactByteCount: artifactByteCount,
            artifactPageCount: artifactPageCount,
            isEncrypted: isEncrypted,
            operation: operation,
            deliveryReceiptID: deliveryReceiptID,
            expectedSHA256: expectedSHA256,
            actualSHA256: actualSHA256,
            checks: checks,
            integrityFailures: integrityFailures,
            signatureStatus: signatureStatus,
            signatureDetail: signatureDetail,
            signerKeyID: signerKeyID,
            signerPublicKeyBase64: signerPublicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            verifiedArtifactURL: verifiedArtifactURL
        )
    }
}

struct PDFReceivedPackageProvenance:
    Codable,
    Hashable,
    Sendable {
    let packageID: UUID
    let deliveryReceiptID: UUID
    let packageCreatedAt: Date
    let verifiedAt: Date
    let importedAt: Date
    let operation: PDFDeliveryOperation
    let artifactSHA256: String
    let artifactByteCount: Int64
    let signerKeyID: String?
    let signerTrustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?

    init(
        report: PDFDeliveryPackageVerificationReport,
        importedAt: Date = Date()
    ) {
        packageID = report.packageID
        deliveryReceiptID = report.deliveryReceiptID
        packageCreatedAt = report.packageCreatedAt
        verifiedAt = report.verifiedAt
        self.importedAt = importedAt
        operation = report.operation
        artifactSHA256 = report.expectedSHA256.lowercased()
        artifactByteCount = report.artifactByteCount
        signerKeyID = report.signerKeyID
        signerTrustStatus = report.trustStatus
        trustedSignerName = report.trustedSignerName
    }

    func matchesCurrentBytes(
        fingerprint: String?,
        byteCount: Int64
    ) -> Bool {
        guard let fingerprint,
              Self.isSHA256(artifactSHA256),
              Self.isSHA256(fingerprint),
              artifactByteCount > 0,
              byteCount == artifactByteCount
        else { return false }
        return fingerprint.caseInsensitiveCompare(artifactSHA256)
            == .orderedSame
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    var sourceTitle: String {
        switch signerTrustStatus {
        case .thisDevice:
            return "Verified on this device"
        case .trusted:
            return trustedSignerName ?? "Trusted signer"
        case .unknown:
            return "Unknown signer"
        case .invalid:
            return "Invalid source"
        case .unsupported:
            return "Unsupported source"
        }
    }

    var formattedArtifactSize: String {
        ByteCountFormatter.string(
            fromByteCount: artifactByteCount,
            countStyle: .file
        )
    }
}

struct DocumentRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    let fileName: String
    let importedAt: Date
    var modifiedAt: Date
    var contentRevisionID: UUID
    var profile: DocumentProfile
    var workflowStatus: DocumentWorkflowStatus
    var isPinned: Bool
    var tags: [String]
    var bookmarkedPages: [Int]
    var lastPageIndex: Int
    var lastViewedAt: Date?
    var completedActions: Set<DocumentAction>
    var taskCheckpoint: DocumentTaskCheckpoint?
    var brief: DocumentBrief?
    var deliveryReceipt: PDFDeliveryReceipt?
    var officeReceipts: [PDFOfficeExportReceipt]
    var officeBatchRun: PDFOfficeBatchRun?
    let sourceDocumentID: UUID?
    var sourceBookmarkData: Data?
    var sourceLocationName: String?
    var sourceImportedFingerprint: String?
    // Legacy archive metadata; current workflows never replace source files.
    var sourceWritebackAt: Date?
    var contentFingerprint: String?
    var deletedAt: Date?
    var dueAt: Date?
    var privateNote: String?
    var bookmarkNames: [Int: String]
    var receivedPackageProvenance: PDFReceivedPackageProvenance?
    var sharedImportID: UUID?

    init(
        id: UUID = UUID(),
        displayName: String,
        fileName: String,
        importedAt: Date = Date(),
        modifiedAt: Date = Date(),
        contentRevisionID: UUID = UUID(),
        profile: DocumentProfile,
        workflowStatus: DocumentWorkflowStatus = .inbox,
        isPinned: Bool = false,
        tags: [String] = [],
        bookmarkedPages: [Int] = [],
        lastPageIndex: Int = 0,
        lastViewedAt: Date? = nil,
        completedActions: Set<DocumentAction> = [],
        taskCheckpoint: DocumentTaskCheckpoint? = nil,
        brief: DocumentBrief? = nil,
        deliveryReceipt: PDFDeliveryReceipt? = nil,
        officeReceipts: [PDFOfficeExportReceipt] = [],
        officeBatchRun: PDFOfficeBatchRun? = nil,
        sourceDocumentID: UUID? = nil,
        sourceBookmarkData: Data? = nil,
        sourceLocationName: String? = nil,
        sourceImportedFingerprint: String? = nil,
        sourceWritebackAt: Date? = nil,
        contentFingerprint: String? = nil,
        deletedAt: Date? = nil,
        dueAt: Date? = nil,
        privateNote: String? = nil,
        bookmarkNames: [Int: String] = [:],
        receivedPackageProvenance:
            PDFReceivedPackageProvenance? = nil,
        sharedImportID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.importedAt = importedAt
        self.modifiedAt = modifiedAt
        self.contentRevisionID = contentRevisionID
        self.profile = profile
        self.workflowStatus = workflowStatus
        self.isPinned = isPinned
        self.tags = tags
        self.bookmarkedPages = bookmarkedPages
        self.lastPageIndex = min(
            max(lastPageIndex, 0),
            max(0, profile.pageCount - 1)
        )
        self.lastViewedAt = lastViewedAt
        self.completedActions = completedActions
        self.taskCheckpoint = taskCheckpoint?.bounded(
            toPageCount: profile.pageCount
        )
        self.brief = brief
        self.deliveryReceipt = deliveryReceipt
        self.officeReceipts = boundedOfficeReceipts(
            officeReceipts
        )
        self.officeBatchRun = officeBatchRun
        self.sourceDocumentID = sourceDocumentID
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceLocationName = sourceLocationName
        self.sourceImportedFingerprint = sourceImportedFingerprint
        self.sourceWritebackAt = sourceWritebackAt
        self.contentFingerprint = contentFingerprint
        self.deletedAt = deletedAt
        self.dueAt = dueAt
        self.privateNote = privateNote
        self.bookmarkNames = bookmarkNames
        self.receivedPackageProvenance =
            receivedPackageProvenance
        self.sharedImportID = sharedImportID
    }

    var subtitle: String {
        AppLocalization.format(
            "%lld page%@ · %@",
            profile.pageCount,
            profile.pageCount == 1 ? "" : "s",
            profile.formattedSize
        )
    }

    var hasCurrentDeliveryReceipt: Bool {
        guard let receipt = deliveryReceipt,
              receipt.isVerified,
              let contentFingerprint,
              receipt.outputPageCount == profile.pageCount,
              receipt.outputByteCount == profile.byteCount,
              contentFingerprint.caseInsensitiveCompare(receipt.sha256)
                == .orderedSame
        else { return false }
        guard let outputRevisionID = receipt.outputRevisionID else {
            return true
        }
        return outputRevisionID == contentRevisionID
    }

    var isDeliveryArtifact: Bool {
        sourceDocumentID != nil
            && deliveryReceipt?.isDeliveryOutput == true
    }

    var isWorkingCopy: Bool {
        !isDeliveryArtifact
    }

    var hasCurrentReceivedPackageProvenance: Bool {
        receivedPackageProvenance?.matchesCurrentBytes(
            fingerprint: contentFingerprint,
            byteCount: profile.byteCount
        ) == true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileName
        case importedAt
        case modifiedAt
        case contentRevisionID
        case profile
        case workflowStatus
        case isPinned
        case tags
        case bookmarkedPages
        case lastPageIndex
        case lastViewedAt
        case completedActions
        case taskCheckpoint
        case brief
        case deliveryReceipt
        case officeReceipts
        case officeBatchRun
        case sourceDocumentID
        case sourceBookmarkData
        case sourceLocationName
        case sourceImportedFingerprint
        case sourceWritebackAt
        case contentFingerprint
        case deletedAt
        case dueAt
        case privateNote
        case bookmarkNames
        case receivedPackageProvenance
        case sharedImportID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        fileName = try container.decode(String.self, forKey: .fileName)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        contentRevisionID = try container.decodeIfPresent(
            UUID.self,
            forKey: .contentRevisionID
        ) ?? id
        profile = try container.decode(DocumentProfile.self, forKey: .profile)
        workflowStatus = try container.decodeIfPresent(
            DocumentWorkflowStatus.self,
            forKey: .workflowStatus
        ) ?? .inbox
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        bookmarkedPages = try container.decodeIfPresent(
            [Int].self,
            forKey: .bookmarkedPages
        ) ?? []
        lastPageIndex = min(
            max(
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .lastPageIndex
                ) ?? 0,
                0
            ),
            max(0, profile.pageCount - 1)
        )
        lastViewedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastViewedAt
        )
        completedActions = try container.decodeIfPresent(
            Set<DocumentAction>.self,
            forKey: .completedActions
        ) ?? []
        taskCheckpoint = try container.decodeIfPresent(
            DocumentTaskCheckpoint.self,
            forKey: .taskCheckpoint
        )?.bounded(toPageCount: profile.pageCount)
        brief = try container.decodeIfPresent(DocumentBrief.self, forKey: .brief)
        deliveryReceipt = try container.decodeIfPresent(
            PDFDeliveryReceipt.self,
            forKey: .deliveryReceipt
        )
        officeReceipts = boundedOfficeReceipts(
            try container.decodeIfPresent(
                [PDFOfficeExportReceipt].self,
                forKey: .officeReceipts
            ) ?? []
        )
        officeBatchRun = try container.decodeIfPresent(
            PDFOfficeBatchRun.self,
            forKey: .officeBatchRun
        )
        sourceDocumentID = try container.decodeIfPresent(
            UUID.self,
            forKey: .sourceDocumentID
        )
        sourceBookmarkData = try container.decodeIfPresent(
            Data.self,
            forKey: .sourceBookmarkData
        )
        sourceLocationName = try container.decodeIfPresent(
            String.self,
            forKey: .sourceLocationName
        )
        sourceImportedFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .sourceImportedFingerprint
        )
        sourceWritebackAt = try container.decodeIfPresent(
            Date.self,
            forKey: .sourceWritebackAt
        )
        contentFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .contentFingerprint
        )
        deletedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .deletedAt
        )
        dueAt = try container.decodeIfPresent(
            Date.self,
            forKey: .dueAt
        )
        privateNote = try container.decodeIfPresent(
            String.self,
            forKey: .privateNote
        )
        bookmarkNames = try container.decodeIfPresent(
            [Int: String].self,
            forKey: .bookmarkNames
        ) ?? [:]
        receivedPackageProvenance = try container.decodeIfPresent(
            PDFReceivedPackageProvenance.self,
            forKey: .receivedPackageProvenance
        )
        sharedImportID = try container.decodeIfPresent(
            UUID.self,
            forKey: .sharedImportID
        )
    }
}

enum DocumentComparisonCandidates {
    static func ordered(
        from records: [DocumentRecord],
        sourceID: UUID
    ) -> [DocumentRecord] {
        let source = records.first { $0.id == sourceID }
        return records
            .filter {
                $0.id != sourceID && !$0.profile.isLocked
            }
            .sorted {
                precedes($0, $1, source: source)
            }
    }

    private static func precedes(
        _ lhs: DocumentRecord,
        _ rhs: DocumentRecord,
        source: DocumentRecord?
    ) -> Bool {
        let lhsRelationship = relationshipRank(lhs, source: source)
        let rhsRelationship = relationshipRank(rhs, source: source)
        if lhsRelationship != rhsRelationship {
            return lhsRelationship > rhsRelationship
        }

        switch (lhs.lastViewedAt, rhs.lastViewedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let nameOrder = lhs.displayName.localizedStandardCompare(
            rhs.displayName
        )
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func relationshipRank(
        _ candidate: DocumentRecord,
        source: DocumentRecord?
    ) -> Int {
        guard let source else { return 0 }
        if candidate.sourceDocumentID == source.id
            || source.sourceDocumentID == candidate.id {
            return 2
        }
        guard let sourceParentID = source.sourceDocumentID,
              candidate.sourceDocumentID == sourceParentID
        else { return 0 }
        return 1
    }
}

enum DocumentCommandReadiness: String, Hashable {
    case ready
    case review
    case blocked

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .review: return "Review"
        case .blocked: return "Blocked"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.seal.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }
}

enum DocumentTextAvailability: Hashable {
    case locked, recognized, imageOnly, partial, available

    init(isLocked: Bool, hasRecognizedText: Bool, textCoverage: Double, imagePageCount: Int) {
        if isLocked {
            self = .locked
        } else if hasRecognizedText {
            self = .recognized
        } else if !textCoverage.isFinite || textCoverage <= 0 {
            self = .imageOnly
        } else if imagePageCount > 0 || textCoverage < 0.6 {
            self = .partial
        } else {
            self = .available
        }
    }

    var needsRecognition: Bool { self == .imageOnly || self == .partial }

    var title: String {
        switch self {
        case .locked: return "Unlock to inspect text"
        case .recognized: return "Recognized text saved"
        case .imageOnly: return "Recognition needed"
        case .partial: return "Some pages need recognition"
        case .available: return "Text available"
        }
    }

    var detail: String {
        switch self {
        case .locked: return "The PDF is locked."
        case .recognized: return "Review saved text before creating a searchable copy."
        case .imageOnly: return "This PDF has no detected text layer."
        case .partial: return "Image pages may not appear in text searches."
        case .available: return "Detected text can be searched and selected."
        }
    }
}

struct DocumentCommandSignal: Identifiable, Hashable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let readiness: DocumentCommandReadiness
}

struct DocumentCommandProfile: Hashable {
    let readiness: DocumentCommandReadiness
    let score: Int
    let primaryTitle: String
    let primaryDetail: String
    let primarySymbol: String
    let officeRoute: String
    let officeDetail: String
    let signals: [DocumentCommandSignal]

    var scoreLabel: String {
        "\(score)"
    }

    var compactLine: String {
        "\(readiness.title) \(score) · \(officeRoute)"
    }
}

struct LibraryCommandSummary: Hashable {
    let readiness: DocumentCommandReadiness
    let score: Int
    let totalCount: Int
    let readyCount: Int
    let attentionCount: Int
    let verifiedCount: Int
    let staleReceiptCount: Int
    let officeReviewCount: Int
    let lockedCount: Int
    let scansNeedingOCRCount: Int
    let dueNowCount: Int
    let batchEligibleCount: Int

    var headline: String {
        if totalCount == 0 {
            return "Private workspace ready"
        }
        if staleReceiptCount > 0 {
            return "Re-verify changed outputs"
        }
        if attentionCount > 0 {
            return "Review active evidence"
        }
        return "Workspace ready to deliver"
    }

    var detail: String {
        if totalCount == 0 {
            return "Import, scan, or create a local paper PDF."
        }
        return AppLocalization.format(
            "%lld ready · %lld verified · %lld review",
            readyCount,
            verifiedCount,
            attentionCount
        )
    }
}

struct PDFVersionSnapshot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let documentID: UUID
    let createdAt: Date
    let label: String
    let fileName: String
    let byteCount: Int64
    let pageCount: Int
    let contentRevisionID: UUID
    let contentFingerprint: String
    let bookmarkedPages: [Int]
    let bookmarkNames: [Int: String]
    let lastPageIndex: Int
    let milestoneName: String?
    let isPinned: Bool?
    let linkedDeliveryReceiptID: UUID?
    let linkedDeliveryReceipt: PDFDeliveryReceipt?

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var resolvedMilestoneName: String? {
        guard let value = milestoneName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    var isPinnedMilestone: Bool {
        isPinned == true
    }

    var archivedDeliveryReceipt: PDFDeliveryReceipt? {
        guard isPinnedMilestone,
              let linkedDeliveryReceiptID,
              let linkedDeliveryReceipt,
              linkedDeliveryReceipt.id == linkedDeliveryReceiptID,
              matchesDeliveryReceipt(linkedDeliveryReceipt)
        else { return nil }
        return linkedDeliveryReceipt
    }

    var displayTitle: String {
        resolvedMilestoneName
            ?? AppLocalization.format(
                "Before %@",
                label.localizedUI
            )
    }

    func matchesDeliveryReceipt(
        _ receipt: PDFDeliveryReceipt
    ) -> Bool {
        guard receipt.isVerified,
              receipt.outputPageCount == pageCount,
              receipt.outputByteCount == byteCount,
              Self.isSHA256(contentFingerprint),
              contentFingerprint.caseInsensitiveCompare(receipt.sha256)
                == .orderedSame
        else { return false }
        guard let outputRevisionID = receipt.outputRevisionID else {
            return true
        }
        return outputRevisionID == contentRevisionID
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    func updatingMilestone(
        name: String?,
        pinned: Bool,
        linkedDeliveryReceiptID: UUID?,
        deliveryReceipt: PDFDeliveryReceipt? = nil
    ) -> PDFVersionSnapshot {
        let normalizedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReceipt: PDFDeliveryReceipt? =
            if let deliveryReceipt,
               deliveryReceipt.id == linkedDeliveryReceiptID,
               matchesDeliveryReceipt(deliveryReceipt) {
            deliveryReceipt
        } else if let linkedDeliveryReceipt,
                  linkedDeliveryReceipt.id
                    == linkedDeliveryReceiptID,
                  matchesDeliveryReceipt(linkedDeliveryReceipt) {
            linkedDeliveryReceipt
        } else {
            nil
        }
        return PDFVersionSnapshot(
            id: id,
            documentID: documentID,
            createdAt: createdAt,
            label: label,
            fileName: fileName,
            byteCount: byteCount,
            pageCount: pageCount,
            contentRevisionID: contentRevisionID,
            contentFingerprint: contentFingerprint,
            bookmarkedPages: bookmarkedPages,
            bookmarkNames: bookmarkNames,
            lastPageIndex: lastPageIndex,
            milestoneName: normalizedName.flatMap {
                $0.isEmpty ? nil : String($0.prefix(80))
            },
            isPinned: pinned ? true : nil,
            linkedDeliveryReceiptID: pinned
                ? linkedDeliveryReceiptID
                : nil,
            linkedDeliveryReceipt: pinned
                ? resolvedReceipt
                : nil
        )
    }

    func updatingMeasuredByteCount(
        _ measuredByteCount: Int64
    ) -> PDFVersionSnapshot {
        PDFVersionSnapshot(
            id: id,
            documentID: documentID,
            createdAt: createdAt,
            label: label,
            fileName: fileName,
            byteCount: max(0, measuredByteCount),
            pageCount: pageCount,
            contentRevisionID: contentRevisionID,
            contentFingerprint: contentFingerprint,
            bookmarkedPages: bookmarkedPages,
            bookmarkNames: bookmarkNames,
            lastPageIndex: lastPageIndex,
            milestoneName: milestoneName,
            isPinned: isPinned,
            linkedDeliveryReceiptID: linkedDeliveryReceiptID,
            linkedDeliveryReceipt: linkedDeliveryReceipt
        )
    }
}

enum PDFDeliveryMilestoneAvailability:
    String,
    Hashable,
    Sendable {
    case linked
    case protectCurrent
    case protectRecovery
    case unavailable
}

struct PDFDeliveryMilestoneEvidence: Hashable, Sendable {
    static let unavailable = PDFDeliveryMilestoneEvidence(
        availability: .unavailable,
        linkedMilestones: [],
        matchingUnlinkedMilestone: nil,
        pinnedStorageSummary: .empty
    )

    let availability: PDFDeliveryMilestoneAvailability
    let linkedMilestones: [PDFVersionSnapshot]
    let matchingUnlinkedMilestone: PDFVersionSnapshot?
    let pinnedStorageSummary: PDFPinnedVersionStorageSummary
}

struct PDFVersionStorageHealth: Hashable, Sendable {
    static let empty = PDFVersionStorageHealth(
        indexedVersionCount: 0,
        pinnedMilestoneCount: 0,
        removedIndexEntryCount: 0,
        removedOrphanFileCount: 0,
        repairedMetadataCount: 0,
        reclaimedByteCount: 0
    )

    let indexedVersionCount: Int
    let pinnedMilestoneCount: Int
    let removedIndexEntryCount: Int
    let removedOrphanFileCount: Int
    let repairedMetadataCount: Int
    let reclaimedByteCount: Int64

    var repairedItemCount: Int {
        removedIndexEntryCount
            + removedOrphanFileCount
            + repairedMetadataCount
    }

    var didRepairStorage: Bool {
        repairedItemCount > 0
    }

    var formattedReclaimedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: reclaimedByteCount,
            countStyle: .file
        )
    }
}

struct LocalStorageSnapshot: Hashable, Sendable {
    let pdfBytes: Int64
    let versionBytes: Int64
    let textIndexBytes: Int64
    let ocrBytes: Int64
    let deliveryCacheBytes: Int64
    let officeExportBytes: Int64
    let officeDeliveryBytes: Int64
    let changeReportBytes: Int64
    let metadataBytes: Int64
    var versionStorageHealth = PDFVersionStorageHealth.empty
    var pageMatchStorage = PDFManualPageMatchStorageSummary.empty

    var totalBytes: Int64 {
        [
            pdfBytes,
            versionBytes,
            textIndexBytes,
            ocrBytes,
            deliveryCacheBytes,
            officeExportBytes,
            officeDeliveryBytes,
            changeReportBytes,
            metadataBytes
        ].reduce(Int64.zero) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(
                max(0, value)
            )
            return overflow ? .max : sum
        }
    }
}

struct PDFPinnedOfficeOutput: Identifiable, Hashable, Sendable {
    let recordID: UUID
    let documentName: String
    let receipt: PDFOfficeExportReceipt

    var id: UUID { receipt.id }
}

struct PDFPinnedVersionStorageSummary: Hashable, Sendable {
    static let maximumMilestoneCount = 32
    static let maximumByteCount: Int64 = 1_024 * 1_024 * 1_024

    static let empty = PDFPinnedVersionStorageSummary(
        milestoneCount: 0,
        byteCount: 0
    )

    let milestoneCount: Int
    let byteCount: Int64

    static func measuring<S: Sequence>(
        _ milestones: S
    ) -> PDFPinnedVersionStorageSummary
    where S.Element == PDFVersionSnapshot {
        var count = 0
        var totalBytes: Int64 = 0
        for milestone in milestones {
            count += 1
            let (sum, overflow) = totalBytes.addingReportingOverflow(
                max(0, milestone.byteCount)
            )
            totalBytes = overflow ? .max : sum
        }
        return PDFPinnedVersionStorageSummary(
            milestoneCount: count,
            byteCount: totalBytes
        )
    }

    var formattedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var countContract: String {
        "\(milestoneCount)/\(Self.maximumMilestoneCount)"
    }

    var byteContract: String {
        AppLocalization.format(
            "%@ / %@",
            formattedBytes,
            ByteCountFormatter.string(
                fromByteCount: Self.maximumByteCount,
                countStyle: .file
            )
        )
    }

    var usageFraction: Double {
        guard Self.maximumByteCount > 0 else { return 0 }
        return min(
            1,
            Double(max(0, byteCount))
                / Double(Self.maximumByteCount)
        )
    }

    var countUsageFraction: Double {
        guard Self.maximumMilestoneCount > 0 else { return 0 }
        return min(
            1,
            Double(max(0, milestoneCount))
                / Double(Self.maximumMilestoneCount)
        )
    }

    var pressureFraction: Double {
        max(usageFraction, countUsageFraction)
    }

    var remainingMilestoneCount: Int {
        max(0, Self.maximumMilestoneCount - milestoneCount)
    }

    var remainingByteCount: Int64 {
        max(0, Self.maximumByteCount - max(0, byteCount))
    }

    var formattedRemainingBytes: String {
        ByteCountFormatter.string(
            fromByteCount: remainingByteCount,
            countStyle: .file
        )
    }

    var isCountAtCapacity: Bool {
        milestoneCount >= Self.maximumMilestoneCount
    }

    var isByteAtCapacity: Bool {
        byteCount >= Self.maximumByteCount
    }

    var isCountNearCapacity: Bool {
        milestoneCount >= Self.maximumMilestoneCount - 4
    }

    var isByteNearCapacity: Bool {
        usageFraction >= 0.8
    }

    var isAtCapacity: Bool {
        isCountAtCapacity || isByteAtCapacity
    }

    var isNearCapacity: Bool {
        isCountNearCapacity || isByteNearCapacity
    }

    func canAdd(bytes: Int64) -> Bool {
        let (combinedBytes, overflow) = max(0, byteCount)
            .addingReportingOverflow(max(0, bytes))
        return milestoneCount < Self.maximumMilestoneCount
            && !overflow
            && combinedBytes <= Self.maximumByteCount
    }
}

struct PDFVersionArchiveManifest: Codable, Hashable, Sendable {
    static let currentSchema = "PaperPath Version Archive V49"
    static let supportedSchemas = [
        "PaperPath Version Archive V47",
        "PaperPath Version Archive V48",
        currentSchema
    ]
    static let maximumEntryCount =
        PDFPinnedVersionStorageSummary.maximumMilestoneCount
    static let maximumEntryByteCount =
        PDFPinnedVersionStorageSummary.maximumByteCount
    static let maximumPageCount = 100_000
    static let maximumTitleCharacters = 160
    static let maximumFileNameBytes = 255

    struct Entry: Codable, Hashable, Sendable {
        let fileName: String
        let documentID: UUID
        let snapshotID: UUID
        let title: String
        let createdAt: Date
        let byteCount: Int64
        let pageCount: Int
        let sha256: String
        let linkedDeliveryReceiptID: UUID?
    }

    let schema: String
    let createdAt: Date
    let entries: [Entry]

    var isStructurallyValid: Bool {
        isStructurallyValid(
            at: PDFOfficeTimeAnchor.process.trustedDate()
        )
    }

    func isStructurallyValid(at date: Date) -> Bool {
        guard Self.supportedSchemas.contains(schema),
              createdAt.timeIntervalSince1970 >= 0,
              createdAt <= date.addingTimeInterval(5 * 60),
              !entries.isEmpty,
              entries.count <= Self.maximumEntryCount
        else { return false }

        var names: Set<String> = []
        var snapshotIDs: Set<UUID> = []
        var totalBytes: Int64 = 0
        for entry in entries {
            let normalizedName = entry.fileName.lowercased()
            let (nextTotal, overflow) = totalBytes
                .addingReportingOverflow(entry.byteCount)
            guard Self.isSafeArchiveFileName(entry.fileName),
                  names.insert(normalizedName).inserted,
                  snapshotIDs.insert(entry.snapshotID).inserted,
                  Self.isSafeDisplayText(entry.title),
                  entry.title.count <= Self.maximumTitleCharacters,
                  entry.createdAt.timeIntervalSince1970 >= 0,
                  entry.createdAt
                    <= createdAt.addingTimeInterval(5 * 60),
                  entry.byteCount > 0,
                  entry.byteCount <= Self.maximumEntryByteCount,
                  !overflow,
                  nextTotal <= Self.maximumEntryByteCount,
                  (1...Self.maximumPageCount).contains(
                    entry.pageCount
                  ),
                  Self.isSHA256(entry.sha256)
            else { return false }
            totalBytes = nextTotal
        }
        return true
    }

    private static func isSafeArchiveFileName(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && !value.hasPrefix(".")
            && !value.contains("/")
            && !value.contains("\\")
            && value.utf8.count <= maximumFileNameBytes
            && value.lowercased().hasSuffix(".pdf")
            && isSafeDisplayText(value)
    }

    private static func isSafeDisplayText(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { scalar in
                let codePoint = scalar.value
                let isBidirectionalControl =
                    codePoint == 0x061C
                    || codePoint == 0x200E
                    || codePoint == 0x200F
                    || (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
                return !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.illegalCharacters.contains(scalar)
                    && !isBidirectionalControl
            }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }
}

struct PDFSignedVersionArchiveManifest:
    Codable,
    Hashable,
    Sendable {
    let manifest: PDFVersionArchiveManifest
    let signature: PDFOfficeVerificationSignature
}

enum PDFVersionArchiveVerificationStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case verified
    case failed

    var title: String {
        switch self {
        case .verified: return "Verified"
        case .failed: return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

struct PDFVersionArchiveVerificationItem:
    Identifiable,
    Hashable,
    Sendable {
    let id: UUID
    let documentID: UUID
    let fileName: String
    let title: String
    let byteCount: Int64
    let pageCount: Int
    let expectedSHA256: String
    let actualSHA256: String?
    let linkedDeliveryReceiptID: UUID?
    let status: PDFVersionArchiveVerificationStatus
    let detail: String

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

struct PDFVersionArchiveVerifiedArtifact:
    Identifiable,
    Hashable,
    Sendable {
    let item: PDFVersionArchiveVerificationItem
    let url: URL

    var id: UUID { item.id }
}

struct PDFVersionArchiveVerificationReport:
    Identifiable,
    Hashable,
    Sendable {
    let id: UUID
    let archiveName: String
    let archiveByteCount: Int64
    let schema: String
    let archiveCreatedAt: Date
    let verifiedAt: Date
    let manifestEntryCount: Int
    let archiveEntryCount: Int
    let items: [PDFVersionArchiveVerificationItem]
    let structuralFailures: [String]
    let signatureStatus: PDFOfficeReportVerificationStatus
    let signatureDetail: String
    let signerKeyID: String?
    let signerPublicKeyBase64: String?
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let verifiedArtifacts: [PDFVersionArchiveVerifiedArtifact]

    init(
        id: UUID = UUID(),
        archiveName: String,
        archiveByteCount: Int64,
        schema: String,
        archiveCreatedAt: Date,
        verifiedAt: Date,
        manifestEntryCount: Int,
        archiveEntryCount: Int,
        items: [PDFVersionArchiveVerificationItem],
        structuralFailures: [String],
        signatureStatus: PDFOfficeReportVerificationStatus =
            .unsupported,
        signatureDetail: String =
            "This legacy archive has no PaperPath source signature.",
        signerKeyID: String? = nil,
        signerPublicKeyBase64: String? = nil,
        trustStatus: PDFOfficeSignerTrustStatus = .unsupported,
        trustedSignerName: String? = nil,
        verifiedArtifacts: [PDFVersionArchiveVerifiedArtifact] = []
    ) {
        self.id = id
        self.archiveName = archiveName
        self.archiveByteCount = archiveByteCount
        self.schema = schema
        self.archiveCreatedAt = archiveCreatedAt
        self.verifiedAt = verifiedAt
        self.manifestEntryCount = manifestEntryCount
        self.archiveEntryCount = archiveEntryCount
        self.items = items
        self.structuralFailures = structuralFailures
        self.signatureStatus = signatureStatus
        self.signatureDetail = signatureDetail
        self.signerKeyID = signerKeyID
        self.signerPublicKeyBase64 = signerPublicKeyBase64
        self.trustStatus = trustStatus
        self.trustedSignerName = trustedSignerName
        self.verifiedArtifacts = verifiedArtifacts
    }

    var verifiedCount: Int {
        items.filter { $0.status == .verified }.count
    }

    var signatureFailureCount: Int {
        signatureStatus == .invalid ? 1 : 0
    }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
            + structuralFailures.count
            + signatureFailureCount
    }

    var status: PDFVersionArchiveVerificationStatus {
        failedCount == 0 && verifiedCount == manifestEntryCount
            ? .verified
            : .failed
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: archiveByteCount,
            countStyle: .file
        )
    }

    var hasValidSourceSignature: Bool {
        signatureStatus == .verified
    }

    var hasInvalidSourceSignature: Bool {
        signatureStatus == .invalid
    }

    var isLegacyUnsigned: Bool {
        signatureStatus == .unsupported
            && signerKeyID == nil
    }

    var canTrustSigner: Bool {
        status == .verified
            && hasValidSourceSignature
            && trustStatus == .unknown
            && signerKeyID != nil
            && signerPublicKeyBase64 != nil
    }

    var canRecoverArtifacts: Bool {
        status == .verified
            && hasValidSourceSignature
            && verifiedArtifacts.count == manifestEntryCount
            && Set(verifiedArtifacts.map(\.id)).count
                == manifestEntryCount
    }

    func verifiedArtifact(
        for itemID: UUID
    ) -> PDFVersionArchiveVerifiedArtifact? {
        guard canRecoverArtifacts else { return nil }
        return verifiedArtifacts.first { $0.id == itemID }
    }

    var provenanceTitle: String {
        if hasInvalidSourceSignature {
            return "Invalid source signature"
        }
        if isLegacyUnsigned {
            return "Unsigned legacy archive"
        }
        return trustedSignerName ?? trustStatus.title
    }

    func resolvingTrust(
        _ trustStatus: PDFOfficeSignerTrustStatus,
        trustedSignerName: String?
    ) -> PDFVersionArchiveVerificationReport {
        PDFVersionArchiveVerificationReport(
            id: id,
            archiveName: archiveName,
            archiveByteCount: archiveByteCount,
            schema: schema,
            archiveCreatedAt: archiveCreatedAt,
            verifiedAt: verifiedAt,
            manifestEntryCount: manifestEntryCount,
            archiveEntryCount: archiveEntryCount,
            items: items,
            structuralFailures: structuralFailures,
            signatureStatus: signatureStatus,
            signatureDetail: signatureDetail,
            signerKeyID: signerKeyID,
            signerPublicKeyBase64: signerPublicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            verifiedArtifacts: verifiedArtifacts
        )
    }

    func removingVerifiedArtifacts()
        -> PDFVersionArchiveVerificationReport {
        PDFVersionArchiveVerificationReport(
            id: id,
            archiveName: archiveName,
            archiveByteCount: archiveByteCount,
            schema: schema,
            archiveCreatedAt: archiveCreatedAt,
            verifiedAt: verifiedAt,
            manifestEntryCount: manifestEntryCount,
            archiveEntryCount: archiveEntryCount,
            items: items,
            structuralFailures: structuralFailures,
            signatureStatus: signatureStatus,
            signatureDetail: signatureDetail,
            signerKeyID: signerKeyID,
            signerPublicKeyBase64: signerPublicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            verifiedArtifacts: []
        )
    }
}

struct PDFOfficePinnedStorageSummary: Hashable, Sendable {
    static let maximumOutputCount = 24
    static let maximumByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024

    let outputCount: Int
    let byteCount: Int64

    static func measuring<S: Sequence>(
        _ outputs: S
    ) -> PDFOfficePinnedStorageSummary
    where S.Element == PDFPinnedOfficeOutput {
        var count = 0
        var totalBytes: Int64 = 0
        for output in outputs {
            count += 1
            let (sum, overflow) = totalBytes.addingReportingOverflow(
                max(0, output.receipt.fileSizeBytes)
            )
            totalBytes = overflow ? .max : sum
        }
        return PDFOfficePinnedStorageSummary(
            outputCount: count,
            byteCount: totalBytes
        )
    }

    var formattedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    var countContract: String {
        "\(outputCount)/\(Self.maximumOutputCount)"
    }

    var byteContract: String {
        AppLocalization.format(
            "%@ / %@",
            formattedBytes,
            ByteCountFormatter.string(
                fromByteCount: Self.maximumByteCount,
                countStyle: .file
            )
        )
    }

    var byteUsageFraction: Double {
        guard Self.maximumByteCount > 0 else { return 0 }
        return min(
            1,
            Double(max(0, byteCount))
                / Double(Self.maximumByteCount)
        )
    }

    var countUsageFraction: Double {
        guard Self.maximumOutputCount > 0 else { return 0 }
        return min(
            1,
            Double(max(0, outputCount))
                / Double(Self.maximumOutputCount)
        )
    }

    var pressureFraction: Double {
        max(byteUsageFraction, countUsageFraction)
    }

    var remainingOutputCount: Int {
        max(0, Self.maximumOutputCount - outputCount)
    }

    var remainingByteCount: Int64 {
        max(0, Self.maximumByteCount - max(0, byteCount))
    }

    var formattedRemainingBytes: String {
        ByteCountFormatter.string(
            fromByteCount: remainingByteCount,
            countStyle: .file
        )
    }

    var isAtCapacity: Bool {
        outputCount >= Self.maximumOutputCount
            || byteCount >= Self.maximumByteCount
    }

    var isNearCapacity: Bool {
        outputCount >= Self.maximumOutputCount - 4
            || byteUsageFraction >= 0.8
    }

    func canAdd(bytes: Int64) -> Bool {
        let (combinedBytes, overflow) = max(0, byteCount)
            .addingReportingOverflow(max(0, bytes))
        return outputCount < Self.maximumOutputCount
            && !overflow
            && combinedBytes <= Self.maximumByteCount
    }
}

struct PDFTechnicalPermissions: Sendable {
    let allowsHighQualityPrinting: Bool
    let allowsCopying: Bool
    let allowsCommenting: Bool
    let allowsFormFilling: Bool
    let allowsDocumentAssembly: Bool
    let allowsContentAccessibility: Bool
}

struct PDFTechnicalInspection: Sendable {
    let byteCount: Int64
    let pageCount: Int
    let sampledPageCount: Int
    let textCoverage: Double?
    let imageDominantPageCount: Int?
    let formFieldCount: Int?
    let annotationCount: Int?
    let attachmentCount: Int?
    let outlineEntryCount: Int?
    let hasExplicitPageLabels: Bool?
    let isEncrypted: Bool
    let isLocked: Bool
    let permissions: PDFTechnicalPermissions?
    let source: PDFSourceLocationSnapshot?
}

enum PDFSourceLocationStatus: String, Sendable {
    case detached
    case current
    case changed
    case unavailable
    case stale

    var title: String {
        switch self {
        case .detached: return "Private copy only"
        case .current: return "Source unchanged"
        case .changed: return "Source changed in Files"
        case .unavailable: return "Source unavailable"
        case .stale: return "Source location moved"
        }
    }

    var symbol: String {
        switch self {
        case .detached: return "internaldrive"
        case .current: return "checkmark.icloud"
        case .changed: return "arrow.triangle.2.circlepath.icloud"
        case .unavailable: return "icloud.slash"
        case .stale: return "folder.badge.questionmark"
        }
    }
}

struct PDFSourceLocationSnapshot: Sendable {
    let status: PDFSourceLocationStatus
    let name: String?
    let resolvedURL: URL?
    let isUbiquitous: Bool
    let modificationDate: Date?
}

struct OCRTextBlock: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let confidence: Double
    let normalizedX: Double
    let normalizedY: Double
    let normalizedWidth: Double
    let normalizedHeight: Double
    let isUserCorrected: Bool

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Double,
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        isUserCorrected: Bool = false
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.isUserCorrected = isUserCorrected
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case confidence
        case normalizedX
        case normalizedY
        case normalizedWidth
        case normalizedHeight
        case isUserCorrected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(
            Double.self,
            forKey: .confidence
        )
        normalizedX = try container.decode(
            Double.self,
            forKey: .normalizedX
        )
        normalizedY = try container.decode(
            Double.self,
            forKey: .normalizedY
        )
        normalizedWidth = try container.decode(
            Double.self,
            forKey: .normalizedWidth
        )
        normalizedHeight = try container.decode(
            Double.self,
            forKey: .normalizedHeight
        )
        isUserCorrected = try container.decodeIfPresent(
            Bool.self,
            forKey: .isUserCorrected
        ) ?? false
    }
}

enum OCRRecognitionPass:
    String,
    Codable,
    Hashable,
    Sendable {
    case standard
    case enhanced

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .enhanced: return "Enhanced locally"
        }
    }
}

enum OCRLanguageMode:
    String,
    Codable,
    CaseIterable,
    Identifiable,
    Sendable {
    case automatic
    case selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .selected: return "Choose Languages"
        }
    }
}

enum OCRRecognitionLanguage:
    String,
    CaseIterable,
    Identifiable,
    Sendable {
    case english = "en-US"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja-JP"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case portuguese = "pt-BR"
    case italian = "it-IT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .portuguese: return "Portuguese"
        case .italian: return "Italian"
        }
    }
}

struct OCRRecognitionConfiguration:
    Codable,
    Hashable,
    Sendable {
    let languageMode: OCRLanguageMode
    let languageIdentifiers: [String]
    let customWords: [String]

    static let automatic = OCRRecognitionConfiguration(
        languageMode: .automatic,
        languageIdentifiers: [],
        customWords: []
    )

    var languageSummary: String {
        guard languageMode == .selected else {
            return "Automatic language detection".localizedUI
        }
        let names = languageIdentifiers.compactMap {
            identifier in
            OCRRecognitionLanguage(rawValue: identifier)?.title.localizedUI
                ?? AppLocalization.selectedLanguage.locale.localizedString(
                    forIdentifier: identifier
                )
        }
        return names.isEmpty
            ? "Selected languages".localizedUI
            : names.joined(separator: ", ")
    }
}

struct OCRPageResult: Codable, Identifiable, Hashable, Sendable {
    var id: Int { pageIndex }
    let pageIndex: Int
    let text: String
    let confidence: Double
    let blocks: [OCRTextBlock]
    let recognitionPass: OCRRecognitionPass

    var needsReview: Bool {
        confidence < 0.72
            || text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            || !lowConfidenceBlocks.isEmpty
    }

    var lowConfidenceBlocks: [OCRTextBlock] {
        blocks.filter {
            $0.confidence < 0.72 && !$0.isUserCorrected
        }
    }

    init(
        pageIndex: Int,
        text: String,
        confidence: Double,
        blocks: [OCRTextBlock] = [],
        recognitionPass: OCRRecognitionPass = .standard
    ) {
        self.pageIndex = pageIndex
        self.text = text
        self.confidence = confidence
        self.blocks = blocks
        self.recognitionPass = recognitionPass
    }

    private enum CodingKeys: String, CodingKey {
        case pageIndex
        case text
        case confidence
        case blocks
        case recognitionPass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Double.self, forKey: .confidence)
        blocks = try container.decodeIfPresent(
            [OCRTextBlock].self,
            forKey: .blocks
        ) ?? []
        recognitionPass = try container.decodeIfPresent(
            OCRRecognitionPass.self,
            forKey: .recognitionPass
        ) ?? .standard
    }
}

struct OCRResult: Codable, Hashable, Sendable {
    static let maximumPageCount = 1_000
    static let maximumBlockCount = 100_000
    static let maximumEncodedTextBytes = 64 * 1_024 * 1_024

    let pages: [OCRPageResult]
    let configuration: OCRRecognitionConfiguration

    init(
        pages: [OCRPageResult],
        configuration: OCRRecognitionConfiguration = .automatic
    ) {
        self.pages = Self.normalizedPages(pages)
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case pages
        case configuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        pages = Self.normalizedPages(
            try container.decode(
                [OCRPageResult].self,
                forKey: .pages
            )
        )
        configuration = try container.decodeIfPresent(
            OCRRecognitionConfiguration.self,
            forKey: .configuration
        ) ?? .automatic
    }

    private static func normalizedPages(
        _ pages: [OCRPageResult]
    ) -> [OCRPageResult] {
        var preferredByIndex: [Int: OCRPageResult] = [:]
        for page in pages where page.pageIndex >= 0 {
            guard let current = preferredByIndex[page.pageIndex] else {
                preferredByIndex[page.pageIndex] = page
                continue
            }
            if prefers(page, over: current) {
                preferredByIndex[page.pageIndex] = page
            }
        }
        return preferredByIndex.values.sorted {
            $0.pageIndex < $1.pageIndex
        }
    }

    private static func prefers(
        _ candidate: OCRPageResult,
        over current: OCRPageResult
    ) -> Bool {
        let candidateCorrections = candidate.blocks.filter(
            \.isUserCorrected
        ).count
        let currentCorrections = current.blocks.filter(
            \.isUserCorrected
        ).count
        if candidateCorrections != currentCorrections {
            return candidateCorrections > currentCorrections
        }
        let candidateText = candidate.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let currentText = current.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let candidateLength = candidateText.count
        let currentLength = currentText.count
        let candidateQuality = Double(candidateLength)
            * min(max(candidate.confidence, 0), 1)
        let currentQuality = Double(currentLength)
            * min(max(current.confidence, 0), 1)
        if candidateQuality != currentQuality {
            return candidateQuality > currentQuality
        }
        if candidateLength != currentLength {
            return candidateLength > currentLength
        }
        if candidate.confidence != current.confidence {
            return candidate.confidence > current.confidence
        }
        if candidate.recognitionPass != current.recognitionPass {
            return candidate.recognitionPass == .enhanced
        }
        return candidate.blocks.count > current.blocks.count
    }

    var text: String {
        pages
            .map { "Page \($0.pageIndex + 1)\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    var meanConfidence: Double {
        guard !pages.isEmpty else { return 0 }
        return pages.reduce(0) { $0 + $1.confidence } / Double(pages.count)
    }

    var pagesNeedingReview: [OCRPageResult] {
        pages.filter(\.needsReview)
    }

    var enhancedPageCount: Int {
        pages.filter { $0.recognitionPass == .enhanced }.count
    }
}

enum PDFPageSelection {
    enum SelectionError: LocalizedError {
        case empty
        case syntax
        case outOfBounds(Int)
        case tooLong

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter at least one page number.".localizedUI
            case .syntax:
                return "Use page numbers or ascending ranges separated by commas.".localizedUI
            case .outOfBounds(let pageCount):
                return AppLocalization.format("Page numbers must be between 1 and %lld.", pageCount)
            case .tooLong:
                return "The page selection is too long.".localizedUI
            }
        }
    }

    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        guard text.count <= 2_048 else { throw SelectionError.tooLong }
        guard (1...100_000).contains(pageCount) else {
            throw SelectionError.outOfBounds(max(0, pageCount))
        }
        let normalized = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SelectionError.empty }
        let tokens = normalized.split(separator: ",", omittingEmptySubsequences: false)
        guard tokens.count <= 256 else { throw SelectionError.tooLong }
        var indices: Set<Int> = []
        for token in tokens {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { throw SelectionError.syntax }
            let numbers = try parts.map { part -> Int in
                let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(value)
                else { throw SelectionError.syntax }
                guard (1...pageCount).contains(number) else {
                    throw SelectionError.outOfBounds(pageCount)
                }
                return number
            }
            let first = numbers[0]
            let last = numbers.last ?? first
            guard first <= last else { throw SelectionError.syntax }
            indices.formUnion((first - 1)..<last)
        }
        return indices.sorted()
    }
}

enum PaperPathError: LocalizedError {
    case unreadablePDF
    case unreadableImage
    case lockedPDF
    case invalidPage
    case cannotDeleteOnlyPage
    case cameraUnavailable
    case emptyScan
    case insufficientSelection(String)
    case insufficientStorage
    case fileTooLarge
    case invalidPassword
    case missingRecognizedText
    case compressionNotBeneficial(
        sourceByteCount: Int64,
        candidateByteCount: Int64
    )
    case outputVerificationFailed(String)
    case storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "PaperPath could not read this PDF.".localizedUI
        case .unreadableImage:
            return "The selected images could not be opened.".localizedUI
        case .lockedPDF:
            return "This PDF must be unlocked before it can be processed."
                .localizedUI
        case .invalidPage:
            return "That page is no longer available.".localizedUI
        case .cannotDeleteOnlyPage:
            return "A PDF must keep at least one page.".localizedUI
        case .cameraUnavailable:
            return "Document scanning is unavailable in this environment."
                .localizedUI
        case .emptyScan:
            return "The scan did not contain any pages.".localizedUI
        case .insufficientSelection(let detail):
            return detail.localizedUI
        case .insufficientStorage:
            return "There isn’t enough free space to create a private copy. Free some storage and try again."
                .localizedUI
        case .fileTooLarge:
            return "This PDF is larger than the 1 GB on-device processing limit."
                .localizedUI
        case .invalidPassword:
            return "Use a PDF password between 8 and 128 characters."
                .localizedUI
        case .missingRecognizedText:
            return "Recognize the document text before creating a searchable copy."
                .localizedUI
        case .compressionNotBeneficial(
            let sourceByteCount,
            let candidateByteCount
        ):
            return AppLocalization.format(
                "Compression would grow this PDF from %@ to %@. PaperPath did not save the larger copy.",
                ByteCountFormatter.string(
                    fromByteCount: sourceByteCount,
                    countStyle: .file
                ),
                ByteCountFormatter.string(
                    fromByteCount: candidateByteCount,
                    countStyle: .file
                )
            )
        case .outputVerificationFailed(let reason):
            return AppLocalization.format(
                "The output failed verification: %@",
                reason.localizedUI
            )
        case .storageFailure(let detail):
            return AppLocalization.format(
                "PaperPath could not update its private copy. %@",
                detail.localizedUI
            )
        }
    }
}
