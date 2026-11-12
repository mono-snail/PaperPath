import SwiftUI
import UIKit
import UserNotifications

struct FirstRunExperienceView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let hasExistingDocuments: Bool
    let onImport: () -> Void
    let onSample: () async -> Bool
    let onComplete: () -> Void

    @State private var isCreatingSample = false
    @State private var sampleError: String?
    @State private var sampleTask: Task<Void, Never>?
    @State private var sampleGeneration = UUID()
    @State private var sampleErrorFeedback = 0

    var body: some View {
        ZStack {
            PPCanvas()
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.large) {
                        introductionHeader
                        Spacer(minLength: 0)
                        introduction
                        capabilities
                        Label("Your original stays unchanged.".localizedUI,
                              systemImage: "doc.on.doc")
                            .font(.subheadline)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        actions
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 520)
                    .padding(PPSpacing.large)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .clipped()
        }
        .interactiveDismissDisabled()
        .sensoryFeedback(.error, trigger: sampleErrorFeedback)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptSampleCreation()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptSampleCreation()
        }
        .onDisappear { interruptSampleCreation() }
    }

    private var introductionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                brandName
                Spacer(minLength: PPSpacing.small)
                OnDeviceBadge(compact: true)
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                brandName
                OnDeviceBadge(compact: true)
            }
        }
    }

    private var brandName: some View {
        Text(AppBrand.name)
            .font(.headline)
            .fontDesign(.serif)
            .foregroundStyle(PPColor.textPrimary)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            if !dynamicTypeSize.ppPrefersExpandedLayout {
                PPIllustration(kind: .workspace, width: 128)
                    .frame(maxWidth: .infinity)
                    .frame(height: 112)
                    .accessibilityHidden(true)
            }
            Text("Your PDF. Ready to work.".localizedUI)
                .font(dynamicTypeSize.ppPrefersExpandedLayout ? .title2.bold() : .title.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Fill, sign, and share a private working copy.".localizedUI)
                .font(.body)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var capabilities: some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(alignment: .top, spacing: PPSpacing.medium))
        return layout {
            capability("Fill & sign", symbol: "signature")
            capability("Organize pages", symbol: "square.grid.2x2")
            capability("Check & share", symbol: "checkmark.shield")
        }
        .padding(.vertical, PPSpacing.small)
    }

    private func capability(_ title: String, symbol: String) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(HStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.small))
        return layout {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(PPColor.accent)
                .accessibilityHidden(true)
            Text(title.localizedUI)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PPColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: PPSpacing.small) {
            Button(action: onImport) {
                Label("Open a PDF".localizedUI, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(isCreatingSample)
            .accessibilityIdentifier("onboardingImportPDF")

            Button {
                if sampleTask != nil { interruptSampleCreation() }
                else { createSample() }
            } label: {
                Label(sampleActionTitle.localizedUI,
                      systemImage: isCreatingSample ? "stop.fill" : "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
            .accessibilityIdentifier("samplePDFAction")
            .accessibilityHint((isCreatingSample
                ? "Stops before the sample is added"
                : hasExistingDocuments
                    ? "Opens an existing private working copy"
                    : "Creates a local sample PDF").localizedUI)

            Button("Go to documents".localizedUI, action: onComplete)
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(isCreatingSample)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("onboardingOpenLibrary")

            if let sampleError {
                Label(sampleError.localizedUI, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(PPColor.rose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sampleActionTitle: String {
        if isCreatingSample { return "Stop Creating Sample" }
        if sampleError != nil { return "Try Sample Again" }
        return hasExistingDocuments ? "Continue with existing PDF" : "Try a Sample PDF"
    }

    private func createSample() {
        guard sampleTask == nil else { return }
        let generation = UUID()
        sampleGeneration = generation
        sampleError = nil
        isCreatingSample = true
        sampleTask = Task { @MainActor in
            let created = await onSample()
            guard sampleGeneration == generation else { return }
            sampleTask = nil
            isCreatingSample = false
            guard !Task.isCancelled else { return }
            if !created {
                sampleError = "The sample PDF could not be created. Try again or go to Home."
                sampleErrorFeedback += 1
            }
        }
    }

    private func interruptSampleCreation() {
        sampleGeneration = UUID()
        sampleTask?.cancel()
        sampleTask = nil
        isCreatingSample = false
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var appLock: AppLockController
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(AppLanguage.defaultsKey)
    private var languageCode = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.metadataSyncEnabledKey)
    private var metadataSyncEnabled = false
    @AppStorage(AppPreferences.dueRemindersEnabledKey)
    private var dueRemindersEnabled = false
    @AppStorage(AppPreferences.previewQualityKey)
    private var previewQuality =
        ThumbnailPreviewQuality.automatic.rawValue
    @AppStorage(AppPreferences.onboardingReplayRequestedKey)
    private var onboardingReplayRequested = false

    @State private var isShowingPrivacy = false
    @State private var isShowingWhatsNew = false
    @State private var isShowingPrivacyInformation = false
    @State private var isShowingSupport = false
    @State private var isShowingFeedback = false
    @State private var isShowingDiagnostics = false
    @State private var diagnosticsURL: URL?
    @State private var resetConfirmation = ""
    @State private var isConfirmingReset = false
    @State private var isConfirmingMetadataDeletion = false
    @State private var isResetting = false
    @State private var resetTask: Task<Void, Never>?
    @State private var metadataTask: Task<Void, Never>?
    @State private var metadataGeneration = UUID()
    @State private var isDeletingSyncedMetadata = false
    @State private var isUpdatingReminders = false
    @State private var reminderUpdateTask: Task<Void, Never>?
    @State private var reminderUpdateGeneration = UUID()
    @State private var pendingReminderPreference: Bool?
    @State private var appLockPreferenceTask: Task<Void, Never>?
    @State private var appLockPreferenceGeneration = UUID()
    @State private var shouldLockAfterPrivacyDismissal = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        feedbackEntry
                        languageSection
                        privacySection
                        performanceSection
                        remindersSection
                        supportSection
                        dataSection
                        Text("PaperPath PDF · \(AppPreferences.versionDescription)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("settingsAppVersion")
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(hasBlockingSettingsOperation)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let blockingOperationStatus {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(blockingOperationStatus.localizedUI)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Spacer(minLength: 0)
                        OnDeviceBadge(compact: true)
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .frame(minHeight: 44)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .interactiveDismissDisabled(hasBlockingSettingsOperation)
        .accessibilityAction(.escape) {
            guard !hasBlockingSettingsOperation else { return }
            dismiss()
        }
        .sheet(
            isPresented: $isShowingPrivacy,
            onDismiss: completePrivacyCenterDismissal
        ) {
            PrivacyCenterView {
                shouldLockAfterPrivacyDismissal = true
                isShowingPrivacy = false
            }
        }
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewView()
        }
        .sheet(isPresented: $isShowingFeedback) {
            SupportFeedbackView()
        }
        .sheet(isPresented: $isShowingSupport) {
            SupportView()
        }
        .sheet(isPresented: $isShowingPrivacyInformation) {
            PrivacyInformationView()
        }
        .sheet(
            isPresented: $isShowingDiagnostics,
            onDismiss: discardDiagnostics
        ) {
            if let diagnosticsURL {
                ShareSheet(items: [diagnosticsURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .alert(
            "Delete all local PaperPath data?",
            isPresented: $isConfirmingReset
        ) {
            TextField("Type DELETE", text: $resetConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Delete Local Data", role: .destructive) {
                guard resetConfirmation == "DELETE" else { return }
                eraseAllLocalData()
            }
            .disabled(
                resetConfirmation != "DELETE"
                    || hasBlockingSettingsOperation
                    || metadataTask != nil
                    || model.hasActiveLocalDataOperations
            )
            Button("Cancel", role: .cancel) {
                resetConfirmation = ""
            }
        } message: {
            Text(
                "Deletes all PaperPath copies and data. Originals in Files stay unchanged."
            )
        }
        .alert(
            "Delete synced metadata from iCloud?",
            isPresented: $isConfirmingMetadataDeletion
        ) {
            Button("Delete Synced Metadata", role: .destructive) {
                deleteSyncedMetadata()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Turns off sync and deletes iCloud metadata. Local files stay unchanged."
            )
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptDiagnosticsShare()
            clearSensitiveConfirmations()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptDiagnosticsShare()
            clearSensitiveConfirmations()
        }
        .onDisappear {
            appLock.cancelPendingAuthentication()
            interruptDiagnosticsShare()
            clearSensitiveConfirmations()
            interruptTransientSettingsWork()
        }
    }

    private func completePrivacyCenterDismissal() {
        guard shouldLockAfterPrivacyDismissal else { return }
        shouldLockAfterPrivacyDismissal = false
        appLock.lockNow()
    }

    private var languageSection: some View {
        settingsSection(
            title: "APP LANGUAGE",
            symbol: "globe",
            tint: PPColor.cyan
        ) {
            settingsControl(tint: PPColor.cyan) {
                Picker(
                    selection: $languageCode
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language.rawValue)
                    }
                } label: {
                    settingsRow(
                        symbol: "character.book.closed",
                        tint: PPColor.cyan,
                        title: "App Language",
                        detail: selectedLanguageTitle
                    )
                }
                .pickerStyle(.menu)
                .tint(PPColor.cyan)
            }
        }
    }

    private var privacySection: some View {
        settingsSection(
            title: "PRIVACY & SECURITY",
            symbol: "lock.shield",
            tint: PPColor.mint
        ) {
            settingsControl(tint: PPColor.cyan) {
                Toggle(isOn: metadataSyncBinding) {
                    settingsRow(
                        symbol: metadataSyncEnabled
                            ? "checkmark.icloud"
                            : "icloud.slash",
                        tint: metadataSyncEnabled
                            ? PPColor.cyan
                            : PPColor.textSecondary,
                        title: "iCloud Metadata",
                        detail: metadataSyncEnabled
                            ? model.metadataSyncStatus.detail
                            : "Off · PDF files and extracted text stay local"
                    )
                }
                .disabled(isDeletingSyncedMetadata || isResetting)
            }

            if metadataSyncEnabled {
                settingsControl(tint: PPColor.cyan) {
                    Button {
                        synchronizeMetadataNow()
                    } label: {
                        settingsActionLabel(
                            "Sync Metadata Now",
                            symbol: "arrow.triangle.2.circlepath",
                            tint: PPColor.cyan
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        model.metadataSyncStatus.state == .syncing
                            || metadataTask != nil
                            || isResetting
                    )
                }

                settingsControl(tint: PPColor.rose) {
                    Button(role: .destructive) {
                        isConfirmingMetadataDeletion = true
                    } label: {
                        settingsActionLabel(
                            "Delete Synced Metadata",
                            detail: "Keep local PDFs and Files originals",
                            symbol: "icloud.slash",
                            tint: PPColor.rose
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        metadataTask != nil
                            || isResetting
                    )
                }
            }

            settingsControl(tint: PPColor.mint) {
                Toggle(
                    isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { enabled in
                            updateAppLockPreference(enabled)
                        }
                    )
                ) {
                    settingsRow(
                        symbol: appLock.symbol,
                        tint: appLock.isEnabled
                            ? PPColor.mint
                            : PPColor.textSecondary,
                        title: "App Lock",
                        detail: appLock.isAuthenticating
                            ? "Authenticating"
                            : appLock.isEnabled
                                ? appLock.methodTitle
                                : nil
                    )
                }
                .disabled(
                    appLock.isAuthenticating
                        || appLockPreferenceTask != nil
                        || (!appLock.isAvailable && !appLock.isEnabled)
                )
            }

            if let errorMessage = appLock.errorMessage {
                Label(
                    errorMessage,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
                .padding(.horizontal, PPSpacing.small)
            }

            if appLock.isEnabled {
                settingsControl(tint: PPColor.mint) {
                    Picker(
                        selection: Binding(
                            get: { appLock.delay },
                            set: { appLock.setDelay($0) }
                        )
                    ) {
                        ForEach(AppLockDelay.allCases) { delay in
                            Text(delay.title.localizedUI)
                                .tag(delay)
                        }
                    } label: {
                        settingsRow(
                            symbol: "timer",
                            tint: PPColor.mint,
                            title: "Require Again",
                            detail: appLock.delay.title
                        )
                    }
                    .pickerStyle(.menu)
                    .tint(PPColor.mint)
                }
            }

            settingsControl(tint: PPColor.mint) {
                Button {
                    isShowingPrivacy = true
                } label: {
                    settingsActionLabel(
                        "Privacy Center",
                        symbol: "lock.shield",
                        tint: PPColor.mint,
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var performanceSection: some View {
        settingsSection(
            title: "PDF PREVIEWS",
            symbol: "gauge.with.dots.needle.50percent",
            tint: PPColor.amber
        ) {
            settingsControl(tint: PPColor.amber) {
                Picker(selection: $previewQuality) {
                    ForEach(ThumbnailPreviewQuality.allCases) { quality in
                        Text(quality.title.localizedUI)
                            .tag(quality.rawValue)
                    }
                } label: {
                    settingsRow(
                        symbol: "photo.on.rectangle",
                        tint: PPColor.amber,
                        title: "PDF Previews",
                        detail: selectedPreviewQualityTitle
                    )
                }
                .pickerStyle(.menu)
                .tint(PPColor.amber)
            }
        }
    }

    private var remindersSection: some View {
        let displayedRemindersEnabled =
            pendingReminderPreference ?? dueRemindersEnabled
        return settingsSection(
            symbol: "calendar.badge.clock",
            tint: PPColor.amber
        ) {
            settingsControl(tint: PPColor.amber) {
                Toggle(isOn: remindersBinding) {
                    settingsRow(
                        symbol: displayedRemindersEnabled
                            ? "calendar.badge.clock"
                            : "bell.slash",
                        tint: displayedRemindersEnabled
                            ? PPColor.amber
                            : PPColor.textSecondary,
                        title: "Due-Date Reminders",
                        detail: isUpdatingReminders
                            ? "Updating scheduled reminders"
                            : nil
                    )
                }
                .disabled(isUpdatingReminders || isResetting)
            }
        }
    }

    private var feedbackEntry: some View {
        settingsControl(tint: PPColor.accent) {
            Button {
                isShowingFeedback = true
            } label: {
                settingsActionLabel(
                    "Feedback",
                    symbol: "square.and.pencil",
                    tint: PPColor.accent,
                    disclosure: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settingsFeedback")
        }
    }

    private var supportSection: some View {
        settingsSection(
            title: "HELP & ABOUT",
            symbol: "questionmark.circle",
            tint: PPColor.cyan
        ) {
            settingsControl(tint: PPColor.cyan) {
                Button {
                    isShowingSupport = true
                } label: {
                    settingsActionLabel(
                        "Contact Support",
                        symbol: "bubble.left.and.bubble.right",
                        tint: PPColor.cyan,
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsSupport")
            }
            settingsControl(tint: PPColor.mint) {
                Button {
                    isShowingPrivacyInformation = true
                } label: {
                    settingsActionLabel(
                        "Privacy & Data",
                        symbol: "hand.raised",
                        tint: PPColor.mint,
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsPrivacyInformation")
            }

            settingsControl(tint: PPColor.cyan) {
                Button {
                    createDiagnostics()
                } label: {
                    settingsActionLabel(
                        "Share Private Diagnostics",
                        detail: "Diagnostics exclude document content and names",
                        symbol: "wrench.and.screwdriver",
                        tint: PPColor.cyan,
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
            }

            settingsControl(tint: PPColor.accent) {
                Button {
                    isShowingWhatsNew = true
                } label: {
                    settingsActionLabel(
                        "What’s New",
                        symbol: "newspaper",
                        tint: PPColor.accent,
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
            }

            settingsControl(tint: PPColor.rose) {
                Button {
                    onboardingReplayRequested = true
                    dismiss()
                } label: {
                    settingsActionLabel(
                        "Replay Introduction",
                        symbol: "rectangle.stack",
                        tint: PPColor.rose
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsReplayIntroduction")
            }
        }
    }

    private var dataSection: some View {
        settingsSection(
            title: "STORAGE & DATA",
            symbol: "internaldrive",
            tint: PPColor.rose
        ) {
            settingsControl(tint: PPColor.accent) {
                settingsValueRow(
                    "Working Copies",
                    value: "\(model.documents.count)",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                )
            }

            settingsControl(tint: PPColor.amber) {
                settingsValueRow(
                    "Local PDF Storage",
                    value: localStorageSize,
                    symbol: "internaldrive",
                    tint: PPColor.amber
                )
            }

            settingsControl(tint: PPColor.rose) {
                Button(role: .destructive) {
                    resetConfirmation = ""
                    isConfirmingReset = true
                } label: {
                    HStack {
                        settingsActionLabel(
                            "Delete All Local Data",
                            detail: model.hasActiveLocalDataOperations
                                ? "Finish active document work first"
                                : "Permanent removal from PaperPath",
                            symbol: "trash",
                            tint: PPColor.rose
                        )
                        if isResetting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    hasBlockingSettingsOperation
                        || metadataTask != nil
                        || model.hasActiveLocalDataOperations
                )
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String? = nil,
        detail: String? = nil,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                StudioSectionRule(
                    title: title,
                    detail: detail,
                    symbol: symbol,
                    tint: tint
                )
                .padding(.bottom, PPSpacing.small)
            }
            content()
        }
    }

    private func settingsControl<Content: View>(
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 50)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(tint.opacity(0.68))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.52))
                    .frame(height: 0.6)
            }
    }

    private func settingsActionLabel(
        _ title: String,
        detail: String? = nil,
        symbol: String,
        tint: Color,
        disclosure: Bool = false
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    HStack(spacing: PPSpacing.small) {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint)
                            .frame(width: 28)
                        Text(title.localizedUI)
                            .foregroundStyle(PPColor.textPrimary)
                        Spacer(minLength: PPSpacing.small)
                        if disclosure {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                    if let detail {
                        Text(detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 36)
                    }
                }
                .padding(.vertical, PPSpacing.xSmall)
            } else {
                HStack(spacing: PPSpacing.medium) {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.localizedUI)
                            .foregroundStyle(PPColor.textPrimary)
                        if let detail {
                            Text(detail.localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                    Spacer(minLength: PPSpacing.small)
                    if disclosure {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func settingsValueRow(
        _ title: String,
        value: String,
        symbol: String,
        tint: Color
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    Label {
                        Text(title.localizedUI)
                            .foregroundStyle(PPColor.textPrimary)
                    } icon: {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                            .frame(width: 28)
                    }
                    Text(value.localizedUI)
                        .font(
                            .subheadline.monospacedDigit()
                                .weight(.semibold)
                        )
                        .foregroundStyle(PPColor.textSecondary)
                        .padding(.leading, 36)
                }
                .padding(.vertical, PPSpacing.xSmall)
            } else {
                HStack(spacing: PPSpacing.medium) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    Text(title.localizedUI)
                        .foregroundStyle(PPColor.textPrimary)
                    Spacer(minLength: PPSpacing.small)
                    Text(value.localizedUI)
                        .font(
                            .subheadline.monospacedDigit()
                                .weight(.semibold)
                        )
                        .foregroundStyle(PPColor.textSecondary)
                }
            }
        }
    }

    private var selectedLanguageTitle: String {
        AppLanguage(rawValue: languageCode)?.title
            ?? AppLanguage.system.title
    }

    private var selectedPreviewQualityTitle: String {
        (
            ThumbnailPreviewQuality(rawValue: previewQuality)
                ?? .automatic
        ).title.localizedUI
    }

    private var metadataSyncBinding: Binding<Bool> {
        Binding(
            get: { metadataSyncEnabled },
            set: { enabled in
                updateMetadataSyncPreference(enabled)
            }
        )
    }

    private var remindersBinding: Binding<Bool> {
        Binding(
            get: {
                pendingReminderPreference
                    ?? dueRemindersEnabled
            },
            set: { enabled in
                guard reminderUpdateTask == nil else { return }
                let generation = UUID()
                reminderUpdateGeneration = generation
                pendingReminderPreference = enabled
                isUpdatingReminders = true
                if !enabled {
                    dueRemindersEnabled = false
                }
                reminderUpdateTask = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    defer {
                        if reminderUpdateGeneration == generation {
                            isUpdatingReminders = false
                            reminderUpdateTask = nil
                            pendingReminderPreference = nil
                        }
                    }
                    if enabled {
                        let allowed = await LocalDueReminderScheduler
                            .requestAuthorization()
                        guard reminderUpdateGeneration == generation,
                              !Task.isCancelled
                        else { return }
                        dueRemindersEnabled = allowed
                        if allowed {
                            var failedCount = 0
                            for record in model.documents
                            where record.dueAt != nil {
                                guard reminderUpdateGeneration
                                        == generation,
                                      !Task.isCancelled
                                else { return }
                                let scheduled =
                                    await LocalDueReminderScheduler.update(
                                    recordID: record.id,
                                    dueAt: record.dueAt
                                )
                                guard reminderUpdateGeneration
                                        == generation,
                                      !Task.isCancelled
                                else { return }
                                if !scheduled {
                                    failedCount += 1
                                }
                            }
                            if failedCount > 0 {
                                model[noticeFor: paperPathSceneID] =
                                    "Some due-date reminders could not be scheduled."
                                        .localizedUI
                            }
                        } else {
                            model[noticeFor: paperPathSceneID] =
                                "Reminders remain off because notification access was not granted."
                                    .localizedUI
                        }
                    } else {
                        await LocalDueReminderScheduler.disableAll()
                    }
                }
            }
        )
    }

    private var hasBlockingSettingsOperation: Bool {
        isResetting
            || isDeletingSyncedMetadata
            || isUpdatingReminders
            || appLockPreferenceTask != nil
            || metadataTask != nil
    }

    private var blockingOperationStatus: String? {
        if isResetting {
            return "Deleting local PaperPath data"
        }
        if isDeletingSyncedMetadata {
            return "Deleting synced metadata"
        }
        if isUpdatingReminders {
            return "Updating due-date reminders"
        }
        if appLockPreferenceTask != nil {
            return "Updating App Lock"
        }
        if metadataTask != nil {
            return "Updating iCloud metadata"
        }
        return nil
    }

    private func eraseAllLocalData() {
        guard resetTask == nil else { return }
        isResetting = true
        resetTask = Task { @MainActor in
            let deleted = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.eraseAllLocalData()
            }
            isResetting = false
            resetTask = nil
            if deleted {
                dismiss()
            }
        }
    }

    private func updateMetadataSyncPreference(_ enabled: Bool) {
        let generation = UUID()
        metadataGeneration = generation
        metadataTask?.cancel()
        metadataSyncEnabled = enabled
        metadataTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await model.withFeedbackTarget(paperPathSceneID) {
                await model.setMetadataSyncEnabled(enabled)
            }
            guard metadataGeneration == generation else { return }
            metadataTask = nil
        }
    }

    private func updateAppLockPreference(_ enabled: Bool) {
        guard appLockPreferenceTask == nil else { return }
        let generation = UUID()
        appLockPreferenceGeneration = generation
        appLockPreferenceTask = Task { @MainActor in
            if enabled {
                _ = await appLock.enable()
            } else {
                _ = await appLock.disable()
            }
            guard appLockPreferenceGeneration == generation else {
                return
            }
            appLockPreferenceTask = nil
        }
    }

    private func synchronizeMetadataNow() {
        guard metadataTask == nil else { return }
        let generation = UUID()
        metadataGeneration = generation
        metadataTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await model.withFeedbackTarget(paperPathSceneID) {
                await model.synchronizeMetadata()
            }
            guard metadataGeneration == generation else { return }
            metadataTask = nil
        }
    }

    private func deleteSyncedMetadata() {
        guard metadataTask == nil else { return }
        let generation = UUID()
        metadataGeneration = generation
        isDeletingSyncedMetadata = true
        metadataTask = Task { @MainActor in
            await model.withFeedbackTarget(paperPathSceneID) {
                await model.deleteSyncedMetadata()
            }
            guard metadataGeneration == generation else { return }
            metadataSyncEnabled = false
            isDeletingSyncedMetadata = false
            metadataTask = nil
        }
    }

    private func interruptTransientSettingsWork() {
        metadataGeneration = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        isDeletingSyncedMetadata = false
        let shouldRemovePendingReminders =
            reminderUpdateTask != nil
                && pendingReminderPreference == true
        reminderUpdateGeneration = UUID()
        reminderUpdateTask?.cancel()
        reminderUpdateTask = nil
        isUpdatingReminders = false
        pendingReminderPreference = nil
        if shouldRemovePendingReminders {
            dueRemindersEnabled = false
            Task {
                await LocalDueReminderScheduler.disableAll()
            }
        }
        appLockPreferenceGeneration = UUID()
        appLockPreferenceTask?.cancel()
        appLockPreferenceTask = nil
        appLock.cancelPendingAuthentication()
    }

    private func settingsRow(
        symbol: String,
        tint: Color,
        title: String,
        detail: String? = nil,
        disclosure: Bool = false
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    HStack(spacing: PPSpacing.small) {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                            .frame(width: 28)
                        Text(title.localizedUI)
                            .foregroundStyle(PPColor.textPrimary)
                        Spacer(minLength: PPSpacing.small)
                        if disclosure {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                    if let detail {
                        Text(detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 36)
                    }
                }
                .padding(.vertical, PPSpacing.xSmall)
            } else {
                HStack(spacing: PPSpacing.medium) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.localizedUI)
                            .foregroundStyle(PPColor.textPrimary)
                        if let detail {
                            Text(detail.localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                    }
                    Spacer(minLength: PPSpacing.small)
                    if disclosure {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var localStorageSize: String {
        ByteCountFormatter.string(
            fromByteCount: diagnosticsLibraryMetrics.byteCount,
            countStyle: .file
        )
    }

    private func createDiagnostics() {
        let metrics = diagnosticsLibraryMetrics
        do {
            diagnosticsURL = try SupportBundleService.create(
                documentCount: model.documents.count,
                deletedCount: model.deletedDocuments.count,
                pageCount: metrics.pageCount,
                localByteCount: metrics.byteCount,
                indexedDocumentCount: model.textIndices.count,
                ocrDocumentCount: model.ocrResults.count,
                receiptCount: metrics.receiptCount,
                metadataSyncState:
                    model.metadataSyncStatus.state.rawValue
            )
            isShowingDiagnostics = true
        } catch {
            model.present(error, in: paperPathSceneID)
        }
    }

    private var diagnosticsLibraryMetrics: (
        pageCount: Int,
        byteCount: Int64,
        receiptCount: Int
    ) {
        var pageCount = 0
        var byteCount: Int64 = 0
        var receiptCount = 0
        for record in model.documents {
            let nextPages = pageCount.addingReportingOverflow(
                max(0, record.profile.pageCount)
            )
            pageCount = nextPages.overflow
                ? .max
                : nextPages.partialValue
            let nextBytes = byteCount.addingReportingOverflow(
                max(0, record.profile.byteCount)
            )
            byteCount = nextBytes.overflow
                ? .max
                : nextBytes.partialValue
            if record.deliveryReceipt != nil,
               receiptCount < .max {
                receiptCount += 1
            }
        }
        return (pageCount, byteCount, receiptCount)
    }

    private func discardDiagnostics() {
        SupportBundleService.discard(diagnosticsURL)
        diagnosticsURL = nil
    }

    private func clearSensitiveConfirmations() {
        resetConfirmation = ""
        isConfirmingReset = false
        isConfirmingMetadataDeletion = false
    }

    private func interruptDiagnosticsShare() {
        isShowingDiagnostics = false
        discardDiagnostics()
    }
}


struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferences.latestReleaseSeenKey)
    private var latestReleaseSeen = ""

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        PPIllustration(kind: .workspace, width: 160)
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: PPSpacing.small) {
                            StudioSectionRule(
                                title: "PaperPath \(AppPreferences.currentRelease)",
                                symbol: "doc.text.magnifyingglass",
                                tint: PPColor.rose
                            )
                        }
                        change(
                            "Pick up where you left off",
                            symbol: "arrow.right.circle"
                        )
                        change(
                            "Review scans and recognized text",
                            symbol: "viewfinder"
                        )
                        change(
                            "Review private details",
                            symbol: "hand.raised"
                        )
                        change(
                            "Check the copy you share",
                            symbol: "checkmark.shield"
                        )
                    }
                    .frame(maxWidth: 620)
                    .padding(PPSpacing.large)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("What’s New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear {
            latestReleaseSeen = AppPreferences.currentRelease
        }
    }

    private func change(
        _ title: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: symbol,
                tint: PPColor.accent,
                size: 42
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title.localizedUI)
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }
}
