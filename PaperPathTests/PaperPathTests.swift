import Darwin
import ImageIO
import PDFKit
import UIKit
import XCTest
@testable import PaperPath

final class PaperPathTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var previousLanguageCode: String?

    override func setUpWithError() throws {
        previousLanguageCode = UserDefaults.standard.string(
            forKey: AppLanguage.defaultsKey
        )
        UserDefaults.standard.set(
            AppLanguage.english.rawValue,
            forKey: AppLanguage.defaultsKey
        )
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        if let previousLanguageCode {
            UserDefaults.standard.set(
                previousLanguageCode,
                forKey: AppLanguage.defaultsKey
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: AppLanguage.defaultsKey
            )
        }
    }

    func testInspectorClassifiesTextPDF() throws {
        let url = temporaryDirectory.appendingPathComponent("text.pdf")
        try makePDF(at: url, pages: ["A searchable project handoff document."])

        let profile = try PDFInspectionService().inspect(url: url)

        XCTAssertEqual(profile.kind, .text)
        XCTAssertEqual(profile.pageCount, 1)
        XCTAssertGreaterThan(profile.textCharacterCount, 24)
        XCTAssertFalse(profile.recommendedActions.contains(.recognizeText))
        XCTAssertEqual(profile.recommendedActions, [.inspect, .shareCopy])
    }

    func testDeviceGoldenPathsCompleteEndToEnd() async throws {
        let reportURL = temporaryDirectory
            .appendingPathComponent("device-golden-paths.json")

        await DeviceGoldenPathDiagnostics.run(reportURL: reportURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(
            DeviceGoldenPathReport.self,
            from: Data(contentsOf: reportURL)
        )
        XCTAssertTrue(
            report.passed,
            report.results.compactMap { result in
                result.failure.map { "\(result.id): \($0)" }
            }.joined(separator: "\n")
        )
        XCTAssertEqual(
            Set(report.results.map(\.id)),
            [
                "fill-sign-verify",
                "redact-verify",
                "scan-ocr-verify",
                "ocr-page-recovery"
            ]
        )
    }

    func testInspectorRecommendsOCRAndPageToolsForScannedPDF() throws {
        let url = temporaryDirectory.appendingPathComponent("scan.pdf")
        try makePDF(at: url, pages: ["", ""])

        let profile = try PDFInspectionService().inspect(url: url)

        XCTAssertEqual(profile.kind, .scan)
        XCTAssertEqual(profile.imageDominantPageCount, 2)
        XCTAssertEqual(
            profile.recommendedActions,
            [.recognizeText, .organizePages, .inspect, .shareCopy]
        )
    }

    func testInspectorBoundsLargeDocumentSampling() throws {
        let url = temporaryDirectory.appendingPathComponent("large.pdf")
        try makePDF(
            at: url,
            pages: Array(repeating: "Searchable content for sampled pages.", count: 40)
        )

        let profile = try PDFInspectionService().inspect(url: url)

        XCTAssertEqual(profile.pageCount, 40)
        XCTAssertEqual(profile.sampledPageCount, 12)
        XCTAssertEqual(profile.kind, .text)
    }

    func testInspectorDetectsInteractiveForm() throws {
        let url = temporaryDirectory.appendingPathComponent("form.pdf")
        try makePDF(at: url, pages: ["Complete the field below."])
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 56, y: 300, width: 240, height: 42),
            forType: .widget,
            withProperties: nil
        )
        annotation.widgetFieldType = .text
        annotation.fieldName = "full-name"
        page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: url))

        let profile = try PDFInspectionService().inspect(url: url)

        XCTAssertEqual(profile.kind, .form)
        XCTAssertEqual(profile.formFieldCount, 1)
        XCTAssertEqual(profile.recommendedActions.first, .reviewForm)
    }

    func testInspectorFindsFormFieldOutsideTextSamplePages() throws {
        let url = temporaryDirectory
            .appendingPathComponent("long-form.pdf")
        try makePDF(
            at: url,
            pages: (0..<40).map { "Page \($0 + 1)" }
        )
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 38))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 56, y: 300, width: 240, height: 42),
            forType: .widget,
            withProperties: nil
        )
        annotation.widgetFieldType = .signature
        annotation.fieldName = "approval-signature"
        page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: url))

        let profile = try PDFInspectionService().inspect(url: url)

        XCTAssertEqual(profile.pageCount, 40)
        XCTAssertEqual(profile.sampledPageCount, 12)
        XCTAssertEqual(profile.formFieldCount, 1)
        XCTAssertEqual(profile.kind, .form)
    }

    func testFormFieldCreationAndCompatibilityReport() throws {
        let url = temporaryDirectory
            .appendingPathComponent("created-form.pdf")
        try makePDF(at: url, pages: ["Complete and sign"])
        let service = PDFMutationService()
        try service.addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .text,
                name: "Full name",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.12,
                    y: 0.28,
                    width: 0.48,
                    height: 0.08
                ),
                isRequired: true,
                isMultiline: false,
                maximumLength: 80
            ),
            in: url
        )
        try service.addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .signature,
                name: "Approval signature",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.48,
                    y: 0.72,
                    width: 0.38,
                    height: 0.09
                ),
                isRequired: true,
                isMultiline: false,
                maximumLength: nil
            ),
            in: url
        )

        let report = try PDFFormInspectionService().inspect(url: url)

        XCTAssertEqual(
            report.compatibility,
            .ready,
            report.issues.joined(separator: " | ")
        )
        XCTAssertEqual(report.fields.count, 2)
        XCTAssertEqual(
            report.fields.map(\.kind),
            [.text, .signature]
        )
        XCTAssertTrue(report.fields.allSatisfy(\.isRequired))
        XCTAssertEqual(
            report.fields.first?.maximumLength,
            80
        )
        XCTAssertEqual(report.incompleteRequiredFields.count, 2)
        XCTAssertTrue(report.issues.isEmpty)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 2)
    }

    func testVisualSignatureCompletesOnlyItsOverlappingFormField()
        throws {
        let url = temporaryDirectory
            .appendingPathComponent("visual-signature-form.pdf")
        try makePDF(at: url, pages: ["Sign in the marked field"])
        let fieldBounds = PDFNormalizedRect(
            x: 0.48,
            y: 0.72,
            width: 0.38,
            height: 0.09
        )
        let service = PDFMutationService()
        try service.addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .signature,
                name: "Approval signature",
                normalizedBounds: fieldBounds,
                isRequired: true,
                isMultiline: false,
                maximumLength: nil
            ),
            in: url
        )

        var report = try PDFFormInspectionService().inspect(url: url)
        XCTAssertFalse(report.fields[0].isComplete)
        XCTAssertFalse(report.isReadyForVerifiedOutput)

        let stroke = PDFInkStroke(
            points: [
                PDFInkPoint(x: 0.08, y: 0.7),
                PDFInkPoint(x: 0.38, y: 0.28),
                PDFInkPoint(x: 0.68, y: 0.62),
                PDFInkPoint(x: 0.92, y: 0.2)
            ]
        )
        try service.addInk(
            PDFInkPayload(
                pageIndex: 0,
                strokes: [stroke],
                placement: .signature,
                normalizedBounds: PDFNormalizedRect(
                    x: 0.06,
                    y: 0.08,
                    width: 0.3,
                    height: 0.08
                )
            ),
            in: url
        )

        report = try PDFFormInspectionService().inspect(url: url)
        XCTAssertFalse(report.fields[0].isComplete)
        XCTAssertFalse(report.isReadyForVerifiedOutput)

        try service.addInk(
            PDFInkPayload(
                pageIndex: 0,
                strokes: [stroke],
                placement: .signature,
                normalizedBounds: fieldBounds
            ),
            in: url
        )

        report = try PDFFormInspectionService().inspect(url: url)
        XCTAssertTrue(report.fields[0].isComplete)
        XCTAssertTrue(report.incompleteRequiredFields.isEmpty)
        XCTAssertTrue(report.isReadyForVerifiedOutput)
    }

    func testOptionalBlankFormFieldDoesNotBlockVerifiedOutput()
        throws {
        let url = temporaryDirectory
            .appendingPathComponent("optional-form.pdf")
        try makePDF(at: url, pages: ["Optional note"])
        try PDFMutationService().addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .text,
                name: "Optional note",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.12,
                    y: 0.28,
                    width: 0.48,
                    height: 0.08
                ),
                isRequired: false,
                isMultiline: false,
                maximumLength: 120
            ),
            in: url
        )

        let report = try PDFFormInspectionService().inspect(url: url)

        XCTAssertEqual(report.incompleteOptionalFields.count, 1)
        XCTAssertTrue(report.incompleteRequiredFields.isEmpty)
        XCTAssertTrue(report.isReadyForVerifiedOutput)
    }

    func testXFAFormIsPreservedForCompatibleReader() throws {
        let url = temporaryDirectory
            .appendingPathComponent("xfa-form.pdf")
        try makeXFAStubPDF(at: url)

        let report = try PDFFormInspectionService().inspect(url: url)

        XCTAssertTrue(report.hasXFA)
        XCTAssertEqual(report.compatibility, .unsupported)
        XCTAssertTrue(report.requiresCompatibleReader)
        XCTAssertFalse(report.isReadyForVerifiedOutput)
        XCTAssertTrue(
            report.issues.contains {
                $0.contains("preserves it")
            }
        )
        XCTAssertNotNil(PDFDocument(url: url))
    }

    func testFormFieldCreationRejectsDuplicateName() throws {
        let url = temporaryDirectory
            .appendingPathComponent("duplicate-form.pdf")
        try makePDF(at: url, pages: ["Form"])
        let payload = PDFFormFieldPayload(
            pageIndex: 0,
            kind: .checkbox,
            name: "Consent",
            normalizedBounds: PDFNormalizedRect(
                x: 0.1,
                y: 0.2,
                width: 0.08,
                height: 0.06
            ),
            isRequired: false,
            isMultiline: false,
            maximumLength: nil
        )
        let service = PDFMutationService()
        try service.addFormField(payload, in: url)

        XCTAssertThrowsError(
            try service.addFormField(payload, in: url)
        )
        let report = try PDFFormInspectionService().inspect(url: url)
        XCTAssertEqual(report.fields.count, 1)
        XCTAssertEqual(report.fields.first?.kind, .checkbox)
    }

    func testRadioGroupAndChoiceFieldRoundTrip() throws {
        let url = temporaryDirectory
            .appendingPathComponent("choice-form.pdf")
        try makePDF(at: url, pages: ["Delivery preferences"])
        let service = PDFMutationService()

        try service.addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .radio,
                name: "Delivery speed",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.12,
                    y: 0.24,
                    width: 0.48,
                    height: 0.16
                ),
                isRequired: true,
                isMultiline: false,
                maximumLength: nil,
                options: ["Standard", "Express"]
            ),
            in: url
        )
        try service.addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .choice,
                name: "Department",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.12,
                    y: 0.5,
                    width: 0.48,
                    height: 0.08
                ),
                isRequired: false,
                isMultiline: false,
                maximumLength: nil,
                options: ["Design", "Engineering", "Operations"]
            ),
            in: url
        )

        let report = try PDFFormInspectionService().inspect(url: url)
        let radioFields = report.fields.filter {
            $0.kind == .radio
        }
        let choice = try XCTUnwrap(
            report.fields.first { $0.kind == .choice }
        )

        XCTAssertTrue(
            report.fields.allSatisfy { $0.issue == nil },
            report.fields.compactMap { field in
                field.issue.map { "\(field.name): \($0)" }
            }.joined(separator: " | ")
        )
        XCTAssertEqual(
            report.compatibility,
            .ready,
            report.issues.joined(separator: " | ")
        )
        XCTAssertEqual(radioFields.count, 2)
        XCTAssertTrue(radioFields.allSatisfy(\.isRequired))
        XCTAssertEqual(
            Set(radioFields.map(\.name)),
            ["Delivery speed"]
        )
        XCTAssertEqual(choice.name, "Department")
        XCTAssertEqual(choice.optionCount, 3)
        XCTAssertEqual(report.incompleteRequiredFields.count, 2)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let annotations = try XCTUnwrap(
            reopened.page(at: 0)?.annotations
        )
        XCTAssertEqual(
            annotations.filter {
                $0.widgetControlType == .radioButtonControl
            }.count,
            2
        )
        XCTAssertEqual(
            annotations.filter {
                $0.widgetFieldType == .choice
            }.first?.choices,
            ["Design", "Engineering", "Operations"]
        )

        XCTAssertThrowsError(
            try service.addFormField(
                PDFFormFieldPayload(
                    pageIndex: 0,
                    kind: .choice,
                    name: "Invalid choice",
                    normalizedBounds: PDFNormalizedRect(
                        x: 0.12,
                        y: 0.65,
                        width: 0.4,
                        height: 0.08
                    ),
                    isRequired: false,
                    isMultiline: false,
                    maximumLength: nil,
                    options: ["Same", "same"]
                ),
                in: url
            )
        )
    }

    func testScanRendererProducesImageDominantPages() throws {
        let url = temporaryDirectory.appendingPathComponent("camera-scan.pdf")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1_200))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1_200))
            UIColor.systemGray3.setFill()
            context.fill(CGRect(x: 80, y: 100, width: 740, height: 1_000))
        }

        try ScanPDFRenderer().render(images: [image, image], to: url)
        let profile = try PDFInspectionService().inspect(url: url)

        XCTAssertEqual(profile.pageCount, 2)
        XCTAssertEqual(profile.kind, .scan)
    }

    func testScanEnhancementDetectsAndCropsDocumentEdges() throws {
        let image = syntheticDocumentPhoto()
        let result = ScanPDFRenderer().preview(
            image: image,
            options: .document
        )

        XCTAssertTrue(result.detectedDocument)
        XCTAssertGreaterThan(result.image.size.width, 300)
        XCTAssertGreaterThan(result.image.size.height, 400)
        XCTAssertLessThan(
            result.image.size.width / result.image.size.height,
            0.9
        )
    }

    func testBlackAndWhiteScanRendersVerifiedPDF() throws {
        let url = temporaryDirectory
            .appendingPathComponent("cleaned-scan.pdf")
        let image = syntheticDocumentPhoto()
        let options = ScanProcessingOptions(
            enhancement: .blackAndWhite,
            autoCrop: true,
            removeShadows: true,
            cleanEdges: true
        )
        let progress = ProgressRecorder()

        try ScanPDFRenderer().render(
            pages: [
                ScanPageImage(image: image),
                ScanPageImage(image: image)
            ],
            to: url,
            options: options
        ) {
            progress.append($0)
        }

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(progress.values.first, 0)
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertNotNil(
            document.page(at: 1)?.thumbnail(
                of: CGSize(width: 306, height: 396),
                for: .cropBox
            ).cgImage
        )
    }

    func testLongDocumentBudgetsAt100500And1000Pages() throws {
        let pageCounts = [100, 500, 1_000]
        for pageCount in pageCounts {
            let url = temporaryDirectory
                .appendingPathComponent("budget-\(pageCount).pdf")
            try makePDF(
                at: url,
                pages: (0..<pageCount).map {
                    "Performance page \($0 + 1)"
                }
            )
            let baseline = currentResidentMemory()
            let sampler = ProcessMemorySampler()
            sampler.start()
            let start = ContinuousClock.now

            let profile = try PDFInspectionService().inspect(url: url)

            let elapsed = start.duration(to: .now)
            let peakDelta = sampler.stop().saturatingSubtracting(
                baseline
            )
            XCTAssertEqual(profile.pageCount, pageCount)
            XCTAssertEqual(profile.sampledPageCount, 12)
            XCTAssertLessThan(
                elapsed,
                .seconds(2.5),
                "\(pageCount)-page inspection exceeded 2.5 seconds"
            )
            XCTAssertLessThan(
                peakDelta,
                250 * 1_024 * 1_024,
                "\(pageCount)-page inspection exceeded 250 MB"
            )
        }
    }

    func testLongDocumentExtractionPreservesSelectedOrder() throws {
        let source = temporaryDirectory
            .appendingPathComponent("thousand-pages.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("thousand-extract.pdf")
        try makePDF(
            at: source,
            pages: (0..<1_000).map { "Marker \($0)" }
        )

        try PDFCompositionService().extractPages(
            from: source,
            indices: [999, 0, 499],
            to: output
        )

        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(
            document.page(at: 0)?.string?.contains("Marker 0")
                == true
        )
        XCTAssertTrue(
            document.page(at: 1)?.string?.contains("Marker 499")
                == true
        )
        XCTAssertTrue(
            document.page(at: 2)?.string?.contains("Marker 999")
                == true
        )
    }

    func testLongDocumentCancellationReturnsWithin250Milliseconds() async throws {
        let source = temporaryDirectory
            .appendingPathComponent("cancel-thousand.pdf")
        try makePDF(
            at: source,
            pages: (0..<1_000).map { "Cancel marker \($0)" }
        )
        let task = Task.detached(priority: .utility) {
            try PDFInspectionService().inspect(url: source)
        }
        try? await Task.sleep(for: .milliseconds(1))
        let cancelledAt = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected when traversal has not already completed.
        }
        XCTAssertLessThan(
            cancelledAt.duration(to: .now),
            .milliseconds(250)
        )
    }

    func testImportCreatesIndependentPrivateCopy() async throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try makePDF(at: source, pages: ["Private source"])
        let storeRoot = temporaryDirectory.appendingPathComponent("Store")
        let store = DocumentStore(rootURL: storeRoot)

        let record = try await store.importPDF(from: source)
        let privateURL = await store.url(for: record)
        try FileManager.default.removeItem(at: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: privateURL.path))
        let records = try await store.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertNotEqual(privateURL, source)
    }

    func testImportRejectsUnreadablePDFWithoutCreatingCopy() async throws {
        let source = temporaryDirectory.appendingPathComponent("damaged.pdf")
        try Data("not a PDF".utf8).write(to: source)
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("DamagedStore")
        )

        do {
            _ = try await store.importPDF(from: source)
            XCTFail("A damaged PDF should not be imported.")
        } catch let error as PaperPathError {
            XCTAssertEqual(
                error.errorDescription,
                PaperPathError.unreadablePDF.errorDescription
            )
        }
        let records = try await store.load()
        XCTAssertTrue(records.isEmpty)
    }

    func testImportRejectsInsufficientStorageWithoutCreatingCopy() async throws {
        let source = temporaryDirectory.appendingPathComponent("large.pdf")
        try makePDF(at: source, pages: ["Needs storage"])
        let storeRoot = temporaryDirectory.appendingPathComponent("FullStore")
        let store = DocumentStore(
            rootURL: storeRoot,
            availableCapacity: { _ in 0 }
        )

        do {
            _ = try await store.importPDF(from: source)
            XCTFail("Import should stop before copying.")
        } catch let error as PaperPathError {
            XCTAssertEqual(
                error.errorDescription,
                PaperPathError.insufficientStorage.errorDescription
            )
        }
        let documentURLs = try FileManager.default.contentsOfDirectory(
            at: storeRoot.appendingPathComponent("Documents"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(documentURLs.isEmpty)
    }

    func testRenameChangesMetadataNotFileLocation() async throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        try makePDF(at: source, pages: ["Rename me"])
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("Store")
        )
        let record = try await store.importPDF(from: source)
        let originalURL = await store.url(for: record)

        let renamed = try await store.rename(
            record,
            to: "Signed contract",
            expectedName: record.displayName
        )
        let renamedURL = await store.url(for: renamed)

        XCTAssertEqual(renamed.displayName, "Signed contract")
        XCTAssertEqual(renamedURL, originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }

    func testPageMutationRotateMoveAndDelete() throws {
        let url = temporaryDirectory.appendingPathComponent("pages.pdf")
        try makePDF(at: url, pages: ["First page marker", "Second page marker"])
        let service = PDFMutationService()

        try service.rotatePage(at: 0, in: url)
        var document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.page(at: 0)?.rotation, 90)

        try service.movePage(at: 0, direction: .later, in: url)
        document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Second") == true)

        try service.deletePage(at: 1, in: url)
        document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertThrowsError(try service.deletePage(at: 0, in: url))
    }

    func testDocumentUnderstandingExtractsInvoiceFactsAndSteps() throws {
        let index = DocumentTextIndex(
            source: .native,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: """
                    Invoice #PP-2048
                    Invoice date: August 8, 2026
                    Amount due: USD 1,280.00
                    Contact billing@example.com
                    Signature required
                    """
                )
            ],
            indexedAt: Date()
        )

        let brief = DocumentUnderstandingService().analyze(
            index: index,
            profile: textProfile(pageCount: 1)
        )

        XCTAssertEqual(brief.category, .invoice)
        XCTAssertTrue(
            brief.entities.contains {
                $0.kind == .amount && $0.value.contains("1,280.00")
            }
        )
        XCTAssertTrue(
            brief.entities.contains {
                $0.kind == .email && $0.value == "billing@example.com"
            }
        )
        XCTAssertTrue(
            brief.suggestedSteps.contains { $0.kind == .reviewAmount }
        )
        XCTAssertTrue(
            brief.suggestedSteps.contains { $0.kind == .reviewSignature }
        )
    }

    func testTextIndexFindsMatchingPage() {
        let index = DocumentTextIndex(
            source: .native,
            pages: [
                IndexedPageText(pageIndex: 0, text: "Cover page"),
                IndexedPageText(pageIndex: 1, text: "Payment reference PP-2048")
            ],
            indexedAt: Date()
        )

        XCTAssertEqual(index.firstMatchingPage(for: "PP-2048"), 1)
        XCTAssertEqual(index.firstMatchingPage(for: "payment PP-2048"), 1)
        XCTAssertNil(index.firstMatchingPage(for: "missing"))
    }

    func testStorePersistsWorkflowBriefAndTextIndex() async throws {
        let source = temporaryDirectory.appendingPathComponent("indexed.pdf")
        try makePDF(at: source, pages: ["Invoice amount USD 40.00"])
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("Store")
        )
        let record = try await store.importPDF(from: source)
        let index = try PDFTextIndexService().extractNativeText(from: source)
        let brief = DocumentUnderstandingService().analyze(
            index: index,
            profile: record.profile
        )

        let analyzed = try await store.saveAnalysis(
            record,
            brief: brief,
            textIndex: index
        )
        _ = try await store.updateWorkflow(analyzed, status: .reviewing)

        let reloaded = try await store.load()
        let indices = try await store.loadTextIndices()
        XCTAssertEqual(reloaded.first?.workflowStatus, .reviewing)
        XCTAssertEqual(reloaded.first?.brief?.category, .invoice)
        XCTAssertEqual(indices[record.id]?.text, index.text)
    }

    func testStoreRepeatedAnalysisReplacementRemainsReadable()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("repeated-index.pdf")
        try makePDF(at: source, pages: ["Initial searchable text"])
        let root = temporaryDirectory
            .appendingPathComponent("RepeatedIndexStore")
        let store = DocumentStore(rootURL: root)
        var record = try await store.importPDF(from: source)

        for revision in 0..<32 {
            let text = "Replacement index revision \(revision)"
            let index = DocumentTextIndex(
                source: .vision,
                pages: [
                    IndexedPageText(pageIndex: 0, text: text)
                ],
                indexedAt: Date(
                    timeIntervalSince1970: Double(revision + 1)
                )
            )
            let brief = DocumentUnderstandingService().analyze(
                index: index,
                profile: record.profile
            )

            record = try await store.saveAnalysis(
                record,
                brief: brief,
                textIndex: index
            )
            let storedIndex = index.bound(
                to: record.contentRevisionID
            )

            let sameStoreIndices = try await store.loadTextIndices()
            XCTAssertEqual(
                sameStoreIndices[record.id],
                storedIndex,
                "Same-store read failed after replacement \(revision)"
            )

            let reopenedStore = DocumentStore(rootURL: root)
            let reopenedIndices = try await reopenedStore.loadTextIndices()
            XCTAssertEqual(
                reopenedIndices[record.id],
                storedIndex,
                "Reopened-store read failed after replacement \(revision)"
            )
        }
    }

    func testTaskCheckpointPersistsExactSignatureResume()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("resume-signature.pdf")
        try makePDF(
            at: source,
            pages: ["Page one", "Page two", "Page three"]
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "TaskCheckpointStore"
            )
        )
        let record = try await store.importPDF(from: source)
        let bounds = PDFNormalizedRect(
            x: 0.46,
            y: 0.72,
            width: 0.4,
            height: 0.1
        )

        let updated = try await store.updateTaskCheckpoint(
            record,
            checkpoint: DocumentTaskCheckpoint(
                stage: .sign,
                pageIndex: 2,
                fieldName: "Approval signature",
                normalizedBounds: bounds,
                updatedAt: Date(timeIntervalSince1970: 42)
            )
        )
        let loaded = try await store.load()
        let reloaded = try XCTUnwrap(loaded.first)

        XCTAssertEqual(updated.workflowStatus, .reviewing)
        XCTAssertEqual(reloaded.taskCheckpoint?.stage, .sign)
        XCTAssertEqual(reloaded.taskCheckpoint?.pageIndex, 2)
        XCTAssertEqual(
            reloaded.taskCheckpoint?.fieldName,
            "Approval signature"
        )
        XCTAssertEqual(reloaded.taskCheckpoint?.normalizedBounds, bounds)
        let action = DocumentActionPlanner.recommendation(
            for: reloaded,
            hasRecognizedText: false
        )
        XCTAssertEqual(action.action, .sign)
        XCTAssertTrue(action.reason.contains("Approval signature"))
        let task = try XCTUnwrap(
            PDFTaskPackagePlanner.recommendation(
                for: reloaded,
                hasRecognizedText: false
            )
        )
        XCTAssertEqual(task.task, .signPDF)
        XCTAssertEqual(task.title, "Continue signing")

        _ = try await store.updateTaskCheckpoint(
            reloaded,
            checkpoint: nil
        )
        let cleared = try await store.load()
        XCTAssertNil(cleared.first?.taskCheckpoint)
    }

    func testTaskCheckpointBoundsRestoredPageToDocument()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("resume-bounds.pdf")
        try makePDF(at: source, pages: ["One", "Two"])
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "TaskCheckpointBoundsStore"
            )
        )
        let record = try await store.importPDF(from: source)

        let updated = try await store.updateTaskCheckpoint(
            record,
            checkpoint: DocumentTaskCheckpoint(
                stage: .fillForm,
                pageIndex: 99,
                fieldName: "Name"
            )
        )

        XCTAssertEqual(updated.taskCheckpoint?.pageIndex, 1)
    }

    func testRecordDecodesLegacyMetadataWithoutBookmarks() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "displayName": "Legacy",
          "fileName": "\(id.uuidString).pdf",
          "importedAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z",
          "profile": {
            "pageCount": 1,
            "sampledPageCount": 1,
            "textCharacterCount": 10,
            "imageDominantPageCount": 0,
            "formFieldCount": 0,
            "byteCount": 100,
            "isEncrypted": false,
            "isLocked": false,
            "allowsCopying": true,
            "allowsCommenting": true,
            "kind": "text",
            "recommendedActions": ["inspect", "shareCopy"]
          },
          "workflowStatus": "inbox",
          "isPinned": false,
          "tags": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(
            DocumentRecord.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(record.id, id)
        XCTAssertTrue(record.bookmarkedPages.isEmpty)
        XCTAssertTrue(record.completedActions.isEmpty)
        XCTAssertNil(record.deliveryReceipt)
    }

    func testCompletedActionsPersistAndCanBeReopened() async throws {
        let source = temporaryDirectory.appendingPathComponent("signed.pdf")
        try makePDF(at: source, pages: ["Sign here"])
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("CompletionStore")
        )
        let record = try await store.importPDF(from: source)

        let completed = try await store.setActionCompletion(
            record,
            action: .sign,
            completed: true
        )
        var reloaded = try await store.load()
        XCTAssertTrue(completed.completedActions.contains(.sign))
        XCTAssertTrue(reloaded.first?.completedActions.contains(.sign) == true)

        _ = try await store.setActionCompletion(
            completed,
            action: .sign,
            completed: false
        )
        reloaded = try await store.load()
        XCTAssertFalse(reloaded.first?.completedActions.contains(.sign) == true)
    }

    func testBookmarksPersistAndDiscardInvalidPages() async throws {
        let source = temporaryDirectory.appendingPathComponent("bookmarks.pdf")
        try makePDF(at: source, pages: ["One", "Two"])
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("BookmarkStore")
        )
        let record = try await store.importPDF(from: source)

        let updated = try await store.updateBookmarks(
            record,
            pages: [1, 0, 1, -1, 5]
        )
        let loaded = try await store.load()

        XCTAssertEqual(updated.bookmarkedPages, [0, 1])
        XCTAssertEqual(loaded.first?.bookmarkedPages, [0, 1])
    }

    func testReadingPositionPersistsWithoutChangingModifiedOrder() async throws {
        let source = temporaryDirectory
            .appendingPathComponent("reading-position.pdf")
        try makePDF(
            at: source,
            pages: ["One", "Two", "Three", "Four"]
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("ReadingPositionStore")
        )
        let record = try await store.importPDF(from: source)
        let modifiedAt = record.modifiedAt
        let viewedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let updated = try await store.updateReadingPosition(
            recordID: record.id,
            pageIndex: 3,
            expectedRevisionID: record.contentRevisionID,
            viewedAt: viewedAt
        )
        let loaded = try await store.load()
        let reopened = try XCTUnwrap(loaded.first)

        XCTAssertEqual(updated.lastPageIndex, 3)
        XCTAssertEqual(reopened.lastPageIndex, 3)
        XCTAssertEqual(
            try XCTUnwrap(reopened.lastViewedAt)
                .timeIntervalSince1970,
            viewedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            reopened.modifiedAt.timeIntervalSince1970,
            modifiedAt.timeIntervalSince1970,
            accuracy: 1
        )
    }

    @MainActor
    func testMetadataSyncMergesIndependentDeviceChangesByField()
        async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fingerprint = String(repeating: "a", count: 64)
        let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
        let shadowA = TestMetadataKeyValueStore(
            isCloudBacked: false
        )
        let shadowB = TestMetadataKeyValueStore(
            isCloudBacked: false
        )
        var deviceA = DocumentRecord(
            displayName: "Client Contract",
            fileName: "a.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(5),
            profile: textProfile(pageCount: 8),
            workflowStatus: .reviewing,
            isPinned: true,
            tags: ["Legal"],
            bookmarkedPages: [1, 5],
            lastPageIndex: 3,
            lastViewedAt: base.addingTimeInterval(6),
            completedActions: [.brief],
            sourceImportedFingerprint: fingerprint,
            contentFingerprint: fingerprint
        )
        var deviceB = DocumentRecord(
            displayName: "Renamed Elsewhere",
            fileName: "b.pdf",
            importedAt: base.addingTimeInterval(100),
            modifiedAt: base.addingTimeInterval(100),
            profile: textProfile(pageCount: 8),
            sourceImportedFingerprint: fingerprint,
            contentFingerprint: fingerprint
        )

        let firstA = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowA,
            now: { base.addingTimeInterval(10) }
        )
        let resultA = try await firstA.synchronize(records: [deviceA])
        XCTAssertTrue(resultA.isCloudAvailable)
        XCTAssertTrue(resultA.updates.isEmpty)

        let firstB = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowB,
            now: { base.addingTimeInterval(20) }
        )
        let resultB = try await firstB.synchronize(records: [deviceB])
        let imported = try XCTUnwrap(resultB.updates.first)
        XCTAssertEqual(imported.lastPageIndex, 3)
        XCTAssertEqual(imported.bookmarkedPages, [1, 5])
        XCTAssertEqual(imported.tags, ["Legal"])
        XCTAssertTrue(imported.isPinned)

        deviceB.lastPageIndex = imported.lastPageIndex
        deviceB.lastViewedAt = imported.lastViewedAt
        deviceB.bookmarkedPages = imported.bookmarkedPages
        deviceB.workflowStatus = imported.workflowStatus
        deviceB.isPinned = imported.isPinned
        deviceB.tags = imported.tags
        deviceB.completedActions = imported.completedActions
        deviceB.lastPageIndex = 4
        deviceB.lastViewedAt = base.addingTimeInterval(30)
        let secondB = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowB,
            now: { base.addingTimeInterval(31) }
        )
        _ = try await secondB.synchronize(records: [deviceB])

        deviceA.tags = ["Priority"]
        deviceA.modifiedAt = base.addingTimeInterval(40)
        let secondA = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowA,
            now: { base.addingTimeInterval(41) }
        )
        let mergedResult = try await secondA.synchronize(
            records: [deviceA]
        )
        let merged = try XCTUnwrap(mergedResult.updates.first)
        XCTAssertEqual(merged.lastPageIndex, 4)
        XCTAssertEqual(merged.tags, ["Priority"])
        XCTAssertEqual(merged.bookmarkedPages, [1, 5])
        XCTAssertEqual(merged.workflowStatus, .reviewing)

        let cloudText = cloud.storage.values.compactMap {
            String(data: $0, encoding: .utf8)
        }.joined()
        XCTAssertFalse(cloudText.contains("Client Contract"))
        XCTAssertFalse(cloudText.contains("Renamed Elsewhere"))
    }

    @MainActor
    func testMetadataSyncEqualTimestampConflictsConvergeDeterministically()
        async throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let fingerprint = String(repeating: "d", count: 64)

        func record(tags: [String]) -> DocumentRecord {
            let subsecondOffset = tags == ["Zulu"] ? 0.8 : 0.2
            return DocumentRecord(
                displayName: tags.joined(separator: "-"),
                fileName: "\(tags.joined()).pdf",
                importedAt: modifiedAt,
                modifiedAt: modifiedAt.addingTimeInterval(
                    subsecondOffset
                ),
                profile: textProfile(pageCount: 2),
                tags: tags,
                contentFingerprint: fingerprint
            )
        }

        func apply(
            _ result: PDFMetadataSyncResult,
            to record: inout DocumentRecord
        ) {
            guard let update = result.updates.first else { return }
            record.tags = update.tags
            record.modifiedAt = max(record.modifiedAt, update.updatedAt)
        }

        func converge(
            firstTags: [String],
            secondTags: [String]
        ) async throws -> ([String], [String]) {
            let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
            let firstShadow = TestMetadataKeyValueStore(
                isCloudBacked: false
            )
            let secondShadow = TestMetadataKeyValueStore(
                isCloudBacked: false
            )
            var firstRecord = record(tags: firstTags)
            var secondRecord = record(tags: secondTags)

            _ = try await PDFMetadataSyncService(
                cloudStore: cloud,
                shadowStore: firstShadow,
                now: { modifiedAt.addingTimeInterval(10) }
            ).synchronize(records: [firstRecord])

            let secondResult = try await PDFMetadataSyncService(
                cloudStore: cloud,
                shadowStore: secondShadow,
                now: { modifiedAt.addingTimeInterval(20) }
            ).synchronize(records: [secondRecord])
            apply(secondResult, to: &secondRecord)

            let firstResult = try await PDFMetadataSyncService(
                cloudStore: cloud,
                shadowStore: firstShadow,
                now: { modifiedAt.addingTimeInterval(30) }
            ).synchronize(records: [firstRecord])
            apply(firstResult, to: &firstRecord)

            let stableResult = try await PDFMetadataSyncService(
                cloudStore: cloud,
                shadowStore: secondShadow,
                now: { modifiedAt.addingTimeInterval(40) }
            ).synchronize(records: [secondRecord])
            XCTAssertTrue(stableResult.updates.isEmpty)
            return (firstRecord.tags, secondRecord.tags)
        }

        let alphaFirst = try await converge(
            firstTags: ["Alpha"],
            secondTags: ["Zulu"]
        )
        let zuluFirst = try await converge(
            firstTags: ["Zulu"],
            secondTags: ["Alpha"]
        )

        XCTAssertEqual(alphaFirst.0, ["Zulu"])
        XCTAssertEqual(alphaFirst.1, ["Zulu"])
        XCTAssertEqual(zuluFirst.0, ["Zulu"])
        XCTAssertEqual(zuluFirst.1, ["Zulu"])
    }

    func testMetadataSyncLocalStateMatchesPersistedDatePrecision() {
        let persistedDate = Date(
            timeIntervalSince1970: 1_800_000_000
        )
        var resident = DocumentRecord(
            displayName: "Resident",
            fileName: "resident.pdf",
            importedAt: persistedDate,
            modifiedAt: persistedDate.addingTimeInterval(0.8),
            profile: textProfile(pageCount: 2),
            tags: ["Legal"],
            bookmarkedPages: [1],
            lastPageIndex: 1,
            lastViewedAt: persistedDate.addingTimeInterval(0.9),
            contentFingerprint: String(repeating: "e", count: 64)
        )
        var persisted = resident
        persisted.modifiedAt = persistedDate
        persisted.lastViewedAt = persistedDate
        let expected = PDFMetadataSyncLocalState(persisted)

        XCTAssertTrue(
            expected.matchesPersistenceRepresentation(of: resident)
        )

        resident.tags = ["Changed"]
        XCTAssertFalse(
            expected.matchesPersistenceRepresentation(of: resident)
        )
    }

    @MainActor
    func testMetadataSyncConflictRetryPreservesFieldTimestamps()
        async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let fingerprint = String(repeating: "f", count: 64)
        let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
        let shadowA = TestMetadataKeyValueStore(isCloudBacked: false)
        let shadowB = TestMetadataKeyValueStore(isCloudBacked: false)
        let serviceA = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowA,
            now: { base.addingTimeInterval(10) }
        )
        var deviceA = DocumentRecord(
            displayName: "Device A",
            fileName: "a.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(1),
            profile: textProfile(pageCount: 2),
            tags: ["Alpha"],
            contentFingerprint: fingerprint
        )
        var deviceB = DocumentRecord(
            displayName: "Device B",
            fileName: "b.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(2),
            profile: textProfile(pageCount: 2),
            tags: ["Beta"],
            contentFingerprint: fingerprint
        )

        _ = try await serviceA.synchronize(records: [deviceA])
        let serviceB = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowB,
            now: { base.addingTimeInterval(10) }
        )
        _ = try await serviceB.synchronize(records: [deviceB])
        deviceB.lastPageIndex = 1
        deviceB.lastViewedAt = base.addingTimeInterval(5)
        _ = try await serviceB.synchronize(records: [deviceB])

        let preparation = try await serviceA.prepareSynchronization(
            records: [deviceA]
        )
        let appliedUpdate = try XCTUnwrap(preparation.updates.first)
        deviceA.lastPageIndex = appliedUpdate.lastPageIndex
        deviceA.lastViewedAt = appliedUpdate.lastViewedAt
        deviceA.bookmarkedPages = appliedUpdate.bookmarkedPages
        deviceA.workflowStatus = appliedUpdate.workflowStatus
        deviceA.isPinned = appliedUpdate.isPinned
        deviceA.tags = appliedUpdate.tags
        deviceA.completedActions = appliedUpdate.completedActions
        deviceA.deliveryReceipt = appliedUpdate.deliveryReceipt
        deviceA.modifiedAt = max(
            deviceA.modifiedAt,
            appliedUpdate.updatedAt
        )
        try serviceA.checkpointAppliedMetadata(preparation)

        let shadowC = TestMetadataKeyValueStore(
            isCloudBacked: false
        )
        shadowC.set(
            cloud.data(
                forKey: PDFMetadataSyncService.cloudStorageKey
            ),
            forKey: "paperpath.metadata.shadow.v1"
        )
        let deviceC = DocumentRecord(
            displayName: "Device C",
            fileName: "c.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(3),
            profile: textProfile(pageCount: 2),
            tags: ["Gamma"],
            contentFingerprint: fingerprint
        )
        _ = try await PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadowC,
            now: { base.addingTimeInterval(10) }
        ).synchronize(records: [deviceC])

        XCTAssertThrowsError(try serviceA.commit(preparation)) { error in
            guard case PDFMetadataSyncCommitError.remoteStateChanged = error
            else {
                XCTFail("Unexpected commit error: \(error)")
                return
            }
        }

        let retry = try await serviceA.prepareSynchronization(
            records: [deviceA]
        )
        XCTAssertEqual(retry.updates.first?.tags, ["Gamma"])
        XCTAssertEqual(retry.updates.first?.lastPageIndex, 1)
    }

    @MainActor
    func testMetadataSyncSeparatesChangedWorkingCopies() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceFingerprint = String(repeating: "a", count: 64)
        let firstContent = String(repeating: "b", count: 64)
        let secondContent = String(repeating: "c", count: 64)
        let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
        let first = DocumentRecord(
            displayName: "Original",
            fileName: "first.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(1),
            profile: textProfile(pageCount: 2),
            tags: ["Signed"],
            sourceImportedFingerprint: sourceFingerprint,
            contentFingerprint: firstContent
        )
        let second = DocumentRecord(
            displayName: "Edited",
            fileName: "second.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(2),
            profile: textProfile(pageCount: 3),
            sourceImportedFingerprint: sourceFingerprint,
            contentFingerprint: secondContent
        )

        _ = try await PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: TestMetadataKeyValueStore(
                isCloudBacked: false
            ),
            now: { base.addingTimeInterval(10) }
        ).synchronize(records: [first])
        let result = try await PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: TestMetadataKeyValueStore(
                isCloudBacked: false
            ),
            now: { base.addingTimeInterval(20) }
        ).synchronize(records: [second])

        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(result.cloudEntryCount, 2)
    }

    @MainActor
    func testMetadataSyncLargeLibraryKeepsMainActorResponsive()
        async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = textProfile(pageCount: 2)
        let records = (0..<10_000).map { index in
            DocumentRecord(
                displayName: "Document \(index)",
                fileName: "\(index).pdf",
                importedAt: base,
                modifiedAt: base.addingTimeInterval(
                    TimeInterval(index)
                ),
                profile: profile,
                tags: ["Batch \(index % 8)"],
                contentFingerprint: String(
                    format: "%064llx",
                    UInt64(index + 1)
                )
            )
        }
        let service = PDFMetadataSyncService(
            cloudStore: TestMetadataKeyValueStore(
                isCloudBacked: true
            ),
            shadowStore: TestMetadataKeyValueStore(
                isCloudBacked: false
            ),
            now: { base.addingTimeInterval(20_000) }
        )
        var heartbeatCount = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                heartbeatCount += 1
                await Task.yield()
            }
        }
        await Task.yield()
        let countBeforeSync = heartbeatCount

        let result = try await service.synchronize(records: records)

        heartbeat.cancel()
        _ = await heartbeat.result
        XCTAssertGreaterThan(
            heartbeatCount - countBeforeSync,
            0,
            "Metadata preparation monopolized the main actor"
        )
        XCTAssertEqual(result.eligibleDocumentCount, records.count)
        XCTAssertEqual(result.cloudEntryCount, 128)
    }

    @MainActor
    func testCancelledMetadataSyncDoesNotCommitPayload() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = textProfile(pageCount: 2)
        let records = (0..<2_000).map { index in
            DocumentRecord(
                displayName: "Document \(index)",
                fileName: "\(index).pdf",
                importedAt: base,
                modifiedAt: base,
                profile: profile,
                contentFingerprint: String(
                    format: "%064llx",
                    UInt64(index + 1)
                )
            )
        }
        let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
        let shadow = TestMetadataKeyValueStore(isCloudBacked: false)
        let service = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadow,
            now: { base.addingTimeInterval(1) }
        )
        let task = Task { @MainActor in
            try await service.synchronize(records: records)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled metadata sync committed a payload")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertTrue(cloud.storage.isEmpty)
        XCTAssertTrue(shadow.storage.isEmpty)
    }

    @MainActor
    func testMetadataSyncPreparationDoesNotCommitBeforeLocalApply()
        async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
        let shadow = TestMetadataKeyValueStore(isCloudBacked: false)
        let service = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadow,
            now: { base.addingTimeInterval(10) }
        )
        let record = DocumentRecord(
            displayName: "Prepared",
            fileName: "prepared.pdf",
            importedAt: base,
            modifiedAt: base.addingTimeInterval(1),
            profile: textProfile(pageCount: 1),
            tags: ["Local"],
            contentFingerprint: String(repeating: "a", count: 64)
        )

        let preparation = try await service.prepareSynchronization(
            records: [record]
        )

        XCTAssertTrue(cloud.storage.isEmpty)
        XCTAssertTrue(shadow.storage.isEmpty)
        let result = try service.commit(preparation)
        XCTAssertEqual(result.eligibleDocumentCount, 1)
        XCTAssertFalse(cloud.storage.isEmpty)
        XCTAssertFalse(shadow.storage.isEmpty)
    }

    func testMetadataSyncBatchConflictDoesNotPartiallyCommit()
        async throws {
        let firstSource = temporaryDirectory
            .appendingPathComponent("metadata-first.pdf")
        let secondSource = temporaryDirectory
            .appendingPathComponent("metadata-second.pdf")
        try makePDF(at: firstSource, pages: ["First"])
        try makePDF(at: secondSource, pages: ["Second"])
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("MetadataBatchStore")
        )
        let first = try await store.importPDF(from: firstSource)
        let second = try await store.importPDF(from: secondSource)
        let updateDate = Date().addingTimeInterval(60)
        let firstUpdate = PDFMetadataSyncUpdate(
            recordID: first.id,
            fingerprint: try XCTUnwrap(first.contentFingerprint),
            expectedLocalState: PDFMetadataSyncLocalState(first),
            lastPageIndex: 0,
            lastViewedAt: updateDate,
            bookmarkedPages: [],
            workflowStatus: .ready,
            isPinned: false,
            tags: ["Remote"],
            completedActions: [],
            deliveryReceipt: nil,
            updatedAt: updateDate
        )
        let conflictingUpdate = PDFMetadataSyncUpdate(
            recordID: second.id,
            fingerprint: String(repeating: "f", count: 64),
            expectedLocalState: PDFMetadataSyncLocalState(second),
            lastPageIndex: 0,
            lastViewedAt: updateDate,
            bookmarkedPages: [],
            workflowStatus: .ready,
            isPinned: false,
            tags: ["Remote"],
            completedActions: [],
            deliveryReceipt: nil,
            updatedAt: updateDate
        )

        do {
            _ = try await store.applyMetadataSync(
                [firstUpdate, conflictingUpdate]
            )
            XCTFail("A conflicting sync batch should not commit")
        } catch PDFMetadataSyncApplyError.localStateChanged {
        } catch {
            XCTFail("Unexpected metadata conflict error: \(error)")
        }

        let reopened = try await store.load()
        XCTAssertEqual(
            reopened.first(where: { $0.id == first.id })?.tags,
            []
        )
    }

    func testMetadataSyncRejectsConcurrentLocalMetadataEdit()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("metadata-concurrent.pdf")
        try makePDF(at: source, pages: ["Concurrent metadata"])
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("MetadataConcurrentStore")
        )
        let record = try await store.importPDF(from: source)
        let updateDate = Date().addingTimeInterval(300)
        let preparedUpdate = PDFMetadataSyncUpdate(
            recordID: record.id,
            fingerprint: try XCTUnwrap(record.contentFingerprint),
            expectedLocalState: PDFMetadataSyncLocalState(record),
            lastPageIndex: 0,
            lastViewedAt: updateDate,
            bookmarkedPages: [],
            workflowStatus: .ready,
            isPinned: false,
            tags: ["Remote"],
            completedActions: [],
            deliveryReceipt: nil,
            updatedAt: updateDate
        )
        _ = try await store.updateTags(
            record,
            tags: ["Local"],
            expectedTags: record.tags
        )

        do {
            _ = try await store.applyMetadataSync([preparedUpdate])
            XCTFail("A prepared update must not overwrite a local edit")
        } catch PDFMetadataSyncApplyError.localStateChanged {
        } catch {
            XCTFail("Unexpected metadata conflict error: \(error)")
        }

        let reopened = try await store.load()
        XCTAssertEqual(
            reopened.first(where: { $0.id == record.id })?.tags,
            ["Local"]
        )
    }

    @MainActor
    func testMetadataSyncCommitRejectsChangedCloudBaseline()
        async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let cloud = TestMetadataKeyValueStore(isCloudBacked: true)
        let shadow = TestMetadataKeyValueStore(isCloudBacked: false)
        let service = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadow,
            now: { base.addingTimeInterval(10) }
        )
        let record = DocumentRecord(
            displayName: "Concurrent cloud",
            fileName: "concurrent-cloud.pdf",
            importedAt: base,
            modifiedAt: base,
            profile: textProfile(pageCount: 1),
            contentFingerprint: String(repeating: "c", count: 64)
        )
        let preparation = try await service.prepareSynchronization(
            records: [record]
        )
        let concurrentCloudData = Data("new remote value".utf8)
        cloud.set(
            concurrentCloudData,
            forKey: PDFMetadataSyncService.cloudStorageKey
        )

        XCTAssertThrowsError(try service.commit(preparation)) { error in
            guard case PDFMetadataSyncCommitError.remoteStateChanged = error
            else {
                XCTFail("Unexpected commit error: \(error)")
                return
            }
        }
        XCTAssertEqual(
            cloud.data(forKey: PDFMetadataSyncService.cloudStorageKey),
            concurrentCloudData
        )
        XCTAssertTrue(shadow.storage.isEmpty)
    }

    @MainActor
    func testAppLockCoversMultipleScenesDelayAndProtectedData()
        async throws {
        let suiteName = "PaperPath-AppLock-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let clock = TestUptimeClock(value: 100)
        let controller = AppLockController(
            defaults: defaults,
            authenticationOverride: { _ in true },
            uptimeProvider: { clock.read() }
        )
        let enabled = await controller.enable()
        XCTAssertTrue(enabled)
        controller.setDelay(.oneMinute)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let firstScene = UUID()
        let secondScene = UUID()
        XCTAssertTrue(
            controller.sceneDidBecomeActive(firstScene, at: base)
        )
        XCTAssertFalse(
            controller.sceneDidBecomeActive(secondScene, at: base)
        )
        XCTAssertTrue(controller.hasActiveScenes)
        XCTAssertFalse(
            controller.sceneDidEnterBackground(firstScene, at: base)
        )
        XCTAssertTrue(controller.hasActiveScenes)
        XCTAssertFalse(controller.isLocked)

        clock.advance(by: 90)
        XCTAssertTrue(
            controller.sceneDidEnterBackground(secondScene, at: base)
        )
        XCTAssertFalse(controller.hasActiveScenes)
        XCTAssertFalse(controller.isLocked)

        clock.advance(by: 30)
        XCTAssertTrue(
            controller.sceneDidBecomeActive(
                firstScene,
                at: base.addingTimeInterval(30)
            )
        )
        XCTAssertTrue(controller.hasActiveScenes)
        XCTAssertFalse(controller.isLocked)
        XCTAssertTrue(
            controller.sceneDidEnterBackground(
                firstScene,
                at: base.addingTimeInterval(30)
            )
        )

        clock.advance(by: 61)
        XCTAssertTrue(
            controller.sceneDidBecomeActive(
                firstScene,
                at: base.addingTimeInterval(91)
            )
        )
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.lockGeneration, 1)

        let unlocked = await controller.unlock()
        XCTAssertTrue(unlocked)
        XCTAssertFalse(controller.isLocked)
        controller.setDelay(.fifteenMinutes)
        controller.protectedDataWillBecomeUnavailable()
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.lockGeneration, 2)
    }

    @MainActor
    func testAppLock_repeatedSceneChurnKeepsOverlayDismissed_BitsUT()
        async throws {
        let suiteName = "PaperPath-AppLock-Churn-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let clock = TestUptimeClock(value: 1_000)
        let controller = AppLockController(
            defaults: defaults,
            authenticationOverride: { _ in true },
            uptimeProvider: { clock.read() }
        )
        let enabled = await controller.enable()
        XCTAssertTrue(enabled)
        controller.setDelay(.fiveMinutes)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<50 {
            let primaryScene = UUID()
            let secondaryScene = UUID()
            let date = base.addingTimeInterval(Double(index))

            XCTAssertTrue(
                controller.sceneDidBecomeActive(
                    primaryScene,
                    at: date
                )
            )
            XCTAssertFalse(
                controller.sceneDidBecomeActive(
                    secondaryScene,
                    at: date
                )
            )
            XCTAssertFalse(
                controller.sceneDidEnterBackground(
                    primaryScene,
                    at: date
                )
            )
            XCTAssertTrue(controller.hasActiveScenes)
            XCTAssertFalse(controller.isLocked)
            XCTAssertTrue(
                controller.sceneDidDisconnect(
                    secondaryScene,
                    at: date
                )
            )
            XCTAssertFalse(controller.hasActiveScenes)
            XCTAssertFalse(controller.isLocked)
        }
    }

    func testLibraryForegroundActivityOnlyBlocksOwningScene_BitsUT() {
        XCTAssertFalse(
            LibraryForegroundActivity(
                isFileImportActive: false,
                isPhotoPreparationActive: false,
                isScanCreationActive: false
            ).blocksInteraction
        )

        for activity in [
            LibraryForegroundActivity(
                isFileImportActive: true,
                isPhotoPreparationActive: false,
                isScanCreationActive: false
            ),
            LibraryForegroundActivity(
                isFileImportActive: false,
                isPhotoPreparationActive: true,
                isScanCreationActive: false
            ),
            LibraryForegroundActivity(
                isFileImportActive: false,
                isPhotoPreparationActive: false,
                isScanCreationActive: true
            )
        ] {
            XCTAssertTrue(activity.blocksInteraction)
        }
    }

    func testExternalDocumentHandoffQueuePreservesSceneOwnership_BitsUT() {
        let firstScene = UUID()
        let secondScene = UUID()
        let firstRecord = UUID()
        let secondRecord = UUID()
        let unscopedRecord = UUID()
        var queue = ExternalDocumentHandoffQueue()

        queue.enqueue(
            recordID: firstRecord,
            targetSceneID: firstScene
        )
        queue.enqueue(
            recordID: secondRecord,
            targetSceneID: secondScene
        )
        queue.enqueue(
            recordID: unscopedRecord,
            targetSceneID: nil
        )
        queue.enqueue(
            recordID: firstRecord,
            targetSceneID: secondScene
        )

        XCTAssertEqual(queue.entries.count, 3)
        XCTAssertEqual(queue.recordID(for: firstScene), firstRecord)
        XCTAssertEqual(queue.recordID(for: secondScene), secondRecord)

        queue.clear(recordID: firstRecord)
        XCTAssertEqual(
            queue.recordID(for: firstScene),
            unscopedRecord
        )
        XCTAssertEqual(queue.recordID(for: secondScene), secondRecord)

        queue.releaseTarget(for: secondScene)
        XCTAssertEqual(queue.recordID(for: firstScene), secondRecord)
        XCTAssertEqual(queue.recordID(for: secondScene), secondRecord)
    }

    func testSourceLocationDetectsExternalChange() async throws {
        let source = temporaryDirectory
            .appendingPathComponent("source-location.pdf")
        try makePDF(at: source, pages: ["Original source"])
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("SourceLocationStore")
        )
        let record = try await store.importPDF(from: source)

        var snapshot = try await store.sourceLocation(for: record)
        XCTAssertEqual(snapshot.status, .current)
        XCTAssertEqual(snapshot.name, "source-location.pdf")

        try makePDF(at: source, pages: ["Changed outside PaperPath"])
        snapshot = try await store.sourceLocation(for: record)
        XCTAssertEqual(snapshot.status, .changed)
    }

    func testEditingPrivateCopyNeverChangesOriginal() async throws {
        let source = temporaryDirectory
            .appendingPathComponent("writeback-source.pdf")
        try makePDF(at: source, pages: ["Original source"])
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("WritebackStore")
        )
        let record = try await store.importPDF(from: source)
        let workingURL = await store.url(for: record)
        try makePDF(
            at: workingURL,
            pages: ["Edited private copy", "Second page"]
        )

        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let workingDocument = try XCTUnwrap(
            PDFDocument(url: workingURL)
        )

        XCTAssertEqual(sourceDocument.pageCount, 1)
        XCTAssertTrue(
            sourceDocument.page(at: 0)?.string?
                .contains("Original source") == true
        )
        XCTAssertEqual(workingDocument.pageCount, 2)
        XCTAssertTrue(
            workingDocument.page(at: 0)?.string?
                .contains("Edited private copy") == true
        )
        XCTAssertNil(record.sourceWritebackAt)
        let finalSnapshot = try await store.sourceLocation(
            for: record
        )
        XCTAssertEqual(
            finalSnapshot.status,
            .current
        )
    }

    @MainActor
    func testFilesExportUsesReadableNameAndCleansTemporaryCopy() async throws {
        let source = temporaryDirectory
            .appendingPathComponent("Client Review.pdf")
        try makePDF(at: source, pages: ["Readable export"])
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("FilesExportStore")
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let importedRecord = await model.importPDF(from: source)
        let imported = try XCTUnwrap(importedRecord)

        let exportResult = await model.makeFilesExportCopy(
            recordID: imported.id
        )
        let exportURL = try XCTUnwrap(
            exportResult,
            "Files export returned no URL"
        )
        let exportDirectory = exportURL.deletingLastPathComponent()

        XCTAssertEqual(exportURL.lastPathComponent, "Client Review.pdf")
        XCTAssertTrue(
            exportDirectory.lastPathComponent
                .hasPrefix("PaperPath-FilesExport-")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        XCTAssertEqual(
            try Data(contentsOf: exportURL),
            try Data(contentsOf: XCTUnwrap(model.url(for: imported.id)))
        )

        await model.discardFilesExportCopy(at: exportURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: exportDirectory.path)
        )

        let interruptedResult = await model.makeFilesExportCopy(
            recordID: imported.id
        )
        let interruptedURL = try XCTUnwrap(
            interruptedResult,
            "Files export returned no URL"
        )
        let interruptedDirectory = interruptedURL.deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: interruptedURL.path)
        )

        let relaunchedModel = PaperPathModel(store: store)
        await relaunchedModel.bootstrap()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: interruptedDirectory.path
            )
        )
    }

    func testSignatureStorePersistsAndRemovesProtectedData() async throws {
        let root = temporaryDirectory.appendingPathComponent("SignatureStore")
        let store = SignatureStore(rootURL: root)
        let signature = PDFTestFixtureFactory.makeSignaturePNG(seed: 1)

        try await store.save(signature)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, signature)

        try await store.remove()
        let removed = try await store.load()
        XCTAssertNil(removed)
    }

    func testPrivateStoresAreExcludedFromSystemBackup() async throws {
        let documentRoot = temporaryDirectory
            .appendingPathComponent("NoBackupDocuments")
        let documentStore = DocumentStore(rootURL: documentRoot)
        _ = try await documentStore.load()

        let signatureRoot = temporaryDirectory
            .appendingPathComponent("NoBackupSignature")
        let signatureStore = SignatureStore(rootURL: signatureRoot)
        try await signatureStore.save(
            PDFTestFixtureFactory.makeSignaturePNG(seed: 2)
        )

        let documentValues = try documentRoot.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        let signatureValues = try signatureRoot.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(documentValues.isExcludedFromBackup, true)
        XCTAssertEqual(signatureValues.isExcludedFromBackup, true)
    }

    func testSignatureStoreRejectsOversizedDrawingData() async throws {
        let root = temporaryDirectory
            .appendingPathComponent("BoundedSignature")
        let store = SignatureStore(rootURL: root)

        do {
            try await store.save(Data(count: 5 * 1_024 * 1_024 + 1))
            XCTFail("Expected oversized signature data to be rejected")
        } catch PaperPathError.storageFailure(_) {
            let saved = try await store.load()
            XCTAssertNil(saved)
        }
    }

    func testSignatureStoreRejectsTruncatedImageAndPreservesSelection()
        async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "TruncatedSignature"
        )
        let store = SignatureStore(rootURL: root)
        let valid = PDFTestFixtureFactory.makeSignaturePNG(seed: 7)
        let original = try await store.add(valid)
        let idat = try XCTUnwrap(valid.range(of: Data("IDAT".utf8)))
        let truncated = Data(valid.prefix(idat.upperBound + 4))
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(truncated as CFData, nil)
        )
        XCTAssertNotNil(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
            "The fixture must preserve readable image dimensions."
        )

        do {
            _ = try await store.add(truncated)
            XCTFail("Incomplete signature pixels must be rejected.")
        } catch PaperPathError.storageFailure {
            // 拒绝损坏图片时，之前保存和选中的签名必须完整保留。
        }
        let reloaded = try await store.loadLibrary()
        XCTAssertEqual(reloaded, original)
        let selected = try await store.load()
        XCTAssertEqual(selected, valid)
    }

    func testSignatureStoreRepairsTruncatedEntryAndRetainsValidSignature()
        async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "RepairTruncatedSignature"
        )
        let store = SignatureStore(rootURL: root)
        let valid = PDFTestFixtureFactory.makeSignaturePNG(seed: 8)
        let saved = try await store.add(valid)
        let idat = try XCTUnwrap(valid.range(of: Data("IDAT".utf8)))
        let damaged = SavedSignature(
            data: Data(valid.prefix(idat.upperBound + 4))
        )
        let library = SavedSignatureLibrary(
            selectedID: damaged.id,
            entries: [damaged] + saved.entries
        )
        let libraryURL = root.appendingPathComponent(
            "saved-signatures.json"
        )
        try JSONEncoder().encode(library).write(
            to: libraryURL,
            options: [.atomic, .completeFileProtection]
        )

        let repaired = try await store.loadLibrary()
        XCTAssertEqual(repaired, saved)
        let persisted = try JSONDecoder().decode(
            SavedSignatureLibrary.self,
            from: Data(contentsOf: libraryURL)
        )
        XCTAssertEqual(persisted, saved)
    }

    func testStoreAppliesCompleteFileProtection() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("File protection attributes require a physical device.")
