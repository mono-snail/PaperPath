import Foundation
import PDFKit
import SwiftUI

enum PrivacyBatchRedactionAppearance:
    String,
    CaseIterable,
    Hashable,
    Sendable {
    case black
    case white

    var title: String {
        switch self {
        case .black: "Black cover".localizedUI
        case .white: "White removal".localizedUI
        }
    }

    var color: Color {
        switch self {
        case .black: .black
        case .white: .white
        }
    }

    var pdfAppearance: PDFRedactionAppearance {
        switch self {
        case .black: .black
        case .white: .white
        }
    }
}

struct PrivacyRedactionSelection: Sendable {
    let findings: [PrivacyFinding]
    let appearance: PrivacyBatchRedactionAppearance

    var findingCount: Int {
        findings.count
    }

    var regionCount: Int {
        findings.reduce(0) {
            $0 + $1.normalizedBounds.count
        }
    }

    var affectedPageCount: Int {
        Set(findings.map(\.pageIndex)).count
    }

    var redactionMarks: [PDFRedactionMark] {
        PDFRedactionMarkSanitizer.clean(
            findings.flatMap { finding in
                finding.normalizedBounds.map { bounds in
                    PDFRedactionMark(
                        pageIndex: finding.pageIndex,
                        normalizedX: bounds.x,
                        normalizedY: bounds.y,
                        normalizedWidth: bounds.width,
                        normalizedHeight: bounds.height,
                        appearance: appearance.pdfAppearance
                    )
                }
            }
        )
    }
}

final class PrivacyRedactionOutcome: Sendable {
    let outputURL: URL
    let createdRecordID: UUID?
    let verifiedFindingCount: Int
    let affectedPageCount: Int

    init(
        outputURL: URL,
        createdRecordID: UUID? = nil,
        verifiedFindingCount: Int,
        affectedPageCount: Int
    ) {
        self.outputURL = outputURL
        self.createdRecordID = createdRecordID
        self.verifiedFindingCount = verifiedFindingCount
        self.affectedPageCount = affectedPageCount
    }

    deinit {
        PaperPathTemporaryArtifact.removeManagedItem(
            containing: outputURL,
            allowedPrefixes: ["PaperPath-FilesExport-"]
        )
    }

    @MainActor
    static func prepare(
        createdRecord: DocumentRecord,
        selection: PrivacyRedactionSelection,
        model: PaperPathModel
    ) async throws -> PrivacyRedactionOutcome {
        try Task.checkCancellation()
        guard let current = model.record(id: createdRecord.id),
              current.contentRevisionID == createdRecord.contentRevisionID,
              current.hasCurrentDeliveryReceipt,
              current.deliveryReceipt?.operation == .redacted
        else {
            throw PrivacyScanReviewError.managedOutputUnavailable
        }
        guard let outputURL = await model.makeFilesExportCopy(
            recordID: createdRecord.id,
            presentsFeedback: false
        ) else {
            try Task.checkCancellation()
            throw PrivacyScanReviewError.sharePreparationFailed
        }
        let outcome = PrivacyRedactionOutcome(
            outputURL: outputURL,
            createdRecordID: createdRecord.id,
            verifiedFindingCount: selection.findingCount,
            affectedPageCount: selection.affectedPageCount
        )
        try Task.checkCancellation()
        return outcome
    }
}

