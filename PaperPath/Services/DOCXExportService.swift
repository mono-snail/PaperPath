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

private struct PDFOfficePageGeometry: Sendable {
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
        )
    ].joined()

    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">\(properties)</Properties>
    """
}

private struct DOCXVisualReferenceBudget {
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

private struct DOCXBlockStats: Sendable {
    let paragraphCount: Int
    let tableCount: Int
    let characterCount: Int
    let hasTable: Bool

    init(blocks: [DOCXBlock]) {
        var paragraphs = 0
        var tables = 0
        var characters = 0
        for block in blocks {
            switch block {
            case .paragraph(let paragraph):
                paragraphs += 1
                characters += paragraph.text.count
            case .table(let table):
                tables += 1
                characters += table.rows.reduce(0) { result, row in
                    result + row.cells.reduce(0) {
                        $0 + $1.text.count
                    }
                }
            }
        }
        paragraphCount = paragraphs
        tableCount = tables
        characterCount = characters
        hasTable = tables > 0
    }
}

private enum DOCXVisualReferenceSkipReason: String {
    case totalBudgetExhausted = "total-budget-exhausted"
    case pageBudgetExceeded = "page-budget-exceeded"
    case renderFailed = "render-failed"
}

private enum DOCXVisualReferencePriority: String {
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

private struct DOCXVisualReferenceResult {
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

private enum DOCXVisualReferenceOutcome {
    case accepted(DOCXVisualReferenceResult)
    case skipped(DOCXVisualReferenceSkipReason)
}

private struct DOCXReconstructionMetrics: Sendable {
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
                    : visualAcceptedMinimumQualityPercent
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
            guard let page = document.page(at: pageIndex) else { continue }
            guard let geometry = PDFOfficePageGeometry(page: page) else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) has invalid dimensions"
                )
            }
            var blocks = structuredBlocks(from: page)
            var usedFallbackText = false
            if blocks.isEmpty,
               let indexedText = indexedPages[pageIndex] {
                blocks = fallbackParagraphs(from: indexedText)
                    .map(DOCXBlock.paragraph)
                usedFallbackText = !blocks.isEmpty
            }
            let blockStats = DOCXBlockStats(blocks: blocks)
            let embeddedImagePage = cgDocument
                .flatMap { $0.page(at: pageIndex + 1) }
                .map(pageContainsEmbeddedImage) ?? false
            let needsVisualReference = embeddedImagePage
                || blockStats.hasTable
                || blocks.isEmpty
            var visualReferenceResult: DOCXVisualReferenceResult?
            if needsVisualReference {
                let visualPriority = DOCXVisualReferencePriority.classify(
                    hasStructuredText: !blocks.isEmpty,
                    hasTable: blockStats.hasTable,
                    hasEmbeddedImage: embeddedImagePage
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
                    switch pageVisualReference(
                        page: page,
                        geometry: geometry,
                        pageIndex: pageIndex,
                        relationshipIndex: imageOrdinal + 3,
                        longestEdge: visualBudget.longestEdge,
                        compressionQuality:
                            visualBudget.compressionQuality,
                        maximumByteCount: pageBudget,
                        priority: visualPriority
                    ) {
                    case .accepted(let result):
                        visualReferenceResult = result
                        visualReferenceByteCount += result.byteCount
                        imageOrdinal += 1
                    case .skipped(let reason):
                        metrics.recordSkippedVisualReference(reason)
                    }
                }
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

    private func structuredBlocks(
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

        let lines = selection.selectionsByLine().compactMap {
            line(from: $0, on: page)
        }
        guard !lines.isEmpty else { return [] }
        let bodySize = median(lines.map(\.fontSize))
        let pageBounds = page.bounds(for: .cropBox)
        var blocks: [DOCXBlock] = []
        var paragraphLines: [DOCXLine] = []

        func flushParagraphs() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(
                contentsOf: paragraphBlocks(
                    from: paragraphLines,
                    bodySize: bodySize,
                    pageBounds: pageBounds
                )
            )
            paragraphLines = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.cells.count >= 2 else {
                paragraphLines.append(line)
                index += 1
                continue
            }
            var tableLines = [line]
            var nextIndex = index + 1
            while nextIndex < lines.count,
                  lines[nextIndex].cells.count >= 2,
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

    private func paragraphBlocks(
        from lines: [DOCXLine],
        bodySize: CGFloat,
        pageBounds: CGRect
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
                pageBounds: pageBounds
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

    private func tableRowsAlign(
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

    private func table(
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

    private func startsNewParagraph(
        _ line: DOCXLine,
        after previous: DOCXLine,
        paragraphStart: DOCXLine,
        bodySize: CGFloat
    ) -> Bool {
        if looksLikeListItem(line.text) {
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

    private func paragraph(
        from lines: [DOCXLine],
        bodySize: CGFloat,
        pageBounds: CGRect
    ) -> DOCXParagraph? {
        guard let first = lines.first else { return nil }
        var text = first.text
        for line in lines.dropFirst() {
            if text.hasSuffix("-"),
               line.text.first?.isLowercase == true {
                text.removeLast()
                text += line.text
            } else {
                text += " " + line.text
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let size = median(lines.map(\.fontSize))
        let boldCount = lines.filter(\.isBold).count
        let italicCount = lines.filter(\.isItalic).count
        let bounds = lines.dropFirst().reduce(first.bounds) {
            $0.union($1.bounds)
        }
        let style: DOCXParagraphStyle
        if size >= bodySize * 1.52 {
            style = .heading1
        } else if size >= bodySize * 1.22
                    || (
                        boldCount * 2 >= lines.count
                            && text.count <= 140
                    ) {
            style = .heading2
        } else if looksLikeListItem(text) {
            style = .list
        } else {
            style = .body
        }
        return DOCXParagraph(
            text: text,
            style: style,
            isBold: boldCount * 2 >= lines.count,
            isItalic: italicCount * 2 >= lines.count,
            fontSize: min(max(size, 8), 36),
            alignment: inferredAlignment(
                bounds: bounds,
                pageBounds: pageBounds
            )
        )
    }

    private func fallbackParagraphs(
        from text: String
    ) -> [DOCXParagraph] {
        let normalized = text.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        return normalized
            .components(separatedBy: "\n\n")
            .flatMap { block -> [String] in
                let trimmed = block.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if trimmed.isEmpty { return [] }
                return [trimmed]
            }
            .map {
                DOCXParagraph(
                    text: $0
                        .components(separatedBy: .newlines)
                        .map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }
                        .filter { !$0.isEmpty }
                        .joined(separator: " "),
                    style: looksLikeListItem($0) ? .list : .body,
                    isBold: false,
                    isItalic: false,
                    fontSize: 11,
                    alignment: .left
                )
            }
            .filter { !$0.text.isEmpty }
    }

    private func inferredAlignment(
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

    private func isHeading(
        _ line: DOCXLine,
        bodySize: CGFloat
    ) -> Bool {
        line.fontSize >= bodySize * 1.22
            || (line.isBold && line.text.count <= 140)
    }

    private func looksLikeListItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if ["• ", "◦ ", "▪ ", "- ", "* "].contains(
            where: { trimmed.hasPrefix($0) }
        ) {
            return true
        }
        guard let firstSpace = trimmed.firstIndex(of: " ") else {
            return false
        }
        let marker = trimmed[..<firstSpace]
        return marker.hasSuffix(".")
            && marker.dropLast().allSatisfy(\.isNumber)
    }

    private func endsParagraph(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?;:。！？；：".contains(last)
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
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

    private func wordPageLayout(
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
        let documentXML = wordDocumentXML(pages: pages)
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
        try archive.add(
            path: "word/document.xml",
            string: documentXML
        )
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
        guard writtenBytes > 4,
              documentXML.contains("<w:document"),
              documentXML.contains("<w:body>")
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Word package structure is incomplete"
            )
        }
        return writtenBytes
    }

    private func wordDocumentXML(pages: [DOCXPage]) -> String {
        var body = ""
        for (pagePosition, page) in pages.enumerated() {
            for block in page.blocks {
                body += blockXML(
                    block,
                    pageBreakBefore: false
                )
            }
            if let image = page.visualReference {
                body += imageXML(
                    image,
                    documentID: page.pageIndex + 1,
                    pageBreakBefore: false
                )
            }
            if pagePosition + 1 < pages.count {
                body += """
                <w:p><w:pPr>\(sectionPropertiesXML(page.layout, startsNextPage: true))</w:pPr></w:p>
                """
            }
        }
        let finalSection = sectionPropertiesXML(
            pages.last?.layout ?? DOCXPageLayout.letterPortrait,
            startsNextPage: false
        )
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\(finalSection)</w:body></w:document>
        """
    }

    private func sectionPropertiesXML(
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

    private func blockXML(
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

    private func paragraphXML(
        _ paragraph: DOCXParagraph,
        pageBreakBefore: Bool
    ) -> String {
        let style = paragraph.style.wordStyle
        let alignment = paragraph.alignment.rawValue
        let pageBreak = pageBreakBefore ? "<w:pageBreakBefore/>" : ""
        let fontSize = Int((paragraph.fontSize * 2).rounded())
        let bold = paragraph.isBold ? "<w:b/>" : ""
        let italic = paragraph.isItalic ? "<w:i/>" : ""
        return """
        <w:p><w:pPr><w:pStyle w:val="\(style)"/><w:jc w:val="\(alignment)"/><w:spacing w:after="120" w:line="276" w:lineRule="auto"/>\(pageBreak)</w:pPr><w:r><w:rPr>\(bold)\(italic)<w:sz w:val="\(fontSize)"/><w:szCs w:val="\(fontSize)"/></w:rPr><w:t xml:space="preserve">\(xmlEscaped(paragraph.text))</w:t></w:r></w:p>
        """
    }

    private func tableXML(_ table: DOCXTable) -> String {
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

    private func imageXML(
        _ image: DOCXImage,
        documentID: Int,
        pageBreakBefore: Bool
    ) -> String {
        let pageBreak = pageBreakBefore ? "<w:pageBreakBefore/>" : ""
        return """
        <w:p><w:pPr><w:spacing w:before="180" w:after="120"/><w:jc w:val="center"/>\(pageBreak)</w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(documentID)" name="Page \(documentID)" descr="\(xmlEscaped(image.description))"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(documentID)" name="\(xmlEscaped(image.fileName))"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(image.relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    private func corePropertiesXML(title: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscaped(title))</dc:title><dc:creator>PaperPath</dc:creator><cp:lastModifiedBy>PaperPath</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified></cp:coreProperties>
        """
    }

    private func xmlEscaped(_ value: String) -> String {
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

    private func documentRelationshipsXML(
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

    private func customPropertiesXML(
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

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { continue }
            guard let geometry = PDFOfficePageGeometry(page: page) else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) has invalid dimensions"
                )
            }
            var rows = rows(from: page)
            if rows.isEmpty,
               let indexedText = indexedPages[pageIndex] {
                rows = fallbackRows(from: indexedText)
            }
            if !rows.isEmpty {
                totalCellCount += rows.reduce(0) {
                    $0 + $1.cells.count
                }
                totalCharacterCount += rows.reduce(0) { result, row in
                    result + row.cells.reduce(0) {
                        $0 + $1.text.count
                    }
                }
                guard totalCellCount <= 500_000,
                      totalCharacterCount <= 12_000_000
                else {
                    throw PaperPathError.insufficientSelection(
                        "The detected workbook exceeds the on-device export budget."
                    )
                }
                sheets.append(
                    Sheet(
                        name: "Page \(pageIndex + 1)",
                        rows: rows,
                        isLandscape: geometry.isLandscape
                    )
                )
            }
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
            searchablePageCount: sheets.count,
            assetCount: 0,
            assetByteCount: 0,
            assetBudgetByteCount: 0,
            assetCompressionFallbackCount: 0,
            assetMinimumQualityPercent: 0
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

    private func rows(from page: PDFPage) -> [Row] {
        guard let pageText = page.string,
              !pageText.isEmpty,
              let selection = page.selection(
                  for: NSRange(
                      location: 0,
                      length: (pageText as NSString).length
                  )
              )
        else { return [] }
        return selection.selectionsByLine().compactMap {
            row(from: $0, on: page)
        }
    }

    private func row(
        from selection: PDFSelection,
        on page: PDFPage
    ) -> Row? {
        guard let rawText = selection.string else { return nil }
        let text = rawText
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lineBounds = selection.bounds(for: page)
        let isBold = selectionIsBold(selection)
        let detected = detectedCells(
            from: selection,
            on: page,
            lineHeight: lineBounds.height
        )
        let values = detected.isEmpty ? [text] : detected
        return Row(
            cells: values.prefix(64).map {
                Cell(
                    text: $0,
                    numericValue: numericValue(for: $0),
                    isBold: isBold
                )
            }
        )
    }

    private func detectedCells(
        from selection: PDFSelection,
        on page: PDFPage,
        lineHeight: CGFloat
    ) -> [String] {
        guard let pageText = page.string else { return [] }
        let source = pageText as NSString
        let expression = try? NSRegularExpression(pattern: "\\S+")
        var words: [(text: String, bounds: CGRect)] = []
        for rangeIndex in 0..<selection.numberOfTextRanges(on: page) {
            let lineRange = selection.range(
                at: rangeIndex,
                on: page
            )
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
                    location: lineRange.location
                        + match.range.location,
                    length: match.range.length
                )
                guard let wordSelection = page.selection(
                    for: absoluteRange
                ) else { continue }
                let bounds = wordSelection.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else {
                    continue
                }
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
        var cells: [String] = []
        var text = words[0].text
        var bounds = words[0].bounds
        for word in words.dropFirst() {
            let gap = word.bounds.minX - bounds.maxX
            if gap >= largeGap {
                cells.append(text)
                text = word.text
                bounds = word.bounds
            } else {
                text += " " + word.text
                bounds = bounds.union(word.bounds)
            }
        }
        cells.append(text)
        return cells.count >= 2 ? cells : []
    }

    private func fallbackRows(from text: String) -> [Row] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .compactMap { line -> Row? in
                let values = fallbackCells(from: line)
                guard !values.isEmpty else { return nil }
                return Row(
                    cells: values.prefix(64).map {
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
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        let expression = try? NSRegularExpression(
            pattern: "\\t+| {2,}"
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
            if !value.isEmpty {
                values.append(value)
            }
            location = NSMaxRange(match.range)
        }
        if location < source.length {
            let value = source.substring(
                from: location
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values.append(value)
            }
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
                  of: #"^[+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count <= 15 else { return nil }
        let normalized = trimmed.replacingOccurrences(
            of: ",",
            with: ""
        )
        return normalized.hasPrefix("+")
            ? String(normalized.dropFirst())
            : normalized
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
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
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
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Arial"/><family val="2"/></font><font><b/><sz val="11"/><name val="Arial"/><family val="2"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
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
                minimumAcceptedQualityPercent
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

private struct DOCXPage {
    let pageIndex: Int
    let blocks: [DOCXBlock]
    let visualReference: DOCXImage?
    let layout: DOCXPageLayout
}

private struct DOCXPageLayout {
    let widthTwips: Int
    let heightTwips: Int
    let isLandscape: Bool

    static let letterPortrait = DOCXPageLayout(
        widthTwips: 12_240,
        heightTwips: 15_840,
        isLandscape: false
    )
}

private enum DOCXBlock {
    case paragraph(DOCXParagraph)
    case table(DOCXTable)
}

private struct DOCXLine {
    let text: String
    let bounds: CGRect
    let fontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let cells: [DOCXCellCandidate]
}

private struct DOCXCellCandidate {
    let text: String
    let bounds: CGRect
}

private struct DOCXTable {
    let rows: [DOCXTableRow]
    let columnWidths: [Int]
}

private struct DOCXTableRow {
    let cells: [DOCXTableCell]
    let repeatsAsHeader: Bool
}

private struct DOCXTableCell {
    let text: String
    let isBold: Bool
}

private struct DOCXImage {
    let relationshipID: String
    let fileName: String
    let data: Data
    let widthEMU: Int
    let heightEMU: Int
    let description: String
}

private struct DOCXParagraph {
    let text: String
    let style: DOCXParagraphStyle
    let isBold: Bool
    let isItalic: Bool
    let fontSize: CGFloat
    let alignment: DOCXAlignment
}

private enum DOCXParagraphStyle {
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

private enum DOCXAlignment: String {
    case left
    case center
    case right
}

private func ooxmlEscaped(_ value: String) -> String {
    let sanitized = value.unicodeScalars.reduce(
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
    return sanitized
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
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

private struct OOXMLArchive {
    private struct Entry {
        let path: String
        let name: Data
        let payload: Data
        let checksum: UInt32
    }

    private var entries: [Entry] = []
    private var paths: Set<String> = []

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
        guard paths.insert(path).inserted else {
            throw PaperPathError.outputVerificationFailed(
                "the Office package contains a duplicate part: \(path)"
            )
        }
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
        let totalBytes = entries.reduce(Int64(22)) {
            partial, entry in
            partial
                + Int64(30 + entry.name.count + entry.payload.count)
                + Int64(46 + entry.name.count)
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
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ],
            options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        for candidate in candidates
            where candidate.lastPathComponent
                .hasPrefix(".PaperPath-OOXML-")
                && candidate.pathExtension == "tmp" {
            let values = try? candidate.resourceValues(
                forKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey
                ]
            )
            guard values?.isRegularFile == true,
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
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(result & 1))
                result = (result >> 1) ^ (0xedb88320 & mask)
            }
        }
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

private final class OOXMLRelationshipCollector:
    NSObject,
    XMLParserDelegate {
    struct Relationship {
        let target: String
        let isExternal: Bool
    }

    private(set) var relationships: [Relationship] = []
    private(set) var hasRelationshipsRoot = false
    private(set) var hasMalformedRelationship = false
    private var identifiers: Set<String> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Relationships" {
            hasRelationshipsRoot = true
            return
        }
        guard elementName == "Relationship" else { return }
        guard let identifier = attributeDict["Id"],
              !identifier.isEmpty,
              let type = attributeDict["Type"],
              !type.isEmpty,
              let target = attributeDict["Target"],
              !target.isEmpty,
              identifiers.insert(identifier).inserted
        else {
            hasMalformedRelationship = true
            return
        }
        relationships.append(
            Relationship(
                target: target,
                isExternal: attributeDict["TargetMode"]?
                    .caseInsensitiveCompare("External") == .orderedSame
            )
        )
    }
}

private final class OOXMLContentTypesCollector:
    NSObject,
    XMLParserDelegate {
    private(set) var defaults: [String: String] = [:]
    private(set) var overrides: [String: String] = [:]
    private(set) var hasTypesRoot = false
    private(set) var hasMalformedDeclaration = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Types":
            hasTypesRoot = true
        case "Default":
            guard let fileExtension = attributeDict["Extension"]?
                .lowercased(),
                  !fileExtension.isEmpty,
                  let contentType = attributeDict["ContentType"],
                  !contentType.isEmpty,
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
                  !contentType.isEmpty
            else {
                hasMalformedDeclaration = true
                return
            }
            let path = String(partName.dropFirst())
            guard !path.isEmpty,
                  !path.contains("\\"),
                  !path.split(separator: "/").contains(where: {
                      $0 == "." || $0 == ".."
                  }),
                  overrides[path] == nil
            else {
                hasMalformedDeclaration = true
                return
            }
            overrides[path] = contentType
        default:
            return
        }
    }
}

struct OfficeBatchArchiveSource: Sendable {
    let sourceURL: URL
    let archiveName: String
}

struct OfficeBatchArchiveService: Sendable {
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
            guard seenNames.insert(source.archiveName).inserted else {
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
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
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

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
                    let copiedBytes = try copyFile(
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
                    guard copiedBytes == fileSize else {
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
            progress(
                PDFByteProgressUpdate(
                    stage: .archiving,
                    processedBytes: totalArchiveBytes,
                    totalBytes: totalArchiveBytes,
                    completedUnitCount: ordered.count,
                    totalUnitCount: ordered.count
                )
            )
            try output.synchronize()
            try output.close()

            let archived = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard archived.isRegularFile == true,
                  (archived.fileSize ?? 0) > centralDirectory.count
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office batch archive is incomplete"
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: destination,
                fileManager: fileManager
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
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\"),
              name.utf8.count <= Int(UInt16.max)
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
    ) throws -> Int64 {
        var copiedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 256 * 1_024),
                  !chunk.isEmpty
            else { break }
            try output.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
            if copiedBytes - lastReportedBytes >= reportingStride {
                progress(copiedBytes)
                lastReportedBytes = copiedBytes
            }
        }
        if copiedBytes != lastReportedBytes {
            progress(copiedBytes)
        }
        return copiedBytes
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
            for byte in chunk {
                result ^= UInt32(byte)
                for _ in 0..<8 {
                    let mask = UInt32(
                        bitPattern: -Int32(result & 1)
                    )
                    result =
                        (result >> 1)
                        ^ (0xedb88320 & mask)
                }
            }
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
    private static let maximumArchiveBytes: Int64 =
        1_100 * 1_024 * 1_024
    private static let maximumEntryCount = 64
    private static let deliveryEntryCount = 2
    private static let maximumManifestBytes = 1 * 1_024 * 1_024

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
    }

    private struct StreamResult {
        let data: Data?
        let sha256: String
        let crc32: UInt32
        let prefix: Data
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
    }

    private struct DeliverySignatureInspection {
        let status: PDFOfficeReportVerificationStatus
        let detail: String
        let keyID: String?
        let publicKeyBase64: String?
        let trustStatus: PDFOfficeSignerTrustStatus
    }

    func verify(
        archiveURL: URL
    ) throws -> PDFVersionArchiveVerificationReport {
        let inspection = try inspectArchive(
            archiveURL: archiveURL,
            manifestName: Self.manifestName,
            maximumEntryCount: Self.maximumEntryCount
        )
        let decoded = try decodeManifest(inspection.manifestData)
        return makeReport(
            decoded: decoded,
            observed: inspection.observed,
            archiveName: archiveURL.lastPathComponent,
            archiveBytes: inspection.archiveBytes
        )
    }

    func verifyDeliveryPackage(
        archiveURL: URL,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> PDFDeliveryPackageVerificationReport {
        let inspection = try inspectArchive(
            archiveURL: archiveURL,
            manifestName: Self.deliveryManifestName,
            maximumEntryCount: Self.deliveryEntryCount,
            progress: progress
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            PDFSignedDeliveryPackageManifest.self,
            from: inspection.manifestData
        ),
        signed.manifest.isStructurallyValid
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

        return PDFDeliveryPackageVerificationReport(
            archiveName: archiveURL.lastPathComponent,
            archiveByteCount: inspection.archiveBytes,
            packageID: manifest.packageID,
            packageCreatedAt: manifest.createdAt,
            verifiedAt: Date(),
            artifactFileName: manifest.artifact.fileName,
            artifactByteCount: manifest.artifact.byteCount,
            artifactPageCount: manifest.artifact.pageCount,
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
            trustedSignerName: nil
        )
    }

    private func inspectArchive(
        archiveURL: URL,
        manifestName: String,
        maximumEntryCount: Int,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> ArchiveInspection {
        try Task.checkCancellation()
        let values = try archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
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
        var manifestData: Data?
        var entryIndex = 0
        while try input.offset() < end.centralOffset {
            try Task.checkCancellation()
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
            guard flags & 0x0001 == 0,
                  flags & 0x0008 == 0,
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
            guard observed[name] == nil else {
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
            let stream = try streamEntry(
                from: input,
                byteCount: Int64(compressedSize),
                collectsData: collectsData
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
            let isPDF = name.lowercased().hasSuffix(".pdf")
            observed[name] = ObservedEntry(
                byteCount: Int64(uncompressedSize),
                sha256: stream.sha256,
                crc32: stream.crc32,
                crcMatches: stream.crc32 == expectedCRC,
                hasPDFHeader: !isPDF
                    || stream.prefix.starts(with: Data("%PDF-".utf8)),
                localHeaderOffset: localHeaderOffset
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
        return ArchiveInspection(
            archiveBytes: archiveBytes,
            observed: observed,
            manifestData: manifestData
        )
    }

    private func verifyCentralDirectory(
        from input: FileHandle,
        record: EndRecord,
        observed: [String: ObservedEntry]
    ) throws -> Set<String> {
        var names: Set<String> = []
        for _ in 0..<record.entryCount {
            try Task.checkCancellation()
            let header = try readExactly(
                46,
                from: input,
                context: "central directory header"
            )
            guard header.uint32(at: 0) == 0x02014b50,
                  header.uint16(at: 8) & 0x0001 == 0,
                  header.uint16(at: 8) & 0x0008 == 0,
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
            guard names.insert(name).inserted,
                  let local = observed[name],
                  local.byteCount == centralSize,
                  local.crc32 == centralCRC,
                  local.localHeaderOffset == localHeaderOffset
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
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(
                    bitPattern: -Int32(result & 1)
                )
                result =
                    (result >> 1)
                    ^ (0xedb88320 & mask)
            }
        }
        return result
    }

    private func decodeManifest(
        _ data: Data
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
        try validateManifest(decoded.manifest)
        return decoded
    }

    private func verifySignedManifest(
        _ signed: PDFSignedVersionArchiveManifest
    ) -> DecodedManifest {
        let envelope = signed.signature
        guard signed.manifest.schema
                == "PaperPath Version Archive V49",
              envelope.algorithm == "Ed25519",
              let publicKeyData = Data(
                base64Encoded: envelope.publicKeyBase64
              ),
              let signatureData = Data(
                base64Encoded: envelope.signatureBase64
              ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
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
        let calculatedKeyID = SHA256.hash(data: publicKeyData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let isValid = calculatedKeyID == envelope.keyID
            && publicKey.isValidSignature(
                signatureData,
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
              envelope.algorithm == "Ed25519",
              let publicKeyData = Data(
                base64Encoded: envelope.publicKeyBase64
              ),
              let signatureData = Data(
                base64Encoded: envelope.signatureBase64
              ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
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
        let calculatedKeyID = SHA256.hash(data: publicKeyData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let isValid = calculatedKeyID == envelope.keyID
            && publicKey.isValidSignature(
                signatureData,
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
        _ manifest: PDFVersionArchiveManifest
    ) throws {
        let supportedSchemas = [
            "PaperPath Version Archive V47",
            "PaperPath Version Archive V48",
            "PaperPath Version Archive V49"
        ]
        guard supportedSchemas.contains(manifest.schema),
              !manifest.entries.isEmpty,
              manifest.entries.count
                <= PDFPinnedVersionStorageSummary.maximumMilestoneCount
        else {
            throw verificationFailure(
                "the version manifest schema or entry count is invalid"
            )
        }
        var names: Set<String> = []
        var snapshotIDs: Set<UUID> = []
        for entry in manifest.entries {
            try validateArchiveName(entry.fileName)
            guard entry.fileName.lowercased().hasSuffix(".pdf"),
                  names.insert(entry.fileName).inserted,
                  snapshotIDs.insert(entry.snapshotID).inserted,
                  entry.byteCount >= 0,
                  entry.byteCount
                    <= PDFPinnedVersionStorageSummary.maximumByteCount,
                  entry.pageCount > 0,
                  isSHA256(entry.sha256)
            else {
                throw verificationFailure(
                    "a version manifest entry is invalid or duplicated"
                )
            }
        }
    }

    private func makeReport(
        decoded: DecodedManifest,
        observed: [String: ObservedEntry],
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
                    fileName: entry.fileName,
                    title: entry.title,
                    byteCount: entry.byteCount,
                    pageCount: entry.pageCount,
                    expectedSHA256: entry.sha256,
                    actualSHA256: nil,
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
            return PDFVersionArchiveVerificationItem(
                id: entry.snapshotID,
                fileName: entry.fileName,
                title: entry.title,
                byteCount: entry.byteCount,
                pageCount: entry.pageCount,
                expectedSHA256: entry.sha256,
                actualSHA256: actual.sha256,
                status: failures.isEmpty ? .verified : .failed,
                detail: failures.isEmpty
                    ? "Manifest, CRC, bytes, and SHA-256 match"
                    : AppLocalization.format(
                        "Mismatch: %@",
                        failures.joined(separator: ", ")
                    )
            )
        }
        return PDFVersionArchiveVerificationReport(
            id: UUID(),
            archiveName: archiveName,
            archiveByteCount: archiveBytes,
            schema: manifest.schema,
            archiveCreatedAt: manifest.createdAt,
            verifiedAt: Date(),
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
            trustedSignerName: nil
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
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\"),
              name.utf8.count <= Int(UInt16.max)
        else {
            throw verificationFailure(
                "the archive contains an unsafe file name"
            )
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    private func verificationFailure(
        _ reason: String
    ) -> PaperPathError {
        .outputVerificationFailed(reason)
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
