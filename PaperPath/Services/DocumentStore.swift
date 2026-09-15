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

struct DocumentStoreAnalysisSnapshot {
    let textIndices: [UUID: DocumentTextIndex]
    let ocrResults: [UUID: OCRResult]
}

struct DocumentStoreStorageInventory: Sendable {
    let snapshot: LocalStorageSnapshot
    let pinnedMilestones: [PDFVersionSnapshot]
    let changeReports: PDFRetainedChangeReportInventory
}

struct DocumentStoreTextSearchCandidate: Sendable {
    let recordID: UUID
    let metadataCorpus: String
    let pageCount: Int
    let hasAnalysis: Bool
    var contentRevisionID: UUID? = nil
}

struct DocumentStoreTextSearchSnapshot: Sendable {
    let matchingRecordIDs: Set<UUID>
    let matchesByRecordID: [UUID: [DocumentTextMatch]]
    let isLimited: Bool
    let hasTruncatedIndices: Bool
}

enum PDFMetadataSyncApplyError: Error {
    case localStateChanged
}

struct PreparedPDFWorkingCopy: Sendable {
    let recordID: UUID
    let sourceRevisionID: UUID
    let preparedURL: URL
    let restoredBookmarkedPages: [Int]?
    let restoredBookmarkNames: [Int: String]?
    let restoredLastPageIndex: Int?
    let restoredTaskCheckpoint: DocumentTaskCheckpoint?
    let restoresNavigationState: Bool
    let expectedFingerprint: String?
    let expectedPageCount: Int?

    init(
        recordID: UUID,
        sourceRevisionID: UUID,
        preparedURL: URL,
        restoredBookmarkedPages: [Int]? = nil,
        restoredBookmarkNames: [Int: String]? = nil,
        restoredLastPageIndex: Int? = nil,
        restoredTaskCheckpoint: DocumentTaskCheckpoint? = nil,
        restoresNavigationState: Bool = false,
        expectedFingerprint: String? = nil,
        expectedPageCount: Int? = nil
    ) {
        self.recordID = recordID
        self.sourceRevisionID = sourceRevisionID
        self.preparedURL = preparedURL
        self.restoredBookmarkedPages = restoredBookmarkedPages
        self.restoredBookmarkNames = restoredBookmarkNames
        self.restoredLastPageIndex = restoredLastPageIndex
        self.restoredTaskCheckpoint = restoredTaskCheckpoint
        self.restoresNavigationState = restoresNavigationState
        self.expectedFingerprint = expectedFingerprint
        self.expectedPageCount = expectedPageCount
    }
}

struct PreparedPDFWorkingCopyBatchResult: Sendable {
    let records: [DocumentRecord]
    let batesReceipt: PDFSignedBatesBatchReceipt?
}

struct PDFWorkingCopyTransactionJournal: Codable {
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

struct ProtectedDataTransactionJournal: Codable {
    struct Entry: Codable {
        let destinationPath: String
        let backupPath: String?
        let stagingPath: String
        let originalFingerprint: String?
        let stagedFingerprint: String
    }

    let id: UUID
    let createdAt: Date
    let entries: [Entry]
}

private struct PDFTrustedTimeCheckpoint: Codable {
    static let schema = "paperpath.trusted-time.v1"

    let schema: String
    let observedUnixSeconds: TimeInterval

    var date: Date? {
        guard schema == Self.schema,
              observedUnixSeconds.isFinite,
              observedUnixSeconds >= 0
        else {
            return nil
        }
        return Date(timeIntervalSince1970: observedUnixSeconds)
    }
}

private struct PDFManualPageMatchCorrectionStore: Codable {
    static let schema = "paperpath.page-match-corrections.v1"

    let schema: String
    let corrections: [PDFManualPageMatchCorrection]
}

private struct PDFRetainedChangeReportStore: Codable {
    static let schema = "paperpath.retained-change-reports.v1"

    let schema: String
    let reports: [PDFRetainedChangeReport]
}

actor DocumentStore {
    private static let maximumVersionDirectoryFileCount = 256
    private static let maximumStorageEnumerationCount = 100_000
    private static let maximumLibraryRecordCount = 50_000
    private static let maximumVersionRecordCount = 200_000
    private static let maximumVersionsPerDocument = 12
    private static let maximumVersionBytes: Int64 =
        1_024 * 1_024 * 1_024
    private static let maximumLibraryIndexBytes: Int64 =
        32 * 1_024 * 1_024
    private static let maximumVersionIndexBytes: Int64 =
        16 * 1_024 * 1_024
    private static let maximumTextIndexBytes: Int64 =
        64 * 1_024 * 1_024
    private static let maximumOCRResultBytes: Int64 =
        128 * 1_024 * 1_024
    private static let maximumBootstrapAnalysisRecords = 8
    private static let maximumBootstrapAnalysisBytes: Int64 =
        24 * 1_024 * 1_024
    private static let maximumPreflightCacheBytes: Int64 =
        4 * 1_024 * 1_024
    private static let maximumLoadedPreflightCacheEntries = 64
    private static let maximumLoadedPreflightCacheBytes: Int64 =
        16 * 1_024 * 1_024
    private static let maximumPersistedStateBytes: Int64 =
        8 * 1_024 * 1_024
    private static let maximumTrustedSignerBytes: Int64 =
        1 * 1_024 * 1_024
    private static let maximumTrustedSignerVerificationCount = 1_000_000
    private static let maximumRecoveryJournalBytes: Int64 =
        1 * 1_024 * 1_024
    private static let maximumDeepInspectionBytes: Int64 =
        128 * 1_024 * 1_024
    private static let maximumPinnedOfficeExportsPerDocument = 4
    private static let maximumPinnedOfficeExportBytes: Int64 =
        512 * 1_024 * 1_024
    private static let maximumOfficeDeliveryPackages = 8
    private static let maximumPinnedOfficeDeliveryPackages = 4
    private static let trustedTimeCheckpointService =
        "com.monoware.paperpath.trusted-time"
    private static let trustedTimeCheckpointAccount =
        "high-water-v1"
    private static let maximumTrustedTimeCheckpointBytes = 512
    private static let trustedTimeCheckpointInterval:
        TimeInterval = 5 * 60
    private static let maximumPageMatchCorrectionBytes =
        PDFManualPageMatchStorageSummary.maximumByteCount
    private static let maximumPageMatchCorrectionCount =
        PDFManualPageMatchStorageSummary.maximumCorrectionCount
    private static let maximumRetainedChangeReportIndexBytes: Int64 =
        1 * 1_024 * 1_024

    private let rootURL: URL
    private let filesURL: URL
    private let versionsURL: URL
    private let indicesURL: URL
    private let ocrURL: URL
    private let preflightURL: URL
    private let officeExportsURL: URL
    private let officeDeliveriesURL: URL
    private let changeReportsURL: URL
    private let indexURL: URL
    private let versionsIndexURL: URL
    private let batchDeliveryURL: URL
    private let officeProductionQueueURL: URL
    private let officeDeliveryIndexURL: URL
    private let officeTrustedSignersURL: URL
    private let batesBatchReceiptsURL: URL
    private let pageMatchCorrectionsURL: URL
    private let retainedChangeReportsIndexURL: URL
    private let workingCopyTransactionJournalURL: URL
    private let protectedDataTransactionJournalURL: URL
    private let fileManager: FileManager
    private let inspector: PDFInspectionService
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let signingPrivateKeyProvider:
        (@Sendable () throws -> Curve25519.Signing.PrivateKey)?
    private let officeTimeAnchor: PDFOfficeTimeAnchor
    private let persistsTrustedTimeCheckpoint: Bool
    private var didRecoverInterruptedWorkingCopyTransaction = false
    private var didRecoverInterruptedProtectedDataTransaction = false
    private var didPruneOrphanedDocumentStagingFiles = false
    private var didRestoreTrustedTimeCheckpoint = false
    private var lastPersistedTrustedDate: Date?

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
            (@Sendable () throws -> Curve25519.Signing.PrivateKey)? = nil,
        officeTimeAnchor: PDFOfficeTimeAnchor = .process
    ) {
        self.fileManager = fileManager
        self.inspector = inspector
        self.availableCapacity = availableCapacity
        self.signingPrivateKeyProvider = signingPrivateKeyProvider
        self.officeTimeAnchor = officeTimeAnchor
        persistsTrustedTimeCheckpoint =
            rootURL == nil
            && officeTimeAnchor === PDFOfficeTimeAnchor.process

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
        self.changeReportsURL = baseURL.appendingPathComponent(
            "ChangeReports",
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
        self.pageMatchCorrectionsURL = baseURL.appendingPathComponent(
            "page-match-corrections.json"
        )
        self.retainedChangeReportsIndexURL =
            baseURL.appendingPathComponent(
                "change-reports.json"
            )
        self.workingCopyTransactionJournalURL =
            baseURL.appendingPathComponent(
                "active-working-copy-transaction.json"
            )
        self.protectedDataTransactionJournalURL =
            baseURL.appendingPathComponent(
                "active-protected-data-transaction.json"
            )
    }

    func loadBootstrapSnapshot() throws
        -> DocumentStoreBootstrapSnapshot {
        _ = currentTrustedDate()
        let records = try loadExistingRecords()
        do {
            _ = try reconcileVersionStorage()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Version cleanup must not block access to the document library.
        }
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
            active.map { ($0.id, url(for: $0)) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let bootstrapAnalysisRecords = bootstrapAnalysisRecords(
            from: active
        )
        return DocumentStoreBootstrapSnapshot(
            documents: active,
            deletedDocuments: deleted,
            documentURLs: urls,
            textIndices: try loadTextIndices(
                for: bootstrapAnalysisRecords
            ),
            ocrResults: try loadOCRResults(
                for: bootstrapAnalysisRecords
            ),
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

    func pageMatchCorrection(
        context: PDFManualPageMatchCorrectionContext,
        sourceDocumentID: UUID,
        sourceRevisionID: UUID,
        revisedDocumentID: UUID,
        revisedRevisionID: UUID,
        versionSnapshotID: UUID?,
        sourcePageCount: Int,
        revisedPageCount: Int
    ) throws -> PDFManualPageMatchCorrectionLookup {
        try Task.checkCancellation()
        try prepareDirectories()
        let loaded = try loadPageMatchCorrections()
        let identities = pageMatchCorrectionIdentities(
            context: context,
            sourceDocumentID: sourceDocumentID,
            revisedDocumentID: revisedDocumentID,
            versionSnapshotID: versionSnapshotID
        )
        let hadSavedCorrection = loaded.contains {
            identities.contains($0.comparisonIdentity)
        }
        let retained = try reconciledPageMatchCorrections(
            loaded: loaded
        )
        let retainsSavedCorrection = retained.contains {
            identities.contains($0.comparisonIdentity)
        }
        let directCorrection = retained.first {
            $0.context == context
                && $0.sourceDocumentID == sourceDocumentID
                && $0.sourceRevisionID == sourceRevisionID
                && $0.revisedDocumentID == revisedDocumentID
                && $0.revisedRevisionID == revisedRevisionID
                && $0.versionSnapshotID == versionSnapshotID
                && $0.sourcePageCount == sourcePageCount
                && $0.revisedPageCount == revisedPageCount
        }
        let reversedCorrection =
            context == .documentPair && directCorrection == nil
                ? retained.first {
                    $0.context == .documentPair
                        && $0.sourceDocumentID == revisedDocumentID
                        && $0.sourceRevisionID == revisedRevisionID
                        && $0.revisedDocumentID == sourceDocumentID
                        && $0.revisedRevisionID == sourceRevisionID
                        && $0.versionSnapshotID == nil
                        && $0.sourcePageCount == revisedPageCount
                        && $0.revisedPageCount == sourcePageCount
                }?.reversedDocumentPair()
                : nil
        let correction = directCorrection ?? reversedCorrection
        return PDFManualPageMatchCorrectionLookup(
            correction: correction,
            discardedStaleCorrection:
                hadSavedCorrection && !retainsSavedCorrection
        )
    }

    @discardableResult
    func savePageMatchCorrection(
        _ correction: PDFManualPageMatchCorrection
    ) throws -> Int {
        try Task.checkCancellation()
        try prepareDirectories()
        let trustedDate = currentTrustedDate()
        let savedCorrection = PDFManualPageMatchCorrection(
            context: correction.context,
            sourceDocumentID: correction.sourceDocumentID,
            sourceRevisionID: correction.sourceRevisionID,
            revisedDocumentID: correction.revisedDocumentID,
            revisedRevisionID: correction.revisedRevisionID,
            versionSnapshotID: correction.versionSnapshotID,
            sourcePageCount: correction.sourcePageCount,
            revisedPageCount: correction.revisedPageCount,
            matches: correction.matches,
            updatedAt: trustedDate
        )
        guard savedCorrection.isStructurallyValid(
            at: trustedDate
        ) else {
            throw PaperPathError.insufficientSelection(
                "The corrected page matches are no longer valid."
            )
        }
        var corrections = try reconciledPageMatchCorrections()
        let identities = pageMatchCorrectionIdentities(
            context: savedCorrection.context,
            sourceDocumentID: savedCorrection.sourceDocumentID,
            revisedDocumentID: savedCorrection.revisedDocumentID,
            versionSnapshotID: savedCorrection.versionSnapshotID
        )
        corrections.removeAll {
            identities.contains($0.comparisonIdentity)
        }
        let retainedExistingCount = corrections.count
        corrections.append(savedCorrection)
        let bounded = boundedPageMatchCorrections(
            corrections,
            at: trustedDate
        )
        guard bounded.contains(savedCorrection) else {
            throw PaperPathError.storageFailure(
                "The corrected page matches exceed the local storage limit."
            )
        }
        try savePageMatchCorrections(bounded)
        let survivingExistingCount = bounded.reduce(
            into: 0
        ) { count, candidate in
            guard candidate != savedCorrection else { return }
            count += 1
        }
        return max(
            0,
            retainedExistingCount - survivingExistingCount
        )
    }

    func removePageMatchCorrection(
        context: PDFManualPageMatchCorrectionContext,
        sourceDocumentID: UUID,
        revisedDocumentID: UUID,
        versionSnapshotID: UUID?
    ) throws {
        try Task.checkCancellation()
        var corrections = try reconciledPageMatchCorrections()
        let identities = pageMatchCorrectionIdentities(
            context: context,
            sourceDocumentID: sourceDocumentID,
            revisedDocumentID: revisedDocumentID,
            versionSnapshotID: versionSnapshotID
        )
        let originalCount = corrections.count
        corrections.removeAll {
            identities.contains($0.comparisonIdentity)
        }
        guard corrections.count != originalCount else { return }
        try savePageMatchCorrections(corrections)
    }

    @discardableResult
    func clearPageMatchCorrections() throws -> Int {
        try Task.checkCancellation()
        try prepareDirectories()
        let corrections = try reconciledPageMatchCorrections()
        try Task.checkCancellation()
        guard fileManager.fileExists(
            atPath: pageMatchCorrectionsURL.path
        ) else {
            return corrections.count
        }
        try savePageMatchCorrections([])
        return corrections.count
    }

    func retainedChangeReports() throws
        -> [PDFRetainedChangeReport] {
        try reconciledRetainedChangeReports()
    }

    func retainedChangeReportInventory() throws
        -> PDFRetainedChangeReportInventory {
        try Task.checkCancellation()
        let reports = try reconciledRetainedChangeReports()
        let records = try loadIndex()
        let versions = try loadVersionIndex()
        var recordsByID: [UUID: DocumentRecord] = [:]
        for record in records
        where recordsByID[record.id] == nil {
            recordsByID[record.id] = record
        }
        var versionsByID: [UUID: PDFVersionSnapshot] = [:]
        for version in versions
        where versionsByID[version.id] == nil {
            versionsByID[version.id] = version
        }
        var healthByReportID:
            [UUID: PDFRetainedChangeReportLinkHealthStatus] = [:]
        healthByReportID.reserveCapacity(reports.count)
        for report in reports {
            try Task.checkCancellation()
            healthByReportID[report.id] =
                retainedChangeReportLinkHealth(
                    report,
                    recordsByID: recordsByID,
                    versionsByID: versionsByID
                )
        }
        return PDFRetainedChangeReportInventory(
            reports: reports,
            linkHealthByReportID: healthByReportID
        )
    }

    func currentDocumentMatches(
        recordID: UUID,
        revisionID: UUID,
        sha256: String
    ) throws -> Bool {
        try Task.checkCancellation()
        try prepareDirectories()
        guard let record = try loadIndex().first(
            where: {
                $0.id == recordID
                    && $0.deletedAt == nil
            }
        ),
              record.contentRevisionID == revisionID,
              let storedFingerprint = record.contentFingerprint,
              storedFingerprint.caseInsensitiveCompare(sha256)
                == .orderedSame
        else { return false }
        let url = url(for: record)
        guard isSafeRegularFile(
            at: url,
            containedIn: filesURL
        ) else { return false }
        return try fileFingerprint(at: url)
            .caseInsensitiveCompare(sha256) == .orderedSame
    }

    @discardableResult
    func retainChangeReport(
        at sourceURL: URL,
        localLink: PDFRetainedChangeReportLocalLink? = nil
    ) throws -> PDFRetainedChangeReport {
        try Task.checkCancellation()
        try prepareDirectories()
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: PDFRetainedChangeReport.maximumReportBytes
        )
        guard !data.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "Choose a non-empty signed PaperPath change report."
            )
        }

        let verificationURL = try protectedTemporaryFile(
            directoryPrefix: "PaperPath-ChangeReport-Verify-",
            fileName: "report.md"
        )
        defer {
            try? fileManager.removeItem(
                at: verificationURL.deletingLastPathComponent()
            )
        }
        try writeProtectedData(data, to: verificationURL)
        let verification = try verifyChangeReport(
            at: verificationURL
        )
        guard verification.isVerified else {
            throw PaperPathError.outputVerificationFailed(
                "the change report signature is not valid"
            )
        }
        try Task.checkCancellation()
        let retainedLocalLink: PDFRetainedChangeReportLocalLink?
        if let localLink,
           localLink.isStructurallyValid,
           localLink.matches(verification) {
            retainedLocalLink = localLink
        } else {
            retainedLocalLink = nil
        }

        let retainedAt = currentTrustedDate()
        let sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let report = PDFRetainedChangeReport(
            id: verification.reportID,
            fileName: "\(verification.reportID.uuidString).md",
            sourceName: verification.sourceName,
            revisedName: verification.revisedName,
            generatedAt: verification.generatedAt,
            retainedAt: retainedAt,
            changedPageCount: verification.changedPageCount,
            deliveryReceiptID: verification.deliveryReceiptID,
            signerKeyID: verification.keyID,
            byteCount: Int64(data.count),
            sha256: sha256,
            localLink: retainedLocalLink
        )
        guard report.isStructurallyValid(at: retainedAt) else {
            throw PaperPathError.outputVerificationFailed(
                "the change report metadata is invalid"
            )
        }

        var reports = try reconciledRetainedChangeReports()
        reports.removeAll { $0.id == report.id }
        let summary = PDFRetainedChangeReportStorageSummary.measuring(
            reports
        )
        guard summary.canAdd(bytes: report.byteCount) else {
            throw PaperPathError.insufficientSelection(
                "The signed report vault keeps up to 24 reports and 64 MB. Delete an older report before retaining another."
            )
        }
        reports.append(report)
        reports.sort(by: retainedChangeReportSortsBefore)

        let destination = retainedChangeReportURL(for: report)
        try writeProtectedDataTransaction(
            [
                (data: data, destination: destination),
                (
                    data: try encodedRetainedChangeReports(reports),
                    destination: retainedChangeReportsIndexURL
                )
            ]
        )
        excludeFromBackup(destination)
        excludeFromBackup(retainedChangeReportsIndexURL)
        guard try fileFingerprint(at: destination)
                .caseInsensitiveCompare(report.sha256)
                == .orderedSame
        else {
            throw PaperPathError.outputVerificationFailed(
                "the retained change report did not match its committed digest"
            )
        }
        pruneOrphanedRetainedChangeReportFiles(retaining: reports)
        return report
    }

    func verifyRetainedChangeReport(
        id: UUID
    ) throws -> PDFChangeReportVerificationResult {
        try Task.checkCancellation()
        let reports = try reconciledRetainedChangeReports()
        guard let report = reports.first(where: { $0.id == id }) else {
            throw PaperPathError.insufficientSelection(
                "This retained change report is no longer available."
            )
        }
        let url = retainedChangeReportURL(for: report)
        guard logicalFileSize(url) == report.byteCount,
              try fileFingerprint(at: url)
                .caseInsensitiveCompare(report.sha256) == .orderedSame
        else {
            throw PaperPathError.outputVerificationFailed(
                "the retained change report no longer matches its saved SHA-256"
            )
        }
        let verification = try verifyChangeReport(at: url)
        guard verification.reportID == report.id,
              verification.sourceName == report.sourceName,
              verification.revisedName == report.revisedName,
              verification.generatedAt == report.generatedAt,
              verification.changedPageCount == report.changedPageCount,
              verification.deliveryReceiptID == report.deliveryReceiptID,
              verification.keyID == report.signerKeyID
        else {
            throw PaperPathError.outputVerificationFailed(
                "the retained change report no longer matches its private index"
            )
        }
        return verification
    }

    func prepareRetainedChangeReportShareCopy(
        id: UUID,
        fileName: String
    ) throws -> URL {
        let verification = try verifyRetainedChangeReport(id: id)
        guard verification.isVerified else {
            throw PaperPathError.outputVerificationFailed(
                "the retained change report signature is not valid"
            )
        }
        let reports = try reconciledRetainedChangeReports()
        guard let report = reports.first(where: { $0.id == id }),
              (fileName as NSString).pathExtension.lowercased() == "md",
              paperPathArchiveLeafNameIdentity(fileName) != nil
        else {
            throw PaperPathError.insufficientSelection(
                "The retained change report share name is invalid."
            )
        }
        let source = retainedChangeReportURL(for: report)
        let data = try boundedData(
            at: source,
            maximumBytes: PDFRetainedChangeReport.maximumReportBytes
        )
        let destination = try protectedTemporaryFile(
            directoryPrefix: "PaperPath-ChangeReport-",
            fileName: fileName
        )
        do {
            try writeProtectedData(data, to: destination)
            excludeFromBackup(
                destination.deletingLastPathComponent()
            )
            guard logicalFileSize(destination) == report.byteCount,
                  try fileFingerprint(at: destination)
                    .caseInsensitiveCompare(report.sha256)
                    == .orderedSame
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the temporary change report share copy did not match its saved SHA-256"
                )
            }
            return destination
        } catch {
            try? fileManager.removeItem(
                at: destination.deletingLastPathComponent()
            )
            throw error
        }
    }

    @discardableResult
    func removeRetainedChangeReport(
        id: UUID
    ) throws -> Bool {
        try Task.checkCancellation()
        var reports = try reconciledRetainedChangeReports()
        guard let removed = reports.first(where: { $0.id == id }) else {
            return false
        }
        reports.removeAll { $0.id == id }
        try writeProtectedData(
            try encodedRetainedChangeReports(reports),
            to: retainedChangeReportsIndexURL
        )
        excludeFromBackup(retainedChangeReportsIndexURL)
        try Task.checkCancellation()
        let url = retainedChangeReportURL(for: removed)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        pruneOrphanedRetainedChangeReportFiles(retaining: reports)
        return true
    }

    func importPDF(
        from sourceURL: URL,
        preferredName: String? = nil,
        deliveryReceipt: PDFDeliveryReceipt? = nil,
        sourceDocumentID: UUID? = nil,
        contentRevisionID: UUID? = nil,
        preserveSourceLocation: Bool = true,
        expectedSHA256: String? = nil,
        expectedByteCount: Int64? = nil,
        expectedPageCount: Int? = nil,
        sharedImportID: UUID? = nil,
        progress: @escaping PDFImportProgressHandler = { _ in }
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        progress(
            PDFImportProgressUpdate(
                stage: .preparing,
                fractionCompleted: 0
            )
        )
        try prepareDirectories()
        let trustedDate = currentTrustedDate()
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
            guard (expectedSHA256 == nil)
                    == (expectedByteCount == nil),
                  expectedPageCount == nil
                    || expectedSHA256 != nil,
                  sharedImportID == nil || expectedSHA256 != nil
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the shared import integrity checkpoint is incomplete"
                )
            }
            let sourceIdentityKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
            let sourceValues = try sourceURL.resourceValues(
                forKeys: sourceIdentityKeys
            )
            guard sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true,
                  let rawSourceByteCount = sourceValues.fileSize,
                  rawSourceByteCount > 0
            else {
                throw PaperPathError.unreadablePDF
            }
            let sourceByteCount = Int64(rawSourceByteCount)
            if let expectedByteCount,
               sourceByteCount != expectedByteCount {
                throw PaperPathError.outputVerificationFailed(
                    "the shared PDF size changed before import"
                )
            }
            if let expectedSHA256,
               !isValidVersionFingerprint(expectedSHA256) {
                throw PaperPathError.outputVerificationFailed(
                    "the shared PDF integrity checkpoint is invalid"
                )
            }
            var records = try loadIndex()
            if let sharedImportID,
               let expectedSHA256,
               let existing = records.first(where: {
                   $0.deletedAt == nil
                       && $0.sharedImportID == sharedImportID
                       && $0.contentFingerprint?
                        .caseInsensitiveCompare(expectedSHA256)
                            == .orderedSame
                       && $0.profile.byteCount == expectedByteCount
                       && (
                        expectedPageCount == nil
                            || $0.profile.pageCount
                                == expectedPageCount
                       )
               }),
               (try? fileFingerprint(at: url(for: existing)))?
                .caseInsensitiveCompare(expectedSHA256) == .orderedSame {
                progress(
                    PDFImportProgressUpdate(
                        stage: .complete,
                        fractionCompleted: 1
                    )
                )
                return existing
            }
            try ensureCapacity(for: sourceURL)
            progress(
                PDFImportProgressUpdate(
                    stage: .copying,
                    fractionCompleted: 0.04,
                    totalBytes: sourceByteCount
                )
            )
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: destination,
                expectedByteCount: sourceByteCount
            ) { copiedByteCount in
                let copiedFraction = Double(copiedByteCount)
                    / Double(sourceByteCount)
                progress(
                    PDFImportProgressUpdate(
                        stage: .copying,
                        fractionCompleted:
                            0.04 + min(1, copiedFraction) * 0.66,
                        processedBytes: copiedByteCount,
                        totalBytes: sourceByteCount
                    )
                )
            }
            try Task.checkCancellation()
            let finalSourceValues = try uncachedResourceValues(
                at: sourceURL,
                forKeys: sourceIdentityKeys
            )
            progress(
                PDFImportProgressUpdate(
                    stage: .inspecting,
                    fractionCompleted: 0.70
                )
            )
            let destinationValues = try destination.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            guard finalSourceValues.isRegularFile == true,
                  finalSourceValues.isSymbolicLink != true,
                  finalSourceValues.fileSize == rawSourceByteCount,
                  finalSourceValues.contentModificationDate
                    == sourceValues.contentModificationDate,
                  fileResourceIdentifiersMatch(
                    sourceValues.fileResourceIdentifier,
                    finalSourceValues.fileResourceIdentifier
                  ),
                  destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  destinationValues.fileSize == rawSourceByteCount,
                  copiedFile.byteCount == sourceByteCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the source PDF changed while its private copy was created"
                )
            }
            let contentFingerprint = copiedFile.sha256
            if let expectedSHA256,
               contentFingerprint.caseInsensitiveCompare(
                expectedSHA256
               ) != .orderedSame {
                throw PaperPathError.outputVerificationFailed(
                    "the shared PDF changed after it entered PaperPath"
                )
            }
            let profile = try importedProfile(
                at: destination,
                copiedFile: copiedFile
            ) { inspectionFraction in
                progress(
                    PDFImportProgressUpdate(
                        stage: .inspecting,
                        fractionCompleted:
                            0.70
                                + min(
                                    1,
                                    max(0, inspectionFraction)
                                ) * 0.24
                    )
                )
            }
            if let expectedPageCount,
               profile.pageCount != expectedPageCount {
                throw PaperPathError.outputVerificationFailed(
                    "the shared PDF page count changed during import"
                )
            }
            try Task.checkCancellation()
            let resolvedRevisionID = contentRevisionID ?? UUID()
            if let deliveryReceipt {
                guard deliveryReceipt.isVerified(at: trustedDate),
                      deliveryReceipt.outputByteCount == sourceByteCount,
                      deliveryReceipt.outputPageCount == profile.pageCount,
                      deliveryReceipt.sha256.caseInsensitiveCompare(
                          contentFingerprint
                      ) == .orderedSame,
                      deliveryReceipt.outputRevisionID == nil
                        || deliveryReceipt.outputRevisionID
                            == resolvedRevisionID
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the delivery receipt does not match the imported PDF"
                    )
                }
            }
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
                contentRevisionID: resolvedRevisionID,
                profile: profile,
                deliveryReceipt: deliveryReceipt,
                sourceDocumentID: sourceDocumentID,
                sourceBookmarkData: sourceBookmark,
                sourceLocationName: preserveSourceLocation
                    ? normalizedName(sourceURL.lastPathComponent)
                    : nil,
                sourceImportedFingerprint: sourceFingerprint,
                contentFingerprint: contentFingerprint,
                sharedImportID: sharedImportID
            )
            records.append(record)
            try Task.checkCancellation()
            progress(
                PDFImportProgressUpdate(
                    stage: .saving,
                    fractionCompleted: 0.95
                )
            )
            try saveIndex(records)
            progress(
                PDFImportProgressUpdate(
                    stage: .complete,
                    fractionCompleted: 1
                )
            )
            return record
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func importVerifiedVersionArchiveArtifact(
        _ report: PDFVersionArchiveVerificationReport,
        itemID: UUID
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        let trustedDate = currentTrustedDate()
        guard report.archiveCreatedAt.timeIntervalSince1970.isFinite,
              report.archiveCreatedAt.timeIntervalSince1970 >= 0,
              report.archiveCreatedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.verifiedAt <= trustedDate.addingTimeInterval(5 * 60),
              report.canRecoverArtifacts,
              let artifact = report.verifiedArtifact(for: itemID),
              artifact.item.status == .verified,
              let actualSHA256 = artifact.item.actualSHA256,
              actualSHA256.caseInsensitiveCompare(
                artifact.item.expectedSHA256
              ) == .orderedSame,
              artifact.url.lastPathComponent == artifact.item.fileName,
              isVerifiedVersionArchiveArtifactReference(artifact.url)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the verified milestone is no longer available"
            )
        }

        let values = try artifact.url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == artifact.item.byteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the verified milestone changed before recovery"
            )
        }

        return try importPDF(
            from: artifact.url,
            preferredName: artifact.item.title,
            sourceDocumentID: artifact.item.documentID,
            preserveSourceLocation: false,
            expectedSHA256: artifact.item.expectedSHA256,
            expectedByteCount: artifact.item.byteCount,
            expectedPageCount: artifact.item.pageCount,
            sharedImportID: artifact.item.id
        )
    }

    func importVerifiedDeliveryArtifact(
        _ report: PDFDeliveryPackageVerificationReport
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()
        let trustedDate = currentTrustedDate()
        guard report.packageCreatedAt.timeIntervalSince1970.isFinite,
              report.packageCreatedAt.timeIntervalSince1970 >= 0,
              report.packageCreatedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.verifiedAt <= trustedDate.addingTimeInterval(5 * 60),
              report.status == .verified,
              report.canOpenArtifact,
              let sourceURL = report.verifiedArtifactURL,
              let actualSHA256 = report.actualSHA256,
              actualSHA256.caseInsensitiveCompare(
                report.expectedSHA256
              ) == .orderedSame,
              sourceURL.lastPathComponent == report.artifactFileName,
              isVerifiedDeliveryArtifactReference(sourceURL)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the verified package artifact is no longer available"
            )
        }

        let sourceValues = try sourceURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              Int64(sourceValues.fileSize ?? -1)
                == report.artifactByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the verified PDF changed before import"
            )
        }
        var records = try loadIndex()
        if let existing = records.first(where: {
            $0.deletedAt == nil
                && $0.receivedPackageProvenance?.packageID
                    == report.packageID
                && $0.contentFingerprint?.caseInsensitiveCompare(
                    report.expectedSHA256
                ) == .orderedSame
                && $0.profile.byteCount == report.artifactByteCount
                && $0.profile.pageCount == report.artifactPageCount
        }),
           (try? fileFingerprint(at: url(for: existing)))?
            .caseInsensitiveCompare(report.expectedSHA256) == .orderedSame {
            return existing
        }

        try Task.checkCancellation()
        try ensureCapacity(for: sourceURL)
        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = filesURL.appendingPathComponent(fileName)
        do {
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: destination,
                expectedByteCount: report.artifactByteCount
            )
            let profile = try importedProfile(
                at: destination,
                copiedFile: copiedFile
            )
            try Task.checkCancellation()
            let destinationFingerprint = copiedFile.sha256
            guard destinationFingerprint.caseInsensitiveCompare(
                report.expectedSHA256
            ) == .orderedSame,
                  profile.byteCount == report.artifactByteCount,
                  profile.pageCount == report.artifactPageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the imported private copy did not match the verified PDF"
                )
            }

            let record = DocumentRecord(
                id: id,
                displayName: normalizedName(
                    sourceURL.deletingPathExtension().lastPathComponent
                ),
                fileName: fileName,
                contentRevisionID: UUID(),
                profile: profile,
                sourceBookmarkData: nil,
                sourceLocationName: nil,
                sourceImportedFingerprint: nil,
                contentFingerprint: destinationFingerprint,
                receivedPackageProvenance:
                    PDFReceivedPackageProvenance(
                        report: report,
                        importedAt: currentTrustedDate()
                    )
            )
            records.append(record)
            try Task.checkCancellation()
            try saveIndex(records)
            return record
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func prepareVerifiedDeliveryArtifactShareCopy(
        _ report: PDFDeliveryPackageVerificationReport,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> URL {
        try Task.checkCancellation()
        let trustedDate = currentTrustedDate()
        guard report.packageCreatedAt.timeIntervalSince1970.isFinite,
              report.packageCreatedAt.timeIntervalSince1970 >= 0,
              report.packageCreatedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.verifiedAt.timeIntervalSince1970.isFinite,
              report.verifiedAt.timeIntervalSince1970 >= 0,
              report.verifiedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.status == .verified,
              report.canOpenArtifact,
              let sourceURL = report.verifiedArtifactURL,
              let actualSHA256 = report.actualSHA256,
              actualSHA256.caseInsensitiveCompare(
                report.expectedSHA256
              ) == .orderedSame,
              isValidVersionFingerprint(report.expectedSHA256),
              sourceURL.lastPathComponent == report.artifactFileName,
              isSafeDocumentFileName(report.artifactFileName),
              isVerifiedDeliveryArtifactReference(sourceURL)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the verified package artifact is no longer available"
            )
        }

        let identityKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        let sourceValues = try sourceURL.resourceValues(
            forKeys: identityKeys
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              Int64(sourceValues.fileSize ?? -1)
                == report.artifactByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the verified PDF changed before sharing"
            )
        }

        try ensureCapacity(for: sourceURL)
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-FilesExport-\(UUID().uuidString)",
                isDirectory: true
            )
        let destination = directory.appendingPathComponent(
            report.artifactFileName
        )
        let (totalWorkBytes, didOverflow) = report.artifactByteCount
            .multipliedReportingOverflow(by: 2)
        let progressTotal = didOverflow ? Int64.max : totalWorkBytes
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory,
            fileManager: fileManager
        )
        do {
            progress(
                PDFByteProgressUpdate(
                    stage: .checksumming,
                    processedBytes: 0,
                    totalBytes: progressTotal,
                    totalUnitCount: 2,
                    currentUnitName: report.artifactFileName
                )
            )
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: destination,
                expectedByteCount: report.artifactByteCount
            ) { copiedBytes in
                progress(
                    PDFByteProgressUpdate(
                        stage: .checksumming,
                        processedBytes: copiedBytes,
                        totalBytes: progressTotal,
                        completedUnitCount:
                            copiedBytes == report.artifactByteCount ? 1 : 0,
                        totalUnitCount: 2,
                        currentUnitName: report.artifactFileName
                    )
                )
            }
            try Task.checkCancellation()
            let finalSourceValues = try uncachedResourceValues(
                at: sourceURL,
                forKeys: identityKeys
            )
            let destinationValues = try destination.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            let destinationFingerprint = try fileFingerprint(
                at: destination
            ) { processedBytes, _ in
                progress(
                    PDFByteProgressUpdate(
                        stage: .verifying,
                        processedBytes: min(
                            progressTotal,
                            report.artifactByteCount + processedBytes
                        ),
                        totalBytes: progressTotal,
                        completedUnitCount:
                            processedBytes == report.artifactByteCount
                                ? 2
                                : 1,
                        totalUnitCount: 2,
                        currentUnitName: report.artifactFileName
                    )
                )
            }
            let profile = try importedProfile(
                at: destination,
                copiedFile: copiedFile
            )
            try Task.checkCancellation()
            guard finalSourceValues.isRegularFile == true,
                  finalSourceValues.isSymbolicLink != true,
                  Int64(finalSourceValues.fileSize ?? -1)
                    == report.artifactByteCount,
                  finalSourceValues.contentModificationDate
                    == sourceValues.contentModificationDate,
                  fileResourceIdentifiersMatch(
                    sourceValues.fileResourceIdentifier,
                    finalSourceValues.fileResourceIdentifier
                  ),
                  destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  Int64(destinationValues.fileSize ?? -1)
                    == report.artifactByteCount,
                  copiedFile.byteCount == report.artifactByteCount,
                  copiedFile.sha256.caseInsensitiveCompare(
                    report.expectedSHA256
                  ) == .orderedSame,
                  destinationFingerprint.caseInsensitiveCompare(
                    report.expectedSHA256
                  ) == .orderedSame,
                  profile.byteCount == report.artifactByteCount,
                  profile.pageCount == report.artifactPageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the PDF changed or no longer matches its signed Receipt"
                )
            }
            return destination
        } catch {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: directory,
                allowedPrefixes: ["PaperPath-FilesExport-"],
                fileManager: fileManager
            )
            throw error
        }
    }

    func prepareFilesExportCopy(
        recordID: UUID,
        expectedRevisionID: UUID,
        fileName: String,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> URL {
        try Task.checkCancellation()
        try prepareDirectories()
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-FilesExport-\(UUID().uuidString)",
                isDirectory: true
            )
        let destinationURL = parent.appendingPathComponent(fileName)
        guard let managed =
                PaperPathTemporaryArtifact.managedTopLevelItem(
                    containing: destinationURL,
                    allowedPrefixes: ["PaperPath-FilesExport-"],
                    fileManager: fileManager
                ),
              managed == parent
                .resolvingSymlinksInPath()
                .standardizedFileURL
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Files export destination is not managed by PaperPath"
            )
        }
        guard isSafeDocumentFileName(
            destinationURL.lastPathComponent
        ),
              destinationURL.pathExtension.lowercased() == "pdf"
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Files export name is invalid"
            )
        }
        guard !fileManager.fileExists(atPath: parent.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Files export destination already exists"
            )
        }
        guard let record = try loadIndex().first(where: {
            $0.id == recordID && $0.deletedAt == nil
        }) else {
            throw PaperPathError.outputVerificationFailed(
                "the Files export source is no longer available"
            )
        }
        guard record.contentRevisionID == expectedRevisionID else {
            throw PaperPathError.outputVerificationFailed(
                "the Files export source changed before export"
            )
        }

        let sourceURL = url(for: record)
        let identityKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        let sourceValues = try sourceURL.resourceValues(
            forKeys: identityKeys
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let rawSourceByteCount = sourceValues.fileSize,
              rawSourceByteCount > 0,
              Int64(rawSourceByteCount) == record.profile.byteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the working PDF no longer matches its library record"
            )
        }
