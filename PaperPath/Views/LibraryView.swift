import AVFoundation
import CoreImage.CIFilterBuiltins
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import VisionKit

private enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyEdited
    case recentlyOpened
    case name
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyEdited: return "Recently edited"
        case .recentlyOpened: return "Recently opened"
        case .name: return "Name"
        case .size: return "File size"
        }
    }

    var symbol: String {
        switch self {
        case .recentlyEdited: return "clock.arrow.circlepath"
        case .recentlyOpened: return "book.pages"
        case .name: return "textformat"
        case .size: return "arrow.down.circle"
        }
    }
}

private enum LibraryDensity: String {
    case comfortable
    case compact

    var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    var symbol: String {
        switch self {
        case .comfortable: return "list.bullet.rectangle"
        case .compact: return "rectangle.grid.1x2"
        }
    }
}

private enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list
    case grid
    case board

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        case .board: return "Board"
        }
    }

    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .board: return "rectangle.3.group"
        }
    }
}

private enum LibrarySearchScope: String, CaseIterable, Identifiable {
    case all
    case documents
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .documents: return "Documents"
        case .tools: return "Tools"
        }
    }
}

private enum LibraryWorkspaceLane:
    String,
    CaseIterable,
    Identifiable {
    case work
    case create
    case deliver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "Home"
        case .create: return "Tasks"
        case .deliver: return "Outputs"
        }
    }

    var detail: String {
        switch self {
        case .work:
            return "Continue the most useful next step."
        case .create:
            return "Choose what you want to accomplish."
        case .deliver:
            return "Review, verify, convert, and share."
        }
    }

    var symbol: String {
        switch self {
        case .work: return "house"
        case .create: return "checklist"
        case .deliver: return "square.and.arrow.up"
        }
    }
}

private enum DeliveryBoardLane:
    String,
    CaseIterable,
    Identifiable,
    Hashable {
    case source
    case producing
    case review
    case verified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "Sources"
        case .producing: return "Producing"
        case .review: return "Review"
        case .verified: return "Verified"
        }
    }

    var detail: String {
        switch self {
        case .source: return "Ready to check"
        case .producing: return "Local work"
        case .review: return "Needs evidence"
        case .verified: return "Ready to share"
        }
    }

    var symbol: String {
        switch self {
        case .source: return "doc"
        case .producing: return "gearshape.2"
        case .review: return "exclamationmark.triangle"
        case .verified: return "checkmark.seal.fill"
        }
    }
}

private enum LibrarySmartView: String, CaseIterable, Identifiable {
    case attention
    case overdue
    case today
    case scans
    case forms
    case ready
    case verified
    case officeReview
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention: return "Attention"
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .scans: return "Scans"
        case .forms: return "Forms"
        case .ready: return "Ready"
        case .verified: return "Verified"
        case .officeReview: return "Office Review"
        case .duplicates: return "Duplicates"
        }
    }

    var symbol: String {
        switch self {
        case .attention: return "sparkles"
        case .overdue: return "calendar.badge.exclamationmark"
        case .today: return "calendar"
        case .scans: return "viewfinder"
        case .forms: return "list.bullet.clipboard"
        case .ready: return "tray.full"
        case .verified: return "checkmark.seal"
        case .officeReview: return "doc.richtext"
        case .duplicates: return "doc.on.doc"
        }
    }
}

private struct LibrarySmartViewSummary: Identifiable {
    let view: LibrarySmartView
    let count: Int

    var id: LibrarySmartView { view }
}

private struct LibraryPageSearchSummary {
    let pageCount: Int
    let documentCount: Int
    let isLimited: Bool

    static let empty = LibraryPageSearchSummary(
        pageCount: 0,
        documentCount: 0,
        isLimited: false
    )
}

private struct LibraryPageIndexStamp: Hashable {
    let recordID: UUID
    let indexedAt: Date
    let pageCount: Int
}

private struct LibraryPageSearchRequest: Hashable {
    let query: String
    let recordIDs: [UUID]
    let indexStamps: [LibraryPageIndexStamp]
}

private struct LibraryPageSearchSnapshot: Sendable {
    let query: String
    let matchesByRecordID: [UUID: [DocumentTextMatch]]
    let isLimited: Bool

    static let empty = LibraryPageSearchSnapshot(
        query: "",
        matchesByRecordID: [:],
        isLimited: false
    )

    var summary: LibraryPageSearchSummary {
        LibraryPageSearchSummary(
            pageCount: matchesByRecordID.values.reduce(0) {
                $0 + $1.count
            },
            documentCount: matchesByRecordID.count,
            isLimited: isLimited
        )
    }
}

private struct LibraryDeliveryBoardSnapshot {
    let recordsByLane:
        [DeliveryBoardLane: [DocumentRecord]]
    let recordIDs: Set<UUID>

    var outputRecordCount: Int {
        Set(
            [
                DeliveryBoardLane.producing,
                .review,
                .verified
            ]
            .flatMap { recordsByLane[$0] ?? [] }
            .map(\.id)
        ).count
    }

    var visibleLanes: [DeliveryBoardLane] {
        DeliveryBoardLane.allCases.filter {
            !(recordsByLane[$0] ?? []).isEmpty
        }
    }

    func records(
        for lane: DeliveryBoardLane
    ) -> [DocumentRecord] {
        recordsByLane[lane] ?? []
    }
}

private enum LibraryContentSection: Int, Identifiable {
    case hero
    case laneSwitcher
    case commandCenter
    case start
    case continueWork
    case outputActions
    case deliveryCenter
    case smartViews
    case searchScope
    case pageSearch
    case taskPackages
    case pdfTools
    case searchAndFilters
    case tagFilters
    case library

    var id: Int { rawValue }
}

private struct ScanReviewSession: Identifiable, @unchecked Sendable {
    let id = UUID()
    let images: [UIImage]
    let initialOptions: ScanProcessingOptions
}

private extension View {
    func eraseLibraryViewType() -> AnyView {
        AnyView(self)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isImportingFile = false
    @State private var isPresentingScanner = false
    @State private var isPresentingCombine = false
    @State private var isPresentingCompressionBatch = false
    @State private var isPresentingBatchDelivery = false
    @State private var isPresentingBatchBatesNumbers = false
    @State private var batchBatesInitialRecordIDs: [UUID] = []
    @State private var isPresentingBatesReceipts = false
    @State private var isPresentingOfficeProduction = false
    @State private var officeProductionInitialRecordIDs: Set<UUID> = []
    @State private var scanReviewSession: ScanReviewSession?
    @State private var documentPickerTask: PDFQuickTask?
    @State private var taskPackagePicker: PDFTaskPackage?
    @State private var pendingImportTask: PDFQuickTask?
    @State private var isPresentingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var searchText = ""
    @State private var appliedSearchText = ""
    @State private var searchScope = LibrarySearchScope.all
    @State private var statusFilter: DocumentWorkflowStatus?
    @State private var categoryFilter: DocumentCategory?
    @State private var selectedTag: String?
    @State private var selectedSmartView: LibrarySmartView?
    @State private var expandedDeliveryLanes:
        Set<DeliveryBoardLane> = []
    @State private var showsAllTaskPackages = false
    @State private var showsAllPDFTools = false
    @State private var showsCommandDetails = false
    @State private var taskStartFeedback = 0
    @State private var isSelectingDocuments = false
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var isConfirmingBulkDelete = false
    @State private var isPresentingSettings = false
    @State private var isPresentingTrash = false
    @State private var isPresentingDuplicates = false
    @State private var isPresentingStorageCenter = false
    @State private var isPresentingPaperCreator = false
    @State private var isPresentingLibraryPageSearch = false
    @State private var isImportingDeliveryPackage = false
    @State private var deliveryPackageVerificationReport:
        PDFDeliveryPackageVerificationReport?
    @State private var deliveryPackageVerificationTask:
        Task<Void, Never>?
    @State private var deliveryPackageVerificationProgress:
        PDFOperationProgress?
    @State private var deliveryPackageVerificationGeneration = UUID()
    @State private var deliveryPackageVerificationFeedback = 0
    @State private var deliveryPackageVerificationErrorFeedback = 0
    @State private var isPresentingBatchTagEditor = false
    @State private var tagEditorRecord: DocumentRecord?
    @State private var scheduleEditorRecord: DocumentRecord?
    @State private var noteEditorRecord: DocumentRecord?
    @State private var deliveryReceiptRecord: DocumentRecord?
    @State private var libraryPageSearchSnapshot =
        LibraryPageSearchSnapshot.empty
    @State private var isSearchingPageIndex = false
    @AppStorage("library.quickTools") private var savedQuickTools = ""
    @AppStorage("library.sort")
    private var savedLibrarySort = LibrarySort.recentlyEdited.rawValue
    @AppStorage("library.density")
    private var savedLibraryDensity =
        LibraryDensity.compact.rawValue
    @AppStorage("library.viewMode")
    private var savedLibraryViewMode =
        LibraryViewMode.list.rawValue
    @AppStorage("library.workspaceLane")
    private var savedWorkspaceLane =
        LibraryWorkspaceLane.work.rawValue
    @AppStorage(AppPreferences.metadataSyncEnabledKey)
    private var metadataSyncEnabled = false
    @AppStorage("library.searchHistory")
    private var savedLibrarySearchHistory = "[]"
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false

    var selectedRecordID: UUID? = nil
    let onOpen: (DocumentRoute) -> Void

    var body: some View {
        ZStack {
            PPCanvas()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: PPSpacing.large) {
                    ForEach(visibleLibraryContentSections) { section in
                        libraryContent(section)
                    }
                }
                .frame(maxWidth: libraryContentMaxWidth)
                .padding(.horizontal, PPSpacing.regular)
                .padding(.top, PPSpacing.small)
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity)
            }

            if model.isImporting {
                processingOverlay
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewThatFits(in: .horizontal) {
                    brandTitle(AppBrand.title)
                    brandTitle(AppBrand.name)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AppBrand.title)
                .accessibilityIdentifier("libraryBrandTitle")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isPresentingPaperCreator = true
                    } label: {
                        Label(
                            "Create Paper PDF",
                            systemImage: "doc.badge.plus"
                        )
                    }

                    Button {
                        isImportingFile = true
                    } label: {
                        Label("Import PDFs", systemImage: "doc.badge.plus")
                    }

                    Button {
                        isImportingDeliveryPackage = true
                    } label: {
                        Label(
                            "Verify Delivery Package",
                            systemImage: "checkmark.shield"
                        )
                    }
                    .disabled(deliveryPackageVerificationTask != nil)
                    .accessibilityIdentifier("verifyDeliveryPackage")

                    Button {
                        beginScan()
                    } label: {
                        Label("Scan Paper", systemImage: "viewfinder")
                    }

                    if model.workingDocuments.count >= 2 {
                        Button {
                            isPresentingCombine = true
                        } label: {
                            Label("Combine PDFs", systemImage: "square.stack.3d.up")
                        }
                    }

                    if batesBatchEligibleRecords.count >= 2 {
                        Button {
                            batchBatesInitialRecordIDs = []
                            isPresentingBatchBatesNumbers = true
                        } label: {
                            Label(
                                "Bates Several PDFs",
                                systemImage: "number.square.fill"
                            )
                        }
                    }

                    if !model.batesBatchReceipts.isEmpty {
                        Button {
                            isPresentingBatesReceipts = true
                        } label: {
                            Label(
                                "Bates Receipts",
                                systemImage: "checkmark.seal"
                            )
                        }
                    }

                    if !model.deletedDocuments.isEmpty {
                        Divider()
                        Button {
                            isPresentingTrash = true
                        } label: {
                            Label(
                                "Trash (\(model.deletedDocuments.count))",
                                systemImage: "trash"
                            )
                        }
                    }

