import SwiftUI

private struct KeyDetailPreview: Identifiable {
    let id = UUID()
    let recordID: UUID
    let revisionID: UUID
    let pageIndex: Int
}

private struct KeyDetailReplacement: Identifiable {
    let id = UUID()
    let requirementID: UUID
    let originalRecordID: UUID?
}

struct HandoffKeyDetailsView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.scenePhase) private var scenePhase
    let packetID: UUID
    @State private var editing: HandoffKeyDetail?
    @State private var preview: KeyDetailPreview?
    @State private var replacement: KeyDetailReplacement?
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    private var packet: HandoffPacket? { model.handoffWorkspace.packets.first { $0.id == packetID } }
    private var currentReport: HandoffKeyDetailReport? {
        guard let packet, let report = packet.keyDetailReport,
              report.isCurrent(for: packet, documents: model.handoffDocuments(for: packet)) else { return nil }
        return report
    }

    var body: some View {
        Group {
            if let packet {
                List {
                    if packet.detailsToCheck.isEmpty {
                        Section {
                            Text("Catch conflicting details before sharing".localizedUI)
                                .font(.title2.weight(.semibold)).fontDesign(.serif)
                            Text("Choose the project references, client names or other labelled text that must agree across your materials.".localizedUI)
                                .foregroundStyle(PPColor.textSecondary)
                            Button("Add a key detail".localizedUI, action: addDetail)
                                .disabled(packet.requirements.count < 2)
                                .accessibilityIdentifier("keyDetailsAddEmpty")
                        }
                    } else {
                        Section {
                            Label(summary(packet), systemImage: passed(packet) ? "checkmark.circle" : "doc.text.magnifyingglass")
                                .font(.headline).foregroundStyle(passed(packet) ? PPColor.mint : PPColor.accent)
                            if currentReport == nil {
                                Text("Check the selected PDFs again after changing a file or a check condition.".localizedUI)
                                    .foregroundStyle(PPColor.textSecondary)
                            }
                        }
                        ForEach(packet.detailsToCheck) { detail in
                            detailSection(detail, packet: packet)
                        }
                    }
                    if packet.requirements.count < 2 {
                        Text("Add at least two materials to the packet first.".localizedUI)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    Section {
                        Text("Checks compare labelled readable text. Missing text, multiple possible values and incomplete reading need review. This does not verify business meaning or document accuracy.".localizedUI)
                            .font(.footnote).foregroundStyle(PPColor.textSecondary)
                        Text("For scans, first create a searchable PDF copy. Large PDFs may need splitting before checking.".localizedUI)
                            .font(.footnote).foregroundStyle(PPColor.textSecondary)
                        Text("Check conditions and excerpts are not added to the exported checklist. Your selected PDFs are shared as chosen.".localizedUI)
                            .font(.footnote).foregroundStyle(PPColor.textSecondary)
                    }
                    if let error { Text(error).foregroundStyle(PPColor.amber).accessibilityIdentifier("keyDetailsError") }
                }
                .disabled(busy)
                .scrollContentBackground(.hidden).background(PPColor.canvas)
                .navigationTitle("Key details".localizedUI).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button(action: addDetail) { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Add a key detail".localizedUI).accessibilityIdentifier("keyDetailsAdd")
                        .disabled(busy || packet.requirements.count < 2 || packet.detailsToCheck.count >= 8)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button {
                        if busy { operation?.cancel() } else { runCheck() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text((busy ? "Stop checking" : "Check selected PDFs").localizedUI)
                                .font(.headline).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(packet.detailsToCheck.isEmpty)
                    .accessibilityIdentifier("keyDetailsRun")
                    .padding().background(PPColor.canvas)
                }
            } else {
                ContentUnavailableView("Packet unavailable".localizedUI, systemImage: "folder.badge.questionmark")
            }
        }
        .sheet(item: $editing) { original in
            if let packet {
                HandoffKeyDetailEditor(detail: original, requirements: packet.requirements) { edited in
                    try await saveDetail(edited, original: original)
                }
            }
        }
        .sheet(item: $preview) { target in
            NavigationStack {
                DocumentWorkspaceView(recordID: target.recordID, initialPageIndex: target.pageIndex,
                                      initialContentRevisionID: target.revisionID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done".localizedUI) { preview = nil } } }
            }
        }
        .sheet(item: $replacement) { request in
            HandoffDocumentPicker { id in replaceMaterial(request, with: id) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { operation?.cancel() } }
        .onDisappear { operation?.cancel() }
        .tint(PPColor.accent)
    }

    private func passed(_ packet: HandoffPacket) -> Bool {
        currentReport?.passes(for: packet, documents: model.handoffDocuments(for: packet)) == true
    }

    private func summary(_ packet: HandoffPacket) -> String {
        if passed(packet) { return "Selected key details match".localizedUI }
        if currentReport != nil { return "Some details need attention".localizedUI }
        return "Key details need checking".localizedUI
    }

    @ViewBuilder private func detailSection(_ detail: HandoffKeyDetail, packet: HandoffPacket) -> some View {
        Section {
            Text(AppLocalization.format("Expected: %@", detail.expectedText))
                .font(.subheadline).foregroundStyle(PPColor.textSecondary)
            if let report = currentReport {
                ForEach(detail.requirementIDs, id: \.self) { requirementID in
                    let item = packet.requirements.first { $0.id == requirementID }
                    if let result = report.results.first(where: { $0.detailID == detail.id && $0.requirementID == requirementID }) {
                        resultRow(result, materialName: item?.title ?? "Removed material".localizedUI)
                        if result.state != .matches, let item {
                            Button("Choose another PDF".localizedUI) {
                                replacement = KeyDetailReplacement(requirementID: requirementID, originalRecordID: item.recordID)
                            }.accessibilityIdentifier("keyDetailsReplace-\(requirementID.uuidString)")
                        }
                    }
                }
            } else {
                ForEach(detail.requirementIDs, id: \.self) { id in
                    Text(packet.requirements.first(where: { $0.id == id })?.title ?? "Removed material".localizedUI)
                        .foregroundStyle(PPColor.textSecondary)
                }
            }
        } header: {
            HStack {
                Text(detail.name).textCase(nil).font(.headline).foregroundStyle(PPColor.textPrimary)
                Spacer()
                Menu {
                    Button("Edit".localizedUI) { editing = detail }
                    Button("Remove check".localizedUI, role: .destructive) { removeDetail(detail.id) }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel(AppLocalization.format("Options for %@", detail.name))
            }
        }
    }

    @ViewBuilder private func resultRow(_ result: HandoffKeyDetailResult, materialName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(materialName).font(.headline)
            Label(result.state.title.localizedUI, systemImage: result.state == .matches ? "checkmark.circle" : "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(result.state == .matches ? PPColor.mint : PPColor.amber)
            ForEach(Array(result.evidence.enumerated()), id: \.offset) { index, evidence in
                Button {
                    if let id = result.recordID, let revision = result.revisionID {
                        preview = KeyDetailPreview(recordID: id, revisionID: revision, pageIndex: evidence.pageIndex)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(evidence.value.isEmpty ? "No unambiguous value".localizedUI : evidence.value)
                                .font(.body.weight(.medium)).foregroundStyle(PPColor.textPrimary)
                            Text(AppLocalization.format("Open page %lld", evidence.pageIndex + 1))
                                .font(.caption).foregroundStyle(PPColor.accent)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(PPColor.accent)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("keyDetailsEvidence-\(result.id)-\(index)")
            }
            if result.evidence.isEmpty, let id = result.recordID, let revision = result.revisionID {
                Button("Open PDF for review".localizedUI) {
                    preview = KeyDetailPreview(recordID: id, revisionID: revision, pageIndex: 0)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private func addDetail() {
        guard let packet else { return }
        var detail = HandoffKeyDetail()
        detail.requirementIDs = packet.requirements.map(\.id)
        editing = detail
    }

    private func saveDetail(_ detail: HandoffKeyDetail, original: HandoffKeyDetail) async throws {
        var workspace = model.handoffWorkspace
        guard let index = workspace.packets.firstIndex(where: { $0.id == packetID }), detail.isValid,
              Set(detail.requirementIDs).isSubset(of: Set(workspace.packets[index].requirements.map(\.id))) else {
            throw PaperPathError.insufficientSelection("Select at least two current materials for this check.")
        }
        var details = workspace.packets[index].detailsToCheck
        if let existing = details.firstIndex(where: { $0.id == original.id }) {
            guard details[existing] == original else {
                throw PaperPathError.storageFailure("The check condition changed in another window. Reopen it first.")
            }
            details[existing] = detail
        } else { details.append(detail) }
        if details != workspace.packets[index].detailsToCheck { workspace.packets[index].keyDetailReport = nil }
        workspace.packets[index].keyDetails = details
        try await model.saveHandoffWorkspace(workspace)
    }

    private func replaceMaterial(_ request: KeyDetailReplacement, with recordID: UUID) {
        busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            var workspace = model.handoffWorkspace
            guard let p = workspace.packets.firstIndex(where: { $0.id == packetID }),
                  let i = workspace.packets[p].requirements.firstIndex(where: { $0.id == request.requirementID }),
                  workspace.packets[p].requirements[i].recordID == request.originalRecordID else {
                error = "The material changed in another window. Review it again.".localizedUI; return
            }
            workspace.packets[p].requirements[i].assign(recordID)
            workspace.packets[p].keyDetailReport = nil
            do { try await model.saveHandoffWorkspace(workspace) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func runCheck() {
        busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do { try await model.checkHandoffKeyDetails(packetID: packetID) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func removeDetail(_ id: UUID) {
        busy = true; error = nil
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            var workspace = model.handoffWorkspace
            guard let index = workspace.packets.firstIndex(where: { $0.id == packetID }) else { return }
            workspace.packets[index].keyDetails = workspace.packets[index].detailsToCheck.filter { $0.id != id }
            workspace.packets[index].keyDetailReport = nil
            do { try await model.saveHandoffWorkspace(workspace) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct HandoffKeyDetailEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var detail: HandoffKeyDetail
    let requirements: [HandoffRequirement]
    let onSave: (HandoffKeyDetail) async throws -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Check name".localizedUI, text: $detail.name).accessibilityIdentifier("keyDetailName")
                    TextField("Label in PDF".localizedUI, text: $detail.label)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("keyDetailLabel")
                    TextField("Expected text".localizedUI, text: $detail.expectedText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("keyDetailExpected")
                } footer: {
                    Text("Use the field label as it appears in the PDF, for example Project ID. Expected text is compared as written, without inferring amounts, dates or meaning.".localizedUI)
                }
                Section {
                    ForEach(requirements) { item in
                        Button {
                            if detail.requirementIDs.contains(item.id) { detail.requirementIDs.removeAll { $0 == item.id } }
                            else { detail.requirementIDs.append(item.id) }
                        } label: {
                            HStack {
                                Text(item.title).foregroundStyle(PPColor.textPrimary).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Image(systemName: detail.requirementIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(PPColor.accent)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityValue((detail.requirementIDs.contains(item.id) ? "Selected" : "Not selected").localizedUI)
                    }
                } header: { Text("Materials to compare".localizedUI) }
                  footer: { Text("Select at least two materials.".localizedUI) }
                if let error { Text(error).foregroundStyle(PPColor.amber) }
            }
            .disabled(busy)
            .scrollContentBackground(.hidden).background(PPColor.canvas)
            .navigationTitle("Key detail".localizedUI).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel".localizedUI) { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".localizedUI) {
                        var saved = detail
                        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.label = saved.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.expectedText = saved.expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.requirementIDs = saved.requirementIDs.sorted { $0.uuidString < $1.uuidString }
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do { try await onSave(saved); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy || !detail.isValid).accessibilityIdentifier("keyDetailSave")
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear {
                let current = Set(requirements.map(\.id))
                detail.requirementIDs.removeAll { !current.contains($0) }
            }
        }.tint(PPColor.accent)
    }
}
