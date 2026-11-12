import CryptoKit
import Foundation
import XCTest
@testable import PaperPath

final class HandoffWorkflowTests: XCTestCase {
    private func document(id: UUID = UUID(), revision: UUID = UUID(), fingerprint: String? = "abc", bytes: Int64 = 100,
                          locked: Bool = false, image: Bool = false, receipt: Bool = false, warnings: Bool = false) -> HandoffDocumentSnapshot {
        HandoffDocumentSnapshot(id: id, revisionID: revision, name: "Test PDF", fingerprint: fingerprint, byteCount: bytes,
                                isLocked: locked, isImageBased: image, hasCurrentReceipt: receipt, receiptHasWarnings: warnings)
    }

    private func setup(_ doc: HandoffDocumentSnapshot) -> (HandoffRule, HandoffPacket) {
        var rule = HandoffRule(); rule.name = "Client rule"
        var item = HandoffRequirement(title: "Application", recordID: doc.id)
        item.privacyReviewedRevisionID = doc.revisionID
        item.confirm(document: doc, rule: rule)
        return (rule, HandoffPacket(name: "Client packet", ruleID: rule.id, requirements: [item]))
    }

    private func issues(_ packet: HandoffPacket, _ rule: HandoffRule?, _ docs: [HandoffDocumentSnapshot]) -> [HandoffIssue] {
        HandoffEvaluator.assess(packet: packet, rule: rule, documents: Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })).flatMap(\.issues)
    }

    func testConfirmedCurrentDocumentIsReady() {
        let doc = document(); let (rule, packet) = setup(doc)
        let result = HandoffEvaluator.assess(packet: packet, rule: rule, documents: [doc.id: doc])
        XCTAssertTrue(HandoffEvaluator.isReady(packet: packet, assessments: result))
    }

    func testContentChangeInvalidatesPrivacyAndPacketConfirmation() {
        let old = document(); let (rule, packet) = setup(old)
        let changed = document(id: old.id)
        XCTAssertEqual(issues(packet, rule, [changed]), [.privacyReviewRequired, .confirmationRequired])
    }

    func testRuleChangeRequiresNewConfirmationEvenWhenChecksStillPass() {
        let doc = document(); var (rule, packet) = setup(doc)
        rule.version = UUID()
        XCTAssertEqual(issues(packet, rule, [doc]), [.confirmationRequired])
        packet.requirements[0].confirm(document: doc, rule: rule)
        XCTAssertTrue(issues(packet, rule, [doc]).isEmpty)
    }

    func testMissingRuleAndMissingFileCannotBeConfirmed() {
        let doc = document(); let (rule, packet) = setup(doc)
        XCTAssertEqual(issues(packet, nil, [doc]), [.ruleMissing])
        XCTAssertEqual(issues(packet, rule, []), [.fileMissing])
        var wrongRule = rule; wrongRule.id = UUID()
        XCTAssertEqual(issues(packet, wrongRule, [doc]), [.ruleMissing])
    }

    func testDuplicateRecordAndIdenticalImportedCopyAreBothBlocked() {
        let doc = document(); let (rule, initial) = setup(doc)
        var packet = initial
        packet.requirements.append(HandoffRequirement(title: "Attachment", recordID: doc.id))
        XCTAssertEqual(issues(packet, rule, [doc]).filter { $0 == .duplicateFile }.count, 2)
        let duplicate = document(fingerprint: "ABC")
        packet.requirements[1].assign(duplicate.id)
        XCTAssertEqual(issues(packet, rule, [doc, duplicate]).filter { $0 == .duplicateFile }.count, 2)
    }

    func testDistinctRecordsWithoutFingerprintsAreNotAssumedIdentical() {
        let a = document(fingerprint: nil), b = document(fingerprint: nil)
        let (rule, initial) = setup(a)
        var packet = initial
        packet.requirements.append(HandoffRequirement(title: "Attachment", recordID: b.id))
        XCTAssertFalse(issues(packet, rule, [a,b]).contains(.duplicateFile))
    }

    func testSizeLimitUsesDecimalMegabytesAndIncludesBoundary() {
        let doc = document(bytes: 1_000_000); var (rule, packet) = setup(doc)
        rule.maximumMegabytes = 1
        XCTAssertFalse(issues(packet, rule, [doc]).contains(.fileTooLarge))
        let big = document(id: doc.id, revision: doc.revisionID, bytes: 1_000_001)
        XCTAssertTrue(issues(packet, rule, [big]).contains(.fileTooLarge))
        packet.requirements[0].assign(nil)
        XCTAssertEqual(issues(packet, rule, [big]), [.fileMissing])
    }

    func testImageReceiptAndLockedRequirementsAreIndependent() {
        let doc = document(locked: true); var (rule, packet) = setup(doc)
        rule.outputFormat = .imageBased; rule.requiresReceipt = true
        XCTAssertEqual(issues(packet, rule, [doc]), [.locked, .imageCopyRequired, .receiptRequired])
        let output = document(image: true, receipt: true, warnings: true)
        packet.requirements[0].assign(output.id)
        packet.requirements[0].privacyReviewedRevisionID = output.revisionID
        packet.requirements[0].confirm(document: output, rule: rule)
        XCTAssertEqual(issues(packet, rule, [output]), [.receiptWarnings])
    }

    func testChangingAssignedFileClearsAllAcknowledgements() {
        let doc = document(); var (_, packet) = setup(doc)
        packet.requirements[0].assign(UUID())
        XCTAssertNil(packet.requirements[0].privacyReviewedRevisionID)
        XCTAssertNil(packet.requirements[0].confirmedRevisionID)
        XCTAssertNil(packet.requirements[0].confirmedRuleVersion)
        XCTAssertNil(packet.requirements[0].confirmedAt)
    }

    func testEmptyPacketAndWrongAssessmentIDsNeverPass() {
        let doc = document(); let (rule, packet) = setup(doc)
        XCTAssertFalse(HandoffEvaluator.isReady(packet: HandoffPacket(name: "Empty", ruleID: rule.id), assessments: []))
        XCTAssertFalse(HandoffEvaluator.isReady(packet: packet, assessments: [HandoffRequirementAssessment(requirementID: UUID(), issues: [])]))
    }

    func testInvalidAndOversizedRuleStateIsRejected() throws {
        var rule = HandoffRule(); rule.name = "Valid"; rule.maximumMegabytes = 0
        XCTAssertFalse(rule.isValid)
        rule.maximumMegabytes = 251; XCTAssertFalse(rule.isValid)
        rule.maximumMegabytes = 10; rule.name = "\n"; XCTAssertFalse(rule.isValid)
        rule.name = "Valid"
        var workspace = HandoffWorkspace(); workspace.rules = [rule,rule]
        XCTAssertFalse(workspace.isValid)
        workspace.rules = [rule]; workspace.schemaVersion = 999
        XCTAssertFalse(workspace.isValid)
    }

    func testArchiveFilenamesCannotEscapeOrBecomeHiddenPaths() {
        XCTAssertEqual(HandoffText.fileComponent("../../secret/one"), "-..-secret-one")
        XCTAssertFalse(HandoffText.fileComponent(".\n/\\:").contains("/"))
        XCTAssertFalse(HandoffText.fileComponent("..").hasPrefix("."))
        XCTAssertLessThanOrEqual(HandoffText.fileComponent(String(repeating: "长", count: 300)).count, 60)
        XCTAssertLessThanOrEqual(HandoffText.fileComponent(String(repeating: "👨‍👩‍👧‍👦", count: 60)).utf8.count, 160)
    }

    func testWorkspaceSurvivesReloadAndRejectsStaleWindowSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffStorage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        var workspace = try await store.loadHandoffWorkspace()
        let stale = workspace
        let (rule, packet) = setup(document())
        workspace.rules = [rule]; workspace.packets = [packet]
        let saved = try await store.saveHandoffWorkspace(workspace)
        XCTAssertEqual(saved.revision, 1)
        let reopened = try await DocumentStore(rootURL: root).loadHandoffWorkspace()
        XCTAssertEqual(reopened, saved)
        do { _ = try await store.saveHandoffWorkspace(stale); XCTFail("Stale save must fail") } catch { }
        let preserved = try await store.loadHandoffWorkspace()
        XCTAssertEqual(preserved, saved)
    }

    func testCorruptWorkspaceIsPreservedAndNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffCorrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        _ = try await store.loadHandoffWorkspace()
        let url = root.appendingPathComponent("handoff-workspace.json")
        let corrupt = Data("{broken workspace".utf8)
        try corrupt.write(to: url)
        do { _ = try await store.loadHandoffWorkspace(); XCTFail("Corrupt data must not be treated as empty") } catch { }
        do { _ = try await store.saveHandoffWorkspace(HandoffWorkspace()); XCTFail("Must preserve corrupt data") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testEraseAllLocalDataAlsoRemovesRulesAndPackets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffErase-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(rootURL: root)
        var workspace = HandoffWorkspace(); let (rule, packet) = setup(document())
        workspace.rules = [rule]; workspace.packets = [packet]
        _ = try await store.saveHandoffWorkspace(workspace)
        try await store.eraseAllData()
        let empty = try await store.loadHandoffWorkspace()
        XCTAssertEqual(empty, HandoffWorkspace())
    }

    @MainActor
    func testExportedArchiveManifestMatchesPDFBytesAndPreservesSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffArchiveTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 2)
        let originalBytes = try Data(contentsOf: input)
        let record = try await DocumentStore(rootURL: root.appendingPathComponent("Store")).importPDF(from: input)
        let doc = record.handoffSnapshot
        var (rule, packet) = setup(doc)
        rule.filenamePrefix = "Client"
        packet.requirements[0].confirm(document: doc, rule: rule)
        let archive = try HandoffArchiveService().create(packet: packet, rule: rule, sources: [doc.id: HandoffArchiveSource(document: doc, url: input, receipt: nil)])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let entries = try readStoredZIP(archive)
        XCTAssertTrue(String(decoding: try XCTUnwrap(entries["PaperPath-checklist.txt"]), as: UTF8.self).contains("Application"))
        let manifestData = try XCTUnwrap(entries["PaperPath-packet-manifest.json"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(HandoffManifest.self, from: manifestData)
        XCTAssertEqual(manifest.files.count, 1)
        let file = try XCTUnwrap(manifest.files.first)
        let pdf = try XCTUnwrap(entries[file.filename])
        XCTAssertEqual(file.filename, "01-Client-Application.pdf")
        XCTAssertEqual(pdf, originalBytes)
        XCTAssertEqual(file.byteCount, Int64(pdf.count))
        XCTAssertEqual(file.sha256, SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(manifest.rule.version, rule.version)
        XCTAssertTrue(file.privacyReviewed)
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        let attachment = XCTAttachment(contentsOfFile: archive)
        attachment.name = "PaperPath-handoff-verified-artifact.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testExportRejectsTamperedPreparedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffTamper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 1)
        let record = try await DocumentStore(rootURL: root.appendingPathComponent("Store")).importPDF(from: input)
        let (rule, packet) = setup(record.handoffSnapshot)
        var bytes = try Data(contentsOf: input); bytes[bytes.count - 8] ^= 1; try bytes.write(to: input)
        XCTAssertThrowsError(try HandoffArchiveService().create(packet: packet, rule: rule, sources: [record.id: HandoffArchiveSource(document: record.handoffSnapshot, url: input, receipt: nil)]))
    }

    @MainActor
    func testImageRuleExportsActualCheckedOutputAndMatchingReceipt() async throws {
        let restorePreferences = disableMetadataSyncForFixture()
        defer { restorePreferences() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffImageOutput-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 1)
        let originalBytes = try Data(contentsOf: input)
        let model = PaperPathModel(store: DocumentStore(rootURL: root.appendingPathComponent("Store")),
                                  signatureStore: SignatureStore(rootURL: root.appendingPathComponent("Signatures")))
        let imported = await model.importPDF(from: input)
        let source = try XCTUnwrap(imported)
        let created = await model.createSafeShareCopy(recordID: source.id, expectedContentRevisionID: source.contentRevisionID)
        let output = try XCTUnwrap(created)
        XCTAssertTrue(output.hasCurrentDeliveryReceipt)
        XCTAssertTrue(output.handoffSnapshot.isImageBased)
        var (rule, packet) = setup(output.handoffSnapshot)
        rule.outputFormat = .imageBased; rule.requiresReceipt = true
        var workspace = HandoffWorkspace(); workspace.rules = [rule]; workspace.packets = [packet]
        try await model.saveHandoffWorkspace(workspace)
        let archive = try await model.makeHandoffPacketExport(packetID: packet.id)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let entries = try readStoredZIP(archive)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(HandoffManifest.self, from: XCTUnwrap(entries["PaperPath-packet-manifest.json"]))
        let file = try XCTUnwrap(manifest.files.first)
        let receiptData = try XCTUnwrap(entries[try XCTUnwrap(file.receiptFilename)])
        let receipt = try decoder.decode(PDFDeliveryReceipt.self, from: receiptData)
        let pdf = try XCTUnwrap(entries[file.filename])
        XCTAssertEqual(receipt.sha256, SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(receipt.sha256, file.sha256)
        XCTAssertEqual(receipt.outputRevisionID, file.documentRevisionID)
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        packet.requirements[0].confirmedRuleVersion = UUID()
        workspace = model.handoffWorkspace; workspace.packets = [packet]
        try await model.saveHandoffWorkspace(workspace)
        do { _ = try await model.makeHandoffPacketExport(packetID: packet.id); XCTFail("Stale confirmation must prevent export") } catch { }
        let attachment = XCTAttachment(contentsOfFile: archive)
        attachment.name = "PaperPath-handoff-image-output-with-receipt.zip"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testSampleDocumentsNeverReuseExistingUserPDF() async throws {
        let restorePreferences = disableMetadataSyncForFixture()
        defer { restorePreferences() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffSample-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("private.pdf")
        try PDFTestFixtureFactory.makeTextPDF(at: input, pageCount: 1)
        let model = PaperPathModel(store: DocumentStore(rootURL: root.appendingPathComponent("Store")),
                                  signatureStore: SignatureStore(rootURL: root.appendingPathComponent("Signatures")))
        let existing = await model.importPDF(from: input)
        let userDocument = try XCTUnwrap(existing)
        let samples = try await model.createHandoffSampleDocuments()
        XCTAssertNotEqual(samples.main, userDocument.id)
        XCTAssertNotEqual(samples.supporting, userDocument.id)
        let main = try XCTUnwrap(model.record(id: samples.main))
        let supporting = try XCTUnwrap(model.record(id: samples.supporting))
        XCTAssertNotEqual(main.contentFingerprint, supporting.contentFingerprint)
        XCTAssertEqual(model.documents.count, 4)
    }

    private func disableMetadataSyncForFixture() -> () -> Void {
        let key = AppPreferences.metadataSyncEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        return {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func readStoredZIP(_ url: URL) throws -> [String: Data] {
        let bytes = [UInt8](try Data(contentsOf: url))
        func number(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        var offset = 0; var entries: [String: Data] = [:]
        while offset + 30 <= bytes.count, number(offset, 4) == 0x04034b50 {
            XCTAssertEqual(number(offset + 8, 2), 0, "Independent oracle expects stored ZIP entries")
            let size = number(offset + 18, 4), nameSize = number(offset + 26, 2), extra = number(offset + 28, 2)
            let start = offset + 30 + nameSize + extra
            guard start + size <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameSize)], as: UTF8.self)
            entries[name] = Data(bytes[start..<(start + size)])
            offset = start + size
        }
        return entries
    }
}
