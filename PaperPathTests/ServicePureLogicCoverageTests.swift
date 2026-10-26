import CryptoKit
import CoreImage
import Darwin
import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PaperPath

@MainActor
final class ReleaseExperienceLogicTests: XCTestCase {
    // Restore every preference we touch: these tests share the host application.
    private func withHistory(_ body: (UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["commerce.verifiedOutputCount", "commerce.lastVerifiedOutputAt",
                    "commerce.lastVerifiedFailureAt", "experience.ratingRequested"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        try body(defaults)
    }

    func testRatingRequiresTwoSuccessfulOutputsAndOnlyRequestsOnce() {
        withHistory { _ in
            XCTAssertFalse(AppEntitlement.shouldRequestRating)
            XCTAssertEqual(AppEntitlement.recordVerifiedOutput(), 1)
            XCTAssertFalse(AppEntitlement.shouldRequestRating)
            XCTAssertEqual(AppEntitlement.recordVerifiedOutput(), 2)
            XCTAssertTrue(AppEntitlement.shouldRequestRating)
            AppEntitlement.markRatingRequested()
            AppEntitlement.recordVerifiedOutput()
            XCTAssertFalse(AppEntitlement.shouldRequestRating)
        }
    }

    func testRatingSuppressedAfterFailureUntilLaterSuccess() {
        withHistory { defaults in
            defaults.set(2, forKey: "commerce.verifiedOutputCount")
            let now = Date()
            defaults.set(now.addingTimeInterval(-60), forKey: "commerce.lastVerifiedOutputAt")
            defaults.set(now, forKey: "commerce.lastVerifiedFailureAt")
            XCTAssertFalse(AppEntitlement.shouldRequestRating)
            defaults.set(now.addingTimeInterval(-120), forKey: "commerce.lastVerifiedFailureAt")
            XCTAssertTrue(AppEntitlement.shouldRequestRating)
            defaults.set(now.addingTimeInterval(-60), forKey: "commerce.lastVerifiedFailureAt")
            XCTAssertFalse(AppEntitlement.shouldRequestRating, "Equal timestamps must fail closed")
        }
    }

    func testRatingRejectsMissingMalformedAndImplausibleSuccessDates() {
        withHistory { defaults in
            defaults.set(2, forKey: "commerce.verifiedOutputCount")
            XCTAssertFalse(AppEntitlement.shouldRequestRating)
            let invalidDates: [Any] = ["invalid", Date(timeIntervalSince1970: -1),
                                       Date().addingTimeInterval(3600)]
            for invalid in invalidDates {
                defaults.set(invalid, forKey: "commerce.lastVerifiedOutputAt")
                XCTAssertFalse(AppEntitlement.shouldRequestRating)
            }
        }
    }

    func testRatingRejectsImplausibleFailureDates() {
        withHistory { defaults in
            defaults.set(2, forKey: "commerce.verifiedOutputCount")
            defaults.set(Date(), forKey: "commerce.lastVerifiedOutputAt")
            for invalid in [Date(timeIntervalSince1970: -1), Date().addingTimeInterval(3600)] {
                defaults.set(invalid, forKey: "commerce.lastVerifiedFailureAt")
                XCTAssertFalse(AppEntitlement.shouldRequestRating)
            }
        }
    }

    func testOutputHistoryClampsCorruptCountsAndSaturates() {
        withHistory { defaults in
            defaults.set(-100, forKey: "commerce.verifiedOutputCount")
            XCTAssertEqual(AppEntitlement.verifiedOutputCount, 0)
            XCTAssertEqual(AppEntitlement.recordVerifiedOutput(), 1)
            defaults.set(Int.max, forKey: "commerce.verifiedOutputCount")
            XCTAssertEqual(AppEntitlement.verifiedOutputCount, 1_000_000)
            XCTAssertEqual(AppEntitlement.recordVerifiedOutput(), 1_000_000)
            AppEntitlement.recordVerifiedFailure()
            XCTAssertNotNil(defaults.object(forKey: "commerce.lastVerifiedFailureAt") as? Date)
            XCTAssertFalse(AppEntitlement.shouldRequestRating)
        }
    }

    func testDefaultsRegistrationPreservesExplicitUserChoices() throws {
        let suite = "ReleaseExperience-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppPreferences.metadataSyncEnabledKey)
        defaults.set(true, forKey: AppPreferences.dueRemindersEnabledKey)
        defaults.set("economy", forKey: AppPreferences.previewQualityKey)
        AppPreferences.registerDefaults(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: AppPreferences.metadataSyncEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: AppPreferences.dueRemindersEnabledKey))
        XCTAssertEqual(defaults.string(forKey: AppPreferences.previewQualityKey), "economy")
    }

    func testUnknownPreviewPreferenceFallsBackToBoundedAutomaticMode() {
        let defaults = UserDefaults.standard
        let key = AppPreferences.previewQualityKey
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.set("removed-quality", forKey: key)
        XCTAssertEqual(ThumbnailPreviewQuality.selected, .automatic)
        for quality in ThumbnailPreviewQuality.allCases {
            XCTAssertGreaterThan(quality.renderScale, 0)
            XCTAssertLessThanOrEqual(quality.renderScale, 2)
            XCTAssertGreaterThan(quality.cacheEntryLimit, 0)
            XCTAssertLessThanOrEqual(quality.cacheEntryLimit, 72)
            XCTAssertLessThanOrEqual(quality.cacheByteLimit, 18 * 1024 * 1024)
            XCTAssertLessThanOrEqual(quality.cacheDocumentLimit, 3)
        }
    }

    func testDiagnosticBundleContainsOnlyDeclaredAggregateFieldsAndIsDiscarded() throws {
        let url = try SupportBundleService.create(
            documentCount: 7, deletedCount: 2, pageCount: 31, localByteCount: 8192,
            indexedDocumentCount: 4, ocrDocumentCount: 3, receiptCount: 1,
            metadataSyncState: "idle")
        defer { SupportBundleService.discard(url) }
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["generatedAt", "app", "device", "library", "settings", "privacy"])
        let library = try XCTUnwrap(json["library"] as? [String: Int])
        XCTAssertEqual(library, ["documentCount": 7, "trashCount": 2, "pageCount": 31,
                                 "allocatedPDFBytes": 8192, "indexedDocumentCount": 4,
                                 "ocrDocumentCount": 3, "receiptCount": 1])
        let privacy = try XCTUnwrap(json["privacy"] as? [String: Bool])
        XCTAssertEqual(Set(privacy.keys), ["containsPDFBytes", "containsFileNames",
                        "containsExtractedText", "containsPasswords", "containsSignatures"])
        XCTAssertTrue(privacy.values.allSatisfy { !$0 })
        let app = try XCTUnwrap(json["app"] as? [String: String])
        XCTAssertEqual(app["version"], Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        SupportBundleService.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        SupportBundleService.discard(url) // Repeated cancellation/cleanup must be safe.
        SupportBundleService.discard(nil)
    }

    func testDiagnosticDiscardCannotRemoveUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Unrelated-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keep.json")
        try Data("private".utf8).write(to: url)
        SupportBundleService.discard(url)
        XCTAssertEqual(try Data(contentsOf: url), Data("private".utf8))
    }
}

final class ServicePureLogicCoverageTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-ServiceLogic-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testInsufficientStorageRecognitionIncludesQuotaAndNestedErrors_BitsUT() {
        XCTAssertTrue(
            LocalFileSecurity.isInsufficientStorageError(
                POSIXError(.ENOSPC)
            )
        )
        XCTAssertTrue(
            LocalFileSecurity.isInsufficientStorageError(
                NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EDQUOT)
                )
            )
        )
        XCTAssertTrue(
            LocalFileSecurity.isInsufficientStorageError(
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileWriteUnknown.rawValue,
                    userInfo: [
                        NSUnderlyingErrorKey: NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(ENOSPC)
                        )
                    ]
                )
            )
        )
        XCTAssertFalse(
            LocalFileSecurity.isInsufficientStorageError(
                POSIXError(.EACCES)
            )
        )
    }

    func testPDFObjectSyntaxHandlesStringsArraysAndReferences_BitsUT()
        throws {
        XCTAssertNil(pdfDecodedString(Data()))
        XCTAssertNil(pdfDecodedString(Data("name".utf8)))
        XCTAssertNil(pdfDecodedString(Data("<GG>".utf8)))
        XCTAssertNil(pdfDecodedString(Data("(trailing\\)".utf8)))
        XCTAssertEqual(pdfDecodedString(Data("<48656c6c6f>".utf8)), "Hello")
        XCTAssertEqual(pdfDecodedString(Data("<414>".utf8)), "A@")
        XCTAssertEqual(
            pdfDecodedString(Data("<FEFF00410042>".utf8)),
            "AB"
        )
        XCTAssertEqual(
            pdfDecodedString(Data("<FFFE41004200>".utf8)),
            "AB"
        )
        XCTAssertEqual(
            pdfDecodedString(
                Data(#"(a\nb\rc\td\b\f\(\)\\\101\q)"#.utf8)
            ),
            "a\nb\rc\td\u{08}\u{0c}()\\Aq"
        )
        XCTAssertEqual(
            pdfDecodedString(Data([0x28, 0xff, 0x29])),
            "\u{00ff}"
        )
        XCTAssertEqual(pdfDecodedString(Data("(a\\\nb)".utf8)), "ab")
        XCTAssertEqual(pdfDecodedString(Data("(a\\\r\nb)".utf8)), "ab")
        XCTAssertTrue(pdfUTF16HexString("Review").hasPrefix("<FEFF"))

        let source = Data(
            """
            12 0 obj
            << /Title (Old\\) title)
               /Array [1 (two) << /Nested <4142> >> % ignored ]
                       3]
               /Reference 3 0 R
               /Flag true
            >>
            endobj
            trailer
            """.utf8
        )
        XCTAssertEqual(pdfInteger(following: "/Reference", in: String(
            decoding: source,
            as: UTF8.self
        )), 3)
        XCTAssertEqual(
            pdfTopLevelString(for: "Title", in: source),
            "Old) title"
        )
        let dictionary = try XCTUnwrap(pdfFirstDictionaryRange(in: source))
        let arrayRange = try XCTUnwrap(
            pdfTopLevelValueRange(
                for: "Array",
                in: source,
                dictionaryRange: dictionary
            )
        )
        XCTAssertEqual(
            String(decoding: source[arrayRange], as: UTF8.self)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            "[1 (two) << /Nested <4142> >> % ignored ] 3]"
        )

        let updated = try pdfObject(
            source,
            setting: "Title",
            to: Data("(New)".utf8)
        )
        XCTAssertEqual(pdfTopLevelString(for: "Title", in: updated), "New")
        let inserted = try pdfObject(
            source,
            setting: "Added",
            to: Data("[4 5]".utf8)
        )
        XCTAssertNotNil(
            pdfTopLevelValueRange(
                for: "Added",
                in: inserted,
                dictionaryRange: try XCTUnwrap(
                    pdfFirstDictionaryRange(in: inserted)
                )
            )
        )
        let removed = try pdfObject(source, removing: "Reference")
        XCTAssertFalse(String(decoding: removed, as: UTF8.self).contains(
            "/Reference"
        ))
        XCTAssertEqual(
            try pdfObject(source, removing: "Missing"),
            Data(source[..<(try XCTUnwrap(
                source.range(
                    of: Data("endobj".utf8),
                    options: .backwards
                )
            ).upperBound)])
        )
        XCTAssertThrowsError(
            try pdfObject(Data("<< /A 1 >>".utf8), removing: "A")
        )
        XCTAssertThrowsError(
            try pdfObject(
                Data("12 0 obj\nnot-a-dictionary\nendobj".utf8),
                setting: "A",
                to: Data("1".utf8)
            )
        )

        let composite = Data("<< /A [1 [2] (]) <5D> % ]\n 3] >>".utf8)
        let compositeRange = try XCTUnwrap(
            pdfFirstDictionaryRange(in: composite)
        )
        XCTAssertEqual(compositeRange.lowerBound, 0)
        let nestedStart = try XCTUnwrap(composite.firstIndex(of: 0x5b))
        XCTAssertNotNil(
            pdfArrayEnd(
                in: composite,
                start: nestedStart,
                limit: composite.count
            )
        )
        XCTAssertNil(
            pdfArrayEnd(in: composite, start: 0, limit: composite.count)
        )
        XCTAssertNil(
            pdfArrayEnd(
                in: Data("[1 2".utf8),
                start: 0,
                limit: 4
            )
        )
        XCTAssertTrue([0, 9, 10, 12, 13, 32].allSatisfy {
            pdfIsWhitespace(UInt8($0))
        })
        XCTAssertTrue([40, 41, 60, 62, 91, 93, 123, 125, 47, 37]
            .allSatisfy { pdfIsDelimiter(UInt8($0)) })
        XCTAssertFalse(pdfIsDelimiter(65))
    }

    func testFormAutomationParserAndFormatterMatrix_BitsUT() throws {
        let service = PDFFormAutomationService()
        let operations: [(String, PDFFormCalculationOperation)] = [
            ("SUM", .sum),
            ("PRD", .product),
            ("AVG", .average),
            ("MIN", .minimum),
            ("MAX", .maximum)
        ]
        for (name, operation) in operations {
            XCTAssertEqual(service.calculationOperation(name), operation)
            XCTAssertEqual(
                service.parseCalculation(
                    "AFSimple_Calculate(\"\(name)\", "
                        + "new Array(\"A\", \"B\"));"
                )?.operation,
                operation
            )
            XCTAssertNotNil(
                service.evaluatedValue(operation, values: [2, 4, 8])
            )
        }
        XCTAssertNil(service.calculationOperation("MEDIAN"))
        XCTAssertNil(service.parseCalculation("alert('unsafe')"))
        XCTAssertNil(
            service.parseCalculation(
                "AFSimple_Calculate(\"SUM\", new Array());"
            )
        )

        let number = try XCTUnwrap(
            service.parseFormat(
                #"AFNumber_Format(2, 0, 2, 0, "$", true);"#
            )
        )
        let european = try XCTUnwrap(
            service.parseFormat(
                #"AFNumber_Format(2, 2, 0, 0, "EUR ", true);"#
            )
        )
        let swiss = try XCTUnwrap(
            service.parseFormat(
                #"AFNumber_Format(2, 4, 0, 0, "CHF ", false);"#
            )
        )
        let percent = try XCTUnwrap(
            service.parseFormat("AFPercent_Format(1, 1);")
        )
        XCTAssertEqual(
            service.parseNumericValue("$1,234.50", format: number),
            1_234.5
        )
        XCTAssertEqual(
            service.parseNumericValue("EUR 1.234,50", format: european),
            1_234.5
        )
        XCTAssertEqual(
            service.parseNumericValue("1'234.50CHF ", format: swiss),
            1_234.5
        )
        XCTAssertEqual(
            service.parseNumericValue("12.5%", format: percent),
            0.125
        )
        XCTAssertEqual(service.parseNumericValue("(42)", format: nil), -42)
        XCTAssertEqual(service.parseNumericValue("1,25", format: nil), 1.25)
        XCTAssertEqual(service.parseNumericValue("1,234", format: nil), 1234)
        XCTAssertNil(service.parseNumericValue("not-a-number", format: nil))
        XCTAssertEqual(
            service.formattedValue(-1_234.5, format: number),
            "($1,234.50)"
        )
        XCTAssertEqual(
            service.formattedValue(0.125, format: percent),
            "12.5%"
        )
        XCTAssertNotNil(service.formattedValue(1_234.5, format: european))
        XCTAssertNotNil(service.formattedValue(1_234.5, format: swiss))

        let date = try XCTUnwrap(
            service.parseFormat(#"AFDate_FormatEx("mm/dd/yyyy");"#)
        )
        let time = try XCTUnwrap(
            service.parseFormat(#"AFTime_FormatEx("HH:MM:ss");"#)
        )
        XCTAssertEqual(
            service.normalizedDateOrTime("08/27/2026", format: date),
            "08/27/2026"
        )
        XCTAssertEqual(
            service.normalizedDateOrTime("23:59:58", format: time),
            "23:59:58"
        )
        XCTAssertNil(
            service.normalizedDateOrTime("02/31/2026", format: date)
        )
        XCTAssertNil(
            service.parseFormat(#"AFDate_FormatEx("yyyy-MM-dd");"#)
        )

        for script in [
            #"AFNumber_Keystroke(2, 0, 0, 0, "$", true);"#,
            "AFPercent_Keystroke(2, 0);",
            #"AFDate_KeystrokeEx("mm/dd/yyyy");"#,
            #"AFTime_KeystrokeEx("h:MM tt");"#
        ] {
            XCTAssertTrue(service.isRecognizedKeystroke(script))
        }
        XCTAssertFalse(service.isRecognizedKeystroke("alert('unsafe')"))
        XCTAssertFalse(service.isRecognizedKeystroke(
            "AFNumber_Keystroke(99, 0, 0, 0, \"\", true);"
        ))

        XCTAssertEqual(
            service.javaScriptStringArray(#"["A", "B"]"#),
            ["A", "B"]
        )
        XCTAssertEqual(service.javaScriptStringArray(#""A""#), ["A"])
        XCTAssertNil(service.javaScriptStringArray("[\"A\", invalid]"))
        XCTAssertEqual(service.javaScriptString(#""a\nb\"c""#), "a\nb\"c")
        XCTAssertNil(service.javaScriptString(#""bad\x""#))
        XCTAssertNil(service.javaScriptString("unquoted"))
        XCTAssertEqual(service.integer(" 42 "), 42)
        XCTAssertEqual(service.double(" 1.25 "), 1.25)
        XCTAssertNil(service.double("inf"))
        XCTAssertEqual(service.boolean(" TRUE "), true)
        XCTAssertEqual(service.boolean("false"), false)
        XCTAssertNil(service.boolean("yes"))
        XCTAssertEqual(service.normalizedName(" Résumé "), "resume")
        XCTAssertTrue(service.isSafeSingleLineText(
            "Invoice",
            maximumCharacters: 20,
            maximumBytes: 40
        ))
        XCTAssertFalse(service.isSafeSingleLineText(
            "bad\nline",
            maximumCharacters: 20,
            maximumBytes: 40
        ))
        XCTAssertNil(service.finiteSum([
            Double.greatestFiniteMagnitude,
            Double.greatestFiniteMagnitude
        ]))
        XCTAssertNil(service.evaluatedValue(.sum, values: []))
        XCTAssertNil(service.evaluatedValue(
            .product,
            values: [Double.greatestFiniteMagnitude, 2]
        ))
        XCTAssertTrue(service.numbersMatch(1, 1.000_000_01))
        XCTAssertFalse(service.numbersMatch(.infinity, 1))
        XCTAssertEqual(service.canonicalNumber(42), "42")
        XCTAssertTrue(
            service.canonicalNumber(0.000_000_000_1)
                .lowercased()
                .contains("e")
        )
        XCTAssertEqual(service.canonicalNumber(.infinity), "")

        let utf16BE = Data([0xfe, 0xff, 0x00, 0x41])
        let utf16LE = Data([0xff, 0xfe, 0x41, 0x00])
        XCTAssertEqual(service.decodedScript(utf16BE), "A")
        XCTAssertEqual(service.decodedScript(utf16LE), "A")
        XCTAssertEqual(service.decodedScript(Data("script".utf8)), "script")
        XCTAssertNil(service.boundedScript(String(repeating: "x", count: 131_073)))
        XCTAssertEqual(service.boundedScript("safe"), "safe")

        XCTAssertNotNil(service.parseRangeValidation(
            "AFRange_Validate(true, -10, true, 10);"
        ))
        XCTAssertNil(service.parseRangeValidation(
            "AFRange_Validate(true, 10, true, -10);"
        ))
    }

    func testOCRReadingOrderAndConfigurationContracts_BitsUT() throws {
        let service = VisionOCRService()
        func block(
            _ text: String,
            x: Double,
            y: Double,
            width: Double = 0.2,
            confidence: Double = 0.9
        ) -> OCRTextBlock {
            OCRTextBlock(
                text: text,
                confidence: confidence,
                normalizedX: x,
                normalizedY: y,
                normalizedWidth: width,
                normalizedHeight: 0.05
            )
        }

        let twoColumns = [
            block("Header", x: 0.1, y: 0.92, width: 0.8),
            block("L1", x: 0.1, y: 0.8),
            block("L2", x: 0.1, y: 0.6),
            block("L3", x: 0.1, y: 0.4),
            block("R1", x: 0.7, y: 0.8),
            block("R2", x: 0.7, y: 0.6),
            block("R3", x: 0.7, y: 0.4)
        ]
        XCTAssertTrue(service.hasTwoColumns(twoColumns))
        XCTAssertEqual(
            service.readingOrder(twoColumns).map(\.text),
            ["Header", "L1", "L2", "L3", "R1", "R2", "R3"]
        )
        XCTAssertFalse(service.hasTwoColumns(Array(twoColumns.prefix(4))))
        XCTAssertEqual(
            service.columnOrder(Array(twoColumns.dropFirst())).map(\.text),
            ["L1", "L2", "L3", "R1", "R2", "R3"]
        )
        XCTAssertTrue(service.lineOrder(
            block("left", x: 0.1, y: 0.5),
            block("right", x: 0.7, y: 0.5)
        ))

        let strong = OCRPageResult(
            pageIndex: 0,
            text: String(repeating: "A", count: 100),
            confidence: 0.95,
            blocks: [block("Strong", x: 0.1, y: 0.5)]
        )
        let weak = OCRPageResult(
            pageIndex: 0,
            text: "short",
            confidence: 0.4,
            blocks: [block("Weak", x: 0.1, y: 0.5, confidence: 0.2)]
        )
        let conciseStrong = OCRPageResult(
            pageIndex: 0,
            text: "Approved",
            confidence: 0.96,
            blocks: [block("Approved", x: 0.1, y: 0.5, confidence: 0.96)]
        )
        XCTAssertFalse(service.shouldRetry(strong))
        XCTAssertFalse(service.shouldRetry(conciseStrong))
        XCTAssertTrue(service.shouldRetry(weak))
        XCTAssertGreaterThan(
            service.recognitionScore(strong),
            service.recognitionScore(weak)
        )

        let configuration = try service.validated(
            OCRRecognitionConfiguration(
                languageMode: .automatic,
                languageIdentifiers: ["en-US"],
                customWords: [" Invoice ", "invoice", "", "Total"]
            )
        )
        XCTAssertTrue(configuration.languageIdentifiers.isEmpty)
        XCTAssertEqual(configuration.customWords, ["Invoice", "Total"])
        XCTAssertThrowsError(
            try service.validated(
                OCRRecognitionConfiguration(
                    languageMode: .automatic,
                    languageIdentifiers: [],
                    customWords: [String(repeating: "x", count: 65)]
                )
            )
        )
    }

    func testDOCXVisualBudgetsAndBlankPageExport_BitsUT() throws {
        let source = temporaryDirectory.appendingPathComponent("visual.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: source) { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(bounds)
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 60, y: 120, width: 320, height: 180))
        }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let geometry = try XCTUnwrap(PDFOfficePageGeometry(page: page))
        XCTAssertFalse(geometry.isLandscape)
        XCTAssertGreaterThan(geometry.aspectRatio, 0)

        for pageCount in [1, 50, 500, 1_000] {
            let budget = DOCXVisualReferenceBudget(pageCount: pageCount)
            for priority in [
                DOCXVisualReferencePriority.critical,
                .image,
                .table
            ] {
                XCTAssertGreaterThan(priority.minimumByteFloor, 0)
                XCTAssertGreaterThan(priority.reserveBytesPerLaterCandidate, 0)
                XCTAssertGreaterThan(
                    priority.byteMultiplier(
                        hasStructuredText: priority != .critical,
                        hasTable: priority == .table,
                        hasEmbeddedImage: priority == .image
                    ),
                    0
                )
                XCTAssertGreaterThan(
                    budget.byteLimitForPage(
                        hasStructuredText: priority != .critical,
                        hasTable: priority == .table,
                        hasEmbeddedImage: priority == .image,
                        priority: priority,
                        remainingTotalBytes: 8 * 1_024 * 1_024,
                        remainingCandidateCount: 10
                    ),
                    0
                )
                XCTAssertGreaterThan(
                    budget.remainingCandidateWindow(
                        pageIndex: 0,
                        pageCount: pageCount,
                        priority: priority
                    ),
                    0
                )
            }
        }

        XCTAssertEqual(
            DOCXVisualReferencePriority.classify(
                hasStructuredText: false,
                hasTable: false,
                hasEmbeddedImage: false
            ),
            .critical
        )
        XCTAssertEqual(
            DOCXVisualReferencePriority.classify(
                hasStructuredText: true,
                hasTable: false,
                hasEmbeddedImage: true
            ),
            .image
        )
        XCTAssertEqual(
            DOCXVisualReferencePriority.classify(
                hasStructuredText: true,
                hasTable: true,
                hasEmbeddedImage: false
            ),
            .table
        )

        let destination = temporaryDirectory
            .appendingPathComponent("visual.docx")
        let progress = TestServiceProgressRecorder()
        let runtime = try DOCXExportService().export(
            sourceURL: source,
            destination: destination,
            textIndex: nil,
            title: "Visual fallback",
            progress: { progress.append($0) }
        )
        XCTAssertEqual(runtime.sourcePageCount, 1)
        XCTAssertEqual(runtime.outputPageCount, 1)
        XCTAssertEqual(runtime.assetCount, 1)
        XCTAssertGreaterThan(runtime.assetByteCount, 0)
        XCTAssertEqual(progress.values.last, 1)

        let raster = UIGraphicsImageRenderer(
            size: CGSize(width: 240, height: 160)
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 200, height: 120))
        }
        let imageSource = temporaryDirectory.appendingPathComponent(
            "embedded-image.pdf"
        )
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: imageSource) {
            context in
            context.beginPage()
            raster.draw(in: CGRect(x: 72, y: 120, width: 360, height: 240))
        }
        let imageDestination = temporaryDirectory.appendingPathComponent(
            "embedded-image.docx"
        )
        let imageRuntime = try DOCXExportService().export(
            sourceURL: imageSource,
            destination: imageDestination,
            textIndex: nil,
            title: "Embedded image",
            progress: { _ in }
        )
        XCTAssertEqual(imageRuntime.outputPageCount, 1)
        XCTAssertEqual(imageRuntime.assetCount, 1)
    }

    func testDOCXStructureAndXMLContracts_BitsUT() throws {
        let service = DOCXExportService()
        let pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let header = DOCXLine(
            text: "Item",
            bounds: CGRect(x: 40, y: 700, width: 500, height: 20),
            fontSize: 14,
            isBold: true,
            isItalic: false,
            cells: [
                DOCXCellCandidate(
                    text: "Item",
                    bounds: CGRect(x: 40, y: 700, width: 180, height: 20)
                ),
                DOCXCellCandidate(
                    text: "Amount",
                    bounds: CGRect(x: 320, y: 700, width: 120, height: 20)
                )
            ]
        )
        let row = DOCXLine(
            text: "Hosting $10",
            bounds: CGRect(x: 42, y: 670, width: 500, height: 20),
            fontSize: 11,
            isBold: false,
            isItalic: true,
            cells: [
                DOCXCellCandidate(
                    text: "Hosting",
                    bounds: CGRect(x: 42, y: 670, width: 180, height: 20)
                ),
                DOCXCellCandidate(
                    text: "$10",
                    bounds: CGRect(x: 322, y: 670, width: 120, height: 20)
                )
            ]
        )
        XCTAssertTrue(service.tableRowsAlign(
            header,
            row,
            pageWidth: pageBounds.width
        ))
        XCTAssertFalse(service.tableRowsAlign(
            header,
            DOCXLine(
                text: "Only one",
                bounds: row.bounds,
                fontSize: 11,
                isBold: false,
                isItalic: false,
                cells: [row.cells[0]]
            ),
            pageWidth: pageBounds.width
        ))
        let table = service.table(
            from: [header, row],
            pageBounds: pageBounds
        )
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertTrue(table.rows[0].repeatsAsHeader)
        XCTAssertEqual(table.columnWidths.count, 2)

        let titleLine = DOCXLine(
            text: "Quarterly Report",
            bounds: CGRect(x: 150, y: 750, width: 300, height: 30),
            fontSize: 22,
            isBold: true,
            isItalic: false,
            cells: []
        )
        let bodyLine = DOCXLine(
            text: "A wrapped exam-",
            bounds: CGRect(x: 50, y: 650, width: 480, height: 16),
            fontSize: 11,
            isBold: false,
            isItalic: false,
            cells: []
        )
        let continuation = DOCXLine(
            text: "ple.",
            bounds: CGRect(x: 50, y: 632, width: 480, height: 16),
            fontSize: 11,
            isBold: false,
            isItalic: false,
            cells: []
        )
        XCTAssertTrue(service.isHeading(titleLine, bodySize: 11))
        XCTAssertTrue(service.looksLikeListItem("1. First"))
        XCTAssertTrue(service.looksLikeListItem("- First"))
        XCTAssertFalse(service.looksLikeListItem("Plain"))
        XCTAssertTrue(service.endsParagraph("Done!"))
        XCTAssertFalse(service.endsParagraph("Pending"))
        XCTAssertEqual(service.median([]), 11)
        XCTAssertEqual(service.median([10, 14]), 12)
        XCTAssertEqual(service.median([10, 14, 20]), 14)
        XCTAssertTrue(service.startsNewParagraph(
            titleLine,
            after: bodyLine,
            paragraphStart: bodyLine,
            bodySize: 11
        ))

        let paragraph = try XCTUnwrap(service.paragraph(
            from: [bodyLine, continuation],
            bodySize: 11,
            pageBounds: pageBounds
        ))
        XCTAssertEqual(paragraph.text, "A wrapped exam-ple.")
        XCTAssertEqual(paragraph.style.wordStyle, "Normal")
        let softHyphenLine = DOCXLine(
            text: "A wrapped exam\u{00ad}",
            bounds: bodyLine.bounds,
            fontSize: bodyLine.fontSize,
            isBold: false,
            isItalic: false,
            cells: []
        )
        let softHyphenParagraph = try XCTUnwrap(service.paragraph(
            from: [softHyphenLine, continuation],
            bodySize: 11,
            pageBounds: pageBounds
        ))
        XCTAssertEqual(softHyphenParagraph.text, "A wrapped example.")
        XCTAssertEqual(
            service.inferredAlignment(
                bounds: titleLine.bounds,
                pageBounds: pageBounds
            ).rawValue,
            "center"
        )
        XCTAssertEqual(
            service.inferredAlignment(
                bounds: CGRect(x: 400, y: 20, width: 180, height: 20),
                pageBounds: pageBounds
            ).rawValue,
            "right"
        )
        XCTAssertEqual(
            service.inferredAlignment(
                bounds: CGRect(x: 30, y: 20, width: 180, height: 20),
                pageBounds: pageBounds
            ).rawValue,
            "left"
        )

        let fallback = service.fallbackParagraphs(
            from: "First line\nsecond line\n\n- Item\n\n"
        )
        XCTAssertEqual(fallback.count, 2)
        XCTAssertEqual(fallback[0].text, "First line second line")
        XCTAssertEqual(fallback[1].style.wordStyle, "ListParagraph")
        let blocks = service.paragraphBlocks(
            from: [titleLine, bodyLine, continuation],
            bodySize: 11,
            pageBounds: pageBounds
        )
        XCTAssertGreaterThanOrEqual(blocks.count, 2)

        let image = DOCXImage(
            relationshipID: "rId3",
            fileName: "page-1.jpg",
            data: Data([0xff, 0xd8, 0xff, 0xd9]),
            widthEMU: 1_000,
            heightEMU: 2_000,
            description: "Page <1>"
        )
        let docxPage = DOCXPage(
            pageIndex: 0,
            blocks: [
                .paragraph(paragraph),
                .table(table)
            ],
            visualReference: image,
            layout: .letterPortrait
        )
        XCTAssertTrue(
            service.paragraphXML(
                paragraph,
                pageBreakBefore: true
            ).contains("pageBreakBefore")
        )
        XCTAssertTrue(
            service.blockXML(
                .table(table),
                pageBreakBefore: true
            ).contains("<w:tbl>")
        )
        XCTAssertTrue(service.tableXML(table).contains("<w:tblHeader/>"))
        XCTAssertTrue(
            service.imageXML(
                image,
                documentID: 1,
                pageBreakBefore: true
            ).contains("rId3")
        )
        XCTAssertTrue(
            try service.wordDocumentXML(pages: [docxPage])
                .contains("<w:document")
        )
        XCTAssertThrowsError(
            try service.wordDocumentXML(
                pages: [docxPage],
                maximumUTF8Bytes: 128
            )
        )
        XCTAssertTrue(
            service.sectionPropertiesXML(
                .letterPortrait,
                startsNextPage: true
            ).contains("nextPage")
        )
        XCTAssertTrue(
            service.documentRelationshipsXML(images: [image])
                .contains("page-1.jpg")
        )
        XCTAssertTrue(
            service.corePropertiesXML(title: "A&B")
                .contains("A&amp;B")
        )
        XCTAssertEqual(
            service.xmlEscaped("<&>\"'\u{01}"),
            "&lt;&amp;&gt;&quot;&apos;"
        )
        XCTAssertEqual(
            ooxmlEscaped("<&>\"'\u{01}"),
            "&lt;&amp;&gt;&quot;&apos;"
        )

        let blockStats = DOCXBlockStats(blocks: docxPage.blocks)
        let structuralElementCount = blockStats.paragraphCount
            + blockStats.tableCount
            + blockStats.tableRowCount
            + blockStats.tableCellCount
        var contentBudget = DOCXContentBudget(
            maximumPageUTF16Units: paragraph.text.utf16.count,
            maximumCharacterCount: blockStats.characterCount,
            maximumStructuralElementCount: structuralElementCount
        )
        try contentBudget.validatePageText(paragraph.text)
        try contentBudget.consume(blockStats)
        XCTAssertEqual(
            contentBudget.characterCount,
            blockStats.characterCount
        )
        XCTAssertEqual(
            contentBudget.structuralElementCount,
            structuralElementCount
        )
        XCTAssertThrowsError(
            try contentBudget.consume(blockStats)
        )
        XCTAssertThrowsError(
            try contentBudget.validatePageText(paragraph.text + "x")
        )

        var archiveBudget = OOXMLArchivePayloadBudget(maximumBytes: 8)
        try archiveBudget.consume(5)
        XCTAssertEqual(archiveBudget.consumedBytes, 5)
        XCTAssertThrowsError(try archiveBudget.consume(4))
        XCTAssertEqual(archiveBudget.consumedBytes, 5)

        var profile = DocumentProfile.empty
        profile.pageCount = 2
        profile.sampledPageCount = 2
        profile.textCharacterCount = 200
        let portfolio = PDFOfficeExportPortfolio(profile: profile)
        var metrics = DOCXReconstructionMetrics(
            sourcePageCount: 2,
            officePortfolio: portfolio,
            visualBudgetMode: .highDetail,
            visualLongestEdge: 1_600,
            visualCompressionQualityPercent: 80,
            visualMaximumBytesPerPage: 1_000_000
        )
        metrics.recordVisualCandidate(
            priority: .critical,
            pageBudget: 400_000,
            windowWasLimited: true
        )
        metrics.recordVisualCandidate(
            priority: .image,
            pageBudget: 300_000,
            windowWasLimited: false
        )
        metrics.recordVisualCandidate(
            priority: .table,
            pageBudget: 200_000,
            windowWasLimited: false
        )
        let visual = DOCXVisualReferenceResult(
            image: image,
            priority: .critical,
            attemptCount: 2,
            acceptedQualityPercent: 70,
            acceptedLongestEdge: 1_280,
            byteCount: 4
        )
        metrics.recordPage(
            blockStats: DOCXBlockStats(blocks: docxPage.blocks),
            usedFallbackText: true,
            visualReferenceResult: visual
        )
        metrics.recordSkippedVisualReference(.totalBudgetExhausted)
        metrics.recordSkippedVisualReference(.pageBudgetExceeded)
        metrics.recordSkippedVisualReference(.renderFailed)
        XCTAssertEqual(metrics.pageYieldPercent, 50)
        XCTAssertEqual(metrics.structuredCoveragePercent, 100)
        XCTAssertEqual(metrics.visualAnchorHitPercent, 33)
        XCTAssertFalse(metrics.reconstructionSummary.isEmpty)
        XCTAssertFalse(metrics.visualSkipReasonSummary.isEmpty)
        XCTAssertEqual(metrics.runtimeEvidence.assetCount, 1)
        XCTAssertTrue(
            service.customPropertiesXML(metrics: metrics)
                .contains("PaperPathReconstructionSummary")
        )
    }

    func testAuditSamplingAndSecurePasteboardContracts_BitsUT() async throws {
        let short = PDFDeliveryAuditService.SnapshotOptions.preflight(
            pageCount: 8
        )
        XCTAssertNil(short.renderedPageIndices)
        let long = PDFDeliveryAuditService.SnapshotOptions.preflight(
            pageCount: 500
        )
        XCTAssertEqual(long.renderedPageIndices?.count, 24)
        for pageCount in [50, 150, 350, 700, 2_500, 10_001] {
            let options = PDFDeliveryAuditService.SnapshotOptions.comparison(
                pageCount: pageCount
            )
            XCTAssertGreaterThan(options.visualSampleSide, 0)
            XCTAssertGreaterThan(options.maximumTextFragments, 0)
            XCTAssertGreaterThan(options.detailedTextPageStride, 0)
        }

        await MainActor.run {
            let pasteboard = UIPasteboard.general
            SecurePasteboard.clearIfOwned()
            XCTAssertFalse(SecurePasteboard.copy(""))
            let countBeforeOwnedCopy = pasteboard.changeCount
            XCTAssertTrue(SecurePasteboard.copy("PaperPath"))
            let ownedChangeCount = pasteboard.changeCount
            XCTAssertGreaterThan(ownedChangeCount, countBeforeOwnedCopy)
            SecurePasteboard.clearIfOwned()
            XCTAssertGreaterThan(
                pasteboard.changeCount,
                ownedChangeCount
            )
            XCTAssertFalse(SecurePasteboard.isOwnedContentCurrent)

            XCTAssertTrue(SecurePasteboard.copy("Owned"))
            pasteboard.setItems([
                [UTType.utf8PlainText.identifier: "External"]
            ])
            let externalChangeCount = pasteboard.changeCount
            SecurePasteboard.clearIfOwned()
            XCTAssertEqual(
                pasteboard.changeCount,
                externalChangeCount
            )
            pasteboard.items = []
        }
    }

    func testAuditAlignmentAndDifferenceAlgorithms_BitsUT() throws {
        let service = PDFDeliveryAuditService()
        let region = PDFDifferenceRegion(
            x: 0.1,
            y: 0.2,
            width: 0.2,
            height: 0.1,
            intensity: 0.5
        )
        func character(
            _ text: String,
            x: Double
        ) -> PDFDeliveryAuditService.CharacterFragment {
            PDFDeliveryAuditService.CharacterFragment(
                text: text,
                region: PDFDifferenceRegion(
                    x: x,
                    y: 0.2,
                    width: 0.05,
                    height: 0.1,
                    intensity: 1
                )
            )
        }
        func fragment(
            _ text: String,
            characters: [PDFDeliveryAuditService.CharacterFragment]
        ) -> PDFDeliveryAuditService.TextFragment {
            PDFDeliveryAuditService.TextFragment(
                text: text,
                normalized: text.lowercased(),
                comparison: text,
                region: region,
                characters: characters
            )
        }
        func page(
            _ key: String?,
            label: Data? = nil,
            marker: Data? = nil,
            barcode: Data? = nil,
            size: CGSize = CGSize(width: 612, height: 792),
            rotation: Int = 0,
            visual: [UInt8] = Array(repeating: 0, count: 108),
            alignment: [UInt8] = [0, 0, 0, 0]
        ) -> PDFDeliveryAuditService.PageSnapshot {
            PDFDeliveryAuditService.PageSnapshot(
                rendered: true,
                coverage: 0.2,
                annotationCount: 0,
                textCharacterCount: key?.count ?? 0,
                textFingerprint: key.map { Data($0.utf8) } ?? Data(),
                textFragments: [],
                pageLabelFingerprint: label,
                stableMarkerFingerprint: marker,
                barcodeFingerprint: barcode,
                pageSize: size,
                rotation: rotation,
                visualSamples: visual,
                alignmentSamples: alignment
            )
        }

        XCTAssertEqual(
            service.normalizedText("  Résumé\n  review  "),
            "Résumé review"
        )
        XCTAssertEqual(service.normalizedToken(" Résumé "), "resume")
        XCTAssertEqual(service.comparisonToken(" Résumé "), "Résumé")
        let normalizedRegion = service.normalizedRegion(
            CGRect(x: 10, y: 20, width: 30, height: 40),
            in: CGRect(x: 0, y: 0, width: 100, height: 200)
        )
        XCTAssertEqual(normalizedRegion.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(normalizedRegion.y, 0.7, accuracy: 0.0001)
        XCTAssertNil(service.pageLabelFingerprint(nil, pageIndex: 0))
        XCTAssertNil(service.pageLabelFingerprint("Page 1", pageIndex: 0))
        XCTAssertNotNil(
            service.pageLabelFingerprint("Appendix A", pageIndex: 0)
        )

        let markerFragment = fragment(
            "INV-1234",
            characters: [character("I", x: 0.1)]
        )
        XCTAssertNotNil(service.stableMarkerFingerprint([markerFragment]))
        XCTAssertNil(service.stableMarkerFingerprint([
            fragment("abc", characters: [])
        ]))

        let a = Data("A".utf8)
        let b = Data("B".utf8)
        let grouped = try service.keyIndexGroups([a, nil, a, b])
        XCTAssertEqual(grouped[a], [0, 2])
        XCTAssertEqual(grouped[b], [3])
        let unique = try service.uniqueKeyIndices([a, nil, a, b])
        XCTAssertNil(unique[a])
        XCTAssertEqual(unique[b], 3)

        let exactA = page("abcdefgh-A")
        let exactB = page("abcdefgh-B")
        let inserted = page(
            nil,
            label: Data("inserted-label".utf8),
            visual: Array(repeating: 255, count: 108),
            alignment: [255, 255, 255, 255]
        )
        XCTAssertNotNil(service.pageAnchorKey(exactA))
        XCTAssertNotNil(service.pageAnchorKey(inserted))
        XCTAssertNil(service.pageAnchorKey(.empty))

        let aligned = try service.alignedPages(
            source: [exactA, exactB],
            revised: [exactA, inserted, exactB]
        )
        XCTAssertEqual(aligned.count, 3)
        XCTAssertEqual(aligned.map(\.sourceIndex), [0, nil, 1])
        XCTAssertEqual(aligned.map(\.revisedIndex), [0, 1, 2])

        let emptySource = try service.alignSegment(
            source: [],
            sourceRange: 0..<0,
            revised: [inserted],
            revisedRange: 0..<1
        )
        XCTAssertNil(emptySource.first?.sourceIndex)
        let emptyRevised = try service.alignSegment(
            source: [exactA],
            sourceRange: 0..<1,
            revised: [],
            revisedRange: 0..<0
        )
        XCTAssertNil(emptyRevised.first?.revisedIndex)
        let oversizedAlignment = try service.alignSegment(
            source: Array(repeating: .empty, count: 501),
            sourceRange: 0..<501,
            revised: Array(repeating: .empty, count: 500),
            revisedRange: 0..<500
        )
        XCTAssertEqual(oversizedAlignment.count, 501)

        let candidates = [
            PDFDeliveryAuditService.AnchorCandidate(
                source: 0,
                revised: 2,
                basis: .exactContent
            ),
            PDFDeliveryAuditService.AnchorCandidate(
                source: 1,
                revised: 0,
                basis: .pageLabel
            ),
            PDFDeliveryAuditService.AnchorCandidate(
                source: 2,
                revised: 1,
                basis: .textMarker
            )
        ]
        let increasing = try service.longestIncreasingAnchors(candidates)
        XCTAssertEqual(increasing.map(\.revised), [0, 1])
        XCTAssertTrue(service.repeatedAnchor(
            sourceIndex: 1,
            revisedIndex: 1,
            isCompatibleWith: [
                .init(source: 0, revised: 0, basis: .exactContent),
                .init(source: 2, revised: 2, basis: .exactContent)
            ]
        ))
        XCTAssertFalse(service.repeatedAnchor(
            sourceIndex: 1,
            revisedIndex: 2,
            isCompatibleWith: [
                .init(source: 0, revised: 0, basis: .exactContent),
                .init(source: 2, revised: 2, basis: .exactContent)
            ]
        ))
        XCTAssertEqual(
            try service.contextualAnchorKeys(
                pages: [exactA],
                keys: []
            ),
            [nil]
        )
        XCTAssertEqual(
            try service.contextualAnchorKeys(
                pages: [exactA, exactA, exactB],
                keys: [a, a, b]
            ).compactMap { $0 }.count,
            3
        )

        let sourceCharacters = [
            character("a", x: 0.1),
            character("b", x: 0.2),
            character("c", x: 0.3)
        ]
        let revisedCharacters = [
            character("a", x: 0.1),
            character("x", x: 0.2),
            character("c", x: 0.3)
        ]
        let characterRuns = service.characterDifferenceRuns(
            source: sourceCharacters,
            revised: revisedCharacters
        )
        XCTAssertEqual(characterRuns.count, 1)
        XCTAssertEqual(
            service.characterEvidence(
                characterRuns[0].source,
                kind: .removed
            )?.text,
            "b"
        )
        XCTAssertNil(service.characterEvidence([], kind: .removed))

        let longSource = (0..<65).map {
            character($0 == 32 ? "x" : "a", x: Double($0) / 100)
        }
        let longRevised = (0..<65).map {
            character($0 == 32 ? "y" : "a", x: Double($0) / 100)
        }
        XCTAssertEqual(
            service.characterDifferenceRuns(
                source: longSource,
                revised: longRevised
            ).count,
            1
        )
        XCTAssertTrue(service.prefixSuffixCharacterDifferenceRuns(
            source: [],
            revised: revisedCharacters
        ).isEmpty)

        let located = service.locatedTextDifferences(
            source: [fragment("abc", characters: sourceCharacters)],
            revised: [fragment("axc", characters: revisedCharacters)]
        )
        XCTAssertEqual(located.source.first?.text, "b")
        XCTAssertEqual(located.revised.first?.text, "x")

        let merged = service.union(
            region,
            PDFDifferenceRegion(
                x: 0.2,
                y: 0.1,
                width: 0.4,
                height: 0.3,
                intensity: 0.9
            )
        )
        XCTAssertEqual(merged.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(merged.intensity, 0.9, accuracy: 0.0001)

        XCTAssertEqual(
            service.visualDifference([], [], channels: 3).meanDifference,
            1
        )
        XCTAssertEqual(
            service.visualDifference(
                [0, 0, 0, 255, 255, 255],
                [0, 0, 0, 0, 0, 0]
            ).changedPixelRatio,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            service.detailedVisualDifference([], []).meanDifference,
            1
        )
        let changedVisual = Array(repeating: UInt8(255), count: 108)
        XCTAssertGreaterThan(
            service.detailedVisualDifference(
                Array(repeating: 0, count: 108),
                changedVisual
            ).changedPixelRatio,
            0.9
        )
        XCTAssertFalse(service.pageGeometryChanged(exactA, exactA))
        XCTAssertTrue(service.pageGeometryChanged(
            exactA,
            page(
                "abcdefgh-A",
                size: CGSize(width: 792, height: 612),
                rotation: 90
            )
        ))
        XCTAssertEqual(service.pageSimilarityScore(exactA, exactA), 6)
        XCTAssertLessThan(service.pageSimilarityScore(exactA, inserted), 6)

        XCTAssertNil(try service.pageChange(
            sequenceIndex: 0,
            sourceIndex: 0,
            revisedIndex: 0,
            source: exactA,
            revised: exactA,
            matchBasis: .exactContent
        ))
        XCTAssertEqual(
            try service.pageChange(
                sequenceIndex: 0,
                sourceIndex: nil,
                revisedIndex: 0,
                source: nil,
                revised: inserted,
                matchBasis: nil
            )?.resolvedMatchKind,
            .inserted
        )
        XCTAssertNotNil(try service.pageChange(
            sequenceIndex: 0,
            sourceIndex: 0,
            revisedIndex: 0,
            source: exactA,
            revised: inserted,
            matchBasis: .similarity
        ))

        let sourceSnapshot = PDFDeliveryAuditService.Snapshot(
            pageCount: 2,
            renderedPageCount: 2,
            renderAttemptedPageCount: 2,
            renderedPageIndices: [0, 1],
            contentCoverage: [0.2, 0.2],
            annotationCount: 0,
            textCharacterCount: 20,
            personalMetadataEntryCount: 0,
            pages: [exactA, exactB]
        )
        let revisedSnapshot = PDFDeliveryAuditService.Snapshot(
            pageCount: 3,
            renderedPageCount: 3,
            renderAttemptedPageCount: 3,
            renderedPageIndices: [0, 1, 2],
            contentCoverage: [0.2, 0.4, 0.2],
            annotationCount: 0,
            textCharacterCount: 20,
            personalMetadataEntryCount: 0,
            pages: [exactA, inserted, exactB]
        )
        let review = try service.changeReview(
            source: sourceSnapshot,
            revised: revisedSnapshot
        )
        XCTAssertEqual(review.insertedPages.count, 1)
        XCTAssertEqual(
            service.changeReviewCheck(
                review,
                operation: .bookletPrepared
            ).status,
            .passed
        )
        XCTAssertNotEqual(
            service.changeReviewCheck(
                review,
                operation: .safeShare
            ).status,
            .passed
        )
        XCTAssertEqual(service.pageList([0]), "Review page 1")
        XCTAssertEqual(
            service.pageList(Array(0..<10)),
            "Review pages 1, 2, 3, 4, 5, 6, 7, 8"
        )
    }

    func testDocumentStoreRecoversInterruptedTransactions_BitsUT()
        async throws {
        func fingerprint(_ data: Data) -> String {
            SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        }
        func jsonData(_ value: Any) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
            )
        }
        let now = ISO8601DateFormatter().string(from: Date())

        let protectedRoot = temporaryDirectory.appendingPathComponent(
            "ProtectedRecovery",
            isDirectory: true
        )
        let textIndexDirectory = protectedRoot.appendingPathComponent(
            "TextIndex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: textIndexDirectory,
            withIntermediateDirectories: true
        )
        let replacedID = UUID()
        let replacedDestination = textIndexDirectory
            .appendingPathComponent("\(replacedID.uuidString).json")
        let replacedBackup = textIndexDirectory
            .appendingPathComponent(".rollback-\(UUID().uuidString)")
        let replacedStaging = textIndexDirectory
            .appendingPathComponent(".protected-\(UUID().uuidString)")
        let original = Data("original".utf8)
        let staged = Data("replacement".utf8)
        try staged.write(to: replacedDestination)
        try original.write(to: replacedBackup)
        try Data("unused-stage".utf8).write(to: replacedStaging)

        let createdID = UUID()
        let createdDestination = textIndexDirectory
            .appendingPathComponent("\(createdID.uuidString).json")
        let createdStaging = textIndexDirectory
            .appendingPathComponent(".protected-\(UUID().uuidString)")
        let created = Data("new-value".utf8)
        try created.write(to: createdDestination)
        try Data("unused-stage".utf8).write(to: createdStaging)

        let protectedJournal = [
            "id": UUID().uuidString,
            "createdAt": now,
            "entries": [
                [
                    "destinationPath": replacedDestination.path,
                    "backupPath": replacedBackup.path,
                    "stagingPath": replacedStaging.path,
                    "originalFingerprint": fingerprint(original),
                    "stagedFingerprint": fingerprint(staged)
                ],
                [
                    "destinationPath": createdDestination.path,
                    "stagingPath": createdStaging.path,
                    "stagedFingerprint": fingerprint(created)
                ]
            ]
        ] as [String: Any]
        try jsonData(protectedJournal).write(
            to: protectedRoot.appendingPathComponent(
                "active-protected-data-transaction.json"
            )
        )

        let protectedStore = DocumentStore(rootURL: protectedRoot)
        try await protectedStore.recoverInterruptedProtectedDataTransaction()
        XCTAssertEqual(
            try Data(contentsOf: replacedDestination),
            original
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: createdDestination.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: replacedStaging.path)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: protectedRoot.appendingPathComponent(
                "active-protected-data-transaction.json"
            ).path
        ))

        let workingRoot = temporaryDirectory.appendingPathComponent(
            "WorkingRecovery",
            isDirectory: true
        )
        let documentsDirectory = workingRoot.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )
        let documentID = UUID()
        let destination = documentsDirectory
            .appendingPathComponent("\(documentID.uuidString).pdf")
        let backup = documentsDirectory
            .appendingPathComponent(".batch-rollback-\(UUID().uuidString)")
        let staging = documentsDirectory
            .appendingPathComponent(".batch-\(UUID().uuidString)")
        let originalPDF = Data("%PDF-1.4\noriginal\n%%EOF".utf8)
        try Data("%PDF-1.4\nchanged\n%%EOF".utf8).write(to: destination)
        try originalPDF.write(to: backup)
        try Data("%PDF-1.4\nstaged\n%%EOF".utf8).write(to: staging)
        let workingJournal = [
            "id": UUID().uuidString,
            "createdAt": now,
            "entries": [
                [
                    "destinationPath": destination.path,
                    "backupPath": backup.path,
                    "stagingPath": staging.path,
                    "backupFingerprint": fingerprint(originalPDF)
                ]
            ]
        ] as [String: Any]
        try jsonData(workingJournal).write(
            to: workingRoot.appendingPathComponent(
                "active-working-copy-transaction.json"
            )
        )

        let workingStore = DocumentStore(rootURL: workingRoot)
        try await workingStore.recoverInterruptedWorkingCopyTransaction()
        XCTAssertEqual(try Data(contentsOf: destination), originalPDF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let invalidRoot = temporaryDirectory.appendingPathComponent(
            "InvalidRecovery",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: invalidRoot,
            withIntermediateDirectories: true
        )
        let invalidJournal = [
            "id": UUID().uuidString,
            "createdAt": now,
            "entries": []
        ] as [String: Any]
        try jsonData(invalidJournal).write(
            to: invalidRoot.appendingPathComponent(
                "active-protected-data-transaction.json"
            )
        )
        let invalidStore = DocumentStore(rootURL: invalidRoot)
        var rejectedInvalidJournal = false
        do {
            try await invalidStore
                .recoverInterruptedProtectedDataTransaction()
        } catch {
            rejectedInvalidJournal = true
        }
        XCTAssertTrue(rejectedInvalidJournal)
    }

    func testDocumentStoreReconcilesOrphanedVersionFiles_BitsUT()
        async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "VersionReconciliation",
            isDirectory: true
        )
        let store = DocumentStore(rootURL: root)
        _ = try await store.load()

        let versionDirectory = root
            .appendingPathComponent("Versions", isDirectory: true)
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: versionDirectory,
            withIntermediateDirectories: true
        )
        let orphan = versionDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf")
        let pending = versionDirectory
            .appendingPathComponent(".\(UUID().uuidString).pending")
        let unrelated = versionDirectory.appendingPathComponent("notes.txt")
        try Data(repeating: 1, count: 512).write(to: orphan)
        try Data(repeating: 2, count: 256).write(to: pending)
        try Data("keep".utf8).write(to: unrelated)

        let snapshot = try await store.storageSnapshot()
        XCTAssertEqual(snapshot.versionStorageHealth.indexedVersionCount, 0)
        XCTAssertEqual(
            snapshot.versionStorageHealth.removedOrphanFileCount,
            2
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPDFOutputLayoutAndLabelAlgorithms_BitsUT() throws {
        let service = PDFOutputService()
        let outlineSourceURL = temporaryDirectory.appendingPathComponent(
            "outline-source.pdf"
        )
        let outlineDestinationURL = temporaryDirectory.appendingPathComponent(
            "outline-destination.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: outlineSourceURL,
            pageCount: 2
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: outlineDestinationURL,
            pageCount: 2
        )
        let outlineSource = try XCTUnwrap(
            PDFDocument(url: outlineSourceURL)
        )
        let outlineDestination = try XCTUnwrap(
            PDFDocument(url: outlineDestinationURL)
        )
        service.copyOutline(
            from: PDFDocument(),
            to: outlineDestination
        )
        let rootOutline = PDFOutline()
        let firstOutline = PDFOutline()
        firstOutline.label = "First"
        firstOutline.destination = PDFDestination(
            page: try XCTUnwrap(outlineSource.page(at: 0)),
            at: CGPoint(x: 20, y: 30)
        )
        rootOutline.insertChild(firstOutline, at: 0)
        var parent = firstOutline
        for depth in 0..<26 {
            let child = PDFOutline()
            child.label = "Depth \(depth)"
            parent.insertChild(child, at: 0)
            parent = child
        }
        outlineSource.outlineRoot = rootOutline
        service.copyOutline(
            from: outlineSource,
            to: outlineDestination
        )
        let copiedRoot = try XCTUnwrap(outlineDestination.outlineRoot)
        XCTAssertEqual(copiedRoot.numberOfChildren, 1)
        XCTAssertEqual(copiedRoot.child(at: 0)?.label, "First")
        XCTAssertNotNil(
            copiedRoot.child(at: 0)?.destination?.page
        )
        let outlinedURL = temporaryDirectory.appendingPathComponent(
            "outlined.pdf"
        )
        XCTAssertTrue(outlineSource.write(to: outlinedURL))
        let structureSignature = try PDFDocumentStructureService()
            .preservationSignature(
                in: outlinedURL,
                includePageLabels: true
            )
        XCTAssertFalse(structureSignature.outlineEntries.isEmpty)
        let classicData = try Data(contentsOf: outlineSourceURL)
        let classic = try PDFClassicXRefDocument(data: classicData)
        let rootObject = try XCTUnwrap(classic.rootCatalogObject())
        XCTAssertFalse(classic.objectData(for: rootObject).isEmpty)
        XCTAssertNil(
            classic.object(
                number: rootObject.number,
                generation: rootObject.generation + 1
            )
        )
        XCTAssertNotNil(
            classic.referencedObject(
                following: "/Pages",
                in: rootObject
            )
        )
        XCTAssertNil(classic.imageObject(matching: Data("missing".utf8)))
        XCTAssertNil(
            classic.imageObject(
                matchingDecodedStream: Data("missing".utf8)
            )
        )
        let streamObject = try XCTUnwrap(
            classic.allObjects().first {
                String(
                    decoding: classic.objectData(for: $0),
                    as: UTF8.self
                ).contains("stream")
            }
        )
        XCTAssertFalse(classic.dataForObject(streamObject).isEmpty)
        let rewritten = try classic.replacingObject(
            rootObject,
            with: classic.objectData(for: rootObject)
        )
        XCTAssertNotNil(PDFDocument(data: rewritten))
        let routed = try PDFImageObjectDocument(data: classicData)
        XCTAssertNotNil(routed.rootCatalogObject())
        XCTAssertFalse(routed.allObjects().isEmpty)
        XCTAssertNotNil(routed.object(
            number: rootObject.number,
            generation: rootObject.generation
        ))
        XCTAssertFalse(
            routed.objectData(for: rootObject)?.isEmpty ?? true
        )
        XCTAssertThrowsError(
            try pdfObjectReplacementPlans(
                in: classicData,
                before: classicData.count,
                orderedObjects: classic.allObjects(),
                replacements: []
            )
        )

        let inner = CGRect(x: 10, y: 20, width: 70, height: 50)
        let outer = CGRect(x: 0, y: 0, width: 100, height: 100)
        let insets = service.edgeInsets(inner: inner, outer: outer)
        XCTAssertEqual(insets.top, 30)
        XCTAssertEqual(insets.right, 20)
        XCTAssertEqual(insets.bottom, 20)
        XCTAssertEqual(insets.left, 10)
        XCTAssertEqual(
            service.bleedAllowancePoints(
                trimBox: inner,
                bleedBox: outer
            ),
            [20, 20, 30, 10]
        )
        XCTAssertEqual(
            service.nearestDistance(
                from: inner,
                toInsideOf: outer
            ),
            10
        )
        XCTAssertTrue(service.nearestDistance(
            from: .zero,
            toInsideOf: outer
        ).isInfinite)
        XCTAssertEqual(
            service.standardized(
                CGRect(x: 10, y: 10, width: -5, height: -4)
            ),
            CGRect(x: 5, y: 6, width: 5, height: 4)
        )
        XCTAssertTrue(service.rectsNearlyEqual(
            outer,
            outer.offsetBy(dx: 0.01, dy: -0.01),
            tolerance: 0.02
        ))
        XCTAssertFalse(service.rectsNearlyEqual(
            outer,
            outer.offsetBy(dx: 1, dy: 0),
            tolerance: 0.02
        ))

        let rawOptions = PDFBookletOptions(
            paperTarget: .original,
            bindingEdge: .left,
            outerMarginPoints: 1,
            gutterPoints: 99,
            showsFoldMarks: true,
            signatureSheetLimit: 2,
            creepCompensationPoints: 99
        )
        let options = service.normalizedBookletOptions(rawOptions)
        XCTAssertEqual(options.paperTarget, .a4)
        XCTAssertEqual(options.outerMarginPoints, 12)
        XCTAssertEqual(options.gutterPoints, 48)
        XCTAssertEqual(options.creepCompensationPoints, 18)
        let plans = service.bookletSignaturePlans(
            sourcePageCount: 11,
            options: options
        )
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.map(\.paddedPageCount), [8, 4])
        var unlimited = options
        unlimited.signatureSheetLimit = 0
        XCTAssertEqual(
            service.bookletSignaturePlans(
                sourcePageCount: 5,
                options: unlimited
            ).first?.paddedPageCount,
            8
        )
        let spreads = service.bookletSpreads(
            signaturePlans: plans,
            pageSizes: Array(
                repeating: CGSize(width: 612, height: 792),
                count: 11
            ),
            options: options
        )
        XCTAssertEqual(spreads.count, 6)
        XCTAssertTrue(spreads.contains(where: \.hasBlankSlot))

        let rules = try service.validatedPageLabelRules(
            [
                PDFPageLabelRule(
                    startPageIndex: 3,
                    style: .lowercaseRoman,
                    prefix: "A-",
                    startNumber: 1
                ),
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .decimal,
                    startNumber: 1
                )
            ],
            pageCount: 8
        )
        XCTAssertEqual(rules.map(\.startPageIndex), [0, 3])
        XCTAssertEqual(
            service.expectedPageLabel(pageIndex: 4, rules: rules),
            "A-ii"
        )
        XCTAssertTrue(
            String(
                decoding: service.pdfPageLabelDictionary(rules: rules),
                as: UTF8.self
            ).contains("/Nums")
        )
        XCTAssertThrowsError(try service.validatedPageLabelRules(
            [],
            pageCount: 1
        ))
        XCTAssertThrowsError(try service.validatedPageLabelRules(
            [
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .uppercaseRoman,
                    startNumber: 3_999
                )
            ],
            pageCount: 2
        ))

        let regions = [
            PDFTextFlowRegion(
                pageIndex: 0,
                normalizedX: 0.1,
                normalizedY: 0.1,
                normalizedWidth: 0.4,
                normalizedHeight: 0.2,
                lineCount: 2,
                originalText: "First region",
                sourceRangeLocation: 0,
                sourceRangeLength: 12
            ),
            PDFTextFlowRegion(
                pageIndex: 1,
                normalizedX: 0.2,
                normalizedY: 0.2,
                normalizedWidth: 0.5,
                normalizedHeight: 0.3,
                lineCount: 3,
                originalText: "Second region",
                sourceRangeLocation: 0,
                sourceRangeLength: 13
            )
        ]
        let selection = PDFTextSelectionSnapshot(
            pageIndex: 0,
            originalText: "First region Second region",
            normalizedX: 0.1,
            normalizedY: 0.1,
            normalizedWidth: 0.4,
            normalizedHeight: 0.2,
            fontName: "Helvetica",
            fontSize: 12,
            color: PDFInkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            ),
            lineCount: 5,
            hasMixedFonts: false,
            pageRotation: 0,
            flowRegions: regions
        )
        XCTAssertEqual(
            service.textSelectionBounds(
                selection,
                pageBounds: CGRect(x: 0, y: 0, width: 100, height: 200)
            ),
            CGRect(x: 10, y: 140, width: 40, height: 40)
        )
        XCTAssertEqual(
            service.textFlowBounds(
                regions[1],
                pageBounds: CGRect(x: 0, y: 0, width: 100, height: 200)
            ),
            CGRect(x: 20, y: 100, width: 50, height: 60)
        )
        XCTAssertTrue(service.textFlowRegionsAreOrdered(regions))
        XCTAssertFalse(service.textFlowRegionsAreOrdered(
            [regions[1], regions[0]]
        ))
        let overlapping = [
            PDFTextFlowRegion(
                pageIndex: 0,
                normalizedX: 0,
                normalizedY: 0,
                normalizedWidth: 0.5,
                normalizedHeight: 0.2,
                lineCount: 1,
                originalText: "one",
                sourceRangeLocation: 4,
                sourceRangeLength: 4
            ),
            PDFTextFlowRegion(
                pageIndex: 0,
                normalizedX: 0,
                normalizedY: 0.3,
                normalizedWidth: 0.5,
                normalizedHeight: 0.2,
                lineCount: 1,
                originalText: "two",
                sourceRangeLocation: 2,
                sourceRangeLength: 3
            )
        ]
        XCTAssertFalse(service.textFlowRegionsAreOrdered(overlapping))

        let font = UIFont.systemFont(ofSize: 12)
        let emptyMeasurement = service.replacementFlowMeasurement(
            text: "Text",
            bounds: [],
            font: font,
            lineSpacing: 0,
            alignment: .left
        )
        XCTAssertFalse(emptyMeasurement.fits)
        let measurement = service.replacementFlowMeasurement(
            text: "A short replacement",
            bounds: [CGRect(x: 0, y: 0, width: 240, height: 80)],
            font: font,
            lineSpacing: 1,
            alignment: .center
        )
        XCTAssertTrue(measurement.fits)
        XCTAssertEqual(measurement.regionTexts.count, 1)
        let attempt = try service.fittingReplacementLayout(
            text: "A short replacement",
            selection: selection,
            bounds: [CGRect(x: 0, y: 0, width: 240, height: 80)],
            style: .sans,
            alignment: .right
        )
        XCTAssertNotNil(attempt.layout)
        XCTAssertFalse(service.replacementBoundarySplitsWord(
            "hello world",
            utf16Offset: 5
        ))
        XCTAssertTrue(service.replacementBoundarySplitsWord(
            "helloworld",
            utf16Offset: 5
        ))
        XCTAssertEqual(service.textAlignment(.left), .left)
        XCTAssertEqual(service.textAlignment(.center), .center)
        XCTAssertEqual(service.textAlignment(.right), .right)

        XCTAssertEqual(service.occurrenceCount(of: "aa", in: "aaaaa"), 2)
        XCTAssertEqual(service.occurrenceCount(of: "", in: "aaaaa"), 0)
        XCTAssertEqual(
            service.normalizedOccurrenceCount(
                of: "a b",
                in: "a\u{00a0}b  a b"
            ),
            2
        )
        XCTAssertEqual(
            service.normalizedVerificationText("a\u{00ad}b\n c"),
            "ab c"
        )
        XCTAssertEqual(
            service.fittedSize(
                CGSize(width: 100, height: 50),
                longestEdge: 200
            ),
            CGSize(width: 200, height: 100)
        )
        XCTAssertEqual(
            service.fittedSize(.zero, longestEdge: 200),
            CGSize(width: 200, height: 200)
        )
        XCTAssertTrue(PDFOutputService.rectsMatch(
            PDFNormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            PDFNormalizedRect(
                x: 0.101,
                y: 0.201,
                width: 0.301,
                height: 0.401
            )
        ))
        XCTAssertFalse(PDFOutputService.rectsMatch(
            PDFNormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            PDFNormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4)
        ))
        XCTAssertFalse(service.blockedTextReplacement(
            "Blocked",
            fontStyle: .serif,
            alignment: .center
        ).isReady)
    }

    func testExternalInboxRecoversDuplicateAndConflictingClaims_BitsUT()
        throws {
        let sharedContainer = temporaryDirectory.appendingPathComponent(
            "InboxRecovery",
            isDirectory: true
        )
        let sourceA = temporaryDirectory.appendingPathComponent("a.pdf")
        let sourceB = temporaryDirectory.appendingPathComponent("b.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: sourceA, pageCount: 1)
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: sourceB) {
            context in
            context.beginPage()
            ("Different PDF" as NSString).draw(
                at: CGPoint(x: 40, y: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }

        let stagedA = try ExternalPDFInbox.stagePDF(
            from: sourceA,
            suggestedName: "Original.pdf",
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )
        let claimedA = try ExternalPDFInbox.claim(
            stagedA,
            sharedContainerURL: sharedContainer
        )
        try FileManager.default.copyItem(
            at: claimedA.containerURL,
            to: stagedA.containerURL
        )
        let duplicateSnapshot = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: sharedContainer
        )
        XCTAssertEqual(duplicateSnapshot.items.count, 1)
        XCTAssertEqual(duplicateSnapshot.discardedInvalidItemCount, 0)
        XCTAssertTrue(duplicateSnapshot.deferredItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: claimedA.containerURL.path
        ))

        let restoredA = try XCTUnwrap(duplicateSnapshot.items.first)
        let claimedAgain = try ExternalPDFInbox.claim(
            restoredA,
            sharedContainerURL: sharedContainer
        )
        let stagedB = try ExternalPDFInbox.stagePDF(
            from: sourceB,
            suggestedName: "Conflict.pdf",
            sharedContainerURL: sharedContainer,
            protectionHandler: { _ in }
        )
        try FileManager.default.moveItem(
            at: stagedB.containerURL,
            to: restoredA.containerURL
        )
        let conflictSnapshot = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: sharedContainer
        )
        XCTAssertEqual(conflictSnapshot.items.count, 2)
        XCTAssertTrue(conflictSnapshot.items.contains {
            $0.expectedSHA256 == claimedAgain.expectedSHA256
        })
        XCTAssertTrue(conflictSnapshot.items.contains {
            $0.expectedSHA256 == stagedB.expectedSHA256
        })

        let recoverWithoutQueued = try XCTUnwrap(
            conflictSnapshot.items.first(where: {
                $0.expectedSHA256 == claimedAgain.expectedSHA256
            })
        )
        let processingOnly = try ExternalPDFInbox.claim(
            recoverWithoutQueued,
            sharedContainerURL: sharedContainer
        )
        let processingRecovered = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: sharedContainer
        )
        XCTAssertTrue(processingRecovered.items.contains {
            $0.expectedSHA256 == processingOnly.expectedSHA256
        })

        let inbox = sharedContainer
            .appendingPathComponent("SharedImports", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
        let invalidID = UUID()
        let invalidQueued = inbox.appendingPathComponent(
            "\(invalidID.uuidString).inbox",
            isDirectory: true
        )
        let invalidProcessing = inbox.appendingPathComponent(
            ".processing-\(invalidID.uuidString).inbox",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: invalidQueued,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: invalidProcessing,
            withIntermediateDirectories: true
        )
        let invalidSnapshot = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: sharedContainer
        )
        XCTAssertGreaterThanOrEqual(
            invalidSnapshot.discardedInvalidItemCount,
            2
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: invalidQueued.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: invalidProcessing.path
        ))

        let stagingDirectory = sharedContainer
            .appendingPathComponent("SharedImports", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        let stale = stagingDirectory.appendingPathComponent("stale")
        try Data("stale".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [
                .creationDate: Date(timeIntervalSinceNow: -172_800),
                .modificationDate: Date(timeIntervalSinceNow: -172_800)
            ],
            ofItemAtPath: stale.path
        )
        let consumed = inbox.appendingPathComponent(
            ".consumed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: consumed,
            withIntermediateDirectories: true
        )
        _ = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: sharedContainer
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: consumed.path))
    }

    func testDocumentStoreOfficeRetentionIdempotencyAndPinning_BitsUT()
        async throws {
        let sourcePDF = temporaryDirectory.appendingPathComponent(
            "retention-source.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: sourcePDF,
            pageCount: 1
        )
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "OfficeRetention",
                isDirectory: true
            )
        )
        let importedRecord = try await store.importPDF(
            from: sourcePDF,
            preserveSourceLocation: false
        )
        let repairedRecords = try await store.ensureContentFingerprints(
            for: [importedRecord]
        )
        let record = try XCTUnwrap(repairedRecords.first)
        XCTAssertNotNil(record.contentFingerprint)
        let officeURL = temporaryDirectory.appendingPathComponent(
            "retention.docx"
        )
        let officeData = Data("office-version-one".utf8)
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

        var staleRecord = record
        staleRecord.contentRevisionID = UUID()
        do {
            _ = try await store.retainOfficeExport(
                receipt,
                sourceURL: officeURL,
                for: staleRecord
            )
            XCTFail("A stale revision must not retain an Office output")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }

        let wrongSizeReceipt = PDFOfficeExportReceipt(
            format: .wordDocument,
            fileName: officeURL.lastPathComponent,
            fileSizeBytes: Int64(officeData.count + 1),
            plan: PDFOfficeExportFormatPlan.plan(
                for: .wordDocument,
                profile: record.profile
            ),
            budgetPlan: PDFOfficeVisualBudgetPlan(
                profile: record.profile
            )
        )
        do {
            _ = try await store.retainOfficeExport(
                wrongSizeReceipt,
                sourceURL: officeURL,
                for: record
            )
            XCTFail("A mismatched receipt size must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }

        let retained = try await store.retainOfficeExport(
            receipt,
            sourceURL: officeURL,
            for: record
        )
        let repeated = try await store.retainOfficeExport(
            receipt,
            sourceURL: officeURL,
            for: retained.record
        )
        XCTAssertEqual(repeated.receipt.id, retained.receipt.id)
        XCTAssertEqual(repeated.url, retained.url)

        let conflicting = Data("office-version-two".utf8)
        XCTAssertEqual(conflicting.count, officeData.count)
        try conflicting.write(to: officeURL)
        do {
            _ = try await store.retainOfficeExport(
                receipt,
                sourceURL: officeURL,
                for: retained.record
            )
            XCTFail("The same receipt ID must not accept different bytes")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        try officeData.write(to: officeURL)

        let pinned = try await store.setOfficeExportPinned(
            receiptID: receipt.id,
            pinned: true,
            for: retained.record
        )
        XCTAssertNotNil(
            pinned.officeReceipts.first(where: {
                $0.id == receipt.id
            })?.pinnedAt
        )
        let pinnedAgain = try await store.setOfficeExportPinned(
            receiptID: receipt.id,
            pinned: true,
            for: pinned
        )
        XCTAssertNotNil(
            pinnedAgain.officeReceipts.first(where: {
                $0.id == receipt.id
            })?.pinnedAt
        )
        let unpinned = try await store.setOfficeExportPinned(
            receiptID: receipt.id,
            pinned: false,
            for: pinnedAgain
        )
        XCTAssertNil(
            unpinned.officeReceipts.first(where: {
                $0.id == receipt.id
            })?.pinnedAt
        )
        do {
            _ = try await store.setOfficeExportPinned(
                receiptID: UUID(),
                pinned: true,
                for: unpinned
            )
            XCTFail("A missing receipt must not be pinned")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }

        try FileManager.default.removeItem(at: retained.url)
        do {
            _ = try await store.setOfficeExportPinned(
                receiptID: receipt.id,
                pinned: true,
                for: unpinned
            )
            XCTFail("A missing retained output must not be pinned")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
    }

    func testFormAutomationEvaluationFailuresAndOperations_BitsUT()
        throws {
        let service = PDFFormAutomationService()
        func replacing(
            _ field: PDFFormFieldSnapshot,
            value: String?,
            kind: PDFFormFieldKind? = nil
        ) -> PDFFormFieldSnapshot {
            PDFFormFieldSnapshot(
                id: field.id,
                pageIndex: field.pageIndex,
                annotationIndex: field.annotationIndex,
                name: field.name,
                kind: kind ?? field.kind,
                value: value,
                normalizedBounds: field.normalizedBounds,
                isRequired: field.isRequired,
                isReadOnly: field.isReadOnly,
                isMultiline: field.isMultiline,
                maximumLength: field.maximumLength,
                optionCount: field.optionCount,
                hasAppearanceStream: field.hasAppearanceStream,
                issue: field.issue
            )
        }
        func automation(
            operation: String,
            transform: ([PDFFormFieldSnapshot]) -> [PDFFormFieldSnapshot]
                = { $0 }
        ) throws -> PDFFormAutomationInspection {
            let url = temporaryDirectory.appendingPathComponent(
                "automation-\(operation)-\(UUID().uuidString).pdf"
            )
            try PDFTestFixtureFactory.makeAcroFormAutomationPDF(
                at: url,
                customCalculationScript:
                    "AFSimple_Calculate(\"\(operation)\", "
                    + "new Array(\"Amount A\", \"Amount B\"));"
            )
            let fields = try PDFFormInspectionService()
                .inspect(url: url).fields
            return try service.inspect(
                url: url,
                fields: transform(fields)
            )
        }

        let expected: [String: String] = [
            "SUM": "30",
            "PRD": "200",
            "AVG": "15",
            "MIN": "10",
            "MAX": "20"
        ]
        for operation in expected.keys.sorted() {
            let report = try automation(operation: operation)
            let total = try XCTUnwrap(report.fields.first {
                $0.fieldName == "Total"
            })
            XCTAssertEqual(total.expectedValue, expected[operation])
            if operation == "PRD" {
                XCTAssertNotNil(total.validationIssue)
            } else {
                XCTAssertNil(total.validationIssue)
            }
        }

        let missing = try automation(operation: "SUM") { fields in
            fields.filter { $0.name != "Amount A" }
        }
        XCTAssertNotNil(missing.fields.first {
            $0.fieldName == "Total"
        }?.validationIssue)

        let ambiguous = try automation(operation: "SUM") { fields in
            guard let amount = fields.first(where: {
                $0.name == "Amount A"
            }) else { return fields }
            return fields + [amount]
        }
        XCTAssertNotNil(ambiguous.fields.first {
            $0.fieldName == "Total"
        }?.validationIssue)

        let invalidNumber = try automation(operation: "SUM") { fields in
            fields.map {
                $0.name == "Amount A"
                    ? replacing($0, value: "not-a-number")
                    : $0
            }
        }
        XCTAssertNotNil(invalidNumber.fields.first {
            $0.fieldName == "Total"
        }?.validationIssue)

        let outOfRange = try automation(operation: "SUM") { fields in
            fields.map {
                $0.name == "Amount A"
                    ? replacing($0, value: "100")
                    : $0
            }
        }
        XCTAssertNotNil(outOfRange.fields.first {
            $0.fieldName == "Total"
        }?.validationIssue)

        let wrongKind = try automation(operation: "SUM") { fields in
            fields.map {
                $0.name == "Total"
                    ? replacing($0, value: "0", kind: .button)
                    : $0
            }
        }
        XCTAssertNotNil(wrongKind.fields.first {
            $0.fieldName == "Total"
        }?.validationIssue)
    }

    func testDocumentStoreRecoveryAndSignerValidationMatrices_BitsUT()
        async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "StoreValidation",
            isDirectory: true
        )
        let store = DocumentStore(rootURL: root)
        let digest = String(repeating: "a", count: 64)
        let documentID = UUID()
        let destination = root
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("\(documentID.uuidString).pdf")
        let workingEntry = PDFWorkingCopyTransactionJournal.Entry(
            destinationPath: destination.path,
            backupPath: destination.deletingLastPathComponent()
                .appendingPathComponent(
                    ".batch-rollback-\(UUID().uuidString)"
                ).path,
            stagingPath: destination.deletingLastPathComponent()
                .appendingPathComponent(
                    ".batch-\(UUID().uuidString)"
                ).path,
            backupFingerprint: digest
        )
        let workingJournal = PDFWorkingCopyTransactionJournal(
            id: UUID(),
            createdAt: Date(),
            entries: [workingEntry]
        )
        let validWorkingJournal = await store.isValidRecoveryJournal(
            workingJournal
        )
        let validWorkingEntry = await store.isValidRecoveryJournalEntry(
            workingEntry
        )
        XCTAssertTrue(validWorkingJournal)
        XCTAssertTrue(validWorkingEntry)
        let duplicateWorkingJournal = PDFWorkingCopyTransactionJournal(
            id: UUID(),
            createdAt: Date(),
            entries: [workingEntry, workingEntry]
        )
        let duplicateWorkingIsValid = await store.isValidRecoveryJournal(
            duplicateWorkingJournal
        )
        XCTAssertFalse(duplicateWorkingIsValid)
        let staleWorkingJournal = PDFWorkingCopyTransactionJournal(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: -1),
            entries: [workingEntry]
        )
        let staleWorkingIsValid = await store.isValidRecoveryJournal(
            staleWorkingJournal
        )
        XCTAssertFalse(staleWorkingIsValid)

        let metadataID = UUID()
        let metadataDestination = root
            .appendingPathComponent("TextIndex", isDirectory: true)
            .appendingPathComponent("\(metadataID.uuidString).json")
        let protectedEntry = ProtectedDataTransactionJournal.Entry(
            destinationPath: metadataDestination.path,
            backupPath: nil,
            stagingPath: metadataDestination.deletingLastPathComponent()
                .appendingPathComponent(
                    ".protected-\(UUID().uuidString)"
                ).path,
            originalFingerprint: nil,
            stagedFingerprint: digest
        )
        let protectedJournal = ProtectedDataTransactionJournal(
            id: UUID(),
            createdAt: Date(),
            entries: [protectedEntry]
        )
        let validProtectedJournal = await store
            .isValidProtectedDataTransactionJournal(protectedJournal)
        let validProtectedEntry = await store
            .isValidProtectedDataTransactionEntry(protectedEntry)
        XCTAssertTrue(validProtectedJournal)
        XCTAssertTrue(validProtectedEntry)
        let duplicateProtectedJournal = ProtectedDataTransactionJournal(
            id: UUID(),
            createdAt: Date(),
            entries: [protectedEntry, protectedEntry]
        )
        let duplicateProtectedIsValid = await store
            .isValidProtectedDataTransactionJournal(
                duplicateProtectedJournal
            )
        XCTAssertFalse(duplicateProtectedIsValid)
        let invalidProtectedEntry = ProtectedDataTransactionJournal.Entry(
            destinationPath: temporaryDirectory
                .appendingPathComponent("outside.json").path,
            backupPath: nil,
            stagingPath: metadataDestination.deletingLastPathComponent()
                .appendingPathComponent("unsafe").path,
            originalFingerprint: nil,
            stagedFingerprint: digest.uppercased()
        )
        let invalidProtectedIsValid = await store
            .isValidProtectedDataTransactionEntry(invalidProtectedEntry)
        XCTAssertFalse(invalidProtectedIsValid)
        let allowedDestination = await store
            .isAllowedProtectedTransactionDestination(metadataDestination)
        let rejectedDestination = await store
            .isAllowedProtectedTransactionDestination(
                root.appendingPathComponent("outside.json")
            )
        XCTAssertTrue(allowedDestination)
        XCTAssertFalse(rejectedDestination)
        let canonicalDigest = await store.isCanonicalSHA256(digest)
        let uppercaseDigest = await store.isCanonicalSHA256(
            digest.uppercased()
        )
        XCTAssertTrue(canonicalDigest)
        XCTAssertFalse(uppercaseDigest)

        let packageID = UUID()
        let managedNames = [
            "\(packageID.uuidString).zip",
            "\(packageID.uuidString)-verification.json",
            ".staging-\(packageID.uuidString).zip",
            ".staging-\(packageID.uuidString).json"
        ]
        for name in managedNames {
            let isManaged = await store
                .isManagedOfficeDeliveryArtifactName(name)
            XCTAssertTrue(
                isManaged
            )
        }
        let notesAreManaged = await store
            .isManagedOfficeDeliveryArtifactName("notes.txt")
        XCTAssertFalse(notesAreManaged)

        let publicKey = Data(repeating: 1, count: 32)
        let signatureBytes = Data(repeating: 2, count: 64)
        let keyID = String(
            SHA256.hash(data: publicKey).map {
                String(format: "%02x", $0)
            }.joined().prefix(16)
        )
        let signature = PDFOfficeVerificationSignature(
            algorithm: "Ed25519",
            keyID: keyID,
            publicKeyBase64: publicKey.base64EncodedString(),
            signatureBase64: signatureBytes.base64EncodedString()
        )
        let signatureMaterial = await store
            .canonicalOfficeSignatureMaterial(signature)
        XCTAssertNotNil(signatureMaterial)
        let invalidSignatureMaterial = await store
            .canonicalOfficeSignatureMaterial(
                PDFOfficeVerificationSignature(
                    algorithm: "RSA",
                    keyID: keyID,
                    publicKeyBase64: publicKey.base64EncodedString(),
                    signatureBase64: signatureBytes.base64EncodedString()
                )
            )
        XCTAssertNil(invalidSignatureMaterial)
        let normalizedKeyID = await store.safeSigningKeyID(
            keyID.uppercased()
        )
        let invalidKeyID = await store.safeSigningKeyID("invalid")
        XCTAssertEqual(normalizedKeyID, keyID)
        XCTAssertNil(invalidKeyID)
        let safeReportText = await store.safeChangeReportDisplayText("\n")
        XCTAssertEqual(
            safeReportText,
            "Unreadable PDF"
        )

        let trustedSigner = PDFOfficeTrustedSigner(
            keyID: keyID,
            publicKeyBase64: publicKey.base64EncodedString(),
            displayName: "Reviewer",
            trustedAt: Date(),
            lastVerifiedAt: Date(),
            verificationCount: 1,
            note: nil
        )
        let unsupportedTrust = await store.officeSignerTrust(
            for: PDFOfficeVerificationSignature(
                algorithm: "RSA",
                keyID: keyID,
                publicKeyBase64: publicKey.base64EncodedString(),
                signatureBase64: signatureBytes.base64EncodedString()
            ),
            signatureIsValid: true,
            localKeyID: nil,
            trustedSigners: []
        )
        XCTAssertEqual(unsupportedTrust.status, .unsupported)
        let invalidTrust = await store.officeSignerTrust(
            for: signature,
            signatureIsValid: false,
            localKeyID: nil,
            trustedSigners: []
        )
        XCTAssertEqual(invalidTrust.status, .invalid)
        let localTrust = await store.officeSignerTrust(
            for: signature,
            signatureIsValid: true,
            localKeyID: keyID,
            trustedSigners: []
        )
        XCTAssertEqual(localTrust.status, .thisDevice)
        let trusted = await store.officeSignerTrust(
            for: signature,
            signatureIsValid: true,
            localKeyID: nil,
            trustedSigners: [trustedSigner]
        )
        XCTAssertEqual(trusted.status, .trusted)
        XCTAssertEqual(trusted.name, "Reviewer")
        let unknown = await store.officeSignerTrust(
            for: signature,
            signatureIsValid: true,
            localKeyID: nil,
            trustedSigners: []
        )
        XCTAssertEqual(unknown.status, .unknown)
    }

    func testDocumentStoreProtectedTransactionRollback_BitsUT()
        async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "ProtectedTransaction",
            isDirectory: true
        )
        let store = DocumentStore(rootURL: root)
        _ = try await store.load()
        let directory = root.appendingPathComponent(
            "TextIndex",
            isDirectory: true
        )
        let first = directory.appendingPathComponent(
            "\(UUID().uuidString).json"
        )
        let second = directory.appendingPathComponent(
            "\(UUID().uuidString).json"
        )
        try await store.writeProtectedDataTransaction([
            (Data("first".utf8), first),
            (Data("second".utf8), second)
        ])
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        try await store.writeProtectedDataTransaction([])

        var rejectedDuplicate = false
        do {
            try await store.writeProtectedDataTransaction([
                (Data("one".utf8), first),
                (Data("two".utf8), first)
            ])
        } catch {
            rejectedDuplicate = true
        }
        XCTAssertTrue(rejectedDuplicate)

        let rollbackRoot = temporaryDirectory.appendingPathComponent(
            "ProtectedRollback",
            isDirectory: true
        )
        let failingManager = MoveFailingFileManager()
        let rollbackStore = DocumentStore(
            rootURL: rollbackRoot,
            fileManager: failingManager
        )
        _ = try await rollbackStore.load()
        let rollbackDirectory = rollbackRoot.appendingPathComponent(
            "TextIndex",
            isDirectory: true
        )
        let rollbackFirst = rollbackDirectory.appendingPathComponent(
            "\(UUID().uuidString).json"
        )
        let rollbackSecond = rollbackDirectory.appendingPathComponent(
            "\(UUID().uuidString).json"
        )
        failingManager.deniedDestinationPath = rollbackSecond.path
        var rolledBack = false
        do {
            try await rollbackStore.writeProtectedDataTransaction([
                (Data("published-first".utf8), rollbackFirst),
                (Data("blocked-second".utf8), rollbackSecond)
            ])
        } catch {
            rolledBack = true
        }
        XCTAssertTrue(rolledBack)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rollbackFirst.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rollbackSecond.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rollbackRoot.appendingPathComponent(
                "active-protected-data-transaction.json"
            ).path
        ))
    }

    @MainActor
    func testMetadataSyncStoresCanonicalReceiptAndRejectsCorruption_BitsUT()
        async throws {
        let suiteName = "PaperPath-Metadata-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let local = LocalMetadataKeyValueStore(defaults: defaults)
        let localKey = "local"
        let localData = Data("metadata".utf8)
        XCTAssertFalse(local.isCloudBacked)
        XCTAssertTrue(local.synchronize())
        local.set(localData, forKey: localKey)
        XCTAssertEqual(local.data(forKey: localKey), localData)
        local.set(nil, forKey: localKey)
        XCTAssertNil(local.data(forKey: localKey))

        let cloud = TestServiceMetadataKeyValueStore(
            isCloudBacked: true
        )
        let shadow = TestServiceMetadataKeyValueStore(
            isCloudBacked: false
        )
        let now = Date()
        let fingerprint = String(repeating: "a", count: 64)
        let revisionID = UUID()
        let profile = DocumentProfile(
            pageCount: 2,
            sampledPageCount: 2,
            textCharacterCount: 120,
            imageDominantPageCount: 0,
            formFieldCount: 0,
            byteCount: 2_048,
            isEncrypted: false,
            isLocked: false,
            allowsCopying: true,
            allowsCommenting: true,
            kind: .text,
            recommendedActions: [.inspect, .shareCopy]
        )
        let receipt = PDFDeliveryReceipt(
            id: UUID(),
            operation: .safeShare,
            createdAt: now.addingTimeInterval(-20),
            sourcePageCount: 2,
            outputPageCount: 2,
            renderedPageCount: 2,
            sourceByteCount: profile.byteCount,
            outputByteCount: profile.byteCount,
            unexpectedBlankPageIndices: [],
            annotationCount: 0,
            textCharacterCount: 120,
            personalMetadataEntryCount: 0,
            isEncrypted: false,
            sha256: fingerprint.uppercased(),
            checks: [
                PDFDeliveryCheck(
                    id: "reopened",
                    title: "Reopened",
                    detail: "The output reopened.",
                    status: .passed
                )
            ],
            outputRevisionID: revisionID
        )
        let sourceRecord = DocumentRecord(
            displayName: "Synced",
            fileName: "synced.pdf",
            importedAt: now.addingTimeInterval(-100),
            modifiedAt: now.addingTimeInterval(-30),
            contentRevisionID: revisionID,
            profile: profile,
            workflowStatus: .ready,
            isPinned: true,
            tags: [" Evidence ", "evidence", String(repeating: "x", count: 30)],
            bookmarkedPages: [1, 1, -1, 9],
            lastPageIndex: 1,
            lastViewedAt: now.addingTimeInterval(-10),
            completedActions: [.inspect, .safeShare],
            deliveryReceipt: receipt,
            sourceImportedFingerprint: fingerprint,
            contentFingerprint: fingerprint.uppercased()
        )
        let first = try await PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: shadow,
            now: { now }
        ).synchronize(records: [sourceRecord, sourceRecord])
        XCTAssertEqual(first.eligibleDocumentCount, 1)
        XCTAssertEqual(first.duplicateDocumentCount, 1)
        XCTAssertTrue(first.isCloudAvailable)

        let receivingRecord = DocumentRecord(
            displayName: "Receiving",
            fileName: "receiving.pdf",
            importedAt: now.addingTimeInterval(-200),
            modifiedAt: now.addingTimeInterval(-200),
            contentRevisionID: revisionID,
            profile: profile,
            sourceImportedFingerprint: fingerprint,
            contentFingerprint: fingerprint
        )
        let receiver = PDFMetadataSyncService(
            cloudStore: cloud,
            shadowStore: TestServiceMetadataKeyValueStore(
                isCloudBacked: false
            ),
            now: { now.addingTimeInterval(30) }
        )
        let received = try await receiver.synchronize(
            records: [receivingRecord]
        )
        let update = try XCTUnwrap(received.updates.first)
        XCTAssertEqual(update.deliveryReceipt?.sha256, fingerprint)
        XCTAssertNil(update.deliveryReceipt?.changeReview)
        XCTAssertEqual(update.bookmarkedPages, [1])
        XCTAssertEqual(update.tags, ["Evidence", String(repeating: "x", count: 24)])

        receiver.clearLocalMetadata()
        cloud.set(
            Data(#"{"version":2,"snapshots":[]}"#.utf8),
            forKey: "paperpath.metadata.cloud.v1"
        )
        do {
            _ = try await receiver.synchronize(
                records: [receivingRecord]
            )
            XCTFail("Unsupported metadata schema was accepted")
        } catch {}
        cloud.set(
            Data(repeating: 0, count: 900_001),
            forKey: "paperpath.metadata.cloud.v1"
        )
        do {
            _ = try await receiver.synchronize(
                records: [receivingRecord]
            )
            XCTFail("Oversized metadata payload was accepted")
        } catch {}
    }

    func testDocumentStoreSearchRestoreAndVersionCleanup_BitsUT()
        async throws {
        let source = temporaryDirectory.appendingPathComponent(
            "search-version.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let root = temporaryDirectory.appendingPathComponent(
            "SearchVersionStore",
            isDirectory: true
        )
        let store = DocumentStore(rootURL: root)
        var record = try await store.importPDF(
            from: source,
            preserveSourceLocation: false
        )
        let detached = try await store.sourceLocation(for: record)
        XCTAssertEqual(detached.status, .detached)
        var invalidBookmarkRecord = record
        invalidBookmarkRecord.sourceBookmarkData = Data([0, 1, 2])
        invalidBookmarkRecord.sourceLocationName = "Unavailable.pdf"
        let unavailable = try await store.sourceLocation(
            for: invalidBookmarkRecord
        )
        XCTAssertEqual(unavailable.status, .unavailable)

        let index = DocumentTextIndex(
            source: .native,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "needle alpha needle beta"
                ),
                IndexedPageText(
                    pageIndex: 1,
                    text: "needle gamma"
                )
            ],
            indexedAt: Date()
        )
        record = try await store.saveAnalysis(
            record,
            brief: DocumentUnderstandingService().analyze(
                index: index,
                profile: record.profile
            ),
            textIndex: index
        )
        let candidate = DocumentStoreTextSearchCandidate(
            recordID: record.id,
            metadataCorpus: "",
            pageCount: record.profile.pageCount,
            hasAnalysis: true
        )
        let limited = try await store.searchTextIndices(
            query: "needle",
            candidates: [candidate],
            resultLimit: 0,
            perDocumentLimit: 0
        )
        XCTAssertTrue(limited.matchingRecordIDs.contains(record.id))
        XCTAssertTrue(limited.isLimited)
        XCTAssertTrue(limited.matchesByRecordID.isEmpty)
        let matched = try await store.searchTextIndices(
            query: "needle",
            candidates: [candidate],
            resultLimit: 2,
            perDocumentLimit: 1
        )
        XCTAssertEqual(matched.matchesByRecordID[record.id]?.count, 1)
        XCTAssertTrue(matched.isLimited)

        let snapshot = try await store.createVersionSnapshot(
            for: record,
            label: "  "
        )
        let workingURL = await store.url(for: record)
        try PDFMutationService().rotatePage(
            at: 0,
            direction: .clockwise,
            in: workingURL
        )
        record = try await store.refresh(
            record,
            invalidateAnalysis: false
        )
        let restored = try await store.restoreVersion(
            snapshotID: snapshot.id,
            for: record
        )
        XCTAssertEqual(
            restored.contentFingerprint,
            snapshot.contentFingerprint
        )
        XCTAssertEqual(restored.lastPageIndex, snapshot.lastPageIndex)
        try await store.enforceVersionRetention()
        try await store.removeVersions(for: record.id)
        let versions = try await store.versions(for: record.id)
        XCTAssertTrue(versions.isEmpty)
        do {
            _ = try await store.versionFileURL(
                snapshotID: snapshot.id,
                recordID: record.id
            )
            XCTFail("A removed version must not remain available")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
    }

    func testMutationXRefAndInvisibleTextUtilities_BitsUT() throws {
        let destination = temporaryDirectory.appendingPathComponent(
            "append-destination.pdf"
        )
        let source = temporaryDirectory.appendingPathComponent(
            "append-source.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: destination,
            pageCount: 1
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: source,
            pageCount: 2
        )
        let mutation = PDFMutationService()
        try mutation.appendPages(from: source, in: destination)
        try mutation.duplicatePage(at: 0, in: destination)
        XCTAssertEqual(PDFDocument(url: destination)?.pageCount, 4)

        let page = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let textRange = (pageText as NSString).range(
            of: "Fixture page 1 amount 0"
        )
        let nativeSelection = try XCTUnwrap(page.selection(for: textRange))
        let pageBounds = page.bounds(for: .cropBox)
        let textBounds = nativeSelection.bounds(for: page)
        let selection = PDFTextSelectionSnapshot(
            pageIndex: 0,
            originalText: "Fixture page 1 amount 0",
            normalizedX:
                (textBounds.minX - pageBounds.minX) / pageBounds.width,
            normalizedY:
                (pageBounds.maxY - textBounds.maxY) / pageBounds.height,
            normalizedWidth: textBounds.width / pageBounds.width,
            normalizedHeight: textBounds.height / pageBounds.height,
            fontName: "Helvetica",
            fontSize: 18,
            color: PDFInkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            ),
            lineCount: 1,
            hasMixedFonts: false,
            pageRotation: 0
        )
        let output = PDFOutputService()
        XCTAssertNotNil(
            output.matchingTextRange(in: page, snapshot: selection)
        )

        let invisibleURL = temporaryDirectory.appendingPathComponent(
            "invisible-text.pdf"
        )
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(
            to: invisibleURL
        ) { context in
            context.beginPage()
            output.drawInvisibleText(
                "Searchable",
                bounds: CGRect(x: 20, y: 20, width: 180, height: 24),
                context: context.cgContext
            )
        }
        XCTAssertNotNil(PDFDocument(url: invisibleURL))

        let raster = UIGraphicsImageRenderer(
            size: CGSize(width: 120, height: 80)
        ).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 10, y: 10, width: 100, height: 60))
        }
        let imagePDF = temporaryDirectory.appendingPathComponent(
            "xref-stream.pdf"
        )
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: imagePDF) {
            context in
            context.beginPage()
            raster.draw(in: bounds)
        }
        let data = try Data(contentsOf: imagePDF)
        let parsed = try PDFImageObjectDocument(data: data)
        let objects = parsed.allObjects()
        XCTAssertFalse(objects.isEmpty)
        let rootObject = try XCTUnwrap(parsed.rootCatalogObject())
        XCTAssertNotNil(parsed.objectData(for: rootObject))
        XCTAssertNotNil(
            parsed.object(
                number: rootObject.number,
                generation: rootObject.generation
            )
        )
        XCTAssertNotNil(
            parsed.referencedObject(following: "/Pages", in: rootObject)
        )
        XCTAssertNil(
            parsed.imageObject(matching: Data("absent-image".utf8))
        )
        XCTAssertNil(
            parsed.imageObject(
                matchingDecodedStream: Data("absent-stream".utf8)
            )
        )
    }

    func testSignedOfficeAndBatesFailureMatrices_BitsUT()
        async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "SignedFailureStore",
                isDirectory: true
            ),
            signingPrivateKeyProvider: { signingKey }
        )
        let now = PDFOfficeTimeAnchor.process.trustedDate()
        let artifact = temporaryDirectory.appendingPathComponent(
            "signed-output.docx"
        )
        let artifactData = Data("signed office output".utf8)
        try artifactData.write(to: artifact)
        let artifactDigest = serviceSHA256(artifactData)
        let deliveryEntry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Source",
            receiptID: UUID(),
            format: .wordDocument,
            archiveName: artifact.lastPathComponent,
            byteCount: Int64(artifactData.count),
            sha256: artifactDigest
        )
        let deliveryPayload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: UUID(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            verifiedOutputs: 1,
            files: [deliveryEntry]
        )
        let signedDelivery = try await store.signOfficeDeliveryPayload(
            deliveryPayload
        )

        let invalidPayload = PDFOfficeVerificationPayload(
            schema: "invalid",
            packageID: deliveryPayload.packageID,
            createdAt: deliveryPayload.createdAt,
            expiresAt: deliveryPayload.expiresAt,
            verifiedOutputs: deliveryPayload.verifiedOutputs,
            files: deliveryPayload.files
        )
        let invalidStructure = try await store.verifyOfficeDeliveryReport(
            PDFOfficeSignedVerificationReport(
                payload: invalidPayload,
                signature: signedDelivery.signature
            )
        )
        XCTAssertEqual(invalidStructure.status, .invalid)

        let unsupportedSignature = PDFOfficeVerificationSignature(
            algorithm: "RSA",
            keyID: signedDelivery.signature.keyID,
            publicKeyBase64:
                signedDelivery.signature.publicKeyBase64,
            signatureBase64:
                signedDelivery.signature.signatureBase64
        )
        let unsupported = try await store.verifyOfficeDeliveryReport(
            PDFOfficeSignedVerificationReport(
                payload: deliveryPayload,
                signature: unsupportedSignature
            )
        )
        XCTAssertEqual(unsupported.status, .unsupported)

        let malformedSignature = PDFOfficeVerificationSignature(
            algorithm: "Ed25519",
            keyID: signedDelivery.signature.keyID,
            publicKeyBase64: "not-base64",
            signatureBase64: "not-base64"
        )
        let malformed = try await store.verifyOfficeDeliveryReport(
            PDFOfficeSignedVerificationReport(
                payload: deliveryPayload,
                signature: malformedSignature
            )
        )
        XCTAssertEqual(malformed.status, .invalid)

        let changedSignature = PDFOfficeVerificationSignature(
            algorithm: "Ed25519",
            keyID: signedDelivery.signature.keyID,
            publicKeyBase64:
                signedDelivery.signature.publicKeyBase64,
            signatureBase64:
                Data(repeating: 0, count: 64).base64EncodedString()
        )
        let changed = try await store.verifyOfficeDeliveryReport(
            PDFOfficeSignedVerificationReport(
                payload: deliveryPayload,
                signature: changedSignature
            )
        )
        XCTAssertEqual(changed.status, .invalid)

        let wrongExtension = temporaryDirectory.appendingPathComponent(
            "office-report.txt"
        )
        try writeServiceJSON(signedDelivery, to: wrongExtension)
        let unsupportedFile = try await store.verifyOfficeDeliveryReport(
            at: wrongExtension
        )
        XCTAssertEqual(unsupportedFile.status, .unsupported)
        let malformedJSON = temporaryDirectory.appendingPathComponent(
            "office-report.json"
        )
        try Data("not-json".utf8).write(to: malformedJSON)
        let malformedFile = try await store.verifyOfficeDeliveryReport(
            at: malformedJSON
        )
        XCTAssertEqual(malformedFile.status, .unsupported)

        let officeMatch = try await store.matchExternalOfficeDeliveryFiles(
            report: signedDelivery,
            candidateURLs: [artifact]
        )
        let officeMatchURL = try await store.exportSignedOfficeMatchReport(
            deliveryReport: signedDelivery,
            matchReport: officeMatch
        )
        let signedOfficeMatch = try serviceJSONDecoder().decode(
            PDFSignedOfficeMatchReport.self,
            from: Data(contentsOf: officeMatchURL)
        )
        let foreignStore = DocumentStore(
            rootURL: temporaryDirectory.appendingPathComponent(
                "ForeignSignedFailureStore",
                isDirectory: true
            ),
            signingPrivateKeyProvider: {
                Curve25519.Signing.PrivateKey()
            }
        )
        let unknownOfficeMatch = try await foreignStore
            .inspectExternalOfficeMatchReport(at: officeMatchURL)
        XCTAssertEqual(unknownOfficeMatch.trustStatus, .unknown)
        let unknownDelivery = try await foreignStore
            .verifyOfficeDeliveryReport(signedDelivery)
        _ = try await foreignStore.trustOfficeReportSigner(
            unknownDelivery
        )
        let trustedOfficeMatch = try await foreignStore
            .inspectExternalOfficeMatchReport(at: officeMatchURL)
        XCTAssertEqual(trustedOfficeMatch.trustStatus, .trusted)
        XCTAssertEqual(
            trustedOfficeMatch.deliveryTrustStatus,
            .trusted
        )

        let malformedOfficeMatchPayload = PDFOfficeMatchReportPayload(
            schema: "invalid",
            reportID: signedOfficeMatch.payload.reportID,
            createdAt: signedOfficeMatch.payload.createdAt,
            deliveryReport:
                signedOfficeMatch.payload.deliveryReport,
            matchReport: signedOfficeMatch.payload.matchReport
        )
        let invalidStructureOfficeMatchURL = temporaryDirectory
            .appendingPathComponent("office-match-structure.json")
        try writeServiceJSON(
            PDFSignedOfficeMatchReport(
                payload: malformedOfficeMatchPayload,
                signature: signedOfficeMatch.signature
            ),
            to: invalidStructureOfficeMatchURL
        )
        let invalidStructureOfficeMatch = try await store
            .inspectExternalOfficeMatchReport(
                at: invalidStructureOfficeMatchURL
            )
        XCTAssertEqual(
            invalidStructureOfficeMatch.signatureStatus,
            .invalid
        )

        let unsupportedOfficeMatchURL = temporaryDirectory
            .appendingPathComponent("office-match-unsupported.json")
        try writeServiceJSON(
            PDFSignedOfficeMatchReport(
                payload: signedOfficeMatch.payload,
                signature: unsupportedSignature
            ),
            to: unsupportedOfficeMatchURL
        )
        let unsupportedOfficeMatch = try await store
            .inspectExternalOfficeMatchReport(
                at: unsupportedOfficeMatchURL
            )
        XCTAssertEqual(
            unsupportedOfficeMatch.signatureStatus,
            .unsupported
        )

        let malformedOfficeMatchURL = temporaryDirectory
            .appendingPathComponent("office-match-malformed.json")
        try writeServiceJSON(
            PDFSignedOfficeMatchReport(
                payload: signedOfficeMatch.payload,
                signature: malformedSignature
            ),
            to: malformedOfficeMatchURL
        )
        let malformedOfficeMatch = try await store
            .inspectExternalOfficeMatchReport(
                at: malformedOfficeMatchURL
            )
        XCTAssertEqual(
            malformedOfficeMatch.signatureStatus,
            .invalid
        )

        let changedOfficeMatchURL = temporaryDirectory
            .appendingPathComponent("office-match-changed.json")
        try writeServiceJSON(
            PDFSignedOfficeMatchReport(
                payload: signedOfficeMatch.payload,
                signature: changedSignature
            ),
            to: changedOfficeMatchURL
        )
        let changedOfficeMatch = try await store
            .inspectExternalOfficeMatchReport(
                at: changedOfficeMatchURL
            )
        XCTAssertEqual(
            changedOfficeMatch.signatureStatus,
            .invalid
        )

        let invalidEmbeddedDelivery = PDFOfficeSignedVerificationReport(
            payload: deliveryPayload,
            signature: changedSignature
        )
        let invalidEmbeddedPayload = PDFOfficeMatchReportPayload(
            schema: PDFOfficeMatchReportPayload.schema,
            reportID: officeMatch.id,
            createdAt: officeMatch.checkedAt,
            deliveryReport: invalidEmbeddedDelivery,
            matchReport: officeMatch
        )
        let invalidEmbeddedURL = temporaryDirectory
            .appendingPathComponent("office-match-embedded.json")
        try writeServiceJSON(
            PDFSignedOfficeMatchReport(
                payload: invalidEmbeddedPayload,
                signature: try serviceSignature(
                    for: invalidEmbeddedPayload,
                    key: signingKey
                )
            ),
            to: invalidEmbeddedURL
        )
        let invalidEmbedded = try await store
            .inspectExternalOfficeMatchReport(at: invalidEmbeddedURL)
        XCTAssertEqual(
            invalidEmbedded.deliverySignatureStatus,
            .invalid
        )

        let numberedPDF = temporaryDirectory.appendingPathComponent(
            "numbered.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(
            at: numberedPDF,
            pageCount: 1
        )
        let numberedData = try Data(contentsOf: numberedPDF)
        let numberedDigest = serviceSHA256(numberedData)
        let batesEntry = PDFBatesBatchReceiptEntry(
            recordID: UUID(),
            displayName: "Numbered",
            pageCount: 1,
            startNumber: 1,
            endNumber: 1,
            startIdentifier: "CASE-0001",
            endIdentifier: "CASE-0001",
            sourceRevisionID: UUID(),
            outputRevisionID: UUID(),
            sourceSHA256: String(repeating: "b", count: 64),
            outputSHA256: numberedDigest
        )
        let batesPayload = PDFBatesBatchReceiptPayload(
            schema: PDFBatesBatchReceiptPayload.schema,
            batchID: UUID(),
            createdAt: now,
            digitCount: 4,
            prefix: "CASE-",
            suffix: "",
            position: .bottomRight,
            totalPageCount: 1,
            firstIdentifier: "CASE-0001",
            lastIdentifier: "CASE-0001",
            entries: [batesEntry]
        )
        let batesReceipt = PDFSignedBatesBatchReceipt(
            payload: batesPayload,
            signature: try serviceSignature(
                for: batesPayload,
                key: signingKey
            )
        )
        let missingBates = try await store.verifyBatesBatchReceipt(
            batesReceipt
        )
        XCTAssertEqual(missingBates.signatureStatus, .verified)
        XCTAssertEqual(missingBates.items.first?.status, .missing)

        let unsupportedBates = try await store.verifyBatesBatchReceipt(
            PDFSignedBatesBatchReceipt(
                payload: batesPayload,
                signature: unsupportedSignature
            )
        )
        XCTAssertEqual(unsupportedBates.signatureStatus, .unsupported)
        XCTAssertEqual(unsupportedBates.items.first?.status, .untrusted)
        let changedBates = try await store.verifyBatesBatchReceipt(
            PDFSignedBatesBatchReceipt(
                payload: batesPayload,
                signature: changedSignature
            )
        )
        XCTAssertEqual(changedBates.signatureStatus, .invalid)

        let batesMatch = try await store.matchExternalBatesPDFs(
            receipt: batesReceipt,
            candidateURLs: [numberedPDF]
        )
        let batesMatchURL = try await store.exportSignedBatesMatchReport(
            receipt: batesReceipt,
            report: batesMatch
        )
        let signedBatesMatch = try serviceJSONDecoder().decode(
            PDFSignedBatesMatchReport.self,
            from: Data(contentsOf: batesMatchURL)
        )
        let validBatesMatch = try await store
            .inspectExternalBatesMatchReport(at: batesMatchURL)
        XCTAssertEqual(
            validBatesMatch.signatureStatus,
            .verified
        )

        let invalidBatesPayload = PDFBatesMatchReportPayload(
            schema: "invalid",
            reportID: signedBatesMatch.payload.reportID,
            createdAt: signedBatesMatch.payload.createdAt,
            receipt: signedBatesMatch.payload.receipt,
            report: signedBatesMatch.payload.report
        )
        let invalidBatesURL = temporaryDirectory.appendingPathComponent(
            "bates-match-invalid.json"
        )
        try writeServiceJSON(
            PDFSignedBatesMatchReport(
                payload: invalidBatesPayload,
                signature: signedBatesMatch.signature
            ),
            to: invalidBatesURL
        )
        let invalidBatesMatch = try await store
            .inspectExternalBatesMatchReport(at: invalidBatesURL)
        XCTAssertEqual(
            invalidBatesMatch.signatureStatus,
            .invalid
        )

        let invalidReceipt = PDFSignedBatesBatchReceipt(
            payload: batesPayload,
            signature: changedSignature
        )
        let invalidReceiptPayload = PDFBatesMatchReportPayload(
            schema: PDFBatesMatchReportPayload.schema,
            reportID: batesMatch.id,
            createdAt: batesMatch.checkedAt,
            receipt: invalidReceipt,
            report: batesMatch
        )
        let invalidReceiptURL = temporaryDirectory.appendingPathComponent(
            "bates-match-invalid-receipt.json"
        )
        try writeServiceJSON(
            PDFSignedBatesMatchReport(
                payload: invalidReceiptPayload,
                signature: signedBatesMatch.signature
            ),
            to: invalidReceiptURL
        )
        let invalidReceiptMatch = try await store
            .inspectExternalBatesMatchReport(at: invalidReceiptURL)
        XCTAssertEqual(
            invalidReceiptMatch.receiptSignatureStatus,
            .invalid
        )

        let unsupportedBatesMatchURL = temporaryDirectory
            .appendingPathComponent("bates-match-unsupported.json")
        try writeServiceJSON(
            PDFSignedBatesMatchReport(
                payload: signedBatesMatch.payload,
                signature: unsupportedSignature
            ),
            to: unsupportedBatesMatchURL
        )
        let unsupportedBatesMatch = try await store
            .inspectExternalBatesMatchReport(
                at: unsupportedBatesMatchURL
            )
        XCTAssertEqual(
            unsupportedBatesMatch.signatureStatus,
            .unsupported
        )

        let malformedBatesMatchURL = temporaryDirectory
            .appendingPathComponent("bates-match-malformed.json")
        try writeServiceJSON(
            PDFSignedBatesMatchReport(
                payload: signedBatesMatch.payload,
                signature: malformedSignature
            ),
            to: malformedBatesMatchURL
        )
        let malformedBatesMatch = try await store
            .inspectExternalBatesMatchReport(
                at: malformedBatesMatchURL
            )
        XCTAssertEqual(
            malformedBatesMatch.signatureStatus,
            .unsupported
        )

        let changedBatesMatchURL = temporaryDirectory
            .appendingPathComponent("bates-match-changed.json")
        try writeServiceJSON(
            PDFSignedBatesMatchReport(
                payload: signedBatesMatch.payload,
                signature: changedSignature
            ),
            to: changedBatesMatchURL
        )
        let changedBatesMatch = try await store
            .inspectExternalBatesMatchReport(at: changedBatesMatchURL)
        XCTAssertEqual(
            changedBatesMatch.signatureStatus,
            .invalid
        )
    }

    func testDocumentStructureAssociationBudgetAndTechnicalBranches_BitsUT()
        throws {
        let source = temporaryDirectory.appendingPathComponent(
            "associated-attachments.pdf"
        )
        let attachmentData = Data("associated evidence".utf8)
        let fileName = "evidence.txt"
        let encodedName = servicePDFHex(fileName)
        let pageCommands = Data("0 0 0 rg\n20 20 40 40 re f\n".utf8)
        try PDFTestFixtureFactory.writeClassicPDF(
            objects: [
                .init(
                    1,
                    """
                    << /Type /Catalog /Pages 2 0 R /AF [5 0 R] /Names << /EmbeddedFiles 7 0 R >> >>
                    """
                ),
                .init(
                    2,
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
                ),
                .init(
                    3,
                    """
                    << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [0 0 612 792] /Resources << >> /Contents 4 0 R /AF [5 0 R] /Annots [6 10 11 12] >>
                    """
                ),
                .init(
                    4,
                    "<< /Length \(pageCommands.count) >>",
                    stream: pageCommands
                ),
                .init(
                    5,
                    """
                    << /Type /Filespec /F <\(encodedName)> /UF <\(encodedName)> /Desc (Associated evidence) /EF << /F 8 0 R /UF 8 0 R >> >>
                    """
                ),
                .init(
                    6,
                    """
                    << /Type /Annot /Subtype /FileAttachment /Rect [20 20 40 40] /FS 5 0 R /Contents (Page attachment) >>
                    """
                ),
                .init(7, "<< /Kids [9 0 R] >>"),
                .init(
                    8,
                    """
                    << /Type /EmbeddedFile /Subtype /text#2Fplain /Params << /Size \(attachmentData.count) >> /Length \(attachmentData.count) >>
                    """,
                    stream: attachmentData
                ),
                .init(
                    9,
                    "<< /Names [<\(encodedName)> 5 0 R] >>"
                ),
                .init(
                    10,
                    """
                    << /Type /Annot /Subtype /Polygon /Rect [60 60 100 100] /Contents (Default color) >>
                    """
                ),
                .init(
                    11,
                    """
                    << /Type /Annot /Subtype /Polygon /Rect [110 60 150 100] /Contents (Gray color) /C [0.4] >>
                    """
                ),
                .init(
                    12,
                    """
                    << /Type /Annot /Subtype /Polygon /Rect [160 60 200 100] /Contents (Invalid color) /C [0.1 0.2] >>
                    """
                )
            ],
            rootObjectNumber: 1,
            to: source
        )

        let service = PDFDocumentStructureService()
        let payloads = try service.decodedAttachmentPayloads(
            in: source,
            retainingDataFor: Set<String>(),
            maximumDecodedBytes: 64
        )
        XCTAssertEqual(payloads.count, 1)
        XCTAssertNil(payloads.first?.data)
        XCTAssertEqual(
            payloads.first?.snapshot.origin,
            .pageAnnotation
        )

        let limited = try service.decodedAttachmentPayloads(
            in: source,
            maximumDecodedBytes: 2
        )
        XCTAssertEqual(limited.count, 3)
        XCTAssertTrue(limited.allSatisfy {
            !$0.snapshot.isExtractable
                && $0.snapshot.limitation?
                    .contains("memory budget") == true
        })
        XCTAssertThrowsError(
            try service.decodedAttachmentPayloads(
                in: source,
                maximumDecodedBytes: 0
            )
        )
        let encodedSizeSource = temporaryDirectory.appendingPathComponent(
            "encoded-size-attachment.pdf"
        )
        try PDFTestFixtureFactory.makeStructurePDF(
            at: encodedSizeSource,
            attachment: .init(
                fileName: "raw.bin",
                data: Data([1, 2, 3, 4]),
                includesDeclaredSize: false
            )
        )
        let encodedSizePayload = try XCTUnwrap(
            service.attachmentPayloads(in: encodedSizeSource).first
        )
        XCTAssertTrue(encodedSizePayload.snapshot.isExtractable)
        XCTAssertEqual(encodedSizePayload.data, Data([1, 2, 3, 4]))

        let reviews = try service.unsupportedReviewAnnotations(in: source)
        XCTAssertTrue(reviews.allSatisfy { $0.color.alpha == 1 })
        XCTAssertEqual(decodePDFName("text#2Fplain"), "text/plain")
        XCTAssertEqual(decodePDFName("A#20B"), "A B")
        XCTAssertEqual(decodePDFName("bad#GZname"), "bad#GZname")
        XCTAssertEqual(decodePDFName("trailing#"), "trailing#")

        var profile = try PDFInspectionService().inspect(url: source)
        profile.sampledPageCount = 0
        profile.imageDominantPageCount = 0
        let technical = try service.technicalInspection(
            in: source,
            profile: profile,
            source: nil
        )
        XCTAssertEqual(technical.pageCount, 1)
        XCTAssertNil(technical.textCoverage)
        XCTAssertNil(technical.imageDominantPageCount)
        XCTAssertEqual(technical.attachmentCount, 1)
        XCTAssertEqual(technical.annotationCount, reviews.count)

        let plain = temporaryDirectory.appendingPathComponent(
            "technical-plain.pdf"
        )
        let protected = temporaryDirectory.appendingPathComponent(
            "technical-protected.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(at: plain, pageCount: 1)
        try PDFOutputService().protect(
            sourceURL: plain,
            destination: protected,
            password: "local-only"
        )
        let locked = try service.technicalInspection(
            in: protected,
            profile: .empty,
            source: nil
        )
        XCTAssertTrue(locked.isLocked)
        XCTAssertNil(locked.permissions)
        let unlocked = try service.technicalInspection(
            in: protected,
            profile: .empty,
            source: nil,
            unlockPassword: "local-only"
        )
        XCTAssertFalse(unlocked.isLocked)
        XCTAssertNotNil(unlocked.permissions)
    }

    func testExternalInboxMetadataRepairRestoreAndCancellation_BitsUT()
        throws {
        let signal = ExternalPDFInboxCancellationSignal()
        XCTAssertNoThrow(try signal.checkCancellation())
        signal.cancel()
        XCTAssertThrowsError(try signal.checkCancellation()) {
            XCTAssertTrue($0 is CancellationError)
        }

        let source = temporaryDirectory.appendingPathComponent(
            "inbox-repair-source.pdf"
        )
        let otherSource = temporaryDirectory.appendingPathComponent(
            "inbox-repair-other.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 1)
        try UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 240, height: 320)
        ).writePDF(to: otherSource) { context in
            context.beginPage()
            ("Other" as NSString).draw(at: CGPoint(x: 20, y: 20))
        }
        XCTAssertThrowsError(
            try ExternalPDFInbox.stagePDF(
                from: source,
                sharedContainerURL: temporaryDirectory
                    .appendingPathComponent("CancelledInbox"),
                protectionHandler: { _ in },
                cancellationCheck: signal.checkCancellation
            )
        ) {
            XCTAssertTrue($0 is CancellationError)
        }

        let repairRoot = temporaryDirectory.appendingPathComponent(
            "RepairInbox"
        )
        let repairItem = try ExternalPDFInbox.stagePDF(
            from: source,
            suggestedName: "",
            sharedContainerURL: repairRoot,
            protectionHandler: { _ in }
        )
        let metadataURL = repairItem.containerURL.appendingPathComponent(
            "metadata.json"
        )
        try FileManager.default.removeItem(at: metadataURL)
        let repaired = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: repairRoot
        )
        XCTAssertEqual(repaired.items.count, 1)
        XCTAssertEqual(repaired.items.first?.preferredName, "Shared PDF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        let legacyRoot = temporaryDirectory.appendingPathComponent(
            "LegacyInbox"
        )
        let legacyItem = try ExternalPDFInbox.stagePDF(
            from: source,
            suggestedName: "Legacy.pdf",
            sharedContainerURL: legacyRoot,
            protectionHandler: { _ in }
        )
        let legacyMetadataURL = legacyItem.containerURL
            .appendingPathComponent("metadata.json")
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: legacyMetadataURL)
            ) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "payloadSHA256")
        legacyJSON.removeValue(forKey: "payloadByteCount")
        try JSONSerialization.data(
            withJSONObject: legacyJSON,
            options: [.sortedKeys]
        ).write(to: legacyMetadataURL)
        let migrated = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: legacyRoot
        )
        XCTAssertEqual(migrated.items.first?.preferredName, "Legacy")
        XCTAssertEqual(
            migrated.items.first?.expectedSHA256.count,
            64
        )

        let invalidRoot = temporaryDirectory.appendingPathComponent(
            "InvalidMetadataInbox"
        )
        let invalidItem = try ExternalPDFInbox.stagePDF(
            from: source,
            sharedContainerURL: invalidRoot,
            protectionHandler: { _ in }
        )
        let invalidMetadataURL = invalidItem.containerURL
            .appendingPathComponent("metadata.json")
        var invalidJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: invalidMetadataURL)
            ) as? [String: Any]
        )
        invalidJSON.removeValue(forKey: "payloadByteCount")
        try JSONSerialization.data(
            withJSONObject: invalidJSON,
            options: [.sortedKeys]
        ).write(to: invalidMetadataURL)
        let invalidSnapshot = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: invalidRoot
        )
        XCTAssertTrue(invalidSnapshot.items.isEmpty)
        XCTAssertEqual(invalidSnapshot.discardedInvalidItemCount, 1)

        let duplicateRoot = temporaryDirectory.appendingPathComponent(
            "DuplicateRestoreInbox"
        )
        let duplicateItem = try ExternalPDFInbox.stagePDF(
            from: source,
            sharedContainerURL: duplicateRoot,
            protectionHandler: { _ in }
        )
        let duplicateClaim = try ExternalPDFInbox.claim(
            duplicateItem,
            sharedContainerURL: duplicateRoot
        )
        try FileManager.default.copyItem(
            at: duplicateClaim.containerURL,
            to: duplicateItem.containerURL
        )
        try ExternalPDFInbox.restore(
            duplicateClaim,
            sharedContainerURL: duplicateRoot
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: duplicateClaim.containerURL.path
        ))

        let replaceRoot = temporaryDirectory.appendingPathComponent(
            "ReplaceRestoreInbox"
        )
        let replaceItem = try ExternalPDFInbox.stagePDF(
            from: source,
            sharedContainerURL: replaceRoot,
            protectionHandler: { _ in }
        )
        let replaceClaim = try ExternalPDFInbox.claim(
            replaceItem,
            sharedContainerURL: replaceRoot
        )
        try FileManager.default.createDirectory(
            at: replaceItem.containerURL,
            withIntermediateDirectories: true
        )
        try ExternalPDFInbox.restore(
            replaceClaim,
            sharedContainerURL: replaceRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: replaceItem.containerURL
                .appendingPathComponent("document.pdf").path
        ))

        let conflictRoot = temporaryDirectory.appendingPathComponent(
            "ConflictRestoreInbox"
        )
        let conflictItem = try ExternalPDFInbox.stagePDF(
            from: source,
            sharedContainerURL: conflictRoot,
            protectionHandler: { _ in }
        )
        let conflictClaim = try ExternalPDFInbox.claim(
            conflictItem,
            sharedContainerURL: conflictRoot
        )
        let competingItem = try ExternalPDFInbox.stagePDF(
            from: otherSource,
            sharedContainerURL: conflictRoot,
            protectionHandler: { _ in }
        )
        try FileManager.default.moveItem(
            at: competingItem.containerURL,
            to: conflictItem.containerURL
        )
        try ExternalPDFInbox.restore(
            conflictClaim,
            sharedContainerURL: conflictRoot
        )
        let conflictItems = try ExternalPDFInbox.pendingItems(
            sharedContainerURL: conflictRoot
        )
        XCTAssertEqual(conflictItems.count, 2)
        XCTAssertEqual(
            Set(conflictItems.map(\.expectedSHA256)).count,
            2
        )

        let tamperedRoot = temporaryDirectory.appendingPathComponent(
            "TamperedRestoreInbox"
        )
        let tamperedItem = try ExternalPDFInbox.stagePDF(
            from: source,
            sharedContainerURL: tamperedRoot,
            protectionHandler: { _ in }
        )
        let tamperedClaim = try ExternalPDFInbox.claim(
            tamperedItem,
            sharedContainerURL: tamperedRoot
        )
        try Data("%PDF-1.7\ntampered".utf8).write(
            to: tamperedClaim.fileURL
        )
        try ExternalPDFInbox.restore(
            tamperedClaim,
            sharedContainerURL: tamperedRoot
        )
        let tamperedSnapshot = try ExternalPDFInbox.pendingSnapshot(
            sharedContainerURL: tamperedRoot
        )
        XCTAssertTrue(tamperedSnapshot.items.isEmpty)
        XCTAssertEqual(tamperedSnapshot.discardedInvalidItemCount, 1)
    }

    func testFormAutomationNestedStreamAndValidationBranches_BitsUT()
        throws {
        let source = temporaryDirectory.appendingPathComponent(
            "automation-matrix.pdf"
        )
        func widget(
            _ number: Int,
            name: String?,
            value: String,
            actions: String = "",
            parent: Int? = nil
        ) -> PDFTestFixtureFactory.PDFObject {
            let nameEntry = name.map { "/T (\($0)) " } ?? ""
            let parentEntry = parent.map { "/Parent \($0) 0 R " } ?? ""
            return .init(
                number,
                """
                << /Type /Annot /Subtype /Widget /FT /Tx \(nameEntry)/V (\(value)) \(parentEntry)\(actions)/Rect [20 20 180 48] >>
                """
            )
        }
        func action(
            _ number: Int,
            _ script: String
        ) -> PDFTestFixtureFactory.PDFObject {
            .init(
                number,
                "<< /S /JavaScript /JS <\(servicePDFHex(script))> >>"
            )
        }

        let content = Data()
        var objects: [PDFTestFixtureFactory.PDFObject] = [
            .init(
                1,
                "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>"
            ),
            .init(
                2,
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
            ),
            .init(
                3,
                """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents 4 0 R /Annots [6 0 R 7 0 R 8 0 R 9 0 R 10 0 R 11 0 R 12 0 R 13 0 R 14 0 R 15 0 R 16 0 R 17 0 R 18 0 R 19 0 R 30 0 R 31 0 R 32 0 R] >>
                """
            ),
            .init(4, "<< /Length 0 >>", stream: content),
            .init(
                5,
                """
                << /Fields [6 0 R 7 0 R 8 0 R 9 0 R 10 0 R 11 0 R 12 0 R 13 0 R 14 0 R 15 0 R 16 0 R 17 0 R 18 0 R 19 0 R 30 0 R 31 0 R 33 0 R] >>
                """
            ),
            widget(6, name: "A", value: "10"),
            widget(7, name: "B", value: "20"),
            widget(
                8,
                name: "Nested",
                value: "0",
                actions: "/AA << /C 20 0 R >> "
            ),
            widget(
                9,
                name: "CycleA",
                value: "0",
                actions: "/AA << /C 21 0 R >> "
            ),
            widget(
                10,
                name: "CycleB",
                value: "0",
                actions: "/AA << /C 22 0 R >> "
            ),
            widget(
                11,
                name: "BadNumber",
                value: "letters",
                actions: "/AA << /F 23 0 R >> "
            ),
            widget(
                12,
                name: "BadDate",
                value: "not-a-date",
                actions: "/AA << /F 24 0 R >> "
            ),
            widget(
                13,
                name: "Low",
                value: "-1",
                actions: "/AA << /V 25 0 R >> "
            ),
            widget(
                14,
                name: "High",
                value: "20",
                actions: "/AA << /V 25 0 R >> "
            ),
            widget(
                15,
                name: "RangeBad",
                value: "none",
                actions: "/AA << /V 25 0 R >> "
            ),
            widget(16, name: "HugeA", value: "1e308"),
            widget(17, name: "HugeB", value: "1e308"),
            widget(
                18,
                name: "HugeProduct",
                value: "0",
                actions: "/AA << /C 26 0 R >> "
            ),
            widget(
                19,
                name: "Unsupported",
                value: "1",
                actions: "/AA << /K 27 0 R >> /A 28 0 R "
            ),
            widget(
                30,
                name: "Merged",
                value: "0",
                actions: "/AA << /C 29 0 R >> "
            ),
            widget(
                31,
                name: "Merged",
                value: "0",
                actions: "/AA << /F 23 0 R >> "
            ),
            widget(
                32,
                name: nil,
                value: "42",
                parent: 33
            ),
            .init(
                33,
                "<< /T (Inherited) /Kids [32 0 R] /AA << /F 23 0 R >> >>"
            ),
            action(
                20,
                #"AFSimple_Calculate("SUM", new Array("A", "B"));"#
            ),
            action(
                21,
                #"AFSimple_Calculate("SUM", new Array("CycleB"));"#
            ),
            action(
                22,
                #"AFSimple_Calculate("SUM", new Array("CycleA"));"#
            ),
            action(
                23,
                #"AFNumber_Format(2, 0, 0, 0, "$", true);"#
            ),
            action(24, #"AFDate_FormatEx("mm/dd/yyyy");"#),
            action(25, "AFRange_Validate(true, 0, true, 10);"),
            action(
                26,
                #"AFSimple_Calculate("PRD", new Array("HugeA", "HugeB"));"#
            ),
            .init(27, "<< /S /JavaScript /JS 34 0 R >>"),
            .init(28, "<< /S /JavaScript >>"),
            action(
                29,
                #"AFSimple_Calculate("SUM", new Array("A", "B"));"#
            )
        ]
        let streamScript = Data(
            #"AFNumber_Keystroke(2, 0, 0, 0, "$", true);"#.utf8
        )
        objects.append(
            .init(
                34,
                "<< /Length \(streamScript.count) >>",
                stream: streamScript
            )
        )
        try PDFTestFixtureFactory.writeClassicPDF(
            objects: objects,
            rootObjectNumber: 1,
            to: source
        )

        let namesAndValues: [(String, String)] = [
            ("A", "10"),
            ("B", "20"),
            ("Nested", "0"),
            ("CycleA", "0"),
            ("CycleB", "0"),
            ("BadNumber", "letters"),
            ("BadDate", "not-a-date"),
            ("Low", "-1"),
            ("High", "20"),
            ("RangeBad", "none"),
            ("HugeA", "1e308"),
            ("HugeB", "1e308"),
            ("HugeProduct", "0"),
            ("Unsupported", "1"),
            ("Merged", "0"),
            ("Inherited", "42")
        ]
        let fields = namesAndValues.enumerated().map {
            index,
            pair in
            serviceFormField(
                id: "matrix-\(index)",
                name: pair.0,
                value: pair.1
            )
        }
        let report = try PDFFormAutomationService().inspect(
            url: source,
            fields: fields
        )
        func automation(
            _ name: String
        ) throws -> PDFFormAutomationFieldSnapshot {
            try XCTUnwrap(report.fields.first { $0.fieldName == name })
        }

        XCTAssertEqual(
            try automation("Nested").expectedValue,
            "30"
        )
        XCTAssertNotNil(try automation("CycleA").validationIssue)
        XCTAssertNotNil(
            try automation("HugeProduct").validationIssue
        )
        XCTAssertNotNil(try automation("BadNumber").validationIssue)
        XCTAssertNotNil(try automation("BadDate").validationIssue)
        XCTAssertNotNil(try automation("Low").validationIssue)
        XCTAssertNotNil(try automation("High").validationIssue)
        XCTAssertNotNil(try automation("RangeBad").validationIssue)
        XCTAssertEqual(
            try automation("Merged").formattedPreview,
            "$30.00"
        )
        XCTAssertEqual(
            try automation("Inherited").formattedPreview,
            "$42.00"
        )
        XCTAssertGreaterThanOrEqual(
            report.encounteredJavaScriptCount,
            11
        )
        XCTAssertGreaterThanOrEqual(
            report.unsupportedJavaScriptCount,
            1
        )

        let formReport = try PDFFormInspectionService().inspect(url: source)
        XCTAssertTrue(formReport.hasJavaScript)
        XCTAssertFalse(formReport.fields.isEmpty)
        XCTAssertEqual(
            try PDFFormInspectionService().fields(in: source).count,
            formReport.fields.count
        )
    }

    func testScanCompositionAndFormInspectionBoundaryBranches_BitsUT()
        throws {
        let scan = ScanPDFRenderer()
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 240, height: 180)
        ).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
            UIColor.black.setFill()
            context.fill(CGRect(x: 24, y: 20, width: 192, height: 140))
        }
        XCTAssertThrowsError(
            try scan.validateInputBudget(
                for: Array(
                    repeating: ScanPageImage(image: image),
                    count: 251
                )
            )
        )
        let hugeImage = UIImage(
            ciImage: CIImage(
                color: CIColor(red: 1, green: 1, blue: 1)
            ).cropped(
                to: CGRect(x: 0, y: 0, width: 20_000, height: 10_000)
            )
        )
        XCTAssertThrowsError(
            try scan.validateInputBudget(
                for: [ScanPageImage(image: hugeImage)]
            )
        )
        let batchImage = UIImage(
            ciImage: CIImage(
                color: CIColor(red: 1, green: 1, blue: 1)
            ).cropped(
                to: CGRect(x: 0, y: 0, width: 11_000, height: 10_000)
            )
        )
        XCTAssertThrowsError(
            try scan.validateInputBudget(
                for: Array(
                    repeating: ScanPageImage(image: batchImage),
                    count: 11
                )
            )
        )
        XCTAssertThrowsError(
            try scan.validateInputBudget(
                for: [ScanPageImage(image: UIImage())]
            )
        )

        let rotated = UIImage(
            cgImage: try XCTUnwrap(image.cgImage),
            scale: 1,
            orientation: .left
        )
        XCTAssertEqual(
            scan.orientedPixelSize(of: rotated),
            CGSize(
                width: try XCTUnwrap(image.cgImage).height,
                height: try XCTUnwrap(image.cgImage).width
            )
        )
        XCTAssertEqual(
            scan.orientedPixelSize(of: batchImage),
            CGSize(width: 11_000, height: 10_000)
        )
        let downsampled = scan.processingSized(
            image,
            longestEdge: 40,
            maximumPixelCount: 800
        )
        XCTAssertLessThan(
            scan.orientedPixelSize(of: downsampled).width,
            scan.orientedPixelSize(of: image).width
        )

        let crop = ScanCropQuad(
            topLeft: ScanCropPoint(x: 0.08, y: 0.08),
            topRight: ScanCropPoint(x: 0.92, y: 0.08),
            bottomRight: ScanCropPoint(x: 0.92, y: 0.92),
            bottomLeft: ScanCropPoint(x: 0.08, y: 0.92)
        )
        let cropped = scan.processed(
            image,
            options: ScanProcessingOptions(
                enhancement: .color,
                autoCrop: false,
                removeShadows: true,
                cleanEdges: true,
                brightness: 0.2,
                contrast: 1.2,
                manualCrop: crop
            )
        )
        XCTAssertTrue(cropped.detectedDocument)
        XCTAssertEqual(cropped.cropQuad, crop)
        for enhancement in ScanEnhancement.allCases {
            XCTAssertNotNil(
                scan.processed(
                    image,
                    options: ScanProcessingOptions(
                        enhancement: enhancement,
                        autoCrop: false,
                        removeShadows: true,
                        cleanEdges: false,
                        brightness: -0.1,
                        contrast: 0.8
                    )
                ).image.cgImage
            )
        }
        XCTAssertNil(scan.detectedRectangle(in: UIImage()))

        let scanPDF = temporaryDirectory.appendingPathComponent(
            "scan-verification.pdf"
        )
        try scan.render(images: [image], to: scanPDF)
        XCTAssertNoThrow(
            try scan.verifyRenderedPDF(
                at: scanPDF,
                expectedPageCount: 1
            )
        )
        XCTAssertThrowsError(
            try scan.verifyRenderedPDF(
                at: scanPDF,
                expectedPageCount: 2
            )
        )
        let invalidPDF = temporaryDirectory.appendingPathComponent(
            "invalid-scan.pdf"
        )
        try Data("not a pdf".utf8).write(to: invalidPDF)
        XCTAssertThrowsError(
            try scan.verifyRenderedPDF(
                at: invalidPDF,
                expectedPageCount: 1
            )
        )
        XCTAssertThrowsError(try scan.render(images: [], to: invalidPDF))
        XCTAssertThrowsError(
            try scan.render(images: [image], to: scanPDF)
        )

        let template = PaperTemplateRenderer()
        XCTAssertThrowsError(
            try template.render(
                kind: .blank,
                size: .letter,
                pageCount: 51,
                title: "Too many",
                to: temporaryDirectory.appendingPathComponent(
                    "too-many-template.pdf"
                )
            )
        )
        XCTAssertThrowsError(
            try template.render(
                kind: .grid,
                size: .a4,
                pageCount: 1,
                title: "Existing",
                to: scanPDF
            )
        )

        let composition = PDFCompositionService()
        let source = temporaryDirectory.appendingPathComponent(
            "composition-source.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 1)
        XCTAssertThrowsError(
            try composition.combine(urls: [source], to: invalidPDF)
        )
        XCTAssertThrowsError(
            try composition.combine(
                urls: [source, invalidPDF],
                to: temporaryDirectory.appendingPathComponent(
                    "bad-combination.pdf"
                )
            )
        )
        XCTAssertThrowsError(
            try composition.extractPages(
                from: source,
                indices: [],
                to: invalidPDF
            )
        )
        XCTAssertThrowsError(
            try composition.extractPages(
                from: source,
                indices: [99],
                to: invalidPDF
            )
        )
        XCTAssertThrowsError(
            try composition.write(
                PDFDocument(),
                expectedPageCount: 0,
                to: invalidPDF
            )
        )
        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertThrowsError(
            try composition.write(
                sourceDocument,
                expectedPageCount: 2,
                to: invalidPDF
            )
        )
        XCTAssertThrowsError(
            try composition.verifyOutput(
                at: invalidPDF,
                expectedPageCount: 1
            )
        )
        XCTAssertThrowsError(
            try composition.verifyOutput(
                at: source,
                expectedPageCount: 2
            )
        )
        let replacementDestination = temporaryDirectory
            .appendingPathComponent("replacement-destination.pdf")
        let replacementStaging = temporaryDirectory
            .appendingPathComponent("replacement-staging.pdf")
        try Data("old".utf8).write(to: replacementDestination)
        try Data("new".utf8).write(to: replacementStaging)
        try composition.replaceExistingItem(
            at: replacementDestination,
            with: replacementStaging
        )
        XCTAssertEqual(
            try Data(contentsOf: replacementDestination),
            Data("new".utf8)
        )
        XCTAssertThrowsError(
            try composition.replaceExistingItem(
                at: replacementDestination,
                with: replacementStaging
            )
        )

        let searchable = SearchablePDFService()
        let block = OCRTextBlock(
            text: "Searchable",
            confidence: 0.9,
            normalizedX: 0.1,
            normalizedY: 0.1,
            normalizedWidth: 0.4,
            normalizedHeight: 0.1
        )
        let page = OCRPageResult(
            pageIndex: 0,
            text: "Searchable",
            confidence: 0.9,
            blocks: [block]
        )
        XCTAssertNoThrow(
            try searchable.validate([page], sourcePageCount: 1)
        )
        XCTAssertThrowsError(
            try searchable.validate(
                [page, page],
                sourcePageCount: 1
            )
        )
        XCTAssertThrowsError(
            try searchable.validate(
                [
                    OCRPageResult(
                        pageIndex: 0,
                        text: "Bad confidence",
                        confidence: .nan,
                        blocks: [block]
                    )
                ],
                sourcePageCount: 1
            )
        )
        XCTAssertThrowsError(
            try searchable.validate(
                [
                    OCRPageResult(
                        pageIndex: 0,
                        text: "Bad block",
                        confidence: 1,
                        blocks: [
                            OCRTextBlock(
                                text: "",
                                confidence: 1,
                                normalizedX: 0,
                                normalizedY: 0,
                                normalizedWidth: 0,
                                normalizedHeight: 0
                            )
                        ]
                    )
                ],
                sourcePageCount: 1
            )
        )
        XCTAssertThrowsError(
            try searchable.createSearchableCopy(
                sourceURL: source,
                ocrResult: OCRResult(pages: []),
                destination: invalidPDF
            )
        )
        XCTAssertThrowsError(
            try searchable.createSearchableCopy(
                sourceURL: invalidPDF,
                ocrResult: OCRResult(pages: [page]),
                destination: temporaryDirectory.appendingPathComponent(
                    "unreadable-searchable.pdf"
                )
            )
        )
        XCTAssertThrowsError(
            try searchable.createSearchableCopy(
                sourceURL: source,
                ocrResult: OCRResult(
                    pages: [
                        OCRPageResult(
                            pageIndex: 0,
                            text: "",
                            confidence: 1,
                            blocks: []
                        )
                    ]
                ),
                destination: temporaryDirectory.appendingPathComponent(
                    "empty-searchable.pdf"
                )
            )
        )
        XCTAssertThrowsError(
            try searchable.createSearchableCopy(
                sourceURL: source,
                ocrResult: OCRResult(pages: [page]),
                destination: invalidPDF
            )
        )
        XCTAssertThrowsError(
            try searchable.verifyOutput(
                at: invalidPDF,
                expectedPageCount: 1,
                searchablePageIndices: []
            )
        )
        XCTAssertThrowsError(
            try searchable.verifyOutput(
                at: source,
                expectedPageCount: 2,
                searchablePageIndices: []
            )
        )
        let blank = temporaryDirectory.appendingPathComponent(
            "blank-searchable.pdf"
        )
        try UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 240, height: 320)
        ).writePDF(to: blank) { $0.beginPage() }
        XCTAssertThrowsError(
            try searchable.verifyOutput(
                at: blank,
                expectedPageCount: 1,
                searchablePageIndices: [0]
            )
        )
        XCTAssertNoThrow(
            try searchable.verifyOutput(
                at: source,
                expectedPageCount: 1,
                searchablePageIndices: [0]
            )
        )

        let inspection = PDFFormInspectionService()
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let textWidget = PDFAnnotation(
            bounds: CGRect(x: 40, y: 40, width: 180, height: 32),
            forType: .widget,
            withProperties: nil
        )
        textWidget.widgetFieldType = .text
        textWidget.fieldName = "Name"
        textWidget.widgetStringValue = String(repeating: "x", count: 65_537)
        let oversized = inspection.snapshot(
            textWidget,
            annotationIndex: 0,
            pageIndex: 0,
            pageBounds: pageBounds,
            placedSignatureBounds: []
        )
        XCTAssertNil(oversized.value)
        XCTAssertNotNil(oversized.issue)

        let unnamed = PDFAnnotation(
            bounds: CGRect(x: 40, y: 40, width: 1, height: 1),
            forType: .widget,
            withProperties: nil
        )
        unnamed.widgetFieldType = .button
        let unnamedSnapshot = inspection.snapshot(
            unnamed,
            annotationIndex: 1,
            pageIndex: 0,
            pageBounds: pageBounds,
            placedSignatureBounds: []
        )
        XCTAssertFalse(unnamedSnapshot.name.isEmpty)
        XCTAssertNotNil(unnamedSnapshot.issue)
        XCTAssertEqual(inspection.fieldKind(unnamed), .checkbox)
        XCTAssertTrue(inspection.isWidget(unnamed))

        let ink = PDFAnnotation(
            bounds: CGRect(x: 40, y: 40, width: 180, height: 32),
            forType: .ink,
            withProperties: nil
        )
        ink.contents = "Signature"
        XCTAssertTrue(inspection.isPlacedSignature(ink))
        XCTAssertTrue(inspection.hasPlacedSignature(
            in: textWidget.bounds,
            placedSignatureBounds: [ink.bounds]
        ))
        XCTAssertFalse(inspection.hasPlacedSignature(
            in: .zero,
            placedSignatureBounds: [ink.bounds]
        ))
        XCTAssertFalse(inspection.isWidget(ink))
        XCTAssertFalse(inspection.isSafeFieldName(""))
        XCTAssertFalse(inspection.isSafeFieldName("unsafe\u{202E}name"))
        XCTAssertNil(
            inspection.fieldIssue(
                textWidget,
                kind: .text,
                bounds: textWidget.bounds,
                pageBounds: pageBounds,
                name: "Name"
            )
        )
    }

    func testTextReplacementGuardMatrixAndXRefStreamRoundTrip_BitsUT()
        throws {
        let source = temporaryDirectory.appendingPathComponent(
            "replacement-guards.pdf"
        )
        try PDFTestFixtureFactory.makeTextPDF(at: source, pageCount: 3)
        let service = PDFOutputService()
        let base = try serviceTextSelection(in: source, pageIndex: 0)

        XCTAssertThrowsError(
            try service.assessTextReplacement(
                sourceURL: temporaryDirectory.appendingPathComponent(
                    "missing.pdf"
                ),
                selection: base,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            )
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: base,
                replacement: " ",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: base,
                replacement: base.originalText,
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )

        let rotated = serviceSelection(
            from: base,
            pageRotation: 90
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: rotated,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let mixed = serviceSelection(from: base, hasMixedFonts: true)
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: mixed,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let noncontiguous = serviceSelection(
            from: base,
            flowRegions: [
                base.flowRegions[0],
                PDFTextFlowRegion(
                    pageIndex: 2,
                    normalizedX: base.normalizedX,
                    normalizedY: base.normalizedY,
                    normalizedWidth: base.normalizedWidth,
                    normalizedHeight: base.normalizedHeight,
                    lineCount: 1,
                    originalText: "Fixture page 3 amount 20"
                )
            ]
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: noncontiguous,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let unordered = serviceSelection(
            from: base,
            flowRegions: [
                PDFTextFlowRegion(
                    pageIndex: 0,
                    normalizedX: base.normalizedX,
                    normalizedY: base.normalizedY,
                    normalizedWidth: base.normalizedWidth,
                    normalizedHeight: base.normalizedHeight,
                    lineCount: 1,
                    originalText: "second",
                    sourceRangeLocation: 10,
                    sourceRangeLength: 3
                ),
                PDFTextFlowRegion(
                    pageIndex: 0,
                    normalizedX: base.normalizedX,
                    normalizedY: base.normalizedY,
                    normalizedWidth: base.normalizedWidth,
                    normalizedHeight: base.normalizedHeight,
                    lineCount: 1,
                    originalText: "first",
                    sourceRangeLocation: 2,
                    sourceRangeLength: 3
                )
            ]
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: unordered,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let excessive = serviceSelection(from: base, lineCount: 97)
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: excessive,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let tiny = serviceSelection(
            from: base,
            normalizedWidth: 0.001,
            normalizedHeight: 0.001
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: tiny,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let missingText = serviceSelection(
            from: base,
            originalText: "text that is absent"
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: missingText,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )
        let invalidPage = PDFTextSelectionSnapshot(
            pageIndex: 99,
            originalText: base.originalText,
            normalizedX: base.normalizedX,
            normalizedY: base.normalizedY,
            normalizedWidth: base.normalizedWidth,
            normalizedHeight: base.normalizedHeight,
            fontName: base.fontName,
            fontSize: base.fontSize,
            color: base.color,
            lineCount: 1,
            hasMixedFonts: false,
            pageRotation: 0
        )
        XCTAssertThrowsError(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: invalidPage,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            )
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: source,
                selection: base,
                replacement: String(repeating: "word ", count: 3_000),
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )

        let annotatedURL = temporaryDirectory.appendingPathComponent(
            "replacement-annotated.pdf"
        )
        let annotatedDocument = try XCTUnwrap(PDFDocument(url: source))
        let annotatedPage = try XCTUnwrap(annotatedDocument.page(at: 0))
        let pageBounds = annotatedPage.bounds(for: .cropBox)
        let annotationBounds = CGRect(
            x: pageBounds.minX + CGFloat(base.normalizedX) * pageBounds.width,
            y: pageBounds.maxY
                - CGFloat(base.normalizedY + base.normalizedHeight)
                    * pageBounds.height,
            width: CGFloat(base.normalizedWidth) * pageBounds.width,
            height: CGFloat(base.normalizedHeight) * pageBounds.height
        )
        annotatedPage.addAnnotation(
            PDFAnnotation(
                bounds: annotationBounds,
                forType: .square,
                withProperties: nil
            )
        )
        XCTAssertTrue(annotatedDocument.write(to: annotatedURL))
        let annotatedSelection = try serviceTextSelection(
            in: annotatedURL,
            pageIndex: 0
        )
        XCTAssertFalse(
            try service.assessTextReplacement(
                sourceURL: annotatedURL,
                selection: annotatedSelection,
                replacement: "Changed",
                fontStyle: .sans,
                alignment: .left
            ).isReady
        )

        let ready = try service.assessTextReplacement(
            sourceURL: source,
            selection: base,
            replacement: "Changed text",
            fontStyle: .sans,
            alignment: .left
        )
        XCTAssertTrue(ready.isReady, ready.detail)
        let stale = PDFTextReplacementAssessment(
            status: ready.status,
            title: ready.title,
            detail: ready.detail,
            resolvedFontName: ready.resolvedFontName,
            resolvedFontSize: ready.resolvedFontSize + 1,
            resolvedLineSpacing: ready.resolvedLineSpacing,
            reflowedLineCount: ready.reflowedLineCount,
            backgroundColor: ready.backgroundColor,
            regionBackgroundColors: ready.regionBackgroundColors,
            flowRegionTexts: ready.flowRegionTexts,
            fontStyle: ready.fontStyle,
            alignment: ready.alignment
        )
        XCTAssertThrowsError(
            try service.replaceText(
                sourceURL: source,
                destination: temporaryDirectory.appendingPathComponent(
                    "stale-replacement.pdf"
                ),
                selection: base,
                replacement: "Changed text",
                assessment: stale
            )
        )

        let blocked = service.blockedTextReplacement(
            "Blocked",
            fontStyle: .sans,
            alignment: .left
        )
        let replacementDestination = temporaryDirectory
            .appendingPathComponent("blocked-replacement.pdf")
        XCTAssertThrowsError(
            try service.replaceText(
                sourceURL: source,
                destination: replacementDestination,
                selection: base,
                replacement: "Changed",
                assessment: blocked
            )
        )
        try Data("existing".utf8).write(to: replacementDestination)
        XCTAssertThrowsError(
            try service.replaceText(
                sourceURL: source,
                destination: replacementDestination,
                selection: base,
                replacement: "Changed",
                assessment: blocked
            )
        )

        let fixture = try serviceXRefStreamFixture()
        let xref = try PDFXRefStreamDocument(data: fixture.data)
        let root = try XCTUnwrap(xref.rootCatalogObject())
        XCTAssertEqual(root.number, 1)
        XCTAssertEqual(xref.allObjects().count, 5)
        XCTAssertNotNil(
            xref.referencedObject(following: "/Pages", in: root)
        )
        XCTAssertNil(
            xref.referencedObject(following: "/Missing", in: root)
        )
        let imageObject = try XCTUnwrap(
            xref.imageObject(matching: fixture.encodedImage)
        )
        XCTAssertEqual(imageObject.number, 4)
        XCTAssertEqual(
            xref.imageObject(matchingDecodedStream: fixture.rawImage)?
                .number,
            4
        )
        XCTAssertNotNil(xref.object(number: 4, generation: 0))
        XCTAssertNil(xref.object(number: 4, generation: 1))
        XCTAssertNotNil(xref.objectData(for: imageObject))
        XCTAssertNil(
            xref.objectData(
                for: PDFImageObjectReference(
                    number: 99,
                    generation: 0,
                    offset: -1
                )
            )
        )
        let replacementImage = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2)
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let jpeg = try XCTUnwrap(
            replacementImage.jpegData(compressionQuality: 0.8)
        )
        let rewritten = try xref.replacingImageObject(
            imageObject,
            jpegData: jpeg,
            pixelWidth: 2,
            pixelHeight: 2
        )
        let reparsed = try PDFXRefStreamDocument(data: rewritten)
        XCTAssertEqual(reparsed.rootCatalogObject()?.number, 1)
        XCTAssertEqual(
            reparsed.imageObject(matching: jpeg)?.number,
            4
        )
    }

    func testOfficePackageFileValidationAndSignatureReadBounds_BitsUT()
        async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "OfficePackageValidation",
            isDirectory: true
        )
        let signingKey = Curve25519.Signing.PrivateKey()
        let store = DocumentStore(
            rootURL: root,
            signingPrivateKeyProvider: { signingKey }
        )
        let archiveSource = temporaryDirectory.appendingPathComponent(
            "validation-package.zip"
        )
        let reportSource = temporaryDirectory.appendingPathComponent(
            "validation-report.json"
        )
        let archiveData = Data("verified office archive".utf8)
        try archiveData.write(to: archiveSource)
        let entry = PDFOfficeDeliveryEntry(
            sourceRecordID: UUID(),
            sourceRevisionID: UUID(),
            sourceName: "Validation source",
            receiptID: UUID(),
            format: .wordDocument,
            archiveName: "validation.docx",
            byteCount: Int64(archiveData.count),
            sha256: serviceSHA256(archiveData)
        )
        var package = PDFOfficeDeliveryPackage(entries: [entry])
        let payload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: package.id,
            createdAt: package.createdAt,
            expiresAt: package.expiresAt,
            verifiedOutputs: 1,
            files: package.entries
        )
        let signed = try await store.signOfficeDeliveryPayload(payload)
        package.signerKeyID = signed.signature.keyID
        let reportData = try serviceJSONEncoder().encode(signed)
        try reportData.write(to: reportSource)
        let retainedResult = try await store.retainOfficeDeliveryPackage(
            package,
            archiveURL: archiveSource,
            reportURL: reportSource
        )
        let retained = retainedResult.0
        let archive = retainedResult.1
        let report = retainedResult.2
        _ = try await store.officeDeliveryPackageURLs(for: retained)

        let reportBackup = temporaryDirectory.appendingPathComponent(
            "validation-report-backup.json"
        )
        try FileManager.default.moveItem(at: report, to: reportBackup)
        do {
            _ = try await store.officeDeliveryPackageURLs(for: retained)
            XCTFail("A missing report must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        try FileManager.default.moveItem(at: reportBackup, to: report)

        let tamperedReport = Data(repeating: 0x58, count: reportData.count)
        try tamperedReport.write(to: report)
        do {
            _ = try await store.officeDeliveryPackageURLs(for: retained)
            XCTFail("A changed report digest must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        try reportData.write(to: report, options: .atomic)

        let mismatchedEntry = PDFOfficeDeliveryEntry(
            sourceRecordID: entry.sourceRecordID,
            sourceRevisionID: entry.sourceRevisionID,
            sourceName: "Changed source",
            receiptID: entry.receiptID,
            format: entry.format,
            archiveName: entry.archiveName,
            byteCount: entry.byteCount,
            sha256: entry.sha256
        )
        let mismatchedPayload = PDFOfficeVerificationPayload(
            schema: "PaperPath Office Delivery V34",
            packageID: retained.id,
            createdAt: retained.createdAt,
            expiresAt: retained.expiresAt,
            verifiedOutputs: 1,
            files: [mismatchedEntry]
        )
        let mismatchedSigned = try await store.signOfficeDeliveryPayload(
            mismatchedPayload
        )
        let mismatchedReportData = try serviceJSONEncoder().encode(
            mismatchedSigned
        )
        try mismatchedReportData.write(to: report, options: .atomic)
        var mismatchedPackage = retained
        mismatchedPackage.reportSHA256 = serviceSHA256(
            mismatchedReportData
        )
        do {
            _ = try await store.officeDeliveryPackageURLs(
                for: mismatchedPackage
            )
            XCTFail("A mismatched signed report must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }

        try reportData.write(to: report, options: .atomic)
        let archiveBackup = temporaryDirectory.appendingPathComponent(
            "validation-archive-backup.zip"
        )
        try FileManager.default.moveItem(at: archive, to: archiveBackup)
        _ = try await store.officeDeliveryPackageURLs(
            for: retained,
            reportOnly: true
        )
        do {
            _ = try await store.officeDeliveryPackageURLs(for: retained)
            XCTFail("A missing archive must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        try FileManager.default.moveItem(at: archiveBackup, to: archive)

        try Data("short".utf8).write(to: archive, options: .atomic)
        do {
            _ = try await store.officeDeliveryPackageURLs(for: retained)
            XCTFail("A changed archive size must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        let sameSizeTamper = Data(
            repeating: 0x59,
            count: archiveData.count
        )
        try sameSizeTamper.write(to: archive, options: .atomic)
        do {
            _ = try await store.officeDeliveryPackageURLs(for: retained)
            XCTFail("A changed archive digest must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }

        let signatureRoot = temporaryDirectory.appendingPathComponent(
            "SignatureReadBounds",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: signatureRoot,
            withIntermediateDirectories: true
        )
        let signatureStore = SignatureStore(rootURL: signatureRoot)
        let boundedURL = signatureRoot.appendingPathComponent("bounded.data")
        let boundedPayload = Data("bounded".utf8)
        try boundedPayload.write(to: boundedURL)
        let loadedBounded = try await signatureStore.boundedData(
            at: boundedURL,
            maximumBytes: boundedPayload.count
        )
        XCTAssertEqual(loadedBounded, boundedPayload)
        do {
            _ = try await signatureStore.boundedData(
                at: boundedURL,
                maximumBytes: -1
            )
            XCTFail("A negative read limit must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        do {
            _ = try await signatureStore.boundedData(
                at: boundedURL,
                maximumBytes: Int.max
            )
            XCTFail("An overflowing read limit must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        do {
            _ = try await signatureStore.boundedData(
                at: boundedURL,
                maximumBytes: boundedPayload.count - 1
            )
            XCTFail("An oversized payload must be rejected")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }
        do {
            _ = try await signatureStore.boundedData(
                at: signatureRoot,
                maximumBytes: 100
            )
            XCTFail("A directory must not be read as signature data")
        } catch {
            XCTAssertNotNil(error as? PaperPathError)
        }

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: ExternalPDFInbox.appGroupIdentifier)
        )
        let previousLanguage = defaults.object(forKey: "app.language")
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: "app.language")
            } else {
                defaults.removeObject(forKey: "app.language")
            }
        }
        defaults.set("en", forKey: "app.language")
        XCTAssertEqual(
            ExternalPDFInbox.localized("Shared PDF"),
            "Shared PDF"
        )
        XCTAssertEqual(
            ExternalPDFInbox.localizationLocale.identifier,
            "en"
        )
        defaults.set("zh-Hans", forKey: "app.language")
        XCTAssertFalse(
            ExternalPDFInbox.localized("Shared PDF").isEmpty
        )
        XCTAssertEqual(
            ExternalPDFInbox.localizationLocale.identifier,
            "zh-Hans"
        )
        defaults.set("system", forKey: "app.language")
        XCTAssertFalse(
            ExternalPDFInbox.localized("Shared PDF").isEmpty
        )
        XCTAssertFalse(
            ExternalPDFInbox.localizationLocale.identifier.isEmpty
        )
    }

    func testStructureDigestColorAndVerificationHelpers_BitsUT()
        async throws {
        let structure = PDFDocumentStructureService()
        let payload = Data(repeating: 0x5A, count: 1_048_577)
        let payloadURL = temporaryDirectory.appendingPathComponent(
            "attachment.bin"
        )
        try payload.write(to: payloadURL)
        XCTAssertEqual(
            try structure.fileSHA256(
                at: payloadURL,
                expectedByteCount: payload.count
            ),
            serviceSHA256(payload)
        )
        XCTAssertThrowsError(
            try structure.fileSHA256(
                at: payloadURL,
                expectedByteCount: -1
            )
        )
        XCTAssertThrowsError(
            try structure.fileSHA256(
                at: payloadURL,
                expectedByteCount: payload.count - 1
            )
        )
        let cancelledDigest = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try structure.fileSHA256(
                at: payloadURL,
                expectedByteCount: payload.count
            )
        }
        do {
            _ = try await cancelledDigest.value
            XCTFail("A cancelled digest must stop reading")
        } catch is CancellationError {
            // Expected.
        }

        var usedNames: Set<String> = []
        XCTAssertEqual(
            structure.uniqueFileName(
                "Report.PDF",
                usedNames: &usedNames
            ),
            "Report.PDF"
        )
        XCTAssertEqual(
            structure.uniqueFileName(
                "report.pdf",
                usedNames: &usedNames
            ),
            "report 2.pdf"
        )
        usedNames.insert("notes")
        usedNames.insert("notes 2")
        XCTAssertEqual(
            structure.uniqueFileName("Notes", usedNames: &usedNames),
            "Notes 3"
        )

        let annotationURL = temporaryDirectory.appendingPathComponent(
            "annotation-colors.pdf"
        )
        try PDFTestFixtureFactory.writeClassicPDF(
            objects: [
                .init(1, "<< /Type /Catalog /Pages 2 0 R >>"),
                .init(
                    2,
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
                ),
                .init(
                    3,
                    """
                    << /Type /Page /Parent 2 0 R
                       /MediaBox [0 0 200 200]
                       /Resources << >>
                       /Contents 4 0 R
                       /Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R] >>
                    """
                ),
                .init(4, "<< /Length 0 >>", stream: Data()),
                .init(
                    5,
                    "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] >>"
                ),
                .init(
                    6,
                    "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] /C [0.25] >>"
                ),
                .init(
                    7,
                    "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] /C [0.1 0.2] >>"
                ),
                .init(
                    8,
                    "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] /C [0.1 0.2 0.3] >>"
                ),
                .init(
                    9,
                    "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] /C [0.2 /Invalid 0.4] >>"
                )
            ],
            rootObjectNumber: 1,
            to: annotationURL
        )
        let cgDocument = try XCTUnwrap(
            CGPDFDocument(annotationURL as CFURL)
        )
        let cgPage = try XCTUnwrap(cgDocument.page(at: 1))
        let pageDictionary = try XCTUnwrap(cgPage.dictionary)
        var annotationArray: CGPDFArrayRef?
        XCTAssertTrue(
            CGPDFDictionaryGetArray(
                pageDictionary,
                "Annots",
                &annotationArray
            )
        )
        let annotations = try XCTUnwrap(annotationArray)

        func color(at index: Int) throws -> PDFInkColor {
            var dictionary: CGPDFDictionaryRef?
            XCTAssertTrue(
                CGPDFArrayGetDictionary(
                    annotations,
                    index,
                    &dictionary
                )
            )
            return structure.annotationColor(
                in: try XCTUnwrap(dictionary)
            )
        }

        let fallback = try color(at: 0)
        XCTAssertEqual(fallback.red, 0.95, accuracy: 0.0001)
        XCTAssertEqual(fallback.green, 0.72, accuracy: 0.0001)
        XCTAssertEqual(fallback.blue, 0.08, accuracy: 0.0001)
        let gray = try color(at: 1)
        XCTAssertEqual(gray.red, 0.25, accuracy: 0.0001)
        XCTAssertEqual(gray.green, 0.25, accuracy: 0.0001)
        XCTAssertEqual(gray.blue, 0.25, accuracy: 0.0001)
        let shortColor = try color(at: 2)
        XCTAssertEqual(shortColor, fallback)
        let rgb = try color(at: 3)
        XCTAssertEqual(rgb.red, 0.1, accuracy: 0.0001)
        XCTAssertEqual(rgb.green, 0.2, accuracy: 0.0001)
        XCTAssertEqual(rgb.blue, 0.3, accuracy: 0.0001)
        XCTAssertEqual(try color(at: 4), fallback)

        let archiveVerifier = PDFVersionArchiveVerificationService()
        XCTAssertTrue(archiveVerifier.isSHA256(String(repeating: "a", count: 64)))
        XCTAssertTrue(archiveVerifier.isSHA256(String(repeating: "F", count: 64)))
        XCTAssertFalse(archiveVerifier.isSHA256(String(repeating: "a", count: 63)))
        XCTAssertFalse(
            archiveVerifier.isSHA256(String(repeating: "g", count: 64))
        )
        guard case .outputVerificationFailed(let archiveReason) =
                archiveVerifier.verificationFailure("archive detail")
        else {
            return XCTFail("Expected an archive verification failure")
        }
        XCTAssertEqual(archiveReason, "archive detail")

        let shareVerifier = PDFOfficeArtifactShareVerificationService()
        guard case .outputVerificationFailed(let unavailableReason) =
                shareVerifier.unavailableFile("Report.docx"),
              case .outputVerificationFailed(let changedReason) =
                shareVerifier.changedFile("Report.docx"),
              case .outputVerificationFailed(let directReason) =
                shareVerifier.verificationFailure("share detail")
        else {
            return XCTFail("Expected Office sharing verification failures")
        }
        XCTAssertTrue(unavailableReason.contains("Report.docx"))
        XCTAssertTrue(changedReason.contains("Report.docx"))
        XCTAssertEqual(directReason, "share detail")
    }

    private func servicePDFHex(_ value: String) -> String {
        Data(value.utf8)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private func serviceFormField(
        id: String,
        name: String,
        value: String?,
        kind: PDFFormFieldKind = .text
    ) -> PDFFormFieldSnapshot {
        PDFFormFieldSnapshot(
            id: id,
            pageIndex: 0,
            annotationIndex: 0,
            name: name,
            kind: kind,
            value: value,
            normalizedBounds: PDFNormalizedRect(
                x: 0.1,
                y: 0.1,
                width: 0.4,
                height: 0.08
            ),
            isRequired: false,
            isReadOnly: false,
            isMultiline: false,
            maximumLength: nil,
            optionCount: 0,
            hasAppearanceStream: false,
            issue: nil
        )
    }

    private func serviceTextSelection(
        in url: URL,
        pageIndex: Int
    ) throws -> PDFTextSelectionSnapshot {
        let page = try XCTUnwrap(
            PDFDocument(url: url)?.page(at: pageIndex)
        )
        let text = try XCTUnwrap(page.string)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = (page.string! as NSString).range(of: text)
        let nativeSelection = try XCTUnwrap(page.selection(for: range))
        let pageBounds = page.bounds(for: .cropBox)
        let textBounds = nativeSelection.bounds(for: page)
        let normalizedX =
            (textBounds.minX - pageBounds.minX) / pageBounds.width
        let normalizedY =
            (pageBounds.maxY - textBounds.maxY) / pageBounds.height
        let normalizedWidth = textBounds.width / pageBounds.width
        let normalizedHeight = textBounds.height / pageBounds.height
        return PDFTextSelectionSnapshot(
            pageIndex: pageIndex,
            originalText: text,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            normalizedWidth: normalizedWidth,
            normalizedHeight: normalizedHeight,
            fontName: "Helvetica",
            fontSize: 18,
            color: PDFInkColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: 1
            ),
            lineCount: 1,
            hasMixedFonts: false,
            pageRotation: 0,
            flowRegions: [
                PDFTextFlowRegion(
                    pageIndex: pageIndex,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY,
                    normalizedWidth: normalizedWidth,
                    normalizedHeight: normalizedHeight,
                    lineCount: 1,
                    originalText: text,
                    sourceRangeLocation: range.location,
                    sourceRangeLength: range.length
                )
            ]
        )
    }

    private func serviceSelection(
        from source: PDFTextSelectionSnapshot,
        originalText: String? = nil,
        normalizedWidth: Double? = nil,
        normalizedHeight: Double? = nil,
        lineCount: Int? = nil,
        hasMixedFonts: Bool? = nil,
        pageRotation: Int? = nil,
        flowRegions: [PDFTextFlowRegion]? = nil
    ) -> PDFTextSelectionSnapshot {
        let resolvedText = originalText ?? source.originalText
        let resolvedWidth = normalizedWidth ?? source.normalizedWidth
        let resolvedHeight = normalizedHeight ?? source.normalizedHeight
        let resolvedLineCount = lineCount ?? source.lineCount
        let changedRegion =
            originalText != nil
                || normalizedWidth != nil
                || normalizedHeight != nil
                || lineCount != nil
        let resolvedRegions = flowRegions
            ?? (
                changedRegion
                    ? [
                        PDFTextFlowRegion(
                            pageIndex: source.pageIndex,
                            normalizedX: source.normalizedX,
                            normalizedY: source.normalizedY,
                            normalizedWidth: resolvedWidth,
                            normalizedHeight: resolvedHeight,
                            lineCount: resolvedLineCount,
                            originalText: resolvedText,
                            sourceRangeLocation:
                                source.flowRegions.first?
                                    .sourceRangeLocation,
                            sourceRangeLength:
                                source.flowRegions.first?
                                    .sourceRangeLength
                        )
                    ]
                    : source.flowRegions
            )
        return PDFTextSelectionSnapshot(
            id: source.id,
            pageIndex: source.pageIndex,
            originalText: resolvedText,
            normalizedX: source.normalizedX,
            normalizedY: source.normalizedY,
            normalizedWidth: resolvedWidth,
            normalizedHeight: resolvedHeight,
            fontName: source.fontName,
            fontSize: source.fontSize,
            color: source.color,
            lineCount: resolvedLineCount,
            hasMixedFonts: hasMixedFonts ?? source.hasMixedFonts,
            pageRotation: pageRotation ?? source.pageRotation,
            flowRegions: resolvedRegions
        )
    }

    private func serviceXRefStreamFixture() throws -> (
        data: Data,
        rawImage: Data,
        encodedImage: Data
    ) {
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]

        func append(_ value: String) {
            data.append(Data(value.utf8))
        }

        func appendObject(
            _ number: Int,
            dictionary: String,
            stream: Data? = nil
        ) {
            offsets[number] = data.count
            append("\(number) 0 obj\n\(dictionary)")
            if let stream {
                append("\nstream\n")
                data.append(stream)
                append("\nendstream")
            }
            append("\nendobj\n")
        }

        let rawImage = Data([255, 0, 0])
        let encodedImage = try XCTUnwrap(
            PDFXRefStreamDocument.deflateZlib(rawImage)
        )
        let pageCommands = Data(
            "q\n100 0 0 100 40 40 cm\n/Im0 Do\nQ\n".utf8
        )
        appendObject(
            1,
            dictionary: "<< /Type /Catalog /Pages 2 0 R >>"
        )
        appendObject(
            2,
            dictionary: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        )
        appendObject(
            3,
            dictionary:
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 320] "
                + "/Resources << /XObject << /Im0 4 0 R >> >> "
                + "/Contents 5 0 R >>"
        )
        appendObject(
            4,
            dictionary:
                "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
                + "/ColorSpace /DeviceRGB /BitsPerComponent 8 "
                + "/Filter /FlateDecode /Length \(encodedImage.count) >>",
            stream: encodedImage
        )
        appendObject(
            5,
            dictionary: "<< /Length \(pageCommands.count) >>",
            stream: pageCommands
        )

        let xrefOffset = data.count
        offsets[6] = xrefOffset
        var xrefBytes = Data()
        func appendBigEndian(
            _ value: UInt64,
            width: Int
        ) {
            guard width > 0 else { return }
            for index in stride(from: width - 1, through: 0, by: -1) {
                xrefBytes.append(
                    UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
                )
            }
        }
        for number in 0..<7 {
            appendBigEndian(number == 0 ? 0 : 1, width: 1)
            appendBigEndian(
                UInt64(offsets[number] ?? 0),
                width: 8
            )
            appendBigEndian(number == 0 ? 65_535 : 0, width: 4)
        }
        let encodedXRef = try XCTUnwrap(
            PDFXRefStreamDocument.deflateZlib(xrefBytes)
        )
        append(
            "6 0 obj\n"
                + "<< /Type /XRef /Size 7 /Root 1 0 R "
                + "/W [1 8 4] /Index [0 7] /Filter /FlateDecode "
                + "/Length \(encodedXRef.count) >>\nstream\n"
        )
        data.append(encodedXRef)
        append(
            """

            endstream
            endobj
            startxref
            \(xrefOffset)
            %%EOF

            """
        )
        return (data, rawImage, encodedImage)
    }

    private func serviceSHA256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func serviceSignature<Value: Encodable>(
        for value: Value,
        key: Curve25519.Signing.PrivateKey
    ) throws -> PDFOfficeVerificationSignature {
        let payload = try serviceJSONEncoder().encode(value)
        let publicKey = key.publicKey.rawRepresentation
        let keyID = String(serviceSHA256(publicKey).prefix(16))
        return PDFOfficeVerificationSignature(
            algorithm: "Ed25519",
            keyID: keyID,
            publicKeyBase64: publicKey.base64EncodedString(),
            signatureBase64: try key.signature(
                for: payload
            ).base64EncodedString()
        )
    }

    private func writeServiceJSON<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let encoder = serviceJSONEncoder()
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func serviceJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func serviceJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class TestServiceProgressRecorder: @unchecked Sendable {
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

private final class MoveFailingFileManager:
    FileManager,
    @unchecked Sendable {
    var deniedDestinationPath: String?

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.path == deniedDestinationPath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@MainActor
private final class TestServiceMetadataKeyValueStore:
    PDFMetadataKeyValueStore {
    let isCloudBacked: Bool
    var synchronizeResult = true
    private(set) var storage: [String: Data] = [:]

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
