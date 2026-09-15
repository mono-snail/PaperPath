import CryptoKit
import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
private typealias DOCXPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
private typealias DOCXPlatformFont = NSFont
#endif

struct PDFOfficePageGeometry: Sendable {
    let displaySize: CGSize
    let rotation: Int

    init?(page: PDFPage) {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0
        else { return nil }
        let normalizedRotation = (
            (page.rotation % 360) + 360
        ) % 360
        let swapsEdges = normalizedRotation == 90
            || normalizedRotation == 270
        self.displaySize = swapsEdges
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        self.rotation = normalizedRotation
    }

    var aspectRatio: CGFloat {
        displaySize.width / max(1, displaySize.height)
    }

    var isLandscape: Bool {
        displaySize.width > displaySize.height
    }
}

private func officeIndexedTextByPage(
    _ textIndex: DocumentTextIndex?
) -> [Int: String] {
    (textIndex?.pages ?? []).reduce(into: [:]) { result, page in
        guard page.pageIndex >= 0 else { return }
        let candidate = page.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !candidate.isEmpty else { return }
        if let existing = result[page.pageIndex],
           existing.count >= candidate.count {
            return
        }
        result[page.pageIndex] = candidate
    }
}

private func officeAuditPropertiesXML(
    format: PDFTextExportFormat,
    portfolio: PDFOfficeExportPortfolio,
    runtime: PDFOfficeRuntimeEvidence
) -> String {
    let plan = portfolio.plan(for: format)
    let leadSignal = portfolio.preflightLeadSignal

    func preflightValue(_ id: String) -> String {
        guard let signal = portfolio.preflightSignals.first(
            where: { $0.id == id }
        ) else { return "missing" }
        return "\(signal.readiness.rawValue): \(signal.value) · \(signal.detail)"
    }

    func property(
        pid: Int,
        name: String,
        value: String
    ) -> String {
        """
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="\(pid)" name="\(ooxmlEscaped(name))"><vt:lpwstr>\(ooxmlEscaped(value))</vt:lpwstr></property>
        """
    }

    let signalDigest = portfolio.preflightSignals
        .map {
            "\($0.id):\($0.readiness.rawValue):\($0.value)"
        }
        .joined(separator: " | ")
    let properties = [
        property(
            pid: 2,
            name: "PaperPathAuditSchema",
            value: "Office Production Audit V29"
        ),
        property(
            pid: 3,
            name: "PaperPathExportMode",
            value:
                "Local \(format.fileExtension.uppercased()) reconstruction"
        ),
        property(
            pid: 4,
            name: "PaperPathOfficeFormat",
            value: format.fileExtension.uppercased()
        ),
        property(
            pid: 5,
            name: "PaperPathSourcePages",
            value: "\(runtime.sourcePageCount)"
        ),
        property(
            pid: 6,
            name: "PaperPathExportedPages",
            value: "\(runtime.outputPageCount)"
        ),
        property(
            pid: 7,
            name: "PaperPathPageYieldPercent",
            value: "\(runtime.pageYieldPercent)"
        ),
        property(
            pid: 8,
            name: "PaperPathPrimaryUnit",
            value: runtime.primaryUnitLabel
        ),
        property(
            pid: 9,
            name: "PaperPathPrimaryUnitCount",
            value: "\(runtime.primaryUnitCount)"
        ),
        property(
            pid: 10,
            name: "PaperPathCharacterCount",
            value: "\(runtime.characterCount)"
        ),
        property(
            pid: 11,
            name: "PaperPathSearchablePages",
            value: "\(runtime.searchablePageCount)"
        ),
        property(
            pid: 12,
            name: "PaperPathSearchableCoveragePercent",
            value: "\(runtime.searchableCoveragePercent)"
        ),
        property(
            pid: 13,
            name: "PaperPathEmbeddedAssets",
            value: "\(runtime.assetCount)"
        ),
        property(
            pid: 14,
            name: "PaperPathEmbeddedAssetBytes",
            value: "\(runtime.assetByteCount)"
        ),
        property(
            pid: 15,
            name: "PaperPathOfficeRoute",
            value: portfolio.decisionLine
        ),
        property(
            pid: 16,
            name: "PaperPathOfficeRouteScore",
            value: "\(plan.compositeScore)"
        ),
        property(
            pid: 17,
            name: "PaperPathOfficeReadiness",
            value: plan.readiness.rawValue
        ),
        property(
            pid: 18,
            name: "PaperPathOfficeRouteConfidence",
            value: portfolio.routeConfidence.rawValue
        ),
        property(
            pid: 19,
            name: "PaperPathOfficeProductionSLA",
            value: portfolio.productionSLA.rawValue
        ),
        property(
            pid: 20,
            name: "PaperPathOfficeRouteRank",
            value: portfolio.routeRankLine
        ),
        property(
            pid: 21,
            name: "PaperPathOfficePreflightSummary",
            value: portfolio.preflightSummary
        ),
        property(
            pid: 22,
            name: "PaperPathOfficePreflightDigest",
            value: signalDigest
        ),
        property(
            pid: 23,
            name: "PaperPathOfficeLeadRisk",
            value: leadSignal.map {
                "\($0.readiness.rawValue): \($0.detail)"
            } ?? "none"
        ),
        property(
            pid: 24,
            name: "PaperPathOfficeRights",
            value: preflightValue("rights")
        ),
        property(
            pid: 25,
            name: "PaperPathOfficeStructure",
            value: preflightValue("structure")
        ),
        property(
            pid: 26,
            name: "PaperPathOfficeVisual",
            value: preflightValue("visual")
        ),
        property(
            pid: 27,
            name: "PaperPathOfficePackage",
            value: preflightValue("package")
        ),
        property(
            pid: 28,
            name: "PaperPathOfficeAnchorPolicy",
            value: portfolio.visualBudgetPlan.anchorPolicy.rawValue
        ),
        property(
            pid: 29,
            name: "PaperPathOfficeBudgetPressure",
            value: portfolio.visualBudgetPlan.budgetPressure.rawValue
        ),
        property(
            pid: 30,
            name: "PaperPathOfficeBudgetContract",
            value: portfolio.visualBudgetPlan.pressureContract
        ),
        property(
            pid: 31,
            name: "PaperPathOfficeMemoryGuard",
            value: portfolio.visualBudgetPlan.memoryGuardSummary
        ),
        property(
            pid: 32,
            name: "PaperPathOfficeOutputBoundary",
            value: portfolio.outputBoundaryLine
        ),
        property(
            pid: 33,
            name: "PaperPathPrivacy",
            value: "Generated on device from the private working copy"
        ),
        property(
            pid: 34,
            name: "PaperPathAssetBudgetBytes",
            value: "\(runtime.assetBudgetByteCount)"
        ),
        property(
            pid: 35,
            name: "PaperPathAssetBudgetUsePercent",
            value: "\(runtime.assetBudgetUsePercent)"
        ),
        property(
            pid: 36,
            name: "PaperPathAssetCompressionFallbacks",
            value: "\(runtime.assetCompressionFallbackCount)"
        ),
        property(
            pid: 37,
            name: "PaperPathAssetMinimumQualityPercent",
            value: "\(runtime.assetMinimumQualityPercent)"
        ),
        property(
            pid: 38,
            name: "PaperPathContentNotices",
            value: officeContentNoticeDigest(runtime.contentNotices ?? [])
        )
    ].joined()

    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\(properties)</Properties>
    """
}

private func officeContentNoticeDigest(_ notices: [PDFOfficeContentNotice]) -> String {
    notices.map {
        "\($0.kind.rawValue): \($0.kind.detail) pages=\($0.pageIndices.map { String($0 + 1) }.joined(separator: ","))"
    }.joined(separator: "\n")
}

struct DOCXVisualReferenceBudget {
    let longestEdge: CGFloat
    let compressionQuality: CGFloat
    let maximumTotalBytes: Int
    let maximumBytesPerPage: Int
    let mode: PDFOfficeVisualBudgetMode

    init(pageCount: Int) {
        let totalBudget = 72 * 1_024 * 1_024
        mode = PDFOfficeVisualBudgetMode(pageCount: pageCount)
        longestEdge = CGFloat(mode.longestEdge)
        compressionQuality =
            CGFloat(mode.compressionQualityPercent) / 100
        maximumTotalBytes = totalBudget
        maximumBytesPerPage = min(
            3 * 1_024 * 1_024,
            max(
                160 * 1_024,
                totalBudget / max(1, pageCount)
            )
        )
    }

    func byteLimitForPage(
        hasStructuredText: Bool,
        hasTable: Bool,
        hasEmbeddedImage: Bool,
        priority: DOCXVisualReferencePriority,
        remainingTotalBytes: Int,
        remainingCandidateCount: Int
    ) -> Int {
        let multiplier = priority.byteMultiplier(
            hasStructuredText: hasStructuredText,
            hasTable: hasTable,
            hasEmbeddedImage: hasEmbeddedImage
        )
        let reserveBytes = max(
            0,
            (max(remainingCandidateCount, 1) - 1)
                * priority.reserveBytesPerLaterCandidate
        )
        let spendableBytes = max(
            priority.minimumByteFloor,
            remainingTotalBytes - reserveBytes
        )
        return min(
            spendableBytes,
            max(
                priority.minimumByteFloor,
                Int(Double(maximumBytesPerPage) * multiplier)
            )
        )
    }

    func remainingCandidateWindow(
        pageIndex: Int,
        pageCount: Int,
        priority: DOCXVisualReferencePriority
    ) -> Int {
        let remainingPages = max(1, pageCount - pageIndex)
        let baseWindow = mode.chunkPageTarget
        let priorityWindow: Int
        switch priority {
        case .critical:
            priorityWindow = baseWindow
        case .image:
            priorityWindow = max(8, baseWindow / 2)
        case .table:
            priorityWindow = max(6, baseWindow / 3)
        }
        return min(remainingPages, priorityWindow)
    }
}

struct DOCXBlockStats: Sendable {
    let paragraphCount: Int
    let tableCount: Int
    let tableRowCount: Int
    let tableCellCount: Int
    let characterCount: Int
    let hasTable: Bool

    init(blocks: [DOCXBlock]) {
        var paragraphs = 0
        var tables = 0
        var tableRows = 0
        var tableCells = 0
        var characters = 0
        for block in blocks {
            switch block {
            case .paragraph(let paragraph):
                paragraphs += 1
                characters += paragraph.text.count
            case .table(let table):
                tables += 1
                tableRows += table.rows.count
                characters += table.rows.reduce(0) { result, row in
                    tableCells += row.cells.count
                    return result + row.cells.reduce(0) {
                        $0 + $1.text.count
                    }
                }
            }
        }
        paragraphCount = paragraphs
        tableCount = tables
        tableRowCount = tableRows
        tableCellCount = tableCells
        characterCount = characters
        hasTable = tables > 0
    }
}

struct DOCXContentBudget: Sendable {
    static let maximumPageUTF16Units = 1_000_000
    static let maximumCharacterCount = 8_000_000
    static let maximumStructuralElementCount = 200_000
    static let maximumDocumentXMLBytes = 64 * 1_024 * 1_024

    let maximumPageUTF16Units: Int
    let maximumCharacterCount: Int
    let maximumStructuralElementCount: Int
    private(set) var characterCount = 0
    private(set) var structuralElementCount = 0

    init(
        maximumPageUTF16Units: Int = Self.maximumPageUTF16Units,
        maximumCharacterCount: Int = Self.maximumCharacterCount,
        maximumStructuralElementCount: Int =
            Self.maximumStructuralElementCount
    ) {
        self.maximumPageUTF16Units = max(0, maximumPageUTF16Units)
        self.maximumCharacterCount = max(0, maximumCharacterCount)
        self.maximumStructuralElementCount = max(
            0,
            maximumStructuralElementCount
        )
    }

    func validatePageText(_ text: String) throws {
        guard (text as NSString).length <= maximumPageUTF16Units else {
            throw budgetExceededError
        }
    }

    mutating func consume(_ stats: DOCXBlockStats) throws {
        let (nextCharacters, characterOverflow) = characterCount
            .addingReportingOverflow(stats.characterCount)
        let pageElements = [
            stats.paragraphCount,
            stats.tableCount,
            stats.tableRowCount,
            stats.tableCellCount
        ].reduce(into: 0) { result, value in
            let (next, overflow) = result.addingReportingOverflow(value)
            result = overflow ? Int.max : next
        }
        let (nextElements, elementOverflow) = structuralElementCount
            .addingReportingOverflow(pageElements)
        guard !characterOverflow,
              !elementOverflow,
              nextCharacters <= maximumCharacterCount,
              nextElements <= maximumStructuralElementCount
        else {
            throw budgetExceededError
        }
        characterCount = nextCharacters
        structuralElementCount = nextElements
    }

    private var budgetExceededError: PaperPathError {
        .insufficientSelection(
            "The detected Word content exceeds the on-device export budget."
        )
    }
}

enum DOCXVisualReferenceSkipReason: String {
    case totalBudgetExhausted = "total-budget-exhausted"
    case pageBudgetExceeded = "page-budget-exceeded"
    case renderFailed = "render-failed"
}

enum DOCXVisualReferencePriority: String {
    case critical = "critical"
    case image = "image"
    case table = "table"

    static func classify(
        hasStructuredText: Bool,
        hasTable: Bool,
        hasEmbeddedImage: Bool
    ) -> DOCXVisualReferencePriority {
        if !hasStructuredText {
            return .critical
        }
        if hasEmbeddedImage {
            return .image
        }
        if hasTable {
            return .table
        }
        return .table
    }

    func byteMultiplier(
        hasStructuredText: Bool,
        hasTable: Bool,
        hasEmbeddedImage: Bool
    ) -> Double {
        switch self {
        case .critical:
            return 1.34
        case .image:
            return hasEmbeddedImage ? 1.16 : 1.02
        case .table:
            return hasTable ? 0.92 : 0.72
        }
    }

    var minimumByteFloor: Int {
        switch self {
        case .critical:
            return 180 * 1_024
        case .image:
            return 144 * 1_024
        case .table:
            return 104 * 1_024
        }
    }

    var reserveBytesPerLaterCandidate: Int {
        switch self {
        case .critical:
            return 116 * 1_024
        case .image:
            return 104 * 1_024
        case .table:
            return 80 * 1_024
        }
    }
}

struct DOCXVisualReferenceResult {
    let image: DOCXImage
    let priority: DOCXVisualReferencePriority
    let attemptCount: Int
    let acceptedQualityPercent: Int
    let acceptedLongestEdge: Int
    let byteCount: Int

    var usedCompressionFallback: Bool {
        attemptCount > 1
    }
}

enum DOCXVisualReferenceOutcome {
    case accepted(DOCXVisualReferenceResult)
    case skipped(DOCXVisualReferenceSkipReason)
}

struct DOCXReconstructionMetrics: Sendable {
    let sourcePageCount: Int
    let officePortfolio: PDFOfficeExportPortfolio
    let visualBudgetMode: PDFOfficeVisualBudgetMode
    let visualLongestEdge: Int
    let visualCompressionQualityPercent: Int
    let visualMaximumBytesPerPage: Int
    var exportedPageCount = 0
    var structuredPageCount = 0
    var paragraphCount = 0
    var tableCount = 0
    var characterCount = 0
    var fallbackPageCount = 0
    var visualReferenceCount = 0
    var visualReferenceByteCount = 0
    var skippedVisualReferenceCount = 0
    var visualBudgetSkipCount = 0
    var visualPageBudgetExceededCount = 0
    var visualRenderFailedCount = 0
    var visualCompressionFallbackCount = 0
    var visualCriticalAnchorCount = 0
    var visualImageAnchorCount = 0
    var visualTableAnchorCount = 0
    var visualCandidatePageCount = 0
    var visualCriticalCandidateCount = 0
    var visualImageCandidateCount = 0
    var visualTableCandidateCount = 0
    var visualBudgetWindowLimitedCount = 0
    var visualMinimumPageBudget = Int.max
    var visualMaximumPageBudget = 0
    var visualAcceptedMinimumQualityPercent = 100
    var visualAcceptedMaximumByteCount = 0
    var visualAcceptedSmallestEdge = Int.max
    var missingVisualPageIndices: [Int] = []

    mutating func recordVisualCandidate(
        priority: DOCXVisualReferencePriority,
        pageBudget: Int,
        windowWasLimited: Bool
    ) {
        visualCandidatePageCount += 1
        visualMinimumPageBudget = min(visualMinimumPageBudget, pageBudget)
        visualMaximumPageBudget = max(visualMaximumPageBudget, pageBudget)
        if windowWasLimited {
            visualBudgetWindowLimitedCount += 1
        }
        switch priority {
        case .critical:
            visualCriticalCandidateCount += 1
        case .image:
            visualImageCandidateCount += 1
        case .table:
            visualTableCandidateCount += 1
        }
    }

    mutating func recordPage(
        blockStats: DOCXBlockStats,
        usedFallbackText: Bool,
        visualReferenceResult: DOCXVisualReferenceResult?
    ) {
        exportedPageCount += 1
        if blockStats.characterCount > 0 {
            structuredPageCount += 1
        }
        paragraphCount += blockStats.paragraphCount
        tableCount += blockStats.tableCount
        characterCount += blockStats.characterCount
        if usedFallbackText {
            fallbackPageCount += 1
        }
        if let visualReferenceResult {
            visualReferenceCount += 1
            visualReferenceByteCount += visualReferenceResult.byteCount
            visualAcceptedMinimumQualityPercent = min(
                visualAcceptedMinimumQualityPercent,
                visualReferenceResult.acceptedQualityPercent
            )
            visualAcceptedMaximumByteCount = max(
                visualAcceptedMaximumByteCount,
                visualReferenceResult.byteCount
            )
            visualAcceptedSmallestEdge = min(
                visualAcceptedSmallestEdge,
                visualReferenceResult.acceptedLongestEdge
            )
            if visualReferenceResult.usedCompressionFallback {
                visualCompressionFallbackCount += 1
            }
            switch visualReferenceResult.priority {
            case .critical:
                visualCriticalAnchorCount += 1
            case .image:
                visualImageAnchorCount += 1
            case .table:
                visualTableAnchorCount += 1
            }
        }
    }

    mutating func recordSkippedVisualReference(
        _ reason: DOCXVisualReferenceSkipReason
    ) {
        skippedVisualReferenceCount += 1
        switch reason {
        case .totalBudgetExhausted:
            visualBudgetSkipCount += 1
        case .pageBudgetExceeded:
            visualPageBudgetExceededCount += 1
        case .renderFailed:
            visualRenderFailedCount += 1
        }
    }

    var acceptedMinimumQualitySummary: String {
        visualReferenceCount == 0
            ? "none"
            : "\(visualAcceptedMinimumQualityPercent)"
    }

    var acceptedSmallestEdgeSummary: String {
        visualReferenceCount == 0
            ? "none"
            : "\(visualAcceptedSmallestEdge)"
    }

    var minimumPageBudgetSummary: String {
        visualCandidatePageCount == 0
            ? "none"
            : "\(visualMinimumPageBudget)"
    }

    var maximumPageBudgetSummary: String {
        visualCandidatePageCount == 0
            ? "none"
            : "\(visualMaximumPageBudget)"
    }

    var pageYieldPercent: Int {
        guard sourcePageCount > 0 else { return 0 }
        return min(
            100,
            max(
                0,
                Int(
                    (
                        Double(exportedPageCount)
                            / Double(sourcePageCount)
                            * 100
                    ).rounded()
                )
            )
        )
    }

    var structuredCoveragePercent: Int {
        guard exportedPageCount > 0 else { return 0 }
        return min(
            100,
            max(
                0,
                Int(
                    (
                        Double(structuredPageCount)
                            / Double(exportedPageCount)
                            * 100
                    ).rounded()
                )
            )
        )
    }

    var visualAnchorHitPercent: Int {
        guard visualCandidatePageCount > 0 else { return 0 }
        return min(
            100,
            max(
                0,
                Int(
                    (
                        Double(visualReferenceCount)
                            / Double(visualCandidatePageCount)
                            * 100
                    ).rounded()
                )
            )
        )
    }

    var visualBudgetUsePercent: Int {
        min(
            100,
            max(
                0,
                Int(
                    (
                        Double(visualReferenceByteCount)
                            / Double(
                                max(
                                    1,
                                    officePortfolio.visualBudgetPlan
                                        .maximumTotalBytes
                                )
                            )
                            * 100
                    ).rounded()
                )
            )
        )
    }

    var visualBudgetUseSummary: String {
        AppLocalization.format(
            "%lld%% · %@",
            visualBudgetUsePercent,
            ByteCountFormatter.string(
                fromByteCount: Int64(visualReferenceByteCount),
                countStyle: .file
            )
        )
    }

    var visualSkipReasonSummary: String {
        AppLocalization.format(
            "total %@ · page %@ · render %@",
            "\(visualBudgetSkipCount)",
            "\(visualPageBudgetExceededCount)",
            "\(visualRenderFailedCount)"
        )
    }

    var qualityFallbackSummary: String {
        AppLocalization.format(
            "%@ compression · %@ fallback pages · minQ %@",
            "\(visualCompressionFallbackCount)",
            "\(fallbackPageCount)",
            acceptedMinimumQualitySummary
        )
    }

    var routeDecisionSummary: String {
        AppLocalization.format(
            "%@ · %@ · %@",
            officePortfolio.routeConfidence.title,
            officePortfolio.productionSLA.title,
            officePortfolio.routeRankLine
        )
    }

    var reconstructionSummary: String {
        AppLocalization.format(
            "%lld/%lld pages · %lld paragraphs · %lld tables · %lld visuals",
            exportedPageCount,
            sourcePageCount,
            paragraphCount,
            tableCount,
            visualReferenceCount
        )
    }

    var embeddedPreflightSummary: String {
        let lead = officePortfolio.preflightLeadSignal
            .map { " · \($0.title)=\($0.value)" }
            ?? ""
        return "\(officePortfolio.preflightSummary)\(lead)"
    }

    var embeddedPreflightSignalDigest: String {
        officePortfolio.preflightSignals
            .map {
                "\($0.id):\($0.readiness.rawValue):\($0.value)"
            }
            .joined(separator: " | ")
    }

    var runtimeEvidence: PDFOfficeRuntimeEvidence {
        PDFOfficeRuntimeEvidence(
            sourcePageCount: sourcePageCount,
            outputPageCount: exportedPageCount,
            primaryUnitLabel: "blocks",
            primaryUnitCount: paragraphCount + tableCount,
            characterCount: characterCount,
            searchablePageCount: structuredPageCount,
            assetCount: visualReferenceCount,
            assetByteCount: visualReferenceByteCount,
            assetBudgetByteCount:
                officePortfolio.visualBudgetPlan.maximumTotalBytes,
            assetCompressionFallbackCount:
                visualCompressionFallbackCount,
            assetMinimumQualityPercent:
                visualReferenceCount == 0
                    ? 0
                    : visualAcceptedMinimumQualityPercent,
            contentNotices: PDFOfficeContentNotice.defaults(for: .wordDocument)
                + (missingVisualPageIndices.isEmpty ? [] : [
                    PDFOfficeContentNotice(kind: .missingVisualReferences, pageIndices: missingVisualPageIndices)
                ])
        )
    }
}

struct DOCXExportService: Sendable {
    private func fallbackProfile(
        document: PDFDocument,
        sourceSize: Int64
    ) -> DocumentProfile {
        DocumentProfile(
            pageCount: document.pageCount,
            sampledPageCount: max(1, min(document.pageCount, 12)),
            textCharacterCount: 0,
            imageDominantPageCount: 0,
            formFieldCount: 0,
            byteCount: sourceSize,
            isEncrypted: false,
            isLocked: document.isLocked,
            allowsCopying: true,
            allowsCommenting: true,
            kind: .mixed,
            recommendedActions: [.inspect]
        )
    }

    func export(
        sourceURL: URL,
        destination: URL,
        textIndex: DocumentTextIndex?,
        title: String,
        profile: DocumentProfile? = nil,
        byteProgress: @escaping PDFByteProgressHandler = { _ in },
        progress: @escaping PDFProgressHandler
    ) throws -> PDFOfficeRuntimeEvidence {
        let sourceSize = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceSize <= 512 * 1_024 * 1_024 else {
            throw PaperPathError.fileTooLarge
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= 1_000 else {
            throw PaperPathError.insufficientSelection(
                "Word export supports up to 1,000 PDF pages per document."
            )
        }

        let indexedPages = officeIndexedTextByPage(textIndex)
        let cgDocument = CGPDFDocument(sourceURL as CFURL)
        var pages: [DOCXPage] = []
        pages.reserveCapacity(document.pageCount)
        var contentBudget = DOCXContentBudget()
        var imageOrdinal = 0
        var visualReferenceByteCount = 0
        let visualBudget = DOCXVisualReferenceBudget(
            pageCount: document.pageCount
        )
        let officePortfolio = PDFOfficeExportPortfolio(
            profile: profile ?? fallbackProfile(
                document: document,
                sourceSize: Int64(sourceSize)
            )
        )
        var metrics = DOCXReconstructionMetrics(
            sourcePageCount: document.pageCount,
            officePortfolio: officePortfolio,
            visualBudgetMode: visualBudget.mode,
            visualLongestEdge: Int(visualBudget.longestEdge),
            visualCompressionQualityPercent:
                Int((visualBudget.compressionQuality * 100).rounded()),
            visualMaximumBytesPerPage:
                visualBudget.maximumBytesPerPage
        )
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            guard let geometry = PDFOfficePageGeometry(page: page) else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) has invalid dimensions"
                )
            }
            if let pageText = page.string {
                try contentBudget.validatePageText(pageText)
            }
            var blocks = structuredBlocks(from: page)
            var usedFallbackText = false
            if blocks.isEmpty,
               let indexedText = indexedPages[pageIndex] {
                try contentBudget.validatePageText(indexedText)
                blocks = fallbackParagraphs(from: indexedText)
                    .map(DOCXBlock.paragraph)
                usedFallbackText = !blocks.isEmpty
            }
            let blockStats = DOCXBlockStats(blocks: blocks)
            try contentBudget.consume(blockStats)
            let embeddedImagePage = cgDocument
                .flatMap { $0.page(at: pageIndex + 1) }
                .map(pageContainsEmbeddedImage) ?? false
            let needsSourceReference = page.rotation % 360 != 0
                || blocks.contains {
                    if case .paragraph(let paragraph) = $0 {
                        return hasSpacedEastAsianLabel(paragraph.text)
                    }
                    return false
                }
            let needsVisualReference = embeddedImagePage
                || needsSourceReference
                || blockStats.hasTable
                || blocks.isEmpty
            var visualReferenceResult: DOCXVisualReferenceResult?
            if needsVisualReference {
                let visualPriority = DOCXVisualReferencePriority.classify(
                    hasStructuredText: !blocks.isEmpty,
                    hasTable: blockStats.hasTable,
                    hasEmbeddedImage: embeddedImagePage || needsSourceReference
                )
                let remainingBudget =
                    visualBudget.maximumTotalBytes
                        - visualReferenceByteCount
                if remainingBudget <= 0 {
                    metrics.recordSkippedVisualReference(
                        .totalBudgetExhausted
                    )
                } else {
                    let remainingCandidateWindow =
                        visualBudget.remainingCandidateWindow(
                            pageIndex: pageIndex,
                            pageCount: document.pageCount,
                            priority: visualPriority
                        )
                    let pageBudget = min(
                        visualBudget.byteLimitForPage(
                            hasStructuredText: !blocks.isEmpty,
                            hasTable: blockStats.hasTable,
                            hasEmbeddedImage: embeddedImagePage,
                            priority: visualPriority,
                            remainingTotalBytes: remainingBudget,
                            remainingCandidateCount:
                                remainingCandidateWindow
                        ),
                        remainingBudget
                    )
                    metrics.recordVisualCandidate(
                        priority: visualPriority,
                        pageBudget: pageBudget,
                        windowWasLimited:
                            remainingCandidateWindow
                                < document.pageCount - pageIndex
                    )
                    let visualOutcome = pageVisualReference(
                        page: page,
                        geometry: geometry,
                        pageIndex: pageIndex,
                        relationshipIndex: imageOrdinal + 3,
                        longestEdge: visualBudget.longestEdge,
                        compressionQuality:
                            visualBudget.compressionQuality,
                        maximumByteCount: pageBudget,
                        priority: visualPriority
                    )
                    try Task.checkCancellation()
                    switch visualOutcome {
                    case .accepted(let result):
                        visualReferenceResult = result
                        visualReferenceByteCount += result.byteCount
                        imageOrdinal += 1
                    case .skipped(let reason):
                        metrics.recordSkippedVisualReference(reason)
                    }
                }
            }
            if needsVisualReference && visualReferenceResult == nil {
                metrics.missingVisualPageIndices.append(pageIndex)
            }
            if !blocks.isEmpty || visualReferenceResult != nil {
                metrics.recordPage(
                    blockStats: blockStats,
                    usedFallbackText: usedFallbackText,
                    visualReferenceResult: visualReferenceResult
                )
                pages.append(
                    DOCXPage(
                        pageIndex: pageIndex,
                        blocks: blocks,
                        visualReference: visualReferenceResult?.image,
                        layout: wordPageLayout(for: geometry)
                    )
                )
            }
            progress(
                0.64 * Double(pageIndex + 1)
                    / Double(max(1, document.pageCount))
            )
        }
        guard !pages.isEmpty else {
            throw PaperPathError.missingRecognizedText
        }

        _ = try makePackage(
            title: title,
            pages: pages,
            metrics: metrics,
            destination: destination,
            byteProgress: byteProgress
        )
        progress(0.86)
        progress(1)
        return metrics.runtimeEvidence
    }

    func structuredBlocks(
        from page: PDFPage
    ) -> [DOCXBlock] {
        guard let pageText = page.string,
              !pageText.isEmpty,
              let selection = page.selection(
                for: NSRange(
                    location: 0,
                    length: (pageText as NSString).length
                )
              )
        else { return [] }

        let rawLines = selection.selectionsByLine().compactMap {
            line(from: $0, on: page)
        }
        // PDFKit can separate a list marker from its text on the same baseline.
        var lines: [DOCXLine] = []
        for line in rawLines {
            if let previous = lines.last,
               abs(previous.bounds.midY - line.bounds.midY)
                    < min(previous.bounds.height, line.bounds.height) * 0.3,
               line.bounds.minX >= previous.bounds.maxX - 1,
               line.bounds.minX - previous.bounds.maxX <= max(18, previous.fontSize * 2),
               looksLikeListItem(previous.text),
               !looksLikeListItem(line.text) {
                lines[lines.count - 1] = DOCXLine(
                    text: previous.text + " " + line.text,
                    bounds: previous.bounds.union(line.bounds),
                    fontSize: line.fontSize,
                    isBold: line.isBold,
                    isItalic: line.isItalic,
                    cells: []
                )
            } else {
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return [] }
        let bodySize = median(lines.map(\.fontSize))
        let pageBounds = page.bounds(for: .cropBox)
        let textLeft = lines.map(\.bounds.minX).min() ?? pageBounds.minX
        var blocks: [DOCXBlock] = []
        var paragraphLines: [DOCXLine] = []

        func flushParagraphs() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(
                contentsOf: paragraphBlocks(
                    from: paragraphLines,
                    bodySize: bodySize,
                    pageBounds: pageBounds,
                    listBaseX: textLeft
                )
            )
            paragraphLines = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.cells.count >= 2, !looksLikeListItem(line.text) else {
                paragraphLines.append(line)
                index += 1
                continue
            }
            var tableLines = [line]
            var nextIndex = index + 1
            while nextIndex < lines.count,
                  lines[nextIndex].cells.count >= 2,
                  !looksLikeListItem(lines[nextIndex].text),
                  tableRowsAlign(
                      tableLines[0],
                      lines[nextIndex],
                      pageWidth: pageBounds.width
                  ) {
                tableLines.append(lines[nextIndex])
                nextIndex += 1
            }
            if tableLines.count >= 2 {
                flushParagraphs()
                blocks.append(
                    .table(
                        table(
                            from: tableLines,
                            pageBounds: pageBounds
                        )
                    )
                )
                index = nextIndex
            } else {
                paragraphLines.append(line)
                index += 1
            }
        }
        flushParagraphs()
        return blocks
    }

    func paragraphBlocks(
        from lines: [DOCXLine],
        bodySize: CGFloat,
        pageBounds: CGRect,
        listBaseX: CGFloat? = nil
    ) -> [DOCXBlock] {
        var groups: [[DOCXLine]] = []
        var current: [DOCXLine] = []
        for line in lines {
            if let previous = current.last,
               startsNewParagraph(
                   line,
                   after: previous,
                   paragraphStart: current.first ?? previous,
                   bodySize: bodySize
               ) {
                groups.append(current)
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups.compactMap {
            paragraph(
                from: $0,
                bodySize: bodySize,
                pageBounds: pageBounds,
                listBaseX: listBaseX
            )
        }.map(DOCXBlock.paragraph)
    }

    private func line(
        from selection: PDFSelection,
        on page: PDFPage
    ) -> DOCXLine? {
        guard let rawText = selection.string else { return nil }
        let text = rawText
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let bounds = selection.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var fontSizes: [CGFloat] = []
        var boldCount = 0
        var italicCount = 0
        var fontCount = 0
        if let attributed = selection.attributedString,
           attributed.length > 0 {
            attributed.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, range, _ in
                guard let font = value as? DOCXPlatformFont else { return }
                let weight = max(1, range.length)
                fontSizes.append(
                    contentsOf: repeatElement(
                        font.pointSize,
                        count: min(weight, 32)
                    )
                )
                fontCount += weight
                if fontIsBold(font) {
                    boldCount += weight
                }
                if fontIsItalic(font) {
                    italicCount += weight
                }
            }
        }
        let size = fontSizes.isEmpty
            ? max(8, bounds.height * 0.72)
            : median(fontSizes)
        return DOCXLine(
            text: text,
            bounds: bounds,
            fontSize: size,
            isBold: fontCount > 0 && boldCount * 2 >= fontCount,
            isItalic: fontCount > 0 && italicCount * 2 >= fontCount,
            cells: tableCells(
                from: selection,
                on: page,
                lineHeight: bounds.height
            )
        )
    }

    private func tableCells(
        from selection: PDFSelection,
        on page: PDFPage,
        lineHeight: CGFloat
    ) -> [DOCXCellCandidate] {
        guard let pageText = page.string else { return [] }
        let source = pageText as NSString
        let expression = try? NSRegularExpression(pattern: "\\S+")
        var words: [(text: String, bounds: CGRect)] = []
        for rangeIndex in 0..<selection.numberOfTextRanges(on: page) {
            let lineRange = selection.range(at: rangeIndex, on: page)
            guard lineRange.location != NSNotFound,
                  NSMaxRange(lineRange) <= source.length
            else { continue }
            let lineText = source.substring(with: lineRange)
            let localRange = NSRange(
                location: 0,
                length: (lineText as NSString).length
            )
            for match in expression?.matches(
                in: lineText,
                range: localRange
            ) ?? [] {
                let absoluteRange = NSRange(
                    location: lineRange.location + match.range.location,
                    length: match.range.length
                )
                guard let wordSelection = page.selection(
                    for: absoluteRange
                ) else { continue }
                let bounds = wordSelection.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                words.append(
                    (
                        source.substring(with: absoluteRange),
                        bounds
                    )
                )
            }
        }
        words.sort { $0.bounds.minX < $1.bounds.minX }
        guard words.count >= 2 else { return [] }

        let largeGap = max(14, lineHeight * 1.35)
        var cells: [DOCXCellCandidate] = []
        var text = words[0].text
        var bounds = words[0].bounds
        for word in words.dropFirst() {
            let gap = word.bounds.minX - bounds.maxX
            if gap >= largeGap {
                cells.append(
                    DOCXCellCandidate(text: text, bounds: bounds)
                )
                text = word.text
                bounds = word.bounds
            } else {
                text += " " + word.text
                bounds = bounds.union(word.bounds)
            }
        }
        cells.append(DOCXCellCandidate(text: text, bounds: bounds))
        return cells.count >= 2 ? cells : []
    }

    func tableRowsAlign(
        _ first: DOCXLine,
        _ candidate: DOCXLine,
        pageWidth: CGFloat
    ) -> Bool {
        guard first.cells.count == candidate.cells.count,
              first.cells.count >= 2
        else { return false }
        let tolerance = max(16, pageWidth * 0.035)
        return zip(first.cells, candidate.cells).allSatisfy {
            abs($0.bounds.minX - $1.bounds.minX) <= tolerance
        }
    }

    func table(
        from lines: [DOCXLine],
        pageBounds: CGRect
    ) -> DOCXTable {
        let columnCount = lines.map(\.cells.count).max() ?? 1
        let columnStarts = (0..<columnCount).map { column -> CGFloat in
            let values = lines.compactMap {
                $0.cells.indices.contains(column)
                    ? $0.cells[column].bounds.minX
                    : nil
            }
            return values.reduce(0, +) / CGFloat(max(1, values.count))
        }
        let rightEdge = lines
            .compactMap { $0.cells.last?.bounds.maxX }
            .max() ?? pageBounds.maxX
        let rawWidths = (0..<columnCount).map { column -> CGFloat in
            let next = column + 1 < columnStarts.count
                ? columnStarts[column + 1]
                : rightEdge
            return max(20, next - columnStarts[column])
        }
        let widthTotal = rawWidths.reduce(0, +)
        let wordWidth = 9_360
        let columnWidths = rawWidths.map {
            max(480, Int(($0 / max(1, widthTotal) * CGFloat(wordWidth)).rounded()))
        }
        let firstRowIsHeader = lines.first?.isBold == true
        return DOCXTable(
            rows: lines.enumerated().map { rowIndex, line in
                DOCXTableRow(
                    cells: line.cells.map {
                        DOCXTableCell(
                            text: $0.text,
                            isBold: rowIndex == 0 && firstRowIsHeader
                        )
                    },
                    repeatsAsHeader: rowIndex == 0 && firstRowIsHeader
                )
            },
            columnWidths: columnWidths
        )
    }

    func startsNewParagraph(
        _ line: DOCXLine,
        after previous: DOCXLine,
        paragraphStart: DOCXLine,
        bodySize: CGFloat
    ) -> Bool {
        if looksLikeListItem(line.text) || hasFieldLabel(line.text) {
            return true
        }
        if looksLikeListItem(paragraphStart.text),
           line.bounds.minX <= paragraphStart.bounds.minX + 2 {
            return true
        }
        let baselineDistance = abs(
            previous.bounds.midY - line.bounds.midY
        )
        let visualGap = baselineDistance
            - (previous.bounds.height + line.bounds.height) / 2
        if visualGap > max(5, bodySize * 0.62) {
            return true
        }
        if line.bounds.midY > previous.bounds.midY + bodySize {
            return true
        }
        let sizeChange = abs(line.fontSize - previous.fontSize)
        if sizeChange > max(2.5, bodySize * 0.2) {
            return true
        }
        let indentChange = abs(
            line.bounds.minX - paragraphStart.bounds.minX
        )
        if indentChange > max(18, bodySize * 1.6),
           endsParagraph(previous.text) {
            return true
        }
        if isHeading(previous, bodySize: bodySize) {
            return true
        }
        return false
    }

    func paragraph(
        from lines: [DOCXLine],
        bodySize: CGFloat,
        pageBounds: CGRect,
        listBaseX: CGFloat? = nil
    ) -> DOCXParagraph? {
        guard let first = lines.first else { return nil }
        let text = joinedParagraphText(lines.map(\.text))
        guard !text.isEmpty else { return nil }

        let size = median(lines.map(\.fontSize))
        let boldCount = lines.filter(\.isBold).count
        let italicCount = lines.filter(\.isItalic).count
        let bounds = lines.dropFirst().reduce(first.bounds) {
            $0.union($1.bounds)
        }
        let style: DOCXParagraphStyle
        if looksLikeListItem(text) {
            style = .list
        } else if size >= bodySize * 1.52 {
            style = .heading1
        } else if size >= bodySize * 1.22
                    || (
                        boldCount * 2 >= lines.count
                            && text.count <= 140
                    ) {
            style = .heading2
        } else {
            style = .body
        }
        return DOCXParagraph(
            text: text,
            style: style,
            isBold: boldCount * 2 >= lines.count,
            isItalic: italicCount * 2 >= lines.count,
            fontSize: min(max(size, 8), 36),
            alignment: style == .list ? .left : inferredAlignment(
                bounds: bounds,
                pageBounds: pageBounds
            ),
            listIndentTwips: style == .list
                ? max(0, Int(((first.bounds.minX - (listBaseX ?? pageBounds.minX)) * 20).rounded()))
                : nil
        )
    }

    func fallbackParagraphs(
        from text: String
    ) -> [DOCXParagraph] {
        let normalized = text.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        ).replacingOccurrences(of: "\r", with: "\n")
        var groups: [[String]] = []
        var current: [String] = []
        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || hasFieldLabel(line) || looksLikeListItem(line) {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            }
            if !line.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups.map {
            let value = joinedParagraphText($0)
            return DOCXParagraph(
                text: value,
                style: looksLikeListItem(value) ? .list : .body,
                isBold: false,
                isItalic: false,
                fontSize: 11,
                alignment: .left
            )
        }.filter { !$0.text.isEmpty }
    }

    private func hasFieldLabel(_ text: String) -> Bool {
        guard let separator = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return hasSpacedEastAsianLabel(text)
        }
        let label = text[..<separator].trimmingCharacters(in: .whitespaces)
        let value = text[text.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 48, !value.isEmpty,
              label.split(whereSeparator: \.isWhitespace).count <= 6,
              label.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !label.contains(where: { ".,;!?。；！？/@".contains($0) }),
              !value.hasPrefix("//"),
              !["http", "https", "mailto", "tel", "file", "urn"].contains(label.lowercased())
        else { return false }
        return true
    }

    private func hasSpacedEastAsianLabel(_ text: String) -> Bool {
        // Some PDFs map full-width punctuation to whitespace. Preserve the
        // field boundary without inventing a missing character.
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, (2...8).contains(parts[0].count) else {
            return false
        }
        return parts[0].precomposedStringWithCompatibilityMapping.unicodeScalars.allSatisfy {
            isEastAsianText($0) && CharacterSet.letters.contains($0)
        }
    }

    private func joinedParagraphText(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            guard !line.isEmpty else { continue }
            if result.isEmpty {
                result = line
            } else if result.hasSuffix("\u{00ad}") {
                result.removeLast()
                result += line
            } else if result.hasSuffix("-"), line.first?.isLowercase == true {
                // A visible hyphen may be semantic (for example, "non-compete").
                result += line
            } else if let last = result.unicodeScalars.last,
                      let first = line.unicodeScalars.first,
                      isEastAsianText(last), isEastAsianText(first) {
                result += line
            } else {
                result += " " + line
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isEastAsianText(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF01...0xFF60,
             0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    func inferredAlignment(
        bounds: CGRect,
        pageBounds: CGRect
    ) -> DOCXAlignment {
        guard pageBounds.width > 0 else { return .left }
        let left = bounds.minX - pageBounds.minX
        let right = pageBounds.maxX - bounds.maxX
        if abs(left - right) <= pageBounds.width * 0.055,
           bounds.width < pageBounds.width * 0.82 {
            return .center
        }
        if right < pageBounds.width * 0.1,
           left > right * 1.8 {
            return .right
        }
        return .left
    }

    func isHeading(
        _ line: DOCXLine,
        bodySize: CGFloat
    ) -> Bool {
        line.fontSize >= bodySize * 1.22
            || (line.isBold && line.text.count <= 140)
    }

    func looksLikeListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.range(
            of: #"^(?:[•◦▪*-](?:\s|$)|\(?\d+(?:\.\d+)*[.)](?!\d)|[A-Za-z][.)](?:\s|$)|[ivxlcdmIVXLCDM]{2,}[.)](?:\s|$))"#,
            options: .regularExpression
        ) != nil
    }

    func endsParagraph(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?;:。！？；：".contains(last)
    }

    func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 11 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func fontIsBold(_ font: DOCXPlatformFont) -> Bool {
#if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
#else
        font.fontDescriptor.symbolicTraits.contains(.bold)
#endif
    }

    private func fontIsItalic(_ font: DOCXPlatformFont) -> Bool {
#if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
#else
        font.fontDescriptor.symbolicTraits.contains(.italic)
#endif
    }

    private func pageContainsEmbeddedImage(_ page: CGPDFPage) -> Bool {
        guard let pageDictionary = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            pageDictionary,
            "Resources",
            &resources
        ), let resources else { return false }

        func containsImage(
            resources: CGPDFDictionaryRef,
            depth: Int
        ) -> Bool {
            guard depth <= 3 else { return false }
            var xObjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(
                resources,
                "XObject",
                &xObjects
            ), let xObjects else { return false }
            var found = false
            CGPDFDictionaryApplyBlock(
                xObjects,
                { key, _, _ in
                    var stream: CGPDFStreamRef?
                    guard CGPDFDictionaryGetStream(
                        xObjects,
                        key,
                        &stream
                    ), let stream,
                          let dictionary = CGPDFStreamGetDictionary(stream)
                    else { return true }
                    var subtype: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetName(
                        dictionary,
                        "Subtype",
                        &subtype
                    ), let subtype
                    else { return true }
                    let name = String(cString: subtype)
                    if name == "Image" {
                        found = true
                        return false
                    }
                    if name == "Form" {
                        var nestedResources: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(
                            dictionary,
                            "Resources",
                            &nestedResources
                        ), let nestedResources,
                           containsImage(
                               resources: nestedResources,
                               depth: depth + 1
                           ) {
                            found = true
                            return false
                        }
                    }
                    return true
                },
                nil
            )
            return found
        }

        return containsImage(resources: resources, depth: 0)
    }

    private func pageVisualReference(
        page: PDFPage,
        geometry: PDFOfficePageGeometry,
        pageIndex: Int,
        relationshipIndex: Int,
        longestEdge: CGFloat,
        compressionQuality: CGFloat,
        maximumByteCount: Int,
        priority: DOCXVisualReferencePriority
    ) -> DOCXVisualReferenceOutcome {
        let size = geometry.displaySize
        let attempts: [(edge: CGFloat, quality: CGFloat)] = [
            (longestEdge, compressionQuality),
            (
                max(720, longestEdge * 0.76),
                min(0.7, compressionQuality)
            ),
            (
                max(560, longestEdge * 0.56),
                min(0.58, compressionQuality)
            ),
            (
                max(420, longestEdge * 0.42),
                min(0.46, compressionQuality)
            )
        ]
        var encodedAnyAttempt = false
        for (index, attempt) in attempts.enumerated() {
            guard !Task.isCancelled else {
                return .skipped(.renderFailed)
            }
            let data: Data? = autoreleasepool {
                let scale = attempt.edge
                    / max(size.width, size.height)
                let image = page.thumbnail(
                    of: CGSize(
                        width: max(1, size.width * scale),
                        height: max(1, size.height * scale)
                    ),
                    for: .cropBox
                )
#if canImport(UIKit)
                return image.jpegData(
                    compressionQuality: attempt.quality
                )
#else
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff)
                else {
                    return nil
                }
                return bitmap.representation(
                    using: .jpeg,
                    properties: [
                        .compressionFactor: attempt.quality
                    ]
                )
#endif
            }
            if let data,
               !data.isEmpty {
                encodedAnyAttempt = true
                if data.count <= maximumByteCount {
                    let maximumWidth = 5_943_600.0
                    let maximumHeight = 7_315_200.0
                    let emuScale = min(
                        maximumWidth / Double(size.width),
                        maximumHeight / Double(size.height)
                    )
                    let image = DOCXImage(
                        relationshipID: "rId\(relationshipIndex)",
                        fileName: "page-visual-\(pageIndex + 1).jpg",
                        data: data,
                        widthEMU: Int(Double(size.width) * emuScale),
                        heightEMU: Int(Double(size.height) * emuScale),
                        description:
                            "Original appearance of PDF page \(pageIndex + 1)"
                    )
                    return .accepted(
                        DOCXVisualReferenceResult(
                            image: image,
                            priority: priority,
                            attemptCount: index + 1,
                            acceptedQualityPercent:
                                Int((attempt.quality * 100).rounded()),
                            acceptedLongestEdge:
                                Int(attempt.edge.rounded()),
                            byteCount: data.count
                        )
                    )
                }
            }
        }
        return .skipped(
            encodedAnyAttempt ? .pageBudgetExceeded : .renderFailed
        )
    }

    func wordPageLayout(
        for geometry: PDFOfficePageGeometry
    ) -> DOCXPageLayout {
        let longEdge = 15_840.0
        let minimumShortEdge = 7_200.0
        let ratio = min(
            max(Double(geometry.aspectRatio), 0.35),
            2.85
        )
        if ratio >= 1 {
            return DOCXPageLayout(
                widthTwips: Int(longEdge),
                heightTwips: Int(
                    max(minimumShortEdge, longEdge / ratio)
                        .rounded()
                ),
                isLandscape: true
            )
        }
        return DOCXPageLayout(
            widthTwips: Int(
                max(minimumShortEdge, longEdge * ratio)
                    .rounded()
            ),
            heightTwips: Int(longEdge),
            isLandscape: false
        )
    }

    private func makePackage(
        title: String,
        pages: [DOCXPage],
        metrics: DOCXReconstructionMetrics,
        destination: URL,
        byteProgress: @escaping PDFByteProgressHandler
    ) throws -> Int64 {
        let images = pages.compactMap(\.visualReference)
        var archive = OOXMLArchive()
        try archive.add(
            path: "[Content_Types].xml",
            string: contentTypesXML
        )
        try archive.add(path: "_rels/.rels", string: rootRelationshipsXML)
        try archive.add(
            path: "docProps/core.xml",
            string: corePropertiesXML(title: title)
        )
        try archive.add(
            path: "docProps/app.xml",
            string: appPropertiesXML
        )
        try archive.add(
            path: "docProps/custom.xml",
            string: customPropertiesXML(metrics: metrics)
        )
        do {
            let documentXML = try wordDocumentXML(pages: pages)
            guard documentXML.contains("<w:document"),
                  documentXML.contains("<w:body>")
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Word package structure is incomplete"
                )
            }
            try archive.add(
                path: "word/document.xml",
                string: documentXML
            )
        }
        try archive.add(
            path: "word/styles.xml",
            string: stylesXML
        )
        try archive.add(
            path: "word/settings.xml",
            string: settingsXML
        )
        try archive.add(
            path: "word/_rels/document.xml.rels",
            string: documentRelationshipsXML(images: images)
        )
        for image in images {
            try archive.add(
                path: "word/media/\(image.fileName)",
                data: image.data
            )
        }
        let writtenBytes = try archive.write(
            to: destination,
            profile: .word,
            byteProgress: byteProgress
        )
        guard writtenBytes > 4 else {
            throw PaperPathError.outputVerificationFailed(
                "the Word package structure is incomplete"
            )
        }
        return writtenBytes
    }

    func wordDocumentXML(
        pages: [DOCXPage],
        maximumUTF8Bytes: Int =
            DOCXContentBudget.maximumDocumentXMLBytes
    ) throws -> String {
        let prefix = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>
        """
        let suffix = "</w:body></w:document>"
        guard maximumUTF8Bytes >= prefix.utf8.count + suffix.utf8.count else {
            throw PaperPathError.insufficientSelection(
                "The detected Word content exceeds the on-device export budget."
            )
        }
        var document = prefix
        document.reserveCapacity(
            min(
                maximumUTF8Bytes,
                max(prefix.utf8.count, pages.count * 1_024)
            )
        )
        var byteCount = prefix.utf8.count

        func append(_ fragment: String) throws {
            let fragmentByteCount = fragment.utf8.count
            let (nextByteCount, overflow) = byteCount
                .addingReportingOverflow(fragmentByteCount)
            guard !overflow,
                  nextByteCount <= maximumUTF8Bytes
            else {
                throw PaperPathError.insufficientSelection(
                    "The detected Word content exceeds the on-device export budget."
                )
            }
            document.append(fragment)
            byteCount = nextByteCount
        }

        for (pagePosition, page) in pages.enumerated() {
            try Task.checkCancellation()
            for block in page.blocks {
                try append(
                    blockXML(
                        block,
                        pageBreakBefore: false
                    )
                )
            }
            if let image = page.visualReference {
                try append(
                    imageXML(
                        image,
                        documentID: page.pageIndex + 1,
                        pageBreakBefore: false
                    )
                )
            }
            if pagePosition + 1 < pages.count {
                try append(
                    """
                    <w:p><w:pPr>\(sectionPropertiesXML(page.layout, startsNextPage: true))</w:pPr></w:p>
                    """
                )
            }
        }
        try append(
            sectionPropertiesXML(
                pages.last?.layout ?? DOCXPageLayout.letterPortrait,
                startsNextPage: false
            )
        )
        try append(suffix)
        return document
    }

    func sectionPropertiesXML(
        _ layout: DOCXPageLayout,
        startsNextPage: Bool
    ) -> String {
        let type = startsNextPage
            ? "<w:type w:val=\"nextPage\"/>"
            : ""
        let orientation = layout.isLandscape
            ? " w:orient=\"landscape\""
            : ""
        return """
        <w:sectPr>\(type)<w:pgSz w:w="\(layout.widthTwips)" w:h="\(layout.heightTwips)"\(orientation)/><w:pgMar w:top="900" w:right="900" w:bottom="900" w:left="900" w:header="540" w:footer="540" w:gutter="0"/></w:sectPr>
        """
    }

    func blockXML(
        _ block: DOCXBlock,
        pageBreakBefore: Bool
    ) -> String {
        switch block {
        case .paragraph(let paragraph):
            return paragraphXML(
                paragraph,
                pageBreakBefore: pageBreakBefore
            )
        case .table(let table):
            let pageBreak = pageBreakBefore
                ? "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                : ""
            return pageBreak + tableXML(table)
        }
    }

    func paragraphXML(
        _ paragraph: DOCXParagraph,
        pageBreakBefore: Bool
    ) -> String {
        let style = paragraph.style.wordStyle
        let alignment = paragraph.alignment.rawValue
        let pageBreak = pageBreakBefore ? "<w:pageBreakBefore/>" : ""
        let fontSize = Int((paragraph.fontSize * 2).rounded())
        let bold = paragraph.isBold ? "<w:b/>" : ""
        let italic = paragraph.isItalic ? "<w:i/>" : ""
        let indentation = paragraph.listIndentTwips.map {
            "<w:ind w:left=\"\($0 + 360)\" w:hanging=\"360\"/>"
        } ?? ""
        return """
        <w:p><w:pPr><w:pStyle w:val="\(style)"/><w:jc w:val="\(alignment)"/><w:spacing w:after="120" w:line="276" w:lineRule="auto"/>\(indentation)\(pageBreak)</w:pPr><w:r><w:rPr>\(bold)\(italic)<w:sz w:val="\(fontSize)"/><w:szCs w:val="\(fontSize)"/></w:rPr><w:t xml:space="preserve">\(xmlEscaped(paragraph.text))</w:t></w:r></w:p>
        """
    }

    func tableXML(_ table: DOCXTable) -> String {
        let grid = table.columnWidths.map {
            "<w:gridCol w:w=\"\($0)\"/>"
        }.joined()
        let rows = table.rows.map { row in
            let header = row.repeatsAsHeader
                ? "<w:tblHeader/><w:cantSplit/>"
                : "<w:cantSplit/>"
            let cells = row.cells.enumerated().map { index, cell in
                let width = table.columnWidths.indices.contains(index)
                    ? table.columnWidths[index]
                    : 1_800
                let bold = cell.isBold ? "<w:b/>" : ""
                return """
                <w:tc><w:tcPr><w:tcW w:w="\(width)" w:type="dxa"/><w:tcMar><w:top w:w="80" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="80" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tcMar></w:tcPr><w:p><w:pPr><w:spacing w:after="0"/></w:pPr><w:r><w:rPr>\(bold)</w:rPr><w:t xml:space="preserve">\(xmlEscaped(cell.text))</w:t></w:r></w:p></w:tc>
                """
            }.joined()
            return "<w:tr><w:trPr>\(header)</w:trPr>\(cells)</w:tr>"
        }.joined()
        return """
        <w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="9360" w:type="dxa"/><w:tblLayout w:type="fixed"/><w:tblBorders><w:top w:val="single" w:sz="4" w:color="B8BDC6"/><w:left w:val="single" w:sz="4" w:color="B8BDC6"/><w:bottom w:val="single" w:sz="4" w:color="B8BDC6"/><w:right w:val="single" w:sz="4" w:color="B8BDC6"/><w:insideH w:val="single" w:sz="4" w:color="D8DCE3"/><w:insideV w:val="single" w:sz="4" w:color="D8DCE3"/></w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(rows)</w:tbl>
        """
    }

    func imageXML(
        _ image: DOCXImage,
        documentID: Int,
        pageBreakBefore: Bool
    ) -> String {
        let pageBreak = pageBreakBefore ? "<w:pageBreakBefore/>" : ""
        return """
        <w:p><w:pPr><w:spacing w:before="180" w:after="120"/><w:jc w:val="center"/>\(pageBreak)</w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(documentID)" name="Page \(documentID)" descr="\(xmlEscaped(image.description))"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(documentID)" name="\(xmlEscaped(image.fileName))"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(image.relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    func corePropertiesXML(title: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscaped(title))</dc:title><dc:creator>PaperPath</dc:creator><cp:lastModifiedBy>PaperPath</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified></cp:coreProperties>
        """
    }

    func xmlEscaped(_ value: String) -> String {
        ooxmlEscaped(value)
    }

    private var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/></Types>
        """
    }

    private var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/></Relationships>
        """
    }

    func documentRelationshipsXML(
        images: [DOCXImage]
    ) -> String {
        let imageRelationships = images.map {
            """
            <Relationship Id="\($0.relationshipID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\($0.fileName)"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(imageRelationships)</Relationships>
        """
    }

    private var appPropertiesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>PaperPath</Application><AppVersion>1.0</AppVersion></Properties>
        """
    }

    func customPropertiesXML(
        metrics: DOCXReconstructionMetrics
    ) -> String {
        let officePortfolio = metrics.officePortfolio
        let wordPlan = officePortfolio.plan(for: .wordDocument)
        let leadSignal = officePortfolio.preflightLeadSignal
        func preflightValue(_ id: String) -> String {
            guard let signal = officePortfolio.preflightSignals.first(
                where: { $0.id == id }
            ) else { return "missing" }
            return "\(signal.readiness.rawValue): \(signal.value) · \(signal.detail)"
        }
        func property(
            pid: Int,
            name: String,
            value: String
        ) -> String {
            """
            <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="\(pid)" name="\(xmlEscaped(name))"><vt:lpwstr>\(xmlEscaped(value))</vt:lpwstr></property>
            """
        }
        let properties = [
            property(
                pid: 2,
                name: "PaperPathExportMode",
                value: "Local DOCX reconstruction"
            ),
            property(
                pid: 3,
                name: "PaperPathReconstructionSummary",
                value: metrics.reconstructionSummary
            ),
            property(
                pid: 4,
                name: "PaperPathSourcePages",
                value: "\(metrics.sourcePageCount)"
            ),
            property(
                pid: 5,
                name: "PaperPathExportedPages",
                value: "\(metrics.exportedPageCount)"
            ),
            property(
                pid: 6,
                name: "PaperPathParagraphBlocks",
                value: "\(metrics.paragraphCount)"
            ),
            property(
                pid: 7,
                name: "PaperPathTableBlocks",
                value: "\(metrics.tableCount)"
            ),
            property(
                pid: 8,
                name: "PaperPathVisualReferences",
                value: "\(metrics.visualReferenceCount)"
            ),
            property(
                pid: 9,
                name: "PaperPathVisualReferenceBytes",
                value: "\(metrics.visualReferenceByteCount)"
            ),
            property(
                pid: 10,
                name: "PaperPathFallbackTextPages",
                value: "\(metrics.fallbackPageCount)"
            ),
            property(
                pid: 11,
                name: "PaperPathSkippedVisualReferences",
                value: "\(metrics.skippedVisualReferenceCount)"
            ),
            property(
                pid: 12,
                name: "PaperPathVisualBudgetMode",
                value: metrics.visualBudgetMode.storageValue
            ),
            property(
                pid: 13,
                name: "PaperPathVisualLongestEdge",
                value: "\(metrics.visualLongestEdge)"
            ),
            property(
                pid: 14,
                name: "PaperPathVisualCompressionPercent",
                value:
                    "\(metrics.visualCompressionQualityPercent)"
            ),
            property(
                pid: 15,
                name: "PaperPathVisualMaxBytesPerPage",
                value: "\(metrics.visualMaximumBytesPerPage)"
            ),
            property(
                pid: 16,
                name: "PaperPathVisualBudgetSkips",
                value: "\(metrics.visualBudgetSkipCount)"
            ),
            property(
                pid: 17,
                name: "PaperPathVisualPageBudgetExceeded",
                value: "\(metrics.visualPageBudgetExceededCount)"
            ),
            property(
                pid: 18,
                name: "PaperPathVisualRenderFailures",
                value: "\(metrics.visualRenderFailedCount)"
            ),
            property(
                pid: 19,
                name: "PaperPathVisualCompressionFallbacks",
                value: "\(metrics.visualCompressionFallbackCount)"
            ),
            property(
                pid: 20,
                name: "PaperPathVisualAcceptedMinQuality",
                value: metrics.acceptedMinimumQualitySummary
            ),
            property(
                pid: 21,
                name: "PaperPathVisualAcceptedSmallestEdge",
                value: metrics.acceptedSmallestEdgeSummary
            ),
            property(
                pid: 22,
                name: "PaperPathVisualAcceptedMaxBytes",
                value: "\(metrics.visualAcceptedMaximumByteCount)"
            ),
            property(
                pid: 23,
                name: "PaperPathVisualCriticalAnchors",
                value: "\(metrics.visualCriticalAnchorCount)"
            ),
            property(
                pid: 24,
                name: "PaperPathVisualImageAnchors",
                value: "\(metrics.visualImageAnchorCount)"
            ),
            property(
                pid: 25,
                name: "PaperPathVisualTableAnchors",
                value: "\(metrics.visualTableAnchorCount)"
            ),
            property(
                pid: 26,
                name: "PaperPathVisualCandidatePages",
                value: "\(metrics.visualCandidatePageCount)"
            ),
            property(
                pid: 27,
                name: "PaperPathVisualCriticalCandidates",
                value: "\(metrics.visualCriticalCandidateCount)"
            ),
            property(
                pid: 28,
                name: "PaperPathVisualImageCandidates",
                value: "\(metrics.visualImageCandidateCount)"
            ),
            property(
                pid: 29,
                name: "PaperPathVisualTableCandidates",
                value: "\(metrics.visualTableCandidateCount)"
            ),
            property(
                pid: 30,
                name: "PaperPathVisualBudgetWindowLimited",
                value: "\(metrics.visualBudgetWindowLimitedCount)"
            ),
            property(
                pid: 31,
                name: "PaperPathVisualMinPageBudget",
                value: metrics.minimumPageBudgetSummary
            ),
            property(
                pid: 32,
                name: "PaperPathVisualMaxPageBudget",
                value: metrics.maximumPageBudgetSummary
            ),
            property(
                pid: 33,
                name: "PaperPathOfficeRoute",
                value: officePortfolio.decisionLine
            ),
            property(
                pid: 34,
                name: "PaperPathOfficeDOCXScore",
                value: "\(wordPlan.compositeScore)"
            ),
            property(
                pid: 35,
                name: "PaperPathOfficeDOCXReadiness",
                value: wordPlan.readiness.rawValue
            ),
            property(
                pid: 36,
                name: "PaperPathOfficePreflightSummary",
                value: metrics.embeddedPreflightSummary
            ),
            property(
                pid: 37,
                name: "PaperPathOfficePreflightDigest",
                value: metrics.embeddedPreflightSignalDigest
            ),
            property(
                pid: 38,
                name: "PaperPathOfficeLeadRisk",
                value: leadSignal.map {
                    "\($0.readiness.rawValue): \($0.detail)"
                } ?? "none"
            ),
            property(
                pid: 39,
                name: "PaperPathOfficeRights",
                value: preflightValue("rights")
            ),
            property(
                pid: 40,
                name: "PaperPathOfficeStructure",
                value: preflightValue("structure")
            ),
            property(
                pid: 41,
                name: "PaperPathOfficeVisual",
                value: preflightValue("visual")
            ),
            property(
                pid: 42,
                name: "PaperPathOfficePackage",
                value: preflightValue("package")
            ),
            property(
                pid: 43,
                name: "PaperPathOfficeAnchorPolicy",
                value: officePortfolio.visualBudgetPlan.anchorPolicy.rawValue
            ),
            property(
                pid: 44,
                name: "PaperPathOfficeBudgetPressure",
                value: officePortfolio.visualBudgetPlan.budgetPressure.rawValue
            ),
            property(
                pid: 45,
                name: "PaperPathOfficeChunkPlan",
                value: officePortfolio.visualBudgetPlan.chunkSummary
            ),
            property(
                pid: 46,
                name: "PaperPathStructuredPages",
                value: "\(metrics.structuredPageCount)"
            ),
            property(
                pid: 47,
                name: "PaperPathPageYieldPercent",
                value: "\(metrics.pageYieldPercent)"
            ),
            property(
                pid: 48,
                name: "PaperPathStructuredCoveragePercent",
                value: "\(metrics.structuredCoveragePercent)"
            ),
            property(
                pid: 49,
                name: "PaperPathVisualAnchorHitPercent",
                value: "\(metrics.visualAnchorHitPercent)"
            ),
            property(
                pid: 50,
                name: "PaperPathVisualBudgetUse",
                value: metrics.visualBudgetUseSummary
            ),
            property(
                pid: 51,
                name: "PaperPathVisualSkipReasons",
                value: metrics.visualSkipReasonSummary
            ),
            property(
                pid: 52,
                name: "PaperPathQualityFallbacks",
                value: metrics.qualityFallbackSummary
            ),
            property(
                pid: 53,
                name: "PaperPathOfficeRouteConfidence",
                value: officePortfolio.routeConfidence.rawValue
            ),
            property(
                pid: 54,
                name: "PaperPathOfficeProductionSLA",
                value: officePortfolio.productionSLA.rawValue
            ),
            property(
                pid: 55,
                name: "PaperPathOfficeRouteRank",
                value: officePortfolio.routeRankLine
            ),
            property(
                pid: 56,
                name: "PaperPathOfficeDecisionDeck",
                value: officePortfolio.decisionDeckLine
            ),
            property(
                pid: 57,
                name: "PaperPathOfficeBudgetContract",
                value: officePortfolio.visualBudgetPlan.pressureContract
            ),
            property(
                pid: 58,
                name: "PaperPathOfficeMemoryGuard",
                value: officePortfolio.visualBudgetPlan.memoryGuardSummary
            ),
            property(
                pid: 59,
                name: "PaperPathOfficeRouteAudit",
                value: metrics.routeDecisionSummary
            ),
            property(
                pid: 60,
                name: "PaperPathPrivacy",
                value: "Generated on device from the private working copy"
            ),
            property(
                pid: 61,
                name: "PaperPathAuditSchema",
                value: "Office Production Audit V29"
            ),
            property(
                pid: 62,
                name: "PaperPathContentNotices",
                value: officeContentNoticeDigest(metrics.runtimeEvidence.contentNotices ?? [])
            )
        ].joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\(properties)</Properties>
        """
    }

    private var settingsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="180" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr></w:style></w:styles>
        """
    }
}

struct XLSXExportService: Sendable {
    private struct Cell: Sendable {
        let text: String
        let numericValue: String?
        let isBold: Bool
    }

    private struct Row: Sendable {
        let cells: [Cell]
    }

    private struct PositionedText {
        let text: String
        let bounds: CGRect
        let isBold: Bool
    }

    private struct Sheet: Sendable {
        let name: String
        let rows: [Row]
        let isLandscape: Bool
    }

    func export(
        sourceURL: URL,
        destination: URL,
        textIndex: DocumentTextIndex?,
        title: String,
        profile: DocumentProfile? = nil,
        byteProgress: @escaping PDFByteProgressHandler = { _ in },
        progress: @escaping PDFProgressHandler
    ) throws -> PDFOfficeRuntimeEvidence {
        let sourceSize = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceSize <= 512 * 1_024 * 1_024 else {
            throw PaperPathError.fileTooLarge
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= 1_000 else {
            throw PaperPathError.insufficientSelection(
                "Excel export supports up to 1,000 PDF pages per workbook."
            )
        }

        let indexedPages = officeIndexedTextByPage(textIndex)
        var sheets: [Sheet] = []
        sheets.reserveCapacity(document.pageCount)
        var totalCellCount = 0
        var totalCharacterCount = 0
        var emptyPageIndices: [Int] = []
        var inferredPageIndices: [Int] = []

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            guard let geometry = PDFOfficePageGeometry(page: page) else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) has invalid dimensions"
                )
            }
            guard (page.string?.utf8.count ?? 0) <= 2_000_000 else {
                throw PaperPathError.fileTooLarge
            }
            var usedBoundaries = false
            var rows = rows(from: page, usedBoundaries: &usedBoundaries)
            if rows.isEmpty,
               let indexedText = indexedPages[pageIndex] {
                rows = fallbackRows(from: indexedText)
            }
            if rows.isEmpty {
                emptyPageIndices.append(pageIndex)
            } else {
                if !usedBoundaries { inferredPageIndices.append(pageIndex) }
                totalCellCount += rows.reduce(0) {
                    $0 + $1.cells.count
                }
                totalCharacterCount += rows.reduce(0) { result, row in
                    result + row.cells.reduce(0) {
                        $0 + $1.text.count
                    }
                }
                guard rows.allSatisfy({ $0.cells.count <= 16_384 }),
                      totalCellCount <= 500_000,
                      totalCharacterCount <= 12_000_000
                else {
                    throw PaperPathError.insufficientSelection(
                        "The detected workbook exceeds the on-device export budget."
                    )
                }
            }
            sheets.append(
                Sheet(
                    name: "Page \(pageIndex + 1)",
                    rows: rows,
                    isLandscape: geometry.isLandscape
                )
            )
            progress(
                0.62 * Double(pageIndex + 1)
                    / Double(max(1, document.pageCount))
            )
        }
        guard !sheets.isEmpty else {
            throw PaperPathError.missingRecognizedText
        }

        let officePortfolio = PDFOfficeExportPortfolio(
            profile: profile ?? fallbackProfile(
                document: document,
                sourceSize: Int64(sourceSize)
            )
        )
        let auditRuntime = PDFOfficeRuntimeEvidence(
            sourcePageCount: document.pageCount,
            outputPageCount: sheets.count,
            primaryUnitLabel: "cells",
            primaryUnitCount: totalCellCount,
            characterCount: totalCharacterCount,
            searchablePageCount: sheets.count - emptyPageIndices.count,
            assetCount: 0,
            assetByteCount: 0,
            assetBudgetByteCount: 0,
            assetCompressionFallbackCount: 0,
            assetMinimumQualityPercent: 0,
            contentNotices: PDFOfficeContentNotice.defaults(for: .excelWorkbook)
                + (emptyPageIndices.isEmpty ? [] : [
                    PDFOfficeContentNotice(kind: .pagesWithoutText, pageIndices: emptyPageIndices)
                ])
                + (inferredPageIndices.isEmpty ? [] : [
                    PDFOfficeContentNotice(kind: .inferredTableLayout, pageIndices: inferredPageIndices)
                ])
        )
        _ = try makePackage(
            title: title,
            sheets: sheets,
            auditXML: officeAuditPropertiesXML(
                format: .excelWorkbook,
                portfolio: officePortfolio,
                runtime: auditRuntime
            ),
            destination: destination,
            byteProgress: byteProgress
        )
        progress(0.88)
        progress(1)
        return auditRuntime
    }

    private func rows(from page: PDFPage, usedBoundaries: inout Bool) -> [Row] {
        guard let pageText = page.string,
              !pageText.isEmpty
        else { return [] }
        let source = pageText as NSString
        let expression = try? NSRegularExpression(pattern: "\\S+")
        let words: [PositionedText] = (expression?.matches(
            in: pageText, range: NSRange(location: 0, length: source.length)
        ) ?? []).compactMap { match in
            guard let selection = page.selection(for: match.range) else { return nil }
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0,
                  bounds.minX.isFinite, bounds.minY.isFinite
            else { return nil }
            return PositionedText(
                text: source.substring(with: match.range),
                bounds: bounds,
                isBold: selectionIsBold(selection)
            )
        }.sorted {
            if $0.bounds.midY != $1.bounds.midY {
                return $0.bounds.midY > $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        guard !words.isEmpty else { return [] }
        var lines: [[PositionedText]] = []
        for word in words {
            if let anchor = lines.last?.first,
               abs(anchor.bounds.midY - word.bounds.midY)
                    <= min(anchor.bounds.height, word.bounds.height) * 0.32 {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }
        let rulings = pdfOfficeTableRulings(in: page) ?? []
        let horizontal = rulings.filter { $0.height <= 3 && $0.width >= 24 }
        let vertical = rulings.filter { line in
            line.width <= 3 && line.height >= 12
                && horizontal.filter {
                    $0.minX - 2 <= line.midX && $0.maxX + 2 >= line.midX
                        && $0.midY >= line.minY - 2 && $0.midY <= line.maxY + 2
                }.count >= 2
        }
        let edges = clusteredCoordinates(vertical.map(\.midX))
        if edges.count >= 3, edges.count <= 65 {
            usedBoundaries = true
            // Boundaries, not text starts, keep right-aligned values under their headers.
            func column(_ word: PositionedText) -> Int {
                max(0, min(edges.count - 2,
                    edges.dropFirst().prefix { $0 < word.bounds.midX }.count))
            }
            let rowEdges = clusteredCoordinates(horizontal.filter {
                $0.minX <= edges[0] + 2 && $0.maxX >= edges[edges.count - 1] - 2
            }.map(\.midY))
            var mergedLines = lines
            // A centered row label may accompany a two-line value inside one ruled cell.
            for pair in zip(rowEdges, rowEdges.dropFirst()) {
                let indices = mergedLines.indices.filter { index in
                    let y = mergedLines[index][0].bounds.midY
                    return y > pair.0 && y < pair.1
                }
                guard indices.count >= 2, indices.count <= 3 else { continue }
                let selected = indices.flatMap { mergedLines[$0] }
                let firstColumnLines = indices.filter {
                    mergedLines[$0].contains { column($0) == 0 }
                }
                let height = selected.map(\.bounds.height).min() ?? 0
                guard firstColumnLines.count == 1, pair.1 - pair.0 <= height * 2.5,
                      selected.allSatisfy({
                          $0.bounds.midX > edges[0] && $0.bounds.midX < edges[edges.count - 1]
                      })
                else { continue }
                mergedLines[indices[0]] = selected
                for index in indices.dropFirst().reversed() { mergedLines.remove(at: index) }
            }
            return mergedLines.map { line in
                let y = line[0].bounds.midY
                if !vertical.contains(where: { y >= $0.minY - 2 && y <= $0.maxY + 2 }) {
                    return Row(cells: [makeCell(line)])
                }
                var columns = Array(repeating: [PositionedText](), count: edges.count - 1)
                for word in line { columns[column(word)].append(word) }
                return Row(cells: columns.map(makeCell))
            }
        }
        // Without rulings, infer stable column anchors across rows, including empty cells.
        let candidates = lines.map { line -> [PositionedText] in
            var cells: [PositionedText] = []
            for word in line.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                if let previous = cells.last,
                   word.bounds.minX - previous.bounds.maxX < max(10, word.bounds.height * 0.8) {
                    cells[cells.count - 1] = PositionedText(
                        text: previous.text + " " + word.text,
                        bounds: previous.bounds.union(word.bounds),
                        isBold: previous.isBold && word.isBold
                    )
                } else {
                    cells.append(word)
                }
            }
            return cells
        }
        let anchors = clusteredCoordinates(candidates.flatMap { row in
            row.map { numericValue(for: $0.text) == nil ? $0.bounds.minX : $0.bounds.maxX }
        }, tolerance: 6)
        guard anchors.count <= 64 else {
            return candidates.map { Row(cells: $0.map { makeCell([$0]) }) }
        }
        return candidates.map { line in
            var columns = Array(repeating: [PositionedText](), count: anchors.count)
            for cell in line {
                let x = numericValue(for: cell.text) == nil ? cell.bounds.minX : cell.bounds.maxX
                let index = anchors.indices.min { abs(anchors[$0] - x) < abs(anchors[$1] - x) } ?? 0
                columns[index].append(cell)
            }
            return Row(cells: columns.map(makeCell))
        }
    }

    private func clusteredCoordinates(_ values: [CGFloat], tolerance: CGFloat = 2) -> [CGFloat] {
        var groups: [[CGFloat]] = []
        for value in values.sorted() {
            if let first = groups.last?.first, value - first <= tolerance {
                groups[groups.count - 1].append(value)
            } else {
                groups.append([value])
            }
        }
        return groups.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    private func makeCell(_ words: [PositionedText]) -> Cell {
        let sorted = words.sorted {
            if $0.bounds.midY != $1.bounds.midY {
                return $0.bounds.midY > $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        var lines: [[PositionedText]] = []
        for word in sorted {
            if let anchor = lines.last?.first,
               abs(anchor.bounds.midY - word.bounds.midY)
                    <= min(anchor.bounds.height, word.bounds.height) * 0.32 {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }
        let ordered = lines.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
        var text = ""
        var previous: PositionedText?
        for word in ordered {
            if let previous {
                text += abs(previous.bounds.midY - word.bounds.midY) > word.bounds.height * 0.5 ? "\n" : " "
            }
            text += word.text
            previous = word
        }
        return Cell(text: text, numericValue: numericValue(for: text),
                    isBold: !words.isEmpty && words.allSatisfy(\.isBold))
    }

    private func fallbackRows(from text: String) -> [Row] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .compactMap { line -> Row? in
                let values = fallbackCells(from: line)
                guard !values.isEmpty else { return nil }
                return Row(
                    cells: values.map {
                        Cell(
                            text: $0,
                            numericValue: numericValue(for: $0),
                            isBold: false
                        )
                    }
                )
            }
    }

    private func fallbackCells(from line: String) -> [String] {
        if line.contains("\t") {
            return line.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        let expression = try? NSRegularExpression(
            pattern: " {2,}"
        )
        let matches = expression?.matches(
            in: line,
            range: range
        ) ?? []
        guard !matches.isEmpty else {
            let value = line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return value.isEmpty ? [] : [value]
        }
        var values: [String] = []
        var location = 0
        for match in matches {
            let valueRange = NSRange(
                location: location,
                length: match.range.location - location
            )
            let value = source.substring(with: valueRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values.append(value)
            location = NSMaxRange(match.range)
        }
        if location < source.length {
            let value = source.substring(
                from: location
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            values.append(value)
        }
        return values
    }

    private func selectionIsBold(
        _ selection: PDFSelection
    ) -> Bool {
        guard let attributed = selection.attributedString,
              attributed.length > 0
        else { return false }
        var boldCount = 0
        var fontCount = 0
        attributed.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let font = value as? DOCXPlatformFont else { return }
            fontCount += range.length
#if canImport(UIKit)
            if font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                boldCount += range.length
            }
#else
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                boldCount += range.length
            }
#endif
        }
        return fontCount > 0 && boldCount * 2 >= fontCount
    }

    private func numericValue(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count <= 24,
              trimmed.range(
                  of: #"^-?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count <= 15 else { return nil }
        let normalized = trimmed.replacingOccurrences(
            of: ",",
            with: ""
        )
        let magnitude = normalized.hasPrefix("-")
            ? normalized.dropFirst()
            : normalized[...]
        let integerPart = magnitude.split(separator: ".", maxSplits: 1).first ?? ""
        // Leading zeroes and explicit plus signs commonly identify accounts or phones.
        guard integerPart.count == 1 || integerPart.first != "0" else {
            return nil
        }
        return normalized
    }

    private func makePackage(
        title: String,
        sheets: [Sheet],
        auditXML: String,
        destination: URL,
        byteProgress: @escaping PDFByteProgressHandler
    ) throws -> Int64 {
        var archive = OOXMLArchive()
        try archive.add(
            path: "[Content_Types].xml",
            string: contentTypesXML(sheetCount: sheets.count)
        )
        try archive.add(
            path: "_rels/.rels",
            string: rootRelationshipsXML
        )
        try archive.add(
            path: "docProps/core.xml",
            string: corePropertiesXML(title: title)
        )
        try archive.add(
            path: "docProps/app.xml",
            string: appPropertiesXML(sheets: sheets)
        )
        try archive.add(
            path: "docProps/custom.xml",
            string: auditXML
        )
        try archive.add(
            path: "xl/workbook.xml",
            string: workbookXML(sheets: sheets)
        )
        try archive.add(
            path: "xl/_rels/workbook.xml.rels",
            string: workbookRelationshipsXML(
                sheetCount: sheets.count
            )
        )
        try archive.add(
            path: "xl/styles.xml",
            string: stylesXML
        )
        for (index, sheet) in sheets.enumerated() {
            try Task.checkCancellation()
            try archive.add(
                path: "xl/worksheets/sheet\(index + 1).xml",
                string: worksheetXML(sheet)
            )
        }
        let writtenBytes = try archive.write(
            to: destination,
            profile: .excel(sheetCount: sheets.count),
            byteProgress: byteProgress
        )
        guard writtenBytes > 4,
              !sheets.isEmpty
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Excel package structure is incomplete"
            )
        }
        return writtenBytes
    }

    private func worksheetXML(_ sheet: Sheet) -> String {
        let columnCount = sheet.rows.map {
            $0.cells.count
        }.max() ?? 1
        let widths = (0..<columnCount).map { column -> Double in
            let longest = sheet.rows.compactMap { row in
                row.cells.indices.contains(column)
                    ? row.cells[column].text.count
                    : nil
            }.max() ?? 8
            return min(48, max(10, Double(longest + 2)))
        }
        let columns = widths.enumerated().map { index, width in
            """
            <col min="\(index + 1)" max="\(index + 1)" width="\(width)" customWidth="1"/>
            """
        }.joined()
        let rows = sheet.rows.enumerated().map {
            rowIndex,
            row -> String in
            let cells = row.cells.enumerated().map {
                columnIndex,
                cell -> String in
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                let style = cell.isBold ? " s=\"1\"" : ""
                if let numericValue = cell.numericValue {
                    return """
                    <c r="\(reference)"\(style)><v>\(numericValue)</v></c>
                    """
                }
                return """
                <c r="\(reference)"\(style) t="inlineStr"><is><t xml:space="preserve">\(xmlEscaped(cell.text))</t></is></c>
                """
            }.joined()
            let lineCount = row.cells.enumerated().map { index, cell in
                let width = widths[index]
                return cell.text.components(separatedBy: "\n").reduce(0) {
                    $0 + max(1, Int(ceil(Double($1.count) / max(1, width - 2))))
                }
            }.max() ?? 1
            let height = min(409, max(15, lineCount * 15))
            return "<row r=\"\(rowIndex + 1)\" ht=\"\(height)\" customHeight=\"1\">\(cells)</row>"
        }.joined()
        let lastColumn = columnName(max(1, columnCount))
        let lastRow = max(1, sheet.rows.count)
        let orientation = sheet.isLandscape
            ? "landscape"
            : "portrait"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><dimension ref="A1:\(lastColumn)\(lastRow)"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>\(columns)</cols><sheetData>\(rows)</sheetData><printOptions horizontalCentered="1"/><pageMargins left="0.25" right="0.25" top="0.5" bottom="0.5" header="0.2" footer="0.2"/><pageSetup orientation="\(orientation)" fitToWidth="1" fitToHeight="0"/></worksheet>
        """
    }

    private func workbookXML(sheets: [Sheet]) -> String {
        let entries = sheets.enumerated().map { index, sheet in
            """
            <sheet name="\(xmlEscaped(sheet.name))" sheetId="\(index + 1)" r:id="rId\(index + 1)"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>\(entries)</sheets><calcPr calcId="191029"/></workbook>
        """
    }

    private func contentTypesXML(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            """
            <Override PartName="/xl/worksheets/sheet\($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/>\(sheets)</Types>
        """
    }

    private var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/></Relationships>
        """
    }

    private func workbookRelationshipsXML(
        sheetCount: Int
    ) -> String {
        let sheets = (1...sheetCount).map {
            """
            <Relationship Id="rId\($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\($0).xml"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheets)<Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/><family val="2"/></font><font><b/><sz val="11"/><name val="Arial"/><family val="2"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
    }

    private func corePropertiesXML(title: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscaped(title))</dc:title><dc:creator>PaperPath</dc:creator><cp:lastModifiedBy>PaperPath</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified></cp:coreProperties>
        """
    }

    private func appPropertiesXML(sheets: [Sheet]) -> String {
        let titles = sheets.map {
            "<vt:lpstr>\(xmlEscaped($0.name))</vt:lpstr>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>PaperPath</Application><HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>\(sheets.count)</vt:i4></vt:variant></vt:vector></HeadingPairs><TitlesOfParts><vt:vector size="\(sheets.count)" baseType="lpstr">\(titles)</vt:vector></TitlesOfParts><AppVersion>1.0</AppVersion></Properties>
        """
    }

    private func columnName(_ index: Int) -> String {
        var value = max(1, index)
        var result = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(65 + value % 26)!
            result.insert(Character(scalar), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private func xmlEscaped(_ value: String) -> String {
        ooxmlEscaped(value)
    }

    private func fallbackProfile(
        document: PDFDocument,
        sourceSize: Int64
    ) -> DocumentProfile {
        DocumentProfile(
            pageCount: document.pageCount,
            sampledPageCount: max(1, min(document.pageCount, 12)),
            textCharacterCount: 0,
            imageDominantPageCount: 0,
            formFieldCount: 0,
            byteCount: sourceSize,
            isEncrypted: false,
            isLocked: document.isLocked,
            allowsCopying: true,
            allowsCommenting: true,
            kind: .mixed,
            recommendedActions: [.inspect]
        )
    }
}

struct PPTXExportService: Sendable {
    private struct Slide: Sendable {
        let pageIndex: Int
        let pageSize: CGSize
        let imageData: Data
        let searchableText: String
    }

    private struct PresentationSize: Sendable {
        let widthEMU: Int64
        let heightEMU: Int64
    }

    private struct VisualBudget: Sendable {
        let maximumTotalBytes = 72 * 1_024 * 1_024
        let minimumAssetBytes = 72 * 1_024
        let maximumAssetBytes = 4 * 1_024 * 1_024

        func byteLimit(
            remainingBytes: Int,
            remainingSlideCount: Int
        ) -> Int {
            let slideCount = max(1, remainingSlideCount)
            let reservedForLater = minimumAssetBytes
                * max(0, slideCount - 1)
            let availableNow = max(
                minimumAssetBytes,
                remainingBytes - reservedForLater
            )
            let fairShare = max(
                minimumAssetBytes,
                remainingBytes / slideCount
            )
            return min(
                maximumAssetBytes,
                availableNow,
                fairShare * 2
            )
        }
    }

    private struct RenderedSlideAsset: Sendable {
        let data: Data
        let qualityPercent: Int
        let attemptCount: Int
    }

    func export(
        sourceURL: URL,
        destination: URL,
        textIndex: DocumentTextIndex?,
        title: String,
        profile: DocumentProfile? = nil,
        byteProgress: @escaping PDFByteProgressHandler = { _ in },
        progress: @escaping PDFProgressHandler
    ) throws -> PDFOfficeRuntimeEvidence {
        let sourceSize = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceSize <= 512 * 1_024 * 1_024 else {
            throw PaperPathError.fileTooLarge
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= 500 else {
            throw PaperPathError.fileTooLarge
        }

        let indexedPages = officeIndexedTextByPage(textIndex)
        var slides: [Slide] = []
        slides.reserveCapacity(document.pageCount)
        var renderedByteCount = 0
        var compressionFallbackCount = 0
        var minimumAcceptedQualityPercent = 100
        let visualBudget = VisualBudget()

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            guard let geometry = PDFOfficePageGeometry(page: page) else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) has invalid dimensions"
                )
            }
            let pixelSize = fittedPixelSize(
                geometry.displaySize,
                pageCount: document.pageCount
            )
            let remainingBytes =
                visualBudget.maximumTotalBytes - renderedByteCount
            let remainingSlides = document.pageCount - pageIndex
            let pageByteLimit = visualBudget.byteLimit(
                remainingBytes: remainingBytes,
                remainingSlideCount: remainingSlides
            )
            let renderedAsset = autoreleasepool {
                renderedSlideAsset(
                    from: page,
                    baseSize: pixelSize,
                    initialCompressionQuality:
                        document.pageCount > 160 ? 0.78 : 0.88,
                    maximumByteCount: pageByteLimit
                )
            }
            try Task.checkCancellation()
            guard let renderedAsset,
                  !renderedAsset.data.isEmpty
            else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) exceeded its adaptive PowerPoint visual budget"
                )
            }
            renderedByteCount += renderedAsset.data.count
            compressionFallbackCount += max(
                0,
                renderedAsset.attemptCount - 1
            )
            minimumAcceptedQualityPercent = min(
                minimumAcceptedQualityPercent,
                renderedAsset.qualityPercent
            )
            guard renderedByteCount
                    <= visualBudget.maximumTotalBytes
            else {
                throw PaperPathError.fileTooLarge
            }

            let pageText = page.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackText = indexedPages[pageIndex]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            slides.append(
                Slide(
                    pageIndex: pageIndex,
                    pageSize: geometry.displaySize,
                    imageData: renderedAsset.data,
                    searchableText: boundedSearchableText(
                        pageText?.isEmpty == false
                            ? pageText ?? ""
                            : fallbackText ?? ""
                    )
                )
            )
            progress(
                0.72 * Double(pageIndex + 1)
                    / Double(document.pageCount)
            )
        }

        guard !slides.isEmpty else {
            throw PaperPathError.unreadablePDF
        }
        let presentationSize = presentationSize(
            for: slides.map(\.pageSize)
        )
        let officePortfolio = PDFOfficeExportPortfolio(
            profile: profile ?? fallbackProfile(
                document: document,
                sourceSize: Int64(sourceSize)
            )
        )
        let searchableSlides = slides.filter {
            !$0.searchableText.isEmpty
        }
        let auditRuntime = PDFOfficeRuntimeEvidence(
            sourcePageCount: document.pageCount,
            outputPageCount: slides.count,
            primaryUnitLabel: "slides",
            primaryUnitCount: slides.count,
            characterCount: searchableSlides.reduce(0) {
                $0 + $1.searchableText.count
            },
            searchablePageCount: searchableSlides.count,
            assetCount: slides.count,
            assetByteCount: renderedByteCount,
            assetBudgetByteCount: visualBudget.maximumTotalBytes,
            assetCompressionFallbackCount:
                compressionFallbackCount,
            assetMinimumQualityPercent:
                minimumAcceptedQualityPercent,
            contentNotices: PDFOfficeContentNotice.defaults(for: .powerPointPresentation)
        )
        _ = try makePackage(
            title: title,
            slides: slides,
            presentationSize: presentationSize,
            auditXML: officeAuditPropertiesXML(
                format: .powerPointPresentation,
                portfolio: officePortfolio,
                runtime: auditRuntime
            ),
            destination: destination,
            byteProgress: byteProgress
        )
        progress(0.9)
        progress(1)
        return auditRuntime
    }

    private func fittedPixelSize(
        _ size: CGSize,
        pageCount: Int
    ) -> CGSize {
        let aspect = max(size.width, size.height)
            / max(1, min(size.width, size.height))
        let standardLongestEdge: CGFloat
        switch pageCount {
        case ...30:
            standardLongestEdge = 2_400
        case ...120:
            standardLongestEdge = 1_900
        case ...300:
            standardLongestEdge = 1_500
        default:
            standardLongestEdge = 1_120
        }
        let longestEdge: CGFloat = aspect > 4
            ? min(
                4_800,
                max(
                    standardLongestEdge,
                    aspect * 210
                )
            )
            : standardLongestEdge
        let scale = longestEdge / max(size.width, size.height)
        return CGSize(
            width: max(1, (size.width * scale).rounded(.up)),
            height: max(1, (size.height * scale).rounded(.up))
        )
    }

    private func jpegData(
        from page: PDFPage,
        size: CGSize,
        compressionQuality: CGFloat
    ) -> Data? {
        let image = page.thumbnail(of: size, for: .cropBox)
#if canImport(UIKit)
        return image.jpegData(
            compressionQuality: compressionQuality
        )
#elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [
                .compressionFactor: compressionQuality
            ]
        )
