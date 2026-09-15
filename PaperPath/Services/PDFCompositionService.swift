import CoreGraphics
import CoreText
import Foundation
import PDFKit

struct PDFCompositionService: Sendable {
    static let maximumSourceDocumentCount = 64
    static let maximumPageCount = 100_000

    func combine(urls: [URL], to destination: URL) throws {
        guard (2...Self.maximumSourceDocumentCount).contains(
            urls.count
        ) else {
            throw PaperPathError.insufficientSelection(
                urls.count < 2
                    ? "Choose at least two PDFs to combine."
                    : "Combine up to 64 PDFs at once."
            )
        }
        let destinationPath = destination.standardizedFileURL.path
        guard !urls.contains(where: {
            $0.standardizedFileURL.path == destinationPath
        }) else {
            throw PaperPathError.insufficientSelection(
                "Create a separate combined copy instead of replacing a source PDF."
            )
        }

        let output = PDFDocument()
        var outputIndex = 0
        var expectedPageCount = 0
        for url in urls {
            try Task.checkCancellation()
            guard let source = PDFDocument(url: url),
                  !source.isLocked,
                  source.pageCount > 0
            else {
                throw PaperPathError.unreadablePDF
            }
            guard source.pageCount <= Self.maximumPageCount else {
                throw PaperPathError.insufficientSelection(
                    "Combine PDFs with up to 100,000 pages each."
                )
            }
            let (nextPageCount, overflow) = expectedPageCount
                .addingReportingOverflow(source.pageCount)
            guard !overflow,
                  nextPageCount <= Self.maximumPageCount
            else {
                throw PaperPathError.insufficientSelection(
                    "Combine up to 100,000 pages at once."
                )
            }
            expectedPageCount = nextPageCount
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                    throw PaperPathError.invalidPage
                }
                output.insert(page, at: outputIndex)
                outputIndex += 1
            }
        }
        try write(
            output,
            expectedPageCount: expectedPageCount,
            to: destination
        )
    }

    func extractPages(
        from sourceURL: URL,
        indices: [Int],
        to destination: URL
    ) throws {
        guard sourceURL.standardizedFileURL.path
                != destination.standardizedFileURL.path
        else {
            throw PaperPathError.insufficientSelection(
                "Create a separate extracted copy instead of replacing the source PDF."
            )
        }
        guard indices.count <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Extract up to 100,000 pages at once."
            )
        }
        let uniqueIndices = Array(Set(indices)).sorted()
        guard !uniqueIndices.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to extract."
            )
        }
        guard let source = PDFDocument(url: sourceURL),
              !source.isLocked,
              source.pageCount > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        guard source.pageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Extract from PDFs with up to 100,000 pages."
            )
        }

        let output = PDFDocument()
        for (outputIndex, pageIndex) in uniqueIndices.enumerated() {
            try Task.checkCancellation()
            guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                throw PaperPathError.invalidPage
            }
            output.insert(page, at: outputIndex)
        }
        try write(
            output,
            expectedPageCount: uniqueIndices.count,
            to: destination
        )
    }

    func write(
        _ document: PDFDocument,
        expectedPageCount: Int,
        to destination: URL
    ) throws {
        guard expectedPageCount > 0 else {
            throw PaperPathError.storageFailure("The new PDF contained no pages.")
        }
        guard expectedPageCount <= Self.maximumPageCount else {
            throw PaperPathError.insufficientSelection(
                "Create PDFs with up to 100,000 pages."
            )
        }
        guard document.pageCount == expectedPageCount else {
            throw PaperPathError.outputVerificationFailed(
                "the composed PDF did not contain every selected page"
            )
        }
        let fileManager = FileManager.default
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".composition-\(UUID().uuidString).pdf"
            )
        defer { try? fileManager.removeItem(at: stagingURL) }

        try Task.checkCancellation()
        guard document.write(to: stagingURL) else {
            throw PaperPathError.storageFailure(
                "The new PDF could not be written."
            )
        }
        try LocalFileSecurity.requireCompleteProtection(to: stagingURL)
        try verifyOutput(
            at: stagingURL,
            expectedPageCount: expectedPageCount
        )
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            try replaceExistingItem(
                at: destination,
                with: stagingURL
            )
        } else {
            try fileManager.moveItem(
                at: stagingURL,
                to: destination
            )
            do {
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
            } catch {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                throw error
            }
        }
    }

    func verifyOutput(
        at url: URL,
        expectedPageCount: Int
    ) throws {
        guard (1...Self.maximumPageCount).contains(
            expectedPageCount
        ),
              let reopened = PDFDocument(url: url),
              !reopened.isLocked,
              reopened.pageCount == expectedPageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the composed PDF could not be reopened with every page"
            )
        }

        for pageIndex in 0..<reopened.pageCount {
            try Task.checkCancellation()
            guard let page = reopened.page(at: pageIndex) else {
                throw PaperPathError.outputVerificationFailed(
                    "a composed page could not be reopened"
                )
            }
            let mediaBounds = page.bounds(for: .mediaBox)
            let cropBounds = page.bounds(for: .cropBox)
            guard Self.hasValidGeometry(mediaBounds),
                  Self.hasValidGeometry(cropBounds)
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a composed page has invalid geometry"
                )
            }
        }
    }

    func replaceExistingItem(
        at destination: URL,
        with stagingURL: URL
    ) throws {
        let fileManager = FileManager.default
        let backupName =
            ".composition-rollback-\(UUID().uuidString).pdf"
        let backupURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(backupName)
        defer { try? fileManager.removeItem(at: backupURL) }

        do {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: stagingURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
            try LocalFileSecurity.requireCompleteProtection(
                to: destination
            )
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw error
            }
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(
                        destination,
                        withItemAt: backupURL
                    )
                } else {
                    try fileManager.moveItem(
                        at: backupURL,
                        to: destination
                    )
                }
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
            } catch {
                throw PaperPathError.storageFailure(
                    "The previous PDF could not be restored after publishing failed."
                )
            }
            throw error
        }
    }

    private static func hasValidGeometry(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }
}

