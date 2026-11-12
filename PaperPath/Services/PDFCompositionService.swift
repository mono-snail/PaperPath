import CoreGraphics
import CoreText
import CryptoKit
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
            let rawSource = CGPDFDocument(url as CFURL)
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                    throw PaperPathError.invalidPage
                }
                try restoreCopiedNoteBounds(from: rawSource?.page(at: pageIndex + 1), to: page)
                output.insert(page, at: outputIndex)
                outputIndex += 1
            }
        }
        try write(
            output,
            expectedPageCount: expectedPageCount,
            to: destination,
            sourceURLs: urls
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
        let rawSource = CGPDFDocument(sourceURL as CFURL)
        for (outputIndex, pageIndex) in uniqueIndices.enumerated() {
            try Task.checkCancellation()
            guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                throw PaperPathError.invalidPage
            }
            try restoreCopiedNoteBounds(from: rawSource?.page(at: pageIndex + 1), to: page)
            output.insert(page, at: outputIndex)
        }
        try write(
            output,
            expectedPageCount: uniqueIndices.count,
            to: destination,
            sourceURLs: [sourceURL]
        )
    }

    private func restoreCopiedNoteBounds(from source: CGPDFPage?, to page: PDFPage) throws {
        // PDFKit normalizes loaded Text notes to 24pt before copying. Keep the
        // original PDF rectangle so composing pages does not shrink note icons.
        let notes = page.annotations.filter {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "text"
        }
        guard !notes.isEmpty else { return }
        guard let dictionary = source?.dictionary else {
            throw PaperPathError.outputVerificationFailed("original note geometry could not be read")
        }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else {
            throw PaperPathError.outputVerificationFailed("original notes could not be read")
        }
        var rectangles: [CGRect] = []
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Text" else { continue }
            var rect: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(annotation, "Rect", &rect), let rect,
                  CGPDFArrayGetCount(rect) == 4 else {
                throw PaperPathError.outputVerificationFailed("original note bounds are invalid")
            }
            var numbers = [CGPDFReal](repeating: 0, count: 4)
            for component in 0..<4 {
                guard CGPDFArrayGetNumber(rect, component, &numbers[component]), numbers[component].isFinite else {
                    throw PaperPathError.outputVerificationFailed("original note bounds are invalid")
                }
            }
            rectangles.append(CGRect(x: numbers[0], y: numbers[1],
                width: numbers[2] - numbers[0], height: numbers[3] - numbers[1]).standardized)
        }
        guard rectangles.count == notes.count else {
            throw PaperPathError.outputVerificationFailed("copied note count changed")
        }
        for (note, rectangle) in zip(notes, rectangles) { note.bounds = rectangle }
    }

    func write(
        _ document: PDFDocument,
        expectedPageCount: Int,
        to destination: URL,
        sourceURLs: [URL] = []
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
        try PDFContentPreservingWriter.write(document, to: stagingURL, sourceURLs: sourceURLs)
        var attachmentPayloads: [PDFEmbeddedAttachmentPayload] = []
        for source in sourceURLs {
            for payload in try PDFDocumentStructureService().attachmentPayloads(in: source)
            where payload.snapshot.origin == .document {
                if let existing = attachmentPayloads.first(where: {
                    $0.snapshot.fileName.caseInsensitiveCompare(payload.snapshot.fileName) == .orderedSame
                }) {
                    guard existing.snapshot.checksum == payload.snapshot.checksum else {
                        throw PaperPathError.insufficientSelection("Rename embedded files with duplicate names before combining these PDFs.")
                    }
                } else { attachmentPayloads.append(payload) }
            }
        }
        if !attachmentPayloads.isEmpty {
            let preserved = try PDFCatalogStructureAppender(data: Data(contentsOf: stagingURL))
                .appending(attachmentPayloads: attachmentPayloads, pageLabels: [])
            try preserved.write(to: stagingURL, options: .atomic)
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
                    kCGPDFContextMediaBox as String: pdfPageBoxData(mediaBox)
                ] as CFDictionary
                context.beginPDFPage(pageInfo)

                // This temporary PDF contains only the invisible text. Drawing
                // the source through CGContext would rebuild its original font
                // maps and can turn existing searchable text into control codes.
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
            guard let sourceKit = PDFDocument(url: sourceURL),
                  let textLayers = CGPDFDocument(stagingURL as CFURL)
            else { throw PaperPathError.unreadablePDF }
            var overlays: [Int: CGPDFPage] = [:]
            for (index, result) in resultsByPage where !result.blocks.isEmpty {
                guard let page = textLayers.page(at: index + 1) else { throw PaperPathError.invalidPage }
                overlays[index] = page
            }
            let composed = stagingURL.deletingLastPathComponent().appendingPathComponent(".ocr-composed-\(UUID()).pdf")
            defer { try? fileManager.removeItem(at: composed) }
            // Form XObjects give the OCR fonts their own resource namespace;
            // the writer verifies original commands and Unicode maps unchanged.
            try PDFContentPreservingWriter.write(sourceKit, to: composed,
                sourceURLs: [sourceURL], imageOverlayPages: overlays)
            withExtendedLifetime(textLayers) {}
            try fileManager.removeItem(at: stagingURL)
            try fileManager.moveItem(at: composed, to: stagingURL)
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

/// PDFKit may regenerate subset-font CMaps when writing, losing original glyph
/// identities (especially GlyphLessFont OCR). Keep its edited page tree and
/// annotations, but restore original page content/resources when that occurs.
struct PDFContentPreservingWriter {
    static func write(_ document: PDFDocument, to destination: URL, sourceURLs: [URL] = [],
                      options: [PDFDocumentWriteOption: Any]? = nil, password: String? = nil, sourcePassword: String? = nil,
                      imageOverlayPages: [Int: CGPDFPage] = [:]) throws {
        let pages = (0..<document.pageCount).map { document.page(at: $0) }
        let originals = pages.map { $0?.pageRef }
        let texts = pages.map { normalized($0?.string) }
        guard document.write(to: destination, withOptions: options), let reopened = PDFDocument(url: destination),
              reopened.pageCount == pages.count else { throw PaperPathError.unreadablePDF }
        if let password { guard reopened.unlock(withPassword: password) else { throw PaperPathError.lockedPDF } }
        let changed = texts.enumerated().contains { normalized(reopened.page(at: $0.offset)?.string) != $0.element }
        guard let staging = CGPDFDocument(destination as CFURL) else { throw PaperPathError.unreadablePDF }
        if let password { guard password.withCString({ staging.unlockWithPassword($0) }) else { throw PaperPathError.lockedPDF } }
        guard let catalog = staging.catalog else { throw PaperPathError.unreadablePDF }
        var form: CGPDFDictionaryRef?
        let hasForm = CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form)
            || (0..<reopened.pageCount).contains { reopened.page(at: $0)?.annotations.contains { $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "widget" } == true }
        let needsAppearances = (0..<reopened.pageCount).contains { index in
            reopened.page(at: index)?.annotations.contains {
                $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "widget" && $0.widgetFieldType != .signature && !$0.hasAppearanceStream
                    && !($0.widgetStringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.widgetStringValue != "Off"
            } == true
        }
        // Retain document-level names (including embedded files) which PDFKit
        // drops during a native write. Keep backing documents alive while copying.
        let sourceDocuments = sourceURLs.compactMap { CGPDFDocument($0 as CFURL) }
        if let sourcePassword {
            for source in sourceDocuments { _ = sourcePassword.withCString { source.unlockWithPassword($0) } }
        }
        var catalogValues: [String: CGPDFObjectRef] = [:]
        if password == nil, sourcePassword == nil, sourceDocuments.count == 1, let originalCatalog = sourceDocuments.first?.catalog {
            for key in ["Names", "AF"] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(originalCatalog, key, &object), let object { catalogValues[key] = object }
            }
        }
        guard changed || hasForm || !imageOverlayPages.isEmpty || !catalogValues.isEmpty else { return }
        var overrides: [UInt: [String: CGPDFObjectRef]] = [:]
        for (index, original) in originals.enumerated() {
            guard let source = original?.dictionary, let target = staging.page(at: index + 1)?.dictionary else { continue }
            var values: [String: CGPDFObjectRef] = [:]
            for key in ["Contents", "Resources", "Group"] {
                var ancestor: CGPDFDictionaryRef? = source
                for _ in 0..<32 {
                    guard let dictionary = ancestor else { break }
                    var object: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(dictionary, key, &object), let object { values[key] = object; break }
                    if key != "Resources" { break }
                    var parent: CGPDFDictionaryRef?
                    _ = CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent)
                    ancestor = parent
                }
            }
            overrides[UInt(bitPattern: target.rawValue)] = values
        }
        if !catalogValues.isEmpty { overrides[UInt(bitPattern: catalog.rawValue)] = catalogValues }
        let repaired = destination.deletingLastPathComponent().appendingPathComponent(".original-content-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: repaired) }
        let encryption = try password.map { try PDFCatalogStructureAppender(data: Data(contentsOf: destination))
            .originalObjectEncryption(password: $0) }
        let writer = PDFOriginalObjectWriter(overrides: overrides, encodedImages: try encodedLargeImages(sourceURLs, password: sourcePassword), encryption: encryption, needsAppearances: needsAppearances)
        try writer.installImageOverlays(imageOverlayPages, in: staging)
        try writer.write(document: staging, to: repaired)
        guard let result = PDFDocument(url: repaired), result.pageCount == texts.count else { throw PaperPathError.unreadablePDF }
        if let password { guard result.unlock(withPassword: password) else { throw PaperPathError.lockedPDF } }
        guard let rawResult = CGPDFDocument(repaired as CFURL) else { throw PaperPathError.unreadablePDF }
        if let password { guard password.withCString({ rawResult.unlockWithPassword($0) }) else { throw PaperPathError.lockedPDF } }
        for index in texts.indices {
            if let original = originals[index], let restored = rawResult.page(at: index + 1) {
                if imageOverlayPages[index] == nil {
                    guard try contentFingerprint(original) == contentFingerprint(restored) else {
                        throw PaperPathError.outputVerificationFailed("the saved PDF changed original page commands or Unicode font maps")
                    }
                } else if try contentFingerprint(original) != contentFingerprint(restored, droppingAddedDrawing: true) {
                    throw PaperPathError.outputVerificationFailed("the added image changed original page commands or Unicode font maps")
                }
            }
        }
        // PDFKit's extracted spacing/reading order can change after rotation,
        // cropping, or adding widgets. The page-command and CMap fingerprints
        // above verify original bytes directly rather than that layout heuristic.
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: repaired, to: destination)
        withExtendedLifetime(sourceDocuments) {}
        _ = originals // Retain every backing CGPDFDocument until graph copying completes.
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").precomposedStringWithCompatibilityMapping
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\u{fffc}"))).joined()
    }

    private static func contentFingerprint(_ page: CGPDFPage, droppingAddedDrawing: Bool = false) throws -> SHA256.Digest {
        guard let dictionary = page.dictionary else { throw PaperPathError.invalidPage }
        var digest = SHA256()
        func appendStream(_ stream: CGPDFStreamRef) throws {
            var format = CGPDFDataFormat.raw
            guard let bytes = CGPDFStreamCopyData(stream, &format), CFDataGetLength(bytes) <= 64 * 1_024 * 1_024 else { throw PaperPathError.fileTooLarge }
            digest.update(data: bytes as Data)
        }
        var contents: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "Contents", &contents), let contents {
            if CGPDFObjectGetType(contents) == .stream {
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(contents, .stream, &stream), let stream { try appendStream(stream) }
            } else {
                var array: CGPDFArrayRef?
                if CGPDFObjectGetValue(contents, .array, &array), let array {
                    for index in 0..<max(0, CGPDFArrayGetCount(array) - (droppingAddedDrawing ? 1 : 0)) {
                        var stream: CGPDFStreamRef?
                        if CGPDFArrayGetStream(array, index, &stream), let stream { try appendStream(stream) }
                    }
                }
            }
        }
        var resources: CGPDFDictionaryRef?, ancestor: CGPDFDictionaryRef? = dictionary
        for _ in 0..<32 {
            guard let current = ancestor else { break }
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources) { break }
            var parent: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(current, "Parent", &parent); ancestor = parent
        }
        var fonts: CGPDFDictionaryRef?
        if let resources, CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
            var maps: [(String, CGPDFStreamRef)] = []
            CGPDFDictionaryApplyBlock(fonts, { key, _, _ in
                var font: CGPDFDictionaryRef?, map: CGPDFStreamRef?
                if CGPDFDictionaryGetDictionary(fonts, key, &font), let font,
                   CGPDFDictionaryGetStream(font, "ToUnicode", &map), let map { maps.append((String(cString: key), map)) }
                return true
            }, nil)
            for (key, map) in maps.sorted(by: { $0.0 < $1.0 }) {
                digest.update(data: Data(key.utf8)); try appendStream(map)
            }
        }
        return digest.finalize()
    }

    private static func encodedLargeImages(_ urls: [URL], password: String?) throws -> [String: Data] {
        var candidates: [String: [Data]] = [:]
        for url in urls {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let references: [PDFImageObjectReference]
            let encryption: PDFAESV2EncryptionContext?
            if let parsed = try? PDFImageObjectDocument(data: data, allowZeroOffsetPlaceholders: true) {
                references = parsed.allObjects(); encryption = nil
            } else if let password, let parsed = try? PDFCatalogStructureAppender(data: data) {
                references = parsed.originalStreamReferences()
                encryption = try parsed.originalObjectEncryption(password: password).context
            } else { continue }
            for (index, reference) in references.enumerated() {
                try Task.checkCancellation()
                let end = index + 1 < references.count ? references[index + 1].offset : data.count
                guard reference.offset < end, end - reference.offset <= 32 * 1_024 * 1_024 else { continue }
                let prefix = Data(data[reference.offset..<min(end, reference.offset + 64 * 1_024)])
                guard let dictionaryRange = pdfFirstDictionaryRange(in: prefix),
                      let values = pdfCompressionValues(Data(prefix[dictionaryRange])), values["Subtype"] == "/Image",
                      let width = Int(values["Width"] ?? ""), let height = Int(values["Height"] ?? ""),
                      width > 0, height > 0, width <= 100_000, height <= 100_000,
                      let bits = Int(values["BitsPerComponent"] ?? ""), (1...16).contains(bits),
                      width * height * 4 * bits / 8 > 64 * 1_024 * 1_024,
                      let length = Int(values["Length"] ?? ""), length > 0,
                      let marker = prefix.range(of: Data("stream".utf8), in: dictionaryRange.upperBound..<prefix.count) else { continue }
                var start = marker.upperBound
                if start < prefix.count, prefix[start] == 13 { start += 1 }
                if start < prefix.count, prefix[start] == 10 { start += 1 }
                start += reference.offset
                guard length <= end - start else { continue }
                let key = "\(width):\(height):\(bits):\(length)"
                let encoded = Data(data[start..<(start + length)])
                let bytes = try encryption?.decrypt(encoded, objectNumber: reference.number, generation: reference.generation) ?? encoded
                candidates[key, default: []].append(bytes)
            }
        }
        // Ambiguous matches stay unsupported; never guess between image payloads.
        return candidates.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }
}