@MainActor
final class PrivacyScanReviewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(completedPages: Int, totalPages: Int)
        case review
        case redacting
        case completed
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: PrivacyScanResult?
    @Published private(set) var selection: Set<UUID> = []
    @Published private(set) var outcome: PrivacyRedactionOutcome?
    @Published var appearance: PrivacyBatchRedactionAppearance = .black
    @Published var expandedCategories: Set<PrivacyCategory> = []

    private var scanTask: Task<PrivacyScanResult, Error>?
    private var operationID = UUID()
    private var groupedFindings:
        [PrivacyCategory: [PrivacyFinding]] = [:]
    private var locatableFindingIDs: Set<UUID> = []
    private var locatableFindingIDsByCategory:
        [PrivacyCategory: Set<UUID>] = [:]
    private var regionCountByFindingID: [UUID: Int] = [:]
    private var pageIndexByFindingID: [UUID: Int] = [:]
    private var categoryByFindingID: [UUID: PrivacyCategory] = [:]
    private var selectedFindingCountByPage: [Int: Int] = [:]
    private var selectedFindingCountByCategory:
        [PrivacyCategory: Int] = [:]
    private var cachedLocatableCount = 0
    private var cachedLocatableRegionCount = 0
    private var cachedSelectedRegionCount = 0
    private var cachedSelectedPageCount = 0

    var findings: [PrivacyFinding] {
        result?.findings ?? []
    }

    var selectedFindings: [PrivacyFinding] {
        findings.filter { selection.contains($0.id) }
    }

    var selectedRegionCount: Int {
        cachedSelectedRegionCount
    }

    var selectedPageCount: Int {
        cachedSelectedPageCount
    }

    var locatableCount: Int {
        cachedLocatableCount
    }

    var locatableRegionCount: Int {
        cachedLocatableRegionCount
    }

    var unlocatableCount: Int {
        findings.count - locatableCount
    }

    var canRedact: Bool {
        selectedRegionCount > 0
            && phase == .review
    }

    var isAllLocatableSelected: Bool {
        locatableCount > 0
            && selection.count == locatableCount
    }

    var reviewWarnings: [PrivacyScanWarning] {
        PrivacyScanWarning.allCases.filter { warning in
            guard result?.warnings.contains(warning) == true else {
                return false
            }
            return warning != .ocrTextHadNoSpatialData
                || unlocatableCount == 0
        }
    }

    func findings(in category: PrivacyCategory) -> [PrivacyFinding] {
        groupedFindings[category, default: []]
    }

    func locatableCount(in category: PrivacyCategory) -> Int {
        locatableFindingIDsByCategory[category, default: []].count
    }

    func selectedCount(in category: PrivacyCategory) -> Int {
        selectedFindingCountByCategory[category, default: 0]
    }

    func selectionState(
        for category: PrivacyCategory
    ) -> PrivacySelectionState {
        let candidates = locatableFindingIDsByCategory[
            category,
            default: []
        ]
        let selectedCount = selectedFindingCountByCategory[
            category,
            default: 0
        ]
        if selectedCount == 0 {
            return .none
        }
        if selectedCount == candidates.count {
            return .all
        }
        return .some
    }

    func scan(
        document: PDFDocument,
        textIndex: DocumentTextIndex? = nil,
        spatialOCR: [PrivacySpatialTextObservation] = [],
        ocrResult: OCRResult? = nil,
        documentRevisionID: UUID? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let currentOperationID = beginScan(
            estimatedPageCount: document.pageCount
        )

        guard let data = document.dataRepresentation() else {
            phase = .failed(
                message: PrivacyScanReviewError.unreadableDocument
                    .localizedDescription
            )
            return
        }

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let isolatedDocument = PDFDocument(data: data) else {
                throw PrivacyScanReviewError.unreadableDocument
            }
            var resolvedSpatialOCR = spatialOCR
            resolvedSpatialOCR.append(
                contentsOf: try PrivacyScanService.spatialObservations(
                    from: ocrResult,
                    document: isolatedDocument
                )
            )
            return try PrivacyScanService().scan(
                document: isolatedDocument,
                textIndex: textIndex,
                spatialOCR: resolvedSpatialOCR,
                documentRevisionID: documentRevisionID
            ) { completed, total in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.operationID == currentOperationID,
                          case .scanning = self.phase
                    else {
                        return
                    }
                    self.phase = .scanning(
                        completedPages: completed,
                        totalPages: total
                    )
                }
            }
        }
        scanTask = worker
        await finishScan(
            worker,
            operationID: currentOperationID
        )
    }

    func scan(
        sourceURL: URL,
        estimatedPageCount: Int,
        textIndex: DocumentTextIndex? = nil,
        spatialOCR: [PrivacySpatialTextObservation] = [],
        ocrResult: OCRResult? = nil,
        documentRevisionID: UUID? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let currentOperationID = beginScan(
            estimatedPageCount: estimatedPageCount
        )
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let isolatedDocument = PDFDocument(url: sourceURL),
                  isolatedDocument.pageCount > 0
            else {
                throw PrivacyScanReviewError.unreadableDocument
            }
            var resolvedSpatialOCR = spatialOCR
            resolvedSpatialOCR.append(
                contentsOf: try PrivacyScanService.spatialObservations(
                    from: ocrResult,
                    document: isolatedDocument
                )
            )
            return try PrivacyScanService().scan(
                document: isolatedDocument,
                textIndex: textIndex,
                spatialOCR: resolvedSpatialOCR,
                documentRevisionID: documentRevisionID
            ) { completed, total in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.operationID == currentOperationID,
                          case .scanning = self.phase
                    else {
                        return
                    }
                    self.phase = .scanning(
                        completedPages: completed,
                        totalPages: total
                    )
                }
            }
        }
        scanTask = worker
        await finishScan(
            worker,
            operationID: currentOperationID
        )
    }

    private func beginScan(estimatedPageCount: Int) -> UUID {
        cancelScan()
        let currentOperationID = UUID()
        operationID = currentOperationID
        outcome = nil
        result = nil
        selection = []
        groupedFindings.removeAll(keepingCapacity: true)
        locatableFindingIDs.removeAll(keepingCapacity: true)
        locatableFindingIDsByCategory.removeAll(keepingCapacity: true)
        regionCountByFindingID.removeAll(keepingCapacity: true)
        pageIndexByFindingID.removeAll(keepingCapacity: true)
        categoryByFindingID.removeAll(keepingCapacity: true)
        selectedFindingCountByPage.removeAll(keepingCapacity: true)
        selectedFindingCountByCategory.removeAll(keepingCapacity: true)
        cachedLocatableCount = 0
        cachedLocatableRegionCount = 0
        cachedSelectedRegionCount = 0
        cachedSelectedPageCount = 0
        phase = .scanning(
            completedPages: 0,
            totalPages: max(0, estimatedPageCount)
        )
        return currentOperationID
    }

    private func finishScan(
        _ worker: Task<PrivacyScanResult, Error>,
        operationID currentOperationID: UUID
    ) async {
        do {
            let scanResult = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard operationID == currentOperationID else { return }
            let grouped = Dictionary(
                grouping: scanResult.findings,
                by: \.category
            )
            let locatable = scanResult.findings.filter(\.isLocatable)
            groupedFindings = grouped
            locatableFindingIDs = Set(locatable.map(\.id))
            locatableFindingIDsByCategory = Dictionary(
                grouping: locatable,
                by: \.category
            ).mapValues { Set($0.map(\.id)) }
            regionCountByFindingID = Dictionary(
                uniqueKeysWithValues: locatable.map {
                    ($0.id, $0.normalizedBounds.count)
                }
            )
            pageIndexByFindingID = Dictionary(
                uniqueKeysWithValues: locatable.map {
                    ($0.id, $0.pageIndex)
                }
            )
            categoryByFindingID = Dictionary(
                uniqueKeysWithValues: locatable.map {
                    ($0.id, $0.category)
                }
            )
            cachedLocatableCount = locatable.count
            cachedLocatableRegionCount = locatable.reduce(0) {
                $0 + $1.normalizedBounds.count
            }
            result = scanResult
            selection = Set(
                scanResult.findings
                    .filter(\.isSelectedByDefault)
                    .map(\.id)
            )
            rebuildSelectionMetrics()
            let populatedCategories = PrivacyCategory.allCases.filter {
                grouped[$0]?.isEmpty == false
            }
            let selectedCategories = populatedCategories.filter {
                selectedFindingCountByCategory[$0, default: 0] > 0
            }
            let expansionLimit: Int
            switch scanResult.findings.count {
            case ...12:
                expansionLimit = selectedCategories.count
            case ...40:
                expansionLimit = 2
            default:
                expansionLimit = 1
            }
            expandedCategories = Set(
                selectedCategories.prefix(expansionLimit)
            )
            phase = .review
        } catch is CancellationError {
            guard operationID == currentOperationID else { return }
            phase = .idle
        } catch {
            guard operationID == currentOperationID else { return }
            phase = .failed(
                message: AppLocalization.userFacingErrorDescription(
                    error,
                    fallback: "Privacy scan could not finish."
                )
            )
        }
        if operationID == currentOperationID {
            scanTask = nil
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        operationID = UUID()
        switch phase {
        case .scanning:
            phase = .idle
        case .redacting:
            outcome = nil
            phase = result == nil ? .idle : .review
        default:
            break
        }
    }

    func toggle(_ finding: PrivacyFinding) {
        guard finding.isLocatable else { return }
        if selection.contains(finding.id) {
            removeFromSelection(finding.id)
        } else {
            addToSelection(finding.id)
        }
    }

    func toggle(category: PrivacyCategory) {
        let candidates = locatableFindingIDsByCategory[
            category,
            default: []
        ]
        guard !candidates.isEmpty else { return }
        var updatedSelection = selection
        if candidates.isSubset(of: selection) {
            updatedSelection.subtract(candidates)
        } else {
            updatedSelection.formUnion(candidates)
        }
        selection = updatedSelection
        rebuildSelectionMetrics()
    }

    func selectAll() {
        selection = locatableFindingIDs
        rebuildSelectionMetrics()
    }

    func clearSelection() {
        selection.removeAll(keepingCapacity: true)
        selectedFindingCountByPage.removeAll(keepingCapacity: true)
        selectedFindingCountByCategory.removeAll(keepingCapacity: true)
        cachedSelectedRegionCount = 0
        cachedSelectedPageCount = 0
    }

    private func addToSelection(_ id: UUID) {
        guard locatableFindingIDs.contains(id),
              selection.insert(id).inserted
        else { return }
        cachedSelectedRegionCount += regionCountByFindingID[id, default: 0]
        guard let pageIndex = pageIndexByFindingID[id] else { return }
        let previousCount = selectedFindingCountByPage[
            pageIndex,
            default: 0
        ]
        selectedFindingCountByPage[pageIndex] = previousCount + 1
        if let category = categoryByFindingID[id] {
            selectedFindingCountByCategory[category, default: 0] += 1
        }
        if previousCount == 0 {
            cachedSelectedPageCount += 1
        }
    }

    private func removeFromSelection(_ id: UUID) {
        guard selection.remove(id) != nil else { return }
        cachedSelectedRegionCount = max(
            0,
            cachedSelectedRegionCount
                - regionCountByFindingID[id, default: 0]
        )
        guard let pageIndex = pageIndexByFindingID[id],
              let previousCount = selectedFindingCountByPage[pageIndex]
        else { return }
        if previousCount <= 1 {
            selectedFindingCountByPage[pageIndex] = nil
            cachedSelectedPageCount = max(
                0,
                cachedSelectedPageCount - 1
            )
        } else {
            selectedFindingCountByPage[pageIndex] = previousCount - 1
        }
        if let category = categoryByFindingID[id],
           let selectedCount = selectedFindingCountByCategory[category] {
            if selectedCount <= 1 {
                selectedFindingCountByCategory[category] = nil
            } else {
                selectedFindingCountByCategory[category] = selectedCount - 1
            }
        }
    }

    private func rebuildSelectionMetrics() {
        cachedSelectedRegionCount = 0
        selectedFindingCountByPage.removeAll(keepingCapacity: true)
        selectedFindingCountByCategory.removeAll(
            keepingCapacity: true
        )
        for id in selection {
            cachedSelectedRegionCount += regionCountByFindingID[
                id,
                default: 0
            ]
            if let pageIndex = pageIndexByFindingID[id] {
                selectedFindingCountByPage[pageIndex, default: 0] += 1
            }
            if let category = categoryByFindingID[id] {
                selectedFindingCountByCategory[
                    category,
                    default: 0
                ] += 1
            }
        }
        cachedSelectedPageCount = selectedFindingCountByPage.count
    }

    func reset() {
        scanTask?.cancel()
        scanTask = nil
        operationID = UUID()
        phase = .idle
        result = nil
        selection = []
        outcome = nil
        appearance = .black
        expandedCategories = []
        groupedFindings.removeAll(keepingCapacity: true)
        locatableFindingIDs.removeAll(keepingCapacity: true)
        locatableFindingIDsByCategory.removeAll(keepingCapacity: true)
        regionCountByFindingID.removeAll(keepingCapacity: true)
        pageIndexByFindingID.removeAll(keepingCapacity: true)
        categoryByFindingID.removeAll(keepingCapacity: true)
        selectedFindingCountByPage.removeAll(keepingCapacity: true)
        selectedFindingCountByCategory.removeAll(keepingCapacity: true)
        cachedLocatableCount = 0
        cachedLocatableRegionCount = 0
        cachedSelectedRegionCount = 0
        cachedSelectedPageCount = 0
    }

    func redact(
        using handler: @escaping @MainActor (
            PrivacyRedactionSelection
        ) async throws -> PrivacyRedactionOutcome
    ) async {
        guard canRedact else { return }
        let currentOperationID = UUID()
        operationID = currentOperationID
        let redactionSelection = PrivacyRedactionSelection(
            findings: selectedFindings,
            appearance: appearance
        )
        outcome = nil
        phase = .redacting
        do {
            let redactionOutcome = try await handler(
                redactionSelection
            )
            try Task.checkCancellation()
            guard operationID == currentOperationID else { return }
            outcome = redactionOutcome
            phase = .completed
        } catch is CancellationError {
            guard operationID == currentOperationID else { return }
            phase = .review
        } catch {
            guard operationID == currentOperationID else { return }
            phase = .failed(
                message: AppLocalization.userFacingErrorDescription(
                    error,
                    fallback: "Redaction could not finish."
                )
            )
        }
    }

    func returnToReview() {
        operationID = UUID()
        guard result != nil else {
            phase = .idle
            return
        }
        phase = .review
    }
}

