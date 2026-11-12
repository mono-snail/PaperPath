import Foundation

enum HandoffOutputFormat: String, Codable, CaseIterable, Sendable {
    case keepPDF
    case imageBased

    var title: String {
        switch self {
        case .keepPDF: return "Keep selected PDF"
        case .imageBased: return "Image-based copy"
        }
    }
}

struct HandoffRule: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var version = UUID()
    var name = ""
    var outputFormat: HandoffOutputFormat = .keepPDF
    var requiresPrivacyReview = true
    var requiresReceipt = false
    var maximumMegabytes: Int? = nil
    var filenamePrefix = ""

    var isValid: Bool {
        HandoffText.isValid(name, limit: 80)
            && filenamePrefix.count <= 40
            && !filenamePrefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (maximumMegabytes.map { (1...250).contains($0) } ?? true)
    }
}

struct HandoffRequirement: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var recordID: UUID?
    var privacyReviewedRevisionID: UUID?
    var confirmedRevisionID: UUID?
    var confirmedRuleVersion: UUID?
    var confirmedAt: Date?

    mutating func assign(_ id: UUID?) {
        recordID = id
        privacyReviewedRevisionID = nil
        clearConfirmation()
    }

    mutating func clearConfirmation() {
        confirmedRevisionID = nil
        confirmedRuleVersion = nil
        confirmedAt = nil
    }

    mutating func confirm(document: HandoffDocumentSnapshot, rule: HandoffRule) {
        confirmedRevisionID = document.revisionID
        confirmedRuleVersion = rule.version
        confirmedAt = Date()
    }

    func hasCurrentConfirmation(document: HandoffDocumentSnapshot, rule: HandoffRule) -> Bool {
        confirmedRevisionID == document.revisionID && confirmedRuleVersion == rule.version && confirmedAt != nil
    }
}

struct HandoffPacket: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var ruleID: UUID
    var requirements: [HandoffRequirement] = []
    // Optional for compatibility with packets saved before key-detail checks.
    var keyDetails: [HandoffKeyDetail]?
    var keyDetailReport: HandoffKeyDetailReport?

    var detailsToCheck: [HandoffKeyDetail] { keyDetails ?? [] }

    var isValid: Bool {
        HandoffText.isValid(name, limit: 100)
            && requirements.count <= 30
            && Set(requirements.map(\.id)).count == requirements.count
            && requirements.allSatisfy { HandoffText.isValid($0.title, limit: 100) }
            && detailsToCheck.count <= 8
            && Set(detailsToCheck.map(\.id)).count == detailsToCheck.count
            && detailsToCheck.allSatisfy(\.isValid)
            && (keyDetailReport?.isStructurallyValid ?? true)
    }
}

struct HandoffWorkspace: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revision = 0
    var rules: [HandoffRule] = []
    var packets: [HandoffPacket] = []

    var isValid: Bool {
        schemaVersion == 1 && revision >= 0 && revision < Int.max
            && rules.count <= 30 && packets.count <= 50
            && Set(rules.map(\.id)).count == rules.count
            && Set(packets.map(\.id)).count == packets.count
            && rules.allSatisfy(\.isValid) && packets.allSatisfy(\.isValid)
    }
}

enum HandoffText {
    static func isValid(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= limit
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func fileComponent(_ value: String) -> String {
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:<>\"|?*"))
        let safe = String(value.unicodeScalars.map { disallowed.contains($0) ? "-" : String($0) }.joined().prefix(60))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var bounded = ""
        for character in safe {
            guard bounded.utf8.count + String(character).utf8.count <= 160 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Document" : bounded
    }
}

struct HandoffDocumentSnapshot: Equatable, Sendable {
    let id: UUID
    let revisionID: UUID
    let name: String
    let fingerprint: String?
    let byteCount: Int64
    let isLocked: Bool
    let isImageBased: Bool
    let hasCurrentReceipt: Bool
    let receiptHasWarnings: Bool
}

enum HandoffIssue: String, Codable, CaseIterable, Sendable {
    case ruleMissing
    case fileMissing
    case duplicateFile
    case locked
    case imageCopyRequired
    case receiptRequired
    case receiptWarnings
    case fileTooLarge
    case privacyReviewRequired
    case confirmationRequired
    case keyDetailsRequired