struct SearchablePDFService: Sendable {
    private static let maximumPageCount = 100_000
    private static let maximumBlocksPerPage = 4_096
    private static let maximumTotalBlocks = 100_000
    private static let maximumBlockTextBytes = 16 * 1_024

    func createSearchableCopy(
        sourceURL: URL,
        ocrResult: OCRResult,
        destination: URL,
        progress: @escaping PDFProgressHandler = { _ in }
    ) throws {
        progress(0)
        guard !ocrResult.pages.isEmpty else {
            throw PaperPathError.missingRecognizedText
        }
        guard let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              (1...Self.maximumPageCount).contains(
                source.numberOfPages
              ),
              let firstPage = source.page(at: 1)
        else {
            throw PaperPathError.unreadablePDF
        }
        let relevantPages = ocrResult.pages.filter {
            $0.pageIndex >= 0
                && $0.pageIndex < source.numberOfPages
        }
        guard relevantPages.contains(where: { !$0.blocks.isEmpty }) else {
            throw PaperPathError.missingRecognizedText
        }
        try validate(
            relevantPages,
            sourcePageCount: source.numberOfPages
        )

        var defaultBox = firstPage.getBoxRect(.mediaBox)
        guard Self.hasValidGeometry(defaultBox) else {
            throw PaperPathError.invalidPage
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PaperPathError.storageFailure(
                "The searchable PDF destination already exists."
            )
        }
        let stagingURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".searchable-\(UUID().uuidString).pdf"
            )
        defer { try? fileManager.removeItem(at: stagingURL) }
        guard let consumer = CGDataConsumer(url: stagingURL as CFURL)
        else {
            throw PaperPathError.storageFailure(
                "The searchable PDF staging file could not be created."
            )
        }
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            nil
        ) else {
            throw PaperPathError.storageFailure(
                "The searchable PDF context could not be created."
            )
        }
        var didCloseContext = false
        var publishedDestination = false
        defer {
            if !didCloseContext {
                context.closePDF()
            }
        }

        do {
            let resultsByPage = relevantPages.reduce(
                into: [Int: OCRPageResult]()
            ) { result, page in
                result[page.pageIndex] = page
            }
            var lastReportedPercent = -1

            for pageNumber in 1...source.numberOfPages {
                try Task.checkCancellation()
                guard let sourcePage = source.page(at: pageNumber)
                else {
                    throw PaperPathError.invalidPage
                }
                let mediaBox = sourcePage.getBoxRect(.mediaBox)
                guard Self.hasValidGeometry(mediaBox) else {
                    throw PaperPathError.invalidPage
                }
                let pageInfo = [
                    kCGPDFContextMediaBox as String: mediaBox
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

                if let pageResult = resultsByPage[pageNumber - 1] {
                    try drawInvisibleText(
                        pageResult.blocks,
                        in: mediaBox,
                        context: context
                    )
                }
                context.endPDFPage()
                let fraction = 0.82 * Double(pageNumber)
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
            try LocalFileSecurity.requireCompleteProtection(
                to: stagingURL
            )
            try verifyOutput(
                at: stagingURL,
                expectedPageCount: source.numberOfPages,
                searchablePageIndices: Set(
                    resultsByPage.values
                        .filter { !$0.blocks.isEmpty }
                        .map(\.pageIndex)
                )
            )
            progress(0.94)
            try Task.checkCancellation()
            try fileManager.moveItem(at: stagingURL, to: destination)
            publishedDestination = true
            try LocalFileSecurity.requireCompleteProtection(to: destination)
            LocalFileSecurity.excludeFromBackup(destination)
            progress(1)
        } catch {
            if !didCloseContext {
                context.closePDF()
                didCloseContext = true
            }
            if publishedDestination,
               fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    private func drawInvisibleText(
        _ blocks: [OCRTextBlock],
        in mediaBox: CGRect,
        context: CGContext
    ) throws {
        context.saveGState()
        defer { context.restoreGState() }
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity

        for (index, block) in blocks.enumerated()
        where !block.text.isEmpty {
            if index.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            let x = mediaBox.minX + CGFloat(block.normalizedX) * mediaBox.width
            let y = mediaBox.minY + CGFloat(block.normalizedY) * mediaBox.height
            let height = CGFloat(block.normalizedHeight) * mediaBox.height
            let fontSize = max(4, min(72, height * 0.82))
            let font = CTFontCreateWithName(
                "Helvetica" as CFString,
                fontSize,
                nil
            )
            let attributed = NSAttributedString(
                string: block.text,
                attributes: [
                    NSAttributedString.Key(
                        rawValue: kCTFontAttributeName as String
                    ): font
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: x, y: y + height * 0.12)
            CTLineDraw(line, context)
        }
    }

    func validate(
        _ pages: [OCRPageResult],
        sourcePageCount: Int
    ) throws {
        guard (1...Self.maximumPageCount).contains(
            sourcePageCount
        ) else {
            throw PaperPathError.insufficientSelection(
                "Create searchable copies with up to 100,000 pages."
            )
        }
        var seenPageIndices: Set<Int> = []
        var totalBlocks = 0
        for page in pages {
            try Task.checkCancellation()
            let (nextTotal, overflow) = totalBlocks
                .addingReportingOverflow(page.blocks.count)
            guard page.pageIndex >= 0,
                  page.pageIndex < sourcePageCount,
                  seenPageIndices.insert(page.pageIndex).inserted,
                  page.confidence.isFinite,
                  (0...1).contains(page.confidence),
                  page.blocks.count <= Self.maximumBlocksPerPage,
                  !overflow,
                  nextTotal <= Self.maximumTotalBlocks
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the OCR result did not match this PDF"
                )
            }
            for (index, block) in page.blocks.enumerated() {
                if index.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                guard Self.isValid(block) else {
                    throw PaperPathError.outputVerificationFailed(
                        "the OCR result contained an invalid text region"
                    )
                }
            }
            totalBlocks = nextTotal
        }
    }

    func verifyOutput(
        at url: URL,
        expectedPageCount: Int,
        searchablePageIndices: Set<Int>
    ) throws {
        guard (1...Self.maximumPageCount).contains(
            expectedPageCount
        ),
              let reopened = PDFDocument(url: url),
              !reopened.isLocked,
              reopened.pageCount == expectedPageCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the searchable PDF could not be reopened with every page"
            )
        }
        for pageIndex in 0..<reopened.pageCount {
            try Task.checkCancellation()
            guard let page = reopened.page(at: pageIndex),
                  Self.hasValidGeometry(page.bounds(for: .mediaBox))
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a searchable PDF page has invalid geometry"
                )
            }
            if searchablePageIndices.contains(pageIndex) {
                let text = page.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text?.isEmpty == false else {
                    throw PaperPathError.outputVerificationFailed(
                        "the searchable text layer could not be reopened"
                    )
                }
            }
        }
    }

    private static func isValid(_ block: OCRTextBlock) -> Bool {
        let values = [
            block.normalizedX,
            block.normalizedY,
            block.normalizedWidth,
            block.normalizedHeight
        ]
        return !block.text.isEmpty
            && block.text.utf8.count <= maximumBlockTextBytes
            && block.confidence.isFinite
            && (0...1).contains(block.confidence)
            && values.allSatisfy(\.isFinite)
            && block.normalizedX >= -0.001
            && block.normalizedY >= -0.001
            && block.normalizedWidth > 0
            && block.normalizedHeight > 0
            && block.normalizedX + block.normalizedWidth <= 1.001
            && block.normalizedY + block.normalizedHeight <= 1.001
    }

    private static func hasValidGeometry(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width > 0
            && bounds.height > 0
    }
}
