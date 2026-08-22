import CryptoKit
import Darwin
import PDFKit
import QuickLookThumbnailing
import UIKit
import XCTest

@testable import PaperPath

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
            let representation = try await QLThumbnailGenerator
                .shared
                .generateBestRepresentation(for: request)
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
                quality: .balanced
            )

        XCTAssertEqual(estimate.sampledPageCount, 3)
        XCTAssertGreaterThan(estimate.sourceByteCount, 0)
        XCTAssertGreaterThan(estimate.estimatedByteCount, 0)
        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(5)
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
            try await store.save(Data([1, 2, 3, 4]))
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
        let storedSignature = await store.load()
        XCTAssertNil(storedSignature)
    }

    func testSignatureStore_updateProtectionFailurePreservesLibrary_BitsUT()
        async throws {
        let root = temporaryDirectory
            .appendingPathComponent("ExistingSignatureStore")
        let original = Data([9, 8, 7, 6])
        try await SignatureStore(rootURL: root).save(original)

        let fileManager = ProtectionFailingFileManager()
        fileManager.deniedPathFragment = "saved-signatures"
        let failingStore = SignatureStore(
            rootURL: root,
            fileManager: fileManager
        )

        do {
            try await failingStore.save(Data([1, 2, 3, 4]))
            XCTFail(
                "Signature update should fail when protection is denied"
            )
        } catch ProtectionTestError.denied {
            // Expected.
        } catch {
            XCTFail("Unexpected protection error: \(error)")
        }

        let storedSignature = await failingStore.load()
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
        XCTAssertEqual(pending[0].preferredName, "Shared contract")

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

        let library = await store.loadLibrary()
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
        for value in 0..<6 {
            _ = try await store.add(Data([UInt8(value)]))
        }

        var library = await store.loadLibrary()
        XCTAssertEqual(
            library.entries.count,
            SignatureStore.maximumSignatureCount
        )
        XCTAssertEqual(library.entries.first?.data, Data([5]))
        XCTAssertEqual(library.selectedID, library.entries.first?.id)

        let originalID = try XCTUnwrap(
            library.entries.first {
                $0.data == Data([3])
            }?.id
        )
        library = try await store.add(Data([3]))
        XCTAssertEqual(library.entries.count, 5)
        XCTAssertEqual(library.entries.first?.id, originalID)
        XCTAssertEqual(library.entries.first?.data, Data([3]))

        library = try await store.remove(id: originalID)
        XCTAssertEqual(library.entries.count, 4)
        XCTAssertEqual(library.selectedID, library.entries.first?.id)
        let loaded = await store.load()
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
        let legacy = Data([7, 8, 9])
        try legacy.write(to: legacyURL)
        let store = SignatureStore(rootURL: root)

        let loaded = await store.load()
        XCTAssertEqual(loaded, legacy)
        let library = try await store.add(Data([1, 2, 3]))

        XCTAssertEqual(library.entries.count, 2)
        XCTAssertEqual(library.entries.first?.data, Data([1, 2, 3]))
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
        XCTAssertEqual(indices[record.id], originalIndex)
        XCTAssertEqual(results[record.id], originalOCR)
        XCTAssertEqual(records.first?.brief, originalBrief)
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

        let resumed = run.restored(currentRevisionID: revisionID)
        XCTAssertEqual(resumed.status, .paused)
        XCTAssertEqual(resumed.segments[0].status, .queued)
        XCTAssertEqual(resumed.segments[0].fractionCompleted, 0)
        XCTAssertEqual(resumed.segments[1].status, .completed)

        let changed = run.restored(currentRevisionID: UUID())
        XCTAssertEqual(changed.status, .partial)
        XCTAssertEqual(changed.segments[0].status, .failed)
        XCTAssertEqual(changed.segments[0].fractionCompleted, 1)
        XCTAssertEqual(changed.segments[1].status, .completed)
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
            ]
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
            note: "  \(String(repeating: "n", count: 1_200))  "
        )
        XCTAssertEqual(record.privateNote?.count, 1_000)
        record = try await store.updateReadingPosition(
            record,
            pageIndex: 99
        )
        XCTAssertEqual(record.lastPageIndex, 3)

        let loaded = try await store.load()
        let reopened = try XCTUnwrap(loaded.first)
        XCTAssertEqual(reopened.tags, record.tags)
        XCTAssertEqual(reopened.bookmarkedPages, [1, 3])
        XCTAssertEqual(reopened.privateNote?.count, 1_000)
        XCTAssertEqual(reopened.lastPageIndex, 3)
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
            contentRevisionID: revisionID,
            preserveSourceLocation: false
        )
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
            contentRevisionID: revisionID,
            preserveSourceLocation: false
        )
        let recovery = try await store.createVersionSnapshot(
            for: imported,
            label: "Before edit"
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

    @MainActor
    func testMetadataSync_clearRemovesCloudAndShadowPayloads_BitsUT()
        throws {
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
        _ = try service.synchronize(records: [])
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
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
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
            presentsFeedback: false
        )
        async let second = model.createCompressedCopy(
            recordID: imported.id,
            quality: .compact,
            presentsFeedback: false
        )
        let results = await (first, second)
        let created = [results.0, results.1].compactMap { $0 }

        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(
            model.documents.filter {
                $0.sourceDocumentID == imported.id
            }.count,
            1
        )
        XCTAssertFalse(model.isProcessing(imported.id))
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
        let createdAt = Date(timeIntervalSince1970: 100)
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
        let store = DocumentStore(rootURL: root)
        let archiveURL = temporaryDirectory
            .appendingPathComponent("delivery.zip")
        let reportURL = temporaryDirectory
            .appendingPathComponent("delivery-report.json")
        let archiveData = Data("verified-archive".utf8)
        let reportData = Data("verified-report".utf8)
        try archiveData.write(to: archiveURL)
        try reportData.write(to: reportURL)
        let package = PDFOfficeDeliveryPackage(entries: [])

        let first = try await store.retainOfficeDeliveryPackage(
            package,
            archiveURL: archiveURL,
            reportURL: reportURL
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
            modifiedIndex
        )
    }

    @MainActor
    func testMetadataSync_clearFailureIsObservable_BitsUT() throws {
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
        _ = try service.synchronize(records: [])
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

    func testSignatureStore_unknownSelectionAndRemovalAreIdempotent_BitsUT()
        async throws {
        let store = SignatureStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("IdempotentSignatureStore")
        )
        let initial = try await store.add(Data([1, 2, 3]))
        let selected = try await store.select(UUID())
        let removed = try await store.remove(id: UUID())

        XCTAssertEqual(selected.entries, initial.entries)
        XCTAssertEqual(selected.selectedID, initial.selectedID)
        XCTAssertEqual(removed.entries, initial.entries)
        XCTAssertEqual(removed.selectedID, initial.selectedID)
        let loaded = await store.load()
        XCTAssertEqual(loaded, Data([1, 2, 3]))
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
        XCTAssertTrue(lockedPlan.riskEvidence.contains("Locked"))
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
        let createdAt = Date(timeIntervalSince1970: 100)
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
        let createdAt = Date(timeIntervalSince1970: 100)
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

        let rawReport = try PDFVersionArchiveVerificationService()
            .verify(archiveURL: archiveURL)
        XCTAssertEqual(rawReport.status, .verified)
        XCTAssertEqual(rawReport.signatureStatus, .verified)
        XCTAssertEqual(rawReport.trustStatus, .unknown)
        let trustedReport = try await store.resolveVersionArchiveTrust(
            rawReport
        )
        XCTAssertEqual(trustedReport.trustStatus, .thisDevice)
        XCTAssertEqual(trustedReport.verifiedCount, 1)
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
            metadataBytes: 8
        )
        XCTAssertEqual(storage.totalBytes, 36)
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

    private func makeOCRBlock(
        text: String,
        confidence: Double
    ) -> OCRTextBlock {
        OCRTextBlock(
            text: text,
            confidence: confidence,
            normalizedX: 0.1,
            normalizedY: 0.1,
            normalizedWidth: 0.8,
            normalizedHeight: 0.08
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
            checks: [],
            outputRevisionID: revisionID
        )
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
