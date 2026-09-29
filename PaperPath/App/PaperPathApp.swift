import SwiftUI

@main
struct PaperPathApp: App {
    @StateObject private var model = PaperPathApp.makeModel()
    @StateObject private var appLock = AppLockController()
    @StateObject private var purchase = PurchaseController()
    @AppStorage(AppLanguage.defaultsKey)
    private var languageCode = AppLanguage.system.rawValue

    private static func makeModel() -> PaperPathModel {
#if DEBUG
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
#endif
        return PaperPathModel()
    }

    init() {
        AppPreferences.registerDefaults()
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
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
                .environmentObject(purchase)
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