#endif
    }

    private func renderedSlideAsset(
        from page: PDFPage,
        baseSize: CGSize,
        initialCompressionQuality: CGFloat,
        maximumByteCount: Int
    ) -> RenderedSlideAsset? {
        let attempts: [(scale: CGFloat, quality: CGFloat)] = [
            (1, initialCompressionQuality),
            (0.84, min(initialCompressionQuality, 0.74)),
            (0.70, min(initialCompressionQuality, 0.66)),
            (0.58, min(initialCompressionQuality, 0.58)),
            (0.48, min(initialCompressionQuality, 0.50))
        ]
        for (index, attempt) in attempts.enumerated() {
            guard !Task.isCancelled else { return nil }
            let size = CGSize(
                width: max(
                    1,
                    (baseSize.width * attempt.scale).rounded(.up)
                ),
                height: max(
                    1,
                    (baseSize.height * attempt.scale).rounded(.up)
                )
            )
            guard let data = jpegData(
                from: page,
                size: size,
                compressionQuality: attempt.quality
            ),
                  !data.isEmpty
            else {
                continue
            }
            guard !Task.isCancelled else { return nil }
            if data.count <= maximumByteCount {
                return RenderedSlideAsset(
                    data: data,
                    qualityPercent: Int(
                        (attempt.quality * 100).rounded()
                    ),
                    attemptCount: index + 1
                )
            }
        }
        return nil
    }

    private func boundedSearchableText(_ text: String) -> String {
        let sanitized = text.unicodeScalars.reduce(
            into: ""
        ) { result, scalar in
            let code = scalar.value
            if code == 0x09
                || code == 0x0a
                || code == 0x0d
                || (0x20...0xd7ff).contains(code)
                || (0xe000...0xfffd).contains(code)
                || (0x10000...0x10ffff).contains(code) {
                result.unicodeScalars.append(scalar)
            }
        }
        return String(sanitized.prefix(32_000))
    }

    private func presentationSize(
        for pageSizes: [CGSize]
    ) -> PresentationSize {
        let ratios = pageSizes.compactMap { size -> Double? in
            guard size.width > 0, size.height > 0 else {
                return nil
            }
            return Double(size.width / size.height)
        }.sorted()
        let medianRatio: Double
        if ratios.isEmpty {
            medianRatio = 4.0 / 3.0
        } else if ratios.count.isMultiple(of: 2) {
            let index = ratios.count / 2
            medianRatio = sqrt(
                ratios[index - 1] * ratios[index]
            )
        } else {
            medianRatio = ratios[ratios.count / 2]
        }
        let neutralRatio = (0.9...1.1).contains(medianRatio)
            ? 4.0 / 3.0
            : medianRatio
        let ratio = min(
            max(neutralRatio, 9.0 / 16.0),
            16.0 / 9.0
        )
        let longEdge = 9_144_000.0
        if ratio >= 1 {
            return PresentationSize(
                widthEMU: Int64(longEdge),
                heightEMU: Int64(
                    (longEdge / ratio).rounded()
                )
            )
        }
        return PresentationSize(
            widthEMU: Int64(
                (longEdge * ratio).rounded()
            ),
            heightEMU: Int64(longEdge)
        )
    }

    private func makePackage(
        title: String,
        slides: [Slide],
        presentationSize: PresentationSize,
        auditXML: String,
        destination: URL,
        byteProgress: @escaping PDFByteProgressHandler
    ) throws -> Int64 {
        var archive = OOXMLArchive()
        try archive.add(
            path: "[Content_Types].xml",
            string: contentTypesXML(slideCount: slides.count)
        )
        try archive.add(
            path: "_rels/.rels",
            string: rootRelationshipsXML
        )
        try archive.add(
            path: "docProps/core.xml",
            string: corePropertiesXML(title: title)
        )
        try archive.add(
            path: "docProps/app.xml",
            string: appPropertiesXML(slideCount: slides.count)
        )
        try archive.add(
            path: "docProps/custom.xml",
            string: auditXML
        )
        try archive.add(
            path: "ppt/presentation.xml",
            string: presentationXML(
                slideCount: slides.count,
                size: presentationSize
            )
        )
        try archive.add(
            path: "ppt/_rels/presentation.xml.rels",
            string: presentationRelationshipsXML(
                slideCount: slides.count
            )
        )
        try archive.add(
            path: "ppt/slideMasters/slideMaster1.xml",
            string: slideMasterXML
        )
        try archive.add(
            path: "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            string: slideMasterRelationshipsXML
        )
        try archive.add(
            path: "ppt/slideLayouts/slideLayout1.xml",
            string: slideLayoutXML
        )
        try archive.add(
            path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            string: slideLayoutRelationshipsXML
        )
        try archive.add(
            path: "ppt/theme/theme1.xml",
            string: themeXML
        )

        for (index, slide) in slides.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            try archive.add(
                path: "ppt/slides/slide\(number).xml",
                string: slideXML(
                    slide,
                    size: presentationSize
                )
            )
            try archive.add(
                path: "ppt/slides/_rels/slide\(number).xml.rels",
                string: slideRelationshipsXML(
                    imageNumber: number
                )
            )
            try archive.add(
                path: "ppt/media/page-\(number).jpg",
                data: slide.imageData
            )
        }

        let writtenBytes = try archive.write(
            to: destination,
            profile: .powerPoint(slideCount: slides.count),
            byteProgress: byteProgress
        )
        guard writtenBytes > 4,
              !slides.isEmpty
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PowerPoint package structure is incomplete"
            )
        }
        return writtenBytes
    }

    private func presentationXML(
        slideCount: Int,
        size: PresentationSize
    ) -> String {
        let slideIDs = (1...slideCount).map { number in
            """
            <p:sldId id="\(255 + number)" r:id="rId\(number + 1)"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(size.widthEMU)" cy="\(size.heightEMU)" type="custom"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:defaultTextStyle></p:presentation>
        """
    }

    private func slideXML(
        _ slide: Slide,
        size: PresentationSize
    ) -> String {
        let placement = imagePlacement(
            pageSize: slide.pageSize,
            presentationSize: size
        )
        let searchableShape: String
        if slide.searchableText.isEmpty {
            searchableShape = ""
        } else {
            searchableShape = """
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Searchable PDF text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(size.widthEMU)" cy="\(size.heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square"/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="100" dirty="0"><a:solidFill><a:srgbClr val="FFFFFF"><a:alpha val="0"/></a:srgbClr></a:solidFill></a:rPr><a:t xml:space="preserve">\(xmlEscaped(slide.searchableText))</a:t></a:r><a:endParaRPr lang="en-US" sz="100"/></a:p></p:txBody></p:sp>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="PDF Page \(slide.pageIndex + 1)"><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\(searchableShape)<p:pic><p:nvPicPr><p:cNvPr id="3" name="PDF Page \(slide.pageIndex + 1)" descr="High-fidelity rendering of PDF page \(slide.pageIndex + 1)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(placement.x)" y="\(placement.y)"/><a:ext cx="\(placement.width)" cy="\(placement.height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:ln><a:noFill/></a:ln></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    private func imagePlacement(
        pageSize: CGSize,
        presentationSize: PresentationSize
    ) -> (x: Int64, y: Int64, width: Int64, height: Int64) {
        let scale = min(
            Double(presentationSize.widthEMU)
                / Double(pageSize.width),
            Double(presentationSize.heightEMU)
                / Double(pageSize.height)
        )
        let width = Int64((Double(pageSize.width) * scale).rounded())
        let height = Int64((Double(pageSize.height) * scale).rounded())
        return (
            x: max(0, (presentationSize.widthEMU - width) / 2),
            y: max(0, (presentationSize.heightEMU - height) / 2),
            width: width,
            height: height
        )
    }

    private func contentTypesXML(slideCount: Int) -> String {
        let slides = (1...slideCount).map {
            """
            <Override PartName="/ppt/slides/slide\($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/><Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/>\(slides)</Types>
        """
    }

    private var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties" Target="docProps/custom.xml"/></Relationships>
        """
    }

    private func presentationRelationshipsXML(
        slideCount: Int
    ) -> String {
        let slides = (1...slideCount).map {
            """
            <Relationship Id="rId\($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\($0).xml"/>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\(slides)</Relationships>
        """
    }

    private var slideMasterRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """
    }

    private var slideLayoutRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """
    }

    private func slideRelationshipsXML(
        imageNumber: Int
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/page-\(imageNumber).jpg"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
        """
    }

    private var slideMasterXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="PaperPath"><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="3200" b="1"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="342900" indent="-342900"><a:defRPr sz="1800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:otherStyle></p:txStyles></p:sldMaster>
        """
    }

    private var slideLayoutXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
    }

    private var themeXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="PaperPath"><a:themeElements><a:clrScheme name="PaperPath"><a:dk1><a:sysClr val="windowText" lastClr="202124"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="243447"/></a:dk2><a:lt2><a:srgbClr val="F3F5F7"/></a:lt2><a:accent1><a:srgbClr val="176B87"/></a:accent1><a:accent2><a:srgbClr val="2D8C73"/></a:accent2><a:accent3><a:srgbClr val="D89A3D"/></a:accent3><a:accent4><a:srgbClr val="7A6FA8"/></a:accent4><a:accent5><a:srgbClr val="B75A65"/></a:accent5><a:accent6><a:srgbClr val="4E83B5"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="PaperPath"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="PaperPath"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:tint val="15000"/><a:satMod val="350000"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:shade val="85000"/><a:satMod val="250000"/></a:schemeClr></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:shade val="85000"/><a:satMod val="250000"/></a:schemeClr></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
    }

    private func corePropertiesXML(title: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscaped(title))</dc:title><dc:creator>PaperPath</dc:creator><cp:lastModifiedBy>PaperPath</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified></cp:coreProperties>
        """
    }

    private func appPropertiesXML(slideCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>PaperPath</Application><PresentationFormat>Custom</PresentationFormat><Slides>\(slideCount)</Slides><Notes>0</Notes><HiddenSlides>0</HiddenSlides><MMClips>0</MMClips><ScaleCrop>false</ScaleCrop><AppVersion>1.0</AppVersion></Properties>
        """
    }

    private func xmlEscaped(_ value: String) -> String {
        ooxmlEscaped(value)
    }

    private func fallbackProfile(
        document: PDFDocument,
        sourceSize: Int64
    ) -> DocumentProfile {
        DocumentProfile(
            pageCount: document.pageCount,
            sampledPageCount: max(1, min(document.pageCount, 12)),
            textCharacterCount: 0,
            imageDominantPageCount: 0,
            formFieldCount: 0,
            byteCount: sourceSize,
            isEncrypted: false,
            isLocked: document.isLocked,
            allowsCopying: true,
            allowsCommenting: true,
            kind: .mixed,
            recommendedActions: [.inspect]
        )
    }
}

