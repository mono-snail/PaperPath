import CommonCrypto
import Compression
import CoreImage
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import Security
import UIKit
import UniformTypeIdentifiers
import zlib

typealias PDFProgressHandler = @Sendable (Double) -> Void

enum PDFCompressionMode: String, CaseIterable, Identifiable, Sendable {
    case preserveContent
    case optimizedImages
    case imageCopy

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preserveContent: return "Lossless"
        case .optimizedImages: return "High quality (lossy)"
        case .imageCopy: return "Image pages (lossy)"
        }
    }
    var detail: String {
        switch self {
        case .preserveContent:
            return "Keeps image pixels and resolution unchanged. Preserves text, links, forms, and notes. Savings depend on the file."
        case .optimizedImages:
            return "Lossy image compression. Keeps text, links, forms, and notes. Fine image detail may change; your original is kept."
        case .imageCopy:
            return "Lossy conversion: rebuilds pages as images. Removes search, links, forms, and editable notes."
        }
    }

}

struct PDFReplacementTextLayout {
    let font: UIFont
    let lineSpacing: CGFloat
    let lineCount: Int
    let regionTexts: [String]
}

struct PDFReplacementFlowMeasurement {
    let fits: Bool
    let lineCount: Int
    let regionTexts: [String]
    let consumedUTF16Length: Int
    let splitWordAtRegionBoundary: Bool
}

struct PDFReplacementLayoutAttempt {
    let layout: PDFReplacementTextLayout?
    let minimumFontSize: CGFloat
    let consumedUTF16Length: Int
    let splitWordAtRegionBoundary: Bool
}

private struct PDFExpectedLinkAnnotation {
    let pageIndex: Int
    let bounds: PDFNormalizedRect
    let url: URL
}

private struct PDFExpectedTextAnnotation {
    let bounds: PDFNormalizedRect
    let contents: String
}

private struct PDFContentOverlayValidation {
    let annotationAdditionsByPage: [Int: Int]
    let expectedLinksByPage: [Int: [PDFExpectedLinkAnnotation]]
    let expectedTextsByPage: [Int: [PDFExpectedTextAnnotation]]
}

struct PDFBookletSignaturePlan {
    let number: Int
    let startPageIndex: Int
    let sourcePageCount: Int
    let paddedPageCount: Int
}

struct PDFCompressionEstimate: Equatable, Sendable {
    let sourceByteCount: Int64
    let estimatedByteCount: Int64
    let sampledPageCount: Int