                    Divider()
                    Button {
                        isPresentingStorageCenter = true
                    } label: {
                        Label(
                            "Local Storage",
                            systemImage: "internaldrive"
                        )
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add PDF")
            }
        }
        .eraseLibraryViewType()
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            let requestedTask = pendingImportTask
            pendingImportTask = nil
            guard case .success(let urls) = result, !urls.isEmpty else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            Task {
                let records = await model.importPDFs(from: urls)
                if requestedTask == .mergePDFs {
                    if model.workingDocuments.count >= 2 {
                        isPresentingCombine = true
                    } else {
                        model.noticeMessage = "Choose at least two PDFs to merge"
                    }
                } else if let requestedTask,
                          let record = records.first {
                    if requestedTask.supports(record) {
                        open(requestedTask, recordID: record.id)
                    } else {
                        model.noticeMessage = "That PDF doesn’t support \(requestedTask.title.lowercased())"
                        onOpen(DocumentRoute(recordID: record.id))
                    }
                } else if records.count == 1,
                          let record = records.first {
                    onOpen(DocumentRoute(recordID: record.id))
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingDeliveryPackage,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first
            else {
                if case .failure(let error) = result {
                    model.present(error)
                    deliveryPackageVerificationErrorFeedback += 1
                }
                return
            }
            verifyDeliveryPackage(url)
        }
        .sheet(item: $deliveryPackageVerificationReport) { report in
            DeliveryPackageVerificationView(
                report: report
            ) { candidate in
                let updated = await model
                    .trustDeliveryPackageSigner(candidate)
                if let updated {
                    deliveryPackageVerificationReport = updated
                }
                return updated
            }
        }
        .photosPicker(
            isPresented: $isPresentingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 12,
            matching: .images
        )
        .onChange(of: selectedPhotoItems.count) { _, count in
            guard count > 0 else { return }
            importSelectedImages()
        }
        .fullScreenCover(isPresented: $isPresentingScanner) {
            DocumentScannerView(
                onComplete: { images in
                    isPresentingScanner = false
                    let session = ScanReviewSession(
                        images: images,
                        initialOptions: .document
                    )
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        scanReviewSession = session
                    }
                },
                onCancel: {
                    isPresentingScanner = false
                },
                onError: { error in
                    isPresentingScanner = false
                    model.present(error)
                }
            )
            .ignoresSafeArea()
        }
        .eraseLibraryViewType()
        .sheet(isPresented: $isPresentingCombine) {
            CombineDocumentsView { createdID in
                onOpen(DocumentRoute(recordID: createdID))
            }
        }
        .sheet(isPresented: $isPresentingCompressionBatch) {
            BatchCompressionView { route in
                onOpen(route)
            }
        }
        .sheet(item: $documentPickerTask) { task in
            quickTaskDocumentPicker(task)
        }
        .sheet(item: $taskPackagePicker) { package in
            taskPackageDocumentPicker(package)
        }
        .sheet(isPresented: $isPresentingBatchDelivery) {
            BatchSafeShareView { route in
                isPresentingBatchDelivery = false
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpen(route)
                }
            }
        }
        .sheet(isPresented: $isPresentingBatchBatesNumbers) {
            BatchBatesNumberingView(
                initialRecordIDs: batchBatesInitialRecordIDs
            )
        }
        .sheet(isPresented: $isPresentingBatesReceipts) {
            BatesBatchReceiptHistoryView { recordID in
                isPresentingBatesReceipts = false
                Task {
                    try? await Task.sleep(
                        for: .milliseconds(180)
                    )
                    onOpen(DocumentRoute(recordID: recordID))
                }
            }
        }
        .sheet(isPresented: $isPresentingOfficeProduction) {
            OfficeProductionCenterView(
                initialRecordIDs: officeProductionInitialRecordIDs
            ) { recordID in
                isPresentingOfficeProduction = false
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpen(DocumentRoute(recordID: recordID))
                }
            }
        }
        .eraseLibraryViewType()
        .sheet(isPresented: $isPresentingSettings) {
            AppSettingsView()
        }
        .sheet(isPresented: $isPresentingTrash) {
            TrashCenterView()
        }
        .sheet(isPresented: $isPresentingDuplicates) {
            DuplicateReviewView()
        }
        .sheet(isPresented: $isPresentingStorageCenter) {
            StorageCenterView { recordID in
                isPresentingStorageCenter = false
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpen(DocumentRoute(recordID: recordID))
                }
            }
        }
        .eraseLibraryViewType()
        .sheet(isPresented: $isPresentingPaperCreator) {
            PaperTemplateCreatorView { route in
                isPresentingPaperCreator = false
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpen(route)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isPresentingLibraryPageSearch) {
            LibraryPageSearchView(
                query: appliedSearchText,
                snapshot: libraryPageSearchSnapshot
            ) {
                recordID,
                pageIndex in
                isPresentingLibraryPageSearch = false
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    onOpen(
                        DocumentRoute(
                            recordID: recordID,
                            pageIndex: pageIndex
                        )
                    )
                }
            }
        }
        .sheet(item: $tagEditorRecord) { record in
            DocumentTagEditorView(recordID: record.id)
        }
        .sheet(item: $scheduleEditorRecord) { record in
            DocumentScheduleView(recordID: record.id)
                .presentationDetents([.medium, .large])
        }
        .eraseLibraryViewType()
        .sheet(item: $noteEditorRecord) { record in
            DocumentPrivateNoteView(recordID: record.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $deliveryReceiptRecord) { record in
            DeliveryReceiptView(
                recordID: record.id
            ) { targetRecordID, pageIndex in
                deliveryReceiptRecord = nil
                Task {
                    try? await Task.sleep(
                        for: .milliseconds(180)
                    )
                    onOpen(
                        DocumentRoute(
                            recordID: targetRecordID,
                            pageIndex: pageIndex
                        )
                    )
                }
            }
        }
        .sheet(isPresented: $isPresentingBatchTagEditor) {
            BatchTagEditorView(recordIDs: selectedDocumentIDs)
        }
        .sheet(item: $scanReviewSession) { session in
            ScanReviewView(
                images: session.images,
                initialOptions: session.initialOptions
            ) { pages in
                scanReviewSession = nil
                Task {
                    if let record = await model.importScan(
                        pages: pages
                    ) {
                        onOpen(DocumentRoute(recordID: record.id))
                    }
                }
            }
        }
        .eraseLibraryViewType()
        .confirmationDialog(
            "Move \(selectedDocumentIDs.count) private copies to Trash?",
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button(
                "Move \(selectedDocumentIDs.count) to Trash",
                role: .destructive
            ) {
                let recordIDs = selectedDocumentIDs
                Task {
                    if await model.delete(recordIDs: recordIDs) {
                        setDocumentSelection(active: false)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The copies remain recoverable. Original imported files stay untouched."
            )
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search PDFs or tools"
        )
        .searchSuggestions {
            if searchText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
               !librarySearchHistory.isEmpty {
                Section("Recent Searches") {
                    ForEach(librarySearchHistory, id: \.self) { query in
                        Button {
                            searchText = query
                            appliedSearchText = query
                            recordLibrarySearch(query)
                        } label: {
                            Label(
                                query,
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                    }

                    Button(role: .destructive) {
                        savedLibrarySearchHistory = "[]"
                    } label: {
                        Label(
                            "Clear Search History",
                            systemImage: "trash"
                        )
                    }
                }
            }
        }
        .onSubmit(of: .search) {
            appliedSearchText = searchText
            recordLibrarySearch(searchText)
        }
        .onChange(of: searchText) { _, value in
            if value.count > 200 {
                searchText = String(value.prefix(200))
            }
            if !value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                selectedSmartView = nil
            }
        }
        .eraseLibraryViewType()
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            appliedSearchText = searchText
        }
        .task(id: libraryPageSearchRequest) {
            await refreshLibraryPageSearch(
                request: libraryPageSearchRequest
            )
        }
        .onChange(
            of: model.settingsPresentationGeneration,
            initial: true
        ) { _, generation in
            guard generation > 0 else { return }
            isPresentingSettings = true
        }
        .onChange(of: model.documents.map(\.id)) { _, activeIDs in
            selectedDocumentIDs.formIntersection(Set(activeIDs))
        }
        .sensoryFeedback(.success, trigger: model.documents.count)
        .sensoryFeedback(.selection, trigger: showsAllPDFTools)
        .sensoryFeedback(.selection, trigger: savedQuickTools)
        .sensoryFeedback(.selection, trigger: taskStartFeedback)
        .sensoryFeedback(.selection, trigger: selectedDocumentIDs.count)
        .sensoryFeedback(.selection, trigger: savedLibraryViewMode)
        .sensoryFeedback(.selection, trigger: savedWorkspaceLane)
        .sensoryFeedback(
            .success,
            trigger: deliveryPackageVerificationFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: deliveryPackageVerificationErrorFeedback
        )
        .eraseLibraryViewType()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectingDocuments {
                documentSelectionBar
            } else if let progress =
                        deliveryPackageVerificationProgress {
                deliveryPackageVerificationBar(progress)
            }
        }
        .onDisappear {
            stopDeliveryPackageVerification()
        }
    }

    private var libraryContentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 1_180 : 760
    }

    private var visibleLibraryContentSections: [LibraryContentSection] {
        var sections: [LibraryContentSection] = []

        if isSearching {
            sections.append(.searchScope)
            if isSearchingPageIndex
                || libraryPageSearchSnapshot.summary.pageCount > 0,
               searchScope != .tools {
                sections.append(.pageSearch)
            }
            if shouldShowTaskPackages {
                sections.append(.taskPackages)
            }
            if shouldShowPDFTools {
                sections.append(.pdfTools)
            }
            if !model.documents.isEmpty,
               searchScope != .tools {
                sections.append(.searchAndFilters)
            }
            if !availableTags.isEmpty,
               searchScope != .tools {
                sections.append(.tagFilters)
            }
            if shouldShowLibrary {
                sections.append(.library)
            }
            return sections
        }

        if model.workingDocuments.isEmpty {
            sections.append(.hero)
        }
        sections.append(.laneSwitcher)
        switch workspaceLane {
        case .work:
            if model.workingDocuments.isEmpty {
                sections.append(.start)
                sections.append(.taskPackages)
            } else {
                sections.append(.commandCenter)
                if !additionalContinueWorkRecords.isEmpty {
                    sections.append(.continueWork)
                }
                if !activeSmartViewSummaries.isEmpty {
                    sections.append(.smartViews)
                }
                sections.append(.library)
            }
        case .create:
            if model.workingDocuments.isEmpty {
                sections.append(.start)
            }
            if shouldShowTaskPackages {
                sections.append(.taskPackages)
            }
            if shouldShowPDFTools {
                sections.append(.pdfTools)
            }
        case .deliver:
            sections.append(.outputActions)
            sections.append(.deliveryCenter)
        }
        return sections
    }

    @ViewBuilder
    private func libraryContent(
        _ section: LibraryContentSection
    ) -> some View {
        switch section {
        case .hero:
            libraryHero
        case .laneSwitcher:
            workspaceLaneSwitcher
        case .commandCenter:
            workbenchCommandCenter
        case .start:
            startActionSection
        case .continueWork:
            continueWorkSection
        case .outputActions:
            outputActionsSection
        case .deliveryCenter:
            deliveryCenterSection
        case .smartViews:
            smartViewsRail
        case .searchScope:
            searchScopeControl
        case .pageSearch:
            pageSearchSummary
        case .taskPackages:
            taskPackagesSection
        case .pdfTools:
            pdfToolsSection
        case .searchAndFilters:
            searchAndFilters
        case .tagFilters:
            tagFilterRail
        case .library:
            librarySection
        }
    }

    private var workspaceLane: LibraryWorkspaceLane {
        LibraryWorkspaceLane(rawValue: savedWorkspaceLane)
            ?? .work
    }

    private var workspaceLaneSwitcher: some View {
        let currentLaneCount = workspaceLaneCount(workspaceLane)

        return VStack(alignment: .leading, spacing: 6) {
            Text(workspaceLane.detail.localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(2)

            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    ForEach(LibraryWorkspaceLane.allCases) { lane in
                        Button {
                            selectWorkspaceLane(lane)
                        } label: {
                            Label(
                                lane.title.localizedUI,
                                systemImage: workspaceLane == lane
                                    ? "checkmark"
                                    : lane.symbol
                            )
                        }
                    }
                } label: {
                    HStack(spacing: PPSpacing.small) {
                        Label(
                            workspaceLane.title.localizedUI,
                            systemImage: workspaceLane.symbol
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            workspaceLaneTint(workspaceLane)
                        )
                        Spacer()
                        if currentLaneCount > 0 {
                            Text(
                                "\(currentLaneCount)"
                            )
                            .font(
                                .caption.monospacedDigit()
                                    .weight(.bold)
                            )
                            .foregroundStyle(PPColor.textSecondary)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 48)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(
                                workspaceLaneTint(workspaceLane)
                            )
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workspace")
                .accessibilityValue(workspaceLane.title.localizedUI)
            } else {
                HStack(spacing: 0) {
                    ForEach(LibraryWorkspaceLane.allCases) {
                        workspaceLaneButton($0)
                    }
                }
            }
        }
        .padding(.bottom, PPSpacing.xSmall)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryWorkspaceLanes")
    }

    private func workspaceLaneButton(
        _ lane: LibraryWorkspaceLane
    ) -> some View {
        let selected = lane == workspaceLane
        let tint = workspaceLaneTint(lane)
        let count = workspaceLaneCount(lane)

        return Button {
            selectWorkspaceLane(lane)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: lane.symbol)
                    .font(.caption.weight(.semibold))
                    .frame(width: 18)
                Text(lane.title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(selected ? .serif : .default)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(
                            selected ? tint : PPColor.textSecondary
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(
                selected ? tint : PPColor.textSecondary
            )
            .padding(.horizontal, 8)
            .frame(minHeight: 42)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        selected
                            ? tint
                            : PPColor.border.opacity(0.55)
                    )
                    .frame(height: selected ? 2 : 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lane.title.localizedUI)
        .accessibilityHint(lane.detail.localizedUI)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier(workspaceLaneIdentifier(lane))
    }

    private func selectWorkspaceLane(
        _ lane: LibraryWorkspaceLane
    ) {
        guard lane != workspaceLane else { return }
        withAnimation(
            reduceMotion ? nil : .snappy(duration: 0.2)
        ) {
            savedWorkspaceLane = lane.rawValue
            selectedSmartView = nil
            selectedTag = nil
            statusFilter = nil
            categoryFilter = nil
        }
    }

    private func workspaceLaneIdentifier(
        _ lane: LibraryWorkspaceLane
    ) -> String {
        switch lane {
        case .work: return "workspaceLane-home"
        case .create: return "workspaceLane-tasks"
        case .deliver: return "workspaceLane-outputs"
        }
    }

    private func workspaceLaneCount(
        _ lane: LibraryWorkspaceLane
    ) -> Int {
        switch lane {
        case .work:
            return continueWorkRecords.count
                + (recoverableBatchRun == nil ? 0 : 1)
                + (hasOfficeQueueRecovery ? 1 : 0)
        case .create:
            return 0
        case .deliver:
            return makeDeliveryBoardSnapshot().outputRecordCount
        }
    }

    private func workspaceLaneTint(
        _ lane: LibraryWorkspaceLane
    ) -> Color {
        switch lane {
        case .work: return PPColor.accent
        case .create: return PPColor.cyan
        case .deliver: return PPColor.mint
        }
    }

    private var libraryHero: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "PAPERPATH STUDIO",
                detail: Date.now.formatted(
                    .dateTime.month(.abbreviated).day()
                ),
                symbol: "doc.text.magnifyingglass",
                tint: PPColor.rose
            )

            HStack(alignment: .center, spacing: PPSpacing.medium) {
                libraryHeroCopy
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !dynamicTypeSize.isAccessibilitySize {
                    libraryArtwork
                }
            }
        }
        .padding(.bottom, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    private var libraryHeroCopy: some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Text("Private workbench".localizedUI)
                .font(.title2.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .accessibilityAddTraits(.isHeader)

            Text(AppBrand.subtitle.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.rose)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }

    private func brandTitle(_ value: String) -> some View {
        Text(value)
            .font(.headline)
            .fontDesign(.serif)
            .foregroundStyle(PPColor.textPrimary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var libraryArtwork: some View {
        if model.workingDocuments.isEmpty {
            PPIllustration(kind: .workspace, width: 124)
                .scaleEffect(0.52)
                .frame(width: 86, height: 62)
                .accessibilityHidden(true)
        } else {
            DocumentFan(
                records: model.workingDocuments,
                urlFor: { model.url(for: $0) },
                refreshTokenFor: { model.refreshToken(for: $0) }
            )
            .scaleEffect(0.46)
            .frame(width: 86, height: 62)
        }
    }

    private var workbenchMetrics: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 126, maximum: 240),
                    spacing: PPSpacing.small
                )
            ],
            alignment: .leading,
            spacing: PPSpacing.small
        ) {
            workbenchMetric(
                value: "\(model.workingDocuments.count)",
                title: "PDFs",
                symbol: "doc.text",
                tint: PPColor.accent
            )
            workbenchMetric(
                value: "\(model.textIndices.count)",
                title: "Searchable",
                symbol: "text.magnifyingglass",
                tint: PPColor.cyan
            )
            workbenchMetric(
                value: "\(model.attentionCount)",
                title: "Attention",
                symbol: "exclamationmark.circle",
                tint: model.attentionCount == 0
                    ? PPColor.mint
                    : PPColor.amber
            )
            workbenchMetric(
                value: "\(model.deliveryOutputs.filter(\.hasCurrentDeliveryReceipt).count)",
                title: "Verified",
                symbol: "checkmark.seal",
                tint: PPColor.mint
            )
        }
    }

    private func workbenchMetric(
        value: String,
        title: String,
        symbol: String,
        tint: Color
    ) -> some View {
        StudioMetricCell(
            value: value,
            label: title,
            symbol: symbol,
            tint: tint
        )
    }

    private var workbenchCommandCenter: some View {
        let summary = model.libraryCommandSummary

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            commandCenterPrimaryButton(summary)

            Button {
                withAnimation(
                    reduceMotion ? nil : .snappy(duration: 0.2)
                ) {
                    showsCommandDetails.toggle()
                }
            } label: {
                HStack {
                    Label(
                        showsCommandDetails
                            ? "Hide recommendation details"
                            : "Why this is next",
                        systemImage: "info.circle"
                    )
                    Spacer()
                    Image(
                        systemName: showsCommandDetails
                            ? "chevron.up"
                            : "chevron.down"
                    )
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsCommandDetails {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 116, maximum: 220),
                            spacing: PPSpacing.small
                        )
                    ],
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    commandCenterMetric(
                        value: "\(summary.readyCount)",
                        title: "Ready",
                        symbol: "tray.full",
                        tint: PPColor.mint
                    )
                    commandCenterMetric(
                        value: "\(summary.staleReceiptCount)",
                        title: "Recheck",
                        symbol: "arrow.triangle.2.circlepath",
                        tint: summary.staleReceiptCount == 0
                            ? PPColor.textSecondary
                            : PPColor.amber
                    )
                    commandCenterMetric(
                        value: "\(summary.scansNeedingOCRCount)",
                        title: "OCR",
                        symbol: "text.viewfinder",
                        tint: summary.scansNeedingOCRCount == 0
                            ? PPColor.textSecondary
                            : PPColor.cyan
                    )
                    commandCenterMetric(
                        value: "\(summary.batchEligibleCount)",
                        title: "Batch",
                        symbol: "checklist",
                        tint: summary.batchEligibleCount >= 2
                            ? PPColor.mint
                            : PPColor.textSecondary
                    )
                }
                commandCenterSecondaryCommands(summary)
                workbenchPrivacyRail(summary)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbenchCommandCenter")
    }

    private func commandCenterPrimaryButton(
        _ summary: LibraryCommandSummary
    ) -> some View {
        Button {
            performCommandCenterPrimary(summary)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                Image(systemName: commandCenterPrimarySymbol(summary))
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT")
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text(commandCenterPrimaryTitle(summary).localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .lineLimit(2)
                    Text(commandCenterPrimaryDetail(summary).localizedUI)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(Color.white.opacity(0.78))
                }
                Spacer(minLength: PPSpacing.small)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, PPSpacing.medium)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 68)
            .background(commandCenterPrimaryTint(summary))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: 7,
                    bottomTrailingRadius: 7,
                    topTrailingRadius: 2,
                    style: .continuous
                )
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.78))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            commandCenterPrimaryTitle(summary).localizedUI
        )
        .accessibilityHint(
            commandCenterPrimaryDetail(summary).localizedUI
        )
        .accessibilityIdentifier("homePrimaryAction")
    }

    private func commandCenterSecondaryCommands(
        _ summary: LibraryCommandSummary
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 112, maximum: 220),
                    spacing: PPSpacing.small
                )
            ],
            spacing: PPSpacing.small
        ) {
            commandCenterSecondaryButton(
                "Batch verify",
                detail: AppEntitlement.isUnlocked
                    ? "\(summary.batchEligibleCount) PDFs"
                    : "Lifetime lane",
                symbol: "checklist",
                tint: PPColor.mint,
                disabled: summary.batchEligibleCount < 2
            ) {
                isPresentingBatchDelivery = true
            }

            commandCenterSecondaryButton(
                "Bates batch",
                detail: AppLocalization.format(
                    "%lld eligible PDFs",
                    batesBatchEligibleRecords.count
                ),
                symbol: "number.square.fill",
                tint: PPColor.amber,
                disabled: batesBatchEligibleRecords.count < 2
            ) {
                batchBatesInitialRecordIDs = []
                isPresentingBatchBatesNumbers = true
            }

            commandCenterSecondaryButton(
                "Office queue",
                detail: officeProductionCommandDetail,
                symbol: "square.stack.3d.up",
                tint: PPColor.cyan
            ) {
                officeProductionInitialRecordIDs = []
                isPresentingOfficeProduction = true
            }

            if workspaceLane != .deliver {
                commandCenterSecondaryButton(
                    "Storage",
                    detail: "Local files",
                    symbol: "internaldrive",
                    tint: PPColor.accent
                ) {
                    isPresentingStorageCenter = true
                }

                commandCenterSecondaryButton(
                    "All tools",
                    detail: "Search commands",
                    symbol: "slider.horizontal.3",
                    tint: PPColor.cyan
                ) {
                    selectedSmartView = nil
                    savedWorkspaceLane =
                        LibraryWorkspaceLane.create.rawValue
                    showsAllPDFTools = true
                }
            }
        }
    }

    private func workbenchPrivacyRail(
        _ summary: LibraryCommandSummary
    ) -> some View {
        let workingCount = model.workingDocuments.count
        let checkedCount = summary.verifiedCount

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                privacyProofPill(
                    "On-device",
                    value: "\(model.documents.count)",
                    symbol: "iphone",
                    tint: PPColor.mint
                )
                privacyProofPill(
                    "Working",
                    value: "\(workingCount)",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                )
                privacyProofPill(
                    "Verified",
                    value: "\(checkedCount)",
                    symbol: "checkmark.seal",
                    tint: PPColor.mint
                )
                privacyProofPill(
                    "Metadata",
                    value: metadataSyncEvidenceValue,
                    symbol: metadataSyncEvidenceSymbol,
                    tint: metadataSyncEvidenceTint
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 116, maximum: 220),
                        spacing: PPSpacing.small
                    )
                ],
                alignment: .leading,
                spacing: PPSpacing.small
            ) {
                privacyProofPill(
                    "On-device",
                    value: "\(model.documents.count)",
                    symbol: "iphone",
                    tint: PPColor.mint
                )
                privacyProofPill(
                    "Working",
                    value: "\(workingCount)",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                )
                privacyProofPill(
                    "Verified",
                    value: "\(checkedCount)",
                    symbol: "checkmark.seal",
                    tint: PPColor.mint
                )
                privacyProofPill(
                    "Metadata",
                    value: metadataSyncEvidenceValue,
                    symbol: metadataSyncEvidenceSymbol,
                    tint: metadataSyncEvidenceTint
                )
            }
        }
        .padding(.top, PPSpacing.xSmall)
    }

    private func privacyProofPill(
        _ title: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 15)
            Text(value.localizedUI)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(title.localizedUI)
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 30)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.72))
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var metadataSyncEvidenceValue: String {
        guard metadataSyncEnabled else { return "Off" }
        switch model.metadataSyncStatus.state {
        case .idle:
            return "Ready"
        case .syncing:
            return "Syncing"
        case .synced:
            return "\(model.metadataSyncStatus.documentCount)"
        case .unavailable:
            return "Local"
        case .failed:
            return "Review"
        }
    }

    private var metadataSyncEvidenceSymbol: String {
        guard metadataSyncEnabled else { return "icloud.slash" }
        switch model.metadataSyncStatus.state {
        case .idle:
            return "icloud"
        case .syncing:
            return "icloud.and.arrow.up"
        case .synced:
            return "icloud.fill"
        case .unavailable:
            return "icloud.slash"
        case .failed:
            return "exclamationmark.icloud"
        }
    }

    private var metadataSyncEvidenceTint: Color {
        guard metadataSyncEnabled else { return PPColor.textSecondary }
        switch model.metadataSyncStatus.state {
        case .idle, .synced:
            return PPColor.mint
        case .syncing:
            return PPColor.cyan
        case .unavailable, .failed:
            return PPColor.amber
        }
    }

    private func commandCenterSecondaryButton(
        _ title: String,
        detail: String,
        symbol: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(disabled ? PPColor.textSecondary : tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(detail.localizedUI)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 42)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(
                        disabled
                            ? PPColor.border.opacity(0.45)
                            : tint.opacity(0.44)
                    )
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.58 : 1)
    }

    private func deliveryPackageVerificationBar(
        _ progress: PDFOperationProgress
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            LocalOperationProgressView(progress: progress)
                .frame(maxWidth: 620)
            Button {
                stopDeliveryPackageVerification()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.rose)
            .accessibilityLabel("Stop package verification")
            .accessibilityIdentifier("stopDeliveryPackageVerification")
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.72))
                .frame(height: 0.6)
        }
    }

    private func verifyDeliveryPackage(_ url: URL) {
        stopDeliveryPackageVerification()
        let generation = UUID()
        deliveryPackageVerificationGeneration = generation
        deliveryPackageVerificationProgress = PDFOperationProgress(
            label: "Verifying package",
            fractionCompleted: 0,
            byteStage: .verifying
        )
        deliveryPackageVerificationTask = Task { @MainActor in
            defer {
                if deliveryPackageVerificationGeneration
                    == generation {
                    deliveryPackageVerificationGeneration = UUID()
                    deliveryPackageVerificationTask = nil
                    deliveryPackageVerificationProgress = nil
                }
            }

            let report = await model.verifyDeliveryPackage(
                at: url
            ) { update in
                guard deliveryPackageVerificationGeneration
                        == generation
                else { return }
                let fraction = update.totalBytes > 0
                    ? min(
                        1,
                        max(
                            0,
                            Double(update.processedBytes)
                                / Double(update.totalBytes)
                        )
                    )
                    : 0
                deliveryPackageVerificationProgress =
                    PDFOperationProgress(
                        label: "Verifying package",
                        fractionCompleted: fraction,
                        byteStage: update.stage,
                        processedBytes: update.processedBytes,
                        totalBytes: update.totalBytes,
                        lastByteUpdateAt: Date()
                    )
            }
            guard !Task.isCancelled,
                  deliveryPackageVerificationGeneration == generation
            else { return }
            guard let report else {
                deliveryPackageVerificationErrorFeedback += 1
                return
            }
            deliveryPackageVerificationReport = report
            if report.status == .verified {
                deliveryPackageVerificationFeedback += 1
            } else {
                deliveryPackageVerificationErrorFeedback += 1
            }
        }
    }

    private func stopDeliveryPackageVerification() {
        deliveryPackageVerificationGeneration = UUID()
        deliveryPackageVerificationTask?.cancel()
        deliveryPackageVerificationTask = nil
        deliveryPackageVerificationProgress = nil
    }

    private func commandCenterMetric(
        value: String,
        title: String,
        symbol: String,
        tint: Color
    ) -> some View {
        StudioMetricCell(
            value: value,
            label: title,
            symbol: symbol,
            tint: tint
        )
    }

    private func commandCenterPrimaryTitle(
        _ summary: LibraryCommandSummary
    ) -> String {
        if let run = recoverableBatchRun {
            return run.needsRecovery
                ? "Resume batch verification"
                : "Review batch results"
        }
        if model.officeProductionQueue.isSuspended,
           model.officeProductionQueue.pendingCount > 0 {
            return "Resume Office queue"
        }
        if model.officeProductionQueue.attentionCount > 0 {
            return "Review Office queue"
        }
        if let record = homePriorityRecord {
            if record.profile.isLocked {
                return "Unlock to continue"
            }
            if record.deliveryReceipt != nil,
               !record.hasCurrentDeliveryReceipt {
                return "Verify changed output"
            }
            if let checkpoint = record.taskCheckpoint {
                return checkpoint.stage.title
            }
            if let recommendation =
                model.taskPackageRecommendation(for: record) {
                return recommendation.title
            }
            return AppLocalization.format(
                "Continue %@",
                record.displayName
            )
        }
        if summary.totalCount == 0 { return "Import PDF" }
        if summary.staleReceiptCount > 0 { return "Verify changed output" }
        if summary.scansNeedingOCRCount > 0 { return "Run OCR" }
        if summary.batchEligibleCount >= 2 { return "Batch verify" }
        return "Verify & Share"
    }

    private func commandCenterPrimaryDetail(
        _ summary: LibraryCommandSummary
    ) -> String {
        if let run = recoverableBatchRun {
            let remaining = run.items.filter {
                !$0.stage.isShareable
            }.count
            return AppLocalization.format(
                "%lld PDF%@ need attention",
                remaining,
                remaining == 1 ? "" : "s"
            )
        }
        if model.officeProductionQueue.isSuspended,
           model.officeProductionQueue.pendingCount > 0 {
            return AppLocalization.format(
                "%lld job%@ waiting to continue",
                model.officeProductionQueue.pendingCount,
                model.officeProductionQueue.pendingCount == 1 ? "" : "s"
            )
        }
        if model.officeProductionQueue.attentionCount > 0 {
            return AppLocalization.format(
                "%lld Office job%@ need review",
                model.officeProductionQueue.attentionCount,
                model.officeProductionQueue.attentionCount == 1 ? "" : "s"
            )
        }
        if let record = homePriorityRecord {
            let reason: String
            if record.profile.isLocked {
                reason = "Protected PDF"
            } else if record.deliveryReceipt != nil,
               !record.hasCurrentDeliveryReceipt {
                reason = "Changed after receipt"
            } else if let checkpoint = record.taskCheckpoint {
                reason = checkpoint.resumeReason
            } else if let recommendation =
                model.taskPackageRecommendation(for: record) {
                reason = recommendation.reason
            } else {
                reason = continueReason(for: record)
            }
            return "\(record.displayName) · \(reason.localizedUI)"
        }
        if summary.totalCount == 0 {
            return "Create a private copy"
        }
        if summary.staleReceiptCount > 0 {
            return "\(summary.staleReceiptCount) receipt\(summary.staleReceiptCount == 1 ? "" : "s")"
        }
        if summary.scansNeedingOCRCount > 0 {
            return "\(summary.scansNeedingOCRCount) scan\(summary.scansNeedingOCRCount == 1 ? "" : "s")"
        }
        if summary.batchEligibleCount >= 2 {
            return AppLocalization.format(
                "%lld eligible PDFs",
                summary.batchEligibleCount
            )
        }
        return "Create checked output"
    }

    private func commandCenterPrimarySymbol(
        _ summary: LibraryCommandSummary
    ) -> String {
        if recoverableBatchRun != nil {
            return "arrow.clockwise.circle.fill"
        }
        if hasOfficeQueueRecovery {
            return "square.stack.3d.up.fill"
        }
        if let record = homePriorityRecord {
            if record.profile.isLocked {
                return "lock.open"
            }
            if record.deliveryReceipt != nil,
               !record.hasCurrentDeliveryReceipt {
                return "arrow.triangle.2.circlepath"
            }
            return record.taskCheckpoint?.stage.symbol
                ?? model.taskPackageRecommendation(for: record)?
                    .task.symbol
                ?? "book.pages"
        }
        if summary.totalCount == 0 { return "doc.badge.plus" }
        if summary.staleReceiptCount > 0 {
            return "arrow.triangle.2.circlepath"
        }
        if summary.scansNeedingOCRCount > 0 { return "text.viewfinder" }
        if summary.batchEligibleCount >= 2 { return "checklist" }
        return "checkmark.shield"
    }

    private func commandCenterPrimaryTint(
        _ summary: LibraryCommandSummary
    ) -> Color {
        if recoverableBatchRun != nil || hasOfficeQueueRecovery {
            return PPColor.amber
        }
        if let record = homePriorityRecord {
            if record.profile.isLocked {
                return PPColor.amber
            }
            if record.deliveryReceipt != nil,
               !record.hasCurrentDeliveryReceipt {
                return PPColor.amber
            }
            if let package =
                model.taskPackageRecommendation(for: record)?.package {
                return taskPackageTint(package)
            }
            return PPColor.cyan
        }
        if summary.staleReceiptCount > 0 { return PPColor.amber }
        if summary.scansNeedingOCRCount > 0 { return PPColor.cyan }
        return PPColor.mint
    }

    private func performCommandCenterPrimary(
        _ summary: LibraryCommandSummary
    ) {
        taskStartFeedback += 1
        if recoverableBatchRun != nil {
            isPresentingBatchDelivery = true
        } else if hasOfficeQueueRecovery {
            officeProductionInitialRecordIDs = []
            isPresentingOfficeProduction = true
        } else if let record = homePriorityRecord {
            onOpen(homePriorityRoute(for: record))
        } else if summary.totalCount == 0 {
            isImportingFile = true
        } else if let record = staleReceiptRecord {
            open(.safeShare, recordID: record.id)
        } else if let record = scanNeedingOCRRecord {
            open(.recognizeText, recordID: record.id)
        } else if summary.batchEligibleCount >= 2 {
            isPresentingBatchDelivery = true
        } else {
            start(.safeShare)
        }
    }

    private var staleReceiptRecord: DocumentRecord? {
        model.workingDocuments.first {
            $0.deliveryReceipt != nil && !$0.hasCurrentDeliveryReceipt
        }
    }

    private var scanNeedingOCRRecord: DocumentRecord? {
        model.workingDocuments.first {
            ($0.profile.kind == .scan || $0.profile.kind == .mixed)
                && model.ocrResults[$0.id] == nil
                && !$0.profile.isLocked
        }
    }

    private var recoverableBatchRun: PDFBatchDeliveryRun? {
        model.recoverableBatchDeliveryRun()
    }

    private var currentBatchRun: PDFBatchDeliveryRun? {
        model.currentBatchDeliveryRun()
    }

    private var hasOfficeQueueRecovery: Bool {
        let queue = model.officeProductionQueue
        return (queue.isSuspended && queue.pendingCount > 0)
            || queue.attentionCount > 0
    }

    private func commandTint(
        _ readiness: DocumentCommandReadiness
    ) -> Color {
        switch readiness {
        case .ready: return PPColor.mint
        case .review: return PPColor.amber
        case .blocked: return .red
        }
    }

    private var suggestionFilter: some View {
        Button {
            selectSmartView(
                selectedSmartView == .attention
                    ? nil
                    : .attention
            )
        } label: {
            HStack(spacing: PPSpacing.regular) {
                VStack(spacing: 1) {
                    Text(
                        model.attentionCount == 0
                            ? "✓"
                            : "\(model.attentionCount)"
                    )
                    .font(.title2.weight(.medium))
                    .fontDesign(.serif)
                    .monospacedDigit()
                    Text("NOTES")
                        .font(.caption2.smallCaps().weight(.bold))
                        .fixedSize()
                }
                .foregroundStyle(
                    model.attentionCount == 0 ? PPColor.mint : PPColor.cyan
                )
                .dynamicTypeSize(.xSmall ... .xxxLarge)
                .frame(width: 60)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.62))
                        .frame(width: 0.6, height: 42)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        model.attentionCount == 0
                            ? "Up to date"
                            : "\(model.attentionCount) suggestion\(model.attentionCount == 1 ? "" : "s")"
                    )
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
                    Text(
                        model.attentionCount == 0
                            ? "No suggested follow-ups."
                            : "Optional next steps are available in the document brief."
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.isAccessibilitySize ? 4 : 2
                    )
                }

                Spacer()
                Image(
                    systemName: selectedSmartView == .attention
                        ? "line.3.horizontal.decrease"
                        : "arrow.right"
                )
                    .foregroundStyle(PPColor.textSecondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, PPSpacing.small)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.55))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.attentionCount == 0)
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .accessibilityIdentifier("suggestionFilter")
    }

    private var smartViewsRail: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "SMART VIEWS")
            ScrollView(.horizontal) {
                HStack(spacing: PPSpacing.small) {
                    ForEach(activeSmartViewSummaries) { summary in
                        let view = summary.view
                        let count = summary.count
                        let isSelected = selectedSmartView == view
                        Button {
                            selectSmartView(isSelected ? nil : view)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: view.symbol)
                                Text(view.title.localizedUI)
                                    .lineLimit(1)
                                Text("\(count)")
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        isSelected
                                            ? smartViewTint(view)
                                            : PPColor.textSecondary
                                    )
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(smartViewTint(view))
                            .padding(.horizontal, PPSpacing.small)
                            .frame(minHeight: 34)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(
                                        isSelected
                                            ? smartViewTint(view)
                                            : PPColor.border.opacity(0.58)
                                    )
                                    .frame(height: isSelected ? 2 : 0.6)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(
                            isSelected ? "Selected" : ""
                        )
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("librarySmartViews")
    }

    private var activeSmartViewSummaries:
        [LibrarySmartViewSummary] {
        let candidates: [LibrarySmartView] = [
            LibrarySmartView.attention,
            .overdue,
            .today,
            .duplicates
        ]
        var counts: [LibrarySmartView: Int] = [:]
        for record in model.workingDocuments {
            for view in candidates
            where matchesSmartView(record, smartView: view) {
                counts[view, default: 0] += 1
            }
        }
        return candidates.compactMap { view in
            guard let count = counts[view], count > 0 else {
                return nil
            }
            return LibrarySmartViewSummary(
                view: view,
                count: count
            )
        }
    }

    private var outputActionsSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "CREATE AN OUTPUT",
                detail: "Choose the result, then choose a PDF.",
                symbol: "checkmark.shield",
                tint: PPColor.mint
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 150, maximum: 320),
                        spacing: PPSpacing.small
                    )
                ],
                spacing: PPSpacing.small
            ) {
                outputActionButton(
                    "Verify & Share",
                    detail: "Create and check a final copy",
                    symbol: "checkmark.shield",
                    tint: PPColor.mint,
                    identifier: "outputsVerifyAction"
                ) {
                    start(.safeShare)
                }
                outputActionButton(
                    "Office production",
                    detail: officeProductionCommandDetail,
                    symbol: "doc.richtext",
                    tint: PPColor.cyan,
                    identifier: "outputsOfficeAction"
                ) {
                    officeProductionInitialRecordIDs = []
                    isPresentingOfficeProduction = true
                }
                outputActionButton(
                    "Verify package",
                    detail: deliveryPackageVerificationTask == nil
                        ? "PDF + signed Receipt"
                        : "Reading on device",
                    symbol: deliveryPackageVerificationTask == nil
                        ? "checkmark.shield"
                        : "hourglass",
                    tint: PPColor.mint,
                    identifier: "outputsVerifyPackageAction",
                    disabled: deliveryPackageVerificationTask != nil
                ) {
                    isImportingDeliveryPackage = true
                }
                if !model.batesBatchReceipts.isEmpty {
                    outputActionButton(
                        "Bates receipts",
                        detail: AppLocalization.format(
                            "%lld signed batches",
                            model.batesBatchReceipts.count
                        ),
                        symbol: "checkmark.seal",
                        tint: PPColor.amber,
                        identifier: "outputsBatesReceiptsAction"
                    ) {
                        isPresentingBatesReceipts = true
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outputActions")
    }

    private func outputActionButton(
        _ title: String,
        detail: String,
        symbol: String,
        tint: Color,
        identifier: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        disabled ? PPColor.textSecondary : tint
                    )
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(
                        disabled ? PPColor.textSecondary : tint
                    )
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 56)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(tint.opacity(0.72))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.58))
                    .frame(height: 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.58 : 1)
        .accessibilityHint(detail.localizedUI)
        .accessibilityIdentifier(identifier)
    }

    private var deliveryCenterSection: some View {
        let board = makeDeliveryBoardSnapshot()

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "DELIVERY BOARD",
                detail: "Source → production → review → verified",
                symbol: "arrow.forward.square",
                count: board.recordIDs.count,
                tint: PPColor.mint
            )

            if let batch = currentBatchRun {
                Button {
                    isPresentingBatchDelivery = true
                } label: {
                    HStack(spacing: PPSpacing.small) {
                        Image(
                            systemName: batch.needsAttention
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            batch.needsAttention
                                ? PPColor.amber
                                : PPColor.mint
                        )
                        Text(batchDeliverySummary(batch))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 38)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(
                                batch.needsAttention
                                    ? PPColor.amber
                                    : PPColor.mint
                            )
                            .frame(width: 2)
                            .padding(.vertical, 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Open latest batch delivery. \(batchDeliverySummary(batch))"
                )
            }

            if board.visibleLanes.isEmpty {
                ContentUnavailableView(
                    "No outputs yet".localizedUI,
                    systemImage: "checkmark.seal",
                    description: Text(
                        "Choose Verify & Share or Office production to begin."
                            .localizedUI
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.large)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: PPSpacing.medium) {
                        ForEach(board.visibleLanes) { lane in
                            deliveryBoardColumn(
                                lane,
                                records: board.records(for: lane)
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityIdentifier("deliveryCenter")
    }

    private func deliveryBoardColumn(
        _ lane: DeliveryBoardLane,
        records: [DocumentRecord]
    ) -> some View {
        let isExpanded = expandedDeliveryLanes.contains(lane)
        let visibleRecords = isExpanded
            ? records
            : Array(records.prefix(4))
        let tint = deliveryBoardTint(lane)

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .top, spacing: PPSpacing.small) {
                Image(systemName: lane.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(lane.detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                }
                Spacer(minLength: 0)
                Text("\(records.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }
            .frame(minHeight: 34)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tint.opacity(0.62))
                    .frame(height: 1.5)
            }

            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: lane.symbol)
                        .font(.headline)
                    Text("Clear")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 82)
                .overlay {
                    StudioStageMarks(
                        tint: PPColor.border,
                        inset: 3,
                        arm: 7
                    )
                }
            } else {
                ForEach(visibleRecords) { record in
                    deliveryBoardCard(record, lane: lane)
                }

                if records.count > 4 {
                    Button {
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .snappy(duration: 0.2)
                        ) {
                            if isExpanded {
                                expandedDeliveryLanes.remove(lane)
                            } else {
                                expandedDeliveryLanes.insert(lane)
                            }
                        }
                    } label: {
                        HStack {
                            Text(
                                isExpanded
                                    ? "Show less".localizedUI
                                    : AppLocalization.format(
                                        "Show %lld more",
                                        records.count - 4
                                    )
                            )
                            Spacer()
                            Image(
                                systemName: isExpanded
                                    ? "chevron.up"
                                    : "chevron.down"
                            )
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 210)
    }

    private func deliveryBoardCard(
        _ record: DocumentRecord,
        lane: DeliveryBoardLane
    ) -> some View {
        let tint = deliveryBoardTint(lane)

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            Button {
                openDeliveryRecord(record, lane: lane)
            } label: {
                HStack(alignment: .top, spacing: PPSpacing.small) {
                    if let url = model.url(for: record.id) {
                        PDFPageThumbnailView(
                            url: url,
                            pageIndex: 0,
                            refreshToken: model.refreshToken(
                                for: record.id
                            ),
                            width: 34
                        )
                    } else {
                        Image(systemName: lane.symbol)
                            .foregroundStyle(tint)
                            .frame(width: 34, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(2)
                        Text(deliveryBoardStatus(record, lane: lane))
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, PPSpacing.small)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 58)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tint.opacity(0.72))
                        .frame(width: 2)
                        .padding(.vertical, 5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(lane.title): \(record.displayName)"
            )

            if lane == .verified,
               let url = model.url(for: record.id) {
                ShareLink(item: url) {
                    Label(
                        "Share",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.mint)
                .accessibilityLabel(
                    "Share verified \(record.displayName)"
                )
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.56))
                .frame(height: 0.6)
        }
    }

    private func openDeliveryRecord(
        _ record: DocumentRecord,
        lane: DeliveryBoardLane
    ) {
        if lane == .verified {
            deliveryReceiptRecord = record
            return
        }
        if let item = batchDeliveryItem(for: record.id) {
            if item.stage == .needsReview,
               let pageIndex = item.reviewPageIndex {
                onOpen(
                    DocumentRoute(
                        recordID: item.sourceRecordID,
                        pageIndex: pageIndex
                    )
                )
            } else if item.stage == .failed
                        || item.stage == .stopped
                        || !item.stage.isFinal {
                isPresentingBatchDelivery = true
            } else {
                onOpen(
                    DocumentRoute(recordID: item.sourceRecordID)
                )
            }
            return
        }
        onOpen(
            DocumentRoute(
                recordID: record.id,
                quickTask: lane == .producing
                    ? nil
                    : .safeShare
            )
        )
    }

    private func makeDeliveryBoardSnapshot()
        -> LibraryDeliveryBoardSnapshot {
        var ids = model.deliveryProcessingDocumentIDs
            .union(model.batchDeliveryPendingDocumentIDs)
        if let run = currentBatchRun {
            for item in run.items
            where !item.stage.isFinal {
                ids.insert(item.sourceRecordID)
            }
        }
        let producingIDs = ids

        let outputRecords = deliveryCenterRecords
        var reviewIDs = Set(
            outputRecords
                .filter {
                    !$0.hasCurrentDeliveryReceipt
                        && model.verifiedShareTarget(for: $0.id) == nil
                }
                .map(\.id)
        )
        if let run = currentBatchRun {
            for item in run.items
            where item.stage.isFinal && !item.stage.isShareable {
                reviewIDs.insert(
                    item.outputRecordID ?? item.sourceRecordID
                )
            }
        }

        let recordsByLane: [
            DeliveryBoardLane: [DocumentRecord]
        ] = [
            .source: model.workingDocuments
                .filter {
                    !$0.profile.isLocked
                        && !producingIDs.contains($0.id)
                        && !reviewIDs.contains($0.id)
                        && model.verifiedShareTarget(for: $0.id) == nil
                }
                .sorted { $0.modifiedAt > $1.modifiedAt },
            .producing: model.documents
                .filter { producingIDs.contains($0.id) }
                .sorted { $0.modifiedAt > $1.modifiedAt },
            .review: model.documents
                .filter { reviewIDs.contains($0.id) }
                .sorted { $0.modifiedAt > $1.modifiedAt },
            .verified: outputRecords
                .filter(\.hasCurrentDeliveryReceipt)
        ]
        return LibraryDeliveryBoardSnapshot(
            recordsByLane: recordsByLane,
            recordIDs: Set(
                recordsByLane.values
                    .flatMap { $0 }
                    .map(\.id)
            )
        )
    }

    private func deliveryBoardStatus(
        _ record: DocumentRecord,
        lane: DeliveryBoardLane
    ) -> String {
        switch lane {
        case .source:
            return "\(record.profile.pageCount) pages · \(record.profile.formattedSize)"
        case .producing:
            return model.progress(for: record.id)?.label
                ?? "Local production in progress"
        case .review:
            if let item = batchDeliveryItem(for: record.id) {
                if let issue = item.issue {
                    return "\(item.stage.title.localizedUI) · \(issue.code)"
                }
                return item.detail.localizedUI
            }
            return record.deliveryReceipt == nil
                ? "Review batch evidence"
                : "Changed after receipt"
        case .verified:
            return deliveryStatusText(record)
        }
    }

    private func batchDeliveryItem(
        for recordID: UUID
    ) -> PDFBatchDeliveryItem? {
        currentBatchRun?.items.first {
            $0.sourceRecordID == recordID
                || $0.outputRecordID == recordID
        }
    }

    private func deliveryBoardTint(
        _ lane: DeliveryBoardLane
    ) -> Color {
        switch lane {
        case .source: return PPColor.accent
        case .producing: return PPColor.cyan
        case .review: return PPColor.amber
        case .verified: return PPColor.mint
        }
    }

    private var deliveryCenterRecords: [DocumentRecord] {
        model.deliveryOutputs
            .sorted {
                ($0.deliveryReceipt?.createdAt ?? $0.modifiedAt)
                    > ($1.deliveryReceipt?.createdAt ?? $1.modifiedAt)
            }
    }

    private func receiptDate(
        _ receipt: PDFDeliveryReceipt?
    ) -> String {
        (receipt?.createdAt ?? Date()).formatted(
            date: .abbreviated,
            time: .omitted
        )
    }

    private func deliveryStatusText(
        _ record: DocumentRecord
    ) -> String {
        guard record.hasCurrentDeliveryReceipt else {
            return "Changed after receipt".localizedUI
        }
        return AppLocalization.format(
            "%@ · %@",
            (
                record.deliveryReceipt?.operation.title
                    ?? "Output"
            ).localizedUI,
            receiptDate(record.deliveryReceipt)
        )
    }

    private func batchDeliverySummary(
        _ run: PDFBatchDeliveryRun
    ) -> String {
        let ready = run.items.filter(\.stage.isShareable).count
        let attention = run.items.count - ready
        if attention == 0 {
            return AppLocalization.format(
                "%lld verified in latest batch",
                ready
            )
        }
        return AppLocalization.format(
            "%lld ready · %lld need attention",
            ready,
            attention
        )
    }

    private var startActionSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(
                text: model.workingDocuments.isEmpty
                    ? "START"
                    : "COMMAND DECK"
            )

            if horizontalSizeClass == .regular,
               !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: PPSpacing.small) {
                    primaryStartButton
                        .frame(maxWidth: 340)
                    intakeCommands
                }
            } else {
                VStack(spacing: PPSpacing.small) {
                    primaryStartButton
                    intakeCommands
                }
            }
        }
        .padding(.bottom, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .accessibilityIdentifier("primaryStartPath")
    }

    private var primaryStartButton: some View {
        Button {
            if model.workingDocuments.isEmpty {
                isImportingFile = true
            } else {
                start(PDFQuickTask.safeShare)
            }
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(
                    systemName: model.workingDocuments.isEmpty
                        ? "doc.badge.plus"
                        : "checkmark.shield"
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        model.workingDocuments.isEmpty
                            ? "Import PDF"
                            : "Verify & Share"
                    )
                    .font(.headline)
                    Text(
                        model.workingDocuments.isEmpty
                            ? "Create a private working copy"
                            : "Reopen and check the final copy"
                    )
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, PPSpacing.medium)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(PPColor.accent)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o", modifiers: .command)
    }

    private var intakeCommands: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 78, maximum: 180),
                    spacing: PPSpacing.small
                )
            ],
            spacing: PPSpacing.small
        ) {
            if !model.workingDocuments.isEmpty {
                intakeCommand(
                    "Import",
                    symbol: "tray.and.arrow.down",
                    tint: PPColor.accent
                ) {
                    isImportingFile = true
                }
            }
            intakeCommand(
                "Scan",
                symbol: "viewfinder",
                tint: PPColor.cyan
            ) {
                beginScan()
            }
            intakeCommand(
                "Photos",
                symbol: "photo.on.rectangle.angled",
                tint: PPColor.amber
            ) {
                isPresentingPhotoPicker = true
            }
            intakeCommand(
                "Paper",
                symbol: "doc.badge.plus",
                tint: PPColor.mint
            ) {
                isPresentingPaperCreator = true
            }
        }
    }

    private func intakeCommand(
        _ title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                Text(title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(tint.opacity(0.48))
                    .frame(width: 2)
                    .padding(.vertical, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.localizedUI)
    }

    private var compactCapture: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: 0))

        return layout {
            Button {
                isPresentingPhotoPicker = true
            } label: {
                captureLabel(
                    "Photos",
                    note: "To PDF",
                    symbol: "photo.on.rectangle.angled",
                    tint: PPColor.accent
                )
            }
            .buttonStyle(.plain)

            Button {
                beginScan()
            } label: {
                captureLabel(
                    "Scan",
                    note: "Paper",
                    symbol: "viewfinder",
                    tint: PPColor.cyan
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                isPresentingPaperCreator = true
            } label: {
                captureLabel(
                    "Create",
                    note: "Paper PDF",
                    symbol: "doc.badge.plus",
                    tint: PPColor.mint
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("createPaperButton")
            .accessibilityLabel("Create Paper PDF")
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    private func captureLabel(
        _ title: String,
        note: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(note.localizedUI.uppercased())
                    .font(.caption2.smallCaps().weight(.medium))
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 48)
        .padding(.horizontal, PPSpacing.medium)
        .contentShape(Rectangle())
    }

    private var continueWorkSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionEyebrow(text: "ACTIVE WORK")
                    Text("More in progress")
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                }
                Spacer()
                Text("\(additionalContinueWorkRecords.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(
                    Array(additionalContinueWorkRecords.prefix(3).enumerated()),
                    id: \.element.id
                ) { index, record in
                    Button {
                        onOpen(continueRoute(for: record))
                    } label: {
                        HStack(spacing: PPSpacing.medium) {
                            if !hideLibraryPreviews,
                               let url = model.url(for: record.id) {
                                PDFPageThumbnailView(
                                    url: url,
                                    pageIndex: record.lastPageIndex,
                                    refreshToken: model.refreshToken(
                                        for: record.id
                                    ),
                                    width: 34
                                )
                            } else {
                                Image(systemName: record.profile.kind.symbol)
                                    .frame(width: 34, height: 44)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .fontDesign(.serif)
                                    .foregroundStyle(PPColor.textPrimary)
                                    .lineLimit(1)
                                Text(continueReason(for: record).localizedUI)
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: PPSpacing.small)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PPColor.cyan)
                        }
                        .frame(minHeight: 50)
                        .padding(.horizontal, PPSpacing.small)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index
                        < min(additionalContinueWorkRecords.count, 3) - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                            .padding(.leading, 50)
                    }
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .accessibilityIdentifier("continueWorkSection")
    }

    private var dueDeskSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionEyebrow(text: "DUE DESK")
                    Text("Needs your attention")
                        .font(.title3.bold())
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                }
                Spacer()
                Text("\(dueDeskRecords.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(
                    Array(dueDeskRecords.prefix(3).enumerated()),
                    id: \.element.id
                ) { index, record in
                    Button {
                        onOpen(
                            DocumentRoute(
                                recordID: record.id,
                                pageIndex: record.lastPageIndex
                            )
                        )
                    } label: {
                        HStack(spacing: PPSpacing.medium) {
                            let isOverdue = record.dueAt.map {
                                $0 < Calendar.current.startOfDay(
                                    for: Date()
                                )
                            } ?? false
                            ToolSymbolPlate(
                                symbol: isOverdue
                                    ? "calendar.badge.exclamationmark"
                                    : "calendar",
                                tint: isOverdue
                                    ? .red
                                    : PPColor.amber,
                                size: 40
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.displayName)
                                    .font(
                                        .subheadline.weight(.semibold)
                                    )
                                    .fontDesign(.serif)
                                    .foregroundStyle(
                                        PPColor.textPrimary
                                    )
                                    .lineLimit(1)
                                Text(dueDeskReason(record))
                                    .font(.caption)
                                    .foregroundStyle(
                                        isOverdue
                                            ? Color.red
                                            : PPColor.textSecondary
                                    )
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(PPColor.accent)
                        }
                        .padding(.horizontal, PPSpacing.small)
                        .frame(minHeight: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < min(dueDeskRecords.count, 3) - 1 {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                            .padding(.leading, 54)
                    }
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
        .accessibilityIdentifier("dueDesk")
    }

    private var searchScopeControl: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    ForEach(LibrarySearchScope.allCases) { scope in
                        Button {
                            searchScope = scope
                        } label: {
                            Label(
                                scope.title.localizedUI,
                                systemImage: searchScope == scope
                                    ? "checkmark"
                                    : searchScopeSymbol(scope)
                            )
                        }
                    }
                } label: {
                    HStack(spacing: PPSpacing.small) {
                        Label(
                            searchScope.title.localizedUI,
                            systemImage: searchScopeSymbol(searchScope)
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 48)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.cyan.opacity(0.72))
                            .frame(height: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search scope")
                .accessibilityValue(searchScope.title.localizedUI)
            } else {
                Picker(
                    "Search scope",
                    selection: $searchScope
                ) {
                    ForEach(LibrarySearchScope.allCases) { scope in
                        Text(scope.title.localizedUI)
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .accessibilityIdentifier("librarySearchScope")
    }

    private func searchScopeSymbol(
        _ scope: LibrarySearchScope
    ) -> String {
        switch scope {
        case .all: return "square.grid.2x2"
        case .documents: return "doc.on.doc"
        case .tools: return "slider.horizontal.3"
        }
    }

    private var pageSearchSummary: some View {
        let summary = libraryPageSearchSnapshot.summary

        return Group {
            if isSearchingPageIndex {
                HStack(spacing: PPSpacing.medium) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PPColor.cyan)
                        .frame(width: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Searching every page")
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                        Text("Checking the private on-device index")
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PPSpacing.medium)
                .frame(minHeight: 62)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(PPColor.cyan.opacity(0.72))
                        .frame(width: 3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Searching every page in the private on-device index"
                )
            } else {
                pageSearchResultButton(summary)
            }
        }
        .background(PPColor.cyan.opacity(0.07))
        .clipShape(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityIdentifier("libraryPageSearch")
    }

    private func pageSearchResultButton(
        _ summary: LibraryPageSearchSummary
    ) -> some View {
        Button {
            isPresentingLibraryPageSearch = true
            recordLibrarySearch(appliedSearchText)
        } label: {
            HStack(spacing: PPSpacing.medium) {
                ToolSymbolPlate(
                    symbol: "text.page.badge.magnifyingglass",
                    tint: PPColor.cyan,
                    size: 42
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Search every matching page")
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        summary.isLimited
                            ? AppLocalization.format(
                                "First %lld pages across %lld PDFs",
                                summary.pageCount,
                                summary.documentCount
                            )
                            : AppLocalization.format(
                                "%lld pages across %lld PDFs",
                                summary.pageCount,
                                summary.documentCount
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .monospacedDigit()
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.cyan)
            }
            .padding(.horizontal, PPSpacing.medium)
            .frame(minHeight: 62)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(PPColor.cyan)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var continueWorkRecords: [DocumentRecord] {
        model.workingDocuments
            .filter {
                $0.taskCheckpoint != nil
                    || ($0.lastViewedAt != nil && $0.lastPageIndex > 0)
                    || $0.dueAt != nil
                    || (
                        $0.deliveryReceipt != nil
                            && !$0.hasCurrentDeliveryReceipt
                    )
            }
            .sorted { lhs, rhs in
                let left = nextUpPriority(lhs)
                let right = nextUpPriority(rhs)
                if left != right {
                    return left > right
                }
                return (lhs.lastViewedAt ?? lhs.modifiedAt)
                    > (rhs.lastViewedAt ?? rhs.modifiedAt)
            }
    }

    private var additionalContinueWorkRecords: [DocumentRecord] {
        continueWorkRecords.filter {
            $0.id != homePriorityRecord?.id
        }
    }

    private var homePriorityRecord: DocumentRecord? {
        model.workingDocuments
            .filter {
                $0.profile.isLocked
                    || $0.taskCheckpoint != nil
                    || $0.dueAt != nil
                    || model.needsAttention($0)
                    || (
                        model.taskPackageRecommendation(
                            for: $0
                        ).map {
                            $0.task != .safeShare
                        } ?? false
                    )
                    || (
                        $0.deliveryReceipt != nil
                            && !$0.hasCurrentDeliveryReceipt
                    )
                    || (
                        $0.lastViewedAt != nil
                            && $0.lastPageIndex > 0
                    )
            }
            .max { lhs, rhs in
                let left = homePriorityScore(lhs)
                let right = homePriorityScore(rhs)
                if left != right {
                    return left < right
                }
                let leftDate = lhs.lastViewedAt ?? lhs.modifiedAt
                let rightDate = rhs.lastViewedAt ?? rhs.modifiedAt
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                return lhs.id.uuidString > rhs.id.uuidString
            }
    }

    private func homePriorityScore(_ record: DocumentRecord) -> Int {
        if record.deliveryReceipt != nil,
           !record.hasCurrentDeliveryReceipt {
            return 50
        }
        if record.profile.isLocked {
            return 45
        }
        if record.taskCheckpoint != nil {
            return 40
        }
        if let dueAt = record.dueAt {
            return dueAt < Calendar.current.startOfDay(for: Date())
                ? 35
                : 30
        }
        if model.taskPackageRecommendation(for: record).map({
            $0.task != .safeShare
        }) ?? false {
            return 25
        }
        if model.needsAttention(record) {
            return 20
        }
        return 10
    }

    private func homePriorityRoute(
        for record: DocumentRecord
    ) -> DocumentRoute {
        if record.deliveryReceipt != nil,
           !record.hasCurrentDeliveryReceipt {
            return DocumentRoute(
                recordID: record.id,
                quickTask: .safeShare
            )
        }
        if let recommendation =
            model.taskPackageRecommendation(for: record) {
            return DocumentRoute(
                recordID: record.id,
                pageIndex: record.taskCheckpoint?.pageIndex
                    ?? record.lastPageIndex,
                quickTask: recommendation.task
            )
        }
        return continueRoute(for: record)
    }

    private func nextUpPriority(
        _ record: DocumentRecord
    ) -> Int {
        if record.deliveryReceipt != nil,
           !record.hasCurrentDeliveryReceipt {
            return 5
        }
        if record.taskCheckpoint != nil {
            return 4
        }
        if let dueAt = record.dueAt {
            return dueAt < Calendar.current.startOfDay(for: Date())
                ? 3
                : 2
        }
        return 1
    }

    private var dueDeskRecords: [DocumentRecord] {
        model.workingDocuments
            .filter {
                guard let dueAt = $0.dueAt else { return false }
                let endOfToday = Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: Calendar.current.startOfDay(for: Date())
                    ) ?? Date()
                return dueAt < endOfToday
                    && $0.workflowStatus != .ready
                    && $0.workflowStatus != .archived
            }
            .sorted {
                guard let lhs = $0.dueAt, let rhs = $1.dueAt else {
                    return $0.dueAt != nil
                }
                if lhs != rhs {
                    return lhs < rhs
                }
                return $0.modifiedAt > $1.modifiedAt
            }
    }

    private func dueDeskReason(_ record: DocumentRecord) -> String {
        guard let dueAt = record.dueAt else { return "" }
        let calendar = Calendar.current
        if dueAt < calendar.startOfDay(for: Date()) {
            let days = max(
                1,
                calendar.dateComponents(
                    [.day],
                    from: dueAt,
                    to: calendar.startOfDay(for: Date())
                ).day ?? 1
            )
            return "\(days)d overdue · \(record.workflowStatus.title.localizedUI)"
        }
        return "Due today · \(record.workflowStatus.title.localizedUI)"
    }

    private func continueRoute(
        for record: DocumentRecord
    ) -> DocumentRoute {
        if let checkpoint = record.taskCheckpoint {
            return DocumentRoute(
                recordID: record.id,
                pageIndex: checkpoint.pageIndex,
                quickTask: checkpoint.stage.quickTask
            )
        }
        return DocumentRoute(
            recordID: record.id,
            pageIndex: record.lastPageIndex
        )
    }

    private func continueReason(
        for record: DocumentRecord
    ) -> String {
        if record.deliveryReceipt != nil,
           !record.hasCurrentDeliveryReceipt {
            return "Changed after receipt · verify again"
        }
        if let checkpoint = record.taskCheckpoint {
            return checkpoint.resumeReason
        }
        if record.dueAt != nil {
            return dueDeskReason(record)
        }
        return AppLocalization.format(
            "Resume reading · page %lld",
            record.lastPageIndex + 1
        )
    }

    private var taskPackagesSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                SectionEyebrow(
                    text: isSearchingTools ? "TASK RESULTS" : "SUGGESTED"
                )
                Text(
                    isSearchingTools
                        ? "\(matchingTaskPackages.count) matching path\(matchingTaskPackages.count == 1 ? "" : "s")"
                        : model.workingDocuments.isEmpty
                            ? "Choose an outcome"
                            : "Choose a result"
                )
                .font(.headline)
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .monospacedDigit()
                }
                Spacer()
                Text("\(visibleTaskPackages.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .monospacedDigit()
            }

            taskPackagePathList

            if !isSearchingTools,
               hiddenTaskPackageCount > 0 || showsAllTaskPackages {
                Button {
                    withAnimation(
                        reduceMotion ? nil : .snappy(duration: 0.2)
                    ) {
                        showsAllTaskPackages.toggle()
                    }
                } label: {
                    HStack {
                        Text(
                            showsAllTaskPackages
                                ? "Show fewer paths"
                                : AppLocalization.format(
                                    "Show %lld more paths",
                                    hiddenTaskPackageCount
                                )
                        )
                        Spacer()
                        Image(
                            systemName: showsAllTaskPackages
                                ? "chevron.up"
                                : "chevron.down"
                        )
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.cyan)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("toggleAllTaskPaths")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("taskPackagesSection")
    }

    @ViewBuilder
    private var taskPackagePathList: some View {
        if !dynamicTypeSize.isAccessibilitySize,
           !isSearchingTools {
            LazyVGrid(
                columns: taskPackageColumns,
                alignment: .leading,
                spacing: PPSpacing.small
            ) {
                ForEach(
                    Array(visibleTaskPackages.enumerated()),
                    id: \.element.id
                ) { index, package in
                    taskPackageButton(
                        package,
                        featured: index == 0,
                        gridTile: true
                    )
                }
            }
        } else if let featured = visibleTaskPackages.first {
            let remaining = Array(visibleTaskPackages.dropFirst())
            if horizontalSizeClass == .regular,
               !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: PPSpacing.xLarge) {
                    taskPackageButton(featured, featured: true)
                        .frame(maxWidth: 340)
                    VStack(spacing: 0) {
                        ForEach(remaining) { package in
                            taskPackageButton(package)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: PPSpacing.medium) {
                    taskPackageButton(
                        featured,
                        featured: !isSearchingTools
                    )
                    VStack(spacing: 0) {
                        ForEach(remaining) { package in
                            taskPackageButton(package)
                        }
                    }
                }
            }
        }
    }

    private var taskPackageColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: PPSpacing.small),
            count: count
        )
    }

    private func taskPackageButton(
        _ package: PDFTaskPackage,
        featured: Bool = false,
        gridTile: Bool = false
    ) -> some View {
        TaskPackageButton(
            package: package,
            tint: taskPackageTint(package),
            isFeatured: featured,
            isGridTile: gridTile
        ) {
            start(package)
        }
    }

    private var pdfToolsSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    )
                )
                : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

            headerLayout {
                VStack(alignment: .leading, spacing: 3) {
                    if isSearchingTools {
                        SectionEyebrow(text: "TOOL RESULTS")
                    }
                    Text(
                        isSearchingTools
                            ? "\(matchingQuickTasks.count) matching tool\(matchingQuickTasks.count == 1 ? "" : "s")"
                            : "PDF tools"
                    )
                    .font(.headline)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isSearchingTools {
                    HStack(spacing: PPSpacing.small) {
                        Button {
                            withAnimation(
                                reduceMotion
                                    ? nil
                                    : .spring(
                                        response: 0.38,
                                        dampingFraction: 0.9
                                    )
                            ) {
                                showsAllPDFTools.toggle()
                            }
                        } label: {
                            Label(
                                showsAllPDFTools ? "Show less" : "Show all",
                                systemImage: showsAllPDFTools
                                    ? "chevron.up"
                                    : "chevron.down"
                            )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PPColor.accent)
                                .frame(minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            showsAllPDFTools
                                ? "Show quick PDF tools only"
                                : "Show all PDF tools"
                        )
                        .accessibilityIdentifier("toggleAllPDFTools")

                        Menu {
                            ForEach(
                                PDFQuickTask.allCases.filter(\.requiresDocument)
                            ) { task in
                                Button {
                                    toggleQuickAccess(task)
                                } label: {
                                    Label(
                                        task.title,
                                        systemImage: quickAccessTasks.contains(task)
                                            ? "checkmark"
                                            : task.symbol
                                    )
                                }
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Customize quick tools")
                        .help("Customize quick tools")
                    }
                }
            }

            if isSearchingTools {
                quickToolGrid(matchingQuickTasks)
            } else {
                toolGroup(title: "QUICK ACCESS", tasks: quickAccessTasks)

                if showsAllPDFTools {
                    ForEach(PDFQuickTaskGroup.allCases) { group in
                        let tasks = PDFQuickTask.allCases.filter {
                            $0.group == group
                                && !quickAccessTasks.contains($0)
                        }
                        if !tasks.isEmpty {
                            toolGroup(title: group.title, tasks: tasks)
                                .transition(
                                    .move(edge: .top).combined(with: .opacity)
                                )
                        }
                    }
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .accessibilityIdentifier("pdfToolsSection")
    }

    private func toolGroup(
        title: String,
        tasks: [PDFQuickTask]
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text(title.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.textSecondary)

            quickToolGrid(tasks)
        }
    }

    private func quickToolGrid(
        _ tasks: [PDFQuickTask]
    ) -> some View {
        LazyVGrid(
            columns: quickToolColumns,
            alignment: .leading,
            spacing: 0
        ) {
            ForEach(tasks) { task in
                quickToolButton(task)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
    }

    private var quickToolColumns: [GridItem] {
        let count: Int
        if dynamicTypeSize.isAccessibilitySize {
            count = 1
        } else if horizontalSizeClass == .regular {
            count = 4
        } else {
            count = 2
        }
        return Array(
            repeating: GridItem(.flexible(), spacing: 0),
            count: count
        )
    }

    private func quickToolButton(_ task: PDFQuickTask) -> some View {
        Button {
            start(task)
        } label: {
            HStack(alignment: .top, spacing: PPSpacing.small) {
                ToolSymbolPlate(
                    symbol: task.symbol,
                    tint: quickToolTint(task.group),
                    size: 34
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(task.detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.isAccessibilitySize ? 3 : 1
                        )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 78 : 54)
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.55))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(task.detail.localizedUI)
        .accessibilityIdentifier("quickTool-\(task.rawValue)")
    }

    private func quickToolTint(_ group: PDFQuickTaskGroup) -> Color {
        switch group {
        case .create: return PPColor.cyan
        case .pages: return PPColor.accent
        case .finish: return PPColor.mint
        case .convert: return PPColor.amber
        }
    }

    private func taskPackageTint(_ package: PDFTaskPackage) -> Color {
        switch package {
        case .prepareToSend: return PPColor.mint
        case .makeSearchable: return PPColor.cyan
        case .convertForWork: return PPColor.rose
        case .compressForEmail: return PPColor.accent
        case .redactAndProve: return PPColor.amber
        case .fixPages: return PPColor.cyan
        }
    }

    private func start(_ package: PDFTaskPackage) {
        taskStartFeedback += 1
        let eligible = eligibleDocuments(for: package)
        if eligible.isEmpty {
            start(package.defaultTask)
        } else if let record = eligible.first, eligible.count == 1 {
            open(
                model.task(for: package, record: record),
                recordID: record.id
            )
        } else {
            taskPackagePicker = package
        }
    }

    private func start(_ task: PDFQuickTask) {
        switch task {
        case .scanToPDF:
            beginScan()
        case .imagesToPDF:
            isPresentingPhotoPicker = true
        case .mergePDFs:
            isPresentingCombine = true
        case .compressPDF:
            isPresentingCompressionBatch = true
        case .splitPDF, .organizePages, .fillForms,
             .signPDF, .redactPDF, .protectPDF, .safeShare,
             .recognizeText, .exportText, .exportImages:
            let eligible = eligibleDocuments(for: task)
            if eligible.isEmpty {
                pendingImportTask = task
                isImportingFile = true
            } else if let record = eligible.first,
                      eligible.count == 1 {
                open(task, recordID: record.id)
            } else {
                documentPickerTask = task
            }
        }
    }

    private func open(_ task: PDFQuickTask, recordID: UUID) {
        onOpen(
            DocumentRoute(
                recordID: recordID,
                quickTask: task
            )
        )
    }

    private func quickTaskDocumentPicker(
        _ task: PDFQuickTask
    ) -> some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.detail.localizedUI)
                                .foregroundStyle(PPColor.textPrimary)
                            Text(
                                "\(eligibleDocuments(for: task).count) compatible PDF\(eligibleDocuments(for: task).count == 1 ? "" : "s")"
                            )
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(PPColor.textSecondary)
                        }
                    } icon: {
                        Image(systemName: task.symbol)
                            .foregroundStyle(quickToolTint(task.group))
                    }
                } footer: {
                    Text("Only compatible, unlocked PDFs are shown.")
                }

                Section("Choose a document") {
                    ForEach(eligibleDocuments(for: task)) { record in
                        Button {
                            documentPickerTask = nil
                            Task {
                                try? await Task.sleep(
                                    for: .milliseconds(180)
                                )
                                open(task, recordID: record.id)
                            }
                        } label: {
                            HStack(spacing: PPSpacing.medium) {
                                if !hideLibraryPreviews,
                                   let url = model.url(for: record.id) {
                                    PDFPageThumbnailView(
                                        url: url,
                                        pageIndex: 0,
                                        refreshToken: model.refreshToken(
                                            for: record.id
                                        ),
                                        width: 42
                                    )
                                } else {
                                    Image(systemName: "doc")
                                        .frame(width: 42, height: 54)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(PPColor.textPrimary)
                                        .lineLimit(2)
                                    Text(
                                        task.compatibilityNote(
                                            for: record
                                        ).localizedUI
                                    )
                                        .font(.caption)
                                        .foregroundStyle(PPColor.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PPColor.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            task.compatibilityNote(for: record)
                        )
                        .accessibilityIdentifier(
                            "quickTaskDocument-\(record.id.uuidString)"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PPColor.canvas)
            .navigationTitle(task.title.localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        documentPickerTask = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func taskPackageDocumentPicker(
        _ package: PDFTaskPackage
    ) -> some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    let eligible = eligibleDocuments(for: package)

                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        HStack(spacing: PPSpacing.medium) {
                            ToolSymbolPlate(
                                symbol: package.symbol,
                                tint: taskPackageTint(package),
                                size: 52
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.title.localizedUI)
                                    .font(.title3.bold())
                                    .fontDesign(.serif)
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(package.detail.localizedUI)
                                    .font(.subheadline)
                                    .foregroundStyle(PPColor.textSecondary)
                            }
                        }
                        .padding(PPSpacing.regular)
                        .ppPaper(cornerRadius: 14)

                        if package == .prepareToSend,
                           batchDeliveryDocuments.count >= 2 {
                            Button {
                                taskPackagePicker = nil
                                Task {
                                    try? await Task.sleep(
                                        for: .milliseconds(180)
                                    )
                                    isPresentingBatchDelivery = true
                                }
                            } label: {
                                HStack(spacing: PPSpacing.regular) {
                                    DocumentFan(
                                        records: batchDeliveryDocuments,
                                        urlFor: { model.url(for: $0) },
                                        refreshTokenFor: {
                                            model.refreshToken(for: $0)
                                        }
                                    )
                                    .scaleEffect(0.46)
                                    .frame(width: 92, height: 72)

                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {
                                        SectionEyebrow(text: "MULTIPLE PDFS")
                                        Text("Prepare several")
                                            .font(.headline)
                                            .fontDesign(.serif)
                                            .foregroundStyle(
                                                PPColor.textPrimary
                                            )
                                        Text(
                                            "Check and verify one at a time"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(
                                            PPColor.textSecondary
                                        )
                                    }
                                    Spacer(minLength: PPSpacing.small)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(PPColor.mint)
                                }
                                .frame(minHeight: 82)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, PPSpacing.medium)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(PPColor.border.opacity(0.58))
                                    .frame(height: 0.6)
                            }
                        }

                        VStack(spacing: PPSpacing.small) {
                            ForEach(eligible) { record in
                                let task = model.task(
                                    for: package,
                                    record: record
                                )
                                Button {
                                    taskPackagePicker = nil
                                    Task {
                                        try? await Task.sleep(
                                            for: .milliseconds(160)
                                        )
                                        open(task, recordID: record.id)
                                    }
                                } label: {
                                    HStack(spacing: PPSpacing.medium) {
                                        if !hideLibraryPreviews,
                                           let url = model.url(for: record.id) {
                                            PDFPageThumbnailView(
                                                url: url,
                                                pageIndex: 0,
                                                refreshToken: model.refreshToken(
                                                    for: record.id
                                                ),
                                                width: 44
                                            )
                                        } else {
                                            ToolSymbolPlate(
                                                symbol: record.profile.kind.symbol,
                                                tint: taskPackageTint(package),
                                                size: 44
                                            )
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(record.displayName)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(PPColor.textPrimary)
                                                .lineLimit(2)
                                            Text(task.title.localizedUI)
                                                .font(.caption)
                                                .foregroundStyle(
                                                    taskPackageTint(package)
                                                )
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(PPColor.textSecondary)
                                    }
                                    .padding(PPSpacing.medium)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if record.id != eligible.last?.id {
                                    Rectangle()
                                        .fill(PPColor.border.opacity(0.58))
                                        .frame(height: 0.6)
                                        .padding(.leading, 72)
                                }
                            }
                        }
                        .ppPaper(cornerRadius: 14, shadow: false)
                    }
                    .frame(maxWidth: 620)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Choose a PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        taskPackagePicker = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func eligibleDocuments(
        for task: PDFQuickTask
    ) -> [DocumentRecord] {
        model.workingDocuments.filter(task.supports)
    }

    private func eligibleDocuments(
        for package: PDFTaskPackage
    ) -> [DocumentRecord] {
        model.workingDocuments.filter(package.supports)
    }

    private var batchDeliveryDocuments: [DocumentRecord] {
        model.workingDocuments.filter {
            !$0.profile.isLocked
        }
    }

    private var quickAccessTasks: [PDFQuickTask] {
        let stored = savedQuickTools
            .split(separator: ",")
            .compactMap { PDFQuickTask(rawValue: String($0)) }
        var tasks = stored.isEmpty
            ? PDFQuickTaskPlanner.quickAccess(
                for: model.workingDocuments
            )
            : stored
        if !model.workingDocuments.isEmpty {
            tasks.removeAll { task in
                task.requiresDocument
                    && !model.workingDocuments.contains(
                        where: task.supports
                    )
            }
        }

        let prototypes = [
            PDFQuickTask.compressPDF,
            .mergePDFs
        ]
        tasks.removeAll { prototypes.contains($0) }
        for prototype in prototypes.reversed()
        where model.workingDocuments.isEmpty
            || !prototype.requiresDocument
            || model.workingDocuments.contains(
                where: prototype.supports
            ) {
            tasks.insert(prototype, at: 0)
        }

        for essential in [
            PDFQuickTask.safeShare
        ] where !tasks.contains(essential)
            && model.workingDocuments.contains(
                where: essential.supports
            ) {
            tasks.append(essential)
        }
        return Array(tasks.prefix(6))
    }

    private var visibleTaskPackages: [PDFTaskPackage] {
        if isSearchingTools {
            return matchingTaskPackages
        }
        return showsAllTaskPackages
            ? recommendedTaskPackages
            : Array(recommendedTaskPackages.prefix(3))
    }

    private var recommendedTaskPackages: [PDFTaskPackage] {
        PDFTaskPackagePlanner.homePackages(
            for: model.workingDocuments
        )
    }

    private var hiddenTaskPackageCount: Int {
        max(0, recommendedTaskPackages.count - 3)
    }

    private var matchingTaskPackages: [PDFTaskPackage] {
        guard searchesTools else { return [] }
        return PDFTaskPackage.allCases.filter {
            $0.matches(appliedSearchText)
        }
    }

    private var matchingQuickTasks: [PDFQuickTask] {
        guard searchesTools else { return [] }
        return PDFQuickTask.allCases.compactMap { task in
            task.matchScore(appliedSearchText).map { (task, $0) }
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.title < rhs.0.title
            }
            return lhs.1 > rhs.1
        }
        .map(\.0)
    }

    private var isSearchingTools: Bool {
        searchesTools
    }

    private var isSearching: Bool {
        !appliedSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var searchesTools: Bool {
        isSearching && searchScope != .documents
    }

    private func toggleQuickAccess(_ task: PDFQuickTask) {
        var tasks = quickAccessTasks
        if let index = tasks.firstIndex(of: task) {
            guard tasks.count > 2 else {
                model.noticeMessage = "Keep at least two quick tools"
                return
            }
            tasks.remove(at: index)
        } else {
            guard tasks.count < 6 else {
                model.noticeMessage = "Quick access holds up to six tools"
                return
            }
            tasks.append(task)
        }
        savedQuickTools = tasks.map(\.rawValue).joined(separator: ",")
    }

    private func importSelectedImages() {
        let items = selectedPhotoItems
        selectedPhotoItems = []

        Task {
            var images: [UIImage] = []
            images.reserveCapacity(items.count)
            for item in items {
                guard !Task.isCancelled,
                      let data = try? await item.loadTransferable(
                        type: Data.self
                      ),
                      data.count <= 24 * 1_024 * 1_024
                else { continue }
                let page = await Task.detached(priority: .userInitiated) {
                    Self.downsampledImage(from: data).map(
                        ScanPageImage.init(image:)
                    )
                }.value
                if let page {
                    images.append(page.image)
                }
            }

            guard !images.isEmpty else {
                model.present(PaperPathError.unreadableImage)
                return
            }
            scanReviewSession = ScanReviewSession(
                images: images,
                initialOptions: .original
            )
        }
    }

    nonisolated private static func downsampledImage(
        from data: Data
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private var searchAndFilters: some View {
        let filterLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return VStack(spacing: PPSpacing.medium) {
            filterLayout {
                filterMenu(
                    title: statusFilter?.title ?? "All stages",
                    symbol: statusFilter?.symbol ?? "tray.2"
                ) {
                    Button("All stages") { statusFilter = nil }
                    ForEach(DocumentWorkflowStatus.allCases) { status in
                        Button {
                            statusFilter = status
                            selectedSmartView = nil
                            selectedTag = nil
                        } label: {
                            Label(
                                status.title.localizedUI,
                                systemImage: status.symbol
                            )
                        }
                    }
                }

                filterMenu(
                    title: categoryFilter?.title ?? "All types",
                    symbol: categoryFilter?.symbol ?? "doc.on.doc"
                ) {
                    Button("All types") { categoryFilter = nil }
                    ForEach(DocumentCategory.allCases) { category in
                        Button {
                            categoryFilter = category
                            selectedSmartView = nil
                            selectedTag = nil
                        } label: {
                            Label(
                                category.title.localizedUI,
                                systemImage: category.symbol
                            )
                        }
                    }
                }

                if hasActiveFilters {
                    Button {
                        statusFilter = nil
                        categoryFilter = nil
                        selectedSmartView = nil
                        selectedTag = nil
                        searchText = ""
                        appliedSearchText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityLabel("Clear filters")
                }
            }
        }
        .dynamicTypeSize(.xSmall ... .accessibility2)
    }

    private var tagFilterRail: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack {
                SectionEyebrow(text: "TAGS")
                Spacer()
                if let selectedTag {
                    Button {
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .snappy(duration: 0.18)
                        ) {
                            self.selectedTag = nil
                        }
                    } label: {
                        Label(
                            "Clear \(selectedTag)",
                            systemImage: "xmark"
                        )
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityLabel("Clear tag filter")
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: PPSpacing.small) {
                    ForEach(availableTags, id: \.name) { entry in
                        let isSelected = selectedTag?
                            .caseInsensitiveCompare(entry.name)
                            == .orderedSame
                        Button {
                            withAnimation(
                                reduceMotion
                                    ? nil
                                    : .snappy(duration: 0.18)
                            ) {
                                selectedTag = isSelected
                                    ? nil
                                    : entry.name
                                if !isSelected {
                                    selectedSmartView = nil
                                    statusFilter = nil
                                    categoryFilter = nil
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(
                                    systemName: isSelected
                                        ? "tag.fill"
                                        : "tag"
                                )
                                Text(entry.name)
                                    .lineLimit(1)
                                Text("\(entry.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        isSelected
                                            ? Color.white.opacity(0.8)
                                            : PPColor.textSecondary
                                    )
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                isSelected
                                    ? Color.white
                                    : PPColor.textPrimary
                            )
                            .padding(.horizontal, PPSpacing.medium)
                            .frame(minHeight: 36)
                            .background(
                                isSelected
                                    ? PPColor.accent
                                    : PPColor.surface
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 7,
                                    style: .continuous
                                )
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: 7,
                                    style: .continuous
                                )
                                .stroke(
                                    isSelected
                                        ? Color.clear
                                        : PPColor.border.opacity(0.62),
                                    lineWidth: 0.6
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(
                            isSelected ? "Selected" : ""
                        )
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("libraryTagFilters")
    }

    private func filterMenu<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                Text(title.localizedUI)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: PPSpacing.small)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(PPColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, PPSpacing.small)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.7))
                    .frame(height: 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    private var promiseCard: some View {
        VStack(spacing: PPSpacing.large) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    PPIllustration(kind: .intake, width: 210)
                        .frame(maxWidth: .infinity)
                    promiseCopy
                }
            } else {
                HStack(alignment: .center, spacing: PPSpacing.regular) {
                    PPIllustration(kind: .intake, width: 190)
                    promiseCopy
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: PPSpacing.medium) {
                    importButton
                    scanButton(expands: true)
                }
            } else {
                HStack(spacing: PPSpacing.medium) {
                    importButton
                    scanButton(expands: false)
                }
            }

            PrivacyProof()
        }
        .padding(PPSpacing.large)
        .ppPaper(cornerRadius: 14)
    }

    private var promiseCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start with the outcome")
                .font(.title3.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
            Text("Choose a task first. PaperPath asks for a PDF when needed.")
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importButton: some View {
        Button {
            isImportingFile = true
        } label: {
            Label("Import PDF", systemImage: "doc.badge.plus")
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .keyboardShortcut("o", modifiers: .command)
        .accessibilityIdentifier("importPDFButton")
    }

    private func scanButton(expands: Bool) -> some View {
        Button {
            beginScan()
        } label: {
            Label("Scan", systemImage: "viewfinder")
                .frame(maxWidth: expands ? .infinity : nil)
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .accessibilityIdentifier("scanButton")
    }

    private func beginScan() {
        guard VNDocumentCameraViewController.isSupported else {
            model.present(PaperPathError.cameraUnavailable)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            model.presentCameraPermissionDenied()
        case .authorized, .notDetermined:
            isPresentingScanner = true
        @unknown default:
            model.present(PaperPathError.cameraUnavailable)
        }
    }

    @ViewBuilder
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionEyebrow(
                        text: isSearching
                            ? "MATCHING PDFS"
                            : "WORKING COPIES"
                    )
                    Text(libraryTitle.localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .dynamicTypeSize(.xSmall ... .accessibility2)
                }
                Spacer()
                if !model.workingDocuments.isEmpty || isSearching {
                    Text("\(filteredDocuments.count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                        .contentTransition(.numericText())
                        .dynamicTypeSize(.xSmall ... .accessibility1)

                    Button {
                        setDocumentSelection(
                            active: !isSelectingDocuments
                        )
                    } label: {
                        Image(
                            systemName: isSelectingDocuments
                                ? "checkmark.circle.fill"
                                : "checkmark.circle"
                        )
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        isSelectingDocuments
                            ? PPColor.accent
                            : PPColor.textSecondary
                    )
                    .accessibilityLabel(
                        isSelectingDocuments
                            ? "Finish selecting documents"
                            : "Select documents"
                    )
                    .accessibilityIdentifier("selectDocuments")

                    Menu {
                        ForEach(LibrarySort.allCases) { sort in
                            Button {
                                savedLibrarySort = sort.rawValue
                            } label: {
                                Label(
                                    sort.title.localizedUI,
                                    systemImage: sort == librarySort
                                        ? "checkmark"
                                        : sort.symbol
                                )
                            }
                        }
                        Divider()
                        Menu {
                            Button {
                                statusFilter = nil
                            } label: {
                                Label(
                                    "All stages",
                                    systemImage: statusFilter == nil
                                        ? "checkmark"
                                        : "tray.2"
                                )
                            }
                            ForEach(DocumentWorkflowStatus.allCases) {
                                status in
                                Button {
                                    statusFilter = status
                                    selectedTag = nil
                                    selectedSmartView = nil
                                } label: {
                                    Label(
                                        status.title.localizedUI,
                                        systemImage: statusFilter == status
                                            ? "checkmark"
                                            : status.symbol
                                    )
                                }
                            }
                        } label: {
                            Label(
                                statusFilter?.title ?? "Stage",
                                systemImage: statusFilter?.symbol ?? "tray.2"
                            )
                        }
                        Menu {
                            Button {
                                categoryFilter = nil
                            } label: {
                                Label(
                                    "All types",
                                    systemImage: categoryFilter == nil
                                        ? "checkmark"
                                        : "doc.on.doc"
                                )
                            }
                            ForEach(DocumentCategory.allCases) { category in
                                Button {
                                    categoryFilter = category
                                    selectedTag = nil
                                    selectedSmartView = nil
                                } label: {
                                    Label(
                                        category.title.localizedUI,
                                        systemImage:
                                            categoryFilter == category
                                                ? "checkmark"
                                                : category.symbol
                                    )
                                }
                            }
                        } label: {
                            Label(
                                categoryFilter?.title ?? "Type",
                                systemImage:
                                    categoryFilter?.symbol ?? "doc.on.doc"
                            )
                        }
                        if !availableTags.isEmpty {
                            Menu {
                                Button {
                                    selectedTag = nil
                                } label: {
                                    Label(
                                        "All tags",
                                        systemImage: selectedTag == nil
                                            ? "checkmark"
                                            : "tag"
                                    )
                                }
                                ForEach(availableTags, id: \.name) { tag in
                                    Button {
                                        selectedTag = tag.name
                                        statusFilter = nil
                                        categoryFilter = nil
                                        selectedSmartView = nil
                                    } label: {
                                        Label {
                                            Text(
                                                "\(tag.name) (\(tag.count))"
                                            )
                                        } icon: {
                                            Image(
                                                systemName: selectedTag
                                                    == tag.name
                                                    ? "checkmark"
                                                    : "tag"
                                            )
                                        }
                                    }
                                }
                            } label: {
                                Label(
                                    selectedTag ?? "Tags",
                                    systemImage: "tag"
                                )
                            }
                        }
                        if hasActiveFilters {
                            Button {
                                statusFilter = nil
                                categoryFilter = nil
                                selectedTag = nil
                                selectedSmartView = nil
                            } label: {
                                Label(
                                    "Clear filters",
                                    systemImage: "line.3.horizontal.decrease.circle"
                                )
                            }
                        }
                        Divider()
                        Button {
                            savedLibraryDensity =
                                LibraryDensity.comfortable.rawValue
                        } label: {
                            Label(
                                "Comfortable rows",
                                systemImage: libraryDensity
                                    == .comfortable
                                    ? "checkmark"
                                    : LibraryDensity.comfortable.symbol
                            )
                        }
                        Button {
                            savedLibraryDensity =
                                LibraryDensity.compact.rawValue
                        } label: {
                            Label(
                                "Compact rows",
                                systemImage: libraryDensity == .compact
                                    ? "checkmark"
                                    : LibraryDensity.compact.symbol
                            )
                        }
                        Divider()
                        ForEach(LibraryViewMode.allCases) { mode in
                            Button {
                                withAnimation(
                                    reduceMotion
                                        ? nil
                                        : .snappy(duration: 0.22)
                                ) {
                                    savedLibraryViewMode = mode.rawValue
                                }
                            } label: {
                                Label(
                                    mode.title.localizedUI,
                                    systemImage: mode == libraryViewMode
                                        ? "checkmark"
                                        : mode.symbol
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityLabel(
                        AppLocalization.format(
                            "Library display: %@",
                            librarySort.title.localizedUI
                        )
                    )
                    .accessibilityIdentifier("libraryDisplay")
                }
            }

            if model.isLoading {
                loadingLibrary
            } else if model.workingDocuments.isEmpty && !isSearching {
                emptyLibrary
            } else if filteredDocuments.isEmpty {
                emptyResults
            } else {
                libraryDocumentGroups(filteredDocuments)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryDocumentsSection")
    }

    @ViewBuilder
    private func libraryDocumentGroups(
        _ records: [DocumentRecord]
    ) -> some View {
        let pinned = records.filter(\.isPinned)
        let unpinned = records.filter { !$0.isPinned }
        let today = unpinned.filter {
            Calendar.current.isDateInToday(
                documentActivityDate($0)
            )
        }
        let earlier = unpinned.filter {
            !Calendar.current.isDateInToday(
                documentActivityDate($0)
            )
        }

        if effectiveLibraryViewMode == .board {
            documentsContent(records)
        } else if !hasActiveFilters {
            if !pinned.isEmpty {
                documentGroup(
                    title: "Pinned",
                    symbol: "pin.fill",
                    records: pinned,
                    tint: PPColor.accent
                )
            }
            if !today.isEmpty {
                documentGroup(
                    title: "Today",
                    symbol: "sun.max",
                    records: today,
                    tint: PPColor.cyan
                )
            }
            if !earlier.isEmpty {
                documentGroup(
                    title: "Earlier",
                    symbol: "calendar",
                    records: earlier,
                    tint: PPColor.textSecondary
                )
            }
        } else {
            documentsContent(records)
        }
    }

    private func documentActivityDate(
        _ record: DocumentRecord
    ) -> Date {
        max(
            record.modifiedAt,
            record.lastViewedAt ?? record.importedAt
        )
    }

    private func documentGroup(
        title: String,
        symbol: String,
        records: [DocumentRecord],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title.localizedUI.uppercased())
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Spacer()
                Text("\(records.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 2)

            documentsContent(records)
        }
    }

    @ViewBuilder
    private func documentsContent(
        _ records: [DocumentRecord]
    ) -> some View {
        if effectiveLibraryViewMode == .grid {
            documentsGrid(records)
        } else if effectiveLibraryViewMode == .board {
            workflowBoard(records)
        } else {
            documentsList(records)
        }
    }

    private func workflowBoard(
        _ records: [DocumentRecord]
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: PPSpacing.large) {
                ForEach(DocumentWorkflowStatus.allCases) { status in
                    workflowColumn(
                        status: status,
                        records: records.filter {
                            $0.workflowStatus == status
                        }
                    )
                }
            }
            .padding(.horizontal, 1)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("workflowBoard")
    }

    private func workflowColumn(
        status: DocumentWorkflowStatus,
        records: [DocumentRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: status.symbol)
                    .foregroundStyle(workflowTint(status))
                Text(status.title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                Spacer()
                Text("\(records.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.horizontal, 2)
            .frame(height: 34)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(workflowTint(status).opacity(0.42))
                    .frame(height: 2)
            }

            if records.isEmpty {
                VStack(spacing: PPSpacing.small) {
                    Image(systemName: status.symbol)
                    Text("No documents")
                }
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 116)
                .background(PPColor.surfaceMuted.opacity(0.55))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous
                    )
                )
            } else {
                ForEach(records) { record in
                    workflowCard(record)
                }
            }
        }
        .frame(width: 226)
    }

    private func workflowCard(
        _ record: DocumentRecord
    ) -> some View {
        let isCurrent = selectedRecordID == record.id

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(alignment: .top, spacing: PPSpacing.small) {
                Button {
                    if isSelectingDocuments {
                        toggleDocumentSelection(record.id)
                    } else {
                        onOpen(
                            DocumentRoute(
                                recordID: record.id,
                                pageIndex: record.lastPageIndex
                            )
                        )
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: record.profile.kind.symbol
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.cyan)
                            Text(record.displayName)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(2)
                        }
                        Text(record.subtitle)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isSelectingDocuments {
                    Image(
                        systemName: selectedDocumentIDs.contains(record.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .foregroundStyle(
                        selectedDocumentIDs.contains(record.id)
                            ? PPColor.accent
                            : PPColor.textSecondary
                    )
                } else {
                    Menu {
                        documentActions(for: record)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                }
            }

            HStack(spacing: 6) {
                if record.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(PPColor.accent)
                }
                if let dueAt = record.dueAt {
                    Label(
                        dueDateTitle(dueAt),
                        systemImage: "calendar"
                    )
                    .foregroundStyle(dueDateTint(dueAt))
                }
                if record.privateNote != nil {
                    Image(systemName: "note.text")
                        .foregroundStyle(PPColor.amber)
                }
                Spacer()
                if let tag = record.tags.first {
                    Text("#\(tag)")
                        .foregroundStyle(PPColor.accent)
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.semibold))
        }
        .padding(PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    selectedDocumentIDs.contains(record.id) || isCurrent
                        ? PPColor.accent
                        : PPColor.border.opacity(0.62),
                    lineWidth:
                        selectedDocumentIDs.contains(record.id) || isCurrent
                        ? 1.5
                        : 0.6
                )
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(PPColor.rose)
                    .frame(width: 2)
                    .padding(.vertical, PPSpacing.small)
            }
        }
    }

    private func workflowTint(
        _ status: DocumentWorkflowStatus
    ) -> Color {
        switch status {
        case .inbox: return PPColor.textSecondary
        case .reviewing: return PPColor.cyan
        case .ready: return PPColor.mint
        case .archived: return PPColor.accent
        }
    }

    private func documentsGrid(
        _ records: [DocumentRecord]
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 154, maximum: 226),
                    spacing: PPSpacing.medium,
                    alignment: .top
                )
            ],
            alignment: .leading,
            spacing: PPSpacing.medium
        ) {
            ForEach(records) { record in
                documentGridCard(record)
            }
        }
    }

    private func documentGridCard(
        _ record: DocumentRecord
    ) -> some View {
        let textMatch = appliedSearchText.isEmpty
            ? nil
            : model.matchingText(
                recordID: record.id,
                query: appliedSearchText
            )
        let recommendation = model.taskPackageRecommendation(
            for: record
        )

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button {
                    if isSelectingDocuments {
                        toggleDocumentSelection(record.id)
                    } else {
                        onOpen(
                            DocumentRoute(
                                recordID: record.id,
                                pageIndex: textMatch?.pageIndex
                            )
                        )
                    }
                } label: {
                    VStack(spacing: PPSpacing.small) {
                        ZStack(alignment: .bottomLeading) {
                            if !hideLibraryPreviews,
                               let url = model.url(for: record.id) {
                                PDFPageThumbnailView(
                                    url: url,
                                    pageIndex: 0,
                                    refreshToken: model.refreshToken(
                                        for: record.id
                                    ),
                                    width: 94
                                )
                                .shadow(
                                    color: .black.opacity(0.13),
                                    radius: 5,
                                    y: 3
                                )
                            } else {
                                RoundedRectangle(
                                    cornerRadius: 7,
                                    style: .continuous
                                )
                                .fill(PPColor.surfaceMuted)
                                .frame(width: 94, height: 121)
                                .overlay {
                                    Image(
                                        systemName: record.profile.kind.symbol
                                    )
                                    .font(.title2)
                                    .foregroundStyle(PPColor.cyan)
                                }
                            }

                            if record.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(PPColor.surface)
                                    .frame(width: 25, height: 25)
                                    .background(PPColor.accent)
                                    .clipShape(Circle())
                                    .offset(x: -8, y: 5)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 132)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayName)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(2)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )

                            HStack(spacing: 5) {
                                Text(record.subtitle)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(
                                    systemName:
                                        record.workflowStatus.symbol
                                )
                            }
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)

                            if let tag = record.tags.first {
                                Label(
                                    tag,
                                    systemImage: "tag.fill"
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PPColor.accent)
                                .lineLimit(1)
                            }

                            if let dueAt = record.dueAt {
                                Label(
                                    dueDateTitle(dueAt),
                                    systemImage: "calendar"
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(dueDateTint(dueAt))
                                .lineLimit(1)
                            }

                            if let textMatch {
                                Label(
                                    "Match · p\(textMatch.pageIndex + 1)",
                                    systemImage: "text.magnifyingglass"
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PPColor.accent)
                                .lineLimit(1)
                            } else if let recommendation {
                                Label(
                                    recommendation.title.localizedUI,
                                    systemImage:
                                        recommendation.task.symbol
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(
                                    taskPackageTint(
                                        recommendation.package
                                    )
                                )
                                .lineLimit(1)
                            }
                        }
                    }
                    .padding(PPSpacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "documentGrid-\(record.id.uuidString)"
                )

                if isSelectingDocuments {
                    Image(
                        systemName: selectedDocumentIDs.contains(record.id)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        selectedDocumentIDs.contains(record.id)
                            ? PPColor.accent
                            : PPColor.textSecondary
                    )
                    .padding(PPSpacing.small)
                    .accessibilityHidden(true)
                } else {
                    Menu {
                        documentActions(for: record)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .accessibilityLabel(
                        "More actions for \(record.displayName)"
                    )
                }
            }
        }
        .frame(minHeight: 218, alignment: .top)
        .ppPaper(cornerRadius: 8, shadow: false)
        .overlay {
            if selectedDocumentIDs.contains(record.id)
                || selectedRecordID == record.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PPColor.accent, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .leading) {
            if selectedRecordID == record.id {
                Rectangle()
                    .fill(PPColor.rose)
                    .frame(width: 2)
                    .padding(.vertical, PPSpacing.medium)
            }
        }
        .contextMenu {
            if !isSelectingDocuments {
                documentActions(for: record)
            }
        }
    }

    private func documentsList(_ records: [DocumentRecord]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(records) { record in
                let recommendation = model.taskPackageRecommendation(
                    for: record
                )
                let textMatch = appliedSearchText.isEmpty
                    ? nil
                    : model.matchingText(
                        recordID: record.id,
                        query: appliedSearchText
                    )

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        Button {
                            if isSelectingDocuments {
                                toggleDocumentSelection(record.id)
                            } else {
                                onOpen(
                                    DocumentRoute(
                                        recordID: record.id,
                                        pageIndex: textMatch?.pageIndex
                                    )
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                DocumentRow(
                                    record: record,
                                    url: model.url(for: record.id),
                                    refreshToken: model.refreshToken(for: record.id),
                                    isCompact: libraryDensity == .compact,
                                    showsDisclosure: false
                                )
                                .padding(.leading, PPSpacing.small)
                                .padding(.trailing, PPSpacing.small)

                                if let textMatch {
                                    searchEvidence(textMatch)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "documentRow-\(record.id.uuidString)"
                        )
                        .accessibilityHint(
                            isSelectingDocuments
                                ? (
                                    selectedDocumentIDs.contains(record.id)
                                        ? "Deselect document"
                                        : "Select document"
                                )
                                : "Open document"
                        )

                        if isSelectingDocuments {
                            Image(
                                systemName: selectedDocumentIDs
                                    .contains(record.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .font(.title3)
                            .foregroundStyle(
                                selectedDocumentIDs.contains(record.id)
                                    ? PPColor.accent
                                    : PPColor.textSecondary
                            )
                            .frame(width: 44, height: 44)
                            .padding(.top, PPSpacing.xSmall)
                            .padding(.trailing, 2)
                            .accessibilityHidden(true)
                        } else {
                            Menu {
                                documentActions(for: record)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(PPColor.textSecondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, PPSpacing.xSmall)
                            .padding(.trailing, 2)
                            .accessibilityLabel(
                                "More actions for \(record.displayName)"
                            )
                            .accessibilityIdentifier(
                                "documentMenu-\(record.id.uuidString)"
                            )
                        }
                    }

                    if let recommendation,
                       !isSelectingDocuments {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                            .padding(.leading, 66)

                        DocumentTaskShortcut(
                            recommendation: recommendation,
                            tint: taskPackageTint(
                                recommendation.package
                            )
                        ) {
                            open(
                                recommendation.task,
                                recordID: record.id
                            )
                        }
                    }
                }
                .background(
                    selectedDocumentIDs.contains(record.id)
                        ? PPColor.accent.opacity(0.08)
                        : (
                            selectedRecordID == record.id
                                ? PPColor.rose.opacity(0.045)
                                : Color.clear
                        )
                )
                .overlay(alignment: .leading) {
                    if selectedRecordID == record.id {
                        Rectangle()
                            .fill(PPColor.rose)
                            .frame(width: 2)
                            .padding(.vertical, PPSpacing.medium)
                    } else if let recommendation,
                       !isSelectingDocuments {
                        Rectangle()
                            .fill(
                                taskPackageTint(
                                    recommendation.package
                                ).opacity(0.58)
                            )
                            .frame(width: 2)
                            .padding(.vertical, PPSpacing.medium)
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.58))
                        .frame(height: 0.6)
                        .padding(.leading, 66)
                }
                .contextMenu {
                    if !isSelectingDocuments {
                        documentActions(for: record)
                    }
                }
            }
        }
        .background(PPColor.surface.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
    }

    private var documentSelectionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                Label(
                    "\(selectedDocumentIDs.count) selected",
                    systemImage: "checkmark.circle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .contentTransition(.numericText())

                Spacer(minLength: PPSpacing.small)

                if selectedDocumentIDs.count
                    < filteredDocuments.count {
                    Button("Select All") {
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .snappy(duration: 0.18)
                        ) {
                            selectedDocumentIDs = Set(
                                filteredDocuments.map(\.id)
                            )
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.accent)
                }

                Button {
                    selectedDocumentIDs.removeAll()
                } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityLabel("Clear selection")

                Button {
                    setDocumentSelection(active: false)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
                .accessibilityLabel("Finish selecting")
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.top, PPSpacing.xSmall)

            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)

            HStack(spacing: 0) {
                Button {
                    let recordIDs = selectedDocumentIDs
                    let shouldPin = !selectedDocumentsArePinned
                    Task {
                        await model.setPinned(
                            recordIDs: recordIDs,
                            isPinned: shouldPin
                        )
                        setDocumentSelection(active: false)
                    }
                } label: {
                    WorkspaceBarLabel(
                        title: selectedDocumentsArePinned
                            ? "Unpin"
                            : "Pin",
                        symbol: selectedDocumentsArePinned
                            ? "pin.slash"
                            : "pin"
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedDocumentIDs.isEmpty)

                Menu {
                    ForEach(DocumentWorkflowStatus.allCases) { status in
                        Button {
                            let recordIDs = selectedDocumentIDs
                            Task {
                                await model.updateWorkflow(
                                    recordIDs: recordIDs,
                                    status: status
                                )
                                setDocumentSelection(active: false)
                            }
                        } label: {
                            Label(
                                status.title.localizedUI,
                                systemImage: status.symbol
                            )
                        }
                    }
                } label: {
                    WorkspaceBarLabel(
                        title: "Move",
                        symbol: "tray.and.arrow.down"
                    )
                }
                .disabled(selectedDocumentIDs.isEmpty)

                Menu {
                    Button {
                        isPresentingBatchTagEditor = true
                    } label: {
                        Label("Edit Tags", systemImage: "tag")
                    }

                    Button {
                        batchBatesInitialRecordIDs =
                            selectedBatesEligibleRecordIDs
                        isPresentingBatchBatesNumbers = true
                    } label: {
                        Label(
                            AppLocalization.format(
                                "Continuous Bates (%lld)",
                                selectedBatesEligibleRecordIDs.count
                            ),
                            systemImage: "number.square.fill"
                        )
                    }
                    .disabled(
                        selectedBatesEligibleRecordIDs.count < 2
                    )

                    Button {
                        officeProductionInitialRecordIDs =
                            selectedDocumentIDs
                        isPresentingOfficeProduction = true
                    } label: {
                        Label(
                            "Office Production",
                            systemImage: "square.stack.3d.up"
                        )
                    }
                    .disabled(
                        !selectedDocumentIDs.contains {
                            id in
                            guard let record = model.record(id: id)
                            else { return false }
                            return record.isWorkingCopy
                                && PDFQuickTask.exportText
                                    .supports(record)
                        }
                    )
                } label: {
                    WorkspaceBarLabel(
                        title: "Batch",
                        symbol: "square.stack.3d.up"
                    )
                }
                .disabled(selectedDocumentIDs.isEmpty)

                Button(role: .destructive) {
                    isConfirmingBulkDelete = true
                } label: {
                    WorkspaceBarLabel(
                        title: "Remove",
                        symbol: "trash",
                        tint: .red
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedDocumentIDs.isEmpty)
            }
            .opacity(selectedDocumentIDs.isEmpty ? 0.45 : 1)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.72))
                .frame(height: 0.6)
        }
    }

    private var selectedDocumentsArePinned: Bool {
        !selectedDocumentIDs.isEmpty
            && model.documents
                .filter { selectedDocumentIDs.contains($0.id) }
                .allSatisfy(\.isPinned)
    }

    private var batesBatchEligibleRecords: [DocumentRecord] {
        model.workingDocuments.filter {
            !$0.profile.isLocked
                && $0.profile.pageCount > 0
                && !model.isProcessing($0.id)
        }
    }

    private var selectedBatesEligibleRecordIDs: [UUID] {
        filteredDocuments.filter {
            selectedDocumentIDs.contains($0.id)
                && $0.isWorkingCopy
                && !$0.profile.isLocked
                && $0.profile.pageCount > 0
                && !model.isProcessing($0.id)
        }.map(\.id)
    }

    private var officeProductionCommandDetail: String {
        let queue = model.officeProductionQueue
        if let active = queue.activeJob {
            return "\(active.format.fileExtension.uppercased()) · \(queue.pendingCount) waiting"
        }
        if queue.attentionCount > 0 {
            return "\(queue.attentionCount) need review"
        }
        if queue.pendingCount > 0 {
            return "\(queue.pendingCount) waiting"
        }
        return "Local batch export"
    }

    private func setDocumentSelection(active: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            isSelectingDocuments = active
            if !active {
                selectedDocumentIDs.removeAll()
            }
        }
    }

    private func toggleDocumentSelection(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            if selectedDocumentIDs.contains(id) {
                selectedDocumentIDs.remove(id)
            } else {
                selectedDocumentIDs.insert(id)
            }
        }
    }

    @ViewBuilder
    private func documentActions(
        for record: DocumentRecord
    ) -> some View {
        Button {
            onOpen(DocumentRoute(recordID: record.id))
        } label: {
            Label("Open", systemImage: "doc.text.magnifyingglass")
        }

        Button {
            Task {
                await model.togglePinned(recordID: record.id)
            }
        } label: {
            Label(
                record.isPinned ? "Unpin" : "Pin",
                systemImage: record.isPinned ? "pin.slash" : "pin"
            )
        }

        Menu("Move to") {
            ForEach(DocumentWorkflowStatus.allCases) { status in
                Button {
                    Task {
                        await model.updateWorkflow(
                            recordID: record.id,
                            status: status
                        )
                    }
                } label: {
                    Label(
                        status.title.localizedUI,
                        systemImage: status.symbol
                    )
                }
            }
        }

        Button {
            tagEditorRecord = record
        } label: {
            Label("Tags", systemImage: "tag")
        }

        Button {
            scheduleEditorRecord = record
        } label: {
            Label(
                record.dueAt == nil
                    ? "Set Due Date"
                    : "Edit Due Date",
                systemImage: "calendar.badge.clock"
            )
        }

        Button {
            noteEditorRecord = record
        } label: {
            Label(
                record.privateNote == nil
                    ? "Add Private Note"
                    : "Edit Private Note",
                systemImage: "note.text"
            )
        }

        Button {
            Task {
                if let duplicated = await model.duplicate(
                    recordID: record.id
                ) {
                    onOpen(
                        DocumentRoute(recordID: duplicated.id)
                    )
                }
            }
        } label: {
            Label(
                "Duplicate Working Copy",
                systemImage: "plus.square.on.square"
            )
        }

        if let verified = model.verifiedShareTarget(for: record.id),
           let url = model.url(for: verified.id) {
            ShareLink(item: url) {
                Label(
                    "Share Verified Copy",
                    systemImage: "square.and.arrow.up"
                )
            }
        } else if record.profile.isLocked,
                  let url = model.url(for: record.id) {
            ShareLink(item: url) {
                Label(
                    "Share Encrypted PDF",
                    systemImage: "lock.doc"
                )
            }
        } else {
            Button {
                open(.safeShare, recordID: record.id)
            } label: {
                Label(
                    "Verify Before Sharing",
                    systemImage: "checkmark.shield"
                )
            }
        }
    }

    private func searchEvidence(
        _ match: DocumentTextMatch
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Label(
                "Page \(match.pageIndex + 1)",
                systemImage: "text.magnifyingglass"
            )
            .font(.caption2.weight(.bold))
            .foregroundStyle(PPColor.accent)
            .labelStyle(.titleAndIcon)
            .fixedSize()

            Text(match.excerpt)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(libraryDensity == .compact ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PPSpacing.medium)
        .padding(.top, 2)
        .padding(.bottom, PPSpacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Match on page \(match.pageIndex + 1). \(match.excerpt)"
        )
    }

    private var emptyResults: some View {
        let hasTaskResults = !matchingTaskPackages.isEmpty
            || !matchingQuickTasks.isEmpty

        return HStack(spacing: PPSpacing.medium) {
            PPIllustration(kind: .search, width: 92)
                .frame(width: 88, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    hasTaskResults
                        ? "No matching documents"
                        : "No matching documents or tools"
                )
                .font(.headline)
                .foregroundStyle(PPColor.textPrimary)
                Text(
                    hasTaskResults
                        ? "Matching tasks are shown above."
                        : "Try sign, compress, redact, or pages."
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var emptyLibrary: some View {
        HStack(spacing: PPSpacing.medium) {
            PPIllustration(kind: .workspace, width: 92)
                .frame(width: 88, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text("No private copies yet")
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
                Text(
                    "Importing creates a private copy. Your original stays untouched."
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var loadingLibrary: some View {
        HStack(spacing: PPSpacing.medium) {
            PPIllustration(kind: .processing, width: 82)
                .frame(width: 76, height: 66)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView()
                    .controlSize(.small)
                    .tint(PPColor.accent)
                Text("Opening your local library")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.small)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
            VStack(spacing: PPSpacing.medium) {
                PPIllustration(kind: .processing, width: 132)
                Text("Preparing a private copy")
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
                Text("The source file remains unchanged.")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(PPSpacing.xLarge)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
            .accessibilityElement(children: .combine)
        }
    }

    private var filteredDocuments: [DocumentRecord] {
        guard !isSearching || searchScope != .tools else {
            return []
        }
        let records = model.matchingDocuments(
            query: appliedSearchText,
            status: statusFilter,
            category: categoryFilter
        )
        let scopedRecords = isSearching
            ? records
            : records.filter(\.isWorkingCopy)
        let taggedRecords = selectedTag.map { selectedTag in
            scopedRecords.filter { record in
                record.tags.contains {
                    $0.caseInsensitiveCompare(selectedTag)
                        == .orderedSame
                }
            }
        } ?? scopedRecords
        let smartRecords = selectedSmartView.map { smartView in
            taggedRecords.filter {
                matchesSmartView($0, smartView: smartView)
            }
        } ?? taggedRecords
        return sortedDocuments(smartRecords)
    }

    private var librarySort: LibrarySort {
        LibrarySort(rawValue: savedLibrarySort)
            ?? .recentlyEdited
    }

    private var libraryDensity: LibraryDensity {
        LibraryDensity(rawValue: savedLibraryDensity)
            ?? .compact
    }

    private func dueDateTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if date < calendar.startOfDay(for: Date()) {
            return "Overdue".localizedUI
        }
        if calendar.isDateInToday(date) {
            return "Today".localizedUI
        }
        return date.formatted(
            .dateTime.month(.abbreviated).day()
        )
    }

    private func dueDateTint(_ date: Date) -> Color {
        let calendar = Calendar.current
        if date < calendar.startOfDay(for: Date()) {
            return .red
        }
        return calendar.isDateInToday(date)
            ? PPColor.amber
            : PPColor.cyan
    }

    private var libraryViewMode: LibraryViewMode {
        LibraryViewMode(rawValue: savedLibraryViewMode)
            ?? .list
    }

    private var effectiveLibraryViewMode: LibraryViewMode {
        dynamicTypeSize.isAccessibilitySize
            ? .list
            : libraryViewMode
    }

    private func sortedDocuments(
        _ records: [DocumentRecord]
    ) -> [DocumentRecord] {
        records.sorted { lhs, rhs in
            switch librarySort {
            case .recentlyEdited:
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
            case .recentlyOpened:
                let lhsDate = lhs.lastViewedAt ?? .distantPast
                let rhsDate = rhs.lastViewedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case .name:
                let comparison = lhs.displayName
                    .localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .size:
                if lhs.profile.byteCount != rhs.profile.byteCount {
                    return lhs.profile.byteCount
                        > rhs.profile.byteCount
                }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var shouldShowTaskPackages: Bool {
        statusFilter == nil
            && categoryFilter == nil
            && selectedSmartView == nil
            && (
                isSearchingTools
                    || !recommendedTaskPackages.isEmpty
            )
            && (
                appliedSearchText.isEmpty
                    || !matchingTaskPackages.isEmpty
            )
    }

    private var shouldShowPDFTools: Bool {
        statusFilter == nil
            && categoryFilter == nil
            && selectedSmartView == nil
            && (
                !isSearchingTools
                    || !matchingQuickTasks.isEmpty
            )
    }

    private var shouldShowLibrary: Bool {
        !isSearching || searchScope != .tools
    }

    private var hasActiveFilters: Bool {
        statusFilter != nil
            || categoryFilter != nil
            || selectedTag != nil
            || selectedSmartView != nil
            || !appliedSearchText.isEmpty
    }

    private var libraryTitle: String {
        if model.workingDocuments.isEmpty && !isSearching {
            return "Ready when you are"
        }
        if let selectedSmartView {
            return selectedSmartView.title
        }
        if let selectedTag {
            return "#\(selectedTag)"
        }
        if hasActiveFilters {
            return "Search results"
        }
        return "Recent documents"
    }

    private func selectSmartView(
        _ smartView: LibrarySmartView?
    ) {
        if smartView == .duplicates {
            isPresentingDuplicates = true
            return
        }
        withAnimation(
            reduceMotion
                ? nil
                : .snappy(duration: 0.2)
        ) {
            selectedSmartView = smartView
            guard smartView != nil else { return }
            statusFilter = nil
            categoryFilter = nil
            selectedTag = nil
            searchText = ""
            appliedSearchText = ""
        }
    }

    private func matchesSmartView(
        _ record: DocumentRecord,
        smartView: LibrarySmartView
    ) -> Bool {
        switch smartView {
        case .attention:
            return model.needsAttention(record)
        case .overdue:
            guard let dueAt = record.dueAt else { return false }
            return dueAt < Calendar.current.startOfDay(for: Date())
                && record.workflowStatus != .ready
                && record.workflowStatus != .archived
        case .today:
            guard let dueAt = record.dueAt else { return false }
            return Calendar.current.isDateInToday(dueAt)
                && record.workflowStatus != .ready
                && record.workflowStatus != .archived
        case .scans:
            return record.profile.kind == .scan
                || record.profile.kind == .mixed
        case .forms:
            return record.profile.formFieldCount > 0
        case .ready:
            return record.workflowStatus == .ready
        case .verified:
            return model.verifiedShareTarget(for: record.id) != nil
        case .officeReview:
            return PDFOfficeExportPortfolio(profile: record.profile)
                .routeConfidence != .high
        case .duplicates:
            return model.duplicateFingerprintCount(for: record) > 1
        }
    }

    private func smartViewTint(
        _ smartView: LibrarySmartView
    ) -> Color {
        switch smartView {
        case .attention: return PPColor.amber
        case .overdue: return .red
        case .today: return PPColor.amber
        case .scans: return PPColor.cyan
        case .forms: return PPColor.accent
        case .ready: return PPColor.mint
        case .verified: return PPColor.mint
        case .officeReview: return PPColor.cyan
        case .duplicates: return PPColor.amber
        }
    }

    private var availableTags: [(name: String, count: Int)] {
        var displayNames: [String: String] = [:]
        var counts: [String: Int] = [:]
        for tag in model.workingDocuments.flatMap(\.tags) {
            let key = tag.lowercased()
            displayNames[key] = displayNames[key] ?? tag
            counts[key, default: 0] += 1
        }
        return counts.compactMap { key, count in
            displayNames[key].map { (name: $0, count: count) }
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.name.localizedStandardCompare(rhs.name)
                == .orderedAscending
        }
    }

    private var librarySearchHistory: [String] {
        guard let data = savedLibrarySearchHistory.data(
            using: .utf8
        ) else {
            return []
        }
        return (try? JSONDecoder().decode(
            [String].self,
            from: data
        )) ?? []
    }

    private var libraryPageSearchRequest:
        LibraryPageSearchRequest {
        let query = appliedSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recordIDs = model.documents.map(\.id).sorted {
            $0.uuidString < $1.uuidString
        }
        let indexStamps = model.textIndices.map {
            LibraryPageIndexStamp(
                recordID: $0.key,
                indexedAt: $0.value.indexedAt,
                pageCount: $0.value.pages.count
            )
        }
        .sorted {
            $0.recordID.uuidString < $1.recordID.uuidString
        }
        return LibraryPageSearchRequest(
            query: query,
            recordIDs: recordIDs,
            indexStamps: indexStamps
        )
    }

    private func refreshLibraryPageSearch(
        request: LibraryPageSearchRequest
    ) async {
        guard !request.query.isEmpty else {
            libraryPageSearchSnapshot = .empty
            isSearchingPageIndex = false
            return
        }

        isSearchingPageIndex = true
        let recordIDs = Set(request.recordIDs)
        let indices: [
            (recordID: UUID, index: DocumentTextIndex)
        ] = request.recordIDs.compactMap { recordID in
            guard recordIDs.contains(recordID),
                  let index = model.textIndices[recordID]
            else { return nil }
            return (recordID: recordID, index: index)
        }
        let query = request.query
        let worker = Task.detached(
            priority: .userInitiated
        ) { () throws -> LibraryPageSearchSnapshot in
            var matchesByRecordID:
                [UUID: [DocumentTextMatch]] = [:]
            matchesByRecordID.reserveCapacity(indices.count)
            let resultLimit = 500
            let perDocumentLimit = 200
            var remaining = resultLimit
            var isLimited = false
            for (recordID, index) in indices {
                try Task.checkCancellation()
                guard remaining > 0 else {
                    isLimited = true
                    break
                }
                let matches = index.matches(
                    for: query,
                    limit: min(
                        perDocumentLimit + 1,
                        remaining + 1
                    )
                )
                if !matches.isEmpty {
                    let accepted = Array(
                        matches.prefix(
                            min(perDocumentLimit, remaining)
                        )
                    )
                    matchesByRecordID[recordID] = accepted
                    remaining -= accepted.count
                    if matches.count > accepted.count {
                        isLimited = true
                    }
                }
            }
            return LibraryPageSearchSnapshot(
                query: query,
                matchesByRecordID: matchesByRecordID,
                isLimited: isLimited
            )
        }

        do {
            let snapshot = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard request == libraryPageSearchRequest else { return }
            libraryPageSearchSnapshot = snapshot
            isSearchingPageIndex = false
        } catch {
            guard request == libraryPageSearchRequest else { return }
            libraryPageSearchSnapshot = .empty
            isSearchingPageIndex = false
        }
    }

    private func recordLibrarySearch(_ value: String) {
        let query = String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(80)
        )
        guard !query.isEmpty else { return }

        var history = librarySearchHistory.filter {
            $0.caseInsensitiveCompare(query) != .orderedSame
        }
        history.insert(query, at: 0)
        history = Array(history.prefix(6))
        guard let data = try? JSONEncoder().encode(history),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        savedLibrarySearchHistory = encoded
    }
}

private enum OfficeProductionFormatChoice:
    String,
    CaseIterable,
    Identifiable {
    case recommended
    case word
    case excel
    case powerPoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: return "Recommended per PDF"
        case .word: return "Word"
        case .excel: return "Excel"
        case .powerPoint: return "PowerPoint"
        }
    }

    var symbol: String {
        switch self {
        case .recommended: return "wand.and.stars"
        case .word: return PDFTextExportFormat.wordDocument.symbol
        case .excel: return PDFTextExportFormat.excelWorkbook.symbol
        case .powerPoint:
            return PDFTextExportFormat.powerPointPresentation.symbol
        }
    }

    var format: PDFTextExportFormat? {
        switch self {
        case .recommended: return nil
        case .word: return .wordDocument
        case .excel: return .excelWorkbook
        case .powerPoint: return .powerPointPresentation
        }
    }
}

private struct OfficeProductionCenterView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let onOpen: (UUID) -> Void

    @State private var selectedRecordIDs: Set<UUID>
    @State private var formatChoice =
        OfficeProductionFormatChoice.recommended
    @State private var priority = PDFOfficeQueuePriority.normal
    @State private var sourceSearchText = ""
    @State private var showsAllJobs = false
    @State private var queueFeedback = 0
    @State private var deliveryFeedback = 0
    @State private var isPreparingDelivery = false
    @State private var isPresentingDeliveryShare = false
    @State private var deliveryShareURL: URL?
    @State private var verificationTask: Task<Void, Never>?
    @State private var deliveryTask: Task<Void, Never>?
    @State private var isImportingVerificationReport = false
    @State private var reportVerificationFeedback = 0
    @State private var reportVerificationErrorFeedback = 0
    @State private var isPresentingSigningIdentity = false
    @State private var isSelectingExternalDeliveryFiles = false
    @State private var officeExternalMatchTask: Task<Void, Never>?
    @State private var officeExternalMatchReport:
        PDFOfficeExternalMatchReport?
    @State private var isImportingOfficeMatchReport = false
    @State private var isInspectingOfficeMatchReport = false
    @State private var officeMatchInspectionTask:
        Task<Void, Never>?
    @State private var importedOfficeMatchInspection:
        PDFOfficeMatchReportInspection?

    init(
        initialRecordIDs: Set<UUID>,
        onOpen: @escaping (UUID) -> Void
    ) {
        self.onOpen = onOpen
        _selectedRecordIDs = State(initialValue: initialRecordIDs)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        productionHeader
                        if let verification =
                            model.lastOfficeReportVerification {
                            reportVerificationSection(verification)
                        }
                        if !model.officeProductionQueue.jobs.isEmpty {
                            queueSection
                        }
                        if !model.officeDeliveryPackages.isEmpty {
                            deliveryLedgerSection
                        }
                        setupSection
                        sourceSection
                    }
                    .frame(maxWidth: 820)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 84)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Office Production")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $sourceSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Filter PDFs"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        officeExternalMatchTask == nil
                            ? "Done"
                            : "Stop"
                    ) {
                        if let officeExternalMatchTask {
                            officeExternalMatchTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    queueToolbarMenu
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                enqueueBar
            }
            .sheet(isPresented: $isPresentingDeliveryShare) {
                if let deliveryShareURL {
                    ShareSheet(items: [deliveryShareURL])
                }
            }
            .sheet(isPresented: $isPresentingSigningIdentity) {
                OfficeSigningIdentityView(
                    identity: model.officeSigningIdentityCard,
                    trustedSigners: model.officeTrustedSigners,
                    onShare: shareSigningIdentity,
                    onRemoveTrustedSigner: { keyID in
                        Task {
                            await model.removeOfficeTrustedSigner(
                                keyID
                            )
                        }
                    }
                )
            }
            .fileImporter(
                isPresented: $isImportingVerificationReport,
                allowedContentTypes: [.json]
            ) { result in
                handleVerificationReportImport(result)
            }
            .fileImporter(
                isPresented: $isSelectingExternalDeliveryFiles,
                allowedContentTypes: externalDeliveryContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleExternalDeliverySelection(result)
            }
            .sheet(item: $officeExternalMatchReport) { report in
                OfficeDeliveryFileMatchView(
                    report: report,
                    deliveryReport:
                        model.lastOfficeReportVerification?
                            .signedReport,
                    inspection: nil,
                    trustStatus:
                        model.lastOfficeReportVerification?
                            .trustStatus ?? .unknown,
                    trustedSignerName:
                        model.lastOfficeReportVerification?
                            .trustedSignerName,
                    onChooseAgain: {
                        Task { @MainActor in
                            try? await Task.sleep(
                                for: .milliseconds(180)
                            )
                            isSelectingExternalDeliveryFiles = true
                        }
                    }
                )
            }
            .fileImporter(
                isPresented: $isImportingOfficeMatchReport,
                allowedContentTypes: [.json]
            ) { result in
                handleOfficeMatchReportImport(result)
            }
            .sheet(item: $importedOfficeMatchInspection) {
                inspection in
                OfficeDeliveryFileMatchView(
                    report:
                        inspection.signedReport.payload.matchReport,
                    deliveryReport:
                        inspection.signedReport.payload
                            .deliveryReport,
                    inspection: inspection,
                    trustStatus:
                        inspection.deliveryTrustStatus,
                    trustedSignerName:
                        inspection.deliveryTrustedSignerName,
                    onChooseAgain: nil
                )
            }
            .onChange(of: isPresentingDeliveryShare) { _, presented in
                if !presented {
                    cleanupDeliveryShareURL()
                }
            }
        }
        .interactiveDismissDisabled(officeExternalMatchTask != nil)
        .sensoryFeedback(.success, trigger: queueFeedback)
        .sensoryFeedback(.success, trigger: deliveryFeedback)
        .sensoryFeedback(
            .success,
            trigger: reportVerificationFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: reportVerificationErrorFeedback
        )
        .sensoryFeedback(
            .selection,
            trigger: selectedRecordIDs.count
        )
        .task {
            selectedRecordIDs.formIntersection(
                Set(eligibleRecords.map(\.id))
            )
            await model.refreshOfficeResourceSnapshot()
        }
        .onChange(of: eligibleRecords.map(\.id)) { _, eligibleIDs in
            selectedRecordIDs.formIntersection(Set(eligibleIDs))
        }
        .onDisappear {
            verificationTask?.cancel()
            deliveryTask?.cancel()
            officeExternalMatchTask?.cancel()
            officeExternalMatchTask = nil
            officeMatchInspectionTask?.cancel()
            officeMatchInspectionTask = nil
        }
    }

    private var productionHeader: some View {
        let queue = model.officeProductionQueue
        return WorkflowCommandHeader(
            eyebrow: "LOCAL OFFICE PRODUCTION",
            title: queue.activeJob == nil
                ? "Serial production queue"
                : queue.activeJob?.sourceName
                    ?? "Serial production queue",
            detail: queue.activeJob?.detail
                ?? "Schedule multiple PDFs without uploading originals.",
            symbol: queue.activeJob?.stage.symbol
                ?? "square.stack.3d.up",
            tint: queue.attentionCount > 0
                ? PPColor.amber
                : PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(queue.pendingCount)",
                    label: "Waiting",
                    symbol: "clock",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(queue.completedCount)",
                    label: "Ready",
                    symbol: "checkmark.circle",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(queue.attentionCount)",
                    label: "Review",
                    symbol: "exclamationmark.triangle",
                    tint: queue.attentionCount == 0
                        ? PPColor.textSecondary
                        : PPColor.amber
                ),
                WorkflowMetric(
                    value: model.officeResourceSnapshot.mode.title,
                    label: "Resources",
                    symbol: model.officeResourceSnapshot.mode.symbol,
                    tint: resourceTint
                )
            ]
        )
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "PRODUCTION QUEUE")
                Spacer(minLength: 0)
                Button {
                    verifyReadyOutputs()
                } label: {
                    Image(systemName: "checkmark.shield")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.mint)
                .disabled(
                    completedJobIDs.isEmpty || isPreparingDelivery
                )
                .accessibilityLabel("Verify ready Office outputs")

                Button {
                    packageReadyOutputs()
                } label: {
                    Image(systemName: "archivebox")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .disabled(
                    completedJobIDs.isEmpty || isPreparingDelivery
                )
                .accessibilityLabel("Package verified Office outputs")

                queueRunControl
            }

            resourceRail
            if let progress = model.officeIntegrityProgress {
                verificationProgressRail(progress)
            }

            VStack(spacing: 0) {
                ForEach(visibleJobs) { job in
                    queueJobRow(job)
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }

            if model.officeProductionQueue.jobs.count > visibleJobs.count {
                Button {
                    showsAllJobs = true
                } label: {
                    Label(
                        AppLocalization.format(
                            "Show all %lld jobs",
                            model.officeProductionQueue.jobs.count
                        ),
                        systemImage: "chevron.down"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
            } else if showsAllJobs,
                      model.officeProductionQueue.jobs.count > 8 {
                Button {
                    showsAllJobs = false
                } label: {
                    Label(
                        "Show active jobs only",
                        systemImage: "chevron.up"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
            }
        }
    }

    private func reportVerificationSection(
        _ verification: PDFOfficeReportVerificationResult
    ) -> some View {
        let tint = officeReportTint(verification)
        return VStack(
            alignment: .leading,
            spacing: PPSpacing.small
        ) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: verification.status.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(
                        .bounce,
                        value: reportVerificationFeedback
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(verification.status.title.localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(verification.detail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                    Label(
                        (
                            verification.trustedSignerName
                                ?? verification.trustStatus.title
                        ).localizedUI,
                        systemImage: verification.trustStatus.symbol
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                }
                Spacer(minLength: 0)
                if verification.canTrustSigner {
                    Button {
                        Task {
                            await model.trustLastOfficeReportSigner()
                            reportVerificationFeedback += 1
                        }
                    } label: {
                        Label(
                            "Trust Signer",
                            systemImage:
                                "person.crop.circle.badge.checkmark"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.mint)
                    )
                    .disabled(officeExternalMatchTask != nil)
                }
                Button {
                    dismissOfficeReportVerification()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityLabel("Dismiss verification result")
                .disabled(officeExternalMatchTask != nil)
            }
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 88, maximum: 180),
                        spacing: PPSpacing.medium
                    )
                ],
                alignment: .leading,
                spacing: PPSpacing.small
            ) {
                evidencePair(
                    verification.trustStatus.title,
                    value: verification.keyID.map {
                        String($0.prefix(12))
                    } ?? "—"
                )
                evidencePair(
                    "Sources",
                    value: "\(verification.sourceCount)"
                )
                evidencePair(
                    "Outputs",
                    value: "\(verification.outputCount)"
                )
                if let createdAt = verification.createdAt {
                    evidencePair(
                        "Created",
                        value: createdAt.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                }
            }
            if let progress = model.officeExternalMatchProgress,
               progress.packageID == verification.packageID,
               officeExternalMatchTask != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: PPSpacing.small) {
                        Text(progress.currentFileName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(
                            "\(progress.completedFileCount)/\(progress.totalFileCount)"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                    Text(
                        AppLocalization.format(
                            "%@ of %@ checked",
                            ByteCountFormatter.string(
                                fromByteCount:
                                    progress.processedBytes,
                                countStyle: .file
                            ),
                            ByteCountFormatter.string(
                                fromByteCount: progress.totalBytes,
                                countStyle: .file
                            )
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
            if verification.isVerified,
               verification.signedReport != nil {
                Button {
                    if let officeExternalMatchTask {
                        officeExternalMatchTask.cancel()
                    } else {
                        isSelectingExternalDeliveryFiles = true
                    }
                } label: {
                    Label(
                        officeExternalMatchTask == nil
                            ? "Match Delivery Files"
                            : "Stop Matching",
                        systemImage: officeExternalMatchTask == nil
                            ? "doc.text.magnifyingglass"
                            : "stop.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    PPQuietButtonStyle(
                        tint: officeExternalMatchTask == nil
                            ? PPColor.cyan
                            : PPColor.amber
                    )
                )
                .accessibilityHint(
                    "Compares selected file bytes with this signed report"
                )
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tint.opacity(0.66))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private func evidencePair(
        _ label: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps())
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func officeReportTint(
        _ verification: PDFOfficeReportVerificationResult
    ) -> Color {
        guard verification.isVerified else { return PPColor.rose }
        switch verification.trustStatus {
        case .thisDevice, .trusted: return PPColor.mint
        case .unknown: return PPColor.amber
        case .invalid, .unsupported: return PPColor.rose
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "NEW JOBS")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    formatMenu
                    priorityPicker
                }
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    formatMenu
                    priorityPicker
                }
            }
            forecastRail
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var deliveryLedgerSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "DELIVERY LEDGER")
                Text("\(model.officeDeliveryPackages.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.mint)
                if let keyID = model.officeDeliverySigningKeyID {
                    Text("SIGNER \(keyID.prefix(8))")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                Spacer(minLength: 0)
                Text("3-day local retention".localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
            }

            VStack(spacing: 0) {
                ForEach(model.officeDeliveryPackages) { package in
                    deliveryPackageRow(package)
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(height: 0.6)
            }
        }
    }

    private func deliveryPackageRow(
        _ package: PDFOfficeDeliveryPackage
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            Image(systemName: "shippingbox.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.mint)
                .frame(width: 30, height: 30)
                .background(
                    PPColor.mint.opacity(0.1),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(
                        package.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                    if package.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(PPColor.amber)
                    }
                    Spacer(minLength: 0)
                    Text(package.formattedSize)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                Text(
                    AppLocalization.format(
                        "%lld source%@ · %lld output%@ · %@",
                        package.sourceCount,
                        package.sourceCount == 1 ? "" : "s",
                        package.entries.count,
                        package.entries.count == 1 ? "" : "s",
                        package.retentionSummary
                    )
                )
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
                if let fingerprint = package.shortFingerprint {
                    Label(
                        "ZIP SHA-256 \(fingerprint)",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PPColor.mint)
                }
                if let signerKeyID = package.signerKeyID {
                    Text(
                        "Ed25519 · signer \(signerKeyID.prefix(12))"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                }
            }

            Menu {
                Button {
                    shareDeliveryPackage(package, reportOnly: false)
                } label: {
                    Label(
                        "Share Package",
                        systemImage: "square.and.arrow.up"
                    )
                }
                Button {
                    shareDeliveryPackage(package, reportOnly: true)
                } label: {
                    Label(
                        "Share Verification Report",
                        systemImage: "checkmark.shield"
                    )
                }
                Button {
                    Task {
                        await model.setOfficeDeliveryPackagePinned(
                            package.id,
                            pinned: !package.isPinned
                        )
                    }
                } label: {
                    Label(
                        package.isPinned ? "Unpin" : "Pin",
                        systemImage: package.isPinned
                            ? "pin.slash"
                            : "pin"
                    )
                }
                Divider()
                Button(role: .destructive) {
                    Task {
                        await model.deleteOfficeDeliveryPackage(
                            package.id
                        )
                    }
                } label: {
                    Label("Delete Package", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityLabel("Delivery package actions")
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.5))
                .frame(height: 0.5)
                .padding(.leading, 40)
        }
    }

    private var formatMenu: some View {
        Menu {
            ForEach(OfficeProductionFormatChoice.allCases) { choice in
                Button {
                    formatChoice = choice
                } label: {
                    Label(
                        choice.title,
                        systemImage: formatChoice == choice
                            ? "checkmark"
                            : choice.symbol
                    )
                }
            }
        } label: {
            HStack(spacing: PPSpacing.small) {
                ToolSymbolPlate(
                    symbol: formatChoice.symbol,
                    tint: PPColor.cyan,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Output route")
                        .font(.caption2.smallCaps())
                        .foregroundStyle(PPColor.textSecondary)
                    Text(formatChoice.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var priorityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Priority".localizedUI.uppercased())
                .font(.caption2.smallCaps())
                .foregroundStyle(PPColor.textSecondary)
            Picker("Priority", selection: $priority) {
                ForEach(PDFOfficeQueuePriority.allCases) { option in
                    Text(option.title.localizedUI)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "ELIGIBLE PDFS")
                Text("\(selectedRecordIDs.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.cyan)
                Spacer(minLength: 0)
                if selectedRecordIDs.count < filteredEligibleRecords.count {
                    Button("Select All") {
                        selectedRecordIDs = Set(
                            filteredEligibleRecords.map(\.id)
                        )
                    }
                    .font(.caption.weight(.semibold))
                } else if !selectedRecordIDs.isEmpty {
                    Button("Clear") {
                        selectedRecordIDs.removeAll()
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .padding(.bottom, PPSpacing.xSmall)

            if filteredEligibleRecords.isEmpty {
                ContentUnavailableView(
                    "No eligible PDFs",
                    systemImage: "doc.questionmark",
                    description: Text(
                        "Unlocked PDFs appear here for local Office production."
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.large)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredEligibleRecords) { record in
                        sourceRow(record)
                    }
                }
            }
        }
    }

    private func sourceRow(
        _ record: DocumentRecord
    ) -> some View {
        let selected = selectedRecordIDs.contains(record.id)
        let portfolio = PDFOfficeExportPortfolio(profile: record.profile)
        let route = formatChoice.format
            ?? portfolio.recommendedPlan?.format
            ?? .wordDocument
        return Button {
            if selected {
                selectedRecordIDs.remove(record.id)
            } else {
                selectedRecordIDs.insert(record.id)
            }
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(
                    systemName: selected
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(
                    selected ? PPColor.cyan : PPColor.textSecondary
                )
                .frame(width: 28)

                ToolSymbolPlate(
                    symbol: record.profile.kind.symbol,
                    tint: PPColor.accent,
                    size: 34
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(
                        "\(record.subtitle) · \(route.fileExtension.uppercased()) · \(portfolio.routeConfidence.title)"
                            .localizedUI
                    )
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if route.officePageLimit.map({
                    record.profile.pageCount > $0
                }) == true {
                    Text("SEGMENTED".localizedUI)
                        .font(.caption2.smallCaps().weight(.black))
                        .foregroundStyle(PPColor.amber)
                }
            }
            .padding(.vertical, PPSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.5))
                .frame(height: 0.5)
                .padding(.leading, 72)
        }
    }

    private func queueJobRow(
        _ job: PDFOfficeQueueJob
    ) -> some View {
        let progress = model.progress(for: job.recordID)
        return HStack(
            alignment: .top,
            spacing: PPSpacing.small
        ) {
            Image(systemName: job.stage.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(stageTint(job.stage))
                .frame(width: 30, height: 30)
                .background(
                    stageTint(job.stage).opacity(0.1),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(job.sourceName)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(job.format.fileExtension.uppercased())
                        .font(.caption2.smallCaps().weight(.black))
                        .foregroundStyle(PPColor.cyan)
                    Spacer(minLength: 0)
                    Text(job.priority.title.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(priorityTint(job.priority))
                }
                Text(
                    "\(job.stage.title) · \(job.routeLabel) · \(job.sourcePageCount)p"
                        .localizedUI
                )
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
                if let integrity = model.officeIntegrityStatus(for: job) {
                    Label(
                        integrity.title.localizedUI,
                        systemImage: integrity.symbol
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        integrity.isVerified
                            ? PPColor.mint
                            : PPColor.amber
                    )
                }
                Text(job.detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(
                        job.stage == .attention
                            ? PPColor.amber
                            : PPColor.textSecondary
                    )
                    .lineLimit(2)
                if let progress, job.stage.isActive {
                    ProgressView(value: progress.fractionCompleted)
                        .tint(PPColor.cyan)
                    if let bytes = progress.byteSummary {
                        TimelineView(
                            .periodic(from: .now, by: 1)
                        ) { context in
                            let isStalled = progress.isStalled(
                                at: context.date
                            )
                            HStack(spacing: PPSpacing.small) {
                                Label(
                                    isStalled
                                        ? "Stalled"
                                        : progress.byteStage?.title
                                            ?? "Processing",
                                    systemImage: isStalled
                                        ? "pause.fill"
                                        : progress.byteStage?.symbol
                                            ?? "gearshape.2"
                                )
                                .foregroundStyle(
                                    isStalled
                                        ? PPColor.amber
                                        : PPColor.textSecondary
                                )
                                Text(bytes)
                                Spacer(minLength: 0)
                                if isStalled {
                                    Text("0 B/s")
                                        .foregroundStyle(
                                            PPColor.amber
                                        )
                                } else if let speed =
                                    progress.throughputSummary {
                                    Text(speed)
                                        .foregroundStyle(
                                            PPColor.cyan
                                        )
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(1)
                        }
                    }
                }
            }

            queueJobMenu(job)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.5))
                .frame(height: 0.5)
                .padding(.leading, 40)
        }
        .accessibilityElement(children: .contain)
    }

    private func queueJobMenu(
        _ job: PDFOfficeQueueJob
    ) -> some View {
        Menu {
            if model.record(id: job.recordID) != nil {
                Button {
                    onOpen(job.recordID)
                } label: {
                    Label("Open PDF", systemImage: "arrow.up.right")
                }
            }

            if job.stage.isPending {
                Menu("Priority") {
                    ForEach(PDFOfficeQueuePriority.allCases) { option in
                        Button {
                            Task {
                                await model.setOfficeProductionPriority(
                                    jobID: job.id,
                                    priority: option
                                )
                            }
                        } label: {
                            Label(
                                option.title,
                                systemImage: job.priority == option
                                    ? "checkmark"
                                    : option.symbol
                            )
                        }
                    }
                }
            }

            if model.canRestoreOfficeProductionSource(job.id) {
                Button {
                    Task {
                        await model.restoreAndRetryOfficeProductionJob(
                            job.id
                        )
                    }
                } label: {
                    Label(
                        "Restore Source & Retry",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                }
            } else if model.canRetryOfficeProductionJob(job.id) {
                Button {
                    Task {
                        await model.retryOfficeProductionJob(job.id)
                    }
                } label: {
                    Label("Retry Job", systemImage: "arrow.clockwise")
                }
            } else if let record = model.record(id: job.recordID),
                      record.isWorkingCopy,
                      PDFQuickTask.exportText.supports(record),
                      job.stage == .attention
                        || job.stage == .cancelled {
                Button {
                    sourceSearchText = ""
                    selectedRecordIDs.insert(record.id)
                } label: {
                    Label(
                        "Queue Current Revision",
                        systemImage: "text.badge.plus"
                    )
                }
            }

            Divider()
            if job.stage.isTerminal {
                Button(role: .destructive) {
                    Task {
                        await model.removeOfficeProductionJob(job.id)
                    }
                } label: {
                    Label("Remove Job", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    Task {
                        await model.cancelOfficeProductionJob(job.id)
                    }
                } label: {
                    Label("Cancel Job", systemImage: "stop.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.textSecondary)
        .accessibilityLabel("Office job actions")
    }

    private var queueRunControl: some View {
        Group {
            if model.officeProductionQueue.isSuspended,
               model.officeProductionQueue.pendingCount > 0 {
                Button {
                    Task {
                        await model.resumeOfficeProductionQueue()
                    }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
            } else if model.officeProductionQueue.activeJob != nil
                        || model.officeProductionQueue.pendingCount > 0 {
                Button {
                    Task {
                        await model.suspendOfficeProductionQueue()
                    }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
            }
        }
    }

    private var queueToolbarMenu: some View {
        Menu {
            Button {
                isPresentingSigningIdentity = true
            } label: {
                Label(
                    "Signing Identity",
                    systemImage: "qrcode"
                )
            }
            Button {
                isImportingVerificationReport = true
            } label: {
                Label(
                    "Verify External Report",
                    systemImage: "checkmark.seal"
                )
            }
            Button {
                isImportingOfficeMatchReport = true
            } label: {
                Label(
                    "Verify Delivery Match Report",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            if model.officeProductionQueue.jobs.contains(
                where: \.stage.isTerminal
            ) {
                Divider()
                Button(role: .destructive) {
                    Task {
                        await model.clearFinishedOfficeProductionJobs()
                    }
                } label: {
                    Label(
                        "Clear Finished Jobs",
                        systemImage: "trash"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(
            officeExternalMatchTask != nil
                || isInspectingOfficeMatchReport
        )
        .accessibilityLabel("Office queue options")
    }

    private var externalDeliveryContentTypes: [UTType] {
        guard let files = model.lastOfficeReportVerification?
            .signedReport?.payload.files
        else { return [.data] }
        var seen: Set<String> = []
        let types = files.compactMap { entry -> UTType? in
            guard let type = UTType(
                filenameExtension: entry.format.fileExtension
            ),
                  seen.insert(type.identifier).inserted
            else { return nil }
            return type
        }
        return types.isEmpty ? [.data] : types
    }

    private func handleVerificationReportImport(
        _ result: Result<URL, Error>
    ) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result {
                model.present(error)
                reportVerificationErrorFeedback += 1
            }
            return
        }
        officeExternalMatchTask?.cancel()
        officeExternalMatchTask = nil
        officeExternalMatchReport = nil
        model.clearOfficeReportVerification()
        Task {
            do {
                let verification = try await model
                    .verifyOfficeDeliveryReport(at: url)
                if verification.isVerified {
                    reportVerificationFeedback += 1
                } else {
                    reportVerificationErrorFeedback += 1
                }
            } catch is CancellationError {
                return
            } catch {
                model.present(error)
                reportVerificationErrorFeedback += 1
            }
        }
    }

    private func handleExternalDeliverySelection(
        _ result: Result<[URL], Error>
    ) {
        guard case .success(let urls) = result,
              !urls.isEmpty
        else {
            if case .failure(let error) = result {
                model.present(error)
                reportVerificationErrorFeedback += 1
            }
            return
        }
        guard let report = model.lastOfficeReportVerification?
            .signedReport
        else {
            model.noticeMessage =
                "Verify a signed delivery report first.".localizedUI
            return
        }
        officeExternalMatchTask?.cancel()
        officeExternalMatchTask = Task {
            let matchReport = await model
                .matchExternalOfficeDeliveryFiles(
                    report: report,
                    candidateURLs: urls
                )
            let wasCancelled = Task.isCancelled
            officeExternalMatchTask = nil
            guard !wasCancelled else { return }
            guard let matchReport else {
                reportVerificationErrorFeedback += 1
                return
            }
            officeExternalMatchReport = matchReport
            reportVerificationFeedback += 1
        }
    }

    private func handleOfficeMatchReportImport(
        _ result: Result<URL, Error>
    ) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result {
                model.present(error)
                reportVerificationErrorFeedback += 1
            }
            return
        }
        officeMatchInspectionTask?.cancel()
        isInspectingOfficeMatchReport = true
        officeMatchInspectionTask = Task {
            let inspection = await model
                .inspectExternalOfficeMatchReport(at: url)
            let wasCancelled = Task.isCancelled
            isInspectingOfficeMatchReport = false
            officeMatchInspectionTask = nil
            guard !wasCancelled else { return }
            guard let inspection else {
                reportVerificationErrorFeedback += 1
                return
            }
            importedOfficeMatchInspection = inspection
            if inspection.isVerified {
                reportVerificationFeedback += 1
            } else {
                reportVerificationErrorFeedback += 1
            }
        }
    }

    private func dismissOfficeReportVerification() {
        officeExternalMatchTask?.cancel()
        officeExternalMatchTask = nil
        officeExternalMatchReport = nil
        model.clearOfficeReportVerification()
    }

    private func shareSigningIdentity() {
        Task {
            do {
                let url = try await model
                    .makeOfficeSigningIdentityCardFile()
                isPresentingSigningIdentity = false
                try? await Task.sleep(for: .milliseconds(160))
                deliveryShareURL = url
                isPresentingDeliveryShare = true
            } catch {
                model.present(error)
            }
        }
    }

    private func cleanupDeliveryShareURL() {
        guard let url = deliveryShareURL else { return }
        if url.lastPathComponent.hasPrefix(
            "PaperPath-Signing-Identity-"
        ) {
            try? FileManager.default.removeItem(at: url)
        }
        deliveryShareURL = nil
    }

    private var enqueueBar: some View {
        HStack(spacing: PPSpacing.small) {
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    selectedRecordIDs.isEmpty
                        ? "Select PDFs"
                        : AppLocalization.format(
                            "%lld PDF%@ selected",
                            selectedRecordIDs.count,
                            selectedRecordIDs.count == 1 ? "" : "s"
                        )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                Text(
                    "\(formatChoice.title) · \(priority.title)"
                        .localizedUI
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                let recordIDs = selectedRecordIDs
                Task {
                    let didQueue = await model.enqueueOfficeProduction(
                        recordIDs: recordIDs,
                        format: formatChoice.format,
                        priority: priority
                    )
                    if didQueue {
                        selectedRecordIDs.removeAll()
                        queueFeedback += 1
                    }
                }
            } label: {
                Label(
                    "Add to Queue",
                    systemImage: "text.badge.plus"
                )
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .frame(maxWidth: 210)
            .disabled(
                selectedRecordIDs.isEmpty
                    || !currentForecast.hasCapacity
            )
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private var eligibleRecords: [DocumentRecord] {
        model.workingDocuments.filter(
            PDFQuickTask.exportText.supports
        )
    }

    private var filteredEligibleRecords: [DocumentRecord] {
        let query = sourceSearchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return eligibleRecords }
        return eligibleRecords.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleJobs: [PDFOfficeQueueJob] {
        let jobs = model.officeProductionQueue.jobs
        guard jobs.count > 8, !showsAllJobs else { return jobs }
        let active = jobs.filter { !$0.stage.isTerminal }
        let recent = Array(
            jobs.filter(\.stage.isTerminal).prefix(4)
        )
        return Array((active + recent).prefix(8))
    }

    private var resourceRail: some View {
        let snapshot = model.officeResourceSnapshot
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.large) {
                resourceMetric(
                    snapshot.thermalLevel.title,
                    label: "Thermal",
                    symbol: "thermometer.medium",
                    tint: resourceTint
                )
                resourceMetric(
                    snapshot.powerTitle,
                    label: "Power",
                    symbol: snapshot.isLowPowerModeEnabled
                        ? "battery.25percent"
                        : "battery.100percent",
                    tint: snapshot.isLowPowerModeEnabled
                        ? PPColor.amber
                        : PPColor.mint
                )
                resourceMetric(
                    snapshot.formattedAvailableCapacity,
                    label: "Free",
                    symbol: "internaldrive",
                    tint: snapshot.mode == .blocked
                        ? PPColor.amber
                        : PPColor.accent
                )
                Text(snapshot.detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: PPSpacing.small
            ) {
                resourceMetric(
                    snapshot.thermalLevel.title,
                    label: "Thermal",
                    symbol: "thermometer.medium",
                    tint: resourceTint
                )
                resourceMetric(
                    snapshot.powerTitle,
                    label: "Power",
                    symbol: "battery.100percent",
                    tint: snapshot.isLowPowerModeEnabled
                        ? PPColor.amber
                        : PPColor.mint
                )
                resourceMetric(
                    snapshot.formattedAvailableCapacity,
                    label: "Free",
                    symbol: "internaldrive",
                    tint: PPColor.accent
                )
                resourceMetric(
                    snapshot.mode.title,
                    label: "Policy",
                    symbol: snapshot.mode.symbol,
                    tint: resourceTint
                )
            }
        }
        .padding(.vertical, PPSpacing.xSmall)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.5))
                .frame(height: 0.5)
        }
    }

    private var forecastRail: some View {
        let forecast = currentForecast
        return HStack(spacing: PPSpacing.small) {
            Image(
                systemName: forecast.hasCapacity
                    ? "externaldrive.badge.checkmark"
                    : "externaldrive.badge.exclamationmark"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                forecast.hasCapacity ? PPColor.mint : PPColor.amber
            )
            Text(
                forecast.sourceCount == 0
                    ? "Select PDFs to forecast local storage."
                    : AppLocalization.format(
                        "%lld source%@ · %lld package%@ · %@",
                        forecast.sourceCount,
                        forecast.sourceCount == 1 ? "" : "s",
                        forecast.packageCount,
                        forecast.packageCount == 1 ? "" : "s",
                        forecast.contract
                    )
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func verificationProgressRail(
        _ progress: PDFOfficeIntegrityProgress
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: PPSpacing.small) {
                Label(
                    "\(progress.activity.title) \(progress.currentSourceName)",
                    systemImage: progress.activity.symbol
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                Spacer(minLength: 0)
                if progress.totalCount > 0 {
                    Text(progress.counter)
                        .font(
                            .caption2.monospacedDigit().weight(.bold)
                        )
                        .foregroundStyle(PPColor.mint)
                }
                Button {
                    verificationTask?.cancel()
                    deliveryTask?.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityLabel("Cancel verification")
            }
            ProgressView(value: progress.fractionCompleted)
                .tint(PPColor.mint)
            if let byteSummary = progress.byteSummary {
                TimelineView(
                    .periodic(from: .now, by: 1)
                ) { context in
                    let isStalled = progress.isStalled(
                        at: context.date
                    )
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: PPSpacing.medium) {
                            byteProgressLabel(byteSummary)
                            Spacer(minLength: 0)
                            throughputAndRemaining(
                                progress,
                                isStalled: isStalled
                            )
                        }
                        VStack(
                            alignment: .leading,
                            spacing: 3
                        ) {
                            byteProgressLabel(byteSummary)
                            HStack(spacing: PPSpacing.medium) {
                                throughputAndRemaining(
                                    progress,
                                    isStalled: isStalled
                                )
                            }
                        }
                    }
                    .contentTransition(.numericText())
                }
            }
        }
        .padding(.vertical, PPSpacing.xSmall)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func byteProgressLabel(
        _ byteSummary: String
    ) -> some View {
        Label(byteSummary, systemImage: "externaldrive")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(PPColor.textSecondary)
    }

    @ViewBuilder
    private func throughputAndRemaining(
        _ progress: PDFOfficeIntegrityProgress,
        isStalled: Bool
    ) -> some View {
        if isStalled {
            Text("0 B/s")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.amber)
        } else if let throughput = progress.throughputSummary {
            Label(throughput, systemImage: "speedometer")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.cyan)
        }
        if !isStalled,
           let remaining = progress.remainingSummary {
            Label(remaining, systemImage: "clock")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        ByteTelemetrySparkline(
            samples: progress.throughputHistory,
            isStalled: isStalled
        )
        if isStalled {
            Label("Stalled", systemImage: "pause.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.amber)
        }
    }

    private func resourceMetric(
        _ value: String,
        label: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value.localizedUI)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps())
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
        }
    }

    private var currentForecast: PDFOfficeStorageForecast {
        model.officeProductionForecast(
            recordIDs: selectedRecordIDs,
            format: formatChoice.format
        )
    }

    private var completedJobIDs: Set<UUID> {
        Set(
            model.officeProductionQueue.jobs
                .filter { $0.stage == .completed }
                .map(\.id)
        )
    }

    private var resourceTint: Color {
        switch model.officeResourceSnapshot.mode {
        case .ready: return PPColor.mint
        case .conserving: return PPColor.amber
        case .blocked: return Color.red
        }
    }

    private func verifyReadyOutputs() {
        guard !completedJobIDs.isEmpty else { return }
        isPreparingDelivery = true
        verificationTask?.cancel()
        verificationTask = Task {
            defer {
                isPreparingDelivery = false
                verificationTask = nil
            }
            do {
                let report = try await model
                    .verifyOfficeProductionOutputs(
                        jobIDs: completedJobIDs
                    )
                if report.isVerified {
                    deliveryFeedback += 1
                }
            } catch is CancellationError {
                return
            } catch {
                model.present(error)
            }
        }
    }

    private func packageReadyOutputs() {
        guard !completedJobIDs.isEmpty else { return }
        isPreparingDelivery = true
        deliveryTask?.cancel()
        deliveryTask = Task {
            defer {
                isPreparingDelivery = false
                deliveryTask = nil
            }
            do {
                let retained = try await model
                    .makeOfficeProductionDeliveryPackage(
                        jobIDs: completedJobIDs
                    )
                deliveryShareURL = retained.1
                deliveryFeedback += 1
                isPresentingDeliveryShare = true
            } catch is CancellationError {
                return
            } catch {
                model.present(error)
            }
        }
    }

    private func shareDeliveryPackage(
        _ package: PDFOfficeDeliveryPackage,
        reportOnly: Bool
    ) {
        deliveryTask?.cancel()
        isPreparingDelivery = true
        deliveryTask = Task {
            defer {
                isPreparingDelivery = false
                deliveryTask = nil
            }
            do {
                let urls = try await model.officeDeliveryPackageURLs(
                    package
                )
                deliveryShareURL = reportOnly
                    ? urls.report
                    : urls.archive
                isPresentingDeliveryShare = true
            } catch is CancellationError {
                return
            } catch {
                model.present(error)
            }
        }
    }

    private func stageTint(
        _ stage: PDFOfficeQueueJobStage
    ) -> Color {
        switch stage {
        case .completed:
            return PPColor.mint
        case .attention:
            return PPColor.amber
        case .cancelled, .paused:
            return PPColor.textSecondary
        case .queued, .analyzing, .rebuilding, .retaining:
            return PPColor.cyan
        }
    }

    private func priorityTint(
        _ priority: PDFOfficeQueuePriority
    ) -> Color {
        switch priority {
        case .urgent: return PPColor.amber
        case .normal: return PPColor.cyan
        case .background: return PPColor.textSecondary
        }
    }
}

private struct OfficeDeliveryFileMatchView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let report: PDFOfficeExternalMatchReport
    let deliveryReport: PDFOfficeSignedVerificationReport?
    let inspection: PDFOfficeMatchReportInspection?
    let trustStatus: PDFOfficeSignerTrustStatus
    let trustedSignerName: String?
    let onChooseAgain: (() -> Void)?

    @State private var exportTask: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var isSharing = false
    @State private var isConfirmingExport = false
    @State private var exportFeedback = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        if inspection != nil {
                            verificationSection
                        }
                        resultHeader
                        evidenceBoundary
                        matchSection
                        if !report.extraCandidates.isEmpty {
                            extraSection
                        }
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, inspection == nil ? 88 : 0)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(
                inspection == nil
                    ? "Delivery File Match"
                    : "Signed Delivery Match"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(exportTask != nil)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if inspection == nil {
                    actionFooter
                }
            }
        }
        .interactiveDismissDisabled(exportTask != nil)
        .sheet(isPresented: $isSharing, onDismiss: removeShareFile) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .confirmationDialog(
            "Share signed delivery match report?",
            isPresented: $isConfirmingExport,
            titleVisibility: .visible
        ) {
            Button("Create and Share") {
                exportReport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The JSON includes source PDF names, delivery output names, selected file names, byte sizes, and SHA-256 fingerprints. Document bytes are not included."
            )
        }
        .sensoryFeedback(.success, trigger: exportFeedback)
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            removeShareFile()
        }
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "REPORT VERIFICATION")
            if let inspection {
                verificationFact(
                    "Source file",
                    value: inspection.sourceFileName,
                    symbol: "doc"
                )
                verificationFact(
                    "Match report signature",
                    value: inspection.signatureStatus.title.localizedUI,
                    symbol: inspection.signatureStatus.symbol
                )
                verificationFact(
                    "Match report signer",
                    value:
                        inspection.trustedSignerName
                            ?? inspection.trustStatus.title.localizedUI,
                    symbol: inspection.trustStatus.symbol
                )
                verificationFact(
                    "Match report Key ID",
                    value:
                        inspection.signedReport.signature.keyID,
                    symbol: "key"
                )
                verificationFact(
                    "Delivery report signature",
                    value:
                        inspection.deliverySignatureStatus
                            .title.localizedUI,
                    symbol:
                        inspection.deliverySignatureStatus.symbol
                )
                verificationFact(
                    "Delivery report signer",
                    value:
                        inspection.deliveryTrustedSignerName
                            ?? inspection.deliveryTrustStatus
                                .title.localizedUI,
                    symbol: inspection.deliveryTrustStatus.symbol
                )
                Label(
                    inspection.detail.localizedUI,
                    systemImage: inspection.isVerified
                        ? "checkmark.shield"
                        : "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(verificationColor)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var actionFooter: some View {
        VStack(spacing: PPSpacing.small) {
            if exportTask != nil {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Signing delivery match report".localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    chooseAgainButton
                    shareReportButton
                }
                VStack(spacing: PPSpacing.small) {
                    shareReportButton
                    chooseAgainButton
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private var chooseAgainButton: some View {
        Button {
            dismiss()
            onChooseAgain?()
        } label: {
            Label(
                "Choose Again",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(
            PPQuietButtonStyle(tint: PPColor.cyan)
        )
        .disabled(
            onChooseAgain == nil
                || exportTask != nil
                || isSharing
        )
    }

    private var shareReportButton: some View {
        Button {
            isConfirmingExport = true
        } label: {
            Label(
                exportTask == nil
                    ? "Share Signed Report"
                    : "Preparing Report",
                systemImage: exportTask == nil
                    ? "square.and.arrow.up"
                    : "hourglass"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            deliveryReport == nil
                || exportTask != nil
                || isSharing
        )
    }

    private var resultHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "DELIVERY BYTE MATCH",
            title: inspectionTitle ?? resultTitle,
            detail: AppLocalization.format(
                "%lld selected files | %@ checked",
                report.totalCandidateCount,
                ByteCountFormatter.string(
                    fromByteCount: report.totalCandidateBytes,
                    countStyle: .file
                )
            ),
            symbol: evidenceVerified
                ? (
                    report.isComplete
                        ? "checkmark.seal.fill"
                        : "doc.text.magnifyingglass"
                )
                : "xmark.seal.fill",
            tint: evidenceVerified
                ? (report.isComplete ? PPColor.mint : PPColor.amber)
                : PPColor.rose,
            metrics: [
                WorkflowMetric(
                    value: "\(report.exactCount)",
                    label: "Exact",
                    symbol: "equal.circle",
                    tint: evidenceVerified
                        ? PPColor.mint
                        : PPColor.rose
                ),
                WorkflowMetric(
                    value:
                        "\(report.missingCount + report.ambiguousCount + report.inconsistentCount)",
                    label: "Review",
                    symbol: "exclamationmark.triangle",
                    tint: evidenceVerified
                        ? PPColor.amber
                        : PPColor.rose
                ),
                WorkflowMetric(
                    value: "\(report.extraCandidates.count)",
                    label: "Extra",
                    symbol: "plus.square.on.square",
                    tint: evidenceVerified
                        ? (
                            report.extraCandidates.isEmpty
                                ? PPColor.textSecondary
                                : PPColor.rose
                        )
                        : PPColor.rose
                )
            ]
        )
    }

    private var evidenceBoundary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                evidenceVerified
                    ? "The report signature was verified first. File matches use complete SHA-256 bytes; names are labels only."
                    : "This imported report did not pass complete verification. Its saved conclusions are untrusted.",
                systemImage: evidenceVerified
                    ? "checkmark.shield"
                    : "exclamationmark.shield"
            )
            Label(
                AppLocalization.format(
                    "Delivery signer: %@",
                    (
                        trustedSignerName
                            ?? trustStatus.title
                    ).localizedUI
                ),
                systemImage: trustStatus.symbol
            )
            Label(
                "A byte match does not establish legal identity or a trusted timestamp.",
                systemImage: "info.circle"
            )
        }
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(
                text: evidenceVerified
                    ? "SIGNED OUTPUT ORDER"
                    : "UNVERIFIED OUTPUT ORDER"
            )
                .padding(.bottom, PPSpacing.small)
            ForEach(
                Array(report.matches.enumerated()),
                id: \.element.id
            ) { offset, match in
                matchRow(match, number: offset + 1)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private var extraSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "NOT IN REPORT")
                .padding(.bottom, PPSpacing.small)
            ForEach(report.extraCandidates) { candidate in
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "plus.square.on.square")
                        .foregroundStyle(PPColor.rose)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.fileName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(candidate.formattedSize) | SHA-256 \(candidate.shortFingerprint)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }
                }
                .frame(minHeight: 54)
                .accessibilityElement(children: .combine)
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
                    .padding(.leading, 42)
            }
        }
    }

    private func matchRow(
        _ match: PDFOfficeExternalEntryMatch,
        number: Int
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.black))
                .foregroundStyle(PPColor.surface)
                .frame(width: 24, height: 24)
                .background(matchColor(match.status), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(match.entry.archiveName)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Text(
                        match.entry.format.fileExtension.uppercased()
                    )
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(PPColor.cyan)
                }
                Text(match.entry.sourceName)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Text(candidateSummary(match))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PPSpacing.small)
            Image(systemName: match.status.symbol)
                .foregroundStyle(matchColor(match.status))
                .accessibilityLabel(match.status.title.localizedUI)
        }
        .frame(minHeight: 72)
        .accessibilityElement(children: .combine)
    }

    private var resultTitle: String {
        if report.isComplete {
            return "Every delivery file matches"
        }
        if report.exactCount > 0 {
            return "Some delivery files need review"
        }
        return "No delivery files matched"
    }

    private var inspectionTitle: String? {
        guard let inspection else { return nil }
        guard inspection.isVerified else {
            return "Delivery match not verified"
        }
        if inspection.trustStatus == .unknown
            || inspection.deliveryTrustStatus == .unknown {
            return "Valid signatures, review signers"
        }
        switch inspection.trustStatus {
        case .thisDevice:
            return "Signed match from this device"
        case .trusted:
            return "Signed match from a trusted source"
        case .unknown:
            return "Valid match, unknown signer"
        case .invalid:
            return "Delivery match not verified"
        case .unsupported:
            return "Unsupported delivery match"
        }
    }

    private var evidenceVerified: Bool {
        inspection?.isVerified ?? true
    }

    private var verificationColor: Color {
        guard let inspection else { return PPColor.mint }
        guard inspection.isVerified else { return PPColor.rose }
        if inspection.trustStatus == .unknown
            || inspection.deliveryTrustStatus == .unknown {
            return PPColor.amber
        }
        if inspection.trustStatus == .invalid
            || inspection.trustStatus == .unsupported
            || inspection.deliveryTrustStatus == .invalid
            || inspection.deliveryTrustStatus == .unsupported {
            return PPColor.rose
        }
        switch inspection.trustStatus {
        case .thisDevice, .trusted: return PPColor.mint
        case .unknown: return PPColor.amber
        case .invalid, .unsupported: return PPColor.rose
        }
    }

    private func verificationFact(
        _ title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(verificationColor)
                .frame(width: 24)
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            Spacer(minLength: PPSpacing.small)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(minHeight: 34)
    }

    private func candidateSummary(
        _ match: PDFOfficeExternalEntryMatch
    ) -> String {
        guard !match.candidates.isEmpty else {
            return match.status.title.localizedUI
        }
        let names = match.candidates.prefix(2).map(\.fileName)
            .joined(separator: ", ")
        let remaining = match.candidates.count - min(
            2,
            match.candidates.count
        )
        if remaining > 0 {
            return AppLocalization.format(
                "%@ and %lld more",
                names,
                remaining
            )
        }
        return names
    }

    private func matchColor(
        _ status: PDFOfficeExternalMatchStatus
    ) -> Color {
        guard evidenceVerified else { return PPColor.rose }
        switch status {
        case .exact: return PPColor.mint
        case .missing, .ambiguous, .inconsistent:
            return PPColor.amber
        }
    }

    private func exportReport() {
        guard exportTask == nil,
              !isSharing,
              let deliveryReport
        else { return }
        removeShareFile()
        exportTask = Task {
            let url = await model.exportSignedOfficeMatchReport(
                deliveryReport: deliveryReport,
                matchReport: report
            )
            let wasCancelled = Task.isCancelled
            exportTask = nil
            guard !wasCancelled, let url else {
                if let url {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            shareURL = url
            exportFeedback += 1
            isSharing = true
        }
    }

    private func removeShareFile() {
        guard let shareURL else { return }
        try? FileManager.default.removeItem(at: shareURL)
        self.shareURL = nil
    }
}

private struct OfficeSigningIdentityView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let identity: PDFOfficeSignerIdentityCard?
    let trustedSigners: [PDFOfficeTrustedSigner]
    let onShare: () -> Void
    let onRemoveTrustedSigner: (String) -> Void

    @State private var copyFeedback = 0
    @State private var isScanningIdentity = false
    @State private var isImportingIdentity = false
    @State private var candidateIdentity:
        PDFOfficeSignerIdentityCard?
    @State private var scannerMessage: String?
    @State private var editingSigner: PDFOfficeTrustedSigner?
    @State private var isPickingIdentityPhoto = false
    @State private var selectedIdentityPhoto: PhotosPickerItem?
    @State private var isDecodingIdentityPhoto = false
    @State private var identityPhotoCandidates:
        [PDFOfficeSignerIdentityCard] = []
    @State private var identityPhotoAnalysis:
        SignerIdentityPhotoScanResult?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        identityHeader
                        if let identity {
                            identityExchange(identity)
                        }
                        if !identityPhotoCandidates.isEmpty {
                            multipleIdentityCandidatesSection
                        } else if let candidateIdentity {
                            candidateIdentitySection(
                                candidateIdentity
                            )
                        } else if let scannerMessage {
                            scannerMessageSection(scannerMessage)
                        }
                        trustedSignerSection
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Signing Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            requestIdentityScanner()
                        } label: {
                            Label(
                                "Scan Identity",
                                systemImage: "qrcode.viewfinder"
                            )
                        }
                        Button {
                            isImportingIdentity = true
                        } label: {
                            Label(
                                "Import Identity Card",
                                systemImage: "folder"
                            )
                        }
                        Button {
                            isPickingIdentityPhoto = true
                        } label: {
                            Label(
                                "Choose QR Photo",
                                systemImage: "photo"
                            )
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("Add trusted signer")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isScanningIdentity) {
                SignerIdentityScannerSheet(
                    onDetected: handleScannedIdentity,
                    onCancel: {
                        isScanningIdentity = false
                    }
                )
            }
            .sheet(item: $editingSigner) { signer in
                TrustedSignerEditorView(signer: signer) {
                    displayName,
                    note in
                    Task {
                        if await model.updateOfficeTrustedSigner(
                            keyID: signer.keyID,
                            displayName: displayName,
                            note: note
                        ) {
                            editingSigner = nil
                            copyFeedback += 1
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $isImportingIdentity,
                allowedContentTypes: [.json]
            ) { result in
                handleIdentityImport(result)
            }
            .photosPicker(
                isPresented: $isPickingIdentityPhoto,
                selection: $selectedIdentityPhoto,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: selectedIdentityPhoto) { _, item in
                guard let item else { return }
                handleIdentityPhoto(item)
            }
        }
        .sensoryFeedback(.success, trigger: copyFeedback)
    }

    private var identityHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "LOCAL SIGNING IDENTITY",
            title: identity.map {
                "Key \($0.keyID.prefix(12))"
            } ?? "Identity unavailable",
            detail: "Ed25519 · device local",
            symbol: "checkmark.seal.fill",
            tint: PPColor.mint,
            metrics: [
                WorkflowMetric(
                    value: "Ed25519",
                    label: "Algorithm",
                    symbol: "function",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(trustedSigners.count)",
                    label: "Trusted",
                    symbol: "person.2",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "LOCAL",
                    label: "Private key",
                    symbol: "key.fill",
                    tint: PPColor.amber
                )
            ]
        )
    }

    private func identityExchange(
        _ identity: PDFOfficeSignerIdentityCard
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            SectionEyebrow(text: "PUBLIC IDENTITY")
            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .center,
                    spacing: PPSpacing.xLarge
                ) {
                    SignerIdentityQRCodeView(
                        payload: identity.qrPayload
                    )
                    identityDetails(identity)
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.medium
                ) {
                    SignerIdentityQRCodeView(
                        payload: identity.qrPayload
                    )
                    .frame(maxWidth: .infinity)
                    identityDetails(identity)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.mint.opacity(0.68))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private func identityDetails(
        _ identity: PDFOfficeSignerIdentityCard
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            VStack(alignment: .leading, spacing: 3) {
                Text("KEY ID".localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                Text(identity.keyID)
                    .font(.body.monospaced().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("PUBLIC KEY".localizedUI)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(PPColor.textSecondary)
                Text(identity.publicKeyBase64)
                    .font(.caption.monospaced())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: PPSpacing.small) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        identityActionButtons(identity)
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        identityActionButtons(identity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func identityActionButtons(
        _ identity: PDFOfficeSignerIdentityCard
    ) -> some View {
        Button {
            SecurePasteboard.copy(identity.keyID)
            copyFeedback += 1
        } label: {
            Label("Copy Key ID", systemImage: "doc.on.doc")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))

        Button {
            requestIdentityScanner()
        } label: {
            Label("Scan Identity", systemImage: "qrcode.viewfinder")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))

        Button {
            isPickingIdentityPhoto = true
        } label: {
            Label("Choose QR Photo", systemImage: "photo")
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
        .disabled(isDecodingIdentityPhoto)

        Button(action: onShare) {
            Label(
                "Share Identity",
                systemImage: "square.and.arrow.up"
            )
        }
        .buttonStyle(PPPrimaryButtonStyle())
    }

    private func candidateIdentitySection(
        _ candidate: PDFOfficeSignerIdentityCard
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title3)
                    .foregroundStyle(PPColor.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identity ready for review".localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(candidate.keyID)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                    if let identityPhotoAnalysis {
                        Text(identityPhotoAnalysis.summary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.cyan)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    candidateIdentity = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss identity candidate")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    evidenceValue(
                        "Key ID",
                        value: candidate.keyID
                    )
                    evidenceValue(
                        "Algorithm",
                        value: "Ed25519"
                    )
                    Spacer(minLength: 0)
                    trustCandidateButton(candidate)
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    HStack(spacing: PPSpacing.large) {
                        evidenceValue(
                            "Key ID",
                            value: candidate.keyID
                        )
                        evidenceValue(
                            "Algorithm",
                            value: "Ed25519"
                        )
                    }
                    trustCandidateButton(candidate)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.amber.opacity(0.7))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private var multipleIdentityCandidatesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: "qrcode")
                    .foregroundStyle(PPColor.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a signing identity".localizedUI)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        AppLocalization.format(
                            "%lld valid QR code%@ found",
                            identityPhotoCandidates.count,
                            identityPhotoCandidates.count == 1
                                ? "" : "s"
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    if let identityPhotoAnalysis {
                        Text(identityPhotoAnalysis.summary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.cyan)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    identityPhotoCandidates = []
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss identity candidates")
            }
            .padding(.bottom, PPSpacing.xSmall)

            ForEach(identityPhotoCandidates, id: \.keyID) {
                candidate in
                Button {
                    candidateIdentity = candidate
                    identityPhotoCandidates = []
                    copyFeedback += 1
                } label: {
                    HStack(spacing: PPSpacing.small) {
                        Image(
                            systemName:
                                "person.crop.circle.badge.questionmark"
                        )
                        .foregroundStyle(PPColor.amber)
                        .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.keyID)
                                .font(
                                    .subheadline.monospaced()
                                        .weight(.bold)
                                )
                                .foregroundStyle(PPColor.textPrimary)
                            Text("Ed25519 · verified identity card")
                                .font(.caption2)
                                .foregroundStyle(
                                    PPColor.textSecondary
                                )
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PPColor.cyan)
                    }
                    .padding(.vertical, PPSpacing.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.5))
                        .frame(height: 0.5)
                        .padding(.leading, 36)
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.cyan.opacity(0.7))
                .frame(height: 1)
        }
    }

    private func trustCandidateButton(
        _ candidate: PDFOfficeSignerIdentityCard
    ) -> some View {
        Button {
            Task {
                if await model.trustOfficeSignerIdentity(candidate) {
                    candidateIdentity = nil
                    copyFeedback += 1
                }
            }
        } label: {
            Label(
                "Trust Identity",
                systemImage: "person.crop.circle.badge.checkmark"
            )
        }
        .buttonStyle(PPPrimaryButtonStyle())
    }

    private func scannerMessageSection(
        _ message: String
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            if isDecodingIdentityPhoto {
                ProgressView()
                    .controlSize(.small)
                    .tint(PPColor.mint)
            } else {
                Image(systemName: "camera.fill")
                    .foregroundStyle(PPColor.amber)
            }
            Text(message.localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
            Spacer(minLength: 0)
            Button {
                scannerMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, PPSpacing.xSmall)
    }

    private func evidenceValue(
        _ label: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps())
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private var trustedSignerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "TRUSTED SIGNERS")
                Text("\(trustedSigners.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.mint)
            }
            .padding(.bottom, PPSpacing.xSmall)

            if trustedSigners.isEmpty {
                ContentUnavailableView(
                    "No trusted signers",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PPSpacing.large)
            } else {
                VStack(spacing: 0) {
                    ForEach(trustedSigners) { signer in
                        HStack(spacing: PPSpacing.small) {
                            Image(
                                systemName:
                                    "person.crop.circle.badge.checkmark"
                            )
                            .foregroundStyle(PPColor.mint)
                            .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signer.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .fontDesign(.serif)
                                    .foregroundStyle(PPColor.textPrimary)
                                Text(
                                    "\(signer.keyID) · \(signer.verificationCount) verified"
                                )
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(PPColor.textSecondary)
                                .lineLimit(1)
                                if let note = signer.note,
                                   !note.isEmpty {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(
                                            PPColor.textSecondary
                                        )
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(
                                signer.lastVerifiedAt.formatted(
                                    date: .abbreviated,
                                    time: .omitted
                                )
                            )
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                            Button {
                                editingSigner = signer
                            } label: {
                                Image(systemName: "pencil")
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit trusted signer")
                            Button(role: .destructive) {
                                onRemoveTrustedSigner(signer.keyID)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove trusted signer")
                        }
                        .padding(.vertical, PPSpacing.small)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.5))
                                .frame(height: 0.5)
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    private func requestIdentityScanner() {
        scannerMessage = nil
        guard DataScannerViewController.isSupported else {
            scannerMessage =
                "Identity scanning is unavailable on this device."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard DataScannerViewController.isAvailable else {
                scannerMessage =
                    "The camera is temporarily unavailable."
                return
            }
            isScanningIdentity = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(
                    for: .video
                )
                if granted, DataScannerViewController.isAvailable {
                    isScanningIdentity = true
                } else {
                    scannerMessage =
                        "Camera access is required to scan an identity."
                }
            }
        case .denied, .restricted:
            scannerMessage =
                "Camera access is required to scan an identity."
        @unknown default:
            scannerMessage =
                "Identity scanning is unavailable on this device."
        }
    }

    private func handleScannedIdentity(_ payload: String) {
        isScanningIdentity = false
        identityPhotoCandidates = []
        identityPhotoAnalysis = nil
        Task {
            do {
                candidateIdentity = try await model
                    .parseOfficeSignerIdentityPayload(payload)
                scannerMessage = nil
                copyFeedback += 1
            } catch {
                model.present(error)
            }
        }
    }

    private func handleIdentityImport(
        _ result: Result<URL, Error>
    ) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result {
                model.present(error)
            }
            return
        }
        Task {
            do {
                identityPhotoCandidates = []
                identityPhotoAnalysis = nil
                candidateIdentity = try await model
                    .loadOfficeSignerIdentityCard(at: url)
                scannerMessage = nil
                copyFeedback += 1
            } catch {
                model.present(error)
            }
        }
    }

    private func handleIdentityPhoto(
        _ item: PhotosPickerItem
    ) {
        isDecodingIdentityPhoto = true
        identityPhotoCandidates = []
        candidateIdentity = nil
        identityPhotoAnalysis = nil
        scannerMessage = "Reading identity QR from photo"
        Task {
            defer {
                isDecodingIdentityPhoto = false
                selectedIdentityPhoto = nil
            }
            do {
                guard let data = try await item.loadTransferable(
                    type: Data.self
                ),
                      !data.isEmpty,
                      data.count <= 24 * 1_024 * 1_024
                else {
                    throw PaperPathError.insufficientSelection(
                        "Choose an image under 24 MB."
                    )
                }
                let analysis = try await SignerIdentityPhotoDecoder
                    .analyze(data)
                identityPhotoAnalysis = analysis
                var cards: [PDFOfficeSignerIdentityCard] = []
                var seenKeyIDs: Set<String> = []
                for payload in analysis.payloads {
                    guard let card = try? await model
                        .parseOfficeSignerIdentityPayload(payload),
                          seenKeyIDs.insert(card.keyID).inserted
                    else { continue }
                    cards.append(card)
                    if cards.count == 12 { break }
                }
                guard !cards.isEmpty else {
                    throw PaperPathError.insufficientSelection(
                        "No valid PaperPath signing identities were found."
                    )
                }
                if cards.count == 1 {
                    candidateIdentity = cards[0]
                } else {
                    identityPhotoCandidates = cards
                }
                scannerMessage = nil
                copyFeedback += 1
            } catch is CancellationError {
                return
            } catch {
                scannerMessage = nil
                model.present(error)
            }
        }
    }
}

private struct SignerIdentityPhotoScanResult: Sendable {
    let payloads: [String]
    let sourceWidth: Int
    let sourceHeight: Int
    let analyzedMaxPixelSize: Int
    let passCount: Int

    var summary: String {
        AppLocalization.format(
            "%lld×%lld source · %lld px analysis · %lld pass%@",
            sourceWidth,
            sourceHeight,
            analyzedMaxPixelSize,
            passCount,
            passCount == 1 ? "" : "es"
        )
    }
}

private enum SignerIdentityPhotoDecoder {
    static func analyze(
        _ data: Data
    ) async throws -> SignerIdentityPhotoScanResult {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let sourceOptions = [
                kCGImageSourceShouldCache: false
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                sourceOptions
            ) else {
                throw PaperPathError.insufficientSelection(
                    "The selected image could not be decoded."
                )
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any]
            let width = (
                properties?[kCGImagePropertyPixelWidth] as? NSNumber
            )?.intValue ?? 0
            let height = (
                properties?[kCGImagePropertyPixelHeight] as? NSNumber
            )?.intValue ?? 0
            let sourceMax = max(width, height)
            guard width > 0, height > 0 else {
                throw PaperPathError.insufficientSelection(
                    "The selected image has invalid dimensions."
                )
            }
            var targetSizes = [min(sourceMax, 2_048)]
            if sourceMax > 2_048 {
                targetSizes.append(min(sourceMax, 4_096))
            }
            var seen: Set<String> = []
            var payloads: [String] = []
            for targetSize in targetSizes {
                try Task.checkCancellation()
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: targetSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options
                ) else { continue }
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                let handler = VNImageRequestHandler(
                    cgImage: image,
                    options: [:]
                )
                try handler.perform([request])
                for payload in request.results?
                    .compactMap(\.payloadStringValue) ?? []
                    where payload.hasPrefix(
                        "paperpath-signer:v1:"
                    ) && seen.insert(payload).inserted {
                    payloads.append(payload)
                }
            }
            try Task.checkCancellation()
            guard !payloads.isEmpty else {
                throw PaperPathError.insufficientSelection(
                    "No PaperPath signing identity QR code was found."
                )
            }
            return SignerIdentityPhotoScanResult(
                payloads: Array(payloads.prefix(64)),
                sourceWidth: width,
                sourceHeight: height,
                analyzedMaxPixelSize: targetSizes.last ?? sourceMax,
                passCount: targetSizes.count
            )
        }.value
    }
}

private struct SignerIdentityScannerSheet: View {
    let onDetected: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SignerIdentityDataScanner(onDetected: onDetected)
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        Color.white.opacity(0.85),
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: [10, 7]
                        )
                    )
                    .frame(width: 248, height: 248)
                    .allowsHitTesting(false)
            }
            .navigationTitle("Scan Signing Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct SignerIdentityDataScanner:
    UIViewControllerRepresentable {
    let onDetected: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetected: onDetected)
    }

    func makeUIViewController(
        context: Context
    ) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.qr])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ controller: DataScannerViewController,
        context: Context
    ) {
        guard !controller.isScanning else { return }
        try? controller.startScanning()
    }

    static func dismantleUIViewController(
        _ controller: DataScannerViewController,
        coordinator: Coordinator
    ) {
        controller.stopScanning()
    }

    final class Coordinator:
        NSObject,
        DataScannerViewControllerDelegate {
        let onDetected: (String) -> Void
        private var hasDetected = false

        init(onDetected: @escaping (String) -> Void) {
            self.onDetected = onDetected
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            inspect(addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            inspect(updatedItems)
        }

        private func inspect(_ items: [RecognizedItem]) {
            guard !hasDetected else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      payload.hasPrefix("paperpath-signer:v1:")
                else { continue }
                hasDetected = true
                onDetected(payload)
                return
            }
        }
    }
}

private struct TrustedSignerEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let signer: PDFOfficeTrustedSigner
    let onSave: (String, String) -> Void

    @State private var displayName: String
    @State private var note: String

    init(
        signer: PDFOfficeTrustedSigner,
        onSave: @escaping (String, String) -> Void
    ) {
        self.signer = signer
        self.onSave = onSave
        _displayName = State(initialValue: signer.displayName)
        _note = State(initialValue: signer.note ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    WorkflowCommandHeader(
                        eyebrow: "TRUSTED SIGNER",
                        title: displayName.isEmpty
                            ? "Signer \(signer.keyID.prefix(8))"
                            : displayName,
                        detail: signer.keyID,
                        symbol: "person.crop.circle.badge.checkmark",
                        tint: PPColor.mint,
                        metrics: [
                            WorkflowMetric(
                                value:
                                    "\(signer.verificationCount)",
                                label: "Verified",
                                symbol: "checkmark.seal",
                                tint: PPColor.mint
                            ),
                            WorkflowMetric(
                                value: signer.lastVerifiedAt.formatted(
                                    date: .abbreviated,
                                    time: .omitted
                                ),
                                label: "Last seen",
                                symbol: "clock",
                                tint: PPColor.cyan
                            )
                        ]
                    )

                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        SectionEyebrow(text: "SIGNER PROFILE")
                        TextField(
                            "Display name",
                            text: $displayName
                        )
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)

                        Text("NOTE".localizedUI)
                            .font(.caption2.smallCaps())
                            .foregroundStyle(PPColor.textSecondary)
                        TextEditor(text: $note)
                            .frame(minHeight: 88, maxHeight: 120)
                            .padding(PPSpacing.xSmall)
                            .background(
                                PPColor.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        PPColor.border,
                                        lineWidth: 0.6
                                    )
                            }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 620)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Edit Signer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(displayName, note)
                    }
                }
            }
        }
    }
}