struct DOCXPage {
    let pageIndex: Int
    let blocks: [DOCXBlock]
    let visualReference: DOCXImage?
    let layout: DOCXPageLayout
}

struct DOCXPageLayout {
    let widthTwips: Int
    let heightTwips: Int
    let isLandscape: Bool

    static let letterPortrait = DOCXPageLayout(
        widthTwips: 12_240,
        heightTwips: 15_840,
        isLandscape: false
    )
}

enum DOCXBlock {
    case paragraph(DOCXParagraph)
    case table(DOCXTable)
}

struct DOCXLine {
    let text: String
    let bounds: CGRect
    let fontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let cells: [DOCXCellCandidate]
}

struct DOCXCellCandidate {
    let text: String
    let bounds: CGRect
}

struct DOCXTable {
    let rows: [DOCXTableRow]
    let columnWidths: [Int]
}

struct DOCXTableRow {
    let cells: [DOCXTableCell]
    let repeatsAsHeader: Bool
}

struct DOCXTableCell {
    let text: String
    let isBold: Bool
}

struct DOCXImage {
    let relationshipID: String
    let fileName: String
    let data: Data
    let widthEMU: Int
    let heightEMU: Int
    let description: String
}

struct DOCXParagraph {
    let text: String
    let style: DOCXParagraphStyle
    let isBold: Bool
    let isItalic: Bool
    let fontSize: CGFloat
    let alignment: DOCXAlignment
    var listIndentTwips: Int? = nil
}

