import XCTest
import UIKit

@MainActor
final class PaperPathUITests: XCTestCase {
    private func selectProfessionalMode(_ mode: String, chinese: Bool = false, in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["pdfWorkspace"].firstMatch.waitForExistence(timeout: 10))
        let menu = app.buttons["workspaceModeMenu"]
        if menu.exists {
            menu.tap()
            app.buttons["workspaceMode-\(mode)"].tap()
        } else {
            let title = mode == "read" ? (chinese ? "阅读" : "Read") : (chinese ? "页面" : "Pages")
            let button = app.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
    }

    func testProfessionalFavorites() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO", "-workspace.toolMode", "pages"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "documentRow-", "Project handoff"
        )).firstMatch
        XCTAssertTrue(reveal(row, in: app, maxSwipes: 8))
        row.tap()
        if app.buttons["deskOpenDocument"].waitForExistence(timeout: 2) { app.buttons["deskOpenDocument"].tap() }
        selectProfessionalMode("pages", in: app)
        app.buttons["documentToolsAction"].tap()
        let search = app.textFields["documentToolSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Find")
        let remove = app.buttons["Remove Find from favorites"]
        if remove.exists { remove.tap() }
        let star = app.buttons["Add Find to favorites"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        app.buttons["Clear tool search"].tap()
        let favorites = app.descendants(matching: .any)["favoriteDocumentTools"].firstMatch
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "documentTool-find").count, 1)
        addScreenshot(named: "Favorite tool without duplicates", app: app)
        app.buttons["documentTool-find"].tap()
        XCTAssertTrue(app.navigationBars["Find"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testProfessionalOCRCopyFlow() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_POLISH_OCR", "-privacy.hideLibraryPreviews", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "documentRow-", "Polish scan"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(reveal(row, in: app, maxSwipes: 12))
        row.tap()
        if app.buttons["deskOpenDocument"].waitForExistence(timeout: 2) {
            app.buttons["deskOpenDocument"].tap()
        }
        selectProfessionalMode("pages", in: app)
        app.buttons["documentToolsAction"].tap()
        let search = app.textFields["documentToolSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("OCR")
        let recognize = app.buttons["documentTool-recognize"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 5))
        guard recognize.isEnabled else {
            XCTFail("The image-only scan should support recognition")
            app.terminate()
            return
        }
        recognize.tap()
        if app.buttons["startOCR"].waitForExistence(timeout: 4) {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == YES"), object: app.buttons["startOCR"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            app.buttons["startOCR"].tap()
        }
        let copy = app.buttons["recognizedTextCopyMenu"]
        XCTAssertTrue(copy.waitForExistence(timeout: 90))
        copy.tap()
        app.buttons["Copy all recognized text"].tap()
        XCTAssertTrue(app.staticTexts["Recognized text copied locally for five minutes"].waitForExistence(timeout: 5))
        let textSearch = app.searchFields["Search recognized text"]
        textSearch.tap()
        textSearch.typeText("Delivery")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        let filtered = app.buttons["copyFilteredRecognizedPages"]
        XCTAssertTrue(filtered.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(filtered, in: app, maxSwipes: 8))
        XCTAssertTrue(filtered.isEnabled)
        filtered.tap()
        XCTAssertTrue(app.staticTexts["Recognized text copied locally for five minutes"].waitForExistence(timeout: 5))
        addScreenshot(named: "Recognized text filtered copy", app: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        app.terminate()
    }

    func testProfessionalPickerFlow() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO", "-privacy.hideLibraryPreviews", "YES"]
        for key in ["PICKER_DEBUG_URL", "PICKER_DEBUG_RUN"] {
            app.launchEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(title: "Tools", identifier: "workspaceLane-tasks", in: app)
        let tool = app.buttons["quickTool-safeShare"]
        XCTAssertTrue(reveal(tool, in: app, maxSwipes: 12))
        tool.tap()
        if ProcessInfo.processInfo.environment["PICKER_DEBUG_RUN"] == nil {
            let search = app.searchFields["Search documents"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("Project handoff")
            if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
            addScreenshot(named: "Professional document picker", app: app)
        }
        let document = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "quickTaskDocument-", "Project handoff"
        )).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        let center = document.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        if ProcessInfo.processInfo.environment["PICKER_DEBUG_RUN"] == "pre-fix",
           !app.buttons["safeShareButton"].waitForExistence(timeout: 3) {
            document.staticTexts["Project handoff"].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["safeShareButton"].waitForExistence(timeout: 15))
        addScreenshot(named: "Professional picker handoff", app: app)
        app.terminate()
    }

    func testProfessionalReadingFlow() throws {
        for (large, chinese) in [(false, false), (true, false), (false, true)] {
            let app = makeApp()
            let done = chinese ? "完成" : "Done"
            let suffix = chinese ? " Chinese" : large ? " accessibility" : ""
            if chinese {
                app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans"]
            }
            app.launchArguments += [
                "UITEST_RESET_DEMO", "-privacy.hideLibraryPreviews", "NO",
                "-workspace.toolMode", "read",
                "-focusReader.continuous", "NO"
            ]
            if large {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(waitForLibrary(in: app))
            selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
            let row = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-", "Project handoff"
            )).firstMatch
            XCTAssertTrue(reveal(row, in: app, maxSwipes: 8))
            row.tap()
            if app.buttons["deskOpenDocument"].waitForExistence(timeout: 2) {
                app.buttons["deskOpenDocument"].tap()
            }
            selectProfessionalMode("read", chinese: chinese, in: app)
            app.buttons["readingOptions"].tap()
            app.buttons["readingSettings"].tap()
            XCTAssertTrue(app.buttons["readingTheme-sepia"].waitForExistence(timeout: 5))
            app.buttons["readingTheme-sepia"].tap()
            let reset = app.buttons["resetReadingSettings"]
            XCTAssertTrue(reveal(reset, in: app, maxSwipes: 8))
            reset.tap()
            addScreenshot(named: "Reading settings" + suffix, app: app)
            app.buttons[done].firstMatch.tap()
            app.buttons["readingOptions"].tap()
            app.buttons["readingBookmarks"].tap()
            let input = app.textFields["navigationPageInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText("2")
            addScreenshot(named: "Navigation" + suffix, app: app)
            app.buttons["navigationGoToPage"].tap()
            XCTAssertTrue(app.buttons["readingOptions"].waitForExistence(timeout: 5))
            app.buttons["readingOptions"].tap()
            app.buttons["readingFocusReader"].tap()
            let position = app.staticTexts["focusReaderPosition"]
            XCTAssertTrue(position.waitForExistence(timeout: 15))
            app.buttons["focusReaderPrevious"].tap()
            XCTAssertTrue(app.buttons["focusReaderNext"].isEnabled)
            let original = position.value as? String
            XCTAssertNotNil(original)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(position.waitForExistence(timeout: 15))
            XCTAssertEqual(position.value as? String, original)
            addScreenshot(named: "Focus reader" + suffix, app: app)
            app.buttons[done].firstMatch.tap()
            selectProfessionalMode("pages", chinese: chinese, in: app)
            let organizer = app.buttons["workspaceTool-organize"]
            XCTAssertTrue(organizer.waitForExistence(timeout: 5))
            organizer.tap()
            XCTAssertTrue(app.buttons["organizerGoToPage"].waitForExistence(timeout: 5))
            app.buttons["organizerGoToPage"].tap()
            app.alerts.textFields.firstMatch.typeText("2")
            app.alerts.buttons[chinese ? "前往" : "Go"].tap()
            let second = app.buttons["organizerPage-1"]
            XCTAssertTrue(reveal(second, in: app, maxSwipes: 6))
            addScreenshot(named: "Page organizer" + suffix, app: app)
            app.buttons[chinese ? "关闭" : "Close"].firstMatch.tap()
            app.buttons["documentToolsAction"].tap()
            let search = app.textFields["documentToolSearchField"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            addScreenshot(named: "Document tools" + suffix, app: app)
            search.tap()
            search.typeText(chinese ? "查找" : "Find")
            let find = app.buttons["documentTool-find"]
            XCTAssertTrue(find.waitForExistence(timeout: 5))
            find.tap()
            XCTAssertTrue(app.navigationBars[chinese ? "查找" : "Find"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    private func revealOfficeControl(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let footer = app.otherElements["officeResultActions"].firstMatch
        for _ in 0..<12 {
            let top = app.navigationBars["Convert PDF"].frame.maxY + 12
            let bottom = footer.exists ? footer.frame.minY - 16 : app.frame.maxY - 120
            if element.exists, element.isHittable,
               element.frame.midY >= top, element.frame.midY <= bottom {
                return true
            }
            let down = element.exists && element.frame.midY < top
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: down ? top + 40 : bottom - 40))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(
                    CGVector(dx: app.frame.midX, dy: down ? bottom - 40 : top + 40)
                ))
        }
        return false
    }

    private func waitForOfficeTablePixels(_ preview: XCUIElement) {
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let image = preview.screenshot().image.cgImage else { return false }
            let width = 320, height = 180
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let rows = pixels.withUnsafeMutableBytes { bytes -> Int in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return 0 }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let data = bytes.bindMemory(to: UInt8.self)
                return (10..<170).filter { y in
                    let darkPixels = (8..<312).filter { x in
                        let i = (y * width + x) * 4
                        return data[i] < 170 && data[i + 1] < 170 && data[i + 2] < 170
                    }.count
                    return darkPixels > 15 && darkPixels < 230
                }.count
            }
            return rows > 28
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    }

    func testNativeWorkbenchHiddenPreview() throws {
        let app = makeApp()
        // #region debug-point D:ipad-notice-hit
        for key in ["NOTICE_DEBUG_URL", "NOTICE_DEBUG_RUN"] {
            app.launchEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        // #endregion
        app.launchArguments += [
            "UITEST_OFFICE_CORPUS_RESULT",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "YES"
        ]
        app.launch()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 20))
        selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
        // #region debug-point D:ipad-notice-hit-search
        if ProcessInfo.processInfo.environment["NOTICE_DEBUG_RUN"] == "without-search" {
            let more = app.buttons["moreOfficeResults"]
            if reveal(more, in: app, maxSwipes: 6) { more.tap() }
        } else {
            let search = app.searchFields.firstMatch
            search.tap()
            search.typeText("ConditionalFormattingSamples")
            if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        }
        // #endregion
        let output = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "officeResult-", "ConditionalFormattingSamples")).firstMatch
        XCTAssertTrue(reveal(output, in: app, maxSwipes: 12))
        output.tap()
        let preview = app.descendants(matching: .any)["officeOutputPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.value as? String, "Preview hidden")
        XCTAssertFalse(app.buttons["officeOpenOutputPreview"].isEnabled)
        addScreenshot(named: "Native hidden output preview", app: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        addScreenshot(named: "Native hidden preview after background", app: app)
        let summary = app.otherElements["officeNoticeDetails-spreadsheetTextOnly"].buttons.firstMatch
        XCTAssertTrue(reveal(summary, in: app, maxSwipes: 8))
        summary.tap()
        XCTAssertTrue(app.descendants(matching: .any)["officeNotice-spreadsheetTextOnly"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testNativeWorkbenchDocumentFlow() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_OFFICE_CORPUS_RESULT",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "NO",
            "-workspace.toolMode", "read"
        ]
        app.launch()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 20))
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "documentRow-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        addScreenshot(named: "Native library", app: app)
        row.tap()
        let open = app.buttons["deskOpenDocument"]
        if open.waitForExistence(timeout: 2) { open.tap() }
        let pdf = app.descendants(matching: .any)["pdfWorkspace"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))
        let read = app.buttons["workspaceModeMenu"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(pdf.frame.height / app.frame.height, 0.5)
        addScreenshot(named: "Native reader", app: app)
        app.buttons["enterFocusReading"].tap()
        XCTAssertTrue(app.buttons["exitImmersiveReading"].waitForExistence(timeout: 5))
        addScreenshot(named: "Native focused reader", app: app)
        app.buttons["exitImmersiveReading"].tap()
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        app.buttons["workspaceMode-annotate"].tap()
        XCTAssertTrue(app.buttons["workspaceTool-highlight"].waitForExistence(timeout: 5))
        addScreenshot(named: "Native annotation tools", app: app)
        app.terminate()
    }

    func testNativeWorkbenchChineseLayouts() throws {
        for largeType in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                "-app.language", "zh-Hans",
                "-UIPreferredContentSizeCategoryName",
                largeType ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
                "UITEST_OFFICE_CORPUS_RESULT",
                "-experience.onboardingCompleted.v4", "YES",
                "-privacy.hideLibraryPreviews", "NO",
                "-workspace.toolMode", "read"
            ]
            app.launch()
            let documents = app.buttons["workspaceLane-home"].firstMatch
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 20))
            if documents.exists {
                documents.tap()
            } else {
                app.buttons["工作区"].firstMatch.tap()
                let option = app.buttons["文档"].firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 5))
                option.tap()
            }
            let row = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "documentRow-"
            )).firstMatch
            XCTAssertTrue(reveal(row, in: app, maxSwipes: 8))
            addScreenshot(named: largeType ? "Chinese library accessibility" : "Chinese library", app: app)
            row.tap()
            let open = app.buttons["deskOpenDocument"]
            if open.waitForExistence(timeout: 2) {
                addScreenshot(named: largeType ? "Chinese library focused accessibility" : "Chinese library focused", app: app)
                open.tap()
            }
            let pdf = app.descendants(matching: .any)["pdfWorkspace"].firstMatch
            XCTAssertTrue(pdf.waitForExistence(timeout: 10))
            let mode = app.buttons["workspaceModeMenu"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            if !app.buttons["enterFocusReading"].exists {
                mode.tap()
                app.buttons["workspaceMode-read"].tap()
            }
            XCTAssertTrue(app.buttons["enterFocusReading"].isHittable)
            addScreenshot(named: largeType ? "Chinese reader accessibility" : "Chinese reader", app: app)
            app.buttons["enterFocusReading"].tap()
            XCTAssertTrue(app.buttons["exitImmersiveReading"].waitForExistence(timeout: 5))
            app.buttons["exitImmersiveReading"].tap()
            app.terminate()
        }
    }

    func testNativeWorkbenchPDFResults() throws {
        let setup = try openVerifiedDeliveryReceipt(fromLibrary: true)
        setup.terminate()
        for largeType in [false, true] {
            let app = makeApp()
            if largeType {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL"
                ]
            }
            app.launch()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 20))
            selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
            let document = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "resultDocument-"
            )).firstMatch
            XCTAssertTrue(reveal(document, in: app, maxSwipes: 8))
            let receipt = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "resultReceipt-"
            )).firstMatch
            XCTAssertTrue(reveal(receipt, in: app, maxSwipes: 8))
            XCTAssertGreaterThanOrEqual(receipt.frame.height, 44)
            addScreenshot(named: largeType ? "Native PDF results accessibility" : "Native PDF results", app: app)
            receipt.tap()
            XCTAssertTrue(app.navigationBars["Delivery receipt"].waitForExistence(timeout: 8))
            app.terminate()
        }
    }

    func testNativeWorkbenchChineseOutput() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-app.language", "zh-Hans",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "UITEST_OFFICE_CORPUS_RESULT",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 20))
        app.buttons["workspaceLane-outputs"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("ConditionalFormattingSamples")
        if app.keyboards.buttons["搜索"].exists { app.keyboards.buttons["搜索"].tap() }
        let output = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "officeResult-"
        )).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        addScreenshot(named: "Chinese results", app: app)
        output.tap()
        let preview = app.descendants(matching: .any)["officeOutputPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "输出预览已就绪"), object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        waitForOfficeTablePixels(preview)
        addScreenshot(named: "Chinese output preview", app: app)
        app.terminate()
    }

    func testOfficeCorpusNoticesSurviveReopening() throws {
        let app = makeApp()
        // #region debug-point C:ipad-notice-hit
        for key in ["NOTICE_DEBUG_URL", "NOTICE_DEBUG_RUN"] {
            app.launchEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        // #endregion
        app.launchArguments += [
            "UITEST_OFFICE_CORPUS_RESULT",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "NO",
            "-library.workspaceLane", "deliver"
        ]
        for largeType in [false, true] {
            if largeType {
                app.launchArguments += [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL"
                ]
            }
            app.launch()
            XCTAssertTrue(waitForLibrary(in: app))
            selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 20))
            search.tap()
            search.typeText("ConditionalFormattingSamples")
            if app.keyboards.buttons["Search"].exists {
                app.keyboards.buttons["Search"].tap()
            }
            let output = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "officeResult-")
            ).firstMatch
            XCTAssertTrue(output.waitForExistence(timeout: 10))
            addScreenshot(named: largeType ? "Native results accessibility" : "Native results", app: app)
            output.tap()
            let preview = app.descendants(matching: .any)["officeOutputPreview"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 15))
            if !largeType {
                let loaded = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Output preview ready"), object: preview
                )
                XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed)
                // #region debug-point C:ipad-notice-hit-lifecycle
                if ProcessInfo.processInfo.environment["NOTICE_DEBUG_RUN"] != "no-background" {
                    XCUIDevice.shared.press(.home)
                    app.activate()
                }
                // #endregion
                let reloaded = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Output preview ready"), object: preview
                )
                XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 30), .completed)
                waitForOfficeTablePixels(preview)
            }
            addScreenshot(named: largeType ? "Native output accessibility" : "Native output preview", app: app)
            let summary = app.otherElements["officeNoticeDetails-spreadsheetTextOnly"].buttons.firstMatch
            XCTAssertTrue(revealOfficeControl(summary, in: app))
            // #region debug-point C:ipad-notice-hit
            if let endpoint = ProcessInfo.processInfo.environment["NOTICE_DEBUG_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "ipad-notice-hit", "runId": ProcessInfo.processInfo.environment["NOTICE_DEBUG_RUN"] ?? "pre-fix", "hypothesisId": "C", "msg": "[DEBUG] Test tap", "data": ["frame": "\(summary.frame)", "preview": "\(preview.frame)"]]); URLSession.shared.dataTask(with: request).resume() }
            // #endregion
            summary.tap()
            let notice = app.descendants(matching: .any)["officeNotice-spreadsheetTextOnly"].firstMatch
            // #region debug-point C:ipad-notice-hit-offset
            if ProcessInfo.processInfo.environment["NOTICE_DEBUG_RUN"] == "offset", !notice.waitForExistence(timeout: 1) {
                summary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: 0, dy: 42)).tap()
            }
            // #endregion
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            XCTAssertTrue(notice.label.contains("Charts, images and conditional formatting"))
            XCTAssertTrue(revealOfficeControl(notice, in: app))
            addScreenshot(named: largeType ? "Office notice text accessibility" : "Office notice text standard", app: app)
            XCTAssertTrue(revealOfficeControl(summary, in: app))
            summary.tap()
            let emptySummary = app.otherElements["officeNoticeDetails-pagesWithoutText"].buttons.firstMatch
            XCTAssertTrue(revealOfficeControl(emptySummary, in: app))
            emptySummary.tap()
            let emptyPages = app.descendants(matching: .any)["officeNotice-pagesWithoutText"].firstMatch
            XCTAssertTrue(reveal(emptyPages, in: app, maxSwipes: 8))
            XCTAssertTrue(emptyPages.label.contains("7, 9, 17, 19, 21, 23, 25, 30, 33, 36"))
            XCTAssertTrue(revealOfficeControl(emptySummary, in: app))
            emptySummary.tap()
            let checks = app.buttons["officeConversionChecks"].firstMatch
            XCTAssertTrue(revealOfficeControl(checks, in: app))
            addScreenshot(named: largeType ? "Office notices accessibility" : "Office notices standard", app: app)
            checks.tap()
            XCTAssertTrue(app.navigationBars["Conversion details"].waitForExistence(timeout: 5))
            let detailNotice = app.descendants(matching: .any)["officeNotice-spreadsheetTextOnly"].firstMatch
            XCTAssertTrue(detailNotice.exists)
            XCTAssertLessThan(detailNotice.frame.minY, app.frame.height * 0.5)
            addScreenshot(named: largeType ? "Office checks accessibility" : "Office checks standard", app: app)
            app.terminate()
        }
    }

    func testLibraryAndWorkspaceSmokeFlow() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-AppleInterfaceStyle",
            "Dark"
        ]
        configureFreezeTracing(for: app)
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Home",
            identifier: "workspaceLane-home",
            in: app
        )
        let brandTitle = app.descendants(matching: .any)[
            "libraryBrandTitle"
        ]
        XCTAssertTrue(brandTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(
            brandTitle.label,
            "PaperPath: Secure PDF Studio"
        )
        XCTAssertTrue(
            app.buttons["homePrimaryAction"].waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            app.buttons["homePrimaryAction"].label,
            "Fill Form"
        )
        XCTAssertTrue(app.otherElements["libraryDocumentsSection"].exists)
        selectWorkspaceLane(
            title: "Tasks",
            identifier: "workspaceLane-tasks",
            in: app
        )

        let combineButton = app.buttons["quickTool-mergePDFs"]
        XCTAssertTrue(combineButton.waitForExistence(timeout: 3))
        for identifier in [
            "taskPackage-prepareToSend",
            "taskPackage-convertForWork",
            "taskPackage-fixPages"
        ] {
            XCTAssertTrue(app.buttons[identifier].exists)
        }
        let allTaskPaths = app.buttons["toggleAllTaskPaths"].firstMatch
        XCTAssertTrue(reveal(allTaskPaths, in: app, maxSwipes: 3))
        allTaskPaths.tap()
        XCTAssertFalse(app.buttons["taskPackage-makeSearchable"].exists)
        XCTAssertTrue(app.buttons["taskPackage-compressForEmail"].exists)
        let toolsSection = app.otherElements["pdfToolsSection"].firstMatch
        XCTAssertTrue(reveal(toolsSection, in: app, maxSwipes: 4))
        let allTools = app.buttons["Show all PDF tools"]
        XCTAssertTrue(allTools.waitForExistence(timeout: 3))
        allTools.tap()
        XCTAssertTrue(
            app.buttons["Show quick PDF tools only"]
                .waitForExistence(timeout: 3)
        )
        addScreenshot(named: "PaperPath Library Default", app: app)
        combineButton.tap()
        XCTAssertTrue(
            app.navigationBars["Merge PDFs"]
                .waitForExistence(timeout: 5)
        )
        addScreenshot(named: "PaperPath Combine", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            app.searchFields.firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            reveal(
                app.buttons["quickTool-imagesToPDF"],
                in: app,
                maxSwipes: 4
            )
        )

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("August invoice")
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(
            reveal(app.staticTexts["August invoice"], in: app, maxSwipes: 5)
        )
        XCTAssertFalse(app.staticTexts["Site review report"].exists)
        search.buttons.firstMatch.tap()
        addScreenshot(named: "PaperPath Library", app: app)

        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(
            reveal(app.staticTexts["Project handoff"], in: app, maxSwipes: 5)
        )

        let documentButton = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(documentButton.exists)
        documentButton.tap()

        let workspace = app.otherElements["pdfWorkspace"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["documentContext"].exists)
        XCTAssertTrue(
            app.buttons["workspaceNextAction"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.otherElements["recentDocumentTabs"].exists)
        XCTAssertFalse(app.otherElements["workspaceCommandRail"].exists)

        addScreenshot(named: "PaperPath Workspace", app: app)

        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"]
                .waitForExistence(timeout: 5)
        )
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("shrink")
        XCTAssertTrue(
            app.buttons["documentTool-compress"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["documentTool-sign"].exists)
        addScreenshot(named: "PaperPath Tool Search", app: app)
        let clearToolSearch = app.buttons["Clear tool search"]
            .firstMatch
        XCTAssertTrue(clearToolSearch.waitForExistence(timeout: 3))
        clearToolSearch.tap()
        XCTAssertFalse(clearToolSearch.waitForExistence(timeout: 1))

        let toolsNavigation = app.navigationBars["Tools"]
        let closeTools = toolsNavigation.buttons["Close"].firstMatch
        XCTAssertTrue(closeTools.waitForExistence(timeout: 3))
        XCTAssertTrue(closeTools.isHittable)
        let closeFrame = closeTools.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(
                CGVector(
                    dx: closeFrame.midX,
                    dy: closeFrame.midY
                )
            )
            .tap()
        let toolsClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: toolsNavigation
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [toolsClosed], timeout: 5),
            .completed
        )

        let findButton = firstHittableButton(
            identifier: "workspaceFindAction",
            in: app,
            timeout: 3
        )
        XCTAssertTrue(findButton.isHittable)
        tapCenter(findButton)
        let findNavigation = app.navigationBars["Find"]
        XCTAssertTrue(findNavigation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Find in document"].exists)
        addScreenshot(named: "PaperPath Document Find", app: app)
        let closeFind = findNavigation.buttons["Close"].firstMatch
        XCTAssertTrue(closeFind.waitForExistence(timeout: 3))
        closeFind.tap()
        XCTAssertFalse(findNavigation.waitForExistence(timeout: 1))

        app.buttons["Pages"].tap()
        XCTAssertTrue(
            app.navigationBars["Organize pages"].waitForExistence(timeout: 5)
        )
        let selectPages = app.buttons["selectOrganizerPages"]
        XCTAssertTrue(selectPages.waitForExistence(timeout: 3))
        selectPages.tap()
        app.buttons["pageSelectionMenu"].tap()
        app.buttons["All Pages"].tap()
        addScreenshot(named: "PaperPath Page Selection", app: app)
        let pageActions = app.buttons["pageSelectionActions"]
        XCTAssertTrue(pageActions.waitForExistence(timeout: 3))
        pageActions.tap()
        let extract = app.buttons["Extract to New PDF"].firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 3))
        extract.tap()
        XCTAssertTrue(
            app.staticTexts["Project handoff - extracted pages"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        addScreenshot(named: "PaperPath Extracted Copy", app: app)
    }

    func testDocumentFindSearchNavigationAndHistory() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_PREPARE_FIND_INDEX"
        ]
        app.launch()

        let librarySearch = librarySearchField(in: app)
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 15))
        librarySearch.tap()
        librarySearch.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["Find"].tap()
        XCTAssertTrue(
            app.navigationBars["Find"].waitForExistence(timeout: 5)
        )
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("local")

        let firstResult = app.buttons["documentFindResult-0"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 5))
        app.keyboards.buttons["Search"].tap()
        XCTAssertTrue(
            app.otherElements["documentFindNavigator"].exists
        )
        let next = app.buttons["documentFindNext"]
        XCTAssertTrue(next.exists)
        next.tap()

        search.tap()
        let clearText = app.buttons["Clear text"].firstMatch
        XCTAssertTrue(clearText.waitForExistence(timeout: 3))
        clearText.tap()
        let history = app.buttons["documentFindHistory-local"]
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        history.tap()
        XCTAssertTrue(firstResult.waitForExistence(timeout: 5))

        app.buttons["documentFindViewPDF"].tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )
    }

    func testScanReviewSelectionCropAndUndo() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_OPEN_SCAN_REVIEW"
        ]
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Review captured pages"]
                .waitForExistence(timeout: 8)
        )
        let undo = app.buttons["scanUndo"]
        XCTAssertTrue(undo.exists)
        XCTAssertFalse(undo.isEnabled)

        let rotate = app.buttons[
            "scanPageAction-Rotate Clockwise"
        ]
        XCTAssertTrue(rotate.waitForExistence(timeout: 3))
        rotate.tap()
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: undo
        )
        waitForExpectations(timeout: 3)
        undo.tap()
        expectation(
            for: NSPredicate(format: "enabled == false"),
            evaluatedWith: undo
        )
        waitForExpectations(timeout: 3)

        let selectPages = app.buttons["scanSelectPages"]
        XCTAssertTrue(selectPages.waitForExistence(timeout: 3))
        selectPages.tap()
        let secondPage = app.buttons["scanThumbnail-1"]
        XCTAssertTrue(secondPage.waitForExistence(timeout: 3))
        secondPage.tap()
        XCTAssertEqual(secondPage.value as? String, "Selected")

        let rotateSelected = app.buttons[
            "scanPageAction-Rotate Selected"
        ]
        XCTAssertTrue(rotateSelected.waitForExistence(timeout: 3))
        rotateSelected.tap()
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertFalse(undo.isEnabled)

        app.buttons["scanSelectPages"].tap()
        let adjustCrop = app.buttons["scanAdjustCrop"]
        XCTAssertTrue(adjustCrop.waitForExistence(timeout: 3))
        adjustCrop.tap()
        XCTAssertTrue(
            app.buttons["scanApplyCrop"].waitForExistence(timeout: 3)
        )
        app.buttons["scanCancelCrop"].tap()
        XCTAssertTrue(adjustCrop.waitForExistence(timeout: 3))
    }

    func testStoppingScanCreationRestoresReviewedDraft() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_OPEN_SCAN_REVIEW",
            "UITEST_DELAY_SCAN_CREATION"
        ]
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Review captured pages"]
                .waitForExistence(timeout: 8)
        )
        let blackAndWhite = app.buttons[
            "scanEnhancement-blackAndWhite"
        ]
        let enhancementPicker = app.scrollViews[
            "scanEnhancementPicker"
        ]
        XCTAssertTrue(enhancementPicker.waitForExistence(timeout: 3))
        enhancementPicker.swipeLeft()
        XCTAssertTrue(blackAndWhite.waitForExistence(timeout: 3))
        blackAndWhite.tap()
        XCTAssertTrue(blackAndWhite.isSelected)

        let save = app.buttons["scanSave"]
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: save
        )
        waitForExpectations(timeout: 5)
        save.tap()

        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()
        XCTAssertTrue(
            app.navigationBars["Review captured pages"]
                .waitForExistence(timeout: 5)
        )

        let restoredBlackAndWhite = app.buttons[
            "scanEnhancement-blackAndWhite"
        ]
        let restoredEnhancementPicker = app.scrollViews[
            "scanEnhancementPicker"
        ]
        XCTAssertTrue(
            restoredEnhancementPicker.waitForExistence(timeout: 3)
        )
        restoredEnhancementPicker.swipeLeft()
        XCTAssertTrue(
            restoredBlackAndWhite.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(restoredBlackAndWhite.isSelected)
        XCTAssertTrue(app.buttons["scanSave"].isEnabled)
    }

    func testQuickCompressToolOpensRequestedOperation() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Tasks",
            identifier: "workspaceLane-tasks",
            in: app
        )
        XCTAssertTrue(
            app.buttons["taskPackage-prepareToSend"]
                .waitForExistence(timeout: 3)
        )

        let compress = app.buttons["quickTool-compressPDF"]
        XCTAssertTrue(reveal(compress, in: app, maxSwipes: 6))
        compress.tap()

        XCTAssertTrue(
            app.navigationBars["Compress PDF"].waitForExistence(timeout: 5)
        )
        let document = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "batchCompressionDocument-"
            )
        ).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Project handoff")
        ).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        let action = app.buttons["batchCompressionAction"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertTrue(action.isEnabled)
        XCTAssertEqual(action.label, "Compress 1 PDF")
    }

    func testRedactionModeHasStablePrimaryActionAndExplicitExit()
        throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("August invoice")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "August invoice")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        openDocumentTools(in: app)
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("redact")
        let redactTool = app.buttons["documentTool-redact"]
        XCTAssertTrue(redactTool.waitForExistence(timeout: 3))
        redactTool.tap()

        let cancel = app.buttons["cancelRedactionMode"]
        let apply = app.buttons["applyRedactionSelection"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(apply.exists)
        XCTAssertFalse(app.buttons["workspaceNextAction"].exists)

        cancel.tap()
        XCTAssertTrue(
            app.buttons["workspaceNextAction"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(cancel.exists)
        XCTAssertFalse(apply.exists)
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
    }

    func testCompareVersionsUsesClearLocalWorkflow() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()

        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )
        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"]
                .waitForExistence(timeout: 5)
        )
        selectAllDocumentTools(in: app)
        let compare = app.buttons["documentTool-compare"]
        XCTAssertTrue(reveal(compare, in: app, maxSwipes: 6))
        compare.tap()

        XCTAssertTrue(
            app.navigationBars["Compare Versions"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["BASE PDF"].exists)
        XCTAssertTrue(app.staticTexts["COMPARE WITH"].exists)
        XCTAssertTrue(app.staticTexts["August invoice"].exists)
        let compareButton = app.buttons["compareVersionsButton"]
        XCTAssertTrue(compareButton.exists)
        XCTAssertTrue(compareButton.isEnabled)
        addScreenshot(named: "PaperPath Compare Versions", app: app)

        compareButton.tap()
        let resultTitle = app.staticTexts["COMPARISON RESULT"]
        XCTAssertTrue(resultTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 changed pages"].exists)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "changePage-"
                )
            ).count,
            2
        )
        addScreenshot(named: "PaperPath Compare Result", app: app)

        let changedPage = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "changePage-",
                "-revised"
            )
        ).firstMatch
        XCTAssertTrue(reveal(changedPage, in: app, maxSwipes: 3))
        tapCenter(changedPage)
        XCTAssertTrue(
            app.navigationBars["Compare Versions"]
                .waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )
        let openedDocumentTitle = workspaceDocumentTitle(in: app)
        XCTAssertTrue(openedDocumentTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(
            openedDocumentTitle.label,
            "August invoice"
        )
        addScreenshot(named: "PaperPath Compare Page Direct", app: app)
    }

    func testVerifyAndShareShowsOutcomeBeforeTechnicalEvidence()
        throws {
        let app = try openVerifiedDeliveryReceipt()
        XCTAssertTrue(app.staticTexts["FINAL COPY CHECKED"].exists)
        let share = app.buttons["shareVerifiedOutput"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        XCTAssertEqual(share.label, "Share checked PDF")
        XCTAssertTrue(app.buttons["shareDeliveryPackage"].exists)
        let decision = app.staticTexts["Delivery decision"]
        XCTAssertTrue(decision.exists)
        XCTAssertLessThan(decision.frame.minY, share.frame.minY)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Verification details"
                )
            ).firstMatch.exists
        )
        addScreenshot(named: "PaperPath Verified Outcome", app: app)

        share.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Share with 1 warning"
                )
            ).firstMatch.waitForExistence(timeout: 3)
        )
        let reviewWarning = app.buttons["reviewWarningDetails"]
            .firstMatch
        XCTAssertTrue(reviewWarning.waitForExistence(timeout: 3))
        addScreenshot(
            named: "PaperPath Warning Share Confirmation",
            app: app
        )
        reviewWarning.tap()
        XCTAssertFalse(app.buttons["confirmWarningShare"].exists)

        expandVerificationDetails(in: app)
        let protectMilestone = app.buttons[
            "protectDeliveryMilestone"
        ]
        XCTAssertTrue(
            reveal(protectMilestone, in: app, maxSwipes: 6)
        )
        protectMilestone.tap()
        let linkedMilestone = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openLinkedMilestone-"
            )
        ).firstMatch
        XCTAssertTrue(linkedMilestone.waitForExistence(timeout: 8))
        addScreenshot(
            named: "PaperPath Receipt Version Evidence",
            app: app
        )
        linkedMilestone.tap()

        XCTAssertTrue(
            app.navigationBars["Version History"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Verified output"].exists)
        addScreenshot(
            named: "PaperPath Linked Milestone",
            app: app
        )
        let linkedReceipt = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openMilestoneReceipt-"
            )
        ).firstMatch
        XCTAssertTrue(reveal(linkedReceipt, in: app, maxSwipes: 6))
        linkedReceipt.tap()
        XCTAssertTrue(
            app.navigationBars["Delivery receipt"]
                .firstMatch
                .waitForExistence(timeout: 8)
        )
    }

    func testDeliveryEvidenceRemainsReachableAtAccessibilityXXXL()
        throws {
        let setupApp = try openVerifiedDeliveryReceipt()
        expandVerificationDetails(in: setupApp)
        let protectMilestone = setupApp.buttons[
            "protectDeliveryMilestone"
        ]
        XCTAssertTrue(
            reveal(protectMilestone, in: setupApp, maxSwipes: 8)
        )
        protectMilestone.tap()
        let protectedMilestone = setupApp.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openLinkedMilestone-"
            )
        ).firstMatch
        XCTAssertTrue(
            protectedMilestone.waitForExistence(timeout: 8)
        )
        setupApp.terminate()

        let app = makeApp()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))

        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff - Verified copy")
        app.keyboards.buttons["Search"].tap()
        let verifiedDocument = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-",
                "Project handoff - Verified copy"
            )
        ).firstMatch
        XCTAssertTrue(
            reveal(verifiedDocument, in: app, maxSwipes: 8)
        )
        verifiedDocument.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .firstMatch
                .waitForExistence(timeout: 8)
        )

        let receipt = firstHittableButton(
            identifier: "deliveryReceiptBadge",
            in: app,
            timeout: 8
        )
        XCTAssertTrue(receipt.exists)
        tapCenter(receipt)
        XCTAssertTrue(
            app.navigationBars["Delivery receipt"]
                .waitForExistence(timeout: 8)
        )

        expandVerificationDetails(in: app)
        let linkedMilestone = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openLinkedMilestone-"
            )
        ).firstMatch
        XCTAssertTrue(
            revealForCenterTap(
                linkedMilestone,
                in: app,
                maxSwipes: 14
            )
        )
        tapCenter(linkedMilestone)
        XCTAssertTrue(
            app.navigationBars["Version History"]
                .waitForExistence(timeout: 8)
        )

        let editMilestone = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "editInspectedVersionMilestone-"
            )
        ).firstMatch
        XCTAssertTrue(
            revealForCenterTap(
                editMilestone,
                in: app,
                maxSwipes: 14
            )
        )
        tapCenter(editMilestone)

        XCTAssertTrue(
            app.scrollViews["versionMilestoneEditor"]
                .waitForExistence(timeout: 5)
        )
        let receiptLink = app.descendants(
            matching: .any
        )["milestoneReceiptLink"]
        XCTAssertTrue(
            reveal(receiptLink, in: app, maxSwipes: 8)
        )
        addScreenshot(
            named: "PaperPath Milestone Editor Accessibility XXXL",
            app: app
        )
    }

    func testUnifiedSearchFindsPDFTools() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("shrink")

        XCTAssertTrue(
            app.buttons["quickTool-compressPDF"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["1 matching tool"].exists)

        app.buttons["Clear text"].firstMatch.tap()
        search.tap()
        search.typeText("zyxwv no result")
        XCTAssertTrue(
            app.staticTexts["No matching documents or tools"]
                .waitForExistence(timeout: 3)
        )
    }

    func testFormReviewAndFieldPlacementScreens() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"]
                .waitForExistence(timeout: 5)
        )
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("form")
        let fillForm = app.buttons["documentTool-fillForm"]
        XCTAssertTrue(fillForm.waitForExistence(timeout: 3))
        fillForm.tap()

        XCTAssertTrue(
            app.navigationBars["Fill Form"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Recipient name"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Approval signature"].exists)
        addScreenshot(named: "PaperPath Form Check", app: app)

        app.buttons["Add Field"].tap()
        let placementNavigation = app.navigationBars["Place Form Field"]
        XCTAssertTrue(placementNavigation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Field name"].exists)
        let fieldType = app.buttons["formFieldTypePicker"]
        XCTAssertTrue(fieldType.waitForExistence(timeout: 3))
        fieldType.tap()
        app.buttons["Radio"].tap()
        XCTAssertTrue(
            app.textFields["formFieldOptions"]
                .waitForExistence(timeout: 3)
        )
        addScreenshot(named: "PaperPath Form Field Placement", app: app)
        let cancelPlacement = placementNavigation.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelPlacement.waitForExistence(timeout: 3))
        tapCenter(cancelPlacement)
        let discardDraft = app.buttons["Discard Draft"].firstMatch
        XCTAssertTrue(discardDraft.waitForExistence(timeout: 3))
        discardDraft.tap()
        XCTAssertTrue(placementNavigation.waitForNonExistence(timeout: 5))

        XCTAssertTrue(
            app.navigationBars["Fill Form"]
                .waitForExistence(timeout: 5)
        )
        let signatureField = app.descendants(matching: .any)[
            "formField-1-0"
        ].firstMatch
        XCTAssertTrue(signatureField.waitForExistence(timeout: 3))
        tapCenter(signatureField)
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 5)
        )
        let signaturePageContext = app.staticTexts[
            "signaturePageContext"
        ]
        XCTAssertTrue(
            signaturePageContext.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(signaturePageContext.label, "Sign for page 2")
        XCTAssertTrue(app.buttons["Place on Page"].exists)
        addScreenshot(named: "PaperPath Form Signature", app: app)
        app.buttons["Cancel"].tap()
    }

    func testInterruptedSignatureResumesAfterRelaunch() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )
        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"]
                .waitForExistence(timeout: 5)
        )
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("form")
        app.buttons["documentTool-fillForm"].tap()
        XCTAssertTrue(
            app.navigationBars["Fill Form"]
                .waitForExistence(timeout: 5)
        )
        let signatureField = app.descendants(matching: .any)[
            "formField-1-0"
        ].firstMatch
        XCTAssertTrue(signatureField.waitForExistence(timeout: 5))
        tapCenter(signatureField)
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 5)
        )
        let initialSignaturePageContext = app.staticTexts[
            "signaturePageContext"
        ]
        XCTAssertTrue(
            initialSignaturePageContext.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            initialSignaturePageContext.label,
            "Sign for page 2"
        )
        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        app.terminate()
        app.launchArguments = englishLaunchArguments
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        let resumedSearch = librarySearchField(in: app)
        resumedSearch.tap()
        resumedSearch.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let resume = app.buttons["documentTask-prepareToSend"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(resume.label, "Next, Continue signing")
        let resumeLocation = app.staticTexts[
            "Approval signature · page 2"
        ]
        XCTAssertTrue(resumeLocation.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            resumeLocation.frame.maxX,
            app.frame.maxX
        )
        addScreenshot(named: "PaperPath Resume Signing", app: app)
        resume.tap()

        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 8)
        )
        let resumedSignaturePageContext = app.staticTexts[
            "signaturePageContext"
        ]
        XCTAssertTrue(
            resumedSignaturePageContext.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            resumedSignaturePageContext.label,
            "Sign for page 2"
        )
    }

    func testExistingLinkEditorSurface() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"]
                .waitForExistence(timeout: 5)
        )
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("existing link")
        let editLinks = app.buttons["documentTool-links"]
        XCTAssertTrue(editLinks.waitForExistence(timeout: 3))
        editLinks.tap()

        XCTAssertTrue(
            app.navigationBars["Edit Links"]
                .waitForExistence(timeout: 5)
        )
        let overlay = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "existingLink-"
            )
        ).firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["selectedLinkMenu"].exists)
        XCTAssertTrue(app.textFields["existingLinkLabel"].exists)
        XCTAssertTrue(app.buttons["createLinkEditedCopy"].isEnabled)
        addScreenshot(named: "PaperPath Existing Link Editor", app: app)
    }

    func testReadingPageWorkflowAndFilesSurfaces() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        configureFreezeTracing(for: app)
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["Reading and navigation"].tap()
        let navigate = app.buttons["Navigate"].firstMatch
        XCTAssertTrue(navigate.waitForExistence(timeout: 3))
        navigate.tap()
        XCTAssertTrue(
            app.navigationBars["Navigate"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Go to page"].exists)
        addScreenshot(named: "PaperPath Page Navigation", app: app)
        let navigationDone = app.navigationBars["Navigate"]
            .buttons["Done"]
            .firstMatch
        XCTAssertTrue(navigationDone.waitForExistence(timeout: 3))
        navigationDone.tap()

        app.buttons["Pages"].tap()
        XCTAssertTrue(
            app.navigationBars["Organize pages"]
                .waitForExistence(timeout: 5)
        )
        let selectPages = app.buttons["selectOrganizerPages"]
        XCTAssertTrue(selectPages.waitForExistence(timeout: 3))
        selectPages.tap()
        let selectionMenu = app.buttons["pageSelectionMenu"]
        XCTAssertTrue(selectionMenu.waitForExistence(timeout: 3))
        selectionMenu.tap()
        app.buttons["All Pages"].tap()
        let actions = app.buttons["pageSelectionActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        let copyToDocument = app.buttons["Copy to Document"].firstMatch
        XCTAssertTrue(copyToDocument.waitForExistence(timeout: 3))
        copyToDocument.tap()
        XCTAssertTrue(
            app.navigationBars["Copy Pages To"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["August invoice"].exists)
        addScreenshot(named: "PaperPath Cross Document Pages", app: app)
        app.navigationBars["Copy Pages To"]
            .buttons["Cancel"]
            .firstMatch
            .tap()
        let organizer = app.navigationBars["Organize pages"]
        if organizer.exists {
            let close = organizer.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.tap()
        }
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["Document menu"].tap()
        let historyAndSource = app.buttons["History & source"].firstMatch
        XCTAssertTrue(historyAndSource.waitForExistence(timeout: 3))
        historyAndSource.tap()
        let fileLocation = app.buttons["File location & source"].firstMatch
        XCTAssertTrue(fileLocation.waitForExistence(timeout: 3))
        fileLocation.tap()
        XCTAssertTrue(
            app.navigationBars["Files & Source"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Private copy only"].exists
        )
        XCTAssertTrue(
            app.buttons["Save Working Copy to Files"].exists
        )
        addScreenshot(named: "PaperPath Files Source", app: app)

        app.buttons["Save Working Copy to Files"].tap()
        let filesPicker = app.descendants(matching: .any)[
            "fileExportPicker"
        ]
        let storageMessage = app.staticTexts[
            "There isn’t enough free space to create a private copy. Free some storage and try again."
        ]
        let exportOutcome = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                filesPicker.exists || storageMessage.exists
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [exportOutcome], timeout: 8),
            .completed
        )
        if filesPicker.exists {
            addScreenshot(named: "PaperPath Files Export", app: app)
        } else {
            XCTAssertTrue(app.alerts["Couldn’t complete that"].exists)
            addScreenshot(
                named: "PaperPath Files Export Low Storage",
                app: app
            )
        }
    }

    func testAccessibilityLayoutKeepsPrimaryTasksReachable() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Home",
            identifier: "workspaceLane-home",
            in: app
        )
        XCTAssertTrue(
            app.buttons["homePrimaryAction"].waitForExistence(timeout: 3)
        )
        addScreenshot(named: "PaperPath Accessibility Home XXXL", app: app)
        selectWorkspaceLane(
            title: "Tasks",
            identifier: "workspaceLane-tasks",
            in: app
        )
        XCTAssertTrue(
            reveal(
                app.buttons["quickTool-safeShare"],
                in: app,
                maxSwipes: 8
            )
        )
        addScreenshot(named: "PaperPath Accessibility XXXL", app: app)
    }

    func testOfficeExportDoubleTapKeepsSingleFlowAlive() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO"
        ]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(
            search.waitForExistence(timeout: 8)
        )
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"]
                .waitForExistence(timeout: 5)
        )
        selectAllDocumentTools(in: app)
        let exportResult = app.buttons["documentTool-export"].firstMatch
        XCTAssertTrue(reveal(exportResult, in: app, maxSwipes: 6))
        exportResult.tap()
        XCTAssertTrue(
            app.navigationBars["Create & Share"]
                .waitForExistence(timeout: 5)
        )

        let recommended = app.buttons["recommendedOfficeExport"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 5))
        XCTAssertTrue(recommended.isEnabled)
        recommended.doubleTap()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 12)
        )
        XCTAssertFalse(
            app.staticTexts[
                "Another local operation is already using this PDF."
            ].exists
        )
        XCTAssertTrue(
            app.navigationBars["Create & Share"].exists
                || app.otherElements["pdfWorkspace"].exists
                || app.otherElements["ActivityListView"].exists
        )
        addScreenshot(
            named: "PaperPath Office Export Double Tap",
            app: app
        )
    }

    func testOfficeExportCanBePresentedRepeatedlyInOneSession() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        configureFreezeTracing(for: app)
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        for iteration in 0..<10 {
            openDocumentTools(in: app)
            XCTAssertTrue(
                app.navigationBars["Tools"]
                    .waitForExistence(timeout: 5)
            )
            selectAllDocumentTools(in: app)
            let export = app.buttons["documentTool-export"].firstMatch
            XCTAssertTrue(reveal(export, in: app, maxSwipes: 6))
            export.tap()

            let exportNavigation = app.navigationBars["Create & Share"]
            XCTAssertTrue(
                exportNavigation.waitForExistence(timeout: 5),
                "Export sheet did not appear on iteration \(iteration)"
            )
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 3),
                "App left the foreground on iteration \(iteration)"
            )
            let done = app.buttons["officeExportDoneAction"]
                .firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            done.tap()
            XCTAssertTrue(
                app.otherElements["pdfWorkspace"]
                    .waitForExistence(timeout: 5),
                "Workspace did not recover on iteration \(iteration)"
            )
        }
    }

    func testOfficeExportCancellationSoakKeepsProcessAlive() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_OFFICE_SOAK_DEMO"
        ]
        configureFreezeTracing(for: app)
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("Office stress")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Office stress")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 10)
        )

        for iteration in 0..<8 {
            openDocumentTools(in: app)
            XCTAssertTrue(
                app.navigationBars["Tools"]
                    .waitForExistence(timeout: 5)
            )
            selectAllDocumentTools(in: app)
            let export = app.buttons["documentTool-export"].firstMatch
            XCTAssertTrue(reveal(export, in: app, maxSwipes: 6))
            export.tap()

            let exportNavigation = app.navigationBars["Create & Share"]
            XCTAssertTrue(
                exportNavigation.waitForExistence(timeout: 8),
                "Export sheet did not appear on iteration \(iteration)"
            )
            let recommended = app.buttons["recommendedOfficeExport"]
                .firstMatch
            XCTAssertTrue(reveal(recommended, in: app, maxSwipes: 8))
            recommended.tap()

            let stop = app.descendants(matching: .any)[
                "officeExportStopAction"
            ].firstMatch
            XCTAssertTrue(
                stop.waitForExistence(timeout: 5),
                "Office export did not start on iteration \(iteration)"
            )
            stop.tap()
            let done = app.descendants(matching: .any)[
                "officeExportDoneAction"
            ].firstMatch
            XCTAssertTrue(
                done.waitForExistence(timeout: 20),
                "Cancellation did not settle on iteration \(iteration)"
            )
            done.tap()
            XCTAssertTrue(
                app.otherElements["pdfWorkspace"]
                    .waitForExistence(timeout: 8),
                "Workspace did not recover on iteration \(iteration)"
            )
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 3),
                "App process exited on iteration \(iteration)"
            )
        }
    }

    func testRapidNavigationAndSheetHandoffsRemainResponsive() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        configureFreezeTracing(for: app)
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let lanes = [
            (
                "workspaceLane-home",
                "homePrimaryAction"
            ),
            (
                "workspaceLane-tasks",
                "taskPackage-prepareToSend"
            ),
            (
                "workspaceLane-outputs",
                "outputsVerifyAction"
            )
        ]
        for iteration in 0..<18 {
            let lane = lanes[iteration % lanes.count]
            let laneButton = app.buttons[lane.0].firstMatch
            XCTAssertTrue(
                laneButton.waitForExistence(timeout: 2),
                "Lane disappeared on iteration \(iteration)"
            )
            let startedAt = Date()
            laneButton.tap()
            XCTAssertTrue(
                app.buttons[lane.1].firstMatch
                    .waitForExistence(timeout: 3),
                "Lane did not respond on iteration \(iteration)"
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(startedAt),
                4,
                "Lane transition stalled on iteration \(iteration)"
            )
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 1)
            )
        }

        selectWorkspaceLane(
            title: "Home",
            identifier: "workspaceLane-home",
            in: app
        )
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Project handoff")
        app.keyboards.buttons["Search"].tap()
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        for iteration in 0..<12 {
            let toolsButton = firstHittableButton(
                identifier: "documentToolsAction",
                in: app,
                timeout: 3
            )
            XCTAssertTrue(toolsButton.isHittable)
            let toolsStartedAt = Date()
            tapCenter(toolsButton)
            let tools = app.navigationBars["Tools"]
            XCTAssertTrue(
                tools.waitForExistence(timeout: 3),
                "Tools did not open on iteration \(iteration)"
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(toolsStartedAt),
                3,
                "Tools opening stalled on iteration \(iteration)"
            )
            let toolsDone = tools.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Done",
                    "Close"
                )
            ).firstMatch
            XCTAssertTrue(toolsDone.waitForExistence(timeout: 2))
            toolsDone.tap()
            XCTAssertTrue(
                app.otherElements["pdfWorkspace"]
                    .waitForExistence(timeout: 3),
                "Workspace did not recover from Tools on iteration \(iteration)"
            )

            let find = firstHittableButton(
                identifier: "workspaceFindAction",
                in: app,
                timeout: 2
            )
            XCTAssertTrue(find.isHittable)
            let findStartedAt = Date()
            find.tap()
            let findNavigation = app.navigationBars["Find"]
            XCTAssertTrue(
                findNavigation.waitForExistence(timeout: 3),
                "Find did not open on iteration \(iteration)"
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(findStartedAt),
                3,
                "Find opening stalled on iteration \(iteration)"
            )
            let findDone = findNavigation.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Done",
                    "Close"
                )
            ).firstMatch
            XCTAssertTrue(findDone.waitForExistence(timeout: 2))
            findDone.tap()
            XCTAssertTrue(
                app.otherElements["pdfWorkspace"]
                    .waitForExistence(timeout: 3),
                "Workspace did not recover from Find on iteration \(iteration)"
            )
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 1)
            )
        }
    }

    func testOutcomeNavigationKeepsEachLaneFocused() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO"
        ]
        app.launch()

        let home = app.buttons["workspaceLane-home"].firstMatch
        let tasks = app.buttons["workspaceLane-tasks"].firstMatch
        let outputs = app.buttons["workspaceLane-outputs"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        XCTAssertTrue(tasks.exists)
        XCTAssertTrue(outputs.exists)
        home.tap()
        XCTAssertTrue(
            app.buttons["homePrimaryAction"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.otherElements["libraryDocumentsSection"].exists)

        tasks.tap()
        XCTAssertTrue(
            app.buttons["taskPackage-prepareToSend"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["homePrimaryAction"].exists)
        XCTAssertFalse(app.otherElements["libraryDocumentsSection"].exists)

        outputs.tap()
        XCTAssertTrue(
            app.buttons["outputsVerifyAction"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.otherElements["libraryDocumentsSection"].exists)

        home.tap()
        XCTAssertTrue(app.buttons["homePrimaryAction"].exists)
        XCTAssertTrue(app.otherElements["libraryDocumentsSection"].exists)
        addScreenshot(named: "PaperPath Focused Home", app: app)
    }

    private func addScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var englishLaunchArguments: [String] {
        [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
            "-app.language",
            "en",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryL"
        ]
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = englishLaunchArguments
        return app
    }

    private func configureFreezeTracing(for app: XCUIApplication) {
        app.launchArguments += ["UITEST_FREEZE_TRACE"]
        let defaults = [
            "DEBUG_SERVER_URL": "http://localhost:7777/event",
            "DEBUG_SESSION_ID": "frequent-ui-freeze",
            "DEBUG_RUN_ID": "post-fix"
        ]
        for (key, fallback) in defaults {
            app.launchEnvironment[key] =
                ProcessInfo.processInfo.environment[key] ?? fallback
        }
    }

    private func openVerifiedDeliveryReceipt(
        accessibilityText: Bool = false,
        fromLibrary: Bool = false
    ) throws -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        if accessibilityText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        if fromLibrary {
            selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
            let document = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-", "Project handoff"
            )).firstMatch
            XCTAssertTrue(reveal(document, in: app, maxSwipes: 8))
            document.tap()
            let open = app.buttons["deskOpenDocument"]
            if open.waitForExistence(timeout: 2) { open.tap() }
            XCTAssertTrue(app.descendants(matching: .any)["pdfWorkspace"].firstMatch.waitForExistence(timeout: 10))
            app.buttons["workspaceModeMenu"].tap()
            app.buttons["workspaceMode-deliver"].tap()
            let verify = app.buttons["Verify & Share"].firstMatch
            XCTAssertTrue(verify.waitForExistence(timeout: 5))
            verify.tap()
        } else {
            selectWorkspaceLane(
                title: "Tasks",
                identifier: "workspaceLane-tasks",
                in: app
            )
            let verify = app.buttons["quickTool-safeShare"]
            XCTAssertTrue(reveal(verify, in: app, maxSwipes: 12))
            verify.tap()

            XCTAssertTrue(
                app.navigationBars["Verify & Share"]
                    .waitForExistence(timeout: 5)
            )
            let document = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                    "quickTaskDocument-",
                    "Project handoff"
                )
            ).firstMatch
            XCTAssertTrue(reveal(document, in: app, maxSwipes: 8))
            let picker = app.collectionViews.containing(
                .button, identifier: document.identifier
            ).firstMatch
            if picker.exists {
                for _ in 0..<6 where !picker.frame.insetBy(dx: 0, dy: 24).contains(document.frame) {
                    picker.swipeUp()
                }
            }
            document.tap()
        }

        let create = app.buttons["safeShareButton"]
        if !create.waitForExistence(timeout: 10) {
            XCTAssertTrue(
                app.otherElements["pdfWorkspace"]
                    .firstMatch
                    .waitForExistence(timeout: 5)
            )
            let verifiedShareAction = firstHittableButton(
                identifier: "verifiedShareAction",
                in: app,
                timeout: 5
            )
            XCTAssertTrue(verifiedShareAction.isHittable)
            tapCenter(verifiedShareAction)
        }
        XCTAssertTrue(reveal(create, in: app, maxSwipes: 12))
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: create
        )
        waitForExpectations(timeout: 30)
        guard create.isEnabled else {
            XCTFail("Verify & Share did not finish preflight")
            return app
        }
        create.tap()

        if !accessibilityText {
            let verifiedTitle = workspaceDocumentTitle(in: app)
            let titleUpdated = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "label == %@",
                    "Project handoff - Verified copy"
                ),
                object: verifiedTitle
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [titleUpdated], timeout: 20),
                .completed
            )
            XCTAssertEqual(
                verifiedTitle.label,
                "Project handoff - Verified copy"
            )
        }
        let receipt = firstHittableButton(
            identifier: "deliveryReceiptBadge",
            in: app,
            timeout: accessibilityText ? 30 : 5
        )
        XCTAssertTrue(receipt.isHittable)
        receipt.tap()
        let receiptNavigation = app.navigationBars[
            "Delivery receipt"
        ]
        if !receiptNavigation.waitForExistence(timeout: 8) {
            XCTAssertTrue(receipt.isHittable)
            receipt.tap()
        }
        XCTAssertTrue(receiptNavigation.waitForExistence(timeout: 8))
        return app
    }

    private func expandVerificationDetails(in app: XCUIApplication) {
        if app.buttons["protectDeliveryMilestone"].exists {
            return
        }
        let disclosure = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Verification details"
            )
        ).firstMatch
        XCTAssertTrue(reveal(disclosure, in: app, maxSwipes: 8))
        tapCenter(disclosure)
    }

    private func waitForLibrary(in app: XCUIApplication) -> Bool {
        let desk = app.buttons["returnToDocumentDesk"]
        if desk.waitForExistence(timeout: 3), desk.isHittable { desk.tap() }
        return app.searchFields.firstMatch.waitForExistence(timeout: 20)
    }

    private func workspaceLane(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func firstHittableButton(
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement {
        let query = app.buttons.matching(identifier: identifier)
        _ = query.firstMatch.waitForExistence(timeout: timeout)
        return query.allElementsBoundByIndex.first(where: \.isHittable)
            ?? query.firstMatch
    }

    private func openDocumentTools(in app: XCUIApplication) {
        let button = firstHittableButton(
            identifier: "documentToolsAction",
            in: app,
            timeout: 5
        )
        XCTAssertTrue(button.isHittable)
        tapCenter(button)
    }

    private func selectWorkspaceLane(
        title: String,
        identifier: String,
        in app: XCUIApplication
    ) {
        let directLane = workspaceLane(identifier, in: app)
        if directLane.exists {
            directLane.tap()
            return
        }

        let menu = app.buttons["Workspace"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
    }

    private func librarySearchField(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.searchFields.firstMatch
    }

    private func documentToolSearchField(
        in app: XCUIApplication
    ) -> XCUIElement {
        let identified = app.textFields["documentToolSearchField"]
            .firstMatch
        if identified.waitForExistence(timeout: 1) {
            return identified
        }
        return app.searchFields.firstMatch
    }

    private func workspaceDocumentTitle(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)["workspaceDocumentTitle"]
            .firstMatch
    }

    private func selectAllDocumentTools(in app: XCUIApplication) {
        let identified = app.buttons["documentToolView-all"].firstMatch
        if identified.waitForExistence(timeout: 1) {
            identified.tap()
            return
        }

        let direct = app.buttons["All actions"].firstMatch
        if direct.waitForExistence(timeout: 1) {
            direct.tap()
            return
        }

        let picker = app.buttons["documentToolView"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let menuAction = app.buttons["All actions"].firstMatch
        XCTAssertTrue(menuAction.waitForExistence(timeout: 3))
        menuAction.tap()
    }

    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> Bool {
        if element.exists && element.isHittable {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 0.5),
               element.isHittable {
                return true
            }
        }
        return element.exists && element.isHittable
    }

    private func revealForCenterTap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> Bool {
        let safeTop = app.frame.minY + 120
        let safeBottom = app.frame.maxY - 80

        for _ in 0...maxSwipes {
            if element.exists {
                let frame = element.frame
                if element.isHittable,
                   frame.midY >= safeTop,
                   frame.midY <= safeBottom {
                    return true
                }

                if frame.midY < safeTop {
                    dragViewport(
                        in: app,
                        fromY: 0.35,
                        toY: 0.65
                    )
                } else {
                    dragViewport(
                        in: app,
                        fromY: 0.72,
                        toY: 0.42
                    )
                }
            } else {
                app.swipeUp()
            }
        }

        guard element.exists, element.isHittable else {
            return false
        }
        let frame = element.frame
        return frame.midY >= safeTop && frame.midY <= safeBottom
    }

    private func dragViewport(
        in app: XCUIApplication,
        fromY: CGFloat,
        toY: CGFloat
    ) {
        let start = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: fromY)
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: toY)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func tapCenter(_ element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
    }
}