enum PrivacySelectionState: Equatable {
    case none
    case some
    case all

    var systemImage: String {
        switch self {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }

    var title: String {
        switch self {
        case .none: "None selected".localizedUI
        case .some: "Some selected".localizedUI
        case .all: "All selected".localizedUI
        }
    }
}

private extension PrivacyFindingSource {
    var title: String {
        switch self {
        case .nativeText: "PDF text".localizedUI
        case .opticalCharacterRecognition: "On-device OCR".localizedUI
        }
    }

    var systemImage: String {
        switch self {
        case .nativeText: "doc.text"
        case .opticalCharacterRecognition: "viewfinder"
        }
    }
}

struct PrivacyScanReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false
    @ObservedObject private var model: PrivacyScanReviewModel
    @State private var showsCapabilities = false
    @State private var showsConfirmation = false
    @State private var redactionTask: Task<Void, Never>?
    @State private var scanWasStopped = false
    @State private var selectionFeedback = 0

    let documentName: String?
    let document: PDFDocument?
    let sourceURL: URL?
    let estimatedPageCount: Int
    let textIndex: DocumentTextIndex?
    let spatialOCR: [PrivacySpatialTextObservation]
    let ocrResult: OCRResult?
    let documentRevisionID: UUID?
    let onLocate: @MainActor (PrivacyFinding) -> Void
    let onRedact: @MainActor (
        PrivacyRedactionSelection
    ) async throws -> PrivacyRedactionOutcome
    let onOpenCreatedCopy: @MainActor (UUID) -> Void