enum DOCXParagraphStyle {
    case body
    case heading1
    case heading2
    case list

    var wordStyle: String {
        switch self {
        case .body: return "Normal"
        case .heading1: return "Heading1"
        case .heading2: return "Heading2"
        case .list: return "ListParagraph"
        }
    }
}

enum DOCXAlignment: String {
    case left
    case center
    case right
}

func ooxmlEscaped(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.utf8.count)
    for scalar in value.unicodeScalars {
        let code = scalar.value
        guard code == 0x09
                || code == 0x0a
                || code == 0x0d
                || (0x20...0xd7ff).contains(code)
                || (0xe000...0xfffd).contains(code)
                || (0x10000...0x10ffff).contains(code)
        else { continue }
        switch scalar {
        case "&":
            result.append("&amp;")
        case "<":
            result.append("&lt;")
        case ">":
            result.append("&gt;")
        case "\"":
            result.append("&quot;")
        case "'":
            result.append("&apos;")
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

private enum OOXMLPackageProfile {
    case word
    case excel(sheetCount: Int)
    case powerPoint(slideCount: Int)

    var requiredParts: Set<String> {
        var parts: Set<String> = [
            "[Content_Types].xml",
            "_rels/.rels",
            "docProps/core.xml",
            "docProps/app.xml",
            "docProps/custom.xml"
        ]
        switch self {
        case .word:
            parts.formUnion([
                "word/document.xml",
                "word/styles.xml",
                "word/settings.xml",
                "word/_rels/document.xml.rels"
            ])
        case .excel(let sheetCount):
            parts.formUnion([
                "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels",
                "xl/styles.xml"
            ])
            if sheetCount > 0 {
                for index in 1...sheetCount {
                    parts.insert(
                        "xl/worksheets/sheet\(index).xml"
                    )
                }
            }
        case .powerPoint(let slideCount):
            parts.formUnion([
                "ppt/presentation.xml",
                "ppt/_rels/presentation.xml.rels",
                "ppt/slideMasters/slideMaster1.xml",
                "ppt/slideMasters/_rels/slideMaster1.xml.rels",
                "ppt/slideLayouts/slideLayout1.xml",
                "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
                "ppt/theme/theme1.xml"
            ])
            if slideCount > 0 {
                for index in 1...slideCount {
                    parts.formUnion([
                        "ppt/slides/slide\(index).xml",
                        "ppt/slides/_rels/slide\(index).xml.rels",
                        "ppt/media/page-\(index).jpg"
                    ])
                }
            }
        }
        return parts
    }

    var requiredContentTypes: [String: String] {
        var types: [String: String] = [
            "docProps/core.xml":
                "application/vnd.openxmlformats-package.core-properties+xml",
            "docProps/app.xml":
                "application/vnd.openxmlformats-officedocument.extended-properties+xml",
            "docProps/custom.xml":
                "application/vnd.openxmlformats-officedocument.custom-properties+xml"
        ]
        switch self {
        case .word:
            types["word/document.xml"] =
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
            types["word/styles.xml"] =
                "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"
            types["word/settings.xml"] =
                "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"
        case .excel(let sheetCount):
            types["xl/workbook.xml"] =
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
            types["xl/styles.xml"] =
                "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"
            if sheetCount > 0 {
                for index in 1...sheetCount {
                    types["xl/worksheets/sheet\(index).xml"] =
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
                }
            }
        case .powerPoint(let slideCount):
            types["ppt/presentation.xml"] =
                "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
            types["ppt/slideMasters/slideMaster1.xml"] =
                "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"
            types["ppt/slideLayouts/slideLayout1.xml"] =
                "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"
            types["ppt/theme/theme1.xml"] =
                "application/vnd.openxmlformats-officedocument.theme+xml"
            if slideCount > 0 {
                for index in 1...slideCount {
                    types["ppt/slides/slide\(index).xml"] =
                        "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"
                }
            }
        }
        return types
    }

    var requiredRelationshipTargets: [String: Set<String>] {
        let coreTargets: Set<String> = [
            "docProps/core.xml",
            "docProps/app.xml",
            "docProps/custom.xml"
        ]
        switch self {
        case .word:
            return [
                "_rels/.rels": coreTargets.union([
                    "word/document.xml"
                ]),
                "word/_rels/document.xml.rels": [
                    "word/styles.xml",
                    "word/settings.xml"
                ]
            ]
        case .excel(let sheetCount):
            var workbookTargets: Set<String> = [
                "xl/styles.xml"
            ]
            if sheetCount > 0 {
                for index in 1...sheetCount {
                    workbookTargets.insert(
                        "xl/worksheets/sheet\(index).xml"
                    )
                }
            }
            return [
                "_rels/.rels": coreTargets.union([
                    "xl/workbook.xml"
                ]),
                "xl/_rels/workbook.xml.rels":
                    workbookTargets
            ]
        case .powerPoint(let slideCount):
            var relationships: [String: Set<String>] = [
                "_rels/.rels": coreTargets.union([
                    "ppt/presentation.xml"
                ]),
                "ppt/_rels/presentation.xml.rels": [
                    "ppt/slideMasters/slideMaster1.xml"
                ],
                "ppt/slideMasters/_rels/slideMaster1.xml.rels": [
                    "ppt/slideLayouts/slideLayout1.xml",
                    "ppt/theme/theme1.xml"
                ],
                "ppt/slideLayouts/_rels/slideLayout1.xml.rels": [
                    "ppt/slideMasters/slideMaster1.xml"
                ]
            ]
            if slideCount > 0 {
                for index in 1...slideCount {
                    relationships[
                        "ppt/_rels/presentation.xml.rels",
                        default: []
                    ].insert(
                        "ppt/slides/slide\(index).xml"
                    )
                    relationships[
                        "ppt/slides/_rels/slide\(index).xml.rels"
                    ] = [
                        "ppt/media/page-\(index).jpg",
                        "ppt/slideLayouts/slideLayout1.xml"
                    ]
                }
            }
            return relationships
        }
    }
}

private func ooxmlBoundedDirectoryContents(
    at directory: URL,
    includingPropertiesForKeys keys: [URLResourceKey],
    options: FileManager.DirectoryEnumerationOptions = [],
    maximumEntryCount: Int = 4_096
) -> [URL]? {
    var enumerationFailed = false
    guard maximumEntryCount > 0,
          let enumerator = FileManager.default.enumerator(
              at: directory,
              includingPropertiesForKeys: keys,
              options: options.union(.skipsSubdirectoryDescendants),
              errorHandler: { _, _ in
                  enumerationFailed = true
                  return false
              }
          )
    else { return nil }

    var urls: [URL] = []
    urls.reserveCapacity(min(maximumEntryCount, 128))
    for case let url as URL in enumerator {
        guard urls.count < maximumEntryCount else { break }
        urls.append(url)
    }
    guard !enumerationFailed else { return nil }
    return urls
}

struct OOXMLArchivePayloadBudget: Sendable {
    static let defaultMaximumBytes = 128 * 1_024 * 1_024

    let maximumBytes: Int
    private(set) var consumedBytes = 0

    init(maximumBytes: Int = Self.defaultMaximumBytes) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func consume(_ byteCount: Int) throws {
        let (nextBytes, overflow) = consumedBytes
            .addingReportingOverflow(byteCount)
        guard byteCount >= 0,
              !overflow,
              nextBytes <= maximumBytes
        else {
            throw PaperPathError.fileTooLarge
        }
        consumedBytes = nextBytes
    }
}

private struct OOXMLArchive {
    private struct Entry {
        let path: String
        let name: Data
        let payload: Data
        let checksum: UInt32
    }

    private var entries: [Entry] = []
    private var paths: Set<String> = []
    private var payloadBudget = OOXMLArchivePayloadBudget()

    private struct CentralRecord {
        let entry: Entry
        let offset: UInt32
    }

    mutating func add(path: String, string: String) throws {
        try add(path: path, data: Data(string.utf8))
    }

    mutating func add(path: String, data: Data) throws {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !components.contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              })
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office package contains an invalid path"
            )
        }
        guard !paths.contains(path) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office package contains a duplicate part: \(path)"
            )
        }
        try payloadBudget.consume(data.count)
        paths.insert(path)
        entries.append(
            Entry(
                path: path,
                name: Data(path.utf8),
                payload: data,
                checksum: crc32(data)
            )
        )
    }

    func write(
        to destination: URL,
        profile: OOXMLPackageProfile,
        byteProgress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> Int64 {
        guard !entries.isEmpty else {
            throw PaperPathError.outputVerificationFailed(
                "the Office package is empty"
            )
        }
        try validate(profile: profile)
        guard entries.count <= Int(UInt16.max) else {
            throw PaperPathError.storageFailure(
                "The Office export exceeded the local package limit."
            )
        }
        var totalBytes = Int64(22)
        for entry in entries {
            guard entry.name.count <= Int(UInt16.max),
                  entry.payload.count <= Int(UInt32.max)
            else {
                throw PaperPathError.storageFailure(
                    "The Office export exceeded the local package limit."
                )
            }
            let entryByteCount = Int64(76)
                + Int64(entry.name.count) * 2
                + Int64(entry.payload.count)
            let (nextTotalBytes, overflow) = totalBytes
                .addingReportingOverflow(entryByteCount)
            guard !overflow,
                  nextTotalBytes <= Int64(UInt32.max)
            else {
                throw PaperPathError.storageFailure(
                    "The Office export exceeded the ZIP32 package limit."
                )
            }
            totalBytes = nextTotalBytes
        }
        byteProgress(
            PDFByteProgressUpdate(
                stage: .packaging,
                processedBytes: 0,
                totalBytes: totalBytes,
                totalUnitCount: entries.count
            )
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let parentValues = try destination.deletingLastPathComponent()
            .resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
        let (requiredCapacity, capacityOverflow) = totalBytes
            .addingReportingOverflow(32 * 1_024 * 1_024)
        guard !capacityOverflow else {
            throw PaperPathError.fileTooLarge
        }
        if let available =
            parentValues.volumeAvailableCapacityForImportantUsage,
           available < requiredCapacity {
            throw PaperPathError.insufficientStorage
        }
        cleanupStaleTemporaryFiles(
            in: destination.deletingLastPathComponent()
        )
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".PaperPath-OOXML-\(UUID().uuidString).tmp"
            )
        try? fileManager.removeItem(at: temporary)
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [
                .protectionKey: FileProtectionType.complete
            ]
        ) else {
            throw PaperPathError.storageFailure(
                "The Office package temporary file could not be created."
            )
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var temporaryResourceURL = temporary
        try? temporaryResourceURL.setResourceValues(resourceValues)

        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)
        var lastReportedBytes: Int64 = 0
        let reportingStride: Int64 = 2 * 1_024 * 1_024
        do {
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                let rawOffset = try output.offset()
                guard entry.name.count <= Int(UInt16.max),
                      entry.payload.count <= Int(UInt32.max),
                      rawOffset <= UInt64(UInt32.max)
                else {
                    throw PaperPathError.storageFailure(
                        "The Office export exceeded the local package limit."
                    )
                }
                let offset = UInt32(rawOffset)
                let payloadSize = UInt32(entry.payload.count)
                let nameSize = UInt16(entry.name.count)
                var localHeader = Data()
                localHeader.appendLittleEndian(UInt32(0x04034b50))
                localHeader.appendLittleEndian(UInt16(20))
                localHeader.appendLittleEndian(UInt16(0x0800))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(UInt16(0x0021))
                localHeader.appendLittleEndian(entry.checksum)
                localHeader.appendLittleEndian(payloadSize)
                localHeader.appendLittleEndian(payloadSize)
                localHeader.appendLittleEndian(nameSize)
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.append(entry.name)
                try output.write(contentsOf: localHeader)
                try output.write(contentsOf: entry.payload)
                centralRecords.append(
                    CentralRecord(entry: entry, offset: offset)
                )

                let generatedBytes = Int64(try output.offset())
                if generatedBytes - lastReportedBytes
                    >= reportingStride
                    || index == entries.index(before: entries.endIndex) {
                    byteProgress(
                        PDFByteProgressUpdate(
                            stage: .packaging,
                            processedBytes: generatedBytes,
                            totalBytes: totalBytes,
                            completedUnitCount: index + 1,
                            totalUnitCount: entries.count,
                            currentUnitName: entry.path
                        )
                    )
                    lastReportedBytes = generatedBytes
                }
            }

            let rawCentralOffset = try output.offset()
            guard rawCentralOffset <= UInt64(UInt32.max) else {
                throw PaperPathError.storageFailure(
                    "The Office export exceeded the local package limit."
                )
            }
            for record in centralRecords {
                try Task.checkCancellation()
                let entry = record.entry
                let payloadSize = UInt32(entry.payload.count)
                var centralHeader = Data()
                centralHeader.appendLittleEndian(UInt32(0x02014b50))
                centralHeader.appendLittleEndian(UInt16(20))
                centralHeader.appendLittleEndian(UInt16(20))
                centralHeader.appendLittleEndian(UInt16(0x0800))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0x0021))
                centralHeader.appendLittleEndian(entry.checksum)
                centralHeader.appendLittleEndian(payloadSize)
                centralHeader.appendLittleEndian(payloadSize)
                centralHeader.appendLittleEndian(
                    UInt16(entry.name.count)
                )
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt16(0))
                centralHeader.appendLittleEndian(UInt32(0))
                centralHeader.appendLittleEndian(record.offset)
                centralHeader.append(entry.name)
                try output.write(contentsOf: centralHeader)
            }
            let rawEndOffset = try output.offset()
            let centralSize = rawEndOffset - rawCentralOffset
            guard centralSize <= UInt64(UInt32.max) else {
                throw PaperPathError.storageFailure(
                    "The Office export exceeded the local package limit."
                )
            }
            var endRecord = Data()
            endRecord.appendLittleEndian(UInt32(0x06054b50))
            endRecord.appendLittleEndian(UInt16(0))
            endRecord.appendLittleEndian(UInt16(0))
            endRecord.appendLittleEndian(UInt16(entries.count))
            endRecord.appendLittleEndian(UInt16(entries.count))
            endRecord.appendLittleEndian(UInt32(centralSize))
            endRecord.appendLittleEndian(UInt32(rawCentralOffset))
            endRecord.appendLittleEndian(UInt16(0))
            try output.write(contentsOf: endRecord)
            try Task.checkCancellation()
            try output.synchronize()
            try output.close()

            let writtenBytes = Int64(
                try temporary.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0
            )
            guard writtenBytes == totalBytes,
                  try hasZIPSignature(at: temporary)
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office package stream is incomplete"
                )
            }
            try commit(
                temporary: temporary,
                destination: destination
            )
            byteProgress(
                PDFByteProgressUpdate(
                    stage: .packaging,
                    processedBytes: writtenBytes,
                    totalBytes: totalBytes,
                    completedUnitCount: entries.count,
                    totalUnitCount: entries.count
                )
            )
            return writtenBytes
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func hasZIPSignature(at url: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let signature = try input.read(upToCount: 4)
        return signature == Data([0x50, 0x4b, 0x03, 0x04])
    }

    private func cleanupStaleTemporaryFiles(
        in directory: URL
    ) {
        let fileManager = FileManager.default
        guard let candidates = ooxmlBoundedDirectoryContents(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        for candidate in candidates
            where candidate.lastPathComponent
                .hasPrefix(".PaperPath-OOXML-")
                && PaperPathTemporaryArtifact.isManagedName(
                    candidate.lastPathComponent
                ) {
            let values = try? candidate.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt < cutoff
            else { continue }
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func commit(
        temporary: URL,
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(
                at: temporary,
                to: destination
            )
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var destinationResourceURL = destination
        try? destinationResourceURL.setResourceValues(values)
    }

    private func validate(
        profile: OOXMLPackageProfile
    ) throws {
        var entryMap: [String: Data] = [:]
        for entry in entries {
            guard entryMap[entry.path] == nil else {
                throw ooxmlValidationError(
                    "contains a duplicate \(entry.path) part"
                )
            }
            entryMap[entry.path] = entry.payload
        }
        let missingParts = profile.requiredParts.subtracting(
            entryMap.keys
        )
        guard missingParts.isEmpty else {
            throw ooxmlValidationError(
                "is missing \(missingParts.sorted().joined(separator: ", "))"
            )
        }
        try validateXML(in: entryMap)
        try validateRelationships(
            in: entryMap,
            profile: profile
        )
        try validateContentTypes(
            in: entryMap,
            profile: profile
        )
    }

    private func validateXML(
        in entries: [String: Data]
    ) throws {
        for (path, payload) in entries
            where path.hasSuffix(".xml")
                || path.hasSuffix(".rels") {
            let parser = XMLParser(data: payload)
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else {
                throw ooxmlValidationError(
                    "contains invalid XML in \(path)"
                )
            }
        }
    }

    private func validateRelationships(
        in entries: [String: Data],
        profile: OOXMLPackageProfile
    ) throws {
        var discoveredTargets: [String: Set<String>] = [:]
        for (path, payload) in entries
            where path.hasSuffix(".rels") {
            let collector = OOXMLRelationshipCollector()
            let parser = XMLParser(data: payload)
            parser.shouldResolveExternalEntities = false
            parser.delegate = collector
            guard parser.parse(),
                  collector.hasRelationshipsRoot,
                  !collector.hasMalformedRelationship
            else {
                throw ooxmlValidationError(
                    "contains invalid relationships in \(path)"
                )
            }
            let ownerDirectory = try relationshipOwnerDirectory(
                for: path
            )
            for relationship in collector.relationships
                where !relationship.isExternal {
                let target = try normalizedRelationshipPath(
                    ownerDirectory: ownerDirectory,
                    target: relationship.target
                )
                guard entries[target] != nil else {
                    throw ooxmlValidationError(
                        "references missing part \(target) from \(path)"
                    )
                }
                discoveredTargets[path, default: []].insert(
                    target
                )
            }
        }
        for (path, requiredTargets) in
            profile.requiredRelationshipTargets {
            let missingTargets = requiredTargets.subtracting(
                discoveredTargets[path] ?? []
            )
            guard missingTargets.isEmpty else {
                throw ooxmlValidationError(
                    "is missing required relationships from \(path): "
                        + missingTargets.sorted().joined(separator: ", ")
                )
            }
        }
    }

    private func validateContentTypes(
        in entries: [String: Data],
        profile: OOXMLPackageProfile
    ) throws {
        guard let payload = entries["[Content_Types].xml"] else {
            throw ooxmlValidationError(
                "is missing [Content_Types].xml"
            )
        }
        let collector = OOXMLContentTypesCollector()
        let parser = XMLParser(data: payload)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(),
              collector.hasTypesRoot,
              !collector.hasMalformedDeclaration
        else {
            throw ooxmlValidationError(
                "contains invalid content type declarations"
            )
        }

        for path in entries.keys
            where path != "[Content_Types].xml" {
            let fileExtension = path.hasSuffix(".rels")
                ? "rels"
                : (path as NSString)
                    .pathExtension
                    .lowercased()
            guard collector.overrides[path] != nil
                    || collector.defaults[fileExtension] != nil
            else {
                throw ooxmlValidationError(
                    "does not declare a content type for \(path)"
                )
            }
        }
        for path in collector.overrides.keys
            where entries[path] == nil {
            throw ooxmlValidationError(
                "declares a missing content part: \(path)"
            )
        }
        for (path, expectedType) in profile.requiredContentTypes {
            guard collector.overrides[path] == expectedType else {
                throw ooxmlValidationError(
                    "has an invalid content type for \(path)"
                )
            }
        }
    }

    private func relationshipOwnerDirectory(
        for path: String
    ) throws -> String {
        if path == "_rels/.rels" {
            return ""
        }
        guard let range = path.range(
            of: "/_rels/",
            options: .backwards
        ) else {
            throw ooxmlValidationError(
                "contains a misplaced relationship part: \(path)"
            )
        }
        return String(path[..<range.lowerBound])
    }

    private func normalizedRelationshipPath(
        ownerDirectory: String,
        target: String
    ) throws -> String {
        guard !target.isEmpty,
              !target.contains("\\"),
              !target.contains("#"),
              !target.contains("?")
        else {
            throw ooxmlValidationError(
                "contains an invalid relationship target: \(target)"
            )
        }
        let decodedTarget = target.removingPercentEncoding ?? target
        let relativeTarget = decodedTarget.hasPrefix("/")
            ? String(decodedTarget.dropFirst())
            : decodedTarget
        let rawPath = decodedTarget.hasPrefix("/")
            ? relativeTarget
            : [ownerDirectory, relativeTarget]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        var components: [Substring] = []
        for component in rawPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw ooxmlValidationError(
                        "contains an escaping relationship target: \(target)"
                    )
                }
                components.removeLast()
            case "":
                throw ooxmlValidationError(
                    "contains an invalid relationship target: \(target)"
                )
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else {
            throw ooxmlValidationError(
                "contains an empty relationship target"
            )
        }
        return components.joined(separator: "/")
    }

    private func crc32(_ data: Data) -> UInt32 {
        var result = UInt32.max
        paperPathUpdateCRC32(&result, with: data)
        return result ^ UInt32.max
    }
}

private func ooxmlValidationError(
    _ detail: String
) -> PaperPathError {
    .outputVerificationFailed(
        "the Office package \(detail)"
    )
}

private func paperPathIsSafeOOXMLPath(
    _ path: String
) -> Bool {
    let normalized = path.precomposedStringWithCanonicalMapping
    let components = path.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    return !path.isEmpty
        && path == normalized
        && !path.hasPrefix("/")
        && !path.hasSuffix("/")
        && !path.contains("\\")
        && !path.contains(":")
        && !path.contains("?")
        && !path.contains("#")
        && !path.contains("%")
        && path.utf8.count <= 512
        && !components.contains(where: {
            $0.isEmpty
                || $0 == "."
                || $0 == ".."
                || $0.hasSuffix(".")
                || String($0) != String($0).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        })
        && path.unicodeScalars.allSatisfy {
            let codePoint = $0.value
            let isBidirectionalControl =
                codePoint == 0x061c
                || codePoint == 0x200e
                || codePoint == 0x200f
                || (0x202a...0x202e).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
                && !isBidirectionalControl
        }
}

private func paperPathIsSafeOOXMLAttribute(
    _ value: String,
    maximumUTF8Bytes: Int
) -> Bool {
    !value.isEmpty
        && value.utf8.count <= maximumUTF8Bytes
        && value == value.precomposedStringWithCanonicalMapping
        && value == value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        && value.unicodeScalars.allSatisfy {
            let codePoint = $0.value
            let isBidirectionalControl =
                codePoint == 0x061c
                || codePoint == 0x200e
                || codePoint == 0x200f
                || (0x202a...0x202e).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            return !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
                && !isBidirectionalControl
        }
}

private final class OOXMLRelationshipCollector:
    NSObject,
    XMLParserDelegate {
    struct Relationship {
        let type: String
        let target: String
        let isExternal: Bool
    }

    private(set) var relationships: [Relationship] = []
    private(set) var hasRelationshipsRoot = false
    private(set) var hasMalformedRelationship = false
    private var identifiers: Set<String> = []
    private var depth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        defer { depth += 1 }
        if depth == 0 {
            guard elementName == "Relationships",
                  !hasRelationshipsRoot
            else {
                hasMalformedRelationship = true
                return
            }
            hasRelationshipsRoot = true
            return
        }
        guard depth == 1,
              elementName == "Relationship",
              relationships.count < 16_384
        else {
            hasMalformedRelationship = true
            return
        }
        guard let identifier = attributeDict["Id"],
              paperPathIsSafeOOXMLAttribute(
                identifier,
                maximumUTF8Bytes: 256
              ),
              let type = attributeDict["Type"],
              paperPathIsSafeOOXMLAttribute(
                type,
                maximumUTF8Bytes: 512
              ),
              let target = attributeDict["Target"],
              paperPathIsSafeOOXMLAttribute(
                target,
                maximumUTF8Bytes: 1_024
              ),
              identifiers.insert(identifier).inserted
        else {
            hasMalformedRelationship = true
            return
        }
        let targetMode = attributeDict["TargetMode"]
        guard targetMode == nil
                || targetMode == "Internal"
                || targetMode == "External"
        else {
            hasMalformedRelationship = true
            return
        }
        relationships.append(
            Relationship(
                type: type,
                target: target,
                isExternal: targetMode == "External"
            )
        )
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard depth > 0 else {
            hasMalformedRelationship = true
            return
        }
        depth -= 1
    }
}