private struct SignerIdentityQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = Self.makeQRCode(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Signing identity QR code")
            } else {
                Image(systemName: "qrcode")
                    .font(.largeTitle)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .frame(width: 184, height: 184)
        .padding(PPSpacing.small)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(PPColor.border, lineWidth: 0.7)
        }
    }

    private static func makeQRCode(
        _ payload: String
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(
            output,
            from: output.extent
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct BatchTagEditorView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordIDs: Set<UUID>

    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        selectionHeader
                        addControl
                        if !commonTags.isEmpty {
                            tagSection(
                                title: "ON EVERY DOCUMENT",
                                tags: commonTags,
                                actionSymbol: "minus"
                            ) { tag in
                                Task {
                                    await model.updateTags(
                                        recordIDs: recordIDs,
                                        removing: [tag]
                                    )
                                }
                            }
                        }
                        if !availableTags.isEmpty {
                            tagSection(
                                title: "ADD TO SELECTION",
                                tags: availableTags,
                                actionSymbol: "plus"
                            ) { tag in
                                Task {
                                    await model.updateTags(
                                        recordIDs: recordIDs,
                                        adding: [tag]
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Tag Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var selectionHeader: some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: "checkmark.circle",
                tint: PPColor.accent,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "BULK ORGANIZE")
                Text("\(selectedRecords.count) selected")
                    .font(.title3.bold())
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.bottom, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var addControl: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "NEW TAG")
            HStack(spacing: PPSpacing.small) {
                TextField("Client, project, topic", text: $newTag)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(addNewTag)
                    .onChange(of: newTag) { _, value in
                        if value.count > 24 {
                            newTag = String(value.prefix(24))
                        }
                    }
                Button(action: addNewTag) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(normalizedNewTag.isEmpty)
                .accessibilityLabel("Add tag to selected documents")
            }
            .padding(.horizontal, PPSpacing.medium)
            .frame(minHeight: 50)
            .background(PPColor.surface)
            .clipShape(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        PPColor.border.opacity(0.62),
                        lineWidth: 0.6
                    )
            }
        }
    }

    private func tagSection(
        title: String,
        tags: [String],
        actionSymbol: String,
        action: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: title)
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 112, maximum: 190),
                        spacing: PPSpacing.small
                    )
                ],
                alignment: .leading,
                spacing: PPSpacing.small
            ) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        action(tag)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: actionSymbol)
                                .font(.caption2.weight(.bold))
                            Text(tag)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 38)
                        .padding(.horizontal, PPSpacing.small)
                        .background(PPColor.surface)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 7,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 7,
                                style: .continuous
                            )
                            .stroke(
                                PPColor.border.opacity(0.62),
                                lineWidth: 0.6
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var selectedRecords: [DocumentRecord] {
        model.documents.filter {
            recordIDs.contains($0.id)
        }
    }

    private var commonTags: [String] {
        guard let first = selectedRecords.first else { return [] }
        return first.tags.filter { tag in
            selectedRecords.dropFirst().allSatisfy { record in
                record.tags.contains {
                    $0.caseInsensitiveCompare(tag) == .orderedSame
                }
            }
        }
        .sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var availableTags: [String] {
        var seen: Set<String> = []
        return model.documents
            .flatMap(\.tags)
            .filter { tag in
                let key = tag.lowercased()
                return !commonTags.contains {
                    $0.caseInsensitiveCompare(tag) == .orderedSame
                } && seen.insert(key).inserted
            }
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
    }

    private var normalizedNewTag: String {
        String(
            newTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(24)
        )
    }

    private func addNewTag() {
        guard !normalizedNewTag.isEmpty else { return }
        let tag = normalizedNewTag
        newTag = ""
        Task {
            await model.updateTags(
                recordIDs: recordIDs,
                adding: [tag]
            )
        }
    }
}

private enum TrashRetentionPolicy: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case never = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sevenDays: return "After 7 days"
        case .thirtyDays: return "After 30 days"
        case .ninetyDays: return "After 90 days"
        case .never: return "Never automatically"
        }
    }
}

