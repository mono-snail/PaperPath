import SwiftUI

private struct HandoffSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct HandoffWorkspaceView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var loaded = false
    @State private var error: String?
    @State private var busy = false
    @State private var editingRule: HandoffRule?
    @State private var editingPacket: HandoffPacket?

    var body: some View {
        NavigationStack {
            List {
                if tab == 0 { checkIntroduction }
                Picker("Check materials".localizedUI, selection: $tab) {
                    Text("Packets".localizedUI).tag(0)
                    Text("Rules".localizedUI).tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("handoffTabs")
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if tab == 0 {
                    packets
                } else {
                    rules
                }
            }
            .disabled(busy)
            .scrollContentBackground(.hidden)
            .background(PPColor.canvas)
            .navigationTitle("Check materials".localizedUI)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done".localizedUI) { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if tab == 1 || model.handoffWorkspace.rules.isEmpty {
                            editingRule = HandoffRule()
                        } else {
                            editingPacket = HandoffPacket(name: "", ruleID: model.handoffWorkspace.rules[0].id)
                        }
                    } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel((tab == 1 ? "New delivery rule" : "New packet").localizedUI)
                    .accessibilityIdentifier("handoffAdd")
                    .disabled(!loaded || busy || (tab == 1 ? model.handoffWorkspace.rules.count >= 30 : model.handoffWorkspace.packets.count >= 50))
                }
            }
            .sheet(item: $editingRule) { original in
                HandoffRuleEditor(rule: original) { edited in
                    var workspace = model.handoffWorkspace
                    if let index = workspace.rules.firstIndex(where: { $0.id == original.id }) {
                        guard workspace.rules[index] == original else { throw HandoffUIError.changed }
                        workspace.rules[index] = edited
                    } else { workspace.rules.append(edited) }
                    try await model.saveHandoffWorkspace(workspace)
                }
            }
            .sheet(item: $editingPacket) { original in
                HandoffPacketEditor(packet: original) { edited in
                    var workspace = model.handoffWorkspace
                    workspace.packets.append(edited)
                    try await model.saveHandoffWorkspace(workspace)
                }
            }
            .task {
                do { try await model.loadHandoffWorkspace(); loaded = true }
                catch { self.error = error.localizedDescription }
            }
            .alert("Handoff".localizedUI, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK".localizedUI) { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(busy)
        .tint(PPColor.accent)
    }

    @ViewBuilder private var packets: some View {
        if model.handoffWorkspace.packets.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Button("Try a reference mismatch".localizedUI, action: createSample)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("handoffSample")
                    Button((model.handoffWorkspace.rules.isEmpty ? "Create a rule" : "Create a packet").localizedUI) {
                        if let rule = model.handoffWorkspace.rules.first {
                            editingPacket = HandoffPacket(name: "", ruleID: rule.id)
                        } else { editingRule = HandoffRule() }
                    }.accessibilityIdentifier("handoffCreate")
                }.padding(.vertical, 12)
            }
        } else {
            Section {
                ForEach(model.handoffWorkspace.packets) { packet in
                    NavigationLink {
                        HandoffPacketView(packetID: packet.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(packet.name).font(.headline).fontDesign(.serif)
                            let rule = model.handoffWorkspace.rules.first { $0.id == packet.ruleID }
                            let confirmed = HandoffEvaluator.confirmedCount(packet: packet, rule: rule, documents: model.handoffDocuments(for: packet))
                            Text(AppLocalization.format("%lld of %lld materials confirmed", confirmed, packet.requirements.count))
                                .font(.subheadline).foregroundStyle(PPColor.textSecondary)
                        }.padding(.vertical, 6)
                    }.accessibilityIdentifier("handoffPacket-\(packet.id.uuidString)")
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { model.handoffWorkspace.packets[$0].id })
                    save { $0.packets.removeAll { ids.contains($0.id) } }
                }
            } footer: {
                Text("Your checklist defines completeness. PaperPath does not certify an institution's requirements.".localizedUI)
            }
        }
    }

    private var checkIntroduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Check references and names across your PDFs".localizedUI)
                    .font(.title2.weight(.semibold)).fontDesign(.serif)
                    .fixedSize(horizontal: false, vertical: true)
                if model.handoffWorkspace.packets.isEmpty {
                    Text("Example: application A102 · attachment A120".localizedUI)
                        .font(.body.weight(.medium)).foregroundStyle(PPColor.accent)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Use the same check conditions for your application, contract and attachments.".localizedUI)
                        .foregroundStyle(PPColor.textSecondary)
                }
            }.padding(.vertical, 6)
        }.listRowBackground(Color.clear)
    }

    @ViewBuilder private var rules: some View {
        Section {
            if model.handoffWorkspace.rules.isEmpty {
                Text("Save the checks and output requirements you use again.".localizedUI)
                    .foregroundStyle(PPColor.textSecondary)
                Button("Create a rule".localizedUI) { editingRule = HandoffRule() }
            }
            ForEach(model.handoffWorkspace.rules) { rule in
                Button { editingRule = rule } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rule.name).foregroundStyle(PPColor.textPrimary).font(.headline)
                            Text(rule.outputFormat.title.localizedUI).font(.subheadline).foregroundStyle(PPColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(PPColor.textSecondary)
                    }.padding(.vertical, 6)
                }
                .accessibilityIdentifier("handoffRule-\(rule.id.uuidString)")
                .swipeActions {
                    if !model.handoffWorkspace.packets.contains(where: { $0.ruleID == rule.id }) {
                        Button("Delete".localizedUI, role: .destructive) { save { $0.rules.removeAll { $0.id == rule.id } } }
                    }
                }
            }
        } footer: {
            Text("Changing a rule requires new file confirmations. Rules never delete sensitive content automatically.".localizedUI)
        }
    }

    private func save(_ mutation: (inout HandoffWorkspace) -> Void) {
        var next = model.handoffWorkspace
        mutation(&next)
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await model.saveHandoffWorkspace(next) }
            catch { self.error = error.localizedDescription; try? await model.loadHandoffWorkspace() }
        }
    }

    private func createSample() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let samples: (main: UUID, supporting: UUID, corrected: UUID)
            do { samples = try await model.createHandoffSampleDocuments() }
            catch { self.error = error.localizedDescription; return }
            var next = model.handoffWorkspace
            var rule = HandoffRule()
            rule.name = "Sample handoff rule".localizedUI
            rule.maximumMegabytes = 10
            next.rules.append(rule)
            var sample = HandoffPacket(
                name: "Sample client handoff".localizedUI, ruleID: rule.id,
                requirements: [HandoffRequirement(title: "Main document".localizedUI, recordID: samples.main),
                               HandoffRequirement(title: "Supporting document".localizedUI, recordID: samples.supporting)]
            )
            let scope = sample.requirements.map(\.id).sorted { $0.uuidString < $1.uuidString }
            sample.keyDetails = [
                HandoffKeyDetail(name: "Project reference".localizedUI, label: "Project ID", expectedText: "A102", requirementIDs: scope),
                HandoffKeyDetail(name: "Client name".localizedUI, label: "Client", expectedText: "Northstar Studio", requirementIDs: scope)
            ]
            next.packets.append(sample)
            do { try await model.saveHandoffWorkspace(next) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private enum HandoffUIError: LocalizedError {
    case changed
    var errorDescription: String? { "The handoff workspace changed. Reopen it and review the latest version.".localizedUI }
}

private struct HandoffRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: HandoffRule
    let onSave: (HandoffRule) async throws -> Void
    @State private var limitsSize = false
    @State private var size = "10"
    @State private var busy = false
    @State private var error: String?

    @State private var initialRule: HandoffRule?
    @State private var initialized = false

    private var candidate: HandoffRule {
        var result = rule
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.maximumMegabytes = limitsSize ? Int(size) : nil
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Rule name".localizedUI, text: $rule.name).accessibilityIdentifier("handoffRuleName")
                    TextField("Filename prefix (optional)".localizedUI, text: $rule.filenamePrefix)
                        .accessibilityIdentifier("handoffRulePrefix")
                }
                Section("Output".localizedUI) {
                    Picker("PDF format".localizedUI, selection: $rule.outputFormat) {
                        ForEach(HandoffOutputFormat.allCases, id: \.self) { Text($0.title.localizedUI).tag($0) }
                    }.accessibilityIdentifier("handoffRuleFormat")
                    if rule.outputFormat == .imageBased {
                        Text("Image-based copies remove searchable text, links and interactive fields. Review before sharing.".localizedUI)
                            .font(.footnote).foregroundStyle(PPColor.textSecondary)
                    }
                    Toggle("Require privacy review".localizedUI, isOn: $rule.requiresPrivacyReview)
                        .accessibilityIdentifier("handoffRulePrivacy")
                    Toggle("Require output receipt".localizedUI, isOn: $rule.requiresReceipt)
                        .accessibilityIdentifier("handoffRuleReceipt")
                    Toggle("Limit file size".localizedUI, isOn: $limitsSize)
                        .accessibilityIdentifier("handoffRuleSizeEnabled")
                    if limitsSize {
                        HStack {
                            Text("Maximum per PDF (MB)".localizedUI)
                            TextField("1–250", text: $size).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("handoffRuleSize")
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(PPColor.amber) } }
            }
            .scrollContentBackground(.hidden).background(PPColor.canvas)
            .navigationTitle("Delivery rule".localizedUI).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel".localizedUI) { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save rule".localizedUI) {
                        var saved = candidate
                        if saved != initialRule { saved.version = UUID() }
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do { try await onSave(saved); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(busy || !candidate.isValid || (limitsSize && Int(size) == nil))
                    .accessibilityIdentifier("handoffSaveRule")
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear {
                guard !initialized else { return }
                initialRule = rule
                limitsSize = rule.maximumMegabytes != nil
                size = String(rule.maximumMegabytes ?? 10)
                initialized = true
            }
        }.tint(PPColor.accent)
    }
}