private final class OOXMLContentTypesCollector:
    NSObject,
    XMLParserDelegate {
    private(set) var defaults: [String: String] = [:]
    private(set) var overrides: [String: String] = [:]
    private(set) var hasTypesRoot = false
    private(set) var hasMalformedDeclaration = false
    private var depth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        defer { depth += 1 }
        if depth == 0 {
            guard elementName == "Types",
                  !hasTypesRoot
            else {
                hasMalformedDeclaration = true
                return
            }
            hasTypesRoot = true
            return
        }
        guard depth == 1 else {
            hasMalformedDeclaration = true
            return
        }
        switch elementName {
        case "Default":
            guard let fileExtension = attributeDict["Extension"]?
                .lowercased(),
                  paperPathIsSafeOOXMLAttribute(
                    fileExtension,
                    maximumUTF8Bytes: 32
                  ),
                  !fileExtension.hasPrefix("."),
                  !fileExtension.contains("/"),
                  !fileExtension.contains("\\"),
                  let contentType = attributeDict["ContentType"],
                  paperPathIsSafeOOXMLAttribute(
                    contentType,
                    maximumUTF8Bytes: 256
                  ),
                  defaults[fileExtension] == nil
            else {
                hasMalformedDeclaration = true
                return
            }
            defaults[fileExtension] = contentType
        case "Override":
            guard let partName = attributeDict["PartName"],
                  partName.hasPrefix("/"),
                  let contentType = attributeDict["ContentType"],
                  paperPathIsSafeOOXMLAttribute(
                    contentType,
                    maximumUTF8Bytes: 256
                  )
            else {
                hasMalformedDeclaration = true
                return
            }
            let path = String(partName.dropFirst())
            guard paperPathIsSafeOOXMLPath(path),
                  overrides[path] == nil
            else {
                hasMalformedDeclaration = true
                return
            }
            overrides[path] = contentType
        default:
            hasMalformedDeclaration = true
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard depth > 0 else {
            hasMalformedDeclaration = true
            return
        }
        depth -= 1
    }
}

struct OfficeBatchArchiveSource: Sendable {
    let sourceURL: URL
    let archiveName: String
}

struct OfficeBatchArchiveService: Sendable {
    private static let maximumArchiveBytes: Int64 =
        1_100 * 1_024 * 1_024

    private struct CentralEntry {
        let name: Data
        let checksum: UInt32
        let size: UInt32
        let offset: UInt32
    }

