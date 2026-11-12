#if DEBUG && !PAPERPATH_REVIEW_BUILD
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct AssistantMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    var recordID: UUID? = nil
}

private struct AssistantSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct PDFAssistantView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [PDFAssistantFile] = []
    @State private var nextNumber = 1
    @State private var messages: [AssistantMessage] = []
    @State private var draft = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var composerFocused = false
    @State private var plan: PDFAssistantPlan?
    @State private var busy = false
    @State private var activity = ""
    @State private var error: String?
    @State private var availability = PDFAssistantService().availability()
    @State private var task: Task<Void, Never>?
    @State private var showsPicker = false
    @State private var showsImport = false
    @State private var showsQuickActions = false
    @State private var preview: DocumentRecord?
    @State private var sharedFile: AssistantSharedFile?
    private let service = PDFAssistantService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                attachmentShelf
                Divider()
                conversation
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("PDF Assistant".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done".localizedUI) { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Quick actions".localizedUI, systemImage: "slider.horizontal.3") { showsQuickActions = true }
                        Button("Refresh model status".localizedUI, systemImage: "arrow.clockwise") { availability = service.availability() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $showsPicker) {
                AssistantFilePicker(selected: Set(files.map(\.id))) { records in
                    plan = nil
                    for record in records where !files.contains(where: { $0.id == record.id }) { addFile(record) }
                }
            }
            .sheet(isPresented: $showsQuickActions) {
                AssistantQuickActions(files: currentFiles()) { steps in
                    prepareQuickAction(steps)
                }
            }
            .sheet(item: $preview) { record in
                NavigationStack {
                    DocumentWorkspaceView(recordID: record.id, onOpenDocument: { route in preview = model.record(id: route.recordID) })
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done".localizedUI) { preview = nil } } }
                }
            }
            .sheet(item: $sharedFile, onDismiss: cleanupShare) {
                ShareSheet(items: [$0.url], removesTemporaryItemsOnCompletion: false)
            }
            .fileImporter(isPresented: $showsImport, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let issue): error = issue.localizedDescription
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { availability = service.availability() }
                else { task?.cancel(); composerFocused = false }
            }
            .onDisappear { task?.cancel(); composerFocused = false; cleanupShare() }
        }
        .tint(PPColor.accent)
    }

    private var attachmentShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    Button("Choose from Library".localizedUI, systemImage: "books.vertical") { composerFocused = false; showsPicker = true }
                    Button("Import PDF".localizedUI, systemImage: "folder") { composerFocused = false; showsImport = true }
                } label: { Label("Add PDFs".localizedUI, systemImage: "plus") .font(.subheadline.weight(.semibold)) }
                .accessibilityIdentifier("assistantAddFiles")
                .disabled(busy || files.count >= 16)
                Spacer()
                if !files.isEmpty { Text("Tap a number to reference".localizedUI).font(.caption).foregroundStyle(PPColor.textSecondary) }
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files) { file in
                            Button { insertReference(file) } label: {
                                HStack(spacing: 8) {
                                    Text("#\(file.number)").font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(PPColor.accent)
                                    Text(model.record(id: file.id)?.displayName ?? file.name).font(.subheadline).lineLimit(1)
                                        .frame(maxWidth: 160, alignment: .leading)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 12)
                                .background(PPColor.surface, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("#\(file.number) \(file.name)")
                            .accessibilityHint("Insert this file reference into your request".localizedUI)
                            .accessibilityIdentifier("assistantReference\(file.number)")
                            .contextMenu {
                                Button("Reference in request".localizedUI, systemImage: "number") { insertReference(file) }
                                Button("Open PDF".localizedUI, systemImage: "doc") { preview = model.record(id: file.id) }
                                Button("Remove from conversation".localizedUI, systemImage: "minus.circle") { files.removeAll { $0.id == file.id }; plan = nil }
                            }
                            .disabled(busy)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var conversation: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if messages.isEmpty && plan == nil { introduction }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 10) {
                            if !message.text.isEmpty {
                                Text(message.text)
                                    .textSelection(.enabled)
                                    .padding(message.isUser ? 12 : 0)
                                    .background(message.isUser ? PPColor.surfaceMuted : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
                            }
                            if let id = message.recordID, let record = model.record(id: id) { resultRow(record) }
                        }.id(message.id)
                    }
                    if let plan { planReview(plan) }
                    if busy {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(activity.localizedUI).font(.subheadline)
                            Spacer()
                            Button("Stop".localizedUI) { task?.cancel() }
                        }.accessibilityIdentifier("assistantProgress")
                    }
                    if let error { Text(error).foregroundStyle(PPColor.amber).accessibilityIdentifier("assistantError") }
                    Color.clear.frame(height: 1).id("assistantBottom")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in withAnimation { scroll.scrollTo("assistantBottom", anchor: .bottom) } }
            .onChange(of: plan?.id) { _, _ in withAnimation { scroll.scrollTo("assistantBottom", anchor: .bottom) } }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What would you like to do with your PDFs?".localizedUI)
                .font(.title2.weight(.semibold)).fontDesign(.serif)
                .padding(.top, 18)
            Text("Choose PDFs, then mention them as #1 or #2. Generated PDFs get their own numbers, too.".localizedUI)
                .foregroundStyle(PPColor.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                suggestion("Combine #1 and #2, then compress the result")
                Divider()
                suggestion("Extract pages 2–4 from #1")
            }
            Button("Quick actions".localizedUI, systemImage: "slider.horizontal.3") { showsQuickActions = true }
                .disabled(files.isEmpty || busy)
            Text("Demo: combine, extract pages and compress. Each task creates copies in Library.".localizedUI)
                .font(.footnote).foregroundStyle(PPColor.textSecondary)
            if availability.canChat { modelStatus }
        }
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            draft = text.localizedUI; selection = NSRange(location: draft.utf16.count, length: 0); composerFocused = true
        } label: {
            HStack(alignment: .firstTextBaseline) { Text(text.localizedUI).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.left") }
                .padding(.vertical, 14)
        }.disabled(busy)
    }

    private var modelStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(availability.title.localizedUI, systemImage: availability.canChat ? "checkmark.circle" : "info.circle")
                .font(.footnote.weight(.medium))
            Text(availability.detail.localizedUI).font(.footnote).foregroundStyle(PPColor.textSecondary)
        }.accessibilityIdentifier("assistantModelStatus")
    }

    private func planReview(_ plan: PDFAssistantPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((plan.usesLanguageModel ? "Proposed steps" : "Quick action preview").localizedUI).font(.headline)
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(index + 1). \(step.action.title.localizedUI)").font(.subheadline.weight(.semibold))
                    Text(stepDetail(step)).font(.subheadline).foregroundStyle(PPColor.textSecondary)
                }
            }
            Text("Creates new PDFs; keeps the originals. Compression uses balanced settings and cannot guarantee a file size.".localizedUI)
                .font(.footnote).foregroundStyle(PPColor.textSecondary)
            HStack {
                Button("Generate PDFs".localizedUI) { execute(plan) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("assistantExecute")
                Button("Dismiss steps".localizedUI) { self.plan = nil }
            }.disabled(busy)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stepDetail(_ step: PDFAssistantStep) -> String {
        let inputs = step.inputs.map { $0 == 0 ? "Previous step result".localizedUI : "#\($0)" }.joined(separator: " → ")
        return step.action == .extract ? "\(inputs) · \(step.firstPage)–\(step.lastPage)" : inputs
    }

    private func resultRow(_ record: DocumentRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let file = files.first { $0.id == record.id }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.richtext").font(.title2).foregroundStyle(PPColor.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(file.map { "#\($0.number) " } ?? "")\(record.displayName)").font(.headline)
                    Text(record.profile.formattedSize).font(.caption).foregroundStyle(PPColor.textSecondary)
                }
            }
            HStack {
                Button("Open PDF".localizedUI) { preview = record }
                if let file { Button("Reference in request".localizedUI) { insertReference(file) } }
                Button("Share".localizedUI, systemImage: "square.and.arrow.up") { share(record) }
            }.font(.subheadline).disabled(busy)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(PPColor.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !referenceMatches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(referenceMatches) { file in
                            Button("#\(file.number) \(file.name)") { insertReference(file) }.lineLimit(1).buttonStyle(.bordered)
                        }
                    }.padding(.horizontal, 16)
                }.accessibilityIdentifier("assistantReferenceSuggestions")
            }
            if !availability.canChat { modelStatus.padding(.horizontal, 16) }
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Describe your task, or type # to reference a PDF".localizedUI)
                            .foregroundStyle(PPColor.textSecondary).padding(.top, 9).padding(.leading, 5).allowsHitTesting(false)
                    }
                    AssistantComposer(text: $draft, selection: $selection, focused: $composerFocused, enabled: !busy)
                        .frame(minHeight: 44, maxHeight: 140)
                }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Prepare PDF steps".localizedUI).accessibilityIdentifier("assistantSend")
                    .disabled(busy || !availability.canChat || files.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10).background(PPColor.surface, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 12)
            HStack {
                Text("PDF Assistant · Demo".localizedUI).font(.caption).foregroundStyle(PPColor.textSecondary)
                Spacer()
                Button("Quick actions".localizedUI) { composerFocused = false; showsQuickActions = true }.font(.caption)
                    .disabled(busy || files.isEmpty)
            }.padding(.horizontal, 20)
        }
        .padding(.vertical, 10).background(PPColor.canvas)
    }

    private var referenceRange: NSRange? {
        PDFAssistantReferences.activeRange(text: draft, selection: selection)
    }
    private var referenceMatches: [PDFAssistantFile] {
        guard let range = referenceRange else { return [] }
        let prefix = (draft as NSString).substring(with: range).dropFirst()
        return files.filter { prefix.isEmpty || String($0.number).hasPrefix(prefix) }
    }
    private func insertReference(_ file: PDFAssistantFile) {
        let inserted = PDFAssistantReferences.inserting(number: file.number, text: draft, selection: selection)
        guard inserted.text.count <= 1200 else { return }
        draft = inserted.text; selection = inserted.selection; composerFocused = true
    }

    private func addFile(_ record: DocumentRecord) {
        guard files.count < 16, !files.contains(where: { $0.id == record.id }) else { return }
        files.append(.init(id: record.id, number: nextNumber, name: record.displayName,
            revisionID: record.contentRevisionID, pageCount: record.profile.pageCount, isLocked: record.profile.isLocked))
        nextNumber += 1
    }
    private func currentFiles() -> [PDFAssistantFile] {
        files.compactMap { file in
            guard let record = model.record(id: file.id), record.deletedAt == nil else { return nil }
            return .init(id: record.id, number: file.number, name: record.displayName,
                         revisionID: record.contentRevisionID, pageCount: record.profile.pageCount, isLocked: record.profile.isLocked)
        }
    }
    private func send() {
        availability = service.availability()
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, availability.canChat, !request.isEmpty, !files.isEmpty else { return }
        let contextFiles = currentFiles()
        guard contextFiles.count == files.count, !contextFiles.contains(where: \.isLocked) else {
            error = "Choose available, unlocked PDFs before preparing steps.".localizedUI; return
        }
        let history = messages.suffix(8).map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
            + (plan.map { "\nPlan (not executed): " + $0.steps.map { $0.action.rawValue + ": " + stepDetail($0) }.joined(separator: "; ") } ?? "")
        files = contextFiles; plan = nil; draft = ""; selection = NSRange(location: 0, length: 0)
        messages.append(.init(isUser: true, text: request)); composerFocused = false
        busy = true; error = nil; activity = "Preparing steps on this device"
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let reply = try await service.prepare(request: request, files: contextFiles, conversation: history)
                try Task.checkCancellation()
                if let prepared = reply.plan {
                    guard files.count + prepared.steps.count <= 16 else {
                        throw PDFAssistantError.invalidPlan
                    }
                    plan = prepared
                } else { messages.append(.init(isUser: false, text: reply.clarification ?? "")) }
            } catch is CancellationError { error = "Stopped. Completed copies remain in Library.".localizedUI }
            catch { self.error = error.localizedDescription }
        }
    }
    private func prepareQuickAction(_ steps: [PDFAssistantStep]) {
        let prepared = PDFAssistantPlan(files: currentFiles(), steps: steps, usesLanguageModel: false)
        do {
            try prepared.validate()
            guard files.count + steps.count <= 16 else { throw PDFAssistantError.invalidPlan }
            plan = prepared; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func execute(_ prepared: PDFAssistantPlan) {
        guard !busy else { return }
        plan = nil; busy = true; error = nil; composerFocused = false
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                try await PDFAssistantExecutor().execute(prepared, model: model) { index, record in
                    addFile(record)
                    let number = files.first { $0.id == record.id }?.number ?? 0
                    messages.append(.init(isUser: false,
                        text: AppLocalization.format("Completed step %lld · #%lld saved in Library", index + 1, number), recordID: record.id))
                } progress: { index in
                    activity = prepared.steps[index].action.title
                }
            } catch is CancellationError { error = "Stopped. Completed copies remain in Library.".localizedUI }
            catch { self.error = error.localizedDescription }
        }
    }
    private func importFiles(_ urls: [URL]) {
        guard !busy else { return }
        guard urls.count + files.count <= 12 else { error = "Add up to 12 PDFs, leaving room for generated results.".localizedUI; return }
        busy = true; activity = "Importing PDFs"; error = nil; plan = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            let records = await model.importPDFs(from: urls)
            for record in records { addFile(record) }
            if records.count != urls.count { error = "Some PDFs could not be imported. Please check Library.".localizedUI }
        }
    }
    private func share(_ record: DocumentRecord) {
        busy = true; activity = "Preparing PDF for sharing"; error = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            if let url = await model.makeFilesExportCopy(recordID: record.id) {
                if Task.isCancelled { await model.discardFilesExportCopy(at: url); return }
                sharedFile = .init(url: url)
            }
            else { error = "Could not prepare this PDF for sharing.".localizedUI }
        }
    }
    private func cleanupShare() {
        guard let url = sharedFile?.url else { return }
        sharedFile = nil
        Task { await model.discardFilesExportCopy(at: url) }
    }
}

