import XCTest

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

    func testPaidDownloadHasNoTrialOrPurchaseFlow() throws {
        let app = launch()
        XCTAssertFalse(app.buttons["trialStatusBanner"].exists)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["settingsPurchase"].exists)
        XCTAssertFalse(app.buttons["trialStartAction"].exists)
        XCTAssertFalse(app.buttons["purchasePrimaryAction"].exists)
        XCTAssertTrue(reveal(app.buttons["settingsPrivacyInformation"], app))
        app.buttons["settingsPrivacyInformation"].tap()
        let paidDownload = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "one-time paid download")
        ).firstMatch
        XCTAssertTrue(reveal(paidDownload, app))
        screenshot("Paid download includes all tools", app)
    }


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
        XCTAssertTrue(version.label.hasPrefix("PaperPath PDF · 1.1.0 ("))
    }

    func testChinesePrivacyInformationAtStandardSize() throws {
        let app = launch(chinese: true)
        screenshot("Chinese home standard size", app)
        app.buttons["settings"].tap()
        let privacy = app.buttons["settingsPrivacyInformation"]
        XCTAssertTrue(reveal(privacy, app))
        privacy.tap()
        XCTAssertTrue(app.navigationBars["隐私与数据"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["支持离线使用"].exists)
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
        XCTAssertTrue(app.staticTexts["支持离线使用"].exists)
        screenshot("Chinese privacy accessibility", app)
        XCTAssertTrue(reveal(app.staticTexts["分享文档之前"], app))
        screenshot("Chinese privacy last section accessibility", app)
    }

    func testSupportStorageFailureCanCloseAndReopenWithoutResending() throws {
        let app = launch(extraArguments: ["UITEST_SUPPORT_SAVE_FAILURE"])
        app.buttons["settings"].tap()
        app.buttons["settingsFeedback"].tap()
        let retry = app.buttons["supportSaveConversationAgain"]
        XCTAssertTrue(reveal(retry, app))
        let submit = app.buttons["supportSubmit"]
        XCTAssertTrue(reveal(submit, app))
        XCTAssertFalse(submit.isEnabled)
        XCTAssertTrue(reveal(retry, app))
        retry.tap()
        XCTAssertTrue(app.staticTexts["supportError"].exists)
        let reference = "8C94C77A-37D1-4670-987D-C15D0E676A15"
        XCTAssertTrue(app.staticTexts[reference].exists)
        let close = app.buttons["supportCancel"]
        XCTAssertTrue(close.isEnabled)
        close.tap()
        let alert = app.alerts["Close feedback?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Keep Open"].tap()
        XCTAssertTrue(retry.exists)
        close.tap()
        app.alerts.buttons.matching(identifier: "supportClosePending").firstMatch.tap()
        XCTAssertTrue(app.buttons["settingsFeedback"].waitForExistence(timeout: 5))
        app.buttons["settingsFeedback"].tap()
        XCTAssertTrue(reveal(app.staticTexts[reference], app))
        XCTAssertTrue(reveal(submit, app))
        XCTAssertFalse(submit.isEnabled)
        XCTAssertTrue(reveal(retry, app))
        XCTAssertTrue(retry.isEnabled)
        screenshot("Support pending conversation retained after closing", app)
        app.buttons["supportCancel"].tap()
        app.alerts.buttons.matching(identifier: "supportClosePending").firstMatch.tap()
        XCTAssertTrue(app.buttons["settingsFeedback"].waitForExistence(timeout: 5))
    }

    func testSupportFormValidationAndDiscard() throws {
        try checkSupportForm(chinese: false, largeText: false, dark: false)
    }

    func testChineseSupportAtAccessibilitySize() throws {
        try checkSupportForm(chinese: true, largeText: true, dark: false)
    }

    func testSupportInDarkMode() throws {
        try checkSupportForm(chinese: false, largeText: false, dark: true)
    }

    private func checkSupportForm(chinese: Bool, largeText: Bool, dark: Bool) throws {
        let app = launch(chinese: chinese, largeText: largeText)
        // Set simulator appearance with `simctl ui <device> appearance dark`
        // before the dark-mode run; launch defaults do not change UIKit appearance.
        app.buttons["settings"].tap()
        // Feedback is immediately available in Settings and opens the native form directly.
        XCTAssertTrue(app.buttons["settingsFeedback"].waitForExistence(timeout: 5))
        app.buttons["settingsFeedback"].tap()
        let submit = app.buttons["supportSubmit"]
        screenshot("Support composer \(chinese) \(largeText) \(dark)", app)
        let email = app.textFields["supportEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("person@example.com")
        app.buttons["supportDismissKeyboard"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "supportTitle").firstMatch
        XCTAssertTrue(reveal(title, app))
        title.tap()
        title.typeText("Export issue")
        app.buttons["supportDismissKeyboard"].tap()
        let description = app.descendants(matching: .any).matching(identifier: "supportDescription").firstMatch
        XCTAssertTrue(reveal(description, app))
        description.tap()
        description.typeText("The export stops after selecting a destination.")
        app.buttons["supportDismissKeyboard"].tap()
        XCTAssertTrue(reveal(submit, app))
        XCTAssertTrue(submit.isEnabled)
        screenshot("Support ready to send \(chinese) \(largeText) \(dark)", app)
        // Do not create a real support ticket during UI testing.
        app.navigationBars.buttons[chinese ? "取消" : "Cancel"].tap()
        XCTAssertTrue(app.alerts[chinese ? "放弃反馈？" : "Discard feedback?"].waitForExistence(timeout: 5))
        app.alerts.buttons[chinese ? "放弃" : "Discard"].tap()
        XCTAssertTrue(app.buttons["settingsFeedback"].waitForExistence(timeout: 5))
    }

    private func launch(chinese: Bool = false, largeText: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_RESET_DEMO", "UITEST_WORKFLOW_FIXTURE",
            "-AppleLanguages", chinese ? "(zh-Hans)" : "(en)",
            "-AppleLocale", chinese ? "zh_CN" : "en_US",
            "-app.language", chinese ? "zh-Hans" : "en",
            "-privacy.appLockEnabled", "NO",
            "-UIPreferredContentSizeCategoryName",
            largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        ]
        app.launchArguments += extraArguments
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
