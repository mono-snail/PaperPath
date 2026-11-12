import SwiftUI

@MainActor
final class SupportInbox: ObservableObject {
    // Keep an unsaved conversation available after dismissing its composer.
    // Only Keychain persistence survives ending this app session.
    static let shared: SupportInbox = {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_WORKFLOW_FIXTURE"),
           arguments.contains("UITEST_SUPPORT_SAVE_FAILURE") {
            let inbox = SupportInbox(loadThreads: { [] }, saveThread: { _ in throw SupportFailure.storage })
            inbox.pending = SupportThread(id: "8C94C77A-37D1-4670-987D-C15D0E676A15",
                conversationToken: String(repeating: "a", count: 64),
                title: "Offline support fixture", createdAt: "2026-11-03T00:00:00Z")
            inbox.savePending()
            return inbox
        }
#endif
        return SupportInbox()
    }()

    @Published var threads: [SupportThread] = []
    @Published var pending: SupportThread?
    @Published var busy = false
    @Published var error: String?
    @Published var uncertain = false
    private let loadThreads: () throws -> [SupportThread]
    private let saveThread: (SupportThread) throws -> Void

    init(loadThreads: @escaping () throws -> [SupportThread] = { try SupportThreadStore().load() },
         saveThread: @escaping (SupportThread) throws -> Void = { try SupportThreadStore().save($0) }) {
        self.loadThreads = loadThreads
        self.saveThread = saveThread
    }
    // Keep drafts and ambiguous delivery state while navigating the inbox.
    // Feedback text stays in memory and is never written to preferences or iCloud.
    private var replySessions: [String: SupportReplySession] = [:]

    func replySession(for threadID: String) -> SupportReplySession {
        if let session = replySessions[threadID] { return session }
        let session = SupportReplySession()
        replySessions[threadID] = session
        return session
    }

