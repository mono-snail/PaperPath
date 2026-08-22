import StoreKit
import SwiftUI
import UserNotifications

struct FirstRunExperienceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onSample: () async -> Void
    let onComplete: () -> Void

    @State private var page = 0
    @State private var isCreatingSample = false

    var body: some View {
        ZStack {
            PPCanvas()

            VStack(spacing: 0) {
                HStack {
                    Text(AppBrand.name)
                        .font(.headline)
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Spacer()
                    Button("Skip") {
                        onComplete()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .opacity(page == 2 ? 0 : 1)
                    .disabled(page == 2)
                }
                .padding(.horizontal, PPSpacing.large)
                .padding(.top, PPSpacing.medium)

                onboardingRail
                    .padding(.horizontal, PPSpacing.large)
                    .padding(.top, PPSpacing.small)

                TabView(selection: $page) {
                    introPage(
                        eyebrow: "PRIVATE BY DEFAULT",
                        title: "Finish important PDFs privately.",
                        detail: "PDF content and extracted text stay in your local workspace.",
                        illustration: .privacy,
                        tint: PPColor.mint
                    )
                    .tag(0)

                    introPage(
                        eyebrow: "ORIGINAL PRESERVED",
                        title: "Work on a private copy.",
                        detail: "Your imported original is not silently overwritten.",
                        illustration: .workspace,
                        tint: PPColor.cyan
                    )
                    .tag(1)

                    introPage(
                        eyebrow: "VERIFIED OUTPUT",
                        title: "Check the copy before it leaves.",
                        detail: "PaperPath reopens the output, checks it, and keeps a receipt.",
                        illustration: .processing,
                        tint: PPColor.accent
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: PPSpacing.medium) {
                    if page < 2 {
                        Button {
                            withAnimation(
                                reduceMotion
                                    ? nil
                                    : .snappy(duration: 0.28)
                            ) {
                                page += 1
                            }
                        } label: {
                            Label(
                                "Continue",
                                systemImage: "arrow.right"
                            )
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                    } else {
                        Button {
                            isCreatingSample = true
                            Task {
                                await onSample()
                                isCreatingSample = false
                            }
                        } label: {
                            HStack(spacing: PPSpacing.small) {
                                if isCreatingSample {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "doc.text.magnifyingglass")
                                }
                                Text("Try a Local Sample")
                            }
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                        .disabled(isCreatingSample)

                        Button("Start Empty") {
                            onComplete()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, PPSpacing.large)
                .padding(.bottom, PPSpacing.large)
            }
        }
        .interactiveDismissDisabled()
        .sensoryFeedback(.selection, trigger: page)
    }

    private var onboardingRail: some View {
        HStack(spacing: 0) {
            onboardingStop(
                index: 0,
                title: "Local",
                symbol: "iphone"
            )
            onboardingStop(
                index: 1,
                title: "Source",
                symbol: "doc.on.doc"
            )
            onboardingStop(
                index: 2,
                title: "Deliver",
                symbol: "checkmark.seal"
            )
        }
        .accessibilityElement(children: .contain)
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
            withAnimation(
                reduceMotion ? nil : .snappy(duration: 0.24)
            ) {
                page = index
            }
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

    private func introPage(
        eyebrow: String,
        title: String,
        detail: String,
        illustration: PPIllustrationKind,
        tint: Color
    ) -> some View {
        ScrollView {
            VStack(spacing: PPSpacing.large) {
                Spacer(minLength: PPSpacing.medium)

                ViewThatFits(in: .horizontal) {
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

                    VStack(spacing: PPSpacing.medium) {
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
                .padding(.horizontal, PPSpacing.xLarge)

                onboardingEvidence
                    .padding(.horizontal, PPSpacing.large)
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
        PPIllustration(kind: illustration, width: 164)
            .frame(width: 170, height: 138)
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
                .font(.title2.bold())
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
            columns: [
                GridItem(
                    .adaptive(minimum: 106, maximum: 190),
                    spacing: PPSpacing.medium
                )
            ],
            spacing: PPSpacing.medium
        ) {
            StudioMetricCell(
                value: "Local",
                label: "Processing",
                symbol: "iphone",
                tint: PPColor.mint
            )
            StudioMetricCell(
                value: "Kept",
                label: "Original",
                symbol: "doc.on.doc",
                tint: PPColor.accent
            )
            StudioMetricCell(
                value: "SHA-256",
                label: "Receipt",
                symbol: "number",
                tint: PPColor.rose
            )
        }
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var appLock: AppLockController
    @EnvironmentObject private var purchase: PurchaseController
    @Environment(\.dismiss) private var dismiss

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
    @State private var isShowingDiagnostics = false
    @State private var diagnosticsURL: URL?
    @State private var resetConfirmation = ""
    @State private var isConfirmingReset = false
    @State private var isConfirmingMetadataDeletion = false
    @State private var isResetting = false

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        settingsStudioHeader
                        accountSection
                        languageSection
                        privacySection
                        performanceSection
                        remindersSection
                        supportSection
                        dataSection
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
                }
            }
        }
        .sheet(isPresented: $isShowingPrivacy) {
            PrivacyCenterView()
        }
        .sheet(isPresented: $isShowingWhatsNew) {
            WhatsNewView()
        }
        .sheet(isPresented: $isShowingUnlock) {
            FullUnlockView()
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
                isResetting = true
                Task {
                    await model.eraseAllLocalData()
                    isResetting = false
                    dismiss()
                }
            }
            .disabled(resetConfirmation != "DELETE")
            Button("Cancel", role: .cancel) {
                resetConfirmation = ""
            }
        } message: {
            Text(
                "Working copies, OCR text, receipts, versions, signatures, and Trash will be permanently removed. Files originals stay untouched."
            )
        }
        .alert(
            "Delete synced metadata from iCloud?",
            isPresented: $isConfirmingMetadataDeletion
        ) {
            Button("Delete Synced Metadata", role: .destructive) {
                Task {
                    await model.deleteSyncedMetadata()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes PaperPath metadata from iCloud. Local PDFs and Files originals stay untouched."
            )
        }
        .task {
            await purchase.prepare()
        }
    }

    private var settingsStudioHeader: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            StudioSectionRule(
                title: "STUDIO CONTROL",
                detail: "Private workspace policy",
                symbol: "switch.2",
                tint: PPColor.rose
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 128, maximum: 220),
                        spacing: PPSpacing.medium
                    )
                ],
                spacing: PPSpacing.medium
            ) {
                StudioMetricCell(
                    value: purchase.isUnlocked ? "Owned" : "Free",
                    label: "License",
                    symbol: "seal",
                    tint: purchase.isUnlocked
                        ? PPColor.mint
                        : PPColor.accent
                )
                StudioMetricCell(
                    value: "\(model.documents.count)",
                    label: "Copies",
                    symbol: "doc.on.doc",
                    tint: PPColor.cyan
                )
                StudioMetricCell(
                    value: localStorageSize,
                    label: "Storage",
                    symbol: "internaldrive",
                    tint: PPColor.amber
                )
                StudioMetricCell(
                    value: appLock.isEnabled ? "On" : "Off",
                    label: "App lock",
                    symbol: appLock.symbol,
                    tint: appLock.isEnabled
                        ? PPColor.mint
                        : PPColor.textSecondary
                )
            }
        }
    }

    private var accountSection: some View {
        settingsSection(
            title: "OWNERSHIP",
            detail: "No account or subscription",
            symbol: "seal",
            tint: PPColor.accent
        ) {
            settingsControl(tint: PPColor.accent) {
                Button {
                    isShowingUnlock = true
                } label: {
                    settingsRow(
                        symbol: purchase.isUnlocked
                            ? "checkmark.seal.fill"
                            : "seal",
                        tint: purchase.isUnlocked
                            ? PPColor.mint
                            : PPColor.accent,
                        title: purchase.isUnlocked
                            ? "Verified Output Lifetime"
                            : "Unlock Verified Output",
                        detail: purchase.isUnlocked
                            ? "Owned on this Apple ID"
                            : purchase.product.map {
                                AppLocalization.format(
                                    "%@ once · no subscription",
                                    $0.displayPrice
                                )
                            } ?? "One-time purchase · no subscription",
                        disclosure: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var languageSection: some View {
        settingsSection(
            title: "LANGUAGE",
            detail: "Interface only",
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
            title: "LOCAL-FIRST",
            detail: "Protected temporary exports are deleted after handoff",
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
                            : "Off · Document content stays local"
                    )
                }
            }

            if metadataSyncEnabled {
                settingsControl(tint: PPColor.cyan) {
                    Button {
                        Task {
                            await model.synchronizeMetadata()
                        }
                    } label: {
                        settingsActionLabel(
                            "Sync Metadata Now",
                            detail: "Document bytes never leave the device",
                            symbol: "arrow.triangle.2.circlepath",
                            tint: PPColor.cyan
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        model.metadataSyncStatus.state == .syncing
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
                }
            }

            settingsControl(tint: PPColor.mint) {
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
                    settingsRow(
                        symbol: appLock.symbol,
                        tint: appLock.isEnabled
                            ? PPColor.mint
                            : PPColor.textSecondary,
                        title: "App Lock",
                        detail: appLock.isEnabled
                            ? appLock.methodTitle
                            : "Off"
                    )
                }
                .disabled(
                    !appLock.isAvailable && !appLock.isEnabled
                )
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
            title: "PERFORMANCE",
            detail: "Balance preview detail and memory",
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
        settingsSection(
            title: "REMINDERS",
            detail: "PDF names and content never appear in notifications",
            symbol: "calendar.badge.clock",
            tint: PPColor.amber
        ) {
            settingsControl(tint: PPColor.amber) {
                Toggle(isOn: remindersBinding) {
                    settingsRow(
                        symbol: dueRemindersEnabled
                            ? "calendar.badge.clock"
                            : "bell.slash",
                        tint: dueRemindersEnabled
                            ? PPColor.amber
                            : PPColor.textSecondary,
                        title: "Due-Date Reminders",
                        detail: dueRemindersEnabled
                            ? "Only reminders you schedule"
                            : "No promotional notifications"
                    )
                }
            }
        }
    }

    private var supportSection: some View {
        settingsSection(
            title: "SUPPORT",
            detail: "Diagnostics exclude document content and names",
            symbol: "questionmark.circle",
            tint: PPColor.cyan
        ) {
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
                        detail: "Local → source → deliver",
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
            title: "LOCAL DATA",
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
                            detail: "Permanent removal from PaperPath",
                            symbol: "trash",
                            tint: PPColor.rose
                        )
                        if isResetting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isResetting)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PPSpacing.small)
            if disclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
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
        HStack(spacing: PPSpacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title.localizedUI)
                .foregroundStyle(PPColor.textPrimary)
            Spacer(minLength: PPSpacing.small)
            Text(value.localizedUI)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
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
                metadataSyncEnabled = enabled
                Task {
                    await model.setMetadataSyncEnabled(enabled)
                }
            }
        )
    }

    private var remindersBinding: Binding<Bool> {
        Binding(
            get: { dueRemindersEnabled },
            set: { enabled in
                Task {
                    if enabled {
                        let allowed = await LocalDueReminderScheduler
                            .requestAuthorization()
                        dueRemindersEnabled = allowed
                        if allowed {
                            for record in model.documents
                            where record.dueAt != nil {
                                await LocalDueReminderScheduler.update(
                                    recordID: record.id,
                                    dueAt: record.dueAt
                                )
                            }
                        }
                    } else {
                        dueRemindersEnabled = false
                        LocalDueReminderScheduler.disableAll()
                    }
                }
            }
        )
    }

    private func settingsRow(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        disclosure: Bool = false
    ) -> some View {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PPSpacing.small)
            if disclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var localStorageSize: String {
        ByteCountFormatter.string(
            fromByteCount: model.documents.reduce(0) {
                $0 + $1.profile.byteCount
            },
            countStyle: .file
        )
    }

    private func createDiagnostics() {
        do {
            diagnosticsURL = try SupportBundleService.create(
                documentCount: model.documents.count,
                deletedCount: model.deletedDocuments.count,
                pageCount: model.documents.reduce(0) {
                    $0 + $1.profile.pageCount
                },
                localByteCount: model.documents.reduce(0) {
                    $0 + $1.profile.byteCount
                },
                indexedDocumentCount: model.textIndices.count,
                ocrDocumentCount: model.ocrResults.count,
                receiptCount: model.documents.filter {
                    $0.deliveryReceipt != nil
                }.count,
                metadataSyncState:
                    model.metadataSyncStatus.state.rawValue
            )
            isShowingDiagnostics = true
        } catch {
            model.present(error)
        }
    }

    private func discardDiagnostics() {
        SupportBundleService.discard(diagnosticsURL)
        diagnosticsURL = nil
    }
}

struct FullUnlockView: View {
    @EnvironmentObject private var purchase: PurchaseController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        unlockHero
                        entitlementBoundary
                        capability(
                            "Unlimited Verified Output",
                            detail: "Create verified copies without a limit",
                            symbol: "checkmark.shield"
                        )
                        capability(
                            "Single & Batch Delivery",
                            detail: "Check one final copy or a complete batch",
                            symbol: "square.stack.3d.up"
                        )
                        capability(
                            "No Subscription",
                            detail: "One purchase for this Apple ID",
                            symbol: "infinity"
                        )
                        purchaseActions
                    }
                    .frame(maxWidth: 560)
                    .padding(PPSpacing.xLarge)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Verified Output Lifetime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await purchase.prepare()
        }
    }

    private var unlockHero: some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            StudioSectionRule(
                title: "ONE-TIME OWNERSHIP",
                detail: "No account · no subscription",
                symbol: "seal",
                tint: PPColor.rose
            )

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
        .frame(maxWidth: .infinity)
    }

    private var unlockIllustration: some View {
        PPIllustration(kind: .tools, width: 154)
            .frame(width: 164, height: 132)
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
                purchase.isUnlocked
                    ? "Verified Output is unlocked."
                    : "Own trusted delivery for life."
            )
            .font(.title2.bold())
            .fontDesign(.serif)
            .foregroundStyle(PPColor.textPrimary)
            Text(
                purchase.isUnlocked
                    ? "Thank you for supporting private, on-device PDF work."
                    : "Your first real Verified Output is free. Unlock unlimited use when PaperPath has proved useful."
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                entitlementFact(
                    "Included",
                    value: "Read/Edit",
                    symbol: "doc.text",
                    tint: PPColor.accent
                )
                entitlementFact(
                    "First verified",
                    value: AppEntitlement.verifiedOutputCount == 0
                        ? "Free"
                        : "\(AppEntitlement.verifiedOutputCount)",
                    symbol: "checkmark.seal",
                    tint: PPColor.mint
                )
                entitlementFact(
                    "Lifetime",
                    value: purchase.isUnlocked ? "Active" : "Optional",
                    symbol: "infinity",
                    tint: purchase.isUnlocked ? PPColor.mint : PPColor.amber
                )
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                entitlementFact(
                    "Included",
                    value: "Read/Edit",
                    symbol: "doc.text",
                    tint: PPColor.accent
                )
                entitlementFact(
                    "First verified",
                    value: AppEntitlement.verifiedOutputCount == 0
                        ? "Free"
                        : "\(AppEntitlement.verifiedOutputCount)",
                    symbol: "checkmark.seal",
                    tint: PPColor.mint
                )
                entitlementFact(
                    "Lifetime",
                    value: purchase.isUnlocked ? "Active" : "Optional",
                    symbol: "infinity",
                    tint: purchase.isUnlocked ? PPColor.mint : PPColor.amber
                )
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
                        if purchase.status == .purchasing
                            || purchase.status == .loading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "seal.fill")
                        }
                        Text(
                            purchase.product == nil
                                ? "Check App Store"
                                : "Unlock for \(purchase.displayPrice)"
                        )
                    }
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(
                    purchase.status == .purchasing
                        || purchase.status == .loading
                        || purchase.status == .pending
                )

                Button("Restore Purchase") {
                    Task {
                        await purchase.restore()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
            }

            Text(purchase.status.detail.localizedUI)
                .font(.caption)
                .foregroundStyle(
                    purchase.status == .purchased
                        ? PPColor.mint
                        : PPColor.textSecondary
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, PPSpacing.small)
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
                                title: "PAPERPATH V5",
                                detail: "Paper studio edition",
                                symbol: "doc.text.magnifyingglass",
                                tint: PPColor.rose
                            )
                            Text("A calmer path to trusted output")
                                .font(.title2.bold())
                                .fontDesign(.serif)
                                .foregroundStyle(PPColor.textPrimary)
                        }
                        change(
                            "Start with the outcome",
                            detail: "The home screen now prioritizes the next document task.",
                            symbol: "arrow.right.circle"
                        )
                        change(
                            "Local-first controls",
                            detail: "iCloud metadata is optional and off by default.",
                            symbol: "lock.shield"
                        )
                        change(
                            "Private support bundle",
                            detail: "Share diagnostics without PDF names, bytes, or extracted text.",
                            symbol: "wrench.and.screwdriver"
                        )
                        change(
                            "One-time ownership",
                            detail: "Unlimited Verified Output uses one purchase, not a recurring subscription.",
                            symbol: "seal"
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
                    Button("Done") { dismiss() }
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