    func createArchive(
        sources: [OfficeBatchArchiveSource],
        destination: URL,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws {
        let ordered = sources.sorted {
            if $0.archiveName == $1.archiveName {
                return $0.sourceURL.path < $1.sourceURL.path
            }
            return $0.archiveName < $1.archiveName
        }
        guard !ordered.isEmpty,
              ordered.count <= Int(UInt16.max)
        else {
            throw PaperPathError.insufficientSelection(
                "No files are available to archive."
            )
        }

        var seenNames: Set<String> = []
        for source in ordered {
            try validateArchiveName(source.archiveName)
            guard let identity = paperPathArchiveLeafNameIdentity(
                source.archiveName
            ),
            seenNames.insert(identity).inserted
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the archive contains duplicate file names"
                )
            }
        }
        var sourceSizes: [String: Int64] = [:]
        var totalSourceBytes: Int64 = 0
        var totalArchiveBytes: Int64 = 22
        for source in ordered {
            let values = try source.sourceURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= Int(UInt32.max)
            else {
                throw PaperPathError.fileTooLarge
            }
            let size = Int64(fileSize)
            let nameBytes = source.archiveName.utf8.count
            sourceSizes[source.archiveName] = size
            totalSourceBytes += size
            totalArchiveBytes += size + Int64(76 + nameBytes * 2)
        }
        guard totalArchiveBytes <= Self.maximumArchiveBytes else {
            throw PaperPathError.fileTooLarge
        }

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let parentValues = try parent.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let (requiredCapacity, capacityOverflow) = totalArchiveBytes
            .addingReportingOverflow(32 * 1_024 * 1_024)
        guard !capacityOverflow else {
            throw PaperPathError.fileTooLarge
        }
        if let available =
            parentValues.volumeAvailableCapacityForImportantUsage,
           available < requiredCapacity {
            throw PaperPathError.insufficientStorage
        }
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil
        ) else {
            throw PaperPathError.storageFailure(
                "The Office batch archive could not be created."
            )
        }
        let output: FileHandle
        do {
            try LocalFileSecurity.requireCompleteProtection(
                to: destination,
                fileManager: fileManager
            )
            LocalFileSecurity.excludeFromBackup(destination)
            output = try FileHandle(forWritingTo: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        var centralEntries: [CentralEntry] = []
        var checksummedBytes: Int64 = 0
        progress(
            PDFByteProgressUpdate(
                stage: .checksumming,
                processedBytes: 0,
                totalBytes: totalSourceBytes,
                totalUnitCount: ordered.count
            )
        )
        do {
            for (sourceIndex, source) in ordered.enumerated() {
                try Task.checkCancellation()
                let fileSize = sourceSizes[source.archiveName] ?? 0
                let name = Data(source.archiveName.utf8)
                guard name.count <= Int(UInt16.max) else {
                    throw PaperPathError.outputVerificationFailed(
                        "the archive file name is too long"
                    )
                }
                let outputOffset = try output.offset()
                guard outputOffset <= UInt64(UInt32.max) else {
                    throw PaperPathError.fileTooLarge
                }
                let checksumBase = checksummedBytes
                let input = try FileHandle(
                    forReadingFrom: source.sourceURL
                )
                let checksum: UInt32
                do {
                    let result = try crc32(from: input) { fileBytes in
                        progress(
                            PDFByteProgressUpdate(
                                stage: .checksumming,
                                processedBytes:
                                    checksumBase + fileBytes,
                                totalBytes: totalSourceBytes,
                                completedUnitCount:
                                    fileBytes >= fileSize
                                    ? sourceIndex + 1
                                    : sourceIndex,
                                totalUnitCount: ordered.count,
                                currentUnitName: source.archiveName
                            )
                        )
                    }
                    guard result.byteCount == fileSize else {
                        throw PaperPathError.outputVerificationFailed(
                            "an archive source changed while it was being read"
                        )
                    }
                    checksum = result.checksum
                    try input.seek(toOffset: 0)
                } catch {
                    try? input.close()
                    throw error
                }
                checksummedBytes += fileSize
                let size = UInt32(fileSize)

                var localHeader = Data()
                localHeader.appendLittleEndian(UInt32(0x04034b50))
                localHeader.appendLittleEndian(UInt16(20))
                localHeader.appendLittleEndian(UInt16(0x0800))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.appendLittleEndian(UInt16(0x0021))
                localHeader.appendLittleEndian(checksum)
                localHeader.appendLittleEndian(size)
                localHeader.appendLittleEndian(size)
                localHeader.appendLittleEndian(UInt16(name.count))
                localHeader.appendLittleEndian(UInt16(0))
                localHeader.append(name)
                try output.write(contentsOf: localHeader)
                let archiveBase =
                    Int64(outputOffset) + Int64(localHeader.count)
                progress(
                    PDFByteProgressUpdate(
                        stage: .archiving,
                        processedBytes: archiveBase,
                        totalBytes: totalArchiveBytes,
                        completedUnitCount: sourceIndex,
                        totalUnitCount: ordered.count,
                        currentUnitName: source.archiveName
                    )
                )
                do {
                    let copied = try copyFile(
                        from: input,
                        to: output
                    ) { copiedBytes in
                        progress(
                            PDFByteProgressUpdate(
                                stage: .archiving,
                                processedBytes:
                                    archiveBase + copiedBytes,
                                totalBytes: totalArchiveBytes,
                                completedUnitCount:
                                    copiedBytes >= fileSize
                                    ? sourceIndex + 1
                                    : sourceIndex,
                                totalUnitCount: ordered.count,
                                currentUnitName: source.archiveName
                            )
                        )
                    }
                    try input.close()
                    guard copied.byteCount == fileSize,
                          copied.checksum == checksum
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "an archive source changed while it was being copied"
                        )
                    }
                } catch {
                    try? input.close()
                    throw error
                }

                centralEntries.append(
                    CentralEntry(
                        name: name,
                        checksum: checksum,
                        size: size,
                        offset: UInt32(outputOffset)
                    )
                )
            }

            let centralOffset = try output.offset()
            guard centralOffset <= UInt64(UInt32.max) else {
                throw PaperPathError.fileTooLarge
            }
            var centralDirectory = Data()
            for entry in centralEntries {
                centralDirectory.appendLittleEndian(UInt32(0x02014b50))
                centralDirectory.appendLittleEndian(UInt16(20))
                centralDirectory.appendLittleEndian(UInt16(20))
                centralDirectory.appendLittleEndian(UInt16(0x0800))
                centralDirectory.appendLittleEndian(UInt16(0))
                centralDirectory.appendLittleEndian(UInt16(0))
                centralDirectory.appendLittleEndian(UInt16(0x0021))
                centralDirectory.appendLittleEndian(entry.checksum)
                centralDirectory.appendLittleEndian(entry.size)
                centralDirectory.appendLittleEndian(entry.size)
                centralDirectory.appendLittleEndian(UInt16(entry.name.count))
                centralDirectory.appendLittleEndian(UInt16(0))
                centralDirectory.appendLittleEndian(UInt16(0))
                centralDirectory.appendLittleEndian(UInt16(0))
                centralDirectory.appendLittleEndian(UInt16(0))
                centralDirectory.appendLittleEndian(UInt32(0))
                centralDirectory.appendLittleEndian(entry.offset)
                centralDirectory.append(entry.name)
            }
            guard centralDirectory.count <= Int(UInt32.max) else {
                throw PaperPathError.fileTooLarge
            }
            try output.write(contentsOf: centralDirectory)

            var endRecord = Data()
            endRecord.appendLittleEndian(UInt32(0x06054b50))
            endRecord.appendLittleEndian(UInt16(0))
            endRecord.appendLittleEndian(UInt16(0))
            endRecord.appendLittleEndian(UInt16(centralEntries.count))
            endRecord.appendLittleEndian(UInt16(centralEntries.count))
            endRecord.appendLittleEndian(UInt32(centralDirectory.count))
            endRecord.appendLittleEndian(UInt32(centralOffset))
            endRecord.appendLittleEndian(UInt16(0))
            try output.write(contentsOf: endRecord)
            try output.synchronize()
            try output.close()

            let archived = try destination.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            guard archived.isRegularFile == true,
                  archived.isSymbolicLink != true,
                  Int64(archived.fileSize ?? -1) == totalArchiveBytes
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office batch archive is incomplete"
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: destination,
                fileManager: fileManager
            )
            progress(
                PDFByteProgressUpdate(
                    stage: .archiving,
                    processedBytes: totalArchiveBytes,
                    totalBytes: totalArchiveBytes,
                    completedUnitCount: ordered.count,
                    totalUnitCount: ordered.count
                )
            )
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func validateArchiveName(
        _ name: String
    ) throws {
        guard paperPathIsSafeArchiveLeafName(name)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the archive contains an invalid file name"
            )
        }
    }

    private func copyFile(
        from input: FileHandle,
        to output: FileHandle,
        progress: (Int64) -> Void
    ) throws -> (byteCount: Int64, checksum: UInt32) {
        var copiedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        var checksum = UInt32.max
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 256 * 1_024),
                  !chunk.isEmpty
            else { break }
            try output.write(contentsOf: chunk)
            paperPathUpdateCRC32(&checksum, with: chunk)
            copiedBytes += Int64(chunk.count)
            if copiedBytes - lastReportedBytes >= reportingStride {
                progress(copiedBytes)
                lastReportedBytes = copiedBytes
            }
        }
        if copiedBytes != lastReportedBytes {
            progress(copiedBytes)
        }
        return (copiedBytes, checksum ^ UInt32.max)
    }

    private func crc32(
        from input: FileHandle,
        progress: (Int64) -> Void
    ) throws -> (checksum: UInt32, byteCount: Int64) {
        var result = UInt32.max
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 256 * 1_024),
                  !chunk.isEmpty
            else { break }
            paperPathUpdateCRC32(&result, with: chunk)
            processedBytes += Int64(chunk.count)
            if processedBytes - lastReportedBytes >= reportingStride {
                progress(processedBytes)
                lastReportedBytes = processedBytes
            }
        }
        if processedBytes != lastReportedBytes {
            progress(processedBytes)
        }
        return (result ^ UInt32.max, processedBytes)
    }
}

struct PDFVersionArchiveVerificationService: Sendable {
    private static let manifestName =
        "PaperPath-version-manifest.json"
    private static let deliveryManifestName =
        "PaperPath-delivery-receipt.json"
    private static let officeDeliveryManifestName =
        "PaperPath-delivery-manifest.json"
    private static let maximumArchiveBytes: Int64 =
        1_100 * 1_024 * 1_024
    private static let maximumEntryCount = 64
    private static let deliveryEntryCount = 2
    private static let maximumManifestBytes = 1 * 1_024 * 1_024
    private let timeAnchor: PDFOfficeTimeAnchor

    init(timeAnchor: PDFOfficeTimeAnchor = .process) {
        self.timeAnchor = timeAnchor
    }

