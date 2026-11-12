import Foundation

// Host-only metamorphic checks: the same production model runs without an iOS runtime.
@main
struct CheckHandoffDomain {
    static func main() throws {
        var checks = 0
        for index in 0..<1_000 {
            let doc = HandoffDocumentSnapshot(id: UUID(), revisionID: UUID(), name: "Fixture", fingerprint: "file-\(index)",
                                             byteCount: Int64(index + 1), isLocked: false, isImageBased: true,
                                             hasCurrentReceipt: true, receiptHasWarnings: false)
            var rule = HandoffRule()
            rule.name = "Fixture rule"
            rule.requiresPrivacyReview = index.isMultiple(of: 2)
            rule.requiresReceipt = index.isMultiple(of: 3)
            rule.outputFormat = index.isMultiple(of: 5) ? .imageBased : .keepPDF
            var item = HandoffRequirement(title: "Document", recordID: doc.id)
            item.privacyReviewedRevisionID = doc.revisionID
            item.confirm(document: doc, rule: rule)
            var packet = HandoffPacket(name: "Fixture packet", ruleID: rule.id, requirements: [item])
            func assess(_ packet: HandoffPacket, _ rule: HandoffRule, _ doc: HandoffDocumentSnapshot) -> [HandoffRequirementAssessment] {
                HandoffEvaluator.assess(packet: packet, rule: rule, documents: [doc.id: doc])
            }
            precondition(HandoffEvaluator.isReady(packet: packet, assessments: assess(packet, rule, doc)))
            checks += 1
            let changed = HandoffDocumentSnapshot(id: doc.id, revisionID: UUID(), name: doc.name, fingerprint: doc.fingerprint,
                                                 byteCount: doc.byteCount, isLocked: false, isImageBased: true,
                                                 hasCurrentReceipt: true, receiptHasWarnings: false)
            precondition(!HandoffEvaluator.isReady(packet: packet, assessments: assess(packet, rule, changed)), "Changed revisions must invalidate confirmation")
            checks += 1
            var changedRule = rule; changedRule.version = UUID()
            precondition(!HandoffEvaluator.isReady(packet: packet, assessments: assess(packet, changedRule, doc)), "Changed rules must invalidate confirmation")
            checks += 1
            var second = item; second.id = UUID(); second.title = "Another required material"
            packet.requirements.append(second)
            precondition(assess(packet, rule, doc).allSatisfy { $0.issues.contains(.duplicateFile) }, "Adding the same file cannot satisfy a second requirement")
            checks += 1
            var workspace = HandoffWorkspace(); workspace.rules = [rule]; workspace.packets = [packet]
            let restored = try JSONDecoder().decode(HandoffWorkspace.self, from: JSONEncoder().encode(workspace))
            precondition(restored == workspace)
            checks += 1
        }
        print("Passed \(checks) host-only handoff invariants across 1,000 document/rule combinations.")
    }
}
