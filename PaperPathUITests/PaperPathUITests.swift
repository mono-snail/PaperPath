import XCTest
import UIKit

@MainActor
final class PaperPathUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let app = XCUIApplication()
            if app.state == .runningForeground {
                addScreenshot(named: "Failure — \(name)", app: app)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Failure accessibility hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
        }
        try super.tearDownWithError()
    }

    private func selectProfessionalMode(_ mode: String, chinese: Bool = false, in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["pdfWorkspace"].firstMatch.waitForExistence(timeout: 10))
        var menu = firstHittableButton(
            identifier: "workspaceModeMenu",
            in: app,
            timeout: 2
        )
        if !menu.isHittable {
            let label = chinese ? "工作区工具" : "Workspace tools"
            let alternatives = app.buttons.matching(
                NSPredicate(format: "label == %@", label)
            )
            _ = alternatives.firstMatch.waitForExistence(timeout: 2)
            menu = alternatives.allElementsBoundByIndex
                .first(where: \.isHittable)
                ?? alternatives.firstMatch
        }
        if menu.exists, menu.isHittable {
            tapCenter(menu)
            let identified = firstHittableButton(
                identifier: "workspaceMode-\(mode)",
                in: app,
                timeout: 2
            )
            if identified.exists, identified.isHittable {
                tapCenter(identified)
            } else {
                let title: String
                switch mode {
                case "read":
                    title = chinese ? "阅读" : "Read"
                case "annotate":
                    title = chinese ? "批注" : "Annotate"
                case "deliver":
                    title = chinese ? "交付" : "Deliver"
                default:
                    title = chinese ? "页面" : "Pages"
                }
                let options = app.buttons.matching(
                    NSPredicate(format: "label == %@", title)
                )
                let option = options.allElementsBoundByIndex
                    .first(where: \.isHittable)
                    ?? options.firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 3))
                tapCenter(option)
            }
        } else {
            let title: String
            switch mode {
            case "read":
                title = chinese ? "阅读" : "Read"
            case "annotate":
                title = chinese ? "批注" : "Annotate"
            case "deliver":
                title = chinese ? "交付" : "Deliver"
            default:
                title = chinese ? "页面" : "Pages"
            }
            let button = app.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }

        let expectedControl: String
        switch mode {
        case "read": expectedControl = "workspaceFindAction"
        case "annotate": expectedControl = "workspaceTool-highlight"
        case "deliver": expectedControl = "workspaceTool-fillForm"
        default: expectedControl = "workspaceTool-organize"
        }
        XCTAssertTrue(
            app.buttons[expectedControl].firstMatch
                .waitForExistence(timeout: 5),
            "Workspace mode \(mode) did not become active"
        )
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
        openDocumentTools(in: app)
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
        openDocumentTools(in: app)
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
            app.buttons["workspaceNavigationMenu"].tap()
            app.buttons[chinese ? "阅读" : "Reading"].firstMatch.tap()
            app.buttons[chinese ? "阅读设置" : "Reading Settings"].firstMatch.tap()
            XCTAssertTrue(app.buttons["readingTheme-sepia"].waitForExistence(timeout: 5))
            app.buttons["readingTheme-sepia"].tap()
            let reset = app.buttons["resetReadingSettings"]
            XCTAssertTrue(reveal(reset, in: app, maxSwipes: 8))
            reset.tap()
            addScreenshot(named: "Reading settings" + suffix, app: app)
            app.buttons[done].firstMatch.tap()
            app.buttons["workspaceNavigationMenu"].tap()
            app.descendants(matching: .any)["workspaceNavigateAction"].firstMatch.tap()
            let input = app.textFields["navigationPageInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText("2")
            addScreenshot(named: "Navigation" + suffix, app: app)
            app.buttons["navigationGoToPage"].tap()
            XCTAssertTrue(app.buttons["workspaceNavigationMenu"].waitForExistence(timeout: 5))
            app.buttons["workspaceNavigationMenu"].tap()
            app.buttons[chinese ? "阅读" : "Reading"].firstMatch.tap()
            app.buttons[chinese ? "专注阅读" : "Focus Reader"].firstMatch.tap()
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
            openDocumentTools(chinese: chinese, in: app)
            let search = app.textFields["documentToolSearchField"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            addScreenshot(named: "Document tools" + suffix, app: app)
            search.tap()
            search.typeText(chinese ? "查找" : "Find")
            let find = app.buttons["documentTool-find"]
            XCTAssertTrue(find.waitForExistence(timeout: 5))
            let submit = app.keyboards.buttons["Go"].firstMatch
            XCTAssertTrue(submit.waitForExistence(timeout: 3))
            submit.tap()
            XCTAssertTrue(
                app.searchFields.firstMatch.waitForExistence(timeout: 5)
            )
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

    private func waitForOfficeTablePixels(
        in app: XCUIApplication
    ) {
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let status = app.descendants(matching: .any)[
                "officeOutputPreviewStatus"
            ].firstMatch
            guard status.exists,
                  status.frame.width > 0,
                  status.frame.height > 0,
                  let image = app.screenshot().image.cgImage
            else { return false }
            let appFrame = app.frame
            let previewHeight: CGFloat = 210
            let points = CGRect(
                x: appFrame.minX + 16,
                y: max(
                    appFrame.minY,
                    status.frame.minY - previewHeight
                ),
                width: max(1, appFrame.width - 32),
                height: previewHeight
            )
            let scaleX = CGFloat(image.width) / appFrame.width
            let scaleY = CGFloat(image.height) / appFrame.height
            let pixelBounds = CGRect(
                x: (points.minX - appFrame.minX) * scaleX,
                y: (points.minY - appFrame.minY) * scaleY,
                width: points.width * scaleX,
                height: points.height * scaleY
            ).integral.intersection(
                CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
            )
            guard pixelBounds.width > 0,
                  pixelBounds.height > 0,
                  let previewImage = image.cropping(
                    to: pixelBounds
                  )
            else { return false }
            let width = 320, height = 180
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let rows = pixels.withUnsafeMutableBytes { bytes -> Int in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return 0 }
                context.draw(
                    previewImage,
                    in: CGRect(
                        x: 0,
                        y: 0,
                        width: width,
                        height: height
                    )
                )
                let data = bytes.bindMemory(to: UInt8.self)
                return (10..<170).filter { y in
                    let darkPixels = (8..<312).filter { x in
                        let i = (y * width + x) * 4
                        return data[i] < 170 && data[i + 1] < 170 && data[i + 2] < 170
                    }.count
                    return darkPixels > 3 && darkPixels < 230
                }.count
            }
            return rows > 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed)
    }

    private func waitForOfficePreviewReady(
        chinese: Bool = false,
        in app: XCUIApplication
    ) -> XCUIElement {
        let expectedValue = chinese
            ? "输出预览已就绪"
            : "Output preview ready"
        let status = app.descendants(matching: .any)[
            "officeOutputPreviewStatus"
        ].firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                expectedValue
            ),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 30),
            .completed
        )
        return status
    }

    func testNativeWorkbenchHiddenPreview() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_OFFICE_CORPUS_FIXTURE",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "YES"
        ]
        app.launch()
        XCTAssertTrue(waitForOfficeCorpusFixture(in: app))
        selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("ConditionalFormattingSamples")
        submitSearchKeyboard(in: app)
        let output = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "officeResult-", "ConditionalFormattingSamples")).firstMatch
        XCTAssertTrue(reveal(output, in: app, maxSwipes: 12))
        output.tap()
        let preview = app.descendants(matching: .any)[
            "officeOutputPreviewStatus"
        ].firstMatch
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
            "UITEST_OFFICE_CORPUS_FIXTURE",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "NO",
            "-workspace.toolMode", "read"
        ]
        app.launch()
        XCTAssertTrue(waitForOfficeCorpusFixture(in: app))
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
        selectProfessionalMode("annotate", in: app)
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
                "-privacy.appLockEnabled", "NO",
                "-UIPreferredContentSizeCategoryName",
                largeType ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL",
                "UITEST_OFFICE_CORPUS_FIXTURE",
                "-experience.onboardingCompleted.v4", "YES",
                "-privacy.hideLibraryPreviews", "NO",
                "-workspace.toolMode", "read"
            ]
            app.launch()
            XCTAssertTrue(
                waitForOfficeCorpusFixture(chinese: true, in: app)
            )
            selectWorkspaceLane(
                title: "文档",
                identifier: "workspaceLane-home",
                in: app
            )
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
                selectProfessionalMode(
                    "read",
                    chinese: true,
                    in: app
                )
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
            XCTAssertTrue(waitForLibrary(in: app))
            selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
            let document = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "resultDocument-"
            )).firstMatch
            XCTAssertTrue(reveal(document, in: app, maxSwipes: 8))
            let receipt = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "resultReceipt-"
            )).firstMatch
            XCTAssertTrue(reveal(receipt, in: app, maxSwipes: 8))
            XCTAssertGreaterThanOrEqual(receipt.frame.height + 0.001, 44)
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
            "-privacy.appLockEnabled", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "UITEST_OFFICE_CORPUS_FIXTURE",
            "-experience.onboardingCompleted.v4", "YES",
            "-privacy.hideLibraryPreviews", "NO"
        ]
        app.launch()
        XCTAssertTrue(
            waitForOfficeCorpusFixture(chinese: true, in: app)
        )
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("ConditionalFormattingSamples")
        submitSearchKeyboard(in: app)
        let output = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "officeResult-"
        )).firstMatch
        guard output.waitForExistence(timeout: 30) else {
            XCTFail("The localized Office result did not become available")
            app.terminate()
            return
        }
        addScreenshot(named: "Chinese results", app: app)
        output.tap()
        let preview = app.descendants(matching: .any)[
            "officeOutputPreviewStatus"
        ].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        _ = waitForOfficePreviewReady(
            chinese: true,
            in: app
        )
        waitForOfficeTablePixels(in: app)
        addScreenshot(named: "Chinese output preview", app: app)
        app.terminate()
    }

    func testOfficeCorpusNoticesSurviveReopening() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_OFFICE_CORPUS_FIXTURE",
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
            XCTAssertTrue(waitForOfficeCorpusFixture(in: app))
            selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
            let search = librarySearchField(in: app)
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
            let preview = app.descendants(matching: .any)[
                "officeOutputPreviewStatus"
            ].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 15))
            if !largeType {
                _ = waitForOfficePreviewReady(
                    in: app
                )
                XCUIDevice.shared.press(.home)
                app.activate()
                _ = waitForOfficePreviewReady(
                    in: app
                )
                waitForOfficeTablePixels(in: app)
            }
            addScreenshot(named: largeType ? "Native output accessibility" : "Native output preview", app: app)
            let summary = app.otherElements["officeNoticeDetails-spreadsheetTextOnly"].buttons.firstMatch
            XCTAssertTrue(revealOfficeControl(summary, in: app))
            summary.tap()
            let notice = app.descendants(matching: .any)["officeNotice-spreadsheetTextOnly"].firstMatch
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            XCTAssertTrue(notice.label.contains("Charts, images, formulas, and pivot tables are omitted."))
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
            "Dark",
            "-workspace.toolMode",
            "pages"
        ]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Documents",
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
            app.otherElements["libraryDocumentsSection"]
                .waitForExistence(timeout: 3)
        )
        selectWorkspaceLane(
            title: "Tools",
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
            XCTAssertTrue(
                reveal(
                    app.buttons[identifier],
                    in: app,
                    maxSwipes: 10
                )
            )
        }
        let allTaskPaths = app.buttons["toggleAllTaskPaths"].firstMatch
        XCTAssertTrue(reveal(allTaskPaths, in: app, maxSwipes: 3))
        allTaskPaths.tap()
        XCTAssertFalse(app.buttons["taskPackage-makeSearchable"].exists)
        XCTAssertTrue(app.buttons["taskPackage-compressForEmail"].exists)
        XCTAssertTrue(
            app.otherElements["deskToolsCatalog"].exists
        )
        XCTAssertTrue(
            revealTowardTop(
                combineButton,
                in: app,
                maxSwipes: 12
            )
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
            app.buttons["librarySearchButton"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            reveal(
                app.buttons["quickTool-imagesToPDF"],
                in: app,
                maxSwipes: 4
            )
        )

        let search = librarySearchField(in: app)
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

        let nextSearch = librarySearchField(in: app)
        nextSearch.tap()
        nextSearch.typeText("Project handoff")
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
        selectProfessionalMode("pages", in: app)
        XCTAssertTrue(workspaceDocumentTitle(in: app).label.contains("Project handoff"))
        XCTAssertTrue(app.buttons["workspaceTool-organize"].firstMatch.isHittable)
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

        selectProfessionalMode("read", in: app)
        let findButton = firstHittableButton(
            identifier: "workspaceFindAction",
            in: app,
            timeout: 3
        )
        XCTAssertTrue(findButton.isHittable)
        tapCenter(findButton)
        let findNavigation = app.navigationBars["Find"]
        XCTAssertTrue(findNavigation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3))
        addScreenshot(named: "PaperPath Document Find", app: app)
        dismissPresentedWorkflow(title: "Find", in: app)
        XCTAssertTrue(findNavigation.waitForNonExistence(timeout: 5))

        openPageOrganizer(in: app)
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

    func testSplitPDFQuickJourneyCreatesCopyAfterCancelAndReentry()
        throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-workspace.toolMode",
            "pages"
        ]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        openQuickTask(
            identifier: "splitPDF",
            query: "Split PDF",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Split PDF"].waitForExistence(timeout: 10)
        )
        dismissPresentedWorkflow(title: "Split PDF", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "splitPDF",
            query: "Split PDF",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Split PDF"].waitForExistence(timeout: 10)
        )
        let firstPage = app.buttons["organizerPage-0"]
        XCTAssertTrue(firstPage.waitForExistence(timeout: 5))
        firstPage.tap()

        let extract = app.buttons["extractPagesButton"]
        XCTAssertTrue(extract.waitForExistence(timeout: 3))
        XCTAssertTrue(extract.isEnabled)
        extract.tap()

        XCTAssertTrue(
            app.staticTexts["Project handoff - extracted pages"]
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        assertAppAlive(app)
    }

    func testProtectPDFJourneyCreatesCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "protectPDF",
            query: "Protect PDF",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Protect PDF"]
                .waitForExistence(timeout: 8)
        )
        addScreenshot(named: "Protection first screen", app: app)
        dismissPresentedWorkflow(title: "Protect PDF", in: app)

        openQuickTask(
            identifier: "protectPDF",
            query: "Protect PDF",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Protect PDF"]
                .waitForExistence(timeout: 8)
        )
        completeProtection(
            navigationTitle: "Protect PDF",
            password: "PaperPath-2026",
            in: app
        )
        let protectedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Protected copy"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [protectedCopyOpened],
                timeout: 30
            ),
            .completed
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        assertAppAlive(app)
    }

    func testWatermarkJourneyWritesAnnotationsAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "watermark",
            query: "Watermark",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Watermark"]
                .waitForExistence(timeout: 5)
        )
        dismissPresentedWorkflow(title: "Watermark", in: app)

        openDocumentTool(
            identifier: "watermark",
            query: "Watermark",
            in: app
        )
        let apply = app.buttons["watermarkApplyAction"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(
            app.navigationBars["Watermark"]
                .waitForNonExistence(timeout: 20)
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)

        openDocumentTool(
            identifier: "annotations",
            query: "Annotations",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Comments & Markup"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts["CONFIDENTIAL"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertGreaterThan(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "annotationRow-"
                )
            ).count,
            0
        )
        assertAppAlive(app)
    }

    func testBatesJourneyWritesPageIDsAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "bates",
            query: "Bates Numbering",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Bates Numbering"]
                .waitForExistence(timeout: 5)
        )
        dismissPresentedWorkflow(title: "Bates Numbering", in: app)

        openDocumentTool(
            identifier: "bates",
            query: "Bates Numbering",
            in: app
        )
        let apply = app.buttons["batesApplyAction"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(
            app.navigationBars["Bates Numbering"]
                .waitForNonExistence(timeout: 20)
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)

        openDocumentTool(
            identifier: "annotations",
            query: "Annotations",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Comments & Markup"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts["000001"].waitForExistence(timeout: 10)
        )
        XCTAssertGreaterThan(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "annotationRow-"
                )
            ).count,
            0
        )
        assertAppAlive(app)
    }

    func testStampJourneyAddsEditableAnnotationAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "stamp",
            query: "Stamp",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Add stamp"]
                .waitForExistence(timeout: 5)
        )
        dismissPresentedWorkflow(title: "Add stamp", in: app)

        openDocumentTool(
            identifier: "stamp",
            query: "Stamp",
            in: app
        )
        let approved = app.buttons["stampOption-Approved"].firstMatch
        XCTAssertTrue(approved.waitForExistence(timeout: 5))
        tapCenter(approved)
        XCTAssertTrue(
            app.navigationBars["Add stamp"]
                .waitForNonExistence(timeout: 10)
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)

        openDocumentTool(
            identifier: "annotations",
            query: "Annotations",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Comments & Markup"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts["Approved"].waitForExistence(timeout: 10)
        )
        XCTAssertGreaterThan(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "annotationRow-"
                )
            ).count,
            0
        )
        assertAppAlive(app)
    }

    func testBriefJourneyLoadsResultAfterCloseAndReentry() throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        for _ in 0..<2 {
            openDocumentTool(
                identifier: "brief",
                query: "Brief",
                in: app
            )
            XCTAssertTrue(
                app.navigationBars["Document details"]
                    .waitForExistence(timeout: 8)
            )
            XCTAssertTrue(
                app.staticTexts["Project handoff"]
                    .waitForExistence(timeout: 10)
            )
            XCTAssertFalse(app.staticTexts["Brief unavailable"].exists)
            dismissPresentedWorkflow(
                title: "Document details",
                in: app
            )
            XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        }
        assertAppAlive(app)
    }

    func testAnnotationsJourneyReloadsInventoryAfterCloseAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        for _ in 0..<2 {
            openDocumentTool(
                identifier: "annotations",
                query: "Annotations",
                in: app
            )
            XCTAssertTrue(
                app.navigationBars["Comments & Markup"]
                    .waitForExistence(timeout: 8)
            )
            let loaded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.staticTexts["No annotations"].exists
                        || app.descendants(matching: .any).matching(
                            NSPredicate(
                                format: "identifier BEGINSWITH %@",
                                "annotationRow-"
                            )
                        ).count > 0
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [loaded], timeout: 15),
                .completed
            )
            dismissPresentedWorkflow(
                title: "Comments & Markup",
                in: app
            )
            XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        }
        assertAppAlive(app)
    }

    func testAttachmentsJourneyReloadsInspectionAfterCloseAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        for _ in 0..<2 {
            openDocumentTool(
                identifier: "attachments",
                query: "Attachments",
                in: app
            )
            XCTAssertTrue(
                app.navigationBars["Attachments"]
                    .waitForExistence(timeout: 8)
            )
            let loaded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.staticTexts["No embedded files"].exists
                        || app.descendants(matching: .any).matching(
                            NSPredicate(
                                format: "identifier BEGINSWITH %@",
                                "attachmentRow-"
                            )
                        ).count > 0
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [loaded], timeout: 15),
                .completed
            )
            dismissPresentedWorkflow(
                title: "Attachments",
                in: app
            )
            XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        }
        assertAppAlive(app)
    }

    func testScanToPDFJourneyCreatesReviewedTwoPageDocument()
        throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_SCAN_CAPTURE_FIXTURE"]
        )

        openQuickTask(
            identifier: "scanToPDF",
            query: "Scan to PDF",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Review Scan"]
                .waitForExistence(timeout: 8)
        )
        addScreenshot(named: "Scan review first screen", app: app)
        dismissPresentedWorkflow(
            title: "Review Scan",
            in: app
        )

        openQuickTask(
            identifier: "scanToPDF",
            query: "Scan to PDF",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "scanOutputBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        let save = app.buttons["scanSave"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: save
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 10),
            .completed
        )
        save.tap()

        let title = workspaceDocumentTitle(in: app)
        let scanOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label BEGINSWITH %@",
                "Scan"
            ),
            object: title
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [scanOpened], timeout: 30),
            .completed
        )
        assertTwoPageDocumentNavigation(in: app)
        assertAppAlive(app)
    }

    func testImagesToPDFJourneyCreatesReviewedTwoPageDocument()
        throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_IMAGE_IMPORT_FIXTURE"]
        )

        openQuickTask(
            identifier: "imagesToPDF",
            query: "Images to PDF",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Review Scan"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(
            title: "Review Scan",
            in: app
        )

        openQuickTask(
            identifier: "imagesToPDF",
            query: "Images to PDF",
            in: app
        )
        let save = app.buttons["scanSave"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: save
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 10),
            .completed
        )
        save.tap()

        let title = workspaceDocumentTitle(in: app)
        let imagesOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label BEGINSWITH %@",
                "Images"
            ),
            object: title
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [imagesOpened], timeout: 30),
            .completed
        )
        assertTwoPageDocumentNavigation(in: app)
        assertAppAlive(app)
    }

    func testIPadDocumentToolsInspectorOpensCompression() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad inspector workflow")
        }
        let app = launchResetDemo()
        openDemoDocument(in: app)
        let toggle = app.buttons["workspaceInspectorToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        let compress = app.buttons["inspectorTool-compressPDF"].firstMatch
        if !compress.isHittable { toggle.tap() }
        XCTAssertTrue(compress.waitForExistence(timeout: 8))
        XCTAssertTrue(compress.isEnabled)
        addScreenshot(named: "iPad document tools", app: app)
        compress.tap()
        XCTAssertTrue(app.navigationBars["Compress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["compressionSizeEstimate"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["compressionOutputBoundary"].firstMatch.exists)
        addScreenshot(named: "iPad compact compression", app: app)
        dismissPresentedWorkflow(title: "Compress", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "Hidden")
    }

    func testLocalPDFHomeShortcutsOpenWorkflows() throws {
        let app = launchResetDemo(additionalArguments: ["UITEST_POLISH_OCR"])
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["localProcessingPromise"].firstMatch.waitForExistence(timeout: 5))
        for (task, title) in [
            ("mergePDFs", "Merge PDFs"),
            ("splitPDF", "Split PDF"),
            ("compressPDF", "Compress PDF"),
            ("recognizeText", "OCR PDF")
        ] {
            let shortcut = app.buttons["homeGoal-\(task)"].firstMatch
            XCTAssertTrue(reveal(shortcut, in: app, maxSwipes: 5))
            shortcut.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            dismissPresentedWorkflow(title: title, in: app)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Local PDF home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testMergePDFJourneyCreatesNamedResultAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "mergePDFs",
            query: "Merge PDFs",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Merge PDFs"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Merge PDFs", in: app)

        openQuickTask(
            identifier: "mergePDFs",
            query: "Merge PDFs",
            in: app
        )
        let create = app.buttons["mergeCreateAction"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled)

        for documentTitle in ["Project handoff", "August invoice"] {
            let document = app.buttons.matching(
                NSPredicate(
                    format:
                        "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                    "mergeAvailableDocument-",
                    documentTitle
                )
            ).firstMatch
            XCTAssertTrue(
                revealForCenterTap(document, in: app, maxSwipes: 10),
                "Could not add \(documentTitle) to the merge"
            )
            tapCenter(document)
            guard document.waitForNonExistence(timeout: 8) else {
                XCTFail(
                    "\(documentTitle) did not move into the merge selection"
                )
                return
            }
            let selectedDocument = app.descendants(matching: .any).matching(
                NSPredicate(
                    format:
                        "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                    "mergeSelectedDocument-",
                    documentTitle
                )
            ).firstMatch
            guard selectedDocument.waitForExistence(timeout: 8) else {
                XCTFail(
                    "\(documentTitle) was not added to the merge order"
                )
                return
            }
        }

        let selectedRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mergeSelectedDocument-")
        )
        let project = selectedRows.matching(NSPredicate(format: "label CONTAINS[c] %@", "Project handoff")).firstMatch
        let invoice = selectedRows.matching(NSPredicate(format: "label CONTAINS[c] %@", "August invoice")).firstMatch
        XCTAssertTrue(revealForCenterTap(project, in: app, maxSwipes: 8))
        let invoiceID = String(invoice.identifier.dropFirst("mergeSelectedDocument-".count))
        let dragHandle = app.descendants(matching: .any)["mergeDrag-\(invoiceID)"].firstMatch
        XCTAssertTrue(revealForCenterTap(dragHandle, in: app, maxSwipes: 8))
        XCTAssertTrue(project.isHittable)
        dragHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: project.coordinate(
                withNormalizedOffset: CGVector(dx: 0.4, dy: 0.25)
            ))
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in invoice.frame.minY < project.frame.minY },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        addScreenshot(named: "Dragged merge order", app: app)

        let outputName = app.textFields["mergeOutputName"].firstMatch
        XCTAssertTrue(revealForCenterTap(outputName, in: app, maxSwipes: 8))
        outputName.tap()
        outputName.typeText("Automation Merge")
        if app.keyboards.buttons["Done"].exists {
            app.keyboards.buttons["Done"].tap()
        }
        addScreenshot(named: "Merge order and output name", app: app)

        XCTAssertTrue(reveal(create, in: app, maxSwipes: 8))
        let mergeEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: create
        )
        guard XCTWaiter.wait(
            for: [mergeEnabled],
            timeout: 15
        ) == .completed else {
            XCTFail("Merge action did not become enabled")
            return
        }
        create.tap()
        XCTAssertTrue(
            app.staticTexts["Merged PDF ready"]
                .waitForExistence(timeout: 30)
        )
        let openResult = app.buttons["mergeOpenResult"].firstMatch
        XCTAssertTrue(openResult.waitForExistence(timeout: 5))
        tapCenter(openResult)

        let title = workspaceDocumentTitle(in: app)
        let mergedDocumentOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Automation Merge"
            ),
            object: title
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [mergedDocumentOpened],
                timeout: 15
            ),
            .completed
        )
        assertAppAlive(app)
    }

    func testOrganizePagesQuickJourneyCreatesCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "organizePages",
            query: "Organize Pages",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Organize pages"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Organize pages", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "organizePages",
            query: "Organize Pages",
            documentTitle: "Project handoff",
            in: app
        )
        let cropPage = app.buttons["Crop page"].firstMatch
        XCTAssertTrue(cropPage.waitForExistence(timeout: 5))
        tapCenter(cropPage)
        XCTAssertTrue(
            app.navigationBars["Crop Page"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "pageCropBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Organize pages"]
                .waitForExistence(timeout: 5)
        )
        completePageExtraction(in: app)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "Project handoff - extracted pages"
        )
        assertAppAlive(app)
    }

    func testCompressPDFQuickJourneyKeepsAlreadySmallerOriginal()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "compressPDF",
            query: "Compress PDF",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Compress PDF"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Compress PDF", in: app)
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "compressPDF",
            query: "Compress PDF",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "batchCompressionOutputBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        let source = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "batchCompressionDocument-",
                "Project handoff"
            )
        ).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        tapCenter(source)
        let compress = app.buttons["batchCompressionAction"].firstMatch
        XCTAssertTrue(compress.waitForExistence(timeout: 5))
        XCTAssertTrue(compress.isEnabled)
        compress.tap()

        XCTAssertTrue(
            app.staticTexts["COMPRESSION RESULT"]
                .waitForExistence(timeout: 45)
        )
        XCTAssertTrue(
            app.staticTexts["Originals already smaller"]
                .waitForExistence(timeout: 5)
        )
        let protectedFromGrowth = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "PaperPath did not save the larger copy."
            )
        )
        .firstMatch
        XCTAssertTrue(
            protectedFromGrowth.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["No new copy"].exists)
        XCTAssertFalse(app.buttons["Retry 1 Failed"].exists)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(waitForLibrary(in: app))
        XCTAssertFalse(
            app.staticTexts["Project handoff - Compressed copy"].exists
        )
        assertAppAlive(app)
    }

    func testFillFormsQuickJourneyAddsFieldAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "fillForms",
            query: "Fill Forms",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Fill Form"].waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Fill Form", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "fillForms",
            query: "Fill Forms",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertFalse(app.staticTexts["Quick task field"].exists)
        completeFormField(named: "Quick task field", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        assertAppAlive(app)
    }

    func testSignPDFQuickJourneyPlacesSignatureAfterCancelAndReentry()
        throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_INK_FIXTURE"]
        )

        openQuickTask(
            identifier: "signPDF",
            query: "Sign PDF",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Add signature", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "signPDF",
            query: "Sign PDF",
            documentTitle: "Project handoff",
            in: app
        )
        completeSignature(in: app)
        assertAnnotationResult(title: "Signature", in: app)
    }

    func testRedactPDFQuickJourneyCreatesSecureCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_PRESELECT_TEXT"]
        )

        openQuickTask(
            identifier: "redactPDF",
            query: "Redact PDF",
            documentTitle: "Project handoff",
            in: app
        )
        openQuickRedactionReview(in: app)
        dismissPresentedWorkflow(title: "Review redactions", in: app)
        let cancelMode = app.buttons["cancelRedactionMode"].firstMatch
        XCTAssertTrue(cancelMode.waitForExistence(timeout: 5))
        cancelMode.tap()
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "redactPDF",
            query: "Redact PDF",
            documentTitle: "Project handoff",
            in: app
        )
        openQuickRedactionReview(in: app)
        completeRedaction(in: app)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "Project handoff - Redacted copy"
        )
        assertAppAlive(app)
    }

    func testSafeShareQuickJourneyCreatesVerifiedCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "safeShare",
            query: "Verify Share",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Finish & Share"]
                .waitForExistence(timeout: 10)
        )
        dismissPresentedWorkflow(title: "Finish & Share", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "safeShare",
            query: "Verify Share",
            documentTitle: "Project handoff",
            in: app
        )
        completeVerifiedShare(in: app)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "Project handoff - Verified copy"
        )
        assertAppAlive(app)
    }

    func testRecognizeTextQuickJourneyProducesResultAfterCancelAndReentry()
        throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_POLISH_OCR",
            "-workspace.toolMode",
            "pages"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "recognizeText",
            query: "OCR PDF",
            documentTitle: "Polish scan",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Recognition"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Recognition", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Polish scan")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "recognizeText",
            query: "OCR PDF",
            documentTitle: "Polish scan",
            in: app
        )
        completeRecognition(query: "Delivery", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Polish scan")
        assertAppAlive(app)
    }

    func testExportTextQuickJourneyProducesResultAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "exportText",
            query: "PDF Office",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Convert PDF"]
                .waitForExistence(timeout: 10)
        )
        dismissPresentedWorkflow(title: "Convert PDF", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "exportText",
            query: "PDF Office",
            documentTitle: "Project handoff",
            in: app
        )
        completeOfficeExport(in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        assertAppAlive(app)
    }

    func testExportImagesJourneyProducesShareablePageFilesAfterReentry()
        throws {
        let app = launchResetDemo()

        openQuickTask(
            identifier: "exportImages",
            query: "PDF Images",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Save as Images"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Save as Images", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        XCTAssertTrue(waitForLibrary(in: app))

        openQuickTask(
            identifier: "exportImages",
            query: "PDF Images",
            documentTitle: "Project handoff",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Save as Images"]
                .waitForExistence(timeout: 8)
        )
        let export = app.buttons[
            "exportPageImages-jpegCompact"
        ].firstMatch
        XCTAssertTrue(reveal(export, in: app, maxSwipes: 12))
        tapCenter(export)
        XCTAssertTrue(
            app.otherElements["ActivityListView"]
                .waitForExistence(timeout: 30)
        )
        addScreenshot(named: "Exported page images in system share sheet", app: app)
        assertAppAlive(app)
    }

    func testHighlightJourneyWritesMarkupAfterCancelAndReentry()
        throws {
        runMarkupJourney(
            identifier: "highlight",
            query: "Highlight",
            expectedAnnotationTitle: "Highlight"
        )
    }

    func testTouchSelectionSurvivesOpeningMarkupTools() throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)
        let workspace = app.otherElements["pdfWorkspace"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 8))
        addScreenshot(named: "PDF before touch selection", app: app)
        let selectableTitle = workspace.staticTexts["Project handoff"]
            .firstMatch
        XCTAssertTrue(selectableTitle.waitForExistence(timeout: 5))
        selectableTitle.press(forDuration: 1.2)
        XCTAssertTrue(
            app.menuItems["Copy"].waitForExistence(timeout: 4)
                || app.buttons["Copy"].waitForExistence(timeout: 4)
        )
        addScreenshot(named: "Text selected by touch", app: app)
        openDocumentTool(identifier: "highlight", query: "Highlight", in: app)
        assertAnnotationResult(title: "Highlight", in: app)
    }

    func testUnderlineJourneyWritesMarkupAfterCancelAndReentry()
        throws {
        runMarkupJourney(
            identifier: "underline",
            query: "Underline",
            expectedAnnotationTitle: "Underline"
        )
    }

    func testStrikeoutJourneyWritesMarkupAfterCancelAndReentry()
        throws {
        runMarkupJourney(
            identifier: "strikeOut",
            query: "Strike",
            expectedAnnotationTitle: "Strikethrough"
        )
    }

    func testInkJourneyWritesDrawingAfterCancelAndReentry() throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_INK_FIXTURE"]
        )
        openDemoDocument(in: app)

        selectProfessionalMode("annotate", in: app)
        let inkTool = firstHittableButton(
            identifier: "workspaceTool-ink",
            in: app,
            timeout: 5
        )
        XCTAssertTrue(inkTool.isHittable)
        tapCenter(inkTool)
        XCTAssertTrue(
            app.navigationBars["Draw on page"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Draw on page", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        XCTAssertTrue(inkTool.waitForExistence(timeout: 5))
        XCTAssertTrue(inkTool.isHittable)
        tapCenter(inkTool)
        let save = app.buttons["inkSaveAction"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        let canvas = app.descendants(matching: .any)[
            "inkCanvas"
        ].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let viewport = app.scrollViews["inkViewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: save
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 15),
            .completed
        )
        let initialShapePosition = String(
            describing: canvas.value
        )
        XCTAssertTrue(
            initialShapePosition.contains("shape selected"),
            "The inserted shape should be directly editable"
        )
        addScreenshot(named: "Drawing and shape before touch move", app: app)
        canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).press(
            forDuration: 0.1,
            thenDragTo: canvas.coordinate(
                withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)
            )
        )
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return String(describing: element.value)
                    != initialShapePosition
            },
            object: canvas
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 5),
            .completed,
            "Dragging the inserted shape should change its position"
        )
        let selection = app.descendants(matching: .any)[
            "insertedShapeSelection"
        ].firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let originalSelectionFrame = selection.frame
        // This thin-line fixture has a 52-point logical selection height.
        // XCTest reports the frame after page fitting, including its scale.
        let handleInset = originalSelectionFrame.height * (20.0 / 52.0)
        let handle = selection.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: originalSelectionFrame.width - handleInset,
                dy: originalSelectionFrame.height - handleInset
            ))
        handle.press(
            forDuration: 0.1,
            thenDragTo: handle.withOffset(CGVector(dx: -40, dy: -10))
        )
        // The fixture is a thin line; its selection keeps a minimum hit height.
        // Shrinking also avoids clamping at the page edge after the move above.
        let resized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                selection.frame.width < originalSelectionFrame.width - 12
                    && abs(selection.frame.minX - originalSelectionFrame.minX) < 3
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [resized], timeout: 5),
            .completed,
            "Dragging the bottom-right handle should resize the selected shape"
        )
        addScreenshot(named: "Inserted shape after touch handle resize", app: app)
        let viewportMode = app.buttons["Move and zoom page"].firstMatch
        XCTAssertTrue(viewportMode.waitForExistence(timeout: 5))
        let fittedCanvasFrame = canvas.frame
        let fittedViewportFrame = viewport.frame
        XCTAssertLessThanOrEqual(fittedCanvasFrame.width, fittedViewportFrame.width + 1)
        XCTAssertLessThanOrEqual(fittedCanvasFrame.height, fittedViewportFrame.height + 1)
        let resizedShapeWidthRatio =
            selection.frame.width / fittedCanvasFrame.width
        XCTAssertFalse(viewportMode.isSelected)
        XCTAssertTrue(app.buttons["Lasso"].firstMatch.isSelected)
        // Large iPad canvases constrain the synthesized finger travel.
        canvas.pinch(withScale: 4, velocity: 1)
        let zoomed = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return element.frame.width
                    > fittedCanvasFrame.width * 1.25
            },
            object: canvas
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [zoomed], timeout: 5),
            .completed,
            "Pinching the page should enlarge the PDF and drawing together"
        )
        let visibleZoomFrame = canvas.frame.intersection(
            fittedViewportFrame
        )
        let fittedVisibleFrame = fittedCanvasFrame.intersection(fittedViewportFrame)
        XCTAssertGreaterThanOrEqual(
            visibleZoomFrame.width * visibleZoomFrame.height,
            fittedVisibleFrame.width * fittedVisibleFrame.height - 1,
            "Zooming must preserve the visible page area, including when the page already fits the viewport's aspect ratio."
        )
        XCTAssertTrue(
            app.buttons["Lasso"].firstMatch.isSelected,
            "Pinching must preserve the active drawing tool."
        )
        XCTAssertEqual(
            selection.frame.width / canvas.frame.width,
            resizedShapeWidthRatio,
            accuracy: 0.02,
            "Pinching the page must not resize the selected shape."
        )
        viewportMode.tap()
        XCTAssertTrue(viewportMode.isSelected)
        XCTAssertFalse(
            app.buttons["Lasso"].firstMatch.isSelected,
            "Moving the page must not present the lasso as the active tool."
        )
        addScreenshot(named: "Drawing and PDF after touch zoom", app: app)
        save.tap()
        XCTAssertTrue(
            app.navigationBars["Draw on page"]
                .waitForNonExistence(timeout: 30)
        )

        assertAnnotationResult(
            title: "Drawing",
            in: app
        )
    }

    func testNoteJourneyWritesCommentAfterCancelAndReentry() throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "note",
            query: "Note",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Add note"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Add note", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "note",
            query: "Note",
            in: app
        )
        let note = app.descendants(matching: .any)["noteText"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Automation note")
        let add = app.buttons["noteAddAction"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(
            app.navigationBars["Add note"]
                .waitForNonExistence(timeout: 20)
        )

        assertAnnotationResult(
            title: "Note",
            contents: "Automation note",
            in: app
        )
    }

    func testContentJourneyCreatesEditedCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "content",
            query: "Add Content",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Add Content"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Add Content", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "content",
            query: "Add Content",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "addContentStructureBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        let text = app.descendants(matching: .any)["contentText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.tap()
        text.typeText("Automation content")
        let create = app.buttons["contentCreateCopy"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: create
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 15),
            .completed
        )
        create.tap()

        let editedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Edited copy"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [editedCopyOpened], timeout: 30),
            .completed
        )
        assertAnnotationResult(
            title: "Added Text",
            contents: "Automation content",
            in: app
        )
    }

    func testCompressJourneyExplainsAlreadySmallerOriginalAfterReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "compress",
            query: "Compress",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Compress"].waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Compress", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "compress",
            query: "Compress",
            in: app
        )
        let create = app.buttons["compressionCreateAction"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "compressionOutputBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Original is already smaller"]
                .waitForExistence(timeout: 45)
        )
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(
            create.label.contains("Original Is Already Smaller")
        )
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        assertAppAlive(app)
    }

    func testDocumentProtectJourneyCreatesCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "protect",
            query: "Protect",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Protect PDF"].waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Protect PDF", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "protect",
            query: "Protect",
            in: app
        )
        completeProtection(
            navigationTitle: "Protect PDF",
            password: "PaperPath-Document-2026",
            in: app
        )
        let protectedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Protected copy"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [protectedCopyOpened],
                timeout: 30
            ),
            .completed
        )
        assertAppAlive(app)
    }

    func testLinksJourneyCreatesEditedCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "links",
            query: "Edit Links",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Edit Links"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Edit Links", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "links",
            query: "Edit Links",
            in: app
        )
        let label = app.textFields["existingLinkLabel"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        label.tap()
        label.typeText(" Automation")
        let create = app.buttons["createLinkEditedCopy"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: create
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 8),
            .completed
        )
        create.tap()

        let linkCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Links edited"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [linkCopyOpened], timeout: 45),
            .completed
        )
        assertAppAlive(app)
    }

    func testSignJourneyPlacesSignatureAfterCancelAndReentry()
        throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_INK_FIXTURE"]
        )
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "sign",
            query: "Sign",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Add signature", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "sign",
            query: "Sign",
            in: app
        )
        let advance = app.buttons["Place on Page"].firstMatch
        XCTAssertTrue(advance.waitForExistence(timeout: 8))
        let canAdvance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: advance
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [canAdvance], timeout: 15),
            .completed
        )
        advance.tap()

        let place = app.buttons["placeSignatureOnly"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 8))
        let canPlace = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: place
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [canPlace], timeout: 10),
            .completed
        )
        place.tap()
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForNonExistence(timeout: 30)
        )
        assertAnnotationResult(title: "Signature", in: app)
    }

    func testRedactJourneyCreatesSecureCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_PRESELECT_TEXT"]
        )
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "redact",
            query: "Redact",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Review redactions"]
                .waitForExistence(timeout: 15)
        )
        dismissPresentedWorkflow(title: "Review redactions", in: app)
        let cancelMode = app.buttons["cancelRedactionMode"].firstMatch
        XCTAssertTrue(cancelMode.waitForExistence(timeout: 5))
        cancelMode.tap()
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "redact",
            query: "Redact",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Review redactions"]
                .waitForExistence(timeout: 15)
        )
        let create = app.buttons["redactionCreateAction"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isEnabled)
        create.tap()

        let redactedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Redacted copy"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [redactedCopyOpened], timeout: 45),
            .completed
        )
        assertAppAlive(app)
    }

    func testPrivacyScanJourneyCreatesManagedVerifiedCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(named: "August invoice", in: app)

        let scan = app.buttons["privacyScanButton"].firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertTrue(scan.isEnabled)
        scan.tap()
        XCTAssertTrue(
            app.buttons["privacyScanClose"]
                .waitForExistence(timeout: 8)
        )
        dismissPrivacyScan(in: app)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "August invoice"
        )

        XCTAssertTrue(app.buttons["privacyScanClose"].waitForNonExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: scan
        )], timeout: 8), .completed)
        scan.tap()
        let privacyCandidate =
            app.staticTexts["b***@example.com"].firstMatch
        XCTAssertTrue(
            privacyCandidate.waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "privacyReviewSummary"
            ].firstMatch.exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "privacyRedactionScope"
            ].firstMatch.exists
        )
        let findingReason = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "privacyFindingReason-"
            )
        ).firstMatch
        XCTAssertTrue(reveal(findingReason, in: app, maxSwipes: 6))
        let findingSource = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "privacyFindingSource-"
            )
        ).firstMatch
        XCTAssertTrue(reveal(findingSource, in: app, maxSwipes: 6))
        addScreenshot(
            named: "Privacy Scan Review",
            app: app
        )
        let locate = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "privacyLocate-"
            )
        ).firstMatch
        XCTAssertTrue(reveal(locate, in: app, maxSwipes: 6))
        XCTAssertGreaterThanOrEqual(locate.frame.width, 44)
        XCTAssertGreaterThanOrEqual(locate.frame.height, 44)
        tapCenter(locate)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "August invoice"
        )

        XCTAssertTrue(app.buttons["privacyScanClose"].waitForNonExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: scan
        )], timeout: 8), .completed)
        scan.tap()
        XCTAssertTrue(
            app.staticTexts["b***@example.com"]
                .waitForExistence(timeout: 30)
        )

        let redact = app.buttons["privacyRedactionAction"].firstMatch
        XCTAssertTrue(redact.waitForExistence(timeout: 5))
        XCTAssertTrue(redact.isEnabled)
        XCTAssertTrue(redact.label.contains("1"))
        redact.tap()
        let cancel = app.buttons["privacyRedactionCancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(redact.waitForExistence(timeout: 5))
        XCTAssertTrue(redact.isEnabled)
        redact.tap()
        let confirm = app.descendants(matching: .any)[
            "privacyRedactionConfirm"
        ].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        addScreenshot(
            named: "Privacy Redaction Confirmation",
            app: app
        )
        confirm.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "privacyRedactionVerified"
            ].firstMatch.waitForExistence(timeout: 60)
        )
        let share = app.buttons["privacyShareVerifiedCopy"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isHittable)
        let openCopy = app.buttons["privacyOpenCreatedCopy"].firstMatch
        XCTAssertTrue(openCopy.waitForExistence(timeout: 5))
        XCTAssertTrue(openCopy.isHittable)
        addScreenshot(
            named: "Privacy Redaction Completed",
            app: app
        )
        share.tap()
        let shareSheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15))
        addScreenshot(named: "Privacy verified copy in system share sheet", app: app)
        if let closeShare = app.buttons.matching(identifier: "Close")
            .allElementsBoundByIndex.first(where: \.isHittable) {
            closeShare.tap()
        } else {
            XCTAssertTrue(
                app.otherElements["PopoverDismissRegion"].firstMatch.exists
            )
            let shareFrame = shareSheet.frame
            XCTAssertGreaterThan(shareFrame.minY - app.frame.minY, 32)
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(
                    dx: shareFrame.midX - app.frame.minX,
                    dy: shareFrame.minY - app.frame.minY - 16
                )
            ).tap()
        }
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 5))
        openCopy.tap()
        let relatedDocuments = app.buttons[
            "workspaceRelatedDocumentsMenu"
        ].firstMatch
        XCTAssertTrue(
            relatedDocuments.waitForExistence(timeout: 45)
        )
        XCTAssertTrue(relatedDocuments.isHittable)
        addScreenshot(
            named: "Result copy relationship",
            app: app
        )
        let openSource = app.buttons[
            "documentRelationshipOpenSource"
        ].firstMatch
        relatedDocuments.tap()
        XCTAssertTrue(openSource.waitForExistence(timeout: 5))
        XCTAssertTrue(openSource.isHittable)
        let resultRole = app.descendants(matching: .any)[
            "documentRelationshipRole"
        ].firstMatch
        XCTAssertTrue(resultRole.exists)
        XCTAssertTrue(
            resultRole.label.contains("Result copy")
                || resultRole.label.contains("结果副本")
        )
        XCTAssertTrue(
            workspaceDocumentTitle(in: app).label
                .hasPrefix("August invoice - ")
        )
        addScreenshot(
            named: "Redacted Copy Relationship",
            app: app
        )
        openSource.tap()
        let sourceOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "August invoice"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sourceOpened], timeout: 20),
            .completed
        )
        let workingRole = app.descendants(matching: .any)[
            "documentRelationshipRole"
        ].firstMatch
        XCTAssertTrue(workingRole.exists)
        XCTAssertTrue(
            workingRole.label.contains("Working copy")
                || workingRole.label.contains("工作副本")
        )
        addScreenshot(
            named: "Working copy relationship",
            app: app
        )
        let sourceRelatedDocuments = app.buttons[
            "workspaceRelatedDocumentsMenu"
        ].firstMatch
        XCTAssertTrue(
            sourceRelatedDocuments.waitForExistence(timeout: 5)
        )
        sourceRelatedDocuments.tap()
        let openLatest = app.buttons[
            "documentRelationshipOpenLatestResult"
        ].firstMatch
        XCTAssertTrue(openLatest.waitForExistence(timeout: 5))
        XCTAssertTrue(openLatest.isHittable)
        addScreenshot(
            named: "Source With Latest Result",
            app: app
        )
        openLatest.tap()
        let latestResultRelationship = app.buttons[
            "workspaceRelatedDocumentsMenu"
        ].firstMatch
        XCTAssertTrue(
            latestResultRelationship.waitForExistence(timeout: 20)
        )
        latestResultRelationship.tap()
        XCTAssertTrue(
            app.buttons["documentRelationshipOpenSource"]
                .firstMatch.waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            workspaceDocumentTitle(in: app).label
                .hasPrefix("August invoice - ")
        )
        assertAppAlive(app)
    }

    func testSignatureEnglishStandardJourney() throws {
        try signatureStandardJourney(chinese: false)
    }

    func testSignatureChineseStandardJourney() throws {
        try signatureStandardJourney(chinese: true)
    }

    /// Uses the real library and redaction pipeline, so the result preview must
    /// be a retained, verified copy rather than a presentation-only fixture.
    private func signatureStandardJourney(chinese: Bool) throws {
        continueAfterFailure = false
        let name = chinese ? "Signature Chinese" : "Signature English"
        let app = XCUIApplication()
        app.launchArguments = [
            "UITEST_RESET_DEMO",
            "-AppleLanguages", chinese ? "(zh-Hans)" : "(en)",
            "-AppleLocale", chinese ? "zh_CN" : "en_US",
            "-app.language", chinese ? "zh-Hans" : "en",
            "-privacy.appLockEnabled", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-privacy.hideLibraryPreviews", "NO",
            "-workspace.toolMode", "read"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        let primary = app.buttons["deskImport"].firstMatch
        XCTAssertTrue(primary.waitForExistence(timeout: 8))
        XCTAssertTrue(primary.isHittable)
        addScreenshot(named: "\(name) Home", app: app)

        selectWorkspaceLane(title: "Tools", identifier: "workspaceLane-tasks", in: app)
        XCTAssertTrue(app.buttons["quickTool-mergePDFs"].waitForExistence(timeout: 5))
        addScreenshot(named: "\(name) Tools", app: app)
        openDemoDocument(named: "August invoice", in: app)
        selectProfessionalMode("read", chinese: chinese, in: app)
        let document = app.descendants(matching: .any)["pdfWorkspace"].firstMatch
        XCTAssertGreaterThan(document.frame.height / app.frame.height, 0.45)
        addScreenshot(named: "\(name) Reader", app: app)

        app.buttons["privacyScanButton"].firstMatch.tap()
        let summary = app.descendants(matching: .any)["privacyReviewSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        if UIDevice.current.userInterfaceIdiom == .pad {
            let firstFinding = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "privacyLocate-")
            ).firstMatch
            XCTAssertTrue(
                firstFinding.isHittable,
                "The first finding must be reachable without scrolling past the summary on iPad."
            )
        }
        let clear = app.buttons["privacyClearSelection"].firstMatch
        XCTAssertTrue(revealTowardTop(clear, in: app, maxSwipes: 6))
        clear.tap()
        let redact = app.buttons["privacyRedactionAction"].firstMatch
        XCTAssertTrue(redact.exists)
        XCTAssertFalse(redact.isEnabled)
        addScreenshot(named: "\(name) Privacy Zero Selection", app: app)
        let selectAll = app.buttons["privacySelectAll"].firstMatch
        XCTAssertTrue(selectAll.isHittable)
        selectAll.tap()
        XCTAssertTrue(redact.isEnabled)
        XCTAssertGreaterThanOrEqual(redact.frame.height, 44)
        XCTAssertLessThanOrEqual(redact.frame.maxX, app.frame.maxX)
        addScreenshot(named: "\(name) Privacy Review", app: app)
        redact.tap()
        let cancel = app.buttons["privacyRedactionCancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        addScreenshot(named: "\(name) Redaction Confirmation", app: app)
        cancel.tap()
        XCTAssertTrue(redact.isEnabled)
        redact.tap()
        app.buttons["privacyRedactionConfirm"].firstMatch.tap()
        let verified = app.descendants(matching: .any)["privacyRedactionVerified"].firstMatch
        XCTAssertTrue(verified.waitForExistence(timeout: 60))
        let share = app.buttons["privacyShareVerifiedCopy"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled)
        XCTAssertTrue(share.isHittable)
        XCTAssertTrue(
            app.buttons["privacyOpenCreatedCopy"].firstMatch
                .waitForExistence(timeout: 5)
        )
        addScreenshot(named: "\(name) Verified Copy", app: app)
        app.buttons["privacyRedactionDone"].firstMatch.tap()
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "August invoice")
        app.terminate()
    }

    func testPrivacyScanReviewLayoutMatrix() throws {
        let variants: [(
            name: String,
            arguments: [String],
            expectsAppearanceMenu: Bool
        )] = [
            (
                name: "English Light Regular",
                arguments: [
                    "-AppleInterfaceStyle", "Light",
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryL"
                ],
                expectsAppearanceMenu: false
            ),
            (
                name: "Chinese Dark Accessibility",
                arguments: [
                    "-AppleLanguages", "(zh-Hans)",
                    "-AppleLocale", "zh_CN",
                    "-app.language", "zh-Hans",
                    "-AppleInterfaceStyle", "Dark",
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL"
                ],
                expectsAppearanceMenu: true
            )
        ]

        for variant in variants {
            let app = makeApp()
            app.launchArguments += [
                "UITEST_RESET_DEMO",
                "-workspace.toolMode",
                "pages"
            ] + variant.arguments
            app.launch()
            XCTAssertTrue(waitForLibrary(in: app))
            openDemoDocument(named: "August invoice", in: app)

            let scan = app.buttons["privacyScanButton"].firstMatch
            XCTAssertTrue(scan.waitForExistence(timeout: 5))
            scan.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)[
                    "privacyReviewSummary"
                ].firstMatch.waitForExistence(timeout: 30)
            )
            let action = app.descendants(matching: .any)[
                "privacyRedactionAction"
            ].firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            XCTAssertLessThanOrEqual(action.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            let firstFinding = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "privacyFinding-"
                )
            ).firstMatch
            XCTAssertTrue(reveal(firstFinding, in: app, maxSwipes: 12))
            for _ in 0..<8
            where firstFinding.frame.maxY > action.frame.minY {
                app.swipeUp()
            }
            XCTAssertTrue(app.frame.intersects(firstFinding.frame))
            XCTAssertLessThan(firstFinding.frame.minY, action.frame.minY)
            XCTAssertLessThanOrEqual(
                firstFinding.frame.maxY,
                action.frame.minY
            )

            if variant.expectsAppearanceMenu {
                let selectionMenu = app.descendants(matching: .any)[
                    "privacySelectionMenu"
                ].firstMatch
                XCTAssertTrue(
                    revealTowardTop(
                        selectionMenu,
                        in: app,
                        maxSwipes: 8
                    )
                )
                XCTAssertFalse(
                    app.descendants(matching: .any)[
                        "privacyRedactionScope"
                    ].firstMatch.exists
                )
            } else {
                let selectAll =
                    app.descendants(matching: .any)[
                        "privacySelectAll"
                    ].firstMatch
                let deselectAll =
                    app.descendants(matching: .any)[
                        "privacyClearSelection"
                    ].firstMatch
                XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
                XCTAssertTrue(deselectAll.waitForExistence(timeout: 5))
                XCTAssertEqual(selectAll.label, "Select All")
                XCTAssertEqual(deselectAll.label, "Deselect All")
            }

            if variant.expectsAppearanceMenu {
                let appearanceMenu = app.descendants(matching: .any)[
                    "privacyAppearanceMenu"
                ].firstMatch
                XCTAssertTrue(
                    reveal(appearanceMenu, in: app, maxSwipes: 8)
                )
            } else {
                XCTAssertTrue(
                    app.descendants(matching: .any)[
                        "privacyAppearance-black"
                    ].firstMatch.waitForExistence(timeout: 5)
                )
                XCTAssertTrue(
                    app.descendants(matching: .any)[
                        "privacyAppearance-white"
                    ].firstMatch.exists
                )
            }

            addScreenshot(
                named: "Privacy Review \(variant.name)",
                app: app
            )
            dismissPrivacyScan(in: app)
            app.terminate()
        }
    }

    func testFillFormJourneyAddsFieldAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "fillForm",
            query: "Fill Form",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Fill Form"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Fill Form", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "fillForm",
            query: "Fill Form",
            in: app
        )
        let addField = app.buttons["addFormFieldFromReview"].firstMatch
        XCTAssertTrue(reveal(addField, in: app, maxSwipes: 12))
        addField.tap()
        XCTAssertTrue(
            app.navigationBars["Place Form Field"]
                .waitForExistence(timeout: 8)
        )
        let name = app.textFields["formFieldName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Automation field")
        let add = app.buttons["addFormField"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: add
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 15),
            .completed
        )
        add.tap()
        XCTAssertTrue(
            app.navigationBars["Fill Form"]
                .waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            waitForFormField(
                named: "Automation field",
                in: app
            )
        )
        assertAppAlive(app)
    }

    func testOCRJourneyProducesSearchableResultAfterCancelAndReentry()
        throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_POLISH_OCR",
            "-workspace.toolMode",
            "pages"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: "Polish scan", in: app)

        openDocumentTool(
            identifier: "recognize",
            query: "OCR",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Recognition"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Recognition", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Polish scan")

        openDocumentTool(
            identifier: "recognize",
            query: "OCR",
            in: app
        )
        let start = app.buttons["startOCR"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: start
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 20),
            .completed
        )
        start.tap()
        XCTAssertTrue(
            app.buttons["recognizedTextCopyMenu"]
                .waitForExistence(timeout: 90)
        )
        addScreenshot(named: "Signature OCR Result", app: app)
        let openSearch = app.buttons["Search recognized text"].firstMatch
        XCTAssertTrue(openSearch.waitForExistence(timeout: 5))
        XCTAssertTrue(openSearch.isHittable)
        openSearch.tap()
        let search = app.searchFields["Search recognized text"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        search.typeText("Delivery")
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        XCTAssertTrue(
            app.buttons["copyFilteredRecognizedPages"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["copyFilteredRecognizedPages"].isEnabled)
        addScreenshot(named: "Signature OCR Filtered Result", app: app)
        assertAppAlive(app)
    }

    func testFindJourneyReturnsResultAfterCancelAndReentry() throws {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_PREPARE_FIND_INDEX"]
        )
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "find",
            query: "Find",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Find"].waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Find", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "find",
            query: "Find",
            in: app
        )
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("local")
        let result = app.buttons["documentFindResult-0"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No results"].exists)
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        let viewPDF = app.buttons["documentFindViewPDF"].firstMatch
        XCTAssertTrue(viewPDF.waitForExistence(timeout: 5))
        viewPDF.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"].waitForExistence(timeout: 8)
        )
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        assertAppAlive(app)
    }

    func testCompareJourneyLoadsResultAfterCancelAndReentry() throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "compare",
            query: "Compare Versions",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Compare Versions"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Compare Versions", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "compare",
            query: "Compare Versions",
            in: app
        )
        let compare = app.buttons["compareVersionsButton"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 8))
        XCTAssertTrue(compare.isEnabled)
        compare.tap()
        XCTAssertTrue(
            app.staticTexts["COMPARISON RESULT"]
                .waitForExistence(timeout: 30)
        )
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
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        assertAppAlive(app)
    }

    func testBookmarksJourneyPersistsResultAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "bookmarks",
            query: "Bookmarks",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Navigate"].waitForExistence(timeout: 8)
        )
        let bookmark = app.buttons["navigationCurrentBookmark"].firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        let bookmarkReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: bookmark
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [bookmarkReady], timeout: 15),
            .completed
        )
        bookmark.tap()
        let cancelledName = app.alerts.textFields.firstMatch
        XCTAssertTrue(cancelledName.waitForExistence(timeout: 5))
        cancelledName.typeText("Cancelled bookmark")
        app.alerts.buttons["Cancel"].tap()
        dismissPresentedWorkflow(title: "Navigate", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "bookmarks",
            query: "Bookmarks",
            in: app
        )
        XCTAssertFalse(app.staticTexts["Cancelled bookmark"].exists)
        let reopenedBookmark =
            app.buttons["navigationCurrentBookmark"].firstMatch
        let reopenedReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: reopenedBookmark
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reopenedReady], timeout: 15),
            .completed
        )
        reopenedBookmark.tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Automation bookmark")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(
            app.staticTexts["Automation bookmark"]
                .waitForExistence(timeout: 15)
        )
        dismissPresentedWorkflow(title: "Navigate", in: app)

        openDocumentTool(
            identifier: "bookmarks",
            query: "Bookmarks",
            in: app
        )
        XCTAssertTrue(
            app.staticTexts["Automation bookmark"]
                .waitForExistence(timeout: 15)
        )
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.staticTexts["Automation bookmark"]
                .waitForExistence(timeout: 15)
        )
        let resumedBookmark = app.buttons["navigationCurrentBookmark"].firstMatch
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND enabled == true"),
                    object: resumedBookmark
                )],
                timeout: 15
            ),
            .completed
        )
        addScreenshot(named: "Bookmarks restored after background", app: app)
        assertAppAlive(app)
    }

    func testOrganizeJourneyCreatesCopyAfterCancelAndReentry() throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "organize",
            query: "Organize",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Organize pages"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Organize pages", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "organize",
            query: "Organize",
            in: app
        )
        completePageExtraction(in: app)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "Project handoff - extracted pages"
        )
        assertAppAlive(app)
    }

    func testExportJourneyProducesPageFilesAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        openDemoDocument(in: app)

        openDocumentTool(
            identifier: "export",
            query: "Export",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Create & Share"]
                .waitForExistence(timeout: 8)
        )
        dismissPresentedWorkflow(title: "Create & Share", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: "export",
            query: "Export",
            in: app
        )
        let pdf = app.descendants(matching: .any)[
            "exportCatalogMode-pdf"
        ].firstMatch
        XCTAssertTrue(reveal(pdf, in: app, maxSwipes: 8))
        tapCenter(pdf)
        let flattened = app.buttons["flattenedOutputOption"]
            .firstMatch
        XCTAssertTrue(reveal(flattened, in: app, maxSwipes: 8))
        XCTAssertTrue(
            app.staticTexts[
                "Image-based: removes search, links, forms, and editable layers"
            ].exists
        )
        let images = app.descendants(matching: .any)[
            "exportCatalogMode-images"
        ].firstMatch
        XCTAssertTrue(reveal(images, in: app, maxSwipes: 8))
        tapCenter(images)
        completePageImageExport(in: app)
        assertAppAlive(app)
    }

    func testEveryPDFQuickToolRemainsDiscoverable() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Tools",
            identifier: "workspaceLane-tasks",
            in: app
        )

        let quickTools = [
            ("scanToPDF", "Scan to PDF"),
            ("imagesToPDF", "Images to PDF"),
            ("mergePDFs", "Merge PDFs"),
            ("splitPDF", "Split PDF"),
            ("organizePages", "Organize Pages"),
            ("compressPDF", "Compress PDF"),
            ("fillForms", "Fill Forms"),
            ("signPDF", "Sign PDF"),
            ("redactPDF", "Redact PDF"),
            ("protectPDF", "Protect PDF"),
            ("safeShare", "Verify Share"),
            ("recognizeText", "OCR PDF"),
            ("exportText", "PDF Office"),
            ("exportImages", "PDF Images")
        ]

        for (identifier, query) in quickTools {
            let search = librarySearchField(in: app)
            XCTAssertTrue(
                search.waitForExistence(timeout: 3),
                "Library search is unavailable for \(identifier)"
            )
            search.tap()
            search.typeText(query)

            XCTAssertTrue(
                app.buttons["quickTool-\(identifier)"]
                    .waitForExistence(timeout: 3),
                "Quick tool \(identifier) is not discoverable"
            )

            let clear = app.buttons["Clear text"].firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 2))
            clear.tap()
        }
    }

    func testEveryDocumentToolRemainsDiscoverable() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-workspace.toolMode",
            "pages",
            "-workspace.showToolNames",
            "NO"
        ]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let librarySearch = librarySearchField(in: app)
        librarySearch.tap()
        librarySearch.typeText("Project handoff")
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 10)
        )

        selectProfessionalMode("pages", in: app)
        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"].waitForExistence(timeout: 5)
        )
        let documentTools = [
            ("brief", "Brief"),
            ("find", "Find"),
            ("recognize", "Recognize"),
            ("highlight", "Highlight"),
            ("underline", "Underline"),
            ("strikeOut", "Strike"),
            ("ink", "Draw"),
            ("note", "Note"),
            ("stamp", "Stamp"),
            ("watermark", "Watermark"),
            ("bates", "Bates Numbering"),
            ("content", "Add Content"),
            ("links", "Edit Links"),
            ("annotations", "Annotations"),
            ("attachments", "Attachments"),
            ("compare", "Compare Versions"),
            ("sign", "Sign"),
            ("redact", "Redact"),
            ("fillForm", "Fill Form"),
            ("bookmarks", "Bookmarks"),
            ("organize", "Organize"),
            ("compress", "Compress"),
            ("protect", "Protect"),
            ("export", "Export")
        ]

        for (identifier, query) in documentTools {
            let search = documentToolSearchField(in: app)
            XCTAssertTrue(
                search.waitForExistence(timeout: 3),
                "Tool search is unavailable for \(identifier)"
            )
            search.tap()
            search.typeText(query)

            XCTAssertTrue(
                app.buttons["documentTool-\(identifier)"]
                    .firstMatch
                    .waitForExistence(timeout: 3),
                "Document tool \(identifier) is not discoverable"
            )

            let clear = app.buttons["Clear tool search"].firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 2))
            clear.tap()
        }
    }

    func testWorkspaceToolModesSurviveRepeatedRecomposition() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-workspace.toolMode",
            "read"
        ]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        let search = librarySearchField(in: app)
        search.tap()
        search.typeText("Project handoff")
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()

        let workspace = app.otherElements["pdfWorkspace"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let modes = [
            ("read", "workspaceFindAction"),
            ("annotate", "workspaceTool-highlight"),
            ("pages", "workspaceTool-organize"),
            ("deliver", "workspaceTool-fillForm")
        ]

        for iteration in 0..<4 {
            for (mode, expectedControl) in modes {
                selectProfessionalMode(mode, in: app)
                XCTAssertTrue(
                    app.buttons[expectedControl]
                        .waitForExistence(timeout: 3),
                    "\(mode) mode failed during iteration \(iteration + 1)"
                )
                XCTAssertTrue(workspace.exists)
            }
        }
    }

    func testIntroductionCanReturnHomeFromFirstPage() throws {
        let seeded = launchResetDemo()
        seeded.terminate()

        // Replay through the real Settings flow so launch defaults do not
        // override the completion value that the introduction writes.
        let app = makeApp()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        app.buttons["settings"].tap()
        let replay = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Replay Introduction")
        ).firstMatch
        XCTAssertTrue(revealForCenterTap(replay, in: app, maxSwipes: 12))
        tapCenter(replay)

        let home = app.buttons["onboardingOpenLibrary"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["samplePDFAction"].isHittable)
        addScreenshot(named: "Introduction first page", app: app)
        home.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 8))
        XCTAssertTrue(waitForLibrary(in: app))
        assertAppAlive(app)
    }

    func testIntroductionSampleRemainsReadableAfterRotation() throws {
        continueAfterFailure = false
        let seeded = launchResetDemo()
        seeded.terminate()
        let app = makeApp()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        let sample = app.buttons["samplePDFAction"]
        if !sample.waitForExistence(timeout: 2) {
            app.buttons["settings"].tap()
            let replay = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Replay Introduction")
            ).firstMatch
            XCTAssertTrue(revealForCenterTap(replay, in: app, maxSwipes: 12))
            tapCenter(replay)
        }
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        sample.tap()
        let workspace = app.otherElements["pdfWorkspace"].firstMatch
        if !workspace.waitForExistence(timeout: 3) {
            let open = app.buttons["deskOpenDocument"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 8))
            open.tap()
        }
        XCTAssertTrue(workspace.waitForExistence(timeout: 15))
        let title = workspaceDocumentTitle(in: app).label
        addScreenshot(named: "Sample reader portrait", app: app)

        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
                object: app
            )], timeout: 8),
            .completed
        )
        XCTAssertTrue(workspace.exists)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        // UIKit publishes new bounds before its rotation animation finishes.
        Thread.sleep(forTimeInterval: 1)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Sample reader landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in app.frame.height > app.frame.width },
                object: app
            )], timeout: 8),
            .completed
        )
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        assertAppAlive(app)
    }

    func testFindEmptyStateRemainsReachableAtAccessibilityXXXL() throws {
        continueAfterFailure = false
        let app = launchResetDemo(additionalArguments: [
            "UITEST_PREPARE_FIND_INDEX",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        openDemoDocument(in: app)
        openDocumentTools(in: app)
        let toolSearch = documentToolSearchField(in: app)
        XCTAssertTrue(toolSearch.waitForExistence(timeout: 5))
        toolSearch.tap()
        toolSearch.typeText("Find")
        let find = app.buttons["documentTool-find"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(revealForCenterTap(find, in: app, maxSwipes: 8))
        XCTAssertEqual(toolSearch.value as? String, "Find")
        XCTAssertGreaterThan(find.frame.midY, toolSearch.frame.maxY)
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThan(find.frame.midY, app.keyboards.firstMatch.frame.minY)
        }
        addScreenshot(named: "Tool search above keyboard accessibility", app: app)
        tapCenter(find)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zzznomatchingtext")
        app.keyboards.buttons["Search"].tap()

        let clear = app.buttons["documentFindClearSearch"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        XCTAssertTrue(revealInPresentedSheet(clear, navigationTitle: "Find", in: app, maxSwipes: 12))
        addScreenshot(named: "Find empty state accessibility", app: app)
        tapCenter(clear)
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))

        search.tap()
        search.typeText("local")
        XCTAssertTrue(
            app.buttons["documentFindResult-0"].waitForExistence(timeout: 10)
        )
        app.keyboards.buttons["Search"].tap()
        let open = app.buttons["documentFindViewPDF"]
        // The result navigator is pinned below the list, outside its scroll content.
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isHittable)
        tapCenter(open)
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"].waitForExistence(timeout: 8)
        )
        assertAppAlive(app)
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

        selectProfessionalMode("read", in: app)
        let find = firstHittableButton(
            identifier: "workspaceFindAction",
            in: app,
            timeout: 5
        )
        XCTAssertTrue(find.isHittable)
        find.tap()
        let findNavigationBar = app.navigationBars["Find"].firstMatch
        XCTAssertTrue(findNavigationBar.waitForExistence(timeout: 5))
        let search = findNavigationBar.searchFields.firstMatch
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
        let clearText = findNavigationBar.buttons["Clear text"].firstMatch
        XCTAssertTrue(clearText.waitForExistence(timeout: 3))
        clearText.tap()
        search.tap()
        let history = app.descendants(matching: .any)[
            "documentFindHistory-local"
        ].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        tapCenter(history)
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
            app.navigationBars["Review Scan"]
                .waitForExistence(timeout: 8)
        )
        let undo = app.buttons["scanUndo"]
        XCTAssertTrue(undo.exists)
        XCTAssertFalse(undo.isEnabled)

        let rotate = scanPageAction(
            labeled: "Rotate Clockwise",
            in: app
        )
        XCTAssertTrue(rotate.waitForExistence(timeout: 3))
        tapCenter(rotate)
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

        let selectPages = app.descendants(matching: .any)[
            "scanSelectPages"
        ].firstMatch
        XCTAssertTrue(
            revealInScanReview(
                selectPages,
                in: app,
                maxSwipes: 4
            ),
            "Select Pages was not reachable above the completion bar"
        )
        selectPages.tap()
        let selectionSource = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND value == %@",
                "scanThumbnail-",
                "Adjustment source"
            )
        ).firstMatch
        XCTAssertTrue(selectionSource.waitForExistence(timeout: 3))
        let targetPage = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND value == %@",
                "scanThumbnail-",
                "Not selected"
            )
        ).firstMatch
        let selectionModeReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: targetPage
        )
        guard XCTWaiter.wait(
            for: [selectionModeReady],
            timeout: 3
        ) == .completed else {
            XCTFail("Scan review did not enter page selection mode")
            return
        }
        XCTAssertTrue(
            revealTowardTop(targetPage, in: app, maxSwipes: 4),
            "Target scan page was not reachable in selection mode"
        )
        let targetPageIdentifier = targetPage.identifier
        XCTAssertFalse(targetPageIdentifier.isEmpty)
        if app.frame.height <= 700 {
            let selectAll = scanPageAction(
                labeled: "Select All",
                in: app
            )
            XCTAssertTrue(
                selectAll.waitForExistence(timeout: 3),
                "Select All was not available on the compact screen"
            )
            selectAll.tap()
        } else {
            targetPage.tap()
        }
        let selectedTargetPage = app.buttons[targetPageIdentifier]
        let pageSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "Selected"
            ),
            object: selectedTargetPage
        )
        guard XCTWaiter.wait(
            for: [pageSelected],
            timeout: 3
        ) == .completed else {
            XCTFail("Target scan page was not selected")
            return
        }

        let rotateSelected = scanPageAction(
            labeled: "Rotate Selected",
            in: app
        )
        XCTAssertTrue(
            reveal(rotateSelected, in: app, maxSwipes: 4),
            "Rotate Selected was not reachable"
        )
        rotateSelected.tap()
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertFalse(undo.isEnabled)

        XCTAssertTrue(
            revealInScanReview(
                selectPages,
                in: app,
                maxSwipes: 4
            ),
            "Done selecting pages was not reachable"
        )
        selectPages.tap()
        let adjustCrop = scanPageAction(
            labeled: "Adjust crop",
            in: app
        )
        XCTAssertTrue(adjustCrop.waitForExistence(timeout: 3))
        if app.frame.height <= 700 {
            adjustCrop.tap()
        } else {
            tapCenter(adjustCrop)
        }
        let applyCrop = app.descendants(matching: .any)[
            "scanApplyCrop"
        ].firstMatch
        guard applyCrop.waitForExistence(timeout: 3) else {
            XCTFail("Manual crop editor did not open")
            return
        }
        let cancelCrop = app.descendants(matching: .any)[
            "scanCancelCrop"
        ].firstMatch
        guard cancelCrop.waitForExistence(timeout: 3) else {
            XCTFail("Manual crop cancel action was unavailable")
            return
        }
        tapCenter(cancelCrop)
        XCTAssertTrue(adjustCrop.waitForExistence(timeout: 3))
    }

    func testScanUnchangedSettingsDoNotCreateUndo() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO", "UITEST_OPEN_SCAN_REVIEW"
        ]
        app.launch()
        XCTAssertTrue(
            app.navigationBars["Review Scan"].waitForExistence(timeout: 8)
        )
        let undo = app.buttons["scanUndo"]
        XCTAssertFalse(undo.isEnabled)
        let apply = app.buttons["scanApplyToScope"]
        XCTAssertTrue(revealInScanReview(apply, in: app, maxSwipes: 5))
        apply.tap()
        XCTAssertFalse(
            undo.isEnabled,
            "Applying identical settings must not create an undo step."
        )
        let save = app.buttons["scanSave"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: save
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        addScreenshot(named: "Identical scan settings preserve clean undo", app: app)
    }

    func testScanUnchangedCropPreservesPreviousUndo() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO", "UITEST_OPEN_SCAN_REVIEW"
        ]
        app.launch()
        XCTAssertTrue(
            app.navigationBars["Review Scan"].waitForExistence(timeout: 8)
        )
        let document = app.buttons["scanEnhancement-document"]
        XCTAssertTrue(revealInScanReview(document, in: app, maxSwipes: 5))
        document.tap()
        let undo = app.buttons["scanUndo"]
        XCTAssertTrue(undo.isEnabled)
        let crop = scanPageAction(labeled: "Adjust crop", in: app)
        XCTAssertTrue(revealInScanReview(
            crop, in: app, maxSwipes: 5, includesPreview: true
        ))
        tapCenter(crop)
        let applyCrop = app.buttons["scanApplyCrop"]
        XCTAssertTrue(applyCrop.waitForExistence(timeout: 5))
        applyCrop.tap()
        XCTAssertTrue(undo.isEnabled)
        undo.tap()

        let original = app.buttons["scanEnhancement-original"]
        XCTAssertTrue(revealInScanReview(original, in: app, maxSwipes: 5))
        XCTAssertTrue(
            original.isSelected,
            "Confirming unchanged crop corners must preserve the enhancement undo."
        )
        XCTAssertFalse(undo.isEnabled)
        addScreenshot(named: "Unchanged crop keeps previous scan undo", app: app)
    }

    func testScanBrightnessRepeatedValueFinishesPreview() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "UITEST_OPEN_SCAN_REVIEW"
        ]
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Review Scan"]
                .waitForExistence(timeout: 8)
        )
        let save = app.buttons["scanSave"]
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: save
        )
        waitForExpectations(timeout: 8)

        let fineAdjustments = app.buttons["scanFineAdjustments"].firstMatch
        XCTAssertTrue(revealInScanReview(fineAdjustments, in: app, maxSwipes: 6))
        fineAdjustments.tap()
        let brightness = app.sliders["Brightness"].firstMatch
        XCTAssertTrue(
            revealInScanReview(brightness, in: app, maxSwipes: 6),
            app.debugDescription
        )
        let initialValue = try XCTUnwrap(brightness.value as? String)
        // The custom AX value is a signed brightness percentage, not the
        // normalized percentage assumed by XCTest's slider adjustment API.
        let maximum = brightness.coordinate(
            withNormalizedOffset: CGVector(dx: 1, dy: 0.5)
        )
        brightness.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).press(
            forDuration: 0.05, thenDragTo: maximum,
            withVelocity: .slow, thenHoldForDuration: 0.2
        )
        XCTAssertTrue(app.navigationBars["Review Scan"].exists)
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: save
        )
        waitForExpectations(timeout: 8)
        let adjustedValue = try XCTUnwrap(brightness.value as? String)
        XCTAssertNotEqual(adjustedValue, initialValue)
        XCTAssertEqual(adjustedValue, "+35%")

        brightness.coordinate(
            withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)
        ).press(
            forDuration: 0.05, thenDragTo: maximum,
            withVelocity: .slow, thenHoldForDuration: 0.2
        )
        XCTAssertTrue(app.navigationBars["Review Scan"].exists)
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: save
        )
        waitForExpectations(timeout: 3)
        XCTAssertEqual(brightness.value as? String, adjustedValue)
        XCTAssertFalse(app.staticTexts["Updating preview"].exists)
        addScreenshot(named: "Repeated scan brightness preview ready", app: app)
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
            app.navigationBars["Review Scan"]
                .waitForExistence(timeout: 8)
        )
        let blackAndWhite = app.buttons[
            "scanEnhancement-blackAndWhite"
        ]
        XCTAssertTrue(reveal(blackAndWhite, in: app, maxSwipes: 6))
        tapCenter(blackAndWhite)
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
            app.navigationBars["Review Scan"]
                .waitForExistence(timeout: 5)
        )

        let restoredBlackAndWhite = app.buttons[
            "scanEnhancement-blackAndWhite"
        ]
        XCTAssertTrue(
            reveal(restoredBlackAndWhite, in: app, maxSwipes: 6)
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
            title: "Tools",
            identifier: "workspaceLane-tasks",
            in: app
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
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
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
        XCTAssertTrue(apply.isHittable)

        cancel.tap()
        let tools = app.buttons["documentToolsAction"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        XCTAssertTrue(tools.isEnabled)
        XCTAssertFalse(cancel.exists)
        XCTAssertFalse(apply.exists)
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
    }

    func testCompareVersionsUsesClearLocalWorkflow() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
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
        XCTAssertTrue(
            app.descendants(matching: .any)["deliverySummary"]
                .waitForExistence(timeout: 3)
        )
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

        for summaryID in [
            "deliverySummary-source",
            "deliverySummary-output",
            "deliverySummary-issues",
            "deliverySummary-send-status"
        ] {
            let fact = app.descendants(matching: .any)[summaryID].firstMatch
            XCTAssertTrue(
                revealInDeliveryReceipt(fact, in: app, maxSwipes: 8),
                "\(summaryID) was not reachable in the delivery summary"
            )
        }
        XCTAssertTrue(revealTowardTop(share, in: app, maxSwipes: 8))
        share.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label BEGINSWITH %@ AND label CONTAINS[c] %@",
                    "Share with ",
                    "warning"
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

        guard expandVerificationDetails(in: app) else {
            XCTFail("Verification details did not expand")
            return
        }
        let protectMilestone = app.descendants(matching: .any)[
            "protectDeliveryMilestone"
        ].firstMatch
        XCTAssertTrue(
            revealInDeliveryReceipt(
                protectMilestone,
                in: app,
                maxSwipes: 8
            )
        )
        tapCenter(protectMilestone)
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
        guard expandVerificationDetails(in: setupApp) else {
            XCTFail("Verification details did not expand")
            return
        }
        let protectMilestone = setupApp.descendants(matching: .any)[
            "protectDeliveryMilestone"
        ].firstMatch
        XCTAssertTrue(
            revealInDeliveryReceipt(
                protectMilestone,
                in: setupApp,
                maxSwipes: 12
            )
        )
        tapCenter(protectMilestone)
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
        if receipt.exists, receipt.isHittable {
            tapCenter(receipt)
        } else {
            app.buttons["Document menu"].tap()
            app.buttons["Results"].firstMatch.tap()
            let menuReceipt = app.buttons["Delivery receipt"].firstMatch
            XCTAssertTrue(menuReceipt.waitForExistence(timeout: 5))
            menuReceipt.tap()
        }
        XCTAssertTrue(
            app.navigationBars["Delivery receipt"]
                .waitForExistence(timeout: 8)
        )

        guard expandVerificationDetails(in: app) else {
            XCTFail("Verification details did not expand")
            return
        }
        let linkedMilestone = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openLinkedMilestone-"
            )
        ).firstMatch
        XCTAssertTrue(
            revealInDeliveryReceipt(
                linkedMilestone,
                in: app,
                maxSwipes: 20
            )
        )
        linkedMilestone.tap()
        let versionHistory = app.navigationBars[
            "Version History"
        ].firstMatch
        guard versionHistory.waitForExistence(timeout: 8) else {
            XCTFail("Version History did not open from the receipt")
            return
        }

        let editMilestone = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "editInspectedVersionMilestone-"
            )
        ).firstMatch
        guard revealInPresentedSheet(
                editMilestone,
                navigationTitle: "Version History",
                in: app,
                maxSwipes: 14
        ) else {
            XCTFail("The milestone editor action was not reachable")
            return
        }
        let editMilestoneEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == YES"),
            object: editMilestone
        )
        guard XCTWaiter.wait(
            for: [editMilestoneEnabled],
            timeout: 15
        ) == .completed else {
            XCTFail("The milestone editor action remained disabled")
            return
        }
        tapCenter(editMilestone)

        let milestoneEditor = app.descendants(matching: .any)[
            "versionMilestoneEditor"
        ].firstMatch
        guard milestoneEditor.waitForExistence(timeout: 8) else {
            XCTFail("The milestone editor did not open")
            return
        }
        let receiptLink = app.descendants(
            matching: .any
        )["milestoneReceiptLink"]
        XCTAssertTrue(
            revealInContainer(
                receiptLink,
                container: milestoneEditor,
                maxSwipes: 8
            )
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

    func testLibrarySearchCancelHistoryAndDocumentReturn() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        XCTAssertFalse(app.searchFields["librarySearchField"].exists)

        for _ in 0..<3 {
            let search = librarySearchField(in: app)
            search.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            search.typeText("Project handoff")
            XCTAssertEqual(search.value as? String, "Project handoff")
            submitSearchKeyboard(in: app)
            let document = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-", "Project handoff"
            )).firstMatch
            XCTAssertTrue(reveal(document, in: app, maxSwipes: 5))
            addScreenshot(named: "Library search results", app: app)
            document.tap()
            XCTAssertTrue(app.otherElements["pdfWorkspace"].waitForExistence(timeout: 8))
            XCTAssertTrue(waitForLibrary(in: app))
            XCTAssertTrue(app.buttons["librarySearchButton"].waitForExistence(timeout: 5))
            let resumedSearch = librarySearchField(in: app)
            XCTAssertEqual(resumedSearch.value as? String, "Project handoff")
            let cancelSearch = app.buttons["librarySearchCancel"]
            XCTAssertTrue(cancelSearch.waitForExistence(timeout: 5))
            XCTAssertTrue(cancelSearch.isHittable)
            cancelSearch.tap()
            XCTAssertTrue(resumedSearch.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["settings"].isHittable)
        }

        _ = librarySearchField(in: app)
        let history = app.buttons["librarySearchHistory"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        app.buttons["Project handoff"].firstMatch.tap()
        XCTAssertEqual(
            app.searchFields["librarySearchField"].value as? String,
            "Project handoff"
        )
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["librarySearchCancel"].tap()
        addScreenshot(named: "Library after repeated search cancellation", app: app)
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

        let addField = app.buttons["addFormFieldFromReview"]
        XCTAssertTrue(reveal(addField, in: app, maxSwipes: 8))
        addField.tap()
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
        XCTAssertTrue(revealTowardTop(signatureField, in: app, maxSwipes: 8))
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
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)

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

        openPageOrganizer(in: app)
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
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        XCTAssertTrue(
            app.otherElements["libraryDocumentsSection"]
                .waitForExistence(timeout: 3)
        )
        addScreenshot(named: "PaperPath Accessibility Home XXXL", app: app)
        selectWorkspaceLane(
            title: "Tools",
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

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
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
        let exportResult = app.buttons["documentTool-export"].firstMatch
        XCTAssertTrue(reveal(exportResult, in: app, maxSwipes: 6))
        exportResult.tap()
        XCTAssertTrue(
            app.navigationBars["Create & Share"]
                .waitForExistence(timeout: 5)
        )

        let recommended = selectRecommendedOfficeExport(in: app)
        XCTAssertTrue(recommended.isEnabled)
        tapCenter(recommended)
        let convert = app.buttons["officeConvertAction"].firstMatch
        XCTAssertTrue(reveal(convert, in: app, maxSwipes: 8))
        convert.doubleTap()

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
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
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
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        let search = librarySearchField(in: app)
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
            let recommended = selectRecommendedOfficeExport(in: app)
            tapCenter(recommended)
            let convert = app.buttons["officeConvertAction"].firstMatch
            XCTAssertTrue(reveal(convert, in: app, maxSwipes: 8))
            convert.tap()

            let stop = app.descendants(matching: .any)[
                "officeExportStopAction"
            ].firstMatch
            XCTAssertTrue(
                stop.waitForExistence(timeout: 5),
                "Office export did not start on iteration \(iteration)"
            )
            XCTAssertTrue(
                tapCurrentFrame(of: stop, in: app),
                "Office stop action had no tappable frame on iteration \(iteration)"
            )
            let done = app.descendants(matching: .any)[
                "officeExportDoneAction"
            ].firstMatch
            guard finishOfficeExportCancellation(
                stop: stop,
                done: done,
                in: app,
                timeout: 20
            ) else {
                XCTFail(
                    "Cancellation did not settle on iteration \(iteration)"
                )
                return
            }
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
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        // XCUI element polling can return after the app has already rendered.
        let automationDriverAllowance: TimeInterval = 1
        let lanes = [
            ("workspaceLane-home", "Documents"),
            ("workspaceLane-tasks", "Tools"),
            ("workspaceLane-outputs", "Results")
        ]
        for iteration in 0..<20 {
            let lane = lanes[iteration % lanes.count]
            let startedAt = Date()
            selectWorkspaceLane(
                title: lane.1,
                identifier: lane.0,
                in: app
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(startedAt),
                4 + automationDriverAllowance,
                "Lane transition stalled on iteration \(iteration)"
            )
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 1)
            )
        }

        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        let search = librarySearchField(in: app)
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

        selectProfessionalMode("pages", in: app)
        // Twenty lane changes plus twenty Tools and twenty Find
        // open/close pairs exercise 100 high-frequency transitions.
        for iteration in 0..<20 {
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 3),
                "App was not foregrounded on iteration \(iteration)"
            )
            let toolsButton = revealDocumentToolsButton(in: app)
            let toolsStartedAt = Date()
            tapCenter(toolsButton)
            let tools = app.navigationBars["Tools"]
            XCTAssertTrue(
                tools.waitForExistence(timeout: 3),
                "Tools did not open on iteration \(iteration)"
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(toolsStartedAt),
                3 + automationDriverAllowance,
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

            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 3),
                "App lost foreground after Tools on iteration \(iteration)"
            )
            selectProfessionalMode("read", in: app)
            let find = firstHittableButton(
                identifier: "workspaceFindAction",
                in: app,
                timeout: 2
            )
            guard find.isHittable else {
                XCTFail(
                    "Find was not reachable on iteration \(iteration)"
                )
                return
            }
            let findStartedAt = Date()
            find.tap()
            let findNavigation = app.navigationBars["Find"]
            XCTAssertTrue(
                findNavigation.waitForExistence(timeout: 3),
                "Find did not open on iteration \(iteration)"
            )
            XCTAssertLessThan(
                Date().timeIntervalSince(findStartedAt),
                3 + automationDriverAllowance,
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
            selectProfessionalMode("pages", in: app)
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

        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        XCTAssertTrue(app.otherElements["libraryDocumentsSection"].exists)
        let deskHeader = app.descendants(matching: .any)[
            "documentDeskHeader"
        ].firstMatch
        let importPDFs = app.buttons["deskImport"].firstMatch
        let scanPaper = app.buttons["deskScan"].firstMatch
        let firstDocument = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentRow-")
        ).firstMatch
        for element in [deskHeader, importPDFs, scanPaper, firstDocument] {
            XCTAssertTrue(element.waitForExistence(timeout: 3))
            XCTAssertTrue(element.isHittable)
            XCTAssertLessThanOrEqual(
                element.frame.maxY,
                app.frame.maxY,
                "The focused Home action must remain in the first viewport"
            )
        }
        addScreenshot(
            named: "PaperPath Focused Home First Screen",
            app: app
        )

        selectWorkspaceLane(
            title: "Tools",
            identifier: "workspaceLane-tasks",
            in: app
        )
        XCTAssertTrue(
            reveal(
                app.buttons["taskPackage-prepareToSend"],
                in: app,
                maxSwipes: 10
            )
        )
        XCTAssertFalse(firstDocument.exists)
        XCTAssertFalse(app.otherElements["libraryDocumentsSection"].exists)

        selectWorkspaceLane(
            title: "Results",
            identifier: "workspaceLane-outputs",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["deliveryCenter"]
                .firstMatch.exists
        )
        XCTAssertFalse(app.otherElements["libraryDocumentsSection"].exists)

        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        XCTAssertTrue(app.otherElements["libraryDocumentsSection"].exists)
        addScreenshot(named: "PaperPath Focused Home", app: app)
    }

    private func addScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertTwoPageDocumentNavigation(in app: XCUIApplication) {
        let firstPage = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Page 1 of 2")
        ).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 8))
        let next = app.buttons["Next page"].firstMatch
        XCTAssertTrue(next.isEnabled)
        next.tap()
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Page 2 of 2")
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(next.isEnabled)
    }

    private var englishLaunchArguments: [String] {
        [
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
            "-app.language",
            "en",
            "-privacy.appLockEnabled",
            "NO",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryL"
        ]
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = englishLaunchArguments
        return app
    }

    private func launchResetDemo(
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-workspace.toolMode",
            "pages"
        ] + additionalArguments
        app.launch()
        XCTAssertTrue(
            waitForLibrary(in: app),
            "The reset demo library did not become ready"
        )
        assertAppAlive(app)
        return app
    }

    private func openDemoDocument(
        named title: String = "Project handoff",
        in app: XCUIApplication
    ) {
        selectWorkspaceLane(
            title: "Documents",
            identifier: "workspaceLane-home",
            in: app
        )
        let row = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-",
                title
            )
        ).firstMatch
        XCTAssertTrue(
            revealForCenterTap(row, in: app, maxSwipes: 10),
            "Could not find demo document \(title)"
        )
        tapCenter(row)
        let workspace = app.otherElements["pdfWorkspace"].firstMatch
        if !workspace.waitForExistence(timeout: 2) {
            let open = app.buttons["deskOpenDocument"].firstMatch
            if reveal(open, in: app, maxSwipes: 8) {
                tapCenter(open)
            }
        }
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 8),
            "The PDF workspace did not open for \(title)"
        )
        let workspaceTitle = workspaceDocumentTitle(in: app)
        XCTAssertTrue(workspaceTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(
            workspaceTitle.label.localizedCaseInsensitiveContains(title)
        )
        assertAppAlive(app)
    }

    @discardableResult
    private func openDocumentTool(
        identifier: String,
        query: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"].waitForExistence(timeout: 5)
        )
        let search = documentToolSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText(query)
        let tool = app.buttons["documentTool-\(identifier)"].firstMatch
        XCTAssertTrue(
            tool.waitForExistence(timeout: 5),
            "Document tool \(identifier) was not available"
        )
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: tool
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 15),
            .completed,
            "Document tool \(identifier) did not become enabled"
        )
        XCTAssertTrue(revealForCenterTap(tool, in: app, maxSwipes: 8))
        tapCenter(tool)
        assertAppAlive(app)
        return tool
    }

    private func openQuickTask(
        identifier: String,
        query: String,
        documentTitle: String? = nil,
        in app: XCUIApplication
    ) {
        let hasLibrarySurface =
            app.descendants(matching: .any)[
                "libraryDocumentsSection"
            ].firstMatch.exists
            || app.descendants(matching: .any)[
                "taskPackagesSection"
            ].firstMatch.exists
            || app.descendants(matching: .any)[
                "deliveryCenter"
            ].firstMatch.exists
        if !hasLibrarySurface {
            XCTAssertTrue(
                waitForLibrary(in: app),
                "The Library was not reachable before opening \(identifier)"
            )
        }
        selectWorkspaceLane(
            title: "Tools",
            identifier: "workspaceLane-tasks",
            in: app
        )
        var task = app.buttons["quickTool-\(identifier)"].firstMatch
        if !revealForCenterTap(task, in: app, maxSwipes: 10) {
            let search = librarySearchField(in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            search.tap()
            search.typeText(query)
            task = app.buttons["quickTool-\(identifier)"].firstMatch
        }
        XCTAssertTrue(
            task.waitForExistence(timeout: 5),
            "Quick task \(identifier) was not available"
        )
        XCTAssertTrue(task.isEnabled)
        XCTAssertTrue(
            revealForCenterTap(task, in: app, maxSwipes: 10),
            "Quick task \(identifier) could not be centered for tapping"
        )
        tapCenter(task)

        guard let documentTitle else {
            assertAppAlive(app)
            return
        }
        let document = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "quickTaskDocument-",
                documentTitle
            )
        ).firstMatch
        XCTAssertTrue(
            document.waitForExistence(timeout: 8),
            "Document picker did not present \(documentTitle) for \(identifier)"
        )
        guard document.exists else { return }
        XCTAssertTrue(
            revealForCenterTap(document, in: app, maxSwipes: 10),
            "Could not choose \(documentTitle) for \(identifier)"
        )
        tapCenter(document)
        assertAppAlive(app)
    }

    private func dismissPresentedWorkflow(
        title: String,
        in app: XCUIApplication
    ) {
        let navigation = app.navigationBars[title].firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        let controls = [
            navigation.buttons["Cancel"].firstMatch,
            navigation.buttons["Close"].firstMatch,
            navigation.buttons["Done"].firstMatch
        ]
        guard let control = controls.first(where: {
            $0.exists && $0.isHittable
        }) else {
            XCTFail("No dismissal control was available for \(title)")
            return
        }
        tapCenter(control)
        for confirmationTitle in [
            "Discard Pages",
            "Discard Draft",
            "Discard Changes"
        ] {
            let confirmation = app.buttons[confirmationTitle].firstMatch
            if confirmation.waitForExistence(timeout: 1) {
                tapCenter(confirmation)
                break
            }
        }
        XCTAssertTrue(navigation.waitForNonExistence(timeout: 5))
        assertAppAlive(app)
    }

    private func dismissPrivacyScan(in app: XCUIApplication) {
        let close = app.buttons["privacyScanClose"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        assertAppAlive(app)
    }

    private func runMarkupJourney(
        identifier: String,
        query: String,
        expectedAnnotationTitle: String
    ) {
        let app = launchResetDemo(
            additionalArguments: ["UITEST_PRESELECT_TEXT"]
        )
        openDemoDocument(in: app)

        cancelDocumentToolSelection(
            identifier: identifier,
            query: query,
            in: app
        )
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")

        openDocumentTool(
            identifier: identifier,
            query: query,
            in: app
        )
        assertAnnotationResult(
            title: expectedAnnotationTitle,
            in: app
        )
    }

    private func cancelDocumentToolSelection(
        identifier: String,
        query: String,
        in app: XCUIApplication
    ) {
        openDocumentTools(in: app)
        XCTAssertTrue(
            app.navigationBars["Tools"].waitForExistence(timeout: 5)
        )
        let search = documentToolSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText(query)
        XCTAssertTrue(
            app.buttons["documentTool-\(identifier)"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        dismissPresentedWorkflow(title: "Tools", in: app)
    }

    private func assertAnnotationResult(
        title: String,
        contents: String? = nil,
        in app: XCUIApplication
    ) {
        openDocumentTool(
            identifier: "annotations",
            query: "Annotations",
            in: app
        )
        XCTAssertTrue(
            app.navigationBars["Comments & Markup"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.staticTexts[title].waitForExistence(timeout: 15),
            "Expected annotation type \(title)"
        )
        if let contents {
            XCTAssertTrue(
                app.staticTexts[contents].waitForExistence(timeout: 5),
                "Expected annotation contents \(contents)"
            )
        }
        XCTAssertGreaterThan(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "annotationRow-"
                )
            ).count,
            0
        )
        assertAppAlive(app)
    }

    private func completeProtection(
        navigationTitle: String,
        password value: String,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(
            app.navigationBars[navigationTitle]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "protectionPermissionBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        let password = app.descendants(matching: .any)[
            "protectionPassword"
        ].firstMatch
        let confirmation = app.descendants(matching: .any)[
            "protectionConfirmation"
        ].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        XCTAssertTrue(confirmation.exists)
        password.tap()
        password.typeText(value)
        let keyboardNext = app.keyboards.buttons["next"].firstMatch
        if keyboardNext.waitForExistence(timeout: 2) {
            keyboardNext.tap()
        } else {
            tapCenter(confirmation)
        }
        let confirmationFocused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: confirmation
        )
        if XCTWaiter.wait(
            for: [confirmationFocused],
            timeout: 3
        ) != .completed {
            tapCenter(confirmation)
        }
        let confirmationRefocused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: confirmation
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [confirmationRefocused],
                timeout: 3
            ),
            .completed
        )
        confirmation.typeText(value)
        let create = app.buttons["protectionCreateAction"].firstMatch
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: create
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 8),
            .completed
        )
        create.tap()
        XCTAssertTrue(
            app.navigationBars[navigationTitle]
                .waitForNonExistence(timeout: 45)
        )
    }

    private func completePageExtraction(in app: XCUIApplication) {
        XCTAssertTrue(
            app.navigationBars["Organize pages"]
                .waitForExistence(timeout: 8)
        )
        let select = app.buttons["selectOrganizerPages"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let selection = app.buttons["pageSelectionMenu"].firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        selection.tap()
        app.buttons["All Pages"].tap()
        let actions = app.buttons["pageSelectionActions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let extract = app.buttons["Extract to New PDF"].firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 5))
        extract.tap()
        XCTAssertTrue(
            app.staticTexts["Project handoff - extracted pages"]
                .waitForExistence(timeout: 30)
        )
        let extractedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - extracted pages"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [extractedCopyOpened],
                timeout: 15
            ),
            .completed
        )
    }

    private func completeFormField(
        named fieldName: String,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(
            app.navigationBars["Fill Form"].waitForExistence(timeout: 8)
        )
        let addField = app.buttons["addFormFieldFromReview"].firstMatch
        XCTAssertTrue(reveal(addField, in: app, maxSwipes: 12))
        addField.tap()
        XCTAssertTrue(
            app.navigationBars["Place Form Field"]
                .waitForExistence(timeout: 8)
        )
        let name = app.textFields["formFieldName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(fieldName)
        let add = app.buttons["addFormField"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: add
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 15),
            .completed
        )
        add.tap()
        XCTAssertTrue(
            app.navigationBars["Fill Form"]
                .waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            waitForFormField(named: fieldName, in: app)
        )
    }

    private func completeSignature(in app: XCUIApplication) {
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "visualSignatureBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        let advance = app.buttons["Place on Page"].firstMatch
        XCTAssertTrue(advance.waitForExistence(timeout: 8))
        let canAdvance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: advance
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [canAdvance], timeout: 15),
            .completed
        )
        advance.tap()
        let place = app.buttons["placeSignatureOnly"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 8))
        let canPlace = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: place
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [canPlace], timeout: 10),
            .completed
        )
        place.tap()
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForNonExistence(timeout: 30)
        )
    }

    private func openQuickRedactionReview(in app: XCUIApplication) {
        let apply = app.buttons["applyRedactionSelection"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: apply
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 10),
            .completed
        )
        apply.tap()
        XCTAssertTrue(
            app.navigationBars["Review redactions"]
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "redactionOutputBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
    }

    private func completeRedaction(in app: XCUIApplication) {
        let create = app.buttons["redactionCreateAction"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let redactedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Redacted copy"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [redactedCopyOpened],
                timeout: 45
            ),
            .completed
        )
    }

    private func completeRecognition(
        query: String,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(
            app.navigationBars["Recognition"]
                .waitForExistence(timeout: 8)
        )
        let start = app.buttons["startOCR"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: start
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 20),
            .completed
        )
        start.tap()
        XCTAssertTrue(
            app.buttons["recognizedTextCopyMenu"]
                .waitForExistence(timeout: 90)
        )
        let search = app.searchFields["Search recognized text"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(query)
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        XCTAssertTrue(
            app.buttons["copyFilteredRecognizedPages"]
                .waitForExistence(timeout: 8)
        )
    }

    private func completeOfficeExport(in app: XCUIApplication) {
        XCTAssertTrue(
            app.navigationBars["Convert PDF"]
                .waitForExistence(timeout: 10)
        )
        let word = app.descendants(matching: .any)[
            "officeFormat-wordDocument"
        ].firstMatch
        XCTAssertTrue(reveal(word, in: app, maxSwipes: 8))
        tapCenter(word)
        let convert = app.buttons["officeConvertAction"].firstMatch
        XCTAssertTrue(reveal(convert, in: app, maxSwipes: 8))
        XCTAssertTrue(convert.isEnabled)
        convert.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "officeConversionResult"
            ].firstMatch.waitForExistence(timeout: 90)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "officeResultActions"
            ].firstMatch.exists
        )
        let share = app.buttons["Share output"].firstMatch
        XCTAssertTrue(reveal(share, in: app, maxSwipes: 8))
        XCTAssertTrue(share.isEnabled)
        tapCenter(share)
        XCTAssertTrue(
            app.otherElements["ActivityListView"]
                .waitForExistence(timeout: 30)
        )
    }

    private func completePageImageExport(in app: XCUIApplication) {
        let export = app.buttons[
            "exportPageImages-jpegCompact"
        ].firstMatch
        XCTAssertTrue(reveal(export, in: app, maxSwipes: 12))
        tapCenter(export)
        XCTAssertTrue(
            app.otherElements["ActivityListView"]
                .waitForExistence(timeout: 30)
        )
    }

    private func completeVerifiedShare(in app: XCUIApplication) {
        XCTAssertTrue(
            app.navigationBars["Finish & Share"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "safeShareOutputBoundary"
            ].firstMatch.waitForExistence(timeout: 5)
        )
        let create = app.buttons["safeShareButton"].firstMatch
        XCTAssertTrue(reveal(create, in: app, maxSwipes: 12))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: create
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 30),
            .completed
        )
        create.tap()
        let verifiedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff - Verified copy"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [verifiedCopyOpened],
                timeout: 45
            ),
            .completed
        )
    }

    private func assertAppAlive(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "PaperPath is no longer running in the foreground",
            file: file,
            line: line
        )
        let hasStableSurface =
            app.otherElements["pdfWorkspace"].firstMatch.exists
            || app.otherElements["libraryDocumentsSection"]
                .firstMatch.exists
            || !app.navigationBars.allElementsBoundByIndex.isEmpty
        if hasStableSurface {
            return
        }
        let stableSurface = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.otherElements["pdfWorkspace"].firstMatch.exists
                    || app.otherElements["libraryDocumentsSection"]
                        .firstMatch.exists
                    || !app.navigationBars.allElementsBoundByIndex.isEmpty
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [stableSurface], timeout: 3),
            .completed,
            "PaperPath has no reachable stable surface",
            file: file,
            line: line
        )
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
            selectProfessionalMode("deliver", in: app)
            let verify = app.buttons["Verify & Share"].firstMatch
            XCTAssertTrue(verify.waitForExistence(timeout: 5))
            verify.tap()
        } else {
            selectWorkspaceLane(
                title: "Tools",
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
        if receipt.exists, receipt.isHittable {
            receipt.tap()
        } else {
            app.buttons["Document menu"].tap()
            app.buttons["Results"].firstMatch.tap()
            let menuReceipt = app.buttons["Delivery receipt"].firstMatch
            XCTAssertTrue(menuReceipt.waitForExistence(timeout: 5))
            menuReceipt.tap()
        }
        let receiptNavigation = app.navigationBars[
            "Delivery receipt"
        ]
        XCTAssertTrue(receiptNavigation.waitForExistence(timeout: 8))
        return app
    }

    private func expandVerificationDetails(
        in app: XCUIApplication
    ) -> Bool {
        let protectMilestone = app.descendants(matching: .any)[
            "protectDeliveryMilestone"
        ].firstMatch
        let linkedMilestone = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "openLinkedMilestone-")
        ).firstMatch
        if protectMilestone.exists || linkedMilestone.exists {
            return true
        }
        let disclosure = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Verification details"
            )
        ).firstMatch
        guard revealInDeliveryReceipt(
            disclosure,
            in: app,
            maxSwipes: 8
        ) else {
            return false
        }
        disclosure.tap()
        return app.navigationBars["Delivery receipt"]
            .waitForExistence(timeout: 5)
    }

    private func waitForLibrary(in app: XCUIApplication) -> Bool {
        dismissBlockingAlert(in: app)
        dismissKeyboard(in: app)

        let workspace = app.descendants(matching: .any)[
            "pdfWorkspace"
        ].firstMatch
        let desk = app.descendants(matching: .any)[
            "returnToDocumentDesk"
        ].firstMatch
        if desk.waitForExistence(timeout: 3) {
            let deskReady = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "exists == true AND hittable == true"
                ),
                object: desk
            )
            _ = XCTWaiter.wait(for: [deskReady], timeout: 5)
            tapCenter(desk)
        } else if workspace.exists {
            let compactBack = app.buttons["BackButton"].firstMatch
            XCTAssertTrue(
                compactBack.waitForExistence(timeout: 3),
                "The compact workspace did not expose its Back button"
            )
            if compactBack.exists {
                tapCenter(compactBack)
            }
        }

        let libraryReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.dismissBlockingAlert(in: app)
                let hasLibrarySurface =
                    app.descendants(matching: .any)[
                        "libraryDocumentsSection"
                    ].firstMatch.exists
                    || app.descendants(matching: .any)[
                        "taskPackagesSection"
                    ].firstMatch.exists
                    || app.descendants(matching: .any)[
                        "deliveryCenter"
                    ].firstMatch.exists
                return hasLibrarySurface
                    && !app.buttons["returnToDocumentDesk"].firstMatch.exists
                    && !app.descendants(matching: .any)[
                        "pdfWorkspace"
                    ].firstMatch.exists
            },
            object: nil
        )
        return XCTWaiter.wait(
            for: [libraryReady],
            timeout: 20
        ) == .completed
    }

    private func waitForOfficeCorpusFixture(
        chinese: Bool = false,
        in app: XCUIApplication
    ) -> Bool {
        guard waitForLibrary(in: app) else {
            return false
        }
        selectWorkspaceLane(
            title: chinese ? "成果" : "Results",
            identifier: "workspaceLane-outputs",
            in: app
        )
        return app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "officeResult-"
            )
        ).firstMatch.waitForExistence(timeout: 90)
    }

    private func dismissBlockingAlert(in app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        if alert.exists {
            let ok = alert.buttons["OK"].firstMatch
            if ok.exists, ok.isHittable {
                ok.tap()
                return
            }
        }

        guard app.navigationBars["SwiftUI.PlatformAlert"]
            .firstMatch.exists
        else { return }
        let ok = app.buttons["OK"].firstMatch
        if ok.exists, ok.isHittable {
            tapCenter(ok)
        }
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        for label in ["Hide keyboard", "隐藏键盘"] {
            let hide = app.keyboards.buttons[label].firstMatch
            if hide.exists, hide.isHittable {
                hide.tap()
                return
            }
        }
    }

    private func submitSearchKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        for identifier in ["Search", "search", "搜索"] {
            let submit = app.keyboards.buttons[identifier].firstMatch
            if submit.exists, submit.isHittable {
                submit.tap()
                return
            }
        }
        dismissKeyboard(in: app)
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

    private func openDocumentTools(
        chinese: Bool = false,
        in app: XCUIApplication
    ) {
        selectProfessionalMode(
            "pages",
            chinese: chinese,
            in: app
        )
        tapDocumentToolsButton(in: app)
    }

    private func tapDocumentToolsButton(in app: XCUIApplication) {
        tapCenter(revealDocumentToolsButton(in: app))
    }

    private func revealDocumentToolsButton(
        in app: XCUIApplication
    ) -> XCUIElement {
        let toolRow = app.scrollViews["workspaceToolRow"].firstMatch
        var button = firstHittableButton(
            identifier: "documentToolsAction",
            in: app,
            timeout: 2
        )
        func hasVisibleCenter(
            _ element: XCUIElement
        ) -> Bool {
            guard element.exists, element.isHittable else {
                return false
            }
            guard toolRow.exists else {
                return true
            }
            return toolRow.frame.insetBy(dx: 2, dy: 0).contains(
                CGPoint(
                    x: element.frame.midX,
                    y: element.frame.midY
                )
            )
        }
        for _ in 0..<8 where !hasVisibleCenter(button) {
            if toolRow.exists {
                toolRow.swipeLeft()
            } else {
                app.swipeLeft()
            }
            button = firstHittableButton(
                identifier: "documentToolsAction",
                in: app,
                timeout: 1
            )
        }
        XCTAssertTrue(
            hasVisibleCenter(button),
            "Document tools did not scroll into the visible tool row"
        )
        return button
    }

    private func openPageOrganizer(in app: XCUIApplication) {
        selectProfessionalMode("pages", in: app)
        let organizer = firstHittableButton(
            identifier: "workspaceTool-organize",
            in: app,
            timeout: 5
        )
        XCTAssertTrue(organizer.isHittable)
        tapCenter(organizer)
    }

    private func selectWorkspaceLane(
        title: String,
        identifier: String,
        in app: XCUIApplication
    ) {
        let chineseTitle: String
        switch identifier {
        case "workspaceLane-home": chineseTitle = "文档"
        case "workspaceLane-tasks": chineseTitle = "工具"
        case "workspaceLane-outputs": chineseTitle = "成果"
        default: chineseTitle = title
        }
        let titles = [title, chineseTitle]
        if workspaceLaneMarker(identifier, in: app).exists {
            return
        }
        let directQuery = app.descendants(matching: .any)
            .matching(identifier: identifier)
        _ = directQuery.firstMatch.waitForExistence(timeout: 2)
        if let directLane = directQuery.allElementsBoundByIndex
            .first(where: \.isHittable) {
            tapCenter(directLane)
        } else {
            let labeledQuery = app.buttons.matching(
                NSPredicate(
                    format: "label IN %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                    titles,
                    "\(title),",
                    "\(chineseTitle),"
                )
            )
            _ = labeledQuery.firstMatch.waitForExistence(timeout: 2)
            if let labeledLane = labeledQuery.allElementsBoundByIndex
                .first(where: \.isHittable) {
                tapCenter(labeledLane)
                XCTAssertTrue(
                    workspaceLaneMarker(identifier, in: app)
                        .waitForExistence(timeout: 5),
                    "Workspace lane \(identifier) did not finish loading"
                )
                return
            }
            let menuQuery = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label IN %@",
                    ["Workspace", "工作区"]
                )
            )
            let firstMenu = menuQuery.firstMatch
            _ = firstMenu.waitForExistence(timeout: 3)
            let menu = menuQuery.allElementsBoundByIndex
                .first(where: \.isHittable)
                ?? firstMenu
            XCTAssertTrue(menu.waitForExistence(timeout: 3))
            tapCenter(menu)
            let optionQuery = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label IN %@ OR identifier IN %@",
                    titles,
                    titles
                )
            )
            let firstOption = optionQuery.firstMatch
            _ = firstOption.waitForExistence(timeout: 3)
            let option = optionQuery.allElementsBoundByIndex
                .first(where: \.isHittable)
                ?? firstOption
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            tapCenter(option)
        }

        XCTAssertTrue(
            workspaceLaneMarker(identifier, in: app)
                .waitForExistence(timeout: 5),
            "Workspace lane \(identifier) did not finish loading"
        )
    }

    private func workspaceLaneMarker(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let marker: String
        switch identifier {
        case "workspaceLane-home": marker = "libraryDocumentsSection"
        case "workspaceLane-tasks": marker = "taskPackagesSection"
        case "workspaceLane-outputs": marker = "deliveryCenter"
        default: marker = identifier
        }
        return app.descendants(matching: .any)[marker].firstMatch
    }

    private func librarySearchField(
        in app: XCUIApplication
    ) -> XCUIElement {
        let field = app.searchFields["librarySearchField"].firstMatch
        if !field.exists {
            let openSearch = app.buttons["librarySearchButton"].firstMatch
            XCTAssertTrue(openSearch.waitForExistence(timeout: 5))
            openSearch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
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

    private func selectRecommendedOfficeExport(
        in app: XCUIApplication
    ) -> XCUIElement {
        let mode = app.descendants(matching: .any)[
            "exportCatalogMode-recommended"
        ].firstMatch
        XCTAssertTrue(reveal(mode, in: app, maxSwipes: 8))
        tapCenter(mode)

        let recommended = app.descendants(matching: .any)[
            "recommendedOfficeExport"
        ].firstMatch
        XCTAssertTrue(reveal(recommended, in: app, maxSwipes: 8))
        return recommended
    }

    private func waitForFormField(
        named fieldName: String,
        in app: XCUIApplication
    ) -> Bool {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label == %@",
                "formField-",
                fieldName
            )
        ).firstMatch.waitForExistence(timeout: 45)
    }

    private func scanPageAction(
        labeled label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", label)
        ).firstMatch
    }

    private func revealInDeliveryReceipt(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> Bool {
        revealInPresentedSheet(
            element,
            navigationTitle: "Delivery receipt",
            in: app,
            maxSwipes: max(maxSwipes, 16)
        )
    }

    private func revealInPresentedSheet(
        _ element: XCUIElement,
        navigationTitle: String,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> Bool {
        let navigation = app.navigationBars[navigationTitle].firstMatch
        guard navigation.exists else {
            return false
        }
        // An iPad reader behind the sheet can be larger than the sheet itself.
        // Prefer the control's actual scroll ancestor; scrolling the largest
        // view can move the PDF and make a coordinate tap dismiss the sheet.
        let ancestor = element.exists && !element.identifier.isEmpty
            ? app.scrollViews.containing(.any, identifier: element.identifier)
                .allElementsBoundByIndex.min(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                })
            : nil
        let minimumSheetWidth = navigation.frame.width * 0.8
        let scrollView = ancestor ?? app.scrollViews.allElementsBoundByIndex
            .filter {
                $0.frame.width >= minimumSheetWidth
                    && $0.frame.height > app.frame.height * 0.35
                    && abs($0.frame.midX - navigation.frame.midX) < 32
            }
            .min(by: {
                $0.frame.width * $0.frame.height
                    < $1.frame.width * $1.frame.height
            })
            ?? app.scrollViews.firstMatch
        let isCenteredInViewport: () -> Bool = {
            guard element.exists,
                  element.isHittable,
                  scrollView.exists else {
                return false
            }
            let viewport = scrollView.frame.insetBy(dx: 8, dy: 8)
            let safeTop = max(
                viewport.minY,
                navigation.frame.maxY + 8
            )
            let visibleViewport = CGRect(
                x: viewport.minX,
                y: safeTop,
                width: viewport.width,
                height: max(0, viewport.maxY - safeTop)
            )
            return visibleViewport.contains(
                CGPoint(
                    x: element.frame.midX,
                    y: element.frame.midY
                )
            )
        }

        for _ in 0...maxSwipes {
            if isCenteredInViewport() {
                return true
            }
            guard navigation.exists, scrollView.exists else {
                return false
            }
            let safeTop = max(
                scrollView.frame.minY + 8,
                navigation.frame.maxY + 8
            )
            // The scroll view frame includes the searchable navigation bar.
            // Keep both gesture endpoints in the exposed content viewport.
            let visibleBottom = min(scrollView.frame.maxY, app.frame.maxY) - 8
            guard visibleBottom > safeTop + 24 else { return false }
            let contentHeight = visibleBottom - safeTop
            let upper = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: scrollView.frame.midX, dy: safeTop + contentHeight * 0.15))
            let lower = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: scrollView.frame.midX, dy: safeTop + contentHeight * 0.85))
            if element.exists && element.frame.midY < safeTop {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
        }
        return isCenteredInViewport()
    }

    private func revealInContainer(
        _ element: XCUIElement,
        container: XCUIElement,
        maxSwipes: Int
    ) -> Bool {
        for _ in 0...maxSwipes {
            if element.exists, element.isHittable {
                return true
            }
            guard container.exists else {
                return false
            }
            container.swipeUp()
        }
        return element.exists && element.isHittable
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

    private func revealInScanReview(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int,
        includesPreview: Bool = false
    ) -> Bool {
        let completionMessage = app.staticTexts[
            "Image-based PDF · recognize text after saving"
        ].firstMatch
        let save = app.buttons["scanSave"]
        let navigation = app.navigationBars["Review Scan"]
        let scrollView = app.scrollViews.containing(
            .button,
            identifier: "scanSelectPages"
        ).firstMatch

        for _ in 0...maxSwipes {
            guard scrollView.exists, save.exists else {
                return false
            }
            // SwiftUI's AX scroll frame can extend beneath the fixed footer.
            // scanOutputBoundary belongs to the scrolling disclosure content.
            let visibleTop = max(
                includesPreview ? navigation.frame.maxY : scrollView.frame.minY,
                navigation.frame.maxY
            ) + 4
            let visibleBottom = min(
                scrollView.frame.maxY,
                completionMessage.exists
                    ? completionMessage.frame.minY - 16
                    : save.frame.minY - 8
            )
            if element.exists,
               element.isHittable,
               element.frame.minY >= visibleTop,
               element.frame.maxY <= visibleBottom {
                return true
            }
            guard visibleBottom - visibleTop > 60 else {
                return false
            }
            let needsDownwardDrag = element.exists
                && element.frame.minY < visibleTop
            let upperY = visibleTop + (visibleBottom - visibleTop) * 0.2
            let lowerY = visibleTop + (visibleBottom - visibleTop) * 0.8
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = scrollView.frame.minX + 6
            origin.withOffset(CGVector(
                dx: x,
                dy: needsDownwardDrag ? upperY : lowerY
            )).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(
                    dx: x,
                    dy: needsDownwardDrag ? lowerY : upperY
                )),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        return false
    }

    private func revealTowardTop(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> Bool {
        if element.exists && element.isHittable {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeDown()
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
        let toolSearch = app.textFields["documentToolSearchField"].firstMatch
        let safeTop = max(
            app.frame.minY + 120,
            toolSearch.exists ? toolSearch.frame.maxY + 8 : 0
        )
        let primaryNavigation = app.descendants(matching: .any)[
            "libraryPrimaryNavigation"
        ].firstMatch
        let navigationBottom = primaryNavigation.exists
            ? primaryNavigation.frame.minY - 8
            : app.frame.maxY - 80

        for _ in 0...maxSwipes {
            // XCTest's keyboard frame excludes the prediction/accessory strip.
            let safeBottom = app.keyboards.firstMatch.exists
                ? min(navigationBottom, app.keyboards.firstMatch.frame.minY - 64)
                : navigationBottom
            if element.exists {
                let frame = element.frame
                if element.isHittable,
                   frame.midY >= safeTop,
                   frame.midY <= safeBottom {
                    return true
                }
            }
            guard safeBottom > safeTop else { return false }
            let movesDown = element.exists && element.frame.midY < safeTop
            dragViewport(
                in: app,
                fromY: movesDown ? 0.35 : 0.72,
                toY: movesDown ? 0.65 : 0.42,
                top: safeTop,
                bottom: safeBottom
            )
        }

        guard element.exists, element.isHittable else {
            return false
        }
        let frame = element.frame
        let safeBottom = app.keyboards.firstMatch.exists
            ? min(navigationBottom, app.keyboards.firstMatch.frame.minY - 64)
            : navigationBottom
        return frame.midY >= safeTop && frame.midY <= safeBottom
    }

    private func dragViewport(
        in app: XCUIApplication,
        fromY: CGFloat,
        toY: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) {
        let visibleHeight = bottom - top
        let appHeight = app.frame.height
        let start = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: (top - app.frame.minY + visibleHeight * fromY) / appHeight
            )
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: (top - app.frame.minY + visibleHeight * toY) / appHeight
            )
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
    }

    private func tapCenter(_ element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
    }

    private func tapCurrentFrame(
        of element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        guard element.exists else {
            return false
        }
        let appFrame = app.frame
        let elementFrame = element.frame
        guard appFrame.width > 0,
              appFrame.height > 0,
              appFrame.intersects(elementFrame) else {
            return false
        }
        app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (elementFrame.midX - appFrame.minX) / appFrame.width,
                dy: (elementFrame.midY - appFrame.minY) / appFrame.height
            )
        ).tap()
        return true
    }

    private func finishOfficeExportCancellation(
        stop: XCUIElement,
        done: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let conversionNavigation = app.navigationBars[
            "Convert PDF"
        ].firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        while deadline.timeIntervalSinceNow > 0 {
            if !conversionNavigation.exists {
                return true
            }
            if done.exists {
                if tapCurrentFrame(of: done, in: app),
                   conversionNavigation.waitForNonExistence(timeout: 2) {
                    return true
                }
            } else if stop.exists, stop.isEnabled {
                _ = tapCurrentFrame(of: stop, in: app)
            }

            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard remaining > 0 else {
                break
            }
            _ = done.waitForExistence(timeout: min(1, remaining))
        }

        return !conversionNavigation.exists
    }
}
