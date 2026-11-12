import XCTest

@MainActor
final class HandoffWorkflowUITests: XCTestCase {
    func testReleaseScopeShowsSharingCheckWithoutExperimentalEntries() {
        verifyReleaseEntry()
    }

    func testChineseReleaseScopeShowsSharingCheckWithoutExperimentalEntries() {
        verifyReleaseEntry(chinese: true)
    }

    func testChineseLargeTextReleaseScopeShowsSharingCheckWithoutExperimentalEntries() {
        verifyReleaseEntry(chinese: true, largeText: true)
    }

    private func verifyReleaseEntry(chinese: Bool = false, largeText: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_WORKFLOW_FIXTURE", "UITEST_RESET_DEMO",
            "UITEST_HANDOFF_FIXTURE=\(UUID().uuidString)",
            "-app.language", chinese ? "zh-Hans" : "en",
            "-AppleLanguages", chinese ? "(zh-Hans)" : "(en)",
            "-AppleLocale", chinese ? "zh_CN" : "en_US",
            "-privacy.appLockEnabled", "NO",
            "-privacy.metadataSyncEnabled", "NO",
            "-UIPreferredContentSizeCategoryName",
            largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        ]
        app.launch()
        let sharingCheck = app.buttons["shareCheckOpen"]
        XCTAssertTrue(sharingCheck.waitForExistence(timeout: 15))
        XCTAssertTrue(sharingCheck.isHittable)
        XCTAssertFalse(app.buttons["handoffOpen"].exists)
        XCTAssertFalse(app.buttons["assistantOpen"].exists)
        sharingCheck.tap()
        XCTAssertTrue(app.buttons["shareCheckSample"].waitForExistence(timeout: 8))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Release sharing check entry"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }
}