private struct HandoffPacketEditor: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @State var packet: HandoffPacket
    let onSave: (HandoffPacket) async throws -> Void
    @State private var newRequirement = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Packet name".localizedUI, text: $packet.name).accessibilityIdentifier("handoffPacketName")
                    Picker("Delivery rule".localizedUI, selection: $packet.ruleID) {
                        ForEach(model.handoffWorkspace.rules) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("handoffPacketRule")
                }
                Section("Required materials".localizedUI) {
                    ForEach($packet.requirements) { $item in
                        TextField("Material name".localizedUI, text: $item.title)
                            .onChange(of: item.title) { _, _ in item.clearConfirmation() }
                    }.onDelete { packet.requirements.remove(atOffsets: $0) }
                    if packet.requirements.count < 30 {
                        TextField("Material name".localizedUI, text: $newRequirement)
                            .accessibilityIdentifier("handoffRequirementName")
                        Button("Add material".localizedUI) {
                            packet.requirements.append(HandoffRequirement(title: newRequirement.trimmingCharacters(in: .whitespacesAndNewlines)))
                            newRequirement = ""
                        }
                        .disabled(!HandoffText.isValid(newRequirement, limit: 100))
                        .accessibilityIdentifier("handoffAddRequirement")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(PPColor.amber) } }
            }
            .scrollContentBackground(.hidden).background(PPColor.canvas)
            .navigationTitle("Packet checklist".localizedUI).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel".localizedUI) { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".localizedUI) {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do { try await onSave(packet); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(busy || !packet.isValid || packet.requirements.isEmpty || !newRequirement.isEmpty
                              || !model.handoffWorkspace.rules.contains(where: { $0.id == packet.ruleID }))
                    .accessibilityIdentifier("handoffSavePacket")
                }
            }
            .interactiveDismissDisabled(busy)
        }.tint(PPColor.accent)
    }
}