    func load() {
        if pending != nil { savePending(); return }
        do { threads = try loadThreads(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func savePending() {
        guard let pending else { return }
        do {
            try saveThread(pending)
            threads = try loadThreads()
            self.pending = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func submit(email: String, title: String, description: String, type: String, deviceInfo: Bool) async {
        guard !busy, pending == nil, !uncertain else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            pending = try await SupportService.shared.create(email: email, title: title,
                description: description, type: type, includeDeviceInfo: deviceInfo)
            savePending()
        } catch {
            self.error = error.localizedDescription
            if let failure = error as? SupportFailure {
                uncertain = failure == .uncertain || failure == .invalidResponse
            }
        }
    }
}

struct SupportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var inbox = SupportInbox.shared
    @State private var composing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if inbox.pending == nil { inbox.error = nil; inbox.uncertain = false }
                        composing = true
                    } label: {
                        Label((inbox.pending == nil ? "New feedback" : "Save conversation again").localizedUI, systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("supportNewFeedback")
                }
                Section("Your conversations".localizedUI) {
                    if inbox.threads.isEmpty {
                        Text("No conversations on this device.".localizedUI)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(inbox.threads) { thread in
                        NavigationLink {
                            SupportConversationView(thread: thread, session: inbox.replySession(for: thread.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.title)
                                Text(String(thread.createdAt.prefix(10)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = inbox.error {
                    Section {
                        Text(error).foregroundStyle(PPColor.rose)
                        Button("Try again".localizedUI) { inbox.load() }
                    }
                }
                Section {
                    Link("Email support".localizedUI, destination: URL(string: "mailto:hello@monoware.app")!)
                    Link("Support website".localizedUI, destination: URL(string: "https://support.monoware.app/?product=paperpath")!)
                } footer: {
                    Text("Conversations are saved securely on this device. They do not sync through iCloud. Do not include private documents, passwords, or signatures.".localizedUI)
                }
            }
            .navigationTitle("Contact Support".localizedUI)
            .tint(PPColor.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done".localizedUI) { dismiss() }
                }
            }
            .task { inbox.load() }
            .sheet(isPresented: $composing) {
                SupportComposerView(inbox: inbox)
            }
        }
    }
}

// Settings opens the native composer directly; conversation history stays in SupportView.
struct SupportFeedbackView: View {
    @StateObject private var inbox = SupportInbox.shared

    var body: some View {
        SupportComposerView(inbox: inbox)
    }
}

private struct SupportComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Field: Hashable { case email, title, description }
    @FocusState private var focusedField: Field?
    @ObservedObject var inbox: SupportInbox
    @State private var email = ""
    @State private var title = ""
    @State private var description = ""
    @State private var type = "bug"
    @State private var deviceInfo = false
    @State private var confirmResend = false
    @State private var confirmDiscard = false
    @State private var confirmClosePending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Feedback type".localizedUI, selection: $type) {
                        Text("Problem".localizedUI).tag("bug")
                        Text("Feature request".localizedUI).tag("feature_request")
                        Text("Improvement".localizedUI).tag("improvement")
                        Text("Other".localizedUI).tag("other")
                    }
                    TextField("Email".localizedUI, text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .title }
                        .accessibilityIdentifier("supportEmail")
                    TextField("Title (3–160 characters)".localizedUI, text: $title, axis: .vertical)
                        .focused($focusedField, equals: .title)
                        .accessibilityIdentifier("supportTitle")
                    TextField("What happened? (10–5,000 characters)".localizedUI, text: $description, axis: .vertical)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1...8 : 3...10)
                        .focused($focusedField, equals: .description)
                        .accessibilityIdentifier("supportDescription")
                }
                .disabled(inbox.busy || inbox.pending != nil)
                Section {
                    Toggle("Include app and OS version".localizedUI, isOn: $deviceInfo)
                        .disabled(inbox.busy || inbox.pending != nil)
                } footer: {
                    Text("Your email and feedback are sent to Monoware Support. No PDF, document name, extracted text, or signature is attached automatically.".localizedUI)
                }
                if let error = inbox.error {
                    Section {
                        Text(error).foregroundStyle(PPColor.rose)
                            .accessibilityIdentifier("supportError")
                        if let pending = inbox.pending {
                            Text(pending.id).font(.caption).textSelection(.enabled)
                            Button("Save conversation again".localizedUI) {
                                inbox.savePending()
                                if inbox.pending == nil && inbox.error == nil { dismiss() }
                            }
                            .accessibilityIdentifier("supportSaveConversationAgain")
                        } else if inbox.uncertain {
                            Button("Send again…".localizedUI) { confirmResend = true }
                        }
                        Link("Email support".localizedUI, destination: URL(string: "mailto:hello@monoware.app")!)
                    }
                }
                Section {
                    Button {
                        Task {
                            await inbox.submit(email: email, title: title, description: description,
                                               type: type, deviceInfo: deviceInfo)
                            if inbox.error == nil && inbox.pending == nil { dismiss() }
                        }
                    } label: {
                        HStack {
                            Text("Send feedback".localizedUI)
                            Spacer()
                            if inbox.busy { ProgressView() }
                        }
                    }
                    .disabled(!SupportService.valid(email: email, title: title, description: description)
                              || inbox.busy || inbox.pending != nil || inbox.uncertain)
                    .accessibilityIdentifier("supportSubmit")
                }
            }
            .navigationTitle("New feedback".localizedUI)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done".localizedUI) { focusedField = nil }
                        .accessibilityIdentifier("supportDismissKeyboard")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button((inbox.pending == nil ? "Cancel" : "Close").localizedUI) {
                        if inbox.pending != nil { confirmClosePending = true }
                        else if email.isEmpty && title.isEmpty && description.isEmpty { dismiss() }
                        else { confirmDiscard = true }
                    }
                    .disabled(inbox.busy)
                    .accessibilityIdentifier("supportCancel")
                }
            }
            .interactiveDismissDisabled(inbox.busy || inbox.pending != nil || !email.isEmpty || !title.isEmpty || !description.isEmpty)
            .alert("Send again?".localizedUI, isPresented: $confirmResend) {
                Button("Cancel".localizedUI, role: .cancel) { }
                Button("Allow another attempt".localizedUI) { inbox.uncertain = false }
            } message: {
                Text("The first request may already have arrived. Another attempt can create a duplicate conversation.".localizedUI)
            }
            .alert("Close feedback?".localizedUI, isPresented: $confirmClosePending) {
                Button("Keep Open".localizedUI, role: .cancel) { }
                Button("Close".localizedUI) { dismiss() }
                    .accessibilityIdentifier("supportClosePending")
            } message: {
                Text("Your feedback was sent. Reopen Support to retry saving this conversation. If the app closes before it is saved, contact hello@monoware.app with the reference shown here.".localizedUI)
            }
            .alert("Discard feedback?".localizedUI, isPresented: $confirmDiscard) {
                Button("Keep editing".localizedUI, role: .cancel) { }
                Button("Discard".localizedUI, role: .destructive) { dismiss() }
            }
            .onChange(of: inbox.pending) { _, pending in
                if pending == nil && inbox.error == nil && !inbox.busy { dismiss() }
            }
        }
    }
}