/// Serializes resolved Core Graphics PDF objects without asking PDFKit to
/// regenerate page text or fonts. Objects are queued and streamed one at a time;
/// cycles (page Parent/P, form trees, outlines) use stable indirect references.
struct PDFOriginalObjectEncryption {
    let context: PDFAESV2EncryptionContext
    let dictionary: Data
    let identifier: Data
    let encryptMetadata: Bool
}

private final class PDFOriginalObjectWriter {
    private enum Node {
        case dictionary(CGPDFDictionaryRef), array(CGPDFArrayRef), stream(CGPDFStreamRef)
        case raw(String)
        case rawStream(String, Data)
    }
    private struct Key: Hashable { let kind: Int; let pointer: UInt }
    private var nodes: [Node] = []
    private var identifiers: [Key: Int] = [:]
    private let overrides: [UInt: [String: CGPDFObjectRef]]
    private let encodedImages: [String: Data]
    private let encryption: PDFOriginalObjectEncryption?
    private let needsAppearances: Bool
    private var objectNumber = 0
    private var additionsByDictionary: [UInt: [String: String]] = [:]
    init(overrides: [UInt: [String: CGPDFObjectRef]], encodedImages: [String: Data], encryption: PDFOriginalObjectEncryption?, needsAppearances: Bool) {
        self.overrides = overrides; self.encodedImages = encodedImages; self.encryption = encryption; self.needsAppearances = needsAppearances
    }