private struct PaperTemplateCreatorView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let onCreated: (DocumentRoute) -> Void

    @State private var kind = PaperTemplateKind.lined
    @State private var size = PaperTemplateSize.letter
    @State private var pageCount = 3
    @State private var title = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xLarge
                ) {
                    HStack(alignment: .top, spacing: PPSpacing.large) {
                        templatePreview
                        VStack(alignment: .leading, spacing: 5) {
                            SectionEyebrow(text: "VECTOR PAPER")
                            Text(kind.title.localizedUI)
                                .font(.title2.bold())
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                            Text(
                                "\(size.title) · \(pageCount) page\(pageCount == 1 ? "" : "s")"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .monospacedDigit()
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: PPSpacing.small) {
                        SectionEyebrow(text: "PAPER")
                        Picker("Paper template", selection: $kind) {
                            ForEach(PaperTemplateKind.allCases) {
                                Label(
                                    $0.title.localizedUI,
                                    systemImage: $0.symbol
                                )
                                .tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: PPSpacing.small) {
                        SectionEyebrow(text: "DOCUMENT")
                        TextField("Document name", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: title) { _, value in
                                if value.count > 80 {
                                    title = String(value.prefix(80))
                                }
                            }

                        Picker("Page size", selection: $size) {
                            ForEach(PaperTemplateSize.allCases) {
                                Text($0.title).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)

                        Stepper(
                            value: $pageCount,
                            in: 1...50
                        ) {
                            LabeledContent(
                                "Pages",
                                value: "\(pageCount)"
                            )
                            .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: 620)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Create Paper PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let finalTitle = title
                        Task {
                            if let record = await model
                                .createPaperTemplate(
                                    kind: kind,
                                    size: size,
                                    pageCount: pageCount,
                                    title: finalTitle
                                ) {
                                onCreated(
                                    DocumentRoute(recordID: record.id)
                                )
                            }
                        }
                    }
                    .disabled(model.isImporting)
                }
            }
        }
    }

    private var templatePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white)
                .shadow(
                    color: .black.opacity(0.14),
                    radius: 8,
                    y: 4
                )
            templateLines
                .padding(12)
        }
        .frame(width: 84, height: 112)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var templateLines: some View {
        switch kind {
        case .blank:
            Color.clear
        case .lined:
            VStack(spacing: 8) {
                ForEach(0..<9, id: \.self) { _ in
                    Rectangle()
                        .fill(PPColor.cyan.opacity(0.22))
                        .frame(height: 1)
                }
            }
        case .grid:
            ZStack {
                VStack(spacing: 8) {
                    ForEach(0..<10, id: \.self) { _ in
                        Rectangle()
                            .fill(PPColor.cyan.opacity(0.18))
                            .frame(height: 1)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { _ in
                        Rectangle()
                            .fill(PPColor.cyan.opacity(0.18))
                            .frame(width: 1)
                    }
                }
            }
        case .checklist:
            VStack(spacing: 7) {
                ForEach(0..<8, id: \.self) { _ in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(PPColor.cyan.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Rectangle()
                            .fill(PPColor.cyan.opacity(0.18))
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}

private struct StorageCenterView: View {
    private enum StorageSort:
        String,
        CaseIterable,
        Identifiable {
        case size
        case category

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private struct StorageLedgerItem: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let symbol: String
        let tint: Color
        let retention: String
        let contract: String
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let onOpen: (UUID) -> Void

    @State private var snapshot: LocalStorageSnapshot?
    @State private var isRefreshing = false
    @State private var isConfirmingUnpinAllOfficeOutputs = false
    @State private var isConfirmingUnpinAllVersionMilestones = false
    @State private var storageSort = StorageSort.size
    @State private var pinnedVersionMilestones:
        [PDFVersionSnapshot] = []
    @State private var versionArchiveURL: URL?
    @State private var isSharingVersionArchive = false
    @State private var isCreatingVersionArchive = false
    @State private var versionArchiveCreationTask:
        Task<Void, Never>?
    @State private var isImportingVersionArchive = false
    @State private var isVerifyingVersionArchive = false
    @State private var versionArchiveVerificationReport:
        PDFVersionArchiveVerificationReport?
    @State private var presentedVersionArchiveVerificationReport:
        PDFVersionArchiveVerificationReport?
    @State private var versionArchiveVerificationTask:
        Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        storageHero
                        breakdown
                        versionArchiveIntegritySection
                        if !pinnedVersionMilestones.isEmpty {
                            pinnedVersionSection
                        }
                        if !model.pinnedOfficeOutputs.isEmpty {
                            pinnedOfficeOutputs
                        }
                        largestDocuments
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await refresh()
                }

                if snapshot == nil {
                    ProgressView("Measuring local storage")
                        .padding(PPSpacing.large)
                        .background(.regularMaterial)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 8,
                                style: .continuous
                            )
                        )
                }
            }
            .navigationTitle("Local Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Measure storage again")
                }
            }
        }
        .task {
            await refresh()
        }
        .confirmationDialog(
            "Return all pinned Office outputs to standard retention?",
            isPresented: $isConfirmingUnpinAllOfficeOutputs,
            titleVisibility: .visible
        ) {
            Button("Unpin All Outputs", role: .destructive) {
                Task {
                    await model.unpinAllOfficeExports()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Expired outputs may be removed from local storage. Audit receipts remain."
            )
        }
        .confirmationDialog(
            "Return all version milestones to standard retention?",
            isPresented: $isConfirmingUnpinAllVersionMilestones,
            titleVisibility: .visible
        ) {
            Button("Unpin All Milestones", role: .destructive) {
                Task {
                    await model.unpinAllVersionMilestones()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Retained versions keep milestone names and receipt links. Older versions may be removed immediately by the 12-version and 1 GB rotation policy."
            )
        }
        .sheet(isPresented: $isSharingVersionArchive) {
            if let versionArchiveURL {
                ShareSheet(items: [versionArchiveURL])
            }
        }
        .sheet(item: $presentedVersionArchiveVerificationReport) {
            report in
            VersionArchiveVerificationView(
                report: report
            ) { candidate in
                let updated = await model
                    .trustVersionArchiveSigner(candidate)
                if let updated {
                    versionArchiveVerificationReport = updated
                    presentedVersionArchiveVerificationReport = updated
                }
                return updated
            }
        }
        .fileImporter(
            isPresented: $isImportingVersionArchive,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first
            else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            verifyVersionArchive(url)
        }
        .onDisappear {
            versionArchiveCreationTask?.cancel()
            versionArchiveCreationTask = nil
            versionArchiveVerificationTask?.cancel()
            versionArchiveVerificationTask = nil
            if let versionArchiveURL {
                try? FileManager.default.removeItem(
                    at: versionArchiveURL.deletingLastPathComponent()
                )
                self.versionArchiveURL = nil
            }
        }
    }

    private var storageHero: some View {
        HStack(spacing: PPSpacing.large) {
            ZStack {
                Circle()
                    .stroke(
                        PPColor.border.opacity(0.55),
                        lineWidth: 8
                    )
                Circle()
                    .trim(from: 0, to: pdfShare)
                    .stroke(
                        PPColor.accent,
                        style: StrokeStyle(
                            lineWidth: 8,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "internaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(PPColor.accent)
            }
            .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 4) {
                SectionEyebrow(text: "ON THIS DEVICE")
                Text(formatted(snapshot?.totalBytes ?? 0))
                    .font(.title.bold())
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .monospacedDigit()
                Text(
                    "\(model.documents.count) active · \(model.deletedDocuments.count) in Trash"
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .monospacedDigit()
            }
            Spacer()
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: "CAPACITY LEDGER",
                detail: "Category · size · share · retention",
                symbol: "chart.bar.doc.horizontal",
                count: 8,
                tint: PPColor.accent
            )
            .padding(.bottom, PPSpacing.small)

            HStack(spacing: PPSpacing.small) {
                Picker("Storage sort", selection: $storageSort) {
                    ForEach(StorageSort.allCases) { sort in
                        Text(sort.title.localizedUI).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
                Text("Largest first".localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .opacity(storageSort == .size ? 1 : 0)
            }
            .padding(.bottom, PPSpacing.small)

            storageLedgerHeader
            ForEach(sortedStorageItems) { item in
                storageLedgerRow(
                    title: item.title,
                    bytes: item.bytes,
                    symbol: item.symbol,
                    tint: item.tint,
                    retention: item.retention,
                    contract: item.contract
                )
            }
        }
    }

    private var sortedStorageItems: [StorageLedgerItem] {
        let items = [
            StorageLedgerItem(
                id: "pdf",
                title: "PDF working copies",
                bytes: snapshot?.pdfBytes ?? 0,
                symbol: "doc.on.doc",
                tint: PPColor.accent,
                retention: "Until Trash",
                contract: "\(model.documents.count) active"
            ),
            StorageLedgerItem(
                id: "versions",
                title: "Recovery versions",
                bytes: snapshot?.versionBytes ?? 0,
                symbol: "clock.arrow.circlepath",
                tint: PPColor.mint,
                retention: "Version policy",
                contract: "Recoverable history"
            ),
            StorageLedgerItem(
                id: "indices",
                title: "Text indexes",
                bytes: snapshot?.textIndexBytes ?? 0,
                symbol: "text.magnifyingglass",
                tint: PPColor.cyan,
                retention: "With PDF",
                contract: "\(model.textIndices.count) indexes"
            ),
            StorageLedgerItem(
                id: "ocr",
                title: "Local OCR",
                bytes: snapshot?.ocrBytes ?? 0,
                symbol: "viewfinder",
                tint: PPColor.mint,
                retention: "With PDF",
                contract: "\(model.ocrResults.count) result sets"
            ),
            StorageLedgerItem(
                id: "checks",
                title: "Delivery checks",
                bytes: snapshot?.deliveryCacheBytes ?? 0,
                symbol: "checkmark.shield",
                tint: PPColor.amber,
                retention: "Rebuildable",
                contract: "Verification cache"
            ),
            StorageLedgerItem(
                id: "office",
                title: "Reusable Office outputs",
                bytes: snapshot?.officeExportBytes ?? 0,
                symbol: "shippingbox.fill",
                tint: PPColor.cyan,
                retention: "Receipt policy",
                contract: model.pinnedOfficeStorageSummary
                    .countContract
            ),
            StorageLedgerItem(
                id: "packages",
                title: "Office delivery packages",
                bytes: snapshot?.officeDeliveryBytes ?? 0,
                symbol: "archivebox.fill",
                tint: PPColor.mint,
                retention: "Temporary",
                contract: "Share packages"
            ),
            StorageLedgerItem(
                id: "metadata",
                title: "Library metadata",
                bytes: snapshot?.metadataBytes ?? 0,
                symbol: "list.bullet.rectangle",
                tint: PPColor.textSecondary,
                retention: "Library lifetime",
                contract: "Records and receipts"
            )
        ]
        switch storageSort {
        case .size:
            return items.sorted {
                if $0.bytes != $1.bytes {
                    return $0.bytes > $1.bytes
                }
                return $0.title < $1.title
            }
        case .category:
            return items
        }
    }

    private var storageLedgerHeader: some View {
        HStack(spacing: PPSpacing.small) {
            Text("CATEGORY")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("SIZE")
                .frame(width: 78, alignment: .trailing)
            Text("SHARE")
                .frame(width: 64, alignment: .trailing)
            Text("RETENTION")
                .frame(width: 116, alignment: .leading)
        }
        .font(.caption2.smallCaps().weight(.bold))
        .foregroundStyle(PPColor.textSecondary)
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
    }

    private func storageLedgerRow(
        title: String,
        bytes: Int64,
        symbol: String,
        tint: Color,
        retention: String,
        contract: String
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(contract.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(formatted(bytes))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .frame(width: 78, alignment: .trailing)
                Text(storagePercent(bytes))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 64, alignment: .trailing)
                Text(retention.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
                    .frame(width: 116, alignment: .leading)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(PPColor.surfaceMuted)
                    Rectangle()
                        .fill(tint)
                        .frame(
                            width: proxy.size.width
                                * storageFraction(bytes)
                        )
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.52))
                .frame(height: 0.6)
        }
    }

    private var pinnedOfficeOutputs: some View {
        let summary = model.pinnedOfficeStorageSummary
        let outputs = Array(model.pinnedOfficeOutputs.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "PINNED OFFICE OUTPUTS")
                Text(summary.countContract)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.cyan)
                Spacer(minLength: 0)
                Text(summary.byteContract)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Button {
                    isConfirmingUnpinAllOfficeOutputs = true
                } label: {
                    Image(systemName: "pin.slash")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.amber)
                .accessibilityLabel("Unpin all Office outputs")
            }
            .padding(.bottom, PPSpacing.xSmall)

            ForEach(Array(outputs.enumerated()), id: \.element.id) {
                index,
                output in
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: output.receipt.format.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.cyan)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(
                                output.receipt.format.fileExtension
                                    .uppercased()
                            )
                            .font(.caption2.smallCaps().weight(.black))
                            .foregroundStyle(PPColor.cyan)
                            Text(output.documentName)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(1)
                        }
                        Text(
                            "\(output.receipt.formattedSize) · \(output.receipt.batchSummary ?? output.receipt.qualityGateSummary)"
                                .localizedUI
                        )
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onOpen(output.recordID)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.accent)
                    .accessibilityLabel(
                        "Open \(output.documentName)"
                    )

                    Button {
                        Task {
                            await model.setOfficeExportPinned(
                                recordID: output.recordID,
                                receiptID: output.receipt.id,
                                pinned: false
                            )
                            await refresh()
                        }
                    } label: {
                        Image(systemName: "pin.slash")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityLabel(
                        "Unpin \(output.receipt.fileName)"
                    )
                }
                .padding(.vertical, PPSpacing.small)

                if index < outputs.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.56))
                        .frame(height: 0.6)
                        .padding(.leading, 32)
                }
            }

            if model.pinnedOfficeOutputs.count > outputs.count {
                Text(
                    AppLocalization.format(
                        "%lld more pinned outputs",
                        model.pinnedOfficeOutputs.count - outputs.count
                    )
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .padding(.top, PPSpacing.xSmall)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
                .offset(y: 27)
        }
    }

    private var versionArchiveIntegritySection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            StudioSectionRule(
                title: "VERSION ARCHIVE INTEGRITY",
                detail: "ZIP structure · manifest · CRC · SHA-256",
                symbol: "checkmark.shield",
                count: versionArchiveVerificationReport?
                    .manifestEntryCount,
                tint: versionArchiveVerificationReport?.status
                    == .failed
                    || versionArchiveVerificationReport?
                        .hasInvalidSourceSignature == true
                    ? PPColor.rose
                    : PPColor.cyan
            )

            HStack(spacing: PPSpacing.medium) {
                if let report = versionArchiveVerificationReport {
                    Image(
                        systemName: report.hasInvalidSourceSignature
                            ? report.signatureStatus.symbol
                            : report.status.symbol
                    )
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                            archiveStatusColor(report)
                        )
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.archiveName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(report.verifiedCount)/\(report.manifestEntryCount) verified · \(report.provenanceTitle.localizedUI) · \(report.formattedSize)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        presentedVersionArchiveVerificationReport = report
                    } label: {
                        Label(
                            "Open Report",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(
                            tint: archiveStatusColor(report)
                        )
                    )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recheck an exported milestone archive")
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            "Reads the ZIP in place without importing its PDFs."
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                Button {
                    isImportingVersionArchive = true
                } label: {
                    Label(
                        isVerifyingVersionArchive
                            ? "Verifying"
                            : "Choose Archive",
                        systemImage: isVerifyingVersionArchive
                            ? "hourglass"
                            : "folder.badge.questionmark"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
                .disabled(isVerifyingVersionArchive)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func archiveStatusColor(
        _ report: PDFVersionArchiveVerificationReport
    ) -> Color {
        if report.status == .failed
            || report.hasInvalidSourceSignature {
            return PPColor.rose
        }
        switch report.trustStatus {
        case .thisDevice, .trusted:
            return PPColor.mint
        case .unknown:
            return PPColor.amber
        case .unsupported:
            return PPColor.cyan
        case .invalid:
            return PPColor.rose
        }
    }

    private func verifyVersionArchive(_ url: URL) {
        versionArchiveVerificationTask?.cancel()
        isVerifyingVersionArchive = true
        versionArchiveVerificationTask = Task {
            let report = await model.verifyPinnedVersionArchive(
                at: url
            )
            guard !Task.isCancelled else { return }
            isVerifyingVersionArchive = false
            versionArchiveVerificationTask = nil
            guard let report else { return }
            versionArchiveVerificationReport = report
            presentedVersionArchiveVerificationReport = report
        }
    }

    private var pinnedVersionSection: some View {
        let summary = pinnedVersionSummary
        let milestones = Array(pinnedVersionMilestones.prefix(8))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                SectionEyebrow(text: "PINNED VERSION MILESTONES")
                Text(summary.countContract)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(
                        summary.isNearCapacity
                            ? PPColor.amber
                            : PPColor.mint
                    )
                Spacer(minLength: 0)
                Text(summary.byteContract)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Button {
                    createPinnedVersionArchive()
                } label: {
                    Image(
                        systemName: isCreatingVersionArchive
                            ? "hourglass"
                            : "archivebox"
                    )
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .disabled(isCreatingVersionArchive)
                .accessibilityLabel("Export pinned version archive")
                Button {
                    isConfirmingUnpinAllVersionMilestones = true
                } label: {
                    Image(systemName: "pin.slash")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.amber)
                .accessibilityLabel("Unpin all version milestones")
            }
            .padding(.bottom, PPSpacing.xSmall)

            if summary.isNearCapacity {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(PPColor.amber)
                    Text(
                        "Pinned milestones are nearing the 1 GB library budget."
                            .localizedUI
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                }
                .padding(.vertical, PPSpacing.small)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(PPColor.amber)
                        .frame(width: 2)
                }
            }

            ForEach(
                Array(milestones.enumerated()),
                id: \.element.id
            ) { index, milestone in
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "pin.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.mint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(milestone.displayTitle.localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            "\(versionDocumentName(milestone)) · \(milestone.formattedSize) · \(milestone.pageCount) pages"
                        )
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onOpen(milestone.documentID)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.accent)
                    .accessibilityLabel(
                        "Open \(versionDocumentName(milestone))"
                    )

                    Button {
                        Task {
                            await model.setVersionMilestonePinned(
                                milestone,
                                pinned: false
                            )
                            await refresh()
                        }
                    } label: {
                        Image(systemName: "pin.slash")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                    .accessibilityLabel(
                        "Unpin \(milestone.displayTitle)"
                    )
                }
                .padding(.vertical, PPSpacing.small)

                if index < milestones.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.56))
                        .frame(height: 0.6)
                        .padding(.leading, 32)
                }
            }

            if pinnedVersionMilestones.count > milestones.count {
                Text(
                    AppLocalization.format(
                        "%lld more pinned milestones",
                        pinnedVersionMilestones.count - milestones.count
                    )
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .padding(.top, PPSpacing.xSmall)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
                .offset(y: 27)
        }
    }

    private var pinnedVersionSummary:
        PDFPinnedVersionStorageSummary {
        PDFPinnedVersionStorageSummary(
            milestoneCount: pinnedVersionMilestones.count,
            byteCount: pinnedVersionMilestones.reduce(Int64(0)) {
                $0 + max(0, $1.byteCount)
            }
        )
    }

    private func versionDocumentName(
        _ milestone: PDFVersionSnapshot
    ) -> String {
        model.record(id: milestone.documentID)?
            .displayName ?? "Unavailable document".localizedUI
    }

    private func createPinnedVersionArchive() {
        versionArchiveCreationTask?.cancel()
        isCreatingVersionArchive = true
        versionArchiveCreationTask = Task {
            let archive = await model.makePinnedVersionArchive()
            guard !Task.isCancelled else { return }
            isCreatingVersionArchive = false
            versionArchiveCreationTask = nil
            guard let archive else { return }
            if let previous = versionArchiveURL {
                try? FileManager.default.removeItem(
                    at: previous.deletingLastPathComponent()
                )
            }
            versionArchiveURL = archive
            isSharingVersionArchive = true
        }
    }

    private var largestDocuments: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "LARGEST PRIVATE COPIES")
                .padding(.bottom, PPSpacing.small)
            ForEach(
                Array(largestRecords.enumerated()),
                id: \.element.id
            ) { index, record in
                HStack(spacing: PPSpacing.medium) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(record.subtitle)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer()
                    Button {
                        onOpen(record.id)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.accent)
                    .accessibilityLabel(
                        "Open \(record.displayName)"
                    )
                    Menu {
                        Button {
                            Task {
                                _ = await model.duplicate(
                                    recordID: record.id
                                )
                                await refresh()
                            }
                        } label: {
                            Label(
                                "Duplicate Working Copy",
                                systemImage: "plus.square.on.square"
                            )
                        }
                        Button(role: .destructive) {
                            Task {
                                await model.delete(recordID: record.id)
                                await refresh()
                            }
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
                }
                .padding(.vertical, PPSpacing.small)

                if index < largestRecords.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.56))
                        .frame(height: 0.6)
                        .padding(.leading, 34)
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
                .offset(y: 23)
        }
    }

    private var largestRecords: [DocumentRecord] {
        Array(
            model.documents
                .sorted {
                    $0.profile.byteCount > $1.profile.byteCount
                }
                .prefix(8)
        )
    }

    private var pdfShare: Double {
        guard let snapshot, snapshot.totalBytes > 0 else { return 0 }
        return min(
            1,
            max(
                0.04,
                Double(snapshot.pdfBytes)
                    / Double(snapshot.totalBytes)
            )
        )
    }

    private func storageFraction(_ bytes: Int64) -> Double {
        guard let snapshot, snapshot.totalBytes > 0 else { return 0 }
        return min(
            1,
            max(0.015, Double(bytes) / Double(snapshot.totalBytes))
        )
    }

    private func storagePercent(_ bytes: Int64) -> String {
        guard let snapshot, snapshot.totalBytes > 0 else {
            return "0%"
        }
        return AppLocalization.format(
            "%.1f%%",
            Double(bytes) / Double(snapshot.totalBytes) * 100
        )
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    private func refresh() async {
        isRefreshing = true
        async let snapshotTask = model.localStorageSnapshot()
        async let pinnedTask = model.pinnedVersionMilestones()
        let (loadedSnapshot, loadedPinnedMilestones) = await (
            snapshotTask,
            pinnedTask
        )
        snapshot = loadedSnapshot
        pinnedVersionMilestones = loadedPinnedMilestones
        isRefreshing = false
    }
}