@MainActor
final class SupportReplySession: ObservableObject {
    @Published var conversation: SupportConversation?
    @Published var reply = ""
    @Published var busy = false
    @Published var refreshing = false
    @Published var error: String?
    @Published var uncertainReply: String?
    var knownMessageIDs: Set<String> = []
    @Published var reconciled = false
}

private struct SupportConversationView: View {
    let thread: SupportThread
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var replyFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var session: SupportReplySession
    @State private var confirmResend = false

    var body: some View {
        List {
            Section {
                Text(thread.title).font(.headline)
                if let conversation = session.conversation {
                    Text(statusTitle(conversation.feedback.status).localizedUI)
                        .foregroundStyle(PPColor.accent)
                }
                Text(thread.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if session.refreshing { ProgressView() }
            }
            if let conversation = session.conversation {
                Section("Messages".localizedUI) {
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text((message.author == "user" ? "You" : "Support").localizedUI).font(.subheadline.bold())
                                Spacer()
                                Text(messageDate(message.createdAt)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(message.body).textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Reply".localizedUI) {
                    TextField("Write a reply".localizedUI, text: $session.reply, axis: .vertical)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 1...8 : 3...10)
                        .focused($replyFocused)
                        .disabled(session.busy || session.uncertainReply != nil)
                        .accessibilityIdentifier("supportReply")
                    Button("Send reply".localizedUI) { Task { await send() } }
                        .disabled(session.busy || session.refreshing || session.uncertainReply != nil
                            || !(1...5000).contains(session.reply.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count))
                        .accessibilityIdentifier("supportSendReply")
                    if session.busy { ProgressView() }
                }
            }
            if let error = session.error {
                Section {
                    Text(error).foregroundStyle(PPColor.rose)
                    if session.uncertainReply != nil {
                        Button("Review and allow another attempt…".localizedUI) { confirmResend = true }
                            .disabled(session.refreshing || !session.reconciled)
                    }
                }
            }
            Section {
                Button("Refresh".localizedUI) { Task { await refresh() } }
                    .disabled(session.busy || session.refreshing)
                Link("Email support".localizedUI, destination: URL(string: "mailto:hello@monoware.app")!)
            }
        }
        .navigationTitle("Conversation".localizedUI)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done".localizedUI) { replyFocused = false }
            }
        }
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .alert("Send again?".localizedUI, isPresented: $confirmResend) {
            Button("Cancel".localizedUI, role: .cancel) { }
            Button("Allow another attempt".localizedUI) { session.uncertainReply = nil }
        } message: {
            Text("Refresh and check the latest messages first. Sending again may create a duplicate reply.".localizedUI)
        }
    }

    private func refresh() async {
        guard !session.refreshing, !session.busy else { return }
        session.refreshing = true
        defer { session.refreshing = false }
        do {
            session.conversation = try await SupportService.shared.conversation(thread)
            if let pending = session.uncertainReply,
               session.conversation?.messages.contains(where: { $0.author == "user" && $0.body == pending && !session.knownMessageIDs.contains($0.id) }) == true {
                session.reply = ""
                session.uncertainReply = nil
            }
            session.reconciled = true
            session.error = session.uncertainReply == nil ? nil : SupportFailure.uncertain.localizedDescription
        } catch { session.error = error.localizedDescription }
    }

    private func send() async {
        guard !session.busy, !session.refreshing, session.uncertainReply == nil else { return }
        session.busy = true
        session.error = nil
        session.reconciled = false
        session.knownMessageIDs = Set(session.conversation?.messages.map(\.id) ?? [])
        do {
            try await SupportService.shared.reply(session.reply, to: thread)
            session.reply = ""
        } catch {
            session.error = error.localizedDescription
            if let failure = error as? SupportFailure, failure == .uncertain || failure == .invalidResponse {
                session.uncertainReply = session.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        session.busy = false
        if session.error == nil || session.uncertainReply != nil { await refresh() }
    }

    private func messageDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return String(value.prefix(10)) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "open": return "Received"
        case "reviewing": return "Under review"
        case "planned": return "Planned"
        case "resolved": return "Resolved"
        case "closed": return "Closed"
        default: return "Status unavailable"
        }
    }
}