    func verifyCoordinated(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> PDFVersionArchiveVerificationReport {
        try coordinatedRead(at: archiveURL) { coordinatedURL in
            try verify(
                archiveURL: coordinatedURL,
                extractionDirectory: extractionDirectory,
                progress: progress
            )
        }
    }

    func verifyDeliveryPackageCoordinated(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> PDFDeliveryPackageVerificationReport {
        try coordinatedRead(at: archiveURL) { coordinatedURL in
            try verifyDeliveryPackage(
                archiveURL: coordinatedURL,
                extractionDirectory: extractionDirectory,
                progress: progress
            )
        }
    }

    private struct EndRecord {
        let entryCount: Int
        let centralSize: UInt64
        let centralOffset: UInt64
    }

    private struct ObservedEntry {
        let byteCount: Int64
        let sha256: String
        let crc32: UInt32
        let crcMatches: Bool
        let hasPDFHeader: Bool
        let localHeaderOffset: UInt64
        let flags: UInt16
    }

    private struct StreamResult {
        let data: Data?
        let sha256: String
        let crc32: UInt32
        let prefix: Data
    }

    private struct ExtractionPreflight {
        let names: Set<String>
        let byteCount: Int64
    }

    private struct DecodedManifest {
        let manifest: PDFVersionArchiveManifest
        let signatureStatus: PDFOfficeReportVerificationStatus
        let signatureDetail: String
        let signerKeyID: String?
        let signerPublicKeyBase64: String?
        let trustStatus: PDFOfficeSignerTrustStatus
    }

    private struct ArchiveInspection {
        let archiveBytes: Int64
        let observed: [String: ObservedEntry]
        let manifestData: Data
        let extractedURLs: [String: URL]
    }

    private struct DeliverySignatureInspection {
        let status: PDFOfficeReportVerificationStatus
        let detail: String
        let keyID: String?
        let publicKeyBase64: String?
        let trustStatus: PDFOfficeSignerTrustStatus
    }

    struct OfficeDeliveryArchiveInspection: Sendable {
        let signedReport: PDFOfficeSignedVerificationReport
        let archiveByteCount: Int64
        let verifiedFileCount: Int
        let extractedFileURLs: [String: URL]
    }

    func verify(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> PDFVersionArchiveVerificationReport {
        if let extractionDirectory {
            let standardized = extractionDirectory.standardizedFileURL
            guard let managed =
                    PaperPathTemporaryArtifact.managedTopLevelItem(
                        containing: standardized,
                        allowedPrefixes: [
                            PaperPathTemporaryArtifact
                                .verifiedVersionArchivePrefix
                        ]
                    ),
                  managed == standardized
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            else {
                throw verificationFailure(
                    "the verified version directory is not managed by PaperPath"
                )
            }
        }
        let inspection = try inspectArchive(
            archiveURL: archiveURL,
            manifestName: Self.manifestName,
            maximumEntryCount: Self.maximumEntryCount,
            extractionDirectory: extractionDirectory,
            maximumExtractedEntryCount:
                PDFVersionArchiveManifest.maximumEntryCount,
            maximumExtractedBytes:
                PDFVersionArchiveManifest.maximumEntryByteCount,
            progress: progress
        )
        var keepsExtractedFiles = false
        defer {
            if !keepsExtractedFiles {
                for url in inspection.extractedURLs.values {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let decoded = try decodeManifest(
            inspection.manifestData,
            at: timeAnchor.trustedDate()
        )
        let report = makeReport(
            decoded: decoded,
            observed: inspection.observed,
            extractedURLs: inspection.extractedURLs,
            archiveName: paperPathSafeExternalFileName(
                archiveURL.lastPathComponent
            ),
            archiveBytes: inspection.archiveBytes
        )
        keepsExtractedFiles = report.canRecoverArtifacts
        return report
    }

    func verifyDeliveryPackage(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> PDFDeliveryPackageVerificationReport {
        if let extractionDirectory {
            let standardized = extractionDirectory.standardizedFileURL
            guard let managed =
                    PaperPathTemporaryArtifact.managedTopLevelItem(
                        containing: standardized,
                        allowedPrefixes: [
                            PaperPathTemporaryArtifact
                                .verifiedDeliveryPackagePrefix
                        ]
                    ),
                  managed == standardized
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            else {
                throw verificationFailure(
                    "the verified delivery directory is not managed by PaperPath"
                )
            }
        }
        let inspection = try inspectArchive(
            archiveURL: archiveURL,
            manifestName: Self.deliveryManifestName,
            maximumEntryCount: Self.deliveryEntryCount,
            extractionDirectory: extractionDirectory,
            progress: progress
        )
        var keepsExtractedArtifact = false
        defer {
            if !keepsExtractedArtifact,
               let extractedURL = inspection.extractedURLs.values.first {
                try? FileManager.default.removeItem(at: extractedURL)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            PDFSignedDeliveryPackageManifest.self,
            from: inspection.manifestData
        ),
        signed.manifest.isStructurallyValid(
            at: timeAnchor.trustedDate()
        )
        else {
            throw verificationFailure(
                "the delivery package manifest is invalid"
            )
        }

        let manifest = signed.manifest
        let signature = verifyDeliverySignature(signed)
        let expectedNames: Set<String> = [
            Self.deliveryManifestName,
            manifest.artifact.fileName
        ]
        let observedNames = Set(inspection.observed.keys)
        var failures: [String] = []
        for name in observedNames.subtracting(expectedNames).sorted() {
            failures.append(
                AppLocalization.format(
                    "Unlisted archive entry: %@",
                    name
                )
            )
        }
        for name in expectedNames.subtracting(observedNames).sorted() {
            failures.append(
                AppLocalization.format(
                    "Missing archive entry: %@",
                    name
                )
            )
        }
        if inspection.observed[Self.deliveryManifestName]?
            .crcMatches != true {
            failures.append("Receipt ZIP CRC")
        }

        let artifact = inspection.observed[
            manifest.artifact.fileName
        ]
        if let artifact {
            if artifact.byteCount != manifest.artifact.byteCount {
                failures.append("PDF byte count")
            }
            if artifact.sha256.caseInsensitiveCompare(
                manifest.artifact.sha256
            ) != .orderedSame {
                failures.append("PDF SHA-256")
            }
            if !artifact.crcMatches {
                failures.append("PDF ZIP CRC")
            }
            if !artifact.hasPDFHeader {
                failures.append("PDF header")
            }
        }
        if let extractedURL = inspection.extractedURLs[
            manifest.artifact.fileName
        ] {
            if let document = PDFDocument(url: extractedURL) {
                if document.isEncrypted != manifest.isEncrypted {
                    failures.append("PDF encryption state")
                }
                if !document.isLocked,
                   document.pageCount != manifest.artifact.pageCount {
                    failures.append("PDF page count")
                }
            } else {
                failures.append("PDF readability")
            }
        }

        let verifiedArtifactURL: URL?
        if failures.isEmpty,
           signature.status == .verified,
           let extractedURL = inspection.extractedURLs[
               manifest.artifact.fileName
           ] {
            verifiedArtifactURL = extractedURL
            keepsExtractedArtifact = verifiedArtifactURL != nil
        } else {
            verifiedArtifactURL = nil
        }

        return PDFDeliveryPackageVerificationReport(
            archiveName: paperPathSafeExternalFileName(
                archiveURL.lastPathComponent
            ),
            archiveByteCount: inspection.archiveBytes,
            packageID: manifest.packageID,
            packageCreatedAt: manifest.createdAt,
            verifiedAt: timeAnchor.trustedDate(),
            artifactFileName: manifest.artifact.fileName,
            artifactByteCount: manifest.artifact.byteCount,
            artifactPageCount: manifest.artifact.pageCount,
            isEncrypted: manifest.isEncrypted,
            operation: manifest.operation,
            deliveryReceiptID: manifest.deliveryReceiptID,
            expectedSHA256: manifest.artifact.sha256,
            actualSHA256: artifact?.sha256,
            checks: manifest.checks,
            integrityFailures: failures,
            signatureStatus: signature.status,
            signatureDetail: signature.detail,
            signerKeyID: signature.keyID,
            signerPublicKeyBase64: signature.publicKeyBase64,
            trustStatus: signature.trustStatus,
            trustedSignerName: nil,
            verifiedArtifactURL: verifiedArtifactURL
        )
    }

    func verifyOfficeDeliveryArchive(
        archiveURL: URL,
        extractionDirectory: URL? = nil,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> OfficeDeliveryArchiveInspection {
        if let extractionDirectory {
            let standardized = extractionDirectory.standardizedFileURL
            guard let managed =
                    PaperPathTemporaryArtifact.managedTopLevelItem(
                        containing: standardized,
                        allowedPrefixes: [
                            PaperPathTemporaryArtifact
                                .verifiedOfficeDeliveryPrefix
                        ]
                    ),
                  managed == standardized
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            else {
                throw verificationFailure(
                    "the verified Office directory is not managed by PaperPath"
                )
            }
        }
        let inspection = try inspectArchive(
            archiveURL: archiveURL,
            manifestName: Self.officeDeliveryManifestName,
            maximumEntryCount:
                PDFOfficeExternalMatchReport.maximumFileCount + 1,
            extractionDirectory: extractionDirectory,
            extractionExtensions: Set(
                PDFTextExportFormat.allCases.map {
                    $0.fileExtension.lowercased()
                }
            ),
            maximumExtractedEntryCount:
                PDFOfficeExternalMatchReport.maximumFileCount,
            maximumExtractedBytes:
                PDFOfficeExternalMatchReport.maximumBatchBytes,
            progress: progress
        )
        var keepsExtractedFiles = false
        defer {
            if !keepsExtractedFiles {
                for url in inspection.extractedURLs.values {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signedReport = try? decoder.decode(
            PDFOfficeSignedVerificationReport.self,
            from: inspection.manifestData
        ),
        signedReport.payload.isStructurallyValid(
            at: timeAnchor.trustedDate()
        )
        else {
            throw verificationFailure(
                "the Office delivery manifest is invalid"
            )
        }

        let expectedNames = Set(
            signedReport.payload.files.map(\.archiveName)
        ).union([Self.officeDeliveryManifestName])
        let observedNames = Set(inspection.observed.keys)
        guard observedNames == expectedNames,
              inspection.observed[
                  Self.officeDeliveryManifestName
              ]?.crcMatches == true
        else {
            throw verificationFailure(
                "the ZIP entries do not match the signed Office inventory"
            )
        }

        for file in signedReport.payload.files {
            try Task.checkCancellation()
            guard let observed = inspection.observed[
                file.archiveName
            ],
            observed.crcMatches,
            observed.byteCount == file.byteCount,
            observed.sha256.caseInsensitiveCompare(file.sha256)
                == .orderedSame
            else {
                throw verificationFailure(
                    AppLocalization.format(
                        "Office ZIP entry failed verification: %@",
                        file.archiveName
                    )
                )
            }
        }
        if extractionDirectory != nil {
            let expectedFileNames = Set(
                signedReport.payload.files.map(\.archiveName)
            )
            guard Set(inspection.extractedURLs.keys)
                    == expectedFileNames
            else {
                throw verificationFailure(
                    "the verified Office files could not be extracted"
                )
            }
        }
        keepsExtractedFiles = true
        return OfficeDeliveryArchiveInspection(
            signedReport: signedReport,
            archiveByteCount: inspection.archiveBytes,
            verifiedFileCount: signedReport.payload.files.count,
            extractedFileURLs: inspection.extractedURLs
        )
    }

    private func inspectArchive(
        archiveURL: URL,
        manifestName: String,
        maximumEntryCount: Int,
        extractionDirectory: URL? = nil,
        extractionExtensions: Set<String> = ["pdf"],
        maximumExtractedEntryCount: Int = 1,
        maximumExtractedBytes: Int64 = Self.maximumArchiveBytes,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> ArchiveInspection {
        try Task.checkCancellation()
        let values = try archiveURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let rawSize = values.fileSize,
              rawSize >= 22
        else {
            throw verificationFailure(
                "the selected archive is not a readable ZIP file"
            )
        }
        let archiveBytes = Int64(rawSize)
        guard archiveBytes <= Self.maximumArchiveBytes else {
            throw PaperPathError.fileTooLarge
        }
        let sourceModificationDate = values.contentModificationDate
        let sourceIdentifier = values.fileResourceIdentifier

        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }
        let end = try readEndRecord(
            from: input,
            archiveBytes: UInt64(rawSize)
        )
        guard end.entryCount > 0,
              end.entryCount <= maximumEntryCount,
              end.centralOffset + end.centralSize + 22
                == UInt64(rawSize)
        else {
            throw verificationFailure(
                "the ZIP directory is incomplete or exceeds the entry limit"
            )
        }
        let extractionNames: Set<String>
        if let extractionDirectory {
            let preflight = try preflightExtraction(
                from: input,
                payloadEnd: end.centralOffset,
                extensions: extractionExtensions,
                maximumArchiveEntryCount: maximumEntryCount,
                maximumExtractedEntryCount:
                    maximumExtractedEntryCount,
                maximumBytes: maximumExtractedBytes
            )
            extractionNames = preflight.names
            try prepareExtractionDirectory(
                extractionDirectory,
                requiredBytes: preflight.byteCount
            )
        } else {
            extractionNames = []
        }

        progress(
            PDFByteProgressUpdate(
                stage: .verifying,
                processedBytes: 0,
                totalBytes: archiveBytes,
                totalUnitCount: end.entryCount
            )
        )
        try input.seek(toOffset: 0)
        var observed: [String: ObservedEntry] = [:]
        var observedIdentities: Set<String> = []
        var manifestData: Data?
        var extractedURLs: [String: URL] = [:]
        var completedInspection = false
        defer {
            if !completedInspection {
                for url in extractedURLs.values {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        var entryIndex = 0
        while try input.offset() < end.centralOffset {
            try Task.checkCancellation()
            guard entryIndex < maximumEntryCount else {
                throw verificationFailure(
                    "the ZIP payload exceeds the entry limit"
                )
            }
            let localHeaderOffset = try input.offset()
            let header = try readExactly(
                30,
                from: input,
                context: "local file header"
            )
            guard header.uint32(at: 0) == 0x04034b50 else {
                throw verificationFailure(
                    "a ZIP local file header is invalid"
                )
            }
            let flags = header.uint16(at: 6)
            let method = header.uint16(at: 8)
            let expectedCRC = header.uint32(at: 14)
            let compressedSize = UInt64(header.uint32(at: 18))
            let uncompressedSize = UInt64(header.uint32(at: 22))
            let nameLength = Int(header.uint16(at: 26))
            let extraLength = UInt64(header.uint16(at: 28))
            guard flags == 0x0800,
                  method == 0,
                  compressedSize == uncompressedSize,
                  nameLength > 0
            else {
                throw verificationFailure(
                    "the archive must use unencrypted STORE-only entries"
                )
            }
            guard compressedSize <= UInt64(Int64.max),
                  compressedSize <= UInt64(Self.maximumArchiveBytes)
            else {
                throw PaperPathError.fileTooLarge
            }
            let nameData = try readExactly(
                nameLength,
                from: input,
                context: "file name"
            )
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw verificationFailure(
                    "an archive file name is not valid UTF-8"
                )
            }
            try validateArchiveName(name)
            guard let nameIdentity =
                    paperPathArchiveLeafNameIdentity(name),
                  observedIdentities.insert(nameIdentity).inserted,
                  observed[name] == nil
            else {
                throw verificationFailure(
                    "the archive contains duplicate file names"
                )
            }
            let afterName = try input.offset()
            guard afterName + extraLength <= end.centralOffset else {
                throw verificationFailure(
                    "an archive extra field exceeds the ZIP directory"
                )
            }
            try input.seek(toOffset: afterName + extraLength)
            let collectsData = name == manifestName
            if collectsData,
               compressedSize > UInt64(Self.maximumManifestBytes) {
                throw verificationFailure(
                    "the archive manifest exceeds 1 MB"
                )
            }
            let dataOffset = try input.offset()
            let isPDF = name.lowercased().hasSuffix(".pdf")
            let extractionOutput: FileHandle?
            let extractedURL: URL?
            if extractionNames.contains(name),
               let extractionDirectory {
                let destination = extractionDirectory
                    .appendingPathComponent(name)
                guard destination.deletingLastPathComponent()
                        .standardizedFileURL
                        == extractionDirectory.standardizedFileURL,
                      !FileManager.default.fileExists(
                          atPath: destination.path
                      ),
                      FileManager.default.createFile(
                        atPath: destination.path,
                        contents: nil,
                        attributes: [
                            .protectionKey: FileProtectionType.complete
                        ]
                      )
                else {
                    throw PaperPathError.storageFailure(
                        isPDF
                            ? "The verified PDF could not be prepared."
                            : "The verified Office file could not be prepared."
                    )
                }
                do {
                    try LocalFileSecurity.requireCompleteProtection(
                        to: destination
                    )
                    LocalFileSecurity.excludeFromBackup(destination)
                    extractionOutput = try FileHandle(
                        forWritingTo: destination
                    )
                    extractedURL = destination
                    extractedURLs[name] = destination
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
            } else {
                extractionOutput = nil
                extractedURL = nil
            }
            let stream: StreamResult
            do {
                stream = try streamEntry(
                    from: input,
                    byteCount: Int64(compressedSize),
                    collectsData: collectsData,
                    output: extractionOutput
                ) { processedBytes in
                    progress(
                        PDFByteProgressUpdate(
                            stage: .verifying,
                            processedBytes: min(
                                archiveBytes,
                                Int64(dataOffset) + processedBytes
                            ),
                            totalBytes: archiveBytes,
                            completedUnitCount: entryIndex,
                            totalUnitCount: end.entryCount,
                            currentUnitName: name
                        )
                    )
                }
                if let extractionOutput,
                   let extractedURL {
                    try extractionOutput.synchronize()
                    try extractionOutput.close()
                    try LocalFileSecurity.requireCompleteProtection(
                        to: extractedURL
                    )
                    let extractedValues = try extractedURL
                        .resourceValues(
                            forKeys: [.isRegularFileKey, .fileSizeKey]
                        )
                    guard extractedValues.isRegularFile == true,
                          Int64(extractedValues.fileSize ?? -1)
                            == Int64(compressedSize)
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            isPDF
                                ? "the verified PDF was not written completely"
                                : "the verified Office file was not written completely"
                        )
                    }
                }
            } catch {
                try? extractionOutput?.close()
                throw error
            }
            observed[name] = ObservedEntry(
                byteCount: Int64(uncompressedSize),
                sha256: stream.sha256,
                crc32: stream.crc32,
                crcMatches: stream.crc32 == expectedCRC,
                hasPDFHeader: !isPDF
                    || stream.prefix.starts(with: Data("%PDF-".utf8)),
                localHeaderOffset: localHeaderOffset,
                flags: flags
            )
            if collectsData {
                manifestData = stream.data
            }
            entryIndex += 1
            guard try input.offset() <= end.centralOffset else {
                throw verificationFailure(
                    "an archive entry overlaps the ZIP directory"
                )
            }
        }
        guard try input.offset() == end.centralOffset else {
            throw verificationFailure(
                "the ZIP payload does not end at its directory"
            )
        }
        let centralNames = try verifyCentralDirectory(
            from: input,
            record: end,
            observed: observed
        )
        guard centralNames == Set(observed.keys),
              observed.count == end.entryCount,
              let manifestData,
              observed[manifestName]?.crcMatches == true
        else {
            throw verificationFailure(
                "the archive manifest or entry directory is incomplete"
            )
        }
        let finalValues = try archiveURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              finalValues.fileSize == rawSize,
              finalValues.contentModificationDate
                == sourceModificationDate,
              fileResourceIdentifiersMatch(
                sourceIdentifier,
                finalValues.fileResourceIdentifier
              )
        else {
            throw verificationFailure(
                "the selected archive changed during verification"
            )
        }
        progress(
            PDFByteProgressUpdate(
                stage: .verifying,
                processedBytes: archiveBytes,
                totalBytes: archiveBytes,
                completedUnitCount: end.entryCount,
                totalUnitCount: end.entryCount,
                currentUnitName: manifestName
            )
        )
        completedInspection = true
        return ArchiveInspection(
            archiveBytes: archiveBytes,
            observed: observed,
            manifestData: manifestData,
            extractedURLs: extractedURLs
        )
    }

    private func coordinatedRead<Result>(
        at sourceURL: URL,
        operation: (URL) throws -> Result
    ) throws -> Result {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Swift.Result<Result, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Swift.Result {
                try Task.checkCancellation()
                return try operation(coordinatedURL)
            }
        }
        try Task.checkCancellation()
        if let operationResult {
            return try operationResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        throw verificationFailure(
            "the selected archive could not be coordinated for reading"
        )
    }

    private func preflightExtraction(
        from input: FileHandle,
        payloadEnd: UInt64,
        extensions: Set<String>,
        maximumArchiveEntryCount: Int,
        maximumExtractedEntryCount: Int,
        maximumBytes: Int64
    ) throws -> ExtractionPreflight {
        try input.seek(toOffset: 0)
        var names: Set<String> = []
        var nameIdentities: Set<String> = []
        var extractionNames: Set<String> = []
        var extractedBytes: Int64 = 0
        var entryCount = 0
        while try input.offset() < payloadEnd {
            try Task.checkCancellation()
            guard entryCount < maximumArchiveEntryCount else {
                throw verificationFailure(
                    "the ZIP payload exceeds the entry limit"
                )
            }
            let header = try readExactly(
                30,
                from: input,
                context: "local file header"
            )
            guard header.uint32(at: 0) == 0x04034b50 else {
                throw verificationFailure(
                    "a ZIP local file header is invalid"
                )
            }
            let flags = header.uint16(at: 6)
            let method = header.uint16(at: 8)
            let compressedSize = UInt64(header.uint32(at: 18))
            let uncompressedSize = UInt64(header.uint32(at: 22))
            let nameLength = Int(header.uint16(at: 26))
            let extraLength = UInt64(header.uint16(at: 28))
            guard flags == 0x0800,
                  method == 0,
                  compressedSize == uncompressedSize,
                  compressedSize <= UInt64(Int64.max),
                  nameLength > 0
            else {
                throw verificationFailure(
                    "the archive must use unencrypted STORE-only entries"
                )
            }
            let nameData = try readExactly(
                nameLength,
                from: input,
                context: "file name"
            )
            guard let name = String(data: nameData, encoding: .utf8)
            else {
                throw verificationFailure(
                    "an archive file name is not valid UTF-8"
                )
            }
            try validateArchiveName(name)
            guard let nameIdentity =
                    paperPathArchiveLeafNameIdentity(name),
                  nameIdentities.insert(nameIdentity).inserted,
                  names.insert(name).inserted
            else {
                throw verificationFailure(
                    "the archive contains duplicate file names"
                )
            }
            let current = try input.offset()
            let nextOffset = current + extraLength + compressedSize
            guard nextOffset <= payloadEnd else {
                throw verificationFailure(
                    "an archive entry overlaps the ZIP directory"
                )
            }
            if extensions.contains(
                URL(fileURLWithPath: name)
                    .pathExtension
                    .lowercased()
            ) {
                let (nextBytes, overflow) = extractedBytes
                    .addingReportingOverflow(Int64(compressedSize))
                guard !overflow,
                      nextBytes <= maximumBytes,
                      extractionNames.count
                        < maximumExtractedEntryCount
                else {
                    throw PaperPathError.fileTooLarge
                }
                extractedBytes = nextBytes
                extractionNames.insert(name)
            }
            try input.seek(toOffset: nextOffset)
            entryCount += 1
        }
        guard try input.offset() == payloadEnd else {
            throw verificationFailure(
                "the ZIP payload does not end at its directory"
            )
        }
        return ExtractionPreflight(
            names: extractionNames,
            byteCount: extractedBytes
        )
    }

    private func prepareExtractionDirectory(
        _ directory: URL,
        requiredBytes: Int64
    ) throws {
        let fileManager = FileManager.default
        let standardized = directory.standardizedFileURL
        let values = try standardized.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .volumeAvailableCapacityForImportantUsageKey
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              ooxmlBoundedDirectoryContents(
                  at: standardized,
                  includingPropertiesForKeys: [],
                  maximumEntryCount: 1
              )?.isEmpty == true
        else {
            throw verificationFailure(
                "the verified output directory is unavailable"
            )
        }
        let (capacityWithReserve, overflow) = requiredBytes
            .addingReportingOverflow(16 * 1_024 * 1_024)
        guard !overflow else {
            throw PaperPathError.fileTooLarge
        }
        if let capacity =
            values.volumeAvailableCapacityForImportantUsage,
           capacity < capacityWithReserve {
            throw PaperPathError.insufficientStorage
        }
        try LocalFileSecurity.requireCompleteProtection(
            to: standardized,
            fileManager: fileManager
        )
        LocalFileSecurity.excludeFromBackup(standardized)
    }

    private func verifyCentralDirectory(
        from input: FileHandle,
        record: EndRecord,
        observed: [String: ObservedEntry]
    ) throws -> Set<String> {
        var names: Set<String> = []
        var nameIdentities: Set<String> = []
        for _ in 0..<record.entryCount {
            try Task.checkCancellation()
            let header = try readExactly(
                46,
                from: input,
                context: "central directory header"
            )
            let flags = header.uint16(at: 8)
            guard header.uint32(at: 0) == 0x02014b50,
                  flags == 0x0800,
                  header.uint16(at: 10) == 0,
                  header.uint32(at: 20) == header.uint32(at: 24)
            else {
                throw verificationFailure(
                    "a ZIP central directory entry is invalid"
                )
            }
            let nameLength = Int(header.uint16(at: 28))
            let extraLength = UInt64(header.uint16(at: 30))
            let commentLength = UInt64(header.uint16(at: 32))
            let centralCRC = header.uint32(at: 16)
            let centralSize = Int64(header.uint32(at: 24))
            let localHeaderOffset = UInt64(header.uint32(at: 42))
            let nameData = try readExactly(
                nameLength,
                from: input,
                context: "central directory file name"
            )
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw verificationFailure(
                    "a central directory file name is invalid"
                )
            }
            try validateArchiveName(name)
            guard let nameIdentity =
                    paperPathArchiveLeafNameIdentity(name),
                  nameIdentities.insert(nameIdentity).inserted,
                  names.insert(name).inserted,
                  let local = observed[name],
                  local.byteCount == centralSize,
                  local.crc32 == centralCRC,
                  local.localHeaderOffset == localHeaderOffset,
                  local.flags == flags
            else {
                throw verificationFailure(
                    "the ZIP directory does not match its local entries"
                )
            }
            let current = try input.offset()
            let skip = extraLength + commentLength
            guard current + skip
                    <= record.centralOffset + record.centralSize
            else {
                throw verificationFailure(
                    "a ZIP directory field exceeds its declared size"
                )
            }
            try input.seek(toOffset: current + skip)
        }
        guard try input.offset()
                == record.centralOffset + record.centralSize
        else {
            throw verificationFailure(
                "the ZIP central directory size does not match"
            )
        }
        return names
    }

    private func fileResourceIdentifiersMatch(
        _ first: Any?,
        _ second: Any?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case let (first as NSObject, second):
            return first.isEqual(second)
        default:
            return false
        }
    }

    private func readEndRecord(
        from input: FileHandle,
        archiveBytes: UInt64
    ) throws -> EndRecord {
        guard archiveBytes >= 22 else {
            throw verificationFailure("the ZIP end record is missing")
        }
        try input.seek(toOffset: archiveBytes - 22)
        let data = try readExactly(
            22,
            from: input,
            context: "ZIP end record"
        )
        guard data.uint32(at: 0) == 0x06054b50,
              data.uint16(at: 4) == 0,
              data.uint16(at: 6) == 0,
              data.uint16(at: 8) == data.uint16(at: 10),
              data.uint16(at: 20) == 0
        else {
            throw verificationFailure(
                "multi-disk or commented ZIP archives are not supported"
            )
        }
        return EndRecord(
            entryCount: Int(data.uint16(at: 10)),
            centralSize: UInt64(data.uint32(at: 12)),
            centralOffset: UInt64(data.uint32(at: 16))
        )
    }

    private func streamEntry(
        from input: FileHandle,
        byteCount: Int64,
        collectsData: Bool,
        output: FileHandle? = nil,
        progress: (Int64) -> Void = { _ in }
    ) throws -> StreamResult {
        var remaining = byteCount
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        var hasher = SHA256()
        var crc = UInt32.max
        var collected = collectsData ? Data() : nil
        var prefix = Data()
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(remaining, 256 * 1_024))
            guard let chunk = try input.read(upToCount: requested),
                  !chunk.isEmpty
            else {
                throw verificationFailure(
                    "an archive entry ended before its declared size"
                )
            }
            remaining -= Int64(chunk.count)
            processedBytes += Int64(chunk.count)
            try output?.write(contentsOf: chunk)
            hasher.update(data: chunk)
            crc = updateCRC32(crc, with: chunk)
            if prefix.count < 5 {
                prefix.append(chunk.prefix(5 - prefix.count))
            }
            collected?.append(chunk)
            if processedBytes - lastReportedBytes >= reportingStride
                || remaining == 0 {
                progress(processedBytes)
                lastReportedBytes = processedBytes
            }
        }
        return StreamResult(
            data: collected,
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            crc32: crc ^ UInt32.max,
            prefix: prefix
        )
    }

    private func updateCRC32(
        _ seed: UInt32,
        with data: Data
    ) -> UInt32 {
        var result = seed
        paperPathUpdateCRC32(&result, with: data)
        return result
    }

    private func decodeManifest(
        _ data: Data,
        at date: Date
    ) throws -> DecodedManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: DecodedManifest
        if let signed = try? decoder.decode(
            PDFSignedVersionArchiveManifest.self,
            from: data
        ) {
            decoded = verifySignedManifest(signed)
        } else if let manifest = try? decoder.decode(
            PDFVersionArchiveManifest.self,
            from: data
        ) {
            let isLegacyUnsigned = [
                "PaperPath Version Archive V47",
                "PaperPath Version Archive V48"
            ].contains(manifest.schema)
            decoded = DecodedManifest(
                manifest: manifest,
                signatureStatus: isLegacyUnsigned
                    ? .unsupported
                    : .invalid,
                signatureDetail: isLegacyUnsigned
                    ? "This V47/V48 archive predates PaperPath source signatures."
                    : "This archive schema requires a PaperPath source signature.",
                signerKeyID: nil,
                signerPublicKeyBase64: nil,
                trustStatus: isLegacyUnsigned
                    ? .unsupported
                    : .invalid
            )
        } else {
            throw verificationFailure(
                "the version manifest could not be decoded"
            )
        }
        try validateManifest(decoded.manifest, at: date)
        return decoded
    }

    private func verifySignedManifest(
        _ signed: PDFSignedVersionArchiveManifest
    ) -> DecodedManifest {
        let envelope = signed.signature
        guard signed.manifest.schema
                == PDFVersionArchiveManifest.currentSchema,
              let signatureMaterial =
                canonicalSignatureMaterial(envelope),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: signatureMaterial.publicKey
              ),
              let canonicalManifest = try? canonicalData(
                signed.manifest
              )
        else {
            return DecodedManifest(
                manifest: signed.manifest,
                signatureStatus: .invalid,
                signatureDetail:
                    "The archive uses an invalid signing envelope.",
                signerKeyID: envelope.keyID,
                signerPublicKeyBase64: envelope.publicKeyBase64,
                trustStatus: .invalid
            )
        }
        let calculatedKeyID = SHA256.hash(
            data: signatureMaterial.publicKey
        )
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let isValid = calculatedKeyID == envelope.keyID
            && publicKey.isValidSignature(
                signatureMaterial.signature,
                for: canonicalManifest
            )
        return DecodedManifest(
            manifest: signed.manifest,
            signatureStatus: isValid ? .verified : .invalid,
            signatureDetail: isValid
                ? "The version manifest matches its Ed25519 source signature."
                : "The manifest, public key, Key ID, or signature was changed.",
            signerKeyID: envelope.keyID,
            signerPublicKeyBase64: envelope.publicKeyBase64,
            trustStatus: isValid ? .unknown : .invalid
        )
    }

    private func verifyDeliverySignature(
        _ signed: PDFSignedDeliveryPackageManifest
    ) -> DeliverySignatureInspection {
        let envelope = signed.signature
        guard signed.manifest.schema
                == PDFDeliveryPackageManifest.currentSchema,
              let signatureMaterial =
                canonicalSignatureMaterial(envelope),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: signatureMaterial.publicKey
              ),
              let canonicalManifest = try? canonicalData(
                signed.manifest
              )
        else {
            return DeliverySignatureInspection(
                status: .invalid,
                detail:
                    "The delivery package uses an invalid signing envelope.",
                keyID: envelope.keyID,
                publicKeyBase64: envelope.publicKeyBase64,
                trustStatus: .invalid
            )
        }
        let calculatedKeyID = SHA256.hash(
            data: signatureMaterial.publicKey
        )
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let isValid = calculatedKeyID == envelope.keyID
            && publicKey.isValidSignature(
                signatureMaterial.signature,
                for: canonicalManifest
            )
        return DeliverySignatureInspection(
            status: isValid ? .verified : .invalid,
            detail: isValid
                ? "The receipt manifest matches its Ed25519 source signature."
                : "The receipt, public key, Key ID, or signature was changed.",
            keyID: envelope.keyID,
            publicKeyBase64: envelope.publicKeyBase64,
            trustStatus: isValid ? .unknown : .invalid
        )
    }

    private func canonicalSignatureMaterial(
        _ envelope: PDFOfficeVerificationSignature
    ) -> (publicKey: Data, signature: Data)? {
        guard envelope.algorithm == "Ed25519",
              let publicKey = Data(
                base64Encoded: envelope.publicKeyBase64,
                options: []
              ),
              let signature = Data(
                base64Encoded: envelope.signatureBase64,
                options: []
              ),
              publicKey.count == 32,
              signature.count == 64,
              publicKey.base64EncodedString()
                == envelope.publicKeyBase64,
              signature.base64EncodedString()
                == envelope.signatureBase64
        else { return nil }
        return (publicKey, signature)
    }

    private func canonicalData(
        _ manifest: PDFVersionArchiveManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func canonicalData(
        _ manifest: PDFDeliveryPackageManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func validateManifest(
        _ manifest: PDFVersionArchiveManifest,
        at date: Date
    ) throws {
        guard manifest.isStructurallyValid(at: date)
        else {
            throw verificationFailure(
                "the version manifest schema or entry count is invalid"
            )
        }
        for entry in manifest.entries {
            try validateArchiveName(entry.fileName)
        }
    }

    private func makeReport(
        decoded: DecodedManifest,
        observed: [String: ObservedEntry],
        extractedURLs: [String: URL],
        archiveName: String,
        archiveBytes: Int64
    ) -> PDFVersionArchiveVerificationReport {
        let manifest = decoded.manifest
        let manifestNames = Set(
            manifest.entries.map(\.fileName)
        )
        let payloadNames = Set(
            observed.keys.filter { $0 != Self.manifestName }
        )
        var structuralFailures: [String] = []
        for name in payloadNames.subtracting(manifestNames).sorted() {
            structuralFailures.append(
                AppLocalization.format(
                    "Unlisted archive entry: %@",
                    name
                )
            )
        }
        let items = manifest.entries.map { entry in
            guard let actual = observed[entry.fileName] else {
                return PDFVersionArchiveVerificationItem(
                    id: entry.snapshotID,
                    documentID: entry.documentID,
                    fileName: entry.fileName,
                    title: entry.title,
                    byteCount: entry.byteCount,
                    pageCount: entry.pageCount,
                    expectedSHA256: entry.sha256,
                    actualSHA256: nil,
                    linkedDeliveryReceiptID:
                        entry.linkedDeliveryReceiptID,
                    status: .failed,
                    detail: "File missing from archive"
                )
            }
            var failures: [String] = []
            if actual.byteCount != entry.byteCount {
                failures.append("byte count")
            }
            if actual.sha256.lowercased()
                != entry.sha256.lowercased() {
                failures.append("SHA-256")
            }
            if !actual.crcMatches {
                failures.append("ZIP CRC")
            }
            if !actual.hasPDFHeader {
                failures.append("PDF header")
            }
            if let extractedURL = extractedURLs[entry.fileName] {
                if let document = PDFDocument(url: extractedURL),
                   !document.isLocked {
                    if document.pageCount != entry.pageCount {
                        failures.append("page count")
                    }
                } else {
                    failures.append("PDF readability")
                }
            }
            return PDFVersionArchiveVerificationItem(
                id: entry.snapshotID,
                documentID: entry.documentID,
                fileName: entry.fileName,
                title: entry.title,
                byteCount: entry.byteCount,
                pageCount: entry.pageCount,
                expectedSHA256: entry.sha256,
                actualSHA256: actual.sha256,
                linkedDeliveryReceiptID:
                    entry.linkedDeliveryReceiptID,
                status: failures.isEmpty ? .verified : .failed,
                detail: failures.isEmpty
                    ? "Manifest, CRC, bytes, and SHA-256 match"
                    : AppLocalization.format(
                        "Mismatch: %@",
                        failures.joined(separator: ", ")
                    )
            )
        }
        let canRetainExtractedFiles =
            decoded.signatureStatus == .verified
            && structuralFailures.isEmpty
            && items.count == manifest.entries.count
            && items.allSatisfy { $0.status == .verified }
            && Set(extractedURLs.keys) == manifestNames
        let verifiedArtifacts = canRetainExtractedFiles
            ? items.compactMap { item in
                extractedURLs[item.fileName].map {
                    PDFVersionArchiveVerifiedArtifact(
                        item: item,
                        url: $0
                    )
                }
            }
            : []
        return PDFVersionArchiveVerificationReport(
            id: UUID(),
            archiveName: archiveName,
            archiveByteCount: archiveBytes,
            schema: manifest.schema,
            archiveCreatedAt: manifest.createdAt,
            verifiedAt: timeAnchor.trustedDate(),
            manifestEntryCount: manifest.entries.count,
            archiveEntryCount: payloadNames.count,
            items: items,
            structuralFailures: structuralFailures,
            signatureStatus: decoded.signatureStatus,
            signatureDetail: decoded.signatureDetail,
            signerKeyID: decoded.signerKeyID,
            signerPublicKeyBase64:
                decoded.signerPublicKeyBase64,
            trustStatus: decoded.trustStatus,
            trustedSignerName: nil,
            verifiedArtifacts: verifiedArtifacts
        )
    }

    private func readExactly(
        _ count: Int,
        from input: FileHandle,
        context: String
    ) throws -> Data {
        guard count >= 0,
              let data = try input.read(upToCount: count),
              data.count == count
        else {
            throw verificationFailure(
                "the \(context) is incomplete"
            )
        }
        return data
    }

    private func validateArchiveName(_ name: String) throws {
        guard paperPathIsSafeArchiveLeafName(name)
        else {
            throw verificationFailure(
                "the archive contains an unsafe file name"
            )
        }
    }

    func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    func verificationFailure(
        _ reason: String
    ) -> PaperPathError {
        .outputVerificationFailed(reason)
    }
}

struct PDFOfficeArtifactFormatVerificationService: Sendable {
    private struct Candidate {
        let entry: PDFOfficeDeliveryEntry
        let url: URL
    }

    private struct CentralEntry {
        let name: String
        let checksum: UInt32
        let byteCount: Int64
        let localHeaderOffset: UInt64
        let flags: UInt16
    }

    private struct OOXMLProfile {
        let mainPart: String
        let mainContentType: String
    }

    private struct UTF8Validator {
        private var remainingContinuationBytes = 0
        private var nextLowerBound: UInt8 = 0x80
        private var nextUpperBound: UInt8 = 0xbf

        mutating func consume(_ data: Data) -> Bool {
            for byte in data {
                if remainingContinuationBytes > 0 {
                    guard byte >= nextLowerBound,
                          byte <= nextUpperBound
                    else { return false }
                    remainingContinuationBytes -= 1
                    nextLowerBound = 0x80
                    nextUpperBound = 0xbf
                    continue
                }
                switch byte {
                case 0x01...0x7f:
                    continue
                case 0xc2...0xdf:
                    remainingContinuationBytes = 1
                case 0xe0:
                    remainingContinuationBytes = 2
                    nextLowerBound = 0xa0
                case 0xe1...0xec, 0xee...0xef:
                    remainingContinuationBytes = 2
                case 0xed:
                    remainingContinuationBytes = 2
                    nextUpperBound = 0x9f
                case 0xf0:
                    remainingContinuationBytes = 3
                    nextLowerBound = 0x90
                case 0xf1...0xf3:
                    remainingContinuationBytes = 3
                case 0xf4:
                    remainingContinuationBytes = 3
                    nextUpperBound = 0x8f
                default:
                    return false
                }
            }
            return true
        }

        var isComplete: Bool {
            remainingContinuationBytes == 0
        }
    }

    private static let maximumOOXMLParts = 4_096
    private static let maximumControlPartBytes =
        1 * 1_024 * 1_024
    private static let maximumControlBytes =
        8 * 1_024 * 1_024
    private static let bufferSize = 256 * 1_024
    private static let reportingStride: Int64 =
        4 * 1_024 * 1_024

    func verify(
        _ entries: [PDFOfficeDeliveryEntry],
        extractedFileURLs: [String: URL],
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> [UUID: PDFOfficeArtifactFormatEvidence] {
        try Task.checkCancellation()
        guard !entries.isEmpty,
              entries.count
                <= PDFOfficeExternalMatchReport.maximumFileCount
        else {
            throw formatFailure(
                "No Office files are available for format verification."
            )
        }
        let artifacts = try entries.map { entry in
            guard let url = extractedFileURLs[entry.archiveName]
            else {
                throw invalidFormat(entry.archiveName)
            }
            return Candidate(entry: entry, url: url)
        }
        guard artifacts.count == extractedFileURLs.count else {
            throw formatFailure(
                "The Office format evidence is incomplete."
            )
        }
        var totalBytes: Int64 = 0
        for artifact in artifacts {
            let (next, overflow) = totalBytes
                .addingReportingOverflow(artifact.entry.byteCount)
            guard !overflow,
                  next <= PDFOfficeExternalMatchReport.maximumBatchBytes
            else {
                throw PaperPathError.fileTooLarge
            }
            totalBytes = next
        }

        var completedBytes: Int64 = 0
        var evidence: [
            UUID: PDFOfficeArtifactFormatEvidence
        ] = [:]
        evidence.reserveCapacity(artifacts.count)
        for (index, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            let name = artifact.entry.archiveName
            progress(
                PDFByteProgressUpdate(
                    stage: .verifying,
                    processedBytes: completedBytes,
                    totalBytes: totalBytes,
                    completedUnitCount: index,
                    totalUnitCount: artifacts.count,
                    currentUnitName: name
                )
            )
            let itemEvidence = try verify(
                artifact,
                progress: { fileBytes in
                    progress(
                        PDFByteProgressUpdate(
                            stage: .verifying,
                            processedBytes:
                                completedBytes + fileBytes,
                            totalBytes: totalBytes,
                            completedUnitCount: index,
                            totalUnitCount: artifacts.count,
                            currentUnitName: name
                        )
                    )
                }
            )
            evidence[artifact.entry.receiptID] = itemEvidence
            completedBytes += artifact.entry.byteCount
            progress(
                PDFByteProgressUpdate(
                    stage: .verifying,
                    processedBytes: completedBytes,
                    totalBytes: totalBytes,
                    completedUnitCount: index + 1,
                    totalUnitCount: artifacts.count,
                    currentUnitName: name
                )
            )
        }
        guard evidence.count == artifacts.count else {
            throw formatFailure(
                "The Office format evidence is incomplete."
            )
        }
        return evidence
    }

    private func verify(
        _ artifact: Candidate,
        progress: (Int64) -> Void
    ) throws -> PDFOfficeArtifactFormatEvidence {
        let url = artifact.url.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
        } catch {
            throw invalidFormat(artifact.entry.archiveName)
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1)
                == artifact.entry.byteCount
        else {
            throw invalidFormat(artifact.entry.archiveName)
        }

        switch artifact.entry.format {
        case .wordDocument:
            return try verifyOOXML(
                at: url,
                fileName: artifact.entry.archiveName,
                profile: OOXMLProfile(
                    mainPart: "word/document.xml",
                    mainContentType:
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
                ),
                progress: progress
            )
        case .excelWorkbook:
            return try verifyOOXML(
                at: url,
                fileName: artifact.entry.archiveName,
                profile: OOXMLProfile(
                    mainPart: "xl/workbook.xml",
                    mainContentType:
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
                ),
                progress: progress
            )
        case .powerPointPresentation:
            return try verifyOOXML(
                at: url,
                fileName: artifact.entry.archiveName,
                profile: OOXMLProfile(
                    mainPart: "ppt/presentation.xml",
                    mainContentType:
                        "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
                ),
                progress: progress
            )
        case .richText:
            try verifyText(
                at: url,
                fileName: artifact.entry.archiveName,
                byteCount: artifact.entry.byteCount,
                requiresRTFEnvelope: true,
                progress: progress
            )
            return .richText
        case .markdown, .plainText:
            try verifyText(
                at: url,
                fileName: artifact.entry.archiveName,
                byteCount: artifact.entry.byteCount,
                requiresRTFEnvelope: false,
                progress: progress
            )
            return .utf8Text
        }
    }

    private func verifyOOXML(
        at url: URL,
        fileName: String,
        profile: OOXMLProfile,
        progress: (Int64) -> Void
    ) throws -> PDFOfficeArtifactFormatEvidence {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: url)
        } catch {
            throw invalidFormat(fileName)
        }
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        guard fileSize >= 22,
              fileSize <= UInt64(
                PDFOfficeExternalMatchReport.maximumFileBytes
              )
        else {
            throw invalidFormat(fileName)
        }
        try input.seek(toOffset: fileSize - 22)
        let end = try readExactly(
            22,
            from: input,
            fileName: fileName
        )
        guard end.uint32(at: 0) == 0x06054b50,
              end.uint16(at: 4) == 0,
              end.uint16(at: 6) == 0,
              end.uint16(at: 8) == end.uint16(at: 10),
              end.uint16(at: 20) == 0
        else {
            throw invalidFormat(fileName)
        }
        let entryCount = Int(end.uint16(at: 10))
        let centralSize = UInt64(end.uint32(at: 12))
        let centralOffset = UInt64(end.uint32(at: 16))
        guard entryCount > 0,
              entryCount <= Self.maximumOOXMLParts,
              centralOffset + centralSize + 22 == fileSize
        else {
            throw invalidFormat(fileName)
        }

        try input.seek(toOffset: centralOffset)
        var entries: [CentralEntry] = []
        entries.reserveCapacity(entryCount)
        var normalizedNames: Set<String> = []
        for _ in 0..<entryCount {
            try Task.checkCancellation()
            let header = try readExactly(
                46,
                from: input,
                fileName: fileName
            )
            let flags = header.uint16(at: 8)
            let method = header.uint16(at: 10)
            let compressedSize = header.uint32(at: 20)
            let uncompressedSize = header.uint32(at: 24)
            let nameLength = Int(header.uint16(at: 28))
            let extraLength = UInt64(header.uint16(at: 30))
            let commentLength = UInt64(header.uint16(at: 32))
            guard header.uint32(at: 0) == 0x02014b50,
                  flags == 0x0800,
                  method == 0,
                  compressedSize == uncompressedSize,
                  header.uint16(at: 34) == 0,
                  nameLength > 0,
                  extraLength == 0,
                  commentLength == 0
            else {
                throw invalidFormat(fileName)
            }
            let nameData = try readExactly(
                nameLength,
                from: input,
                fileName: fileName
            )
            guard let name = String(
                data: nameData,
                encoding: .utf8
            ),
                  paperPathIsSafeOOXMLPath(name),
                  normalizedNames.insert(
                    name.precomposedStringWithCanonicalMapping
                        .lowercased()
                  ).inserted
            else {
                throw invalidFormat(fileName)
            }
            if isForbiddenOOXMLPart(name) {
                throw formatFailure(
                    AppLocalization.format(
                        "The Office file contains unsupported active content: %@",
                        name
                    )
                )
            }
            entries.append(
                CentralEntry(
                    name: name,
                    checksum: header.uint32(at: 16),
                    byteCount: Int64(uncompressedSize),
                    localHeaderOffset:
                        UInt64(header.uint32(at: 42)),
                    flags: flags
                )
            )
        }
        guard try input.offset() == centralOffset + centralSize
        else {
            throw invalidFormat(fileName)
        }

        let names = Set(entries.map(\.name))
        guard names.contains("[Content_Types].xml"),
              names.contains("_rels/.rels"),
              names.contains(profile.mainPart)
        else {
            throw invalidFormat(fileName)
        }
        var controlParts: [String: Data] = [:]
        var controlBytes = 0
        var expectedOffset: UInt64 = 0
        var lastReportedOffset: Int64 = 0
        for entry in entries.sorted(
            by: { $0.localHeaderOffset < $1.localHeaderOffset }
        ) {
            try Task.checkCancellation()
            guard entry.localHeaderOffset == expectedOffset else {
                throw invalidFormat(fileName)
            }
            try input.seek(toOffset: entry.localHeaderOffset)
            let header = try readExactly(
                30,
                from: input,
                fileName: fileName
            )
            let flags = header.uint16(at: 6)
            let method = header.uint16(at: 8)
            let byteCount = Int64(header.uint32(at: 22))
            let nameLength = Int(header.uint16(at: 26))
            let extraLength = UInt64(header.uint16(at: 28))
            guard header.uint32(at: 0) == 0x04034b50,
                  flags == entry.flags,
                  method == 0,
                  header.uint32(at: 18)
                    == header.uint32(at: 22),
                  header.uint32(at: 14) == entry.checksum,
                  byteCount == entry.byteCount,
                  extraLength == 0
            else {
                throw invalidFormat(fileName)
            }
            let localNameData = try readExactly(
                nameLength,
                from: input,
                fileName: fileName
            )
            guard String(data: localNameData, encoding: .utf8)
                    == entry.name
            else {
                throw invalidFormat(fileName)
            }
            let shouldCapture =
                entry.name == "[Content_Types].xml"
                || entry.name.lowercased().hasSuffix(".rels")
            if shouldCapture {
                guard entry.byteCount
                        <= Int64(Self.maximumControlPartBytes),
                      controlBytes
                        <= Self.maximumControlBytes
                            - Int(entry.byteCount)
                else {
                    throw invalidFormat(fileName)
                }
            }
            var captured = Data()
            if shouldCapture {
                captured.reserveCapacity(Int(entry.byteCount))
            }
            var remaining = entry.byteCount
            var checksum = UInt32.max
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(
                    min(Int64(Self.bufferSize), remaining)
                )
                let chunk = try readExactly(
                    count,
                    from: input,
                    fileName: fileName
                )
                updateCRC32(&checksum, with: chunk)
                if shouldCapture {
                    captured.append(chunk)
                }
                remaining -= Int64(chunk.count)
                let processed = Int64(try input.offset())
                if processed - lastReportedOffset
                    >= Self.reportingStride
                    || processed == Int64(centralOffset) {
                    progress(min(Int64(fileSize), processed))
                    lastReportedOffset = processed
                }
            }
            guard checksum ^ UInt32.max == entry.checksum else {
                throw invalidFormat(fileName)
            }
            if shouldCapture {
                controlParts[entry.name] = captured
                controlBytes += captured.count
            }
            expectedOffset = try input.offset()
        }
        guard expectedOffset == centralOffset else {
            throw invalidFormat(fileName)
        }
        let relationshipCount = try validateControlParts(
            controlParts,
            partNames: names,
            profile: profile,
            fileName: fileName
        )
        progress(Int64(fileSize))
        let xmlPartCount = names.lazy.filter {
            let lowered = $0.lowercased()
            return lowered.hasSuffix(".xml")
                || lowered.hasSuffix(".rels")
        }.count
        let mediaPartCount = names.lazy.filter {
            "/\($0.lowercased())".contains("/media/")
        }.count
        return .ooxml(
            partCount: entryCount,
            xmlPartCount: xmlPartCount,
            relationshipCount: relationshipCount,
            mediaPartCount: mediaPartCount
        )
    }

    private func validateControlParts(
        _ parts: [String: Data],
        partNames: Set<String>,
        profile: OOXMLProfile,
        fileName: String
    ) throws -> Int {
        for data in parts.values {
            guard let source = String(data: data, encoding: .utf8)
            else {
                throw invalidFormat(fileName)
            }
            let lowered = source.lowercased()
            guard !lowered.contains("<!doctype"),
                  !lowered.contains("<!entity")
            else {
                throw formatFailure(
                    AppLocalization.format(
                        "The Office file contains unsupported XML declarations: %@",
                        fileName
                    )
                )
            }
        }
        guard let contentTypesData =
                parts["[Content_Types].xml"],
              let rootRelationshipsData = parts["_rels/.rels"]
        else {
            throw invalidFormat(fileName)
        }
        let contentTypes = OOXMLContentTypesCollector()
        let contentParser = XMLParser(data: contentTypesData)
        contentParser.shouldResolveExternalEntities = false
        contentParser.delegate = contentTypes
        guard contentParser.parse(),
              contentTypes.hasTypesRoot,
              !contentTypes.hasMalformedDeclaration,
              contentTypes.overrides[profile.mainPart]
                == profile.mainContentType
        else {
            throw invalidFormat(fileName)
        }

        for path in partNames
            where path != "[Content_Types].xml" {
            let fileExtension = path.hasSuffix(".rels")
                ? "rels"
                : (path as NSString)
                    .pathExtension
                    .lowercased()
            guard contentTypes.overrides[path] != nil
                    || contentTypes.defaults[fileExtension] != nil
            else {
                throw formatFailure(
                    AppLocalization.format(
                        "The Office file has no content type for %@.",
                        path
                    )
                )
            }
        }
        for path in contentTypes.overrides.keys
            where path == "[Content_Types].xml"
                || !partNames.contains(path) {
            throw formatFailure(
                AppLocalization.format(
                    "The Office file declares a missing content part: %@.",
                    path
                )
            )
        }

        let officeDocumentRelationshipType =
            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        var rootOfficeDocumentTargets: [String] = []
        var relationshipCount = 0
        for (path, data) in parts
            .filter({ $0.key.lowercased().hasSuffix(".rels") })
            .sorted(by: { $0.key < $1.key }) {
            let relationships = OOXMLRelationshipCollector()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = relationships
            guard parser.parse(),
                  relationships.hasRelationshipsRoot,
                  !relationships.hasMalformedRelationship,
                  !relationships.relationships.contains(
                    where: \.isExternal
                  )
            else {
                throw formatFailure(
                    AppLocalization.format(
                        "The Office file contains invalid or external relationships: %@",
                        fileName
                    )
                )
            }
            let context = try relationshipContext(for: path)
            if let owner = context.owner,
               !partNames.contains(owner) {
                throw formatFailure(
                    AppLocalization.format(
                        "The Office relationship owner is missing: %@.",
                        owner
                    )
                )
            }
            guard relationshipCount
                    <= 16_384 - relationships.relationships.count
            else {
                throw invalidFormat(fileName)
            }
            for relationship in relationships.relationships {
                let target = try normalizedRelationshipTarget(
                    ownerDirectory: context.directory,
                    target: relationship.target
                )
                guard partNames.contains(target) else {
                    throw formatFailure(
                        AppLocalization.format(
                            "The Office relationship target is missing: %@.",
                            target
                        )
                    )
                }
                if path == "_rels/.rels",
                   relationship.type
                    == officeDocumentRelationshipType {
                    rootOfficeDocumentTargets.append(target)
                }
            }
            relationshipCount += relationships.relationships.count
        }
        guard rootOfficeDocumentTargets.count == 1,
              rootOfficeDocumentTargets.first == profile.mainPart,
              rootRelationshipsData.count > 0
        else {
            throw invalidFormat(fileName)
        }
        return relationshipCount
    }

    private func relationshipContext(
        for path: String
    ) throws -> (owner: String?, directory: String) {
        if path == "_rels/.rels" {
            return (nil, "")
        }
        let marker = "/_rels/"
        let directory: String
        let relationshipName: String
        if path.hasPrefix("_rels/") {
            directory = ""
            relationshipName = String(path.dropFirst("_rels/".count))
        } else if let range = path.range(
            of: marker,
            options: .backwards
        ) {
            directory = String(path[..<range.lowerBound])
            relationshipName = String(path[range.upperBound...])
        } else {
            throw formatFailure(
                AppLocalization.format(
                    "The Office file contains a misplaced relationship part: %@.",
                    path
                )
            )
        }
        guard relationshipName.hasSuffix(".rels") else {
            throw invalidFormat(path)
        }
        let ownerName = String(relationshipName.dropLast(5))
        let owner = [directory, ownerName]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        guard paperPathIsSafeOOXMLPath(owner) else {
            throw invalidFormat(path)
        }
        return (owner, directory)
    }

    private func normalizedRelationshipTarget(
        ownerDirectory: String,
        target: String
    ) throws -> String {
        guard !target.isEmpty,
              !target.contains("\\"),
              !target.contains("#"),
              !target.contains("?")
        else {
            throw invalidFormat(target)
        }
        guard let decoded = target.removingPercentEncoding,
              decoded == decoded.precomposedStringWithCanonicalMapping
        else {
            throw invalidFormat(target)
        }
        let relativeTarget = decoded.hasPrefix("/")
            ? String(decoded.dropFirst())
            : decoded
        let rawPath = decoded.hasPrefix("/")
            ? relativeTarget
            : [ownerDirectory, relativeTarget]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        var components: [Substring] = []
        for component in rawPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw invalidFormat(target)
                }
                components.removeLast()
            case "":
                throw invalidFormat(target)
            default:
                components.append(component)
            }
        }
        let normalized = components.joined(separator: "/")
        guard paperPathIsSafeOOXMLPath(normalized) else {
            throw invalidFormat(target)
        }
        return normalized
    }

    private func verifyText(
        at url: URL,
        fileName: String,
        byteCount: Int64,
        requiresRTFEnvelope: Bool,
        progress: (Int64) -> Void
    ) throws {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: url)
        } catch {
            throw invalidFormat(fileName)
        }
        defer { try? input.close() }
        var validator = UTF8Validator()
        var prefix = Data()
        var lastNonWhitespaceByte: UInt8?
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try input.read(
                    upToCount: Self.bufferSize
                ) ?? Data()
            } catch {
                throw invalidFormat(fileName)
            }
            if chunk.isEmpty { break }
            guard validator.consume(chunk) else {
                throw invalidFormat(fileName)
            }
            if prefix.count < 16 {
                prefix.append(
                    chunk.prefix(16 - prefix.count)
                )
            }
            for byte in chunk.reversed()
                where ![0x09, 0x0a, 0x0d, 0x20]
                    .contains(byte) {
                lastNonWhitespaceByte = byte
                break
            }
            processedBytes += Int64(chunk.count)
            if processedBytes - lastReportedBytes
                >= Self.reportingStride
                || processedBytes == byteCount {
                progress(processedBytes)
                lastReportedBytes = processedBytes
            }
        }
        guard processedBytes == byteCount,
              validator.isComplete,
              !prefix.contains(0)
        else {
            throw invalidFormat(fileName)
        }
        if requiresRTFEnvelope {
            guard prefix.starts(
                with: Data([0x7b, 0x5c, 0x72, 0x74, 0x66])
            ),
                  lastNonWhitespaceByte == 0x7d
            else {
                throw invalidFormat(fileName)
            }
        }
        if processedBytes != lastReportedBytes {
            progress(processedBytes)
        }
    }

    private func isForbiddenOOXMLPart(_ path: String) -> Bool {
        let lowered = "/\(path.lowercased())"
        return lowered.hasSuffix("/vbaproject.bin")
            || lowered.contains("/activex/")
            || lowered.contains("/embeddings/")
            || lowered.contains("/externallinks/")
            || lowered.hasSuffix("/connections.xml")
            || lowered.contains("/querytables/")
            || lowered.contains("/webextensions/")
            || lowered.contains("/customui/")
            || lowered.contains("/ctrlprops/")
            || lowered.hasSuffix(".bin")
    }

    private func updateCRC32(
        _ checksum: inout UInt32,
        with data: Data
    ) {
        paperPathUpdateCRC32(&checksum, with: data)
    }

    private func readExactly(
        _ count: Int,
        from input: FileHandle,
        fileName: String
    ) throws -> Data {
        guard count >= 0 else {
            throw invalidFormat(fileName)
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try input.read(
                    upToCount: count - result.count
                ) ?? Data()
            } catch {
                throw invalidFormat(fileName)
            }
            guard !chunk.isEmpty else {
                throw invalidFormat(fileName)
            }
            result.append(chunk)
        }
        return result
    }

    private func invalidFormat(_ name: String) -> PaperPathError {
        formatFailure(
            AppLocalization.format(
                "The signed file is not a valid %@ artifact.",
                (name as NSString).pathExtension.uppercased()
            )
        )
    }

    private func formatFailure(
        _ reason: String
    ) -> PaperPathError {
        .outputVerificationFailed(reason)
    }
}