    var title: String {
        switch self {
        case .ruleMissing: return "Choose a delivery rule"
        case .fileMissing: return "Add the required PDF"
        case .duplicateFile: return "This PDF is used more than once"
        case .locked: return "Unlock and review this PDF first"
        case .imageCopyRequired: return "Create an image-based copy"
        case .receiptRequired: return "A current output receipt is required"
        case .receiptWarnings: return "Review the output receipt warnings"
        case .fileTooLarge: return "This PDF exceeds the rule's size limit"
        case .privacyReviewRequired: return "Confirm privacy review for this version"
        case .confirmationRequired: return "Confirm this file for the packet"
        case .keyDetailsRequired: return "Check the packet's key details before exporting"
        }
    }
}

struct HandoffRequirementAssessment: Sendable {
    let requirementID: UUID
    let issues: [HandoffIssue]
    var isReady: Bool { issues.isEmpty }
    var canConfirm: Bool {
        issues.contains(.confirmationRequired)
            && issues.allSatisfy { $0 == .confirmationRequired || $0 == .keyDetailsRequired }
    }
}

enum HandoffEvaluator {
    static func assess(
        packet: HandoffPacket,
        rule: HandoffRule?,
        documents: [UUID: HandoffDocumentSnapshot]
    ) -> [HandoffRequirementAssessment] {
        let identities = packet.requirements.compactMap { item -> String? in
            guard let id = item.recordID, let doc = documents[id] else { return nil }
            return identity(doc)
        }
        let counts = Dictionary(identities.map { ($0, 1) }, uniquingKeysWith: +)
        return packet.requirements.map { item in
            var issues: [HandoffIssue] = []
            guard let rule, rule.id == packet.ruleID, rule.isValid else {
                return HandoffRequirementAssessment(requirementID: item.id, issues: [.ruleMissing])
            }
            guard let id = item.recordID, let doc = documents[id] else {
                return HandoffRequirementAssessment(requirementID: item.id, issues: [.fileMissing])
            }
            if counts[identity(doc), default: 0] > 1 { issues.append(.duplicateFile) }
            if doc.isLocked { issues.append(.locked) }
            if rule.outputFormat == .imageBased && !doc.isImageBased { issues.append(.imageCopyRequired) }
            if rule.requiresReceipt && !doc.hasCurrentReceipt { issues.append(.receiptRequired) }
            if rule.requiresReceipt && doc.hasCurrentReceipt && doc.receiptHasWarnings { issues.append(.receiptWarnings) }
            if doc.byteCount <= 0 || rule.maximumMegabytes.map({ doc.byteCount > Int64($0) * 1_000_000 }) == true {
                issues.append(.fileTooLarge)
            }
            if rule.requiresPrivacyReview && item.privacyReviewedRevisionID != doc.revisionID {
                issues.append(.privacyReviewRequired)
            }
            if !item.hasCurrentConfirmation(document: doc, rule: rule) {
                issues.append(.confirmationRequired)
            }
            if !packet.detailsToCheck.isEmpty,
               packet.keyDetailReport?.passes(for: packet, documents: documents) != true {
                issues.append(.keyDetailsRequired)
            }
            return HandoffRequirementAssessment(requirementID: item.id, issues: issues)
        }
    }

    static func isReady(packet: HandoffPacket, assessments: [HandoffRequirementAssessment]) -> Bool {
        packet.isValid && !packet.requirements.isEmpty
            && assessments.count == packet.requirements.count
            && Set(assessments.map(\.requirementID)) == Set(packet.requirements.map(\.id))
            && assessments.allSatisfy(\.isReady)
    }

    static func confirmedCount(packet: HandoffPacket, rule: HandoffRule?, documents: [UUID: HandoffDocumentSnapshot]) -> Int {
        guard let rule, rule.id == packet.ruleID else { return 0 }
        return packet.requirements.filter { item in
            guard let id = item.recordID, let document = documents[id] else { return false }
            return item.hasCurrentConfirmation(document: document, rule: rule)
        }.count
    }

    private static func identity(_ doc: HandoffDocumentSnapshot) -> String {
        if let fingerprint = doc.fingerprint, !fingerprint.isEmpty { return "sha256:\(fingerprint.lowercased())" }
        return "record:\(doc.id.uuidString)"
    }
}

struct HandoffManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let requirement: String
        let filename: String
        let byteCount: Int64
        let sha256: String
        let documentRevisionID: UUID
        let privacyReviewed: Bool
        let confirmedAt: Date
        let receiptFilename: String?
    }

    let schemaVersion: Int
    let packetID: UUID
    let packetName: String
    let createdAt: Date
    let rule: HandoffRule
    let files: [File]
    let scope: String
    var keyDetailSummary: HandoffKeyDetailSummary? = nil
}

