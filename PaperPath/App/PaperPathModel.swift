import Foundation
import UIKit

private struct BatchPreflightOutcome: Sendable {
    let recordID: UUID
    let revisionID: UUID?
    let assessment: PDFDeliveryPreflightAssessment?
    let issue: PDFBatchDeliveryIssue?
}

private struct PageMutationUndo: Sendable {
    let backupURL: URL
    let bookmarkedPages: [Int]
    let taskCheckpoint: DocumentTaskCheckpoint?
    let label: String
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

private struct ByteRateWindow {
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
        if stage != newStage
            || processedBytes < (samples.last?.bytes ?? 0) {
            stage = newStage
            samples = [Sample(date: date, bytes: processedBytes)]
            rate = 0
            history.removeAll(keepingCapacity: true)
            return rate
        }
        guard processedBytes > (samples.last?.bytes ?? -1) else {
            return rate
        }
        samples.append(Sample(date: date, bytes: processedBytes))
        let cutoff = date.addingTimeInterval(-5)
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
        let duration = max(
            0.05,
            last.date.timeIntervalSince(first.date)
        )
        rate = Double(last.bytes - first.bytes) / duration
        if rate.isFinite, rate > 0 {
            history.append(rate)
            if history.count > 24 {
                history.removeFirst(history.count - 24)
            }
        }
        return rate
    }
}

