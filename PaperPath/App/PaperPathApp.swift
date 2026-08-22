import SwiftUI

@main
struct PaperPathApp: App {
    @StateObject private var model = PaperPathModel()
    @StateObject private var appLock = AppLockController()
    @StateObject private var purchase = PurchaseController()
    @AppStorage(AppLanguage.defaultsKey)
    private var languageCode = AppLanguage.system.rawValue

    init() {
        AppPreferences.registerDefaults()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "UITEST_RESET_DEMO"
        ) {
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
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(appLock)
                .environmentObject(purchase)
                .environment(
                    \.locale,
                    AppLanguage(rawValue: languageCode)?.locale
                        ?? .autoupdatingCurrent
                )
                .tint(PPColor.accent)
                .task {
                    async let bootstrap: Void = model.bootstrap()
                    async let entitlement: Void =
                        purchase.refreshForLaunch()
                    _ = await (bootstrap, entitlement)
                }
                .onOpenURL { url in
                    Task {
                        await model.receiveExternalURL(url)
                    }
                }
        }
    }
}