    private func reference(_ node: Node) throws -> String {
        let key: Key
        switch node {
        case .dictionary(let value): key = Key(kind: 1, pointer: UInt(bitPattern: value.rawValue))
        case .array(let value): key = Key(kind: 2, pointer: UInt(bitPattern: value.rawValue))
        case .stream(let value): key = Key(kind: 3, pointer: UInt(bitPattern: value.rawValue))
        case .raw, .rawStream:
            let number = nodes.count + 1; nodes.append(node); return "\(number) 0 R"
        }
        if let number = identifiers[key] { return "\(number) 0 R" }
        guard nodes.count < 500_000 else { throw PaperPathError.fileTooLarge }
        let number = nodes.count + 1
        identifiers[key] = number; nodes.append(node)
        return "\(number) 0 R"
    }
    private func name(_ pointer: UnsafePointer<CChar>) -> String {
        let count = strlen(pointer)
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return "/" + (0..<count).map { i in
            let b = bytes[i]
            return b > 32 && b < 127 && ![35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(b)
                ? String(UnicodeScalar(b)) : String(format: "#%02X", b)
        }.joined()
    }
    private func value(_ object: CGPDFObjectRef) throws -> String {
        switch CGPDFObjectGetType(object) {
        case .null: return "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            guard CGPDFObjectGetValue(object, .boolean, &value) else { throw PaperPathError.unreadablePDF }
            return value == 0 ? "false" : "true"
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, .integer, &value) else { throw PaperPathError.unreadablePDF }
            return String(value)
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw PaperPathError.unreadablePDF }
            return String(format: "%.10f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { throw PaperPathError.unreadablePDF }
            return name(value)
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value,
                  CGPDFStringGetLength(value) <= 16 * 1_024 * 1_024,
                  let bytes = CGPDFStringGetBytePtr(value) else { throw PaperPathError.unreadablePDF }
            let raw = Data(bytes: bytes, count: CGPDFStringGetLength(value))
            let encoded = try encryption?.context.encrypt(raw, objectNumber: objectNumber, generation: 0) ?? raw
            return "<" + encoded.map { String(format: "%02X", $0) }.joined() + ">"
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { throw PaperPathError.unreadablePDF }
            return try reference(.array(value))
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw PaperPathError.unreadablePDF }
            return try reference(.dictionary(value))
        case .stream:
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { throw PaperPathError.unreadablePDF }
            return try reference(.stream(value))
        @unknown default: throw PaperPathError.unreadablePDF
        }
    }
    private func dictionary(_ dictionary: CGPDFDictionaryRef, skipping: Set<String> = [], additions: [String: String] = [:]) throws -> String {
        let additions = (additionsByDictionary[UInt(bitPattern: dictionary.rawValue)] ?? [:]).merging(additions) { _, explicit in explicit }
        var entries: [(String, String, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
            entries.append((String(cString: key), self.name(key), object))
            return entries.count <= 100_000
        }, nil)
        guard entries.count <= 100_000 else { throw PaperPathError.fileTooLarge }
        var result = "<<"
        for (key, encodedName, original) in entries.sorted(by: { $0.1 < $1.1 }) where !skipping.contains(key) && additions[key] == nil {
            let object = overrides[UInt(bitPattern: dictionary.rawValue)]?[key] ?? original
            result += " \(encodedName) \(try value(object))"
        }
        let existingKeys = Set(entries.map { $0.0 })
        for (key, object) in overrides[UInt(bitPattern: dictionary.rawValue)] ?? [:]
        where !existingKeys.contains(key) && !skipping.contains(key) && additions[key] == nil {
            result += " /\(key) \(try value(object))"
        }
        for key in additions.keys.sorted() { result += " /\(key) \(additions[key]!)" }
        return result + " >>"
    }

    func installImageOverlays(_ pages: [Int: CGPDFPage], in document: CGPDFDocument) throws {
        guard encryption == nil || pages.isEmpty else { throw PaperPathError.lockedPDF }
        for (index, overlay) in pages {
            guard let target = document.page(at: index + 1)?.dictionary, let overlayDictionary = overlay.dictionary else { throw PaperPathError.invalidPage }
            let targetKey = UInt(bitPattern: target.rawValue)
            guard let sourceValues = overrides[targetKey] else { throw PaperPathError.invalidPage }
            var resources: CGPDFDictionaryRef?
            if let object = sourceValues["Resources"] { _ = CGPDFObjectGetValue(object, .dictionary, &resources) }
            var originalXObjects: CGPDFDictionaryRef?
            if let resources { _ = CGPDFDictionaryGetDictionary(resources, "XObject", &originalXObjects) }
            var resourceName = "PaperPathAddedImage"
            if let originalXObjects {
                var value: CGPDFObjectRef?
                while CGPDFDictionaryGetObject(originalXObjects, resourceName, &value) { resourceName += "X" }
            }
            let bounds = overlay.getBoxRect(.mediaBox)
            var overlayResources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(overlayDictionary, "Resources", &overlayResources)
            let resourceReference = try overlayResources.map { try reference(.dictionary($0)) } ?? "<< >>"
            var content: CGPDFObjectRef?, imageCommands = Data()
            _ = CGPDFDictionaryGetObject(overlayDictionary, "Contents", &content)
            func append(_ stream: CGPDFStreamRef) throws {
                var format = CGPDFDataFormat.raw
                guard let bytes = CGPDFStreamCopyData(stream, &format), CFDataGetLength(bytes) <= 32 * 1_024 * 1_024 else { throw PaperPathError.fileTooLarge }
                imageCommands.append(bytes as Data); imageCommands.append(10)
            }
            if let content, CGPDFObjectGetType(content) == .stream {
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(content, .stream, &stream), let stream { try append(stream) }
            } else if let content {
                var array: CGPDFArrayRef?
                if CGPDFObjectGetValue(content, .array, &array), let array {
                    for i in 0..<CGPDFArrayGetCount(array) {
                        var stream: CGPDFStreamRef?
                        if CGPDFArrayGetStream(array, i, &stream), let stream { try append(stream) }
                    }
                }
            }
            let form = try reference(.rawStream("/Type /XObject /Subtype /Form /FormType 1 /BBox [\(bounds.minX) \(bounds.minY) \(bounds.maxX) \(bounds.maxY)] /Resources \(resourceReference)", imageCommands))
            let xObjects = try originalXObjects.map { try dictionary($0, additions: [resourceName: form]) } ?? "<< /\(resourceName) \(form) >>"
            let xObjectReference = try reference(.raw(xObjects))
            let updatedResources = try resources.map { try dictionary($0, additions: ["XObject": xObjectReference]) } ?? "<< /XObject \(xObjectReference) >>"
            let updatedResourceReference = try reference(.raw(updatedResources))
            var originalContents: [String] = []
            if let contents = sourceValues["Contents"] {
                if CGPDFObjectGetType(contents) == .array {
                    var array: CGPDFArrayRef?
                    if CGPDFObjectGetValue(contents, .array, &array), let array {
                        for i in 0..<CGPDFArrayGetCount(array) {
                            var object: CGPDFObjectRef?
                            if CGPDFArrayGetObject(array, i, &object), let object { originalContents.append(try value(object)) }
                        }
                    }
                } else { originalContents.append(try value(contents)) }
            }
            let draw = try reference(.rawStream("", Data("q /\(resourceName) Do Q\n".utf8)))
            additionsByDictionary[targetKey, default: [:]]["Resources"] = updatedResourceReference
            additionsByDictionary[targetKey, default: [:]]["Contents"] = "[ " + (originalContents + [draw]).joined(separator: " ") + " ]"
        }
    }
    func write(document: CGPDFDocument, to url: URL) throws {
        guard let catalog = document.catalog else { throw PaperPathError.unreadablePDF }
        // PDFKit can emit page widgets without adding them to AcroForm/Fields.
        // Reconcile existing roots and orphan widgets before writing the graph.
        var acroForm: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm)
        var fieldReferences: [String] = [], seenFields = Set<UInt>()
        func addField(_ dictionary: CGPDFDictionaryRef) throws {
            let pointer = UInt(bitPattern: dictionary.rawValue)
            if seenFields.insert(pointer).inserted { fieldReferences.append(try reference(.dictionary(dictionary))) }
        }
        if let acroForm {
            var fields: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields {
                for i in 0..<CGPDFArrayGetCount(fields) {
                    var field: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(fields, i, &field), let field { try addField(field) }
                }
            }
        }
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index)?.dictionary else { throw PaperPathError.invalidPage }
            var annotations: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations {
                for i in 0..<CGPDFArrayGetCount(annotations) {
                    var field: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
                    guard CGPDFArrayGetDictionary(annotations, i, &field), var field else { continue }
                    _ = CGPDFDictionaryGetName(field, "Subtype", &subtype)
                    guard subtype.map({ String(cString: $0) == "Widget" }) == true else { continue }
                    var parents = Set<UInt>()
                    for _ in 0..<32 {
                        guard parents.insert(UInt(bitPattern: field.rawValue)).inserted else { throw PaperPathError.unreadablePDF }
                        var parent: CGPDFDictionaryRef?
                        if CGPDFDictionaryGetDictionary(field, "Parent", &parent), let parent { field = parent }
                        else { break }
                    }
                    try addField(field)
                }
            }
        }
        if !fieldReferences.isEmpty {
            let fields = "[ " + fieldReferences.joined(separator: " ") + " ]"
            if let acroForm { additionsByDictionary[UInt(bitPattern: acroForm.rawValue)] = ["Fields": fields, "NeedAppearances": needsAppearances ? "true" : "false"] }
            else {
                let font = try reference(.raw("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))
                let form = try reference(.raw("<< /Fields \(fields) /NeedAppearances false /DR << /Font << /Helv \(font) /Helvetica \(font) >> >> >>"))
                additionsByDictionary[UInt(bitPattern: catalog.rawValue)] = ["AcroForm": form]
            }
        }
        let root = try reference(.dictionary(catalog))
        let info = try document.info.map { try reference(.dictionary($0)) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw PaperPathError.insufficientStorage }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("%PDF-1.7\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n".utf8))
        var offsets: [UInt64] = [0], index = 0
        while index < nodes.count {
            try Task.checkCancellation()
            try autoreleasepool {
                objectNumber = index + 1
                offsets.append(try handle.offset())
                try handle.write(contentsOf: Data("\(index + 1) 0 obj\n".utf8))
                switch nodes[index] {
                case .raw(let text): try handle.write(contentsOf: Data(text.utf8))
                case .rawStream(let attributes, let raw):
                    guard let bytes = pdfCompressionDeflate(raw) else { throw PaperPathError.unreadablePDF }
                    try handle.write(contentsOf: Data("<< \(attributes) /Length \(bytes.count) /Filter /FlateDecode >>\nstream\n".utf8))
                    try handle.write(contentsOf: bytes)
                    try handle.write(contentsOf: Data("\nendstream".utf8))
                case .dictionary(let dictionary):
                    try handle.write(contentsOf: Data(try self.dictionary(dictionary).utf8))
                case .array(let array):
                    guard CGPDFArrayGetCount(array) <= 500_000 else { throw PaperPathError.fileTooLarge }
                    var text = "["
                    for i in 0..<CGPDFArrayGetCount(array) {
                        var object: CGPDFObjectRef?
                        guard CGPDFArrayGetObject(array, i, &object), let object else { throw PaperPathError.unreadablePDF }
                        text += " \(try value(object))"
                    }
                    try handle.write(contentsOf: Data((text + " ]").utf8))
                case .stream(let stream):
                    guard let dictionary = CGPDFStreamGetDictionary(stream) else { throw PaperPathError.unreadablePDF }
                    var width = 0, height = 0, bits = 0, length = 0
                    _ = CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                    _ = CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                    _ = CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
                    _ = CGPDFDictionaryGetInteger(dictionary, "Length", &length)
                    if width > 0, height > 0, width <= 100_000, height <= 100_000, (1...16).contains(bits),
                       width * height * 4 * bits / 8 > 64 * 1_024 * 1_024 {
                        guard let raw = encodedImages["\(width):\(height):\(bits):\(length)"] else { throw PaperPathError.fileTooLarge }
                        let bytes = try encryption?.context.encrypt(raw, objectNumber: objectNumber, generation: 0) ?? raw
                        let text = try self.dictionary(dictionary, skipping: ["Length"], additions: ["Length": "\(bytes.count)"])
                        try handle.write(contentsOf: Data((text + "\nstream\n").utf8))
                        try handle.write(contentsOf: bytes)
                        try handle.write(contentsOf: Data("\nendstream".utf8))
                        break
                    }
                    var format = CGPDFDataFormat.raw
                    guard let content = CGPDFStreamCopyData(stream, &format) else { throw PaperPathError.unreadablePDF }
                    let decoded = content as Data
                    guard decoded.count <= 64 * 1_024 * 1_024 else { throw PaperPathError.fileTooLarge }
                    var params: CGPDFDictionaryRef?
                    let embedded = CGPDFDictionaryGetDictionary(dictionary, "Params", &params)
                    let bytes: Data, filter: String?
                    if embedded || decoded.isEmpty || decoded.count > 32 * 1_024 * 1_024 { bytes = decoded; filter = nil }
                    else { switch format {
                    case .jpegEncoded: bytes = decoded; filter = "/DCTDecode"
                    case .JPEG2000: bytes = decoded; filter = "/JPXDecode"
                    default:
                        guard let encoded = pdfCompressionDeflate(decoded) else { throw PaperPathError.unreadablePDF }
                        bytes = encoded; filter = "/FlateDecode"
                    } }
                    var streamType: UnsafePointer<CChar>?
                    _ = CGPDFDictionaryGetName(dictionary, "Type", &streamType)
                    let isMetadata = streamType.map { String(cString: $0) == "Metadata" } ?? false
                    let encoded = try (encryption != nil && (!isMetadata || encryption!.encryptMetadata))
                        ? encryption!.context.encrypt(bytes, objectNumber: objectNumber, generation: 0) : bytes
                    var settings = ["Length": "\(encoded.count)"]
                    if let filter { settings["Filter"] = filter }
                    let text = try self.dictionary(dictionary, skipping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms"], additions: settings)
                    try handle.write(contentsOf: Data((text + "\nstream\n").utf8))
                    try handle.write(contentsOf: encoded)
                    try handle.write(contentsOf: Data("\nendstream".utf8))
                }
                try handle.write(contentsOf: Data("\nendobj\n".utf8))
            }
            guard try handle.offset() <= 512 * 1_024 * 1_024 else { throw PaperPathError.fileTooLarge }
            index += 1
        }
        var encryptionTrailer = ""
        if let encryption {
            let number = offsets.count
            offsets.append(try handle.offset())
            try handle.write(contentsOf: Data("\(number) 0 obj\n".utf8))
            try handle.write(contentsOf: encryption.dictionary)
            try handle.write(contentsOf: Data("\nendobj\n".utf8))
            let identifier = encryption.identifier.map { String(format: "%02X", $0) }.joined()
            encryptionTrailer = " /Encrypt \(number) 0 R /ID [<\(identifier)> <\(identifier)>]"
        }
        let start = try handle.offset()
        try handle.write(contentsOf: Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { try handle.write(contentsOf: Data(String(format: "%010llu 00000 n \n", offset).utf8)) }
        try handle.write(contentsOf: Data("trailer\n<< /Size \(offsets.count) /Root \(root)\(info.map { " /Info \($0)" } ?? "")\(encryptionTrailer) >>\nstartxref\n\(start)\n%%EOF\n".utf8))
        try handle.synchronize()
    }
}

/// Quartz page dictionaries require CFData containing CGRect bytes, not a boxed
/// CGRect. A boxed value is ignored, silently reusing the first page's size.
func pdfPageBoxData(_ rectangle: CGRect) -> CFData {
    var rectangle = rectangle
    return withUnsafeBytes(of: &rectangle) { Data($0) as CFData }
}
