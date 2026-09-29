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
            NSPredicate(format: "label CONTAINS %@", "自动备份")
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
