import CryptoKit
import Foundation

extension DocumentRecord {
    var handoffSnapshot: HandoffDocumentSnapshot {
        HandoffDocumentSnapshot(
            id: id, revisionID: contentRevisionID, name: displayName,
            fingerprint: contentFingerprint, byteCount: profile.byteCount,
            isLocked: profile.isLocked,
            isImageBased: hasCurrentDeliveryReceipt
                && (deliveryReceipt.map { [.safeShare, .flattened, .redacted].contains($0.operation) } ?? false),
            hasCurrentReceipt: hasCurrentDeliveryReceipt,
            receiptHasWarnings: deliveryReceipt?.hasWarnings ?? false
        )
    }
}

struct HandoffArchiveSource: Sendable {
    let document: HandoffDocumentSnapshot
    let url: URL
    let receipt: PDFDeliveryReceipt?
}

struct HandoffArchiveService: Sendable {
    func create(
        packet: HandoffPacket,
        rule: HandoffRule,
        sources: [UUID: HandoffArchiveSource]
    ) throws -> URL {
        let snapshots = sources.mapValues(\.document)
        guard HandoffEvaluator.isReady(
            packet: packet,
            assessments: HandoffEvaluator.assess(packet: packet, rule: rule, documents: snapshots)
        ) else {
            throw PaperPathError.insufficientSelection("Complete the packet checks before exporting.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperPath-FilesExport-\(UUID().uuidString)", isDirectory: true)
        try LocalFileSecurity.prepareProtectedDirectory(at: directory)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        var archiveSources: [OfficeBatchArchiveSource] = []
        var files: [HandoffManifest.File] = []
        var seenFingerprints = Set<String>()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for (index, item) in packet.requirements.enumerated() {
            try Task.checkCancellation()
            guard let id = item.recordID, let source = sources[id], let confirmedAt = item.confirmedAt else {
                throw PaperPathError.unreadablePDF
            }
            let values = try source.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == source.document.byteCount else {
                throw PaperPathError.outputVerificationFailed("a packet file changed during export")
            }
            let fingerprint = try hash(source.url)
            guard source.document.fingerprint.map({ $0.lowercased() == fingerprint }) ?? true,
                  seenFingerprints.insert(fingerprint).inserted else {
                throw PaperPathError.outputVerificationFailed("a packet contains changed or duplicate PDF files")
            }
            let prefix = rule.filenamePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let stem = HandoffText.fileComponent((prefix.isEmpty ? "" : "\(prefix)-") + item.title)
            let filename = String(format: "%02d-", index + 1) + stem + ".pdf"
            // The archive reads private export copies, never the user's imported source.
            archiveSources.append(OfficeBatchArchiveSource(sourceURL: source.url, archiveName: filename))
            var receiptFilename: String?
            if let receipt = source.receipt, source.document.hasCurrentReceipt {
                guard receipt.sha256.lowercased() == fingerprint,
                      receipt.outputRevisionID == source.document.revisionID else {
                    throw PaperPathError.outputVerificationFailed("a packet receipt no longer matches its PDF")
                }
                let name = String(format: "%02d-", index + 1) + stem + "-receipt.json"
                let receiptURL = directory.appendingPathComponent(name)
                try encoder.encode(receipt).write(to: receiptURL, options: [.atomic, .completeFileProtection])
                archiveSources.append(OfficeBatchArchiveSource(sourceURL: receiptURL, archiveName: name))
                receiptFilename = name
            } else if rule.requiresReceipt {
                throw PaperPathError.outputVerificationFailed("a required packet receipt is missing")
            }
            files.append(HandoffManifest.File(
                requirement: item.title, filename: filename, byteCount: source.document.byteCount,
                sha256: fingerprint, documentRevisionID: source.document.revisionID,
                privacyReviewed: item.privacyReviewedRevisionID == source.document.revisionID,
                confirmedAt: confirmedAt, receiptFilename: receiptFilename
            ))
        }
        let manifest = HandoffManifest(
            schemaVersion: 1, packetID: packet.id, packetName: packet.name, createdAt: Date(),
            rule: rule, files: files,
            scope: "User-defined material checklist and file checks. Privacy review is a user acknowledgement. Key-detail checks compare selected readable text, not business meaning or accuracy. Check-condition records and extracted excerpts are not added to the exported checklist; selected PDF content is retained. This manifest is not an identity, content accuracy, legal compliance, or digital-signature certificate.",
            keyDetailSummary: packet.detailsToCheck.isEmpty ? nil : packet.keyDetailReport.map {
                HandoffKeyDetailSummary(checkedAt: $0.checkedAt, detailCount: $0.details.count,
                    materialCount: Set($0.results.compactMap(\.recordID)).count,
                    allMatched: $0.passes(for: packet, documents: snapshots))
            }
        )
        let manifestURL = directory.appendingPathComponent("PaperPath-packet-manifest.json")
        try encoder.encode(manifest).write(to: manifestURL, options: [.atomic, .completeFileProtection])
        archiveSources.append(OfficeBatchArchiveSource(sourceURL: manifestURL, archiveName: manifestURL.lastPathComponent))
        let readable = [
            "PaperPath · Material checklist",
            packet.name,
            "Rule: \(rule.name)",
            "Rule version: \(rule.version.uuidString)",
            manifest.keyDetailSummary.map { "Key-detail checks: \($0.detailCount) across \($0.materialCount) materials. Check conditions and excerpts are not added to this checklist." } ?? "",
            "",
            files.enumerated().map { index, file in
                "\(index + 1). \(file.requirement)\n   \(file.filename)\n   \(file.byteCount) bytes\n   SHA-256: \(file.sha256)"
            }.joined(separator: "\n\n"),
            "",
            "Completeness follows the user's checklist. File checks do not certify document accuracy, identity or legal compliance. See the JSON manifest and any output receipts for details."
        ].joined(separator: "\n")
        let readableURL = directory.appendingPathComponent("PaperPath-checklist.txt")
        try Data(readable.utf8).write(to: readableURL, options: [.atomic, .completeFileProtection])
        archiveSources.append(OfficeBatchArchiveSource(sourceURL: readableURL, archiveName: readableURL.lastPathComponent))
        let destination = directory.appendingPathComponent(HandoffText.fileComponent(packet.name) + ".zip")
        try OfficeBatchArchiveService().createArchive(sources: archiveSources, destination: destination)
        try LocalFileSecurity.requireCompleteProtection(to: destination)
        try LocalFileSecurity.requireExcludedFromBackup(directory)
        // Do not retain a second loose copy of manifests containing document names.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url != destination {
            try FileManager.default.removeItem(at: url)
        }
        succeeded = true
        return destination
    }

    private func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try file.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
