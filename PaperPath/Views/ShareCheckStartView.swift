import SwiftUI
import UniformTypeIdentifiers

private struct ShareCheckDestination: Hashable {
    let route: DocumentRoute
    let startsPrivacyReview: Bool
}

/// A direct route into existing privacy review. Never reuses a real document as a sample.
struct ShareCheckStartView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [ShareCheckDestination] = []
    @State private var importing = false
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var query = ""

    private var availableDocuments: [DocumentRecord] {
        model.documents.filter {
            $0.deletedAt == nil && !$0.profile.isLocked
                && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query))
        }
    }
    private var processing: Bool {
        busy || path.last.map { model.isProcessing($0.route.recordID) } == true
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text("Review private details, then check the copy you share.".localizedUI)
                        .font(.title3.weight(.semibold)).fontDesign(.serif)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                    Button {
                        importing = true
                    } label: {
                        Label("Choose a PDF".localizedUI, systemImage: "folder")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("shareCheckImport")
                    Button {
                        createSample()
                    } label: {
                        HStack {
                            Label("Try a fictional sample".localizedUI, systemImage: "doc.text")
                            Spacer()
                            if busy { ProgressView() }
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("shareCheckSample")
                }
                Section("Or choose from Library".localizedUI) {
                    ForEach(availableDocuments) { record in
                        Button { open(record) } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "doc").foregroundStyle(PPColor.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.displayName).foregroundStyle(PPColor.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(record.profile.formattedSize).font(.caption).foregroundStyle(PPColor.textSecondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(PPColor.textSecondary)
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("shareCheckDocument-\(record.id.uuidString)")
                    }
                    if availableDocuments.isEmpty {
                        Text("Import a PDF above, or try the fictional sample.".localizedUI)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
                Section {
                    Text("Automatic detection can miss information. Review before sharing.".localizedUI)
                        .font(.footnote).foregroundStyle(PPColor.textSecondary)
                }
                if let error { Section { Text(error).foregroundStyle(PPColor.amber).accessibilityIdentifier("shareCheckError") } }
            }
            .disabled(busy)
            .searchable(text: $query, prompt: "Search PDFs".localizedUI)
            .scrollContentBackground(.hidden)
            .background(PPColor.canvas)
            .navigationTitle("Check before sharing".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done".localizedUI) { dismiss() }.disabled(processing)
                }
            }
            .navigationDestination(for: ShareCheckDestination.self) { destination in
                DocumentWorkspaceView(
                    recordID: destination.route.recordID,
                    initialPageIndex: destination.route.pageIndex,
                    initialQuickTask: destination.route.quickTask,
                    initialContentRevisionID: destination.route.expectedContentRevisionID,
                    initialPrivacyScan: destination.startsPrivacyReview,
                    onOpenDocument: { route in path.append(.init(route: route, startsPrivacyReview: false)) }
                ).id(destination.route)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    busy = true; error = nil
                    task = Task { @MainActor in
                        defer { busy = false; task = nil }
                        guard let record = await model.importPDF(from: url) else {
                            if !Task.isCancelled { error = "Could not import this PDF. Please try another file.".localizedUI }
                            return
                        }
                        guard !Task.isCancelled else { return }
                        open(record)
                    }
                case .failure(let issue):
                    if (issue as NSError).code != NSUserCancelledError { error = issue.localizedDescription }
                }
            }
        }
        .interactiveDismissDisabled(processing)
        .tint(PPColor.accent)
        .onChange(of: scenePhase) { _, phase in if phase == .background { task?.cancel() } }
        .onDisappear { task?.cancel() }
    }

    private func open(_ record: DocumentRecord) {
        guard !record.profile.isLocked else {
            error = "Unlock the PDF before checking private details.".localizedUI
            return
        }
        path.append(.init(route: DocumentRoute(recordID: record.id, expectedContentRevisionID: record.contentRevisionID), startsPrivacyReview: true))
    }
    private func createSample() {
        guard !busy else { return }
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let record = try await model.createShareCheckSample()
                guard !Task.isCancelled else { return }
                open(record)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
