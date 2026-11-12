import SwiftUI

@main
struct PaperPathApp: App {
    @StateObject private var model = PaperPathApp.makeModel()
    @StateObject private var appLock = AppLockController()
    @AppStorage(AppLanguage.defaultsKey)
    private var languageCode = AppLanguage.system.rawValue

    private static func makeModel() -> PaperPathModel {
#if DEBUG
        if let fixtureArgument = ProcessInfo.processInfo.arguments.last(where: {
            $0.hasPrefix("UITEST_DOCUMENT_LIFECYCLE=")
        }), let fixtureID = UUID(uuidString: String(fixtureArgument.dropFirst("UITEST_DOCUMENT_LIFECYCLE=".count))),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let root = documents.appendingPathComponent("DocumentLifecycleUITestFixtures")
                .appendingPathComponent(fixtureID.uuidString)
            return PaperPathModel(store: DocumentStore(rootURL: root),
                                 signatureStore: SignatureStore(rootURL: root.appendingPathComponent("Signatures")))
        }
        if ProcessInfo.processInfo.arguments.contains("UITEST_COMPRESSION_FIXTURE"),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return PaperPathModel(store: DocumentStore(
                rootURL: documents.appendingPathComponent("CompressionUITestFixture")
            ))
        }
        if ProcessInfo.processInfo.arguments.contains("UITEST_POLISH_OCR"),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return PaperPathModel(store: DocumentStore(
                rootURL: documents.appendingPathComponent("PolishOCRFixture")
            ))
        }
        if ProcessInfo.processInfo.arguments.contains(
            "UITEST_OFFICE_CORPUS_FIXTURE"
        ),
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first {
            return PaperPathModel(
                store: DocumentStore(
                    rootURL: documents.appendingPathComponent(
                        "OfficeCorpusUITestFixture-v1"
                    )
                )
            )
        }
        if ProcessInfo.processInfo.arguments.contains("UITEST_OFFICE_CORPUS_RESULT"),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: documents.appendingPathComponent("OfficeCorpus/report.json")),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let runID = report["runID"] as? String, UUID(uuidString: runID) != nil {
            return PaperPathModel(store: DocumentStore(
                rootURL: documents.appendingPathComponent("OfficeCorpus/store-\(runID)")
            ))
        }
        if (ProcessInfo.processInfo.arguments.contains("UITEST_COMPETITIVE_GALLERY")
            || ProcessInfo.processInfo.arguments.contains("UITEST_RECOVERY_GALLERY")),
           let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
           ).first {
            return PaperPathModel(store: DocumentStore(
                rootURL: documents.appendingPathComponent(
                    ProcessInfo.processInfo.arguments.contains("UITEST_RECOVERY_GALLERY")
                        ? "RecoveryFixture" : "CompetitiveFixture", isDirectory: true
                )
            ))
        }
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("UITEST_HANDOFF_FIXTURE=") }),
           let token = UUID(uuidString: String(argument.dropFirst("UITEST_HANDOFF_FIXTURE=".count))) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperPathHandoffTests-\(token.uuidString)")
            return PaperPathModel(store: DocumentStore(rootURL: root.appendingPathComponent("Documents")),
                                  signatureStore: SignatureStore(rootURL: root.appendingPathComponent("Signatures")))
        }
        if ProcessInfo.processInfo.arguments.contains("UITEST_WORKFLOW_FIXTURE")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperPathWorkflowTestFixture", isDirectory: true)
            return PaperPathModel(
                store: DocumentStore(rootURL: root.appendingPathComponent("Documents")),
                signatureStore: SignatureStore(rootURL: root.appendingPathComponent("Signatures"))
            )
        }
#endif
        return PaperPathModel()
    }

    init() {
        AppPreferences.registerDefaults()
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(where: { $0.hasPrefix("UITEST_") }) {
            // A failed replay test must not present the introduction in the
            // next isolated fixture. Explicit replay still works after launch.
            UserDefaults.standard.set(false, forKey: AppPreferences.onboardingReplayRequestedKey)
        }
        if arguments.contains("UITEST_RESET_DEMO") {
            UserDefaults.standard.set(
                "work",
                forKey: "library.workspaceLane"
            )
            UserDefaults.standard.set(
                "suggested",
                forKey: "document.toolPaletteView"
            )
        }
#endif
    }

    var body: some Scene {
        WindowGroup(for: UUID.self) { $initialRecordID in
            appContent(initialRecordID: initialRecordID)
                .environmentObject(model)
                .environmentObject(appLock)
                .environment(
                    \.locale,
                    AppLanguage(rawValue: languageCode)?.locale
                        ?? .autoupdatingCurrent
                )
                .tint(PPColor.accent)
                .onChange(of: languageCode, initial: true) {
                    _, newValue in
                    UserDefaults(
                        suiteName: ExternalPDFInbox.appGroupIdentifier
                    )?.set(
                        newValue,
                        forKey: AppLanguage.defaultsKey
                    )
                }
        }
    }

    @ViewBuilder
    private func appContent(initialRecordID: UUID?) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: {
            $0.hasPrefix("UITEST_PRIVACY_GALLERY_")
        }) {
            PrivacyScanDebugGalleryView()
        } else {
            RootView(initialRecordID: initialRecordID)
        }
#else
        RootView(initialRecordID: initialRecordID)
#endif
    }
}