private struct HandoffPacketView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.scenePhase) private var scenePhase
    let packetID: UUID
    @State private var editingPacket: HandoffPacket?
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var sharedFile: HandoffSharedFile?
    @State private var preparedURL: URL?

    private var packet: HandoffPacket? { model.handoffWorkspace.packets.first { $0.id == packetID } }
    private var rule: HandoffRule? { model.handoffWorkspace.rules.first { $0.id == packet?.ruleID } }
    private var assessments: [HandoffRequirementAssessment] {
        guard let packet else { return [] }
        return HandoffEvaluator.assess(packet: packet, rule: rule, documents: model.handoffDocuments(for: packet))
    }

    var body: some View {
        Group {
            if let packet {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppLocalization.format("%lld of %lld materials confirmed", HandoffEvaluator.confirmedCount(packet: packet, rule: rule, documents: model.handoffDocuments(for: packet)), packet.requirements.count))
                                .font(.title3.weight(.semibold)).foregroundStyle(PPColor.accent)
                            Text(rule?.name ?? "Choose a delivery rule".localizedUI)
                                .foregroundStyle(PPColor.textSecondary)
                        }.padding(.vertical, 8).accessibilityIdentifier("handoffPacketSummary")
                    }
                    Section {
                        NavigationLink {
                            HandoffKeyDetailsView(packetID: packetID)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("Check key details".localizedUI, systemImage: "doc.text.magnifyingglass")
                                    .font(.headline).foregroundStyle(PPColor.accent)
                                Text(keyDetailStatus(packet)).font(.subheadline).foregroundStyle(PPColor.textSecondary)
                            }.padding(.vertical, 5)
                        }.accessibilityIdentifier("handoffKeyDetails")
                    }
                    Section("Required materials".localizedUI) {
                        ForEach(Array(packet.requirements.enumerated()), id: \.element.id) { index, item in
                            NavigationLink {
                                HandoffMaterialView(packetID: packetID, requirementID: item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.headline)
                                    if let recordID = item.recordID, let record = model.record(id: recordID) {
                                        Text(record.displayName).font(.subheadline).foregroundStyle(PPColor.textSecondary)
                                    }
                                    let result = assessments.first { $0.requirementID == item.id }
                                    Label((result?.issues.first?.title ?? "Confirmed").localizedUI,
                                          systemImage: result?.isReady == true ? "checkmark.circle" : "circle")
                                        .font(.caption).foregroundStyle(result?.isReady == true ? PPColor.mint : PPColor.textSecondary)
                                }.padding(.vertical, 5)
                            }.accessibilityIdentifier("handoffMaterial-\(index)")
                        }
                    }
                    Section {
                        Button {
                            export()
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Label((busy ? "Preparing packet" : "Export packet + checklist").localizedUI, systemImage: "square.and.arrow.up")
                            }.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(busy || !HandoffEvaluator.isReady(packet: packet, assessments: assessments))
                        .accessibilityIdentifier("handoffExport")
                    } footer: {
                        Text("The ZIP includes the selected PDFs, available output receipts, and a checklist with file fingerprints. Sharing sends these files to the service you choose.".localizedUI)
                    }
                    if let error { Section { Text(error).foregroundStyle(PPColor.amber).accessibilityIdentifier("handoffError") } }
                }
                .disabled(busy)
                .scrollContentBackground(.hidden).background(PPColor.canvas)
                .navigationTitle(packet.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Edit".localizedUI) { editingPacket = packet }
                        .disabled(busy).accessibilityIdentifier("handoffEditPacket")
                }
            } else {
                ContentUnavailableView("Packet unavailable".localizedUI, systemImage: "folder.badge.questionmark")
            }
        }
        .sheet(item: $editingPacket) { original in
            HandoffPacketEditor(packet: original) { edited in
                var workspace = model.handoffWorkspace
                guard let index = workspace.packets.firstIndex(where: { $0.id == original.id }), workspace.packets[index] == original else { throw HandoffUIError.changed }
                workspace.packets[index] = edited
                try await model.saveHandoffWorkspace(workspace)
            }
        }
        .sheet(item: $sharedFile, onDismiss: cleanupShare) { ShareSheet(items: [$0.url], removesTemporaryItemsOnCompletion: false) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { task?.cancel() } }
        .onDisappear { task?.cancel(); cleanupShare() }
    }

    private func export() {
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                let url = try await model.makeHandoffPacketExport(packetID: packetID)
                guard !Task.isCancelled else { await model.discardFilesExportCopy(at: url); return }
                preparedURL = url
                sharedFile = HandoffSharedFile(url: url)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func keyDetailStatus(_ packet: HandoffPacket) -> String {
        if packet.detailsToCheck.isEmpty { return "Choose details that must agree across these PDFs".localizedUI }
        if packet.keyDetailReport?.passes(for: packet, documents: model.handoffDocuments(for: packet)) == true {
            return "Selected key details match".localizedUI
        }
        if let report = packet.keyDetailReport, report.isCurrent(for: packet, documents: model.handoffDocuments(for: packet)) {
            return "Some details need attention".localizedUI
        }
        return "Key details need checking".localizedUI
    }

    private func cleanupShare() {
        guard let url = preparedURL else { return }
        preparedURL = nil
        sharedFile = nil
        Task { await model.discardFilesExportCopy(at: url) }
    }
}

