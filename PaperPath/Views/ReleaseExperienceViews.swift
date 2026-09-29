import StoreKit
import SwiftUI
import UIKit
import UserNotifications

struct FirstRunExperienceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let hasExistingDocuments: Bool
    let onSample: () async -> Bool
    let onComplete: () -> Void

    @State private var page = 0
    @State private var isCreatingSample = false
    @State private var sampleError: String?
    @State private var sampleTask: Task<Void, Never>?
    @State private var sampleGeneration = UUID()
    @State private var sampleErrorFeedback = 0

    var body: some View {
        ZStack {
            PPCanvas()

            VStack(spacing: 0) {
                HStack {
                    Text(AppBrand.name)
                        .font(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? .caption.weight(.semibold)
                                : .headline
                        )
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    OnDeviceBadge(compact: true)
                }
                .padding(.horizontal, PPSpacing.large)
                .padding(.top, PPSpacing.medium)

                onboardingRail
                    .padding(.horizontal, PPSpacing.large)
                    .padding(.top, PPSpacing.small)
                    .disabled(isCreatingSample)

                if usesWideOnboardingLayout {
                    Spacer(minLength: 0)
                }

                TabView(selection: $page) {
                    introPage(
                        eyebrow: "YOUR PDF, YOUR DEVICE",
                        title: "Finish important PDFs privately.",
                        detail: "Fill, sign, or remove sensitive information. Keep your original and check the copy before sharing.",
                        illustration: .workspace,
                        tint: PPColor.accent
                    )
                    .tag(0)

                    introPage(
                        eyebrow: "WORK ON A COPY",
                        title: "Choose a PDF when you’re ready.",
                        detail: "PaperPath creates a private working copy. Your imported original stays untouched.",
                        illustration: .intake,
                        tint: PPColor.cyan
                    )
                    .tag(1)

                    introPage(
                        eyebrow: "CHECK BEFORE SHARING",
                        title: "Finish with confidence.",
                        detail: "PaperPath reopens the finished copy, checks it, and keeps a local receipt.",
                        illustration: .processing,
                        tint: PPColor.mint
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: usesWideOnboardingLayout ? 420 : .infinity)
                .disabled(isCreatingSample)

                VStack(spacing: PPSpacing.medium) {
                    Button {
                        if sampleTask != nil {
                            interruptSampleCreation()
                        } else {
                            createSample()
                        }
                    } label: {
                        HStack(spacing: PPSpacing.small) {
                            Image(systemName: isCreatingSample
                                ? "stop.fill"
                                : sampleError != nil
                                    ? "arrow.clockwise"
                                    : "doc.text.magnifyingglass")
                            Text(sampleActionTitle.localizedUI)
                        }
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("samplePDFAction")
                    .accessibilityHint(
                        (
                            isCreatingSample
                                ? "Stops before the sample is added"
                                : hasExistingDocuments
                                    ? "Opens an existing private working copy"
                                    : "Creates a local sample PDF"
                        ).localizedUI
                    )

                    Button("Go to Home") {
                        onComplete()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(isCreatingSample)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("onboardingOpenLibrary")

                    if let sampleError {
                        Label(
                            sampleError.localizedUI,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isStaticText)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, PPSpacing.large)
                .padding(.bottom, PPSpacing.large)

                if usesWideOnboardingLayout {
                    Spacer(minLength: 0)
                }
            }
        }
        .interactiveDismissDisabled()
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.error, trigger: sampleErrorFeedback)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptSampleCreation()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptSampleCreation()
        }
        .onDisappear {
            interruptSampleCreation()
        }
    }

    private var onboardingRail: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                HStack(spacing: PPSpacing.small) {
                    Text(
                        AppLocalization.format(
                            "Step %lld of 3",
                            page + 1
                        )
                    )
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.accent)
                    Spacer()
                    Label(
                        onboardingStepTitle.localizedUI,
                        systemImage: onboardingStepSymbol
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                }
                .frame(minHeight: 44)
            } else {
                HStack(spacing: 0) {
                    onboardingStop(
                        index: 0,
                        title: "Goal",
                        symbol: "scope"
                    )
                    onboardingStop(
                        index: 1,
                        title: "Work",
                        symbol: "doc.on.doc"
                    )
                    onboardingStop(
                        index: 2,
                        title: "Share",
                        symbol: "checkmark.seal"
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Introduction progress".localizedUI)
        .accessibilityValue(
            AppLocalization.format(
                "Step %lld of 3, %@",
                page + 1,
                onboardingStepTitle.localizedUI
            )
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                guard page < 2 else { return }
                changeOnboardingPage(to: page + 1)
            case .decrement:
                guard page > 0 else { return }
                changeOnboardingPage(to: page - 1)
            @unknown default:
                break
            }
        }
    }

    private var onboardingStepTitle: String {
        switch page {
        case 0: return "Goal"
        case 1: return "Work"
        default: return "Share"
        }
    }

    private var onboardingStepSymbol: String {
        switch page {
        case 0: return "scope"
        case 1: return "doc.on.doc"
        default: return "checkmark.seal"
        }
    }

    private var sampleActionTitle: String {
        if isCreatingSample {
            return "Stop Creating Sample"
        }
        if sampleError != nil {
            return "Try Sample Again"
        }
        return hasExistingDocuments
            ? "Open My PDF"
            : "Try a Sample PDF"
    }

    private func onboardingStop(
        index: Int,
        title: String,
        symbol: String
    ) -> some View {
        let selected = page == index
        let complete = page > index
        let tint: Color = complete
            ? PPColor.mint
            : (selected ? PPColor.accent : PPColor.textSecondary)
        return Button {
            changeOnboardingPage(to: index)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index + 1))
                        .font(.caption2.monospacedDigit().weight(.bold))
                    Rectangle()
                        .fill(tint.opacity(selected ? 0.8 : 0.42))
                        .frame(height: selected ? 1.5 : 0.6)
                }
                Label(title.localizedUI, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "")
    }

    private var usesWideOnboardingLayout: Bool {
        horizontalSizeClass == .regular
            && !dynamicTypeSize.ppPrefersExpandedLayout
    }

    private func changeOnboardingPage(to requestedPage: Int) {
        let resolvedPage = min(max(0, requestedPage), 2)
        guard resolvedPage != page else { return }
        withAnimation(
            reduceMotion ? nil : .snappy(duration: 0.24)
        ) {
            page = resolvedPage
        }
    }

    private func introPage(
        eyebrow: String,
        title: String,
        detail: String,
        illustration: PPIllustrationKind,
        tint: Color
    ) -> some View {
        ScrollView {
            VStack(spacing: PPSpacing.large) {
                Spacer(
                    minLength:
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? PPSpacing.xSmall
                            : PPSpacing.medium
                )

                Group {
                    if horizontalSizeClass == .compact
                        || dynamicTypeSize.ppPrefersExpandedLayout {
                        VStack(alignment: .leading, spacing: PPSpacing.xLarge) {
                            onboardingIllustration(illustration)
                                .frame(maxWidth: .infinity)
                            onboardingCopy(
                                eyebrow: eyebrow,
                                title: title,
                                detail: detail,
                                tint: tint
                            )
                            .multilineTextAlignment(.leading)
                        }
                    } else {
                        HStack(
                            alignment: .center,
                            spacing: PPSpacing.xLarge
                        ) {
                            onboardingIllustration(illustration)
                            onboardingCopy(
                                eyebrow: eyebrow,
                                title: title,
                                detail: detail,
                                tint: tint
                            )
                            .multilineTextAlignment(.leading)
                        }
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, PPSpacing.xLarge)

                if horizontalSizeClass == .regular,
                   !dynamicTypeSize.ppPrefersExpandedLayout {
                    onboardingEvidence
                        .padding(.horizontal, PPSpacing.large)
                }
                Spacer(minLength: PPSpacing.medium)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.hidden)
    }

    private func onboardingIllustration(
        _ illustration: PPIllustrationKind
    ) -> some View {
        let width: CGFloat =
            dynamicTypeSize.ppPrefersExpandedLayout ? 92 : 164
        return PPIllustration(kind: illustration, width: width)
            .frame(
                width: dynamicTypeSize.ppPrefersExpandedLayout
                    ? 102
                    : 170,
                height: dynamicTypeSize.ppPrefersExpandedLayout
                    ? 82
                    : 138
            )
            .overlay {
                StudioStageMarks(
                    tint: page == 2 ? PPColor.mint : PPColor.accent,
                    inset: 3,
                    arm: 9
                )
            }
    }

    private func onboardingCopy(
        eyebrow: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: eyebrow)

            Text(title.localizedUI)
                .font(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? .title3.bold()
                        : .title2.bold()
                )
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(detail.localizedUI)
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.7))
                .frame(width: 2)
                .padding(.vertical, 2)
                .offset(x: -12)
        }
    }

    private var onboardingEvidence: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(minimum: 0),
                    spacing: PPSpacing.medium
                ),
                count: 3
            ),
            spacing: PPSpacing.medium
        ) {
            StudioMetricCell(
                value: "Choose",
                label: "A clear goal",
                symbol: "scope",
                tint: PPColor.accent,
                allowsLabelWrapping: true
            )
            StudioMetricCell(
                value: "Edit",
                label: "Private copy",
                symbol: "doc.on.doc",
                tint: PPColor.cyan,
                allowsLabelWrapping: true
            )
            StudioMetricCell(
                value: "Check",
                label: "Before sharing",
                symbol: "checkmark.seal",
                tint: PPColor.mint,
                allowsLabelWrapping: true
            )
        }
        .frame(maxWidth: 720)
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
                sampleError =
                    "The sample PDF could not be created. Try again or go to Home."
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
    @EnvironmentObject private var purchase: PurchaseController
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
    @State private var isShowingUnlock = false
    @State private var isShowingPrivacyInformation = false
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
                        accountSection
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
        .sheet(isPresented: $isShowingUnlock) {
            FullUnlockView(context: .settings)
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
                "Working copies, OCR text, receipts, versions, signatures, and Trash will be permanently removed. Original files stay untouched."
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
                "This turns off metadata sync and removes PaperPath metadata from iCloud. Local PDFs and original files stay untouched."
            )
        }
        .task {
            await purchase.prepare()
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

    private var accountSection: some View {
        settingsSection(
            title: "PAPERPATH",
            detail: "One-time access, no account",
            symbol: "seal",
            tint: PPColor.accent
        ) {
            settingsControl(tint: PPColor.accent) {
                Button {
                    isShowingUnlock = true
                } label: {
                    settingsRow(
                        symbol: purchaseOwnershipSymbol,
                        tint: purchaseOwnershipTint,
                        title: purchaseOwnershipTitle,
                        detail: purchaseOwnershipDetail,
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsPurchase")
            }
        }
    }

    private var languageSection: some View {
        settingsSection(
            title: "APP LANGUAGE",
            detail: "Change the PaperPath interface",
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
            detail: "App lock and optional metadata sync",
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
                            detail: "PDF bytes and extracted text never sync",
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
                                : "Off"
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
                        detail: "Inspect local processing and protection",
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
            detail: "Balance image detail and memory",
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
            title: "REMINDERS",
            detail: "PDF names and content never appear in notifications",
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
                            : displayedRemindersEnabled
                                ? "Only reminders you schedule"
                                : "No promotional notifications"
                    )
                }
                .disabled(isUpdatingReminders || isResetting)
            }
        }
    }

    private var supportSection: some View {
        settingsSection(
            title: "HELP & ABOUT",
            detail: "Diagnostics exclude document content and names",
            symbol: "questionmark.circle",
            tint: PPColor.cyan
        ) {
            settingsControl(tint: PPColor.mint) {
                Button {
                    isShowingPrivacyInformation = true
                } label: {
                    settingsActionLabel(
                        "Privacy & Data",
                        detail: "Read how your files and purchases are handled",
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
                        detail: "Technical state only",
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
                        detail: "Review recent product changes",
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
                        detail: "Review the basic workflow",
                        symbol: "rectangle.stack",
                        tint: PPColor.rose
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dataSection: some View {
        settingsSection(
            title: "STORAGE & DATA",
            detail: "Files originals stay untouched",
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
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: title,
                detail: detail,
                symbol: symbol,
                tint: tint
            )
            .padding(.bottom, PPSpacing.small)
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
        detail: String,
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
                    Text(detail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36)
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
                        Text(detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
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

    private var purchaseOwnershipTitle: String {
        if purchase.isUnlocked {
            return "Verified Output Lifetime"
        }
        if purchase.status == .pending {
            return "Purchase Pending"
        }
        return "Unlock Verified Output"
    }

    private var purchaseOwnershipDetail: String {
        if purchase.isUnlocked {
            return "Lifetime access is active on this device"
        }
        switch purchase.status {
        case .loading, .purchasing, .restoring, .pending,
             .unavailable, .failed:
            return purchase.status.detail
        case .idle, .cancelled, .purchased:
            return purchase.product.map {
                AppLocalization.format(
                    "%@ once · no subscription",
                    $0.displayPrice
                )
            } ?? "One-time purchase · no subscription"
        }
    }

    private var purchaseOwnershipSymbol: String {
        if purchase.isUnlocked {
            return "checkmark.seal.fill"
        }
        return purchase.status == .pending
            ? "clock.badge.questionmark"
            : "seal"
    }

    private var purchaseOwnershipTint: Color {
        if purchase.isUnlocked {
            return PPColor.mint
        }
        switch purchase.status {
        case .pending:
            return PPColor.amber
        case .failed, .unavailable:
            return PPColor.rose
        default:
            return PPColor.accent
        }
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
        detail: String,
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
                    Text(detail.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36)
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
                        Text(detail.localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
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

struct FullUnlockView: View {
    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var purchase: PurchaseController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled)
    private var voiceOverEnabled

    let context: FullUnlockContext

    @State private var purchaseSuccessFeedback = 0
    @State private var purchaseErrorFeedback = 0
    @State private var continuationTask: Task<Void, Never>?
    @State private var isShowingPrivacyInformation = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    unlockContent
                        .padding(.horizontal, PPSpacing.regular)
                        .padding(.vertical, PPSpacing.regular)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Verified Output Lifetime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            purchase.isUnlocked && context.isBlockedAction
                                ? "Continue"
                                : "Done"
                        ).localizedUI
                    ) {
                        dismiss()
                    }
                    .disabled(isCommittingStoreOperation)
                }
            }
        }
        .interactiveDismissDisabled(isCommittingStoreOperation)
        .sheet(isPresented: $isShowingPrivacyInformation) {
            PrivacyInformationView()
        }
        .task {
            await purchase.prepare()
        }
        .onChange(of: purchase.status) { _, status in
            switch status {
            case .purchased:
                purchaseSuccessFeedback += 1
            case .failed, .unavailable:
                purchaseErrorFeedback += 1
            default:
                break
            }
            if voiceOverEnabled {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: status.detail.localizedUI
                )
            }
        }
        .onChange(of: purchase.isUnlocked) { _, isUnlocked in
            guard isUnlocked else {
                continuationTask?.cancel()
                continuationTask = nil
                return
            }
            scheduleBlockedActionContinuation()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                scheduleBlockedActionContinuation()
            } else {
                continuationTask?.cancel()
                continuationTask = nil
            }
        }
        .onDisappear {
            continuationTask?.cancel()
            continuationTask = nil
        }
        .sensoryFeedback(.success, trigger: purchaseSuccessFeedback)
        .sensoryFeedback(.error, trigger: purchaseErrorFeedback)
    }

    private func scheduleBlockedActionContinuation() {
        guard context.isBlockedAction,
              purchase.isUnlocked,
              scenePhase == .active,
              !voiceOverEnabled
        else { return }
        continuationTask?.cancel()
        continuationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  purchase.isUnlocked,
                  scenePhase == .active,
                  !voiceOverEnabled
            else { return }
            continuationTask = nil
            dismiss()
        }
    }

    private var unlockContent: some View {
        VStack(
            alignment: .leading,
            spacing: PPSpacing.large
        ) {
            unlockHero
            entitlementBoundary
            capability(
                "Unlimited Verified Output",
                detail: "Create verified copies without a limit",
                symbol: "checkmark.shield"
            )
            purchaseActions
            DisclosureGroup {
                capability(
                    "Single & Batch Delivery",
                    detail: "Check one final copy or a complete batch",
                    symbol: "square.stack.3d.up"
                )
                capability(
                    "No Subscription",
                    detail: ownershipCapabilityDetail,
                    symbol: "infinity"
                )
            } label: {
                Text("Included with unlock".localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            purchaseInformation
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var unlockHero: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            StudioSectionRule(
                title: "ONE-TIME OWNERSHIP",
                detail: "No PaperPath account · no subscription",
                symbol: "seal",
                tint: PPColor.rose
            )

            if dynamicTypeSize.ppPrefersExpandedLayout {
                unlockCopy
            } else if horizontalSizeClass != .regular {
                HStack(spacing: PPSpacing.medium) {
                    PPIllustration(kind: .tools, width: 72)
                        .accessibilityHidden(true)
                    unlockCopy
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.xLarge) {
                        unlockIllustration
                        unlockCopy
                    }
                    VStack(spacing: PPSpacing.medium) {
                        unlockIllustration
                        unlockCopy
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var unlockIllustration: some View {
        let width: CGFloat = dynamicTypeSize.ppPrefersExpandedLayout
            ? 112
            : 154
        return PPIllustration(kind: .tools, width: width)
            .frame(
                width: dynamicTypeSize.ppPrefersExpandedLayout
                    ? 122
                    : 164,
                height: dynamicTypeSize.ppPrefersExpandedLayout
                    ? 100
                    : 132
            )
            .overlay {
                StudioStageMarks(
                    tint: PPColor.mint,
                    inset: 3,
                    arm: 9
                )
            }
    }

    private var unlockCopy: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text(
                (
                    purchase.isUnlocked
                        ? "Verified Output is unlocked."
                        : context.title
                ).localizedUI
            )
            .font(.title2.bold())
            .fontDesign(.serif)
            .foregroundStyle(PPColor.textPrimary)
            Text(
                (
                    purchase.isUnlocked
                        ? context.isBlockedAction
                            ? "Return to your document to continue."
                            : "Thank you for supporting private, on-device PDF work."
                        : context.detail
                ).localizedUI
            )
            .font(.subheadline)
            .foregroundStyle(PPColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 380, alignment: .leading)
    }

    private func capability(
        _ title: String,
        detail: String,
        symbol: String
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: symbol,
                tint: PPColor.mint,
                size: 42
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title.localizedUI)
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
                Text(detail.localizedUI)
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
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

    private var entitlementBoundary: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    entitlementFacts
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        entitlementFacts
                    }
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        entitlementFacts
                    }
                }
            }
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var entitlementFacts: some View {
        entitlementFact(
            "Included",
            value: "Read/Edit",
            symbol: "doc.text",
            tint: PPColor.accent
        )
        entitlementFact(
            "Single verified",
            value: purchase.isUnlocked
                ? "Included"
                : model.verifiedOutputSuccessCount == 0
                    ? "Free once"
                    : "Used",
            symbol: "checkmark.seal",
            tint: PPColor.mint
        )
        entitlementFact(
            "Lifetime access",
            value: purchase.isUnlocked ? "Active" : "Optional",
            symbol: "infinity",
            tint: purchase.isUnlocked ? PPColor.mint : PPColor.amber
        )
    }

    private func entitlementFact(
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
            VStack(alignment: .leading, spacing: 0) {
                Text(value.localizedUI)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(title.localizedUI)
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 36)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.42))
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var purchaseActions: some View {
        VStack(spacing: PPSpacing.medium) {
            if purchase.isUnlocked {
                Label(
                    "Lifetime Access Active",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(PPColor.mint)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
            } else {
                if purchase.status == .pending {
                    Button {
                        Task {
                            await purchase.recheckPendingPurchase()
                        }
                    } label: {
                        Label(
                            "Check Purchase Status",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(purchase.isBusy)
                    .accessibilityIdentifier("purchaseCheckStatus")
                } else {
                    Button {
                        Task {
                            if purchase.product == nil {
                                await purchase.prepare()
                            } else {
                                await purchase.purchase()
                            }
                        }
                    } label: {
                        HStack(spacing: PPSpacing.small) {
                            if purchase.activeOperation == .purchasing
                                || purchase.activeOperation == .preparing {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "seal.fill")
                            }
                            Text(purchaseButtonTitle)
                        }
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(purchase.purchaseControlsDisabled)
                    .accessibilityIdentifier("purchasePrimaryAction")

                    Button {
                        Task {
                            await purchase.restore()
                        }
                    } label: {
                        HStack(spacing: PPSpacing.small) {
                            if purchase.activeOperation == .restoring {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 20, height: 20)
                            }
                            Text("Restore Purchase")
                        }
                    }
                    .disabled(purchase.purchaseControlsDisabled)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("purchaseRestore")
                }
            }

            Text(purchase.status.detail.localizedUI)
                .font(.caption)
                .foregroundStyle(statusTint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(
                    purchase.isBusy ? .updatesFrequently : []
                )

            if !purchase.isUnlocked,
               purchase.status == .pending || purchase.product == nil {
                Text(
                    (purchase.status == .pending
                        ? "Approval may take time. You can close this screen and keep using PaperPath; access updates when the App Store approves the purchase."
                        : "Connect to the App Store to load the price. Your PDFs, reading, and editing remain available.")
                    .localizedUI
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, PPSpacing.small)
    }

    private var purchaseButtonTitle: String {
        guard let product = purchase.product else {
            return (purchase.isBusy
                ? "Checking App Store"
                : "Retry App Store").localizedUI
        }
        return AppLocalization.format(
            "Unlock for %@",
            product.displayPrice
        )
    }

    private var ownershipCapabilityDetail: String {
        purchase.product?.isFamilyShareable == true
            ? "One purchase · Family Sharing"
            : "One purchase · no recurring charge"
    }

    private var purchaseInformation: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text("A one-time purchase is charged to your Apple Account after confirmation. Restore it with the same Apple Account on another device. There is no recurring charge.".localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) { purchaseInformationLinks }
                VStack(alignment: .leading, spacing: 0) { purchaseInformationLinks }
            }
        }
    }

    @ViewBuilder
    private var purchaseInformationLinks: some View {
        Button("Privacy & Data".localizedUI) {
            isShowingPrivacyInformation = true
        }
        .accessibilityIdentifier("purchasePrivacyInformation")
        .frame(minHeight: 44)
        Link(
            "Terms of Use".localizedUI,
            destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
        )
        .frame(minHeight: 44)
    }

    private var isCommittingStoreOperation: Bool {
        purchase.activeOperation == .purchasing
            || purchase.activeOperation == .restoring
    }

    private var statusTint: Color {
        switch purchase.status {
        case .purchased:
            return PPColor.mint
        case .failed, .unavailable:
            return PPColor.rose
        case .pending:
            return PPColor.amber
        default:
            return PPColor.textSecondary
        }
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
                                detail: "Ready for your next PDF",
                                symbol: "doc.text.magnifyingglass",
                                tint: PPColor.rose
                            )
                            Text("Finish your PDF with fewer steps")
                                .font(.title2.bold())
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                        }
                        change(
                            "Pick up where you left off",
                            detail: "A clearer home screen keeps your next document and import actions close.",
                            symbol: "arrow.right.circle"
                        )
                        change(
                            "Review scans and recognized text",
                            detail: "Keep the page in view, adjust only what you need, and review uncertain words first.",
                            symbol: "viewfinder"
                        )
                        change(
                            "Review private details",
                            detail: "Select candidates, check their position in the PDF, and create a redacted copy while keeping the original.",
                            symbol: "hand.raised"
                        )
                        change(
                            "Check the copy you share",
                            detail: "See the result and any warnings first, then share the checked PDF with its receipt if needed.",
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
        detail: String,
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
                Text(detail.localizedUI)
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
