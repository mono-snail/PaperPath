import CryptoKit
import Foundation
import Security

struct DocumentStoreBootstrapSnapshot {
    let documents: [DocumentRecord]
    let deletedDocuments: [DocumentRecord]
    let documentURLs: [UUID: URL]
    let textIndices: [UUID: DocumentTextIndex]
    let ocrResults: [UUID: OCRResult]
    let deliveryPreflightCache:
        [UUID: PDFDeliveryPreflightCacheEntry]
}

struct PreparedPDFWorkingCopy: Sendable {
    let recordID: UUID
    let sourceRevisionID: UUID
    let preparedURL: URL
}

struct PreparedPDFWorkingCopyBatchResult: Sendable {
    let records: [DocumentRecord]
    let batesReceipt: PDFSignedBatesBatchReceipt?
}

private struct PDFWorkingCopyTransactionJournal: Codable {
    struct Entry: Codable {
        let destinationPath: String
        let backupPath: String
        let stagingPath: String
        let backupFingerprint: String
    }

    let id: UUID
    let createdAt: Date
    let entries: [Entry]
}

actor DocumentStore {
    private static let maximumVersionsPerDocument = 12
    private static let maximumVersionBytes: Int64 =
        1_024 * 1_024 * 1_024
    private static let maximumPinnedOfficeExportsPerDocument = 4
    private static let maximumPinnedOfficeExportBytes: Int64 =
        512 * 1_024 * 1_024
    private static let maximumOfficeDeliveryPackages = 8
    private static let maximumPinnedOfficeDeliveryPackages = 4

    private let rootURL: URL
    private let filesURL: URL
    private let versionsURL: URL
    private let indicesURL: URL
    private let ocrURL: URL
    private let preflightURL: URL
    private let officeExportsURL: URL
    private let officeDeliveriesURL: URL
    private let indexURL: URL
    private let versionsIndexURL: URL
    private let batchDeliveryURL: URL
    private let officeProductionQueueURL: URL
    private let officeDeliveryIndexURL: URL
    private let officeTrustedSignersURL: URL
    private let batesBatchReceiptsURL: URL
    private let workingCopyTransactionJournalURL: URL
    private let fileManager: FileManager
    private let inspector: PDFInspectionService
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let signingPrivateKeyProvider:
        (@Sendable () throws -> Curve25519.Signing.PrivateKey)?
    private var didRecoverInterruptedWorkingCopyTransaction = false

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        inspector: PDFInspectionService = PDFInspectionService(),
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { url in
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            return values?.volumeAvailableCapacityForImportantUsage
        },
        signingPrivateKeyProvider:
            (@Sendable () throws -> Curve25519.Signing.PrivateKey)? = nil
    ) {
        self.fileManager = fileManager
        self.inspector = inspector
        self.availableCapacity = availableCapacity
        self.signingPrivateKeyProvider = signingPrivateKeyProvider

        let baseURL: URL
        if let rootURL {
            baseURL = rootURL
        } else {
            baseURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("PaperPath", isDirectory: true)
        }
        self.rootURL = baseURL
        self.filesURL = baseURL.appendingPathComponent("Documents", isDirectory: true)
        self.versionsURL = baseURL.appendingPathComponent(
            "Versions",
            isDirectory: true
        )
        self.indicesURL = baseURL.appendingPathComponent("TextIndex", isDirectory: true)
        self.ocrURL = baseURL.appendingPathComponent("OCR", isDirectory: true)
        self.preflightURL = baseURL.appendingPathComponent(
            "DeliveryPreflight",
            isDirectory: true
        )
        self.officeExportsURL = baseURL.appendingPathComponent(
            "OfficeExports",
            isDirectory: true
        )
        self.officeDeliveriesURL = baseURL.appendingPathComponent(
            "OfficeDeliveries",
            isDirectory: true
        )
        self.indexURL = baseURL.appendingPathComponent("library.json")
        self.versionsIndexURL = baseURL.appendingPathComponent(
            "versions.json"
        )
        self.batchDeliveryURL = baseURL.appendingPathComponent(
            "last-batch-delivery.json"
        )
        self.officeProductionQueueURL = baseURL.appendingPathComponent(
            "office-production-queue.json"
        )
        self.officeDeliveryIndexURL = baseURL.appendingPathComponent(
            "office-deliveries.json"
        )
        self.officeTrustedSignersURL = baseURL.appendingPathComponent(
            "office-trusted-signers.json"
        )
        self.batesBatchReceiptsURL = baseURL.appendingPathComponent(
            "bates-batch-receipts.json"
        )
        self.workingCopyTransactionJournalURL =
            baseURL.appendingPathComponent(
                "active-working-copy-transaction.json"
            )
    }

    func loadBootstrapSnapshot() throws
        -> DocumentStoreBootstrapSnapshot {
        let records = try loadExistingRecords()
        let active = sorted(
            records.filter { $0.deletedAt == nil }
        )
        let deleted = records
            .filter { $0.deletedAt != nil }
            .sorted {
                ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
        let urls = Dictionary(
            uniqueKeysWithValues: active.map {
                ($0.id, url(for: $0))
            }
        )
        return DocumentStoreBootstrapSnapshot(
            documents: active,
            deletedDocuments: deleted,
            documentURLs: urls,
            textIndices: try loadTextIndices(for: active),
            ocrResults: try loadOCRResults(for: active),
            deliveryPreflightCache:
                try loadDeliveryPreflightCache(for: active)
        )
    }

    func load() throws -> [DocumentRecord] {
        sorted(
            try loadExistingRecords().filter {
                $0.deletedAt == nil
            }
        )
    }

    func eraseAllData() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try prepareDirectories()
    }

    func loadDeleted() throws -> [DocumentRecord] {
        try loadExistingRecords()
            .filter { $0.deletedAt != nil }
            .sorted {
                ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
    }

    func importPDF(
        from sourceURL: URL,
        preferredName: String? = nil,
        deliveryReceipt: PDFDeliveryReceipt? = nil,
        sourceDocumentID: UUID? = nil,
        contentRevisionID: UUID? = nil,
        preserveSourceLocation: Bool = true
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = filesURL.appendingPathComponent(fileName)

        do {
            try Task.checkCancellation()
            try ensureCapacity(for: sourceURL)
            try fileManager.copyItem(at: sourceURL, to: destination)
            try Task.checkCancellation()
            try requireFileProtection(to: destination)
            let profile = try inspector.inspect(url: destination)
            try Task.checkCancellation()
            let contentFingerprint = try fileFingerprint(
                at: destination
            )
            try Task.checkCancellation()
            let sourceFingerprint = preserveSourceLocation
                ? contentFingerprint
                : nil
            let sourceBookmark = preserveSourceLocation
                ? try? sourceURL.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: [
                        .nameKey,
                        .contentModificationDateKey,
                        .isUbiquitousItemKey
                    ],
                    relativeTo: nil
                )
                : nil
            let record = DocumentRecord(
                id: id,
                displayName: normalizedName(
                    preferredName ?? sourceURL.deletingPathExtension().lastPathComponent
                ),
                fileName: fileName,
                contentRevisionID: contentRevisionID ?? UUID(),
                profile: profile,
                deliveryReceipt: deliveryReceipt,
                sourceDocumentID: sourceDocumentID,
                sourceBookmarkData: sourceBookmark,
                sourceLocationName: preserveSourceLocation
                    ? sourceURL.lastPathComponent
                    : nil,
                sourceImportedFingerprint: sourceFingerprint,
                contentFingerprint: contentFingerprint
            )
            var records = try loadIndex()
            records.append(record)
            try Task.checkCancellation()
            try saveIndex(records)
            return record
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func duplicate(_ record: DocumentRecord) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()

        let sourceURL = url(for: record)
        try ensureCapacity(for: sourceURL)

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = filesURL.appendingPathComponent(fileName)
        let records = try loadIndex()

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            try Task.checkCancellation()
            try requireFileProtection(to: destination)

            let duplicated = DocumentRecord(
                id: id,
                displayName: duplicateName(
                    for: record.displayName,
                    records: records
                ),
                fileName: fileName,
                importedAt: Date(),
                modifiedAt: Date(),
                contentRevisionID: UUID(),
                profile: record.profile,
                workflowStatus: record.workflowStatus,
                isPinned: false,
                tags: record.tags,
                bookmarkedPages: record.bookmarkedPages,
                lastPageIndex: record.lastPageIndex,
                lastViewedAt: Date(),
                completedActions: record.completedActions,
                taskCheckpoint: nil,
                brief: record.brief,
                deliveryReceipt: nil,
                sourceDocumentID: nil,
                sourceBookmarkData: nil,
                sourceLocationName: nil,
                sourceImportedFingerprint: nil,
                sourceWritebackAt: nil,
                contentFingerprint: record.contentFingerprint,
                dueAt: record.dueAt,
                privateNote: record.privateNote,
                bookmarkNames: record.bookmarkNames
            )

            var updatedRecords = records
            updatedRecords.append(duplicated)
            try saveIndex(updatedRecords)
            return duplicated
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func refresh(
        _ record: DocumentRecord,
        invalidateAnalysis: Bool = false
    ) throws -> DocumentRecord {
        let profile = try inspector.inspect(url: url(for: record))
        var updated = record
        updated.profile = profile
        updated.lastPageIndex = min(
            max(updated.lastPageIndex, 0),
            max(0, profile.pageCount - 1)
        )
        updated.taskCheckpoint = updated.taskCheckpoint?.bounded(
            toPageCount: profile.pageCount
        )
        updated.modifiedAt = Date()
        updated.contentRevisionID = UUID()
        updated.contentFingerprint = try fileFingerprint(
            at: url(for: record)
        )
        removeDeliveryPreflight(recordID: record.id)
        if invalidateAnalysis {
            updated.brief = nil
            try? removeSidecars(for: record)
        }
        try replaceRecord(updated)
        return updated
    }

    func replaceWorkingCopies(
        with preparedCopies: [PreparedPDFWorkingCopy],
        invalidateAnalysis: Bool = false
    ) throws -> [DocumentRecord] {
        try commitWorkingCopies(
            preparedCopies,
            invalidateAnalysis: invalidateAnalysis,
            batesPlan: nil,
            batesRemovalReceiptID: nil
        ).records
    }

    func replaceWorkingCopiesAndCreateBatesReceipt(
        with preparedCopies: [PreparedPDFWorkingCopy],
        plan: PDFBatesBatchPlan
    ) throws -> PreparedPDFWorkingCopyBatchResult {
        let result = try commitWorkingCopies(
            preparedCopies,
            invalidateAnalysis: false,
            batesPlan: plan,
            batesRemovalReceiptID: nil
        )
        guard result.batesReceipt != nil else {
            throw PaperPathError.storageFailure(
                "The Bates receipt was not included in its transaction."
            )
        }
        return result
    }

    func replaceWorkingCopiesAndCreateBatesRemovalReceipt(
        with preparedCopies: [PreparedPDFWorkingCopy],
        receiptID: UUID
    ) throws -> PreparedPDFWorkingCopyBatchResult {
        let result = try commitWorkingCopies(
            preparedCopies,
            invalidateAnalysis: false,
            batesPlan: nil,
            batesRemovalReceiptID: receiptID
        )
        guard result.batesReceipt?.removal != nil else {
            throw PaperPathError.storageFailure(
                "The Bates removal receipt was not included in its transaction."
            )
        }
        return result
    }

    private func commitWorkingCopies(
        _ preparedCopies: [PreparedPDFWorkingCopy],
        invalidateAnalysis: Bool,
        batesPlan: PDFBatesBatchPlan?,
        batesRemovalReceiptID: UUID?
    ) throws -> PreparedPDFWorkingCopyBatchResult {
        try prepareDirectories()
        try Task.checkCancellation()
        guard batesPlan == nil || batesRemovalReceiptID == nil else {
            throw PaperPathError.insufficientSelection(
                "A PDF batch cannot add and remove Bates numbers together."
            )
        }
        guard !preparedCopies.isEmpty,
              preparedCopies.count
                <= PDFBatesBatchPlan.maximumDocumentCount,
              Set(preparedCopies.map(\.recordID)).count
                == preparedCopies.count,
              Set(
                  preparedCopies.map {
                      $0.preparedURL.standardizedFileURL.path
                  }
              ).count == preparedCopies.count
        else {
            throw PaperPathError.insufficientSelection(
                "The document batch is invalid."
            )
        }

        var records = try loadIndex()
        var updatedByID: [UUID: DocumentRecord] = [:]
        var expectedFingerprints: [UUID: String] = [:]
        var sourceByDestination: [URL: URL] = [:]
        var sourceRecordsByID: [UUID: DocumentRecord] = [:]
        let now = Date()

        for prepared in preparedCopies {
            try Task.checkCancellation()
            guard let recordIndex = records.firstIndex(where: {
                $0.id == prepared.recordID
            }) else {
                throw PaperPathError.storageFailure(
                    "A selected working copy is unavailable."
                )
            }
            let stored = records[recordIndex]
            let destination = url(for: stored)
            guard stored.deletedAt == nil,
                  stored.isWorkingCopy,
                  stored.contentRevisionID
                    == prepared.sourceRevisionID,
                  fileManager.fileExists(atPath: destination.path),
                  fileManager.fileExists(
                      atPath: prepared.preparedURL.path
                  )
            else {
                throw PaperPathError.insufficientSelection(
                    "A selected PDF changed before the batch was committed."
                )
            }
            let profile = try inspector.inspect(
                url: prepared.preparedURL
            )
            guard !profile.isLocked,
                  profile.pageCount == stored.profile.pageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a prepared PDF changed its page structure"
                )
            }
            let fingerprint = try fileFingerprint(
                at: prepared.preparedURL
            )
            guard fingerprint.count == 64 else {
                throw PaperPathError.outputVerificationFailed(
                    "a prepared PDF has no valid fingerprint"
                )
            }

            var updated = stored
            updated.profile = profile
            updated.modifiedAt = now
            updated.contentRevisionID = UUID()
            updated.contentFingerprint = fingerprint
            if invalidateAnalysis {
                updated.brief = nil
            }
            records[recordIndex] = updated
            updatedByID[updated.id] = updated
            sourceRecordsByID[stored.id] = stored
            expectedFingerprints[updated.id] = fingerprint
            sourceByDestination[destination] = prepared.preparedURL
        }
        guard sourceByDestination.count == preparedCopies.count else {
            throw PaperPathError.storageFailure(
                "The document batch contains duplicate destinations."
            )
        }

        let indexData = try JSONEncoder.paperPath.encode(
            sorted(records)
        )
        var signedBatesReceipt: PDFSignedBatesBatchReceipt?
        var metadataWrites: [(data: Data, destination: URL)] = []
        if let batesPlan {
            let receipt = try makeSignedBatesBatchReceipt(
                plan: batesPlan,
                sourceRecordsByID: sourceRecordsByID,
                updatedByID: updatedByID,
                preparedCopies: preparedCopies
            )
            var receipts = try loadBatesBatchReceipts()
            receipts.removeAll { $0.id == receipt.id }
            receipts.insert(receipt, at: 0)
            let bounded = boundedBatesBatchReceipts(receipts)
            guard bounded.contains(where: { $0.id == receipt.id })
            else {
                throw PaperPathError.storageFailure(
                    "The new Bates receipt exceeds the local history limit."
                )
            }
            let receiptData = try JSONEncoder.paperPath.encode(
                bounded
            )
            guard receiptData.count
                    <= PDFBatesBatchReceiptPayload.maximumHistoryBytes
            else {
                throw PaperPathError.storageFailure(
                    "The Bates receipt history exceeds its local limit."
                )
            }
            signedBatesReceipt = receipt
            metadataWrites.append(
                (receiptData, batesBatchReceiptsURL)
            )
        } else if let batesRemovalReceiptID {
            var receipts = try loadBatesBatchReceipts()
            guard let receiptIndex = receipts.firstIndex(where: {
                $0.id == batesRemovalReceiptID
            }) else {
                throw PaperPathError.storageFailure(
                    "This Bates receipt is no longer available."
                )
            }
            let receipt = receipts[receiptIndex]
            guard receipt.removal == nil else {
                throw PaperPathError.insufficientSelection(
                    "This Bates batch already has a signed removal receipt."
                )
            }
            let removal = try makeSignedBatesRemovalReceipt(
                for: receipt,
                sourceRecordsByID: sourceRecordsByID,
                updatedByID: updatedByID,
                preparedCopies: preparedCopies
            )
            let updatedReceipt = PDFSignedBatesBatchReceipt(
                payload: receipt.payload,
                signature: receipt.signature,
                removal: removal
            )
            receipts[receiptIndex] = updatedReceipt
            let bounded = boundedBatesBatchReceipts(receipts)
            guard bounded.contains(updatedReceipt) else {
                throw PaperPathError.storageFailure(
                    "The Bates removal receipt exceeds the local history limit."
                )
            }
            let receiptData = try JSONEncoder.paperPath.encode(
                bounded
            )
            guard receiptData.count
                    <= PDFBatesBatchReceiptPayload.maximumHistoryBytes
            else {
                throw PaperPathError.storageFailure(
                    "The Bates receipt history exceeds its local limit."
                )
            }
            signedBatesReceipt = updatedReceipt
            metadataWrites.append(
                (receiptData, batesBatchReceiptsURL)
            )
        }
        metadataWrites.append((indexData, indexURL))
        try ensurePreparedCopyTransactionCapacity(
            sources: Array(sourceByDestination.values),
            destinations: Array(sourceByDestination.keys),
            metadataWrites: metadataWrites
        )

        var stagingByDestination: [URL: URL] = [:]
        var backupByDestination: [URL: URL] = [:]
        let destinations = Array(sourceByDestination.keys)
            + metadataWrites.map(\.destination)
        var didStartPublishing = false

        func removeIfPresent(_ url: URL) throws {
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }

        do {
            for (destination, source) in sourceByDestination {
                try Task.checkCancellation()
                let staging = destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".batch-\(UUID().uuidString)",
                        isDirectory: false
                    )
                try fileManager.copyItem(at: source, to: staging)
                try requireFileProtection(to: staging)
                stagingByDestination[destination] = staging
            }

            for write in metadataWrites {
                let staging = write.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".batch-metadata-\(UUID().uuidString)",
                        isDirectory: false
                    )
                try write.data.write(to: staging, options: .atomic)
                try requireFileProtection(to: staging)
                stagingByDestination[write.destination] = staging
            }

            for destination in destinations
            where fileManager.fileExists(atPath: destination.path) {
                try Task.checkCancellation()
                let backup = destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".batch-rollback-\(UUID().uuidString)",
                        isDirectory: false
                    )
                try fileManager.copyItem(
                    at: destination,
                    to: backup
                )
                try requireFileProtection(to: backup)
                backupByDestination[destination] = backup
            }

            guard backupByDestination.count == destinations.count else {
                throw PaperPathError.storageFailure(
                    "The PDF batch recovery set is incomplete."
                )
            }
            let journal = PDFWorkingCopyTransactionJournal(
                id: UUID(),
                createdAt: Date(),
                entries: try destinations.compactMap { destination in
                    guard let backup =
                            backupByDestination[destination],
                          let staging =
                            stagingByDestination[destination]
                    else { return nil }
                    return PDFWorkingCopyTransactionJournal.Entry(
                        destinationPath:
                            destination.standardizedFileURL.path,
                        backupPath: backup.standardizedFileURL.path,
                        stagingPath: staging.standardizedFileURL.path,
                        backupFingerprint: try fileFingerprint(
                            at: backup
                        )
                    )
                }
            )
            guard journal.entries.count == destinations.count else {
                throw PaperPathError.storageFailure(
                    "The PDF batch recovery journal is incomplete."
                )
            }
            try writeProtectedData(
                try JSONEncoder.paperPath.encode(journal),
                to: workingCopyTransactionJournalURL
            )
            try Task.checkCancellation()
            didStartPublishing = true
            for destination in destinations {
                guard let staging = stagingByDestination[destination]
                else {
                    throw PaperPathError.storageFailure(
                        "A prepared batch file is missing."
                    )
                }
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(
                        destination,
                        withItemAt: staging
                    )
                } else {
                    try fileManager.moveItem(
                        at: staging,
                        to: destination
                    )
                }
                try requireFileProtection(to: destination)
            }

            let committedRecords = try loadIndex()
            let committedByID = Dictionary(
                uniqueKeysWithValues: committedRecords.map {
                    ($0.id, $0)
                }
            )
            for prepared in preparedCopies {
                guard let expected =
                    expectedFingerprints[prepared.recordID],
                      let committed =
                    committedByID[prepared.recordID],
                      committed.contentFingerprint == expected,
                      try fileFingerprint(
                          at: url(for: committed)
                      ) == expected,
                      try inspector.inspect(
                          url: url(for: committed)
                      ).pageCount == committed.profile.pageCount
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the committed batch did not match its index"
                    )
                }
            }
            if let signedBatesReceipt {
                let persisted = try loadBatesBatchReceipts()
                let expectedData = try JSONEncoder.paperPath.encode(
                    signedBatesReceipt
                )
                guard let persistedReceipt = persisted.first(
                    where: { $0.id == signedBatesReceipt.id }
                ),
                      try JSONEncoder.paperPath.encode(
                          persistedReceipt
                      ) == expectedData
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the signed Bates receipt did not persist"
                    )
                }
            }
            try removeIfPresent(workingCopyTransactionJournalURL)
        } catch {
            var rollbackFailed = false
            if didStartPublishing {
                for destination in destinations.reversed() {
                    do {
                        try removeIfPresent(destination)
                        if let backup = backupByDestination[destination],
                           fileManager.fileExists(atPath: backup.path) {
                            try fileManager.moveItem(
                                at: backup,
                                to: destination
                            )
                            try requireFileProtection(to: destination)
                        }
                    } catch {
                        rollbackFailed = true
                    }
                }
            }
            for staging in stagingByDestination.values {
                try? removeIfPresent(staging)
            }
            if !rollbackFailed {
                for backup in backupByDestination.values {
                    try? removeIfPresent(backup)
                }
                try? removeIfPresent(
                    workingCopyTransactionJournalURL
                )
            }
            if rollbackFailed {
                throw PaperPathError.storageFailure(
                    "The PDF batch could not be rolled back."
                )
            }
            throw error
        }

        for staging in stagingByDestination.values {
            try? removeIfPresent(staging)
        }
        for backup in backupByDestination.values {
            try? removeIfPresent(backup)
        }
        for prepared in preparedCopies {
            removeDeliveryPreflight(recordID: prepared.recordID)
            if invalidateAnalysis,
               let updated = updatedByID[prepared.recordID] {
                try? removeSidecars(for: updated)
            }
        }
        return PreparedPDFWorkingCopyBatchResult(
            records: preparedCopies.compactMap {
                updatedByID[$0.recordID]
            },
            batesReceipt: signedBatesReceipt
        )
    }

    func ensureContentFingerprints(
        for records: [DocumentRecord]
    ) throws -> [DocumentRecord] {
        var updatedRecords = records
        var didChange = false
        for index in updatedRecords.indices {
            let existing = updatedRecords[index].contentFingerprint
            if let existing,
               existing.count == 64,
               existing.allSatisfy(\.isHexDigit) {
                continue
            }
            updatedRecords[index].contentFingerprint = try fileFingerprint(
                at: url(for: updatedRecords[index])
            )
            didChange = true
        }
        if didChange {
            try saveIndex(updatedRecords)
        }
        return sorted(updatedRecords)
    }

    func rename(_ record: DocumentRecord, to proposedName: String) throws -> DocumentRecord {
        var updated = record
        updated.displayName = normalizedName(proposedName)
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateWorkflow(
        _ record: DocumentRecord,
        status: DocumentWorkflowStatus
    ) throws -> DocumentRecord {
        var updated = record
        updated.workflowStatus = status
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func setPinned(
        _ record: DocumentRecord,
        isPinned: Bool
    ) throws -> DocumentRecord {
        var updated = record
        updated.isPinned = isPinned
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateTags(
        _ record: DocumentRecord,
        tags: [String]
    ) throws -> DocumentRecord {
        let normalized = normalizedTags(tags)
        var updated = record
        updated.tags = normalized
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateDueDate(
        _ record: DocumentRecord,
        dueAt: Date?
    ) throws -> DocumentRecord {
        var updated = record
        updated.dueAt = dueAt.map {
            Calendar.current.startOfDay(for: $0)
        }
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updatePrivateNote(
        _ record: DocumentRecord,
        note: String?
    ) throws -> DocumentRecord {
        let normalized = note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = record
        if let normalized, !normalized.isEmpty {
            updated.privateNote = String(normalized.prefix(1_000))
        } else {
            updated.privateNote = nil
        }
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func recordOfficeExportReceipt(
        _ receipt: PDFOfficeExportReceipt,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        var updated = record
        updated.officeReceipts = boundedOfficeReceipts(
            ([receipt] + record.officeReceipts.filter {
                $0.id != receipt.id
            })
        )
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateOfficeBatchRun(
        _ run: PDFOfficeBatchRun?,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        var updated = record
        updated.officeBatchRun = run
        try replaceRecord(updated)
        return updated
    }

    func retainOfficeExport(
        _ receipt: PDFOfficeExportReceipt,
        sourceURL: URL,
        for record: DocumentRecord
    ) throws -> (
        receipt: PDFOfficeExportReceipt,
        record: DocumentRecord,
        url: URL
    ) {
        try prepareDirectories()
        try Task.checkCancellation()
        try ensureCapacity(for: sourceURL)

        let directory = officeExportDirectory(for: record.id)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try requireFileProtection(to: directory)

        let retainedFileName =
            "\(receipt.id.uuidString).\(receipt.format.fileExtension)"
        let destination = directory.appendingPathComponent(
            retainedFileName
        )
        let staging = directory.appendingPathComponent(
            ".staging-\(UUID().uuidString)"
        )
        defer {
            try? fileManager.removeItem(at: staging)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: staging)
            try Task.checkCancellation()
            try requireFileProtection(to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
            try requireFileProtection(to: destination)

            let retainedSize = try destination.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard retainedSize.isRegularFile == true,
                  Int64(retainedSize.fileSize ?? -1)
                    == receipt.fileSizeBytes
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office file size changed"
                )
            }

            var retainedReceipt = receipt
            retainedReceipt.sourceRevisionID = record.contentRevisionID
            retainedReceipt.retainedFileName = retainedFileName
            retainedReceipt.artifactSHA256 = try fileFingerprint(
                at: destination
            )
            retainedReceipt.reusableUntil = Calendar.current.date(
                byAdding: .day,
                value: 7,
                to: receipt.exportedAt
            ) ?? receipt.exportedAt.addingTimeInterval(
                7 * 24 * 60 * 60
            )

            var updated = record
            updated.officeReceipts = boundedOfficeReceipts(
                ([retainedReceipt] + record.officeReceipts.filter {
                    $0.id != retainedReceipt.id
                })
            )
            updated.modifiedAt = Date()
            try replaceRecord(updated)
            pruneOfficeExportDirectory(for: updated)
            return (
                receipt: retainedReceipt,
                record: updated,
                url: destination
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func setOfficeExportPinned(
        receiptID: UUID,
        pinned: Bool,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        guard let receiptIndex = record.officeReceipts.firstIndex(
            where: { $0.id == receiptID }
        ) else {
            throw PaperPathError.insufficientSelection(
                "This Office receipt is no longer available."
            )
        }

        let target = record.officeReceipts[receiptIndex]
        if !pinned {
            var updated = record
            updated.officeReceipts[receiptIndex].pinnedAt = nil
            updated.officeReceipts = boundedOfficeReceipts(
                updated.officeReceipts
            )
            updated.modifiedAt = Date()
            try replaceRecord(updated)
            pruneOfficeExportDirectory(for: updated)
            return updated
        }

        guard target.artifactAvailability(
            for: record.contentRevisionID
        ) == .reusable,
              let fileName = target.retainedFileName,
              isSafeOfficeExportFileName(fileName)
        else {
            throw PaperPathError.insufficientSelection(
                "Only a current reusable Office output can be pinned."
            )
        }

        let url = officeExportDirectory(for: record.id)
            .appendingPathComponent(fileName)
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
              values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == target.fileSizeBytes
        else {
            try? fileManager.removeItem(at: url)
            throw PaperPathError.outputVerificationFailed(
                "the retained Office file is unavailable"
            )
        }

        if !target.isPinned {
            let pinnedReceipts = record.officeReceipts.filter(\.isPinned)
            guard pinnedReceipts.count
                    < Self.maximumPinnedOfficeExportsPerDocument
            else {
                throw PaperPathError.insufficientSelection(
                    "Keep up to 4 pinned Office outputs per PDF."
                )
            }
            let pinnedBytes = pinnedReceipts.reduce(Int64(0)) {
                $0 + $1.fileSizeBytes
            }
            guard pinnedBytes + target.fileSizeBytes
                    <= Self.maximumPinnedOfficeExportBytes
            else {
                throw PaperPathError.insufficientStorage
            }
        }

        var updated = record
        updated.officeReceipts[receiptIndex].pinnedAt = Date()
        updated.officeReceipts = boundedOfficeReceipts(
            updated.officeReceipts
        )
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        pruneOfficeExportDirectory(for: updated)
        return updated
    }

    func reusableOfficeExportURL(
        for receipt: PDFOfficeExportReceipt,
        record: DocumentRecord
    ) -> URL? {
        guard receipt.artifactAvailability(
            for: record.contentRevisionID
        ) == .reusable,
              let fileName = receipt.retainedFileName,
              isSafeOfficeExportFileName(fileName)
        else {
            return nil
        }
        let url = officeExportDirectory(for: record.id)
            .appendingPathComponent(fileName)
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        ),
              values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == receipt.fileSizeBytes
        else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return url
    }

    func verifyOfficeExport(
        receiptID: UUID,
        for record: DocumentRecord,
        progress: (
            @Sendable (_ processedBytes: Int64, _ totalBytes: Int64)
                -> Void
        )? = nil
    ) throws -> PDFOfficeIntegrityVerification {
        guard let receiptIndex = record.officeReceipts.firstIndex(
            where: { $0.id == receiptID }
        ) else {
            throw PaperPathError.insufficientSelection(
                "This Office receipt is no longer available."
            )
        }

        var updated = record
        var receipt = updated.officeReceipts[receiptIndex]
        let checkedAt = Date()
        let status: PDFOfficeIntegrityStatus
        var verifiedURL: URL?

        if receipt.sourceRevisionID != record.contentRevisionID {
            status = .sourceChanged
        } else if receipt.artifactAvailability(
            for: record.contentRevisionID
        ) != .reusable {
            status = .missing
        } else if let fileName = receipt.retainedFileName,
                  isSafeOfficeExportFileName(fileName) {
            let url = officeExportDirectory(for: record.id)
                .appendingPathComponent(fileName)
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            if values?.isRegularFile != true
                || Int64(values?.fileSize ?? -1)
                    != receipt.fileSizeBytes {
                status = .missing
            } else {
                let actualFingerprint = try fileFingerprint(
                    at: url,
                    progress: progress
                )
                if let expected = receipt.artifactSHA256,
                   !expected.isEmpty,
                   expected != actualFingerprint {
                    status = .mismatch
                } else {
                    receipt.artifactSHA256 = actualFingerprint
                    status = .verified
                    verifiedURL = url
                }
            }
        } else {
            status = .missing
        }

        receipt.integrityStatus = status
        receipt.integrityCheckedAt = checkedAt
        updated.officeReceipts[receiptIndex] = receipt
        updated.officeReceipts = boundedOfficeReceipts(
            updated.officeReceipts
        )
        try replaceRecord(updated)
        return PDFOfficeIntegrityVerification(
            recordID: record.id,
            record: updated,
            receipt: receipt,
            status: status,
            url: verifiedURL
        )
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        let normalized = tags.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let shortened = String(trimmed.prefix(24))
            guard seen.insert(shortened.lowercased()).inserted else { return nil }
            return shortened
        }
        return Array(normalized.prefix(8))
    }

    func updateBookmarks(
        _ record: DocumentRecord,
        pages: [Int],
        preserveNames: Bool = false
    ) throws -> DocumentRecord {
        var updated = record
        updated.bookmarkedPages = Array(
            Set(
                pages.filter {
                    $0 >= 0 && $0 < record.profile.pageCount
                }
            )
        ).sorted()
        if preserveNames {
            let validPages = Set(updated.bookmarkedPages)
            updated.bookmarkNames = record.bookmarkNames.filter {
                validPages.contains($0.key)
            }
        } else if updated.bookmarkedPages != record.bookmarkedPages {
            updated.bookmarkNames = [:]
        }
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateBookmarkName(
        _ record: DocumentRecord,
        pageIndex: Int,
        name: String?
    ) throws -> DocumentRecord {
        guard record.bookmarkedPages.contains(pageIndex) else {
            return record
        }
        var updated = record
        let normalized = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            updated.bookmarkNames[pageIndex] = String(
                normalized.prefix(80)
            )
        } else {
            updated.bookmarkNames[pageIndex] = nil
        }
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateReadingPosition(
        _ record: DocumentRecord,
        pageIndex: Int,
        viewedAt: Date = Date()
    ) throws -> DocumentRecord {
        let bounded = min(
            max(pageIndex, 0),
            max(0, record.profile.pageCount - 1)
        )
        var updated = record
        updated.lastPageIndex = bounded
        updated.lastViewedAt = viewedAt
        try replaceRecord(updated)
        return updated
    }

    func applyMetadataSync(
        _ update: PDFMetadataSyncUpdate,
        to record: DocumentRecord
    ) throws -> DocumentRecord {
        guard update.recordID == record.id,
              update.fingerprint == record.contentFingerprint?
                .lowercased()
        else {
            throw PaperPathError.storageFailure(
                "The synced metadata does not match this document."
            )
        }
        var updated = record
        updated.lastPageIndex = min(
            max(update.lastPageIndex, 0),
            max(0, record.profile.pageCount - 1)
        )
        if let remoteViewedAt = update.lastViewedAt,
           remoteViewedAt > (record.lastViewedAt ?? .distantPast) {
            updated.lastViewedAt = remoteViewedAt
        }
        updated.bookmarkedPages = Array(
            Set(
                update.bookmarkedPages.filter {
                    $0 >= 0 && $0 < record.profile.pageCount
                }
            )
        ).sorted()
        updated.workflowStatus = update.workflowStatus
        updated.isPinned = update.isPinned
        updated.tags = normalizedTags(update.tags)
        updated.completedActions = update.completedActions

        if let receipt = update.deliveryReceipt,
           receipt.sha256.lowercased() == update.fingerprint,
           receipt.outputPageCount == record.profile.pageCount,
           (try? fileFingerprint(
               at: url(for: record)
           ))?.lowercased() == update.fingerprint {
            var verifiedReceipt = receipt
            verifiedReceipt.outputRevisionID = record.contentRevisionID
            updated.deliveryReceipt = verifiedReceipt
        }
        updated.modifiedAt = max(record.modifiedAt, update.updatedAt)
        try replaceRecord(updated)
        return updated
    }

    func sourceLocation(
        for record: DocumentRecord
    ) throws -> PDFSourceLocationSnapshot {
        guard let bookmarkData = record.sourceBookmarkData else {
            return PDFSourceLocationSnapshot(
                status: .detached,
                name: record.sourceLocationName,
                resolvedURL: nil,
                isUbiquitous: false,
                modificationDate: nil
            )
        }
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            return PDFSourceLocationSnapshot(
                status: .unavailable,
                name: record.sourceLocationName,
                resolvedURL: nil,
                isUbiquitous: false,
                modificationDate: nil
            )
        }
        let hasAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        guard fileManager.fileExists(atPath: resolvedURL.path) else {
            return PDFSourceLocationSnapshot(
                status: isStale ? .stale : .unavailable,
                name: record.sourceLocationName,
                resolvedURL: resolvedURL,
                isUbiquitous: false,
                modificationDate: nil
            )
        }
        let values = try? resolvedURL.resourceValues(
            forKeys: [
                .isUbiquitousItemKey,
                .contentModificationDateKey
            ]
        )
        let fingerprint = try fileFingerprint(at: resolvedURL)
        let status: PDFSourceLocationStatus
        if isStale {
            status = .stale
        } else if fingerprint == record.sourceImportedFingerprint {
            status = .current
        } else {
            status = .changed
        }
        return PDFSourceLocationSnapshot(
            status: status,
            name: record.sourceLocationName
                ?? resolvedURL.lastPathComponent,
            resolvedURL: resolvedURL,
            isUbiquitous: values?.isUbiquitousItem ?? false,
            modificationDate: values?.contentModificationDate
        )
    }

    func writeBackToSource(
        _ record: DocumentRecord
    ) throws -> DocumentRecord {
        let snapshot = try sourceLocation(for: record)
        guard snapshot.status == .current,
              let sourceURL = snapshot.resolvedURL
        else {
            throw PaperPathError.storageFailure(
                "The original changed or is unavailable. Import its latest version before replacing it."
            )
        }
        let workingURL = url(for: record)
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: sourceURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let coordinatedFingerprint = try fileFingerprint(
                    at: coordinatedURL
                )
                guard coordinatedFingerprint
                        == record.sourceImportedFingerprint
                else {
                    throw PaperPathError.storageFailure(
                        "The original changed while PaperPath was preparing to write. No file was replaced."
                    )
                }
                let temporaryURL = coordinatedURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".paperpath-\(UUID().uuidString).pdf"
                    )
                defer {
                    try? fileManager.removeItem(at: temporaryURL)
                }
                try fileManager.copyItem(
                    at: workingURL,
                    to: temporaryURL
                )
                _ = try fileManager.replaceItemAt(
                    coordinatedURL,
                    withItemAt: temporaryURL
                )
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
        var updated = record
        updated.sourceImportedFingerprint = try fileFingerprint(
            at: sourceURL
        )
        if let refreshedBookmark = try? sourceURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: [
                    .nameKey,
                    .contentModificationDateKey,
                    .isUbiquitousItemKey
                ],
                relativeTo: nil
            ) {
            updated.sourceBookmarkData = refreshedBookmark
        }
        updated.sourceWritebackAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func setActionCompletion(
        _ record: DocumentRecord,
        action: DocumentAction,
        completed: Bool
    ) throws -> DocumentRecord {
        var updated = record
        if completed {
            updated.completedActions.insert(action)
        } else {
            updated.completedActions.remove(action)
        }
        guard updated.completedActions != record.completedActions else {
            return record
        }
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func updateTaskCheckpoint(
        _ record: DocumentRecord,
        checkpoint: DocumentTaskCheckpoint?
    ) throws -> DocumentRecord {
        let bounded = checkpoint?.bounded(
            toPageCount: record.profile.pageCount
        )
        guard bounded != record.taskCheckpoint else { return record }
        var updated = record
        updated.taskCheckpoint = bounded
        if bounded != nil,
           updated.workflowStatus == .inbox {
            updated.workflowStatus = .reviewing
        }
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func saveAnalysis(
        _ record: DocumentRecord,
        brief: DocumentBrief,
        textIndex: DocumentTextIndex,
        ocrResult: OCRResult? = nil
    ) throws -> DocumentRecord {
        try prepareDirectories()
        do {
            var records = try loadIndex()
            guard let recordIndex = records.firstIndex(
                where: { $0.id == record.id }
            ) else {
                throw PaperPathError.storageFailure(
                    "The document record is missing."
                )
            }
            let storedRecord = records[recordIndex]
            guard storedRecord.deletedAt == nil,
                  storedRecord.contentRevisionID
                    == record.contentRevisionID
            else {
                throw CancellationError()
            }
            var updated = storedRecord
            updated.brief = brief
            updated.modifiedAt = Date()
            records[recordIndex] = updated

            let indexData = try JSONEncoder.paperPath.encode(textIndex)
            var writes: [(data: Data, destination: URL)] = [
                (
                    data: indexData,
                    destination: textIndexURL(for: record.id)
                )
            ]
            if let ocrResult {
                let ocrData = try JSONEncoder.paperPath.encode(ocrResult)
                writes.append(
                    (
                        data: ocrData,
                        destination: ocrResultURL(for: record.id)
                    )
                )
            }
            writes.append(
                (
                    data: try JSONEncoder.paperPath.encode(
                        sorted(records)
                    ),
                    destination: indexURL
                )
            )
            try writeProtectedDataTransaction(writes)
            return updated
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PaperPathError.storageFailure(
                "The local analysis could not be saved."
            )
        }
    }

    func loadTextIndices() throws -> [UUID: DocumentTextIndex] {
        try prepareDirectories()
        return try loadTextIndices(
            for: try loadIndex().filter { $0.deletedAt == nil }
        )
    }

    private func loadTextIndices(
        for records: [DocumentRecord]
    ) throws -> [UUID: DocumentTextIndex] {
        var result: [UUID: DocumentTextIndex] = [:]
        for record in records {
            try Task.checkCancellation()
            let url = textIndexURL(for: record.id)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               let index = try? JSONDecoder.paperPath.decode(
                   DocumentTextIndex.self,
                   from: data
               ) {
                result[record.id] = index
            }
        }
        return result
    }

    func loadOCRResults() throws -> [UUID: OCRResult] {
        try prepareDirectories()
        return try loadOCRResults(
            for: try loadIndex().filter { $0.deletedAt == nil }
        )
    }

    private func loadOCRResults(
        for records: [DocumentRecord]
    ) throws -> [UUID: OCRResult] {
        var result: [UUID: OCRResult] = [:]
        for record in records {
            try Task.checkCancellation()
            let url = ocrResultURL(for: record.id)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               let ocrResult = try? JSONDecoder.paperPath.decode(
                   OCRResult.self,
                   from: data
               ) {
                result[record.id] = ocrResult
            }
        }
        return result
    }

    func loadDeliveryPreflightCache(
        for records: [DocumentRecord]
    ) throws -> [UUID: PDFDeliveryPreflightCacheEntry] {
        try prepareDirectories()
        var result: [UUID: PDFDeliveryPreflightCacheEntry] = [:]
        for record in records {
            try Task.checkCancellation()
            let url = deliveryPreflightURL(for: record.id)
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder.paperPath.decode(
                      PDFDeliveryPreflightCacheEntry.self,
                      from: data
                  ),
                  entry.recordID == record.id,
                  entry.revisionID == record.contentRevisionID
            else { continue }
            result[record.id] = entry
        }
        return result
    }

    func saveDeliveryPreflight(
        _ entry: PDFDeliveryPreflightCacheEntry
    ) throws {
        try prepareDirectories()
        do {
            let data = try JSONEncoder.paperPath.encode(entry)
            let url = deliveryPreflightURL(for: entry.recordID)
            try writeProtectedData(data, to: url)
        } catch {
            throw PaperPathError.storageFailure(
                "The local delivery check could not be saved."
            )
        }
    }

    func removeDeliveryPreflight(recordID: UUID) {
        let url = deliveryPreflightURL(for: recordID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    func loadBatchDeliveryRun() throws -> PDFBatchDeliveryRun? {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: batchDeliveryURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: batchDeliveryURL)
            return try JSONDecoder.paperPath.decode(
                PDFBatchDeliveryRun.self,
                from: data
            )
        } catch {
            try? fileManager.removeItem(at: batchDeliveryURL)
            return nil
        }
    }

    func saveBatchDeliveryRun(_ run: PDFBatchDeliveryRun) throws {
        try prepareDirectories()
        do {
            let data = try JSONEncoder.paperPath.encode(run)
            try writeProtectedData(data, to: batchDeliveryURL)
        } catch {
            throw PaperPathError.storageFailure(
                "The batch recovery state could not be saved."
            )
        }
    }

    func clearBatchDeliveryRun() {
        guard fileManager.fileExists(atPath: batchDeliveryURL.path)
        else { return }
        try? fileManager.removeItem(at: batchDeliveryURL)
    }

    func loadBatesBatchReceipts() throws
        -> [PDFSignedBatesBatchReceipt] {
        try prepareDirectories()
        guard fileManager.fileExists(
            atPath: batesBatchReceiptsURL.path
        ) else { return [] }
        guard fileSize(batesBatchReceiptsURL)
                <= Int64(
                    PDFBatesBatchReceiptPayload.maximumHistoryBytes
                )
        else {
            throw PaperPathError.storageFailure(
                "The Bates receipt history exceeds its local limit."
            )
        }
        do {
            let data = try Data(contentsOf: batesBatchReceiptsURL)
            let receipts = try JSONDecoder.paperPath.decode(
                [PDFSignedBatesBatchReceipt].self,
                from: data
            )
            guard receipts.count
                    <= PDFBatesBatchReceiptPayload.maximumReceiptCount,
                  Set(receipts.map(\.id)).count == receipts.count,
                  receipts.allSatisfy({
                      $0.payload.isStructurallyValid
                          && (
                              $0.removal?.payload.isLinked(
                                  to: $0.payload
                              ) ?? true
                          )
                  })
            else {
                throw PaperPathError.storageFailure(
                    "The Bates receipt history is structurally invalid."
                )
            }
            return receipts.sorted {
                $0.payload.createdAt > $1.payload.createdAt
            }
        } catch let error as PaperPathError {
            throw error
        } catch {
            throw PaperPathError.storageFailure(
                "The Bates receipt history could not be read safely."
            )
        }
    }

    func verifyBatesBatchReceipt(
        _ receipt: PDFSignedBatesBatchReceipt,
        progress: @escaping @MainActor @Sendable (
            PDFBatesBatchReceiptVerificationProgress
        ) -> Void = { _ in }
    ) async throws -> PDFBatesBatchReceiptVerificationReport {
        try prepareDirectories()
        try Task.checkCancellation()
        let payload = receipt.payload
        let signature = receipt.signature
        await progress(
            PDFBatesBatchReceiptVerificationProgress(
                receiptID: receipt.id,
                completedDocumentCount: 0,
                totalDocumentCount: payload.entries.count,
                currentDocumentName: "Signed manifest".localizedUI
            )
        )
        guard payload.isStructurallyValid,
              signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                  base64Encoded: signature.publicKeyBase64
              ),
              let signatureData = Data(
                  base64Encoded: signature.signatureBase64
              ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let canonicalPayload = try? JSONEncoder.paperPath
                .encode(payload)
        else {
            await progress(
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receipt.id,
                    completedDocumentCount: payload.entries.count,
                    totalDocumentCount: payload.entries.count,
                    currentDocumentName: "Signature rejected".localizedUI
                )
            )
            return untrustedBatesBatchReport(
                receipt,
                status: .unsupported,
                detail: "The Bates receipt uses an unsupported envelope."
            )
        }
        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: publicKeyData
        )
        guard calculatedKeyID == signature.keyID,
              publicKey.isValidSignature(
                  signatureData,
                  for: canonicalPayload
              )
        else {
            await progress(
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receipt.id,
                    completedDocumentCount: payload.entries.count,
                    totalDocumentCount: payload.entries.count,
                    currentDocumentName: "Signature rejected".localizedUI
                )
            )
            return untrustedBatesBatchReport(
                receipt,
                status: .invalid,
                detail:
                    "The Bates receipt payload, public key, or signature changed."
            )
        }
        if let removal = receipt.removal,
           !isValidBatesRemovalReceiptSignature(
               removal,
               for: receipt.payload
           ) {
            await progress(
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receipt.id,
                    completedDocumentCount: payload.entries.count,
                    totalDocumentCount: payload.entries.count,
                    currentDocumentName: "Removal signature rejected"
                        .localizedUI
                )
            )
            return untrustedBatesBatchReport(
                receipt,
                status: .invalid,
                detail:
                    "The Bates removal payload, public key, or signature changed."
            )
        }
        let localKeyID = try? officeDeliverySigningKeyID()
        let trustedSigner = (
            try? loadOfficeTrustedSigners()
        )?.first {
            $0.keyID == calculatedKeyID
                && $0.publicKeyBase64
                    == signature.publicKeyBase64
        }
        let trustStatus: PDFOfficeSignerTrustStatus
        if localKeyID == calculatedKeyID {
            trustStatus = .thisDevice
        } else if trustedSigner != nil {
            trustStatus = .trusted
        } else {
            trustStatus = .unknown
        }

        let records = try loadIndex()
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var items: [PDFBatesBatchReceiptVerificationItem] = []
        items.reserveCapacity(payload.entries.count)
        let removalByRecordID = Dictionary(
            uniqueKeysWithValues: (
                receipt.removal?.payload.entries ?? []
            ).map { ($0.recordID, $0) }
        )
        for (offset, entry) in payload.entries.enumerated() {
            try Task.checkCancellation()
            await progress(
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receipt.id,
                    completedDocumentCount: offset,
                    totalDocumentCount: payload.entries.count,
                    currentDocumentName: entry.displayName
                )
            )
            guard let record = recordsByID[entry.recordID] else {
                items.append(
                    PDFBatesBatchReceiptVerificationItem(
                        entry: entry,
                        status: .missing,
                        actualRevisionID: nil,
                        actualSHA256: nil
                    )
                )
                await progress(
                    PDFBatesBatchReceiptVerificationProgress(
                        receiptID: receipt.id,
                        completedDocumentCount: offset + 1,
                        totalDocumentCount: payload.entries.count,
                        currentDocumentName: entry.displayName
                    )
                )
                continue
            }
            let documentURL = url(for: record)
            guard fileManager.fileExists(atPath: documentURL.path),
                  let fingerprint = try? fileFingerprint(
                      at: documentURL
                  )
            else {
                items.append(
                    PDFBatesBatchReceiptVerificationItem(
                        entry: entry,
                        status: .missing,
                        actualRevisionID: record.contentRevisionID,
                        actualSHA256: nil
                    )
                )
                await progress(
                    PDFBatesBatchReceiptVerificationProgress(
                        receiptID: receipt.id,
                        completedDocumentCount: offset + 1,
                        totalDocumentCount: payload.entries.count,
                        currentDocumentName: entry.displayName
                    )
                )
                continue
            }
            let bytesMatch = fingerprint == entry.outputSHA256
            let revisionMatches =
                record.contentRevisionID == entry.outputRevisionID
            let removalEntry = removalByRecordID[entry.recordID]
            let removalBytesMatch =
                fingerprint == removalEntry?.clearedSHA256
            let removalRevisionMatches =
                record.contentRevisionID
                    == removalEntry?.clearedRevisionID
            let status: PDFBatesBatchEntryStatus
            if bytesMatch && revisionMatches {
                status = record.deletedAt == nil
                    ? .current
                    : .inTrash
            } else if removalBytesMatch && removalRevisionMatches {
                status = record.deletedAt == nil
                    ? .removed
                    : .inTrash
            } else {
                status = .changed
            }
            items.append(
                PDFBatesBatchReceiptVerificationItem(
                    entry: entry,
                    status: status,
                    actualRevisionID: record.contentRevisionID,
                    actualSHA256: fingerprint
                )
            )
            await progress(
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receipt.id,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: payload.entries.count,
                    currentDocumentName: entry.displayName
                )
            )
        }
        let attentionCount = items.filter {
            $0.status != .current && $0.status != .removed
        }.count
        let hasMixedRemovalState =
            items.contains { $0.status == .current }
                && items.contains { $0.status == .removed }
        return PDFBatesBatchReceiptVerificationReport(
            receiptID: receipt.id,
            checkedAt: Date(),
            signatureStatus: .verified,
            trustStatus: trustStatus,
            trustedSignerName: trustedSigner?.displayName,
            keyID: calculatedKeyID,
            items: items,
            detail: attentionCount == 0 && !hasMixedRemovalState
                ? (
                    receipt.removal == nil
                        ? "Signature, revisions, and PDF fingerprints match."
                        : "Numbering and removal signatures match the current PDFs."
                )
                : hasMixedRemovalState
                    ? "The batch contains both numbered and cleared PDFs."
                : AppLocalization.format(
                    "%lld referenced PDFs need attention.",
                    attentionCount
                )
        )
    }

    func inspectExternalBatesBatchReceipt(
        at sourceURL: URL,
        progress: @escaping @MainActor @Sendable (
            PDFBatesBatchReceiptVerificationProgress
        ) -> Void = { _ in }
    ) async throws -> PDFBatesBatchReceiptInspection {
        try Task.checkCancellation()
        let hasAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount
                <= PDFBatesBatchReceiptPayload.maximumHistoryBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath Bates JSON under 1 MB."
            )
        }
        let data = try Data(
            contentsOf: sourceURL,
            options: [.mappedIfSafe]
        )
        guard let receipt = try? JSONDecoder.paperPath.decode(
            PDFSignedBatesBatchReceipt.self,
            from: data
        ),
              receipt.payload.isStructurallyValid
        else {
            throw PaperPathError.insufficientSelection(
                "This JSON is not a supported PaperPath Bates receipt."
            )
        }
        let report = try await verifyBatesBatchReceipt(
            receipt,
            progress: progress
        )
        return PDFBatesBatchReceiptInspection(
            sourceFileName: String(
                sourceURL.lastPathComponent.prefix(160)
            ),
            receipt: receipt,
            report: report
        )
    }

    func retainExternalBatesBatchReceipt(
        _ receipt: PDFSignedBatesBatchReceipt
    ) async throws -> [PDFSignedBatesBatchReceipt] {
        let report = try await verifyBatesBatchReceipt(receipt)
        guard report.signatureStatus == .verified else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates receipt signature is not valid"
            )
        }
        var receipts = try loadBatesBatchReceipts()
        receipts.removeAll { $0.id == receipt.id }
        receipts.insert(receipt, at: 0)
        let retained = try saveBatesBatchReceipts(receipts)
        guard retained.contains(where: { $0.id == receipt.id }) else {
            throw PaperPathError.storageFailure(
                "The imported Bates receipt exceeds the local history limit."
            )
        }
        return retained
    }

    func matchExternalBatesPDFs(
        receipt: PDFSignedBatesBatchReceipt,
        candidateURLs: [URL],
        progress: @escaping @MainActor @Sendable (
            PDFBatesExternalMatchProgress
        ) -> Void = { _ in }
    ) async throws -> PDFBatesExternalMatchReport {
        try Task.checkCancellation()
        guard isValidBatesReceiptSignature(receipt) else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates receipt signature is not valid"
            )
        }
        let uniqueURLs = candidateURLs.reduce(into: [URL]()) {
            result,
            url in
            let standardized = url.standardizedFileURL
            if !result.contains(where: {
                $0.standardizedFileURL.path
                    == standardized.path
            }) {
                result.append(url)
            }
        }
        guard !uniqueURLs.isEmpty,
              uniqueURLs.count
                <= PDFBatesExternalMatchReport.maximumFileCount
        else {
            throw PaperPathError.insufficientSelection(
                "Choose between 1 and 64 PDF files."
            )
        }

        var sizes: [URL: Int64] = [:]
        var totalBytes: Int64 = 0
        for url in uniqueURLs {
            try Task.checkCancellation()
            let hasAccess =
                url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard url.pathExtension.lowercased() == "pdf",
                  values.isRegularFile == true,
                  let rawSize = values.fileSize
            else {
                throw PaperPathError.insufficientSelection(
                    "Every selected item must be a readable PDF file."
                )
            }
            let size = Int64(rawSize)
            guard size > 0,
                  size <= PDFBatesExternalMatchReport.maximumFileBytes
            else {
                throw PaperPathError.fileTooLarge
            }
            let (nextTotal, overflow) =
                totalBytes.addingReportingOverflow(size)
            guard !overflow,
                  nextTotal
                    <= PDFBatesExternalMatchReport.maximumBatchBytes
            else {
                throw PaperPathError.insufficientSelection(
                    "Match up to 8 GB of PDF files at a time."
                )
            }
            sizes[url] = size
            totalBytes = nextTotal
        }

        var candidates: [PDFBatesExternalCandidate] = []
        candidates.reserveCapacity(uniqueURLs.count)
        var completedBytes: Int64 = 0
        for (offset, url) in uniqueURLs.enumerated() {
            try Task.checkCancellation()
            guard let expectedSize = sizes[url] else {
                throw PaperPathError.unreadablePDF
            }
            let hasAccess =
                url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let fileName = String(
                url.lastPathComponent.prefix(160)
            )
            let fingerprint = try await externalFileFingerprint(
                at: url,
                expectedSize: expectedSize,
                receiptID: receipt.id,
                completedFileCount: offset,
                totalFileCount: uniqueURLs.count,
                baseProcessedBytes: completedBytes,
                totalBatchBytes: totalBytes,
                fileName: fileName,
                progress: progress
            )
            completedBytes += expectedSize
            candidates.append(
                PDFBatesExternalCandidate(
                    id: UUID(),
                    fileName: fileName,
                    byteCount: expectedSize,
                    sha256: fingerprint
                )
            )
            await progress(
                PDFBatesExternalMatchProgress(
                    receiptID: receipt.id,
                    completedFileCount: offset + 1,
                    totalFileCount: uniqueURLs.count,
                    processedBytes: completedBytes,
                    totalBytes: totalBytes,
                    currentFileName: fileName
                )
            )
        }

        let entries = receipt.payload.entries
        let removalByRecordID = Dictionary(
            uniqueKeysWithValues: (
                receipt.removal?.payload.entries ?? []
            ).map { ($0.recordID, $0) }
        )
        let recognizedHashes = Set(
            entries.flatMap {
                var hashes = [$0.outputSHA256, $0.sourceSHA256]
                if let cleared = removalByRecordID[$0.recordID]?
                    .clearedSHA256 {
                    hashes.append(cleared)
                }
                return hashes
            }
        )
        let ownersByHash = Dictionary(
            grouping: entries.flatMap { entry in
                var hashes = [
                    (entry.outputSHA256, entry.recordID),
                    (entry.sourceSHA256, entry.recordID)
                ]
                if let cleared = removalByRecordID[entry.recordID]?
                    .clearedSHA256 {
                    hashes.append((cleared, entry.recordID))
                }
                return hashes
            },
            by: { $0.0 }
        ).mapValues { pairs in
            Set(pairs.map(\.1))
        }

        let matches = entries.map { entry in
            let outputCandidates = candidates.filter {
                $0.sha256 == entry.outputSHA256
            }
            let sourceCandidates = candidates.filter {
                $0.sha256 == entry.sourceSHA256
            }
            let removedCandidates = candidates.filter {
                $0.sha256
                    == removalByRecordID[entry.recordID]?.clearedSHA256
            }
            let combined = Array(
                Dictionary(
                    uniqueKeysWithValues:
                        (
                            outputCandidates
                                + removedCandidates
                                + sourceCandidates
                        )
                            .map { ($0.id, $0) }
                ).values
            ).sorted { $0.fileName < $1.fileName }
            let outputOwnerCount =
                ownersByHash[entry.outputSHA256]?.count ?? 0
            let sourceOwnerCount =
                ownersByHash[entry.sourceSHA256]?.count ?? 0
            let removedOwnerCount = removalByRecordID[entry.recordID]
                .map { ownersByHash[$0.clearedSHA256]?.count ?? 0 }
                ?? 0
            let status: PDFBatesExternalEntryMatchStatus
            if outputCandidates.count == 1,
               sourceCandidates.isEmpty,
               removedCandidates.isEmpty,
               outputOwnerCount == 1 {
                status = .outputMatch
            } else if removedCandidates.count == 1,
                      outputCandidates.isEmpty,
                      sourceCandidates.isEmpty,
                      removedOwnerCount == 1 {
                status = .removedMatch
            } else if outputCandidates.isEmpty,
                      removedCandidates.isEmpty,
                      sourceCandidates.count == 1,
                      sourceOwnerCount == 1 {
                status = .sourceMatch
            } else if combined.isEmpty {
                status = .missing
            } else {
                status = .ambiguous
            }
            return PDFBatesExternalEntryMatch(
                entry: entry,
                status: status,
                candidates: combined
            )
        }
        let unrecognized = candidates.filter {
            !recognizedHashes.contains($0.sha256)
        }
        return PDFBatesExternalMatchReport(
            id: UUID(),
            receiptID: receipt.id,
            checkedAt: Date(),
            matches: matches,
            unrecognizedCandidates: unrecognized,
            totalCandidateCount: candidates.count,
            totalCandidateBytes: totalBytes
        )
    }

    func exportSignedBatesMatchReport(
        receipt: PDFSignedBatesBatchReceipt,
        report: PDFBatesExternalMatchReport
    ) throws -> URL {
        try Task.checkCancellation()
        guard isValidBatesReceiptSignature(receipt),
              report.receiptID == receipt.id
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates receipt signature is not valid"
            )
        }
        let payload = PDFBatesMatchReportPayload(
            schema: PDFBatesMatchReportPayload.schema,
            reportID: report.id,
            createdAt: report.checkedAt,
            receipt: receipt,
            report: report
        )
        guard payload.isStructurallyValid else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates match report is structurally invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalPayload = try JSONEncoder.paperPath.encode(
            payload
        )
        let signatureData = try privateKey.signature(
            for: canonicalPayload
        )
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let signedReport = PDFSignedBatesMatchReport(
            payload: payload,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKeyData
                ),
                publicKeyBase64:
                    publicKeyData.base64EncodedString(),
                signatureBase64:
                    signatureData.base64EncodedString()
            )
        )
        let encoder = JSONEncoder.paperPath
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(signedReport)
        guard data.count <= PDFBatesMatchReportPayload.maximumEncodedBytes
        else {
            throw PaperPathError.storageFailure(
                "The signed Bates match report exceeds 2 MB."
            )
        }
        try Task.checkCancellation()
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Bates-Match-\(report.id.uuidString.prefix(8)).json"
            )
        try writeProtectedData(data, to: fileURL)
        excludeFromBackup(fileURL)
        return fileURL
    }

    func inspectExternalBatesMatchReport(
        at sourceURL: URL
    ) throws -> PDFBatesMatchReportInspection {
        try Task.checkCancellation()
        let hasAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= PDFBatesMatchReportPayload.maximumEncodedBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath Bates match report under 2 MB."
            )
        }
        let data = try Data(
            contentsOf: sourceURL,
            options: [.mappedIfSafe]
        )
        guard let signedReport = try? JSONDecoder.paperPath.decode(
            PDFSignedBatesMatchReport.self,
            from: data
        ) else {
            throw PaperPathError.insufficientSelection(
                "This JSON is not a supported PaperPath Bates match report."
            )
        }
        let fileName = String(
            sourceURL.lastPathComponent.prefix(160)
        )
        let receiptSignatureStatus:
            PDFOfficeReportVerificationStatus =
                isValidBatesReceiptSignature(
                    signedReport.payload.receipt
                ) ? .verified : .invalid
        guard signedReport.payload.isStructurallyValid else {
            return PDFBatesMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .invalid,
                receiptSignatureStatus: receiptSignatureStatus,
                trustStatus: .invalid,
                trustedSignerName: nil,
                detail:
                    "The Bates match report structure or conclusions changed."
            )
        }
        guard receiptSignatureStatus == .verified else {
            return PDFBatesMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .invalid,
                receiptSignatureStatus: receiptSignatureStatus,
                trustStatus: .invalid,
                trustedSignerName: nil,
                detail:
                    "The embedded Bates receipt signature is invalid."
            )
        }

        let signature = signedReport.signature
        guard signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                  base64Encoded: signature.publicKeyBase64
              ),
              let signatureData = Data(
                  base64Encoded: signature.signatureBase64
              ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let canonicalPayload = try? JSONEncoder.paperPath.encode(
                  signedReport.payload
              )
        else {
            return PDFBatesMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .unsupported,
                receiptSignatureStatus: receiptSignatureStatus,
                trustStatus: .unsupported,
                trustedSignerName: nil,
                detail:
                    "The Bates match report uses an unsupported signing envelope."
            )
        }
        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: publicKeyData
        )
        guard calculatedKeyID == signature.keyID,
              publicKey.isValidSignature(
                  signatureData,
                  for: canonicalPayload
              )
        else {
            return PDFBatesMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .invalid,
                receiptSignatureStatus: receiptSignatureStatus,
                trustStatus: .invalid,
                trustedSignerName: nil,
                detail:
                    "The Bates match report payload, public key, or signature changed."
            )
        }

        let localKeyID = try? officeDeliverySigningKeyID()
        if localKeyID == calculatedKeyID {
            return PDFBatesMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .verified,
                receiptSignatureStatus: receiptSignatureStatus,
                trustStatus: .thisDevice,
                trustedSignerName: nil,
                detail:
                    "The report signature and embedded Bates receipt are valid."
            )
        }
        var trustedSigners = try loadOfficeTrustedSigners()
        if let index = trustedSigners.firstIndex(where: {
            $0.keyID == calculatedKeyID
                && $0.publicKeyBase64 == signature.publicKeyBase64
        }) {
            trustedSigners[index].lastVerifiedAt = Date()
            trustedSigners[index].verificationCount += 1
            try saveOfficeTrustedSigners(trustedSigners)
            return PDFBatesMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .verified,
                receiptSignatureStatus: receiptSignatureStatus,
                trustStatus: .trusted,
                trustedSignerName: trustedSigners[index].displayName,
                detail:
                    "The report signature and embedded Bates receipt are valid."
            )
        }
        return PDFBatesMatchReportInspection(
            sourceFileName: fileName,
            signedReport: signedReport,
            signatureStatus: .verified,
            receiptSignatureStatus: receiptSignatureStatus,
            trustStatus: .unknown,
            trustedSignerName: nil,
            detail:
                "The report is cryptographically valid, but its signer is not trusted on this device."
        )
    }

    func exportBatesBatchReceipt(
        receiptID: UUID
    ) throws -> URL {
        try Task.checkCancellation()
        guard let receipt = try loadBatesBatchReceipts()
            .first(where: { $0.id == receiptID })
        else {
            throw PaperPathError.storageFailure(
                "This Bates receipt is no longer available."
            )
        }
        let encoder = JSONEncoder.paperPath
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Bates-\(receipt.id.uuidString.prefix(8)).json"
            )
        try writeProtectedData(data, to: fileURL)
        excludeFromBackup(fileURL)
        return fileURL
    }

    func deleteBatesBatchReceipt(
        receiptID: UUID
    ) throws -> [PDFSignedBatesBatchReceipt] {
        var receipts = try loadBatesBatchReceipts()
        let previousCount = receipts.count
        receipts.removeAll { $0.id == receiptID }
        guard receipts.count != previousCount else {
            throw PaperPathError.storageFailure(
                "This Bates receipt is no longer available."
            )
        }
        return try saveBatesBatchReceipts(receipts)
    }

    func loadOfficeProductionQueue() throws
        -> PDFOfficeProductionQueue {
        try prepareDirectories()
        guard fileManager.fileExists(
            atPath: officeProductionQueueURL.path
        ) else {
            return PDFOfficeProductionQueue()
        }
        do {
            let data = try Data(contentsOf: officeProductionQueueURL)
            return try JSONDecoder.paperPath.decode(
                PDFOfficeProductionQueue.self,
                from: data
            )
        } catch {
            try? fileManager.removeItem(at: officeProductionQueueURL)
            return PDFOfficeProductionQueue()
        }
    }

    func saveOfficeProductionQueue(
        _ queue: PDFOfficeProductionQueue
    ) throws {
        try prepareDirectories()
        do {
            let data = try JSONEncoder.paperPath.encode(queue)
            try writeProtectedData(
                data,
                to: officeProductionQueueURL
            )
        } catch {
            throw PaperPathError.storageFailure(
                "The Office production queue could not be saved."
            )
        }
    }

    func clearOfficeProductionQueue() {
        guard fileManager.fileExists(
            atPath: officeProductionQueueURL.path
        ) else { return }
        try? fileManager.removeItem(at: officeProductionQueueURL)
    }

    func loadOfficeDeliveryPackages() throws
        -> [PDFOfficeDeliveryPackage] {
        try prepareDirectories()
        let packages: [PDFOfficeDeliveryPackage]
        if fileManager.fileExists(atPath: officeDeliveryIndexURL.path),
           let data = try? Data(contentsOf: officeDeliveryIndexURL),
           let decoded = try? JSONDecoder.paperPath.decode(
                [PDFOfficeDeliveryPackage].self,
                from: data
           ) {
            packages = decoded
        } else {
            packages = []
        }

        var valid: [PDFOfficeDeliveryPackage] = []
        for package in packages {
            guard !package.isExpired,
                  let archiveFileName = package.archiveFileName,
                  let reportFileName = package.reportFileName,
                  isSafeOfficeDeliveryFileName(archiveFileName),
                  isSafeOfficeDeliveryFileName(reportFileName)
            else {
                removeOfficeDeliveryFiles(package)
                continue
            }
            let archiveURL = officeDeliveriesURL
                .appendingPathComponent(archiveFileName)
            let reportURL = officeDeliveriesURL
                .appendingPathComponent(reportFileName)
            guard fileManager.fileExists(atPath: archiveURL.path),
                  fileManager.fileExists(atPath: reportURL.path)
            else {
                removeOfficeDeliveryFiles(package)
                continue
            }
            valid.append(package)
        }
        valid = boundedOfficeDeliveryPackages(valid)
        if valid != packages {
            try saveOfficeDeliveryPackages(valid)
        }
        return valid.sorted { $0.createdAt > $1.createdAt }
    }

    func officeDeliverySigningKeyID() throws -> String {
        let key = try officeDeliverySigningPrivateKey()
        return officeDeliverySigningKeyID(
            publicKeyData: key.publicKey.rawRepresentation
        )
    }

    func officeDeliverySigningIdentityCard() throws
        -> PDFOfficeSignerIdentityCard {
        let key = try officeDeliverySigningPrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        return PDFOfficeSignerIdentityCard(
            schema: "PaperPath Signing Identity V1",
            keyID: officeDeliverySigningKeyID(
                publicKeyData: publicKey
            ),
            publicKeyBase64: publicKey.base64EncodedString(),
            generatedAt: Date()
        )
    }

    func makeOfficeDeliverySigningIdentityCardFile() throws
        -> URL {
        let card = try officeDeliverySigningIdentityCard()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Signing-Identity-\(card.keyID).json"
            )
        try? fileManager.removeItem(at: url)
        let data = try JSONEncoder.paperPath.encode(card)
        try writeProtectedData(data, to: url)
        return url
    }

    func parseOfficeSignerIdentityPayload(
        _ payload: String
    ) throws -> PDFOfficeSignerIdentityCard {
        let components = payload.split(
            separator: ":",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0] == "paperpath-signer",
              components[1] == "v1"
        else {
            throw PaperPathError.insufficientSelection(
                "This QR code is not a PaperPath signing identity."
            )
        }
        let card = PDFOfficeSignerIdentityCard(
            schema: "PaperPath Signing Identity V1",
            keyID: String(components[2]),
            publicKeyBase64: String(components[3]),
            generatedAt: Date()
        )
        try validateOfficeSignerIdentityCard(card)
        return card
    }

    func loadOfficeSignerIdentityCard(
        at sourceURL: URL
    ) throws -> PDFOfficeSignerIdentityCard {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= 64 * 1_024
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a PaperPath identity card under 64 KB."
            )
        }
        let data = try Data(contentsOf: sourceURL)
        let card = try JSONDecoder.paperPath.decode(
            PDFOfficeSignerIdentityCard.self,
            from: data
        )
        try validateOfficeSignerIdentityCard(card)
        return card
    }

    func loadOfficeTrustedSigners() throws
        -> [PDFOfficeTrustedSigner] {
        try prepareDirectories()
        guard fileManager.fileExists(
            atPath: officeTrustedSignersURL.path
        ) else { return [] }
        let decoded: [PDFOfficeTrustedSigner]
        do {
            let data = try Data(contentsOf: officeTrustedSignersURL)
            decoded = try JSONDecoder.paperPath.decode(
                [PDFOfficeTrustedSigner].self,
                from: data
            )
        } catch {
            try? fileManager.removeItem(at: officeTrustedSignersURL)
            return []
        }
        return decoded.filter { signer in
            guard let publicKey = Data(
                base64Encoded: signer.publicKeyBase64
            ) else { return false }
            return officeDeliverySigningKeyID(
                publicKeyData: publicKey
            ) == signer.keyID
        }
        .sorted { $0.lastVerifiedAt > $1.lastVerifiedAt }
        .prefix(24)
        .map { $0 }
    }

    func trustOfficeReportSigner(
        _ verification: PDFOfficeReportVerificationResult
    ) throws -> [PDFOfficeTrustedSigner] {
        guard verification.canTrustSigner,
              let keyID = verification.keyID,
              let publicKeyBase64 = verification.publicKeyBase64
        else {
            throw PaperPathError.insufficientSelection(
                "Only a valid unknown signer can be trusted."
            )
        }
        var signers = try loadOfficeTrustedSigners()
        if let existing = signers.first(
            where: { $0.keyID == keyID }
        ),
           existing.publicKeyBase64 != publicKeyBase64 {
            throw PaperPathError.outputVerificationFailed(
                "the signer Key ID conflicts with a different public key"
            )
        }
        let now = Date()
        let signer = PDFOfficeTrustedSigner(
            keyID: keyID,
            publicKeyBase64: publicKeyBase64,
            displayName: "Signer \(keyID.prefix(8))",
            trustedAt: now,
            lastVerifiedAt: now,
            verificationCount: 1,
            note: nil
        )
        signers.removeAll { $0.keyID == keyID }
        signers.insert(signer, at: 0)
        signers = Array(signers.prefix(24))
        try saveOfficeTrustedSigners(signers)
        return signers
    }

    func trustOfficeSignerIdentity(
        _ card: PDFOfficeSignerIdentityCard
    ) throws -> [PDFOfficeTrustedSigner] {
        try validateOfficeSignerIdentityCard(card)
        let localKeyID = try officeDeliverySigningKeyID()
        guard card.keyID != localKeyID else {
            throw PaperPathError.insufficientSelection(
                "This identity belongs to this device."
            )
        }
        var signers = try loadOfficeTrustedSigners()
        if let existing = signers.first(
            where: { $0.keyID == card.keyID }
        ) {
            guard existing.publicKeyBase64 == card.publicKeyBase64 else {
                throw PaperPathError.outputVerificationFailed(
                    "the signer Key ID conflicts with a different public key"
                )
            }
            return signers
        }
        let now = Date()
        signers.insert(
            PDFOfficeTrustedSigner(
                keyID: card.keyID,
                publicKeyBase64: card.publicKeyBase64,
                displayName: "Signer \(card.keyID.prefix(8))",
                trustedAt: now,
                lastVerifiedAt: now,
                verificationCount: 0,
                note: nil
            ),
            at: 0
        )
        signers = Array(signers.prefix(24))
        try saveOfficeTrustedSigners(signers)
        return signers
    }

    func updateOfficeTrustedSigner(
        keyID: String,
        displayName: String,
        note: String
    ) throws -> [PDFOfficeTrustedSigner] {
        var signers = try loadOfficeTrustedSigners()
        guard let index = signers.firstIndex(
            where: { $0.keyID == keyID }
        ) else {
            throw PaperPathError.insufficientSelection(
                "This trusted signer is no longer available."
            )
        }
        let cleanName = String(
            displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(64)
        )
        let cleanNote = String(
            note
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240)
        )
        signers[index].displayName = cleanName.isEmpty
            ? "Signer \(keyID.prefix(8))"
            : cleanName
        signers[index].note = cleanNote.isEmpty ? nil : cleanNote
        try saveOfficeTrustedSigners(signers)
        return signers
    }

    func removeOfficeTrustedSigner(
        _ keyID: String
    ) throws -> [PDFOfficeTrustedSigner] {
        var signers = try loadOfficeTrustedSigners()
        signers.removeAll { $0.keyID == keyID }
        try saveOfficeTrustedSigners(signers)
        return signers
    }

    func signOfficeDeliveryPayload(
        _ payload: PDFOfficeVerificationPayload
    ) throws -> PDFOfficeSignedVerificationReport {
        guard payload.isStructurallyValid else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report inventory is invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalPayload = try JSONEncoder.paperPath.encode(payload)
        let signature = try privateKey.signature(
            for: canonicalPayload
        )
        let publicKey = privateKey.publicKey.rawRepresentation
        return PDFOfficeSignedVerificationReport(
            payload: payload,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKey
                ),
                publicKeyBase64: publicKey.base64EncodedString(),
                signatureBase64: signature.base64EncodedString()
            )
        )
    }

    func signVersionArchiveManifest(
        _ manifest: PDFVersionArchiveManifest
    ) throws -> PDFSignedVersionArchiveManifest {
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalManifest = try JSONEncoder.paperPath.encode(
            manifest
        )
        let signature = try privateKey.signature(
            for: canonicalManifest
        )
        let publicKey = privateKey.publicKey.rawRepresentation
        return PDFSignedVersionArchiveManifest(
            manifest: manifest,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKey
                ),
                publicKeyBase64: publicKey.base64EncodedString(),
                signatureBase64: signature.base64EncodedString()
            )
        )
    }

    func signedDeliveryPackageManifest(
        for record: DocumentRecord,
        artifactFileName: String,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> PDFSignedDeliveryPackageManifest {
        try prepareDirectories()
        try Task.checkCancellation()
        guard let receipt = record.deliveryReceipt,
              receipt.isVerified,
              record.hasCurrentDeliveryReceipt
        else {
            throw PaperPathError.outputVerificationFailed(
                "the delivery receipt no longer matches this PDF"
            )
        }

        let sourceURL = url(for: record)
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              let rawFileSize = values.fileSize,
              rawFileSize > 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let fileSize = Int64(rawFileSize)
        guard fileSize <= PDFDeliveryPackageManifest
            .maximumArtifactBytes
        else {
            throw PaperPathError.fileTooLarge
        }
        guard fileSize == receipt.outputByteCount else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF byte count changed after verification"
            )
        }
        if let available = availableCapacity(rootURL) {
            let required = saturatingAdd(
                fileSize,
                16 * 1_024 * 1_024
            )
            guard available >= required else {
                throw PaperPathError.insufficientStorage
            }
        }

        let fingerprint = try fileFingerprint(
            at: sourceURL
        ) { processedBytes, totalBytes in
            progress(
                PDFByteProgressUpdate(
                    stage: .checksumming,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    completedUnitCount:
                        processedBytes >= totalBytes ? 1 : 0,
                    totalUnitCount: 1,
                    currentUnitName: artifactFileName
                )
            )
        }
        guard fingerprint.caseInsensitiveCompare(receipt.sha256)
                == .orderedSame,
              fingerprint.caseInsensitiveCompare(
                record.contentFingerprint ?? ""
              ) == .orderedSame
        else {
            throw PaperPathError.outputVerificationFailed(
                "the PDF fingerprint changed after verification"
            )
        }

        let manifest = PDFDeliveryPackageManifest(
            artifactFileName: artifactFileName,
            record: record,
            receipt: receipt
        )
        return try signDeliveryPackageManifest(manifest)
    }

    func signDeliveryPackageManifest(
        _ manifest: PDFDeliveryPackageManifest
    ) throws -> PDFSignedDeliveryPackageManifest {
        guard manifest.isStructurallyValid else {
            throw PaperPathError.outputVerificationFailed(
                "the delivery package manifest is invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalManifest = try JSONEncoder.paperPath.encode(
            manifest
        )
        let signature = try privateKey.signature(
            for: canonicalManifest
        )
        let publicKey = privateKey.publicKey.rawRepresentation
        return PDFSignedDeliveryPackageManifest(
            manifest: manifest,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKey
                ),
                publicKeyBase64: publicKey.base64EncodedString(),
                signatureBase64: signature.base64EncodedString()
            )
        )
    }

    func resolveVersionArchiveTrust(
        _ report: PDFVersionArchiveVerificationReport
    ) throws -> PDFVersionArchiveVerificationReport {
        guard report.hasValidSourceSignature,
              let keyID = report.signerKeyID,
              let publicKeyBase64 = report.signerPublicKeyBase64
        else {
            return report.resolvingTrust(
                report.hasInvalidSourceSignature
                    ? .invalid
                    : .unsupported,
                trustedSignerName: nil
            )
        }
        let localIdentity = try officeDeliverySigningIdentityCard()
        if localIdentity.keyID == keyID,
           localIdentity.publicKeyBase64 == publicKeyBase64 {
            return report.resolvingTrust(
                .thisDevice,
                trustedSignerName: nil
            )
        }

        var trustedSigners = try loadOfficeTrustedSigners()
        guard let index = trustedSigners.firstIndex(
            where: {
                $0.keyID == keyID
                    && $0.publicKeyBase64 == publicKeyBase64
            }
        ) else {
            return report.resolvingTrust(
                .unknown,
                trustedSignerName: nil
            )
        }
        trustedSigners[index].lastVerifiedAt = Date()
        trustedSigners[index].verificationCount += 1
        try saveOfficeTrustedSigners(trustedSigners)
        return report.resolvingTrust(
            .trusted,
            trustedSignerName: trustedSigners[index].displayName
        )
    }

    func trustVersionArchiveSigner(
        _ report: PDFVersionArchiveVerificationReport
    ) throws -> [PDFOfficeTrustedSigner] {
        guard report.canTrustSigner else {
            throw PaperPathError.insufficientSelection(
                "Only a valid unknown signer can be trusted."
            )
        }
        let bridge = PDFOfficeReportVerificationResult(
            status: report.signatureStatus,
            packageID: nil,
            keyID: report.signerKeyID,
            sourceCount: Set(
                report.items.map(\.id)
            ).count,
            outputCount: report.items.count,
            createdAt: report.archiveCreatedAt,
            detail: report.signatureDetail,
            publicKeyBase64: report.signerPublicKeyBase64,
            trustStatus: report.trustStatus,
            trustedSignerName: report.trustedSignerName
        )
        return try trustOfficeReportSigner(bridge)
    }

    func resolveDeliveryPackageTrust(
        _ report: PDFDeliveryPackageVerificationReport
    ) throws -> PDFDeliveryPackageVerificationReport {
        guard report.hasValidSourceSignature,
              report.integrityStatus == .verified,
              let keyID = report.signerKeyID,
              let publicKeyBase64 = report.signerPublicKeyBase64
        else {
            return report.resolvingTrust(
                report.hasInvalidSourceSignature
                    ? .invalid
                    : (
                        report.hasValidSourceSignature
                            ? .unknown
                            : .unsupported
                    ),
                trustedSignerName: nil
            )
        }
        let localIdentity = try officeDeliverySigningIdentityCard()
        if localIdentity.keyID == keyID,
           localIdentity.publicKeyBase64 == publicKeyBase64 {
            return report.resolvingTrust(
                .thisDevice,
                trustedSignerName: nil
            )
        }

        var trustedSigners = try loadOfficeTrustedSigners()
        guard let index = trustedSigners.firstIndex(
            where: {
                $0.keyID == keyID
                    && $0.publicKeyBase64 == publicKeyBase64
            }
        ) else {
            return report.resolvingTrust(
                .unknown,
                trustedSignerName: nil
            )
        }
        trustedSigners[index].lastVerifiedAt = Date()
        trustedSigners[index].verificationCount += 1
        try saveOfficeTrustedSigners(trustedSigners)
        return report.resolvingTrust(
            .trusted,
            trustedSignerName: trustedSigners[index].displayName
        )
    }

    func trustDeliveryPackageSigner(
        _ report: PDFDeliveryPackageVerificationReport
    ) throws -> [PDFOfficeTrustedSigner] {
        guard report.canTrustSigner else {
            throw PaperPathError.insufficientSelection(
                "Only a valid unknown signer can be trusted."
            )
        }
        let bridge = PDFOfficeReportVerificationResult(
            status: report.signatureStatus,
            packageID: report.packageID,
            keyID: report.signerKeyID,
            sourceCount: 1,
            outputCount: 1,
            createdAt: report.packageCreatedAt,
            detail: report.signatureDetail,
            publicKeyBase64: report.signerPublicKeyBase64,
            trustStatus: report.trustStatus,
            trustedSignerName: report.trustedSignerName
        )
        return try trustOfficeReportSigner(bridge)
    }

    func verifyOfficeDeliveryReport(
        at sourceURL: URL
    ) throws -> PDFOfficeReportVerificationResult {
        try Task.checkCancellation()
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 5 * 1_024 * 1_024
        else {
            return PDFOfficeReportVerificationResult(
                status: .unsupported,
                packageID: nil,
                keyID: nil,
                sourceCount: 0,
                outputCount: 0,
                createdAt: nil,
                detail:
                    "Choose a PaperPath verification report under 5 MB.",
                publicKeyBase64: nil,
                trustStatus: .unsupported,
                trustedSignerName: nil
            )
        }
        let data = try Data(
            contentsOf: sourceURL,
            options: [.mappedIfSafe]
        )
        guard let report = try? JSONDecoder.paperPath.decode(
            PDFOfficeSignedVerificationReport.self,
            from: data
        ) else {
            return PDFOfficeReportVerificationResult(
                status: .unsupported,
                packageID: nil,
                keyID: nil,
                sourceCount: 0,
                outputCount: 0,
                createdAt: nil,
                detail:
                    "This JSON file is not a signed PaperPath report.",
                publicKeyBase64: nil,
                trustStatus: .unsupported,
                trustedSignerName: nil
            )
        }
        guard report.payload.isStructurallyValid else {
            return PDFOfficeReportVerificationResult(
                status: .invalid,
                packageID: report.payload.packageID,
                keyID: report.signature.keyID,
                sourceCount: Set(
                    report.payload.files.map(\.sourceRecordID)
                ).count,
                outputCount: report.payload.files.count,
                createdAt: report.payload.createdAt,
                detail:
                    "The report structure, file metadata, or hash inventory is invalid.",
                publicKeyBase64:
                    report.signature.publicKeyBase64,
                trustStatus: .invalid,
                trustedSignerName: nil,
                signedReport: report
            )
        }
        guard report.signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                base64Encoded: report.signature.publicKeyBase64
              ),
              let signatureData = Data(
                base64Encoded: report.signature.signatureBase64
              ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
              ),
              let canonicalPayload = try? JSONEncoder.paperPath
                .encode(report.payload)
        else {
            return PDFOfficeReportVerificationResult(
                status: .unsupported,
                packageID: report.payload.packageID,
                keyID: report.signature.keyID,
                sourceCount: Set(
                    report.payload.files.map(\.sourceRecordID)
                ).count,
                outputCount: report.payload.files.count,
                createdAt: report.payload.createdAt,
                detail:
                    "The report uses an unsupported signing envelope.",
                publicKeyBase64:
                    report.signature.publicKeyBase64,
                trustStatus: .unsupported,
                trustedSignerName: nil,
                signedReport: report
            )
        }

        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: publicKeyData
        )
        let valid = calculatedKeyID == report.signature.keyID
            && publicKey.isValidSignature(
                signatureData,
                for: canonicalPayload
            )
        var trustStatus: PDFOfficeSignerTrustStatus =
            valid ? .unknown : .invalid
        var trustedSignerName: String?
        if valid {
            let localKeyID = try? officeDeliverySigningKeyID()
            if localKeyID == calculatedKeyID {
                trustStatus = .thisDevice
            } else {
                var trustedSigners = try loadOfficeTrustedSigners()
                if let index = trustedSigners.firstIndex(
                    where: {
                        $0.keyID == calculatedKeyID
                            && $0.publicKeyBase64
                                == report.signature.publicKeyBase64
                    }
                ) {
                    trustStatus = .trusted
                    trustedSignerName =
                        trustedSigners[index].displayName
                    trustedSigners[index].lastVerifiedAt = Date()
                    trustedSigners[index].verificationCount += 1
                    try saveOfficeTrustedSigners(trustedSigners)
                }
            }
        }
        return PDFOfficeReportVerificationResult(
            status: valid ? .verified : .invalid,
            packageID: report.payload.packageID,
            keyID: report.signature.keyID,
            sourceCount: Set(
                report.payload.files.map(\.sourceRecordID)
            ).count,
            outputCount: report.payload.files.count,
            createdAt: report.payload.createdAt,
            detail: valid
                ? "The report payload matches its Ed25519 signature."
                : "The report payload, public key, or signature was changed.",
            publicKeyBase64: report.signature.publicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            signedReport: report
        )
    }

    func matchExternalOfficeDeliveryFiles(
        report: PDFOfficeSignedVerificationReport,
        candidateURLs: [URL],
        progress: @escaping @MainActor @Sendable (
            PDFOfficeExternalMatchProgress
        ) -> Void = { _ in }
    ) async throws -> PDFOfficeExternalMatchReport {
        try Task.checkCancellation()
        guard isValidOfficeDeliveryReportSignature(report) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report signature is not valid"
            )
        }
        let uniqueURLs = candidateURLs.reduce(into: [URL]()) {
            result,
            url in
            let standardized = url.standardizedFileURL
            if !result.contains(where: {
                $0.standardizedFileURL.path == standardized.path
            }) {
                result.append(url)
            }
        }
        guard !uniqueURLs.isEmpty,
              uniqueURLs.count
                <= PDFOfficeExternalMatchReport.maximumFileCount
        else {
            throw PaperPathError.insufficientSelection(
                "Choose between 1 and 128 delivery files."
            )
        }
        let expectedExtensions = Set(
            report.payload.files.map {
                $0.format.fileExtension.lowercased()
            }
        )
        var sizes: [URL: Int64] = [:]
        var totalBytes: Int64 = 0
        for url in uniqueURLs {
            try Task.checkCancellation()
            let hasAccess =
                url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            let fileExtension = url.pathExtension.lowercased()
            guard expectedExtensions.contains(fileExtension),
                  values.isRegularFile == true,
                  let rawSize = values.fileSize
            else {
                throw PaperPathError.insufficientSelection(
                    "Every selected item must use a file format declared by this delivery report."
                )
            }
            let size = Int64(rawSize)
            guard size > 0,
                  size
                    <= PDFOfficeExternalMatchReport.maximumFileBytes
            else {
                throw PaperPathError.fileTooLarge
            }
            let (nextTotal, overflow) =
                totalBytes.addingReportingOverflow(size)
            guard !overflow,
                  nextTotal
                    <= PDFOfficeExternalMatchReport.maximumBatchBytes
            else {
                throw PaperPathError.insufficientSelection(
                    "Match up to 8 GB of delivery files at a time."
                )
            }
            sizes[url] = size
            totalBytes = nextTotal
        }

        var candidates: [PDFOfficeExternalCandidate] = []
        candidates.reserveCapacity(uniqueURLs.count)
        var completedBytes: Int64 = 0
        for (offset, url) in uniqueURLs.enumerated() {
            try Task.checkCancellation()
            guard let expectedSize = sizes[url] else {
                throw PaperPathError.storageFailure(
                    "A selected delivery file could not be read."
                )
            }
            let hasAccess =
                url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let fileName = boundedExternalDisplayName(
                url.lastPathComponent,
                maximumLength: 180
            )
            let fingerprint =
                try await externalOfficeFileFingerprint(
                    at: url,
                    expectedSize: expectedSize,
                    packageID: report.payload.packageID,
                    completedFileCount: offset,
                    totalFileCount: uniqueURLs.count,
                    baseProcessedBytes: completedBytes,
                    totalBatchBytes: totalBytes,
                    fileName: fileName,
                    progress: progress
                )
            completedBytes += expectedSize
            candidates.append(
                PDFOfficeExternalCandidate(
                    id: UUID(),
                    fileName: fileName,
                    fileExtension: url.pathExtension.lowercased(),
                    byteCount: expectedSize,
                    sha256: fingerprint
                )
            )
            await progress(
                PDFOfficeExternalMatchProgress(
                    packageID: report.payload.packageID,
                    completedFileCount: offset + 1,
                    totalFileCount: uniqueURLs.count,
                    processedBytes: completedBytes,
                    totalBytes: totalBytes,
                    currentFileName: fileName
                )
            )
        }

        let entries = report.payload.files
        let recognizedHashes = Set(entries.map(\.sha256))
        let ownersByHash = Dictionary(
            grouping: entries,
            by: \.sha256
        ).mapValues { Set($0.map(\.receiptID)) }
        let matches = entries.map { entry in
            let hashCandidates = candidates.filter {
                $0.sha256 == entry.sha256
            }
            let exactCandidates = hashCandidates.filter {
                $0.byteCount == entry.byteCount
            }
            let status: PDFOfficeExternalMatchStatus
            if hashCandidates.count == 1,
               ownersByHash[entry.sha256]?.count == 1 {
                status = exactCandidates.count == 1
                    ? .exact
                    : .inconsistent
            } else if hashCandidates.isEmpty {
                status = .missing
            } else {
                status = .ambiguous
            }
            return PDFOfficeExternalEntryMatch(
                entry: entry,
                status: status,
                candidates: hashCandidates.sorted {
                    $0.fileName.localizedStandardCompare(
                        $1.fileName
                    ) == .orderedAscending
                }
            )
        }
        let extras = candidates.filter {
            !recognizedHashes.contains($0.sha256)
        }.sorted {
            $0.fileName.localizedStandardCompare($1.fileName)
                == .orderedAscending
        }
        return PDFOfficeExternalMatchReport(
            id: UUID(),
            packageID: report.payload.packageID,
            checkedAt: Date(),
            matches: matches,
            extraCandidates: extras,
            totalCandidateCount: candidates.count,
            totalCandidateBytes: totalBytes
        )
    }

    func exportSignedOfficeMatchReport(
        deliveryReport: PDFOfficeSignedVerificationReport,
        matchReport: PDFOfficeExternalMatchReport
    ) throws -> URL {
        try Task.checkCancellation()
        guard isValidOfficeDeliveryReportSignature(deliveryReport),
              matchReport.packageID
                == deliveryReport.payload.packageID
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report signature is not valid"
            )
        }
        let payload = PDFOfficeMatchReportPayload(
            schema: PDFOfficeMatchReportPayload.schema,
            reportID: matchReport.id,
            createdAt: matchReport.checkedAt,
            deliveryReport: deliveryReport,
            matchReport: matchReport
        )
        guard payload.isStructurallyValid else {
            throw PaperPathError.outputVerificationFailed(
                "the Office match report is structurally invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalPayload = try JSONEncoder.paperPath.encode(
            payload
        )
        let signatureData = try privateKey.signature(
            for: canonicalPayload
        )
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let signedReport = PDFSignedOfficeMatchReport(
            payload: payload,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKeyData
                ),
                publicKeyBase64:
                    publicKeyData.base64EncodedString(),
                signatureBase64:
                    signatureData.base64EncodedString()
            )
        )
        let encoder = JSONEncoder.paperPath
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(signedReport)
        guard data.count
                <= PDFOfficeMatchReportPayload.maximumEncodedBytes
        else {
            throw PaperPathError.storageFailure(
                "The signed Office match report exceeds 4 MB."
            )
        }
        try Task.checkCancellation()
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Delivery-Match-\(matchReport.id.uuidString.prefix(8)).json"
            )
        try writeProtectedData(data, to: fileURL)
        excludeFromBackup(fileURL)
        return fileURL
    }

    func inspectExternalOfficeMatchReport(
        at sourceURL: URL
    ) throws -> PDFOfficeMatchReportInspection {
        try Task.checkCancellation()
        let hasAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount
                <= PDFOfficeMatchReportPayload.maximumEncodedBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath Delivery match report under 4 MB."
            )
        }
        let data = try Data(
            contentsOf: sourceURL,
            options: [.mappedIfSafe]
        )
        guard let signedReport = try? JSONDecoder.paperPath.decode(
            PDFSignedOfficeMatchReport.self,
            from: data
        ) else {
            throw PaperPathError.insufficientSelection(
                "This JSON is not a supported PaperPath Delivery match report."
            )
        }
        let fileName = String(
            sourceURL.lastPathComponent.prefix(180)
        )
        let deliveryIsValid = isValidOfficeDeliveryReportSignature(
            signedReport.payload.deliveryReport
        )
        let deliverySignatureStatus:
            PDFOfficeReportVerificationStatus =
                deliveryIsValid ? .verified : .invalid
        let localKeyID = try? officeDeliverySigningKeyID()
        let trustedSigners = try loadOfficeTrustedSigners()
        let deliveryTrust = officeSignerTrust(
            for: signedReport.payload.deliveryReport.signature,
            signatureIsValid: deliveryIsValid,
            localKeyID: localKeyID,
            trustedSigners: trustedSigners
        )
        guard signedReport.payload.isStructurallyValid else {
            return PDFOfficeMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .invalid,
                deliverySignatureStatus:
                    deliverySignatureStatus,
                trustStatus: .invalid,
                trustedSignerName: nil,
                deliveryTrustStatus: deliveryTrust.status,
                deliveryTrustedSignerName: deliveryTrust.name,
                detail:
                    "The Delivery match report structure or conclusions changed."
            )
        }

        let signature = signedReport.signature
        guard signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                  base64Encoded: signature.publicKeyBase64
              ),
              let signatureData = Data(
                  base64Encoded: signature.signatureBase64
              ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let canonicalPayload = try? JSONEncoder.paperPath.encode(
                  signedReport.payload
              )
        else {
            return PDFOfficeMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .unsupported,
                deliverySignatureStatus:
                    deliverySignatureStatus,
                trustStatus: .unsupported,
                trustedSignerName: nil,
                deliveryTrustStatus: deliveryTrust.status,
                deliveryTrustedSignerName: deliveryTrust.name,
                detail:
                    "The Delivery match report uses an unsupported signing envelope."
            )
        }
        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: publicKeyData
        )
        guard calculatedKeyID == signature.keyID,
              publicKey.isValidSignature(
                  signatureData,
                  for: canonicalPayload
              )
        else {
            return PDFOfficeMatchReportInspection(
                sourceFileName: fileName,
                signedReport: signedReport,
                signatureStatus: .invalid,
                deliverySignatureStatus:
                    deliverySignatureStatus,
                trustStatus: .invalid,
                trustedSignerName: nil,
                deliveryTrustStatus: deliveryTrust.status,
                deliveryTrustedSignerName: deliveryTrust.name,
                detail:
                    "The Delivery match report payload, public key, or signature changed."
            )
        }

        var mutableTrustedSigners = trustedSigners
        let outerTrust = officeSignerTrust(
            for: signature,
            signatureIsValid: true,
            localKeyID: localKeyID,
            trustedSigners: mutableTrustedSigners
        )
        if outerTrust.status == .trusted,
           let index = mutableTrustedSigners.firstIndex(where: {
               $0.keyID == signature.keyID
                   && $0.publicKeyBase64
                    == signature.publicKeyBase64
           }) {
            mutableTrustedSigners[index].lastVerifiedAt = Date()
            mutableTrustedSigners[index].verificationCount += 1
            try saveOfficeTrustedSigners(mutableTrustedSigners)
        }
        let detail: String
        if !deliveryIsValid {
            detail =
                "The embedded Delivery report signature is invalid."
        } else if outerTrust.status == .unknown {
            detail =
                "The report is cryptographically valid, but its signer is not trusted on this device."
        } else {
            detail =
                "The match report and embedded Delivery report signatures are valid."
        }
        return PDFOfficeMatchReportInspection(
            sourceFileName: fileName,
            signedReport: signedReport,
            signatureStatus: .verified,
            deliverySignatureStatus: deliverySignatureStatus,
            trustStatus: outerTrust.status,
            trustedSignerName: outerTrust.name,
            deliveryTrustStatus: deliveryTrust.status,
            deliveryTrustedSignerName: deliveryTrust.name,
            detail: detail
        )
    }

    func retainOfficeDeliveryPackage(
        _ package: PDFOfficeDeliveryPackage,
        archiveURL: URL,
        reportURL: URL
    ) throws -> (PDFOfficeDeliveryPackage, URL, URL) {
        try prepareDirectories()
        try ensureCapacity(for: archiveURL)
        try Task.checkCancellation()

        let archiveFileName = "\(package.id.uuidString).zip"
        let reportFileName =
            "\(package.id.uuidString)-verification.json"
        let destinationArchive = officeDeliveriesURL
            .appendingPathComponent(archiveFileName)
        let destinationReport = officeDeliveriesURL
            .appendingPathComponent(reportFileName)
        if let existing = try loadOfficeDeliveryPackages().first(
            where: { $0.id == package.id }
        ) {
            let urls = try officeDeliveryPackageURLs(for: existing)
            return (existing, urls.archive, urls.report)
        }
        guard !fileManager.fileExists(
            atPath: destinationArchive.path
        ),
        !fileManager.fileExists(atPath: destinationReport.path)
        else {
            throw PaperPathError.storageFailure(
                "An Office delivery package with this identifier already exists."
            )
        }
        let stagingArchive = officeDeliveriesURL
            .appendingPathComponent(".staging-\(UUID().uuidString).zip")
        let stagingReport = officeDeliveriesURL
            .appendingPathComponent(".staging-\(UUID().uuidString).json")
        var didPublishArchive = false
        var didPublishReport = false
        defer {
            try? fileManager.removeItem(at: stagingArchive)
            try? fileManager.removeItem(at: stagingReport)
        }

        do {
            try fileManager.copyItem(
                at: archiveURL,
                to: stagingArchive
            )
            try fileManager.copyItem(
                at: reportURL,
                to: stagingReport
            )
            try Task.checkCancellation()
            try requireFileProtection(to: stagingArchive)
            try requireFileProtection(to: stagingReport)
            try fileManager.moveItem(
                at: stagingArchive,
                to: destinationArchive
            )
            didPublishArchive = true
            try fileManager.moveItem(
                at: stagingReport,
                to: destinationReport
            )
            didPublishReport = true
            try requireFileProtection(to: destinationArchive)
            try requireFileProtection(to: destinationReport)

            let values = try destinationArchive.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office delivery package is incomplete"
                )
            }

            var retained = package
            retained.archiveFileName = archiveFileName
            retained.reportFileName = reportFileName
            retained.byteCount = Int64(size)
            retained.sha256 = try fileFingerprint(
                at: destinationArchive
            )
            retained.reportSHA256 = try fileFingerprint(
                at: destinationReport
            )
            var packages = try loadOfficeDeliveryPackages()
            packages.removeAll { $0.id == retained.id }
            packages.insert(retained, at: 0)
            packages = boundedOfficeDeliveryPackages(packages)
            try saveOfficeDeliveryPackages(packages)
            return (
                retained,
                destinationArchive,
                destinationReport
            )
        } catch {
            if didPublishArchive {
                try? fileManager.removeItem(at: destinationArchive)
            }
            if didPublishReport {
                try? fileManager.removeItem(at: destinationReport)
            }
            throw error
        }
    }

    func officeDeliveryPackageURLs(
        for package: PDFOfficeDeliveryPackage
    ) throws -> (archive: URL, report: URL) {
        guard !package.isExpired,
              let archiveFileName = package.archiveFileName,
              let reportFileName = package.reportFileName,
              let expectedFingerprint = package.sha256,
              let expectedReportFingerprint = package.reportSHA256,
              isSafeOfficeDeliveryFileName(archiveFileName),
              isSafeOfficeDeliveryFileName(reportFileName)
        else {
            throw PaperPathError.insufficientSelection(
                "This Office delivery package is no longer available."
            )
        }
        let archive = officeDeliveriesURL
            .appendingPathComponent(archiveFileName)
        let report = officeDeliveriesURL
            .appendingPathComponent(reportFileName)
        let values = try archive.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == package.byteCount,
              fileManager.fileExists(atPath: report.path),
              try fileFingerprint(at: archive) == expectedFingerprint,
              try fileFingerprint(at: report)
                == expectedReportFingerprint
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery package failed integrity verification"
            )
        }
        return (archive, report)
    }

    func setOfficeDeliveryPackagePinned(
        _ packageID: UUID,
        pinned: Bool
    ) throws -> [PDFOfficeDeliveryPackage] {
        var packages = try loadOfficeDeliveryPackages()
        guard let index = packages.firstIndex(
            where: { $0.id == packageID }
        ) else {
            throw PaperPathError.insufficientSelection(
                "This Office delivery package is no longer available."
            )
        }
        if pinned,
           packages[index].pinnedAt == nil,
           packages.filter(\.isPinned).count
                >= Self.maximumPinnedOfficeDeliveryPackages {
            throw PaperPathError.insufficientSelection(
                "Keep up to 4 Office delivery packages pinned."
            )
        }
        packages[index].pinnedAt = pinned ? Date() : nil
        if !pinned {
            packages[index].expiresAt = Calendar.current.date(
                byAdding: .day,
                value: 3,
                to: Date()
            ) ?? Date().addingTimeInterval(3 * 24 * 60 * 60)
        }
        packages = boundedOfficeDeliveryPackages(packages)
        try saveOfficeDeliveryPackages(packages)
        return packages
    }

    func deleteOfficeDeliveryPackage(
        _ packageID: UUID
    ) throws -> [PDFOfficeDeliveryPackage] {
        var packages = try loadOfficeDeliveryPackages()
        guard let package = packages.first(
            where: { $0.id == packageID }
        ) else { return packages }
        removeOfficeDeliveryFiles(package)
        packages.removeAll { $0.id == packageID }
        try saveOfficeDeliveryPackages(packages)
        return packages
    }

    func createVersionSnapshot(
        for record: DocumentRecord,
        label: String,
        preservingVersionID: UUID? = nil
    ) throws -> PDFVersionSnapshot {
        try prepareDirectories()
        let sourceURL = url(for: record)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PaperPathError.storageFailure(
                "The working copy is unavailable for versioning."
            )
        }
        let fingerprint = try fileFingerprint(at: sourceURL)
        let existing = try loadVersionIndex()
            .filter { $0.documentID == record.id }
            .sorted { $0.createdAt > $1.createdAt }
        if let latest = existing.first,
           latest.contentFingerprint == fingerprint,
           fileManager.fileExists(
               atPath: versionURL(for: latest).path
           ) {
            return latest
        }

        try ensureCapacity(for: sourceURL)
        let id = UUID()
        let documentDirectory = versionsURL.appendingPathComponent(
            record.id.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        try requireFileProtection(to: documentDirectory)
        excludeFromBackup(documentDirectory)

        let fileName = "\(record.id.uuidString)/\(id.uuidString).pdf"
        let destination = versionsURL.appendingPathComponent(fileName)
        let temporary = documentDirectory.appendingPathComponent(
            ".\(id.uuidString).pending"
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            try requireFileProtection(to: destination)
            guard try fileFingerprint(at: destination) == fingerprint else {
                throw PaperPathError.outputVerificationFailed(
                    "the recovery version did not match the working copy"
                )
            }
            let byteCount = (try? sourceURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize).map(Int64.init) ?? record.profile.byteCount
            let normalizedLabel = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = PDFVersionSnapshot(
                id: id,
                documentID: record.id,
                createdAt: Date(),
                label: String(
                    (
                        normalizedLabel.isEmpty
                            ? "Document edit"
                            : normalizedLabel
                    ).prefix(80)
                ),
                fileName: fileName,
                byteCount: byteCount,
                pageCount: record.profile.pageCount,
                contentRevisionID: record.contentRevisionID,
                contentFingerprint: fingerprint,
                bookmarkedPages: record.bookmarkedPages,
                bookmarkNames: record.bookmarkNames,
                lastPageIndex: record.lastPageIndex,
                milestoneName: nil,
                isPinned: nil,
                linkedDeliveryReceiptID:
                    record.deliveryReceipt?.id
            )
            let allVersions = try loadVersionIndex() + [snapshot]
            var preservedIDs: Set<UUID> = [snapshot.id]
            if let preservingVersionID {
                preservedIDs.insert(preservingVersionID)
            }
            let retention = retainedVersions(
                from: allVersions,
                preserving: preservedIDs
            )
            try saveVersionIndex(retention.kept)
            for removed in retention.removed {
                try? fileManager.removeItem(
                    at: versionURL(for: removed)
                )
            }
            removeEmptyVersionDirectories()
            return snapshot
        } catch {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func versions(
        for recordID: UUID
    ) throws -> [PDFVersionSnapshot] {
        try prepareDirectories()
        return try loadVersionIndex()
            .filter {
                $0.documentID == recordID
                    && fileManager.fileExists(
                        atPath: versionURL(for: $0).path
                    )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func versionFileURL(
        snapshotID: UUID,
        recordID: UUID
    ) throws -> URL {
        try prepareDirectories()
        guard let snapshot = try loadVersionIndex().first(
            where: {
                $0.id == snapshotID
                    && $0.documentID == recordID
            }
        ) else {
            throw PaperPathError.storageFailure(
                "The selected recovery version is unavailable."
            )
        }
        let url = versionURL(for: snapshot)
        guard fileManager.fileExists(atPath: url.path),
              try fileFingerprint(at: url)
                == snapshot.contentFingerprint
        else {
            throw PaperPathError.outputVerificationFailed(
                "the selected recovery version failed its integrity check"
            )
        }
        return url
    }

    func updateVersionMilestone(
        snapshotID: UUID,
        recordID: UUID,
        name: String?,
        pinned: Bool,
        linkedDeliveryReceiptID: UUID?
    ) throws -> [PDFVersionSnapshot] {
        try prepareDirectories()
        var snapshots = try loadVersionIndex()
        guard let index = snapshots.firstIndex(where: {
            $0.id == snapshotID && $0.documentID == recordID
        }) else {
            throw PaperPathError.storageFailure(
                "The selected recovery version is unavailable."
            )
        }
        let normalizedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = snapshots[index]
        if pinned, !existing.isPinnedMilestone {
            let pinnedSnapshots = snapshots.filter(\.isPinnedMilestone)
            let summary = PDFPinnedVersionStorageSummary(
                milestoneCount: pinnedSnapshots.count,
                byteCount: pinnedSnapshots.reduce(Int64(0)) {
                    $0 + max(0, $1.byteCount)
                }
            )
            guard summary.canAdd(bytes: existing.byteCount) else {
                throw PaperPathError.insufficientSelection(
                    "Keep up to 32 pinned milestones and 1 GB across the library."
                )
            }
        }
        snapshots[index] = existing.updatingMilestone(
            name: normalizedName,
            pinned: pinned,
            linkedDeliveryReceiptID: linkedDeliveryReceiptID
        )
        let pinnedIDs = Set(
            snapshots.filter(\.isPinnedMilestone).map(\.id)
        )
        let retention = retainedVersions(
            from: snapshots,
            preserving: pinnedIDs
        )
        try saveVersionIndex(retention.kept)
        for removed in retention.removed {
            try? fileManager.removeItem(
                at: versionURL(for: removed)
            )
        }
        removeEmptyVersionDirectories()
        return retention.kept
            .filter { $0.documentID == recordID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func protectDeliveryReceiptMilestone(
        for record: DocumentRecord,
        label: String,
        milestoneName: String
    ) throws -> PDFVersionSnapshot {
        guard let receipt = record.deliveryReceipt,
              receipt.isVerified
        else {
            throw PaperPathError.insufficientSelection(
                "No verified delivery receipt is available to protect."
            )
        }

        var candidate = try versions(for: record.id).first {
            $0.matchesDeliveryReceipt(receipt)
        }
        if candidate == nil, record.hasCurrentDeliveryReceipt {
            let created = try createVersionSnapshot(
                for: record,
                label: label
            )
            guard created.matchesDeliveryReceipt(receipt) else {
                throw PaperPathError.outputVerificationFailed(
                    "the protected version did not match the delivery receipt"
                )
            }
            candidate = created
        }
        guard let candidate else {
            throw PaperPathError.storageFailure(
                "The PDF version matching this receipt is no longer available."
            )
        }

        _ = try versionFileURL(
            snapshotID: candidate.id,
            recordID: record.id
        )
        if candidate.isPinnedMilestone,
           candidate.linkedDeliveryReceiptID == receipt.id {
            return candidate
        }

        let updated = try updateVersionMilestone(
            snapshotID: candidate.id,
            recordID: record.id,
            name: candidate.resolvedMilestoneName ?? milestoneName,
            pinned: true,
            linkedDeliveryReceiptID: receipt.id
        )
        guard let protected = updated.first(where: {
            $0.id == candidate.id
                && $0.isPinnedMilestone
                && $0.linkedDeliveryReceiptID == receipt.id
                && $0.matchesDeliveryReceipt(receipt)
        }) else {
            throw PaperPathError.storageFailure(
                "The verified milestone could not be saved."
            )
        }
        return protected
    }

    func pinnedVersionMilestones() throws -> [PDFVersionSnapshot] {
        try prepareDirectories()
        return try loadVersionIndex()
            .filter {
                $0.isPinnedMilestone
                    && fileManager.fileExists(
                        atPath: versionURL(for: $0).path
                    )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func unpinAllVersionMilestones() throws -> Int {
        try prepareDirectories()
        let snapshots = try loadVersionIndex()
        let pinnedCount = snapshots.filter(\.isPinnedMilestone).count
        guard pinnedCount > 0 else { return 0 }
        let updated = snapshots.map { snapshot in
            guard snapshot.isPinnedMilestone else { return snapshot }
            return snapshot.updatingMilestone(
                name: snapshot.milestoneName,
                pinned: false,
                linkedDeliveryReceiptID:
                    snapshot.linkedDeliveryReceiptID
            )
        }
        let retention = retainedVersions(
            from: updated,
            preserving: []
        )
        try saveVersionIndex(retention.kept)
        for removed in retention.removed {
            try? fileManager.removeItem(at: versionURL(for: removed))
        }
        removeEmptyVersionDirectories()
        return pinnedCount
    }

    func enforceVersionRetention(
        preserving snapshotID: UUID? = nil
    ) throws {
        let snapshots = try loadVersionIndex()
        let retention = retainedVersions(
            from: snapshots,
            preserving: snapshotID.map { Set([$0]) } ?? []
        )
        guard !retention.removed.isEmpty else { return }
        try saveVersionIndex(retention.kept)
        for removed in retention.removed {
            try? fileManager.removeItem(at: versionURL(for: removed))
        }
        removeEmptyVersionDirectories()
    }

    func restoreVersion(
        snapshotID: UUID,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        try prepareDirectories()
        guard let snapshot = try loadVersionIndex().first(where: {
            $0.id == snapshotID && $0.documentID == record.id
        }) else {
            throw PaperPathError.storageFailure(
                "The selected recovery version is unavailable."
            )
        }
        let source = versionURL(for: snapshot)
        guard fileManager.fileExists(atPath: source.path),
              try fileFingerprint(at: source)
                == snapshot.contentFingerprint
        else {
            throw PaperPathError.outputVerificationFailed(
                "the selected recovery version failed its integrity check"
            )
        }

        let destination = url(for: record)
        let replacement = filesURL.appendingPathComponent(
            ".restore-\(UUID().uuidString).pdf"
        )
        let rollback = filesURL.appendingPathComponent(
            ".rollback-\(UUID().uuidString).pdf"
        )
        var didReplace = false
        var sidecarBackups: [(source: URL, backup: URL)] = []
        defer {
            try? fileManager.removeItem(at: replacement)
            try? fileManager.removeItem(at: rollback)
            for entry in sidecarBackups {
                try? fileManager.removeItem(at: entry.backup)
            }
        }

        do {
            try ensureCapacity(for: source)
            try fileManager.copyItem(at: source, to: replacement)
            try requireFileProtection(to: replacement)
            guard try fileFingerprint(at: replacement)
                    == snapshot.contentFingerprint
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the prepared recovery copy failed its integrity check"
                )
            }
            let restoredProfile = try inspector.inspect(url: replacement)
            for sidecar in sidecarURLs(for: record.id)
                where fileManager.fileExists(atPath: sidecar.path) {
                let backup = rootURL.appendingPathComponent(
                    ".rollback-sidecar-\(UUID().uuidString)"
                )
                try fileManager.copyItem(at: sidecar, to: backup)
                try requireFileProtection(to: backup)
                sidecarBackups.append((sidecar, backup))
            }

            try fileManager.copyItem(at: destination, to: rollback)
            try requireFileProtection(to: rollback)
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: replacement
            )
            didReplace = true
            try requireFileProtection(to: destination)
            guard try fileFingerprint(at: destination)
                    == snapshot.contentFingerprint
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the restored working copy failed its integrity check"
                )
            }
            try removeSidecars(for: record)

            let validBookmarks = snapshot.bookmarkedPages.filter {
                $0 >= 0 && $0 < restoredProfile.pageCount
            }
            let validBookmarkSet = Set(validBookmarks)
            var updated = record
            updated.profile = restoredProfile
            updated.modifiedAt = Date()
            updated.contentRevisionID = UUID()
            updated.contentFingerprint = snapshot.contentFingerprint
            updated.bookmarkedPages = validBookmarks
            updated.bookmarkNames = snapshot.bookmarkNames.filter {
                validBookmarkSet.contains($0.key)
            }
            updated.lastPageIndex = min(
                max(snapshot.lastPageIndex, 0),
                max(0, restoredProfile.pageCount - 1)
            )
            updated.lastViewedAt = Date()
            updated.completedActions = []
            updated.taskCheckpoint = nil
            updated.brief = nil
            updated.deliveryReceipt = nil
            try replaceRecord(updated)
            return updated
        } catch {
            var rollbackFailed = false
            if didReplace,
               fileManager.fileExists(atPath: rollback.path) {
                do {
                    _ = try fileManager.replaceItemAt(
                        destination,
                        withItemAt: rollback
                    )
                    try requireFileProtection(to: destination)
                } catch {
                    rollbackFailed = true
                }
            }
            for entry in sidecarBackups
                where !fileManager.fileExists(atPath: entry.source.path)
                    && fileManager.fileExists(atPath: entry.backup.path) {
                do {
                    try fileManager.moveItem(
                        at: entry.backup,
                        to: entry.source
                    )
                    try requireFileProtection(to: entry.source)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                throw PaperPathError.storageFailure(
                    "The recovery transaction could not be rolled back."
                )
            }
            throw error
        }
    }

    func moveToTrash(_ record: DocumentRecord) throws -> DocumentRecord {
        var updated = record
        updated.deletedAt = Date()
        updated.isPinned = false
        updated.taskCheckpoint = nil
        try replaceRecord(updated)
        return updated
    }

    func restoreFromTrash(
        _ record: DocumentRecord
    ) throws -> DocumentRecord {
        var updated = record
        updated.deletedAt = nil
        updated.modifiedAt = Date()
        try replaceRecord(updated)
        return updated
    }

    func delete(_ record: DocumentRecord) throws {
        try permanentlyDelete(record)
    }

    func permanentlyDelete(_ record: DocumentRecord) throws {
        let fileURL = url(for: record)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try? removeSidecars(for: record)
        try? removeVersions(for: record.id)
        try? removeOfficeExports(for: record.id)
        var records = try loadIndex()
        records.removeAll { $0.id == record.id }
        try saveIndex(records)
    }

    func purgeDeleted(before cutoff: Date) throws -> [UUID] {
        let records = try loadIndex()
        let expired = records.filter {
            guard let deletedAt = $0.deletedAt else { return false }
            return deletedAt < cutoff
        }
        guard !expired.isEmpty else { return [] }

        for record in expired {
            let fileURL = url(for: record)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try? removeSidecars(for: record)
            try? removeVersions(for: record.id)
            try? removeOfficeExports(for: record.id)
        }
        let expiredIDs = Set(expired.map(\.id))
        try saveIndex(
            records.filter { !expiredIDs.contains($0.id) }
        )
        return Array(expiredIDs)
    }

    func url(for record: DocumentRecord) -> URL {
        filesURL.appendingPathComponent(record.fileName)
    }

    func containsDocuments() throws -> Bool {
        try !load().isEmpty
    }

    func storageSnapshot() throws -> LocalStorageSnapshot {
        try prepareDirectories()
        try Task.checkCancellation()
        let directorySizes = try storageDirectorySizes()
        return LocalStorageSnapshot(
            pdfBytes: directorySizes[
                filesURL.lastPathComponent,
                default: 0
            ],
            versionBytes: directorySizes[
                versionsURL.lastPathComponent,
                default: 0
            ],
            textIndexBytes: directorySizes[
                indicesURL.lastPathComponent,
                default: 0
            ],
            ocrBytes: directorySizes[
                ocrURL.lastPathComponent,
                default: 0
            ],
            deliveryCacheBytes: directorySizes[
                preflightURL.lastPathComponent,
                default: 0
            ],
            officeExportBytes: directorySizes[
                officeExportsURL.lastPathComponent,
                default: 0
            ],
            officeDeliveryBytes: directorySizes[
                officeDeliveriesURL.lastPathComponent,
                default: 0
            ],
            metadataBytes: fileSize(indexURL)
                + fileSize(versionsIndexURL)
                + fileSize(batchDeliveryURL)
                + fileSize(officeProductionQueueURL)
                + fileSize(officeDeliveryIndexURL)
                + fileSize(officeTrustedSignersURL)
                + fileSize(batesBatchReceiptsURL)
        )
    }

    func availableCapacityForOfficeProduction() throws -> Int64? {
        try prepareDirectories()
        return availableCapacity(rootURL)
    }

    private func replaceRecord(_ record: DocumentRecord) throws {
        var records = try loadIndex()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            throw PaperPathError.storageFailure("The document record is missing.")
        }
        records[index] = record
        try saveIndex(records)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: versionsURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: indicesURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: ocrURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: preflightURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: officeExportsURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: officeDeliveriesURL,
            withIntermediateDirectories: true
        )
        for directory in [
            rootURL,
            filesURL,
            versionsURL,
            indicesURL,
            ocrURL,
            preflightURL,
            officeExportsURL,
            officeDeliveriesURL
        ] {
            try requireFileProtection(to: directory)
        }
        excludeFromBackup(rootURL)
        if !didRecoverInterruptedWorkingCopyTransaction {
            try recoverInterruptedWorkingCopyTransaction()
            didRecoverInterruptedWorkingCopyTransaction = true
        }
        if !fileManager.fileExists(
            atPath: batesBatchReceiptsURL.path
        ) {
            try writeProtectedData(
                try JSONEncoder.paperPath.encode(
                    [PDFSignedBatesBatchReceipt]()
                ),
                to: batesBatchReceiptsURL
            )
        } else {
            try requireFileProtection(to: batesBatchReceiptsURL)
        }
    }

    private func recoverInterruptedWorkingCopyTransaction() throws {
        guard fileManager.fileExists(
            atPath: workingCopyTransactionJournalURL.path
        ) else {
            removeOrphanedWorkingCopyTransactionFiles()
            return
        }
        let journal: PDFWorkingCopyTransactionJournal
        do {
            let data = try Data(
                contentsOf: workingCopyTransactionJournalURL
            )
            journal = try JSONDecoder.paperPath.decode(
                PDFWorkingCopyTransactionJournal.self,
                from: data
            )
        } catch {
            throw PaperPathError.storageFailure(
                "An interrupted PDF batch could not be inspected safely."
            )
        }

        let allowedRoots = [
            rootURL.standardizedFileURL.path,
            filesURL.standardizedFileURL.path
        ]
        guard !journal.entries.isEmpty,
              journal.entries.count
                <= PDFBatesBatchPlan.maximumDocumentCount + 2,
              journal.entries.allSatisfy({ entry in
                  [entry.destinationPath, entry.backupPath, entry.stagingPath]
                      .allSatisfy { path in
                          allowedRoots.contains {
                              path == $0 || path.hasPrefix($0 + "/")
                          }
                      }
              })
        else {
            throw PaperPathError.storageFailure(
                "An interrupted PDF batch has an invalid recovery journal."
            )
        }

        var recoveryFailed = false
        for entry in journal.entries.reversed() {
            let destination = URL(fileURLWithPath: entry.destinationPath)
            let backup = URL(fileURLWithPath: entry.backupPath)
            let staging = URL(fileURLWithPath: entry.stagingPath)
            do {
                if fileManager.fileExists(atPath: backup.path) {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(
                        at: backup,
                        to: destination
                    )
                    try requireFileProtection(to: destination)
                } else {
                    guard fileManager.fileExists(
                        atPath: destination.path
                    ),
                          try fileFingerprint(at: destination)
                            == entry.backupFingerprint
                    else {
                        throw PaperPathError.storageFailure(
                            "A PDF batch recovery file is missing."
                        )
                    }
                }
                guard try fileFingerprint(at: destination)
                        == entry.backupFingerprint
                else {
                    throw PaperPathError.storageFailure(
                        "A PDF batch recovery file did not match."
                    )
                }
                if fileManager.fileExists(atPath: staging.path) {
                    try fileManager.removeItem(at: staging)
                }
            } catch {
                recoveryFailed = true
            }
        }
        guard !recoveryFailed else {
            throw PaperPathError.storageFailure(
                "An interrupted PDF batch could not be fully restored."
            )
        }
        try fileManager.removeItem(
            at: workingCopyTransactionJournalURL
        )
        removeOrphanedWorkingCopyTransactionFiles()
    }

    private func removeOrphanedWorkingCopyTransactionFiles() {
        for directory in [rootURL, filesURL] {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for url in urls
            where url.lastPathComponent.hasPrefix(".batch-") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func untrustedBatesBatchReport(
        _ receipt: PDFSignedBatesBatchReceipt,
        status: PDFOfficeReportVerificationStatus,
        detail: String
    ) -> PDFBatesBatchReceiptVerificationReport {
        PDFBatesBatchReceiptVerificationReport(
            receiptID: receipt.id,
            checkedAt: Date(),
            signatureStatus: status,
            trustStatus: status == .invalid
                ? .invalid
                : .unsupported,
            trustedSignerName: nil,
            keyID: receipt.signature.keyID,
            items: receipt.payload.entries.map {
                PDFBatesBatchReceiptVerificationItem(
                    entry: $0,
                    status: .untrusted,
                    actualRevisionID: nil,
                    actualSHA256: nil
                )
            },
            detail: detail
        )
    }

    private func isValidOfficeDeliveryReportSignature(
        _ report: PDFOfficeSignedVerificationReport
    ) -> Bool {
        let signature = report.signature
        guard report.payload.isStructurallyValid,
              signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                  base64Encoded: signature.publicKeyBase64
              ),
              let signatureData = Data(
                  base64Encoded: signature.signatureBase64
              ),
              officeDeliverySigningKeyID(
                  publicKeyData: publicKeyData
              ) == signature.keyID,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let payloadData = try? JSONEncoder.paperPath.encode(
                  report.payload
              )
        else { return false }
        return publicKey.isValidSignature(
            signatureData,
            for: payloadData
        )
    }

    private func officeSignerTrust(
        for signature: PDFOfficeVerificationSignature,
        signatureIsValid: Bool,
        localKeyID: String?,
        trustedSigners: [PDFOfficeTrustedSigner]
    ) -> (
        status: PDFOfficeSignerTrustStatus,
        name: String?
    ) {
        guard signature.algorithm == "Ed25519" else {
            return (.unsupported, nil)
        }
        guard signatureIsValid else { return (.invalid, nil) }
        if localKeyID == signature.keyID {
            return (.thisDevice, nil)
        }
        if let signer = trustedSigners.first(where: {
            $0.keyID == signature.keyID
                && $0.publicKeyBase64
                    == signature.publicKeyBase64
        }) {
            return (.trusted, signer.displayName)
        }
        return (.unknown, nil)
    }

    private func isValidBatesReceiptSignature(
        _ receipt: PDFSignedBatesBatchReceipt
    ) -> Bool {
        let signature = receipt.signature
        guard receipt.payload.isStructurallyValid,
              signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                  base64Encoded: signature.publicKeyBase64
              ),
              let signatureData = Data(
                  base64Encoded: signature.signatureBase64
              ),
              officeDeliverySigningKeyID(
                  publicKeyData: publicKeyData
              ) == signature.keyID,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let payloadData = try? JSONEncoder.paperPath.encode(
                  receipt.payload
              )
        else { return false }
        guard publicKey.isValidSignature(
            signatureData,
            for: payloadData
        ) else { return false }
        guard let removal = receipt.removal else { return true }
        return isValidBatesRemovalReceiptSignature(
            removal,
            for: receipt.payload
        )
    }

    private func isValidBatesRemovalReceiptSignature(
        _ removal: PDFSignedBatesRemovalReceipt,
        for batesPayload: PDFBatesBatchReceiptPayload
    ) -> Bool {
        let signature = removal.signature
        guard removal.payload.isLinked(to: batesPayload),
              signature.algorithm == "Ed25519",
              let publicKeyData = Data(
                  base64Encoded: signature.publicKeyBase64
              ),
              let signatureData = Data(
                  base64Encoded: signature.signatureBase64
              ),
              officeDeliverySigningKeyID(
                  publicKeyData: publicKeyData
              ) == signature.keyID,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let payloadData = try? JSONEncoder.paperPath.encode(
                  removal.payload
              )
        else { return false }
        return publicKey.isValidSignature(
            signatureData,
            for: payloadData
        )
    }

    private func makeSignedBatesBatchReceipt(
        plan: PDFBatesBatchPlan,
        sourceRecordsByID: [UUID: DocumentRecord],
        updatedByID: [UUID: DocumentRecord],
        preparedCopies: [PreparedPDFWorkingCopy]
    ) throws -> PDFSignedBatesBatchReceipt {
        let preparedByID = Dictionary(
            uniqueKeysWithValues: preparedCopies.map {
                ($0.recordID, $0)
            }
        )
        guard plan.items.count == preparedCopies.count,
              plan.items.allSatisfy({
                  sourceRecordsByID[$0.recordID] != nil
                      && updatedByID[$0.recordID] != nil
                      && preparedByID[$0.recordID] != nil
              })
        else {
            throw PaperPathError.storageFailure(
                "The Bates receipt sources are incomplete."
            )
        }

        var entries: [PDFBatesBatchReceiptEntry] = []
        entries.reserveCapacity(plan.items.count)
        for item in plan.items {
            try Task.checkCancellation()
            guard let source = sourceRecordsByID[item.recordID],
                  let updated = updatedByID[item.recordID],
                  let prepared = preparedByID[item.recordID],
                  source.contentRevisionID == item.sourceRevisionID,
                  updated.contentRevisionID != source.contentRevisionID,
                  updated.profile.pageCount == item.pageCount,
                  let outputFingerprint =
                    updated.contentFingerprint,
                  outputFingerprint.count == 64
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Bates receipt revision set is incomplete"
                )
            }
            let sourceFingerprint = try fileFingerprint(
                at: url(for: source)
            )
            guard fileManager.fileExists(
                      atPath: prepared.preparedURL.path
                  ),
                  sourceFingerprint.count == 64,
                  outputFingerprint.count == 64
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Bates receipt fingerprints do not match"
                )
            }
            entries.append(
                PDFBatesBatchReceiptEntry(
                    recordID: item.recordID,
                    displayName: String(
                        source.displayName.prefix(120)
                    ),
                    pageCount: item.pageCount,
                    startNumber: item.startNumber,
                    endNumber: item.endNumber,
                    startIdentifier: plan.identifier(
                        for: item.startNumber
                    ),
                    endIdentifier: plan.identifier(
                        for: item.endNumber
                    ),
                    sourceRevisionID: source.contentRevisionID,
                    outputRevisionID: updated.contentRevisionID,
                    sourceSHA256: sourceFingerprint,
                    outputSHA256: outputFingerprint
                )
            )
        }

        let payload = PDFBatesBatchReceiptPayload(
            schema: PDFBatesBatchReceiptPayload.schema,
            batchID: UUID(),
            createdAt: Date(),
            digitCount: plan.digitCount,
            prefix: plan.prefix,
            suffix: plan.suffix,
            position: plan.position,
            totalPageCount: plan.totalPageCount,
            firstIdentifier: plan.firstIdentifier,
            lastIdentifier: plan.lastIdentifier,
            entries: entries
        )
        guard payload.isStructurallyValid else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates receipt payload is invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalPayload = try JSONEncoder.paperPath.encode(
            payload
        )
        let signatureData = try privateKey.signature(
            for: canonicalPayload
        )
        let publicKeyData = privateKey.publicKey.rawRepresentation
        return PDFSignedBatesBatchReceipt(
            payload: payload,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKeyData
                ),
                publicKeyBase64:
                    publicKeyData.base64EncodedString(),
                signatureBase64:
                    signatureData.base64EncodedString()
            )
        )
    }

    private func makeSignedBatesRemovalReceipt(
        for receipt: PDFSignedBatesBatchReceipt,
        sourceRecordsByID: [UUID: DocumentRecord],
        updatedByID: [UUID: DocumentRecord],
        preparedCopies: [PreparedPDFWorkingCopy]
    ) throws -> PDFSignedBatesRemovalReceipt {
        guard receipt.removal == nil,
              isValidBatesReceiptSignature(receipt)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates receipt cannot authorize this removal"
            )
        }
        let preparedByID = Dictionary(
            uniqueKeysWithValues: preparedCopies.map {
                ($0.recordID, $0)
            }
        )
        guard receipt.payload.entries.count == preparedCopies.count,
              receipt.payload.entries.allSatisfy({
                  sourceRecordsByID[$0.recordID] != nil
                      && updatedByID[$0.recordID] != nil
                      && preparedByID[$0.recordID] != nil
              })
        else {
            throw PaperPathError.storageFailure(
                "The Bates removal receipt sources are incomplete."
            )
        }

        var entries: [PDFBatesRemovalReceiptEntry] = []
        entries.reserveCapacity(receipt.payload.entries.count)
        for numbered in receipt.payload.entries {
            try Task.checkCancellation()
            guard let source = sourceRecordsByID[numbered.recordID],
                  let updated = updatedByID[numbered.recordID],
                  let prepared = preparedByID[numbered.recordID],
                  source.deletedAt == nil,
                  source.isWorkingCopy,
                  source.contentRevisionID == numbered.outputRevisionID,
                  updated.contentRevisionID != source.contentRevisionID,
                  updated.profile.pageCount == numbered.pageCount,
                  let clearedFingerprint = updated.contentFingerprint,
                  clearedFingerprint.count == 64,
                  fileManager.fileExists(
                      atPath: prepared.preparedURL.path
                  )
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Bates removal revision set is incomplete"
                )
            }
            let numberedFingerprint = try fileFingerprint(
                at: url(for: source)
            )
            guard numberedFingerprint == numbered.outputSHA256
            else {
                throw PaperPathError.outputVerificationFailed(
                    "a numbered PDF changed before Bates removal"
                )
            }
            entries.append(
                PDFBatesRemovalReceiptEntry(
                    recordID: numbered.recordID,
                    displayName: numbered.displayName,
                    pageCount: numbered.pageCount,
                    numberedRevisionID: numbered.outputRevisionID,
                    clearedRevisionID: updated.contentRevisionID,
                    numberedSHA256: numbered.outputSHA256,
                    clearedSHA256: clearedFingerprint
                )
            )
        }

        let payload = PDFBatesRemovalReceiptPayload(
            schema: PDFBatesRemovalReceiptPayload.schema,
            removalID: UUID(),
            batesBatchID: receipt.id,
            createdAt: Date(),
            totalPageCount: receipt.payload.totalPageCount,
            entries: entries
        )
        guard payload.isLinked(to: receipt.payload) else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates removal receipt payload is invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalPayload = try JSONEncoder.paperPath.encode(
            payload
        )
        let signatureData = try privateKey.signature(
            for: canonicalPayload
        )
        let publicKeyData = privateKey.publicKey.rawRepresentation
        return PDFSignedBatesRemovalReceipt(
            payload: payload,
            signature: PDFOfficeVerificationSignature(
                algorithm: "Ed25519",
                keyID: officeDeliverySigningKeyID(
                    publicKeyData: publicKeyData
                ),
                publicKeyBase64:
                    publicKeyData.base64EncodedString(),
                signatureBase64:
                    signatureData.base64EncodedString()
            )
        )
    }

    private func saveBatesBatchReceipts(
        _ receipts: [PDFSignedBatesBatchReceipt]
    ) throws -> [PDFSignedBatesBatchReceipt] {
        let bounded = boundedBatesBatchReceipts(receipts)
        guard receipts.isEmpty || !bounded.isEmpty else {
            throw PaperPathError.storageFailure(
                "The Bates receipt history exceeds its local limit."
            )
        }
        let data = try JSONEncoder.paperPath.encode(bounded)
        guard data.count
                <= PDFBatesBatchReceiptPayload.maximumHistoryBytes
        else {
            throw PaperPathError.storageFailure(
                "The Bates receipt history exceeds its local limit."
            )
        }
        try writeProtectedData(data, to: batesBatchReceiptsURL)
        return bounded
    }

    private func boundedBatesBatchReceipts(
        _ receipts: [PDFSignedBatesBatchReceipt]
    ) -> [PDFSignedBatesBatchReceipt] {
        let sorted = receipts.sorted {
            $0.payload.createdAt > $1.payload.createdAt
        }
        var result: [PDFSignedBatesBatchReceipt] = []
        var seen: Set<UUID> = []
        for receipt in sorted
        where result.count
                < PDFBatesBatchReceiptPayload.maximumReceiptCount {
            guard seen.insert(receipt.id).inserted,
                  receipt.payload.isStructurallyValid
            else { continue }
            let candidate = result + [receipt]
            guard let data = try? JSONEncoder.paperPath.encode(
                candidate
            ),
                  data.count
                    <= PDFBatesBatchReceiptPayload.maximumHistoryBytes
            else { break }
            result = candidate
        }
        return result
    }

    private func loadIndex() throws -> [DocumentRecord] {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: indexURL)
            return try JSONDecoder.paperPath.decode([DocumentRecord].self, from: data)
        } catch {
            throw PaperPathError.storageFailure("The local library index is unreadable.")
        }
    }

    private func loadExistingRecords() throws -> [DocumentRecord] {
        try prepareDirectories()
        let records = try loadIndex()
        pruneOfficeExports(for: records)
        let existing = records.filter {
            fileManager.fileExists(
                atPath: filesURL
                    .appendingPathComponent($0.fileName).path
            )
        }
        if existing.count != records.count {
            try saveIndex(existing)
        }
        return existing
    }

    private func saveIndex(_ records: [DocumentRecord]) throws {
        do {
            let data = try JSONEncoder.paperPath.encode(sorted(records))
            try writeProtectedData(data, to: indexURL)
        } catch {
            throw PaperPathError.storageFailure("The local library index could not be saved.")
        }
    }

    private func loadVersionIndex() throws -> [PDFVersionSnapshot] {
        guard fileManager.fileExists(atPath: versionsIndexURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: versionsIndexURL)
            return try JSONDecoder.paperPath.decode(
                [PDFVersionSnapshot].self,
                from: data
            )
        } catch {
            throw PaperPathError.storageFailure(
                "The local version history is unreadable."
            )
        }
    }

    private func saveVersionIndex(
        _ snapshots: [PDFVersionSnapshot]
    ) throws {
        do {
            let data = try JSONEncoder.paperPath.encode(
                snapshots.sorted { $0.createdAt > $1.createdAt }
            )
            try writeProtectedData(data, to: versionsIndexURL)
        } catch {
            throw PaperPathError.storageFailure(
                "The local version history could not be saved."
            )
        }
    }

    private func retainedVersions(
        from snapshots: [PDFVersionSnapshot],
        preserving snapshotIDs: Set<UUID>
    ) -> (
        kept: [PDFVersionSnapshot],
        removed: [PDFVersionSnapshot]
    ) {
        let protectedIDs = snapshotIDs.union(
            snapshots.filter(\.isPinnedMilestone).map(\.id)
        )
        var kept = Dictionary(
            grouping: snapshots,
            by: \.documentID
        ).values.flatMap { versions -> [PDFVersionSnapshot] in
            let sorted = versions.sorted { $0.createdAt > $1.createdAt }
            var selected = Array(
                sorted.prefix(Self.maximumVersionsPerDocument)
            )
            for required in sorted where
                protectedIDs.contains(required.id)
                    && !selected.contains(where: {
                        $0.id == required.id
                    }) {
                if let removableIndex = selected.lastIndex(where: {
                    !protectedIDs.contains($0.id)
                }) {
                    selected.remove(at: removableIndex)
                }
                selected.append(required)
            }
            return selected
        }
        var totalBytes = kept.reduce(Int64(0)) {
            $0 + max(0, $1.byteCount)
        }
        while totalBytes > Self.maximumVersionBytes {
            guard let candidate = kept
                .filter({ !protectedIDs.contains($0.id) })
                .min(by: { $0.createdAt < $1.createdAt })
            else { break }
            kept.removeAll { $0.id == candidate.id }
            totalBytes -= max(0, candidate.byteCount)
        }
        let keptIDs = Set(kept.map(\.id))
        return (
            kept: kept.sorted { $0.createdAt > $1.createdAt },
            removed: snapshots.filter { !keptIDs.contains($0.id) }
        )
    }

    private func removeVersions(for recordID: UUID) throws {
        let remaining = try loadVersionIndex().filter {
            $0.documentID != recordID
        }
        try saveVersionIndex(remaining)
        let directory = versionsURL.appendingPathComponent(
            recordID.uuidString,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func removeEmptyVersionDirectories() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents {
            guard (try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true,
                  (try? fileManager.contentsOfDirectory(
                    atPath: url.path
                  ).isEmpty) == true
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func versionURL(
        for snapshot: PDFVersionSnapshot
    ) -> URL {
        versionsURL.appendingPathComponent(snapshot.fileName)
    }

    private func sorted(_ records: [DocumentRecord]) -> [DocumentRecord] {
        records.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            if $0.modifiedAt == $1.modifiedAt {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Untitled PDF"
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(80))
    }

    private func duplicateName(
        for displayName: String,
        records: [DocumentRecord]
    ) -> String {
        let base = normalizedName(displayName)
        let existing = Set(
            records.map { $0.displayName.lowercased() }
        )
        var index = 1
        while true {
            let suffix = index == 1 ? " Copy" : " Copy \(index)"
            let candidate = normalizedName(
                String(base.prefix(max(1, 80 - suffix.count)))
                    + suffix
            )
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }

    private func requireFileProtection(to url: URL) throws {
        try LocalFileSecurity.requireCompleteProtection(
            to: url,
            fileManager: fileManager
        )
    }

    private func writeProtectedData(
        _ data: Data,
        to destination: URL
    ) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".protected-\(UUID().uuidString)",
                isDirectory: false
            )
        defer {
            try? fileManager.removeItem(at: staging)
        }

        try data.write(to: staging, options: .atomic)
        try requireFileProtection(to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging
            )
        } else {
            try fileManager.moveItem(
                at: staging,
                to: destination
            )
        }
    }

    private func writeProtectedDataTransaction(
        _ writes: [(data: Data, destination: URL)]
    ) throws {
        guard !writes.isEmpty else { return }
        try Task.checkCancellation()
        let destinationPaths = writes.map {
            $0.destination.standardizedFileURL.path
        }
        guard Set(destinationPaths).count == destinationPaths.count else {
            throw PaperPathError.storageFailure(
                "The protected transaction contains duplicate files."
            )
        }
        try ensureTransactionCapacity(for: writes)

        var stagingByDestination: [URL: URL] = [:]
        var backupByDestination: [URL: URL] = [:]
        var didStartPublishing = false

        func removeIfPresent(_ url: URL) throws {
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }

        do {
            for write in writes {
                try Task.checkCancellation()
                let staging = write.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".protected-\(UUID().uuidString)",
                        isDirectory: false
                    )
                stagingByDestination[write.destination] = staging
                try write.data.write(to: staging, options: .atomic)
                try requireFileProtection(to: staging)
            }

            for write in writes where fileManager.fileExists(
                atPath: write.destination.path
            ) {
                try Task.checkCancellation()
                let backup = write.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".rollback-\(UUID().uuidString)",
                        isDirectory: false
                    )
                backupByDestination[write.destination] = backup
                try fileManager.copyItem(
                    at: write.destination,
                    to: backup
                )
            }

            try Task.checkCancellation()
            didStartPublishing = true
            for write in writes {
                guard let staging =
                    stagingByDestination[write.destination]
                else {
                    throw PaperPathError.storageFailure(
                        "A protected staging file is missing."
                    )
                }
                if fileManager.fileExists(
                    atPath: write.destination.path
                ) {
                    _ = try fileManager.replaceItemAt(
                        write.destination,
                        withItemAt: staging
                    )
                } else {
                    try fileManager.moveItem(
                        at: staging,
                        to: write.destination
                    )
                }
            }
        } catch {
            var rollbackFailed = false
            if didStartPublishing {
                for write in writes.reversed() {
                    do {
                        try removeIfPresent(write.destination)
                        if let backup =
                            backupByDestination[write.destination],
                           fileManager.fileExists(atPath: backup.path) {
                            try fileManager.moveItem(
                                at: backup,
                                to: write.destination
                            )
                        }
                    } catch {
                        rollbackFailed = true
                    }
                }
            }
            for staging in stagingByDestination.values {
                try? removeIfPresent(staging)
            }
            if !rollbackFailed {
                for backup in backupByDestination.values {
                    try? removeIfPresent(backup)
                }
            }
            if rollbackFailed {
                throw PaperPathError.storageFailure(
                    "The protected transaction could not be rolled back."
                )
            }
            throw error
        }

        for staging in stagingByDestination.values {
            try? removeIfPresent(staging)
        }
        for backup in backupByDestination.values {
            try? removeIfPresent(backup)
        }
    }

    private func ensureTransactionCapacity(
        for writes: [(data: Data, destination: URL)]
    ) throws {
        guard let available = availableCapacity(rootURL) else {
            return
        }
        let stagedBytes = writes.reduce(Int64.zero) {
            saturatingAdd($0, Int64($1.data.count))
        }
        let largestAtomicWrite = writes.reduce(Int64.zero) {
            max($0, Int64($1.data.count))
        }
        let rollbackBytes = writes.reduce(Int64.zero) {
            partial, write in
            saturatingAdd(partial, fileSize(write.destination))
        }
        let reserve = Int64(8 * 1_024 * 1_024)
        let required = saturatingAdd(
            saturatingAdd(stagedBytes, largestAtomicWrite),
            saturatingAdd(rollbackBytes, reserve)
        )
        guard available >= required else {
            throw PaperPathError.insufficientStorage
        }
    }

    private func ensurePreparedCopyTransactionCapacity(
        sources: [URL],
        destinations: [URL],
        metadataWrites: [(data: Data, destination: URL)]
    ) throws {
        guard let available = availableCapacity(rootURL) else {
            return
        }
        let metadataBytes = metadataWrites.reduce(Int64.zero) {
            saturatingAdd($0, Int64($1.data.count))
        }
        let stagedBytes = sources.reduce(metadataBytes) {
            saturatingAdd($0, fileSize($1))
        }
        let rollbackBytes = (
            destinations + metadataWrites.map(\.destination)
        ).reduce(Int64.zero) {
            saturatingAdd($0, fileSize($1))
        }
        let largestSource = sources.reduce(Int64.zero) {
            max($0, fileSize($1))
        }
        let largestMetadata = metadataWrites.reduce(Int64.zero) {
            max($0, Int64($1.data.count))
        }
        let largestAtomicWrite = max(
            largestMetadata,
            largestSource
        )
        let reserve = Int64(8 * 1_024 * 1_024)
        let required = saturatingAdd(
            saturatingAdd(stagedBytes, rollbackBytes),
            saturatingAdd(largestAtomicWrite, reserve)
        )
        guard available >= required else {
            throw PaperPathError.insufficientStorage
        }
    }

    private func saturatingAdd(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private func excludeFromBackup(_ url: URL) {
        LocalFileSecurity.excludeFromBackup(url)
    }

    private func ensureCapacity(for sourceURL: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= 1_073_741_824 else {
            throw PaperPathError.fileTooLarge
        }
        guard let available = availableCapacity(rootURL) else { return }
        let reserve = Int64(8 * 1_024 * 1_024)
        guard available >= fileSize + reserve else {
            throw PaperPathError.insufficientStorage
        }
    }

    private func fileFingerprint(
        at url: URL,
        progress: (
            @Sendable (_ processedBytes: Int64, _ totalBytes: Int64)
                -> Void
        )? = nil
    ) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        let resourceValues = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        )
        let totalBytes = Int64(resourceValues?.fileSize ?? 0)
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 4 * 1_024 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        while stream.hasBytesAvailable {
            try Task.checkCancellation()
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError
                    ?? PaperPathError.unreadablePDF
            }
            if count == 0 { break }
            hasher.update(
                bufferPointer: UnsafeRawBufferPointer(
                    start: buffer,
                    count: count
                )
            )
            processedBytes += Int64(count)
            if processedBytes - lastReportedBytes
                >= reportingStride
                || (totalBytes > 0 && processedBytes >= totalBytes) {
                progress?(processedBytes, totalBytes)
                lastReportedBytes = processedBytes
            }
        }
        if processedBytes != lastReportedBytes {
            progress?(processedBytes, totalBytes)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func externalFileFingerprint(
        at url: URL,
        expectedSize: Int64,
        receiptID: UUID,
        completedFileCount: Int,
        totalFileCount: Int,
        baseProcessedBytes: Int64,
        totalBatchBytes: Int64,
        fileName: String,
        progress: @escaping @MainActor @Sendable (
            PDFBatesExternalMatchProgress
        ) -> Void
    ) async throws -> String {
        guard let stream = InputStream(url: url) else {
            throw PaperPathError.unreadablePDF
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1 * 1_024 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = -1
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        await progress(
            PDFBatesExternalMatchProgress(
                receiptID: receiptID,
                completedFileCount: completedFileCount,
                totalFileCount: totalFileCount,
                processedBytes: baseProcessedBytes,
                totalBytes: totalBatchBytes,
                currentFileName: fileName
            )
        )
        while stream.hasBytesAvailable {
            try Task.checkCancellation()
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError
                    ?? PaperPathError.unreadablePDF
            }
            if count == 0 { break }
            hasher.update(
                bufferPointer: UnsafeRawBufferPointer(
                    start: buffer,
                    count: count
                )
            )
            processedBytes += Int64(count)
            if processedBytes - lastReportedBytes
                >= reportingStride
                || processedBytes >= expectedSize {
                await progress(
                    PDFBatesExternalMatchProgress(
                        receiptID: receiptID,
                        completedFileCount: completedFileCount,
                        totalFileCount: totalFileCount,
                        processedBytes:
                            baseProcessedBytes + processedBytes,
                        totalBytes: totalBatchBytes,
                        currentFileName: fileName
                    )
                )
                lastReportedBytes = processedBytes
            }
        }
        guard processedBytes == expectedSize else {
            throw PaperPathError.insufficientSelection(
                "A selected PDF changed while it was being matched."
            )
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func externalOfficeFileFingerprint(
        at url: URL,
        expectedSize: Int64,
        packageID: UUID,
        completedFileCount: Int,
        totalFileCount: Int,
        baseProcessedBytes: Int64,
        totalBatchBytes: Int64,
        fileName: String,
        progress: @escaping @MainActor @Sendable (
            PDFOfficeExternalMatchProgress
        ) -> Void
    ) async throws -> String {
        guard let stream = InputStream(url: url) else {
            throw PaperPathError.storageFailure(
                "A selected delivery file could not be read."
            )
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1 * 1_024 * 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = -1
        let reportingStride: Int64 = 4 * 1_024 * 1_024
        await progress(
            PDFOfficeExternalMatchProgress(
                packageID: packageID,
                completedFileCount: completedFileCount,
                totalFileCount: totalFileCount,
                processedBytes: baseProcessedBytes,
                totalBytes: totalBatchBytes,
                currentFileName: fileName
            )
        )
        while stream.hasBytesAvailable {
            try Task.checkCancellation()
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError
                    ?? PaperPathError.storageFailure(
                        "A selected delivery file could not be read."
                    )
            }
            if count == 0 { break }
            hasher.update(
                bufferPointer: UnsafeRawBufferPointer(
                    start: buffer,
                    count: count
                )
            )
            processedBytes += Int64(count)
            if processedBytes - lastReportedBytes
                >= reportingStride
                || processedBytes >= expectedSize {
                await progress(
                    PDFOfficeExternalMatchProgress(
                        packageID: packageID,
                        completedFileCount: completedFileCount,
                        totalFileCount: totalFileCount,
                        processedBytes:
                            baseProcessedBytes + processedBytes,
                        totalBytes: totalBatchBytes,
                        currentFileName: fileName
                    )
                )
                lastReportedBytes = processedBytes
            }
        }
        guard processedBytes == expectedSize else {
            throw PaperPathError.insufficientSelection(
                "A selected delivery file changed while it was being matched."
            )
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func boundedExternalDisplayName(
        _ value: String,
        maximumLength: Int
    ) -> String {
        let sanitized = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = sanitized.isEmpty
            ? "External file"
            : sanitized
        return String(fallback.prefix(maximumLength))
    }

    private func storageDirectorySizes() throws -> [String: Int64] {
        let trackedDirectoryNames: Set<String> = [
            filesURL.lastPathComponent,
            versionsURL.lastPathComponent,
            indicesURL.lastPathComponent,
            ocrURL.lastPathComponent,
            preflightURL.lastPathComponent,
            officeExportsURL.lastPathComponent,
            officeDeliveriesURL.lastPathComponent
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        let rootComponentCount = rootURL.pathComponents.count
        var sizes: [String: Int64] = [:]
        var visitedCount = 0
        for case let url as URL in enumerator {
            if visitedCount.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            visitedCount += 1
            guard let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey
                ]
            ),
                  values.isRegularFile == true
            else { continue }
            let components = url.pathComponents
            guard components.count > rootComponentCount else {
                continue
            }
            let directoryName = components[rootComponentCount]
            guard trackedDirectoryNames.contains(directoryName) else {
                continue
            }
            let bytes = Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? 0
            )
            sizes[directoryName] = saturatingAdd(
                sizes[directoryName, default: 0],
                bytes
            )
        }
        try Task.checkCancellation()
        return sizes
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ]
        ),
              values.isRegularFile == true
        else { return 0 }
        return Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 0
        )
    }

    private func textIndexURL(for recordID: UUID) -> URL {
        indicesURL.appendingPathComponent("\(recordID.uuidString).json")
    }

    private func ocrResultURL(for recordID: UUID) -> URL {
        ocrURL.appendingPathComponent("\(recordID.uuidString).json")
    }

    private func deliveryPreflightURL(for recordID: UUID) -> URL {
        preflightURL.appendingPathComponent(
            "\(recordID.uuidString).json"
        )
    }

    private func officeExportDirectory(
        for recordID: UUID
    ) -> URL {
        officeExportsURL.appendingPathComponent(
            recordID.uuidString,
            isDirectory: true
        )
    }

    private func isSafeOfficeExportFileName(
        _ fileName: String
    ) -> Bool {
        !fileName.isEmpty
            && !fileName.contains("/")
            && !fileName.contains("\\")
            && fileName != "."
            && fileName != ".."
    }

    private func boundedOfficeDeliveryPackages(
        _ packages: [PDFOfficeDeliveryPackage]
    ) -> [PDFOfficeDeliveryPackage] {
        let sorted = packages.sorted { $0.createdAt > $1.createdAt }
        let pinned = sorted.filter(\.isPinned)
        let standard = sorted.filter { !$0.isPinned }
        let retained = pinned
            + Array(
                standard.prefix(
                    max(
                        0,
                        Self.maximumOfficeDeliveryPackages
                            - pinned.count
                    )
                )
            )
        let retainedIDs = Set(retained.map(\.id))
        for package in sorted
            where !retainedIDs.contains(package.id) {
            removeOfficeDeliveryFiles(package)
        }
        return retained.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveOfficeDeliveryPackages(
        _ packages: [PDFOfficeDeliveryPackage]
    ) throws {
        let data = try JSONEncoder.paperPath.encode(packages)
        try writeProtectedData(data, to: officeDeliveryIndexURL)
    }

    private func saveOfficeTrustedSigners(
        _ signers: [PDFOfficeTrustedSigner]
    ) throws {
        let data = try JSONEncoder.paperPath.encode(signers)
        try writeProtectedData(data, to: officeTrustedSignersURL)
        excludeFromBackup(officeTrustedSignersURL)
    }

    private func validateOfficeSignerIdentityCard(
        _ card: PDFOfficeSignerIdentityCard
    ) throws {
        guard card.schema == "PaperPath Signing Identity V1",
              card.keyID.count == 16,
              let publicKeyData = Data(
                base64Encoded: card.publicKeyBase64
              ),
              (try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
              )) != nil,
              officeDeliverySigningKeyID(
                publicKeyData: publicKeyData
              ) == card.keyID
        else {
            throw PaperPathError.outputVerificationFailed(
                "the signing identity card is invalid"
            )
        }
    }

    private func removeOfficeDeliveryFiles(
        _ package: PDFOfficeDeliveryPackage
    ) {
        for fileName in [
            package.archiveFileName,
            package.reportFileName
        ].compactMap({ $0 })
            where isSafeOfficeDeliveryFileName(fileName) {
            try? fileManager.removeItem(
                at: officeDeliveriesURL
                    .appendingPathComponent(fileName)
            )
        }
    }

    private func isSafeOfficeDeliveryFileName(
        _ fileName: String
    ) -> Bool {
        !fileName.isEmpty
            && !fileName.hasPrefix(".")
            && !fileName.contains("/")
            && !fileName.contains("\\")
            && (fileName.hasSuffix(".zip")
                || fileName.hasSuffix(".json"))
    }

    private func officeDeliverySigningPrivateKey() throws
        -> Curve25519.Signing.PrivateKey {
        if let signingPrivateKeyProvider {
            return try signingPrivateKeyProvider()
        }
        let service =
            "com.monoware.paperpath.office-delivery-signing"
        let account = "ed25519-v1"
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] =
            kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            readQuery as CFDictionary,
            &item
        )
        if status == errSecSuccess {
            if let data = item as? Data,
               let key = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: data
               ) {
                return key
            }
            SecItemDelete(baseQuery as CFDictionary)
        } else if status != errSecItemNotFound {
            throw PaperPathError.storageFailure(
                "The local delivery signing identity is unavailable."
            )
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: privateKey.rawRepresentation
        ]
        let addStatus = SecItemAdd(
            addQuery as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw PaperPathError.storageFailure(
                "The local delivery signing identity could not be saved."
            )
        }
        return privateKey
    }

    private func officeDeliverySigningKeyID(
        publicKeyData: Data
    ) -> String {
        SHA256.hash(data: publicKeyData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func pruneOfficeExports(
        for records: [DocumentRecord]
    ) {
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        guard let directories = try? fileManager.contentsOfDirectory(
            at: officeExportsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for directory in directories {
            guard let recordID = UUID(
                uuidString: directory.lastPathComponent
            ),
                  let record = recordsByID[recordID]
            else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            pruneOfficeExportDirectory(for: record)
        }
    }

    private func pruneOfficeExportDirectory(
        for record: DocumentRecord
    ) {
        let directory = officeExportDirectory(for: record.id)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }
        let retainedNames = Set(
            record.officeReceipts.compactMap { receipt -> String? in
                guard receipt.artifactAvailability(
                    for: record.contentRevisionID
                ) == .reusable,
                      let fileName = receipt.retainedFileName,
                      isSafeOfficeExportFileName(fileName)
                else {
                    return nil
                }
                return fileName
            }
        )
        for file in files where
            !retainedNames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func removeOfficeExports(
        for recordID: UUID
    ) throws {
        let directory = officeExportDirectory(for: recordID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func sidecarURLs(for recordID: UUID) -> [URL] {
        [
            textIndexURL(for: recordID),
            ocrResultURL(for: recordID),
            deliveryPreflightURL(for: recordID)
        ]
    }

    private func removeSidecars(for record: DocumentRecord) throws {
        for url in sidecarURLs(for: record.id) {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}

private extension JSONEncoder {
    static var paperPath: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var paperPath: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
