import Foundation
import PDFKit
import UIKit

struct ExternalDocumentHandoff: Equatable, Sendable {
    let recordID: UUID
    let targetSceneID: UUID?
}

struct ExternalDocumentHandoffQueue: Equatable, Sendable {
    private(set) var entries: [ExternalDocumentHandoff] = []

    mutating func enqueue(
        recordID: UUID,
        targetSceneID: UUID?
    ) {
        guard !entries.contains(where: {
            $0.recordID == recordID
        }) else { return }
        entries.append(
            ExternalDocumentHandoff(
                recordID: recordID,
                targetSceneID: targetSceneID
            )
        )
    }

    func recordID(for sceneID: UUID) -> UUID? {
        entries.first {
            $0.targetSceneID == sceneID
        }?.recordID
            ?? entries.first {
                $0.targetSceneID == nil
            }?.recordID
    }

    mutating func clear(recordID: UUID) {
        entries.removeAll { $0.recordID == recordID }
    }

    mutating func removeUnavailable(
        availableRecordIDs: Set<UUID>
    ) {
        entries.removeAll {
            !availableRecordIDs.contains($0.recordID)
        }
    }

    mutating func releaseTarget(for sceneID: UUID) {
        entries = entries.map { handoff in
            guard handoff.targetSceneID == sceneID else {
                return handoff
            }
            return ExternalDocumentHandoff(
                recordID: handoff.recordID,
                targetSceneID: nil
            )
        }
    }
}

private enum AppFeedbackContext {
    @TaskLocal static var targetSceneID: UUID?
}

private struct BatchPreflightOutcome: Sendable {
    let recordID: UUID
    let revisionID: UUID?
    let assessment: PDFDeliveryPreflightAssessment?
    let issue: PDFBatchDeliveryIssue?
}

private struct PageMutationUndo: Sendable {
    let backupURL: URL
    let expectedRevisionID: UUID
    let bookmarkedPages: [Int]
    let bookmarkNames: [Int: String]
    let lastPageIndex: Int
    let taskCheckpoint: DocumentTaskCheckpoint?
    let label: String
    var sourceRevisionID: UUID? = nil
}

private struct PageMutationNavigationState: Sendable {
    let bookmarkedPages: [Int]
    let bookmarkNames: [Int: String]
    let lastPageIndex: Int
    let taskCheckpoint: DocumentTaskCheckpoint?
}

private struct DocumentAnalysisTaskEntry {
    let revisionID: UUID
    let generation: UUID
    let task: Task<Void, Never>
}

private struct ReadingPositionTaskEntry {
    let recordID: UUID
    let generation: UUID
    let task: Task<Void, Never>
}

private struct ProtectedTemporaryPDF: Sendable {
    let directoryURL: URL
    let fileURL: URL
    let prefix: String

    init(prefix: String) {
        self.prefix = prefix
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)\(UUID().uuidString)",
                isDirectory: true
            )
        fileURL = directoryURL.appendingPathComponent("document.pdf")
    }

    func prepare() throws {
        try LocalFileSecurity.prepareProtectedDirectory(at: directoryURL)
    }

    func copy(
        from sourceURL: URL,
        expectedByteCount: Int64
    ) throws {
        guard expectedByteCount > 0 else {
            throw PaperPathError.unreadablePDF
        }
        let identityKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        let initialSourceValues = try sourceURL.resourceValues(
            forKeys: identityKeys
        )
        guard initialSourceValues.isRegularFile == true,
              initialSourceValues.isSymbolicLink != true,
              Int64(initialSourceValues.fileSize ?? -1)
                == expectedByteCount
        else {
            throw PaperPathError.unreadablePDF
        }

        try prepare()
        guard
              FileManager.default.createFile(
                  atPath: fileURL.path,
                  contents: nil
              )
        else {
            throw PaperPathError.unreadablePDF
        }
        try LocalFileSecurity.requireCompleteProtection(to: fileURL)
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: fileURL)
        defer { try? output.close() }
        var copiedByteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            let (nextByteCount, overflow) = copiedByteCount
                .addingReportingOverflow(Int64(data.count))
            guard !overflow,
                  nextByteCount <= expectedByteCount
            else {
                throw PaperPathError.unreadablePDF
            }
            try output.write(contentsOf: data)
            copiedByteCount = nextByteCount
        }
        try Task.checkCancellation()
        try output.synchronize()
        let finalSourceValues = try sourceURL.resourceValues(
            forKeys: identityKeys
        )
        let destinationValues = try fileURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ]
        )
        let sourceIdentifierMatches: Bool
        if let initialIdentifier =
                initialSourceValues.fileResourceIdentifier as? NSObject {
            sourceIdentifierMatches =
                (finalSourceValues.fileResourceIdentifier as? NSObject)?
                    .isEqual(initialIdentifier) == true
        } else {
            sourceIdentifierMatches =
                finalSourceValues.fileResourceIdentifier == nil
        }
        guard copiedByteCount == expectedByteCount,
              finalSourceValues.isRegularFile == true,
              finalSourceValues.isSymbolicLink != true,
              Int64(finalSourceValues.fileSize ?? -1)
                == expectedByteCount,
              finalSourceValues.contentModificationDate
                == initialSourceValues.contentModificationDate,
              sourceIdentifierMatches,
              destinationValues.isRegularFile == true,
              destinationValues.isSymbolicLink != true,
              Int64(destinationValues.fileSize ?? -1)
                == expectedByteCount
        else {
            throw PaperPathError.unreadablePDF
        }
        try LocalFileSecurity.requireCompleteProtection(to: fileURL)
    }

    func remove() {
        PaperPathTemporaryArtifact.removeManagedItem(
            containing: fileURL,
            allowedPrefixes: [prefix]
        )
    }
}

private func removePageMutationTemporaryItem(containing url: URL) {
    PaperPathTemporaryArtifact.removeManagedItem(
        containing: url,
        allowedPrefixes: [
            "PaperPath-Bates-Undo-",
            "PaperPath-Bates-Prepared-",
            "PaperPath-Bates-Removal-Undo-",
            "PaperPath-Bates-Removal-",
            "PaperPath-PageUndo-",
            "PaperPath-Mutation-"
        ]
    )
}

private struct PDFComparisonCacheKey: Hashable {
    let sourceRecordID: UUID
    let sourceRevisionID: UUID
    let revisedRecordID: UUID
    let revisedRevisionID: UUID
}

private struct PDFPageAssessmentCacheKey: Hashable {
    let recordID: UUID
    let revisionID: UUID
}

private struct PDFVersionComparisonCacheKey: Hashable {
    let recordID: UUID
    let snapshotID: UUID
    let currentRevisionID: UUID
}

private struct ActivePDFComparison {
    let recordIDs: Set<UUID>
    let task: Task<PDFChangeReview, Error>
}

private struct ActiveExclusiveDocumentWorker {
    let operationToken: UUID
    let cancel: @Sendable () -> Void
}

private actor PDFComparisonCoordinator {
    private let service: PDFDeliveryAuditService

    init(service: PDFDeliveryAuditService) {
        self.service = service
    }

    func compare(
        sourceURL: URL,
        revisedURL: URL,
        manualMatches: [PDFManualPageMatch] = [],
        progress: @escaping PDFComparisonProgressHandler = { _ in }
    ) throws -> PDFChangeReview {
        try service.compare(
            sourceURL: sourceURL,
            revisedURL: revisedURL,
            manualMatches: manualMatches,
            progress: progress
        )
    }
}

private final class MainActorLatestValueRelay<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var latestValue: Value?
    private var isDeliveryScheduled = false
    private let consume: @MainActor @Sendable (Value) -> Void

    init(
        consume: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        self.consume = consume
    }

    func send(_ value: Value) {
        lock.lock()
        latestValue = value
        guard !isDeliveryScheduled else {
            lock.unlock()
            return
        }
        isDeliveryScheduled = true
        lock.unlock()

        Task { @MainActor [self] in
            deliverLatestValue()
        }
    }

    @MainActor
    private func deliverLatestValue() {
        lock.lock()
        let value = latestValue
        latestValue = nil
        isDeliveryScheduled = false
        lock.unlock()
        guard let value else { return }
        consume(value)
    }
}

struct ByteRateWindow {
    private struct Sample {
        let date: Date
        let bytes: Int64
    }

    private var stage: PDFByteProgressStage?
    private var samples: [Sample] = []
    private(set) var rate: Double = 0
    private(set) var history: [Double] = []

    mutating func reset() {
        stage = nil
        samples.removeAll(keepingCapacity: true)
        rate = 0
        history.removeAll(keepingCapacity: true)
    }

    mutating func update(
        stage newStage: PDFByteProgressStage,
        processedBytes: Int64,
        at date: Date = Date()
    ) -> Double {
        let boundedBytes = max(0, processedBytes)
        let sampleDate = date.timeIntervalSince1970.isFinite
            ? date
            : Date()
        if stage != newStage
            || boundedBytes < (samples.last?.bytes ?? 0) {
            stage = newStage
            samples = [
                Sample(date: sampleDate, bytes: boundedBytes)
            ]
            rate = 0
            history.removeAll(keepingCapacity: true)
            return rate
        }
        guard boundedBytes > (samples.last?.bytes ?? -1) else {
            return rate
        }
        samples.append(
            Sample(date: sampleDate, bytes: boundedBytes)
        )
        let cutoff = sampleDate.addingTimeInterval(-5)
        while samples.count > 2,
              samples[1].date < cutoff {
            samples.removeFirst()
        }
        if samples.count > 12 {
            samples.removeFirst(samples.count - 12)
        }
        guard let first = samples.first,
              let last = samples.last,
              last.bytes > first.bytes
        else {
            rate = 0
            return rate
        }
        let rawDuration = last.date.timeIntervalSince(first.date)
        guard rawDuration.isFinite else {
            rate = 0
            return rate
        }
        let duration = max(
            0.05,
            rawDuration
        )
        let (byteDelta, overflow) = last.bytes
            .subtractingReportingOverflow(first.bytes)
        guard !overflow, byteDelta > 0 else {
            rate = 0
            return rate
        }
        let measuredRate = Double(byteDelta) / duration
        rate = measuredRate.isFinite && measuredRate > 0
            ? min(Double(Int64.max / 2), measuredRate)
            : 0
        if rate > 0 {
            history.append(rate)
            if history.count > 24 {
                history.removeFirst(history.count - 24)
            }
        }
        return rate
    }

    mutating func operationProgress(
        label: String,
        update: PDFByteProgressUpdate,
        current: PDFOperationProgress?
    ) -> PDFOperationProgress? {
        if current?.byteStage == update.stage,
           update.processedBytes < (current?.processedBytes ?? 0) {
            return nil
        }
        let now = Date()
        let didAdvance = current?.byteStage != update.stage
            || update.processedBytes > (current?.processedBytes ?? 0)
            || current?.lastByteUpdateAt == nil
        let bytesPerSecond = self.update(
            stage: update.stage,
            processedBytes: update.processedBytes,
            at: now
        )
        let stageFraction = update.totalBytes > 0
            ? min(
                1,
                max(
                    0,
                    Double(update.processedBytes)
                        / Double(update.totalBytes)
                )
            )
            : 0
        let mappedFraction: Double
        switch update.stage {
        case .checksumming:
            mappedFraction = stageFraction * 0.45
        case .archiving:
            mappedFraction = 0.45 + stageFraction * 0.55
        case .copying, .reconstructing, .packaging, .verifying:
            mappedFraction = stageFraction
        }
        let fraction = max(
            current?.fractionCompleted ?? 0,
            mappedFraction
        )
        return PDFOperationProgress(
            label: label,
            fractionCompleted: fraction,
            byteStage: update.stage,
            processedBytes: update.processedBytes,
            totalBytes: update.totalBytes,
            bytesPerSecond: bytesPerSecond,
            estimatedRemainingSeconds:
                bytesPerSecond > 0 && update.totalBytes > 0
                    ? Double(
                        max(
                            0,
                            update.totalBytes - update.processedBytes
                        )
                    ) / bytesPerSecond
                    : nil,
            throughputHistory: history,
            lastByteUpdateAt: didAdvance
                ? now
                : current?.lastByteUpdateAt
        )
    }
}

@MainActor
final class PaperPathModel: ObservableObject {
    private static let maximumExternalPageSourceBytes:
        Int64 = 1_073_741_824

    @Published private(set) var documents: [DocumentRecord] = [] {
        didSet {
            rebuildDocumentDerivedIndexes()
        }
    }
    @Published private(set) var deletedDocuments: [DocumentRecord] = []
    @Published private(set) var documentURLs: [UUID: URL] = [:]
    @Published private(set) var refreshTokens: [UUID: Int] = [:]
    @Published private(set) var ocrResults: [UUID: OCRResult] = [:]
    @Published private(set) var textIndices: [UUID: DocumentTextIndex] = [:]
    @Published private(set) var processingDocumentIDs: Set<UUID> = []
    @Published private(set) var comparingDocumentIDs: Set<UUID> = []
    @Published private(set) var deliveryProcessingDocumentIDs: Set<UUID> = []
    @Published private(set) var batchDeliveryPendingDocumentIDs: Set<UUID> = []
    @Published private(set) var batesBatchProgress:
        PDFBatesBatchProgress?
    @Published private(set) var isBatesBatchMutationActive = false
    @Published private(set) var batesBatchReceipts:
        [PDFSignedBatesBatchReceipt] = []
    @Published private(set) var batesReceiptVerificationProgress:
        PDFBatesBatchReceiptVerificationProgress?
    @Published private(set) var isBatesReceiptVerificationActive =
        false
    @Published private(set) var batesExternalMatchProgress:
        PDFBatesExternalMatchProgress?
    @Published private(set) var operationProgress: [UUID: PDFOperationProgress] = [:]
    @Published private(set) var savedSignatureData: Data?
    @Published private(set) var savedSignatures: [SavedSignature] = []
    @Published private(set) var selectedSignatureID: UUID?
    @Published private(set) var lastBatchDeliveryRun: PDFBatchDeliveryRun?
    @Published private(set) var batchDeliveryPersistenceError: String?
    @Published private(set) var activeBatchDeliveryRunID: UUID?
    @Published private(set) var officeBatchRuns:
        [UUID: PDFOfficeBatchRun] = [:]
    @Published private(set) var officeProductionQueue =
        PDFOfficeProductionQueue()
    @Published private(set) var officeResourceSnapshot =
        PDFOfficeResourceSnapshot.initial
    @Published private(set) var lastOfficeIntegrityReport:
        PDFOfficeIntegrityReport?
    @Published private(set) var officeIntegrityProgress:
        PDFOfficeIntegrityProgress?
    @Published private(set) var officeDeliveryPackages:
        [PDFOfficeDeliveryPackage] = []
    @Published private(set) var officeDeliverySigningKeyID: String?
    @Published private(set) var lastOfficeReportVerification:
        PDFOfficeReportVerificationResult?
    @Published private(set) var officeExternalMatchProgress:
        PDFOfficeExternalMatchProgress?
    @Published private(set) var officeSigningIdentityCard:
        PDFOfficeSignerIdentityCard?
    @Published private(set) var officeTrustedSigners:
        [PDFOfficeTrustedSigner] = []
    @Published private(set) var metadataSyncStatus =
        PDFMetadataSyncStatus.idle
    @Published private(set) var analyzingDocumentIDs: Set<UUID> = []
    @Published var isLoading = true
    @Published private(set) var isImporting = false
    @Published private var scanImportProgresses: [UUID: Double] = [:]
    @Published private var foregroundImportProgresses:
        [UUID: PDFOperationProgress] = [:]
    @Published private(set) var externalImportProgress:
        PDFOperationProgress?
    @Published private(set) var isExternalPDFImportActive = false
    @Published private(set) var externalImportRetryAvailable = false
    @Published private(set) var externalImportDeferredCount = 0
    @Published private(set) var externalImportRetryMessage: String?
    @Published private(set) var retainedEvidenceRevision = 0
    @Published private var presentationErrorsBySceneID:
        [UUID: AppPresentationError] = [:]
    @Published private var unscopedPresentationError:
        AppPresentationError?
    @Published private var actionNoticesBySceneID:
        [UUID: AppActionNotice] = [:]
    @Published private var unscopedActionNotice: AppActionNotice?
    @Published private var transientNoticesBySceneID:
        [UUID: AppTransientNotice] = [:]
    @Published private var unscopedTransientNotice:
        AppTransientNotice?
    private var activeFeedbackSceneIDs = Set<UUID>()
    private var feedbackSceneRecency: [UUID: UInt64] = [:]
    private var feedbackSceneSequence: UInt64 = 0
    var noticeMessage: String? {
        get { unscopedTransientNotice?.message }
        set {
            setTransientNotice(
                newValue,
                targetSceneID: AppFeedbackContext.targetSceneID
            )
        }
    }
    subscript(noticeFor sceneID: UUID?) -> String? {
        get {
            if let sceneID {
                return transientNotice(for: sceneID)?.message
            }
            return unscopedTransientNotice?.message
        }
        set {
            if let newValue {
                setTransientNotice(
                    newValue,
                    targetSceneID: sceneID
                )
            } else {
                dismissTransientNotice(from: sceneID)
            }
        }
    }
    @Published private(set) var externalDocumentHandoffs =
        ExternalDocumentHandoffQueue()
    var pendingExternalDocumentID: UUID? {
        externalDocumentHandoffs.entries.first?.recordID
    }
    @Published private var fullUnlockContextsBySceneID:
        [UUID: FullUnlockContext] = [:]
    @Published private var unscopedFullUnlockContext:
        FullUnlockContext?
    @Published private var settingsPresentationSceneIDs =
        Set<UUID>()
    @Published private var hasUnscopedSettingsPresentationRequest =
        false
    @Published private(set) var verifiedOutputSuccessCount =
        AppEntitlement.verifiedOutputCount

    private let store: DocumentStore
    private let mutationService: PDFMutationService
    private let ocrService: VisionOCRService
    private let scanRenderer: ScanPDFRenderer
    private let textIndexService: PDFTextIndexService
    private let understandingService: DocumentUnderstandingService
    private let compositionService: PDFCompositionService
    private let searchablePDFService: SearchablePDFService
    private let outputService: PDFOutputService
    private let deliveryAuditService: PDFDeliveryAuditService
    private let comparisonCoordinator: PDFComparisonCoordinator
    private let documentStructureService: PDFDocumentStructureService
    private let signatureStore: SignatureStore
    private let metadataSyncService: PDFMetadataSyncService
    private var documentRecordsByID: [UUID: DocumentRecord] = [:]
    private var isFreeVerifiedOutputReserved = false
    private var workingDocumentCache: [DocumentRecord] = []
    private var deliveryOutputCache: [DocumentRecord] = []
    private var verifiedDeliveryOutputCountCache = 0
    private var pinnedOfficeOutputCache: [PDFPinnedOfficeOutput] = []
    private var pinnedOfficeStorageSummaryCache =
        PDFOfficePinnedStorageSummary(outputCount: 0, byteCount: 0)
    private var verifiedOutputsBySourceID:
        [UUID: [DocumentRecord]] = [:]
    private var deliveryHistoryBySourceID:
        [UUID: [DocumentRecord]] = [:]
    private var verifiedShareTargetsByRecordID:
        [UUID: DocumentRecord] = [:]
    private var workingFingerprintCounts: [String: Int] = [:]
    private var attentionCountCache = 0
    private var libraryCommandSummaryCache = LibraryCommandSummary(
        readiness: .ready,
        score: 100,
        totalCount: 0,
        readyCount: 0,
        attentionCount: 0,
        verifiedCount: 0,
        staleReceiptCount: 0,
        officeReviewCount: 0,
        lockedCount: 0,
        scansNeedingOCRCount: 0,
        dueNowCount: 0,
        batchEligibleCount: 0
    )
    private var libraryCommandSummaryCacheDay = Date.distantPast
    private var recordsWithRecognizedText: Set<UUID> = []
    private var residentAnalysisOrder: [UUID] = []
    private var residentAnalysisGeneration = UUID()
    private var documentAnalysisTasks:
        [UUID: DocumentAnalysisTaskEntry] = [:]
    private static let maximumResidentAnalysisRecords = 8
    private var searchMetadataCorpora: [UUID: String] = [:]
    private var searchTextCorpora: [UUID: String] = [:]
    private var searchTextCorpusCosts: [UUID: Int] = [:]
    private var streamingSearchTextRecordIDs: Set<UUID> = []
    private var searchTextCorpusCost = 0
    private var scanImportGenerations: [UUID: UUID] = [:]
    private var batesReceiptVerificationToken: UUID?
    private var batesExternalMatchGeneration = UUID()
    private var officeReportVerificationGeneration = UUID()
    private var officeExternalMatchGeneration = UUID()
    private var deliveryPreflightCache: [
        UUID: PDFDeliveryPreflightCacheEntry
    ] = [:]
    private static let maximumInMemoryPreflightEntries = 64
    private var comparisonCache: [
        PDFComparisonCacheKey: PDFChangeReview
    ] = [:]
    private var comparisonCacheOrder: [PDFComparisonCacheKey] = []
    private static let maximumComparisonCacheBytes: Int64 =
        12 * 1_024 * 1_024
    private var pageAssessmentCache: [
        PDFPageAssessmentCacheKey: PDFPagePreparationAssessment
    ] = [:]
    private var pageAssessmentCacheOrder: [
        PDFPageAssessmentCacheKey
    ] = []
    private var versionComparisonCache: [
        PDFVersionComparisonCacheKey: PDFChangeReview
    ] = [:]
    private var versionComparisonCacheOrder: [
        PDFVersionComparisonCacheKey
    ] = []
    private static let maximumVersionComparisonCacheBytes: Int64 =
        12 * 1_024 * 1_024
    private var activeComparisonTasks:
        [UUID: ActivePDFComparison] = [:]
    private var isClearingPageMatches = false
    private var isUpdatingVersionStorage = false
    private var isErasingAllLocalData = false
    private var pageMutationUndos: [UUID: PageMutationUndo] = [:]
    private var pageMutationUndoOrder: [UUID] = []
    private static let maximumPageMutationUndoCount = 4
    private static let maximumPageMutationUndoBytes: Int64 =
        256 * 1_024 * 1_024
    private var readingPositionTasks:
        [UUID: ReadingPositionTaskEntry] = [:]
    private var trustedTimeCheckpointTask: Task<Void, Never>?
    private var trustedTimeCheckpointGeneration = UUID()
    private var initialBootstrapTask: Task<Bool, Never>?
    private var initialBootstrapGeneration = UUID()
    private var deferredBootstrapTask: Task<Void, Never>?
    private var deferredBackgroundWorkNeedsRestart = false
    private var metadataSyncTask: Task<Void, Never>?
    private nonisolated(unsafe) var metadataSyncObserver:
        NSObjectProtocol?
    private nonisolated(unsafe) var memoryWarningObserver:
        NSObjectProtocol?
    private var didBootstrap = false
    private var isBootstrapping = false
    private var isApplyingMetadataSync = false
    private var isSynchronizingMetadata = false
    private var metadataSyncNeedsFollowUp = false
    private var metadataSyncFollowUpShowsNotice = false
    private var metadataSyncAutomaticRetryBlocked = false
    private var metadataSyncGeneration = UUID()
    private var metadataSyncScheduleGeneration = UUID()
    private static let maximumMetadataSyncPassesPerRun = 3
    private var queuedExternalPDFURLs: [URL] = []
    private var queuedExternalPDFTargetSceneIDs: [String: UUID] = [:]
    private var activeExternalPDFURLIdentities: Set<String> = []
    private var isProcessingExternalPDFs = false
    private var externalPDFImportTask: Task<Void, Never>?
    private var externalPDFImportGeneration = UUID()
    private var externalPDFDeferredOpenGeneration: UUID?
    private var externalImportKnownTotalCount = 0
    private var externalImportCompletedItemCount = 0
    private var externalImportCurrentItemFraction: Double = 0
    private var externalImportRateWindow = ByteRateWindow()
    private var activeForegroundImportProgressIDs: Set<UUID> = []
    private var foregroundImportRateWindows:
        [UUID: ByteRateWindow] = [:]
    private var activeImportOperations: Set<UUID> = []
    private var deferredCommittedImports: [UUID: DocumentRecord] = [:]
    private var deferredCommittedImportSourceIdentities:
        [UUID: String] = [:]
    private var deferredCommittedOpenRecordIDs: [UUID] = []
    private var deferredCommittedOpenSceneIDs: [UUID: UUID] = [:]
    private var completedExternalImportSceneIDs: [UUID: UUID] = [:]
    private var committedImportRestoreTask: Task<Void, Never>?
    private var committedImportRestoreGeneration = UUID()
    private var scanRenderTasks: [UUID: Task<Void, Error>] = [:]
    private var batesBatchMutationToken: UUID?
    private var officeProductionTask: Task<Void, Never>?
    private var officeProductionCancelledJobID: UUID?
    private var officeResourceMonitorTask: Task<Void, Never>?
    private var officeIntegrityGeneration: UUID?
    private var officeIntegrityRateWindow = ByteRateWindow()
    private var operationRateWindows: [UUID: ByteRateWindow] = [:]
    private var exclusiveDocumentOperations: [UUID: UUID] = [:]
    private var backgroundCancellableDocumentOperations:
        [UUID: UUID] = [:]
    private var cancelledExclusiveDocumentOperationTokens: Set<UUID> = []
    private var activeExclusiveDocumentWorkers:
        [UUID: ActiveExclusiveDocumentWorker] = [:]
    private var importingVerifiedPackageIDs: Set<UUID> = []
    private var importingVerifiedVersionArtifactIDs: Set<UUID> = []
    private var versionArchiveVerificationGeneration = UUID()
    private static let maximumQueuedExternalPDFCount = 64

    init(
        store: DocumentStore = DocumentStore(),
        mutationService: PDFMutationService = PDFMutationService(),
        ocrService: VisionOCRService = VisionOCRService(),
        scanRenderer: ScanPDFRenderer = ScanPDFRenderer(),
        textIndexService: PDFTextIndexService = PDFTextIndexService(),
        understandingService: DocumentUnderstandingService = DocumentUnderstandingService(),
        compositionService: PDFCompositionService = PDFCompositionService(),
        searchablePDFService: SearchablePDFService = SearchablePDFService(),
        outputService: PDFOutputService = PDFOutputService(),
        deliveryAuditService: PDFDeliveryAuditService = PDFDeliveryAuditService(),
        documentStructureService: PDFDocumentStructureService =
            PDFDocumentStructureService(),
        signatureStore: SignatureStore = SignatureStore(),
        metadataSyncService: PDFMetadataSyncService? = nil
    ) {
        self.store = store
        self.mutationService = mutationService
        self.ocrService = ocrService
        self.scanRenderer = scanRenderer
        self.textIndexService = textIndexService
        self.understandingService = understandingService
        self.compositionService = compositionService
        self.searchablePDFService = searchablePDFService
        self.outputService = outputService
        self.deliveryAuditService = deliveryAuditService
        self.comparisonCoordinator = PDFComparisonCoordinator(
            service: deliveryAuditService
        )
        self.documentStructureService = documentStructureService
        self.signatureStore = signatureStore
        self.metadataSyncService = metadataSyncService
            ?? PDFMetadataSyncService()
        UserDefaults.standard.removeObject(
            forKey: "library.searchHistory"
        )
        UserDefaults.standard.removeObject(
            forKey: "document.findHistory"
        )
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure()
            }
        }
    }

    deinit {
        initialBootstrapTask?.cancel()
        deferredBootstrapTask?.cancel()
        for entry in documentAnalysisTasks.values {
            entry.task.cancel()
        }
        for comparison in activeComparisonTasks.values {
            comparison.task.cancel()
        }
        for worker in activeExclusiveDocumentWorkers.values {
            worker.cancel()
        }
        for entry in readingPositionTasks.values {
            entry.task.cancel()
        }
        trustedTimeCheckpointTask?.cancel()
        metadataSyncTask?.cancel()
        externalPDFImportTask?.cancel()
        for task in scanRenderTasks.values {
            task.cancel()
        }
        officeProductionTask?.cancel()
        officeResourceMonitorTask?.cancel()
        if let metadataSyncObserver {
            NotificationCenter.default.removeObserver(
                metadataSyncObserver
            )
        }
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(
                memoryWarningObserver
            )
        }
    }

    func bootstrap() async {
        await store.checkpointTrustedTime()
        if didBootstrap {
            await restoreCommittedImportsForForeground()
            guard !Task.isCancelled else { return }
            await processPendingExternalPDFs()
            guard !Task.isCancelled else { return }
            await restoreCommittedImportsForForeground()
            resumeDeferredBackgroundWork()
            return
        }
        if let initialBootstrapTask {
            let completed = await initialBootstrapTask.value
            guard !completed,
                  !Task.isCancelled,
                  !didBootstrap
            else { return }
            await bootstrap()
            return
        }
        let generation = UUID()
        initialBootstrapGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            let completed = await self.performInitialBootstrap()
            if self.initialBootstrapGeneration == generation {
                self.initialBootstrapTask = nil
            }
            return completed
        }
        initialBootstrapTask = task
        let completed = await task.value
        guard !completed,
              !Task.isCancelled,
              !didBootstrap
        else { return }
        await bootstrap()
    }

    private func performInitialBootstrap() async -> Bool {
        isBootstrapping = true
        defer { isBootstrapping = false }
        deferredBootstrapTask?.cancel()
        deferredBootstrapTask = nil
        deferredBackgroundWorkNeedsRestart = false
        isLoading = true
        do {
            try await discardInterruptedTemporaryFiles()
            applyBootstrapSnapshot(
                try await store.loadBootstrapSnapshot()
            )
            await applyTrashRetention(showNotice: false)
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(
                "UITEST_OFFICE_CORPUS_FIXTURE"
            ) {
                try await prepareOfficeCorpusUITestFixture()
            } else if arguments.contains("UITEST_RESET_DEMO") {
                try await store.eraseAllData()
                try await signatureStore.remove()
                AppEntitlement.resetVerifiedOutputHistoryForUITesting()
                verifiedOutputSuccessCount = 0
                await Task.detached(priority: .utility) {
                    try? ExternalPDFInbox.removeAll()
                }.value
                try await seedDemo()
                applyBootstrapSnapshot(
                    try await store.loadBootstrapSnapshot()
                )
            } else if documents.isEmpty,
                      arguments.contains("UITEST_SEED_DEMO") {
                try await seedDemo()
                applyBootstrapSnapshot(
                    try await store.loadBootstrapSnapshot()
                )
            }
            if arguments.contains("UITEST_PREPARE_FIND_INDEX") {
                await prepareFindIndexForUITest()
            }
#endif
            do {
                batesBatchReceipts = try await store
                    .loadBatesBatchReceipts()
            } catch {
                batesBatchReceipts = []
                present(error)
            }
            restoreOfficeBatchRuns()
            officeProductionQueue = try await store
                .loadOfficeProductionQueue()
            officeProductionQueue.restoreInterruptedWork()
            reconcileOfficeProductionQueueSources()
            try? await store.saveOfficeProductionQueue(
                officeProductionQueue
            )
            officeDeliveryPackages = try await store
                .loadOfficeDeliveryPackages()
            officeDeliverySigningKeyID = try? await store
                .officeDeliverySigningKeyID()
            officeSigningIdentityCard = try? await store
                .officeDeliverySigningIdentityCard()
            officeTrustedSigners = (
                try? await store.loadOfficeTrustedSigners()
            ) ?? []
            await refreshOfficeResourceSnapshot()
            try await restoreBatchDeliveryRun()
            do {
                applySignatureLibrary(
                    try await signatureStore.loadLibrary()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                applySignatureLibrary(.empty)
                present(error)
            }
            rebuildSearchCorpora()
            didBootstrap = true
#if DEBUG
            if arguments.contains("SCREENSHOT_SETTINGS") {
                requestSettingsPresentation(in: nil)
            } else if arguments.contains("SCREENSHOT_FULL_UNLOCK") {
                presentFullUnlock(.settings)
            }
#endif
            isLoading = false
            await processPendingExternalPDFs()
            guard !isRunningAutomatedTests else { return true }
            resumeDeferredBackgroundWork()
            return true
        } catch is CancellationError {
            if !didBootstrap {
                isLoading = false
            }
            return false
        } catch {
            isLoading = false
            present(error)
            return true
        }
    }

    func resumeDeferredBackgroundWork() {
        guard didBootstrap,
              !isRunningAutomatedTests,
              deferredCommittedImports.isEmpty,
              !Task.isCancelled
        else { return }
        guard deferredBootstrapTask == nil else {
            deferredBackgroundWorkNeedsRestart = true
            return
        }
        deferredBackgroundWorkNeedsRestart = false
        deferredBootstrapTask = Task { [weak self] in
            await self?.finishDeferredBootstrap()
            guard let self else { return }
            let shouldRestart =
                self.deferredBackgroundWorkNeedsRestart
                    && !Task.isCancelled
            self.deferredBootstrapTask = nil
            self.deferredBackgroundWorkNeedsRestart = false
            if shouldRestart {
                self.resumeDeferredBackgroundWork()
            }
        }
    }

    private func finishDeferredBootstrap() async {
        guard !Task.isCancelled else { return }
        await analyzeMissingDocuments()
        guard !Task.isCancelled else { return }
        guard UserDefaults.standard.bool(
            forKey: AppPreferences.metadataSyncEnabledKey
        ) else {
            metadataSyncStatus = metadataSyncDisabledStatus
            return
        }
        startMetadataSyncObservation()
        await synchronizeMetadata(showNotice: false)
    }

    private func applyBootstrapSnapshot(
        _ snapshot: DocumentStoreBootstrapSnapshot
    ) {
        documents = snapshot.documents
        deletedDocuments = snapshot.deletedDocuments
        documentURLs = snapshot.documentURLs
        textIndices = snapshot.textIndices
        replaceOCRResults(snapshot.ocrResults)
        residentAnalysisOrder = documents
            .filter {
                snapshot.textIndices[$0.id] != nil
                    || snapshot.ocrResults[$0.id] != nil
            }
            .sorted {
                let lhs = $0.lastViewedAt ?? $0.modifiedAt
                let rhs = $1.lastViewedAt ?? $1.modifiedAt
                if lhs != rhs {
                    return lhs < rhs
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(\.id)
        deliveryPreflightCache = snapshot.deliveryPreflightCache
        if AppEntitlement.verifiedOutputCount == 0,
           documents.contains(where: isVerifiedSafeShareOutput) {
            verifiedOutputSuccessCount =
                AppEntitlement.recordVerifiedOutput()
        } else {
            verifiedOutputSuccessCount =
                AppEntitlement.verifiedOutputCount
        }
    }

    func ensureAnalysisLoaded(for recordID: UUID) async {
        guard let sourceRecord = record(id: recordID) else { return }
        let needsOCR = sourceRecord.completedActions.contains(
            .recognizeText
        )
        if textIndices[recordID] != nil,
           !needsOCR || ocrResults[recordID] != nil {
            touchResidentAnalysis(recordID)
            return
        }
        guard sourceRecord.brief != nil else {
            if needsOCR {
                recordsWithRecognizedText.remove(recordID)
                rebuildAttentionCount()
                await setActionCompletion(
                    recordID: recordID,
                    action: .recognizeText,
                    completed: false
                )
            }
            await analyzeDocument(recordID: recordID)
            return
        }
        let generation = residentAnalysisGeneration

        do {
            let snapshot = try await store.loadAnalysis(
                for: Set([recordID])
            )
            try Task.checkCancellation()
            guard residentAnalysisGeneration == generation,
                  record(id: recordID)?.contentRevisionID
                    == sourceRecord.contentRevisionID
            else { return }
            textIndices.merge(snapshot.textIndices) {
                _, loaded in loaded
            }
            mergeOCRResults(snapshot.ocrResults)
            let loadedOCRResult = snapshot.ocrResults[recordID]
            if needsOCR,
               loadedOCRResult.map(hasUsefulRecognizedText) != true {
                recordsWithRecognizedText.remove(recordID)
                rebuildAttentionCount()
                await setActionCompletion(
                    recordID: recordID,
                    action: .recognizeText,
                    completed: false
                )
            }
            if snapshot.textIndices[recordID] == nil {
                await analyzeDocument(recordID: recordID)
            } else {
                touchResidentAnalysis(recordID)
                trimResidentAnalysisCache()
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func searchLibraryPageIndex(
        query: String,
        orderedRecordIDs: [UUID]
    ) async throws -> DocumentStoreTextSearchSnapshot {
        let candidates: [DocumentStoreTextSearchCandidate] =
            orderedRecordIDs.compactMap {
                recordID -> DocumentStoreTextSearchCandidate? in
                guard let record = documentRecordsByID[recordID] else {
                    return nil
                }
                return DocumentStoreTextSearchCandidate(
                    recordID: recordID,
                    metadataCorpus: librarySearchMetadataCorpus(
                        for: recordID
                    ),
                    pageCount: record.profile.pageCount,
                    hasAnalysis: record.brief != nil,
                    contentRevisionID: record.contentRevisionID
                )
            }
        return try await store.searchTextIndices(
            query: query,
            candidates: candidates
        )
    }

    private func valuePropagatingCancellation<Value>(
        from task: Task<Value, Error>
    ) async throws -> Value {
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return value
    }

    private func valuePropagatingExclusiveCancellation<Value>(
        from task: Task<Value, Error>,
        recordID: UUID,
        operationToken: UUID
    ) async throws -> Value {
        let value = try await valueCompletingAtomicExclusiveCommit(
            from: task,
            recordID: recordID,
            operationToken: operationToken
        )
        try ensureExclusiveDocumentOperationIsCurrent(
            recordID: recordID,
            token: operationToken
        )
        return value
    }

    private func valueCompletingAtomicExclusiveCommit<Value>(
        from task: Task<Value, Error>,
        recordID: UUID,
        operationToken: UUID
    ) async throws -> Value {
        do {
            try markExclusiveDocumentOperationBackgroundCancellable(
                recordID: recordID,
                token: operationToken
            )
        } catch {
            task.cancel()
            throw error
        }
        activeExclusiveDocumentWorkers[recordID] =
            ActiveExclusiveDocumentWorker(
                operationToken: operationToken,
                cancel: { task.cancel() }
            )
        defer {
            if activeExclusiveDocumentWorkers[recordID]?
                .operationToken == operationToken {
                activeExclusiveDocumentWorkers[recordID] = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func valuePropagatingExclusiveCancellation<Value>(
        from task: Task<Value, Error>,
        operationTokens: [UUID: UUID]
    ) async throws -> Value {
        let value = try await valueCompletingAtomicExclusiveCommit(
            from: task,
            operationTokens: operationTokens
        )
        for (recordID, token) in operationTokens {
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: token
            )
        }
        return value
    }

    private func valueCompletingAtomicExclusiveCommit<Value>(
        from task: Task<Value, Error>,
        operationTokens: [UUID: UUID]
    ) async throws -> Value {
        defer {
            for (recordID, token) in operationTokens
            where activeExclusiveDocumentWorkers[recordID]?
                .operationToken == token {
                activeExclusiveDocumentWorkers[recordID] = nil
            }
        }
        do {
            for (recordID, token) in operationTokens {
                try markExclusiveDocumentOperationBackgroundCancellable(
                    recordID: recordID,
                    token: token
                )
                activeExclusiveDocumentWorkers[recordID] =
                    ActiveExclusiveDocumentWorker(
                        operationToken: token,
                        cancel: { task.cancel() }
                    )
            }
        } catch {
            task.cancel()
            throw error
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func saveSignature(_ data: Data?) async {
        do {
            if let data {
                let library = try await signatureStore.add(data)
                applySignatureLibrary(library)
                noticeMessage = AppLocalization.format(
                    "Signature saved on this device · %d/5",
                    savedSignatures.count
                )
            } else {
                if let id = selectedSignatureID
                    ?? savedSignatures.first?.id {
                    let library = try await signatureStore.remove(id: id)
                    applySignatureLibrary(library)
                } else {
                    try await signatureStore.remove()
                    applySignatureLibrary(.empty)
                }
                noticeMessage = "Saved signature removed".localizedUI
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func selectSavedSignature(
        _ id: UUID,
        presentsFeedback: Bool = true
    ) async {
        do {
            let library = try await signatureStore.select(id)
            applySignatureLibrary(library)
            if presentsFeedback {
                noticeMessage = "Saved signature selected".localizedUI
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func removeSavedSignature(_ id: UUID) async {
        do {
            let library = try await signatureStore.remove(id: id)
            applySignatureLibrary(library)
            noticeMessage = "Saved signature removed".localizedUI
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    private func applySignatureLibrary(
        _ library: SavedSignatureLibrary
    ) {
        savedSignatures = library.entries
        selectedSignatureID = library.selectedID
        if let selectedID = library.selectedID,
           let entry = library.entries.first(where: { $0.id == selectedID }) {
            savedSignatureData = entry.data
        } else {
            savedSignatureData = library.entries.first?.data
        }
    }

    func importPDF(
        from url: URL,
        progressID: UUID = UUID()
    ) async -> DocumentRecord? {
        let importToken = beginImportOperation()
        beginForegroundImportProgress(
            progressID: progressID,
            totalItemCount: 1,
            firstURL: url
        )
        defer {
            finishForegroundImportProgress(progressID)
            finishImportOperation(importToken)
        }
        do {
            let record = try await importSinglePDF(
                from: url,
                analyzeAfterImport: false,
                preserveSourceLocation: true,
                progress: foregroundImportProgressHandler(
                    progressID: progressID,
                    itemIndex: 0,
                    totalItemCount: 1,
                    url: url
                )
            )
            noticeMessage = "Private copy imported".localizedUI
            resumeDeferredBackgroundWork()
            return record
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func importPDFs(
        from urls: [URL],
        progressID: UUID = UUID()
    ) async -> [DocumentRecord] {
        guard !urls.isEmpty else { return [] }
        let importToken = beginImportOperation()
        beginForegroundImportProgress(
            progressID: progressID,
            totalItemCount: urls.count,
            firstURL: urls[0]
        )
        defer {
            finishForegroundImportProgress(progressID)
            finishImportOperation(importToken)
        }

        var imported: [DocumentRecord] = []
        var failures: [Error] = []
        for (index, url) in urls.enumerated() {
            guard !Task.isCancelled else { break }
            do {
                imported.append(
                    try await importSinglePDF(
                        from: url,
                        analyzeAfterImport: false,
                        preserveSourceLocation: true,
                        progress: foregroundImportProgressHandler(
                            progressID: progressID,
                            itemIndex: index,
                            totalItemCount: urls.count,
                            url: url
                        )
                    )
                )
            } catch is CancellationError {
                break
            } catch {
                failures.append(error)
            }
        }
        if imported.isEmpty, let firstFailure = failures.first {
            present(firstFailure)
        } else if !failures.isEmpty {
            noticeMessage = AppLocalization.format(
                "%lld imported · %lld couldn’t be opened",
                imported.count,
                failures.count
            )
        } else if !imported.isEmpty {
            noticeMessage = AppLocalization.format(
                "%lld private cop%@ imported",
                imported.count,
                imported.count == 1 ? "y" : "ies"
            )
        }
        if !imported.isEmpty {
            resumeDeferredBackgroundWork()
        }
        return imported
    }

    func foregroundImportProgress(
        for progressID: UUID
    ) -> PDFOperationProgress? {
        foregroundImportProgresses[progressID]
    }

    func clearForegroundImportProgress(_ progressID: UUID) {
        activeForegroundImportProgressIDs.remove(progressID)
        foregroundImportRateWindows[progressID] = nil
        foregroundImportProgresses[progressID] = nil
    }

    func receiveExternalURL(
        _ url: URL,
        targetSceneID: UUID? = nil
    ) async {
        if url.isFileURL {
            await receiveExternalURLs(
                [url],
                targetSceneID: targetSceneID
            )
            return
        } else {
            guard url.scheme?.lowercased() == "paperpath" else { return }
            if url.host?.lowercased() == "settings" {
                requestSettingsPresentation(in: targetSceneID)
                return
            }
        }
        await processPendingExternalPDFs()
    }

    func receiveExternalURLs(
        _ urls: [URL],
        targetSceneID: UUID? = nil
    ) async {
        guard !urls.isEmpty,
              urls.allSatisfy({
                  $0.isFileURL
                      && $0.pathExtension.caseInsensitiveCompare("pdf")
                          == .orderedSame
              })
        else {
            present(ExternalPDFInboxError.invalidPDF)
            return
        }

        let overflowCount = enqueueExternalPDFURLs(
            urls,
            targetSceneID: targetSceneID
        )
        if overflowCount > 0 {
            noticeMessage =
                "The external import queue is full. Open queued PDFs before adding more."
                    .localizedUI
        }
        await processPendingExternalPDFs()
    }

    func processPendingExternalPDFs() async {
        guard didBootstrap, !Task.isCancelled else { return }
        if let existingTask = externalPDFImportTask {
            await existingTask.value
            if !Task.isCancelled,
               externalPDFImportTask == nil,
               !externalImportRetryAvailable || !queuedExternalPDFURLs.isEmpty {
                await processPendingExternalPDFs()
            }
            return
        }

        let generation = UUID()
        externalPDFImportGeneration = generation
        externalPDFDeferredOpenGeneration = generation
        externalImportRetryAvailable = false
        externalImportDeferredCount = 0
        externalImportRetryMessage = nil
        externalImportKnownTotalCount = 0
        externalImportCompletedItemCount = 0
        externalImportCurrentItemFraction = 0
        externalImportRateWindow.reset()
        externalImportProgress = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPendingExternalPDFImports(
                generation: generation
            )
            guard self.externalPDFImportGeneration == generation
            else { return }
            self.externalPDFImportGeneration = UUID()
            self.externalPDFDeferredOpenGeneration = nil
            self.externalPDFImportTask = nil
            self.externalImportProgress = nil
            self.externalImportKnownTotalCount = 0
            self.externalImportCompletedItemCount = 0
            self.externalImportCurrentItemFraction = 0
            self.externalImportRateWindow.reset()
            self.isExternalPDFImportActive = false
        }
        externalPDFImportTask = task
        isExternalPDFImportActive = true
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelExternalPDFImports() {
        guard externalPDFImportTask != nil else { return }
        externalPDFDeferredOpenGeneration = nil
        externalImportRetryAvailable = true
        externalPDFImportTask?.cancel()
    }

    func dismissExternalImportRetry() {
        externalImportRetryAvailable = false
    }

    private func offerExternalImportRetry(
        generation: UUID,
        error: Error? = nil
    ) {
        guard externalPDFImportGeneration == generation else { return }
        externalImportRetryAvailable = true
        if let error, externalImportRetryMessage == nil {
            switch error {
            case PaperPathError.insufficientStorage:
                externalImportRetryMessage =
                    ExternalPDFInboxError.insufficientStorage.errorDescription
            case PaperPathError.outputVerificationFailed:
                externalImportRetryMessage =
                    ExternalPDFInboxError.incompleteCopy.errorDescription
            default:
                externalImportRetryMessage =
                    ExternalPDFInbox.retryReason(for: error).errorDescription
            }
        }
    }

    private func runPendingExternalPDFImports(
        generation: UUID
    ) async {
        guard externalPDFImportGeneration == generation,
              !isProcessingExternalPDFs
        else { return }

        isProcessingExternalPDFs = true
        var importToken: UUID?
        defer {
            if let importToken {
                finishImportOperation(importToken)
            }
            activeExternalPDFURLIdentities.removeAll()
            isProcessingExternalPDFs = false
        }

        var imported: [DocumentRecord] = []
        var failures: [Error] = []
        var attemptedSharedContainers: Set<URL> = []
        var retryContainers: Set<URL> = []
        var queueInspectionInterrupted = false
        var shouldInspectSharedInbox = true
        var didInspectSharedInbox = false
        var completedItemCount = 0
        var totalItemCount = 0
        defer {
            for record in imported {
                completedExternalImportSceneIDs[record.id] = nil
            }
            if externalPDFImportGeneration == generation {
                externalImportDeferredCount =
                    retryContainers.count + queuedExternalPDFURLs.count
                externalImportRetryAvailable =
                    externalImportDeferredCount > 0
                        || queueInspectionInterrupted
                        || Task.isCancelled && !didInspectSharedInbox
                if !externalImportRetryAvailable {
                    externalImportRetryMessage = nil
                }
            }
        }

        while true {
            guard !Task.isCancelled else { break }
            let directURLs = queuedExternalPDFURLs
            queuedExternalPDFURLs.removeAll()
            let directURLIdentities = Set(
                directURLs.map(externalPDFURLIdentity)
            )
            activeExternalPDFURLIdentities.formUnion(
                directURLIdentities
            )
            let excludedContainers = attemptedSharedContainers
            let inspectsInbox = shouldInspectSharedInbox
            let inboxTask = Task.detached(priority: .utility) {
                guard inspectsInbox else {
                    return ExternalPDFInboxSnapshot(
                        items: [],
                        discardedInvalidItemCount: 0
                    )
                }
                return try ExternalPDFInbox.pendingSnapshot(
                    excludingContainers: excludedContainers
                )
            }
            let pendingItems: [ExternalPDFInboxItem]
            do {
                let snapshot = try await valuePropagatingCancellation(
                    from: inboxTask
                )
                pendingItems = snapshot.items
                didInspectSharedInbox = didInspectSharedInbox || inspectsInbox
                for deferred in snapshot.deferredItems
                where attemptedSharedContainers.insert(deferred.containerURL).inserted {
                    retryContainers.insert(deferred.containerURL)
                    failures.append(deferred.reason)
                    offerExternalImportRetry(
                        generation: generation,
                        error: deferred.reason
                    )
                }
                if snapshot.discardedInvalidItemCount > 0 {
                    failures.append(
                        contentsOf: Array(
                            repeating:
                                ExternalPDFInboxError.incompleteCopy,
                            count:
                                snapshot.discardedInvalidItemCount
                        )
                    )
                }
            } catch is CancellationError {
                queueInspectionInterrupted = true
                activeExternalPDFURLIdentities.subtract(
                    directURLIdentities
                )
                enqueueExternalPDFURLs(directURLs, atFront: true)
                return
            } catch ExternalPDFInboxError.sharedContainerUnavailable {
                // Passive inbox polling should not interrupt direct imports
                // when the extension container is unavailable.
                pendingItems = []
                shouldInspectSharedInbox = false
            } catch {
                failures.append(error)
                queueInspectionInterrupted = true
                shouldInspectSharedInbox = false
                offerExternalImportRetry(generation: generation, error: error)
                pendingItems = []
            }
            guard !Task.isCancelled else {
                retryContainers.formUnion(pendingItems.map(\.containerURL))
                activeExternalPDFURLIdentities.subtract(
                    directURLIdentities
                )
                enqueueExternalPDFURLs(directURLs, atFront: true)
                break
            }
            let sharedItems = pendingItems.filter {
                attemptedSharedContainers.insert($0.containerURL).inserted
            }
            retryContainers.formUnion(sharedItems.map(\.containerURL))
            guard !directURLs.isEmpty || !sharedItems.isEmpty else {
                if queuedExternalPDFURLs.isEmpty {
                    break
                }
                continue
            }
            if importToken == nil {
                importToken = beginImportOperation()
            }
            totalItemCount += directURLs.count + sharedItems.count

            for (offset, url) in directURLs.enumerated() {
                guard !Task.isCancelled else {
                    activeExternalPDFURLIdentities.subtract(
                        Set(
                            directURLs[offset...].map(
                                externalPDFURLIdentity
                            )
                        )
                    )
                    enqueueExternalPDFURLs(
                        Array(directURLs[offset...]),
                        atFront: true
                    )
                    break
                }
                let urlIdentity = externalPDFURLIdentity(url)
                let currentName = url.deletingPathExtension()
                    .lastPathComponent
                publishExternalImportProgress(
                    PDFImportProgressUpdate(
                        stage: .preparing,
                        fractionCompleted: 0
                    ),
                    generation: generation,
                    currentName: currentName,
                    completedItemCount: completedItemCount,
                    totalItemCount: totalItemCount
                )
                do {
                    let record = try await importSinglePDF(
                        from: url,
                        analyzeAfterImport: false,
                        preserveSourceLocation: true,
                        deferredOpenGeneration: generation,
                        progress: externalImportProgressHandler(
                            generation: generation,
                            currentName: currentName,
                            completedItemCount:
                                completedItemCount,
                            totalItemCount: totalItemCount
                        )
                    )
                    if let targetSceneID =
                            queuedExternalPDFTargetSceneIDs[urlIdentity] {
                        completedExternalImportSceneIDs[record.id] =
                            targetSceneID
                    }
                    queuedExternalPDFTargetSceneIDs[urlIdentity] = nil
                    imported.append(record)
                } catch is CancellationError {
                    let remainingURLs = Array(
                        directURLs[offset...]
                    ).filter {
                        !hasDeferredCommittedImport(from: $0)
                    }
                    activeExternalPDFURLIdentities.subtract(
                        Set(
                            directURLs[offset...].map(
                                externalPDFURLIdentity
                            )
                        )
                    )
                    enqueueExternalPDFURLs(
                        remainingURLs,
                        atFront: true
                    )
                    break
                } catch {
                    queuedExternalPDFTargetSceneIDs[urlIdentity] = nil
                    failures.append(error)
                }
                activeExternalPDFURLIdentities.remove(urlIdentity)
                completedItemCount += 1
            }

            for item in sharedItems {
                guard !Task.isCancelled else {
                    offerExternalImportRetry(generation: generation)
                    break
                }
                publishExternalImportProgress(
                    PDFImportProgressUpdate(
                        stage: .preparing,
                        fractionCompleted: 0
                    ),
                    generation: generation,
                    currentName: item.preferredName,
                    completedItemCount: completedItemCount,
                    totalItemCount: totalItemCount
                )
                if hasImportedSharedInboxItem(item.id) {
                    publishExternalImportProgress(
                        PDFImportProgressUpdate(
                            stage: .complete,
                            fractionCompleted: 1
                        ),
                        generation: generation,
                        currentName: item.preferredName,
                        completedItemCount: completedItemCount,
                        totalItemCount: totalItemCount
                    )
                    try? await Task.detached(priority: .utility) {
                        try ExternalPDFInbox.remove(item)
                    }.value
                    retryContainers.remove(item.containerURL)
                    completedItemCount += 1
                    continue
                }
                let claimedItem: ExternalPDFInboxItem
                do {
                    claimedItem = try await Task.detached(
                        priority: .utility
                    ) {
                        try ExternalPDFInbox.claim(item)
                    }.value
                    attemptedSharedContainers.insert(claimedItem.containerURL)
                } catch is CancellationError {
                    offerExternalImportRetry(generation: generation)
                    break
                } catch {
                    failures.append(error)
                    offerExternalImportRetry(generation: generation, error: error)
                    completedItemCount += 1
                    continue
                }
                do {
                    let record = try await importSinglePDF(
                        from: claimedItem.fileURL,
                        preferredName: claimedItem.preferredName,
                        analyzeAfterImport: false,
                        preserveSourceLocation: false,
                        expectedSHA256: claimedItem.expectedSHA256,
                        expectedByteCount: claimedItem.byteCount,
                        sharedImportID: claimedItem.id,
                        deferredOpenGeneration: generation,
                        progress: externalImportProgressHandler(
                            generation: generation,
                            currentName: claimedItem.preferredName,
                            completedItemCount: completedItemCount,
                            totalItemCount: totalItemCount
                        )
                    )
                    imported.append(record)
                    retryContainers.remove(item.containerURL)
                    try? await Task.detached(priority: .utility) {
                        try ExternalPDFInbox.complete(claimedItem)
                    }.value
                } catch is CancellationError {
                    let alreadyCommitted =
                        hasImportedSharedInboxItem(claimedItem.id)
                    if alreadyCommitted {
                        retryContainers.remove(item.containerURL)
                    }
                    try? await Task.detached(priority: .utility) {
                        if alreadyCommitted {
                            try ExternalPDFInbox.complete(claimedItem)
                        } else {
                            try ExternalPDFInbox.restore(claimedItem)
                        }
                    }.value
                    break
                } catch {
                    failures.append(error)
                    let shouldDiscard =
                        Self.shouldDiscardSharedInboxItem(after: error)
                    if !shouldDiscard {
                        offerExternalImportRetry(generation: generation, error: error)
                    } else {
                        retryContainers.remove(item.containerURL)
                    }
                    try? await Task.detached(priority: .utility) {
                        if shouldDiscard {
                            try ExternalPDFInbox.complete(claimedItem)
                        } else {
                            try ExternalPDFInbox.restore(claimedItem)
                        }
                    }.value
                }
                completedItemCount += 1
            }
        }

        guard !Task.isCancelled else { return }
        guard !imported.isEmpty || !failures.isEmpty else { return }
        if !imported.isEmpty {
            for record in imported {
                externalDocumentHandoffs.enqueue(
                    recordID: record.id,
                    targetSceneID:
                        completedExternalImportSceneIDs[record.id]
                )
            }
            resumeDeferredBackgroundWork()
        }

        if imported.isEmpty, let firstFailure = failures.first {
            if retryContainers.isEmpty && !queueInspectionInterrupted {
                present(firstFailure)
            }
        } else if !failures.isEmpty {
            noticeMessage = AppLocalization.format(
                "%lld imported · %lld need attention",
                imported.count,
                failures.count
            )
        } else {
            noticeMessage = AppLocalization.format(
                "%lld private cop%@ imported",
                imported.count,
                imported.count == 1 ? "y" : "ies"
            )
        }
    }

    func pendingExternalDocumentID(
        for sceneID: UUID
    ) -> UUID? {
        externalDocumentHandoffs.removeUnavailable(
            availableRecordIDs: Set(documentRecordsByID.keys)
        )
        return externalDocumentHandoffs.recordID(for: sceneID)
    }

    func clearPendingExternalDocument(_ recordID: UUID) {
        externalDocumentHandoffs.clear(recordID: recordID)
    }

    func releaseExternalDocumentTarget(for sceneID: UUID) {
        externalDocumentHandoffs.releaseTarget(for: sceneID)
        queuedExternalPDFTargetSceneIDs = queuedExternalPDFTargetSceneIDs
            .filter { $0.value != sceneID }
        deferredCommittedOpenSceneIDs = deferredCommittedOpenSceneIDs
            .filter { $0.value != sceneID }
        completedExternalImportSceneIDs = completedExternalImportSceneIDs
            .filter { $0.value != sceneID }
    }

    func createPaperTemplate(
        kind: PaperTemplateKind,
        size: PaperTemplateSize,
        pageCount: Int,
        title: String
    ) async -> DocumentRecord? {
        let importToken = beginImportOperation()
        defer { finishImportOperation(importToken) }

        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = normalizedTitle.isEmpty
            ? AppLocalization.format(
                "%@ Paper",
                kind.title.localizedUI
            )
            : String(normalizedTitle.prefix(80))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-DocumentExport-\(UUID().uuidString)",
                isDirectory: true
            )
        let temporaryURL = temporaryDirectory
            .appendingPathComponent("template.pdf")
        defer {
            PaperPathTemporaryArtifact.removeManagedItem(
                containing: temporaryDirectory,
                allowedPrefixes: ["PaperPath-DocumentExport-"]
            )
        }

        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: temporaryDirectory
            )
            let renderer = PaperTemplateRenderer()
            let renderTask = Task.detached(priority: .userInitiated) {
                try renderer.render(
                    kind: kind,
                    size: size,
                    pageCount: pageCount,
                    title: finalTitle,
                    to: temporaryURL
                )
            }
            try await valuePropagatingCancellation(from: renderTask)
            try Task.checkCancellation()
            let record = try await importSinglePDF(
                from: temporaryURL,
                preferredName: finalTitle,
                analyzeAfterImport: true,
                preserveSourceLocation: false
            )
            noticeMessage = AppLocalization.format(
                "%@ PDF created on this device",
                kind.title.localizedUI
            )
            return record
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createSampleWorkspace() async -> UUID? {
        if let existing = workingDocuments.first {
            return existing.id
        }
        let importToken = beginImportOperation()
        defer { finishImportOperation(importToken) }
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-DocumentExport-"
        )
        let temporaryURL = temporaryArtifact.fileURL
        defer { temporaryArtifact.remove() }
        do {
            try temporaryArtifact.prepare()
            let renderTask = Task.detached(priority: .userInitiated) {
                try DemoPDFBuilder.create(at: temporaryURL)
            }
            try await valuePropagatingCancellation(from: renderTask)
            try Task.checkCancellation()
            let record = try await importSinglePDF(
                from: temporaryURL,
                preferredName: "Project handoff sample",
                preserveSourceLocation: false
            )
            noticeMessage = "Local sample created".localizedUI
            return record.id
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func duplicate(recordID: UUID) async -> DocumentRecord? {
        await ensureAnalysisLoaded(for: recordID)
        guard !Task.isCancelled else { return nil }
        guard let source = record(id: recordID) else { return nil }
        let importToken = beginImportOperation()
        defer { finishImportOperation(importToken) }

        do {
            var duplicated = try await store.duplicate(source)
            documentURLs[duplicated.id] = await store.url(
                for: duplicated
            )

            if let brief = source.brief,
               let textIndex = textIndices[source.id],
               let analyzed = try? await store.saveAnalysis(
                    duplicated,
                    brief: brief,
                    textIndex: textIndex,
                    ocrResult: ocrResults[source.id]
               ) {
                duplicated = analyzed
                textIndices[duplicated.id] = textIndex
                touchResidentAnalysis(duplicated.id)
                trimResidentAnalysisCache()
                if let ocrResult = ocrResults[source.id] {
                    setOCRResult(
                        ocrResult,
                        for: duplicated.id
                    )
                }
            }

            replace(duplicated)
            noticeMessage = "Independent working copy created".localizedUI
            return duplicated
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func importScan(
        images: [UIImage],
        options: ScanProcessingOptions = .document
    ) async -> DocumentRecord? {
        await importScan(
            pages: images.map {
                ScanPageImage(
                    image: $0,
                    processingOptions: options
                )
            }
        )
    }

    func importScan(
        pages: [ScanPageImage],
        progressID: UUID = UUID(),
        onCommit: (DocumentRecord) -> Void = { _ in }
    ) async -> DocumentRecord? {
        return await importImagePages(
            pages,
            options: .document,
            preferredName: AppLocalization.datedDocumentName(
                "Scan · %@"
            ),
            successMessage: "Scan saved on device",
            progressID: progressID,
            onCommit: onCommit
        )
    }

    func importImages(_ images: [UIImage]) async -> DocumentRecord? {
        await importImages(
            pages: images.map {
                ScanPageImage(
                    image: $0,
                    processingOptions: .original
                )
            }
        )
    }

    func importImages(
        pages: [ScanPageImage],
        progressID: UUID = UUID(),
        onCommit: (DocumentRecord) -> Void = { _ in }
    ) async -> DocumentRecord? {
        await importImagePages(
            pages,
            options: .original,
            preferredName: AppLocalization.datedDocumentName(
                "Images · %@"
            ),
            successMessage: "Image PDF created on device",
            progressID: progressID,
            onCommit: onCommit
        )
    }

    func scanImportFraction(for progressID: UUID) -> Double? {
        scanImportProgresses[progressID]
    }

    private func importImagePages(
        _ pages: [ScanPageImage],
        options: ScanProcessingOptions,
        preferredName: String,
        successMessage: String,
        progressID: UUID,
        onCommit: (DocumentRecord) -> Void
    ) async -> DocumentRecord? {
        let generation = UUID()
        scanRenderTasks[progressID]?.cancel()
        scanImportGenerations[progressID] = generation
        let importToken = beginImportOperation()
        scanImportProgresses[progressID] = 0
        defer {
            finishImportOperation(importToken)
            if scanImportGenerations[progressID] == generation {
                scanRenderTasks[progressID] = nil
                scanImportProgresses[progressID] = nil
                scanImportGenerations[progressID] = nil
            }
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "UITEST_DELAY_SCAN_CREATION"
        ) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return nil }
        }
#endif
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-DocumentExport-\(UUID().uuidString)",
                isDirectory: true
            )

        let temporaryURL = temporaryDirectory
            .appendingPathComponent("scan.pdf")
        defer {
            PaperPathTemporaryArtifact.removeManagedItem(
                containing: temporaryDirectory,
                allowedPrefixes: ["PaperPath-DocumentExport-"]
            )
        }

        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: temporaryDirectory
            )
            let renderer = scanRenderer
            let renderTask = Task.detached(priority: .userInitiated) {
                try renderer.render(
                    pages: pages,
                    to: temporaryURL,
                    options: options
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.scanImportGenerations[progressID]
                                == generation
                        else { return }
                        self.scanImportProgresses[progressID] = max(
                            self.scanImportProgresses[progressID] ?? 0,
                            min(1, max(0, value))
                        )
                    }
                }
            }
            scanRenderTasks[progressID] = renderTask
            try await valuePropagatingCancellation(from: renderTask)
            try Task.checkCancellation()
            guard scanImportGenerations[progressID] == generation else {
                throw CancellationError()
            }
            let record = try await store.importPDF(
                from: temporaryURL,
                preferredName: preferredName
            )
            onCommit(record)
            guard !Task.isCancelled,
                  scanImportGenerations[progressID] == generation
            else {
                deferredCommittedImports[record.id] = record
                return await restoreCommittedImportIfForeground(
                    record
                )
            }
            replace(record)
            documentURLs[record.id] = await store.url(for: record)
            noticeMessage = successMessage.localizedUI
            resumeDeferredBackgroundWork()
            return self.record(id: record.id)
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    private var canRestoreCommittedImportsInForeground: Bool {
        !isErasingAllLocalData
            && UIApplication.shared.applicationState == .active
            && UIApplication.shared.isProtectedDataAvailable
    }

    func restoreCommittedImportsForForeground() async {
        if let committedImportRestoreTask {
            await committedImportRestoreTask.value
        }
        guard committedImportRestoreTask == nil,
              canRestoreCommittedImportsInForeground,
              !deferredCommittedImports.isEmpty
        else { return }
        let generation = UUID()
        committedImportRestoreGeneration = generation
        let task = Task { @MainActor [weak self] in
            await self?.performCommittedImportRestore()
            guard let self,
                  self.committedImportRestoreGeneration == generation
            else { return }
            self.committedImportRestoreTask = nil
        }
        committedImportRestoreTask = task
        await task.value
    }

    private func restoreCommittedImportIfForeground(
        _ committed: DocumentRecord
    ) async -> DocumentRecord? {
        guard canRestoreCommittedImportsInForeground else { return nil }
        let resolvedURL = await store.url(for: committed)
        guard canRestoreCommittedImportsInForeground else { return nil }
        deferredCommittedImports[committed.id] = nil
        deferredCommittedImportSourceIdentities[committed.id] = nil
        deferredCommittedOpenSceneIDs[committed.id] = nil
        deferredCommittedOpenRecordIDs.removeAll {
            $0 == committed.id
        }
        replace(committed)
        documentURLs[committed.id] = resolvedURL
        resumeDeferredBackgroundWork()
        return record(id: committed.id) ?? committed
    }

    private func performCommittedImportRestore() async {
        guard canRestoreCommittedImportsInForeground else { return }
        var restoredCount = 0
        var pendingExternalOpenID: UUID?
        var pendingExternalOpenSceneID: UUID?
        while !deferredCommittedImports.isEmpty {
            guard !Task.isCancelled,
                  canRestoreCommittedImportsInForeground
            else { return }
            let pending = Array(deferredCommittedImports.values)
            let pendingIDs = Set(pending.map(\.id))
            if pendingExternalOpenID == nil {
                pendingExternalOpenID =
                    deferredCommittedOpenRecordIDs.first {
                        pendingIDs.contains($0)
                    }
                if let pendingExternalOpenID {
                    pendingExternalOpenSceneID =
                        deferredCommittedOpenSceneIDs[
                            pendingExternalOpenID
                        ]
                }
            }
            var resolvedURLs: [UUID: URL] = [:]
            resolvedURLs.reserveCapacity(pending.count)
            for record in pending {
                guard !Task.isCancelled,
                      canRestoreCommittedImportsInForeground
                else { return }
                resolvedURLs[record.id] = await store.url(for: record)
            }
            guard !Task.isCancelled,
                  canRestoreCommittedImportsInForeground
            else { return }
            replace(pending)
            documentURLs.merge(resolvedURLs) { _, latest in latest }
            for record in pending {
                deferredCommittedImports[record.id] = nil
                deferredCommittedImportSourceIdentities[record.id] = nil
                deferredCommittedOpenSceneIDs[record.id] = nil
            }
            deferredCommittedOpenRecordIDs.removeAll {
                pendingIDs.contains($0)
            }
            restoredCount += pending.count
        }
        if let pendingExternalOpenID {
            externalDocumentHandoffs.enqueue(
                recordID: pendingExternalOpenID,
                targetSceneID: pendingExternalOpenSceneID
            )
        }
        noticeMessage = AppLocalization.format(
            "%lld private cop%@ restored after interruption",
            restoredCount,
            restoredCount == 1 ? "y" : "ies"
        )
        resumeDeferredBackgroundWork()
    }

    @discardableResult
    func rename(
        recordID: UUID,
        to name: String,
        expectedName: String
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        guard record.displayName == expectedName else {
            noticeMessage =
                "The document name changed in another window. Review it and try again."
                    .localizedUI
            return false
        }
        do {
            let updated = try await store.rename(
                record,
                to: name,
                expectedName: expectedName
            )
            if replaceMetadataRecordIfCurrent(updated) {
                noticeMessage = "Name updated".localizedUI
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updateWorkflow(
        recordID: UUID,
        status: DocumentWorkflowStatus
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        do {
            let updated = try await store.updateWorkflow(record, status: status)
            if replaceMetadataRecordIfCurrent(updated) {
                noticeMessage = AppLocalization.format(
                    "Moved to %@",
                    status.title.localizedUI
                )
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func togglePinned(
        recordID: UUID,
        expectedIsPinned: Bool
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        guard record.isPinned == expectedIsPinned else {
            noticeMessage =
                "The pin state changed in another window. Review it and try again."
                    .localizedUI
            return false
        }
        do {
            let updated = try await store.togglePinned(
                record,
                expectedIsPinned: expectedIsPinned
            )
            if replaceMetadataRecordIfCurrent(updated) {
                noticeMessage = updated.isPinned ? "Pinned" : "Unpinned"
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func setPinned(
        recordIDs: Set<UUID>,
        isPinned: Bool
    ) async -> Bool {
        let records = documents.filter {
            recordIDs.contains($0.id) && $0.isPinned != isPinned
        }
        guard !records.isEmpty else { return true }

        do {
            let updated = try await store.setPinned(
                recordIDs: Set(records.map(\.id)),
                isPinned: isPinned
            )
            let appliedCount =
                replaceMetadataRecordsIfCurrent(updated)
            if appliedCount > 0 {
                noticeMessage = AppLocalization.format(
                    isPinned
                        ? "%lld private copies pinned"
                        : "%lld private copies unpinned",
                    appliedCount
                )
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updateWorkflow(
        recordIDs: Set<UUID>,
        status: DocumentWorkflowStatus
    ) async -> Bool {
        let records = documents.filter {
            recordIDs.contains($0.id)
                && $0.workflowStatus != status
        }
        guard !records.isEmpty else { return true }

        do {
            let updated = try await store.updateWorkflow(
                recordIDs: Set(records.map(\.id)),
                status: status
            )
            let appliedCount =
                replaceMetadataRecordsIfCurrent(updated)
            if appliedCount > 0 {
                noticeMessage = AppLocalization.format(
                    "%lld private copies moved to %@",
                    appliedCount,
                    status.title.localizedUI
                )
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updateTags(
        recordID: UUID,
        tags: [String],
        expectedTags: [String]
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        guard record.tags == expectedTags else {
            noticeMessage =
                "The tags changed in another window. Review them and try again."
                    .localizedUI
            return false
        }
        do {
            let updated = try await store.updateTags(
                record,
                tags: tags,
                expectedTags: expectedTags
            )
            if replaceMetadataRecordIfCurrent(updated) {
                noticeMessage = "Tags updated".localizedUI
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updateTags(
        recordIDs: Set<UUID>,
        adding tagsToAdd: [String] = [],
        removing tagsToRemove: [String] = []
    ) async -> Bool {
        guard !recordIDs.isEmpty else { return false }

        do {
            let updated = try await store.updateTags(
                recordIDs: recordIDs,
                adding: tagsToAdd,
                removing: tagsToRemove
            )
            let appliedCount =
                replaceMetadataRecordsIfCurrent(updated)
            if appliedCount > 0 {
                noticeMessage = AppLocalization.format(
                    "%lld private copies updated",
                    appliedCount
                )
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updateDueDate(
        recordID: UUID,
        dueAt: Date?,
        expectedDueAt: Date?
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        let calendar = Calendar.current
        let currentDueAt = record.dueAt.map {
            calendar.startOfDay(for: $0)
        }
        let normalizedExpected = expectedDueAt.map {
            calendar.startOfDay(for: $0)
        }
        guard currentDueAt == normalizedExpected else {
            noticeMessage =
                "The due date changed in another window. Review it and try again."
                    .localizedUI
            return false
        }
        do {
            let updated = try await store.updateDueDate(
                record,
                dueAt: dueAt,
                expectedDueAt: normalizedExpected
            )
            let applied =
                replaceMetadataRecordIfCurrent(updated)
            let effectiveDueDate = self.record(id: recordID)?.dueAt
            let reminderUpdated = await LocalDueReminderScheduler.update(
                recordID: recordID,
                dueAt: effectiveDueDate
            )
            if applied,
               dueAt != nil,
               UserDefaults.standard.bool(
                   forKey: AppPreferences.dueRemindersEnabledKey
               ),
               !reminderUpdated {
                noticeMessage =
                    "Due date saved, but its reminder could not be scheduled."
                        .localizedUI
            } else if applied {
                noticeMessage = dueAt == nil
                    ? "Due date removed".localizedUI
                    : "Due date updated".localizedUI
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func updatePrivateNote(
        recordID: UUID,
        note: String?,
        expectedNote: String?
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        let normalizedExpected = expectedNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedExpected: String? =
            if let normalizedExpected, !normalizedExpected.isEmpty {
                String(normalizedExpected.prefix(1_000))
            } else {
                nil
            }
        guard record.privateNote == boundedExpected else {
            noticeMessage =
                "The private note changed in another window. Review it and try again."
                    .localizedUI
            return false
        }
        do {
            let updated = try await store.updatePrivateNote(
                record,
                note: note,
                expectedNote: boundedExpected
            )
            if replaceMetadataRecordIfCurrent(updated) {
                noticeMessage = updated.privateNote == nil
                    ? "Private note removed".localizedUI
                    : "Private note saved on this device".localizedUI
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func recordOfficeExportReceipt(
        recordID: UUID,
        receipt: PDFOfficeExportReceipt
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.recordOfficeExportReceipt(
                receipt,
                for: record
            )
            synchronizeCommittedOfficeReceipts(updated, expectedRecord: record)
        } catch {
            // Office export remains usable if local receipt history fails.
        }
    }

    func retainOfficeExport(
        recordID: UUID,
        receipt: PDFOfficeExportReceipt,
        sourceURL: URL,
        expectedContentRevisionID: UUID? = nil
    ) async -> (
        receipt: PDFOfficeExportReceipt,
        url: URL
    )? {
        guard let record = record(id: recordID) else {
            return nil
        }
        let requestedRevision = expectedContentRevisionID
            ?? receipt.sourceRevisionID ?? record.contentRevisionID
        guard requestedRevision == record.contentRevisionID else { return nil }
        var boundReceipt = receipt
        boundReceipt.sourceRevisionID = requestedRevision
        do {
            let retained = try await store.retainOfficeExport(
                boundReceipt,
                sourceURL: sourceURL,
                for: record
            )
            synchronizeCommittedOfficeReceipts(retained.record, expectedRecord: record)
            await discardTemporaryExportCopies(at: [sourceURL])
            return (
                receipt: retained.receipt,
                url: retained.url
            )
        } catch {
            await recordOfficeExportReceipt(
                recordID: recordID,
                receipt: boundReceipt
            )
            return nil
        }
    }

    private func synchronizeCommittedOfficeReceipts(
        _ updated: DocumentRecord,
        expectedRecord: DocumentRecord
    ) {
        if replaceMetadataRecordIfCurrent(updated, schedulesMetadataSync: false) {
            return
        }
        guard var resident = record(id: updated.id),
              resident.contentRevisionID == updated.contentRevisionID,
              resident.officeReceipts == expectedRecord.officeReceipts
        else { return }
        resident.officeReceipts = updated.officeReceipts
        resident.modifiedAt = max(resident.modifiedAt, updated.modifiedAt)
        replace(
            resident,
            schedulesMetadataSync: false,
            invalidatesSearchText: false
        )
    }

    func prepareReusableOfficeExportShareCopy(
        recordID: UUID,
        receiptID: UUID,
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void = { _ in }
    ) async -> URL? {
        guard let operationToken = acquireExclusiveDocumentOperation(
            recordID: recordID
        ) else {
            return nil
        }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        guard let record = record(id: recordID),
              let receipt = record.officeReceipts.first(
                  where: { $0.id == receiptID }
              )
        else { return nil }
        let requestedRevision = record.contentRevisionID
        let destination = officeShareDestinationURL(
            for: receipt
        )
        do {
            try Task.checkCancellation()
            let prepared = try await store
                .prepareOfficeExportShareCopy(
                receiptID: receiptID,
                for: record,
                destinationURL: destination
            ) { update in
                Task { @MainActor in
                    progress(update)
                }
            }
            replace(
                prepared.record,
                schedulesMetadataSync: false
            )
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == requestedRevision
            else {
                await discardTemporaryExportCopies(
                    at: [destination]
                )
                throw PaperPathError.outputVerificationFailed(
                    "the source PDF changed while its Office share copy was prepared"
                )
            }
            return prepared.url
        } catch is CancellationError {
            await discardTemporaryExportCopies(at: [destination])
            return nil
        } catch {
            await discardTemporaryExportCopies(at: [destination])
            guard !Task.isCancelled else { return nil }
            await refreshOfficeBatchArtifactState(recordID: recordID)
            present(error)
            return nil
        }
    }

    func prepareReusableOfficeExportShareCopies(
        recordID: UUID,
        receiptIDs: [UUID],
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void = { _ in }
    ) async -> [URL]? {
        guard !receiptIDs.isEmpty,
              Set(receiptIDs).count == receiptIDs.count,
              let operationToken = acquireExclusiveDocumentOperation(
                  recordID: recordID
              )
        else { return nil }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        guard var currentRecord = record(id: recordID) else {
            return nil
        }
        let requestedRevision = currentRecord.contentRevisionID
        let receiptsByID = Dictionary(
            currentRecord.officeReceipts.map {
                ($0.id, $0)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        let receipts = receiptIDs.compactMap { receiptsByID[$0] }
        guard receipts.count == receiptIDs.count,
              receipts.allSatisfy({ $0.fileSizeBytes > 0 })
        else { return nil }
        let totalWorkBytes = receipts.reduce(Int64.zero) {
            total,
            receipt in
            saturatedByteTotal(
                [
                    total,
                    receipt.fileSizeBytes,
                    receipt.fileSizeBytes,
                    receipt.fileSizeBytes
                ]
            )
        }
        let totalUnitCount = receipts.count * 3
        var preparedURLs: [URL] = []
        preparedURLs.reserveCapacity(receipts.count)
        var completedWorkBytes = Int64.zero
        do {
            for (index, receipt) in receipts.enumerated() {
                try Task.checkCancellation()
                let destination = officeShareDestinationURL(
                    for: receipt
                )
                let completedBeforeCurrent = completedWorkBytes
                let prepared = try await store
                    .prepareOfficeExportShareCopy(
                        receiptID: receipt.id,
                        for: currentRecord,
                        destinationURL: destination
                    ) { update in
                        let currentProcessed = min(
                            max(0, update.totalBytes),
                            max(0, update.processedBytes)
                        )
                        let (sum, overflow) =
                            completedBeforeCurrent
                                .addingReportingOverflow(
                                    currentProcessed
                                )
                        let cumulativeProcessed =
                            overflow ? Int64.max : sum
                        let cumulativeUpdate =
                            PDFByteProgressUpdate(
                                stage: update.stage,
                                processedBytes: min(
                                    totalWorkBytes,
                                    cumulativeProcessed
                                ),
                                totalBytes: totalWorkBytes,
                                completedUnitCount: min(
                                    totalUnitCount,
                                    index * 3
                                        + update.completedUnitCount
                                ),
                                totalUnitCount: totalUnitCount,
                                currentUnitName:
                                    update.currentUnitName
                            )
                        Task { @MainActor in
                            progress(cumulativeUpdate)
                        }
                    }
                replace(
                    prepared.record,
                    schedulesMetadataSync: false
                )
                currentRecord = prepared.record
                preparedURLs.append(prepared.url)
                completedWorkBytes = saturatedByteTotal(
                    [
                        completedWorkBytes,
                        receipt.fileSizeBytes,
                        receipt.fileSizeBytes,
                        receipt.fileSizeBytes
                    ]
                )
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == requestedRevision
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the source PDF changed while its Office share copies were prepared"
                )
            }
            return preparedURLs
        } catch is CancellationError {
            await discardTemporaryExportCopies(at: preparedURLs)
            return nil
        } catch {
            await discardTemporaryExportCopies(at: preparedURLs)
            guard !Task.isCancelled else { return nil }
            await refreshOfficeBatchArtifactState(recordID: recordID)
            present(error)
            return nil
        }
    }

    var pinnedOfficeOutputs: [PDFPinnedOfficeOutput] {
        pinnedOfficeOutputCache
    }

    var pinnedOfficeStorageSummary: PDFOfficePinnedStorageSummary {
        pinnedOfficeStorageSummaryCache
    }

    func setOfficeExportPinned(
        recordID: UUID,
        receiptID: UUID,
        pinned: Bool
    ) async {
        guard let operationToken = acquireExclusiveDocumentOperation(
            recordID: recordID
        ) else { return }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        guard let record = record(id: recordID) else { return }
        do {
            try Task.checkCancellation()
            if pinned,
               let receipt = record.officeReceipts.first(
                    where: { $0.id == receiptID }
               ),
               !receipt.isPinned,
               !pinnedOfficeStorageSummary.canAdd(
                    bytes: receipt.fileSizeBytes
               ) {
                throw PaperPathError.insufficientSelection(
                    "Keep up to 24 pinned Office outputs and 2 GB across the library."
                )
            }
            let updated = try await store.setOfficeExportPinned(
                receiptID: receiptID,
                pinned: pinned,
                for: record
            )
            replace(updated, schedulesMetadataSync: false)
            try Task.checkCancellation()
            noticeMessage = pinned
                ? "Office output pinned on this device".localizedUI
                : "Office output returns to seven-day retention".localizedUI
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func unpinAllOfficeExports() async {
        let unpinnedCount = pinnedOfficeOutputs.count
        guard unpinnedCount > 0 else { return }
        do {
            try Task.checkCancellation()
            let updatedRecords = try await store
                .unpinAllOfficeExports()
            replace(
                updatedRecords,
                schedulesMetadataSync: false
            )
            guard !Task.isCancelled else { return }
            noticeMessage = AppLocalization.format(
                "%lld Office output%@ returned to standard retention",
                unpinnedCount,
                unpinnedCount == 1 ? "" : "s"
            )
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func makeOfficeBatchArchive(
        recordID: UUID,
        batchID: UUID
    ) async throws -> (archive: URL, report: URL) {
        let operationToken = try beginExclusiveDocumentOperation(
            recordID: recordID
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        guard let record = record(id: recordID),
              let run = officeBatchRuns[recordID],
              run.id == batchID,
              run.plan.sourceRevisionID == record.contentRevisionID
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office batch no longer matches the source"
            )
        }

        let receiptIDs = Set(run.segments.compactMap(\.receiptID))
        let receipts = record.officeReceipts
            .filter { receiptIDs.contains($0.id) }
            .sorted {
                ($0.batchSegmentIndex ?? 0)
                    < ($1.batchSegmentIndex ?? 0)
            }
        guard !receipts.isEmpty,
              receipts.count == run.completedCount
        else {
            throw PaperPathError.insufficientSelection(
                "Not every completed Office batch part is available."
            )
        }

        var retainedSources: [OfficeBatchArchiveSource] = []
        var deliveryEntries: [PDFOfficeDeliveryEntry] = []
        var currentRecord = record
        for receipt in receipts {
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            )
            let store = self.store
            let recordToVerify = currentRecord
            let verificationTask = Task {
                try await store.verifyOfficeExport(
                    receiptID: receipt.id,
                    for: recordToVerify
                )
            }
            let verification =
                try await valueCompletingAtomicExclusiveCommit(
                    from: verificationTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            replace(
                verification.record,
                schedulesMetadataSync: false
            )
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            )
            currentRecord = verification.record
            guard verification.status.isVerified,
                  let url = verification.url
            else {
                throw PaperPathError.outputVerificationFailed(
                    AppLocalization.format(
                        "Office batch part %lld failed: %@",
                        receipt.batchSegmentIndex.map { $0 + 1 } ?? 1,
                        verification.status.title.localizedUI
                    )
                )
            }
            let verifiedReceipt = verification.receipt
            let partNumber =
                (verifiedReceipt.batchSegmentIndex ?? 0) + 1
            let startPage =
                (verifiedReceipt.sourcePageStartIndex ?? 0) + 1
            let endPage =
                (verifiedReceipt.sourcePageEndIndex ?? 0) + 1
            let archiveName = String(
                format:
                    "%02d-part-%02d-pages-%d-%d.%@",
                partNumber,
                partNumber,
                startPage,
                endPage,
                verifiedReceipt.format.fileExtension
            )
            retainedSources.append(
                OfficeBatchArchiveSource(
                    sourceURL: url,
                    archiveName: archiveName
                )
            )
            deliveryEntries.append(
                PDFOfficeDeliveryEntry(
                    sourceRecordID: currentRecord.id,
                    sourceRevisionID:
                        run.plan.sourceRevisionID,
                    sourceName: currentRecord.displayName,
                    receiptID: verifiedReceipt.id,
                    format: verifiedReceipt.format,
                    archiveName: archiveName,
                    byteCount: verifiedReceipt.fileSizeBytes,
                    sha256:
                        verifiedReceipt.artifactSHA256
                            ?? "unavailable"
                )
            )
        }
        guard !retainedSources.isEmpty,
              deliveryEntries.count == retainedSources.count
        else {
            throw PaperPathError.insufficientSelection(
                "The retained Office batch parts are no longer available."
            )
        }
        let signedArchiveWorkingBytes = saturatedByteTotal(
            deliveryEntries.lazy.map(\.byteCount),
            reserve: 16 * 1_024 * 1_024
        )
        guard signedArchiveWorkingBytes
                <= 1_024 * 1_024 * 1_024
        else {
            throw PaperPathError.fileTooLarge
        }
        await refreshOfficeResourceSnapshot()
        if let available =
            officeResourceSnapshot.availableCapacityBytes,
           available < signedArchiveWorkingBytes {
            throw PaperPathError.insufficientStorage
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Office-Batch-\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory
        )
        let reportURL = directory.appendingPathComponent(
            "\(safeExportName(record.displayName))-\(run.id.uuidString.prefix(8))-verification.json"
        )
        let archiveKind =
            run.completedCount == run.segments.count
                ? "signed-batch"
                : "signed-partial-batch"
        let destination = directory.appendingPathComponent(
            "\(safeExportName(record.displayName))-\(run.plan.format.fileExtension)-\(archiveKind).zip"
        )
        do {
            let store = self.store
            let evidenceDateTask = Task {
                try await store.trustedEvidenceIssuanceDate()
            }
            let packageCreatedAt =
                try await valuePropagatingExclusiveCancellation(
                    from: evidenceDateTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            let package = PDFOfficeDeliveryPackage(
                id: run.id,
                createdAt: packageCreatedAt,
                entries: deliveryEntries
            )
            let payload = PDFOfficeVerificationPayload(
                schema: "PaperPath Office Delivery V34",
                packageID: package.id,
                createdAt: package.createdAt,
                expiresAt: package.expiresAt,
                verifiedOutputs: deliveryEntries.count,
                files: deliveryEntries
            )
            guard payload.isStructurallyValid(at: packageCreatedAt)
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the signed Office batch identity is invalid"
                )
            }
            let signingTask = Task {
                try await store.signOfficeDeliveryPayload(payload)
            }
            let signedReport =
                try await valuePropagatingExclusiveCancellation(
                    from: signingTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            officeDeliverySigningKeyID =
                signedReport.signature.keyID
            let reportEncoder = JSONEncoder()
            reportEncoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys
            ]
            reportEncoder.dateEncodingStrategy = .iso8601
            let manifestData = try reportEncoder.encode(
                signedReport
            )
            try manifestData.write(to: reportURL, options: .atomic)
            try LocalFileSecurity.requireCompleteProtection(
                to: reportURL
            )
            LocalFileSecurity.excludeFromBackup(reportURL)
            retainedSources.append(
                OfficeBatchArchiveSource(
                    sourceURL: reportURL,
                    archiveName:
                        "PaperPath-delivery-manifest.json"
                )
            )

            let archiveSources = retainedSources
            let operationLabel = "Packaging Office batch"
            operationProgress[recordID] = PDFOperationProgress(
                label: operationLabel,
                fractionCompleted: 0
            )
            operationRateWindows[recordID] = ByteRateWindow()
            defer {
                if operationProgress[recordID]?.label
                    == operationLabel {
                    operationProgress[recordID] = nil
                    operationRateWindows[recordID] = nil
                }
            }
            let archiveTask = Task.detached(priority: .userInitiated) {
                try OfficeBatchArchiveService().createArchive(
                    sources: archiveSources,
                    destination: destination,
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.publishOperationByteProgress(
                                recordID: recordID,
                                label: operationLabel,
                                update: update
                            )
                        }
                    }
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: archiveTask,
                recordID: recordID,
                operationToken: operationToken
            )
            try await verifyCreatedOfficeDeliveryArchive(
                at: destination,
                expectedReport: signedReport,
                progress: { update in
                    Task { @MainActor [weak self] in
                        self?.publishOperationByteProgress(
                            recordID: recordID,
                            label: operationLabel,
                            update: update
                        )
                    }
                }
            )
            try LocalFileSecurity.requireCompleteProtection(
                to: destination
            )
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            )
            noticeMessage =
                "Signed Office batch and verification report ready"
                    .localizedUI
            return (destination, reportURL)
        } catch {
            await discardTemporaryExportCopies(at: [directory])
            throw error
        }
    }

    @discardableResult
    func enqueueOfficeProduction(
        recordIDs: Set<UUID>,
        format requestedFormat: PDFTextExportFormat? = nil,
        priority: PDFOfficeQueuePriority = .normal
    ) async -> Bool {
        await refreshOfficeResourceSnapshot()
        let forecast = officeProductionForecast(
            recordIDs: recordIDs,
            format: requestedFormat
        )
        guard forecast.hasCapacity else {
            noticeMessage = AppLocalization.format(
                "Office production needs %@ of working space.",
                forecast.formattedWorkingBytes
            )
            return false
        }
        let selected = documents
            .filter {
                recordIDs.contains($0.id)
                    && $0.isWorkingCopy
                    && PDFQuickTask.exportText.supports($0)
            }
            .sorted { $0.displayName < $1.displayName }
        guard !selected.isEmpty else {
            noticeMessage =
                "Choose at least one unlocked PDF for Office production."
            return false
        }

        var addedCount = 0
        for record in selected {
            let portfolio = PDFOfficeExportPortfolio(
                profile: record.profile
            )
            let format = requestedFormat
                ?? portfolio.recommendedPlan?.format
                ?? .wordDocument
            guard format.isOfficeFormat else { continue }
            let alreadyQueued = officeProductionQueue.jobs.contains {
                $0.recordID == record.id
                    && $0.sourceRevisionID == record.contentRevisionID
                    && $0.format == format
                    && !$0.stage.isTerminal
            }
            guard !alreadyQueued else { continue }
            officeProductionQueue.jobs.append(
                PDFOfficeQueueJob(
                    recordID: record.id,
                    sourceRevisionID: record.contentRevisionID,
                    sourceName: record.displayName,
                    sourcePageCount: record.profile.pageCount,
                    format: format,
                    priority: priority
                )
            )
            addedCount += 1
        }

        guard addedCount > 0 else {
            noticeMessage =
                "Those PDFs are already in the Office queue."
            return false
        }
        officeProductionQueue.isSuspended =
            officeResourceSnapshot.mode == .blocked
        officeProductionQueue.boundHistory()
        await persistOfficeProductionQueue()
        noticeMessage = AppLocalization.format(
            officeResourceSnapshot.mode == .blocked
                ? "%lld Office job%@ queued and paused"
                : "%lld Office job%@ queued",
            addedCount,
            addedCount == 1 ? "" : "s"
        )
        startOfficeProductionQueue()
        return true
    }

    func resumeOfficeProductionQueue() async {
        await refreshOfficeResourceSnapshot()
        guard officeResourceSnapshot.mode != .blocked else {
            noticeMessage = officeResourceSnapshot.detail.localizedUI
            return
        }
        reconcileOfficeProductionQueueSources()
        for index in officeProductionQueue.jobs.indices
            where officeProductionQueue.jobs[index].stage == .paused {
            officeProductionQueue.jobs[index].stage = .queued
            officeProductionQueue.jobs[index].detail =
                "Waiting for local production"
        }
        officeProductionQueue.isSuspended = false
        await persistOfficeProductionQueue()
        startOfficeProductionQueue()
    }

    func suspendOfficeProductionQueue() async {
        guard officeProductionTask != nil
                || officeProductionQueue.hasRunnableJobs
        else { return }
        officeProductionQueue.isSuspended = true
        await persistOfficeProductionQueue()
        officeProductionTask?.cancel()
    }

    func retryOfficeProductionJob(
        _ jobID: UUID
    ) async {
        guard let index = officeProductionQueue.jobs.firstIndex(
            where: { $0.id == jobID }
        ),
              officeProductionQueue.jobs[index].stage == .attention
                || officeProductionQueue.jobs[index].stage == .cancelled
        else { return }
        let job = officeProductionQueue.jobs[index]
        if let issue = officeProductionSourceIssue(for: job) {
            officeProductionQueue.jobs[index].detail =
                issue.localizedUI
            await persistOfficeProductionQueue()
            return
        }
        officeProductionQueue.jobs[index].stage = .queued
        officeProductionQueue.jobs[index].completedAt = nil
        officeProductionQueue.jobs[index].detail =
            "Waiting for local production"
        officeProductionQueue.isSuspended = false
        await persistOfficeProductionQueue()
        startOfficeProductionQueue()
    }

    func canRetryOfficeProductionJob(_ jobID: UUID) -> Bool {
        guard let job = officeProductionQueue.jobs.first(
            where: { $0.id == jobID }
        ),
              job.stage == .attention || job.stage == .cancelled
        else { return false }
        return officeProductionSourceIssue(for: job) == nil
    }

    func canRestoreOfficeProductionSource(_ jobID: UUID) -> Bool {
        guard let job = officeProductionQueue.jobs.first(
            where: { $0.id == jobID }
        ),
              job.stage == .attention || job.stage == .cancelled,
              let deleted = deletedDocuments.first(
                where: { $0.id == job.recordID }
              )
        else { return false }
        return deleted.isWorkingCopy
            && !deleted.profile.isLocked
            && deleted.contentRevisionID == job.sourceRevisionID
            && PDFQuickTask.exportText.supports(deleted)
    }

    func restoreAndRetryOfficeProductionJob(
        _ jobID: UUID
    ) async {
        guard canRestoreOfficeProductionSource(jobID),
              let job = officeProductionQueue.jobs.first(
                where: { $0.id == jobID }
              )
        else { return }
        await restoreDeletedDocuments(recordIDs: [job.recordID])
        guard record(id: job.recordID) != nil else { return }
        await retryOfficeProductionJob(jobID)
        if officeProductionQueue.jobs.first(
            where: { $0.id == jobID }
        )?.stage == .queued {
            noticeMessage =
                "Source restored and Office job queued".localizedUI
        }
    }

    func cancelOfficeProductionJob(
        _ jobID: UUID
    ) async {
        guard let index = officeProductionQueue.jobs.firstIndex(
            where: { $0.id == jobID }
        ),
              !officeProductionQueue.jobs[index].stage.isTerminal
        else { return }
        if officeProductionQueue.jobs[index].stage.isActive {
            officeProductionCancelledJobID = jobID
            officeProductionTask?.cancel()
            return
        }
        officeProductionQueue.jobs[index].stage = .cancelled
        officeProductionQueue.jobs[index].completedAt =
            PDFOfficeTimeAnchor.process.trustedDate()
        officeProductionQueue.jobs[index].detail =
            "Removed before production started"
        await persistOfficeProductionQueue()
    }

    func setOfficeProductionPriority(
        jobID: UUID,
        priority: PDFOfficeQueuePriority
    ) async {
        guard let index = officeProductionQueue.jobs.firstIndex(
            where: { $0.id == jobID }
        ),
              officeProductionQueue.jobs[index].stage.isPending
        else { return }
        officeProductionQueue.jobs[index].priority = priority
        officeProductionQueue.boundHistory()
        await persistOfficeProductionQueue()
    }

    func clearFinishedOfficeProductionJobs() async {
        officeProductionQueue.jobs.removeAll {
            $0.stage.isTerminal
        }
        officeProductionQueue.boundHistory()
        await persistOfficeProductionQueue()
    }

    func removeOfficeProductionJob(_ jobID: UUID) async {
        guard officeProductionQueue.jobs.contains(where: {
            $0.id == jobID && $0.stage.isTerminal
        }) else { return }
        officeProductionQueue.jobs.removeAll { $0.id == jobID }
        officeProductionQueue.boundHistory()
        await persistOfficeProductionQueue()
    }

    private func startOfficeProductionQueue() {
        guard officeProductionTask == nil,
              officeProductionQueue.hasRunnableJobs,
              officeResourceSnapshot.mode != .blocked
        else { return }
        officeProductionTask = Task { @MainActor [weak self] in
            await self?.runOfficeProductionQueue()
        }
        startOfficeResourceMonitor()
    }

    private func runOfficeProductionQueue() async {
        while !Task.isCancelled,
              !officeProductionQueue.isSuspended,
              let jobID = nextOfficeProductionJobID() {
            await refreshOfficeResourceSnapshot()
            if officeResourceSnapshot.mode == .blocked {
                officeProductionQueue.isSuspended = true
                await persistOfficeProductionQueue()
                break
            }
            if officeResourceSnapshot.mode == .conserving {
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { break }
            }
            updateOfficeProductionJob(jobID) { job in
                job.stage = .analyzing
                job.startedAt = job.startedAt
                    ?? PDFOfficeTimeAnchor.process.trustedDate()
                job.completedAt = nil
                job.detail = "Checking source revision and route"
            }
            await persistOfficeProductionQueue()

            do {
                try Task.checkCancellation()
                guard let job = officeProductionQueue.jobs.first(
                    where: { $0.id == jobID }
                )
                else {
                    throw PaperPathError.insufficientSelection(
                        "The queued Office job is no longer available."
                    )
                }
                if let issue = officeProductionSourceIssue(for: job) {
                    throw PaperPathError.insufficientSelection(issue)
                }

                updateOfficeProductionJob(jobID) {
                    $0.stage = .rebuilding
                    $0.detail = $0.isBatch
                        ? "Running bounded segments serially"
                        : "Rebuilding one local Office package"
                }
                await persistOfficeProductionQueue()

                let receiptIDs: [UUID]
                if job.isBatch {
                    let run = try await executeQueuedOfficeBatch(job)
                    receiptIDs = run.segments.compactMap(\.receiptID)
                    guard run.completedCount == run.segments.count else {
                        updateOfficeProductionJob(jobID) {
                            $0.stage = .attention
                            $0.completedAt =
                                PDFOfficeTimeAnchor.process.trustedDate()
                            $0.receiptIDs = receiptIDs
                            $0.detail = AppLocalization.format(
                                "%lld of %lld parts retained",
                                run.completedCount,
                                run.segments.count
                            )
                        }
                        await persistOfficeProductionQueue()
                        continue
                    }
                } else {
                    let receipt = try await executeQueuedOfficeExport(
                        job
                    )
                    receiptIDs = [receipt.id]
                }

                updateOfficeProductionJob(jobID) {
                    $0.stage = .completed
                    $0.completedAt =
                        PDFOfficeTimeAnchor.process.trustedDate()
                    $0.receiptIDs = receiptIDs
                    $0.detail = receiptIDs.count == 1
                        ? "Integrity-sealed output retained"
                        : AppLocalization.format(
                            "%lld integrity-sealed parts retained",
                            receiptIDs.count
                        )
                }
                await persistOfficeProductionQueue()
            } catch is CancellationError {
                let wasCancelled =
                    officeProductionCancelledJobID == jobID
                updateOfficeProductionJob(jobID) {
                    $0.stage = wasCancelled ? .cancelled : .paused
                    $0.completedAt = wasCancelled
                        ? PDFOfficeTimeAnchor.process.trustedDate()
                        : nil
                    $0.detail = wasCancelled
                        ? "Production cancelled"
                        : "Paused safely between local operations"
                }
                officeProductionCancelledJobID = nil
                await persistOfficeProductionQueue()
                break
            } catch {
                updateOfficeProductionJob(jobID) {
                    $0.stage = .attention
                    $0.completedAt =
                        PDFOfficeTimeAnchor.process.trustedDate()
                    $0.detail = AppLocalization
                        .userFacingErrorDescription(error)
                }
                await persistOfficeProductionQueue()
            }
        }

        officeProductionTask = nil
        officeResourceMonitorTask?.cancel()
        officeResourceMonitorTask = nil
        if officeProductionQueue.hasRunnableJobs {
            startOfficeProductionQueue()
        }
    }

    private func executeQueuedOfficeBatch(
        _ job: PDFOfficeQueueJob
    ) async throws -> PDFOfficeBatchRun {
        if let existing = officeBatchRuns[job.recordID],
           existing.plan.sourceRevisionID == job.sourceRevisionID,
           existing.plan.format == job.format {
            if existing.completedCount == existing.segments.count {
                return existing
            }
            if !existing.retryableSegmentIDs.isEmpty,
               let resumed = try await resumeOfficeBatch(
                    recordID: job.recordID,
                    queueJobID: job.id
               ) {
                try Task.checkCancellation()
                return resumed
            }
        }
        guard let created = try await makeOfficeBatch(
            recordID: job.recordID,
            format: job.format,
            expectedSourceRevisionID: job.sourceRevisionID,
            queueJobID: job.id
        ) else {
            throw PaperPathError.storageFailure(
                "The segmented Office job could not start."
            )
        }
        try Task.checkCancellation()
        return created
    }

    private func executeQueuedOfficeExport(
        _ job: PDFOfficeQueueJob
    ) async throws -> PDFOfficeExportReceipt {
        let artifact = try await makeTextExport(
            recordID: job.recordID,
            format: job.format,
            expectedContentRevisionID: job.sourceRevisionID
        )
        defer {
            try? FileManager.default.removeItem(at: artifact.url)
            cleanupOfficeExportContainer(for: artifact.url)
        }
        try Task.checkCancellation()
        if let issue = officeProductionSourceIssue(for: job) {
            throw PaperPathError.insufficientSelection(issue)
        }
        guard let record = record(id: job.recordID) else {
            throw PaperPathError.unreadablePDF
        }

        updateOfficeProductionJob(job.id) {
            $0.stage = .retaining
            $0.detail = "Hashing and retaining the completed package"
        }
        await persistOfficeProductionQueue()

        let portfolio = PDFOfficeExportPortfolio(
            profile: record.profile
        )
        let size = (
            try? artifact.url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
        ) ?? 0
        let receipt = PDFOfficeExportReceipt(
            format: job.format,
            fileName: artifact.url.lastPathComponent,
            fileSizeBytes: Int64(size),
            plan: portfolio.plan(for: job.format),
            budgetPlan: portfolio.visualBudgetPlan,
            portfolio: portfolio,
            runtimeEvidence: artifact.runtimeEvidence
        )
        guard let retained = await retainOfficeExport(
            recordID: job.recordID,
            receipt: receipt,
            sourceURL: artifact.url,
            expectedContentRevisionID: job.sourceRevisionID
        ) else {
            throw PaperPathError.storageFailure(
                "The Office output could not be retained."
            )
        }
        return retained.receipt
    }

    private func nextOfficeProductionJobID() -> UUID? {
        officeProductionQueue.jobs
            .filter { $0.stage.isPending }
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority.rawValue
                        < $1.priority.rawValue
                }
                return $0.createdAt < $1.createdAt
            }
            .first?
            .id
    }

    private func updateOfficeProductionJob(
        _ jobID: UUID,
        update: (inout PDFOfficeQueueJob) -> Void
    ) {
        guard let index = officeProductionQueue.jobs.firstIndex(
            where: { $0.id == jobID }
        ) else { return }
        update(&officeProductionQueue.jobs[index])
        officeProductionQueue.updatedAt =
            PDFOfficeTimeAnchor.process.trustedDate()
    }

    private func persistOfficeProductionQueue() async {
        officeProductionQueue.updatedAt =
            PDFOfficeTimeAnchor.process.trustedDate()
        officeProductionQueue.boundHistory()
        do {
            try await store.saveOfficeProductionQueue(
                officeProductionQueue
            )
        } catch {
            present(error)
        }
    }

    private func reconcileOfficeProductionQueueSources() {
        var changed = false
        for index in officeProductionQueue.jobs.indices {
            let job = officeProductionQueue.jobs[index]
            guard !job.stage.isTerminal,
                  let issue = officeProductionSourceIssue(for: job)
            else { continue }
            officeProductionQueue.jobs[index].stage = .attention
            officeProductionQueue.jobs[index].completedAt =
                PDFOfficeTimeAnchor.process.trustedDate()
            officeProductionQueue.jobs[index].detail = issue.localizedUI
            changed = true
        }
        if !officeProductionQueue.jobs.contains(
            where: { $0.stage.isPending }
        ) {
            officeProductionQueue.isSuspended = false
        }
        if changed {
            officeProductionQueue.boundHistory()
        }
    }

    private func officeProductionSourceIssue(
        for job: PDFOfficeQueueJob
    ) -> String? {
        guard let source = record(id: job.recordID) else {
            if deletedDocuments.contains(where: {
                $0.id == job.recordID
            }) {
                return "Source is in Trash. Restore it, then retry."
            }
            return "Source is no longer available. Remove this job."
        }
        guard source.isWorkingCopy else {
            return "Only working copies can enter Office production."
        }
        guard !source.profile.isLocked else {
            return "Unlock this PDF before adding it to Office production."
        }
        guard PDFQuickTask.exportText.supports(source) else {
            return "This PDF no longer supports Office production."
        }
        guard source.contentRevisionID == job.sourceRevisionID else {
            return "The source changed. Add a new queue job."
        }
        return nil
    }

    func refreshOfficeResourceSnapshot() async {
        let processInfo = ProcessInfo.processInfo
        let thermalLevel: PDFOfficeThermalLevel
        switch processInfo.thermalState {
        case .nominal: thermalLevel = .nominal
        case .fair: thermalLevel = .fair
        case .serious: thermalLevel = .serious
        case .critical: thermalLevel = .critical
        @unknown default: thermalLevel = .unknown
        }
        let available = try? await store
            .availableCapacityForOfficeProduction()
        let capacity = available
        let lowPower = processInfo.isLowPowerModeEnabled
        let mode: PDFOfficeResourceMode
        let detail: String
        if thermalLevel == .critical {
            mode = .blocked
            detail =
                "Office production paused until device temperature drops."
        } else if let capacity,
                  capacity < 512 * 1_024 * 1_024 {
            mode = .blocked
            detail =
                "Office production paused because local space is critically low."
        } else if thermalLevel == .serious
                    || thermalLevel == .fair
                    || lowPower
                    || (capacity.map {
                        $0 < 2 * 1_024 * 1_024 * 1_024
                    } ?? false) {
            mode = .conserving
            detail =
                "Serial production uses a cooldown between Office jobs."
        } else {
            mode = .ready
            detail =
                "Device resources support normal serial production."
        }
        officeResourceSnapshot = PDFOfficeResourceSnapshot(
            mode: mode,
            thermalLevel: thermalLevel,
            isLowPowerModeEnabled: lowPower,
            availableCapacityBytes: capacity,
            capturedAt: Date(),
            detail: detail
        )
    }

    func officeProductionForecast(
        recordIDs: Set<UUID>,
        format requestedFormat: PDFTextExportFormat?
    ) -> PDFOfficeStorageForecast {
        var estimatedBytes: Int64 = 0
        var packageCount = 0
        let selected = documents.filter {
            recordIDs.contains($0.id)
                && $0.isWorkingCopy
                && PDFQuickTask.exportText.supports($0)
        }
        for record in selected {
            let portfolio = PDFOfficeExportPortfolio(
                profile: record.profile
            )
            let format = requestedFormat
                ?? portfolio.recommendedPlan?.format
                ?? .wordDocument
            let pageBytes = Int64(
                max(1, record.profile.pageCount)
            ) * 12 * 1_024
            let visualBytes = Int64(
                portfolio.visualBudgetPlan.estimatedVisualBytes
            )
            let baseBytes = max(
                pageBytes,
                min(record.profile.byteCount, 96 * 1_024 * 1_024)
            )
            let scale: Int64
            switch format {
            case .wordDocument: scale = 100
            case .excelWorkbook: scale = 72
            case .powerPointPresentation: scale = 125
            case .richText, .markdown, .plainText: scale = 45
            }
            let estimate = max(
                64 * 1_024,
                min(
                    768 * 1_024 * 1_024,
                    (baseBytes + visualBytes) * scale / 100
                )
            )
            estimatedBytes += estimate
            packageCount += PDFOfficeBatchPlan(
                format: format,
                sourceRevisionID: record.contentRevisionID,
                profile: record.profile
            ).segmentCount
        }
        let workingBytes = estimatedBytes > 0
            ? estimatedBytes
                + max(
                    64 * 1_024 * 1_024,
                    estimatedBytes / 4
                )
            : 0
        return PDFOfficeStorageForecast(
            sourceCount: selected.count,
            packageCount: packageCount,
            estimatedOutputBytes: estimatedBytes,
            requiredWorkingBytes: workingBytes,
            availableCapacityBytes:
                officeResourceSnapshot.availableCapacityBytes
        )
    }

    func officeIntegrityStatus(
        for job: PDFOfficeQueueJob
    ) -> PDFOfficeIntegrityStatus? {
        guard job.stage == .completed,
              !job.receiptIDs.isEmpty
        else { return nil }
        guard let record = record(id: job.recordID) else {
            return .missing
        }
        let receiptIDs = Set(job.receiptIDs)
        let receipts = record.officeReceipts.filter {
            receiptIDs.contains($0.id)
        }
        guard receipts.count == receiptIDs.count,
              !receipts.isEmpty
        else { return .missing }
        if let failure = receipts.compactMap(\.integrityStatus)
            .first(where: { !$0.isVerified }) {
            return failure
        }
        return receipts.allSatisfy {
            $0.integrityStatus == .verified
        } ? .verified : nil
    }

    func verifyOfficeProductionOutputs(
        jobIDs: Set<UUID>? = nil
    ) async throws -> PDFOfficeIntegrityReport {
        let (_, report) = try await verifiedOfficeArtifacts(
            jobIDs: jobIDs
        )
        lastOfficeIntegrityReport = report
        noticeMessage = report.summary.localizedUI
        return report
    }

    func makeOfficeProductionDeliveryPackage(
        jobIDs: Set<UUID>? = nil
    ) async throws -> (PDFOfficeDeliveryPackage, URL) {
        let (artifacts, report) = try await verifiedOfficeArtifacts(
            jobIDs: jobIDs
        )
        lastOfficeIntegrityReport = report
        guard report.isVerified, !artifacts.isEmpty else {
            throw PaperPathError.outputVerificationFailed(
                "one or more Office outputs failed integrity verification"
            )
        }
        await refreshOfficeResourceSnapshot()
        let deliveryWorkingBytes = saturatedByteTotal(
            artifacts.lazy.map {
                max(0, $0.receipt.fileSizeBytes)
            },
            reserve: 64 * 1_024 * 1_024
        )
        if let available =
            officeResourceSnapshot.availableCapacityBytes,
           available < deliveryWorkingBytes {
            throw PaperPathError.insufficientStorage
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Office-Delivery-\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory
        )
        let manifestURL = directory.appendingPathComponent(
            "PaperPath-delivery-manifest.json"
        )
        let destination = directory.appendingPathComponent(
            "PaperPath-Office-Delivery.zip"
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            var archiveSources: [OfficeBatchArchiveSource] = []
            var deliveryEntries: [PDFOfficeDeliveryEntry] = []
            for (index, verification) in artifacts.enumerated() {
                guard let url = verification.url else { continue }
                let receipt = verification.receipt
                let record = verification.record
                let partSuffix = receipt.batchSegmentIndex.map {
                    String(format: "-part-%02d", $0 + 1)
                } ?? ""
                let archiveName = String(
                    format: "%02d-%@%@.%@",
                    index + 1,
                    safeExportName(record.displayName),
                    partSuffix,
                    receipt.format.fileExtension
                )
                archiveSources.append(
                    OfficeBatchArchiveSource(
                        sourceURL: url,
                        archiveName: archiveName
                    )
                )
                deliveryEntries.append(
                    PDFOfficeDeliveryEntry(
                        sourceRecordID: record.id,
                        sourceRevisionID: record.contentRevisionID,
                        sourceName: record.displayName,
                        receiptID: receipt.id,
                        format: receipt.format,
                        archiveName: archiveName,
                        byteCount: receipt.fileSizeBytes,
                        sha256:
                            receipt.artifactSHA256 ?? "unavailable"
                    )
                )
            }
            let packageCreatedAt = try await store
                .trustedEvidenceIssuanceDate()
            var package = PDFOfficeDeliveryPackage(
                createdAt: packageCreatedAt,
                entries: deliveryEntries
            )
            let payload = PDFOfficeVerificationPayload(
                schema: "PaperPath Office Delivery V34",
                packageID: package.id,
                createdAt: package.createdAt,
                expiresAt: package.expiresAt,
                verifiedOutputs: report.verifiedCount,
                files: deliveryEntries
            )
            let signedReport = try await store
                .signOfficeDeliveryPayload(payload)
            package.signerKeyID = signedReport.signature.keyID
            officeDeliverySigningKeyID =
                signedReport.signature.keyID
            let reportEncoder = JSONEncoder()
            reportEncoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys
            ]
            reportEncoder.dateEncodingStrategy = .iso8601
            let manifestData = try reportEncoder.encode(
                signedReport
            )
            try manifestData.write(to: manifestURL, options: .atomic)
            try LocalFileSecurity.requireCompleteProtection(
                to: manifestURL
            )
            archiveSources.append(
                OfficeBatchArchiveSource(
                    sourceURL: manifestURL,
                    archiveName: manifestURL.lastPathComponent
                )
            )
            let sources = archiveSources
            let archiveGeneration = UUID()
            let archiveStartedAt = Date()
            officeIntegrityProgress = nil
            officeIntegrityGeneration = archiveGeneration
            officeIntegrityRateWindow.reset()
            defer {
                if officeIntegrityGeneration == archiveGeneration {
                    officeIntegrityProgress = nil
                    officeIntegrityGeneration = nil
                    officeIntegrityRateWindow.reset()
                }
            }
            let archiveTask = Task.detached(priority: .userInitiated) {
                try OfficeBatchArchiveService().createArchive(
                    sources: sources,
                    destination: destination,
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.publishOfficeIntegrityProgress(
                                generation: archiveGeneration,
                                completedCount:
                                    update.completedUnitCount,
                                totalCount:
                                    update.totalUnitCount,
                                currentSourceName:
                                    update.currentUnitName.isEmpty
                                    ? "Delivery package"
                                    : update.currentUnitName,
                                processedBytes:
                                    update.processedBytes,
                                totalBytes: update.totalBytes,
                                startedAt: archiveStartedAt,
                                activity: update.stage
                            )
                        }
                    }
                )
            }
            try await withTaskCancellationHandler {
                try await archiveTask.value
            } onCancel: {
                archiveTask.cancel()
            }
            try await verifyCreatedOfficeDeliveryArchive(
                at: destination,
                expectedReport: signedReport,
                progress: { update in
                    Task { @MainActor [weak self] in
                        self?.publishOfficeIntegrityProgress(
                            generation: archiveGeneration,
                            completedCount:
                                update.completedUnitCount,
                            totalCount: update.totalUnitCount,
                            currentSourceName:
                                update.currentUnitName.isEmpty
                                ? "Delivery package"
                                : update.currentUnitName,
                            processedBytes: update.processedBytes,
                            totalBytes: update.totalBytes,
                            startedAt: archiveStartedAt,
                            activity: update.stage
                        )
                    }
                }
            )
            let retained = try await store
                .retainOfficeDeliveryPackage(
                    package,
                    archiveURL: destination,
                    reportURL: manifestURL
                )
            officeDeliveryPackages = try await store
                .loadOfficeDeliveryPackages()
            return (retained.0, retained.1)
        } catch {
            throw error
        }
    }

    private func verifyCreatedOfficeDeliveryArchive(
        at archiveURL: URL,
        expectedReport: PDFOfficeSignedVerificationReport,
        progress: @escaping PDFByteProgressHandler
    ) async throws {
        let worker = Task.detached(priority: .utility) {
            try PDFVersionArchiveVerificationService()
                .verifyOfficeDeliveryArchive(
                    archiveURL: archiveURL,
                    progress: progress
                )
        }
        let inspection = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard inspection.signedReport == expectedReport else {
            throw PaperPathError.outputVerificationFailed(
                "the Office archive manifest changed after packaging"
            )
        }
        let signatureResult = try await store
            .verifyOfficeDeliveryReport(inspection.signedReport)
        guard signatureResult.isVerified else {
            throw PaperPathError.outputVerificationFailed(
                "the Office archive signature could not be verified"
            )
        }
    }

    func officeDeliveryPackageURLs(
        _ package: PDFOfficeDeliveryPackage,
        reportOnly: Bool = false
    ) async throws -> (archive: URL, report: URL) {
        try await store.officeDeliveryPackageURLs(
            for: package,
            reportOnly: reportOnly
        )
    }

    func verifyOfficeDeliveryReport(
        at url: URL
    ) async throws -> PDFOfficeReportVerificationResult {
        let generation = UUID()
        officeReportVerificationGeneration = generation
        releaseOfficeReportVerification()
        var verifiedDirectory: URL?
        var keepsVerifiedDirectory = false
        defer {
            if !keepsVerifiedDirectory,
               let verifiedDirectory {
                Self.discardVerifiedOfficeDeliveryDirectory(
                    verifiedDirectory
                )
            }
        }
        let result: PDFOfficeReportVerificationResult
        if url.pathExtension.lowercased() == "zip" {
            let hasScopedAccess =
                url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let archiveGeneration = UUID()
            let startedAt = Date()
            officeIntegrityGeneration = archiveGeneration
            officeIntegrityProgress = nil
            officeIntegrityRateWindow.reset()
            defer {
                if officeIntegrityGeneration == archiveGeneration {
                    officeIntegrityGeneration = nil
                    officeIntegrityProgress = nil
                    officeIntegrityRateWindow.reset()
                }
            }
            let extractionDirectory = FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "\(PaperPathTemporaryArtifact.verifiedOfficeDeliveryPrefix)\(UUID().uuidString)",
                    isDirectory: true
                )
            verifiedDirectory = extractionDirectory
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try LocalFileSecurity.prepareProtectedDirectory(
                        at: extractionDirectory
                    )
                    return try PDFVersionArchiveVerificationService()
                        .verifyOfficeDeliveryArchive(
                            archiveURL: url,
                            extractionDirectory: extractionDirectory
                        ) { update in
                            Task { @MainActor [weak self] in
                                self?.publishOfficeIntegrityProgress(
                                    generation: archiveGeneration,
                                    completedCount:
                                        update.completedUnitCount,
                                    totalCount:
                                        update.totalUnitCount,
                                    currentSourceName:
                                        update.currentUnitName.isEmpty
                                        ? "Signed ZIP"
                                        : update.currentUnitName,
                                    processedBytes:
                                        update.processedBytes,
                                    totalBytes: update.totalBytes,
                                    startedAt: startedAt,
                                    activity: update.stage
                                )
                            }
                        }
                } catch {
                    Self.discardVerifiedOfficeDeliveryDirectory(
                        extractionDirectory
                    )
                    throw error
                }
            }
            let inspection = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let verifiedReport = try await store
                .verifyOfficeDeliveryReport(
                inspection.signedReport
            )
            var archiveResult = verifiedReport.appendingDetail(
                AppLocalization.format(
                    "%lld ZIP entries matched CRC, byte count, and SHA-256.",
                    inspection.verifiedFileCount
                )
            )
            if archiveResult.isVerified {
                let formatStartedAt = Date()
                officeIntegrityRateWindow.reset()
                let formatWorker = Task.detached(
                    priority: .userInitiated
                ) {
                    try PDFOfficeArtifactFormatVerificationService()
                        .verify(
                            inspection.signedReport.payload.files,
                            extractedFileURLs:
                                inspection.extractedFileURLs
                        ) { update in
                            Task { @MainActor [weak self] in
                                self?.publishOfficeIntegrityProgress(
                                    generation: archiveGeneration,
                                    completedCount:
                                        update.completedUnitCount,
                                    totalCount:
                                        update.totalUnitCount,
                                    currentSourceName:
                                        update.currentUnitName,
                                    processedBytes:
                                        update.processedBytes,
                                    totalBytes: update.totalBytes,
                                    startedAt: formatStartedAt,
                                    activity: update.stage
                                )
                            }
                        }
                }
                let formatEvidence =
                    try await withTaskCancellationHandler {
                        try await formatWorker.value
                    } onCancel: {
                        formatWorker.cancel()
                    }
                try Task.checkCancellation()
                let artifacts = try inspection.signedReport.payload
                    .files.map { entry in
                        guard let artifactURL =
                                inspection.extractedFileURLs[
                                    entry.archiveName
                                ],
                              let evidence =
                                formatEvidence[entry.receiptID]
                        else {
                            throw PaperPathError.outputVerificationFailed(
                                "the verified Office files could not be extracted"
                            )
                        }
                        return PDFOfficeVerifiedArtifact(
                            entry: entry,
                            url: artifactURL,
                            formatEvidence: evidence
                        )
                    }
                archiveResult = archiveResult
                    .appendingDetail(
                        AppLocalization.format(
                            "%lld Office file formats passed structural verification.",
                            artifacts.count
                        )
                    )
                    .attachingVerifiedArtifacts(artifacts)
            }
            result = archiveResult
        } else {
            result = try await store.verifyOfficeDeliveryReport(
                at: url
            )
        }
        guard officeReportVerificationGeneration == generation
        else {
            throw CancellationError()
        }
        officeTrustedSigners = (
            try? await store.loadOfficeTrustedSigners()
        ) ?? officeTrustedSigners
        guard officeReportVerificationGeneration == generation
        else {
            throw CancellationError()
        }
        lastOfficeReportVerification = result
        keepsVerifiedDirectory = !result.verifiedArtifacts.isEmpty
        return result
    }

    func clearOfficeReportVerification() {
        officeReportVerificationGeneration = UUID()
        officeExternalMatchGeneration = UUID()
        releaseOfficeReportVerification()
        officeExternalMatchProgress = nil
    }

    private func releaseOfficeReportVerification() {
        let artifacts =
            lastOfficeReportVerification?.verifiedArtifacts ?? []
        lastOfficeReportVerification = nil
        guard let firstURL = artifacts.first?.url else { return }
        Self.discardVerifiedOfficeDeliveryDirectory(
            firstURL.deletingLastPathComponent()
        )
    }

    nonisolated private static func
        discardVerifiedOfficeDeliveryDirectory(
            _ directory: URL
        ) {
        Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: directory,
                allowedPrefixes: [
                    PaperPathTemporaryArtifact
                        .verifiedOfficeDeliveryPrefix
                ]
            )
        }
    }

    func revalidateOfficeArtifactsForSharing(
        receiptIDs: Set<UUID>
    ) async throws -> [URL] {
        guard let verification = lastOfficeReportVerification,
              !verification.verifiedArtifacts.isEmpty,
              !receiptIDs.isEmpty
        else {
            throw PaperPathError.insufficientSelection(
                "Choose at least one verified Office file."
            )
        }
        let initialWallDate = Date()
        let initialSystemUptime = ProcessInfo.processInfo.systemUptime
        let initialStatus = verification.effectiveStatus(
            at: initialWallDate,
            systemUptime: initialSystemUptime
        )
        guard initialStatus != .expired else {
            invalidateOfficeReportVerification()
            throw PaperPathError.outputVerificationFailed(
                "This signed Office report has expired. Verify a current delivery package before sharing."
            )
        }
        guard initialStatus == .verified,
              let signedReport = verification.signedReport
        else {
            invalidateOfficeReportVerification()
            throw PaperPathError.outputVerificationFailed(
                "The signed Office report must be verified again before sharing."
            )
        }
        let artifacts = verification.verifiedArtifacts.filter {
            receiptIDs.contains($0.id)
        }
        guard artifacts.count == receiptIDs.count else {
            throw PaperPathError.outputVerificationFailed(
                "The verified Office selection is invalid."
            )
        }

        let reportGeneration = officeReportVerificationGeneration
        let refreshedReport = try await store
            .verifyOfficeDeliveryReport(signedReport)
        guard officeReportVerificationGeneration == reportGeneration
        else {
            throw CancellationError()
        }
        let refreshedWallDate = Date()
        let refreshedSystemUptime = ProcessInfo.processInfo.systemUptime
        let refreshedStatus = refreshedReport.effectiveStatus(
            at: refreshedWallDate,
            systemUptime: refreshedSystemUptime
        )
        guard refreshedStatus == .verified else {
            invalidateOfficeReportVerification()
            throw PaperPathError.outputVerificationFailed(
                refreshedStatus == .expired
                    ? "This signed Office report expired before sharing."
                    : "The signed Office report no longer passes verification."
            )
        }
        let progressGeneration = UUID()
        let startedAt = Date()
        let totalBytes = saturatedByteTotal(
            artifacts.lazy.map { max(0, $0.entry.byteCount) }
        )
        officeIntegrityGeneration = progressGeneration
        officeIntegrityProgress = nil
        officeIntegrityRateWindow.reset()
        publishOfficeIntegrityProgress(
            generation: progressGeneration,
            completedCount: 0,
            totalCount: artifacts.count,
            currentSourceName:
                artifacts.first?.entry.archiveName ?? "",
            processedBytes: 0,
            totalBytes: totalBytes,
            startedAt: startedAt,
            activity: .checksumming
        )
        defer {
            if officeIntegrityGeneration == progressGeneration {
                officeIntegrityGeneration = nil
                officeIntegrityProgress = nil
                officeIntegrityRateWindow.reset()
            }
        }

        let worker = Task.detached(priority: .userInitiated) {
            try PDFOfficeArtifactShareVerificationService().verify(
                artifacts
            ) { update in
                Task { @MainActor [weak self] in
                    self?.publishOfficeIntegrityProgress(
                        generation: progressGeneration,
                        completedCount: update.completedUnitCount,
                        totalCount: update.totalUnitCount,
                        currentSourceName:
                            update.currentUnitName,
                        processedBytes: update.processedBytes,
                        totalBytes: update.totalBytes,
                        startedAt: startedAt,
                        activity: update.stage
                    )
                }
            }
        }
        let urls: [URL]
        do {
            urls = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if officeReportVerificationGeneration
                == reportGeneration {
                officeReportVerificationGeneration = UUID()
                releaseOfficeReportVerification()
            }
            throw error
        }
        try Task.checkCancellation()
        guard officeReportVerificationGeneration == reportGeneration,
              let current = lastOfficeReportVerification,
              current.verifiedArtifacts.filter({
                  receiptIDs.contains($0.id)
              }) == artifacts
        else {
            throw CancellationError()
        }
        let finalWallDate = Date()
        let finalSystemUptime = ProcessInfo.processInfo.systemUptime
        guard current.isVerified(
            at: finalWallDate,
            systemUptime: finalSystemUptime
        ) else {
            invalidateOfficeReportVerification()
            throw PaperPathError.outputVerificationFailed(
                "This signed Office report expired before sharing."
            )
        }
        return urls
    }

    private func invalidateOfficeReportVerification() {
        officeReportVerificationGeneration = UUID()
        releaseOfficeReportVerification()
    }

    func matchExternalOfficeDeliveryFiles(
        report: PDFOfficeSignedVerificationReport,
        candidateURLs: [URL]
    ) async -> PDFOfficeExternalMatchReport? {
        let generation = UUID()
        officeExternalMatchGeneration = generation
        officeExternalMatchProgress = nil
        do {
            let result = try await store
                .matchExternalOfficeDeliveryFiles(
                    report: report,
                    candidateURLs: candidateURLs
                ) { [weak self] progress in
                    guard self?.officeExternalMatchGeneration
                            == generation
                    else { return }
                    self?.officeExternalMatchProgress = progress
                }
            guard officeExternalMatchGeneration == generation
            else { return nil }
            if officeExternalMatchProgress?.packageID
                == report.payload.packageID {
                officeExternalMatchProgress = nil
            }
            return result
        } catch is CancellationError {
            if officeExternalMatchGeneration == generation {
                officeExternalMatchProgress = nil
            }
            return nil
        } catch {
            guard officeExternalMatchGeneration == generation
            else { return nil }
            officeExternalMatchProgress = nil
            present(error)
            return nil
        }
    }

    func exportSignedOfficeMatchReport(
        deliveryReport: PDFOfficeSignedVerificationReport,
        matchReport: PDFOfficeExternalMatchReport
    ) async -> URL? {
        do {
            return try await store.exportSignedOfficeMatchReport(
                deliveryReport: deliveryReport,
                matchReport: matchReport
            )
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func inspectExternalOfficeMatchReport(
        at sourceURL: URL
    ) async -> PDFOfficeMatchReportInspection? {
        do {
            return try await store.inspectExternalOfficeMatchReport(
                at: sourceURL
            )
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func makeOfficeSigningIdentityCardFile() async throws -> URL {
        try await store.makeOfficeDeliverySigningIdentityCardFile()
    }

    func parseOfficeSignerIdentityPayload(
        _ payload: String
    ) async throws -> PDFOfficeSignerIdentityCard {
        try await store.parseOfficeSignerIdentityPayload(payload)
    }

    func loadOfficeSignerIdentityCard(
        at url: URL
    ) async throws -> PDFOfficeSignerIdentityCard {
        try await store.loadOfficeSignerIdentityCard(at: url)
    }

    func trustOfficeSignerIdentity(
        _ card: PDFOfficeSignerIdentityCard
    ) async -> Bool {
        do {
            officeTrustedSigners = try await store
                .trustOfficeSignerIdentity(card)
            noticeMessage = "Signer trusted on this device"
            return true
        } catch {
            present(error)
            return false
        }
    }

    func updateOfficeTrustedSigner(
        keyID: String,
        displayName: String,
        note: String
    ) async -> Bool {
        do {
            officeTrustedSigners = try await store
                .updateOfficeTrustedSigner(
                    keyID: keyID,
                    displayName: displayName,
                    note: note
                )
            if let verification = lastOfficeReportVerification,
               verification.keyID == keyID,
               verification.trustStatus == .trusted,
               let signer = officeTrustedSigners.first(
                where: { $0.keyID == keyID }
               ) {
                lastOfficeReportVerification =
                    verification.updatingTrust(
                        .trusted,
                        signerName: signer.displayName
                    )
            }
            return true
        } catch {
            present(error)
            return false
        }
    }

    func trustLastOfficeReportSigner() async {
        guard let verification = lastOfficeReportVerification else {
            return
        }
        do {
            officeTrustedSigners = try await store
                .trustOfficeReportSigner(verification)
            if let keyID = verification.keyID,
               let signer = officeTrustedSigners.first(
                where: { $0.keyID == keyID }
               ) {
                lastOfficeReportVerification =
                    verification.updatingTrust(
                        .trusted,
                        signerName: signer.displayName
                    )
            }
            noticeMessage = "Signer trusted on this device"
        } catch {
            present(error)
        }
    }

    func removeOfficeTrustedSigner(
        _ keyID: String
    ) async -> Bool {
        do {
            officeTrustedSigners = try await store
                .removeOfficeTrustedSigner(keyID)
            if lastOfficeReportVerification?.keyID == keyID,
               let verification = lastOfficeReportVerification {
                lastOfficeReportVerification =
                    verification.updatingTrust(
                        .unknown,
                        signerName: nil
                    )
            }
            noticeMessage = "Signer trust removed from this device"
                .localizedUI
            return true
        } catch {
            present(error)
            return false
        }
    }

    func setOfficeDeliveryPackagePinned(
        _ packageID: UUID,
        pinned: Bool
    ) async {
        do {
            officeDeliveryPackages = try await store
                .setOfficeDeliveryPackagePinned(
                    packageID,
                    pinned: pinned
                )
        } catch {
            present(error)
        }
    }

    func deleteOfficeDeliveryPackage(
        _ packageID: UUID
    ) async {
        do {
            officeDeliveryPackages = try await store
                .deleteOfficeDeliveryPackage(packageID)
        } catch {
            present(error)
        }
    }

    private func verifiedOfficeArtifacts(
        jobIDs: Set<UUID>?
    ) async throws -> (
        [PDFOfficeIntegrityVerification],
        PDFOfficeIntegrityReport
    ) {
        let jobs = officeProductionQueue.jobs.filter {
            $0.stage == .completed
                && (jobIDs?.contains($0.id) ?? true)
        }
        let expectedReceiptIDs = Set(
            jobs.flatMap(\.receiptIDs)
        )
        guard !expectedReceiptIDs.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "No completed Office outputs are ready."
            )
        }

        var receiptByteCounts: [UUID: Int64] = [:]
        for job in jobs {
            guard let current = record(id: job.recordID) else {
                continue
            }
            for receiptID in job.receiptIDs
                where receiptByteCounts[receiptID] == nil {
                receiptByteCounts[receiptID] = current.officeReceipts
                    .first(where: { $0.id == receiptID })
                    .map { max(0, $0.fileSizeBytes) } ?? 0
            }
        }
        let totalBytes = saturatedByteTotal(
            receiptByteCounts.values
        )
        let startedAt = Date()
        let generation = UUID()
        officeIntegrityProgress = nil
        officeIntegrityGeneration = generation
        officeIntegrityRateWindow.reset()
        publishOfficeIntegrityProgress(
            generation: generation,
            completedCount: 0,
            totalCount: expectedReceiptIDs.count,
            currentSourceName: jobs.first?.sourceName ?? "",
            processedBytes: 0,
            totalBytes: totalBytes,
            startedAt: startedAt
        )
        defer {
            if officeIntegrityGeneration == generation {
                officeIntegrityProgress = nil
                officeIntegrityGeneration = nil
                officeIntegrityRateWindow.reset()
            }
        }
        var verifications: [PDFOfficeIntegrityVerification] = []
        var seenReceiptIDs: Set<UUID> = []
        var completedCount = 0
        var processedBytes: Int64 = 0
        for job in jobs {
            for receiptID in job.receiptIDs
                where seenReceiptIDs.insert(receiptID).inserted {
                try Task.checkCancellation()
                let receiptBytes = receiptByteCounts[receiptID] ?? 0
                let completedBytes = processedBytes
                let fileCompletedCount = completedCount
                let sourceName = job.sourceName
                publishOfficeIntegrityProgress(
                    generation: generation,
                    completedCount: completedCount,
                    totalCount: expectedReceiptIDs.count,
                    currentSourceName: sourceName,
                    processedBytes: completedBytes,
                    totalBytes: totalBytes,
                    startedAt: startedAt
                )
                guard let current = record(id: job.recordID) else {
                    completedCount += 1
                    processedBytes = saturatedByteTotal(
                        [processedBytes, receiptBytes]
                    )
                    continue
                }
                let verification = try await store.verifyOfficeExport(
                    receiptID: receiptID,
                    for: current,
                    progress: { [weak self] fileBytes, _ in
                        let aggregateBytes = min(
                            totalBytes,
                            completedBytes
                                + min(receiptBytes, fileBytes)
                        )
                        Task { @MainActor [weak self] in
                            self?.publishOfficeIntegrityProgress(
                                generation: generation,
                                completedCount: fileCompletedCount,
                                totalCount:
                                    expectedReceiptIDs.count,
                                currentSourceName: sourceName,
                                processedBytes: aggregateBytes,
                                totalBytes: totalBytes,
                                startedAt: startedAt
                            )
                        }
                    }
                )
                replace(
                    verification.record,
                    schedulesMetadataSync: false
                )
                verifications.append(verification)
                completedCount += 1
                processedBytes = saturatedByteTotal(
                    [processedBytes, receiptBytes]
                )
                publishOfficeIntegrityProgress(
                    generation: generation,
                    completedCount: completedCount,
                    totalCount: expectedReceiptIDs.count,
                    currentSourceName: job.sourceName,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    startedAt: startedAt
                )
            }
        }
        let checkedCount = max(
            expectedReceiptIDs.count,
            verifications.count
        )
        let verifiedCount = verifications.filter {
            $0.status.isVerified
        }.count
        let report = PDFOfficeIntegrityReport(
            checkedCount: checkedCount,
            verifiedCount: verifiedCount,
            failedCount: checkedCount - verifiedCount,
            checkedAt: await store.trustedDeliveryDate()
        )
        return (verifications, report)
    }

    private func publishOfficeIntegrityProgress(
        generation: UUID,
        completedCount: Int,
        totalCount: Int,
        currentSourceName: String,
        processedBytes: Int64,
        totalBytes: Int64,
        startedAt: Date,
        activity: PDFByteProgressStage = .verifying
    ) {
        guard officeIntegrityGeneration == generation else { return }
        if let current = officeIntegrityProgress,
           current.activity == activity,
           processedBytes < current.processedBytes
            || (
                processedBytes == current.processedBytes
                    && completedCount < current.completedCount
            ) {
            return
        }
        _ = startedAt
        let previousBytes =
            officeIntegrityProgress?.activity == activity
            ? officeIntegrityProgress?.processedBytes ?? 0
            : 0
        let boundedTotalBytes = max(0, totalBytes)
        let boundedBytes = max(
            previousBytes,
            min(max(0, processedBytes), boundedTotalBytes)
        )
        let previousProgress = officeIntegrityProgress
        let didAdvance =
            previousProgress?.activity != activity
            || boundedBytes
                > (previousProgress?.processedBytes ?? -1)
        let bytesPerSecond = officeIntegrityRateWindow.update(
            stage: activity,
            processedBytes: boundedBytes
        )
        let remaining = bytesPerSecond > 0
            ? Double(boundedTotalBytes - boundedBytes)
                / bytesPerSecond
            : nil
        officeIntegrityProgress = PDFOfficeIntegrityProgress(
            completedCount: completedCount,
            totalCount: totalCount,
            currentSourceName: currentSourceName,
            processedBytes: boundedBytes,
            totalBytes: boundedTotalBytes,
            bytesPerSecond: bytesPerSecond,
            estimatedRemainingSeconds: remaining,
            activity: activity,
            throughputHistory: officeIntegrityRateWindow.history,
            lastByteUpdateAt: didAdvance
                ? Date()
                : previousProgress?.lastByteUpdateAt
        )
    }

    private func startOfficeResourceMonitor() {
        officeResourceMonitorTask?.cancel()
        officeResourceMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                await self.refreshOfficeResourceSnapshot()
                if self.officeResourceSnapshot.mode == .blocked {
                    self.noticeMessage = self.officeResourceSnapshot.detail
                        .localizedUI
                    await self.suspendOfficeProductionQueue()
                    return
                }
            }
        }
    }

    @discardableResult
    func toggleBookmark(
        recordID: UUID,
        pageIndex: Int,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID,
              pageIndex >= 0,
              pageIndex < record.profile.pageCount
        else { return false }
        do {
            let updated = try await store.toggleBookmark(
                record,
                pageIndex: pageIndex
            )
            guard updated.contentRevisionID
                    == expectedContentRevisionID
            else { return false }
            guard let resident = self.record(id: recordID),
                  resident.contentRevisionID
                    == expectedContentRevisionID
            else { return false }
            guard resident.modifiedAt <= updated.modifiedAt else {
                return true
            }
            replace(updated)
            noticeMessage = updated.bookmarkedPages.contains(pageIndex)
                ? AppLocalization.format(
                    "Page %lld bookmarked",
                    pageIndex + 1
                )
                : "Bookmark removed".localizedUI
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func saveBookmark(
        recordID: UUID,
        pageIndex: Int,
        name: String?,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID,
              pageIndex >= 0,
              pageIndex < record.profile.pageCount
        else { return false }
        do {
            let updated = try await store.saveBookmark(
                record,
                pageIndex: pageIndex,
                name: name
            )
            guard updated.contentRevisionID
                    == expectedContentRevisionID
            else { return false }
            guard let resident = self.record(id: recordID),
                  resident.contentRevisionID
                    == expectedContentRevisionID
            else { return false }
            guard resident.modifiedAt <= updated.modifiedAt else {
                return true
            }
            replace(updated)
            noticeMessage = updated.bookmarkNames[pageIndex] == nil
                ? AppLocalization.format(
                    "Page %lld bookmarked",
                    pageIndex + 1
                )
                : "Bookmark named".localizedUI
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func updateBookmarkName(
        recordID: UUID,
        pageIndex: Int,
        name: String?
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updateBookmarkName(
                record,
                pageIndex: pageIndex,
                name: name
            )
            guard let resident = self.record(id: recordID),
                  resident.contentRevisionID
                    == record.contentRevisionID,
                  resident.modifiedAt <= updated.modifiedAt
            else { return }
            replace(updated)
            noticeMessage = updated.bookmarkNames[pageIndex] == nil
                ? "Bookmark name removed"
                : "Bookmark named"
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func updateReadingPosition(
        recordID: UUID,
        pageIndex: Int,
        expectedContentRevisionID: UUID,
        viewedAt: Date = Date()
    ) async {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID
        else { return }
        if record.lastPageIndex == pageIndex,
           let lastViewedAt = record.lastViewedAt,
           viewedAt <= lastViewedAt
                || viewedAt.timeIntervalSince(lastViewedAt) < 30 {
            return
        }
        do {
            let updated = try await store.updateReadingPosition(
                recordID: recordID,
                pageIndex: pageIndex,
                expectedRevisionID:
                    expectedContentRevisionID,
                viewedAt: viewedAt
            )
            guard updated.contentRevisionID
                    == expectedContentRevisionID
            else { return }
            guard let resident = self.record(id: recordID),
                  resident.contentRevisionID
                    == expectedContentRevisionID,
                  (resident.lastViewedAt ?? .distantPast)
                    <= (updated.lastViewedAt ?? .distantPast)
            else { return }
            replace(
                updated,
                invalidatesSearchText: false
            )
        } catch is CancellationError {
            return
        } catch {
            // Reading remains usable even if this noncritical state fails.
        }
    }

    func enqueueReadingPositionUpdate(
        ownerID: UUID,
        recordID: UUID,
        pageIndex: Int,
        expectedContentRevisionID: UUID,
        viewedAt: Date = Date()
    ) {
        cancelReadingPositionUpdate(ownerID: ownerID)
        guard UIApplication.shared.isProtectedDataAvailable,
              record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else { return }
        let generation = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.readingPositionTasks[ownerID]?.generation
                    == generation {
                    self.readingPositionTasks[ownerID] = nil
                }
            }
            guard !Task.isCancelled,
                  UIApplication.shared.isProtectedDataAvailable,
                  self.record(id: recordID)?.contentRevisionID
                    == expectedContentRevisionID
            else { return }
            await self.updateReadingPosition(
                recordID: recordID,
                pageIndex: pageIndex,
                expectedContentRevisionID:
                    expectedContentRevisionID,
                viewedAt: viewedAt
            )
        }
        readingPositionTasks[ownerID] = ReadingPositionTaskEntry(
            recordID: recordID,
            generation: generation,
            task: task
        )
    }

    func cancelReadingPositionUpdate(ownerID: UUID) {
        readingPositionTasks.removeValue(forKey: ownerID)?
            .task.cancel()
    }

    private func cancelAllReadingPositionUpdates() {
        for entry in readingPositionTasks.values {
            entry.task.cancel()
        }
        readingPositionTasks.removeAll(keepingCapacity: false)
    }

    func recentDocuments(
        excluding recordID: UUID,
        limit: Int = 5
    ) -> [DocumentRecord] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let currentRole = record(id: recordID)?.isDeliveryArtifact
        var recent: [DocumentRecord] = []
        recent.reserveCapacity(min(boundedLimit, documents.count))
        for candidate in documents {
            guard candidate.id != recordID else { continue }
            if let currentRole,
               candidate.isDeliveryArtifact != currentRole {
                continue
            }
            let candidateDate =
                candidate.lastViewedAt ?? candidate.modifiedAt
            let insertionIndex = recent.firstIndex {
                candidateDate
                    > ($0.lastViewedAt ?? $0.modifiedAt)
            } ?? recent.endIndex
            guard insertionIndex < boundedLimit else { continue }
            recent.insert(candidate, at: insertionIndex)
            if recent.count > boundedLimit {
                recent.removeLast()
            }
        }
        return recent
    }

    func synchronizeMetadata(
        showNotice: Bool = true
    ) async {
        guard UserDefaults.standard.bool(
            forKey: AppPreferences.metadataSyncEnabledKey
        ) else {
            metadataSyncStatus = metadataSyncDisabledStatus
            return
        }
        guard !isRunningAutomatedTests else { return }
        if showNotice {
            metadataSyncAutomaticRetryBlocked = false
        } else {
            guard !metadataSyncAutomaticRetryBlocked else { return }
        }
        if isSynchronizingMetadata {
            requestMetadataSyncFollowUp(
                showNotice: showNotice
            )
            return
        }
        metadataSyncScheduleGeneration = UUID()
        metadataSyncTask?.cancel()
        metadataSyncTask = nil
        let generation = metadataSyncGeneration
        isSynchronizingMetadata = true
        var shouldShowCompletionNotice = showNotice
        var completed = true
        var completedPassCount = 0
        repeat {
            metadataSyncNeedsFollowUp = false
            metadataSyncFollowUpShowsNotice = false
            completed = await performMetadataSyncPass(
                generation: generation
            )
            completedPassCount += 1
            guard metadataSyncGeneration == generation else {
                return
            }
            shouldShowCompletionNotice =
                shouldShowCompletionNotice
                    || metadataSyncFollowUpShowsNotice
        } while completed
            && metadataSyncNeedsFollowUp
            && completedPassCount
                < Self.maximumMetadataSyncPassesPerRun
        let shouldRetryAfterFailure =
            !completed && metadataSyncNeedsFollowUp
        isSynchronizingMetadata = false
        metadataSyncNeedsFollowUp = false
        metadataSyncFollowUpShowsNotice = false
        if shouldRetryAfterFailure {
            scheduleMetadataSync(delay: .milliseconds(250))
        }
        guard shouldShowCompletionNotice else { return }
        switch metadataSyncStatus.state {
        case .synced:
            noticeMessage = "Document metadata synced".localizedUI
        case .unavailable:
            noticeMessage =
                "iCloud metadata sync is unavailable".localizedUI
        case .failed:
            noticeMessage = "Metadata sync could not finish".localizedUI
        case .idle, .syncing:
            break
        }
    }

    private func performMetadataSyncPass(
        generation: UUID
    ) async -> Bool {
        metadataSyncStatus = PDFMetadataSyncStatus(
            state: .syncing,
            documentCount: metadataSyncStatus.documentCount,
            updatedAt: metadataSyncStatus.updatedAt,
            detail: "Merging lightweight metadata through iCloud."
        )
        do {
            let fingerprintedRecords = try await store
                .ensureContentFingerprints(for: documents)
            synchronizeCommittedFingerprints(fingerprintedRecords)
            guard metadataSyncGeneration == generation,
                  UserDefaults.standard.bool(
                    forKey: AppPreferences.metadataSyncEnabledKey
                  )
            else { return false }
            let preparation =
                try await metadataSyncService.prepareSynchronization(
                    records: fingerprintedRecords
                )
            guard metadataSyncGeneration == generation else {
                return false
            }
            isApplyingMetadataSync = true
            defer { isApplyingMetadataSync = false }
            let updatedRecords = try await store.applyMetadataSync(
                preparation.updates
            )
            let expectedStates = Dictionary(
                uniqueKeysWithValues: preparation.updates.map {
                    ($0.recordID, $0.expectedLocalState)
                }
            )
            for updated in updatedRecords {
                guard let expectedState = expectedStates[updated.id]
                else { continue }
                synchronizeCommittedMetadataRecord(
                    updated,
                    expectedLocalState: expectedState
                )
            }
            guard !Task.isCancelled,
                  metadataSyncGeneration == generation,
                  UserDefaults.standard.bool(
                    forKey: AppPreferences.metadataSyncEnabledKey
                  )
            else { return false }
            try metadataSyncService.checkpointAppliedMetadata(
                preparation
            )
            let result = try metadataSyncService.commit(preparation)
            let detail: String
            if result.isCloudAvailable {
                detail = result.eligibleDocumentCount == 0
                    ? "No matching document metadata is ready to sync."
                    : "Bookmarks, tags, status, and receipts are synced. PDFs and text stay local."
            } else {
                detail =
                    "Sign in to iCloud and enable PaperPath sync. PDFs and text stay local."
            }
            metadataSyncStatus = PDFMetadataSyncStatus(
                state: result.isCloudAvailable
                    ? .synced
                    : .unavailable,
                documentCount: result.eligibleDocumentCount,
                updatedAt: result.synchronizedAt,
                detail: detail
            )
            return true
        } catch is CancellationError {
            return false
        } catch PDFMetadataSyncApplyError.localStateChanged,
                PDFMetadataSyncCommitError.remoteStateChanged {
            guard metadataSyncGeneration == generation else {
                return false
            }
            requestMetadataSyncFollowUp(showNotice: false)
            return false
        } catch {
            guard metadataSyncGeneration == generation else {
                return false
            }
            metadataSyncStatus = PDFMetadataSyncStatus(
                state: .failed,
                documentCount: metadataSyncStatus.documentCount,
                updatedAt: metadataSyncStatus.updatedAt,
                detail: AppLocalization
                    .userFacingErrorDescription(error)
            )
            return false
        }
    }

    private func synchronizeCommittedFingerprints(
        _ storedRecords: [DocumentRecord]
    ) {
        for storedRecord in storedRecords {
            guard let fingerprint = storedRecord.contentFingerprint,
                  var residentRecord = record(id: storedRecord.id),
                  residentRecord.contentRevisionID
                    == storedRecord.contentRevisionID,
                  residentRecord.contentFingerprint != fingerprint
            else { continue }
            residentRecord.contentFingerprint = fingerprint
            replace(
                residentRecord,
                schedulesMetadataSync: false,
                invalidatesSearchText: false
            )
        }
    }

    private func synchronizeCommittedMetadataRecord(
        _ storedRecord: DocumentRecord,
        expectedLocalState: PDFMetadataSyncLocalState
    ) {
        guard let residentRecord = record(id: storedRecord.id),
              residentRecord.contentRevisionID
                == storedRecord.contentRevisionID
        else { return }
        let storedState = PDFMetadataSyncLocalState(storedRecord)
        if storedState.matchesPersistenceRepresentation(
            of: residentRecord
        ) {
            return
        }
        guard expectedLocalState.matchesPersistenceRepresentation(
            of: residentRecord
        ) else { return }
        var mergedRecord = residentRecord
        mergedRecord.lastPageIndex = storedRecord.lastPageIndex
        mergedRecord.lastViewedAt = storedRecord.lastViewedAt
        mergedRecord.bookmarkedPages = storedRecord.bookmarkedPages
        mergedRecord.workflowStatus = storedRecord.workflowStatus
        mergedRecord.isPinned = storedRecord.isPinned
        mergedRecord.tags = storedRecord.tags
        mergedRecord.completedActions = storedRecord.completedActions
        mergedRecord.deliveryReceipt = storedRecord.deliveryReceipt
        mergedRecord.modifiedAt = max(
            residentRecord.modifiedAt,
            storedRecord.modifiedAt
        )
        replace(
            mergedRecord,
            schedulesMetadataSync: false,
            invalidatesSearchText: false
        )
    }

    func setMetadataSyncEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(
            enabled,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        if enabled {
            metadataSyncAutomaticRetryBlocked = false
            startMetadataSyncObservation()
            await synchronizeMetadata()
        } else {
            invalidateMetadataSyncWork()
            metadataSyncAutomaticRetryBlocked = false
            if let metadataSyncObserver {
                NotificationCenter.default.removeObserver(
                    metadataSyncObserver
                )
                self.metadataSyncObserver = nil
            }
            metadataSyncStatus = metadataSyncDisabledStatus
            noticeMessage = "iCloud metadata sync turned off".localizedUI
        }
    }

    func deleteSyncedMetadata() async {
        invalidateMetadataSyncWork()
        metadataSyncAutomaticRetryBlocked = false
        if let metadataSyncObserver {
            NotificationCenter.default.removeObserver(
                metadataSyncObserver
            )
            self.metadataSyncObserver = nil
        }
        UserDefaults.standard.set(
            false,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        metadataSyncStatus = metadataSyncDisabledStatus
        do {
            try metadataSyncService.clearSyncedMetadata()
            noticeMessage =
                "Synced metadata deleted and sync turned off".localizedUI
        } catch {
            present(error)
        }
    }

    func sourceLocation(
        recordID: UUID
    ) async -> PDFSourceLocationSnapshot? {
        guard let record = record(id: recordID) else { return nil }
        do {
            try Task.checkCancellation()
            let snapshot = try await store.sourceLocation(for: record)
            try Task.checkCancellation()
            return snapshot
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func importLatestSource(
        recordID: UUID
    ) async -> DocumentRecord? {
        guard let record = record(id: recordID) else { return nil }
        do {
            let snapshot = try await store.sourceLocation(for: record)
            guard let url = snapshot.resolvedURL,
                  snapshot.status == .changed
                    || snapshot.status == .stale
            else {
                present(
                    PaperPathError.storageFailure(
                        "The source in Files has no newer version to import."
                    )
                )
                return nil
            }
            let importToken = beginImportOperation()
            defer { finishImportOperation(importToken) }
            let imported = try await importSinglePDF(
                from: url,
                preferredName: AppLocalization.format(
                    "%@ - Files update",
                    record.displayName
                ),
                analyzeAfterImport: false,
                preserveSourceLocation: true
            )
            noticeMessage = "Updated source imported as a new private copy"
                .localizedUI
            resumeDeferredBackgroundWork()
            return imported
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func moveToTrashBlockReason(for recordID: UUID) -> String? {
        if isProcessing(recordID) {
            return "Wait for the current PDF operation to finish."
        }
        if officeProductionQueue.jobs.contains(where: {
            $0.recordID == recordID && !$0.stage.isTerminal
        }) {
            return "Finish or cancel this PDF's Office job first."
        }
        if batchDeliveryPendingDocumentIDs.contains(recordID) {
            return "Stop the active batch verification first."
        }
        return nil
    }

    @discardableResult
    func delete(recordID: UUID) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        if let reason = moveToTrashBlockReason(for: recordID) {
            noticeMessage = reason.localizedUI
            return false
        }
        guard let operationToken =
            acquireExclusiveDocumentOperation(recordID: recordID)
        else { return false }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            let deleted = try await store.moveToTrash(record)
            removeRecordState(recordID)
            deletedDocuments.insert(deleted, at: 0)
            presentActionNotice(
                message: record.isDeliveryArtifact
                    ? "Delivery output moved to Trash"
                    : "Working copy moved to Trash",
                detail: record.isDeliveryArtifact
                    ? "Its source working copy remains available."
                    : "The Files original remains unchanged.",
                kind: .recovery,
                action: .restoreTrash(recordIDs: [recordID])
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func delete(recordIDs: Set<UUID>) async -> Bool {
        let records = documents.filter {
            recordIDs.contains($0.id)
        }
        guard !records.isEmpty else { return false }
        if let blocked = records.first(where: {
            moveToTrashBlockReason(for: $0.id) != nil
        }) {
            noticeMessage = AppLocalization.format(
                "%@: %@",
                blocked.displayName,
                moveToTrashBlockReason(for: blocked.id) ?? ""
            )
            return false
        }
        let orderedIDs = records.map(\.id)
        guard let operationTokens =
            acquireExclusiveDocumentOperations(
                recordIDs: orderedIDs
            )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }

        do {
            let deleted = try await store.moveToTrash(
                recordIDs: Set(orderedIDs)
            )
            let deletedIDs = Set(deleted.map(\.id))
            removeRecordsState(deletedIDs)
            deletedDocuments.append(contentsOf: deleted)
            deletedDocuments.sort {
                ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
            presentActionNotice(
                message: AppLocalization.format(
                    "%lld items moved to Trash",
                    deleted.count
                ),
                detail: "Restore the complete selection in one step.",
                kind: .recovery,
                action: .restoreTrash(
                    recordIDs: deleted.map(\.id)
                )
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func withFeedbackTarget<Value>(
        _ sceneID: UUID?,
        operation: () async throws -> Value
    ) async rethrows -> Value {
        try await AppFeedbackContext.$targetSceneID.withValue(
            sceneID
        ) {
            try await operation()
        }
    }

    func feedbackSceneDidBecomeActive(_ sceneID: UUID) {
        activeFeedbackSceneIDs.insert(sceneID)
        feedbackSceneSequence &+= 1
        feedbackSceneRecency[sceneID] = feedbackSceneSequence
        adoptUnscopedFeedback(into: sceneID)
    }

    func feedbackSceneDidResignActive(_ sceneID: UUID) {
        activeFeedbackSceneIDs.remove(sceneID)
        if let targetSceneID = preferredActiveFeedbackSceneID {
            adoptUnscopedFeedback(into: targetSceneID)
        }
    }

    func feedbackSceneDidDisconnect(_ sceneID: UUID) {
        activeFeedbackSceneIDs.remove(sceneID)
        feedbackSceneRecency[sceneID] = nil
        fullUnlockContextsBySceneID[sceneID] = nil
        settingsPresentationSceneIDs.remove(sceneID)
        if let targetSceneID = preferredActiveFeedbackSceneID {
            adoptUnscopedFeedback(into: targetSceneID)
        }
    }

    func fullUnlockContext(
        for sceneID: UUID
    ) -> FullUnlockContext? {
        if let context = fullUnlockContextsBySceneID[sceneID] {
            return context
        }
        guard preferredActiveFeedbackSceneID == sceneID
        else { return nil }
        return unscopedFullUnlockContext
    }

    func dismissFullUnlock(from sceneID: UUID) {
        if fullUnlockContextsBySceneID[sceneID] != nil {
            fullUnlockContextsBySceneID[sceneID] = nil
        } else if preferredActiveFeedbackSceneID == sceneID {
            unscopedFullUnlockContext = nil
        }
    }

    func settingsPresentationRequested(
        for sceneID: UUID?
    ) -> Bool {
        guard let sceneID else {
            return activeFeedbackSceneIDs.isEmpty
                && hasUnscopedSettingsPresentationRequest
        }
        return settingsPresentationSceneIDs.contains(sceneID)
            || (
                preferredActiveFeedbackSceneID == sceneID
                    && hasUnscopedSettingsPresentationRequest
            )
    }

    func consumeSettingsPresentationRequest(
        for sceneID: UUID?
    ) {
        guard let sceneID else {
            if activeFeedbackSceneIDs.isEmpty {
                hasUnscopedSettingsPresentationRequest = false
            }
            return
        }
        if settingsPresentationSceneIDs.remove(sceneID) != nil {
            return
        }
        if preferredActiveFeedbackSceneID == sceneID {
            hasUnscopedSettingsPresentationRequest = false
        }
    }

    func transientNotice(
        for sceneID: UUID
    ) -> AppTransientNotice? {
        transientNoticesBySceneID[sceneID]
            ?? unscopedTransientNoticeForScene(sceneID)
    }

    func presentNotice(
        _ message: String?,
        in sceneID: UUID?
    ) {
        if let message {
            setTransientNotice(message, targetSceneID: sceneID)
        } else {
            dismissTransientNotice(from: sceneID)
        }
    }

    func dismissTransientNotice(
        id: UUID? = nil,
        from sceneID: UUID? = nil
    ) {
        if let sceneID,
           let notice = transientNoticesBySceneID[sceneID],
           id == nil || notice.id == id {
            transientNoticesBySceneID[sceneID] = nil
            return
        }
        guard let notice = unscopedTransientNotice,
              id == nil || notice.id == id
        else { return }
        unscopedTransientNotice = nil
    }

    func releaseTransientNoticeTarget(for sceneID: UUID) {
        guard let notice = transientNoticesBySceneID.removeValue(
            forKey: sceneID
        ) else { return }
        if let targetSceneID = preferredActiveFeedbackSceneID,
           transientNoticesBySceneID[targetSceneID] == nil {
            transientNoticesBySceneID[targetSceneID] =
                notice.targetingScene(targetSceneID)
        } else {
            unscopedTransientNotice = notice.targetingScene(nil)
        }
    }

    func presentationError(
        for sceneID: UUID?
    ) -> AppPresentationError? {
        if let sceneID,
           let error = presentationErrorsBySceneID[sceneID] {
            return error
        }
        guard let sceneID,
              preferredActiveFeedbackSceneID == sceneID
        else { return nil }
        return unscopedPresentationError
    }

    func presentErrorMessage(
        _ message: String,
        offersSettings: Bool = false,
        in sceneID: UUID?
    ) {
        setPresentationError(
            message,
            offersSettings: offersSettings,
            targetSceneID: sceneID
        )
    }

    func clearError(from sceneID: UUID? = nil) {
        if let sceneID,
           presentationErrorsBySceneID[sceneID] != nil {
            presentationErrorsBySceneID[sceneID] = nil
            return
        }
        unscopedPresentationError = nil
    }

    func releasePresentationErrorTarget(for sceneID: UUID) {
        presentationErrorsBySceneID[sceneID] = nil
    }

    func dismissActionNotice(
        id: UUID? = nil,
        from sceneID: UUID? = nil
    ) {
        if let sceneID,
           let notice = actionNoticesBySceneID[sceneID],
           id == nil || notice.id == id {
            actionNoticesBySceneID[sceneID] = nil
            return
        }
        guard let notice = unscopedActionNotice,
              id == nil || notice.id == id
        else { return }
        unscopedActionNotice = nil
    }

    func performNoticeAction(
        _ notice: AppActionNotice,
        from sceneID: UUID? = nil
    ) async {
        let currentNotice = sceneID.map {
            actionNotice(for: $0)
        } ?? unscopedActionNotice
        guard currentNotice?.id == notice.id
        else { return }
        dismissActionNotice(id: notice.id, from: sceneID)
        await withFeedbackTarget(sceneID) {
            switch notice.action {
            case .restoreTrash(let recordIDs):
                await restoreDeletedDocuments(recordIDs: recordIDs)
            case .undoPageChange(let recordID):
                _ = await undoLastPageChange(recordID: recordID)
            case .undoPageChanges(let recordIDs):
                _ = await undoLastPageChanges(recordIDs: recordIDs)
            }
        }
    }

    func actionNotice(for sceneID: UUID) -> AppActionNotice? {
        actionNoticesBySceneID[sceneID]
            ?? unscopedActionNoticeForScene(sceneID)
    }

    func releaseActionNoticeTarget(for sceneID: UUID) {
        guard let notice = actionNoticesBySceneID.removeValue(
            forKey: sceneID
        ) else { return }
        if let targetSceneID = preferredActiveFeedbackSceneID,
           actionNoticesBySceneID[targetSceneID] == nil {
            actionNoticesBySceneID[targetSceneID] =
                notice.targetingScene(targetSceneID)
        } else {
            unscopedActionNotice = notice.targetingScene(nil)
        }
    }

    private func restoreDeletedDocuments(
        recordIDs: [UUID]
    ) async {
        let requested = Set(recordIDs)
        let records = deletedDocuments.filter {
            requested.contains($0.id)
        }
        guard !records.isEmpty else {
            noticeMessage =
                "That recovery point is no longer available."
                    .localizedUI
            return
        }
        let orderedIDs = records.map(\.id)
        guard let operationTokens =
            acquireExclusiveDocumentOperations(
                recordIDs: orderedIDs
            )
        else { return }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }

        var restoredIDs: Set<UUID> = []
        var restoredRecords: [DocumentRecord] = []
        do {
            restoredRecords = try await store.restoreFromTrash(
                recordIDs: Set(records.map(\.id))
            )
            restoredIDs = Set(restoredRecords.map(\.id))
            deletedDocuments.removeAll {
                restoredIDs.contains($0.id)
            }
            clearActionNotice(referencing: restoredIDs)
            replace(restoredRecords)
            for restored in restoredRecords {
                documentURLs[restored.id] = await store.url(
                    for: restored
                )
            }
            if let analysis = try? await store.loadAnalysis(
                for: restoredIDs
            ) {
                textIndices.merge(analysis.textIndices) {
                    _, restored in restored
                }
                mergeOCRResults(analysis.ocrResults)
                for recordID in restoredIDs
                where analysis.textIndices[recordID] != nil
                    || analysis.ocrResults[recordID] != nil {
                    touchResidentAnalysis(recordID)
                }
                trimResidentAnalysisCache()
            }
            let unavailableCount =
                max(0, requested.count - restoredIDs.count)
            if unavailableCount > 0 {
                noticeMessage = AppLocalization.format(
                    "%lld restored · %lld no longer available",
                    restoredIDs.count,
                    unavailableCount
                )
            } else if restoredIDs.count == 1,
                      let restored = restoredRecords.first {
                noticeMessage = (
                    restored.isDeliveryArtifact
                        ? "Delivery output restored"
                        : "Working copy restored"
                ).localizedUI
            } else {
                noticeMessage = AppLocalization.format(
                    "%lld items restored",
                    restoredIDs.count
                )
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func restoreFromTrash(recordID: UUID) async {
        await restoreDeletedDocuments(recordIDs: [recordID])
    }

    func restoreAllFromTrash() async {
        await restoreDeletedDocuments(
            recordIDs: deletedDocuments.map(\.id)
        )
    }

    func permanentlyDelete(recordID: UUID) async {
        guard let record = deletedDocuments.first(
            where: { $0.id == recordID }
        ) else { return }
        guard let operationToken =
            acquireExclusiveDocumentOperation(recordID: recordID)
        else { return }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            try await store.permanentlyDelete(record)
            deletedDocuments.removeAll { $0.id == recordID }
            clearActionNotice(referencing: Set([recordID]))
            noticeMessage = "Item permanently deleted".localizedUI
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func emptyTrash() async {
        let records = deletedDocuments
        guard !records.isEmpty else { return }
        let orderedIDs = records.map(\.id)
        guard let operationTokens =
            acquireExclusiveDocumentOperations(
                recordIDs: orderedIDs
            )
        else { return }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }
        do {
            let deletedIDs = Set(
                try await store.permanentlyDelete(
                    recordIDs: Set(orderedIDs)
                )
            )
            deletedDocuments.removeAll {
                deletedIDs.contains($0.id)
            }
            clearActionNotice(referencing: deletedIDs)
            noticeMessage = "Trash emptied".localizedUI
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    @discardableResult
    func eraseAllLocalData() async -> Bool {
        guard !hasActiveLocalDataOperations else {
            noticeMessage =
                "Finish or stop active document work before deleting local data."
                    .localizedUI
            return false
        }
        isErasingAllLocalData = true
        let importToken = beginImportOperation()
        defer {
            finishImportOperation(importToken)
            isErasingAllLocalData = false
        }
        deferredBootstrapTask?.cancel()
        deferredBootstrapTask = nil
        deferredBackgroundWorkNeedsRestart = false
        cancelAllDocumentAnalysis()
        officeProductionTask?.cancel()
        officeProductionTask = nil
        officeResourceMonitorTask?.cancel()
        officeResourceMonitorTask = nil
        invalidateMetadataSyncWork()
        metadataSyncAutomaticRetryBlocked = false
        do {
            try await store.eraseAllData()
            try await signatureStore.remove()
            metadataSyncService.clearLocalMetadata()
            if let metadataSyncObserver {
                NotificationCenter.default.removeObserver(
                    metadataSyncObserver
                )
                self.metadataSyncObserver = nil
            }
            UserDefaults.standard.set(
                false,
                forKey: AppPreferences.metadataSyncEnabledKey
            )
            UserDefaults.standard.set(
                false,
                forKey: AppPreferences.dueRemindersEnabledKey
            )
            await LocalDueReminderScheduler.disableAll()
            let removedSharedImports = await Task.detached(
                priority: .utility
            ) {
                do {
                    try ExternalPDFInbox.removeAll()
                    return true
                } catch {
                    return false
                }
            }.value
            try await discardInterruptedTemporaryFiles()
            UserDefaults.standard.removeObject(
                forKey: "library.searchHistory"
            )
            UserDefaults.standard.removeObject(
                forKey: "document.findHistory"
            )

            documents = []
            deletedDocuments = []
            documentURLs = [:]
            refreshTokens = [:]
            replaceOCRResults([:])
            textIndices = [:]
            residentAnalysisOrder = []
            residentAnalysisGeneration = UUID()
            processingDocumentIDs = []
            deliveryProcessingDocumentIDs = []
            batchDeliveryPendingDocumentIDs = []
            operationProgress = [:]
            savedSignatureData = nil
            savedSignatures = []
            selectedSignatureID = nil
            lastBatchDeliveryRun = nil
            officeBatchRuns = [:]
            officeProductionQueue = PDFOfficeProductionQueue()
            officeResourceSnapshot = .initial
            lastOfficeIntegrityReport = nil
            officeIntegrityProgress = nil
            officeDeliveryPackages = []
            officeDeliverySigningKeyID = nil
            lastOfficeReportVerification = nil
            officeExternalMatchProgress = nil
            officeSigningIdentityCard = nil
            officeTrustedSigners = []
            batesBatchReceipts = []
            batesBatchProgress = nil
            batesBatchMutationToken = nil
            isBatesBatchMutationActive = false
            batesReceiptVerificationToken = nil
            isBatesReceiptVerificationActive = false
            batesReceiptVerificationProgress = nil
            batesExternalMatchProgress = nil
            searchMetadataCorpora = [:]
            releaseSearchTextCorpora()
            deliveryPreflightCache = [:]
            releaseEvidenceCaches()
            for undo in pageMutationUndos.values {
                removePageMutationTemporaryItem(
                    containing: undo.backupURL
                )
            }
            pageMutationUndos = [:]
            operationRateWindows = [:]
            exclusiveDocumentOperations = [:]
            importingVerifiedPackageIDs = []
            importingVerifiedVersionArtifactIDs = []
            versionArchiveVerificationGeneration = UUID()
            officeProductionCancelledJobID = nil
            officeIntegrityGeneration = nil
            officeIntegrityRateWindow.reset()
            cancelAllScanImports()
            batesExternalMatchGeneration = UUID()
            officeReportVerificationGeneration = UUID()
            officeExternalMatchGeneration = UUID()
            deferredCommittedImports = [:]
            deferredCommittedImportSourceIdentities = [:]
            deferredCommittedOpenRecordIDs = []
            deferredCommittedOpenSceneIDs = [:]
            committedImportRestoreGeneration = UUID()
            committedImportRestoreTask?.cancel()
            committedImportRestoreTask = nil
            queuedExternalPDFURLs = []
            queuedExternalPDFTargetSceneIDs = [:]
            activeExternalPDFURLIdentities = []
            completedExternalImportSceneIDs = [:]
            externalPDFImportGeneration = UUID()
            externalPDFDeferredOpenGeneration = nil
            externalPDFImportTask = nil
            externalImportProgress = nil
            externalImportKnownTotalCount = 0
            externalImportCompletedItemCount = 0
            externalImportCurrentItemFraction = 0
            externalImportRateWindow.reset()
            activeForegroundImportProgressIDs = []
            foregroundImportProgresses = [:]
            foregroundImportRateWindows = [:]
            isExternalPDFImportActive = false
            externalImportRetryAvailable = false
            externalImportDeferredCount = 0
            externalImportRetryMessage = nil
            retainedEvidenceRevision &+= 1
            externalDocumentHandoffs =
                ExternalDocumentHandoffQueue()
            metadataSyncStatus = metadataSyncDisabledStatus
            actionNoticesBySceneID = [:]
            unscopedActionNotice = nil
            transientNoticesBySceneID = [:]
            unscopedTransientNotice = nil
            noticeMessage = removedSharedImports
                ? "All local PaperPath data deleted".localizedUI
                : "Private library deleted, but queued shared imports could not be removed."
                    .localizedUI
            return removedSharedImports
        } catch {
            present(error)
            return false
        }
    }

    func applyTrashRetention(showNotice: Bool = true) async {
        let defaults = UserDefaults.standard
        let key = "privacy.trashRetentionDays"
        let retentionDays: Int
        if defaults.object(forKey: key) == nil {
            retentionDays = 30
            defaults.set(retentionDays, forKey: key)
        } else {
            retentionDays = defaults.integer(forKey: key)
        }
        guard retentionDays > 0 else { return }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: Date()
        ) ?? Date.distantPast
        let expiredIDs = deletedDocuments.compactMap {
            record -> UUID? in
            guard let deletedAt = record.deletedAt,
                  deletedAt < cutoff
            else { return nil }
            return record.id
        }
        guard !expiredIDs.isEmpty else { return }
        guard let operationTokens =
            acquireExclusiveDocumentOperations(
                recordIDs: expiredIDs
            )
        else { return }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }
        do {
            let purgedIDs = try await store.purgeDeleted(
                before: cutoff
            )
            guard !purgedIDs.isEmpty else { return }
            let purged = Set(purgedIDs)
            deletedDocuments.removeAll { purged.contains($0.id) }
            clearActionNotice(referencing: purged)
            if showNotice {
                noticeMessage = AppLocalization.format(
                    "%lld expired Trash item%@ deleted",
                    purgedIDs.count,
                    purgedIDs.count == 1 ? "" : "s"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func localStorageSnapshot() async -> LocalStorageSnapshot? {
        do {
            return try await store.storageSnapshot()
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func localStorageInventory() async throws
        -> DocumentStoreStorageInventory {
        try Task.checkCancellation()
        return try await store.storageInventory()
    }

    @discardableResult
    func clearSavedPageMatches() async -> Int? {
        guard !isClearingPageMatches else { return nil }
        isClearingPageMatches = true
        defer { isClearingPageMatches = false }
        let comparisonTasks = cancelActiveComparisonWork()
        for task in comparisonTasks {
            _ = try? await task.value
        }
        do {
            try Task.checkCancellation()
            let removedCount =
                try await store.clearPageMatchCorrections()
            comparisonCache.removeAll(keepingCapacity: false)
            comparisonCacheOrder.removeAll(keepingCapacity: false)
            versionComparisonCache.removeAll(
                keepingCapacity: false
            )
            versionComparisonCacheOrder.removeAll(
                keepingCapacity: false
            )
            if !Task.isCancelled {
                noticeMessage = removedCount > 0
                    ? AppLocalization.format(
                        "%lld saved comparison records cleared",
                        removedCount
                    )
                    : "Saved page-match metadata cleared"
                        .localizedUI
            }
            return removedCount
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    @discardableResult
    func createVersionSnapshot(
        recordID: UUID,
        label: String
    ) async -> Bool {
        guard let record = record(id: recordID),
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return false }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            _ = try await store.createVersionSnapshot(
                for: record,
                label: label
            )
            retainedEvidenceRevision &+= 1
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func versionHistory(
        recordID: UUID
    ) async -> [PDFVersionSnapshot] {
        do {
            return try await store.versions(for: recordID)
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
    }

    func versionHistoryOverview(
        recordID: UUID
    ) async -> (
        versions: [PDFVersionSnapshot],
        pinnedStorageSummary: PDFPinnedVersionStorageSummary
    )? {
        do {
            return try await store.versionHistoryOverview(for: recordID)
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func deliveryMilestoneEvidence(
        recordID: UUID,
        receiptID: UUID,
        retainedReceipt: PDFDeliveryReceipt? = nil
    ) async -> PDFDeliveryMilestoneEvidence? {
        guard let record = record(id: recordID),
              let receipt = retainedReceipt ?? record.deliveryReceipt,
              receipt.id == receiptID,
              receipt.isVerified
        else { return .unavailable }
        do {
            let overview = try await store.versionHistoryOverview(
                for: recordID
            )
            try Task.checkCancellation()
            guard let current = self.record(id: recordID),
                  current.contentRevisionID == record.contentRevisionID
            else { return nil }
            let matching = overview.versions
                .filter { $0.matchesDeliveryReceipt(receipt) }
            let linked = matching.filter {
                $0.linkedDeliveryReceiptID == receiptID
                    && $0.isPinnedMilestone
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            let matchingUnlinked = matching.first {
                !$0.isPinnedMilestone
                    || $0.linkedDeliveryReceiptID != receiptID
            }
            let availability: PDFDeliveryMilestoneAvailability
            if !linked.isEmpty {
                availability = .linked
            } else if current.deliveryReceipt?.id == receipt.id,
                      current.hasCurrentDeliveryReceipt {
                availability = .protectCurrent
            } else if current.deliveryReceipt?.id == receipt.id,
                      !matching.isEmpty {
                availability = .protectRecovery
            } else {
                availability = .unavailable
            }
            return PDFDeliveryMilestoneEvidence(
                availability: availability,
                linkedMilestones: linked,
                matchingUnlinkedMilestone: matchingUnlinked,
                pinnedStorageSummary: overview.pinnedStorageSummary
            )
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func protectDeliveryReceiptMilestone(
        recordID: UUID
    ) async -> PDFVersionSnapshot? {
        guard let record = record(id: recordID),
              let receipt = record.deliveryReceipt,
              receipt.isVerified,
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return nil }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            let milestone = try await store
                .protectDeliveryReceiptMilestone(
                    for: record,
                    label: "Protect verified version".localizedUI,
                    milestoneName: (
                        receipt.isDeliveryOutput
                            ? "Verified output"
                            : "Checked editable copy"
                    ).localizedUI
                )
            noticeMessage = "Verified version protected".localizedUI
            retainedEvidenceRevision &+= 1
            return milestone
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func pinnedVersionMilestones() async -> [PDFVersionSnapshot] {
        do {
            return try await store.pinnedVersionMilestones()
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
    }

    func pinnedVersionStorageSummary()
        async -> PDFPinnedVersionStorageSummary? {
        do {
            let milestones = try await store.pinnedVersionMilestones()
            return PDFPinnedVersionStorageSummary.measuring(milestones)
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func unpinAllVersionMilestones() async {
        guard activeComparisonTasks.isEmpty,
              !isUpdatingVersionStorage
        else {
            noticeMessage =
                "Stop active comparisons before changing version retention."
                    .localizedUI
            return
        }
        isUpdatingVersionStorage = true
        defer { isUpdatingVersionStorage = false }
        do {
            try Task.checkCancellation()
            let count = try await store.unpinAllVersionMilestones()
            retainedEvidenceRevision &+= 1
            versionComparisonCache.removeAll(
                keepingCapacity: false
            )
            versionComparisonCacheOrder.removeAll(
                keepingCapacity: false
            )
            try Task.checkCancellation()
            noticeMessage = AppLocalization.format(
                "%lld milestone%@ returned to standard retention",
                count,
                count == 1 ? "" : "s"
            )
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func setVersionMilestonePinned(
        _ milestone: PDFVersionSnapshot,
        pinned: Bool
    ) async {
        guard let operationToken =
                acquireExclusiveDocumentOperation(
                    recordID: milestone.documentID
                )
        else { return }
        defer {
            finishExclusiveDocumentOperation(
                recordID: milestone.documentID,
                token: operationToken
            )
        }
        do {
            try Task.checkCancellation()
            _ = try await store.updateVersionMilestone(
                snapshotID: milestone.id,
                recordID: milestone.documentID,
                name: milestone.milestoneName,
                pinned: pinned,
                linkedDeliveryReceiptID:
                    pinned
                        ? milestone.linkedDeliveryReceiptID
                        : nil
            )
            retainedEvidenceRevision &+= 1
            invalidateVersionComparisonCaches(
                for: Set([milestone.documentID])
            )
            try Task.checkCancellation()
            noticeMessage = pinned
                ? "Milestone version protected".localizedUI
                : "Milestone returned to standard retention".localizedUI
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func makePinnedVersionArchive(
        recordID: UUID? = nil,
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void = { _ in }
    ) async -> URL? {
        do {
            let allMilestones = try await store
                .pinnedVersionMilestones()
            try Task.checkCancellation()
            let milestones = allMilestones.filter {
                recordID == nil || $0.documentID == recordID
            }
            guard !milestones.isEmpty else {
                throw PaperPathError.insufficientSelection(
                    "Pin at least one version milestone before archiving."
                )
            }
            let archiveBytes = saturatedByteTotal(
                milestones.lazy.map { max(0, $0.byteCount) }
            )
            let requiredArchiveBytes = saturatedByteTotal(
                CollectionOfOne(archiveBytes),
                reserve: 16 * 1_024 * 1_024
            )
            if let available = try await store
                .availableCapacityForOfficeProduction(),
               available < requiredArchiveBytes {
                throw PaperPathError.insufficientStorage
            }
            try Task.checkCancellation()

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "PaperPath-Version-Archive-\(UUID().uuidString)",
                    isDirectory: true
                )
            try LocalFileSecurity.prepareProtectedDirectory(
                at: directory
            )
            let manifestURL = directory.appendingPathComponent(
                "PaperPath-version-manifest.json"
            )
            let destination = directory.appendingPathComponent(
                recordID.flatMap { self.record(id: $0)?.displayName }
                    .map { "\(safeExportName($0))-milestones.zip" }
                    ?? "PaperPath-pinned-milestones.zip"
            )

            do {
                var sources: [OfficeBatchArchiveSource] = []
                var entries: [PDFVersionArchiveManifest.Entry] = []
                sources.reserveCapacity(milestones.count + 1)
                entries.reserveCapacity(milestones.count)
                for (index, milestone) in milestones.enumerated() {
                    try Task.checkCancellation()
                    let sourceURL = try await store.versionFileURL(
                        snapshotID: milestone.id,
                        recordID: milestone.documentID
                    )
                    let documentName = record(
                        id: milestone.documentID
                    )?.displayName ?? "Document"
                    let archiveName = String(
                        format: "%02d-%@-%@.pdf",
                        index + 1,
                        safeExportName(documentName),
                        milestone.id.uuidString
                    )
                    sources.append(
                        OfficeBatchArchiveSource(
                            sourceURL: sourceURL,
                            archiveName: archiveName
                        )
                    )
                    entries.append(
                        PDFVersionArchiveManifest.Entry(
                            fileName: archiveName,
                            documentID: milestone.documentID,
                            snapshotID: milestone.id,
                            title: milestone.displayTitle,
                            createdAt: milestone.createdAt,
                            byteCount: milestone.byteCount,
                            pageCount: milestone.pageCount,
                            sha256: milestone.contentFingerprint,
                            linkedDeliveryReceiptID:
                                milestone.linkedDeliveryReceiptID
                        )
                    )
                }

                let archiveCreatedAt = try await store
                    .trustedEvidenceIssuanceDate()
                let manifest = PDFVersionArchiveManifest(
                    schema: PDFVersionArchiveManifest.currentSchema,
                    createdAt: archiveCreatedAt,
                    entries: entries
                )
                let signedManifest = try await store
                    .signVersionArchiveManifest(manifest)
                try Task.checkCancellation()
                officeDeliverySigningKeyID =
                    signedManifest.signature.keyID
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(signedManifest).write(
                    to: manifestURL,
                    options: .atomic
                )
                try LocalFileSecurity.requireCompleteProtection(
                    to: manifestURL
                )
                sources.append(
                    OfficeBatchArchiveSource(
                        sourceURL: manifestURL,
                        archiveName: manifestURL.lastPathComponent
                    )
                )
                let archiveSources = sources
                let archiveTask = Task.detached(
                    priority: .userInitiated
                ) {
                    try OfficeBatchArchiveService().createArchive(
                        sources: archiveSources,
                        destination: destination
                    ) { update in
                        Task { @MainActor in
                            progress(update)
                        }
                    }
                }
                try await withTaskCancellationHandler {
                    try await archiveTask.value
                } onCancel: {
                    archiveTask.cancel()
                }
                try Task.checkCancellation()
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: manifestURL)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            present(error)
            return nil
        }
    }

    func verifyPinnedVersionArchive(
        at sourceURL: URL,
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void = { _ in }
    ) async -> PDFVersionArchiveVerificationReport? {
        let generation = UUID()
        versionArchiveVerificationGeneration = generation
        let extractionDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.verifiedVersionArchivePrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        let hasScopedAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: extractionDirectory
            )
            let timeAnchor = await store.deliveryTimeAnchor()
            let worker = Task.detached(priority: .userInitiated) {
                try PDFVersionArchiveVerificationService(
                    timeAnchor: timeAnchor
                )
                    .verifyCoordinated(
                        archiveURL: sourceURL,
                        extractionDirectory: extractionDirectory
                    ) { update in
                        Task { @MainActor in
                            progress(update)
                        }
                    }
            }
            let rawReport = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  versionArchiveVerificationGeneration == generation
            else {
                throw CancellationError()
            }
            let resolvedReport = try await store
                .resolveVersionArchiveTrust(rawReport)
            guard !Task.isCancelled,
                  versionArchiveVerificationGeneration == generation
            else {
                throw CancellationError()
            }
            officeTrustedSigners = (
                try? await store.loadOfficeTrustedSigners()
            ) ?? officeTrustedSigners
            guard !Task.isCancelled,
                  versionArchiveVerificationGeneration == generation
            else {
                throw CancellationError()
            }
            if !resolvedReport.canRecoverArtifacts {
                try? FileManager.default.removeItem(
                    at: extractionDirectory
                )
            }
            return resolvedReport
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: extractionDirectory)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: extractionDirectory)
            guard !Task.isCancelled else { return nil }
            present(error)
            return nil
        }
    }

    func importVerifiedVersionArchiveArtifact(
        _ report: PDFVersionArchiveVerificationReport,
        itemID: UUID
    ) async -> DocumentRecord? {
        guard report.canRecoverArtifacts,
              report.verifiedArtifact(for: itemID) != nil
        else {
            present(
                PaperPathError.outputVerificationFailed(
                    "the signed archive must pass verification before recovery"
                )
            )
            return nil
        }
        guard importingVerifiedVersionArtifactIDs.insert(itemID)
                .inserted
        else {
            noticeMessage =
                "This milestone is already being recovered".localizedUI
            return nil
        }
        let importToken = beginImportOperation()
        defer {
            importingVerifiedVersionArtifactIDs.remove(itemID)
            finishImportOperation(importToken)
        }

        do {
            let imported = try await store
                .importVerifiedVersionArchiveArtifact(
                    report,
                    itemID: itemID
                )
            guard !Task.isCancelled else {
                deferredCommittedImports[imported.id] = imported
                return await restoreCommittedImportIfForeground(
                    imported
                )
            }
            let wasAlreadyImported = record(id: imported.id) != nil
            replace(imported)
            documentURLs[imported.id] = await store.url(for: imported)
            noticeMessage = wasAlreadyImported
                ? "This exact milestone is already in PaperPath".localizedUI
                : "Milestone recovered as a private copy".localizedUI
            if !wasAlreadyImported {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    await self?.analyzeDocument(recordID: imported.id)
                }
            }
            return self.record(id: imported.id) ?? imported
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func discardVerifiedVersionArchiveArtifacts(
        in report: PDFVersionArchiveVerificationReport
    ) async {
        guard let url = report.verifiedArtifacts.first?.url else {
            return
        }
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: [
                    PaperPathTemporaryArtifact
                        .verifiedVersionArchivePrefix
                ]
            )
        }.value
    }

    func discardVersionArchive(at url: URL) async {
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: ["PaperPath-Version-Archive-"]
            )
        }.value
    }

    func trustVersionArchiveSigner(
        _ report: PDFVersionArchiveVerificationReport
    ) async -> PDFVersionArchiveVerificationReport? {
        do {
            officeTrustedSigners = try await store
                .trustVersionArchiveSigner(report)
            let name = officeTrustedSigners.first {
                $0.keyID == report.signerKeyID
            }?.displayName
            noticeMessage = "Signer trusted on this device".localizedUI
            return report.resolvingTrust(
                .trusted,
                trustedSignerName: name
            )
        } catch {
            present(error)
            return nil
        }
    }

    func verifyDeliveryPackage(
        at sourceURL: URL,
        presentsFailure: Bool = true,
        onFailure: @escaping @MainActor @Sendable (
            PDFDeliveryPackageVerificationFailure
        ) -> Void = { _ in },
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void
    ) async -> PDFDeliveryPackageVerificationReport? {
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(PaperPathTemporaryArtifact.verifiedDeliveryPackagePrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        let hasScopedAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: extractionDirectory
            )
            let timeAnchor = await store.deliveryTimeAnchor()
            let worker = Task.detached(priority: .userInitiated) {
                try PDFVersionArchiveVerificationService(
                    timeAnchor: timeAnchor
                )
                    .verifyDeliveryPackageCoordinated(
                        archiveURL: sourceURL,
                        extractionDirectory: extractionDirectory
                    ) { update in
                        Task { @MainActor in
                            progress(update)
                        }
                    }
            }
            let rawReport = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            let resolvedReport = try await store
                .resolveDeliveryPackageTrust(rawReport)
            try Task.checkCancellation()
            officeTrustedSigners = (
                try? await store.loadOfficeTrustedSigners()
            ) ?? officeTrustedSigners
            try Task.checkCancellation()
            if resolvedReport.verifiedArtifactURL == nil {
                try? FileManager.default.removeItem(
                    at: extractionDirectory
                )
            }
            return resolvedReport
        } catch is CancellationError {
            try? FileManager.default.removeItem(
                at: extractionDirectory
            )
            return nil
        } catch {
            try? FileManager.default.removeItem(
                at: extractionDirectory
            )
            guard !Task.isCancelled else { return nil }
            onFailure(
                deliveryPackageVerificationFailure(for: error)
            )
            if presentsFailure {
                present(error)
            }
            return nil
        }
    }

    private func deliveryPackageVerificationFailure(
        for error: Error
    ) -> PDFDeliveryPackageVerificationFailure {
        if LocalFileSecurity.isInsufficientStorageError(error) {
            return PDFDeliveryPackageVerificationFailure(
                kind: .storage,
                detail: PaperPathError.insufficientStorage
                    .errorDescription
                    ?? "Free some storage and try again."
            )
        }

        if let paperPathError = error as? PaperPathError {
            switch paperPathError {
            case .fileTooLarge:
                return PDFDeliveryPackageVerificationFailure(
                    kind: .sourceLimit,
                    detail:
                        "Delivery packages larger than 1 GB cannot be verified on this device."
                )
            case .outputVerificationFailed(let reason):
                let lowercasedReason = reason.lowercased()
                let isAccessFailure =
                    lowercasedReason.contains("coordinated")
                    || lowercasedReason.contains("readable zip")
                    || lowercasedReason.contains("unavailable")
                return PDFDeliveryPackageVerificationFailure(
                    kind: isAccessFailure ? .access : .integrity,
                    detail: paperPathError.errorDescription
                        ?? reason.localizedUI
                )
            case .insufficientStorage:
                return PDFDeliveryPackageVerificationFailure(
                    kind: .storage,
                    detail: paperPathError.errorDescription
                        ?? "Free some storage and try again."
                )
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            || nsError.domain == NSPOSIXErrorDomain {
            return PDFDeliveryPackageVerificationFailure(
                kind: .access,
                detail:
                    "Keep the package downloaded in Files, then choose it again."
            )
        }

        return PDFDeliveryPackageVerificationFailure(
            kind: .unknown,
            detail: (error as? LocalizedError)?.errorDescription
                ?? "PaperPath could not read this delivery package."
        )
    }

    func importVerifiedDeliveryArtifact(
        _ report: PDFDeliveryPackageVerificationReport
    ) async -> DocumentRecord? {
        guard report.status == .verified,
              report.canOpenArtifact
        else {
            present(
                PaperPathError.outputVerificationFailed(
                    "the delivery package must pass verification before import"
                )
            )
            return nil
        }
        guard importingVerifiedPackageIDs.insert(report.packageID)
                .inserted
        else {
            noticeMessage =
                "This verified PDF is already being imported".localizedUI
            return nil
        }
        let importToken = beginImportOperation()
        defer {
            importingVerifiedPackageIDs.remove(report.packageID)
            finishImportOperation(importToken)
        }

        do {
            let imported = try await store
                .importVerifiedDeliveryArtifact(report)
            guard !Task.isCancelled else {
                deferredCommittedImports[imported.id] = imported
                return await restoreCommittedImportIfForeground(
                    imported
                )
            }
            let wasAlreadyImported = record(id: imported.id) != nil
            replace(imported)
            documentURLs[imported.id] = await store.url(for: imported)
            noticeMessage = wasAlreadyImported
                ? "This exact verified PDF is already in PaperPath"
                    .localizedUI
                : "Verified PDF imported as a private copy".localizedUI
            if !wasAlreadyImported {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    await self?.analyzeDocument(recordID: imported.id)
                }
            }
            return self.record(id: imported.id) ?? imported
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func prepareVerifiedDeliveryArtifactShareCopy(
        _ report: PDFDeliveryPackageVerificationReport,
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void = { _ in }
    ) async -> URL? {
        var preparedURL: URL?
        do {
            preparedURL = try await store
                .prepareVerifiedDeliveryArtifactShareCopy(
                    report
                ) { update in
                    Task { @MainActor in
                        progress(update)
                    }
                }
            try Task.checkCancellation()
            return preparedURL
        } catch is CancellationError {
            if let preparedURL {
                await discardFilesExportCopy(at: preparedURL)
            }
            return nil
        } catch {
            if let preparedURL {
                await discardFilesExportCopy(at: preparedURL)
            }
            present(error)
            return nil
        }
    }

    func discardVerifiedDeliveryArtifact(at url: URL) async {
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: [
                    PaperPathTemporaryArtifact
                        .verifiedDeliveryPackagePrefix
                ]
            )
        }.value
    }

    func trustDeliveryPackageSigner(
        _ report: PDFDeliveryPackageVerificationReport
    ) async -> PDFDeliveryPackageVerificationReport? {
        do {
            officeTrustedSigners = try await store
                .trustDeliveryPackageSigner(report)
            let name = officeTrustedSigners.first {
                $0.keyID == report.signerKeyID
            }?.displayName
            noticeMessage = "Signer trusted on this device".localizedUI
            return report.resolvingTrust(
                .trusted,
                trustedSignerName: name
            )
        } catch {
            present(error)
            return nil
        }
    }

    func versionFileURL(
        recordID: UUID,
        snapshotID: UUID
    ) async -> URL? {
        do {
            return try await store.versionFileURL(
                snapshotID: snapshotID,
                recordID: recordID
            )
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func updateVersionMilestone(
        recordID: UUID,
        snapshotID: UUID,
        name: String?,
        pinned: Bool,
        linksCurrentDeliveryReceipt: Bool
    ) async -> [PDFVersionSnapshot]? {
        guard let operationToken =
                acquireExclusiveDocumentOperation(
                    recordID: recordID
                )
        else { return nil }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            try Task.checkCancellation()
            guard let version = try await store.versions(
                for: recordID
            ).first(where: { $0.id == snapshotID }) else {
                throw PaperPathError.storageFailure(
                    "The selected recovery version is unavailable."
                )
            }
            let linkedReceiptID: UUID?
            if linksCurrentDeliveryReceipt {
                if let receipt = record(id: recordID)?.deliveryReceipt,
                   version.matchesDeliveryReceipt(receipt) {
                    linkedReceiptID = receipt.id
                } else if let retained = version
                    .linkedDeliveryReceiptID {
                    linkedReceiptID = retained
                } else {
                    throw PaperPathError.insufficientSelection(
                        "Only a version matching the delivery receipt can be linked."
                    )
                }
            } else {
                linkedReceiptID = nil
            }
            try Task.checkCancellation()
            let versions = try await store.updateVersionMilestone(
                snapshotID: snapshotID,
                recordID: recordID,
                name: name,
                pinned: pinned,
                linkedDeliveryReceiptID: linkedReceiptID
            )
            retainedEvidenceRevision &+= 1
            invalidateVersionComparisonCaches(
                for: Set([recordID])
            )
            if !Task.isCancelled {
                noticeMessage = pinned
                    ? "Milestone version protected".localizedUI
                    : "Version details updated".localizedUI
            }
            return versions
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func compareVersion(
        recordID: UUID,
        snapshotID: UUID,
        manualMatches: [PDFManualPageMatch]? = nil,
        progress: @escaping @MainActor @Sendable (
            PDFComparisonProgress
        ) -> Void = { _ in }
    ) async throws -> PDFChangeReview {
        guard !isClearingPageMatches,
              !isUpdatingVersionStorage,
              !isErasingAllLocalData
        else {
            throw PaperPathError.insufficientSelection(
                "Local storage is being updated. Try the comparison again when it finishes."
            )
        }
        guard !isProcessing(recordID) else {
            throw PaperPathError.insufficientSelection(
                "This PDF is busy. Wait for the current task to finish or stop it."
            )
        }
        return try await performTrackedComparison(
            recordIDs: [recordID]
        ) {
            workGeneration in
            try await self.compareVersionCore(
                recordID: recordID,
                snapshotID: snapshotID,
                manualMatches: manualMatches,
                workGeneration: workGeneration,
                progress: progress
            )
        }
    }

    private func compareVersionCore(
        recordID: UUID,
        snapshotID: UUID,
        manualMatches: [PDFManualPageMatch]?,
        workGeneration: UUID,
        progress: @escaping @MainActor @Sendable (
            PDFComparisonProgress
        ) -> Void
    ) async throws -> PDFChangeReview {
        guard let currentRecord = record(id: recordID),
              let currentURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        let key = PDFVersionComparisonCacheKey(
            recordID: recordID,
            snapshotID: snapshotID,
            currentRevisionID: currentRecord.contentRevisionID
        )
        if manualMatches == nil,
           let cached = versionComparisonCache[key] {
            touchVersionComparisonCache(key)
            progress(
                PDFComparisonProgress(
                    stage: .complete,
                    completedPageCount: cached.comparedPageCount,
                    totalPageCount: cached.comparedPageCount,
                    fractionCompleted: 1
                )
            )
            return cached
        }
        guard let snapshot = try await store.versions(
            for: recordID
        ).first(where: { $0.id == snapshotID }) else {
            throw PaperPathError.storageFailure(
                "The selected recovery version is unavailable."
            )
        }
        let historicalURL = try await store.versionFileURL(
            snapshotID: snapshotID,
            recordID: recordID
        )
        let correctionLookup:
            PDFManualPageMatchCorrectionLookup =
            if manualMatches == nil {
                try await store.pageMatchCorrection(
                    context: .versionSnapshot,
                    sourceDocumentID: recordID,
                    sourceRevisionID:
                        snapshot.contentRevisionID,
                    revisedDocumentID: recordID,
                    revisedRevisionID:
                        currentRecord.contentRevisionID,
                    versionSnapshotID: snapshotID,
                    sourcePageCount: snapshot.pageCount,
                    revisedPageCount:
                        currentRecord.profile.pageCount
                )
            } else {
                .none
            }
        let restoredCorrection = correctionLookup.correction
        let resolvedManualMatches =
            manualMatches
                ?? restoredCorrection?.matches
                ?? []
        let comparedReview = try await comparisonCoordinator.compare(
            sourceURL: historicalURL,
            revisedURL: currentURL,
            manualMatches: resolvedManualMatches
        ) { update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeComparisonTasks[workGeneration]
                        != nil
                else { return }
                progress(update)
            }
        }
        try Task.checkCancellation()
        guard activeComparisonTasks[workGeneration] != nil,
              record(id: recordID)?.contentRevisionID
                == currentRecord.contentRevisionID
        else {
            throw CancellationError()
        }
        let persistence:
            PDFManualPageMatchPersistence?
        if manualMatches != nil {
            if comparedReview.resolvedManualPageMatches.isEmpty {
                try await store.removePageMatchCorrection(
                    context: .versionSnapshot,
                    sourceDocumentID: recordID,
                    revisedDocumentID: recordID,
                    versionSnapshotID: snapshotID
                )
                persistence = nil
            } else {
                let evictedCount =
                    try await store.savePageMatchCorrection(
                        PDFManualPageMatchCorrection(
                            context: .versionSnapshot,
                            sourceDocumentID: recordID,
                            sourceRevisionID:
                                snapshot.contentRevisionID,
                            revisedDocumentID: recordID,
                            revisedRevisionID:
                                currentRecord.contentRevisionID,
                            versionSnapshotID: snapshotID,
                            sourcePageCount: snapshot.pageCount,
                            revisedPageCount:
                                currentRecord.profile.pageCount,
                            matches: comparedReview
                                .resolvedManualPageMatches,
                            updatedAt: Date()
                        )
                    )
                if evictedCount > 0 {
                    noticeMessage = AppLocalization.format(
                        "%lld older saved comparison record%@ removed to stay within the local limit",
                        evictedCount,
                        evictedCount == 1 ? "" : "s"
                    )
                }
                persistence = .savedOnDevice
            }
        } else {
            persistence = restoredCorrection == nil
                ? nil
                : .restoredFromDevice
            if correctionLookup.discardedStaleCorrection {
                noticeMessage =
                    "Saved page matches were reset because the working copy or saved version changed."
                        .localizedUI
            }
        }
        try Task.checkCancellation()
        guard activeComparisonTasks[workGeneration] != nil else {
            throw CancellationError()
        }
        let review = comparedReview
            .markingManualPageMatchPersistence(persistence)
        versionComparisonCache[key] = review
        touchVersionComparisonCache(key)
        trimVersionComparisonCache()
        return review
    }

    private func touchVersionComparisonCache(
        _ key: PDFVersionComparisonCacheKey
    ) {
        versionComparisonCacheOrder.removeAll { $0 == key }
        versionComparisonCacheOrder.append(key)
    }

    private func trimVersionComparisonCache() {
        var estimatedBytes = versionComparisonCache.values.reduce(
            Int64.zero
        ) {
            saturatedCacheCost(
                $0,
                $1.estimatedCacheByteCount
            )
        }
        while versionComparisonCacheOrder.count > 1 {
            let exceedsCount =
                versionComparisonCacheOrder.count > 4
            let exceedsBytes =
                estimatedBytes
                    > Self.maximumVersionComparisonCacheBytes
            guard exceedsCount || exceedsBytes else { break }
            let oldest = versionComparisonCacheOrder.removeFirst()
            if let removed = versionComparisonCache.removeValue(
                forKey: oldest
            ) {
                estimatedBytes = max(
                    0,
                    estimatedBytes
                        - removed.estimatedCacheByteCount
                )
            }
        }
    }

    private func releaseEvidenceCaches() {
        comparisonCache.removeAll(keepingCapacity: false)
        comparisonCacheOrder.removeAll(keepingCapacity: false)
        pageAssessmentCache.removeAll(keepingCapacity: false)
        pageAssessmentCacheOrder.removeAll(keepingCapacity: false)
        versionComparisonCache.removeAll(keepingCapacity: false)
        versionComparisonCacheOrder.removeAll(keepingCapacity: false)
        deliveryPreflightCache.removeAll(keepingCapacity: false)
        releaseSearchTextCorpora()
        ocrService.releaseCachedResources()
        scanRenderer.releaseCachedResources()
    }

    private func handleMemoryPressure() {
        cancelAllScanImports()
        cancelAllDocumentAnalysis()
        cancelActiveComparisonWork()
        cancelBackgroundCancellableDocumentOperations()
        if officeProductionTask != nil
            || officeProductionQueue.hasRunnableJobs {
            officeProductionQueue.isSuspended = true
            officeProductionCancelledJobID = nil
            officeProductionTask?.cancel()
            officeResourceMonitorTask?.cancel()
            officeResourceMonitorTask = nil
        }
        releaseEvidenceCaches()
        releaseResidentAnalysis(retainingRecordCount: 0)
    }

    private func cancelAllScanImports() {
        scanImportGenerations.removeAll(keepingCapacity: false)
        for task in scanRenderTasks.values {
            task.cancel()
        }
        scanRenderTasks.removeAll(keepingCapacity: false)
        scanImportProgresses.removeAll(keepingCapacity: false)
    }

    func checkpointTrustedTime() {
        trustedTimeCheckpointTask?.cancel()
        let generation = UUID()
        trustedTimeCheckpointGeneration = generation
        trustedTimeCheckpointTask = Task { @MainActor [weak self, store] in
            guard !Task.isCancelled else { return }
            await store.checkpointTrustedTime()
            guard let self,
                  self.trustedTimeCheckpointGeneration == generation
            else { return }
            self.trustedTimeCheckpointTask = nil
        }
    }

    func releaseTransientResourcesForBackground() {
        checkpointTrustedTime()
        cancelAllReadingPositionUpdates()
        initialBootstrapTask?.cancel()
        deferredBootstrapTask?.cancel()
        deferredBootstrapTask = nil
        deferredBackgroundWorkNeedsRestart = false
        committedImportRestoreGeneration = UUID()
        committedImportRestoreTask?.cancel()
        committedImportRestoreTask = nil
        pauseMetadataSyncForBackground()
        externalPDFImportTask?.cancel()
        handleMemoryPressure()
    }

    @discardableResult
    func restoreVersion(
        recordID: UUID,
        snapshotID: UUID
    ) async -> Bool {
        guard let record = record(id: recordID),
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return false }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            let store = self.store
            let snapshotTask = Task {
                try await store.createVersionSnapshot(
                    for: record,
                    label: "Restore version".localizedUI,
                    preservingVersionID: snapshotID
                )
            }
            let currentVersion =
                try await valuePropagatingExclusiveCancellation(
                    from: snapshotTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            let restoreTask = Task {
                try await store.restoreVersion(
                    snapshotID: snapshotID,
                    for: record
                )
            }
            let restored =
                try await valueCompletingAtomicExclusiveCommit(
                    from: restoreTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            replace(restored)
            textIndices[recordID] = nil
            setOCRResult(nil, for: recordID)
            refreshTokens[recordID, default: 0] += 1
            if let undo = pageMutationUndos.removeValue(
                forKey: recordID
            ) {
                removePageMutationTemporaryItem(
                    containing: undo.backupURL
                )
            }
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            let retentionTask = Task {
                try await store.enforceVersionRetention(
                    preserving: currentVersion.id
                )
            }
            _ = try? await valuePropagatingExclusiveCancellation(
                from: retentionTask,
                recordID: recordID,
                operationToken: operationToken
            )
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            await analyzeDocument(recordID: recordID)
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            noticeMessage = "Version restored · current state saved"
                .localizedUI
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func recognizeText(
        recordID: UUID,
        configuration: OCRRecognitionConfiguration = .automatic
    ) async -> Bool {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID],
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return false }
        operationProgress[recordID] = PDFOperationProgress(
            label: "Recognizing text".localizedUI,
            fractionCompleted: 0
        )
        do {
            try markExclusiveDocumentOperationBackgroundCancellable(
                recordID: recordID,
                token: operationToken
            )
        } catch {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
            return false
        }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
        }
        do {
            let service = ocrService
            let appliedConfiguration = try service.validated(configuration)
            let identity = OCRCheckpointIdentity(
                recordID: recordID,
                revisionID: record.contentRevisionID,
                pageCount: record.profile.pageCount,
                configuration: appliedConfiguration
            )
            let checkpoint = try await store.prepareOCRCheckpoint(identity)
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID, token: operationToken
            )
            let checkpointStore = store
            let recognitionTask = Task {
                try await service.recognize(
                    url: url,
                    configuration: appliedConfiguration,
                    checkpoint: checkpoint,
                    onPageCompleted: { page in
                        try await checkpointStore.saveOCRCheckpointPage(page, identity: identity)
                    }
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.exclusiveDocumentOperationIsCurrent(
                                recordID: recordID,
                                token: operationToken
                              )
                        else { return }
                        self.updateOperationFraction(
                            recordID: recordID,
                            label: "Recognizing text".localizedUI,
                            fractionCompleted: value
                        )
                    }
                }
            }
            let result = try await valuePropagatingExclusiveCancellation(
                from: recognitionTask,
                recordID: recordID,
                operationToken: operationToken
            )
            let textService = textIndexService
            let understandingService = understandingService
            let analysisTask = Task.detached(
                priority: .userInitiated
            ) {
                try Task.checkCancellation()
                let index = textService.index(from: result)
                try Task.checkCancellation()
                let brief = understandingService.analyze(
                    index: index,
                    profile: record.profile
                )
                try Task.checkCancellation()
                return (index, brief)
            }
            let (index, brief) =
                try await valuePropagatingExclusiveCancellation(
                    from: analysisTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            )
            guard let currentRecord = self.record(id: recordID),
                  currentRecord.contentRevisionID
                    == record.contentRevisionID
            else {
                throw CancellationError()
            }
            let store = self.store
            let saveTask = Task {
                try await store.saveAnalysis(
                    currentRecord,
                    brief: brief,
                    textIndex: index,
                    ocrResult: result
                )
            }
            let updated =
                try await valueCompletingAtomicExclusiveCommit(
                    from: saveTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            setOCRResult(result, for: recordID)
            textIndices[recordID] = index
            replace(updated)
            try? await store.removeOCRCheckpoint(identity)
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            let hasUsefulText = hasUsefulRecognizedText(result)
            let completionTask = Task {
                try await store.setActionCompletion(
                    updated,
                    action: .recognizeText,
                    completed: hasUsefulText
                )
            }
            let completed =
                try await valueCompletingAtomicExclusiveCommit(
                    from: completionTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            replace(
                completed,
                invalidatesSearchText: false
            )
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            noticeMessage = (
                hasUsefulText
                    ? "Text indexed on device"
                    : "No readable text found"
            ).localizedUI
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func savedOCRPageCount(
        recordID: UUID,
        configuration: OCRRecognitionConfiguration
    ) async throws -> Int {
        let applied = try ocrService.validated(configuration)
        let summary = try await ocrRecoverySummary(recordID: recordID)
        return summary?.identity.configuration == applied ? summary?.completedPageCount ?? 0 : 0
    }

    func ocrRecoverySummary(recordID: UUID) async throws -> OCRRecoverySummary? {
        guard UIApplication.shared.isProtectedDataAvailable,
              let record = record(id: recordID), !record.profile.isLocked else { return nil }
        let summary = try await store.loadOCRRecoverySummary(for: record)
        try Task.checkCancellation()
        guard UIApplication.shared.isProtectedDataAvailable,
              self.record(id: recordID)?.contentRevisionID == record.contentRevisionID else {
            throw CancellationError()
        }
        if let summary {
            guard try ocrService.validated(summary.identity.configuration)
                == summary.identity.configuration else { return nil }
        }
        return summary
    }

#if DEBUG
    func loadWorkflowDiagnosticSnapshot() async throws {
        applyBootstrapSnapshot(try await store.loadBootstrapSnapshot())
        try await restoreBatchDeliveryRun()
        didBootstrap = true
        isLoading = false
    }
#endif

    func correctRecognizedText(
        recordID: UUID,
        pageIndex: Int,
        blockID: UUID,
        expectedBlock: OCRTextBlock? = nil,
        replacement: String
    ) async -> Bool {
        let normalized = replacement
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty,
              normalized.count <= 500,
              normalized.utf8.count <= 2_048,
              normalized.unicodeScalars.allSatisfy({
                  let codePoint = $0.value
                  let isBidirectionalControl =
                      (0x202A...0x202E).contains(codePoint)
                          || (0x2066...0x2069).contains(codePoint)
                  return !CharacterSet.controlCharacters.contains($0)
                      && !CharacterSet.illegalCharacters.contains($0)
                      && !isBidirectionalControl
              })
        else { return false }
        await ensureAnalysisLoaded(for: recordID)
        guard !Task.isCancelled,
              let record = record(id: recordID),
              let result = ocrResults[recordID],
              let pageOffset = result.pages.firstIndex(where: {
                  $0.pageIndex == pageIndex
              }),
              let blockOffset = result.pages[pageOffset]
                .blocks.firstIndex(where: {
                    $0.id == blockID
                }),
              expectedBlock.map({
                  result.pages[pageOffset].blocks[blockOffset] == $0
              }) ?? true,
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return false }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }

        var blocks = result.pages[pageOffset].blocks
        let source = blocks[blockOffset]
        blocks[blockOffset] = OCRTextBlock(
            id: source.id,
            text: normalized,
            confidence: 1,
            normalizedX: source.normalizedX,
            normalizedY: source.normalizedY,
            normalizedWidth: source.normalizedWidth,
            normalizedHeight: source.normalizedHeight,
            isUserCorrected: true
        )
        let totalWeight = blocks.reduce(0) {
            $0 + max(1, $1.text.count)
        }
        let confidence = blocks.reduce(0) {
            $0 + $1.confidence * Double(max(1, $1.text.count))
        } / Double(max(1, totalWeight))
        var pages = result.pages
        pages[pageOffset] = OCRPageResult(
            pageIndex: pageIndex,
            text: blocks.map(\.text).joined(separator: "\n"),
            confidence: confidence,
            blocks: blocks,
            recognitionPass: result.pages[pageOffset]
                .recognitionPass
        )
        let updatedResult = OCRResult(
            pages: pages,
            configuration: result.configuration
        )
        do {
            let textService = textIndexService
            let understandingService = understandingService
            let analysisTask = Task.detached(
                priority: .userInitiated
            ) {
                try Task.checkCancellation()
                let index = textService.index(from: updatedResult)
                try Task.checkCancellation()
                let brief = understandingService.analyze(
                    index: index,
                    profile: record.profile
                )
                try Task.checkCancellation()
                return (index, brief)
            }
            let (index, brief) =
                try await valuePropagatingExclusiveCancellation(
                    from: analysisTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            guard let currentRecord = self.record(id: recordID),
                  currentRecord.contentRevisionID
                    == record.contentRevisionID
            else {
                throw CancellationError()
            }
            let store = self.store
            let saveTask = Task {
                try await store.saveAnalysis(
                    currentRecord,
                    brief: brief,
                    textIndex: index,
                    ocrResult: updatedResult
                )
            }
            let updated =
                try await valueCompletingAtomicExclusiveCommit(
                    from: saveTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            setOCRResult(updatedResult, for: recordID)
            textIndices[recordID] = index
            replace(updated)
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            noticeMessage = "Recognition correction saved locally"
                .localizedUI
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func combineDocuments(
        recordIDs: [UUID],
        name: String
    ) async -> DocumentRecord? {
        var seenRecordIDs = Set<UUID>()
        let uniqueRecordIDs = recordIDs.filter {
            seenRecordIDs.insert($0).inserted
        }
        let records = uniqueRecordIDs.compactMap(record(id:))
        let urls = records.compactMap { documentURLs[$0.id] }
        guard records.count >= 2,
              records.count == uniqueRecordIDs.count,
              urls.count == records.count
        else {
            present(
                PaperPathError.insufficientSelection(
                    "Choose at least two available PDFs to combine."
                )
            )
            return nil
        }
        guard let operationTokens =
                acquireExclusiveDocumentOperations(
                    recordIDs: uniqueRecordIDs
                )
        else { return nil }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }

        let importToken = beginImportOperation()
        defer { finishImportOperation(importToken) }
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-DocumentExport-"
        )
        let temporaryURL = temporaryArtifact.fileURL
        let outputRevisionID = UUID()
        defer { temporaryArtifact.remove() }

        do {
            let store = self.store
            let capacityTask = Task {
                try await store.ensureTemporaryWorkingCapacity(
                    for: urls,
                    copyMultiplier: 2,
                    reserveBytes: 32 * 1_024 * 1_024
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: capacityTask,
                operationTokens: operationTokens
            )
            guard records.allSatisfy({
                self.record(id: $0.id)?.contentRevisionID
                    == $0.contentRevisionID
            }) else {
                throw CancellationError()
            }
            let service = compositionService
            let combineTask = Task.detached(priority: .userInitiated) {
                try temporaryArtifact.prepare()
                try service.combine(urls: urls, to: temporaryURL)
            }
            try await valuePropagatingExclusiveCancellation(
                from: combineTask,
                operationTokens: operationTokens
            )
            guard records.allSatisfy({
                self.record(id: $0.id)?.contentRevisionID
                    == $0.contentRevisionID
            }) else {
                throw CancellationError()
            }
            let fallback = "\(records.first?.displayName ?? "Combined") + \(records.count - 1)"
            let normalizedName = String(
                name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).prefix(80)
            )
            let created = try await importSinglePDF(
                from: temporaryURL,
                preferredName: normalizedName.isEmpty
                    ? fallback
                    : normalizedName,
                contentRevisionID: outputRevisionID
            )
            noticeMessage = AppLocalization.format(
                "%lld PDFs combined locally",
                records.count
            )
            return created
        } catch is CancellationError {
            if let committed = documents.first(where: {
                $0.contentRevisionID == outputRevisionID
            }) {
                noticeMessage =
                    "Copy finished before stopping · copy kept in Library"
                        .localizedUI
                return committed
            }
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func extractPages(
        recordID: UUID,
        indices: Set<Int>,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID,
              let sourceURL = documentURLs[recordID],
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return nil }

        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-DocumentExport-"
        )
        let temporaryURL = temporaryArtifact.fileURL
        let outputRevisionID = UUID()
        defer { temporaryArtifact.remove() }

        do {
            let store = self.store
            let capacityTask = Task {
                try await store.ensureTemporaryWorkingCapacity(
                    for: [sourceURL],
                    copyMultiplier: 2,
                    reserveBytes: 16 * 1_024 * 1_024
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: capacityTask,
                recordID: recordID,
                operationToken: operationToken
            )
            guard self.record(id: recordID)?.contentRevisionID
                    == expectedContentRevisionID
            else {
                throw CancellationError()
            }
            let service = compositionService
            let selectedIndices = indices.sorted()
            let task = Task.detached(priority: .userInitiated) {
                try temporaryArtifact.prepare()
                try service.extractPages(
                    from: sourceURL,
                    indices: selectedIndices,
                    to: temporaryURL
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            guard self.record(id: recordID)?.contentRevisionID
                    == expectedContentRevisionID
            else {
                throw CancellationError()
            }
            let importTask = Task { @MainActor in
                try await self.importSinglePDF(
                    from: temporaryURL,
                    preferredName: AppLocalization.format(
                        "%@ - extracted pages",
                        record.displayName
                    ),
                    contentRevisionID: outputRevisionID
                )
            }
            let created = try await valuePropagatingExclusiveCancellation(
                from: importTask,
                recordID: recordID,
                operationToken: operationToken
            )
            noticeMessage = AppLocalization.format(
                "%lld page%@ extracted",
                selectedIndices.count,
                selectedIndices.count == 1 ? "" : "s"
            )
            return created
        } catch is CancellationError {
            if let committed = documents.first(where: {
                $0.contentRevisionID == outputRevisionID
            }) {
                noticeMessage =
                    "Copy finished before stopping · copy kept in Library"
                        .localizedUI
                return committed
            }
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createSearchableCopy(
        recordID: UUID,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        guard record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else {
            present(PDFBatchDeliveryIssue.sourceChanged)
            return nil
        }
        await ensureAnalysisLoaded(for: recordID)
        guard !Task.isCancelled else { return nil }
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID
        else {
            present(PDFBatchDeliveryIssue.sourceChanged)
            return nil
        }
        guard
              let sourceURL = documentURLs[recordID],
              let result = ocrResults[recordID]
        else {
            present(PaperPathError.missingRecognizedText)
            return nil
        }
        guard let operationToken = acquireExclusiveDocumentOperation(
            recordID: recordID
        ) else { return nil }

        let operationLabel = "Creating searchable PDF".localizedUI
        operationProgress[recordID] = PDFOperationProgress(
            label: operationLabel,
            fractionCompleted: 0
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
        }
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-DocumentExport-"
        )
        let temporaryURL = temporaryArtifact.fileURL
        let outputRevisionID = UUID()
        defer { temporaryArtifact.remove() }

        do {
            let service = searchablePDFService
            let reportProgress: PDFProgressHandler = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.exclusiveDocumentOperationIsCurrent(
                            recordID: recordID,
                            token: operationToken
                          )
                    else { return }
                    self.updateOperationFraction(
                        recordID: recordID,
                        label: operationLabel,
                        fractionCompleted: min(0.9, max(0, value) * 0.9)
                    )
                }
            }
            let task = Task.detached(priority: .userInitiated) {
                try temporaryArtifact.prepare()
                try service.createSearchableCopy(
                    sourceURL: sourceURL,
                    ocrResult: result,
                    destination: temporaryURL,
                    progress: reportProgress
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            operationProgress[recordID] = PDFOperationProgress(
                label: operationLabel,
                fractionCompleted: 0.94
            )
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else {
                throw CancellationError()
            }
            let importTask = Task { @MainActor in
                try await self.importSinglePDF(
                    from: temporaryURL,
                    preferredName: AppLocalization.format(
                        "%@ - searchable",
                        record.displayName
                    ),
                    contentRevisionID: outputRevisionID
                )
            }
            let created = try await valuePropagatingExclusiveCancellation(
                from: importTask,
                recordID: recordID,
                operationToken: operationToken
            )
            operationProgress[recordID] = PDFOperationProgress(
                label: operationLabel,
                fractionCompleted: 1
            )
            await markSourceCompleted(
                recordID: recordID,
                action: .makeSearchable,
                marksReady: false
            )
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            )
            noticeMessage = "Searchable PDF copy created".localizedUI
            return created
        } catch is CancellationError {
            if let committed = documents.first(where: {
                $0.contentRevisionID == outputRevisionID
            }) {
                noticeMessage =
                    "Searchable copy finished before stopping · copy kept in Library"
                        .localizedUI
                return committed
            }
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createCompressedCopy(
        recordID: UUID,
        quality: PDFCompressionQuality,
        expectedContentRevisionID: UUID,
        presentsFeedback: Bool = true,
        onFailure: ((PDFBatchDeliveryIssue) -> Void)? = nil
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Compressed copy",
            notice: "Compressed copy created and verified",
            operationKind: .compressed,
            presentsFeedback: presentsFeedback,
            onFailure: onFailure
        ) { [outputService] source, destination, progress in
            try outputService.compress(
                sourceURL: source,
                destination: destination,
                quality: quality,
                progress: progress
            )
        }
    }

    func compressionEstimate(
        recordID: UUID,
        quality: PDFCompressionQuality,
        expectedContentRevisionID: UUID
    ) async throws -> PDFCompressionEstimate {
        guard record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID,
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        let service = outputService
        let task = Task.detached(priority: .utility) {
            try service.estimateCompression(
                sourceURL: sourceURL,
                quality: quality
            )
        }
        let estimate = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else {
            throw CancellationError()
        }
        return estimate
    }

    func deliveryPreflight(
        recordID: UUID
    ) async throws -> PDFDeliveryPreflightAssessment {
        try Task.checkCancellation()
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        if let cached = deliveryPreflightCache[recordID],
           cached.revisionID == record.contentRevisionID,
           cached.usesCurrentRules {
            try Task.checkCancellation()
            return cached.assessment
        }
        let service = deliveryAuditService
        let task = Task.detached(priority: .userInitiated) {
            try service.preflight(sourceURL: sourceURL)
        }
        let assessment = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID
            == record.contentRevisionID
        else {
            throw CancellationError()
        }
        let entry = PDFDeliveryPreflightCacheEntry(
            recordID: recordID,
            revisionID: record.contentRevisionID,
            checkedAt: Date(),
            assessment: assessment
        )
        try? await store.saveDeliveryPreflight(entry)
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID
            == record.contentRevisionID
        else {
            throw CancellationError()
        }
        deliveryPreflightCache[recordID] = entry
        trimDeliveryPreflightCache(retaining: [recordID])
        return assessment
    }

    func createRedactedCopy(
        recordID: UUID,
        marks: [PDFRedactionMark],
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Redacted copy",
            notice: "Redacted copy created and verified",
            operationKind: .redacted
        ) { [outputService] source, destination, progress in
            try outputService.secureRedact(
                sourceURL: source,
                destination: destination,
                marks: marks,
                progress: progress
            )
        }
    }

    func createProtectedCopy(
        recordID: UUID,
        password: String,
        permissions: PDFProtectionPermissions = .restricted,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Protected copy",
            notice: "Protected copy created and verified",
            operationKind: .protected,
            unlockPassword: password
        ) { [outputService] source, destination, progress in
            try outputService.protect(
                sourceURL: source,
                destination: destination,
                password: password,
                permissions: permissions,
                progress: progress
            )
        }
    }

    func createUnlockedCopy(
        recordID: UUID,
        password: String,
        expectedContentRevisionID: UUID,
        presentsFeedback: Bool = true,
        onFailure: ((PDFBatchDeliveryIssue) -> Void)? = nil
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Editable copy",
            notice: "Editable private copy created and checked",
            operationKind: .unlocked,
            unlockPassword: password,
            presentsFeedback: presentsFeedback,
            onFailure: onFailure
        ) { [outputService] source, destination, progress in
            try outputService.removePassword(
                sourceURL: source,
                destination: destination,
                password: password,
                progress: progress
            )
        }
    }

    func createFlattenedCopy(
        recordID: UUID,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Flattened copy",
            notice: "Flattened copy created and verified",
            operationKind: .flattened
        ) { [outputService] source, destination, progress in
            try outputService.flatten(
                sourceURL: source,
                destination: destination,
                progress: progress
            )
        }
    }

    func printPreparationAssessment(
        recordID: UUID,
        options: PDFPrintPreparationOptions
    ) async -> PDFPrintPreparationAssessment? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else { return nil }
        let revisionID = record.contentRevisionID
        let service = outputService
        let task = Task.detached(priority: .userInitiated) {
            try service.printPreparationAssessment(
                sourceURL: sourceURL,
                revisionID: revisionID,
                options: options
            )
        }
        do {
            let assessment = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                == revisionID,
                  assessment.options == options
            else {
                return nil
            }
            return assessment
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createPrintReadyCopy(
        recordID: UUID,
        options: PDFPrintPreparationOptions,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Print-ready copy",
            notice: "Print-ready copy created and verified",
            operationKind: .printPrepared
        ) { [outputService] source, destination, progress in
            try outputService.prepareForPrint(
                sourceURL: source,
                destination: destination,
                options: options,
                progress: progress
            )
        }
    }

    func bookletAssessment(
        recordID: UUID,
        options: PDFBookletOptions
    ) async -> PDFBookletAssessment? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else { return nil }
        let revisionID = record.contentRevisionID
        let service = outputService
        let task = Task.detached(priority: .userInitiated) {
            try service.bookletAssessment(
                sourceURL: sourceURL,
                revisionID: revisionID,
                options: options
            )
        }
        do {
            let assessment = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                == revisionID
            else {
                return nil
            }
            return assessment
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createBookletCopy(
        recordID: UUID,
        options: PDFBookletOptions,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Booklet copy",
            notice: "Booklet copy created and verified",
            operationKind: .bookletPrepared
        ) { [outputService] source, destination, progress in
            try outputService.prepareBooklet(
                sourceURL: source,
                destination: destination,
                options: options,
                progress: progress
            )
        }
    }

    func createEditedCopy(
        recordID: UUID,
        overlays: [PDFContentOverlay],
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Edited copy",
            notice: "Edited copy created and verified",
            operationKind: .edited
        ) { [outputService] source, destination, progress in
            try outputService.addContent(
                sourceURL: source,
                destination: destination,
                overlays: overlays,
                progress: progress
            )
        }
    }

    func links(
        recordID: UUID,
        pageIndex: Int? = nil
    ) async throws -> [PDFLinkAnnotationSnapshot] {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        let service = mutationService
        let task = Task.detached(priority: .userInitiated) {
            try service.links(
                in: sourceURL,
                pageIndex: pageIndex
            )
        }
        let links = try await valuePropagatingCancellation(from: task)
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID
                == record.contentRevisionID
        else {
            throw CancellationError()
        }
        return links
    }

    func createLinkEditedCopy(
        recordID: UUID,
        mutation: PDFLinkMutation,
        expectedLink: PDFLinkAnnotationSnapshot? = nil,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Links edited",
            notice: "Link-edited copy created and verified",
            operationKind: .edited
        ) { [outputService] source, destination, progress in
            try outputService.editLink(
                sourceURL: source,
                destination: destination,
                mutation: mutation,
                expectedLink: expectedLink,
                progress: progress
            )
        }
    }

    func imageObjects(
        recordID: UUID,
        pageIndex: Int
    ) async throws -> [PDFImageObjectSnapshot] {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        let service = outputService
        let task = Task.detached(priority: .userInitiated) {
            try service.imageObjects(
                sourceURL: sourceURL,
                pageIndex: pageIndex
            )
        }
        let images = try await valuePropagatingCancellation(from: task)
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID
                == record.contentRevisionID
        else {
            throw CancellationError()
        }
        return images
    }

    func createImageReplacementCopy(
        recordID: UUID,
        snapshot: PDFImageObjectSnapshot,
        replacementData: Data,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Image replaced",
            notice: "Image replacement copy created and verified",
            operationKind: .edited
        ) { [outputService] source, destination, progress in
            try outputService.replaceImageObject(
                sourceURL: source,
                destination: destination,
                snapshot: snapshot,
                replacementData: replacementData,
                progress: progress
            )
        }
    }

    func createBookmarkOutlineCopy(
        recordID: UUID,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID
        else {
            present(PDFBatchDeliveryIssue.sourceChanged)
            return nil
        }
        let pages = record.bookmarkedPages
        guard !pages.isEmpty
        else {
            noticeMessage = "Bookmark at least one page first".localizedUI
            return nil
        }
        return await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Outline copy",
            notice: "PDF outline created from local bookmarks",
            operationKind: .edited
        ) { [outputService] source, destination, progress in
            try outputService.embedBookmarks(
                sourceURL: source,
                destination: destination,
                pageIndices: pages,
                progress: progress
            )
        }
    }

    func createPageLabeledCopy(
        recordID: UUID,
        rules: [PDFPageLabelRule],
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Page labeled",
            notice: "Standard PDF page labels created and verified",
            operationKind: .edited
        ) { [outputService] source, destination, progress in
            try outputService.applyPageLabels(
                sourceURL: source,
                destination: destination,
                rules: rules,
                progress: progress
            )
        }
    }

    func assessTextReplacement(
        recordID: UUID,
        selection: PDFTextSelectionSnapshot,
        replacement: String,
        fontStyle: PDFTextReplacementFontStyle,
        alignment: PDFTextReplacementAlignment,
        expectedContentRevisionID: UUID
    ) async -> PDFTextReplacementAssessment {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID,
              let sourceURL = documentURLs[recordID]
        else {
            return PDFTextReplacementAssessment(
                status: .unavailable,
                title: "Document unavailable",
                detail: "The working copy could not be opened.",
                resolvedFontName: nil,
                resolvedFontSize: 0,
                resolvedLineSpacing: 0,
                reflowedLineCount: 0,
                backgroundColor: nil,
                regionBackgroundColors: [],
                flowRegionTexts: [],
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        let revisionID = record.contentRevisionID
        let service = outputService
        let task = Task.detached(priority: .userInitiated) {
            try service.assessTextReplacement(
                sourceURL: sourceURL,
                selection: selection,
                replacement: replacement,
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
        do {
            let urls = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == revisionID
            else {
                return PDFTextReplacementAssessment(
                    status: .blocked,
                    title: "Document changed",
                    detail: "Select the text again before replacing it.",
                    resolvedFontName: nil,
                    resolvedFontSize: 0,
                    resolvedLineSpacing: 0,
                    reflowedLineCount: 0,
                    backgroundColor: nil,
                    regionBackgroundColors: [],
                    flowRegionTexts: [],
                    fontStyle: fontStyle,
                    alignment: alignment
                )
            }
            return urls
        } catch is CancellationError {
            return PDFTextReplacementAssessment(
                status: .unavailable,
                title: "Layout check stopped",
                detail: "No PDF was changed.",
                resolvedFontName: nil,
                resolvedFontSize: 0,
                resolvedLineSpacing: 0,
                reflowedLineCount: 0,
                backgroundColor: nil,
                regionBackgroundColors: [],
                flowRegionTexts: [],
                fontStyle: fontStyle,
                alignment: alignment
            )
        } catch {
            return PDFTextReplacementAssessment(
                status: .unavailable,
                title: "Cannot inspect selection",
                detail: AppLocalization
                    .userFacingErrorDescription(error),
                resolvedFontName: nil,
                resolvedFontSize: 0,
                resolvedLineSpacing: 0,
                reflowedLineCount: 0,
                backgroundColor: nil,
                regionBackgroundColors: [],
                flowRegionTexts: [],
                fontStyle: fontStyle,
                alignment: alignment
            )
        }
    }

    func createTextReplacementCopy(
        recordID: UUID,
        selection: PDFTextSelectionSnapshot,
        replacement: String,
        assessment: PDFTextReplacementAssessment,
        expectedContentRevisionID: UUID
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Text replacement copy",
            notice: "Text replacement copy created and verified",
            operationKind: .textReplaced
        ) { [outputService] source, destination, progress in
            try outputService.replaceText(
                sourceURL: source,
                destination: destination,
                selection: selection,
                replacement: replacement,
                assessment: assessment,
                progress: progress
            )
        }
    }

    func createSafeShareCopy(
        recordID: UUID,
        expectedContentRevisionID: UUID,
        presentsFeedback: Bool = true,
        onFailure: ((PDFBatchDeliveryIssue) -> Void)? = nil,
        bypassesEntitlement: Bool = false
    ) async -> DocumentRecord? {
        let reservesFreeOutput: Bool
        if bypassesEntitlement
            || isRunningAutomatedTests
            || AppEntitlement.canCreateVerifiedOutput {
            reservesFreeOutput = false
        } else if AppEntitlement.verifiedOutputCount == 0,
                  !isFreeVerifiedOutputReserved {
            isFreeVerifiedOutputReserved = true
            reservesFreeOutput = true
        } else {
            presentFullUnlock(.singleVerifiedOutput)
            return nil
        }
        defer {
            if reservesFreeOutput {
                isFreeVerifiedOutputReserved = false
            }
        }
        let existingOutputIDs = verifiedSafeShareOutputIDs(
            for: recordID
        )
        var creationIssue: PDFBatchDeliveryIssue?
        let created = await createOutputCopy(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            outputNameKey: "Verified copy",
            notice: "Verified copy created and checked",
            operationKind: .safeShare,
            completesAction: .safeShare,
            marksSourceReady: true,
            presentsFeedback: presentsFeedback,
            onFailure: {
                creationIssue = $0
                onFailure?($0)
            }
        ) { [outputService] source, destination, progress in
            try outputService.safeShare(
                sourceURL: source,
                destination: destination,
                progress: progress
            )
        }
        let createdDurableOutput = created != nil
            || !verifiedSafeShareOutputIDs(for: recordID)
                .isSubset(of: existingOutputIDs)
        if createdDurableOutput, !isRunningAutomatedTests {
            verifiedOutputSuccessCount =
                AppEntitlement.recordVerifiedOutput()
        } else if !createdDurableOutput,
                  !isRunningAutomatedTests,
                  creationIssue?.phase != .cancelled {
            AppEntitlement.recordVerifiedFailure()
        }
        return created
    }

    private func verifiedSafeShareOutputIDs(
        for sourceRecordID: UUID
    ) -> Set<UUID> {
        Set(
            (documents + Array(deferredCommittedImports.values))
                .filter {
                    $0.sourceDocumentID == sourceRecordID
                        && isVerifiedSafeShareOutput($0)
                }
                .map(\.id)
        )
    }

    private func isVerifiedSafeShareOutput(
        _ record: DocumentRecord
    ) -> Bool {
        record.hasCurrentDeliveryReceipt
            && record.deliveryReceipt?.isDeliveryOutput == true
            && record.deliveryReceipt?.operation == .safeShare
    }

    func beginBatchDeliveryRun(id: UUID) -> Bool {
        guard activeBatchDeliveryRunID == nil else {
            noticeMessage = "Another batch is already running.".localizedUI
            return false
        }
        activeBatchDeliveryRunID = id
        return true
    }

    func endBatchDeliveryRun(id: UUID) {
        if activeBatchDeliveryRunID == id { activeBatchDeliveryRunID = nil }
    }

    private func restoreBatchDeliveryRun() async throws {
        lastBatchDeliveryRun = try await store.loadBatchDeliveryRun()
        if lastBatchDeliveryRun != nil, currentBatchDeliveryRun() == nil {
            lastBatchDeliveryRun = nil
            await store.clearBatchDeliveryRun()
        }
    }

    func createSafeShareBatch(
        recordIDs: [UUID],
        runID: UUID? = nil,
        expectedRevisionIDs: [UUID: UUID]? = nil,
        onUpdate: @escaping (PDFBatchDeliveryItem) -> Void
    ) async -> [PDFBatchDeliveryItem] {
        var seen = Set<UUID>()
        let sourceIDs = recordIDs.filter { seen.insert($0).inserted }
        let ownedRunID = runID ?? UUID()
        let ownsRun = runID.map { activeBatchDeliveryRunID == $0 }
            ?? beginBatchDeliveryRun(id: ownedRunID)
        defer {
            if ownsRun, runID == nil { endBatchDeliveryRun(id: ownedRunID) }
        }
        guard ownsRun, batchDeliveryPendingDocumentIDs.isEmpty else {
            let issue = PDFBatchDeliveryIssue.blocked("Another batch is already running.")
            return sourceIDs.map {
                PDFBatchDeliveryItem(sourceRecordID: $0, stage: .blocked, detail: issue.message, issue: issue)
            }
        }
        guard sourceIDs.count <= 64 else {
            let issue = PDFBatchDeliveryIssue.blocked(
                "Choose up to 64 PDFs in one batch."
            )
            return sourceIDs.map {
                PDFBatchDeliveryItem(
                    sourceRecordID: $0,
                    stage: .blocked,
                    detail: issue.message,
                    issue: issue
                )
            }
        }
        guard authorizeBatchVerifiedOutput() else {
            let issue = PDFBatchDeliveryIssue.blocked(
                "Lifetime access is required for batch Verified Output."
            )
            return sourceIDs.map {
                PDFBatchDeliveryItem(
                    sourceRecordID: $0,
                    stage: .blocked,
                    detail: issue.message,
                    issue: issue
                )
            }
        }
        let pendingSet = Set(sourceIDs)
        batchDeliveryPendingDocumentIDs.formUnion(pendingSet)
        defer {
            batchDeliveryPendingDocumentIDs.subtract(pendingSet)
        }
        var results = sourceIDs.map {
            PDFBatchDeliveryItem(
                sourceRecordID: $0,
                stage: .queued,
                detail: "Waiting for local preflight"
            )
        }

        func publish(_ item: PDFBatchDeliveryItem) {
            guard let index = results.firstIndex(
                where: { $0.sourceRecordID == item.sourceRecordID }
            ) else { return }
            results[index] = item
            onUpdate(item)
        }

        var pendingIDs: [UUID] = []
        for sourceID in sourceIDs {
            guard !Task.isCancelled else { break }
            guard let source = record(id: sourceID) else {
                let issue = PDFBatchDeliveryIssue.sourceUnavailable()
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
                continue
            }
            guard source.isWorkingCopy, !source.profile.isLocked else {
                let issue = PDFBatchDeliveryIssue.blocked(
                    "Only unlocked working copies can enter batch verification."
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .blocked,
                        detail: issue.message,
                        issue: issue
                    )
                )
                continue
            }

            if let expectedRevisionIDs,
               expectedRevisionIDs[sourceID] != source.contentRevisionID {
                publish(.changedSource(sourceID))
                continue
            }

            if let existing = verifiedShareTarget(for: sourceID) {
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        outputRecordID: existing.id,
                        stage: .reused,
                        detail: "Current verified copy reused"
                    )
                )
                continue
            }

            pendingIDs.append(sourceID)
            publish(
                PDFBatchDeliveryItem(
                    sourceRecordID: sourceID,
                    stage: .checking,
                    detail: "Inspecting pages, layers, and metadata"
                )
            )
        }

        let preflightOutcomes = await batchPreflight(
            recordIDs: pendingIDs
        ) { outcome in
            if let issue = outcome.issue {
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: outcome.recordID,
                        stage: issue.phase == .cancelled
                            ? .stopped
                            : .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
                return
            }
            guard let assessment = outcome.assessment else { return }
            if let review = assessment.batchAttentionItem {
                let issue = review.status == .blocked
                    ? PDFBatchDeliveryIssue.blocked(review.detail)
                    : PDFBatchDeliveryIssue.review(review.detail)
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: outcome.recordID,
                        stage: review.status == .blocked ? .blocked : .needsReview,
                        detail: review.detail,
                        reviewPageIndex: review.reviewPageIndex,
                        issue: issue
                    )
                )
                return
            }
            publish(
                PDFBatchDeliveryItem(
                    sourceRecordID: outcome.recordID,
                    stage: .ready,
                    detail: "Preflight complete · waiting to create"
                )
            )
        }

        for sourceID in pendingIDs {
            guard !Task.isCancelled else { break }
            guard let outcome = preflightOutcomes[sourceID] else {
                let issue = PDFBatchDeliveryIssue.preflightFailed(
                    "No preflight result was returned"
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
                continue
            }

            if let issue = outcome.issue {
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: issue.phase == .cancelled
                            ? .stopped
                            : .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
                continue
            }

            guard let assessment = outcome.assessment else {
                let issue = PDFBatchDeliveryIssue.preflightFailed(
                    "The preflight result was incomplete"
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
                continue
            }

            if let pageReview = assessment.batchAttentionItem {
                let issue = pageReview.status == .blocked
                    ? PDFBatchDeliveryIssue.blocked(pageReview.detail)
                    : PDFBatchDeliveryIssue.review(pageReview.detail)
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: pageReview.status == .blocked ? .blocked : .needsReview,
                        detail: pageReview.detail,
                        reviewPageIndex: pageReview.reviewPageIndex,
                        issue: issue
                    )
                )
                continue
            }

            publish(
                PDFBatchDeliveryItem(
                    sourceRecordID: sourceID,
                    stage: .creating,
                    detail: assessment.fixCount == 0
                        ? "Rendering and verifying"
                        : "Applying \(assessment.fixCount) fix\(assessment.fixCount == 1 ? "" : "es"), then verifying"
                )
            )

            guard let expectedContentRevisionID =
                    outcome.revisionID
            else {
                let issue = PDFBatchDeliveryIssue.sourceChanged
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
                continue
            }
            var creationIssue: PDFBatchDeliveryIssue?
            let output = await createSafeShareCopy(
                recordID: sourceID,
                expectedContentRevisionID:
                    expectedContentRevisionID,
                presentsFeedback: false,
                onFailure: { creationIssue = $0 },
                bypassesEntitlement: true
            )
            if let output, output.hasCurrentDeliveryReceipt {
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        outputRecordID: output.id,
                        stage: .verified,
                        detail: "Reopened, audited, and fingerprinted"
                    )
                )
                if Task.isCancelled { break }
            } else if Task.isCancelled {
                break
            } else {
                let issue = creationIssue
                    ?? .renderingFailed(
                        "A verified copy could not be created"
                    )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .failed,
                        detail: issue.message,
                        issue: issue
                    )
                )
            }
        }

        if Task.isCancelled {
            let unfinishedIDs = results
                .filter { !$0.stage.isFinal }
                .map(\.sourceRecordID)
            for sourceID in unfinishedIDs {
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .stopped,
                        detail: PDFBatchDeliveryIssue.cancelled.message,
                        issue: .cancelled
                    )
                )
            }
        }

        let verifiedCount = results.filter {
            $0.stage.isShareable
        }.count
        if Task.isCancelled {
            noticeMessage = "Batch preparation stopped".localizedUI
        } else {
            noticeMessage = AppLocalization.format(
                "%lld verified cop%@ ready",
                verifiedCount,
                verifiedCount == 1 ? "y" : "ies"
            )
        }
        return results
    }

    @discardableResult
    func authorizeBatchVerifiedOutput() -> Bool {
        guard isRunningAutomatedTests
                || AppEntitlement.canCreateVerifiedOutput
        else {
            presentFullUnlock(.batchVerifiedOutput)
            return false
        }
        return true
    }

    private func presentFullUnlock(_ context: FullUnlockContext) {
        if let sceneID = resolvedFeedbackTarget(
            AppFeedbackContext.targetSceneID
        ) {
            fullUnlockContextsBySceneID[sceneID] = context
        } else {
            unscopedFullUnlockContext = context
        }
    }

    @discardableResult
    func saveBatchDeliveryRun(
        id: UUID,
        sourceRecordIDs: [UUID],
        sourceRevisionIDs: [UUID: UUID],
        items: [PDFBatchDeliveryItem],
        startedAt: Date,
        snapshotAt: Date = Date()
    ) async -> Bool {
        guard activeBatchDeliveryRunID == nil || activeBatchDeliveryRunID == id else { return false }
        var canonicalStartedAt = startedAt
        if let current = lastBatchDeliveryRun {
            if id == current.id {
                guard snapshotAt >= current.updatedAt else { return false }
                canonicalStartedAt = current.startedAt
            } else {
                guard startedAt >= current.startedAt else { return false }
            }
        }
        var seen = Set<UUID>()
        let validSourceIDs = sourceRecordIDs.filter { recordID in
            guard seen.insert(recordID).inserted,
                  let source = record(id: recordID),
                  sourceRevisionIDs[recordID] != nil
            else { return false }
            return source.isWorkingCopy
                && !source.profile.isLocked
                && documentURLs[recordID] != nil
        }
        guard !validSourceIDs.isEmpty else {
            return false
        }
        let revisions = Dictionary(
            validSourceIDs.compactMap {
                recordID -> (UUID, UUID)? in
                guard let revisionID =
                    sourceRevisionIDs[recordID]
                else { return nil }
                return (recordID, revisionID)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let itemByID = Dictionary(
            items.map {
                ($0.sourceRecordID, $0)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let run = PDFBatchDeliveryRun(
            id: id,
            startedAt: canonicalStartedAt,
            updatedAt: max(canonicalStartedAt, snapshotAt),
            sourceRecordIDs: validSourceIDs,
            sourceRevisionIDs: revisions,
            items: validSourceIDs.compactMap { recordID in
                guard record(id: recordID)?.contentRevisionID == revisions[recordID] else {
                    return .changedSource(recordID)
                }
                return itemByID[recordID]
            }
        )
        lastBatchDeliveryRun = run
        do {
            try await store.saveBatchDeliveryRun(run)
            if lastBatchDeliveryRun == run { batchDeliveryPersistenceError = nil }
            return true
        } catch {
            if lastBatchDeliveryRun == run {
                batchDeliveryPersistenceError =
                    "Batch progress could not be saved. Completed PDFs remain in Results.".localizedUI
            }
            return false
        }
    }

    func clearBatchDeliveryRun() async {
        guard activeBatchDeliveryRunID == nil else { return }
        lastBatchDeliveryRun = nil
        batchDeliveryPersistenceError = nil
        await store.clearBatchDeliveryRun()
    }

    func currentBatchDeliveryRun() -> PDFBatchDeliveryRun? {
        guard let run = lastBatchDeliveryRun else { return nil }
        let validIDs = run.sourceRecordIDs.filter { recordID in
            guard let current = documentRecordsByID[recordID],
                  run.sourceRevisionIDs[recordID] != nil,
                  current.isWorkingCopy,
                  !current.profile.isLocked,
                  documentURLs[recordID] != nil
            else { return false }
            return true
        }
        let validIDSet = Set(validIDs)
        let itemByID = Dictionary(
            run.items.map {
                ($0.sourceRecordID, $0)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let validItems = validIDs.map { recordID in
            guard documentRecordsByID[recordID]?.contentRevisionID
                    == run.sourceRevisionIDs[recordID] else {
                return PDFBatchDeliveryItem.changedSource(recordID)
            }
            let item = itemByID[recordID] ?? PDFBatchDeliveryItem(
                sourceRecordID: recordID,
                stage: .stopped,
                detail: PDFBatchDeliveryIssue.cancelled.message,
                issue: .cancelled
            )
            if let output = verifiedShareTarget(for: recordID) {
                return PDFBatchDeliveryItem(
                    sourceRecordID: recordID,
                    outputRecordID: output.id,
                    stage: item.stage.isShareable
                        && item.outputRecordID == output.id
                        ? item.stage
                        : .reused,
                    detail: item.stage.isShareable
                        && item.outputRecordID == output.id
                        ? item.detail
                        : "Current verified copy reused"
                )
            }
            if !item.stage.isFinal,
               !batchDeliveryPendingDocumentIDs.contains(recordID) {
                return PDFBatchDeliveryItem(
                    sourceRecordID: recordID,
                    stage: .stopped,
                    detail: PDFBatchDeliveryIssue.cancelled.message,
                    issue: .cancelled
                )
            }
            if item.stage.isShareable {
                return PDFBatchDeliveryItem(
                    sourceRecordID: recordID,
                    stage: .stopped,
                    detail: "The previous verified copy is no longer current",
                    issue: .cancelled
                )
            }
            return item
        }
        guard !validItems.isEmpty else { return nil }
        return PDFBatchDeliveryRun(
            id: run.id,
            startedAt: run.startedAt,
            updatedAt: run.updatedAt,
            sourceRecordIDs: validIDs,
            sourceRevisionIDs: run.sourceRevisionIDs.filter {
                validIDSet.contains($0.key)
            },
            items: validItems
        )
    }

    func recoverableBatchDeliveryRun() -> PDFBatchDeliveryRun? {
        guard let run = currentBatchDeliveryRun(),
              run.needsAttention
        else { return nil }
        return run
    }

    private func batchPreflight(
        recordIDs: [UUID],
        onOutcome: (BatchPreflightOutcome) -> Void
    ) async -> [UUID: BatchPreflightOutcome] {
        typealias Request = (
            recordID: UUID,
            revisionID: UUID,
            sourceURL: URL
        )

        var outcomes: [UUID: BatchPreflightOutcome] = [:]
        var requests: [Request] = []
        for recordID in recordIDs {
            guard let record = record(id: recordID),
                  let sourceURL = documentURLs[recordID]
            else {
                let outcome = BatchPreflightOutcome(
                    recordID: recordID,
                    revisionID: nil,
                    assessment: nil,
                    issue: .sourceUnavailable()
                )
                outcomes[recordID] = outcome
                onOutcome(outcome)
                continue
            }
            if let cached = deliveryPreflightCache[recordID],
               cached.revisionID == record.contentRevisionID,
               cached.usesCurrentRules {
                let outcome = BatchPreflightOutcome(
                    recordID: recordID,
                    revisionID: record.contentRevisionID,
                    assessment: cached.assessment,
                    issue: nil
                )
                outcomes[recordID] = outcome
                onOutcome(outcome)
            } else {
                requests.append(
                    (
                        recordID,
                        record.contentRevisionID,
                        sourceURL
                    )
                )
            }
        }

        let service = deliveryAuditService
        await withTaskGroup(of: BatchPreflightOutcome.self) { group in
            var nextRequestIndex = 0
            let concurrency = min(
                preflightConcurrencyLimit,
                requests.count
            )

            for _ in 0..<concurrency {
                let request = requests[nextRequestIndex]
                nextRequestIndex += 1
                group.addTask {
                    await Self.runBatchPreflight(
                        request: request,
                        service: service
                    )
                }
            }

            while let outcome = await group.next() {
                outcomes[outcome.recordID] = outcome
                onOutcome(outcome)
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if nextRequestIndex < requests.count {
                    let request = requests[nextRequestIndex]
                    nextRequestIndex += 1
                    group.addTask {
                        await Self.runBatchPreflight(
                            request: request,
                            service: service
                        )
                    }
                }
            }
        }

        var cachedRecordIDs: Set<UUID> = []
        for outcome in outcomes.values {
            guard let revisionID = outcome.revisionID,
                  let assessment = outcome.assessment,
                  record(id: outcome.recordID)?.contentRevisionID
                    == revisionID
            else { continue }
            let entry = PDFDeliveryPreflightCacheEntry(
                recordID: outcome.recordID,
                revisionID: revisionID,
                checkedAt: Date(),
                assessment: assessment
            )
            deliveryPreflightCache[outcome.recordID] = entry
            cachedRecordIDs.insert(outcome.recordID)
            try? await store.saveDeliveryPreflight(entry)
        }
        trimDeliveryPreflightCache(
            retaining: cachedRecordIDs
        )
        return outcomes
    }

    private func trimDeliveryPreflightCache(
        retaining recordIDs: Set<UUID>
    ) {
        guard deliveryPreflightCache.count
                > Self.maximumInMemoryPreflightEntries
        else { return }
        var orderedIDs = recordIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        let retainedSet = Set(orderedIDs)
        orderedIDs.append(
            contentsOf: documents.lazy
                .filter {
                    self.deliveryPreflightCache[$0.id] != nil
                        && !retainedSet.contains($0.id)
                }
                .map(\.id)
        )
        let keepIDs = Set(
            orderedIDs.prefix(
                Self.maximumInMemoryPreflightEntries
            )
        )
        deliveryPreflightCache = deliveryPreflightCache.filter {
            keepIDs.contains($0.key)
        }
    }

    private var preflightConcurrencyLimit: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return 1
        case .nominal, .fair:
            return min(
                2,
                max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
            )
        @unknown default:
            return 1
        }
    }

    nonisolated private static func runBatchPreflight(
        request: (
            recordID: UUID,
            revisionID: UUID,
            sourceURL: URL
        ),
        service: PDFDeliveryAuditService
    ) async -> BatchPreflightOutcome {
        do {
            try Task.checkCancellation()
            let assessment = try service.preflight(
                sourceURL: request.sourceURL
            )
            return BatchPreflightOutcome(
                recordID: request.recordID,
                revisionID: request.revisionID,
                assessment: assessment,
                issue: nil
            )
        } catch is CancellationError {
            return BatchPreflightOutcome(
                recordID: request.recordID,
                revisionID: request.revisionID,
                assessment: nil,
                issue: .cancelled
            )
        } catch {
            return BatchPreflightOutcome(
                recordID: request.recordID,
                revisionID: request.revisionID,
                assessment: nil,
                issue: .preflightFailed(
                    AppLocalization
                        .userFacingErrorDescription(error)
                )
            )
        }
    }

    private func validateOfficeProductionResources(
        recordID: UUID,
        format: PDFTextExportFormat
    ) async throws {
        await refreshOfficeResourceSnapshot()
        guard officeResourceSnapshot.mode != .blocked else {
            if let capacity =
                officeResourceSnapshot.availableCapacityBytes,
               capacity < 512 * 1_024 * 1_024 {
                throw PaperPathError.insufficientStorage
            }
            throw PaperPathError.insufficientSelection(
                officeResourceSnapshot.detail
            )
        }
        let forecast = officeProductionForecast(
            recordIDs: [recordID],
            format: format
        )
        guard forecast.hasCapacity else {
            throw PaperPathError.insufficientStorage
        }
    }

    func makeTextExport(
        recordID: UUID,
        format: PDFTextExportFormat = .plainText,
        expectedContentRevisionID: UUID? = nil,
        pageRange: ClosedRange<Int>? = nil
    ) async throws -> PDFTextExportArtifact {
        guard let requestedRevision = expectedContentRevisionID
            ?? record(id: recordID)?.contentRevisionID
        else { throw PaperPathError.unreadablePDF }
        await ensureAnalysisLoaded(for: recordID)
        try Task.checkCancellation()
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        guard record.contentRevisionID == requestedRevision else {
            throw PaperPathError.outputVerificationFailed("the source changed before export")
        }
        if let pageRange {
            guard pageRange.lowerBound >= 0,
                  pageRange.upperBound < record.profile.pageCount,
                  pageRange.count <= (format.officePageLimit ?? PDFCompositionService.maximumPageCount),
                  record.profile.allowsCopying, !record.profile.isLocked
            else {
                throw PaperPathError.insufficientSelection(
                    "Choose an unlocked page range within this format's page limit."
                )
            }
        }
        if format.isOfficeFormat {
            try await validateOfficeProductionResources(
                recordID: recordID,
                format: format
            )
        }

        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID == requestedRevision else {
            throw PaperPathError.outputVerificationFailed("the source changed before export")
        }
        let operationToken = try beginExclusiveDocumentOperation(
            recordID: recordID
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }

        let exportContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                format.isOfficeFormat
                    ? "PaperPath-Office-Export-\(UUID().uuidString)"
                    : "PaperPath-DocumentExport-\(UUID().uuidString)",
                isDirectory: true
            )
        let destination = exportContainer
            .appendingPathComponent(
                "\(safeExportName(record.displayName))\(pageRange.map { "-pages-\($0.lowerBound + 1)-\($0.upperBound + 1)" } ?? "")-\(UUID().uuidString).\(format.fileExtension)"
            )
        let label = AppLocalization.format(
            "Exporting %@",
            format.title.localizedUI
        )
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: 0
        )
        operationRateWindows[recordID] = ByteRateWindow()
        defer {
            operationProgress[recordID] = nil
            operationRateWindows[recordID] = nil
        }
        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: exportContainer
            )
            let service = outputService
            let textIndex = textIndices[recordID]
            let task = Task.detached(priority: .userInitiated) {
                let rangeSource = exportContainer.appendingPathComponent("selected-source.pdf")
                defer {
                    if pageRange != nil { try? FileManager.default.removeItem(at: rangeSource) }
                }
                var effectiveSource = sourceURL
                var effectiveIndex = textIndex
                var effectiveProfile = record.profile
                if let pageRange {
                    guard let source = PDFDocument(url: sourceURL),
                          !source.isLocked, source.allowsCopying,
                          pageRange.upperBound < source.pageCount
                    else { throw PaperPathError.lockedPDF }
                    try PDFCompositionService().extractPages(
                        from: sourceURL, indices: Array(pageRange), to: rangeSource
                    )
                    try LocalFileSecurity.requireCompleteProtection(to: rangeSource)
                    try Task.checkCancellation()
                    effectiveProfile = try PDFInspectionService().inspect(url: rangeSource)
                    effectiveIndex = textIndex?.segment(
                        from: pageRange.lowerBound, through: pageRange.upperBound
                    )
                    effectiveSource = rangeSource
                }
                let evidence = try service.exportText(
                    sourceURL: effectiveSource,
                    destination: destination,
                    textIndex: effectiveIndex,
                    title: record.displayName,
                    format: format,
                    profile: effectiveProfile,
                    byteProgress: { update in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.exclusiveDocumentOperationIsCurrent(
                                    recordID: recordID,
                                    token: operationToken
                                  )
                            else { return }
                            self.publishOperationByteProgress(
                                recordID: recordID,
                                label: label,
                                update: update
                            )
                        }
                    }
                ) { value in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.exclusiveDocumentOperationIsCurrent(
                                recordID: recordID,
                                token: operationToken
                              )
                        else { return }
                        self.updateOperationFraction(
                            recordID: recordID,
                            label: label,
                            fractionCompleted: value
                        )
                    }
                }
                return (evidence, effectiveProfile)
            }
            let (evidence, effectiveProfile) = try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            guard self.record(id: recordID)?.contentRevisionID
                == requestedRevision
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the source changed during export"
                )
            }
            let outputValues = try destination.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ]
            )
            guard outputValues.isRegularFile == true,
                  outputValues.isSymbolicLink != true,
                  (outputValues.fileSize ?? 0) > 0
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the generated file is empty"
                )
            }
            try LocalFileSecurity.requireCompleteProtection(
                to: destination
            )
            return PDFTextExportArtifact(
                url: destination,
                runtimeEvidence: evidence,
                sourceProfile: effectiveProfile
            )
        } catch is CancellationError {
            await discardTemporaryExportCopies(
                at: [exportContainer]
            )
            throw CancellationError()
        } catch {
            await discardTemporaryExportCopies(
                at: [exportContainer]
            )
            throw error
        }
    }

    func officeBatchPlan(
        recordID: UUID,
        format: PDFTextExportFormat
    ) -> PDFOfficeBatchPlan? {
        guard format.isOfficeFormat,
              let record = record(id: recordID)
        else { return nil }
        return PDFOfficeBatchPlan(
            format: format,
            sourceRevisionID: record.contentRevisionID,
            profile: record.profile
        )
    }

    func officeBatchRun(
        for recordID: UUID
    ) -> PDFOfficeBatchRun? {
        officeBatchRuns[recordID]
    }

    func clearFinishedOfficeBatch(
        recordID: UUID
    ) async {
        guard officeBatchRuns[recordID]?.isFinished == true else {
            return
        }
        officeBatchRuns[recordID] = nil
        await persistOfficeBatchRun(recordID: recordID)
    }

    func makeOfficeBatch(
        recordID: UUID,
        format: PDFTextExportFormat,
        expectedSourceRevisionID: UUID? = nil,
        queueJobID: UUID? = nil
    ) async throws -> PDFOfficeBatchRun? {
        guard let record = record(id: recordID),
              format.isOfficeFormat,
              expectedSourceRevisionID == nil
                || expectedSourceRevisionID
                    == record.contentRevisionID
        else { return nil }

        let plan = PDFOfficeBatchPlan(
            format: format,
            sourceRevisionID: record.contentRevisionID,
            profile: record.profile
        )
        guard plan.isBatchRequired else { return nil }
        let run = PDFOfficeBatchRun(plan: plan)
        return try await executeOfficeBatch(
            recordID: recordID,
            run: run,
            selectedSegmentIDs: Set(plan.segments.map(\.id)),
            queueJobID: queueJobID
        )
    }

    func resumeOfficeBatch(
        recordID: UUID,
        selectedSegmentIDs: Set<UUID>? = nil,
        queueJobID: UUID? = nil
    ) async throws -> PDFOfficeBatchRun? {
        guard let run = officeBatchRuns[recordID],
              let record = record(id: recordID),
              run.plan.sourceRevisionID == record.contentRevisionID
        else { return nil }
        let available = run.retryableSegmentIDs
        let selected = selectedSegmentIDs
            .map { $0.intersection(available) }
            ?? available
        guard !selected.isEmpty else { return run }
        return try await executeOfficeBatch(
            recordID: recordID,
            run: run,
            selectedSegmentIDs: selected,
            queueJobID: queueJobID
        )
    }

    private func executeOfficeBatch(
        recordID: UUID,
        run initialRun: PDFOfficeBatchRun,
        selectedSegmentIDs: Set<UUID>,
        queueJobID: UUID?
    ) async throws -> PDFOfficeBatchRun? {
        await ensureAnalysisLoaded(for: recordID)
        try Task.checkCancellation()
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID],
              initialRun.plan.sourceRevisionID
                == record.contentRevisionID,
              !selectedSegmentIDs.isEmpty
        else { return nil }

        let plan = initialRun.plan
        let format = plan.format
        try await validateOfficeProductionResources(
            recordID: recordID,
            format: format
        )
        let operationLabel = AppLocalization.format(
            "Exporting %@ batch",
            format.fileExtension.uppercased()
        )
        let operationToken = try beginExclusiveDocumentOperation(
            recordID: recordID
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
            operationRateWindows[recordID] = nil
        }
        try markExclusiveDocumentOperationBackgroundCancellable(
            recordID: recordID,
            token: operationToken
        )

        var run = initialRun
        for index in run.segments.indices
            where selectedSegmentIDs.contains(run.segments[index].id) {
            run.segments[index].status = .queued
            run.segments[index].fractionCompleted = 0
            run.segments[index].receiptID = nil
            run.segments[index].failureDetail = nil
        }
        run.completedAt = nil
        run.status = .running
        officeBatchRuns[recordID] = run
        await persistOfficeBatchRun(recordID: recordID)

        operationProgress[recordID] = PDFOperationProgress(
            label: operationLabel,
            fractionCompleted: 0
        )
        operationRateWindows[recordID] = ByteRateWindow()

        let service = outputService
        let composition = compositionService
        let sourceTextIndex = textIndices[recordID]

        do {
            for segment in plan.segments
                where selectedSegmentIDs.contains(segment.id) {
                try ensureExclusiveDocumentOperationIsCurrent(
                    recordID: recordID,
                    token: operationToken
                )
                guard self.record(id: recordID)?.contentRevisionID
                        == plan.sourceRevisionID
                else {
                    markOfficeBatchSourceChanged(
                        recordID: recordID,
                        batchID: plan.id,
                        fromSegmentIndex: segment.index
                    )
                    await persistOfficeBatchRun(recordID: recordID)
                    break
                }

                updateOfficeBatchSegment(
                    recordID: recordID,
                    batchID: plan.id,
                    segmentIndex: segment.index,
                    status: .extracting,
                    fractionCompleted: 0.04
                )

                let segmentDirectory =
                    FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Office-Segment-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let segmentURL = segmentDirectory
                    .appendingPathComponent(
                        "source-pages-\(segment.startPageIndex + 1)-\(segment.endPageIndex + 1).pdf"
                    )
                let outputURL = segmentDirectory
                    .appendingPathComponent(
                        "\(safeExportName(record.displayName))-part-\(segment.index + 1).\(format.fileExtension)"
                    )
                defer {
                    try? FileManager.default.removeItem(
                        at: segmentDirectory
                    )
                }

                do {
                    try LocalFileSecurity.prepareProtectedDirectory(
                        at: segmentDirectory
                    )
                    let extractionTask = Task.detached(
                        priority: .userInitiated
                    ) {
                        try composition.extractPages(
                            from: sourceURL,
                            indices: segment.pageIndices,
                            to: segmentURL
                        )
                    }
                    try await valuePropagatingExclusiveCancellation(
                        from: extractionTask,
                        recordID: recordID,
                        operationToken: operationToken
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: segmentURL
                    )

                    let inspector = PDFInspectionService()
                    let inspectionTask = Task.detached(
                        priority: .utility
                    ) {
                        try inspector.inspect(url: segmentURL)
                    }
                    let segmentProfile =
                        try await valuePropagatingExclusiveCancellation(
                            from: inspectionTask,
                            recordID: recordID,
                            operationToken: operationToken
                        )
                    let segmentTextIndex = sourceTextIndex?.segment(
                        from: segment.startPageIndex,
                        through: segment.endPageIndex
                    )

                    updateOfficeBatchSegment(
                        recordID: recordID,
                        batchID: plan.id,
                        segmentIndex: segment.index,
                        status: .rebuilding,
                        fractionCompleted: 0.14
                    )

                    let segmentTitle =
                        "\(record.displayName) - Part \(segment.index + 1)"
                    let exportTask = Task.detached(
                        priority: .userInitiated
                    ) {
                        try service.exportText(
                            sourceURL: segmentURL,
                            destination: outputURL,
                            textIndex: segmentTextIndex,
                            title: segmentTitle,
                            format: format,
                            profile: segmentProfile,
                            byteProgress: { update in
                                Task { @MainActor [weak self] in
                                    guard let self,
                                          self.exclusiveDocumentOperationIsCurrent(
                                            recordID: recordID,
                                            token: operationToken
                                          ),
                                          self.officeBatchRuns[recordID]?.id
                                            == plan.id
                                    else { return }
                                    self.publishOperationByteProgress(
                                        recordID: recordID,
                                        label: operationLabel,
                                        update: update
                                    )
                                }
                            }
                        ) { value in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      self.exclusiveDocumentOperationIsCurrent(
                                        recordID: recordID,
                                        token: operationToken
                                      ),
                                      self.officeBatchRuns[recordID]?.id
                                        == plan.id
                                else { return }
                                self.updateOperationFraction(
                                    recordID: recordID,
                                    label: operationLabel,
                                    fractionCompleted: (
                                        Double(segment.index)
                                            + 0.14 + value * 0.7
                                    ) / Double(
                                        max(1, plan.segmentCount)
                                    )
                                )
                                self.updateOfficeBatchSegment(
                                    recordID: recordID,
                                    batchID: plan.id,
                                    segmentIndex: segment.index,
                                    status: .rebuilding,
                                    fractionCompleted:
                                        0.14 + value * 0.7
                                )
                            }
                        }
                    }
                    let runtimeEvidence =
                        try await valuePropagatingExclusiveCancellation(
                            from: exportTask,
                            recordID: recordID,
                            operationToken: operationToken
                        )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: outputURL
                    )
                    guard self.record(id: recordID)?.contentRevisionID
                            == plan.sourceRevisionID
                    else {
                        throw PaperPathError.outputVerificationFailed(
                            "the source changed during batch export"
                        )
                    }

                    updateOfficeBatchSegment(
                        recordID: recordID,
                        batchID: plan.id,
                        segmentIndex: segment.index,
                        status: .retaining,
                        fractionCompleted: 0.9
                    )

                    let portfolio = PDFOfficeExportPortfolio(
                        profile: segmentProfile
                    )
                    let receipt = PDFOfficeExportReceipt(
                        format: format,
                        fileName: outputURL.lastPathComponent,
                        fileSizeBytes: Int64(
                            (
                                try? outputURL.resourceValues(
                                    forKeys: [.fileSizeKey]
                                ).fileSize
                            ) ?? 0
                        ),
                        plan: portfolio.plan(for: format),
                        budgetPlan: portfolio.visualBudgetPlan,
                        portfolio: portfolio,
                        runtimeEvidence: runtimeEvidence,
                        batchPlan: plan,
                        batchSegment: segment
                    )
                    guard let retained = await retainOfficeExport(
                        recordID: recordID,
                        receipt: receipt,
                        sourceURL: outputURL,
                        expectedContentRevisionID: plan.sourceRevisionID
                    ) else {
                        throw PaperPathError.storageFailure(
                            "The completed segment could not be retained."
                        )
                    }

                    updateOfficeBatchSegment(
                        recordID: recordID,
                        batchID: plan.id,
                        segmentIndex: segment.index,
                        status: .completed,
                        fractionCompleted: 1,
                        receiptID: retained.receipt.id
                    )
                    await persistOfficeBatchRun(recordID: recordID)
                    try ensureExclusiveDocumentOperationIsCurrent(
                        recordID: recordID,
                        token: operationToken
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    updateOfficeBatchSegment(
                        recordID: recordID,
                        batchID: plan.id,
                        segmentIndex: segment.index,
                        status: .failed,
                        fractionCompleted: 1,
                        failureDetail: AppLocalization
                            .userFacingErrorDescription(error)
                    )
                    await persistOfficeBatchRun(recordID: recordID)
                }
            }

            finishOfficeBatch(recordID: recordID, batchID: plan.id)
            await persistOfficeBatchRun(recordID: recordID)
            return officeBatchRuns[recordID]
        } catch is CancellationError {
            if let queueJobID,
               officeProductionCancelledJobID != queueJobID {
                pauseOfficeBatch(
                    recordID: recordID,
                    batchID: plan.id,
                    selectedSegmentIDs: selectedSegmentIDs
                )
            } else {
                cancelOfficeBatch(
                    recordID: recordID,
                    batchID: plan.id,
                    selectedSegmentIDs: selectedSegmentIDs
                )
            }
            await persistOfficeBatchRun(recordID: recordID)
            if queueJobID != nil {
                throw CancellationError()
            }
            return officeBatchRuns[recordID]
        } catch {
            failOfficeBatch(
                recordID: recordID,
                batchID: plan.id,
                detail: AppLocalization
                    .userFacingErrorDescription(error)
            )
            await persistOfficeBatchRun(recordID: recordID)
            return officeBatchRuns[recordID]
        }
    }

    private func pauseOfficeBatch(
        recordID: UUID,
        batchID: UUID,
        selectedSegmentIDs: Set<UUID>
    ) {
        guard var run = officeBatchRuns[recordID],
              run.id == batchID
        else { return }
        run.completedAt = nil
        run.status = .paused
        for index in run.segments.indices
            where selectedSegmentIDs.contains(run.segments[index].id)
                && run.segments[index].status != .completed
                && run.segments[index].status != .failed {
            run.segments[index].status = .queued
            run.segments[index].fractionCompleted = 0
            run.segments[index].receiptID = nil
            run.segments[index].failureDetail =
                "Interrupted safely. Resume to continue this part."
        }
        officeBatchRuns[recordID] = run
    }

    private func updateOfficeBatchSegment(
        recordID: UUID,
        batchID: UUID,
        segmentIndex: Int,
        status: PDFOfficeBatchSegmentStatus,
        fractionCompleted: Double,
        receiptID: UUID? = nil,
        failureDetail: String? = nil
    ) {
        guard var run = officeBatchRuns[recordID],
              run.id == batchID,
              run.status == .running,
              run.segments.indices.contains(segmentIndex)
        else { return }
        let previous = run.segments[segmentIndex]
        guard !previous.status.isTerminal else { return }
        let boundedFraction = fractionCompleted.isFinite
            ? min(1, max(0, fractionCompleted))
            : previous.fractionCompleted
        run.segments[segmentIndex].status = status
        run.segments[segmentIndex].fractionCompleted = max(
            previous.fractionCompleted,
            boundedFraction
        )
        if let receiptID {
            run.segments[segmentIndex].receiptID = receiptID
        }
        if let failureDetail {
            run.segments[segmentIndex].failureDetail = failureDetail
        }
        officeBatchRuns[recordID] = run
        operationProgress[recordID] = PDFOperationProgress(
            label:
                "Part \(segmentIndex + 1) of \(run.segments.count) · \(status.title.lowercased())",
            fractionCompleted: run.fractionCompleted
        )
    }

    private func markOfficeBatchSourceChanged(
        recordID: UUID,
        batchID: UUID,
        fromSegmentIndex: Int
    ) {
        guard var run = officeBatchRuns[recordID],
              run.id == batchID
        else { return }
        for index in fromSegmentIndex..<run.segments.count
            where run.segments[index].status != .completed {
            run.segments[index].status = index == fromSegmentIndex
                ? .failed
                : .cancelled
            run.segments[index].fractionCompleted = 1
            run.segments[index].failureDetail =
                "The source changed during batch export."
        }
        officeBatchRuns[recordID] = run
    }

    private func finishOfficeBatch(
        recordID: UUID,
        batchID: UUID
    ) {
        guard var run = officeBatchRuns[recordID],
              run.id == batchID
        else { return }
        run.completedAt = PDFOfficeTimeAnchor.process.trustedDate()
        if run.completedCount == run.segments.count {
            run.status = .completed
            noticeMessage = AppLocalization.format(
                "%lld Office parts ready to share",
                run.completedCount
            )
        } else if run.completedCount > 0 {
            run.status = .partial
            noticeMessage = AppLocalization.format(
                "%lld of %lld Office parts completed",
                run.completedCount,
                run.segments.count
            )
        } else {
            run.status = .failed
            noticeMessage = "Office batch could not be completed".localizedUI
        }
        officeBatchRuns[recordID] = run
    }

    private func cancelOfficeBatch(
        recordID: UUID,
        batchID: UUID,
        selectedSegmentIDs: Set<UUID>
    ) {
        guard var run = officeBatchRuns[recordID],
              run.id == batchID
        else { return }
        run.completedAt = PDFOfficeTimeAnchor.process.trustedDate()
        run.status = run.completedCount > 0 ? .partial : .cancelled
        for index in run.segments.indices
            where selectedSegmentIDs.contains(run.segments[index].id)
                && run.segments[index].status != .completed
                && run.segments[index].status != .failed {
            run.segments[index].status = .cancelled
            run.segments[index].fractionCompleted = 1
        }
        officeBatchRuns[recordID] = run
        noticeMessage = "Office batch cancelled".localizedUI
    }

    private func failOfficeBatch(
        recordID: UUID,
        batchID: UUID,
        detail: String
    ) {
        guard var run = officeBatchRuns[recordID],
              run.id == batchID
        else { return }
        run.completedAt = PDFOfficeTimeAnchor.process.trustedDate()
        run.status = run.completedCount > 0 ? .partial : .failed
        if let index = run.segments.firstIndex(
            where: {
                $0.status != .completed
                    && $0.status != .failed
            }
        ) {
            run.segments[index].status = .failed
            run.segments[index].fractionCompleted = 1
            run.segments[index].failureDetail = detail
        }
        officeBatchRuns[recordID] = run
        noticeMessage = detail
    }

    private func restoreOfficeBatchRuns() {
        officeBatchRuns = Dictionary(
            documents.compactMap { record in
                guard let stored = record.officeBatchRun else {
                    return nil
                }
                return (
                    record.id,
                    stored.restored(
                        currentRevisionID: record.contentRevisionID,
                        availableReceiptIDs:
                            availableOfficeBatchReceiptIDs(
                                in: record,
                                for: stored
                            )
                    )
                )
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private func availableOfficeBatchReceiptIDs(
        in record: DocumentRecord,
        for run: PDFOfficeBatchRun
    ) -> Set<UUID> {
        let receiptsByID = Dictionary(
            record.officeReceipts.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        return Set(
            run.segments.compactMap { result in
                guard result.status == .completed,
                      let receiptID = result.receiptID,
                      let receipt = receiptsByID[receiptID],
                      receipt.format == run.plan.format,
                      receipt.batchID == run.id,
                      receipt.batchSegmentIndex
                        == result.segment.index,
                      receipt.batchSegmentCount
                        == run.segments.count,
                      receipt.sourcePageStartIndex
                        == result.segment.startPageIndex,
                      receipt.sourcePageEndIndex
                        == result.segment.endPageIndex,
                      receipt.fileSizeBytes > 0,
                      receipt.artifactAvailability(
                        for: record.contentRevisionID
                      ) == .reusable,
                      receipt.integrityStatus != .missing,
                      receipt.integrityStatus != .mismatch,
                      receipt.integrityStatus != .sourceChanged
                else { return nil }
                return receiptID
            }
        )
    }

    private func refreshOfficeBatchArtifactState(
        recordID: UUID
    ) async {
        do {
            guard let updated = try await store
                .reconcileOfficeBatchArtifacts(for: recordID)
            else { return }
            replace(updated, schedulesMetadataSync: false)
            if officeBatchRuns[recordID] == nil,
               let restored = updated.officeBatchRun {
                officeBatchRuns[recordID] = restored
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func persistOfficeBatchRun(
        recordID: UUID
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updateOfficeBatchRun(
                officeBatchRuns[recordID],
                for: record
            )
            replace(updated, schedulesMetadataSync: false)
        } catch {
            present(error)
        }
    }

    func makePageImageExports(
        recordID: UUID,
        preset: PDFPageImageExportPreset = .png
    ) async -> [URL] {
        guard let sourceURL = documentURLs[recordID],
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Images-\(UUID().uuidString)",
                isDirectory: true
            )
        let label = AppLocalization.format(
            "Exporting %@",
            preset.title.localizedUI
        )
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: 0
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
        }
        do {
            let service = outputService
            let task = Task.detached(priority: .userInitiated) {
                try service.exportPageImages(
                    sourceURL: sourceURL,
                    directory: directory,
                    preset: preset
                ) { value in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.exclusiveDocumentOperationIsCurrent(
                                recordID: recordID,
                                token: operationToken
                              )
                        else { return }
                        self.updateOperationFraction(
                            recordID: recordID,
                            label: label,
                            fractionCompleted: value
                        )
                    }
                }
            }
            let urls = try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            return urls
        } catch is CancellationError {
            await discardTemporaryExportCopies(at: [directory])
            return []
        } catch {
            await discardTemporaryExportCopies(at: [directory])
            present(error)
            return []
        }
    }

    func makeEmbeddedImageExports(
        recordID: UUID
    ) async -> [URL] {
        guard let sourceURL = documentURLs[recordID],
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-EmbeddedImages-\(UUID().uuidString)",
                isDirectory: true
            )
        let label = "Exporting embedded images".localizedUI
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: 0
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
        }
        do {
            let service = outputService
            let task = Task.detached(priority: .userInitiated) {
                try service.exportEmbeddedImages(
                    sourceURL: sourceURL,
                    directory: directory
                ) { value in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.exclusiveDocumentOperationIsCurrent(
                                recordID: recordID,
                                token: operationToken
                              )
                        else { return }
                        self.updateOperationFraction(
                            recordID: recordID,
                            label: label,
                            fractionCompleted: value
                        )
                    }
                }
            }
            let result = try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            let duplicateCount = max(
                0,
                result.occurrenceCount
                    - result.unsupportedOccurrenceCount
                    - result.uniqueImageCount
            )
            let kindSummary = AppLocalization.format(
                "%lld original · %lld lossless PNG",
                result.originalStreamFileCount,
                result.losslessPNGFileCount
            )
            if result.unsupportedOccurrenceCount > 0 {
                noticeMessage = AppLocalization.format(
                    "Exported %lld image%@ (%@); %lld unsupported use%@ skipped",
                    result.uniqueImageCount,
                    result.uniqueImageCount == 1 ? "" : "s",
                    kindSummary,
                    result.unsupportedOccurrenceCount,
                    result.unsupportedOccurrenceCount == 1 ? "" : "s"
                )
            } else if duplicateCount > 0 {
                noticeMessage = AppLocalization.format(
                    "Exported %lld image%@ (%@); %lld repeated use%@ deduplicated",
                    result.uniqueImageCount,
                    result.uniqueImageCount == 1 ? "" : "s",
                    kindSummary,
                    duplicateCount,
                    duplicateCount == 1 ? "" : "s"
                )
            } else {
                noticeMessage = AppLocalization.format(
                    "Exported %lld image%@ (%@)",
                    result.uniqueImageCount,
                    result.uniqueImageCount == 1 ? "" : "s",
                    kindSummary
                )
            }
            return result.urls
        } catch is CancellationError {
            await discardTemporaryExportCopies(at: [directory])
            return []
        } catch {
            await discardTemporaryExportCopies(at: [directory])
            present(error)
            return []
        }
    }

    func rotatePage(
        recordID: UUID,
        index: Int,
        direction: PDFMutationService.RotationDirection = .clockwise
    ) async {
        _ = await performPageMutation(
            recordID: recordID,
            label: (
                direction == .clockwise
                    ? "Rotate page clockwise"
                    : "Rotate page counterclockwise"
            ).localizedUI
        ) { service, url in
            try service.rotatePage(
                at: index,
                direction: direction,
                in: url
            )
        }
    }

    func rotatePages(
        recordID: UUID,
        indices: Set<Int>,
        direction: PDFMutationService.RotationDirection = .clockwise
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                direction == .clockwise
                    ? "Rotate %lld pages clockwise"
                    : "Rotate %lld pages counterclockwise",
                indices.count
            )
        ) { service, url in
            try service.rotatePages(
                at: indices.sorted(),
                direction: direction,
                in: url
            )
        }
    }

    func duplicatePage(recordID: UUID, index: Int) async {
        _ = await duplicatePages(
            recordID: recordID,
            indices: [index]
        )
    }

    func duplicatePages(
        recordID: UUID,
        indices: Set<Int>
    ) async -> Bool {
        guard record(id: recordID) != nil,
              !indices.isEmpty
        else { return false }
        let sorted = indices.sorted()

        func shiftedOriginalPage(_ page: Int) -> Int? {
            page + sorted.prefix { $0 < page }.count
        }

        let succeeded = await performPageMutation(
            recordID: recordID,
            label: sorted.count == 1
                ? "Duplicate page".localizedUI
                : AppLocalization.format(
                    "Duplicate %lld pages",
                    sorted.count
                ),
            navigationTransform: shiftedOriginalPage
        ) { service, url in
            try service.duplicatePages(at: sorted, in: url)
        }
        return succeeded
    }

    func deletePage(recordID: UUID, index: Int) async {
        guard record(id: recordID) != nil else { return }
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Remove page".localizedUI,
            navigationTransform: { page in
                if page == index { return nil }
                return page > index ? page - 1 : page
            }
        ) { service, url in
            try service.deletePage(at: index, in: url)
        }
        guard succeeded else { return }
    }

    func deletePages(
        recordID: UUID,
        indices: Set<Int>
    ) async -> Bool {
        guard record(id: recordID) != nil else { return false }
        let sorted = indices.sorted()
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Remove %lld pages",
                indices.count
            ),
            navigationTransform: { page in
                guard !indices.contains(page) else { return nil }
                let removedBefore = sorted.prefix { $0 < page }.count
                return page - removedBefore
            }
        ) { service, url in
            try service.deletePages(at: sorted, in: url)
        }
        return succeeded
    }

    func movePage(
        recordID: UUID,
        index: Int,
        direction: PDFMutationService.MoveDirection
    ) async {
        guard record(id: recordID) != nil else { return }
        let target = direction == .earlier ? index - 1 : index + 1
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Move page".localizedUI,
            navigationTransform: { page in
                if page == index { return target }
                if page == target { return index }
                return page
            }
        ) { service, url in
            try service.movePage(at: index, direction: direction, in: url)
        }
        guard succeeded else { return }
    }

    func movePage(
        recordID: UUID,
        from sourceIndex: Int,
        to destinationIndex: Int
    ) async {
        guard sourceIndex != destinationIndex,
              record(id: recordID) != nil
        else { return }
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Reorder pages".localizedUI,
            navigationTransform: { page in
                if page == sourceIndex {
                    return destinationIndex
                }
                if sourceIndex < destinationIndex,
                   page > sourceIndex,
                   page <= destinationIndex {
                    return page - 1
                }
                if sourceIndex > destinationIndex,
                   page >= destinationIndex,
                   page < sourceIndex {
                    return page + 1
                }
                return page
            }
        ) { service, url in
            try service.movePage(
                from: sourceIndex,
                to: destinationIndex,
                in: url
            )
        }
        guard succeeded else { return }
    }

    func reorderPages(
        recordID: UUID,
        order: [Int],
        label: String
    ) async -> Bool {
        guard let record = record(id: recordID),
              order.count == record.profile.pageCount,
              Set(order).count == record.profile.pageCount,
              order.allSatisfy({
                  (0..<record.profile.pageCount).contains($0)
              })
        else { return false }
        let destinationBySource = Dictionary(
            order.enumerated().map {
                destination,
                source in
                (source, destination)
            },
            uniquingKeysWith: { current, _ in current }
        )
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: label,
            navigationTransform: {
                destinationBySource[$0]
            }
        ) { service, url in
            try service.reorderPages(order: order, in: url)
        }
        return succeeded
    }

    func replacePage(
        recordID: UUID,
        index: Int,
        from sourceRecordID: UUID,
        sourceIndex: Int,
        expectedDestinationContentRevisionID: UUID,
        expectedSourceContentRevisionID: UUID
    ) async -> Bool {
        guard recordID != sourceRecordID,
              record(id: recordID)?.contentRevisionID
                == expectedDestinationContentRevisionID,
              record(id: sourceRecordID)?.contentRevisionID
                == expectedSourceContentRevisionID,
              let sourceURL = documentURLs[sourceRecordID],
              let sourceOperationToken = acquireExclusiveDocumentOperation(
                recordID: sourceRecordID
              )
        else { return false }
        // Keep the previewed source stable while the destination is prepared.
        defer {
            finishExclusiveDocumentOperation(
                recordID: sourceRecordID,
                token: sourceOperationToken
            )
        }
        let succeeded = await performPageMutation(
            recordID: recordID,
            expectedContentRevisionID:
                expectedDestinationContentRevisionID,
            label: AppLocalization.format(
                "Replace page %lld",
                index + 1
            ),
            clearingTaskCheckpointAt: index
        ) { service, destinationURL in
            try service.replacePage(
                at: index,
                withPageAt: sourceIndex,
                from: sourceURL,
                in: destinationURL
            )
        }
        return succeeded
    }

    func prepareExternalPageSource(
        from sourceURL: URL
    ) async -> PDFExternalPageSource? {
        let hasAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let id = UUID()
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-Replacement-"
        )
        let temporaryURL = temporaryArtifact.fileURL
        do {
            let service = mutationService
            let maximumBytes =
                Self.maximumExternalPageSourceBytes
            let task = Task.detached(
                priority: .userInitiated
            ) {
                try Task.checkCancellation()
                let sourceValues = try sourceURL.resourceValues(
                    forKeys: [
                        .fileSizeKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                )
                guard sourceValues.isRegularFile == true,
                      sourceValues.isSymbolicLink != true,
                      let sourceSize = sourceValues.fileSize,
                      sourceSize > 0
                else {
                    throw PaperPathError.unreadablePDF
                }
                guard Int64(sourceSize)
                    <= maximumBytes
                else {
                    throw PaperPathError.fileTooLarge
                }
                try Task.checkCancellation()
                try temporaryArtifact.copy(
                    from: sourceURL,
                    expectedByteCount: Int64(sourceSize)
                )
                let copiedValues = try temporaryURL.resourceValues(
                    forKeys: [
                        .fileSizeKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                )
                guard copiedValues.isRegularFile == true,
                      copiedValues.isSymbolicLink != true,
                      copiedValues.fileSize == sourceSize
                else {
                    throw PaperPathError.unreadablePDF
                }
                try Task.checkCancellation()
                let assessment = try service
                    .pageGeometryAssessment(
                        in: temporaryURL,
                        revisionID: id,
                        pageIndices: [0]
                    )
                let size = try temporaryURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize.map(Int64.init) ?? 0
                return PDFExternalPageSource(
                    id: id,
                    url: temporaryURL,
                    displayName: sourceURL
                        .deletingPathExtension()
                        .lastPathComponent,
                    byteCount: size,
                    assessment: assessment
                )
            }
            return try await valuePropagatingCancellation(from: task)
        } catch is CancellationError {
            await Self.removeTemporaryReplacementFile(
                at: temporaryURL
            )
            return nil
        } catch {
            await Self.removeTemporaryReplacementFile(
                at: temporaryURL
            )
            present(error)
            return nil
        }
    }

    func prepareImagePageSource(
        images: [UIImage],
        options: ScanProcessingOptions,
        displayName: String
    ) async -> PDFExternalPageSource? {
        await prepareImagePageSource(
            pages: images.map {
                ScanPageImage(
                    image: $0,
                    processingOptions: options
                )
            },
            displayName: displayName
        )
    }

    func prepareImagePageSource(
        pages: [ScanPageImage],
        displayName: String
    ) async -> PDFExternalPageSource? {
        guard !pages.isEmpty, pages.count <= 24 else {
            present(PaperPathError.unreadableImage)
            return nil
        }
        let id = UUID()
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-Replacement-"
        )
        let temporaryURL = temporaryArtifact.fileURL
        do {
            let renderer = scanRenderer
            let assessmentService = mutationService
            let task = Task.detached(
                priority: .userInitiated
            ) {
                try Task.checkCancellation()
                try temporaryArtifact.prepare()
                try renderer.render(
                    pages: pages,
                    to: temporaryURL,
                    options: .document
                )
                try Task.checkCancellation()
                try LocalFileSecurity.requireCompleteProtection(
                    to: temporaryURL
                )
                let assessment = try assessmentService
                    .pageGeometryAssessment(
                        in: temporaryURL,
                        revisionID: id,
                        pageIndices: [0]
                    )
                let size = try temporaryURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize.map(Int64.init) ?? 0
                return PDFExternalPageSource(
                    id: id,
                    url: temporaryURL,
                    displayName: String(displayName.prefix(80)),
                    byteCount: size,
                    assessment: assessment
                )
            }
            return try await valuePropagatingCancellation(from: task)
        } catch is CancellationError {
            await Self.removeTemporaryReplacementFile(
                at: temporaryURL
            )
            return nil
        } catch {
            await Self.removeTemporaryReplacementFile(
                at: temporaryURL
            )
            present(error)
            return nil
        }
    }

    func discardExternalPageSource(
        _ source: PDFExternalPageSource
    ) {
        let url = source.url
        Task.detached(priority: .utility) {
            await Self.removeTemporaryReplacementFile(at: url)
        }
    }

    nonisolated private static func removeTemporaryReplacementFile(
        at url: URL
    ) async {
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: ["PaperPath-Replacement-"]
            )
        }.value
    }

    func replacePage(
        recordID: UUID,
        index: Int,
        from source: PDFExternalPageSource,
        sourceIndex: Int,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        guard record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else { return false }
        let succeeded = await performPageMutation(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            label: AppLocalization.format(
                "Replace page %lld",
                index + 1
            ),
            clearingTaskCheckpointAt: index
        ) { service, destinationURL in
            try service.replacePage(
                at: index,
                withPageAt: sourceIndex,
                from: source.url,
                in: destinationURL
            )
        }
        return succeeded
    }

    @discardableResult
    func addInk(
        recordID: UUID,
        payload: PDFInkPayload,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        guard record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else {
            noticeMessage =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            return false
        }
        let succeeded = await mutate(
            recordID: recordID,
            expectedContentRevisionID:
                expectedContentRevisionID,
            invalidatesAnalysis: false,
            snapshotLabel: payload.placement == .signature
                ? "Add signature".localizedUI
                : "Add drawing".localizedUI
        ) {
            service,
            url in
            try service.addInk(payload, in: url)
        }
        guard succeeded else { return false }
        if payload.placement == .signature {
            await setActionCompletion(
                recordID: recordID,
                action: .sign,
                completed: true
            )
            let checkpoint = await checkpointAfterSignature(
                recordID: recordID,
                signaturePageIndex: payload.pageIndex
            )
            let checkpointSaved = await updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: checkpoint,
                presentsFeedback: false
            )
            if checkpointSaved {
                noticeMessage = checkpoint.stage == .verify
                    ? "Signature added · Verify & Share is ready"
                        .localizedUI
                    : AppLocalization.format(
                        "Signature added · %@",
                        checkpoint.stage.title.localizedUI
                    )
            } else {
                noticeMessage =
                    "Signature added · reopen the form to refresh the next step"
                        .localizedUI
            }
        }
        return true
    }

    private func checkpointAfterSignature(
        recordID: UUID,
        signaturePageIndex: Int
    ) async -> DocumentTaskCheckpoint {
        let contentRevisionID = record(id: recordID)?
            .contentRevisionID
        guard let url = documentURLs[recordID] else {
            return DocumentTaskCheckpoint(
                stage: .fillForm,
                contentRevisionID: contentRevisionID
            )
        }
        do {
            let task = Task.detached(priority: .utility) {
                try PDFFormInspectionService().inspect(url: url)
            }
            let report = try await valuePropagatingCancellation(
                from: task
            )
            try Task.checkCancellation()
            if let next = report.incompleteRequiredFields.first {
                return DocumentTaskCheckpoint(
                    stage: next.kind == .signature ? .sign : .fillForm,
                    pageIndex: next.pageIndex,
                    fieldName: next.name,
                    normalizedBounds: next.kind == .signature
                        ? next.normalizedBounds
                        : nil,
                    contentRevisionID: contentRevisionID
                )
            }
            if report.hasXFA {
                return DocumentTaskCheckpoint(
                    stage: .fillForm,
                    contentRevisionID: contentRevisionID
                )
            }
        } catch {
            return DocumentTaskCheckpoint(
                stage: .fillForm,
                contentRevisionID: contentRevisionID
            )
        }
        return DocumentTaskCheckpoint(
            stage: .verify,
            pageIndex: signaturePageIndex,
            contentRevisionID: contentRevisionID
        )
    }

    func addStamp(
        recordID: UUID,
        pageIndex: Int,
        kind: PDFStampKind
    ) async {
        let succeeded = await mutate(
            recordID: recordID,
            invalidatesAnalysis: false,
            snapshotLabel: AppLocalization.format(
                "Add %@ stamp",
                kind.title.localizedUI
            )
        ) { service, url in
            try service.addStamp(
                kind,
                toPageAt: pageIndex,
                in: url
            )
        }
        if succeeded {
            noticeMessage = AppLocalization.format(
                "%@ stamp added",
                kind.title.localizedUI
            )
        }
    }

    @discardableResult
    func applyPageNumbers(
        recordID: UUID,
        payload: PDFPageNumberingPayload
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Number %lld pages",
                payload.pageIndices.count
            ),
            invalidatesAnalysis: false
        ) { service, url in
            try service.applyPageNumbers(payload, in: url)
        }
    }

    @discardableResult
    func removeGeneratedPageNumbers(
        recordID: UUID
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: "Remove page numbers".localizedUI,
            invalidatesAnalysis: false
        ) { service, url in
            _ = try service.removeGeneratedPageNumbers(
                in: url
            )
        }
    }

    @discardableResult
    func applyBatesNumbers(
        recordID: UUID,
        payload: PDFBatesNumberingPayload
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Bates number %lld pages",
                payload.pageIndices.count
            ),
            invalidatesAnalysis: false
        ) { service, url in
            try service.applyBatesNumbers(payload, in: url)
        }
    }

    private func beginBatesBatchMutation() -> UUID? {
        guard batesBatchMutationToken == nil,
              batesReceiptVerificationToken == nil
        else {
            noticeMessage =
                "Another Bates operation is already running. Finish or stop it before starting a new one."
                    .localizedUI
            return nil
        }
        let token = UUID()
        batesBatchMutationToken = token
        isBatesBatchMutationActive = true
        return token
    }

    private func finishBatesBatchMutation(_ token: UUID) {
        guard batesBatchMutationToken == token else { return }
        batesBatchMutationToken = nil
        batesBatchProgress = nil
        isBatesBatchMutationActive = false
    }

    private func beginBatesReceiptVerification() -> UUID? {
        guard batesReceiptVerificationToken == nil,
              batesBatchMutationToken == nil
        else {
            noticeMessage =
                "Another Bates operation is already running. Finish or stop it before starting a new one."
                    .localizedUI
            return nil
        }
        let token = UUID()
        batesReceiptVerificationToken = token
        batesReceiptVerificationProgress = nil
        isBatesReceiptVerificationActive = true
        return token
    }

    private func finishBatesReceiptVerification(_ token: UUID) {
        guard batesReceiptVerificationToken == token else { return }
        batesReceiptVerificationToken = nil
        batesReceiptVerificationProgress = nil
        isBatesReceiptVerificationActive = false
    }

    func batesBatchPlan(
        recordIDs: [UUID],
        startNumber: Int64,
        digitCount: Int,
        prefix: String,
        suffix: String,
        position: PDFPageNumberPosition
    ) throws -> PDFBatesBatchPlan {
        let records = recordIDs.compactMap(record(id:))
        guard records.count == recordIDs.count else {
            throw PaperPathError.insufficientSelection(
                "A selected working copy is unavailable."
            )
        }
        return try PDFBatesBatchPlan(
            records: records,
            startNumber: startNumber,
            digitCount: digitCount,
            prefix: prefix,
            suffix: suffix,
            position: position
        )
    }

    @discardableResult
    func applyBatesNumbersBatch(
        _ plan: PDFBatesBatchPlan
    ) async -> Bool {
        guard let batchToken = beginBatesBatchMutation()
        else { return false }
        defer { finishBatesBatchMutation(batchToken) }
        let recordIDs = plan.items.map(\.recordID)
        guard let operationTokens =
                acquireExclusiveDocumentOperations(
                    recordIDs: recordIDs
                )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }

        let label = AppLocalization.format(
            "Bates number %lld PDFs",
            plan.items.count
        )
        var backups: [UUID: URL] = [:]
        var preparedCopies: [PreparedPDFWorkingCopy] = []
        var keepsBackupsForUndo = false
        defer {
            for prepared in preparedCopies {
                removePageMutationTemporaryItem(
                    containing: prepared.preparedURL
                )
            }
            if !keepsBackupsForUndo {
                for backup in backups.values {
                    removePageMutationTemporaryItem(
                        containing: backup
                    )
                }
            }
        }

        do {
            let sourceURLs = try plan.items.map { item in
                guard let url = documentURLs[item.recordID] else {
                    throw PaperPathError.storageFailure(
                        "A selected working copy is unavailable."
                    )
                }
                return url
            }
            let store = self.store
            let capacityTask = Task {
                try await store.ensureTemporaryWorkingCapacity(
                    for: sourceURLs,
                    copyMultiplier: 6,
                    reserveBytes: 32 * 1_024 * 1_024
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: capacityTask,
                operationTokens: operationTokens
            )
            var recordsByID: [UUID: DocumentRecord] = [:]
            var completedPages = 0
            for (offset, item) in plan.items.enumerated() {
                try Task.checkCancellation()
                guard let record = record(id: item.recordID),
                      record.contentRevisionID
                        == item.sourceRevisionID,
                      record.isWorkingCopy,
                      !record.profile.isLocked,
                      documentURLs[item.recordID] != nil
                else {
                    throw PaperPathError.insufficientSelection(
                        "A selected PDF changed before numbering began."
                    )
                }
                recordsByID[item.recordID] = record
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .snapshotting,
                    completedDocumentCount: offset,
                    totalDocumentCount: plan.items.count,
                    completedPageCount: 0,
                    totalPageCount: plan.totalPageCount,
                    currentDocumentName: item.sourceName
                )
                let snapshotTask = Task {
                    try await store.createVersionSnapshot(
                        for: record,
                        label: label
                    )
                }
                _ = try await valuePropagatingExclusiveCancellation(
                    from: snapshotTask,
                    operationTokens: operationTokens
                )
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .snapshotting,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: plan.items.count,
                    completedPageCount: 0,
                    totalPageCount: plan.totalPageCount,
                    currentDocumentName: item.sourceName
                )
            }

            for (offset, item) in plan.items.enumerated() {
                try Task.checkCancellation()
                guard let sourceURL = documentURLs[item.recordID]
                else {
                    throw PaperPathError.storageFailure(
                        "A selected working copy is unavailable."
                    )
                }
                let backupArtifact = ProtectedTemporaryPDF(
                    prefix: "PaperPath-Bates-Undo-"
                )
                let preparedArtifact = ProtectedTemporaryPDF(
                    prefix: "PaperPath-Bates-Prepared-"
                )
                let backupURL = backupArtifact.fileURL
                let preparedURL = preparedArtifact.fileURL
                let payload = plan.payload(for: item)
                let mutationService = self.mutationService
                let preparationTask = Task.detached(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    try backupArtifact.prepare()
                    try preparedArtifact.prepare()
                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: backupURL
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: backupURL
                    )
                    try FileManager.default.copyItem(
                        at: backupURL,
                        to: preparedURL
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: preparedURL
                    )
                    try mutationService.applyBatesNumbers(
                        payload,
                        in: preparedURL
                    )
                }
                do {
                    try await valuePropagatingExclusiveCancellation(
                        from: preparationTask,
                        operationTokens: operationTokens
                    )
                } catch {
                    backupArtifact.remove()
                    preparedArtifact.remove()
                    throw error
                }
                backups[item.recordID] = backupURL
                preparedCopies.append(
                    PreparedPDFWorkingCopy(
                        recordID: item.recordID,
                        sourceRevisionID: item.sourceRevisionID,
                        preparedURL: preparedURL
                    )
                )
                let (nextCompletedPages, pageCountOverflow) =
                    completedPages.addingReportingOverflow(
                        item.pageCount
                    )
                guard !pageCountOverflow,
                      nextCompletedPages <= plan.totalPageCount
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the Bates batch page count changed during preparation"
                    )
                }
                completedPages = nextCompletedPages
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .preparing,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: plan.items.count,
                    completedPageCount: completedPages,
                    totalPageCount: plan.totalPageCount,
                    currentDocumentName: item.sourceName
                )
            }

            guard plan.items.allSatisfy({
                backups[$0.recordID] != nil
                    && recordsByID[$0.recordID] != nil
            }) else {
                throw PaperPathError.storageFailure(
                    "A batch recovery copy is unavailable."
                )
            }
            try Task.checkCancellation()
            batesBatchProgress = PDFBatesBatchProgress(
                stage: .committing,
                completedDocumentCount: 0,
                totalDocumentCount: plan.items.count,
                completedPageCount: plan.totalPageCount,
                totalPageCount: plan.totalPageCount,
                currentDocumentName: "All selected PDFs".localizedUI
            )
            let copiesToCommit = preparedCopies
            let commitTask = Task {
                try await store
                    .replaceWorkingCopiesAndCreateBatesReceipt(
                        with: copiesToCommit,
                        plan: plan
                    )
            }
            let commit =
                try await valueCompletingAtomicExclusiveCommit(
                    from: commitTask,
                    operationTokens: operationTokens
                )
            let updatedRecords = commit.records
            guard let issuedReceipt = commit.batesReceipt else {
                throw PaperPathError.storageFailure(
                    "The Bates receipt was not included in its transaction."
                )
            }
            batesBatchReceipts = (
                try? await store.loadBatesBatchReceipts()
            ) ?? [issuedReceipt]

            for (offset, updated) in updatedRecords.enumerated() {
                replace(updated)
                deliveryPreflightCache[updated.id] = nil
                refreshTokens[updated.id, default: 0] += 1
                if let previous = pageMutationUndos[updated.id] {
                    removePageMutationTemporaryItem(
                        containing: previous.backupURL
                    )
                }
                if let backup = backups[updated.id],
                   recordsByID[updated.id] != nil {
                    pageMutationUndos[updated.id] = PageMutationUndo(
                        backupURL: backup,
                        expectedRevisionID:
                            updated.contentRevisionID,
                        bookmarkedPages: updated.bookmarkedPages,
                        bookmarkNames: updated.bookmarkNames,
                        lastPageIndex: updated.lastPageIndex,
                        taskCheckpoint: updated.taskCheckpoint,
                        label: label
                    )
                }
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .committing,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: plan.items.count,
                    completedPageCount: plan.totalPageCount,
                    totalPageCount: plan.totalPageCount,
                    currentDocumentName: updated.displayName
                )
            }
            keepsBackupsForUndo = true
            presentActionNotice(
                message: AppLocalization.format(
                    "%lld PDFs Bates numbered",
                    updatedRecords.count
                ),
                detail: AppLocalization.format(
                    "%lld pages share one continuous sequence. Signed receipt saved.",
                    plan.totalPageCount
                ),
                kind: .recovery,
                action: .undoPageChanges(
                    recordIDs: updatedRecords.map(\.id)
                )
            )
            return true
        } catch is CancellationError {
            noticeMessage =
                "Batch numbering stopped. No PDFs changed.".localizedUI
            return false
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func removeBatesNumbersBatch(
        receiptID: UUID
    ) async -> Bool {
        guard let receipt = batesBatchReceipts.first(
            where: { $0.id == receiptID }
        ) else {
            noticeMessage =
                "This Bates receipt is no longer available.".localizedUI
            return false
        }
        guard receipt.removal == nil else {
            noticeMessage =
                "This Bates batch already has a signed removal receipt."
                    .localizedUI
            return false
        }
        let entries = receipt.payload.entries
        let recordIDs = entries.map(\.recordID)
        guard !entries.isEmpty,
              entries.count <= PDFBatesBatchPlan.maximumDocumentCount,
              receipt.payload.totalPageCount
                <= PDFBatesBatchPlan.maximumPageCount
        else { return false }
        guard let batchToken = beginBatesBatchMutation()
        else { return false }
        defer { finishBatesBatchMutation(batchToken) }
        guard
              let operationTokens =
                acquireExclusiveDocumentOperations(
                    recordIDs: recordIDs
                )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
            if batesReceiptVerificationProgress?.receiptID
                == receiptID {
                batesReceiptVerificationProgress = nil
            }
        }

        let label = AppLocalization.format(
            "Remove Bates from %lld PDFs",
            entries.count
        )
        var backups: [UUID: URL] = [:]
        var preparedCopies: [PreparedPDFWorkingCopy] = []
        var keepsBackupsForUndo = false
        defer {
            for prepared in preparedCopies {
                removePageMutationTemporaryItem(
                    containing: prepared.preparedURL
                )
            }
            if !keepsBackupsForUndo {
                for backup in backups.values {
                    removePageMutationTemporaryItem(
                        containing: backup
                    )
                }
            }
        }

        do {
            batesReceiptVerificationProgress =
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receiptID,
                    completedDocumentCount: 0,
                    totalDocumentCount: entries.count,
                    currentDocumentName:
                        "Checking numbered PDFs".localizedUI
                )
            let store = self.store
            let verificationTask = Task {
                try await store.verifyBatesBatchReceipt(
                    receipt
                ) { [weak self] progress in
                    self?.batesReceiptVerificationProgress = progress
                }
            }
            let verification =
                try await valuePropagatingExclusiveCancellation(
                    from: verificationTask,
                    operationTokens: operationTokens
                )
            batesReceiptVerificationProgress = nil
            guard verification.signatureStatus == .verified,
                  verification.items.count == entries.count,
                  verification.items.allSatisfy({
                      $0.status == .current
                  })
            else {
                throw PaperPathError.insufficientSelection(
                    "Every PDF must still match the signed numbered batch before removal."
                )
            }

            let sourceURLs = try entries.map { entry in
                guard let url = documentURLs[entry.recordID] else {
                    throw PaperPathError.storageFailure(
                        "A numbered working copy is unavailable."
                    )
                }
                return url
            }
            let capacityTask = Task {
                try await store.ensureTemporaryWorkingCapacity(
                    for: sourceURLs,
                    copyMultiplier: 5,
                    reserveBytes: 32 * 1_024 * 1_024
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: capacityTask,
                operationTokens: operationTokens
            )
            var recordsByID: [UUID: DocumentRecord] = [:]
            for (offset, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard let record = record(id: entry.recordID),
                      record.deletedAt == nil,
                      record.isWorkingCopy,
                      !record.profile.isLocked,
                      record.profile.pageCount == entry.pageCount,
                      record.contentRevisionID == entry.outputRevisionID,
                      documentURLs[entry.recordID] != nil
                else {
                    throw PaperPathError.insufficientSelection(
                        "A numbered PDF changed before removal began."
                    )
                }
                recordsByID[entry.recordID] = record
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .snapshotting,
                    completedDocumentCount: offset,
                    totalDocumentCount: entries.count,
                    completedPageCount: 0,
                    totalPageCount: receipt.payload.totalPageCount,
                    currentDocumentName: entry.displayName
                )
                let snapshotTask = Task {
                    try await store.createVersionSnapshot(
                        for: record,
                        label: label
                    )
                }
                _ = try await valuePropagatingExclusiveCancellation(
                    from: snapshotTask,
                    operationTokens: operationTokens
                )
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .snapshotting,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: entries.count,
                    completedPageCount: 0,
                    totalPageCount: receipt.payload.totalPageCount,
                    currentDocumentName: entry.displayName
                )
            }

            var completedPages = 0
            for (offset, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard let sourceURL = documentURLs[entry.recordID]
                else {
                    throw PaperPathError.storageFailure(
                        "A numbered working copy is unavailable."
                    )
                }
                let backupArtifact = ProtectedTemporaryPDF(
                    prefix: "PaperPath-Bates-Removal-Undo-"
                )
                let preparedArtifact = ProtectedTemporaryPDF(
                    prefix: "PaperPath-Bates-Removal-"
                )
                let backupURL = backupArtifact.fileURL
                let preparedURL = preparedArtifact.fileURL
                let mutationService = self.mutationService
                let preparationTask = Task.detached(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    try backupArtifact.prepare()
                    try preparedArtifact.prepare()
                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: backupURL
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: backupURL
                    )
                    try FileManager.default.copyItem(
                        at: backupURL,
                        to: preparedURL
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: preparedURL
                    )
                    let removed = try mutationService
                        .removeGeneratedBatesNumbers(
                            in: preparedURL
                        )
                    guard removed == entry.pageCount else {
                        throw PaperPathError.outputVerificationFailed(
                            "the numbered PDF did not contain one Bates identifier per page"
                        )
                    }
                }
                do {
                    try await valuePropagatingExclusiveCancellation(
                        from: preparationTask,
                        operationTokens: operationTokens
                    )
                } catch {
                    backupArtifact.remove()
                    preparedArtifact.remove()
                    throw error
                }
                backups[entry.recordID] = backupURL
                preparedCopies.append(
                    PreparedPDFWorkingCopy(
                        recordID: entry.recordID,
                        sourceRevisionID: entry.outputRevisionID,
                        preparedURL: preparedURL
                    )
                )
                let (nextCompletedPages, pageCountOverflow) =
                    completedPages.addingReportingOverflow(
                        entry.pageCount
                    )
                guard !pageCountOverflow,
                      nextCompletedPages
                        <= receipt.payload.totalPageCount
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "the Bates removal page count changed during preparation"
                    )
                }
                completedPages = nextCompletedPages
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .removing,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: entries.count,
                    completedPageCount: completedPages,
                    totalPageCount: receipt.payload.totalPageCount,
                    currentDocumentName: entry.displayName
                )
            }

            guard entries.allSatisfy({
                backups[$0.recordID] != nil
                    && recordsByID[$0.recordID] != nil
            }) else {
                throw PaperPathError.storageFailure(
                    "A Bates removal recovery copy is unavailable."
                )
            }
            try Task.checkCancellation()
            batesBatchProgress = PDFBatesBatchProgress(
                stage: .committing,
                completedDocumentCount: 0,
                totalDocumentCount: entries.count,
                completedPageCount: receipt.payload.totalPageCount,
                totalPageCount: receipt.payload.totalPageCount,
                currentDocumentName: "All numbered PDFs".localizedUI
            )
            let copiesToCommit = preparedCopies
            let commitTask = Task {
                try await store
                    .replaceWorkingCopiesAndCreateBatesRemovalReceipt(
                        with: copiesToCommit,
                        receiptID: receiptID
                    )
            }
            let commit =
                try await valueCompletingAtomicExclusiveCommit(
                    from: commitTask,
                    operationTokens: operationTokens
                )
            guard let updatedReceipt = commit.batesReceipt,
                  updatedReceipt.removal != nil
            else {
                throw PaperPathError.storageFailure(
                    "The Bates removal receipt was not included in its transaction."
                )
            }
            batesBatchReceipts = (
                try? await store.loadBatesBatchReceipts()
            ) ?? [updatedReceipt]

            for (offset, updated) in commit.records.enumerated() {
                replace(updated)
                deliveryPreflightCache[updated.id] = nil
                refreshTokens[updated.id, default: 0] += 1
                if let previous = pageMutationUndos[updated.id] {
                    removePageMutationTemporaryItem(
                        containing: previous.backupURL
                    )
                }
                if let backup = backups[updated.id],
                   let original = recordsByID[updated.id] {
                    pageMutationUndos[updated.id] = PageMutationUndo(
                        backupURL: backup,
                        expectedRevisionID:
                            updated.contentRevisionID,
                        bookmarkedPages: original.bookmarkedPages,
                        bookmarkNames: original.bookmarkNames,
                        lastPageIndex: original.lastPageIndex,
                        taskCheckpoint: original.taskCheckpoint,
                        label: label
                    )
                }
                batesBatchProgress = PDFBatesBatchProgress(
                    stage: .committing,
                    completedDocumentCount: offset + 1,
                    totalDocumentCount: entries.count,
                    completedPageCount:
                        receipt.payload.totalPageCount,
                    totalPageCount:
                        receipt.payload.totalPageCount,
                    currentDocumentName: updated.displayName
                )
            }
            keepsBackupsForUndo = true
            presentActionNotice(
                message: AppLocalization.format(
                    "Bates removed from %lld PDFs",
                    commit.records.count
                ),
                detail: AppLocalization.format(
                    "%lld pages cleared. Signed removal receipt saved.",
                    receipt.payload.totalPageCount
                ),
                kind: .recovery,
                action: .undoPageChanges(
                    recordIDs: commit.records.map(\.id)
                )
            )
            return true
        } catch is CancellationError {
            noticeMessage =
                "Batch removal stopped. No PDFs changed.".localizedUI
            return false
        } catch {
            present(error)
            return false
        }
    }

    func verifyBatesBatchReceipt(
        receiptID: UUID
    ) async -> PDFBatesBatchReceiptVerificationReport? {
        guard let receipt = batesBatchReceipts.first(
            where: { $0.id == receiptID }
        ) else {
            noticeMessage =
                "This Bates receipt is no longer available.".localizedUI
            return nil
        }
        guard let verificationToken =
                beginBatesReceiptVerification()
        else { return nil }
        defer {
            finishBatesReceiptVerification(verificationToken)
        }
        do {
            batesReceiptVerificationProgress =
                PDFBatesBatchReceiptVerificationProgress(
                    receiptID: receiptID,
                    completedDocumentCount: 0,
                    totalDocumentCount:
                        receipt.payload.documentCount,
                    currentDocumentName:
                        "Signed manifest".localizedUI
                )
            let report = try await store.verifyBatesBatchReceipt(
                receipt
            ) { [weak self] progress in
                guard self?.batesReceiptVerificationToken
                        == verificationToken
                else { return }
                self?.batesReceiptVerificationProgress = progress
            }
            guard batesReceiptVerificationToken == verificationToken
            else { return nil }
            return report
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func exportBatesBatchReceipt(
        receiptID: UUID
    ) async -> URL? {
        do {
            let url = try await store.exportBatesBatchReceipt(
                receiptID: receiptID
            )
            guard !Task.isCancelled else {
                await discardTemporaryExportCopies(at: [url])
                return nil
            }
            return url
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func inspectExternalBatesBatchReceipt(
        at sourceURL: URL
    ) async -> PDFBatesBatchReceiptInspection? {
        guard let verificationToken =
                beginBatesReceiptVerification()
        else { return nil }
        defer {
            finishBatesReceiptVerification(verificationToken)
        }
        do {
            let inspection = try await store
                .inspectExternalBatesBatchReceipt(
                    at: sourceURL
                ) { [weak self] progress in
                    guard self?.batesReceiptVerificationToken
                            == verificationToken
                    else { return }
                    self?.batesReceiptVerificationProgress =
                        progress
                }
            guard batesReceiptVerificationToken == verificationToken
            else { return nil }
            return inspection
        } catch is CancellationError {
            return nil
        } catch {
            guard batesReceiptVerificationToken == verificationToken
            else { return nil }
            present(error)
            return nil
        }
    }

    @discardableResult
    func retainExternalBatesBatchReceipt(
        _ receipt: PDFSignedBatesBatchReceipt
    ) async -> Bool {
        do {
            batesBatchReceipts = try await store
                .retainExternalBatesBatchReceipt(receipt)
            noticeMessage = "Bates receipt saved locally".localizedUI
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func matchExternalBatesPDFs(
        receipt: PDFSignedBatesBatchReceipt,
        candidateURLs: [URL]
    ) async -> PDFBatesExternalMatchReport? {
        let generation = UUID()
        batesExternalMatchGeneration = generation
        batesExternalMatchProgress = nil
        do {
            let report = try await store.matchExternalBatesPDFs(
                receipt: receipt,
                candidateURLs: candidateURLs
            ) { [weak self] progress in
                guard self?.batesExternalMatchGeneration == generation
                else { return }
                self?.batesExternalMatchProgress = progress
            }
            guard batesExternalMatchGeneration == generation
            else { return nil }
            if batesExternalMatchProgress?.receiptID
                == receipt.id {
                batesExternalMatchProgress = nil
            }
            return report
        } catch is CancellationError {
            if batesExternalMatchGeneration == generation {
                batesExternalMatchProgress = nil
            }
            return nil
        } catch {
            guard batesExternalMatchGeneration == generation
            else { return nil }
            batesExternalMatchProgress = nil
            present(error)
            return nil
        }
    }

    func exportSignedBatesMatchReport(
        receipt: PDFSignedBatesBatchReceipt,
        report: PDFBatesExternalMatchReport
    ) async -> URL? {
        do {
            let url = try await store.exportSignedBatesMatchReport(
                receipt: receipt,
                report: report
            )
            guard !Task.isCancelled else {
                await discardTemporaryExportCopies(at: [url])
                return nil
            }
            return url
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func inspectExternalBatesMatchReport(
        at sourceURL: URL
    ) async -> PDFBatesMatchReportInspection? {
        do {
            return try await store.inspectExternalBatesMatchReport(
                at: sourceURL
            )
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    @discardableResult
    func deleteBatesBatchReceipt(
        receiptID: UUID
    ) async -> Bool {
        do {
            batesBatchReceipts = try await store
                .deleteBatesBatchReceipt(receiptID: receiptID)
            noticeMessage = "Bates receipt deleted".localizedUI
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func removeGeneratedBatesNumbers(
        recordID: UUID
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: "Remove Bates numbers".localizedUI,
            invalidatesAnalysis: false
        ) { service, url in
            _ = try service.removeGeneratedBatesNumbers(
                in: url
            )
        }
    }

    @discardableResult
    func applyWatermark(
        recordID: UUID,
        payload: PDFWatermarkPayload
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Watermark %lld pages",
                payload.pageIndices.count
            ),
            invalidatesAnalysis: false
        ) { service, url in
            try service.applyWatermark(payload, in: url)
        }
    }

    @discardableResult
    func removeGeneratedWatermarks(
        recordID: UUID
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: "Remove watermarks".localizedUI,
            invalidatesAnalysis: false
        ) { service, url in
            _ = try service.removeGeneratedWatermarks(
                in: url
            )
        }
    }

    @discardableResult
    func addFormField(
        recordID: UUID,
        payload: PDFFormFieldPayload,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        guard record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else {
            noticeMessage =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            return false
        }
        let succeeded = await mutate(
            recordID: recordID,
            expectedContentRevisionID: expectedContentRevisionID,
            invalidatesAnalysis: false,
            snapshotLabel: AppLocalization.format(
                "Add %@ field",
                payload.kind.title.localizedUI
            )
        ) { service, url in
            try service.addFormField(payload, in: url)
        }
        if succeeded {
            noticeMessage = AppLocalization.format(
                "%@ field added",
                payload.kind.title.localizedUI
            )
        }
        return succeeded
    }

    func inspectForm(
        recordID: UUID
    ) async throws -> PDFFormInspectionReport {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        let task = Task.detached(priority: .utility) {
            try PDFFormInspectionService().inspect(url: url)
        }
        let report = try await valuePropagatingCancellation(from: task)
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID
                == record.contentRevisionID
        else {
            throw CancellationError()
        }
        return report
    }

    @discardableResult
    func refreshFormAutomation(
        recordID: UUID,
        expectedContentRevisionID: UUID? = nil,
        presentsFeedback: Bool = true
    ) async -> Bool {
        let succeeded = await mutate(
            recordID: recordID,
            expectedContentRevisionID: expectedContentRevisionID,
            invalidatesAnalysis: false,
            snapshotLabel: "Refresh form calculations".localizedUI,
            presentsFeedback: presentsFeedback
        ) { service, url in
            try service.refreshFormAutomation(in: url)
        }
        if succeeded {
            noticeMessage =
                "Calculations refreshed and field formats validated"
        }
        return succeeded
    }

    func insertBlankPage(
        recordID: UUID,
        at insertionIndex: Int
    ) async {
        guard let record = record(id: recordID) else { return }
        guard insertionIndex >= 0,
              insertionIndex <= record.profile.pageCount
        else { return }
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Insert page".localizedUI,
            navigationTransform: {
                $0 >= insertionIndex ? $0 + 1 : $0
            }
        ) { service, url in
            try service.insertBlankPage(
                at: insertionIndex,
                in: url
            )
        }
        guard succeeded else { return }
    }

    func insertBlankPage(recordID: UUID, after index: Int) async {
        await insertBlankPage(
            recordID: recordID,
            at: index + 1
        )
    }

    func appendPages(recordID: UUID, from sourceURL: URL) async {
        guard let prepared = await prepareExternalPageSource(
            from: sourceURL
        ) else { return }
        defer { discardExternalPageSource(prepared) }
        _ = await performPageMutation(
            recordID: recordID,
            label: "Add pages".localizedUI
        ) { service, url in
            try service.appendPages(from: prepared.url, in: url)
        }
    }

    func copyPages(
        from sourceRecordID: UUID,
        indices: Set<Int>,
        to destinationRecordID: UUID
    ) async -> Bool {
        guard sourceRecordID != destinationRecordID,
              let sourceURL = documentURLs[sourceRecordID],
              !indices.isEmpty,
              let sourceOperationToken = acquireExclusiveDocumentOperation(
                recordID: sourceRecordID
              )
        else { return false }
        defer {
            finishExclusiveDocumentOperation(
                recordID: sourceRecordID,
                token: sourceOperationToken
            )
        }
        let sorted = indices.sorted()
        let succeeded = await performPageMutation(
            recordID: destinationRecordID,
            label: AppLocalization.format(
                "Copy %lld pages",
                indices.count
            )
        ) { service, destinationURL in
            try service.appendPages(
                from: sourceURL,
                indices: sorted,
                in: destinationURL
            )
        }
        if succeeded {
            noticeMessage = AppLocalization.format(
                "%lld page%@ copied",
                indices.count,
                indices.count == 1 ? "" : "s"
            )
        }
        return succeeded
    }

    func cropPage(
        recordID: UUID,
        index: Int,
        insetFraction: Double
    ) async {
        let inset = max(0, min(insetFraction, 0.18))
        _ = await cropPage(
            recordID: recordID,
            index: index,
            insets: PDFPageCropInsets(
                top: inset,
                right: inset,
                bottom: inset,
                left: inset
            )
        )
    }

    func cropPage(
        recordID: UUID,
        index: Int,
        insets: PDFPageCropInsets
    ) async -> Bool {
        await performPageMutation(
            recordID: recordID,
            label: "Trim margins".localizedUI
        ) { service, url in
            try service.cropPage(
                at: index,
                insets: insets,
                in: url
            )
        }
    }

    func cropPages(
        recordID: UUID,
        insetsByPage: [Int: PDFPageCropInsets]
    ) async -> Bool {
        guard !insetsByPage.isEmpty else { return false }
        return await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Prepare %lld pages",
                insetsByPage.count
            )
        ) { service, url in
            try service.cropPages(
                insetsByPage,
                in: url
            )
        }
    }

    func pageGeometryItem(
        recordID: UUID,
        pageIndex: Int
    ) async -> PDFPagePreparationItem? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID],
              (0..<record.profile.pageCount).contains(pageIndex)
        else { return nil }
        let requestedRevision = record.contentRevisionID
        let cacheKey = PDFPageAssessmentCacheKey(
            recordID: recordID,
            revisionID: requestedRevision
        )
        if let cached = pageAssessmentCache[cacheKey],
           let item = cached.pages.first(
               where: { $0.pageIndex == pageIndex }
           ) {
            touchPageAssessmentCache(cacheKey)
            return item
        }
        let service = mutationService
        let task = Task.detached(priority: .userInitiated) {
            try service.pageGeometryAssessment(
                in: sourceURL,
                revisionID: requestedRevision,
                pageIndices: [pageIndex]
            )
        }
        do {
            let assessment = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                == requestedRevision
            else { return nil }
            return assessment.pages.first
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func pageGeometryItem(
        source: PDFExternalPageSource,
        pageIndex: Int
    ) async -> PDFPagePreparationItem? {
        guard (0..<source.pageCount).contains(pageIndex) else {
            return nil
        }
        if let item = source.assessment.pages.first(
            where: { $0.pageIndex == pageIndex }
        ) {
            return item
        }
        let service = mutationService
        let task = Task.detached(priority: .userInitiated) {
            try service.pageGeometryAssessment(
                in: source.url,
                revisionID: source.id,
                pageIndices: [pageIndex]
            )
        }
        do {
            let assessment = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            return assessment.pages.first
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func pagePreparationAssessment(
        recordID: UUID
    ) async -> PDFPagePreparationAssessment? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else { return nil }
        let requestedRevision = record.contentRevisionID
        let cacheKey = PDFPageAssessmentCacheKey(
            recordID: recordID,
            revisionID: requestedRevision
        )
        if let cached = pageAssessmentCache[cacheKey] {
            touchPageAssessmentCache(cacheKey)
            return cached
        }
        let label = "Inspecting page geometry".localizedUI
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: 0
        )
        defer {
            if operationProgress[recordID]?.label == label {
                operationProgress[recordID] = nil
            }
        }
        let service = mutationService
        let task = Task.detached(priority: .userInitiated) {
            try service.pagePreparationAssessment(
                in: sourceURL,
                revisionID: requestedRevision
            ) { value in
                Task { @MainActor [weak self] in
                    guard self?.record(id: recordID)?
                        .contentRevisionID == requestedRevision,
                          self?.operationProgress[recordID]?.label
                            == label
                    else { return }
                    self?.operationProgress[recordID]
                        = PDFOperationProgress(
                            label: label,
                            fractionCompleted: value
                        )
                }
            }
        }
        do {
            let assessment = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                == requestedRevision
            else {
                return nil
            }
            pageAssessmentCache[cacheKey] = assessment
            touchPageAssessmentCache(cacheKey)
            while pageAssessmentCacheOrder.count > 8 {
                let oldest = pageAssessmentCacheOrder.removeFirst()
                pageAssessmentCache[oldest] = nil
            }
            return assessment
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    private func touchPageAssessmentCache(
        _ key: PDFPageAssessmentCacheKey
    ) {
        pageAssessmentCacheOrder.removeAll { $0 == key }
        pageAssessmentCacheOrder.append(key)
    }

    func canUndoPageChange(recordID: UUID) -> Bool {
        guard let undo = pageMutationUndos[recordID],
              record(id: recordID)?.contentRevisionID
                == undo.expectedRevisionID
        else { return false }
        return FileManager.default.fileExists(
            atPath: undo.backupURL.path
        )
    }

    func pageRecoveryRevision(recordID: UUID, after sourceRevisionID: UUID) -> UUID? {
        guard let undo = pageMutationUndos[recordID],
              undo.sourceRevisionID == sourceRevisionID,
              record(id: recordID)?.contentRevisionID == undo.expectedRevisionID
        else { return nil }
        return undo.expectedRevisionID
    }

    func undoLastPageChange(
        recordID: UUID,
        expectedContentRevisionID: UUID? = nil
    ) async -> Bool {
        if let expectedContentRevisionID,
           record(id: recordID)?.contentRevisionID != expectedContentRevisionID {
            noticeMessage =
                "The PDF changed after that recovery point. No changes were undone.".localizedUI
            return false
        }
        guard let undo = pageMutationUndos[recordID],
              let record = record(id: recordID)
        else {
            noticeMessage =
                "That recovery point is no longer available."
                    .localizedUI
            return false
        }
        guard record.contentRevisionID
                == undo.expectedRevisionID,
              FileManager.default.fileExists(
                atPath: undo.backupURL.path
              )
        else {
            discardPageMutationUndo(recordID: recordID)
            noticeMessage =
                "The PDF changed after that recovery point. No changes were undone."
                    .localizedUI
            return false
        }
        guard let operationToken = acquireExclusiveDocumentOperation(
            recordID: recordID
        )
        else { return false }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            let store = self.store
            let snapshotTask = Task {
                try await store.createVersionSnapshot(
                    for: record,
                    label: AppLocalization.format(
                        "Undo %@",
                        undo.label.localizedUI
                    )
                )
            }
            _ = try await valuePropagatingExclusiveCancellation(
                from: snapshotTask,
                recordID: recordID,
                operationToken: operationToken
            )
            let restoreTask = Task {
                try await store.replaceWorkingCopies(
                    with: [
                        PreparedPDFWorkingCopy(
                            recordID: recordID,
                            sourceRevisionID:
                                record.contentRevisionID,
                            preparedURL: undo.backupURL,
                            restoredBookmarkedPages:
                                undo.bookmarkedPages,
                            restoredBookmarkNames:
                                undo.bookmarkNames,
                            restoredLastPageIndex:
                                undo.lastPageIndex,
                            restoredTaskCheckpoint:
                                undo.taskCheckpoint,
                            restoresNavigationState: true
                        )
                    ],
                    invalidateAnalysis: true
                )
            }
            let restored =
                try await valueCompletingAtomicExclusiveCommit(
                    from: restoreTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            guard let refreshed = restored.first(
                where: { $0.id == recordID }
            ) else {
                throw PaperPathError.storageFailure(
                    "The page recovery did not commit."
                )
            }
            replace(refreshed)
            textIndices[recordID] = nil
            setOCRResult(nil, for: recordID)
            refreshTokens[recordID, default: 0] += 1
            pageMutationUndos[recordID] = nil
            removePageMutationTemporaryItem(
                containing: undo.backupURL
            )
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            await analyzeDocument(recordID: recordID)
            guard exclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            ) else { return true }
            noticeMessage = AppLocalization.format(
                "%@ undone",
                undo.label.localizedUI
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    private func undoLastPageChanges(
        recordIDs: [UUID]
    ) async -> Bool {
        let orderedIDs = recordIDs.reduce(into: [UUID]()) {
            result,
            id in
            if !result.contains(id) {
                result.append(id)
            }
        }
        let entries = orderedIDs.compactMap { id -> (
            record: DocumentRecord,
            undo: PageMutationUndo
        )? in
            guard let record = record(id: id),
                  let undo = pageMutationUndos[id],
                  record.contentRevisionID
                    == undo.expectedRevisionID,
                  FileManager.default.fileExists(
                      atPath: undo.backupURL.path
                  )
            else { return nil }
            return (record, undo)
        }
        guard entries.count == orderedIDs.count else {
            for id in orderedIDs
            where !entries.contains(where: { $0.record.id == id }) {
                discardPageMutationUndo(recordID: id)
            }
            noticeMessage =
                "One or more PDFs changed after that recovery point. No changes were undone."
                    .localizedUI
            return false
        }
        guard let operationTokens =
            acquireExclusiveDocumentOperations(
                recordIDs: orderedIDs
            )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }

        do {
            for entry in entries {
                let store = self.store
                let snapshotTask = Task {
                    try await store.createVersionSnapshot(
                        for: entry.record,
                        label: AppLocalization.format(
                            "Undo %@",
                            entry.undo.label.localizedUI
                        )
                    )
                }
                _ = try await valuePropagatingExclusiveCancellation(
                    from: snapshotTask,
                    operationTokens: operationTokens
                )
            }
            let prepared = entries.map {
                PreparedPDFWorkingCopy(
                    recordID: $0.record.id,
                    sourceRevisionID:
                        $0.record.contentRevisionID,
                    preparedURL: $0.undo.backupURL,
                    restoredBookmarkedPages:
                        $0.undo.bookmarkedPages,
                    restoredBookmarkNames:
                        $0.undo.bookmarkNames,
                    restoredLastPageIndex:
                        $0.undo.lastPageIndex,
                    restoredTaskCheckpoint:
                        $0.undo.taskCheckpoint,
                    restoresNavigationState: true
                )
            }
            let store = self.store
            let restoreTask = Task {
                try await store.replaceWorkingCopies(
                    with: prepared,
                    invalidateAnalysis: true
                )
            }
            let restored =
                try await valueCompletingAtomicExclusiveCommit(
                    from: restoreTask,
                    operationTokens: operationTokens
                )
            for record in restored {
                replace(record)
                textIndices[record.id] = nil
                setOCRResult(nil, for: record.id)
                deliveryPreflightCache[record.id] = nil
                refreshTokens[record.id, default: 0] += 1
                if let undo = pageMutationUndos.removeValue(
                    forKey: record.id
                ) {
                    removePageMutationTemporaryItem(
                        containing: undo.backupURL
                    )
                }
            }
            guard operationTokens.allSatisfy({
                exclusiveDocumentOperationIsCurrent(
                    recordID: $0.key,
                    token: $0.value
                )
            }) else { return true }
            for record in restored {
                guard !Task.isCancelled else { break }
                await analyzeDocument(recordID: record.id)
            }
            guard operationTokens.allSatisfy({
                exclusiveDocumentOperationIsCurrent(
                    recordID: $0.key,
                    token: $0.value
                )
            }) else { return true }
            noticeMessage = AppLocalization.format(
                "%lld PDFs restored",
                restored.count
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func refreshAfterAnnotation(recordID: UUID) async {
        guard let record = record(id: recordID) else { return }
        do {
            let refreshed = try await store.refresh(record)
            replace(refreshed)
            refreshTokens[recordID, default: 0] += 1
            await synchronizeCompletionState(recordID: recordID)
            noticeMessage = "Markup saved in the working copy".localizedUI
        } catch {
            present(error)
        }
    }

    func annotations(recordID: UUID) async -> [PDFAnnotationSnapshot] {
        await annotationInventory(recordID: recordID).annotations
    }

    func annotationInventory(
        recordID: UUID
    ) async -> PDFAnnotationInventory {
        do {
            return try await inspectAnnotationInventory(recordID: recordID)
        } catch is CancellationError {
            return .empty
        } catch {
            present(error)
            return .empty
        }
    }

    func inspectAnnotationInventory(
        recordID: UUID
    ) async throws -> PDFAnnotationInventory {
        try Task.checkCancellation()
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { throw PaperPathError.unreadablePDF }
        let displayLimit = 10_000
        let mutationService = self.mutationService
        let structureService = documentStructureService
        let task = Task.detached(priority: .utility) {
            let editable = try mutationService.annotations(
                in: url,
                limit: displayLimit + 1
            )
            try Task.checkCancellation()
            if editable.count > displayLimit {
                return PDFAnnotationInventory(
                    annotations: Array(
                        editable.prefix(displayLimit)
                    ),
                    isTruncated: true,
                    displayLimit: displayLimit
                )
            }
            let remaining = displayLimit - editable.count
            let preserved = try structureService.unsupportedReviewAnnotations(
                in: url,
                resultLimit: remaining + 1
            )
            let combined = (editable + preserved).sorted {
                if $0.pageIndex != $1.pageIndex {
                    return $0.pageIndex < $1.pageIndex
                }
                if $0.canRemove != $1.canRemove { return $0.canRemove }
                return $0.annotationIndex < $1.annotationIndex
            }
            return PDFAnnotationInventory(
                annotations: Array(combined.prefix(displayLimit)),
                isTruncated: combined.count > displayLimit,
                displayLimit: displayLimit
            )
        }
        let inventory = try await valuePropagatingCancellation(from: task)
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID == record.contentRevisionID
        else { throw CancellationError() }
        return inventory
    }

    func technicalInspection(
        recordID: UUID,
        unlockPassword: String? = nil
    ) async -> PDFTechnicalInspection? {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return nil }
        let source = try? await store.sourceLocation(for: record)
        do {
            let service = documentStructureService
            let task = Task.detached(priority: .userInitiated) {
                try service.technicalInspection(
                    in: url,
                    profile: record.profile,
                    source: source,
                    unlockPassword: unlockPassword
                )
            }
            let inspection = try await valuePropagatingCancellation(
                from: task
            )
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else { return nil }
            return inspection
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func embeddedAttachments(
        recordID: UUID
    ) async -> [PDFEmbeddedAttachmentSnapshot] {
        do {
            return try await inspectEmbeddedAttachments(recordID: recordID)
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
    }

    func inspectEmbeddedAttachments(
        recordID: UUID
    ) async throws -> [PDFEmbeddedAttachmentSnapshot] {
        try Task.checkCancellation()
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { throw PaperPathError.unreadablePDF }
        let service = documentStructureService
        let task = Task.detached(priority: .utility) {
            try service.attachments(in: url)
        }
        let attachments = try await valuePropagatingCancellation(from: task)
        try Task.checkCancellation()
        guard self.record(id: recordID)?.contentRevisionID == record.contentRevisionID
        else { throw CancellationError() }
        return attachments
    }

    func pageLabels(
        recordID: UUID
    ) async -> [PDFPageLabelSnapshot] {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return [] }
        do {
            let service = documentStructureService
            let task = Task.detached(priority: .utility) {
                try service.pageLabels(in: url)
            }
            let labels = try await valuePropagatingCancellation(
                from: task
            )
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else { return [] }
            return labels
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
    }

    func makeAttachmentExportCopies(
        recordID: UUID,
        attachmentIDs: Set<String>,
        expectedContentRevisionID: UUID,
        presentsFeedback: Bool = true
    ) async -> [URL] {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID,
              let sourceURL = documentURLs[recordID],
              !attachmentIDs.isEmpty,
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return [] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Attachments-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            let service = documentStructureService
            let task = Task.detached(
                priority: .userInitiated
            ) {
                try service.extractAttachments(
                    in: sourceURL,
                    matching: attachmentIDs,
                    to: directory
                )
            }
            let urls = try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            guard self.record(id: recordID)?.contentRevisionID
                    == expectedContentRevisionID
            else {
                await discardAttachmentExportCopies(at: [directory])
                noticeMessage =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                return []
            }
            noticeMessage = AppLocalization.format(
                "%lld attachment%@ extracted and byte-verified",
                urls.count,
                urls.count == 1 ? "" : "s"
            )
            return urls
        } catch is CancellationError {
            await discardAttachmentExportCopies(at: [directory])
            return []
        } catch {
            await discardAttachmentExportCopies(at: [directory])
            if presentsFeedback && !Task.isCancelled {
                present(error)
            }
            return []
        }
    }

    func discardAttachmentExportCopies(
        at urls: [URL]
    ) async {
        guard let firstURL = urls.first else { return }
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: firstURL,
                allowedPrefixes: ["PaperPath-Attachments-"]
            )
        }.value
    }

    func discardTemporaryExportCopies(
        at urls: [URL]
    ) async {
        guard !urls.isEmpty else { return }
        await Task.detached(priority: .utility) {
            let allowedPrefixes = [
                "PaperPath-Images-",
                "PaperPath-EmbeddedImages-",
                "PaperPath-Office-Batch-",
                "PaperPath-Office-Export-",
                PaperPathTemporaryArtifact.officeSharePrefix,
                "PaperPath-DocumentExport-",
                "PaperPath-Bates-",
                "PaperPath-Delivery-Match-",
                "PaperPath-FilesExport-"
            ]
            let items = Set(urls.compactMap {
                PaperPathTemporaryArtifact.managedTopLevelItem(
                    containing: $0,
                    allowedPrefixes: allowedPrefixes
                )
            })
            for item in items {
                PaperPathTemporaryArtifact.removeManagedItem(
                    containing: item,
                    allowedPrefixes: allowedPrefixes
                )
            }
        }.value
    }

    func editAnnotation(
        recordID: UUID,
        payload: PDFAnnotationEditPayload,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        let succeeded = await performPageMutation(
            recordID: recordID,
            expectedContentRevisionID: expectedContentRevisionID,
            label: "Edit annotation".localizedUI,
            invalidatesAnalysis: false
        ) {
            service,
            url in
            try service.editAnnotation(payload, in: url)
        }
        if succeeded {
            await synchronizeCompletionState(recordID: recordID)
        }
        return succeeded
    }

    @discardableResult
    func removeAnnotation(
        recordID: UUID,
        annotation: PDFAnnotationSnapshot,
        expectedContentRevisionID: UUID
    ) async -> Bool {
        await removeAnnotations(
            recordID: recordID,
            annotations: [annotation],
            expectedContentRevisionID: expectedContentRevisionID
        )
    }

    @discardableResult
    func removeAnnotations(
        recordID: UUID,
        annotations: [PDFAnnotationSnapshot],
        expectedContentRevisionID: UUID
    ) async -> Bool {
        let removable = annotations.filter(\.canRemove)
        guard removable.count == annotations.count,
              !removable.isEmpty
        else {
            present(
                PaperPathError.insufficientSelection(
                    "Select at least one removable annotation."
                )
            )
            return false
        }
        let label = removable.count == 1
            ? "Remove annotation".localizedUI
            : AppLocalization.format(
                "Remove %lld annotations",
                removable.count
            )
        let targets = removable.map(
            PDFAnnotationRemovalTarget.init(annotation:)
        )
        let succeeded = await performPageMutation(
            recordID: recordID,
            expectedContentRevisionID: expectedContentRevisionID,
            label: label,
            invalidatesAnalysis: false
        ) {
            service,
            url in
            _ = try service.removeAnnotations(
                targets,
                in: url
            )
        }
        if succeeded {
            await synchronizeCompletionState(recordID: recordID)
        }
        return succeeded
    }

    func setActionCompletion(
        recordID: UUID,
        action: DocumentAction,
        completed: Bool,
        expectedContentRevisionID: UUID? = nil
    ) async {
        guard let record = record(id: recordID),
              expectedContentRevisionID == nil || record.contentRevisionID == expectedContentRevisionID,
              record.completedActions.contains(action) != completed
        else { return }
        do {
            let updated = try await store.setActionCompletion(
                record,
                action: action,
                completed: completed,
                expectedContentRevisionID: expectedContentRevisionID
            )
            replace(updated)
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    @discardableResult
    func updateTaskCheckpoint(
        recordID: UUID,
        checkpoint: DocumentTaskCheckpoint?,
        presentsFeedback: Bool = true,
        expectedContentRevisionID: UUID? = nil
    ) async -> Bool {
        guard expectedContentRevisionID == nil
                || record(id: recordID)?.contentRevisionID == expectedContentRevisionID,
              !Task.isCancelled
        else { return false }
        guard let record = record(id: recordID),
              record.taskCheckpoint != checkpoint
        else {
            return record(id: recordID) != nil
        }
        do {
            let updated = try await store.updateTaskCheckpoint(
                record,
                checkpoint: checkpoint
            )
            replace(updated, schedulesMetadataSync: false)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if presentsFeedback {
                present(error)
            }
            return false
        }
    }

    func synchronizeCompletionState(recordID: UUID) async {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return }
        let mutationService = self.mutationService
        do {
            let task = Task.detached(priority: .utility) {
                let hasSignature = try mutationService
                    .containsSignature(in: url)
                try Task.checkCancellation()
                let report = try PDFFormInspectionService().inspect(url: url)
                return (hasSignature, report)
            }
            let state = try await valuePropagatingCancellation(
                from: task
            )
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else { return }
            await setActionCompletion(
                recordID: recordID,
                action: .sign,
                completed: state.0
            )
            if record.profile.formFieldCount > 0
                || !state.1.fields.isEmpty {
                await setActionCompletion(
                    recordID: recordID,
                    action: .reviewForm,
                    completed: state.1.isReadyForVerifiedOutput
                )
            }
            guard let currentRecord = self.record(id: recordID),
                  currentRecord.contentRevisionID
                    == record.contentRevisionID
            else { return }
            let currentCheckpoint = currentRecord.taskCheckpoint
            let incompleteRequiredFields =
                state.1.incompleteRequiredFields
            let resumableCheckpoint = currentCheckpoint.flatMap {
                checkpoint -> DocumentTaskCheckpoint? in
                guard checkpoint.contentRevisionID
                        == currentRecord.contentRevisionID,
                      checkpoint.stage != .verify,
                      checkpoint.pageIndex != nil
                        || checkpoint.fieldName != nil
                else { return nil }
                let targetIsStillIncomplete =
                    incompleteRequiredFields.contains { field in
                        let fieldStage: DocumentTaskStage =
                            field.kind == .signature
                                ? .sign
                                : .fillForm
                        guard fieldStage == checkpoint.stage else {
                            return false
                        }
                        if let pageIndex = checkpoint.pageIndex,
                           pageIndex != field.pageIndex {
                            return false
                        }
                        if let fieldName = checkpoint.fieldName,
                           fieldName != field.name {
                            return false
                        }
                        if let normalizedBounds =
                            checkpoint.normalizedBounds,
                           normalizedBounds != field.normalizedBounds {
                            return false
                        }
                        return true
                    }
                return targetIsStillIncomplete ? checkpoint : nil
            }
            let nextCheckpoint: DocumentTaskCheckpoint?
            if let resumableCheckpoint {
                nextCheckpoint = resumableCheckpoint
            } else if let nextField = incompleteRequiredFields.first {
                nextCheckpoint = DocumentTaskCheckpoint(
                    stage: nextField.kind == .signature
                        ? .sign
                        : .fillForm,
                    pageIndex: nextField.pageIndex,
                    fieldName: nextField.name,
                    normalizedBounds:
                        nextField.kind == .signature
                            ? nextField.normalizedBounds
                            : nil,
                    contentRevisionID:
                        currentRecord.contentRevisionID
                )
            } else if state.1.hasXFA {
                nextCheckpoint = DocumentTaskCheckpoint(
                    stage: .fillForm,
                    contentRevisionID:
                        currentRecord.contentRevisionID
                )
            } else if (
                (
                    currentRecord.profile.formFieldCount > 0
                        || !state.1.fields.isEmpty
                )
                    && state.1.isReadyForVerifiedOutput
            ) || state.0 {
                nextCheckpoint = DocumentTaskCheckpoint(
                    stage: .verify,
                    pageIndex: currentCheckpoint?.pageIndex,
                    contentRevisionID:
                        currentRecord.contentRevisionID
                )
            } else if let currentCheckpoint {
                nextCheckpoint = currentCheckpoint.rebased(
                    to: currentRecord.contentRevisionID
                )
            } else {
                nextCheckpoint = nil
            }
            await updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: nextCheckpoint,
                presentsFeedback: false
            )
        } catch {
            return
        }
    }

    func record(id: UUID) -> DocumentRecord? {
        documentRecordsByID[id]
    }

    var workingDocuments: [DocumentRecord] {
        workingDocumentCache
    }

    var deliveryOutputs: [DocumentRecord] {
        deliveryOutputCache
    }

    var verifiedDeliveryOutputCount: Int {
        verifiedDeliveryOutputCountCache
    }

    func duplicateFingerprintCount(
        for record: DocumentRecord
    ) -> Int {
        guard record.isWorkingCopy,
              let fingerprint = record.contentFingerprint
        else { return 0 }
        return workingFingerprintCounts[fingerprint, default: 0]
    }

    func verifiedOutputs(
        for sourceDocumentID: UUID
    ) -> [DocumentRecord] {
        verifiedOutputsBySourceID[sourceDocumentID] ?? []
    }

    func deliveryHistoryOutputs(
        for sourceDocumentID: UUID
    ) -> [DocumentRecord] {
        deliveryHistoryBySourceID[sourceDocumentID] ?? []
    }

    func sourceRecord(
        for output: DocumentRecord
    ) -> DocumentRecord? {
        guard let sourceDocumentID = output.sourceDocumentID else {
            return nil
        }
        return record(id: sourceDocumentID)
    }

    func verifiedShareTarget(
        for recordID: UUID
    ) -> DocumentRecord? {
        verifiedShareTargetsByRecordID[recordID]
    }

    func url(for recordID: UUID) -> URL? {
        documentURLs[recordID]
    }

    func comparePDFs(
        sourceRecordID: UUID,
        revisedRecordID: UUID,
        manualMatches: [PDFManualPageMatch]? = nil,
        progress: @escaping @MainActor @Sendable (
            PDFComparisonProgress
        ) -> Void = { _ in }
    ) async throws -> PDFChangeReview {
        guard !isClearingPageMatches,
              !isErasingAllLocalData
        else {
            throw PaperPathError.insufficientSelection(
                "Local storage is being updated. Try the comparison again when it finishes."
            )
        }
        let recordIDs = Set([
            sourceRecordID,
            revisedRecordID
        ])
        guard recordIDs.allSatisfy({
            !isProcessing($0)
        }) else {
            throw PaperPathError.insufficientSelection(
                "A selected PDF is busy. Wait for its task to finish or stop it."
            )
        }
        return try await performTrackedComparison(
            recordIDs: recordIDs
        ) {
            workGeneration in
            try await self.comparePDFsCore(
                sourceRecordID: sourceRecordID,
                revisedRecordID: revisedRecordID,
                manualMatches: manualMatches,
                workGeneration: workGeneration,
                progress: progress
            )
        }
    }

    private func comparePDFsCore(
        sourceRecordID: UUID,
        revisedRecordID: UUID,
        manualMatches: [PDFManualPageMatch]?,
        workGeneration: UUID,
        progress: @escaping @MainActor @Sendable (
            PDFComparisonProgress
        ) -> Void
    ) async throws -> PDFChangeReview {
        guard sourceRecordID != revisedRecordID,
              let sourceRecord = record(id: sourceRecordID),
              let revisedRecord = record(id: revisedRecordID),
              let sourceURL = documentURLs[sourceRecordID],
              let revisedURL = documentURLs[revisedRecordID]
        else {
            throw PaperPathError.insufficientSelection(
                "Choose two different PDFs to compare."
            )
        }
        let key = PDFComparisonCacheKey(
            sourceRecordID: sourceRecordID,
            sourceRevisionID: sourceRecord.contentRevisionID,
            revisedRecordID: revisedRecordID,
            revisedRevisionID: revisedRecord.contentRevisionID
        )
        if manualMatches == nil,
           let cached = comparisonCache[key] {
            touchComparisonCache(key)
            progress(
                PDFComparisonProgress(
                    stage: .complete,
                    completedPageCount: cached.comparedPageCount,
                    totalPageCount: cached.comparedPageCount,
                    fractionCompleted: 1
                )
            )
            return cached
        }
        let correctionLookup:
            PDFManualPageMatchCorrectionLookup =
            if manualMatches == nil {
                try await store.pageMatchCorrection(
                    context: .documentPair,
                    sourceDocumentID: sourceRecordID,
                    sourceRevisionID:
                        sourceRecord.contentRevisionID,
                    revisedDocumentID: revisedRecordID,
                    revisedRevisionID:
                        revisedRecord.contentRevisionID,
                    versionSnapshotID: nil,
                    sourcePageCount:
                        sourceRecord.profile.pageCount,
                    revisedPageCount:
                        revisedRecord.profile.pageCount
                )
            } else {
                .none
            }
        let restoredCorrection = correctionLookup.correction
        let resolvedManualMatches =
            manualMatches
                ?? restoredCorrection?.matches
                ?? []
        let comparedReview = try await comparisonCoordinator.compare(
            sourceURL: sourceURL,
            revisedURL: revisedURL,
            manualMatches: resolvedManualMatches
        ) { update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeComparisonTasks[workGeneration]
                        != nil
                else { return }
                progress(update)
            }
        }
        try Task.checkCancellation()
        guard activeComparisonTasks[workGeneration] != nil,
              record(id: sourceRecordID)?.contentRevisionID
                == sourceRecord.contentRevisionID,
              record(id: revisedRecordID)?.contentRevisionID
                == revisedRecord.contentRevisionID
        else {
            throw CancellationError()
        }
        let persistence:
            PDFManualPageMatchPersistence?
        if manualMatches != nil {
            if comparedReview.resolvedManualPageMatches.isEmpty {
                try await store.removePageMatchCorrection(
                    context: .documentPair,
                    sourceDocumentID: sourceRecordID,
                    revisedDocumentID: revisedRecordID,
                    versionSnapshotID: nil
                )
                persistence = nil
            } else {
                let evictedCount =
                    try await store.savePageMatchCorrection(
                        PDFManualPageMatchCorrection(
                            context: .documentPair,
                            sourceDocumentID: sourceRecordID,
                            sourceRevisionID:
                                sourceRecord.contentRevisionID,
                            revisedDocumentID: revisedRecordID,
                            revisedRevisionID:
                                revisedRecord.contentRevisionID,
                            versionSnapshotID: nil,
                            sourcePageCount:
                                sourceRecord.profile.pageCount,
                            revisedPageCount:
                                revisedRecord.profile.pageCount,
                            matches: comparedReview
                                .resolvedManualPageMatches,
                            updatedAt: Date()
                        )
                    )
                if evictedCount > 0 {
                    noticeMessage = AppLocalization.format(
                        "%lld older saved comparison record%@ removed to stay within the local limit",
                        evictedCount,
                        evictedCount == 1 ? "" : "s"
                    )
                }
                persistence = .savedOnDevice
            }
        } else {
            persistence = restoredCorrection == nil
                ? nil
                : .restoredFromDevice
            if correctionLookup.discardedStaleCorrection {
                noticeMessage =
                    "Saved page matches were reset because one of the compared PDFs changed."
                        .localizedUI
            }
        }
        try Task.checkCancellation()
        guard activeComparisonTasks[workGeneration] != nil else {
            throw CancellationError()
        }
        let review = comparedReview
            .markingManualPageMatchPersistence(persistence)
        if manualMatches != nil {
            invalidateComparisonCaches(
                between: Set([
                    sourceRecordID,
                    revisedRecordID
                ]),
                preserving: key
            )
        }
        comparisonCache[key] = review
        touchComparisonCache(key)
        trimComparisonCache()
        return review
    }

    private func touchComparisonCache(
        _ key: PDFComparisonCacheKey
    ) {
        comparisonCacheOrder.removeAll { $0 == key }
        comparisonCacheOrder.append(key)
    }

    private func invalidateComparisonCaches(
        between recordIDs: Set<UUID>,
        preserving retainedKey: PDFComparisonCacheKey? = nil
    ) {
        guard recordIDs.count == 2 else { return }
        let keys = comparisonCache.keys.filter { key in
            key != retainedKey
                && Set([
                    key.sourceRecordID,
                    key.revisedRecordID
                ]) == recordIDs
        }
        for key in keys {
            comparisonCache[key] = nil
        }
        let keySet = Set(keys)
        comparisonCacheOrder.removeAll {
            keySet.contains($0)
        }
    }

    private func trimComparisonCache() {
        var estimatedBytes = comparisonCache.values.reduce(
            Int64.zero
        ) {
            saturatedCacheCost(
                $0,
                $1.estimatedCacheByteCount
            )
        }
        while comparisonCacheOrder.count > 1 {
            let exceedsCount = comparisonCacheOrder.count > 6
            let exceedsBytes =
                estimatedBytes > Self.maximumComparisonCacheBytes
            guard exceedsCount || exceedsBytes else { break }
            let oldest = comparisonCacheOrder.removeFirst()
            if let removed = comparisonCache.removeValue(
                forKey: oldest
            ) {
                estimatedBytes = max(
                    0,
                    estimatedBytes
                        - removed.estimatedCacheByteCount
                )
            }
        }
    }

    private func saturatedCacheCost(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(max(0, rhs))
        return overflow ? .max : sum
    }

    func makeChangeReport(
        review: PDFChangeReview,
        descriptor: PDFChangeReportDescriptor,
        validatingRevisions: [UUID: UUID],
        localLink: PDFRetainedChangeReportLocalLink? = nil
    ) async -> URL? {
        guard validatingRevisions.allSatisfy({
            record(id: $0.key)?.contentRevisionID == $0.value
        }) else {
            present(
                PaperPathError.outputVerificationFailed(
                    "a compared PDF changed before the report was created"
                )
            )
            return nil
        }
        let generatedAt: Date
        do {
            generatedAt = try await store
                .trustedEvidenceIssuanceDate()
        } catch {
            present(error)
            return nil
        }
        let trustedDescriptor = PDFChangeReportDescriptor(
            reportID: descriptor.reportID,
            scope: descriptor.scope,
            sourceName: descriptor.sourceName,
            revisedName: descriptor.revisedName,
            sourceRevisionID: descriptor.sourceRevisionID,
            revisedRevisionID: descriptor.revisedRevisionID,
            sourceFingerprint: descriptor.sourceFingerprint,
            revisedFingerprint: descriptor.revisedFingerprint,
            deliveryReceiptID: descriptor.deliveryReceiptID,
            generatedAt: generatedAt
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-ChangeReport-\(UUID().uuidString)",
                isDirectory: true
            )
        let reportName = safeExportName(descriptor.revisedName)
            + "-changes.md"
        do {
            let signerKeyID = try await store
                .officeDeliverySigningKeyID()
            try Task.checkCancellation()
            let renderTask = Task.detached(priority: .utility) {
                let service = PDFChangeReportService()
                let body = try service.render(
                    review: review,
                    descriptor: trustedDescriptor,
                    signerKeyID: signerKeyID
                )
                let payload = try service.signaturePayload(
                    body: body,
                    review: review,
                    descriptor: trustedDescriptor
                )
                return (body, payload)
            }
            let (body, payload) = try await valuePropagatingCancellation(
                from: renderTask
            )
            try Task.checkCancellation()
            let envelope = try await store.signChangeReportPayload(
                payload
            )
            try Task.checkCancellation()
            let writeReferenceDate = await store
                .trustedDeliveryDate()
            let writeTask = Task.detached(priority: .utility) {
                try PDFChangeReportService().create(
                    body: body,
                    envelope: envelope,
                    directory: directory,
                    fileName: reportName,
                    referenceDate: writeReferenceDate
                )
            }
            let url = try await valuePropagatingCancellation(
                from: writeTask
            )
            try Task.checkCancellation()
            guard validatingRevisions.allSatisfy({
                record(id: $0.key)?.contentRevisionID == $0.value
            }) else {
                await discardChangeReport(at: url)
                throw PaperPathError.outputVerificationFailed(
                    "a compared PDF changed while the report was being created"
                )
            }
            do {
                _ = try await store.retainChangeReport(
                    at: url,
                    localLink: localLink
                )
                retainedEvidenceRevision &+= 1
                noticeMessage =
                    "Signed change report retained and ready".localizedUI
            } catch is CancellationError {
                await discardChangeReport(at: url)
                return nil
            } catch {
                noticeMessage = AppLocalization.format(
                    "Signed report ready, but it was not retained. %@",
                    AppLocalization
                        .userFacingErrorDescription(error)
                )
            }
            return url
        } catch is CancellationError {
            await discardChangeReport(at: directory)
            return nil
        } catch {
            await discardChangeReport(at: directory)
            present(error)
            return nil
        }
    }

    func discardChangeReport(at url: URL) async {
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: ["PaperPath-ChangeReport-"]
            )
        }.value
    }

    func retainedChangeReports() async
        -> [PDFRetainedChangeReport] {
        do {
            return try await store.retainedChangeReports()
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
    }

    func retainedChangeReportInventory() async
        -> PDFRetainedChangeReportInventory {
        do {
            return try await store
                .retainedChangeReportInventory()
        } catch is CancellationError {
            return PDFRetainedChangeReportInventory(
                reports: [],
                linkHealthByReportID: [:]
            )
        } catch {
            present(error)
            return PDFRetainedChangeReportInventory(
                reports: [],
                linkHealthByReportID: [:]
            )
        }
    }

    func retainedChangeReports(
        matching lookup: PDFRetainedChangeReportLookup
    ) async -> [PDFRetainedChangeReport] {
        do {
            return try await loadLinkedChangeReports(matching: lookup)
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
    }

    func loadLinkedChangeReports(
        matching lookup: PDFRetainedChangeReportLookup
    ) async throws -> [PDFRetainedChangeReport] {
        try Task.checkCancellation()
        let reports = try await store.retainedChangeReports()
        try Task.checkCancellation()
        return reports.filter { lookup.matches($0.localLink) }
    }

    func retainedChangeReportDestination(
        for report: PDFRetainedChangeReport
    ) async -> PDFRetainedChangeReportDestination? {
        do {
            try Task.checkCancellation()
            guard let link = report.localLink,
                  link.isStructurallyValid
            else {
                return unavailableRetainedChangeReportDestination()
            }
            let verification = try await store
                .verifyRetainedChangeReport(id: report.id)
            try Task.checkCancellation()
            guard verification.reportID == report.id,
                  link.matches(verification)
            else {
                return unavailableRetainedChangeReportDestination()
            }

            switch link.context {
            case .documentPair:
                guard let sourceRecordID = link.sourceDocumentID,
                      let sourceRevisionID = link.sourceRevisionID,
                      let sourceFingerprint = link.sourceFingerprint,
                      let revisedRevisionID = link.revisedRevisionID,
                      let revisedFingerprint = link.revisedFingerprint,
                      let source = record(id: sourceRecordID),
                      source.deletedAt == nil,
                      source.contentRevisionID == sourceRevisionID,
                      source.contentFingerprint?
                        .caseInsensitiveCompare(sourceFingerprint)
                            == .orderedSame,
                      let revised = record(
                          id: link.revisedDocumentID
                      ),
                      revised.deletedAt == nil,
                      revised.contentRevisionID == revisedRevisionID,
                      revised.contentFingerprint?
                        .caseInsensitiveCompare(revisedFingerprint)
                            == .orderedSame,
                      try await store.currentDocumentMatches(
                          recordID: sourceRecordID,
                          revisionID: sourceRevisionID,
                          sha256: sourceFingerprint
                      ),
                      try await store.currentDocumentMatches(
                          recordID: link.revisedDocumentID,
                          revisionID: revisedRevisionID,
                          sha256: revisedFingerprint
                      )
                else {
                    return unavailableRetainedChangeReportDestination()
                }
                return .documentPair(
                    sourceRecordID: sourceRecordID,
                    sourceRevisionID: sourceRevisionID,
                    revisedRecordID: link.revisedDocumentID,
                    revisedRevisionID: revisedRevisionID
                )

            case .versionSnapshot:
                guard let recordID = link.sourceDocumentID,
                      recordID == link.revisedDocumentID,
                      let snapshotID = link.versionSnapshotID,
                      let sourceRevisionID = link.sourceRevisionID,
                      let sourceFingerprint = link.sourceFingerprint,
                      let revisedRevisionID = link.revisedRevisionID,
                      let revisedFingerprint = link.revisedFingerprint,
                      let current = record(id: recordID),
                      current.deletedAt == nil,
                      current.contentRevisionID == revisedRevisionID,
                      current.contentFingerprint?
                        .caseInsensitiveCompare(revisedFingerprint)
                            == .orderedSame,
                      try await store.currentDocumentMatches(
                          recordID: recordID,
                          revisionID: revisedRevisionID,
                          sha256: revisedFingerprint
                      ),
                      let snapshot = try await store.versions(
                          for: recordID
                      ).first(
                          where: {
                              $0.id == snapshotID
                                  && $0.contentRevisionID
                                      == sourceRevisionID
                                  && $0.contentFingerprint
                                      .caseInsensitiveCompare(
                                          sourceFingerprint
                                      ) == .orderedSame
                          }
                      )
                else {
                    return unavailableRetainedChangeReportDestination()
                }
                _ = try await store.versionFileURL(
                    snapshotID: snapshot.id,
                    recordID: recordID
                )
                try Task.checkCancellation()
                return .versionSnapshot(snapshot)

            case .deliveryReceipt:
                guard let receiptID = link.deliveryReceiptID,
                      let revisedFingerprint = link.revisedFingerprint,
                      let output = record(
                          id: link.revisedDocumentID
                      ),
                      output.deletedAt == nil,
                      let receipt = output.deliveryReceipt,
                      receipt.id == receiptID,
                      output.hasCurrentDeliveryReceipt,
                      output.contentFingerprint?
                        .caseInsensitiveCompare(revisedFingerprint)
                            == .orderedSame
                else {
                    return unavailableRetainedChangeReportDestination()
                }
                let currentRevisionID = output.contentRevisionID
                if let revisedRevisionID = link.revisedRevisionID,
                   revisedRevisionID != currentRevisionID {
                    return unavailableRetainedChangeReportDestination()
                }
                guard try await store.currentDocumentMatches(
                    recordID: output.id,
                    revisionID: currentRevisionID,
                    sha256: revisedFingerprint
                ) else {
                    return unavailableRetainedChangeReportDestination()
                }
                return .deliveryReceipt(
                    recordID: output.id,
                    receipt: receipt
                )
            }
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    private func unavailableRetainedChangeReportDestination()
        -> PDFRetainedChangeReportDestination? {
        noticeMessage =
            "The linked local evidence is unavailable or has changed."
                .localizedUI
        return nil
    }

    func verifyRetainedChangeReport(
        id: UUID
    ) async -> PDFChangeReportVerificationResult? {
        do {
            return try await checkRetainedChangeReport(id: id)
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func checkRetainedChangeReport(
        id: UUID
    ) async throws -> PDFChangeReportVerificationResult {
        try Task.checkCancellation()
        let result = try await store.verifyRetainedChangeReport(id: id)
        try Task.checkCancellation()
        return result
    }

    func prepareRetainedChangeReportShareCopy(
        _ report: PDFRetainedChangeReport
    ) async -> URL? {
        let fileName =
            "\(safeExportName(report.revisedName))-changes.md"
        do {
            let url = try await store
                .prepareRetainedChangeReportShareCopy(
                    id: report.id,
                    fileName: fileName
                )
            noticeMessage =
                "Signed change report reverified for sharing".localizedUI
            return url
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    @discardableResult
    func removeRetainedChangeReport(
        id: UUID
    ) async -> Bool {
        do {
            let removed = try await store.removeRetainedChangeReport(
                id: id
            )
            if removed {
                retainedEvidenceRevision &+= 1
                noticeMessage =
                    "Signed change report deleted from this device"
                        .localizedUI
            }
            return removed
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func verifyChangeReport(
        at url: URL
    ) async -> PDFChangeReportVerificationResult? {
        do {
            return try await store.verifyChangeReport(at: url)
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func trustChangeReportSigner(
        _ report: PDFChangeReportVerificationResult
    ) async -> PDFChangeReportVerificationResult? {
        do {
            let updated = try await store.trustChangeReportSigner(
                report
            )
            officeTrustedSigners = (
                try? await store.loadOfficeTrustedSigners()
            ) ?? officeTrustedSigners
            noticeMessage = "Signer trusted on this device".localizedUI
            return updated
        } catch {
            present(error)
            return nil
        }
    }

    func makeFilesExportCopy(
        recordID: UUID,
        presentsFeedback: Bool = true,
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void = { _ in }
    ) async -> URL? {
        guard let record = record(id: recordID),
              documentURLs[recordID] != nil,
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return nil }
        let requestedRevision = record.contentRevisionID
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }

        let displayName = record.displayName.lowercased()
            .hasSuffix(".pdf")
            ? String(record.displayName.dropLast(4))
            : record.displayName
        let fileName = "\(safeExportName(displayName)).pdf"

        do {
            let store = self.store
            let exportTask = Task {
                try await store.prepareFilesExportCopy(
                    recordID: recordID,
                    expectedRevisionID: requestedRevision,
                    fileName: fileName
                ) { update in
                    Task { @MainActor in
                        progress(update)
                    }
                }
            }
            let destination = try await valuePropagatingExclusiveCancellation(
                from: exportTask,
                recordID: recordID,
                operationToken: operationToken
            )
            guard self.record(id: recordID)?.contentRevisionID
                    == requestedRevision
            else {
                await discardFilesExportCopy(at: destination)
                throw PaperPathError.outputVerificationFailed(
                    "the working copy changed during Files export"
                )
            }
            return destination
        } catch is CancellationError {
            return nil
        } catch {
            if presentsFeedback {
                present(error)
            }
            return nil
        }
    }

    func makeDeliveryPackage(recordID: UUID) async -> URL? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID],
              record.hasCurrentDeliveryReceipt,
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else {
            if self.record(id: recordID)?
                .hasCurrentDeliveryReceipt != true {
                present(
                    PaperPathError.outputVerificationFailed(
                        "the delivery receipt no longer matches this PDF"
                    )
                )
            }
            return nil
        }

        let operationLabel = "Packaging verified PDF"
        operationProgress[recordID] = PDFOperationProgress(
            label: operationLabel,
            fractionCompleted: 0
        )
        operationRateWindows[recordID] = ByteRateWindow()
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            if operationProgress[recordID]?.label
                == operationLabel {
                operationProgress[recordID] = nil
                operationRateWindows[recordID] = nil
            }
        }

        let displayName = record.displayName.lowercased()
            .hasSuffix(".pdf")
            ? String(record.displayName.dropLast(4))
            : record.displayName
        let safeName = safeExportName(displayName)
        let artifactName = "\(safeName).pdf"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-DeliveryPackage-\(UUID().uuidString)",
                isDirectory: true
            )
        let manifestURL = directory.appendingPathComponent(
            "PaperPath-delivery-receipt.json"
        )
        let destination = directory.appendingPathComponent(
            "\(safeName)-verified.zip"
        )
        let verificationProgress: PDFByteProgressHandler = {
            [weak self] update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.exclusiveDocumentOperationIsCurrent(
                        recordID: recordID,
                        token: operationToken
                      ),
                      self.operationProgress[recordID]?.label
                        == operationLabel
                else { return }
                let fraction = update.totalBytes > 0
                    ? Double(update.processedBytes)
                        / Double(update.totalBytes)
                    : 0
                self.updateOperationFraction(
                    recordID: recordID,
                    label: operationLabel,
                    fractionCompleted: min(0.24, max(0, fraction) * 0.24)
                )
                self.publishOperationByteProgress(
                    recordID: recordID,
                    label: operationLabel,
                    update: update
                )
            }
        }
        let archiveProgress: PDFByteProgressHandler = {
            [weak self] update in
            Task { @MainActor [weak self] in
                guard let self,
                      self.exclusiveDocumentOperationIsCurrent(
                        recordID: recordID,
                        token: operationToken
                      ),
                      self.operationProgress[recordID]?.label
                        == operationLabel
                else { return }
                let fraction = update.totalBytes > 0
                    ? Double(update.processedBytes)
                        / Double(update.totalBytes)
                    : 0
                let completed: Double
                switch update.stage {
                case .checksumming:
                    completed = 0.24
                        + min(1, max(0, fraction)) * 0.28
                case .archiving:
                    completed = 0.52
                        + min(1, max(0, fraction)) * 0.46
                default:
                    completed = 0.24
                        + min(1, max(0, fraction)) * 0.74
                }
                self.updateOperationFraction(
                    recordID: recordID,
                    label: operationLabel,
                    fractionCompleted: completed
                )
                self.publishOperationByteProgress(
                    recordID: recordID,
                    label: operationLabel,
                    update: update
                )
            }
        }

        do {
            let store = self.store
            let manifestTask = Task {
                try await store.signedDeliveryPackageManifest(
                    for: record,
                    artifactFileName: artifactName,
                    progress: verificationProgress
                )
            }
            let signedManifest =
                try await valuePropagatingExclusiveCancellation(
                    from: manifestTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            officeDeliverySigningKeyID =
                signedManifest.signature.keyID
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID,
                  self.record(id: recordID)?
                    .hasCurrentDeliveryReceipt == true
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the PDF changed while its delivery package was being prepared"
                )
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(signedManifest)
            let sources = [
                OfficeBatchArchiveSource(
                    sourceURL: sourceURL,
                    archiveName: artifactName
                ),
                OfficeBatchArchiveSource(
                    sourceURL: manifestURL,
                    archiveName: manifestURL.lastPathComponent
                )
            ]
            let archiveTask = Task.detached(
                priority: .userInitiated
            ) {
                try LocalFileSecurity.prepareProtectedDirectory(
                    at: directory
                )
                do {
                    try manifestData.write(
                        to: manifestURL,
                        options: .atomic
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: manifestURL
                    )
                    try OfficeBatchArchiveService().createArchive(
                        sources: sources,
                        destination: destination,
                        progress: archiveProgress
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: destination
                    )
                    try? FileManager.default.removeItem(
                        at: manifestURL
                    )
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }
            try await valuePropagatingExclusiveCancellation(
                from: archiveTask,
                recordID: recordID,
                operationToken: operationToken
            )
            updateOperationFraction(
                recordID: recordID,
                label: operationLabel,
                fractionCompleted: 1
            )
            noticeMessage = "Verified delivery package ready".localizedUI
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: directory)
            present(error)
            return nil
        }
    }

    func discardFilesExportCopy(at url: URL) async {
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: ["PaperPath-FilesExport-"]
            )
        }.value
    }

    func discardDeliveryPackage(at url: URL) async {
        await Task.detached(priority: .utility) {
            _ = PaperPathTemporaryArtifact.removeManagedItem(
                containing: url,
                allowedPrefixes: ["PaperPath-DeliveryPackage-"]
            )
        }.value
    }

    private func discardInterruptedTemporaryFiles() async throws {
        let task = Task.detached(priority: .utility) {
            try PaperPathTemporaryArtifact
                .discardInterruptedItems()
        }
        do {
            _ = try await valuePropagatingCancellation(from: task)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Temporary cleanup must not block access to the library.
        }
    }

    func refreshToken(for recordID: UUID) -> Int {
        refreshTokens[recordID, default: 0]
    }

    func isProcessing(_ recordID: UUID) -> Bool {
        processingDocumentIDs.contains(recordID)
            || operationProgress[recordID] != nil
            || comparingDocumentIDs.contains(recordID)
    }

    func isComparing(_ recordID: UUID) -> Bool {
        comparingDocumentIDs.contains(recordID)
    }

    func stopComparisons(recordID: UUID) {
        let stopped = cancelActiveComparisonWork(
            referencing: Set([recordID])
        )
        guard !stopped.isEmpty else { return }
        noticeMessage = "Stopping PDF comparison".localizedUI
    }

    func isAnalyzing(_ recordID: UUID) -> Bool {
        analyzingDocumentIDs.contains(recordID)
    }

    var hasActiveLocalDataOperations: Bool {
        isImporting
            || isProcessingExternalPDFs
            || committedImportRestoreTask != nil
            || isSynchronizingMetadata
            || !processingDocumentIDs.isEmpty
            || !deliveryProcessingDocumentIDs.isEmpty
            || !batchDeliveryPendingDocumentIDs.isEmpty
            || !operationProgress.isEmpty
            || isBatesBatchMutationActive
            || isBatesReceiptVerificationActive
            || officeIntegrityProgress != nil
            || officeProductionTask != nil
            || !exclusiveDocumentOperations.isEmpty
            || !activeComparisonTasks.isEmpty
            || isClearingPageMatches
            || isUpdatingVersionStorage
            || isErasingAllLocalData
    }

    private func performTrackedComparison(
        recordIDs: Set<UUID>,
        operation: @escaping @MainActor @Sendable (
            UUID
        ) async throws -> PDFChangeReview
    ) async throws -> PDFChangeReview {
        let token = UUID()
        let task = Task { @MainActor in
            try await operation(token)
        }
        activeComparisonTasks[token] = ActivePDFComparison(
            recordIDs: recordIDs,
            task: task
        )
        rebuildComparingDocumentIDs()
        defer {
            activeComparisonTasks.removeValue(forKey: token)
            rebuildComparingDocumentIDs()
        }
        return try await withTaskCancellationHandler {
            let review = try await task.value
            try Task.checkCancellation()
            guard activeComparisonTasks[token] != nil else {
                throw CancellationError()
            }
            return review
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    private func cancelActiveComparisonWork()
        -> [Task<PDFChangeReview, Error>] {
        let tasks = activeComparisonTasks.values.map(\.task)
        activeComparisonTasks.removeAll(keepingCapacity: false)
        rebuildComparingDocumentIDs()
        for task in tasks {
            task.cancel()
        }
        return tasks
    }

    @discardableResult
    private func cancelActiveComparisonWork(
        referencing recordIDs: Set<UUID>
    ) -> [Task<PDFChangeReview, Error>] {
        guard !recordIDs.isEmpty else { return [] }
        let tokens = activeComparisonTasks.compactMap {
            token,
            comparison in
            comparison.recordIDs.isDisjoint(with: recordIDs)
                ? nil
                : token
        }
        let tasks = tokens.compactMap {
            activeComparisonTasks.removeValue(forKey: $0)?.task
        }
        rebuildComparingDocumentIDs()
        for task in tasks {
            task.cancel()
        }
        return tasks
    }

    private func rebuildComparingDocumentIDs() {
        comparingDocumentIDs = activeComparisonTasks.values.reduce(
            into: Set<UUID>()
        ) {
            $0.formUnion($1.recordIDs)
        }
    }

    private func acquireExclusiveDocumentOperation(
        recordID: UUID
    ) -> UUID? {
        do {
            return try beginExclusiveDocumentOperation(
                recordID: recordID
            )
        } catch {
            present(error)
            return nil
        }
    }

    private func acquireExclusiveDocumentOperations(
        recordIDs: [UUID]
    ) -> [UUID: UUID]? {
        var tokens: [UUID: UUID] = [:]
        do {
            for recordID in recordIDs {
                tokens[recordID] = try beginExclusiveDocumentOperation(
                    recordID: recordID
                )
            }
            return tokens
        } catch {
            finishExclusiveDocumentOperations(tokens)
            present(error)
            return nil
        }
    }

    private func beginExclusiveDocumentOperation(
        recordID: UUID
    ) throws -> UUID {
        guard !processingDocumentIDs.contains(recordID),
              exclusiveDocumentOperations[recordID] == nil,
              !comparingDocumentIDs.contains(recordID),
              !isUpdatingVersionStorage
        else {
            throw PaperPathError.insufficientSelection(
                "This PDF is busy. Wait for the current task to finish or stop it."
            )
        }
        let token = UUID()
        exclusiveDocumentOperations[recordID] = token
        processingDocumentIDs.insert(recordID)
        return token
    }

    private func markExclusiveDocumentOperationBackgroundCancellable(
        recordID: UUID,
        token: UUID
    ) throws {
        try ensureExclusiveDocumentOperationIsCurrent(
            recordID: recordID,
            token: token
        )
        backgroundCancellableDocumentOperations[recordID] = token
    }

    private func ensureExclusiveDocumentOperationIsCurrent(
        recordID: UUID,
        token: UUID
    ) throws {
        try Task.checkCancellation()
        guard exclusiveDocumentOperationIsCurrent(
            recordID: recordID,
            token: token
        ) else {
            throw CancellationError()
        }
    }

    private func exclusiveDocumentOperationIsCurrent(
        recordID: UUID,
        token: UUID
    ) -> Bool {
        !Task.isCancelled
            && exclusiveDocumentOperations[recordID] == token
            && !cancelledExclusiveDocumentOperationTokens.contains(token)
    }

    private func cancelBackgroundCancellableDocumentOperations() {
        let operations = backgroundCancellableDocumentOperations
        cancelledExclusiveDocumentOperationTokens.formUnion(
            operations.values
        )
        let cancellations = operations.compactMap {
            recordID,
            token -> (@Sendable () -> Void)? in
            guard let worker =
                    activeExclusiveDocumentWorkers[recordID],
                  worker.operationToken == token
            else { return nil }
            return worker.cancel
        }
        for cancel in cancellations {
            cancel()
        }
        // Keep each document locked until its worker has actually exited.
        // Atomic storage commits may finish after cancellation is requested.
    }

    private func finishExclusiveDocumentOperation(
        recordID: UUID,
        token: UUID
    ) {
        if activeExclusiveDocumentWorkers[recordID]?
            .operationToken == token {
            activeExclusiveDocumentWorkers[recordID]?.cancel()
            activeExclusiveDocumentWorkers[recordID] = nil
        }
        if backgroundCancellableDocumentOperations[recordID] == token {
            backgroundCancellableDocumentOperations[recordID] = nil
        }
        cancelledExclusiveDocumentOperationTokens.remove(token)
        guard exclusiveDocumentOperations[recordID] == token else {
            return
        }
        exclusiveDocumentOperations[recordID] = nil
        processingDocumentIDs.remove(recordID)
    }

    private func finishExclusiveDocumentOperations(
        _ tokens: [UUID: UUID]
    ) {
        for (recordID, token) in tokens {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: token
            )
        }
    }

    private func cleanupOfficeExportContainer(
        for artifactURL: URL
    ) {
        Task.detached(priority: .utility) {
            PaperPathTemporaryArtifact.removeManagedItem(
                containing: artifactURL,
                allowedPrefixes: ["PaperPath-Office-Export-"]
            )
        }
    }

    func progress(for recordID: UUID) -> PDFOperationProgress? {
        operationProgress[recordID]
    }

    private func updateOperationFraction(
        recordID: UUID,
        label: String,
        fractionCompleted: Double
    ) {
        guard let current = operationProgress[recordID],
              current.label == label
        else { return }
        let boundedFraction = fractionCompleted.isFinite
            ? min(1, max(0, fractionCompleted))
            : current.fractionCompleted
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: max(
                current.fractionCompleted,
                boundedFraction
            ),
            byteStage: current.byteStage,
            processedBytes: current.processedBytes,
            totalBytes: current.totalBytes,
            bytesPerSecond: current.bytesPerSecond,
            estimatedRemainingSeconds:
                current.estimatedRemainingSeconds,
            throughputHistory: current.throughputHistory,
            lastByteUpdateAt: current.lastByteUpdateAt
        )
    }

    private func publishOperationByteProgress(
        recordID: UUID,
        label: String,
        update: PDFByteProgressUpdate
    ) {
        guard let current = operationProgress[recordID],
              current.label == label
        else { return }
        let totalBytes = max(0, update.totalBytes)
        let processedBytes = totalBytes > 0
            ? min(max(0, update.processedBytes), totalBytes)
            : max(0, update.processedBytes)
        if current.byteStage == update.stage,
           processedBytes < current.processedBytes {
            return
        }
        var window = operationRateWindows[recordID]
            ?? ByteRateWindow()
        let didAdvance =
            current.byteStage != update.stage
            || processedBytes > current.processedBytes
        let rate = window.update(
            stage: update.stage,
            processedBytes: processedBytes
        )
        operationRateWindows[recordID] = window
        let remaining = rate > 0 && totalBytes > 0
            ? Double(totalBytes - processedBytes) / rate
            : nil
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: current.fractionCompleted,
            byteStage: update.stage,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: rate,
            estimatedRemainingSeconds: remaining,
            throughputHistory: window.history,
            lastByteUpdateAt: didAdvance
                ? Date()
                : current.lastByteUpdateAt
        )
    }

    var libraryCommandSummary: LibraryCommandSummary {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        if libraryCommandSummaryCacheDay != startOfToday {
            rebuildLibraryCommandSummary(referenceDate: startOfToday)
        }
        return libraryCommandSummaryCache
    }

    private func rebuildLibraryCommandSummary(
        referenceDate: Date = Date()
    ) {
        let workingDocuments = self.workingDocuments
        let recognizedTextAvailability = Dictionary(
            workingDocuments.map { record in
                (record.id, hasUsefulRecognizedText(recordID: record.id))
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let total = workingDocuments.count
        let endOfToday = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: referenceDate)
        ) ?? referenceDate
        var scoreTotal = 0
        let attention = attentionCountCache
        var verified = 0
        var stale = 0
        var officeReview = 0
        var locked = 0
        var scansNeedingOCR = 0
        var dueNow = 0
        var batchEligible = 0
        var ready = 0

        for record in workingDocuments {
            let hasRecognizedText =
                recognizedTextAvailability[record.id] ?? false
            let profile = commandProfile(
                for: record,
                hasRecognizedText: hasRecognizedText
            )
            scoreTotal += profile.score
            if profile.readiness == .ready {
                ready += 1
            }
            if verifiedShareTarget(for: record.id) != nil {
                verified += 1
            }
            if record.deliveryReceipt != nil,
               !record.hasCurrentDeliveryReceipt {
                stale += 1
            }
            if PDFOfficeExportPortfolio(profile: record.profile)
                .routeConfidence != .high {
                officeReview += 1
            }
            if record.profile.isLocked {
                locked += 1
            } else {
                batchEligible += 1
                if (
                    record.profile.kind == .scan
                        || record.profile.kind == .mixed
                ) && !hasRecognizedText {
                    scansNeedingOCR += 1
                }
            }
            if let dueAt = record.dueAt,
               dueAt < endOfToday,
               record.workflowStatus != .ready,
               record.workflowStatus != .archived {
                dueNow += 1
            }
        }

        let score = total == 0
            ? 100
            : scoreTotal / total
        let readiness: DocumentCommandReadiness
        if total == 0 {
            readiness = .ready
        } else if score < 50 || locked == total {
            readiness = .blocked
        } else if attention > 0
                    || stale > 0
                    || dueNow > 0 {
            readiness = .review
        } else {
            readiness = .ready
        }
        let summary = LibraryCommandSummary(
            readiness: readiness,
            score: score,
            totalCount: total,
            readyCount: ready,
            attentionCount: attention,
            verifiedCount: verified,
            staleReceiptCount: stale,
            officeReviewCount: officeReview,
            lockedCount: locked,
            scansNeedingOCRCount: scansNeedingOCR,
            dueNowCount: dueNow,
            batchEligibleCount: batchEligible
        )
        libraryCommandSummaryCache = summary
        libraryCommandSummaryCacheDay =
            Calendar.current.startOfDay(for: referenceDate)
    }

    func commandProfile(
        for record: DocumentRecord
    ) -> DocumentCommandProfile {
        commandProfile(
            for: record,
            hasRecognizedText: hasUsefulRecognizedText(recordID: record.id)
        )
    }

    private func commandProfile(
        for record: DocumentRecord,
        hasRecognizedText: Bool
    ) -> DocumentCommandProfile {
        let taskRecommendation = taskPackageRecommendation(
            for: record,
            hasRecognizedText: hasRecognizedText
        )
        let actionRecommendation = recommendation(
            for: record,
            hasRecognizedText: hasRecognizedText
        )
        let office = PDFOfficeExportPortfolio(profile: record.profile)
        let officePlan = office.recommendedPlan
        let verifiedTarget = verifiedShareTarget(for: record.id)
        let hasVerifiedTarget = verifiedTarget != nil
        let receiptExpired = record.deliveryReceipt != nil
            && !record.hasCurrentDeliveryReceipt
        let needsReview = needsAttention(record)
        let dueTodayOrOverdue: Bool = {
            guard let dueAt = record.dueAt else { return false }
            let endOfToday = Calendar.current.date(
                byAdding: .day,
                value: 1,
                to: Calendar.current.startOfDay(for: Date())
            ) ?? Date()
            return dueAt < endOfToday
        }()

        var score = 100
        if record.profile.isLocked { score -= 40 }
        if receiptExpired { score -= 30 }
        if needsReview { score -= 18 }
        if dueTodayOrOverdue { score -= 8 }
        switch office.routeConfidence {
        case .high:
            break
        case .guarded:
            score -= 10
        case .weak:
            score -= 22
        }
        if hasVerifiedTarget { score += 5 }
        score = min(100, max(0, score))

        let readiness: DocumentCommandReadiness
        if record.profile.isLocked || score < 50 {
            readiness = .blocked
        } else if score < 80
                    || receiptExpired
                    || needsReview
                    || dueTodayOrOverdue
                    || office.routeConfidence != .high {
            readiness = .review
        } else {
            readiness = .ready
        }

        let primaryTitle: String
        let primaryDetail: String
        let primarySymbol: String
        if receiptExpired {
            primaryTitle = "Verify again"
            primaryDetail =
                "This output changed after its receipt was issued."
            primarySymbol = "arrow.triangle.2.circlepath"
        } else if let taskRecommendation {
            primaryTitle = taskRecommendation.title
            primaryDetail = taskRecommendation.reason
            primarySymbol = taskRecommendation.task.symbol
        } else {
            primaryTitle = actionRecommendation.action.title
            primaryDetail = actionRecommendation.reason
            primarySymbol = actionRecommendation.action.symbol
        }

        let deliverySignal: DocumentCommandSignal
        if hasVerifiedTarget {
            deliverySignal = DocumentCommandSignal(
                id: "delivery",
                title: "Delivery",
                value: "Verified",
                detail: "A current checked output is ready to share.",
                symbol: "checkmark.seal.fill",
                readiness: .ready
            )
        } else if receiptExpired {
            deliverySignal = DocumentCommandSignal(
                id: "delivery",
                title: "Delivery",
                value: "Expired",
                detail: "Re-run Verified Output before sending.",
                symbol: "exclamationmark.triangle.fill",
                readiness: .review
            )
        } else {
            deliverySignal = DocumentCommandSignal(
                id: "delivery",
                title: "Delivery",
                value: "Needed",
                detail: "Create a reopened, checked copy before sharing.",
                symbol: "checkmark.shield",
                readiness: .review
            )
        }

        let officeReadiness = commandReadiness(
            for: office.routeConfidence
        )
        let officeSignal = DocumentCommandSignal(
            id: "office",
            title: "Office",
            value: officePlan.map {
                "\($0.format.fileExtension.uppercased()) \($0.compositeScore)"
            } ?? "Route",
            detail: office.decisionDeckLine,
            symbol: office.routeConfidence.symbol,
            readiness: officeReadiness
        )
        let textState = DocumentTextAvailability(
            isLocked: record.profile.isLocked,
            hasRecognizedText: hasRecognizedText,
            textCoverage: record.profile.textCoverage,
            imagePageCount: record.profile.imageDominantPageCount
        )
        let structureSignal = DocumentCommandSignal(
            id: "text",
            title: "Text",
            value: textState.title,
            detail: textState.detail,
            symbol: "text.magnifyingglass",
            readiness: record.profile.isLocked ? .blocked
                : textState.needsRecognition ? .review : .ready
        )
        let privacySignal = DocumentCommandSignal(
            id: "privacy",
            title: "Privacy",
            value: record.profile.isLocked ? "Protected" : "Local",
            detail: record.profile.isLocked
                ? "Unlock in session or create a separate editable copy."
                : "The private working copy stays on this device.",
            symbol: record.profile.isLocked ? "lock.doc" : "iphone",
            readiness: record.profile.isLocked ? .blocked : .ready
        )

        let profile = DocumentCommandProfile(
            readiness: readiness,
            score: score,
            primaryTitle: primaryTitle,
            primaryDetail: primaryDetail,
            primarySymbol: primarySymbol,
            officeRoute: officePlan.map {
                $0.format.fileExtension.uppercased()
            } ?? "Office",
            officeDetail: office.decisionDeckLine,
            signals: [
                deliverySignal,
                officeSignal,
                structureSignal,
                privacySignal
            ]
        )
        return profile
    }

    func actions(for record: DocumentRecord) -> [DocumentAction] {
        DocumentActionPlanner.actions(
            for: record,
            hasRecognizedText: hasUsefulRecognizedText(recordID: record.id),
            hasCurrentVerifiedOutput:
                verifiedShareTarget(for: record.id) != nil
        )
    }

    func recommendation(
        for record: DocumentRecord
    ) -> DocumentActionPlanner.Recommendation {
        recommendation(
            for: record,
            hasRecognizedText: hasUsefulRecognizedText(recordID: record.id)
        )
    }

    private func recommendation(
        for record: DocumentRecord,
        hasRecognizedText: Bool
    ) -> DocumentActionPlanner.Recommendation {
        DocumentActionPlanner.recommendation(
            for: record,
            hasRecognizedText: hasRecognizedText,
            hasCurrentVerifiedOutput:
                verifiedShareTarget(for: record.id) != nil
        )
    }

    func taskPackageRecommendation(
        for record: DocumentRecord
    ) -> PDFTaskPackagePlanner.Recommendation? {
        taskPackageRecommendation(
            for: record,
            hasRecognizedText: hasUsefulRecognizedText(recordID: record.id)
        )
    }

    private func taskPackageRecommendation(
        for record: DocumentRecord,
        hasRecognizedText: Bool
    ) -> PDFTaskPackagePlanner.Recommendation? {
        guard let recommendation = PDFTaskPackagePlanner.recommendation(
            for: record,
            hasRecognizedText: hasRecognizedText
        ) else { return nil }

        if recommendation.package == .prepareToSend,
           recommendation.task == .safeShare,
           verifiedShareTarget(for: record.id) != nil {
            return PDFTaskPackagePlanner.Recommendation(
                package: .prepareToSend,
                task: .safeShare,
                reason: "Verified copy ready"
            )
        }
        return recommendation
    }

    func task(
        for package: PDFTaskPackage,
        record: DocumentRecord
    ) -> PDFQuickTask {
        PDFTaskPackagePlanner.task(
            for: package,
            record: record
        )
    }

    private func hasUsefulRecognizedText(recordID: UUID) -> Bool {
        recordsWithRecognizedText.contains(recordID)
    }

    func matchingDocuments(
        query: String,
        status: DocumentWorkflowStatus?,
        category: DocumentCategory?
    ) -> [DocumentRecord] {
        let terms = DocumentSearchNormalization.terms(in: query)

        var matches: [DocumentRecord] = []
        matches.reserveCapacity(documents.count)
        for record in documents {
            guard status == nil || record.workflowStatus == status else {
                continue
            }
            guard category == nil || record.brief?.category == category else {
                continue
            }
            guard !terms.isEmpty else {
                matches.append(record)
                continue
            }
            if matchesSearchTerms(terms, in: record) {
                matches.append(record)
            }
        }
        return matches
    }

    func matchingPage(recordID: UUID, query: String) -> Int? {
        textIndices[recordID]?.firstMatchingPage(for: query)
    }

    func matchingText(
        recordID: UUID,
        query: String
    ) -> DocumentTextMatch? {
        textIndices[recordID]?.firstMatch(for: query)
    }

    func matchingPages(
        recordID: UUID,
        query: String,
        limit: Int = 200
    ) -> [DocumentTextMatch] {
        textIndices[recordID]?.matches(
            for: query,
            limit: limit
        ) ?? []
    }

    func needsAttention(_ record: DocumentRecord) -> Bool {
        guard record.isWorkingCopy,
              record.workflowStatus != .ready,
              record.workflowStatus != .archived
        else { return false }
        if record.profile.kind == .scan
            && !hasUsefulRecognizedText(recordID: record.id) {
            return true
        }
        return !(record.brief?.suggestedSteps.isEmpty ?? true)
    }

    func hasRecognizedText(recordID: UUID) -> Bool {
        hasUsefulRecognizedText(recordID: recordID)
    }

    var attentionCount: Int {
        attentionCountCache
    }

    private func commandReadiness(
        for confidence: PDFOfficeRouteConfidence
    ) -> DocumentCommandReadiness {
        switch confidence {
        case .high: return .ready
        case .guarded: return .review
        case .weak: return .blocked
        }
    }

    func present(_ error: Error) {
        present(
            error,
            targetSceneID: AppFeedbackContext.targetSceneID
        )
    }

    func present(_ error: Error, in sceneID: UUID?) {
        present(error, targetSceneID: sceneID)
    }

    private func present(
        _ error: Error,
        targetSceneID: UUID?
    ) {
        guard !(error is CancellationError) else { return }
        let targetSceneID = resolvedFeedbackTarget(targetSceneID)
        clearActionNotice(for: targetSceneID)
        if LocalFileSecurity.isInsufficientStorageError(error) {
            setPresentationError(
                PaperPathError.insufficientStorage.errorDescription,
                offersSettings: false,
                targetSceneID: targetSceneID
            )
            return
        }
        setPresentationError(
            AppLocalization.userFacingErrorDescription(error),
            offersSettings: false,
            targetSceneID: targetSceneID
        )
    }

    func presentCameraPermissionDenied() {
        presentCameraPermissionDenied(
            in: AppFeedbackContext.targetSceneID
        )
    }

    func presentCameraPermissionDenied(in sceneID: UUID?) {
        let sceneID = resolvedFeedbackTarget(sceneID)
        clearActionNotice(for: sceneID)
        setPresentationError(
            "Camera access is off. Import a PDF or enable Camera in Settings."
                .localizedUI,
            offersSettings: true,
            targetSceneID: sceneID
        )
    }

    @discardableResult
    private func performPageMutation(
        recordID: UUID,
        expectedContentRevisionID: UUID? = nil,
        label: String,
        invalidatesAnalysis: Bool = true,
        navigationTransform: ((Int) -> Int?)? = nil,
        clearingTaskCheckpointAt replacedPageIndex: Int? = nil,
        operation: @escaping @Sendable (
            PDFMutationService,
            URL
        ) throws -> Void
    ) async -> Bool {
        if let expectedContentRevisionID,
           record(id: recordID)?.contentRevisionID != expectedContentRevisionID {
            noticeMessage =
                "The PDF changed before this action started. Review the updated PDF.".localizedUI
            return false
        }
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID],
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return false }
        let navigationState: PageMutationNavigationState?
        if navigationTransform != nil || replacedPageIndex != nil {
            navigationState = pageMutationNavigationState(
                for: record,
                transform: navigationTransform,
                clearingTaskCheckpointAt: replacedPageIndex
            )
        } else {
            navigationState = nil
        }
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        let backupArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-PageUndo-"
        )
        let backupURL = backupArtifact.fileURL
        do {
            try await store.ensureTemporaryWorkingCapacity(
                for: [sourceURL],
                copyMultiplier: 6
            )
            let task = Task.detached(priority: .utility) {
                try backupArtifact.prepare()
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: backupURL
                )
                try LocalFileSecurity.requireCompleteProtection(
                    to: backupURL
                )
            }
            try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
        } catch is CancellationError {
            backupArtifact.remove()
            return false
        } catch {
            backupArtifact.remove()
            present(
                PaperPathError.storageFailure(
                    "A recovery snapshot could not be created."
                )
            )
            return false
        }
        let refreshed: DocumentRecord
        do {
            refreshed = try await commitPreparedMutation(
                record: record,
                sourceURL: sourceURL,
                invalidatesAnalysis: invalidatesAnalysis,
                snapshotLabel: label,
                operationToken: operationToken,
                navigationState: navigationState,
                operation: operation
            )
        } catch is CancellationError {
            backupArtifact.remove()
            noticeMessage = "Operation cancelled".localizedUI
            return false
        } catch {
            backupArtifact.remove()
            present(error)
            return false
        }
        if let previous = pageMutationUndos[recordID] {
            removePageMutationTemporaryItem(
                containing: previous.backupURL
            )
        }
        pageMutationUndos[recordID] = PageMutationUndo(
            backupURL: backupURL,
            expectedRevisionID: refreshed.contentRevisionID,
            bookmarkedPages: record.bookmarkedPages,
            bookmarkNames: record.bookmarkNames,
            lastPageIndex: record.lastPageIndex,
            taskCheckpoint: record.taskCheckpoint,
            label: label,
            sourceRevisionID: record.contentRevisionID
        )
        presentActionNotice(
            message: AppLocalization.format(
                "%@ complete",
                label.localizedUI
            ),
            detail: "One-step recovery is ready.",
            kind: .recovery,
            action: .undoPageChange(recordID: recordID)
        )
        return true
    }

    private func presentActionNotice(
        message: String,
        detail: String? = nil,
        kind: AppNoticeKind,
        action: AppNoticeAction
    ) {
        let targetSceneID = resolvedFeedbackTarget(
            AppFeedbackContext.targetSceneID
        )
        dismissTransientNotice(from: targetSceneID)
        let notice = AppActionNotice(
            message: message.localizedUI,
            detail: detail?.localizedUI,
            kind: kind,
            action: action,
            targetSceneID: targetSceneID
        )
        if let targetSceneID = notice.targetSceneID {
            actionNoticesBySceneID[targetSceneID] = notice
        } else {
            unscopedActionNotice = notice
        }
    }

    @discardableResult
    private func mutate(
        recordID: UUID,
        expectedContentRevisionID: UUID? = nil,
        invalidatesAnalysis: Bool = true,
        snapshotLabel: String = "Document edit".localizedUI,
        presentsFeedback: Bool = true,
        operation: @escaping @Sendable (PDFMutationService, URL) throws -> Void
    ) async -> Bool {
        guard let record = record(id: recordID),
              expectedContentRevisionID == nil
                || record.contentRevisionID
                    == expectedContentRevisionID,
              let sourceURL = documentURLs[recordID],
              let operationToken = acquireExclusiveDocumentOperation(
                recordID: recordID
              )
        else { return false }

        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        do {
            _ = try await commitPreparedMutation(
                record: record,
                sourceURL: sourceURL,
                invalidatesAnalysis: invalidatesAnalysis,
                snapshotLabel: snapshotLabel,
                operationToken: operationToken,
                operation: operation
            )
            noticeMessage = "Working copy updated".localizedUI
            return true
        } catch is CancellationError {
            if presentsFeedback {
                noticeMessage = "Operation cancelled".localizedUI
            }
            return false
        } catch {
            if presentsFeedback {
                present(error)
            }
            return false
        }
    }

    private func commitPreparedMutation(
        record: DocumentRecord,
        sourceURL: URL,
        invalidatesAnalysis: Bool,
        snapshotLabel: String,
        operationToken: UUID,
        navigationState: PageMutationNavigationState? = nil,
        operation: @escaping @Sendable (
            PDFMutationService,
            URL
        ) throws -> Void
    ) async throws -> DocumentRecord {
        try markExclusiveDocumentOperationBackgroundCancellable(
            recordID: record.id,
            token: operationToken
        )
        try await store.ensureTemporaryWorkingCapacity(
            for: [sourceURL],
            copyMultiplier: 5
        )
        try ensureExclusiveDocumentOperationIsCurrent(
            recordID: record.id,
            token: operationToken
        )
        let preparedArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-Mutation-"
        )
        let preparedURL = preparedArtifact.fileURL
        defer {
            preparedArtifact.remove()
        }

        let mutationService = self.mutationService
        let task = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try preparedArtifact.prepare()
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: preparedURL
                )
                try LocalFileSecurity.requireCompleteProtection(
                    to: preparedURL
                )
                try Task.checkCancellation()
                try operation(mutationService, preparedURL)
                try Task.checkCancellation()
            } catch {
                preparedArtifact.remove()
                throw error
            }
        }
        try await valuePropagatingExclusiveCancellation(
            from: task,
            recordID: record.id,
            operationToken: operationToken
        )
        let store = self.store
        let snapshotTask = Task {
            try await store.createVersionSnapshot(
                for: record,
                label: snapshotLabel
            )
        }
        _ = try await valuePropagatingExclusiveCancellation(
            from: snapshotTask,
            recordID: record.id,
            operationToken: operationToken
        )
        let commitTask = Task {
            try await store.replaceWorkingCopies(
                with: [
                    PreparedPDFWorkingCopy(
                        recordID: record.id,
                        sourceRevisionID: record.contentRevisionID,
                        preparedURL: preparedURL,
                        restoredBookmarkedPages:
                            navigationState?.bookmarkedPages,
                        restoredBookmarkNames:
                            navigationState?.bookmarkNames,
                        restoredLastPageIndex:
                            navigationState?.lastPageIndex,
                        restoredTaskCheckpoint:
                            navigationState?.taskCheckpoint,
                        restoresNavigationState:
                            navigationState != nil
                    )
                ],
                invalidateAnalysis: invalidatesAnalysis
            )
        }
        let committed =
            try await valueCompletingAtomicExclusiveCommit(
                from: commitTask,
                recordID: record.id,
                operationToken: operationToken
            )
        guard let refreshed = committed.first(
            where: { $0.id == record.id }
        ) else {
            throw PaperPathError.storageFailure(
                "The prepared document change did not commit."
            )
        }

        if invalidatesAnalysis {
            textIndices[record.id] = nil
            setOCRResult(nil, for: record.id)
        }
        replace(refreshed)
        refreshTokens[record.id, default: 0] += 1
        guard exclusiveDocumentOperationIsCurrent(
            recordID: record.id,
            token: operationToken
        ) else { return refreshed }
        if invalidatesAnalysis {
            await analyzeDocument(recordID: record.id)
        }
        guard exclusiveDocumentOperationIsCurrent(
            recordID: record.id,
            token: operationToken
        ) else { return refreshed }
        return refreshed
    }

    private func pageMutationNavigationState(
        for record: DocumentRecord,
        transform: ((Int) -> Int?)?,
        clearingTaskCheckpointAt replacedPageIndex: Int?
    ) -> PageMutationNavigationState {
        let mapPage: (Int) -> Int? = transform ?? { $0 }
        var mappedNames: [Int: String] = [:]
        let mappedBookmarks = record.bookmarkedPages.compactMap {
            page -> Int? in
            guard let mappedPage = mapPage(page) else { return nil }
            if let name = record.bookmarkNames[page],
               mappedNames[mappedPage] == nil {
                mappedNames[mappedPage] = name
            }
            return mappedPage
        }
        let mappedCheckpoint: DocumentTaskCheckpoint?
        if let replacedPageIndex,
           let checkpoint = record.taskCheckpoint,
           checkpoint.stage != .verify,
           checkpoint.pageIndex == replacedPageIndex {
            mappedCheckpoint = nil
        } else if let checkpoint = record.taskCheckpoint,
                  let pageIndex = checkpoint.pageIndex {
            if let mappedPage = mapPage(pageIndex) {
                mappedCheckpoint = DocumentTaskCheckpoint(
                    stage: checkpoint.stage,
                    pageIndex: mappedPage,
                    fieldName: checkpoint.fieldName,
                    normalizedBounds: checkpoint.normalizedBounds,
                    contentRevisionID: checkpoint.contentRevisionID
                )
            } else {
                mappedCheckpoint = nil
            }
        } else {
            mappedCheckpoint = record.taskCheckpoint
        }
        return PageMutationNavigationState(
            bookmarkedPages: Array(Set(mappedBookmarks)).sorted(),
            bookmarkNames: mappedNames,
            lastPageIndex:
                mapPage(record.lastPageIndex)
                    ?? record.lastPageIndex,
            taskCheckpoint: mappedCheckpoint
        )
    }

    private func createOutputCopy(
        recordID: UUID,
        expectedContentRevisionID: UUID,
        outputNameKey: String,
        notice: String,
        operationKind: PDFDeliveryOperation,
        unlockPassword: String? = nil,
        completesAction: DocumentAction? = nil,
        marksSourceReady: Bool = false,
        presentsFeedback: Bool = true,
        onFailure: ((PDFBatchDeliveryIssue) -> Void)? = nil,
        operation: @escaping @Sendable (
            URL,
            URL,
            @escaping PDFProgressHandler
        ) throws -> Void
    ) async -> DocumentRecord? {
        guard let record = record(id: recordID),
              record.contentRevisionID
                == expectedContentRevisionID,
              let sourceURL = documentURLs[recordID]
        else {
            let issue: PDFBatchDeliveryIssue =
                record(id: recordID) == nil
                    ? .sourceUnavailable()
                    : .sourceChanged
            onFailure?(issue)
            if presentsFeedback {
                present(issue)
            }
            return nil
        }
        let operationToken: UUID
        do {
            operationToken = try beginExclusiveDocumentOperation(
                recordID: recordID
            )
        } catch {
            let issue = PDFBatchDeliveryIssue.preflightFailed(
                AppLocalization.userFacingErrorDescription(error)
            )
            onFailure?(issue)
            if presentsFeedback {
                present(issue)
            }
            return nil
        }
        let operationLabel = AppLocalization.format(
            "Creating %@",
            operationKind.title.localizedUI
        )
        do {
            try markExclusiveDocumentOperationBackgroundCancellable(
                recordID: recordID,
                token: operationToken
            )
        } catch {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            onFailure?(.cancelled)
            return nil
        }
        deliveryProcessingDocumentIDs.insert(recordID)
        operationProgress[recordID] = PDFOperationProgress(
            label: operationLabel,
            fractionCompleted: 0
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            deliveryProcessingDocumentIDs.remove(recordID)
            operationProgress[recordID] = nil
        }
        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-DocumentExport-"
        )
        let destination = temporaryArtifact.fileURL
        defer { temporaryArtifact.remove() }
        let auditService = deliveryAuditService
        let deliveryTimeAnchor = await store.deliveryTimeAnchor()
        do {
            try ensureExclusiveDocumentOperationIsCurrent(
                recordID: recordID,
                token: operationToken
            )
        } catch {
            onFailure?(.cancelled)
            return nil
        }
        let reportProgress: PDFProgressHandler = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self,
                      self.exclusiveDocumentOperationIsCurrent(
                        recordID: recordID,
                        token: operationToken
                      )
                else { return }
                self.updateOperationFraction(
                    recordID: recordID,
                    label: operationLabel,
                    fractionCompleted: min(0.98, max(0, value))
                )
            }
        }
        let outputRevisionID = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try temporaryArtifact.prepare()
            do {
                try operation(sourceURL, destination) { value in
                    reportProgress(value * 0.78)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PaperPathError {
                if case .compressionNotBeneficial = error {
                    throw PDFBatchDeliveryIssue.compressionNotBeneficial(
                        AppLocalization.userFacingErrorDescription(error)
                    )
                }
                throw PDFBatchDeliveryIssue.renderingFailed(
                    AppLocalization.userFacingErrorDescription(error)
                )
            } catch {
                throw PDFBatchDeliveryIssue.renderingFailed(
                    AppLocalization.userFacingErrorDescription(error)
                )
            }
            reportProgress(0.82)
            let receipt: PDFDeliveryReceipt
            do {
                receipt = try auditService.audit(
                    sourceURL: sourceURL,
                    outputURL: destination,
                    operation: operationKind,
                    unlockPassword: unlockPassword,
                    timeAnchor: deliveryTimeAnchor
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PDFBatchDeliveryIssue.verificationFailed(
                    AppLocalization.userFacingErrorDescription(error)
                )
            }
            reportProgress(0.96)
            return receipt
        }
        do {
            var receipt = try await valuePropagatingExclusiveCancellation(
                from: task,
                recordID: recordID,
                operationToken: operationToken
            )
            guard self.record(id: recordID)?.contentRevisionID
                == record.contentRevisionID
            else {
                throw PDFBatchDeliveryIssue.verificationFailed(
                    "The source changed while the copy was being created."
                )
            }
            receipt.sourceRevisionID = record.contentRevisionID
            receipt.outputRevisionID = outputRevisionID
            let created: DocumentRecord
            do {
                let importTask = Task { @MainActor in
                    try await self.importSinglePDF(
                        from: destination,
                        preferredName: AppLocalization.format(
                            "%@ - %@",
                            record.displayName,
                            outputNameKey.localizedUI
                        ),
                        deliveryReceipt: receipt,
                        sourceDocumentID: recordID,
                        contentRevisionID: outputRevisionID,
                        analyzeAfterImport: false
                    )
                }
                created = try await valuePropagatingExclusiveCancellation(
                    from: importTask,
                    recordID: recordID,
                    operationToken: operationToken
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PDFBatchDeliveryIssue.savingFailed(
                    AppLocalization.userFacingErrorDescription(error)
                )
            }
            operationProgress[recordID] = PDFOperationProgress(
                label: operationLabel,
                fractionCompleted: 1
            )
            if let completesAction {
                await markSourceCompleted(
                    recordID: recordID,
                    action: completesAction,
                    marksReady: marksSourceReady
                )
                try ensureExclusiveDocumentOperationIsCurrent(
                    recordID: recordID,
                    token: operationToken
                )
            }
            if presentsFeedback {
                noticeMessage = notice
            }
            return created
        } catch is CancellationError {
            if let committed = documents.first(where: {
                $0.contentRevisionID == outputRevisionID
            }) {
                if presentsFeedback {
                    noticeMessage =
                        "Copy finished before stopping · copy kept in Library"
                            .localizedUI
                }
                return committed
            }
            onFailure?(.cancelled)
            if presentsFeedback {
                noticeMessage = "Operation cancelled".localizedUI
            }
            return nil
        } catch let issue as PDFBatchDeliveryIssue {
            onFailure?(issue)
            if presentsFeedback {
                present(issue)
            }
            return nil
        } catch {
            let issue = PDFBatchDeliveryIssue.renderingFailed(
                AppLocalization.userFacingErrorDescription(error)
            )
            onFailure?(issue)
            if presentsFeedback {
                present(issue)
            }
            return nil
        }
    }

    private func markSourceCompleted(
        recordID: UUID,
        action: DocumentAction,
        marksReady: Bool
    ) async {
        guard var updated = record(id: recordID) else { return }
        do {
            if !updated.completedActions.contains(action) {
                updated = try await store.setActionCompletion(
                    updated,
                    action: action,
                    completed: true
                )
                replace(updated)
            }
            if action == .safeShare,
               updated.taskCheckpoint != nil {
                updated = try await store.updateTaskCheckpoint(
                    updated,
                    checkpoint: nil
                )
                replace(updated, schedulesMetadataSync: false)
            }
            if marksReady, updated.workflowStatus != .ready {
                updated = try await store.updateWorkflow(
                    updated,
                    status: .ready
                )
                replace(updated)
            }
        } catch {
            present(error)
        }
    }

    private func removeRecordState(_ recordID: UUID) {
        removeRecordsState(Set([recordID]))
    }

    private func removeRecordsState(
        _ recordIDs: Set<UUID>
    ) {
        guard !recordIDs.isEmpty else { return }
        invalidateEvidenceCaches(
            referencing: recordIDs,
            cancelsActiveComparisons: true
        )
        documents.removeAll { recordIDs.contains($0.id) }
        documentURLs = documentURLs.filter {
            !recordIDs.contains($0.key)
        }
        refreshTokens = refreshTokens.filter {
            !recordIDs.contains($0.key)
        }
        ocrResults = ocrResults.filter {
            !recordIDs.contains($0.key)
        }
        recordsWithRecognizedText.subtract(recordIDs)
        rebuildAttentionCount()
        textIndices = textIndices.filter {
            !recordIDs.contains($0.key)
        }
        residentAnalysisOrder.removeAll {
            recordIDs.contains($0)
        }
        for recordID in recordIDs {
            let readingPositionOwners = readingPositionTasks
                .filter { $0.value.recordID == recordID }
                .map(\.key)
            for ownerID in readingPositionOwners {
                cancelReadingPositionUpdate(ownerID: ownerID)
            }
            cancelDocumentAnalysis(for: recordID)
            searchMetadataCorpora[recordID] = nil
            removeSearchTextCorpus(recordID: recordID)
            deliveryPreflightCache[recordID] = nil
            officeBatchRuns[recordID] = nil
            deliveryProcessingDocumentIDs.remove(recordID)
            batchDeliveryPendingDocumentIDs.remove(recordID)
            discardPageMutationUndo(recordID: recordID)
        }
        clearActionNotice(referencing: recordIDs)
    }

    @discardableResult
    private func replaceMetadataRecordIfCurrent(
        _ updated: DocumentRecord,
        schedulesMetadataSync: Bool = true
    ) -> Bool {
        guard let resident = record(id: updated.id),
              resident.contentRevisionID
                == updated.contentRevisionID,
              resident.modifiedAt <= updated.modifiedAt,
              (resident.lastViewedAt ?? .distantPast)
                <= (updated.lastViewedAt ?? .distantPast)
        else { return false }
        replace(
            updated,
            schedulesMetadataSync: schedulesMetadataSync,
            invalidatesSearchText: false
        )
        return true
    }

    @discardableResult
    private func replaceMetadataRecordsIfCurrent(
        _ updatedRecords: [DocumentRecord],
        schedulesMetadataSync: Bool = true
    ) -> Int {
        let currentRecords = updatedRecords.filter { updated in
            guard let resident = record(id: updated.id) else {
                return false
            }
            return resident.contentRevisionID
                    == updated.contentRevisionID
                && resident.modifiedAt <= updated.modifiedAt
                && (resident.lastViewedAt ?? .distantPast)
                    <= (updated.lastViewedAt ?? .distantPast)
        }
        replace(
            currentRecords,
            schedulesMetadataSync: schedulesMetadataSync,
            invalidatesSearchText: false
        )
        return currentRecords.count
    }

    private func replace(
        _ record: DocumentRecord,
        schedulesMetadataSync: Bool = true,
        invalidatesSearchText: Bool = true
    ) {
        replace(
            [record],
            schedulesMetadataSync: schedulesMetadataSync,
            invalidatesSearchText: invalidatesSearchText
        )
    }

    private func replace(
        _ records: [DocumentRecord],
        schedulesMetadataSync: Bool = true,
        invalidatesSearchText: Bool = true
    ) {
        guard !records.isEmpty else { return }
        var updatedDocuments = documents
        var changedRecordIDs = Set<UUID>()
        for record in records {
            if let index = updatedDocuments.firstIndex(
                where: { $0.id == record.id }
            ) {
                if updatedDocuments[index].contentRevisionID
                    != record.contentRevisionID {
                    deliveryPreflightCache[record.id] = nil
                    changedRecordIDs.insert(record.id)
                    discardPageMutationUndoIfStale(
                        recordID: record.id,
                        currentRevisionID: record.contentRevisionID
                    )
                }
                updatedDocuments[index] = record
            } else {
                updatedDocuments.append(record)
            }
        }
        invalidateEvidenceCaches(
            referencing: changedRecordIDs,
            cancelsActiveComparisons: true
        )
        updatedDocuments.sort(by: documentSortsBefore)
        documents = updatedDocuments
        if !changedRecordIDs.isEmpty {
            retainedEvidenceRevision &+= 1
        }
        for record in records {
            if let run = officeBatchRuns[record.id] {
                let reconciled = run.reconcilingArtifacts(
                    currentRevisionID: record.contentRevisionID,
                    availableReceiptIDs:
                        availableOfficeBatchReceiptIDs(
                            in: record,
                            for: run
                        )
                )
                if reconciled != run {
                    officeBatchRuns[record.id] = reconciled
                }
            }
            searchMetadataCorpora[record.id] =
                searchMetadataCorpus(for: record)
            if invalidatesSearchText {
                removeSearchTextCorpus(recordID: record.id)
            }
        }
        if schedulesMetadataSync {
            scheduleMetadataSync()
        }
    }

    private func discardPageMutationUndoIfStale(
        recordID: UUID,
        currentRevisionID: UUID
    ) {
        guard let undo = pageMutationUndos[recordID],
              undo.expectedRevisionID != currentRevisionID
        else { return }
        discardPageMutationUndo(recordID: recordID)
        clearActionNotice(referencing: Set([recordID]))
    }

    private func discardPageMutationUndo(recordID: UUID) {
        guard let undo = pageMutationUndos.removeValue(
            forKey: recordID
        ) else { return }
        removePageMutationTemporaryItem(
            containing: undo.backupURL
        )
    }

    private func clearActionNotice(
        referencing recordIDs: Set<UUID>
    ) {
        actionNoticesBySceneID = actionNoticesBySceneID.filter {
            actionNoticeRecordIDs($0.value)
                .isDisjoint(with: recordIDs)
        }
        if let notice = unscopedActionNotice,
           !actionNoticeRecordIDs(notice)
                .isDisjoint(with: recordIDs) {
            unscopedActionNotice = nil
        }
    }

    private func clearActionNotice(for sceneID: UUID?) {
        if let sceneID {
            actionNoticesBySceneID[sceneID] = nil
        } else {
            unscopedActionNotice = nil
        }
    }

    private var preferredActiveFeedbackSceneID: UUID? {
        activeFeedbackSceneIDs.max {
            feedbackSceneRecency[$0, default: 0]
                < feedbackSceneRecency[$1, default: 0]
        }
    }

    private func resolvedFeedbackTarget(
        _ explicitSceneID: UUID?
    ) -> UUID? {
        explicitSceneID ?? preferredActiveFeedbackSceneID
    }

    private func unscopedTransientNoticeForScene(
        _ sceneID: UUID
    ) -> AppTransientNotice? {
        guard preferredActiveFeedbackSceneID == sceneID
        else { return nil }
        return unscopedTransientNotice
    }

    private func unscopedActionNoticeForScene(
        _ sceneID: UUID
    ) -> AppActionNotice? {
        guard preferredActiveFeedbackSceneID == sceneID
        else { return nil }
        return unscopedActionNotice
    }

    private func adoptUnscopedFeedback(into sceneID: UUID) {
        if transientNoticesBySceneID[sceneID] == nil,
           let notice = unscopedTransientNotice {
            transientNoticesBySceneID[sceneID] =
                notice.targetingScene(sceneID)
            unscopedTransientNotice = nil
        }
        if actionNoticesBySceneID[sceneID] == nil,
           let notice = unscopedActionNotice {
            actionNoticesBySceneID[sceneID] =
                notice.targetingScene(sceneID)
            unscopedActionNotice = nil
        }
        if presentationErrorsBySceneID[sceneID] == nil,
           let error = unscopedPresentationError {
            presentationErrorsBySceneID[sceneID] =
                error.targetingScene(sceneID)
            unscopedPresentationError = nil
        }
        if fullUnlockContextsBySceneID[sceneID] == nil,
           let context = unscopedFullUnlockContext {
            fullUnlockContextsBySceneID[sceneID] = context
            unscopedFullUnlockContext = nil
        }
        if hasUnscopedSettingsPresentationRequest {
            settingsPresentationSceneIDs.insert(sceneID)
            hasUnscopedSettingsPresentationRequest = false
        }
    }

    private func requestSettingsPresentation(in sceneID: UUID?) {
        if let sceneID = resolvedFeedbackTarget(sceneID) {
            settingsPresentationSceneIDs.insert(sceneID)
        } else {
            hasUnscopedSettingsPresentationRequest = true
        }
    }

    private func setTransientNotice(
        _ message: String?,
        targetSceneID: UUID?
    ) {
        let targetSceneID = message == nil
            ? targetSceneID
            : resolvedFeedbackTarget(targetSceneID)
        if let targetSceneID {
            transientNoticesBySceneID[targetSceneID] = message.map {
                AppTransientNotice(
                    message: $0,
                    targetSceneID: targetSceneID
                )
            }
        } else {
            unscopedTransientNotice = message.map {
                AppTransientNotice(message: $0)
            }
        }
    }

    private func setPresentationError(
        _ message: String?,
        offersSettings: Bool,
        targetSceneID: UUID?
    ) {
        let targetSceneID = message == nil
            ? targetSceneID
            : resolvedFeedbackTarget(targetSceneID)
        if let targetSceneID {
            presentationErrorsBySceneID[targetSceneID] = message.map {
                AppPresentationError(
                    message: $0,
                    offersSettings: offersSettings,
                    targetSceneID: targetSceneID
                )
            }
        } else {
            unscopedPresentationError = message.map {
                AppPresentationError(
                    message: $0,
                    offersSettings: offersSettings
                )
            }
        }
    }

    private func actionNoticeRecordIDs(
        _ notice: AppActionNotice
    ) -> Set<UUID> {
        switch notice.action {
        case .restoreTrash(let ids):
            return Set(ids)
        case .undoPageChange(let id):
            return Set([id])
        case .undoPageChanges(let ids):
            return Set(ids)
        }
    }

    private func invalidateEvidenceCaches(
        referencing recordIDs: Set<UUID>,
        cancelsActiveComparisons: Bool
    ) {
        guard !recordIDs.isEmpty else { return }
        if cancelsActiveComparisons {
            cancelActiveComparisonWork(referencing: recordIDs)
        }

        let comparisonKeys = comparisonCache.keys.filter {
            recordIDs.contains($0.sourceRecordID)
                || recordIDs.contains($0.revisedRecordID)
        }
        for key in comparisonKeys {
            comparisonCache[key] = nil
        }
        let comparisonKeySet = Set(comparisonKeys)
        comparisonCacheOrder.removeAll {
            comparisonKeySet.contains($0)
        }

        invalidateVersionComparisonCaches(for: recordIDs)

        let assessmentKeys = pageAssessmentCache.keys.filter {
            recordIDs.contains($0.recordID)
        }
        for key in assessmentKeys {
            pageAssessmentCache[key] = nil
        }
        let assessmentKeySet = Set(assessmentKeys)
        pageAssessmentCacheOrder.removeAll {
            assessmentKeySet.contains($0)
        }
    }

    private func invalidateVersionComparisonCaches(
        for recordIDs: Set<UUID>
    ) {
        guard !recordIDs.isEmpty else { return }
        let versionKeys = versionComparisonCache.keys.filter {
            recordIDs.contains($0.recordID)
        }
        for key in versionKeys {
            versionComparisonCache[key] = nil
        }
        let versionKeySet = Set(versionKeys)
        versionComparisonCacheOrder.removeAll {
            versionKeySet.contains($0)
        }
    }

    private var isRunningAutomatedTests: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("UITEST_")
        }
            || ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] != nil
#else
        false
#endif
    }

    private var metadataSyncDisabledStatus: PDFMetadataSyncStatus {
        PDFMetadataSyncStatus(
            state: .idle,
            documentCount: 0,
            updatedAt: nil,
            detail: "Off. PDF files and lightweight metadata stay on this device."
        )
    }

    private func scheduleMetadataSync(
        delay: Duration = .seconds(1)
    ) {
        guard didBootstrap,
              !isRunningAutomatedTests,
              UserDefaults.standard.bool(
                forKey: AppPreferences.metadataSyncEnabledKey
              ),
              !metadataSyncAutomaticRetryBlocked
        else { return }
        if isSynchronizingMetadata {
            requestMetadataSyncFollowUp(showNotice: false)
            return
        }
        let scheduleGeneration = UUID()
        metadataSyncScheduleGeneration = scheduleGeneration
        metadataSyncTask?.cancel()
        metadataSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.metadataSyncScheduleGeneration
                    == scheduleGeneration
            else { return }
            self.metadataSyncTask = nil
            await self.synchronizeMetadata(showNotice: false)
        }
    }

    private func startMetadataSyncObservation() {
        guard UserDefaults.standard.bool(
            forKey: AppPreferences.metadataSyncEnabledKey
        ),
        metadataSyncObserver == nil
        else { return }
        metadataSyncObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore
                .didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            let reason = (
                notification.userInfo?[
                    NSUbiquitousKeyValueStoreChangeReasonKey
                ] as? NSNumber
            )?.intValue
            let changedKeys = notification.userInfo?[
                NSUbiquitousKeyValueStoreChangedKeysKey
            ] as? [String]
            Task { @MainActor [weak self] in
                self?.handleMetadataSyncExternalChange(
                    reason: reason,
                    changedKeys: changedKeys
                )
            }
        }
    }

    private func handleMetadataSyncExternalChange(
        reason: Int?,
        changedKeys: [String]?
    ) {
        guard UserDefaults.standard.bool(
            forKey: AppPreferences.metadataSyncEnabledKey
        ) else { return }
        let changesMetadataPayload =
            changedKeys?.contains(
                PDFMetadataSyncService.cloudStorageKey
            ) ?? true

        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            invalidateMetadataSyncWork()
            metadataSyncAutomaticRetryBlocked = true
            metadataSyncStatus = PDFMetadataSyncStatus(
                state: .failed,
                documentCount: metadataSyncStatus.documentCount,
                updatedAt: metadataSyncStatus.updatedAt,
                detail:
                    "iCloud metadata quota was exceeded. PDFs and local metadata remain on this device."
            )
        case NSUbiquitousKeyValueStoreAccountChange:
            invalidateMetadataSyncWork()
            metadataSyncAutomaticRetryBlocked = false
            metadataSyncStatus = PDFMetadataSyncStatus(
                state: .idle,
                documentCount: 0,
                updatedAt: nil,
                detail:
                    "The iCloud account changed. PaperPath will rebuild lightweight metadata sync."
            )
            scheduleMetadataSync(delay: .milliseconds(350))
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            guard changesMetadataPayload else { return }
            guard !isApplyingMetadataSync else { return }
            scheduleMetadataSync(delay: .milliseconds(180))
        default:
            guard changesMetadataPayload else { return }
            guard !isApplyingMetadataSync else { return }
            scheduleMetadataSync(delay: .milliseconds(350))
        }
    }

    private func invalidateMetadataSyncWork() {
        metadataSyncGeneration = UUID()
        metadataSyncScheduleGeneration = UUID()
        isSynchronizingMetadata = false
        metadataSyncNeedsFollowUp = false
        metadataSyncFollowUpShowsNotice = false
        metadataSyncTask?.cancel()
        metadataSyncTask = nil
    }

    private func requestMetadataSyncFollowUp(
        showNotice: Bool
    ) {
        metadataSyncNeedsFollowUp = true
        metadataSyncFollowUpShowsNotice =
            metadataSyncFollowUpShowsNotice || showNotice
        metadataSyncStatus = PDFMetadataSyncStatus(
            state: .syncing,
            documentCount: metadataSyncStatus.documentCount,
            updatedAt: metadataSyncStatus.updatedAt,
            detail:
                "Finishing the current merge, then checking the latest iCloud metadata."
        )
    }

    private func pauseMetadataSyncForBackground() {
        let hadActiveWork =
            isSynchronizingMetadata || metadataSyncTask != nil
        invalidateMetadataSyncWork()
        guard hadActiveWork,
              UserDefaults.standard.bool(
                  forKey: AppPreferences.metadataSyncEnabledKey
              )
        else { return }
        metadataSyncStatus = PDFMetadataSyncStatus(
            state: .idle,
            documentCount: metadataSyncStatus.documentCount,
            updatedAt: metadataSyncStatus.updatedAt,
            detail:
                "Metadata sync paused while PaperPath is in the background."
        )
    }

    private func documentSortsBefore(
        _ lhs: DocumentRecord,
        _ rhs: DocumentRecord
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        let nameOrder = lhs.displayName.localizedStandardCompare(
            rhs.displayName
        )
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func rebuildDocumentDerivedIndexes() {
        let recordsByID = Dictionary(
            documents.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let working = documents.filter(\.isWorkingCopy)
        let outputs = documents
            .filter(\.isDeliveryArtifact)
            .sorted {
                let lhsDate =
                    $0.deliveryReceipt?.createdAt ?? $0.modifiedAt
                let rhsDate =
                    $1.deliveryReceipt?.createdAt ?? $1.modifiedAt
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        let pinnedOfficeOutputs = documents.flatMap { record in
            record.officeReceipts
                .filter(\.isPinned)
                .map {
                    PDFPinnedOfficeOutput(
                        recordID: record.id,
                        documentName: record.displayName,
                        receipt: $0
                    )
                }
        }
        .sorted {
            let lhsDate = $0.receipt.pinnedAt ?? .distantPast
            let rhsDate = $1.receipt.pinnedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.receipt.id.uuidString
                < $1.receipt.id.uuidString
        }
        var fingerprintCounts: [String: Int] = [:]
        for record in working {
            guard let fingerprint = record.contentFingerprint else {
                continue
            }
            fingerprintCounts[fingerprint, default: 0] += 1
        }

        var outputsBySourceID: [UUID: [DocumentRecord]] = [:]
        var historyBySourceID: [UUID: [DocumentRecord]] = [:]
        let chronologicalOutputs = outputs.sorted {
            let lhsDate = $0.deliveryReceipt?.createdAt ?? $0.importedAt
            let rhsDate = $1.deliveryReceipt?.createdAt ?? $1.importedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        for output in chronologicalOutputs {
            var child = output
            var visited = Set<UUID>([output.id])
            var matchesCurrentChain = output.hasCurrentDeliveryReceipt
            while let parentID = child.sourceDocumentID,
                  visited.insert(parentID).inserted,
                  let parent = recordsByID[parentID] {
                historyBySourceID[parentID, default: []].append(output)
                matchesCurrentChain = matchesCurrentChain
                    && child.deliveryReceipt?.sourceRevisionID == parent.contentRevisionID
                if matchesCurrentChain {
                    outputsBySourceID[parentID, default: []].append(output)
                }
                child = parent
            }
        }

        var shareTargets: [UUID: DocumentRecord] = [:]
        for record in documents {
            if record.hasCurrentDeliveryReceipt,
               record.deliveryReceipt?.isDeliveryOutput == true {
                shareTargets[record.id] = record
                continue
            }
            shareTargets[record.id] = outputsBySourceID[record.id]?
                .first {
                    $0.deliveryReceipt?.sourceRevisionID
                        == record.contentRevisionID
                }
        }

        documentRecordsByID = recordsByID
        workingDocumentCache = working
        deliveryOutputCache = outputs
        verifiedDeliveryOutputCountCache = outputs.reduce(into: 0) {
            if $1.hasCurrentDeliveryReceipt {
                $0 += 1
            }
        }
        pinnedOfficeOutputCache = pinnedOfficeOutputs
        pinnedOfficeStorageSummaryCache =
            PDFOfficePinnedStorageSummary.measuring(
                pinnedOfficeOutputs
        )
        verifiedOutputsBySourceID = outputsBySourceID
        deliveryHistoryBySourceID = historyBySourceID
        verifiedShareTargetsByRecordID = shareTargets
        workingFingerprintCounts = fingerprintCounts
        rebuildAttentionCount()
    }

    private func rebuildRecognizedTextAvailability() {
        var available = Set(
            documents.compactMap { record in
                record.completedActions.contains(.recognizeText)
                    ? record.id
                    : nil
            }
        )
        for (recordID, result) in ocrResults {
            if hasUsefulRecognizedText(result) {
                available.insert(recordID)
            } else {
                available.remove(recordID)
            }
        }
        recordsWithRecognizedText = available
        rebuildAttentionCount()
    }

    private func replaceOCRResults(
        _ results: [UUID: OCRResult]
    ) {
        ocrResults = results
        rebuildRecognizedTextAvailability()
    }

    private func mergeOCRResults(
        _ results: [UUID: OCRResult]
    ) {
        guard !results.isEmpty else { return }
        ocrResults.merge(results) { _, latest in latest }
        for (recordID, result) in results {
            if hasUsefulRecognizedText(result) {
                recordsWithRecognizedText.insert(recordID)
            } else {
                recordsWithRecognizedText.remove(recordID)
            }
        }
        rebuildAttentionCount()
    }

    private func setOCRResult(
        _ result: OCRResult?,
        for recordID: UUID
    ) {
        ocrResults[recordID] = result
        if let result {
            if hasUsefulRecognizedText(result) {
                recordsWithRecognizedText.insert(recordID)
            } else {
                recordsWithRecognizedText.remove(recordID)
            }
            touchResidentAnalysis(recordID)
            trimResidentAnalysisCache()
        } else {
            recordsWithRecognizedText.remove(recordID)
        }
        rebuildAttentionCount()
    }

    private func hasUsefulRecognizedText(
        _ result: OCRResult
    ) -> Bool {
        result.pages.contains { page in
            !page.text
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty
                || !page.blocks.isEmpty
        }
    }

    private func touchResidentAnalysis(_ recordID: UUID) {
        residentAnalysisOrder.removeAll { $0 == recordID }
        residentAnalysisOrder.append(recordID)
    }

    private func trimResidentAnalysisCache(
        retaining additionalRecordIDs: Set<UUID> = []
    ) {
        let maximumCount = Self.maximumResidentAnalysisRecords
            + additionalRecordIDs.count
        while residentAnalysisOrder.count > maximumCount {
            let recordID = residentAnalysisOrder.removeFirst()
            guard !additionalRecordIDs.contains(recordID) else {
                residentAnalysisOrder.append(recordID)
                continue
            }
            textIndices[recordID] = nil
            ocrResults[recordID] = nil
            removeSearchTextCorpus(recordID: recordID)
        }
    }

    private func releaseResidentAnalysis(
        retainingRecordCount: Int
    ) {
        let retainedIDs = Set(
            residentAnalysisOrder.suffix(
                max(0, retainingRecordCount)
            )
        )
        textIndices = textIndices.filter {
            retainedIDs.contains($0.key)
        }
        ocrResults = ocrResults.filter {
            retainedIDs.contains($0.key)
        }
        residentAnalysisOrder.removeAll {
            !retainedIDs.contains($0)
        }
    }

    private func rebuildAttentionCount() {
        attentionCountCache = workingDocumentCache.reduce(into: 0) {
            if needsAttention($1) {
                $0 += 1
            }
        }
        rebuildLibraryCommandSummary()
    }

    private func refreshURLCache() async {
        var result: [UUID: URL] = [:]
        for record in documents {
            result[record.id] = await store.url(for: record)
        }
        documentURLs = result
    }

    private func importSinglePDF(
        from url: URL,
        preferredName: String? = nil,
        deliveryReceipt: PDFDeliveryReceipt? = nil,
        sourceDocumentID: UUID? = nil,
        contentRevisionID: UUID? = nil,
        analyzeAfterImport: Bool = true,
        preserveSourceLocation: Bool = false,
        expectedSHA256: String? = nil,
        expectedByteCount: Int64? = nil,
        sharedImportID: UUID? = nil,
        deferredOpenGeneration: UUID? = nil,
        progress: @escaping PDFImportProgressHandler = { _ in }
    ) async throws -> DocumentRecord {
        let record = try await store.importPDF(
            from: url,
            preferredName: preferredName,
            deliveryReceipt: deliveryReceipt,
            sourceDocumentID: sourceDocumentID,
            contentRevisionID: contentRevisionID,
            preserveSourceLocation: preserveSourceLocation,
            expectedSHA256: expectedSHA256,
            expectedByteCount: expectedByteCount,
            sharedImportID: sharedImportID,
            progress: progress
        )
        guard !Task.isCancelled else {
            deferredCommittedImports[record.id] = record
            let sourceIdentity = externalPDFURLIdentity(url)
            deferredCommittedImportSourceIdentities[record.id] =
                sourceIdentity
            if let deferredOpenGeneration,
               externalPDFDeferredOpenGeneration
                    == deferredOpenGeneration,
               !deferredCommittedOpenRecordIDs.contains(
                    record.id
               ) {
                if let targetSceneID =
                        queuedExternalPDFTargetSceneIDs[sourceIdentity] {
                    deferredCommittedOpenSceneIDs[record.id] =
                        targetSceneID
                }
                deferredCommittedOpenRecordIDs.append(
                    record.id
                )
            }
            if let restored =
                await restoreCommittedImportIfForeground(record) {
                return restored
            }
            throw CancellationError()
        }
        replace(record)
        documentURLs[record.id] = await store.url(for: record)
        if analyzeAfterImport {
            await analyzeDocument(recordID: record.id)
        }
        return self.record(id: record.id) ?? record
    }

    private func analyzeMissingDocuments() async {
        for record in documents
        where record.deliveryReceipt == nil
            && record.brief == nil {
            guard !Task.isCancelled else { return }
            await analyzeDocument(recordID: record.id)
            await Task.yield()
        }
    }

    private func analyzeDocument(recordID: UUID) async {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return }
        if let existing = documentAnalysisTasks[recordID] {
            if existing.revisionID == record.contentRevisionID {
                await existing.task.value
                return
            }
            existing.task.cancel()
            documentAnalysisTasks[recordID] = nil
            analyzingDocumentIDs.remove(recordID)
        }

        let taskGeneration = UUID()
        let residencyGeneration = residentAnalysisGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDocumentAnalysis(
                record: record,
                url: url,
                residencyGeneration: residencyGeneration
            )
        }
        documentAnalysisTasks[recordID] = DocumentAnalysisTaskEntry(
            revisionID: record.contentRevisionID,
            generation: taskGeneration,
            task: task
        )
        analyzingDocumentIDs.insert(recordID)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard documentAnalysisTasks[recordID]?.generation
                == taskGeneration
        else { return }
        documentAnalysisTasks[recordID] = nil
        analyzingDocumentIDs.remove(recordID)
    }

    private func performDocumentAnalysis(
        record: DocumentRecord,
        url: URL,
        residencyGeneration: UUID
    ) async {
        let recordID = record.id

        do {
            let ocrResult = ocrResults[recordID]
            let textService = textIndexService
            let understandingService = understandingService
            let analysisTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let index: DocumentTextIndex
                if let ocrResult {
                    index = textService.index(from: ocrResult)
                } else {
                    index = try textService.extractNativeText(
                        from: url
                    )
                }
                try Task.checkCancellation()
                let brief = understandingService.analyze(
                    index: index,
                    profile: record.profile
                )
                try Task.checkCancellation()
                return (index, brief)
            }
            let (index, brief) = try await valuePropagatingCancellation(
                from: analysisTask
            )
            try Task.checkCancellation()
            guard residentAnalysisGeneration == residencyGeneration,
                  let currentRecord = self.record(id: recordID),
                  currentRecord.contentRevisionID
                    == record.contentRevisionID,
                  documentURLs[recordID] == url
            else { return }
            let updated = try await store.saveAnalysis(
                currentRecord,
                brief: brief,
                textIndex: index,
                ocrResult: ocrResult
            )
            guard let residentRecord = self.record(id: recordID),
                  residentRecord.contentRevisionID
                    == updated.contentRevisionID
            else { return }
            if residentRecord.modifiedAt <= updated.modifiedAt {
                replace(updated)
            }
            guard !Task.isCancelled,
                  residentAnalysisGeneration == residencyGeneration,
                  self.record(id: recordID)?.contentRevisionID
                    == updated.contentRevisionID,
                  documentURLs[recordID] == url
            else { return }
            textIndices[recordID] = index
            touchResidentAnalysis(recordID)
            trimResidentAnalysisCache()
        } catch is CancellationError {
            return
        } catch PaperPathError.lockedPDF {
            return
        } catch {
            guard residentAnalysisGeneration == residencyGeneration,
                  !Task.isCancelled
            else { return }
            present(error)
        }
    }

    private func cancelDocumentAnalysis(for recordID: UUID) {
        documentAnalysisTasks.removeValue(forKey: recordID)?
            .task.cancel()
        analyzingDocumentIDs.remove(recordID)
    }

    private func cancelAllDocumentAnalysis() {
        residentAnalysisGeneration = UUID()
        for entry in documentAnalysisTasks.values {
            entry.task.cancel()
        }
        documentAnalysisTasks.removeAll(keepingCapacity: false)
        analyzingDocumentIDs.removeAll(keepingCapacity: false)
    }

    private func beginImportOperation() -> UUID {
        let token = UUID()
        activeImportOperations.insert(token)
        isImporting = true
        return token
    }

    private func beginForegroundImportProgress(
        progressID: UUID,
        totalItemCount: Int,
        firstURL: URL
    ) {
        activeForegroundImportProgressIDs.insert(progressID)
        foregroundImportRateWindows[progressID] =
            ByteRateWindow()
        foregroundImportProgresses[progressID] =
            PDFOperationProgress(
                label: foregroundImportLabel(
                    stage: .preparing,
                    itemIndex: 0,
                    totalItemCount: totalItemCount,
                    url: firstURL
                ),
                fractionCompleted: 0
            )
    }

    private func finishForegroundImportProgress(
        _ progressID: UUID
    ) {
        guard activeForegroundImportProgressIDs.remove(progressID)
            != nil
        else { return }
        foregroundImportRateWindows[progressID] = nil
        foregroundImportProgresses[progressID] = nil
    }

    private func foregroundImportProgressHandler(
        progressID: UUID,
        itemIndex: Int,
        totalItemCount: Int,
        url: URL
    ) -> PDFImportProgressHandler {
        let relay = MainActorLatestValueRelay<PDFImportProgressUpdate> {
            [weak self] update in
            self?.publishForegroundImportProgress(
                update,
                progressID: progressID,
                itemIndex: itemIndex,
                totalItemCount: totalItemCount,
                url: url
            )
        }
        return { update in
            relay.send(update)
        }
    }

    private func publishForegroundImportProgress(
        _ update: PDFImportProgressUpdate,
        progressID: UUID,
        itemIndex: Int,
        totalItemCount: Int,
        url: URL
    ) {
        guard activeForegroundImportProgressIDs.contains(progressID)
        else { return }
        let total = max(1, totalItemCount)
        let boundedIndex = min(max(0, itemIndex), total - 1)
        let itemFraction = min(
            1,
            max(0, update.fractionCompleted)
        )
        let aggregateFraction = (
            Double(boundedIndex) + itemFraction
        ) / Double(total)
        let currentProgress =
            foregroundImportProgresses[progressID]
        let isCopying = update.stage == .copying
            && update.totalBytes > 0
        let now = Date()
        let didAdvanceBytes = currentProgress?.byteStage != .copying
            || update.processedBytes
                > (currentProgress?.processedBytes ?? 0)
        let bytesPerSecond: Double
        let throughputHistory: [Double]
        if isCopying {
            var rateWindow = foregroundImportRateWindows[
                progressID
            ] ?? ByteRateWindow()
            bytesPerSecond = rateWindow.update(
                stage: .copying,
                processedBytes: update.processedBytes,
                at: now
            )
            throughputHistory = rateWindow.history
            foregroundImportRateWindows[progressID] =
                rateWindow
        } else {
            bytesPerSecond = 0
            throughputHistory = []
        }
        foregroundImportProgresses[progressID] =
            PDFOperationProgress(
                label: foregroundImportLabel(
                    stage: update.stage,
                    itemIndex: boundedIndex,
                    totalItemCount: total,
                    url: url
                ),
                fractionCompleted: max(
                    currentProgress?.fractionCompleted ?? 0,
                    aggregateFraction
                ),
                byteStage: isCopying ? .copying : nil,
                processedBytes: isCopying
                    ? update.processedBytes
                    : 0,
                totalBytes: isCopying ? update.totalBytes : 0,
                bytesPerSecond: bytesPerSecond,
                estimatedRemainingSeconds:
                    isCopying
                        && total == 1
                        && bytesPerSecond > 0
                        ? Double(
                            max(
                                0,
                                update.totalBytes
                                    - update.processedBytes
                            )
                        ) / bytesPerSecond
                        : nil,
                throughputHistory: throughputHistory,
                lastByteUpdateAt:
                    isCopying
                        ? didAdvanceBytes
                            ? now
                            : currentProgress?.lastByteUpdateAt
                        : nil
            )
    }

    private func foregroundImportLabel(
        stage: PDFImportProgressStage,
        itemIndex: Int,
        totalItemCount: Int,
        url: URL
    ) -> String {
        AppLocalization.format(
            "%lld of %lld · %@ · %@",
            min(max(0, itemIndex) + 1, max(1, totalItemCount)),
            max(1, totalItemCount),
            stage.title.localizedUI,
            foregroundImportDisplayName(url)
        )
    }

    private func foregroundImportDisplayName(_ url: URL) -> String {
        let candidate = url.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(
            (candidate.isEmpty ? "Document".localizedUI : candidate)
                .prefix(64)
        )
    }

    @discardableResult
    private func enqueueExternalPDFURLs(
        _ urls: [URL],
        atFront: Bool = false,
        targetSceneID: UUID? = nil
    ) -> Int {
        let orderedCandidates = atFront
            ? urls + queuedExternalPDFURLs
            : queuedExternalPDFURLs + urls
        var seenIdentities = activeExternalPDFURLIdentities
        var updatedQueue: [URL] = []
        updatedQueue.reserveCapacity(
            min(
                Self.maximumQueuedExternalPDFCount,
                orderedCandidates.count
            )
        )
        var overflowCount = 0
        for candidate in orderedCandidates {
            let identity = externalPDFURLIdentity(candidate)
            guard seenIdentities.insert(identity).inserted else {
                continue
            }
            guard updatedQueue.count
                    < Self.maximumQueuedExternalPDFCount
            else {
                overflowCount += 1
                continue
            }
            updatedQueue.append(candidate)
        }
        queuedExternalPDFURLs = updatedQueue
        let retainedIdentities = Set(
            updatedQueue.map(externalPDFURLIdentity)
        ).union(activeExternalPDFURLIdentities)
        if let targetSceneID {
            for url in urls {
                let identity = externalPDFURLIdentity(url)
                guard retainedIdentities.contains(identity),
                      queuedExternalPDFTargetSceneIDs[identity] == nil
                else { continue }
                queuedExternalPDFTargetSceneIDs[identity] = targetSceneID
            }
        }
        queuedExternalPDFTargetSceneIDs =
            queuedExternalPDFTargetSceneIDs.filter {
                retainedIdentities.contains($0.key)
            }
        return overflowCount
    }

    private func externalPDFURLIdentity(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func hasDeferredCommittedImport(from url: URL) -> Bool {
        deferredCommittedImportSourceIdentities.values.contains(
            externalPDFURLIdentity(url)
        )
    }

    private func hasImportedSharedInboxItem(_ itemID: UUID) -> Bool {
        documents.contains { $0.sharedImportID == itemID }
            || deletedDocuments.contains {
                $0.sharedImportID == itemID
            }
            || deferredCommittedImports.values.contains {
                $0.sharedImportID == itemID
            }
    }

    private func externalImportProgressHandler(
        generation: UUID,
        currentName: String,
        completedItemCount: Int,
        totalItemCount: Int
    ) -> PDFImportProgressHandler {
        let relay = MainActorLatestValueRelay<PDFImportProgressUpdate> {
            [weak self] update in
            self?.publishExternalImportProgress(
                update,
                generation: generation,
                currentName: currentName,
                completedItemCount: completedItemCount,
                totalItemCount: totalItemCount
            )
        }
        return { update in
            relay.send(update)
        }
    }

    private func publishExternalImportProgress(
        _ update: PDFImportProgressUpdate,
        generation: UUID,
        currentName: String,
        completedItemCount: Int,
        totalItemCount: Int
    ) {
        guard externalPDFImportGeneration == generation else { return }
        let total = max(1, totalItemCount)
        let completed = min(max(0, completedItemCount), total)
        guard total >= externalImportKnownTotalCount,
              completed >= externalImportCompletedItemCount
        else {
            return
        }
        let itemFraction = min(
            1,
            max(0, update.fractionCompleted)
        )
        if completed > externalImportCompletedItemCount {
            externalImportRateWindow.reset()
            externalImportCurrentItemFraction = 0
        } else if itemFraction < externalImportCurrentItemFraction {
            return
        }
        externalImportCompletedItemCount = completed
        externalImportCurrentItemFraction = itemFraction

        let currentProgress = externalImportProgress
        let totalChanged = externalImportKnownTotalCount != total
        externalImportKnownTotalCount = total
        let aggregateFraction = (
            Double(completed) + itemFraction
        ) / Double(total)
        let isCopying = update.stage == .copying
            && update.totalBytes > 0
        let now = Date()
        let didAdvanceBytes = currentProgress?.byteStage != .copying
            || update.processedBytes
                > (currentProgress?.processedBytes ?? 0)
        let bytesPerSecond: Double
        let throughputHistory: [Double]
        if isCopying {
            bytesPerSecond = externalImportRateWindow.update(
                stage: .copying,
                processedBytes: update.processedBytes,
                at: now
            )
            throughputHistory = externalImportRateWindow.history
        } else {
            bytesPerSecond = 0
            throughputHistory = []
        }
        externalImportProgress = PDFOperationProgress(
            label: AppLocalization.format(
                "%lld of %lld · %@ · %@",
                min(completed + 1, total),
                total,
                update.stage.title.localizedUI,
                externalImportDisplayName(currentName)
            ),
            fractionCompleted: totalChanged
                ? aggregateFraction
                : max(
                    currentProgress?.fractionCompleted ?? 0,
                    aggregateFraction
                ),
            byteStage: isCopying ? .copying : nil,
            processedBytes: isCopying
                ? update.processedBytes
                : 0,
            totalBytes: isCopying ? update.totalBytes : 0,
            bytesPerSecond: bytesPerSecond,
            estimatedRemainingSeconds:
                isCopying
                    && bytesPerSecond > 0
                    ? Double(
                        max(
                            0,
                            update.totalBytes
                                - update.processedBytes
                        )
                    ) / bytesPerSecond
                    : nil,
            throughputHistory: throughputHistory,
            lastByteUpdateAt:
                isCopying
                    ? didAdvanceBytes
                        ? now
                        : currentProgress?.lastByteUpdateAt
                    : nil
        )
    }

    private func externalImportDisplayName(_ value: String) -> String {
        let sanitized = value.components(
            separatedBy: .controlCharacters
        ).joined()
        let trimmed = sanitized.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return String(
            (trimmed.isEmpty ? "Document".localizedUI : trimmed)
                .prefix(64)
        )
    }

    nonisolated private static func shouldDiscardSharedInboxItem(
        after error: Error
    ) -> Bool {
        guard let paperPathError = error as? PaperPathError
        else { return false }
        switch paperPathError {
        case .unreadablePDF,
             .lockedPDF,
             .fileTooLarge:
            return true
        case .unreadableImage,
             .invalidPage,
             .cannotDeleteOnlyPage,
             .cameraUnavailable,
             .emptyScan,
             .insufficientSelection,
             .insufficientStorage,
             .compressionNotBeneficial,
             .outputVerificationFailed,
             .invalidPassword,
             .missingRecognizedText,
             .storageFailure:
            return false
        }
    }

    private func finishImportOperation(_ token: UUID) {
        activeImportOperations.remove(token)
        isImporting = !activeImportOperations.isEmpty
    }

    private func safeExportName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let normalized = String(scalars)
            .replacingOccurrences(
                of: "-{2,}",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((normalized.isEmpty ? "Document" : normalized).prefix(64))
    }

    private func officeShareDestinationURL(
        for receipt: PDFOfficeExportReceipt
    ) -> URL {
        let fileExtension = receipt.format.fileExtension
        let extensionSuffix = ".\(fileExtension)"
        let sourceName = receipt.fileName
        let stem = sourceName.lowercased().hasSuffix(
            extensionSuffix.lowercased()
        )
            ? String(sourceName.dropLast(extensionSuffix.count))
            : sourceName
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                PaperPathTemporaryArtifact.officeSharePrefix
                    + UUID().uuidString,
                isDirectory: true
            )
        return directory
            .appendingPathComponent(safeExportName(stem))
            .appendingPathExtension(fileExtension)
    }

    private func saturatedByteTotal<S: Sequence>(
        _ values: S,
        reserve: Int64 = 0
    ) -> Int64 where S.Element == Int64 {
        values.reduce(max(0, reserve)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(
                max(0, value)
            )
            return overflow ? .max : sum
        }
    }

    private func rebuildSearchCorpora() {
        searchMetadataCorpora = Dictionary(
            documents.map { record in
                (record.id, searchMetadataCorpus(for: record))
            },
            uniquingKeysWith: { _, newest in newest }
        )
        releaseSearchTextCorpora()
    }

    private func searchMetadataCorpus(
        for record: DocumentRecord
    ) -> String {
        let entityText = record.brief?.entities
            .map(\.value)
            .joined(separator: " ") ?? ""
        return DocumentSearchNormalization.text(
            [
                record.displayName,
                record.tags.joined(separator: " "),
                record.brief?.category.title ?? "",
                record.brief?.summary ?? "",
                entityText
            ]
            .joined(separator: "\n")
        )
    }

    func librarySearchMetadataCorpus(
        for recordID: UUID
    ) -> String {
        if let cached = searchMetadataCorpora[recordID] {
            return cached
        }
        guard let record = documentRecordsByID[recordID] else {
            return ""
        }
        return searchMetadataCorpus(for: record)
    }

    private func matchesSearchTerms(
        _ terms: [String],
        in record: DocumentRecord
    ) -> Bool {
        let metadata = searchMetadataCorpora[record.id]
            ?? searchMetadataCorpus(for: record)
        let unresolved = terms.filter {
            !metadata.contains($0)
        }
        guard !unresolved.isEmpty else { return true }
        guard let index = textIndices[record.id] else {
            return false
        }
        if let cached = searchTextCorpora[record.id] {
            return unresolved.allSatisfy(cached.contains)
        }
        if streamingSearchTextRecordIDs.contains(record.id) {
            return textIndex(
                index,
                containsAll: unresolved
            )
        }

        let maximumSingleCorpusCharacters = 1_000_000
        guard index.characterCount <= maximumSingleCorpusCharacters else {
            streamingSearchTextRecordIDs.insert(record.id)
            return textIndex(index, containsAll: unresolved)
        }

        let corpus = DocumentSearchNormalization.text(index.text)
        let cost = corpus.utf8.count
        let maximumTotalCost = 12 * 1_024 * 1_024
        let (nextCost, overflow) =
            searchTextCorpusCost.addingReportingOverflow(cost)
        if !overflow, nextCost <= maximumTotalCost {
            searchTextCorpora[record.id] = corpus
            searchTextCorpusCosts[record.id] = cost
            searchTextCorpusCost = nextCost
        } else {
            streamingSearchTextRecordIDs.insert(record.id)
        }
        return unresolved.allSatisfy(corpus.contains)
    }

    private func textIndex(
        _ index: DocumentTextIndex,
        containsAll terms: [String]
    ) -> Bool {
        var remaining = Set(terms)
        for page in index.pages {
            let searchableText =
                DocumentSearchNormalization.text(page.text)
            for term in terms
            where remaining.contains(term)
                && searchableText.contains(term) {
                remaining.remove(term)
            }
            if remaining.isEmpty {
                return true
            }
        }
        return false
    }

    private func removeSearchTextCorpus(recordID: UUID) {
        searchTextCorpora[recordID] = nil
        streamingSearchTextRecordIDs.remove(recordID)
        let removedCost = searchTextCorpusCosts.removeValue(
            forKey: recordID
        ) ?? 0
        let (nextCost, overflow) =
            searchTextCorpusCost.subtractingReportingOverflow(
                removedCost
            )
        searchTextCorpusCost = overflow
            ? 0
            : max(0, nextCost)
    }

    private func releaseSearchTextCorpora() {
        searchTextCorpora.removeAll(keepingCapacity: false)
        searchTextCorpusCosts.removeAll(keepingCapacity: false)
        streamingSearchTextRecordIDs.removeAll(
            keepingCapacity: false
        )
        searchTextCorpusCost = 0
    }

    private func seedDemo() async throws {
        var fixtures: [(String, (URL) throws -> Void)] = [
            ("Project handoff", DemoPDFBuilder.create),
            ("August invoice", DemoPDFBuilder.createInvoice),
            ("Site review report", DemoPDFBuilder.createReport)
        ]
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "UITEST_OFFICE_SOAK_DEMO"
        ) {
            fixtures.append(
                ("Office stress", DemoPDFBuilder.createOfficeSoak)
            )
        }
#endif
        for (name, builder) in fixtures {
            let temporaryArtifact = ProtectedTemporaryPDF(
                prefix: "PaperPath-DocumentExport-"
            )
            let temporaryURL = temporaryArtifact.fileURL
            defer { temporaryArtifact.remove() }
            try temporaryArtifact.prepare()
            try builder(temporaryURL)
            _ = try await store.importPDF(
                from: temporaryURL,
                preferredName: name,
                preserveSourceLocation: false
            )
        }
    }

#if DEBUG
    private func prepareOfficeCorpusUITestFixture()
        async throws {
        if let fixture = officeCorpusUITestFixture(),
           let verification = try? await store.verifyOfficeExport(
                receiptID: fixture.receipt.id,
                for: fixture.record
           ),
           verification.status == .verified {
            replace(
                verification.record,
                schedulesMetadataSync: false,
                invalidatesSearchText: false
            )
            return
        }

        try await store.eraseAllData()
        applyBootstrapSnapshot(
            try await store.loadBootstrapSnapshot()
        )

        let temporaryArtifact = ProtectedTemporaryPDF(
            prefix: "PaperPath-OfficeCorpusUITest-"
        )
        let sourceURL = temporaryArtifact.fileURL
        defer { temporaryArtifact.remove() }
        try temporaryArtifact.prepare()
        let renderTask = Task.detached(
            priority: .userInitiated
        ) {
            try DemoPDFBuilder.createOfficeCorpusResultFixture(
                at: sourceURL
            )
        }
        try await renderTask.value

        let imported = try await store.importPDF(
            from: sourceURL,
            preferredName: "ConditionalFormattingSamples",
            preserveSourceLocation: false
        )
        applyBootstrapSnapshot(
            try await store.loadBootstrapSnapshot()
        )
        guard let record = record(id: imported.id) else {
            throw PaperPathError.storageFailure(
                "The Office UI fixture source did not persist."
            )
        }

        let artifact = try await makeTextExport(
            recordID: record.id,
            format: .excelWorkbook,
            expectedContentRevisionID:
                record.contentRevisionID
        )
        let values = try artifact.url.resourceValues(
            forKeys: [.fileSizeKey]
        )
        let fileSizeBytes = Int64(values.fileSize ?? 0)
        guard fileSizeBytes > 0,
              officeCorpusNoticesAreComplete(
                artifact.runtimeEvidence?.contentNotices ?? []
              )
        else {
            throw PaperPathError.outputVerificationFailed(
                "the Office UI fixture evidence is incomplete"
            )
        }

        let portfolio = PDFOfficeExportPortfolio(
            profile: artifact.sourceProfile
        )
        var receipt = PDFOfficeExportReceipt(
            format: .excelWorkbook,
            fileName: "ConditionalFormattingSamples.xlsx",
            fileSizeBytes: fileSizeBytes,
            plan: portfolio.plan(for: .excelWorkbook),
            budgetPlan: portfolio.visualBudgetPlan,
            portfolio: portfolio,
            runtimeEvidence: artifact.runtimeEvidence
        )
        receipt.sourceRevisionID = record.contentRevisionID
        guard await retainOfficeExport(
            recordID: record.id,
            receipt: receipt,
            sourceURL: artifact.url,
            expectedContentRevisionID:
                record.contentRevisionID
        ) != nil else {
            throw PaperPathError.outputVerificationFailed(
                "the Office UI fixture output did not persist"
            )
        }
        applyBootstrapSnapshot(
            try await store.loadBootstrapSnapshot()
        )
        guard officeCorpusUITestFixture() != nil else {
            throw PaperPathError.outputVerificationFailed(
                "the Office UI fixture failed validation"
            )
        }
    }

    private func officeCorpusUITestFixture() -> (
        record: DocumentRecord,
        receipt: PDFOfficeExportReceipt
    )? {
        guard documents.count == 1,
              let record = documents.first,
              record.displayName
                == "ConditionalFormattingSamples",
              record.profile.pageCount == 36,
              let receipt = record.officeReceipts.first(
                where: {
                    $0.format == .excelWorkbook
                        && $0.fileName
                            == "ConditionalFormattingSamples.xlsx"
                }
              ),
              receipt.artifactAvailability(
                for: record.contentRevisionID
              ) == .reusable,
              officeCorpusNoticesAreComplete(
                receipt.contentNotices
              )
        else {
            return nil
        }
        return (record, receipt)
    }

    private func officeCorpusNoticesAreComplete(
        _ notices: [PDFOfficeContentNotice]
    ) -> Bool {
        let emptyPages = [
            6, 8, 16, 18, 20, 22, 24, 29, 32, 35
        ]
        return notices.contains {
            $0.kind == .spreadsheetTextOnly
        } && notices.contains {
            $0.kind == .pagesWithoutText
                && $0.pageIndices == emptyPages
        }
    }

    private func prepareFindIndexForUITest() async {
        guard let record = documents.first(where: {
            $0.displayName == "Project handoff"
        }),
        let url = documentURLs[record.id] else { return }
        let textService = textIndexService
        let worker = Task.detached(priority: .userInitiated) {
            try textService.extractNativeText(from: url)
        }
        guard let index = try? await worker.value else { return }
        textIndices[record.id] = index
        touchResidentAnalysis(record.id)
        trimResidentAnalysisCache()
    }
#endif
}