#if DEBUG
        // #region debug-point F:files-export-store-capacity
        reportFrequentUIFreezeDebugEvent(
            hypothesisID: "F",
            location: "DocumentStore.prepareFilesExportCopy",
            message: "Files export source verified",
            data: [
                "recordID": recordID.uuidString,
                "sourceBytes": String(rawSourceByteCount),
                "recordBytes": String(record.profile.byteCount),
                "availableCapacity": String(
                    availableCapacity(rootURL) ?? -1
                ),
                "parentExists": String(
                    fileManager.fileExists(atPath: parent.path)
                )
            ]
        )
        // #endregion
#endif
        try ensureCapacity(for: sourceURL)
        let (totalWorkBytes, didOverflow) = Int64(rawSourceByteCount)
            .multipliedReportingOverflow(by: 2)
        let progressTotal = didOverflow ? Int64.max : totalWorkBytes
        progress(
            PDFByteProgressUpdate(
                stage: .checksumming,
                processedBytes: 0,
                totalBytes: progressTotal,
                totalUnitCount: 2,
                currentUnitName: record.displayName
            )
        )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: parent,
            fileManager: fileManager
        )
#if DEBUG
        // #region debug-point F:files-export-directory-ready
        reportFrequentUIFreezeDebugEvent(
            hypothesisID: "F",
            location: "DocumentStore.prepareFilesExportCopy",
            message: "Files export directory ready",
            data: [
                "recordID": recordID.uuidString,
                "parentExists": String(
                    fileManager.fileExists(atPath: parent.path)
                )
            ]
        )
        // #endregion
#endif
        do {
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: destinationURL,
                expectedByteCount: Int64(rawSourceByteCount)
            ) { copiedBytes in
                progress(
                    PDFByteProgressUpdate(
                        stage: .checksumming,
                        processedBytes: copiedBytes,
                        totalBytes: progressTotal,
                        completedUnitCount:
                            copiedBytes == Int64(rawSourceByteCount) ? 1 : 0,
                        totalUnitCount: 2,
                        currentUnitName: record.displayName
                    )
                )
            }
            try Task.checkCancellation()
            let finalSourceValues = try uncachedResourceValues(
                at: sourceURL,
                forKeys: identityKeys
            )
            let destinationValues = try destinationURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            let destinationFingerprint = try fileFingerprint(
                at: destinationURL
            ) { processedBytes, _ in
                progress(
                    PDFByteProgressUpdate(
                        stage: .verifying,
                        processedBytes: min(
                            progressTotal,
                            Int64(rawSourceByteCount) + processedBytes
                        ),
                        totalBytes: progressTotal,
                        completedUnitCount:
                            processedBytes == Int64(rawSourceByteCount)
                                ? 2
                                : 1,
                        totalUnitCount: 2,
                        currentUnitName: record.displayName
                    )
                )
            }
            let profile = try importedProfile(
                at: destinationURL,
                copiedFile: copiedFile
            )
            let fingerprintMatchesRecord =
                record.contentFingerprint.map {
                    $0.caseInsensitiveCompare(copiedFile.sha256)
                        == .orderedSame
                } ?? true
            guard finalSourceValues.isRegularFile == true,
                  finalSourceValues.isSymbolicLink != true,
                  finalSourceValues.fileSize == rawSourceByteCount,
                  finalSourceValues.contentModificationDate
                    == sourceValues.contentModificationDate,
                  fileResourceIdentifiersMatch(
                    sourceValues.fileResourceIdentifier,
                    finalSourceValues.fileResourceIdentifier
                  ),
                  destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  destinationValues.fileSize == rawSourceByteCount,
                  copiedFile.byteCount == Int64(rawSourceByteCount),
                  destinationFingerprint.caseInsensitiveCompare(
                    copiedFile.sha256
                  ) == .orderedSame,
                  fingerprintMatchesRecord,
                  profile.byteCount == record.profile.byteCount,
                  profile.pageCount == record.profile.pageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Files export copy did not match the working PDF"
                )
            }
#if DEBUG
            // #region debug-point F:files-export-store-succeeded
            reportFrequentUIFreezeDebugEvent(
                hypothesisID: "F",
                location: "DocumentStore.prepareFilesExportCopy",
                message: "Files export copy verified",
                data: [
                    "recordID": recordID.uuidString,
                    "copiedBytes": String(copiedFile.byteCount),
                    "destinationExists": String(
                        fileManager.fileExists(
                            atPath: destinationURL.path
                        )
                    )
                ]
            )
            // #endregion