private struct VersionArchiveVerificationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var report: PDFVersionArchiveVerificationReport
    @State private var isTrusting = false
    @State private var trustFeedback = 0

    let onTrust: (
        PDFVersionArchiveVerificationReport
    ) async -> PDFVersionArchiveVerificationReport?

    init(
        report: PDFVersionArchiveVerificationReport,
        onTrust: @escaping (
            PDFVersionArchiveVerificationReport
        ) async -> PDFVersionArchiveVerificationReport?
    ) {
        _report = State(initialValue: report)
        self.onTrust = onTrust
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xLarge
                ) {
                    WorkflowCommandHeader(
                        eyebrow: "VERSION ARCHIVE",
                        title: verificationTitle,
                        detail: report.archiveName,
                        symbol: report.status == .failed
                            ? report.status.symbol
                            : provenanceSymbol,
                        tint: statusColor,
                        metrics: [
                            WorkflowMetric(
                                value:
                                    "\(report.verifiedCount)/\(report.manifestEntryCount)",
                                label: "Verified",
                                symbol: "checkmark.seal.fill",
                                tint: PPColor.mint
                            ),
                            WorkflowMetric(
                                value: "\(report.failedCount)",
                                label: "Failed",
                                symbol: "xmark.octagon.fill",
                                tint: report.failedCount == 0
                                    ? PPColor.textSecondary
                                    : PPColor.rose
                            ),
                            WorkflowMetric(
                                value: report.formattedSize,
                                label: "Archive",
                                symbol: "archivebox",
                                tint: PPColor.cyan
                            )
                        ]
                    )

                    archiveFacts
                    provenanceSection

                    if !report.structuralFailures.isEmpty {
                        structuralFailures
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        StudioSectionRule(
                            title: "MILESTONE EVIDENCE",
                            detail: "Manifest identity · stored bytes",
                            symbol: "list.bullet.rectangle",
                            count: report.items.count,
                            tint: statusColor
                        )
                        ForEach(
                            Array(report.items.enumerated()),
                            id: \.element.id
                        ) { index, item in
                            archiveItem(item)
                            if index < report.items.count - 1 {
                                Rectangle()
                                    .fill(PPColor.border.opacity(0.56))
                                    .frame(height: 0.6)
                                    .padding(.leading, 38)
                            }
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Archive Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(.success, trigger: trustFeedback)
        }
    }

    private var archiveFacts: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "ARCHIVE CONTRACT",
                detail: "Read-only local verification",
                symbol: "lock.shield",
                tint: PPColor.cyan
            )
            LabeledContent(
                "Schema",
                value: report.schema
            )
            LabeledContent(
                "Created",
                value: report.archiveCreatedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            LabeledContent(
                "Verified at",
                value: report.verifiedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            LabeledContent(
                "ZIP entries",
                value:
                    "\(report.archiveEntryCount + 1)"
            )
            Label(
                report.hasValidSourceSignature
                    ? "Manifest identity and PDF bytes are verified independently."
                    : "Verifies archive consistency, not signer identity.",
                systemImage: "info.circle"
            )
            .foregroundStyle(PPColor.textSecondary)
        }
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .monospacedDigit()
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "SOURCE PROVENANCE",
                detail: "Ed25519 manifest signature · local trust",
                symbol: provenanceSymbol,
                tint: provenanceTint
            )

            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(systemName: provenanceSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(provenanceTint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.provenanceTitle.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(report.signatureDetail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    if let keyID = report.signerKeyID {
                        Text("KEY \(keyID.uppercased())")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(provenanceTint)
                    }
                }
                Spacer(minLength: 0)
                if report.canTrustSigner {
                    Button {
                        trustSigner()
                    } label: {
                        Label(
                            isTrusting
                                ? "Trusting"
                                : "Trust Signer",
                            systemImage:
                                "person.crop.circle.badge.checkmark"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.mint)
                    )
                    .disabled(isTrusting)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    private func trustSigner() {
        guard report.canTrustSigner else { return }
        isTrusting = true
        Task {
            let updated = await onTrust(report)
            isTrusting = false
            guard let updated else { return }
            report = updated
            trustFeedback += 1
        }
    }

    private var verificationTitle: String {
        if report.status == .failed {
            return "Archive integrity failed"
        }
        if report.hasInvalidSourceSignature {
            return "Archive signature invalid"
        }
        if report.isLegacyUnsigned {
            return "Unsigned archive verified"
        }
        return "Signed archive verified"
    }

    private var provenanceTint: Color {
        switch report.trustStatus {
        case .thisDevice, .trusted:
            return PPColor.mint
        case .unknown:
            return PPColor.amber
        case .unsupported:
            return PPColor.cyan
        case .invalid:
            return PPColor.rose
        }
    }

    private var provenanceSymbol: String {
        if report.hasInvalidSourceSignature {
            return "xmark.seal.fill"
        }
        if report.isLegacyUnsigned {
            return "questionmark.diamond.fill"
        }
        return report.trustStatus.symbol
    }

    private var structuralFailures: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "STRUCTURE FAILURES",
                detail: "Unexpected archive contents",
                symbol: "exclamationmark.octagon.fill",
                count: report.structuralFailures.count,
                tint: PPColor.rose
            )
            ForEach(
                Array(report.structuralFailures.enumerated()),
                id: \.offset
            ) { _, failure in
                Label(
                    failure.localizedUI,
                    systemImage: "xmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.rose)
            }
        }
    }

    private func archiveItem(
        _ item: PDFVersionArchiveVerificationItem
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            Image(systemName: item.status.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    item.status == .verified
                        ? PPColor.mint
                        : PPColor.rose
                )
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: PPSpacing.small) {
                    Text(item.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(item.status.title.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(
                            item.status == .verified
                                ? PPColor.mint
                                : PPColor.rose
                        )
                }
                Text(item.fileName)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                HStack(spacing: PPSpacing.medium) {
                    Text(
                        "\(item.pageCount) pages · \(item.formattedSize)"
                    )
                    Text(
                        String(item.expectedSHA256.prefix(12))
                            .uppercased()
                    )
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                Text(item.detail.localizedUI)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        item.status == .verified
                            ? PPColor.textSecondary
                            : PPColor.rose
                    )
            }
        }
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        report.status == .failed
            ? PPColor.rose
            : provenanceTint
    }
}

