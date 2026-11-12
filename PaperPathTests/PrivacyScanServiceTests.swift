import Combine
import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import PaperPath

final class PrivacyRedactionShareTests: XCTestCase {
    @MainActor
    func testPrepare_preservesVerifiedBytesAndOwnsTemporaryCopy_BitsUT()
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
            "edit-after-preparation", "delete-after-preparation", "cleanup",
            "stale-output", "deleted-output", "unverified-output", "cancelled"
        ] {
            try await exerciseShare(scenario: scenario)
        }
    }

    @MainActor
    func testSharingSampleNeverReusesOrChangesAnExistingDocument() async throws {
        let syncKey = AppPreferences.metadataSyncEnabledKey
        let oldSync = UserDefaults.standard.object(forKey: syncKey)
        UserDefaults.standard.set(false, forKey: syncKey)
        defer {
            if let oldSync { UserDefaults.standard.set(oldSync, forKey: syncKey) }
            else { UserDefaults.standard.removeObject(forKey: syncKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareCheckSample-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("real-source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 1)
        let store = DocumentStore(rootURL: root.appendingPathComponent("Store"))
        let source = try await store.importPDF(from: input, preserveSourceLocation: false)
        let model = PaperPathModel(store: store, signatureStore: SignatureStore(rootURL: root.appendingPathComponent("Signatures")))
        await model.bootstrap()
        let sourceURL = try XCTUnwrap(model.url(for: source.id))
        let bytes = try Data(contentsOf: sourceURL)
        let first = try await model.createShareCheckSample()
        let second = try await model.createShareCheckSample()
        XCTAssertNotEqual(first.id, source.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        XCTAssertEqual(model.record(id: source.id)?.contentRevisionID, source.contentRevisionID)
        for sample in [first, second] {
            let url = try XCTUnwrap(model.url(for: sample.id))
            let pdf = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertEqual(pdf.pageCount, 1)
            XCTAssertTrue(pdf.string?.contains("billing@example.com") == true)
            XCTAssertTrue(pdf.string?.contains("fictional sample data") == true)
        }
    }

    @MainActor
    private func exerciseShare(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyShare-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 1)
        let store = DocumentStore(rootURL: root.appendingPathComponent("Store"))
        let source = try await store.importPDF(
            from: input, preserveSourceLocation: false
        )
        let model = PaperPathModel(store: store)
        await model.bootstrap()
        let sourceURL = try XCTUnwrap(model.url(for: source.id))
        let sourceBytes = try Data(contentsOf: sourceURL)
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)
        )
        let selection = PrivacyRedactionSelection(
            findings: [
                PrivacyFinding(
                    id: UUID(), fingerprint: "fixture-email",
                    category: .email, pageIndex: 0,
                    rawValue: "alex@example.com", maskedValue: "a***@example.com",
                    confidence: .high, source: .nativeText,
                    normalizedBounds: [bounds],
                    reason: "Test selection"
                )
            ],
            appearance: .black
        )
        let redacted = await model.createRedactedCopy(
            recordID: source.id,
            marks: selection.redactionMarks,
            expectedContentRevisionID: source.contentRevisionID
        )
        let created = try XCTUnwrap(redacted, scenario)
        XCTAssertTrue(created.hasCurrentDeliveryReceipt, scenario)
        let managedURL = try XCTUnwrap(model.url(for: created.id))
        let verifiedBytes = try Data(contentsOf: managedURL)

        if scenario == "deleted-output" {
            let deleted = await model.delete(recordID: created.id)
            XCTAssertTrue(deleted, scenario)
        }
        var candidate = scenario == "unverified-output" ? source : created
        if scenario == "stale-output" {
            candidate.contentRevisionID = UUID()
        }
        let mustReject = [
            "stale-output", "deleted-output", "unverified-output", "cancelled"
        ].contains(scenario)
        var outcome: PrivacyRedactionOutcome?
        do {
            if scenario == "cancelled" {
                let preparation = Task { @MainActor in
                    try await PrivacyRedactionOutcome.prepare(
                        createdRecord: candidate, selection: selection, model: model
                    )
                }
                preparation.cancel()
                outcome = try await preparation.value
            } else {
                outcome = try await PrivacyRedactionOutcome.prepare(
                    createdRecord: candidate, selection: selection, model: model
                )
            }
            XCTAssertFalse(mustReject, scenario)
        } catch {
            XCTAssertTrue(mustReject, "\(scenario): \(error)")
        }
        if !mustReject, let outputURL = outcome?.outputURL {
            XCTAssertNotEqual(outputURL, managedURL, scenario)
            XCTAssertTrue(
                outputURL.deletingLastPathComponent().lastPathComponent
                    .hasPrefix("PaperPath-FilesExport-"), scenario
            )
            XCTAssertEqual(try Data(contentsOf: outputURL), verifiedBytes, scenario)
            XCTAssertEqual(outcome?.verifiedFindingCount, 1, scenario)
            XCTAssertEqual(outcome?.affectedPageCount, 1, scenario)
#if !targetEnvironment(simulator)
            let protection = try FileManager.default.attributesOfItem(
                atPath: outputURL.path
            )[.protectionKey] as? FileProtectionType
            XCTAssertEqual(protection, .complete, scenario)
#endif
            if scenario == "edit-after-preparation" {
                let changed = await model.rotatePages(recordID: created.id, indices: [0])
                XCTAssertTrue(changed, scenario)
                XCTAssertNotEqual(try Data(contentsOf: managedURL), verifiedBytes, scenario)
                XCTAssertFalse(model.record(id: created.id)?.hasCurrentDeliveryReceipt ?? true)
            } else if scenario == "delete-after-preparation" {
                let deleted = await model.delete(recordID: created.id)
                XCTAssertTrue(deleted, scenario)
                await model.permanentlyDelete(recordID: created.id)
                XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path), scenario)
            }
            XCTAssertEqual(try? Data(contentsOf: outputURL), verifiedBytes, scenario)
            outcome = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path), scenario)
        }
        XCTAssertEqual(try Data(contentsOf: input), sourceBytes, scenario)
        XCTAssertFalse(model.hasActiveLocalDataOperations, scenario)
    }
}