struct HandoffKeyDetail: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var label = ""
    var expectedText = ""
    var requirementIDs: [UUID] = []

    var isValid: Bool {
        HandoffText.isValid(name, limit: 60)
            && HandoffText.isValid(label, limit: 80)
            && HandoffText.isValid(expectedText, limit: 160)
            && (2...30).contains(requirementIDs.count)
            && Set(requirementIDs).count == requirementIDs.count
    }
}

enum HandoffKeyDetailState: String, Codable, Sendable {
    case matches, differs, ambiguous, missingField, missingFile, unreadable, incomplete

    var title: String {
        switch self {
        case .matches: return "Matches expected text"
        case .differs: return "Does not match"
        case .ambiguous: return "Needs manual review"
        case .missingField: return "Field not found in readable text"
        case .missingFile: return "Material not assigned"
        case .unreadable: return "Readable PDF text is needed"
        case .incomplete: return "Could not check all text"
        }
    }
}

struct HandoffKeyDetailEvidence: Codable, Equatable, Sendable {
    let pageIndex: Int
    let value: String
    let excerpt: String
}

struct HandoffKeyDetailResult: Identifiable, Codable, Equatable, Sendable {
    let detailID: UUID
    let requirementID: UUID
    let recordID: UUID?
    let revisionID: UUID?
    let state: HandoffKeyDetailState
    let evidence: [HandoffKeyDetailEvidence]
    var id: String { "\(detailID.uuidString)-\(requirementID.uuidString)" }
}

struct HandoffKeyDetailBinding: Codable, Equatable, Sendable {
    let requirementID: UUID
    let recordID: UUID?
    let revisionID: UUID?
    let fingerprint: String?

    static func capture(packet: HandoffPacket, documents: [UUID: HandoffDocumentSnapshot]) -> [Self] {
        let ids = Set(packet.detailsToCheck.flatMap(\.requirementIDs)).sorted { $0.uuidString < $1.uuidString }
        return ids.map { requirementID in
            let item = packet.requirements.first { $0.id == requirementID }
            let document = item?.recordID.flatMap { documents[$0] }
            return Self(requirementID: requirementID, recordID: item?.recordID,
                        revisionID: document?.revisionID, fingerprint: document?.fingerprint)
        }
    }
}

struct HandoffKeyDetailReport: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let checkedAt: Date
    let details: [HandoffKeyDetail]
    let bindings: [HandoffKeyDetailBinding]
    let results: [HandoffKeyDetailResult]

    var isStructurallyValid: Bool {
        version == Self.currentVersion && details.count <= 8 && details.allSatisfy(\.isValid)
            && bindings.count <= 240 && Set(bindings.map(\.requirementID)).count == bindings.count
            && results.count <= 240 && Set(results.map(\.id)).count == results.count
            && results.allSatisfy { result in
                result.evidence.count <= 2 && result.evidence.allSatisfy {
                    (0..<100_000).contains($0.pageIndex) && $0.value.count <= 160 && $0.excerpt.count <= 200
                }
            }
    }

    func isCurrent(for packet: HandoffPacket, documents: [UUID: HandoffDocumentSnapshot]) -> Bool {
        isStructurallyValid && details == packet.detailsToCheck
            && bindings == HandoffKeyDetailBinding.capture(packet: packet, documents: documents)
    }

    func passes(for packet: HandoffPacket, documents: [UUID: HandoffDocumentSnapshot]) -> Bool {
        guard !details.isEmpty, isCurrent(for: packet, documents: documents) else { return false }
        for detail in details {
            let rows = results.filter { $0.detailID == detail.id }
            guard rows.count == detail.requirementIDs.count,
                  Set(rows.map(\.requirementID)) == Set(detail.requirementIDs),
                  Set(rows.compactMap(\.recordID)).count >= 2,
                  rows.allSatisfy({ $0.state == .matches && !$0.evidence.isEmpty }) else { return false }
            for row in rows {
                guard let binding = bindings.first(where: { $0.requirementID == row.requirementID }),
                      row.recordID == binding.recordID, row.revisionID == binding.revisionID,
                      row.recordID != nil, row.revisionID != nil else { return false }
            }
        }
        return results.count == details.reduce(0) { $0 + $1.requirementIDs.count }
    }
}

// This is the only key-detail information exported. Expected values and
// extracted evidence stay in the local store, outside the delivery ZIP.
struct HandoffKeyDetailSummary: Codable, Sendable {
    let checkedAt: Date
    let detailCount: Int
    let materialCount: Int
    let allMatched: Bool
}