private struct DeliveryPackageVerificationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var report: PDFDeliveryPackageVerificationReport
    @State private var isTrusting = false
    @State private var isConfirmingTrust = false
    @State private var trustFeedback = 0

    let onTrust: (
        PDFDeliveryPackageVerificationReport
    ) async -> PDFDeliveryPackageVerificationReport?

    init(
        report: PDFDeliveryPackageVerificationReport,
        onTrust: @escaping (
            PDFDeliveryPackageVerificationReport
        ) async -> PDFDeliveryPackageVerificationReport?
    ) {
        _report = State(initialValue: report)
        self.onTrust = onTrust
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xLarge
                ) {
                    WorkflowCommandHeader(
                        eyebrow: "DELIVERY PACKAGE",
                        title: verificationTitle,
                        detail: report.archiveName,
                        symbol: statusSymbol,
                        tint: statusColor,
                        metrics: [
                            WorkflowMetric(
                                value: "\(report.artifactPageCount)",
                                label: "Pages",
                                symbol: "doc.text",
                                tint: PPColor.cyan
                            ),
                            WorkflowMetric(
                                value: "\(report.warningCount)",
                                label: "Warnings",
                                symbol: "exclamationmark.triangle",
                                tint: report.warningCount == 0
                                    ? PPColor.textSecondary
                                    : PPColor.amber
                            ),
                            WorkflowMetric(
                                value: report.formattedArtifactSize,
                                label: "PDF",
                                symbol: "doc.fill",
                                tint: PPColor.mint
                            )
                        ]
                    )

                    integritySection
                    provenanceSection
                    packageFacts
                    deliveryChecks
                    scopeNotice
                }
                .frame(maxWidth: 760)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPCanvas())
            .navigationTitle("Delivery Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Trust this signing key?",
                isPresented: $isConfirmingTrust,
                titleVisibility: .visible
            ) {
                Button("Trust Signer") {
                    trustSigner()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Compare the Key ID with the sender through a separate channel before trusting it."
                )
            }
            .sensoryFeedback(.success, trigger: trustFeedback)
        }
    }

    private var integritySection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "PACKAGE INTEGRITY",
                detail: "ZIP directory · CRC · bytes · SHA-256",
                symbol: report.integrityStatus.symbol,
                count: report.integrityFailures.isEmpty
                    ? nil
                    : report.integrityFailures.count,
                tint: report.integrityStatus == .verified
                    ? PPColor.mint
                    : PPColor.rose
            )

            if report.integrityFailures.isEmpty {
                verificationRow(
                    "ZIP structure and entry CRCs match",
                    symbol: "archivebox.fill",
                    tint: PPColor.mint
                )
                verificationRow(
                    "PDF bytes match the signed SHA-256",
                    symbol: "number.square.fill",
                    tint: PPColor.mint
                )
                verificationRow(
                    "PDF header and Receipt contract match",
                    symbol: "doc.badge.checkmark",
                    tint: PPColor.mint
                )
            } else {
                ForEach(
                    Array(report.integrityFailures.enumerated()),
                    id: \.offset
                ) { _, failure in
                    verificationRow(
                        failure,
                        symbol: "xmark.octagon.fill",
                        tint: PPColor.rose
                    )
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "SOURCE PROVENANCE",
                detail: "Ed25519 Receipt signature · local trust",
                symbol: provenanceSymbol,
                tint: provenanceTint
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PPSpacing.medium) {
                    provenanceIdentity
                    Spacer(minLength: PPSpacing.small)
                    trustButton
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    provenanceIdentity
                    trustButton
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    private var provenanceIdentity: some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            Image(systemName: provenanceSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(provenanceTint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.provenanceTitle.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                Text(report.signatureDetail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                if let keyID = report.signerKeyID {
                    Text("KEY \(keyID.uppercased())")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(provenanceTint)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var trustButton: some View {
        if report.canTrustSigner {
            Button {
                isConfirmingTrust = true
            } label: {
                Label(
                    isTrusting ? "Trusting" : "Trust Signer",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
            .disabled(isTrusting)
            .accessibilityIdentifier("trustDeliveryPackageSigner")
        }
    }

    private var packageFacts: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "SIGNED RECEIPT",
                detail: "Identity · operation · exact artifact",
                symbol: "doc.text.magnifyingglass",
                tint: PPColor.cyan
            )
            LabeledContent("PDF", value: report.artifactFileName)
            LabeledContent(
                "Operation",
                value: report.operation.title.localizedUI
            )
            LabeledContent(
                "Created",
                value: report.packageCreatedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            LabeledContent(
                "Verified at",
                value: report.verifiedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            LabeledContent(
                "Package ID",
                value: String(
                    report.packageID.uuidString.prefix(12)
                )
            )
            LabeledContent(
                "Receipt ID",
                value: String(
                    report.deliveryReceiptID.uuidString.prefix(12)
                )
            )
            fingerprintEvidence(
                "Expected SHA-256",
                value: report.expectedSHA256
            )
            if let actualSHA256 = report.actualSHA256,
               actualSHA256.caseInsensitiveCompare(
                    report.expectedSHA256
               ) != .orderedSame {
                fingerprintEvidence(
                    "Observed SHA-256",
                    value: actualSHA256
                )
            }
            LabeledContent(
                "Archive",
                value: report.formattedArchiveSize
            )
        }
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .monospacedDigit()
        .textSelection(.enabled)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func fingerprintEvidence(
        _ title: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.localizedUI)
                .foregroundStyle(PPColor.textSecondary)
            Text(value.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var deliveryChecks: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: "DELIVERY CHECKS",
                detail: "Signed claims from the producing device",
                symbol: "checklist",
                count: report.checks.count,
                tint: report.warningCount == 0
                    ? PPColor.mint
                    : PPColor.amber
            )
            ForEach(
                Array(report.checks.enumerated()),
                id: \.element.id
            ) { index, check in
                HStack(alignment: .top, spacing: PPSpacing.medium) {
                    Image(systemName: checkSymbol(check.status))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(checkTint(check.status))
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title.localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                        Text(check.detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, PPSpacing.small)
                .accessibilityElement(children: .combine)

                if index < report.checks.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.56))
                        .frame(height: 0.6)
                        .padding(.leading, 38)
                }
            }
        }
    }

    private var scopeNotice: some View {
        Label(
            "This verifies package integrity and local signer trust, not a certificate-backed legal identity.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .accessibilityElement(children: .combine)
    }

    private func verificationRow(
        _ title: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Label(title.localizedUI, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func trustSigner() {
        guard report.canTrustSigner else { return }
        isTrusting = true
        Task {
            let updated = await onTrust(report)
            isTrusting = false
            guard let updated else { return }
            report = updated
            trustFeedback += 1
        }
    }

    private var verificationTitle: String {
        if report.integrityStatus == .failed {
            return "PDF does not match Receipt"
        }
        if report.hasInvalidSourceSignature {
            return "Receipt signature invalid"
        }
        switch report.trustStatus {
        case .thisDevice:
            return "Verified on this device"
        case .trusted:
            return "Verified trusted package"
        case .unknown:
            return "Package contents verified"
        case .invalid:
            return "Package verification failed"
        case .unsupported:
            return "Unsupported package"
        }
    }

    private var statusColor: Color {
        report.status == .failed ? PPColor.rose : provenanceTint
    }

    private var statusSymbol: String {
        report.status == .failed
            ? "xmark.shield.fill"
            : provenanceSymbol
    }

    private var provenanceTint: Color {
        switch report.trustStatus {
        case .thisDevice, .trusted:
            return PPColor.mint
        case .unknown:
            return PPColor.amber
        case .unsupported:
            return PPColor.cyan
        case .invalid:
            return PPColor.rose
        }
    }

    private var provenanceSymbol: String {
        report.hasInvalidSourceSignature
            ? "xmark.seal.fill"
            : report.trustStatus.symbol
    }

    private func checkTint(
        _ status: PDFDeliveryCheckStatus
    ) -> Color {
        switch status {
        case .passed: return PPColor.mint
        case .warning: return PPColor.amber
        case .failed: return PPColor.rose
        case .notApplicable: return PPColor.textSecondary
        }
    }

    private func checkSymbol(
        _ status: PDFDeliveryCheckStatus
    ) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .notApplicable: return "minus.circle"
        }
    }
}

private struct DuplicateReviewView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    @State private var pendingTrashRecord: DocumentRecord?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if duplicateGroups.isEmpty {
                    PPEmptyState(
                        kind: .workspace,
                        title: "No exact duplicates",
                        message: "Every active private copy has unique PDF bytes."
                    )
                    .padding(PPSpacing.regular)
                } else {
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: PPSpacing.xLarge
                        ) {
                            summary
                            ForEach(duplicateGroups) { group in
                                duplicateGroup(group)
                            }
                        }
                        .frame(maxWidth: 680)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Exact Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Move this duplicate to Trash?",
            isPresented: Binding(
                get: { pendingTrashRecord != nil },
                set: {
                    if !$0 {
                        pendingTrashRecord = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let record = pendingTrashRecord else { return }
                pendingTrashRecord = nil
                Task {
                    await model.delete(recordID: record.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Another byte-for-byte identical copy remains in the library."
            )
        }
    }

    private var summary: some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: "doc.on.doc.fill",
                tint: PPColor.amber,
                size: 46
            )
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "SHA-256 MATCH")
                Text(
                    "\(duplicateGroups.count) group\(duplicateGroups.count == 1 ? "" : "s") · \(removableCount) extra cop\(removableCount == 1 ? "y" : "ies")"
                )
                .font(.title3.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
            }
            Spacer()
            Text(recoverableSize)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textSecondary)
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private func duplicateGroup(
        _ group: DuplicateGroup
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionEyebrow(
                    text: "\(group.records.first?.profile.pageCount ?? 0) PAGES · \(group.records.first?.profile.formattedSize ?? "")"
                )
                Spacer()
                Text("\(group.records.count) copies")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.bottom, PPSpacing.small)

            ForEach(
                Array(group.records.enumerated()),
                id: \.element.id
            ) { index, record in
                HStack(spacing: PPSpacing.medium) {
                    ToolSymbolPlate(
                        symbol: index == 0
                            ? "checkmark.doc"
                            : "doc",
                        tint: index == 0
                            ? PPColor.mint
                            : PPColor.textSecondary,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName)
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(1)
                        Text(
                            record.importedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: PPSpacing.small)
                    if index == 0 {
                        Text("KEEP")
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(PPColor.mint)
                            .padding(.horizontal, PPSpacing.small)
                            .frame(minHeight: 28)
                            .background(PPColor.mint.opacity(0.08))
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 6,
                                    style: .continuous
                                )
                            )
                    } else {
                        Button(role: .destructive) {
                            pendingTrashRecord = record
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel(
                            "Move \(record.displayName) to Trash"
                        )
                    }
                }
                .padding(.vertical, PPSpacing.small)

                if index < group.records.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.55))
                        .frame(height: 0.6)
                        .padding(.leading, 54)
                }
            }
        }
        .padding(.horizontal, PPSpacing.medium)
        .padding(.vertical, PPSpacing.small)
        .ppPaper(cornerRadius: 8, shadow: false)
    }

    private var duplicateGroups: [DuplicateGroup] {
        Dictionary(
            grouping: model.documents.filter {
                $0.contentFingerprint?.isEmpty == false
            },
            by: { $0.contentFingerprint ?? "" }
        )
        .compactMap { fingerprint, records in
            guard records.count > 1 else { return nil }
            return DuplicateGroup(
                fingerprint: fingerprint,
                records: records.sorted {
                    if $0.importedAt != $1.importedAt {
                        return $0.importedAt < $1.importedAt
                    }
                    return $0.displayName.localizedStandardCompare(
                        $1.displayName
                    ) == .orderedAscending
                }
            )
        }
        .sorted {
            ($0.records.first?.displayName ?? "")
                .localizedStandardCompare(
                    $1.records.first?.displayName ?? ""
                ) == .orderedAscending
        }
    }

    private var removableCount: Int {
        duplicateGroups.reduce(0) {
            $0 + max(0, $1.records.count - 1)
        }
    }

    private var recoverableSize: String {
        let bytes = duplicateGroups.reduce(Int64(0)) { result, group in
            result
                + Int64(max(0, group.records.count - 1))
                * (group.records.first?.profile.byteCount ?? 0)
        }
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    private struct DuplicateGroup: Identifiable {
        let fingerprint: String
        let records: [DocumentRecord]

        var id: String { fingerprint }
    }
}