    var formattedSourceSize: String {
        ByteCountFormatter.string(
            fromByteCount: sourceByteCount,
            countStyle: .file
        )
    }

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: estimatedByteCount,
            countStyle: .file
        )
    }

    var isBeneficial: Bool {
        sourceByteCount > 0 && estimatedByteCount < sourceByteCount
    }

    var savingsPercent: Int? {
        guard isBeneficial else { return nil }
        return Int(
            (
                1
                    - Double(estimatedByteCount)
                    / Double(sourceByteCount)
            ) * 100
        )
    }

    var summary: String {
        if sampledPageCount == 0 {
            return "Measured after compression".localizedUI
        }
        if let savingsPercent {
            return AppLocalization.format(
                "About %lld%% smaller · sampled %lld page%@",
                savingsPercent,
                sampledPageCount,
                sampledPageCount == 1 ? "" : "s"
            )
        }
        return AppLocalization.format(
            "Sample estimate: %@ versus %@ original. Actual size may differ.",
            formattedSize,
            formattedSourceSize
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

private extension PDFPageImageExportPreset {
    var fileExtension: String {
        self == .png ? "png" : "jpg"
    }

    var uniformType: UTType {
        self == .png ? .png : .jpeg
    }

    var imageDestinationProperties: [CFString: Any] {
        switch self {
        case .png:
            return [:]
        case .jpegHigh:
            return [
                kCGImageDestinationLossyCompressionQuality: 0.9
            ]
        case .jpegCompact:
            return [
                kCGImageDestinationLossyCompressionQuality: 0.68
            ]
        }
    }
}

struct PDFOutputService: @unchecked Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumTextExportPageBytes =
        4 * 1_024 * 1_024
    private static let maximumTextExportBytes =
        16 * 1_024 * 1_024
    private static let maximumStructuralRewriteBytes =
        128 * 1_024 * 1_024
    private static let maximumImageExportSourceBytes =
        1_024 * 1_024 * 1_024
    private static let maximumPageImageExportCount = 1_000
    private static let maximumPageImagePixels = 16_000_000
    private static let maximumPageImageBytes = 64 * 1_024 * 1_024
    private static let maximumPageImageExportBytes =
        512 * 1_024 * 1_024
    private static let maximumAnnotationsPerPage = 4_096
    private static let maximumAnnotationsScanned = 100_000

    private static func checkedProduct(
        _ left: Int,
        _ right: Int
    ) -> Int? {
        let result = left.multipliedReportingOverflow(by: right)
        return result.overflow ? nil : result.partialValue
    }

    private static func requireSupportedPageCount(
        _ pageCount: Int
    ) throws {
        guard pageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        guard pageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Process PDFs with up to 100,000 pages at a time."
            )
        }
    }

    private static func requireUnchangedSource(
        at url: URL,
        initialValues: URLResourceValues
    ) throws {
        let finalValues = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              finalValues.fileSize == initialValues.fileSize,
              finalValues.contentModificationDate
                == initialValues.contentModificationDate,
              fileResourceIdentifiersMatch(
                initialValues.fileResourceIdentifier,
                finalValues.fileResourceIdentifier
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the source PDF changed during image rendering"
            )
        }
    }

    private static func fileResourceIdentifiersMatch(
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

    private func requireStructuralRewriteFile(
        at url: URL
    ) throws {
        try Task.checkCancellation()
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= Self.maximumStructuralRewriteBytes
        else {
            throw PaperPathError.insufficientSelection(
                "This structure-preserving update supports PDFs up to 128 MB to protect device memory."
            )
        }
    }

    private func fileSHA256(
        at url: URL,
        expectedByteCount: Int
    ) throws -> String {
        guard expectedByteCount > 0 else {
            throw PaperPathError.outputVerificationFailed(
                "an exported file has an invalid size"
            )
        }
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == expectedByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "an exported file did not retain its encoded size"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var totalByteCount = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576)
                ?? Data()
            guard !chunk.isEmpty else { break }
            let (nextTotal, overflow) = totalByteCount
                .addingReportingOverflow(chunk.count)
            guard !overflow, nextTotal <= expectedByteCount else {
                throw PaperPathError.outputVerificationFailed(
                    "an exported file exceeded its encoded size"
                )
            }
            totalByteCount = nextTotal
            hasher.update(data: chunk)
        }
        guard totalByteCount == expectedByteCount else {
            throw PaperPathError.outputVerificationFailed(
                "an exported file did not retain its encoded size"
            )
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func requireTemporaryWriteCapacity(
        at destinationURL: URL,
        byteCount: Int
    ) throws {
        guard byteCount > 0 else {
            throw PaperPathError.outputVerificationFailed(
                "an exported file has an invalid size"
            )
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        let values = try parentURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available =
                values.volumeAvailableCapacityForImportantUsage
        else { return }
        let required = Int64(byteCount)
            .addingReportingOverflow(16 * 1_024 * 1_024)
        guard !required.overflow,
              available >= required.partialValue
        else {
            throw PaperPathError.insufficientStorage
        }
    }

    private func writeProtectedData(
        _ data: Data,
        to stagingURL: URL,
        fileManager: FileManager
    ) throws {
        guard !data.isEmpty,
              !fileManager.fileExists(atPath: stagingURL.path),
              fileManager.createFile(
                  atPath: stagingURL.path,
                  contents: nil,
                  attributes: [
                      .protectionKey: FileProtectionType.complete
                  ]
              )
        else {
            throw PaperPathError.storageFailure(
                "The image export temporary file could not be created."
            )
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: stagingURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        do {
            var offset = data.startIndex
            while offset < data.endIndex {
                try Task.checkCancellation()
                let end = data.index(
                    offset,
                    offsetBy: min(
                        1_048_576,
                        data.distance(from: offset, to: data.endIndex)
                    )
                )
                try output.write(contentsOf: data[offset..<end])
                offset = end
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

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
        try Self.requireSupportedPageCount(document.pageCount)
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
            let pageAnnotationCount = page.annotations.count
            guard pageAnnotationCount
                    <= Self.maximumAnnotationsPerPage
            else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to prepare safely."
                )
            }
            let (nextAnnotationCount, overflow) = annotationCount
                .addingReportingOverflow(pageAnnotationCount)
            guard !overflow,
                  nextAnnotationCount
                    <= Self.maximumAnnotationsScanned
            else {
                throw PaperPathError.insufficientSelection(
                    "The booklet annotation count exceeded the safe local limit."
                )
            }
            annotationCount = nextAnnotationCount
        }
        let signaturePlans = bookletSignaturePlans(
            sourcePageCount: document.pageCount,
            options: normalizedOptions
        )
        var paddedPageCount = 0
        for plan in signaturePlans {
            let (nextPageCount, overflow) = paddedPageCount
                .addingReportingOverflow(plan.paddedPageCount)
            guard !overflow else {
                throw PaperPathError.insufficientSelection(
                    "The booklet page plan exceeded the safe local limit."
                )
            }
            paddedPageCount = nextPageCount
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

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure(
                "The booklet destination already exists."
            )
        }
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".booklet-\(UUID().uuidString).pdf"
            )
        var publishedDestination = false
        var completed = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if publishedDestination, !completed {
                try? fileManager.removeItem(at: destination)
            }
        }
        guard let consumer = CGDataConsumer(
            url: stagingURL as CFURL
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
        var didCloseContext = false
        defer {
            if !didCloseContext {
                context.closePDF()
            }
        }

        var lastReportedPercent = -1
        progress(0.02)
        for (offset, spread) in assessment.spreads.enumerated() {
            try Task.checkCancellation()
            let sheetBounds = CGRect(
                x: 0,
                y: 0,
                width: spread.sheetWidth,
                height: spread.sheetHeight
            )
            guard Self.hasValidPageBounds(sheetBounds) else {
                throw PaperPathError.outputVerificationFailed(
                    "a booklet sheet has invalid geometry"
                )
            }
            let pageInfo = [
                kCGPDFContextMediaBox as String: pdfPageBoxData(sheetBounds),
                kCGPDFContextCropBox as String: pdfPageBoxData(sheetBounds)
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
            let fraction = 0.84 * Double(offset + 1)
                / Double(assessment.spreads.count)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        context.closePDF()
        didCloseContext = true
        try Task.checkCancellation()
        try LocalFileSecurity.requireCompleteProtection(to: stagingURL)

        guard let output = PDFDocument(url: stagingURL),
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
            guard Self.hasValidPageBounds(bounds),
            abs(
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
            let fraction = 0.84
                + 0.14 * Double(pageIndex + 1)
                / Double(output.pageCount)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        let outputByteCount = try stagingURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard outputByteCount > 0,
              outputByteCount <= 1_024 * 1_024 * 1_024
        else {
            throw PaperPathError.fileTooLarge
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: stagingURL, to: destination)
        publishedDestination = true
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        LocalFileSecurity.excludeFromBackup(destination)
        completed = true
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
            guard Self.hasValidPageBounds(bounds) else {
                throw PaperPathError.invalidPage
            }
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
            let pageAnnotationCount = page.annotations.count
            guard pageAnnotationCount
                    <= Self.maximumAnnotationsPerPage
            else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too many annotations to prepare safely."
                )
            }
            let (nextAnnotationCount, overflow) = annotationCount
                .addingReportingOverflow(pageAnnotationCount)
            guard !overflow,
                  nextAnnotationCount
                    <= Self.maximumAnnotationsScanned
            else {
                throw PaperPathError.insufficientSelection(
                    "The print annotation count exceeded the safe local limit."
                )
            }
            annotationCount = nextAnnotationCount
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
        guard Self.hasValidPageBounds(firstBounds) else {
            throw PaperPathError.invalidPage
        }
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

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure(
                "The print-ready destination already exists."
            )
        }
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".print-ready-\(UUID().uuidString).pdf"
            )
        var publishedDestination = false
        var completed = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if publishedDestination, !completed {
                try? fileManager.removeItem(at: destination)
            }
        }
        guard let consumer = CGDataConsumer(
            url: stagingURL as CFURL
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
        var didCloseContext = false
        defer {
            if !didCloseContext {
                context.closePDF()
            }
        }

        var lastReportedPercent = -1
        progress(0.02)
        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            let pageIndex = pageNumber - 1
            guard let sourcePage = source.page(at: pageNumber),
                  let kitPage = sourceDocument.page(at: pageIndex)
            else {
                throw PaperPathError.invalidPage
            }
            let bounds = kitPage.bounds(for: .cropBox)
            guard Self.hasValidPageBounds(bounds) else {
                throw PaperPathError.invalidPage
            }
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
            guard Self.hasValidPageBounds(pageBounds) else {
                throw PaperPathError.outputVerificationFailed(
                    "a print-ready page has invalid geometry"
                )
            }
            let pageInfo = [
                kCGPDFContextMediaBox as String: pdfPageBoxData(pageBounds),
                kCGPDFContextCropBox as String: pdfPageBoxData(pageBounds)
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
            let fraction = 0.84 * Double(pageNumber)
                / Double(source.numberOfPages)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        context.closePDF()
        didCloseContext = true
        try Task.checkCancellation()
        try LocalFileSecurity.requireCompleteProtection(to: stagingURL)
        progress(0.88)

        guard let output = PDFDocument(url: stagingURL),
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
            guard Self.hasValidPageBounds(sourceBounds) else {
                throw PaperPathError.invalidPage
            }
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
            guard Self.hasValidPageBounds(actual),
                  abs(Double(actual.width) - expected.outputWidth)
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
            let fraction = 0.88
                + 0.1 * Double(pageIndex + 1)
                / Double(output.pageCount)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        let outputByteCount = try stagingURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize ?? 0
        guard outputByteCount > 0,
              outputByteCount <= 1_024 * 1_024 * 1_024
        else {
            throw PaperPathError.fileTooLarge
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: stagingURL, to: destination)
        publishedDestination = true
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        LocalFileSecurity.excludeFromBackup(destination)
        completed = true
        progress(1)
    }

    func estimateCompression(
        sourceURL: URL,
        quality: PDFCompressionQuality,
        mode: PDFCompressionMode = .preserveContent
    ) throws -> PDFCompressionEstimate {
        try PDFCompressionExecutionGate.shared.enter()
        defer { PDFCompressionExecutionGate.shared.leave() }
        try Task.checkCancellation()
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let rawSourceByteCount = sourceValues.fileSize,
              rawSourceByteCount > 0,
              rawSourceByteCount
                <= Self.maximumImageExportSourceBytes
        else {
            throw PaperPathError.fileTooLarge
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= (mode != .imageCopy
                ? Self.maximumPageCount : Self.maximumPageImageExportCount)
        else {
            throw PaperPathError.insufficientSelection(
                "Compression supports PDFs up to 1,000 pages."
            )
        }
        let sourceByteCount = Int64(rawSourceByteCount)
        if mode != .imageCopy {
            // A page thumbnail cannot predict savings from embedded objects.
            // Return the current size as a neutral baseline, never a veto.
            return PDFCompressionEstimate(
                sourceByteCount: sourceByteCount,
                estimatedByteCount: sourceByteCount,
                sampledPageCount: 0
            )
        }
        let lastIndex = document.pageCount - 1
        let sampleIndices = Array(
            Set([0, lastIndex / 2, lastIndex])
        ).sorted()
        var encodedByteCount: Int64 = 0
        var sampledPageCount = 0

        for index in sampleIndices {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw PaperPathError.invalidPage
            }
            let byteCount: Int? = autoreleasepool {
                let bounds = page.bounds(for: .cropBox)
                guard Self.hasValidPageBounds(bounds) else {
                    return nil
                }
                let size = fittedSize(
                    rasterPageSize(page),
                    longestEdge: quality.longestEdge
                )
                return rasterPageImage(page, size: size)?
                    .jpegData(compressionQuality: quality.jpegQuality)?
                    .count
            }
            guard let byteCount else {
                throw PaperPathError.outputVerificationFailed(
                    "a sampled page could not be encoded for the compression estimate"
                )
            }
            let (nextByteCount, overflow) = encodedByteCount
                .addingReportingOverflow(Int64(byteCount))
            guard !overflow else {
                throw PaperPathError.insufficientSelection(
                    "The compression estimate exceeded the safe local limit."
                )
            }
            encodedByteCount = nextByteCount
            sampledPageCount += 1
        }

        guard sampledPageCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        let averagePageBytes = encodedByteCount
            / Int64(sampledPageCount)
        let pageCount = Int64(document.pageCount)
        let (encodedEstimate, encodedOverflow) = averagePageBytes
            .multipliedReportingOverflow(by: pageCount)
        let (overheadEstimate, overheadOverflow) = pageCount
            .multipliedReportingOverflow(by: 2_048)
        let (subtotal, subtotalOverflow) = encodedEstimate
            .addingReportingOverflow(overheadEstimate)
        let (estimatedByteCount, totalOverflow) = subtotal
            .addingReportingOverflow(8_192)
        guard !encodedOverflow,
              !overheadOverflow,
              !subtotalOverflow,
              !totalOverflow
        else {
            throw PaperPathError.insufficientSelection(
                "The compression estimate exceeded the safe local limit."
            )
        }
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

    func edgeInsets(
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

    func bleedAllowancePoints(
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

    func nearestDistance(
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

    func standardized(_ rect: CGRect) -> CGRect {
        rect.standardized
    }

    func rectsNearlyEqual(
        _ first: CGRect,
        _ second: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(first.minX - second.minX) <= tolerance
            && abs(first.minY - second.minY) <= tolerance
            && abs(first.width - second.width) <= tolerance
            && abs(first.height - second.height) <= tolerance
    }

    func normalizedBookletOptions(
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

    func bookletSignaturePlans(
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

    func bookletSpreads(
        signaturePlans: [PDFBookletSignaturePlan],
        pageSizes: [CGSize],
        options: PDFBookletOptions
    ) -> [PDFBookletSpread] {
        let target = options.paperTarget.portraitSize
            ?? PDFPrintPaperTarget.a4.portraitSize
            ?? (width: 595.28, height: 841.89)
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
        mode: PDFCompressionMode = .preserveContent,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try PDFCompressionExecutionGate.shared.enter()
        defer { PDFCompressionExecutionGate.shared.leave() }
        try Task.checkCancellation()
        if mode != .imageCopy {
            try compressPreservingContent(
                sourceURL: sourceURL, destination: destination,
                imageQuality: mode == .optimizedImages ? quality : nil,
                progress: progress
            )
            return
        }
        try renderRasterized(
            sourceURL: sourceURL,
            destination: destination,
            longestEdge: quality.longestEdge,
            jpegQuality: quality.jpegQuality,
            requiresSmallerOutput: true,
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
        try Task.checkCancellation()
        progress(0.08)
        guard (8...128).contains(password.count) else {
            throw PaperPathError.invalidPassword
        }
        guard sourceURL.standardizedFileURL
                != destination.standardizedFileURL
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate protected copy instead of replacing the source PDF."
            )
        }
        try requireStructuralRewriteFile(at: sourceURL)
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
        var didWriteDestination = false
        var didComplete = false
        defer {
            if didWriteDestination, !didComplete {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try PDFContentPreservingWriter.write(document, to: encryptedBase, sourceURLs: [sourceURL], options: options, password: password)
        try Task.checkCancellation()
        try requireStructuralRewriteFile(at: encryptedBase)
        let encryptedData = try Data(
            contentsOf: encryptedBase,
            options: .mappedIfSafe
        )
        try Task.checkCancellation()
        let protectedData: Data
        if attachmentPayloads.isEmpty,
           !pageLabels.contains(where: \.isExplicit) {
            protectedData = encryptedData
        } else {
            protectedData = try PDFCatalogStructureAppender(
                data: encryptedData
            ).appending(
                attachmentPayloads: attachmentPayloads,
                pageLabels: pageLabels,
                encryptionPassword: password
            )
        }
        try Task.checkCancellation()
        try protectedData.write(to: destination, options: .atomic)
        didWriteDestination = true
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        progress(0.92)
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        didComplete = true
        progress(1)
    }

    func removePassword(
        sourceURL: URL,
        destination: URL,
        password: String,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        try Task.checkCancellation()
        guard sourceURL.standardizedFileURL
                != destination.standardizedFileURL
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate editable copy when removing a password."
            )
        }
        try requireStructuralRewriteFile(at: sourceURL)
        guard !password.isEmpty,
              let document = PDFDocument(url: sourceURL),
              document.isLocked,
              document.unlock(withPassword: password),
              document.pageCount > 0
        else {
            throw PaperPathError.lockedPDF
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
        try PDFContentPreservingWriter.write(editableDocument, to: editableBase, sourceURLs: [sourceURL], sourcePassword: password)
        try Task.checkCancellation()
        try requireStructuralRewriteFile(at: editableBase)
        let editableData = try Data(
            contentsOf: editableBase,
            options: .mappedIfSafe
        )
        try Task.checkCancellation()
        let restoredData = try PDFCatalogStructureAppender(
            data: editableData
        ).appending(
            attachmentPayloads: attachmentPayloads,
            pageLabels: pageLabels
        )
        try Task.checkCancellation()
        try restoredData.write(to: destination, options: .atomic)
        try Task.checkCancellation()
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
            let canRender = autoreleasepool {
                guard let page = reopened.page(at: pageIndex) else {
                    return false
                }
                return page.thumbnail(
                    of: CGSize(width: 180, height: 240),
                    for: .cropBox
                ).cgImage != nil
            }
            guard canRender else {
                try? FileManager.default.removeItem(at: destination)
                throw PaperPathError.outputVerificationFailed(
                    "page \(pageIndex + 1) could not be reopened"
                )
            }
        }
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        try LocalFileSecurity.requireCompleteProtection(to: destination)
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
              source.numberOfPages == sourceDocument.pageCount,
              let firstPage = source.page(at: 1)
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(sourceDocument.pageCount)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path),
              let consumer = CGDataConsumer(url: destination as CFURL)
        else {
            throw PaperPathError.storageFailure(
                "The edited PDF destination could not be created."
            )
        }
        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: destination)
            }
        }
        let overlayValidation = try validateContentOverlays(
            overlays,
            pageCount: source.numberOfPages
        )

        var defaultBox = firstPage.getBoxRect(.mediaBox)
        guard Self.hasValidPageBounds(defaultBox) else {
            throw PaperPathError.invalidPage
        }
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            nil
        ) else {
            throw PaperPathError.storageFailure(
                "The edited PDF context could not be created."
            )
        }
        var didCloseContext = false
        defer {
            if !didCloseContext {
                context.closePDF()
            }
        }
        let overlaysByPage = Dictionary(
            grouping: overlays,
            by: \.pageIndex
        )
        var lastReportedPercent = -1
        progress(0.02)
        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: pageNumber) else {
                throw PaperPathError.invalidPage
            }
            let mediaBox = sourcePage.getBoxRect(.mediaBox)
            let cropBox = sourcePage.getBoxRect(.cropBox)
            guard Self.hasValidPageBounds(mediaBox),
                  Self.hasValidPageBounds(cropBox)
            else {
                throw PaperPathError.invalidPage
            }
            let pageInfo = [
                kCGPDFContextMediaBox as String: pdfPageBoxData(mediaBox),
                kCGPDFContextCropBox as String: pdfPageBoxData(cropBox)
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
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
            let fraction = 0.7 * Double(pageNumber)
                / Double(source.numberOfPages)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        context.closePDF()
        didCloseContext = true
        try Task.checkCancellation()

        guard let imageDocument = CGPDFDocument(destination as CFURL) else { throw PaperPathError.unreadablePDF }
        let outputDocument = sourceDocument
        let sourceAnnotationCounts = (0..<sourceDocument.pageCount).map { sourceDocument.page(at: $0)?.annotations.count ?? 0 }
        var imagePages: [Int: CGPDFPage] = [:]
        for (index, overlays) in overlaysByPage where overlays.contains(where: { if case .image = $0 { return true }; return false }) {
            if let page = imageDocument.page(at: index + 1) { imagePages[index] = page }
        }
        for pageIndex in 0..<sourceDocument.pageCount {
            try Task.checkCancellation()
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                  let outputPage = outputDocument.page(at: pageIndex)
            else {
                throw PaperPathError.outputVerificationFailed(
                    "an edited PDF page could not be reopened"
                )
            }
            let pageBounds = outputPage.bounds(for: .cropBox)
            guard Self.hasValidPageBounds(pageBounds) else {
                throw PaperPathError.outputVerificationFailed(
                    "an edited PDF page has invalid geometry"
                )
            }
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
            let fraction = 0.7
                + 0.22 * Double(pageIndex + 1)
                / Double(sourceDocument.pageCount)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        let finalizedURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-edited.pdf")
        defer { try? FileManager.default.removeItem(at: finalizedURL) }
        try withExtendedLifetime(imageDocument) {
            try PDFContentPreservingWriter.write(outputDocument, to: finalizedURL, sourceURLs: [sourceURL], imageOverlayPages: imagePages)
        }
        try LocalFileSecurity.requireCompleteProtection(to: finalizedURL)
        guard let finalizedDocument = PDFDocument(url: finalizedURL),
              !finalizedDocument.isLocked,
              finalizedDocument.pageCount == sourceDocument.pageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the finalized edited PDF could not be reopened"
            )
        }
        for pageIndex in 0..<finalizedDocument.pageCount {
            try Task.checkCancellation()
            guard let sourcePage = sourceDocument.page(at: pageIndex),
                  let page = finalizedDocument.page(at: pageIndex),
                  Self.hasValidPageBounds(page.bounds(for: .mediaBox)),
                  Self.hasValidPageBounds(page.bounds(for: .cropBox))
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a finalized edited PDF page has invalid geometry"
                )
            }
            let expectedAnnotationCount = sourceAnnotationCounts[pageIndex]
                + overlayValidation.annotationAdditionsByPage[
                    pageIndex,
                    default: 0
                ]
            guard page.annotations.count == expectedAnnotationCount else {
                throw PaperPathError.outputVerificationFailed(
                    "the finalized edited PDF did not preserve every annotation"
                )
            }
            for expectedLink in overlayValidation.expectedLinksByPage[
                pageIndex,
                default: []
            ] {
                guard hasExpectedLink(
                    expectedLink,
                    on: page
                ) else {
                    throw PaperPathError.outputVerificationFailed(
                        "an added web link did not preserve its verified target"
                    )
                }
            }
            for expectedText in overlayValidation.expectedTextsByPage[
                pageIndex,
                default: []
            ] {
                guard hasExpectedText(
                    expectedText,
                    on: page
                ) else {
                    throw PaperPathError.outputVerificationFailed(
                        "added text did not preserve its content or placement"
                    )
                }
            }
        }
        try Task.checkCancellation()
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: finalizedURL
        )
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        LocalFileSecurity.excludeFromBackup(destination)
        completed = true
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
        expectedLink: PDFLinkAnnotationSnapshot? = nil,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        let service = PDFMutationService()
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
        let sourceLinks = try service.links(
            in: sourceURL,
            pageIndex: identity.pageIndex
        )
        guard let sourceLink = sourceLinks.first(where: {
            $0.pageIndex == identity.pageIndex
                && $0.annotationIndex == identity.annotationIndex
        })
        else {
            throw PaperPathError.insufficientSelection(
                "The selected link changed before the copy was created."
            )
        }
        let expectedLinkMatches = expectedLink.map {
            $0 == sourceLink
        } ?? true
        guard expectedLinkMatches
        else {
            throw PaperPathError.insufficientSelection(
                "The selected link changed before the copy was created."
            )
        }
        try Task.checkCancellation()
        do {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: destination
            )
            try LocalFileSecurity.requireCompleteProtection(to: destination)
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
            let outputLinks = try service.links(
                in: destination,
                pageIndex: identity.pageIndex
            )
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
        guard sourceURL.standardizedFileURL.path
                != destination.standardizedFileURL.path
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate outlined copy instead of replacing the source PDF."
            )
        }
        guard pageIndices.count <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Bookmark up to 100,000 pages at a time."
            )
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)
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
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure(
                "The outlined PDF destination already exists."
            )
        }
        let stagingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".outlined-\(UUID().uuidString).pdf"
            )
        defer { try? fileManager.removeItem(at: stagingURL) }
        var publishedDestination = false
        var completed = false
        defer {
            if publishedDestination,
               !completed,
               fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
        }
        try PDFContentPreservingWriter.write(document, to: stagingURL, sourceURLs: [sourceURL])
        try LocalFileSecurity.requireCompleteProtection(to: stagingURL)
        guard let reopened = PDFDocument(url: stagingURL),
              reopened.pageCount == document.pageCount,
              let reopenedRoot = reopened.outlineRoot,
              (0..<reopenedRoot.numberOfChildren).contains(where: {
                  guard let candidate = reopenedRoot.child(at: $0)
                  else { return false }
                  return candidate.label == "PaperPath Bookmarks"
                      && candidate.numberOfChildren == pages.count
              })
        else {
            throw PaperPathError.outputVerificationFailed(
                "the embedded bookmark outline did not persist"
            )
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: stagingURL, to: destination)
        publishedDestination = true
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        LocalFileSecurity.excludeFromBackup(destination)
        completed = true
        progress(1)
    }

    func applyPageLabels(
        sourceURL: URL,
        destination: URL,
        rules: [PDFPageLabelRule],
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        guard sourceURL.standardizedFileURL
                != destination.standardizedFileURL
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate page-labeled copy instead of replacing the source PDF."
            )
        }
        try requireStructuralRewriteFile(at: sourceURL)
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        var didWriteDestination = false
        var didComplete = false
        defer {
            if didWriteDestination, !didComplete {
                try? FileManager.default.removeItem(at: destination)
            }
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
            try PDFContentPreservingWriter.write(document, to: normalizedURL, sourceURLs: [sourceURL])
            guard let normalized = PDFDocument(url: normalizedURL),
                  normalized.pageCount == document.pageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF structure cannot be normalized for page labels."
                )
            }
            try requireStructuralRewriteFile(at: normalizedURL)
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
        try Task.checkCancellation()
        try outputData.write(to: destination, options: .atomic)
        didWriteDestination = true
        try LocalFileSecurity.requireCompleteProtection(to: destination)

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
        didComplete = true
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
        guard sourceURL.standardizedFileURL
                != destination.standardizedFileURL
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate calculated-field copy instead of replacing the source PDF."
            )
        }
        try requireStructuralRewriteFile(at: sourceURL)
        var didWriteDestination = false
        var didComplete = false
        defer {
            if didWriteDestination, !didComplete {
                try? FileManager.default.removeItem(at: destination)
            }
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
        let structure = try PDFImageObjectDocument(
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

        var replacements: [PDFObjectReplacement] = []
        replacements.reserveCapacity(objectNumbers.count)
        for number in objectNumbers {
            try Task.checkCancellation()
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
                replacements.append(
                    PDFObjectReplacement(
                        object: object,
                        data: replacement
                    )
                )
            }
        }
        let outputData = replacements.isEmpty
            ? sourceData
            : try structure.replacingObjects(replacements)

        try Task.checkCancellation()
        try outputData.write(to: destination, options: .atomic)
        didWriteDestination = true
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        try Task.checkCancellation()
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
        didComplete = true
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

    func copyOutline(
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

    func validatedPageLabelRules(
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

    func pdfPageLabelDictionary(
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

    func expectedPageLabel(
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
              Self.hasSafeReplacementImageProperties(
                  replacementData
              ),
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
        try LocalFileSecurity.requireCompleteProtection(to: destination)

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
        let pageIndices = selection.pageIndices
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
        guard selection.lineCount <= 96,
              selection.flowRegions.count <= 16,
              pageIndices.count <= 4,
              selection.originalText.count <= 16_000,
              trimmed.count <= 16_000
        else {
            return blockedTextReplacement(
                "Limit each edit to 96 lines, 16 text boxes, 4 pages, and 16,000 characters.",
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        guard !pageIndices.isEmpty,
              !selection.flowRegions.isEmpty
        else {
            return blockedTextReplacement(
                "Select at least one complete text line before replacing text.",
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
        try Task.checkCancellation()
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked
        else {
            throw PaperPathError.unreadablePDF
        }
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
        guard selection.pageRotation % 360 == 0,
              pages.values.allSatisfy({ $0.rotation % 360 == 0 })
        else {
            return blockedTextReplacement(
                "Rotate every selected page upright before replacing text.",
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
                detail = AppLocalization.format(
                    "Remove %lld characters or select more lines at %@ pt.",
                    remaining,
                    String(
                        format: "%.1f",
                        Double(layoutAttempt.minimumFontSize)
                    )
                )
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
            ? AppLocalization.format(
                " %lld trailing box%@ cleared.",
                clearedRegionCount,
                clearedRegionCount == 1 ? "" : "es"
            )
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
                ? "\(layoutDetail) Uses \(usedRegionCount)/\(targetBounds.count) boxes across \(pageIndices.count) pages.\(clearedDetail)"
                : targetBounds.count > 1
                    ? "\(layoutDetail) Uses \(usedRegionCount)/\(targetBounds.count) boxes on page \(selection.pageIndex + 1).\(clearedDetail)"
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
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure(
                "The replacement PDF destination already exists."
            )
        }
        var didComplete = false
        defer {
            if !didComplete {
                try? fileManager.removeItem(at: destination)
            }
        }
        guard assessment.isReady,
              let sourceDocument = PDFDocument(url: sourceURL),
              !sourceDocument.isLocked,
              let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              source.numberOfPages == sourceDocument.pageCount,
              let firstPage = source.page(at: 1)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the selected text is no longer safe to replace"
            )
        }
        try Self.requireSupportedPageCount(sourceDocument.pageCount)
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
        guard Self.hasValidPageBounds(defaultBox) else {
            throw PaperPathError.invalidPage
        }
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            nil
        ) else {
            throw PaperPathError.storageFailure(
                "The replacement PDF context could not be created."
            )
        }
        var didCloseContext = false
        defer {
            if !didCloseContext {
                context.closePDF()
            }
        }
        progress(0.03)
        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: pageNumber) else {
                throw PaperPathError.invalidPage
            }
            let mediaBox = sourcePage.getBoxRect(.mediaBox)
            let cropBox = sourcePage.getBoxRect(.cropBox)
            guard Self.hasValidPageBounds(mediaBox),
                  Self.hasValidPageBounds(cropBox)
            else {
                throw PaperPathError.invalidPage
            }
            let pageInfo = [
                kCGPDFContextMediaBox as String: pdfPageBoxData(mediaBox),
                kCGPDFContextCropBox as String: pdfPageBoxData(cropBox)
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            let pageIndex = pageNumber - 1
            if selectedPageIndices.contains(pageIndex) {
                guard let selectedPage = sourceDocument.page(at: pageIndex),
                      let pageSelectedRanges = selectedRanges[pageIndex],
                      let renderingPage = selectedPage.copy() as? PDFPage
                else {
                    context.endPDFPage()
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
        didCloseContext = true
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
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a replacement PDF page could not be reopened"
                )
            }
            for annotation in sourcePage.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else {
                    throw PaperPathError.outputVerificationFailed(
                        "an existing annotation could not be preserved"
                    )
                }
                outputPage.addAnnotation(copy)
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
        try LocalFileSecurity.requireCompleteProtection(to: finalizedURL)
        guard let finalized = PDFDocument(url: finalizedURL),
              !finalized.isLocked,
              finalized.pageCount == sourceDocument.pageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the finalized replacement PDF could not be reopened"
            )
        }
        for pageIndex in 0..<finalized.pageCount {
            try Task.checkCancellation()
            guard let page = finalized.page(at: pageIndex),
                  Self.hasValidPageBounds(page.bounds(for: .mediaBox)),
                  Self.hasValidPageBounds(page.bounds(for: .cropBox))
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a finalized replacement PDF page has invalid geometry"
                )
            }
        }
        try Task.checkCancellation()
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: finalizedURL
        )
        try LocalFileSecurity.requireCompleteProtection(to: destination)
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
        guard sourceURL.standardizedFileURL
                != destination.standardizedFileURL
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate export instead of replacing the source PDF."
            )
        }
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
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
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
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
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
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
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
        var didWriteDestination = false
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
            try Task.checkCancellation()
            try requireTemporaryWriteCapacity(
                at: destination,
                byteCount: data.count
            )
            let expectedDigest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            byteProgress(
                PDFByteProgressUpdate(
                    stage: .packaging,
                    processedBytes: 0,
                    totalBytes: Int64(data.count)
                )
            )
            try data.write(to: destination, options: .atomic)
            didWriteDestination = true
            byteProgress(
                PDFByteProgressUpdate(
                    stage: .packaging,
                    processedBytes: Int64(data.count),
                    totalBytes: Int64(data.count)
                )
            )
            try LocalFileSecurity.requireCompleteProtection(
                to: destination
            )
            let writtenDigest = try fileSHA256(
                at: destination,
                expectedByteCount: data.count
            )
            guard writtenDigest == expectedDigest else {
                throw PaperPathError.outputVerificationFailed(
                    "the exported text did not retain its encoded bytes"
                )
            }
            progress(1)
        } catch is CancellationError {
            if didWriteDestination {
                try? FileManager.default.removeItem(at: destination)
            }
            throw CancellationError()
        } catch let error as PaperPathError {
            if didWriteDestination {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        } catch {
            if didWriteDestination {
                try? FileManager.default.removeItem(at: destination)
            }
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
        let fileManager = FileManager.default
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceByteCount = sourceValues.fileSize,
              sourceByteCount > 0,
              sourceByteCount <= Self.maximumImageExportSourceBytes
        else {
            throw PaperPathError.fileTooLarge
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= Self.maximumPageImageExportCount else {
            throw PaperPathError.insufficientSelection(
                "Page-image export supports PDFs up to 1,000 pages."
            )
        }
        let createdDirectory = !fileManager.fileExists(
            atPath: directory.path
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var urls: [URL] = []
        urls.reserveCapacity(document.pageCount)
        var completed = false
        defer {
            if !completed {
                for url in urls {
                    try? fileManager.removeItem(at: url)
                }
                if createdDirectory {
                    try? fileManager.removeItem(at: directory)
                }
            }
        }
        let directoryValues = try directory.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else {
            throw PaperPathError.storageFailure(
                "The page-image export folder is invalid."
            )
        }
        try LocalFileSecurity.requireCompleteProtection(
            to: directory,
            fileManager: fileManager
        )
        LocalFileSecurity.excludeFromBackup(directory)
        var totalByteCount = 0
        var lastReportedPercent = -1
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let result: (url: URL, byteCount: Int) = try autoreleasepool {
                guard let page = document.page(at: index) else {
                    throw PaperPathError.invalidPage
                }
                let bounds = page.bounds(for: .cropBox)
                guard Self.hasValidPageBounds(bounds) else {
                    throw PaperPathError.invalidPage
                }
                let longestEdge: CGFloat = preset == .jpegCompact
                    ? 1_600
                    : 2_400
                let size = fittedSize(
                    rasterPageSize(page),
                    longestEdge: longestEdge
                )
                guard let image = rasterPageImage(page, size: size) else { throw PaperPathError.invalidPage }
                guard let cgImage = image.cgImage,
                      cgImage.width > 0,
                      cgImage.height > 0,
                      let pixelCount = Self.checkedProduct(
                          cgImage.width,
                          cgImage.height
                      ),
                      pixelCount <= Self.maximumPageImagePixels,
                      let decodedByteCount = Self.checkedProduct(
                          pixelCount,
                          4
                      )
                else {
                    throw PaperPathError.unreadableImage
                }
                let outputURL = directory.appendingPathComponent(
                    String(
                        format: "Page-%03d.%@",
                        index + 1,
                        preset.fileExtension
                    )
                )
                guard !fileManager.fileExists(
                    atPath: outputURL.path
                ) else {
                    throw PaperPathError.storageFailure(
                        "A page-image export file already exists."
                    )
                }
                let stagingURL = directory.appendingPathComponent(
                    ".PaperPath-PageImage-\(UUID().uuidString).tmp"
                )
                defer { try? fileManager.removeItem(at: stagingURL) }
                try requireTemporaryWriteCapacity(
                    at: stagingURL,
                    byteCount: decodedByteCount
                )
                try Task.checkCancellation()
                guard fileManager.createFile(
                    atPath: stagingURL.path,
                    contents: nil,
                    attributes: [
                        .protectionKey: FileProtectionType.complete
                    ]
                ) else {
                    throw PaperPathError.storageFailure(
                        "The image export temporary file could not be created."
                    )
                }
                let properties = preset.imageDestinationProperties
                guard let destination = CGImageDestinationCreateWithURL(
                    stagingURL as CFURL,
                    preset.uniformType.identifier as CFString,
                    1,
                    nil
                ) else {
                    throw PaperPathError.storageFailure(
                        "The page image encoder could not be created."
                    )
                }
                CGImageDestinationAddImage(
                    destination,
                    cgImage,
                    properties as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else {
                    throw PaperPathError.outputVerificationFailed(
                        "a PDF page image could not be encoded safely"
                    )
                }
                try Task.checkCancellation()
                let byteCount = try Self
                    .verifiedExportedPageImageByteCount(
                        at: stagingURL,
                        preset: preset,
                        expectedPixelWidth: cgImage.width,
                        expectedPixelHeight: cgImage.height
                    )
                let (nextTotal, totalOverflow) = totalByteCount
                    .addingReportingOverflow(byteCount)
                guard !totalOverflow,
                      nextTotal
                        <= Self.maximumPageImageExportBytes
                else {
                    throw PaperPathError.insufficientSelection(
                        "The page-image export exceeded the 512 MB safe local limit."
                    )
                }
                var movedToOutput = false
                var published = false
                defer {
                    if movedToOutput, !published {
                        try? fileManager.removeItem(at: outputURL)
                    }
                }
                do {
                    try fileManager.moveItem(
                        at: stagingURL,
                        to: outputURL
                    )
                    movedToOutput = true
                    try LocalFileSecurity.requireCompleteProtection(
                        to: outputURL,
                        fileManager: fileManager
                    )
                    LocalFileSecurity.excludeFromBackup(outputURL)
                    let verifiedByteCount = try Self
                        .verifiedExportedPageImageByteCount(
                            at: outputURL,
                            preset: preset,
                            expectedPixelWidth: cgImage.width,
                            expectedPixelHeight: cgImage.height
                        )
                    guard verifiedByteCount == byteCount else {
                        throw PaperPathError.outputVerificationFailed(
                            "a PDF page image did not retain its encoded bytes"
                        )
                    }
                    published = true
                } catch {
                    throw error
                }
                return (outputURL, nextTotal)
            }
            totalByteCount = result.byteCount
            urls.append(result.url)
            let fraction = Double(index + 1)
                / Double(document.pageCount)
            let percent = Int((fraction * 100).rounded(.down))
            if percent > lastReportedPercent {
                lastReportedPercent = percent
                progress(fraction)
            }
        }
        try Task.checkCancellation()
        try Self.requireUnchangedSource(
            at: sourceURL,
            initialValues: sourceValues
        )
        guard urls.count == document.pageCount else {
            throw PaperPathError.outputVerificationFailed(
                "the page image export did not contain every PDF page"
            )
        }
        completed = true
        return urls
    }

    func exportEmbeddedImages(
        sourceURL: URL,
        directory: URL,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws -> PDFEmbeddedImageExportResult {
        let fileManager = FileManager.default
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceByteCount = sourceValues.fileSize,
              sourceByteCount > 0,
              sourceByteCount <= 512 * 1_024 * 1_024
        else {
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

        let createdDirectory = !fileManager.fileExists(
            atPath: directory.path
        )
        var exportedURLs: [URL] = []
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let directoryValues = try directory.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true
            else {
                throw PaperPathError.storageFailure(
                    "The embedded-image export folder is invalid."
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: directory,
                fileManager: fileManager
            )
            LocalFileSecurity.excludeFromBackup(directory)

            let inspector = PDFImageObjectInspector()
            var exportedDigests: Set<String> = []
            var exportedByteCount = 0
            var occurrenceCount = 0
            var unsupportedOccurrenceCount = 0
            var originalStreamFileCount = 0
            var losslessPNGFileCount = 0
            var lastReportedPercent = -1
            exportedURLs.reserveCapacity(
                min(pdfDocument.pageCount * 2, 64)
            )

            for pageIndex in 0..<document.numberOfPages {
                try Task.checkCancellation()
                guard let page = document.page(at: pageIndex + 1) else {
                    throw PaperPathError.invalidPage
                }
                let scan = autoreleasepool {
                    inspector.scanReport(
                        page: page,
                        pageIndex: pageIndex
                    )
                }
                let (nextOccurrenceCount, occurrenceOverflow) =
                    occurrenceCount.addingReportingOverflow(
                        scan.encounteredImageCount
                    )
                let (unsupportedOnPage, unsupportedPageOverflow) =
                    scan.unsupportedImageCount.addingReportingOverflow(
                        scan.omittedImageCount
                    )
                let (nextUnsupportedCount, unsupportedOverflow) =
                    unsupportedOccurrenceCount.addingReportingOverflow(
                        unsupportedOnPage
                    )
                guard !occurrenceOverflow,
                      !unsupportedPageOverflow,
                      !unsupportedOverflow
                else {
                    throw PaperPathError.insufficientSelection(
                        "The embedded-image report exceeded the safe local limit."
                    )
                }
                occurrenceCount = nextOccurrenceCount
                unsupportedOccurrenceCount = nextUnsupportedCount

                for (imageIndex, use) in scan.uses.enumerated() {
                    try Task.checkCancellation()
                    let digest = PDFImageObjectInspector.digest(
                        use.data
                    )
                    guard !exportedDigests.contains(digest) else {
                        continue
                    }
                    let (nextExportedByteCount, byteCountOverflow) =
                        exportedByteCount.addingReportingOverflow(
                            use.data.count
                        )
                    guard exportedURLs.count < 256,
                          !byteCountOverflow,
                          nextExportedByteCount <= 192 * 1_024 * 1_024
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
                    guard !fileManager.fileExists(
                        atPath: outputURL.path
                    ) else {
                        throw PaperPathError.storageFailure(
                            "An embedded-image export file already exists."
                        )
                    }
                    let stagingURL = directory.appendingPathComponent(
                        ".PaperPath-EmbeddedImage-\(UUID().uuidString).tmp"
                    )
                    defer {
                        try? fileManager.removeItem(at: stagingURL)
                    }
                    try requireTemporaryWriteCapacity(
                        at: stagingURL,
                        byteCount: use.data.count
                    )
                    try writeProtectedData(
                        use.data,
                        to: stagingURL,
                        fileManager: fileManager
                    )
                    let verifiedDigest = try fileSHA256(
                        at: stagingURL,
                        expectedByteCount: use.data.count
                    )
                    guard verifiedDigest == digest else {
                        throw PaperPathError.outputVerificationFailed(
                            "an exported image did not match its original PDF stream"
                        )
                    }
                    try Task.checkCancellation()
                    var movedToOutput = false
                    var published = false
                    defer {
                        if movedToOutput, !published {
                            try? fileManager.removeItem(at: outputURL)
                        }
                    }
                    try fileManager.moveItem(
                        at: stagingURL,
                        to: outputURL
                    )
                    movedToOutput = true
                    try LocalFileSecurity.requireCompleteProtection(
                        to: outputURL,
                        fileManager: fileManager
                    )
                    LocalFileSecurity.excludeFromBackup(outputURL)
                    let finalDigest = try fileSHA256(
                        at: outputURL,
                        expectedByteCount: use.data.count
                    )
                    guard finalDigest == digest else {
                        throw PaperPathError.outputVerificationFailed(
                            "an exported image changed while it was published"
                        )
                    }
                    published = true
                    exportedDigests.insert(digest)
                    exportedByteCount = nextExportedByteCount
                    exportedURLs.append(outputURL)
                    if use.kind.isOriginalStream {
                        originalStreamFileCount += 1
                    } else {
                        losslessPNGFileCount += 1
                    }
                }
                let fraction = Double(pageIndex + 1)
                    / Double(document.numberOfPages)
                let percent = Int((fraction * 100).rounded(.down))
                if percent > lastReportedPercent {
                    lastReportedPercent = percent
                    progress(fraction)
                }
            }

            guard !exportedURLs.isEmpty else {
                let message = occurrenceCount == 0
                    ? "No embedded image objects were found in this PDF."
                    : "This PDF uses image encodings or color spaces that cannot be exported safely."
                throw PaperPathError.insufficientSelection(message)
            }
            try Task.checkCancellation()
            try Self.requireUnchangedSource(
                at: sourceURL,
                initialValues: sourceValues
            )
            return PDFEmbeddedImageExportResult(
                urls: exportedURLs,
                occurrenceCount: occurrenceCount,
                unsupportedOccurrenceCount: unsupportedOccurrenceCount,
                originalStreamFileCount: originalStreamFileCount,
                losslessPNGFileCount: losslessPNGFileCount
            )
        } catch {
            if createdDirectory {
                try? fileManager.removeItem(at: directory)
            } else {
                for url in exportedURLs {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }
    }

    private func textPages(
        sourceURL: URL,
        textIndex: DocumentTextIndex?,
        progress: @escaping PDFProgressHandler
    ) throws -> [(pageIndex: Int, text: String)] {
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        try Self.requireSupportedPageCount(document.pageCount)

        let indexedPages = textIndex?.pages ?? []
        guard indexedPages.count <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Text export supports up to 100,000 indexed pages."
            )
        }
        var indexed: [Int: String] = [:]
        var indexedTextBytes = 0
        for page in indexedPages {
            try Task.checkCancellation()
            guard page.pageIndex >= 0,
                  page.pageIndex < document.pageCount
            else { continue }
            let candidate = page.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !candidate.isEmpty else { continue }
            let candidateBytes = candidate.utf8.count
            guard candidateBytes <= Self.maximumTextExportPageBytes else {
                throw PaperPathError.insufficientSelection(
                    "A PDF page contains too much text to export safely."
                )
            }
            if let existing = indexed[page.pageIndex],
               existing.count >= candidate.count {
                continue
            }
            let existingBytes = indexed[page.pageIndex]?.utf8.count ?? 0
            let baseBytes = indexedTextBytes - existingBytes
            let (nextBytes, overflow) = baseBytes
                .addingReportingOverflow(candidateBytes)
            guard !overflow,
                  nextBytes <= Self.maximumTextExportBytes
            else {
                throw PaperPathError.insufficientSelection(
                    "Text export supports up to 16 MB of extracted text at a time."
                )
            }
            indexed[page.pageIndex] = candidate
            indexedTextBytes = nextBytes
        }

        var pages: [(pageIndex: Int, text: String)] = []
        pages.reserveCapacity(min(document.pageCount, 1_024))
        var exportedTextBytes = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = indexed[index]
                ?? document.page(at: index)?.string
                ?? ""
            let trimmed = text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                let pageBytes = trimmed.utf8.count
                let (nextBytes, overflow) = exportedTextBytes
                    .addingReportingOverflow(pageBytes)
                guard pageBytes <= Self.maximumTextExportPageBytes,
                      !overflow,
                      nextBytes <= Self.maximumTextExportBytes
                else {
                    throw PaperPathError.insufficientSelection(
                        "Text export supports up to 16 MB of extracted text at a time."
                    )
                }
                pages.append((index, trimmed))
                exportedTextBytes = nextBytes
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
        requiresSmallerOutput: Bool = false,
        redactions: [PDFRedactionMark],
        progress: @escaping PDFProgressHandler
    ) throws {
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceByteCount = sourceValues.fileSize,
              sourceByteCount > 0,
              sourceByteCount <= Self.maximumImageExportSourceBytes
        else {
            throw PaperPathError.fileTooLarge
        }
        guard let document = PDFDocument(url: sourceURL),
              !document.isLocked,
              document.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard document.pageCount <= Self.maximumPageImageExportCount else {
            throw PaperPathError.insufficientSelection(
                "Rasterized output supports PDFs up to 1,000 pages."
            )
        }
        try requireTemporaryWriteCapacity(
            at: destination,
            byteCount: sourceByteCount
        )
        guard redactions.count <= 10_000,
              redactions.allSatisfy({
                  $0.pageIndex >= 0
                      && $0.pageIndex < document.pageCount
                      && $0.normalizedX.isFinite
                      && $0.normalizedY.isFinite
                      && $0.normalizedWidth.isFinite
                      && $0.normalizedHeight.isFinite
                      && $0.normalizedX >= 0
                      && $0.normalizedY >= 0
                      && $0.normalizedWidth >= 0.001
                      && $0.normalizedHeight >= 0.001
                      && $0.normalizedX + $0.normalizedWidth <= 1.001
                      && $0.normalizedY + $0.normalizedHeight <= 1.001
              })
        else {
            throw PaperPathError.insufficientSelection(
                "The redaction areas could not be processed safely."
            )
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
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure(
                "The output PDF destination already exists."
            )
        }
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".rasterized-\(UUID().uuidString).pdf"
            )
        defer { try? fileManager.removeItem(at: stagingURL) }
        var publishedDestination = false
        var renderingError: PaperPathError?
        var lastReportedPercent = -1
        progress(0.02)

        do {
            try renderer.writePDF(to: stagingURL) { context in
                for index in 0..<document.pageCount {
                    if Task.isCancelled || renderingError != nil {
                        return
                    }
                    autoreleasepool {
                        guard let page = document.page(at: index) else {
                            renderingError = .invalidPage
                            return
                        }
                        let pageBounds = page.bounds(for: .cropBox)
                        guard Self.hasValidPageBounds(pageBounds) else {
                            renderingError = .outputVerificationFailed(
                                "a source PDF page has invalid geometry"
                            )
                            return
                        }
                        let outputBounds = CGRect(
                            origin: .zero,
                            size: rasterPageSize(page)
                        )
                        context.beginPage(
                            withBounds: outputBounds,
                            pageInfo: [:]
                        )

                        let imageSize = fittedSize(
                            outputBounds.size,
                            longestEdge: longestEdge
                        )
                        guard let rendered = rasterPageImage(page, size: imageSize) else {
                            renderingError = .invalidPage; return
                        }
                        let pageMarks = marksByPage[index, default: []]
                        let sanitized: UIImage
                        if pageMarks.isEmpty {
                            sanitized = rendered
                        } else {
                            let format = UIGraphicsImageRendererFormat()
                            format.scale = 1
                            format.opaque = true
                            let bitmap = UIGraphicsImageRenderer(size: imageSize, format: format)
                            sanitized = bitmap.image { bitmapContext in
                                let pixelBounds = CGRect(origin: .zero, size: imageSize)
                                rendered.draw(in: pixelBounds)
                                for (markIndex, mark) in pageMarks.enumerated() {
                                    if markIndex.isMultiple(of: 64), Task.isCancelled {
                                        return
                                    }
                                    let fillColor: UIColor = mark.appearance == .white
                                        ? .white
                                        : .black
                                    bitmapContext.cgContext.setFillColor(
                                        fillColor.cgColor
                                    )
                                    let rect = rasterRedactionRect(mark, rotation: page.rotation, size: imageSize).insetBy(
                                        dx: -2 * imageSize.width / outputBounds.width,
                                        dy: -imageSize.height / outputBounds.height
                                    )
                                    bitmapContext.cgContext.fill(rect)
                                }
                            }
                        }
                        guard !Task.isCancelled else { return }
                        // Encode only sanitized pixels; never embed the source behind an overlay.
                        guard let compressed = sanitized.jpegData(
                            compressionQuality: jpegQuality
                        ),
                              !compressed.isEmpty,
                              compressed.count
                                <= Self.maximumPageImageBytes,
                              let image = UIImage(data: compressed)
                        else {
                            renderingError = .outputVerificationFailed(
                                "a rasterized PDF page could not be encoded safely"
                            )
                            return
                        }
                        image.draw(in: outputBounds)
                    }
                    if renderingError != nil { return }
                    let fraction = Double(index + 1)
                        / Double(max(1, document.pageCount))
                    let percent = Int((fraction * 100).rounded(.down))
                    if percent > lastReportedPercent {
                        lastReportedPercent = percent
                        progress(fraction)
                    }
                }
            }
            if let renderingError {
                throw renderingError
            }
            try Task.checkCancellation()
            try LocalFileSecurity.requireCompleteProtection(
                to: stagingURL
            )
            try verifyRasterizedOutput(
                at: stagingURL,
                expectedPageCount: document.pageCount
            )
            try Task.checkCancellation()
            if requiresSmallerOutput {
                guard let candidateByteCount = try stagingURL
                    .resourceValues(forKeys: [.fileSizeKey])
                    .fileSize,
                      candidateByteCount > 0
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the compressed PDF size could not be verified"
                    )
                }
                guard candidateByteCount < sourceByteCount else {
                    throw PaperPathError.compressionNotBeneficial(
                        sourceByteCount: Int64(sourceByteCount),
                        candidateByteCount: Int64(candidateByteCount)
                    )
                }
            }
            try Self.requireUnchangedSource(
                at: sourceURL,
                initialValues: sourceValues
            )
            try fileManager.moveItem(at: stagingURL, to: destination)
            publishedDestination = true
            try LocalFileSecurity.requireCompleteProtection(to: destination)
            LocalFileSecurity.excludeFromBackup(destination)
        } catch is CancellationError {
            if publishedDestination {
                try? fileManager.removeItem(at: destination)
            }
            throw CancellationError()
        } catch let error as PaperPathError {
            if publishedDestination {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        } catch {
            if publishedDestination {
                try? fileManager.removeItem(at: destination)
            }
            throw PaperPathError.storageFailure(
                "The output PDF could not be rendered."
            )
        }
    }

    private func verifyRasterizedOutput(
        at url: URL,
        expectedPageCount: Int
    ) throws {
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= 1_024 * 1_024 * 1_024,
              let document = PDFDocument(url: url),
              !document.isLocked,
              document.pageCount == expectedPageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the rasterized PDF could not be reopened with every page"
            )
        }
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex),
                  Self.hasValidPageBounds(page.bounds(for: .mediaBox)),
                  Self.hasValidPageBounds(page.bounds(for: .cropBox))
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a rasterized PDF page has invalid geometry"
                )
            }
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

    private static func hasValidPageBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }

    private func validateContentOverlays(
        _ overlays: [PDFContentOverlay],
        pageCount: Int
    ) throws -> PDFContentOverlayValidation {
        guard overlays.count <= 128 else {
            throw PaperPathError.insufficientSelection(
                "Add no more than 128 content items at once."
            )
        }
        var imageByteCount = 0
        var annotationAdditionsByPage: [Int: Int] = [:]
        var expectedLinksByPage: [Int: [PDFExpectedLinkAnnotation]] = [:]
        var expectedTextsByPage: [
            Int: [PDFExpectedTextAnnotation]
        ] = [:]

        for (index, overlay) in overlays.enumerated() {
            if index.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            guard overlay.pageIndex >= 0,
                  overlay.pageIndex < pageCount
            else {
                throw PaperPathError.invalidPage
            }

            switch overlay {
            case .text(
                let pageIndex,
                let bounds,
                let text,
                let fontSize,
                let color
            ):
                guard Self.isValidNormalizedRect(bounds),
                      Self.isSafeEditableText(
                          text,
                          maximumCharacters: 2_000,
                          maximumBytes: 8 * 1_024
                      ),
                      fontSize.isFinite,
                      (8...72).contains(fontSize),
                      Self.isValid(color)
                else {
                    throw PaperPathError.insufficientSelection(
                        "The added text exceeds the safe local limit."
                    )
                }
                annotationAdditionsByPage[pageIndex, default: 0] += 1
                expectedTextsByPage[pageIndex, default: []].append(
                    PDFExpectedTextAnnotation(
                        bounds: bounds,
                        contents: text
                    )
                )
            case .link(
                let pageIndex,
                let bounds,
                let title,
                let url
            ):
                guard Self.isValidNormalizedRect(bounds),
                      Self.isSafeEditableText(
                          title,
                          maximumCharacters: 240,
                          maximumBytes: 1_024
                      ),
                      Self.isSupportedWebURL(url)
                else {
                    throw PaperPathError.insufficientSelection(
                        "Use a valid HTTP or HTTPS link with a label up to 240 characters."
                    )
                }
                annotationAdditionsByPage[pageIndex, default: 0] += 2
                expectedLinksByPage[pageIndex, default: []].append(
                    PDFExpectedLinkAnnotation(
                        pageIndex: pageIndex,
                        bounds: bounds,
                        url: url
                    )
                )
                expectedTextsByPage[pageIndex, default: []].append(
                    PDFExpectedTextAnnotation(
                        bounds: bounds,
                        contents: title
                    )
                )
            case .image(let pageIndex, let bounds, let data):
                guard Self.isValidNormalizedRect(bounds),
                      try Self.hasSafeImageProperties(data)
                else {
                    throw PaperPathError.insufficientSelection(
                        "The added image exceeds the safe size or pixel limit."
                    )
                }
                let (nextByteCount, overflow) = imageByteCount
                    .addingReportingOverflow(data.count)
                guard !overflow,
                      nextByteCount <= 24 * 1_024 * 1_024
                else {
                    throw PaperPathError.storageFailure(
                        "The added images are too large. Choose smaller images."
                    )
                }
                imageByteCount = nextByteCount
                annotationAdditionsByPage[pageIndex, default: 0] += 0
            }
        }

        return PDFContentOverlayValidation(
            annotationAdditionsByPage: annotationAdditionsByPage,
            expectedLinksByPage: expectedLinksByPage,
            expectedTextsByPage: expectedTextsByPage
        )
    }

    private func hasExpectedText(
        _ expected: PDFExpectedTextAnnotation,
        on page: PDFPage
    ) -> Bool {
        let expectedBounds = pdfBounds(
            expected.bounds,
            pageBounds: page.bounds(for: .cropBox)
        )
        return page.annotations.contains { annotation in
            let type = annotation.type?
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
            let freeTextType = PDFAnnotationSubtype.freeText.rawValue
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
            return type?.caseInsensitiveCompare(freeTextType)
                    == .orderedSame
                && annotation.contents == expected.contents
                && annotation.shouldPrint
                && annotation.userName == "PaperPath"
                && Self.approximatelyEqual(
                    annotation.bounds,
                    expectedBounds
                )
        }
    }

    private func hasExpectedLink(
        _ expected: PDFExpectedLinkAnnotation,
        on page: PDFPage
    ) -> Bool {
        let expectedBounds = pdfBounds(
            expected.bounds,
            pageBounds: page.bounds(for: .cropBox)
        )
        return page.annotations.contains { annotation in
            let type = annotation.type?
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
            let linkType = PDFAnnotationSubtype.link.rawValue
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
            let isLink = type?.caseInsensitiveCompare(
                linkType
            ) == .orderedSame
            let targetURL = (
                annotation.action as? PDFActionURL
            )?.url ?? annotation.url
            return isLink
                && targetURL?.absoluteString
                    == expected.url.absoluteString
                && !annotation.shouldPrint
                && Self.approximatelyEqual(
                    annotation.bounds,
                    expectedBounds
                )
        }
    }

    private static func isValidNormalizedRect(
        _ bounds: PDFNormalizedRect
    ) -> Bool {
        let values = [
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height
        ]
        return values.allSatisfy(\.isFinite)
            && bounds.x >= 0
            && bounds.y >= 0
            && bounds.width >= 0.01
            && bounds.height >= 0.01
            && bounds.x + bounds.width <= 1.001
            && bounds.y + bounds.height <= 1.001
    }

    private static func isValid(_ color: PDFInkColor) -> Bool {
        let components = [
            color.red,
            color.green,
            color.blue,
            color.alpha
        ]
        return components.allSatisfy {
            $0.isFinite && (0...1).contains($0)
        }
    }

    private static func isSafeEditableText(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> Bool {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.count <= maximumCharacters,
              trimmed.utf8.count <= maximumBytes
        else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                (0x202A...0x202E).contains(codePoint)
                    || (0x2066...0x2069).contains(codePoint)
            let isAllowedWhitespace = scalar == "\n" || scalar == "\t"
            return !CharacterSet.illegalCharacters.contains(scalar)
                && (!CharacterSet.controlCharacters.contains(scalar)
                    || isAllowedWhitespace)
                && !isBidirectionalControl
        }
    }

    private static func isSupportedWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              host.utf8.count <= 253,
              url.user == nil,
              url.password == nil,
              url.absoluteString.utf8.count <= 4_096
        else { return false }
        return url.absoluteString.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
        }
    }

    private static func hasSafeImageProperties(
        _ data: Data
    ) throws -> Bool {
        guard !data.isEmpty,
              data.count <= 12 * 1_024 * 1_024,
              let imageSource = CGImageSourceCreateWithData(
                  data as CFData,
                  nil
              ),
              CGImageSourceGetCount(imageSource) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  imageSource,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = (
                  properties[kCGImagePropertyPixelWidth] as? NSNumber
              )?.int64Value,
              let height = (
                  properties[kCGImagePropertyPixelHeight] as? NSNumber
              )?.int64Value,
              width > 0,
              height > 0,
              width <= 16_384,
              height <= 16_384
        else { return false }
        let (pixelCount, overflow) = width
            .multipliedReportingOverflow(by: height)
        return !overflow && pixelCount <= 50_000_000
    }

    private static func hasSafeReplacementImageProperties(
        _ data: Data
    ) -> Bool {
        guard !data.isEmpty,
              data.count <= 12 * 1_024 * 1_024,
              let imageSource = CGImageSourceCreateWithData(
                  data as CFData,
                  [
                      kCGImageSourceShouldCache: false
                  ] as CFDictionary
              ),
              CGImageSourceGetCount(imageSource) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  imageSource,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = (
                  properties[kCGImagePropertyPixelWidth] as? NSNumber
              )?.int64Value,
              let height = (
                  properties[kCGImagePropertyPixelHeight] as? NSNumber
              )?.int64Value,
              width > 0,
              height > 0,
              width <= 8_192,
              height <= 8_192
        else { return false }
        let (pixelCount, overflow) = width
            .multipliedReportingOverflow(by: height)
        return !overflow && pixelCount <= 16_000_000
    }

    private static func verifiedExportedPageImageByteCount(
        at url: URL,
        preset: PDFPageImageExportPreset,
        expectedPixelWidth: Int,
        expectedPixelHeight: Int
    ) throws -> Int {
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumPageImageBytes,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL,
                  [
                      kCGImageSourceShouldCache: false
                  ] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = (
                  properties[kCGImagePropertyPixelWidth] as? NSNumber
              )?.int64Value,
              let height = (
                  properties[kCGImagePropertyPixelHeight] as? NSNumber
              )?.int64Value,
              width > 0,
              height > 0,
              width == Int64(expectedPixelWidth),
              height == Int64(expectedPixelHeight),
              width <= 8_192,
              height <= 8_192
        else {
            throw PaperPathError.outputVerificationFailed(
                "a PDF page image failed format or size verification"
            )
        }
        let (pixelCount, overflow) = width
            .multipliedReportingOverflow(by: height)
        guard type.conforms(to: preset.uniformType),
              !overflow,
              pixelCount <= Int64(maximumPageImagePixels)
        else {
            throw PaperPathError.outputVerificationFailed(
                "a PDF page image failed format or size verification"
            )
        }
        return byteCount
    }

    private static func approximatelyEqual(
        _ left: CGRect,
        _ right: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 0.75
        return abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    private func drawImage(
        _ data: Data,
        in bounds: CGRect,
        context: CGContext
    ) throws {
        guard data.count <= 12 * 1_024 * 1_024,
              Self.hasSafeReplacementImageProperties(data),
              let image = UIImage(data: data),
              let cgImage = image.cgImage,
              Self.hasValidPageBounds(bounds)
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
        link.url = url
        link.action = PDFActionURL(url: url)
        let border = PDFBorder()
        border.lineWidth = 0
        link.border = border
        link.color = .clear
        link.shouldPrint = false
        link.userName = "PaperPath"
        page.addAnnotation(link)
    }

    func blockedTextReplacement(
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

    func textSelectionBounds(
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

    func textFlowBounds(
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

    func textFlowRegionsAreOrdered(
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

    func fittingReplacementLayout(
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

    func replacementFlowMeasurement(
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

    func replacementBoundarySplitsWord(
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

    func textAlignment(
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

    func matchingTextRange(
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
                if score > (best?.score ?? -.infinity) {
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

    func drawInvisibleText(
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

    func occurrenceCount(
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

    func normalizedOccurrenceCount(
        of needle: String,
        in haystack: String
    ) -> Int {
        occurrenceCount(
            of: normalizedVerificationText(needle),
            in: normalizedVerificationText(haystack)
        )
    }

    func normalizedVerificationText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{00ad}", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func fittedSize(
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

    static func rectsMatch(
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
    guard let pixelCount = pdfCheckedProduct(width, height),
          pixelCount <= 16_000_000,
          let rgbaByteCount = pdfCheckedProduct(pixelCount, 4),
          let rgbByteCount = pdfCheckedProduct(pixelCount, 3)
    else {
        throw PaperPathError.fileTooLarge
    }
    var rgba = Data(count: rgbaByteCount)
    var rgb = Data(count: rgbByteCount)
    var alpha = Data(count: pixelCount)
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
                for index in 0..<pixelCount {
                    if index.isMultiple(of: 262_144),
                       Task.isCancelled {
                        return false
                    }
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
        try Task.checkCancellation()
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
    guard let pixelCount = pdfCheckedProduct(width, height),
          let expectedByteCount = pdfCheckedProduct(pixelCount, 3),
          rgbData.count == expectedByteCount,
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
    guard let expectedByteCount = pdfCheckedProduct(width, height),
          alphaData.count == expectedByteCount,
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

private let pdfMaximumCapturedImageBytes = 64 * 1_024 * 1_024

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
        encounteredImageCount = Self.saturatingAdd(
            encounteredImageCount,
            child.encounteredImageCount
        )
        unsupportedImageCount = Self.saturatingAdd(
            unsupportedImageCount,
            child.unsupportedImageCount
        )
        omittedImageCount = Self.saturatingAdd(
            omittedImageCount,
            child.omittedImageCount
        )
        for use in child.uses {
            let (nextByteCount, overflow) = capturedByteCount
                .addingReportingOverflow(use.retainedByteCount)
            guard uses.count < 32,
                  !overflow,
                  nextByteCount <= pdfMaximumCapturedImageBytes
            else {
                omittedImageCount = Self.saturatingAdd(
                    omittedImageCount,
                    1
                )
                continue
            }
            uses.append(use)
            capturedByteCount = nextByteCount
        }
    }

    private static func saturatingAdd(
        _ left: Int,
        _ right: Int
    ) -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : value
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
    let retainedByteCount: Int
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
          height > 0,
          width <= 20_000,
          height <= 20_000,
          let pixelCount = pdfCheckedProduct(
              Int(width),
              Int(height)
          ),
          pixelCount <= 16_000_000
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
    let retainedByteCount: Int
    switch payload.kind {
    case .originalJPEG, .originalJPEG2000:
        retainedByteCount = payload.data.count
    case .losslessPNG:
        let (imageAndSourceBytes, firstOverflow) = payload.data.count
            .addingReportingOverflow(payload.sourceStreamData.count)
        let (totalRetainedBytes, secondOverflow) =
            imageAndSourceBytes.addingReportingOverflow(
                payload.softMaskStreamData?.count ?? 0
            )
        guard !firstOverflow, !secondOverflow else {
            state.omittedImageCount += 1
            return
        }
        retainedByteCount = totalRetainedBytes
    }
    let (nextCapturedByteCount, byteCountOverflow) =
        state.capturedByteCount.addingReportingOverflow(
            retainedByteCount
        )
    guard !payload.data.isEmpty,
          payload.data.count <= 32 * 1_024 * 1_024,
          state.uses.count < 32,
          !byteCountOverflow,
          nextCapturedByteCount <= pdfMaximumCapturedImageBytes
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
            retainedByteCount: retainedByteCount,
            kind: payload.kind
        )
    )
    state.capturedByteCount = nextCapturedByteCount
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
          let pixelCount = pdfCheckedProduct(width, height),
          pixelCount <= 16_000_000,
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
    guard let expectedByteCount = pdfCheckedProduct(
        expectedWidth,
        expectedHeight
    ),
          data.count == expectedByteCount else {
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
    guard let pixelCount = pdfCheckedProduct(width, height),
          pixelCount <= 16_000_000,
          alphaData.count == pixelCount,
          let rgbaByteCount = pdfCheckedProduct(pixelCount, 4)
    else { return nil }
    var rgba = Data(count: rgbaByteCount)
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
        var wasCancelled = false
        alphaData.withUnsafeBytes { alphaBytes in
            guard let pixels = rgbaBytes.bindMemory(
                to: UInt8.self
            ).baseAddress,
                  let alpha = alphaBytes.bindMemory(
                      to: UInt8.self
                  ).baseAddress
            else { return }
            for index in 0..<pixelCount {
                if index.isMultiple(of: 262_144),
                   Task.isCancelled {
                    wasCancelled = true
                    return
                }
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
        guard !wasCancelled else { return nil }
        return context.makeImage()
    }
}

private func pdfCheckedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
    guard lhs >= 0, rhs >= 0 else { return nil }
    let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? nil : product
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
                    throw PaperPathError.invalidPage
                }
                let uses = autoreleasepool {
                    scan(
                        page: page,
                        pageIndex: index
                    )
                }
                for use in uses where use.kind == .originalJPEG
                    || use.kind == .losslessPNG {
                    let digest = Self.digest(use.data)
                    guard candidateDigests.contains(digest) else {
                        continue
                    }
                    let currentCount = usageCountByDigest[
                        digest,
                        default: 0
                    ]
                    let (nextCount, overflow) = currentCount
                        .addingReportingOverflow(1)
                    guard !overflow else {
                        throw PaperPathError.insufficientSelection(
                            "The image reference count exceeded the safe local limit."
                        )
                    }
                    usageCountByDigest[digest] = nextCount
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

struct PDFImageObjectReference {
    let number: Int
    let generation: Int
    let offset: Int
}

struct PDFObjectReplacement {
    let object: PDFImageObjectReference
    let data: Data
}

struct PDFObjectReplacementPlan {
    let object: PDFImageObjectReference
    let data: Data
    let endOffset: Int

    var byteDelta: Int {
        data.count - (endOffset - object.offset)
    }
}

func pdfObjectReplacementPlans(
    in data: Data,
    before startXRef: Int,
    orderedObjects: [PDFImageObjectReference],
    replacements: [PDFObjectReplacement]
) throws -> [PDFObjectReplacementPlan] {
    guard !replacements.isEmpty, replacements.count <= 128 else {
        throw PaperPathError.insufficientSelection(
            "The PDF object update exceeds the safe local limit."
        )
    }
    var objectsByNumber: [Int: PDFImageObjectReference] = [:]
    for object in orderedObjects {
        guard objectsByNumber[object.number] == nil else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF contains duplicate object references"
            )
        }
        objectsByNumber[object.number] = object
    }
    var seenNumbers: Set<Int> = []
    var plans: [PDFObjectReplacementPlan] = []
    plans.reserveCapacity(replacements.count)
    for replacement in replacements {
        try Task.checkCancellation()
        let requested = replacement.object
        guard seenNumbers.insert(requested.number).inserted,
              !replacement.data.isEmpty,
              let stored = objectsByNumber[requested.number],
              stored.generation == requested.generation,
              stored.offset == requested.offset
        else {
            throw PaperPathError.outputVerificationFailed(
                "a PDF object changed before the structural update"
            )
        }
        let upperBound = orderedObjects.first(where: {
            $0.offset > stored.offset
        })?.offset ?? startXRef
        guard stored.offset >= 0,
              stored.offset < upperBound,
              upperBound <= data.count,
              let endOffset = data[stored.offset..<upperBound]
                .range(
                    of: Data("endobj".utf8),
                    options: .backwards
                )?.upperBound
        else {
            throw PaperPathError.outputVerificationFailed(
                "the source object boundaries could not be verified"
            )
        }
        plans.append(
            PDFObjectReplacementPlan(
                object: stored,
                data: replacement.data,
                endOffset: endOffset
            )
        )
    }
    plans.sort { $0.object.offset < $1.object.offset }
    for index in 1..<plans.count
    where plans[index - 1].endOffset > plans[index].object.offset {
        throw PaperPathError.outputVerificationFailed(
            "the PDF object update contains overlapping ranges"
        )
    }
    return plans
}

func pdfBodyReplacingObjects(
    in data: Data,
    before startXRef: Int,
    orderedObjects: [PDFImageObjectReference],
    plans: [PDFObjectReplacementPlan]
) throws -> (body: Data, offsets: [Int: Int]) {
    var projectedByteCount = startXRef
    for plan in plans {
        let (nextCount, overflow) = projectedByteCount
            .addingReportingOverflow(plan.byteDelta)
        guard !overflow, nextCount >= 0, nextCount < Int.max else {
            throw PaperPathError.storageFailure(
                "The rewritten PDF exceeds the safe local limit."
            )
        }
        projectedByteCount = nextCount
    }

    var body = Data()
    body.reserveCapacity(projectedByteCount + 1)
    var cursor = 0
    for plan in plans {
        try Task.checkCancellation()
        body.append(data[cursor..<plan.object.offset])
        body.append(plan.data)
        cursor = plan.endOffset
    }
    body.append(data[cursor..<startXRef])
    if body.last != 0x0a {
        body.append(0x0a)
    }

    var offsets: [Int: Int] = [:]
    offsets.reserveCapacity(orderedObjects.count)
    var planIndex = 0
    var offsetDelta = 0
    for object in orderedObjects {
        while planIndex < plans.count,
              plans[planIndex].endOffset <= object.offset {
            let (nextDelta, overflow) = offsetDelta
                .addingReportingOverflow(
                    plans[planIndex].byteDelta
                )
            guard !overflow else {
                throw PaperPathError.storageFailure(
                    "The rewritten PDF exceeds the safe local limit."
                )
            }
            offsetDelta = nextDelta
            planIndex += 1
        }
        let (newOffset, overflow) = object.offset
            .addingReportingOverflow(offsetDelta)
        guard !overflow, newOffset >= 0 else {
            throw PaperPathError.storageFailure(
                "The rewritten PDF exceeds the safe local limit."
            )
        }
        offsets[object.number] = newOffset
    }
    return (body, offsets)
}

func pdfObjectDictionary(_ objectData: Data) -> String? {
    guard let range = pdfFirstDictionaryRange(in: objectData)
    else { return nil }
    return String(
        decoding: objectData[range],
        as: UTF8.self
    )
}

func pdfObjectReference(
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
    _ objectData: Data,
    maximumOutputByteCount: Int
) -> Data? {
    guard maximumOutputByteCount > 0,
          maximumOutputByteCount <= 64 * 1_024 * 1_024,
          let dictionary = pdfObjectDictionary(objectData),
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
    return pdfInflateZlib(
        encoded,
        maximumOutputByteCount: maximumOutputByteCount
    )
}

func pdfInteger(
    following key: String,
    in value: String
) -> Int? {
    pdfParsedInteger(following: key, in: value)
}

private func pdfParsedInteger(
    following key: String,
    in value: String
) -> Int? {
    guard !key.isEmpty else { return nil }
    var searchStart = value.startIndex
    while searchStart < value.endIndex,
          let keyRange = value.range(
              of: key,
              range: searchStart..<value.endIndex
          ) {
        let valueStart = keyRange.upperBound
        guard valueStart == value.endIndex
                || pdfIsStringTokenDelimiter(value[valueStart])
        else {
            searchStart = valueStart
            continue
        }

        var index = valueStart
        while index < value.endIndex,
              value[index].isWhitespace {
            index = value.index(after: index)
        }
        let numberStart = index
        if index < value.endIndex,
           value[index] == "-" || value[index] == "+" {
            index = value.index(after: index)
        }
        let digitStart = index
        while index < value.endIndex,
              pdfIsASCIIDigit(value[index]) {
            index = value.index(after: index)
        }
        guard index > digitStart,
              index == value.endIndex
                || pdfIsStringTokenDelimiter(value[index])
        else {
            searchStart = valueStart
            continue
        }
        return Int(value[numberStart..<index])
    }
    return nil
}

private func pdfIsASCIIDigit(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1,
          let scalar = character.unicodeScalars.first
    else { return false }
    return (48...57).contains(scalar.value)
}

private func pdfIsStringTokenDelimiter(
    _ character: Character
) -> Bool {
    character.isWhitespace
        || "()<>[]{}/%".contains(character)
}

func pdfInflateZlib(
    _ data: Data,
    maximumOutputByteCount: Int
) -> Data? {
    guard data.count > 6,
          maximumOutputByteCount > 0,
          maximumOutputByteCount <= 64 * 1_024 * 1_024
    else { return nil }

    let compressionMethod = data[data.startIndex]
    let flags = data[data.index(after: data.startIndex)]
    let header = UInt16(compressionMethod) << 8 | UInt16(flags)
    guard compressionMethod & 0x0f == 8,
          header.isMultiple(of: 31),
          flags & 0x20 == 0
    else { return nil }

    let checksumStart = data.index(data.endIndex, offsetBy: -4)
    let expectedChecksum = data[checksumStart...].reduce(UInt32.zero) {
        ($0 << 8) | UInt32($1)
    }
    let payloadStart = data.index(data.startIndex, offsetBy: 2)
    let payload = data[payloadStart..<checksumStart]
    guard !payload.isEmpty else { return nil }

    let initialDestination = UnsafeMutablePointer<UInt8>.allocate(
        capacity: 1
    )
    let initialSource = UnsafeMutablePointer<UInt8>.allocate(
        capacity: 1
    )
    defer {
        initialDestination.deallocate()
        initialSource.deallocate()
    }
    var stream = compression_stream(
        dst_ptr: initialDestination,
        dst_size: 0,
        src_ptr: UnsafePointer(initialSource),
        src_size: 0,
        state: nil
    )
    guard compression_stream_init(
        &stream,
        COMPRESSION_STREAM_DECODE,
        COMPRESSION_ZLIB
    ) != COMPRESSION_STATUS_ERROR else {
        return nil
    }
    defer { compression_stream_destroy(&stream) }

    let chunkByteCount = min(
        64 * 1_024,
        maximumOutputByteCount + 1
    )
    var destination = [UInt8](
        repeating: 0,
        count: chunkByteCount
    )
    var output = Data()
    output.reserveCapacity(
        min(
            maximumOutputByteCount,
            max(payload.count, 64 * 1_024)
        )
    )

    return payload.withUnsafeBytes { sourceBytes -> Data? in
        guard let source = sourceBytes.bindMemory(
            to: UInt8.self
        ).baseAddress else {
            return nil
        }
        stream.src_ptr = source
        stream.src_size = payload.count

        while true {
            let remaining = maximumOutputByteCount - output.count
            let destinationByteCount = min(
                destination.count,
                remaining + 1
            )
            let previousSourceSize = stream.src_size
            let status = destination.withUnsafeMutableBytes {
                destinationBytes -> compression_status in
                guard let destinationPointer =
                        destinationBytes.bindMemory(
                    to: UInt8.self
                ).baseAddress else {
                    return COMPRESSION_STATUS_ERROR
                }
                stream.dst_ptr = destinationPointer
                stream.dst_size = destinationByteCount
                return compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
            }
            let produced = destinationByteCount - stream.dst_size
            guard produced <= remaining else { return nil }
            if produced > 0 {
                output.append(contentsOf: destination[..<produced])
            }

            switch status {
            case COMPRESSION_STATUS_END:
                guard stream.src_size == 0,
                      pdfAdler32(output) == expectedChecksum
                else { return nil }
                return output
            case COMPRESSION_STATUS_OK:
                guard produced > 0
                        || stream.src_size < previousSourceSize
                else { return nil }
            default:
                return nil
            }
        }
    }
}

private func pdfAdler32(_ data: Data) -> UInt32 {
    let modulus: UInt64 = 65_521
    let reductionStride = 5_552
    var first: UInt64 = 1
    var second: UInt64 = 0
    var pendingCount = 0
    for byte in data {
        first += UInt64(byte)
        second += first
        pendingCount += 1
        if pendingCount == reductionStride {
            first %= modulus
            second %= modulus
            pendingCount = 0
        }
    }
    first %= modulus
    second %= modulus
    return UInt32((second << 16) | first)
}

func pdfUTF16HexString(_ value: String) -> String {
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

func pdfCatalogObject(
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

func pdfObject(
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

func pdfObject(
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

func pdfTopLevelString(
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

func pdfDecodedString(_ value: Data) -> String? {
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

func pdfFirstDictionaryRange(
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

func pdfTopLevelValueRange(
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

func pdfObjectValueEnd(
    in data: Data,
    start: Int,
    limit: Int
) -> Int? {
    guard start < limit else { return nil }
    if data[start] == 0x2f {
        // PDF names include their leading slash; it is a delimiter for other
        // tokens, so starting the generic scan at the slash returns no value.
        let end = pdfTokenEnd(in: data, start: start + 1, limit: limit)
        return end > start + 1 ? end : nil
    }
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

func pdfCompositeEnd(
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

func pdfArrayEnd(
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

func pdfLiteralStringEnd(
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

func pdfHexStringEnd(
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

func pdfCommentEnd(
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

func pdfSkipWhitespaceAndComments(
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

func pdfTokenEnd(
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

func pdfIsWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x00
        || byte == 0x09
        || byte == 0x0a
        || byte == 0x0c
        || byte == 0x0d
        || byte == 0x20
}

func pdfIsDelimiter(_ byte: UInt8) -> Bool {
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

enum PDFImageObjectDocument {
    case classic(PDFClassicXRefDocument)
    case xrefStream(PDFXRefStreamDocument)

    init(data: Data, allowZeroOffsetPlaceholders: Bool = false) throws {
        if let classic = try? PDFClassicXRefDocument(data: data, allowZeroOffsetPlaceholders: allowZeroOffsetPlaceholders) {
            self = .classic(classic)
        } else {
            self = .xrefStream(
                try allowZeroOffsetPlaceholders
                    ? PDFXRefStreamDocument(compressionData: data)
                    : PDFXRefStreamDocument(data: data)
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

    func replacingObjects(
        _ replacements: [PDFObjectReplacement]
    ) throws -> Data {
        switch self {
        case .classic(let document):
            return try document.replacingObjects(replacements)
        case .xrefStream(let document):
            return try document.replacingObjects(replacements)
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

struct PDFXRefStreamDocument {
    private static let maximumEntryCount = 500_000

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
    private let compressionTrailer: Data?

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
              size <= Self.maximumEntryCount,
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
        let indexValues = Self.integerArray(
            following: "/Index",
            in: dictionary
        ) ?? [0, size]
        guard indexValues.count.isMultiple(of: 2),
              indexValues.count <= 2_048
        else {
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
        var indexedEntryCount = 0
        for pairIndex in stride(
            from: 0,
            to: indexValues.count,
            by: 2
        ) {
            let first = indexValues[pairIndex]
            let count = indexValues[pairIndex + 1]
            let (nextEntryCount, entryCountOverflow) =
                indexedEntryCount.addingReportingOverflow(count)
            guard first >= 0,
                  count >= 0,
                  first <= size,
                  count <= size - first,
                  !entryCountOverflow,
                  nextEntryCount <= Self.maximumEntryCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the cross-reference index exceeds its declared size"
                )
            }
            indexedEntryCount = nextEntryCount
        }
        let (
            decodedByteCount,
            decodedByteCountOverflow
        ) = indexedEntryCount.multipliedReportingOverflow(
            by: recordWidth
        )
        guard indexedEntryCount > 0,
              !decodedByteCountOverflow,
              decodedByteCount > 0,
              decodedByteCount <= 24 * 1_024 * 1_024
        else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream exceeds the safe local limit"
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
        guard let decoded = pdfInflateZlib(
            encoded,
            maximumOutputByteCount: decodedByteCount
        ),
              decoded.count == decodedByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream could not be decoded"
            )
        }
        var cursor = 0
        var parsedEntries: [Int: Entry] = [:]
        parsedEntries.reserveCapacity(indexedEntryCount)
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
                let objectNumber = first + itemIndex
                guard parsedEntries[objectNumber] == nil else {
                    throw PaperPathError.outputVerificationFailed(
                        "the cross-reference index contains overlapping entries"
                    )
                }
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
                parsedEntries[objectNumber] = Entry(
                    type: type,
                    field1: field1,
                    field2: field2
                )
            }
        }
        guard cursor == decoded.count else {
            throw PaperPathError.outputVerificationFailed(
                "the cross-reference stream contains trailing data"
            )
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
        self.compressionTrailer = nil
    }

    func imageObject(
        matching imageData: Data
    ) -> PDFImageObjectReference? {
        guard !imageData.isEmpty else { return nil }
        let ordered = uncompressedReferences
        var match: PDFImageObjectReference?
        for (index, entry) in ordered.enumerated() {
            let upperBound = index + 1 < ordered.count
                ? ordered[index + 1].offset
                : startXRef
            guard entry.offset < upperBound else { continue }
            let objectData = data[entry.offset..<upperBound]
            guard objectData.range(of: imageData) != nil,
                  objectData.range(of: Data("/Subtype /Image".utf8))
                    != nil
            else { continue }
            guard match == nil else { return nil }
            match = entry
        }
        return match
    }

    func imageObject(
        matchingDecodedStream streamData: Data
    ) -> PDFImageObjectReference? {
        let ordered = uncompressedReferences
        var match: PDFImageObjectReference?
        for (index, entry) in ordered.enumerated() {
            let upperBound = index + 1 < ordered.count
                ? ordered[index + 1].offset
                : startXRef
            guard entry.offset < upperBound else { continue }
            let objectData = Data(data[entry.offset..<upperBound])
            guard pdfInflatedObjectStream(
                objectData,
                maximumOutputByteCount: streamData.count
            ) == streamData else {
                continue
            }
            guard match == nil else { return nil }
            match = entry
        }
        return match
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
        try replacingObjects([
            PDFObjectReplacement(
                object: object,
                data: replacement
            )
        ])
    }

    func replacingObjects(
        _ replacements: [PDFObjectReplacement]
    ) throws -> Data {
        let ordered = uncompressedReferences
        let plans = try pdfObjectReplacementPlans(
            in: data,
            before: startXRef,
            orderedObjects: ordered,
            replacements: replacements
        )
        let rewritten = try pdfBodyReplacingObjects(
            in: data,
            before: startXRef,
            orderedObjects: ordered,
            plans: plans
        )
        var replacementEntries = entries
        for object in ordered {
            guard let offset = rewritten.offsets[object.number],
                  let entry = replacementEntries[object.number]
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the rebuilt cross-reference entry is missing"
                )
            }
            replacementEntries[object.number] = Entry(
                type: entry.type,
                field1: UInt64(offset),
                field2: entry.field2
            )
        }
        var body = rewritten.body
        let newXRefOffset = body.count
        replacementEntries[xrefObjectNumber] = Entry(
            type: 1,
            field1: UInt64(newXRefOffset),
            field2: UInt64(xrefGeneration)
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
        pdfParsedInteger(following: key, in: value)
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

    static func deflateZlib(_ data: Data) -> Data? {
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

struct PDFCatalogStructureAppender {
    private static let maximumAttachmentCount = 256
    private static let maximumAttachmentBytes =
        64 * 1_024 * 1_024
    private static let maximumXRefEntryCount = 500_000

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
        let xrefByteCount = data.count - startXRef
        guard xrefByteCount <= 32 * 1_024 * 1_024 else {
            throw PaperPathError.insufficientSelection(
                "This PDF cross-reference table exceeds the safe local limit."
            )
        }
        let xrefText = String(
            decoding: data[startXRef..<data.count],
            as: UTF8.self
        )
        let lines = xrefText.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              lines.count
                <= Self.maximumXRefEntryCount + 4_096,
              firstLine.trimmingCharacters(
                in: .whitespaces
              ) == "xref"
        else {
            throw PaperPathError.insufficientSelection(
                "This PDF cannot safely preserve catalog structures."
            )
        }

        var parsedEntries: [Int: PDFImageObjectReference] = [:]
        var declaredEntryCount = 0
        var lineIndex = 1
        var trailerStartIndex: Int?
        while lineIndex < lines.count {
            let line = lines[lineIndex]
                .trimmingCharacters(in: .whitespaces)
            lineIndex += 1
            if line == "trailer" {
                trailerStartIndex = lineIndex
                break
            }
            if line.isEmpty { continue }
            let header = line.split(whereSeparator: \.isWhitespace)
            guard header.count == 2,
                  let firstObject = Int(header[0]),
                  let count = Int(header[1]),
                  firstObject >= 0,
                  count >= 0,
                  firstObject <= Self.maximumXRefEntryCount,
                  count <= Self.maximumXRefEntryCount - firstObject,
                  count
                    <= Self.maximumXRefEntryCount - declaredEntryCount,
                  count <= lines.count - lineIndex
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the PDF cross-reference table is malformed"
                )
            }
            declaredEntryCount += count
            for index in 0..<count {
                let fields = lines[lineIndex]
                    .split(whereSeparator: \.isWhitespace)
                lineIndex += 1
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
                    // PDFKit reserves unused slots as in-use entries at zero.
                    if number > 0, offset == 0 { continue }
                    guard parsedEntries[number] == nil else {
                        throw PaperPathError.outputVerificationFailed(
                            "the PDF cross-reference table contains duplicate entries"
                        )
                    }
                    parsedEntries[number] = PDFImageObjectReference(
                        number: number,
                        generation: generation,
                        offset: offset
                    )
                }
            }
        }
        guard let trailerStartIndex else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF trailer is missing"
            )
        }
        let trailerText = lines[trailerStartIndex...]
            .joined(separator: "\n")
        guard let trailer = Self.firstDictionary(in: trailerText),
              let parsedSize = Self.signedInteger(
                  following: "/Size",
                  in: trailer
              ),
              parsedSize > 0,
              parsedSize <= Self.maximumXRefEntryCount,
              parsedEntries.allSatisfy({
                  $0.key < parsedSize
                      && $0.value.offset > 0
                      && $0.value.offset < startXRef
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
        guard attachmentPayloads.count
                <= Self.maximumAttachmentCount
        else {
            throw PaperPathError.insufficientSelection(
                "This PDF contains too many embedded files to preserve safely."
            )
        }
        var attachmentByteCount = 0
        for payload in attachmentPayloads {
            try Task.checkCancellation()
            guard payload.snapshot.origin == .document,
                  let attachmentData = payload.data,
                  payload.snapshot.byteCount == attachmentData.count,
                  Self.digest(attachmentData)
                    == payload.snapshot.checksum
            else {
                throw PaperPathError.insufficientSelection(
                    "This PDF contains attachment structures that cannot be safely preserved."
                )
            }
            let (nextByteCount, overflow) = attachmentByteCount
                .addingReportingOverflow(attachmentData.count)
            guard !overflow,
                  nextByteCount <= Self.maximumAttachmentBytes
            else {
                throw PaperPathError.insufficientSelection(
                    "Structure-preserving updates support up to 64 MB of embedded files."
                )
            }
            attachmentByteCount = nextByteCount
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
                try Task.checkCancellation()
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

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func originalObjectEncryption(password: String) throws -> PDFOriginalObjectEncryption {
        let reference = try reference(following: "/Encrypt", in: trailerDictionary)
        guard let entry = entries[reference.number],
              let range = pdfFirstDictionaryRange(in: objectData(for: entry)),
              let identifier = Self.firstIdentifier(in: trailerDictionary) else { throw PaperPathError.unreadablePDF }
        let dictionary = Data(objectData(for: entry)[range])
        return PDFOriginalObjectEncryption(context: try encryptionContext(password: password), dictionary: dictionary,
            identifier: identifier, encryptMetadata: !String(decoding: dictionary, as: UTF8.self).contains("/EncryptMetadata false"))
    }

    func originalStreamReferences() -> [PDFImageObjectReference] {
        entries.values.sorted { $0.offset < $1.offset }
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

struct PDFAESV2EncryptionContext {
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
                guard let baseAddress = bytes.baseAddress else {
                    return errSecParam
                }
                return SecRandomCopyBytes(
                    kSecRandomDefault,
                    bytes.count,
                    baseAddress
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

    func decrypt(_ data: Data, objectNumber: Int, generation: Int) throws -> Data {
        guard data.count >= 32, (data.count - 16).isMultiple(of: 16) else { throw PaperPathError.unreadablePDF }
        var material = fileKey
        material.append(UInt8(objectNumber & 0xff))
        material.append(UInt8((objectNumber >> 8) & 0xff))
        material.append(UInt8((objectNumber >> 16) & 0xff))
        material.append(UInt8(generation & 0xff)); material.append(UInt8((generation >> 8) & 0xff))
        material.append(contentsOf: [0x73, 0x41, 0x6c, 0x54])
        let key = Data(Insecure.MD5.hash(data: material).prefix(min(fileKey.count + 5, 16)))
        let iv = Data(data.prefix(16)), ciphertext = Data(data.dropFirst(16))
        let capacity = ciphertext.count
        var output = Data(count: capacity), count = 0
        let status = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    ciphertext.withUnsafeBytes { source in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, ciphertext.count,
                            destination.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PaperPathError.unreadablePDF }
        output.count = count
        return output
    }
}

struct PDFClassicXRefDocument {
    private static let maximumEntryCount = 500_000

    private let data: Data
    private let startXRef: Int
    private let size: Int
    private let trailerDictionary: String
    private let entries: [Int: PDFImageObjectReference]

    init(data: Data, allowZeroOffsetPlaceholders: Bool = false) throws {
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
        let xrefByteCount = data.count - startXRef
        guard xrefByteCount <= 32 * 1_024 * 1_024 else {
            throw PaperPathError.insufficientSelection(
                "This PDF cross-reference table exceeds the safe local limit."
            )
        }
        let xrefText = String(
            decoding: data[startXRef..<data.count],
            as: UTF8.self
        )
        let lines = xrefText.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              lines.count <= Self.maximumEntryCount + 4_096,
              firstLine.trimmingCharacters(
                  in: .whitespaces
              ) == "xref"
        else {
            throw PaperPathError.insufficientSelection(
                "Image replacement does not rewrite compressed PDF object streams."
            )
        }

        var parsedEntries: [Int: PDFImageObjectReference] = [:]
        var declaredEntryCount = 0
        var lineIndex = 1
        var trailerStartIndex: Int?
        while lineIndex < lines.count {
            let line = lines[lineIndex]
                .trimmingCharacters(in: .whitespaces)
            lineIndex += 1
            if line == "trailer" {
                trailerStartIndex = lineIndex
                break
            }
            if line.isEmpty { continue }
            let header = line.split(whereSeparator: \.isWhitespace)
            guard header.count == 2,
                  let firstObject = Int(header[0]),
                  let count = Int(header[1]),
                  firstObject >= 0,
                  count >= 0,
                  firstObject <= Self.maximumEntryCount,
                  count <= Self.maximumEntryCount - firstObject,
                  count <= Self.maximumEntryCount - declaredEntryCount,
                  count <= lines.count - lineIndex
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the PDF cross-reference table is malformed"
                )
            }
            declaredEntryCount += count
            for index in 0..<count {
                let fields = lines[lineIndex]
                    .split(whereSeparator: \.isWhitespace)
                lineIndex += 1
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
                    // Some Apple-generated PDFs reserve unused slots as in-use
                    // entries at byte zero. There is no object at the PDF header;
                    // treat these unresolved placeholders as free on compression.
                    if allowZeroOffsetPlaceholders, number > 0, offset == 0 { continue }
                    guard parsedEntries[number] == nil else {
                        throw PaperPathError.outputVerificationFailed(
                            "the PDF cross-reference table contains duplicate entries"
                        )
                    }
                    parsedEntries[number] = PDFImageObjectReference(
                        number: number,
                        generation: generation,
                        offset: offset
                    )
                }
            }
        }
        guard let trailerStartIndex else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF trailer is missing"
            )
        }
        let trailerText = lines[trailerStartIndex...]
            .joined(separator: "\n")
        guard let trailer = Self.firstDictionary(in: trailerText),
              !trailer.contains("/Prev"),
              !trailer.contains("/Encrypt"),
              !trailer.contains("/XRefStm"),
              let parsedSize = Self.integer(
                  following: "/Size",
                  in: trailer
              ),
              parsedSize > 0,
              parsedSize <= Self.maximumEntryCount,
              parsedEntries.allSatisfy({
                  $0.key < parsedSize
                      && $0.value.offset > 0
                      && $0.value.offset < startXRef
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
        guard !jpegData.isEmpty else { return nil }
        let ordered = entries.values.sorted { $0.offset < $1.offset }
        var match: PDFImageObjectReference?
        for (index, entry) in ordered.enumerated() {
            let upperBound = index + 1 < ordered.count
                ? ordered[index + 1].offset
                : startXRef
            guard entry.offset < upperBound,
                  data[entry.offset..<upperBound]
                    .range(of: jpegData) != nil
            else { continue }
            guard match == nil else { return nil }
            match = entry
        }
        return match
    }

    func imageObject(
        matchingDecodedStream streamData: Data
    ) -> PDFImageObjectReference? {
        let ordered = entries.values.sorted {
            $0.offset < $1.offset
        }
        var match: PDFImageObjectReference?
        for (index, entry) in ordered.enumerated() {
            let upperBound = index + 1 < ordered.count
                ? ordered[index + 1].offset
                : startXRef
            guard entry.offset < upperBound,
                  pdfInflatedObjectStream(
                Data(data[entry.offset..<upperBound]),
                maximumOutputByteCount: streamData.count
            ) == streamData
            else { continue }
            guard match == nil else { return nil }
            match = entry
        }
        return match
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
        try replacingObjects([
            PDFObjectReplacement(
                object: object,
                data: replacement
            )
        ])
    }

    func replacingObjects(
        _ replacements: [PDFObjectReplacement]
    ) throws -> Data {
        let ordered = entries.values.sorted { $0.offset < $1.offset }
        let plans = try pdfObjectReplacementPlans(
            in: data,
            before: startXRef,
            orderedObjects: ordered,
            replacements: replacements
        )
        let rewritten = try pdfBodyReplacingObjects(
            in: data,
            before: startXRef,
            orderedObjects: ordered,
            plans: plans
        )
        var body = rewritten.body
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
            guard let offset = rewritten.offsets[entry.number] else {
                throw PaperPathError.outputVerificationFailed(
                    "the rebuilt cross-reference entry is missing"
                )
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

    func dataForObject(
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
        pdfParsedInteger(following: key, in: value)
    }
}

// MARK: - Content-preserving, bounded-memory compression

private extension PDFOutputService {
    func compressPreservingContent(
        sourceURL: URL, destination: URL,
        imageQuality: PDFCompressionQuality?,
        progress: @escaping PDFProgressHandler
    ) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        let identity = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileResourceIdentifierKey
        ])
        guard identity.isRegularFile == true,
              identity.isSymbolicLink != true,
              let sourceBytes = identity.fileSize,
              sourceBytes > 0, sourceBytes <= Self.maximumImageExportSourceBytes
        else { throw PaperPathError.fileTooLarge }
        guard !manager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure("The output PDF destination already exists.")
        }
        try requireTemporaryWriteCapacity(at: destination, byteCount: sourceBytes)
        try pdfRequireUnsignedCompressionSource(sourceURL)
        progress(0.01)
        // Mapping avoids allocating the complete source or output in RAM.
        let mapping = try PDFCompressionMappedInput(url: sourceURL, count: sourceBytes)
        guard let eof = try pdfCompressionEndOfFile(reader: mapping.reader, count: sourceBytes) else {
            throw PaperPathError.unreadablePDF
        }
        let source = mapping.data.prefix(eof)
        let structure: PDFImageObjectDocument
        do {
            structure = try PDFImageObjectDocument(data: source, allowZeroOffsetPlaceholders: true)
        } catch {
            throw PaperPathError.insufficientSelection(
                "This PDF structure cannot yet be optimized while keeping its content. Choose Image copy only if you can remove search, links, forms, and notes. The original is unchanged."
            )
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".compression-\(UUID().uuidString).pdf")
        var published = false
        var completed = false
        defer {
            try? manager.removeItem(at: staging)
            if published && !completed { try? manager.removeItem(at: destination) }
        }
        guard manager.createFile(atPath: staging.path, contents: nil, attributes: [
            .protectionKey: FileProtectionType.complete
        ]) else { throw PaperPathError.insufficientStorage }
        LocalFileSecurity.excludeFromBackup(staging)
        let handle = try FileHandle(forWritingTo: staging)
        do {
            let references = structure.allObjects()
            let byNumber = Dictionary(uniqueKeysWithValues: references.map { ($0.number, $0) })
            // Stream lengths are often separate integer objects (e.g. scanner
            // exports). Resolve through the xref, never by searching image bytes.
            let resolveLength: (String) throws -> Int? = { value in
                if let direct = Int(value) { return direct }
                let tokens = value.split(whereSeparator: \.isWhitespace)
                guard tokens.count == 3, tokens[2] == "R",
                      let number = Int(tokens[0]), let generation = Int(tokens[1]),
                      let reference = byNumber[number], reference.generation == generation else { return nil }
                try mapping.reader.seek(toOffset: UInt64(reference.offset))
                guard let bytes = try mapping.reader.read(upToCount: 256) else { return nil }
                let body = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isWhitespace)
                guard body.count >= 5, body[0] == tokens[0], body[1] == tokens[1],
                      body[2] == "obj", body[4] == "endobj" else { return nil }
                return Int(body[3])
            }
            let transform: (Data) throws -> Data? = { object in
                try Task.checkCancellation()
                return try autoreleasepool {
                    try pdfLosslessCompressionObject(object, imageQuality: imageQuality, resolveLength: resolveLength)
                }
            }
            switch structure {
            case .classic(let document):
                try document.writeCompressed(to: handle, transform: transform, progress: progress, reader: mapping.reader)
            case .xrefStream(let document):
                try document.writeCompressed(to: handle, transform: transform, progress: progress, reader: mapping.reader)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try Task.checkCancellation()
        let outputBytes = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard outputBytes > 0 else { throw PaperPathError.unreadablePDF }
        guard outputBytes + 128 < sourceBytes else {
            throw PaperPathError.compressionNotBeneficial(
                sourceByteCount: Int64(sourceBytes), candidateByteCount: Int64(outputBytes)
            )
        }
        progress(0.88)
        // Every non-image object is copied verbatim or losslessly deflated.
        // Independently reopen pages to catch invalid geometry/text/annotations.
        guard let original = PDFDocument(url: sourceURL), !original.isLocked,
              let output = PDFDocument(url: staging), !output.isLocked,
              original.pageCount > 0, original.pageCount <= Self.maximumPageCount,
              original.pageCount == output.pageCount else {
            throw PaperPathError.outputVerificationFailed("the compressed PDF could not be reopened with every page")
        }
        var lastPercent = 87
        for index in 0..<original.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let before = original.page(at: index), let after = output.page(at: index),
                      before.bounds(for: .mediaBox) == after.bounds(for: .mediaBox),
                      before.bounds(for: .cropBox) == after.bounds(for: .cropBox),
                      before.rotation == after.rotation,
                      before.string == after.string,
                      before.annotations.count == after.annotations.count else {
                    throw PaperPathError.outputVerificationFailed("compression changed page geometry, searchable text, or annotations")
                }
            }
            let fraction = 0.88 + 0.1 * Double(index + 1) / Double(original.pageCount)
            let percent = Int(fraction * 100)
            if percent > lastPercent { progress(fraction); lastPercent = percent }
        }
        try Self.requireUnchangedSource(at: sourceURL, initialValues: identity)
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: destination)
        published = true
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        LocalFileSecurity.excludeFromBackup(destination)
        try Task.checkCancellation()
        completed = true
        progress(1)
    }
}

/// Only replaces top-level values, preserving all unknown dictionary entries.
private func pdfCompressionDictionary(
    _ dictionary: Data, setting values: [String: String]
) -> Data? {
    guard let range = pdfFirstDictionaryRange(in: dictionary) else { return nil }
    var edits: [(Range<Int>, Data)] = []
    var additions = ""
    for key in values.keys.sorted() {
        guard let value = values[key] else { continue }
        if let valueRange = pdfTopLevelValueRange(for: key, in: dictionary, dictionaryRange: range) {
            edits.append((valueRange, Data(value.utf8)))
        } else {
            additions += " /\(key) \(value)"
        }
    }
    var result = dictionary
    for edit in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
        result.replaceSubrange(edit.0, with: edit.1)
    }
    guard let updatedRange = pdfFirstDictionaryRange(in: result) else { return nil }
    result.insert(contentsOf: additions.utf8, at: updatedRange.upperBound - 2)
    return result
}

private func pdfLosslessCompressionObject(
    _ object: Data, imageQuality: PDFCompressionQuality?,
    resolveLength: (String) throws -> Int?
) throws -> Data? {
    // Cap both encoded and decoded work per object. Large objects are streamed
    // unchanged; masks, 1-bit scans, ICC, and unfamiliar filters stay intact.
    guard let dictionaryRange = pdfFirstDictionaryRange(in: object),
          dictionaryRange.count <= 64 * 1_024 else { return nil }
    let dictionary = Data(object[dictionaryRange])
    guard let values = pdfCompressionValues(dictionary) else { return nil }
    func value(_ key: String) -> String? {
        values[key]
    }
    if value("Type") == "/Sig" || value("ByteRange") != nil {
        throw PaperPathError.insufficientSelection(
            "This PDF contains a digital signature. Recompression would invalidate it, so compression was stopped. Use an unsigned version to compress this document."
        )
    }
    if value("Linearized") != nil {
        // The rewritten file has new offsets and is no longer linearized.
        // Keep the object number valid but discard its obsolete hint dictionary.
        var result = Data(object[..<dictionaryRange.lowerBound])
        result.append(Data("null\nendobj\n".utf8))
        return result
    }
    guard let lengthText = value("Length"), let length = try resolveLength(lengthText),
          length > 0, length <= 32 * 1_024 * 1_024,
          let marker = object.range(of: Data("stream".utf8), in: dictionaryRange.upperBound..<object.endIndex)
    else { return nil }
    var start = marker.upperBound
    guard start < object.count else { return nil }
    if object[start] == 13 {
        start += 1
        if start < object.count, object[start] == 10 { start += 1 }
    } else if object[start] == 10 {
        start += 1
    } else { return nil }
    guard length <= object.count - start else { return nil }
    let end = start + length
    let streamEnd = pdfSkipWhitespaceAndComments(in: object, start: end, limit: object.count)
    guard object[streamEnd...].starts(with: Data("endstream".utf8)) else { return nil }
    let encoded = Data(object[start..<end])
    var replacement: Data?
    var settings: [String: String] = [:]
    if let imageQuality, value("Subtype") == "/Image" {
        if let candidate = try pdfHighQualityCompressionImage(encoded, values: values, quality: imageQuality) {
            replacement = candidate.bytes
            settings = candidate.settings
            if settings["Filter"] == "/DCTDecode", value("DecodeParms") != nil {
                settings["DecodeParms"] = "null"
            }
        }
    }
    if replacement == nil, value("Filter") == nil, value("DecodeParms") == nil,
              value("Type") != "/EmbeddedFile" {
        // Default lossless path: no image decoding, resizing, or JPEG encoding.
        // Every proposed Flate stream must round-trip to identical bytes.
        replacement = pdfCompressionDeflate(encoded)
        settings = ["Filter": "/FlateDecode"]
    } else if replacement == nil, value("Type") != "/EmbeddedFile",
              let filter = value("Filter"),
              ["/FlateDecode", "/Fl", "[/FlateDecode]", "[ /FlateDecode ]", "[/Fl]"].contains(filter),
              let decoded = pdfInflateZlib(encoded, maximumOutputByteCount: 32 * 1_024 * 1_024) {
        // Re-encode existing Flate streams at level 9 as well. Predictor bytes
        // and DecodeParms stay intact: identical inflated bytes mean identical
        // pixels, text, fonts and object-stream contents after PDF decoding.
        try Task.checkCancellation()
        replacement = pdfCompressionDeflate(decoded)
    }
    try Task.checkCancellation()
    guard let replacement, replacement.count + 128 < encoded.count else { return nil }
    settings["Length"] = "\(replacement.count)"
    guard let updated = pdfCompressionDictionary(dictionary, setting: settings) else { return nil }
    var result = Data(object[..<dictionaryRange.lowerBound])
    result.append(updated)
    result.append(object[dictionaryRange.upperBound..<start])
    result.append(replacement)
    result.append(object[end...])
    return result.count < object.count ? result : nil
}

/// Writes one object at a time, never retaining all replacement images or an
/// output-sized Data buffer. Offset lookup is O(n), rather than sorting per object.
private func pdfWriteCompressionBody(
    data: Data, startXRef: Int, objects: [PDFImageObjectReference],
    to handle: FileHandle, transform: (Data) throws -> Data?,
    progress: PDFProgressHandler, reader: FileHandle
) throws -> [Int: Int] {
    guard let first = objects.first, first.offset > 0 else { throw PaperPathError.unreadablePDF }
    var offsets: [Int: Int] = [:]
    var written = 0
    var lastPercent = -1
    func read(_ range: Range<Int>) throws -> Data {
        try reader.seek(toOffset: UInt64(range.lowerBound))
        guard let bytes = try reader.read(upToCount: range.count), bytes.count == range.count else {
            throw PaperPathError.outputVerificationFailed("the source PDF changed or became unreadable during compression")
        }
        return bytes
    }
    func copy(_ range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            try Task.checkCancellation()
            let end = min(cursor + 256 * 1_024, range.upperBound)
            try autoreleasepool {
                try handle.write(contentsOf: read(cursor..<end))
            }
            written += end - cursor
            cursor = end
        }
    }
    try copy(0..<first.offset)
    for (index, object) in objects.enumerated() {
        try Task.checkCancellation()
        let end = index + 1 < objects.count ? objects[index + 1].offset : startXRef
        guard object.offset < end, end <= data.count else { throw PaperPathError.unreadablePDF }
        offsets[object.number] = written
        try autoreleasepool {
            if end - object.offset <= 32 * 1_024 * 1_024 {
                let bytes = try read(object.offset..<end)
                if let replacement = try transform(bytes) {
                    try handle.write(contentsOf: replacement)
                    written += replacement.count
                } else {
                    try handle.write(contentsOf: bytes)
                    written += bytes.count
                }
            } else {
                // Oversized objects are copied in bounded chunks, without
                // paging their entire payload into the metadata mapping.
                let prefix = try read(object.offset..<min(end, object.offset + 64 * 1_024))
                if prefix.range(of: Data("/ByteRange".utf8)) != nil {
                    throw PaperPathError.insufficientSelection("This PDF contains a digital signature. Recompression would invalidate it, so compression was stopped. Use an unsigned version to compress this document.")
                }
                try copy(object.offset..<end)
            }
        }
        let fraction = 0.02 + 0.82 * Double(end) / Double(startXRef)
        let percent = Int(fraction * 100)
        if percent > lastPercent { progress(fraction); lastPercent = percent }
    }
    return offsets
}

private extension PDFClassicXRefDocument {
    func writeCompressed(to handle: FileHandle, transform: (Data) throws -> Data?, progress: PDFProgressHandler, reader: FileHandle) throws {
        let objects = allObjects()
        let offsets = try pdfWriteCompressionBody(data: data, startXRef: startXRef, objects: objects,
            to: handle, transform: transform, progress: progress, reader: reader)
        try handle.write(contentsOf: Data("\n".utf8))
        let xrefOffset = try handle.offset()
        try handle.write(contentsOf: Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for number in 1..<size {
            try Task.checkCancellation()
            let line: String
            if let entry = entries[number], let offset = offsets[number] {
                line = String(format: "%010lld %05d n \n", Int64(offset), entry.generation)
            } else { line = "0000000000 00000 f \n" }
            try handle.write(contentsOf: Data(line.utf8))
        }
        try handle.write(contentsOf: Data("trailer\n\(trailerDictionary)\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    }
}

private extension PDFXRefStreamDocument {
    func writeCompressed(to handle: FileHandle, transform: (Data) throws -> Data?, progress: PDFProgressHandler, reader: FileHandle) throws {
        let objects = uncompressedReferences
        let offsets = try pdfWriteCompressionBody(data: data, startXRef: startXRef, objects: objects,
            to: handle, transform: transform, progress: progress, reader: reader)
        var updatedEntries = entries
        for object in objects {
            guard let offset = offsets[object.number], let entry = entries[object.number] else { throw PaperPathError.unreadablePDF }
            updatedEntries[object.number] = Entry(type: 1, field1: UInt64(offset), field2: entry.field2)
        }
        try handle.write(contentsOf: Data("\n".utf8))
        let xrefOffset = try handle.offset()
        updatedEntries[xrefObjectNumber] = Entry(type: 1, field1: xrefOffset, field2: UInt64(xrefGeneration))
        let originalDictionary: Data
        if let compressionTrailer { originalDictionary = compressionTrailer }
        else {
            let prefix = Data(data[startXRef..<min(data.count, startXRef + 64 * 1_024)])
            guard let range = pdfFirstDictionaryRange(in: prefix) else { throw PaperPathError.unreadablePDF }
            originalDictionary = Data(prefix[range])
        }
        guard let compressed = pdfCompressionDeflate(Self.xrefBytes(entries: updatedEntries, size: size)),
              let dictionary = pdfCompressionDictionary(originalDictionary, setting: [
                "W": "[1 8 4]", "Index": "[0 \(size)]", "Length": "\(compressed.count)", "Filter": "/FlateDecode"
              ]) else { throw PaperPathError.unreadablePDF }
        try handle.write(contentsOf: Data("\(xrefObjectNumber) \(xrefGeneration) obj\n".utf8))
        try handle.write(contentsOf: dictionary)
        try handle.write(contentsOf: Data("\nstream\n".utf8))
        try handle.write(contentsOf: compressed)
        try handle.write(contentsOf: Data("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    }
}

/// Cancellation-aware admission shared by estimates and compression, including
/// work from different windows. Waiting never occupies the main actor.
private final class PDFCompressionExecutionGate: @unchecked Sendable {
    static let shared = PDFCompressionExecutionGate()
    private let condition = NSCondition()
    private var busy = false

    func enter() throws {
        condition.lock()
        defer { condition.unlock() }
        while busy {
            try Task.checkCancellation()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try Task.checkCancellation()
        busy = true
    }

    func leave() {
        condition.lock()
        busy = false
        condition.broadcast()
        condition.unlock()
    }
}

/// The mapping is used only to parse structural metadata. Payloads are read
/// through a file handle, so sequential image processing does not make the
/// whole input mapping resident in the process.
private final class PDFCompressionMappedInput {
    let data: Data
    let reader: FileHandle

    init(url: URL, count: Int) throws {
        let handle = try FileHandle(forReadingFrom: url)
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              status.st_size == Int64(count),
              let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0),
              pointer != MAP_FAILED else {
            try? handle.close()
            throw PaperPathError.storageFailure("The PDF could not be opened for local compression.")
        }
        reader = handle
        data = Data(bytesNoCopy: pointer, count: count, deallocator: .unmap)
    }

    deinit { try? reader.close() }
}

func pdfCompressionDeflate(_ data: Data) -> Data? {
    guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024 else { return nil }
    var count = compressBound(uLong(data.count))
    var output = Data(count: Int(count))
    let status = output.withUnsafeMutableBytes { destination in
        data.withUnsafeBytes { source in
            compress2(destination.bindMemory(to: Bytef.self).baseAddress!, &count,
                source.bindMemory(to: Bytef.self).baseAddress!, uLong(data.count), Z_BEST_COMPRESSION)
        }
    }
    guard status == Z_OK else { return nil }
    output.count = Int(count)
    // An exact round trip is required for every proposed stream replacement,
    // including images. Visual similarity and OCR text are not sufficient.
    var restoredCount = uLong(data.count)
    var restored = Data(count: data.count)
    let verification = restored.withUnsafeMutableBytes { destination in
        output.withUnsafeBytes { source in
            uncompress(destination.bindMemory(to: Bytef.self).baseAddress!, &restoredCount,
                source.bindMemory(to: Bytef.self).baseAddress!, uLong(output.count))
        }
    }
    guard verification == Z_OK, restoredCount == data.count,
          restored == data else { return nil }
    return output
}

private func pdfRequireUnsignedCompressionSource(_ url: URL) throws {
    guard let document = CGPDFDocument(url as CFURL),
          let catalog = document.catalog else { throw PaperPathError.unreadablePDF }
    var acroForm: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm else { return }
    var fields: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields else { return }
    var queue: [(CGPDFArrayRef, Int)] = [(fields, 0)]
    var visited = 0
    while let (array, depth) = queue.popLast() {
        try Task.checkCancellation()
        guard depth <= 32 else { throw PaperPathError.unreadablePDF }
        for index in 0..<CGPDFArrayGetCount(array) {
            visited += 1
            guard visited <= 100_000 else { throw PaperPathError.unreadablePDF }
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &field), let field else { continue }
            var value: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(field, "V", &value), let value {
                var range: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(value, "ByteRange", &range) {
                    throw PaperPathError.insufficientSelection("This PDF contains a digital signature. Recompression would invalidate it, so compression was stopped. Use an unsigned version to compress this document.")
                }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids { queue.append((kids, depth + 1)) }
        }
    }
}

/// Reject ambiguous or escaped keys rather than confusing a missing /Filter
/// with an unfamiliar spelling of /Filter. Never searches inside string values.
func pdfCompressionValues(_ dictionary: Data) -> [String: String]? {
    guard let range = pdfFirstDictionaryRange(in: dictionary) else { return nil }
    let limit = range.upperBound - 2
    var index = range.lowerBound + 2
    var values: [String: String] = [:]
    while index < limit {
        index = pdfSkipWhitespaceAndComments(in: dictionary, start: index, limit: limit)
        if index == limit { break }
        guard dictionary[index] == 0x2f else { return nil }
        let end = pdfTokenEnd(in: dictionary, start: index + 1, limit: limit)
        guard end > index + 1 else { return nil }
        let key = String(decoding: dictionary[(index + 1)..<end], as: UTF8.self)
        guard !key.contains("#"), values[key] == nil else { return nil }
        let valueStart = pdfSkipWhitespaceAndComments(in: dictionary, start: end, limit: limit)
        guard let valueEnd = pdfObjectValueEnd(in: dictionary, start: valueStart, limit: limit), valueEnd > valueStart else { return nil }
        values[key] = String(decoding: dictionary[valueStart..<valueEnd], as: UTF8.self)
        index = valueEnd
    }
    return values
}

private func pdfCompressionEndOfFile(reader: FileHandle, count: Int) throws -> Int? {
    let marker = Data("%%EOF".utf8)
    var end = count
    while end > 0 {
        try Task.checkCancellation()
        let start = max(0, end - 64 * 1_024)
        try reader.seek(toOffset: UInt64(start))
        guard let bytes = try reader.read(upToCount: end - start), bytes.count == end - start else {
            throw PaperPathError.unreadablePDF
        }
        if let range = bytes.range(of: marker, options: .backwards) { return start + range.upperBound }
        if start == 0 { break }
        end = start + marker.count - 1
    }
    return nil
}

/// Used only after the user selects a lossy mode. Document text and interactive
/// objects remain untouched; image pixels are allowed to change in this mode.
private func pdfHighQualityCompressionImage(
    _ encoded: Data, values: [String: String], quality: PDFCompressionQuality
) throws -> (bytes: Data, settings: [String: String])? {
    guard values["BitsPerComponent"] == "8",
          values["SMask"] == nil, values["Mask"] == nil,
          values["Decode"] == nil,
          values["ImageMask"] != "true", values["Alternates"] == nil,
          values["SMaskInData"] == nil,
          let widthText = values["Width"], let width = Int(widthText),
          let heightText = values["Height"], let height = Int(heightText),
          width >= 64, height >= 64, width <= 100_000, height <= 100_000,
          width * height <= 100_000_000,
          let color = values["ColorSpace"], ["/DeviceRGB", "/DeviceGray", "/DeviceCMYK"].contains(color)
    else { return nil }
    let channels = color == "/DeviceGray" ? 1 : color == "/DeviceCMYK" ? 4 : 3
    let filter = values["Filter"]?.filter { !$0.isWhitespace }
    let targetEdge = Int(quality.longestEdge)
    let image: CGImage
    var lossless: Data?
    if filter == "/DCTDecode" || filter == "[/DCTDecode]" {
        guard values["DecodeParms"] == nil || values["DecodeParms"] == "null" else { return nil }
        guard let source = CGImageSourceCreateWithData(encoded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == height else { return nil }
        if channels == 4 {
            // ImageIO's JPEG thumbnail path applies Adobe's inverted CMYK
            // decode. PDF /DeviceCMYK with no /Decode uses [0 1] per channel.
            // Decode bounded full CMYK samples and apply PDF's mapping before
            // RGB conversion; otherwise gold artwork can become blue/gray.
            guard width * height * 4 <= 48 * 1_024 * 1_024,
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  raw.bitsPerComponent == 8, raw.bitsPerPixel == 32,
                  let provider = raw.dataProvider,
                  let corrected = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: raw.bytesPerRow, space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: raw.bitmapInfo,
                    provider: provider, decode: [0, 1, 0, 1, 0, 1, 0, 1], shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            image = corrected
        } else {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: min(targetEdge, max(width, height)),
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
            image = thumbnail
        }
    } else if filter == "/FlateDecode" || filter == "[/FlateDecode]" || filter == nil {
        let byteCount = width * height * channels
        guard byteCount <= 32 * 1_024 * 1_024 else { return nil }
        let decoded: Data
        if filter != nil {
            guard let bytes = pdfInflateZlib(encoded, maximumOutputByteCount: min(32 * 1_024 * 1_024, byteCount + height)) else { return nil }
            if let parms = values["DecodeParms"], parms != "null" {
                guard let options = pdfCompressionValues(Data(parms.utf8)),
                      let restored = pdfUndoCompressionPredictor(bytes, values: options), restored.count == byteCount else { return nil }
                decoded = restored
            } else {
                guard bytes.count == byteCount else { return nil }
                decoded = bytes
            }
        } else {
            guard encoded.count == byteCount else { return nil }
            decoded = encoded
            lossless = pdfCompressionDeflate(encoded)
        }
        guard let provider = CGDataProvider(data: decoded as CFData),
              let raw = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: channels * 8, bytesPerRow: width * channels,
                space: channels == 1 ? CGColorSpaceCreateDeviceGray() : channels == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        image = raw
    } else { return nil }
    try Task.checkCancellation()
    let scale = min(1, CGFloat(targetEdge) / CGFloat(max(image.width, image.height)))
    let outWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let outHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: channels == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
    guard let resized = context.makeImage() else { return nil }
    let jpeg = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: quality.jpegQuality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    try Task.checkCancellation()
    if let lossless, lossless.count <= jpeg.length {
        return (lossless, ["Filter": "/FlateDecode"])
    }
    return (jpeg as Data, ["Filter": "/DCTDecode", "Width": "\(outWidth)", "Height": "\(outHeight)",
                          "ColorSpace": channels == 1 ? "/DeviceGray" : "/DeviceRGB"])
}

// Compression-only xref reader. Other mutation paths retain their stricter
// admission rules. Resolves newest entries first, including free entries, and
// follows both incremental and linearized /Prev chains with cycle/budget guards.
private extension PDFXRefStreamDocument {
    init(compressionData data: Data) throws {
        guard data.starts(with: Data("%PDF-".utf8)),
              let marker = data.range(of: Data("startxref".utf8), options: .backwards) else {
            throw PaperPathError.unreadablePDF
        }
        func integer(_ text: String?) -> Int? { text.flatMap(Int.init) }
        func array(_ text: String?) -> [Int]? {
            guard let text, text.first == "[", text.last == "]" else { return nil }
            let tokens = text.dropFirst().dropLast().split(whereSeparator: \.isWhitespace)
            let values = tokens.compactMap { Int($0) }
            return values.count == tokens.count ? values : nil
        }
        func dictionary(at offset: Int) throws -> Data {
            guard offset >= 0, offset < data.count else { throw PaperPathError.unreadablePDF }
            let prefix = Data(data[offset..<min(data.count, offset + 64 * 1_024)])
            guard let range = pdfFirstDictionaryRange(in: prefix) else { throw PaperPathError.unreadablePDF }
            return Data(prefix[range])
        }
        var cursor = marker.upperBound
        func token() throws -> String {
            cursor = pdfSkipWhitespaceAndComments(in: data, start: cursor, limit: data.count)
            guard cursor < data.count else { throw PaperPathError.unreadablePDF }
            let end = pdfTokenEnd(in: data, start: cursor, limit: data.count)
            guard end > cursor, end - cursor < 128 else { throw PaperPathError.unreadablePDF }
            defer { cursor = end }
            return String(decoding: data[cursor..<end], as: UTF8.self)
        }
        guard let firstOffset = Int(try token()) else { throw PaperPathError.unreadablePDF }
        var pending = [firstOffset], visited = Set<Int>(), parsed: [Int: Entry] = [:]
        var trailer: Data?, trailerValues: [String: String] = [:], maximumSize = 0
        var totalEntries = 0
        while let offset = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(offset).inserted, visited.count <= 64,
                  offset > 0, offset < data.count else { throw PaperPathError.unreadablePDF }
            cursor = offset
            let first = try token()
            let currentDictionary: Data
            var current: [Int: Entry] = [:]
            if first == "xref" {
                while true {
                    let number = try token()
                    if number == "trailer" { break }
                    guard let start = Int(number), let count = Int(try token()),
                          start >= 0, count >= 0, start <= 500_000,
                          count <= 500_000 - start, count <= 1_000_000 - totalEntries else {
                        throw PaperPathError.unreadablePDF
                    }
                    totalEntries += count
                    for n in start..<(start + count) {
                        guard let position = UInt64(try token()), let generation = UInt64(try token()) else {
                            throw PaperPathError.unreadablePDF
                        }
                        let kind = try token()
                        guard kind == "n" || kind == "f", current[n] == nil else { throw PaperPathError.unreadablePDF }
                        current[n] = Entry(type: kind == "n" && position > 0 ? 1 : 0, field1: position, field2: generation)
                    }
                }
                currentDictionary = try dictionary(at: cursor)
            } else {
                guard Int(first) != nil, Int(try token()) != nil, try token() == "obj" else {
                    throw PaperPathError.unreadablePDF
                }
                let start = pdfSkipWhitespaceAndComments(in: data, start: cursor, limit: data.count)
                currentDictionary = try dictionary(at: start)
                guard data[start...].starts(with: currentDictionary),
                      let values = pdfCompressionValues(currentDictionary), values["Type"] == "/XRef",
                      let size = integer(values["Size"]), size > 0, size <= 500_000,
                      let widths = array(values["W"]), widths.count == 3,
                      widths.allSatisfy({ (0...8).contains($0) }), widths.reduce(0, +) > 0,
                      let length = integer(values["Length"]), length > 0, length <= 24 * 1_024 * 1_024 else {
                    throw PaperPathError.unreadablePDF
                }
                cursor = start + currentDictionary.count
                guard try token() == "stream" else { throw PaperPathError.unreadablePDF }
                if cursor < data.count, data[cursor] == 13 {
                    cursor += 1
                    if cursor < data.count, data[cursor] == 10 { cursor += 1 }
                } else if cursor < data.count, data[cursor] == 10 { cursor += 1 }
                else { throw PaperPathError.unreadablePDF }
                guard length <= data.count - cursor else { throw PaperPathError.unreadablePDF }
                let encoded = Data(data[cursor..<(cursor + length)])
                let filter = values["Filter"]?.filter { !$0.isWhitespace }
                let inflated: Data
                if filter == nil { inflated = encoded }
                else if ["/FlateDecode", "/Fl", "[/FlateDecode]", "[/Fl]"].contains(filter!) {
                    guard let decoded = pdfInflateZlib(encoded, maximumOutputByteCount: 32 * 1_024 * 1_024) else {
                        throw PaperPathError.unreadablePDF
                    }
                    inflated = decoded
                } else { throw PaperPathError.unreadablePDF }
                let decoded: Data
                if let parms = values["DecodeParms"], parms != "null" {
                    guard let options = pdfCompressionValues(Data(parms.utf8)),
                          let bytes = pdfUndoCompressionPredictor(inflated, values: options) else {
                        throw PaperPathError.unreadablePDF
                    }
                    decoded = bytes
                } else { decoded = inflated }
                let indices = array(values["Index"]) ?? [0, size]
                guard indices.count.isMultiple(of: 2), indices.count <= 2_048 else { throw PaperPathError.unreadablePDF }
                let stride = widths.reduce(0, +)
                var position = 0
                func read(_ width: Int) -> UInt64 {
                    var value: UInt64 = 0
                    for _ in 0..<width { value = (value << 8) | UInt64(decoded[position]); position += 1 }
                    return value
                }
                for pair in Swift.stride(from: 0, to: indices.count, by: 2) {
                    let first = indices[pair], count = indices[pair + 1]
                    guard first >= 0, count >= 0, first <= size, count <= size - first,
                          count <= (decoded.count - position) / stride,
                          count <= 1_000_000 - totalEntries else { throw PaperPathError.unreadablePDF }
                    totalEntries += count
                    for n in first..<(first + count) {
                        guard current[n] == nil else { throw PaperPathError.unreadablePDF }
                        let type = widths[0] == 0 ? 1 : read(widths[0])
                        let field1 = read(widths[1]), field2 = read(widths[2])
                        guard type <= 2 else { throw PaperPathError.unreadablePDF }
                        current[n] = Entry(type: type, field1: field1, field2: field2)
                    }
                }
                guard position == decoded.count else { throw PaperPathError.unreadablePDF }
            }
            guard let values = pdfCompressionValues(currentDictionary), values["Encrypt"] == nil,
                  let size = integer(values["Size"]), size > 0, size < 500_000 else { throw PaperPathError.unreadablePDF }
            maximumSize = max(maximumSize, size)
            if trailer == nil { trailer = currentDictionary; trailerValues = values }
            else {
                // Inherit omitted trailer entries without re-encoding binary strings.
                for key in ["Root", "Info", "ID"] where trailerValues[key] == nil {
                    if let range = pdfFirstDictionaryRange(in: currentDictionary),
                       let valueRange = pdfTopLevelValueRange(for: key, in: currentDictionary, dictionaryRange: range),
                       var inherited = trailer {
                        inherited.insert(contentsOf: Data(" /\(key) ".utf8) + currentDictionary[valueRange], at: inherited.count - 2)
                        trailer = inherited; trailerValues[key] = values[key]
                    }
                }
            }
            for (n, entry) in current where parsed[n] == nil { parsed[n] = entry }
            if let previous = integer(values["Prev"]) { pending.append(previous) }
            if let hybrid = integer(values["XRefStm"]) { pending.append(hybrid) }
        }
        guard let originalTrailer = trailer, let root = trailerValues["Root"], root.hasSuffix(" R"),
              parsed.count <= 500_000,
              parsed.allSatisfy({ n, e in
                  n >= 0 && n < maximumSize && (e.type != 1 || (e.field1 > 0 && e.field1 < UInt64(data.count) && e.field2 <= 65_535))
              }),
              let cleaned = pdfCompressionRemovingKeys(originalTrailer, keys: ["Prev", "XRefStm", "Type", "W", "Index", "Length", "Filter", "DecodeParms"]),
              let dictionary = pdfCompressionDictionary(cleaned, setting: ["Type": "/XRef", "Size": "\(maximumSize + 1)"])
        else { throw PaperPathError.unreadablePDF }
        self.data = data
        self.startXRef = data.count
        self.size = maximumSize + 1
        self.rootReference = root
        self.infoReference = trailerValues["Info"]
        self.xrefObjectNumber = maximumSize
        self.xrefGeneration = 0
        self.entries = parsed
        self.compressionTrailer = dictionary
    }
}

private func pdfCompressionRemovingKeys(_ dictionary: Data, keys: Set<String>) -> Data? {
    guard let range = pdfFirstDictionaryRange(in: dictionary) else { return nil }
    var cursor = range.lowerBound + 2, edits: [Range<Int>] = []
    let limit = range.upperBound - 2
    while cursor < limit {
        cursor = pdfSkipWhitespaceAndComments(in: dictionary, start: cursor, limit: limit)
        if cursor == limit { break }
        let start = cursor
        guard dictionary[cursor] == 47 else { return nil }
        let keyEnd = pdfTokenEnd(in: dictionary, start: cursor + 1, limit: limit)
        let key = String(decoding: dictionary[(cursor + 1)..<keyEnd], as: UTF8.self)
        let valueStart = pdfSkipWhitespaceAndComments(in: dictionary, start: keyEnd, limit: limit)
        guard let end = pdfObjectValueEnd(in: dictionary, start: valueStart, limit: limit) else { return nil }
        if keys.contains(key) { edits.append(start..<end) }
        cursor = end
    }
    var result = dictionary
    for range in edits.reversed() { result.removeSubrange(range) }
    return result
}

/// Undo PDF TIFF/PNG prediction on already-inflated bytes, bounded by callers.
/// PNG always carries one filter byte per row, including fixed predictors 10-14.
private func pdfUndoCompressionPredictor(_ data: Data, values: [String: String]) -> Data? {
    let predictor = Int(values["Predictor"] ?? "1") ?? -1
    if predictor == 1 { return data }
    guard let columns = Int(values["Columns"] ?? "1"), columns > 0, columns <= 100_000,
          let colors = Int(values["Colors"] ?? "1"), (1...4).contains(colors),
          let bits = Int(values["BitsPerComponent"] ?? "8"), bits == 8 else { return nil }
    let width = columns * colors
    if predictor == 2 {
        guard data.count.isMultiple(of: width) else { return nil }
        var result = data
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for row in Swift.stride(from: 0, to: data.count, by: width) {
                for i in colors..<width { bytes[row + i] = bytes[row + i] &+ bytes[row + i - colors] }
            }
        }
        return result
    }
    guard (10...15).contains(predictor), data.count.isMultiple(of: width + 1) else { return nil }
    let rows = data.count / (width + 1)
    var result = Data(count: rows * width)
    return result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Data? in
        for row in 0..<rows {
            let input = row * (width + 1), target = row * width
            let filter = data[input]
            guard filter <= 4 else { return nil }
            for column in 0..<width {
                let left = column >= colors ? Int(output[target + column - colors]) : 0
                let up = row > 0 ? Int(output[target + column - width]) : 0
                let corner = row > 0 && column >= colors ? Int(output[target + column - width - colors]) : 0
                let prediction: Int
                switch filter {
                case 0: prediction = 0
                case 1: prediction = left
                case 2: prediction = up
                case 3: prediction = (left + up) / 2
                default:
                    let p = left + up - corner
                    let a = abs(p - left), b = abs(p - up), c = abs(p - corner)
                    prediction = a <= b && a <= c ? left : b <= c ? up : corner
                }
                output[target + column] = data[input + 1 + column] &+ UInt8(prediction)
            }
        }
        return Data(bytes: output.baseAddress!, count: output.count)
    }
}

private func rasterPageSize(_ page: PDFPage) -> CGSize {
    let size = page.bounds(for: .cropBox).size
    let rotation = ((page.rotation % 360) + 360) % 360
    return rotation == 90 || rotation == 270 ? CGSize(width: size.height, height: size.width) : size
}

/// Delivery images are exact page renders, not PDFKit's decorated thumbnails.
/// Render at scale 1 to keep the pixel/memory budget independent of screen scale.
private func rasterPageImage(_ page: PDFPage, size: CGSize) -> UIImage? {
    guard let source = page.pageRef, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0, size.width * size.height <= 16_000_000 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1; format.opaque = true; format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
        let context = renderer.cgContext
        let rectangle = CGRect(origin: .zero, size: size)
        context.setFillColor(UIColor.white.cgColor); context.fill(rectangle)
        context.saveGState()
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        let displayedSize = rasterPageSize(page)
        context.scaleBy(x: size.width / displayedSize.width, y: size.height / displayedSize.height)
        context.concatenate(source.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayedSize), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(source)
        for annotation in page.annotations where annotation.shouldDisplay {
            let isWidget = annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "widget"
            // PDFKit draws the field name as an editing placeholder for empty
            // widgets without appearances. That label is not document content.
            if isWidget && !annotation.hasAppearanceStream && (annotation.widgetStringValue ?? "").isEmpty { continue }
            annotation.draw(with: .cropBox, in: context)
        }
        context.restoreGState()
    }
}

private func rasterRedactionRect(_ mark: PDFRedactionMark, rotation: Int, size: CGSize) -> CGRect {
    let x = mark.normalizedX, y = mark.normalizedY, w = mark.normalizedWidth, h = mark.normalizedHeight
    let normalized: CGRect
    switch ((rotation % 360) + 360) % 360 {
    case 90: normalized = CGRect(x: y, y: x, width: h, height: w)
    case 180: normalized = CGRect(x: 1 - x - w, y: y, width: w, height: h)
    case 270: normalized = CGRect(x: 1 - y - h, y: 1 - x - w, width: h, height: w)
    default: normalized = CGRect(x: x, y: 1 - y - h, width: w, height: h)
    }
    return CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                  width: normalized.width * size.width, height: normalized.height * size.height)
}
