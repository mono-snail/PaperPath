import CoreGraphics
import CoreText
import Foundation
import PDFKit

struct PDFCompositionService: Sendable {
    func combine(urls: [URL], to destination: URL) throws {
        guard urls.count >= 2 else {
            throw PaperPathError.insufficientSelection(
                "Choose at least two PDFs to combine."
            )
        }

        let output = PDFDocument()
        var outputIndex = 0
        for url in urls {
            try Task.checkCancellation()
            guard let source = PDFDocument(url: url), !source.isLocked else {
                throw PaperPathError.unreadablePDF
            }
            for pageIndex in 0..<source.pageCount {
                try Task.checkCancellation()
                guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                    continue
                }
                output.insert(page, at: outputIndex)
                outputIndex += 1
            }
        }
        try write(output, to: destination)
    }

    func extractPages(
        from sourceURL: URL,
        indices: [Int],
        to destination: URL
    ) throws {
        let uniqueIndices = Array(Set(indices)).sorted()
        guard !uniqueIndices.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one page to extract."
            )
        }
        guard let source = PDFDocument(url: sourceURL), !source.isLocked else {
            throw PaperPathError.unreadablePDF
        }

        let output = PDFDocument()
        for (outputIndex, pageIndex) in uniqueIndices.enumerated() {
            try Task.checkCancellation()
            guard let page = source.page(at: pageIndex)?.copy() as? PDFPage else {
                throw PaperPathError.invalidPage
            }
            output.insert(page, at: outputIndex)
        }
        try write(output, to: destination)
    }

    private func write(_ document: PDFDocument, to destination: URL) throws {
        guard document.pageCount > 0 else {
            throw PaperPathError.storageFailure("The new PDF contained no pages.")
        }
        guard document.write(to: destination) else {
            throw PaperPathError.storageFailure("The new PDF could not be written.")
        }
        LocalFileSecurity.applyCompleteProtection(to: destination)
    }
}

struct SearchablePDFService: Sendable {
    func createSearchableCopy(
        sourceURL: URL,
        ocrResult: OCRResult,
        destination: URL
    ) throws {
        guard !ocrResult.pages.isEmpty,
              ocrResult.pages.contains(where: { !$0.blocks.isEmpty })
        else {
            throw PaperPathError.missingRecognizedText
        }
        guard let provider = CGDataProvider(url: sourceURL as CFURL),
              let source = CGPDFDocument(provider),
              let firstPage = source.page(at: 1),
              let consumer = CGDataConsumer(url: destination as CFURL)
        else {
            throw PaperPathError.unreadablePDF
        }

        var defaultBox = firstPage.getBoxRect(.mediaBox)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &defaultBox,
            nil
        ) else {
            throw PaperPathError.storageFailure(
                "The searchable PDF context could not be created."
            )
        }
        defer { context.closePDF() }

        let resultsByPage = ocrResult.pages.reduce(
            into: [Int: OCRPageResult]()
        ) { result, page in
            result[page.pageIndex] = page
        }

        for pageNumber in 1...source.numberOfPages {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: pageNumber) else { continue }
            let mediaBox = sourcePage.getBoxRect(.mediaBox)
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
        }
        try Task.checkCancellation()
        LocalFileSecurity.applyCompleteProtection(to: destination)
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
}