final class PrivacyScanServiceTests: XCTestCase {
    private var previousLanguageCode: String?

    override func setUpWithError() throws {
        previousLanguageCode = UserDefaults.standard.string(
            forKey: AppLanguage.defaultsKey
        )
        UserDefaults.standard.set(
            AppLanguage.english.rawValue,
            forKey: AppLanguage.defaultsKey
        )
    }

    override func tearDownWithError() throws {
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

    func testSupportedCategoriesRemainVisibleWithoutFindings() {
        XCTAssertEqual(
            Set(PrivacyCategory.allCases),
            [
                .email,
                .phone,
                .identityNumber,
                .socialSecurityNumber,
                .taxIdentifier,
                .passportNumber,
                .bankAccount,
                .paymentCard,
                .ipAddress,
                .date,
                .address
            ]
        )
    }

    func testPaymentCardRequiresValidLuhnChecksum() {
        XCTAssertTrue(
            PrivacyScanService.passesLuhnCheck("4111 1111 1111 1111")
        )
        XCTAssertTrue(
            PrivacyScanService.passesLuhnCheck("5555-5555-5555-4444")
        )
        XCTAssertFalse(
            PrivacyScanService.passesLuhnCheck("4111 1111 1111 1112")
        )
        XCTAssertFalse(
            PrivacyScanService.passesLuhnCheck("12345")
        )
        XCTAssertFalse(
            PrivacyScanService.passesLuhnCheck("4111a1111 1111 1111")
        )
        XCTAssertFalse(
            PrivacyScanService.passesLuhnCheck("４１１１ １１１１ １１１１ １１１１")
        )
    }

    func testIBANValidation() {
        XCTAssertTrue(
            PrivacyScanService.passesIBANCheck(
                "GB82 WEST 1234 5698 7654 32"
            )
        )
        XCTAssertTrue(
            PrivacyScanService.passesIBANCheck(
                "DE89 3704 0044 0532 0130 00"
            )
        )
        XCTAssertFalse(
            PrivacyScanService.passesIBANCheck(
                "GB82 WEST 1234 5698 7654 31"
            )
        )
        XCTAssertFalse(
            PrivacyScanService.passesIBANCheck(
                "GB76 WEST 1234 5698 7654 320"
            ),
            "A checksum-valid IBAN with the wrong national length is invalid."
        )
        XCTAssertFalse(
            PrivacyScanService.passesIBANCheck(
                "GB82-WEST-1234-5698-7654-32"
            )
        )
    }

    func testEmailValidationRejectsPartialAndInvalidDomains() {
        XCTAssertTrue(
            PrivacyScanService.passesEmailCheck("alex.smith@example.com")
        )
        XCTAssertFalse(
            PrivacyScanService.passesEmailCheck("alex..smith@example.com")
        )
        XCTAssertFalse(
            PrivacyScanService.passesEmailCheck("alex@-example.com")
        )

        let findings = PrivacyScanService().candidates(
            in: "Invalid alex..smith@example.com and alex@-example.com"
        )
        XCTAssertFalse(findings.contains { $0.category == .email })
    }

    func testEmailDetectionRecognizesSentenceEndWithoutPartialAddresses() {
        let scenarios: [(String, [String])] = [
            ("Contact alex@example.com.", ["alex@example.com"]),
            ("Contact alex@example.com. Next step.", ["alex@example.com"]),
            ("Contact alex@example.com.\nNext step.", ["alex@example.com"]),
            ("(alex@example.com.)", ["alex@example.com"]),
            ("Contact alex@example.co.uk.", ["alex@example.co.uk"]),
            ("alex@example.com, sam@example.org;", [
                "alex@example.com", "sam@example.org"
            ]),
            ("alex..smith@example.com.", []),
            ("alex@-example.com.", []),
            ("alex@example..com.", []),
            ("alex@example.com..invalid", []),
            ("alex@example.com.invalid_suffix", []),
            ("alex@example.com.123", []),
            ("alex@example.com-extra", []),
        ]
        for (text, expected) in scenarios {
            let emails = PrivacyScanService().candidates(in: text)
                .filter { $0.category == .email }
                .map(\.rawValue)
            XCTAssertEqual(emails, expected, "Input: \(text)")
        }
    }

    func testIdentityChecksumsAndReservedRanges() {
        XCTAssertTrue(
            PrivacyScanService.passesChineseIdentityCheck(
                "11010519491231002X"
            )
        )
        XCTAssertFalse(
            PrivacyScanService.passesChineseIdentityCheck(
                "110105194912310021"
            )
        )
        XCTAssertFalse(
            PrivacyScanService.passesChineseIdentityCheck(
                "110105199902310029"
            ),
            "A checksum-valid identity number must still contain a real date."
        )
        XCTAssertFalse(
            PrivacyScanService.passesChineseIdentityCheck(
                "110105209912310029"
            ),
            "A checksum-valid identity number cannot contain a future birth date."
        )
        XCTAssertTrue(
            PrivacyScanService.passesSocialSecurityCheck("123-45-6789")
        )
        XCTAssertFalse(
            PrivacyScanService.passesSocialSecurityCheck("000-45-6789")
        )
        XCTAssertFalse(
            PrivacyScanService.passesSocialSecurityCheck("900-45-6789")
        )
    }

    func testIPv6ValidationRejectsPartialAddresses() {
        XCTAssertTrue(
            PrivacyScanService.passesIPv6Check(
                "2001:db8::8a2e:370:7334"
            )
        )
        XCTAssertTrue(PrivacyScanService.passesIPv6Check("::1"))
        XCTAssertFalse(PrivacyScanService.passesIPv6Check("1:2:3"))

        let findings = PrivacyScanService().candidates(
            in: "Valid ::1 and 2001:db8::8a2e:370:7334; invalid 1:2:3."
        ).filter { $0.category == .ipAddress }

        XCTAssertEqual(
            Set(findings.map(\.rawValue)),
            ["::1", "2001:db8::8a2e:370:7334"]
        )
    }

    func testIPv4ValidationUsesCanonicalASCIIAddress() {
        XCTAssertTrue(
            PrivacyScanService.passesIPv4Check("192.168.10.24")
        )
        XCTAssertFalse(
            PrivacyScanService.passesIPv4Check("192.168.001.24")
        )
        XCTAssertFalse(
            PrivacyScanService.passesIPv4Check("１９２.１６８.１０.２４")
        )
    }

    func testCandidateClassificationAndInvalidCardRejection() {
        let findings = PrivacyScanService().candidates(
            in: """
            Email: alex@example.com
            Passport No: A12345678
            Card: 4111 1111 1111 1111
            Invalid card: 4111 1111 1111 1112
            IBAN: GB82 WEST 1234 5698 7654 32
            IP: 192.168.10.24
            """
        )

        XCTAssertTrue(
            findings.contains {
                $0.category == .email
                    && $0.rawValue == "alex@example.com"
            }
        )
        XCTAssertTrue(
            findings.contains {
                $0.category == .passportNumber
                    && $0.rawValue == "A12345678"
            }
        )
        XCTAssertTrue(
            findings.contains {
                $0.category == .paymentCard
                    && $0.rawValue.contains("4111 1111 1111 1111")
            }
        )
        XCTAssertFalse(
            findings.contains {
                $0.category == .paymentCard
                    && $0.rawValue.contains("1112")
            }
        )
        XCTAssertTrue(
            findings.contains { $0.category == .bankAccount }
        )
        XCTAssertTrue(
            findings.contains { $0.category == .ipAddress }
        )
    }

    func testMasksDoNotExposeFullSensitiveValue() {
        XCTAssertEqual(
            PrivacyScanService.maskedValue(
                "alex@example.com",
                category: .email
            ),
            "a***@example.com"
        )
        XCTAssertEqual(
            PrivacyScanService.maskedValue(
                "4111 1111 1111 1111",
                category: .paymentCard
            ),
            "****1111"
        )
        XCTAssertEqual(
            PrivacyScanService.maskedValue(
                "192.168.10.24",
                category: .ipAddress
            ),
            "***.***.***.24"
        )
    }

    func testNormalizedRectAccountsForNonZeroCropBoxOrigin() {
        let cropBox = CGRect(
            x: 100,
            y: 200,
            width: 400,
            height: 800
        )
        let source = CGRect(
            x: 120,
            y: 230,
            width: 100,
            height: 50
        )

        let normalized = PrivacyNormalizedRect(
            rect: source,
            relativeTo: cropBox
        )

        XCTAssertEqual(normalized?.x ?? -1, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(normalized?.y ?? -1, 0.0375, accuracy: 0.000_001)
        XCTAssertEqual(normalized?.width ?? -1, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(normalized?.height ?? -1, 0.0625, accuracy: 0.000_001)
    }

    func testNormalizedRectClipsToCropBox() {
        let cropBox = CGRect(
            x: 40,
            y: 60,
            width: 200,
            height: 100
        )
        let source = CGRect(
            x: 20,
            y: 40,
            width: 80,
            height: 60
        )

        let normalized = PrivacyNormalizedRect(
            rect: source,
            relativeTo: cropBox
        )

        XCTAssertEqual(normalized?.x ?? -1, 0, accuracy: 0.000_001)
        XCTAssertEqual(normalized?.y ?? -1, 0, accuracy: 0.000_001)
        XCTAssertEqual(normalized?.width ?? -1, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(normalized?.height ?? -1, 0.4, accuracy: 0.000_001)
    }

    func testOutOfBoundsRectIsRejected() {
        XCTAssertNil(
            PrivacyNormalizedRect(
                rect: CGRect(x: 500, y: 500, width: 20, height: 20),
                relativeTo: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
        )
    }

    func testNormalizedRectRejectsNonFiniteCropBox() {
        XCTAssertNil(
            PrivacyNormalizedRect(
                rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                relativeTo: CGRect(
                    x: CGFloat.infinity,
                    y: 0,
                    width: 100,
                    height: 100
                )
            )
        )
    }

    func testNativePDFFindingHasPageCoordinates() throws {
        let data = makePDF(
            text: "Contact alex@example.com before sharing."
        )
        let document = try XCTUnwrap(PDFDocument(data: data))

        let result = try PrivacyScanService().scan(document: document)
        let email = try XCTUnwrap(
            result.findings.first { $0.category == .email }
        )

        XCTAssertEqual(email.pageIndex, 0)
        XCTAssertTrue(email.isLocatable)
        XCTAssertTrue(
            email.normalizedBounds.allSatisfy {
                $0.x >= 0
                    && $0.y >= 0
                    && $0.x + $0.width <= 1.000_001
                    && $0.y + $0.height <= 1.000_001
            }
        )
    }

    func testSpatialOCRFindingRemainsLocatable() throws {
        let data = makePDF(text: "")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.2,
                y: 0.4,
                width: 0.35,
                height: 0.05
            )
        )

        let result = try PrivacyScanService().scan(
            document: document,
            spatialOCR: [
                PrivacySpatialTextObservation(
                    pageIndex: 0,
                    text: "alex@example.com",
                    normalizedBounds: bounds,
                    confidence: 0.96
                )
            ],
            performsOCRFallback: false
        )
        let finding = try XCTUnwrap(result.findings.first)

        XCTAssertEqual(finding.category, .email)
        XCTAssertEqual(
            finding.source,
            .opticalCharacterRecognition
        )
        XCTAssertTrue(finding.isLocatable)
        XCTAssertEqual(finding.normalizedBounds, [bounds])
    }

    func testNonFiniteSpatialConfidenceIsNeverAutoSelected() throws {
        let document = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.2,
                y: 0.4,
                width: 0.35,
                height: 0.05
            )
        )

        let result = try PrivacyScanService().scan(
            document: document,
            spatialOCR: [
                PrivacySpatialTextObservation(
                    pageIndex: 0,
                    text: "alex@example.com",
                    normalizedBounds: bounds,
                    confidence: .nan
                )
            ],
            performsOCRFallback: false
        )
        let finding = try XCTUnwrap(result.findings.first)

        XCTAssertEqual(finding.confidence, .low)
        XCTAssertFalse(finding.isSelectedByDefault)
    }

    func testStoredOCRBlocksBecomeValidatedSpatialObservations() throws {
        let document = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let result = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "alex@example.com",
                    confidence: 0.9,
                    blocks: [
                        OCRTextBlock(
                            text: " alex@example.com ",
                            confidence: 0.74,
                            normalizedX: 0.1,
                            normalizedY: 0.2,
                            normalizedWidth: 0.4,
                            normalizedHeight: 0.08,
                            isUserCorrected: true
                        ),
                        OCRTextBlock(
                            text: " ",
                            confidence: 0.9,
                            normalizedX: 0,
                            normalizedY: 0,
                            normalizedWidth: 1,
                            normalizedHeight: 1
                        ),
                        OCRTextBlock(
                            text: "invalid bounds",
                            confidence: 0.9,
                            normalizedX: .nan,
                            normalizedY: 0,
                            normalizedWidth: 0.2,
                            normalizedHeight: 0.1
                        )
                    ]
                ),
                OCRPageResult(
                    pageIndex: 3,
                    text: "outside.pdf@example.com",
                    confidence: 0.9,
                    blocks: [
                        OCRTextBlock(
                            text: "outside.pdf@example.com",
                            confidence: 0.9,
                            normalizedX: 0.1,
                            normalizedY: 0.1,
                            normalizedWidth: 0.4,
                            normalizedHeight: 0.1
                        )
                    ]
                )
            ]
        )

        let observations = try PrivacyScanService.spatialObservations(
            from: result,
            document: document
        )

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.pageIndex, 0)
        XCTAssertEqual(observations.first?.text, "alex@example.com")
        XCTAssertEqual(observations.first?.confidence, 1)
    }

    func testStoredOCRCoordinatesRespectCropBoxAndRotation() throws {
        let document = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let page = try XCTUnwrap(document.page(at: 0))
        let mediaBox = page.bounds(for: .mediaBox)
        let cropBox = CGRect(
            x: mediaBox.minX + mediaBox.width * 0.2,
            y: mediaBox.minY + mediaBox.height * 0.15,
            width: mediaBox.width * 0.6,
            height: mediaBox.height * 0.7
        )
        page.setBounds(cropBox, for: .cropBox)
        let absolute = CGRect(
            x: cropBox.minX + cropBox.width * 0.25,
            y: cropBox.minY + cropBox.height * 0.3,
            width: cropBox.width * 0.2,
            height: cropBox.height * 0.1
        )
        let croppedResult = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "crop@example.com",
                    confidence: 0.9,
                    blocks: [
                        OCRTextBlock(
                            text: "crop@example.com",
                            confidence: 0.9,
                            normalizedX: (
                                absolute.minX - mediaBox.minX
                            ) / mediaBox.width,
                            normalizedY: (
                                absolute.minY - mediaBox.minY
                            ) / mediaBox.height,
                            normalizedWidth:
                                absolute.width / mediaBox.width,
                            normalizedHeight:
                                absolute.height / mediaBox.height
                        )
                    ]
                )
            ]
        )

        let cropped = try XCTUnwrap(
            PrivacyScanService.spatialObservations(
                from: croppedResult,
                document: document
            ).first?.normalizedBounds
        )
        XCTAssertEqual(cropped.x, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(cropped.y, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(cropped.width, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(cropped.height, 0.1, accuracy: 0.000_001)

        page.setBounds(mediaBox, for: .cropBox)
        page.rotation = 90
        let rotatedResult = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "rotate@example.com",
                    confidence: 0.9,
                    blocks: [
                        OCRTextBlock(
                            text: "rotate@example.com",
                            confidence: 0.9,
                            normalizedX: 0.1,
                            normalizedY: 0.2,
                            normalizedWidth: 0.3,
                            normalizedHeight: 0.1
                        )
                    ]
                )
            ]
        )

        let rotated = try XCTUnwrap(
            PrivacyScanService.spatialObservations(
                from: rotatedResult,
                document: document
            ).first?.normalizedBounds
        )
        XCTAssertEqual(rotated.x, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(rotated.y, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(rotated.width, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(rotated.height, 0.3, accuracy: 0.000_001)
    }

    func testScanRejectsStaleBoundTextIndex() throws {
        let document = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let currentRevisionID = UUID()
        let staleIndex = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "stale@example.com"
                )
            ],
            indexedAt: Date(),
            contentRevisionID: UUID()
        )

        let staleResult = try PrivacyScanService().scan(
            document: document,
            textIndex: staleIndex,
            documentRevisionID: currentRevisionID,
            performsOCRFallback: false
        )
        XCTAssertTrue(staleResult.findings.isEmpty)
        XCTAssertFalse(
            staleResult.warnings.contains(.ocrTextHadNoSpatialData)
        )

        let currentResult = try PrivacyScanService().scan(
            document: document,
            textIndex: staleIndex.bound(to: currentRevisionID),
            documentRevisionID: currentRevisionID,
            performsOCRFallback: false
        )
        XCTAssertEqual(currentResult.findings.count, 1)
        XCTAssertFalse(
            try XCTUnwrap(currentResult.findings.first).isLocatable
        )
        XCTAssertTrue(
            currentResult.warnings.contains(.ocrTextHadNoSpatialData)
        )
    }

    func testTruncatedIndexWarningAppearsOnlyWhenIndexIsUsed() throws {
        let revisionID = UUID()
        let truncatedIndex = DocumentTextIndex(
            source: .vision,
            pages: [
                IndexedPageText(
                    pageIndex: 0,
                    text: "indexed@example.com"
                )
            ],
            indexedAt: Date(),
            isTruncated: true,
            contentRevisionID: revisionID
        )
        let blank = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let indexedResult = try PrivacyScanService().scan(
            document: blank,
            textIndex: truncatedIndex,
            documentRevisionID: revisionID,
            performsOCRFallback: false
        )
        XCTAssertTrue(
            indexedResult.warnings.contains(.textIndexWasTruncated)
        )

        let native = try XCTUnwrap(
            PDFDocument(data: makePDF(text: "native@example.com"))
        )
        let nativeResult = try PrivacyScanService().scan(
            document: native,
            textIndex: truncatedIndex,
            documentRevisionID: revisionID,
            performsOCRFallback: false
        )
        XCTAssertFalse(
            nativeResult.warnings.contains(.textIndexWasTruncated)
        )
    }

    func testScanRejectsDocumentsBeyondProcessingPageLimit() throws {
        let source = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let sourcePage = try XCTUnwrap(source.page(at: 0))
        let oversized = PDFDocument()
        for index in 0...PrivacyScanService.maximumPageCount {
            let page = try XCTUnwrap(sourcePage.copy() as? PDFPage)
            oversized.insert(page, at: index)
        }

        XCTAssertThrowsError(
            try PrivacyScanService().scan(
                document: oversized,
                performsOCRFallback: false
            )
        ) {
            XCTAssertEqual(
                $0.localizedDescription,
                "Scan PDFs with up to 1,000 pages."
            )
        }
    }

    func testSpatialOCRFindingsAreMergedWithNativeText() throws {
        let data = makePDF(
            text: "Contact alex@example.com before sharing."
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.2,
                y: 0.4,
                width: 0.35,
                height: 0.05
            )
        )

        let result = try PrivacyScanService().scan(
            document: document,
            spatialOCR: [
                PrivacySpatialTextObservation(
                    pageIndex: 0,
                    text: "Card 4111 1111 1111 1111",
                    normalizedBounds: bounds,
                    confidence: 0.96
                )
            ],
            performsOCRFallback: false
        )

        XCTAssertTrue(
            result.findings.contains {
                $0.category == .email
                    && $0.source == .nativeText
            }
        )
        XCTAssertTrue(
            result.findings.contains {
                $0.category == .paymentCard
                    && $0.source == .opticalCharacterRecognition
                    && $0.normalizedBounds == [bounds]
            }
        )
    }

    func testOverlappingNativeAndOCRFindingIsNotDuplicated() throws {
        let data = makePDF(
            text: "Contact alex@example.com before sharing."
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let baseline = try PrivacyScanService().scan(
            document: document,
            performsOCRFallback: false
        )
        let native = try XCTUnwrap(
            baseline.findings.first { $0.category == .email }
        )
        let nativeBounds = try XCTUnwrap(native.normalizedBounds.first)
        let padded = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: max(0, nativeBounds.x - 0.02),
                y: max(0, nativeBounds.y - 0.02),
                width: min(
                    1 - max(0, nativeBounds.x - 0.02),
                    nativeBounds.width + 0.04
                ),
                height: min(
                    1 - max(0, nativeBounds.y - 0.02),
                    nativeBounds.height + 0.04
                )
            )
        )

        let result = try PrivacyScanService().scan(
            document: document,
            spatialOCR: [
                PrivacySpatialTextObservation(
                    pageIndex: 0,
                    text: "alex@example.com",
                    normalizedBounds: padded,
                    confidence: 0.98
                )
            ],
            performsOCRFallback: false
        )
        let emails = result.findings.filter {
            $0.category == .email
        }

        XCTAssertEqual(emails.count, 1)
        XCTAssertEqual(emails.first?.source, .nativeText)
        XCTAssertEqual(emails.first?.normalizedBounds, native.normalizedBounds)
    }

    func testSameValueInSeparateRegionsRemainsTwoFindings() throws {
        let data = makePDF(
            text: "Contact alex@example.com before sharing."
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let baseline = try PrivacyScanService().scan(
            document: document,
            performsOCRFallback: false
        )
        let native = try XCTUnwrap(
            baseline.findings.first { $0.category == .email }
        )
        let nativeBounds = try XCTUnwrap(native.normalizedBounds.first)
        let separated = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: nativeBounds.x < 0.5 ? 0.8 : 0.02,
                y: nativeBounds.y < 0.5 ? 0.85 : 0.02,
                width: 0.1,
                height: 0.04
            )
        )

        let result = try PrivacyScanService().scan(
            document: document,
            spatialOCR: [
                PrivacySpatialTextObservation(
                    pageIndex: 0,
                    text: "alex@example.com",
                    normalizedBounds: separated,
                    confidence: 0.98
                )
            ],
            performsOCRFallback: false
        )

        XCTAssertEqual(
            result.findings.filter { $0.category == .email }.count,
            2
        )
    }

    func testSecureRedactionFlattensAndRemovesSearchableText() throws {
        let data = makePDF(
            text: "Contact alex@example.com before sharing."
        )
        let source = try XCTUnwrap(PDFDocument(data: data))
        let result = try PrivacyScanService().scan(document: source)
        let email = try XCTUnwrap(
            result.findings.first { $0.category == .email }
        )
        let selection = PrivacyRedactionSelection(
            findings: [email],
            appearance: .black
        )
        let files = try makeTemporaryPDFFiles(sourceData: data)
        defer { try? FileManager.default.removeItem(at: files.directory) }

        try PDFOutputService().secureRedact(
            sourceURL: files.source,
            destination: files.output,
            marks: selection.redactionMarks
        )

        let output = try XCTUnwrap(PDFDocument(url: files.output))
        XCTAssertEqual(output.pageCount, 1)
        XCTAssertFalse(
            (output.page(at: 0)?.string ?? "")
                .localizedCaseInsensitiveContains("alex@example.com")
        )
        XCTAssertEqual(selection.findingCount, 1)
        XCTAssertEqual(selection.affectedPageCount, 1)
    }

    func testSecureRedactionRejectsUnlocatedFinding() {
        let finding = PrivacyFinding(
            id: UUID(),
            fingerprint: "unlocated",
            category: .email,
            pageIndex: 0,
            rawValue: "alex@example.com",
            maskedValue: "a***@example.com",
            confidence: .low,
            source: .opticalCharacterRecognition,
            normalizedBounds: [],
            reason: "OCR 文本缺少位置"
        )
        let selection = PrivacyRedactionSelection(
            findings: [finding],
            appearance: .black
        )

        XCTAssertTrue(selection.redactionMarks.isEmpty)
    }

    func testSecureRedactionCapsOversizedPageRasterAndProtectsOutput()
        throws {
        let pageSize = CGSize(width: 9_000, height: 20)
        let data = makePDF(text: "", pageSize: pageSize)
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.1,
                y: 0.1,
                width: 0.2,
                height: 0.5
            )
        )
        let finding = PrivacyFinding(
            id: UUID(),
            fingerprint: "oversized-page",
            category: .email,
            pageIndex: 0,
            rawValue: "alex@example.com",
            maskedValue: "a***@example.com",
            confidence: .high,
            source: .nativeText,
            normalizedBounds: [bounds],
            reason: "Email format"
        )

        let selection = PrivacyRedactionSelection(
            findings: [finding],
            appearance: .black
        )
        let files = try makeTemporaryPDFFiles(sourceData: data)
        defer { try? FileManager.default.removeItem(at: files.directory) }

        try PDFOutputService().secureRedact(
            sourceURL: files.source,
            destination: files.output,
            marks: selection.redactionMarks
        )

        let outputData = try Data(contentsOf: files.output)
        let imageDimensions = try pdfImageDimensions(in: outputData)
        XCTAssertFalse(imageDimensions.isEmpty)
        XCTAssertLessThanOrEqual(
            imageDimensions.map { max($0.width, $0.height) }.max() ?? 0,
            2_400
        )

        var outputURL = files.output
        outputURL.removeCachedResourceValue(
            forKey: .isExcludedFromBackupKey
        )
        let values = try outputURL.resourceValues(
            forKeys: [
                .isExcludedFromBackupKey,
                .isRegularFileKey
            ]
        )
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testRedactionSelectionPreservesWhiteAppearance() throws {
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.4
            )
        )
        let finding = PrivacyFinding(
            id: UUID(),
            fingerprint: "white-redaction",
            category: .email,
            pageIndex: 2,
            rawValue: "alex@example.com",
            maskedValue: "a***@example.com",
            confidence: .high,
            source: .nativeText,
            normalizedBounds: [bounds],
            reason: "Email format"
        )

        let mark = try XCTUnwrap(
            PrivacyRedactionSelection(
                findings: [finding],
                appearance: .white
            ).redactionMarks.first
        )

        XCTAssertEqual(mark.pageIndex, 2)
        XCTAssertEqual(mark.normalizedX, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(mark.normalizedY, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(mark.appearance, .white)
    }

    @MainActor
    func testReviewSelectionSupportsItemCategoryAndAll() async throws {
        let data = makePDF(
            text: """
            Email alex@example.com
            Backup qa@example.com
            Card 4111 1111 1111 1111
            Server 192.168.10.24
            """
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let model = PrivacyScanReviewModel()

        await model.scan(document: document)

        XCTAssertEqual(model.phase, .review)
        XCTAssertGreaterThanOrEqual(
            model.findings(in: .email).count,
            2
        )
        XCTAssertEqual(model.selectionState(for: .email), .all)
        XCTAssertEqual(model.selectionState(for: .ipAddress), .none)
        XCTAssertEqual(
            model.selectedCount(in: .email),
            model.locatableCount(in: .email)
        )
        XCTAssertFalse(model.isAllLocatableSelected)
        XCTAssertEqual(
            model.expandedCategories,
            [.email, .paymentCard]
        )
        let initiallySelectedRegions = model.selectedRegionCount
        XCTAssertGreaterThan(initiallySelectedRegions, 0)
        XCTAssertGreaterThanOrEqual(
            model.locatableRegionCount,
            initiallySelectedRegions
        )
        XCTAssertEqual(model.selectedPageCount, 1)

        model.toggle(category: .email)
        XCTAssertEqual(model.selectionState(for: .email), .none)
        XCTAssertEqual(model.selectedCount(in: .email), 0)
        XCTAssertLessThan(
            model.selectedRegionCount,
            initiallySelectedRegions
        )

        let firstEmail = try XCTUnwrap(
            model.findings(in: .email).first
        )
        model.toggle(firstEmail)
        XCTAssertEqual(model.selectionState(for: .email), .some)

        model.selectAll()
        XCTAssertEqual(model.selection.count, model.locatableCount)
        XCTAssertEqual(model.selectionState(for: .ipAddress), .all)
        XCTAssertTrue(model.isAllLocatableSelected)
        XCTAssertEqual(model.selectedPageCount, 1)
        XCTAssertEqual(
            model.selectedRegionCount,
            model.locatableRegionCount
        )

        model.clearSelection()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.isAllLocatableSelected)
        XCTAssertEqual(model.selectedRegionCount, 0)
        XCTAssertEqual(model.selectedPageCount, 0)
    }

    @MainActor
    func testResetClearsCachedReviewBeforeDocumentRevisionChanges()
        async throws {
        let document = try XCTUnwrap(
            PDFDocument(
                data: makePDF(
                    text: "Contact alex@example.com before sharing."
                )
            )
        )
        let model = PrivacyScanReviewModel()
        await model.scan(document: document)
        model.appearance = .white

        XCTAssertEqual(model.phase, .review)
        XCTAssertFalse(model.findings.isEmpty)
        XCTAssertFalse(model.selection.isEmpty)
        XCTAssertFalse(model.expandedCategories.isEmpty)

        model.reset()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.result)
        XCTAssertNil(model.outcome)
        XCTAssertTrue(model.findings.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.expandedCategories.isEmpty)
        XCTAssertEqual(model.appearance, .black)
        XCTAssertEqual(model.locatableCount, 0)
        XCTAssertEqual(model.locatableRegionCount, 0)
        XCTAssertEqual(model.selectedRegionCount, 0)
        XCTAssertEqual(model.selectedPageCount, 0)
        XCTAssertFalse(model.canRedact)
    }

    @MainActor
    func testCancelledPrivacyScanDoesNotPublishReview() async throws {
        let data = makePDF(text: "Contact alex@example.com before sharing.")
        let files = try makeTemporaryPDFFiles(sourceData: data)
        defer { try? FileManager.default.removeItem(at: files.directory) }

        for usesURL in [false, true] {
            let model = PrivacyScanReviewModel()
            let document = try XCTUnwrap(PDFDocument(data: data))
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                if usesURL {
                    await model.scan(
                        sourceURL: files.source,
                        estimatedPageCount: 1
                    )
                } else {
                    await model.scan(document: document)
                }
            }
            await task.value

            XCTAssertEqual(model.phase, .idle)
            XCTAssertNil(model.result)
            XCTAssertTrue(model.selection.isEmpty)
            XCTAssertEqual(model.locatableCount, 0)
        }
    }

    @MainActor
    func testCancelledPrivacyRescanPreservesExistingReview() async throws {
        let document = try XCTUnwrap(
            PDFDocument(
                data: makePDF(text: "Contact alex@example.com before sharing.")
            )
        )
        let model = PrivacyScanReviewModel()
        await model.scan(document: document)
        XCTAssertEqual(model.phase, .review)
        XCTAssertFalse(model.findings.isEmpty)
        model.clearSelection()
        model.appearance = .white
        let originalIDs = model.findings.map(\.id)

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.scan(document: document)
        }
        await task.value

        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.findings.map(\.id), originalIDs)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.appearance, .white)
    }

    @MainActor
    func testPrivacyScanCancellationAfterStartingReturnsToIdle()
        async throws {
        let document = try XCTUnwrap(
            PDFDocument(
                data: makePDF(text: "Contact alex@example.com before sharing.")
            )
        )
        let model = PrivacyScanReviewModel()
        var scanTask: Task<Void, Never>?
        let subscription = model.$phase.sink { phase in
            if case .scanning = phase {
                scanTask?.cancel()
            }
        }
        defer { subscription.cancel() }
        scanTask = Task { @MainActor in
            await model.scan(document: document)
        }
        await scanTask?.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.result)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testLargeScanProgressReportsAtMostOncePerPercent() {
        var lastReportedPercentage = -1
        var reportedPages: [Int] = []

        for completedPages in 1...1_000 {
            if PrivacyScanService.shouldReportProgress(
                completedPages: completedPages,
                totalPages: 1_000,
                lastReportedPercentage: &lastReportedPercentage
            ) {
                reportedPages.append(completedPages)
            }
        }

        XCTAssertEqual(reportedPages.count, 101)
        XCTAssertEqual(reportedPages.first, 1)
        XCTAssertEqual(reportedPages.last, 1_000)
        XCTAssertEqual(lastReportedPercentage, 100)
    }

    func testProgressPercentageClampsInvalidInputs() {
        XCTAssertEqual(
            PrivacyScanService.progressPercentage(
                completedPages: -5,
                totalPages: 100
            ),
            0
        )
        XCTAssertEqual(
            PrivacyScanService.progressPercentage(
                completedPages: 150,
                totalPages: 100
            ),
            100
        )
        XCTAssertEqual(
            PrivacyScanService.progressPercentage(
                completedPages: 0,
                totalPages: 0
            ),
            0
        )
    }

    @MainActor
    func testReviewSelectionTracksAffectedPagesIncrementally()
        async throws {
        let source = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let document = PDFDocument()
        for pageIndex in 0..<2 {
            document.insert(
                try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage),
                at: pageIndex
            )
        }
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.1,
                y: 0.1,
                width: 0.3,
                height: 0.05
            )
        )
        let model = PrivacyScanReviewModel()

        await model.scan(
            document: document,
            spatialOCR: [
                PrivacySpatialTextObservation(
                    pageIndex: 0,
                    text: "first@example.com",
                    normalizedBounds: bounds,
                    confidence: 0.95
                ),
                PrivacySpatialTextObservation(
                    pageIndex: 1,
                    text: "second@example.com",
                    normalizedBounds: bounds,
                    confidence: 0.95
                )
            ]
        )

        XCTAssertEqual(model.selection.count, 2)
        XCTAssertEqual(model.selectedRegionCount, 2)
        XCTAssertEqual(model.selectedPageCount, 2)

        let first = try XCTUnwrap(model.findings.first)
        model.toggle(first)
        XCTAssertEqual(model.selection.count, 1)
        XCTAssertEqual(model.selectedRegionCount, 1)
        XCTAssertEqual(model.selectedPageCount, 1)

        model.toggle(first)
        XCTAssertEqual(model.selection.count, 2)
        XCTAssertEqual(model.selectedRegionCount, 2)
        XCTAssertEqual(model.selectedPageCount, 2)
    }

    @MainActor
    func testReviewModelScansManagedURL() async throws {
        let data = makePDF(
            text: "Contact alex@example.com before sharing."
        )
        let files = try makeTemporaryPDFFiles(sourceData: data)
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let revisionID = UUID()
        let model = PrivacyScanReviewModel()

        await model.scan(
            sourceURL: files.source,
            estimatedPageCount: 1,
            documentRevisionID: revisionID
        )

        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.result?.documentRevisionID, revisionID)
        XCTAssertEqual(model.result?.pageCount, 1)
        XCTAssertTrue(
            model.findings.contains {
                $0.category == .email && $0.isLocatable
            }
        )
    }

    @MainActor
    func testReviewModelUsesStoredOCRCoordinates() async throws {
        let document = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let ocrResult = OCRResult(
            pages: [
                OCRPageResult(
                    pageIndex: 0,
                    text: "alex@example.com",
                    confidence: 0.92,
                    blocks: [
                        OCRTextBlock(
                            text: "alex@example.com",
                            confidence: 0.92,
                            normalizedX: 0.15,
                            normalizedY: 0.65,
                            normalizedWidth: 0.3,
                            normalizedHeight: 0.06
                        )
                    ]
                )
            ]
        )
        let model = PrivacyScanReviewModel()

        await model.scan(
            document: document,
            ocrResult: ocrResult
        )

        let finding = try XCTUnwrap(
            model.findings.first { $0.category == .email }
        )
        XCTAssertEqual(finding.source, .opticalCharacterRecognition)
        XCTAssertTrue(finding.isLocatable)
        XCTAssertTrue(model.selection.contains(finding.id))
    }

    @MainActor
    func testLargeReviewExpandsOnlyFirstPopulatedCategory() async throws {
        let document = try XCTUnwrap(
            PDFDocument(data: makePDF(text: ""))
        )
        let bounds = try XCTUnwrap(
            PrivacyNormalizedRect(
                x: 0.1,
                y: 0.1,
                width: 0.3,
                height: 0.05
            )
        )
        let observations = (0..<41).map { index in
            PrivacySpatialTextObservation(
                pageIndex: 0,
                text: "person\(index)@example.com",
                normalizedBounds: bounds,
                confidence: 0.95
            )
        }
        let model = PrivacyScanReviewModel()

        await model.scan(
            document: document,
            spatialOCR: observations
        )

        XCTAssertEqual(model.findings.count, 41)
        XCTAssertEqual(model.locatableCount, 41)
        XCTAssertEqual(model.expandedCategories, [.email])
    }

    @MainActor
    func testCancelledRedactionCannotPublishLateOutcome() async throws {
        let document = try XCTUnwrap(
            PDFDocument(
                data: makePDF(
                    text: "Contact alex@example.com before sharing."
                )
            )
        )
        let model = PrivacyScanReviewModel()
        await model.scan(document: document)
        XCTAssertTrue(model.canRedact)

        let task = Task { @MainActor in
            await model.redact { _ in
                try? await Task.sleep(for: .seconds(30))
                return PrivacyRedactionOutcome(
                    outputURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("late-redaction.pdf"),
                    verifiedFindingCount: 1,
                    affectedPageCount: 1
                )
            }
        }
        for _ in 0..<100 where model.phase != .redacting {
            await Task.yield()
        }
        XCTAssertEqual(model.phase, .redacting)

        task.cancel()
        await task.value

        XCTAssertEqual(model.phase, .review)
        XCTAssertNil(model.outcome)
    }

    @MainActor
    func testInvalidatingRedactionRestoresReviewState() async throws {
        let document = try XCTUnwrap(
            PDFDocument(
                data: makePDF(
                    text: "Contact alex@example.com before sharing."
                )
            )
        )
        let model = PrivacyScanReviewModel()
        await model.scan(document: document)
        XCTAssertTrue(model.canRedact)

        let task = Task { @MainActor in
            await model.redact { _ in
                try? await Task.sleep(for: .seconds(30))
                return PrivacyRedactionOutcome(
                    outputURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("invalidated-redaction.pdf"),
                    verifiedFindingCount: 1,
                    affectedPageCount: 1
                )
            }
        }
        for _ in 0..<100 where model.phase != .redacting {
            await Task.yield()
        }
        XCTAssertEqual(model.phase, .redacting)

        model.cancelScan()
        task.cancel()
        await task.value

        XCTAssertEqual(model.phase, .review)
        XCTAssertNil(model.outcome)
        XCTAssertTrue(model.canRedact)
    }

    func testPrivacyCopyFollowsSelectedLanguage() {
        UserDefaults.standard.set(
            AppLanguage.simplifiedChinese.rawValue,
            forKey: AppLanguage.defaultsKey
        )
        XCTAssertEqual(PrivacyCategory.email.title, "电子邮箱")
        XCTAssertEqual("Privacy Scan".localizedUI, "智能隐私扫描")
        XCTAssertEqual("All Selected".localizedUI, "已全部选择")
        XCTAssertEqual("Low confidence".localizedUI, "低置信度")
        XCTAssertEqual(
            PrivacyScanService().candidates(
                in: "Passport No: A12345678"
            ).first { $0.category == .passportNumber }?.reason,
            "护照标签附近的编号"
        )

        UserDefaults.standard.set(
            AppLanguage.english.rawValue,
            forKey: AppLanguage.defaultsKey
        )
        XCTAssertEqual(PrivacyCategory.email.title, "Email address")
        XCTAssertEqual("Privacy Scan".localizedUI, "Privacy Scan")
        XCTAssertEqual(
            PrivacyScanService().candidates(
                in: "Passport No: A12345678"
            ).first { $0.category == .passportNumber }?.reason,
            "Number near a passport label"
        )
    }

    private func makePDF(
        text: String,
        pageSize: CGSize = CGSize(width: 612, height: 792)
    ) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            text.draw(
                at: CGPoint(x: 72, y: 96),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.black
                ]
            )
        }
    }

    private func makeTemporaryPDFFiles(
        sourceData: Data
    ) throws -> (directory: URL, source: URL, output: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrivacyScanServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let source = directory.appendingPathComponent("source.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        try sourceData.write(to: source, options: .atomic)
        return (directory, source, output)
    }

    private func pdfImageDimensions(
        in data: Data
    ) throws -> [(width: Int, height: Int)] {
        let source = String(decoding: data, as: UTF8.self)
        let expression = try NSRegularExpression(
            pattern: #"/Width\s+([0-9]+)\s+/Height\s+([0-9]+)"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap {
            guard $0.numberOfRanges == 3,
                  let widthRange = Range($0.range(at: 1), in: source),
                  let heightRange = Range($0.range(at: 2), in: source),
                  let width = Int(source[widthRange]),
                  let height = Int(source[heightRange])
            else {
                return nil
            }
            return (width, height)
        }
    }
}
