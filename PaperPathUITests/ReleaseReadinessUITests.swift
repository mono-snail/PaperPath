import XCTest

#if targetEnvironment(simulator)
import StoreKitTest
#endif

@MainActor
final class ReleaseReadinessUITests: XCTestCase {
    func testLockedWorkspaceHidesDocumentControlsFromAccessibility() throws {
        let app = launch()
        app.terminate()
        app.launchArguments.removeAll { $0 == "UITEST_RESET_DEMO" }
        if let lockIndex = app.launchArguments.firstIndex(
            of: "-privacy.appLockEnabled"
        ) {
            app.launchArguments.removeSubrange(
                lockIndex...min(
                    lockIndex + 1,
                    app.launchArguments.index(before: app.launchArguments.endIndex)
                )
            )
        }
        app.launchArguments += ["-privacy.appLockEnabled", "YES"]
        app.launch()

        let privacyCover = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "Document previews are hidden"
            )
        ).firstMatch
        XCTAssertTrue(
            app.buttons["unlockPaperPath"].waitForExistence(timeout: 3)
                || privacyCover.waitForExistence(timeout: 10)
        )
        screenshot("Locked workspace accessibility boundary", app)
        XCTAssertFalse(
            app.buttons["workspaceLane-home"].exists,
            "Navigation must be hidden while locked or authenticating."
        )
        XCTAssertFalse(
            app.buttons["settings"].exists,
            "Locked workspace controls must be absent from the accessibility tree."
        )
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "documentRow-")
            ).firstMatch.exists,
            "Document names must not be exposed behind App Lock."
        )
        XCUIDevice.shared.press(.home)
        app.terminate()
    }

#if targetEnvironment(simulator)
    private func commerceSession() throws -> SKTestSession {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PAPERPATH_LOCAL_STOREKIT"] == "1",
            "Run the PaperPathCommerce scheme to activate the local StoreKit catalog."
        )
        let session = try SKTestSession(configurationFileNamed: "PaperPath")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    private func openPurchase(_ app: XCUIApplication) {
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["settingsPurchase"].waitForExistence(timeout: 8))
        app.buttons["settingsPurchase"].tap()
    }

    func testRestoreWithoutPurchaseShowsRecoverableFailure() throws {
        let session = try commerceSession()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let app = launch()
        openPurchase(app)
        let restore = app.buttons["purchaseRestore"]
        XCTAssertTrue(waitForEnabled(restore))
        restore.tap()
        XCTAssertTrue(app.staticTexts["No lifetime purchase was found."].waitForExistence(timeout: 15))
        XCTAssertTrue(waitForEnabled(app.buttons["purchasePrimaryAction"]))
        XCTAssertFalse(app.staticTexts["Lifetime Access Active"].exists)
        screenshot("No purchase restore can be retried", app)
    }

    func testPurchasePersistsAcrossProcessRelaunchAndRefundRevokesAccess() async throws {
        let session = try commerceSession()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let app = launch()
        openPurchase(app)
        let purchase = app.buttons["purchasePrimaryAction"]
        XCTAssertTrue(waitForEnabled(purchase))
        XCTAssertTrue(purchase.label.contains("Unlock for"))
        purchase.tap()
        XCTAssertTrue(app.staticTexts["Lifetime Access Active"].waitForExistence(timeout: 15))
        let transaction = try XCTUnwrap(session.allTransactions().first)
        app.terminate()
        app.launchArguments.removeAll { $0 == "UITEST_RESET_DEMO" }
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 15))
        openPurchase(app)
        XCTAssertTrue(app.staticTexts["Lifetime Access Active"].waitForExistence(timeout: 15))
        try session.refundTransaction(identifier: transaction.identifier)
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForEnabled(purchase))
        XCTAssertFalse(app.staticTexts["Lifetime Access Active"].exists)
        screenshot("Refund removes lifetime access", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 15))
        openPurchase(app)
        XCTAssertTrue(waitForEnabled(app.buttons["purchasePrimaryAction"]))
        XCTAssertFalse(app.staticTexts["Lifetime Access Active"].exists)
    }

    func testPendingPurchaseSurvivesRecheckAndReopenThenApproves() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PAPERPATH_LOCAL_STOREKIT"] == "1",
            "Run the PaperPathCommerce scheme to activate the local StoreKit catalog."
        )
        let session = try SKTestSession(configurationFileNamed: "PaperPath")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = true
        defer {
            session.clearTransactions()
            session.resetToDefaultState()
        }

        let app = launch()
        app.buttons["settings"].tap()
        let account = app.buttons["settingsPurchase"]
        XCTAssertTrue(account.waitForExistence(timeout: 8))
        account.tap()
        let purchase = app.buttons["purchasePrimaryAction"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(purchase))
        XCTAssertTrue(purchase.label.contains("Unlock for"))
        screenshot("Purchase with StoreKit price", app)
        purchase.tap()

        let pending = app.buttons["purchaseCheckStatus"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(pending))
        pending.tap()
        XCTAssertTrue(waitForEnabled(pending))
        XCTAssertFalse(app.buttons["purchasePrimaryAction"].exists)
        screenshot("Purchase still awaiting approval after recheck", app)

        app.navigationBars["Verified Output Lifetime"].buttons["Done"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(pending))
        XCTAssertFalse(app.buttons["purchasePrimaryAction"].exists)

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        XCTAssertTrue(
            app.staticTexts["Lifetime Access Active"].waitForExistence(timeout: 15)
        )
        screenshot("Approved purchase unlocks without another payment", app)
    }