private struct TrashCenterView: View {
    private enum TrashSort:
        String,
        CaseIterable,
        Identifiable {
        case expiry
        case removed
        case size

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("privacy.trashRetentionDays")
    private var trashRetentionDays = 30

    @State private var pendingPermanentDelete: DocumentRecord?
    @State private var isConfirmingEmptyTrash = false
    @State private var trashSort = TrashSort.expiry

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if model.deletedDocuments.isEmpty {
                    PPEmptyState(
                        kind: .workspace,
                        title: "Trash is empty",
                        message: "Removed private copies stay recoverable here."
                    )
                    .padding(PPSpacing.regular)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            trashSummary
                            trashLedgerHeader
                            ForEach(sortedDeletedDocuments) { record in
                                trashRow(record)
                                if record.id
                                    != sortedDeletedDocuments.last?.id {
                                    Rectangle()
                                        .fill(
                                            PPColor.border.opacity(0.58)
                                        )
                                        .frame(height: 0.6)
                                        .padding(.leading, 58)
                                }
                            }
                        }
                        .frame(maxWidth: 860)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !model.deletedDocuments.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                Task {
                                    await model.restoreAllFromTrash()
                                }
                            } label: {
                                Label(
                                    "Restore All",
                                    systemImage:
                                        "arrow.uturn.backward.circle"
                                )
                            }
                            Button(role: .destructive) {
                                isConfirmingEmptyTrash = true
                            } label: {
                                Label(
                                    "Empty Trash",
                                    systemImage: "trash.slash"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Trash actions")
                    }
                }
            }
        }
        .onChange(of: trashRetentionDays) {
            Task {
                await model.applyTrashRetention()
            }
        }
        .confirmationDialog(
            "Delete this private copy permanently?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: {
                    if !$0 {
                        pendingPermanentDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                guard let record = pendingPermanentDelete else {
                    return
                }
                pendingPermanentDelete = nil
                Task {
                    await model.permanentlyDelete(
                        recordID: record.id
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The PDF and its local text index cannot be recovered.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $isConfirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("Delete All Permanently", role: .destructive) {
                Task {
                    await model.emptyTrash()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(model.deletedDocuments.count) private copies and their local indexes will be deleted."
            )
        }
    }

    private var trashSummary: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            StudioSectionRule(
                title: "RETENTION LEDGER",
                detail: "Original Files documents remain unchanged",
                symbol: "clock.badge.checkmark",
                count: model.deletedDocuments.count,
                tint: PPColor.amber
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 126, maximum: 210),
                        spacing: PPSpacing.medium
                    )
                ],
                spacing: PPSpacing.small
            ) {
                trashMetric(
                    value: "\(model.deletedDocuments.count)",
                    label: "Recoverable",
                    symbol: "trash",
                    tint: PPColor.accent
                )
                trashMetric(
                    value: formattedTrashSize,
                    label: "Capacity",
                    symbol: "internaldrive",
                    tint: PPColor.cyan
                )
                trashMetric(
                    value: "\(expiringSoonCount)",
                    label: "Due in 7 days",
                    symbol: "clock.badge.exclamationmark",
                    tint: expiringSoonCount > 0
                        ? PPColor.rose
                        : PPColor.mint
                )
                trashMetric(
                    value: retentionMetric,
                    label: "Auto-delete",
                    symbol: "calendar.badge.clock",
                    tint: PPColor.amber
                )
            }

            HStack(spacing: PPSpacing.medium) {
                Picker(
                    "Trash retention",
                    selection: $trashRetentionDays
                ) {
                    ForEach(TrashRetentionPolicy.allCases) { policy in
                        Text(policy.title.localizedUI)
                            .tag(policy.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(PPColor.accent)
                Picker("Trash sort", selection: $trashSort) {
                    ForEach(TrashSort.allCases) { sort in
                        Text(sort.title.localizedUI)
                            .tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer(minLength: 0)
                Button {
                    Task {
                        await model.restoreAllFromTrash()
                    }
                } label: {
                    Label(
                        "Restore All",
                        systemImage: "arrow.uturn.backward"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
            }
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
    }

    private var trashLedgerHeader: some View {
        HStack(spacing: PPSpacing.small) {
            Text("ITEM")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("SIZE")
                .frame(width: 72, alignment: .trailing)
            Text("REMOVED")
                .frame(width: 90, alignment: .leading)
            Text("EXPIRES")
                .frame(width: 96, alignment: .leading)
            Color.clear
                .frame(width: 82)
        }
        .font(.caption2.smallCaps().weight(.bold))
        .foregroundStyle(PPColor.textSecondary)
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 30)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
    }

    private func trashMetric(
        value: String,
        label: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.localizedUI)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label.localizedUI.uppercased())
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.42))
                .frame(height: 0.8)
        }
    }

    private func trashRow(
        _ record: DocumentRecord
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                trashIdentity(record)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: record.profile.byteCount,
                        countStyle: .file
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textPrimary)
                .frame(width: 72, alignment: .trailing)
                Text(
                    record.deletedAt?.formatted(
                        date: .abbreviated,
                        time: .omitted
                    ) ?? "—"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                .frame(width: 90, alignment: .leading)
                Text(
                    record.deletedAt.map(expiryText) ?? "—"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(
                    expiryTint(record.deletedAt)
                )
                .frame(width: 96, alignment: .leading)
                trashActions(record)
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                trashIdentity(record)
                HStack(spacing: PPSpacing.medium) {
                    Text(record.subtitle)
                    if let deletedAt = record.deletedAt {
                        Text(
                            deletedAt.formatted(
                                date: .abbreviated,
                                time: .omitted
                            )
                        )
                        Text(expiryText(deletedAt))
                            .foregroundStyle(expiryTint(deletedAt))
                    }
                    Spacer(minLength: 0)
                    trashActions(record)
                }
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .contain)
    }

    private func trashIdentity(
        _ record: DocumentRecord
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            ToolSymbolPlate(
                symbol: record.profile.kind.symbol,
                tint: PPColor.textSecondary,
                size: 36
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(
                    (
                        record.isDeliveryArtifact
                            ? "Delivery output · source copy unaffected"
                            : "Working copy · Files original unaffected"
                    ).localizedUI
                )
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
            }
        }
    }

    private func trashActions(
        _ record: DocumentRecord
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                Task {
                    await model.restoreFromTrash(
                        recordID: record.id
                    )
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .accessibilityLabel("Restore \(record.displayName)")
            Menu {
                Button {
                    Task {
                        await model.restoreFromTrash(
                            recordID: record.id
                        )
                    }
                } label: {
                    Label(
                        "Restore",
                        systemImage: "arrow.uturn.backward"
                    )
                }
                Button(role: .destructive) {
                    pendingPermanentDelete = record
                } label: {
                    Label(
                        "Delete Permanently",
                        systemImage: "trash.slash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityLabel(
                "More actions for \(record.displayName)"
            )
        }
        .frame(width: 82)
    }

    private var formattedTrashSize: String {
        ByteCountFormatter.string(
            fromByteCount: model.deletedDocuments.reduce(0) {
                $0 + $1.profile.byteCount
            },
            countStyle: .file
        )
    }

    private var sortedDeletedDocuments: [DocumentRecord] {
        switch trashSort {
        case .expiry:
            return model.deletedDocuments.sorted {
                let left = $0.deletedAt.map(remainingDays) ?? .max
                let right = $1.deletedAt.map(remainingDays) ?? .max
                if left != right {
                    return left < right
                }
                return ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
        case .removed:
            return model.deletedDocuments.sorted {
                ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
        case .size:
            return model.deletedDocuments.sorted {
                if $0.profile.byteCount
                    != $1.profile.byteCount {
                    return $0.profile.byteCount
                        > $1.profile.byteCount
                }
                return $0.displayName
                    .localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
        }
    }

    private func expiryText(_ deletedAt: Date) -> String {
        guard trashRetentionDays > 0 else {
            return "Kept until deleted"
        }
        let expiry = Calendar.current.date(
            byAdding: .day,
            value: trashRetentionDays,
            to: deletedAt
        ) ?? deletedAt
        let remaining = max(
            0,
            Calendar.current.dateComponents(
                [.day],
                from: Date(),
                to: expiry
            ).day ?? 0
        )
        if remaining == 0 {
            return "Deletes today"
        }
        return "\(remaining)d remaining"
    }

    private var expiringSoonCount: Int {
        guard trashRetentionDays > 0 else { return 0 }
        return model.deletedDocuments.filter {
            guard let deletedAt = $0.deletedAt else { return false }
            return remainingDays(deletedAt) <= 7
        }.count
    }

    private var retentionMetric: String {
        guard trashRetentionDays > 0 else { return "Manual" }
        return "\(trashRetentionDays)d"
    }

    private func remainingDays(_ deletedAt: Date) -> Int {
        guard trashRetentionDays > 0 else { return .max }
        let expiry = Calendar.current.date(
            byAdding: .day,
            value: trashRetentionDays,
            to: deletedAt
        ) ?? deletedAt
        return max(
            0,
            Calendar.current.dateComponents(
                [.day],
                from: Date(),
                to: expiry
            ).day ?? 0
        )
    }

    private func expiryTint(_ deletedAt: Date?) -> Color {
        guard let deletedAt, trashRetentionDays > 0 else {
            return PPColor.textSecondary
        }
        let days = remainingDays(deletedAt)
        if days <= 1 {
            return PPColor.rose
        }
        if days <= 7 {
            return PPColor.amber
        }
        return PPColor.mint
    }
}

struct DocumentPrivateNoteView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID

    @State private var note = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                VStack(alignment: .leading, spacing: PPSpacing.large) {
                    HStack(spacing: PPSpacing.medium) {
                        ToolSymbolPlate(
                            symbol: "note.text",
                            tint: PPColor.amber,
                            size: 44
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            SectionEyebrow(text: "DEVICE ONLY")
                            Text(record?.displayName ?? "Document")
                                .font(.title3.bold())
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $note)
                            .focused($isFocused)
                            .font(.body)
                            .foregroundStyle(PPColor.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(PPSpacing.small)

                        if note.isEmpty {
                            Text(
                                "Follow-up, context, or delivery notes"
                            )
                            .font(.body)
                            .foregroundStyle(PPColor.textSecondary)
                            .padding(PPSpacing.medium)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 180)
                    .background(PPColor.surface)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                        .stroke(
                            PPColor.border.opacity(0.68),
                            lineWidth: 0.7
                        )
                    }

                    HStack {
                        Label(
                            "Not embedded in the PDF",
                            systemImage: "iphone"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                        Spacer()
                        Text("\(note.count) / 1,000")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(
                                note.count >= 950
                                    ? PPColor.amber
                                    : PPColor.textSecondary
                            )
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Private Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = note
                        Task {
                            await model.updatePrivateNote(
                                recordID: recordID,
                                note: value
                            )
                            dismiss()
                        }
                    }
                    .disabled(!hasChanges)
                }
                if record?.privateNote != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) {
                            Task {
                                await model.updatePrivateNote(
                                    recordID: recordID,
                                    note: nil
                                )
                                dismiss()
                            }
                        } label: {
                            Label(
                                "Remove Note",
                                systemImage: "note.text.badge.minus"
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            note = record?.privateNote ?? ""
            isFocused = note.isEmpty
        }
        .onChange(of: note) { _, value in
            if value.count > 1_000 {
                note = String(value.prefix(1_000))
            }
        }
    }

    private var record: DocumentRecord? {
        model.record(id: recordID)
    }

    private var normalizedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        let existing = record?.privateNote ?? ""
        return normalizedNote
            != existing.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }
}

private struct DocumentScheduleView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID

    @State private var selectedDate = Date()
    @State private var hasDueDate = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                HStack(spacing: PPSpacing.medium) {
                    ToolSymbolPlate(
                        symbol: "calendar.badge.clock",
                        tint: PPColor.cyan,
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        SectionEyebrow(text: "LOCAL SCHEDULE")
                        Text(record?.displayName ?? "Document")
                            .font(.title3.bold())
                            .fontDesign(.serif)
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(2)
                    }
                    Spacer()
                }

                HStack(spacing: PPSpacing.small) {
                    quickDateButton(
                        "Today",
                        date: Date()
                    )
                    quickDateButton(
                        "Tomorrow",
                        date: Calendar.current.date(
                            byAdding: .day,
                            value: 1,
                            to: Date()
                        ) ?? Date()
                    )
                    quickDateButton(
                        "Next Week",
                        date: Calendar.current.date(
                            byAdding: .day,
                            value: 7,
                            to: Date()
                        ) ?? Date()
                    )
                }

                DatePicker(
                    "Due date",
                    selection: $selectedDate,
                    in: Calendar.current.startOfDay(for: Date())...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(PPColor.accent)
                .onChange(of: selectedDate) {
                    hasDueDate = true
                }

                if hasDueDate {
                    Label(
                        scheduleSummary,
                        systemImage: "bell.badge"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                }
            }
            .padding(PPSpacing.regular)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PPCanvas())
            .navigationTitle("Due Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.updateDueDate(
                                recordID: recordID,
                                dueAt: hasDueDate
                                    ? selectedDate
                                    : nil
                            )
                            dismiss()
                        }
                    }
                }
                if record?.dueAt != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button(role: .destructive) {
                            Task {
                                await model.updateDueDate(
                                    recordID: recordID,
                                    dueAt: nil
                                )
                                dismiss()
                            }
                        } label: {
                            Label(
                                "Remove Due Date",
                                systemImage: "calendar.badge.minus"
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            if let dueAt = record?.dueAt {
                selectedDate = dueAt
                hasDueDate = true
            }
        }
    }

    private var record: DocumentRecord? {
        model.record(id: recordID)
    }

    private var scheduleSummary: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return "Due today"
        }
        if Calendar.current.isDateInTomorrow(selectedDate) {
            return "Due tomorrow"
        }
        return "Due \(selectedDate.formatted(date: .long, time: .omitted))"
    }

    private func quickDateButton(
        _ title: String,
        date: Date
    ) -> some View {
        Button {
            selectedDate = Calendar.current.startOfDay(for: date)
            hasDueDate = true
        } label: {
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 38)
        }
        .buttonStyle(.bordered)
        .tint(PPColor.accent)
    }
}

