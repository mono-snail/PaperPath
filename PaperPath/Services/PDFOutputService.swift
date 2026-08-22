import CommonCrypto
import CoreImage
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Security
import UIKit

typealias PDFProgressHandler = @Sendable (Double) -> Void

private struct PDFReplacementTextLayout {
    let font: UIFont
    let lineSpacing: CGFloat
    let lineCount: Int
    let regionTexts: [String]
}

private struct PDFReplacementFlowMeasurement {
    let fits: Bool
    let lineCount: Int
    let regionTexts: [String]
    let consumedUTF16Length: Int
    let splitWordAtRegionBoundary: Bool
}

private struct PDFReplacementLayoutAttempt {
    let layout: PDFReplacementTextLayout?
    let minimumFontSize: CGFloat
    let consumedUTF16Length: Int
    let splitWordAtRegionBoundary: Bool
}

private struct PDFBookletSignaturePlan {
    let number: Int
    let startPageIndex: Int
    let sourcePageCount: Int
    let paddedPageCount: Int
}

struct PDFCompressionEstimate: Equatable, Sendable {
    let sourceByteCount: Int64
    let estimatedByteCount: Int64
    let sampledPageCount: Int

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: estimatedByteCount,
            countStyle: .file
        )
    }

    var savingsPercent: Int? {
        guard sourceByteCount > 0,
              estimatedByteCount < sourceByteCount
        else { return nil }
        return Int(
            (
                1
                    - Double(estimatedByteCount)
                    / Double(sourceByteCount)
            ) * 100
        )
    }

    var summary: String {
        if let savingsPercent {
            return AppLocalization.format(
                "About %lld%% smaller · sampled %lld page%@",
                savingsPercent,
                sampledPageCount,
                sampledPageCount == 1 ? "" : "s"
            )
        }
        return AppLocalization.format(
            "May not reduce this PDF · sampled %lld page%@",
            sampledPageCount,
            sampledPageCount == 1 ? "" : "s"
        )
    }
}

enum PDFCompressionQuality:
    String,
    CaseIterable,
    Identifiable,
    Hashable {
    case readable
    case balanced
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readable: return "Readable"
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        }
    }

    var detail: String {
        switch self {
        case .readable: return "Sharper pages for review and printing"
        case .balanced: return "A practical balance for email and storage"
        case .compact: return "Smallest output for quick sharing"
        }
    }

    fileprivate var longestEdge: CGFloat {
        switch self {
        case .readable: return 2_400
        case .balanced: return 1_800
        case .compact: return 1_200
        }
    }

    fileprivate var jpegQuality: CGFloat {
        switch self {
        case .readable: return 0.88
        case .balanced: return 0.72
        case .compact: return 0.5
        }
    }
}