struct PDFOfficeArtifactShareVerificationService: Sendable {
    private static let reportingStride: Int64 =
        4 * 1_024 * 1_024
    private static let bufferSize = 1 * 1_024 * 1_024

    func verify(
        _ artifacts: [PDFOfficeVerifiedArtifact],
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> [URL] {
        try Task.checkCancellation()
        guard !artifacts.isEmpty,
              artifacts.count
                <= PDFOfficeExternalMatchReport.maximumFileCount
        else {
            throw verificationFailure(
                "Choose at least one verified Office file."
            )
        }

        var receiptIDs: Set<UUID> = []
        var paths: Set<String> = []
        var expectedTotalBytes: Int64 = 0
        var managedDirectory: URL?
        for artifact in artifacts {
            let entry = artifact.entry
            let url = artifact.url.standardizedFileURL
            guard receiptIDs.insert(entry.receiptID).inserted,
                  paths.insert(url.path).inserted,
                  entry.archiveName == url.lastPathComponent,
                  paperPathIsSafeArchiveLeafName(entry.archiveName),
                  entry.archiveName.utf8.count <= 240,
                  url.pathExtension.lowercased()
                    == entry.format.fileExtension.lowercased(),
                  entry.byteCount > 0,
                  entry.byteCount
                    <= PDFOfficeExternalMatchReport.maximumFileBytes,
                  isSHA256(entry.sha256),
                  let topLevel =
                    PaperPathTemporaryArtifact.managedTopLevelItem(
                        containing: url,
                        allowedPrefixes: [
                            PaperPathTemporaryArtifact
                                .verifiedOfficeDeliveryPrefix
                        ]
                    ),
                  url.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .standardizedFileURL == topLevel
            else {
                throw verificationFailure(
                    "The verified Office selection is invalid."
                )
            }
            if let managedDirectory {
                guard managedDirectory == topLevel else {
                    throw verificationFailure(
                        "The verified Office selection is invalid."
                    )
                }
            } else {
                managedDirectory = topLevel
            }
            let (nextTotal, overflow) = expectedTotalBytes
                .addingReportingOverflow(entry.byteCount)
            guard !overflow,
                  nextTotal
                    <= PDFOfficeExternalMatchReport.maximumBatchBytes
            else {
                throw PaperPathError.fileTooLarge
            }
            expectedTotalBytes = nextTotal
        }

        if let managedDirectory {
            let directoryValues: URLResourceValues
            do {
                directoryValues = try managedDirectory.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey
                    ]
                )
            } catch {
                throw verificationFailure(
                    "The verified Office directory is unavailable."
                )
            }
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true
            else {
                throw verificationFailure(
                    "The verified Office directory is unavailable."
                )
            }
            do {
                try LocalFileSecurity.requireCompleteProtection(
                    to: managedDirectory
                )
                LocalFileSecurity.excludeFromBackup(managedDirectory)
            } catch {
                throw verificationFailure(
                    "The verified Office directory is unavailable."
                )
            }
        }
        progress(
            PDFByteProgressUpdate(
                stage: .checksumming,
                processedBytes: 0,
                totalBytes: expectedTotalBytes,
                completedUnitCount: 0,
                totalUnitCount: artifacts.count,
                currentUnitName:
                    artifacts.first?.entry.archiveName ?? ""
            )
        )

        var completedBytes: Int64 = 0
        var verifiedURLs: [URL] = []
        verifiedURLs.reserveCapacity(artifacts.count)
        for (index, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            let url = artifact.url.standardizedFileURL
            let before: URLResourceValues
            do {
                before = try url.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .fileResourceIdentifierKey
                    ]
                )
            } catch {
                throw unavailableFile(artifact.entry.archiveName)
            }
            guard before.isRegularFile == true,
                  before.isSymbolicLink != true,
                  Int64(before.fileSize ?? -1)
                    == artifact.entry.byteCount
            else {
                throw unavailableFile(artifact.entry.archiveName)
            }
            do {
                try LocalFileSecurity.requireCompleteProtection(to: url)
                LocalFileSecurity.excludeFromBackup(url)
            } catch {
                throw unavailableFile(artifact.entry.archiveName)
            }

            let fingerprint = try fingerprint(
                at: url,
                expectedByteCount: artifact.entry.byteCount
            ) { fileBytes in
                progress(
                    PDFByteProgressUpdate(
                        stage: .checksumming,
                        processedBytes: completedBytes + fileBytes,
                        totalBytes: expectedTotalBytes,
                        completedUnitCount: index,
                        totalUnitCount: artifacts.count,
                        currentUnitName: artifact.entry.archiveName
                    )
                )
            }
            let after: URLResourceValues
            do {
                after = try url.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .fileResourceIdentifierKey
                    ]
                )
            } catch {
                throw unavailableFile(artifact.entry.archiveName)
            }
            guard after.isRegularFile == true,
                  after.isSymbolicLink != true,
                  Int64(after.fileSize ?? -1)
                    == artifact.entry.byteCount,
                  before.contentModificationDate
                    == after.contentModificationDate,
                  fileResourceIdentifiersMatch(
                    before.fileResourceIdentifier,
                    after.fileResourceIdentifier
                  ),
                  fingerprint.caseInsensitiveCompare(
                    artifact.entry.sha256
                  ) == .orderedSame
            else {
                throw changedFile(artifact.entry.archiveName)
            }
            do {
                try LocalFileSecurity.requireCompleteProtection(to: url)
            } catch {
                throw unavailableFile(artifact.entry.archiveName)
            }
            completedBytes += artifact.entry.byteCount
            verifiedURLs.append(url)
            progress(
                PDFByteProgressUpdate(
                    stage: .checksumming,
                    processedBytes: completedBytes,
                    totalBytes: expectedTotalBytes,
                    completedUnitCount: index + 1,
                    totalUnitCount: artifacts.count,
                    currentUnitName: artifact.entry.archiveName
                )
            )
        }
        return verifiedURLs
    }

    private func fileResourceIdentifiersMatch(
        _ first: Any?,
        _ second: Any?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case let (first as NSObject, second):
            return first.isEqual(second)
        default:
            return false
        }
    }

    private func fingerprint(
        at url: URL,
        expectedByteCount: Int64,
        progress: (Int64) -> Void
    ) throws -> String {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: url)
        } catch {
            throw unavailableFile(url.lastPathComponent)
        }
        defer { try? input.close() }

        var hasher = SHA256()
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try input.read(
                    upToCount: Self.bufferSize
                ) ?? Data()
            } catch {
                throw unavailableFile(url.lastPathComponent)
            }
            if chunk.isEmpty { break }
            let (nextBytes, overflow) = processedBytes
                .addingReportingOverflow(Int64(chunk.count))
            guard !overflow,
                  nextBytes <= expectedByteCount
            else {
                throw changedFile(url.lastPathComponent)
            }
            hasher.update(data: chunk)
            processedBytes = nextBytes
            if processedBytes - lastReportedBytes
                >= Self.reportingStride
                || processedBytes == expectedByteCount {
                progress(processedBytes)
                lastReportedBytes = processedBytes
            }
        }
        guard processedBytes == expectedByteCount else {
            throw changedFile(url.lastPathComponent)
        }
        if processedBytes != lastReportedBytes {
            progress(processedBytes)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    func unavailableFile(_ name: String) -> PaperPathError {
        verificationFailure(
            AppLocalization.format(
                "The verified Office file is no longer available: %@",
                name
            )
        )
    }

    func changedFile(_ name: String) -> PaperPathError {
        verificationFailure(
            AppLocalization.format(
                "The verified Office file changed before sharing: %@",
                name
            )
        )
    }

    func verificationFailure(
        _ reason: String
    ) -> PaperPathError {
        .outputVerificationFailed(reason)
    }
}

private func paperPathSafeExternalFileName(
    _ name: String
) -> String {
    let sanitized = name.unicodeScalars.map { scalar in
        let codePoint = scalar.value
        let isBidirectionalControl =
            codePoint == 0x061C
            || codePoint == 0x200E
            || codePoint == 0x200F
            || (0x202A...0x202E).contains(codePoint)
            || (0x2066...0x2069).contains(codePoint)
        if CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.illegalCharacters.contains(scalar)
            || isBidirectionalControl {
            return " "
        }
        return String(scalar)
    }
    .joined()
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    let bounded = String(sanitized.prefix(180))
    return bounded.isEmpty ? "PaperPath Archive.zip" : bounded
}

private let paperPathCRC32Table: [UInt32] = (0..<256).map {
    value in
    var checksum = UInt32(value)
    for _ in 0..<8 {
        checksum = checksum & 1 == 1
            ? (checksum >> 1) ^ 0xedb88320
            : checksum >> 1
    }
    return checksum
}

private func paperPathUpdateCRC32(
    _ checksum: inout UInt32,
    with data: Data
) {
    for byte in data {
        let index = Int((checksum ^ UInt32(byte)) & 0xff)
        checksum =
            (checksum >> 8) ^ paperPathCRC32Table[index]
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            append(contentsOf: $0)
        }
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset])
            | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