@MainActor
final class PaperPathModel: ObservableObject {
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
    @Published private(set) var deliveryProcessingDocumentIDs: Set<UUID> = []
    @Published private(set) var batchDeliveryPendingDocumentIDs: Set<UUID> = []
    @Published private(set) var batesBatchProgress:
        PDFBatesBatchProgress?
    @Published private(set) var batesBatchReceipts:
        [PDFSignedBatesBatchReceipt] = []
    @Published private(set) var batesReceiptVerificationProgress:
        PDFBatesBatchReceiptVerificationProgress?
    @Published private(set) var batesExternalMatchProgress:
        PDFBatesExternalMatchProgress?
    @Published private(set) var operationProgress: [UUID: PDFOperationProgress] = [:]
    @Published private(set) var savedSignatureData: Data?
    @Published private(set) var savedSignatures: [SavedSignature] = []
    @Published private(set) var selectedSignatureID: UUID?
    @Published private(set) var lastBatchDeliveryRun: PDFBatchDeliveryRun?
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
    @Published var isLoading = true
    @Published var isImporting = false
    @Published var errorMessage: String?
    @Published var errorOffersSettings = false
    @Published private(set) var actionNotice: AppActionNotice?
    @Published var noticeMessage: String? {
        didSet {
            if noticeMessage != nil {
                actionNotice = nil
            }
        }
    }
    @Published private(set) var pendingExternalDocumentID: UUID?
    @Published var isPresentingFullUnlock = false
    @Published private(set) var verifiedOutputSuccessCount =
        AppEntitlement.verifiedOutputCount
    @Published private(set) var settingsPresentationGeneration = 0

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
    private let documentStructureService: PDFDocumentStructureService
    private let signatureStore: SignatureStore
    private let metadataSyncService: PDFMetadataSyncService
    private var documentRecordsByID: [UUID: DocumentRecord] = [:]
    private var workingDocumentCache: [DocumentRecord] = []
    private var deliveryOutputCache: [DocumentRecord] = []
    private var verifiedOutputsBySourceID:
        [UUID: [DocumentRecord]] = [:]
    private var verifiedShareTargetsByRecordID:
        [UUID: DocumentRecord] = [:]
    private var workingFingerprintCounts: [String: Int] = [:]
    private var searchMetadataCorpora: [UUID: String] = [:]
    private var searchTextCorpora: [UUID: String] = [:]
    private var searchTextCorpusCosts: [UUID: Int] = [:]
    private var streamingSearchTextRecordIDs: Set<UUID> = []
    private var searchTextCorpusCost = 0
    private var deliveryPreflightCache: [
        UUID: PDFDeliveryPreflightCacheEntry
    ] = [:]
    private var comparisonCache: [
        PDFComparisonCacheKey: PDFChangeReview
    ] = [:]
    private var comparisonCacheOrder: [PDFComparisonCacheKey] = []
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
    private var pageMutationUndos: [UUID: PageMutationUndo] = [:]
    private var deferredBootstrapTask: Task<Void, Never>?
    private var metadataSyncTask: Task<Void, Never>?
    private nonisolated(unsafe) var metadataSyncObserver:
        NSObjectProtocol?
    private nonisolated(unsafe) var memoryWarningObserver:
        NSObjectProtocol?
    private var didBootstrap = false
    private var isApplyingMetadataSync = false
    private var isSynchronizingMetadata = false
    private var queuedExternalPDFURLs: [URL] = []
    private var isProcessingExternalPDFs = false
    private var officeProductionTask: Task<Void, Never>?
    private var officeProductionCancelledJobID: UUID?
    private var officeResourceMonitorTask: Task<Void, Never>?
    private var officeIntegrityGeneration: UUID?
    private var officeIntegrityRateWindow = ByteRateWindow()
    private var operationRateWindows: [UUID: ByteRateWindow] = [:]
    private var exclusiveDocumentOperations: [UUID: UUID] = [:]

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
        self.documentStructureService = documentStructureService
        self.signatureStore = signatureStore
        self.metadataSyncService = metadataSyncService
            ?? PDFMetadataSyncService()
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.releaseEvidenceCaches()
            }
        }
    }

    deinit {
        deferredBootstrapTask?.cancel()
        metadataSyncTask?.cancel()
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
        deferredBootstrapTask?.cancel()
        deferredBootstrapTask = nil
        isLoading = true
        await discardInterruptedTemporaryFiles()
        do {
            applyBootstrapSnapshot(
                try await store.loadBootstrapSnapshot()
            )
            await applyTrashRetention(showNotice: false)
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("UITEST_RESET_DEMO") {
                for document in documents + deletedDocuments {
                    try await store.delete(document)
                }
                await store.clearBatchDeliveryRun()
                await store.clearOfficeProductionQueue()
                documents = []
                deletedDocuments = []
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
            lastBatchDeliveryRun = try await store.loadBatchDeliveryRun()
            if lastBatchDeliveryRun != nil,
               recoverableBatchDeliveryRun() == nil {
                lastBatchDeliveryRun = nil
                await store.clearBatchDeliveryRun()
            }
            applySignatureLibrary(await signatureStore.loadLibrary())
            rebuildSearchCorpora()
            didBootstrap = true
#if DEBUG
            if arguments.contains("SCREENSHOT_SETTINGS") {
                settingsPresentationGeneration &+= 1
            } else if arguments.contains("SCREENSHOT_FULL_UNLOCK") {
                isPresentingFullUnlock = true
            }
#endif
            isLoading = false
            await processPendingExternalPDFs()
            guard !isRunningAutomatedTests else { return }
            deferredBootstrapTask?.cancel()
            deferredBootstrapTask = Task { [weak self] in
                await self?.finishDeferredBootstrap()
            }
        } catch {
            isLoading = false
            present(error)
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
        ocrResults = snapshot.ocrResults
        deliveryPreflightCache = snapshot.deliveryPreflightCache
    }

    private func valuePropagatingCancellation<Value>(
        from task: Task<Value, Error>
    ) async throws -> Value {
        try await withTaskCancellationHandler {
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
        } catch {
            present(error)
        }
    }

    func selectSavedSignature(_ id: UUID) async {
        do {
            let library = try await signatureStore.select(id)
            applySignatureLibrary(library)
            noticeMessage = "Saved signature selected".localizedUI
        } catch {
            present(error)
        }
    }

    func removeSavedSignature(_ id: UUID) async {
        do {
            let library = try await signatureStore.remove(id: id)
            applySignatureLibrary(library)
            noticeMessage = "Saved signature removed".localizedUI
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

    func importPDF(from url: URL) async -> DocumentRecord? {
        isImporting = true
        defer { isImporting = false }
        do {
            let record = try await importSinglePDF(
                from: url,
                preserveSourceLocation: true
            )
            noticeMessage = "Private copy imported".localizedUI
            return record
        } catch {
            present(error)
            return nil
        }
    }

    func importPDFs(from urls: [URL]) async -> [DocumentRecord] {
        guard !urls.isEmpty else { return [] }
        isImporting = true
        defer { isImporting = false }

        var imported: [DocumentRecord] = []
        var failures: [Error] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            do {
                imported.append(
                    try await importSinglePDF(
                        from: url,
                        preserveSourceLocation: true
                    )
                )
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
        return imported
    }

    func receiveExternalURL(_ url: URL) async {
        if url.isFileURL {
            guard url.pathExtension.caseInsensitiveCompare("pdf")
                    == .orderedSame
            else {
                present(ExternalPDFInboxError.invalidPDF)
                return
            }
            if !queuedExternalPDFURLs.contains(url) {
                queuedExternalPDFURLs.append(url)
            }
        } else {
            guard url.scheme?.lowercased() == "paperpath" else { return }
            if url.host?.lowercased() == "settings" {
                settingsPresentationGeneration &+= 1
                return
            }
        }
        await processPendingExternalPDFs()
    }

    func processPendingExternalPDFs() async {
        guard didBootstrap,
              !isProcessingExternalPDFs
        else { return }

        isProcessingExternalPDFs = true
        isImporting = true
        defer {
            isImporting = false
            isProcessingExternalPDFs = false
        }

        var imported: [DocumentRecord] = []
        var failures: [Error] = []
        var attemptedSharedContainers: Set<URL> = []

        while true {
            guard !Task.isCancelled else { break }
            let directURLs = queuedExternalPDFURLs
            queuedExternalPDFURLs.removeAll()
            let inboxTask = Task.detached(priority: .utility) {
                try ExternalPDFInbox.pendingItems()
            }
            let pendingItems = (
                try? await valuePropagatingCancellation(
                    from: inboxTask
                )
            ) ?? []
            guard !Task.isCancelled else { break }
            let sharedItems = pendingItems.filter {
                attemptedSharedContainers.insert($0.containerURL).inserted
            }
            guard !directURLs.isEmpty || !sharedItems.isEmpty else { break }

            for url in directURLs {
                guard !Task.isCancelled else { break }
                do {
                    imported.append(
                        try await importSinglePDF(
                            from: url,
                            preserveSourceLocation: true
                        )
                    )
                } catch {
                    failures.append(error)
                }
            }

            for item in sharedItems {
                guard !Task.isCancelled else { break }
                do {
                    let record = try await importSinglePDF(
                        from: item.fileURL,
                        preferredName: item.preferredName,
                        preserveSourceLocation: false
                    )
                    imported.append(record)
                    _ = try? await Task.detached(priority: .utility) {
                        try ExternalPDFInbox.remove(item)
                    }.value
                } catch {
                    failures.append(error)
                }
            }
        }

        guard !imported.isEmpty || !failures.isEmpty else { return }
        if let firstImported = imported.first {
            pendingExternalDocumentID = firstImported.id
        }

        if imported.isEmpty, let firstFailure = failures.first {
            present(firstFailure)
        } else if !failures.isEmpty {
            noticeMessage = AppLocalization.format(
                "%lld imported · %lld couldn’t be opened",
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

    func clearPendingExternalDocument(_ recordID: UUID) {
        guard pendingExternalDocumentID == recordID else { return }
        pendingExternalDocumentID = nil
    }

    func createPaperTemplate(
        kind: PaperTemplateKind,
        size: PaperTemplateSize,
        pageCount: Int,
        title: String
    ) async -> DocumentRecord? {
        isImporting = true
        defer { isImporting = false }

        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = normalizedTitle.isEmpty
            ? "\(kind.title) Paper"
            : String(normalizedTitle.prefix(80))
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Template-\(UUID().uuidString).pdf"
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
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
            noticeMessage = "\(kind.title) PDF created on this device"
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
        isImporting = true
        defer { isImporting = false }
        let temporaryURL = temporaryPDFURL(prefix: "PaperPath-Sample")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        do {
            try DemoPDFBuilder.create(at: temporaryURL)
            let record = try await importSinglePDF(
                from: temporaryURL,
                preferredName: "Project handoff sample",
                preserveSourceLocation: false
            )
            noticeMessage = "Local sample created".localizedUI
            return record.id
        } catch {
            present(error)
            return nil
        }
    }

    func duplicate(recordID: UUID) async -> DocumentRecord? {
        guard let source = record(id: recordID) else { return nil }
        isImporting = true
        defer { isImporting = false }

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
                if let ocrResult = ocrResults[source.id] {
                    ocrResults[duplicated.id] = ocrResult
                }
            }

            replace(duplicated)
            noticeMessage = "Independent working copy created"
            return duplicated
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
        pages: [ScanPageImage]
    ) async -> DocumentRecord? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'Scan'"
        return await importImagePages(
            pages,
            options: .document,
            preferredName: formatter.string(from: Date()),
            successMessage: "Scan saved on device"
        )
    }

    func importImages(_ images: [UIImage]) async -> DocumentRecord? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'Images'"
        return await importImagePages(
            images.map {
                ScanPageImage(
                    image: $0,
                    processingOptions: .original
                )
            },
            options: .original,
            preferredName: formatter.string(from: Date()),
            successMessage: "Image PDF created on device"
        )
    }

    private func importImagePages(
        _ pages: [ScanPageImage],
        options: ScanProcessingOptions,
        preferredName: String,
        successMessage: String
    ) async -> DocumentRecord? {
        isImporting = true
        defer { isImporting = false }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperPath-Scan-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let renderer = scanRenderer
            let renderTask = Task.detached(priority: .userInitiated) {
                try renderer.render(
                    pages: pages,
                    to: temporaryURL,
                    options: options
                )
            }
            try await valuePropagatingCancellation(from: renderTask)
            try Task.checkCancellation()
            let record = try await store.importPDF(
                from: temporaryURL,
                preferredName: preferredName
            )
            replace(record)
            documentURLs[record.id] = await store.url(for: record)
            await analyzeDocument(recordID: record.id)
            noticeMessage = successMessage
            return self.record(id: record.id)
        } catch {
            present(error)
            return nil
        }
    }

    func rename(recordID: UUID, to name: String) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.rename(record, to: name)
            replace(updated)
            noticeMessage = "Name updated".localizedUI
        } catch {
            present(error)
        }
    }

    func updateWorkflow(
        recordID: UUID,
        status: DocumentWorkflowStatus
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updateWorkflow(record, status: status)
            replace(updated)
            noticeMessage = AppLocalization.format(
                "Moved to %@",
                status.title.localizedUI
            )
        } catch {
            present(error)
        }
    }

    func togglePinned(recordID: UUID) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.setPinned(
                record,
                isPinned: !record.isPinned
            )
            replace(updated)
            noticeMessage = updated.isPinned ? "Pinned" : "Unpinned"
        } catch {
            present(error)
        }
    }

    func setPinned(
        recordIDs: Set<UUID>,
        isPinned: Bool
    ) async {
        let records = documents.filter {
            recordIDs.contains($0.id) && $0.isPinned != isPinned
        }
        guard !records.isEmpty else { return }

        do {
            for record in records {
                let updated = try await store.setPinned(
                    record,
                    isPinned: isPinned
                )
                replace(updated)
            }
            noticeMessage = isPinned
                ? "\(records.count) private copies pinned"
                : "\(records.count) private copies unpinned"
        } catch {
            present(error)
        }
    }

    func updateWorkflow(
        recordIDs: Set<UUID>,
        status: DocumentWorkflowStatus
    ) async {
        let records = documents.filter {
            recordIDs.contains($0.id)
                && $0.workflowStatus != status
        }
        guard !records.isEmpty else { return }

        do {
            for record in records {
                let updated = try await store.updateWorkflow(
                    record,
                    status: status
                )
                replace(updated)
            }
            noticeMessage = AppLocalization.format(
                "%lld private copies moved to %@",
                records.count,
                status.title.localizedUI
            )
        } catch {
            present(error)
        }
    }

    func updateTags(recordID: UUID, tags: [String]) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updateTags(record, tags: tags)
            replace(updated)
            noticeMessage = "Tags updated".localizedUI
        } catch {
            present(error)
        }
    }

    func updateTags(
        recordIDs: Set<UUID>,
        adding tagsToAdd: [String] = [],
        removing tagsToRemove: [String] = []
    ) async {
        let records = documents.filter {
            recordIDs.contains($0.id)
        }
        guard !records.isEmpty else { return }

        do {
            for record in records {
                var tags = record.tags.filter { existing in
                    !tagsToRemove.contains {
                        $0.caseInsensitiveCompare(existing)
                            == .orderedSame
                    }
                }
                for candidate in tagsToAdd where !tags.contains(
                    where: {
                        $0.caseInsensitiveCompare(candidate)
                            == .orderedSame
                    }
                ) {
                    tags.append(candidate)
                }
                let updated = try await store.updateTags(
                    record,
                    tags: tags
                )
                replace(updated)
            }
            noticeMessage = "\(records.count) private copies updated"
        } catch {
            present(error)
        }
    }

    func updateDueDate(
        recordID: UUID,
        dueAt: Date?
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updateDueDate(
                record,
                dueAt: dueAt
            )
            replace(updated)
            await LocalDueReminderScheduler.update(
                recordID: recordID,
                dueAt: updated.dueAt
            )
            noticeMessage = dueAt == nil
                ? "Due date removed".localizedUI
                : "Due date updated".localizedUI
        } catch {
            present(error)
        }
    }

    func updatePrivateNote(
        recordID: UUID,
        note: String?
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updatePrivateNote(
                record,
                note: note
            )
            replace(updated)
            noticeMessage = updated.privateNote == nil
                ? "Private note removed".localizedUI
                : "Private note saved on this device".localizedUI
        } catch {
            present(error)
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
            replace(updated, schedulesMetadataSync: false)
        } catch {
            // Office export remains usable if local receipt history fails.
        }
    }

    func retainOfficeExport(
        recordID: UUID,
        receipt: PDFOfficeExportReceipt,
        sourceURL: URL
    ) async -> (
        receipt: PDFOfficeExportReceipt,
        url: URL
    )? {
        guard let record = record(id: recordID) else {
            return nil
        }
        do {
            let retained = try await store.retainOfficeExport(
                receipt,
                sourceURL: sourceURL,
                for: record
            )
            replace(retained.record, schedulesMetadataSync: false)
            try? FileManager.default.removeItem(at: sourceURL)
            cleanupOfficeExportContainer(for: sourceURL)
            return (
                receipt: retained.receipt,
                url: retained.url
            )
        } catch {
            await recordOfficeExportReceipt(
                recordID: recordID,
                receipt: receipt
            )
            return nil
        }
    }

    func reusableOfficeExportURL(
        recordID: UUID,
        receipt: PDFOfficeExportReceipt
    ) async -> URL? {
        guard let record = record(id: recordID) else {
            return nil
        }
        return await store.reusableOfficeExportURL(
            for: receipt,
            record: record
        )
    }

    var pinnedOfficeOutputs: [PDFPinnedOfficeOutput] {
        documents.flatMap { record in
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
            ($0.receipt.pinnedAt ?? .distantPast)
                > ($1.receipt.pinnedAt ?? .distantPast)
        }
    }

    var pinnedOfficeStorageSummary: PDFOfficePinnedStorageSummary {
        let outputs = pinnedOfficeOutputs
        return PDFOfficePinnedStorageSummary(
            outputCount: outputs.count,
            byteCount: outputs.reduce(Int64(0)) {
                $0 + $1.receipt.fileSizeBytes
            }
        )
    }

    func setOfficeExportPinned(
        recordID: UUID,
        receiptID: UUID,
        pinned: Bool
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
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
            noticeMessage = pinned
                ? "Office output pinned on this device".localizedUI
                : "Office output returns to seven-day retention".localizedUI
        } catch {
            present(error)
        }
    }

    func unpinAllOfficeExports() async {
        let outputs = pinnedOfficeOutputs
        guard !outputs.isEmpty else { return }
        var unpinnedCount = 0
        for output in outputs {
            guard let record = record(id: output.recordID) else {
                continue
            }
            do {
                let updated = try await store.setOfficeExportPinned(
                    receiptID: output.receipt.id,
                    pinned: false,
                    for: record
                )
                replace(updated, schedulesMetadataSync: false)
                unpinnedCount += 1
            } catch {
                present(error)
                return
            }
        }
        noticeMessage = AppLocalization.format(
            "%lld Office output%@ returned to standard retention",
            unpinnedCount,
            unpinnedCount == 1 ? "" : "s"
        )
    }

    func makeOfficeBatchArchive(
        recordID: UUID,
        batchID: UUID
    ) async throws -> URL {
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
        guard !receipts.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "No retained Office batch parts are available."
            )
        }

        var retainedSources: [OfficeBatchArchiveSource] = []
        var manifestParts: [[String: Any]] = []
        for receipt in receipts {
            try Task.checkCancellation()
            guard let url = await store.reusableOfficeExportURL(
                for: receipt,
                record: record
            ) else { continue }
            let partNumber = (receipt.batchSegmentIndex ?? 0) + 1
            let startPage = (receipt.sourcePageStartIndex ?? 0) + 1
            let endPage = (receipt.sourcePageEndIndex ?? 0) + 1
            let archiveName = String(
                format:
                    "%02d-part-%02d-pages-%d-%d.%@",
                partNumber,
                partNumber,
                startPage,
                endPage,
                receipt.format.fileExtension
            )
            retainedSources.append(
                OfficeBatchArchiveSource(
                    sourceURL: url,
                    archiveName: archiveName
                )
            )
            manifestParts.append(
                [
                    "file": archiveName,
                    "part": partNumber,
                    "pages": "\(startPage)-\(endPage)",
                    "bytes": receipt.fileSizeBytes,
                    "receipt_id": receipt.id.uuidString,
                    "sha256":
                        receipt.artifactSHA256 ?? "unavailable"
                ]
            )
        }
        guard !retainedSources.isEmpty else {
            throw PaperPathError.insufficientSelection(
                "The retained Office batch parts are no longer available."
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Office-Batch-\(UUID().uuidString)",
                isDirectory: true
            )
        try LocalFileSecurity.prepareProtectedDirectory(
            at: directory
        )
        let manifestURL = directory.appendingPathComponent(
            "PaperPath-batch-manifest.json"
        )
        let destination = directory.appendingPathComponent(
            "\(safeExportName(record.displayName))-\(run.plan.format.fileExtension)-batch.zip"
        )
        do {
            let manifest: [String: Any] = [
                "schema": "PaperPath Office Batch V31",
                "batch_id": run.id.uuidString,
                "source_revision_id": run.plan.sourceRevisionID.uuidString,
                "format": run.plan.format.fileExtension.uppercased(),
                "source_pages": run.plan.sourcePageCount,
                "completed_parts": retainedSources.count,
                "planned_parts": run.plan.segmentCount,
                "created_at": ISO8601DateFormatter().string(
                    from: run.startedAt
                ),
                "parts": manifestParts
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
            try manifestData.write(to: manifestURL, options: .atomic)
            try LocalFileSecurity.requireCompleteProtection(
                to: manifestURL
            )
            retainedSources.append(
                OfficeBatchArchiveSource(
                    sourceURL: manifestURL,
                    archiveName: manifestURL.lastPathComponent
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
            try await withTaskCancellationHandler {
                try await archiveTask.value
            } onCancel: {
                archiveTask.cancel()
            }
            try? FileManager.default.removeItem(at: manifestURL)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
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
        officeProductionQueue.jobs[index].completedAt = Date()
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
                job.startedAt = job.startedAt ?? Date()
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
                            $0.completedAt = Date()
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
                    $0.completedAt = Date()
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
                    $0.completedAt = wasCancelled ? Date() : nil
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
                    $0.completedAt = Date()
                    $0.detail = error.localizedDescription
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
                    recordID: job.recordID
               ) {
                try Task.checkCancellation()
                return resumed
            }
        }
        guard let created = try await makeOfficeBatch(
            recordID: job.recordID,
            format: job.format
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
            format: job.format
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
            sourceURL: artifact.url
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
        officeProductionQueue.updatedAt = Date()
    }

    private func persistOfficeProductionQueue() async {
        officeProductionQueue.updatedAt = Date()
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
            officeProductionQueue.jobs[index].completedAt = Date()
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
        let deliveryWorkingBytes = artifacts.reduce(Int64(0)) {
            $0 + $1.receipt.fileSizeBytes
        } + 64 * 1_024 * 1_024
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
            var package = PDFOfficeDeliveryPackage(
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

    func officeDeliveryPackageURLs(
        _ package: PDFOfficeDeliveryPackage
    ) async throws -> (archive: URL, report: URL) {
        try await store.officeDeliveryPackageURLs(for: package)
    }

    func verifyOfficeDeliveryReport(
        at url: URL
    ) async throws -> PDFOfficeReportVerificationResult {
        let result = try await store.verifyOfficeDeliveryReport(
            at: url
        )
        officeTrustedSigners = (
            try? await store.loadOfficeTrustedSigners()
        ) ?? officeTrustedSigners
        lastOfficeReportVerification = result
        return result
    }

    func clearOfficeReportVerification() {
        lastOfficeReportVerification = nil
        officeExternalMatchProgress = nil
    }

    func matchExternalOfficeDeliveryFiles(
        report: PDFOfficeSignedVerificationReport,
        candidateURLs: [URL]
    ) async -> PDFOfficeExternalMatchReport? {
        officeExternalMatchProgress = nil
        do {
            let result = try await store
                .matchExternalOfficeDeliveryFiles(
                    report: report,
                    candidateURLs: candidateURLs
                ) { [weak self] progress in
                    self?.officeExternalMatchProgress = progress
                }
            if officeExternalMatchProgress?.packageID
                == report.payload.packageID {
                officeExternalMatchProgress = nil
            }
            return result
        } catch is CancellationError {
            officeExternalMatchProgress = nil
            return nil
        } catch {
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
            if let keyID = verification.keyID {
                lastOfficeReportVerification =
                    PDFOfficeReportVerificationResult(
                        status: verification.status,
                        packageID: verification.packageID,
                        keyID: keyID,
                        sourceCount: verification.sourceCount,
                        outputCount: verification.outputCount,
                        createdAt: verification.createdAt,
                        detail: verification.detail,
                        publicKeyBase64:
                            verification.publicKeyBase64,
                        trustStatus: .trusted,
                        trustedSignerName:
                            "Signer \(keyID.prefix(8))",
                        signedReport: verification.signedReport
                    )
            }
            noticeMessage = "Signer trusted on this device"
        } catch {
            present(error)
        }
    }

    func removeOfficeTrustedSigner(
        _ keyID: String
    ) async {
        do {
            officeTrustedSigners = try await store
                .removeOfficeTrustedSigner(keyID)
            if lastOfficeReportVerification?.keyID == keyID,
               let verification = lastOfficeReportVerification {
                lastOfficeReportVerification =
                    PDFOfficeReportVerificationResult(
                        status: verification.status,
                        packageID: verification.packageID,
                        keyID: verification.keyID,
                        sourceCount: verification.sourceCount,
                        outputCount: verification.outputCount,
                        createdAt: verification.createdAt,
                        detail: verification.detail,
                        publicKeyBase64:
                            verification.publicKeyBase64,
                        trustStatus: .unknown,
                        trustedSignerName: nil,
                        signedReport: verification.signedReport
                    )
            }
        } catch {
            present(error)
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
        let totalBytes = receiptByteCounts.values.reduce(0, +)
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
                    processedBytes += receiptBytes
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
                processedBytes += receiptBytes
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
            checkedAt: Date()
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
        let boundedBytes = max(
            previousBytes,
            min(max(0, processedBytes), max(0, totalBytes))
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
            ? Double(max(0, totalBytes - boundedBytes))
                / bytesPerSecond
            : nil
        officeIntegrityProgress = PDFOfficeIntegrityProgress(
            completedCount: completedCount,
            totalCount: totalCount,
            currentSourceName: currentSourceName,
            processedBytes: boundedBytes,
            totalBytes: totalBytes,
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

    func toggleBookmark(recordID: UUID, pageIndex: Int) async {
        guard let record = record(id: recordID),
              pageIndex >= 0,
              pageIndex < record.profile.pageCount
        else { return }
        var pages = Set(record.bookmarkedPages)
        if pages.contains(pageIndex) {
            pages.remove(pageIndex)
        } else {
            pages.insert(pageIndex)
        }
        do {
            let updated = try await store.updateBookmarks(
                record,
                pages: Array(pages),
                preserveNames: true
            )
            replace(updated)
            noticeMessage = pages.contains(pageIndex)
                ? "Page \(pageIndex + 1) bookmarked"
                : "Bookmark removed"
        } catch {
            present(error)
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
            replace(updated)
            noticeMessage = updated.bookmarkNames[pageIndex] == nil
                ? "Bookmark name removed"
                : "Bookmark named"
        } catch {
            present(error)
        }
    }

    func updateReadingPosition(
        recordID: UUID,
        pageIndex: Int
    ) async {
        guard let record = record(id: recordID) else { return }
        if record.lastPageIndex == pageIndex,
           let lastViewedAt = record.lastViewedAt,
           Date().timeIntervalSince(lastViewedAt) < 30 {
            return
        }
        do {
            let updated = try await store.updateReadingPosition(
                record,
                pageIndex: pageIndex
            )
            replace(updated)
        } catch {
            // Reading remains usable even if this noncritical state fails.
        }
    }

    func recentDocuments(
        excluding recordID: UUID,
        limit: Int = 5
    ) -> [DocumentRecord] {
        let currentRole = record(id: recordID)?.isDeliveryArtifact
        return documents
            .filter {
                guard $0.id != recordID else { return false }
                guard let currentRole else { return true }
                return $0.isDeliveryArtifact == currentRole
            }
            .sorted {
                let left = $0.lastViewedAt ?? $0.modifiedAt
                let right = $1.lastViewedAt ?? $1.modifiedAt
                return left > right
            }
            .prefix(max(0, limit))
            .map { $0 }
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
        guard !isRunningAutomatedTests,
              !isSynchronizingMetadata
        else { return }
        isSynchronizingMetadata = true
        metadataSyncStatus = PDFMetadataSyncStatus(
            state: .syncing,
            documentCount: metadataSyncStatus.documentCount,
            updatedAt: metadataSyncStatus.updatedAt,
            detail: "Merging lightweight metadata through iCloud."
        )
        defer { isSynchronizingMetadata = false }
        do {
            let fingerprintedRecords = try await store
                .ensureContentFingerprints(for: documents)
            for record in fingerprintedRecords
            where self.record(id: record.id)?.contentFingerprint
                != record.contentFingerprint {
                replace(record, schedulesMetadataSync: false)
            }
            let result = try metadataSyncService.synchronize(
                records: fingerprintedRecords
            )
            isApplyingMetadataSync = true
            defer { isApplyingMetadataSync = false }
            for update in result.updates {
                guard let current = record(id: update.recordID) else {
                    continue
                }
                let updated = try await store.applyMetadataSync(
                    update,
                    to: current
                )
                replace(updated, schedulesMetadataSync: false)
            }
            let detail: String
            if result.isCloudAvailable {
                detail = result.eligibleDocumentCount == 0
                    ? "No matching document metadata is ready to sync."
                    : "Page position, bookmarks, tags, status, and verified receipts are current. PDF files stay local."
            } else {
                detail =
                    "Sign in to iCloud and enable PaperPath iCloud access to sync metadata. PDF files stay local."
            }
            metadataSyncStatus = PDFMetadataSyncStatus(
                state: result.isCloudAvailable
                    ? .synced
                    : .unavailable,
                documentCount: result.eligibleDocumentCount,
                updatedAt: result.synchronizedAt,
                detail: detail
            )
            if showNotice {
                noticeMessage = result.isCloudAvailable
                    ? "Document metadata synced"
                    : "iCloud metadata sync is unavailable"
            }
        } catch is CancellationError {
            return
        } catch {
            metadataSyncStatus = PDFMetadataSyncStatus(
                state: .failed,
                documentCount: metadataSyncStatus.documentCount,
                updatedAt: metadataSyncStatus.updatedAt,
                detail: error.localizedDescription
            )
            if showNotice {
                noticeMessage = "Metadata sync could not finish".localizedUI
            }
        }
    }

    func setMetadataSyncEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(
            enabled,
            forKey: AppPreferences.metadataSyncEnabledKey
        )
        if enabled {
            startMetadataSyncObservation()
            await synchronizeMetadata()
        } else {
            metadataSyncTask?.cancel()
            metadataSyncTask = nil
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
        do {
            try metadataSyncService.clearSyncedMetadata()
            metadataSyncStatus = metadataSyncDisabledStatus
            noticeMessage = "Synced metadata deleted".localizedUI
        } catch {
            present(error)
        }
    }

    func sourceLocation(
        recordID: UUID
    ) async -> PDFSourceLocationSnapshot? {
        guard let record = record(id: recordID) else { return nil }
        do {
            return try await store.sourceLocation(for: record)
        } catch {
            present(error)
            return nil
        }
    }

    @discardableResult
    func writeBackToSource(recordID: UUID) async -> Bool {
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
            let updated = try await store.writeBackToSource(record)
            replace(updated)
            noticeMessage = "Original updated in Files".localizedUI
            return true
        } catch {
            present(error)
            return false
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
            isImporting = true
            defer { isImporting = false }
            let imported = try await importSinglePDF(
                from: url,
                preferredName: "\(record.displayName) - Files update",
                preserveSourceLocation: true
            )
            noticeMessage = "Updated source imported as a new private copy"
                .localizedUI
            return imported
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

        do {
            for record in records {
                let deleted = try await store.moveToTrash(record)
                removeRecordState(record.id)
                deletedDocuments.append(deleted)
            }
            deletedDocuments.sort {
                ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
            presentActionNotice(
                message: AppLocalization.format(
                    "%lld items moved to Trash",
                    records.count
                ),
                detail: "Restore the complete selection in one step.",
                kind: .recovery,
                action: .restoreTrash(
                    recordIDs: records.map(\.id)
                )
            )
            return true
        } catch {
            present(error)
            return false
        }
    }

    func dismissActionNotice(id: UUID? = nil) {
        guard id == nil || actionNotice?.id == id else { return }
        actionNotice = nil
    }

    func performNoticeAction(
        _ notice: AppActionNotice
    ) async {
        guard actionNotice?.id == notice.id else { return }
        actionNotice = nil
        switch notice.action {
        case .restoreTrash(let recordIDs):
            await restoreDeletedDocuments(recordIDs: recordIDs)
        case .undoPageChange(let recordID):
            _ = await undoLastPageChange(recordID: recordID)
        case .undoPageChanges(let recordIDs):
            _ = await undoLastPageChanges(recordIDs: recordIDs)
        }
    }

    private func restoreDeletedDocuments(
        recordIDs: [UUID]
    ) async {
        let requested = Set(recordIDs)
        let records = deletedDocuments.filter {
            requested.contains($0.id)
        }
        guard !records.isEmpty else { return }

        var restoredIDs: Set<UUID> = []
        var restoredRecords: [DocumentRecord] = []
        do {
            for record in records {
                let restored = try await store.restoreFromTrash(record)
                restoredIDs.insert(restored.id)
                restoredRecords.append(restored)
                documentURLs[restored.id] = await store.url(
                    for: restored
                )
            }
            deletedDocuments.removeAll {
                restoredIDs.contains($0.id)
            }
            textIndices = try await store.loadTextIndices()
            ocrResults = try await store.loadOCRResults()
            documents.append(contentsOf: restoredRecords)
            rebuildSearchCorpora()
            sortDocuments()
            if restoredIDs.count == 1,
               let restored = records.first {
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
        } catch {
            if !restoredIDs.isEmpty {
                documents.append(contentsOf: restoredRecords)
                deletedDocuments.removeAll {
                    restoredIDs.contains($0.id)
                }
                if let restoredIndices = try? await store.loadTextIndices() {
                    textIndices = restoredIndices
                }
                if let restoredOCR = try? await store.loadOCRResults() {
                    ocrResults = restoredOCR
                }
                rebuildSearchCorpora()
                sortDocuments()
            }
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
        do {
            try await store.permanentlyDelete(record)
            deletedDocuments.removeAll { $0.id == recordID }
            noticeMessage = "Item permanently deleted".localizedUI
        } catch {
            present(error)
        }
    }

    func emptyTrash() async {
        let records = deletedDocuments
        guard !records.isEmpty else { return }
        var deletedCount = 0
        do {
            for record in records {
                try await store.permanentlyDelete(record)
                deletedDocuments.removeAll { $0.id == record.id }
                deletedCount += 1
            }
            noticeMessage = "Trash emptied".localizedUI
        } catch {
            if deletedCount > 0 {
                noticeMessage = AppLocalization.format(
                    "%lld Trash item%@ deleted before the operation stopped",
                    deletedCount,
                    deletedCount == 1 ? "" : "s"
                )
            }
            present(error)
        }
    }

    func eraseAllLocalData() async {
        isImporting = true
        defer { isImporting = false }
        deferredBootstrapTask?.cancel()
        deferredBootstrapTask = nil
        officeProductionTask?.cancel()
        officeProductionTask = nil
        officeResourceMonitorTask?.cancel()
        officeResourceMonitorTask = nil
        do {
            try await store.eraseAllData()
            try? await signatureStore.remove()
            metadataSyncService.clearLocalMetadata()
            if let metadataSyncObserver {
                NotificationCenter.default.removeObserver(
                    metadataSyncObserver
                )
                self.metadataSyncObserver = nil
            }
            metadataSyncTask?.cancel()
            metadataSyncTask = nil
            UserDefaults.standard.set(
                false,
                forKey: AppPreferences.metadataSyncEnabledKey
            )
            UserDefaults.standard.set(
                false,
                forKey: AppPreferences.dueRemindersEnabledKey
            )
            LocalDueReminderScheduler.disableAll()
            try? ExternalPDFInbox.removeAll()
            await discardInterruptedTemporaryFiles()
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
            ocrResults = [:]
            textIndices = [:]
            processingDocumentIDs = []
            deliveryProcessingDocumentIDs = []
            batchDeliveryPendingDocumentIDs = []
            operationProgress = [:]
            savedSignatureData = nil
            savedSignatures = []
            selectedSignatureID = nil
            lastBatchDeliveryRun = nil
            batesBatchReceipts = []
            searchMetadataCorpora = [:]
            releaseSearchTextCorpora()
            deliveryPreflightCache = [:]
            pageMutationUndos = [:]
            metadataSyncStatus = metadataSyncDisabledStatus
            noticeMessage = "All local PaperPath data deleted".localizedUI
        } catch {
            present(error)
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
        do {
            let purgedIDs = try await store.purgeDeleted(
                before: cutoff
            )
            guard !purgedIDs.isEmpty else { return }
            let purged = Set(purgedIDs)
            deletedDocuments.removeAll { purged.contains($0.id) }
            if showNotice {
                noticeMessage =
                    "\(purgedIDs.count) expired Trash item\(purgedIDs.count == 1 ? "" : "s") deleted"
            }
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
            return true
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
        } catch {
            present(error)
            return []
        }
    }

    func deliveryMilestoneEvidence(
        recordID: UUID,
        receiptID: UUID
    ) async -> PDFDeliveryMilestoneEvidence {
        guard let record = record(id: recordID),
              let receipt = record.deliveryReceipt,
              receipt.id == receiptID,
              receipt.isVerified
        else { return .unavailable }
        do {
            let matching = try await store.versions(for: recordID)
                .filter { $0.matchesDeliveryReceipt(receipt) }
            let linked = matching.filter {
                $0.linkedDeliveryReceiptID == receiptID
                    && (
                        $0.isPinnedMilestone
                            || $0.resolvedMilestoneName != nil
                    )
            }
            .sorted { $0.createdAt > $1.createdAt }
            let availability: PDFDeliveryMilestoneAvailability
            if !linked.isEmpty {
                availability = .linked
            } else if record.hasCurrentDeliveryReceipt {
                availability = .protectCurrent
            } else if !matching.isEmpty {
                availability = .protectRecovery
            } else {
                availability = .unavailable
            }
            return PDFDeliveryMilestoneEvidence(
                availability: availability,
                linkedMilestones: linked
            )
        } catch {
            present(error)
            return .unavailable
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
            return milestone
        } catch {
            present(error)
            return nil
        }
    }

    func pinnedVersionMilestones() async -> [PDFVersionSnapshot] {
        do {
            return try await store.pinnedVersionMilestones()
        } catch {
            present(error)
            return []
        }
    }

    func unpinAllVersionMilestones() async {
        do {
            let count = try await store.unpinAllVersionMilestones()
            noticeMessage = AppLocalization.format(
                "%lld milestone%@ returned to standard retention",
                count,
                count == 1 ? "" : "s"
            )
        } catch {
            present(error)
        }
    }

    func setVersionMilestonePinned(
        _ milestone: PDFVersionSnapshot,
        pinned: Bool
    ) async {
        do {
            _ = try await store.updateVersionMilestone(
                snapshotID: milestone.id,
                recordID: milestone.documentID,
                name: milestone.milestoneName,
                pinned: pinned,
                linkedDeliveryReceiptID:
                    milestone.linkedDeliveryReceiptID
            )
            noticeMessage = pinned
                ? "Milestone version protected".localizedUI
                : "Milestone returned to standard retention".localizedUI
        } catch {
            present(error)
        }
    }

    func makePinnedVersionArchive(
        recordID: UUID? = nil
    ) async -> URL? {
        do {
            let allMilestones = try await store
                .pinnedVersionMilestones()
            let milestones = allMilestones.filter {
                recordID == nil || $0.documentID == recordID
            }
            guard !milestones.isEmpty else {
                throw PaperPathError.insufficientSelection(
                    "Pin at least one version milestone before archiving."
                )
            }
            let archiveBytes = milestones.reduce(Int64(0)) {
                $0 + max(0, $1.byteCount)
            }
            if let available = try await store
                .availableCapacityForOfficeProduction(),
               available < archiveBytes + 16 * 1_024 * 1_024 {
                throw PaperPathError.insufficientStorage
            }

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
                        String(milestone.id.uuidString.prefix(8))
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

                let manifest = PDFVersionArchiveManifest(
                    schema: "PaperPath Version Archive V49",
                    createdAt: Date(),
                    entries: entries
                )
                let signedManifest = try await store
                    .signVersionArchiveManifest(manifest)
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
                    )
                }
                try await withTaskCancellationHandler {
                    try await archiveTask.value
                } onCancel: {
                    archiveTask.cancel()
                }
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
                try? FileManager.default.removeItem(at: manifestURL)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func verifyPinnedVersionArchive(
        at sourceURL: URL
    ) async -> PDFVersionArchiveVerificationReport? {
        let hasScopedAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try PDFVersionArchiveVerificationService().verify(
                    archiveURL: sourceURL
                )
            }
            let rawReport = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            let resolvedReport = try await store
                .resolveVersionArchiveTrust(rawReport)
            officeTrustedSigners = (
                try? await store.loadOfficeTrustedSigners()
            ) ?? officeTrustedSigners
            return resolvedReport
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
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
        progress: @escaping @MainActor @Sendable (
            PDFByteProgressUpdate
        ) -> Void
    ) async -> PDFDeliveryPackageVerificationReport? {
        let hasScopedAccess =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try PDFVersionArchiveVerificationService()
                    .verifyDeliveryPackage(
                        archiveURL: sourceURL
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
            let resolvedReport = try await store
                .resolveDeliveryPackageTrust(rawReport)
            officeTrustedSigners = (
                try? await store.loadOfficeTrustedSigners()
            ) ?? officeTrustedSigners
            if resolvedReport.status == .verified {
                noticeMessage =
                    "Delivery package verified on this device".localizedUI
            }
            return resolvedReport
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
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
        do {
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
            let versions = try await store.updateVersionMilestone(
                snapshotID: snapshotID,
                recordID: recordID,
                name: name,
                pinned: pinned,
                linkedDeliveryReceiptID: linkedReceiptID
            )
            noticeMessage = pinned
                ? "Milestone version protected".localizedUI
                : "Version details updated".localizedUI
            return versions
        } catch {
            present(error)
            return nil
        }
    }

    func compareVersion(
        recordID: UUID,
        snapshotID: UUID
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
        if let cached = versionComparisonCache[key] {
            touchVersionComparisonCache(key)
            return cached
        }
        let historicalURL = try await store.versionFileURL(
            snapshotID: snapshotID,
            recordID: recordID
        )
        let service = deliveryAuditService
        let task = Task.detached(
            priority: .userInitiated
        ) {
            try service.compare(
                sourceURL: historicalURL,
                revisedURL: currentURL
            )
        }
        let review = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard record(id: recordID)?.contentRevisionID
                == currentRecord.contentRevisionID
        else {
            throw CancellationError()
        }
        versionComparisonCache[key] = review
        touchVersionComparisonCache(key)
        while versionComparisonCacheOrder.count > 4 {
            let oldest = versionComparisonCacheOrder.removeFirst()
            versionComparisonCache[oldest] = nil
        }
        return review
    }

    private func touchVersionComparisonCache(
        _ key: PDFVersionComparisonCacheKey
    ) {
        versionComparisonCacheOrder.removeAll { $0 == key }
        versionComparisonCacheOrder.append(key)
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
            let currentVersion = try await store.createVersionSnapshot(
                for: record,
                label: "Restore version".localizedUI,
                preservingVersionID: snapshotID
            )
            let restored = try await store.restoreVersion(
                snapshotID: snapshotID,
                for: record
            )
            try? await store.enforceVersionRetention(
                preserving: currentVersion.id
            )
            replace(restored)
            textIndices[recordID] = nil
            ocrResults[recordID] = nil
            refreshTokens[recordID, default: 0] += 1
            if let undo = pageMutationUndos.removeValue(
                forKey: recordID
            ) {
                try? FileManager.default.removeItem(
                    at: undo.backupURL
                )
            }
            await analyzeDocument(recordID: recordID)
            noticeMessage = "Version restored · current state saved"
                .localizedUI
            return true
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
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
        }
        do {
            let result = try await ocrService.recognize(
                url: url,
                configuration: configuration
            ) { [weak self] value in
                Task { @MainActor [weak self] in
                    guard self?.exclusiveDocumentOperations[recordID]
                        == operationToken
                    else { return }
                    self?.operationProgress[recordID]
                        = PDFOperationProgress(
                            label: "Recognizing text".localizedUI,
                            fractionCompleted: value
                        )
                }
            }
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
            let (index, brief) = try await valuePropagatingCancellation(
                from: analysisTask
            )
            try Task.checkCancellation()
            guard let currentRecord = self.record(id: recordID),
                  currentRecord.contentRevisionID
                    == record.contentRevisionID
            else {
                throw CancellationError()
            }
            let updated = try await store.saveAnalysis(
                currentRecord,
                brief: brief,
                textIndex: index,
                ocrResult: result
            )
            let completed = try await store.setActionCompletion(
                updated,
                action: .recognizeText,
                completed: true
            )
            ocrResults[recordID] = result
            textIndices[recordID] = index
            replace(completed)
            noticeMessage = result.text.isEmpty
                ? "No readable text found"
                : "Text indexed on device"
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func correctRecognizedText(
        recordID: UUID,
        pageIndex: Int,
        blockID: UUID,
        replacement: String
    ) async -> Bool {
        let normalized = replacement
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 500,
              let record = record(id: recordID),
              let result = ocrResults[recordID],
              let pageOffset = result.pages.firstIndex(where: {
                  $0.pageIndex == pageIndex
              }),
              let blockOffset = result.pages[pageOffset]
                .blocks.firstIndex(where: {
                    $0.id == blockID
                })
        else { return false }

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
            let (index, brief) = try await valuePropagatingCancellation(
                from: analysisTask
            )
            try Task.checkCancellation()
            guard let currentRecord = self.record(id: recordID),
                  currentRecord.contentRevisionID
                    == record.contentRevisionID
            else {
                throw CancellationError()
            }
            let updated = try await store.saveAnalysis(
                currentRecord,
                brief: brief,
                textIndex: index,
                ocrResult: updatedResult
            )
            ocrResults[recordID] = updatedResult
            textIndices[recordID] = index
            replace(updated)
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
        let records = recordIDs.compactMap(record(id:))
        let urls = records.compactMap { documentURLs[$0.id] }
        guard records.count >= 2, urls.count == records.count else {
            present(
                PaperPathError.insufficientSelection(
                    "Choose at least two available PDFs to combine."
                )
            )
            return nil
        }

        isImporting = true
        defer { isImporting = false }
        let temporaryURL = temporaryPDFURL(prefix: "Combined")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let service = compositionService
            let combineTask = Task.detached(priority: .userInitiated) {
                try service.combine(urls: urls, to: temporaryURL)
            }
            try await valuePropagatingCancellation(from: combineTask)
            try Task.checkCancellation()
            guard records.allSatisfy({
                self.record(id: $0.id)?.contentRevisionID
                    == $0.contentRevisionID
            }) else {
                throw CancellationError()
            }
            let fallback = "\(records.first?.displayName ?? "Combined") + \(records.count - 1)"
            let created = try await importSinglePDF(
                from: temporaryURL,
                preferredName: name.isEmpty ? fallback : name
            )
            noticeMessage = AppLocalization.format(
                "%lld PDFs combined locally",
                records.count
            )
            return created
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func extractPages(
        recordID: UUID,
        indices: Set<Int>
    ) async -> DocumentRecord? {
        guard let record = record(id: recordID),
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
        let temporaryURL = temporaryPDFURL(prefix: "Extracted")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let service = compositionService
            let selectedIndices = indices.sorted()
            let task = Task.detached(priority: .userInitiated) {
                try service.extractPages(
                    from: sourceURL,
                    indices: selectedIndices,
                    to: temporaryURL
                )
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            let created = try await importSinglePDF(
                from: temporaryURL,
                preferredName: "\(record.displayName) - pages"
            )
            noticeMessage = AppLocalization.format(
                "%lld page%@ extracted",
                selectedIndices.count,
                selectedIndices.count == 1 ? "" : "s"
            )
            return created
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createSearchableCopy(recordID: UUID) async -> DocumentRecord? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID],
              let result = ocrResults[recordID]
        else {
            present(PaperPathError.missingRecognizedText)
            return nil
        }
        guard let operationToken = acquireExclusiveDocumentOperation(
            recordID: recordID
        ) else { return nil }

        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }
        let temporaryURL = temporaryPDFURL(prefix: "Searchable")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let service = searchablePDFService
            let task = Task.detached(priority: .userInitiated) {
                try service.createSearchableCopy(
                    sourceURL: sourceURL,
                    ocrResult: result,
                    destination: temporaryURL
                )
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            let created = try await importSinglePDF(
                from: temporaryURL,
                preferredName: "\(record.displayName) - searchable"
            )
            await markSourceCompleted(
                recordID: recordID,
                action: .makeSearchable,
                marksReady: false
            )
            noticeMessage = "Searchable PDF copy created".localizedUI
            return created
        } catch is CancellationError {
            return nil
        } catch {
            present(error)
            return nil
        }
    }

    func createCompressedCopy(
        recordID: UUID,
        quality: PDFCompressionQuality,
        presentsFeedback: Bool = true,
        onFailure: ((PDFBatchDeliveryIssue) -> Void)? = nil
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "compressed",
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
        quality: PDFCompressionQuality
    ) async throws -> PDFCompressionEstimate {
        guard let sourceURL = documentURLs[recordID] else {
            throw PaperPathError.unreadablePDF
        }
        let service = outputService
        let task = Task.detached(priority: .utility) {
            try service.estimateCompression(
                sourceURL: sourceURL,
                quality: quality
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func deliveryPreflight(
        recordID: UUID
    ) async throws -> PDFDeliveryPreflightAssessment {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        if let cached = deliveryPreflightCache[recordID],
           cached.revisionID == record.contentRevisionID {
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
        if self.record(id: recordID)?.contentRevisionID
            == record.contentRevisionID {
            let entry = PDFDeliveryPreflightCacheEntry(
                recordID: recordID,
                revisionID: record.contentRevisionID,
                checkedAt: Date(),
                assessment: assessment
            )
            deliveryPreflightCache[recordID] = entry
            try? await store.saveDeliveryPreflight(entry)
        }
        return assessment
    }

    func createRedactedCopy(
        recordID: UUID,
        marks: [PDFRedactionMark]
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "redacted",
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
        permissions: PDFProtectionPermissions = .restricted
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "protected",
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
        password: String
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "editable",
            notice: "Editable private copy created and checked",
            operationKind: .unlocked,
            unlockPassword: password
        ) { [outputService] source, destination, progress in
            try outputService.removePassword(
                sourceURL: source,
                destination: destination,
                password: password,
                progress: progress
            )
        }
    }

    func createFlattenedCopy(recordID: UUID) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "flattened",
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
        options: PDFPrintPreparationOptions
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "print-ready",
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
        options: PDFBookletOptions
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "booklet",
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
        overlays: [PDFContentOverlay]
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "edited",
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
        mutation: PDFLinkMutation
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "links-edited",
            notice: "Link-edited copy created and verified",
            operationKind: .edited
        ) { [outputService] source, destination, progress in
            try outputService.editLink(
                sourceURL: source,
                destination: destination,
                mutation: mutation,
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
        replacementData: Data
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "image-replaced",
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
        recordID: UUID
    ) async -> DocumentRecord? {
        guard let pages = record(id: recordID)?
            .bookmarkedPages,
              !pages.isEmpty
        else {
            noticeMessage = "Bookmark at least one page first".localizedUI
            return nil
        }
        return await createOutputCopy(
            recordID: recordID,
            outputName: "outlined",
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
        rules: [PDFPageLabelRule]
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "page-labeled",
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
        alignment: PDFTextReplacementAlignment
    ) async -> PDFTextReplacementAssessment {
        guard let sourceURL = documentURLs[recordID] else {
            return PDFTextReplacementAssessment(
                status: .blocked,
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
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            return PDFTextReplacementAssessment(
                status: .blocked,
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
                status: .blocked,
                title: "Cannot inspect selection",
                detail: error.localizedDescription,
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
        assessment: PDFTextReplacementAssessment
    ) async -> DocumentRecord? {
        await createOutputCopy(
            recordID: recordID,
            outputName: "text-replaced",
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
        presentsFeedback: Bool = true,
        onFailure: ((PDFBatchDeliveryIssue) -> Void)? = nil,
        bypassesEntitlement: Bool = false
    ) async -> DocumentRecord? {
        guard bypassesEntitlement
                || isRunningAutomatedTests
                || AppEntitlement.canCreateSingleVerifiedOutput
        else {
            isPresentingFullUnlock = true
            return nil
        }
        let created = await createOutputCopy(
            recordID: recordID,
            outputName: "verified",
            notice: "Verified copy created and checked",
            operationKind: .safeShare,
            completesAction: .safeShare,
            marksSourceReady: true,
            presentsFeedback: presentsFeedback,
            onFailure: onFailure
        ) { [outputService] source, destination, progress in
            try outputService.safeShare(
                sourceURL: source,
                destination: destination,
                progress: progress
            )
        }
        if created != nil {
            verifiedOutputSuccessCount =
                AppEntitlement.recordVerifiedOutput()
        } else {
            AppEntitlement.recordVerifiedFailure()
        }
        return created
    }

    func createSafeShareBatch(
        recordIDs: [UUID],
        onUpdate: @escaping (PDFBatchDeliveryItem) -> Void
    ) async -> [PDFBatchDeliveryItem] {
        var seen = Set<UUID>()
        let sourceIDs = recordIDs.filter { seen.insert($0).inserted }
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
        guard isRunningAutomatedTests || AppEntitlement.isUnlocked
        else {
            isPresentingFullUnlock = true
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
            if let blocked = assessment.items.first(
                where: { $0.status == .blocked }
            ) {
                let issue = PDFBatchDeliveryIssue.blocked(
                    blocked.detail
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: outcome.recordID,
                        stage: .blocked,
                        detail: blocked.detail,
                        issue: issue
                    )
                )
                return
            }
            if let review = assessment.items.first(
                where: {
                    $0.status == .review
                        && $0.reviewPageIndex != nil
                }
            ) {
                let issue = PDFBatchDeliveryIssue.review(
                    review.detail
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: outcome.recordID,
                        stage: .needsReview,
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

            if let blocked = assessment.items.first(
                where: { $0.status == .blocked }
            ) {
                let issue = PDFBatchDeliveryIssue.blocked(
                    blocked.detail
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .blocked,
                        detail: blocked.detail,
                        issue: issue
                    )
                )
                continue
            }

            if let pageReview = assessment.items.first(
                where: {
                    $0.status == .review
                        && $0.reviewPageIndex != nil
                }
            ) {
                let issue = PDFBatchDeliveryIssue.review(
                    pageReview.detail
                )
                publish(
                    PDFBatchDeliveryItem(
                        sourceRecordID: sourceID,
                        stage: .needsReview,
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

            var creationIssue: PDFBatchDeliveryIssue?
            let output = await createSafeShareCopy(
                recordID: sourceID,
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

    func saveBatchDeliveryRun(
        id: UUID,
        sourceRecordIDs: [UUID],
        items: [PDFBatchDeliveryItem],
        startedAt: Date
    ) async {
        var seen = Set<UUID>()
        let validSourceIDs = sourceRecordIDs.filter { recordID in
            guard seen.insert(recordID).inserted,
                  let source = record(id: recordID)
            else { return false }
            return source.isWorkingCopy
                && !source.profile.isLocked
                && documentURLs[recordID] != nil
        }
        guard !validSourceIDs.isEmpty else {
            await clearBatchDeliveryRun()
            return
        }
        let revisions = Dictionary(
            validSourceIDs.compactMap {
                recordID -> (UUID, UUID)? in
                guard let revisionID = record(id: recordID)?
                    .contentRevisionID
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
            startedAt: startedAt,
            updatedAt: Date(),
            sourceRecordIDs: validSourceIDs,
            sourceRevisionIDs: revisions,
            items: validSourceIDs.compactMap { itemByID[$0] }
        )
        lastBatchDeliveryRun = run
        try? await store.saveBatchDeliveryRun(run)
    }

    func clearBatchDeliveryRun() async {
        lastBatchDeliveryRun = nil
        await store.clearBatchDeliveryRun()
    }

    func currentBatchDeliveryRun() -> PDFBatchDeliveryRun? {
        guard let run = lastBatchDeliveryRun else { return nil }
        let validIDs = run.sourceRecordIDs.filter { recordID in
            guard let current = documentRecordsByID[recordID],
                  let revisionID = run.sourceRevisionIDs[recordID],
                  current.isWorkingCopy,
                  !current.profile.isLocked,
                  documentURLs[recordID] != nil
            else { return false }
            return current.contentRevisionID == revisionID
        }
        let validIDSet = Set(validIDs)
        let itemByID = Dictionary(
            run.items.map {
                ($0.sourceRecordID, $0)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let validItems = validIDs.map { recordID in
            let item = itemByID[recordID] ?? PDFBatchDeliveryItem(
                sourceRecordID: recordID,
                stage: .stopped,
                detail: PDFBatchDeliveryIssue.cancelled.message,
                issue: .cancelled
            )
            if !item.stage.isFinal,
               !batchDeliveryPendingDocumentIDs.contains(recordID) {
                return PDFBatchDeliveryItem(
                    sourceRecordID: recordID,
                    stage: .stopped,
                    detail: PDFBatchDeliveryIssue.cancelled.message,
                    issue: .cancelled
                )
            }
            if item.stage.isShareable,
               let output = verifiedShareTarget(for: recordID) {
                return PDFBatchDeliveryItem(
                    sourceRecordID: recordID,
                    outputRecordID: output.id,
                    stage: item.outputRecordID == output.id
                        ? item.stage
                        : .reused,
                    detail: item.outputRecordID == output.id
                        ? item.detail
                        : "Current verified copy reused"
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
               cached.revisionID == record.contentRevisionID {
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
            try? await store.saveDeliveryPreflight(entry)
        }
        return outcomes
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
                    error.localizedDescription
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
        format: PDFTextExportFormat = .plainText
    ) async throws -> PDFTextExportArtifact {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else {
            throw PaperPathError.unreadablePDF
        }
        if format.isOfficeFormat {
            try await validateOfficeProductionResources(
                recordID: recordID,
                format: format
            )
        }

        let requestedRevision = record.contentRevisionID
        let operationToken = try beginExclusiveDocumentOperation(
            recordID: recordID
        )
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
        }

        let officeContainer = format.isOfficeFormat
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "PaperPath-Office-Export-\(UUID().uuidString)",
                    isDirectory: true
                )
            : nil
        let destinationRoot = officeContainer
            ?? FileManager.default.temporaryDirectory
        let destination = destinationRoot
            .appendingPathComponent(
                "\(safeExportName(record.displayName))-\(UUID().uuidString).\(format.fileExtension)"
            )
        let label = "Exporting \(format.title.lowercased())"
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
            if let officeContainer {
                try LocalFileSecurity.prepareProtectedDirectory(
                    at: officeContainer
                )
            }
            let service = outputService
            let textIndex = textIndices[recordID]
            let task = Task.detached(priority: .userInitiated) {
                try service.exportText(
                    sourceURL: sourceURL,
                    destination: destination,
                    textIndex: textIndex,
                    title: record.displayName,
                    format: format,
                    profile: record.profile,
                    byteProgress: { update in
                        Task { @MainActor [weak self] in
                            guard self?.operationProgress[recordID]?
                                .label == label
                            else { return }
                            self?.publishOperationByteProgress(
                                recordID: recordID,
                                label: label,
                                update: update
                            )
                        }
                    }
                ) { value in
                    Task { @MainActor [weak self] in
                        guard self?.operationProgress[recordID]?.label
                            == label
                        else { return }
                        self?.updateOperationFraction(
                            recordID: recordID,
                            label: label,
                            fractionCompleted: value
                        )
                    }
                }
            }
            let evidence = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                == requestedRevision
            else {
                try? FileManager.default.removeItem(at: destination)
                throw PaperPathError.outputVerificationFailed(
                    "the source changed during export"
                )
            }
            let outputValues = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard outputValues.isRegularFile == true,
                  (outputValues.fileSize ?? 0) > 0
            else {
                throw PaperPathError.outputVerificationFailed(
                    "the generated file is empty"
                )
            }
            if format.isOfficeFormat {
                try LocalFileSecurity.requireCompleteProtection(
                    to: destination
                )
            }
            return PDFTextExportArtifact(
                url: destination,
                runtimeEvidence: evidence
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(
                at: officeContainer ?? destination
            )
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(
                at: officeContainer ?? destination
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
        format: PDFTextExportFormat
    ) async throws -> PDFOfficeBatchRun? {
        guard let record = record(id: recordID),
              format.isOfficeFormat
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
            selectedSegmentIDs: Set(plan.segments.map(\.id))
        )
    }

    func resumeOfficeBatch(
        recordID: UUID,
        selectedSegmentIDs: Set<UUID>? = nil
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
            selectedSegmentIDs: selected
        )
    }

    private func executeOfficeBatch(
        recordID: UUID,
        run initialRun: PDFOfficeBatchRun,
        selectedSegmentIDs: Set<UUID>
    ) async throws -> PDFOfficeBatchRun? {
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
        let operationLabel =
            "Exporting \(format.fileExtension.uppercased()) batch"
        let operationToken = try beginExclusiveDocumentOperation(
            recordID: recordID
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
        defer {
            finishExclusiveDocumentOperation(
                recordID: recordID,
                token: operationToken
            )
            operationProgress[recordID] = nil
            operationRateWindows[recordID] = nil
        }

        let service = outputService
        let composition = compositionService
        let sourceTextIndex = textIndices[recordID]

        do {
            for segment in plan.segments
                where selectedSegmentIDs.contains(segment.id) {
                try Task.checkCancellation()
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
                    try await withTaskCancellationHandler {
                        try await extractionTask.value
                    } onCancel: {
                        extractionTask.cancel()
                    }
                    try Task.checkCancellation()
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
                        try await withTaskCancellationHandler {
                            try await inspectionTask.value
                        } onCancel: {
                            inspectionTask.cancel()
                        }
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
                                    self?.publishOperationByteProgress(
                                        recordID: recordID,
                                        label: operationLabel,
                                        update: update
                                    )
                                }
                            }
                        ) { value in
                            Task { @MainActor [weak self] in
                                self?.updateOperationFraction(
                                    recordID: recordID,
                                    label: operationLabel,
                                    fractionCompleted: (
                                        Double(segment.index)
                                            + 0.14 + value * 0.7
                                    ) / Double(
                                        max(1, plan.segmentCount)
                                    )
                                )
                                self?.updateOfficeBatchSegment(
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
                        try await withTaskCancellationHandler {
                            try await exportTask.value
                        } onCancel: {
                            exportTask.cancel()
                        }
                    try Task.checkCancellation()
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
                        sourceURL: outputURL
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    updateOfficeBatchSegment(
                        recordID: recordID,
                        batchID: plan.id,
                        segmentIndex: segment.index,
                        status: .failed,
                        fractionCompleted: 1,
                        failureDetail: error.localizedDescription
                    )
                    await persistOfficeBatchRun(recordID: recordID)
                }
            }

            finishOfficeBatch(recordID: recordID, batchID: plan.id)
            await persistOfficeBatchRun(recordID: recordID)
            return officeBatchRuns[recordID]
        } catch is CancellationError {
            cancelOfficeBatch(
                recordID: recordID,
                batchID: plan.id,
                selectedSegmentIDs: selectedSegmentIDs
            )
            await persistOfficeBatchRun(recordID: recordID)
            return officeBatchRuns[recordID]
        } catch {
            failOfficeBatch(
                recordID: recordID,
                batchID: plan.id,
                detail: error.localizedDescription
            )
            await persistOfficeBatchRun(recordID: recordID)
            return officeBatchRuns[recordID]
        }
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
              run.segments.indices.contains(segmentIndex)
        else { return }
        run.status = .running
        run.segments[segmentIndex].status = status
        run.segments[segmentIndex].fractionCompleted = min(
            1,
            max(0, fractionCompleted)
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
        run.completedAt = Date()
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
        run.completedAt = Date()
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
        run.completedAt = Date()
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
                        currentRevisionID: record.contentRevisionID
                    )
                )
            },
            uniquingKeysWith: { _, newest in newest }
        )
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
        let label = "Exporting \(preset.title.lowercased())"
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
                        guard self?.exclusiveDocumentOperations[recordID]
                            == operationToken
                        else { return }
                        self?.operationProgress[recordID]
                            = PDFOperationProgress(
                                label: label,
                                fractionCompleted: value
                            )
                    }
                }
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            return []
        } catch {
            try? FileManager.default.removeItem(at: directory)
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
        let label = "Exporting embedded images"
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
                        guard self?.exclusiveDocumentOperations[recordID]
                            == operationToken
                        else { return }
                        self?.operationProgress[recordID]
                            = PDFOperationProgress(
                                label: label,
                                fractionCompleted: value
                            )
                    }
                }
            }
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let duplicateCount = max(
                0,
                result.occurrenceCount
                    - result.unsupportedOccurrenceCount
                    - result.uniqueImageCount
            )
            let kindSummary =
                "\(result.originalStreamFileCount) original, \(result.losslessPNGFileCount) lossless PNG"
            if result.unsupportedOccurrenceCount > 0 {
                noticeMessage =
                    "Exported \(result.uniqueImageCount) image\(result.uniqueImageCount == 1 ? "" : "s") (\(kindSummary)); \(result.unsupportedOccurrenceCount) unsupported use\(result.unsupportedOccurrenceCount == 1 ? "" : "s") skipped"
            } else if duplicateCount > 0 {
                noticeMessage =
                    "Exported \(result.uniqueImageCount) image\(result.uniqueImageCount == 1 ? "" : "s") (\(kindSummary)); \(duplicateCount) repeated use\(duplicateCount == 1 ? "" : "s") deduplicated"
            } else {
                noticeMessage =
                    "Exported \(result.uniqueImageCount) image\(result.uniqueImageCount == 1 ? "" : "s") (\(kindSummary))"
            }
            return result.urls
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            return []
        } catch {
            try? FileManager.default.removeItem(at: directory)
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
        guard let record = record(id: recordID),
              !indices.isEmpty
        else { return false }
        let sorted = indices.sorted()
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: sorted.count == 1
                ? "Duplicate page".localizedUI
                : AppLocalization.format(
                    "Duplicate %lld pages",
                    sorted.count
                )
        ) { service, url in
            try service.duplicatePages(at: sorted, in: url)
        }
        guard succeeded else { return false }

        func shiftedOriginalPage(_ page: Int) -> Int {
            page + sorted.prefix { $0 < page }.count
        }
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.map(shiftedOriginalPage)
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint,
            transform: shiftedOriginalPage
        )
        return true
    }

    func deletePage(recordID: UUID, index: Int) async {
        guard let record = record(id: recordID) else { return }
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Remove page".localizedUI
        ) { service, url in
            try service.deletePage(at: index, in: url)
        }
        guard succeeded else { return }
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.compactMap { page in
                if page == index { return nil }
                return page > index ? page - 1 : page
            }
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint
        ) { page in
            if page == index { return nil }
            return page > index ? page - 1 : page
        }
    }

    func deletePages(
        recordID: UUID,
        indices: Set<Int>
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        let sorted = indices.sorted()
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Remove %lld pages",
                indices.count
            )
        ) { service, url in
            try service.deletePages(at: sorted, in: url)
        }
        guard succeeded else { return false }
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.compactMap { bookmark in
                guard !indices.contains(bookmark) else { return nil }
                let removedBefore = sorted.prefix {
                    $0 < bookmark
                }.count
                return bookmark - removedBefore
            }
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint
        ) { page in
            guard !indices.contains(page) else { return nil }
            let removedBefore = sorted.prefix { $0 < page }.count
            return page - removedBefore
        }
        return true
    }

    func movePage(
        recordID: UUID,
        index: Int,
        direction: PDFMutationService.MoveDirection
    ) async {
        guard let record = record(id: recordID) else { return }
        let target = direction == .earlier ? index - 1 : index + 1
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Move page".localizedUI
        ) { service, url in
            try service.movePage(at: index, direction: direction, in: url)
        }
        guard succeeded else { return }
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.map { page in
                if page == index { return target }
                if page == target { return index }
                return page
            }
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint
        ) { page in
            if page == index { return target }
            if page == target { return index }
            return page
        }
    }

    func movePage(
        recordID: UUID,
        from sourceIndex: Int,
        to destinationIndex: Int
    ) async {
        guard sourceIndex != destinationIndex,
              let record = record(id: recordID)
        else { return }
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Reorder pages".localizedUI
        ) { service, url in
            try service.movePage(
                from: sourceIndex,
                to: destinationIndex,
                in: url
            )
        }
        guard succeeded else { return }
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.map { page in
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
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint
        ) { page in
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
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: label
        ) { service, url in
            try service.reorderPages(order: order, in: url)
        }
        guard succeeded else { return false }
        let destinationBySource = Dictionary(
            order.enumerated().map {
                destination,
                source in
                (source, destination)
            },
            uniquingKeysWith: { current, _ in current }
        )
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.compactMap {
                destinationBySource[$0]
            }
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint
        ) {
            destinationBySource[$0]
        }
        return true
    }

    func replacePage(
        recordID: UUID,
        index: Int,
        from sourceRecordID: UUID,
        sourceIndex: Int
    ) async -> Bool {
        guard recordID != sourceRecordID,
              let record = record(id: recordID),
              let sourceURL = documentURLs[sourceRecordID]
        else { return false }
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Replace page %lld",
                index + 1
            )
        ) { service, destinationURL in
            try service.replacePage(
                at: index,
                withPageAt: sourceIndex,
                from: sourceURL,
                in: destinationURL
            )
        }
        if succeeded {
            await clearTaskCheckpointIfReplaced(
                recordID: recordID,
                pageIndex: index,
                checkpoint: record.taskCheckpoint
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
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Replacement-\(id.uuidString).pdf"
            )
        do {
            let service = mutationService
            let task = Task.detached(
                priority: .userInitiated
            ) {
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: temporaryURL
                )
                LocalFileSecurity.applyCompleteProtection(
                    to: temporaryURL
                )
                let assessment = try service
                    .pagePreparationAssessment(
                        in: temporaryURL,
                        revisionID: id
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
            try? FileManager.default.removeItem(
                at: temporaryURL
            )
            return nil
        } catch {
            try? FileManager.default.removeItem(
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
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Replacement-\(id.uuidString).pdf"
            )
        do {
            let renderer = scanRenderer
            let assessmentService = mutationService
            let task = Task.detached(
                priority: .userInitiated
            ) {
                try Task.checkCancellation()
                try renderer.render(
                    pages: pages,
                    to: temporaryURL,
                    options: .document
                )
                try Task.checkCancellation()
                LocalFileSecurity.applyCompleteProtection(
                    to: temporaryURL
                )
                let assessment = try assessmentService
                    .pagePreparationAssessment(
                        in: temporaryURL,
                        revisionID: id
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
            try? FileManager.default.removeItem(at: temporaryURL)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            present(error)
            return nil
        }
    }

    func discardExternalPageSource(
        _ source: PDFExternalPageSource
    ) {
        try? FileManager.default.removeItem(at: source.url)
    }

    func replacePage(
        recordID: UUID,
        index: Int,
        from source: PDFExternalPageSource,
        sourceIndex: Int
    ) async -> Bool {
        guard let record = record(id: recordID) else { return false }
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: AppLocalization.format(
                "Replace page %lld",
                index + 1
            )
        ) { service, destinationURL in
            try service.replacePage(
                at: index,
                withPageAt: sourceIndex,
                from: source.url,
                in: destinationURL
            )
        }
        if succeeded {
            await clearTaskCheckpointIfReplaced(
                recordID: recordID,
                pageIndex: index,
                checkpoint: record.taskCheckpoint
            )
        }
        return succeeded
    }

    @discardableResult
    func addInk(
        recordID: UUID,
        payload: PDFInkPayload
    ) async -> Bool {
        let succeeded = await mutate(
            recordID: recordID,
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
            await updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: checkpoint
            )
            noticeMessage = checkpoint.stage == .verify
                ? "Signature added · Verify & Share is ready"
                : "Signature added · \(checkpoint.stage.title)"
        }
        return true
    }

    private func checkpointAfterSignature(
        recordID: UUID,
        signaturePageIndex: Int
    ) async -> DocumentTaskCheckpoint {
        guard let url = documentURLs[recordID] else {
            return DocumentTaskCheckpoint(
                stage: .verify,
                pageIndex: signaturePageIndex
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
                        : nil
                )
            }
            if report.hasXFA {
                return DocumentTaskCheckpoint(stage: .fillForm)
            }
        } catch {
            return DocumentTaskCheckpoint(
                stage: .verify,
                pageIndex: signaturePageIndex
            )
        }
        return DocumentTaskCheckpoint(
            stage: .verify,
            pageIndex: signaturePageIndex
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
        let recordIDs = plan.items.map(\.recordID)
        guard let operationTokens =
                acquireExclusiveDocumentOperations(
                    recordIDs: recordIDs
                )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
            batesBatchProgress = nil
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
                try? FileManager.default.removeItem(
                    at: prepared.preparedURL
                )
            }
            if !keepsBackupsForUndo {
                for backup in backups.values {
                    try? FileManager.default.removeItem(at: backup)
                }
            }
        }

        do {
            var recordsByID: [UUID: DocumentRecord] = [:]
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
                _ = try await store.createVersionSnapshot(
                    for: record,
                    label: label
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
                let backupURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Bates-Undo-\(UUID().uuidString).pdf"
                    )
                let preparedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Bates-Prepared-\(UUID().uuidString).pdf"
                    )
                let payload = plan.payload(for: item)
                let mutationService = self.mutationService
                let preparationTask = Task.detached(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: backupURL
                    )
                    LocalFileSecurity.applyCompleteProtection(
                        to: backupURL
                    )
                    try FileManager.default.copyItem(
                        at: backupURL,
                        to: preparedURL
                    )
                    LocalFileSecurity.applyCompleteProtection(
                        to: preparedURL
                    )
                    try mutationService.applyBatesNumbers(
                        payload,
                        in: preparedURL
                    )
                }
                do {
                    try await valuePropagatingCancellation(
                        from: preparationTask
                    )
                } catch {
                    try? FileManager.default.removeItem(at: backupURL)
                    try? FileManager.default.removeItem(at: preparedURL)
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
                let completedPages = plan.items
                    .prefix(offset + 1)
                    .reduce(0) { $0 + $1.pageCount }
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
            let commit = try await store
                .replaceWorkingCopiesAndCreateBatesReceipt(
                with: preparedCopies,
                plan: plan
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
                    try? FileManager.default.removeItem(
                        at: previous.backupURL
                    )
                }
                if let backup = backups[updated.id],
                   recordsByID[updated.id] != nil {
                    pageMutationUndos[updated.id] = PageMutationUndo(
                        backupURL: backup,
                        bookmarkedPages: updated.bookmarkedPages,
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
                <= PDFBatesBatchPlan.maximumPageCount,
              let operationTokens =
                acquireExclusiveDocumentOperations(
                    recordIDs: recordIDs
                )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
            batesBatchProgress = nil
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
                try? FileManager.default.removeItem(
                    at: prepared.preparedURL
                )
            }
            if !keepsBackupsForUndo {
                for backup in backups.values {
                    try? FileManager.default.removeItem(at: backup)
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
            let verification = try await store
                .verifyBatesBatchReceipt(receipt) { [weak self] progress in
                    self?.batesReceiptVerificationProgress = progress
                }
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
                _ = try await store.createVersionSnapshot(
                    for: record,
                    label: label
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
                let backupURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Bates-Removal-Undo-\(UUID().uuidString).pdf"
                    )
                let preparedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Bates-Removal-\(UUID().uuidString).pdf"
                    )
                let mutationService = self.mutationService
                let preparationTask = Task.detached(
                    priority: .userInitiated
                ) {
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: backupURL
                    )
                    LocalFileSecurity.applyCompleteProtection(
                        to: backupURL
                    )
                    try FileManager.default.copyItem(
                        at: backupURL,
                        to: preparedURL
                    )
                    LocalFileSecurity.applyCompleteProtection(
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
                    try await valuePropagatingCancellation(
                        from: preparationTask
                    )
                } catch {
                    try? FileManager.default.removeItem(at: backupURL)
                    try? FileManager.default.removeItem(at: preparedURL)
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
                completedPages += entry.pageCount
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
            let commit = try await store
                .replaceWorkingCopiesAndCreateBatesRemovalReceipt(
                    with: preparedCopies,
                    receiptID: receiptID
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
                    try? FileManager.default.removeItem(
                        at: previous.backupURL
                    )
                }
                if let backup = backups[updated.id],
                   let original = recordsByID[updated.id] {
                    pageMutationUndos[updated.id] = PageMutationUndo(
                        backupURL: backup,
                        bookmarkedPages: original.bookmarkedPages,
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
            defer {
                if batesReceiptVerificationProgress?.receiptID
                    == receiptID {
                    batesReceiptVerificationProgress = nil
                }
            }
            return try await store.verifyBatesBatchReceipt(
                receipt
            ) { [weak self] progress in
                self?.batesReceiptVerificationProgress = progress
            }
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
            return try await store.exportBatesBatchReceipt(
                receiptID: receiptID
            )
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
        batesReceiptVerificationProgress = nil
        do {
            let inspection = try await store
                .inspectExternalBatesBatchReceipt(
                    at: sourceURL
                ) { [weak self] progress in
                    self?.batesReceiptVerificationProgress =
                        progress
                }
            if batesReceiptVerificationProgress?.receiptID
                == inspection.id {
                batesReceiptVerificationProgress = nil
            }
            return inspection
        } catch is CancellationError {
            batesReceiptVerificationProgress = nil
            return nil
        } catch {
            batesReceiptVerificationProgress = nil
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
        batesExternalMatchProgress = nil
        do {
            let report = try await store.matchExternalBatesPDFs(
                receipt: receipt,
                candidateURLs: candidateURLs
            ) { [weak self] progress in
                self?.batesExternalMatchProgress = progress
            }
            if batesExternalMatchProgress?.receiptID
                == receipt.id {
                batesExternalMatchProgress = nil
            }
            return report
        } catch is CancellationError {
            batesExternalMatchProgress = nil
            return nil
        } catch {
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
            return try await store.exportSignedBatesMatchReport(
                receipt: receipt,
                report: report
            )
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
        payload: PDFFormFieldPayload
    ) async -> Bool {
        let succeeded = await mutate(
            recordID: recordID,
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
        recordID: UUID
    ) async -> Bool {
        let succeeded = await mutate(
            recordID: recordID,
            invalidatesAnalysis: false,
            snapshotLabel: "Refresh form calculations".localizedUI
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
        let bookmarks = record.bookmarkedPages
        let succeeded = await performPageMutation(
            recordID: recordID,
            label: "Insert page".localizedUI
        ) { service, url in
            try service.insertBlankPage(
                at: insertionIndex,
                in: url
            )
        }
        guard succeeded else { return }
        await replaceBookmarks(
            recordID: recordID,
            pages: bookmarks.map {
                $0 >= insertionIndex ? $0 + 1 : $0
            }
        )
        await remapTaskCheckpoint(
            recordID: recordID,
            checkpoint: record.taskCheckpoint
        ) {
            $0 >= insertionIndex ? $0 + 1 : $0
        }
    }

    func insertBlankPage(recordID: UUID, after index: Int) async {
        await insertBlankPage(
            recordID: recordID,
            at: index + 1
        )
    }

    func appendPages(recordID: UUID, from sourceURL: URL) async {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        _ = await performPageMutation(
            recordID: recordID,
            label: "Add pages".localizedUI
        ) { service, url in
            try service.appendPages(from: sourceURL, in: url)
        }
    }

    func copyPages(
        from sourceRecordID: UUID,
        indices: Set<Int>,
        to destinationRecordID: UUID
    ) async -> Bool {
        guard sourceRecordID != destinationRecordID,
              let sourceURL = documentURLs[sourceRecordID],
              !indices.isEmpty
        else { return false }
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
            noticeMessage =
                "\(indices.count) page\(indices.count == 1 ? "" : "s") copied"
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
        pageMutationUndos[recordID] != nil
    }

    func undoLastPageChange(recordID: UUID) async -> Bool {
        guard let undo = pageMutationUndos[recordID],
              let record = record(id: recordID),
              let destination = documentURLs[recordID],
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
                label: AppLocalization.format(
                    "Undo %@",
                    undo.label.localizedUI
                )
            )
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let replacement = destination
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".undo-\(UUID().uuidString).pdf"
                    )
                defer {
                    try? FileManager.default.removeItem(at: replacement)
                }
                try FileManager.default.copyItem(
                    at: undo.backupURL,
                    to: replacement
                )
                try Task.checkCancellation()
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: replacement
                )
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            var refreshed = try await store.refresh(
                record,
                invalidateAnalysis: true
            )
            refreshed = try await store.updateBookmarks(
                refreshed,
                pages: undo.bookmarkedPages
            )
            refreshed = try await store.updateTaskCheckpoint(
                refreshed,
                checkpoint: undo.taskCheckpoint
            )
            replace(refreshed)
            textIndices[recordID] = nil
            ocrResults[recordID] = nil
            refreshTokens[recordID, default: 0] += 1
            pageMutationUndos[recordID] = nil
            try? FileManager.default.removeItem(at: undo.backupURL)
            await analyzeDocument(recordID: recordID)
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
                  let undo = pageMutationUndos[id]
            else { return nil }
            return (record, undo)
        }
        guard entries.count == orderedIDs.count,
              let operationTokens =
                acquireExclusiveDocumentOperations(
                    recordIDs: orderedIDs
                )
        else { return false }
        defer {
            finishExclusiveDocumentOperations(operationTokens)
        }

        do {
            for entry in entries {
                _ = try await store.createVersionSnapshot(
                    for: entry.record,
                    label: AppLocalization.format(
                        "Undo %@",
                        entry.undo.label.localizedUI
                    )
                )
            }
            let prepared = entries.map {
                PreparedPDFWorkingCopy(
                    recordID: $0.record.id,
                    sourceRevisionID:
                        $0.record.contentRevisionID,
                    preparedURL: $0.undo.backupURL
                )
            }
            let restored = try await store.replaceWorkingCopies(
                with: prepared,
                invalidateAnalysis: false
            )
            for record in restored {
                replace(record)
                deliveryPreflightCache[record.id] = nil
                refreshTokens[record.id, default: 0] += 1
                if let undo = pageMutationUndos.removeValue(
                    forKey: record.id
                ) {
                    try? FileManager.default.removeItem(
                        at: undo.backupURL
                    )
                }
            }
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
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return .empty }
        do {
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
                let preserved = try structureService
                    .unsupportedReviewAnnotations(
                        in: url,
                        resultLimit: remaining + 1
                    )
                let combined = (editable + preserved).sorted {
                    if $0.pageIndex != $1.pageIndex {
                        return $0.pageIndex < $1.pageIndex
                    }
                    if $0.canRemove != $1.canRemove {
                        return $0.canRemove
                    }
                    return $0.annotationIndex < $1.annotationIndex
                }
                return PDFAnnotationInventory(
                    annotations: Array(
                        combined.prefix(displayLimit)
                    ),
                    isTruncated: combined.count > displayLimit,
                    displayLimit: displayLimit
                )
            }
            let inventory = try await valuePropagatingCancellation(
                from: task
            )
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else { return .empty }
            return inventory
        } catch is CancellationError {
            return .empty
        } catch {
            present(error)
            return .empty
        }
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
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return [] }
        do {
            let service = documentStructureService
            let task = Task.detached(priority: .utility) {
                try service.attachments(in: url)
            }
            let attachments = try await valuePropagatingCancellation(
                from: task
            )
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else { return [] }
            return attachments
        } catch is CancellationError {
            return []
        } catch {
            present(error)
            return []
        }
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
        attachmentIDs: Set<String>
    ) async -> [URL] {
        guard let sourceURL = documentURLs[recordID],
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
            let urls = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            noticeMessage = urls.count == 1
                ? "Attachment extracted and byte-verified"
                : "\(urls.count) attachments extracted and byte-verified"
            return urls
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            return []
        } catch {
            try? FileManager.default.removeItem(at: directory)
            present(error)
            return []
        }
    }

    func discardAttachmentExportCopies(
        at urls: [URL]
    ) async {
        guard let directory = urls.first?
            .deletingLastPathComponent()
        else { return }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .standardizedFileURL
        guard directory.deletingLastPathComponent()
                .standardizedFileURL == temporaryDirectory,
              directory.lastPathComponent
                .hasPrefix("PaperPath-Attachments-")
        else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    func editAnnotation(
        recordID: UUID,
        payload: PDFAnnotationEditPayload
    ) async -> Bool {
        let succeeded = await performPageMutation(
            recordID: recordID,
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
        annotation: PDFAnnotationSnapshot
    ) async -> Bool {
        await removeAnnotations(
            recordID: recordID,
            annotations: [annotation]
        )
    }

    @discardableResult
    func removeAnnotations(
        recordID: UUID,
        annotations: [PDFAnnotationSnapshot]
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
        completed: Bool
    ) async {
        guard let record = record(id: recordID),
              record.completedActions.contains(action) != completed
        else { return }
        do {
            let updated = try await store.setActionCompletion(
                record,
                action: action,
                completed: completed
            )
            replace(updated)
        } catch {
            present(error)
        }
    }

    func updateTaskCheckpoint(
        recordID: UUID,
        checkpoint: DocumentTaskCheckpoint?
    ) async {
        guard let record = record(id: recordID),
              record.taskCheckpoint != checkpoint
        else { return }
        do {
            let updated = try await store.updateTaskCheckpoint(
                record,
                checkpoint: checkpoint
            )
            replace(updated, schedulesMetadataSync: false)
        } catch {
            present(error)
        }
    }

    func synchronizeCompletionState(recordID: UUID) async {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return }
        let mutationService = self.mutationService
        do {
            let task = Task.detached(priority: .utility) {
                let annotations = try mutationService.annotations(in: url)
                try Task.checkCancellation()
                let hasSignature = annotations.contains {
                    $0.type.caseInsensitiveCompare("ink") == .orderedSame
                        && $0.contents == "Signature"
                }
                let report = try PDFFormInspectionService().inspect(url: url)
                return (
                    hasSignature,
                    report.isReadyForVerifiedOutput
                )
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
            if record.profile.formFieldCount > 0 {
                await setActionCompletion(
                    recordID: recordID,
                    action: .reviewForm,
                    completed: state.1
                )
            }
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
        revisedRecordID: UUID
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
        if let cached = comparisonCache[key] {
            touchComparisonCache(key)
            return cached
        }
        let service = deliveryAuditService
        let task = Task.detached(priority: .userInitiated) {
            try service.compare(
                sourceURL: sourceURL,
                revisedURL: revisedURL
            )
        }
        let review = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard record(id: sourceRecordID)?.contentRevisionID
                == sourceRecord.contentRevisionID,
              record(id: revisedRecordID)?.contentRevisionID
                == revisedRecord.contentRevisionID
        else {
            throw CancellationError()
        }
        comparisonCache[key] = review
        touchComparisonCache(key)
        while comparisonCacheOrder.count > 6 {
            let oldest = comparisonCacheOrder.removeFirst()
            comparisonCache[oldest] = nil
        }
        return review
    }

    private func touchComparisonCache(
        _ key: PDFComparisonCacheKey
    ) {
        comparisonCacheOrder.removeAll { $0 == key }
        comparisonCacheOrder.append(key)
    }

    func makeFilesExportCopy(recordID: UUID) async -> URL? {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-FilesExport-\(UUID().uuidString)",
                isDirectory: true
            )
        let displayName = record.displayName.lowercased()
            .hasSuffix(".pdf")
            ? String(record.displayName.dropLast(4))
            : record.displayName
        let destination = directory
            .appendingPathComponent(
                safeExportName(displayName)
            )
            .appendingPathExtension("pdf")

        do {
            let task = Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                LocalFileSecurity.applyCompleteProtection(
                    to: directory,
                    fileManager: fileManager
                )
                do {
                    try fileManager.copyItem(
                        at: sourceURL,
                        to: destination
                    )
                    LocalFileSecurity.applyCompleteProtection(
                        to: destination,
                        fileManager: fileManager
                    )
                } catch {
                    try? fileManager.removeItem(at: directory)
                    throw error
                }
            }
            try await valuePropagatingCancellation(from: task)
            try Task.checkCancellation()
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            return nil
        } catch {
            present(error)
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
                guard self?.exclusiveDocumentOperations[recordID]
                    == operationToken,
                      self?.operationProgress[recordID]?.label
                        == operationLabel
                else { return }
                let fraction = update.totalBytes > 0
                    ? Double(update.processedBytes)
                        / Double(update.totalBytes)
                    : 0
                self?.updateOperationFraction(
                    recordID: recordID,
                    label: operationLabel,
                    fractionCompleted: min(0.24, max(0, fraction) * 0.24)
                )
                self?.publishOperationByteProgress(
                    recordID: recordID,
                    label: operationLabel,
                    update: update
                )
            }
        }
        let archiveProgress: PDFByteProgressHandler = {
            [weak self] update in
            Task { @MainActor [weak self] in
                guard self?.exclusiveDocumentOperations[recordID]
                    == operationToken,
                      self?.operationProgress[recordID]?.label
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
                self?.updateOperationFraction(
                    recordID: recordID,
                    label: operationLabel,
                    fractionCompleted: completed
                )
                self?.publishOperationByteProgress(
                    recordID: recordID,
                    label: operationLabel,
                    update: update
                )
            }
        }

        do {
            let signedManifest = try await store
                .signedDeliveryPackageManifest(
                    for: record,
                    artifactFileName: artifactName,
                    progress: verificationProgress
                )
            officeDeliverySigningKeyID =
                signedManifest.signature.keyID
            try Task.checkCancellation()
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
            try await withTaskCancellationHandler {
                try await archiveTask.value
            } onCancel: {
                archiveTask.cancel()
            }
            try Task.checkCancellation()
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
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryDirectory = fileManager.temporaryDirectory
            .standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL
                == temporaryDirectory,
              directory.lastPathComponent
                .hasPrefix("PaperPath-FilesExport-")
        else { return }

        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    func discardDeliveryPackage(at url: URL) async {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryDirectory = fileManager.temporaryDirectory
            .standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL
                == temporaryDirectory,
              directory.lastPathComponent
                .hasPrefix("PaperPath-DeliveryPackage-")
        else { return }

        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    private func discardInterruptedTemporaryFiles() async {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let temporaryDirectory = fileManager.temporaryDirectory
            guard let contents = try? fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in contents {
                guard url.lastPathComponent.hasPrefix("PaperPath-")
                else { continue }
                try? fileManager.removeItem(at: url)
            }
        }.value
    }

    func refreshToken(for recordID: UUID) -> Int {
        refreshTokens[recordID, default: 0]
    }

    func isProcessing(_ recordID: UUID) -> Bool {
        processingDocumentIDs.contains(recordID)
            || operationProgress[recordID] != nil
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
              exclusiveDocumentOperations[recordID] == nil
        else {
            throw PaperPathError.insufficientSelection(
                "Another operation is already using this PDF. Wait for it to finish or stop it before trying again."
            )
        }
        let token = UUID()
        exclusiveDocumentOperations[recordID] = token
        processingDocumentIDs.insert(recordID)
        return token
    }

    private func finishExclusiveDocumentOperation(
        recordID: UUID,
        token: UUID
    ) {
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
        let fileManager = FileManager.default
        let parent = artifactURL.deletingLastPathComponent()
            .standardizedFileURL
        let temporaryRoot = fileManager.temporaryDirectory
            .standardizedFileURL
        guard parent.deletingLastPathComponent() == temporaryRoot,
              parent.lastPathComponent.hasPrefix(
                "PaperPath-Office-Export-"
              )
        else { return }
        try? fileManager.removeItem(at: parent)
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
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: min(1, max(0, fractionCompleted)),
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
        if current.byteStage == update.stage,
           update.processedBytes < current.processedBytes {
            return
        }
        var window = operationRateWindows[recordID]
            ?? ByteRateWindow()
        let didAdvance =
            current.byteStage != update.stage
            || update.processedBytes > current.processedBytes
        let rate = window.update(
            stage: update.stage,
            processedBytes: update.processedBytes
        )
        operationRateWindows[recordID] = window
        let remaining = rate > 0 && update.totalBytes > 0
            ? Double(
                max(0, update.totalBytes - update.processedBytes)
            ) / rate
            : nil
        operationProgress[recordID] = PDFOperationProgress(
            label: label,
            fractionCompleted: current.fractionCompleted,
            byteStage: update.stage,
            processedBytes: max(0, update.processedBytes),
            totalBytes: max(0, update.totalBytes),
            bytesPerSecond: rate,
            estimatedRemainingSeconds: remaining,
            throughputHistory: window.history,
            lastByteUpdateAt: didAdvance
                ? Date()
                : current.lastByteUpdateAt
        )
    }

    var libraryCommandSummary: LibraryCommandSummary {
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
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
        var scoreTotal = 0
        var attention = 0
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
            if needsAttention(record) {
                attention += 1
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
        return LibraryCommandSummary(
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
        let textPercent = min(
            100,
            max(0, Int((record.profile.textCoverage * 100).rounded()))
        )
        let structureSignal = DocumentCommandSignal(
            id: "structure",
            title: "Structure",
            value: "\(textPercent)%",
            detail: AppLocalization.format(
                "%lld page%@ · %lld image-heavy",
                record.profile.pageCount,
                record.profile.pageCount == 1 ? "" : "s",
                record.profile.imageDominantPageCount
            ),
            symbol: "text.magnifyingglass",
            readiness: textPercent >= 60
                ? .ready
                : textPercent >= 30 ? .review : .blocked
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

        return DocumentCommandProfile(
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
        guard let result = ocrResults[recordID] else { return false }
        return result.pages.contains { page in
            !page.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                || !page.blocks.isEmpty
        }
    }

    func matchingDocuments(
        query: String,
        status: DocumentWorkflowStatus?,
        category: DocumentCategory?
    ) -> [DocumentRecord] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }

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
        if record.profile.kind == .scan && ocrResults[record.id] == nil {
            return true
        }
        return !(record.brief?.suggestedSteps.isEmpty ?? true)
    }

    var attentionCount: Int {
        workingDocuments.filter(needsAttention).count
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
        actionNotice = nil
        errorOffersSettings = false
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "PaperPath could not complete that action."
    }

    func presentCameraPermissionDenied() {
        actionNotice = nil
        errorOffersSettings = true
        errorMessage = "Camera access is off. You can continue by importing PDFs, or enable Camera in Settings to scan paper."
            .localizedUI
    }

    func clearError() {
        errorMessage = nil
        errorOffersSettings = false
    }

    @discardableResult
    private func performPageMutation(
        recordID: UUID,
        label: String,
        invalidatesAnalysis: Bool = true,
        operation: @escaping @Sendable (
            PDFMutationService,
            URL
        ) throws -> Void
    ) async -> Bool {
        guard let record = record(id: recordID),
              let sourceURL = documentURLs[recordID]
        else { return false }
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-PageUndo-\(UUID().uuidString).pdf"
            )
        do {
            let task = Task.detached(priority: .utility) {
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: backupURL
                )
                LocalFileSecurity.applyCompleteProtection(to: backupURL)
            }
            try await valuePropagatingCancellation(from: task)
            try Task.checkCancellation()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: backupURL)
            return false
        } catch {
            present(
                PaperPathError.storageFailure(
                    "A recovery snapshot could not be created."
                )
            )
            return false
        }
        let succeeded = await mutate(
            recordID: recordID,
            invalidatesAnalysis: invalidatesAnalysis,
            snapshotLabel: label,
            operation: operation
        )
        guard succeeded else {
            try? FileManager.default.removeItem(at: backupURL)
            return false
        }
        if let previous = pageMutationUndos[recordID] {
            try? FileManager.default.removeItem(
                at: previous.backupURL
            )
        }
        pageMutationUndos[recordID] = PageMutationUndo(
            backupURL: backupURL,
            bookmarkedPages: record.bookmarkedPages,
            taskCheckpoint: record.taskCheckpoint,
            label: label
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
        noticeMessage = nil
        actionNotice = AppActionNotice(
            message: message.localizedUI,
            detail: detail?.localizedUI,
            kind: kind,
            action: action
        )
    }

    @discardableResult
    private func mutate(
        recordID: UUID,
        invalidatesAnalysis: Bool = true,
        snapshotLabel: String = "Document edit".localizedUI,
        operation: @escaping @Sendable (PDFMutationService, URL) throws -> Void
    ) async -> Bool {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID],
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
                label: snapshotLabel
            )
            let mutationService = self.mutationService
            let task = Task.detached(priority: .userInitiated) {
                try operation(mutationService, url)
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let refreshed = try await store.refresh(
                record,
                invalidateAnalysis: invalidatesAnalysis
            )
            if invalidatesAnalysis {
                textIndices[recordID] = nil
                ocrResults[recordID] = nil
            }
            replace(refreshed)
            refreshTokens[recordID, default: 0] += 1
            if invalidatesAnalysis {
                await analyzeDocument(recordID: recordID)
            }
            noticeMessage = "Working copy updated".localizedUI
            return true
        } catch is CancellationError {
            noticeMessage = "Operation cancelled".localizedUI
            return false
        } catch {
            present(error)
            return false
        }
    }

    private func remapTaskCheckpoint(
        recordID: UUID,
        checkpoint: DocumentTaskCheckpoint?,
        transform: (Int) -> Int?
    ) async {
        guard let checkpoint,
              let pageIndex = checkpoint.pageIndex
        else { return }
        guard let mappedPage = transform(pageIndex) else {
            await updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: nil
            )
            return
        }
        guard mappedPage != pageIndex else { return }
        await updateTaskCheckpoint(
            recordID: recordID,
            checkpoint: DocumentTaskCheckpoint(
                stage: checkpoint.stage,
                pageIndex: mappedPage,
                fieldName: checkpoint.fieldName,
                normalizedBounds: checkpoint.normalizedBounds
            )
        )
    }

    private func clearTaskCheckpointIfReplaced(
        recordID: UUID,
        pageIndex: Int,
        checkpoint: DocumentTaskCheckpoint?
    ) async {
        guard let checkpoint,
              checkpoint.stage != .verify,
              checkpoint.pageIndex == pageIndex
        else { return }
        await updateTaskCheckpoint(
            recordID: recordID,
            checkpoint: nil
        )
    }

    private func replaceBookmarks(
        recordID: UUID,
        pages: [Int]
    ) async {
        guard let record = record(id: recordID) else { return }
        do {
            let updated = try await store.updateBookmarks(
                record,
                pages: pages
            )
            replace(updated)
        } catch {
            present(error)
        }
    }

    private func createOutputCopy(
        recordID: UUID,
        outputName: String,
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
              let sourceURL = documentURLs[recordID]
        else {
            onFailure?(.sourceUnavailable())
            return nil
        }
        let operationToken: UUID
        do {
            operationToken = try beginExclusiveDocumentOperation(
                recordID: recordID
            )
        } catch {
            let issue = PDFBatchDeliveryIssue.preflightFailed(
                error.localizedDescription
            )
            onFailure?(issue)
            if presentsFeedback {
                present(issue)
            }
            return nil
        }
        let operationLabel = "Creating \(operationKind.title.lowercased())"
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
        let destination = temporaryPDFURL(prefix: outputName.capitalized)
        defer { try? FileManager.default.removeItem(at: destination) }
        let auditService = deliveryAuditService
        let reportProgress: PDFProgressHandler = { [weak self] value in
            Task { @MainActor [weak self] in
                guard self?.exclusiveDocumentOperations[recordID]
                    == operationToken
                else { return }
                self?.operationProgress[recordID] = PDFOperationProgress(
                    label: operationLabel,
                    fractionCompleted: min(0.98, max(0, value))
                )
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            do {
                try operation(sourceURL, destination) { value in
                    reportProgress(value * 0.78)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PDFBatchDeliveryIssue.renderingFailed(
                    error.localizedDescription
                )
            }
            reportProgress(0.82)
            let receipt: PDFDeliveryReceipt
            do {
                receipt = try auditService.audit(
                    sourceURL: sourceURL,
                    outputURL: destination,
                    operation: operationKind,
                    unlockPassword: unlockPassword
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PDFBatchDeliveryIssue.verificationFailed(
                    error.localizedDescription
                )
            }
            reportProgress(0.96)
            return receipt
        }
        do {
            var receipt = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                == record.contentRevisionID
            else {
                throw PDFBatchDeliveryIssue.verificationFailed(
                    "The source changed while the copy was being created."
                )
            }
            receipt.sourceRevisionID = record.contentRevisionID
            let outputRevisionID = UUID()
            receipt.outputRevisionID = outputRevisionID
            let created: DocumentRecord
            do {
                try Task.checkCancellation()
                created = try await importSinglePDF(
                    from: destination,
                    preferredName: "\(record.displayName) - \(outputName)",
                    deliveryReceipt: receipt,
                    sourceDocumentID: recordID,
                    contentRevisionID: outputRevisionID,
                    analyzeAfterImport: false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PDFBatchDeliveryIssue.savingFailed(
                    error.localizedDescription
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
            }
            if presentsFeedback {
                noticeMessage = notice
            }
            return created
        } catch is CancellationError {
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
                error.localizedDescription
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
        documents.removeAll { $0.id == recordID }
        documentURLs[recordID] = nil
        refreshTokens[recordID] = nil
        ocrResults[recordID] = nil
        textIndices[recordID] = nil
        searchMetadataCorpora[recordID] = nil
        removeSearchTextCorpus(recordID: recordID)
        deliveryPreflightCache[recordID] = nil
        officeBatchRuns[recordID] = nil
        deliveryProcessingDocumentIDs.remove(recordID)
        batchDeliveryPendingDocumentIDs.remove(recordID)
        if let undo = pageMutationUndos.removeValue(
            forKey: recordID
        ) {
            try? FileManager.default.removeItem(at: undo.backupURL)
        }
    }

    private func replace(
        _ record: DocumentRecord,
        schedulesMetadataSync: Bool = true
    ) {
        var updatedDocuments = documents
        if let index = updatedDocuments.firstIndex(
            where: { $0.id == record.id }
        ) {
            if updatedDocuments[index].contentRevisionID
                != record.contentRevisionID {
                deliveryPreflightCache[record.id] = nil
            }
            updatedDocuments[index] = record
        } else {
            updatedDocuments.append(record)
        }
        updatedDocuments.sort {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            return $0.modifiedAt > $1.modifiedAt
        }
        documents = updatedDocuments
        searchMetadataCorpora[record.id] =
            searchMetadataCorpus(for: record)
        removeSearchTextCorpus(recordID: record.id)
        if schedulesMetadataSync {
            scheduleMetadataSync()
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

    private func scheduleMetadataSync() {
        guard didBootstrap,
              !isRunningAutomatedTests,
              UserDefaults.standard.bool(
                forKey: AppPreferences.metadataSyncEnabledKey
              ),
              !isApplyingMetadataSync
        else { return }
        metadataSyncTask?.cancel()
        metadataSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.synchronizeMetadata(showNotice: false)
            }
        }
    }

    private func sortDocuments() {
        documents.sort {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    private func rebuildDocumentDerivedIndexes() {
        let recordsByID = Dictionary(
            documents.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let working = documents.filter(\.isWorkingCopy)
        let outputs = documents.filter(\.isDeliveryArtifact)
        var fingerprintCounts: [String: Int] = [:]
        for record in working {
            guard let fingerprint = record.contentFingerprint else {
                continue
            }
            fingerprintCounts[fingerprint, default: 0] += 1
        }

        var outputsBySourceID: [UUID: [DocumentRecord]] = [:]
        for output in outputs
        where output.hasCurrentDeliveryReceipt
            && output.deliveryReceipt?.isDeliveryOutput == true {
            var child = output
            var visited = Set<UUID>([output.id])
            while let parentID = child.sourceDocumentID,
                  visited.insert(parentID).inserted,
                  let parent = recordsByID[parentID] {
                guard child.deliveryReceipt?.sourceRevisionID
                        == parent.contentRevisionID
                else { break }
                outputsBySourceID[parentID, default: []].append(output)
                child = parent
            }
        }
        for sourceID in Array(outputsBySourceID.keys) {
            outputsBySourceID[sourceID]?.sort {
                ($0.deliveryReceipt?.createdAt ?? $0.importedAt)
                    > ($1.deliveryReceipt?.createdAt ?? $1.importedAt)
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
        verifiedOutputsBySourceID = outputsBySourceID
        verifiedShareTargetsByRecordID = shareTargets
        workingFingerprintCounts = fingerprintCounts
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
        preserveSourceLocation: Bool = false
    ) async throws -> DocumentRecord {
        let record = try await store.importPDF(
            from: url,
            preferredName: preferredName,
            deliveryReceipt: deliveryReceipt,
            sourceDocumentID: sourceDocumentID,
            contentRevisionID: contentRevisionID,
            preserveSourceLocation: preserveSourceLocation
        )
        replace(record)
        documentURLs[record.id] = await store.url(for: record)
        if analyzeAfterImport {
            await analyzeDocument(recordID: record.id)
        }
        return self.record(id: record.id) ?? record
    }

    private func analyzeMissingDocuments() async {
        for record in documents
        where record.brief == nil && record.deliveryReceipt == nil {
            guard !Task.isCancelled else { return }
            await analyzeDocument(recordID: record.id)
            await Task.yield()
        }
    }

    private func analyzeDocument(recordID: UUID) async {
        guard let record = record(id: recordID),
              let url = documentURLs[recordID]
        else { return }

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
            guard let currentRecord = self.record(id: recordID),
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
            try Task.checkCancellation()
            guard self.record(id: recordID)?.contentRevisionID
                    == record.contentRevisionID
            else { return }
            textIndices[recordID] = index
            replace(updated)
        } catch is CancellationError {
            return
        } catch PaperPathError.lockedPDF {
            return
        } catch {
            present(error)
        }
    }

    private func temporaryPDFURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).pdf")
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
        return [
            record.displayName,
            record.tags.joined(separator: " "),
            record.brief?.category.title ?? "",
            record.brief?.summary ?? "",
            entityText
        ]
        .joined(separator: "\n")
        .lowercased()
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

        let corpus = index.text.lowercased()
        let cost = corpus.utf8.count
        let maximumTotalCost = 12 * 1_024 * 1_024
        if searchTextCorpusCost + cost <= maximumTotalCost {
            searchTextCorpora[record.id] = corpus
            searchTextCorpusCosts[record.id] = cost
            searchTextCorpusCost += cost
        } else {
            streamingSearchTextRecordIDs.insert(record.id)
        }
        return unresolved.allSatisfy(corpus.contains)
    }

    private func textIndex(
        _ index: DocumentTextIndex,
        containsAll terms: [String]
    ) -> Bool {
        terms.allSatisfy { term in
            index.pages.contains {
                $0.text.localizedCaseInsensitiveContains(term)
            }
        }
    }

    private func removeSearchTextCorpus(recordID: UUID) {
        searchTextCorpora[recordID] = nil
        streamingSearchTextRecordIDs.remove(recordID)
        searchTextCorpusCost = max(
            0,
            searchTextCorpusCost
                - (searchTextCorpusCosts.removeValue(
                    forKey: recordID
                ) ?? 0)
        )
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
        let fixtures: [(String, (URL) throws -> Void)] = [
            ("Project handoff", DemoPDFBuilder.create),
            ("August invoice", DemoPDFBuilder.createInvoice),
            ("Site review report", DemoPDFBuilder.createReport)
        ]
        for (name, builder) in fixtures {
            let temporaryURL = temporaryPDFURL(prefix: "Demo")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try builder(temporaryURL)
            _ = try await store.importPDF(
                from: temporaryURL,
                preferredName: name,
                preserveSourceLocation: false
            )
        }
    }
}