#endif

    func testSettingsPrivacyInformationAndActualVersion() throws {
        let app = launch()
        screenshot("Release home", app)
        app.buttons["settings"].tap()
        let privacy = app.buttons["settingsPrivacyInformation"]
        XCTAssertTrue(reveal(privacy, app))
        screenshot("Settings privacy entry", app)
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy & Data"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Documents and recognition"].exists)
        screenshot("Offline privacy information", app)
        XCTAssertTrue(reveal(app.staticTexts["Before sending a document"], app))
        app.navigationBars["Privacy & Data"].buttons["Done"].tap()
        let version = app.staticTexts["settingsAppVersion"]
        XCTAssertTrue(reveal(version, app))
        XCTAssertEqual(version.label, "PaperPath PDF · 1.1.0 (5)")
    }

    func testChinesePrivacyInformationAtStandardSize() throws {
        let app = launch(chinese: true)
        screenshot("Chinese home standard size", app)
        app.buttons["settings"].tap()
        let privacy = app.buttons["settingsPrivacyInformation"]
        XCTAssertTrue(reveal(privacy, app))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["隐私与数据"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["文件与数据，由你掌控"].exists)
        let backupDisclosure = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "PDF 不会备份")
        ).firstMatch
        XCTAssertTrue(reveal(backupDisclosure, app))
        screenshot("Chinese privacy and backup boundary standard size", app)
        XCTAssertTrue(reveal(app.staticTexts["分享文档之前"], app))
        screenshot("Chinese privacy last section standard size", app)
    }

    func testChinesePrivacyInformationAtAccessibilitySize() throws {
        let app = launch(chinese: true, largeText: true)
        screenshot("Chinese home accessibility", app)
        app.buttons["settings"].tap()
        let privacy = app.buttons["settingsPrivacyInformation"]
        XCTAssertTrue(reveal(privacy, app))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["隐私与数据"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["文件与数据，由你掌控"].exists)
        screenshot("Chinese privacy accessibility", app)
        XCTAssertTrue(reveal(app.staticTexts["分享文档之前"], app))
        screenshot("Chinese privacy last section accessibility", app)
    }

    private func launch(chinese: Bool = false, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_RESET_DEMO",
            "-AppleLanguages", chinese ? "(zh-Hans)" : "(en)",
            "-AppleLocale", chinese ? "zh_CN" : "en_US",
            "-app.language", chinese ? "zh-Hans" : "en",
            "-privacy.appLockEnabled", "NO",
            "-UIPreferredContentSizeCategoryName",
            largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 15))
        return app
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND enabled == true"),
                object: element
            )],
            timeout: 15
        ) == .completed
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        for _ in 0..<16 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