private struct AssistantFilePicker: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    let selected: Set<UUID>
    let completed: ([DocumentRecord]) -> Void
    @State private var chosen = Set<UUID>()
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.documents.filter { $0.deletedAt == nil && !selected.contains($0.id) && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }) { record in
                    Button {
                        if chosen.contains(record.id) { chosen.remove(record.id) }
                        else if chosen.count + selected.count < 12 { chosen.insert(record.id) }
                    } label: {
                        HStack {
                            Image(systemName: chosen.contains(record.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(record.displayName).foregroundStyle(PPColor.textPrimary)
                                Text(record.profile.formattedSize).font(.caption).foregroundStyle(PPColor.textSecondary)
                            }
                        }.frame(minHeight: 44)
                    }.disabled(record.profile.isLocked)
                }
            }
            .searchable(text: $search)
            .navigationTitle("Choose PDFs".localizedUI)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel".localizedUI) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add PDFs".localizedUI) { completed(model.documents.filter { chosen.contains($0.id) }); dismiss() }.disabled(chosen.isEmpty)
                }
            }
        }
    }
}

private struct AssistantQuickActions: View {
    @Environment(\.dismiss) private var dismiss
    let files: [PDFAssistantFile]
    let completed: ([PDFAssistantStep]) -> Void
    @State private var action = PDFAssistantAction.merge
    @State private var selectedNumber = 0
    @State private var firstPage = "1"
    @State private var lastPage = "1"
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Operation".localizedUI, selection: $action) {
                        Text("Combine PDFs".localizedUI).tag(PDFAssistantAction.merge)
                        Text("Extract pages".localizedUI).tag(PDFAssistantAction.extract)
                        Text("Compress a copy".localizedUI).tag(PDFAssistantAction.compress)
                    }
                    if action == .merge {
                        Text(files.map { "#\($0.number) \($0.name)" }.joined(separator: "\n"))
                        Text("Combines files in the displayed order.".localizedUI).font(.footnote)
                    } else {
                        Picker("PDF".localizedUI, selection: $selectedNumber) {
                            ForEach(files) { Text("#\($0.number) \($0.name)").tag($0.number) }
                        }
                    }
                    if action == .extract {
                        TextField("First page".localizedUI, text: $firstPage).keyboardType(.numberPad)
                        TextField("Last page".localizedUI, text: $lastPage).keyboardType(.numberPad)
                    }
                }
                Section { Text("Quick actions do not use a language model. You review the steps before generating copies.".localizedUI).font(.footnote) }
                if let error { Text(error).foregroundStyle(PPColor.amber) }
            }
            .navigationTitle("Quick actions".localizedUI)
            .onAppear { selectedNumber = files.first?.number ?? 0; if files.count == 1 { action = .compress } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel".localizedUI) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review steps".localizedUI) {
                        let step = PDFAssistantStep(action: action,
                            inputs: action == .merge ? files.map(\.number) : [selectedNumber],
                            firstPage: action == .extract ? (Int(firstPage) ?? 0) : 0,
                            lastPage: action == .extract ? (Int(lastPage) ?? 0) : 0)
                        do {
                            try PDFAssistantPlan(files: files, steps: [step], usesLanguageModel: false).validate()
                            completed([step]); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(files.isEmpty)
                }
            }
        }
    }
}

/// UITextView preserves the actual caret/selection for # references and mixed Chinese text.
private struct AssistantComposer: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let enabled: Bool
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        view.textColor = .label
        view.delegate = context.coordinator
        view.accessibilityLabel = "PDF request".localizedUI
        view.accessibilityIdentifier = "assistantComposer"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if view.text != text { view.text = text }
        if view.markedTextRange == nil, view.selectedRange != selection,
           selection.location + selection.length <= view.text.utf16.count { view.selectedRange = selection }
        view.isEditable = enabled
        if focused && enabled && !view.isFirstResponder { view.becomeFirstResponder() }
        else if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 260
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(140, max(44, measured.height)))
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AssistantComposer
        var updating = false
        init(_ parent: AssistantComposer) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) { guard !updating else { return }; parent.text = view.text; parent.selection = view.selectedRange }
        func textViewDidChangeSelection(_ view: UITextView) { guard !updating else { return }; parent.selection = view.selectedRange }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused { parent.focused = false } }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard let valid = Range(range, in: textView.text) else { return false }
            return textView.text.replacingCharacters(in: valid, with: text).count <= 1200
        }
    }
}

#endif