#endif
            return destinationURL
        } catch {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: parent,
                allowedPrefixes: ["PaperPath-FilesExport-"],
                fileManager: fileManager
            )
            throw error
        }
    }

    func duplicate(_ record: DocumentRecord) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()

        let records = try loadIndex()
        guard let stored = records.first(where: {
            $0.id == record.id && $0.deletedAt == nil
        }) else {
            throw PaperPathError.storageFailure(
                "The document record is missing."
            )
        }
        let sourceURL = url(for: stored)
        let sourceByteCount = logicalFileSize(sourceURL)
        guard sourceByteCount > 0 else {
            throw PaperPathError.storageFailure(
                "The working copy size could not be verified."
            )
        }
        try ensureCapacity(for: sourceURL)

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = filesURL.appendingPathComponent(fileName)

        do {
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: destination,
                expectedByteCount: sourceByteCount
            )
            let sourceFingerprint = copiedFile.sha256
            let destinationValues = try destination.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  Int64(destinationValues.fileSize ?? -1)
                    == sourceByteCount,
                  copiedFile.byteCount == sourceByteCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the duplicated working copy did not match its source"
                )
            }
            let duplicatedProfile = try inspector.inspect(
                url: destination
            )

            let duplicated = DocumentRecord(
                id: id,
                displayName: duplicateName(
                    for: stored.displayName,
                    records: records
                ),
                fileName: fileName,
                importedAt: Date(),
                modifiedAt: Date(),
                contentRevisionID: UUID(),
                profile: duplicatedProfile,
                workflowStatus: stored.workflowStatus,
                isPinned: false,
                tags: stored.tags,
                bookmarkedPages: stored.bookmarkedPages,
                lastPageIndex: stored.lastPageIndex,
                lastViewedAt: Date(),
                completedActions: stored.completedActions,
                taskCheckpoint: nil,
                brief: stored.brief,
                deliveryReceipt: nil,
                sourceDocumentID: nil,
                sourceBookmarkData: nil,
                sourceLocationName: nil,
                sourceImportedFingerprint: nil,
                sourceWritebackAt: nil,
                contentFingerprint: sourceFingerprint,
                dueAt: stored.dueAt,
                privateNote: stored.privateNote,
                bookmarkNames: stored.bookmarkNames
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
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        guard let index = records.firstIndex(where: {
            $0.id == record.id
        }) else {
            throw PaperPathError.storageFailure(
                "The document record is missing."
            )
        }
        let stored = records[index]
        guard stored.deletedAt == nil,
              stored.contentRevisionID == record.contentRevisionID
        else {
            throw PaperPathError.insufficientSelection(
                "The working copy changed before its metadata was refreshed."
            )
        }
        let sourceURL = url(for: stored)
        let profile = try inspector.inspect(url: sourceURL)
        var updated = stored
        updated.profile = profile
        updated.lastPageIndex = min(
            max(updated.lastPageIndex, 0),
            max(0, profile.pageCount - 1)
        )
        updated.modifiedAt = Date()
        updated.contentRevisionID = UUID()
        updated.taskCheckpoint = updated.taskCheckpoint?
            .rebased(to: updated.contentRevisionID)
            .bounded(toPageCount: profile.pageCount)
        updated.contentFingerprint = try fileFingerprint(
            at: sourceURL
        )
        removeDeliveryPreflight(recordID: stored.id)
        if invalidateAnalysis {
            updated.brief = nil
            try? removeSidecars(for: stored)
        }
        records[index] = updated
        try saveIndex(records)
        return updated
    }

    func replaceWorkingCopies(
        with preparedCopies: [PreparedPDFWorkingCopy],
        invalidateAnalysis: Bool = false,
        requiresMatchingPageCount: Bool = false
    ) throws -> [DocumentRecord] {
        try commitWorkingCopies(
            preparedCopies,
            invalidateAnalysis: invalidateAnalysis,
            batesPlan: nil,
            batesRemovalReceiptID: nil,
            requiresMatchingPageCount: requiresMatchingPageCount
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
            batesRemovalReceiptID: nil,
            requiresMatchingPageCount: true
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
            batesRemovalReceiptID: receiptID,
            requiresMatchingPageCount: true
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
        batesRemovalReceiptID: UUID?,
        requiresMatchingPageCount: Bool,
        resetsCompletionEvidence: Bool = false
    ) throws -> PreparedPDFWorkingCopyBatchResult {
        try prepareDirectories()
        try recoverInterruptedWorkingCopyTransaction()
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
        var expectedFingerprintByDestination: [URL: String] = [:]
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
                  !requiresMatchingPageCount
                    || profile.pageCount == stored.profile.pageCount
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
            guard prepared.expectedFingerprint == nil
                    || prepared.expectedFingerprint == fingerprint,
                  prepared.expectedPageCount == nil
                    || prepared.expectedPageCount == profile.pageCount
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the selected recovery version changed before commit"
                )
            }

            var updated = stored
            updated.profile = profile
            updated.modifiedAt = now
            updated.contentRevisionID = UUID()
            updated.contentFingerprint = fingerprint
            updated.lastPageIndex = min(
                max(updated.lastPageIndex, 0),
                max(0, profile.pageCount - 1)
            )
            let requestedBookmarks = prepared.restoresNavigationState
                ? prepared.restoredBookmarkedPages ?? []
                : updated.bookmarkedPages
            updated.bookmarkedPages = requestedBookmarks.filter {
                $0 >= 0 && $0 < profile.pageCount
            }
            let validBookmarkPages = Set(updated.bookmarkedPages)
            let requestedBookmarkNames =
                prepared.restoresNavigationState
                    ? prepared.restoredBookmarkNames ?? [:]
                    : updated.bookmarkNames
            updated.bookmarkNames = requestedBookmarkNames.filter {
                validBookmarkPages.contains($0.key)
            }
            if prepared.restoresNavigationState,
               let restoredLastPageIndex =
                prepared.restoredLastPageIndex {
                updated.lastPageIndex = min(
                    max(restoredLastPageIndex, 0),
                    max(0, profile.pageCount - 1)
                )
            }
            let requestedCheckpoint = prepared.restoresNavigationState
                ? prepared.restoredTaskCheckpoint
                : updated.taskCheckpoint
            updated.taskCheckpoint = requestedCheckpoint?
                .rebased(to: updated.contentRevisionID)
                .bounded(toPageCount: profile.pageCount)
            if invalidateAnalysis {
                updated.brief = nil
            }
            if resetsCompletionEvidence {
                updated.completedActions = []
                updated.deliveryReceipt = nil
                updated.lastViewedAt = now
            }
            records[recordIndex] = updated
            updatedByID[updated.id] = updated
            sourceRecordsByID[stored.id] = stored
            expectedFingerprints[updated.id] = fingerprint
            expectedFingerprintByDestination[destination] = fingerprint
            sourceByDestination[destination] = prepared.preparedURL
        }
        guard sourceByDestination.count == preparedCopies.count else {
            throw PaperPathError.storageFailure(
                "The document batch contains duplicate destinations."
            )
        }

        let indexData = try encodedLibraryIndex(records)
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
        var backupFingerprintByDestination: [URL: String] = [:]
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
                stagingByDestination[destination] = staging
                let sourceByteCount = logicalFileSize(source)
                let copiedFile = try copyProtectedFile(
                    from: source,
                    to: staging,
                    expectedByteCount: sourceByteCount
                )
                guard copiedFile.sha256
                        == expectedFingerprintByDestination[destination]
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "a prepared PDF changed while the batch was staged"
                    )
                }
            }

            for write in metadataWrites {
                let staging = write.destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".batch-metadata-\(UUID().uuidString)",
                        isDirectory: false
                    )
                stagingByDestination[write.destination] = staging
                try write.data.write(to: staging, options: .atomic)
                try requireFileProtection(to: staging)
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
                backupByDestination[destination] = backup
                let copiedBackup = try copyProtectedFile(
                    from: destination,
                    to: backup,
                    expectedByteCount: logicalFileSize(destination)
                )
                backupFingerprintByDestination[destination] =
                    copiedBackup.sha256
            }

            guard backupByDestination.count == destinations.count else {
                throw PaperPathError.storageFailure(
                    "The PDF batch recovery set is incomplete."
                )
            }
            let journal = PDFWorkingCopyTransactionJournal(
                id: UUID(),
                createdAt: Date(),
                entries: destinations.compactMap { destination in
                    guard let backup =
                            backupByDestination[destination],
                          let staging =
                            stagingByDestination[destination],
                          let backupFingerprint =
                            backupFingerprintByDestination[destination]
                    else { return nil }
                    return PDFWorkingCopyTransactionJournal.Entry(
                        destinationPath:
                            destination.standardizedFileURL.path,
                        backupPath: backup.standardizedFileURL.path,
                        stagingPath: staging.standardizedFileURL.path,
                        backupFingerprint: backupFingerprint
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
                committedRecords.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
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
                        guard let backup = backupByDestination[destination],
                              let expected = backupFingerprintByDestination[destination]
                        else {
                            throw PaperPathError.storageFailure(
                                "The PDF batch recovery set is incomplete."
                            )
                        }
                        try restoreVerifiedWorkingCopyBackup(
                            from: backup,
                            to: destination,
                            expectedFingerprint: expected
                        )
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
                didRecoverInterruptedWorkingCopyTransaction = false
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
        try Task.checkCancellation()
        let requestedIDs = Set(records.map(\.id))
        var storedRecords = try loadIndex()
        var didChange = false
        for index in storedRecords.indices
        where requestedIDs.contains(storedRecords[index].id)
            && storedRecords[index].deletedAt == nil {
            try Task.checkCancellation()
            let existing = storedRecords[index].contentFingerprint
            if let existing,
               isValidVersionFingerprint(existing) {
                continue
            }
            storedRecords[index].contentFingerprint = try fileFingerprint(
                at: url(for: storedRecords[index])
            )
            didChange = true
        }
        if didChange {
            try Task.checkCancellation()
            try saveIndex(storedRecords)
        }
        return sorted(
            storedRecords.filter {
                requestedIDs.contains($0.id) && $0.deletedAt == nil
            }
        )
    }

    func rename(
        _ record: DocumentRecord,
        to proposedName: String,
        expectedName: String
    ) throws -> DocumentRecord {
        let name = normalizedName(proposedName)
        let normalizedExpected = normalizedName(expectedName)
        var rejectedConflict = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.displayName == normalizedExpected else {
                rejectedConflict = true
                return false
            }
            guard updated.displayName != name else { return false }
            updated.displayName = name
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedConflict else {
            throw PaperPathError.insufficientSelection(
                "The document name changed in another window. Review it and try again."
            )
        }
        return updated
    }

    func updateWorkflow(
        _ record: DocumentRecord,
        status: DocumentWorkflowStatus
    ) throws -> DocumentRecord {
        try updateStoredRecord(id: record.id) { updated in
            guard updated.workflowStatus != status else { return false }
            updated.workflowStatus = status
            updated.modifiedAt = Date()
            return true
        }
    }

    func updateWorkflow(
        recordIDs: Set<UUID>,
        status: DocumentWorkflowStatus
    ) throws -> [DocumentRecord] {
        try updateStoredRecords(
            ids: recordIDs,
            requiring: { $0.deletedAt == nil }
        ) { updated, now in
            guard updated.workflowStatus != status else {
                return false
            }
            updated.workflowStatus = status
            updated.modifiedAt = now
            return true
        }
    }

    func setPinned(
        _ record: DocumentRecord,
        isPinned: Bool
    ) throws -> DocumentRecord {
        try updateStoredRecord(id: record.id) { updated in
            guard updated.isPinned != isPinned else { return false }
            updated.isPinned = isPinned
            updated.modifiedAt = Date()
            return true
        }
    }

    func togglePinned(
        _ record: DocumentRecord,
        expectedIsPinned: Bool
    ) throws -> DocumentRecord {
        var rejectedConflict = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.isPinned == expectedIsPinned else {
                rejectedConflict = true
                return false
            }
            updated.isPinned.toggle()
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedConflict else {
            throw PaperPathError.insufficientSelection(
                "The pin state changed in another window. Review it and try again."
            )
        }
        return updated
    }

    func setPinned(
        recordIDs: Set<UUID>,
        isPinned: Bool
    ) throws -> [DocumentRecord] {
        try updateStoredRecords(
            ids: recordIDs,
            requiring: { $0.deletedAt == nil }
        ) { updated, now in
            guard updated.isPinned != isPinned else {
                return false
            }
            updated.isPinned = isPinned
            updated.modifiedAt = now
            return true
        }
    }

    func updateTags(
        _ record: DocumentRecord,
        tags: [String],
        expectedTags: [String]
    ) throws -> DocumentRecord {
        let normalized = normalizedTags(tags)
        let normalizedExpected = normalizedTags(expectedTags)
        var rejectedConflict = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.tags == normalizedExpected else {
                rejectedConflict = true
                return false
            }
            guard updated.tags != normalized else { return false }
            updated.tags = normalized
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedConflict else {
            throw PaperPathError.insufficientSelection(
                "The tags changed in another window. Review them and try again."
            )
        }
        return updated
    }

    func updateTags(
        _ tagsByRecordID: [UUID: [String]]
    ) throws -> [DocumentRecord] {
        let normalizedByRecordID = tagsByRecordID.mapValues(
            normalizedTags
        )
        return try updateStoredRecords(
            ids: Set(normalizedByRecordID.keys),
            requiring: { $0.deletedAt == nil }
        ) { updated, now in
            guard let tags = normalizedByRecordID[updated.id],
                  updated.tags != tags
            else {
                return false
            }
            updated.tags = tags
            updated.modifiedAt = now
            return true
        }
    }

    func updateTags(
        recordIDs: Set<UUID>,
        adding tagsToAdd: [String],
        removing tagsToRemove: [String]
    ) throws -> [DocumentRecord] {
        let additions = normalizedTags(tagsToAdd)
        let removalKeys = Set(
            normalizedTags(tagsToRemove).map {
                $0.lowercased()
            }
        )
        return try updateStoredRecords(
            ids: recordIDs,
            requiring: { $0.deletedAt == nil }
        ) { updated, now in
            var tags = updated.tags.filter {
                !removalKeys.contains($0.lowercased())
            }
            for candidate in additions
            where !tags.contains(
                where: {
                    $0.caseInsensitiveCompare(candidate)
                        == .orderedSame
                }
            ) {
                tags.append(candidate)
            }
            let normalized = normalizedTags(tags)
            guard updated.tags != normalized else { return false }
            updated.tags = normalized
            updated.modifiedAt = now
            return true
        }
    }

    func updateDueDate(
        _ record: DocumentRecord,
        dueAt: Date?,
        expectedDueAt: Date?
    ) throws -> DocumentRecord {
        let normalized = dueAt.map {
            Calendar.current.startOfDay(for: $0)
        }
        let normalizedExpected = expectedDueAt.map {
            Calendar.current.startOfDay(for: $0)
        }
        var rejectedConflict = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            let currentDay = updated.dueAt.map {
                Calendar.current.startOfDay(for: $0)
            }
            guard currentDay == normalizedExpected else {
                rejectedConflict = true
                return false
            }
            guard updated.dueAt != normalized else { return false }
            updated.dueAt = normalized
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedConflict else {
            throw PaperPathError.insufficientSelection(
                "The due date changed in another window. Review it and try again."
            )
        }
        return updated
    }

    func updatePrivateNote(
        _ record: DocumentRecord,
        note: String?,
        expectedNote: String?
    ) throws -> DocumentRecord {
        let normalized = note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded: String? = if let normalized, !normalized.isEmpty {
            String(normalized.prefix(1_000))
        } else {
            nil
        }
        let trimmedExpected = expectedNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedExpected: String? =
            if let trimmedExpected, !trimmedExpected.isEmpty {
                String(trimmedExpected.prefix(1_000))
            } else {
                nil
            }
        var rejectedConflict = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.privateNote == boundedExpected else {
                rejectedConflict = true
                return false
            }
            guard updated.privateNote != bounded else { return false }
            updated.privateNote = bounded
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedConflict else {
            throw PaperPathError.insufficientSelection(
                "The private note changed in another window. Review it and try again."
            )
        }
        return updated
    }

    func recordOfficeExportReceipt(
        _ receipt: PDFOfficeExportReceipt,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        let trustedDate = currentTrustedDate()
        return try updateStoredRecord(id: record.id) { updated in
            updated.officeReceipts = boundedOfficeReceipts(
                ([receipt] + updated.officeReceipts.filter {
                    $0.id != receipt.id
                })
            )
            updated = reconciledOfficeBatchRecord(
                updated,
                at: trustedDate,
                checksFileSystem: false
            )
            updated.modifiedAt = Date()
            return true
        }
    }

    func updateOfficeBatchRun(
        _ run: PDFOfficeBatchRun?,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        guard run?.isStructurallyValid(
            at: currentTrustedDate()
        ) != false else {
            throw PaperPathError.storageFailure(
                "The Office batch state is invalid."
            )
        }
        return try updateStoredRecord(id: record.id) { updated in
            guard updated.officeBatchRun != run else { return false }
            updated.officeBatchRun = run
            return true
        }
    }

    func reconcileOfficeBatchArtifacts(
        for recordID: UUID
    ) throws -> DocumentRecord? {
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        guard let index = records.firstIndex(where: {
            $0.id == recordID && $0.deletedAt == nil
        }) else {
            return nil
        }
        let reconciled = reconciledOfficeBatchRecord(
            records[index],
            at: currentTrustedDate(),
            checksFileSystem: true
        )
        if reconciled != records[index] {
            records[index] = reconciled
            try saveIndex(records)
        }
        pruneOfficeExportDirectory(for: reconciled)
        return reconciled
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
        let records = try loadIndex()
        guard let storedRecord = records.first(where: {
            $0.id == record.id && $0.deletedAt == nil
        }),
              storedRecord.contentRevisionID
                == record.contentRevisionID,
              receipt.sourceRevisionID == nil
                || receipt.sourceRevisionID == storedRecord.contentRevisionID
        else {
            throw PaperPathError.insufficientSelection(
                "The source PDF changed before its Office output was retained."
            )
        }
        try ensureCapacity(for: sourceURL)

        let directory = officeExportDirectory(for: storedRecord.id)
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
        func persistedReceipt(
            fingerprint: String
        ) -> PDFOfficeExportReceipt {
            var retained = receipt
            retained.sourceRevisionID = storedRecord.contentRevisionID
            retained.retainedFileName = retainedFileName
            retained.artifactSHA256 = fingerprint
            retained.reusableUntil = Calendar.current.date(
                byAdding: .day,
                value: 7,
                to: receipt.exportedAt
            ) ?? receipt.exportedAt.addingTimeInterval(
                7 * 24 * 60 * 60
            )
            return retained
        }
        if fileManager.fileExists(atPath: destination.path) {
            try requireProtectedRegularFile(at: destination)
            let destinationValues = try destination.resourceValues(
                forKeys: [.fileSizeKey]
            )
            let sourceValues = try sourceURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true,
                  Int64(destinationValues.fileSize ?? -1)
                    == receipt.fileSizeBytes,
                  sourceValues.fileSize == destinationValues.fileSize
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office output ID is already in use"
                )
            }
            let destinationFingerprint = try fileFingerprint(
                at: destination
            )
            let sourceFingerprint = try fileFingerprint(at: sourceURL)
            guard destinationFingerprint
                    == sourceFingerprint
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office output ID refers to different bytes"
                )
            }
            if let existing = storedRecord.officeReceipts.first(
                where: { $0.id == receipt.id }
            ) {
                guard existing.format == receipt.format,
                      existing.fileSizeBytes == receipt.fileSizeBytes,
                      existing.sourceRevisionID
                        == storedRecord.contentRevisionID,
                      existing.retainedFileName == retainedFileName,
                      existing.artifactSHA256
                        == destinationFingerprint
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the retained Office receipt does not match its immutable output"
                    )
                }
                return (
                    receipt: existing,
                    record: storedRecord,
                    url: destination
                )
            }

            let recoveredReceipt = persistedReceipt(
                fingerprint: destinationFingerprint
            )
            var recoveredRecord = storedRecord
            recoveredRecord.officeReceipts = boundedOfficeReceipts(
                [recoveredReceipt] + storedRecord.officeReceipts
            )
            recoveredRecord = reconciledOfficeBatchRecord(
                recoveredRecord,
                at: currentTrustedDate(),
                checksFileSystem: false
            )
            recoveredRecord.modifiedAt = Date()
            try replaceRecord(recoveredRecord)
            pruneOfficeExportDirectory(for: recoveredRecord)
            return (
                receipt: recoveredReceipt,
                record: recoveredRecord,
                url: destination
            )
        }

        let staging = directory.appendingPathComponent(
            ".staging-\(UUID().uuidString)"
        )
        var didPublishDestination = false
        defer {
            try? fileManager.removeItem(at: staging)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: staging)
            try Task.checkCancellation()
            try requireFileProtection(to: staging)
            try Task.checkCancellation()
            try fileManager.moveItem(at: staging, to: destination)
            didPublishDestination = true
            try requireFileProtection(to: destination)

            let retainedSize = try destination.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard retainedSize.isRegularFile == true,
                  retainedSize.isSymbolicLink != true,
                  Int64(retainedSize.fileSize ?? -1)
                    == receipt.fileSizeBytes
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office file size changed"
                )
            }

            let retainedReceipt = persistedReceipt(
                fingerprint: try fileFingerprint(at: destination)
            )

            var updated = storedRecord
            updated.officeReceipts = boundedOfficeReceipts(
                ([retainedReceipt] + storedRecord.officeReceipts.filter {
                    $0.id != retainedReceipt.id
                })
            )
            updated = reconciledOfficeBatchRecord(
                updated,
                at: currentTrustedDate(),
                checksFileSystem: false
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
            if didPublishDestination,
               fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    func setOfficeExportPinned(
        receiptID: UUID,
        pinned: Bool,
        for record: DocumentRecord
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        guard let recordIndex = records.firstIndex(where: {
            $0.id == record.id && $0.deletedAt == nil
        }),
              records[recordIndex].contentRevisionID
                == record.contentRevisionID
        else {
            throw PaperPathError.insufficientSelection(
                "The source PDF changed before its Office retention was updated."
            )
        }
        let storedRecord = records[recordIndex]
        guard let receiptIndex = storedRecord.officeReceipts.firstIndex(
            where: { $0.id == receiptID }
        ) else {
            throw PaperPathError.insufficientSelection(
                "This Office receipt is no longer available."
            )
        }

        let target = storedRecord.officeReceipts[receiptIndex]
        if !pinned {
            var updated = storedRecord
            updated.officeReceipts[receiptIndex].pinnedAt = nil
            updated.officeReceipts = boundedOfficeReceipts(
                updated.officeReceipts
            )
            updated = reconciledOfficeBatchRecord(
                updated,
                at: currentTrustedDate(),
                checksFileSystem: false
            )
            updated.modifiedAt = Date()
            try Task.checkCancellation()
            records[recordIndex] = updated
            try saveIndex(records)
            pruneOfficeExportDirectory(for: updated)
            return updated
        }

        let trustedDate = currentTrustedDate()
        guard target.artifactAvailability(
            for: storedRecord.contentRevisionID,
            now: trustedDate
        ) == .reusable,
              let fileName = target.retainedFileName,
              isSafeOfficeExportFileName(fileName)
        else {
            throw PaperPathError.insufficientSelection(
                "Only a current reusable Office output can be pinned."
            )
        }

        let url = officeExportDirectory(for: storedRecord.id)
            .appendingPathComponent(fileName)
        guard let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == target.fileSizeBytes
        else {
            try? fileManager.removeItem(at: url)
            throw PaperPathError.outputVerificationFailed(
                "the retained Office file is unavailable"
            )
        }

        var verifiedFingerprint: String?
        if !target.isPinned {
            let actualFingerprint = try fileFingerprint(at: url)
            verifiedFingerprint = actualFingerprint
            if let expected = target.artifactSHA256,
               !expected.isEmpty,
               expected.caseInsensitiveCompare(actualFingerprint)
                != .orderedSame {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office output hash no longer matches"
                )
            }
            let pinnedReceipts =
                storedRecord.officeReceipts.filter(\.isPinned)
            guard pinnedReceipts.count
                    < Self.maximumPinnedOfficeExportsPerDocument
            else {
                throw PaperPathError.insufficientSelection(
                    "Keep up to 4 pinned Office outputs per PDF."
                )
            }
            let pinnedBytes = pinnedReceipts.reduce(Int64(0)) {
                saturatingAdd($0, max(0, $1.fileSizeBytes))
            }
            let requiredBytes = saturatingAdd(
                pinnedBytes,
                max(0, target.fileSizeBytes)
            )
            guard requiredBytes <= Self.maximumPinnedOfficeExportBytes
            else {
                throw PaperPathError.insufficientStorage
            }

            let allPinnedReceipts = records.flatMap {
                $0.officeReceipts.filter(\.isPinned)
            }
            let globalPinnedBytes = allPinnedReceipts.reduce(
                Int64.zero
            ) {
                saturatingAdd($0, max(0, $1.fileSizeBytes))
            }
            let globalRequiredBytes = saturatingAdd(
                globalPinnedBytes,
                max(0, target.fileSizeBytes)
            )
            guard allPinnedReceipts.count
                    < PDFOfficePinnedStorageSummary.maximumOutputCount,
                  globalRequiredBytes
                    <= PDFOfficePinnedStorageSummary.maximumByteCount
            else {
                throw PaperPathError.insufficientSelection(
                    "Keep up to 24 pinned Office outputs and 2 GB across the library."
                )
            }
        }

        var updated = storedRecord
        updated.officeReceipts[receiptIndex].pinnedAt = trustedDate
        if updated.officeReceipts[receiptIndex].artifactSHA256 == nil {
            if let verifiedFingerprint {
                updated.officeReceipts[receiptIndex].artifactSHA256 =
                    verifiedFingerprint
            } else {
                updated.officeReceipts[receiptIndex].artifactSHA256 =
                    try fileFingerprint(at: url)
            }
        }
        updated.officeReceipts = boundedOfficeReceipts(
            updated.officeReceipts
        )
        updated = reconciledOfficeBatchRecord(
            updated,
            at: trustedDate,
            checksFileSystem: false
        )
        updated.modifiedAt = Date()
        try Task.checkCancellation()
        records[recordIndex] = updated
        try saveIndex(records)
        pruneOfficeExportDirectory(for: updated)
        return updated
    }

    func unpinAllOfficeExports() throws -> [DocumentRecord] {
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        var updatedRecords: [DocumentRecord] = []
        let modifiedAt = Date()

        for index in records.indices {
            if index.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            guard records[index].officeReceipts.contains(
                where: \.isPinned
            ) else { continue }

            var updated = records[index]
            for receiptIndex in updated.officeReceipts.indices {
                updated.officeReceipts[receiptIndex].pinnedAt = nil
            }
            updated.officeReceipts = boundedOfficeReceipts(
                updated.officeReceipts
            )
            updated = reconciledOfficeBatchRecord(
                updated,
                at: currentTrustedDate(),
                checksFileSystem: false
            )
            updated.modifiedAt = modifiedAt
            records[index] = updated
            updatedRecords.append(updated)
        }

        guard !updatedRecords.isEmpty else { return [] }
        try Task.checkCancellation()
        try saveIndex(records)
        for record in updatedRecords {
            pruneOfficeExportDirectory(for: record)
        }
        return updatedRecords
    }

    func verifyOfficeExport(
        receiptID: UUID,
        for record: DocumentRecord,
        progress: (
            @Sendable (_ processedBytes: Int64, _ totalBytes: Int64)
                -> Void
        )? = nil
    ) throws -> PDFOfficeIntegrityVerification {
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        guard let recordIndex = records.firstIndex(where: {
            $0.id == record.id && $0.deletedAt == nil
        }),
              records[recordIndex].contentRevisionID
                == record.contentRevisionID
        else {
            throw PaperPathError.insufficientSelection(
                "The source PDF changed before its Office output was checked."
            )
        }
        let storedRecord = records[recordIndex]
        guard let receiptIndex = storedRecord.officeReceipts.firstIndex(
            where: { $0.id == receiptID }
        ) else {
            throw PaperPathError.insufficientSelection(
                "This Office receipt is no longer available."
            )
        }

        var updated = storedRecord
        var receipt = updated.officeReceipts[receiptIndex]
        let checkedAt = currentTrustedDate()
        let status: PDFOfficeIntegrityStatus
        var verifiedURL: URL?
        let sourceChanged =
            receipt.sourceRevisionID != storedRecord.contentRevisionID
        let isRetained =
            receipt.isPinned
            || (receipt.reusableUntil ?? .distantPast) > checkedAt

        if sourceChanged && !receipt.isPinned {
            status = .sourceChanged
        } else if !isRetained {
            status = .missing
        } else if let fileName = receipt.retainedFileName,
                  isSafeOfficeExportFileName(fileName) {
            let url = officeExportDirectory(for: storedRecord.id)
                .appendingPathComponent(fileName)
            let values = try? url.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            if values?.isRegularFile != true
                || values?.isSymbolicLink == true
                || Int64(values?.fileSize ?? -1)
                    != receipt.fileSizeBytes {
                status = .missing
            } else {
                try requireFileProtection(to: url)
                let actualFingerprint = try fileFingerprint(
                    at: url,
                    progress: progress
                )
                if let expected = receipt.artifactSHA256,
                   !expected.isEmpty,
                   expected.caseInsensitiveCompare(actualFingerprint)
                    != .orderedSame {
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
        updated = reconciledOfficeBatchRecord(
            updated,
            at: checkedAt,
            checksFileSystem: false
        )
        try Task.checkCancellation()
        records[recordIndex] = updated
        try saveIndex(records)
        return PDFOfficeIntegrityVerification(
            recordID: storedRecord.id,
            record: updated,
            receipt: receipt,
            status: status,
            url: verifiedURL
        )
    }

    func prepareOfficeExportShareCopy(
        receiptID: UUID,
        for record: DocumentRecord,
        destinationURL: URL,
        progress: @escaping PDFByteProgressHandler = { _ in }
    ) throws -> (record: DocumentRecord, url: URL) {
        try Task.checkCancellation()
        guard let requestedReceipt = record.officeReceipts.first(
            where: { $0.id == receiptID }
        ),
              requestedReceipt.fileSizeBytes > 0
        else {
            throw PaperPathError.insufficientSelection(
                "This Office receipt is no longer available."
            )
        }
        let expectedByteCount = requestedReceipt.fileSizeBytes
        let secondPassBaseline = expectedByteCount
        let thirdPassBaseline = saturatingAdd(
            expectedByteCount,
            expectedByteCount
        )
        let totalWorkBytes = saturatingAdd(
            thirdPassBaseline,
            expectedByteCount
        )
        let verification = try verifyOfficeExport(
            receiptID: receiptID,
            for: record
        ) { processedBytes, _ in
            progress(
                PDFByteProgressUpdate(
                    stage: .checksumming,
                    processedBytes: min(
                        totalWorkBytes,
                        max(0, processedBytes)
                    ),
                    totalBytes: totalWorkBytes,
                    completedUnitCount:
                        processedBytes == expectedByteCount ? 1 : 0,
                    totalUnitCount: 3,
                    currentUnitName: requestedReceipt.fileName
                )
            )
        }
        guard verification.status.isVerified,
              let sourceURL = verification.url,
              let retainedFileName = verification.receipt.retainedFileName,
              let expectedSHA256 = verification.receipt.artifactSHA256,
              isValidVersionFingerprint(expectedSHA256),
              verification.receipt.fileSizeBytes == expectedByteCount,
              sourceURL.standardizedFileURL
                == officeExportDirectory(for: record.id)
                    .appendingPathComponent(retainedFileName)
                    .standardizedFileURL
        else {
            throw PaperPathError.outputVerificationFailed(
                "the retained Office output did not pass verification"
            )
        }

        let parent = destinationURL.deletingLastPathComponent()
        let managed = PaperPathTemporaryArtifact.managedTopLevelItem(
            containing: destinationURL,
            allowedPrefixes: [
                PaperPathTemporaryArtifact.officeSharePrefix
            ],
            fileManager: fileManager
        )
        guard let managed,
              managed == parent
                .resolvingSymlinksInPath()
                .standardizedFileURL,
              isSafeOfficeExportFileName(
                destinationURL.lastPathComponent
              ),
              destinationURL.pathExtension.lowercased()
                == verification.receipt.format.fileExtension.lowercased(),
              !fileManager.fileExists(atPath: parent.path),
              !fileManager.fileExists(atPath: destinationURL.path)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office share request is no longer valid"
            )
        }

        let identityKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        let sourceValues = try sourceURL.resourceValues(
            forKeys: identityKeys
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              Int64(sourceValues.fileSize ?? -1) == expectedByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the retained Office output changed before sharing"
            )
        }

        try ensureCapacity(for: sourceURL)
        try LocalFileSecurity.prepareProtectedDirectory(
            at: parent,
            fileManager: fileManager
        )
        do {
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: destinationURL,
                expectedByteCount: expectedByteCount
            ) { copiedBytes in
                progress(
                    PDFByteProgressUpdate(
                        stage: .checksumming,
                        processedBytes: min(
                            totalWorkBytes,
                            secondPassBaseline + copiedBytes
                        ),
                        totalBytes: totalWorkBytes,
                        completedUnitCount:
                            copiedBytes == expectedByteCount ? 2 : 1,
                        totalUnitCount: 3,
                        currentUnitName: requestedReceipt.fileName
                    )
                )
            }
            try Task.checkCancellation()
            let destinationFingerprint = try fileFingerprint(
                at: destinationURL
            ) { processedBytes, _ in
                progress(
                    PDFByteProgressUpdate(
                        stage: .verifying,
                        processedBytes: min(
                            totalWorkBytes,
                            thirdPassBaseline + processedBytes
                        ),
                        totalBytes: totalWorkBytes,
                        completedUnitCount:
                            processedBytes == expectedByteCount ? 3 : 2,
                        totalUnitCount: 3,
                        currentUnitName: requestedReceipt.fileName
                    )
                )
            }
            let finalSourceValues = try uncachedResourceValues(
                at: sourceURL,
                forKeys: identityKeys
            )
            let destinationValues = try destinationURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            try Task.checkCancellation()
            guard finalSourceValues.isRegularFile == true,
                  finalSourceValues.isSymbolicLink != true,
                  Int64(finalSourceValues.fileSize ?? -1)
                    == expectedByteCount,
                  finalSourceValues.contentModificationDate
                    == sourceValues.contentModificationDate,
                  fileResourceIdentifiersMatch(
                    sourceValues.fileResourceIdentifier,
                    finalSourceValues.fileResourceIdentifier
                  ),
                  destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  Int64(destinationValues.fileSize ?? -1)
                    == expectedByteCount,
                  copiedFile.byteCount == expectedByteCount,
                  copiedFile.sha256.caseInsensitiveCompare(
                    expectedSHA256
                  ) == .orderedSame,
                  destinationFingerprint.caseInsensitiveCompare(
                    expectedSHA256
                  ) == .orderedSame
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the protected Office share copy did not match its receipt"
                )
            }
            return (verification.record, destinationURL)
        } catch {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: parent,
                allowedPrefixes: [
                    PaperPathTemporaryArtifact.officeSharePrefix
                ],
                fileManager: fileManager
            )
            throw error
        }
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        let normalized = tags.compactMap { value -> String? in
            let sanitized = sanitizedDisplayText(value)
            guard !sanitized.isEmpty else { return nil }
            let shortened = String(sanitized.prefix(24))
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
        try updateStoredRecord(id: record.id) { updated in
            let previousPages = updated.bookmarkedPages
            let previousNames = updated.bookmarkNames
            updated.bookmarkedPages = Array(
                Set(
                    pages.filter {
                        $0 >= 0 && $0 < updated.profile.pageCount
                    }
                )
            ).sorted()
            if preserveNames {
                let validPages = Set(updated.bookmarkedPages)
                updated.bookmarkNames = updated.bookmarkNames.filter {
                    validPages.contains($0.key)
                }
            } else if updated.bookmarkedPages != previousPages {
                updated.bookmarkNames = [:]
            }
            guard updated.bookmarkedPages != previousPages
                    || updated.bookmarkNames != previousNames
            else { return false }
            updated.modifiedAt = Date()
            return true
        }
    }

    func toggleBookmark(
        _ record: DocumentRecord,
        pageIndex: Int
    ) throws -> DocumentRecord {
        var rejectedStaleRevision = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.contentRevisionID
                    == record.contentRevisionID
            else {
                rejectedStaleRevision = true
                return false
            }
            guard pageIndex >= 0,
                  pageIndex < updated.profile.pageCount
            else { return false }
            if let offset = updated.bookmarkedPages.firstIndex(
                of: pageIndex
            ) {
                updated.bookmarkedPages.remove(at: offset)
                updated.bookmarkNames[pageIndex] = nil
            } else {
                updated.bookmarkedPages.append(pageIndex)
                updated.bookmarkedPages.sort()
            }
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedStaleRevision else {
            throw PaperPathError.insufficientSelection(
                "The PDF changed before this action started. Review the updated PDF."
            )
        }
        return updated
    }

    func saveBookmark(
        _ record: DocumentRecord,
        pageIndex: Int,
        name: String?
    ) throws -> DocumentRecord {
        let sanitized = name.map(sanitizedDisplayText)
        let bounded: String? = if let sanitized, !sanitized.isEmpty {
            String(sanitized.prefix(80))
        } else {
            nil
        }
        var rejectedStaleRevision = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.contentRevisionID
                    == record.contentRevisionID
            else {
                rejectedStaleRevision = true
                return false
            }
            guard pageIndex >= 0,
                  pageIndex < updated.profile.pageCount
            else { return false }
            var changed = false
            if !updated.bookmarkedPages.contains(pageIndex) {
                updated.bookmarkedPages.append(pageIndex)
                updated.bookmarkedPages.sort()
                changed = true
            }
            if updated.bookmarkNames[pageIndex] != bounded {
                updated.bookmarkNames[pageIndex] = bounded
                changed = true
            }
            guard changed else { return false }
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedStaleRevision else {
            throw PaperPathError.insufficientSelection(
                "The PDF changed before this action started. Review the updated PDF."
            )
        }
        return updated
    }

    func updateBookmarkName(
        _ record: DocumentRecord,
        pageIndex: Int,
        name: String?
    ) throws -> DocumentRecord {
        let sanitized = name.map(sanitizedDisplayText)
        let bounded: String? = if let sanitized, !sanitized.isEmpty {
            String(sanitized.prefix(80))
        } else {
            nil
        }
        var rejectedStaleRevision = false
        let updated = try updateStoredRecord(id: record.id) { updated in
            guard updated.contentRevisionID
                    == record.contentRevisionID
            else {
                rejectedStaleRevision = true
                return false
            }
            guard updated.bookmarkedPages.contains(pageIndex),
                  updated.bookmarkNames[pageIndex] != bounded
            else { return false }
            updated.bookmarkNames[pageIndex] = bounded
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedStaleRevision else {
            throw PaperPathError.insufficientSelection(
                "The PDF changed before this action started. Review the updated PDF."
            )
        }
        return updated
    }

    func updateReadingPosition(
        recordID: UUID,
        pageIndex: Int,
        expectedRevisionID: UUID,
        viewedAt: Date = Date()
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        guard let index = records.firstIndex(
            where: { $0.id == recordID }
        ) else {
            throw PaperPathError.unreadablePDF
        }
        let record = records[index]
        guard record.contentRevisionID == expectedRevisionID else {
            throw CancellationError()
        }
        if let currentViewedAt = record.lastViewedAt,
           currentViewedAt > viewedAt {
            return record
        }
        let bounded = min(
            max(pageIndex, 0),
            max(0, record.profile.pageCount - 1)
        )
        var updated = record
        updated.lastPageIndex = bounded
        updated.lastViewedAt = viewedAt
        records[index] = updated
        try Task.checkCancellation()
        try saveIndex(records)
        return updated
    }

    func applyMetadataSync(
        _ update: PDFMetadataSyncUpdate,
        to record: DocumentRecord
    ) throws -> DocumentRecord {
        guard update.recordID == record.id,
              let updated = try applyMetadataSync([update]).first
        else {
            throw PDFMetadataSyncApplyError.localStateChanged
        }
        return updated
    }

    func applyMetadataSync(
        _ updates: [PDFMetadataSyncUpdate]
    ) throws -> [DocumentRecord] {
        guard !updates.isEmpty else { return [] }
        try Task.checkCancellation()
        var records = try loadIndex()
        let updateIDs = updates.map(\.recordID)
        guard Set(updateIDs).count == updateIDs.count else {
            throw PaperPathError.storageFailure(
                "The metadata sync batch contains duplicate documents."
            )
        }
        var updatedRecords: [DocumentRecord] = []
        updatedRecords.reserveCapacity(updates.count)

        for update in updates {
            try Task.checkCancellation()
            guard let recordIndex = records.firstIndex(where: {
                $0.id == update.recordID && $0.deletedAt == nil
            }) else {
                throw PDFMetadataSyncApplyError.localStateChanged
            }
            let storedRecord = records[recordIndex]
            guard isValidVersionFingerprint(update.fingerprint),
                  let storedFingerprint = storedRecord.contentFingerprint,
                  isValidVersionFingerprint(storedFingerprint),
                  update.fingerprint.caseInsensitiveCompare(
                      storedFingerprint
                  ) == .orderedSame,
                  PDFMetadataSyncLocalState(storedRecord)
                    == update.expectedLocalState
            else {
                throw PDFMetadataSyncApplyError.localStateChanged
            }

            let latestLocalActivity = max(
                storedRecord.modifiedAt,
                storedRecord.lastViewedAt ?? .distantPast
            )
            guard latestLocalActivity <= update.updatedAt else {
                throw PDFMetadataSyncApplyError.localStateChanged
            }

            var updated = storedRecord
            updated.lastPageIndex = min(
                max(update.lastPageIndex, 0),
                max(0, storedRecord.profile.pageCount - 1)
            )
            if let remoteViewedAt = update.lastViewedAt,
               remoteViewedAt
                > (storedRecord.lastViewedAt ?? .distantPast) {
                updated.lastViewedAt = remoteViewedAt
            }
            updated.bookmarkedPages = Array(
                Set(
                    update.bookmarkedPages.filter {
                        $0 >= 0
                            && $0 < storedRecord.profile.pageCount
                    }
                )
            ).sorted()
            updated.workflowStatus = update.workflowStatus
            updated.isPinned = update.isPinned
            updated.tags = normalizedTags(update.tags)
            updated.completedActions = update.completedActions

            let trustedDate = currentTrustedDate(
                forceCheckpoint: update.deliveryReceipt != nil
            )
            if let receipt = update.deliveryReceipt,
               receipt.changeReview == nil,
               receipt.isVerified(at: trustedDate),
               receipt.sha256.caseInsensitiveCompare(
                   update.fingerprint
               ) == .orderedSame,
               receipt.outputPageCount == storedRecord.profile.pageCount,
               receipt.outputByteCount == storedRecord.profile.byteCount,
               (try? fileFingerprint(
                   at: url(for: storedRecord)
               ))?.caseInsensitiveCompare(
                   update.fingerprint
               ) == .orderedSame {
                var verifiedReceipt = receipt
                verifiedReceipt.outputRevisionID =
                    storedRecord.contentRevisionID
                if storedRecord.deliveryReceipt?.id == receipt.id {
                    verifiedReceipt.changeReview =
                        storedRecord.deliveryReceipt?.changeReview
                }
                updated.deliveryReceipt = verifiedReceipt
            }
            updated.modifiedAt = max(
                storedRecord.modifiedAt,
                update.updatedAt
            )
            records[recordIndex] = updated
            updatedRecords.append(updated)
        }
        try Task.checkCancellation()
        try saveIndex(records)
        return updatedRecords
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

    func setActionCompletion(
        _ record: DocumentRecord,
        action: DocumentAction,
        completed: Bool,
        expectedContentRevisionID: UUID? = nil
    ) throws -> DocumentRecord {
        try updateStoredRecord(id: record.id) { updated in
            guard expectedContentRevisionID == nil
                    || updated.contentRevisionID == expectedContentRevisionID
            else { return false }
            let previous = updated.completedActions
            if completed {
                updated.completedActions.insert(action)
            } else {
                updated.completedActions.remove(action)
            }
            guard updated.completedActions != previous else {
                return false
            }
            updated.modifiedAt = Date()
            return true
        }
    }

    func updateTaskCheckpoint(
        _ record: DocumentRecord,
        checkpoint: DocumentTaskCheckpoint?
    ) throws -> DocumentRecord {
        var rejectedStaleCheckpoint = false
        let result = try updateStoredRecord(id: record.id) { updated in
            guard updated.contentRevisionID
                    == record.contentRevisionID
            else {
                rejectedStaleCheckpoint = true
                return false
            }
            let bounded: DocumentTaskCheckpoint?
            if let checkpoint {
                guard let validated = checkpoint.validated(
                    for: updated.contentRevisionID,
                    pageCount: updated.profile.pageCount
                ) else {
                    rejectedStaleCheckpoint = true
                    return false
                }
                bounded = validated
            } else {
                bounded = nil
            }
            if let bounded,
               let current = updated.taskCheckpoint,
               bounded.hasSameResumeTarget(as: current) {
                return false
            }
            guard bounded != nil || updated.taskCheckpoint != nil else {
                return false
            }
            updated.taskCheckpoint = bounded
            if bounded != nil,
               updated.workflowStatus == .inbox {
                updated.workflowStatus = .reviewing
            }
            updated.modifiedAt = Date()
            return true
        }
        guard !rejectedStaleCheckpoint else {
            throw CancellationError()
        }
        return result
    }

    func saveAnalysis(
        _ record: DocumentRecord,
        brief: DocumentBrief,
        textIndex: DocumentTextIndex,
        ocrResult: OCRResult? = nil
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
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
            records[recordIndex] = updated

            guard isValidTextIndex(
                textIndex,
                pageCount: storedRecord.profile.pageCount
            ),
            ocrResult.map({
                isValidOCRResult(
                    $0,
                    pageCount: storedRecord.profile.pageCount
                )
            }) ?? true else {
                throw PaperPathError.storageFailure(
                    "The local analysis contains invalid page data."
                )
            }
            let indexData = try JSONEncoder.paperPath.encode(
                textIndex.bound(to: storedRecord.contentRevisionID)
            )
            try requireData(
                indexData,
                maximumBytes: Self.maximumTextIndexBytes,
                label: "The local text index"
            )
            var writes: [(data: Data, destination: URL)] = [
                (
                    data: indexData,
                    destination: textIndexURL(for: record.id)
                )
            ]
            if let ocrResult {
                let ocrData = try JSONEncoder.paperPath.encode(ocrResult)
                try requireData(
                    ocrData,
                    maximumBytes: Self.maximumOCRResultBytes,
                    label: "The local OCR result"
                )
                writes.append(
                    (
                        data: ocrData,
                        destination: ocrResultURL(for: record.id)
                    )
                )
            }
            writes.append(
                (
                    data: try encodedLibraryIndex(records),
                    destination: indexURL
                )
            )
            try Task.checkCancellation()
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
            if let index = try loadTextIndex(
                recordID: record.id,
                pageCount: record.profile.pageCount,
                hasAnalysis: record.brief != nil,
                contentRevisionID: record.contentRevisionID,
                expectedIndexedAt: record.brief?.indexedAt
            ) {
                result[record.id] = index
            }
        }
        return result
    }

    private func loadTextIndex(
        recordID: UUID,
        pageCount: Int,
        hasAnalysis: Bool,
        contentRevisionID: UUID,
        expectedIndexedAt: Date?,
        removesInvalidFile: Bool = true
    ) throws -> DocumentTextIndex? {
        let url = textIndexURL(for: recordID)
        guard hasAnalysis else {
            if removesInvalidFile,
               fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            return nil
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            try requireProtectedRegularFile(at: url)
            let data = try boundedData(
                at: url,
                maximumBytes: Self.maximumTextIndexBytes
            )
            let index = try JSONDecoder.paperPath.decode(
                DocumentTextIndex.self,
                from: data
            )
            try Task.checkCancellation()
            let matchesRevision = index.contentRevisionID.map {
                $0 == contentRevisionID
            } ?? (expectedIndexedAt == index.indexedAt)
            guard matchesRevision, isValidTextIndex(
                index,
                pageCount: pageCount
            ) else {
                throw PaperPathError.storageFailure(
                    "The local text index is invalid."
                )
            }
            // Legacy indices were committed with their brief in one transaction.
            let boundIndex = index.bound(to: contentRevisionID)
            if index.contentRevisionID == nil {
                try? writeProtectedData(
                    JSONEncoder.paperPath.encode(boundIndex),
                    to: url
                )
            }
            return boundIndex
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if removesInvalidFile {
                try? fileManager.removeItem(at: url)
            }
            return nil
        }
    }

    func loadOCRResults() throws -> [UUID: OCRResult] {
        try prepareDirectories()
        return try loadOCRResults(
            for: try loadIndex().filter { $0.deletedAt == nil }
        )
    }

    func loadAnalysis(
        for recordIDs: Set<UUID>
    ) throws -> DocumentStoreAnalysisSnapshot {
        guard !recordIDs.isEmpty else {
            return DocumentStoreAnalysisSnapshot(
                textIndices: [:],
                ocrResults: [:]
            )
        }
        try prepareDirectories()
        let records = try loadIndex().filter {
            recordIDs.contains($0.id) && $0.deletedAt == nil
        }
        return DocumentStoreAnalysisSnapshot(
            textIndices: try loadTextIndices(for: records),
            ocrResults: try loadOCRResults(for: records)
        )
    }

    func searchTextIndices(
        query: String,
        candidates: [DocumentStoreTextSearchCandidate],
        resultLimit: Int = 500,
        perDocumentLimit: Int = 200
    ) throws -> DocumentStoreTextSearchSnapshot {
        let terms = DocumentSearchNormalization.terms(in: query)
        guard !terms.isEmpty else {
            return DocumentStoreTextSearchSnapshot(
                matchingRecordIDs: [],
                matchesByRecordID: [:],
                isLimited: false,
                hasTruncatedIndices: false
            )
        }

        try prepareDirectories()
        let currentRecords = Dictionary(
            uniqueKeysWithValues: try loadIndex().map { ($0.id, $0) }
        )
        let boundedResultLimit = min(max(0, resultLimit), 500)
        let boundedPerDocumentLimit = min(
            max(0, perDocumentLimit),
            200
        )
        var matchingRecordIDs: Set<UUID> = []
        matchingRecordIDs.reserveCapacity(candidates.count)
        var matchesByRecordID: [UUID: [DocumentTextMatch]] = [:]
        matchesByRecordID.reserveCapacity(
            min(candidates.count, boundedResultLimit)
        )
        var remaining = boundedResultLimit
        var isLimited = false
        var hasTruncatedIndices = false

        for candidate in candidates {
            try Task.checkCancellation()
            guard let current = currentRecords[candidate.recordID],
                  current.deletedAt == nil,
                  candidate.contentRevisionID.map({
                      $0 == current.contentRevisionID
                  }) ?? true
            else { continue }
            let unresolvedTerms = terms.filter {
                !candidate.metadataCorpus.contains($0)
            }
            guard !unresolvedTerms.isEmpty else {
                matchingRecordIDs.insert(candidate.recordID)
                continue
            }
            let index = try autoreleasepool {
                try loadTextIndex(
                    recordID: candidate.recordID,
                    pageCount: current.profile.pageCount,
                    hasAnalysis: current.brief != nil,
                    contentRevisionID: current.contentRevisionID,
                    expectedIndexedAt: current.brief?.indexedAt,
                    removesInvalidFile: false
                )
            }
            guard let index else { continue }
            if index.hasTruncatedContent {
                hasTruncatedIndices = true
            }
            let evaluation = try index.evaluateSearch(
                normalizedTerms: unresolvedTerms,
                matchLimit: remaining > 0
                    ? min(
                        boundedPerDocumentLimit + 1,
                        remaining + 1
                    )
                    : 0
            )
            guard evaluation.containsEveryTerm else { continue }

            matchingRecordIDs.insert(candidate.recordID)
            guard remaining > 0 else {
                isLimited = true
                continue
            }
            let matches = evaluation.matches
            guard !matches.isEmpty else { continue }
            let accepted = Array(
                matches.prefix(
                    min(boundedPerDocumentLimit, remaining)
                )
            )
            matchesByRecordID[candidate.recordID] = accepted
            remaining -= accepted.count
            if matches.count > accepted.count {
                isLimited = true
            }
        }

        return DocumentStoreTextSearchSnapshot(
            matchingRecordIDs: matchingRecordIDs,
            matchesByRecordID: matchesByRecordID,
            isLimited: isLimited,
            hasTruncatedIndices: hasTruncatedIndices
        )
    }

    private func loadOCRResults(
        for records: [DocumentRecord]
    ) throws -> [UUID: OCRResult] {
        var result: [UUID: OCRResult] = [:]
        for record in records {
            try Task.checkCancellation()
            let url = ocrResultURL(for: record.id)
            guard record.brief != nil else {
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
                continue
            }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try requireProtectedRegularFile(at: url)
                let data = try boundedData(
                    at: url,
                    maximumBytes: Self.maximumOCRResultBytes
                )
                let ocrResult = try JSONDecoder.paperPath.decode(
                    OCRResult.self,
                    from: data
                )
                try Task.checkCancellation()
                guard isValidOCRResult(
                    ocrResult,
                    pageCount: record.profile.pageCount
                ) else {
                    throw PaperPathError.storageFailure(
                        "The local OCR result is invalid."
                    )
                }
                result[record.id] = ocrResult
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }
        return result
    }

    private func bootstrapAnalysisRecords(
        from records: [DocumentRecord]
    ) -> [DocumentRecord] {
        let candidates = records
            .filter { $0.brief != nil }
            .sorted {
                let lhs = $0.lastViewedAt ?? $0.modifiedAt
                let rhs = $1.lastViewedAt ?? $1.modifiedAt
                if lhs != rhs {
                    return lhs > rhs
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        var selected: [DocumentRecord] = []
        selected.reserveCapacity(
            min(candidates.count, Self.maximumBootstrapAnalysisRecords)
        )
        var totalBytes: Int64 = 0
        for record in candidates {
            guard selected.count
                    < Self.maximumBootstrapAnalysisRecords
            else { break }
            let textBytes = logicalFileSize(
                textIndexURL(for: record.id)
            )
            let ocrBytes = logicalFileSize(
                ocrResultURL(for: record.id)
            )
            let (recordBytes, recordOverflow) =
                textBytes.addingReportingOverflow(ocrBytes)
            guard !recordOverflow, recordBytes > 0 else { continue }
            let (nextTotal, totalOverflow) =
                totalBytes.addingReportingOverflow(recordBytes)
            guard !totalOverflow,
                  nextTotal <= Self.maximumBootstrapAnalysisBytes
            else { continue }
            selected.append(record)
            totalBytes = nextTotal
        }
        return selected
    }

    private func isValidTextIndex(
        _ index: DocumentTextIndex,
        pageCount: Int
    ) -> Bool {
        let timestamp = index.indexedAt.timeIntervalSince1970
        guard pageCount > 0,
              index.pages.count <= pageCount,
              timestamp.isFinite,
              timestamp >= 0,
              index.indexedAt <= Date().addingTimeInterval(5 * 60)
        else { return false }
        var previousPageIndex: Int?
        var totalCharacters = 0
        var totalUTF8Bytes = 0
        for page in index.pages {
            let (nextCharacterCount, characterOverflow) =
                totalCharacters.addingReportingOverflow(
                    page.text.count
                )
            let (nextUTF8ByteCount, byteOverflow) =
                totalUTF8Bytes.addingReportingOverflow(
                    page.text.utf8.count
                )
            guard page.pageIndex >= 0,
                  page.pageIndex < pageCount,
                  previousPageIndex.map({
                      page.pageIndex > $0
                  }) ?? true,
                  !characterOverflow,
                  nextCharacterCount
                    <= DocumentTextIndex.maximumCharacterCount,
                  !byteOverflow,
                  nextUTF8ByteCount
                    <= DocumentTextIndex.maximumUTF8ByteCount
            else { return false }
            previousPageIndex = page.pageIndex
            totalCharacters = nextCharacterCount
            totalUTF8Bytes = nextUTF8ByteCount
        }
        return true
    }

    func loadOCRCheckpoint(
        _ identity: OCRCheckpointIdentity
    ) throws -> OCRCheckpoint? {
        try scanOCRCheckpoint(identity, retainingPages: true).map {
            OCRCheckpoint(identity: identity, pages: $0.pages)
        }
    }

    func loadOCRRecoverySummary(for record: DocumentRecord) throws -> OCRRecoverySummary? {
        try Task.checkCancellation()
        let directory = ocrCheckpointURL(for: record.id)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        try requireOCRCheckpointDirectory(directory)
        guard let identity = try storedOCRCheckpointIdentity(in: directory),
              identity.recordID == record.id,
              identity.revisionID == record.contentRevisionID,
              identity.pageCount == record.profile.pageCount,
              identity.engineVersion == OCRCheckpointIdentity.currentEngineVersion,
              identity.systemVersion == ProcessInfo.processInfo.operatingSystemVersionString
        else { return nil }
        return try scanOCRCheckpoint(identity, retainingPages: false)?.summary
    }

    private func scanOCRCheckpoint(
        _ identity: OCRCheckpointIdentity,
        retainingPages: Bool
    ) throws -> (summary: OCRRecoverySummary, pages: [OCRPageResult])? {
        try Task.checkCancellation()
        try requireCurrentOCRSource(identity)
        let directory = ocrCheckpointURL(for: identity.recordID)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        try requireOCRCheckpointDirectory(directory)
        guard try storedOCRCheckpointIdentity(in: directory) == identity else { return nil }
        var pages: [OCRPageResult] = []
        var completedIndices: [Int] = []
        var damagedPageCount = 0
        var totalBytes: Int64 = 0
        var totalTextBytes = 0
        var totalBlockCount = 0
        for index in 0..<identity.pageCount {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("page-\(index).json")
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try requireProtectedRegularFile(at: url)
            // A summary releases each decoded page instead of retaining the document's text.
            let decoded: (page: OCRPageResult, bytes: Int)? = autoreleasepool {
                guard let data = try? boundedData(at: url, maximumBytes: 8 * 1_024 * 1_024),
                      let page = try? JSONDecoder.paperPath.decode(OCRPageResult.self, from: data)
                else { return nil }
                return (page, data.count)
            }
            guard let decoded,
                  case let page = decoded.page,
                  page.pageIndex == index,
                  isValidOCRResult(
                    OCRResult(pages: [page], configuration: identity.configuration),
                    pageCount: identity.pageCount
                  )
            else {
                damagedPageCount += 1
                continue
            }
            totalBytes += Int64(decoded.bytes)
            totalBlockCount += page.blocks.count
            totalTextBytes += page.text.utf8.count
                + page.blocks.reduce(0) { $0 + $1.text.utf8.count }
            guard totalBytes <= Self.maximumOCRResultBytes,
                  totalBlockCount <= OCRResult.maximumBlockCount,
                  totalTextBytes <= OCRResult.maximumEncodedTextBytes else {
                throw PaperPathError.storageFailure("The local OCR result exceeds its safe storage limit.")
            }
            completedIndices.append(index)
            if retainingPages { pages.append(page) }
        }
        return (
            OCRRecoverySummary(
                identity: identity, completedPageIndices: completedIndices,
                damagedPageCount: damagedPageCount
            ),
            pages
        )
    }

    func prepareOCRCheckpoint(
        _ identity: OCRCheckpointIdentity
    ) throws -> OCRCheckpoint {
        try prepareDirectories()
        if let existing = try loadOCRCheckpoint(identity) { return existing }
        let directory = ocrCheckpointURL(for: identity.recordID)
        if fileManager.fileExists(atPath: directory.path) {
            try requireOCRCheckpointDirectory(directory)
            try fileManager.removeItem(at: directory)
        }
        try LocalFileSecurity.prepareProtectedDirectory(at: directory, fileManager: fileManager)
        try writeProtectedData(
            JSONEncoder.paperPath.encode(identity),
            to: directory.appendingPathComponent("identity.json")
        )
        return OCRCheckpoint(identity: identity, pages: [])
    }

    func saveOCRCheckpointPage(
        _ page: OCRPageResult,
        identity: OCRCheckpointIdentity
    ) throws {
        try Task.checkCancellation()
        try requireCurrentOCRSource(identity)
        let directory = ocrCheckpointURL(for: identity.recordID)
        try requireOCRCheckpointDirectory(directory)
        guard try storedOCRCheckpointIdentity(in: directory) == identity else {
            throw CancellationError()
        }
        guard (0..<identity.pageCount).contains(page.pageIndex),
              isValidOCRResult(
            OCRResult(pages: [page], configuration: identity.configuration),
            pageCount: identity.pageCount
        ) else { throw PaperPathError.invalidPage }
        let data = try JSONEncoder.paperPath.encode(page)
        try requireData(data, maximumBytes: 8 * 1_024 * 1_024, label: "The OCR checkpoint page")
        try writeProtectedData(
            data,
            to: directory.appendingPathComponent("page-\(page.pageIndex).json")
        )
    }

    func removeOCRCheckpoint(_ identity: OCRCheckpointIdentity) throws {
        let directory = ocrCheckpointURL(for: identity.recordID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try requireOCRCheckpointDirectory(directory)
        guard try storedOCRCheckpointIdentity(in: directory) == identity else { return }
        try fileManager.removeItem(at: directory)
    }

    private func requireCurrentOCRSource(_ identity: OCRCheckpointIdentity) throws {
        guard (1...OCRResult.maximumPageCount).contains(identity.pageCount),
              identity.engineVersion == OCRCheckpointIdentity.currentEngineVersion,
              identity.systemVersion == ProcessInfo.processInfo.operatingSystemVersionString,
              let record = try loadIndex().first(where: { $0.id == identity.recordID }),
              record.deletedAt == nil, !record.profile.isLocked,
              record.contentRevisionID == identity.revisionID,
              record.profile.pageCount == identity.pageCount
        else { throw CancellationError() }
    }

    private func requireOCRCheckpointDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PaperPathError.storageFailure("The OCR checkpoint directory is invalid.")
        }
        try requireFileProtection(to: directory)
    }

    private func storedOCRCheckpointIdentity(in directory: URL) throws -> OCRCheckpointIdentity? {
        let url = directory.appendingPathComponent("identity.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try requireProtectedRegularFile(at: url)
        let data = try boundedData(at: url, maximumBytes: 32 * 1_024)
        return try? JSONDecoder.paperPath.decode(OCRCheckpointIdentity.self, from: data)
    }

    private func isValidOCRResult(
        _ result: OCRResult,
        pageCount: Int
    ) -> Bool {
        guard pageCount > 0,
              pageCount <= OCRResult.maximumPageCount,
              result.pages.count <= pageCount,
              result.pages.count <= OCRResult.maximumPageCount,
              result.configuration.customWords.count <= 1_024,
              result.configuration.customWords.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 256
              })
        else { return false }
        let allowedLanguages = Set(
            OCRRecognitionLanguage.allCases.map(\.rawValue)
        )
        let languages = result.configuration.languageIdentifiers
        guard languages.count <= allowedLanguages.count,
              Set(languages).count == languages.count,
              languages.allSatisfy(allowedLanguages.contains)
        else { return false }

        var pageIndices: Set<Int> = []
        var totalBlockCount = 0
        var totalTextBytes = 0
        for page in result.pages {
            let (nextBlockCount, overflow) =
                totalBlockCount.addingReportingOverflow(
                    page.blocks.count
                )
            let blockTextBytes = page.blocks.reduce(0) {
                partial, block in
                let (sum, didOverflow) =
                    partial.addingReportingOverflow(
                        block.text.utf8.count
                    )
                return didOverflow ? .max : sum
            }
            let (pageTextBytes, pageOverflow) =
                page.text.utf8.count.addingReportingOverflow(
                    blockTextBytes
                )
            let (nextTextBytes, textOverflow) =
                totalTextBytes.addingReportingOverflow(pageTextBytes)
            guard !overflow,
                  !pageOverflow,
                  !textOverflow,
                  nextBlockCount <= OCRResult.maximumBlockCount,
                  nextTextBytes <= OCRResult.maximumEncodedTextBytes,
                  page.blocks.count <= 4_096,
                  page.pageIndex >= 0,
                  page.pageIndex < pageCount,
                  pageIndices.insert(page.pageIndex).inserted,
                  isUnitInterval(page.confidence),
                  page.blocks.allSatisfy(isValidOCRBlock)
            else { return false }
            totalBlockCount = nextBlockCount
            totalTextBytes = nextTextBytes
        }
        return true
    }

    private func isValidOCRBlock(_ block: OCRTextBlock) -> Bool {
        let values = [
            block.normalizedX,
            block.normalizedY,
            block.normalizedWidth,
            block.normalizedHeight
        ]
        guard block.text.utf8.count <= 1_048_576,
              isUnitInterval(block.confidence),
              values.allSatisfy(\.isFinite),
              block.normalizedX >= -0.001,
              block.normalizedY >= -0.001,
              block.normalizedWidth >= 0,
              block.normalizedHeight >= 0,
              block.normalizedX + block.normalizedWidth <= 1.001,
              block.normalizedY + block.normalizedHeight <= 1.001
        else { return false }
        return true
    }

    private func isUnitInterval(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    func loadDeliveryPreflightCache(
        for records: [DocumentRecord]
    ) throws -> [UUID: PDFDeliveryPreflightCacheEntry] {
        try prepareDirectories()
        var result: [UUID: PDFDeliveryPreflightCacheEntry] = [:]
        var loadedByteCount: Int64 = 0
        for record in records {
            try Task.checkCancellation()
            guard result.count
                    < Self.maximumLoadedPreflightCacheEntries
            else { break }
            let url = deliveryPreflightURL(for: record.id)
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            do {
                try requireProtectedRegularFile(at: url)
                let data = try boundedData(
                    at: url,
                    maximumBytes: Self.maximumPreflightCacheBytes
                )
                let (nextByteCount, overflow) = loadedByteCount
                    .addingReportingOverflow(Int64(data.count))
                guard !overflow,
                      nextByteCount
                        <= Self.maximumLoadedPreflightCacheBytes
                else { continue }
                let entry = try JSONDecoder.paperPath.decode(
                    PDFDeliveryPreflightCacheEntry.self,
                    from: data
                )
                guard entry.recordID == record.id,
                      entry.revisionID == record.contentRevisionID,
                      entry.usesCurrentRules
                else {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                result[record.id] = entry
                loadedByteCount = nextByteCount
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }
        return result
    }

    func saveDeliveryPreflight(
        _ entry: PDFDeliveryPreflightCacheEntry
    ) throws {
        try prepareDirectories()
        do {
            let data = try JSONEncoder.paperPath.encode(entry)
            try requireData(
                data,
                maximumBytes: Self.maximumPreflightCacheBytes,
                label: "The local delivery check"
            )
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
            let data = try boundedData(
                at: batchDeliveryURL,
                maximumBytes: Self.maximumPersistedStateBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let run: PDFBatchDeliveryRun
            if let precise = try? decoder.decode(PDFBatchDeliveryRun.self, from: data) {
                run = precise
            } else {
                run = try JSONDecoder.paperPath.decode(PDFBatchDeliveryRun.self, from: data)
            }
            guard run.isStructurallyValid else {
                throw PaperPathError.storageFailure(
                    "The batch recovery state is structurally invalid."
                )
            }
            return run
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: batchDeliveryURL)
            return nil
        }
    }

    func saveBatchDeliveryRun(_ run: PDFBatchDeliveryRun) throws {
        try prepareDirectories()
        do {
            guard run.isStructurallyValid else {
                throw PaperPathError.storageFailure(
                    "The batch recovery state is structurally invalid."
                )
            }
            let encoder = JSONEncoder.paperPath
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(run)
            try requireData(
                data,
                maximumBytes: Self.maximumPersistedStateBytes,
                label: "The batch recovery state"
            )
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
            let data = try boundedData(
                at: batesBatchReceiptsURL,
                maximumBytes:
                    Int64(PDFBatesBatchReceiptPayload.maximumHistoryBytes)
            )
            let receipts = try JSONDecoder.paperPath.decode(
                [PDFSignedBatesBatchReceipt].self,
                from: data
            )
            let trustedDate = currentTrustedDate()
            guard receipts.count
                    <= PDFBatesBatchReceiptPayload.maximumReceiptCount,
                  Set(receipts.map(\.id)).count == receipts.count,
                  receipts.allSatisfy({
                      $0.payload.isStructurallyValid(at: trustedDate)
                          && (
                              $0.removal?.payload.isLinked(
                                  to: $0.payload,
                                  at: trustedDate
                              ) ?? true
                          )
                  })
            else {
                throw PaperPathError.storageFailure(
                    "The Bates receipt history is structurally invalid."
                )
            }
            return receipts.sorted(by: batesReceiptSortsBefore)
        } catch is CancellationError {
            throw CancellationError()
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
        let startedAt = currentTrustedDate()
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
        guard payload.isStructurallyValid(at: startedAt),
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
               for: receipt.payload,
               at: startedAt
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
        let checkedAt = currentTrustedDate()
        guard isValidBatesReceiptSignature(
            receipt,
            at: checkedAt
        ) else {
            return untrustedBatesBatchReport(
                receipt,
                status: .invalid,
                detail:
                    "The Bates receipt became invalid while its PDFs were being verified."
            )
        }
        return PDFBatesBatchReceiptVerificationReport(
            receiptID: receipt.id,
            checkedAt: checkedAt,
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
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount
                <= PDFBatesBatchReceiptPayload.maximumHistoryBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath Bates JSON under 1 MB."
            )
        }
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: Int64(
                PDFBatesBatchReceiptPayload.maximumHistoryBytes
            )
        )
        guard let receipt = try? JSONDecoder.paperPath.decode(
            PDFSignedBatesBatchReceipt.self,
            from: data
        ),
              receipt.payload.isStructurallyValid(
                at: currentTrustedDate()
              )
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
        let startedAt = currentTrustedDate()
        guard isValidBatesReceiptSignature(
            receipt,
            at: startedAt
        ) else {
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
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey
                ]
            )
            guard url.pathExtension.lowercased() == "pdf",
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
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

        let checkedAt = currentTrustedDate()
        guard isValidBatesReceiptSignature(
            receipt,
            at: checkedAt
        ) else {
            throw PaperPathError.outputVerificationFailed(
                "the Bates receipt became invalid while files were being matched"
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
            checkedAt: checkedAt,
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
        let trustedDate = try evidenceIssuanceDate()
        guard isValidBatesReceiptSignature(
                receipt,
                at: trustedDate
              ),
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
        guard payload.isStructurallyValid(at: trustedDate) else {
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
        let fileURL = try protectedTemporaryFile(
            directoryPrefix: "PaperPath-Bates-Match-",
            fileName:
                "PaperPath-Bates-Match-\(report.id.uuidString.prefix(8)).json"
        )
        try writeProtectedData(data, to: fileURL)
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
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= PDFBatesMatchReportPayload.maximumEncodedBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath Bates match report under 2 MB."
            )
        }
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: Int64(
                PDFBatesMatchReportPayload.maximumEncodedBytes
            )
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
        let inspectedAt = currentTrustedDate()
        let receiptSignatureStatus:
            PDFOfficeReportVerificationStatus =
                isValidBatesReceiptSignature(
                    signedReport.payload.receipt,
                    at: inspectedAt
                ) ? .verified : .invalid
        guard signedReport.payload.isStructurallyValid(
            at: inspectedAt
        ) else {
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
            trustedSigners[index].lastVerifiedAt =
                currentTrustedDate()
            incrementVerificationCount(&trustedSigners[index])
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
        let fileURL = try protectedTemporaryFile(
            directoryPrefix: "PaperPath-Bates-Receipt-",
            fileName:
                "PaperPath-Bates-\(receipt.id.uuidString.prefix(8)).json"
        )
        try writeProtectedData(data, to: fileURL)
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
            let data = try boundedData(
                at: officeProductionQueueURL,
                maximumBytes: Self.maximumPersistedStateBytes
            )
            return try JSONDecoder.paperPath.decode(
                PDFOfficeProductionQueue.self,
                from: data
            )
        } catch is CancellationError {
            throw CancellationError()
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
            try requireData(
                data,
                maximumBytes: Self.maximumPersistedStateBytes,
                label: "The Office production queue"
            )
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
        let trustedDate = currentTrustedDate()
        let packages: [PDFOfficeDeliveryPackage]
        if fileManager.fileExists(atPath: officeDeliveryIndexURL.path) {
            do {
                let data = try boundedData(
                    at: officeDeliveryIndexURL,
                    maximumBytes: Self.maximumPersistedStateBytes
                )
                packages = try JSONDecoder.paperPath.decode(
                    [PDFOfficeDeliveryPackage].self,
                    from: data
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? fileManager.removeItem(at: officeDeliveryIndexURL)
                packages = []
            }
        } else {
            packages = []
        }

        var valid: [PDFOfficeDeliveryPackage] = []
        var seenPackageIDs = Set<UUID>()
        for package in packages {
            guard seenPackageIDs.insert(package.id).inserted,
                  package.isStructurallyValid(at: trustedDate),
                  !package.isExpired(at: trustedDate),
                  let archiveFileName = package.archiveFileName,
                  let reportFileName = package.reportFileName,
                  isSafeOfficeDeliveryFileName(
                      archiveFileName,
                      for: package.id
                  ),
                  isSafeOfficeDeliveryFileName(
                      reportFileName,
                      for: package.id
                  )
            else {
                continue
            }
            let archiveURL = officeDeliveriesURL
                .appendingPathComponent(archiveFileName)
            let reportURL = officeDeliveriesURL
                .appendingPathComponent(reportFileName)
            guard isSafeRegularFile(
                at: archiveURL,
                containedIn: officeDeliveriesURL
            ),
                  isSafeRegularFile(
                    at: reportURL,
                    containedIn: officeDeliveriesURL
                  ),
                  logicalFileSize(archiveURL) == package.byteCount
            else {
                continue
            }
            try requireFileProtection(to: archiveURL)
            try requireFileProtection(to: reportURL)
            valid.append(package)
        }
        valid = boundedOfficeDeliveryPackages(valid)
        if valid != packages {
            try saveOfficeDeliveryPackages(valid)
            let retainedIDs = Set(valid.map(\.id))
            for package in packages
            where !retainedIDs.contains(package.id) {
                removeOfficeDeliveryFiles(package)
            }
        }
        pruneOfficeDeliveryArtifacts(retaining: valid)
        return valid.sorted(by: officePackageSortsBefore)
    }

    func officeDeliverySigningKeyID() throws -> String {
        let key = try officeDeliverySigningPrivateKey()
        return officeDeliverySigningKeyID(
            publicKeyData: key.publicKey.rawRepresentation
        )
    }

    func deliveryTimeAnchor() -> PDFOfficeTimeAnchor {
        _ = currentTrustedDate()
        return officeTimeAnchor
    }

    func trustedDeliveryDate() -> Date {
        currentTrustedDate()
    }

    func trustedOfficeDate() -> Date {
        trustedDeliveryDate()
    }

    func trustedEvidenceIssuanceDate() throws -> Date {
        try evidenceIssuanceDate()
    }

    func checkpointTrustedTime() {
        _ = currentTrustedDate(forceCheckpoint: true)
    }

    func officeDeliverySigningIdentityCard() throws
        -> PDFOfficeSignerIdentityCard {
        try officeDeliverySigningIdentityCard(
            generatedAt: currentTrustedDate()
        )
    }

    private func officeDeliverySigningIdentityCard(
        generatedAt: Date
    ) throws -> PDFOfficeSignerIdentityCard {
        let key = try officeDeliverySigningPrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        return PDFOfficeSignerIdentityCard(
            schema: "PaperPath Signing Identity V1",
            keyID: officeDeliverySigningKeyID(
                publicKeyData: publicKey
            ),
            publicKeyBase64: publicKey.base64EncodedString(),
            generatedAt: generatedAt
        )
    }

    func makeOfficeDeliverySigningIdentityCardFile() throws
        -> URL {
        let card = try officeDeliverySigningIdentityCard(
            generatedAt: evidenceIssuanceDate()
        )
        let url = try protectedTemporaryFile(
            directoryPrefix: "PaperPath-Signing-Identity-",
            fileName: "PaperPath-Signing-Identity-\(card.keyID).json"
        )
        let data = try JSONEncoder.paperPath.encode(card)
        try writeProtectedData(data, to: url)
        return url
    }

    func parseOfficeSignerIdentityPayload(
        _ payload: String
    ) throws -> PDFOfficeSignerIdentityCard {
        guard !payload.isEmpty,
              payload.utf8.count <= 1_024
        else {
            throw PaperPathError.insufficientSelection(
                "This signing identity QR code is too large."
            )
        }
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
            generatedAt: currentTrustedDate()
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
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= 64 * 1_024
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a PaperPath identity card under 64 KB."
            )
        }
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: 64 * 1_024
        )
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
            let data = try boundedData(
                at: officeTrustedSignersURL,
                maximumBytes: Self.maximumTrustedSignerBytes
            )
            decoded = try JSONDecoder.paperPath.decode(
                [PDFOfficeTrustedSigner].self,
                from: data
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: officeTrustedSignersURL)
            return []
        }
        var seenKeyIDs = Set<String>()
        let normalized = decoded.compactMap {
            normalizedTrustedSigner($0)
        }
        .sorted { $0.lastVerifiedAt > $1.lastVerifiedAt }
        .filter {
            seenKeyIDs.insert($0.keyID).inserted
        }
        .prefix(24)
        .map(\.self)
        if normalized != decoded {
            try? saveOfficeTrustedSigners(normalized)
        }
        return normalized
    }

    func trustOfficeReportSigner(
        _ verification: PDFOfficeReportVerificationResult
    ) throws -> [PDFOfficeTrustedSigner] {
        let systemUptime = ProcessInfo.processInfo.systemUptime
        let trustedDate = currentTrustedDate(
            wallDate: Date(),
            systemUptime: systemUptime
        )
        guard verification.canTrustSigner(
                at: trustedDate,
                systemUptime: systemUptime
              ),
              let keyID = verification.keyID,
              let publicKeyBase64 = verification.publicKeyBase64
        else {
            throw PaperPathError.insufficientSelection(
                "Only a valid unknown signer can be trusted."
            )
        }
        if let signedReport = verification.signedReport {
            guard signedReport.payload.isActive(at: trustedDate),
                  signedReport.signature.keyID == keyID,
                  signedReport.signature.publicKeyBase64
                    == publicKeyBase64,
                  isValidOfficeDeliveryReportSignature(
                    signedReport,
                    at: trustedDate
                  )
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery report is invalid or expired"
                )
            }
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
        let now = trustedDate
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
        let now = currentTrustedDate()
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
        let cleanName = normalizedTrustedSignerText(
            displayName,
            maximumCharacters: 64
        )
        let cleanNote = normalizedTrustedSignerText(
            note,
            maximumCharacters: 240
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
        let trustedDate = try evidenceIssuanceDate()
        guard payload.isActive(at: trustedDate) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report inventory is invalid or expired"
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

    func signChangeReportPayload(
        _ payload: PDFChangeReportSignaturePayload
    ) throws -> PDFSignedChangeReportEnvelope {
        let trustedDate = try evidenceIssuanceDate()
        guard payload.isStructurallyValid(at: trustedDate) else {
            throw PaperPathError.outputVerificationFailed(
                "the change report signature payload is invalid"
            )
        }
        let privateKey = try officeDeliverySigningPrivateKey()
        let canonicalPayload = try PDFChangeReportService
            .canonicalData(payload)
        let signature = try privateKey.signature(
            for: canonicalPayload
        )
        let publicKey = privateKey.publicKey.rawRepresentation
        return PDFSignedChangeReportEnvelope(
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
        let trustedDate = try evidenceIssuanceDate()
        guard manifest.schema == PDFVersionArchiveManifest.currentSchema,
              manifest.isStructurallyValid(at: trustedDate)
        else {
            throw PaperPathError.outputVerificationFailed(
                "the version archive manifest is invalid"
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
        let trustedDate = currentTrustedDate()
        guard let receipt = record.deliveryReceipt,
              receipt.isVerified(at: trustedDate),
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
            createdAt: trustedDate,
            artifactFileName: artifactFileName,
            record: record,
            receipt: receipt
        )
        return try signDeliveryPackageManifest(manifest)
    }

    func signDeliveryPackageManifest(
        _ manifest: PDFDeliveryPackageManifest
    ) throws -> PDFSignedDeliveryPackageManifest {
        let trustedDate = try evidenceIssuanceDate()
        guard manifest.isStructurallyValid(at: trustedDate) else {
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
        let trustedDate = currentTrustedDate()
        guard report.archiveCreatedAt.timeIntervalSince1970.isFinite,
              report.archiveCreatedAt.timeIntervalSince1970 >= 0,
              report.archiveCreatedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.verifiedAt <= trustedDate.addingTimeInterval(5 * 60),
              report.hasValidSourceSignature,
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
        trustedSigners[index].lastVerifiedAt =
            currentTrustedDate()
        incrementVerificationCount(&trustedSigners[index])
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
        let trustedDate = currentTrustedDate()
        guard report.packageCreatedAt.timeIntervalSince1970.isFinite,
              report.packageCreatedAt.timeIntervalSince1970 >= 0,
              report.packageCreatedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.verifiedAt <= trustedDate.addingTimeInterval(5 * 60),
              report.hasValidSourceSignature,
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
        trustedSigners[index].lastVerifiedAt =
            currentTrustedDate()
        incrementVerificationCount(&trustedSigners[index])
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
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              values.isSymbolicLink != true,
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
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: 5 * 1_024 * 1_024
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
        return try verifyOfficeDeliveryReport(report)
    }

    func verifyOfficeDeliveryReport(
        _ report: PDFOfficeSignedVerificationReport
    ) throws -> PDFOfficeReportVerificationResult {
        try Task.checkCancellation()
        let systemUptime = ProcessInfo.processInfo.systemUptime
        let verifiedAt = currentTrustedDate(
            wallDate: Date(),
            systemUptime: systemUptime
        )
        let resultTimeAnchor = PDFOfficeTimeAnchor(
            referenceDate: verifiedAt,
            systemUptime: systemUptime
        )
        guard report.payload.isStructurallyValid(
            at: verifiedAt
        ) else {
            return PDFOfficeReportVerificationResult(
                status: .invalid,
                packageID: report.payload.packageID,
                keyID: report.signature.keyID,
                sourceCount: Set(
                    report.payload.files.map(\.sourceRecordID)
                ).count,
                outputCount: report.payload.files.count,
                createdAt: report.payload.createdAt,
                verifiedAt: verifiedAt,
                timeAnchor: resultTimeAnchor,
                detail:
                    "The report structure, file metadata, or hash inventory is invalid.",
                publicKeyBase64:
                    report.signature.publicKeyBase64,
                trustStatus: .invalid,
                trustedSignerName: nil,
                signedReport: report
            )
        }
        guard report.signature.algorithm == "Ed25519" else {
            return PDFOfficeReportVerificationResult(
                status: .unsupported,
                packageID: report.payload.packageID,
                keyID: report.signature.keyID,
                sourceCount: Set(
                    report.payload.files.map(\.sourceRecordID)
                ).count,
                outputCount: report.payload.files.count,
                createdAt: report.payload.createdAt,
                expiresAt: report.payload.expiresAt,
                verifiedAt: verifiedAt,
                timeAnchor: resultTimeAnchor,
                detail:
                    "The report uses an unsupported signing envelope.",
                publicKeyBase64:
                    report.signature.publicKeyBase64,
                trustStatus: .unsupported,
                trustedSignerName: nil,
                signedReport: report
            )
        }
        guard let signatureMaterial =
                canonicalOfficeSignatureMaterial(
                    report.signature
                ),
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: signatureMaterial.publicKey
              ),
              let canonicalPayload = try? JSONEncoder.paperPath
                .encode(report.payload)
        else {
            return PDFOfficeReportVerificationResult(
                status: .invalid,
                packageID: report.payload.packageID,
                keyID: report.signature.keyID,
                sourceCount: Set(
                    report.payload.files.map(\.sourceRecordID)
                ).count,
                outputCount: report.payload.files.count,
                createdAt: report.payload.createdAt,
                expiresAt: report.payload.expiresAt,
                verifiedAt: verifiedAt,
                timeAnchor: resultTimeAnchor,
                detail:
                    "The report signing key or signature encoding is invalid.",
                publicKeyBase64:
                    report.signature.publicKeyBase64,
                trustStatus: .invalid,
                trustedSignerName: nil,
                signedReport: report
            )
        }

        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: signatureMaterial.publicKey
        )
        let valid = calculatedKeyID == report.signature.keyID
            && publicKey.isValidSignature(
                signatureMaterial.signature,
                for: canonicalPayload
            )
        let isExpired = valid
            && report.payload.expiresAt <= verifiedAt
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
                    trustedSigners[index].lastVerifiedAt = verifiedAt
                    incrementVerificationCount(&trustedSigners[index])
                    try saveOfficeTrustedSigners(trustedSigners)
                }
            }
        }
        return PDFOfficeReportVerificationResult(
            status: valid
                ? (isExpired ? .expired : .verified)
                : .invalid,
            packageID: report.payload.packageID,
            keyID: report.signature.keyID,
            sourceCount: Set(
                report.payload.files.map(\.sourceRecordID)
            ).count,
            outputCount: report.payload.files.count,
            createdAt: report.payload.createdAt,
            expiresAt: report.payload.expiresAt,
            verifiedAt: verifiedAt,
            timeAnchor: resultTimeAnchor,
            detail: isExpired
                ? "The signature is valid, but this delivery report has expired."
                : valid
                    ? "The report payload matches its Ed25519 signature."
                    : "The report payload, public key, or signature was changed.",
            publicKeyBase64: report.signature.publicKeyBase64,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            signedReport: report
        )
    }

    func verifyChangeReport(
        at sourceURL: URL
    ) throws -> PDFChangeReportVerificationResult {
        try Task.checkCancellation()
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceURL.pathExtension.lowercased() == "md",
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 5 * 1_024 * 1_024
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath change report under 5 MB."
            )
        }
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: 5 * 1_024 * 1_024
        )
        let parsed = try PDFChangeReportService()
            .parseSignedReport(data)
        let payload = parsed.envelope.payload
        let signature = parsed.envelope.signature
        let verifiedAt = currentTrustedDate()
        let baseResult: (
            PDFOfficeReportVerificationStatus,
            String,
            PDFOfficeSignerTrustStatus
        )

        guard payload.isStructurallyValid(at: verifiedAt) else {
            baseResult = (
                .invalid,
                "The change report identity or evidence inventory is invalid.",
                .invalid
            )
            return changeReportVerificationResult(
                payload: payload,
                signature: signature,
                status: baseResult.0,
                detail: baseResult.1,
                trustStatus: baseResult.2,
                trustedSignerName: nil
            )
        }
        try Task.checkCancellation()
        let actualBodySHA256 = SHA256.hash(data: parsed.body)
            .map { String(format: "%02x", $0) }
            .joined()
        guard parsed.body.count == payload.bodyByteCount,
              actualBodySHA256.caseInsensitiveCompare(
                payload.bodySHA256
              ) == .orderedSame,
              PDFChangeReportService().bodyIdentityMatches(
                parsed.body,
                payload: payload,
                signerKeyID: signature.keyID
              )
        else {
            return changeReportVerificationResult(
                payload: payload,
                signature: signature,
                status: .invalid,
                detail:
                    "The readable report body or its identity fields changed after signing.",
                trustStatus: .invalid,
                trustedSignerName: nil
            )
        }
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
              let canonicalPayload = try? PDFChangeReportService
                .canonicalData(payload)
        else {
            return changeReportVerificationResult(
                payload: payload,
                signature: signature,
                status: .unsupported,
                detail:
                    "The change report uses an unsupported signing envelope.",
                trustStatus: .unsupported,
                trustedSignerName: nil
            )
        }
        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: publicKeyData
        )
        let isValid = calculatedKeyID == signature.keyID
            && publicKey.isValidSignature(
                signatureData,
                for: canonicalPayload
            )
        guard isValid else {
            return changeReportVerificationResult(
                payload: payload,
                signature: signature,
                status: .invalid,
                detail:
                    "The change report payload, public key, or signature changed.",
                trustStatus: .invalid,
                trustedSignerName: nil
            )
        }

        var trustStatus = PDFOfficeSignerTrustStatus.unknown
        var trustedSignerName: String?
        let localIdentity = try? officeDeliverySigningIdentityCard()
        if localIdentity?.keyID == calculatedKeyID,
           localIdentity?.publicKeyBase64
            == signature.publicKeyBase64 {
            trustStatus = .thisDevice
        } else {
            var trustedSigners = try loadOfficeTrustedSigners()
            if let index = trustedSigners.firstIndex(
                where: {
                    $0.keyID == calculatedKeyID
                        && $0.publicKeyBase64
                            == signature.publicKeyBase64
                }
            ) {
                trustStatus = .trusted
                trustedSignerName = trustedSigners[index].displayName
                trustedSigners[index].lastVerifiedAt =
                    verifiedAt
                incrementVerificationCount(&trustedSigners[index])
                try saveOfficeTrustedSigners(trustedSigners)
            }
        }
        return changeReportVerificationResult(
            payload: payload,
            signature: signature,
            status: .verified,
            detail:
                "The readable report body matches its Ed25519 signature.",
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName,
            verifiedBody: parsed.body
        )
    }

    func trustChangeReportSigner(
        _ report: PDFChangeReportVerificationResult
    ) throws -> PDFChangeReportVerificationResult {
        let trustedDate = currentTrustedDate()
        guard report.generatedAt.timeIntervalSince1970.isFinite,
              report.generatedAt.timeIntervalSince1970 >= 0,
              report.generatedAt
                <= trustedDate.addingTimeInterval(5 * 60),
              report.canTrustSigner
        else {
            throw PaperPathError.insufficientSelection(
                "Only a valid unknown signer can be trusted."
            )
        }
        let bridge = PDFOfficeReportVerificationResult(
            status: report.status,
            packageID: report.reportID,
            keyID: report.keyID,
            sourceCount: 2,
            outputCount: report.changedPageCount,
            createdAt: report.generatedAt,
            detail: report.detail,
            publicKeyBase64: report.publicKeyBase64,
            trustStatus: report.trustStatus,
            trustedSignerName: report.trustedSignerName
        )
        let signers = try trustOfficeReportSigner(bridge)
        let name = signers.first {
            $0.keyID == report.keyID
        }?.displayName
        return report.resolvingTrust(
            .trusted,
            trustedSignerName: name
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
        let startedAt = currentTrustedDate()
        guard report.payload.isActive(at: startedAt) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report is invalid or expired"
            )
        }
        guard isValidOfficeDeliveryReportSignature(
            report,
            at: startedAt
        ) else {
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
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            let fileExtension = url.pathExtension.lowercased()
            guard expectedExtensions.contains(fileExtension),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
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
        let checkedAt = currentTrustedDate()
        guard report.payload.isActive(at: checkedAt) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report expired while files were being matched"
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
            checkedAt: checkedAt,
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
        let trustedDate = try evidenceIssuanceDate()
        guard deliveryReport.payload.isActive(at: trustedDate) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report is invalid or expired"
            )
        }
        guard isValidOfficeDeliveryReportSignature(
                deliveryReport,
                at: trustedDate
              ),
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
        guard payload.isStructurallyValid(at: trustedDate) else {
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
        let fileURL = try protectedTemporaryFile(
            directoryPrefix: "PaperPath-Delivery-Match-",
            fileName:
                "PaperPath-Delivery-Match-\(matchReport.id.uuidString.prefix(8)).json"
        )
        try writeProtectedData(data, to: fileURL)
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
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard sourceURL.pathExtension.lowercased() == "json",
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount
                <= PDFOfficeMatchReportPayload.maximumEncodedBytes
        else {
            throw PaperPathError.insufficientSelection(
                "Choose a signed PaperPath Delivery match report under 4 MB."
            )
        }
        let data = try boundedData(
            at: sourceURL,
            maximumBytes: Int64(
                PDFOfficeMatchReportPayload.maximumEncodedBytes
            )
        )
        guard let signedReport = try? JSONDecoder.paperPath.decode(
            PDFSignedOfficeMatchReport.self,
            from: data
        ) else {
            throw PaperPathError.insufficientSelection(
                "This JSON is not a supported PaperPath Delivery match report."
            )
        }
        let inspectedAt = currentTrustedDate()
        let fileName = String(
            sourceURL.lastPathComponent.prefix(180)
        )
        let deliveryIsValid = isValidOfficeDeliveryReportSignature(
            signedReport.payload.deliveryReport,
            at: inspectedAt
        )
        let deliveryIsExpired = deliveryIsValid
            && signedReport.payload.deliveryReport.payload
                .expiresAt <= inspectedAt
        let deliverySignatureStatus:
            PDFOfficeReportVerificationStatus =
                deliveryIsValid
                    ? (deliveryIsExpired ? .expired : .verified)
                    : .invalid
        let localKeyID = try? officeDeliverySigningKeyID()
        let trustedSigners = try loadOfficeTrustedSigners()
        let deliveryTrust = officeSignerTrust(
            for: signedReport.payload.deliveryReport.signature,
            signatureIsValid: deliveryIsValid,
            localKeyID: localKeyID,
            trustedSigners: trustedSigners
        )
        guard signedReport.payload.isStructurallyValid(
            at: inspectedAt
        ) else {
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
        guard signature.algorithm == "Ed25519" else {
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
        guard let signatureMaterial =
                canonicalOfficeSignatureMaterial(signature),
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: signatureMaterial.publicKey
              ),
              let canonicalPayload = try? JSONEncoder.paperPath.encode(
                  signedReport.payload
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
                    "The Delivery match report signing key or signature encoding is invalid."
            )
        }
        let calculatedKeyID = officeDeliverySigningKeyID(
            publicKeyData: signatureMaterial.publicKey
        )
        guard calculatedKeyID == signature.keyID,
              publicKey.isValidSignature(
                  signatureMaterial.signature,
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
            mutableTrustedSigners[index].lastVerifiedAt = inspectedAt
            incrementVerificationCount(&mutableTrustedSigners[index])
            try saveOfficeTrustedSigners(mutableTrustedSigners)
        }
        let detail: String
        if deliveryIsExpired {
            detail =
                "The match report is valid, but its embedded Delivery report has expired."
        } else if !deliveryIsValid {
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
        try ensureTemporaryWorkingCapacity(
            for: [archiveURL, reportURL],
            copyMultiplier: 1
        )
        try Task.checkCancellation()

        let archiveFileName = "\(package.id.uuidString).zip"
        let reportFileName =
            "\(package.id.uuidString)-verification.json"
        let destinationArchive = officeDeliveriesURL
            .appendingPathComponent(archiveFileName)
        let destinationReport = officeDeliveriesURL
            .appendingPathComponent(reportFileName)
        var packages = try loadOfficeDeliveryPackages()
        if let existing = packages.first(
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
            let trustedDate = currentTrustedDate()
            guard retained.isStructurallyValid(at: trustedDate) else {
                throw PaperPathError.outputVerificationFailed(
                    "the retained Office delivery package metadata is invalid"
                )
            }
            packages.removeAll { $0.id == retained.id }
            packages.insert(retained, at: 0)
            let boundedPackages =
                boundedOfficeDeliveryPackages(packages)
            try saveOfficeDeliveryPackages(boundedPackages)
            let retainedIDs = Set(boundedPackages.map(\.id))
            for removed in packages
            where !retainedIDs.contains(removed.id) {
                removeOfficeDeliveryFiles(removed)
            }
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
        for package: PDFOfficeDeliveryPackage,
        reportOnly: Bool = false
    ) throws -> (archive: URL, report: URL) {
        let trustedDate = currentTrustedDate()
        guard package.isStructurallyValid(at: trustedDate),
              let archiveFileName = package.archiveFileName,
              let reportFileName = package.reportFileName,
              let expectedFingerprint = package.sha256,
              let expectedReportFingerprint = package.reportSHA256
        else {
            throw PaperPathError.insufficientSelection(
                "This Office delivery package is no longer available."
            )
        }
        guard archiveFileName == "\(package.id.uuidString).zip",
              reportFileName
                == "\(package.id.uuidString)-verification.json"
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery package contains invalid file references"
            )
        }
        let archive = officeDeliveriesURL
            .appendingPathComponent(archiveFileName)
        let report = officeDeliveriesURL
            .appendingPathComponent(reportFileName)
        guard isContained(report, in: officeDeliveriesURL) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report escaped private storage"
            )
        }
        guard fileManager.fileExists(atPath: report.path) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report is missing"
            )
        }
        guard let reportValues = try? report.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ) else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report metadata is unavailable"
            )
        }
        guard reportValues.isRegularFile == true else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report is not a regular file"
            )
        }
        guard reportValues.isSymbolicLink != true else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report is a symbolic link"
            )
        }
        guard try fileFingerprint(at: report)
                == expectedReportFingerprint
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office delivery report hash changed"
            )
        }
        let reportData = try boundedData(
            at: report,
            maximumBytes: 5 * 1_024 * 1_024
        )
        guard let signedReport = try? JSONDecoder.paperPath.decode(
                PDFOfficeSignedVerificationReport.self,
                from: reportData
              ),
              signedReport.payload.packageID == package.id,
              officeEvidenceDatesMatch(
                  signedReport.payload.createdAt,
                  package.createdAt
              ),
              signedReport.payload.files == package.entries,
              isValidOfficeDeliveryReportSignature(
                signedReport,
                at: trustedDate
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the retained Office delivery report no longer matches its package"
            )
        }
        if !reportOnly,
           !signedReport.payload.isActive(at: trustedDate) {
            throw PaperPathError.insufficientSelection(
                "This Office delivery report has expired. Create a new package before sharing."
            )
        }
        if !reportOnly {
            guard isContained(archive, in: officeDeliveriesURL) else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive escaped private storage"
                )
            }
            guard fileManager.fileExists(atPath: archive.path) else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive is missing"
                )
            }
            guard let archiveValues = try? archive.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            ) else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive metadata is unavailable"
                )
            }
            guard archiveValues.isRegularFile == true else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive is not a regular file"
                )
            }
            guard archiveValues.isSymbolicLink != true else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive is a symbolic link"
                )
            }
            guard logicalFileSize(archive) == package.byteCount else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive size changed"
                )
            }
            guard try fileFingerprint(at: archive)
                    == expectedFingerprint
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the Office delivery archive hash changed"
                )
            }
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
        packages[index].pinnedAt = pinned
            ? currentTrustedDate()
            : nil
        let boundedPackages = boundedOfficeDeliveryPackages(packages)
        try saveOfficeDeliveryPackages(boundedPackages)
        let retainedIDs = Set(boundedPackages.map(\.id))
        for removed in packages
        where !retainedIDs.contains(removed.id) {
            removeOfficeDeliveryFiles(removed)
        }
        return boundedPackages
    }

    func deleteOfficeDeliveryPackage(
        _ packageID: UUID
    ) throws -> [PDFOfficeDeliveryPackage] {
        var packages = try loadOfficeDeliveryPackages()
        guard let package = packages.first(
            where: { $0.id == packageID }
        ) else { return packages }
        packages.removeAll { $0.id == packageID }
        try saveOfficeDeliveryPackages(packages)
        removeOfficeDeliveryFiles(package)
        return packages
    }

    func createVersionSnapshot(
        for record: DocumentRecord,
        label: String,
        preservingVersionID: UUID? = nil,
        allowsDeliveryArtifact: Bool = false
    ) throws -> PDFVersionSnapshot {
        try Task.checkCancellation()
        try prepareDirectories()
        let records = try loadIndex()
        guard let stored = records.first(where: {
            $0.id == record.id
        }),
              stored.deletedAt == nil,
              stored.isWorkingCopy
                || allowsDeliveryArtifact
                    && stored.isDeliveryArtifact,
              stored.contentRevisionID == record.contentRevisionID
        else {
            throw PaperPathError.insufficientSelection(
                "The working copy changed before the recovery version was created."
            )
        }
        let sourceURL = url(for: stored)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PaperPathError.storageFailure(
                "The working copy is unavailable for versioning."
            )
        }
        let fingerprint = try fileFingerprint(at: sourceURL)
        let sourceProfile = try inspector.inspect(url: sourceURL)
        guard !sourceProfile.isLocked else {
            throw PaperPathError.lockedPDF
        }
        let allExisting = try loadVersionIndex()
        let existing = allExisting
            .filter { $0.documentID == stored.id }
            .sorted(by: versionSortsBefore)
        if let latest = existing.first,
           latest.contentFingerprint == fingerprint,
           latest.contentRevisionID == stored.contentRevisionID,
           latest.bookmarkedPages == stored.bookmarkedPages,
           latest.bookmarkNames == stored.bookmarkNames,
           latest.lastPageIndex == stored.lastPageIndex,
           isAvailableVersionSnapshot(latest) {
            return latest
        }

        let measuredSourceBytes = logicalFileSize(sourceURL)
        guard measuredSourceBytes > 0 else {
            throw PaperPathError.storageFailure(
                "The working copy size could not be verified for versioning."
            )
        }
        let protectedExisting = allExisting.compactMap {
            snapshot -> PDFVersionSnapshot? in
            guard snapshot.isPinnedMilestone
                    || snapshot.id == preservingVersionID
            else { return nil }
            return measuredVersionSnapshot(snapshot)
        }
        let protectedBytes = protectedExisting.reduce(Int64.zero) {
            saturatingAdd($0, $1.byteCount)
        }
        guard saturatingAdd(
            protectedBytes,
            measuredSourceBytes
        ) <= Self.maximumVersionBytes else {
            throw PaperPathError.insufficientSelection(
                "Unpin or archive older milestones before creating another recovery version."
            )
        }

        try ensureCapacity(for: sourceURL)
        let id = UUID()
        let documentDirectory = versionsURL.appendingPathComponent(
            stored.id.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        try requireFileProtection(to: documentDirectory)
        excludeFromBackup(documentDirectory)

        let fileName = "\(stored.id.uuidString)/\(id.uuidString).pdf"
        let destination = versionsURL.appendingPathComponent(fileName)
        let temporary = documentDirectory.appendingPathComponent(
            ".\(id.uuidString).pending"
        )
        do {
            try Task.checkCancellation()
            let copiedFile = try copyProtectedFile(
                from: sourceURL,
                to: temporary,
                expectedByteCount: measuredSourceBytes
            )
            guard copiedFile.sha256 == fingerprint else {
                throw PaperPathError.outputVerificationFailed(
                    "the working copy changed while its recovery version was created"
                )
            }
            try fileManager.moveItem(at: temporary, to: destination)
            try requireFileProtection(to: destination)
            guard logicalFileSize(destination) == measuredSourceBytes
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the recovery version did not match the working copy"
                )
            }
            try Task.checkCancellation()
            let normalizedLabel = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = PDFVersionSnapshot(
                id: id,
                documentID: stored.id,
                createdAt: currentTrustedDate(),
                label: String(
                    (
                        normalizedLabel.isEmpty
                            ? "Document edit"
                            : normalizedLabel
                    ).prefix(80)
                ),
                fileName: fileName,
                byteCount: measuredSourceBytes,
                pageCount: sourceProfile.pageCount,
                contentRevisionID: stored.contentRevisionID,
                contentFingerprint: fingerprint,
                bookmarkedPages: stored.bookmarkedPages,
                bookmarkNames: stored.bookmarkNames,
                lastPageIndex: stored.lastPageIndex,
                milestoneName: nil,
                isPinned: nil,
                linkedDeliveryReceiptID: nil,
                linkedDeliveryReceipt: nil
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
            try Task.checkCancellation()
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

    func versionHistoryOverview(
        for recordID: UUID
    ) throws -> (
        versions: [PDFVersionSnapshot],
        pinnedStorageSummary: PDFPinnedVersionStorageSummary
    ) {
        try prepareDirectories()
        var versions: [PDFVersionSnapshot] = []
        var pinned: [PDFVersionSnapshot] = []
        for snapshot in try loadVersionIndex()
        where snapshot.documentID == recordID || snapshot.isPinnedMilestone {
            try Task.checkCancellation()
            guard let measured = measuredVersionSnapshot(snapshot) else { continue }
            if snapshot.documentID == recordID {
                versions.append(normalizedVersionReceiptLink(measured))
            }
            if measured.isPinnedMilestone {
                pinned.append(measured)
            }
        }
        return (
            versions.sorted(by: versionSortsBefore),
            PDFPinnedVersionStorageSummary.measuring(pinned)
        )
    }

    func versions(
        for recordID: UUID
    ) throws -> [PDFVersionSnapshot] {
        try prepareDirectories()
        return try loadVersionIndex()
            .compactMap {
                guard $0.documentID == recordID else { return nil }
                return measuredVersionSnapshot($0).map(
                    normalizedVersionReceiptLink
                )
            }
            .sorted(by: versionSortsBefore)
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
        ),
              isAvailableVersionSnapshot(snapshot)
        else {
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
        try Task.checkCancellation()
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
        guard isAvailableVersionSnapshot(existing) else {
            throw PaperPathError.storageFailure(
                "The selected recovery version is unavailable."
            )
        }
        guard pinned || linkedDeliveryReceiptID == nil else {
            throw PaperPathError.insufficientSelection(
                "A delivery receipt link requires a pinned milestone."
            )
        }
        let linkedReceipt: PDFDeliveryReceipt?
        if let linkedDeliveryReceiptID {
            if let archived = existing.archivedDeliveryReceipt,
               archived.id == linkedDeliveryReceiptID {
                linkedReceipt = archived.milestoneArchiveCopy
            } else {
                let currentReceipt = try loadIndex()
                    .first(where: { $0.id == recordID })?
                    .deliveryReceipt
                guard let currentReceipt,
                      currentReceipt.id == linkedDeliveryReceiptID,
                      existing.matchesDeliveryReceipt(currentReceipt)
                else {
                    throw PaperPathError.insufficientSelection(
                        "Only a version matching the stored delivery receipt can be linked."
                    )
                }
                linkedReceipt = currentReceipt.milestoneArchiveCopy
            }
        } else {
            linkedReceipt = nil
        }
        if pinned, !existing.isPinnedMilestone {
            let pinnedSnapshots: [PDFVersionSnapshot] =
                snapshots.compactMap { snapshot in
                guard snapshot.isPinnedMilestone else { return nil }
                return measuredVersionSnapshot(snapshot)
            }
            let summary = PDFPinnedVersionStorageSummary.measuring(
                pinnedSnapshots
            )
            let measuredExisting = measuredVersionSnapshot(existing)
            guard let measuredExisting,
                  summary.canAdd(bytes: measuredExisting.byteCount)
            else {
                throw PaperPathError.insufficientSelection(
                    "Keep up to 32 pinned milestones and 1 GB across the library."
                )
            }
        }
        snapshots[index] = existing.updatingMilestone(
            name: normalizedName,
            pinned: pinned,
            linkedDeliveryReceiptID: linkedDeliveryReceiptID,
            deliveryReceipt: linkedReceipt
        )
        let pinnedIDs = Set(
            snapshots.filter(\.isPinnedMilestone).map(\.id)
        )
        let retention = retainedVersions(
            from: snapshots,
            preserving: pinnedIDs
        )
        try Task.checkCancellation()
        try saveVersionIndex(retention.kept)
        for removed in retention.removed {
            try? fileManager.removeItem(
                at: versionURL(for: removed)
            )
        }
        removeEmptyVersionDirectories()
        return retention.kept
            .filter { $0.documentID == recordID }
            .sorted(by: versionSortsBefore)
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
            let sourceBytes = logicalFileSize(url(for: record))
            let pinnedSummary = PDFPinnedVersionStorageSummary.measuring(
                try pinnedVersionMilestones()
            )
            guard sourceBytes > 0,
                  pinnedSummary.canAdd(bytes: sourceBytes)
            else {
                throw PaperPathError.insufficientSelection(
                    "Unpin or archive older milestones before protecting this receipt."
                )
            }
            let created = try createVersionSnapshot(
                for: record,
                label: label,
                allowsDeliveryArtifact: true
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
            .compactMap {
                guard $0.isPinnedMilestone else { return nil }
                return measuredVersionSnapshot($0).map(
                    normalizedVersionReceiptLink
                )
            }
            .sorted(by: versionSortsBefore)
    }

    func unpinAllVersionMilestones() throws -> Int {
        try Task.checkCancellation()
        try prepareDirectories()
        let snapshots = try loadVersionIndex()
        let pinnedCount = snapshots.filter(\.isPinnedMilestone).count
        guard pinnedCount > 0 else { return 0 }
        let updated = snapshots.map { snapshot in
            guard snapshot.isPinnedMilestone else { return snapshot }
            return snapshot.updatingMilestone(
                name: snapshot.milestoneName,
                pinned: false,
                linkedDeliveryReceiptID: nil
            )
        }
        let retention = retainedVersions(
            from: updated,
            preserving: []
        )
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        try prepareDirectories()
        let records = try loadIndex()
        guard let stored = records.first(where: {
            $0.id == record.id
        }),
              stored.deletedAt == nil,
              stored.isWorkingCopy,
              stored.contentRevisionID == record.contentRevisionID
        else {
            throw PaperPathError.insufficientSelection(
                "The working copy changed before the recovery version was restored."
            )
        }
        guard let snapshot = try loadVersionIndex().first(where: {
            $0.id == snapshotID && $0.documentID == stored.id
        }),
              isAvailableVersionSnapshot(snapshot)
        else {
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

        let restoredProfile = try inspector.inspect(url: source)
        guard restoredProfile.pageCount == snapshot.pageCount else {
            throw PaperPathError.outputVerificationFailed(
                "the recovery version page count did not match its saved index"
            )
        }
        // Publish PDF bytes and the index under the same recovery journal.
        let result = try commitWorkingCopies(
            [
                PreparedPDFWorkingCopy(
                    recordID: stored.id,
                    sourceRevisionID: stored.contentRevisionID,
                    preparedURL: source,
                    restoredBookmarkedPages: snapshot.bookmarkedPages,
                    restoredBookmarkNames: snapshot.bookmarkNames,
                    restoredLastPageIndex: snapshot.lastPageIndex,
                    restoresNavigationState: true,
                    expectedFingerprint: snapshot.contentFingerprint,
                    expectedPageCount: snapshot.pageCount
                )
            ],
            invalidateAnalysis: true,
            batesPlan: nil,
            batesRemovalReceiptID: nil,
            requiresMatchingPageCount: false,
            resetsCompletionEvidence: true
        )
        guard let restored = result.records.first else {
            throw PaperPathError.storageFailure(
                "The selected recovery version is unavailable."
            )
        }
        return restored
    }

    func moveToTrash(_ record: DocumentRecord) throws -> DocumentRecord {
        guard let updated = try moveToTrash(
            recordIDs: Set([record.id])
        ).first else {
            throw PaperPathError.storageFailure(
                "The document record is missing."
            )
        }
        return updated
    }

    func moveToTrash(
        recordIDs: Set<UUID>
    ) throws -> [DocumentRecord] {
        try updateStoredRecords(
            ids: recordIDs,
            requiring: { $0.deletedAt == nil }
        ) { updated, now in
            updated.deletedAt = now
            updated.isPinned = false
            updated.taskCheckpoint = nil
            updated.modifiedAt = now
            return true
        }
    }

    func restoreFromTrash(
        _ record: DocumentRecord
    ) throws -> DocumentRecord {
        guard let updated = try restoreFromTrash(
            recordIDs: Set([record.id])
        ).first else {
            throw PaperPathError.storageFailure(
                "The document record is missing."
            )
        }
        return updated
    }

    func restoreFromTrash(
        recordIDs: Set<UUID>
    ) throws -> [DocumentRecord] {
        try updateStoredRecords(
            ids: recordIDs,
            requiring: { $0.deletedAt != nil }
        ) { updated, now in
            updated.deletedAt = nil
            updated.modifiedAt = now
            return true
        }
    }

    func delete(_ record: DocumentRecord) throws {
        try permanentlyDelete(record)
    }

    func permanentlyDelete(_ record: DocumentRecord) throws {
        let deletedIDs = try commitPermanentDeletion(
            recordIDs: [record.id]
        )
        guard deletedIDs.contains(record.id) else {
            throw PaperPathError.storageFailure(
                "The private copy is no longer in Trash."
            )
        }
    }

    func permanentlyDelete(
        recordIDs: Set<UUID>
    ) throws -> [UUID] {
        let records = try loadIndex()
        let deletableIDs = Set(
            records.lazy
                .filter {
                    recordIDs.contains($0.id)
                        && $0.deletedAt != nil
                }
                .map(\.id)
        )
        guard deletableIDs == recordIDs else {
            throw PaperPathError.storageFailure(
                "One or more selected private copies are no longer in Trash."
            )
        }
        let deletedIDs = try commitPermanentDeletion(
            recordIDs: recordIDs
        )
        guard Set(deletedIDs) == recordIDs else {
            throw PaperPathError.storageFailure(
                "One or more selected private copies are no longer in Trash."
            )
        }
        return deletedIDs
    }

    func purgeDeleted(before cutoff: Date) throws -> [UUID] {
        let records = try loadIndex()
        let expired = records.filter {
            guard let deletedAt = $0.deletedAt else { return false }
            return deletedAt < cutoff
        }
        guard !expired.isEmpty else { return [] }
        return try commitPermanentDeletion(
            recordIDs: Set(expired.map(\.id))
        )
    }

    private func commitPermanentDeletion(
        recordIDs: Set<UUID>
    ) throws -> [UUID] {
        try Task.checkCancellation()
        try prepareDirectories()
        let records = try loadIndex()
        let deletedRecords = records.filter {
            recordIDs.contains($0.id) && $0.deletedAt != nil
        }
        guard !deletedRecords.isEmpty else { return [] }

        let deletedIDs = Set(deletedRecords.map(\.id))
        let remainingRecords = records.filter {
            !deletedIDs.contains($0.id)
        }
        let remainingVersions = try loadVersionIndex().filter {
            !deletedIDs.contains($0.documentID)
        }
        let remainingPageMatchCorrections =
            try reconciledPageMatchCorrections().filter {
                !deletedIDs.contains($0.sourceDocumentID)
                    && !deletedIDs.contains(
                        $0.revisedDocumentID
                    )
            }
        let retainedChangeReports =
            try reconciledRetainedChangeReports()
        let unlinkedChangeReports = retainedChangeReports.map {
            $0.removingLocalLink(referencing: deletedIDs)
        }
        var metadataWrites: [(data: Data, destination: URL)] = [
            (
                data: try encodedLibraryIndex(remainingRecords),
                destination: indexURL
            ),
            (
                data: try encodedVersionIndex(remainingVersions),
                destination: versionsIndexURL
            )
        ]
        if !remainingPageMatchCorrections.isEmpty
            || fileManager.fileExists(
                atPath: pageMatchCorrectionsURL.path
            ) {
            metadataWrites.append(
                (
                    data: try encodedPageMatchCorrections(
                        remainingPageMatchCorrections
                    ),
                    destination: pageMatchCorrectionsURL
                )
            )
        }
        if unlinkedChangeReports != retainedChangeReports {
            metadataWrites.append(
                (
                    data: try encodedRetainedChangeReports(
                        unlinkedChangeReports
                    ),
                    destination: retainedChangeReportsIndexURL
                )
            )
        }
        try writeProtectedDataTransaction(metadataWrites)
        if remainingPageMatchCorrections.isEmpty {
            try? fileManager.removeItem(
                at: pageMatchCorrectionsURL
            )
        }

        removeCommittedRecordArtifacts(
            deletedRecords,
            retaining: remainingRecords
        )
        pruneOrphanedRecordArtifacts(retaining: remainingRecords)
        pruneOfficeExports(for: remainingRecords)
        return deletedRecords.map(\.id)
    }

    func url(for record: DocumentRecord) -> URL {
        guard let url = safeDocumentURL(for: record),
              isSafeRegularFile(
                  at: url,
                  containedIn: filesURL
              )
        else {
            return filesURL.appendingPathComponent(
                "\(record.id.uuidString).invalid"
            )
        }
        return url
    }

    func containsDocuments() throws -> Bool {
        try !load().isEmpty
    }

    func storageInventory() throws -> DocumentStoreStorageInventory {
        let snapshot = try storageSnapshot()
        let pinnedMilestones = try pinnedVersionMilestones()
        let changeReports = try retainedChangeReportInventory()
        try Task.checkCancellation()
        return DocumentStoreStorageInventory(
            snapshot: snapshot,
            pinnedMilestones: pinnedMilestones,
            changeReports: changeReports
        )
    }

    func storageSnapshot() throws -> LocalStorageSnapshot {
        try prepareDirectories()
        try Task.checkCancellation()
        let versionStorageHealth: PDFVersionStorageHealth
        do {
            versionStorageHealth = try reconcileVersionStorage()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            versionStorageHealth = .empty
        }
        let pageMatchCorrections =
            try reconciledPageMatchCorrections()
        let pageMatchStorage =
            PDFManualPageMatchStorageSummary.measuring(
                pageMatchCorrections,
                byteCount: logicalFileSize(
                    pageMatchCorrectionsURL
                )
            )
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
            changeReportBytes: directorySizes[
                changeReportsURL.lastPathComponent,
                default: 0
            ],
            metadataBytes: [
                indexURL,
                versionsIndexURL,
                batchDeliveryURL,
                officeProductionQueueURL,
                officeDeliveryIndexURL,
                officeTrustedSignersURL,
                batesBatchReceiptsURL,
                pageMatchCorrectionsURL,
                retainedChangeReportsIndexURL
            ].reduce(Int64.zero) {
                saturatingAdd($0, fileSize($1))
            },
            versionStorageHealth: versionStorageHealth,
            pageMatchStorage: pageMatchStorage
        )
    }

    func availableCapacityForOfficeProduction() throws -> Int64? {
        try prepareDirectories()
        return availableCapacity(rootURL)
    }

    func ensureTemporaryWorkingCapacity(
        for sourceURLs: [URL],
        copyMultiplier: Int,
        reserveBytes: Int64 = 16 * 1_024 * 1_024
    ) throws {
        try prepareDirectories()
        guard !sourceURLs.isEmpty,
              sourceURLs.count <= 64,
              (1...8).contains(copyMultiplier),
              reserveBytes >= 0
        else {
            throw PaperPathError.storageFailure(
                "The temporary storage forecast is invalid."
            )
        }
        let uniqueURLs = Dictionary(
            sourceURLs.map {
                ($0.standardizedFileURL.path, $0)
            },
            uniquingKeysWith: { first, _ in first }
        ).values
        var sourceBytes: Int64 = 0
        for url in uniqueURLs {
            try Task.checkCancellation()
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let rawSize = values.fileSize,
                  rawSize > 0
            else {
                throw PaperPathError.storageFailure(
                    "A file required for the operation is unavailable."
                )
            }
            sourceBytes = saturatingAdd(
                sourceBytes,
                Int64(rawSize)
            )
        }
        let (workingBytes, didOverflow) =
            sourceBytes.multipliedReportingOverflow(
                by: Int64(copyMultiplier)
            )
        let requiredBytes = didOverflow
            ? Int64.max
            : saturatingAdd(workingBytes, reserveBytes)
        guard let available = availableCapacity(rootURL) else {
            return
        }
        guard available >= requiredBytes else {
            throw PaperPathError.insufficientStorage
        }
    }

    private func updateStoredRecord(
        id recordID: UUID,
        mutation: (inout DocumentRecord) -> Bool
    ) throws -> DocumentRecord {
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        guard let index = records.firstIndex(where: {
            $0.id == recordID
        }) else {
            throw PaperPathError.storageFailure(
                "The document record is missing."
            )
        }
        var updated = records[index]
        guard mutation(&updated) else { return updated }
        try Task.checkCancellation()
        records[index] = updated
        try saveIndex(records)
        return updated
    }

    private func updateStoredRecords(
        ids recordIDs: Set<UUID>,
        requiring predicate: (DocumentRecord) -> Bool,
        mutation: (
            inout DocumentRecord,
            Date
        ) -> Bool
    ) throws -> [DocumentRecord] {
        guard !recordIDs.isEmpty else { return [] }
        try Task.checkCancellation()
        try prepareDirectories()
        var records = try loadIndex()
        let matchedIDs = Set(
            records.filter {
                recordIDs.contains($0.id) && predicate($0)
            }
                .map(\.id)
        )
        guard matchedIDs == recordIDs else {
            throw PaperPathError.storageFailure(
                "One or more selected documents are no longer available."
            )
        }

        let now = Date()
        var didChange = false
        for index in records.indices
        where recordIDs.contains(records[index].id) {
            try Task.checkCancellation()
            if mutation(&records[index], now) {
                didChange = true
            }
        }
        if didChange {
            try Task.checkCancellation()
            try saveIndex(records)
        }
        return sorted(
            records.filter { recordIDs.contains($0.id) }
        )
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
        try fileManager.createDirectory(
            at: changeReportsURL,
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
            officeDeliveriesURL,
            changeReportsURL
        ] {
            try requireFileProtection(to: directory)
        }
        excludeFromBackup(rootURL)
        for url in persistedMetadataURLs
        where fileManager.fileExists(atPath: url.path) {
            try requireProtectedRegularFile(at: url)
        }
        if !didRecoverInterruptedWorkingCopyTransaction {
            try recoverInterruptedWorkingCopyTransaction()
            didRecoverInterruptedWorkingCopyTransaction = true
        }
        if !didRecoverInterruptedProtectedDataTransaction {
            try recoverInterruptedProtectedDataTransaction()
            didRecoverInterruptedProtectedDataTransaction = true
        }
        if !didPruneOrphanedDocumentStagingFiles {
            removeOrphanedDocumentStagingFiles()
            didPruneOrphanedDocumentStagingFiles = true
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

    func recoverInterruptedWorkingCopyTransaction() throws {
        guard fileManager.fileExists(
            atPath: workingCopyTransactionJournalURL.path
        ) else {
            return
        }
        let journal: PDFWorkingCopyTransactionJournal
        do {
            let data = try boundedData(
                at: workingCopyTransactionJournalURL,
                maximumBytes: Self.maximumRecoveryJournalBytes
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

        guard !journal.entries.isEmpty,
              journal.entries.count
                <= PDFBatesBatchPlan.maximumDocumentCount + 2,
              isValidRecoveryJournal(journal),
              journal.entries.allSatisfy(isValidRecoveryJournalEntry)
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
                try restoreVerifiedWorkingCopyBackup(
                    from: backup,
                    to: destination,
                    expectedFingerprint: entry.backupFingerprint
                )
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
    }

    private func restoreVerifiedWorkingCopyBackup(
        from backup: URL,
        to destination: URL,
        expectedFingerprint: String
    ) throws {
        // Once rollback starts, cancellation must not interrupt restoration.
        if fileManager.fileExists(atPath: backup.path) {
            guard try fileFingerprint(at: backup, checksCancellation: false)
                    == expectedFingerprint
            else {
                throw PaperPathError.storageFailure(
                    "A PDF batch recovery file did not match."
                )
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: backup)
            } else {
                try fileManager.moveItem(at: backup, to: destination)
            }
        }
        guard fileManager.fileExists(atPath: destination.path),
              try fileFingerprint(at: destination, checksCancellation: false)
                == expectedFingerprint
        else {
            throw PaperPathError.storageFailure(
                "A PDF batch recovery file is missing."
            )
        }
        try requireFileProtection(to: destination)
    }

    func recoverInterruptedProtectedDataTransaction() throws {
        guard fileManager.fileExists(
            atPath: protectedDataTransactionJournalURL.path
        ) else {
            return
        }
        try requireProtectedRegularFile(
            at: protectedDataTransactionJournalURL
        )
        let data = try boundedData(
            at: protectedDataTransactionJournalURL,
            maximumBytes: Self.maximumRecoveryJournalBytes
        )
        let journal: ProtectedDataTransactionJournal
        do {
            journal = try JSONDecoder.paperPath.decode(
                ProtectedDataTransactionJournal.self,
                from: data
            )
        } catch {
            throw PaperPathError.storageFailure(
                "An interrupted protected transaction has an invalid recovery journal."
            )
        }
        guard isValidProtectedDataTransactionJournal(journal),
              journal.entries.allSatisfy(
                isValidProtectedDataTransactionEntry
              )
        else {
            throw PaperPathError.storageFailure(
                "An interrupted protected transaction has an unsafe recovery journal."
            )
        }

        var recoveryFailed = false
        for entry in journal.entries.reversed() {
            let destination = URL(
                fileURLWithPath: entry.destinationPath
            ).standardizedFileURL
            let staging = URL(
                fileURLWithPath: entry.stagingPath
            ).standardizedFileURL
            do {
                if let backupPath = entry.backupPath,
                   let originalFingerprint =
                    entry.originalFingerprint {
                    let backup = URL(
                        fileURLWithPath: backupPath
                    ).standardizedFileURL
                    if fileManager.fileExists(atPath: backup.path) {
                        guard try fileFingerprint(at: backup)
                                == originalFingerprint
                        else {
                            throw PaperPathError.storageFailure(
                                "A protected recovery copy is invalid."
                            )
                        }
                        if fileManager.fileExists(
                            atPath: destination.path
                        ) {
                            _ = try fileManager.replaceItemAt(
                                destination,
                                withItemAt: backup
                            )
                        } else {
                            try fileManager.moveItem(
                                at: backup,
                                to: destination
                            )
                        }
                        try requireFileProtection(to: destination)
                    }
                    guard fileManager.fileExists(
                        atPath: destination.path
                    ),
                          try fileFingerprint(at: destination)
                            == originalFingerprint
                    else {
                        throw PaperPathError.storageFailure(
                            "A protected transaction could not restore its original file."
                        )
                    }
                } else if fileManager.fileExists(
                    atPath: destination.path
                ) {
                    guard try fileFingerprint(at: destination)
                            == entry.stagedFingerprint
                    else {
                        throw PaperPathError.storageFailure(
                            "A new protected transaction file changed before recovery."
                        )
                    }
                    try fileManager.removeItem(at: destination)
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
                "An interrupted protected transaction could not be fully restored."
            )
        }
        try fileManager.removeItem(
            at: protectedDataTransactionJournalURL
        )
    }

    func isValidProtectedDataTransactionJournal(
        _ journal: ProtectedDataTransactionJournal
    ) -> Bool {
        let timestamp = journal.createdAt.timeIntervalSince1970
        guard !journal.entries.isEmpty,
              journal.entries.count <= 16,
              timestamp.isFinite,
              timestamp >= 0,
              journal.createdAt
                <= Date().addingTimeInterval(5 * 60)
        else { return false }
        let destinations = journal.entries.map {
            URL(fileURLWithPath: $0.destinationPath)
                .standardizedFileURL.path
        }
        let stagings = journal.entries.map {
            URL(fileURLWithPath: $0.stagingPath)
                .standardizedFileURL.path
        }
        let backups = journal.entries.compactMap {
            $0.backupPath.map {
                URL(fileURLWithPath: $0)
                    .standardizedFileURL.path
            }
        }
        let destinationSet = Set(destinations)
        let stagingSet = Set(stagings)
        let backupSet = Set(backups)
        return destinationSet.count == destinations.count
            && stagingSet.count == stagings.count
            && backupSet.count == backups.count
            && destinationSet.isDisjoint(with: stagingSet)
            && destinationSet.isDisjoint(with: backupSet)
            && stagingSet.isDisjoint(with: backupSet)
    }

    func isValidProtectedDataTransactionEntry(
        _ entry: ProtectedDataTransactionJournal.Entry
    ) -> Bool {
        let destination = URL(
            fileURLWithPath: entry.destinationPath
        ).standardizedFileURL
        let staging = URL(
            fileURLWithPath: entry.stagingPath
        ).standardizedFileURL
        let parent = destination.deletingLastPathComponent()
            .standardizedFileURL
        guard isAllowedProtectedTransactionDestination(destination),
              staging.deletingLastPathComponent().standardizedFileURL
                == parent,
              isSafeRecoveryFileReference(staging),
              isUUIDTemporaryFileName(
                  staging.lastPathComponent,
                  prefix: ".protected-"
              ),
              isCanonicalSHA256(entry.stagedFingerprint),
              (entry.backupPath == nil)
                == (entry.originalFingerprint == nil)
        else { return false }

        guard let backupPath = entry.backupPath,
              let originalFingerprint = entry.originalFingerprint
        else { return true }
        let backup = URL(
            fileURLWithPath: backupPath
        ).standardizedFileURL
        return backup.deletingLastPathComponent().standardizedFileURL
                == parent
            && isSafeRecoveryFileReference(backup)
            && isUUIDTemporaryFileName(
                backup.lastPathComponent,
                prefix: ".rollback-"
            )
            && isCanonicalSHA256(originalFingerprint)
    }

    func isAllowedProtectedTransactionDestination(
        _ url: URL
    ) -> Bool {
        let standardized = url.standardizedFileURL
        if standardized == indexURL.standardizedFileURL
            || standardized == versionsIndexURL.standardizedFileURL
            || standardized
                == pageMatchCorrectionsURL.standardizedFileURL
            || standardized
                == retainedChangeReportsIndexURL.standardizedFileURL {
            return true
        }
        let parent = standardized.deletingLastPathComponent()
        if parent == changeReportsURL.standardizedFileURL {
            return standardized.pathExtension.lowercased() == "md"
                && UUID(
                    uuidString: standardized
                        .deletingPathExtension()
                        .lastPathComponent
                ) != nil
        }
        guard parent == indicesURL.standardizedFileURL
                || parent == ocrURL.standardizedFileURL,
              standardized.pathExtension.lowercased() == "json"
        else { return false }
        return UUID(
            uuidString: standardized.deletingPathExtension()
                .lastPathComponent
        ) != nil
    }

    func isCanonicalSHA256(_ value: String) -> Bool {
        isValidVersionFingerprint(value)
            && value == value.lowercased()
    }

    func isValidRecoveryJournal(
        _ journal: PDFWorkingCopyTransactionJournal
    ) -> Bool {
        let timestamp = journal.createdAt.timeIntervalSince1970
        guard timestamp.isFinite,
              timestamp >= 0,
              journal.createdAt
                <= Date().addingTimeInterval(5 * 60)
        else { return false }
        let destinationPaths = Set(
            journal.entries.map {
                URL(fileURLWithPath: $0.destinationPath)
                    .standardizedFileURL.path
            }
        )
        let backupPaths = Set(
            journal.entries.map {
                URL(fileURLWithPath: $0.backupPath)
                    .standardizedFileURL.path
            }
        )
        let stagingPaths = Set(
            journal.entries.map {
                URL(fileURLWithPath: $0.stagingPath)
                    .standardizedFileURL.path
            }
        )
        return destinationPaths.count == journal.entries.count
            && backupPaths.count == journal.entries.count
            && stagingPaths.count == journal.entries.count
            && destinationPaths.isDisjoint(with: backupPaths)
            && destinationPaths.isDisjoint(with: stagingPaths)
            && backupPaths.isDisjoint(with: stagingPaths)
    }

    func isValidRecoveryJournalEntry(
        _ entry: PDFWorkingCopyTransactionJournal.Entry
    ) -> Bool {
        let destination = URL(
            fileURLWithPath: entry.destinationPath
        ).standardizedFileURL
        let backup = URL(
            fileURLWithPath: entry.backupPath
        ).standardizedFileURL
        let staging = URL(
            fileURLWithPath: entry.stagingPath
        ).standardizedFileURL
        let parent = destination.deletingLastPathComponent()
            .standardizedFileURL
        guard backup.deletingLastPathComponent().standardizedFileURL
                == parent,
              staging.deletingLastPathComponent().standardizedFileURL
                == parent,
              [destination, backup, staging].allSatisfy({
                  isSafeRecoveryFileReference($0)
              }),
              entry.backupFingerprint.count == 64,
              entry.backupFingerprint.allSatisfy(\.isHexDigit),
              entry.backupFingerprint
                == entry.backupFingerprint.lowercased(),
              isUUIDTemporaryFileName(
                  backup.lastPathComponent,
                  prefix: ".batch-rollback-"
              )
        else { return false }

        if parent == filesURL.standardizedFileURL {
            guard isSafeDocumentFileName(
                destination.lastPathComponent
            ) else { return false }
            return isUUIDTemporaryFileName(
                staging.lastPathComponent,
                prefix: ".batch-"
            )
        }
        guard parent == rootURL.standardizedFileURL,
              destination == indexURL.standardizedFileURL
                || destination
                    == batesBatchReceiptsURL.standardizedFileURL
        else { return false }
        return isUUIDTemporaryFileName(
            staging.lastPathComponent,
            prefix: ".batch-metadata-"
        )
    }

    private func isUUIDTemporaryFileName(
        _ name: String,
        prefix: String
    ) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return UUID(
            uuidString: String(name.dropFirst(prefix.count))
        ) != nil
    }

    private func isSafeRecoveryFileReference(
        _ url: URL
    ) -> Bool {
        guard isContained(url, in: rootURL) else { return false }
        guard fileManager.fileExists(atPath: url.path) else {
            return true
        }
        guard let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private func removeOrphanedDocumentStagingFiles() {
        let stagingPrefixes = [
            ".annotation-",
            ".batch-",
            ".mutation-",
            ".paperpath-",
            ".protected-",
            ".restore-",
            ".rollback-"
        ]
        for directory in [rootURL, filesURL, indicesURL, ocrURL] {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [
                    .skipsSubdirectoryDescendants,
                    .skipsPackageDescendants
                ]
            ) else { continue }
            var inspectedCount = 0
            var removedCount = 0
            while inspectedCount < 1_024,
                  removedCount < 256,
                  let url = enumerator.nextObject() as? URL {
                inspectedCount += 1
                let name = url.lastPathComponent
                let isKnownStaging = stagingPrefixes.contains(
                    where: name.hasPrefix
                )
                let isLegacyStaging: Bool
                if directory == filesURL,
                   name.hasPrefix("."),
                   name.hasSuffix(".pdf") {
                    let identifier = name.dropFirst().dropLast(4)
                    isLegacyStaging =
                        UUID(uuidString: String(identifier)) != nil
                } else {
                    isLegacyStaging = false
                }
                guard isKnownStaging || isLegacyStaging else {
                    continue
                }
                try? fileManager.removeItem(at: url)
                removedCount += 1
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
            checkedAt: currentTrustedDate(),
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

    private func changeReportVerificationResult(
        payload: PDFChangeReportSignaturePayload,
        signature: PDFOfficeVerificationSignature,
        status: PDFOfficeReportVerificationStatus,
        detail: String,
        trustStatus: PDFOfficeSignerTrustStatus,
        trustedSignerName: String?,
        verifiedBody: Data? = nil
    ) -> PDFChangeReportVerificationResult {
        let safeKeyID = safeSigningKeyID(signature.keyID)
        let verifiedBodyText: String?
        if status == .verified,
           let verifiedBody,
           verifiedBody.count == payload.bodyByteCount,
           let decoded = String(data: verifiedBody, encoding: .utf8) {
            verifiedBodyText = decoded
        } else {
            verifiedBodyText = nil
        }
        return PDFChangeReportVerificationResult(
            status: status,
            reportID: payload.reportID,
            generatedAt: payload.generatedAt,
            sourceName: safeChangeReportDisplayText(
                payload.sourceName
            ),
            revisedName: safeChangeReportDisplayText(
                payload.revisedName
            ),
            changedPageCount: min(
                100_000,
                max(0, payload.changedPageCount)
            ),
            deliveryReceiptID: payload.deliveryReceiptID,
            sourceRevisionID: status == .verified
                ? payload.sourceRevisionID
                : nil,
            revisedRevisionID: status == .verified
                ? payload.revisedRevisionID
                : nil,
            sourceFingerprint: status == .verified
                ? payload.sourceFingerprint?.lowercased()
                : nil,
            revisedFingerprint: status == .verified
                ? payload.revisedFingerprint?.lowercased()
                : nil,
            verifiedBody: verifiedBodyText,
            verifiedBodyByteCount: verifiedBodyText == nil
                ? nil
                : payload.bodyByteCount,
            verifiedBodySHA256: verifiedBodyText == nil
                ? nil
                : payload.bodySHA256.lowercased(),
            keyID: safeKeyID,
            detail: detail,
            publicKeyBase64: status == .verified
                && safeKeyID != nil
                ? signature.publicKeyBase64
                : nil,
            trustStatus: trustStatus,
            trustedSignerName: trustedSignerName
        )
    }

    func safeChangeReportDisplayText(
        _ value: String
    ) -> String {
        let normalized = normalizedTrustedSignerText(
            value,
            maximumCharacters: 240
        )
        return normalized.isEmpty ? "Unreadable PDF" : normalized
    }

    func safeSigningKeyID(_ value: String) -> String? {
        guard value.count == 16,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "0123456789abcdefABCDEF"
                  ).contains($0)
              })
        else { return nil }
        return value.lowercased()
    }

    func canonicalOfficeSignatureMaterial(
        _ signature: PDFOfficeVerificationSignature
    ) -> (publicKey: Data, signature: Data)? {
        guard signature.algorithm == "Ed25519",
              safeSigningKeyID(signature.keyID) == signature.keyID,
              let publicKey = Data(
                base64Encoded: signature.publicKeyBase64
              ),
              publicKey.count == 32,
              publicKey.base64EncodedString()
                == signature.publicKeyBase64,
              let signatureData = Data(
                base64Encoded: signature.signatureBase64
              ),
              signatureData.count == 64,
              signatureData.base64EncodedString()
                == signature.signatureBase64
        else { return nil }
        return (publicKey, signatureData)
    }

    private func isValidOfficeDeliveryReportSignature(
        _ report: PDFOfficeSignedVerificationReport,
        at date: Date
    ) -> Bool {
        let signature = report.signature
        guard report.payload.isStructurallyValid(at: date),
              let signatureMaterial =
                canonicalOfficeSignatureMaterial(
                    signature
                ),
              officeDeliverySigningKeyID(
                  publicKeyData: signatureMaterial.publicKey
              ) == signature.keyID,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: signatureMaterial.publicKey
              ),
              let payloadData = try? JSONEncoder.paperPath.encode(
                  report.payload
              )
        else { return false }
        return publicKey.isValidSignature(
            signatureMaterial.signature,
            for: payloadData
        )
    }

    func officeSignerTrust(
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
        _ receipt: PDFSignedBatesBatchReceipt,
        at date: Date? = nil
    ) -> Bool {
        let trustedDate = date ?? currentTrustedDate()
        let signature = receipt.signature
        guard receipt.payload.isStructurallyValid(at: trustedDate),
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
            for: receipt.payload,
            at: trustedDate
        )
    }

    private func isValidBatesRemovalReceiptSignature(
        _ removal: PDFSignedBatesRemovalReceipt,
        for batesPayload: PDFBatesBatchReceiptPayload,
        at date: Date? = nil
    ) -> Bool {
        let trustedDate = date ?? currentTrustedDate()
        let signature = removal.signature
        guard removal.payload.isLinked(
                to: batesPayload,
                at: trustedDate
              ),
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

        let trustedDate = try evidenceIssuanceDate()
        let payload = PDFBatesBatchReceiptPayload(
            schema: PDFBatesBatchReceiptPayload.schema,
            batchID: UUID(),
            createdAt: trustedDate,
            digitCount: plan.digitCount,
            prefix: plan.prefix,
            suffix: plan.suffix,
            position: plan.position,
            totalPageCount: plan.totalPageCount,
            firstIdentifier: plan.firstIdentifier,
            lastIdentifier: plan.lastIdentifier,
            entries: entries
        )
        guard payload.isStructurallyValid(at: trustedDate) else {
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
        let trustedDate = try evidenceIssuanceDate()
        guard receipt.removal == nil,
              isValidBatesReceiptSignature(
                receipt,
                at: trustedDate
              )
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
            createdAt: trustedDate,
            totalPageCount: receipt.payload.totalPageCount,
            entries: entries
        )
        guard payload.isLinked(
            to: receipt.payload,
            at: trustedDate
        ) else {
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
        let sorted = receipts.sorted(by: batesReceiptSortsBefore)
        let trustedDate = currentTrustedDate()
        var result: [PDFSignedBatesBatchReceipt] = []
        var seen: Set<UUID> = []
        for receipt in sorted
        where result.count
                < PDFBatesBatchReceiptPayload.maximumReceiptCount {
            guard seen.insert(receipt.id).inserted,
                  receipt.payload.isStructurallyValid(at: trustedDate)
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

    private func decodedLibraryIndex() throws -> [DocumentRecord] {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return []
        }
        do {
            let data = try boundedData(
                at: indexURL,
                maximumBytes: Self.maximumLibraryIndexBytes
            )
            let records = try JSONDecoder.paperPath.decode(
                [DocumentRecord].self,
                from: data
            )
            guard records.count <= Self.maximumLibraryRecordCount
            else {
                throw PaperPathError.storageFailure(
                    "The local library index contains too many records."
                )
            }
            return records
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PaperPathError.storageFailure("The local library index is unreadable.")
        }
    }

    private func loadIndex() throws -> [DocumentRecord] {
        normalizedLibraryRecords(try decodedLibraryIndex())
    }

    private func loadPageMatchCorrections() throws
        -> [PDFManualPageMatchCorrection] {
        guard fileManager.fileExists(
            atPath: pageMatchCorrectionsURL.path
        ) else {
            return []
        }
        do {
            let data = try boundedData(
                at: pageMatchCorrectionsURL,
                maximumBytes:
                    Self.maximumPageMatchCorrectionBytes
            )
            let store = try JSONDecoder.paperPath.decode(
                PDFManualPageMatchCorrectionStore.self,
                from: data
            )
            guard store.schema
                    == PDFManualPageMatchCorrectionStore.schema
            else {
                throw PaperPathError.storageFailure(
                    "The saved page-match format is unsupported."
                )
            }
            return store.corrections
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func savePageMatchCorrections(
        _ corrections: [PDFManualPageMatchCorrection]
    ) throws {
        if corrections.isEmpty {
            if fileManager.fileExists(
                atPath: pageMatchCorrectionsURL.path
            ) {
                try fileManager.removeItem(
                    at: pageMatchCorrectionsURL
                )
            }
            return
        }
        let store = PDFManualPageMatchCorrectionStore(
            schema: PDFManualPageMatchCorrectionStore.schema,
            corrections: corrections
        )
        let data = try JSONEncoder.paperPath.encode(store)
        try requireData(
            data,
            maximumBytes:
                Self.maximumPageMatchCorrectionBytes,
            label: "The saved page matches"
        )
        try writeProtectedData(
            data,
            to: pageMatchCorrectionsURL
        )
        excludeFromBackup(pageMatchCorrectionsURL)
    }

    private func loadRetainedChangeReports() throws
        -> [PDFRetainedChangeReport] {
        guard fileManager.fileExists(
            atPath: retainedChangeReportsIndexURL.path
        ) else {
            return []
        }
        do {
            let data = try boundedData(
                at: retainedChangeReportsIndexURL,
                maximumBytes:
                    Self.maximumRetainedChangeReportIndexBytes
            )
            let store = try JSONDecoder.paperPath.decode(
                PDFRetainedChangeReportStore.self,
                from: data
            )
            guard store.schema
                    == PDFRetainedChangeReportStore.schema
            else {
                throw PaperPathError.storageFailure(
                    "The signed change report index format is unsupported."
                )
            }
            return store.reports
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PaperPathError.storageFailure(
                "The signed change report index is unreadable."
            )
        }
    }

    private func saveRetainedChangeReports(
        _ reports: [PDFRetainedChangeReport]
    ) throws {
        try writeProtectedData(
            try encodedRetainedChangeReports(reports),
            to: retainedChangeReportsIndexURL
        )
        excludeFromBackup(retainedChangeReportsIndexURL)
    }

    private func encodedRetainedChangeReports(
        _ reports: [PDFRetainedChangeReport]
    ) throws -> Data {
        let store = PDFRetainedChangeReportStore(
            schema: PDFRetainedChangeReportStore.schema,
            reports: reports
        )
        let data = try JSONEncoder.paperPath.encode(store)
        try requireData(
            data,
            maximumBytes:
                Self.maximumRetainedChangeReportIndexBytes,
            label: "The signed change report index"
        )
        return data
    }

    @discardableResult
    private func reconciledRetainedChangeReports() throws
        -> [PDFRetainedChangeReport] {
        try Task.checkCancellation()
        try prepareDirectories()
        let loaded = try loadRetainedChangeReports()
        let trustedDate = currentTrustedDate()
        var retained: [PDFRetainedChangeReport] = []
        var retainedIDs: Set<UUID> = []
        var totalBytes = Int64.zero

        for loadedReport in loaded.sorted(
            by: retainedChangeReportSortsBefore
        ) {
            try Task.checkCancellation()
            let report = loadedReport.sanitizingLocalLink()
            let url = retainedChangeReportURL(for: report)
            let (projectedBytes, overflow) = totalBytes
                .addingReportingOverflow(report.byteCount)
            guard retained.count
                    < PDFRetainedChangeReport.maximumReportCount,
                  !overflow,
                  projectedBytes
                    <= PDFRetainedChangeReport.maximumTotalBytes,
                  report.isStructurallyValid(at: trustedDate),
                  isSafeRegularFile(
                    at: url,
                    containedIn: changeReportsURL
                  ),
                  logicalFileSize(url) == report.byteCount,
                  retainedIDs.insert(report.id).inserted
            else { continue }
            try requireFileProtection(to: url)
            retained.append(report)
            totalBytes = projectedBytes
        }

        if retained != loaded {
            try saveRetainedChangeReports(retained)
        }
        pruneOrphanedRetainedChangeReportFiles(
            retaining: retained
        )
        return retained
    }

    private func retainedChangeReportSortsBefore(
        _ lhs: PDFRetainedChangeReport,
        _ rhs: PDFRetainedChangeReport
    ) -> Bool {
        if lhs.retainedAt != rhs.retainedAt {
            return lhs.retainedAt > rhs.retainedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func retainedChangeReportLinkHealth(
        _ report: PDFRetainedChangeReport,
        recordsByID: [UUID: DocumentRecord],
        versionsByID: [UUID: PDFVersionSnapshot]
    ) -> PDFRetainedChangeReportLinkHealthStatus {
        guard let link = report.localLink,
              link.isStructurallyValid
        else { return .unlinked }

        switch link.context {
        case .documentPair:
            guard let sourceID = link.sourceDocumentID,
                  let source = recordsByID[sourceID],
                  let revised = recordsByID[
                      link.revisedDocumentID
                  ]
            else { return .missing }
            if source.deletedAt != nil || revised.deletedAt != nil {
                return .inTrash
            }
            guard isAvailableWorkingCopy(source),
                  isAvailableWorkingCopy(revised)
            else { return .missing }
            return recordIdentityMatches(
                source,
                revisionID: link.sourceRevisionID,
                fingerprint: link.sourceFingerprint
            ) && recordIdentityMatches(
                revised,
                revisionID: link.revisedRevisionID,
                fingerprint: link.revisedFingerprint
            )
                ? .readyToVerify
                : .changed

        case .versionSnapshot:
            guard let record = recordsByID[
                link.revisedDocumentID
            ] else { return .missing }
            if record.deletedAt != nil {
                return .inTrash
            }
            guard isAvailableWorkingCopy(record) else {
                return .missing
            }
            guard recordIdentityMatches(
                record,
                revisionID: link.revisedRevisionID,
                fingerprint: link.revisedFingerprint
            ) else { return .changed }
            guard let snapshotID = link.versionSnapshotID,
                  let snapshot = versionsByID[snapshotID],
                  snapshot.documentID == record.id,
                  snapshot.contentRevisionID
                    == link.sourceRevisionID,
                  equalFingerprints(
                      snapshot.contentFingerprint,
                      link.sourceFingerprint
                  ),
                  isAvailableVersionSnapshot(snapshot)
            else { return .versionUnavailable }
            return .readyToVerify

        case .deliveryReceipt:
            guard let record = recordsByID[
                link.revisedDocumentID
            ] else { return .missing }
            if record.deletedAt != nil {
                return .inTrash
            }
            guard isAvailableWorkingCopy(record) else {
                return .missing
            }
            guard let receiptID = link.deliveryReceiptID,
                  let receipt = record.deliveryReceipt,
                  receipt.id == receiptID,
                  receipt.isVerified(
                      at: currentTrustedDate()
                  )
            else { return .receiptUnavailable }
            guard recordIdentityMatches(
                record,
                revisionID: link.revisedRevisionID
                    ?? record.contentRevisionID,
                fingerprint: link.revisedFingerprint
            ),
                  equalFingerprints(
                      receipt.sha256,
                      link.revisedFingerprint
                  )
            else { return .changed }
            return .readyToVerify
        }
    }

    private func isAvailableWorkingCopy(
        _ record: DocumentRecord
    ) -> Bool {
        let candidate = url(for: record)
        return isSafeRegularFile(
            at: candidate,
            containedIn: filesURL
        )
    }

    private func recordIdentityMatches(
        _ record: DocumentRecord,
        revisionID: UUID?,
        fingerprint: String?
    ) -> Bool {
        guard let revisionID,
              record.contentRevisionID == revisionID
        else { return false }
        return equalFingerprints(
            record.contentFingerprint,
            fingerprint
        )
    }

    private func equalFingerprints(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func retainedChangeReportURL(
        for report: PDFRetainedChangeReport
    ) -> URL {
        changeReportsURL.appendingPathComponent(report.fileName)
    }

    private func pruneOrphanedRetainedChangeReportFiles(
        retaining reports: [PDFRetainedChangeReport]
    ) {
        let retainedPaths = Set(
            reports.map {
                retainedChangeReportURL(for: $0)
                    .standardizedFileURL.path
            }
        )
        guard let urls = boundedDirectoryContents(
            at: changeReportsURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else { return }
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !retainedPaths.contains(path) else { continue }
            let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            let isManagedReport =
                url.pathExtension.lowercased() == "md"
                && UUID(
                    uuidString:
                        url.deletingPathExtension().lastPathComponent
                ) != nil
            let isTransactionArtifact =
                url.lastPathComponent.hasPrefix(".protected-")
                || url.lastPathComponent.hasPrefix(".rollback-")
            guard values?.isSymbolicLink == true
                    || values?.isDirectory == true
                    || (
                        values?.isRegularFile == true
                            && (
                                isManagedReport
                                    || isTransactionArtifact
                            )
                    )
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    private func reconciledPageMatchCorrections(
        loaded initialCorrections:
            [PDFManualPageMatchCorrection]? = nil
    ) throws
        -> [PDFManualPageMatchCorrection] {
        try Task.checkCancellation()
        try prepareDirectories()
        let loaded: [PDFManualPageMatchCorrection]
        if let initialCorrections {
            loaded = initialCorrections
        } else {
            loaded = try loadPageMatchCorrections()
        }
        guard !loaded.isEmpty else { return [] }
        let records = try loadIndex()
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let versions = try loadVersionIndex()
        let versionsByID = Dictionary(
            versions.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let trustedDate = currentTrustedDate()
        let current = boundedPageMatchCorrections(
            loaded.filter {
                pageMatchCorrection(
                    $0,
                    matches: recordsByID,
                    versions: versionsByID,
                    at: trustedDate
                )
            },
            at: trustedDate
        )
        if current != loaded {
            try savePageMatchCorrections(current)
        }
        return current
    }

    private func boundedPageMatchCorrections(
        _ corrections: [PDFManualPageMatchCorrection],
        at referenceDate: Date
    ) -> [PDFManualPageMatchCorrection] {
        let sorted = corrections.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.comparisonIdentity
                < $1.comparisonIdentity
        }
        var result: [PDFManualPageMatchCorrection] = []
        var seen: Set<String> = []
        var encodedByteEstimate: Int64 = 128
        for correction in sorted {
            guard result.count
                    < Self.maximumPageMatchCorrectionCount,
                  correction.isStructurallyValid(
                    at: referenceDate
                  ),
                  seen.insert(
                    pageMatchCorrectionDeduplicationIdentity(
                        correction
                    )
                  ).inserted
            else { continue }
            guard let encoded = try? JSONEncoder.paperPath.encode(
                correction
            ) else { continue }
            let (projectedBytes, overflow) = encodedByteEstimate
                .addingReportingOverflow(
                    Int64(encoded.count) + 2
                )
            guard !overflow,
                  projectedBytes
                    <= Self.maximumPageMatchCorrectionBytes
            else { continue }
            result.append(correction)
            encodedByteEstimate = projectedBytes
        }
        return result
    }

    private func pageMatchCorrection(
        _ correction: PDFManualPageMatchCorrection,
        matches records: [UUID: DocumentRecord],
        versions: [UUID: PDFVersionSnapshot],
        at referenceDate: Date
    ) -> Bool {
        guard correction.isStructurallyValid(
            at: referenceDate
        ),
              let source = records[
                correction.sourceDocumentID
              ],
              let revised = records[
                correction.revisedDocumentID
              ],
              revised.contentRevisionID
                == correction.revisedRevisionID,
              revised.profile.pageCount
                == correction.revisedPageCount
        else { return false }

        switch correction.context {
        case .documentPair:
            return source.contentRevisionID
                    == correction.sourceRevisionID
                && source.profile.pageCount
                    == correction.sourcePageCount
        case .versionSnapshot:
            guard let snapshotID =
                    correction.versionSnapshotID,
                  let snapshot = versions[snapshotID]
            else { return false }
            return source.id == revised.id
                && snapshot.documentID == source.id
                && snapshot.contentRevisionID
                    == correction.sourceRevisionID
                && snapshot.pageCount
                    == correction.sourcePageCount
                && isAvailableVersionSnapshot(snapshot)
        }
    }

    private func pageMatchCorrectionIdentity(
        context: PDFManualPageMatchCorrectionContext,
        sourceDocumentID: UUID,
        revisedDocumentID: UUID,
        versionSnapshotID: UUID?
    ) -> String {
        switch context {
        case .documentPair:
            return [
                context.rawValue,
                sourceDocumentID.uuidString,
                revisedDocumentID.uuidString
            ].joined(separator: ":")
        case .versionSnapshot:
            return [
                context.rawValue,
                revisedDocumentID.uuidString,
                versionSnapshotID?.uuidString ?? ""
            ].joined(separator: ":")
        }
    }

    private func pageMatchCorrectionIdentities(
        context: PDFManualPageMatchCorrectionContext,
        sourceDocumentID: UUID,
        revisedDocumentID: UUID,
        versionSnapshotID: UUID?
    ) -> Set<String> {
        let direct = pageMatchCorrectionIdentity(
            context: context,
            sourceDocumentID: sourceDocumentID,
            revisedDocumentID: revisedDocumentID,
            versionSnapshotID: versionSnapshotID
        )
        guard context == .documentPair else {
            return Set([direct])
        }
        let reversed = pageMatchCorrectionIdentity(
            context: context,
            sourceDocumentID: revisedDocumentID,
            revisedDocumentID: sourceDocumentID,
            versionSnapshotID: nil
        )
        return Set([direct, reversed])
    }

    private func pageMatchCorrectionDeduplicationIdentity(
        _ correction: PDFManualPageMatchCorrection
    ) -> String {
        guard correction.context == .documentPair else {
            return correction.comparisonIdentity
        }
        let documentIDs = [
            correction.sourceDocumentID.uuidString,
            correction.revisedDocumentID.uuidString
        ].sorted()
        return [
            correction.context.rawValue,
            documentIDs[0],
            documentIDs[1]
        ].joined(separator: ":")
    }

    private func loadExistingRecords() throws -> [DocumentRecord] {
        try prepareDirectories()
        let decodedRecords = try decodedLibraryIndex()
        var records = normalizedLibraryRecords(decodedRecords)
        var repairedMetadata = records != decodedRecords
        let trustedDate = currentTrustedDate()
        for index in records.indices {
            let normalizedDisplayName = normalizedName(
                records[index].displayName
            )
            if records[index].displayName != normalizedDisplayName {
                records[index].displayName = normalizedDisplayName
                repairedMetadata = true
            }
            if let sourceLocationName =
                    records[index].sourceLocationName {
                let normalizedSourceName = normalizedName(
                    sourceLocationName
                )
                if sourceLocationName != normalizedSourceName {
                    records[index].sourceLocationName =
                        normalizedSourceName
                    repairedMetadata = true
                }
            }
            if let receipt = records[index].deliveryReceipt,
               !receipt.isStructurallyValid(at: trustedDate) {
                records[index].deliveryReceipt = nil
                repairedMetadata = true
            }
            let reconciledRecord = reconciledOfficeBatchRecord(
                records[index],
                at: trustedDate,
                checksFileSystem: true
            )
            if reconciledRecord != records[index] {
                records[index] = reconciledRecord
                repairedMetadata = true
            }
        }
        let existing = records.filter {
            guard let url = safeDocumentURL(for: $0) else {
                return false
            }
            return isSafeRegularFile(
                at: url,
                containedIn: filesURL
            )
        }
        for record in existing {
            try requireFileProtection(to: url(for: record))
        }
        if existing.count != records.count || repairedMetadata {
            try saveIndex(existing)
        }
        pruneOrphanedRecordArtifacts(retaining: existing)
        pruneOfficeExports(for: existing)
        return existing
    }

    private func saveIndex(_ records: [DocumentRecord]) throws {
        do {
            let data = try encodedLibraryIndex(records)
            try writeProtectedData(data, to: indexURL)
        } catch {
            throw PaperPathError.storageFailure("The local library index could not be saved.")
        }
    }

    private func loadVersionIndex() throws -> [PDFVersionSnapshot] {
        normalizedVersionSnapshots(try decodedVersionIndex())
    }

    private func decodedVersionIndex() throws -> [PDFVersionSnapshot] {
        guard fileManager.fileExists(atPath: versionsIndexURL.path) else {
            return []
        }
        do {
            let data = try boundedData(
                at: versionsIndexURL,
                maximumBytes: Self.maximumVersionIndexBytes
            )
            let snapshots = try JSONDecoder.paperPath.decode(
                [PDFVersionSnapshot].self,
                from: data
            )
            guard snapshots.count <= Self.maximumVersionRecordCount
            else {
                throw PaperPathError.storageFailure(
                    "The local version history contains too many records."
                )
            }
            return snapshots
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PaperPathError.storageFailure(
                "The local version history is unreadable."
            )
        }
    }

    private func reconcileVersionStorage() throws
        -> PDFVersionStorageHealth {
        let indexedDocumentIDs = Set(try loadIndex().map(\.id))
        let storedSnapshots: [PDFVersionSnapshot]
        let snapshots: [PDFVersionSnapshot]
        if fileManager.fileExists(atPath: versionsIndexURL.path) {
            storedSnapshots = try decodedVersionIndex()
            snapshots = normalizedVersionSnapshots(storedSnapshots)
        } else {
            storedSnapshots = []
            snapshots = []
        }
        var seenSnapshotIDs: Set<UUID> = []
        var retained: [PDFVersionSnapshot] = []
        retained.reserveCapacity(snapshots.count)
        var repairedMetadataIDs = Set(
            zip(
                storedSnapshots,
                storedSnapshots.map(normalizedVersionSnapshot)
            ).compactMap { pair -> UUID? in
                guard let normalized = pair.1,
                      normalized != pair.0
                else { return nil }
                return normalized.id
            }
        )
        for snapshot in snapshots {
            guard seenSnapshotIDs.insert(snapshot.id).inserted,
                  indexedDocumentIDs.contains(snapshot.documentID),
                  let measured = measuredVersionSnapshot(snapshot)
            else { continue }
            let verified = normalizedVersionReceiptLink(measured)
            try requireFileProtection(to: versionURL(for: verified))
            if verified != snapshot {
                repairedMetadataIDs.insert(verified.id)
            }
            retained.append(verified)
        }

        let pinnedIDs = Set(
            retained.filter(\.isPinnedMilestone).map(\.id)
        )
        let retention = retainedVersions(
            from: retained,
            preserving: pinnedIDs
        )
        retained = retention.kept
        repairedMetadataIDs.formIntersection(
            Set(retained.map(\.id))
        )
        let removedIndexEntryCount =
            storedSnapshots.count - retained.count
        if removedIndexEntryCount > 0
            || !repairedMetadataIDs.isEmpty {
            try saveVersionIndex(retained)
        }

        let retainedPaths = Set(
            retained.map {
                versionURL(for: $0).standardizedFileURL.path
            }
        )
        var removedOrphanFileCount = 0
        var reclaimedByteCount: Int64 = 0
        guard let directories = boundedDirectoryContents(
            at: versionsURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [],
            requiresCompleteEnumeration: true
        ) else {
            throw PaperPathError.storageFailure(
                "The version storage directory could not be inspected."
            )
        }
        for directory in directories {
            try Task.checkCancellation()
            let directoryValues = try? directory.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            if directoryValues?.isSymbolicLink == true {
                if (try? fileManager.removeItem(at: directory)) != nil {
                    removedOrphanFileCount += 1
                }
                continue
            }
            guard directoryValues?.isDirectory == true,
                  UUID(uuidString: directory.lastPathComponent) != nil
            else { continue }
            guard let files = boundedDirectoryContents(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey
                ],
                options: [],
                maximumEntryCount:
                    Self.maximumVersionDirectoryFileCount,
                requiresCompleteEnumeration: true
            ) else { continue }

            for file in files {
                try Task.checkCancellation()
                let path = file.standardizedFileURL.path
                if retainedPaths.contains(path) {
                    continue
                }
                let values = try? file.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileAllocatedSizeKey,
                        .totalFileAllocatedSizeKey
                    ]
                )
                let isVersionFile =
                    file.pathExtension.lowercased() == "pdf"
                    && UUID(
                        uuidString:
                            file.deletingPathExtension().lastPathComponent
                    ) != nil
                let isPendingFile =
                    file.lastPathComponent.hasPrefix(".")
                    && file.lastPathComponent.hasSuffix(".pending")
                guard values?.isSymbolicLink == true
                        || (
                            values?.isRegularFile == true
                                && (isVersionFile || isPendingFile)
                        )
                else { continue }
                let bytes = Int64(
                    values?.totalFileAllocatedSize
                        ?? values?.fileAllocatedSize
                        ?? 0
                )
                do {
                    try fileManager.removeItem(at: file)
                    removedOrphanFileCount += 1
                    reclaimedByteCount = saturatingAdd(
                        reclaimedByteCount,
                        bytes
                    )
                } catch {
                    continue
                }
            }
        }
        removeEmptyVersionDirectories()
        return PDFVersionStorageHealth(
            indexedVersionCount: retained.count,
            pinnedMilestoneCount:
                retained.filter(\.isPinnedMilestone).count,
            removedIndexEntryCount: removedIndexEntryCount,
            removedOrphanFileCount: removedOrphanFileCount,
            repairedMetadataCount: repairedMetadataIDs.count,
            reclaimedByteCount: reclaimedByteCount
        )
    }

    private func saveVersionIndex(
        _ snapshots: [PDFVersionSnapshot]
    ) throws {
        do {
            try writeProtectedData(
                try encodedVersionIndex(snapshots),
                to: versionsIndexURL
            )
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
        let availableSnapshots = snapshots.filter(
            isAvailableVersionSnapshot
        )
        let protectedIDs = snapshotIDs.union(
            availableSnapshots.filter(\.isPinnedMilestone).map(\.id)
        )
        var kept = Dictionary(
            grouping: availableSnapshots,
            by: \.documentID
        ).values.flatMap { versions -> [PDFVersionSnapshot] in
            let sorted = versions.sorted(by: versionSortsBefore)
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
            saturatingAdd($0, max(0, $1.byteCount))
        }
        while totalBytes > Self.maximumVersionBytes {
            guard let candidate = kept
                .filter({ !protectedIDs.contains($0.id) })
                .sorted(by: versionSortsBefore)
                .last
            else { break }
            kept.removeAll { $0.id == candidate.id }
            totalBytes -= max(0, candidate.byteCount)
        }
        let keptIDs = Set(kept.map(\.id))
        return (
            kept: kept.sorted(by: versionSortsBefore),
            removed: snapshots.filter { !keptIDs.contains($0.id) }
        )
    }

    private func versionSortsBefore(
        _ lhs: PDFVersionSnapshot,
        _ rhs: PDFVersionSnapshot
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func removeVersions(for recordID: UUID) throws {
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
        guard let contents = boundedDirectoryContents(
            at: versionsURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents {
            let values = try? url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            if values?.isSymbolicLink == true {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard values?.isDirectory == true,
                  boundedDirectoryContents(
                    at: url,
                    includingPropertiesForKeys: [],
                    maximumEntryCount: 1
                  )?.isEmpty == true
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func versionURL(
        for snapshot: PDFVersionSnapshot
    ) -> URL {
        versionsURL
            .appendingPathComponent(
                snapshot.documentID.uuidString,
                isDirectory: true
            )
            .appendingPathComponent(
                "\(snapshot.id.uuidString).pdf"
            )
    }

    private func safeDocumentURL(
        for record: DocumentRecord
    ) -> URL? {
        guard isSafeDocumentFileName(record.fileName) else {
            return nil
        }
        let url = filesURL.appendingPathComponent(record.fileName)
        guard isContained(url, in: filesURL) else { return nil }
        return url
    }

    private func isSafeDocumentFileName(
        _ fileName: String
    ) -> Bool {
        !fileName.isEmpty
            && !fileName.hasPrefix(".")
            && !fileName.contains("/")
            && !fileName.contains("\\")
            && fileName.lowercased().hasSuffix(".pdf")
    }

    private func isAvailableVersionSnapshot(
        _ snapshot: PDFVersionSnapshot
    ) -> Bool {
        let expectedFileName =
            "\(snapshot.documentID.uuidString)/\(snapshot.id.uuidString).pdf"
        guard snapshot.fileName == expectedFileName else {
            return false
        }
        return isSafeRegularFile(
            at: versionURL(for: snapshot),
            containedIn: versionsURL
        )
    }

    private func measuredVersionSnapshot(
        _ snapshot: PDFVersionSnapshot
    ) -> PDFVersionSnapshot? {
        guard isAvailableVersionSnapshot(snapshot) else { return nil }
        let measuredByteCount = logicalFileSize(
            versionURL(for: snapshot)
        )
        guard measuredByteCount > 0 else { return nil }
        if measuredByteCount == snapshot.byteCount {
            return snapshot
        }
        return snapshot.updatingMeasuredByteCount(
            measuredByteCount
        )
    }

    private func normalizedVersionSnapshot(
        _ snapshot: PDFVersionSnapshot
    ) -> PDFVersionSnapshot? {
        let expectedFileName =
            "\(snapshot.documentID.uuidString)/\(snapshot.id.uuidString).pdf"
        guard snapshot.fileName == expectedFileName,
              snapshot.createdAt.timeIntervalSince1970.isFinite,
              snapshot.createdAt.timeIntervalSince1970 >= 0,
              snapshot.createdAt
                <= Date().addingTimeInterval(5 * 60),
              (1...100_000).contains(snapshot.pageCount),
              isValidVersionFingerprint(
                  snapshot.contentFingerprint
              )
        else { return nil }

        let label = boundedVersionText(
            snapshot.label,
            maximumCharacters: 80
        ) ?? "Document edit"
        let bookmarkedPages = Array(
            Set(
                snapshot.bookmarkedPages.filter {
                    (0..<snapshot.pageCount).contains($0)
                }
            )
        )
        .sorted()
        .prefix(10_000)
        let normalizedPages = Array(bookmarkedPages)
        let pageSet = Set(normalizedPages)
        let bookmarkNames = snapshot.bookmarkNames.reduce(
            into: [Int: String]()
        ) { result, entry in
            guard pageSet.contains(entry.key),
                  let name = boundedVersionText(
                      entry.value,
                      maximumCharacters: 80
                  )
            else { return }
            result[entry.key] = name
        }
        let milestoneName = snapshot.milestoneName.flatMap {
            boundedVersionText($0, maximumCharacters: 80)
        }
        let isPinned = snapshot.isPinnedMilestone
        let linkedReceiptID = isPinned
            ? snapshot.linkedDeliveryReceiptID
            : nil
        let linkedReceipt: PDFDeliveryReceipt?
        if isPinned,
           let receipt = snapshot.linkedDeliveryReceipt,
           receipt.id == snapshot.linkedDeliveryReceiptID,
           receipt.isVerified(at: currentTrustedDate()) {
            linkedReceipt = receipt.milestoneArchiveCopy
        } else {
            linkedReceipt = nil
        }
        return PDFVersionSnapshot(
            id: snapshot.id,
            documentID: snapshot.documentID,
            createdAt: snapshot.createdAt,
            label: label,
            fileName: expectedFileName,
            byteCount: max(0, snapshot.byteCount),
            pageCount: snapshot.pageCount,
            contentRevisionID: snapshot.contentRevisionID,
            contentFingerprint:
                snapshot.contentFingerprint.lowercased(),
            bookmarkedPages: normalizedPages,
            bookmarkNames: bookmarkNames,
            lastPageIndex: min(
                max(0, snapshot.lastPageIndex),
                snapshot.pageCount - 1
            ),
            milestoneName: milestoneName,
            isPinned: isPinned ? true : nil,
            linkedDeliveryReceiptID: linkedReceiptID,
            linkedDeliveryReceipt: linkedReceipt
        )
    }

    private func normalizedVersionReceiptLink(
        _ snapshot: PDFVersionSnapshot
    ) -> PDFVersionSnapshot {
        guard snapshot.linkedDeliveryReceiptID != nil else {
            return snapshot
        }
        guard let receipt = snapshot.linkedDeliveryReceipt,
              snapshot.matchesDeliveryReceipt(receipt)
        else {
            return snapshot.updatingMilestone(
                name: snapshot.milestoneName,
                pinned: snapshot.isPinnedMilestone,
                linkedDeliveryReceiptID: nil
            )
        }
        return snapshot
    }

    private func boundedVersionText(
        _ value: String,
        maximumCharacters: Int
    ) -> String? {
        let sanitized = value.unicodeScalars.map { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || isBidirectionalControl {
                return " "
            }
            return String(scalar)
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(maximumCharacters))
    }

    private func isValidVersionFingerprint(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(
                    charactersIn: "0123456789abcdefABCDEF"
                ).contains($0)
            }
    }

    private func isSafeRegularFile(
        at url: URL,
        containedIn root: URL
    ) -> Bool {
        guard isContained(url, in: root),
              let values = try? url.resourceValues(
                  forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey
                  ]
              )
        else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private func isVerifiedDeliveryArtifactReference(
        _ url: URL
    ) -> Bool {
        let parent = url.deletingLastPathComponent()
        let temporaryRoot = fileManager.temporaryDirectory
        let parentValues = try? parent.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard parent.lastPathComponent
                .hasPrefix(
                    PaperPathTemporaryArtifact
                        .verifiedDeliveryPackagePrefix
                ),
              parentValues?.isDirectory == true,
              parentValues?.isSymbolicLink != true,
              parent.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
                == temporaryRoot
                    .resolvingSymlinksInPath().standardizedFileURL
        else { return false }
        return isSafeRegularFile(at: url, containedIn: parent)
    }

    private func isVerifiedVersionArchiveArtifactReference(
        _ url: URL
    ) -> Bool {
        let parent = url.deletingLastPathComponent()
        let temporaryRoot = fileManager.temporaryDirectory
        let parentValues = try? parent.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
        )
        guard parent.lastPathComponent.hasPrefix(
                PaperPathTemporaryArtifact
                    .verifiedVersionArchivePrefix
              ),
              parentValues?.isDirectory == true,
              parentValues?.isSymbolicLink != true,
              parent.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
                == temporaryRoot
                    .resolvingSymlinksInPath().standardizedFileURL
        else { return false }
        return isSafeRegularFile(at: url, containedIn: parent)
    }

    private func isContained(
        _ url: URL,
        in root: URL
    ) -> Bool {
        let rootPath = root.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath()
            .standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func sorted(_ records: [DocumentRecord]) -> [DocumentRecord] {
        records.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            if $0.modifiedAt == $1.modifiedAt {
                let nameOrder = $0.displayName.localizedStandardCompare(
                    $1.displayName
                )
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func normalizedName(_ value: String) -> String {
        let trimmed = sanitizedDisplayText(value)
        let fallback = "Untitled PDF"
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(80))
    }

    private func sanitizedDisplayText(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || isBidirectionalControl {
                return " "
            }
            return String(scalar)
        }
        .joined()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
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

    private var persistedMetadataURLs: [URL] {
        [
            indexURL,
            versionsIndexURL,
            batchDeliveryURL,
            officeProductionQueueURL,
            officeDeliveryIndexURL,
            officeTrustedSignersURL,
            batesBatchReceiptsURL,
            pageMatchCorrectionsURL,
            retainedChangeReportsIndexURL,
            workingCopyTransactionJournalURL,
            protectedDataTransactionJournalURL
        ]
    }

    private func requireProtectedRegularFile(at url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw PaperPathError.storageFailure(
                "A private metadata file is not a regular file."
            )
        }
        try requireFileProtection(to: url)
    }

    private func boundedDirectoryContents(
        at directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions = [],
        maximumEntryCount: Int = 4_096,
        requiresCompleteEnumeration: Bool = false
    ) -> [URL]? {
        var enumerationFailed = false
        guard maximumEntryCount > 0,
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: keys,
                  options: options.union(
                      .skipsSubdirectoryDescendants
                  ),
                  errorHandler: { _, _ in
                      enumerationFailed = true
                      return false
                  }
              )
        else { return nil }

        var urls: [URL] = []
        urls.reserveCapacity(min(maximumEntryCount, 128))
        var isTruncated = false
        for case let url as URL in enumerator {
            guard urls.count < maximumEntryCount else {
                isTruncated = true
                break
            }
            urls.append(url)
        }
        guard !enumerationFailed,
              !requiresCompleteEnumeration || !isTruncated
        else { return nil }
        return urls
    }

    private func boundedData(
        at url: URL,
        maximumBytes: Int64
    ) throws -> Data {
        guard maximumBytes >= 0,
              maximumBytes < Int64(Int.max)
        else {
            throw PaperPathError.storageFailure(
                "A local metadata read limit is invalid."
            )
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= maximumBytes,
              size.int64Value <= Int64(Int.max)
        else {
            throw PaperPathError.storageFailure(
                "A local metadata file exceeds its safe read limit."
            )
        }
        let byteCount = Int(size.int64Value)
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            try Task.checkCancellation()
            let requested = min(
                1_048_576,
                byteCount - data.count
            )
            let chunk = try handle.read(upToCount: requested) ?? Data()
            guard !chunk.isEmpty else {
                throw PaperPathError.storageFailure(
                    "A local metadata file changed while it was read."
                )
            }
            data.append(chunk)
        }
        let trailingByte = try handle.read(upToCount: 1) ?? Data()
        guard trailingByte.isEmpty,
              data.count == byteCount,
              Int64(data.count) <= maximumBytes
        else {
            throw PaperPathError.storageFailure(
                "A local metadata file changed while it was read."
            )
        }
        let finalAttributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard finalAttributes[.type] as? FileAttributeType
                == .typeRegular,
              (finalAttributes[.size] as? NSNumber)?.int64Value
                == Int64(byteCount),
              fileResourceIdentifiersMatch(
                attributes[.systemNumber],
                finalAttributes[.systemNumber]
              ),
              fileResourceIdentifiersMatch(
                attributes[.systemFileNumber],
                finalAttributes[.systemFileNumber]
              ),
              fileResourceIdentifiersMatch(
                attributes[.modificationDate],
                finalAttributes[.modificationDate]
              )
        else {
            throw PaperPathError.storageFailure(
                "A local metadata file changed while it was read."
            )
        }
        try Task.checkCancellation()
        return data
    }

    private func encodedLibraryIndex(
        _ records: [DocumentRecord]
    ) throws -> Data {
        guard records.count <= Self.maximumLibraryRecordCount
        else {
            throw PaperPathError.storageFailure(
                "The local library index contains too many records."
            )
        }
        let normalized = normalizedLibraryRecords(records)
        let data = try JSONEncoder.paperPath.encode(normalized)
        try requireData(
            data,
            maximumBytes: Self.maximumLibraryIndexBytes,
            label: "The local library index"
        )
        return data
    }

    private func normalizedLibraryRecords(
        _ records: [DocumentRecord]
    ) -> [DocumentRecord] {
        let trustedDate = currentTrustedDate()
        var recordsByID: [UUID: DocumentRecord] = [:]
        recordsByID.reserveCapacity(records.count)
        for sourceRecord in records {
            var record = sourceRecord
            if let checkpoint = record.taskCheckpoint {
                record.taskCheckpoint = checkpoint.validated(
                    for: record.contentRevisionID,
                    pageCount: record.profile.pageCount
                )
            }
            if record.deliveryReceipt?.isStructurallyValid(
                at: trustedDate
            ) == false {
                record.deliveryReceipt = nil
            }
            if record.officeBatchRun?.isStructurallyValid(
                at: trustedDate
            ) == false {
                record.officeBatchRun = nil
            }
            record = reconciledOfficeBatchRecord(
                record,
                at: trustedDate,
                checksFileSystem: false
            )
            guard let existing = recordsByID[record.id] else {
                recordsByID[record.id] = record
                continue
            }
            if libraryRecord(record, supersedes: existing) {
                recordsByID[record.id] = record
            }
        }
        return sorted(Array(recordsByID.values))
    }

    private func libraryRecord(
        _ candidate: DocumentRecord,
        supersedes existing: DocumentRecord
    ) -> Bool {
        if candidate.modifiedAt != existing.modifiedAt {
            return candidate.modifiedAt > existing.modifiedAt
        }
        if candidate.deletedAt != existing.deletedAt {
            return (candidate.deletedAt ?? .distantPast)
                > (existing.deletedAt ?? .distantPast)
        }
        if candidate.importedAt != existing.importedAt {
            return candidate.importedAt > existing.importedAt
        }
        if candidate.fileName != existing.fileName {
            return candidate.fileName < existing.fileName
        }
        return candidate.contentRevisionID.uuidString
            < existing.contentRevisionID.uuidString
    }

    private func encodedVersionIndex(
        _ snapshots: [PDFVersionSnapshot]
    ) throws -> Data {
        guard snapshots.count <= Self.maximumVersionRecordCount
        else {
            throw PaperPathError.storageFailure(
                "The local version history contains too many records."
            )
        }
        let normalized = normalizedVersionSnapshots(snapshots)
        let data = try JSONEncoder.paperPath.encode(normalized)
        try requireData(
            data,
            maximumBytes: Self.maximumVersionIndexBytes,
            label: "The local version history"
        )
        return data
    }

    private func normalizedVersionSnapshots(
        _ snapshots: [PDFVersionSnapshot]
    ) -> [PDFVersionSnapshot] {
        let prioritized = snapshots.compactMap(
            normalizedVersionSnapshot
        ).sorted {
            if $0.isPinnedMilestone != $1.isPinnedMilestone {
                return $0.isPinnedMilestone
            }
            return versionSortsBefore($0, $1)
        }
        var seenIDs = Set<UUID>()
        return prioritized
            .filter { seenIDs.insert($0.id).inserted }
            .sorted(by: versionSortsBefore)
    }

    private func encodedPageMatchCorrections(
        _ corrections: [PDFManualPageMatchCorrection]
    ) throws -> Data {
        let store = PDFManualPageMatchCorrectionStore(
            schema: PDFManualPageMatchCorrectionStore.schema,
            corrections: corrections
        )
        let data = try JSONEncoder.paperPath.encode(store)
        try requireData(
            data,
            maximumBytes:
                Self.maximumPageMatchCorrectionBytes,
            label: "The saved page matches"
        )
        return data
    }

    private func requireData(
        _ data: Data,
        maximumBytes: Int64,
        label: String
    ) throws {
        guard Int64(data.count) <= maximumBytes else {
            throw PaperPathError.storageFailure(
                "\(label) exceeds its safe storage limit."
            )
        }
    }

    private func protectedTemporaryFile(
        directoryPrefix: String,
        fileName: String
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "\(directoryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory,
            fileManager: fileManager
        )
        excludeFromBackup(directory)
        return directory.appendingPathComponent(fileName)
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
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".protected-rollback-\(UUID().uuidString)",
                isDirectory: false
            )
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }

        try Task.checkCancellation()
        let expectedFingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        try data.write(to: staging, options: .atomic)
        try requireProtectedRegularFile(at: staging)
        guard logicalFileSize(staging) == Int64(data.count),
              try fileFingerprint(at: staging)
                == expectedFingerprint
        else {
            throw PaperPathError.storageFailure(
                "A protected staging file could not be verified."
            )
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            var replacementStarted = false
            do {
                replacementStarted = true
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: backup.lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
                try requireProtectedRegularFile(at: destination)
                guard logicalFileSize(destination)
                        == Int64(data.count),
                      try fileFingerprint(at: destination)
                        == expectedFingerprint
                else {
                    throw PaperPathError.storageFailure(
                        "A protected file changed while it was published."
                    )
                }
            } catch {
                guard replacementStarted,
                      fileManager.fileExists(atPath: backup.path)
                else { throw error }
                do {
                    if fileManager.fileExists(
                        atPath: destination.path
                    ) {
                        _ = try fileManager.replaceItemAt(
                            destination,
                            withItemAt: backup
                        )
                    } else {
                        try fileManager.moveItem(
                            at: backup,
                            to: destination
                        )
                    }
                    try requireProtectedRegularFile(at: destination)
                } catch {
                    throw PaperPathError.storageFailure(
                        "The previous protected file could not be restored."
                    )
                }
                throw error
            }
        } else {
            var didPublish = false
            do {
                try fileManager.moveItem(
                    at: staging,
                    to: destination
                )
                didPublish = true
                try requireProtectedRegularFile(at: destination)
                guard logicalFileSize(destination)
                        == Int64(data.count),
                      try fileFingerprint(at: destination)
                        == expectedFingerprint
                else {
                    throw PaperPathError.storageFailure(
                        "A protected file changed while it was published."
                    )
                }
            } catch {
                if didPublish,
                   fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                throw error
            }
        }
    }

    func writeProtectedDataTransaction(
        _ writes: [(data: Data, destination: URL)]
    ) throws {
        guard !writes.isEmpty else { return }
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: protectedDataTransactionJournalURL.path) {
            try recoverInterruptedProtectedDataTransaction()
            throw PaperPathError.storageFailure(
                "An interrupted transaction was recovered. Try the action again."
            )
        }
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
        var stagedFingerprintByDestination: [URL: String] = [:]
        var backupByDestination: [URL: URL] = [:]
        var backupFingerprintByDestination: [URL: String] = [:]
        var didPersistJournal = false
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
                let stagedFingerprint = SHA256.hash(data: write.data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard try fileFingerprint(at: staging)
                        == stagedFingerprint
                else {
                    throw PaperPathError.storageFailure(
                        "A protected staging file could not be verified."
                    )
                }
                stagedFingerprintByDestination[write.destination] =
                    stagedFingerprint
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
                let copiedBackup = try copyProtectedFile(
                    from: write.destination,
                    to: backup,
                    expectedByteCount:
                        logicalFileSize(write.destination)
                )
                backupFingerprintByDestination[write.destination] =
                    copiedBackup.sha256
            }

            let journalEntries: [
                ProtectedDataTransactionJournal.Entry
            ] = writes.compactMap {
                write -> ProtectedDataTransactionJournal.Entry? in
                guard let staging =
                    stagingByDestination[write.destination],
                      let stagedFingerprint =
                        stagedFingerprintByDestination[
                            write.destination
                        ]
                else { return nil }
                return ProtectedDataTransactionJournal.Entry(
                    destinationPath:
                        write.destination.standardizedFileURL.path,
                    backupPath: backupByDestination[
                        write.destination
                    ]?.standardizedFileURL.path,
                    stagingPath: staging.standardizedFileURL.path,
                    originalFingerprint:
                        backupFingerprintByDestination[
                            write.destination
                        ],
                    stagedFingerprint: stagedFingerprint
                )
            }
            guard journalEntries.count == writes.count else {
                throw PaperPathError.storageFailure(
                    "The protected recovery journal is incomplete."
                )
            }
            let journal = ProtectedDataTransactionJournal(
                id: UUID(),
                createdAt: Date(),
                entries: journalEntries
            )
            try writeProtectedData(
                try JSONEncoder.paperPath.encode(journal),
                to: protectedDataTransactionJournalURL
            )
            didPersistJournal = true

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
                try requireFileProtection(to: write.destination)
                guard let expected =
                    stagedFingerprintByDestination[write.destination],
                      try fileFingerprint(at: write.destination)
                        == expected
                else {
                    throw PaperPathError.storageFailure(
                        "A protected transaction file could not be verified."
                    )
                }
            }
        } catch {
            var rollbackFailed = false
            if didStartPublishing || didPersistJournal {
                for write in writes.reversed() {
                    do {
                        if let backup =
                            backupByDestination[write.destination],
                           let expected =
                            backupFingerprintByDestination[
                                write.destination
                           ] {
                            if fileManager.fileExists(atPath: backup.path) {
                                guard try fileFingerprint(
                                    at: backup,
                                    checksCancellation: false
                                ) == expected else {
                                    throw PaperPathError.storageFailure(
                                        "A protected rollback file is invalid."
                                    )
                                }
                                if fileManager.fileExists(atPath: write.destination.path) {
                                    _ = try fileManager.replaceItemAt(
                                        write.destination,
                                        withItemAt: backup
                                    )
                                } else {
                                    try fileManager.moveItem(
                                        at: backup,
                                        to: write.destination
                                    )
                                }
                            }
                            try requireFileProtection(
                                to: write.destination
                            )
                            guard try fileFingerprint(
                                at: write.destination,
                                checksCancellation: false
                            ) == expected else {
                                throw PaperPathError.storageFailure(
                                    "A protected rollback file did not match."
                                )
                            }
                        } else if backupByDestination[
                            write.destination
                        ] == nil,
                                  fileManager.fileExists(
                                    atPath: write.destination.path
                                  ) {
                            guard let staged =
                                stagedFingerprintByDestination[
                                    write.destination
                                ],
                                  try fileFingerprint(
                                    at: write.destination,
                                    checksCancellation: false
                                  ) == staged
                            else {
                                throw PaperPathError.storageFailure(
                                    "A new protected transaction file changed before rollback."
                                )
                            }
                            try fileManager.removeItem(
                                at: write.destination
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
                try? removeIfPresent(
                    protectedDataTransactionJournalURL
                )
            }
            if rollbackFailed {
                didRecoverInterruptedProtectedDataTransaction = false
                throw PaperPathError.storageFailure(
                    "The protected transaction could not be rolled back."
                )
            }
            throw error
        }

        try removeIfPresent(protectedDataTransactionJournalURL)
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
        let reserve = Int64(16 * 1_024 * 1_024)
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
        let reserve = Int64(16 * 1_024 * 1_024)
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
        let reserve = Int64(16 * 1_024 * 1_024)
        guard available >= fileSize + reserve else {
            throw PaperPathError.insufficientStorage
        }
    }

    private func copyProtectedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: Int64,
        progress: @Sendable (Int64) -> Void = { _ in }
    ) throws -> (
        byteCount: Int64,
        sha256: String,
        compactInspectionByteCount: Int64?
    ) {
        guard expectedByteCount > 0,
              expectedByteCount <= 1_073_741_824,
              fileManager.createFile(
                  atPath: destinationURL.path,
                  contents: nil
              )
        else {
            throw PaperPathError.unreadablePDF
        }
        try requireFileProtection(to: destinationURL)

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        var hasher = SHA256()
        var copiedByteCount: Int64 = 0
        var lastReportedByteCount: Int64 = 0
        var lastNonPaddingOffset: Int64 = -1
        var lastEOFEndOffset: Int64?
        let eofMarker = Data("%%EOF".utf8)
        var markerTail = Data()
        while true {
            try Task.checkCancellation()
            let copiedChunk = try autoreleasepool {
                let data =
                    try input.read(upToCount: 1_048_576) ?? Data()
                guard !data.isEmpty else { return false }
                let chunkStartOffset = copiedByteCount
                for (index, byte) in data.enumerated()
                where !Self.isPDFTrailingPaddingByte(byte) {
                    lastNonPaddingOffset =
                        chunkStartOffset + Int64(index)
                }
                var searchable = markerTail
                searchable.append(data)
                let searchableStartOffset =
                    chunkStartOffset - Int64(markerTail.count)
                var searchStart = searchable.startIndex
                while searchStart < searchable.endIndex,
                      let range = searchable.range(
                        of: eofMarker,
                        in: searchStart..<searchable.endIndex
                      ) {
                    lastEOFEndOffset =
                        searchableStartOffset
                            + Int64(range.upperBound)
                    searchStart = searchable.index(
                        after: range.lowerBound
                    )
                }
                markerTail = Data(
                    searchable.suffix(
                        max(0, eofMarker.count - 1)
                    )
                )
                let (nextByteCount, overflow) = copiedByteCount
                    .addingReportingOverflow(Int64(data.count))
                guard !overflow,
                      nextByteCount <= expectedByteCount
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the source PDF changed while its private copy was created"
                    )
                }
                try output.write(contentsOf: data)
                hasher.update(data: data)
                copiedByteCount = nextByteCount
                return true
            }
            if !copiedChunk { break }
            if copiedByteCount - lastReportedByteCount
                >= 4 * 1_024 * 1_024
                || copiedByteCount == expectedByteCount {
                progress(copiedByteCount)
                lastReportedByteCount = copiedByteCount
            }
        }
        try Task.checkCancellation()
        try output.synchronize()
        guard copiedByteCount == expectedByteCount else {
            throw PaperPathError.outputVerificationFailed(
                "the source PDF changed while its private copy was created"
            )
        }
        try requireFileProtection(to: destinationURL)
        let compactInspectionByteCount: Int64?
        if let lastEOFEndOffset,
           lastEOFEndOffset > 0,
           lastEOFEndOffset <= 64 * 1_024 * 1_024,
           copiedByteCount - lastEOFEndOffset >= 8 * 1_024 * 1_024,
           lastNonPaddingOffset == lastEOFEndOffset - 1 {
            compactInspectionByteCount = lastEOFEndOffset
        } else {
            compactInspectionByteCount = nil
        }
        return (
            copiedByteCount,
            hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            compactInspectionByteCount
        )
    }

    private func importedProfile(
        at url: URL,
        copiedFile: (
            byteCount: Int64,
            sha256: String,
            compactInspectionByteCount: Int64?
        ),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> DocumentProfile {
        guard let compactByteCount =
                copiedFile.compactInspectionByteCount
        else {
            if copiedFile.byteCount
                > Self.maximumDeepInspectionBytes {
                return try autoreleasepool {
                    try inspector.inspectMetadataOnly(
                        url: url,
                        byteCount: copiedFile.byteCount
                    ) { completedPageCount, totalPageCount in
                        guard totalPageCount > 0 else { return }
                        progress(
                            Double(completedPageCount)
                                / Double(totalPageCount)
                        )
                    }
                }
            }
            return try autoreleasepool {
                try inspector.inspect(url: url) {
                    completedPageCount,
                    totalPageCount in
                    guard totalPageCount > 0 else { return }
                    progress(
                        Double(completedPageCount)
                            / Double(totalPageCount)
                    )
                }
            }
        }
        let inspectionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-PDFInspection-\(UUID().uuidString).pdf"
            )
        defer {
            try? fileManager.removeItem(at: inspectionURL)
        }
        guard fileManager.createFile(
            atPath: inspectionURL.path,
            contents: nil
        ) else {
            throw PaperPathError.storageFailure(
                "The bounded PDF inspection copy could not be created."
            )
        }
        try requireFileProtection(to: inspectionURL)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: inspectionURL)
        defer { try? output.close() }
        var remaining = compactByteCount
        var copiedInspectionBytes: Int64 = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = Int(min(remaining, 1_048_576))
            let data = try input.read(upToCount: requested) ?? Data()
            guard !data.isEmpty,
                  data.count <= requested
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the bounded PDF inspection copy is incomplete"
                )
            }
            try output.write(contentsOf: data)
            let writtenByteCount = Int64(data.count)
            remaining -= writtenByteCount
            copiedInspectionBytes += writtenByteCount
            progress(
                0.20
                    * Double(copiedInspectionBytes)
                    / Double(compactByteCount)
            )
        }
        try output.synchronize()
        try requireFileProtection(to: inspectionURL)
        guard logicalFileSize(inspectionURL) == compactByteCount
        else {
            throw PaperPathError.outputVerificationFailed(
                "the bounded PDF inspection copy has the wrong size"
            )
        }
        var profile = try autoreleasepool {
            try inspector.inspect(url: inspectionURL) {
                completedPageCount,
                totalPageCount in
                guard totalPageCount > 0 else { return }
                progress(
                    0.20
                        + 0.80
                            * Double(completedPageCount)
                            / Double(totalPageCount)
                )
            }
        }
        profile.byteCount = copiedFile.byteCount
        return profile
    }

    private static func isPDFTrailingPaddingByte(
        _ byte: UInt8
    ) -> Bool {
        byte == 0x00
            || byte == 0x09
            || byte == 0x0A
            || byte == 0x0C
            || byte == 0x0D
            || byte == 0x20
    }

    private func fileFingerprint(
        at url: URL,
        checksCancellation: Bool = true,
        progress: (
            @Sendable (_ processedBytes: Int64, _ totalBytes: Int64)
                -> Void
        )? = nil
    ) throws -> String {
        if checksCancellation {
            try Task.checkCancellation()
        }
        let identityKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        let initialValues = try uncachedResourceValues(
            at: url,
            forKeys: identityKeys
        )
        guard initialValues.isRegularFile == true,
              initialValues.isSymbolicLink != true,
              let rawByteCount = initialValues.fileSize,
              rawByteCount >= 0
        else {
            throw PaperPathError.unreadablePDF
        }
        let totalBytes = Int64(rawByteCount)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        let bufferSize: Int64 = 4 * 1_024 * 1_024
        var processedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        while processedBytes < totalBytes {
            if checksCancellation {
                try Task.checkCancellation()
            }
            try autoreleasepool {
                let chunk = try input.read(
                    upToCount: Int(min(bufferSize, totalBytes - processedBytes))
                ) ?? Data()
                guard !chunk.isEmpty else {
                    throw PaperPathError.outputVerificationFailed(
                        "the file changed while its checksum was calculated"
                    )
                }
                hasher.update(data: chunk)
                processedBytes += Int64(chunk.count)
            }
            if processedBytes - lastReportedBytes >= bufferSize {
                progress?(processedBytes, totalBytes)
                lastReportedBytes = processedBytes
            }
        }
        let trailingByte = try input.read(upToCount: 1) ?? Data()
        let finalValues = try uncachedResourceValues(
            at: url,
            forKeys: identityKeys
        )
        guard trailingByte.isEmpty,
              finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              finalValues.fileSize == rawByteCount,
              finalValues.contentModificationDate == initialValues.contentModificationDate,
              fileResourceIdentifiersMatch(
                initialValues.fileResourceIdentifier,
                finalValues.fileResourceIdentifier
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the file changed while its checksum was calculated"
            )
        }
        if checksCancellation {
            try Task.checkCancellation()
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
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == expectedSize
        else {
            throw PaperPathError.insufficientSelection(
                "A selected PDF changed while it was being matched."
            )
        }
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
        while processedBytes < expectedSize {
            try Task.checkCancellation()
            let count = stream.read(
                buffer,
                maxLength: Int(min(Int64(bufferSize), expectedSize - processedBytes))
            )
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
        let trailingCount = stream.read(buffer, maxLength: 1)
        if trailingCount < 0 {
            throw stream.streamError ?? PaperPathError.unreadablePDF
        }
        let finalValues = try uncachedResourceValues(
            at: url,
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard processedBytes == expectedSize,
              trailingCount == 0,
              finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              Int64(finalValues.fileSize ?? -1) == expectedSize,
              finalValues.contentModificationDate == values.contentModificationDate,
              fileResourceIdentifiersMatch(
                values.fileResourceIdentifier,
                finalValues.fileResourceIdentifier
              )
        else {
            throw PaperPathError.insufficientSelection(
                "A selected PDF changed while it was being matched."
            )
        }
        try Task.checkCancellation()
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
        let values = try url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == expectedSize
        else {
            throw PaperPathError.insufficientSelection(
                "A selected delivery file changed while it was being matched."
            )
        }
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
        while processedBytes < expectedSize {
            try Task.checkCancellation()
            let count = stream.read(
                buffer,
                maxLength: Int(min(Int64(bufferSize), expectedSize - processedBytes))
            )
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
        let trailingCount = stream.read(buffer, maxLength: 1)
        if trailingCount < 0 {
            throw stream.streamError ?? PaperPathError.storageFailure(
                "A selected delivery file could not be read."
            )
        }
        guard processedBytes == expectedSize, trailingCount == 0 else {
            throw PaperPathError.insufficientSelection(
                "A selected delivery file changed while it was being matched."
            )
        }
        let finalValues = try uncachedResourceValues(
            at: url,
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        guard finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              Int64(finalValues.fileSize ?? -1) == expectedSize,
              finalValues.contentModificationDate
                == values.contentModificationDate,
              fileResourceIdentifiersMatch(
                values.fileResourceIdentifier,
                finalValues.fileResourceIdentifier
              )
        else {
            throw PaperPathError.insufficientSelection(
                "A selected delivery file changed while it was being matched."
            )
        }
        try Task.checkCancellation()
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func fileResourceIdentifiersMatch(
        _ first: Any?,
        _ second: Any?
    ) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case let (first as NSObject, second):
            return first.isEqual(second)
        default:
            return false
        }
    }

    private func uncachedResourceValues(
        at url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        return try freshURL.resourceValues(forKeys: keys)
    }

    private func officeEvidenceDatesMatch(
        _ first: Date,
        _ second: Date
    ) -> Bool {
        abs(first.timeIntervalSince(second)) < 1
    }

    private func boundedExternalDisplayName(
        _ value: String,
        maximumLength: Int
    ) -> String {
        let sanitized = sanitizedDisplayText(value)
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
            officeDeliveriesURL.lastPathComponent,
            changeReportsURL.lastPathComponent
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ],
            options: [
                .skipsHiddenFiles,
                .skipsPackageDescendants
            ],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw PaperPathError.storageFailure(
                "Local storage could not be measured."
            )
        }

        let rootComponentCount = rootURL.pathComponents.count
        var sizes: [String: Int64] = [:]
        var visitedCount = 0
        for case let url as URL in enumerator {
            guard visitedCount
                    < Self.maximumStorageEnumerationCount
            else {
                throw PaperPathError.storageFailure(
                    "The private storage inventory exceeds the safe local limit."
                )
            }
            if visitedCount.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            visitedCount += 1
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey
                ]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let components = url.pathComponents
            guard components.count > rootComponentCount else {
                continue
            }
            let directoryName = components[rootComponentCount]
            guard trackedDirectoryNames.contains(directoryName) else {
                if values.isDirectory == true,
                   components.count == rootComponentCount + 1 {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
            sizes[directoryName] = saturatingAdd(
                sizes[directoryName, default: 0],
                bytes
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        try Task.checkCancellation()
        return sizes
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return 0 }
        return Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 0
        )
    }

    private func logicalFileSize(_ url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0
        else { return 0 }
        return size
    }

    private func textIndexURL(for recordID: UUID) -> URL {
        indicesURL.appendingPathComponent("\(recordID.uuidString).json")
    }

    private func ocrResultURL(for recordID: UUID) -> URL {
        ocrURL.appendingPathComponent("\(recordID.uuidString).json")
    }

    private func ocrCheckpointURL(for recordID: UUID) -> URL {
        ocrURL.appendingPathComponent("\(recordID.uuidString).resume", isDirectory: true)
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

    private func reconciledOfficeBatchRecord(
        _ sourceRecord: DocumentRecord,
        at date: Date,
        checksFileSystem: Bool
    ) -> DocumentRecord {
        guard let run = sourceRecord.officeBatchRun else {
            return sourceRecord
        }
        let receiptsByID = Dictionary(
            sourceRecord.officeReceipts.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        var availableReceiptIDs = Set<UUID>()
        availableReceiptIDs.reserveCapacity(run.completedCount)

        for result in run.segments where result.status == .completed {
            guard let receiptID = result.receiptID,
                  let receipt = receiptsByID[receiptID],
                  receipt.format == run.plan.format,
                  receipt.batchID == run.id,
                  receipt.batchSegmentIndex == result.segment.index,
                  receipt.batchSegmentCount == run.segments.count,
                  receipt.sourcePageStartIndex
                    == result.segment.startPageIndex,
                  receipt.sourcePageEndIndex
                    == result.segment.endPageIndex,
                  receipt.fileSizeBytes > 0,
                  receipt.artifactAvailability(
                    for: sourceRecord.contentRevisionID,
                    now: date
                  ) == .reusable,
                  receipt.integrityStatus != .missing,
                  receipt.integrityStatus != .mismatch,
                  receipt.integrityStatus != .sourceChanged,
                  let fileName = receipt.retainedFileName,
                  isSafeOfficeExportFileName(fileName),
                  let fingerprint = receipt.artifactSHA256,
                  isValidVersionFingerprint(fingerprint)
            else { continue }

            if checksFileSystem {
                let url = officeExportDirectory(
                    for: sourceRecord.id
                ).appendingPathComponent(fileName)
                guard let values = try? url.resourceValues(
                    forKeys: [
                        .fileSizeKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                ),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      Int64(values.fileSize ?? -1)
                        == receipt.fileSizeBytes
                else { continue }
            }
            availableReceiptIDs.insert(receiptID)
        }

        let reconciled = run.reconcilingArtifacts(
            currentRevisionID: sourceRecord.contentRevisionID,
            availableReceiptIDs: availableReceiptIDs
        )
        guard reconciled != run else { return sourceRecord }
        var record = sourceRecord
        record.officeBatchRun = reconciled
        return record
    }

    private func boundedOfficeDeliveryPackages(
        _ packages: [PDFOfficeDeliveryPackage]
    ) -> [PDFOfficeDeliveryPackage] {
        var seenIDs = Set<UUID>()
        let sorted = packages
            .sorted(by: officePackageSortsBefore)
            .filter { seenIDs.insert($0.id).inserted }
        let pinned = Array(
            sorted.filter(\.isPinned)
                .prefix(Self.maximumPinnedOfficeDeliveryPackages)
        )
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
        return retained.sorted(by: officePackageSortsBefore)
    }

    private func batesReceiptSortsBefore(
        _ lhs: PDFSignedBatesBatchReceipt,
        _ rhs: PDFSignedBatesBatchReceipt
    ) -> Bool {
        if lhs.payload.createdAt != rhs.payload.createdAt {
            return lhs.payload.createdAt > rhs.payload.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func officePackageSortsBefore(
        _ lhs: PDFOfficeDeliveryPackage,
        _ rhs: PDFOfficeDeliveryPackage
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func saveOfficeDeliveryPackages(
        _ packages: [PDFOfficeDeliveryPackage]
    ) throws {
        let data = try JSONEncoder.paperPath.encode(packages)
        try requireData(
            data,
            maximumBytes: Self.maximumPersistedStateBytes,
            label: "The Office delivery index"
        )
        try writeProtectedData(data, to: officeDeliveryIndexURL)
    }

    private func saveOfficeTrustedSigners(
        _ signers: [PDFOfficeTrustedSigner]
    ) throws {
        var seenKeyIDs = Set<String>()
        let normalized = signers.prefix(24).compactMap {
            normalizedTrustedSigner($0)
        }
        .filter {
            seenKeyIDs.insert($0.keyID).inserted
        }
        guard signers.count <= 24,
              normalized.count == signers.count
        else {
            throw PaperPathError.storageFailure(
                "The trusted signer list is invalid."
            )
        }
        let data = try JSONEncoder.paperPath.encode(normalized)
        try requireData(
            data,
            maximumBytes: Self.maximumTrustedSignerBytes,
            label: "The trusted signer list"
        )
        try writeProtectedData(data, to: officeTrustedSignersURL)
        excludeFromBackup(officeTrustedSignersURL)
    }

    private func normalizedTrustedSigner(
        _ signer: PDFOfficeTrustedSigner
    ) -> PDFOfficeTrustedSigner? {
        guard let keyID = safeSigningKeyID(signer.keyID),
              let publicKey = Data(
                  base64Encoded: signer.publicKeyBase64
              ),
              (try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKey
              )) != nil,
              officeDeliverySigningKeyID(
                  publicKeyData: publicKey
              ) == keyID,
              signer.trustedAt.timeIntervalSinceReferenceDate.isFinite,
              signer.lastVerifiedAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        let displayName = normalizedTrustedSignerText(
            signer.displayName,
            maximumCharacters: 64
        )
        let note = signer.note.map {
            normalizedTrustedSignerText(
                $0,
                maximumCharacters: 240
            )
        }
        return PDFOfficeTrustedSigner(
            keyID: keyID,
            publicKeyBase64: publicKey.base64EncodedString(),
            displayName: displayName.isEmpty
                ? "Signer \(keyID.prefix(8))"
                : displayName,
            trustedAt: signer.trustedAt,
            lastVerifiedAt: signer.lastVerifiedAt,
            verificationCount: min(
                max(0, signer.verificationCount),
                Self.maximumTrustedSignerVerificationCount
            ),
            note: note?.isEmpty == false ? note : nil
        )
    }

    private func normalizedTrustedSignerText(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let sanitized = value.unicodeScalars.map { scalar in
            let codePoint = scalar.value
            let isBidirectionalControl =
                codePoint == 0x061C
                || codePoint == 0x200E
                || codePoint == 0x200F
                || (0x202A...0x202E).contains(codePoint)
                || (0x2066...0x2069).contains(codePoint)
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || isBidirectionalControl {
                return " "
            }
            return String(scalar)
        }
        .joined()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        return String(sanitized.prefix(maximumCharacters))
    }

    private func incrementVerificationCount(
        _ signer: inout PDFOfficeTrustedSigner
    ) {
        if signer.verificationCount
            < Self.maximumTrustedSignerVerificationCount {
            signer.verificationCount += 1
        }
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
            where isSafeOfficeDeliveryFileName(
                fileName,
                for: package.id
            ) {
            try? fileManager.removeItem(
                at: officeDeliveriesURL
                    .appendingPathComponent(fileName)
            )
        }
    }

    private func pruneOfficeDeliveryArtifacts(
        retaining packages: [PDFOfficeDeliveryPackage]
    ) {
        let retainedNames = Set(
            packages.flatMap {
                [$0.archiveFileName, $0.reportFileName]
                    .compactMap { $0 }
            }
        )
        guard let urls = boundedDirectoryContents(
            at: officeDeliveriesURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else { return }

        for url in urls {
            let fileName = url.lastPathComponent
            guard !retainedNames.contains(fileName),
                  isManagedOfficeDeliveryArtifactName(fileName)
            else { continue }
            let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values?.isRegularFile == true
                    || values?.isSymbolicLink == true
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func isManagedOfficeDeliveryArtifactName(
        _ fileName: String
    ) -> Bool {
        if fileName.hasPrefix(".staging-") {
            let suffix = fileName.dropFirst(".staging-".count)
            let identifier = suffix
                .split(separator: ".", maxSplits: 1)
                .first
            return identifier.flatMap {
                UUID(uuidString: String($0))
            } != nil
                && (
                    fileName.hasSuffix(".zip")
                        || fileName.hasSuffix(".json")
                )
        }
        if fileName.hasSuffix(".zip") {
            return UUID(
                uuidString: String(fileName.dropLast(4))
            ) != nil
        }
        let reportSuffix = "-verification.json"
        guard fileName.hasSuffix(reportSuffix) else { return false }
        return UUID(
            uuidString: String(fileName.dropLast(reportSuffix.count))
        ) != nil
    }

    private func isSafeOfficeDeliveryFileName(
        _ fileName: String,
        for packageID: UUID
    ) -> Bool {
        fileName == "\(packageID.uuidString).zip"
            || fileName
                == "\(packageID.uuidString)-verification.json"
    }

    private func currentTrustedDate(
        wallDate: Date = Date(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime,
        forceCheckpoint: Bool = false
    ) -> Date {
        restoreTrustedTimeCheckpointIfNeeded()
        let trustedDate = officeTimeAnchor.trustedDate(
            wallDate: wallDate,
            systemUptime: systemUptime
        )
        _ = persistTrustedTimeCheckpointIfNeeded(
            trustedDate,
            force: forceCheckpoint
        )
        return trustedDate
    }

    private func evidenceIssuanceDate(
        wallDate: Date = Date(),
        systemUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) throws -> Date {
        restoreTrustedTimeCheckpointIfNeeded()
        guard let trustedDate = officeTimeAnchor
            .evidenceIssuanceDate(
                wallDate: wallDate,
                systemUptime: systemUptime
            )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the device time is earlier than PaperPath's last trusted time; correct the system clock before creating new signed evidence"
            )
        }
        guard persistTrustedTimeCheckpointIfNeeded(
                trustedDate,
                force: true
              )
        else {
            throw PaperPathError.storageFailure(
                "The trusted time checkpoint could not be saved."
            )
        }
        return trustedDate
    }

    private func restoreTrustedTimeCheckpointIfNeeded() {
        guard persistsTrustedTimeCheckpoint,
              !didRestoreTrustedTimeCheckpoint
        else {
            return
        }
        let baseQuery = trustedTimeCheckpointQuery
        var readQuery = baseQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            readQuery as CFDictionary,
            &item
        )
        if status == errSecInteractionNotAllowed {
            return
        }
        didRestoreTrustedTimeCheckpoint = true
        guard status == errSecSuccess else {
            return
        }
        guard let data = item as? Data,
              data.count
                <= Self.maximumTrustedTimeCheckpointBytes,
              let checkpoint = try? JSONDecoder().decode(
                PDFTrustedTimeCheckpoint.self,
                from: data
              ),
              let restoredDate = checkpoint.date
        else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        guard officeTimeAnchor.restoreTrustedDate(restoredDate) else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        lastPersistedTrustedDate = restoredDate
    }

    private func persistTrustedTimeCheckpointIfNeeded(
        _ date: Date,
        force: Bool
    ) -> Bool {
        guard persistsTrustedTimeCheckpoint else { return true }
        if !force,
           let lastPersistedTrustedDate,
           date.timeIntervalSince(lastPersistedTrustedDate)
            < Self.trustedTimeCheckpointInterval {
            return true
        }
        let checkpoint = PDFTrustedTimeCheckpoint(
            schema: PDFTrustedTimeCheckpoint.schema,
            observedUnixSeconds: date.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(checkpoint),
              data.count <= Self.maximumTrustedTimeCheckpointBytes
        else {
            return false
        }
        let baseQuery = trustedTimeCheckpointQuery
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            status = updateStatus
        }
        if status == errSecSuccess {
            lastPersistedTrustedDate = date
            return true
        }
        return false
    }

    private var trustedTimeCheckpointQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String:
                Self.trustedTimeCheckpointService,
            kSecAttrAccount as String:
                Self.trustedTimeCheckpointAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
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
        guard let directories = boundedDirectoryContents(
            at: officeExportsURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for directory in directories {
            let values = try? directory.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values?.isSymbolicLink != true,
                  values?.isDirectory == true,
                  let recordID = UUID(
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

    private func removeCommittedRecordArtifacts(
        _ deletedRecords: [DocumentRecord],
        retaining remainingRecords: [DocumentRecord]
    ) {
        let retainedFileNames = Set(remainingRecords.map(\.fileName))
        for record in deletedRecords {
            if !retainedFileNames.contains(record.fileName),
               let fileURL = safeDocumentURL(for: record) {
                try? fileManager.removeItem(at: fileURL)
            }
            try? removeSidecars(for: record)
            let versionDirectory = versionsURL.appendingPathComponent(
                record.id.uuidString,
                isDirectory: true
            )
            try? fileManager.removeItem(at: versionDirectory)
            try? removeOfficeExports(for: record.id)
        }
    }

    private func pruneOrphanedRecordArtifacts(
        retaining records: [DocumentRecord]
    ) {
        let recordIDs = Set(records.map(\.id))
        let documentFileNames = Set(records.map(\.fileName))
        pruneUUIDFiles(
            in: filesURL,
            pathExtension: "pdf",
            retainingNames: documentFileNames
        )
        for directory in [indicesURL, ocrURL, preflightURL] {
            pruneUUIDFiles(
                in: directory,
                pathExtension: "json",
                retainingNames: Set(
                    recordIDs.map { "\($0.uuidString).json" }
                )
            )
        }
        if let checkpoints = boundedDirectoryContents(
            at: ocrURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            for url in checkpoints where url.pathExtension == "resume" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !recordIDs.contains(id) else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func pruneUUIDFiles(
        in directory: URL,
        pathExtension: String,
        retainingNames: Set<String>
    ) {
        guard let urls = boundedDirectoryContents(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else { return }
        for url in urls {
            let name = url.lastPathComponent
            guard !retainingNames.contains(name),
                  url.pathExtension.caseInsensitiveCompare(
                    pathExtension
                  ) == .orderedSame,
                  UUID(
                    uuidString: url.deletingPathExtension()
                        .lastPathComponent
                  ) != nil
            else { continue }
            let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values?.isRegularFile == true
                    || values?.isSymbolicLink == true
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func pruneOfficeExportDirectory(
        for record: DocumentRecord
    ) {
        let directory = officeExportDirectory(for: record.id)
        guard let files = boundedDirectoryContents(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
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
            let values = try? file.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values?.isRegularFile == true
                    || values?.isSymbolicLink == true
            else { continue }
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
            ocrCheckpointURL(for: recordID),
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