    init(
        model: PrivacyScanReviewModel,
        document: PDFDocument,
        documentName: String? = nil,
        textIndex: DocumentTextIndex? = nil,
        spatialOCR: [PrivacySpatialTextObservation] = [],
        ocrResult: OCRResult? = nil,
        documentRevisionID: UUID? = nil,
        onLocate: @escaping @MainActor (PrivacyFinding) -> Void,
        onRedact: @escaping @MainActor (
            PrivacyRedactionSelection
        ) async throws -> PrivacyRedactionOutcome,
        onOpenCreatedCopy: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.model = model
        self.documentName = documentName
        self.document = document
        sourceURL = nil
        estimatedPageCount = document.pageCount
        self.textIndex = textIndex
        self.spatialOCR = spatialOCR
        self.ocrResult = ocrResult
        self.documentRevisionID = documentRevisionID
        self.onLocate = onLocate
        self.onRedact = onRedact
        self.onOpenCreatedCopy = onOpenCreatedCopy
    }

    init(
        model: PrivacyScanReviewModel,
        sourceURL: URL,
        estimatedPageCount: Int,
        documentName: String? = nil,
        textIndex: DocumentTextIndex? = nil,
        spatialOCR: [PrivacySpatialTextObservation] = [],
        ocrResult: OCRResult? = nil,
        documentRevisionID: UUID? = nil,
        onLocate: @escaping @MainActor (PrivacyFinding) -> Void,
        onRedact: @escaping @MainActor (
            PrivacyRedactionSelection
        ) async throws -> PrivacyRedactionOutcome,
        onOpenCreatedCopy: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.model = model
        self.documentName = documentName
        document = nil
        self.sourceURL = sourceURL
        self.estimatedPageCount = max(0, estimatedPageCount)
        self.textIndex = textIndex
        self.spatialOCR = spatialOCR
        self.ocrResult = ocrResult
        self.documentRevisionID = documentRevisionID
        self.onLocate = onLocate
        self.onRedact = onRedact
        self.onOpenCreatedCopy = onOpenCreatedCopy
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            reviewNavigation.presentationSizing(.page)
        } else {
            reviewNavigation
        }
    }

    private var reviewNavigation: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle:
                    idleView
                case let .scanning(completedPages, totalPages):
                    scanningView(
                        completedPages: completedPages,
                        totalPages: totalPages
                    )
                case .review:
                    reviewView
                case .redacting:
                    redactingView
                case .completed:
                    completedView
                case let .failed(message):
                    failureView(message: message)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PPColor.canvas)
            .navigationTitle("Privacy Scan".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.phase == .completed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done".localizedUI) {
                            closeAndReset()
                        }
                        .accessibilityIdentifier("privacyRedactionDone")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            closeAndReset()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close".localizedUI)
                        .accessibilityIdentifier("privacyScanClose")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.phase == .redacting)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.selection, trigger: model.appearance)
        .sensoryFeedback(
            .success,
            trigger: model.phase == .completed
        )
        .task(id: scenePhase) {
            guard scenePhase == .active,
                  model.phase == .idle,
                  !scanWasStopped
            else { return }
            await startScan()
        }
        .onDisappear {
            model.cancelScan()
            redactionTask?.cancel()
            redactionTask = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                break
            case .inactive, .background:
                model.cancelScan()
                redactionTask?.cancel()
                redactionTask = nil
            @unknown default:
                model.cancelScan()
                redactionTask?.cancel()
                redactionTask = nil
            }
        }
        .alert(
            confirmationTitle,
            isPresented: $showsConfirmation
        ) {
            Button(
                primaryRedactionTitle,
                role: .destructive
            ) {
                redactionTask?.cancel()
                redactionTask = Task {
                    await model.redact(using: onRedact)
                }
            }
            .accessibilityIdentifier("privacyRedactionConfirm")
            Button("Cancel".localizedUI, role: .cancel) {}
                .accessibilityIdentifier("privacyRedactionCancel")
        } message: {
            Text(confirmationMessage)
        }
#if DEBUG
        .onChange(of: model.phase) { _, phase in
            guard phase == .review else { return }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(
                "UITEST_PRIVACY_GALLERY_CONFIRMATION"
            ) {
                showsConfirmation = true
            } else if arguments.contains(
                "UITEST_PRIVACY_GALLERY_COMPLETED"
            ) {
                redactionTask?.cancel()
                redactionTask = Task {
                    await model.redact(using: onRedact)
                }
            }
        }