struct PDFOutputService: @unchecked Sendable {
    func bookletAssessment(
        sourceURL: URL,
        revisionID: UUID,
        options: PDFBookletOptions
    ) throws -> PDFBookletAssessment {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= 1_000 else {
            throw PaperPathError.insufficientSelection(
                "Booklet preparation supports up to 1,000 pages."
            )
        }
        let normalizedOptions = normalizedBookletOptions(options)
        var pageSizes: [CGSize] = []
        pageSizes.reserveCapacity(document.pageCount)
        var annotationCount = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let bounds = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let swapsEdges = rotation == 90 || rotation == 270
            let size = CGSize(
                width: swapsEdges ? bounds.height : bounds.width,
                height: swapsEdges ? bounds.width : bounds.height
            )
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0
            else {
                throw PaperPathError.outputVerificationFailed(
                    AppLocalization.format(
                        "page %lld has invalid geometry",
                        pageIndex + 1
                    )
                )
            }
            pageSizes.append(size)
            annotationCount += page.annotations.count
        }
        let signaturePlans = bookletSignaturePlans(
            sourcePageCount: document.pageCount,
            options: normalizedOptions
        )
        let paddedPageCount = signaturePlans.reduce(0) {
            $0 + $1.paddedPageCount
        }
        let spreads = bookletSpreads(
            signaturePlans: signaturePlans,
            pageSizes: pageSizes,
            options: normalizedOptions
        )
        return PDFBookletAssessment(
            revisionID: revisionID,
            options: normalizedOptions,
            sourcePageCount: document.pageCount,
            paddedPageCount: paddedPageCount,
            annotationCount: annotationCount,
            spreads: spreads
        )
    }

    func prepareBooklet(
        sourceURL: URL,
        destination: URL,
        options: PDFBookletOptions,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        let sourceByteCount = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceByteCount <= 1_024 * 1_024 * 1_024 else {
            throw PaperPathError.fileTooLarge
        }
        guard let sourceDocument = PDFDocument(url: sourceURL),
              !sourceDocument.isLocked,
              sourceDocument.pageCount > 0,
              sourceDocument.pageCount <= 1_000,
              let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              source.numberOfPages == sourceDocument.pageCount
        else {
            throw PaperPathError.unreadablePDF
        }
        let normalizedOptions = normalizedBookletOptions(options)
        let assessment = try bookletAssessment(
            sourceURL: sourceURL,
            revisionID: UUID(),
            options: normalizedOptions
        )
        guard let firstSpread = assessment.spreads.first else {
            throw PaperPathError.unreadablePDF
        }

        try? FileManager.default.removeItem(at: destination)
        guard let consumer = CGDataConsumer(
            url: destination as CFURL
        ) else {
            throw PaperPathError.storageFailure(
                "The booklet destination could not be created."
            )
        }
        var defaultMediaBox = CGRect(
            x: 0,
            y: 0,
            width: firstSpread.sheetWidth,
            height: firstSpread.sheetHeight
        )
        let metadata = [
            kCGPDFContextCreator as String: "PaperPath"
        ] as CFDictionary
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultMediaBox,
            metadata
        ) else {
            throw PaperPathError.storageFailure(
                "The booklet PDF context could not be created."
            )
        }

        progress(0.02)
        for (offset, spread) in assessment.spreads.enumerated() {
            try Task.checkCancellation()
            let sheetBounds = CGRect(
                x: 0,
                y: 0,
                width: spread.sheetWidth,
                height: spread.sheetHeight
            )
            let pageInfo = [
                kCGPDFContextMediaBox as String: sheetBounds,
                kCGPDFContextCropBox as String: sheetBounds
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(sheetBounds)

            let slotBounds = bookletSlotBounds(
                sheetWidth: spread.sheetWidth,
                sheetHeight: spread.sheetHeight,
                options: normalizedOptions
            )
            try drawBookletSlot(
                spread.left,
                in: slotBounds.left,
                source: source,
                sourceDocument: sourceDocument,
                context: context
            )
            try drawBookletSlot(
                spread.right,
                in: slotBounds.right,
                source: source,
                sourceDocument: sourceDocument,
                context: context
            )
            if normalizedOptions.showsFoldMarks {
                drawBookletFoldMarks(
                    sheetBounds: sheetBounds,
                    context: context
                )
            }
            context.endPDFPage()
            progress(
                0.84 * Double(offset + 1)
                    / Double(assessment.spreads.count)
            )
        }
        context.closePDF()
        try Task.checkCancellation()

        guard let output = PDFDocument(url: destination),
              output.pageCount == assessment.outputPageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the booklet copy could not be reopened"
            )
        }
        for pageIndex in 0..<output.pageCount {
            try Task.checkCancellation()
            guard let page = output.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let bounds = page.bounds(for: .mediaBox)
            guard abs(
                Double(bounds.width) - firstSpread.sheetWidth
            ) <= 1,
            abs(
                Double(bounds.height) - firstSpread.sheetHeight
            ) <= 1,
            page.annotations.isEmpty
            else {
                throw PaperPathError.outputVerificationFailed(
                    AppLocalization.format(
                        "booklet side %lld did not retain its sheet geometry",
                        pageIndex + 1
                    )
                )
            }
            progress(
                0.84
                    + 0.14 * Double(pageIndex + 1)
                    / Double(output.pageCount)
            )
        }
        let outputByteCount = try destination.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard outputByteCount > 0,
              outputByteCount <= 1_024 * 1_024 * 1_024
        else {
            throw PaperPathError.fileTooLarge
        }
        LocalFileSecurity.applyCompleteProtection(to: destination)
        progress(1)
    }

    func printPreparationAssessment(
        sourceURL: URL,
        revisionID: UUID,
        options: PDFPrintPreparationOptions
    ) throws -> PDFPrintPreparationAssessment {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= 1_000 else {
            throw PaperPathError.insufficientSelection(
                "Print preparation supports up to 1,000 pages."
            )
        }

        let cgDocument = CGPDFDocument(sourceURL as CFURL)
        var pages: [PDFPrintPreparationPage] = []
        pages.reserveCapacity(document.pageCount)
        var annotationCount = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let bounds = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let swapsEdges = rotation == 90 || rotation == 270
            let sourceWidth = Double(
                swapsEdges ? bounds.height : bounds.width
            )
            let sourceHeight = Double(
                swapsEdges ? bounds.width : bounds.height
            )
            guard sourceWidth.isFinite,
                  sourceHeight.isFinite,
                  sourceWidth > 0,
                  sourceHeight > 0
            else {
                throw PaperPathError.outputVerificationFailed(
                    AppLocalization.format(
                        "page %lld has invalid geometry",
                        pageIndex + 1
                    )
                )
            }
            pages.append(
                printPreparationPage(
                    pageIndex: pageIndex,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    options: options,
                    productionEvidence: printProductionEvidence(
                        page: page,
                        cgPage: cgDocument?.page(at: pageIndex + 1),
                        pageIndex: pageIndex
                    )
                )
            )
            annotationCount += page.annotations.count
        }
        return PDFPrintPreparationAssessment(
            revisionID: revisionID,
            options: options,
            annotationCount: annotationCount,
            pages: pages
        )
    }

    func prepareForPrint(
        sourceURL: URL,
        destination: URL,
        options: PDFPrintPreparationOptions,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        let sourceByteCount = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceByteCount <= 1_024 * 1_024 * 1_024 else {
            throw PaperPathError.fileTooLarge
        }
        guard let sourceDocument = PDFDocument(url: sourceURL),
              !sourceDocument.isLocked,
              sourceDocument.pageCount > 0,
              sourceDocument.pageCount <= 1_000,
              let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              source.numberOfPages == sourceDocument.pageCount,
              let firstPage = sourceDocument.page(at: 0)
        else {
            throw PaperPathError.unreadablePDF
        }

        let firstBounds = firstPage.bounds(for: .cropBox)
        let firstRotation =
            ((firstPage.rotation % 360) + 360) % 360
        let firstSwapsEdges =
            firstRotation == 90 || firstRotation == 270
        let firstPlan = printPreparationPage(
            pageIndex: 0,
            sourceWidth: Double(
                firstSwapsEdges
                    ? firstBounds.height
                    : firstBounds.width
            ),
            sourceHeight: Double(
                firstSwapsEdges
                    ? firstBounds.width
                    : firstBounds.height
            ),
            options: options
        )

        try? FileManager.default.removeItem(at: destination)
        guard let consumer = CGDataConsumer(
            url: destination as CFURL
        ) else {
            throw PaperPathError.storageFailure(
                "The print-ready destination could not be created."
            )
        }
        var defaultMediaBox = CGRect(
            x: 0,
            y: 0,
            width: firstPlan.outputWidth,
            height: firstPlan.outputHeight
        )
        let metadata = [
            kCGPDFContextCreator as String: "PaperPath"
        ] as CFDictionary
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultMediaBox,
            metadata
        ) else {
            throw PaperPathError.storageFailure(
                "The print-ready PDF context could not be created."
            )
        }

        progress(0.02)
        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            let pageIndex = pageNumber - 1
            guard let sourcePage = source.page(at: pageNumber),
                  let kitPage = sourceDocument.page(at: pageIndex)
            else {
                context.closePDF()
                throw PaperPathError.invalidPage
            }
            let bounds = kitPage.bounds(for: .cropBox)
            let rotation =
                ((kitPage.rotation % 360) + 360) % 360
            let swapsEdges = rotation == 90 || rotation == 270
            let plan = printPreparationPage(
                pageIndex: pageIndex,
                sourceWidth: Double(
                    swapsEdges ? bounds.height : bounds.width
                ),
                sourceHeight: Double(
                    swapsEdges ? bounds.width : bounds.height
                ),
                options: options
            )
            let pageBounds = CGRect(
                x: 0,
                y: 0,
                width: plan.outputWidth,
                height: plan.outputHeight
            )
            let pageInfo = [
                kCGPDFContextMediaBox as String: pageBounds,
                kCGPDFContextCropBox as String: pageBounds
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(pageBounds)

            let printableBounds = CGRect(
                x: (plan.outputWidth - plan.printableWidth) / 2,
                y: (plan.outputHeight - plan.printableHeight) / 2,
                width: plan.printableWidth,
                height: plan.printableHeight
            )
            let destinationBounds = CGRect(
                x: printableBounds.midX - plan.renderedWidth / 2,
                y: printableBounds.midY - plan.renderedHeight / 2,
                width: plan.renderedWidth,
                height: plan.renderedHeight
            )
            context.saveGState()
            context.clip(to: printableBounds)
            let transform = sourcePage.getDrawingTransform(
                .cropBox,
                rect: destinationBounds,
                rotate: 0,
                preserveAspectRatio: true
            )
            context.concatenate(transform)
            context.drawPDFPage(sourcePage)
            for annotation in kitPage.annotations {
                annotation.draw(with: .cropBox, in: context)
            }
            context.restoreGState()
            context.endPDFPage()
            progress(
                0.84 * Double(pageNumber)
                    / Double(source.numberOfPages)
            )
        }
        context.closePDF()
        try Task.checkCancellation()
        progress(0.88)

        guard let output = PDFDocument(url: destination),
              output.pageCount == sourceDocument.pageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the print-ready copy could not be reopened"
            )
        }
        for pageIndex in 0..<output.pageCount {
            try Task.checkCancellation()
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                  let outputPage = output.page(at: pageIndex)
            else {
                throw PaperPathError.invalidPage
            }
            let sourceBounds = sourcePage.bounds(for: .cropBox)
            let rotation =
                ((sourcePage.rotation % 360) + 360) % 360
            let swapsEdges = rotation == 90 || rotation == 270
            let expected = printPreparationPage(
                pageIndex: pageIndex,
                sourceWidth: Double(
                    swapsEdges
                        ? sourceBounds.height
                        : sourceBounds.width
                ),
                sourceHeight: Double(
                    swapsEdges
                        ? sourceBounds.width
                        : sourceBounds.height
                ),
                options: options
            )
            let actual = outputPage.bounds(for: .mediaBox)
            guard abs(Double(actual.width) - expected.outputWidth)
                    <= 1,
                  abs(Double(actual.height) - expected.outputHeight)
                    <= 1,
                  outputPage.annotations.isEmpty
            else {
                throw PaperPathError.outputVerificationFailed(
                    AppLocalization.format(
                        "page %lld did not retain its print geometry",
                        pageIndex + 1
                    )
                )
            }
            progress(
                0.88
                    + 0.1 * Double(pageIndex + 1)
                    / Double(output.pageCount)
            )
        }
        let outputByteCount = try destination.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard outputByteCount > 0,
              outputByteCount <= 1_024 * 1_024 * 1_024
        else {
            throw PaperPathError.fileTooLarge
        }
        LocalFileSecurity.applyCompleteProtection(to: destination)
        progress(1)
    }

    func estimateCompression(
        sourceURL: URL,
        quality: PDFCompressionQuality
    ) throws -> PDFCompressionEstimate {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let sourceByteCount = Int64(
            try sourceURL.resourceValues(forKeys: [.fileSizeKey])
                .fileSize ?? 0
        )
        let lastIndex = document.pageCount - 1
        let sampleIndices = Array(
            Set([0, lastIndex / 2, lastIndex])
        ).sorted()
        var encodedByteCount: Int64 = 0
        var sampledPageCount = 0

        for index in sampleIndices {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let byteCount: Int? = autoreleasepool {
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width > 0, bounds.height > 0 else {
                    return nil
                }
                let size = fittedSize(
                    bounds.size,
                    longestEdge: quality.longestEdge
                )
                return page.thumbnail(of: size, for: .cropBox)
                    .jpegData(compressionQuality: quality.jpegQuality)?
                    .count
            }
            guard let byteCount else { continue }
            encodedByteCount += Int64(byteCount)
            sampledPageCount += 1
        }

        guard sampledPageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        let averagePageBytes = encodedByteCount
            / Int64(sampledPageCount)
        let estimatedByteCount = averagePageBytes
            * Int64(document.pageCount)
            + Int64(document.pageCount * 2_048)
            + 8_192
        return PDFCompressionEstimate(
            sourceByteCount: sourceByteCount,
            estimatedByteCount: estimatedByteCount,
            sampledPageCount: sampledPageCount
        )
    }

    private func printPreparationPage(
        pageIndex: Int,
        sourceWidth: Double,
        sourceHeight: Double,
        options: PDFPrintPreparationOptions,
        productionEvidence: PDFPrintProductionEvidence? = nil
    ) -> PDFPrintPreparationPage {
        let outputSize: (width: Double, height: Double)
        if let target = options.paperTarget.portraitSize {
            switch options.orientation {
            case .automatic:
                outputSize = sourceWidth > sourceHeight
                    ? (target.height, target.width)
                    : target
            case .portrait:
                outputSize = target
            case .landscape:
                outputSize = (target.height, target.width)
            }
        } else {
            outputSize = (sourceWidth, sourceHeight)
        }
        let maximumMargin = max(
            0,
            min(outputSize.width, outputSize.height) / 2 - 12
        )
        let margin = min(
            options.clampedMarginPoints,
            maximumMargin
        )
        let printableWidth = max(24, outputSize.width - margin * 2)
        let printableHeight = max(24, outputSize.height - margin * 2)
        let widthScale = printableWidth / sourceWidth
        let heightScale = printableHeight / sourceHeight
        let scale: Double
        switch options.scaleMode {
        case .fit:
            scale = min(widthScale, heightScale)
        case .fill:
            scale = max(widthScale, heightScale)
        case .actual:
            scale = 1
        }
        let renderedWidth = sourceWidth * scale
        let renderedHeight = sourceHeight * scale
        let visibleWidth = min(renderedWidth, printableWidth)
            / max(1, renderedWidth)
        let visibleHeight = min(renderedHeight, printableHeight)
            / max(1, renderedHeight)
        return PDFPrintPreparationPage(
            pageIndex: pageIndex,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: outputSize.width,
            outputHeight: outputSize.height,
            printableWidth: printableWidth,
            printableHeight: printableHeight,
            renderedWidth: renderedWidth,
            renderedHeight: renderedHeight,
            scale: scale,
            visibleFraction: visibleWidth * visibleHeight,
            productionEvidence: productionEvidence
                ?? emptyPrintProductionEvidence(pageIndex: pageIndex)
        )
    }

    private func printProductionEvidence(
        page: PDFPage,
        cgPage: CGPDFPage?,
        pageIndex: Int
    ) -> PDFPrintProductionEvidence {
        let requiredBleedPoints = 8.5
        let requiredSafeAreaPoints = 18.0
        let cropBox = standardized(
            cgPage?.getBoxRect(.cropBox)
                ?? page.bounds(for: .cropBox)
        )
        let mediaBox = standardized(
            cgPage?.getBoxRect(.mediaBox)
                ?? page.bounds(for: .mediaBox)
        )
        let trimBox = standardized(
            cgPage?.getBoxRect(.trimBox)
                ?? page.bounds(for: .trimBox)
        )
        let bleedBox = standardized(
            cgPage?.getBoxRect(.bleedBox)
                ?? page.bounds(for: .bleedBox)
        )
        let referenceBox = cropBox.isEmpty ? mediaBox : cropBox
        let effectiveTrimBox = trimBox.isEmpty ? referenceBox : trimBox
        let effectiveBleedBox = bleedBox.isEmpty
            ? referenceBox
            : bleedBox
        let hasExplicitTrimBox = !rectsNearlyEqual(
            effectiveTrimBox,
            referenceBox,
            tolerance: 1
        )
        let bleedAllowances = bleedAllowancePoints(
            trimBox: effectiveTrimBox,
            bleedBox: effectiveBleedBox
        )
        let hasBleedAllowance =
            (bleedAllowances.min() ?? 0) >= requiredBleedPoints * 0.82
        let trimInsets = edgeInsets(
            inner: effectiveTrimBox,
            outer: referenceBox
        )
        let bleedInsets = edgeInsets(
            inner: effectiveBleedBox,
            outer: referenceBox
        )
        let nearestContent = contentBounds(on: page).map {
            nearestDistance(
                from: $0,
                toInsideOf: effectiveTrimBox
            )
        }
        let safeAreaRisk: PDFPrintProductionRisk
        if let nearestContent {
            if nearestContent < requiredSafeAreaPoints * 0.5 {
                safeAreaRisk = .risk
            } else if nearestContent < requiredSafeAreaPoints {
                safeAreaRisk = .caution
            } else {
                safeAreaRisk = .clear
            }
        } else {
            safeAreaRisk = .clear
        }
        let bleedRisk: PDFPrintProductionRisk
        if !hasExplicitTrimBox {
            bleedRisk = .caution
        } else if hasBleedAllowance {
            bleedRisk = .clear
        } else {
            bleedRisk = .risk
        }

        return PDFPrintProductionEvidence(
            pageIndex: pageIndex,
            trimBoxInsetPoints: trimInsets,
            bleedInsetPoints: bleedInsets,
            requiredBleedPoints: requiredBleedPoints,
            requiredSafeAreaPoints: requiredSafeAreaPoints,
            nearestContentToTrimPoints: nearestContent,
            hasExplicitTrimBox: hasExplicitTrimBox,
            hasBleedAllowance: hasBleedAllowance,
            safeAreaRisk: safeAreaRisk,
            bleedRisk: bleedRisk
        )
    }

    private func emptyPrintProductionEvidence(
        pageIndex: Int
    ) -> PDFPrintProductionEvidence {
        PDFPrintProductionEvidence(
            pageIndex: pageIndex,
            trimBoxInsetPoints: .none,
            bleedInsetPoints: .none,
            requiredBleedPoints: 8.5,
            requiredSafeAreaPoints: 18,
            nearestContentToTrimPoints: nil,
            hasExplicitTrimBox: false,
            hasBleedAllowance: false,
            safeAreaRisk: .clear,
            bleedRisk: .caution
        )
    }

    private func contentBounds(on page: PDFPage) -> CGRect? {
        var result: CGRect?
        if let pageText = page.string,
           !pageText.isEmpty,
           let selection = page.selection(
               for: NSRange(
                   location: 0,
                   length: (pageText as NSString).length
               )
           ) {
            for line in selection.selectionsByLine() {
                let bounds = standardized(line.bounds(for: page))
                guard bounds.width > 0, bounds.height > 0 else {
                    continue
                }
                result = result.map { $0.union(bounds) } ?? bounds
            }
        }
        for annotation in page.annotations {
            let bounds = standardized(annotation.bounds)
            guard bounds.width > 0, bounds.height > 0 else {
                continue
            }
            result = result.map { $0.union(bounds) } ?? bounds
        }
        return result
    }

    private func edgeInsets(
        inner: CGRect,
        outer: CGRect
    ) -> PDFPageCropInsets {
        guard !inner.isEmpty, !outer.isEmpty else { return .none }
        return PDFPageCropInsets(
            top: max(0, Double(outer.maxY - inner.maxY)),
            right: max(0, Double(outer.maxX - inner.maxX)),
            bottom: max(0, Double(inner.minY - outer.minY)),
            left: max(0, Double(inner.minX - outer.minX))
        )
    }

    private func bleedAllowancePoints(
        trimBox: CGRect,
        bleedBox: CGRect
    ) -> [Double] {
        guard !trimBox.isEmpty, !bleedBox.isEmpty else {
            return [0, 0, 0, 0]
        }
        return [
            Double(trimBox.minY - bleedBox.minY),
            Double(bleedBox.maxX - trimBox.maxX),
            Double(bleedBox.maxY - trimBox.maxY),
            Double(trimBox.minX - bleedBox.minX)
        ].map { max(0, $0) }
    }

    private func nearestDistance(
        from contentBounds: CGRect,
        toInsideOf trimBox: CGRect
    ) -> Double {
        guard !contentBounds.isEmpty, !trimBox.isEmpty else {
            return .infinity
        }
        return [
            Double(contentBounds.minX - trimBox.minX),
            Double(trimBox.maxX - contentBounds.maxX),
            Double(contentBounds.minY - trimBox.minY),
            Double(trimBox.maxY - contentBounds.maxY)
        ].min() ?? .infinity
    }

    private func standardized(_ rect: CGRect) -> CGRect {
        rect.standardized
    }

    private func rectsNearlyEqual(
        _ first: CGRect,
        _ second: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(first.minX - second.minX) <= tolerance
            && abs(first.minY - second.minY) <= tolerance
            && abs(first.width - second.width) <= tolerance
            && abs(first.height - second.height) <= tolerance
    }

    private func normalizedBookletOptions(
        _ options: PDFBookletOptions
    ) -> PDFBookletOptions {
        var result = options
        if result.paperTarget == .original {
            result.paperTarget = .a4
        }
        result.outerMarginPoints =
            result.clampedOuterMarginPoints
        result.gutterPoints = result.clampedGutterPoints
        result.signatureSheetLimit =
            result.normalizedSignatureSheetLimit
        result.creepCompensationPoints =
            result.clampedCreepCompensationPoints
        return result
    }

    private func bookletSignaturePlans(
        sourcePageCount: Int,
        options: PDFBookletOptions
    ) -> [PDFBookletSignaturePlan] {
        let sheetLimit = options.normalizedSignatureSheetLimit
        guard sheetLimit > 0 else {
            return [
                PDFBookletSignaturePlan(
                    number: 1,
                    startPageIndex: 0,
                    sourcePageCount: sourcePageCount,
                    paddedPageCount:
                        ((sourcePageCount + 3) / 4) * 4
                )
            ]
        }
        let pageLimit = sheetLimit * 4
        var plans: [PDFBookletSignaturePlan] = []
        var start = 0
        while start < sourcePageCount {
            let count = min(pageLimit, sourcePageCount - start)
            plans.append(
                PDFBookletSignaturePlan(
                    number: plans.count + 1,
                    startPageIndex: start,
                    sourcePageCount: count,
                    paddedPageCount: ((count + 3) / 4) * 4
                )
            )
            start += count
        }
        return plans
    }

    private func bookletSpreads(
        signaturePlans: [PDFBookletSignaturePlan],
        pageSizes: [CGSize],
        options: PDFBookletOptions
    ) -> [PDFBookletSpread] {
        let target = options.paperTarget.portraitSize
            ?? PDFPrintPaperTarget.a4.portraitSize!
        let sheetWidth = target.height
        let sheetHeight = target.width
        let slotBounds = bookletSlotBounds(
            sheetWidth: sheetWidth,
            sheetHeight: sheetHeight,
            options: options
        )

        func slot(
            virtualPageIndex: Int,
            plan: PDFBookletSignaturePlan,
            bounds: CGRect,
            isLeftSlot: Bool,
            sheetIndex: Int,
            signatureSheetCount: Int
        ) -> PDFBookletSlot {
            let creepDepth = signatureSheetCount <= 1
                ? 0
                : Double(sheetIndex)
                    / Double(max(1, signatureSheetCount - 1))
            let creepMagnitude =
                options.clampedCreepCompensationPoints * creepDepth
            let creepOffset = isLeftSlot
                ? -creepMagnitude
                : creepMagnitude
            guard virtualPageIndex >= 0,
                  virtualPageIndex < plan.sourcePageCount
            else {
                return PDFBookletSlot(
                    sourcePageIndex: nil,
                    scale: 1,
                    visibleFraction: 1,
                    creepOffsetPoints: creepOffset
                )
            }
            let sourcePageIndex = plan.startPageIndex + virtualPageIndex
            guard pageSizes.indices.contains(sourcePageIndex) else {
                return PDFBookletSlot(
                    sourcePageIndex: nil,
                    scale: 1,
                    visibleFraction: 1,
                    creepOffsetPoints: creepOffset
                )
            }
            let size = pageSizes[sourcePageIndex]
            let scale = min(
                bounds.width / size.width,
                bounds.height / size.height
            )
            return PDFBookletSlot(
                sourcePageIndex: sourcePageIndex,
                scale: Double(scale),
                visibleFraction: 1,
                creepOffsetPoints: creepOffset
            )
        }

        var spreads: [PDFBookletSpread] = []
        spreads.reserveCapacity(
            signaturePlans.reduce(0) { $0 + $1.paddedPageCount / 2 }
        )
        for plan in signaturePlans {
            let signatureSheetCount = plan.paddedPageCount / 4
            for sheetIndex in 0..<signatureSheetCount {
                let frontIndices = (
                    left: plan.paddedPageCount - 1 - sheetIndex * 2,
                    right: sheetIndex * 2
                )
                let backIndices = (
                    left: sheetIndex * 2 + 1,
                    right: plan.paddedPageCount - 2 - sheetIndex * 2
                )
                let orderedFront = options.bindingEdge == .left
                    ? frontIndices
                    : (
                        left: frontIndices.right,
                        right: frontIndices.left
                    )
                let orderedBack = options.bindingEdge == .left
                    ? backIndices
                    : (
                        left: backIndices.right,
                        right: backIndices.left
                    )
                spreads.append(
                    PDFBookletSpread(
                        outputPageIndex: spreads.count,
                        signatureNumber: plan.number,
                        signatureSheetCount: signatureSheetCount,
                        sheetNumber: sheetIndex + 1,
                        side: .front,
                        left: slot(
                            virtualPageIndex: orderedFront.left,
                            plan: plan,
                            bounds: slotBounds.left,
                            isLeftSlot: true,
                            sheetIndex: sheetIndex,
                            signatureSheetCount: signatureSheetCount
                        ),
                        right: slot(
                            virtualPageIndex: orderedFront.right,
                            plan: plan,
                            bounds: slotBounds.right,
                            isLeftSlot: false,
                            sheetIndex: sheetIndex,
                            signatureSheetCount: signatureSheetCount
                        ),
                        sheetWidth: sheetWidth,
                        sheetHeight: sheetHeight
                    )
                )
                spreads.append(
                    PDFBookletSpread(
                        outputPageIndex: spreads.count,
                        signatureNumber: plan.number,
                        signatureSheetCount: signatureSheetCount,
                        sheetNumber: sheetIndex + 1,
                        side: .back,
                        left: slot(
                            virtualPageIndex: orderedBack.left,
                            plan: plan,
                            bounds: slotBounds.left,
                            isLeftSlot: true,
                            sheetIndex: sheetIndex,
                            signatureSheetCount: signatureSheetCount
                        ),
                        right: slot(
                            virtualPageIndex: orderedBack.right,
                            plan: plan,
                            bounds: slotBounds.right,
                            isLeftSlot: false,
                            sheetIndex: sheetIndex,
                            signatureSheetCount: signatureSheetCount
                        ),
                        sheetWidth: sheetWidth,
                        sheetHeight: sheetHeight
                    )
                )
            }
        }
        return spreads
    }

    private func bookletSlotBounds(
        sheetWidth: Double,
        sheetHeight: Double,
        options: PDFBookletOptions
    ) -> (left: CGRect, right: CGRect) {
        let margin = options.clampedOuterMarginPoints
        let gutter = options.clampedGutterPoints
        let halfWidth = sheetWidth / 2
        let contentWidth = max(
            24,
            halfWidth - margin - gutter / 2
        )
        let contentHeight = max(24, sheetHeight - margin * 2)
        return (
            CGRect(
                x: margin,
                y: margin,
                width: contentWidth,
                height: contentHeight
            ),
            CGRect(
                x: halfWidth + gutter / 2,
                y: margin,
                width: contentWidth,
                height: contentHeight
            )
        )
    }

    private func drawBookletSlot(
        _ slot: PDFBookletSlot,
        in bounds: CGRect,
        source: CGPDFDocument,
        sourceDocument: PDFDocument,
        context: CGContext
    ) throws {
        guard let pageIndex = slot.sourcePageIndex else { return }
        try Task.checkCancellation()
        guard let sourcePage = source.page(at: pageIndex + 1),
              let kitPage = sourceDocument.page(at: pageIndex)
        else {
            throw PaperPathError.invalidPage
        }
        context.saveGState()
        context.clip(to: bounds)
        let destinationBounds = bounds.offsetBy(
            dx: CGFloat(slot.creepOffsetPoints),
            dy: 0
        )
        let transform = sourcePage.getDrawingTransform(
            .cropBox,
            rect: destinationBounds,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.drawPDFPage(sourcePage)
        for annotation in kitPage.annotations {
            annotation.draw(with: .cropBox, in: context)
        }
        context.restoreGState()
    }

    private func drawBookletFoldMarks(
        sheetBounds: CGRect,
        context: CGContext
    ) {
        let centerX = sheetBounds.midX
        let length: CGFloat = 12
        context.saveGState()
        context.setStrokeColor(
            UIColor.secondaryLabel.withAlphaComponent(0.7).cgColor
        )
        context.setLineWidth(0.55)
        context.move(
            to: CGPoint(x: centerX, y: sheetBounds.minY)
        )
        context.addLine(
            to: CGPoint(x: centerX, y: sheetBounds.minY + length)
        )
        context.move(
            to: CGPoint(x: centerX, y: sheetBounds.maxY)
        )
        context.addLine(
            to: CGPoint(x: centerX, y: sheetBounds.maxY - length)
        )
        context.strokePath()
        context.restoreGState()
    }

    func compress(
        sourceURL: URL,
        destination: URL,
        quality: PDFCompressionQuality,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try renderRasterized(
            sourceURL: sourceURL,
            destination: destination,
            longestEdge: quality.longestEdge,
            jpegQuality: quality.jpegQuality,
            redactions: [],
            progress: progress
        )
    }

    func secureRedact(
        sourceURL: URL,
        destination: URL,
        marks: [PDFRedactionMark],
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard !marks.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Select text in the PDF before marking it for redaction."
            )
        }
        try renderRasterized(
            sourceURL: sourceURL,
            destination: destination,
            longestEdge: 2_400,
            jpegQuality: 0.9,
            redactions: marks,
            progress: progress
        )
    }

    func flatten(
        sourceURL: URL,
        destination: URL,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try renderRasterized(
            sourceURL: sourceURL,
            destination: destination,
            longestEdge: 2_400,
            jpegQuality: 0.92,
            redactions: [],
            progress: progress
        )
    }

    func safeShare(
        sourceURL: URL,
        destination: URL,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try renderRasterized(
            sourceURL: sourceURL,
            destination: destination,
            longestEdge: 2_400,
            jpegQuality: 0.92,
            redactions: [],
            progress: progress
        )
    }

    func protect(
        sourceURL: URL,
        destination: URL,
        password: String,
        permissions: PDFProtectionPermissions = .restricted,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        progress(0.08)
        guard (8...128).contains(password.count) else {
            throw PaperPathError.invalidPassword
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }
        let structureService = PDFDocumentStructureService()
        let sourceStructure = try structureService
            .preservationSignature(
                in: sourceURL,
                includePageLabels: true
            )
        let attachmentPayloads = try structureService
            .attachmentPayloads(in: sourceURL)
        let pageLabels = try structureService.pageLabels(in: sourceURL)
        var permissionValue = PDFAccessPermissions
            .allowsContentAccessibility.rawValue
        if permissions.allowsPrinting {
            permissionValue |= PDFAccessPermissions
                .allowsHighQualityPrinting.rawValue
        }
        if permissions.allowsCopying {
            permissionValue |= PDFAccessPermissions
                .allowsContentCopying.rawValue
        }
        if permissions.allowsCommenting {
            permissionValue |= PDFAccessPermissions
                .allowsCommenting.rawValue
        } else if permissions.allowsFormFilling {
            permissionValue |= PDFAccessPermissions
                .allowsFormFieldEntry.rawValue
        }
        if permissions.allowsPageChanges {
            permissionValue |= PDFAccessPermissions
                .allowsDocumentAssembly.rawValue
        }
        let ownerPassword = UUID().uuidString
            + UUID().uuidString
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: ownerPassword,
            .accessPermissionsOption:
                NSNumber(value: permissionValue)
        ]
        let encryptedBase = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".protect-base-\(UUID().uuidString).pdf"
            )
        defer {
            try? FileManager.default.removeItem(at: encryptedBase)
        }
        guard document.write(
            to: encryptedBase,
            withOptions: options
        ) else {
            throw PaperPathError.storageFailure(
                "The protected PDF could not be written."
            )
        }
        let encryptedData = try Data(
            contentsOf: encryptedBase,
            options: .mappedIfSafe
        )
        let protectedData = try PDFCatalogStructureAppender(
            data: encryptedData
        ).appending(
            attachmentPayloads: attachmentPayloads,
            pageLabels: pageLabels,
            encryptionPassword: password
        )
        try protectedData.write(to: destination, options: .atomic)
        guard let reopened = PDFDocument(url: destination),
              reopened.isLocked,
              reopened.unlock(withPassword: password)
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the protected copy permissions did not persist"
            )
        }
        let persisted = reopened.accessPermissions.rawValue
        func contains(_ permission: PDFAccessPermissions) -> Bool {
            persisted & permission.rawValue != 0
        }
        guard contains(.allowsContentAccessibility),
              contains(.allowsHighQualityPrinting)
                == permissions.allowsPrinting,
              contains(.allowsContentCopying)
                == permissions.allowsCopying,
              contains(.allowsCommenting)
                == permissions.allowsCommenting,
              (
                  contains(.allowsFormFieldEntry)
                      || contains(.allowsCommenting)
              ) == (
                  permissions.allowsFormFilling
                      || permissions.allowsCommenting
              ),
              contains(.allowsDocumentAssembly)
                == permissions.allowsPageChanges
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the protected copy permissions did not persist"
            )
        }
        let outputStructure = try structureService
            .preservationSignature(
                in: destination,
                unlockPassword: password,
                includePageLabels: true
            )
        guard outputStructure == sourceStructure else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "attachments, page labels, review objects, or outlines changed while adding password protection"
            )
        }
        progress(0.92)
        LocalFileSecurity.applyCompleteProtection(to: destination)
        progress(1)
    }

    func removePassword(
        sourceURL: URL,
        destination: URL,
        password: String,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try Task.checkCancellation()
        guard !password.isEmpty,
              let document = PDFDocument(url: sourceURL),
              document.isLocked,
              document.unlock(withPassword: password),
              document.pageCount > 0
        else {
            throw PaperPathError.lockedPDF
        }
        guard sourceURL.standardizedFileURL
                != destination.standardizedFileURL
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate editable copy when removing a password."
            )
        }
        let structureService = PDFDocumentStructureService()
        let sourceStructure = try structureService
            .preservationSignature(
                in: sourceURL,
                unlockPassword: password,
                includePageLabels: true
            )
        let attachmentPayloads = try structureService
            .attachmentPayloads(
                in: sourceURL,
                unlockPassword: password
            )
        let pageLabels = try structureService.pageLabels(
            in: sourceURL,
            unlockPassword: password
        )
        let editableBase = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".unlock-base-\(UUID().uuidString).pdf"
            )
        var didComplete = false
        defer {
            try? FileManager.default.removeItem(at: editableBase)
            if !didComplete {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        progress(0.25)
        try Task.checkCancellation()
        let editableDocument = PDFDocument()
        editableDocument.documentAttributes = document.documentAttributes
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex),
                  let copiedPage = page.copy() as? PDFPage
            else {
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) could not be copied"
                )
            }
            editableDocument.insert(copiedPage, at: pageIndex)
            progress(
                0.25
                    + 0.32
                    * Double(pageIndex + 1)
                    / Double(document.pageCount)
            )
        }
        copyOutline(
            from: document,
            to: editableDocument
        )
        guard editableDocument.write(to: editableBase) else {
            throw PaperPathError.storageFailure(
                "The editable PDF copy could not be written."
            )
        }
        let editableData = try Data(
            contentsOf: editableBase,
            options: .mappedIfSafe
        )
        let restoredData = try PDFCatalogStructureAppender(
            data: editableData
        ).appending(
            attachmentPayloads: attachmentPayloads,
            pageLabels: pageLabels
        )
        try restoredData.write(to: destination, options: .atomic)
        progress(0.68)
        guard let reopened = PDFDocument(url: destination),
              !reopened.isLocked,
              !reopened.isEncrypted,
              reopened.pageCount == document.pageCount
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the editable copy still requires a password"
            )
        }
        for pageIndex in 0..<reopened.pageCount {
            try Task.checkCancellation()
            guard let page = reopened.page(at: pageIndex),
                  page.thumbnail(
                    of: CGSize(width: 180, height: 240),
                    for: .cropBox
                  ).cgImage != nil
            else {
                try? FileManager.default.removeItem(at: destination)
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) could not be reopened"
                )
            }
        }
        let outputStructure = try structureService
            .preservationSignature(
                in: destination,
                includePageLabels: true
            )
        guard outputStructure == sourceStructure else {
            throw PaperPathError.outputVerificationFailed(
                "attachments, page labels, review objects, or outline entries changed while removing the password"
            )
        }
        LocalFileSecurity.applyCompleteProtection(to: destination)
        didComplete = true
        progress(1)
    }

    func addContent(
        sourceURL: URL,
        destination: URL,
        overlays: [PDFContentOverlay],
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard !overlays.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Add text, an image, or a link before creating the copy."
            )
        }
        guard let sourceDocument = PDFDocument(url: sourceURL),
              !sourceDocument.isLocked,
              sourceDocument.pageCount > 0,
              let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              let firstPage = source.page(at: 1),
              let consumer = CGDataConsumer(url: destination as CFURL)
        else {
            throw PaperPathError.unreadablePDF
        }
        guard overlays.allSatisfy({
            $0.pageIndex >= 0 && $0.pageIndex < source.numberOfPages
        }) else {
            throw PaperPathError.invalidPage
        }
        let imageByteCount = overlays.reduce(0) { result, overlay in
            guard case .image(_, _, let data) = overlay else {
                return result
            }
            return result + data.count
        }
        guard imageByteCount <= 24 * 1_024 * 1_024 else {
            throw PaperPathError.storageFailure(
                "The added images are too large. Choose smaller images."
            )
        }

        var defaultBox = firstPage.getBoxRect(.mediaBox)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            nil
        ) else {
            throw PaperPathError.storageFailure(
                "The edited PDF context could not be created."
            )
        }
        let overlaysByPage = Dictionary(
            grouping: overlays,
            by: \.pageIndex
        )
        progress(0.02)
        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: pageNumber) else {
                continue
            }
            let mediaBox = sourcePage.getBoxRect(.mediaBox)
            let cropBox = sourcePage.getBoxRect(.cropBox)
            let pageInfo = [
                kCGPDFContextMediaBox as String: mediaBox,
                kCGPDFContextCropBox as String: cropBox
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.saveGState()
            let transform = sourcePage.getDrawingTransform(
                .mediaBox,
                rect: mediaBox,
                rotate: 0,
                preserveAspectRatio: true
            )
            context.concatenate(transform)
            context.drawPDFPage(sourcePage)
            context.restoreGState()

            for overlay in overlaysByPage[pageNumber - 1, default: []] {
                if case .image(_, let bounds, let data) = overlay {
                    try drawImage(
                        data,
                        in: pdfBounds(bounds, pageBounds: cropBox),
                        context: context
                    )
                }
            }
            context.endPDFPage()
            progress(
                0.7 * Double(pageNumber)
                    / Double(max(1, source.numberOfPages))
            )
        }
        context.closePDF()
        try Task.checkCancellation()

        guard let outputDocument = PDFDocument(url: destination),
              outputDocument.pageCount == sourceDocument.pageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the edited copy could not be reopened"
            )
        }
        for pageIndex in 0..<sourceDocument.pageCount {
            try Task.checkCancellation()
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                  let outputPage = outputDocument.page(at: pageIndex)
            else { continue }
            for annotation in sourcePage.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else {
                    continue
                }
                outputPage.addAnnotation(copy)
            }
            let pageBounds = outputPage.bounds(for: .cropBox)
            for overlay in overlaysByPage[pageIndex, default: []] {
                switch overlay {
                case .text(_, let bounds, let text, let fontSize, let color):
                    addText(
                        text,
                        bounds: pdfBounds(bounds, pageBounds: pageBounds),
                        fontSize: fontSize,
                        color: color,
                        to: outputPage
                    )
                case .link(_, let bounds, let title, let url):
                    addLink(
                        title: title,
                        url: url,
                        bounds: pdfBounds(bounds, pageBounds: pageBounds),
                        to: outputPage
                    )
                case .image:
                    break
                }
            }
            progress(
                0.7
                    + 0.22 * Double(pageIndex + 1)
                    / Double(max(1, sourceDocument.pageCount))
            )
        }
        let finalizedURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-edited.pdf")
        defer { try? FileManager.default.removeItem(at: finalizedURL) }
        guard outputDocument.write(to: finalizedURL) else {
            throw PaperPathError.storageFailure(
                "The added content could not be encoded."
            )
        }
        LocalFileSecurity.applyCompleteProtection(to: finalizedURL)
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: finalizedURL
        )
        LocalFileSecurity.applyCompleteProtection(to: destination)
        progress(1)
    }

    func imageObjects(
        sourceURL: URL,
        pageIndex: Int
    ) throws -> [PDFImageObjectSnapshot] {
        let byteCount = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard byteCount <= 64 * 1_024 * 1_024 else {
            throw PaperPathError.insufficientSelection(
                "Object-level image replacement is limited to PDFs up to 64 MB."
            )
        }
        return try PDFImageObjectInspector().snapshots(
            sourceURL: sourceURL,
            pageIndex: pageIndex
        )
    }

    func editLink(
        sourceURL: URL,
        destination: URL,
        mutation: PDFLinkMutation,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        let service = PDFMutationService()
        let sourceLinks = try service.links(in: sourceURL)
        let identity: (pageIndex: Int, annotationIndex: Int)
        switch mutation {
        case .update(let payload):
            identity = (
                payload.pageIndex,
                payload.annotationIndex
            )
        case .remove(let pageIndex, let annotationIndex):
            identity = (pageIndex, annotationIndex)
        }
        guard sourceLinks.contains(where: {
            $0.pageIndex == identity.pageIndex
                && $0.annotationIndex == identity.annotationIndex
        }) else {
            throw PaperPathError.insufficientSelection(
                "The selected link is no longer available."
            )
        }
        try Task.checkCancellation()
        do {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destination
            )
            LocalFileSecurity.applyCompleteProtection(to: destination)
            progress(0.32)
            try Task.checkCancellation()
            try service.applyLinkMutation(
                mutation,
                in: destination
            )
            progress(0.78)
            try Task.checkCancellation()

            guard let sourceDocument = PDFDocument(url: sourceURL),
                  let outputDocument = PDFDocument(url: destination),
                  sourceDocument.pageCount == outputDocument.pageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the link-edited copy could not be reopened"
                )
            }
            let outputLinks = try service.links(in: destination)
            switch mutation {
            case .remove:
                guard outputLinks.count == sourceLinks.count - 1 else {
                    throw PaperPathError.outputVerificationFailed(
                        "the selected link was not removed"
                    )
                }
            case .update(let payload):
                guard let updated = outputLinks.first(where: {
                    $0.pageIndex == payload.pageIndex
                        && $0.annotationIndex == payload.annotationIndex
                }),
                      updated.title == payload.title
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                      updated.target == payload.target,
                      Self.rectsMatch(
                          updated.normalizedBounds,
                          payload.normalizedBounds
                      )
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the link label, target, or bounds did not persist"
                    )
                }
            }
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func embedBookmarks(
        sourceURL: URL,
        destination: URL,
        pageIndices: [Int],
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let pages = Array(
            Set(
                pageIndices.filter {
                    $0 >= 0 && $0 < document.pageCount
                }
            )
        ).sorted()
        guard !pages.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Bookmark at least one page before creating an outlined copy."
            )
        }
        let root = document.outlineRoot ?? PDFOutline()
        let group = PDFOutline()
        group.label = "PaperPath Bookmarks"
        root.insertChild(group, at: root.numberOfChildren)
        for (offset, pageIndex) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PaperPathError.invalidPage
            }
            let item = PDFOutline()
            let pageLabel = page.label?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            item.label = pageLabel?.isEmpty == false
                ? pageLabel
                : "Page \(pageIndex + 1)"
            item.destination = PDFDestination(
                page: page,
                at: CGPoint(
                    x: page.bounds(for: .cropBox).minX,
                    y: page.bounds(for: .cropBox).maxY
                )
            )
            group.insertChild(item, at: group.numberOfChildren)
            progress(
                0.72 * Double(offset + 1)
                    / Double(pages.count)
            )
        }
        document.outlineRoot = root
        guard document.write(to: destination) else {
            throw PaperPathError.storageFailure(
                "The outlined PDF copy could not be written."
            )
        }
        guard let reopened = PDFDocument(url: destination),
              reopened.pageCount == document.pageCount,
              let reopenedRoot = reopened.outlineRoot,
              (0..<reopenedRoot.numberOfChildren).contains(where: {
                  guard let candidate = reopenedRoot.child(at: $0)
                  else { return false }
                  return candidate.label == "PaperPath Bookmarks"
                      && candidate.numberOfChildren == pages.count
              })
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the embedded bookmark outline did not persist"
            )
        }
        LocalFileSecurity.applyCompleteProtection(to: destination)
        progress(1)
    }

    func applyPageLabels(
        sourceURL: URL,
        destination: URL,
        rules: [PDFPageLabelRule],
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let normalizedRules = try validatedPageLabelRules(
            rules,
            pageCount: document.pageCount
        )
        let labelDictionary = pdfPageLabelDictionary(
            rules: normalizedRules
        )
        let structureService = PDFDocumentStructureService()
        let sourceStructure = try structureService
            .preservationSignature(in: sourceURL)
        progress(0.08)

        func rewrite(_ data: Data) throws -> Data {
            let structure = try PDFImageObjectDocument(data: data)
            guard let root = structure.rootCatalogObject(),
                  let rootData = structure.objectData(for: root)
            else {
                throw PaperPathError.insufficientSelection(
                    "The PDF catalog is stored in an unsupported compressed object."
                )
            }
            let replacement = try pdfCatalogObject(
                rootData,
                replacingPageLabelsWith: labelDictionary
            )
            return try structure.replacingObject(
                root,
                with: replacement
            )
        }

        let sourceData = try Data(
            contentsOf: sourceURL,
            options: .mappedIfSafe
        )
        let outputData: Data
        do {
            outputData = try rewrite(sourceData)
        } catch {
            let normalizedURL = destination
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".page-label-base-\(UUID().uuidString).pdf"
                )
            defer {
                try? FileManager.default.removeItem(at: normalizedURL)
            }
            guard document.write(to: normalizedURL),
                  let normalized = PDFDocument(url: normalizedURL),
                  normalized.pageCount == document.pageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF structure cannot be normalized for page labels."
                )
            }
            let normalizedData = try Data(
                contentsOf: normalizedURL,
                options: .mappedIfSafe
            )
            do {
                outputData = try rewrite(normalizedData)
            } catch {
                throw PaperPathError.insufficientSelection(
                    "This PDF catalog cannot be safely updated with page labels."
                )
            }
        }
        progress(0.72)
        try outputData.write(to: destination, options: .atomic)
        LocalFileSecurity.applyCompleteProtection(to: destination)

        guard let reopened = PDFDocument(url: destination),
              reopened.pageCount == document.pageCount
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the page-labeled copy could not be reopened"
            )
        }
        for index in 0..<reopened.pageCount {
            try Task.checkCancellation()
            let expected = expectedPageLabel(
                pageIndex: index,
                rules: normalizedRules
            )
            guard reopened.page(at: index)?.label == expected else {
                try? FileManager.default.removeItem(at: destination)
                throw PaperPathError.outputVerificationFailed(
                    "page \(index + 1) did not retain its expected label"
                )
            }
        }
        let outputStructure: PDFStructuralPreservationSignature
        do {
            outputStructure = try structureService
                .preservationSignature(in: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard outputStructure == sourceStructure else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "attachments, review objects, or outline entries changed while adding page labels"
            )
        }
        progress(1)
    }

    func applyFormFieldValues(
        sourceURL: URL,
        destination: URL,
        values: [String: String]
    ) throws {
        guard !values.isEmpty,
              values.count <= 64,
              values.allSatisfy({
                  !$0.key.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
                      && $0.key.count <= 160
                      && $0.value.count <= 256
                      && !$0.value.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                              && $0 != "\t"
                      })
              })
        else {
            throw PaperPathError.insufficientSelection(
                "Calculated field updates exceed the safe local limit."
            )
        }
        let sourceReport = try PDFFormInspectionService()
            .inspect(url: sourceURL)
        var normalizedValues: [String: String] = [:]
        for (name, value) in values {
            let key = normalizedPDFFieldName(name)
            if let existing = normalizedValues[key],
               existing != value {
                throw PaperPathError.insufficientSelection(
                    "Calculated field names are ambiguous."
                )
            }
            normalizedValues[key] = value
        }
        let sourceData = try Data(
            contentsOf: sourceURL,
            options: .mappedIfSafe
        )
        var structure = try PDFImageObjectDocument(
            data: sourceData
        )
        let objects = structure.allObjects()
        var targetValues: [
            Int: (generation: Int, value: String)
        ] = [:]
        var matchedNames: Set<String> = []

        for object in objects {
            guard let objectData = structure.objectData(for: object),
                  let name = pdfTopLevelString(
                      for: "T",
                      in: objectData
                  )
            else { continue }
            let normalized = normalizedPDFFieldName(name)
            guard let value = normalizedValues[normalized] else {
                continue
            }
            targetValues[object.number] = (
                object.generation,
                value
            )
            matchedNames.insert(normalized)
        }
        guard matchedNames == Set(normalizedValues.keys) else {
            throw PaperPathError.insufficientSelection(
                "One or more calculated fields are stored in an unsupported compressed object."
            )
        }

        var appearanceObjects: [Int: Int] = targetValues.reduce(
            into: [:]
        ) { result, entry in
            result[entry.key] = entry.value.generation
        }
        for object in objects {
            guard let objectData = structure.objectData(for: object),
                  let parent = pdfObjectReference(
                      following: "/Parent",
                      in: objectData
                  ),
                  targetValues[parent.number] != nil
            else { continue }
            appearanceObjects[object.number] = object.generation
        }

        let needAppearancesObject: PDFImageObjectReference?
        if let root = structure.rootCatalogObject() {
            needAppearancesObject = structure.referencedObject(
                following: "/AcroForm",
                in: root
            )
        } else {
            needAppearancesObject = nil
        }
        guard let needAppearancesObject else {
            throw PaperPathError.insufficientSelection(
                "This PDF stores AcroForm inline and cannot refresh appearances safely."
            )
        }
        let objectNumbers = Set(targetValues.keys)
            .union(appearanceObjects.keys)
            .union([needAppearancesObject.number])
            .sorted()

        var outputData = sourceData
        for number in objectNumbers {
            try Task.checkCancellation()
            structure = try PDFImageObjectDocument(data: outputData)
            let generation = targetValues[number]?.generation
                ?? appearanceObjects[number]
                ?? needAppearancesObject.generation
            guard let object = structure.object(
                number: number,
                generation: generation
            ),
                  let objectData = structure.objectData(for: object)
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a form object moved during the structural rewrite"
                )
            }
            var replacement = objectData
            if let target = targetValues[number] {
                replacement = try pdfObject(
                    replacement,
                    setting: "V",
                    to: Data(
                        pdfUTF16HexString(target.value).utf8
                    )
                )
            }
            if appearanceObjects[number] != nil {
                replacement = try pdfObject(
                    replacement,
                    removing: "AP"
                )
            }
            if number == needAppearancesObject.number {
                replacement = try pdfObject(
                    replacement,
                    setting: "NeedAppearances",
                    to: Data("true".utf8)
                )
            }
            if replacement != objectData {
                outputData = try structure.replacingObject(
                    object,
                    with: replacement
                )
            }
        }

        try outputData.write(to: destination, options: .atomic)
        LocalFileSecurity.applyCompleteProtection(to: destination)
        let outputReport: PDFFormInspectionReport
        do {
            outputReport = try PDFFormInspectionService()
                .inspect(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let sourceLogic = formLogicSignature(sourceReport)
        let outputLogic = formLogicSignature(outputReport)
        let valuesPersisted = normalizedValues.allSatisfy {
            expected in
            outputReport.fields.contains {
                normalizedPDFFieldName($0.name) == expected.key
                    && $0.value == expected.value
            }
        }
        guard outputReport.fields.count == sourceReport.fields.count,
              sourceLogic == outputLogic,
              valuesPersisted
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "calculated values or standard form scripts did not survive the structural rewrite"
            )
        }
    }

    private func formLogicSignature(
        _ report: PDFFormInspectionReport
    ) -> [String] {
        report.automationFields.map {
            [
                normalizedPDFFieldName($0.fieldName),
                String(describing: $0.calculation),
                String(describing: $0.format),
                String(describing: $0.rangeValidation),
                String($0.unsupportedActionCount)
            ].joined(separator: "|")
        }.sorted()
    }

    private func normalizedPDFFieldName(
        _ value: String
    ) -> String {
        value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func copyOutline(
        from source: PDFDocument,
        to destination: PDFDocument
    ) {
        guard let sourceRoot = source.outlineRoot else { return }
        let destinationRoot = PDFOutline()

        func copyItem(
            _ sourceItem: PDFOutline,
            depth: Int
        ) -> PDFOutline? {
            guard depth < 24 else { return nil }
            let item = PDFOutline()
            item.label = sourceItem.label
            if let sourcePage = sourceItem.destination?.page {
                let pageIndex = source.index(for: sourcePage)
                if pageIndex != NSNotFound,
                   let destinationPage = destination.page(
                       at: pageIndex
                   ) {
                    item.destination = PDFDestination(
                        page: destinationPage,
                        at: sourceItem.destination?.point ?? .zero
                    )
                }
            }
            for index in 0..<sourceItem.numberOfChildren {
                guard let child = sourceItem.child(at: index),
                      let copied = copyItem(
                          child,
                          depth: depth + 1
                      )
                else { continue }
                item.insertChild(
                    copied,
                    at: item.numberOfChildren
                )
            }
            return item
        }

        for index in 0..<sourceRoot.numberOfChildren {
            guard let child = sourceRoot.child(at: index),
                  let copied = copyItem(child, depth: 0)
            else { continue }
            destinationRoot.insertChild(
                copied,
                at: destinationRoot.numberOfChildren
            )
        }
        if destinationRoot.numberOfChildren > 0 {
            destination.outlineRoot = destinationRoot
        }
    }

    private func validatedPageLabelRules(
        _ rules: [PDFPageLabelRule],
        pageCount: Int
    ) throws -> [PDFPageLabelRule] {
        let sorted = rules.sorted {
            $0.startPageIndex < $1.startPageIndex
        }
        guard !sorted.isEmpty,
              sorted.count <= 16,
              sorted[0].startPageIndex == 0,
              Set(sorted.map(\.startPageIndex)).count == sorted.count,
              sorted.allSatisfy({
                  $0.startPageIndex >= 0
                      && $0.startPageIndex < pageCount
                      && (1...999_999).contains($0.startNumber)
                      && $0.prefix.count <= 40
                      && !$0.prefix.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      })
                      && (
                          $0.style != .prefixOnly
                              || !$0.prefix.isEmpty
                      )
              })
        else {
            throw PaperPathError.insufficientSelection(
                "Use up to 16 unique label ranges, beginning on page 1."
            )
        }
        for (index, rule) in sorted.enumerated() {
            let nextStart = index + 1 < sorted.count
                ? sorted[index + 1].startPageIndex
                : pageCount
            let largestNumber = rule.startNumber
                + max(0, nextStart - rule.startPageIndex - 1)
            if (
                rule.style == .uppercaseRoman
                    || rule.style == .lowercaseRoman
            ),
               largestNumber > 3_999 {
                throw PaperPathError.insufficientSelection(
                    "Roman page labels support values through 3,999."
                )
            }
        }
        return sorted
    }

    private func pdfPageLabelDictionary(
        rules: [PDFPageLabelRule]
    ) -> Data {
        let values = rules.map { rule in
            var entries: [String] = []
            if let style = rule.style.pdfName {
                entries.append("/S /\(style)")
                entries.append("/St \(rule.startNumber)")
            }
            if !rule.prefix.isEmpty {
                entries.append(
                    "/P \(pdfUTF16HexString(rule.prefix))"
                )
            }
            return "\(rule.startPageIndex) << \(entries.joined(separator: " ")) >>"
        }
        return Data(
            "<< /Nums [\(values.joined(separator: " "))] >>".utf8
        )
    }

    private func expectedPageLabel(
        pageIndex: Int,
        rules: [PDFPageLabelRule]
    ) -> String {
        let rule = rules.last(where: {
            $0.startPageIndex <= pageIndex
        }) ?? rules[0]
        return rule.label(for: pageIndex)
    }

    func replaceImageObject(
        sourceURL: URL,
        destination: URL,
        snapshot: PDFImageObjectSnapshot,
        replacementData: Data,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard snapshot.isSafelyReplaceable,
              replacementData.count <= 12 * 1_024 * 1_024,
              let replacementImage = UIImage(data: replacementData)
        else {
            throw PaperPathError.insufficientSelection(
                "This image object cannot be replaced safely."
            )
        }
        let sourceByteCount = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceByteCount <= 64 * 1_024 * 1_024 else {
            throw PaperPathError.insufficientSelection(
                "Object-level image replacement is limited to PDFs up to 64 MB."
            )
        }
        progress(0.08)
        let sourceData = try Data(
            contentsOf: sourceURL,
            options: .mappedIfSafe
        )
        let sourceParser = try PDFImageObjectDocument(data: sourceData)
        let sourceObject: PDFImageObjectReference?
        switch snapshot.storage {
        case .jpeg:
            sourceObject = sourceParser.imageObject(
                matching: snapshot.sourceStreamData
            )
        case .flate, .flateWithSoftMask:
            sourceObject = sourceParser.imageObject(
                matchingDecodedStream: snapshot.sourceStreamData
            )
        }
        guard let sourceObject,
              sourceObject.number == snapshot.objectNumber,
              sourceObject.generation == snapshot.generation,
              PDFImageObjectInspector.digest(snapshot.jpegData)
                == snapshot.sourceDigest
        else {
            throw PaperPathError.outputVerificationFailed(
                "the selected image object changed before export"
            )
        }
        let outputData: Data
        let expectedPixelWidth: Int
        let expectedPixelHeight: Int
        switch snapshot.storage {
        case .jpeg:
            let normalized = try pdfOpaqueImage(replacementImage)
            guard let jpegData = normalized.jpegData(
                compressionQuality: 0.9
            ),
                  let cgImage = normalized.cgImage
            else {
                throw PaperPathError.unreadableImage
            }
            expectedPixelWidth = cgImage.width
            expectedPixelHeight = cgImage.height
            outputData = try sourceParser.replacingImageObject(
                sourceObject,
                jpegData: jpegData,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height
            )
        case .flate:
            let samples = try pdfRGBASamples(
                replacementImage,
                preserveAlpha: false
            )
            expectedPixelWidth = samples.width
            expectedPixelHeight = samples.height
            let replacement = try pdfFlateImageObject(
                reference: sourceObject,
                width: samples.width,
                height: samples.height,
                rgbData: samples.rgbData,
                softMask: nil
            )
            outputData = try sourceParser.replacingObject(
                sourceObject,
                with: replacement
            )
        case .flateWithSoftMask:
            guard let maskNumber = snapshot.softMaskObjectNumber,
                  let maskGeneration = snapshot.softMaskGeneration,
                  let sourceMask = sourceParser.object(
                      number: maskNumber,
                      generation: maskGeneration
                  ),
                  sourceParser.referencedObject(
                      following: "/SMask",
                      in: sourceObject
                  )?.number == maskNumber
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the selected image transparency mask changed before export"
                )
            }
            let samples = try pdfRGBASamples(
                replacementImage,
                preserveAlpha: true
            )
            expectedPixelWidth = samples.width
            expectedPixelHeight = samples.height
            let mainReplacement = try pdfFlateImageObject(
                reference: sourceObject,
                width: samples.width,
                height: samples.height,
                rgbData: samples.rgbData,
                softMask: sourceMask
            )
            let mainOutput = try sourceParser.replacingObject(
                sourceObject,
                with: mainReplacement
            )
            let secondParser = try PDFImageObjectDocument(
                data: mainOutput
            )
            guard let shiftedMask = secondParser.object(
                number: maskNumber,
                generation: maskGeneration
            ) else {
                throw PaperPathError.outputVerificationFailed(
                    "the transparency mask could not be relocated"
                )
            }
            let maskReplacement = try pdfFlateMaskObject(
                reference: shiftedMask,
                width: samples.width,
                height: samples.height,
                alphaData: samples.alphaData
            )
            outputData = try secondParser.replacingObject(
                shiftedMask,
                with: maskReplacement
            )
        }
        progress(0.62)
        try outputData.write(to: destination, options: .atomic)
        LocalFileSecurity.applyCompleteProtection(to: destination)

        let removedOriginalJPEG = snapshot.storage != .jpeg
            || outputData.range(of: snapshot.sourceStreamData) == nil
        guard removedOriginalJPEG,
              let sourceDocument = PDFDocument(url: sourceURL),
              let outputDocument = PDFDocument(url: destination),
              sourceDocument.pageCount == outputDocument.pageCount,
              let outputPage = outputDocument.page(
                  at: snapshot.pageIndex
              ),
              outputPage.thumbnail(
                  of: CGSize(width: 360, height: 480),
                  for: .cropBox
              ).cgImage != nil
        else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the replacement image could not be reopened and rendered"
            )
        }
        progress(0.82)
        let outputSnapshots = try PDFImageObjectInspector().snapshots(
            sourceURL: destination,
            pageIndex: snapshot.pageIndex
        )
        guard outputSnapshots.contains(where: {
            $0.objectNumber == snapshot.objectNumber
                && $0.generation == snapshot.generation
                && $0.sourceDigest != snapshot.sourceDigest
                && $0.usageCount == snapshot.usageCount
                && $0.pixelWidth == expectedPixelWidth
                && $0.pixelHeight == expectedPixelHeight
                && $0.storage == snapshot.storage
        }) else {
            try? FileManager.default.removeItem(at: destination)
            throw PaperPathError.outputVerificationFailed(
                "the rewritten image object did not pass structural verification"
            )
        }
        progress(1)
    }

    func assessTextReplacement(
        sourceURL: URL,
        selection: PDFTextSelectionSnapshot,
        replacement: String,
        fontStyle: PDFTextReplacementFontStyle,
        alignment: PDFTextReplacementAlignment
    ) throws -> PDFTextReplacementAssessment {
        try Task.checkCancellation()
        let trimmed = replacement.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }
        let pageIndices = selection.pageIndices
        let pages = Dictionary(
            pageIndices.compactMap {
                index -> (Int, PDFPage)? in
                guard let page = document.page(at: index) else {
                    return nil
                }
                return (index, page)
            },
            uniquingKeysWith: { current, _ in current }
        )
        guard pages.count == pageIndices.count else {
            throw PaperPathError.invalidPage
        }
        guard zip(pageIndices, pageIndices.dropFirst()).allSatisfy({
            pair in pair.1 == pair.0 + 1
        }) else {
            return blockedTextReplacement(
                "Cross-page text flow must use neighboring pages without gaps.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard !trimmed.isEmpty else {
            return blockedTextReplacement(
                "Enter replacement text to check the layout.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard trimmed != selection.originalText else {
            return blockedTextReplacement(
                "The replacement is identical to the selected text.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard selection.pageRotation % 360 == 0,
              pages.values.allSatisfy({ $0.rotation % 360 == 0 })
        else {
            return blockedTextReplacement(
                "Rotate every selected page upright before replacing text.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard !selection.hasMixedFonts else {
            return blockedTextReplacement(
                "This selection mixes font families. Select one paragraph style at a time.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard textFlowRegionsAreOrdered(selection.flowRegions) else {
            return blockedTextReplacement(
                "The selected text boxes do not have a stable reading order.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard selection.lineCount <= 96,
              selection.flowRegions.count <= 16,
              pageIndices.count <= 4,
              selection.originalText.count <= 16_000,
              trimmed.count <= 16_000
        else {
            return blockedTextReplacement(
                "Reflow no more than 96 lines, sixteen text boxes, four pages, or 16,000 characters at a time.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        let targetBounds = selection.flowRegions.compactMap {
            region -> CGRect? in
            guard let page = pages[region.pageIndex] else { return nil }
            return textFlowBounds(
                region,
                pageBounds: page.bounds(for: .cropBox)
            )
        }
        guard !targetBounds.isEmpty,
              targetBounds.count == selection.flowRegions.count,
              targetBounds.allSatisfy({
                  $0.width > 8 && $0.height > 5
              })
        else {
            return blockedTextReplacement(
                "One of the selected text boxes is too small to reflow safely.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        let regionsByPage = Dictionary(
            grouping: Array(selection.flowRegions.enumerated()),
            by: { $0.element.pageIndex }
        )
        guard regionsByPage.allSatisfy({ pageIndex, entries in
            guard let page = pages[pageIndex] else { return false }
            return selectedTextRanges(
                in: page,
                snapshot: selection,
                regions: entries.map(\.element)
            ) != nil
        }) else {
            return blockedTextReplacement(
                "The selected text cannot be anchored safely. Select complete text lines again.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard !regionsByPage.contains(where: { pageIndex, entries in
            guard let page = pages[pageIndex] else { return true }
            let bounds = entries.map { targetBounds[$0.offset] }
            return page.annotations.contains {
                annotation in
                bounds.contains {
                    annotation.bounds.intersects(
                        $0.insetBy(dx: -2, dy: -2)
                    )
                }
            }
        }) else {
            return blockedTextReplacement(
                "Remove or flatten annotations over this text first.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }

        let layoutAttempt = try fittingReplacementLayout(
            text: trimmed,
            selection: selection,
            bounds: targetBounds,
            style: fontStyle,
            alignment: alignment
        )
        guard let layout = layoutAttempt.layout else {
            let remaining = max(
                0,
                trimmed.utf16.count
                    - layoutAttempt.consumedUTF16Length
            )
            let detail: String
            if layoutAttempt.splitWordAtRegionBoundary {
                detail = "A word would split between selected text boxes. Widen a box or shorten that word."
            } else if remaining > 0 {
                detail = "The selected flow is short by \(remaining) characters at the safe minimum of \(String(format: "%.1f", Double(layoutAttempt.minimumFontSize))) pt. Shorten the text or select more neighboring lines."
            } else {
                detail = "The text cannot flow through the selected boxes without clipping."
            }
            return blockedTextReplacement(
                detail,
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        try Task.checkCancellation()
        guard let backgrounds = try sampledTextBackgrounds(
            document: document,
            regions: selection.flowRegions
        ),
              backgrounds.count == targetBounds.count,
              let background = backgrounds.first
        else {
            return blockedTextReplacement(
                "One of the text boxes is on a textured or changing background.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        let sizeChanged = abs(
            layout.font.pointSize - selection.fontSize
        ) >= 0.25
        let layoutDetail = sizeChanged
            ? "Reflowed to \(layout.lineCount) lines at \(String(format: "%.1f", Double(layout.font.pointSize))) pt."
            : "Reflowed to \(layout.lineCount) lines at the original size."
        let usedRegionCount = (
            layout.regionTexts.lastIndex {
                !$0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            } ?? -1
        ) + 1
        let clearedRegionCount = max(
            0,
            targetBounds.count - usedRegionCount
        )
        let clearedDetail = clearedRegionCount > 0
            ? " \(clearedRegionCount) trailing selected text box\(clearedRegionCount == 1 ? "" : "es") will be cleared."
            : ""
        return PDFTextReplacementAssessment(
            status: .ready,
            title: targetBounds.count > 1
                ? "Text flow ready"
                : (
                    selection.lineCount > 4
                        ? "Paragraph ready to reflow"
                        : "Ready to replace"
                ),
            detail: selection.isCrossPage
                ? "\(layoutDetail) Flows through \(usedRegionCount) of \(targetBounds.count) text boxes across \(pageIndices.count) pages.\(clearedDetail)"
                : targetBounds.count > 1
                    ? "\(layoutDetail) Flows through \(usedRegionCount) of \(targetBounds.count) text boxes on page \(selection.pageIndex + 1).\(clearedDetail)"
                    : "\(layoutDetail) Only page \(selection.pageIndex + 1) will be rebuilt.",
            resolvedFontName: layout.font.fontName,
            resolvedFontSize: layout.font.pointSize,
            resolvedLineSpacing: layout.lineSpacing,
            reflowedLineCount: layout.lineCount,
            backgroundColor: background,
            regionBackgroundColors: backgrounds,
            flowRegionTexts: layout.regionTexts,
            fontStyle: fontStyle,
            alignment: alignment
        )
    }

    func replaceText(
        sourceURL: URL,
        destination: URL,
        selection: PDFTextSelectionSnapshot,
        replacement: String,
        assessment: PDFTextReplacementAssessment,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try Task.checkCancellation()
        var didComplete = false
        defer {
            if !didComplete {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        guard assessment.isReady,
              let sourceDocument = PDFDocument(url: sourceURL),
              !sourceDocument.isLocked,
              let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              let firstPage = source.page(at: 1)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the selected text is no longer safe to replace"
            )
        }
        let verifiedAssessment = try assessTextReplacement(
            sourceURL: sourceURL,
            selection: selection,
            replacement: replacement,
            fontStyle: assessment.fontStyle,
            alignment: assessment.alignment
        )
        guard textReplacementAssessmentsMatch(
            assessment,
            verifiedAssessment
        ) else {
            throw PaperPathError.outputVerificationFailed(
                "the text or layout changed after preview; check the replacement again"
            )
        }
        try Task.checkCancellation()
        guard let consumer = CGDataConsumer(
            url: destination as CFURL
        ) else {
            throw PaperPathError.storageFailure(
                "The replacement PDF context could not be created."
            )
        }
        let indexedRegions = Array(selection.flowRegions.enumerated())
        let regionsByPage = Dictionary(
            grouping: indexedRegions,
            by: { $0.element.pageIndex }
        )
        let selectedPageIndices = Set(regionsByPage.keys)
        guard !selectedPageIndices.isEmpty,
              indexedRegions.count
                == verifiedAssessment.regionBackgroundColors.count,
              indexedRegions.count
                == verifiedAssessment.flowRegionTexts.count
        else {
            throw PaperPathError.outputVerificationFailed(
                "the text flow regions changed before export"
            )
        }

        var selectedRanges: [Int: [NSRange]] = [:]
        var originalSourceTextByPage: [Int: String] = [:]
        var verifiedNewChunkCount = 0
        for (pageIndex, entries) in regionsByPage {
            try Task.checkCancellation()
            guard let page = sourceDocument.page(at: pageIndex),
                  let pageSelectedRanges = selectedTextRanges(
                      in: page,
                      snapshot: selection,
                      regions: entries.map(\.element)
                  )
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the selected source text could not be located again"
                )
            }
            selectedRanges[pageIndex] = pageSelectedRanges
            originalSourceTextByPage[pageIndex] = page.string ?? ""
        }

        var defaultBox = firstPage.getBoxRect(.mediaBox)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            nil
        ) else {
            throw PaperPathError.storageFailure(
                "The replacement PDF context could not be created."
            )
        }
        progress(0.03)
        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: pageNumber) else {
                continue
            }
            let mediaBox = sourcePage.getBoxRect(.mediaBox)
            let cropBox = sourcePage.getBoxRect(.cropBox)
            let pageInfo = [
                kCGPDFContextMediaBox as String: mediaBox,
                kCGPDFContextCropBox as String: cropBox
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            let pageIndex = pageNumber - 1
            if selectedPageIndices.contains(pageIndex) {
                guard let selectedPage = sourceDocument.page(at: pageIndex),
                      let pageSelectedRanges = selectedRanges[pageIndex],
                      let renderingPage = selectedPage.copy() as? PDFPage
                else {
                    context.endPDFPage()
                    context.closePDF()
                    throw PaperPathError.outputVerificationFailed(
                        "the edited page could not be copied"
                    )
                }
                for annotation in renderingPage.annotations {
                    renderingPage.removeAnnotation(annotation)
                }
                guard let image = renderingPage.thumbnail(
                    of: fittedSize(
                        cropBox.size,
                        longestEdge: 3_200
                    ),
                    for: .cropBox
                ).cgImage else {
                    context.endPDFPage()
                    context.closePDF()
                    throw PaperPathError.outputVerificationFailed(
                        "the edited page could not be rendered"
                    )
                }
                context.draw(image, in: cropBox)
                let entries = regionsByPage[pageIndex, default: []]
                let textBounds = entries.map {
                    textFlowBounds(
                        $0.element,
                        pageBounds: cropBox
                    )
                }
                for (entry, bounds) in zip(entries, textBounds) {
                    let background = verifiedAssessment
                        .regionBackgroundColors[entry.offset]
                    context.setFillColor(
                        red: background.red,
                        green: background.green,
                        blue: background.blue,
                        alpha: 1
                    )
                    context.fill(
                        bounds
                            .insetBy(dx: -1.5, dy: -1)
                            .intersection(cropBox)
                    )
                }
                drawReplacementTextChunks(
                    entries.map {
                        verifiedAssessment.flowRegionTexts[$0.offset]
                    },
                    bounds: textBounds,
                    fontName: verifiedAssessment.resolvedFontName,
                    fontSize: verifiedAssessment.resolvedFontSize,
                    lineSpacing: verifiedAssessment.resolvedLineSpacing,
                    alignment: verifiedAssessment.alignment,
                    color: selection.color,
                    context: context
                )
                drawSearchableTextOutsideSelection(
                    page: selectedPage,
                    selectedRanges: pageSelectedRanges,
                    context: context
                )
            } else {
                context.saveGState()
                let transform = sourcePage.getDrawingTransform(
                    .mediaBox,
                    rect: mediaBox,
                    rotate: 0,
                    preserveAspectRatio: true
                )
                context.concatenate(transform)
                context.drawPDFPage(sourcePage)
                context.restoreGState()
            }
            context.endPDFPage()
            progress(
                0.68 * Double(pageNumber)
                    / Double(max(1, source.numberOfPages))
            )
        }
        context.closePDF()
        try Task.checkCancellation()

        guard let output = PDFDocument(url: destination),
              output.pageCount == sourceDocument.pageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the replacement copy could not be reopened"
            )
        }
        for pageIndex in 0..<sourceDocument.pageCount {
            try Task.checkCancellation()
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                  let outputPage = output.page(at: pageIndex)
            else { continue }
            for annotation in sourcePage.annotations {
                if let copy = annotation.copy() as? PDFAnnotation {
                    outputPage.addAnnotation(copy)
                }
            }
        }
        let finalizedURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-replace.pdf")
        defer { try? FileManager.default.removeItem(at: finalizedURL) }
        try Task.checkCancellation()
        guard output.write(to: finalizedURL) else {
            throw PaperPathError.storageFailure(
                "The replacement PDF could not be encoded."
            )
        }
        try Task.checkCancellation()
        LocalFileSecurity.applyCompleteProtection(to: finalizedURL)
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: finalizedURL
        )
        LocalFileSecurity.applyCompleteProtection(to: destination)
        try Task.checkCancellation()
        progress(0.94)

        guard let reopened = PDFDocument(url: destination) else {
            throw PaperPathError.outputVerificationFailed(
                "the replacement pages could not be inspected"
            )
        }
        for (pageIndex, entries) in regionsByPage {
            try Task.checkCancellation()
            guard let outputText = reopened.page(at: pageIndex)?.string,
                  let sourceText = originalSourceTextByPage[pageIndex]
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a replacement page could not be inspected"
                )
            }
            let oldChunks = entries
                .map(\.element.originalText)
                .map(normalizedVerificationText)
                .filter { $0.count >= 3 }
            let newChunks = entries
                .map { verifiedAssessment.flowRegionTexts[$0.offset] }
                .map(normalizedVerificationText)
                .filter { $0.count >= 3 }
            let normalizedOutput = normalizedVerificationText(outputText)
            let normalizedSource = normalizedVerificationText(sourceText)
            let oldTextRemoved = !oldChunks.isEmpty
                && oldChunks.allSatisfy { chunk in
                    occurrenceCount(of: chunk, in: normalizedOutput)
                        <= max(
                            0,
                            occurrenceCount(
                                of: chunk,
                                in: normalizedSource
                            ) - 1
                        )
                }
            let newTextAdded = !newChunks.isEmpty
                && newChunks.allSatisfy { chunk in
                    occurrenceCount(of: chunk, in: normalizedOutput)
                        >= occurrenceCount(
                            of: chunk,
                            in: normalizedSource
                        ) + 1
                }
            verifiedNewChunkCount += newTextAdded
                ? newChunks.count
                : 0
            guard oldTextRemoved,
                  newChunks.isEmpty || newTextAdded
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the old and new searchable text could not be verified on page \(pageIndex + 1)"
                )
            }
        }
        guard verifiedNewChunkCount > 0 else {
            throw PaperPathError.outputVerificationFailed(
                "the replacement text could not be verified"
            )
        }
        try Task.checkCancellation()
        didComplete = true
        progress(1)
    }

    func exportText(
        sourceURL: URL,
        destination: URL,
        textIndex: DocumentTextIndex? = nil,
        title: String,
        format: PDFTextExportFormat,
        profile: DocumentProfile? = nil,
        byteProgress: @escaping PDFByteProgressHandler = { _ in },
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws -> PDFOfficeRuntimeEvidence? {
        if format == .wordDocument {
            do {
                let evidence = try DOCXExportService().export(
                    sourceURL: sourceURL,
                    destination: destination,
                    textIndex: textIndex,
                    title: title,
                    profile: profile,
                    byteProgress: byteProgress,
                    progress: progress
                )
                LocalFileSecurity.applyCompleteProtection(to: destination)
                return evidence
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PaperPathError {
                throw error
            } catch {
                throw PaperPathError.storageFailure(
                    "The Word document export could not be written."
                )
            }
        }
        if format == .excelWorkbook {
            do {
                let evidence = try XLSXExportService().export(
                    sourceURL: sourceURL,
                    destination: destination,
                    textIndex: textIndex,
                    title: title,
                    profile: profile,
                    byteProgress: byteProgress,
                    progress: progress
                )
                LocalFileSecurity.applyCompleteProtection(to: destination)
                return evidence
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PaperPathError {
                throw error
            } catch {
                throw PaperPathError.storageFailure(
                    "The Excel workbook export could not be written."
                )
            }
        }
        if format == .powerPointPresentation {
            do {
                let evidence = try PPTXExportService().export(
                    sourceURL: sourceURL,
                    destination: destination,
                    textIndex: textIndex,
                    title: title,
                    profile: profile,
                    byteProgress: byteProgress,
                    progress: progress
                )
                LocalFileSecurity.applyCompleteProtection(to: destination)
                return evidence
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PaperPathError {
                throw error
            } catch {
                throw PaperPathError.storageFailure(
                    "The PowerPoint presentation export could not be written."
                )
            }
        }
        let pages = try textPages(
            sourceURL: sourceURL,
            textIndex: textIndex,
            progress: { progress($0 * 0.72) }
        )
        guard !pages.isEmpty else {
            throw PaperPathError.missingRecognizedText
        }
        do {
            let data: Data
            switch format {
            case .wordDocument, .excelWorkbook,
                 .powerPointPresentation:
                return nil
            case .plainText:
                let value = pages.map {
                    "Page \($0.pageIndex + 1)\n\($0.text)"
                }.joined(separator: "\n\n")
                data = Data(value.utf8)
            case .markdown:
                let escapedTitle = title.replacingOccurrences(
                    of: "\n",
                    with: " "
                )
                let value = (
                    ["# \(escapedTitle)"]
                        + pages.map {
                            "## Page \($0.pageIndex + 1)\n\n\($0.text)"
                        }
                ).joined(separator: "\n\n")
                data = Data(value.utf8)
            case .richText:
                data = try richTextData(title: title, pages: pages)
            }
            progress(0.86)
            byteProgress(
                PDFByteProgressUpdate(
                    stage: .packaging,
                    processedBytes: 0,
                    totalBytes: Int64(data.count)
                )
            )
            try data.write(to: destination, options: .atomic)
            byteProgress(
                PDFByteProgressUpdate(
                    stage: .packaging,
                    processedBytes: Int64(data.count),
                    totalBytes: Int64(data.count)
                )
            )
            LocalFileSecurity.applyCompleteProtection(to: destination)
            progress(1)
        } catch {
            throw PaperPathError.storageFailure(
                "The \(format.title.lowercased()) export could not be written."
            )
        }
        return nil
    }

    func exportPageImages(
        sourceURL: URL,
        directory: URL,
        preset: PDFPageImageExportPreset,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws -> [URL] {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        LocalFileSecurity.applyCompleteProtection(to: directory)
        var urls: [URL] = []
        urls.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let url: URL? = try autoreleasepool {
                guard let page = document.page(at: index) else {
                    return nil
                }
                let bounds = page.bounds(for: .cropBox)
                let longestEdge: CGFloat = preset == .jpegCompact
                    ? 1_600
                    : 2_400
                let size = fittedSize(
                    bounds.size,
                    longestEdge: longestEdge
                )
                let image = page.thumbnail(of: size, for: .cropBox)
                let fileExtension: String
                let data: Data?
                switch preset {
                case .png:
                    fileExtension = "png"
                    data = image.pngData()
                case .jpegHigh:
                    fileExtension = "jpg"
                    data = image.jpegData(compressionQuality: 0.9)
                case .jpegCompact:
                    fileExtension = "jpg"
                    data = image.jpegData(compressionQuality: 0.68)
                }
                guard let data else { return nil }
                let url = directory.appendingPathComponent(
                    String(
                        format: "Page-%03d.%@",
                        index + 1,
                        fileExtension
                    )
                )
                try data.write(to: url, options: .atomic)
                LocalFileSecurity.applyCompleteProtection(to: url)
                return url
            }
            if let url {
                urls.append(url)
            }
            progress(
                Double(index + 1)
                    / Double(max(1, document.pageCount))
            )
        }
        return urls
    }

    func exportEmbeddedImages(
        sourceURL: URL,
        directory: URL,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws -> PDFEmbeddedImageExportResult {
        let fileManager = FileManager.default
        let sourceByteCount = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard sourceByteCount <= 512 * 1_024 * 1_024 else {
            throw PaperPathError.fileTooLarge
        }
        guard let pdfDocument = PDFDocument(url: sourceURL),
              !pdfDocument.isLocked,
              pdfDocument.pageCount > 0,
              pdfDocument.pageCount <= 1_000,
              let document = CGPDFDocument(sourceURL as CFURL),
              document.numberOfPages == pdfDocument.pageCount
        else {
            throw PaperPathError.unreadablePDF
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            LocalFileSecurity.applyCompleteProtection(
                to: directory,
                fileManager: fileManager
            )

            let inspector = PDFImageObjectInspector()
            var exportedURLs: [URL] = []
            var exportedDigests: Set<String> = []
            var exportedByteCount = 0
            var occurrenceCount = 0
            var unsupportedOccurrenceCount = 0
            var originalStreamFileCount = 0
            var losslessPNGFileCount = 0
            exportedURLs.reserveCapacity(
                min(pdfDocument.pageCount * 2, 64)
            )

            for pageIndex in 0..<document.numberOfPages {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex + 1) else {
                    continue
                }
                let scan = autoreleasepool {
                    inspector.scanReport(
                        page: page,
                        pageIndex: pageIndex
                    )
                }
                occurrenceCount += scan.encounteredImageCount
                unsupportedOccurrenceCount +=
                    scan.unsupportedImageCount
                    + scan.omittedImageCount

                for (imageIndex, use) in scan.uses.enumerated() {
                    try Task.checkCancellation()
                    let digest = PDFImageObjectInspector.digest(
                        use.data
                    )
                    guard !exportedDigests.contains(digest) else {
                        continue
                    }
                    guard exportedURLs.count < 256,
                          exportedByteCount + use.data.count
                            <= 192 * 1_024 * 1_024
                    else {
                        throw PaperPathError.insufficientSelection(
                            "Embedded-image export supports up to 256 unique images or 192 MB per PDF."
                        )
                    }
                    guard let imageSource = CGImageSourceCreateWithData(
                        use.data as CFData,
                        nil
                    ),
                          CGImageSourceGetCount(imageSource) == 1,
                          let properties = CGImageSourceCopyPropertiesAtIndex(
                              imageSource,
                              0,
                              nil
                          ) as? [CFString: Any],
                          let width = (
                              properties[
                                  kCGImagePropertyPixelWidth
                              ] as? NSNumber
                          )?.intValue,
                          let height = (
                              properties[
                                  kCGImagePropertyPixelHeight
                              ] as? NSNumber
                          )?.intValue,
                          width == use.pixelWidth,
                          height == use.pixelHeight
                    else {
                        unsupportedOccurrenceCount += 1
                        continue
                    }

                    let fileName = String(
                        format: "Embedded-p%04d-%03d-%@.%@",
                        pageIndex + 1,
                        imageIndex + 1,
                        String(digest.prefix(10)),
                        use.kind.fileExtension
                    )
                    let outputURL = directory
                        .appendingPathComponent(fileName)
                    try use.data.write(
                        to: outputURL,
                        options: .atomic
                    )
                    LocalFileSecurity.applyCompleteProtection(
                        to: outputURL,
                        fileManager: fileManager
                    )
                    let verifiedData = try Data(
                        contentsOf: outputURL,
                        options: .mappedIfSafe
                    )
                    guard verifiedData == use.data,
                          PDFImageObjectInspector.digest(
                              verifiedData
                          ) == digest
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "an exported image did not match its original PDF stream"
                        )
                    }
                    exportedDigests.insert(digest)
                    exportedByteCount += verifiedData.count
                    exportedURLs.append(outputURL)
                    if use.kind.isOriginalStream {
                        originalStreamFileCount += 1
                    } else {
                        losslessPNGFileCount += 1
                    }
                }
                progress(
                    Double(pageIndex + 1)
                        / Double(max(1, document.numberOfPages))
                )
            }

            guard !exportedURLs.isEmpty else {
                let message = occurrenceCount == 0
                    ? "No embedded image objects were found in this PDF."
                    : "This PDF uses image encodings or color spaces that cannot be exported safely."
                throw PaperPathError.insufficientSelection(message)
            }
            return PDFEmbeddedImageExportResult(
                urls: exportedURLs,
                occurrenceCount: occurrenceCount,
                unsupportedOccurrenceCount: unsupportedOccurrenceCount,
                originalStreamFileCount: originalStreamFileCount,
                losslessPNGFileCount: losslessPNGFileCount
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func textPages(
        sourceURL: URL,
        textIndex: DocumentTextIndex?,
        progress: @escaping PDFProgressHandler
    ) throws -> [(pageIndex: Int, text: String)] {
        let indexed = (textIndex?.pages ?? []).reduce(
            into: [Int: String]()
        ) { result, page in
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
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        var pages: [(pageIndex: Int, text: String)] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = indexed[index]
                ?? document.page(at: index)?.string
                ?? ""
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                pages.append((index, trimmed))
            }
            progress(
                Double(index + 1)
                    / Double(max(1, document.pageCount))
            )
        }
        return pages
    }

    private func richTextData(
        title: String,
        pages: [(pageIndex: Int, text: String)]
    ) throws -> Data {
        let output = NSMutableAttributedString()
        output.append(
            NSAttributedString(
                string: "\(title)\n",
                attributes: [
                    .font: UIFont.preferredFont(
                        forTextStyle: .largeTitle
                    ),
                    .foregroundColor: UIColor.label
                ]
            )
        )
        output.append(
            NSAttributedString(
                string: "Exported locally by PaperPath\n\n",
                attributes: [
                    .font: UIFont.preferredFont(
                        forTextStyle: .caption1
                    ),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        )
        for (position, page) in pages.enumerated() {
            try Task.checkCancellation()
            output.append(
                NSAttributedString(
                    string: "Page \(page.pageIndex + 1)\n",
                    attributes: [
                        .font: UIFont.preferredFont(
                            forTextStyle: .title2
                        ),
                        .foregroundColor: UIColor.label
                    ]
                )
            )
            output.append(
                NSAttributedString(
                    string: "\(page.text)\n",
                    attributes: [
                        .font: UIFont.preferredFont(
                            forTextStyle: .body
                        ),
                        .foregroundColor: UIColor.label
                    ]
                )
            )
            if position < pages.count - 1 {
                output.append(
                    NSAttributedString(string: "\n\u{000C}\n")
                )
            }
        }
        return try output.data(
            from: NSRange(location: 0, length: output.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
        )
    }

    private func renderRasterized(
        sourceURL: URL,
        destination: URL,
        longestEdge: CGFloat,
        jpegQuality: CGFloat,
        redactions: [PDFRedactionMark],
        progress: @escaping PDFProgressHandler
    ) throws {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [:]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 612, height: 792),
            format: format
        )
        let marksByPage = Dictionary(
            grouping: redactions,
            by: \.pageIndex
        )
        var lastReportedPercent = -1
        progress(0.02)

        do {
            try renderer.writePDF(to: destination) { context in
                for index in 0..<document.pageCount {
                    if Task.isCancelled { return }
                    autoreleasepool {
                        guard let page = document.page(at: index) else {
                            return
                        }
                        let pageBounds = page.bounds(for: .cropBox)
                        let outputBounds = CGRect(
                            origin: .zero,
                            size: pageBounds.size
                        )
                        context.beginPage(
                            withBounds: outputBounds,
                            pageInfo: [:]
                        )

                        let imageSize = fittedSize(
                            pageBounds.size,
                            longestEdge: longestEdge
                        )
                        let rendered = page.thumbnail(
                            of: imageSize,
                            for: .cropBox
                        )
                        let compressed = rendered.jpegData(
                            compressionQuality: jpegQuality
                        )
                        let image = compressed.flatMap(UIImage.init(data:))
                            ?? rendered
                        image.draw(in: outputBounds)

                        UIColor.black.setFill()
                        for mark in marksByPage[index, default: []] {
                            let rect = CGRect(
                                x: mark.normalizedX * outputBounds.width,
                                y: (
                                    1
                                    - mark.normalizedY
                                    - mark.normalizedHeight
                                ) * outputBounds.height,
                                width: mark.normalizedWidth * outputBounds.width,
                                height: mark.normalizedHeight * outputBounds.height
                            ).insetBy(dx: -2, dy: -1)
                            context.cgContext.fill(rect)
                        }
                    }
                    let fraction = Double(index + 1)
                        / Double(max(1, document.pageCount))
                    let percent = Int((fraction * 100).rounded(.down))
                    if percent > lastReportedPercent {
                        lastReportedPercent = percent
                        progress(fraction)
                    }
                }
            }
            try Task.checkCancellation()
            LocalFileSecurity.applyCompleteProtection(to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PaperPathError.storageFailure(
                "The output PDF could not be rendered."
            )
        }
    }

    private func pdfBounds(
        _ bounds: PDFNormalizedRect,
        pageBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: pageBounds.minX + bounds.x * pageBounds.width,
            y: pageBounds.maxY
                - (bounds.y + bounds.height) * pageBounds.height,
            width: bounds.width * pageBounds.width,
            height: bounds.height * pageBounds.height
        ).intersection(pageBounds)
    }

    private func drawImage(
        _ data: Data,
        in bounds: CGRect,
        context: CGContext
    ) throws {
        guard data.count <= 12 * 1_024 * 1_024,
              let image = UIImage(data: data),
              let cgImage = image.cgImage,
              bounds.width > 0,
              bounds.height > 0
        else {
            throw PaperPathError.storageFailure(
                "An added image could not be decoded."
            )
        }
        let scale = min(
            bounds.width / CGFloat(cgImage.width),
            bounds.height / CGFloat(cgImage.height)
        )
        let size = CGSize(
            width: CGFloat(cgImage.width) * scale,
            height: CGFloat(cgImage.height) * scale
        )
        let fitted = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.draw(cgImage, in: fitted)
    }

    private func addText(
        _ text: String,
        bounds: CGRect,
        fontSize: Double,
        color: PDFInkColor,
        to page: PDFPage
    ) {
        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = text
        annotation.font = .systemFont(
            ofSize: min(max(fontSize, 8), 72)
        )
        annotation.fontColor = UIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
        annotation.color = .clear
        annotation.alignment = .left
        annotation.shouldPrint = true
        annotation.userName = "PaperPath"
        page.addAnnotation(annotation)
    }

    private func addLink(
        title: String,
        url: URL,
        bounds: CGRect,
        to page: PDFPage
    ) {
        let label = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? url.absoluteString : title
        let text = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        text.contents = label
        text.font = .systemFont(
            ofSize: min(max(bounds.height * 0.36, 9), 28)
        )
        text.fontColor = .systemBlue
        text.color = .clear
        text.alignment = .left
        text.shouldPrint = true
        text.userName = "PaperPath"
        page.addAnnotation(text)

        let link = PDFAnnotation(
            bounds: bounds,
            forType: .link,
            withProperties: nil
        )
        link.contents = label
        link.action = PDFActionURL(url: url)
        let border = PDFBorder()
        border.lineWidth = 0
        link.border = border
        link.color = .clear
        link.shouldPrint = false
        link.userName = "PaperPath"
        page.addAnnotation(link)
    }

    private func blockedTextReplacement(
        _ detail: String,
        fontStyle: PDFTextReplacementFontStyle,
        alignment: PDFTextReplacementAlignment
    ) -> PDFTextReplacementAssessment {
        PDFTextReplacementAssessment(
            status: .blocked,
            title: "Cannot replace safely",
            detail: detail,
            resolvedFontName: nil,
            resolvedFontSize: 0,
            resolvedLineSpacing: 0,
            reflowedLineCount: 0,
            backgroundColor: nil,
            regionBackgroundColors: [],
            flowRegionTexts: [],
            fontStyle: fontStyle,
            alignment: alignment
        )
    }

    private func textSelectionBounds(
        _ selection: PDFTextSelectionSnapshot,
        pageBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: pageBounds.minX
                + selection.normalizedX * pageBounds.width,
            y: pageBounds.maxY
                - (
                    selection.normalizedY
                        + selection.normalizedHeight
                ) * pageBounds.height,
            width: selection.normalizedWidth * pageBounds.width,
            height: selection.normalizedHeight * pageBounds.height
        ).intersection(pageBounds)
    }

    private func textFlowBounds(
        _ region: PDFTextFlowRegion,
        pageBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: pageBounds.minX
                + region.normalizedX * pageBounds.width,
            y: pageBounds.maxY
                - (
                    region.normalizedY
                        + region.normalizedHeight
                ) * pageBounds.height,
            width: region.normalizedWidth * pageBounds.width,
            height: region.normalizedHeight * pageBounds.height
        ).intersection(pageBounds)
    }

    private func textFlowRegionsAreOrdered(
        _ regions: [PDFTextFlowRegion]
    ) -> Bool {
        var previousPageIndex = -1
        var previousRangeEndByPage: [Int: Int] = [:]
        for region in regions {
            guard region.pageIndex >= previousPageIndex else {
                return false
            }
            previousPageIndex = region.pageIndex
            guard let location = region.sourceRangeLocation,
                  let length = region.sourceRangeLength
            else { continue }
            guard location >= previousRangeEndByPage[
                region.pageIndex,
                default: 0
            ] else {
                return false
            }
            previousRangeEndByPage[region.pageIndex] = location + length
        }
        return true
    }

    private func fittingReplacementLayout(
        text: String,
        selection: PDFTextSelectionSnapshot,
        bounds: [CGRect],
        style: PDFTextReplacementFontStyle,
        alignment: PDFTextReplacementAlignment
    ) throws -> PDFReplacementLayoutAttempt {
        let originalSize = min(max(selection.fontSize, 6), 72)
        let minimumScale: CGFloat = selection.lineCount > 4
            ? 0.8
            : 0.88
        let minimumSize = max(6, originalSize * minimumScale)
        let steps = 24
        var lastMeasurement = PDFReplacementFlowMeasurement(
            fits: false,
            lineCount: 0,
            regionTexts: [],
            consumedUTF16Length: 0,
            splitWordAtRegionBoundary: false
        )
        for step in 0...steps {
            try Task.checkCancellation()
            let progress = CGFloat(step) / CGFloat(steps)
            let size = originalSize
                - (originalSize - minimumSize) * progress
            let font = UIFont(
                name: style.pdfFontName,
                size: size
            ) ?? UIFont.systemFont(ofSize: size)
            let sourceLineStep = zip(
                bounds,
                selection.flowRegions
            ).reduce(CGFloat.zero) {
                $0 + $1.0.height / CGFloat(max(1, $1.1.lineCount))
            } / CGFloat(max(1, bounds.count))
            let lineSpacing = max(
                0,
                min(font.pointSize * 0.45, sourceLineStep - font.lineHeight)
            )
            let measurement = replacementFlowMeasurement(
                text: text,
                bounds: bounds,
                font: font,
                lineSpacing: lineSpacing,
                alignment: alignment
            )
            lastMeasurement = measurement
            if measurement.fits {
                return PDFReplacementLayoutAttempt(
                    layout: PDFReplacementTextLayout(
                        font: font,
                        lineSpacing: lineSpacing,
                        lineCount: measurement.lineCount,
                        regionTexts: measurement.regionTexts
                    ),
                    minimumFontSize: minimumSize,
                    consumedUTF16Length:
                        measurement.consumedUTF16Length,
                    splitWordAtRegionBoundary: false
                )
            }
        }
        return PDFReplacementLayoutAttempt(
            layout: nil,
            minimumFontSize: minimumSize,
            consumedUTF16Length:
                lastMeasurement.consumedUTF16Length,
            splitWordAtRegionBoundary:
                lastMeasurement.splitWordAtRegionBoundary
        )
    }

    private func replacementFlowMeasurement(
        text: String,
        bounds: [CGRect],
        font: UIFont,
        lineSpacing: CGFloat,
        alignment: PDFTextReplacementAlignment
    ) -> PDFReplacementFlowMeasurement {
        guard !bounds.isEmpty else {
            return PDFReplacementFlowMeasurement(
                fits: false,
                lineCount: 0,
                regionTexts: [],
                consumedUTF16Length: 0,
                splitWordAtRegionBoundary: false
            )
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(alignment)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        paragraph.hyphenationFactor = 0
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(
                    rawValue: kCTFontAttributeName as String
                ): CTFontCreateWithName(
                    font.fontName as CFString,
                    font.pointSize,
                    nil
                ),
                .paragraphStyle: paragraph
            ]
        )
        let source = text as NSString
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        var lineCount = 0
        var regionTexts: [String] = []
        regionTexts.reserveCapacity(bounds.count)
        for bounds in bounds {
            guard location < source.length else {
                regionTexts.append("")
                continue
            }
            let path = CGPath(
                rect: CGRect(
                    origin: .zero,
                    size: bounds.insetBy(dx: 0, dy: -0.5).size
                ),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                return PDFReplacementFlowMeasurement(
                    fits: false,
                    lineCount: lineCount,
                    regionTexts: regionTexts,
                    consumedUTF16Length: location,
                    splitWordAtRegionBoundary: false
                )
            }
            let range = NSRange(
                location: visible.location,
                length: visible.length
            )
            let chunk = source.substring(with: range)
            let visibleEnd = visible.location + visible.length
            guard !replacementBoundarySplitsWord(
                text,
                utf16Offset: visibleEnd
            ) else {
                return PDFReplacementFlowMeasurement(
                    fits: false,
                    lineCount: lineCount,
                    regionTexts: regionTexts,
                    consumedUTF16Length: visibleEnd,
                    splitWordAtRegionBoundary: true
                )
            }
            let widestToken = chunk
                .split(whereSeparator: \.isWhitespace)
                .map {
                    (String($0) as NSString).size(
                        withAttributes: [.font: font]
                    ).width
                }
                .max() ?? 0
            guard widestToken <= bounds.width * 1.02 else {
                return PDFReplacementFlowMeasurement(
                    fits: false,
                    lineCount: lineCount,
                    regionTexts: regionTexts,
                    consumedUTF16Length: location,
                    splitWordAtRegionBoundary: true
                )
            }
            regionTexts.append(chunk)
            lineCount += (CTFrameGetLines(frame) as NSArray).count
            location = visibleEnd
        }
        return PDFReplacementFlowMeasurement(
            fits: location >= source.length,
            lineCount: lineCount,
            regionTexts: regionTexts,
            consumedUTF16Length: location,
            splitWordAtRegionBoundary: false
        )
    }

    private func replacementBoundarySplitsWord(
        _ text: String,
        utf16Offset: Int
    ) -> Bool {
        guard utf16Offset > 0,
              utf16Offset < text.utf16.count
        else { return false }
        let boundary = String.Index(
            utf16Offset: utf16Offset,
            in: text
        )
        let previous = text.index(before: boundary)
        return !text[previous].isWhitespace
            && !text[boundary].isWhitespace
    }

    private func textAlignment(
        _ alignment: PDFTextReplacementAlignment
    ) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private func sampledTextBackgrounds(
        document: PDFDocument,
        regions: [PDFTextFlowRegion]
    ) throws -> [PDFInkColor]? {
        let context = CIContext(options: [.cacheIntermediates: false])
        var pageImages: [
            Int: (image: CIImage, width: CGFloat, height: CGFloat)
        ] = [:]
        var backgrounds: [PDFInkColor] = []
        backgrounds.reserveCapacity(regions.count)
        for region in regions {
            try Task.checkCancellation()
            let pageImage: (
                image: CIImage,
                width: CGFloat,
                height: CGFloat
            )
            if let cached = pageImages[region.pageIndex] {
                pageImage = cached
            } else {
                guard let page = document.page(at: region.pageIndex) else {
                    return nil
                }
                let pageBounds = page.bounds(for: .cropBox)
                let size = fittedSize(
                    pageBounds.size,
                    longestEdge: 1_400
                )
                guard let cgImage = page.thumbnail(
                    of: size,
                    for: .cropBox
                ).cgImage else { return nil }
                pageImage = (
                    CIImage(cgImage: cgImage),
                    CGFloat(cgImage.width),
                    CGFloat(cgImage.height)
                )
                pageImages[region.pageIndex] = pageImage
            }
            guard let background = sampledTextBackground(
                region: region,
                width: pageImage.width,
                height: pageImage.height,
                image: pageImage.image,
                context: context
            ) else {
                return nil
            }
            backgrounds.append(background)
        }
        return backgrounds
    }

    private func sampledTextBackground(
        region: PDFTextFlowRegion,
        width: CGFloat,
        height: CGFloat,
        image: CIImage,
        context: CIContext
    ) -> PDFInkColor? {
        let target = CGRect(
            x: region.normalizedX * width,
            y: (
                1
                    - region.normalizedY
                    - region.normalizedHeight
            ) * height,
            width: region.normalizedWidth * width,
            height: region.normalizedHeight * height
        )
        let strip = max(3, min(8, target.height * 0.18))
        let samples = [
            CGRect(
                x: target.minX,
                y: target.maxY + 1,
                width: target.width,
                height: strip
            ),
            CGRect(
                x: target.minX,
                y: target.minY - strip - 1,
                width: target.width,
                height: strip
            ),
            CGRect(
                x: target.minX - strip - 1,
                y: target.minY,
                width: strip,
                height: target.height
            ),
            CGRect(
                x: target.maxX + 1,
                y: target.minY,
                width: strip,
                height: target.height
            )
        ]
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colors = samples.compactMap {
            averageColor(
                image: image,
                rect: $0.intersection(imageBounds),
                context: context
            )
        }
        guard colors.count >= 3 else { return nil }
        let average = colors.reduce(
            (red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        ) {
            (
                $0.red + $1.red,
                $0.green + $1.green,
                $0.blue + $1.blue,
                $0.alpha + $1.alpha
            )
        }
        let divisor = Double(colors.count)
        let resolved = (
            red: average.red / divisor,
            green: average.green / divisor,
            blue: average.blue / divisor,
            alpha: average.alpha / divisor
        )
        let maximumDifference = colors.reduce(0.0) { difference, color in
            max(
                difference,
                abs(color.red - resolved.red),
                abs(color.green - resolved.green),
                abs(color.blue - resolved.blue)
            )
        }
        let luminance = 0.2126 * resolved.red
            + 0.7152 * resolved.green
            + 0.0722 * resolved.blue
        guard maximumDifference <= 0.075,
              luminance >= 0.72,
              resolved.alpha >= 0.96
        else { return nil }
        return PDFInkColor(
            red: resolved.red,
            green: resolved.green,
            blue: resolved.blue,
            alpha: 1
        )
    }

    private func averageColor(
        image: CIImage,
        rect: CGRect,
        context: CIContext
    ) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard rect.width >= 1, rect.height >= 1,
              let filter = CIFilter(name: "CIAreaAverage")
        else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(
            CIVector(cgRect: rect.integral),
            forKey: kCIInputExtentKey
        )
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: output.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (
            Double(pixel[0]) / 255,
            Double(pixel[1]) / 255,
            Double(pixel[2]) / 255,
            Double(pixel[3]) / 255
        )
    }

    private func matchingTextRange(
        in page: PDFPage,
        snapshot: PDFTextSelectionSnapshot
    ) -> NSRange? {
        guard let pageText = page.string else { return nil }
        let source = pageText as NSString
        let pageBounds = page.bounds(for: .cropBox)
        let expected = textSelectionBounds(
            snapshot,
            pageBounds: pageBounds
        )
        var searchRange = NSRange(location: 0, length: source.length)
        var best: (range: NSRange, score: CGFloat)?
        while searchRange.length > 0 {
            let found = source.range(
                of: snapshot.originalText,
                options: [],
                range: searchRange
            )
            guard found.location != NSNotFound else { break }
            if let selection = page.selection(for: found) {
                let bounds = selection.bounds(for: page)
                let intersection = bounds.intersection(expected)
                let score = intersection.isNull
                    ? 0
                    : intersection.width * intersection.height
                        / max(1, expected.width * expected.height)
                if best == nil || score > best!.score {
                    best = (found, score)
                }
            }
            let next = found.location + max(found.length, 1)
            guard next < source.length else { break }
            searchRange = NSRange(
                location: next,
                length: source.length - next
            )
        }
        guard let best, best.score >= 0.45 else { return nil }
        return best.range
    }

    private func selectedTextRanges(
        in page: PDFPage,
        snapshot: PDFTextSelectionSnapshot,
        regions: [PDFTextFlowRegion]
    ) -> [NSRange]? {
        guard let pageText = page.string else { return nil }
        let source = pageText as NSString
        let storedRanges = regions.compactMap { region -> NSRange? in
            guard let location = region.sourceRangeLocation,
                  let length = region.sourceRangeLength,
                  location >= 0,
                  length > 0
            else { return nil }
            return NSRange(location: location, length: length)
        }
        if storedRanges.count == regions.count {
            let validated = zip(regions, storedRanges).allSatisfy {
                pair in
                let region = pair.0
                let range = pair.1
                guard NSMaxRange(range) <= source.length else {
                    return false
                }
                return normalizedVerificationText(
                    source.substring(with: range)
                ) == normalizedVerificationText(
                    region.originalText
                )
            }
            let sorted = storedRanges.sorted {
                $0.location < $1.location
            }
            let nonOverlapping = zip(
                sorted,
                sorted.dropFirst()
            ).allSatisfy {
                pair in NSMaxRange(pair.0) <= pair.1.location
            }
            guard validated, nonOverlapping else { return nil }
            return sorted
        }
        guard regions.count == 1,
              regions[0].pageIndex == snapshot.pageIndex
        else { return nil }
        return matchingTextRange(
            in: page,
            snapshot: snapshot
        ).map { [$0] }
    }

    private func textReplacementAssessmentsMatch(
        _ preview: PDFTextReplacementAssessment,
        _ current: PDFTextReplacementAssessment
    ) -> Bool {
        preview.isReady
            && current.isReady
            && preview.resolvedFontName == current.resolvedFontName
            && abs(
                preview.resolvedFontSize
                    - current.resolvedFontSize
            ) < 0.01
            && abs(
                preview.resolvedLineSpacing
                    - current.resolvedLineSpacing
            ) < 0.01
            && preview.regionBackgroundColors
                == current.regionBackgroundColors
            && preview.flowRegionTexts == current.flowRegionTexts
            && preview.fontStyle == current.fontStyle
            && preview.alignment == current.alignment
    }

    private func drawReplacementTextChunks(
        _ chunks: [String],
        bounds: [CGRect],
        fontName: String?,
        fontSize: Double,
        lineSpacing: Double,
        alignment: PDFTextReplacementAlignment,
        color: PDFInkColor,
        context: CGContext
    ) {
        guard chunks.count == bounds.count else { return }
        let font = CTFontCreateWithName(
            (fontName ?? "Helvetica") as CFString,
            min(max(fontSize, 6), 72),
            nil
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(alignment)
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(0, lineSpacing)
        paragraph.hyphenationFactor = 0
        context.saveGState()
        context.textMatrix = .identity
        context.setTextDrawingMode(.fill)
        for (chunk, bounds) in zip(chunks, bounds)
            where !chunk.isEmpty {
            let attributed = NSAttributedString(
                string: chunk,
                attributes: [
                    NSAttributedString.Key(
                        rawValue: kCTFontAttributeName as String
                    ): font,
                    NSAttributedString.Key(
                        rawValue: kCTForegroundColorAttributeName as String
                    ): CGColor(
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        alpha: color.alpha
                    ),
                    .paragraphStyle: paragraph
                ]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(
                attributed
            )
            let path = CGPath(
                rect: bounds.insetBy(dx: 0, dy: -0.5),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                path,
                nil
            )
            CTFrameDraw(frame, context)
        }
        context.restoreGState()
    }

    private func drawSearchableTextOutsideSelection(
        page: PDFPage,
        selectedRanges: [NSRange],
        context: CGContext
    ) {
        guard let pageText = page.string,
              let fullSelection = page.selection(
                for: NSRange(
                    location: 0,
                    length: (pageText as NSString).length
                )
              )
        else { return }
        for line in fullSelection.selectionsByLine() {
            let rangeCount = line.numberOfTextRanges(on: page)
            let intersectsSelection = (0..<rangeCount).contains {
                let lineRange = line.range(at: $0, on: page)
                return selectedRanges.contains {
                    NSIntersectionRange(
                        lineRange,
                        $0
                    ).length > 0
                }
            }
            guard !intersectsSelection,
                  let text = line.string,
                  !text.isEmpty
            else { continue }
            drawInvisibleText(
                text,
                bounds: line.bounds(for: page),
                context: context
            )
        }
    }

    private func drawInvisibleText(
        _ text: String,
        bounds: CGRect,
        context: CGContext
    ) {
        let fontSize = max(4, min(72, bounds.height * 0.78))
        let font = CTFontCreateWithName(
            "Helvetica" as CFString,
            fontSize,
            nil
        )
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(
                    rawValue: kCTFontAttributeName as String
                ): font
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: bounds.minX,
            y: bounds.minY + bounds.height * 0.12
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func occurrenceCount(
        of needle: String,
        in haystack: String
    ) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(
            of: needle,
            options: [],
            range: searchRange
        ) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private func normalizedOccurrenceCount(
        of needle: String,
        in haystack: String
    ) -> Int {
        occurrenceCount(
            of: normalizedVerificationText(needle),
            in: normalizedVerificationText(haystack)
        )
    }

    private func normalizedVerificationText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{00ad}", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func fittedSize(
        _ size: CGSize,
        longestEdge: CGFloat
    ) -> CGSize {
        let sourceEdge = max(size.width, size.height)
        guard sourceEdge > 0 else {
            return CGSize(width: longestEdge, height: longestEdge)
        }
        let scale = longestEdge / sourceEdge
        return CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
    }

    private static func rectsMatch(
        _ left: PDFNormalizedRect,
        _ right: PDFNormalizedRect
    ) -> Bool {
        let tolerance = 0.002
        return abs(left.x - right.x) <= tolerance
            && abs(left.y - right.y) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }
}

private struct PDFRGBASamples {
    let width: Int
    let height: Int
    let rgbData: Data
    let alphaData: Data
}

private func pdfOpaqueImage(_ image: UIImage) throws -> UIImage {
    let pixelSize = CGSize(
        width: max(1, image.size.width),
        height: max(1, image.size.height)
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(
        size: pixelSize,
        format: format
    ).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: pixelSize))
        image.draw(in: CGRect(origin: .zero, size: pixelSize))
    }
}

private func pdfRGBASamples(
    _ image: UIImage,
    preserveAlpha: Bool
) throws -> PDFRGBASamples {
    let source = preserveAlpha ? image : try pdfOpaqueImage(image)
    let pixelSize = CGSize(
        width: max(1, source.size.width),
        height: max(1, source.size.height)
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = !preserveAlpha
    let normalized = UIGraphicsImageRenderer(
        size: pixelSize,
        format: format
    ).image { context in
        if !preserveAlpha {
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pixelSize))
        }
        source.draw(in: CGRect(origin: .zero, size: pixelSize))
    }
    guard let cgImage = normalized.cgImage,
          cgImage.width > 0,
          cgImage.height > 0,
          cgImage.width <= 8_192,
          cgImage.height <= 8_192,
          cgImage.width <= Int.max / max(1, cgImage.height),
          cgImage.width * cgImage.height <= 16_000_000
    else {
        throw PaperPathError.fileTooLarge
    }
    let width = cgImage.width
    let height = cgImage.height
    var rgba = Data(count: width * height * 4)
    var rgb = Data(count: width * height * 3)
    var alpha = Data(count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let extracted = rgba.withUnsafeMutableBytes {
        rgbaBytes in
        guard let context = CGContext(
            data: rgbaBytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let pixels = rgbaBytes.bindMemory(
            to: UInt8.self
        ).baseAddress else { return false }
        return rgb.withUnsafeMutableBytes { rgbBytes in
            alpha.withUnsafeMutableBytes { alphaBytes in
                guard let rgbPixels = rgbBytes.bindMemory(
                    to: UInt8.self
                ).baseAddress,
                      let alphaPixels = alphaBytes.bindMemory(
                          to: UInt8.self
                      ).baseAddress
                else { return false }
                for index in 0..<(width * height) {
                    let input = index * 4
                    let output = index * 3
                    let alphaValue = preserveAlpha
                        ? pixels[input + 3]
                        : 255
                    alphaPixels[index] = alphaValue
                    if alphaValue == 0 {
                        rgbPixels[output] = 0
                        rgbPixels[output + 1] = 0
                        rgbPixels[output + 2] = 0
                    } else {
                        let divisor = UInt16(alphaValue)
                        rgbPixels[output] = UInt8(
                            min(
                                255,
                                UInt16(pixels[input]) * 255 / divisor
                            )
                        )
                        rgbPixels[output + 1] = UInt8(
                            min(
                                255,
                                UInt16(pixels[input + 1]) * 255 / divisor
                            )
                        )
                        rgbPixels[output + 2] = UInt8(
                            min(
                                255,
                                UInt16(pixels[input + 2]) * 255 / divisor
                            )
                        )
                    }
                }
                return true
            }
        }
    }
    guard extracted else {
        throw PaperPathError.unreadableImage
    }
    return PDFRGBASamples(
        width: width,
        height: height,
        rgbData: rgb,
        alphaData: alpha
    )
}

private func pdfFlateImageObject(
    reference: PDFImageObjectReference,
    width: Int,
    height: Int,
    rgbData: Data,
    softMask: PDFImageObjectReference?
) throws -> Data {
    guard rgbData.count == width * height * 3,
          let compressed = pdfDeflateZlib(rgbData)
    else {
        throw PaperPathError.outputVerificationFailed(
            "the replacement RGB samples could not be encoded"
        )
    }
    let softMaskEntry = softMask.map {
        " /SMask \($0.number) \($0.generation) R"
    } ?? ""
    let header = """
    \(reference.number) \(reference.generation) obj
    << /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true\(softMaskEntry) /Filter /FlateDecode /Length \(compressed.count) >>
    stream
    """
    var result = Data((header + "\n").utf8)
    result.append(compressed)
    result.append(Data("\nendstream\nendobj".utf8))
    return result
}

private func pdfFlateMaskObject(
    reference: PDFImageObjectReference,
    width: Int,
    height: Int,
    alphaData: Data
) throws -> Data {
    guard alphaData.count == width * height,
          let compressed = pdfDeflateZlib(alphaData)
    else {
        throw PaperPathError.outputVerificationFailed(
            "the replacement alpha samples could not be encoded"
        )
    }
    let header = """
    \(reference.number) \(reference.generation) obj
    << /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Interpolate true /Filter /FlateDecode /Length \(compressed.count) >>
    stream
    """
    var result = Data((header + "\n").utf8)
    result.append(compressed)
    result.append(Data("\nendstream\nendobj".utf8))
    return result
}

private func pdfDeflateZlib(_ data: Data) -> Data? {
    guard let raw = try? (data as NSData)
        .compressed(using: .zlib) as Data
    else { return nil }
    var result = Data([0x78, 0x9c])
    result.append(raw)
    var first: UInt32 = 1
    var second: UInt32 = 0
    for byte in data {
        first = (first + UInt32(byte)) % 65_521
        second = (second + first) % 65_521
    }
    let checksum = (second << 16) | first
    result.append(UInt8((checksum >> 24) & 0xff))
    result.append(UInt8((checksum >> 16) & 0xff))
    result.append(UInt8((checksum >> 8) & 0xff))
    result.append(UInt8(checksum & 0xff))
    return result
}

private final class PDFImageScanState {
    let pageIndex: Int
    let cropBox: CGRect
    let resources: CGPDFDictionaryRef
    let xObjects: CGPDFDictionaryRef
    let contentStream: CGPDFContentStreamRef
    let resourcePath: String
    let depth: Int
    var transform = CGAffineTransform.identity
    var transformStack: [CGAffineTransform] = []
    var uses: [PDFScannedImageUse] = []
    var capturedByteCount = 0
    var encounteredImageCount = 0
    var unsupportedImageCount = 0
    var omittedImageCount = 0

    init(
        pageIndex: Int,
        cropBox: CGRect,
        resources: CGPDFDictionaryRef,
        xObjects: CGPDFDictionaryRef,
        contentStream: CGPDFContentStreamRef,
        resourcePath: String = "",
        depth: Int = 0,
        transform: CGAffineTransform = .identity
    ) {
        self.pageIndex = pageIndex
        self.cropBox = cropBox
        self.resources = resources
        self.xObjects = xObjects
        self.contentStream = contentStream
        self.resourcePath = resourcePath
        self.depth = depth
        self.transform = transform
    }

    func merge(_ child: PDFImageScanState) {
        encounteredImageCount += child.encounteredImageCount
        unsupportedImageCount += child.unsupportedImageCount
        omittedImageCount += child.omittedImageCount
        for use in child.uses {
            guard uses.count < 32,
                  capturedByteCount + use.data.count
                    <= 32 * 1_024 * 1_024
            else {
                omittedImageCount += 1
                continue
            }
            uses.append(use)
            capturedByteCount += use.data.count
        }
    }
}

private enum PDFScannedImageKind {
    case originalJPEG
    case originalJPEG2000
    case losslessPNG

    var fileExtension: String {
        switch self {
        case .originalJPEG: return "jpg"
        case .originalJPEG2000: return "jp2"
        case .losslessPNG: return "png"
        }
    }

    var isOriginalStream: Bool {
        switch self {
        case .originalJPEG, .originalJPEG2000: return true
        case .losslessPNG: return false
        }
    }
}

private struct PDFScannedImageUse {
    let pageIndex: Int
    let resourceName: String
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let data: Data
    let sourceStreamData: Data
    let softMaskStreamData: Data?
    let kind: PDFScannedImageKind
}

private struct PDFImagePageScan {
    let uses: [PDFScannedImageUse]
    let encounteredImageCount: Int
    let unsupportedImageCount: Int
    let omittedImageCount: Int
}

private let pdfPushGraphicsState: CGPDFOperatorCallback = {
    _, info in
    guard let info else { return }
    let state = Unmanaged<PDFImageScanState>
        .fromOpaque(info)
        .takeUnretainedValue()
    state.transformStack.append(state.transform)
}

private let pdfPopGraphicsState: CGPDFOperatorCallback = {
    _, info in
    guard let info else { return }
    let state = Unmanaged<PDFImageScanState>
        .fromOpaque(info)
        .takeUnretainedValue()
    if let previous = state.transformStack.popLast() {
        state.transform = previous
    }
}

private let pdfConcatenateMatrix: CGPDFOperatorCallback = {
    scanner, info in
    guard let info else { return }
    var f: CGPDFReal = 0
    var e: CGPDFReal = 0
    var d: CGPDFReal = 0
    var c: CGPDFReal = 0
    var b: CGPDFReal = 0
    var a: CGPDFReal = 0
    guard CGPDFScannerPopNumber(scanner, &f),
          CGPDFScannerPopNumber(scanner, &e),
          CGPDFScannerPopNumber(scanner, &d),
          CGPDFScannerPopNumber(scanner, &c),
          CGPDFScannerPopNumber(scanner, &b),
          CGPDFScannerPopNumber(scanner, &a)
    else { return }
    let state = Unmanaged<PDFImageScanState>
        .fromOpaque(info)
        .takeUnretainedValue()
    let matrix = CGAffineTransform(
        a: a,
        b: b,
        c: c,
        d: d,
        tx: e,
        ty: f
    )
    state.transform = matrix.concatenating(state.transform)
}

private let pdfDrawXObject: CGPDFOperatorCallback = {
    scanner, info in
    guard let info else { return }
    var namePointer: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &namePointer),
          let namePointer
    else { return }
    let state = Unmanaged<PDFImageScanState>
        .fromOpaque(info)
        .takeUnretainedValue()
    var stream: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(
        state.xObjects,
        namePointer,
        &stream
    ),
          let stream,
          let dictionary = CGPDFStreamGetDictionary(stream)
    else { return }
    var subtypePointer: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(
        dictionary,
        "Subtype",
        &subtypePointer
    ),
          let subtypePointer
    else { return }
    let subtype = String(cString: subtypePointer)
    let resourceName = state.resourcePath
        + String(cString: namePointer)

    if subtype == "Form" {
        guard state.depth < 4 else {
            state.omittedImageCount += 1
            return
        }
        var formResources: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(
            dictionary,
            "Resources",
            &formResources
        ) {
            formResources = state.resources
        }
        guard let formResources else { return }
        var formXObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            formResources,
            "XObject",
            &formXObjects
        ),
              let formXObjects
        else { return }
        let formMatrix = pdfFormMatrix(dictionary)
        let content = CGPDFContentStreamCreateWithStream(
            stream,
            formResources,
            state.contentStream
        )
        defer { CGPDFContentStreamRelease(content) }
        let child = PDFImageScanState(
            pageIndex: state.pageIndex,
            cropBox: state.cropBox,
            resources: formResources,
            xObjects: formXObjects,
            contentStream: content,
            resourcePath: resourceName + "/",
            depth: state.depth + 1,
            transform: formMatrix.concatenating(state.transform)
        )
        _ = pdfScanContent(child)
        state.merge(child)
        return
    }

    guard subtype == "Image" else { return }
    state.encounteredImageCount += 1
    var width: CGPDFInteger = 0
    var height: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
          CGPDFDictionaryGetInteger(dictionary, "Height", &height),
          width > 0,
          height > 0
    else {
        state.omittedImageCount += 1
        return
    }
    var encodedLength: CGPDFInteger = 0
    if CGPDFDictionaryGetInteger(
        dictionary,
        "Length",
        &encodedLength
    ),
       encodedLength > 16 * 1_024 * 1_024 {
        state.omittedImageCount += 1
        return
    }
    var format = CGPDFDataFormat.raw
    guard let copied = CGPDFStreamCopyData(stream, &format) else {
        state.unsupportedImageCount += 1
        return
    }
    let copiedData = copied as Data
    let payload: (
        data: Data,
        sourceStreamData: Data,
        softMaskStreamData: Data?,
        kind: PDFScannedImageKind
    )?
    switch format {
    case .jpegEncoded:
        payload = (
            copiedData,
            copiedData,
            nil,
            .originalJPEG
        )
    case .JPEG2000:
        payload = (
            copiedData,
            copiedData,
            nil,
            .originalJPEG2000
        )
    case .raw:
        payload = pdfDecodedImagePayload(
            dictionary: dictionary,
            rawData: copiedData,
            width: Int(width),
            height: Int(height)
        ).map {
            (
                $0.pngData,
                copiedData,
                $0.softMaskData,
                .losslessPNG
            )
        }
    @unknown default:
        payload = nil
    }
    guard let payload else {
        state.unsupportedImageCount += 1
        return
    }
    guard !payload.data.isEmpty,
          payload.data.count <= 32 * 1_024 * 1_024,
          state.uses.count < 32,
          state.capturedByteCount + payload.data.count
            <= 32 * 1_024 * 1_024
    else {
        state.omittedImageCount += 1
        return
    }
    let transformed = CGRect(x: 0, y: 0, width: 1, height: 1)
        .applying(state.transform)
        .standardized
        .intersection(state.cropBox)
    guard !transformed.isNull,
          transformed.width > 4,
          transformed.height > 4
    else {
        state.omittedImageCount += 1
        return
    }
    state.uses.append(
        PDFScannedImageUse(
            pageIndex: state.pageIndex,
            resourceName: resourceName,
            bounds: transformed,
            pixelWidth: width,
            pixelHeight: height,
            data: payload.data,
            sourceStreamData: payload.sourceStreamData,
            softMaskStreamData: payload.softMaskStreamData,
            kind: payload.kind
        )
    )
    state.capturedByteCount += payload.data.count
}

private func pdfFormMatrix(
    _ dictionary: CGPDFDictionaryRef
) -> CGAffineTransform {
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, "Matrix", &array),
          let array,
          CGPDFArrayGetCount(array) == 6
    else { return .identity }
    var values = Array(repeating: CGPDFReal(0), count: 6)
    for index in values.indices {
        guard CGPDFArrayGetNumber(array, index, &values[index]) else {
            return .identity
        }
    }
    return CGAffineTransform(
        a: values[0],
        b: values[1],
        c: values[2],
        d: values[3],
        tx: values[4],
        ty: values[5]
    )
}

private func pdfScanContent(
    _ state: PDFImageScanState
) -> Bool {
    guard let table = CGPDFOperatorTableCreate() else {
        return false
    }
    defer { CGPDFOperatorTableRelease(table) }
    CGPDFOperatorTableSetCallback(
        table,
        "q",
        pdfPushGraphicsState
    )
    CGPDFOperatorTableSetCallback(
        table,
        "Q",
        pdfPopGraphicsState
    )
    CGPDFOperatorTableSetCallback(
        table,
        "cm",
        pdfConcatenateMatrix
    )
    CGPDFOperatorTableSetCallback(
        table,
        "Do",
        pdfDrawXObject
    )
    let scanner = CGPDFScannerCreate(
        state.contentStream,
        table,
        Unmanaged.passUnretained(state).toOpaque()
    )
    defer { CGPDFScannerRelease(scanner) }
    return CGPDFScannerScan(scanner)
}

private struct PDFDecodedImagePayload {
    let pngData: Data
    let softMaskData: Data?
}

private func pdfDecodedImagePayload(
    dictionary: CGPDFDictionaryRef,
    rawData: Data,
    width: Int,
    height: Int
) -> PDFDecodedImagePayload? {
    guard width > 0,
          height > 0,
          width <= 20_000,
          height <= 20_000,
          rawData.count <= 64 * 1_024 * 1_024
    else { return nil }
    var imageMask: CGPDFBoolean = 0
    if CGPDFDictionaryGetBoolean(
        dictionary,
        "ImageMask",
        &imageMask
    ),
       imageMask != 0 {
        return nil
    }
    var decodeObject: CGPDFObjectRef?
    guard !CGPDFDictionaryGetObject(
        dictionary,
        "Decode",
        &decodeObject
    ) else {
        return nil
    }
    var hardMaskObject: CGPDFObjectRef?
    guard !CGPDFDictionaryGetObject(
        dictionary,
        "Mask",
        &hardMaskObject
    ) else {
        return nil
    }
    var bitsPerComponent: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(
        dictionary,
        "BitsPerComponent",
        &bitsPerComponent
    ),
          bitsPerComponent == 8
    else { return nil }
    var colorSpacePointer: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(
        dictionary,
        "ColorSpace",
        &colorSpacePointer
    ),
          let colorSpacePointer
    else { return nil }
    let colorSpaceName = String(cString: colorSpacePointer)
    let components: Int
    let colorSpace: CGColorSpace
    switch colorSpaceName {
    case "DeviceGray", "G":
        components = 1
        colorSpace = CGColorSpaceCreateDeviceGray()
    case "DeviceRGB", "RGB":
        components = 3
        colorSpace = CGColorSpaceCreateDeviceRGB()
    case "DeviceCMYK", "CMYK":
        components = 4
        colorSpace = CGColorSpaceCreateDeviceCMYK()
    default:
        return nil
    }
    guard width <= Int.max / max(1, components),
          height <= Int.max / max(1, width * components)
    else { return nil }
    let bytesPerRow = width * components
    let expectedByteCount = bytesPerRow * height
    guard rawData.count == expectedByteCount,
          let provider = CGDataProvider(data: rawData as CFData),
          let baseImage = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 8 * components,
              bytesPerRow: bytesPerRow,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo(
                  rawValue: CGImageAlphaInfo.none.rawValue
              ),
              provider: provider,
              decode: nil,
              shouldInterpolate: true,
              intent: .defaultIntent
          )
    else { return nil }

    var softMask: CGPDFStreamRef?
    guard CGPDFDictionaryGetStream(
        dictionary,
        "SMask",
        &softMask
    ) else {
        guard let pngData = UIImage(cgImage: baseImage).pngData()
        else { return nil }
        return PDFDecodedImagePayload(
            pngData: pngData,
            softMaskData: nil
        )
    }
    guard let softMask,
          let alphaData = pdfSoftMaskData(
              stream: softMask,
              expectedWidth: width,
              expectedHeight: height
          ),
          let maskedImage = pdfImage(
              baseImage,
              applyingAlpha: alphaData
          )
    else { return nil }
    guard let pngData = UIImage(cgImage: maskedImage).pngData()
    else { return nil }
    return PDFDecodedImagePayload(
        pngData: pngData,
        softMaskData: alphaData
    )
}

private func pdfSoftMaskData(
    stream: CGPDFStreamRef,
    expectedWidth: Int,
    expectedHeight: Int
) -> Data? {
    guard let dictionary = CGPDFStreamGetDictionary(stream)
    else { return nil }
    var width: CGPDFInteger = 0
    var height: CGPDFInteger = 0
    var bitsPerComponent: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(dictionary, "Width", &width),
          CGPDFDictionaryGetInteger(dictionary, "Height", &height),
          CGPDFDictionaryGetInteger(
              dictionary,
              "BitsPerComponent",
              &bitsPerComponent
          ),
          width == expectedWidth,
          height == expectedHeight,
          bitsPerComponent == 8
    else { return nil }
    var colorSpacePointer: UnsafePointer<CChar>?
    if CGPDFDictionaryGetName(
        dictionary,
        "ColorSpace",
        &colorSpacePointer
    ),
       let colorSpacePointer,
       !["DeviceGray", "G"].contains(
           String(cString: colorSpacePointer)
       ) {
        return nil
    }
    var decodeObject: CGPDFObjectRef?
    guard !CGPDFDictionaryGetObject(
        dictionary,
        "Decode",
        &decodeObject
    ) else {
        return nil
    }
    var format = CGPDFDataFormat.raw
    guard let copied = CGPDFStreamCopyData(stream, &format),
          format == .raw
    else { return nil }
    let data = copied as Data
    guard data.count == expectedWidth * expectedHeight else {
        return nil
    }
    return data
}

private func pdfImage(
    _ baseImage: CGImage,
    applyingAlpha alphaData: Data
) -> CGImage? {
    let width = baseImage.width
    let height = baseImage.height
    guard alphaData.count == width * height else { return nil }
    var rgba = Data(count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    return rgba.withUnsafeMutableBytes { rgbaBytes -> CGImage? in
        guard let context = CGContext(
            data: rgbaBytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            baseImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        alphaData.withUnsafeBytes { alphaBytes in
            guard let pixels = rgbaBytes.bindMemory(
                to: UInt8.self
            ).baseAddress,
                  let alpha = alphaBytes.bindMemory(
                      to: UInt8.self
                  ).baseAddress
            else { return }
            for index in 0..<(width * height) {
                let pixel = index * 4
                let alphaValue = UInt16(alpha[index])
                pixels[pixel] = UInt8(
                    UInt16(pixels[pixel]) * alphaValue / 255
                )
                pixels[pixel + 1] = UInt8(
                    UInt16(pixels[pixel + 1]) * alphaValue / 255
                )
                pixels[pixel + 2] = UInt8(
                    UInt16(pixels[pixel + 2]) * alphaValue / 255
                )
                pixels[pixel + 3] = UInt8(alphaValue)
            }
        }
        return context.makeImage()
    }
}

private struct PDFImageObjectInspector {
    func snapshots(
        sourceURL: URL,
        pageIndex: Int
    ) throws -> [PDFImageObjectSnapshot] {
        guard let document = CGPDFDocument(sourceURL as CFURL),
              pageIndex >= 0,
              pageIndex < document.numberOfPages
        else {
            throw PaperPathError.unreadablePDF
        }
        let sourceData = try Data(
            contentsOf: sourceURL,
            options: .mappedIfSafe
        )
        let parser = try PDFImageObjectDocument(data: sourceData)
        guard let targetPage = document.page(at: pageIndex + 1) else {
            throw PaperPathError.invalidPage
        }
        let targetUses = scan(
            page: targetPage,
            pageIndex: pageIndex
        ).filter {
            $0.kind == .originalJPEG
                || $0.kind == .losslessPNG
        }
        let candidateDigests = Set(
            targetUses.map { Self.digest($0.data) }
        )
        var usageCountByDigest = Dictionary(
            grouping: targetUses,
            by: { Self.digest($0.data) }
        ).mapValues(\.count)
        if !candidateDigests.isEmpty {
            for index in 0..<document.numberOfPages
                where index != pageIndex {
                try Task.checkCancellation()
                guard let page = document.page(at: index + 1) else {
                    continue
                }
                autoreleasepool {
                    for use in scan(
                        page: page,
                        pageIndex: index
                    ) where use.kind == .originalJPEG
                        || use.kind == .losslessPNG {
                        let digest = Self.digest(use.data)
                        if candidateDigests.contains(digest) {
                            usageCountByDigest[digest, default: 0] += 1
                        }
                    }
                }
            }
        }
        var objectByDigest: [
            String: PDFImageObjectReference
        ] = [:]
        for use in targetUses {
            try Task.checkCancellation()
            let digest = Self.digest(use.data)
            if objectByDigest[digest] == nil {
                let object: PDFImageObjectReference?
                switch use.kind {
                case .originalJPEG:
                    object = parser.imageObject(
                        matching: use.sourceStreamData
                    )
                case .losslessPNG:
                    object = parser.imageObject(
                        matchingDecodedStream: use.sourceStreamData
                    )
                case .originalJPEG2000:
                    object = nil
                }
                objectByDigest[digest] = object
            }
        }
        return targetUses.compactMap { use in
            guard let object = objectByDigest[
                      Self.digest(use.data)
                  ]
            else { return nil }
            let softMaskObject = use.softMaskStreamData.flatMap {
                _ in parser.referencedObject(
                    following: "/SMask",
                    in: object
                )
            }
            let cropBox = document.page(at: pageIndex + 1)?
                .getBoxRect(.cropBox) ?? .zero
            guard cropBox.width > 0, cropBox.height > 0 else {
                return nil
            }
            let storage: PDFImageObjectSnapshot.Storage
            if use.kind == .originalJPEG {
                storage = .jpeg
            } else if use.softMaskStreamData != nil {
                storage = .flateWithSoftMask
            } else {
                storage = .flate
            }
            return PDFImageObjectSnapshot(
                pageIndex: pageIndex,
                objectNumber: object.number,
                generation: object.generation,
                resourceName: use.resourceName,
                normalizedBounds: PDFNormalizedRect(
                    x: (use.bounds.minX - cropBox.minX)
                        / cropBox.width,
                    y: (cropBox.maxY - use.bounds.maxY)
                        / cropBox.height,
                    width: use.bounds.width / cropBox.width,
                    height: use.bounds.height / cropBox.height
                ),
                pixelWidth: use.pixelWidth,
                pixelHeight: use.pixelHeight,
                jpegData: use.data,
                sourceStreamData: use.sourceStreamData,
                softMaskStreamData: use.softMaskStreamData,
                softMaskObjectNumber: softMaskObject?.number,
                softMaskGeneration: softMaskObject?.generation,
                storage: storage,
                sourceDigest: Self.digest(use.data),
                usageCount: usageCountByDigest[
                    Self.digest(use.data),
                    default: 0
                ]
            )
        }
        .sorted {
            if $0.normalizedBounds.y != $1.normalizedBounds.y {
                return $0.normalizedBounds.y
                    < $1.normalizedBounds.y
            }
            return $0.normalizedBounds.x
                < $1.normalizedBounds.x
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func scan(
        page: CGPDFPage,
        pageIndex: Int
    ) -> [PDFScannedImageUse] {
        scanReport(
            page: page,
            pageIndex: pageIndex
        ).uses
    }

    fileprivate func scanReport(
        page: CGPDFPage,
        pageIndex: Int
    ) -> PDFImagePageScan {
        guard let pageDictionary = page.dictionary else {
            return PDFImagePageScan(
                uses: [],
                encounteredImageCount: 0,
                unsupportedImageCount: 0,
                omittedImageCount: 0
            )
        }
        var resources: CGPDFDictionaryRef?
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            pageDictionary,
            "Resources",
            &resources
        ),
              let resources,
              CGPDFDictionaryGetDictionary(
                  resources,
                  "XObject",
                  &xObjects
              ),
              let xObjects
        else {
            return PDFImagePageScan(
                uses: [],
                encounteredImageCount: 0,
                unsupportedImageCount: 0,
                omittedImageCount: 0
            )
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        let state = PDFImageScanState(
            pageIndex: pageIndex,
            cropBox: page.getBoxRect(.cropBox),
            resources: resources,
            xObjects: xObjects,
            contentStream: content
        )
        guard pdfScanContent(state) else {
            return PDFImagePageScan(
                uses: [],
                encounteredImageCount: 0,
                unsupportedImageCount: 0,
                omittedImageCount: 0
            )
        }
        return PDFImagePageScan(
            uses: state.uses,
            encounteredImageCount: state.encounteredImageCount,
            unsupportedImageCount: state.unsupportedImageCount,
            omittedImageCount: state.omittedImageCount
        )
    }
}

private struct PDFImageObjectReference {
    let number: Int
    let generation: Int
    let offset: Int
}

private func pdfObjectDictionary(_ objectData: Data) -> String? {
    guard let range = pdfFirstDictionaryRange(in: objectData)
    else { return nil }
    return String(
        decoding: objectData[range],
        as: UTF8.self
    )
}

private func pdfObjectReference(
    following key: String,
    in objectData: Data
) -> (number: Int, generation: Int)? {
    guard let dictionary = pdfObjectDictionary(objectData),
          let keyRange = dictionary.range(of: key)
    else { return nil }
    let tokens = dictionary[keyRange.upperBound...]
        .split(whereSeparator: \.isWhitespace)
    guard tokens.count >= 3,
          let number = Int(tokens[0]),
          let generation = Int(tokens[1]),
          tokens[2] == "R"
    else { return nil }
    return (number, generation)
}

private func pdfInflatedObjectStream(
    _ objectData: Data
) -> Data? {
    guard let dictionary = pdfObjectDictionary(objectData),
          dictionary.contains("/Subtype /Image"),
          dictionary.contains("/Filter /FlateDecode")
            || dictionary.contains("/Filter/FlateDecode")
            || dictionary.contains("/Filter /Fl"),
          !dictionary.contains("/DecodeParms"),
          let length = pdfInteger(
              following: "/Length",
              in: dictionary
          ),
          length > 0,
          let streamMarker = objectData.range(
              of: Data("stream".utf8)
          )
    else { return nil }
    let start: Int
    if streamMarker.upperBound < objectData.count,
       objectData[streamMarker.upperBound] == 0x0d {
        start = streamMarker.upperBound + (
            streamMarker.upperBound + 1 < objectData.count
                && objectData[streamMarker.upperBound + 1] == 0x0a
                ? 2
                : 1
        )
    } else if streamMarker.upperBound < objectData.count,
              objectData[streamMarker.upperBound] == 0x0a {
        start = streamMarker.upperBound + 1
    } else {
        return nil
    }
    guard start >= 0,
          length <= objectData.count - start
    else { return nil }
    let encoded = Data(objectData[start..<(start + length)])
    guard encoded.count > 6 else { return nil }
    let raw = Data(encoded.dropFirst(2).dropLast(4))
    return try? (raw as NSData)
        .decompressed(using: .zlib) as Data
}

private func pdfInteger(
    following key: String,
    in value: String
) -> Int? {
    guard let keyRange = value.range(of: key) else { return nil }
    return value[keyRange.upperBound...]
        .split(whereSeparator: { !$0.isNumber })
        .compactMap { Int($0) }
        .first
}

private func pdfUTF16HexString(_ value: String) -> String {
    var bytes: [UInt8] = [0xfe, 0xff]
    bytes.reserveCapacity(2 + value.utf16.count * 2)
    for codeUnit in value.utf16 {
        bytes.append(UInt8((codeUnit >> 8) & 0xff))
        bytes.append(UInt8(codeUnit & 0xff))
    }
    return "<"
        + bytes.map { String(format: "%02X", $0) }.joined()
        + ">"
}

private func pdfCatalogObject(
    _ objectData: Data,
    replacingPageLabelsWith pageLabels: Data
) throws -> Data {
    guard let endObject = objectData.range(
              of: Data("endobj".utf8),
              options: .backwards
          )?.upperBound
    else {
        throw PaperPathError.outputVerificationFailed(
            "the PDF catalog object is malformed"
        )
    }
    var result = Data(objectData[..<endObject])
    guard let dictionaryRange = pdfFirstDictionaryRange(in: result)
    else {
        throw PaperPathError.outputVerificationFailed(
            "the PDF catalog dictionary is missing"
        )
    }
    if let valueRange = pdfTopLevelValueRange(
        for: "PageLabels",
        in: result,
        dictionaryRange: dictionaryRange
    ) {
        result.replaceSubrange(valueRange, with: pageLabels)
    } else {
        let insertion = dictionaryRange.upperBound - 2
        var entry = Data("\n/PageLabels ".utf8)
        entry.append(pageLabels)
        entry.append(0x0a)
        result.insert(contentsOf: entry, at: insertion)
    }
    return result
}

private func pdfObject(
    _ objectData: Data,
    setting key: String,
    to value: Data
) throws -> Data {
    guard let endObject = objectData.range(
        of: Data("endobj".utf8),
        options: .backwards
    )?.upperBound
    else {
        throw PaperPathError.outputVerificationFailed(
            "a PDF form object is malformed"
        )
    }
    var result = Data(objectData[..<endObject])
    guard let dictionaryRange = pdfFirstDictionaryRange(in: result)
    else {
        throw PaperPathError.outputVerificationFailed(
            "a PDF form dictionary is missing"
        )
    }
    if let valueRange = pdfTopLevelValueRange(
        for: key,
        in: result,
        dictionaryRange: dictionaryRange
    ) {
        result.replaceSubrange(valueRange, with: value)
    } else {
        let insertion = dictionaryRange.upperBound - 2
        var entry = Data("\n/\(key) ".utf8)
        entry.append(value)
        entry.append(0x0a)
        result.insert(contentsOf: entry, at: insertion)
    }
    return result
}

private func pdfObject(
    _ objectData: Data,
    removing key: String
) throws -> Data {
    guard let endObject = objectData.range(
        of: Data("endobj".utf8),
        options: .backwards
    )?.upperBound
    else {
        throw PaperPathError.outputVerificationFailed(
            "a PDF form object is malformed"
        )
    }
    var result = Data(objectData[..<endObject])
    guard let dictionaryRange = pdfFirstDictionaryRange(in: result)
    else {
        throw PaperPathError.outputVerificationFailed(
            "a PDF form dictionary is missing"
        )
    }
    guard let valueRange = pdfTopLevelValueRange(
        for: key,
        in: result,
        dictionaryRange: dictionaryRange
    ) else {
        return result
    }
    let keyData = Data("/\(key)".utf8)
    var keyEnd = valueRange.lowerBound
    while keyEnd > dictionaryRange.lowerBound + 2,
          pdfIsWhitespace(result[keyEnd - 1]) {
        keyEnd -= 1
    }
    guard keyEnd >= keyData.count else {
        throw PaperPathError.outputVerificationFailed(
            "a PDF form dictionary entry is malformed"
        )
    }
    let keyStart = keyEnd - keyData.count
    guard result[keyStart..<keyEnd].elementsEqual(keyData) else {
        throw PaperPathError.outputVerificationFailed(
            "a PDF form dictionary key could not be isolated"
        )
    }
    result.removeSubrange(keyStart..<valueRange.upperBound)
    return result
}

private func pdfTopLevelString(
    for key: String,
    in objectData: Data
) -> String? {
    guard let dictionaryRange = pdfFirstDictionaryRange(
        in: objectData
    ),
          let valueRange = pdfTopLevelValueRange(
              for: key,
              in: objectData,
              dictionaryRange: dictionaryRange
          )
    else { return nil }
    return pdfDecodedString(Data(objectData[valueRange]))
}

private func pdfDecodedString(_ value: Data) -> String? {
    guard let first = value.first, let last = value.last else {
        return nil
    }
    var bytes: [UInt8] = []
    if first == 0x3c, last == 0x3e {
        let hexadecimal = value.dropFirst().dropLast().filter {
            !pdfIsWhitespace($0)
        }
        guard hexadecimal.allSatisfy({
            (0x30...0x39).contains($0)
                || (0x41...0x46).contains($0)
                || (0x61...0x66).contains($0)
        }) else { return nil }
        var characters = Array(hexadecimal)
        if !characters.count.isMultiple(of: 2) {
            characters.append(0x30)
        }
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(
            from: 0,
            to: characters.count,
            by: 2
        ) {
            guard let byte = UInt8(
                String(
                    bytes: characters[index...index + 1],
                    encoding: .ascii
                ) ?? "",
                radix: 16
            ) else { return nil }
            bytes.append(byte)
        }
    } else if first == 0x28, last == 0x29 {
        let source = Array(value.dropFirst().dropLast())
        var index = 0
        while index < source.count {
            let byte = source[index]
            guard byte == 0x5c else {
                bytes.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < source.count else { return nil }
            let escaped = source[index]
            switch escaped {
            case 0x6e: bytes.append(0x0a)
            case 0x72: bytes.append(0x0d)
            case 0x74: bytes.append(0x09)
            case 0x62: bytes.append(0x08)
            case 0x66: bytes.append(0x0c)
            case 0x28, 0x29, 0x5c:
                bytes.append(escaped)
            case 0x0a:
                break
            case 0x0d:
                if index + 1 < source.count,
                   source[index + 1] == 0x0a {
                    index += 1
                }
            case 0x30...0x37:
                var octal = Int(escaped - 0x30)
                var consumed = 1
                while consumed < 3,
                      index + 1 < source.count,
                      (0x30...0x37).contains(source[index + 1]) {
                    index += 1
                    consumed += 1
                    octal = octal * 8
                        + Int(source[index] - 0x30)
                }
                bytes.append(UInt8(octal & 0xff))
            default:
                bytes.append(escaped)
            }
            index += 1
        }
    } else {
        return nil
    }
    if bytes.starts(with: [0xfe, 0xff]) {
        let values = stride(
            from: 2,
            to: bytes.count - 1,
            by: 2
        ).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
        return String(decoding: values, as: UTF16.self)
    }
    if bytes.starts(with: [0xff, 0xfe]) {
        let values = stride(
            from: 2,
            to: bytes.count - 1,
            by: 2
        ).map {
            UInt16(bytes[$0 + 1]) << 8 | UInt16(bytes[$0])
        }
        return String(decoding: values, as: UTF16.self)
    }
    return String(bytes: bytes, encoding: .utf8)
        ?? String(bytes: bytes, encoding: .isoLatin1)
}

private func pdfFirstDictionaryRange(
    in data: Data
) -> Range<Int>? {
    guard let start = data.range(of: Data("<<".utf8))?.lowerBound,
          let end = pdfCompositeEnd(
              in: data,
              start: start,
              opening: (0x3c, 0x3c),
              closing: (0x3e, 0x3e)
          )
    else { return nil }
    return start..<end
}

private func pdfTopLevelValueRange(
    for key: String,
    in data: Data,
    dictionaryRange: Range<Int>
) -> Range<Int>? {
    let keyBytes = Array(key.utf8)
    var index = dictionaryRange.lowerBound + 2
    let limit = dictionaryRange.upperBound - 2
    var dictionaryDepth = 1
    var arrayDepth = 0

    while index < limit {
        let byte = data[index]
        if byte == 0x25 {
            index = pdfCommentEnd(in: data, start: index, limit: limit)
            continue
        }
        if byte == 0x28 {
            index = pdfLiteralStringEnd(
                in: data,
                start: index,
                limit: limit
            )
            continue
        }
        if byte == 0x3c,
           index + 1 < limit,
           data[index + 1] != 0x3c {
            index = pdfHexStringEnd(
                in: data,
                start: index,
                limit: limit
            )
            continue
        }
        if index + 1 < limit,
           byte == 0x3c,
           data[index + 1] == 0x3c {
            dictionaryDepth += 1
            index += 2
            continue
        }
        if index + 1 < limit,
           byte == 0x3e,
           data[index + 1] == 0x3e {
            dictionaryDepth -= 1
            index += 2
            continue
        }
        if byte == 0x5b {
            arrayDepth += 1
            index += 1
            continue
        }
        if byte == 0x5d {
            arrayDepth = max(0, arrayDepth - 1)
            index += 1
            continue
        }
        if byte == 0x2f,
           dictionaryDepth == 1,
           arrayDepth == 0 {
            let nameStart = index + 1
            var nameEnd = nameStart
            while nameEnd < limit,
                  !pdfIsDelimiter(data[nameEnd]) {
                nameEnd += 1
            }
            if nameEnd - nameStart == keyBytes.count,
               data[nameStart..<nameEnd].elementsEqual(keyBytes) {
                let valueStart = pdfSkipWhitespaceAndComments(
                    in: data,
                    start: nameEnd,
                    limit: limit
                )
                guard valueStart < limit,
                      let valueEnd = pdfObjectValueEnd(
                          in: data,
                          start: valueStart,
                          limit: limit
                      )
                else { return nil }
                return valueStart..<valueEnd
            }
            index = nameEnd
            continue
        }
        index += 1
    }
    return nil
}

private func pdfObjectValueEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int? {
    guard start < limit else { return nil }
    if data[start] == 0x3c,
       start + 1 < limit,
       data[start + 1] == 0x3c {
        return pdfCompositeEnd(
            in: data,
            start: start,
            opening: (0x3c, 0x3c),
            closing: (0x3e, 0x3e),
            limit: limit
        )
    }
    if data[start] == 0x5b {
        return pdfArrayEnd(
            in: data,
            start: start,
            limit: limit
        )
    }
    if data[start] == 0x28 {
        return pdfLiteralStringEnd(
            in: data,
            start: start,
            limit: limit
        )
    }
    if data[start] == 0x3c {
        return pdfHexStringEnd(
            in: data,
            start: start,
            limit: limit
        )
    }

    let firstEnd = pdfTokenEnd(
        in: data,
        start: start,
        limit: limit
    )
    guard firstEnd > start else { return nil }
    let first = String(
        decoding: data[start..<firstEnd],
        as: UTF8.self
    )
    guard Int(first) != nil else { return firstEnd }
    let secondStart = pdfSkipWhitespaceAndComments(
        in: data,
        start: firstEnd,
        limit: limit
    )
    let secondEnd = pdfTokenEnd(
        in: data,
        start: secondStart,
        limit: limit
    )
    guard secondStart < secondEnd,
          Int(
              String(
                  decoding: data[secondStart..<secondEnd],
                  as: UTF8.self
              )
          ) != nil
    else { return firstEnd }
    let thirdStart = pdfSkipWhitespaceAndComments(
        in: data,
        start: secondEnd,
        limit: limit
    )
    let thirdEnd = pdfTokenEnd(
        in: data,
        start: thirdStart,
        limit: limit
    )
    if thirdStart < thirdEnd,
       data[thirdStart..<thirdEnd].elementsEqual([0x52]) {
        return thirdEnd
    }
    return firstEnd
}

private func pdfCompositeEnd(
    in data: Data,
    start: Int,
    opening: (UInt8, UInt8),
    closing: (UInt8, UInt8),
    limit: Int? = nil
) -> Int? {
    let upperBound = min(limit ?? data.count, data.count)
    guard start + 1 < upperBound,
          data[start] == opening.0,
          data[start + 1] == opening.1
    else { return nil }
    var depth = 1
    var index = start + 2
    while index < upperBound {
        if data[index] == 0x25 {
            index = pdfCommentEnd(
                in: data,
                start: index,
                limit: upperBound
            )
            continue
        }
        if data[index] == 0x28 {
            index = pdfLiteralStringEnd(
                in: data,
                start: index,
                limit: upperBound
            )
            continue
        }
        if data[index] == 0x3c,
           index + 1 < upperBound,
           data[index + 1] != 0x3c {
            index = pdfHexStringEnd(
                in: data,
                start: index,
                limit: upperBound
            )
            continue
        }
        guard index + 1 < upperBound else { break }
        if data[index] == opening.0,
           data[index + 1] == opening.1 {
            depth += 1
            index += 2
            continue
        }
        if data[index] == closing.0,
           data[index + 1] == closing.1 {
            depth -= 1
            index += 2
            if depth == 0 { return index }
            continue
        }
        index += 1
    }
    return nil
}

private func pdfArrayEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int? {
    guard start < limit, data[start] == 0x5b else { return nil }
    var depth = 1
    var index = start + 1
    while index < limit {
        if data[index] == 0x25 {
            index = pdfCommentEnd(
                in: data,
                start: index,
                limit: limit
            )
            continue
        }
        if data[index] == 0x28 {
            index = pdfLiteralStringEnd(
                in: data,
                start: index,
                limit: limit
            )
            continue
        }
        if data[index] == 0x3c,
           index + 1 < limit {
            if data[index + 1] == 0x3c,
               let end = pdfCompositeEnd(
                   in: data,
                   start: index,
                   opening: (0x3c, 0x3c),
                   closing: (0x3e, 0x3e),
                   limit: limit
               ) {
                index = end
                continue
            }
            index = pdfHexStringEnd(
                in: data,
                start: index,
                limit: limit
            )
            continue
        }
        if data[index] == 0x5b {
            depth += 1
        } else if data[index] == 0x5d {
            depth -= 1
            if depth == 0 { return index + 1 }
        }
        index += 1
    }
    return nil
}

private func pdfLiteralStringEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int {
    var depth = 1
    var index = start + 1
    while index < limit {
        if data[index] == 0x5c {
            index = min(limit, index + 2)
            continue
        }
        if data[index] == 0x28 {
            depth += 1
        } else if data[index] == 0x29 {
            depth -= 1
            if depth == 0 { return index + 1 }
        }
        index += 1
    }
    return limit
}

private func pdfHexStringEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int {
    var index = start + 1
    while index < limit {
        if data[index] == 0x3e { return index + 1 }
        index += 1
    }
    return limit
}

private func pdfCommentEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int {
    var index = start + 1
    while index < limit,
          data[index] != 0x0a,
          data[index] != 0x0d {
        index += 1
    }
    return index
}

private func pdfSkipWhitespaceAndComments(
    in data: Data,
    start: Int,
    limit: Int
) -> Int {
    var index = start
    while index < limit {
        if pdfIsWhitespace(data[index]) {
            index += 1
        } else if data[index] == 0x25 {
            index = pdfCommentEnd(
                in: data,
                start: index,
                limit: limit
            )
        } else {
            break
        }
    }
    return index
}

private func pdfTokenEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int {
    var index = start
    while index < limit, !pdfIsDelimiter(data[index]) {
        index += 1
    }
    return index
}

private func pdfIsWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x00
        || byte == 0x09
        || byte == 0x0a
        || byte == 0x0c
        || byte == 0x0d
        || byte == 0x20
}

private func pdfIsDelimiter(_ byte: UInt8) -> Bool {
    pdfIsWhitespace(byte)
        || byte == 0x28
        || byte == 0x29
        || byte == 0x3c
        || byte == 0x3e
        || byte == 0x5b
        || byte == 0x5d
        || byte == 0x7b
        || byte == 0x7d
        || byte == 0x2f
        || byte == 0x25
}

private enum PDFImageObjectDocument {
    case classic(PDFClassicXRefDocument)
    case xrefStream(PDFXRefStreamDocument)

    init(data: Data) throws {
        if let classic = try? PDFClassicXRefDocument(data: data) {
            self = .classic(classic)
        } else {
            self = .xrefStream(
                try PDFXRefStreamDocument(data: data)
            )
        }
    }

    func imageObject(
        matching imageData: Data
    ) -> PDFImageObjectReference? {
        switch self {
        case .classic(let document):
            return document.imageObject(matching: imageData)
        case .xrefStream(let document):
            return document.imageObject(matching: imageData)
        }
    }

    func imageObject(
        matchingDecodedStream streamData: Data
    ) -> PDFImageObjectReference? {
        switch self {
        case .classic(let document):
            return document.imageObject(
                matchingDecodedStream: streamData
            )
        case .xrefStream(let document):
            return document.imageObject(
                matchingDecodedStream: streamData
            )
        }
    }

    func referencedObject(
        following key: String,
        in object: PDFImageObjectReference
    ) -> PDFImageObjectReference? {
        switch self {
        case .classic(let document):
            return document.referencedObject(
                following: key,
                in: object
            )
        case .xrefStream(let document):
            return document.referencedObject(
                following: key,
                in: object
            )
        }
    }

    func replacingImageObject(
        _ object: PDFImageObjectReference,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> Data {
        switch self {
        case .classic(let document):
            return try document.replacingImageObject(
                object,
                jpegData: jpegData,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        case .xrefStream(let document):
            return try document.replacingImageObject(
                object,
                jpegData: jpegData,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    func replacingObject(
        _ object: PDFImageObjectReference,
        with replacement: Data
    ) throws -> Data {
        switch self {
        case .classic(let document):
            return try document.replacingObject(
                object,
                with: replacement
            )
        case .xrefStream(let document):
            return try document.replacingObject(
                object,
                with: replacement
            )
        }
    }

    func object(
        number: Int,
        generation: Int
    ) -> PDFImageObjectReference? {
        switch self {
        case .classic(let document):
            return document.object(
                number: number,
                generation: generation
            )
        case .xrefStream(let document):
            return document.object(
                number: number,
                generation: generation
            )
        }
    }

    func rootCatalogObject() -> PDFImageObjectReference? {
        switch self {
        case .classic(let document):
            return document.rootCatalogObject()
        case .xrefStream(let document):
            return document.rootCatalogObject()
        }
    }

    func objectData(
        for object: PDFImageObjectReference
    ) -> Data? {
        switch self {
        case .classic(let document):
            let data = document.objectData(for: object)
            return data.isEmpty ? nil : data
        case .xrefStream(let document):
            return document.objectData(for: object)
        }
    }

    func allObjects() -> [PDFImageObjectReference] {
        switch self {
        case .classic(let document):
            return document.allObjects()
        case .xrefStream(let document):
            return document.allObjects()
        }
    }
}

private struct PDFXRefStreamDocument {
    private struct Entry {
        let type: UInt64
        let field1: UInt64
        let field2: UInt64
    }

    private let data: Data
    private let startXRef: Int
    private let size: Int
    private let rootReference: String
    private let infoReference: String?
    private let xrefObjectNumber: Int
    private let xrefGeneration: Int
    private let entries: [Int: Entry]

    init(data: Data) throws {
        guard data.count > 64,
              data.prefix(8).starts(with: Data("%PDF-".utf8)),
              data.prefix(min(data.count, 2_048))
                .range(of: Data("/Linearized".utf8)) == nil,
              let startXRef = Self.startXRef(in: data),
              startXRef > 0,
              startXRef < data.count
        else {
            throw PaperPathError.insufficientSelection(
                "Image replacement requires a non-linearized PDF."
            )
        }
        let objectData = data[startXRef..<data.count]
        guard let streamMarker = objectData.range(
            of: Data("stream".utf8)
        ),
              let dictionary = Self.firstDictionary(
                  in: String(
                      decoding: objectData[..<streamMarker.lowerBound],
                      as: UTF8.self
                  )
              ),
              dictionary.contains("/Type /XRef"),
              !dictionary.contains("/Prev"),
              !dictionary.contains("/Encrypt"),
              !dictionary.contains("/DecodeParms"),
              dictionary.contains("/Filter /FlateDecode")
                || dictionary.contains("/Filter/FlateDecode")
                || dictionary.contains("/Filter /Fl"),
              let size = Self.integer(
                  following: "/Size",
                  in: dictionary
              ),
              size > 0,
              let length = Self.integer(
                  following: "/Length",
                  in: dictionary
              ),
              length > 0,
              let widths = Self.integerArray(
                  following: "/W",
                  in: dictionary
              ),
              widths.count == 3,
              widths.allSatisfy({ (0...8).contains($0) }),
              let rootReference = Self.reference(
                  following: "/Root",
                  in: dictionary
              )
        else {
            throw PaperPathError.insufficientSelection(
                "This cross-reference stream uses an unsupported structure."
            )
        }
        guard let dictionaryMarker = objectData.range(
            of: Data("<<".utf8)
        ) else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference dictionary is missing"
            )
        }
        let header = String(
            decoding: objectData[..<dictionaryMarker.lowerBound],
            as: UTF8.self
        )
        let headerNumbers = header
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard headerNumbers.count >= 2 else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream object header is invalid"
            )
        }
        let streamStart = Self.streamPayloadStart(
            after: streamMarker.upperBound,
            in: data
        )
        guard streamStart >= 0,
              length <= data.count - streamStart
        else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream length is invalid"
            )
        }
        let encoded = Data(
            data[streamStart..<(streamStart + length)]
        )
        guard let decoded = Self.inflateZlib(encoded) else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream could not be decoded"
            )
        }
        let indexValues = Self.integerArray(
            following: "/Index",
            in: dictionary
        ) ?? [0, size]
        guard indexValues.count.isMultiple(of: 2) else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference index is malformed"
            )
        }

        let recordWidth = widths.reduce(0, +)
        guard recordWidth > 0 else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference entry width is invalid"
            )
        }
        var cursor = 0
        var parsedEntries: [Int: Entry] = [:]
        for pairIndex in stride(
            from: 0,
            to: indexValues.count,
            by: 2
        ) {
            let first = indexValues[pairIndex]
            let count = indexValues[pairIndex + 1]
            guard first >= 0,
                  count >= 0,
                  count <= (decoded.count - cursor) / recordWidth
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the cross-reference entries are truncated"
                )
            }
            for itemIndex in 0..<count {
                let type = widths[0] == 0
                    ? UInt64(1)
                    : Self.bigEndianInteger(
                        decoded,
                        offset: cursor,
                        width: widths[0]
                    )
                cursor += widths[0]
                let field1 = Self.bigEndianInteger(
                    decoded,
                    offset: cursor,
                    width: widths[1]
                )
                cursor += widths[1]
                let field2 = Self.bigEndianInteger(
                    decoded,
                    offset: cursor,
                    width: widths[2]
                )
                cursor += widths[2]
                parsedEntries[first + itemIndex] = Entry(
                    type: type,
                    field1: field1,
                    field2: field2
                )
            }
        }
        let xrefObjectNumber = headerNumbers[0]
        let xrefGeneration = headerNumbers[1]
        guard xrefObjectNumber >= 0,
              xrefObjectNumber < size,
              parsedEntries[xrefObjectNumber]?.type == 1
        else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream does not index itself"
            )
        }
        self.data = data
        self.startXRef = startXRef
        self.size = size
        self.rootReference = rootReference
        self.infoReference = Self.reference(
            following: "/Info",
            in: dictionary
        )
        self.xrefObjectNumber = xrefObjectNumber
        self.xrefGeneration = xrefGeneration
        self.entries = parsedEntries
    }

    func imageObject(
        matching imageData: Data
    ) -> PDFImageObjectReference? {
        let ordered = uncompressedReferences
        let matches = ordered.enumerated().compactMap {
            index,
            entry -> PDFImageObjectReference? in
            let upperBound = index + 1 < ordered.count
                ? ordered[index + 1].offset
                : startXRef
            guard entry.offset < upperBound else { return nil }
            let objectData = data[entry.offset..<upperBound]
            guard objectData.range(of: imageData) != nil,
                  objectData.range(of: Data("/Subtype /Image".utf8))
                    != nil
            else { return nil }
            return entry
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func imageObject(
        matchingDecodedStream streamData: Data
    ) -> PDFImageObjectReference? {
        let matches = uncompressedReferences.filter { entry in
            guard let objectData = objectData(for: entry) else {
                return false
            }
            return pdfInflatedObjectStream(objectData) == streamData
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func referencedObject(
        following key: String,
        in object: PDFImageObjectReference
    ) -> PDFImageObjectReference? {
        guard let objectData = objectData(for: object),
              let reference = pdfObjectReference(
                  following: key,
                  in: objectData
              ),
              let entry = entries[reference.number],
              entry.type == 1,
              entry.field1 <= UInt64(Int.max)
        else { return nil }
        return PDFImageObjectReference(
            number: reference.number,
            generation: reference.generation,
            offset: Int(entry.field1)
        )
    }

    func rootCatalogObject() -> PDFImageObjectReference? {
        let tokens = rootReference
            .split(whereSeparator: \.isWhitespace)
        guard tokens.count == 3,
              let number = Int(tokens[0]),
              let generation = Int(tokens[1]),
              tokens[2] == "R"
        else { return nil }
        return object(number: number, generation: generation)
    }

    func allObjects() -> [PDFImageObjectReference] {
        uncompressedReferences
    }

    func replacingImageObject(
        _ object: PDFImageObjectReference,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> Data {
        let replacement = Self.jpegImageObject(
            number: object.number,
            generation: object.generation,
            jpegData: jpegData,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        return try replacingObject(object, with: replacement)
    }

    func replacingObject(
        _ object: PDFImageObjectReference,
        with replacement: Data
    ) throws -> Data {
        let ordered = uncompressedReferences
        let objectUpperBound = ordered.first(where: {
            $0.offset > object.offset
        })?.offset ?? startXRef
        guard object.offset < objectUpperBound,
              let endObject = data[object.offset..<objectUpperBound]
                .range(
                    of: Data("endobj".utf8),
                    options: .backwards
                )?.upperBound
        else {
            throw PaperPathError.outputVerificationFailed(
                "the source object boundaries could not be verified"
            )
        }
        var body = Data()
        body.append(data[..<object.offset])
        body.append(replacement)
        body.append(data[endObject..<startXRef])
        if body.last != 0x0a {
            body.append(0x0a)
        }
        let delta = replacement.count - (endObject - object.offset)
        let newXRefOffset = body.count
        let replacementEntries = rebuiltEntries(
            replacing: object,
            objectEnd: endObject,
            offsetDelta: delta,
            newXRefOffset: newXRefOffset
        )
        let xrefBytes = Self.xrefBytes(
            entries: replacementEntries,
            size: size
        )
        guard let compressed = Self.deflateZlib(xrefBytes) else {
            throw PaperPathError.storageFailure(
                "The rebuilt cross-reference stream could not be encoded."
            )
        }
        var optionalInfo = ""
        if let infoReference {
            optionalInfo = " /Info \(infoReference)"
        }
        let dictionary = """
        << /Type /XRef /Size \(size) /Root \(rootReference)\(optionalInfo) /W [1 8 4] /Index [0 \(size)] /Filter /FlateDecode /Length \(compressed.count) >>
        """
        body.append(
            Data(
                "\(xrefObjectNumber) \(xrefGeneration) obj\n\(dictionary)\nstream\n"
                    .utf8
            )
        )
        body.append(compressed)
        body.append(
            Data(
                """

                endstream
                endobj
                startxref
                \(newXRefOffset)
                %%EOF

                """.utf8
            )
        )
        return body
    }

    func object(
        number: Int,
        generation: Int
    ) -> PDFImageObjectReference? {
        guard let entry = entries[number],
              entry.type == 1,
              entry.field1 > 0,
              entry.field1 < UInt64(startXRef),
              entry.field1 <= UInt64(Int.max),
              entry.field2 == UInt64(generation)
        else { return nil }
        return PDFImageObjectReference(
            number: number,
            generation: generation,
            offset: Int(entry.field1)
        )
    }

    private var uncompressedReferences: [PDFImageObjectReference] {
        entries.compactMap { number, entry in
            guard entry.type == 1,
                  entry.field1 > 0,
                  entry.field1 < UInt64(startXRef),
                  entry.field1 <= UInt64(Int.max),
                  entry.field2 <= UInt64(Int.max)
            else { return nil }
            return PDFImageObjectReference(
                number: number,
                generation: Int(entry.field2),
                offset: Int(entry.field1)
            )
        }
        .sorted { $0.offset < $1.offset }
    }

    func objectData(
        for object: PDFImageObjectReference
    ) -> Data? {
        let ordered = uncompressedReferences
        let upperBound = ordered.first(where: {
            $0.offset > object.offset
        })?.offset ?? startXRef
        guard object.offset >= 0,
              object.offset < upperBound,
              upperBound <= data.count
        else { return nil }
        return Data(data[object.offset..<upperBound])
    }

    private func rebuiltEntries(
        replacing object: PDFImageObjectReference,
        objectEnd: Int,
        offsetDelta: Int,
        newXRefOffset: Int
    ) -> [Int: Entry] {
        var result = entries
        for (number, entry) in entries where entry.type == 1 {
            if number == xrefObjectNumber {
                result[number] = Entry(
                    type: 1,
                    field1: UInt64(newXRefOffset),
                    field2: UInt64(xrefGeneration)
                )
            } else if number == object.number {
                result[number] = Entry(
                    type: 1,
                    field1: UInt64(object.offset),
                    field2: UInt64(object.generation)
                )
            } else if entry.field1 >= UInt64(objectEnd) {
                let shifted = Int(entry.field1) + offsetDelta
                result[number] = Entry(
                    type: 1,
                    field1: UInt64(max(0, shifted)),
                    field2: entry.field2
                )
            }
        }
        return result
    }

    private static func xrefBytes(
        entries: [Int: Entry],
        size: Int
    ) -> Data {
        var result = Data()
        result.reserveCapacity(size * 13)
        for number in 0..<size {
            let entry = entries[number]
                ?? Entry(
                    type: 0,
                    field1: 0,
                    field2: number == 0 ? 65_535 : 0
                )
            appendBigEndian(entry.type, width: 1, to: &result)
            appendBigEndian(entry.field1, width: 8, to: &result)
            appendBigEndian(entry.field2, width: 4, to: &result)
        }
        return result
    }

    private static func jpegImageObject(
        number: Int,
        generation: Int,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Data {
        let header = """
        \(number) \(generation) obj
        << /Type /XObject /Subtype /Image /Width \(pixelWidth) /Height \(pixelHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true /Filter /DCTDecode /Length \(jpegData.count) >>
        stream
        """
        var result = Data((header + "\n").utf8)
        result.append(jpegData)
        result.append(Data("\nendstream\nendobj".utf8))
        return result
    }

    private static func startXRef(in data: Data) -> Int? {
        guard let marker = data.range(
            of: Data("startxref".utf8),
            options: .backwards
        ) else { return nil }
        let upperBound = min(data.count, marker.upperBound + 64)
        return String(
            decoding: data[marker.upperBound..<upperBound],
            as: UTF8.self
        )
        .split(whereSeparator: { !$0.isNumber })
        .compactMap { Int($0) }
        .first
    }

    private static func streamPayloadStart(
        after marker: Int,
        in data: Data
    ) -> Int {
        guard marker < data.count else { return -1 }
        if data[marker] == 0x0d {
            return marker + (
                marker + 1 < data.count
                    && data[marker + 1] == 0x0a
                    ? 2
                    : 1
            )
        }
        return data[marker] == 0x0a ? marker + 1 : -1
    }

    private static func firstDictionary(in value: String) -> String? {
        guard let start = value.range(of: "<<")?.lowerBound else {
            return nil
        }
        var index = start
        var depth = 0
        while index < value.endIndex {
            let next = value.index(after: index)
            if next < value.endIndex {
                let pair = value[index...next]
                if pair == "<<" {
                    depth += 1
                    index = value.index(after: next)
                    continue
                }
                if pair == ">>" {
                    depth -= 1
                    let end = value.index(after: next)
                    if depth == 0 {
                        return String(value[start..<end])
                    }
                    index = end
                    continue
                }
            }
            index = next
        }
        return nil
    }

    private static func integer(
        following key: String,
        in value: String
    ) -> Int? {
        guard let keyRange = value.range(of: key) else { return nil }
        return value[keyRange.upperBound...]
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first
    }

    private static func integerArray(
        following key: String,
        in value: String
    ) -> [Int]? {
        guard let keyRange = value.range(of: key),
              let open = value[keyRange.upperBound...]
                .firstIndex(of: "["),
              let close = value[open...].firstIndex(of: "]")
        else { return nil }
        return value[value.index(after: open)..<close]
            .split(whereSeparator: { !$0.isNumber && $0 != "-" })
            .compactMap { Int($0) }
    }

    private static func reference(
        following key: String,
        in value: String
    ) -> String? {
        guard let keyRange = value.range(of: key) else { return nil }
        let tokens = value[keyRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 3,
              Int(tokens[0]) != nil,
              Int(tokens[1]) != nil,
              tokens[2] == "R"
        else { return nil }
        return "\(tokens[0]) \(tokens[1]) R"
    }

    private static func bigEndianInteger(
        _ data: Data,
        offset: Int,
        width: Int
    ) -> UInt64 {
        guard width > 0,
              offset >= 0,
              width <= data.count - offset
        else { return 0 }
        var result: UInt64 = 0
        for index in 0..<width {
            result = (result << 8) | UInt64(data[offset + index])
        }
        return result
    }

    private static func appendBigEndian(
        _ value: UInt64,
        width: Int,
        to data: inout Data
    ) {
        guard width > 0 else { return }
        for shift in stride(
            from: (width - 1) * 8,
            through: 0,
            by: -8
        ) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let raw = Data(data.dropFirst(2).dropLast(4))
        return try? (raw as NSData)
            .decompressed(using: .zlib) as Data
    }

    private static func deflateZlib(_ data: Data) -> Data? {
        guard let raw = try? (data as NSData)
            .compressed(using: .zlib) as Data
        else { return nil }
        var result = Data([0x78, 0x9c])
        result.append(raw)
        var first: UInt32 = 1
        var second: UInt32 = 0
        for byte in data {
            first = (first + UInt32(byte)) % 65_521
            second = (second + first) % 65_521
        }
        let checksum = (second << 16) | first
        result.append(UInt8((checksum >> 24) & 0xff))
        result.append(UInt8((checksum >> 16) & 0xff))
        result.append(UInt8((checksum >> 8) & 0xff))
        result.append(UInt8(checksum & 0xff))
        return result
    }
}

private struct PDFCatalogStructureAppender {
    private let data: Data
    private let startXRef: Int
    private let size: Int
    private let trailerDictionary: String
    private let entries: [Int: PDFImageObjectReference]

    init(data: Data) throws {
        guard data.count > 32,
              data.prefix(8).starts(with: Data("%PDF-".utf8)),
              let marker = data.range(
                of: Data("startxref".utf8),
                options: .backwards
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF cross-reference table could not be located"
            )
        }
        let tailEnd = min(data.count, marker.upperBound + 64)
        let tail = String(
            decoding: data[marker.upperBound..<tailEnd],
            as: UTF8.self
        )
        guard let startXRef = tail
            .split(whereSeparator: { !$0.isNumber })
            .compactMap({ Int($0) })
            .first,
              startXRef > 0,
              startXRef < data.count
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF cross-reference offset is invalid"
            )
        }
        let xrefText = String(
            decoding: data[startXRef..<data.count],
            as: UTF8.self
        )
        var lines = xrefText.components(separatedBy: .newlines)
        guard !lines.isEmpty,
              lines.removeFirst().trimmingCharacters(
                in: .whitespaces
              ) == "xref"
        else {
            throw PaperPathError.insufficientSelection(
                "This PDF cannot safely preserve catalog structures."
            )
        }

        var parsedEntries: [Int: PDFImageObjectReference] = [:]
        var trailerLines: [String] = []
        while !lines.isEmpty {
            let line = lines.removeFirst()
                .trimmingCharacters(in: .whitespaces)
            if line == "trailer" {
                trailerLines = lines
                break
            }
            if line.isEmpty { continue }
            let header = line.split(whereSeparator: \.isWhitespace)
            guard header.count == 2,
                  let firstObject = Int(header[0]),
                  let count = Int(header[1]),
                  count >= 0,
                  lines.count >= count
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the PDF cross-reference table is malformed"
                )
            }
            for index in 0..<count {
                let fields = lines.removeFirst()
                    .split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3,
                      let offset = Int(fields[0]),
                      let generation = Int(fields[1])
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "a PDF cross-reference entry is malformed"
                    )
                }
                if fields[2] == "n" {
                    parsedEntries[firstObject + index] =
                        PDFImageObjectReference(
                            number: firstObject + index,
                            generation: generation,
                            offset: offset
                        )
                }
            }
        }
        let trailerText = trailerLines.joined(separator: "\n")
        guard let trailer = Self.firstDictionary(in: trailerText),
              let parsedSize = Self.signedInteger(
                  following: "/Size",
                  in: trailer
              ),
              parsedSize > 0,
              parsedEntries.values.allSatisfy({
                  $0.offset > 0 && $0.offset < startXRef
              })
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF trailer is malformed"
            )
        }
        self.data = data
        self.startXRef = startXRef
        self.size = parsedSize
        self.trailerDictionary = trailer
        self.entries = parsedEntries
    }

    func appending(
        attachmentPayloads: [PDFEmbeddedAttachmentPayload],
        pageLabels: [PDFPageLabelSnapshot],
        encryptionPassword: String? = nil
    ) throws -> Data {
        let explicitLabels = pageLabels.filter(\.isExplicit)
        guard !attachmentPayloads.isEmpty || !explicitLabels.isEmpty else {
            return data
        }
        guard attachmentPayloads.allSatisfy({
            $0.snapshot.origin == .document
                && $0.data != nil
        }) else {
            throw PaperPathError.insufficientSelection(
                "This PDF contains attachment structures that cannot be safely preserved."
            )
        }
        let rootReference = try reference(
            following: "/Root",
            in: trailerDictionary
        )
        guard let rootEntry = entries[rootReference.number],
              rootEntry.generation == rootReference.generation
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF catalog reference is invalid"
            )
        }
        let encryption = try encryptionPassword.map {
            try encryptionContext(password: $0)
        }

        var nextObjectNumber = size
        func allocate() -> Int {
            defer { nextObjectNumber += 1 }
            return nextObjectNumber
        }
        var objects: [
            (
                number: Int,
                generation: Int,
                data: Data
            )
        ] = []
        var namesReference: Int?
        if !attachmentPayloads.isEmpty {
            var namesEntries: [String] = []
            for payload in attachmentPayloads {
                guard let attachmentData = payload.data else {
                    throw PaperPathError.outputVerificationFailed(
                        "an embedded file payload is unavailable"
                    )
                }
                let streamNumber = allocate()
                let fileSpecNumber = allocate()
                let encodedStream = try encryption?.encrypt(
                    attachmentData,
                    objectNumber: streamNumber,
                    generation: 0
                ) ?? attachmentData
                let contentType = Self.pdfName(
                    payload.snapshot.contentType
                        ?? "application/octet-stream"
                )
                var streamBody = Data(
                    """
                    << /Type /EmbeddedFile /Subtype /\(contentType) /Params << /Size \(attachmentData.count) >> /Length \(encodedStream.count) >>
                    stream

                    """.utf8
                )
                streamBody.append(encodedStream)
                streamBody.append(Data("\nendstream".utf8))
                objects.append(
                    (
                        streamNumber,
                        0,
                        Self.indirectObject(
                            number: streamNumber,
                            generation: 0,
                            body: streamBody
                        )
                    )
                )

                let fileName = try encodedString(
                    payload.snapshot.fileName,
                    objectNumber: fileSpecNumber,
                    encryption: encryption
                )
                let description = try encodedString(
                    payload.snapshot.description ?? "",
                    objectNumber: fileSpecNumber,
                    encryption: encryption
                )
                let fileSpecBody = Data(
                    """
                    << /Type /Filespec /F \(fileName) /UF \(fileName) /Desc \(description) /EF << /F \(streamNumber) 0 R /UF \(streamNumber) 0 R >> >>
                    """.utf8
                )
                objects.append(
                    (
                        fileSpecNumber,
                        0,
                        Self.indirectObject(
                            number: fileSpecNumber,
                            generation: 0,
                            body: fileSpecBody
                        )
                    )
                )
                namesEntries.append(
                    "\(payload.snapshot.fileName)|\(fileSpecNumber)"
                )
            }
            let namesNumber = allocate()
            let sortedNames = try namesEntries.sorted().map { entry in
                let components = entry.split(
                    separator: "|",
                    maxSplits: 1
                )
                guard components.count == 2,
                      let fileSpecNumber = Int(components[1])
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "an embedded file name could not be encoded"
                    )
                }
                let key = try encodedString(
                    String(components[0]),
                    objectNumber: namesNumber,
                    encryption: encryption
                )
                return "\(key) \(fileSpecNumber) 0 R"
            }
            let namesBody = Data(
                "<< /Names [\(sortedNames.joined(separator: " "))] >>"
                    .utf8
            )
            objects.append(
                (
                    namesNumber,
                    0,
                    Self.indirectObject(
                        number: namesNumber,
                        generation: 0,
                        body: namesBody
                    )
                )
            )
            namesReference = namesNumber
        }

        var pageLabelsReference: Int?
        if !explicitLabels.isEmpty {
            let labelsNumber = allocate()
            let entries = try explicitLabels
                .sorted { $0.pageIndex < $1.pageIndex }
                .map { label in
                    let value = try encodedString(
                        label.label,
                        objectNumber: labelsNumber,
                        encryption: encryption
                    )
                    return "\(label.pageIndex) << /P \(value) >>"
                }
            let labelsBody = Data(
                "<< /Nums [\(entries.joined(separator: " "))] >>"
                    .utf8
            )
            objects.append(
                (
                    labelsNumber,
                    0,
                    Self.indirectObject(
                        number: labelsNumber,
                        generation: 0,
                        body: labelsBody
                    )
                )
            )
            pageLabelsReference = labelsNumber
        }

        var rootObject = objectData(for: rootEntry)
        if let namesReference {
            let embeddedFiles = Data(
                "<< /EmbeddedFiles \(namesReference) 0 R >>".utf8
            )
            rootObject = try pdfObject(
                rootObject,
                setting: "Names",
                to: embeddedFiles
            )
        }
        if let pageLabelsReference {
            rootObject = try pdfObject(
                rootObject,
                setting: "PageLabels",
                to: Data("\(pageLabelsReference) 0 R".utf8)
            )
        }
        objects.append(
            (
                rootEntry.number,
                rootEntry.generation,
                rootObject
            )
        )

        var result = data
        if result.last != 0x0a {
            result.append(0x0a)
        }
        var offsets: [
            Int: (
                offset: Int,
                generation: Int
            )
        ] = [:]
        for object in objects {
            offsets[object.number] = (
                result.count,
                object.generation
            )
            result.append(object.data)
            if result.last != 0x0a {
                result.append(0x0a)
            }
        }
        let xrefOffset = result.count
        result.append(Data("xref\n".utf8))
        for number in offsets.keys.sorted() {
            guard let entry = offsets[number] else { continue }
            result.append(Data("\(number) 1\n".utf8))
            result.append(
                Data(
                    String(
                        format: "%010d %05d n \n",
                        entry.offset,
                        entry.generation
                    ).utf8
                )
            )
        }
        let updatedSize = max(
            size,
            (offsets.keys.max() ?? (size - 1)) + 1
        )
        var trailerObject = Data(
            "0 0 obj\n\(trailerDictionary)\nendobj".utf8
        )
        trailerObject = try pdfObject(
            trailerObject,
            setting: "Size",
            to: Data("\(updatedSize)".utf8)
        )
        trailerObject = try pdfObject(
            trailerObject,
            setting: "Prev",
            to: Data("\(startXRef)".utf8)
        )
        guard let updatedTrailer = pdfObjectDictionary(trailerObject)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the updated PDF trailer is malformed"
            )
        }
        result.append(
            Data(
                """
                trailer
                \(updatedTrailer)
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8
            )
        )
        return result
    }

    private func encryptionContext(
        password: String
    ) throws -> PDFAESV2EncryptionContext {
        let encryptionReference = try reference(
            following: "/Encrypt",
            in: trailerDictionary
        )
        guard let encryptionEntry = entries[
            encryptionReference.number
        ],
              encryptionEntry.generation
                == encryptionReference.generation,
              let dictionary = pdfObjectDictionary(
                  objectData(for: encryptionEntry)
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF encryption dictionary is unavailable"
            )
        }
        guard
              dictionary.contains("/V 4"),
              dictionary.contains("/R 4"),
              dictionary.contains("/CFM /AESV2"),
              let owner = Self.hexData(
                  following: "/O",
                  in: dictionary
              ),
              let permissions = Self.signedInteger(
                  following: "/P",
                  in: dictionary
              ),
              let identifier = Self.firstIdentifier(
                  in: trailerDictionary
              )
        else {
            throw PaperPathError.insufficientSelection(
                "This password format cannot preserve embedded structures."
            )
        }
        return PDFAESV2EncryptionContext(
            password: password,
            ownerEntry: owner,
            permissions: Int32(clamping: permissions),
            identifier: identifier,
            encryptMetadata:
                !dictionary.contains("/EncryptMetadata false")
        )
    }

    private func encodedString(
        _ value: String,
        objectNumber: Int,
        encryption: PDFAESV2EncryptionContext?
    ) throws -> String {
        let raw = Self.pdfStringData(value)
        let encoded = try encryption?.encrypt(
            raw,
            objectNumber: objectNumber,
            generation: 0
        ) ?? raw
        return "<\(Self.hex(encoded))>"
    }

    private func reference(
        following key: String,
        in dictionary: String
    ) throws -> (
        number: Int,
        generation: Int
    ) {
        let wrapped = Data(
            "0 0 obj\n\(dictionary)\nendobj".utf8
        )
        guard let reference = pdfObjectReference(
            following: key,
            in: wrapped
        ) else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF \(key) reference is missing"
            )
        }
        return reference
    }

    private func objectData(
        for entry: PDFImageObjectReference
    ) -> Data {
        let upperBound = entries.values
            .map(\.offset)
            .filter { $0 > entry.offset }
            .min() ?? startXRef
        guard entry.offset >= 0,
              entry.offset < upperBound,
              upperBound <= data.count
        else { return Data() }
        return Data(data[entry.offset..<upperBound])
    }

    private static func indirectObject(
        number: Int,
        generation: Int,
        body: Data
    ) -> Data {
        var result = Data(
            "\(number) \(generation) obj\n".utf8
        )
        result.append(body)
        result.append(Data("\nendobj\n".utf8))
        return result
    }

    private static func pdfStringData(_ value: String) -> Data {
        var bytes: [UInt8] = [0xfe, 0xff]
        bytes.reserveCapacity(2 + value.utf16.count * 2)
        for codeUnit in value.utf16 {
            bytes.append(UInt8((codeUnit >> 8) & 0xff))
            bytes.append(UInt8(codeUnit & 0xff))
        }
        return Data(bytes)
    }

    private static func pdfName(_ value: String) -> String {
        value.utf8.map { byte in
            let allowed = (0x21...0x7e).contains(byte)
                && ![0x23, 0x25, 0x28, 0x29, 0x2f, 0x3c, 0x3e,
                     0x5b, 0x5d, 0x7b, 0x7d].contains(byte)
            return allowed
                ? String(UnicodeScalar(byte))
                : String(format: "#%02X", byte)
        }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private static func hexData(
        following key: String,
        in dictionary: String
    ) -> Data? {
        guard let keyRange = dictionary.range(of: key),
              let start = dictionary[
                  keyRange.upperBound...
              ].firstIndex(of: "<"),
              let end = dictionary[start...].firstIndex(of: ">"),
              start < end
        else { return nil }
        let hex = dictionary[
            dictionary.index(after: start)..<end
        ].filter { !$0.isWhitespace }
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16)
            else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func firstIdentifier(
        in trailer: String
    ) -> Data? {
        guard let idRange = trailer.range(of: "/ID"),
              let start = trailer[
                  idRange.upperBound...
              ].firstIndex(of: "<"),
              let end = trailer[start...].firstIndex(of: ">"),
              start < end
        else { return nil }
        let hex = trailer[
            trailer.index(after: start)..<end
        ].filter { !$0.isWhitespace }
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16)
            else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func signedInteger(
        following key: String,
        in value: String
    ) -> Int? {
        guard let keyRange = value.range(of: key) else {
            return nil
        }
        let suffix = value[keyRange.upperBound...]
        guard let start = suffix.firstIndex(where: {
            $0 == "-" || $0.isNumber
        }) else { return nil }
        var end = value.index(after: start)
        while end < value.endIndex, value[end].isNumber {
            end = value.index(after: end)
        }
        return Int(value[start..<end])
    }

    private static func firstDictionary(
        in value: String
    ) -> String? {
        guard let start = value.range(of: "<<")?.lowerBound
        else { return nil }
        var index = start
        var depth = 0
        while index < value.endIndex {
            let next = value.index(after: index)
            if next < value.endIndex {
                let pair = value[index...next]
                if pair == "<<" {
                    depth += 1
                    index = value.index(after: next)
                    continue
                }
                if pair == ">>" {
                    depth -= 1
                    let end = value.index(after: next)
                    if depth == 0 {
                        return String(value[start..<end])
                    }
                    index = end
                    continue
                }
            }
            index = next
        }
        return nil
    }
}

private struct PDFAESV2EncryptionContext {
    private static let passwordPadding = Data([
        0x28, 0xbf, 0x4e, 0x5e, 0x4e, 0x75, 0x8a, 0x41,
        0x64, 0x00, 0x4e, 0x56, 0xff, 0xfa, 0x01, 0x08,
        0x2e, 0x2e, 0x00, 0xb6, 0xd0, 0x68, 0x3e, 0x80,
        0x2f, 0x0c, 0xa9, 0xfe, 0x64, 0x53, 0x69, 0x7a
    ])

    private let fileKey: Data

    init(
        password: String,
        ownerEntry: Data,
        permissions: Int32,
        identifier: Data,
        encryptMetadata: Bool
    ) {
        var padded = Data(password.data(using: .isoLatin1) ?? Data())
        if padded.count > 32 {
            padded = Data(padded.prefix(32))
        } else if padded.count < 32 {
            padded.append(
                Self.passwordPadding.prefix(32 - padded.count)
            )
        }
        var material = padded
        material.append(ownerEntry)
        var littleEndianPermissions = permissions.littleEndian
        withUnsafeBytes(of: &littleEndianPermissions) {
            material.append(contentsOf: $0)
        }
        material.append(identifier)
        if !encryptMetadata {
            material.append(contentsOf: [0xff, 0xff, 0xff, 0xff])
        }
        var digest = Data(Insecure.MD5.hash(data: material))
        for _ in 0..<50 {
            digest = Data(
                Insecure.MD5.hash(data: Data(digest.prefix(16)))
            )
        }
        fileKey = Data(digest.prefix(16))
    }

    func encrypt(
        _ data: Data,
        objectNumber: Int,
        generation: Int
    ) throws -> Data {
        var keyMaterial = fileKey
        keyMaterial.append(UInt8(objectNumber & 0xff))
        keyMaterial.append(UInt8((objectNumber >> 8) & 0xff))
        keyMaterial.append(UInt8((objectNumber >> 16) & 0xff))
        keyMaterial.append(UInt8(generation & 0xff))
        keyMaterial.append(UInt8((generation >> 8) & 0xff))
        keyMaterial.append(contentsOf: [0x73, 0x41, 0x6c, 0x54])
        let digest = Data(Insecure.MD5.hash(data: keyMaterial))
        let objectKey = Data(
            digest.prefix(min(fileKey.count + 5, 16))
        )
        var initializationVector = [UInt8](
            repeating: 0,
            count: kCCBlockSizeAES128
        )
        let randomStatus = initializationVector
            .withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(
                    kSecRandomDefault,
                    bytes.count,
                    bytes.baseAddress!
                )
            }
        guard randomStatus == errSecSuccess
        else {
            throw PaperPathError.storageFailure(
                "Secure PDF encryption could not initialize."
            )
        }
        var output = [UInt8](
            repeating: 0,
            count: data.count + kCCBlockSizeAES128
        )
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            objectKey.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    data.withUnsafeBytes { dataBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            objectKey.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            outputBytes.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw PaperPathError.storageFailure(
                "A PDF structure could not be encrypted."
            )
        }
        var result = Data(initializationVector)
        result.append(contentsOf: output.prefix(outputLength))
        return result
    }
}

private struct PDFClassicXRefDocument {
    private let data: Data
    private let startXRef: Int
    private let size: Int
    private let trailerDictionary: String
    private let entries: [Int: PDFImageObjectReference]

    init(data: Data) throws {
        guard data.count > 32,
              data.prefix(8).starts(with: Data("%PDF-".utf8)),
              data.prefix(min(data.count, 2_048))
                .range(of: Data("/Linearized".utf8)) == nil,
              let marker = data.range(
                  of: Data("startxref".utf8),
                  options: .backwards
              )
        else {
            throw PaperPathError.insufficientSelection(
                "Image replacement supports non-linearized PDFs with a classic cross-reference table."
            )
        }
        let startTail = marker.upperBound
        let endTail = min(data.count, startTail + 64)
        let tail = String(
            decoding: data[startTail..<endTail],
            as: UTF8.self
        )
        guard let startXRef = tail
            .split(whereSeparator: { !$0.isNumber })
            .compactMap({ Int($0) })
            .first,
              startXRef >= 0,
              startXRef < data.count
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF cross-reference offset is invalid"
            )
        }
        let xrefText = String(
            decoding: data[startXRef..<data.count],
            as: UTF8.self
        )
        var lines = xrefText.components(separatedBy: .newlines)
        guard !lines.isEmpty,
              lines.removeFirst().trimmingCharacters(
                  in: .whitespaces
              ) == "xref"
        else {
            throw PaperPathError.insufficientSelection(
                "Image replacement does not rewrite compressed PDF object streams."
            )
        }

        var parsedEntries: [Int: PDFImageObjectReference] = [:]
        var trailerLines: [String] = []
        while !lines.isEmpty {
            let line = lines.removeFirst()
                .trimmingCharacters(in: .whitespaces)
            if line == "trailer" {
                trailerLines = lines
                break
            }
            if line.isEmpty { continue }
            let header = line.split(separator: " ")
            guard header.count == 2,
                  let firstObject = Int(header[0]),
                  let count = Int(header[1]),
                  count >= 0,
                  lines.count >= count
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the PDF cross-reference table is malformed"
                )
            }
            for index in 0..<count {
                let entryLine = lines.removeFirst()
                let fields = entryLine.split(separator: " ")
                guard fields.count >= 3,
                      let offset = Int(fields[0]),
                      let generation = Int(fields[1])
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "a PDF cross-reference entry is malformed"
                    )
                }
                if fields[2] == "n" {
                    let number = firstObject + index
                    parsedEntries[number] = PDFImageObjectReference(
                        number: number,
                        generation: generation,
                        offset: offset
                    )
                }
            }
        }
        let trailerText = trailerLines.joined(separator: "\n")
        guard let trailer = Self.firstDictionary(in: trailerText),
              !trailer.contains("/Prev"),
              !trailer.contains("/Encrypt"),
              !trailer.contains("/XRefStm"),
              let parsedSize = Self.integer(
                  following: "/Size",
                  in: trailer
              ),
              parsedSize > 0,
              parsedEntries.values.allSatisfy({
                  $0.offset > 0 && $0.offset < startXRef
              })
        else {
            throw PaperPathError.insufficientSelection(
                "Image replacement requires an unencrypted, single-revision classic PDF."
            )
        }
        self.data = data
        self.startXRef = startXRef
        self.size = parsedSize
        self.trailerDictionary = trailer
        self.entries = parsedEntries
    }

    func imageObject(
        matching jpegData: Data
    ) -> PDFImageObjectReference? {
        let ordered = entries.values.sorted { $0.offset < $1.offset }
        let matches = ordered.enumerated().compactMap {
            index, entry -> PDFImageObjectReference? in
            let upperBound = index + 1 < ordered.count
                ? ordered[index + 1].offset
                : startXRef
            guard entry.offset < upperBound else { return nil }
            return data[entry.offset..<upperBound]
                .range(of: jpegData) == nil
                ? nil
                : entry
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func imageObject(
        matchingDecodedStream streamData: Data
    ) -> PDFImageObjectReference? {
        let matches = entries.values.filter { entry in
            pdfInflatedObjectStream(objectData(for: entry))
                == streamData
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func referencedObject(
        following key: String,
        in object: PDFImageObjectReference
    ) -> PDFImageObjectReference? {
        guard let reference = pdfObjectReference(
            following: key,
            in: objectData(for: object)
        ),
              let entry = entries[reference.number],
              entry.generation == reference.generation
        else { return nil }
        return entry
    }

    func rootCatalogObject() -> PDFImageObjectReference? {
        guard let keyRange = trailerDictionary.range(of: "/Root")
        else { return nil }
        let tokens = trailerDictionary[keyRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 3,
              let number = Int(tokens[0]),
              let generation = Int(tokens[1]),
              tokens[2] == "R"
        else { return nil }
        return object(number: number, generation: generation)
    }

    func allObjects() -> [PDFImageObjectReference] {
        entries.values.sorted { $0.offset < $1.offset }
    }

    func replacingImageObject(
        _ object: PDFImageObjectReference,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> Data {
        let header = """
        \(object.number) \(object.generation) obj
        << /Type /XObject /Subtype /Image /Width \(pixelWidth) /Height \(pixelHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true /Filter /DCTDecode /Length \(jpegData.count) >>
        stream
        """
        var replacement = Data((header + "\n").utf8)
        replacement.append(jpegData)
        replacement.append(Data("\nendstream\nendobj".utf8))
        return try replacingObject(object, with: replacement)
    }

    func replacingObject(
        _ object: PDFImageObjectReference,
        with replacement: Data
    ) throws -> Data {
        let ordered = entries.values.sorted { $0.offset < $1.offset }
        let objectUpperBound = ordered.first(where: {
            $0.offset > object.offset
        })?.offset ?? startXRef
        guard object.offset < objectUpperBound,
              let endObjectRange = data[object.offset..<objectUpperBound]
                .range(
                    of: Data("endobj".utf8),
                    options: .backwards
                )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the source object boundaries could not be verified"
            )
        }
        let objectEnd = endObjectRange.upperBound
        var body = Data()
        body.append(data[..<object.offset])
        body.append(replacement)
        body.append(data[objectEnd..<startXRef])
        if body.last != 0x0a {
            body.append(0x0a)
        }
        let delta = replacement.count - (objectEnd - object.offset)
        let xrefOffset = body.count
        body.append(Data("xref\n0 \(size)\n".utf8))
        for number in 0..<size {
            if number == 0 {
                body.append(Data("0000000000 65535 f \n".utf8))
                continue
            }
            guard let entry = entries[number] else {
                body.append(Data("0000000000 00000 f \n".utf8))
                continue
            }
            let offset: Int
            if entry.number == object.number {
                offset = object.offset
            } else if entry.offset >= objectEnd {
                offset = entry.offset + delta
            } else {
                offset = entry.offset
            }
            body.append(
                Data(
                    String(
                        format: "%010d %05d n \n",
                        offset,
                        entry.generation
                    ).utf8
                )
            )
        }
        body.append(
            Data(
                """
                trailer
                \(trailerDictionary)
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8
            )
        )
        return body
    }

    func object(
        number: Int,
        generation: Int
    ) -> PDFImageObjectReference? {
        guard let entry = entries[number],
              entry.generation == generation
        else { return nil }
        return entry
    }

    private func dataForObject(
        _ object: PDFImageObjectReference
    ) -> Data {
        let orderedOffsets = entries.values.map(\.offset).sorted()
        let upperBound = orderedOffsets.first(where: {
            $0 > object.offset
        }) ?? startXRef
        let objectData = data[object.offset..<upperBound]
        guard let streamMarker = objectData.range(
            of: Data("stream".utf8)
        ) else { return Data() }
        let start: Int
        if objectData.indices.contains(streamMarker.upperBound),
           objectData[streamMarker.upperBound] == 0x0d {
            start = streamMarker.upperBound + (
                objectData.indices.contains(streamMarker.upperBound + 1)
                    && objectData[streamMarker.upperBound + 1] == 0x0a
                    ? 2
                    : 1
            )
        } else if objectData.indices.contains(streamMarker.upperBound),
                  objectData[streamMarker.upperBound] == 0x0a {
            start = streamMarker.upperBound + 1
        } else {
            return Data()
        }
        guard let end = objectData[start...].range(
            of: Data("endstream".utf8),
            options: .backwards
        )?.lowerBound else { return Data() }
        var result = Data(objectData[start..<end])
        while result.last == 0x0a || result.last == 0x0d {
            result.removeLast()
        }
        return result
    }

    func objectData(
        for object: PDFImageObjectReference
    ) -> Data {
        let upperBound = entries.values
            .map(\.offset)
            .filter { $0 > object.offset }
            .min() ?? startXRef
        guard object.offset >= 0,
              object.offset < upperBound,
              upperBound <= data.count
        else { return Data() }
        return Data(data[object.offset..<upperBound])
    }

    private static func firstDictionary(in value: String) -> String? {
        guard let start = value.range(of: "<<")?.lowerBound else {
            return nil
        }
        var index = start
        var depth = 0
        while index < value.endIndex {
            let next = value.index(after: index)
            if next < value.endIndex {
                let pair = value[index...next]
                if pair == "<<" {
                    depth += 1
                    index = value.index(after: next)
                    continue
                }
                if pair == ">>" {
                    depth -= 1
                    let end = value.index(after: next)
                    if depth == 0 {
                        return String(value[start..<end])
                    }
                    index = end
                    continue
                }
            }
            index = next
        }
        return nil
    }

    private static func integer(
        following key: String,
        in value: String
    ) -> Int? {
        guard let keyRange = value.range(of: key) else { return nil }
        return value[keyRange.upperBound...]
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first
    }
}