private struct DocumentTagEditorView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID

    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        documentHeader
                        addTagControl
                        currentTags
                        if !suggestedTags.isEmpty {
                            suggestedTagsSection
                        }
                    }
                    .frame(maxWidth: 620)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Document Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = tags
                        Task {
                            await model.updateTags(
                                recordID: recordID,
                                tags: updated
                            )
                            dismiss()
                        }
                    }
                    .disabled(!hasChanges)
                }
            }
        }
        .task {
            guard !didLoad else { return }
            tags = model.record(id: recordID)?.tags ?? []
            didLoad = true
        }
    }

    private var documentHeader: some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: "tag",
                tint: PPColor.accent,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "LOCAL ORGANIZATION")
                Text(
                    model.record(id: recordID)?.displayName
                        ?? "Document"
                )
                .font(.title3.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var addTagControl: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "ADD TAG")
            HStack(spacing: PPSpacing.small) {
                TextField("Client, project, topic", text: $newTag)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(addTag)
                    .onChange(of: newTag) { _, value in
                        if value.count > 24 {
                            newTag = String(value.prefix(24))
                        }
                    }

                Button(action: addTag) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddTag)
                .accessibilityLabel("Add tag")
            }
            .padding(.horizontal, PPSpacing.medium)
            .frame(minHeight: 50)
            .background(PPColor.surface)
            .clipShape(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        PPColor.border.opacity(0.62),
                        lineWidth: 0.6
                    )
            }
        }
    }

    private var currentTags: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack {
                SectionEyebrow(text: "CURRENT")
                Spacer()
                Text("\(tags.count) / 8")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
            }

            if tags.isEmpty {
                Label("No tags", systemImage: "tag.slash")
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, PPSpacing.medium)
            } else {
                tagGrid(tags, removable: true)
            }
        }
    }

    private var suggestedTagsSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "FROM YOUR LIBRARY")
            tagGrid(suggestedTags, removable: false)
        }
    }

    private func tagGrid(
        _ values: [String],
        removable: Bool
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 104, maximum: 180),
                    spacing: PPSpacing.small
                )
            ],
            alignment: .leading,
            spacing: PPSpacing.small
        ) {
            ForEach(values, id: \.self) { tag in
                Button {
                    if removable {
                        tags.removeAll {
                            $0.caseInsensitiveCompare(tag) == .orderedSame
                        }
                    } else {
                        appendTag(tag)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(
                            systemName: removable
                                ? "xmark"
                                : "plus"
                        )
                        .font(.caption2.weight(.bold))
                        Text(tag)
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        removable
                            ? PPColor.textPrimary
                            : PPColor.accent
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
                    .padding(.horizontal, PPSpacing.small)
                    .background(
                        (
                            removable
                                ? PPColor.surfaceMuted
                                : PPColor.accent.opacity(0.08)
                        )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 7,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    removable
                        ? "Remove \(tag)"
                        : "Add \(tag)"
                )
            }
        }
    }

    private var normalizedNewTag: String {
        String(
            newTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(24)
        )
    }

    private var canAddTag: Bool {
        !normalizedNewTag.isEmpty
            && tags.count < 8
            && !tags.contains {
                $0.caseInsensitiveCompare(normalizedNewTag)
                    == .orderedSame
            }
    }

    private var suggestedTags: [String] {
        var seen: Set<String> = []
        return model.documents
            .flatMap(\.tags)
            .filter { value in
                let key = value.lowercased()
                return !tags.contains {
                    $0.caseInsensitiveCompare(value) == .orderedSame
                } && seen.insert(key).inserted
            }
            .sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
    }

    private var hasChanges: Bool {
        guard didLoad else { return false }
        return tags != (model.record(id: recordID)?.tags ?? [])
    }

    private func addTag() {
        guard canAddTag else { return }
        appendTag(normalizedNewTag)
        newTag = ""
    }

    private func appendTag(_ value: String) {
        guard tags.count < 8,
              !tags.contains(where: {
                  $0.caseInsensitiveCompare(value) == .orderedSame
              })
        else { return }
        tags.append(value)
    }
}

struct PrivacyCenterView: View {
    private enum BoundaryFocus:
        String,
        CaseIterable,
        Identifiable {
        case all
        case local
        case sync
        case outbound

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var appLock: AppLockController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("privacy.hideLibraryPreviews")
    private var hideLibraryPreviews = false
    @AppStorage(AppPreferences.metadataSyncEnabledKey)
    private var metadataSyncEnabled = false
    @State private var boundaryFocus = BoundaryFocus.all

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        privacyHero
                        localMetrics
                        processingLedger
                        accessBoundary
                        previewBoundary
                        metadataBoundary
                    }
                    .frame(maxWidth: 860)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, PPSpacing.section)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Privacy Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var privacyHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PPSpacing.medium) {
                    PPIllustration(kind: .privacy, width: 132)
                        .frame(maxWidth: .infinity)
                    privacyHeroCopy
                }
            } else {
                HStack(spacing: PPSpacing.large) {
                    PPIllustration(kind: .privacy, width: 132)
                    privacyHeroCopy
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var privacyHeroCopy: some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            SectionEyebrow(text: "STORAGE BOUNDARIES")
            Text("Local document desk")
                .font(.title2.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
            Text("Inspect what is stored on this device and what can sync.")
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localMetrics: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 132, maximum: 210),
                    spacing: PPSpacing.large
                )
            ],
            spacing: PPSpacing.medium
        ) {
            privacyMetric(
                value: "\(model.documents.count)",
                label: "Working copies",
                symbol: "internaldrive"
            )
            privacyMetric(
                value: localStorageSize,
                label: "PDF storage",
                symbol: "doc.on.doc"
            )
            privacyMetric(
                value: "\(model.textIndices.count)",
                label: "Text indexes",
                symbol: "text.magnifyingglass"
            )
            privacyMetric(
                value: "\(verifiedReceiptCount)",
                label: "Receipts",
                symbol: "checkmark.seal"
            )
        }
    }

    private var processingLedger: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: "PROCESSING LEDGER",
                detail: "Data object · location · lifetime · boundary",
                symbol: "tablecells",
                count: visibleBoundaryCount,
                tint: PPColor.mint
            )
            .padding(.bottom, PPSpacing.small)

            Picker("Boundary focus", selection: $boundaryFocus) {
                ForEach(BoundaryFocus.allCases) { focus in
                    Text(focus.title.localizedUI).tag(focus)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, PPSpacing.small)

            privacyLedgerHeader
            if boundaryFocus == .all || boundaryFocus == .local {
                privacyLedgerRow(
                    object: "PDF working copies",
                    detail: "\(model.documents.count) active files",
                    location: "This device",
                    lifetime: "Trash policy",
                    boundary: "Complete protection",
                    symbol: "lock.doc",
                    tint: PPColor.mint
                )
                privacyLedgerRow(
                    object: "OCR and text index",
                    detail:
                        "\(model.ocrResults.count) OCR sets · \(indexedCharacterCount.formatted()) characters",
                    location: "This device",
                    lifetime: "With private copy",
                    boundary: "Never uploaded",
                    symbol: "text.viewfinder",
                    tint: PPColor.cyan
                )
                privacyLedgerRow(
                    object: "Document passwords",
                    detail: "Used only to unlock the open PDF",
                    location: "Memory",
                    lifetime: "Current session",
                    boundary: "Never persisted",
                    symbol: "key.horizontal",
                    tint: PPColor.amber
                )
                privacyLedgerRow(
                    object: "Saved signature",
                    detail: model.savedSignatureData == nil
                        ? "No signature stored"
                        : "One protected signature asset",
                    location: "This device",
                    lifetime: "Until removed",
                    boundary: "Never synced",
                    symbol: "signature",
                    tint: PPColor.accent
                )
            }
            if boundaryFocus == .all || boundaryFocus == .sync {
                privacyLedgerRow(
                    object: "Library metadata",
                    detail:
                        "Position, bookmarks, workflow, tags, and receipts",
                    location: metadataSyncEnabled
                        ? "Private iCloud"
                        : "This device",
                    lifetime: metadataSyncEnabled
                        ? "Opt-in sync"
                        : "Local only",
                    boundary: "No PDF bytes",
                    symbol: metadataSyncEnabled
                        ? "checkmark.icloud"
                        : "icloud.slash",
                    tint: metadataSyncEnabled
                        ? PPColor.cyan
                        : PPColor.textSecondary
                )
            }
            if boundaryFocus == .all || boundaryFocus == .outbound {
                privacyLedgerRow(
                    object: "Outbound files",
                    detail: "Delivery copies leave only on command",
                    location: "Chosen target",
                    lifetime: "Explicit handoff",
                    boundary: "Share or Files",
                    symbol: "square.and.arrow.up",
                    tint: PPColor.rose
                )
            }
        }
    }

    private var visibleBoundaryCount: Int {
        switch boundaryFocus {
        case .all: return 6
        case .local: return 4
        case .sync, .outbound: return 1
        }
    }

    private var privacyLedgerHeader: some View {
        HStack(spacing: PPSpacing.small) {
            Text("OBJECT")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("LOCATION")
                .frame(width: 112, alignment: .leading)
            Text("LIFETIME")
                .frame(width: 112, alignment: .leading)
            Text("BOUNDARY")
                .frame(width: 118, alignment: .leading)
        }
        .font(.caption2.smallCaps().weight(.bold))
        .foregroundStyle(PPColor.textSecondary)
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
        .opacity(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
        .frame(
            height: dynamicTypeSize.isAccessibilitySize ? 0 : nil
        )
    }

    private func privacyLedgerRow(
        object: String,
        detail: String,
        location: String,
        lifetime: String,
        boundary: String,
        symbol: String,
        tint: Color
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(object.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(detail.localizedUI)
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ledgerValue(location, width: 112, tint: tint)
                ledgerValue(lifetime, width: 112)
                ledgerValue(boundary, width: 118)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .frame(width: 22)
                    Text(object.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                }
                Text(detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                HStack(spacing: PPSpacing.medium) {
                    ledgerCompactValue("Location", location)
                    ledgerCompactValue("Lifetime", lifetime)
                    ledgerCompactValue("Boundary", boundary)
                }
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, PPSpacing.small)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.54))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private func ledgerValue(
        _ value: String,
        width: CGFloat,
        tint: Color = PPColor.textSecondary
    ) -> some View {
        Text(value.localizedUI)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(2)
            .frame(width: width, alignment: .leading)
    }

    private func ledgerCompactValue(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
            Text(value.localizedUI)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func privacyMetric(
        value: String,
        label: String,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.mint)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label.localizedUI.uppercased())
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.6))
                .frame(height: 0.6)
        }
    }

    private var localBoundary: some View {
        privacySection(title: "STAYS ON THIS DEVICE") {
            privacyRow(
                title: "PDF working copies",
                detail: "\(model.documents.count) files with complete file protection",
                symbol: "lock.doc",
                tint: PPColor.mint
            )
            privacyRow(
                title: "OCR and extracted text",
                detail: "\(model.ocrResults.count) OCR sets · \(indexedCharacterCount.formatted()) indexed characters",
                symbol: "text.viewfinder",
                tint: PPColor.cyan
            )
            privacyRow(
                title: "File names and passwords",
                detail: "Names stay local; document passwords remain session-only",
                symbol: "key.horizontal",
                tint: PPColor.amber
            )
            privacyRow(
                title: "Saved signature",
                detail: model.savedSignatureData == nil
                    ? "No signature stored"
                    : "Encrypted by iOS file protection on this device",
                symbol: "signature",
                tint: PPColor.accent
            )
        }
    }

    private var accessBoundary: some View {
        privacySection(title: "APP ACCESS") {
            Toggle(
                isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { enabled in
                        Task {
                            if enabled {
                                _ = await appLock.enable()
                            } else {
                                appLock.disable()
                            }
                        }
                    }
                )
            ) {
                HStack(spacing: PPSpacing.medium) {
                    ToolSymbolPlate(
                        symbol: appLock.symbol,
                        tint: appLock.isEnabled
                            ? PPColor.mint
                            : PPColor.textSecondary,
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("App Lock")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            appLock.isEnabled
                                ? appLock.methodTitle.localizedUI
                                : (
                                    appLock.isAvailable
                                        ? "Off".localizedUI
                                        : "Unavailable on this device"
                                            .localizedUI
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(
                !appLock.isAvailable && !appLock.isEnabled
            )
            .padding(.vertical, PPSpacing.small)
            .accessibilityIdentifier("appLockToggle")

            if appLock.isEnabled {
                HStack(spacing: PPSpacing.medium) {
                    ToolSymbolPlate(
                        symbol: "timer",
                        tint: PPColor.cyan,
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Require Again")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(appLock.delay.title.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: PPSpacing.small)
                    Picker(
                        "Require Again",
                        selection: Binding(
                            get: { appLock.delay },
                            set: { appLock.setDelay($0) }
                        )
                    ) {
                        ForEach(AppLockDelay.allCases) { delay in
                            Text(delay.title.localizedUI)
                                .tag(delay)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("appLockDelayPicker")
                }
                .padding(.vertical, PPSpacing.small)

                Button {
                    dismiss()
                    Task {
                        try? await Task.sleep(
                            for: .milliseconds(240)
                        )
                        appLock.lockNow()
                    }
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(PPColor.accent)
                .accessibilityIdentifier("lockPaperPathNow")
            }

            if let errorMessage = appLock.errorMessage {
                HStack(alignment: .top, spacing: PPSpacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.vertical, PPSpacing.small)
            }
        }
    }

    private var metadataBoundary: some View {
        privacySection(title: "iCLOUD METADATA") {
            HStack(alignment: .top, spacing: PPSpacing.medium) {
                Image(systemName: metadataSyncSymbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(metadataSyncColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(metadataSyncTitle.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(model.metadataSyncStatus.detail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    if let updatedAt = model.metadataSyncStatus.updatedAt {
                        Text(
                            updatedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PPColor.textSecondary)
                    }
                }
                Spacer(minLength: PPSpacing.small)
                Button {
                    Task {
                        await model.synchronizeMetadata()
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.cyan)
                .disabled(
                    !metadataSyncEnabled
                        || model.metadataSyncStatus.state == .syncing
                )
                .opacity(metadataSyncEnabled ? 1 : 0.38)
                .accessibilityLabel("Sync metadata now")
            }
            .padding(.vertical, PPSpacing.small)

            privacyRow(
                title: metadataSyncEnabled
                    ? "Can sync"
                    : "Sync is off",
                detail: "Reading position, bookmarks, workflow, pins, tags, completed actions, and receipts",
                symbol: metadataSyncEnabled
                    ? "checkmark.icloud"
                    : "icloud.slash",
                tint: metadataSyncEnabled
                    ? PPColor.cyan
                    : PPColor.textSecondary
            )
            privacyRow(
                title: "Never synced",
                detail: "PDF bytes, file names, OCR text, extracted content, passwords, and signatures",
                symbol: "icloud.slash",
                tint: PPColor.amber
            )
        }
    }

    private var previewBoundary: some View {
        privacySection(title: "PREVIEWS") {
            Toggle(isOn: $hideLibraryPreviews) {
                HStack(spacing: PPSpacing.medium) {
                    ToolSymbolPlate(
                        symbol: hideLibraryPreviews
                            ? "eye.slash.fill"
                            : "eye",
                        tint: hideLibraryPreviews
                            ? PPColor.mint
                            : PPColor.cyan,
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hide Library Thumbnails")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            hideLibraryPreviews
                                ? "Generic document covers are active"
                                : "First-page previews are visible"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .padding(.vertical, PPSpacing.small)
            .accessibilityIdentifier("hideLibraryPreviews")

            privacyRow(
                title: "Editing previews stay available",
                detail: "Page organization, signatures, redaction review, and output inspection keep their working thumbnails",
                symbol: "rectangle.on.rectangle",
                tint: PPColor.textSecondary
            )
        }
    }

    private var networkBoundary: some View {
        privacySection(title: "NETWORK BOUNDARY") {
            privacyRow(
                title: "No PaperPath document service",
                detail: "PaperPath does not upload PDF content or extracted text to an app-managed server",
                symbol: "network.slash",
                tint: PPColor.mint
            )
            privacyRow(
                title: "Explicit handoff only",
                detail: "Files leave the private library only through Share, Files export, or source replacement",
                symbol: "square.and.arrow.up",
                tint: PPColor.accent
            )
        }
    }

    private func privacySection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: title)
                .padding(.bottom, PPSpacing.small)
            content()
        }
    }

    private func privacyRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: symbol,
                tint: tint,
                size: 38
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.54))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .combine)
    }

    private var localStorageSize: String {
        ByteCountFormatter.string(
            fromByteCount: model.documents.reduce(0) {
                $0 + $1.profile.byteCount
            },
            countStyle: .file
        )
    }

    private var indexedCharacterCount: Int {
        model.textIndices.values.reduce(0) {
            $0 + $1.characterCount
        }
    }

    private var verifiedReceiptCount: Int {
        model.documents.filter {
            $0.deliveryReceipt != nil
        }.count
    }

    private var metadataSyncTitle: String {
        guard metadataSyncEnabled else {
            return "iCloud metadata is off"
        }
        switch model.metadataSyncStatus.state {
        case .idle: return "Ready to sync"
        case .syncing: return "Syncing metadata"
        case .synced:
            let count = model.metadataSyncStatus.documentCount
            return "\(count) document\(count == 1 ? "" : "s") current"
        case .unavailable: return "iCloud unavailable"
        case .failed: return "Sync needs attention"
        }
    }

    private var metadataSyncSymbol: String {
        guard metadataSyncEnabled else {
            return "icloud.slash"
        }
        switch model.metadataSyncStatus.state {
        case .idle: return "icloud"
        case .syncing: return "icloud.and.arrow.up"
        case .synced: return "checkmark.icloud"
        case .unavailable: return "icloud.slash"
        case .failed: return "exclamationmark.icloud"
        }
    }

    private var metadataSyncColor: Color {
        switch model.metadataSyncStatus.state {
        case .synced: return PPColor.mint
        case .failed: return .red
        case .unavailable: return PPColor.amber
        case .idle, .syncing: return PPColor.cyan
        }
    }
}

private struct LibraryPageSearchView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let query: String
    let snapshot: LibraryPageSearchSnapshot
    let onOpen: (UUID, Int) -> Void

    @State private var selectedEvidence: Set<EvidenceID> = []
    @State private var evidenceURL: URL?
    @State private var isSharingEvidence = false
    @State private var copyFeedback = 0

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if groups.isEmpty {
                    PPEmptyState(
                        kind: .search,
                        title: "No page matches",
                        message: "Try a shorter or more specific phrase."
                    )
                    .padding(PPSpacing.regular)
                } else {
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: PPSpacing.xLarge
                        ) {
                            searchSummary
                            ForEach(groups) { group in
                                resultGroup(group)
                            }
                        }
                        .frame(maxWidth: 720)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Page Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !selectedEvidence.isEmpty {
                    evidenceBar
                }
            }
        }
        .sheet(
            isPresented: $isSharingEvidence,
            onDismiss: cleanupEvidenceExport
        ) {
            if let evidenceURL {
                ShareSheet(items: [evidenceURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .sensoryFeedback(.selection, trigger: selectedEvidence.count)
        .sensoryFeedback(.success, trigger: copyFeedback)
    }

    private var searchSummary: some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: "text.page.badge.magnifyingglass",
                tint: PPColor.cyan,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                SectionEyebrow(text: "LOCAL FULL-TEXT INDEX")
                Text("“\(query)”")
                    .font(.title3.bold())
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)
                Text(
                    snapshot.isLimited
                        ? AppLocalization.format(
                            "Showing first %lld pages · %lld PDFs",
                            totalMatches,
                            groups.count
                        )
                        : AppLocalization.format(
                            "%lld pages · %lld PDFs",
                            totalMatches,
                            groups.count
                        )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
            }
            Spacer()
        }
        .padding(.bottom, PPSpacing.medium)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.66))
                .frame(height: 0.6)
        }
    }

    private func resultGroup(
        _ group: PageSearchGroup
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: group.record.profile.kind.symbol)
                    .foregroundStyle(PPColor.cyan)
                Text(group.record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(group.matches.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(.bottom, PPSpacing.small)

            ForEach(
                Array(group.matches.enumerated()),
                id: \.offset
            ) { index, match in
                let evidenceID = EvidenceID(
                    recordID: group.record.id,
                    pageIndex: match.pageIndex
                )
                HStack(alignment: .top, spacing: PPSpacing.small) {
                    Button {
                        onOpen(group.record.id, match.pageIndex)
                    } label: {
                        HStack(
                            alignment: .top,
                            spacing: PPSpacing.medium
                        ) {
                        Text("P\(match.pageIndex + 1)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(PPColor.cyan)
                            .frame(width: 34, alignment: .leading)
                        Text(
                            highlighted(
                                match.excerpt,
                                query: query
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        if selectedEvidence.contains(evidenceID) {
                            selectedEvidence.remove(evidenceID)
                        } else {
                            selectedEvidence.insert(evidenceID)
                        }
                    } label: {
                        Image(
                            systemName: selectedEvidence
                                .contains(evidenceID)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            selectedEvidence.contains(evidenceID)
                                ? PPColor.accent
                                : PPColor.textSecondary
                        )
                        .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        selectedEvidence.contains(evidenceID)
                            ? "Remove page \(match.pageIndex + 1) from evidence"
                            : "Add page \(match.pageIndex + 1) to evidence"
                    )
                }
                .padding(.vertical, PPSpacing.small)

                if index < group.matches.count - 1 {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.55))
                        .frame(height: 0.6)
                        .padding(.leading, 46)
                }
            }
        }
        .padding(.horizontal, PPSpacing.medium)
        .padding(.vertical, PPSpacing.small)
        .ppPaper(cornerRadius: 8, shadow: false)
    }

    private var groups: [PageSearchGroup] {
        model.documents.compactMap { record in
            let matches =
                snapshot.matchesByRecordID[record.id] ?? []
            guard !matches.isEmpty else { return nil }
            return PageSearchGroup(
                record: record,
                matches: matches
            )
        }
        .sorted {
            if $0.matches.count != $1.matches.count {
                return $0.matches.count > $1.matches.count
            }
            return $0.record.displayName.localizedStandardCompare(
                $1.record.displayName
            ) == .orderedAscending
        }
    }

    private var totalMatches: Int {
        groups.reduce(0) { $0 + $1.matches.count }
    }

    private var evidenceBar: some View {
        HStack(spacing: PPSpacing.small) {
            Label(
                "\(selectedEvidence.count) selected",
                systemImage: "checkmark.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.textPrimary)
            .monospacedDigit()

            Spacer()

            Button {
                UIPasteboard.general.string = evidenceMarkdown
                copyFeedback += 1
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.cyan)
            .accessibilityLabel("Copy selected evidence")

            Button {
                exportEvidence()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .accessibilityLabel("Export selected evidence")

            Button {
                selectedEvidence.removeAll()
            } label: {
                Image(systemName: "xmark.circle")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityLabel("Clear evidence selection")
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)
        }
    }

    private var selectedEvidenceItems: [EvidenceItem] {
        groups.flatMap { group in
            group.matches.compactMap { match in
                let id = EvidenceID(
                    recordID: group.record.id,
                    pageIndex: match.pageIndex
                )
                guard selectedEvidence.contains(id) else { return nil }
                return EvidenceItem(
                    id: id,
                    documentName: group.record.displayName,
                    excerpt: match.excerpt
                )
            }
        }
        .sorted {
            if $0.documentName != $1.documentName {
                return $0.documentName.localizedStandardCompare(
                    $1.documentName
                ) == .orderedAscending
            }
            return $0.id.pageIndex < $1.id.pageIndex
        }
    }

    private var evidenceMarkdown: String {
        var lines = [
            "# PaperPath Evidence — \(query)",
            "",
            "Generated \(Date().formatted(date: .long, time: .shortened))",
            ""
        ]
        var previousDocument: String?
        for item in selectedEvidenceItems {
            if previousDocument != item.documentName {
                if previousDocument != nil {
                    lines.append("")
                }
                lines.append("## \(item.documentName)")
                previousDocument = item.documentName
            }
            lines.append(
                "- **Page \(item.id.pageIndex + 1):** \(item.excerpt)"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func exportEvidence() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Evidence-\(UUID().uuidString).md"
            )
        do {
            try evidenceMarkdown.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            LocalFileSecurity.applyCompleteProtection(to: url)
            LocalFileSecurity.excludeFromBackup(url)
            evidenceURL = url
            isSharingEvidence = true
        } catch {
            model.present(error)
        }
    }

    private func cleanupEvidenceExport() {
        guard let evidenceURL else { return }
        try? FileManager.default.removeItem(at: evidenceURL)
        self.evidenceURL = nil
    }

    private func highlighted(
        _ value: String,
        query: String
    ) -> AttributedString {
        var attributed = AttributedString(value)
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        for term in terms where !term.isEmpty {
            var start = value.startIndex
            while start < value.endIndex,
                  let range = value.range(
                      of: term,
                      options: [
                          .caseInsensitive,
                          .diacriticInsensitive
                      ],
                      range: start..<value.endIndex
                  ) {
                if let lower = AttributedString.Index(
                    range.lowerBound,
                    within: attributed
                ),
                   let upper = AttributedString.Index(
                       range.upperBound,
                       within: attributed
                   ) {
                    attributed[lower..<upper].backgroundColor =
                        PPColor.amber.opacity(0.24)
                    attributed[lower..<upper].inlinePresentationIntent =
                        .stronglyEmphasized
                }
                start = range.upperBound
            }
        }
        return attributed
    }

    private struct PageSearchGroup: Identifiable {
        let record: DocumentRecord
        let matches: [DocumentTextMatch]

        var id: UUID { record.id }
    }

    private struct EvidenceID: Hashable {
        let recordID: UUID
        let pageIndex: Int
    }

    private struct EvidenceItem: Identifiable {
        let id: EvidenceID
        let documentName: String
        let excerpt: String
    }
}