#endif
    }

    private var idleView: some View {
        List {
            Section {
                PrivacyWorkflowTrail(stage: 0)
                    .padding(.vertical, 4)
                Label(
                    scanWasStopped
                        ? "Scan stopped".localizedUI
                        : "Ready to scan".localizedUI,
                    systemImage: scanWasStopped
                        ? "stop.circle"
                        : "doc.text.magnifyingglass"
                )
                .font(PPType.display)
                documentSummary
                Button {
                    Task { await startScan() }
                } label: {
                    Label(
                        scanWasStopped
                            ? "Scan Again".localizedUI
                            : "Start Scan".localizedUI,
                        systemImage: "viewfinder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .accessibilityIdentifier("privacyScanStart")
            }
            capabilitiesSection
        }
        .contentMargins(
            .horizontal,
            regularListHorizontalMargin,
            for: .scrollContent
        )
    }

    private func scanningView(
        completedPages: Int,
        totalPages: Int
    ) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    PrivacyWorkflowTrail(stage: 0)
                    Label(
                        "Scanning on this device".localizedUI,
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .font(PPType.display)
                    documentSummary
                    HStack(alignment: .firstTextBaseline) {
                        Text(scanProgressTitle(
                            completedPages: completedPages,
                            totalPages: totalPages
                        ))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        Spacer()
                        Text(
                            AppLocalization.format(
                                "%lld of %lld pages",
                                completedPages,
                                totalPages
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    ProgressView(
                        value: Double(completedPages),
                        total: Double(max(totalPages, 1))
                    )
                    .tint(PPColor.mint)
                    .accessibilityLabel("Privacy scan progress".localizedUI)
                    .accessibilityValue(
                        AppLocalization.format(
                            "%lld of %lld pages",
                            completedPages,
                            totalPages
                        )
                    )
                    .accessibilityIdentifier("privacyScanProgress")

                    Label(
                        "PDF content stays on this device.".localizedUI,
                        systemImage: "iphone"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(PPColor.surface)
            Section {
                Button(role: .cancel) {
                    scanWasStopped = true
                    model.cancelScan()
                } label: {
                    Label(
                        "Stop Scan".localizedUI,
                        systemImage: "stop.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("privacyScanStop")
            } footer: {
                Text(
                    "Stop anytime. The PDF stays unchanged."
                        .localizedUI
                )
            }
        }
        .contentMargins(
            .horizontal,
            regularListHorizontalMargin,
            for: .scrollContent
        )
    }

    private var reviewView: some View {
        List {
            summarySection
            if !model.reviewWarnings.isEmpty {
                warningSection
            }
            if model.findings.isEmpty {
                emptySection
            } else {
                findingsSections
            }
            if model.unlocatableCount > 0 {
                unlocatableSection
            }
            if dynamicTypeSize.ppPrefersExpandedLayout {
                Section {
                    appearanceControl
                }
            }
            capabilitiesSection
        }
        .safeAreaInset(edge: .bottom) {
            if model.locatableCount > 0 {
                redactionBar
            }
        }
        .contentMargins(
            .horizontal,
            regularListHorizontalMargin,
            for: .scrollContent
        )
    }

    private var summarySection: some View {
        Section {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: 12) {
                    PrivacyWorkflowTrail(stage: 1)
                    reviewDocumentName
                    Label(
                        "Review private details".localizedUI,
                        systemImage: "eye"
                    )
                    .font(.headline)
                    Text(reviewDetectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(
                        selectedScopeSummary,
                        systemImage: "checkmark.circle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    selectionMenu
                }
                .dynamicTypeSize(.accessibility1)
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("privacyReviewSummary")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    PrivacyWorkflowTrail(stage: 1)
                    reviewDocumentName
                    Label(
                        "Review private details".localizedUI,
                        systemImage: "eye"
                    )
                    .font(PPType.display)
                    Text(reviewDetectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if model.selection.isEmpty, model.locatableCount > 0 {
                        Text("Select one or more candidates to continue.".localizedUI)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if !model.selection.isEmpty {
                        if horizontalSizeClass == .compact {
                            Label(
                                selectedScopeSummary,
                                systemImage: "checkmark.circle"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.accent)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            summaryMetrics
                        }
                    }

                    if model.locatableCount > 0 {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                selectionActions
                            }
                            VStack(spacing: 8) {
                                selectionActions
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("privacyReviewSummary")
            }
        }
        .listRowBackground(PPColor.surface)
    }

    @ViewBuilder
    private var reviewDocumentName: some View {
        if let documentName, !documentName.isEmpty {
            Text(documentName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? nil : 2)
                .truncationMode(.middle)
                .accessibilityIdentifier("privacyReviewDocumentName")
        }
    }

    private var summaryMetrics: some View {
        HStack(spacing: 8) {
            summaryMetric(
                title: "Selected".localizedUI,
                value: model.selection.count,
                symbol: "checkmark.circle"
            )
            summaryMetric(
                title: "Regions".localizedUI,
                value: model.selectedRegionCount,
                symbol: "viewfinder"
            )
            summaryMetric(
                title: "Pages".localizedUI,
                value: model.selectedPageCount,
                symbol: "doc.on.doc"
            )
        }
    }

    private func summaryMetric(
        title: String,
        value: Int,
        symbol: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(PPColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.headline)
                    .monospacedDigit()
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 10)
        .background(
            PPColor.surfaceMuted,
            in: RoundedRectangle(
                cornerRadius: PPRadius.control,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var selectionActions: some View {
        Button {
            model.selectAll()
            selectionFeedback &+= 1
        } label: {
            Label(
                model.isAllLocatableSelected
                    ? "All selected".localizedUI
                    : "Select All".localizedUI,
                systemImage: model.isAllLocatableSelected
                    ? "checkmark.circle.fill"
                    : "checkmark.circle"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.accent)
        .disabled(
            model.locatableCount == 0
                || model.isAllLocatableSelected
        )
        .accessibilityIdentifier("privacySelectAll")

        Button {
            model.clearSelection()
            selectionFeedback &+= 1
        } label: {
            Label(
                "Deselect All".localizedUI,
                systemImage: "xmark.circle"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.accent)
        .disabled(model.selection.isEmpty)
        .accessibilityIdentifier("privacyClearSelection")
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                model.selectAll()
                selectionFeedback &+= 1
            } label: {
                Label(
                    model.isAllLocatableSelected
                        ? "All selected".localizedUI
                        : "Select All".localizedUI,
                    systemImage: model.isAllLocatableSelected
                        ? "checkmark.circle.fill"
                        : "checkmark.circle"
                )
            }
            .disabled(
                model.locatableCount == 0
                    || model.isAllLocatableSelected
            )
            .accessibilityIdentifier("privacySelectAll")

            Button {
                model.clearSelection()
                selectionFeedback &+= 1
            } label: {
                Label(
                    "Deselect All".localizedUI,
                    systemImage: "xmark.circle"
                )
            }
            .disabled(model.selection.isEmpty)
            .accessibilityIdentifier("privacyClearSelection")
        } label: {
            Label(
                "Selection Actions".localizedUI,
                systemImage: "checklist"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("privacySelectionMenu")
    }

    private var capabilitiesSection: some View {
        Section {
            DisclosureGroup(
                isExpanded: $showsCapabilities
            ) {
                ForEach(PrivacyCategory.allCases, id: \.self) {
                    category in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: category.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.capabilityDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                Label(
                    "Supported privacy types".localizedUI,
                    systemImage: "checklist"
                )
                    .font(.headline)
            }
        } footer: {
            Text(
                "On-device detection can miss details."
                    .localizedUI
            )
        }
    }

    private var warningSection: some View {
        Section {
            ForEach(model.reviewWarnings, id: \.self) { warning in
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(warning.title)
                            .font(.subheadline.weight(.semibold))
                        Text(warning.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Review required".localizedUI)
        }
        .accessibilityIdentifier("privacyScanWarnings")
    }

    @ViewBuilder
    private var findingsSections: some View {
        ForEach(PrivacyCategory.allCases, id: \.self) { category in
            let findings = model.findings(in: category)
            if !findings.isEmpty {
                Section {
                    categoryHeader(
                        category: category,
                        count: findings.count
                    )
                    if model.expandedCategories.contains(category) {
                        ForEach(findings) { finding in
                            findingRow(finding)
                        }
                    }
                }
            }
        }
    }

    private func categoryHeader(
        category: PrivacyCategory,
        count: Int
    ) -> some View {
        let selectionState = model.selectionState(for: category)
        let selectedCount = model.selectedCount(in: category)
        let locatableCount = model.locatableCount(in: category)
        return HStack(spacing: 10) {
            Button {
                model.toggle(category: category)
                selectionFeedback &+= 1
            } label: {
                Image(systemName: selectionState.systemImage)
                .font(.title3)
                .foregroundStyle(
                    selectionState == .none
                        ? PPColor.textSecondary
                        : PPColor.accent
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locatableCount == 0)
            .accessibilityLabel(
                AppLocalization.format(
                    "%@ selection, %@",
                    category.title,
                    selectionState.title
                )
            )
            .accessibilityHint(
                "Toggles all locatable findings in this category."
                    .localizedUI
            )
            .accessibilityIdentifier(
                "privacyCategorySelection-\(category.rawValue)"
            )

            Button {
                if !model.expandedCategories.insert(category).inserted {
                    model.expandedCategories.remove(category)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: category.systemImage)
                        .foregroundStyle(PPColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .foregroundStyle(.primary)
                        Text(
                            AppLocalization.format(
                                "%lld of %lld selected",
                                selectedCount,
                                locatableCount
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer()
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(
                        systemName:
                            model.expandedCategories.contains(category)
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                AppLocalization.format(
                    "%@, %lld findings",
                    category.title,
                    count
                )
            )
            .accessibilityValue(
                AppLocalization.format(
                    "%@, %@",
                    selectionState.title,
                    model.expandedCategories.contains(category)
                        ? "Expanded".localizedUI
                        : "Collapsed".localizedUI
                )
            )
            .accessibilityIdentifier(
                "privacyCategory-\(category.rawValue)"
            )
        }
        .dynamicTypeSize(
            dynamicTypeSize.ppPrefersExpandedLayout
                ? .accessibility1
                : dynamicTypeSize
        )
    }

    @ViewBuilder
    private func findingRow(_ finding: PrivacyFinding) -> some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    findingSelectionButton(finding)
                    Spacer()
                    findingLocateButton(finding)
                }
                findingDetails(finding)
                    .padding(.horizontal, 4)
            }
            .dynamicTypeSize(.xSmall ... .accessibility1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "privacyFinding-\(finding.category.rawValue)-"
                    + finding.id.uuidString
            )
            .listRowBackground(model.selection.contains(finding.id) ? PPColor.selection : PPColor.surface)
        } else {
            HStack(alignment: .top, spacing: 10) {
                findingSelectionButton(finding)
                findingDetails(finding)
                findingLocateButton(finding)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "privacyFinding-\(finding.category.rawValue)-"
                    + finding.id.uuidString
            )
            .listRowBackground(model.selection.contains(finding.id) ? PPColor.selection : PPColor.surface)
        }
    }

    private func findingSelectionButton(
        _ finding: PrivacyFinding
    ) -> some View {
        Button {
            model.toggle(finding)
            selectionFeedback &+= 1
        } label: {
            Image(
                systemName: model.selection.contains(finding.id)
                    ? "checkmark.square.fill"
                    : "square"
            )
            .font(.title3)
            .foregroundStyle(
                model.selection.contains(finding.id)
                    ? PPColor.accent
                    : PPColor.textSecondary
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PPPressButtonStyle())
        .disabled(!finding.isLocatable)
        .accessibilityLabel(
            findingSelectionLabel(finding)
        )
        .accessibilityAddTraits(
            model.selection.contains(finding.id) ? .isSelected : []
        )
        .accessibilityIdentifier(
            "privacyFindingSelection-\(finding.id.uuidString)"
        )
    }

    private func findingDetails(
        _ finding: PrivacyFinding
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(finding.maskedValue)
                .font(.body.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    findingMetadata(finding)
                }
                VStack(alignment: .leading, spacing: 3) {
                    findingMetadata(finding)
                }
            }
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)

            Text(finding.reason)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "privacyFindingReason-\(finding.id.uuidString)"
                )

            if !finding.isLocatable {
                Label(
                    "Cannot locate automatically".localizedUI,
                    systemImage: "mappin.slash"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard finding.isLocatable else { return }
            model.toggle(finding)
            selectionFeedback &+= 1
        }
        .accessibilityAction(
            named: model.selection.contains(finding.id)
                ? "Deselect".localizedUI
                : "Select".localizedUI
        ) {
            model.toggle(finding)
            selectionFeedback &+= 1
        }
    }

    @ViewBuilder
    private func findingLocateButton(
        _ finding: PrivacyFinding
    ) -> some View {
        if finding.isLocatable {
            Button {
                onLocate(finding)
            } label: {
                Image(systemName: "scope")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(PPColor.surface, in: RoundedRectangle(cornerRadius: PPRadius.control))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PPPressButtonStyle())
            .foregroundStyle(PPColor.accent)
            .accessibilityLabel(
                AppLocalization.format(
                    "Locate %@ on page %lld",
                    finding.maskedValue,
                    finding.pageIndex + 1
                )
            )
            .accessibilityHint(
                "Returns to the PDF. Reopen Privacy Scan to continue reviewing."
                    .localizedUI
            )
            .accessibilityIdentifier(
                "privacyLocate-\(finding.id.uuidString)"
            )
        }
    }

    @ViewBuilder
    private func findingMetadata(_ finding: PrivacyFinding) -> some View {
        Label(
            AppLocalization.format(
                "Page %lld",
                finding.pageIndex + 1
            ),
            systemImage: "doc"
        )
        Label(
            finding.source.title,
            systemImage: finding.source.systemImage
        )
        .accessibilityIdentifier(
            "privacyFindingSource-\(finding.id.uuidString)"
        )
        if finding.confidence == .low {
            Label(
                "Low confidence".localizedUI,
                systemImage: "exclamationmark.circle.fill"
            )
            .foregroundStyle(PPColor.amber)
        }
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView(
                "No supported private details found".localizedUI,
                systemImage: "doc.text.magnifyingglass",
                description: Text(
                    "Review the PDF before sharing."
                        .localizedUI
                )
            )
        }
    }

    private var unlocatableSection: some View {
        Section {
            Label(
                AppLocalization.format(
                    "%lld OCR candidates need manual redaction.",
                    model.unlocatableCount
                ),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
        } footer: {
            Text(
                "Mark them in the PDF."
                    .localizedUI
            )
        }
    }

    private var redactionBar: some View {
        VStack {
            VStack(alignment: .leading, spacing: 10) {
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    appearanceControl
                }

                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Label(
                        redactionScopeSummary,
                        systemImage: "scope"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("privacyRedactionScope")
                }

                Button {
                    showsConfirmation = true
                } label: {
                    Label(
                        redactionActionTitle,
                        systemImage: "shield.lefthalf.filled"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(!model.canRedact)
                .accessibilityHint(redactionScopeSummary)
                .accessibilityIdentifier("privacyRedactionAction")
            }
            .frame(maxWidth: 680)
            .dynamicTypeSize(
                dynamicTypeSize.ppPrefersExpandedLayout
                    ? .accessibility1
                    : dynamicTypeSize
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.6))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private var appearanceControl: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            Menu {
                ForEach(
                    PrivacyBatchRedactionAppearance.allCases,
                    id: \.self
                ) { appearance in
                    Button {
                        model.appearance = appearance
                    } label: {
                        Label(
                            appearance.title,
                            systemImage: appearance == model.appearance
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                }
            } label: {
                HStack {
                    Text("Appearance".localizedUI)
                    Spacer()
                    appearanceSwatch(model.appearance)
                    Text(model.appearance.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("privacyAppearanceMenu")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance".localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(
                        PrivacyBatchRedactionAppearance.allCases,
                        id: \.self
                    ) { appearance in
                        Button {
                            model.appearance = appearance
                        } label: {
                            HStack(spacing: 7) {
                                appearanceSwatch(appearance)
                                Text(appearance.title)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 8)
                            .background(
                                appearance == model.appearance
                                    ? PPColor.selection
                                    : Color.clear,
                                in: RoundedRectangle(
                                    cornerRadius: PPRadius.control,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: PPRadius.control,
                                    style: .continuous
                                )
                                .stroke(
                                    appearance == model.appearance
                                        ? PPColor.accent
                                        : PPColor.border,
                                    lineWidth: appearance == model.appearance
                                        ? 1.5
                                        : 1
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            appearance == model.appearance ? .isSelected : []
                        )
                        .accessibilityIdentifier(
                            "privacyAppearance-\(appearance.rawValue)"
                        )
                    }
                }
            }
        }
    }

    private func appearanceSwatch(
        _ appearance: PrivacyBatchRedactionAppearance
    ) -> some View {
        Circle()
            .fill(appearance.color)
            .frame(width: 18, height: 18)
            .overlay {
                Circle()
                    .stroke(Color.primary.opacity(0.45), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var redactingView: some View {
        VStack(spacing: 18) {
            PrivacyWorkflowTrail(stage: 1)
                .frame(maxWidth: 460)
            Spacer()
            ZStack {
                Circle()
                    .fill(PPColor.accent.opacity(0.12))
                ProgressView()
                    .controlSize(.large)
                    .tint(PPColor.accent)
            }
            .frame(width: 72, height: 72)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Removing selected content".localizedUI
            )
            .accessibilityIdentifier("privacyRedactionProgress")
            Text("Removing selected content".localizedUI)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(selectedScopeSummary)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
            Text(
                "Verifying before sharing."
                    .localizedUI
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(role: .cancel) {
                redactionTask?.cancel()
                redactionTask = nil
                model.cancelScan()
            } label: {
                Label(
                    "Stop Redaction".localizedUI,
                    systemImage: "stop.circle"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("privacyRedactionStop")
            Spacer()
        }
        .padding(24)
    }

    private var completedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                PrivacyWorkflowTrail(stage: 2)
                VStack(alignment: .leading, spacing: PPSpacing.regular) {
                    HStack(alignment: .center, spacing: PPSpacing.large) {
                        VStack(alignment: .leading, spacing: PPSpacing.medium) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 38, weight: .medium))
                                .foregroundStyle(PPColor.inkAccent)
                            Text("Redaction verified".localizedUI)
                                .font(PPType.display)
                                .foregroundStyle(PPColor.onInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let outcome = model.outcome, !hideLibraryPreviews,
                           !dynamicTypeSize.ppPrefersExpandedLayout {
                            PDFPageThumbnailView(
                                url: outcome.outputURL,
                                pageIndex: 0,
                                refreshToken: 0,
                                width: 72
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .padding(5)
                            .background(PPColor.onInk, in: RoundedRectangle(cornerRadius: 8))
                            .rotationEffect(.degrees(3))
                            .accessibilityHidden(true)
                        }
                    }
                    Text("Copy ready. Original unchanged.".localizedUI)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.onInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(PPSpacing.xLarge)
                .background(PPColor.ink, in: RoundedRectangle(cornerRadius: PPRadius.surface))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("privacyRedactionVerified")
                .ppReveal()
                if let outcome = model.outcome {
                    VStack(spacing: PPSpacing.medium) {
                        LabeledContent(
                            "Permanently redacted".localizedUI,
                            value: itemCountText(outcome.verifiedFindingCount)
                        )
                        Divider()
                        LabeledContent(
                            "Removed regions".localizedUI,
                            value: regionCountText(model.selectedRegionCount)
                        )
                        LabeledContent(
                            "Affected pages".localizedUI,
                            value: pageCountText(outcome.affectedPageCount)
                        )
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                    .ppCard()
                    if let createdRecordID = outcome.createdRecordID {
                        Button {
                            openCreatedCopy(createdRecordID)
                        } label: {
                            Label(
                                "Open Redacted Copy".localizedUI,
                                systemImage: "doc.text.magnifyingglass"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                        .accessibilityHint(
                            "Opens the saved result copy."
                                .localizedUI
                        )
                        .accessibilityIdentifier(
                            "privacyOpenCreatedCopy"
                        )
                    }
                    ShareLink(item: outcome.outputURL) {
                        Label(
                            "Share Verified Copy".localizedUI,
                            systemImage: "square.and.arrow.up"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.accent)
                    )
                    .accessibilityIdentifier("privacyShareVerifiedCopy")
                }
            }
            .frame(maxWidth: 620)
            .padding(PPSpacing.large)
            .frame(maxWidth: .infinity)
        }
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label(
                "Action Not Completed".localizedUI,
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            if model.result == nil {
                Button("Scan Again".localizedUI) {
                    Task { await startScan() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Return to Review".localizedUI) {
                    model.returnToReview()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var documentSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityHidden(true)
            Text(
                documentName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Current PDF".localizedUI
            )
            .lineLimit(2)
            Spacer(minLength: 8)
            Text(pageCountText(estimatedPageCount))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("privacyScanDocument")
    }

    private var reviewDetectionSummary: String {
        AppLocalization.format(
            "%@ found · %@ can be redacted",
            candidateCountText(model.findings.count),
            candidateCountText(model.locatableCount)
        )
    }

    private var selectedScopeSummary: String {
        AppLocalization.format(
            "%@ · %@ · %@",
            itemCountText(model.selection.count),
            regionCountText(model.selectedRegionCount),
            pageCountText(model.selectedPageCount)
        )
    }

    private var redactionScopeSummary: String {
        guard !model.selection.isEmpty else {
            return "Select one or more candidates to continue.".localizedUI
        }
        return selectedScopeSummary
    }

    private var primaryRedactionTitle: String {
        AppLocalization.format(
            "Permanently Redact %@",
            itemCountText(model.selection.count)
        )
    }

    private var redactionActionTitle: String {
        guard !model.selection.isEmpty else {
            return "Select Items to Redact".localizedUI
        }
        return dynamicTypeSize.ppPrefersExpandedLayout
            ? "Review Redaction".localizedUI
            : primaryRedactionTitle
    }

    private func findingSelectionLabel(
        _ finding: PrivacyFinding
    ) -> String {
        AppLocalization.format(
            model.selection.contains(finding.id)
                ? "Deselect %@, %@, page %lld"
                : "Select %@, %@, page %lld",
            finding.maskedValue,
            finding.category.title,
            finding.pageIndex + 1
        )
    }

    private var confirmationTitle: String {
        AppLocalization.format(
            "Permanently redact %@?",
            itemCountText(model.selection.count)
        )
    }

    private var confirmationMessage: String {
        AppLocalization.format(
            "Removes %@ on %@ permanently. Cannot be undone. Original unchanged.",
            regionCountText(model.selectedRegionCount),
            pageCountText(model.selectedPageCount)
        )
    }

    private func candidateCountText(_ count: Int) -> String {
        AppLocalization.format(
            count == 1 ? "%lld candidate" : "%lld candidates",
            count
        )
    }

    private func itemCountText(_ count: Int) -> String {
        AppLocalization.format(
            count == 1 ? "%lld item" : "%lld items",
            count
        )
    }

    private func regionCountText(_ count: Int) -> String {
        AppLocalization.format(
            count == 1 ? "%lld region" : "%lld regions",
            count
        )
    }

    private func pageCountText(_ count: Int) -> String {
        AppLocalization.format(
            count == 1 ? "%lld page" : "%lld pages",
            count
        )
    }

    private func scanProgressTitle(
        completedPages: Int,
        totalPages: Int
    ) -> String {
        let percent = totalPages > 0
            ? min(
                100,
                max(
                    0,
                    Int(
                        (Double(completedPages)
                            / Double(totalPages) * 100).rounded(.down)
                    )
                )
            )
            : 0
        return AppLocalization.format("%lld%%", percent)
    }

    private func startScan() async {
        guard !Task.isCancelled,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        scanWasStopped = false
        if let sourceURL {
            await model.scan(
                sourceURL: sourceURL,
                estimatedPageCount: estimatedPageCount,
                textIndex: textIndex,
                spatialOCR: spatialOCR,
                ocrResult: ocrResult,
                documentRevisionID: documentRevisionID
            )
        } else if let document {
            await model.scan(
                document: document,
                textIndex: textIndex,
                spatialOCR: spatialOCR,
                ocrResult: ocrResult,
                documentRevisionID: documentRevisionID
            )
        }
        if model.phase == .review {
            showsCapabilities = false
        }
    }

    private var regularListHorizontalMargin: CGFloat? {
        horizontalSizeClass == .regular ? 72 : nil
    }

    private func closeAndReset() {
        redactionTask?.cancel()
        redactionTask = nil
        model.reset()
        dismiss()
    }

    private func openCreatedCopy(_ recordID: UUID) {
        redactionTask?.cancel()
        redactionTask = nil
        model.reset()
        onOpenCreatedCopy(recordID)
    }
}

private enum PrivacyScanReviewError: LocalizedError {
    case unreadableDocument
    case sourceChanged
    case invalidSelection
    case outputFailed
    case managedOutputUnavailable
    case sharePreparationFailed

    var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            "PaperPath could not read this PDF.".localizedUI
        case .sourceChanged:
            "The PDF changed. Scan it again before redacting."
                .localizedUI
        case .invalidSelection:
            "The selected findings have no regions that can be safely redacted."
                .localizedUI
        case .outputFailed:
            "The redacted copy was not completed. Review the notice and try again."
                .localizedUI
        case .managedOutputUnavailable:
            "The redacted copy was created, but its managed file is unavailable."
                .localizedUI
        case .sharePreparationFailed:
            "Copy saved in the Library. Open it there to share."
                .localizedUI
        }
    }
}

struct PrivacyScanWorkspaceSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var reviewModel: PrivacyScanReviewModel

    let recordID: UUID
    let contentRevisionID: UUID
    let sourceURL: URL
    let estimatedPageCount: Int
    let documentName: String
    let textIndex: DocumentTextIndex?
    let onLocate: @MainActor (PrivacyFinding) -> Void
    let onOpenDocument: @MainActor (DocumentRoute) -> Void

    var body: some View {
        Group {
            if model.record(id: recordID)?.contentRevisionID
                != contentRevisionID {
                unavailableView(
                    message: PrivacyScanReviewError.sourceChanged
                        .localizedDescription
                )
            } else {
                PrivacyScanReviewView(
                    model: reviewModel,
                    sourceURL: sourceURL,
                    estimatedPageCount: estimatedPageCount,
                    documentName: documentName,
                    textIndex: textIndex,
                    ocrResult: model.ocrResults[recordID],
                    documentRevisionID: contentRevisionID,
                    onLocate: { finding in
                        onLocate(finding)
                        dismiss()
                    },
                    onRedact: redact,
                    onOpenCreatedCopy: { createdRecordID in
                        onOpenDocument(
                            DocumentRoute(recordID: createdRecordID)
                        )
                    }
                )
            }
        }
    }

    private func redact(
        selection: PrivacyRedactionSelection
    ) async throws -> PrivacyRedactionOutcome {
        guard model.record(id: recordID)?.contentRevisionID
            == contentRevisionID
        else {
            throw PrivacyScanReviewError.sourceChanged
        }
        let marks = selection.redactionMarks
        guard !marks.isEmpty else {
            throw PrivacyScanReviewError.invalidSelection
        }
        guard let created = await model.createRedactedCopy(
            recordID: recordID,
            marks: marks,
            expectedContentRevisionID: contentRevisionID
        ) else {
            try Task.checkCancellation()
            throw PrivacyScanReviewError.outputFailed
        }
        return try await PrivacyRedactionOutcome.prepare(
            createdRecord: created,
            selection: selection,
            model: model
        )
    }

    private func unavailableView(message: String) -> some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    "Cannot Scan This PDF".localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            }
            .navigationTitle("Privacy Scan".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close".localizedUI)
                    .accessibilityIdentifier("privacyScanClose")
                }
            }
        }
    }
}

#if DEBUG
struct PrivacyScanDebugGalleryView: View {
    @StateObject private var model = PrivacyScanReviewModel()

    private static let sourceURL: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Privacy-Gallery.pdf",
                isDirectory: false
            )
        try? FileManager.default.removeItem(at: url)
        do {
            try DemoPDFBuilder.createInvoice(at: url)
        } catch {
            assertionFailure(
                "Could not create privacy gallery fixture: \(error)"
            )
        }
        return url
    }()

    var body: some View {
        PrivacyScanReviewView(
            model: model,
            sourceURL: Self.sourceURL,
            estimatedPageCount: 1,
            documentName: "August invoice",
            onLocate: { _ in },
            onRedact: { selection in
                try await Task.sleep(for: .milliseconds(160))
                try Task.checkCancellation()
                return PrivacyRedactionOutcome(
                    outputURL: Self.sourceURL,
                    verifiedFindingCount: selection.findingCount,
                    affectedPageCount: selection.affectedPageCount
                )
            }
        )
    }
}
#endif
