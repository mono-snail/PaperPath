import CryptoKit
import Darwin
import PDFKit
import QuickLookThumbnailing
import UIKit
import XCTest
import zlib

/// Downloaded originals, never rewritten before exercising the service.
/// FetchRealPDFCorpus.py pins bytes; missing files fail rather than skip.
final class RealPDFReleaseTests: XCTestCase {
    private struct Manifest: Decodable { let documents: [Sample] }
    private struct Sample: Decodable { let file: String; let sha256: String }
    private var directory: URL!
    private var rows: [[String: String]] = []
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RealPDF-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "real-pdf-\(name.components(separatedBy: " ").last ?? "results").json"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.removeItem(at: directory)
    }
    private func samples() throws -> [URL] {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RealPDFCorpus", withExtension: nil))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertGreaterThanOrEqual(manifest.documents.count, 8)
        return try manifest.documents.map { sample in
            let url = root.appendingPathComponent(sample.file)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), sample.sha256)
            return url
        }
    }
    private func output(_ source: URL, _ action: String) -> URL {
        directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(action).pdf")
    }
    private func attach(_ url: URL) throws {
        let item = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: "com.adobe.pdf")
        item.name = url.lastPathComponent
        item.lifetime = .keepAlways
        add(item)
    }
    private func verify(_ url: URL, against source: URL, indices: [Int]? = nil, text: Bool = true) throws {
        let before = try XCTUnwrap(PDFDocument(url: source))
        let after = try XCTUnwrap(PDFDocument(url: url))
        let expected = indices ?? Array(0..<before.pageCount)
        XCTAssertEqual(after.pageCount, expected.count)
        for (destinationIndex, sourceIndex) in expected.enumerated() {
            let lhs = try XCTUnwrap(before.page(at: sourceIndex)), rhs = try XCTUnwrap(after.page(at: destinationIndex))
            if text { XCTAssertEqual(lhs.bounds(for: .mediaBox), rhs.bounds(for: .mediaBox)) }
            else {
                let size = lhs.bounds(for: .cropBox).size
                let rotated = ((lhs.rotation % 360) + 360) % 360
                let expectedSize = rotated == 90 || rotated == 270 ? CGSize(width: size.height, height: size.width) : size
                XCTAssertEqual(expectedSize.width, rhs.bounds(for: .mediaBox).width, accuracy: 0.01)
                XCTAssertEqual(expectedSize.height, rhs.bounds(for: .mediaBox).height, accuracy: 0.01)
            }
            if text { XCTAssertTrue(normalizedText(lhs.string) == normalizedText(rhs.string), "Searchable text changed on page \(sourceIndex + 1)") }
            XCTAssertNotNil(rhs.thumbnail(of: CGSize(width: 160, height: 200), for: .mediaBox).cgImage)
        }
    }
    private func normalizedText(_ value: String?) -> String {
        (value ?? "").precomposedStringWithCompatibilityMapping
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\u{fffc}"))).joined()
    }
    private func run(_ source: URL, _ feature: String, _ operation: () throws -> URL) {
        autoreleasepool {
            let before = (try? Data(contentsOf: source)) ?? Data()
            let failuresBefore = testRun?.failureCount ?? 0
            do {
                let result = try operation()
                let size = (try? Data(contentsOf: result).count) ?? 0
                let status = (testRun?.failureCount ?? 0) == failuresBefore ? "passed" : "failed"
                rows.append(["file": source.lastPathComponent, "feature": feature, "status": status, "input": "\(before.count)", "output": "\(size)"])
                print("REAL_PDF \(source.lastPathComponent) \(feature) \(before.count) -> \(size)")
            } catch let error as PaperPathError {
                if case .compressionNotBeneficial = error {
                    rows.append(["file": source.lastPathComponent, "feature": feature, "status": "unchanged", "input": "\(before.count)", "reason": error.localizedDescription])
                    print("REAL_PDF \(source.lastPathComponent) \(feature) UNCHANGED \(error.localizedDescription)")
                } else if source.lastPathComponent == "irs-w4.pdf",
                          ["preserveContent", "optimizedImages"].contains(feature),
                          case .insufficientSelection(let reason) = error,
                          reason.contains("digital signature"),
                          reason.contains("Recompression would invalidate it") {
                    XCTAssertNotNil(before.range(of: Data("/ByteRange".utf8)), "Blocked corpus must actually contain a signature byte range")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output(source, feature).path), "Rejected signature recompression must not publish an output")
                    rows.append(["file": source.lastPathComponent, "feature": feature, "status": "blocked-signature", "reason": reason])
                    print("REAL_PDF \(source.lastPathComponent) \(feature) BLOCKED_SIGNATURE")
                } else {
                    rows.append(["file": source.lastPathComponent, "feature": feature, "status": "failed", "reason": error.localizedDescription])
                    XCTFail("REAL_PDF \(source.lastPathComponent) \(feature): \(error)")
                }
            } catch {
                rows.append(["file": source.lastPathComponent, "feature": feature, "status": "failed", "reason": "\(error)"])
                XCTFail("REAL_PDF \(source.lastPathComponent) \(feature): \(error)")
            }
            XCTAssertEqual(try? Data(contentsOf: source), before, "Downloaded source must never change")
        }
    }
    func testRealCompressionCorpus() throws {
        for source in try samples() {
            for mode in PDFCompressionMode.allCases {
                run(source, mode.rawValue) {
                    let destination = output(source, mode.rawValue)
                    try PDFOutputService().compress(sourceURL: source, destination: destination, quality: .readable, mode: mode)
                    try verify(destination, against: source, text: mode != .imageCopy)
                    let original = try XCTUnwrap(PDFDocument(url: source)), compressed = try XCTUnwrap(PDFDocument(url: destination))
                    for index in 0..<original.pageCount {
                        let before = try thumbnailPixels(try XCTUnwrap(original.page(at: index)))
                        let after = try thumbnailPixels(try XCTUnwrap(compressed.page(at: index)))
                        let error = zip(before, after).enumerated().filter { $0.offset % 4 != 3 }
                            .reduce(0.0) { $0 + Double(abs(Int($1.element.0) - Int($1.element.1))) } / Double(160 * 200 * 3)
                        XCTAssertLessThan(error, mode == .preserveContent ? 1 : 28, "\(source.lastPathComponent) page \(index): compression changed page colors/appearance")
                    }
                    XCTAssertLessThan(try Data(contentsOf: destination).count, try Data(contentsOf: source).count)
                    try attach(destination)
                    return destination
                }
            }
        }
    }
    private func thumbnailPixels(_ page: PDFPage) throws -> [UInt8] {
        let image = try XCTUnwrap(page.thumbnail(of: CGSize(width: 160, height: 200), for: .mediaBox).cgImage)
        var bytes = [UInt8](repeating: 255, count: 160 * 200 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 160, height: 200, bitsPerComponent: 8,
                bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 200))
        }
        return bytes
    }
    func testRealCompositionAndPageEditingCorpus() throws {
        let sources = try samples()
        for source in sources {
            let original = try XCTUnwrap(PDFDocument(url: source))
            run(source, "extract-and-split") {
                for index in 0..<original.pageCount {
                    try autoreleasepool {
                        let destination = output(source, "page-\(index)")
                        try PDFCompositionService().extractPages(from: source, indices: [index], to: destination)
                        try verify(destination, against: source, indices: [index])
                        try attach(destination)
                    }
                }
                return output(source, "page-0")
            }
            run(source, "merge") {
                let second = sources.first { $0 != source }!
                let destination = output(source, "merge")
                try PDFCompositionService().combine(urls: [source, second], to: destination)
                let merged = try XCTUnwrap(PDFDocument(url: destination))
                let other = try XCTUnwrap(PDFDocument(url: second))
                XCTAssertEqual(merged.pageCount, original.pageCount + other.pageCount)
                for i in 0..<merged.pageCount {
                    let expected = i < original.pageCount ? original.page(at: i) : other.page(at: i - original.pageCount)
                    XCTAssertEqual(normalizedText(merged.page(at: i)?.string), normalizedText(expected?.string))
                }
                try attach(destination)
                return destination
            }
            run(source, "page-operations") {
                let destination = output(source, "pages")
                try FileManager.default.copyItem(at: source, to: destination)
                let mutation = PDFMutationService()
                try mutation.rotatePage(at: 0, in: destination)
                XCTAssertEqual(PDFDocument(url: destination)?.page(at: 0)?.rotation, ((original.page(at: 0)?.rotation ?? 0) + 90) % 360)
                try mutation.duplicatePage(at: 0, in: destination)
                XCTAssertEqual(PDFDocument(url: destination)?.pageCount, original.pageCount + 1)
                try mutation.deletePage(at: 1, in: destination)
                XCTAssertEqual(PDFDocument(url: destination)?.pageCount, original.pageCount)
                try mutation.cropPage(at: 0, insetFraction: 0.05, in: destination)
                XCTAssertLessThan(try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0)?.bounds(for: .cropBox).width),
                                  try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0)?.bounds(for: .mediaBox).width))
                if original.pageCount > 1 {
                    try mutation.reorderPages(order: Array((0..<original.pageCount).reversed()), in: destination)
                    XCTAssertEqual(normalizedText(PDFDocument(url: destination)?.page(at: 0)?.string), normalizedText(original.page(at: original.pageCount - 1)?.string))
                }
                try attach(destination)
                return destination
            }
        }
    }

    func testRealProtectionFlatteningAndRedactionCorpus() throws {
        for source in try samples() {
            run(source, "protect-unlock") {
                let protected = output(source, "protected"), unlocked = output(source, "unlocked")
                let service = PDFOutputService()
                try service.protect(sourceURL: source, destination: protected, password: "ReleaseTest-2026", permissions: .init(allowsPrinting: true, allowsCopying: true, allowsCommenting: true, allowsFormFilling: true, allowsPageChanges: true))
                let locked = try XCTUnwrap(PDFDocument(url: protected))
                XCTAssertTrue(locked.isLocked)
                XCTAssertFalse(locked.unlock(withPassword: "incorrect-password"))
                XCTAssertTrue(locked.unlock(withPassword: "ReleaseTest-2026"))
                try attach(protected)
                try service.removePassword(sourceURL: protected, destination: unlocked, password: "ReleaseTest-2026")
                XCTAssertFalse(try XCTUnwrap(PDFDocument(url: unlocked)).isEncrypted)
                try verify(unlocked, against: source)
                try attach(unlocked)
                return unlocked
            }
            for action in ["flatten", "safe-share", "redact"] {
                run(source, action) {
                    let destination = output(source, action), service = PDFOutputService()
                    switch action {
                    case "flatten": try service.flatten(sourceURL: source, destination: destination)
                    case "safe-share": try service.safeShare(sourceURL: source, destination: destination)
                    default:
                        try service.secureRedact(sourceURL: source, destination: destination,
                            marks: [.init(pageIndex: 0, normalizedX: 0, normalizedY: 0, normalizedWidth: 1, normalizedHeight: 1)])
                    }
                    try verify(destination, against: source, text: false)
                    let document = try XCTUnwrap(PDFDocument(url: destination))
                    XCTAssertTrue(document.page(at: 0)?.string?.isEmpty != false, "Raster export must not leave hidden source text")
                    XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
                    try attach(destination)
                    return destination
                }
            }
        }
    }

    func testRealAnnotationsFormsBookmarksAndContentCorpus() throws {
        for source in try samples() {
            run(source, "stamp-number-watermark-bates-signature") {
                let destination = output(source, "annotations")
                try FileManager.default.copyItem(at: source, to: destination)
                let mutation = PDFMutationService()
                let originalCount = try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0)?.annotations.count)
                try mutation.addStamp(.approved, toPageAt: 0, in: destination)
                try mutation.applyPageNumbers(.init(pageIndices: [0], startNumber: 1, format: .pageOfTotal, position: .bottomCenter), in: destination)
                XCTAssertEqual(try mutation.removeGeneratedPageNumbers(in: destination), 1)
                try mutation.applyBatesNumbers(.init(pageIndices: [0], startNumber: 1, digitCount: 6, prefix: "QA-", suffix: "", position: .bottomRight), in: destination)
                XCTAssertEqual(try mutation.removeGeneratedBatesNumbers(in: destination), 1)
                try mutation.applyWatermark(.init(pageIndices: [0], text: "REAL PDF RELEASE TEST", layout: .diagonal, tone: .red, intensity: .standard), in: destination)
                XCTAssertEqual(try mutation.removeGeneratedWatermarks(in: destination), 1)
                try mutation.addInk(.init(pageIndex: 0,
                    strokes: [.init(points: [.init(x: 0.1, y: 0.4), .init(x: 0.5, y: 0.6), .init(x: 0.9, y: 0.2)])], placement: .signature), in: destination)
                XCTAssertTrue(try mutation.containsSignature(in: destination))
                XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0)?.annotations.count), originalCount)
                try attach(destination)
                return destination
            }
            run(source, "form-add-fill") {
                let destination = output(source, "new-form"), filled = output(source, "filled")
                try FileManager.default.copyItem(at: source, to: destination)
                try PDFMutationService().addFormField(.init(pageIndex: 0, kind: .text,
                    name: "RealPDFReleaseField", normalizedBounds: .init(x: 0.1, y: 0.2, width: 0.4, height: 0.6),
                    isRequired: false, isMultiline: false, maximumLength: 64), in: destination)
                try PDFOutputService().applyFormFieldValues(sourceURL: destination, destination: filled, values: ["RealPDFReleaseField": "Verified 2026"])
                XCTAssertTrue(try PDFFormInspectionService().fields(in: filled).contains { $0.name == "RealPDFReleaseField" && $0.value == "Verified 2026" })
                try attach(filled)
                return filled
            }
            run(source, "bookmarks") {
                let destination = output(source, "bookmarks")
                try PDFOutputService().embedBookmarks(sourceURL: source, destination: destination, pageIndices: [0])
                XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: destination)?.outlineRoot?.numberOfChildren), 0)
                try verify(destination, against: source)
                try attach(destination)
                return destination
            }
            run(source, "add-text-image-link") {
                let destination = output(source, "content")
                try PDFOutputService().addContent(sourceURL: source, destination: destination, overlays: [
                    .text(pageIndex: 0, bounds: .init(x: 0.05, y: 0.9, width: 0.8, height: 0.08), text: "Real PDF QA", fontSize: 12, color: .init(red: 0, green: 0, blue: 0, alpha: 1)),
                    .image(pageIndex: 0, bounds: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.1), data: PDFTestFixtureFactory.makeSignaturePNG()),
                    .link(pageIndex: 0, bounds: .init(x: 0.1, y: 0.05, width: 0.4, height: 0.08), title: "QA link", url: URL(string: "https://example.com/qa")!)])
                let page = try XCTUnwrap(PDFDocument(url: destination)?.page(at: 0))
                XCTAssertTrue(page.annotations.contains { $0.contents == "Real PDF QA" })
                XCTAssertTrue(page.annotations.contains { $0.url?.absoluteString == "https://example.com/qa" })
                try attach(destination)
                return destination
            }
        }
    }

    func testRealConversionPrintAndInspectionCorpus() throws {
        for source in try samples() {
            let document = try XCTUnwrap(PDFDocument(url: source))
            let nativeTextBeforeRendering = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
            let firstNativeText = nativeTextBeforeRendering.first { !normalizedText($0).isEmpty }
            run(source, "inspect-search-privacy") {
                let profile = try PDFInspectionService().inspect(url: source)
                XCTAssertEqual(profile.pageCount, document.pageCount)
                let index = try PDFTextIndexService().extractNativeText(from: source)
                let text = document.page(at: 0)?.string ?? ""
                if let word = text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 5 }) {
                    XCTAssertNotNil(index.firstMatchingPage(for: String(word)))
                }
                _ = try PDFDocumentStructureService().technicalInspection(in: source, profile: profile, source: nil)
                _ = try PrivacyScanService().scan(document: document, performsOCRFallback: false)
                return source
            }
            for format in PDFTextExportFormat.allCases {
                // Office exports can preserve scanned page imagery. Plain text
                // needs native text; image-only cases are covered by OCR below.
                if [.plainText, .markdown, .richText].contains(format), firstNativeText == nil {
                    rows.append(["file": source.lastPathComponent, "feature": "export-\(format.rawValue)", "status": "requires-ocr"])
                    continue
                }
                run(source, "export-\(format.rawValue)") {
                    let destination = output(source, format.rawValue).deletingPathExtension().appendingPathExtension(format.fileExtension)
                    let evidence = try PDFOutputService().exportText(sourceURL: source, destination: destination, title: "Real PDF QA", format: format)
                    XCTAssertGreaterThan(try Data(contentsOf: destination).count, 0)
                    if [.wordDocument, .excelWorkbook, .powerPointPresentation].contains(format) { XCTAssertNotNil(evidence) }
                    else if format == .plainText {
                        let exported = try String(contentsOf: destination, encoding: .utf8)
                        XCTAssertTrue(normalizedText(exported).contains(normalizedText(firstNativeText)), "Native source text must survive plain-text export")
                    }
                    let attachment = XCTAttachment(data: try Data(contentsOf: destination), uniformTypeIdentifier: "public.data")
                    attachment.name = destination.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
                    return destination
                }
            }
            run(source, "page-images-and-images-to-pdf") {
                let images = try PDFOutputService().exportPageImages(sourceURL: source, directory: directory.appendingPathComponent(source.lastPathComponent + "-png"), preset: .png)
                XCTAssertEqual(images.count, document.pageCount)
                let selected = try images.prefix(2).map { try XCTUnwrap(UIImage(contentsOfFile: $0.path)) }
                let destination = output(source, "images-to-pdf")
                try ScanPDFRenderer().render(images: selected, to: destination)
                XCTAssertEqual(PDFDocument(url: destination)?.pageCount, selected.count)
                try attach(destination)
                return destination
            }
            run(source, "print-and-booklet") {
                let printURL = output(source, "print"), bookletURL = output(source, "booklet")
                try PDFOutputService().prepareForPrint(sourceURL: source, destination: printURL, options: .standard)
                XCTAssertEqual(PDFDocument(url: printURL)?.pageCount, document.pageCount)
                try PDFOutputService().prepareBooklet(sourceURL: source, destination: bookletURL, options: .init(paperTarget: .a4, bindingEdge: .left, outerMarginPoints: 24, gutterPoints: 12, showsFoldMarks: true, signatureSheetLimit: 0, creepCompensationPoints: 0))
                XCTAssertEqual(PDFDocument(url: bookletURL)?.pageCount, ((document.pageCount + 3) / 4) * 2)
                try attach(printURL); try attach(bookletURL)
                return bookletURL
            }
        }
    }

    func testRealScannedOCRAndSearchableOutput() async throws {
        let source = try XCTUnwrap(try samples().first { $0.lastPathComponent == "ocr-multipage.pdf" })
        let result = try await VisionOCRService().recognize(url: source)
        XCTAssertEqual(result.pages.count, 6)
        let text = result.pages.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("watson"), "Compare with the actual scanned book page")
        let destination = output(source, "searchable")
        try SearchablePDFService().createSearchableCopy(sourceURL: source, ocrResult: result, destination: destination)
        XCTAssertEqual(PDFDocument(url: destination)?.pageCount, 6)
        XCTAssertTrue((PDFDocument(url: destination)?.string ?? "").lowercased().contains("watson"))
        let textURL = output(source, "ocr-text").deletingPathExtension().appendingPathExtension("txt")
        _ = try PDFOutputService().exportText(sourceURL: destination, destination: textURL, title: "Scanned book", format: .plainText)
        XCTAssertTrue(try String(contentsOf: textURL, encoding: .utf8).lowercased().contains("watson"))
        try attach(destination)
        rows.append(["file": source.lastPathComponent, "feature": "ocr-searchable", "status": "passed", "pages": "6"])
    }

    func testSearchableOverlayPreservesExistingNativeTextAndPagePixels() throws {
        let source = try XCTUnwrap(try samples().first { $0.lastPathComponent == "ocr-multipage.pdf" })
        let original = try XCTUnwrap(PDFDocument(url: source))
        let existing = normalizedText(original.page(at: 3)?.string)
        XCTAssertFalse(existing.isEmpty, "The mixed scan must include an existing native text layer")
        let text = "Native map regression"
        let block = OCRTextBlock(text: text, confidence: 1,
            normalizedX: 0.05, normalizedY: 0.05, normalizedWidth: 0.8, normalizedHeight: 0.05)
        let result = OCRResult(pages: [OCRPageResult(pageIndex: 3, text: text, confidence: 1, blocks: [block])])
        let destination = output(source, "native-map-regression")
        try SearchablePDFService().createSearchableCopy(sourceURL: source, ocrResult: result, destination: destination)
        let saved = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(saved.pageCount, original.pageCount)
        let savedText = normalizedText(saved.page(at: 3)?.string)
        XCTAssertTrue(savedText.contains(existing), "Appending OCR must preserve existing native character maps")
        XCTAssertTrue(savedText.contains(normalizedText(text)))
        for index in 0..<original.pageCount {
            XCTAssertEqual(try thumbnailPixels(XCTUnwrap(original.page(at: index))),
                           try thumbnailPixels(XCTUnwrap(saved.page(at: index))),
                           "An invisible OCR layer must not change page pixels")
        }
        try attach(destination)
    }
}

@testable import PaperPath

final class AnnotationRecoveryTests: XCTestCase {
    func testStartupPreservesInterruptedAnnotationBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        _ = try await store.load()
        let directory = root.appendingPathComponent("Documents")
        let backup = directory.appendingPathComponent(
            ".annotation-rollback-\(UUID()).pdf"
        )
        let staging = directory.appendingPathComponent(
            ".annotation-\(UUID()).pdf"
        )
        let ordinaryFile = directory.appendingPathComponent("unrelated.txt")
        let original = Data("original private PDF bytes".utf8)
        try original.write(to: backup)
        try Data("uncommitted annotation".utf8).write(to: staging)
        try Data("unrelated".utf8).write(to: ordinaryFile)

        _ = try await DocumentStore(rootURL: root).load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinaryFile.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backup.path),
            "An interrupted original must survive cleanup even when its destination is unknown."
        )
        if FileManager.default.fileExists(atPath: backup.path) {
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testAnnotationPublicationCommitsOrPreservesOriginal() throws {
        for scenario in ["success", "changed-source", "protection-failure"] {
            try XCTContext.runActivity(named: scenario) { _ in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AnnotationPublish-\(UUID())")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                defer { try? FileManager.default.removeItem(at: directory) }
                let destination = directory.appendingPathComponent("\(UUID()).pdf")
                let staging = directory.appendingPathComponent(".annotation-new.pdf")
                let original = Data("original".utf8)
                let updated = Data("annotated".utf8)
                try original.write(to: destination)
                try updated.write(to: staging)
                let manager = ProtectionFailingFileManager()
                let transaction = PDFAnnotationTransaction(fileManager: manager)
                var checks = 0
                if scenario == "protection-failure" {
                    manager.deniedPathFragment = destination.path
                }
                let publish = {
                    try transaction.publish(staging: staging, to: destination) {
                        checks += 1
                        return scenario != "changed-source" || checks == 1
                    }
                }
                if scenario == "success" {
                    try publish()
                    XCTAssertEqual(try Data(contentsOf: destination), updated)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
                } else {
                    XCTAssertThrowsError(try publish())
                    XCTAssertEqual(try Data(contentsOf: destination), original)
                }
                manager.deniedPathFragment = nil
                try transaction.recoverAll(in: directory)
                let remaining = try FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
                XCTAssertFalse(remaining.contains { $0.hasPrefix(".annotation-recovery-") })
                XCTAssertEqual(
                    try Data(contentsOf: destination),
                    scenario == "success" ? updated : original
                )
            }
        }
    }

    func testStartupRecoversAnnotationAfterFailedRestoration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationRelaunch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        _ = try await store.load()
        let directory = root.appendingPathComponent("Documents")
        let source = root.appendingPathComponent("source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 1)
        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let destination = await store.url(for: record)
        let staging = directory.appendingPathComponent(".annotation-new.pdf")
        let original = try Data(contentsOf: destination)
        try (original + Data("\n% annotation update\n".utf8)).write(to: staging)
        let manager = ProtectionFailingFileManager()
        manager.deniedPathFragment = destination.path
        XCTAssertThrowsError(
            try PDFAnnotationTransaction(fileManager: manager).publish(
                staging: staging,
                to: destination,
                sourceIsCurrent: { true }
            )
        )
        let recovery = directory.appendingPathComponent(
            ".annotation-recovery-\(destination.lastPathComponent)"
        )
        XCTAssertEqual(
            try Data(contentsOf: recovery.appendingPathComponent("original.pdf")),
            original
        )
        // A failed replacement may leave the destination missing.
        try FileManager.default.removeItem(at: destination)
        _ = try await DocumentStore(rootURL: root).load()
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testAnnotationRecoveryPreservesIndependentEdit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationConflict-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("\(UUID()).pdf")
        let staging = directory.appendingPathComponent(".annotation-new.pdf")
        try Data("original".utf8).write(to: destination)
        try Data("annotated".utf8).write(to: staging)
        let manager = ProtectionFailingFileManager()
        manager.deniedPathFragment = destination.path
        XCTAssertThrowsError(
            try PDFAnnotationTransaction(fileManager: manager).publish(
                staging: staging,
                to: destination,
                sourceIsCurrent: { true }
            )
        )
        let independentEdit = Data("a later independent edit".utf8)
        try independentEdit.write(to: destination)
        let transaction = PDFAnnotationTransaction()
        XCTAssertThrowsError(try transaction.recoverAll(in: directory))
        XCTAssertEqual(try Data(contentsOf: destination), independentEdit)
        let backup = directory.appendingPathComponent(
            ".annotation-recovery-\(destination.lastPathComponent)/original.pdf"
        )
        XCTAssertEqual(try Data(contentsOf: backup), Data("original".utf8))
    }
}

final class PDFCoreServiceRegressionTests: XCTestCase {
    private static let mebibyte = 1_024 * 1_024
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PDFCoreServiceRegressionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: temporaryDirectory
        )
    }

    private func quickLookServiceUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == 4_097
    }

    func testImportPDF_sparse256MiBUsesBoundedMemory_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("sparse-256.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: Int64(256 * Self.mebibyte)
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("LargeStore"),
            availableCapacity: { _ in
                Int64(2 * 1_024 * 1_024 * 1_024)
            }
        )
        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now

        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )

        let elapsed = startedAt.duration(to: .now)
        let peakDelta = sampler.stop()
            .saturatingSubtracting(baseline)
        let privateURL = await store.url(for: record)
        let sourceSize = try XCTUnwrap(
            source.resourceValues(forKeys: [.fileSizeKey])
                .fileSize
        )
        let privateSize = try XCTUnwrap(
            privateURL.resourceValues(forKeys: [.fileSizeKey])
                .fileSize
        )
        XCTAssertGreaterThanOrEqual(
            sourceSize,
            256 * Self.mebibyte
        )
        XCTAssertEqual(privateSize, sourceSize)
        XCTAssertEqual(record.profile.pageCount, 1)
        XCTAssertEqual(record.contentFingerprint?.count, 64)
        XCTAssertLessThan(
            elapsed,
            .seconds(20),
            "256 MiB import exceeded 20 seconds"
        )
        XCTAssertLessThan(
            peakDelta,
            UInt64(192 * Self.mebibyte),
            "256 MiB import exceeded 192 MiB peak RSS growth"
        )
    }

    func testImportPDF_trailingPaddingPreservesBytesAndDeepProfile_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("trailing-padding.pdf")
        try PDFTestFixtureFactory.makeTrailingPaddedPDF(
            at: source,
            paddingBytes: Int64(9 * Self.mebibyte)
        )
        let sourceData = try Data(
            contentsOf: source,
            options: .mappedIfSafe
        )
        let expectedFingerprint = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("TrailingPaddingStore"),
            availableCapacity: { _ in
                Int64(512 * 1_024 * 1_024)
            }
        )

        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let privateURL = await store.url(for: record)

        XCTAssertEqual(record.profile.pageCount, 1)
        XCTAssertEqual(record.profile.sampledPageCount, 1)
        XCTAssertGreaterThan(record.profile.textCharacterCount, 0)
        XCTAssertEqual(
            record.profile.byteCount,
            Int64(sourceData.count)
        )
        XCTAssertEqual(record.contentFingerprint, expectedFingerprint)
        XCTAssertEqual(
            try Data(
                contentsOf: privateURL,
                options: .mappedIfSafe
            ),
            sourceData
        )
    }

    func testMetadataOnlyInspection_detectsFormWithoutReadingContentStreams_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("metadata-only-form.pdf")
        try PDFTestFixtureFactory.makeAcroFormAutomationPDF(
            at: source
        )
        let byteCount = Int64(
            try XCTUnwrap(
                source.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
            )
        )

        let profile = try PDFInspectionService()
            .inspectMetadataOnly(
                url: source,
                byteCount: byteCount
            )

        XCTAssertEqual(profile.pageCount, 1)
        XCTAssertEqual(profile.formFieldCount, 3)
        XCTAssertEqual(profile.kind, .form)
        XCTAssertEqual(profile.sampledPageCount, 0)
        XCTAssertEqual(profile.byteCount, byteCount)
    }

    func testMetadataOnlyInspection_ignoresSparseStreamMetadataLookalikes_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("sparse-stream-lookalikes.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: Int64(16 * Self.mebibyte)
        )
        let handle = try FileHandle(forUpdating: source)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8_192) ?? Data()
        let objectMarker = Data("5 0 obj".utf8)
        let streamMarker = Data("stream\n".utf8)
        let objectRange = try XCTUnwrap(
            prefix.range(of: objectMarker)
        )
        let streamRange = try XCTUnwrap(
            prefix.range(
                of: streamMarker,
                in: objectRange.upperBound..<prefix.endIndex
            )
        )
        try handle.seek(toOffset: UInt64(streamRange.upperBound))
        try handle.write(
            contentsOf: Data(
                """
                /Type /Pages /Count 999
                /Encrypt 9 0 R
                /Subtype /Widget

                """.utf8
            )
        )
        try handle.synchronize()

        let byteCount = Int64(
            try XCTUnwrap(
                source.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
            )
        )
        let profile = try PDFInspectionService()
            .inspectMetadataOnly(
                url: source,
                byteCount: byteCount
            )

        XCTAssertEqual(profile.pageCount, 1)
        XCTAssertEqual(profile.formFieldCount, 0)
        XCTAssertFalse(profile.isEncrypted)
        XCTAssertFalse(profile.isLocked)
        XCTAssertEqual(profile.kind, .mixed)
    }

    func testMetadataOnlyInspection_ignoresSparseTrailerStringTokens_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("sparse-trailer-string.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: Int64(16 * Self.mebibyte),
            trailerEntries: "/Info (Text mentioning /Encrypt 9 0 R)"
        )
        let byteCount = Int64(
            try XCTUnwrap(
                source.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize
            )
        )

        let profile = try PDFInspectionService()
            .inspectMetadataOnly(
                url: source,
                byteCount: byteCount
            )

        XCTAssertFalse(profile.isEncrypted)
        XCTAssertFalse(profile.isLocked)
        XCTAssertEqual(profile.kind, .mixed)
    }

    func testSparseStructuralText_ignoresLiteralStringsAndComments_BitsUT()
        throws {
        let source = #"""
        /Info (Text /Encrypt 9 0 R (nested /AcroForm) escaped \) /Subtype /Widget)
        % /Encrypt 8 0 R /AcroForm 8 0 R /Subtype /Widget
        /Encrypt 7 0 R
        /AcroForm 4 0 R
        /Subtype /Widget
        """#

        let structuralText = try PDFInspectionService()
            .sparseStructuralText(from: source)

        XCTAssertFalse(structuralText.contains("/Encrypt 9 0 R"))
        XCTAssertFalse(structuralText.contains("/Encrypt 8 0 R"))
        XCTAssertTrue(structuralText.contains("/Encrypt 7 0 R"))
        XCTAssertTrue(structuralText.contains("/AcroForm 4 0 R"))
        XCTAssertEqual(
            structuralText.components(
                separatedBy: "/Subtype /Widget"
            ).count - 1,
            1
        )
        XCTAssertThrowsError(
            try PDFInspectionService()
                .sparseStructuralText(from: "(unterminated")
        )
    }

    func testImportPDF_cancelledSparseCopyLeavesNoRecord_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("cancel-sparse.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: Int64(384 * Self.mebibyte)
        )
        let root = temporaryDirectory
            .appendingPathComponent("CancelledStore")
        let store = DocumentStore(
            rootURL: root,
            availableCapacity: { _ in
                Int64(2 * 1_024 * 1_024 * 1_024)
            }
        )
        let task = Task.detached(priority: .utility) {
            try await store.importPDF(
                from: source,
                preserveSourceLocation: false
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        let cancelledAt = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled import unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        XCTAssertLessThan(
            cancelledAt.duration(to: .now),
            .seconds(2)
        )
        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
        let documents = root.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        let remainingPDFs = (
            try? FileManager.default.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: nil
            )
        )?.filter { $0.pathExtension == "pdf" } ?? []
        XCTAssertTrue(remainingPDFs.isEmpty)
    }

    func testDeliveryAudit_sparse128MiBStreamsFingerprint_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("audit-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("audit-output.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: Int64(128 * Self.mebibyte)
        )
        try FileManager.default.copyItem(
            at: source,
            to: output
        )
        let service = PDFDeliveryAuditService()
        let preflight = try service.preflight(
            sourceURL: source
        )
        XCTAssertTrue(
            preflight.items.contains {
                $0.id == "large-source"
            }
        )

        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now
        let receipt = try service.audit(
            sourceURL: source,
            outputURL: output,
            operation: .compressed
        )
        let elapsed = startedAt.duration(to: .now)
        let peakDelta = sampler.stop()
            .saturatingSubtracting(baseline)

        XCTAssertTrue(receipt.isVerified)
        XCTAssertEqual(receipt.outputPageCount, 1)
        XCTAssertEqual(receipt.sha256.count, 64)
        XCTAssertGreaterThanOrEqual(
            receipt.outputByteCount,
            Int64(128 * Self.mebibyte)
        )
        XCTAssertLessThan(
            elapsed,
            .seconds(20),
            "128 MiB delivery audit exceeded 20 seconds"
        )
        XCTAssertLessThan(
            peakDelta,
            UInt64(256 * Self.mebibyte),
            "128 MiB delivery audit exceeded 256 MiB peak RSS growth"
        )
    }

    func testOversizedPDF_guardsRunBeforeObjectParsing_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("oversized-513.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: Int64(513 * Self.mebibyte)
        )
        let output = temporaryDirectory
            .appendingPathComponent("oversized.pptx")
        let images = temporaryDirectory
            .appendingPathComponent("oversized-images")
        let startedAt = ContinuousClock.now

        XCTAssertThrowsError(
            try PDFOutputService().imageObjects(
                sourceURL: source,
                pageIndex: 0
            )
        ) { error in
            guard case PaperPathError.insufficientSelection =
                error else {
                return XCTFail("Unexpected image error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try PDFOutputService().exportEmbeddedImages(
                sourceURL: source,
                directory: images
            )
        ) { error in
            guard case PaperPathError.fileTooLarge = error else {
                return XCTFail("Unexpected export error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try PDFOutputService().exportText(
                sourceURL: source,
                destination: output,
                title: "Oversized",
                format: .powerPointPresentation
            )
        ) { error in
            guard case PaperPathError.fileTooLarge = error else {
                return XCTFail("Unexpected Office error: \(error)")
            }
        }
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(2)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: images.path)
        )
    }

    func testOfficeExports_mixedGeometryPassesCRCXMLAndRels_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("mixed-geometry.pdf")
        try PDFTestFixtureFactory.makeMixedGeometryPDF(at: source)
        let service = PDFOutputService()
        let exports: [(PDFTextExportFormat, String)] = [
            (.wordDocument, "mixed.docx"),
            (.excelWorkbook, "mixed.xlsx"),
            (.powerPointPresentation, "mixed.pptx")
        ]
        var archives: [
            PDFTextExportFormat: StoredZIPArchiveFixture
        ] = [:]

        for (format, fileName) in exports {
            let destination = temporaryDirectory
                .appendingPathComponent(fileName)
            _ = try service.exportText(
                sourceURL: source,
                destination: destination,
                title: "Mixed\u{0001} geometry",
                format: format
            )
            let archive = try StoredZIPArchiveFixture(
                data: Data(
                    contentsOf: destination,
                    options: .mappedIfSafe
                )
            )
            try archive.validateXMLAndRelationships()
            XCTAssertEqual(
                archive.localEntryCount,
                archive.centralEntryCount
            )
            archives[format] = archive
        }

        for archive in archives.values {
            let coreProperties = try XCTUnwrap(
                archive.entries["docProps/core.xml"]
            )
            XCTAssertNil(coreProperties.firstIndex(of: 0x01))
            XCTAssertTrue(
                String(decoding: coreProperties, as: UTF8.self)
                    .contains(
                        "<dc:title>Mixed geometry</dc:title>"
                    )
            )
        }

        let word = try XCTUnwrap(
            archives[.wordDocument]?
                .entries["word/document.xml"]
        )
        let wordXML = try XCTUnwrap(
            String(data: word, encoding: .utf8)
        )
        XCTAssertEqual(
            occurrenceCount(
                of: "<w:sectPr>",
                in: wordXML
            ),
            4
        )
        XCTAssertTrue(
            wordXML.contains("w:orient=\"landscape\"")
        )
        let wordStyles = try XCTUnwrap(
            archives[.wordDocument]?
                .entries["word/styles.xml"]
        )
        XCTAssertTrue(
            String(decoding: wordStyles, as: UTF8.self)
                .contains("w:ascii=\"Arial\"")
        )
        XCTAssertFalse(
            String(decoding: wordStyles, as: UTF8.self)
                .contains("Aptos")
        )

        let workbook = try XCTUnwrap(
            archives[.excelWorkbook]
        )
        XCTAssertEqual(
            workbook.entries.keys.filter {
                $0.hasPrefix("xl/worksheets/sheet")
                    && $0.hasSuffix(".xml")
            }.count,
            4
        )
        let firstSheet = try XCTUnwrap(
            workbook.entries["xl/worksheets/sheet1.xml"]
        )
        let secondSheet = try XCTUnwrap(
            workbook.entries["xl/worksheets/sheet2.xml"]
        )
        XCTAssertTrue(
            String(decoding: firstSheet, as: UTF8.self)
                .contains("orientation=\"portrait\"")
        )
        XCTAssertTrue(
            String(decoding: secondSheet, as: UTF8.self)
                .contains("orientation=\"landscape\"")
        )
        let workbookProperties = try XCTUnwrap(
            workbook.entries["docProps/app.xml"]
        )
        let workbookPropertiesXML = String(
            decoding: workbookProperties,
            as: UTF8.self
        )
        XCTAssertTrue(
            workbookPropertiesXML.contains("<HeadingPairs>")
        )
        XCTAssertTrue(
            workbookPropertiesXML.contains("<TitlesOfParts>")
        )
        XCTAssertTrue(
            workbookPropertiesXML.contains(
                "<vt:lpstr>Page 1</vt:lpstr>"
            )
        )
        let workbookStyles = try XCTUnwrap(
            workbook.entries["xl/styles.xml"]
        )
        XCTAssertTrue(
            String(decoding: workbookStyles, as: UTF8.self)
                .contains("<name val=\"Arial\"/>")
        )

        let presentation = try XCTUnwrap(
            archives[.powerPointPresentation]
        )
        let presentationXML = try XCTUnwrap(
            presentation.entries["ppt/presentation.xml"]
        )
        let presentationText = String(
            decoding: presentationXML,
            as: UTF8.self
        )
        XCTAssertTrue(
            presentationText.contains(
                "cx=\"9144000\" cy=\"6858000\""
            )
        )
        let presentationTheme = try XCTUnwrap(
            presentation.entries["ppt/theme/theme1.xml"]
        )
        let presentationThemeXML = String(
            decoding: presentationTheme,
            as: UTF8.self
        )
        XCTAssertTrue(
            presentationThemeXML.contains(
                "<a:latin typeface=\"Arial\"/>"
            )
        )
        XCTAssertFalse(presentationThemeXML.contains("Aptos"))
        let tallPageData = try XCTUnwrap(
            presentation.entries["ppt/media/page-4.jpg"]
        )
        let tallPage = try XCTUnwrap(
            UIImage(data: tallPageData)
        )
        XCTAssertLessThanOrEqual(
            max(tallPage.size.width, tallPage.size.height),
            6_000
        )
        XCTAssertGreaterThan(
            min(tallPage.size.width, tallPage.size.height),
            0
        )
    }

    func testOfficeExports_renderInSimulatorQuickLook_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("quick-look-office.pdf")
        try PDFTestFixtureFactory.makeMixedGeometryPDF(at: source)
        let service = PDFOutputService()
        let exports: [(PDFTextExportFormat, String)] = [
            (.wordDocument, "PaperPath-R213.docx"),
            (.excelWorkbook, "PaperPath-R213.xlsx"),
            (
                .powerPointPresentation,
                "PaperPath-R213.pptx"
            )
        ]

        for (format, fileName) in exports {
            let destination = temporaryDirectory
                .appendingPathComponent(fileName)
            _ = try service.exportText(
                sourceURL: source,
                destination: destination,
                title: "PaperPath Office Interoperability",
                format: format
            )

            let fileAttachment = XCTAttachment(
                contentsOfFile: destination
            )
            fileAttachment.name = fileName
            fileAttachment.lifetime = .keepAlways
            add(fileAttachment)

            let request = QLThumbnailGenerator.Request(
                fileAt: destination,
                size: CGSize(width: 1_024, height: 1_024),
                scale: 1,
                representationTypes: .thumbnail
            )
            let representation: QLThumbnailRepresentation
            do {
                representation = try await QLThumbnailGenerator
                    .shared
                    .generateBestRepresentation(for: request)
            } catch {
                if quickLookServiceUnavailable(error) {
                    throw XCTSkip(
                        "Quick Look thumbnail service unavailable in this simulator"
                    )
                }
                throw error
            }
            XCTAssertEqual(
                representation.type,
                .thumbnail,
                "\(fileName) returned an icon instead of a rendered preview"
            )
            let preview = representation.uiImage
            let minimumDimension: CGFloat
            let minimumPNGSize: Int
            if format == .excelWorkbook {
                // Spreadsheet Quick Look crops to the used cell range.
                minimumDimension = 16
                minimumPNGSize = 512
            } else {
                minimumDimension = 100
                minimumPNGSize = 2_048
            }
            XCTAssertGreaterThan(
                preview.size.width,
                minimumDimension
            )
            XCTAssertGreaterThan(
                preview.size.height,
                minimumDimension
            )
            XCTAssertGreaterThan(
                preview.pngData()?.count ?? 0,
                minimumPNGSize,
                "\(fileName) returned an empty preview"
            )

            let previewAttachment = XCTAttachment(image: preview)
            previewAttachment.name = "\(fileName)-preview"
            previewAttachment.lifetime = .keepAlways
            add(previewAttachment)
        }
    }

    func testPublicOfficeCorpusRendersInSimulatorQuickLook_BitsUT()
        async throws {
        let bundle = Bundle(for: Self.self)
        let corpusURL = try XCTUnwrap(
            bundle.url(
                forResource: "OfficeInteropCorpus",
                withExtension: nil
            )
        )
        let manifestData = try Data(
            contentsOf: corpusURL.appendingPathComponent(
                "manifest.json"
            )
        )
        let manifest = try JSONDecoder().decode(
            OfficeInteropCorpusManifest.self,
            from: manifestData
        )
        XCTAssertEqual(manifest.documents.count, 9)

        var formatCounts: [String: Int] = [:]
        for document in manifest.documents {
            let fileURL = corpusURL.appendingPathComponent(
                document.path
            )
            let fileData = try Data(
                contentsOf: fileURL,
                options: .mappedIfSafe
            )
            let fingerprint = SHA256.hash(data: fileData)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(
                fingerprint,
                document.sha256,
                "\(document.path) does not match its public source"
            )

            XCTAssertEqual(
                fileData.prefix(4),
                Data([0x50, 0x4b, 0x03, 0x04]),
                "\(document.path) is not an OOXML ZIP package"
            )

            let fileExtension = fileURL.pathExtension
                .lowercased()
            formatCounts[fileExtension, default: 0] += 1

            let request = QLThumbnailGenerator.Request(
                fileAt: fileURL,
                size: CGSize(width: 1_024, height: 1_024),
                scale: 1,
                representationTypes: .thumbnail
            )
            let representation: QLThumbnailRepresentation
            do {
                representation = try await QLThumbnailGenerator
                    .shared
                    .generateBestRepresentation(for: request)
            } catch {
                if quickLookServiceUnavailable(error) {
                    throw XCTSkip(
                        "Quick Look thumbnail service unavailable in this simulator"
                    )
                }
                XCTFail(
                    "\(document.path) Quick Look failed: \(error)"
                )
                continue
            }
            XCTAssertEqual(
                representation.type,
                .thumbnail,
                "\(document.path) returned an icon instead of rendered content"
            )
            let preview = representation.uiImage
            XCTAssertGreaterThan(
                min(preview.size.width, preview.size.height),
                16,
                "\(document.path) returned an invalid preview size"
            )
            XCTAssertGreaterThan(
                preview.pngData()?.count ?? 0,
                512,
                "\(document.path) returned an empty preview"
            )

            let attachment = XCTAttachment(image: preview)
            attachment.name =
                "\(fileURL.lastPathComponent)-preview"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertEqual(formatCounts["docx"], 3)
        XCTAssertEqual(formatCounts["xlsx"], 3)
        XCTAssertEqual(formatCounts["pptx"], 3)
    }

    func testDocumentStructure_attachmentLabelsAndReviewRoundTrip_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("structure-source.pdf")
        let labeled = temporaryDirectory
            .appendingPathComponent("structure-labeled.pdf")
        let attachmentData = Data(
            "Attachment payload".utf8
        )
        try PDFTestFixtureFactory.makeStructurePDF(
            at: source,
            attachment: .init(
                fileName: "../unsafe?.txt",
                data: attachmentData
            )
        )
        let structure = PDFDocumentStructureService()
        let attachments = try structure.attachments(in: source)
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachment.fileName, "unsafe-.txt")
        XCTAssertEqual(attachment.contentType, "text/plain")
        XCTAssertEqual(attachment.byteCount, attachmentData.count)
        XCTAssertEqual(attachment.checksum.count, 64)
        XCTAssertTrue(attachment.isExtractable)

        let extractionDirectory = temporaryDirectory
            .appendingPathComponent("extracted")
        let extracted = try structure.extractAttachments(
            in: source,
            matching: [attachment.id],
            to: extractionDirectory
        )
        XCTAssertEqual(extracted.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: extracted[0]),
            attachmentData
        )
        let labels = try structure.pageLabels(in: source)
        XCTAssertEqual(labels.map(\.label), ["i"])
        XCTAssertTrue(labels.allSatisfy(\.isExplicit))
        let reviews = try structure.unsupportedReviewAnnotations(
            in: source
        )
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews.first?.type, "Polygon")
        XCTAssertFalse(reviews.first?.canRemove ?? true)

        try PDFOutputService().applyPageLabels(
            sourceURL: source,
            destination: labeled,
            rules: [
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .decimal,
                    prefix: "A-",
                    startNumber: 7
                )
            ]
        )
        XCTAssertEqual(
            try structure.pageLabels(in: labeled).map(\.label),
            ["A-7"]
        )
        XCTAssertEqual(
            try structure.attachments(in: labeled)
                .map(\.checksum),
            [attachment.checksum]
        )
        XCTAssertEqual(
            try structure.unsupportedReviewAnnotations(
                in: labeled
            ).count,
            1
        )
    }

    func testDocumentStructure_declaredOversizedAttachmentIsBounded_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("oversized-attachment.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: source,
            attachment: .init(
                fileName: "large.bin",
                data: Data([1, 2, 3, 4]),
                declaredSize: 70 * Self.mebibyte
            )
        )

        let attachment = try XCTUnwrap(
            PDFDocumentStructureService()
                .attachments(in: source)
                .first
        )

        XCTAssertEqual(
            attachment.byteCount,
            70 * Self.mebibyte
        )
        XCTAssertFalse(attachment.isExtractable)
        XCTAssertTrue(attachment.checksum.isEmpty)
        XCTAssertNotNil(attachment.limitation)
    }

    func testDocumentStructure_compressedAttachmentWithoutDecodedSizeFailsClosed_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("untrusted-compressed-attachment.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: source,
            attachment: .init(
                fileName: "compressed.bin",
                data: Data([0x78, 0x9c, 0x03, 0x00]),
                includesDeclaredSize: false,
                filterName: "FlateDecode"
            )
        )

        let payload = try XCTUnwrap(
            PDFDocumentStructureService()
                .attachmentPayloads(in: source)
                .first
        )

        XCTAssertFalse(payload.snapshot.isExtractable)
        XCTAssertNil(payload.data)
        XCTAssertTrue(payload.snapshot.checksum.isEmpty)
        XCTAssertEqual(
            payload.snapshot.limitation,
            "Compressed attachment is missing a trusted decoded size"
        )
    }

    func testDocumentStructure_compressedAttachmentWithSmallDeclaredSizeFailsClosed_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("compressed-size-bypass.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: source,
            attachment: .init(
                fileName: "compressed.bin",
                data: Data(repeating: 0, count: 1_024),
                declaredSize: 1,
                filterName: "FlateDecode"
            )
        )

        let payload = try XCTUnwrap(
            PDFDocumentStructureService()
                .attachmentPayloads(in: source)
                .first
        )

        XCTAssertEqual(payload.snapshot.byteCount, 1)
        XCTAssertFalse(payload.snapshot.isExtractable)
        XCTAssertNil(payload.data)
        XCTAssertTrue(payload.snapshot.checksum.isEmpty)
        XCTAssertEqual(
            payload.snapshot.limitation,
            "Compressed attachments cannot be decoded within the local safety limit"
        )
    }

    func testDocumentStructure_unfilteredAttachmentCopyRequiresBoundedSource_BitsUT() {
        XCTAssertTrue(
            PDFDocumentStructureService
                .unfilteredAttachmentCopyIsBounded(
                    sourceByteCount: 4 * Self.mebibyte
                )
        )
        XCTAssertFalse(
            PDFDocumentStructureService
                .unfilteredAttachmentCopyIsBounded(
                    sourceByteCount: 64 * Self.mebibyte + 1
                )
        )
        XCTAssertFalse(
            PDFDocumentStructureService
                .unfilteredAttachmentCopyIsBounded(
                    sourceByteCount: 0
                )
        )
    }

    func testDocumentStructure_declaredAttachmentSizeMismatchFailsClosed_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("mismatched-attachment.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: source,
            attachment: .init(
                fileName: "mismatch.bin",
                data: Data([1, 2, 3, 4]),
                declaredSize: 12
            )
        )

        let payload = try XCTUnwrap(
            PDFDocumentStructureService()
                .attachmentPayloads(in: source)
                .first
        )

        XCTAssertFalse(payload.snapshot.isExtractable)
        XCTAssertNil(payload.data)
        XCTAssertTrue(payload.snapshot.checksum.isEmpty)
        XCTAssertEqual(payload.snapshot.byteCount, 4)
        XCTAssertEqual(
            payload.snapshot.limitation,
            "Decoded attachment size does not match its PDF declaration"
        )
    }

    func testFormAutomation_calculatesFormatsAndRefreshes_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("automation.pdf")
        try PDFTestFixtureFactory.makeAcroFormAutomationPDF(
            at: source
        )
        let inspection = PDFFormInspectionService()
        let before = try inspection.inspect(url: source)
        let totalBefore = try XCTUnwrap(
            before.automationFields.first {
                $0.fieldName == "Total"
            }
        )
        XCTAssertEqual(totalBefore.expectedValue, "30")
        XCTAssertEqual(totalBefore.formattedPreview, "$30.00")
        XCTAssertTrue(totalBefore.needsUpdate)
        XCTAssertNil(totalBefore.validationIssue)
        XCTAssertEqual(before.unsupportedJavaScriptCount, 0)

        try PDFMutationService().refreshFormAutomation(
            in: source
        )

        let after = try inspection.inspect(url: source)
        let totalField = try XCTUnwrap(
            after.fields.first { $0.name == "Total" }
        )
        let totalAfter = try XCTUnwrap(
            after.automationFields.first {
                $0.fieldName == "Total"
            }
        )
        XCTAssertEqual(totalField.value, "30")
        XCTAssertFalse(totalAfter.needsUpdate)
        XCTAssertEqual(totalAfter.formattedPreview, "$30.00")
        XCTAssertEqual(
            totalAfter.calculation?.operation,
            .sum
        )
        XCTAssertEqual(
            totalAfter.rangeValidation?.minimum,
            0
        )
        XCTAssertEqual(
            totalAfter.rangeValidation?.maximum,
            100
        )
    }

    func testFormAutomation_customScriptFailsClosedWithoutMutation_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("custom-script.pdf")
        try PDFTestFixtureFactory.makeAcroFormAutomationPDF(
            at: source,
            customCalculationScript: "event.value = 42;"
        )
        let before = try Data(contentsOf: source)
        let report = try PDFFormInspectionService()
            .inspect(url: source)
        XCTAssertEqual(report.unsupportedJavaScriptCount, 1)
        XCTAssertTrue(report.hasJavaScript)

        XCTAssertThrowsError(
            try PDFMutationService()
                .refreshFormAutomation(in: source)
        ) { error in
            guard case PaperPathError.insufficientSelection =
                error else {
                return XCTFail("Unexpected script error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testMutation_invalidBatchLeavesSourceUnchanged_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("atomic-mutation.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 3
        )
        let original = try Data(contentsOf: source)
        let mutation = PDFMutationService()

        XCTAssertThrowsError(
            try mutation.rotatePages(
                at: [0, 99],
                in: source
            )
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(
            try mutation.deletePages(
                at: [0, 1, 2],
                in: source
            )
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(
            try mutation.appendPages(
                from: source,
                indices: [-1],
                in: source
            )
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testVisionOCR_oversizedCustomDictionaryIsRejected_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("ocr-config.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let configuration = OCRRecognitionConfiguration(
            languageMode: .automatic,
            languageIdentifiers: [],
            customWords: (0..<51).map { "Term\($0)" }
        )

        do {
            _ = try await VisionOCRService().recognize(
                url: source,
                configuration: configuration
            )
            XCTFail("Oversized custom dictionary was accepted")
        } catch let error as PaperPathError {
            guard case .insufficientSelection = error else {
                return XCTFail("Unexpected OCR error: \(error)")
            }
        }
    }

    func testCompressionEstimate_sixtyPagesSamplesThree_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("compression-60.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 60
        )
        let startedAt = ContinuousClock.now

        let estimate = try PDFOutputService()
            .estimateCompression(
                sourceURL: source,
                quality: .balanced,
                mode: .imageCopy
            )

        XCTAssertEqual(estimate.sampledPageCount, 3)
        XCTAssertGreaterThan(estimate.sourceByteCount, 0)
        XCTAssertGreaterThan(estimate.estimatedByteCount, 0)
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(5)
        )
    }

    func testCombine_twoHundredPagesUsesBoundedMemory_BitsUT()
        throws {
        let first = temporaryDirectory
            .appendingPathComponent("combine-100-a.pdf")
        let second = temporaryDirectory
            .appendingPathComponent("combine-100-b.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("combine-200-output.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: first,
            pageCount: 100
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: second,
            pageCount: 100
        )
        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now

        try PDFCompositionService().combine(
            urls: [first, second],
            to: output
        )

        let elapsed = startedAt.duration(to: .now)
        let peakDelta = sampler.stop()
            .saturatingSubtracting(baseline)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 200)
        XCTAssertTrue(
            document.page(at: 0)?.string?
                .contains("Fixture page 1") == true
        )
        XCTAssertTrue(
            document.page(at: 199)?.string?
                .contains("Fixture page 100") == true
        )
        XCTAssertLessThan(elapsed, .seconds(20))
        XCTAssertLessThan(
            peakDelta,
            UInt64(256 * Self.mebibyte),
            "200-page combine exceeded 256 MiB peak RSS growth"
        )
    }

    func testCompression_fortyPagesUsesBoundedMemory_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("compression-40-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("compression-40-output.pdf")
        try PDFTestFixtureFactory.makeTrailingPaddedPDF(
            at: source,
            paddingBytes: Int64(64 * Self.mebibyte),
            pageCount: 40
        )
        let sourceByteCount = try XCTUnwrap(
            source.resourceValues(forKeys: [.fileSizeKey])
                .fileSize
        )
        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now

        try PDFOutputService().compress(
            sourceURL: source,
            destination: output,
            quality: .balanced
        )

        let elapsed = startedAt.duration(to: .now)
        let peakDelta = sampler.stop()
            .saturatingSubtracting(baseline)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let outputByteCount = try XCTUnwrap(
            output.resourceValues(forKeys: [.fileSizeKey])
                .fileSize
        )
        XCTAssertEqual(document.pageCount, 40)
        XCTAssertLessThan(outputByteCount, sourceByteCount)
        XCTAssertLessThan(elapsed, .seconds(45))
        XCTAssertLessThan(
            peakDelta,
            UInt64(256 * Self.mebibyte),
            "40-page compression exceeded 256 MiB peak RSS growth"
        )
    }

    func testSafeShare_fortyPagesUsesBoundedMemory_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("safe-share-40-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("safe-share-40-output.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 40
        )
        let sourceDocument = try XCTUnwrap(
            PDFDocument(url: source)
        )
        sourceDocument.documentAttributes = [
            PDFDocumentAttribute.authorAttribute: "Private Author",
            PDFDocumentAttribute.titleAttribute: "Private Title"
        ]
        XCTAssertTrue(sourceDocument.write(to: source))
        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now

        try PDFOutputService().safeShare(
            sourceURL: source,
            destination: output
        )

        let elapsed = startedAt.duration(to: .now)
        let peakDelta = sampler.stop()
            .saturatingSubtracting(baseline)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 40)
        XCTAssertEqual(
            document.documentAttributes?[
                PDFDocumentAttribute.authorAttribute
            ] as? String,
            nil
        )
        XCTAssertTrue(
            (0..<document.pageCount).allSatisfy {
                document.page(at: $0)?.string?.isEmpty != false
            }
        )
        XCTAssertLessThan(elapsed, .seconds(45))
        XCTAssertLessThan(
            peakDelta,
            UInt64(256 * Self.mebibyte),
            "40-page safe share exceeded 256 MiB peak RSS growth"
        )
    }

    func testVisionOCR_thousandPageResumeUsesBoundedMemory_BitsUT()
        async throws {
#if targetEnvironment(simulator)
        let recognitionPageCount = 8
        let maximumDuration: Duration = .seconds(30)
        let maximumPeakRSS = UInt64(512 * Self.mebibyte)
#else
        let recognitionPageCount = 20
        let maximumDuration: Duration = .seconds(30)
        let maximumPeakRSS = UInt64(256 * Self.mebibyte)
#endif
        let source = temporaryDirectory
            .appendingPathComponent("ocr-resume-1000.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1_000
        )
        let identity = OCRCheckpointIdentity(
            recordID: UUID(),
            revisionID: UUID(),
            pageCount: 1_000,
            configuration: .automatic
        )
        let checkpoint = OCRCheckpoint(
            identity: identity,
            pages: (0..<(1_000 - recognitionPageCount)).map {
                OCRPageResult(
                    pageIndex: $0,
                    text: "Recovered fixture page \($0 + 1)",
                    confidence: 0.99,
                    blocks: []
                )
            }
        )
        let service = VisionOCRService()
        service.releaseCachedResources()
        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now

        let result = try await service.recognize(
            url: source,
            checkpoint: checkpoint
        )

        let elapsed = startedAt.duration(to: .now)
        let peakRSS = sampler.stop()
        let peakDelta = peakRSS
            .saturatingSubtracting(baseline)
        service.releaseCachedResources()
        let baselineMiB = baseline / 1_024 / 1_024
        let peakMiB = peakRSS / 1_024 / 1_024
        let growthMiB = peakDelta / 1_024 / 1_024
        await XCTContext.runActivity(
            named: """
            OCR stress: \(recognitionPageCount) pages in \(elapsed), \
            RSS \(baselineMiB) -> \(peakMiB) MiB (+\(growthMiB) MiB)
            """
        ) { _ in }
        XCTAssertEqual(result.pages.count, 1_000)
        XCTAssertEqual(
            result.pages.map(\.pageIndex),
            Array(0..<1_000)
        )
        XCTAssertTrue(
            result.pages.suffix(recognitionPageCount).allSatisfy {
                !$0.text.isEmpty
            }
        )
        XCTAssertLessThan(elapsed, maximumDuration)
        XCTAssertLessThan(
            peakDelta,
            maximumPeakRSS,
            "\(recognitionPageCount)-page resumed OCR exceeded its peak RSS budget"
        )
    }

    func testCompareVersions_twoHundredPagesUsesBoundedMemory_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("compare-200-source.pdf")
        let revised = temporaryDirectory
            .appendingPathComponent("compare-200-revised.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 200
        )
        try FileManager.default.copyItem(
            at: source,
            to: revised
        )
        let baseline = testResidentMemory()
        let sampler = TestProcessMemorySampler()
        sampler.start()
        let startedAt = ContinuousClock.now

        let review = try PDFDeliveryAuditService().compare(
            sourceURL: source,
            revisedURL: revised
        )

        let elapsed = startedAt.duration(to: .now)
        let peakDelta = sampler.stop()
            .saturatingSubtracting(baseline)
        XCTAssertTrue(review.isIdentical)
        XCTAssertEqual(review.comparedPageCount, 200)
        XCTAssertLessThan(elapsed, .seconds(15))
        XCTAssertLessThan(
            peakDelta,
            UInt64(192 * Self.mebibyte),
            "200-page comparison exceeded 192 MiB peak RSS growth"
        )
    }

    func testFormInspection_zeroPagePDFIsRejectedBeforeAutomation_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("zero-page.pdf")
        try PDFTestFixtureFactory.makeZeroPagePDF(at: source)

        XCTAssertThrowsError(
            try PDFFormInspectionService().inspect(url: source)
        ) { error in
            guard case PaperPathError.unreadablePDF = error else {
                return XCTFail(
                    "Unexpected zero-page PDF error: \(error)"
                )
            }
        }
    }

    private func occurrenceCount(
        of value: String,
        in source: String
    ) -> Int {
        guard !value.isEmpty else { return 0 }
        var count = 0
        var range = source.startIndex..<source.endIndex
        while let match = source.range(
            of: value,
            range: range
        ) {
            count += 1
            range = match.upperBound..<source.endIndex
        }
        return count
    }
}

final class PDFBoundaryBehaviorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PDFBoundaryBehaviorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: temporaryDirectory
        )
    }

    func testOverlongAnnotationEditPreservesOriginalPDFBytes_BitsUT() throws {
        let url = temporaryDirectory.appendingPathComponent("long-note.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: url, pageCount: 1)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 100, width: 24, height: 24),
            forType: .text, withProperties: nil)
        note.contents = "Original note must survive"
        page.addAnnotation(note)
        XCTAssertTrue(document.write(to: url))
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try PDFMutationService().editAnnotation(
            PDFAnnotationEditPayload(pageIndex: 0, annotationIndex: 0,
                expectedType: "Text", contents: String(repeating: "n", count: 2001),
                color: PDFInkColor(red: 0, green: 0, blue: 0, alpha: 1), lineWidth: 1),
            in: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.first?.contents,
            "Original note must survive")
    }

    func testEditAnnotation_outOfRangeColorUsesNormalizedComponents_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("normalized-color.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 80, y: 520, width: 160, height: 80),
            forType: .square,
            withProperties: nil
        )
        annotation.contents = "Review"
        annotation.color = .black
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: source))

        try PDFMutationService().editAnnotation(
            PDFAnnotationEditPayload(
                pageIndex: 0,
                annotationIndex: 0,
                expectedType: "Square",
                contents: "Review",
                color: PDFInkColor(
                    red: 1.4,
                    green: 0.2,
                    blue: -0.3,
                    alpha: 1
                ),
                lineWidth: 2
            ),
            in: source
        )

        let snapshot = try XCTUnwrap(
            PDFMutationService().annotations(in: source).first
        )
        XCTAssertEqual(snapshot.color.red, 1, accuracy: 0.025)
        XCTAssertEqual(snapshot.color.green, 0.2, accuracy: 0.025)
        XCTAssertEqual(snapshot.color.blue, 0, accuracy: 0.025)
    }

    func testStructuralRewrites_rejectSamePathWithoutChangingSource_BitsUT()
        throws {
        let service = PDFOutputService()
        let source = temporaryDirectory
            .appendingPathComponent("same-path-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let original = try Data(contentsOf: source)

        for operation in [
            {
                try service.protect(
                    sourceURL: source,
                    destination: source,
                    password: "Secure123"
                )
            },
            {
                try service.applyPageLabels(
                    sourceURL: source,
                    destination: source,
                    rules: [
                        PDFPageLabelRule(
                            startPageIndex: 0,
                            style: .decimal
                        )
                    ]
                )
            }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case PaperPathError.insufficientSelection =
                        error
                else {
                    return XCTFail(
                        "Unexpected same-path error: \(error)"
                    )
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }

        let form = temporaryDirectory
            .appendingPathComponent("same-path-form.pdf")
        try PDFTestFixtureFactory.makeAcroFormAutomationPDF(
            at: form
        )
        let originalForm = try Data(contentsOf: form)
        XCTAssertThrowsError(
            try service.applyFormFieldValues(
                sourceURL: form,
                destination: form,
                values: ["Amount A": "42"]
            )
        ) { error in
            guard case PaperPathError.insufficientSelection = error
            else {
                return XCTFail(
                    "Unexpected same-path form error: \(error)"
                )
            }
        }
        XCTAssertEqual(try Data(contentsOf: form), originalForm)

        let protected = temporaryDirectory
            .appendingPathComponent("same-path-protected.pdf")
        try service.protect(
            sourceURL: source,
            destination: protected,
            password: "Secure123"
        )
        let originalProtected = try Data(contentsOf: protected)
        XCTAssertThrowsError(
            try service.removePassword(
                sourceURL: protected,
                destination: protected,
                password: "Secure123"
            )
        ) { error in
            guard case PaperPathError.insufficientSelection = error
            else {
                return XCTFail(
                    "Unexpected same-path unlock error: \(error)"
                )
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: protected),
            originalProtected
        )
    }

    func testProtect_permissionMatrixRoundTrips_BitsUT() throws {
        let source = temporaryDirectory
            .appendingPathComponent("permission-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let configurations = [
            PDFProtectionPermissions(
                allowsPrinting: false,
                allowsCopying: false,
                allowsCommenting: false,
                allowsFormFilling: false,
                allowsPageChanges: false
            ),
            PDFProtectionPermissions(
                allowsPrinting: true,
                allowsCopying: true,
                allowsCommenting: false,
                allowsFormFilling: true,
                allowsPageChanges: false
            ),
            PDFProtectionPermissions(
                allowsPrinting: true,
                allowsCopying: true,
                allowsCommenting: true,
                allowsFormFilling: true,
                allowsPageChanges: true
            )
        ]

        for (index, permissions) in configurations.enumerated() {
            let destination = temporaryDirectory
                .appendingPathComponent("permission-\(index).pdf")
            try PDFOutputService().protect(
                sourceURL: source,
                destination: destination,
                password: "local-only",
                permissions: permissions
            )

            let document = try XCTUnwrap(
                PDFDocument(url: destination)
            )
            XCTAssertTrue(document.isLocked)
            XCTAssertTrue(
                document.unlock(withPassword: "local-only")
            )
            let stored = document.accessPermissions
            func has(
                _ permission: PDFAccessPermissions
            ) -> Bool {
                stored.rawValue & permission.rawValue != 0
            }
            XCTAssertEqual(
                has(.allowsHighQualityPrinting),
                permissions.allowsPrinting
            )
            XCTAssertEqual(
                has(.allowsContentCopying),
                permissions.allowsCopying
            )
            XCTAssertEqual(
                has(.allowsCommenting),
                permissions.allowsCommenting
            )
            XCTAssertEqual(
                has(.allowsFormFieldEntry)
                    || has(.allowsCommenting),
                permissions.allowsFormFilling
                    || permissions.allowsCommenting
            )
            XCTAssertEqual(
                has(.allowsDocumentAssembly),
                permissions.allowsPageChanges
            )
            XCTAssertTrue(
                has(.allowsContentAccessibility)
            )
        }
    }

    func testExtractAttachments_invalidSelectionLeavesNoOutput_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("attachment-source.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: source,
            attachment: .init(
                fileName: "notes.txt",
                data: Data("Private notes".utf8)
            )
        )
        let service = PDFDocumentStructureService()
        let emptyDirectory = temporaryDirectory
            .appendingPathComponent("empty-selection")
        XCTAssertThrowsError(
            try service.extractAttachments(
                in: source,
                matching: [],
                to: emptyDirectory
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: emptyDirectory.path
            )
        )

        let staleDirectory = temporaryDirectory
            .appendingPathComponent("stale-selection")
        XCTAssertThrowsError(
            try service.extractAttachments(
                in: source,
                matching: ["stale-attachment-id"],
                to: staleDirectory
            )
        ) { error in
            guard case PaperPathError.outputVerificationFailed =
                error else {
                return XCTFail(
                    "Unexpected stale selection error: \(error)"
                )
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staleDirectory.path
            )
        )
    }

    func testApplyPageLabels_invalidRulesLeaveNoOutput_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("page-label-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let invalidRuleSets: [[PDFPageLabelRule]] = [
            [
                PDFPageLabelRule(
                    startPageIndex: 1,
                    style: .decimal
                )
            ],
            [
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .decimal
                ),
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .lowercaseRoman
                )
            ],
            [
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .uppercaseRoman,
                    startNumber: 4_000
                )
            ]
        ]

        for (index, rules) in invalidRuleSets.enumerated() {
            let destination = temporaryDirectory
                .appendingPathComponent("invalid-labels-\(index).pdf")
            XCTAssertThrowsError(
                try PDFOutputService().applyPageLabels(
                    sourceURL: source,
                    destination: destination,
                    rules: rules
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: destination.path
                )
            )
        }
    }

    func testFormAutomation_missingCalculationSourceFailsClosed_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("missing-calculation-source.pdf")
        try PDFTestFixtureFactory.makeAcroFormAutomationPDF(
            at: source,
            customCalculationScript:
                #"AFSimple_Calculate("SUM", new Array("Missing Amount"));"#
        )
        let sourceBeforeRefresh = try Data(contentsOf: source)

        let report = try PDFFormInspectionService().inspect(
            url: source
        )

        let total = try XCTUnwrap(
            report.automationFields.first {
                $0.fieldName == "Total"
            }
        )
        XCTAssertEqual(report.unsupportedJavaScriptCount, 0)
        XCTAssertNil(total.expectedValue)
        XCTAssertTrue(
            total.validationIssue?.contains("Missing Amount")
                == true
        )
        XCTAssertThrowsError(
            try PDFMutationService().refreshFormAutomation(
                in: source
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: source),
            sourceBeforeRefresh
        )
    }
}

final class PDFUnlockStructureTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PDFUnlockStructureTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: temporaryDirectory
        )
    }

    func testRemovePassword_preservesDocumentStructure_BitsUT()
        throws {
        let plain = temporaryDirectory
            .appendingPathComponent("structured-source.pdf")
        let protected = temporaryDirectory
            .appendingPathComponent("structured-protected.pdf")
        let unlocked = temporaryDirectory
            .appendingPathComponent("structured-unlocked.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: plain,
            attachment: .init(
                fileName: "evidence.txt",
                data: Data("Verified evidence".utf8)
            )
        )
        let structure = PDFDocumentStructureService()
        let sourceAttachments = try structure.attachments(
            in: plain
        )
        let sourceLabels = try structure.pageLabels(in: plain)
        let sourceReviews = try structure
            .unsupportedReviewAnnotations(in: plain)
        try PDFOutputService().protect(
            sourceURL: plain,
            destination: protected,
            password: "local-only"
        )

        try PDFOutputService().removePassword(
            sourceURL: protected,
            destination: unlocked,
            password: "local-only"
        )

        XCTAssertEqual(
            try structure.attachments(in: unlocked)
                .map(\.checksum),
            sourceAttachments.map(\.checksum)
        )
        XCTAssertEqual(
            try structure.pageLabels(in: unlocked),
            sourceLabels
        )
        XCTAssertEqual(
            try structure.unsupportedReviewAnnotations(in: unlocked)
                .map(\.type),
            sourceReviews.map(\.type)
        )
    }

    func testAudit_unlockedRejectsMissingDocumentStructure_BitsUT()
        throws {
        let plain = temporaryDirectory
            .appendingPathComponent("audit-structured-source.pdf")
        let protected = temporaryDirectory
            .appendingPathComponent("audit-structured-protected.pdf")
        let lossyOutput = temporaryDirectory
            .appendingPathComponent("audit-lossy-output.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(
            at: plain,
            attachment: .init(
                fileName: "audit.txt",
                data: Data("Audit evidence".utf8)
            )
        )
        try PDFOutputService().protect(
            sourceURL: plain,
            destination: protected,
            password: "local-only"
        )
        let sourceDocument = try XCTUnwrap(
            PDFDocument(url: plain)
        )
        let outputDocument = PDFDocument()
        let copiedPage = try XCTUnwrap(
            sourceDocument.page(at: 0)?.copy() as? PDFPage
        )
        outputDocument.insert(copiedPage, at: 0)
        XCTAssertTrue(outputDocument.write(to: lossyOutput))
        XCTAssertTrue(
            try PDFDocumentStructureService()
                .attachments(in: lossyOutput).isEmpty
        )

        XCTAssertThrowsError(
            try PDFDeliveryAuditService().audit(
                sourceURL: protected,
                outputURL: lossyOutput,
                operation: .unlocked,
                unlockPassword: "local-only"
            )
        ) { error in
            guard case PaperPathError.outputVerificationFailed =
                error else {
                return XCTFail(
                    "Unexpected audit error: \(error)"
                )
            }
        }
    }
}

private struct OfficeInteropCorpusManifest: Decodable {
    let documents: [OfficeInteropCorpusDocument]
}

private struct OfficeInteropCorpusDocument: Decodable {
    let path: String
    let sha256: String
}

private final class TestProcessMemorySampler:
    @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var isRunning = false
    private var peak: UInt64 = 0

    func start() {
        lock.lock()
        isRunning = true
        peak = testResidentMemory()
        lock.unlock()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            while running {
                let current = testResidentMemory()
                lock.lock()
                peak = max(peak, current)
                lock.unlock()
                usleep(2_000)
            }
        }
    }

    func stop() -> UInt64 {
        lock.lock()
        isRunning = false
        lock.unlock()
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    private var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }
}

private func testResidentMemory() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size
            / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
        pointer -> kern_return_t in
        pointer.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(count)
        ) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS
        ? UInt64(info.resident_size)
        : 0
}

private extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

final class PDFStabilityContractTests: XCTestCase {
    private var temporaryDirectory: URL!

    @MainActor
    func testPDFViewDeferredUpdatesOnlyAcceptLatestObservedGeneration_BitsUT() {
        let coordinator = PDFDocumentView.Coordinator(
            onPageChange: { _ in }
        )
        let view = PDFView()
        coordinator.observePageChanges(in: view)

        let first = coordinator.beginDeferredUpdate(in: view)
        let second = coordinator.beginDeferredUpdate(in: view)

        XCTAssertFalse(
            coordinator.isCurrentDeferredUpdate(first, in: view)
        )
        XCTAssertTrue(
            coordinator.isCurrentDeferredUpdate(second, in: view)
        )

        coordinator.stopObservingPageChanges()

        XCTAssertFalse(
            coordinator.isCurrentDeferredUpdate(second, in: view)
        )
    }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PDFStabilityContractTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testOfficeExports_duplicatePageIndexUsesPreferredText_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("duplicate-index.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: source,
            paddingBytes: 0
        )
        let preferredText =
            "Preferred complete office text with invoice total 1280"
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(pageIndex: 0, text: "Short"),
                IndexedPageText(pageIndex: -1, text: "Invalid"),
                IndexedPageText(
                    pageIndex: 0,
                    text: preferredText
                )
            ],
            indexedAt: Date()
        )
        let service = PDFOutputService()
        let officeExports: [
            (
                format: PDFTextExportFormat,
                fileName: String,
                contentPath: String
            )
        ] = [
            (
                .wordDocument,
                "duplicate.docx",
                "word/document.xml"
            ),
            (
                .excelWorkbook,
                "duplicate.xlsx",
                "xl/worksheets/sheet1.xml"
            ),
            (
                .powerPointPresentation,
                "duplicate.pptx",
                "ppt/slides/slide1.xml"
            )
        ]

        for item in officeExports {
            let destination = temporaryDirectory
                .appendingPathComponent(item.fileName)
            XCTAssertNoThrow(
                _ = try service.exportText(
                    sourceURL: source,
                    destination: destination,
                    textIndex: index,
                    title: "Duplicate index",
                    format: item.format
                )
            )
            let archive = try StoredZIPArchiveFixture(
                data: Data(contentsOf: destination)
            )
            let content = try XCTUnwrap(
                archive.entries[item.contentPath]
            )
            XCTAssertTrue(
                String(decoding: content, as: UTF8.self)
                    .contains(preferredText)
            )
        }

        for format in [
            PDFTextExportFormat.richText,
            .markdown,
            .plainText
        ] {
            let destination = temporaryDirectory
                .appendingPathComponent(
                    "duplicate.\(format.fileExtension)"
                )
            XCTAssertNoThrow(
                _ = try service.exportText(
                    sourceURL: source,
                    destination: destination,
                    textIndex: index,
                    title: "Duplicate index",
                    format: format
                )
            )
            XCTAssertTrue(
                String(
                    decoding: try Data(contentsOf: destination),
                    as: UTF8.self
                ).contains(preferredText)
            )
        }
    }

    func testOCRResult_duplicatePagePrefersCorrectedAndQualityText_BitsUT() {
        let corrected = OCRPageResult(
            pageIndex: 0,
            text: "Corrected",
            confidence: 0.7,
            blocks: [
                makeOCRBlock(
                    text: "Corrected",
                    confidence: 0.7,
                    isUserCorrected: true
                )
            ]
        )
        let uncorrected = OCRPageResult(
            pageIndex: 0,
            text: "Longer uncorrected candidate",
            confidence: 0.99,
            blocks: [
                makeOCRBlock(
                    text: "Longer uncorrected candidate",
                    confidence: 0.99
                )
            ]
        )
        let correctedResult = OCRResult(
            pages: [uncorrected, corrected]
        )
        XCTAssertEqual(correctedResult.pages, [corrected])

        let fragmented = OCRPageResult(
            pageIndex: 1,
            text: "Bad",
            confidence: 0.2,
            blocks: [
                makeOCRBlock(text: "B", confidence: 0.2),
                makeOCRBlock(text: "a", confidence: 0.2),
                makeOCRBlock(text: "d", confidence: 0.2)
            ]
        )
        let complete = OCRPageResult(
            pageIndex: 1,
            text: "Complete recognized invoice total 1280",
            confidence: 0.95,
            blocks: [
                makeOCRBlock(
                    text: "Complete recognized invoice total 1280",
                    confidence: 0.95
                )
            ],
            recognitionPass: .enhanced
        )
        let qualityResult = OCRResult(
            pages: [fragmented, complete]
        )
        XCTAssertEqual(qualityResult.pages, [complete])
    }

    func testOfficeFailureClassify_recoveryMatchesFailure_BitsUT() {
        let sourceLimit = PDFOfficeExportFailure.classify(
            format: .powerPointPresentation,
            error: PaperPathError.fileTooLarge
        )
        XCTAssertEqual(sourceLimit.kind, .sourceLimit)

        let storage = PDFOfficeExportFailure.classify(
            format: .wordDocument,
            error: PaperPathError.insufficientStorage
        )
        XCTAssertEqual(storage.kind, .storage)

        let busy = PDFOfficeExportFailure.classify(
            format: .excelWorkbook,
            error: PaperPathError.insufficientSelection(
                "Another operation is already using this PDF."
            )
        )
        XCTAssertEqual(busy.kind, .busy)
    }

    func testImportPDF_protectionFailureLeavesNoPrivateCopy_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("protection-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let root = temporaryDirectory
            .appendingPathComponent("ProtectedDocumentStore")
        let fileManager = ProtectionFailingFileManager()
        fileManager.deniedPathFragment = ".pdf"
        let store = DocumentStore(
            rootURL: root,
            fileManager: fileManager
        )

        do {
            _ = try await store.importPDF(from: source)
            XCTFail("Import should fail when protection cannot be applied")
        } catch ProtectionTestError.denied {
            // Expected.
        } catch {
            XCTFail("Unexpected protection error: \(error)")
        }

        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
        let documents = root.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        let remainingPDFs = (
            try? FileManager.default.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: nil
            )
        )?.filter { $0.pathExtension == "pdf" } ?? []
        XCTAssertTrue(remainingPDFs.isEmpty)
    }

    func testSignatureStore_protectionFailureLeavesNoLibrary_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("ProtectedSignatureStore")
        let fileManager = ProtectionFailingFileManager()
        fileManager.deniedPathFragment = "saved-signatures"
        let store = SignatureStore(
            rootURL: root,
            fileManager: fileManager
        )

        do {
            try await store.save(
                PDFTestFixtureFactory.makeSignaturePNG(seed: 1)
            )
            XCTFail(
                "Signature save should fail when protection cannot be applied"
            )
        } catch ProtectionTestError.denied {
            // Expected.
        } catch {
            XCTFail("Unexpected protection error: \(error)")
        }

        let libraryURL = root.appendingPathComponent(
            "saved-signatures.json"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: libraryURL.path)
        )
        let storedSignature = try await store.load()
        XCTAssertNil(storedSignature)
    }

    func testSignatureStore_updateProtectionFailurePreservesLibrary_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("ExistingSignatureStore")
        let original = PDFTestFixtureFactory.makeSignaturePNG(seed: 9)
        try await SignatureStore(rootURL: root).save(original)

        let fileManager = ProtectionFailingFileManager()
        fileManager.deniedPathFragment = "saved-signatures"
        let failingStore = SignatureStore(
            rootURL: root,
            fileManager: fileManager
        )

        do {
            try await failingStore.save(
                PDFTestFixtureFactory.makeSignaturePNG(seed: 1)
            )
            XCTFail(
                "Signature update should fail when protection is denied"
            )
        } catch ProtectionTestError.denied {
            // Expected.
        } catch {
            XCTFail("Unexpected protection error: \(error)")
        }

        fileManager.deniedPathFragment = nil
        let storedSignature = try await failingStore.load()
        XCTAssertEqual(storedSignature, original)
    }

    func testExternalPDFInbox_protectsBeforePublishing_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("shared-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let sharedContainer = temporaryDirectory
            .appendingPathComponent(
                "SharedContainer",
                isDirectory: true
            )
        var protectedPaths: [String] = []

        let item = try ExternalPDFInbox.stagePDF(
            from: source,
            suggestedName: "  Shared contract.pdf  ",
            sharedContainerURL: sharedContainer,
            protectionHandler: { url in
                protectedPaths.append(url.standardizedFileURL.path)
            }
        )

        XCTAssertEqual(item.preferredName, "Shared contract")
        XCTAssertTrue(
            protectedPaths.contains {
                $0.hasSuffix("/document.pdf")
            }
        )
        XCTAssertTrue(
            protectedPaths.contains {
                $0.hasSuffix("metadata.json")
            }
        )
        let pending = try ExternalPDFInbox.pendingItems(
            sharedContainerURL: sharedContainer
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.preferredName, "Shared contract")

        try ExternalPDFInbox.remove(
            item,
            sharedContainerURL: sharedContainer
        )
        XCTAssertTrue(
            try ExternalPDFInbox.pendingItems(
                sharedContainerURL: sharedContainer
            ).isEmpty
        )
    }

    func testExternalPDFInbox_protectionFailurePublishesNothing_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("blocked-share.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let sharedContainer = temporaryDirectory
            .appendingPathComponent(
                "BlockedSharedContainer",
                isDirectory: true
            )

        XCTAssertThrowsError(
            try ExternalPDFInbox.stagePDF(
                from: source,
                sharedContainerURL: sharedContainer,
                protectionHandler: { url in
                    if url.lastPathComponent == "metadata.json" {
                        throw ProtectionTestError.denied
                    }
                }
            )
        ) { error in
            guard case ProtectionTestError.denied = error else {
                return XCTFail(
                    "Unexpected protection error: \(error)"
                )
            }
        }

        let inbox = sharedContainer
            .appendingPathComponent("SharedImports", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
        let published = (
            try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        XCTAssertTrue(published.isEmpty)

        let staging = sharedContainer
            .appendingPathComponent("SharedImports", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        let abandoned = (
            try? FileManager.default.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        XCTAssertTrue(abandoned.isEmpty)
    }

    private func makeOCRBlock(
        text: String,
        confidence: Double,
        isUserCorrected: Bool = false
    ) -> OCRTextBlock {
        OCRTextBlock(
            text: text,
            confidence: confidence,
            normalizedX: 0.1,
            normalizedY: 0.1,
            normalizedWidth: 0.8,
            normalizedHeight: 0.1,
            isUserCorrected: isUserCorrected
        )
    }
}

final class PDFCriticalFeatureContractTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PDFCriticalFeatureContractTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSignatureStore_rejectsEmptyPayload_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("EmptySignatureStore")
        let store = SignatureStore(rootURL: root)

        do {
            _ = try await store.add(Data())
            XCTFail("An empty signature must not be accepted")
        } catch PaperPathError.storageFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected empty-signature error: \(error)")
        }

        let library = try await store.loadLibrary()
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertNil(library.selectedID)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("saved-signatures.json")
                    .path
            )
        )
    }

    func testSignatureStore_deduplicatesBoundsAndSelectsFallback_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("BoundedSignatureStore")
        let store = SignatureStore(rootURL: root)
        let signatures = (0..<6).map {
            PDFTestFixtureFactory.makeSignaturePNG(seed: $0)
        }
        for signature in signatures {
            _ = try await store.add(signature)
        }

        var library = try await store.loadLibrary()
        XCTAssertEqual(
            library.entries.count,
            SignatureStore.maximumSignatureCount
        )
        XCTAssertEqual(library.entries.first?.data, signatures[5])
        XCTAssertEqual(library.selectedID, library.entries.first?.id)

        let originalID = try XCTUnwrap(
            library.entries.first {
                $0.data == signatures[3]
            }?.id
        )
        library = try await store.add(signatures[3])
        XCTAssertEqual(library.entries.count, 5)
        XCTAssertEqual(library.entries.first?.id, originalID)
        XCTAssertEqual(library.entries.first?.data, signatures[3])

        library = try await store.remove(id: originalID)
        XCTAssertEqual(library.entries.count, 4)
        XCTAssertEqual(library.selectedID, library.entries.first?.id)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, library.entries.first?.data)
    }

    func testSignatureStore_migratesLegacyPayloadOnNextSave_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("LegacySignatureStore")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let legacyURL = root.appendingPathComponent(
            "saved-signature.data"
        )
        let legacy = PDFTestFixtureFactory.makeSignaturePNG(seed: 7)
        let added = PDFTestFixtureFactory.makeSignaturePNG(seed: 1)
        try legacy.write(to: legacyURL)
        let store = SignatureStore(rootURL: root)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, legacy)
        let library = try await store.add(added)

        XCTAssertEqual(library.entries.count, 2)
        XCTAssertEqual(library.entries.first?.data, added)
        XCTAssertEqual(library.entries.last?.data, legacy)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyURL.path)
        )
    }

    func testSaveAnalysis_failurePreservesPreviousSidecars_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("analysis-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let root = temporaryDirectory
            .appendingPathComponent("AnalysisStore")
        let fileManager = ProtectionFailingFileManager()
        let store = DocumentStore(
            rootURL: root,
            fileManager: fileManager
        )
        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let originalIndex = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "Original recognized value"
                )
            ],
            indexedAt: Date(timeIntervalSince1970: 10)
        )
        let originalOCR = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "Original recognized value",
                    confidence: 0.91,
                    blocks: [
                        makeOCRBlock(
                            text: "Original recognized value",
                            confidence: 0.91
                        )
                    ]
                )
            ]
        )
        let originalBrief = DocumentUnderstandingService().analyze(
            index: originalIndex,
            profile: record.profile
        )
        let savedRecord = try await store.saveAnalysis(
            record,
            brief: originalBrief,
            textIndex: originalIndex,
            ocrResult: originalOCR
        )

        let replacementIndex = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "Replacement recognized value"
                )
            ],
            indexedAt: Date(timeIntervalSince1970: 20)
        )
        let replacementOCR = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "Replacement recognized value",
                    confidence: 0.99,
                    blocks: [
                        makeOCRBlock(
                            text: "Replacement recognized value",
                            confidence: 0.99
                        )
                    ]
                )
            ]
        )
        let replacementBrief = DocumentUnderstandingService().analyze(
            index: replacementIndex,
            profile: savedRecord.profile
        )
        fileManager.deniedPathFragment = "OCR/.protected-"

        do {
            _ = try await store.saveAnalysis(
                savedRecord,
                brief: replacementBrief,
                textIndex: replacementIndex,
                ocrResult: replacementOCR
            )
            XCTFail("A partial analysis update must not succeed")
        } catch PaperPathError.storageFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected analysis storage error: \(error)")
        }

        let indices = try await store.loadTextIndices()
        let results = try await store.loadOCRResults()
        let records = try await store.load()
        XCTAssertEqual(
            indices[record.id],
            originalIndex.bound(to: savedRecord.contentRevisionID)
        )
        XCTAssertEqual(results[record.id], originalOCR)
        XCTAssertEqual(records.first?.brief, originalBrief)
    }

    func testSearchTextIndices_metadataHitSkipsUnavailableSidecar_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("MetadataFirstSearchStore")
        let source = temporaryDirectory
            .appendingPathComponent("metadata-search-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let store = DocumentStore(rootURL: root)
        let record = try await store.importPDF(
            from: source,
            preferredName: "Quarterly Review",
            preserveSourceLocation: false
        )
        let recordID = record.id
        let sidecarURL = root
            .appendingPathComponent("TextIndex", isDirectory: true)
            .appendingPathComponent(
                "\(recordID.uuidString).json",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: sidecarURL,
            withIntermediateDirectories: true
        )
        let candidate = DocumentStoreTextSearchCandidate(
            recordID: recordID,
            metadataCorpus: DocumentSearchNormalization.text(
                "Quarterly Review"
            ),
            pageCount: 1,
            hasAnalysis: false,
            contentRevisionID: record.contentRevisionID
        )

        let metadataMatch = try await store.searchTextIndices(
            query: "quarterly review",
            candidates: [candidate]
        )
        XCTAssertEqual(
            metadataMatch.matchingRecordIDs,
            Set([recordID])
        )
        XCTAssertTrue(metadataMatch.matchesByRecordID.isEmpty)

        let missingBodyMatch = try await store.searchTextIndices(
            query: "body-only needle",
            candidates: [candidate]
        )
        XCTAssertTrue(missingBodyMatch.matchingRecordIDs.isEmpty)
        XCTAssertTrue(missingBodyMatch.matchesByRecordID.isEmpty)
    }

    func testBootstrapSnapshot_restoresOnlyEightRecentAnalyses_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("bootstrap-analysis.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("BootstrapAnalysisStore")
        )
        var recordIDs: [UUID] = []
        for index in 0..<10 {
            var record = try await store.importPDF(
                from: source,
                preferredName: "Analysis \(index)",
                preserveSourceLocation: false
            )
            let text = "Indexed content \(index)"
            let textIndex = DocumentTextIndex(
                source: .vision,
                pages: [
                    IndexedPageText(
                        pageIndex: 0,
                        text: text
                    )
                ],
                indexedAt: Date(
                    timeIntervalSince1970: Double(index)
                )
            )
            record = try await store.saveAnalysis(
                record,
                brief: DocumentBrief(
                    category: .general,
                    summary: text,
                    entities: [],
                    suggestedSteps: [],
                    indexedAt: textIndex.indexedAt,
                    textSource: .vision,
                    indexedCharacterCount: text.count
                ),
                textIndex: textIndex,
                ocrResult: OCRResult(
                    pages: [
                        OCRPageResult(
                            pageIndex: 0,
                            text: text,
                            confidence: 0.9
                        )
                    ]
                )
            )
            _ = try await store.updateReadingPosition(
                recordID: record.id,
                pageIndex: 0,
                expectedRevisionID: record.contentRevisionID,
                viewedAt: Date(
                    timeIntervalSince1970: Double(1_000 + index)
                )
            )
            recordIDs.append(record.id)
        }

        let snapshot = try await store.loadBootstrapSnapshot()
        let expectedIDs = Set(recordIDs.suffix(8))

        XCTAssertEqual(snapshot.documents.count, 10)
        XCTAssertEqual(Set(snapshot.textIndices.keys), expectedIDs)
        XCTAssertEqual(Set(snapshot.ocrResults.keys), expectedIDs)
    }

    func testExternalPDFInbox_rejectsInvalidAndIgnoresTamperedPayload_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory
            .appendingPathComponent("SharedContainer")
        let invalid = temporaryDirectory
            .appendingPathComponent("not-a-pdf.pdf")
        try Data("plain text".utf8).write(to: invalid)

        XCTAssertThrowsError(
            try ExternalPDFInbox.stagePDF(
                from: invalid,
                sharedContainerURL: sharedContainer,
                protectionHandler: { _ in }
            )
        ) { error in
            guard case ExternalPDFInboxError.invalidPDF = error else {
                return XCTFail("Unexpected inbox error: \(error)")
            }
        }

        let valid = temporaryDirectory
            .appendingPathComponent("valid.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: valid,
            pageCount: 1
        )
        let item = try ExternalPDFInbox.stagePDF(
            from: valid,
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )
        try Data("tampered".utf8).write(to: item.fileURL)

        XCTAssertTrue(
            try ExternalPDFInbox.pendingItems(
                sharedContainerURL: sharedContainer
            ).isEmpty
        )
    }

    func testExternalPDFInbox_removeCannotEscapeTrustedInbox_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory
            .appendingPathComponent("RemovalContainer")
        let outside = temporaryDirectory
            .appendingPathComponent("outside.inbox", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let outsideFile = outside.appendingPathComponent("document.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: outsideFile,
            pageCount: 1
        )
        let item = ExternalPDFInboxItem(
            containerURL: outside,
            fileURL: outsideFile,
            preferredName: "Outside"
        )

        try ExternalPDFInbox.remove(
            item,
            sharedContainerURL: sharedContainer
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path)
        )
    }

    func testProtectionRejectsOverlongPasswordsInsteadOfMatchingTruncatedPrefixes_BitsUT() {
        let prefix = String(repeating: "p", count: 128)
        XCTAssertNil(PDFProtectionPasswordValidation.message(password: prefix, confirmation: prefix))
        XCTAssertNotNil(PDFProtectionPasswordValidation.message(password: prefix + "A", confirmation: prefix + "B"))
        XCTAssertNotNil(PDFProtectionPasswordValidation.message(password: prefix + "A", confirmation: prefix + "A"))
        XCTAssertNotNil(PDFProtectionPasswordValidation.message(password: prefix, confirmation: prefix + "A"))
        XCTAssertNotNil(PDFProtectionPasswordValidation.message(password: "1234567", confirmation: "1234567"))
        XCTAssertNil(PDFProtectionPasswordValidation.message(password: "12345678", confirmation: "12345678"))
        XCTAssertNotNil(PDFProtectionPasswordValidation.message(password: "12345678", confirmation: "12345679"))
        XCTAssertNotNil(PDFProtectionPasswordValidation.message(password: " password", confirmation: "password"))
    }

    func testBatchCompressionDoesNotDescribeFailuresAsUnchanged_BitsUT() {
        let failed = PDFCompressionBatchOutputState(successfulCount: 0, unchangedCount: 0, failedCount: 2)
        XCTAssertEqual(failed, .unavailable)
        XCTAssertEqual(failed.placeholder, "No compressed output")
        let unchanged = PDFCompressionBatchOutputState(successfulCount: 0, unchangedCount: 2, failedCount: 0)
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(unchanged.placeholder, "No change needed")
        XCTAssertEqual(PDFCompressionBatchOutputState(successfulCount: 0, unchangedCount: 1, failedCount: 1), .unavailable)
        XCTAssertEqual(PDFCompressionBatchOutputState(successfulCount: 1, unchangedCount: 1, failedCount: 1), .compressed)
        XCTAssertNil(PDFCompressionBatchOutputState.compressed.placeholder)
        XCTAssertEqual(PDFCompressionBatchOutputState(successfulCount: 0, unchangedCount: 0, failedCount: 0), .unavailable)
    }

    func testPageJumpAcceptsLocalizedDigitsWithoutReinterpretingInvalidInput_BitsUT() {
        for value in ["12", "１２", "١٢", "۱۲", " 12\n"] {
            XCTAssertEqual(PDFPageNumberInput.pageIndex(value, pageCount: 20), 11)
        }
        for value in ["", "0", "21", "1-3", "1,3", "1 3", "-3", "+3", "½", "²", "Ⅻ", "1️⃣", "1000000"] {
            XCTAssertNil(PDFPageNumberInput.pageIndex(value, pageCount: 20), value)
        }
        XCTAssertEqual(PDFPageNumberInput.pageIndex("100000", pageCount: 100000), 99999)
        XCTAssertEqual(PDFPageNumberInput.pageIndex("000012", pageCount: 20), 11)
        XCTAssertNil(PDFPageNumberInput.pageIndex("1", pageCount: 0))
        XCTAssertNil(PDFPageNumberInput.pageIndex("1", pageCount: -1))
    }

    func testOCRPhraseSearchUsesDocumentNormalizationWithoutChangingPhraseSemantics_BitsUT() {
        let search = DocumentPhraseSearch(query: " payment cafe ")
        XCTAssertTrue(search.matches("Earlier PAY\u{00ad}MENT Café details"))
        XCTAssertTrue(search.matches("Earlier ＰＡＹＭＥＮＴ Café details"))
        XCTAssertTrue(DocumentPhraseSearch(query: "pay\u{00ad}ment").matches("Payment"))
        XCTAssertFalse(search.matches("cafe payment"))
        XCTAssertFalse(search.matches("payment invoice cafe"))
        XCTAssertFalse(search.matches("payment\ncafe"))
        XCTAssertFalse(DocumentPhraseSearch(query: "cooperate").matches("co-operate"))
        for query in ["", " \n ", "\u{00ad}"] {
            XCTAssertFalse(DocumentPhraseSearch(query: query).matches("Payment café"))
        }
    }

    func testDocumentSearchFindsWordsContainingDiscretionaryHyphens_BitsUT() throws {
        let original = String(repeating: "Earlier context ", count: 20)
            + "PAY\u{00ad}MENT Café invoice co-operate"
        let index = DocumentTextIndex(
            source: .native,
            pages: [IndexedPageText(pageIndex: 3, text: original)],
            indexedAt: Date()
        )
        let match = try XCTUnwrap(index.firstMatch(for: "payment cafe"))
        XCTAssertEqual(match.pageIndex, 3)
        XCTAssertTrue(match.excerpt.contains("PAYMENT Café"))
        XCTAssertFalse(match.excerpt.contains("\u{00ad}"))
        XCTAssertEqual(index.pages.first?.text, original)
        XCTAssertEqual(index.matches(for: "pay\u{00ad}ment").count, 1)
        XCTAssertTrue(try index.containsEveryTerm(["payment", "cafe"]))
        XCTAssertEqual(try index.cancellableMatches(for: "payment").count, 1)
        XCTAssertTrue(index.matches(for: "cooperate").isEmpty)
        XCTAssertEqual(index.matches(for: "co-operate").count, 1)
        XCTAssertTrue(index.matches(for: "\u{00ad}").isEmpty)
    }

    func testDocumentTextIndex_segmentsAndBoundsSearchResults_BitsUT() {
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(pageIndex: 4, text: "Outside before"),
                IndexedPageText(
                    pageIndex: 5,
                    text: String(repeating: "prefix ", count: 20)
                        + "Needle alpha"
                ),
                IndexedPageText(
                    pageIndex: 7,
                    text: "Needle alpha beta"
                ),
                IndexedPageText(pageIndex: 8, text: "Outside after")
            ],
            indexedAt: Date(timeIntervalSince1970: 100)
        )

        let segment = index.segment(from: 5, through: 7)
        XCTAssertEqual(segment.pages.map(\.pageIndex), [0, 2])
        XCTAssertEqual(segment.indexedAt, index.indexedAt)

        let matches = index.matches(
            for: "needle alpha",
            excerptLimit: 48,
            limit: 1
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.pageIndex, 5)
        XCTAssertLessThanOrEqual(matches.first?.excerpt.count ?? 0, 50)
        XCTAssertTrue(index.matches(for: "   ").isEmpty)
        XCTAssertTrue(index.matches(for: "needle", limit: 0).isEmpty)
    }

    func testOCRResult_discardsNegativePagesAndUsesStableTieBreakers_BitsUT() {
        let standard = OCRPageResult(
            pageIndex: 2,
            text: "Equal",
            confidence: 0.8,
            blocks: [
                makeOCRBlock(text: "Equal", confidence: 0.8)
            ],
            recognitionPass: .standard
        )
        let enhanced = OCRPageResult(
            pageIndex: 2,
            text: "Equal",
            confidence: 0.8,
            blocks: [
                makeOCRBlock(text: "Equal", confidence: 0.8)
            ],
            recognitionPass: .enhanced
        )
        let result = OCRResult(
            pages: [
                enhanced,
                OCRPageResult(
                    pageIndex: -1,
                    text: "Invalid",
                    confidence: 1
                ),
                OCRPageResult(
                    pageIndex: 0,
                    text: "First",
                    confidence: 0.6
                ),
                standard
            ]
        )

        XCTAssertEqual(result.pages.map(\.pageIndex), [0, 2])
        XCTAssertEqual(result.pages.last?.recognitionPass, .enhanced)
        XCTAssertEqual(result.enhancedPageCount, 1)
        XCTAssertEqual(result.meanConfidence, 0.7, accuracy: 0.0001)
    }

    func testOfficeBatchPlan_coversEveryPageOnceWithinFormatLimit_BitsUT() {
        let profile = makeProfile(pageCount: 1_201)
        let plan = PDFOfficeBatchPlan(
            format: .wordDocument,
            sourceRevisionID: UUID(),
            profile: profile
        )
        let pages = plan.segments.flatMap(\.pageIndices)

        XCTAssertTrue(plan.isBatchRequired)
        XCTAssertEqual(pages, Array(0..<1_201))
        XCTAssertEqual(Set(pages).count, 1_201)
        XCTAssertTrue(
            plan.segments.allSatisfy {
                $0.pageCount > 0
                    && $0.pageCount
                        <= PDFTextExportFormat.wordDocument.officePageLimit!
            }
        )
    }

    func testOfficeBatchRun_restoresInterruptedAndChangedSources_BitsUT() {
        let revisionID = UUID()
        let plan = PDFOfficeBatchPlan(
            format: .wordDocument,
            sourceRevisionID: revisionID,
            profile: makeProfile(pageCount: 1_201)
        )
        XCTAssertGreaterThanOrEqual(plan.segmentCount, 2)
        var run = PDFOfficeBatchRun(plan: plan)
        run.status = .running
        run.segments[0].status = .extracting
        run.segments[0].fractionCompleted = 0.4
        run.segments[1].status = .completed
        run.segments[1].fractionCompleted = 1
        run.segments[1].receiptID = UUID()
        let availableReceiptIDs = Set(
            run.segments.compactMap(\.receiptID)
        )

        let resumed = run.restored(
            currentRevisionID: revisionID,
            availableReceiptIDs: availableReceiptIDs
        )
        XCTAssertEqual(resumed.status, .paused)
        XCTAssertEqual(resumed.segments[0].status, .queued)
        XCTAssertEqual(resumed.segments[0].fractionCompleted, 0)
        XCTAssertEqual(resumed.segments[1].status, .completed)

        let changed = run.restored(
            currentRevisionID: UUID(),
            availableReceiptIDs: availableReceiptIDs
        )
        XCTAssertEqual(changed.status, .failed)
        XCTAssertEqual(changed.segments[0].status, .failed)
        XCTAssertEqual(changed.segments[0].fractionCompleted, 1)
        XCTAssertEqual(changed.segments[1].status, .failed)
        XCTAssertEqual(changed.segments[1].fractionCompleted, 1)
    }

    func testOfficeProductionQueue_restoresAndBoundsHistory_BitsUT() {
        let recordID = UUID()
        let revisionID = UUID()
        var active = makeQueueJob(
            recordID: recordID,
            revisionID: revisionID,
            priority: .urgent,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        active.stage = .analyzing
        var queued = makeQueueJob(
            recordID: recordID,
            revisionID: revisionID,
            priority: .background,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        queued.stage = .queued
        let terminal = (0..<45).map { index -> PDFOfficeQueueJob in
            var job = makeQueueJob(
                recordID: recordID,
                revisionID: revisionID,
                priority: .normal,
                createdAt: Date(timeIntervalSince1970: Double(10 + index))
            )
            job.stage = .completed
            job.completedAt = Date(
                timeIntervalSince1970: Double(100 + index)
            )
            return job
        }
        var queue = PDFOfficeProductionQueue(
            jobs: terminal + [queued, active]
        )

        queue.boundHistory()
        XCTAssertEqual(queue.jobs.count, 42)
        XCTAssertEqual(queue.jobs.filter(\.stage.isTerminal).count, 40)
        XCTAssertFalse(queue.jobs[0].stage.isTerminal)
        XCTAssertEqual(queue.jobs[0].priority, .urgent)

        queue.restoreInterruptedWork()
        XCTAssertTrue(queue.isSuspended)
        XCTAssertEqual(
            queue.jobs.first { $0.id == active.id }?.stage,
            .paused
        )
        XCTAssertFalse(queue.hasRunnableJobs)
    }

    func testOfficeProgress_clampsFractionsAndDetectsStalls_BitsUT() {
        let byteProgress = PDFOfficeIntegrityProgress(
            completedCount: 0,
            totalCount: 4,
            currentSourceName: "Sample",
            processedBytes: 150,
            totalBytes: 100
        )
        XCTAssertEqual(byteProgress.fractionCompleted, 1)

        let countProgress = PDFOfficeIntegrityProgress(
            completedCount: 2,
            totalCount: 4,
            currentSourceName: "Sample"
        )
        XCTAssertEqual(countProgress.fractionCompleted, 0.5)

        let now = Date()
        let stalled = PDFOfficeIntegrityProgress(
            completedCount: 0,
            totalCount: 1,
            currentSourceName: "Sample",
            processedBytes: 10,
            totalBytes: 100,
            lastByteUpdateAt: now.addingTimeInterval(-3)
        )
        XCTAssertTrue(stalled.isStalled(at: now))
        XCTAssertFalse(
            stalled.isStalled(
                at: now.addingTimeInterval(-2)
            )
        )
    }

    func testPinnedVersionCapacity_enforcesCountAndByteBoundaries_BitsUT() {
        let available = PDFPinnedVersionStorageSummary(
            milestoneCount: 31,
            byteCount: PDFPinnedVersionStorageSummary.maximumByteCount - 10
        )
        XCTAssertTrue(available.isNearCapacity)
        XCTAssertTrue(available.canAdd(bytes: 10))
        XCTAssertFalse(available.canAdd(bytes: 11))

        let full = PDFPinnedVersionStorageSummary(
            milestoneCount: 32,
            byteCount: 0
        )
        XCTAssertFalse(full.canAdd(bytes: 0))
    }

    func testOfficeFailureClassification_coversRecoveryMatrix_BitsUT() {
        let cases: [
            (
                error: PaperPathError,
                expected: PDFOfficeExportFailureKind
            )
        ] = [
            (.lockedPDF, .rights),
            (.missingRecognizedText, .missingText),
            (.insufficientStorage, .storage),
            (.fileTooLarge, .sourceLimit),
            (
                .outputVerificationFailed(
                    "The source changed during export"
                ),
                .sourceChanged
            ),
            (
                .outputVerificationFailed("CRC mismatch"),
                .verification
            ),
            (
                .insufficientSelection(
                    "Another operation is already using this PDF"
                ),
                .busy
            )
        ]

        for item in cases {
            XCTAssertEqual(
                PDFOfficeExportFailure.classify(
                    format: .wordDocument,
                    error: item.error
                ).kind,
                item.expected
            )
        }
        XCTAssertEqual(
            PDFOfficeExportFailureKind.sourceLimit.recoveryTask,
            .splitPDF
        )
        XCTAssertEqual(
            PDFOfficeExportFailureKind.missingText.recoveryTask,
            .recognizeText
        )
        XCTAssertFalse(PDFOfficeExportFailureKind.rights.allowsRetry)
    }

    func testCompositionExtraction_deduplicatesAndRejectsInvalidPages_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("composition-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 3
        )
        let destination = temporaryDirectory
            .appendingPathComponent("deduplicated.pdf")
        let service = PDFCompositionService()

        try service.extractPages(
            from: source,
            indices: [2, 2, 0],
            to: destination
        )
        let output = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertTrue(
            output.page(at: 0)?.string?.contains("Fixture page 1")
                == true
        )
        XCTAssertTrue(
            output.page(at: 1)?.string?.contains("Fixture page 3")
                == true
        )

        let invalidDestination = temporaryDirectory
            .appendingPathComponent("invalid-extract.pdf")
        XCTAssertThrowsError(
            try service.extractPages(
                from: source,
                indices: [-1],
                to: invalidDestination
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: invalidDestination.path
            )
        )
    }

    func testSearchableCopy_ignoresOutOfRangeOCRAndPreservesPages_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("searchable-source.pdf")
        let destination = temporaryDirectory
            .appendingPathComponent("searchable-output.pdf")
        try makeBlankPDF(at: source, pageCount: 2)
        let result = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "Valid searchable text",
                    confidence: 0.98,
                    blocks: [
                        makeOCRBlock(
                            text: "Valid searchable text",
                            confidence: 0.98
                        )
                    ]
                ),
                OCRPageResult(
                    pageIndex: 99,
                    text: "Stale page text",
                    confidence: 0.99,
                    blocks: [
                        makeOCRBlock(
                            text: "Stale page text",
                            confidence: 0.99
                        )
                    ]
                )
            ]
        )

        try SearchablePDFService().createSearchableCopy(
            sourceURL: source,
            ocrResult: result,
            destination: destination
        )

        let output = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertTrue(
            output.page(at: 0)?.string?
                .contains("Valid searchable text") == true
        )
        XCTAssertFalse(
            output.string?.contains("Stale page text") == true
        )
    }

    func testMutation_invalidReorderLeavesSourceUnchanged_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("reorder-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 3
        )
        let original = try Data(contentsOf: source)
        let service = PDFMutationService()

        for order in [[0, 0, 2], [0, 1], [0, 1, 3]] {
            XCTAssertThrowsError(
                try service.reorderPages(
                    order: order,
                    in: source
                )
            )
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testMutation_negativeBlankInsertionIsRejectedAtomically_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("blank-insertion-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let original = try Data(contentsOf: source)

        XCTAssertThrowsError(
            try PDFMutationService().insertBlankPage(
                after: -2,
                in: source
            )
        ) { error in
            guard case PaperPathError.invalidPage = error else {
                return XCTFail(
                    "Unexpected blank insertion error: \(error)"
                )
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testTextExport_missingTextLeavesNoArtifact_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("blank-text-source.pdf")
        try makeBlankPDF(at: source, pageCount: 1)
        let destination = temporaryDirectory
            .appendingPathComponent("missing.txt")
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: -1,
                    text: "Invalid page text"
                ),
                IndexedPageText(pageIndex: 0, text: "   ")
            ],
            indexedAt: Date()
        )

        XCTAssertThrowsError(
            try PDFOutputService().exportText(
                sourceURL: source,
                destination: destination,
                textIndex: index,
                title: "Missing",
                format: .plainText
            )
        ) { error in
            guard case PaperPathError.missingRecognizedText = error else {
                return XCTFail("Unexpected text export error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
    }

    func testOfficeExports_escapeUntrustedTextAndValidatePackages_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("special-office-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "A&B <C> \"D\" 'E'"
                )
            ],
            indexedAt: Date()
        )

        for format in [
            PDFTextExportFormat.wordDocument,
            .excelWorkbook,
            .powerPointPresentation
        ] {
            let destination = temporaryDirectory
                .appendingPathComponent(
                    "special.\(format.fileExtension)"
                )
            _ = try PDFOutputService().exportText(
                sourceURL: source,
                destination: destination,
                textIndex: index,
                title: "Title & <unsafe> \"quoted\"",
                format: format,
                profile: makeProfile(pageCount: 1)
            )
            let archive = try StoredZIPArchiveFixture(
                data: Data(contentsOf: destination)
            )
            try archive.validateXMLAndRelationships()
        }
    }

    func testPageImageExport_allPresetsProduceStablePageSet_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("page-images-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )

        for preset in PDFPageImageExportPreset.allCases {
            let directory = temporaryDirectory
                .appendingPathComponent(
                    "images-\(preset.rawValue)",
                    isDirectory: true
                )
            let urls = try PDFOutputService().exportPageImages(
                sourceURL: source,
                directory: directory,
                preset: preset
            )
            XCTAssertEqual(urls.count, 2)
            XCTAssertEqual(
                urls.map {
                    $0.deletingPathExtension().lastPathComponent
                },
                ["Page-001", "Page-002"]
            )
            XCTAssertTrue(
                urls.allSatisfy {
                    (
                        try? $0.resourceValues(
                            forKeys: [.fileSizeKey]
                        ).fileSize
                    ) ?? 0 > 0
                }
            )
        }
    }

    func testDocumentStore_normalizesUserMetadataAndBookmarks_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("metadata-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 4
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("MetadataStore")
        )
        var record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        record = try await store.updateTags(
            record,
            tags: [
                " Legal ",
                "legal",
                "Finance",
                "One",
                "Two",
                "Three",
                "Four",
                "Five",
                "Six",
                "Seven"
            ],
            expectedTags: record.tags
        )
        XCTAssertEqual(record.tags.count, 8)
        XCTAssertEqual(record.tags.first, "Legal")
        XCTAssertEqual(
            record.tags.filter {
                $0.caseInsensitiveCompare("legal") == .orderedSame
            }.count,
            1
        )

        record = try await store.updateBookmarks(
            record,
            pages: [3, 1, 1, -1, 99]
        )
        XCTAssertEqual(record.bookmarkedPages, [1, 3])
        record = try await store.updatePrivateNote(
            record,
            note: "  \(String(repeating: "n", count: 1_200))  ",
            expectedNote: record.privateNote
        )
        XCTAssertEqual(record.privateNote?.count, 1_000)
        record = try await store.updateReadingPosition(
            recordID: record.id,
            pageIndex: 99,
            expectedRevisionID: record.contentRevisionID
        )
        XCTAssertEqual(record.lastPageIndex, 3)

        let loaded = try await store.load()
        let reopened = try XCTUnwrap(loaded.first)
        XCTAssertEqual(reopened.tags, record.tags)
        XCTAssertEqual(reopened.bookmarkedPages, [1, 3])
        XCTAssertEqual(reopened.privateNote?.count, 1_000)
        XCTAssertEqual(reopened.lastPageIndex, 3)
    }

    func testReadingPosition_ignoresOlderEvents_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("reading-events.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 4
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ReadingEventStore")
        )
        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let newestEvent = Date(timeIntervalSince1970: 300)
        _ = try await store.updateReadingPosition(
            recordID: record.id,
            pageIndex: 3,
            expectedRevisionID: record.contentRevisionID,
            viewedAt: newestEvent
        )

        let staleResult = try await store.updateReadingPosition(
            recordID: record.id,
            pageIndex: 0,
            expectedRevisionID: record.contentRevisionID,
            viewedAt: Date(timeIntervalSince1970: 200)
        )
        let loaded = try await store.load()
        let persisted = try XCTUnwrap(loaded.first)

        XCTAssertEqual(staleResult.lastPageIndex, 3)
        XCTAssertEqual(staleResult.lastViewedAt, newestEvent)
        XCTAssertEqual(persisted.lastPageIndex, 3)
        XCTAssertEqual(persisted.lastViewedAt, newestEvent)
    }

    func testDocumentStore_trashRestoreAndPurgeLifecycle_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("trash-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("TrashStore")
        )
        let imported = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let privateURL = await store.url(for: imported)
        var trashed = try await store.moveToTrash(imported)
        let activeAfterTrash = try await store.load()
        let deletedAfterTrash = try await store.loadDeleted()
        XCTAssertTrue(activeAfterTrash.isEmpty)
        XCTAssertEqual(deletedAfterTrash.map(\.id), [imported.id])

        let restored = try await store.restoreFromTrash(trashed)
        XCTAssertNil(restored.deletedAt)
        let activeAfterRestore = try await store.load()
        XCTAssertEqual(activeAfterRestore.map(\.id), [imported.id])

        trashed = try await store.moveToTrash(restored)
        let removed = try await store.purgeDeleted(
            before: Date().addingTimeInterval(1)
        )
        XCTAssertEqual(removed, [trashed.id])
        let deletedAfterPurge = try await store.loadDeleted()
        XCTAssertTrue(deletedAfterPurge.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: privateURL.path)
        )
    }

    func testDocumentStore_versionDedupAndTamperDetection_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("version-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let root = temporaryDirectory
            .appendingPathComponent("VersionStore")
        let store = DocumentStore(rootURL: root)
        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )

        let first = try await store.createVersionSnapshot(
            for: record,
            label: "First"
        )
        let duplicate = try await store.createVersionSnapshot(
            for: record,
            label: "Duplicate"
        )
        XCTAssertEqual(duplicate.id, first.id)
        let versions = try await store.versions(for: record.id)
        XCTAssertEqual(
            versions.count,
            1
        )

        let versionURL = root
            .appendingPathComponent("Versions", isDirectory: true)
            .appendingPathComponent(first.fileName)
        try Data("tampered".utf8).write(to: versionURL)
        do {
            _ = try await store.versionFileURL(
                snapshotID: first.id,
                recordID: record.id
            )
            XCTFail("A tampered version must not be returned")
        } catch PaperPathError.outputVerificationFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected version integrity error: \(error)")
        }
    }

    func testDeliveryMilestoneCreatesCurrentVersionIdempotently_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("current-receipt-milestone.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let revisionID = UUID()
        let fingerprint = sha256(try Data(contentsOf: source))
        let byteCount = Int64(
            try source.resourceValues(forKeys: [.fileSizeKey])
                .fileSize ?? 0
        )
        let receipt = makeDeliveryReceipt(
            fingerprint: fingerprint,
            revisionID: revisionID,
            pageCount: 2,
            byteCount: byteCount
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("CurrentReceiptMilestoneStore")
        )
        let imported = try await store.importPDF(
            from: source,
            deliveryReceipt: receipt,
            sourceDocumentID: UUID(),
            contentRevisionID: revisionID,
            preserveSourceLocation: false
        )
        XCTAssertTrue(imported.isDeliveryArtifact)
        XCTAssertTrue(imported.hasCurrentDeliveryReceipt)

        var mismatched = imported
        mismatched.contentFingerprint = String(repeating: "f", count: 64)
        XCTAssertFalse(mismatched.hasCurrentDeliveryReceipt)

        var legacy = imported
        legacy.deliveryReceipt?.outputRevisionID = nil
        XCTAssertTrue(legacy.hasCurrentDeliveryReceipt)

        let protected = try await store
            .protectDeliveryReceiptMilestone(
                for: imported,
                label: "Protect verified version",
                milestoneName: "Verified output"
            )
        XCTAssertTrue(protected.isPinnedMilestone)
        XCTAssertTrue(protected.matchesDeliveryReceipt(receipt))
        XCTAssertEqual(
            protected.linkedDeliveryReceiptID,
            receipt.id
        )

        let repeated = try await store
            .protectDeliveryReceiptMilestone(
                for: imported,
                label: "Protect verified version",
                milestoneName: "Verified output"
            )
        XCTAssertEqual(repeated.id, protected.id)
        let retainedVersions = try await store.versions(
            for: imported.id
        )
        XCTAssertEqual(retainedVersions.count, 1)
    }

    func testDeliveryMilestoneProtectsExactRecoveryVersionIdempotently_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("receipt-milestone.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let revisionID = UUID()
        let fingerprint = sha256(try Data(contentsOf: source))
        let byteCount = Int64(
            try source.resourceValues(forKeys: [.fileSizeKey])
                .fileSize ?? 0
        )
        var receipt = makeDeliveryReceipt(
            fingerprint: fingerprint,
            revisionID: revisionID,
            pageCount: 2,
            byteCount: byteCount
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ReceiptMilestoneStore")
        )
        let imported = try await store.importPDF(
            from: source,
            deliveryReceipt: receipt,
            sourceDocumentID: UUID(),
            contentRevisionID: revisionID,
            preserveSourceLocation: false
        )
        XCTAssertTrue(imported.isDeliveryArtifact)
        let recovery = try await store.createVersionSnapshot(
            for: imported,
            label: "Before edit",
            allowsDeliveryArtifact: true
        )
        XCTAssertTrue(recovery.matchesDeliveryReceipt(receipt))
        XCTAssertFalse(recovery.isPinnedMilestone)

        var stale = imported
        stale.contentRevisionID = UUID()
        stale.contentFingerprint = String(repeating: "f", count: 64)
        XCTAssertFalse(stale.hasCurrentDeliveryReceipt)
        let protected = try await store
            .protectDeliveryReceiptMilestone(
                for: stale,
                label: "Protect verified version",
                milestoneName: "Verified output"
            )

        XCTAssertEqual(protected.id, recovery.id)
        XCTAssertTrue(protected.isPinnedMilestone)
        XCTAssertEqual(
            protected.linkedDeliveryReceiptID,
            receipt.id
        )
        XCTAssertTrue(protected.matchesDeliveryReceipt(receipt))

        let repeated = try await store
            .protectDeliveryReceiptMilestone(
                for: stale,
                label: "Protect verified version",
                milestoneName: "Verified output"
            )
        XCTAssertEqual(repeated.id, protected.id)
        let retainedVersions = try await store.versions(
            for: imported.id
        )
        XCTAssertEqual(
            retainedVersions.count,
            1
        )

        receipt.outputRevisionID = UUID()
        XCTAssertFalse(protected.matchesDeliveryReceipt(receipt))
        receipt.outputRevisionID = nil
        XCTAssertTrue(protected.matchesDeliveryReceipt(receipt))
    }

    func testBulkUnpin_persistsOfficeAndVersionState_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("BulkUnpinStore")
        let store = DocumentStore(rootURL: root)
        var pinnedRecordIDs: [UUID] = []

        for index in 0..<2 {
            let source = temporaryDirectory
                .appendingPathComponent("bulk-unpin-\(index).pdf")
            try PDFTestFixtureFactory.makeTextPDF(
                at: source,
                pageCount: index + 1
            )
            let record = try await store.importPDF(
                from: source,
                preserveSourceLocation: false
            )
            let officeURL = temporaryDirectory
                .appendingPathComponent("bulk-unpin-\(index).docx")
            let officeData = Data("office-\(index)".utf8)
            try officeData.write(to: officeURL)
            let receipt = PDFOfficeExportReceipt(
                format: .wordDocument,
                fileName: officeURL.lastPathComponent,
                fileSizeBytes: Int64(officeData.count),
                plan: PDFOfficeExportFormatPlan.plan(
                    for: .wordDocument,
                    profile: record.profile
                ),
                budgetPlan: PDFOfficeVisualBudgetPlan(
                    profile: record.profile
                )
            )
            let retained = try await store.retainOfficeExport(
                receipt,
                sourceURL: officeURL,
                for: record
            )
            let pinned = try await store.setOfficeExportPinned(
                receiptID: retained.receipt.id,
                pinned: true,
                for: retained.record
            )
            XCTAssertTrue(
                pinned.officeReceipts.contains(where: \.isPinned)
            )
            pinnedRecordIDs.append(record.id)

            let snapshot = try await store.createVersionSnapshot(
                for: pinned,
                label: "Pinned \(index)"
            )
            let versions = try await store.updateVersionMilestone(
                snapshotID: snapshot.id,
                recordID: record.id,
                name: "Milestone \(index)",
                pinned: true,
                linkedDeliveryReceiptID: nil
            )
            XCTAssertTrue(
                versions.contains {
                    $0.id == snapshot.id && $0.isPinnedMilestone
                }
            )
        }

        let updated = try await store.unpinAllOfficeExports()
        XCTAssertEqual(Set(updated.map(\.id)), Set(pinnedRecordIDs))
        XCTAssertTrue(
            updated.allSatisfy {
                $0.officeReceipts.allSatisfy { !$0.isPinned }
            }
        )
        let persistedRecords = try await store.load()
        XCTAssertTrue(
            persistedRecords.allSatisfy {
                $0.officeReceipts.allSatisfy { !$0.isPinned }
            }
        )

        let unpinnedVersionCount =
            try await store.unpinAllVersionMilestones()
        XCTAssertEqual(unpinnedVersionCount, 2)
        let pinnedVersions =
            try await store.pinnedVersionMilestones()
        XCTAssertTrue(pinnedVersions.isEmpty)
    }

    @MainActor
    func testMetadataSync_clearRemovesCloudAndShadowPayloads_BitsUT()
        async throws {
        let cloud = CriticalMetadataKeyValueStore(
            isCloudBacked: true
        )
        let shadow = CriticalMetadataKeyValueStore(
            isCloudBacked: false
        )
        let service = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadow,
            now: { Date(timeIntervalSince1970: 100) }
        )
        _ = try await service.synchronize(records: [])
        XCTAssertFalse(cloud.storage.isEmpty)
        XCTAssertFalse(shadow.storage.isEmpty)

        try service.clearSyncedMetadata()

        XCTAssertTrue(cloud.storage.isEmpty)
        XCTAssertTrue(shadow.storage.isEmpty)
    }

    @MainActor
    func testModel_concurrentOutputsAllowOnlyOneDocumentFlow_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("concurrent-output-source.pdf")
        try PDFTestFixtureFactory.makeTrailingPaddedPDF(
            at: source,
            paddingBytes: 1_024 * 1_024,
            pageCount: 6
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ConcurrentOutputStore")
        )
        let imported = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let previousSync = UserDefaults.standard.object(
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        defer {
            if let previousSync {
                UserDefaults.standard.set(
                    previousSync,
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            }
        }
        let model = PaperPathModel(store: store)
        await model.bootstrap()

        async let first = model.createCompressedCopy(
            recordID: imported.id,
            quality: .compact,
            expectedContentRevisionID:
                imported.contentRevisionID,
            presentsFeedback: false
        )
        async let second = model.createCompressedCopy(
            recordID: imported.id,
            quality: .compact,
            expectedContentRevisionID:
                imported.contentRevisionID,
            presentsFeedback: false
        )
        let results = await (first, second)
        let created = [results.0, results.1].compactMap { $0 }

        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.id, imported.id)
        XCTAssertEqual(model.documents.map(\.id), [imported.id])
        XCTAssertNotEqual(model.record(id: imported.id)?.contentRevisionID, imported.contentRevisionID)
        let versions = try await store.versions(for: imported.id)
        XCTAssertEqual(versions.count, 1, "Only one operation may save a new version")
        XCTAssertEqual(versions.first?.contentRevisionID, imported.contentRevisionID)
        XCTAssertFalse(model.isProcessing(imported.id))
    }

    @MainActor
    func testModel_concurrentImageImportsKeepOperationOwnership_BitsUT()
        async throws {
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ConcurrentImageImportStore")
        )
        let previousSync = UserDefaults.standard.object(
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        defer {
            if let previousSync {
                UserDefaults.standard.set(
                    previousSync,
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            }
        }
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let image = makeTestImage(
            size: CGSize(width: 640, height: 480)
        )
        let pages = (0..<8).map { _ in
            ScanPageImage(image: image)
        }
        let scanProgressID = UUID()
        let imageProgressID = UUID()

        let scanTask = Task { @MainActor in
            await model.importScan(
                pages: pages,
                progressID: scanProgressID
            )
        }
        for _ in 0..<100
        where model.scanImportFraction(for: scanProgressID) == nil {
            await Task.yield()
        }
        XCTAssertNotNil(
            model.scanImportFraction(for: scanProgressID)
        )

        let imageTask = Task { @MainActor in
            await model.importImages(
                pages: pages,
                progressID: imageProgressID
            )
        }
        let records = await (scanTask.value, imageTask.value)

        XCTAssertNotNil(records.0)
        XCTAssertNotNil(records.1)
        XCTAssertNotEqual(records.0?.id, records.1?.id)
        XCTAssertEqual(model.documents.count, 2)
        XCTAssertNil(model.scanImportFraction(for: scanProgressID))
        XCTAssertNil(model.scanImportFraction(for: imageProgressID))
        XCTAssertFalse(model.hasActiveLocalDataOperations)
    }

    @MainActor
    func testModel_concurrentBootstrapYieldsAndLoadsOnce_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("concurrent-bootstrap-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 8
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ConcurrentBootstrapStore")
        )
        let imported = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let previousSync = UserDefaults.standard.object(
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        defer {
            if let previousSync {
                UserDefaults.standard.set(
                    previousSync,
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            }
        }
        let model = PaperPathModel(store: store)
        let heartbeat = expectation(
            description: "Main actor remains responsive"
        )
        Task { @MainActor in
            await Task.yield()
            heartbeat.fulfill()
        }

        async let firstBootstrap: Void = model.bootstrap()
        async let secondBootstrap: Void = model.bootstrap()
        await fulfillment(of: [heartbeat], timeout: 2)
        _ = await (firstBootstrap, secondBootstrap)

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.documents.map(\.id), [imported.id])
        XCTAssertFalse(model.hasActiveLocalDataOperations)
    }

    @MainActor
    func testModel_cancelledCompressionReleasesProcessingState_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("cancelled-compression-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 80
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("CancelledCompressionStore")
        )
        let imported = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let previousSync = UserDefaults.standard.object(
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        defer {
            if let previousSync {
                UserDefaults.standard.set(
                    previousSync,
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: AppPreferences.metadataSyncEnabledKey
                )
            }
        }
        let model = PaperPathModel(store: store)
        await model.bootstrap()

        let operation = Task { @MainActor in
            await model.createCompressedCopy(
                recordID: imported.id,
                quality: .compact,
                expectedContentRevisionID:
                    imported.contentRevisionID,
                presentsFeedback: false
            )
        }
        for _ in 0..<100 where !model.isProcessing(imported.id) {
            await Task.yield()
        }
        operation.cancel()
        _ = await operation.value
        for _ in 0..<100 where model.isProcessing(imported.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isProcessing(imported.id))
        XCTAssertFalse(model.hasActiveLocalDataOperations)
    }

    func testOfficeBatchArchive_roundTripsAndRejectsUnsafeNames_BitsUT()
        throws {
        let first = temporaryDirectory
            .appendingPathComponent("first.docx")
        let second = temporaryDirectory
            .appendingPathComponent("second.xlsx")
        let firstData = Data("first-office-output".utf8)
        let secondData = Data("second-office-output".utf8)
        try firstData.write(to: first)
        try secondData.write(to: second)
        let destination = temporaryDirectory
            .appendingPathComponent("office-batch.zip")
        let service = OfficeBatchArchiveService()

        try service.createArchive(
            sources: [
                OfficeBatchArchiveSource(
                    sourceURL: second,
                    archiveName: "02-second.xlsx"
                ),
                OfficeBatchArchiveSource(
                    sourceURL: first,
                    archiveName: "01-first.docx"
                )
            ],
            destination: destination
        )

        let archive = try StoredZIPArchiveFixture(
            data: Data(contentsOf: destination)
        )
        XCTAssertEqual(archive.localEntryCount, 2)
        XCTAssertEqual(archive.centralEntryCount, 2)
        XCTAssertEqual(archive.entries["01-first.docx"], firstData)
        XCTAssertEqual(archive.entries["02-second.xlsx"], secondData)

        for invalidSources in [
            [
                OfficeBatchArchiveSource(
                    sourceURL: first,
                    archiveName: "duplicate.docx"
                ),
                OfficeBatchArchiveSource(
                    sourceURL: second,
                    archiveName: "duplicate.docx"
                )
            ],
            [
                OfficeBatchArchiveSource(
                    sourceURL: first,
                    archiveName: "../outside.docx"
                )
            ]
        ] {
            let invalidDestination = temporaryDirectory
                .appendingPathComponent(
                    "invalid-\(UUID().uuidString).zip"
                )
            XCTAssertThrowsError(
                try service.createArchive(
                    sources: invalidSources,
                    destination: invalidDestination
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: invalidDestination.path
                )
            )
        }
    }

    func testOfficeDeliverySigning_verifiesOriginalAndRejectsTampering_BitsUT()
        async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("SigningStore"),
            signingPrivateKeyProvider: { signingKey }
        )
        let createdAt = PDFOfficeTimeAnchor.process.trustedDate()
        let payload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: UUID(),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3_600),
            verifiedOutputs: 1,
            files: [
                PDFOfficeDeliveryEntry(
                    sourceRecordID: UUID(),
                    sourceRevisionID: UUID(),
                    sourceName: "Quarterly report",
                    receiptID: UUID(),
                    format: .wordDocument,
                    archiveName: "report.docx",
                    byteCount: 128,
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
        let signed = try await store.signOfficeDeliveryPayload(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let signedURL = temporaryDirectory
            .appendingPathComponent("signed-report.json")
        try encoder.encode(signed).write(
            to: signedURL,
            options: .atomic
        )

        let verified = try await store.verifyOfficeDeliveryReport(
            at: signedURL
        )
        XCTAssertEqual(verified.status, .verified)
        XCTAssertEqual(verified.trustStatus, .thisDevice)
        XCTAssertEqual(verified.outputCount, 1)

        let identityURL = try await store
            .makeOfficeDeliverySigningIdentityCardFile()
        let identityCard = try await store
            .loadOfficeSignerIdentityCard(at: identityURL)
        let localSigningKeyID = try await store
            .officeDeliverySigningKeyID()
        XCTAssertEqual(identityCard.keyID, localSigningKeyID)

        let verifyingStore = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ForeignSigningStore"),
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        let unknownSigner = try await verifyingStore
            .verifyOfficeDeliveryReport(at: signedURL)
        XCTAssertEqual(unknownSigner.trustStatus, .unknown)
        var trustedSigners = try await verifyingStore
            .trustOfficeReportSigner(unknownSigner)
        XCTAssertEqual(trustedSigners.first?.keyID, identityCard.keyID)
        let trustedReport = try await verifyingStore
            .verifyOfficeDeliveryReport(at: signedURL)
        XCTAssertEqual(trustedReport.trustStatus, .trusted)
        XCTAssertEqual(trustedReport.trustedSignerName, trustedSigners.first?.displayName)
        trustedSigners = try await verifyingStore
            .removeOfficeTrustedSigner(identityCard.keyID)
        XCTAssertTrue(trustedSigners.isEmpty)
        trustedSigners = try await verifyingStore
            .trustOfficeSignerIdentity(identityCard)
        XCTAssertEqual(trustedSigners.first?.verificationCount, 0)

        let tamperedPayload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: payload.packageID,
            createdAt: payload.createdAt,
            expiresAt: payload.expiresAt,
            verifiedOutputs: 2,
            files: payload.files
        )
        let tampered = PDFOfficeSignedVerificationReport(
            payload: tamperedPayload,
            signature: signed.signature
        )
        let tamperedURL = temporaryDirectory
            .appendingPathComponent("tampered-report.json")
        try encoder.encode(tampered).write(
            to: tamperedURL,
            options: .atomic
        )

        let rejected = try await store.verifyOfficeDeliveryReport(
            at: tamperedURL
        )
        XCTAssertEqual(rejected.status, .invalid)
        XCTAssertEqual(rejected.trustStatus, .invalid)
    }

    func testDeliveryPackageVerification_materializesExactPDF_BitsUT()
        async throws {
        let package = try await makeSignedDeliveryPackage(
            name: "verified-received",
            tampersSignature: false
        )
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-VerifiedDelivery-\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: extractionDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: extractionDirectory)
        }

        let report = try PDFVersionArchiveVerificationService()
            .verifyDeliveryPackage(
                archiveURL: package.archiveURL,
                extractionDirectory: extractionDirectory
            )

        XCTAssertEqual(report.status, .verified)
        XCTAssertTrue(report.canOpenArtifact)
        XCTAssertEqual(
            report.verifiedArtifactURL?.lastPathComponent,
            package.artifactName
        )
        let extractedURL = try XCTUnwrap(
            report.verifiedArtifactURL
        )
        XCTAssertEqual(
            try Data(contentsOf: extractedURL),
            package.artifactData
        )

        let storeKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("VerifiedDeliveryStore"),
            signingPrivateKeyProvider: { storeKey }
        )
        let unknownTrust = try await store
            .resolveDeliveryPackageTrust(report)
        XCTAssertEqual(unknownTrust.trustStatus, .unknown)
        let trustedDeliverySigners = try await store
            .trustDeliveryPackageSigner(unknownTrust)
        XCTAssertEqual(
            trustedDeliverySigners.first?.keyID,
            report.signerKeyID
        )
        let trustedReport = try await store
            .resolveDeliveryPackageTrust(report)
        XCTAssertEqual(trustedReport.trustStatus, .trusted)
        let shareCopy = try await store
            .prepareVerifiedDeliveryArtifactShareCopy(report)
        XCTAssertEqual(
            try Data(contentsOf: shareCopy),
            package.artifactData
        )
        let imported = try await store
            .importVerifiedDeliveryArtifact(report)
        let importedAgain = try await store
            .importVerifiedDeliveryArtifact(report)
        XCTAssertEqual(importedAgain.id, imported.id)
        let importedURL = await store.url(for: imported)
        XCTAssertEqual(
            try Data(contentsOf: importedURL),
            package.artifactData
        )
    }

    func testDeliveryPackageVerification_removesPDFForInvalidSignature_BitsUT()
        async throws {
        let package = try await makeSignedDeliveryPackage(
            name: "tampered-signature",
            tampersSignature: true
        )
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.verifiedDeliveryPackagePrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: extractionDirectory
        )
        defer {
            try? FileManager.default.removeItem(
                at: extractionDirectory
            )
        }

        let report = try PDFVersionArchiveVerificationService()
            .verifyDeliveryPackage(
                archiveURL: package.archiveURL,
                extractionDirectory: extractionDirectory
            )

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.signatureStatus, .invalid)
        XCTAssertFalse(report.canOpenArtifact)
        XCTAssertNil(report.verifiedArtifactURL)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: extractionDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testOfficeExportRetention_verifiesCurrentArtifactAndTamper_BitsUT()
        async throws {
        let sourcePDF = temporaryDirectory
            .appendingPathComponent("retention-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: sourcePDF,
            pageCount: 1
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("RetentionStore")
        )
        let record = try await store.importPDF(
            from: sourcePDF,
            preserveSourceLocation: false
        )
        let officeURL = temporaryDirectory
            .appendingPathComponent("retained.docx")
        let officeData = Data("verified-office-artifact".utf8)
        try officeData.write(to: officeURL)
        let receipt = PDFOfficeExportReceipt(
            format: .wordDocument,
            fileName: officeURL.lastPathComponent,
            fileSizeBytes: Int64(officeData.count),
            plan: PDFOfficeExportFormatPlan.plan(
                for: .wordDocument,
                profile: record.profile
            ),
            budgetPlan: PDFOfficeVisualBudgetPlan(
                profile: record.profile
            )
        )

        let retained = try await store.retainOfficeExport(
            receipt,
            sourceURL: officeURL,
            for: record
        )
        let verified = try await store.verifyOfficeExport(
            receiptID: retained.receipt.id,
            for: retained.record
        )
        XCTAssertEqual(verified.status, .verified)
        XCTAssertEqual(verified.url, retained.url)

        let shareDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.officeSharePrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        let shareURL = shareDirectory.appendingPathComponent(
            retained.receipt.fileName
        )
        defer {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: shareDirectory,
                allowedPrefixes: [
                    PaperPathTemporaryArtifact.officeSharePrefix
                ]
            )
        }
        let preparedShare = try await store.prepareOfficeExportShareCopy(
            receiptID: retained.receipt.id,
            for: verified.record,
            destinationURL: shareURL
        )
        XCTAssertEqual(preparedShare.url, shareURL)
        XCTAssertEqual(
            try Data(contentsOf: preparedShare.url),
            officeData
        )

        try Data(repeating: 0x58, count: officeData.count).write(
            to: retained.url
        )
        let mismatch = try await store.verifyOfficeExport(
            receiptID: retained.receipt.id,
            for: verified.record
        )
        XCTAssertEqual(mismatch.status, .mismatch)
        XCTAssertNil(mismatch.url)
    }

    func testOfficeDeliveryRetention_retryPreservesPublishedPackage_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("DeliveryRetentionStore")
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: root,
            signingPrivateKeyProvider: { signingKey }
        )
        let archiveURL = temporaryDirectory
            .appendingPathComponent("delivery.zip")
        let reportURL = temporaryDirectory
            .appendingPathComponent("delivery-report.json")
        let archiveData = Data("verified-archive".utf8)
        try archiveData.write(to: archiveURL)
        let receiptID = UUID()
        var package = PDFOfficeDeliveryPackage(
            entries: [
                PDFOfficeDeliveryEntry(
                    sourceRecordID: UUID(),
                    sourceRevisionID: UUID(),
                    sourceName: "Verified report",
                    receiptID: receiptID,
                    format: .wordDocument,
                    archiveName: "verified-report.docx",
                    byteCount: Int64(archiveData.count),
                    sha256: sha256(archiveData)
                )
            ]
        )
        let signedReport = try await store.signOfficeDeliveryPayload(
            PDFOfficeVerificationPayload(
                schema: "PaperPath Office Delivery V34",
                packageID: package.id,
                createdAt: package.createdAt,
                expiresAt: package.expiresAt,
                verifiedOutputs: package.entries.count,
                files: package.entries
            )
        )
        package.signerKeyID = signedReport.signature.keyID
        let reportEncoder = JSONEncoder()
        reportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        reportEncoder.dateEncodingStrategy = .iso8601
        let reportData = try reportEncoder.encode(signedReport)
        try reportData.write(to: reportURL)

        let first = try await store.retainOfficeDeliveryPackage(
            package,
            archiveURL: archiveURL,
            reportURL: reportURL
        )
        XCTAssertTrue(first.0.isStructurallyValid)
        let initiallyPublished = try await store
            .officeDeliveryPackageURLs(for: first.0)
        XCTAssertEqual(
            try Data(contentsOf: initiallyPublished.archive),
            archiveData
        )
        XCTAssertEqual(
            try Data(contentsOf: initiallyPublished.report),
            reportData
        )
        do {
            _ = try await store.retainOfficeDeliveryPackage(
                package,
                archiveURL: archiveURL,
                reportURL: reportURL
            )
        } catch {
            // A retry may be rejected, but it must not remove the old package.
        }

        let published: (archive: URL, report: URL)
        do {
            published = try await store.officeDeliveryPackageURLs(
                for: first.0
            )
        } catch {
            return XCTFail(
                "Retry removed the published Office package: \(error)"
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: published.archive),
            archiveData
        )
        XCTAssertEqual(
            try Data(contentsOf: published.report),
            reportData
        )
        let loadedPackages = try await store
            .loadOfficeDeliveryPackages()
        XCTAssertEqual(loadedPackages.map(\.id), [package.id])
        let pinned = try await store.setOfficeDeliveryPackagePinned(
            package.id,
            pinned: true
        )
        XCTAssertNotNil(pinned.first?.pinnedAt)
        let unpinned = try await store.setOfficeDeliveryPackagePinned(
            package.id,
            pinned: false
        )
        XCTAssertNil(unpinned.first?.pinnedAt)
        let remainingPackages = try await store
            .deleteOfficeDeliveryPackage(package.id)
        XCTAssertTrue(remainingPackages.isEmpty)
    }

    func testRestoreVersion_sidecarCleanupFailureRollsBack_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("restore-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let root = temporaryDirectory
            .appendingPathComponent("RestoreStore")
        let fileManager = RemovalFailingFileManager()
        let store = DocumentStore(
            rootURL: root,
            fileManager: fileManager
        )
        let original = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let snapshot = try await store.createVersionSnapshot(
            for: original,
            label: "Before edit"
        )
        let privateURL = await store.url(for: original)
        try PDFMutationService().addStamp(
            .draft,
            toPageAt: 0,
            in: privateURL
        )
        var modified = try await store.refresh(original)
        let modifiedIndex = DocumentTextIndex(
            source: .native,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "Index for the modified working copy"
                )
            ],
            indexedAt: Date(timeIntervalSince1970: 200)
        )
        modified = try await store.saveAnalysis(
            modified,
            brief: DocumentUnderstandingService().analyze(
                index: modifiedIndex,
                profile: modified.profile
            ),
            textIndex: modifiedIndex
        )
        let modifiedData = try Data(contentsOf: privateURL)
        fileManager.deniedRemovalPathFragment = "TextIndex"

        var didFail = false
        do {
            _ = try await store.restoreVersion(
                snapshotID: snapshot.id,
                for: modified
            )
        } catch {
            didFail = true
        }

        guard didFail else {
            return XCTFail(
                "Restore must not report success when stale sidecars remain"
            )
        }
        XCTAssertEqual(try Data(contentsOf: privateURL), modifiedData)
        let indicesAfterFailure = try await store.loadTextIndices()
        XCTAssertEqual(
            indicesAfterFailure[original.id],
            modifiedIndex.bound(to: modified.contentRevisionID)
        )
    }

    func testRestoreVersion_checkpointCleanupFailurePreservesPages_BitsUT()
        async throws {
        for mode in CheckpointRemovalFailingFileManager.Mode.allCases {
            let source = temporaryDirectory
                .appendingPathComponent("checkpoint-\(mode).pdf")
            try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 2)
            let root = temporaryDirectory
                .appendingPathComponent("CheckpointStore-\(mode)")
            let fileManager = CheckpointRemovalFailingFileManager(mode: mode)
            let store = DocumentStore(rootURL: root, fileManager: fileManager)
            let original = try await store.importPDF(
                from: source,
                preserveSourceLocation: false
            )
            let snapshot = try await store.createVersionSnapshot(
                for: original, label: "Before edit"
            )
            let privateURL = await store.url(for: original)
            try PDFMutationService().addStamp(.draft, toPageAt: 0, in: privateURL)
            let modified = try await store.refresh(original)
            let identity = OCRCheckpointIdentity(
                recordID: modified.id,
                revisionID: modified.contentRevisionID,
                pageCount: 2,
                configuration: .automatic
            )
            _ = try await store.prepareOCRCheckpoint(identity)
            for index in 0..<2 {
                try await store.saveOCRCheckpointPage(
                    OCRPageResult(
                        pageIndex: index,
                        text: "Saved recognition page \(index + 1)",
                        confidence: 0.99,
                        blocks: []
                    ),
                    identity: identity
                )
            }
            let checkpointURL = root.appendingPathComponent(
                "OCR/\(modified.id.uuidString).resume"
            )
            let names = ["identity.json", "page-0.json", "page-1.json"]
            let savedBytes = try names.map {
                try Data(contentsOf: checkpointURL.appendingPathComponent($0))
            }
            let savedPDF = try Data(contentsOf: privateURL)
            let journal = root.appendingPathComponent(
                "active-working-copy-transaction.json"
            )
            fileManager.checkpointURL = checkpointURL

            do {
                _ = try await store.restoreVersion(
                    snapshotID: snapshot.id, for: modified
                )
                XCTFail("Cleanup failure must reject version restore: \(mode)")
            } catch {
                XCTAssertTrue(fileManager.didInjectFailure, "\(mode)")
            }
            XCTAssertEqual(try Data(contentsOf: privateURL), savedPDF, "\(mode)")
            if mode == .restoreCopyFailure || mode == .restoreProtectionFailure {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: journal.path),
                    "A failed rollback must retain its journal"
                )
                let backups = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasPrefix(".batch-sidecar-rollback-") }
                XCTAssertEqual(backups.count, 1)
                if let backup = backups.first {
                    for (name, data) in zip(names, savedBytes) {
                        XCTAssertEqual(
                            try Data(contentsOf: backup.appendingPathComponent(name)),
                            data
                        )
                    }
                }
            } else {
                for (name, data) in zip(names, savedBytes) {
                    XCTAssertEqual(
                        try? Data(contentsOf: checkpointURL.appendingPathComponent(name)),
                        data,
                        "\(mode): \(name)"
                    )
                }
            }

            let reopened = DocumentStore(rootURL: root)
            let records = try await reopened.load()
            XCTAssertEqual(
                records.first?.contentRevisionID,
                modified.contentRevisionID,
                "\(mode)"
            )
            let checkpoint = try await reopened.loadOCRCheckpoint(identity)
            XCTAssertEqual(checkpoint?.pages.map(\.pageIndex), [0, 1], "\(mode)")
            for (name, data) in zip(names, savedBytes) {
                XCTAssertEqual(
                    try? Data(contentsOf: checkpointURL.appendingPathComponent(name)),
                    data,
                    "\(mode): \(name) after reopening"
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(remaining.contains { $0.hasPrefix(".batch-sidecar-") })
        }
    }

    @MainActor
    func testMetadataSync_clearFailureIsObservable_BitsUT() async throws {
        let cloud = CriticalMetadataKeyValueStore(
            isCloudBacked: true
        )
        let shadow = CriticalMetadataKeyValueStore(
            isCloudBacked: false
        )
        let service = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadow
        )
        _ = try await service.synchronize(records: [])
        cloud.synchronizeResult = false

        XCTAssertThrowsError(
            try service.clearSyncedMetadata()
        ) { error in
            guard case PaperPathError.storageFailure = error else {
                return XCTFail(
                    "Unexpected metadata clear error: \(error)"
                )
            }
        }
    }

    func testMutation_replaceAndBatchCropAreAtomic_BitsUT() throws {
        let destination = temporaryDirectory
            .appendingPathComponent("mutation-destination.pdf")
        let replacement = temporaryDirectory
            .appendingPathComponent("mutation-replacement.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: destination,
            pageCount: 3
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: replacement,
            pageCount: 1
        )
        let service = PDFMutationService()

        try service.replacePage(
            at: 1,
            withPageAt: 0,
            from: replacement,
            in: destination
        )
        let replaced = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(replaced.pageCount, 3)
        XCTAssertTrue(
            replaced.page(at: 1)?.string?
                .contains("Fixture page 1") == true
        )

        let beforeInvalidCrop = try Data(contentsOf: destination)
        XCTAssertThrowsError(
            try service.cropPages(
                [
                    0: PDFPageCropInsets(
                        top: 0.05,
                        right: 0.05,
                        bottom: 0.05,
                        left: 0.05
                    ),
                    99: .none
                ],
                in: destination
            )
        ) { error in
            guard case PaperPathError.invalidPage = error else {
                return XCTFail(
                    "Unexpected batch crop error: \(error)"
                )
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: destination),
            beforeInvalidCrop
        )
    }

    func testWorkingCopyTransaction_recoversAfterRollbackFailure_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("WorkingCopyRecoveryStore")
        let source = temporaryDirectory
            .appendingPathComponent("recovery-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let fileManager = ProtectionFailingFileManager()
        let store = DocumentStore(
            rootURL: root,
            fileManager: fileManager
        )
        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let workingCopyURL = await store.url(for: record)
        let originalData = try Data(contentsOf: workingCopyURL)
        let preparedURL = temporaryDirectory
            .appendingPathComponent("recovery-prepared.pdf")
        try FileManager.default.copyItem(
            at: workingCopyURL,
            to: preparedURL
        )
        try PDFMutationService().addStamp(
            .draft,
            toPageAt: 0,
            in: preparedURL
        )
        XCTAssertNotEqual(
            try Data(contentsOf: preparedURL),
            originalData
        )

        fileManager.deniedPathFragment = workingCopyURL.path
        do {
            _ = try await store.replaceWorkingCopies(
                with: [
                    PreparedPDFWorkingCopy(
                        recordID: record.id,
                        sourceRevisionID: record.contentRevisionID,
                        preparedURL: preparedURL
                    )
                ],
                invalidateAnalysis: true,
                requiresMatchingPageCount: true
            )
            XCTFail("A denied publication must fail")
        } catch {
            // The recovery journal must remain available after rollback fails.
        }
        fileManager.deniedPathFragment = nil

        let journalURL = root.appendingPathComponent(
            "active-working-copy-transaction.json"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: journalURL.path)
        )

        let recoveredStore = DocumentStore(
            rootURL: root,
            fileManager: fileManager
        )
        let recoveredRecords = try await recoveredStore.load()
        let recoveredRecord = try XCTUnwrap(recoveredRecords.first)
        let recoveredURL = await recoveredStore.url(
            for: recoveredRecord
        )
        let recoveredData = try Data(contentsOf: recoveredURL)
        XCTAssertEqual(
            recoveredRecord.contentRevisionID,
            record.contentRevisionID
        )
        XCTAssertEqual(recoveredData, originalData)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalURL.path)
        )
        let documentEntries = try FileManager.default
            .contentsOfDirectory(
                at: root.appendingPathComponent(
                    "Documents",
                    isDirectory: true
                ),
                includingPropertiesForKeys: nil
            )
        XCTAssertFalse(
            documentEntries.contains {
                $0.lastPathComponent.hasPrefix(".batch-")
                    || $0.lastPathComponent.hasPrefix(
                        ".batch-rollback-"
                    )
            }
        )
    }

    func testSignatureStore_unknownSelectionAndRemovalAreIdempotent_BitsUT()
        async throws {
        let store = SignatureStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("IdempotentSignatureStore")
        )
        let signature = PDFTestFixtureFactory.makeSignaturePNG(seed: 3)
        let initial = try await store.add(signature)
        let selected = try await store.select(UUID())
        let removed = try await store.remove(id: UUID())

        XCTAssertEqual(selected.entries, initial.entries)
        XCTAssertEqual(selected.selectedID, initial.selectedID)
        XCTAssertEqual(removed.entries, initial.entries)
        XCTAssertEqual(removed.selectedID, initial.selectedID)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, signature)
    }

    func testExternalPDFInbox_roundTripsNameAndLifecycle_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory
            .appendingPathComponent("InboxLifecycle")
        let source = temporaryDirectory
            .appendingPathComponent("shared-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let item = try ExternalPDFInbox.stagePDF(
            from: source,
            suggestedName: "  Quarterly Review.pdf  ",
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )

        var pending = try ExternalPDFInbox.pendingItems(
            sharedContainerURL: sharedContainer
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.preferredName, "Quarterly Review")
        XCTAssertEqual(
            try Data(contentsOf: item.fileURL),
            try Data(contentsOf: source)
        )

        try ExternalPDFInbox.remove(
            item,
            sharedContainerURL: sharedContainer
        )
        pending = try ExternalPDFInbox.pendingItems(
            sharedContainerURL: sharedContainer
        )
        XCTAssertTrue(pending.isEmpty)

        _ = try ExternalPDFInbox.stagePDF(
            from: source,
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )
        try ExternalPDFInbox.removeAll(
            sharedContainerURL: sharedContainer
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sharedContainer
                    .appendingPathComponent("SharedImports")
                    .path
            )
        )
    }

    func testExternalPDFInbox_rejectsSymlinkAndOversizedPayloads_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory
            .appendingPathComponent("InboxBoundaryContainer")
        let source = temporaryDirectory
            .appendingPathComponent("inbox-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let symlink = temporaryDirectory
            .appendingPathComponent("inbox-source-link.pdf")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: source
        )

        XCTAssertThrowsError(
            try ExternalPDFInbox.stagePDF(
                from: symlink,
                sharedContainerURL: sharedContainer,
                protectionHandler: { _ in }
            )
        ) { error in
            guard case ExternalPDFInboxError.invalidPDF = error else {
                return XCTFail("Unexpected symlink error: \(error)")
            }
        }

        let oversized = temporaryDirectory
            .appendingPathComponent("oversized-inbox.pdf")
        try PDFTestFixtureFactory.makeSparsePDF(
            at: oversized,
            paddingBytes: Int64(1_024 * 1_024 * 1_024)
        )
        XCTAssertThrowsError(
            try ExternalPDFInbox.stagePDF(
                from: oversized,
                sharedContainerURL: sharedContainer,
                protectionHandler: { _ in }
            )
        ) { error in
            guard case ExternalPDFInboxError.fileTooLarge = error else {
                return XCTFail("Unexpected size error: \(error)")
            }
        }
        XCTAssertTrue(
            try ExternalPDFInbox.pendingItems(
                sharedContainerURL: sharedContainer
            ).isEmpty
        )
    }

    func testExternalPDFInbox_boundsMetadataBeforeDecoding_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory
            .appendingPathComponent("InboxMetadataContainer")
        let source = temporaryDirectory
            .appendingPathComponent("metadata-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let item = try ExternalPDFInbox.stagePDF(
            from: source,
            suggestedName: "Sensitive contract.pdf",
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )
        try Data(
            repeating: 0x41,
            count: 64 * 1_024 + 1
        ).write(
            to: item.containerURL
                .appendingPathComponent("metadata.json"),
            options: .atomic
        )

        let snapshot = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: sharedContainer
        )
        XCTAssertTrue(
            snapshot.deferredItems.isEmpty,
            snapshot.deferredItems.map {
                "\($0.containerURL.lastPathComponent): \($0.reason)"
            }.joined(separator: "\n")
        )
        let pending = snapshot.items
        let sourceData = try Data(contentsOf: source)
        let expectedFingerprint = SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined()
        let pendingItem = try XCTUnwrap(
            pending.first,
            "Oversized metadata should be repaired without discarding its PDF"
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pendingItem.preferredName, "Shared PDF")
        XCTAssertEqual(pendingItem.fileURL, item.fileURL)
        XCTAssertEqual(pendingItem.byteCount, Int64(sourceData.count))
        XCTAssertEqual(
            pendingItem.expectedSHA256,
            expectedFingerprint
        )
        XCTAssertEqual(
            try Data(contentsOf: pendingItem.fileURL),
            sourceData
        )

        let repairedMetadata = try Data(
            contentsOf: item.containerURL
                .appendingPathComponent("metadata.json")
        )
        XCTAssertLessThanOrEqual(repairedMetadata.count, 64 * 1_024)
        let reparsed = try ExternalPDFInbox.pendingItems(
            sharedContainerURL: sharedContainer
        )
        let reparsedItem = try XCTUnwrap(
            reparsed.first,
            "Repaired metadata should remain readable"
        )
        XCTAssertEqual(reparsed.count, 1)
        XCTAssertEqual(
            reparsedItem.expectedSHA256,
            expectedFingerprint
        )
    }

    func testOfficeFormatPlan_limitsLockedAndOversizedSources_BitsUT() {
        var oversized = makeProfile(pageCount: 1_201)
        oversized.byteCount = 320 * 1_024 * 1_024
        for format in [
            PDFTextExportFormat.wordDocument,
            .excelWorkbook,
            .powerPointPresentation
        ] {
            let plan = PDFOfficeExportFormatPlan.plan(
                for: format,
                profile: oversized
            )
            XCTAssertEqual(plan.readiness, .limited)
            XCTAssertTrue(
                plan.riskEvidence.contains(
                    format.fileExtension.uppercased()
                )
            )
        }

        var locked = makeProfile(pageCount: 2)
        locked.isEncrypted = true
        locked.isLocked = true
        locked.allowsCopying = false
        let lockedPlan = PDFOfficeExportFormatPlan.plan(
            for: .wordDocument,
            profile: locked
        )
        XCTAssertEqual(lockedPlan.readiness, .limited)
        XCTAssertTrue(
            lockedPlan.riskEvidence.contains(
                "Locked source".localizedUI
            )
        )
    }

    func testWatermarkDiagonalAppearanceSurvivesLanguageChangesAndEditing() throws {
        let url = temporaryDirectory.appendingPathComponent("watermark-angle.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.pdfData { $0.beginPage() }.write(to: url)
        let service = PDFMutationService()

        func checkAppearance(diagonal: Bool) throws {
            let document = try XCTUnwrap(PDFDocument(url: url))
            let page = try XCTUnwrap(document.page(at: 0))
            defer { withExtendedLifetime(document) {} }
            XCTAssertEqual(page.annotations.count, 1)
            XCTAssertTrue(try XCTUnwrap(page.annotations.first).hasAppearanceStream)
            let image = page.thumbnail(of: CGSize(width: 612, height: 792), for: .cropBox)
            let attachment = XCTAttachment(image: image)
            attachment.name = "watermark-\(page.annotations.first?.contents ?? "")-\(diagonal)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let cgImage = try XCTUnwrap(image.cgImage)
            let width = cgImage.width, height = cgImage.height
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var points: [(Double, Double)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if Int(pixels[i]) - Int(pixels[i + 1]) > 20 {
                        points.append((Double(x), Double(y)))
                    }
                }
            }
            XCTAssertGreaterThan(points.count, 100, "Watermark must be visible")
            guard !points.isEmpty else { return }
            let count = Double(points.count)
            let meanX = points.reduce(0) { $0 + $1.0 } / count
            let meanY = points.reduce(0) { $0 + $1.1 } / count
            let xx = points.reduce(0) { $0 + pow($1.0 - meanX, 2) }
            let yy = points.reduce(0) { $0 + pow($1.1 - meanY, 2) }
            let xy = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            if diagonal {
                // Bitmap rows run downward: a negative slope rises to the right.
                XCTAssertLessThan(xy / sqrt(xx * yy), -0.8, "Saved text must rise from bottom left to top right")
                XCTAssertEqual(xx / yy, 1, accuracy: 0.25)
            } else {
                XCTAssertGreaterThan(xx / yy, 4, "Centered text must stay horizontal")
            }
        }

        for text in ["CUSTOM WATERMARK", "自定义中文水印", "ENGLISH AGAIN"] {
            try service.applyWatermark(.init(pageIndices: [0], text: text, layout: .diagonal,
                tone: .red, intensity: .standard), in: url)
            try checkAppearance(diagonal: true)
        }
        for text in ["再次编辑中文水印", "EDITED ENGLISH"] {
            let watermark = try XCTUnwrap(service.annotations(in: url).first)
            try service.editAnnotation(.init(pageIndex: 0, annotationIndex: 0, expectedType: "FreeText",
                contents: text, color: watermark.color,
                lineWidth: nil), in: url)
            try checkAppearance(diagonal: true)
        }
        try service.applyWatermark(.init(pageIndices: [0], text: "中文居中 WATERMARK", layout: .centered,
            tone: .red, intensity: .standard), in: url)
        try checkAppearance(diagonal: false)
        XCTAssertEqual(try service.removeGeneratedWatermarks(in: url), 1)
    }

    func testGeneratedPageMarks_roundTripAndRemoveIndependently_BitsUT()
        throws {
        let url = temporaryDirectory
            .appendingPathComponent("generated-page-marks.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: url, pageCount: 3)
        let source = try XCTUnwrap(PDFDocument(url: url))
        let firstPage = try XCTUnwrap(source.page(at: 0))
        let reviewerNote = PDFAnnotation(
            bounds: CGRect(x: 72, y: 500, width: 180, height: 44),
            forType: .freeText,
            withProperties: nil
        )
        reviewerNote.contents = "Keep this reviewer note"
        reviewerNote.userName = "Reviewer"
        firstPage.addAnnotation(reviewerNote)
        XCTAssertTrue(source.write(to: url))

        let service = PDFMutationService()
        try service.applyPageNumbers(
            PDFPageNumberingPayload(
                pageIndices: [2, 0, 2],
                startNumber: 7,
                format: .pageOfTotal,
                position: .bottomCenter
            ),
            in: url
        )
        try service.applyWatermark(
            PDFWatermarkPayload(
                pageIndices: [0, 2],
                text: "CONFIDENTIAL",
                layout: .diagonal,
                tone: .red,
                intensity: .standard
            ),
            in: url
        )
        try service.applyBatesNumbers(
            PDFBatesNumberingPayload(
                pageIndices: [0, 2],
                startNumber: 98,
                digitCount: 4,
                prefix: "CASE-",
                suffix: "-A",
                position: .topRight
            ),
            in: url
        )

        var annotations = try service.annotations(in: url)
        let pageNumbers = annotations.filter {
            $0.generatedKind == .pageNumber
        }
        let watermarks = annotations.filter {
            $0.generatedKind == .watermark
        }
        let bates = annotations.filter {
            $0.generatedKind == .batesNumber
        }
        XCTAssertEqual(
            pageNumbers.map(\.contents),
            [
                PDFPageNumberFormat.pageOfTotal.text(
                    number: 7,
                    total: 8
                ),
                PDFPageNumberFormat.pageOfTotal.text(
                    number: 8,
                    total: 8
                )
            ]
        )
        XCTAssertEqual(watermarks.count, 2)
        XCTAssertEqual(
            bates.map(\.contents),
            ["CASE-0098-A", "CASE-0099-A"]
        )
        XCTAssertTrue(
            annotations.contains {
                $0.contents == "Keep this reviewer note"
                    && $0.generatedKind == nil
            }
        )

        XCTAssertEqual(
            try service.removeGeneratedPageNumbers(in: url),
            2
        )
        XCTAssertEqual(
            try service.removeGeneratedWatermarks(in: url),
            2
        )
        XCTAssertEqual(
            try service.removeGeneratedBatesNumbers(in: url),
            2
        )
        annotations = try service.annotations(in: url)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(
            annotations.first?.contents,
            "Keep this reviewer note"
        )
    }

    func testPageDuplicationRotationAndBlankInsertionPreserveOrder_BitsUT()
        throws {
        let url = temporaryDirectory
            .appendingPathComponent("page-workbench.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: url, pageCount: 3)
        let service = PDFMutationService()

        try service.rotatePages(
            at: [0, 2],
            direction: .counterclockwise,
            in: url
        )
        try service.duplicatePages(at: [0, 2], in: url)
        var document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 5)
        XCTAssertEqual(
            (0..<document.pageCount).map {
                document.page(at: $0)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            },
            [
                "Fixture page 1 amount 0",
                "Fixture page 1 amount 0",
                "Fixture page 2 amount 10",
                "Fixture page 3 amount 20",
                "Fixture page 3 amount 20"
            ]
        )
        XCTAssertEqual(document.page(at: 0)?.rotation, 270)
        XCTAssertEqual(document.page(at: 1)?.rotation, 270)
        XCTAssertEqual(document.page(at: 3)?.rotation, 270)
        XCTAssertEqual(document.page(at: 4)?.rotation, 270)

        try service.insertBlankPage(at: 0, in: url)
        document = try XCTUnwrap(PDFDocument(url: url))
        let blank = try XCTUnwrap(document.page(at: 0))
        let reference = try XCTUnwrap(document.page(at: 1))
        XCTAssertEqual(document.pageCount, 6)
        XCTAssertEqual(blank.rotation, reference.rotation)
        XCTAssertEqual(
            blank.bounds(for: .mediaBox),
            reference.bounds(for: .mediaBox)
        )
        XCTAssertEqual(
            blank.bounds(for: .cropBox),
            reference.bounds(for: .cropBox)
        )
    }

    func testAnnotationInventoryAndBatchRemovalFailClosed_BitsUT()
        throws {
        let url = temporaryDirectory
            .appendingPathComponent("annotation-inventory.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: url, pageCount: 1)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        for index in 0..<4 {
            let annotation = PDFAnnotation(
                bounds: CGRect(
                    x: 40,
                    y: 500 - CGFloat(index * 50),
                    width: 180,
                    height: 36
                ),
                forType: .freeText,
                withProperties: nil
            )
            annotation.contents = "Review \(index)"
            page.addAnnotation(annotation)
        }
        XCTAssertTrue(document.write(to: url))

        let service = PDFMutationService()
        XCTAssertEqual(
            try service.annotations(in: url, limit: 2).count,
            2
        )
        let inventory = try service.annotations(in: url)
        let targets = [inventory[0], inventory[3]].map(
            PDFAnnotationRemovalTarget.init(annotation:)
        )
        XCTAssertEqual(
            try service.removeAnnotations(targets, in: url),
            2
        )
        XCTAssertEqual(
            try service.annotations(in: url).map(\.contents),
            ["Review 1", "Review 2"]
        )

        let beforeStaleRemoval = try Data(contentsOf: url)
        XCTAssertThrowsError(
            try service.removeAnnotations(targets, in: url)
        )
        XCTAssertEqual(
            try Data(contentsOf: url),
            beforeStaleRemoval
        )
    }

    func testBatesFormattingPlanAndReceiptContracts_BitsUT() throws {
        XCTAssertEqual(
            PDFBatesNumberingPayload.maximumNumber(digitCount: 3),
            999
        )
        XCTAssertEqual(
            PDFBatesNumberingPayload.text(
                number: 42,
                digitCount: 6,
                prefix: "A-",
                suffix: "-Z"
            ),
            "A-000042-Z"
        )
        XCTAssertEqual(
            try PDFBatesNumberingPayload.normalizedAffix(
                "  CASE  ",
                name: "prefix"
            ),
            "CASE"
        )
        XCTAssertThrowsError(
            try PDFBatesNumberingPayload.normalizedAffix(
                "BAD#",
                name: "prefix"
            )
        )

        let first = makeRecord(name: "Volume A", pageCount: 2)
        let second = makeRecord(name: "Volume B", pageCount: 3)
        let plan = try PDFBatesBatchPlan(
            records: [first, second],
            startNumber: 998,
            digitCount: 4,
            prefix: "CASE-",
            suffix: "",
            position: .bottomRight
        )
        XCTAssertEqual(plan.totalPageCount, 5)
        XCTAssertEqual(plan.firstIdentifier, "CASE-0998")
        XCTAssertEqual(plan.lastIdentifier, "CASE-1002")
        XCTAssertEqual(
            plan.payload(for: plan.items[1]).startNumber,
            1_000
        )
        XCTAssertThrowsError(
            try PDFBatesBatchPlan(
                records: [first],
                startNumber: 1,
                digitCount: 6,
                prefix: "",
                suffix: "",
                position: .bottomRight
            )
        )
        XCTAssertThrowsError(
            try PDFBatesBatchPlan(
                records: [first, second],
                startNumber: 998,
                digitCount: 3,
                prefix: "",
                suffix: "",
                position: .bottomRight
            )
        )

        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "b", count: 64)
        let entries = [
            makeBatesEntry(
                record: first,
                outputRevisionID: UUID(),
                start: 998,
                end: 999,
                sourceHash: hashA,
                outputHash: hashB
            ),
            makeBatesEntry(
                record: second,
                outputRevisionID: UUID(),
                start: 1_000,
                end: 1_002,
                sourceHash: hashB,
                outputHash: hashA
            )
        ]
        let payload = PDFBatesBatchReceiptPayload(
            schema: PDFBatesBatchReceiptPayload.schema,
            batchID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            digitCount: 4,
            prefix: "CASE-",
            suffix: "",
            position: .bottomRight,
            totalPageCount: 5,
            firstIdentifier: "CASE-0998",
            lastIdentifier: "CASE-1002",
            entries: entries
        )
        XCTAssertTrue(payload.isStructurallyValid)
        let removal = PDFBatesRemovalReceiptPayload(
            schema: PDFBatesRemovalReceiptPayload.schema,
            removalID: UUID(),
            batesBatchID: payload.batchID,
            createdAt: Date(timeIntervalSince1970: 200),
            totalPageCount: 5,
            entries: zip(entries, [hashA, hashB]).map { pair in
                let entry = pair.0
                let clearedHash = pair.1
                return PDFBatesRemovalReceiptEntry(
                    recordID: entry.recordID,
                    displayName: entry.displayName,
                    pageCount: entry.pageCount,
                    numberedRevisionID: entry.outputRevisionID,
                    clearedRevisionID: UUID(),
                    numberedSHA256: entry.outputSHA256,
                    clearedSHA256: clearedHash
                )
            }
        )
        XCTAssertTrue(removal.isStructurallyValid)
        XCTAssertTrue(removal.isLinked(to: payload))
    }

    func testBatesProgressModelsClampInvalidInput_BitsUT() {
        XCTAssertEqual(
            PDFBatesBatchProgress(
                stage: .preparing,
                completedDocumentCount: 0,
                totalDocumentCount: 2,
                completedPageCount: -20,
                totalPageCount: 10,
                currentDocumentName: "A"
            ).fractionCompleted,
            0
        )
        XCTAssertEqual(
            PDFBatesBatchProgress(
                stage: .committing,
                completedDocumentCount: 20,
                totalDocumentCount: 2,
                completedPageCount: 10,
                totalPageCount: 10,
                currentDocumentName: "A"
            ).fractionCompleted,
            1
        )
        XCTAssertEqual(
            PDFBatesExternalMatchProgress(
                receiptID: UUID(),
                completedFileCount: 0,
                totalFileCount: 1,
                processedBytes: -1,
                totalBytes: 10,
                currentFileName: "A.pdf"
            ).fractionCompleted,
            0
        )
        XCTAssertEqual(
            PDFBatesBatchReceiptVerificationProgress(
                receiptID: UUID(),
                completedDocumentCount: -1,
                totalDocumentCount: 2,
                currentDocumentName: "A"
            ).fractionCompleted,
            0
        )
    }

    func testScanCropGeometryAndProcessingOptionsAreBounded_BitsUT() {
        XCTAssertEqual(ScanCropPoint(x: -2, y: 3).x, 0)
        XCTAssertEqual(ScanCropPoint(x: -2, y: 3).y, 1)

        let quad = ScanCropQuad(
            topLeft: ScanCropPoint(x: 0.1, y: 0.2),
            topRight: ScanCropPoint(x: 0.9, y: 0.1),
            bottomRight: ScanCropPoint(x: 0.8, y: 0.9),
            bottomLeft: ScanCropPoint(x: 0.2, y: 0.8)
        )
        XCTAssertTrue(quad.isValid)
        XCTAssertFalse(quad.isEffectivelyFullFrame)
        let fullRotation = quad.rotatedClockwise.rotatedClockwise
            .rotatedClockwise.rotatedClockwise
        XCTAssertEqual(fullRotation.topLeft.x, quad.topLeft.x, accuracy: 1e-12)
        XCTAssertEqual(fullRotation.topLeft.y, quad.topLeft.y, accuracy: 1e-12)
        XCTAssertEqual(
            fullRotation.bottomRight.x,
            quad.bottomRight.x,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            fullRotation.bottomRight.y,
            quad.bottomRight.y,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            quad.moving(
                .topLeft,
                to: ScanCropPoint(x: 0.95, y: 0.95)
            ),
            quad
        )

        let invalid = ScanCropQuad(
            topLeft: ScanCropPoint(x: 0, y: 0),
            topRight: ScanCropPoint(x: 0.02, y: 0),
            bottomRight: ScanCropPoint(x: 0.02, y: 0.02),
            bottomLeft: ScanCropPoint(x: 0, y: 0.02)
        )
        XCTAssertFalse(invalid.isValid)
        let options = ScanProcessingOptions(
            enhancement: .document,
            autoCrop: true,
            removeShadows: true,
            cleanEdges: true,
            brightness: 4,
            contrast: -2,
            manualCrop: invalid
        )
        XCTAssertEqual(options.brightness, 0.5)
        XCTAssertEqual(options.contrast, 0.5)
        XCTAssertNil(options.manualCrop)
        XCTAssertTrue(options.hasToneAdjustments)
        XCTAssertFalse(ScanProcessingOptions.original.hasToneAdjustments)
    }

    func testScanManualCropAndPerPageRenderingUseSharedOptions_BitsUT()
        throws {
        let image = makeTestImage(size: CGSize(width: 480, height: 360))
        let quad = ScanCropQuad(
            topLeft: ScanCropPoint(x: 0.1, y: 0.1),
            topRight: ScanCropPoint(x: 0.9, y: 0.1),
            bottomRight: ScanCropPoint(x: 0.9, y: 0.9),
            bottomLeft: ScanCropPoint(x: 0.1, y: 0.9)
        )
        let options = ScanProcessingOptions(
            enhancement: .color,
            autoCrop: false,
            removeShadows: false,
            cleanEdges: true,
            brightness: 0.1,
            contrast: 1.2,
            manualCrop: quad
        )
        let renderer = ScanPDFRenderer()
        let preview = renderer.preview(image: image, options: options)
        XCTAssertTrue(preview.detectedDocument)
        XCTAssertEqual(preview.cropQuad, quad)
        XCTAssertLessThan(preview.image.size.width, image.size.width)
        XCTAssertLessThan(preview.image.size.height, image.size.height)

        let destination = temporaryDirectory
            .appendingPathComponent("per-page-scan.pdf")
        let progress = TestProgressRecorder()
        try renderer.render(
            pages: [
                ScanPageImage(
                    image: image,
                    processingOptions: options
                ),
                ScanPageImage(
                    image: image,
                    processingOptions: .original
                )
            ],
            to: destination,
            options: .document,
            progress: { progress.append($0) }
        )
        let output = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 1)
    }

    func testPrintAndBookletPreparationProduceReopenableOutputs_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("production-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 5)
        let service = PDFOutputService()
        let printOptions = PDFPrintPreparationOptions(
            paperTarget: .letter,
            orientation: .automatic,
            scaleMode: .fit,
            marginPoints: 24
        )
        let printAssessment = try service.printPreparationAssessment(
            sourceURL: source,
            revisionID: UUID(),
            options: printOptions
        )
        XCTAssertEqual(printAssessment.pages.count, 5)
        XCTAssertEqual(printAssessment.averageScalePercent, 92)

        let printURL = temporaryDirectory
            .appendingPathComponent("print-ready.pdf")
        try service.prepareForPrint(
            sourceURL: source,
            destination: printURL,
            options: printOptions
        )
        let printOutput = try XCTUnwrap(PDFDocument(url: printURL))
        XCTAssertEqual(printOutput.pageCount, 5)
        XCTAssertEqual(
            printOutput.page(at: 0)?.bounds(for: .mediaBox).size,
            CGSize(width: 612, height: 792)
        )

        let bookletOptions = PDFBookletOptions(
            paperTarget: .letter,
            bindingEdge: .left,
            outerMarginPoints: 24,
            gutterPoints: 12,
            showsFoldMarks: true,
            signatureSheetLimit: 0,
            creepCompensationPoints: 4
        )
        let bookletAssessment = try service.bookletAssessment(
            sourceURL: source,
            revisionID: UUID(),
            options: bookletOptions
        )
        XCTAssertEqual(bookletAssessment.paddedPageCount, 8)
        XCTAssertEqual(bookletAssessment.insertedBlankCount, 3)
        XCTAssertEqual(bookletAssessment.sheetCount, 2)
        XCTAssertEqual(bookletAssessment.outputPageCount, 4)

        let bookletURL = temporaryDirectory
            .appendingPathComponent("booklet.pdf")
        try service.prepareBooklet(
            sourceURL: source,
            destination: bookletURL,
            options: bookletOptions
        )
        XCTAssertEqual(
            PDFDocument(url: bookletURL)?.pageCount,
            bookletAssessment.outputPageCount
        )
    }

    func testBatesBatchTransactionReceiptMatchingAndRemoval_BitsUT()
        async throws {
        let firstSource = temporaryDirectory
            .appendingPathComponent("bates-a.pdf")
        let secondSource = temporaryDirectory
            .appendingPathComponent("bates-b.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: firstSource,
            pageCount: 2
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: secondSource,
            pageCount: 3
        )
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("BatesTransactionStore"),
            signingPrivateKeyProvider: { signingKey }
        )
        let first = try await store.importPDF(
            from: firstSource,
            preserveSourceLocation: false
        )
        let second = try await store.importPDF(
            from: secondSource,
            preserveSourceLocation: false
        )
        let plan = try PDFBatesBatchPlan(
            records: [first, second],
            startNumber: 41,
            digitCount: 6,
            prefix: "MAT-",
            suffix: "",
            position: .bottomRight
        )
        let mutation = PDFMutationService()
        var prepared: [PreparedPDFWorkingCopy] = []
        for item in plan.items {
            let record = item.recordID == first.id ? first : second
            let sourceURL = await store.url(for: record)
            let preparedURL = temporaryDirectory
                .appendingPathComponent(
                    "prepared-\(item.recordID.uuidString).pdf"
                )
            try FileManager.default.copyItem(
                at: sourceURL,
                to: preparedURL
            )
            try mutation.applyBatesNumbers(
                plan.payload(for: item),
                in: preparedURL
            )
            prepared.append(
                PreparedPDFWorkingCopy(
                    recordID: record.id,
                    sourceRevisionID: record.contentRevisionID,
                    preparedURL: preparedURL
                )
            )
        }

        let committed = try await store
            .replaceWorkingCopiesAndCreateBatesReceipt(
                with: prepared,
                plan: plan
            )
        let receipt = try XCTUnwrap(committed.batesReceipt)
        XCTAssertTrue(receipt.payload.isStructurallyValid)
        let persistedReceiptIDs = try await store
            .loadBatesBatchReceipts()
            .map(\.id)
        XCTAssertEqual(
            persistedReceiptIDs,
            [receipt.id]
        )
        let current = try await store.verifyBatesBatchReceipt(receipt)
        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(current.currentCount, 2)
        XCTAssertEqual(current.trustStatus, .thisDevice)
        let exportedReceiptURL = try await store
            .exportBatesBatchReceipt(receiptID: receipt.id)
        let externalStore = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ExternalBatesReceiptStore"),
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        let externalInspection = try await externalStore
            .inspectExternalBatesBatchReceipt(at: exportedReceiptURL)
        XCTAssertEqual(
            externalInspection.report.signatureStatus,
            .verified
        )
        XCTAssertEqual(externalInspection.report.trustStatus, .unknown)
        let retainedExternal = try await externalStore
            .retainExternalBatesBatchReceipt(receipt)
        XCTAssertEqual(retainedExternal.first?.id, receipt.id)
        let deletedExternal = try await externalStore
            .deleteBatesBatchReceipt(receiptID: receipt.id)
        XCTAssertTrue(deletedExternal.isEmpty)

        var numberedURLs: [URL] = []
        for record in committed.records {
            numberedURLs.append(await store.url(for: record))
        }
        let numberedMatch = try await store.matchExternalBatesPDFs(
            receipt: receipt,
            candidateURLs: numberedURLs
        )
        XCTAssertTrue(numberedMatch.isCompleteOutputSet)
        let signedMatchURL = try await store
            .exportSignedBatesMatchReport(
                receipt: receipt,
                report: numberedMatch
            )
        let inspectedMatch = try await store
            .inspectExternalBatesMatchReport(at: signedMatchURL)
        XCTAssertTrue(inspectedMatch.isVerified)
        XCTAssertEqual(inspectedMatch.trustStatus, .thisDevice)

        var clearedCopies: [PreparedPDFWorkingCopy] = []
        for record in committed.records {
            let currentURL = await store.url(for: record)
            let clearedURL = temporaryDirectory
                .appendingPathComponent(
                    "cleared-\(record.id.uuidString).pdf"
                )
            try FileManager.default.copyItem(
                at: currentURL,
                to: clearedURL
            )
            XCTAssertEqual(
                try mutation.removeGeneratedBatesNumbers(
                    in: clearedURL
                ),
                record.profile.pageCount
            )
            clearedCopies.append(
                PreparedPDFWorkingCopy(
                    recordID: record.id,
                    sourceRevisionID: record.contentRevisionID,
                    preparedURL: clearedURL
                )
            )
        }
        let removalResult = try await store
            .replaceWorkingCopiesAndCreateBatesRemovalReceipt(
                with: clearedCopies,
                receiptID: receipt.id
            )
        let removedReceipt = try XCTUnwrap(
            removalResult.batesReceipt
        )
        XCTAssertNotNil(removedReceipt.removal)
        let removedReport = try await store
            .verifyBatesBatchReceipt(removedReceipt)
        XCTAssertTrue(removedReport.isCurrent)
        XCTAssertEqual(removedReport.removedCount, 2)

        var clearedURLs: [URL] = []
        for record in removalResult.records {
            clearedURLs.append(await store.url(for: record))
        }
        let clearedMatch = try await store.matchExternalBatesPDFs(
            receipt: removedReceipt,
            candidateURLs: clearedURLs
        )
        XCTAssertTrue(clearedMatch.isCompleteRemovedSet)
    }

    func testOfficeDeliveryMatchAndSignedReportRoundTrip_BitsUT()
        async throws {
        let artifact = temporaryDirectory
            .appendingPathComponent("delivery.docx")
        let artifactData = Data("verified office output".utf8)
        try artifactData.write(to: artifact)
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("OfficeMatchStore"),
            signingPrivateKeyProvider: { signingKey }
        )
        let createdAt = PDFOfficeTimeAnchor.process.trustedDate()
        let payload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: UUID(),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3_600),
            verifiedOutputs: 1,
            files: [
                PDFOfficeDeliveryEntry(
                    sourceRecordID: UUID(),
                    sourceRevisionID: UUID(),
                    sourceName: "Source",
                    receiptID: UUID(),
                    format: .wordDocument,
                    archiveName: "delivery.docx",
                    byteCount: Int64(artifactData.count),
                    sha256: sha256(artifactData)
                )
            ]
        )
        let signed = try await store.signOfficeDeliveryPayload(payload)
        let match = try await store.matchExternalOfficeDeliveryFiles(
            report: signed,
            candidateURLs: [artifact, artifact]
        )
        XCTAssertTrue(match.isComplete)
        XCTAssertEqual(match.exactCount, 1)
        XCTAssertEqual(match.totalCandidateCount, 1)

        let signedMatchURL = try await store
            .exportSignedOfficeMatchReport(
                deliveryReport: signed,
                matchReport: match
            )
        let inspection = try await store
            .inspectExternalOfficeMatchReport(at: signedMatchURL)
        XCTAssertTrue(inspection.isVerified)
        XCTAssertEqual(inspection.trustStatus, .thisDevice)
        XCTAssertEqual(
            inspection.deliveryTrustStatus,
            .thisDevice
        )
    }

    func testSignedVersionArchiveVerifiesBytesAndSourceIdentity_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("milestone-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 2)
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("VersionArchiveStore"),
            signingPrivateKeyProvider: { signingKey }
        )
        let record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let snapshot = try await store.createVersionSnapshot(
            for: record,
            label: "Before approval"
        )
        _ = try await store.updateVersionMilestone(
            snapshotID: snapshot.id,
            recordID: record.id,
            name: "Approved source",
            pinned: true,
            linkedDeliveryReceiptID: nil
        )
        let snapshotURL = try await store.versionFileURL(
            snapshotID: snapshot.id,
            recordID: record.id
        )
        let archiveName = "01-approved-source.pdf"
        let createdAt = Date()
        let manifest = PDFVersionArchiveManifest(
            schema: "PaperPath Version Archive V49",
            createdAt: createdAt,
            entries: [
                PDFVersionArchiveManifest.Entry(
                    fileName: archiveName,
                    documentID: record.id,
                    snapshotID: snapshot.id,
                    title: "Approved source",
                    createdAt: snapshot.createdAt,
                    byteCount: snapshot.byteCount,
                    pageCount: snapshot.pageCount,
                    sha256: snapshot.contentFingerprint,
                    linkedDeliveryReceiptID: nil
                )
            ]
        )
        let signedManifest = try await store
            .signVersionArchiveManifest(manifest)
        let manifestURL = temporaryDirectory
            .appendingPathComponent(
                "PaperPath-version-manifest.json"
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(signedManifest).write(to: manifestURL)
        let archiveURL = temporaryDirectory
            .appendingPathComponent("milestones.zip")
        try OfficeBatchArchiveService().createArchive(
            sources: [
                OfficeBatchArchiveSource(
                    sourceURL: snapshotURL,
                    archiveName: archiveName
                ),
                OfficeBatchArchiveSource(
                    sourceURL: manifestURL,
                    archiveName: manifestURL.lastPathComponent
                )
            ],
            destination: archiveURL
        )

        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.verifiedVersionArchivePrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: extractionDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: extractionDirectory)
        }
        let rawReport = try PDFVersionArchiveVerificationService()
            .verify(
                archiveURL: archiveURL,
                extractionDirectory: extractionDirectory
            )
        XCTAssertEqual(rawReport.status, .verified)
        XCTAssertEqual(rawReport.signatureStatus, .verified)
        XCTAssertEqual(rawReport.trustStatus, .unknown)
        let trustedReport = try await store.resolveVersionArchiveTrust(
            rawReport
        )
        XCTAssertEqual(trustedReport.trustStatus, .thisDevice)
        XCTAssertEqual(trustedReport.verifiedCount, 1)

        let foreignKey = Curve25519.Signing.PrivateKey()
        let foreignStore = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ForeignVersionArchiveStore"),
            signingPrivateKeyProvider: { foreignKey }
        )
        let unknownReport = try await foreignStore
            .resolveVersionArchiveTrust(rawReport)
        XCTAssertEqual(unknownReport.trustStatus, .unknown)
        let trustedSigners = try await foreignStore
            .trustVersionArchiveSigner(unknownReport)
        XCTAssertEqual(
            trustedSigners.first?.keyID,
            rawReport.signerKeyID
        )
        let externallyTrusted = try await foreignStore
            .resolveVersionArchiveTrust(rawReport)
        XCTAssertEqual(externallyTrusted.trustStatus, .trusted)
        let recovered = try await foreignStore
            .importVerifiedVersionArchiveArtifact(
                externallyTrusted,
                itemID: snapshot.id
            )
        XCTAssertEqual(recovered.profile.pageCount, 2)
        XCTAssertEqual(recovered.contentFingerprint, snapshot.contentFingerprint)
    }

    func testPageGeometryRedactionAndStorageModelsClampInputs_BitsUT() {
        let insets = PDFPageCropInsets(
            top: -0.2,
            right: 0.8,
            bottom: 0.1,
            left: 0.2
        )
        XCTAssertEqual(insets.clamped.top, 0)
        XCTAssertEqual(insets.clamped.right, 0.42)
        XCTAssertEqual(
            PDFPageCropInsets(
                top: 0.1,
                right: 0.2,
                bottom: 0.3,
                left: 0.4
            ).mappedToPDFBox(rotation: 90),
            PDFPageCropInsets(
                top: 0.2,
                right: 0.3,
                bottom: 0.4,
                left: 0.1
            )
        )
        let cleanMarks = PDFRedactionMarkSanitizer.clean([
            PDFRedactionMark(
                pageIndex: 1,
                normalizedX: -0.1,
                normalizedY: 0.2,
                normalizedWidth: 2,
                normalizedHeight: 0.3
            ),
            PDFRedactionMark(
                pageIndex: 1,
                normalizedX: -0.1,
                normalizedY: 0.2,
                normalizedWidth: 2,
                normalizedHeight: 0.3
            ),
            PDFRedactionMark(
                pageIndex: -1,
                normalizedX: 0,
                normalizedY: 0,
                normalizedWidth: 1,
                normalizedHeight: 1
            )
        ])
        XCTAssertEqual(cleanMarks.count, 1)
        XCTAssertEqual(cleanMarks[0].normalizedX, 0)
        XCTAssertEqual(cleanMarks[0].normalizedWidth, 1)

        let storage = LocalStorageSnapshot(
            pdfBytes: 1,
            versionBytes: 2,
            textIndexBytes: 3,
            ocrBytes: 4,
            deliveryCacheBytes: 5,
            officeExportBytes: 6,
            officeDeliveryBytes: 7,
            changeReportBytes: 8,
            metadataBytes: 9
        )
        XCTAssertEqual(storage.totalBytes, 45)
        XCTAssertTrue(
            PDFPinnedVersionStorageSummary(
                milestoneCount: 28,
                byteCount: 1
            ).isNearCapacity
        )
        XCTAssertFalse(
            PDFPinnedVersionStorageSummary(
                milestoneCount: 32,
                byteCount: 0
            ).canAdd(bytes: 1)
        )
    }

    func testExperienceDefaultsAndPreviewBudgetsRemainBounded_BitsUT()
        throws {
        let suiteName = "PaperPathTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        AppPreferences.registerDefaults(defaults: defaults)
        XCTAssertFalse(
            defaults.bool(
                forKey: AppPreferences.metadataSyncEnabledKey
            )
        )
        XCTAssertFalse(
            defaults.bool(
                forKey: AppPreferences.dueRemindersEnabledKey
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: AppPreferences.previewQualityKey
            ),
            ThumbnailPreviewQuality.automatic.rawValue
        )
        XCTAssertEqual(ThumbnailPreviewQuality.economy.renderScale, 1)
        XCTAssertEqual(
            ThumbnailPreviewQuality.economy.cacheEntryLimit,
            24
        )
        XCTAssertEqual(
            ThumbnailPreviewQuality.detailed.cacheByteLimit,
            18 * 1_024 * 1_024
        )
        XCTAssertEqual(
            ThumbnailPreviewQuality.detailed.cacheDocumentLimit,
            3
        )
    }

    func testTaskAndActionPlannersPrioritizeResumeAndDeliveryState_BitsUT()
        throws {
        var formProfile = makeProfile(pageCount: 2)
        formProfile.kind = .form
        formProfile.formFieldCount = 3
        let checkpoint = DocumentTaskCheckpoint(
            stage: .sign,
            pageIndex: 12,
            fieldName: "  Approval signature  ",
            normalizedBounds: PDFNormalizedRect(
                x: 0.2,
                y: 0.2,
                width: 0.4,
                height: 0.1
            ),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let record = DocumentRecord(
            displayName: "Client agreement",
            fileName: "agreement.pdf",
            profile: formProfile,
            workflowStatus: .reviewing,
            completedActions: [.reviewForm],
            taskCheckpoint: checkpoint
        )

        XCTAssertEqual(record.taskCheckpoint?.pageIndex, 1)
        XCTAssertEqual(record.taskCheckpoint?.fieldName, "Approval signature")
        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: record,
                hasRecognizedText: false
            ).first,
            .sign
        )
        XCTAssertFalse(
            DocumentActionPlanner.actions(
                for: record,
                hasRecognizedText: false
            ).contains(.reviewForm)
        )
        let packageRecommendation = try XCTUnwrap(
            PDFTaskPackagePlanner.recommendation(
                for: record,
                hasRecognizedText: false
            )
        )
        XCTAssertEqual(packageRecommendation.task, .signPDF)
        XCTAssertEqual(packageRecommendation.title, "Continue signing")
        XCTAssertTrue(
            packageRecommendation.reason.contains("Approval signature")
        )

        let revisionID = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        let deliveryReceipt = PDFDeliveryReceipt(
            id: UUID(),
            operation: .safeShare,
            createdAt: Date(timeIntervalSince1970: 1_000),
            sourcePageCount: 1,
            outputPageCount: 1,
            renderedPageCount: 1,
            sourceByteCount: 2_048,
            outputByteCount: 2_048,
            unexpectedBlankPageIndices: [],
            annotationCount: 0,
            textCharacterCount: 12,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: fingerprint,
            checks: [
                PDFDeliveryCheck(
                    id: "reopened",
                    title: "Reopened",
                    detail: "Every output page reopened.",
                    status: .passed
                )
            ],
            sourceRevisionID: nil,
            outputRevisionID: revisionID
        )
        var deliveryProfile = makeProfile(pageCount: 1)
        deliveryProfile.byteCount = 2_048
        let deliveryArtifact = DocumentRecord(
            displayName: "Signed copy",
            fileName: "signed.pdf",
            contentRevisionID: revisionID,
            profile: deliveryProfile,
            deliveryReceipt: deliveryReceipt,
            sourceDocumentID: UUID(),
            contentFingerprint: fingerprint
        )

        XCTAssertTrue(deliveryArtifact.isDeliveryArtifact)
        XCTAssertTrue(deliveryArtifact.hasCurrentDeliveryReceipt)
        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: deliveryArtifact,
                hasRecognizedText: false
            ),
            [.shareCopy, .inspect]
        )
        XCTAssertEqual(
            PDFTaskPackagePlanner.recommendation(
                for: deliveryArtifact,
                hasRecognizedText: false
            )?.title,
            "Share verified PDF"
        )
    }

    func testDocumentRecordDecodingAndCandidateRelationContracts_BitsUT()
        throws {
        let base = Date(timeIntervalSince1970: 94_000)
        let sourceID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")
        )
        let parentID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000102")
        )
        let legacyRecord = DocumentRecord(
            id: sourceID,
            displayName: "Legacy agreement",
            fileName: "legacy.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(5),
            contentRevisionID: UUID(),
            profile: makeProfile(pageCount: 3),
            workflowStatus: .reviewing,
            isPinned: true,
            tags: ["legal"],
            bookmarkedPages: [2],
            lastPageIndex: 99,
            lastViewedAt: base.addingTimeInterval(8),
            completedActions: [.inspect],
            taskCheckpoint: DocumentTaskCheckpoint(
                stage: .sign,
                pageIndex: 99,
                fieldName: "  Approval  ",
                updatedAt: base.addingTimeInterval(10)
            ),
            sourceDocumentID: parentID,
            sourceImportedFingerprint: String(repeating: "a", count: 64),
            contentFingerprint: String(repeating: "b", count: 64),
            deletedAt: base.addingTimeInterval(11),
            dueAt: base.addingTimeInterval(12),
            privateNote: "Internal note",
            bookmarkNames: [2: "Signature"],
            sharedImportID: UUID()
        )

        let encoded = try JSONEncoder().encode(legacyRecord)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        [
            "contentRevisionID",
            "workflowStatus",
            "isPinned",
            "tags",
            "bookmarkedPages",
            "lastViewedAt",
            "completedActions",
            "officeReceipts",
            "sourceDocumentID",
            "sourceImportedFingerprint",
            "contentFingerprint",
            "deletedAt",
            "dueAt",
            "privateNote",
            "bookmarkNames",
            "sharedImportID"
        ].forEach { object.removeValue(forKey: $0) }
        object["lastPageIndex"] = 99
        if var checkpoint = object["taskCheckpoint"] as? [String: Any] {
            checkpoint["pageIndex"] = 99
            object["taskCheckpoint"] = checkpoint
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            DocumentRecord.self,
            from: legacyData
        )
        XCTAssertEqual(decoded.contentRevisionID, decoded.id)
        XCTAssertEqual(decoded.workflowStatus, .inbox)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertTrue(decoded.bookmarkedPages.isEmpty)
        XCTAssertNil(decoded.lastViewedAt)
        XCTAssertTrue(decoded.completedActions.isEmpty)
        XCTAssertTrue(decoded.officeReceipts.isEmpty)
        XCTAssertNil(decoded.sourceDocumentID)
        XCTAssertNil(decoded.contentFingerprint)
        XCTAssertNil(decoded.deletedAt)
        XCTAssertNil(decoded.dueAt)
        XCTAssertNil(decoded.privateNote)
        XCTAssertTrue(decoded.bookmarkNames.isEmpty)
        XCTAssertNil(decoded.sharedImportID)
        XCTAssertEqual(decoded.lastPageIndex, 2)
        XCTAssertEqual(decoded.taskCheckpoint?.pageIndex, 2)
        XCTAssertEqual(decoded.taskCheckpoint?.fieldName, "Approval")

        let source = DocumentRecord(
            id: sourceID,
            displayName: "Matter source",
            fileName: "source.pdf",
            modifiedAt: base,
            profile: makeProfile(pageCount: 2),
            sourceDocumentID: parentID
        )
        let directChildID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000103")
        )
        let directChild = DocumentRecord(
            id: directChildID,
            displayName: "Verified output",
            fileName: "child.pdf",
            modifiedAt: base,
            profile: makeProfile(pageCount: 2),
            lastViewedAt: base.addingTimeInterval(10),
            sourceDocumentID: source.id
        )
        let parent = DocumentRecord(
            id: parentID,
            displayName: "Original parent",
            fileName: "parent.pdf",
            modifiedAt: base,
            profile: makeProfile(pageCount: 2),
            lastViewedAt: base.addingTimeInterval(5)
        )
        let siblingID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000104")
        )
        let sibling = DocumentRecord(
            id: siblingID,
            displayName: "Sibling export",
            fileName: "sibling.pdf",
            modifiedAt: base,
            profile: makeProfile(pageCount: 2),
            lastViewedAt: base.addingTimeInterval(1_000),
            sourceDocumentID: parentID
        )
        let unrelatedID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000105")
        )
        let unrelated = DocumentRecord(
            id: unrelatedID,
            displayName: "Recently viewed unrelated",
            fileName: "unrelated.pdf",
            modifiedAt: base,
            profile: makeProfile(pageCount: 2),
            lastViewedAt: base.addingTimeInterval(2_000)
        )
        let alphaID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000106")
        )
        let alpha = DocumentRecord(
            id: alphaID,
            displayName: "Alpha appendix",
            fileName: "alpha.pdf",
            modifiedAt: base,
            profile: makeProfile(pageCount: 2)
        )
        let bravoID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000107")
        )
        let bravo = DocumentRecord(
            id: bravoID,
            displayName: "Bravo appendix",
            fileName: "bravo.pdf",
            modifiedAt: base.addingTimeInterval(100),
            profile: makeProfile(pageCount: 2)
        )
        var lockedProfile = makeProfile(pageCount: 2)
        lockedProfile.isLocked = true
        let lockedRelated = DocumentRecord(
            displayName: "Locked related",
            fileName: "locked.pdf",
            profile: lockedProfile,
            sourceDocumentID: source.id
        )

        let ordered = DocumentComparisonCandidates.ordered(
            from: [
                unrelated,
                sibling,
                source,
                bravo,
                directChild,
                lockedRelated,
                alpha,
                parent
            ],
            sourceID: source.id
        )
        XCTAssertEqual(
            ordered.map(\.id),
            [directChildID, parentID, siblingID, unrelatedID, alphaID, bravoID]
        )
        XCTAssertFalse(ordered.contains { $0.profile.isLocked })
        XCTAssertFalse(ordered.contains { $0.id == source.id })
    }

    func testQuickTaskSearchSupportAndPackageHomeOrdering_BitsUT() {
        XCTAssertEqual(
            PDFTaskPackagePlanner.homePackages(for: []),
            [
                .prepareToSend,
                .makeSearchable,
                .convertForWork,
                .compressForEmail,
                .fixPages
            ]
        )
        XCTAssertEqual(PDFQuickTask.exportText.matchScore("PDF to Office"), 100)
        XCTAssertTrue(PDFQuickTask.exportText.matches("word excel"))
        XCTAssertNil(PDFQuickTask.redactPDF.matchScore("scan camera"))
        XCTAssertEqual(DocumentTool.find.matchScore("Find"), 1_210)
        XCTAssertTrue(DocumentTool.bates.matches("legal exhibit"))
        XCTAssertFalse(DocumentTool.protect.matches("ocr scan"))

        var lockedProfile = makeProfile(pageCount: 3)
        lockedProfile.isLocked = true
        let lockedRecord = DocumentRecord(
            displayName: "Locked",
            fileName: "locked.pdf",
            profile: lockedProfile
        )

        XCTAssertFalse(PDFQuickTask.safeShare.supports(lockedRecord))
        XCTAssertFalse(PDFTaskPackage.prepareToSend.supports(lockedRecord))
        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: lockedRecord,
                hasRecognizedText: false
            ),
            [.inspect, .shareCopy]
        )
    }

    func testOfficePortfolioRoutesAndReceiptAvailability_BitsUT() {
        var protectedScan = makeProfile(pageCount: 640)
        protectedScan.kind = .scan
        protectedScan.sampledPageCount = 10
        protectedScan.imageDominantPageCount = 9
        protectedScan.byteCount = 300 * 1_024 * 1_024
        protectedScan.isEncrypted = true
        protectedScan.isLocked = true
        protectedScan.allowsCopying = false

        let portfolio = PDFOfficeExportPortfolio(profile: protectedScan)
        XCTAssertEqual(portfolio.routeConfidence, .weak)
        XCTAssertEqual(portfolio.productionSLA, .constrained)
        XCTAssertGreaterThanOrEqual(portfolio.limitedSignalCount, 2)
        XCTAssertEqual(portfolio.preflightSignals.count, 4)
        XCTAssertEqual(portfolio.suggestedSegmentCount, 3)
        XCTAssertTrue(
            portfolio.outputBoundaryLine.contains("640")
        )
        XCTAssertTrue(
            portfolio.recoveryActions.map(\.id).contains("permissions")
        )
        XCTAssertTrue(
            portfolio.recoveryActions.map(\.id).contains("ocr")
        )
        XCTAssertEqual(
            PDFOfficeExportFormatPlan.plan(
                for: .powerPointPresentation,
                profile: protectedScan
            ).readiness,
            .limited
        )

        let revisionID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let budgetPlan = PDFOfficeVisualBudgetPlan(
            profile: makeProfile(pageCount: 2)
        )
        let plan = PDFOfficeExportFormatPlan(
            format: .wordDocument,
            readiness: .review,
            editabilityScore: 70,
            appearanceScore: 68,
            sizeScore: 90,
            primaryEvidence: "70% text",
            riskEvidence: "Local rebuild",
            preferredUse: "Contracts",
            fallbackFormat: .plainText
        )
        var receipt = PDFOfficeExportReceipt(
            format: .wordDocument,
            fileName: "Agreement.docx",
            fileSizeBytes: 4_096,
            plan: plan,
            budgetPlan: budgetPlan
        )
        receipt.sourceRevisionID = revisionID
        receipt.retainedFileName = "Agreement.docx"
        receipt.reusableUntil = now.addingTimeInterval(60)
        receipt.artifactSHA256 = "abcdef123456" + String(repeating: "0", count: 52)

        XCTAssertEqual(
            receipt.artifactAvailability(for: revisionID, now: now),
            .reusable
        )
        XCTAssertEqual(
            receipt.artifactAvailability(for: UUID(), now: now),
            .sourceChanged
        )
        XCTAssertEqual(
            receipt.artifactAvailability(
                for: revisionID,
                now: now.addingTimeInterval(120)
            ),
            .expired
        )
        XCTAssertEqual(receipt.shortArtifactFingerprint, "abcd ef12 3456")
        XCTAssertEqual(receipt.embeddedEvidenceLabel, "App receipt")
        XCTAssertTrue(
            receipt.qualityGateSummary.contains(
                "\(receipt.routeScore)"
            )
        )
        receipt.pinnedAt = now
        XCTAssertEqual(
            receipt.artifactAvailability(
                for: revisionID,
                now: now.addingTimeInterval(120)
            ),
            .reusable
        )
        receipt.integrityStatus = .mismatch
        XCTAssertEqual(receipt.integritySummary, "Hash mismatch")
    }

    func testProgressAndBatchStateClampValues_BitsUT() {
        let stalledDate = Date(timeIntervalSince1970: 200)
        let stalledProgress = PDFOfficeIntegrityProgress(
            completedCount: 1,
            totalCount: 4,
            currentSourceName: "Large.pdf",
            processedBytes: 32,
            totalBytes: 1_024,
            bytesPerSecond: 256,
            estimatedRemainingSeconds: 125.1,
            activity: .checksumming,
            throughputHistory: [128, 256],
            lastByteUpdateAt: stalledDate.addingTimeInterval(-2.1)
        )
        XCTAssertEqual(stalledProgress.fractionCompleted, 0.03125)
        XCTAssertEqual(stalledProgress.counter, "1/4")
        XCTAssertEqual(stalledProgress.remainingSummary, "2m 6s")
        XCTAssertNotNil(stalledProgress.byteSummary)
        XCTAssertNotNil(stalledProgress.throughputSummary)
        XCTAssertTrue(stalledProgress.isStalled(at: stalledDate))

        let overComplete = PDFOfficeIntegrityProgress(
            completedCount: 9,
            totalCount: 3,
            currentSourceName: "Done.pdf"
        )
        XCTAssertEqual(overComplete.fractionCompleted, 1)
        XCTAssertFalse(overComplete.isStalled(at: stalledDate))

        let batchProgress = PDFBatesBatchProgress(
            stage: .committing,
            completedDocumentCount: 99,
            totalDocumentCount: 1,
            completedPageCount: 99,
            totalPageCount: 10,
            currentDocumentName: "Batch.pdf"
        )
        XCTAssertEqual(batchProgress.fractionCompleted, 1)
        XCTAssertEqual(
            PDFOperationProgress(
                label: "Write",
                fractionCompleted: 0.456,
                processedBytes: 1_024,
                totalBytes: 2_048,
                bytesPerSecond: 512,
                estimatedRemainingSeconds: 0.2,
                lastByteUpdateAt: stalledDate.addingTimeInterval(-3)
            ).remainingSummary,
            "1s"
        )
    }

    func testOfficeVerificationAndMatchPayloadsRejectTampering_BitsUT() {
        let now = Date(timeIntervalSince1970: 20_000)
        let packageID = UUID()
        let receiptID = UUID()
        let hash = String(repeating: "b", count: 64)
        let entry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Quarterly report",
            receiptID: receiptID,
            format: .wordDocument,
            archiveName: "QuarterlyReport.docx",
            byteCount: 2_048,
            sha256: hash
        )
        let payload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: packageID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            verifiedOutputs: 1,
            files: [entry]
        )
        XCTAssertTrue(payload.isStructurallyValid(at: now.addingTimeInterval(60)))
        XCTAssertTrue(payload.isActive(at: now.addingTimeInterval(60)))
        XCTAssertFalse(payload.isActive(at: now.addingTimeInterval(3_601)))

        let unsafeEntry = PDFOfficeDeliveryEntry(
            sourceRecordID: entry.sourceRecordID,
            sourceRevisionID: entry.sourceRevisionID,
            sourceName: entry.sourceName,
            receiptID: entry.receiptID,
            format: entry.format,
            archiveName: "../QuarterlyReport.docx",
            byteCount: entry.byteCount,
            sha256: entry.sha256
        )
        XCTAssertFalse(
            PDFOfficeVerificationPayload(
                schema: payload.schema,
                packageID: packageID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                verifiedOutputs: 1,
                files: [unsafeEntry]
            ).isStructurallyValid(at: now.addingTimeInterval(60))
        )

        let signature = PDFOfficeVerificationSignature(
            algorithm: "Ed25519",
            keyID: "0123456789abcdef",
            publicKeyBase64: "public",
            signatureBase64: "signature"
        )
        let candidate = PDFOfficeExternalCandidate(
            id: UUID(),
            fileName: "QuarterlyReport.docx",
            fileExtension: "docx",
            byteCount: entry.byteCount,
            sha256: entry.sha256
        )
        let reportID = UUID()
        let checkedAt = now.addingTimeInterval(120)
        let validReport = PDFOfficeExternalMatchReport(
            id: reportID,
            packageID: packageID,
            checkedAt: checkedAt,
            matches: [
                PDFOfficeExternalEntryMatch(
                    entry: entry,
                    status: .exact,
                    candidates: [candidate]
                )
            ],
            extraCandidates: [],
            totalCandidateCount: 1,
            totalCandidateBytes: candidate.byteCount
        )
        let signedDelivery = PDFOfficeSignedVerificationReport(
            payload: payload,
            signature: signature
        )
        XCTAssertTrue(
            PDFOfficeMatchReportPayload(
                schema: PDFOfficeMatchReportPayload.schema,
                reportID: reportID,
                createdAt: checkedAt,
                deliveryReport: signedDelivery,
                matchReport: validReport
            ).isStructurallyValid(at: checkedAt.addingTimeInterval(1))
        )

        let tamperedStatusReport = PDFOfficeExternalMatchReport(
            id: reportID,
            packageID: packageID,
            checkedAt: checkedAt,
            matches: [
                PDFOfficeExternalEntryMatch(
                    entry: entry,
                    status: .ambiguous,
                    candidates: [candidate]
                )
            ],
            extraCandidates: [],
            totalCandidateCount: 1,
            totalCandidateBytes: candidate.byteCount
        )
        XCTAssertFalse(
            PDFOfficeMatchReportPayload(
                schema: PDFOfficeMatchReportPayload.schema,
                reportID: reportID,
                createdAt: checkedAt,
                deliveryReport: signedDelivery,
                matchReport: tamperedStatusReport
            ).isStructurallyValid(at: checkedAt.addingTimeInterval(1))
        )
    }

    func testBatesReceiptAndExternalMatchPayloadsValidateLinkage_BitsUT()
        throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let sourceA = String(repeating: "1", count: 64)
        let outputA = String(repeating: "2", count: 64)
        let sourceB = String(repeating: "3", count: 64)
        let outputB = String(repeating: "4", count: 64)
        let clearedA = String(repeating: "5", count: 64)
        let clearedB = String(repeating: "6", count: 64)
        let recordA = makeRecord(name: "A.pdf", pageCount: 2)
        let recordB = makeRecord(name: "B.pdf", pageCount: 1)
        let entryA = makeBatesEntry(
            record: recordA,
            outputRevisionID: UUID(),
            start: 1,
            end: 2,
            sourceHash: sourceA,
            outputHash: outputA
        )
        let entryB = makeBatesEntry(
            record: recordB,
            outputRevisionID: UUID(),
            start: 3,
            end: 3,
            sourceHash: sourceB,
            outputHash: outputB
        )
        let batchID = UUID()
        let payload = PDFBatesBatchReceiptPayload(
            schema: PDFBatesBatchReceiptPayload.schema,
            batchID: batchID,
            createdAt: now,
            digitCount: 4,
            prefix: "CASE-",
            suffix: "",
            position: .bottomRight,
            totalPageCount: 3,
            firstIdentifier: "CASE-0001",
            lastIdentifier: "CASE-0003",
            entries: [entryA, entryB]
        )
        XCTAssertTrue(payload.isStructurallyValid(at: now.addingTimeInterval(60)))

        let removalPayload = PDFBatesRemovalReceiptPayload(
            schema: PDFBatesRemovalReceiptPayload.schema,
            removalID: UUID(),
            batesBatchID: batchID,
            createdAt: now.addingTimeInterval(10),
            totalPageCount: 3,
            entries: [
                PDFBatesRemovalReceiptEntry(
                    recordID: entryA.recordID,
                    displayName: entryA.displayName,
                    pageCount: entryA.pageCount,
                    numberedRevisionID: entryA.outputRevisionID,
                    clearedRevisionID: UUID(),
                    numberedSHA256: entryA.outputSHA256,
                    clearedSHA256: clearedA
                ),
                PDFBatesRemovalReceiptEntry(
                    recordID: entryB.recordID,
                    displayName: entryB.displayName,
                    pageCount: entryB.pageCount,
                    numberedRevisionID: entryB.outputRevisionID,
                    clearedRevisionID: UUID(),
                    numberedSHA256: entryB.outputSHA256,
                    clearedSHA256: clearedB
                )
            ]
        )
        XCTAssertTrue(
            removalPayload.isLinked(
                to: payload,
                at: now.addingTimeInterval(60)
            )
        )

        let signature = PDFOfficeVerificationSignature(
            algorithm: "Ed25519",
            keyID: "fedcba9876543210",
            publicKeyBase64: "public",
            signatureBase64: "signature"
        )
        let signedReceipt = PDFSignedBatesBatchReceipt(
            payload: payload,
            signature: signature,
            removal: PDFSignedBatesRemovalReceipt(
                payload: removalPayload,
                signature: signature
            )
        )
        let candidateA = PDFBatesExternalCandidate(
            id: UUID(),
            fileName: "A-numbered.pdf",
            byteCount: 10,
            sha256: outputA
        )
        let candidateB = PDFBatesExternalCandidate(
            id: UUID(),
            fileName: "B-cleared.pdf",
            byteCount: 12,
            sha256: clearedB
        )
        let reportID = UUID()
        let checkedAt = now.addingTimeInterval(20)
        let report = PDFBatesExternalMatchReport(
            id: reportID,
            receiptID: signedReceipt.id,
            checkedAt: checkedAt,
            matches: [
                PDFBatesExternalEntryMatch(
                    entry: entryA,
                    status: .outputMatch,
                    candidates: [candidateA]
                ),
                PDFBatesExternalEntryMatch(
                    entry: entryB,
                    status: .removedMatch,
                    candidates: [candidateB]
                )
            ],
            unrecognizedCandidates: [],
            totalCandidateCount: 2,
            totalCandidateBytes: candidateA.byteCount + candidateB.byteCount
        )
        XCTAssertTrue(
            PDFBatesMatchReportPayload(
                schema: PDFBatesMatchReportPayload.schema,
                reportID: reportID,
                createdAt: checkedAt,
                receipt: signedReceipt,
                report: report
            ).isStructurallyValid(at: checkedAt.addingTimeInterval(1))
        )

        let tamperedReport = PDFBatesExternalMatchReport(
            id: reportID,
            receiptID: signedReceipt.id,
            checkedAt: checkedAt,
            matches: [
                PDFBatesExternalEntryMatch(
                    entry: entryA,
                    status: .missing,
                    candidates: [candidateA]
                ),
                PDFBatesExternalEntryMatch(
                    entry: entryB,
                    status: .removedMatch,
                    candidates: [candidateB]
                )
            ],
            unrecognizedCandidates: [],
            totalCandidateCount: 2,
            totalCandidateBytes: candidateA.byteCount + candidateB.byteCount
        )
        XCTAssertFalse(
            PDFBatesMatchReportPayload(
                schema: PDFBatesMatchReportPayload.schema,
                reportID: reportID,
                createdAt: checkedAt,
                receipt: signedReceipt,
                report: tamperedReport
            ).isStructurallyValid(at: checkedAt.addingTimeInterval(1))
        )
    }

    func testDeliveryManifestVersionArchiveAndProvenanceContracts_BitsUT() {
        let now = Date(timeIntervalSince1970: 40_000)
        let revisionID = UUID()
        let fingerprint = String(repeating: "c", count: 64)
        let check = PDFDeliveryCheck(
            id: "reopened",
            title: "Reopened",
            detail: "All pages reopened after rendering.",
            status: .passed
        )
        let receipt = PDFDeliveryReceipt(
            id: UUID(),
            operation: .safeShare,
            createdAt: now,
            sourcePageCount: 2,
            outputPageCount: 2,
            renderedPageCount: 2,
            sourceByteCount: 8_192,
            outputByteCount: 8_192,
            unexpectedBlankPageIndices: [],
            annotationCount: 1,
            textCharacterCount: 240,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: fingerprint,
            checks: [check],
            sourceRevisionID: nil,
            outputRevisionID: revisionID
        )
        let record = DocumentRecord(
            displayName: "Delivery",
            fileName: "delivery.pdf",
            contentRevisionID: revisionID,
            profile: DocumentProfile(
                pageCount: 2,
                sampledPageCount: 2,
                textCharacterCount: 240,
                imageDominantPageCount: 0,
                formFieldCount: 0,
                byteCount: 8_192,
                isEncrypted: false,
                isLocked: false,
                allowsCopying: true,
                allowsCommenting: true,
                kind: .text,
                recommendedActions: [.inspect, .shareCopy]
            ),
            deliveryReceipt: receipt,
            contentFingerprint: fingerprint
        )

        XCTAssertTrue(receipt.isVerified(at: now.addingTimeInterval(1)))
        XCTAssertEqual(receipt.shortFingerprint, "cccc cccc cccc")
        XCTAssertTrue(record.hasCurrentDeliveryReceipt)
        let manifest = PDFDeliveryPackageManifest(
            packageID: UUID(),
            createdAt: now.addingTimeInterval(1),
            artifactFileName: "Delivery.pdf",
            record: record,
            receipt: receipt
        )
        XCTAssertTrue(manifest.isStructurallyValid(at: now.addingTimeInterval(2)))
        XCTAssertFalse(
            PDFDeliveryPackageManifest(
                packageID: UUID(),
                createdAt: now.addingTimeInterval(1),
                artifactFileName: "../Delivery.pdf",
                record: record,
                receipt: receipt
            ).isStructurallyValid(at: now.addingTimeInterval(2))
        )

        let verificationReport = PDFDeliveryPackageVerificationReport(
            archiveName: "Delivery.zip",
            archiveByteCount: 10_000,
            packageID: manifest.packageID,
            packageCreatedAt: manifest.createdAt,
            verifiedAt: now.addingTimeInterval(2),
            artifactFileName: manifest.artifact.fileName,
            artifactByteCount: manifest.artifact.byteCount,
            artifactPageCount: manifest.artifact.pageCount,
            isEncrypted: false,
            operation: manifest.operation,
            deliveryReceiptID: manifest.deliveryReceiptID,
            expectedSHA256: fingerprint,
            actualSHA256: fingerprint,
            checks: [check],
            integrityFailures: [],
            signatureStatus: .verified,
            signatureDetail: "Signature verified",
            signerKeyID: "0123456789abcdef",
            signerPublicKeyBase64: "public",
            trustStatus: .unknown,
            trustedSignerName: nil,
            verifiedArtifactURL: URL(fileURLWithPath: "/tmp/Delivery.pdf")
        )
        XCTAssertEqual(verificationReport.status, .verified)
        XCTAssertTrue(verificationReport.canTrustSigner)
        XCTAssertTrue(verificationReport.canPreviewArtifact)
        XCTAssertEqual(
            verificationReport.resolvingTrust(
                .trusted,
                trustedSignerName: "Legal Ops"
            ).provenanceTitle,
            "Legal Ops"
        )
        let provenance = PDFReceivedPackageProvenance(
            report: verificationReport,
            importedAt: now.addingTimeInterval(3)
        )
        XCTAssertTrue(
            provenance.matchesCurrentBytes(
                fingerprint: fingerprint.uppercased(),
                byteCount: manifest.artifact.byteCount
            )
        )
        XCTAssertFalse(
            provenance.matchesCurrentBytes(
                fingerprint: String(repeating: "d", count: 64),
                byteCount: manifest.artifact.byteCount
            )
        )

        let versionEntry = PDFVersionArchiveManifest.Entry(
            fileName: "Delivery.pdf",
            documentID: record.id,
            snapshotID: UUID(),
            title: "Signed delivery",
            createdAt: now,
            byteCount: 8_192,
            pageCount: 2,
            sha256: fingerprint,
            linkedDeliveryReceiptID: receipt.id
        )
        XCTAssertTrue(
            PDFVersionArchiveManifest(
                schema: PDFVersionArchiveManifest.currentSchema,
                createdAt: now.addingTimeInterval(1),
                entries: [versionEntry]
            ).isStructurallyValid(at: now.addingTimeInterval(2))
        )
        let unsafeVersionEntry = PDFVersionArchiveManifest.Entry(
            fileName: ".hidden.pdf",
            documentID: record.id,
            snapshotID: UUID(),
            title: "Signed delivery",
            createdAt: now,
            byteCount: 8_192,
            pageCount: 2,
            sha256: fingerprint,
            linkedDeliveryReceiptID: receipt.id
        )
        XCTAssertFalse(
            PDFVersionArchiveManifest(
                schema: PDFVersionArchiveManifest.currentSchema,
                createdAt: now.addingTimeInterval(1),
                entries: [unsafeVersionEntry]
            ).isStructurallyValid(at: now.addingTimeInterval(2))
        )
    }

    func testChangeReviewAndSignedPayloadContracts_BitsUT() {
        let now = Date(timeIntervalSince1970: 50_000)
        let sourceRevisionID = UUID()
        let revisedRevisionID = UUID()
        let receiptID = UUID()
        let sourceFingerprint = String(repeating: "a", count: 64)
        let revisedFingerprint = String(repeating: "B", count: 64)
        let bodyHash = String(repeating: "c", count: 64)
        let region = PDFDifferenceRegion(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4,
            intensity: 0.9
        )
        let modified = PDFPageChange(
            pageIndex: 0,
            sourcePageIndex: 0,
            revisedPageIndex: 1,
            matchKind: .modified,
            sourceExists: true,
            revisedExists: true,
            visibleDifference: 0.001,
            changedPixelRatio: 0.0001,
            geometryChanged: false,
            textChanged: true,
            sourceTextCharacterCount: 18,
            revisedTextCharacterCount: 24,
            differenceRegions: [region],
            sourceTextDifferences: [
                PDFTextDifferenceEvidence(
                    kind: .removed,
                    text: "  Old   clause  ",
                    region: region
                )
            ],
            revisedTextDifferences: [
                PDFTextDifferenceEvidence(
                    kind: .inserted,
                    text: "New",
                    region: region,
                    granularity: .character
                )
            ],
            matchBasis: .textMarker
        )
        let inserted = PDFPageChange(
            pageIndex: 1,
            sourceExists: false,
            revisedExists: true,
            visibleDifference: 0,
            changedPixelRatio: 0,
            geometryChanged: false,
            textChanged: false,
            sourceTextCharacterCount: 0,
            revisedTextCharacterCount: 30
        )
        let removed = PDFPageChange(
            pageIndex: 2,
            sourceExists: true,
            revisedExists: false,
            visibleDifference: 0,
            changedPixelRatio: 0,
            geometryChanged: false,
            textChanged: false,
            sourceTextCharacterCount: 30,
            revisedTextCharacterCount: 0
        )

        XCTAssertFalse(modified.isVisibleChange)
        XCTAssertTrue(modified.isTextOnlyChange)
        XCTAssertEqual(modified.severity, .major)
        XCTAssertEqual(modified.resolvedTextDifferenceGranularity, .character)
        XCTAssertTrue(modified.localizedTextEvidenceCountLabel.contains("1"))
        XCTAssertTrue(modified.localizedTextEvidenceCountLabel.contains("·"))
        XCTAssertEqual(
            modified.textDifferencePreview,
            "Old clause → New"
        )
        XCTAssertEqual(inserted.resolvedMatchKind, .inserted)
        XCTAssertEqual(removed.resolvedMatchKind, .removed)
        XCTAssertEqual(removed.preferredOpenSide, .source)
        XCTAssertEqual(inserted.severity, .critical)

        let review = PDFChangeReview(
            sourcePageCount: 3,
            revisedPageCount: 3,
            comparedPageCount: 3,
            changes: [modified, inserted, removed],
            pageMatches: [
                PDFPageMatch(
                    id: 0,
                    sourcePageIndex: 0,
                    revisedPageIndex: 1,
                    kind: .modified,
                    basis: .textMarker
                ),
                PDFPageMatch(
                    id: 1,
                    sourcePageIndex: 1,
                    revisedPageIndex: nil,
                    kind: .removed
                ),
                PDFPageMatch(
                    id: 2,
                    sourcePageIndex: nil,
                    revisedPageIndex: 2,
                    kind: .inserted
                )
            ]
        )
        XCTAssertEqual(review.visibleChangedPageCount, 2)
        XCTAssertEqual(review.textChangedPageCount, 1)
        XCTAssertEqual(review.criticalChanges.count, 2)
        XCTAssertEqual(review.insertedPages.count, 1)
        XCTAssertEqual(review.removedPages.count, 1)
        XCTAssertGreaterThan(review.estimatedCacheByteCount, 256)
        XCTAssertEqual(review.revisedPage(matchingSourcePage: 0), 1)
        XCTAssertNil(review.sourcePage(matchingRevisedPage: 0))
        let lookup = PDFPageMatchLookup(review: review)
        XCTAssertEqual(lookup.revisedPage(matchingSourcePage: 0), 1)
        XCTAssertNil(lookup.sourcePage(matchingRevisedPage: 0))
        let fallbackMatches = PDFChangeReview(
            sourcePageCount: 2,
            revisedPageCount: 1,
            comparedPageCount: 2,
            changes: []
        ).resolvedPageMatches
        XCTAssertEqual(fallbackMatches.map(\.kind), [.unchanged, .removed])

        let payload = PDFChangeReportSignaturePayload(
            schema: PDFChangeReportSignaturePayload.schema,
            reportID: UUID(),
            generatedAt: now,
            sourceName: "Source.pdf",
            revisedName: "Revised.pdf",
            sourceRevisionID: sourceRevisionID,
            revisedRevisionID: revisedRevisionID,
            sourceFingerprint: sourceFingerprint,
            revisedFingerprint: revisedFingerprint,
            deliveryReceiptID: receiptID,
            changedPageCount: review.totalChangedPageCount,
            bodyByteCount: 2_048,
            bodySHA256: bodyHash
        )
        XCTAssertTrue(payload.isStructurallyValid(at: now.addingTimeInterval(1)))
        XCTAssertFalse(
            PDFChangeReportSignaturePayload(
                schema: payload.schema,
                reportID: payload.reportID,
                generatedAt: now.addingTimeInterval(6 * 60),
                sourceName: payload.sourceName,
                revisedName: payload.revisedName,
                sourceRevisionID: sourceRevisionID,
                revisedRevisionID: revisedRevisionID,
                sourceFingerprint: sourceFingerprint,
                revisedFingerprint: revisedFingerprint,
                deliveryReceiptID: receiptID,
                changedPageCount: review.totalChangedPageCount,
                bodyByteCount: 2_048,
                bodySHA256: bodyHash
            ).isStructurallyValid(at: now)
        )
        XCTAssertFalse(
            PDFChangeReportSignaturePayload(
                schema: payload.schema,
                reportID: payload.reportID,
                generatedAt: now,
                sourceName: "Source\nName.pdf",
                revisedName: payload.revisedName,
                sourceRevisionID: sourceRevisionID,
                revisedRevisionID: revisedRevisionID,
                sourceFingerprint: sourceFingerprint,
                revisedFingerprint: revisedFingerprint,
                deliveryReceiptID: receiptID,
                changedPageCount: review.totalChangedPageCount,
                bodyByteCount: PDFChangeReportSignaturePayload.maximumBodyBytes + 1,
                bodySHA256: bodyHash
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
    }

    func testTimeAnchoredReportVerificationAndTrustContracts_BitsUT() {
        let baseDate = Date(timeIntervalSince1970: 60_000)
        let anchor = PDFOfficeTimeAnchor(
            referenceDate: baseDate,
            systemUptime: 100
        )
        XCTAssertTrue(
            anchor.restoreTrustedDate(
                baseDate.addingTimeInterval(20)
            )
        )
        XCTAssertFalse(
            anchor.restoreTrustedDate(
                Date(timeIntervalSince1970: -1)
            )
        )
        XCTAssertEqual(
            anchor.trustedDate(
                wallDate: baseDate.addingTimeInterval(10),
                systemUptime: 130
            ),
            baseDate.addingTimeInterval(30)
        )
        XCTAssertTrue(
            anchor.hasWallClockRollback(
                wallDate: baseDate.addingTimeInterval(10),
                systemUptime: 130
            )
        )
        XCTAssertNil(
            anchor.evidenceIssuanceDate(
                wallDate: baseDate.addingTimeInterval(10),
                systemUptime: 130
            )
        )

        let freshAnchor = PDFOfficeTimeAnchor(
            referenceDate: baseDate,
            systemUptime: 100
        )
        let verified = PDFOfficeReportVerificationResult(
            status: .verified,
            packageID: UUID(),
            keyID: "0123456789abcdef",
            sourceCount: 1,
            outputCount: 1,
            createdAt: baseDate,
            expiresAt: baseDate.addingTimeInterval(60),
            verifiedAt: baseDate.addingTimeInterval(1),
            timeAnchor: freshAnchor,
            detail: "Verified",
            publicKeyBase64: "public",
            trustStatus: .unknown,
            trustedSignerName: nil
        )
        XCTAssertTrue(
            verified.canTrustSigner(
                at: baseDate.addingTimeInterval(10),
                systemUptime: 105
            )
        )
        XCTAssertEqual(
            verified.effectiveStatus(
                at: baseDate.addingTimeInterval(10),
                systemUptime: 170
            ),
            .expired
        )
        XCTAssertFalse(
            verified.canTrustSigner(
                at: baseDate.addingTimeInterval(10),
                systemUptime: 170
            )
        )
        XCTAssertEqual(
            verified.appendingDetail("Signed by Legal").detail,
            "Verified Signed by Legal"
        )
        let trusted = verified.updatingTrust(
            .trusted,
            signerName: "Legal Ops"
        )
        XCTAssertEqual(trusted.trustStatus, .trusted)
        XCTAssertEqual(trusted.trustedSignerName, "Legal Ops")
        XCTAssertFalse(
            trusted.canTrustSigner(
                at: baseDate.addingTimeInterval(10),
                systemUptime: 105
            )
        )
    }

    func testOfficeDeliveryPackageAndBatchRunContracts_BitsUT() {
        let now = Date(timeIntervalSince1970: 70_000)
        let packageID = UUID()
        let hash = String(repeating: "d", count: 64)
        let receiptID = UUID()
        let entry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Board deck",
            receiptID: receiptID,
            format: .powerPointPresentation,
            archiveName: "BoardDeck.pptx",
            byteCount: 4_096,
            sha256: hash
        )
        var package = PDFOfficeDeliveryPackage(
            id: packageID,
            createdAt: now,
            entries: [entry]
        )
        package.expiresAt = now.addingTimeInterval(3_600)
        package.archiveFileName = "\(packageID.uuidString).zip"
        package.reportFileName =
            "\(packageID.uuidString)-verification.json"
        package.byteCount = 8_192
        package.sha256 = hash
        package.reportSHA256 = String(repeating: "e", count: 64)
        package.signerKeyID = "0123456789abcdef"

        XCTAssertTrue(package.isStructurallyValid(at: now.addingTimeInterval(1)))
        XCTAssertFalse(package.isExpired(at: now.addingTimeInterval(60)))
        XCTAssertTrue(package.isExpired(at: now.addingTimeInterval(3_601)))
        XCTAssertEqual(package.sourceCount, 1)
        XCTAssertEqual(package.shortFingerprint, String(hash.prefix(12)))
        package.pinnedAt = now.addingTimeInterval(10)
        XCTAssertFalse(package.isExpired(at: now.addingTimeInterval(3_601)))
        XCTAssertTrue(package.isReportExpired(at: now.addingTimeInterval(3_601)))
        XCTAssertTrue(
            package.retentionSummary(
                at: now.addingTimeInterval(3_601)
            ).contains("Pinned")
        )

        var mismatchedReport = package
        mismatchedReport.reportFileName = "unexpected.json"
        XCTAssertFalse(
            mismatchedReport.isStructurallyValid(
                at: now.addingTimeInterval(1)
            )
        )
        var badSigner = package
        badSigner.signerKeyID = "short"
        XCTAssertFalse(
            badSigner.isStructurallyValid(at: now.addingTimeInterval(1))
        )

        let sourceID = UUID()
        let outputID = UUID()
        let item = PDFBatchDeliveryItem(
            sourceRecordID: sourceID,
            outputRecordID: outputID,
            stage: .verified,
            detail: "Verified",
            reviewPageIndex: nil,
            issue: nil
        )
        let run = PDFBatchDeliveryRun(
            id: UUID(),
            startedAt: now,
            updatedAt: now.addingTimeInterval(10),
            sourceRecordIDs: [sourceID],
            sourceRevisionIDs: [sourceID: UUID()],
            items: [item]
        )
        XCTAssertTrue(run.isStructurallyValid(at: now.addingTimeInterval(20)))
        XCTAssertFalse(run.needsRecovery)
        XCTAssertFalse(run.needsAttention)
        XCTAssertTrue(PDFBatchDeliveryStage.verified.isFinal)
        XCTAssertTrue(PDFBatchDeliveryStage.verified.isShareable)

        let blocked = PDFBatchDeliveryRun(
            id: run.id,
            startedAt: now,
            updatedAt: now.addingTimeInterval(10),
            sourceRecordIDs: [sourceID],
            sourceRevisionIDs: [sourceID: UUID()],
            items: [
                PDFBatchDeliveryItem(
                    sourceRecordID: sourceID,
                    outputRecordID: nil,
                    stage: .blocked,
                    detail: "Needs unlock",
                    reviewPageIndex: 0,
                    issue: .blocked("Password required")
                )
            ]
        )
        XCTAssertTrue(blocked.isStructurallyValid(at: now.addingTimeInterval(20)))
        XCTAssertFalse(blocked.needsRecovery)
        XCTAssertTrue(blocked.needsAttention)
        XCTAssertEqual(
            PDFBatchDeliveryIssue.cancelled.errorDescription,
            "Stopped: Processing stopped before this PDF finished"
        )

        let invalid = PDFBatchDeliveryRun(
            id: run.id,
            startedAt: now.addingTimeInterval(10),
            updatedAt: now,
            sourceRecordIDs: [sourceID],
            sourceRevisionIDs: [sourceID: UUID()],
            items: [
                PDFBatchDeliveryItem(
                    sourceRecordID: sourceID,
                    outputRecordID: sourceID,
                    stage: .failed,
                    detail: "Bad\nDetail",
                    reviewPageIndex: -1,
                    issue: .savingFailed("Disk full")
                )
            ]
        )
        XCTAssertFalse(invalid.isStructurallyValid(at: now.addingTimeInterval(20)))
    }

    func testArchiveNamesVerificationPayloadsAndStoragePressureContracts_BitsUT() {
        let now = Date(timeIntervalSince1970: 71_000)
        let packageID = UUID()
        let hash = String(repeating: "a", count: 64)

        func entry(
            name: String,
            receiptID: UUID = UUID(),
            sourceName: String = "Closing report",
            format: PDFTextExportFormat = .wordDocument,
            byteCount: Int64 = 4_096,
            sha256: String = hash
        ) -> PDFOfficeDeliveryEntry {
            PDFOfficeDeliveryEntry(
                sourceRecordID: UUID(),
                sourceRevisionID: UUID(),
                sourceName: sourceName,
                receiptID: receiptID,
                format: format,
                archiveName: name,
                byteCount: byteCount,
                sha256: sha256
            )
        }

        XCTAssertEqual(
            paperPathArchiveLeafNameIdentity("Report.DOCX"),
            "report.docx"
        )
        XCTAssertNil(paperPathArchiveLeafNameIdentity(" Report.docx"))
        XCTAssertNil(paperPathArchiveLeafNameIdentity(".Report.docx"))
        XCTAssertNil(paperPathArchiveLeafNameIdentity("folder/Report.docx"))
        XCTAssertNil(paperPathArchiveLeafNameIdentity("Report\u{202E}.docx"))

        let validPayload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: packageID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            verifiedOutputs: 1,
            files: [entry(name: "ClosingReport.docx")]
        )
        XCTAssertTrue(validPayload.isStructurallyValid(at: now.addingTimeInterval(1)))
        XCTAssertFalse(
            PDFOfficeVerificationPayload(
                schema: validPayload.schema,
                packageID: packageID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                verifiedOutputs: 2,
                files: validPayload.files
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
        XCTAssertFalse(
            PDFOfficeVerificationPayload(
                schema: validPayload.schema,
                packageID: packageID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                verifiedOutputs: 2,
                files: [
                    entry(name: "Report.docx"),
                    entry(name: "report.DOCX")
                ]
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
        XCTAssertFalse(
            PDFOfficeVerificationPayload(
                schema: validPayload.schema,
                packageID: packageID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(8 * 24 * 60 * 60),
                verifiedOutputs: 1,
                files: validPayload.files
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
        let oversizedEntries = (0..<9).map { index in
            entry(
                name: "Part\(index).docx",
                byteCount: PDFOfficeExternalMatchReport.maximumFileBytes
            )
        }
        XCTAssertFalse(
            PDFOfficeVerificationPayload(
                schema: validPayload.schema,
                packageID: packageID,
                createdAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                verifiedOutputs: oversizedEntries.count,
                files: oversizedEntries
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )

        var package = PDFOfficeDeliveryPackage(
            id: packageID,
            createdAt: now,
            entries: validPayload.files
        )
        package.expiresAt = now.addingTimeInterval(3_600)
        package.archiveFileName = "\(packageID.uuidString).zip"
        package.reportFileName = "\(packageID.uuidString)-verification.json"
        package.byteCount = 8_192
        package.sha256 = String(repeating: "b", count: 64)
        package.reportSHA256 = String(repeating: "c", count: 64)
        package.signerKeyID = "0123456789abcdef"
        XCTAssertTrue(package.isStructurallyValid(at: now.addingTimeInterval(1)))

        var futurePin = package
        futurePin.pinnedAt = now.addingTimeInterval(10 * 60)
        XCTAssertFalse(futurePin.isStructurallyValid(at: now.addingTimeInterval(1)))

        var badArchiveHash = package
        badArchiveHash.sha256 = String(repeating: "g", count: 64)
        XCTAssertFalse(badArchiveHash.isStructurallyValid(at: now.addingTimeInterval(1)))

        var oversizedPackage = PDFOfficeDeliveryPackage(
            id: packageID,
            createdAt: now,
            entries: oversizedEntries
        )
        oversizedPackage.expiresAt = package.expiresAt
        oversizedPackage.archiveFileName = package.archiveFileName
        oversizedPackage.reportFileName = package.reportFileName
        oversizedPackage.byteCount = PDFOfficeExternalMatchReport.maximumBatchBytes
        oversizedPackage.sha256 = package.sha256
        oversizedPackage.reportSHA256 = package.reportSHA256
        oversizedPackage.signerKeyID = package.signerKeyID
        XCTAssertFalse(oversizedPackage.isStructurallyValid(at: now.addingTimeInterval(1)))

        let officePressure = PDFOfficePinnedStorageSummary(
            outputCount: PDFOfficePinnedStorageSummary.maximumOutputCount - 4,
            byteCount: PDFOfficePinnedStorageSummary.maximumByteCount * 4 / 5
        )
        XCTAssertTrue(officePressure.isNearCapacity)
        XCTAssertFalse(officePressure.isAtCapacity)
        XCTAssertEqual(officePressure.remainingOutputCount, 4)
        XCTAssertEqual(
            officePressure.remainingByteCount,
            PDFOfficePinnedStorageSummary.maximumByteCount - officePressure.byteCount
        )
        XCTAssertFalse(
            PDFOfficePinnedStorageSummary(
                outputCount: PDFOfficePinnedStorageSummary.maximumOutputCount,
                byteCount: 0
            ).canAdd(bytes: 1)
        )
        XCTAssertFalse(
            PDFOfficePinnedStorageSummary(
                outputCount: 1,
                byteCount: Int64.max
            ).canAdd(bytes: 1)
        )

        let versionPressure = PDFPinnedVersionStorageSummary(
            milestoneCount: PDFPinnedVersionStorageSummary.maximumMilestoneCount,
            byteCount: -1
        )
        XCTAssertTrue(versionPressure.isAtCapacity)
        XCTAssertEqual(versionPressure.usageFraction, 0)
        XCTAssertEqual(versionPressure.remainingMilestoneCount, 0)
        XCTAssertFalse(versionPressure.canAdd(bytes: 0))
    }

    func testVersionSnapshotStorageAndArchiveVerificationContracts_BitsUT() {
        let now = Date(timeIntervalSince1970: 80_000)
        let documentID = UUID()
        let revisionID = UUID()
        let fingerprint = String(repeating: "f", count: 64)
        let receipt = PDFDeliveryReceipt(
            id: UUID(),
            operation: .safeShare,
            createdAt: now,
            sourcePageCount: 2,
            outputPageCount: 2,
            renderedPageCount: 2,
            sourceByteCount: 2_048,
            outputByteCount: 2_048,
            unexpectedBlankPageIndices: [],
            annotationCount: 0,
            textCharacterCount: 80,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: fingerprint,
            checks: [
                PDFDeliveryCheck(
                    id: "reopened",
                    title: "Reopened",
                    detail: "All pages opened.",
                    status: .passed
                )
            ],
            outputRevisionID: revisionID
        )
        let snapshot = PDFVersionSnapshot(
            id: UUID(),
            documentID: documentID,
            createdAt: now,
            label: "Import",
            fileName: "import.pdf",
            byteCount: 2_048,
            pageCount: 2,
            contentRevisionID: revisionID,
            contentFingerprint: fingerprint.uppercased(),
            bookmarkedPages: [0, 1],
            bookmarkNames: [0: "Cover"],
            lastPageIndex: 9,
            milestoneName: "   ",
            isPinned: nil,
            linkedDeliveryReceiptID: nil,
            linkedDeliveryReceipt: nil
        )
        XCTAssertNil(snapshot.resolvedMilestoneName)
        XCTAssertEqual(
            snapshot.displayTitle,
            AppLocalization.format("Before %@", snapshot.label.localizedUI)
        )
        XCTAssertTrue(snapshot.matchesDeliveryReceipt(receipt))
        XCTAssertEqual(snapshot.updatingMeasuredByteCount(-1).byteCount, 0)

        let pinned = snapshot.updatingMilestone(
            name: "  Closing package  ",
            pinned: true,
            linkedDeliveryReceiptID: receipt.id,
            deliveryReceipt: receipt
        )
        XCTAssertTrue(pinned.isPinnedMilestone)
        XCTAssertEqual(pinned.resolvedMilestoneName, "Closing package")
        XCTAssertNotNil(pinned.archivedDeliveryReceipt)
        let unpinned = pinned.updatingMilestone(
            name: nil,
            pinned: false,
            linkedDeliveryReceiptID: receipt.id,
            deliveryReceipt: receipt
        )
        XCTAssertFalse(unpinned.isPinnedMilestone)
        XCTAssertNil(unpinned.archivedDeliveryReceipt)

        let measured = PDFPinnedVersionStorageSummary.measuring([
            pinned,
            snapshot.updatingMeasuredByteCount(-128)
        ])
        XCTAssertEqual(measured.milestoneCount, 2)
        XCTAssertEqual(measured.byteCount, pinned.byteCount)
        XCTAssertTrue(
            PDFPinnedVersionStorageSummary(
                milestoneCount: 31,
                byteCount: 1
            ).isNearCapacity
        )
        XCTAssertFalse(
            PDFPinnedVersionStorageSummary(
                milestoneCount: 32,
                byteCount: 0
            ).canAdd(bytes: 1)
        )

        let item = PDFVersionArchiveVerificationItem(
            id: UUID(),
            documentID: documentID,
            fileName: "import.pdf",
            title: "Closing package",
            byteCount: 2_048,
            pageCount: 2,
            expectedSHA256: fingerprint,
            actualSHA256: fingerprint,
            linkedDeliveryReceiptID: receipt.id,
            status: .verified,
            detail: "Verified"
        )
        let artifactURL = URL(fileURLWithPath: "/tmp/import.pdf")
        let report = PDFVersionArchiveVerificationReport(
            archiveName: "versions.zip",
            archiveByteCount: 4_096,
            schema: PDFVersionArchiveManifest.currentSchema,
            archiveCreatedAt: now,
            verifiedAt: now.addingTimeInterval(1),
            manifestEntryCount: 1,
            archiveEntryCount: 1,
            items: [item],
            structuralFailures: [],
            signatureStatus: .verified,
            signatureDetail: "Signature verified",
            signerKeyID: "0123456789abcdef",
            signerPublicKeyBase64: "public",
            trustStatus: .unknown,
            trustedSignerName: nil,
            verifiedArtifacts: [
                PDFVersionArchiveVerifiedArtifact(
                    item: item,
                    url: artifactURL
                )
            ]
        )
        XCTAssertEqual(report.status, .verified)
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(report.canTrustSigner)
        XCTAssertTrue(report.canRecoverArtifacts)
        XCTAssertEqual(report.verifiedArtifact(for: item.id)?.url, artifactURL)
        XCTAssertEqual(
            report.resolvingTrust(
                .trusted,
                trustedSignerName: "Legal Ops"
            ).provenanceTitle,
            "Legal Ops"
        )
        XCTAssertFalse(report.removingVerifiedArtifacts().canRecoverArtifacts)

        let invalidSignatureReport = PDFVersionArchiveVerificationReport(
            archiveName: "versions.zip",
            archiveByteCount: 4_096,
            schema: PDFVersionArchiveManifest.currentSchema,
            archiveCreatedAt: now,
            verifiedAt: now.addingTimeInterval(1),
            manifestEntryCount: 1,
            archiveEntryCount: 1,
            items: [item],
            structuralFailures: [],
            signatureStatus: .invalid,
            signatureDetail: "Signature mismatch",
            signerKeyID: "0123456789abcdef",
            signerPublicKeyBase64: "public",
            trustStatus: .invalid,
            trustedSignerName: nil
        )
        XCTAssertEqual(invalidSignatureReport.status, .failed)
        XCTAssertEqual(invalidSignatureReport.failedCount, 1)
        XCTAssertEqual(
            invalidSignatureReport.provenanceTitle,
            "Invalid source signature"
        )
        XCTAssertEqual(
            PDFVersionArchiveVerificationReport(
                archiveName: "legacy.zip",
                archiveByteCount: 2_048,
                schema: "PaperPath Version Archive V47",
                archiveCreatedAt: now,
                verifiedAt: now.addingTimeInterval(1),
                manifestEntryCount: 1,
                archiveEntryCount: 1,
                items: [item],
                structuralFailures: []
            ).provenanceTitle,
            "Unsigned legacy archive"
        )
    }

    func testDocumentRoute_repeatedQuickTaskHasFreshInvocationIdentity_BitsUT() {
        let recordID = UUID()
        let revisionID = UUID()
        let firstRead = DocumentRoute(
            recordID: recordID,
            pageIndex: 4
        )
        let secondRead = DocumentRoute(
            recordID: recordID,
            pageIndex: 4
        )
        let firstTask = DocumentRoute(
            recordID: recordID,
            pageIndex: 4,
            quickTask: .protectPDF
        )
        let secondTask = DocumentRoute(
            recordID: recordID,
            pageIndex: 4,
            quickTask: .protectPDF
        )

        XCTAssertEqual(firstRead, secondRead)
        XCTAssertNotEqual(firstTask, secondTask)

        let reboundTask = firstTask.bindingExpectedRevision(revisionID)
        XCTAssertEqual(
            reboundTask.bindingExpectedRevision(revisionID),
            reboundTask
        )
        XCTAssertNotEqual(reboundTask, secondTask)
    }

    func testDocumentBriefProfileAndNoticeContracts_BitsUT() {
        let recordID = UUID()
        XCTAssertEqual(
            AppNoticeAction.restoreTrash(recordIDs: [recordID]).title,
            "Restore"
        )
        XCTAssertEqual(
            AppNoticeAction.undoPageChange(recordID: recordID).title,
            "Undo"
        )
        XCTAssertEqual(PDFQuickTaskGroup.finish.title, "Finish & protect")
        XCTAssertFalse(PDFQuickTask.mergePDFs.requiresDocument)
        XCTAssertTrue(PDFQuickTask.safeShare.requiresDocument)
        XCTAssertEqual(PDFQuickTask.redactPDF.group, .finish)

        XCTAssertEqual(DocumentCategory.invoice.title, "Invoice")
        XCTAssertEqual(DocumentCategory.invoice.symbol, "doc.text.below.ecg")
        XCTAssertEqual(IndexedTextSource.searchableCopy.title, "Searchable PDF text")
        XCTAssertEqual(DocumentUnderstandingConfidence.medium.symbol, "circle.lefthalf.filled")
        XCTAssertTrue(DetectedEntity.Kind.email.isSensitive)
        XCTAssertFalse(DetectedEntity.Kind.amount.isSensitive)
        XCTAssertEqual(SuggestedStep.Kind.reviewSignature.symbol, "signature")

        let brief = DocumentBrief(
            category: .invoice,
            summary: "",
            entities: [
                DetectedEntity(kind: .email, value: "legal@example.com"),
                DetectedEntity(kind: .amount, value: "$400")
            ],
            suggestedSteps: [
                SuggestedStep(
                    kind: .reviewAmount,
                    title: "Review amount",
                    evidence: "$400",
                    evidencePageIndex: 0
                )
            ],
            indexedAt: Date(timeIntervalSince1970: 90_000),
            textSource: .vision,
            indexedCharacterCount: 0,
            confidence: nil
        )
        XCTAssertTrue(brief.hasUsefulContent)
        XCTAssertEqual(brief.resolvedConfidence, .low)
        XCTAssertEqual(brief.sensitiveEntityCount, 1)

        let emptyBrief = DocumentBrief(
            category: .general,
            summary: "",
            entities: [],
            suggestedSteps: [],
            indexedAt: Date(timeIntervalSince1970: 90_001),
            textSource: nil,
            indexedCharacterCount: 0,
            confidence: .high
        )
        XCTAssertFalse(emptyBrief.hasUsefulContent)
        XCTAssertEqual(emptyBrief.resolvedConfidence, .high)

        var lockedProfile = makeProfile(pageCount: 1)
        lockedProfile.isLocked = true
        XCTAssertEqual(
            lockedProfile.summary,
            "Unlock this PDF before PaperPath can inspect its contents."
                .localizedUI
        )
        var singleFieldProfile = makeProfile(pageCount: 1)
        singleFieldProfile.kind = .form
        singleFieldProfile.formFieldCount = 1
        XCTAssertFalse(singleFieldProfile.summary.isEmpty)
        XCTAssertTrue(singleFieldProfile.summary.contains("1"))
    }

    func testOfficeResourceForecastRuntimeAndVisualBudgetContracts_BitsUT() {
        XCTAssertEqual(PDFOfficeResourceSnapshot.initial.formattedAvailableCapacity, "Checking")
        let resource = PDFOfficeResourceSnapshot(
            mode: .conserving,
            thermalLevel: .fair,
            isLowPowerModeEnabled: true,
            availableCapacityBytes: 2_048,
            capturedAt: Date(timeIntervalSince1970: 91_000),
            detail: "Device is warm"
        )
        XCTAssertEqual(resource.mode.title, "Conserving")
        XCTAssertEqual(resource.mode.symbol, "leaf.fill")
        XCTAssertEqual(resource.thermalLevel.title, "Device warm")
        XCTAssertEqual(resource.powerTitle, "Low Power")
        XCTAssertFalse(resource.formattedAvailableCapacity.isEmpty)

        let forecast = PDFOfficeStorageForecast(
            sourceCount: 3,
            packageCount: 2,
            estimatedOutputBytes: 10 * 1_024,
            requiredWorkingBytes: 90 * 1_024,
            availableCapacityBytes: 80 * 1_024
        )
        XCTAssertFalse(forecast.hasCapacity)
        XCTAssertTrue(
            PDFOfficeStorageForecast(
                sourceCount: 1,
                packageCount: 1,
                estimatedOutputBytes: 1,
                requiredWorkingBytes: 2,
                availableCapacityBytes: nil
            ).hasCapacity
        )
        XCTAssertTrue(forecast.contract.contains("streamed commit".localizedUI))
        XCTAssertEqual(PDFOfficeIntegrityStatus.mismatch.title, "Hash mismatch")
        XCTAssertEqual(PDFOfficeIntegrityStatus.verified.symbol, "checkmark.shield.fill")
        XCTAssertTrue(PDFOfficeIntegrityStatus.verified.isVerified)
        XCTAssertFalse(PDFOfficeIntegrityStatus.sourceChanged.isVerified)
        XCTAssertEqual(
            PDFOfficeIntegrityReport(
                checkedCount: 2,
                verifiedCount: 2,
                failedCount: 0,
                checkedAt: Date(timeIntervalSince1970: 91_100)
            ).summary,
            AppLocalization.format(
                "%lld/%lld outputs verified",
                2,
                2
            )
        )
        XCTAssertFalse(
            PDFOfficeIntegrityReport(
                checkedCount: 0,
                verifiedCount: 0,
                failedCount: 0,
                checkedAt: Date(timeIntervalSince1970: 91_101)
            ).isVerified
        )

        let runtimeEvidence = PDFOfficeRuntimeEvidence(
            sourcePageCount: 2,
            outputPageCount: 5,
            primaryUnitLabel: "paragraphs",
            primaryUnitCount: 12,
            characterCount: 200,
            searchablePageCount: 4,
            assetCount: 2,
            assetByteCount: 9,
            assetBudgetByteCount: 6,
            assetCompressionFallbackCount: 1,
            assetMinimumQualityPercent: 46
        )
        XCTAssertEqual(runtimeEvidence.pageYieldPercent, 100)
        XCTAssertEqual(runtimeEvidence.searchableCoveragePercent, 80)
        XCTAssertEqual(runtimeEvidence.assetBudgetUsePercent, 100)
        XCTAssertEqual(
            runtimeEvidence.yieldSummary,
            AppLocalization.format(
                "%lld/%lld pages · %lld%% yield",
                5,
                2,
                100
            )
        )
        XCTAssertEqual(
            PDFOfficeRuntimeEvidence(
                sourcePageCount: 0,
                outputPageCount: 0,
                primaryUnitLabel: "pages",
                primaryUnitCount: 0,
                characterCount: 0,
                searchablePageCount: 0,
                assetCount: 0,
                assetByteCount: 0,
                assetBudgetByteCount: 0,
                assetCompressionFallbackCount: 0,
                assetMinimumQualityPercent: 0
            ).formattedAssetBudget,
            "No visual budget"
        )

        XCTAssertEqual(PDFOfficeVisualBudgetMode(pageCount: 24), .highDetail)
        XCTAssertEqual(PDFOfficeVisualBudgetMode(pageCount: 25), .balanced)
        XCTAssertEqual(PDFOfficeVisualBudgetMode(pageCount: 101), .bounded)
        XCTAssertEqual(PDFOfficeVisualBudgetMode(pageCount: 301), .largeDocument)
        XCTAssertEqual(
            PDFOfficeVisualBudgetPressure(
                estimatedVisualBytes: 35,
                totalBudgetBytes: 100
            ),
            .relaxed
        )
        XCTAssertEqual(
            PDFOfficeVisualBudgetPressure(
                estimatedVisualBytes: 36,
                totalBudgetBytes: 100
            ),
            .managed
        )
        XCTAssertEqual(
            PDFOfficeVisualBudgetPressure(
                estimatedVisualBytes: 74,
                totalBudgetBytes: 100
            ),
            .tight
        )

        var scanProfile = makeProfile(pageCount: 12)
        scanProfile.sampledPageCount = 12
        scanProfile.imageDominantPageCount = 12
        XCTAssertEqual(PDFOfficeVisualAnchorPolicy(profile: scanProfile), .scanFirst)

        var imageProfile = makeProfile(pageCount: 12)
        imageProfile.sampledPageCount = 12
        imageProfile.imageDominantPageCount = 2
        XCTAssertEqual(PDFOfficeVisualAnchorPolicy(profile: imageProfile), .imageFirst)

        var mixedProfile = makeProfile(pageCount: 12)
        mixedProfile.sampledPageCount = 10
        mixedProfile.imageDominantPageCount = 6
        XCTAssertEqual(PDFOfficeVisualAnchorPolicy(profile: mixedProfile), .tableAware)
        XCTAssertEqual(
            PDFOfficeVisualAnchorPolicy(profile: makeProfile(pageCount: 12)),
            .structureFirst
        )

        let largePlan = PDFOfficeVisualBudgetPlan(profile: makeProfile(pageCount: 640))
        XCTAssertEqual(largePlan.mode, .largeDocument)
        XCTAssertEqual(largePlan.chunkCount, 6)
        XCTAssertEqual(largePlan.maximumBytesPerPage, 160 * 1_024)
        XCTAssertTrue(
            largePlan.memoryGuardSummary.contains(
                PDFOfficeVisualBudgetMode.largeDocument.title.localizedUI
            )
        )
        XCTAssertEqual(
            PDFOfficeProductionSLA(
                pageCount: 10,
                sourceBytes: 1_024,
                visualBudgetPlan: PDFOfficeVisualBudgetPlan(
                    profile: makeProfile(pageCount: 10)
                ),
                isProtected: false
            ),
            .quick
        )
        XCTAssertEqual(
            PDFOfficeProductionSLA(
                pageCount: 320,
                sourceBytes: 1_024,
                visualBudgetPlan: largePlan,
                isProtected: false
            ),
            .heavy
        )
        XCTAssertEqual(
            PDFOfficeProductionSLA(
                pageCount: 1,
                sourceBytes: 1,
                visualBudgetPlan: largePlan,
                isProtected: true
            ),
            .constrained
        )
    }

    func testTextImagePrintAndBookletPureContracts_BitsUT() {
        XCTAssertEqual(PDFTextReplacementFontStyle.monospaced.pdfFontName, "Menlo-Regular")
        XCTAssertEqual(PDFTextReplacementAlignment.center.symbol, "text.aligncenter")
        let color = PDFInkColor(red: 1, green: 1, blue: 1, alpha: 1)
        let readyAssessment = PDFTextReplacementAssessment(
            status: .ready,
            title: "Ready",
            detail: "Two lines",
            resolvedFontName: "Helvetica",
            resolvedFontSize: 13,
            resolvedLineSpacing: 3,
            reflowedLineCount: 2,
            backgroundColor: color,
            regionBackgroundColors: [color, color],
            flowRegionTexts: ["First", "Second"],
            fontStyle: .sans,
            alignment: .left
        )
        XCTAssertTrue(readyAssessment.isReady)
        XCTAssertFalse(
            PDFTextReplacementAssessment(
                status: .ready,
                title: "Blocked",
                detail: "Missing background",
                resolvedFontName: nil,
                resolvedFontSize: 0,
                resolvedLineSpacing: 0,
                reflowedLineCount: 0,
                backgroundColor: nil,
                regionBackgroundColors: [],
                flowRegionTexts: ["Text"],
                fontStyle: .serif,
                alignment: .right
            ).isReady
        )

        let bounds = PDFNormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let image = PDFImageObjectSnapshot(
            pageIndex: 0,
            objectNumber: 7,
            generation: 0,
            resourceName: "Im0",
            normalizedBounds: bounds,
            pixelWidth: 200,
            pixelHeight: 100,
            jpegData: Data([1]),
            sourceStreamData: Data([2]),
            softMaskStreamData: nil,
            softMaskObjectNumber: nil,
            softMaskGeneration: nil,
            storage: .jpeg,
            sourceDigest: "digest",
            usageCount: 2
        )
        XCTAssertEqual(image.id, "7-0-0-Im0")
        XCTAssertTrue(image.isSafelyReplaceable)
        XCTAssertTrue(image.replacesMultipleUses)
        XCTAssertFalse(
            PDFImageObjectSnapshot(
                pageIndex: 0,
                objectNumber: 8,
                generation: 0,
                resourceName: "Im1",
                normalizedBounds: bounds,
                pixelWidth: 200,
                pixelHeight: 100,
                jpegData: Data([1]),
                sourceStreamData: Data([2]),
                softMaskStreamData: nil,
                softMaskObjectNumber: nil,
                softMaskGeneration: nil,
                storage: .flateWithSoftMask,
                sourceDigest: "digest",
                usageCount: 1
            ).isSafelyReplaceable
        )

        XCTAssertEqual(
            PDFPrintPreparationOptions(
                paperTarget: .letter,
                orientation: .landscape,
                scaleMode: .fill,
                marginPoints: 96
            ).clampedMarginPoints,
            72
        )
        let riskEvidence = PDFPrintProductionEvidence(
            pageIndex: 0,
            trimBoxInsetPoints: PDFPageCropInsets(
                top: 1,
                right: 2,
                bottom: 3,
                left: 4
            ),
            bleedInsetPoints: .none,
            requiredBleedPoints: 3,
            requiredSafeAreaPoints: 18,
            nearestContentToTrimPoints: 12,
            hasExplicitTrimBox: true,
            hasBleedAllowance: false,
            safeAreaRisk: .clear,
            bleedRisk: .risk
        )
        XCTAssertEqual(riskEvidence.overallRisk, .risk)
        XCTAssertEqual(
            riskEvidence.trimSummary,
            AppLocalization.format(
                "T%.0f R%.0f B%.0f L%.0f pt",
                1.0,
                2.0,
                3.0,
                4.0
            )
        )
        XCTAssertEqual(riskEvidence.bleedSummary, "Missing")
        XCTAssertEqual(
            riskEvidence.safeAreaSummary,
            AppLocalization.format("%.0f pt", 12.0)
        )
        let clearEvidence = PDFPrintProductionEvidence(
            pageIndex: 1,
            trimBoxInsetPoints: .none,
            bleedInsetPoints: .none,
            requiredBleedPoints: 0,
            requiredSafeAreaPoints: 0,
            nearestContentToTrimPoints: nil,
            hasExplicitTrimBox: false,
            hasBleedAllowance: true,
            safeAreaRisk: .clear,
            bleedRisk: .clear
        )
        XCTAssertEqual(clearEvidence.overallRisk, .clear)
        XCTAssertEqual(clearEvidence.trimSummary, "Crop box")
        XCTAssertEqual(clearEvidence.safeAreaSummary, "No text/fields")

        let riskPage = PDFPrintPreparationPage(
            pageIndex: 0,
            sourceWidth: 612,
            sourceHeight: 792,
            outputWidth: 612,
            outputHeight: 792,
            printableWidth: 560,
            printableHeight: 740,
            renderedWidth: 550,
            renderedHeight: 700,
            scale: 0.95,
            visibleFraction: 0.96,
            productionEvidence: riskEvidence
        )
        XCTAssertTrue(riskPage.hasClipping)
        XCTAssertTrue(riskPage.isScaled)
        XCTAssertTrue(riskPage.hasPadding)
        XCTAssertEqual(riskPage.outcomeTitle, "Preflight risk")
        let actualPage = PDFPrintPreparationPage(
            pageIndex: 1,
            sourceWidth: 612,
            sourceHeight: 792,
            outputWidth: 612,
            outputHeight: 792,
            printableWidth: 612,
            printableHeight: 792,
            renderedWidth: 612,
            renderedHeight: 792,
            scale: 1,
            visibleFraction: 1,
            productionEvidence: clearEvidence
        )
        XCTAssertEqual(actualPage.outcomeTitle, "Actual size")
        let printAssessment = PDFPrintPreparationAssessment(
            revisionID: UUID(),
            options: .standard,
            annotationCount: 1,
            pages: [riskPage, actualPage]
        )
        XCTAssertEqual(printAssessment.clippedPageCount, 1)
        XCTAssertEqual(printAssessment.scaledPageCount, 1)
        XCTAssertEqual(printAssessment.paddedPageCount, 1)
        XCTAssertEqual(printAssessment.productionRiskPageCount, 1)
        XCTAssertEqual(printAssessment.productionReviewPageCount, 1)
        XCTAssertEqual(printAssessment.averageScalePercent, 98)

        let pageItem = PDFPagePreparationItem(
            pageIndex: 0,
            widthPoints: 842,
            heightPoints: 595,
            rotation: 90,
            paperClass: .a4,
            detectedInsets: PDFPageCropInsets(
                top: 0.02,
                right: 0.03,
                bottom: 0.04,
                left: 0.05
            ),
            confidence: .high,
            inkCoverage: 0.12
        )
        XCTAssertTrue(pageItem.isLandscape)
        XCTAssertEqual(pageItem.orientationTitle, "Landscape")
        XCTAssertTrue(pageItem.isSuggested(safetyPadding: 0))
        let preparation = PDFPagePreparationAssessment(
            revisionID: UUID(),
            pages: [pageItem]
        )
        XCTAssertEqual(preparation.geometryVariantCount, 1)
        XCTAssertEqual(preparation.suggestedPageCount(safetyPadding: 0), 1)
        XCTAssertEqual(
            PDFExternalPageSource(
                id: UUID(),
                url: URL(fileURLWithPath: "/tmp/external.pdf"),
                displayName: "External",
                byteCount: 1_024,
                assessment: preparation
            ).pageCount,
            1
        )

        let bookletOptions = PDFBookletOptions(
            paperTarget: .letter,
            bindingEdge: .right,
            outerMarginPoints: 1,
            gutterPoints: 99,
            showsFoldMarks: true,
            signatureSheetLimit: 99,
            creepCompensationPoints: -4
        )
        XCTAssertEqual(bookletOptions.clampedOuterMarginPoints, 12)
        XCTAssertEqual(bookletOptions.clampedGutterPoints, 48)
        XCTAssertEqual(bookletOptions.normalizedSignatureSheetLimit, 32)
        XCTAssertEqual(bookletOptions.clampedCreepCompensationPoints, 0)
        let slot = PDFBookletSlot(
            sourcePageIndex: 3,
            scale: 0.96,
            visibleFraction: 1,
            creepOffsetPoints: -2.4
        )
        let blank = PDFBookletSlot(
            sourcePageIndex: nil,
            scale: 1,
            visibleFraction: 1,
            creepOffsetPoints: 0
        )
        let spread = PDFBookletSpread(
            outputPageIndex: 0,
            signatureNumber: 1,
            signatureSheetCount: 2,
            sheetNumber: 1,
            side: .front,
            left: slot,
            right: blank,
            sheetWidth: 792,
            sheetHeight: 612
        )
        XCTAssertTrue(spread.hasBlankSlot)
        XCTAssertEqual(spread.pageOrderLabel, "4 · Blank")
        let bookletAssessment = PDFBookletAssessment(
            revisionID: UUID(),
            options: bookletOptions,
            sourcePageCount: 5,
            paddedPageCount: 8,
            annotationCount: 1,
            spreads: [spread]
        )
        XCTAssertEqual(bookletAssessment.signatureCount, 1)
        XCTAssertEqual(bookletAssessment.insertedBlankCount, 3)
        XCTAssertEqual(bookletAssessment.sheetCount, 2)
        XCTAssertEqual(bookletAssessment.outputPageCount, 1)
        XCTAssertEqual(bookletAssessment.maximumCreepOffsetPoints, 2)
        XCTAssertEqual(bookletAssessment.largestSignatureSheetCount, 2)
        XCTAssertEqual(bookletAssessment.averageScalePercent, 96)
    }

    func testOverlayFormAnnotationAndPageLabelContracts_BitsUT()
        throws {
        let clamped = PDFNormalizedRect(
            x: -0.5,
            y: 2,
            width: 0.01,
            height: 3
        )
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.y, 0)
        XCTAssertEqual(clamped.width, 0.08)
        XCTAssertEqual(clamped.height, 1)

        let webURL = try XCTUnwrap(URL(string: "https://example.com/sign"))
        XCTAssertEqual(
            PDFContentOverlay.text(
                pageIndex: 3,
                bounds: clamped,
                text: "Approved",
                fontSize: 12,
                color: PDFInkColor(red: 0, green: 0, blue: 0, alpha: 1)
            ).pageIndex,
            3
        )
        XCTAssertEqual(PDFLinkTarget.web(webURL).title, webURL.absoluteString)
        XCTAssertEqual(PDFLinkTarget.page(4).title, "Page 5")
        XCTAssertFalse(PDFLinkTarget.unsupported("Launch action").isEditable)
        XCTAssertEqual(
            PDFLinkAnnotationSnapshot(
                pageIndex: 2,
                annotationIndex: 5,
                normalizedBounds: clamped,
                title: "Clause",
                target: .page(0)
            ).id,
            "2-5"
        )
        XCTAssertEqual(PDFSignatureSize.large.pageWidthFraction, 0.54)
        XCTAssertEqual(PDFSignaturePosition.center.title, "Center")
        XCTAssertEqual(
            PDFInkPayload(
                pageIndex: 1,
                strokes: [
                    PDFInkStroke(
                        points: [PDFInkPoint(x: 0.1, y: 0.2)],
                        color: PDFInkColor(red: 0, green: 0, blue: 1, alpha: 1),
                        normalizedLineWidth: 0.02
                    )
                ],
                placement: .signature,
                signaturePosition: .right,
                signatureSize: .compact,
                normalizedBounds: clamped
            ).signatureSize,
            .compact
        )

        XCTAssertTrue(PDFFormFieldKind.signature.canCreate)
        XCTAssertFalse(PDFFormFieldKind.button.canCreate)
        XCTAssertEqual(PDFFormCompatibility.limited.symbol, "exclamationmark.triangle")
        XCTAssertEqual(PDFFormCalculationOperation.average.title, "Average")
        XCTAssertEqual(PDFFormFormatKind.percent.title, "Percent")

        let required = PDFFormFieldSnapshot(
            id: "required",
            pageIndex: 0,
            annotationIndex: 0,
            name: "Approval",
            kind: .text,
            value: "   ",
            normalizedBounds: clamped,
            isRequired: true,
            isReadOnly: true,
            isMultiline: false,
            maximumLength: 80,
            optionCount: 0,
            hasAppearanceStream: false,
            issue: "Read only"
        )
        let optional = PDFFormFieldSnapshot(
            id: "optional",
            pageIndex: 0,
            annotationIndex: 1,
            name: "Total",
            kind: .choice,
            value: nil,
            normalizedBounds: clamped,
            isRequired: false,
            isReadOnly: false,
            isMultiline: false,
            maximumLength: nil,
            optionCount: 3,
            hasAppearanceStream: true,
            issue: nil
        )
        let complete = PDFFormFieldSnapshot(
            id: "complete",
            pageIndex: 0,
            annotationIndex: 2,
            name: "Accepted",
            kind: .checkbox,
            value: "Yes",
            normalizedBounds: clamped,
            isRequired: false,
            isReadOnly: false,
            isMultiline: false,
            maximumLength: nil,
            optionCount: 0,
            hasAppearanceStream: true,
            issue: nil
        )
        let calculation = PDFFormCalculationRule(
            operation: .sum,
            sourceFieldNames: ["Subtotal", "Tax"]
        )
        let format = PDFFormFormatRule(
            kind: .number,
            decimalPlaces: 2,
            separatorStyle: 0,
            negativeStyle: 0,
            currencySymbol: "$",
            currencyPrecedesValue: true,
            pattern: nil
        )
        let range = PDFFormRangeValidationRule(minimum: 0, maximum: 100)
        let automation = PDFFormAutomationFieldSnapshot(
            fieldID: optional.id,
            fieldName: "Total",
            calculation: calculation,
            format: format,
            rangeValidation: range,
            expectedValue: "128",
            formattedPreview: "$128.00",
            needsUpdate: true,
            validationIssue: nil,
            unsupportedActionCount: 0
        )
        let invalidAutomation = PDFFormAutomationFieldSnapshot(
            fieldID: required.id,
            fieldName: "Approval",
            calculation: nil,
            format: nil,
            rangeValidation: range,
            expectedValue: nil,
            formattedPreview: nil,
            needsUpdate: false,
            validationIssue: "Out of range",
            unsupportedActionCount: 1
        )
        let unsupportedAutomation = PDFFormAutomationFieldSnapshot(
            fieldID: "script",
            fieldName: "Legacy script",
            calculation: nil,
            format: nil,
            rangeValidation: nil,
            expectedValue: nil,
            formattedPreview: nil,
            needsUpdate: true,
            validationIssue: nil,
            unsupportedActionCount: 2
        )
        let report = PDFFormInspectionReport(
            fields: [required, optional, complete],
            automationFields: [automation, invalidAutomation, unsupportedAutomation],
            compatibility: .limited,
            issues: ["XFA fallback"],
            hasXFA: true,
            hasJavaScript: true,
            needsAppearances: true,
            unsupportedJavaScriptCount: 1
        )
        XCTAssertEqual(report.incompleteRequiredFields.map(\.id), [required.id])
        XCTAssertEqual(report.incompleteOptionalFields.map(\.id), [optional.id])
        XCTAssertEqual(report.editableFieldCount, 2)
        XCTAssertEqual(report.fieldsNeedingAutomationUpdate.map(\.id), [optional.id])
        XCTAssertEqual(report.invalidAutomationFields.map(\.id), [required.id])
        XCTAssertEqual(report.supportedAutomationFields.count, 2)
        XCTAssertEqual(report.automation(for: optional)?.fieldName, "Total")
        XCTAssertFalse(report.isReadyForVerifiedOutput)
        XCTAssertTrue(report.requiresCompatibleReader)
        XCTAssertFalse(PDFFormInspectionReport.empty.isReadyForVerifiedOutput)

        let color = PDFInkColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)
        let annotation = PDFAnnotationSnapshot(
            pageIndex: 1,
            annotationIndex: 2,
            type: "Highlight",
            contents: "Review",
            generatedKind: .pageNumber,
            color: color,
            lineWidth: 2,
            hasAppearanceStream: true,
            canEditContents: false,
            canEditStyle: true,
            canRemove: true
        )
        XCTAssertEqual(annotation.id, "1-2-Highlight")
        XCTAssertTrue(annotation.canEdit)
        XCTAssertEqual(
            PDFAnnotationRemovalTarget(annotation: annotation).expectedGeneratedKind,
            .pageNumber
        )
        XCTAssertEqual(
            PDFGeneratedAnnotationKind.resolve(author: PDFGeneratedAnnotationKind.watermark.author),
            .watermark
        )
        let attachment = PDFEmbeddedAttachmentSnapshot(
            id: "attachment-1",
            fileName: "evidence.csv",
            contentType: "text/csv",
            byteCount: 1_536,
            checksum: String(repeating: "a", count: 64),
            description: nil,
            pageIndex: 1,
            origin: .pageAnnotation,
            isExtractable: true,
            limitation: nil
        )
        XCTAssertEqual(attachment.origin.title, "Page attachment")
        XCTAssertFalse(attachment.formattedSize.isEmpty)

        XCTAssertEqual(PDFPageLabelStyle.uppercaseRoman.formattedNumber(4), "IV")
        XCTAssertEqual(
            PDFPageLabelStyle.uppercaseRoman.formattedNumber(4_000),
            "MMMCMXCIX"
        )
        XCTAssertEqual(PDFPageLabelStyle.lowercaseLetters.formattedNumber(27), "aa")
        XCTAssertNil(PDFPageLabelStyle.prefixOnly.pdfName)
        let rule = PDFPageLabelRule(
            startPageIndex: 2,
            style: .uppercaseLetters,
            prefix: "A-",
            startNumber: 27
        )
        XCTAssertEqual(rule.label(for: 1), "A-AA")
        XCTAssertEqual(rule.label(for: 3), "A-AB")
        XCTAssertEqual(PDFWatermarkPreset.internalUse.defaultText, "INTERNAL USE")
        XCTAssertEqual(PDFWatermarkLayout.diagonal.rotationDegrees, 315)
        XCTAssertEqual(PDFWatermarkIntensity.bold.scale, 1.16)
    }

    func testCommandSourceStorageAndOCRContracts_BitsUT()
        throws {
        XCTAssertEqual(DocumentWorkflowStatus.archived.symbol, "archivebox")
        XCTAssertEqual(DocumentTaskStage.verify.action, .safeShare)
        XCTAssertEqual(DocumentTaskStage.verify.quickTask, .safeShare)
        XCTAssertEqual(
            DocumentTaskCheckpoint(
                stage: .verify,
                pageIndex: 2,
                updatedAt: Date(timeIntervalSince1970: 1)
            ).resumeReason,
            "Check the final copy before sharing on page 3"
        )
        XCTAssertEqual(
            DocumentTaskCheckpoint(
                stage: .sign,
                pageIndex: 1,
                fieldName: "Approval signature",
                updatedAt: Date(timeIntervalSince1970: 1)
            ).resumeReason,
            AppLocalization.format(
                "%@ · page %lld",
                "Approval signature",
                2
            )
        )
        XCTAssertEqual(DocumentCommandReadiness.blocked.symbol, "xmark.octagon.fill")
        let commandProfile = DocumentCommandProfile(
            readiness: .review,
            score: 82,
            primaryTitle: "Review evidence",
            primaryDetail: "One receipt changed",
            primarySymbol: "exclamationmark.triangle.fill",
            officeRoute: "DOCX",
            officeDetail: "Segmented export",
            signals: [
                DocumentCommandSignal(
                    id: "receipt",
                    title: "Receipt",
                    value: "Stale",
                    detail: "Output changed",
                    symbol: "clock.badge.exclamationmark",
                    readiness: .review
                )
            ]
        )
        XCTAssertEqual(commandProfile.scoreLabel, "82")
        XCTAssertEqual(commandProfile.compactLine, "Review 82 · DOCX")

        let emptySummary = LibraryCommandSummary(
            readiness: .ready,
            score: 100,
            totalCount: 0,
            readyCount: 0,
            attentionCount: 0,
            verifiedCount: 0,
            staleReceiptCount: 0,
            officeReviewCount: 0,
            lockedCount: 0,
            scansNeedingOCRCount: 0,
            dueNowCount: 0,
            batchEligibleCount: 0
        )
        XCTAssertEqual(emptySummary.headline, "Private workspace ready")
        XCTAssertEqual(
            emptySummary.detail,
            "Import, scan, or create a local paper PDF."
        )
        XCTAssertEqual(
            LibraryCommandSummary(
                readiness: .review,
                score: 61,
                totalCount: 3,
                readyCount: 2,
                attentionCount: 0,
                verifiedCount: 1,
                staleReceiptCount: 1,
                officeReviewCount: 0,
                lockedCount: 0,
                scansNeedingOCRCount: 0,
                dueNowCount: 0,
                batchEligibleCount: 0
            ).headline,
            "Re-verify changed outputs"
        )
        XCTAssertEqual(
            LibraryCommandSummary(
                readiness: .review,
                score: 72,
                totalCount: 3,
                readyCount: 2,
                attentionCount: 1,
                verifiedCount: 1,
                staleReceiptCount: 0,
                officeReviewCount: 1,
                lockedCount: 0,
                scansNeedingOCRCount: 0,
                dueNowCount: 0,
                batchEligibleCount: 0
            ).headline,
            "Review active evidence"
        )

        let health = PDFVersionStorageHealth(
            indexedVersionCount: 4,
            pinnedMilestoneCount: 2,
            removedIndexEntryCount: 1,
            removedOrphanFileCount: 2,
            repairedMetadataCount: 3,
            reclaimedByteCount: 4_096
        )
        XCTAssertEqual(health.repairedItemCount, 6)
        XCTAssertTrue(health.didRepairStorage)
        XCTAssertFalse(health.formattedReclaimedBytes.isEmpty)
        XCTAssertEqual(
            LocalStorageSnapshot(
                pdfBytes: .max,
                versionBytes: .max,
                textIndexBytes: -64,
                ocrBytes: 0,
                deliveryCacheBytes: 0,
                officeExportBytes: 0,
                officeDeliveryBytes: 0,
                changeReportBytes: 0,
                metadataBytes: 0
            ).totalBytes,
            .max
        )

        let budgetPlan = PDFOfficeVisualBudgetPlan(profile: makeProfile(pageCount: 1))
        let receiptA = PDFOfficeExportReceipt(
            format: .wordDocument,
            fileName: "A.docx",
            fileSizeBytes: 1_024,
            plan: nil,
            budgetPlan: budgetPlan
        )
        let receiptB = PDFOfficeExportReceipt(
            format: .plainText,
            fileName: "B.txt",
            fileSizeBytes: -8,
            plan: nil,
            budgetPlan: budgetPlan
        )
        let officeSummary = PDFOfficePinnedStorageSummary.measuring([
            PDFPinnedOfficeOutput(
                recordID: UUID(),
                documentName: "A",
                receipt: receiptA
            ),
            PDFPinnedOfficeOutput(
                recordID: UUID(),
                documentName: "B",
                receipt: receiptB
            )
        ])
        XCTAssertEqual(officeSummary.outputCount, 2)
        XCTAssertEqual(officeSummary.byteCount, 1_024)
        XCTAssertEqual(officeSummary.countContract, "2/24")
        XCTAssertEqual(officeSummary.remainingOutputCount, 22)
        XCTAssertTrue(officeSummary.canAdd(bytes: 1))
        XCTAssertFalse(
            officeSummary.canAdd(
                bytes: PDFOfficePinnedStorageSummary.maximumByteCount
            )
        )
        XCTAssertTrue(
            PDFOfficePinnedStorageSummary(
                outputCount: 20,
                byteCount: 0
            ).isNearCapacity
        )
        XCTAssertTrue(
            PDFOfficePinnedStorageSummary(
                outputCount: PDFOfficePinnedStorageSummary.maximumOutputCount,
                byteCount: 0
            ).isAtCapacity
        )

        XCTAssertEqual(PDFSourceLocationStatus.changed.title, "Source changed in Files")
        XCTAssertEqual(PDFSourceLocationStatus.stale.symbol, "folder.badge.questionmark")
        let permissions = PDFTechnicalPermissions(
            allowsHighQualityPrinting: true,
            allowsCopying: false,
            allowsCommenting: true,
            allowsFormFilling: true,
            allowsDocumentAssembly: false,
            allowsContentAccessibility: true
        )
        let source = PDFSourceLocationSnapshot(
            status: .current,
            name: "Source.pdf",
            resolvedURL: URL(fileURLWithPath: "/tmp/Source.pdf"),
            isUbiquitous: true,
            modificationDate: Date(timeIntervalSince1970: 2)
        )
        let inspection = PDFTechnicalInspection(
            byteCount: 2_048,
            pageCount: 2,
            sampledPageCount: 2,
            textCoverage: 0.8,
            imageDominantPageCount: 0,
            formFieldCount: 1,
            annotationCount: 1,
            attachmentCount: 1,
            outlineEntryCount: 2,
            hasExplicitPageLabels: true,
            isEncrypted: false,
            isLocked: false,
            permissions: permissions,
            source: source
        )
        XCTAssertFalse(inspection.permissions?.allowsCopying ?? true)
        XCTAssertEqual(inspection.source?.status, .current)

        let blockID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000201")
        )
        let blockData = try JSONSerialization.data(
            withJSONObject: [
                "id": blockID.uuidString,
                "text": "Legacy block",
                "confidence": 0.91,
                "normalizedX": 0.1,
                "normalizedY": 0.2,
                "normalizedWidth": 0.3,
                "normalizedHeight": 0.4
            ]
        )
        let legacyBlock = try JSONDecoder().decode(
            OCRTextBlock.self,
            from: blockData
        )
        XCTAssertFalse(legacyBlock.isUserCorrected)

        let low = makeOCRBlock(text: "Low", confidence: 0.2)
        let corrected = makeOCRBlock(
            text: "Corrected",
            confidence: 0.2,
            isUserCorrected: true
        )
        let reviewPage = OCRPageResult(
            pageIndex: 0,
            text: "Invoice",
            confidence: 0.85,
            blocks: [low, corrected]
        )
        let cleanPage = OCRPageResult(
            pageIndex: 1,
            text: "Clean",
            confidence: 0.99,
            blocks: [corrected],
            recognitionPass: .enhanced
        )
        XCTAssertEqual(reviewPage.lowConfidenceBlocks, [low])
        XCTAssertTrue(reviewPage.needsReview)
        XCTAssertFalse(cleanPage.needsReview)
        let configuration = OCRRecognitionConfiguration(
            languageMode: .selected,
            languageIdentifiers: [
                OCRRecognitionLanguage.english.rawValue,
                OCRRecognitionLanguage.simplifiedChinese.rawValue
            ],
            customWords: ["Bates"]
        )
        XCTAssertEqual(
            configuration.languageSummary,
            [
                OCRRecognitionLanguage.english.title.localizedUI,
                OCRRecognitionLanguage.simplifiedChinese.title.localizedUI
            ].joined(separator: ", ")
        )
        XCTAssertEqual(
            OCRRecognitionConfiguration.automatic.languageSummary,
            "Automatic language detection".localizedUI
        )
        let result = OCRResult(
            pages: [cleanPage, reviewPage],
            configuration: configuration
        )
        XCTAssertEqual(result.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(result.pagesNeedingReview.map(\.pageIndex), [0])
        XCTAssertEqual(result.enhancedPageCount, 1)
        XCTAssertEqual(result.text, "Page 1\nInvoice\n\nPage 2\nClean")

        let legacyPageData = try JSONSerialization.data(
            withJSONObject: [
                "pageIndex": 4,
                "text": "Legacy page",
                "confidence": 0.93
            ]
        )
        let legacyPage = try JSONDecoder().decode(
            OCRPageResult.self,
            from: legacyPageData
        )
        XCTAssertEqual(legacyPage.blocks, [])
        XCTAssertEqual(legacyPage.recognitionPass, .standard)
    }

    func testPlannerMatrixPreflightAndErrorContracts_BitsUT()
        throws {
        XCTAssertEqual(
            PDFQuickTaskPlanner.quickAccess(for: []),
            [.scanToPDF, .imagesToPDF, .mergePDFs, .compressPDF]
        )

        var scanProfile = makeProfile(pageCount: 4)
        scanProfile.kind = .scan
        scanProfile.sampledPageCount = 4
        scanProfile.imageDominantPageCount = 4
        let scanRecord = DocumentRecord(
            displayName: "Scanned exhibit",
            fileName: "scan.pdf",
            profile: scanProfile
        )
        XCTAssertEqual(
            PDFQuickTaskPlanner.quickAccess(for: [scanRecord]),
            [.recognizeText, .organizePages, .signPDF, .safeShare]
        )
        XCTAssertEqual(
            PDFQuickTask.recognizeText.compatibilityNote(for: scanRecord),
            "Image-based pages detected"
        )
        XCTAssertEqual(
            PDFQuickTask.organizePages.compatibilityNote(for: scanRecord),
            "4 pages ready to organize"
        )

        let contractBrief = DocumentBrief(
            category: .contract,
            summary: "Agreement",
            entities: [],
            suggestedSteps: [],
            indexedAt: Date(timeIntervalSince1970: 95_000),
            textSource: .searchableCopy,
            indexedCharacterCount: 120,
            confidence: .medium
        )
        let contractRecord = DocumentRecord(
            displayName: "NDA",
            fileName: "nda.pdf",
            profile: makeProfile(pageCount: 1),
            brief: contractBrief
        )
        let packageRecommendation = try XCTUnwrap(
            PDFTaskPackagePlanner.recommendation(
                for: contractRecord,
                hasRecognizedText: true
            )
        )
        XCTAssertEqual(packageRecommendation.package, .prepareToSend)
        XCTAssertEqual(packageRecommendation.task, .signPDF)
        XCTAssertEqual(packageRecommendation.reason, "Signature may be needed")
        XCTAssertEqual(
            PDFTaskPackagePlanner.task(
                for: .prepareToSend,
                record: contractRecord
            ),
            .signPDF
        )

        let amountBrief = DocumentBrief(
            category: .invoice,
            summary: "Invoice",
            entities: [],
            suggestedSteps: [
                SuggestedStep(
                    kind: .reviewAmount,
                    title: "Check total",
                    evidence: "Total $140",
                    evidencePageIndex: 0
                )
            ],
            indexedAt: Date(timeIntervalSince1970: 95_010),
            textSource: .vision,
            indexedCharacterCount: 80,
            confidence: .medium
        )
        let amountRecord = DocumentRecord(
            displayName: "Invoice",
            fileName: "invoice.pdf",
            profile: makeProfile(pageCount: 1),
            brief: amountBrief
        )
        let actionRecommendation = DocumentActionPlanner.recommendation(
            for: amountRecord,
            hasRecognizedText: false
        )
        XCTAssertEqual(actionRecommendation.action, .brief)
        XCTAssertEqual(actionRecommendation.reason, "Total $140")

        XCTAssertEqual(PDFDeliveryPreflightStatus.ready.title, "Ready to verify")
        XCTAssertEqual(PDFDeliveryPreflightStatus.blocked.symbol, "xmark.octagon")
        let preflight = PDFDeliveryPreflightAssessment(
            status: .review,
            pageCount: 2,
            byteCount: 2_048,
            fixCount: 1,
            reviewCount: 1,
            items: [
                PDFDeliveryPreflightItem(
                    id: "metadata",
                    title: "Metadata",
                    detail: "Personal metadata will be removed",
                    status: .willFix
                )
            ]
        )
        XCTAssertFalse(preflight.formattedSize.isEmpty)
        XCTAssertEqual(preflight.items.map(\.id), ["metadata"])
        XCTAssertEqual(PDFDeliveryOperation.bookletPrepared.symbol, "book.pages.fill")
        XCTAssertEqual(
            PaperPathError.invalidPassword.errorDescription,
            "Use a PDF password between 8 and 128 characters."
                .localizedUI
        )
        XCTAssertFalse(
            PaperPathError.outputVerificationFailed("Blank page")
                .errorDescription?.isEmpty ?? true
        )
    }

    func testOCRNormalizationPreferenceAndCodingContracts_BitsUT()
        throws {
        let negativePage = OCRPageResult(
            pageIndex: -1,
            text: "Dropped",
            confidence: 1
        )
        let uncorrected = OCRPageResult(
            pageIndex: 1,
            text: "Long uncorrected text",
            confidence: 0.99,
            blocks: []
        )
        let corrected = OCRPageResult(
            pageIndex: 1,
            text: "Fix",
            confidence: 0.1,
            blocks: [
                makeOCRBlock(
                    text: "Fix",
                    confidence: 0.95,
                    isUserCorrected: true
                )
            ]
        )
        let standardTie = OCRPageResult(
            pageIndex: 2,
            text: "Same",
            confidence: 0.8,
            blocks: []
        )
        let enhancedTie = OCRPageResult(
            pageIndex: 2,
            text: "Same",
            confidence: 0.8,
            blocks: [],
            recognitionPass: .enhanced
        )

        let normalized = OCRResult(
            pages: [standardTie, negativePage, uncorrected, corrected, enhancedTie]
        )
        XCTAssertEqual(normalized.pages.map(\.pageIndex), [1, 2])
        XCTAssertEqual(normalized.pages[0].text, "Fix")
        XCTAssertEqual(
            normalized.pages[0].blocks.filter(\.isUserCorrected).count,
            1
        )
        XCTAssertEqual(normalized.pages[1].recognitionPass, .enhanced)
        XCTAssertEqual(normalized.enhancedPageCount, 1)
        XCTAssertEqual(normalized.meanConfidence, 0.45, accuracy: 0.0001)
        XCTAssertLessThan(
            try JSONEncoder().encode(normalized).count,
            OCRResult.maximumEncodedTextBytes
        )

        let legacyData = try JSONSerialization.data(
            withJSONObject: [
                "pages": [
                    [
                        "pageIndex": 0,
                        "text": "Legacy",
                        "confidence": 0.9
                    ]
                ]
            ]
        )
        let legacyResult = try JSONDecoder().decode(
            OCRResult.self,
            from: legacyData
        )
        XCTAssertEqual(legacyResult.configuration, .automatic)
        XCTAssertEqual(legacyResult.pages.first?.recognitionPass, .standard)
    }

    func testVersionArchiveCapacityAndUnsafeManifestContracts_BitsUT() {
        let now = Date(timeIntervalSince1970: 96_000)
        let hash = String(repeating: "d", count: 64)
        let documentID = UUID()

        func archiveEntry(
            fileName: String = "Case.pdf",
            snapshotID: UUID = UUID(),
            title: String = "Case file",
            createdAt: Date = now,
            byteCount: Int64 = 4_096,
            pageCount: Int = 2,
            sha256: String = hash
        ) -> PDFVersionArchiveManifest.Entry {
            PDFVersionArchiveManifest.Entry(
                fileName: fileName,
                documentID: documentID,
                snapshotID: snapshotID,
                title: title,
                createdAt: createdAt,
                byteCount: byteCount,
                pageCount: pageCount,
                sha256: sha256,
                linkedDeliveryReceiptID: nil
            )
        }

        let snapshotA = PDFVersionSnapshot(
            id: UUID(),
            documentID: documentID,
            createdAt: now,
            label: "Import",
            fileName: "a.pdf",
            byteCount: .max,
            pageCount: 1,
            contentRevisionID: UUID(),
            contentFingerprint: hash,
            bookmarkedPages: [],
            bookmarkNames: [:],
            lastPageIndex: 0,
            milestoneName: "A",
            isPinned: true,
            linkedDeliveryReceiptID: nil,
            linkedDeliveryReceipt: nil
        )
        let snapshotB = PDFVersionSnapshot(
            id: UUID(),
            documentID: documentID,
            createdAt: now,
            label: "Edit",
            fileName: "b.pdf",
            byteCount: 1,
            pageCount: 1,
            contentRevisionID: UUID(),
            contentFingerprint: hash,
            bookmarkedPages: [],
            bookmarkNames: [:],
            lastPageIndex: 0,
            milestoneName: "B",
            isPinned: true,
            linkedDeliveryReceiptID: nil,
            linkedDeliveryReceipt: nil
        )
        let measured = PDFPinnedVersionStorageSummary.measuring([
            snapshotA,
            snapshotB
        ])
        XCTAssertEqual(measured.byteCount, .max)
        XCTAssertTrue(measured.isAtCapacity)
        XCTAssertFalse(measured.canAdd(bytes: 1))
        XCTAssertTrue(measured.byteContract.contains("/"))
        XCTAssertFalse(measured.formattedRemainingBytes.isEmpty)

        let valid = PDFVersionArchiveManifest(
            schema: PDFVersionArchiveManifest.currentSchema,
            createdAt: now,
            entries: [archiveEntry()]
        )
        XCTAssertTrue(valid.isStructurallyValid(at: now.addingTimeInterval(1)))

        let duplicateID = UUID()
        XCTAssertFalse(
            PDFVersionArchiveManifest(
                schema: PDFVersionArchiveManifest.currentSchema,
                createdAt: now,
                entries: [
                    archiveEntry(fileName: "A.pdf", snapshotID: duplicateID),
                    archiveEntry(fileName: "B.pdf", snapshotID: duplicateID)
                ]
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
        XCTAssertFalse(
            PDFVersionArchiveManifest(
                schema: PDFVersionArchiveManifest.currentSchema,
                createdAt: now,
                entries: [archiveEntry(title: "Bad\nTitle")]
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
        XCTAssertFalse(
            PDFVersionArchiveManifest(
                schema: PDFVersionArchiveManifest.currentSchema,
                createdAt: now,
                entries: [
                    archiveEntry(createdAt: now.addingTimeInterval(6 * 60))
                ]
            ).isStructurallyValid(at: now.addingTimeInterval(1))
        )
    }

    func testModelCatalogDisplayAndSearchContractsCoverEveryCase_BitsUT() {
        let allQuickTasks = PDFQuickTask.allCases
        XCTAssertEqual(allQuickTasks.count, 14)
        XCTAssertTrue(allQuickTasks.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(allQuickTasks.allSatisfy { !$0.detail.isEmpty })
        XCTAssertTrue(allQuickTasks.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertTrue(allQuickTasks.allSatisfy { !$0.searchAliases.isEmpty })
        XCTAssertEqual(PDFQuickTask.scanToPDF.group, .create)
        XCTAssertEqual(PDFQuickTask.exportText.group, .convert)
        XCTAssertFalse(PDFQuickTask.mergePDFs.requiresDocument)
        XCTAssertTrue(PDFQuickTask.safeShare.requiresDocument)
        XCTAssertTrue(PDFQuickTask.organizePages.isDefaultQuickAccess)
        XCTAssertFalse(PDFQuickTask.exportImages.isDefaultQuickAccess)
        XCTAssertEqual(PDFQuickTask.signPDF.matchScore("Sign PDF"), 100)
        XCTAssertEqual(PDFQuickTask.signPDF.matchScore("sign"), 80)
        XCTAssertEqual(PDFQuickTask.signPDF.matchScore("signature"), 50)
        XCTAssertNil(PDFQuickTask.signPDF.matchScore("spreadsheet"))

        var formProfile = makeProfile(pageCount: 1)
        formProfile.kind = .form
        formProfile.formFieldCount = 1
        let formRecord = DocumentRecord(
            displayName: "Form",
            fileName: "form.pdf",
            profile: formProfile
        )
        XCTAssertTrue(PDFQuickTask.fillForms.supports(formRecord))
        XCTAssertTrue(
            PDFQuickTask.fillForms.compatibilityNote(for: formRecord)
                .contains("1 interactive field")
        )

        var scanProfile = makeProfile(pageCount: 1)
        scanProfile.kind = .scan
        let scanRecord = DocumentRecord(
            displayName: "Scan",
            fileName: "scan.pdf",
            profile: scanProfile
        )
        XCTAssertTrue(PDFQuickTask.recognizeText.supports(scanRecord))
        XCTAssertFalse(PDFQuickTask.redactPDF.supports(scanRecord))
        XCTAssertEqual(
            PDFQuickTask.exportImages.compatibilityNote(for: scanRecord),
            "1 page to render"
        )

        var multiProfile = makeProfile(pageCount: 3)
        multiProfile.kind = .mixed
        let multiRecord = DocumentRecord(
            displayName: "Mixed",
            fileName: "mixed.pdf",
            profile: multiProfile
        )
        XCTAssertTrue(PDFQuickTask.organizePages.supports(multiRecord))
        XCTAssertEqual(
            PDFQuickTask.organizePages.compatibilityNote(for: multiRecord),
            "3 pages ready to organize"
        )
        XCTAssertEqual(
            PDFQuickTask.splitPDF.compatibilityNote(for: multiRecord),
            "3 pages ready to extract"
        )
        XCTAssertEqual(
            PDFQuickTask.signPDF.compatibilityNote(for: multiRecord),
            "Ready for signature"
        )
        XCTAssertEqual(
            PDFQuickTask.safeShare.compatibilityNote(for: multiRecord),
            "Ready for verified delivery"
        )

        let allPackages = PDFTaskPackage.allCases
        XCTAssertEqual(allPackages.count, 6)
        XCTAssertTrue(allPackages.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(allPackages.allSatisfy { !$0.detail.isEmpty })
        XCTAssertTrue(allPackages.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertTrue(allPackages.allSatisfy { !$0.searchAliases.isEmpty })
        XCTAssertTrue(PDFTaskPackage.makeSearchable.matches("ocr scan"))
        XCTAssertFalse(PDFTaskPackage.compressForEmail.matches("signature"))
        XCTAssertEqual(PDFTaskPackage.prepareToSend.defaultTask, .safeShare)
        XCTAssertEqual(PDFTaskPackage.fixPages.defaultTask, .organizePages)
        XCTAssertTrue(PDFTaskPackage.fixPages.supports(multiRecord))
        XCTAssertFalse(PDFTaskPackage.redactAndProve.supports(scanRecord))

        var lockedProfile = makeProfile(pageCount: 3)
        lockedProfile.isLocked = true
        let lockedRecord = DocumentRecord(
            displayName: "Locked",
            fileName: "locked.pdf",
            profile: lockedProfile
        )
        XCTAssertTrue(
            PDFQuickTask.scanToPDF.supports(lockedRecord)
        )
        XCTAssertFalse(
            PDFQuickTask.safeShare.supports(lockedRecord)
        )
        XCTAssertFalse(
            PDFTaskPackage.prepareToSend.supports(lockedRecord)
        )
    }

    func testModelFormatActionAndToolContractsCoverEveryCase_BitsUT() {
        let formats = PDFTextExportFormat.allCases
        XCTAssertEqual(formats.count, 6)
        XCTAssertTrue(formats.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.detail.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.fileExtension.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.editabilityIntent.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.appearanceIntent.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.sizeIntent.isEmpty })
        XCTAssertTrue(formats.allSatisfy { !$0.bestFor.isEmpty })
        XCTAssertEqual(
            formats.filter { $0.isOfficeFormat },
            [.wordDocument, .excelWorkbook, .powerPointPresentation]
        )
        XCTAssertEqual(PDFTextExportFormat.wordDocument.officePageLimit, 1_000)
        XCTAssertEqual(PDFTextExportFormat.powerPointPresentation.officePageLimit, 500)
        XCTAssertNil(PDFTextExportFormat.plainText.officePageLimit)

        let actions = DocumentAction.allCases
        XCTAssertEqual(actions.count, 9)
        XCTAssertTrue(actions.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(actions.allSatisfy { !$0.explanation.isEmpty })
        XCTAssertTrue(actions.allSatisfy { !$0.symbol.isEmpty })

        let tools = DocumentTool.allCases
        XCTAssertEqual(tools.count, 24)
        XCTAssertTrue(tools.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(tools.allSatisfy { !$0.compactTitle.isEmpty })
        XCTAssertTrue(tools.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertTrue(tools.allSatisfy { !$0.detail.isEmpty })
        XCTAssertTrue(tools.allSatisfy { !$0.searchAliases.isEmpty })
        XCTAssertEqual(DocumentTool.brief.group, .understand)
        XCTAssertEqual(DocumentTool.highlight.group, .markUp)
        XCTAssertEqual(DocumentTool.sign.group, .finish)
        XCTAssertEqual(DocumentTool.organize.group, .pages)
        XCTAssertEqual(DocumentTool.export.group, .export)
        XCTAssertEqual(DocumentTool.find.matchScore("Find"), 1_210)
        XCTAssertGreaterThan(
            DocumentTool.bates.matchScore("legal exhibit") ?? 0,
            DocumentTool.bates.matchScore("finish") ?? 0
        )
        XCTAssertNil(DocumentTool.protect.matchScore("ocr scan"))
    }

    func testModelVerificationProgressAndProvenanceContracts_BitsUT()
        throws {
        let now = Date(timeIntervalSince1970: 97_000)
        let packageID = UUID()
        let receiptID = UUID()
        let entry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Matter",
            receiptID: receiptID,
            format: .wordDocument,
            archiveName: "Matter.docx",
            byteCount: 4_096,
            sha256: String(repeating: "a", count: 64)
        )
        let verifiedArtifact = PDFOfficeVerifiedArtifact(
            entry: entry,
            url: temporaryDirectory.appendingPathComponent("Matter.docx"),
            formatEvidence: .ooxml(
                partCount: 7,
                xmlPartCount: 4,
                relationshipCount: 2,
                mediaPartCount: 1
            )
        )
        XCTAssertTrue(verifiedArtifact.formattedSize.contains("KB"))
        XCTAssertEqual(verifiedArtifact.shortFingerprint, String(repeating: "a", count: 12))
        XCTAssertEqual(
            verifiedArtifact.formatEvidence.summary,
            AppLocalization.format(
                "%lld parts · %lld XML · %lld relationships · %lld media",
                7,
                4,
                2,
                1
            )
        )
        XCTAssertEqual(
            PDFOfficeArtifactFormatEvidence.richText.summary,
            "RTF structure · UTF-8"
        )
        XCTAssertEqual(
            PDFOfficeArtifactFormatEvidence.utf8Text.symbol,
            "text.alignleft"
        )

        let report = PDFOfficeReportVerificationResult(
            status: .verified,
            packageID: packageID,
            keyID: "signer-key",
            sourceCount: 1,
            outputCount: 1,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            verifiedAt: now,
            detail: "Verified",
            publicKeyBase64: Data(repeating: 1, count: 32).base64EncodedString(),
            trustStatus: .unknown,
            trustedSignerName: nil
        )
        XCTAssertTrue(report.canTrustSigner(at: now))
        XCTAssertFalse(report.isExpired(at: now))
        XCTAssertTrue(report.isExpired(at: now.addingTimeInterval(61)))
        XCTAssertEqual(
            report.appendingDetail("ready").detail,
            "Verified ready"
        )
        XCTAssertEqual(
            report.attachingVerifiedArtifacts([verifiedArtifact])
                .verifiedArtifacts,
            [verifiedArtifact]
        )
        XCTAssertEqual(
            report.updatingTrust(.trusted, signerName: "Legal Ops")
                .trustedSignerName,
            "Legal Ops"
        )

        let changeReport = PDFChangeReportVerificationResult(
            status: .verified,
            reportID: UUID(),
            generatedAt: now,
            sourceName: "A.pdf",
            revisedName: "B.pdf",
            changedPageCount: 2,
            deliveryReceiptID: receiptID,
            sourceRevisionID: nil,
            revisedRevisionID: nil,
            sourceFingerprint: nil,
            revisedFingerprint: nil,
            verifiedBody: nil,
            verifiedBodyByteCount: nil,
            verifiedBodySHA256: nil,
            keyID: "change-key",
            detail: "Signed",
            publicKeyBase64: Data(repeating: 2, count: 32).base64EncodedString(),
            trustStatus: .unknown,
            trustedSignerName: nil
        )
        XCTAssertTrue(changeReport.canTrustSigner)
        XCTAssertEqual(
            changeReport.resolvingTrust(
                .trusted,
                trustedSignerName: "Reviewer"
            ).trustedSignerName,
            "Reviewer"
        )

        let progressWithoutBytes = PDFOperationProgress(
            label: "Idle",
            fractionCompleted: 0
        )
        XCTAssertNil(progressWithoutBytes.byteSummary)
        XCTAssertNil(progressWithoutBytes.throughputSummary)
        XCTAssertNil(progressWithoutBytes.remainingSummary)
        XCTAssertFalse(progressWithoutBytes.isStalled(at: now))
        let progressWithProcessedOnly = PDFOperationProgress(
            label: "Copy",
            fractionCompleted: 0.5,
            processedBytes: 2_048
        )
        XCTAssertNotNil(progressWithProcessedOnly.byteSummary)
        XCTAssertEqual(
            PDFOperationProgress(
                label: "Wait",
                fractionCompleted: 0.1,
                processedBytes: 1,
                totalBytes: 10,
                lastByteUpdateAt: now.addingTimeInterval(-1.5)
            ).isStalled(at: now),
            false
        )
        XCTAssertEqual(
            PDFOperationProgress(
                label: "Long",
                fractionCompleted: 0.1,
                estimatedRemainingSeconds: 125
            ).remainingSummary,
            "2m 5s"
        )

        let stages: [PDFBatchDeliveryStage] = [
            .queued,
            .checking,
            .ready,
            .creating,
            .verified,
            .reused,
            .needsReview,
            .blocked,
            .failed,
            .stopped
        ]
        XCTAssertTrue(stages.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(stages.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertEqual(stages.filter { $0.isFinal }.count, 6)
        XCTAssertEqual(
            stages.filter { $0.isShareable },
            [.verified, .reused]
        )

        let batesRecord = makeRecord(name: "Bates", pageCount: 2)
        let batesEntry = makeBatesEntry(
            record: batesRecord,
            outputRevisionID: UUID(),
            start: 1,
            end: 2,
            sourceHash: String(repeating: "b", count: 64),
            outputHash: String(repeating: "c", count: 64)
        )
        let statuses: [PDFBatesBatchEntryStatus] = [
            .current,
            .changed,
            .removed,
            .inTrash,
            .missing,
            .untrusted
        ]
        XCTAssertTrue(statuses.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(statuses.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertEqual(
            statuses.map {
                PDFBatesBatchReceiptVerificationItem(
                    entry: batesEntry,
                    status: $0,
                    actualRevisionID: nil,
                    actualSHA256: nil
                ).detail
            },
            [
                "Revision and SHA-256 match",
                "The working copy changed after this receipt",
                "The signed Bates removal matches this working copy",
                "The verified revision is currently in Trash",
                "The referenced private copy is unavailable",
                "The signed receipt payload could not be trusted"
            ]
        )

        let deliveryReport = PDFDeliveryPackageVerificationReport(
            archiveName: "matter.zip",
            archiveByteCount: 8_192,
            packageID: packageID,
            packageCreatedAt: now,
            verifiedAt: now.addingTimeInterval(2),
            artifactFileName: "Matter.pdf",
            artifactByteCount: 4_096,
            artifactPageCount: 1,
            isEncrypted: false,
            operation: .safeShare,
            deliveryReceiptID: receiptID,
            expectedSHA256: String(repeating: "d", count: 64),
            actualSHA256: String(repeating: "d", count: 64),
            checks: [
                PDFDeliveryCheck(
                    id: "hash",
                    title: "SHA-256",
                    detail: "Artifact bytes match.",
                    status: .passed
                )
            ],
            integrityFailures: [],
            signatureStatus: .verified,
            signatureDetail: "Valid",
            signerKeyID: "delivery-key",
            signerPublicKeyBase64:
                Data(repeating: 3, count: 32).base64EncodedString(),
            trustStatus: .trusted,
            trustedSignerName: "Legal Ops",
            verifiedArtifactURL:
                temporaryDirectory.appendingPathComponent("Matter.pdf")
        )
        XCTAssertEqual(deliveryReport.status, .verified)
        XCTAssertEqual(deliveryReport.warningCount, 0)
        XCTAssertTrue(deliveryReport.hasValidSourceSignature)
        XCTAssertTrue(deliveryReport.canOpenArtifact)
        XCTAssertTrue(deliveryReport.canPreviewArtifact)
        XCTAssertEqual(deliveryReport.provenanceTitle, "Legal Ops")
        let invalidReport = deliveryReport.resolvingTrust(
            .invalid,
            trustedSignerName: nil
        )
        XCTAssertFalse(invalidReport.provenanceTitle.isEmpty)
        XCTAssertNotEqual(invalidReport.provenanceTitle, "Legal Ops")
        let provenance = PDFReceivedPackageProvenance(
            report: deliveryReport,
            importedAt: now.addingTimeInterval(3)
        )
        XCTAssertTrue(
            provenance.matchesCurrentBytes(
                fingerprint: String(repeating: "D", count: 64),
                byteCount: 4_096
            )
        )
        XCTAssertFalse(
            provenance.matchesCurrentBytes(
                fingerprint: String(repeating: "e", count: 64),
                byteCount: 4_096
            )
        )
        XCTAssertEqual(provenance.sourceTitle, "Legal Ops")
        XCTAssertFalse(provenance.formattedArtifactSize.isEmpty)
    }

    func testModelPresentationMatricesExerciseEveryState_BitsUT() {
        XCTAssertEqual(
            Set(PDFQuickTaskGroup.allCases.map(\.id)).count,
            PDFQuickTaskGroup.allCases.count
        )
        XCTAssertTrue(
            PDFQuickTaskGroup.allCases.allSatisfy { !$0.title.isEmpty }
        )
        XCTAssertTrue(
            PDFPageImageExportPreset.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
                    && !$0.detail.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            DocumentKind.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            DocumentToolGroup.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFReadingTheme.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFReadingLayout.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(PDFMarkupKind.allCases.allSatisfy { !$0.id.isEmpty })
        XCTAssertTrue(
            PDFMarkupColor.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFStampKind.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.stampName.isEmpty
            }
        )
        XCTAssertTrue(
            PDFPageNumberFormat.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
                    && !$0.text(number: 2, total: 8).isEmpty
            }
        )
        XCTAssertTrue(
            PDFPageNumberPosition.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFGeneratedAnnotationKind.allCases.allSatisfy {
                !$0.author.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFWatermarkPreset.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
                    && ($0 == .custom || !$0.defaultText.isEmpty)
            }
        )
        XCTAssertTrue(
            PDFWatermarkLayout.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFWatermarkTone.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFWatermarkIntensity.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
                    && $0.opacity > 0 && $0.scale > 0
            }
        )
        XCTAssertTrue(
            PDFTextReplacementFontStyle.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.pdfFontName.isEmpty
            }
        )
        XCTAssertTrue(
            PDFTextReplacementAlignment.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFPrintPaperTarget.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFPrintOrientationPolicy.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFPrintScaleMode.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFPrintProductionRisk.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFBookletBindingEdge.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFBookletSheetSide.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFSignaturePosition.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            PDFSignatureSize.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
                    && $0.pageWidthFraction > 0
            }
        )
        XCTAssertTrue(
            PDFFormFieldKind.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PDFPageLabelStyle.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
                    && $0.formattedNumber(28).count >= 0
            }
        )
        XCTAssertTrue(
            DocumentWorkflowStatus.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            DocumentCategory.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            DetectedEntity.Kind.allCases.allSatisfy {
                !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertEqual(
            DetectedEntity.Kind.allCases.filter(\.isSensitive),
            [.email, .phone, .identifier]
        )
        XCTAssertTrue(
            PDFChangeSeverity.allCases.allSatisfy { !$0.title.isEmpty }
        )
        XCTAssertTrue(
            OCRLanguageMode.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )
        XCTAssertTrue(
            OCRRecognitionLanguage.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty
            }
        )

        let readiness: [PDFOfficeExportReadiness] = [
            .strong, .review, .limited
        ]
        XCTAssertTrue(readiness.allSatisfy {
            !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertTrue(PDFOfficeExportStage.allCases.allSatisfy {
            !$0.id.isEmpty && !$0.title.isEmpty
                && !$0.symbol.isEmpty && $0.threshold >= 0
        })
        XCTAssertEqual(PDFOfficeExportStage.current(fractionCompleted: -1), .analyze)
        XCTAssertEqual(PDFOfficeExportStage.current(fractionCompleted: 0.7), .package)
        XCTAssertEqual(PDFOfficeExportStage.current(fractionCompleted: 1), .verify)

        let failureKinds: [PDFOfficeExportFailureKind] = [
            .sourceLimit, .rights, .missingText, .busy, .storage,
            .verification, .sourceChanged, .unavailableArtifact, .unknown
        ]
        XCTAssertTrue(failureKinds.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertEqual(
            failureKinds.filter(\.allowsRetry).count,
            6
        )
        XCTAssertEqual(
            failureKinds.compactMap(\.recoveryTask),
            [.splitPDF, .recognizeText]
        )

        let availability: [PDFOfficeArtifactAvailability] = [
            .reusable, .sourceChanged, .expired, .unavailable
        ]
        XCTAssertTrue(availability.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let resources: [PDFOfficeResourceMode] = [
            .ready, .conserving, .blocked
        ]
        XCTAssertTrue(resources.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let thermals: [PDFOfficeThermalLevel] = [
            .nominal, .fair, .serious, .critical, .unknown
        ]
        XCTAssertTrue(thermals.allSatisfy { !$0.title.isEmpty })
        let integrity: [PDFOfficeIntegrityStatus] = [
            .verified, .missing, .mismatch, .sourceChanged
        ]
        XCTAssertTrue(integrity.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertEqual(integrity.filter(\.isVerified), [.verified])
        let byteStages: [PDFByteProgressStage] = [
            .reconstructing, .packaging, .checksumming, .archiving, .verifying
        ]
        XCTAssertTrue(byteStages.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let trustStatuses: [PDFOfficeSignerTrustStatus] = [
            .thisDevice, .trusted, .unknown, .invalid, .unsupported
        ]
        XCTAssertTrue(trustStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let reportStatuses: [PDFOfficeReportVerificationStatus] = [
            .verified, .expired, .invalid, .unsupported
        ]
        XCTAssertTrue(reportStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let matchStatuses: [PDFOfficeExternalMatchStatus] = [
            .exact, .missing, .ambiguous, .inconsistent
        ]
        XCTAssertTrue(matchStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertTrue(PDFOfficeRouteConfidence.allCases.allSatisfy {
            !$0.id.isEmpty && !$0.title.isEmpty
                && !$0.symbol.isEmpty && !$0.detail.isEmpty
        })
        XCTAssertTrue(PDFOfficeProductionSLA.allCases.allSatisfy {
            !$0.id.isEmpty && !$0.title.isEmpty && !$0.window.isEmpty
                && !$0.symbol.isEmpty && !$0.detail.isEmpty
        })
        XCTAssertTrue(PDFOfficeVisualBudgetMode.allCases.allSatisfy {
            !$0.id.isEmpty && !$0.storageValue.isEmpty
                && !$0.title.isEmpty && !$0.symbol.isEmpty
                && !$0.detail.isEmpty
        })
        XCTAssertTrue(PDFOfficeVisualBudgetPressure.allCases.allSatisfy {
            !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertTrue(PDFOfficeVisualAnchorPolicy.allCases.allSatisfy {
            !$0.id.isEmpty && !$0.title.isEmpty
                && !$0.symbol.isEmpty && !$0.detail.isEmpty
        })

        let formCompatibility: [PDFFormCompatibility] = [
            .ready, .limited, .unsupported
        ]
        XCTAssertTrue(formCompatibility.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let calculations: [PDFFormCalculationOperation] = [
            .sum, .product, .average, .minimum, .maximum
        ]
        XCTAssertTrue(calculations.allSatisfy { !$0.title.isEmpty })
        let formats: [PDFFormFormatKind] = [
            .number, .percent, .date, .time
        ]
        XCTAssertTrue(formats.allSatisfy { !$0.title.isEmpty })
        let origins: [PDFEmbeddedAttachmentOrigin] = [
            .document, .pageAnnotation
        ]
        XCTAssertTrue(origins.allSatisfy { !$0.title.isEmpty })
        let paperClasses: [PDFPagePaperClass] = [
            .a4, .letter, .legal, .square, .custom
        ]
        XCTAssertTrue(paperClasses.allSatisfy { !$0.title.isEmpty })
        let cropConfidence: [PDFPageCropConfidence] = [
            .high, .medium, .low
        ]
        XCTAssertTrue(cropConfidence.allSatisfy { !$0.title.isEmpty })
        let taskStages: [DocumentTaskStage] = [
            .fillForm, .sign, .verify
        ]
        XCTAssertTrue(taskStages.allSatisfy {
            !$0.title.isEmpty && !$0.detail.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertEqual(taskStages.map(\.action), [.reviewForm, .sign, .safeShare])
        XCTAssertEqual(taskStages.map(\.quickTask), [.fillForms, .signPDF, .safeShare])
        let textSources: [IndexedTextSource] = [
            .native, .vision, .searchableCopy
        ]
        XCTAssertTrue(textSources.allSatisfy { !$0.title.isEmpty })
        let confidence: [DocumentUnderstandingConfidence] = [
            .high, .medium, .low
        ]
        XCTAssertTrue(confidence.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let suggestionKinds: [SuggestedStep.Kind] = [
            .recognize, .reviewDate, .reviewAmount, .completeForm,
            .reviewSignature, .organize, .share
        ]
        XCTAssertTrue(suggestionKinds.allSatisfy { !$0.symbol.isEmpty })
        let operations: [PDFDeliveryOperation] = [
            .compressed, .redacted, .protected, .unlocked, .flattened,
            .safeShare, .edited, .textReplaced, .printPrepared,
            .bookletPrepared
        ]
        XCTAssertTrue(operations.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let preflightStatuses: [PDFDeliveryPreflightStatus] = [
            .ready, .review, .blocked
        ]
        XCTAssertTrue(preflightStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let failurePhases: [PDFBatchDeliveryFailurePhase] = [
            .source, .preflight, .rendering, .verification, .saving,
            .cancelled
        ]
        XCTAssertTrue(failurePhases.allSatisfy { !$0.title.isEmpty })
        let changeSides: [PDFChangePageSide] = [.source, .revised]
        XCTAssertTrue(changeSides.allSatisfy { !$0.title.isEmpty })
        let matchKinds: [PDFPageMatchKind] = [
            .unchanged, .modified, .inserted, .removed
        ]
        XCTAssertTrue(matchKinds.allSatisfy { !$0.title.isEmpty })
        let differenceKinds: [PDFTextDifferenceKind] = [
            .removed, .inserted
        ]
        XCTAssertTrue(differenceKinds.allSatisfy { !$0.title.isEmpty })
        let granularities: [PDFTextDifferenceGranularity] = [
            .word, .character
        ]
        XCTAssertTrue(granularities.allSatisfy { !$0.title.isEmpty })
        let matchBases: [PDFPageMatchBasis] = [
            .exactContent, .repeatedContent, .pageLabel, .textMarker,
            .barcode, .context, .similarity
        ]
        XCTAssertTrue(matchBases.allSatisfy { !$0.title.isEmpty })
        let versionStatuses: [PDFVersionArchiveVerificationStatus] = [
            .verified, .failed
        ]
        XCTAssertTrue(versionStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let sourceStatuses: [PDFSourceLocationStatus] = [
            .detached, .current, .changed, .unavailable, .stale
        ]
        XCTAssertTrue(sourceStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let recognitionPasses: [OCRRecognitionPass] = [
            .standard, .enhanced
        ]
        XCTAssertTrue(recognitionPasses.allSatisfy { !$0.title.isEmpty })
    }

    func testOfficeBatchQueueAndBudgetStateMatrices_BitsUT() {
        var profile = makeProfile(pageCount: 1_205)
        profile.byteCount = 300 * 1_024 * 1_024
        profile.sampledPageCount = 1_000
        profile.imageDominantPageCount = 820

        let budget = PDFOfficeVisualBudgetPlan(profile: profile)
        XCTAssertFalse(budget.formattedTotalBudget.isEmpty)
        XCTAssertFalse(budget.formattedPerPageBudget.isEmpty)
        XCTAssertFalse(budget.formattedEstimatedVisualBytes.isEmpty)
        XCTAssertFalse(budget.pressureContract.isEmpty)
        XCTAssertFalse(budget.chunkSummary.isEmpty)
        XCTAssertFalse(budget.compressionLadderSummary.isEmpty)
        XCTAssertFalse(budget.anchorPolicySummary.isEmpty)
        XCTAssertFalse(budget.reserveWindowSummary.isEmpty)
        XCTAssertFalse(budget.memoryGuardSummary.isEmpty)
        XCTAssertTrue((0...100).contains(budget.visualReferenceRatioPercent))
        XCTAssertTrue((0...100).contains(budget.estimatedBudgetUsePercent))

        for format in PDFTextExportFormat.allCases {
            let plan = PDFOfficeExportFormatPlan.plan(
                for: format,
                profile: profile
            )
            XCTAssertEqual(plan.id, format.rawValue)
            XCTAssertTrue((0...100).contains(plan.compositeScore))
            XCTAssertFalse(plan.decisionRole.isEmpty)
            XCTAssertFalse(plan.compactEvidence.isEmpty)
            XCTAssertFalse(plan.actionTitle.isEmpty)
            XCTAssertFalse(plan.primaryEvidence.isEmpty)
            XCTAssertFalse(plan.riskEvidence.isEmpty)
            XCTAssertFalse(plan.preferredUse.isEmpty)
        }

        let failures = [
            PDFOfficeExportFailure.sourceLimit(
                format: .powerPointPresentation,
                pageCount: 501
            ),
            PDFOfficeExportFailure.unavailableArtifact(format: .wordDocument),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.lockedPDF
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.missingRecognizedText
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.insufficientStorage
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.fileTooLarge
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.outputVerificationFailed(
                    "source changed during verification"
                )
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.outputVerificationFailed("hash mismatch")
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.insufficientSelection(
                    "already processing"
                )
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.insufficientSelection("page limit")
            ),
            PDFOfficeExportFailure.classify(
                format: .plainText,
                error: PaperPathError.invalidPage
            )
        ]
        XCTAssertEqual(Set(failures.map(\.kind)).count, 9)
        XCTAssertTrue(failures.allSatisfy { !$0.detail.isEmpty })

        let plan = PDFOfficeBatchPlan(
            format: .wordDocument,
            sourceRevisionID: UUID(),
            profile: profile
        )
        XCTAssertGreaterThan(plan.segmentCount, 1)
        XCTAssertTrue(plan.isBatchRequired)
        XCTAssertFalse(plan.summary.isEmpty)
        XCTAssertTrue(plan.segments.allSatisfy {
            $0.id == $0.id && $0.pageCount > 0
                && !$0.pageIndices.isEmpty && !$0.pageRangeLabel.isEmpty
        })

        var run = PDFOfficeBatchRun(plan: plan)
        for index in run.segments.indices {
            run.segments[index].status = [
                PDFOfficeBatchSegmentStatus.completed,
                .failed,
                .cancelled
            ][index % 3]
            run.segments[index].fractionCompleted = Double(index + 1)
                / Double(run.segments.count)
        }
        XCTAssertGreaterThan(run.completedCount, 0)
        XCTAssertGreaterThan(run.failedCount, 0)
        XCTAssertTrue((0...1).contains(run.fractionCompleted))
        XCTAssertTrue((0...100).contains(run.percentCompleted))
        XCTAssertFalse(run.retryableSegmentIDs.isEmpty)
        let segmentStatuses: [PDFOfficeBatchSegmentStatus] = [
            .queued, .extracting, .rebuilding, .retaining, .completed,
            .failed, .cancelled
        ]
        XCTAssertTrue(segmentStatuses.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertEqual(segmentStatuses.filter(\.isTerminal).count, 3)
        let batchStatuses: [PDFOfficeBatchStatus] = [
            .preparing, .running, .paused, .completed, .partial, .failed,
            .cancelled
        ]
        run.status = .completed
        XCTAssertTrue(run.isFinished)
        XCTAssertTrue(batchStatuses.allSatisfy { !$0.title.isEmpty })

        var jobs = PDFOfficeQueuePriority.allCases.enumerated().map {
            index,
            priority in
            var job = makeQueueJob(
                recordID: UUID(),
                revisionID: UUID(),
                priority: priority,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
            job.stage = [
                PDFOfficeQueueJobStage.queued,
                .analyzing,
                .completed
            ][index]
            job.completedAt = Date(
                timeIntervalSince1970: Double(index + 10)
            )
            return job
        }
        jobs.append(contentsOf: [
            .init(
                recordID: UUID(),
                sourceRevisionID: UUID(),
                sourceName: "Large",
                sourcePageCount: 1_001,
                format: .wordDocument,
                priority: .background
            ),
            .init(
                recordID: UUID(),
                sourceRevisionID: UUID(),
                sourceName: "Text",
                sourcePageCount: 1,
                format: .plainText,
                priority: .normal
            )
        ])
        XCTAssertTrue(PDFOfficeQueuePriority.allCases.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        let queueStages: [PDFOfficeQueueJobStage] = [
            .queued, .analyzing, .rebuilding, .retaining, .paused,
            .completed, .attention, .cancelled
        ]
        XCTAssertTrue(queueStages.allSatisfy {
            !$0.title.isEmpty && !$0.symbol.isEmpty
        })
        XCTAssertEqual(queueStages.filter(\.isPending), [.queued, .paused])
        XCTAssertEqual(queueStages.filter(\.isTerminal).count, 3)
        XCTAssertFalse(jobs[0].isBatch)
        XCTAssertTrue(jobs[3].isBatch)
        XCTAssertTrue(jobs.allSatisfy { !$0.routeLabel.isEmpty })

        var queue = PDFOfficeProductionQueue(jobs: jobs)
        XCTAssertGreaterThan(queue.pendingCount, 0)
        XCTAssertGreaterThan(queue.completedCount, 0)
        XCTAssertEqual(queue.attentionCount, 0)
        XCTAssertNotNil(queue.activeJob)
        XCTAssertTrue(queue.hasRunnableJobs)
        queue.restoreInterruptedWork()
        XCTAssertTrue(queue.isSuspended)
        queue.boundHistory()
        XCTAssertEqual(queue.jobs.count, jobs.count)

        let runtime = PDFOfficeRuntimeEvidence(
            sourcePageCount: 2,
            outputPageCount: 3,
            primaryUnitLabel: "Paragraphs",
            primaryUnitCount: 4,
            characterCount: 20,
            searchablePageCount: 2,
            assetCount: 1,
            assetByteCount: 1_024,
            assetBudgetByteCount: 2_048,
            assetCompressionFallbackCount: 1,
            assetMinimumQualityPercent: 46
        )
        XCTAssertEqual(runtime.pageYieldPercent, 100)
        XCTAssertEqual(runtime.searchableCoveragePercent, 67)
        XCTAssertEqual(runtime.assetBudgetUsePercent, 50)
        XCTAssertFalse(runtime.formattedAssetBytes.isEmpty)
        XCTAssertFalse(runtime.formattedAssetBudget.isEmpty)
    }

    func testPrintBookletFormAndDifferenceDerivedContracts_BitsUT() {
        let clearEvidence = PDFPrintProductionEvidence(
            pageIndex: 0,
            trimBoxInsetPoints: .none,
            bleedInsetPoints: .none,
            requiredBleedPoints: 9,
            requiredSafeAreaPoints: 18,
            nearestContentToTrimPoints: nil,
            hasExplicitTrimBox: false,
            hasBleedAllowance: true,
            safeAreaRisk: .clear,
            bleedRisk: .clear
        )
        let riskEvidence = PDFPrintProductionEvidence(
            pageIndex: 1,
            trimBoxInsetPoints: PDFPageCropInsets(
                top: 1,
                right: 2,
                bottom: 3,
                left: 4
            ),
            bleedInsetPoints: .none,
            requiredBleedPoints: 9,
            requiredSafeAreaPoints: 18,
            nearestContentToTrimPoints: 7,
            hasExplicitTrimBox: true,
            hasBleedAllowance: false,
            safeAreaRisk: .risk,
            bleedRisk: .caution
        )
        XCTAssertEqual(clearEvidence.overallRisk, .clear)
        XCTAssertEqual(clearEvidence.trimSummary, "Crop box")
        XCTAssertEqual(clearEvidence.safeAreaSummary, "No text/fields")
        XCTAssertEqual(riskEvidence.overallRisk, .risk)
        XCTAssertFalse(riskEvidence.trimSummary.isEmpty)
        XCTAssertEqual(riskEvidence.bleedSummary, "Missing")
        XCTAssertFalse(riskEvidence.safeAreaSummary.isEmpty)

        let pages = [
            PDFPrintPreparationPage(
                pageIndex: 0,
                sourceWidth: 612,
                sourceHeight: 792,
                outputWidth: 612,
                outputHeight: 792,
                printableWidth: 564,
                printableHeight: 744,
                renderedWidth: 500,
                renderedHeight: 700,
                scale: 0.8,
                visibleFraction: 1,
                productionEvidence: clearEvidence
            ),
            PDFPrintPreparationPage(
                pageIndex: 1,
                sourceWidth: 792,
                sourceHeight: 612,
                outputWidth: 612,
                outputHeight: 792,
                printableWidth: 564,
                printableHeight: 744,
                renderedWidth: 600,
                renderedHeight: 744,
                scale: 1.2,
                visibleFraction: 0.8,
                productionEvidence: riskEvidence
            )
        ]
        XCTAssertEqual(pages.map(\.id), [0, 1])
        XCTAssertTrue(pages[0].hasPadding)
        XCTAssertTrue(pages[1].hasClipping)
        XCTAssertTrue(pages.allSatisfy { $0.isScaled })
        XCTAssertTrue(pages.allSatisfy { !$0.sourceSizeLabel.isEmpty })
        XCTAssertTrue(pages.allSatisfy { !$0.outputSizeLabel.isEmpty })
        XCTAssertEqual(pages.map(\.scalePercent), [80, 120])
        XCTAssertEqual(pages.map(\.visiblePercent), [100, 80])
        XCTAssertEqual(pages[0].outcomeTitle, "Reduced")
        XCTAssertEqual(pages[1].outcomeTitle, "Preflight risk")

        let printAssessment = PDFPrintPreparationAssessment(
            revisionID: UUID(),
            options: .standard,
            annotationCount: 0,
            pages: pages
        )
        XCTAssertEqual(printAssessment.clippedPageCount, 1)
        XCTAssertEqual(printAssessment.scaledPageCount, 2)
        XCTAssertEqual(printAssessment.paddedPageCount, 1)
        XCTAssertEqual(printAssessment.productionRiskPageCount, 1)
        XCTAssertEqual(printAssessment.productionCautionPageCount, 0)
        XCTAssertEqual(printAssessment.productionReviewPageCount, 1)
        XCTAssertEqual(printAssessment.bleedRiskPageCount, 1)
        XCTAssertEqual(printAssessment.safeAreaRiskPageCount, 1)
        XCTAssertEqual(printAssessment.averageScalePercent, 100)

        let left = PDFBookletSlot(
            sourcePageIndex: 0,
            scale: 0.9,
            visibleFraction: 1,
            creepOffsetPoints: -4
        )
        let blank = PDFBookletSlot(
            sourcePageIndex: nil,
            scale: 1,
            visibleFraction: 1,
            creepOffsetPoints: 6
        )
        let spread = PDFBookletSpread(
            outputPageIndex: 0,
            signatureNumber: 1,
            signatureSheetCount: 2,
            sheetNumber: 1,
            side: .front,
            left: left,
            right: blank,
            sheetWidth: 792,
            sheetHeight: 612
        )
        XCTAssertEqual(left.pageNumber, 1)
        XCTAssertEqual(left.scalePercent, 90)
        XCTAssertTrue(blank.isBlank)
        XCTAssertTrue(spread.hasBlankSlot)
        XCTAssertEqual(spread.id, 0)
        XCTAssertEqual(spread.pageOrderLabel, "1 · Blank")
        let booklet = PDFBookletAssessment(
            revisionID: UUID(),
            options: PDFBookletOptions(
                paperTarget: .letter,
                bindingEdge: .left,
                outerMarginPoints: 24,
                gutterPoints: 12,
                showsFoldMarks: true,
                signatureSheetLimit: 2,
                creepCompensationPoints: 6
            ),
            sourcePageCount: 1,
            paddedPageCount: 4,
            annotationCount: 0,
            spreads: [spread]
        )
        XCTAssertEqual(booklet.signatureCount, 1)
        XCTAssertEqual(booklet.insertedBlankCount, 3)
        XCTAssertEqual(booklet.sheetCount, 1)
        XCTAssertEqual(booklet.outputPageCount, 1)
        XCTAssertEqual(booklet.maximumCreepOffsetPoints, 6)
        XCTAssertEqual(booklet.largestSignatureSheetCount, 2)
        XCTAssertEqual(booklet.averageScalePercent, 90)

        let region = PDFDifferenceRegion(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
            intensity: 0.8
        )
        let character = PDFTextDifferenceEvidence(
            kind: .removed,
            text: " \n\t",
            region: region,
            granularity: .character
        )
        let word = PDFTextDifferenceEvidence(
            kind: .inserted,
            text: "A replacement phrase that is deliberately longer than the preview",
            region: region,
            granularity: .word
        )
        let modified = PDFPageChange(
            pageIndex: 1,
            sourceExists: true,
            revisedExists: true,
            visibleDifference: 0,
            changedPixelRatio: 0,
            geometryChanged: false,
            textChanged: true,
            sourceTextCharacterCount: 3,
            revisedTextCharacterCount: 64,
            differenceRegions: [region],
            sourceTextDifferences: [character],
            revisedTextDifferences: [word],
            matchBasis: .textMarker
        )
        XCTAssertFalse(modified.id.isEmpty)
        XCTAssertEqual(modified.resolvedSourcePageIndex, 1)
        XCTAssertEqual(modified.resolvedRevisedPageIndex, 1)
        XCTAssertEqual(modified.resolvedMatchKind, .modified)
        XCTAssertTrue(modified.isTextOnlyChange)
        XCTAssertEqual(modified.textDifferenceCount, 2)
        XCTAssertEqual(modified.characterDifferenceCount, 1)
        XCTAssertEqual(modified.wordDifferenceCount, 1)
        XCTAssertEqual(modified.resolvedTextDifferenceGranularity, .character)
        XCTAssertFalse(modified.localizedTextEvidenceCountLabel.isEmpty)
        XCTAssertFalse(modified.textDifferencePreview?.isEmpty ?? true)
        XCTAssertEqual(modified.preferredOpenSide, .revised)
        XCTAssertEqual(modified.preferredOpenPageIndex, 1)
        XCTAssertEqual(modified.severity, .major)

        let inserted = PDFPageChange(
            pageIndex: 2,
            sourceExists: false,
            revisedExists: true,
            visibleDifference: 1,
            changedPixelRatio: 1,
            geometryChanged: true,
            textChanged: false,
            sourceTextCharacterCount: 0,
            revisedTextCharacterCount: 5
        )
        let removed = PDFPageChange(
            pageIndex: 3,
            sourceExists: true,
            revisedExists: false,
            visibleDifference: 1,
            changedPixelRatio: 1,
            geometryChanged: false,
            textChanged: false,
            sourceTextCharacterCount: 5,
            revisedTextCharacterCount: 0
        )
        XCTAssertEqual(inserted.resolvedMatchKind, .inserted)
        XCTAssertEqual(removed.resolvedMatchKind, .removed)
        XCTAssertEqual(removed.preferredOpenSide, .source)
        XCTAssertEqual(removed.preferredOpenPageIndex, 3)

        let review = PDFChangeReview(
            sourcePageCount: 3,
            revisedPageCount: 4,
            comparedPageCount: 2,
            changes: [modified, inserted, removed]
        )
        XCTAssertEqual(review.visibleChangedPageCount, 2)
        XCTAssertEqual(review.textChangedPageCount, 1)
        XCTAssertEqual(review.geometryChangedPageCount, 1)
        XCTAssertEqual(review.totalChangedPageCount, 3)
        XCTAssertEqual(review.addedPageCount, 1)
        XCTAssertEqual(review.removedPageCount, 0)
        XCTAssertEqual(review.visiblyUnchangedPageCount, 2)
        XCTAssertFalse(review.isIdentical)
        XCTAssertGreaterThan(review.estimatedCacheByteCount, 0)
        XCTAssertEqual(review.resolvedPageMatches.count, 4)
        XCTAssertEqual(review.revisedPage(matchingSourcePage: 1), 1)
        XCTAssertEqual(review.sourcePage(matchingRevisedPage: 1), 1)
    }

    func testOfficeArtifactFormatAndShareVerificationRoundTrip_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("format-verification-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "Invoice 1042\nDescription Quantity Total\nPaper 2 18.00"
                ),
                IndexedPageText(
                    pageIndex: 1,
                    text: "Approval notes\nReviewed locally"
                )
            ],
            indexedAt: Date()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.verifiedOfficeDeliveryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(at: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var entries: [PDFOfficeDeliveryEntry] = []
        var urls: [String: URL] = [:]
        for format in PDFTextExportFormat.allCases {
            let name = "verified-\(format.rawValue).\(format.fileExtension)"
            let url = directory.appendingPathComponent(name)
            _ = try PDFOutputService().exportText(
                sourceURL: source,
                destination: url,
                textIndex: index,
                title: "Verified Office Export",
                format: format,
                profile: makeProfile(pageCount: 2)
            )
            let data = try Data(contentsOf: url)
            let entry = PDFOfficeDeliveryEntry(
                sourceRecordID: UUID(),
                sourceRevisionID: UUID(),
                sourceName: "Format source",
                receiptID: UUID(),
                format: format,
                archiveName: name,
                byteCount: Int64(data.count),
                sha256: sha256(data)
            )
            entries.append(entry)
            urls[name] = url
        }

        let evidence = try PDFOfficeArtifactFormatVerificationService()
            .verify(entries, extractedFileURLs: urls)
        XCTAssertEqual(evidence.count, entries.count)
        XCTAssertTrue(entries.allSatisfy { evidence[$0.receiptID] != nil })

        let artifacts = try entries.map { entry in
            PDFOfficeVerifiedArtifact(
                entry: entry,
                url: try XCTUnwrap(urls[entry.archiveName]),
                formatEvidence: try XCTUnwrap(evidence[entry.receiptID])
            )
        }
        let verifiedURLs = try PDFOfficeArtifactShareVerificationService()
            .verify(artifacts)
        XCTAssertEqual(
            Set(verifiedURLs.map(\.standardizedFileURL)),
            Set(urls.values.map(\.standardizedFileURL))
        )

        let signingStore = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("OfficeArchiveSigningStore"),
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        let createdAt = PDFOfficeTimeAnchor.process.trustedDate()
        let signedReport = try await signingStore
            .signOfficeDeliveryPayload(
                PDFOfficeVerificationPayload(
                    schema: "PaperPath Office Delivery V34",
                    packageID: UUID(),
                    createdAt: createdAt,
                    expiresAt: createdAt.addingTimeInterval(3_600),
                    verifiedOutputs: entries.count,
                    files: entries
                )
            )
        let manifestURL = temporaryDirectory
            .appendingPathComponent("PaperPath-delivery-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(signedReport).write(
            to: manifestURL,
            options: .atomic
        )
        let archiveURL = temporaryDirectory
            .appendingPathComponent("verified-office-delivery.zip")
        let archiveSources = entries.map { entry in
            OfficeBatchArchiveSource(
                sourceURL: urls[entry.archiveName]!,
                archiveName: entry.archiveName
            )
        } + [
            OfficeBatchArchiveSource(
                sourceURL: manifestURL,
                archiveName: manifestURL.lastPathComponent
            )
        ]
        try OfficeBatchArchiveService().createArchive(
            sources: archiveSources,
            destination: archiveURL
        )
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.verifiedOfficeDeliveryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: extractionDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: extractionDirectory)
        }
        let archiveInspection = try PDFVersionArchiveVerificationService()
            .verifyOfficeDeliveryArchive(
                archiveURL: archiveURL,
                extractionDirectory: extractionDirectory
            )
        XCTAssertEqual(archiveInspection.verifiedFileCount, entries.count)
        XCTAssertEqual(
            Set(archiveInspection.extractedFileURLs.keys),
            Set(entries.map(\.archiveName))
        )

        let invalidText = directory.appendingPathComponent("invalid.txt")
        try Data([0xf0, 0x28, 0x8c, 0x28]).write(to: invalidText)
        let invalidEntry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Invalid UTF-8",
            receiptID: UUID(),
            format: .plainText,
            archiveName: invalidText.lastPathComponent,
            byteCount: 4,
            sha256: sha256(try Data(contentsOf: invalidText))
        )
        XCTAssertThrowsError(
            try PDFOfficeArtifactFormatVerificationService().verify(
                [invalidEntry],
                extractedFileURLs: [
                    invalidEntry.archiveName: invalidText
                ]
            )
        )
    }

    func testOutputAddedContentAndEmbeddedBookmarksRoundTrip_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("content-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let edited = temporaryDirectory
            .appendingPathComponent("content-edited.pdf")
        let imageData = try XCTUnwrap(
            makeTestImage(size: CGSize(width: 80, height: 60))
                .pngData()
        )
        let bounds = PDFNormalizedRect(
            x: 0.1,
            y: 0.1,
            width: 0.3,
            height: 0.15
        )
        let linkURL = try XCTUnwrap(URL(string: "https://example.com/review"))
        let progress = TestProgressRecorder()
        try PDFOutputService().addContent(
            sourceURL: source,
            destination: edited,
            overlays: [
                .text(
                    pageIndex: 0,
                    bounds: bounds,
                    text: "Approved",
                    fontSize: 14,
                    color: PDFInkColor(
                        red: 0.1,
                        green: 0.2,
                        blue: 0.3,
                        alpha: 1
                    )
                ),
                .link(
                    pageIndex: 0,
                    bounds: PDFNormalizedRect(
                        x: 0.1,
                        y: 0.35,
                        width: 0.5,
                        height: 0.1
                    ),
                    title: "Review source",
                    url: linkURL
                ),
                .image(
                    pageIndex: 1,
                    bounds: bounds,
                    data: imageData
                )
            ],
            progress: { progress.append($0) }
        )
        let editedDocument = try XCTUnwrap(PDFDocument(url: edited))
        XCTAssertEqual(editedDocument.pageCount, 2)
        XCTAssertEqual(editedDocument.page(at: 0)?.annotations.count, 3)
        XCTAssertEqual(progress.values.last, 1)

        let bookmarked = temporaryDirectory
            .appendingPathComponent("content-bookmarked.pdf")
        try PDFOutputService().embedBookmarks(
            sourceURL: edited,
            destination: bookmarked,
            pageIndices: [1, 0, 1, -1, 99]
        )
        let bookmarkedDocument = try XCTUnwrap(
            PDFDocument(url: bookmarked)
        )
        XCTAssertEqual(bookmarkedDocument.pageCount, 2)
        XCTAssertEqual(
            bookmarkedDocument.outlineRoot?.child(at: 0)?
                .numberOfChildren,
            2
        )

        XCTAssertThrowsError(
            try PDFOutputService().addContent(
                sourceURL: source,
                destination: temporaryDirectory
                    .appendingPathComponent("empty-content.pdf"),
                overlays: []
            )
        )
        XCTAssertThrowsError(
            try PDFOutputService().addContent(
                sourceURL: source,
                destination: temporaryDirectory
                    .appendingPathComponent("invalid-content.pdf"),
                overlays: [
                    .text(
                        pageIndex: 99,
                        bounds: bounds,
                        text: "Invalid",
                        fontSize: 12,
                        color: PDFInkColor(
                            red: 0,
                            green: 0,
                            blue: 0,
                            alpha: 1
                        )
                    )
                ]
            )
        )
    }

    func testPaperTemplateRendererCoversEveryTemplate_BitsUT() throws {
        for kind in PaperTemplateKind.allCases {
            XCTAssertFalse(kind.id.isEmpty)
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
            for size in PaperTemplateSize.allCases {
                XCTAssertFalse(size.id.isEmpty)
                XCTAssertFalse(size.title.isEmpty)
                XCTAssertGreaterThan(size.dimensions.width, 0)
                let destination = temporaryDirectory.appendingPathComponent(
                    "\(kind.rawValue)-\(size.rawValue).pdf"
                )
                try PaperTemplateRenderer().render(
                    kind: kind,
                    size: size,
                    pageCount: 2,
                    title: "\(kind.title) notes",
                    to: destination
                )
                XCTAssertEqual(
                    PDFDocument(url: destination)?.pageCount,
                    2
                )
            }
        }
        XCTAssertThrowsError(
            try PaperTemplateRenderer().render(
                kind: .blank,
                size: .letter,
                pageCount: 0,
                title: "Invalid",
                to: temporaryDirectory
                    .appendingPathComponent("invalid-template.pdf")
            )
        )
    }

    func testExternalInboxClaimRestoreAndCompleteLifecycle_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory
            .appendingPathComponent("ClaimRestoreInbox")
        let source = temporaryDirectory
            .appendingPathComponent("claim-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 1
        )
        let staged = try ExternalPDFInbox.stagePDF(
            from: source,
            suggestedName: "Claim me.pdf",
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )
        let claimed = try ExternalPDFInbox.claim(
            staged,
            sharedContainerURL: sharedContainer
        )
        XCTAssertNotEqual(claimed.containerURL, staged.containerURL)
        XCTAssertEqual(claimed.containerURL.pathExtension, "inbox")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.containerURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: claimed.containerURL.path)
        )

        try ExternalPDFInbox.restore(
            claimed,
            sharedContainerURL: sharedContainer
        )
        let restored = try XCTUnwrap(
            ExternalPDFInbox.pendingItems(
                sharedContainerURL: sharedContainer
            ).first
        )
        XCTAssertEqual(restored.id, staged.id)
        let claimedAgain = try ExternalPDFInbox.claim(
            restored,
            sharedContainerURL: sharedContainer
        )
        try ExternalPDFInbox.complete(
            claimedAgain,
            sharedContainerURL: sharedContainer
        )
        XCTAssertTrue(
            try ExternalPDFInbox.pendingItems(
                sharedContainerURL: sharedContainer
            ).isEmpty
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: claimedAgain.containerURL.path
            )
        )
        XCTAssertTrue(
            [
                ExternalPDFInboxError.sharedContainerUnavailable,
                .invalidPDF,
                .fileTooLarge,
                .inboxFull,
                .insufficientStorage,
                .incompleteCopy
            ].allSatisfy {
                !($0.errorDescription ?? "").isEmpty
            }
        )
    }

    func testSignedChangeReportCreationVerificationAndTrust_BitsUT()
        async throws {
        let now = Date()
        let region = PDFDifferenceRegion(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.08,
            intensity: 0.75
        )
        let changes = [
            PDFPageChange(
                pageIndex: 0,
                sourcePageIndex: 0,
                revisedPageIndex: 0,
                matchKind: .modified,
                sourceExists: true,
                revisedExists: true,
                visibleDifference: 0.02,
                changedPixelRatio: 0.2,
                geometryChanged: true,
                textChanged: true,
                sourceTextCharacterCount: 40,
                revisedTextCharacterCount: 52,
                differenceRegions: [region],
                sourceTextDifferences: (0..<5).map {
                    PDFTextDifferenceEvidence(
                        kind: .removed,
                        text: "Old *value* \($0)",
                        region: region,
                        granularity: $0 == 0 ? .character : .word
                    )
                },
                revisedTextDifferences: (0..<5).map {
                    PDFTextDifferenceEvidence(
                        kind: .inserted,
                        text: "New [value] \($0)",
                        region: region
                    )
                },
                matchBasis: .exactContent
            ),
            PDFPageChange(
                pageIndex: 1,
                sourcePageIndex: nil,
                revisedPageIndex: 1,
                matchKind: .inserted,
                sourceExists: false,
                revisedExists: true,
                visibleDifference: 1,
                changedPixelRatio: 1,
                geometryChanged: false,
                textChanged: false,
                sourceTextCharacterCount: 0,
                revisedTextCharacterCount: 20,
                matchBasis: .context
            ),
            PDFPageChange(
                pageIndex: 2,
                sourcePageIndex: 2,
                revisedPageIndex: nil,
                matchKind: .removed,
                sourceExists: true,
                revisedExists: false,
                visibleDifference: 1,
                changedPixelRatio: 1,
                geometryChanged: false,
                textChanged: false,
                sourceTextCharacterCount: 20,
                revisedTextCharacterCount: 0,
                matchBasis: .pageLabel
            )
        ]
        let review = PDFChangeReview(
            sourcePageCount: 3,
            revisedPageCount: 3,
            comparedPageCount: 1,
            changes: changes,
            pageMatches: [
                PDFPageMatch(
                    id: 0,
                    sourcePageIndex: 0,
                    revisedPageIndex: 0,
                    kind: .modified,
                    basis: .exactContent
                )
            ]
        )
        let descriptor = PDFChangeReportDescriptor(
            reportID: UUID(),
            scope: "Full review",
            sourceName: "Base *matter*.pdf",
            revisedName: "Revised [matter].pdf",
            sourceRevisionID: UUID(),
            revisedRevisionID: UUID(),
            sourceFingerprint: String(repeating: "a", count: 64),
            revisedFingerprint: String(repeating: "b", count: 64),
            deliveryReceiptID: UUID(),
            generatedAt: now
        )
        let service = PDFChangeReportService()
        let signingKey = Curve25519.Signing.PrivateKey()
        let signingStore = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ChangeReportSigningStore"),
            signingPrivateKeyProvider: { signingKey }
        )
        let body = try service.render(
            review: review,
            descriptor: descriptor,
            signerKeyID: try await signingStore
                .officeDeliverySigningKeyID()
        )
        XCTAssertTrue(
            String(decoding: body, as: UTF8.self)
                .contains("## Page Changes")
        )
        let payload = try service.signaturePayload(
            body: body,
            review: review,
            descriptor: descriptor
        )
        let envelope = try await signingStore
            .signChangeReportPayload(payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-ChangeReport-\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(at: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try service.create(
            body: body,
            envelope: envelope,
            directory: directory,
            fileName: "matter-change-report.md",
            referenceDate: now
        )
        let parsed = try service.parseSignedReport(
            Data(contentsOf: url)
        )
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(
            parsed.envelope.payload.reportID,
            envelope.payload.reportID
        )
        XCTAssertEqual(
            parsed.envelope.payload.bodySHA256,
            envelope.payload.bodySHA256
        )
        XCTAssertEqual(parsed.envelope.signature, envelope.signature)
        XCTAssertTrue(
            service.bodyIdentityMatches(
                parsed.body,
                payload: parsed.envelope.payload,
                signerKeyID: parsed.envelope.signature.keyID
            )
        )

        let verifyingStore = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ChangeReportVerifyingStore"),
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        let unknown = try await verifyingStore.verifyChangeReport(at: url)
        XCTAssertEqual(unknown.status, .verified)
        XCTAssertEqual(unknown.trustStatus, .unknown)
        XCTAssertTrue(unknown.canTrustSigner)
        let trusted = try await verifyingStore
            .trustChangeReportSigner(unknown)
        XCTAssertEqual(trusted.trustStatus, .trusted)
        let verifiedAgain = try await verifyingStore
            .verifyChangeReport(at: url)
        XCTAssertEqual(verifiedAgain.trustStatus, .trusted)

        let card = PDFOfficeSignerIdentityCard(
            schema: "PaperPath Signing Identity V1",
            keyID: envelope.signature.keyID,
            publicKeyBase64: envelope.signature.publicKeyBase64,
            generatedAt: now
        )
        let parsedCard = try await verifyingStore
            .parseOfficeSignerIdentityPayload(card.qrPayload)
        XCTAssertEqual(parsedCard.schema, card.schema)
        XCTAssertEqual(parsedCard.keyID, card.keyID)
        XCTAssertEqual(parsedCard.publicKeyBase64, card.publicKeyBase64)
        var signers = try await verifyingStore.updateOfficeTrustedSigner(
            keyID: card.keyID,
            displayName: "  External reviewer  ",
            note: "  Trusted for this matter  "
        )
        XCTAssertEqual(signers.first?.displayName, "External reviewer")
        signers = try await verifyingStore.removeOfficeTrustedSigner(card.keyID)
        XCTAssertTrue(signers.isEmpty)
    }

    func testDocumentStoreMetadataStorageAndSigningLifecycle_BitsUT()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("store-lifecycle.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let sourceData = try Data(contentsOf: source)
        let fingerprint = sha256(sourceData)
        let revisionID = UUID()
        let receipt = makeDeliveryReceipt(
            fingerprint: fingerprint,
            revisionID: revisionID,
            pageCount: 2,
            byteCount: Int64(sourceData.count)
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("MetadataLifecycleStore"),
            availableCapacity: { _ in 2 * 1_024 * 1_024 * 1_024 },
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        var record = try await store.importPDF(
            from: source,
            preferredName: "Matter",
            deliveryReceipt: receipt,
            contentRevisionID: revisionID,
            preserveSourceLocation: false
        )
        let containsImportedDocument = try await store.containsDocuments()
        XCTAssertTrue(containsImportedDocument)

        let signedManifest = try await store
            .signedDeliveryPackageManifest(
                for: record,
                artifactFileName: "Matter-final.pdf"
            )
        XCTAssertEqual(
            signedManifest.manifest.artifact.sha256,
            fingerprint
        )
        XCTAssertEqual(
            signedManifest.manifest.deliveryReceiptID,
            receipt.id
        )

        let firstDuplicate = try await store.duplicate(record)
        let secondDuplicate = try await store.duplicate(record)
        XCTAssertNotEqual(firstDuplicate.displayName, secondDuplicate.displayName)
        let duplicatedIDs = Set([
            record.id,
            firstDuplicate.id,
            secondDuplicate.id
        ])
        var updatedRecords = try await store.updateWorkflow(
            recordIDs: duplicatedIDs,
            status: .reviewing
        )
        XCTAssertEqual(updatedRecords.count, 3)
        XCTAssertTrue(
            updatedRecords.allSatisfy {
                $0.workflowStatus == .reviewing
            }
        )
        updatedRecords = try await store.setPinned(
            recordIDs: duplicatedIDs,
            isPinned: true
        )
        XCTAssertTrue(updatedRecords.allSatisfy(\.isPinned))
        updatedRecords = try await store.updateTags([
            record.id: ["  Legal  ", "legal", String(repeating: "x", count: 40)],
            firstDuplicate.id: ["Review"],
            secondDuplicate.id: ["Archive"]
        ])
        XCTAssertEqual(updatedRecords.count, 3)

        record = try XCTUnwrap(
            updatedRecords.first { $0.id == record.id }
        )
        record = try await store.setPinned(record, isPinned: false)
        record = try await store.updateDueDate(
            record,
            dueAt: Date(timeIntervalSince1970: 200_000),
            expectedDueAt: record.dueAt
        )
        record = try await store.updatePrivateNote(
            record,
            note: "  Preserve the signed source.  ",
            expectedNote: record.privateNote
        )
        record = try await store.updateBookmarks(
            record,
            pages: [1, 0, 1, -1, 99]
        )
        record = try await store.updateBookmarkName(
            record,
            pageIndex: 1,
            name: "  Approval page  "
        )
        XCTAssertEqual(record.bookmarkedPages, [0, 1])
        XCTAssertEqual(record.bookmarkNames[1], "Approval page")
        XCTAssertEqual(record.tags.first, "Legal")
        XCTAssertEqual(record.tags.last?.count, 24)
        XCTAssertEqual(record.privateNote, "Preserve the signed source.")

        let viewedAt = Date().addingTimeInterval(30)
        record = try await store.updateReadingPosition(
            recordID: record.id,
            pageIndex: 99,
            expectedRevisionID: record.contentRevisionID,
            viewedAt: viewedAt
        )
        XCTAssertEqual(record.lastPageIndex, 1)
        let staleReadingPosition = try await store.updateReadingPosition(
            recordID: record.id,
            pageIndex: 0,
            expectedRevisionID: record.contentRevisionID,
            viewedAt: viewedAt.addingTimeInterval(-10)
        )
        XCTAssertEqual(staleReadingPosition.lastPageIndex, 1)
        let storedRecords = try await store.load()
        let syncBaseline = try XCTUnwrap(
            storedRecords.first(where: { $0.id == record.id })
        )

        let syncDate = Date().addingTimeInterval(3_600)
        let synchronized = try await store.applyMetadataSync(
            PDFMetadataSyncUpdate(
                recordID: record.id,
                fingerprint: fingerprint.uppercased(),
                expectedLocalState:
                    PDFMetadataSyncLocalState(syncBaseline),
                lastPageIndex: -10,
                lastViewedAt: syncDate,
                bookmarkedPages: [1, 1, 20],
                workflowStatus: .ready,
                isPinned: true,
                tags: [" Synced ", "synced", "Evidence"],
                completedActions: [.inspect, .safeShare],
                deliveryReceipt: receipt,
                updatedAt: syncDate
            ),
            to: syncBaseline
        )
        XCTAssertEqual(synchronized.lastPageIndex, 0)
        XCTAssertEqual(synchronized.bookmarkedPages, [1])
        XCTAssertEqual(synchronized.workflowStatus, .ready)
        XCTAssertEqual(synchronized.tags, ["Synced", "Evidence"])
        XCTAssertTrue(synchronized.hasCurrentDeliveryReceipt)

        let emptyAnalysis = try await store.loadAnalysis(for: [])
        XCTAssertTrue(emptyAnalysis.textIndices.isEmpty)
        XCTAssertTrue(emptyAnalysis.ocrResults.isEmpty)
        let missingAnalysis = try await store.loadAnalysis(
            for: [record.id]
        )
        XCTAssertTrue(missingAnalysis.textIndices.isEmpty)
        XCTAssertTrue(missingAnalysis.ocrResults.isEmpty)

        let preflight = PDFDeliveryPreflightCacheEntry(
            recordID: record.id,
            revisionID: record.contentRevisionID,
            checkedAt: Date(),
            assessment: PDFDeliveryPreflightAssessment(
                status: .ready,
                pageCount: record.profile.pageCount,
                byteCount: record.profile.byteCount,
                fixCount: 0,
                reviewCount: 0,
                items: [
                    PDFDeliveryPreflightItem(
                        id: "reopen",
                        title: "Reopen",
                        detail: "The working copy is readable.",
                        status: .passed
                    )
                ]
            )
        )
        try await store.saveDeliveryPreflight(preflight)
        let loadedPreflight = try await store.loadDeliveryPreflightCache(
            for: [record]
        )
        let restoredPreflight = try XCTUnwrap(loadedPreflight[record.id])
        XCTAssertEqual(restoredPreflight.recordID, preflight.recordID)
        XCTAssertEqual(restoredPreflight.revisionID, preflight.revisionID)
        XCTAssertEqual(restoredPreflight.assessment, preflight.assessment)
        XCTAssertEqual(
            restoredPreflight.checkedAt.timeIntervalSince1970,
            preflight.checkedAt.timeIntervalSince1970,
            accuracy: 1
        )
        await store.removeDeliveryPreflight(recordID: record.id)

        let batchDate = Date()
        let batchRun = PDFBatchDeliveryRun(
            id: UUID(),
            startedAt: batchDate,
            updatedAt: batchDate,
            sourceRecordIDs: [record.id],
            sourceRevisionIDs: [
                record.id: record.contentRevisionID
            ],
            items: [
                PDFBatchDeliveryItem(
                    sourceRecordID: record.id,
                    stage: .queued,
                    detail: "Waiting"
                )
            ]
        )
        try await store.saveBatchDeliveryRun(batchRun)
        let persistedBatchRun = try await store.loadBatchDeliveryRun()
        let loadedBatchRun = try XCTUnwrap(persistedBatchRun)
        XCTAssertEqual(loadedBatchRun.id, batchRun.id)
        XCTAssertEqual(loadedBatchRun.sourceRecordIDs, batchRun.sourceRecordIDs)
        XCTAssertEqual(
            loadedBatchRun.sourceRevisionIDs,
            batchRun.sourceRevisionIDs
        )
        XCTAssertEqual(loadedBatchRun.items, batchRun.items)
        XCTAssertEqual(
            loadedBatchRun.startedAt.timeIntervalSince1970,
            batchRun.startedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            loadedBatchRun.updatedAt.timeIntervalSince1970,
            batchRun.updatedAt.timeIntervalSince1970,
            accuracy: 1
        )
        await store.clearBatchDeliveryRun()
        let clearedBatchRun = try await store.loadBatchDeliveryRun()
        XCTAssertNil(clearedBatchRun)

        let officeQueueDate = Date(timeIntervalSince1970: 100)
        let officeQueue = PDFOfficeProductionQueue(
            jobs: [
                PDFOfficeQueueJob(
                    recordID: record.id,
                    sourceRevisionID: record.contentRevisionID,
                    sourceName: record.displayName,
                    sourcePageCount: record.profile.pageCount,
                    format: .wordDocument,
                    priority: .urgent,
                    createdAt: officeQueueDate
                )
            ],
            updatedAt: officeQueueDate
        )
        try await store.saveOfficeProductionQueue(officeQueue)
        let loadedOfficeQueue = try await store
            .loadOfficeProductionQueue()
        XCTAssertEqual(loadedOfficeQueue.jobs, officeQueue.jobs)
        await store.clearOfficeProductionQueue()
        let clearedOfficeQueue = try await store
            .loadOfficeProductionQueue()
        XCTAssertTrue(clearedOfficeQueue.jobs.isEmpty)

        let officePlan = PDFOfficeExportFormatPlan.plan(
            for: .wordDocument,
            profile: record.profile
        )
        let officeReceipt = PDFOfficeExportReceipt(
            format: .wordDocument,
            fileName: "Matter.docx",
            fileSizeBytes: 4_096,
            plan: officePlan,
            budgetPlan: PDFOfficeVisualBudgetPlan(
                profile: record.profile
            )
        )
        record = try await store.recordOfficeExportReceipt(
            officeReceipt,
            for: record
        )
        XCTAssertEqual(record.officeReceipts.first?.id, officeReceipt.id)
        let officeBatchPlan = PDFOfficeBatchPlan(
            format: .wordDocument,
            sourceRevisionID: record.contentRevisionID,
            profile: record.profile
        )
        let officeBatchRun = PDFOfficeBatchRun(plan: officeBatchPlan)
        record = try await store.updateOfficeBatchRun(
            officeBatchRun,
            for: record
        )
        XCTAssertEqual(record.officeBatchRun?.id, officeBatchRun.id)

        let storage = try await store.storageSnapshot()
        XCTAssertGreaterThan(storage.pdfBytes, 0)
        XCTAssertGreaterThan(storage.metadataBytes, 0)
        let available = try await store
            .availableCapacityForOfficeProduction()
        XCTAssertEqual(available, 2 * 1_024 * 1_024 * 1_024)
        try await store.ensureTemporaryWorkingCapacity(
            for: [source, source],
            copyMultiplier: 2,
            reserveBytes: 0
        )

        _ = try await store.moveToTrash(firstDuplicate)
        do {
            _ = try await store.permanentlyDelete(
                recordIDs: [firstDuplicate.id, secondDuplicate.id]
            )
            XCTFail("Mixed Trash state must reject the whole deletion")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("no longer in Trash")
            )
        }
        let deletedAfterRejectedBatch = try await store.loadDeleted()
        let expectedDeletedIDs = [firstDuplicate.id]
        XCTAssertEqual(
            deletedAfterRejectedBatch.map(\.id),
            expectedDeletedIDs
        )
        guard deletedAfterRejectedBatch.map(\.id)
                == expectedDeletedIDs
        else { return }
        let activeAfterRejectedBatch = try await store.load()
        XCTAssertTrue(
            activeAfterRejectedBatch.contains {
                $0.id == secondDuplicate.id
            }
        )

        _ = try await store.moveToTrash(secondDuplicate)
        let deletedDuplicateIDs = try await store.permanentlyDelete(
            recordIDs: [firstDuplicate.id, secondDuplicate.id]
        )
        XCTAssertEqual(Set(deletedDuplicateIDs), Set([
            firstDuplicate.id,
            secondDuplicate.id
        ]))
        let trashedRecord = try await store.moveToTrash(record)
        try await store.delete(trashedRecord)
        let containsAfterDeletion = try await store.containsDocuments()
        XCTAssertFalse(containsAfterDeletion)
        try await store.eraseAllData()
        let recordsAfterErase = try await store.load()
        XCTAssertTrue(recordsAfterErase.isEmpty)
    }

    func testResidualServiceEntryPointsAndSearchContracts_BitsUT()
        throws {
        let mixed = temporaryDirectory
            .appendingPathComponent("residual-mixed.pdf")
        try PDFTestFixtureFactory.makeMixedGeometryPDF(at: mixed)
        let profile = try PDFInspectionService().inspect(url: mixed)
        let technical = try PDFDocumentStructureService()
            .technicalInspection(
                in: mixed,
                profile: profile,
                source: nil
            )
        XCTAssertEqual(technical.pageCount, 4)
        XCTAssertEqual(technical.sampledPageCount, profile.sampledPageCount)
        XCTAssertNotNil(technical.permissions)

        let preparationProgress = TestProgressRecorder()
        let assessment = try PDFMutationService()
            .pagePreparationAssessment(
                in: mixed,
                revisionID: UUID(),
                progress: { preparationProgress.append($0) }
            )
        XCTAssertEqual(assessment.pages.count, 4)
        XCTAssertEqual(preparationProgress.values.last, 1)
        XCTAssertTrue(
            assessment.pages.allSatisfy {
                $0.widthPoints > 0
                    && $0.heightPoints > 0
                    && $0.inkCoverage.isFinite
            }
        )

        let flattened = temporaryDirectory
            .appendingPathComponent("residual-flattened.pdf")
        try PDFOutputService().flatten(
            sourceURL: mixed,
            destination: flattened
        )
        XCTAssertEqual(
            try XCTUnwrap(PDFDocument(url: flattened)).pageCount,
            4
        )
        let compressionEstimates = [
            PDFCompressionEstimate(
                sourceByteCount: 10_000,
                estimatedByteCount: 4_000,
                sampledPageCount: 1
            ),
            PDFCompressionEstimate(
                sourceByteCount: 10_000,
                estimatedByteCount: 12_000,
                sampledPageCount: 2
            )
        ]
        XCTAssertEqual(compressionEstimates.first?.savingsPercent, 60)
        XCTAssertNil(compressionEstimates.last?.savingsPercent)
        XCTAssertTrue(
            compressionEstimates.allSatisfy {
                !$0.formattedSize.isEmpty && !$0.summary.isEmpty
            }
        )
        XCTAssertTrue(
            PDFCompressionQuality.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.detail.isEmpty
            }
        )

        let invoice = temporaryDirectory
            .appendingPathComponent("demo-invoice.pdf")
        let report = temporaryDirectory
            .appendingPathComponent("demo-report.pdf")
        try DemoPDFBuilder.createInvoice(at: invoice)
        try DemoPDFBuilder.createReport(at: report)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: invoice)).pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: report)).pageCount, 1)

        let combined = temporaryDirectory
            .appendingPathComponent("residual-combined.pdf")
        let composition = PDFCompositionService()
        try composition.combine(urls: [invoice, report], to: combined)
        try composition.combine(urls: [report, invoice], to: combined)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: combined)).pageCount, 2)

        let quad = ScanCropQuad(
            topLeft: ScanCropPoint(x: 0.08, y: 0.06),
            topRight: ScanCropPoint(x: 0.92, y: 0.08),
            bottomRight: ScanCropPoint(x: 0.9, y: 0.94),
            bottomLeft: ScanCropPoint(x: 0.1, y: 0.91)
        )
        XCTAssertTrue(quad.isValid)
        XCTAssertFalse(quad.isEffectivelyFullFrame)
        XCTAssertFalse(quad.cacheKey.isEmpty)
        XCTAssertEqual(
            ScanCropCorner.allCases.map { quad.point(for: $0) }.count,
            4
        )
        XCTAssertTrue(
            ScanEnhancement.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PaperTemplateKind.allCases.allSatisfy {
                !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            PaperTemplateSize.allCases.allSatisfy {
                !$0.id.isEmpty
                    && !$0.title.isEmpty
                    && $0.dimensions.width > 0
            }
        )
        let scanRenderer = ScanPDFRenderer()
        let image = makeTestImage(size: CGSize(width: 96, height: 72))
        XCTAssertNotNil(
            scanRenderer.preview(
                image: image,
                enhancement: .grayscale
            ).cgImage
        )
        let scanURL = temporaryDirectory
            .appendingPathComponent("residual-scan.pdf")
        try scanRenderer.render(
            pages: [ScanPageImage(image: image)],
            to: scanURL,
            enhancement: .blackAndWhite
        )
        scanRenderer.releaseCachedResources()
        VisionOCRService().releaseCachedResources()
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: scanURL)).pageCount, 1)

        let index = DocumentTextIndex(
            source: .native,
            pages: (0..<20).map {
                IndexedPageText(
                    pageIndex: $0,
                    text: $0.isMultiple(of: 2)
                        ? "Invoice approval evidence \($0)"
                        : "Unrelated page \($0)"
                )
            },
            indexedAt: Date()
        )
        XCTAssertTrue(
            try index.containsEveryTerm(["invoice", "approval"])
        )
        XCTAssertFalse(
            try index.containsEveryTerm(["invoice", "missing"])
        )
        XCTAssertEqual(
            try index.cancellableMatches(
                for: "invoice approval",
                excerptLimit: 48,
                limit: 3
            ).count,
            3
        )
        let indexedOCR = PDFTextIndexService().index(
            from: OCRResult(
                pages: [
                    OCRPageResult(
                        pageIndex: 0,
                        text: "Recognized invoice",
                        confidence: 0.9,
                        blocks: [
                            makeOCRBlock(
                                text: "Recognized invoice",
                                confidence: 0.9
                            )
                        ]
                    )
                ]
            )
        )
        XCTAssertEqual(indexedOCR.source, .vision)
        XCTAssertEqual(indexedOCR.pages.first?.text, "Recognized invoice")
    }

    func testRemainingModelDerivedContracts_BitsUT() throws {
        let now = PDFOfficeTimeAnchor.process.trustedDate()
        let profile = makeProfile(pageCount: 1_205)
        let plan = PDFOfficeBatchPlan(
            format: .wordDocument,
            sourceRevisionID: UUID(),
            profile: profile
        )
        let segment = try XCTUnwrap(plan.segments.first)
        var receipt = PDFOfficeExportReceipt(
            format: .wordDocument,
            fileName: "Matter.docx",
            fileSizeBytes: 8_192,
            plan: PDFOfficeExportFormatPlan.plan(
                for: .wordDocument,
                profile: profile
            ),
            budgetPlan: PDFOfficeVisualBudgetPlan(profile: profile),
            portfolio: PDFOfficeExportPortfolio(profile: profile),
            batchPlan: plan,
            batchSegment: segment
        )
        receipt.sourceRevisionID = plan.sourceRevisionID
        receipt.retainedFileName = "retained.docx"
        receipt.reusableUntil = now.addingTimeInterval(3_600)
        receipt.artifactSHA256 = String(repeating: "a", count: 64)
        XCTAssertFalse(receipt.formattedSize.isEmpty)
        XCTAssertFalse(receipt.shortTime.isEmpty)
        XCTAssertFalse(receipt.receiptSummary.isEmpty)
        XCTAssertFalse(receipt.auditEvidenceSummary.isEmpty)
        XCTAssertTrue(receipt.isBatchSegment)
        XCTAssertNotNil(receipt.batchSummary)
        XCTAssertFalse(receipt.retentionSummary.isEmpty)
        XCTAssertFalse(receipt.integritySummary.isEmpty)

        let pinnedOutput = PDFPinnedOfficeOutput(
            recordID: UUID(),
            documentName: "Matter",
            receipt: receipt
        )
        let officeStorage = PDFOfficePinnedStorageSummary.measuring(
            [pinnedOutput]
        )
        XCTAssertFalse(officeStorage.formattedBytes.isEmpty)
        XCTAssertFalse(officeStorage.countContract.isEmpty)
        XCTAssertFalse(officeStorage.byteContract.isEmpty)
        XCTAssertGreaterThan(officeStorage.byteUsageFraction, 0)
        XCTAssertGreaterThan(officeStorage.countUsageFraction, 0)
        XCTAssertGreaterThan(officeStorage.pressureFraction, 0)
        XCTAssertFalse(officeStorage.formattedRemainingBytes.isEmpty)

        let versionStorage = PDFPinnedVersionStorageSummary(
            milestoneCount: 8,
            byteCount: 256 * 1_024 * 1_024
        )
        XCTAssertFalse(versionStorage.formattedBytes.isEmpty)
        XCTAssertFalse(versionStorage.countContract.isEmpty)
        XCTAssertFalse(versionStorage.byteContract.isEmpty)
        XCTAssertGreaterThan(versionStorage.countUsageFraction, 0)
        XCTAssertGreaterThan(versionStorage.pressureFraction, 0)
        XCTAssertFalse(versionStorage.formattedRemainingBytes.isEmpty)

        let entry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Matter",
            receiptID: receipt.id,
            format: .wordDocument,
            archiveName: receipt.fileName,
            byteCount: receipt.fileSizeBytes,
            sha256: try XCTUnwrap(receipt.artifactSHA256)
        )
        let candidate = PDFOfficeExternalCandidate(
            id: UUID(),
            fileName: entry.archiveName,
            fileExtension: entry.format.fileExtension,
            byteCount: entry.byteCount,
            sha256: entry.sha256
        )
        XCTAssertFalse(candidate.formattedSize.isEmpty)
        XCTAssertEqual(candidate.shortFingerprint.count, 12)
        let officeMatch = PDFOfficeExternalMatchReport(
            id: UUID(),
            packageID: UUID(),
            checkedAt: now,
            matches: [
                PDFOfficeExternalEntryMatch(
                    entry: entry,
                    status: .exact,
                    candidates: [candidate]
                ),
                PDFOfficeExternalEntryMatch(
                    entry: entry,
                    status: .missing,
                    candidates: []
                ),
                PDFOfficeExternalEntryMatch(
                    entry: entry,
                    status: .ambiguous,
                    candidates: [candidate]
                ),
                PDFOfficeExternalEntryMatch(
                    entry: entry,
                    status: .inconsistent,
                    candidates: [candidate]
                )
            ],
            extraCandidates: [candidate],
            totalCandidateCount: 1,
            totalCandidateBytes: candidate.byteCount
        )
        XCTAssertEqual(officeMatch.missingCount, 1)
        XCTAssertEqual(officeMatch.ambiguousCount, 1)
        XCTAssertEqual(officeMatch.inconsistentCount, 1)
        XCTAssertEqual(officeMatch.reviewCount, 4)
        XCTAssertEqual(
            PDFOfficeExternalMatchProgress(
                packageID: officeMatch.packageID,
                completedFileCount: 1,
                totalFileCount: 4,
                processedBytes: 0,
                totalBytes: 0,
                currentFileName: candidate.fileName
            ).fractionCompleted,
            0.25
        )

        var package = PDFOfficeDeliveryPackage(
            id: officeMatch.packageID,
            createdAt: now,
            entries: [entry]
        )
        package.byteCount = 10_000
        package.expiresAt = now.addingTimeInterval(60)
        XCTAssertFalse(package.formattedSize.isEmpty)
        XCTAssertFalse(package.isExpired)
        XCTAssertFalse(package.retentionSummary.isEmpty)
        package.pinnedAt = now
        XCTAssertFalse(
            package.retentionSummary(
                at: now.addingTimeInterval(120)
            ).isEmpty
        )

        XCTAssertTrue(
            [
                PDFBatesExternalEntryMatchStatus.outputMatch,
                .removedMatch,
                .sourceMatch,
                .missing,
                .ambiguous
            ].allSatisfy {
                !$0.title.isEmpty && !$0.symbol.isEmpty
            }
        )
        XCTAssertTrue(
            [
                PDFImageObjectSnapshot.Storage.jpeg,
                .flate,
                .flateWithSoftMask
            ].allSatisfy { !$0.detail.isEmpty }
        )
        let issues = [
            PDFBatchDeliveryIssue.sourceUnavailable(),
            .preflightFailed("Preflight failed"),
            .blocked("Blocked"),
            .review("Review"),
            .renderingFailed("Render failed"),
            .verificationFailed("Verification failed"),
            .savingFailed("Save failed"),
            .cancelled
        ]
        XCTAssertTrue(issues.allSatisfy {
            !$0.code.isEmpty
                && !$0.recovery.isEmpty
                && !($0.errorDescription ?? "").isEmpty
        })

        let record = makeRecord(name: "Derived", pageCount: 2)
        XCTAssertFalse(record.subtitle.isEmpty)
        XCTAssertFalse(
            makeDeliveryReceipt(
                fingerprint: String(repeating: "b", count: 64),
                revisionID: UUID(),
                pageCount: 2,
                byteCount: 2_048
            ).formattedOutputSize.isEmpty
        )
        let evidence = PDFEvidenceOverlay(
            pageIndex: 0,
            regions: [
                PDFDifferenceRegion(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.2,
                    intensity: 0.5
                )
            ],
            tone: .revised,
            generation: 1
        )
        XCTAssertEqual(evidence.pageIndex, 0)
    }

    func testTextReplacementAndContentValidationSafetyMatrix_BitsUT()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("text-safety-matrix.pdf")
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 3
        )
        let service = PDFOutputService()
        let color = PDFInkColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )

        func region(
            pageIndex: Int,
            width: Double = 0.5,
            lineCount: Int = 1,
            text: String = "Original"
        ) -> PDFTextFlowRegion {
            PDFTextFlowRegion(
                pageIndex: pageIndex,
                normalizedX: 0.1,
                normalizedY: 0.1,
                normalizedWidth: width,
                normalizedHeight: 0.1,
                lineCount: lineCount,
                originalText: text
            )
        }

        func selection(
            originalText: String = "Original",
            lineCount: Int = 1,
            hasMixedFonts: Bool = false,
            pageRotation: Int = 0,
            regions: [PDFTextFlowRegion] = []
        ) -> PDFTextSelectionSnapshot {
            PDFTextSelectionSnapshot(
                pageIndex: regions.first?.pageIndex ?? 0,
                originalText: originalText,
                normalizedX: 0.1,
                normalizedY: 0.1,
                normalizedWidth: 0.5,
                normalizedHeight: 0.1,
                fontName: "Helvetica",
                fontSize: 12,
                color: color,
                lineCount: lineCount,
                hasMixedFonts: hasMixedFonts,
                pageRotation: pageRotation,
                flowRegions: regions
            )
        }

        let blockedSelections: [
            (
                selection: PDFTextSelectionSnapshot,
                replacement: String
            )
        ] = [
            (
                selection(
                    regions: [
                        region(pageIndex: 0),
                        region(pageIndex: 2)
                    ]
                ),
                "Replacement"
            ),
            (selection(), "   "),
            (selection(), "Original"),
            (selection(pageRotation: 90), "Replacement"),
            (selection(hasMixedFonts: true), "Replacement"),
            (
                selection(
                    lineCount: 97,
                    regions: [
                        region(pageIndex: 0, lineCount: 97)
                    ]
                ),
                "Replacement"
            ),
            (
                selection(
                    regions: [
                        region(pageIndex: 0, width: 0.001)
                    ]
                ),
                "Replacement"
            ),
            (
                selection(originalText: "Definitely absent"),
                "Replacement"
            )
        ]
        var firstBlockedAssessment: PDFTextReplacementAssessment?
        for item in blockedSelections {
            let assessment = try service.assessTextReplacement(
                sourceURL: source,
                selection: item.selection,
                replacement: item.replacement,
                fontStyle: .serif,
                alignment: .center
            )
            XCTAssertEqual(assessment.status, .blocked)
            XCTAssertFalse(assessment.isReady)
            XCTAssertFalse(assessment.title.isEmpty)
            XCTAssertFalse(assessment.detail.isEmpty)
            firstBlockedAssessment = firstBlockedAssessment ?? assessment
        }
        let blocked = try XCTUnwrap(firstBlockedAssessment)
        XCTAssertThrowsError(
            try service.replaceText(
                sourceURL: source,
                destination: temporaryDirectory
                    .appendingPathComponent("blocked-replacement.pdf"),
                selection: blockedSelections[0].selection,
                replacement: blockedSelections[0].replacement,
                assessment: blocked
            )
        )

        let invalidOverlays: [PDFContentOverlay] = [
            .text(
                pageIndex: -1,
                bounds: PDFNormalizedRect(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                text: "Invalid page",
                fontSize: 12,
                color: color
            ),
            .text(
                pageIndex: 0,
                bounds: PDFNormalizedRect(
                    x: .nan,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                text: "Invalid bounds",
                fontSize: 12,
                color: color
            ),
            .text(
                pageIndex: 0,
                bounds: PDFNormalizedRect(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                text: " ",
                fontSize: 12,
                color: color
            ),
            .link(
                pageIndex: 0,
                bounds: PDFNormalizedRect(
                    x: 0.1,
                    y: 0.1,
                    width: 0.2,
                    height: 0.1
                ),
                title: "Unsupported",
                url: try XCTUnwrap(URL(string: "file:///tmp/unsafe"))
            )
        ]
        for (index, overlay) in invalidOverlays.enumerated() {
            XCTAssertThrowsError(
                try service.addContent(
                    sourceURL: source,
                    destination: temporaryDirectory
                        .appendingPathComponent(
                            "invalid-overlay-\(index).pdf"
                        ),
                    overlays: [overlay]
                )
            )
        }
    }

    private func makeOCRBlock(
        text: String,
        confidence: Double,
        isUserCorrected: Bool = false
    ) -> OCRTextBlock {
        OCRTextBlock(
            text: text,
            confidence: confidence,
            normalizedX: 0.1,
            normalizedY: 0.1,
            normalizedWidth: 0.8,
            normalizedHeight: 0.08,
            isUserCorrected: isUserCorrected
        )
    }

    private func makeProfile(pageCount: Int) -> DocumentProfile {
        DocumentProfile(
            pageCount: pageCount,
            sampledPageCount: min(pageCount, 12),
            textCharacterCount: pageCount * 80,
            imageDominantPageCount: 0,
            formFieldCount: 0,
            byteCount: Int64(pageCount * 1_024),
            isEncrypted: false,
            isLocked: false,
            allowsCopying: true,
            allowsCommenting: true,
            kind: .text,
            recommendedActions: [.inspect, .shareCopy]
        )
    }

    private func makeDeliveryReceipt(
        fingerprint: String,
        revisionID: UUID,
        pageCount: Int,
        byteCount: Int64
    ) -> PDFDeliveryReceipt {
        PDFDeliveryReceipt(
            id: UUID(),
            operation: .safeShare,
            createdAt: Date(),
            sourcePageCount: pageCount,
            outputPageCount: pageCount,
            renderedPageCount: pageCount,
            sourceByteCount: byteCount,
            outputByteCount: byteCount,
            unexpectedBlankPageIndices: [],
            annotationCount: 0,
            textCharacterCount: 100,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: fingerprint,
            checks: [
                PDFDeliveryCheck(
                    id: "reopened",
                    title: "Output reopened",
                    detail: "Output passed local verification.",
                    status: .passed
                )
            ],
            outputRevisionID: revisionID
        )
    }

    private func makeSignedDeliveryPackage(
        name: String,
        tampersSignature: Bool
    ) async throws -> (
        archiveURL: URL,
        artifactName: String,
        artifactData: Data
    ) {
        let artifactName = "\(name).pdf"
        let artifactURL = temporaryDirectory
            .appendingPathComponent(artifactName)
        try PDFTestFixtureFactory.makeTextPDF(
            at: artifactURL,
            pageCount: 2
        )
        let artifactData = try Data(contentsOf: artifactURL)
        let fingerprint = SHA256.hash(data: artifactData)
            .map { String(format: "%02x", $0) }
            .joined()
        var record = makeRecord(name: name, pageCount: 2)
        record.contentFingerprint = fingerprint
        record.deliveryReceipt = PDFDeliveryReceipt(
            id: UUID(),
            operation: .safeShare,
            createdAt: Date(timeIntervalSince1970: 100),
            sourcePageCount: 2,
            outputPageCount: 2,
            renderedPageCount: 2,
            sourceByteCount: Int64(artifactData.count),
            outputByteCount: Int64(artifactData.count),
            unexpectedBlankPageIndices: [],
            annotationCount: 0,
            textCharacterCount: 120,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: fingerprint,
            checks: [
                PDFDeliveryCheck(
                    id: "reopened",
                    title: "Final copy reopened",
                    detail: "Both pages rendered after creation.",
                    status: .passed
                )
            ],
            outputRevisionID: record.contentRevisionID
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "DeliverySigning-\(UUID().uuidString)",
                isDirectory: true
            ),
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        let manifest = PDFDeliveryPackageManifest(
            artifactFileName: artifactName,
            record: record,
            receipt: try XCTUnwrap(record.deliveryReceipt)
        )
        let signed = try await store.signDeliveryPackageManifest(
            manifest
        )
        let packaged: PDFSignedDeliveryPackageManifest
        if tampersSignature {
            packaged = PDFSignedDeliveryPackageManifest(
                manifest: signed.manifest,
                signature: PDFOfficeVerificationSignature(
                    algorithm: signed.signature.algorithm,
                    keyID: signed.signature.keyID,
                    publicKeyBase64:
                        signed.signature.publicKeyBase64,
                    signatureBase64: Data(
                        repeating: 0,
                        count: 64
                    ).base64EncodedString()
                )
            )
        } else {
            packaged = signed
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = temporaryDirectory
            .appendingPathComponent(
                "\(name)-PaperPath-delivery-receipt.json"
            )
        try encoder.encode(packaged).write(
            to: manifestURL,
            options: .atomic
        )
        let archiveURL = temporaryDirectory
            .appendingPathComponent("\(name).zip")
        try OfficeBatchArchiveService().createArchive(
            sources: [
                OfficeBatchArchiveSource(
                    sourceURL: artifactURL,
                    archiveName: artifactName
                ),
                OfficeBatchArchiveSource(
                    sourceURL: manifestURL,
                    archiveName: "PaperPath-delivery-receipt.json"
                )
            ],
            destination: archiveURL
        )
        return (archiveURL, artifactName, artifactData)
    }

    private func makeRecord(
        name: String,
        pageCount: Int
    ) -> DocumentRecord {
        DocumentRecord(
            displayName: name,
            fileName: "\(UUID().uuidString).pdf",
            profile: makeProfile(pageCount: pageCount)
        )
    }

    private func makeBatesEntry(
        record: DocumentRecord,
        outputRevisionID: UUID,
        start: Int64,
        end: Int64,
        sourceHash: String,
        outputHash: String
    ) -> PDFBatesBatchReceiptEntry {
        PDFBatesBatchReceiptEntry(
            recordID: record.id,
            displayName: record.displayName,
            pageCount: record.profile.pageCount,
            startNumber: start,
            endNumber: end,
            startIdentifier: PDFBatesNumberingPayload.text(
                number: start,
                digitCount: 4,
                prefix: "CASE-",
                suffix: ""
            ),
            endIdentifier: PDFBatesNumberingPayload.text(
                number: end,
                digitCount: 4,
                prefix: "CASE-",
                suffix: ""
            ),
            sourceRevisionID: record.contentRevisionID,
            outputRevisionID: outputRevisionID,
            sourceSHA256: sourceHash,
            outputSHA256: outputHash
        )
    }

    private func makeTestImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            UIColor(white: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(
                CGRect(
                    x: size.width * 0.1,
                    y: size.height * 0.1,
                    width: size.width * 0.8,
                    height: size.height * 0.8
                )
            )
            UIColor.white.setFill()
            context.fill(
                CGRect(
                    x: size.width * 0.18,
                    y: size.height * 0.18,
                    width: size.width * 0.64,
                    height: size.height * 0.64
                )
            )
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func makeQueueJob(
        recordID: UUID,
        revisionID: UUID,
        priority: PDFOfficeQueuePriority,
        createdAt: Date
    ) -> PDFOfficeQueueJob {
        PDFOfficeQueueJob(
            recordID: recordID,
            sourceRevisionID: revisionID,
            sourceName: "Queue source",
            sourcePageCount: 2,
            format: .wordDocument,
            priority: priority,
            createdAt: createdAt
        )
    }

    private func makeBlankPDF(
        at url: URL,
        pageCount: Int
    ) throws {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: 612,
            height: 792
        )
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for _ in 0..<pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
            }
        }
    }
}

final class PageReplacementOwnershipTests: XCTestCase {
    @MainActor
    func testReplacePage_preservesSourceOwnershipAndReleasesOperations_BitsUT()
        async throws {
        let syncKey = AppPreferences.metadataSyncEnabledKey
        let previousSync = UserDefaults.standard.object(forKey: syncKey)
        UserDefaults.standard.set(false, forKey: syncKey)
        defer {
            if let previousSync {
                UserDefaults.standard.set(previousSync, forKey: syncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: syncKey)
            }
        }
        for scenario in [
            "replacing", "source-busy", "cancelled", "invalid-page",
            "stale-source", "stale-destination", "same-document"
        ] {
            try await exerciseReplacement(scenario: scenario)
        }
    }

    @MainActor
    private func exerciseReplacement(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplacementOwnership-\(UUID())")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 2)
        let gate = ReplacementCapacityGate()
        defer { gate.release() }
        let store = DocumentStore(
            rootURL: root.appendingPathComponent("Store"),
            availableCapacity: { _ in gate.capacity() }
        )
        let source = try await store.importPDF(
            from: input, preserveSourceLocation: false
        )
        let destination = try await store.importPDF(
            from: input, preserveSourceLocation: false
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let sourceURL = try XCTUnwrap(model.url(for: source.id))
        let destinationURL = try XCTUnwrap(model.url(for: destination.id))
        let sourceBytes = try Data(contentsOf: sourceURL)
        let destinationBytes = try Data(contentsOf: destinationURL)
        let replace: @MainActor () async -> Bool = {
            await model.replacePage(
                recordID: destination.id,
                index: 0,
                from: scenario == "same-document"
                    ? destination.id : source.id,
                sourceIndex: scenario == "invalid-page" ? 10 : 1,
                expectedDestinationContentRevisionID:
                    scenario == "stale-destination"
                        ? UUID() : destination.contentRevisionID,
                expectedSourceContentRevisionID:
                    scenario == "stale-source"
                        ? UUID() : source.contentRevisionID
            )
        }

        var replaced = false
        if ["replacing", "source-busy", "cancelled"].contains(scenario) {
            let entered = expectation(description: "\(scenario) storage paused")
            gate.arm { entered.fulfill() }
            let first = Task { @MainActor in
                if scenario == "source-busy" {
                    return await model.rotatePages(
                        recordID: source.id, indices: [0]
                    )
                }
                return await replace()
            }
            await fulfillment(of: [entered], timeout: 5)
            if scenario == "source-busy" {
                XCTAssertTrue(model.isProcessing(source.id), scenario)
            } else {
                XCTAssertTrue(model.isProcessing(destination.id), scenario)
                XCTAssertTrue(model.isProcessing(source.id), scenario)
            }
            if scenario == "cancelled" {
                first.cancel()
                gate.release()
                replaced = await first.value
                XCTAssertFalse(replaced, scenario)
            } else {
                let contenderStarted = expectation(
                    description: "\(scenario) competing operation started"
                )
                let contender = Task { @MainActor in
                    contenderStarted.fulfill()
                    if scenario == "source-busy" {
                        return await replace()
                    }
                    return await model.rotatePages(
                        recordID: source.id, indices: [0]
                    )
                }
                await fulfillment(of: [contenderStarted], timeout: 5)
                gate.release()
                let firstSucceeded = await first.value
                let competingSucceeded = await contender.value
                XCTAssertTrue(firstSucceeded, scenario)
                XCTAssertFalse(competingSucceeded, scenario)
                replaced = scenario == "source-busy"
                    ? competingSucceeded : firstSucceeded
            }
        } else {
            replaced = await replace()
            XCTAssertFalse(replaced, scenario)
        }
        XCTAssertFalse(model.isProcessing(source.id), scenario)
        XCTAssertFalse(model.isProcessing(destination.id), scenario)
        XCTAssertFalse(model.hasActiveLocalDataOperations, scenario)
        XCTAssertFalse(gate.didTimeOut, scenario)
        if scenario != "source-busy" {
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes, scenario)
            XCTAssertEqual(
                model.record(id: source.id)?.contentRevisionID,
                source.contentRevisionID,
                scenario
            )
        }
        if replaced {
            let output = try XCTUnwrap(PDFDocument(url: destinationURL))
            XCTAssertEqual(output.pageCount, 2, scenario)
            XCTAssertEqual(
                output.page(at: 0)?.string,
                PDFDocument(url: input)?.page(at: 1)?.string,
                scenario
            )
            XCTAssertNotEqual(
                model.record(id: destination.id)?.contentRevisionID,
                destination.contentRevisionID,
                scenario
            )
        } else {
            XCTAssertEqual(
                try Data(contentsOf: destinationURL), destinationBytes, scenario
            )
            XCTAssertEqual(
                model.record(id: destination.id)?.contentRevisionID,
                destination.contentRevisionID,
                scenario
            )
        }
    }
}

final class PageCopyOwnershipTests: XCTestCase {
    @MainActor
    func testCopyPages_preservesSourceOwnershipAndReleasesOperations_BitsUT()
        async throws {
        let syncKey = AppPreferences.metadataSyncEnabledKey
        let previousSync = UserDefaults.standard.object(forKey: syncKey)
        UserDefaults.standard.set(false, forKey: syncKey)
        defer {
            if let previousSync {
                UserDefaults.standard.set(previousSync, forKey: syncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: syncKey)
            }
        }
        for scenario in [
            "copying", "source-busy", "cancelled", "invalid-page",
            "same-document", "empty-selection", "missing-source",
            "missing-destination"
        ] {
            try await exerciseCopy(scenario: scenario)
        }
    }

    @MainActor
    private func exerciseCopy(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageCopyOwnership-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 2)
        let gate = ReplacementCapacityGate()
        defer { gate.release() }
        let store = DocumentStore(
            rootURL: root.appendingPathComponent("Store"),
            availableCapacity: { _ in gate.capacity() }
        )
        let source = try await store.importPDF(
            from: input, preserveSourceLocation: false
        )
        let destination = try await store.importPDF(
            from: input, preserveSourceLocation: false
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let sourceURL = try XCTUnwrap(model.url(for: source.id))
        let destinationURL = try XCTUnwrap(model.url(for: destination.id))
        let sourceBytes = try Data(contentsOf: sourceURL)
        let destinationBytes = try Data(contentsOf: destinationURL)
        let copy: @MainActor () async -> Bool = {
            await model.copyPages(
                from: scenario == "missing-source" ? UUID() : source.id,
                indices: scenario == "empty-selection"
                    ? [] : (scenario == "invalid-page" ? [10] : [0, 1]),
                to: scenario == "same-document" ? source.id
                    : (scenario == "missing-destination" ? UUID() : destination.id)
            )
        }
        var copied = false
        if ["copying", "source-busy", "cancelled"].contains(scenario) {
            let entered = expectation(description: "\(scenario) storage paused")
            gate.arm { entered.fulfill() }
            let first = Task { @MainActor in
                if scenario == "source-busy" {
                    return await model.rotatePages(
                        recordID: source.id, indices: [0]
                    )
                }
                return await copy()
            }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertTrue(model.isProcessing(source.id), scenario)
            if scenario != "source-busy" {
                XCTAssertTrue(model.isProcessing(destination.id), scenario)
            }
            if scenario == "cancelled" {
                first.cancel()
                gate.release()
                copied = await first.value
                XCTAssertFalse(copied, scenario)
            } else {
                let started = expectation(
                    description: "\(scenario) competing operation started"
                )
                let contender = Task { @MainActor in
                    started.fulfill()
                    if scenario == "source-busy" {
                        return await copy()
                    }
                    return await model.rotatePages(
                        recordID: source.id, indices: [0]
                    )
                }
                await fulfillment(of: [started], timeout: 5)
                gate.release()
                let firstSucceeded = await first.value
                let competingSucceeded = await contender.value
                XCTAssertTrue(firstSucceeded, scenario)
                XCTAssertFalse(competingSucceeded, scenario)
                copied = scenario == "source-busy"
                    ? competingSucceeded : firstSucceeded
            }
        } else {
            copied = await copy()
            XCTAssertFalse(copied, scenario)
        }
        XCTAssertFalse(model.isProcessing(source.id), scenario)
        XCTAssertFalse(model.isProcessing(destination.id), scenario)
        XCTAssertFalse(model.hasActiveLocalDataOperations, scenario)
        XCTAssertFalse(gate.didTimeOut, scenario)
        if scenario != "source-busy" {
            XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes, scenario)
            XCTAssertEqual(
                model.record(id: source.id)?.contentRevisionID,
                source.contentRevisionID, scenario
            )
        }
        if copied {
            let output = try XCTUnwrap(PDFDocument(url: destinationURL))
            XCTAssertEqual(output.pageCount, 4, scenario)
            for index in 0..<2 {
                XCTAssertEqual(
                    output.page(at: index + 2)?.string,
                    PDFDocument(url: input)?.page(at: index)?.string,
                    scenario
                )
            }
            XCTAssertNotEqual(
                model.record(id: destination.id)?.contentRevisionID,
                destination.contentRevisionID, scenario
            )
        } else {
            XCTAssertEqual(
                try Data(contentsOf: destinationURL), destinationBytes, scenario
            )
            XCTAssertEqual(
                model.record(id: destination.id)?.contentRevisionID,
                destination.contentRevisionID, scenario
            )
        }
    }
}

private final class ReplacementCapacityGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var onEntry: (() -> Void)?
    private var released = false
    private var timedOut = false

    var didTimeOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }

    func arm(onEntry: @escaping () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        self.onEntry = onEntry
        released = false
    }

    func capacity() -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        guard let onEntry else { return .max }
        self.onEntry = nil
        onEntry()
        let deadline = Date().addingTimeInterval(10)
        while !released {
            if !condition.wait(until: deadline) {
                timedOut = true
                break
            }
        }
        return .max
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class TestProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func append(_ value: Double) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private enum ProtectionTestError: Error {
    case denied
}

private final class ProtectionFailingFileManager:
    FileManager,
    @unchecked Sendable {
    var deniedPathFragment: String?

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        if attributes[.protectionKey] != nil,
           deniedPathFragment.map({ path.contains($0) }) ?? false {
            throw ProtectionTestError.denied
        }
        try super.setAttributes(
            attributes,
            ofItemAtPath: path
        )
    }
}

private final class RemovalFailingFileManager:
    FileManager,
    @unchecked Sendable {
    var deniedRemovalPathFragment: String?

    override func removeItem(at URL: URL) throws {
        if deniedRemovalPathFragment.map({
            URL.path.contains($0)
        }) ?? false {
            throw ProtectionTestError.denied
        }
        try super.removeItem(at: URL)
    }
}

private final class CheckpointRemovalFailingFileManager:
    FileManager,
    @unchecked Sendable {
    enum Mode: CaseIterable {
        case partialRemoval
        case completeRemoval
        case restoreCopyFailure
        case restoreProtectionFailure
    }

    let mode: Mode
    var checkpointURL: URL?
    private(set) var didInjectFailure = false

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL == checkpointURL, !didInjectFailure {
            didInjectFailure = true
            if mode == .completeRemoval {
                try super.removeItem(at: URL)
            } else {
                try super.removeItem(at: URL.appendingPathComponent("page-0.json"))
            }
            throw ProtectionTestError.denied
        }
        try super.removeItem(at: URL)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if mode == .restoreCopyFailure,
           didInjectFailure,
           srcURL.path.contains(".batch-sidecar-rollback-") {
            try Data("partial checkpoint copy".utf8).write(to: dstURL)
            throw ProtectionTestError.denied
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        if mode == .restoreProtectionFailure,
           didInjectFailure,
           attributes[.protectionKey] != nil,
           path == checkpointURL?.appendingPathComponent("page-0.json").path {
            throw ProtectionTestError.denied
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

@MainActor
private final class CriticalMetadataKeyValueStore:
    PDFMetadataKeyValueStore {
    let isCloudBacked: Bool
    var storage: [String: Data] = [:]
    var synchronizeResult = true

    init(isCloudBacked: Bool) {
        self.isCloudBacked = isCloudBacked
    }

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func set(_ data: Data?, forKey key: String) {
        storage[key] = data
    }

    func synchronize() -> Bool {
        synchronizeResult
    }
}

final class PDFCompressionDepthTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompressionDepth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testRecompressesExistingFlateWithIndirectLengthAndPredictorsLosslessly() throws {
        for predictor in [1, 2, 15] {
            let source = url("flate-\(predictor).pdf"), output = url("out-\(predictor).pdf")
            let edge = 512
            var pixels = Data()
            for _ in 0..<edge {
                if predictor == 15 { pixels.append(0) } // PNG row filter: None.
                pixels.append(Data(repeating: 42, count: edge * 3))
            }
            var encoded = Data(count: Int(compressBound(uLong(pixels.count))))
            var count = uLongf(encoded.count)
            let status = encoded.withUnsafeMutableBytes { target in
                pixels.withUnsafeBytes { input in
                    compress2(target.bindMemory(to: Bytef.self).baseAddress!, &count,
                        input.bindMemory(to: Bytef.self).baseAddress!, uLong(pixels.count), 1)
                }
            }
            XCTAssertEqual(status, Z_OK)
            encoded.count = Int(count)
            let commands = Data("q 200 0 0 200 0 0 cm /Im Do Q\n".utf8)
            try PDFTestFixtureFactory.writeClassicPDF(objects: [
                .init(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                .init(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
                .init(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>"),
                .init(4, "<< /Length \(commands.count) >>", stream: commands),
                .init(5, "<< /Type /XObject /Subtype /Image /Width \(edge) /Height \(edge) /BitsPerComponent 8 /ColorSpace /DeviceRGB /Length 6 0 R /Filter /FlateDecode /DecodeParms << /Predictor \(predictor) /Colors 3 /Columns \(edge) /BitsPerComponent 8 >> >>", stream: encoded),
                .init(6, "\(encoded.count)")
            ], rootObjectNumber: 1, to: source)
            try PDFOutputService().compress(sourceURL: source, destination: output, quality: .readable)
            XCTAssertLessThan(try Data(contentsOf: output).count, try Data(contentsOf: source).count)
            print("FLATE_RECOMPRESSION predictor=\(predictor) source=\(try Data(contentsOf: source).count) output=\(try Data(contentsOf: output).count)")
            try assertImagePayloadsEqual(source: source, output: output, pages: 1)
        }
    }

    func testIndirectJPEGLengthIsOptimizedOnlyInExplicitLossyMode() throws {
        let original = url("jpeg-direct.pdf"), source = url("jpeg-indirect.pdf"), output = url("out.pdf")
        try makeImagePDF(at: original, pages: 1, edge: 2_400, jpeg: true)
        let document = try XCTUnwrap(CGPDFDocument(original as CFURL))
        let page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, image: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(page, "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &images))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(images), "Im", &image))
        var format = CGPDFDataFormat.raw
        let jpeg = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(image), &format)) as Data
        XCTAssertEqual(format, .jpegEncoded)
        let commands = Data("q 200 0 0 200 0 0 cm /Im Do Q\n".utf8)
        try PDFTestFixtureFactory.writeClassicPDF(objects: [
            .init(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            .init(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            .init(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>"),
            .init(4, "<< /Length \(commands.count) >>", stream: commands),
            .init(5, "<< /Type /XObject /Subtype /Image /Width 2400 /Height 2400 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Length 6 0 R /Filter /DCTDecode >>", stream: jpeg),
            .init(6, "\(jpeg.count)")
        ], rootObjectNumber: 1, to: source)
        XCTAssertThrowsError(try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact)) { error in
            guard case PaperPathError.compressionNotBeneficial = error else {
                return XCTFail("Expected a valid PDF with no lossless savings; received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact, mode: .optimizedImages)
        XCTAssertLessThan(try Data(contentsOf: output).count, try Data(contentsOf: source).count)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
    }

    @MainActor
    func testIncrementalPDFCompressionPreservesLatestRevisionAndOriginal() async throws {
        let source = url("incremental.pdf")
        try makeImagePDF(at: source, pages: 1, edge: 200)
        var bytes = try Data(contentsOf: source)
        let marker = try XCTUnwrap(bytes.range(of: Data("startxref".utf8), options: .backwards))
        let previous = try XCTUnwrap(String(decoding: bytes[marker.upperBound...], as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) })
        let objectOffset = bytes.count
        bytes.append(Data("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [7 0 R] >> >>\nendobj\n".utf8))
        let xrefOffset = bytes.count
        bytes.append(Data(String(format: "xref\n1 1\n%010d 00000 n \n", objectOffset).utf8))
        bytes.append(Data("trailer\n<< /Size 9 /Root 1 0 R /Prev \(previous) >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try bytes.write(to: source)
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 1)
        let store = DocumentStore(rootURL: directory.appendingPathComponent("Store"))
        let imported = try await store.importPDF(from: source)
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        var issue: PDFBatchDeliveryIssue?
        let result = await model.createCompressedCopy(recordID: imported.id, quality: .readable,
            expectedContentRevisionID: imported.contentRevisionID, presentsFeedback: false) { issue = $0 }
        XCTAssertNotNil(result)
        XCTAssertNil(issue)
        XCTAssertEqual(result?.id, imported.id)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let saved = try XCTUnwrap(model.url(for: imported.id))
        XCTAssertLessThan(try Data(contentsOf: saved).count, bytes.count)
        XCTAssertEqual(PDFDocument(url: saved)?.page(at: 0)?.string, PDFDocument(url: source)?.page(at: 0)?.string)
    }

    func testPreservesTextLinksFormsAndPageGeometry() throws {
        let source = url("mixed.pdf"), output = url("output.pdf")
        try makeImagePDF(at: source, pages: 2, edge: 900)
        let original = try XCTUnwrap(PDFDocument(url: source))
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced)
        let compressed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(compressed.pageCount, 2)
        for index in 0..<2 {
            let before = try XCTUnwrap(original.page(at: index))
            let after = try XCTUnwrap(compressed.page(at: index))
            XCTAssertEqual(after.string, before.string)
            XCTAssertTrue(after.string?.contains("Compression contract") == true)
            XCTAssertEqual(after.rotation, before.rotation)
            XCTAssertEqual(after.bounds(for: .cropBox), before.bounds(for: .cropBox))
            XCTAssertEqual(after.annotations.count, 2)
            XCTAssertEqual(after.annotations.first?.url?.absoluteString, "https://example.com/")
            XCTAssertEqual(after.annotations.last?.widgetStringValue, "Keep this value")
        }
        let receipt = try PDFDeliveryAuditService().audit(sourceURL: source, outputURL: output,
            operation: .compressed, compressionPreservesContent: true)
        XCTAssertFalse(receipt.checks.contains { $0.status == .failed })
        XCTAssertEqual(receipt.checks.first { $0.id == "text-layer" }?.status, .passed)
        XCTAssertEqual(receipt.checks.first { $0.id == "annotations" }?.status, .passed)
    }

    func testLargeImagePDFMemoryTimeAndRatio() throws {
        let source = url("large.pdf"), output = url("output.pdf")
        // Real embedded RGB pixels, rather than a small PDF with padding.
        try autoreleasepool { try makeImagePDF(at: source, pages: 24, edge: 1_600) }
        let baseline = testResidentMemory(), sampler = TestProcessMemorySampler()
        sampler.start()
        let start = ContinuousClock.now
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced) { fraction in
            if fraction == 0.01 || fraction == 0.88 || fraction == 1 {
                print("COMPRESSION_PHASE fraction=\(fraction) rss=\(testResidentMemory())")
            }
        }
        let elapsed = start.duration(to: .now)
        let peak = sampler.stop().saturatingSubtracting(baseline)
        let sourceBytes = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let outputBytes = try XCTUnwrap(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("COMPRESSION_BENCHMARK source=\(sourceBytes) output=\(outputBytes) pages=24 elapsed=\(elapsed) peakRSSDelta=\(peak)")
        XCTAssertGreaterThan(sourceBytes, 175 * 1_024 * 1_024)
        XCTAssertLessThan(outputBytes, sourceBytes / 3)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 24)
        XCTAssertLessThan(elapsed, .seconds(90))
        XCTAssertLessThan(peak, UInt64(128 * 1_024 * 1_024))
    }

    func testHalfGigabytePDFDoesNotScaleResidentMemoryWithInputSize() throws {
        let source = url("half-gigabyte.pdf"), output = url("output.pdf")
        try autoreleasepool { try makeImagePDF(at: source, pages: 64, edge: 1_600) }
        let baseline = testResidentMemory(), sampler = TestProcessMemorySampler()
        sampler.start()
        let start = ContinuousClock.now
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced)
        let elapsed = start.duration(to: .now)
        let peak = sampler.stop().saturatingSubtracting(baseline)
        let sourceBytes = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let outputBytes = try XCTUnwrap(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        print("COMPRESSION_HALF_GB source=\(sourceBytes) output=\(outputBytes) pages=64 elapsed=\(elapsed) peakRSSDelta=\(peak)")
        XCTAssertGreaterThan(sourceBytes, 450 * 1_024 * 1_024)
        XCTAssertLessThan(outputBytes, sourceBytes / 3)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 64)
        XCTAssertLessThan(peak, UInt64(128 * 1_024 * 1_024))
        XCTAssertLessThan(elapsed, .seconds(90))
        try assertImagePayloadsEqual(source: source, output: output, pages: 64)
    }

    func testCancellationCleansStagingAndLeavesSourceUnchanged() async throws {
        let source = url("cancel.pdf"), output = url("output.pdf")
        try makeImagePDF(at: source, pages: 8, edge: 900)
        let hash = try Data(contentsOf: source)
        let latch = CompressionCancellationLatch()
        let worker = Task.detached {
            try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact) { value in
                if value > 0.02 { latch.pauseAtCheckpoint() }
            }
        }
        await Task.detached { latch.waitForCheckpoint() }.value
        worker.cancel()
        latch.resume()
        do { try await worker.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: source), hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".compression-") })
        // The shared admission gate must also be released after cancellation.
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact)
        XCTAssertNotNil(PDFDocument(url: output))
    }

    func testAlreadyOptimizedNeverReplacesDestination() throws {
        let source = url("source.pdf"), output = url("output.pdf")
        try makeImagePDF(at: source, pages: 1, edge: 700)
        let sentinel = Data("existing output".utf8)
        try sentinel.write(to: output)
        XCTAssertThrowsError(try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    func testPreservesAttachmentsOutlinesAndPageLabels() throws {
        let source = url("structure.pdf"), output = url("output.pdf")
        try PDFTestFixtureFactory.makeStructurePDF(at: source, attachment: .init(
            fileName: "notes.txt", data: Data(repeating: 65, count: 128 * 1_024)))
        let padding = try FileHandle(forWritingTo: source)
        try padding.seekToEnd()
        try padding.write(contentsOf: Data(repeating: 0, count: 512 * 1_024))
        try padding.close()
        let service = PDFDocumentStructureService()
        let before = try service.preservationSignature(in: source, includePageLabels: true)
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced)
        XCTAssertEqual(try service.preservationSignature(in: output, includePageLabels: true), before)
    }

    func testImageModeRemovesTextOnlyWhenExplicitlySelected() throws {
        let source = url("source.pdf"), output = url("output.pdf")
        try makeImagePDF(at: source, pages: 1, edge: 900)
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact, mode: .imageCopy)
        XCTAssertTrue(PDFDocument(url: output)?.page(at: 0)?.string?.isEmpty ?? true)
    }

    func testEstimateIsNeutralForContentModeAndSamplesImageMode() throws {
        let source = url("source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 60)
        let content = try PDFOutputService().estimateCompression(sourceURL: source, quality: .balanced)
        XCTAssertEqual(content.sampledPageCount, 0)
        XCTAssertEqual(content.estimatedByteCount, content.sourceByteCount)
        let image = try PDFOutputService().estimateCompression(sourceURL: source, quality: .balanced, mode: .imageCopy)
        XCTAssertEqual(image.sampledPageCount, 3)
        XCTAssertGreaterThan(image.estimatedByteCount, 0)
    }

    func testSignedPDFIsRefusedWithoutPublishing() throws {
        let source = url("signed.pdf"), output = url("output.pdf")
        let commands = Data(repeating: 32, count: 2_048)
        try PDFTestFixtureFactory.writeClassicPDF(objects: [
            .init(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            .init(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            .init(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>"),
            .init(4, "<< /Length \(commands.count) >>", stream: commands),
            .init(5, "<< /Type /Sig /ByteRange [0 1 2 3] /Contents <1234> >>")
        ], rootObjectNumber: 1, to: source)
        XCTAssertThrowsError(try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced)) { error in
            XCTAssertTrue(String(describing: error).contains("signature"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDictionaryParserRecognizesNamesWithoutLookingInsideStrings() throws {
        let data = Data("<< /Type /EmbeddedFile /Note (not /Filter /DCTDecode) /Filter /FlateDecode /Length 123 >>".utf8)
        let dictionary = try XCTUnwrap(pdfFirstDictionaryRange(in: data))
        let type = try XCTUnwrap(pdfTopLevelValueRange(for: "Type", in: data, dictionaryRange: dictionary))
        let filter = try XCTUnwrap(pdfTopLevelValueRange(for: "Filter", in: data, dictionaryRange: dictionary))
        XCTAssertEqual(String(decoding: data[type], as: UTF8.self), "/EmbeddedFile")
        XCTAssertEqual(String(decoding: data[filter], as: UTF8.self), "/FlateDecode")
    }

    @MainActor
    func testModelCompressionKeepsMainActorResponsiveThroughAuditAndSave() async throws {
        let source = url("responsive.pdf")
        try makeImagePDF(at: source, pages: 12, edge: 1_200)
        let store = DocumentStore(rootURL: url("ModelStore"))
        let imported = try await store.importPDF(from: source, preserveSourceLocation: false)
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        var finished = false
        let operation = Task { @MainActor in
            let created = await model.createCompressedCopy(recordID: imported.id, quality: .balanced,
                expectedContentRevisionID: imported.contentRevisionID, presentsFeedback: false)
            finished = true
            return created
        }
        var ticks = 0
        var maxDelay: Duration = .zero
        while !finished {
            let tick = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(20))
            maxDelay = max(maxDelay, tick.duration(to: .now))
            ticks += 1
        }
        let result = await operation.value
        XCTAssertNotNil(result, "Compression failed")
        XCTAssertGreaterThan(ticks, 1)
        XCTAssertLessThan(maxDelay, .milliseconds(500), "Main actor stalled during compression/audit/save")
        XCTAssertFalse(model.isProcessing(imported.id))
        print("COMPRESSION_RESPONSIVENESS ticks=\(ticks) longestHeartbeatInterval=\(maxDelay)")
    }

    func testLosslessPreservesExistingJPEGBytesAtEveryQuality() throws {
        let source = url("original-jpeg.pdf")
        try makeImagePDF(at: source, pages: 2, edge: 2_400, jpeg: true)
        try appendPadding(to: source)
        for quality in PDFCompressionQuality.allCases {
            let output = url("lossless-\(quality.rawValue).pdf")
            try PDFOutputService().compress(sourceURL: source, destination: output, quality: quality)
            try assertImagePayloadsEqual(source: source, output: output, pages: 2)
            XCTAssertNotNil(try Data(contentsOf: output).range(of: Data("/Width 2400".utf8)))
        }
    }

    func testLosslessKeepsHighEntropyImagePixelsInsteadOfReducingQuality() throws {
        let source = url("noise.pdf"), output = url("lossless-noise.pdf")
        try makeImagePDF(at: source, pages: 1, edge: 900, noisy: true)
        try appendPadding(to: source)
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact)
        try assertImagePayloadsEqual(source: source, output: output, pages: 1)
        let bytes = try XCTUnwrap(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(bytes, 900 * 900 * 3 - 1_024,
            "High-entropy pixels cannot be shrunk dramatically without changing them")
    }

    private func appendPadding(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 1_024 * 1_024))
    }

    /// Independent PDF decoder: compare every original sample byte (or every
    /// existing JPEG byte), rather than low-resolution rendered thumbnails.
    private func assertImagePayloadsEqual(source: URL, output: URL, pages: Int) throws {
        let before = try XCTUnwrap(CGPDFDocument(source as CFURL))
        let after = try XCTUnwrap(CGPDFDocument(output as CFURL))
        func payload(_ document: CGPDFDocument, page: Int) throws -> (Data, CGPDFDataFormat, Int, Int) {
            let dictionary = try XCTUnwrap(document.page(at: page)?.dictionary)
            var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &images))
            XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(images), "Im", &stream))
            let image = try XCTUnwrap(stream)
            let metadata = try XCTUnwrap(CGPDFStreamGetDictionary(image))
            var width = 0, height = 0
            XCTAssertTrue(CGPDFDictionaryGetInteger(metadata, "Width", &width))
            XCTAssertTrue(CGPDFDictionaryGetInteger(metadata, "Height", &height))
            var format = CGPDFDataFormat.raw
            let bytes = try XCTUnwrap(CGPDFStreamCopyData(image, &format)) as Data
            return (bytes, format, width, height)
        }
        for page in 1...pages {
            try autoreleasepool {
                let lhs = try payload(before, page: page), rhs = try payload(after, page: page)
                XCTAssertTrue(lhs.0 == rhs.0, "Image data differs on page \(page)")
                XCTAssertEqual(lhs.1, rhs.1)
                XCTAssertEqual(lhs.2, rhs.2)
                XCTAssertEqual(lhs.3, rhs.3)
            }
        }
        print("LOSSLESS_PIXEL_CHECK pages=\(pages) identical_payloads=\(pages)")
    }

    func testCompressionAcceptsUnusedAppleZeroOffsetPlaceholder() throws {
        let source = url("placeholder.pdf"), output = url("output.pdf")
        let commands = Data(("BT /F 12 Tf 20 50 Td (Placeholder test) Tj ET\n" + String(repeating: " ", count: 2_048)).utf8)
        try PDFTestFixtureFactory.writeClassicPDF(objects: [
            .init(1, "<< /Type /Catalog /Pages 2 0 R >>"),
            .init(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            .init(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Resources << /Font << /F 6 0 R >> >> /Contents 4 0 R >>"),
            .init(4, "<< /Length \(commands.count) >>", stream: commands),
            .init(6, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        ], rootObjectNumber: 1, to: source)
        var data = try Data(contentsOf: source)
        let marker = try XCTUnwrap(data.range(of: Data("0000000000 00000 f".utf8)))
        data.replaceSubrange(marker, with: Data("0000000000 00000 n".utf8))
        try data.write(to: source)
        XCTAssertThrowsError(try PDFClassicXRefDocument(data: data), "Other mutation paths remain strict")
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .readable)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.string, PDFDocument(url: source)?.page(at: 0)?.string)
        XCTAssertTrue(PDFDocument(url: output)?.page(at: 0)?.string?.contains("Placeholder test") == true)
    }

    func testJPEGDownsamplingPreservesSearchableText() throws {
        let source = url("jpeg.pdf"), output = url("output.pdf")
        try makeImagePDF(at: source, pages: 2, edge: 2_400, jpeg: true)
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .compact, mode: .optimizedImages)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 1)?.string, PDFDocument(url: source)?.page(at: 1)?.string)
        XCTAssertLessThan(try XCTUnwrap(output.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        let bytes = try Data(contentsOf: output)
        XCTAssertNotNil(bytes.range(of: Data("/Width 1200".utf8)))
    }

    func testCrossReferenceAndObjectStreamsRetainTextAndTrailerID() throws {
        let classic = url("classic.pdf"), source = url("xref-stream.pdf"), output = url("output.pdf")
        try makeImagePDF(at: classic, pages: 1, edge: 900)
        let data = try Data(contentsOf: classic)
        let parsed = try PDFClassicXRefDocument(data: data)
        let references = parsed.allObjects()
        let marker = try XCTUnwrap(data.range(of: Data("startxref".utf8), options: .backwards))
        let start = try XCTUnwrap(Int(String(decoding: data[marker.upperBound...], as: UTF8.self).split(whereSeparator: { !$0.isNumber }).first ?? ""))
        var body = Data(data[..<start])
        let objectStreamNumber = (references.map(\.number).max() ?? 0) + 1
        let xrefNumber = objectStreamNumber + 1
        let fontPayload = Data("3 0 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)
        let objectStreamOffset = body.count
        body.append(Data("\(objectStreamNumber) 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Length \(fontPayload.count) >>\nstream\n".utf8))
        body.append(fontPayload)
        body.append(Data("\nendstream\nendobj\n".utf8))
        let xrefOffset = body.count
        var entries = Data()
        func entry(_ type: UInt8, _ first: UInt64, _ second: UInt32) {
            entries.append(type)
            for shift in stride(from: 56, through: 0, by: -8) { entries.append(UInt8(truncatingIfNeeded: first >> shift)) }
            for shift in stride(from: 24, through: 0, by: -8) { entries.append(UInt8(truncatingIfNeeded: second >> shift)) }
        }
        for number in 0...xrefNumber {
            if number == 0 { entry(0, 0, 65_535) }
            else if number == 3 { entry(2, UInt64(objectStreamNumber), 0) }
            else if number == objectStreamNumber { entry(1, UInt64(objectStreamOffset), 0) }
            else if number == xrefNumber { entry(1, UInt64(xrefOffset), 0) }
            else { entry(1, UInt64(try XCTUnwrap(references.first { $0.number == number }?.offset)), 0) }
        }
        let compressed = try XCTUnwrap(PDFXRefStreamDocument.deflateZlib(entries))
        body.append(Data("\(xrefNumber) 0 obj\n<< /Type /XRef /Size \(xrefNumber + 1) /Root 1 0 R /W [1 8 4] /Filter /FlateDecode /Length \(compressed.count) /ID [<12345678> <12345678>] >>\nstream\n".utf8))
        body.append(compressed)
        body.append(Data("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try body.write(to: source)
        XCTAssertTrue(PDFDocument(url: source)?.page(at: 0)?.string?.contains("Compression contract") == true)
        try PDFOutputService().compress(sourceURL: source, destination: output, quality: .balanced)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.string, PDFDocument(url: source)?.page(at: 0)?.string)
        XCTAssertNotNil(try Data(contentsOf: output).range(of: Data("/ID [<12345678> <12345678>]".utf8)))
    }

    /// Uses a different image object per page and writes directly to disk.
    private func makeImagePDF(at url: URL, pages: Int, edge: Int, jpeg: Bool = false, noisy: Bool = false) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offsets: [UInt64] = [0]
        func append(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
        func object(_ number: Int, _ dictionary: String, stream: Data? = nil) throws {
            XCTAssertEqual(offsets.count, number)
            offsets.append(try handle.offset())
            try append("\(number) 0 obj\n\(dictionary)\n")
            if let stream { try append("stream\n"); try handle.write(contentsOf: stream); try append("\nendstream\n") }
            try append("endobj\n")
        }
        try append("%PDF-1.7\n")
        try object(1, "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [7 0 R] >> >>")
        let kids = (0..<pages).map { "\(4 + $0 * 5) 0 R" }.joined(separator: " ")
        try object(2, "<< /Type /Pages /Count \(pages) /Kids [\(kids)] >>")
        try object(3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        for index in 0..<pages {
            try autoreleasepool {
                let page = 4 + index * 5
                try object(page, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 600 780] /Rotate \(index.isMultiple(of: 2) ? 0 : 90) /Resources << /Font << /F1 3 0 R >> /XObject << /Im \(page + 2) 0 R >> >> /Contents \(page + 1) 0 R /Annots [\(page + 4) 0 R \(page + 3) 0 R] >>")
                let commands = Data("q 500 0 0 500 50 150 cm /Im Do Q\nBT /F1 16 Tf 50 700 Td (Compression contract \(index)) Tj ET\n".utf8)
                try object(page + 1, "<< /Length \(commands.count) >>", stream: commands)
                var pixels = Data(count: edge * edge * 3)
                pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    var random: UInt32 = UInt32(index + 1)
                    for y in 0..<edge { for x in 0..<edge {
                        let offset = (y * edge + x) * 3
                        if noisy {
                            for channel in 0..<3 {
                                random = random &* 1_664_525 &+ 1_013_904_223
                                bytes[offset + channel] = UInt8(truncatingIfNeeded: random >> 16)
                            }
                            continue
                        }
                        bytes[offset] = UInt8((x / 8 + index) % 256)
                        bytes[offset + 1] = UInt8((y / 8 + index) % 256)
                        bytes[offset + 2] = UInt8(((x + y) / 16) % 256)
                    }}
                }
                let filter: String
                if jpeg {
                    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
                    let image = try XCTUnwrap(CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 24,
                        bytesPerRow: edge * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
                    pixels = try XCTUnwrap(UIImage(cgImage: image).jpegData(compressionQuality: 0.98))
                    filter = "/Filter /DCTDecode"
                } else { filter = "" }
                try object(page + 2, "<< /Type /XObject /Subtype /Image /Width \(edge) /Height \(edge) /BitsPerComponent 8 /ColorSpace /DeviceRGB /Length \(pixels.count) \(filter) >>", stream: pixels)
                try object(page + 3, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Input\(index)) /V (Keep this value) /Rect [50 60 200 100] >>")
                try object(page + 4, "<< /Type /Annot /Subtype /Link /Rect [50 710 200 740] /A << /S /URI /URI (https://example.com/) >> >>")
            }
        }
        let xref = try handle.offset()
        try append("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() { try append(String(format: "%010llu 00000 n \n", offset)) }
        try append("trailer\n<< /Size \(offsets.count) /Root 1 0 R /ID [<12345678> <12345678>] >>\nstartxref\n\(xref)\n%%EOF\n")
    }
}

private final class CompressionCancellationLatch: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didPause = false
    func pauseAtCheckpoint() {
        lock.lock()
        if didPause { lock.unlock(); return }
        didPause = true
        lock.unlock()
        reached.signal()
        _ = release.wait(timeout: .now() + 10)
    }
    func waitForCheckpoint() { _ = reached.wait(timeout: .now() + 15) }
    func resume() { release.signal() }
}

/// Product contract: ordinary actions advance one Library document. Historical
/// bytes are recoverable, while only an explicit duplicate adds a document.
final class PDFDocumentLifecycleTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }
    private func source(_ name: String = "Contract.pdf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try PDFTestFixtureFactory.makeTextPDF(at: url, pageCount: 2)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 2 * 1_024 * 1_024))
        try handle.close()
        return url
    }
    private var overlay: PDFContentOverlay {
        .text(pageIndex: 0, bounds: PDFNormalizedRect(x: 0.1, y: 0.6, width: 0.7, height: 0.1),
              text: "Added information", fontSize: 16,
              color: PDFInkColor(red: 0, green: 0, blue: 0, alpha: 1))
    }

    func testLargeHistoryThresholdUsesBytesNotPageCount() {
        XCTAssertFalse(PDFHistoryStoragePolicy.usesCompactHistory(byteCount: 100 * 1_024 * 1_024 - 1))
        XCTAssertTrue(PDFHistoryStoragePolicy.usesCompactHistory(byteCount: 100 * 1_024 * 1_024))
    }

    func testCompactHistoryKeepsOriginalAcrossEditsAndRestart() async throws {
        let root = directory.appendingPathComponent("CompactStore")
        // Exercise production retention with small offline fixtures.
        let store = DocumentStore(rootURL: root, largeFileHistoryThreshold: 1)
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        let originalBytes = try Data(contentsOf: liveURL)
        let original = try await store.createVersionSnapshot(for: record, label: "First edit", automatic: true)
        XCTAssertTrue(original.isProtectedOriginal)
        for _ in 0..<4 {
            try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
            record = try await store.refresh(record)
            let recovery = try await store.createVersionSnapshot(for: record, label: "Another edit", automatic: true)
            XCTAssertEqual(recovery.id, original.id)
        }
        // Persisted compact mode survives even when the current PDF shrinks below the threshold.
        let reopened = DocumentStore(rootURL: root, largeFileHistoryThreshold: Int64.max)
        let reused = try await reopened.createVersionSnapshot(for: record, label: "After restart", automatic: true)
        XCTAssertEqual(reused.id, original.id)
        let versions = try await reopened.versions(for: record.id)
        XCTAssertEqual(versions.count, 1)
        let originalURL = try await reopened.versionFileURL(snapshotID: original.id, recordID: record.id)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertNotEqual(try Data(contentsOf: liveURL), originalBytes)
    }

    func testCleanupKeepsStartingAndCurrentBytesAndRemovesPinnedIntermediate() async throws {
        let store = DocumentStore(rootURL: directory.appendingPathComponent("CleanupStore"))
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        let originalBytes = try Data(contentsOf: liveURL)
        let original = try await store.createVersionSnapshot(for: record, label: "First edit", automatic: true)
        var pinnedID: UUID?
        for index in 0..<14 {
            try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
            record = try await store.refresh(record)
            let snapshot = try await store.createVersionSnapshot(for: record, label: "Edit", automatic: true)
            if index == 1 {
                pinnedID = snapshot.id
                _ = try await store.updateVersionMilestone(snapshotID: snapshot.id, recordID: record.id,
                    name: "Important", pinned: true, linkedDeliveryReceiptID: nil)
            }
        }
        let before = try await store.versions(for: record.id)
        XCTAssertTrue(before.contains { $0.id == original.id }, "Retention must preserve the original past 12 edits")
        let latestBytes = try Data(contentsOf: liveURL)
        let removed = try await store.clearIntermediateVersions()
        XCTAssertEqual(removed, before.count - 1)
        let after = try await store.versions(for: record.id)
        XCTAssertEqual(after.map(\.id), [original.id])
        XCTAssertFalse(after.contains { $0.id == pinnedID })
        XCTAssertEqual(try Data(contentsOf: liveURL), latestBytes)
        let originalURL = try await store.versionFileURL(snapshotID: original.id, recordID: record.id)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        let repeated = try await store.clearIntermediateVersions()
        XCTAssertEqual(repeated, 0)
    }

    func testCompactHistoryPreservesExplicitMilestonesUntilConfirmedCleanup() async throws {
        let store = DocumentStore(rootURL: directory.appendingPathComponent("PinnedCompactStore"), largeFileHistoryThreshold: 1)
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        let original = try await store.createVersionSnapshot(for: record, label: "First", automatic: true)
        try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
        record = try await store.refresh(record)
        let explicit = try await store.createVersionSnapshot(for: record, label: "Explicit milestone")
        _ = try await store.updateVersionMilestone(snapshotID: explicit.id, recordID: record.id,
            name: "Keep", pinned: true, linkedDeliveryReceiptID: nil)
        try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
        record = try await store.refresh(record)
        _ = try await store.createVersionSnapshot(for: record, label: "Next", automatic: true)
        let versions = try await store.versions(for: record.id)
        XCTAssertEqual(Set(versions.map(\.id)), Set([original.id, explicit.id]))
        _ = try await store.clearIntermediateVersions()
        let cleared = try await store.versions(for: record.id)
        XCTAssertEqual(cleared.map(\.id), [original.id])
    }

    func testLegacyCleanupRetainsEarliestAvailableAndDecodesMissingPolicyFields() async throws {
        let root = directory.appendingPathComponent("LegacyHistoryStore")
        let store = DocumentStore(rootURL: root)
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        let earliest = try await store.createVersionSnapshot(for: record, label: "Oldest available")
        try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
        record = try await store.refresh(record)
        _ = try await store.createVersionSnapshot(for: record, label: "Intermediate")
        let indexURL = root.appendingPathComponent("versions.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        for index in rows.indices {
            rows[index].removeValue(forKey: "isOriginalRecoveryPoint")
            rows[index].removeValue(forKey: "compactHistoryEnabled")
            // Distinct legacy timestamps are intentional here; rapid snapshots
            // otherwise round to the same second on a fast physical device.
            rows[index]["createdAt"] = rows[index]["id"] as? String == earliest.id.uuidString
                ? "2026-01-01T00:00:00Z" : "2026-01-01T00:01:00Z"
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: indexURL)
        let reopened = DocumentStore(rootURL: root)
        let removed = try await reopened.clearIntermediateVersions()
        XCTAssertEqual(removed, 1)
        let remaining = try await reopened.versions(for: record.id)
        XCTAssertEqual(remaining.map(\.id), [earliest.id])
        XCTAssertTrue(try XCTUnwrap(remaining.first).isProtectedOriginal)
    }

    func testLegacyCleanupPreservesAmbiguousEarliestVersionsAndTheirBytes() async throws {
        let root = directory.appendingPathComponent("AmbiguousLegacyHistoryStore")
        let store = DocumentStore(rootURL: root)
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        var snapshots: [PDFVersionSnapshot] = []
        var bytes: [UUID: Data] = [:]
        for index in 0..<3 {
            if index > 0 {
                try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
                record = try await store.refresh(record)
            }
            let snapshot = try await store.createVersionSnapshot(for: record, label: "Legacy \(index)")
            snapshots.append(snapshot)
            bytes[snapshot.id] = try Data(contentsOf: await store.versionFileURL(snapshotID: snapshot.id, recordID: record.id))
        }
        let liveBytes = try Data(contentsOf: liveURL)
        let indexURL = root.appendingPathComponent("versions.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        for index in rows.indices {
            rows[index].removeValue(forKey: "isOriginalRecoveryPoint")
            rows[index].removeValue(forKey: "compactHistoryEnabled")
            rows[index]["createdAt"] = rows[index]["id"] as? String == snapshots[2].id.uuidString
                ? "2026-01-01T00:01:00Z" : "2026-01-01T00:00:00Z"
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: indexURL)
        let reopened = DocumentStore(rootURL: root)
        let removed = try await reopened.clearIntermediateVersions()
        XCTAssertEqual(removed, 1)
        let remaining = try await reopened.versions(for: record.id)
        XCTAssertEqual(Set(remaining.map(\.id)), Set(snapshots.prefix(2).map(\.id)))
        XCTAssertTrue(remaining.allSatisfy(\.isProtectedOriginal))
        for snapshot in remaining {
            let url = try await reopened.versionFileURL(snapshotID: snapshot.id, recordID: record.id)
            XCTAssertEqual(try Data(contentsOf: url), bytes[snapshot.id])
        }
        let repeatedRemoval = try await reopened.clearIntermediateVersions()
        XCTAssertEqual(repeatedRemoval, 0)
        XCTAssertEqual(try Data(contentsOf: liveURL), liveBytes)
    }

    private func ambiguousLegacyFixture(_ name: String) async throws -> (
        root: URL, record: DocumentRecord, snapshots: [PDFVersionSnapshot], bytes: [UUID: Data], liveURL: URL
    ) {
        let root = directory.appendingPathComponent(name)
        let store = DocumentStore(rootURL: root)
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        var snapshots: [PDFVersionSnapshot] = []
        var bytes: [UUID: Data] = [:]
        for index in 0..<3 {
            if index > 0 {
                try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
                record = try await store.refresh(record)
            }
            let snapshot = try await store.createVersionSnapshot(for: record, label: "Legacy \(index)")
            snapshots.append(snapshot)
            bytes[snapshot.id] = try Data(contentsOf: await store.versionFileURL(snapshotID: snapshot.id, recordID: record.id))
        }
        let indexURL = root.appendingPathComponent("versions.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        for index in rows.indices {
            rows[index].removeValue(forKey: "isOriginalRecoveryPoint")
            rows[index].removeValue(forKey: "compactHistoryEnabled")
            rows[index]["createdAt"] = rows[index]["id"] as? String == snapshots[2].id.uuidString
                ? "2026-01-01T00:01:00Z" : "2026-01-01T00:00:00Z"
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: indexURL)
        return (root, record, snapshots, bytes, liveURL)
    }

    func testAutomaticCompactHistoryPreservesAmbiguousLegacyOriginalBytesAcrossRestart() async throws {
        let fixture = try await ambiguousLegacyFixture("LegacyAutomaticCompact")
        let liveBytes = try Data(contentsOf: fixture.liveURL)
        let store = DocumentStore(rootURL: fixture.root, largeFileHistoryThreshold: 1)
        _ = try await store.createVersionSnapshot(for: fixture.record, label: "Automatic edit", automatic: true)
        let expected = Set(fixture.snapshots.prefix(2).map(\.id))
        let retained = try await store.versions(for: fixture.record.id)
        XCTAssertEqual(Set(retained.map(\.id)), expected)
        XCTAssertTrue(retained.allSatisfy { $0.isProtectedOriginal && $0.compactHistoryEnabled == true })
        let reopened = DocumentStore(rootURL: fixture.root, largeFileHistoryThreshold: Int64.max)
        _ = try await reopened.createVersionSnapshot(for: fixture.record, label: "After restart", automatic: true)
        let afterRestart = try await reopened.versions(for: fixture.record.id)
        XCTAssertEqual(Set(afterRestart.map(\.id)), expected)
        for snapshot in afterRestart {
            let url = try await reopened.versionFileURL(snapshotID: snapshot.id, recordID: fixture.record.id)
            XCTAssertEqual(try Data(contentsOf: url), fixture.bytes[snapshot.id])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.liveURL), liveBytes)
    }

    func testOrdinaryHistoryRetentionPreservesAmbiguousLegacyOriginalBytesPastItsLimit() async throws {
        let fixture = try await ambiguousLegacyFixture("LegacyOrdinaryRetention")
        let store = DocumentStore(rootURL: fixture.root)
        var record = fixture.record
        for index in 0..<14 {
            try PDFMutationService().addStamp(.draft, toPageAt: 0, in: fixture.liveURL)
            record = try await store.refresh(record)
            let liveBytes = try Data(contentsOf: fixture.liveURL)
            _ = try await store.createVersionSnapshot(for: record, label: "Later edit \(index)")
            XCTAssertEqual(try Data(contentsOf: fixture.liveURL), liveBytes)
        }
        let retained = try await store.versions(for: record.id)
        XCTAssertEqual(retained.count, 12)
        for original in fixture.snapshots.prefix(2) {
            XCTAssertTrue(retained.contains { $0.id == original.id && $0.isProtectedOriginal })
            let url = try await store.versionFileURL(snapshotID: original.id, recordID: record.id)
            XCTAssertEqual(try Data(contentsOf: url), fixture.bytes[original.id])
        }
    }

    func testAutomaticCompactionRejectsAnyDamagedAmbiguousOriginalBeforeDeletingHistory() async throws {
        let fixture = try await ambiguousLegacyFixture("LegacyDamagedAutomaticCompact")
        let store = DocumentStore(rootURL: fixture.root, largeFileHistoryThreshold: 1)
        let damaged = fixture.snapshots[1]
        let damagedURL = try await store.versionFileURL(snapshotID: damaged.id, recordID: fixture.record.id)
        var bytes = try Data(contentsOf: damagedURL)
        bytes[0] ^= 1
        try bytes.write(to: damagedURL)
        let indexURL = fixture.root.appendingPathComponent("versions.json")
        let originalIndex = try Data(contentsOf: indexURL)
        let liveBytes = try Data(contentsOf: fixture.liveURL)
        do {
            _ = try await store.createVersionSnapshot(for: fixture.record, label: "Unsafe cleanup", automatic: true)
            XCTFail("A damaged candidate must prevent destructive automatic cleanup")
        } catch PaperPathError.outputVerificationFailed { }
        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        XCTAssertEqual(try Data(contentsOf: fixture.liveURL), liveBytes)
        let later = fixture.snapshots[2]
        let laterURL = try await store.versionFileURL(snapshotID: later.id, recordID: fixture.record.id)
        XCTAssertEqual(try Data(contentsOf: laterURL), fixture.bytes[later.id])
    }

    func testCleanupRejectsDamagedStartingPointBeforeDeletingHistory() async throws {
        let root = directory.appendingPathComponent("DamagedStartingPointStore")
        let store = DocumentStore(rootURL: root)
        var record = try await store.importPDF(from: source())
        let liveURL = await store.url(for: record)
        let original = try await store.createVersionSnapshot(for: record, label: "Starting")
        try PDFMutationService().addStamp(.draft, toPageAt: 0, in: liveURL)
        record = try await store.refresh(record)
        let middle = try await store.createVersionSnapshot(for: record, label: "Middle")
        let originalURL = try await store.versionFileURL(snapshotID: original.id, recordID: record.id)
        var damaged = try Data(contentsOf: originalURL)
        damaged[0] ^= 1
        try damaged.write(to: originalURL)
        let current = try Data(contentsOf: liveURL)
        do {
            _ = try await store.clearIntermediateVersions()
            XCTFail("Damaged starting point must prevent destructive cleanup")
        } catch PaperPathError.outputVerificationFailed { }
        let retained = try await store.versions(for: record.id)
        XCTAssertTrue(retained.contains { $0.id == middle.id })
        XCTAssertEqual(try Data(contentsOf: liveURL), current)
    }

    func testLargeFileCapacityRetainsReserveAndRejectsUnknownCapacity() async throws {
        let sparse = directory.appendingPathComponent("large-capacity-fixture.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(PDFHistoryStoragePolicy.largeFileThreshold))
        try handle.close()
        let low = DocumentStore(rootURL: directory.appendingPathComponent("LowCapacity"),
            availableCapacity: { _ in 355 * 1_024 * 1_024 })
        do {
            try await low.ensureTemporaryWorkingCapacity(for: [sparse], copyMultiplier: 1, reserveBytes: 0)
            XCTFail("Large operations must leave the safety reserve")
        } catch PaperPathError.insufficientStorage { }
        let enough = DocumentStore(rootURL: directory.appendingPathComponent("EnoughCapacity"),
            availableCapacity: { _ in 356 * 1_024 * 1_024 })
        try await enough.ensureTemporaryWorkingCapacity(for: [sparse], copyMultiplier: 1, reserveBytes: 0)
        let unknown = DocumentStore(rootURL: directory.appendingPathComponent("UnknownCapacity"),
            availableCapacity: { _ in nil })
        do {
            try await unknown.ensureTemporaryWorkingCapacity(for: [sparse], copyMultiplier: 1)
            XCTFail("Unknown capacity must not authorize large working files")
        } catch PaperPathError.storageFailure { }
    }

    @MainActor
    func testCompressThenEditRetainsIdentityAndRestoresOriginal() async throws {
        let external = try source()
        let originalBytes = try Data(contentsOf: external)
        let store = DocumentStore(rootURL: directory.appendingPathComponent("Store"))
        let imported = try await store.importPDF(from: external)
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let originalURL = try XCTUnwrap(model.url(for: imported.id))
        let compressedResult = await model.createCompressedCopy(recordID: imported.id, quality: .readable,
            expectedContentRevisionID: imported.contentRevisionID, presentsFeedback: false)
        let compressed = try XCTUnwrap(compressedResult)
        XCTAssertEqual(compressed.id, imported.id)
        XCTAssertEqual(compressed.displayName, imported.displayName)
        XCTAssertEqual(model.url(for: compressed.id), originalURL)
        XCTAssertLessThan(compressed.profile.byteCount, imported.profile.byteCount)
        XCTAssertTrue(compressed.hasCurrentDeliveryReceipt)
        let noBenefit = await model.createCompressedCopy(recordID: compressed.id, quality: .readable,
            expectedContentRevisionID: compressed.contentRevisionID, presentsFeedback: false)
        XCTAssertNil(noBenefit)
        XCTAssertEqual(model.record(id: imported.id)?.contentRevisionID, compressed.contentRevisionID)
        let unchangedHistory = try await store.versions(for: imported.id)
        XCTAssertEqual(unchangedHistory.count, 1)
        let editedResult = await model.createEditedCopy(recordID: compressed.id, overlays: [overlay],
            expectedContentRevisionID: compressed.contentRevisionID)
        let edited = try XCTUnwrap(editedResult)
        XCTAssertEqual(edited.id, imported.id)
        XCTAssertEqual(model.workingDocuments.map(\.id), [imported.id])
        XCTAssertTrue(model.deliveryOutputs.isEmpty)
        XCTAssertTrue(PDFDocument(url: originalURL)?.page(at: 0)?.annotations.contains {
            $0.contents == "Added information"
        } == true)
        XCTAssertEqual(try Data(contentsOf: external), originalBytes)
        let versions = try await store.versions(for: imported.id)
        XCTAssertEqual(versions.count, 2)
        let initial = try XCTUnwrap(versions.first { $0.contentRevisionID == imported.contentRevisionID })
        let restored = await model.restoreVersion(recordID: imported.id, snapshotID: initial.id)
        XCTAssertTrue(restored)
        XCTAssertEqual(model.workingDocuments.count, 1)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        let reloaded = try await DocumentStore(rootURL: directory.appendingPathComponent("Store")).load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.displayName, imported.displayName)
        let duplicated = await model.duplicate(recordID: imported.id)
        XCTAssertNotEqual(duplicated?.id, imported.id)
        XCTAssertEqual(model.workingDocuments.count, 2, "Only explicit Save as New Document branches")
    }

    @MainActor
    func testPasswordRoundTripAndEncryptedHistoryRestoreUseOneDocument() async throws {
        let store = DocumentStore(rootURL: directory.appendingPathComponent("Store"))
        let imported = try await store.importPDF(from: source())
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let protectedResult = await model.createProtectedCopy(recordID: imported.id, password: "local-secret",
            expectedContentRevisionID: imported.contentRevisionID)
        let protected = try XCTUnwrap(protectedResult)
        XCTAssertEqual(protected.id, imported.id)
        XCTAssertTrue(protected.profile.isLocked)
        var unlockIssue: PDFBatchDeliveryIssue?
        let unlockedResult = await model.createUnlockedCopy(recordID: protected.id, password: "local-secret",
            expectedContentRevisionID: protected.contentRevisionID, presentsFeedback: false,
            onFailure: { unlockIssue = $0 })
        let unlocked = try XCTUnwrap(unlockedResult, "\(unlockIssue?.code ?? "") \(unlockIssue?.message ?? "")")
        XCTAssertEqual(unlocked.id, imported.id)
        XCTAssertFalse(unlocked.profile.isLocked)
        let versions = try await store.versions(for: imported.id)
        let encrypted = try XCTUnwrap(versions.first { $0.contentRevisionID == protected.contentRevisionID })
        let restored = await model.restoreVersion(recordID: imported.id, snapshotID: encrypted.id)
        XCTAssertTrue(restored)
        XCTAssertTrue(model.record(id: imported.id)?.profile.isLocked == true)
        XCTAssertEqual(model.workingDocuments.count, 1)
        let initial = try XCTUnwrap(versions.first { $0.contentRevisionID == imported.contentRevisionID })
        let restoredPlain = await model.restoreVersion(recordID: imported.id, snapshotID: initial.id)
        XCTAssertTrue(restoredPlain, "History works while the current document is password protected")
        XCTAssertFalse(model.record(id: imported.id)?.profile.isLocked == true)
        XCTAssertTrue(model.deliveryOutputs.isEmpty)
    }

    func testStaleAndCancelledUpdatesCannotPublishOrAddDocuments() async throws {
        let store = DocumentStore(rootURL: directory.appendingPathComponent("Store"))
        let imported = try await store.importPDF(from: source())
        let prepared = try source("Prepared.pdf")
        let updated = try await store.saveProcessedDocument(imported, from: prepared,
            label: "Save changes", revisionID: UUID())
        do {
            _ = try await store.saveProcessedDocument(imported, from: prepared,
                label: "Stale", revisionID: UUID())
            XCTFail("Stale revision committed")
        } catch { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.saveProcessedDocument(updated, from: prepared,
                label: "Cancelled", revisionID: UUID())
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled revision committed") }
        catch is CancellationError { }
        let records = try await store.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.contentRevisionID, updated.contentRevisionID)
        let versions = try await store.versions(for: imported.id)
        XCTAssertEqual(versions.count, 1)
    }

    @MainActor
    func testExplicitExportKeepsEditableDocumentAndDoesNotCreateWorkingDocument() async throws {
        let store = DocumentStore(rootURL: directory.appendingPathComponent("Store"))
        let imported = try await store.importPDF(from: source())
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let exportedResult = await model.createSafeShareCopy(recordID: imported.id,
            expectedContentRevisionID: imported.contentRevisionID)
        let exported = try XCTUnwrap(exportedResult)
        XCTAssertNotEqual(exported.id, imported.id)
        XCTAssertEqual(exported.sourceDocumentID, imported.id)
        XCTAssertEqual(model.workingDocuments.map(\.id), [imported.id])
        XCTAssertEqual(model.record(id: imported.id)?.contentRevisionID, imported.contentRevisionID)
        XCTAssertEqual(model.deliveryHistoryOutputs(for: imported.id).map(\.id), [exported.id])
        let secondExportResult = await model.createSafeShareCopy(recordID: exported.id,
            expectedContentRevisionID: exported.contentRevisionID)
        let secondExport = try XCTUnwrap(secondExportResult)
        XCTAssertEqual(model.sourceRecord(for: secondExport)?.id, exported.id,
            "Verification keeps the immediate source")
        XCTAssertEqual(model.originalDocument(for: secondExport)?.id, imported.id,
            "Navigation jumps straight through an old-style output chain")
        XCTAssertEqual(model.workingDocuments.count, 1)
    }
}

extension PDFCoreServiceRegressionTests {
    private func makeMergeNoteSource() throws -> URL {
        let source = temporaryDirectory.appendingPathComponent("nonstandard-note.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let document = try XCTUnwrap(PDFDocument(data: renderer.pdfData { context in context.beginPage() }))
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 200, width: 30, height: 30),
            forType: .text, withProperties: nil)
        note.contents = "Preserve original note geometry"
        document.page(at: 0)?.addAnnotation(note)
        XCTAssertTrue(document.write(to: source))
        return source
    }

    private func rawNoteRect(in url: URL, page number: Int) throws -> CGRect {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: number))
        let dictionary = try XCTUnwrap(page.dictionary)
        var annotations: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
        let array = try XCTUnwrap(annotations)
        for index in 0..<CGPDFArrayGetCount(array) {
            var annotation: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, index, &annotation), let annotation else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Text" else { continue }
            var bounds: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(annotation, "Rect", &bounds))
            let rect = try XCTUnwrap(bounds)
            var values = [CGPDFReal](repeating: 0, count: 4)
            for component in 0..<4 { XCTAssertTrue(CGPDFArrayGetNumber(rect, component, &values[component])) }
            return CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
        }
        XCTFail("Saved note annotation disappeared")
        throw PaperPathError.invalidPage
    }

    func testMergePreservesNonstandardNoteRectangle() throws {
        let source = try makeMergeNoteSource()
        let original = try Data(contentsOf: source)
        let output = temporaryDirectory.appendingPathComponent("merged-notes.pdf")
        try PDFCompositionService().combine(urls: [source, source], to: output)
        let expected = try rawNoteRect(in: source, page: 1)
        XCTAssertEqual(expected.width, 30)
        XCTAssertEqual(try rawNoteRect(in: output, page: 1), expected)
        XCTAssertEqual(try rawNoteRect(in: output, page: 2), expected)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExtractionPreservesNonstandardNoteRectangle() throws {
        let source = try makeMergeNoteSource()
        let output = temporaryDirectory.appendingPathComponent("extracted-note.pdf")
        try PDFCompositionService().extractPages(from: source, indices: [0], to: output)
        XCTAssertEqual(try rawNoteRect(in: output, page: 1), try rawNoteRect(in: source, page: 1))
    }
}

extension RealPDFReleaseTests {
    func testCoreTextFormSavePreservesPagesAndOtherFields() throws {
        let source = directory.appendingPathComponent("core-form.pdf")
        try DemoPDFBuilder.create(at: source)
        let before = try XCTUnwrap(PDFDocument(url: source))
        let text = (0..<before.pageCount).map { before.page(at: $0)?.string }
        let report = try PDFFormInspectionService().inspect(url: source)
        let field = try XCTUnwrap(report.fields.first { $0.name == "Recipient name" })
        try PDFMutationService().setTextFormValue("Core Verified 2026", field: field, in: source)
        let saved = try PDFFormInspectionService().inspect(url: source)
        XCTAssertEqual(saved.fields.first { $0.name == field.name }?.value, "Core Verified 2026")
        XCTAssertEqual(saved.fields.filter { $0.name != field.name }.map(\.value),
            report.fields.filter { $0.name != field.name }.map(\.value))
        let after = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(after.pageCount, before.pageCount)
        XCTAssertEqual((0..<after.pageCount).map { after.page(at: $0)?.string }, text)
    }

    func testCoreTextFormRejectsOversizedAndReadOnlyValuesWithoutChangingFile() throws {
        let source = directory.appendingPathComponent("core-form-invalid.pdf")
        try DemoPDFBuilder.create(at: source)
        let report = try PDFFormInspectionService().inspect(url: source)
        let field = try XCTUnwrap(report.fields.first { $0.name == "Recipient name" })
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFMutationService().setTextFormValue(String(repeating: "x", count: 257), field: field, in: source))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let annotation = try XCTUnwrap(document.page(at: field.pageIndex)?.annotations[field.annotationIndex])
        annotation.isReadOnly = true
        XCTAssertTrue(document.write(to: source))
        let protectedBytes = try Data(contentsOf: source)
        // An old editable snapshot must not bypass the current PDF's read-only flag.
        XCTAssertThrowsError(try PDFMutationService().setTextFormValue("Must not save", field: field, in: source))
        XCTAssertEqual(try Data(contentsOf: source), protectedBytes)
    }
}