#else
        let source = temporaryDirectory.appendingPathComponent("protected.pdf")
        try makePDF(at: source, pages: ["Protected local content"])
        let storeRoot = temporaryDirectory.appendingPathComponent("ProtectedStore")
        let store = DocumentStore(rootURL: storeRoot)
        let record = try await store.importPDF(from: source)
        let index = try PDFTextIndexService().extractNativeText(from: source)
        let brief = DocumentUnderstandingService().analyze(
            index: index,
            profile: record.profile
        )
        _ = try await store.saveAnalysis(
            record,
            brief: brief,
            textIndex: index
        )

        let privateURL = await store.url(for: record)
        try PDFMutationService().addStamp(.draft, toPageAt: 0, in: privateURL)
        let textExport = temporaryDirectory
            .appendingPathComponent("protected-export.txt")
        _ = try PDFOutputService().exportText(
            sourceURL: privateURL,
            destination: textExport,
            textIndex: index,
            title: "Protected export",
            format: .plainText
        )

        let urls = [
            privateURL,
            storeRoot.appendingPathComponent("library.json"),
            storeRoot
                .appendingPathComponent("TextIndex")
                .appendingPathComponent("\(record.id.uuidString).json"),
            textExport
        ]
        for url in urls {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            XCTAssertEqual(
                attributes[.protectionKey] as? FileProtectionType,
                .complete
            )
        }