private struct HandoffMaterialView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.scenePhase) private var scenePhase
    let packetID: UUID
    let requirementID: UUID
    @State private var showsPicker = false
    @State private var openedRecord: DocumentRecord?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var packet: HandoffPacket? { model.handoffWorkspace.packets.first { $0.id == packetID } }
    private var item: HandoffRequirement? { packet?.requirements.first { $0.id == requirementID } }
    private var rule: HandoffRule? { model.handoffWorkspace.rules.first { $0.id == packet?.ruleID } }
    private var record: DocumentRecord? { item?.recordID.flatMap { model.record(id: $0) } }
    private var assessment: HandoffRequirementAssessment? {
        guard let packet else { return nil }
        return HandoffEvaluator.assess(packet: packet, rule: rule, documents: model.handoffDocuments(for: packet)).first { $0.requirementID == requirementID }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showsPicker = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record?.displayName ?? "Choose a PDF".localizedUI).font(.headline)
                            if let record { Text(record.profile.formattedSize).font(.caption).foregroundStyle(PPColor.textSecondary) }
                        }
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }.padding(.vertical, 6)
                }.accessibilityIdentifier("handoffChoosePDF")
                    .accessibilityValue(record?.id.uuidString ?? "")
                if let record {
                    Button("Open and review PDF".localizedUI) { openedRecord = record }
                        .accessibilityIdentifier("handoffReviewPDF")
                    if rule?.requiresPrivacyReview == true {
                        Button {
                            let reviewed = item?.privacyReviewedRevisionID == record.contentRevisionID
                            update { $0.privacyReviewedRevisionID = reviewed ? nil : record.contentRevisionID; $0.clearConfirmation() }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: item?.privacyReviewedRevisionID == record.contentRevisionID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(PPColor.accent)
                                Text("I reviewed private details in this version".localizedUI)
                                    .foregroundStyle(PPColor.textPrimary).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("handoffPrivacyConfirmed")
                            .accessibilityValue((item?.privacyReviewedRevisionID == record.contentRevisionID ? "Reviewed" : "Not reviewed").localizedUI)
                    }
                }
            } footer: {
                if rule?.requiresPrivacyReview == true {
                    Text("Open the PDF to review it and use Privacy Scan if needed. Automatic detection can miss information. Confirm only after reviewing the document yourself.".localizedUI)
                }
            }
            if let record, rule?.outputFormat == .imageBased || rule?.requiresReceipt == true {
                Section {
                    Button("Create checked image-based copy".localizedUI) { createCopy(record) }
                        .accessibilityIdentifier("handoffCreateOutput")
                } footer: {
                    Text("Creates a separate copy and removes searchable text, links, interactive fields and editable layers. Then review and confirm the new copy.".localizedUI)
                }
            }
            if let assessment {
                Section("File checks".localizedUI) {
                    if assessment.isReady {
                        Label("Confirmed".localizedUI, systemImage: "checkmark.circle.fill").foregroundStyle(PPColor.mint)
                    } else {
                        if let record, item?.confirmedRevisionID == record.contentRevisionID,
                           item?.confirmedRuleVersion == rule?.version, item?.confirmedAt != nil {
                            Label("File version confirmed".localizedUI, systemImage: "checkmark.circle")
                                .foregroundStyle(PPColor.mint)
                        }
                        ForEach(assessment.issues, id: \.self) { issue in
                            Label(issue.title.localizedUI, systemImage: "circle").foregroundStyle(PPColor.textSecondary)
                        }
                    }
                    if let record, let receipt = record.deliveryReceipt, record.hasCurrentDeliveryReceipt {
                        NavigationLink("View output receipt".localizedUI) {
                            DeliveryReceiptView(recordID: record.id, receiptOverride: receipt, onOpenRoute: { route in
                                openedRecord = model.record(id: route.recordID)
                            })
                        }.accessibilityIdentifier("handoffViewReceipt")
                    }
                }
            }
            Section {
                Button("Confirm for packet".localizedUI) {
                    guard let record, let rule else { return }
                    update { $0.confirm(document: record.handoffSnapshot, rule: rule) }
                }
                .disabled(assessment?.canConfirm != true || record == nil || assessment?.isReady == true)
                .accessibilityIdentifier("handoffConfirmMaterial")
                if item?.confirmedAt != nil {
                    Button("Clear confirmation".localizedUI) { update { $0.clearConfirmation() } }
                }
            }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(error).foregroundStyle(PPColor.amber).accessibilityIdentifier("handoffError") }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden).background(PPColor.canvas)
        .navigationTitle(item?.title ?? "Material".localizedUI).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPicker) {
            HandoffDocumentPicker { id in update { $0.assign(id) } }
        }
        .sheet(item: $openedRecord) { selected in
            NavigationStack {
                DocumentWorkspaceView(
                    recordID: selected.id,
                    initialContentRevisionID: selected.contentRevisionID,
                    onOpenDocument: { route in openedRecord = model.record(id: route.recordID) }
                )
                .id(selected.id)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done".localizedUI) { openedRecord = nil } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Use this PDF".localizedUI) {
                            if item?.recordID != selected.id { update { $0.assign(selected.id) } }
                            openedRecord = nil
                        }.accessibilityIdentifier("handoffUseReviewedPDF")
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { task?.cancel() } }
        .onDisappear { task?.cancel() }
    }

    private func update(_ change: (inout HandoffRequirement) -> Void) {
        var workspace = model.handoffWorkspace
        guard let packetIndex = workspace.packets.firstIndex(where: { $0.id == packetID }),
              let itemIndex = workspace.packets[packetIndex].requirements.firstIndex(where: { $0.id == requirementID }) else { return }
        change(&workspace.packets[packetIndex].requirements[itemIndex])
        busy = true; error = nil
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do { try await model.saveHandoffWorkspace(workspace) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription; try? await model.loadHandoffWorkspace() }
        }
    }

    private func createCopy(_ source: DocumentRecord) {
        busy = true; error = nil
        task = Task { @MainActor in
            let created = await model.createSafeShareCopy(recordID: source.id, expectedContentRevisionID: source.contentRevisionID)
            busy = false; task = nil
            if let created, !Task.isCancelled {
                update { $0.assign(created.id) }
            } else if !Task.isCancelled {
                error = "The output could not be created. The selected file has not changed.".localizedUI
            }
        }
    }
}

struct HandoffDocumentPicker: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onSelect: (UUID) -> Void

    private var documents: [DocumentRecord] {
        model.documents.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(documents.enumerated()), id: \.element.id) { index, record in
                    Button { onSelect(record.id); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.displayName).foregroundStyle(PPColor.textPrimary)
                            Text(record.profile.formattedSize).font(.caption).foregroundStyle(PPColor.textSecondary)
                        }.padding(.vertical, 5)
                    }.accessibilityIdentifier("handoffPickPDF-\(index)")
                        .accessibilityValue(record.id.uuidString)
                }
                if documents.isEmpty {
                    Text("No matching PDFs. Import a PDF from the document library first.".localizedUI).foregroundStyle(PPColor.textSecondary)
                }
            }
            .scrollContentBackground(.hidden).background(PPColor.canvas)
            .searchable(text: $query, prompt: "Search PDFs".localizedUI)
            .navigationTitle("Choose a PDF".localizedUI).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel".localizedUI) { dismiss() } } }
        }
    }
}