#endif
    }

    func testCombineAndExtractPreservePageOrder() throws {
        let first = temporaryDirectory.appendingPathComponent("first.pdf")
        let second = temporaryDirectory.appendingPathComponent("second.pdf")
        let combined = temporaryDirectory.appendingPathComponent("combined.pdf")
        let extracted = temporaryDirectory.appendingPathComponent("extracted.pdf")
        try makePDF(at: first, pages: ["Alpha"])
        try makePDF(at: second, pages: ["Beta", "Gamma"])

        let service = PDFCompositionService()
        try service.combine(urls: [first, second], to: combined)
        let combinedDocument = try XCTUnwrap(PDFDocument(url: combined))
        XCTAssertEqual(combinedDocument.pageCount, 3)
        XCTAssertTrue(combinedDocument.page(at: 0)?.string?.contains("Alpha") == true)
        XCTAssertTrue(combinedDocument.page(at: 1)?.string?.contains("Beta") == true)

        try service.extractPages(
            from: combined,
            indices: [2, 0],
            to: extracted
        )
        let extractedDocument = try XCTUnwrap(PDFDocument(url: extracted))
        XCTAssertEqual(extractedDocument.pageCount, 2)
        XCTAssertTrue(extractedDocument.page(at: 0)?.string?.contains("Alpha") == true)
        XCTAssertTrue(extractedDocument.page(at: 1)?.string?.contains("Gamma") == true)
    }

    func testSearchableCopyContainsVisionTextLayer() throws {
        let source = temporaryDirectory.appendingPathComponent("scan-source.pdf")
        let destination = temporaryDirectory.appendingPathComponent("searchable.pdf")
        try makePDF(at: source, pages: [""])
        let result = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "Private searchable phrase",
                    confidence: 0.98,
                    blocks: [
                        OCRTextBlock(
                            text: "Private searchable phrase",
                            confidence: 0.98,
                            normalizedX: 0.1,
                            normalizedY: 0.7,
                            normalizedWidth: 0.5,
                            normalizedHeight: 0.05
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

        let searchable = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(searchable.pageCount, 1)
        XCTAssertTrue(
            searchable.page(at: 0)?.string?
                .contains("Private searchable phrase") == true
        )
    }

    func testOCRAppliesLanguageConfigurationAndKeepsLegacyResults()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("multilingual-ocr.pdf")
        try makePDF(
            at: source,
            pages: [
                """
                Invoice total 1280
                Factura total 1280
                PaperPath
                """
            ]
        )
        let configuration = OCRRecognitionConfiguration(
            languageMode: .selected,
            languageIdentifiers: [
                OCRRecognitionLanguage.spanish.rawValue,
                OCRRecognitionLanguage.english.rawValue
            ],
            customWords: [
                " PaperPath ",
                "paperpath",
                "Northstar"
            ]
        )

        let result = try await VisionOCRService().recognize(
            url: source,
            configuration: configuration
        )

        XCTAssertEqual(
            result.configuration.languageIdentifiers,
            ["en-US", "es-ES"]
        )
        XCTAssertEqual(
            result.configuration.customWords,
            ["PaperPath", "Northstar"]
        )
        let recognized = result.text.lowercased()
        XCTAssertTrue(recognized.contains("invoice"))
        XCTAssertTrue(recognized.contains("factura"))
        XCTAssertTrue(recognized.contains("paperpath"))

        let legacy = try JSONDecoder().decode(
            OCRResult.self,
            from: Data(#"{"pages":[]}"#.utf8)
        )
        XCTAssertEqual(legacy.configuration, .automatic)

        do {
            _ = try await VisionOCRService().recognize(
                url: source,
                configuration: OCRRecognitionConfiguration(
                    languageMode: .selected,
                    languageIdentifiers: ["xx-Invalid"],
                    customWords: []
                )
            )
            XCTFail("Unsupported language should be rejected")
        } catch let error as PaperPathError {
            guard case .insufficientSelection = error else {
                return XCTFail(
                    "Unexpected OCR error: \(error.localizedDescription)"
                )
            }
        }
    }

    func testOCRCancellationAfterLastCheckpointRemainsResumable()
        async throws {
        let source = temporaryDirectory.appendingPathComponent(
            "checkpoint-cancellation.pdf"
        )
        let checkpointURL = temporaryDirectory.appendingPathComponent(
            "last-page-checkpoint.json"
        )
        try makePDF(at: source, pages: ["PaperPath invoice total 1280"])
        let identity = OCRCheckpointIdentity(
            recordID: UUID(),
            revisionID: UUID(),
            pageCount: 1,
            configuration: .automatic
        )

        do {
            _ = try await VisionOCRService().recognize(
                url: source,
                onPageCompleted: { page in
                    try JSONEncoder().encode(page).write(
                        to: checkpointURL,
                        options: .atomic
                    )
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
            XCTFail("Cancelling at the last checkpoint must not return success.")
        } catch is CancellationError {
            // 已完成的检查点保留；取消不得伪装为整个识别任务成功。
        }

        let savedPage = try JSONDecoder().decode(
            OCRPageResult.self,
            from: Data(contentsOf: checkpointURL)
        )
        XCTAssertEqual(savedPage.pageIndex, 0)
        XCTAssertTrue(savedPage.text.lowercased().contains("invoice"))
        let resumed = try await VisionOCRService().recognize(
            url: source,
            checkpoint: OCRCheckpoint(identity: identity, pages: [savedPage]),
            onPageCompleted: { _ in
                XCTFail("A saved page must not be recognized again.")
            }
        )
        XCTAssertEqual(resumed.pages.count, 1)
        XCTAssertEqual(resumed.pages.first?.text, savedPage.text)
    }

    func testCompressionCreatesSeparateSmallerReadablePDF() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("compressed.pdf")
        try PDFTestFixtureFactory.makeTrailingPaddedPDF(
            at: source,
            paddingBytes: 1_024 * 1_024
        )

        try PDFOutputService().compress(
            sourceURL: source,
            destination: output,
            quality: .balanced
        )

        let compressed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(compressed.pageCount, 1)
        XCTAssertLessThan(
            try XCTUnwrap(
                output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            ),
            try XCTUnwrap(
                source.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCompressionDoesNotPublishCopyLargerThanSource() throws {
        let source = temporaryDirectory
            .appendingPathComponent("optimized-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("larger-compressed.pdf")
        try makePDF(at: source, pages: ["One", "Two"])
        let sourceByteCount = try XCTUnwrap(
            source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        XCTAssertThrowsError(
            try PDFOutputService().compress(
                sourceURL: source,
                destination: output,
                quality: .balanced
            )
        ) { error in
            guard case let PaperPathError.compressionNotBeneficial(
                originalByteCount,
                candidateByteCount
            ) = error else {
                return XCTFail("Unexpected compression error: \(error)")
            }
            XCTAssertEqual(originalByteCount, Int64(sourceByteCount))
            XCTAssertGreaterThanOrEqual(
                candidateByteCount,
                originalByteCount
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCompressionEstimateIdentifiesAlreadySmallerOriginal() {
        let estimate = PDFCompressionEstimate(
            sourceByteCount: 256 * 1_024,
            estimatedByteCount: 25 * 1_024 * 1_024,
            sampledPageCount: 3
        )

        XCTAssertFalse(estimate.isBeneficial)
        XCTAssertNil(estimate.savingsPercent)
        XCTAssertFalse(estimate.formattedSourceSize.isEmpty)
        XCTAssertFalse(estimate.formattedSize.isEmpty)
    }

    func testSafeShareAuditVerifiesEveryPageAndFingerprint() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("safe-share.pdf")
        try makePDF(at: source, pages: ["Private author note", "Second page"])
        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        sourceDocument.documentAttributes = [
            PDFDocumentAttribute.authorAttribute: "Example Author",
            PDFDocumentAttribute.titleAttribute: "Private title",
            PDFDocumentAttribute.keywordsAttribute: ["private", "draft"]
        ]
        let page = try XCTUnwrap(sourceDocument.page(at: 0))
        page.addAnnotation(
            PDFAnnotation(
                bounds: CGRect(x: 48, y: 300, width: 220, height: 42),
                forType: .freeText,
                withProperties: nil
            )
        )
        XCTAssertTrue(sourceDocument.write(to: source))

        try PDFOutputService().safeShare(
            sourceURL: source,
            destination: output
        )
        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: source,
            outputURL: output,
            operation: .safeShare
        )

        XCTAssertTrue(receipt.isVerified)
        XCTAssertEqual(receipt.outputPageCount, 2)
        XCTAssertEqual(receipt.renderedPageCount, 2)
        XCTAssertTrue(receipt.unexpectedBlankPageIndices.isEmpty)
        XCTAssertEqual(receipt.annotationCount, 0)
        XCTAssertEqual(receipt.textCharacterCount, 0)
        XCTAssertEqual(receipt.personalMetadataEntryCount, 0)
        XCTAssertEqual(receipt.sha256.count, 64)
        XCTAssertNotNil(receipt.changeReview)
        XCTAssertEqual(
            receipt.changeReview?.geometryChangedPageCount,
            0
        )
    }

    func testCompareVersionsIdenticalPDFHasNoChanges() throws {
        let source = temporaryDirectory
            .appendingPathComponent("compare-source.pdf")
        try makePDF(at: source, pages: ["First page", "Second page"])

        let review = try PDFDeliveryAuditService().compare(
            sourceURL: source,
            revisedURL: source
        )

        XCTAssertTrue(review.isIdentical)
        XCTAssertEqual(review.comparedPageCount, 2)
        XCTAssertEqual(review.visibleChangedPageCount, 0)
        XCTAssertEqual(review.textChangedPageCount, 0)
        XCTAssertTrue(review.changes.isEmpty)
    }

    func testCompareVersionsFindsTextAndVisiblePageChange() throws {
        let source = temporaryDirectory
            .appendingPathComponent("compare-base.pdf")
        let revised = temporaryDirectory
            .appendingPathComponent("compare-revised.pdf")
        try makePDF(
            at: source,
            pages: ["Stable first page", "Contract amount 100"]
        )
        try makePDF(
            at: revised,
            pages: ["Stable first page", "Contract amount 250"]
        )

        let review = try PDFDeliveryAuditService().compare(
            sourceURL: source,
            revisedURL: revised
        )

        XCTAssertFalse(review.isIdentical)
        XCTAssertEqual(review.sourcePageCount, 2)
        XCTAssertEqual(review.revisedPageCount, 2)
        XCTAssertEqual(review.textChanges.map(\.pageIndex), [1])
        XCTAssertEqual(
            review.visibleChanges.map(\.pageIndex),
            [1]
        )
        XCTAssertEqual(review.geometryChangedPageCount, 0)
    }

    func testCompareVersionsReportsAddedPage() throws {
        let source = temporaryDirectory
            .appendingPathComponent("compare-one-page.pdf")
        let revised = temporaryDirectory
            .appendingPathComponent("compare-two-pages.pdf")
        try makePDF(at: source, pages: ["Stable first page"])
        try makePDF(
            at: revised,
            pages: ["Stable first page", "New appendix"]
        )

        let review = try PDFDeliveryAuditService().compare(
            sourceURL: source,
            revisedURL: revised
        )
        let added = try XCTUnwrap(
            review.changes.first { !$0.sourceExists }
        )

        XCTAssertEqual(review.addedPageCount, 1)
        XCTAssertEqual(added.pageIndex, 1)
        XCTAssertTrue(added.revisedExists)
        XCTAssertTrue(added.isVisibleChange)
        XCTAssertEqual(added.preferredOpenSide, .revised)
    }

    func testCompareVersionsOpensRemovedPageFromBasePDF() throws {
        let source = temporaryDirectory
            .appendingPathComponent("compare-two-page-base.pdf")
        let revised = temporaryDirectory
            .appendingPathComponent("compare-one-page-revised.pdf")
        try makePDF(
            at: source,
            pages: ["Stable first page", "Removed appendix"]
        )
        try makePDF(at: revised, pages: ["Stable first page"])

        let review = try PDFDeliveryAuditService().compare(
            sourceURL: source,
            revisedURL: revised
        )
        let removed = try XCTUnwrap(
            review.changes.first { !$0.revisedExists }
        )

        XCTAssertEqual(review.removedPageCount, 1)
        XCTAssertEqual(removed.pageIndex, 1)
        XCTAssertEqual(removed.preferredOpenSide, .source)
    }

    func testDeliveryAuditRejectsMissingOutputPage() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("partial.pdf")
        try makePDF(at: source, pages: ["First", "Second"])
        try makePDF(at: output, pages: ["First"])

        XCTAssertThrowsError(
            try PDFDeliveryAuditService().audit(
                sourceURL: source,
                outputURL: output,
                operation: .safeShare
            )
        ) { error in
            guard case PaperPathError.outputVerificationFailed(let reason)
                = error
            else {
                return XCTFail("Expected an output verification error")
            }
            XCTAssertTrue(reason.contains("Expected 2 pages"))
        }
    }

    func testPreflightFailsClosedForDamagedAndLockedPDFs()
        throws {
        let damaged = temporaryDirectory
            .appendingPathComponent("damaged.pdf")
        let damagedData = Data("not a valid PDF".utf8)
        try damagedData.write(to: damaged)

        XCTAssertThrowsError(
            try PDFDeliveryAuditService().preflight(
                sourceURL: damaged
            )
        ) { error in
            guard case PaperPathError.unreadablePDF = error else {
                return XCTFail(
                    "Expected unreadable PDF, received \(error)"
                )
            }
        }
        XCTAssertEqual(try Data(contentsOf: damaged), damagedData)

        let plain = temporaryDirectory
            .appendingPathComponent("preflight-plain.pdf")
        let locked = temporaryDirectory
            .appendingPathComponent("preflight-locked.pdf")
        try makePDF(at: plain, pages: ["Locked source"])
        try PDFOutputService().protect(
            sourceURL: plain,
            destination: locked,
            password: "local-only"
        )

        let assessment = try PDFDeliveryAuditService().preflight(
            sourceURL: locked
        )

        XCTAssertEqual(assessment.status, .blocked)
        XCTAssertEqual(assessment.items.first?.id, "locked-source")
        XCTAssertTrue(PDFDocument(url: locked)?.isLocked == true)
    }

    func testDeliveryAuditVerifiesPasswordProtection() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("protected.pdf")
        try makePDF(at: source, pages: ["Confidential"])
        try PDFOutputService().protect(
            sourceURL: source,
            destination: output,
            password: "local-only"
        )

        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: source,
            outputURL: output,
            operation: .protected,
            unlockPassword: "local-only"
        )

        XCTAssertTrue(receipt.isVerified)
        XCTAssertTrue(receipt.isEncrypted)
        XCTAssertEqual(
            receipt.checks.first { $0.id == "encryption" }?.status,
            .passed
        )
    }

    func testUnlockedPrivateCopyRemovesPasswordAndPassesAudit()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("locked-source.pdf")
        let unlocked = temporaryDirectory
            .appendingPathComponent("editable-copy.pdf")
        let plain = temporaryDirectory
            .appendingPathComponent("plain-source.pdf")
        try makePDF(at: plain, pages: ["Confidential", "Signature page"])
        try PDFMutationService().addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .text,
                name: "Recipient",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.12,
                    y: 0.28,
                    width: 0.48,
                    height: 0.08
                ),
                isRequired: true,
                isMultiline: false,
                maximumLength: 80
            ),
            in: plain
        )
        try PDFOutputService().protect(
            sourceURL: plain,
            destination: source,
            password: "local-only"
        )

        try PDFOutputService().removePassword(
            sourceURL: source,
            destination: unlocked,
            password: "local-only"
        )

        let original = try XCTUnwrap(PDFDocument(url: source))
        let editable = try XCTUnwrap(PDFDocument(url: unlocked))
        XCTAssertTrue(original.isLocked)
        XCTAssertTrue(original.isEncrypted)
        XCTAssertFalse(editable.isLocked)
        XCTAssertFalse(editable.isEncrypted)
        XCTAssertEqual(editable.pageCount, 2)
        let editableForm = try PDFFormInspectionService().inspect(
            url: unlocked
        )
        XCTAssertEqual(editableForm.fields.first?.name, "Recipient")
        XCTAssertEqual(editableForm.fields.first?.isRequired, true)

        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: source,
            outputURL: unlocked,
            operation: .unlocked,
            unlockPassword: "local-only"
        )
        XCTAssertTrue(receipt.isVerified)
        XCTAssertFalse(receipt.isEncrypted)
        XCTAssertEqual(
            receipt.checks.first { $0.id == "encryption" }?.status,
            .passed
        )
    }

    func testStorePersistsDeliveryReceipt() async throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("safe-share.pdf")
        try makePDF(at: source, pages: ["Deliverable"])
        try PDFOutputService().safeShare(
            sourceURL: source,
            destination: output
        )
        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: source,
            outputURL: output,
            operation: .safeShare
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("ReceiptStore")
        )

        let record = try await store.importPDF(
            from: output,
            preferredName: "Verified deliverable",
            deliveryReceipt: receipt
        )
        let loaded = try await store.load()

        XCTAssertEqual(record.deliveryReceipt, receipt)
        XCTAssertEqual(loaded.first?.deliveryReceipt, receipt)
    }

    func testTextExportUsesOCRIndexWhenPDFHasNoTextLayer() throws {
        let source = temporaryDirectory.appendingPathComponent("scan.pdf")
        let output = temporaryDirectory.appendingPathComponent("scan.txt")
        try makePDF(at: source, pages: [""])
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "Recognized only by Vision"
                )
            ],
            indexedAt: Date()
        )

        _ = try PDFOutputService().exportText(
            sourceURL: source,
            destination: output,
            textIndex: index,
            title: "Recognized scan",
            format: .plainText
        )

        let exported = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(exported.contains("Recognized only by Vision"))
    }

    func testExcelWorkbookPreservesPageTablesAndOCRFallback() throws {
        let source = temporaryDirectory
            .appendingPathComponent("structured-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("structured-output.xlsx")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: source) { context in
            context.beginPage()
            "Item".draw(
                at: CGPoint(x: 56, y: 80),
                withAttributes: [
                    .font: UIFont.systemFont(
                        ofSize: 15,
                        weight: .bold
                    )
                ]
            )
            "Amount".draw(
                at: CGPoint(x: 360, y: 80),
                withAttributes: [
                    .font: UIFont.systemFont(
                        ofSize: 15,
                        weight: .bold
                    )
                ]
            )
            "Design services".draw(
                at: CGPoint(x: 56, y: 122),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 15)
                ]
            )
            "1,280.50".draw(
                at: CGPoint(x: 360, y: 122),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 15)
                ]
            )

            context.beginPage()
            UIColor.systemGray5.setFill()
            context.fill(
                CGRect(x: 48, y: 72, width: 516, height: 648)
            )
        }
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 1,
                    text: "Status\tCount\nReady\t42"
                )
            ],
            indexedAt: Date()
        )

        _ = try PDFOutputService().exportText(
            sourceURL: source,
            destination: output,
            textIndex: index,
            title: "Structured report",
            format: .excelWorkbook
        )

        let package = try Data(contentsOf: output)
        func contains(_ value: String) -> Bool {
            package.range(of: Data(value.utf8)) != nil
        }
        XCTAssertTrue(
            package.starts(with: [0x50, 0x4b, 0x03, 0x04])
        )
        XCTAssertTrue(contains("xl/workbook.xml"))
        XCTAssertTrue(contains("xl/worksheets/sheet1.xml"))
        XCTAssertTrue(contains("xl/worksheets/sheet2.xml"))
        XCTAssertTrue(contains("Design services"))
        XCTAssertTrue(contains("<v>1280.50</v>"))
        XCTAssertTrue(contains("Ready"))
        XCTAssertTrue(contains("<v>42</v>"))
        XCTAssertEqual(
            PDFTextExportFormat.excelWorkbook.fileExtension,
            "xlsx"
        )
    }

    func testPowerPointExportCreatesOneSearchableSlidePerPage() throws {
        let source = temporaryDirectory
            .appendingPathComponent("presentation-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("presentation-output.pptx")
        try makePDF(
            at: source,
            pages: [
                "Quarterly delivery summary",
                ""
            ]
        )
        let index = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 1,
                    text: "Scanned approval page"
                )
            ],
            indexedAt: Date()
        )

        _ = try PDFOutputService().exportText(
            sourceURL: source,
            destination: output,
            textIndex: index,
            title: "Delivery deck",
            format: .powerPointPresentation
        )

        let package = try Data(contentsOf: output)
        func contains(_ value: String) -> Bool {
            package.range(of: Data(value.utf8)) != nil
        }
        XCTAssertTrue(
            package.starts(with: [0x50, 0x4b, 0x03, 0x04])
        )
        XCTAssertTrue(contains("ppt/presentation.xml"))
        XCTAssertTrue(contains("ppt/slides/slide1.xml"))
        XCTAssertTrue(contains("ppt/slides/slide2.xml"))
        XCTAssertTrue(contains("ppt/media/page-1.jpg"))
        XCTAssertTrue(contains("ppt/media/page-2.jpg"))
        XCTAssertTrue(contains("Quarterly delivery summary"))
        XCTAssertTrue(contains("Scanned approval page"))
        XCTAssertTrue(contains("<Slides>2</Slides>"))
        XCTAssertEqual(
            PDFTextExportFormat.powerPointPresentation.fileExtension,
            "pptx"
        )
    }

    func testProtectedCopyRequiresPassword() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("protected.pdf")
        try makePDF(at: source, pages: ["Sensitive"])

        try PDFOutputService().protect(
            sourceURL: source,
            destination: output,
            password: "local-only"
        )

        let protected = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(protected.isEncrypted)
        XCTAssertTrue(protected.isLocked)
        XCTAssertTrue(protected.unlock(withPassword: "local-only"))
    }

    func testProtectedCopySupportsStructuredDemoPDF_BitsUT() throws {
        let source = temporaryDirectory
            .appendingPathComponent("structured-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("structured-protected.pdf")
        try DemoPDFBuilder.create(at: source)

        try PDFOutputService().protect(
            sourceURL: source,
            destination: output,
            password: "PaperPath-2026"
        )

        let protected = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(protected.isEncrypted)
        XCTAssertTrue(protected.isLocked)
        XCTAssertTrue(protected.unlock(withPassword: "PaperPath-2026"))
        XCTAssertEqual(protected.pageCount, 2)
        XCTAssertEqual(
            protected.page(at: 0)?.annotations
                .filter { $0.widgetFieldType == .text }
                .count,
            1
        )
        XCTAssertEqual(
            protected.page(at: 1)?.annotations
                .filter { $0.widgetFieldType == .signature }
                .count,
            1
        )
        XCTAssertEqual(
            protected.page(at: 1)?.annotations
                .filter { $0.type == "Link" }
                .count,
            1
        )
    }

    func testProtectedCopyRejectsShortPassword() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("protected.pdf")
        try makePDF(at: source, pages: ["Sensitive"])

        XCTAssertThrowsError(
            try PDFOutputService().protect(
                sourceURL: source,
                destination: output,
                password: "short"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSecureRedactionRemovesUnderlyingTextLayer() throws {
        let source = temporaryDirectory.appendingPathComponent("source.pdf")
        let output = temporaryDirectory.appendingPathComponent("redacted.pdf")
        try makePDF(at: source, pages: ["Secret account 12345"])

        try PDFOutputService().secureRedact(
            sourceURL: source,
            destination: output,
            marks: [
                PDFRedactionMark(
                    pageIndex: 0,
                    normalizedX: 0.08,
                    normalizedY: 0.7,
                    normalizedWidth: 0.5,
                    normalizedHeight: 0.08
                )
            ]
        )

        let redacted = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertFalse(
            redacted.page(at: 0)?.string?.contains("12345") == true
        )
    }

    func testInkAnnotationPersistsAsPDFAnnotation() throws {
        let source = temporaryDirectory.appendingPathComponent("ink.pdf")
        try makePDF(at: source, pages: ["Sign here"])
        let payload = PDFInkPayload(
            pageIndex: 0,
            strokes: [
                PDFInkStroke(
                    points: [
                        PDFInkPoint(x: 0.1, y: 0.5),
                        PDFInkPoint(x: 0.4, y: 0.45),
                        PDFInkPoint(x: 0.8, y: 0.55)
                    ]
                )
            ],
            placement: .signature
        )

        try PDFMutationService().addInk(payload, in: source)

        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(document.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(
            document.page(at: 0)?.annotations.first?.type,
            "Ink"
        )
    }

    func testAnnotationPropertiesRebuildAppearanceAndVerify()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("annotation-edit.pdf")
        try makePDF(at: source, pages: ["Review this region"])
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 80, y: 520, width: 180, height: 96),
            forType: .square,
            withProperties: nil
        )
        annotation.contents = "Before review"
        annotation.color = .systemRed
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: source))

        let service = PDFMutationService()
        let snapshot = try XCTUnwrap(
            service.annotations(in: source).first
        )
        XCTAssertTrue(snapshot.hasAppearanceStream)
        XCTAssertTrue(snapshot.canEditContents)
        XCTAssertTrue(snapshot.canEditStyle)

        let blue = PDFInkColor(
            red: 0.04,
            green: 0.36,
            blue: 0.88,
            alpha: 1
        )
        try service.editAnnotation(
            PDFAnnotationEditPayload(
                pageIndex: snapshot.pageIndex,
                annotationIndex: snapshot.annotationIndex,
                expectedType: snapshot.type,
                contents: "Reviewed locally",
                color: blue,
                lineWidth: 4.5
            ),
            in: source
        )

        let reopened = try XCTUnwrap(PDFDocument(url: source))
        let edited = try XCTUnwrap(
            reopened.page(at: 0)?.annotations.first
        )
        XCTAssertEqual(edited.contents, "Reviewed locally")
        XCTAssertEqual(edited.border?.lineWidth, 4.5)
        XCTAssertNotNil(edited.modificationDate)
        XCTAssertEqual(edited.userName, "PaperPath")
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blueComponent: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(
            edited.color.getRed(
                &red,
                green: &green,
                blue: &blueComponent,
                alpha: &alpha
            )
        )
        XCTAssertEqual(red, 0.04, accuracy: 0.025)
        XCTAssertEqual(green, 0.36, accuracy: 0.025)
        XCTAssertEqual(blueComponent, 0.88, accuracy: 0.025)
    }

    func testFreeTextEditPreservesIndependentFontColor()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("free-text-edit.pdf")
        try makePDF(at: source, pages: ["Review this note"])
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 80, y: 520, width: 220, height: 72),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Original note"
        annotation.color = .systemRed
        annotation.fontColor = .systemGreen
        page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: source))

        let service = PDFMutationService()
        let snapshot = try XCTUnwrap(
            service.annotations(in: source).first
        )
        XCTAssertEqual(snapshot.type.lowercased(), "freetext")
        XCTAssertTrue(snapshot.canEditContents)
        XCTAssertTrue(snapshot.canEditStyle)
        XCTAssertEqual(snapshot.color.red, 0.2, accuracy: 0.08)
        XCTAssertEqual(snapshot.color.green, 0.78, accuracy: 0.08)

        try service.editAnnotation(
            PDFAnnotationEditPayload(
                pageIndex: snapshot.pageIndex,
                annotationIndex: snapshot.annotationIndex,
                expectedType: snapshot.type,
                contents: "Updated note",
                color: snapshot.color,
                lineWidth: nil
            ),
            in: source
        )

        let reopened = try XCTUnwrap(PDFDocument(url: source))
        let edited = try XCTUnwrap(
            reopened.page(at: 0)?.annotations.first
        )
        XCTAssertEqual(edited.contents, "Updated note")
        let fontColor = try XCTUnwrap(edited.fontColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(
            fontColor.getRed(
                &red,
                green: &green,
                blue: &blue,
                alpha: &alpha
            )
        )
        XCTAssertEqual(red, 0.2, accuracy: 0.08)
        XCTAssertEqual(green, 0.78, accuracy: 0.08)
    }

    func testSignaturePlacementRespectsSelectedPositionAndSize() throws {
        let source = temporaryDirectory.appendingPathComponent("signature.pdf")
        try makePDF(at: source, pages: ["Sign here"])
        let stroke = PDFInkStroke(
            points: [
                PDFInkPoint(x: 0.1, y: 0.5),
                PDFInkPoint(x: 0.9, y: 0.5)
            ]
        )
        let service = PDFMutationService()

        try service.addInk(
            PDFInkPayload(
                pageIndex: 0,
                strokes: [stroke],
                placement: .signature,
                signaturePosition: .left,
                signatureSize: .compact
            ),
            in: source
        )
        try service.addInk(
            PDFInkPayload(
                pageIndex: 0,
                strokes: [stroke],
                placement: .signature,
                signaturePosition: .right,
                signatureSize: .large
            ),
            in: source
        )

        let annotations = try XCTUnwrap(
            PDFDocument(url: source)?.page(at: 0)?.annotations
        )
        XCTAssertEqual(annotations.count, 2)
        XCTAssertLessThan(annotations[0].bounds.minX, annotations[1].bounds.minX)
        XCTAssertLessThan(annotations[0].bounds.width, annotations[1].bounds.width)
    }

    func testDirectPageMovePreservesRequestedOrder() throws {
        let source = temporaryDirectory.appendingPathComponent("reorder.pdf")
        try makePDF(at: source, pages: ["First", "Second", "Third"])

        try PDFMutationService().movePage(from: 0, to: 2, in: source)

        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Second") == true)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Third") == true)
        XCTAssertTrue(document.page(at: 2)?.string?.contains("First") == true)
    }

    func testExistingLinkCanChangeTargetAndBeRemoved() throws {
        let source = temporaryDirectory
            .appendingPathComponent("links.pdf")
        let updatedURL = temporaryDirectory
            .appendingPathComponent("links-updated.pdf")
        let removedURL = temporaryDirectory
            .appendingPathComponent("links-removed.pdf")
        try makePDF(at: source, pages: ["Open website", "Details"])
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 56, y: 610, width: 180, height: 32),
            forType: .link,
            withProperties: nil
        )
        annotation.contents = "Project website"
        annotation.url = try XCTUnwrap(
            URL(string: "https://example.com")
        )
        page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: source))

        let mutationService = PDFMutationService()
        let sourceLink = try XCTUnwrap(
            mutationService.links(in: source).first
        )
        XCTAssertEqual(
            sourceLink.target,
            .web(try XCTUnwrap(URL(string: "https://example.com")))
        )
        let movedBounds = PDFNormalizedRect(
            x: 0.18,
            y: 0.62,
            width: 0.36,
            height: 0.08
        )
        try PDFOutputService().editLink(
            sourceURL: source,
            destination: updatedURL,
            mutation: .update(
                PDFLinkEditPayload(
                    pageIndex: sourceLink.pageIndex,
                    annotationIndex: sourceLink.annotationIndex,
                    normalizedBounds: movedBounds,
                    title: "Open details",
                    target: .page(1)
                )
            )
        )

        let updated = try XCTUnwrap(
            mutationService.links(in: updatedURL).first
        )
        XCTAssertEqual(updated.title, "Open details")
        XCTAssertEqual(updated.target, .page(1))
        XCTAssertEqual(
            updated.normalizedBounds.x,
            movedBounds.x,
            accuracy: 0.002
        )

        try PDFOutputService().editLink(
            sourceURL: updatedURL,
            destination: removedURL,
            mutation: .remove(
                pageIndex: updated.pageIndex,
                annotationIndex: updated.annotationIndex
            )
        )
        XCTAssertTrue(
            try mutationService.links(in: removedURL).isEmpty
        )
        XCTAssertEqual(
            PDFDocument(url: removedURL)?.pageCount,
            2
        )
    }

    func testBatchPageMutationAndSelectedCrossDocumentCopy() throws {
        let source = temporaryDirectory
            .appendingPathComponent("batch-source.pdf")
        let destination = temporaryDirectory
            .appendingPathComponent("batch-destination.pdf")
        try makePDF(
            at: source,
            pages: (0..<6).map { "Source \($0)" }
        )
        try makePDF(at: destination, pages: ["Destination"])
        let service = PDFMutationService()

        try service.rotatePages(at: [1, 3, 5], in: source)
        var sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(sourceDocument.page(at: 1)?.rotation, 90)
        XCTAssertEqual(sourceDocument.page(at: 2)?.rotation, 0)

        try service.appendPages(
            from: source,
            indices: [5, 1, 3, 3],
            in: destination
        )
        let copied = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(copied.pageCount, 4)
        XCTAssertTrue(
            copied.page(at: 1)?.string?.contains("Source 1")
                == true
        )
        XCTAssertTrue(
            copied.page(at: 2)?.string?.contains("Source 3")
                == true
        )
        XCTAssertTrue(
            copied.page(at: 3)?.string?.contains("Source 5")
                == true
        )

        try service.deletePages(at: [4, 2, 2], in: source)
        sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(sourceDocument.pageCount, 4)
        XCTAssertTrue(
            sourceDocument.page(at: 2)?.string?.contains("Source 3")
                == true
        )
        XCTAssertThrowsError(
            try service.deletePages(
                at: Array(0..<sourceDocument.pageCount),
                in: source
            )
        )
    }

    @MainActor
    func testPageMutationUndoRestoresPagesAndBookmarks() async throws {
        let source = temporaryDirectory
            .appendingPathComponent("undo-pages.pdf")
        try makePDF(at: source, pages: ["One", "Two", "Three"])
        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("PageUndoStore")
        )
        var record = try await store.importPDF(from: source)
        record = try await store.updateBookmarks(
            record,
            pages: [1, 2]
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()

        await model.deletePage(recordID: record.id, index: 1)
        XCTAssertTrue(model.canUndoPageChange(recordID: record.id))
        XCTAssertEqual(model.record(id: record.id)?.profile.pageCount, 2)

        let undone = await model.undoLastPageChange(
            recordID: record.id
        )
        XCTAssertTrue(undone)
        let restored = try XCTUnwrap(model.record(id: record.id))
        XCTAssertEqual(restored.profile.pageCount, 3)
        XCTAssertEqual(restored.bookmarkedPages, [1, 2])
        let restoredURL = try XCTUnwrap(model.url(for: record.id))
        XCTAssertTrue(
            PDFDocument(url: restoredURL)?.page(at: 1)?.string?
                .contains("Two") == true
        )
    }

    func testPageInsertionAndCropUpdateGeometry() throws {
        let source = temporaryDirectory.appendingPathComponent("pages.pdf")
        try makePDF(at: source, pages: ["Page"])
        let service = PDFMutationService()

        try service.insertBlankPage(after: 0, in: source)
        var document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(document.pageCount, 2)

        let original = try XCTUnwrap(document.page(at: 0))
            .bounds(for: .cropBox)
        try service.cropPage(at: 0, insetFraction: 0.04, in: source)
        document = try XCTUnwrap(PDFDocument(url: source))
        let cropped = try XCTUnwrap(document.page(at: 0))
            .bounds(for: .cropBox)
        XCTAssertLessThan(cropped.width, original.width)
        XCTAssertLessThan(cropped.height, original.height)
    }

    func testStandardStampPersistsAsInteroperableAnnotation() throws {
        let source = temporaryDirectory.appendingPathComponent("stamp.pdf")
        try makePDF(at: source, pages: ["Review copy"])

        try PDFMutationService().addStamp(
            .approved,
            toPageAt: 0,
            in: source
        )

        let annotation = try XCTUnwrap(
            PDFDocument(url: source)?.page(at: 0)?.annotations.first
        )
        XCTAssertEqual(annotation.type, "Stamp")
        XCTAssertEqual(
            annotation.stampName?.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            ),
            PDFStampKind.approved.stampName
        )
        XCTAssertEqual(annotation.contents, "Approved")
    }

    func testAnnotationSummaryEscapesUntrustedMarkdownInlineContent() {
        let value = "Contract #1\n[link] *bold* \\ draft | final!"

        XCTAssertEqual(
            PDFAnnotationMarkdown.inline(value),
            "Contract \\#1 \\[link\\] \\*bold\\* \\\\ draft \\| final\\!"
        )
    }

    func testComparisonCandidatesUseStableRelevantOrdering() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let source = DocumentRecord(
            displayName: "Project handoff",
            fileName: "source.pdf",
            modifiedAt: base,
            profile: textProfile(pageCount: 2)
        )
        let alphabeticalFirst = DocumentRecord(
            displayName: "August invoice",
            fileName: "august.pdf",
            modifiedAt: base.addingTimeInterval(30),
            profile: textProfile(pageCount: 2)
        )
        let alphabeticalSecond = DocumentRecord(
            displayName: "Site review report",
            fileName: "site.pdf",
            modifiedAt: base.addingTimeInterval(60),
            profile: textProfile(pageCount: 2)
        )
        let recentlyViewed = DocumentRecord(
            displayName: "Viewed notes",
            fileName: "viewed.pdf",
            modifiedAt: base,
            profile: textProfile(pageCount: 2),
            lastViewedAt: base.addingTimeInterval(10)
        )
        let relatedOutput = DocumentRecord(
            displayName: "Project handoff - verified",
            fileName: "related.pdf",
            modifiedAt: base,
            profile: textProfile(pageCount: 2),
            sourceDocumentID: source.id
        )
        let locked = DocumentRecord(
            displayName: "Locked",
            fileName: "locked.pdf",
            profile: profile(
                kind: .text,
                pageCount: 2,
                isLocked: true
            )
        )

        let ordered = DocumentComparisonCandidates.ordered(
            from: [
                alphabeticalSecond,
                source,
                locked,
                alphabeticalFirst,
                recentlyViewed,
                relatedOutput
            ],
            sourceID: source.id
        )

        XCTAssertEqual(
            ordered.map(\.displayName),
            [
                "Project handoff - verified",
                "Viewed notes",
                "August invoice",
                "Site review report"
            ]
        )
    }

    func testQuickTasksSupportUnifiedSearchAndDocumentEligibility() {
        let form = DocumentRecord(
            displayName: "Application",
            fileName: "form.pdf",
            profile: profile(kind: .form, pageCount: 2)
        )
        let scan = DocumentRecord(
            displayName: "Receipt",
            fileName: "scan.pdf",
            profile: profile(kind: .scan, pageCount: 1)
        )

        XCTAssertEqual(PDFQuickTask.safeShare.title, "Verify & Share")
        XCTAssertTrue(PDFQuickTask.safeShare.matches("clean verify"))
        XCTAssertTrue(PDFQuickTask.signPDF.matches("signature"))
        XCTAssertTrue(PDFQuickTask.signPDF.matches("签字"))
        XCTAssertTrue(PDFQuickTask.compressPDF.matches("瘦身"))
        XCTAssertTrue(PDFQuickTask.redactPDF.matches("打码"))
        XCTAssertTrue(PDFQuickTask.splitPDF.matches("拆页"))
        XCTAssertTrue(PDFQuickTask.exportText.matches("pdf-to-text"))
        XCTAssertTrue(DocumentTool.redact.matches("打码"))
        XCTAssertTrue(DocumentTool.compress.matches("shrink"))
        XCTAssertTrue(DocumentTool.export.matches("pdf_text"))
        XCTAssertFalse(DocumentTool.sign.matches("crop pages"))
        XCTAssertGreaterThan(
            DocumentTool.sign.matchScore("sign") ?? 0,
            DocumentTool.export.matchScore("sign") ?? 0
        )
        XCTAssertNotNil(
            DocumentTool.organize.matchScore("rotate crop")
        )
        XCTAssertNil(DocumentTool.sign.matchScore("rotate crop"))
        XCTAssertGreaterThan(
            PDFQuickTask.signPDF.matchScore("sign") ?? 0,
            PDFQuickTask.safeShare.matchScore("sign") ?? 0
        )
        XCTAssertTrue(PDFQuickTask.fillForms.supports(form))
        XCTAssertFalse(PDFQuickTask.fillForms.supports(scan))
        XCTAssertTrue(PDFQuickTask.recognizeText.supports(scan))
        XCTAssertFalse(PDFQuickTask.organizePages.supports(scan))
    }

    func testQuickAccessAdaptsToDocumentNeeds() {
        let form = DocumentRecord(
            displayName: "Application",
            fileName: "form.pdf",
            profile: profile(kind: .form, pageCount: 1)
        )
        let scan = DocumentRecord(
            displayName: "Receipt",
            fileName: "scan.pdf",
            profile: profile(kind: .scan, pageCount: 2)
        )

        let tasks = PDFQuickTaskPlanner.quickAccess(for: [form, scan])

        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(tasks[0], .fillForms)
        XCTAssertEqual(tasks[1], .recognizeText)
        XCTAssertEqual(tasks[2], .organizePages)
        XCTAssertEqual(tasks[3], .signPDF)
    }

    func testQuickAccessAvoidsIncompatiblePageToolsForSinglePageLibrary() {
        let text = DocumentRecord(
            displayName: "Memo",
            fileName: "memo.pdf",
            profile: profile(kind: .text, pageCount: 1)
        )

        let tasks = PDFQuickTaskPlanner.quickAccess(for: [text])

        XCTAssertEqual(
            tasks,
            [.signPDF, .safeShare, .compressPDF, .protectPDF]
        )
        XCTAssertFalse(tasks.contains(.organizePages))
    }

    func testActionPlannerPrioritizesDocumentSpecificNextStep() {
        let scan = DocumentRecord(
            displayName: "Receipt",
            fileName: "scan.pdf",
            profile: profile(kind: .scan, pageCount: 1)
        )
        let form = DocumentRecord(
            displayName: "Application",
            fileName: "form.pdf",
            profile: profile(kind: .form, pageCount: 1)
        )
        let contract = DocumentRecord(
            displayName: "Agreement",
            fileName: "contract.pdf",
            profile: profile(kind: .text, pageCount: 2),
            brief: DocumentBrief(
                category: .contract,
                summary: "Signature required.",
                entities: [],
                suggestedSteps: [
                    SuggestedStep(
                        kind: .reviewSignature,
                        title: "Review signature requirement",
                        evidence: "Sign here"
                    )
                ],
                indexedAt: Date(),
                textSource: .native,
                indexedCharacterCount: 120
            )
        )

        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: scan,
                hasRecognizedText: false
            ).first,
            .recognizeText
        )
        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: scan,
                hasRecognizedText: true
            ).first,
            .makeSearchable
        )
        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: form,
                hasRecognizedText: false
            ).first,
            .reviewForm
        )
        XCTAssertEqual(
            DocumentActionPlanner.actions(
                for: contract,
                hasRecognizedText: false
            ).first,
            .sign
        )

        var signedContract = contract
        signedContract.completedActions = [.sign]
        let recommendation = DocumentActionPlanner.recommendation(
            for: signedContract,
            hasRecognizedText: false
        )
        XCTAssertEqual(recommendation.action, .safeShare)
        XCTAssertTrue(recommendation.reason.contains("flattened"))
        XCTAssertFalse(
            DocumentActionPlanner.actions(
                for: signedContract,
                hasRecognizedText: false
            ).contains(.sign)
        )

        let unsignedRecommendation = DocumentActionPlanner.recommendation(
            for: contract,
            hasRecognizedText: false
        )
        XCTAssertEqual(unsignedRecommendation.action, .sign)
        XCTAssertEqual(unsignedRecommendation.reason, "Sign here")
    }

    func testActionPlannerDoesNotOfferSearchableCopyAfterEmptyOCR() {
        var scan = DocumentRecord(
            displayName: "Receipt",
            fileName: "scan.pdf",
            profile: profile(kind: .scan, pageCount: 1),
            completedActions: [.recognizeText]
        )

        var actions = DocumentActionPlanner.actions(
            for: scan,
            hasRecognizedText: false
        )
        XCTAssertFalse(actions.contains(.recognizeText))
        XCTAssertFalse(actions.contains(.makeSearchable))

        scan.completedActions.insert(.makeSearchable)
        actions = DocumentActionPlanner.actions(
            for: scan,
            hasRecognizedText: true
        )
        XCTAssertFalse(actions.contains(.makeSearchable))
    }

    func testActionPlannerRequiresCurrentVerifiedOutputBeforeSharing() {
        var source = DocumentRecord(
            displayName: "Agreement",
            fileName: "contract.pdf",
            profile: profile(kind: .text, pageCount: 2),
            workflowStatus: .ready,
            completedActions: [.sign, .safeShare]
        )

        var actions = DocumentActionPlanner.actions(
            for: source,
            hasRecognizedText: false
        )
        XCTAssertEqual(actions.first, .safeShare)
        XCTAssertFalse(actions.contains(.shareCopy))
        XCTAssertEqual(
            DocumentActionPlanner.recommendation(
                for: source,
                hasRecognizedText: false
            ).action,
            .safeShare
        )

        actions = DocumentActionPlanner.actions(
            for: source,
            hasRecognizedText: false,
            hasCurrentVerifiedOutput: true
        )
        XCTAssertEqual(actions.first, .shareCopy)
        XCTAssertFalse(actions.contains(.safeShare))
        XCTAssertEqual(
            DocumentActionPlanner.recommendation(
                for: source,
                hasRecognizedText: false,
                hasCurrentVerifiedOutput: true
            ).action,
            .shareCopy
        )

        let artifactRevisionID = UUID()
        var artifactReceipt = deliveryReceipt(operation: .safeShare)
        artifactReceipt.outputRevisionID = artifactRevisionID
        source = DocumentRecord(
            displayName: "Agreement - verified",
            fileName: "contract-verified.pdf",
            contentRevisionID: artifactRevisionID,
            profile: profile(kind: .text, pageCount: 2),
            workflowStatus: .ready,
            completedActions: [.safeShare],
            deliveryReceipt: artifactReceipt,
            sourceDocumentID: UUID(),
            contentFingerprint: artifactReceipt.sha256
        )
        actions = DocumentActionPlanner.actions(
            for: source,
            hasRecognizedText: false
        )
        XCTAssertEqual(actions, [.shareCopy, .inspect])
        XCTAssertEqual(
            DocumentActionPlanner.recommendation(
                for: source,
                hasRecognizedText: false
            ).reason,
            "Verified copy checked with a SHA-256 receipt."
        )
    }

    func testImageObjectReplacementRemovesOriginalJPEGBytes() throws {
        let source = temporaryDirectory
            .appendingPathComponent("image-object.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("image-replaced.pdf")
        let originalJPEG = try XCTUnwrap(
            solidJPEG(color: .systemRed, size: CGSize(width: 80, height: 60))
        )
        let replacementJPEG = try XCTUnwrap(
            solidJPEG(color: .systemBlue, size: CGSize(width: 120, height: 90))
        )
        try makeClassicImagePDF(
            at: source,
            jpegData: originalJPEG,
            pixelWidth: 80,
            pixelHeight: 60
        )

        let service = PDFOutputService()
        let objects = try service.imageObjects(
            sourceURL: source,
            pageIndex: 0
        )
        let object = try XCTUnwrap(objects.first)
        XCTAssertTrue(object.isSafelyReplaceable)
        XCTAssertEqual(object.objectNumber, 5)
        XCTAssertEqual(object.pixelWidth, 80)
        XCTAssertEqual(object.pixelHeight, 60)
        XCTAssertEqual(object.usageCount, 1)
        XCTAssertEqual(
            object.normalizedBounds.x,
            100.0 / 612.0,
            accuracy: 0.002
        )
        XCTAssertEqual(
            object.normalizedBounds.y,
            352.0 / 792.0,
            accuracy: 0.002
        )

        try service.replaceImageObject(
            sourceURL: source,
            destination: output,
            snapshot: object,
            replacementData: replacementJPEG
        )

        let outputData = try Data(contentsOf: output)
        XCTAssertNil(outputData.range(of: originalJPEG))
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertNotNil(
            reopened.page(at: 0)?.thumbnail(
                of: CGSize(width: 306, height: 396),
                for: .cropBox
            ).cgImage
        )
        let rewritten = try XCTUnwrap(
            service.imageObjects(
                sourceURL: output,
                pageIndex: 0
            ).first
        )
        XCTAssertNotEqual(rewritten.sourceDigest, object.sourceDigest)
        XCTAssertEqual(rewritten.pixelWidth, 120)
        XCTAssertEqual(rewritten.pixelHeight, 90)
    }

    func testSharedImageObjectReplacementUpdatesEveryUse() throws {
        let source = temporaryDirectory
            .appendingPathComponent("shared-image-object.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("shared-image-replaced.pdf")
        let originalJPEG = try XCTUnwrap(
            solidJPEG(
                color: .systemOrange,
                size: CGSize(width: 96, height: 72)
            )
        )
        let replacementJPEG = try XCTUnwrap(
            solidJPEG(
                color: .systemTeal,
                size: CGSize(width: 144, height: 108)
            )
        )
        try makeClassicRepeatedImagePDF(
            at: source,
            jpegData: originalJPEG,
            pixelWidth: 96,
            pixelHeight: 72
        )

        let service = PDFOutputService()
        let object = try XCTUnwrap(
            service.imageObjects(
                sourceURL: source,
                pageIndex: 0
            ).first
        )
        XCTAssertEqual(object.usageCount, 2)
        XCTAssertTrue(object.isSafelyReplaceable)
        XCTAssertTrue(object.replacesMultipleUses)

        try service.replaceImageObject(
            sourceURL: source,
            destination: output,
            snapshot: object,
            replacementData: replacementJPEG
        )

        let outputData = try Data(contentsOf: output)
        XCTAssertNil(outputData.range(of: originalJPEG))
        let firstUse = try XCTUnwrap(
            service.imageObjects(
                sourceURL: output,
                pageIndex: 0
            ).first
        )
        let secondUse = try XCTUnwrap(
            service.imageObjects(
                sourceURL: output,
                pageIndex: 1
            ).first
        )
        XCTAssertEqual(firstUse.objectNumber, object.objectNumber)
        XCTAssertEqual(secondUse.objectNumber, object.objectNumber)
        XCTAssertEqual(firstUse.sourceDigest, secondUse.sourceDigest)
        XCTAssertNotEqual(firstUse.sourceDigest, object.sourceDigest)
        XCTAssertEqual(firstUse.usageCount, 2)
        XCTAssertEqual(secondUse.usageCount, 2)
        XCTAssertEqual(firstUse.pixelWidth, 144)
        XCTAssertEqual(secondUse.pixelHeight, 108)
    }

    func testXRefStreamImageReplacementRebuildsWithoutOldBytes()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("xref-stream-image.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("xref-stream-replaced.pdf")
        let originalJPEG = try XCTUnwrap(
            solidJPEG(
                color: .systemRed,
                size: CGSize(width: 80, height: 60)
            )
        )
        let replacementJPEG = try XCTUnwrap(
            solidJPEG(
                color: .systemBlue,
                size: CGSize(width: 128, height: 96)
            )
        )
        try makeXRefStreamImagePDF(
            at: source,
            jpegData: originalJPEG,
            pixelWidth: 80,
            pixelHeight: 60
        )
        let service = PDFOutputService()
        let object = try XCTUnwrap(
            service.imageObjects(
                sourceURL: source,
                pageIndex: 0
            ).first
        )

        try service.replaceImageObject(
            sourceURL: source,
            destination: output,
            snapshot: object,
            replacementData: replacementJPEG
        )

        XCTAssertNil(
            try Data(contentsOf: output).range(of: originalJPEG)
        )
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
        let rewritten = try XCTUnwrap(
            service.imageObjects(
                sourceURL: output,
                pageIndex: 0
            ).first
        )
        XCTAssertEqual(rewritten.objectNumber, object.objectNumber)
        XCTAssertEqual(rewritten.pixelWidth, 128)
        XCTAssertEqual(rewritten.pixelHeight, 96)
    }

    func testEmbeddedImageExportPreservesBytesAndDeduplicatesUses()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("embedded-images.pdf")
        let directory = temporaryDirectory
            .appendingPathComponent("embedded-export", isDirectory: true)
        let originalJPEG = try XCTUnwrap(
            solidJPEG(
                color: .systemPurple,
                size: CGSize(width: 96, height: 72)
            )
        )
        try makeClassicRepeatedImagePDF(
            at: source,
            jpegData: originalJPEG,
            pixelWidth: 96,
            pixelHeight: 72
        )
        let sourceBeforeExport = try Data(contentsOf: source)

        let result = try PDFOutputService().exportEmbeddedImages(
            sourceURL: source,
            directory: directory
        )

        XCTAssertEqual(result.uniqueImageCount, 1)
        XCTAssertEqual(result.occurrenceCount, 2)
        XCTAssertEqual(result.unsupportedOccurrenceCount, 0)
        XCTAssertEqual(result.originalStreamFileCount, 1)
        XCTAssertEqual(result.losslessPNGFileCount, 0)
        let exportedURL = try XCTUnwrap(result.urls.first)
        XCTAssertEqual(exportedURL.pathExtension, "jpg")
        XCTAssertTrue(
            exportedURL.lastPathComponent
                .hasPrefix("Embedded-p0001-001-")
        )
        XCTAssertEqual(
            try Data(contentsOf: exportedURL),
            originalJPEG
        )
        XCTAssertEqual(
            try Data(contentsOf: source),
            sourceBeforeExport
        )

        let emptySource = temporaryDirectory
            .appendingPathComponent("no-embedded-images.pdf")
        let emptyDirectory = temporaryDirectory
            .appendingPathComponent("empty-export", isDirectory: true)
        try makePDF(at: emptySource, pages: ["Vector text only"])
        XCTAssertThrowsError(
            try PDFOutputService().exportEmbeddedImages(
                sourceURL: emptySource,
                directory: emptyDirectory
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: emptyDirectory.path
            )
        )
    }

    func testEmbeddedImageExportDecodesFlateSoftMaskInsideForm()
        throws {
        let source = temporaryDirectory
            .appendingPathComponent("form-flate-image.pdf")
        let directory = temporaryDirectory
            .appendingPathComponent(
                "form-flate-export",
                isDirectory: true
            )
        try makeFormFlateImagePDF(at: source)
        let sourceBeforeExport = try Data(contentsOf: source)

        let result = try PDFOutputService().exportEmbeddedImages(
            sourceURL: source,
            directory: directory
        )

        XCTAssertEqual(result.uniqueImageCount, 1)
        XCTAssertEqual(result.occurrenceCount, 1)
        XCTAssertEqual(result.unsupportedOccurrenceCount, 0)
        XCTAssertEqual(result.originalStreamFileCount, 0)
        XCTAssertEqual(result.losslessPNGFileCount, 1)
        let exportedURL = try XCTUnwrap(result.urls.first)
        XCTAssertEqual(exportedURL.pathExtension, "png")

        let data = try Data(contentsOf: exportedURL)
        let sourceRef = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(
                sourceRef,
                0,
                nil
            ) as? [CFString: Any]
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .intValue,
            4
        )
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .intValue,
            2
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(sourceRef, 0, nil)
        )
        XCTAssertNotEqual(image.alphaInfo, .none)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipFirst)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipLast)
        XCTAssertEqual(
            try Data(contentsOf: source),
            sourceBeforeExport
        )

        let service = PDFOutputService()
        let object = try XCTUnwrap(
            service.imageObjects(
                sourceURL: source,
                pageIndex: 0
            ).first
        )
        XCTAssertEqual(object.storage, .flateWithSoftMask)
        let replacementURL = temporaryDirectory
            .appendingPathComponent("form-flate-replaced.pdf")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let replacement = UIGraphicsImageRenderer(
            size: CGSize(width: 16, height: 8),
            format: format
        ).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
            UIColor.systemGreen.withAlphaComponent(0.55).setFill()
            context.fill(CGRect(x: 2, y: 1, width: 12, height: 6))
        }
        let replacementData = try XCTUnwrap(replacement.pngData())
        try service.replaceImageObject(
            sourceURL: source,
            destination: replacementURL,
            snapshot: object,
            replacementData: replacementData
        )
        let rewritten = try XCTUnwrap(
            service.imageObjects(
                sourceURL: replacementURL,
                pageIndex: 0
            ).first
        )
        XCTAssertEqual(rewritten.storage, .flateWithSoftMask)
        XCTAssertEqual(rewritten.pixelWidth, 16)
        XCTAssertEqual(rewritten.pixelHeight, 8)
        XCTAssertNotEqual(rewritten.sourceDigest, object.sourceDigest)
    }

    func testCrossPageTextFlowRebuildsAndVerifiesBothPages() throws {
        let source = temporaryDirectory
            .appendingPathComponent("cross-page-source.pdf")
        let output = temporaryDirectory
            .appendingPathComponent("cross-page-output.pdf")
        try makePDF(
            at: source,
            pages: [
                "First page original wording",
                "Second page original wording"
            ]
        )
        let document = try XCTUnwrap(PDFDocument(url: source))
        var regions: [PDFTextFlowRegion] = []
        for pageIndex in 0..<2 {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let text = try XCTUnwrap(page.string)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = try XCTUnwrap(page.string) as NSString
            let range = NSRange(location: 0, length: source.length)
            let selection = try XCTUnwrap(page.selection(for: range))
            let pageBounds = page.bounds(for: .cropBox)
            let bounds = selection.bounds(for: page)
                .intersection(pageBounds)
            regions.append(
                PDFTextFlowRegion(
                    pageIndex: pageIndex,
                    normalizedX: (
                        bounds.minX - pageBounds.minX
                    ) / pageBounds.width,
                    normalizedY: (
                        pageBounds.maxY - bounds.maxY
                    ) / pageBounds.height,
                    normalizedWidth: bounds.width / pageBounds.width,
                    normalizedHeight: bounds.height / pageBounds.height,
                    lineCount: 1,
                    originalText: text,
                    sourceRangeLocation: range.location,
                    sourceRangeLength: range.length
                )
            )
        }
        let first = regions[0]
        let snapshot = PDFTextSelectionSnapshot(
            pageIndex: 0,
            originalText: regions.map(\.originalText)
                .joined(separator: "\n"),
            normalizedX: first.normalizedX,
            normalizedY: first.normalizedY,
            normalizedWidth: first.normalizedWidth,
            normalizedHeight: first.normalizedHeight,
            fontName: "Helvetica",
            fontSize: 18,
            color: PDFInkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            ),
            lineCount: 2,
            hasMixedFonts: false,
            pageRotation: 0,
            flowRegions: regions
        )
        let replacement =
            "Updated wording flows safely across both selected pages."
        let service = PDFOutputService()
        let assessment = try service.assessTextReplacement(
            sourceURL: source,
            selection: snapshot,
            replacement: replacement,
            fontStyle: .sans,
            alignment: .left
        )
        XCTAssertTrue(assessment.isReady, assessment.detail)
        XCTAssertEqual(assessment.flowRegionTexts.count, 2)
        XCTAssertFalse(assessment.flowRegionTexts[1].isEmpty)

        try service.replaceText(
            sourceURL: source,
            destination: output,
            selection: snapshot,
            replacement: replacement,
            assessment: assessment
        )

        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertFalse(
            reopened.page(at: 0)?.string?
                .contains("First page original") == true
        )
        XCTAssertFalse(
            reopened.page(at: 1)?.string?
                .contains("Second page original") == true
        )
        let outputText = (0..<2).compactMap {
            reopened.page(at: $0)?.string
        }.joined(separator: " ")
        for chunk in assessment.flowRegionTexts where !chunk.isEmpty {
            XCTAssertTrue(outputText.contains(chunk))
        }
    }

    @MainActor
    func testSafeShareCopyMarksSourceReadyAndCompleted() async throws {
        let source = temporaryDirectory.appendingPathComponent("ready.pdf")
        try makePDF(at: source, pages: ["Ready to deliver"])
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent("ModelStore")
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()

        let importedRecord = await model.importPDF(from: source)
        let imported = try XCTUnwrap(importedRecord)
        await model.updateTaskCheckpoint(
            recordID: imported.id,
            checkpoint: DocumentTaskCheckpoint(stage: .verify)
        )
        let createdRecord = await model.createSafeShareCopy(
            recordID: imported.id,
            expectedContentRevisionID:
                imported.contentRevisionID
        )
        let created = try XCTUnwrap(createdRecord)
        let updatedSource = try XCTUnwrap(model.record(id: imported.id))
        let output = try XCTUnwrap(model.record(id: created.id))

        XCTAssertTrue(updatedSource.completedActions.contains(.safeShare))
        XCTAssertEqual(updatedSource.workflowStatus, .ready)
        XCTAssertNil(updatedSource.taskCheckpoint)
        let receipt = try XCTUnwrap(output.deliveryReceipt)
        XCTAssertEqual(
            receipt.outcomeTitle,
            "Ready to share",
            "\(receipt.changeReview?.changes ?? [])"
        )
        XCTAssertEqual(
            receipt.outcomeDetail,
            "PaperPath reopened all 1 page and checked the final copy."
        )
        XCTAssertEqual(
            DocumentActionPlanner.recommendation(
                for: output,
                hasRecognizedText: false
            ).action,
            .shareCopy
        )
    }

    @MainActor
    func testModelCreatesCheckedEditableCopyFromSessionPassword()
        async throws {
        let plain = temporaryDirectory
            .appendingPathComponent("plain-locked-source.pdf")
        let protected = temporaryDirectory
            .appendingPathComponent("protected-source.pdf")
        try makePDF(at: plain, pages: ["Protected form"])
        try PDFOutputService().protect(
            sourceURL: plain,
            destination: protected,
            password: "local-only"
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "UnlockedModelStore"
            )
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let importedRecord = await model.importPDF(from: protected)
        let imported = try XCTUnwrap(importedRecord)
        XCTAssertTrue(imported.profile.isLocked)

        let createdRecord = await model.createUnlockedCopy(
            recordID: imported.id,
            password: "local-only",
            expectedContentRevisionID:
                imported.contentRevisionID
        )
        let created = try XCTUnwrap(createdRecord)
        let output = try XCTUnwrap(model.record(id: created.id))
        let sourceURL = try XCTUnwrap(model.url(for: imported.id))
        let outputURL = try XCTUnwrap(model.url(for: output.id))

        XCTAssertTrue(PDFDocument(url: sourceURL)?.isLocked == true)
        XCTAssertFalse(output.profile.isLocked)
        XCTAssertFalse(PDFDocument(url: outputURL)?.isEncrypted == true)
        XCTAssertEqual(output.deliveryReceipt?.operation, .unlocked)
        XCTAssertTrue(output.hasCurrentDeliveryReceipt)
        XCTAssertEqual(
            output.deliveryReceipt?.outcomeTitle,
            "Editable copy ready"
        )
        XCTAssertNil(model.verifiedShareTarget(for: output.id))
        XCTAssertNotEqual(
            DocumentActionPlanner.recommendation(
                for: output,
                hasRecognizedText: false
            ).action,
            .shareCopy
        )
    }

    @MainActor
    func testSignatureKeepsNextRequiredFormFieldAheadOfVerify()
        async throws {
        let source = temporaryDirectory
            .appendingPathComponent("ordered-form.pdf")
        try makePDF(at: source, pages: ["Recipient", "Signature"])
        let signatureBounds = PDFNormalizedRect(
            x: 0.48,
            y: 0.72,
            width: 0.38,
            height: 0.09
        )
        let mutation = PDFMutationService()
        try mutation.addFormField(
            PDFFormFieldPayload(
                pageIndex: 0,
                kind: .text,
                name: "Recipient name",
                normalizedBounds: PDFNormalizedRect(
                    x: 0.12,
                    y: 0.28,
                    width: 0.48,
                    height: 0.08
                ),
                isRequired: true,
                isMultiline: false,
                maximumLength: 80
            ),
            in: source
        )
        try mutation.addFormField(
            PDFFormFieldPayload(
                pageIndex: 1,
                kind: .signature,
                name: "Approval signature",
                normalizedBounds: signatureBounds,
                isRequired: true,
                isMultiline: false,
                maximumLength: nil
            ),
            in: source
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "OrderedFormModelStore"
            )
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let importedRecord = await model.importPDF(from: source)
        let imported = try XCTUnwrap(importedRecord)
        let saved = await model.addInk(
            recordID: imported.id,
            payload: PDFInkPayload(
                pageIndex: 1,
                strokes: [
                    PDFInkStroke(
                        points: [
                            PDFInkPoint(x: 0.1, y: 0.7),
                            PDFInkPoint(x: 0.45, y: 0.25),
                            PDFInkPoint(x: 0.9, y: 0.55)
                        ]
                    )
                ],
                placement: .signature,
                normalizedBounds: signatureBounds
            ),
            expectedContentRevisionID:
                imported.contentRevisionID
        )

        XCTAssertTrue(saved)
        let checkpoint = try XCTUnwrap(
            model.record(id: imported.id)?.taskCheckpoint
        )
        XCTAssertEqual(checkpoint.stage, .fillForm)
        XCTAssertEqual(checkpoint.pageIndex, 0)
        XCTAssertEqual(checkpoint.fieldName, "Recipient name")
        XCTAssertEqual(
            DocumentActionPlanner.recommendation(
                for: try XCTUnwrap(model.record(id: imported.id)),
                hasRecognizedText: false
            ).action,
            .reviewForm
        )
    }

    func testProfessionalWorkflow_litigationParalegalProducesRedactedBatesSet()
        throws {
        let filing = temporaryDirectory
            .appendingPathComponent("public-filing.pdf")
        let exhibit = temporaryDirectory
            .appendingPathComponent("supporting-exhibit.pdf")
        let redacted = temporaryDirectory
            .appendingPathComponent("public-filing-redacted.pdf")
        let production = temporaryDirectory
            .appendingPathComponent("production-set.pdf")
        let verified = temporaryDirectory
            .appendingPathComponent("production-set-verified.pdf")

        try makePDF(
            at: filing,
            pages: [
                """
                ACME v. Roe public filing
                Social Security number: 111-22-3333
                Responsive contract follows below.
                """,
                "Filing declaration and signature page"
            ]
        )
        try makePDF(
            at: exhibit,
            pages: [
                "Exhibit A vendor agreement",
                "Exhibit B payment history"
            ]
        )
        let filingDocument = try XCTUnwrap(PDFDocument(url: filing))
        filingDocument.documentAttributes = [
            PDFDocumentAttribute.authorAttribute:
                "Privileged Litigation Team",
            PDFDocumentAttribute.subjectAttribute:
                "Attorney work product"
        ]
        guard filingDocument.write(to: filing) else {
            return XCTFail("Could not persist the legal fixture.")
        }
        let originalFiling = try Data(contentsOf: filing)
        let originalExhibit = try Data(contentsOf: exhibit)

        try PDFOutputService().secureRedact(
            sourceURL: filing,
            destination: redacted,
            marks: [
                PDFRedactionMark(
                    pageIndex: 0,
                    normalizedX: 0.06,
                    normalizedY: 0.66,
                    normalizedWidth: 0.88,
                    normalizedHeight: 0.18
                )
            ]
        )
        let redactionReceipt = try PDFDeliveryAuditService().audit(
            sourceURL: filing,
            outputURL: redacted,
            operation: .redacted
        )
        XCTAssertTrue(redactionReceipt.isVerified)
        XCTAssertEqual(redactionReceipt.textCharacterCount, 0)
        XCTAssertEqual(redactionReceipt.personalMetadataEntryCount, 0)

        try PDFCompositionService().combine(
            urls: [redacted, exhibit],
            to: production
        )
        let productionPageCount = try XCTUnwrap(
            PDFDocument(url: production)
        ).pageCount
        XCTAssertEqual(productionPageCount, 4)

        let payload = PDFBatesNumberingPayload(
            pageIndices: Array(0..<productionPageCount),
            startNumber: 1,
            digitCount: 6,
            prefix: "ACME-",
            suffix: "",
            position: .bottomRight
        )
        try PDFMutationService().applyBatesNumbers(
            payload,
            in: production
        )
        let numbered = try XCTUnwrap(PDFDocument(url: production))
        for pageIndex in 0..<numbered.pageCount {
            let expected = payload.text(
                number: Int64(pageIndex + 1)
            )
            XCTAssertTrue(
                numbered.page(at: pageIndex)?.annotations.contains {
                    $0.contents == expected
                        && $0.shouldDisplay
                        && $0.shouldPrint
                } == true,
                "Missing visible Bates identifier \(expected)"
            )
        }

        try PDFOutputService().safeShare(
            sourceURL: production,
            destination: verified
        )
        let deliveryReceipt = try PDFDeliveryAuditService().audit(
            sourceURL: production,
            outputURL: verified,
            operation: .safeShare
        )
        XCTAssertTrue(deliveryReceipt.isVerified)
        XCTAssertEqual(deliveryReceipt.outputPageCount, 4)
        XCTAssertEqual(deliveryReceipt.renderedPageCount, 4)
        XCTAssertEqual(deliveryReceipt.annotationCount, 0)
        XCTAssertEqual(deliveryReceipt.sha256.count, 64)
        XCTAssertEqual(try Data(contentsOf: filing), originalFiling)
        XCTAssertEqual(try Data(contentsOf: exhibit), originalExhibit)
    }

    func testProfessionalWorkflow_bookkeeperBuildsSearchableOrganizedAuditPacket()
        async throws {
        let scan = temporaryDirectory
            .appendingPathComponent("august-receipts-scan.pdf")
        let searchable = temporaryDirectory
            .appendingPathComponent("august-receipts-searchable.pdf")
        let workbook = temporaryDirectory
            .appendingPathComponent("august-expenses.xlsx")
        let protected = temporaryDirectory
            .appendingPathComponent("august-receipts-protected.pdf")
        let receiptTexts = [
            "INVOICE ACME 1001\nDATE 08/08/2026\nTOTAL 1280.50",
            "RECEIPT NORTHSTAR 2002\nDATE 08/14/2026\nTOTAL 84.20",
            "INVOICE ORBIT 3003\nDATE 08/21/2026\nTOTAL 410.00"
        ]
        let images = receiptTexts.map(makeReceiptImage)
        try ScanPDFRenderer().render(images: images, to: scan)
        let originalScan = try Data(contentsOf: scan)

        let recognition = try await VisionOCRService().recognize(
            url: scan,
            configuration: OCRRecognitionConfiguration(
                languageMode: .selected,
                languageIdentifiers: [
                    OCRRecognitionLanguage.english.rawValue
                ],
                customWords: ["ACME", "NORTHSTAR", "ORBIT"]
            )
        )
        let normalizedText = recognition.text.uppercased()
        XCTAssertTrue(normalizedText.contains("INVOICE"))
        XCTAssertTrue(normalizedText.contains("1280.50"))
        XCTAssertEqual(recognition.pages.count, 3)

        try SearchablePDFService().createSearchableCopy(
            sourceURL: scan,
            ocrResult: recognition,
            destination: searchable
        )
        let searchableDocument = try XCTUnwrap(
            PDFDocument(url: searchable)
        )
        XCTAssertEqual(searchableDocument.pageCount, 3)
        XCTAssertTrue(
            searchableDocument.string?.uppercased()
                .contains("NORTHSTAR") == true
        )

        let index = DocumentTextIndex(
            source: .vision,
            pages: recognition.pages.map {
                IndexedPageText(
                    pageIndex: $0.pageIndex,
                    text: $0.text
                )
            },
            indexedAt: Date()
        )
        let evidence = try XCTUnwrap(
            PDFOutputService().exportText(
                sourceURL: scan,
                destination: workbook,
                textIndex: index,
                title: "August 2026 expense packet",
                format: .excelWorkbook
            )
        )
        XCTAssertEqual(evidence.outputPageCount, 3)
        XCTAssertEqual(evidence.searchablePageCount, 3)
        let archive = try StoredZIPArchiveFixture(
            data: Data(contentsOf: workbook)
        )
        try archive.validateXMLAndRelationships()
        let worksheetText = archive.entries
            .filter { $0.key.hasPrefix("xl/worksheets/") }
            .values
            .reduce(into: Data()) { $0.append($1) }
        XCTAssertNotNil(
            worksheetText.range(of: Data("1280.50".utf8))
        )

        let store = DocumentStore(
            rootURL: temporaryDirectory
                .appendingPathComponent("BookkeepingStore")
        )
        var record = try await store.importPDF(
            from: searchable,
            preferredName: "2026-08 Expense Packet",
            preserveSourceLocation: false
        )
        record = try await store.updateTags(
            record,
            tags: ["2026", "Expenses", "August"],
            expectedTags: record.tags
        )
        record = try await store.updatePrivateNote(
            record,
            note: "Matched to August ledger.",
            expectedNote: record.privateNote
        )
        XCTAssertEqual(record.tags, ["2026", "Expenses", "August"])
        XCTAssertEqual(
            record.privateNote,
            "Matched to August ledger."
        )

        let privateURL = await store.url(for: record)
        try PDFOutputService().protect(
            sourceURL: privateURL,
            destination: protected,
            password: "ledger-2026"
        )
        let protectionReceipt = try PDFDeliveryAuditService().audit(
            sourceURL: privateURL,
            outputURL: protected,
            operation: .protected,
            unlockPassword: "ledger-2026"
        )
        XCTAssertTrue(protectionReceipt.isVerified)
        XCTAssertTrue(protectionReceipt.isEncrypted)
        XCTAssertEqual(protectionReceipt.outputPageCount, 3)
        XCTAssertEqual(try Data(contentsOf: scan), originalScan)
    }

    func testProfessionalWorkflow_operationsCoordinatorCompletesSignedHandoff()
        throws {
        let original = temporaryDirectory
            .appendingPathComponent("vendor-acceptance-original.pdf")
        let working = temporaryDirectory
            .appendingPathComponent("vendor-acceptance-working.pdf")
        let appendix = temporaryDirectory
            .appendingPathComponent("scope-appendix.pdf")
        let package = temporaryDirectory
            .appendingPathComponent("vendor-handoff-package.pdf")
        let verified = temporaryDirectory
            .appendingPathComponent("vendor-handoff-verified.pdf")
        try DemoPDFBuilder.create(at: original)
        let originalData = try Data(contentsOf: original)
        try FileManager.default.copyItem(at: original, to: working)

        let workingDocument = try XCTUnwrap(PDFDocument(url: working))
        let recipientField = try XCTUnwrap(
            workingDocument.page(at: 0)?.annotations.first {
                $0.fieldName == "Recipient name"
            }
        )
        recipientField.widgetStringValue = "Jordan Lee"
        guard workingDocument.write(to: working) else {
            return XCTFail("Could not save the completed form.")
        }
        let signatureBounds = PDFNormalizedRect(
            x: 0.49,
            y: 0.81,
            width: 0.36,
            height: 0.08
        )
        try PDFMutationService().addInk(
            PDFInkPayload(
                pageIndex: 1,
                strokes: [
                    PDFInkStroke(
                        points: [
                            PDFInkPoint(x: 0.08, y: 0.72),
                            PDFInkPoint(x: 0.31, y: 0.24),
                            PDFInkPoint(x: 0.52, y: 0.68),
                            PDFInkPoint(x: 0.86, y: 0.18)
                        ]
                    )
                ],
                placement: .signature,
                normalizedBounds: signatureBounds
            ),
            in: working
        )
        let formReport = try PDFFormInspectionService().inspect(
            url: working
        )
        XCTAssertTrue(
            formReport.incompleteRequiredFields.isEmpty,
            formReport.incompleteRequiredFields
                .map(\.name)
                .joined(separator: ", ")
        )

        try makePDF(
            at: appendix,
            pages: ["Scope appendix: implementation and acceptance criteria"]
        )
        try PDFCompositionService().combine(
            urls: [working, appendix],
            to: package
        )
        try PDFOutputService().safeShare(
            sourceURL: package,
            destination: verified
        )
        let receipt = try PDFDeliveryAuditService().audit(
            sourceURL: package,
            outputURL: verified,
            operation: .safeShare
        )
        XCTAssertTrue(receipt.isVerified)
        XCTAssertEqual(receipt.outputPageCount, 3)
        XCTAssertEqual(receipt.renderedPageCount, 3)
        XCTAssertEqual(receipt.annotationCount, 0)
        XCTAssertEqual(receipt.personalMetadataEntryCount, 0)
        XCTAssertEqual(receipt.sha256.count, 64)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
    }

    private func makeReceiptImage(_ text: String) -> UIImage {
        let size = CGSize(width: 1_600, height: 2_200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            let border = UIBezierPath(
                roundedRect: CGRect(
                    x: 90,
                    y: 100,
                    width: 1_420,
                    height: 2_000
                ),
                cornerRadius: 24
            )
            border.lineWidth = 8
            border.stroke()
            text.draw(
                in: CGRect(
                    x: 180,
                    y: 420,
                    width: 1_240,
                    height: 1_000
                ),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(
                        ofSize: 92,
                        weight: .bold
                    ),
                    .foregroundColor: UIColor.black
                ]
            )
        }
    }

    private func solidJPEG(
        color: UIColor,
        size: CGSize
    ) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    private func makeClassicImagePDF(
        at url: URL,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]

        func appendObject(
            _ number: Int,
            prefix: String,
            stream: Data? = nil
        ) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n\(prefix)".utf8))
            if let stream {
                data.append(Data("\nstream\n".utf8))
                data.append(stream)
                data.append(Data("\nendstream".utf8))
            }
            data.append(Data("\nendobj\n".utf8))
        }

        appendObject(
            1,
            prefix: "<< /Type /Catalog /Pages 2 0 R >>"
        )
        appendObject(
            2,
            prefix: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        )
        appendObject(
            3,
            prefix: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << /ProcSet [/PDF /ImageC] /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>
            """
        )
        let commands = Data(
            "q\n220 0 0 140 100 300 cm\n/Im1 Do\nQ\n".utf8
        )
        appendObject(
            4,
            prefix: "<< /Length \(commands.count) >>",
            stream: commands
        )
        appendObject(
            5,
            prefix: """
            << /Type /XObject /Subtype /Image /Width \(pixelWidth) /Height \(pixelHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>
            """,
            stream: jpegData
        )

        let xrefOffset = data.count
        data.append(Data("xref\n0 6\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for number in 1...5 {
            data.append(
                Data(
                    String(
                        format: "%010d 00000 n \n",
                        offsets[number] ?? 0
                    ).utf8
                )
            )
        }
        data.append(
            Data(
                """
                trailer
                << /Size 6 /Root 1 0 R >>
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8
            )
        )
        try data.write(to: url, options: .atomic)
    }

    private func makeClassicRepeatedImagePDF(
        at url: URL,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]

        func appendObject(
            _ number: Int,
            prefix: String,
            stream: Data? = nil
        ) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n\(prefix)".utf8))
            if let stream {
                data.append(Data("\nstream\n".utf8))
                data.append(stream)
                data.append(Data("\nendstream".utf8))
            }
            data.append(Data("\nendobj\n".utf8))
        }

        appendObject(
            1,
            prefix: "<< /Type /Catalog /Pages 2 0 R >>"
        )
        appendObject(
            2,
            prefix:
                "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"
        )
        appendObject(
            3,
            prefix: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << /ProcSet [/PDF /ImageC] /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>
            """
        )
        let firstCommands = Data(
            "q\n220 0 0 140 100 300 cm\n/Im1 Do\nQ\n".utf8
        )
        appendObject(
            4,
            prefix: "<< /Length \(firstCommands.count) >>",
            stream: firstCommands
        )
        appendObject(
            5,
            prefix: """
            << /Type /XObject /Subtype /Image /Width \(pixelWidth) /Height \(pixelHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>
            """,
            stream: jpegData
        )
        appendObject(
            6,
            prefix: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << /ProcSet [/PDF /ImageC] /XObject << /Im1 5 0 R >> >> /Contents 7 0 R >>
            """
        )
        let secondCommands = Data(
            "q\n180 0 0 120 160 360 cm\n/Im1 Do\nQ\n".utf8
        )
        appendObject(
            7,
            prefix: "<< /Length \(secondCommands.count) >>",
            stream: secondCommands
        )

        let xrefOffset = data.count
        data.append(Data("xref\n0 8\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for number in 1...7 {
            data.append(
                Data(
                    String(
                        format: "%010d 00000 n \n",
                        offsets[number] ?? 0
                    ).utf8
                )
            )
        }
        data.append(
            Data(
                """
                trailer
                << /Size 8 /Root 1 0 R >>
                startxref
                \(xrefOffset)
                %%EOF
                """.utf8
            )
        )
        try data.write(to: url, options: .atomic)
    }

    private func makeXRefStreamImagePDF(
        at url: URL,
        jpegData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        var data = Data("%PDF-1.7\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n".utf8)
        var offsets: [Int: Int] = [:]

        func appendObject(
            _ number: Int,
            prefix: String,
            stream: Data? = nil
        ) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n\(prefix)".utf8))
            if let stream {
                data.append(Data("\nstream\n".utf8))
                data.append(stream)
                data.append(Data("\nendstream".utf8))
            }
            data.append(Data("\nendobj\n".utf8))
        }

        appendObject(
            1,
            prefix: "<< /Type /Catalog /Pages 2 0 R >>"
        )
        appendObject(
            2,
            prefix: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        )
        appendObject(
            3,
            prefix: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>
            """
        )
        let commands = Data(
            "q\n220 0 0 140 100 300 cm\n/Im1 Do\nQ\n".utf8
        )
        appendObject(
            4,
            prefix: "<< /Length \(commands.count) >>",
            stream: commands
        )
        appendObject(
            5,
            prefix: """
            << /Type /XObject /Subtype /Image /Width \(pixelWidth) /Height \(pixelHeight) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>
            """,
            stream: jpegData
        )

        let xrefOffset = data.count
        offsets[6] = xrefOffset
        var xref = Data()
        func appendBigEndian(_ value: UInt64, width: Int) {
            for shift in stride(
                from: (width - 1) * 8,
                through: 0,
                by: -8
            ) {
                xref.append(
                    UInt8(truncatingIfNeeded: value >> shift)
                )
            }
        }
        for number in 0...6 {
            if number == 0 {
                appendBigEndian(0, width: 1)
                appendBigEndian(0, width: 4)
                appendBigEndian(65_535, width: 2)
            } else {
                appendBigEndian(1, width: 1)
                appendBigEndian(
                    UInt64(offsets[number] ?? 0),
                    width: 4
                )
                appendBigEndian(0, width: 2)
            }
        }
        let compressed = try zlibWrapped(xref)
        appendObject(
            6,
            prefix: """
            << /Type /XRef /Size 7 /Root 1 0 R /W [1 4 2] /Index [0 7] /Filter /FlateDecode /Length \(compressed.count) >>
            """,
            stream: compressed
        )
        data.append(
            Data(
                """
                startxref
                \(xrefOffset)
                %%EOF
                """.utf8
            )
        )
        try data.write(to: url, options: .atomic)
    }

    private func makeFormFlateImagePDF(at url: URL) throws {
        let rgb = Data([
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            255, 255, 0,
            0, 255, 255,
            255, 0, 255,
            48, 48, 48,
            230, 230, 230
        ])
        let alpha = Data([
            0, 85, 170, 255,
            255, 170, 85, 0
        ])
        let compressedRGB = try zlibWrapped(rgb)
        let compressedAlpha = try zlibWrapped(alpha)
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]

        func appendObject(
            _ number: Int,
            prefix: String,
            stream: Data? = nil
        ) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n\(prefix)".utf8))
            if let stream {
                data.append(Data("\nstream\n".utf8))
                data.append(stream)
                data.append(Data("\nendstream".utf8))
            }
            data.append(Data("\nendobj\n".utf8))
        }

        appendObject(
            1,
            prefix: "<< /Type /Catalog /Pages 2 0 R >>"
        )
        appendObject(
            2,
            prefix: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        )
        appendObject(
            3,
            prefix: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << /XObject << /Fm1 5 0 R >> >> /Contents 4 0 R >>
            """
        )
        let pageCommands = Data(
            "q\n240 0 0 120 96 320 cm\n/Fm1 Do\nQ\n".utf8
        )
        appendObject(
            4,
            prefix: "<< /Length \(pageCommands.count) >>",
            stream: pageCommands
        )
        let formCommands = Data(
            "q\n1 0 0 1 0 0 cm\n/Im1 Do\nQ\n".utf8
        )
        appendObject(
            5,
            prefix: """
            << /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /Im1 6 0 R >> >> /Length \(formCommands.count) >>
            """,
            stream: formCommands
        )
        appendObject(
            6,
            prefix: """
            << /Type /XObject /Subtype /Image /Width 4 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 7 0 R /Filter /FlateDecode /Length \(compressedRGB.count) >>
            """,
            stream: compressedRGB
        )
        appendObject(
            7,
            prefix: """
            << /Type /XObject /Subtype /Image /Width 4 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length \(compressedAlpha.count) >>
            """,
            stream: compressedAlpha
        )

        let xrefOffset = data.count
        data.append(Data("xref\n0 8\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for number in 1...7 {
            data.append(
                Data(
                    String(
                        format: "%010d 00000 n \n",
                        offsets[number] ?? 0
                    ).utf8
                )
            )
        }
        data.append(
            Data(
                """
                trailer
                << /Size 8 /Root 1 0 R >>
                startxref
                \(xrefOffset)
                %%EOF
                """.utf8
            )
        )
        try data.write(to: url, options: .atomic)
    }

    private func zlibWrapped(_ data: Data) throws -> Data {
        let rawDeflate = try (data as NSData)
            .compressed(using: .zlib) as Data
        var result = Data([0x78, 0x9c])
        result.append(rawDeflate)
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

    private func syntheticDocumentPhoto() -> UIImage {
        let size = CGSize(width: 900, height: 1_200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: size,
            format: format
        ).image { context in
            UIColor(white: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let path = UIBezierPath()
            path.move(to: CGPoint(x: 105, y: 82))
            path.addLine(to: CGPoint(x: 818, y: 132))
            path.addLine(to: CGPoint(x: 780, y: 1_116))
            path.addLine(to: CGPoint(x: 126, y: 1_074))
            path.close()
            context.cgContext.saveGState()
            context.cgContext.setShadow(
                offset: CGSize(width: 16, height: 18),
                blur: 22,
                color: UIColor.black.withAlphaComponent(0.65).cgColor
            )
            UIColor(white: 0.96, alpha: 1).setFill()
            path.fill()
            context.cgContext.restoreGState()

            UIColor.darkGray.setStroke()
            for line in 0..<12 {
                let y = CGFloat(220 + line * 58)
                let inset = CGFloat(line % 3) * 22
                let linePath = UIBezierPath()
                linePath.move(
                    to: CGPoint(x: 190 + inset, y: y)
                )
                linePath.addLine(
                    to: CGPoint(x: 700 - inset, y: y + 4)
                )
                linePath.lineWidth = line == 0 ? 12 : 6
                linePath.stroke()
            }
        }
    }

    private func makeXFAStubPDF(at url: URL) throws {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]

        func appendObject(
            _ number: Int,
            prefix: String,
            stream: Data? = nil
        ) {
            offsets[number] = data.count
            data.append(Data("\(number) 0 obj\n\(prefix)".utf8))
            if let stream {
                data.append(Data("\nstream\n".utf8))
                data.append(stream)
                data.append(Data("\nendstream".utf8))
            }
            data.append(Data("\nendobj\n".utf8))
        }

        let pageCommands = Data("q\nQ\n".utf8)
        let xfaData = Data(
            "<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"></xdp:xdp>"
                .utf8
        )
        appendObject(
            1,
            prefix: "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>"
        )
        appendObject(
            2,
            prefix: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        )
        appendObject(
            3,
            prefix: """
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents 4 0 R >>
            """
        )
        appendObject(
            4,
            prefix: "<< /Length \(pageCommands.count) >>",
            stream: pageCommands
        )
        appendObject(
            5,
            prefix: "<< /Fields [] /XFA 6 0 R >>"
        )
        appendObject(
            6,
            prefix: "<< /Length \(xfaData.count) >>",
            stream: xfaData
        )

        let xrefOffset = data.count
        data.append(Data("xref\n0 7\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for number in 1...6 {
            data.append(
                Data(
                    String(
                        format: "%010d 00000 n \n",
                        offsets[number] ?? 0
                    ).utf8
                )
            )
        }
        data.append(
            Data(
                """
                trailer
                << /Size 7 /Root 1 0 R >>
                startxref
                \(xrefOffset)
                %%EOF

                """.utf8
            )
        )
        try data.write(to: url, options: .atomic)
    }

    private func makePDF(at url: URL, pages: [String]) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            for (index, text) in pages.enumerated() {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)

                if text.isEmpty {
                    UIColor.systemGray5.setFill()
                    context.fill(
                        CGRect(x: 48, y: 72, width: 516, height: 648)
                    )
                } else {
                    "\(text) \(index)".draw(
                        in: CGRect(x: 56, y: 72, width: 500, height: 200),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 18),
                            .foregroundColor: UIColor.black
                        ]
                    )
                }
            }
        }
    }

    private func textProfile(pageCount: Int) -> DocumentProfile {
        profile(kind: .text, pageCount: pageCount)
    }

    private func profile(
        kind: DocumentKind,
        pageCount: Int,
        isLocked: Bool = false
    ) -> DocumentProfile {
        DocumentProfile(
            pageCount: pageCount,
            sampledPageCount: pageCount,
            textCharacterCount: kind == .scan ? 0 : 100,
            imageDominantPageCount: kind == .scan ? pageCount : 0,
            formFieldCount: kind == .form ? 1 : 0,
            byteCount: 1_024,
            isEncrypted: isLocked,
            isLocked: isLocked,
            allowsCopying: true,
            allowsCommenting: true,
            kind: kind,
            recommendedActions: [.inspect, .shareCopy]
        )
    }

    private func deliveryReceipt(
        operation: PDFDeliveryOperation
    ) -> PDFDeliveryReceipt {
        PDFDeliveryReceipt(
            id: UUID(),
            operation: operation,
            createdAt: Date(),
            sourcePageCount: 2,
            outputPageCount: 2,
            renderedPageCount: 2,
            sourceByteCount: 1_024,
            outputByteCount: 1_024,
            unexpectedBlankPageIndices: [],
            annotationCount: 0,
            textCharacterCount: 0,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: String(repeating: "a", count: 64),
            checks: [
                PDFDeliveryCheck(
                    id: "reopened",
                    title: "Output reopened",
                    detail: "Output passed local verification.",
                    status: .passed
                )
            ]
        )
    }
}

private final class TestUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(value: TimeInterval) {
        self.value = value
    }

    func read() -> TimeInterval {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value += interval
        }
    }
}

@MainActor
private final class TestMetadataKeyValueStore:
    PDFMetadataKeyValueStore {
    let isCloudBacked: Bool
    var storage: [String: Data] = [:]
    var isAvailable = true

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
        isAvailable
    }
}

private final class ProcessMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var isRunning = false
    private var peak: UInt64 = 0

    func start() {
        lock.lock()
        isRunning = true
        peak = currentResidentMemory()
        lock.unlock()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            while running {
                let current = currentResidentMemory()
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

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func currentResidentMemory() -> UInt64 {
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
