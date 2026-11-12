import XCTest
import UIKit
import PDFKit

@MainActor
final class PaperPathUITests: XCTestCase {
    private var qualityCaptureEnabled = false
    private var qualityFeatureKey = ""
    private var qualityContentSize = "UICTContentSizeCategoryL"
    private let qualityCaseID = UUID()
    private let qualityStoreID = UUID()

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
        // Three complete language/text-size configurations retain their own
        // short per-step waits while sharing this overall XCTest allowance.
        executionTimeAllowance = 600
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
            openReadingNavigationMenu(chinese: chinese, in: app)
            app.buttons[chinese ? "阅读" : "Reading"].firstMatch.tap()
            app.buttons[chinese ? "阅读设置" : "Reading Settings"].firstMatch.tap()
            XCTAssertTrue(app.buttons["readingTheme-sepia"].waitForExistence(timeout: 5))
            app.buttons["readingTheme-sepia"].tap()
            let reset = app.buttons["resetReadingSettings"]
            let readingForm = app.collectionViews.allElementsBoundByIndex
                .first { $0.buttons["readingTheme-sepia"].exists }
            XCTAssertNotNil(readingForm)
            XCTAssertTrue(revealInContainer(reset, container: try XCTUnwrap(readingForm), maxSwipes: 8))
            reset.tap()
            addScreenshot(named: "Reading settings" + suffix, app: app)
            app.buttons[done].firstMatch.tap()
            openReadingNavigationMenu(chinese: chinese, in: app)
            app.descendants(matching: .any)["workspaceNavigateAction"].firstMatch.tap()
            let input = app.textFields["navigationPageInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText("2")
            addScreenshot(named: "Navigation" + suffix, app: app)
            app.buttons["navigationGoToPage"].tap()
            let page = app.buttons["workspacePageJumpAction"].firstMatch
            let pageReached = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", chinese
                    ? "第 2 页，共 2 页。前往页面" : "Page 2 of 2. Go to page"),
                object: page
            )
            XCTAssertEqual(XCTWaiter.wait(for: [pageReached], timeout: 5), .completed)
            openReadingNavigationMenu(chinese: chinese, in: app)
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
            let pageAlert = app.alerts.firstMatch
            pageAlert.textFields.firstMatch.typeText("2")
            let go = pageAlert.buttons[chinese ? "前往" : "Go"].firstMatch
            let goReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: go)
            XCTAssertEqual(XCTWaiter.wait(for: [goReady], timeout: 5), .completed)
            addScreenshot(named: "Organizer page confirmation before touch" + suffix, app: app)
            let jumpEvidence = XCTAttachment(string: "go=\(go.frame)\napp=\(app.frame)\n\(app.debugDescription)")
            jumpEvidence.name = "Organizer page confirmation accessibility before touch" + suffix
            jumpEvidence.lifetime = .keepAlways
            add(jumpEvidence)
            // With a hardware keyboard, iPad's floating number pad consumes
            // the first outside touch. Close that observed popover before
            // confirming the actual alert; phones use the ordinary single tap.
            if UIDevice.current.userInterfaceIdiom == .pad,
               let numberPad = app.otherElements.matching(identifier: "UIKeyboardLayoutStar Preview")
                .allElementsBoundByIndex.first(where: {
                    $0.frame.width < app.frame.width * 0.6
                        && app.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                }) {
                XCTAssertTrue(tapCurrentFrame(of: go, in: app))
                let padClosed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !numberPad.exists || !app.frame.intersects(numberPad.frame)
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [padClosed], timeout: 5), .completed)
            }
            if pageAlert.exists {
                XCTAssertTrue(tapCurrentFrame(of: go, in: app))
            }
            XCTAssertTrue(pageAlert.waitForNonExistence(timeout: 5))
            let second = app.buttons["organizerPage-1"]
            XCTAssertTrue(revealWorkflowControl(second, in: app,
                navigationTitle: chinese ? "整理页面" : "Organize pages",
                footerID: "selectOrganizerPages", maxSwipes: 6))
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
            let focus = app.buttons["enterFocusReading"].firstMatch
            let toolRow = app.scrollViews["workspaceToolRow"].firstMatch
            for _ in 0..<8 where !focus.isHittable || !toolRow.frame.contains(focus.frame) {
                toolRow.swipeLeft()
            }
            XCTAssertTrue(focus.isHittable)
            XCTAssertTrue(toolRow.frame.contains(focus.frame))
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
            "PaperPath: Private PDF"
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
                "Project handoff"
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
        XCTAssertTrue(revealInPresentedSheet(approved,
            navigationTitle: "Add stamp", in: app, maxSwipes: 20))
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

        // Keep adding through the library plus buttons after reaching two PDFs.
        // Do not reopen the disclosure: a third source must remain discoverable.
        for documentTitle in ["Project handoff", "August invoice", "Site review report"] {
            let document = app.buttons.matching(
                NSPredicate(
                    format:
                        "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                    "mergeAvailableDocument-",
                    documentTitle
                )
            ).firstMatch
            XCTAssertTrue(
                revealMergeControl(document, in: app, maxSwipes: 16),
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

        XCTAssertEqual(create.label, "Merge 3 PDFs")

        let selectedRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "mergeSelectedDocument-")
        )
        let project = selectedRows.matching(NSPredicate(format: "label CONTAINS[c] %@", "Project handoff")).firstMatch
        let invoice = selectedRows.matching(NSPredicate(format: "label CONTAINS[c] %@", "August invoice")).firstMatch
        let largeText = qualityCaptureEnabled && qualityContentSize == "UICTContentSizeCategoryAccessibilityXXXL"
        if largeText {
            let earlier = app.buttons.matching(NSPredicate(
                format: "label == %@ AND value == %@", "Move earlier", "August invoice"
            )).firstMatch
            XCTAssertTrue(revealMergeControl(earlier, in: app, maxSwipes: 16, searchUp: true))
            tapCenter(earlier)
        } else {
            XCTAssertTrue(revealMergeControl(project, in: app, maxSwipes: 8, searchUp: true))
            let invoiceID = String(invoice.identifier.dropFirst("mergeSelectedDocument-".count))
            let dragHandle = app.descendants(matching: .any)["mergeDrag-\(invoiceID)"].firstMatch
            XCTAssertTrue(revealMergeControl(dragHandle, in: app, maxSwipes: 8))
            XCTAssertTrue(project.isHittable)
            dragHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.0, thenDragTo: project.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.4, dy: 0.25)
                ))
        }
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in invoice.frame.minY < project.frame.minY },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        addScreenshot(named: "Dragged merge order", app: app)

        let outputName = app.textFields["mergeOutputName"].firstMatch
        XCTAssertTrue(revealMergeControl(outputName, in: app, maxSwipes: 16))
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
        XCTAssertTrue(revealWorkflowControl(cropPage, in: app, navigationTitle: "Organize pages",
            footerID: "selectOrganizerPages", maxSwipes: 16))
        addScreenshot(named: "Actual organizer crop control before touch", app: app)
        let cropEvidence = XCTAttachment(string: "crop=\(cropPage.frame)\napp=\(app.frame)\n\(app.debugDescription)")
        cropEvidence.name = "Actual organizer crop accessibility before touch"
        cropEvidence.lifetime = .keepAlways
        add(cropEvidence)
        XCTAssertTrue(tapCurrentFrame(of: cropPage, in: app))
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

    func testCompressionAndContentEditingStayInSameDocument() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)
        let title = workspaceDocumentTitle(in: app).label
        openDocumentTool(identifier: "compress", query: "Compress", in: app)
        let compress = app.buttons["compressionCreateAction"].firstMatch
        XCTAssertTrue(compress.waitForExistence(timeout: 8))
        XCTAssertEqual(compress.label, "Compress PDF")
        addScreenshot(named: "Document workflow compression saves current", app: app)
        compress.tap()
        if app.buttons["compressionTryLossyAction"].waitForExistence(timeout: 3) {
            // The demo is already encoded efficiently: a no-benefit result must
            // keep this same document and allow editing to continue normally.
            dismissPresentedWorkflow(title: "Compress", in: app)
        }
        XCTAssertTrue(app.navigationBars["Compress"].waitForNonExistence(timeout: 30))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        openDocumentTool(identifier: "content", query: "Add Content", in: app)
        let text = app.descendants(matching: .any)["contentText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.tap()
        text.typeText("Same document workflow")
        let save = app.buttons["contentCreateCopy"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertEqual(save.label, "Save Changes")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        save.tap()
        XCTAssertTrue(app.navigationBars["Add Content"].waitForNonExistence(timeout: 30))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        addScreenshot(named: "Document workflow same document after save", app: app)
        assertAnnotationResult(title: "Added Text", contents: "Same document workflow", in: app)
        assertAppAlive(app)
    }

    func testCompressionMethodsRemainActionableWithAdvisoryEstimate() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_COMPRESSION_FIXTURE", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)
        openDocumentTool(identifier: "compress", query: "Compress", in: app)
        let create = app.buttons["compressionCreateAction"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Measured after compression")).firstMatch.waitForExistence(timeout: 5))
        let quality = app.segmentedControls["Output quality"]
        XCTAssertFalse(quality.exists, "Lossless mode must not suggest that JPEG quality affects its output")
        addScreenshot(named: "Compression lossless default", app: app)
        let method = app.segmentedControls["compressionMethodPicker"].firstMatch
        XCTAssertTrue(method.waitForExistence(timeout: 5))
        method.buttons["High quality (lossy)"].tap()
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Lossy image compression.")).firstMatch.exists)
        addScreenshot(named: "Compression explicit high quality", app: app)
        app.buttons["More options"].firstMatch.tap()
        app.buttons["Image pages (lossy)"].firstMatch.tap()
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Lossy conversion: rebuilds pages as images.")).firstMatch.waitForExistence(timeout: 5))
        addScreenshot(named: "Compression explicit image copy", app: app)
        XCTAssertTrue(create.isEnabled, "A sampled size must never veto real compression")
        method.buttons["Lossless"].tap()
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let retry = app.buttons["compressionTryLossyAction"]
        if !retry.waitForExistence(timeout: 3) {
            // A first optimization may produce a smaller copy. Recompressing
            // that canonical output must report the no-savings state.
            XCTAssertTrue(app.descendants(matching: .any)["workspaceDocumentTitle"].firstMatch.waitForExistence(timeout: 10))
            openDocumentTool(identifier: "compress", query: "Compress", in: app)
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            create.tap()
        }
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        retry.tap()
        XCTAssertTrue(method.buttons["High quality (lossy)"].isSelected)
        assertAppAlive(app)
    }

    func testCompressPDFQuickJourneyKeepsAlreadySmallerOriginal()
        throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_COMPRESSION_FIXTURE", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))

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
        XCTAssertTrue(revealWorkflowControl(source, in: app, navigationTitle: "Compress PDF", footerID: "batchCompressionAction", maxSwipes: 16))
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        tapCenter(source)
        let method = app.descendants(matching: .any)["compressionMethodPicker"].firstMatch
        XCTAssertTrue(method.waitForExistence(timeout: 5))
        let options = app.buttons["More options"].firstMatch
        XCTAssertTrue(revealWorkflowControl(options, in: app, navigationTitle: "Compress PDF", footerID: "batchCompressionAction", maxSwipes: 16, searchUp: true))
        tapCenter(options)
        let imageMode = app.buttons["Image pages (lossy)"].firstMatch
        XCTAssertTrue(revealWorkflowControl(imageMode, in: app, navigationTitle: "Compress PDF", footerID: "batchCompressionAction", maxSwipes: 16))
        tapCenter(imageMode)
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
                "The document was left unchanged."
            )
        )
        .firstMatch
        XCTAssertTrue(
            protectedFromGrowth.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["No change needed"].exists)
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
            "Project handoff"
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
            "Project handoff - Export"
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
        let cancelSearch = app.buttons["librarySearchCancel"].firstMatch
        if cancelSearch.exists {
            XCTAssertTrue(tapCurrentFrame(of: cancelSearch, in: app))
            XCTAssertTrue(cancelSearch.waitForNonExistence(timeout: 8))
        }

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
        // Bind both endpoints to the screen before the selected view resizes.
        let handle = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: originalSelectionFrame.maxX - handleInset - app.frame.minX,
                dy: originalSelectionFrame.maxY - handleInset - app.frame.minY
            ))
        handle.press(
            forDuration: 0.1,
            thenDragTo: handle.withOffset(CGVector(dx: -40, dy: -10))
        )
        let resizeEvidence = XCTAttachment(string:
            "before=\(originalSelectionFrame)\nafter=\(selection.frame)\ncanvas=\(canvas.frame)")
        resizeEvidence.name = "Actual shape resize frames"
        resizeEvidence.lifetime = .keepAlways
        add(resizeEvidence)
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
                "Project handoff"
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
        let app = makeApp()
        app.launchArguments += ["UITEST_COMPRESSION_FIXTURE", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
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
        let method = app.descendants(matching: .any)["compressionMethodPicker"].firstMatch
        XCTAssertTrue(method.waitForExistence(timeout: 5))
        app.buttons["More options"].firstMatch.tap()
        app.buttons["Image pages (lossy)"].firstMatch.tap()
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@", "The document was left unchanged."
        )).firstMatch.waitForExistence(timeout: 45))
        XCTAssertTrue(create.isEnabled)
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
                "Project handoff"
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
        let expectedLabel = try XCTUnwrap(label.value as? String)
        XCTAssertTrue(expectedLabel.contains("Automation"))
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

        XCTAssertTrue(app.navigationBars["Edit Links"].waitForNonExistence(timeout: 45))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        openDocumentTool(identifier: "links", query: "Edit Links", in: app)
        let savedLabel = app.textFields["existingLinkLabel"].firstMatch
        XCTAssertTrue(savedLabel.waitForExistence(timeout: 10))
        XCTAssertEqual(savedLabel.value as? String, expectedLabel, "The link edit must survive saving and reopening")
        dismissPresentedWorkflow(title: "Edit Links", in: app)
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
                "Project handoff"
            ),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [redactedCopyOpened], timeout: 45),
            .completed
        )
        assertAppAlive(app)
    }

    func testShareCheckJourneyCompletesFictionalSampleAfterCancelAndReentry() throws {
        let app = launchResetDemo()
        let entry = app.buttons["shareCheckOpen"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(entry.isHittable)
        addScreenshot(named: "Sharing check home entry", app: app)
        entry.tap()
        let sample = app.buttons["shareCheckSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        addScreenshot(named: "Sharing check file selection", app: app)
        dismissPresentedWorkflow(title: "Check before sharing", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        sample.tap()
        let summary = app.descendants(matching: .any)["privacyReviewSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["privacyReviewDocumentName"].firstMatch.label.contains("Fictional sharing sample"))
        let all = app.buttons["privacySelectAll"].firstMatch
        XCTAssertTrue(revealWorkflowControl(all, in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 12))
        all.tap()
        let redact = app.buttons["privacyRedactionAction"].firstMatch
        XCTAssertTrue(redact.waitForExistence(timeout: 8))
        XCTAssertTrue(redact.isHittable)
        XCTAssertTrue(redact.isEnabled)
        addScreenshot(named: "Sharing sample privacy review", app: app)
        redact.tap()
        let confirm = app.descendants(matching: .any)["privacyRedactionConfirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["privacyRedactionVerified"].firstMatch.waitForExistence(timeout: 60))
        let share = app.buttons["privacyShareVerifiedCopy"].firstMatch
        XCTAssertTrue(revealForCenterTap(share, in: app, maxSwipes: 16))
        XCTAssertTrue(share.isEnabled)
        addScreenshot(named: "Sharing sample checked output", app: app)
        assertAppAlive(app)
    }

    func testShareCheckChineseStandardEntryAndSample() throws {
        let app = launchResetDemo(additionalArguments: [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans"
        ])
        let entry = app.buttons["shareCheckOpen"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(entry.isHittable)
        addScreenshot(named: "Sharing check Chinese home", app: app)
        entry.tap()
        let sample = app.buttons["shareCheckSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        XCTAssertTrue(sample.isHittable)
        addScreenshot(named: "Sharing check Chinese sample selection", app: app)
        sample.tap()
        XCTAssertTrue(app.descendants(matching: .any)["privacyReviewSummary"].firstMatch.waitForExistence(timeout: 30))
        addScreenshot(named: "Sharing check Chinese sample review", app: app)
        dismissPrivacyScan(in: app)
        assertAppAlive(app)
    }

    func testShareCheckEntryUsesExistingPDFAndChineseLargeTextLayout() throws {
        let app = launchResetDemo(additionalArguments: [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let entry = app.buttons["shareCheckOpen"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertTrue(revealForCenterTap(entry, in: app, maxSwipes: 6))
        entry.tap()
        let sample = app.buttons["shareCheckSample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        XCTAssertTrue(sample.isHittable)
        addScreenshot(named: "Sharing check Chinese large text selection", app: app)
        let existing = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shareCheckDocument-")).firstMatch
        XCTAssertTrue(revealForCenterTap(existing, in: app, maxSwipes: 12))
        existing.tap()
        XCTAssertTrue(app.buttons["privacyScanClose"].waitForExistence(timeout: 15))
        addScreenshot(named: "Sharing check existing PDF opened directly", app: app)
        app.buttons["privacyScanClose"].tap()
        assertAppAlive(app)
    }

    func testPrivacyScanJourneyCreatesManagedVerifiedCopyAfterCancelAndReentry()
        throws {
        let app = launchResetDemo()
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        let originalRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "documentRow-", "August invoice"
        )).firstMatch
        XCTAssertTrue(revealForCenterTap(originalRow, in: app, maxSwipes: 10))
        let originalRecordRowID = originalRow.identifier
        XCTAssertTrue(originalRecordRowID.hasPrefix("documentRow-"))
        openDemoDocument(named: "August invoice", in: app)

        let scan = privacyScanEntry(in: app)
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertTrue(scan.isEnabled)
        tapCenter(scan)
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
        tapCenter(scan)
        let privacyCandidate =
            app.staticTexts["b***@example.com"].firstMatch
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "privacyReviewSummary"
            ].firstMatch.waitForExistence(timeout: 30)
        )
        let expandedScope = app.staticTexts["privacySelectedScopeSummary"].firstMatch
        if expandedScope.exists {
            XCTAssertTrue(expandedScope.label.contains("1 item"))
            let category = app.buttons["privacyCategory-email"].firstMatch
            XCTAssertTrue(category.exists)
            XCTAssertLessThan(category.frame.height, app.frame.height * 0.5,
                "Category text must remain readable instead of wrapping one character per line")
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["privacyRedactionScope"].firstMatch.exists)
        }
        XCTAssertTrue(revealWorkflowControl(privacyCandidate, in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 16))
        let findingReason = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "privacyFindingReason-"
            )
        ).firstMatch
        XCTAssertTrue(revealWorkflowControl(findingReason, in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 16))
        let findingSource = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "privacyFindingSource-"
            )
        ).firstMatch
        XCTAssertTrue(revealWorkflowControl(findingSource, in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 16))
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
        XCTAssertTrue(revealWorkflowControl(locate, in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 16))
        XCTAssertGreaterThanOrEqual(locate.frame.width, 44)
        XCTAssertGreaterThanOrEqual(locate.frame.height, 44)
        tapCenter(locate)
        XCTAssertEqual(
            workspaceDocumentTitle(in: app).label,
            "August invoice"
        )

        XCTAssertTrue(app.buttons["privacyScanClose"].waitForNonExistence(timeout: 8))
        // Locating publishes a transient status banner above the toolbar.
        // Synchronize with its removal before a single reopen tap; no retries.
        let locatingNotice = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Privacy candidate on page"
        )).firstMatch
        XCTAssertTrue(locatingNotice.waitForNonExistence(timeout: 8))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: scan
        )], timeout: 8), .completed)
        tapCenter(scan)
        XCTAssertTrue(app.buttons["privacyScanClose"].waitForExistence(timeout: 8),
            "Privacy review must reopen after locating a finding")
        XCTAssertTrue(app.buttons["privacyRedactionAction"].waitForExistence(timeout: 30))
        XCTAssertTrue(revealWorkflowControl(app.descendants(matching: .any)["privacyReviewSummary"].firstMatch,
            in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 16, searchUp: true))
        let expandedSelection = app.staticTexts["privacySelectedScopeSummary"].firstMatch
        let selectedOneInSummary = expandedSelection.exists && expandedSelection.label.contains("1 item")
        XCTAssertTrue(revealWorkflowControl(privacyCandidate, in: app, navigationTitle: "Privacy Scan", footerID: "privacyRedactionAction", maxSwipes: 16))

        let redact = app.buttons["privacyRedactionAction"].firstMatch
        XCTAssertTrue(redact.waitForExistence(timeout: 5))
        XCTAssertTrue(redact.isEnabled)
        XCTAssertTrue(redact.label.contains("1") || selectedOneInSummary)
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

        let verified = app.descendants(matching: .any)["privacyRedactionVerified"].firstMatch
        XCTAssertTrue(verified.waitForExistence(timeout: 60))
        XCTAssertTrue(revealInPresentedSheet(verified, navigationTitle: "Privacy Scan", in: app, maxSwipes: 20))
        let share = app.buttons["privacyShareVerifiedCopy"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(revealInPresentedSheet(share, navigationTitle: "Privacy Scan", in: app, maxSwipes: 20))
        XCTAssertTrue(share.isEnabled)
        let openCopy = app.buttons["privacyOpenCreatedCopy"].firstMatch
        XCTAssertTrue(openCopy.waitForExistence(timeout: 5))
        XCTAssertTrue(revealInPresentedSheet(openCopy, navigationTitle: "Privacy Scan", in: app, maxSwipes: 20))
        XCTAssertTrue(openCopy.isEnabled)
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
        XCTAssertTrue(app.buttons["privacyOpenCreatedCopy"].waitForNonExistence(timeout: 15))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "August invoice")
        XCTAssertFalse(app.buttons["workspaceRelatedDocumentsMenu"].exists)
        app.buttons["Document menu"].tap()
        let historyAndSource = app.buttons["History & source"].firstMatch
        XCTAssertTrue(historyAndSource.waitForExistence(timeout: 5))
        historyAndSource.tap()
        app.buttons["Version History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Version History"].waitForExistence(timeout: 8))
        let priorVersion = app.buttons["Version actions"].firstMatch
        XCTAssertTrue(revealInPresentedSheet(priorVersion, navigationTitle: "Version History", in: app, maxSwipes: 8),
                      "Saving redactions must retain a previous version")
        XCTAssertFalse(app.staticTexts["No recovery versions yet"].exists)
        addScreenshot(named: "Redaction saved to same document with history", app: app)
        dismissPresentedWorkflow(title: "Version History", in: app)
        XCTAssertTrue(waitForLibrary(in: app))
        selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
        let savedRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "documentRow-", "August invoice"
        )).allElementsBoundByIndex
        XCTAssertEqual(Set(savedRows.map(\.identifier)), Set([originalRecordRowID]),
                       "Saving redactions must preserve the document ID and must not create another editable document")
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

        privacyScanEntry(chinese: chinese, in: app).tap()
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

            let scan = privacyScanEntry(chinese: variant.arguments.contains("zh-Hans"), in: app)
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
        XCTAssertTrue(revealInPresentedSheet(pdf, navigationTitle: "Create & Share", in: app, maxSwipes: 20))
        tapCenter(pdf)
        expandPDFOptions(in: app)
        let flattened = app.buttons["flattenedOutputOption"]
            .firstMatch
        XCTAssertTrue(revealInPresentedSheet(flattened, navigationTitle: "Create & Share", in: app, maxSwipes: 20))
        XCTAssertTrue(
            app.staticTexts[
                "Image-based: removes search, links, forms, and editable layers"
            ].exists
        )
        let images = app.descendants(matching: .any)[
            "exportCatalogMode-images"
        ].firstMatch
        XCTAssertTrue(revealInPresentedSheet(images, navigationTitle: "Create & Share", in: app, maxSwipes: 20, searchUp: true))
        tapCenter(images)
        XCTAssertEqual(images.value as? String, "Selected")
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
        XCTAssertTrue(revealInPresentedSheet(replay, navigationTitle: "Settings", in: app, maxSwipes: 12, scrollInGutter: true))
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

    func testIntroductionOpensFilePickerAndCanCancelThenReenter() throws {
        continueAfterFailure = false
        let seeded = launchResetDemo()
        seeded.terminate()
        let app = makeApp()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        app.buttons["settings"].tap()
        let replay = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Replay Introduction")
        ).firstMatch
        XCTAssertTrue(revealInPresentedSheet(replay, navigationTitle: "Settings", in: app, maxSwipes: 12, scrollInGutter: true))
        tapCenter(replay)
        let open = app.buttons["onboardingImportPDF"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertTrue(open.isHittable)
        addScreenshot(named: "Introduction focused on own PDF", app: app)
        open.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 8))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        addScreenshot(named: "Introduction opens real Files picker", app: app)
        cancel.tap()
        XCTAssertTrue(waitForLibrary(in: app))
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "documentRow-")
        ).count, 3, "Cancelling must not add a sample or an empty document")
        let importPDF = app.buttons["deskImport"]
        XCTAssertTrue(importPDF.isHittable)
        importPDF.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.tap()
        XCTAssertTrue(waitForLibrary(in: app))
        addScreenshot(named: "Home after cancelling introduction import", app: app)
        assertAppAlive(app)
    }

    func testIntroductionChineseAccessibilityKeepsActionsReachable() throws {
        continueAfterFailure = false
        let seeded = launchResetDemo()
        seeded.terminate()
        let app = makeApp()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-app.language", "zh-Hans", "-privacy.appLockEnabled", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        app.buttons["settings"].tap()
        let replay = app.buttons["settingsReplayIntroduction"]
        XCTAssertTrue(revealInPresentedSheet(replay, navigationTitle: "设置", in: app,
            maxSwipes: 20, scrollInGutter: true))
        tapCenter(replay)
        let open = app.buttons["onboardingImportPDF"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        addScreenshot(named: "Chinese introduction accessibility heading", app: app)
        XCTAssertTrue(revealForCenterTap(open, in: app, maxSwipes: 10))
        XCTAssertTrue(open.isHittable)
        XCTAssertTrue(open.label.contains("打开"))
        addScreenshot(named: "Chinese introduction accessibility actions", app: app)
        let home = app.buttons["onboardingOpenLibrary"]
        XCTAssertTrue(revealForCenterTap(home, in: app, maxSwipes: 10))
        home.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 8))
        XCTAssertTrue(waitForLibrary(in: app))
        assertAppAlive(app)
    }

    func testToolCatalogUsesCompleteTaskNamesAndSearchesThem() throws {
        continueAfterFailure = false
        let app = launchResetDemo()
        openDemoDocument(in: app)
        openDocumentTools(in: app)
        let search = documentToolSearchField(in: app)
        for (identifier, query) in [
            ("recognize", "Recognize text (OCR)"),
            ("protect", "Password protect"),
            ("bates", "Page IDs (Bates)"),
            ("redact", "Permanently redact")
        ] {
            search.tap()
            search.typeText(query)
            let tool = app.buttons["documentTool-\(identifier)"].firstMatch
            XCTAssertTrue(tool.waitForExistence(timeout: 5))
            XCTAssertTrue(tool.label.contains(query))
            if identifier == "protect" {
                addScreenshot(named: "Full task name search result", app: app)
            }
            app.buttons["Clear tool search"].tap()
        }
        addScreenshot(named: "Tool suggestions with complete task names", app: app)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.otherElements["pdfWorkspace"].waitForExistence(timeout: 5))
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
            XCTAssertTrue(revealInPresentedSheet(replay, navigationTitle: "Settings", in: app, maxSwipes: 12, scrollInGutter: true))
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
        let document = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "documentRow-", "Project handoff"
        )).firstMatch
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
        search.typeText("Project handoff - Export")
        app.keyboards.buttons["Search"].tap()
        let verifiedDocument = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-",
                "Project handoff - Export"
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

        openDeliveryReceipt(in: app)

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
        let emptySearch = librarySearchField(in: app)
        emptySearch.tap()
        emptySearch.typeText("zyxwv no result")
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
        app.navigationBars["Add signature"].buttons["Cancel"].firstMatch.tap()
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
        app.navigationBars["Add signature"].buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )

        app.terminate()
        app.launchArguments = englishLaunchArguments + ["UITEST_WORKFLOW_FIXTURE"]
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

    private func cancelFileExportPicker(_ picker: XCUIElement, in app: XCUIApplication) {
        let cancel = picker.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2), cancel.isHittable {
            tapCenter(cancel)
        } else {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
            top.press(forDuration: 0.1, thenDragTo:
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        XCTAssertTrue(picker.waitForNonExistence(timeout: 8))
    }

    private func completeDirectSystemShare(in app: XCUIApplication, screenshot: String) {
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 20))
        let copy = app.cells.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "actionGroupCell", "Copy"
        )).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertTrue(copy.isHittable)
        addScreenshot(named: screenshot, app: app)
        copy.tap()
        XCTAssertTrue(activity.waitForNonExistence(timeout: 10))
    }

    func testConciseToolScreensChinese() throws {
        try captureConciseToolScreens(largeText: false)
    }

    func testConciseToolsExpanded() throws {
        try captureConciseToolScreens(largeText: true, chinese: false, focusedCapture: true)
    }

    func testConciseToolsEnglish() throws {
        try captureConciseToolScreens(largeText: false, chinese: false, focusedCapture: true)
    }

    // A visual capture journey also checks that the condensed pages retain
    // their actions and the protection / lossy-output boundaries.
    private func captureConciseToolScreens(largeText: Bool, chinese: Bool = true, focusedCapture: Bool = false) throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO",
            "-experience.onboardingCompleted.v4", "YES",
            "-library.viewMode", "list", "-document.toolPaletteView", "suggested"
        ]
        if chinese {
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans"]
        }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)

        func capture(_ name: String) {
            addScreenshot(named: "Concise \(largeText ? "large" : "normal") \(name)", app: app)
        }
        func closeTool() {
            let titles = chinese ? ["取消", "关闭", "完成"] : ["Cancel", "Close", "Done"]
            guard let navigation = app.navigationBars.allElementsBoundByIndex.reversed().first(where: { bar in
                titles.contains { bar.buttons[$0].firstMatch.exists && bar.buttons[$0].firstMatch.isHittable }
            }) else {
                XCTFail("No presented tool navigation bar with a visible dismissal control")
                return
            }
            let options = titles.map { navigation.buttons[$0].firstMatch }
            guard let close = options.first(where: { $0.exists && $0.isHittable }) else {
                XCTFail("No visible tool dismissal control")
                return
            }
            let presentedNavigation = app.navigationBars[navigation.identifier].firstMatch
            close.tap()
            XCTAssertTrue(presentedNavigation.waitForNonExistence(timeout: 8))
        }
        func openTool(_ id: String, query: String) {
            openDocumentTools(chinese: chinese, in: app)
            let search = documentToolSearchField(in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText(query)
            let tool = app.buttons["documentTool-\(id)"].firstMatch
            XCTAssertTrue(revealForCenterTap(tool, in: app, maxSwipes: 8))
            XCTAssertTrue(tool.isEnabled)
            tool.tap()
        }

        if !focusedCapture {
            app.buttons["documentExportMenu"].tap()
            app.buttons[chinese ? "其他导出格式" : "More Export Formats"].tap()
            XCTAssertTrue(app.buttons["exportSavePDFToFiles"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["exportSharePDF"].isHittable)
            capture("export")
            XCTAssertTrue(reveal(app.buttons["exportCatalogMode-images"], in: app, maxSwipes: 6))
            app.buttons["exportCatalogMode-images"].tap()
            XCTAssertTrue(app.buttons["exportPageImages-jpegCompact"].waitForExistence(timeout: 5))
            capture("image formats")
            XCTAssertTrue(revealTowardTop(app.buttons["exportCatalogMode-pdf"], in: app, maxSwipes: 6))
            app.buttons["exportCatalogMode-pdf"].tap()
            expandPDFOptions(in: app, chinese: chinese)
            XCTAssertTrue(reveal(app.buttons["flattenedOutputOption"], in: app, maxSwipes: 6))
            capture("PDF formats and conversion boundary")
            app.buttons["officeExportDoneAction"].tap()

        }

        openTool("note", query: "note")
        XCTAssertTrue(app.buttons["noteAddAction"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["noteAddAction"].isEnabled)
        capture("note")
        if largeText {
            let content = app.scrollViews["noteComposerContent"]
            XCTAssertTrue(content.exists)
            content.swipeUp()
            capture("note scrolled with keyboard")
        }
        closeTool()

        openTool("stamp", query: "stamp")
        XCTAssertTrue(app.buttons["stampOption-Approved"].waitForExistence(timeout: 8))
        capture("stamps")
        if largeText {
            XCTAssertTrue(reveal(app.buttons["stampOption-Void"], in: app, maxSwipes: 6))
            capture("last stamp reachable")
        }
        closeTool()
        if !chinese { return }

        openTool("annotations", query: "annotations")
        XCTAssertTrue(app.navigationBars["批注与标记"].waitForExistence(timeout: 8))
        capture("annotations")
        closeTool()

        openTool("protect", query: "protect")
        let boundary = app.descendants(matching: .any)["protectionPermissionBoundary"].firstMatch
        XCTAssertTrue(reveal(boundary, in: app, maxSwipes: 8))
        capture("password permissions boundary")
        closeTool()
    }

    func testSharingIsOneTapFromEditorLibraryResumeAndCatalog() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO",
            "-library.viewMode", "list", "-workspace.toolMode", "read"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        let invoiceShare = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "librarySharePDF-", "August invoice"
        )).firstMatch
        XCTAssertTrue(revealForCenterTap(invoiceShare, in: app, maxSwipes: 8))
        addScreenshot(named: "Library visible one-tap share", app: app)
        invoiceShare.tap()
        completeDirectSystemShare(in: app, screenshot: "Invoice shared directly from library")

        openDemoDocument(in: app)
        let editorShare = app.buttons["workspaceSharePDF"]
        XCTAssertTrue(editorShare.waitForExistence(timeout: 5))
        XCTAssertTrue(editorShare.isHittable)
        addScreenshot(named: "Editor visible Share and Export", app: app)
        editorShare.tap()
        completeDirectSystemShare(in: app, screenshot: "Document shared directly from editor")

        app.buttons["documentExportMenu"].tap()
        app.buttons["More Export Formats"].tap()
        let catalogShare = app.buttons["exportSharePDF"]
        XCTAssertTrue(catalogShare.waitForExistence(timeout: 10))
        XCTAssertTrue(catalogShare.isHittable)
        catalogShare.tap()
        completeDirectSystemShare(in: app, screenshot: "Export catalog direct share")
        app.buttons["officeExportDoneAction"].tap()
        openReadingNavigationMenu(chinese: false, in: app)
        let find = app.buttons["Find in Document"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 3))
        find.tap()
        let closeFind = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeFind.waitForExistence(timeout: 5))
        closeFind.tap()
        XCTAssertTrue(waitForLibrary(in: app))
        let resumeShare = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "resumeSharePDF-", "Project handoff"
        )).firstMatch
        if UIDevice.current.userInterfaceIdiom == .pad, !resumeShare.exists {
            let previewShare = app.buttons["deskSharePDF"].firstMatch
            XCTAssertTrue(previewShare.waitForExistence(timeout: 5))
            XCTAssertTrue(previewShare.isHittable)
            tapCenter(previewShare)
        } else {
            XCTAssertTrue(revealTowardTop(resumeShare, in: app, maxSwipes: 8))
            resumeShare.tap()
        }
        completeDirectSystemShare(in: app, screenshot: "Continue working direct share")
    }

    func testGridAndBoardExposeDirectFileSharing() throws {
        for (mode, prefix) in [("grid", "gridSharePDF-"), ("board", "boardSharePDF-")] {
            let app = makeApp()
            app.launchArguments += [
                "UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO",
                "-library.viewMode", mode
            ]
            app.launch()
            XCTAssertTrue(waitForLibrary(in: app))
            selectWorkspaceLane(title: "Documents", identifier: "workspaceLane-home", in: app)
            let display = app.buttons["libraryDisplay"].firstMatch
            if display.exists { tapCenter(display) }
            app.buttons[mode == "grid" ? "Grid" : "Board"].firstMatch.tap()
            let share = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, "Project handoff"
            )).firstMatch
            XCTAssertTrue(revealForCenterTap(share, in: app, maxSwipes: 8))
            addScreenshot(named: "\(mode) visible file share", app: app)
            share.tap()
            completeDirectSystemShare(in: app, screenshot: "\(mode) direct file share")
            app.terminate()
        }
    }

    func testOfficeResultsExposeDirectArtifactSharing() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_OFFICE_CORPUS_FIXTURE",
            "-experience.onboardingCompleted.v4", "YES"
        ]
        app.launch()
        XCTAssertTrue(waitForOfficeCorpusFixture(in: app))
        selectWorkspaceLane(title: "Results", identifier: "workspaceLane-outputs", in: app)
        let share = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "officeResultShare-"
        )).firstMatch
        XCTAssertTrue(revealForCenterTap(share, in: app, maxSwipes: 12))
        addScreenshot(named: "Office results direct file share", app: app)
        share.tap()
        completeDirectSystemShare(in: app, screenshot: "Office artifact system share")
    }

    func testPlainPDFCanAddAndFillAFieldFromTheDocument() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.fillForm"
        defer { qualityCaptureEnabled = false }
        let app = makeApp()
        app.launchArguments += ["UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: "August invoice", in: app)
        selectProfessionalMode("deliver", in: app)
        let fill = app.buttons["workspaceTool-fillForm"].firstMatch
        XCTAssertTrue(fill.waitForExistence(timeout: 5))
        XCTAssertTrue(fill.isEnabled, "A plain PDF must allow adding fillable fields")
        XCTAssertTrue(fill.isHittable)
        fill.tap()
        let firstField = app.buttons["addFirstFormField"]
        XCTAssertTrue(firstField.waitForExistence(timeout: 10))
        XCTAssertTrue(firstField.isEnabled)
        XCTAssertTrue(firstField.isHittable)
        XCTAssertFalse(app.staticTexts["No interactive fields"].exists)
        addScreenshot(named: "Plain PDF — add a fillable area from the document", app: app)
        firstField.tap()
        let name = app.textFields["formFieldName"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Invoice reference")
        let add = app.buttons["addFormField"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        add.tap()
        XCTAssertTrue(app.navigationBars["Fill Form"].waitForExistence(timeout: 30))
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "formField-", "Invoice reference"
        )).firstMatch
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 12))
        field.tap()
        let value = app.textFields["formFieldValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        value.tap()
        value.typeText("PP-2026")
        app.buttons["formValueSave"].tap()
        XCTAssertTrue(value.waitForNonExistence(timeout: 30))
        dismissPresentedWorkflow(title: "Fill Form", in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: "August invoice", in: app)
        selectProfessionalMode("deliver", in: app)
        app.buttons["workspaceTool-fillForm"].tap()
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 12))
        field.tap()
        XCTAssertTrue(value.waitForExistence(timeout: 8))
        XCTAssertEqual(value.value as? String, "PP-2026")
        addScreenshot(named: "Plain PDF — added field value survives relaunch", app: app)
        app.terminate()
    }

    func testAllToolsStaysVisibleInEveryWorkspaceMode() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)
        for mode in ["read", "annotate", "pages", "deliver"] {
            selectProfessionalMode(mode, in: app)
            let allTools = app.buttons["documentToolsAction"].firstMatch
            XCTAssertTrue(allTools.waitForExistence(timeout: 3))
            XCTAssertTrue(allTools.isHittable, "All tools must be visible without scrolling in \(mode)")
            let row = app.scrollViews["workspaceToolRow"].firstMatch
            XCTAssertGreaterThan(allTools.frame.midX, row.frame.maxX)
            addScreenshot(named: "Pinned tools — \(mode)", app: app)
            allTools.tap()
            XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 5))
            app.navigationBars["Tools"].buttons["Close"].tap()
            XCTAssertTrue(app.otherElements["pdfWorkspace"].waitForExistence(timeout: 5))
        }
        app.terminate()
    }

    func testCommentsAndExportKeepCommonTasksVisible() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)
        openDocumentTool(identifier: "note", query: "Note", in: app)
        let note = app.descendants(matching: .any)["noteText"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Review feedback")
        app.buttons["noteAddAction"].tap()
        XCTAssertTrue(app.navigationBars["Add note"].waitForNonExistence(timeout: 20))
        openDocumentTool(identifier: "annotations", query: "Annotations", in: app)
        XCTAssertTrue(app.staticTexts["Review feedback"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Widget"].exists)
        XCTAssertFalse(app.staticTexts["Popup"].exists)
        XCTAssertFalse(app.staticTexts["Form field"].exists)
        XCTAssertFalse(app.staticTexts["Note pop-up"].exists)
        XCTAssertFalse(app.staticTexts["Comments & markup"].exists)
        addScreenshot(named: "Usable comments — focused on actual feedback", app: app)
        app.buttons["annotationActions"].tap()
        app.buttons["annotationDocumentObjects"].tap()
        XCTAssertTrue(app.staticTexts["Form field"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Note pop-up"].waitForExistence(timeout: 5))
        addScreenshot(named: "Usable comments — fields and pop-ups remain available", app: app)
        app.buttons["annotationFilter-all"].tap()
        XCTAssertTrue(app.staticTexts["Review feedback"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Note pop-up"].exists)
        app.navigationBars["Comments & Markup"].buttons["Done"].tap()
        app.buttons["documentExportMenu"].tap()
        app.buttons["More Export Formats"].tap()
        let save = app.buttons["exportSavePDFToFiles"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(app.buttons["exportSharePDF"].isHittable)
        app.buttons["exportCatalogMode-pdf"].tap()
        XCTAssertFalse(app.buttons["exportCatalogMode-recommended"].exists)
        XCTAssertFalse(app.buttons["flattenedOutputOption"].exists)
        XCTAssertFalse(app.buttons["Current PDF"].exists)
        addScreenshot(named: "Usable export — save share and three formats", app: app)
        expandPDFOptions(in: app)
        XCTAssertTrue(app.buttons["flattenedOutputOption"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Image-based: removes search, links, forms, and editable layers"].exists)
        addScreenshot(named: "Usable export — advanced PDF options still available", app: app)
        app.staticTexts["More PDF options"].tap()
        XCTAssertFalse(app.buttons["flattenedOutputOption"].exists)
        app.buttons["exportCatalogMode-images"].tap()
        XCTAssertTrue(app.buttons["exportPageImages-jpegCompact"].waitForExistence(timeout: 5))
        app.buttons["exportCatalogMode-office"].tap()
        XCTAssertTrue(app.buttons["officeFormat-wordDocument"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["officeFormat-wordDocument"].isEnabled)
        app.buttons["officeExportDoneAction"].tap()
        XCTAssertTrue(app.otherElements["pdfWorkspace"].waitForExistence(timeout: 5))
        app.buttons["documentExportMenu"].tap()
        app.buttons["More Export Formats"].tap()
        XCTAssertTrue(app.navigationBars["Create & Share"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["exportCatalogMode-pdf"].value as? String, "Selected")
        XCTAssertFalse(app.buttons["flattenedOutputOption"].exists)
        XCTAssertTrue(app.buttons["exportSavePDFToFiles"].isHittable)
        addScreenshot(named: "Usable export — PDF start restored after Office", app: app)
        app.terminate()
    }

    func testBasicUserCanRenameEditSaveAndReopenPDF() throws {
        let app = makeApp()
        let fixtureID = UUID()
        let finalName = "Client review approved " + String(fixtureID.uuidString.prefix(6))
        app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(fixtureID)", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        let originalRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "documentRow-", "Project handoff"
        )).firstMatch
        XCTAssertTrue(revealForCenterTap(originalRow, in: app, maxSwipes: 5))
        originalRow.press(forDuration: 1.2)
        let renameInLibrary = app.buttons["libraryRenameDocument"]
        XCTAssertTrue(renameInLibrary.waitForExistence(timeout: 5))
        addScreenshot(named: "Basic 01 Library file actions", app: app)
        renameInLibrary.tap()
        let renameAlert = app.alerts["Rename document"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        let nameField = renameAlert.textFields.firstMatch
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        XCTAssertFalse(renameAlert.buttons["Save"].isEnabled)
        nameField.typeText("Client review draft")
        addScreenshot(named: "Basic 02 Rename without opening PDF", app: app)
        renameAlert.buttons["Cancel"].tap()
        XCTAssertTrue(originalRow.exists)
        originalRow.press(forDuration: 1.2)
        renameInLibrary.tap()
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        nameField.typeText("Client review draft")
        renameAlert.buttons["Save"].tap()
        openDemoDocument(named: "Client review draft", in: app)
        addScreenshot(named: "Basic 03 Open renamed document", app: app)
        let titleMenu = app.buttons["workspaceDocumentNameMenu"]
        XCTAssertTrue(titleMenu.isHittable)
        titleMenu.tap()
        app.buttons["renameDocument"].tap()
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        nameField.typeText(finalName)
        renameAlert.buttons["Save"].tap()
        let expectedTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", finalName),
            object: workspaceDocumentTitle(in: app)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectedTitle], timeout: 10), .completed)

        openDocumentTool(identifier: "note", query: "Note", in: app)
        let note = app.descendants(matching: .any)["noteText"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Reviewed through the basic user journey")
        app.buttons["noteAddAction"].tap()
        XCTAssertTrue(app.navigationBars["Add note"].waitForNonExistence(timeout: 20))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, finalName)
        addScreenshot(named: "Basic 04 Edited PDF keeps chosen name", app: app)

        app.buttons["workspaceSharePDF"].tap()
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", finalName)).firstMatch.exists)
        addScreenshot(named: "Basic 05 Share uses chosen filename", app: app)
        let copy = app.cells.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "actionGroupCell", "Copy"
        )).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(activity.waitForNonExistence(timeout: 10))

        let exportMenu = app.buttons["documentExportMenu"]
        exportMenu.tap()
        app.buttons["savePDFToFiles"].tap()
        let picker = app.descendants(matching: .any)["fileExportPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        let filename = app.textFields.firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 10))
        XCTAssertTrue((filename.value as? String)?.contains(finalName) == true)
        addScreenshot(named: "Basic 06 Save PDF with its current name", app: app)
        cancelFileExportPicker(picker, in: app)
        exportMenu.tap()
        app.buttons["savePDFToFiles"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        XCTAssertTrue((filename.value as? String)?.contains(finalName) == true)
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["PDF saved to Files"].waitForExistence(timeout: 5))
        addScreenshot(named: "Basic 07 Saved to Files confirmation", app: app)
        XCTAssertTrue(waitForLibrary(in: app))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "documentRow-"))
        XCTAssertEqual(rows.count, 3, "Renaming and editing must not create extra documents")
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: finalName, in: app)
        assertAnnotationResult(title: "Note", contents: "Reviewed through the basic user journey", in: app)
        addScreenshot(named: "Basic 08 Reopened document retains edited note", app: app)
        dismissPresentedWorkflow(title: "Comments & Markup", in: app)
        XCTAssertTrue(waitForLibrary(in: app))
        app.buttons["deskImport"].tap()
        let recents = app.buttons["Recents"].firstMatch
        if recents.waitForExistence(timeout: 3), recents.isHittable { recents.tap() }
        // Scope to the native file browser: the covered library has a
        // static label with this same name underneath the picker.
        let savedFile = app.collectionViews["File View"].cells.matching(NSPredicate(
            format: "label BEGINSWITH %@", finalName
        )).firstMatch
        XCTAssertTrue(savedFile.waitForExistence(timeout: 15))
        addScreenshot(named: "Basic 09 Find exported PDF in Files", app: app)
        savedFile.tap()
        let openFile = app.buttons["Open"].firstMatch
        if openFile.waitForExistence(timeout: 3), openFile.isHittable { openFile.tap() }
        XCTAssertTrue(app.otherElements["pdfWorkspace"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, finalName)
        assertAnnotationResult(title: "Note", contents: "Reviewed through the basic user journey", in: app)
        addScreenshot(named: "Basic 10 Exported PDF imported with its note intact", app: app)
        let evidence = XCTAttachment(string: "fixtureID=\(fixtureID.uuidString)\nfileName=\(finalName).pdf")
        evidence.name = "Basic journey file evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
        app.terminate()
    }

    func testEditedPDFCanSaveToFilesAndShareFromVisibleExportMenu() throws {
        let app = makeApp()
        // Isolate fixtures from the user's existing library on the shared device.
        app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(UUID().uuidString)", "UITEST_SEED_DEMO"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)
        openDocumentTool(identifier: "note", query: "Note", in: app)
        let note = app.descendants(matching: .any)["noteText"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Export journey edited note")
        app.buttons["noteAddAction"].tap()
        XCTAssertTrue(app.navigationBars["Add note"].waitForNonExistence(timeout: 20))

        let exportMenu = app.buttons["documentExportMenu"]
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(exportMenu.isHittable)
        exportMenu.tap()
        let save = app.buttons["savePDFToFiles"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        addScreenshot(named: "Edited PDF visible export choices", app: app)
        save.tap()
        let picker = app.descendants(matching: .any)["fileExportPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        addScreenshot(named: "Edited PDF system save location", app: app)
        // iOS 26's native export picker dismisses with the sheet gesture.
        cancelFileExportPicker(picker, in: app)

        // A cancelled save must leave editing and the next export usable.
        exportMenu.tap()
        app.buttons["savePDFToFiles"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        let saveButton = app.buttons["Save"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 15))
        let filename = app.textFields.firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 5))
        filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        filename.typeText("PaperPath export journey \(UUID().uuidString)")
        saveButton.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["PDF saved to Files"].waitForExistence(timeout: 5))
        addScreenshot(named: "Edited PDF saved to Files successfully", app: app)

        exportMenu.tap()
        app.buttons["shareCurrentPDF"].tap()
        let activity = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 20))
        // Native iOS share actions are collection cells, not buttons.
        let copy = app.cells.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "actionGroupCell", "Copy"
        )).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertTrue(copy.isHittable)
        addScreenshot(named: "Edited PDF direct system share sheet", app: app)
        copy.tap()
        XCTAssertTrue(activity.waitForNonExistence(timeout: 10))

        exportMenu.tap()
        app.buttons["More Export Formats"].tap()
        let catalogSave = app.buttons["exportSavePDFToFiles"]
        XCTAssertTrue(catalogSave.waitForExistence(timeout: 10))
        XCTAssertTrue(catalogSave.isHittable)
        addScreenshot(named: "Export catalog direct PDF save action", app: app)
        catalogSave.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        cancelFileExportPicker(picker, in: app)
        app.buttons["officeExportDoneAction"].tap()
        XCTAssertTrue(catalogSave.waitForNonExistence(timeout: 8))

        XCTAssertTrue(waitForLibrary(in: app))
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "documentRow-", "Project handoff"
        )).firstMatch
        XCTAssertTrue(revealForCenterTap(row, in: app, maxSwipes: 5))
        row.press(forDuration: 1.2)
        let librarySave = app.buttons["librarySavePDFToFiles"]
        XCTAssertTrue(librarySave.waitForExistence(timeout: 5))
        addScreenshot(named: "Library direct save and share actions", app: app)
        librarySave.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        cancelFileExportPicker(picker, in: app)
    }

    func testReadingPageWorkflowAndFilesSurfaces() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)

        if !app.buttons["Reading and navigation"].exists {
            app.buttons["Document menu"].tap()
        }
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
        executionTimeAllowance = 600
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
        executionTimeAllowance = 600
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
        executionTimeAllowance = 900
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
            qualityCaptureEnabled ? qualityContentSize : "UICTContentSizeCategoryL"
        ]
    }

    func testExcellenceDocumentDeskAndToolJourney() throws {
        try runExcellenceDocumentDeskAndToolJourney(largeText: false)
    }

    func testExcellenceDocumentDeskAndToolJourneyLargeText() throws {
        try runExcellenceDocumentDeskAndToolJourney(largeText: true)
    }

    func testExcellenceDocumentDeskAndToolJourneyChineseLargeText() throws {
        try runExcellenceDocumentDeskAndToolJourney(largeText: true, chinese: true)
    }

    func testReleaseChineseNormalScreenshots() throws {
        try runExcellenceDocumentDeskAndToolJourney(largeText: false, chinese: true)
    }

    private func runExcellenceDocumentDeskAndToolJourney(largeText: Bool, chinese: Bool = false) throws {
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = makeApp()
        func capture(_ title: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = title
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.launchArguments += [
            "UITEST_DOCUMENT_LIFECYCLE=CA1214D0-DAF9-43D6-B817-9C1EAB641030",
            "UITEST_RESET_DEMO",
            "-experience.onboardingCompleted.v4", "YES",
            "-library.workspaceLane", "home",
            "-document.toolPaletteView", "suggested"
        ]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if chinese {
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans"]
        }
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        XCTAssertTrue(reveal(app.buttons["deskImport"].firstMatch, in: app, maxSwipes: 8))
        capture("Excellence document desk")
        openDemoDocument(in: app)
        selectProfessionalMode("read", chinese: chinese, in: app)
        if !largeText && !chinese {
            let jump = app.buttons["workspacePageJumpAction"].firstMatch
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            tapCenter(jump)
            let input = app.alerts["Go to page"].textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 3))
            input.tap()
            input.typeText(XCUIKeyboardKey.delete.rawValue + "0")
            let go = app.buttons["workspacePageJumpConfirm"].firstMatch
            XCTAssertFalse(go.isEnabled)
            XCTAssertEqual(input.value as? String, "0")
            input.typeText(XCUIKeyboardKey.delete.rawValue + "2")
            XCTAssertTrue(go.isEnabled)
            tapCenter(go)
            XCTAssertTrue(jump.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Next page"].firstMatch.isEnabled)
        }
        capture("Excellence document workspace")
        let toolRow = app.scrollViews["workspaceToolRow"].firstMatch
        let appearance = app.buttons["readingAppearanceAction"].firstMatch
        for _ in 0..<8 where !appearance.isHittable || !toolRow.frame.contains(appearance.frame) {
            toolRow.swipeLeft()
        }
        XCTAssertTrue(appearance.isHittable)
        XCTAssertTrue(toolRow.frame.contains(appearance.frame))
        tapCenter(appearance)
        XCTAssertTrue(app.buttons["readingTheme-sepia"].waitForExistence(timeout: 5))
        capture("Excellence reading appearance")
        tapCenter(app.buttons[chinese ? "完成" : "Done"].firstMatch)
        let reader = app.buttons["readerTextAction"].firstMatch
        for _ in 0..<8 where !reader.isHittable || !toolRow.frame.contains(reader.frame) {
            toolRow.swipeRight()
        }
        XCTAssertTrue(reader.isHittable)
        XCTAssertTrue(toolRow.frame.contains(reader.frame))
        tapCenter(reader)
        XCTAssertTrue(app.staticTexts["focusReaderPosition"].waitForExistence(timeout: 15))
        capture("Excellence text reader")
        tapCenter(app.buttons[chinese ? "完成" : "Done"].firstMatch)
        openDocumentTools(chinese: chinese, in: app)
        let search = documentToolSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if !largeText && !chinese {
            search.tap()
            search.typeText("fill forms")
            let favoriteForm = app.buttons["documentToolFavorite-fillForm"].firstMatch
            XCTAssertTrue(favoriteForm.waitForExistence(timeout: 5))
            let wasFavorite = favoriteForm.label.hasPrefix("Remove")
            if !wasFavorite { tapCenter(favoriteForm) }
            tapCenter(app.buttons["Close"].firstMatch)
            XCTAssertTrue(waitForLibrary(in: app))
            openDemoDocument(named: "August invoice", in: app)
            openDocumentTools(in: app)
            let favoriteOnInvoice = app.buttons["documentTool-fillForm"].firstMatch
            XCTAssertTrue(favoriteOnInvoice.waitForExistence(timeout: 5))
            XCTAssertTrue(favoriteOnInvoice.isEnabled, "Blank PDFs support adding form fields")
            let removeFavorite = app.buttons["documentToolFavorite-fillForm"].firstMatch
            XCTAssertTrue(removeFavorite.isEnabled)
            capture("Excellence favorite on another document")
            tapCenter(removeFavorite)
            XCTAssertTrue(favoriteOnInvoice.waitForNonExistence(timeout: 3))
            tapCenter(app.buttons["Close"].firstMatch)
            XCTAssertTrue(waitForLibrary(in: app))
            openDemoDocument(in: app)
            openDocumentTools(in: app)
            if wasFavorite {
                search.tap()
                search.typeText("fill forms")
                tapCenter(favoriteForm)
                tapCenter(app.buttons["Close"].firstMatch)
                openDocumentTools(in: app)
            }
        }
        capture("Excellence suggested tools")
        search.tap()
        search.typeText("zzqxv987654321")
        XCTAssertTrue(app.descendants(matching: .any)["documentToolEmptyState"].firstMatch.waitForExistence(timeout: 5))
        capture("Excellence no matching tools")
        let clear = app.buttons[chinese ? "清除工具搜索" : "Clear tool search"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        tapCenter(clear)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clearing a tool query should preserve typing focus")
        search.typeText("annotat")
        let annotations = app.buttons["documentTool-annotations"].firstMatch
        XCTAssertTrue(annotations.waitForExistence(timeout: 5))
        XCTAssertTrue(revealForCenterTap(annotations, in: app, maxSwipes: 8))
        capture("Excellence tool search")
        let favorite = app.buttons["documentToolFavorite-annotations"].firstMatch
        XCTAssertTrue(revealForCenterTap(favorite, in: app, maxSwipes: 8))
        let originalFavoriteLabel = favorite.label
        tapCenter(favorite)
        XCTAssertNotEqual(favorite.label, originalFavoriteLabel)
        tapCenter(favorite)
        XCTAssertEqual(favorite.label, originalFavoriteLabel)
        tapCenter(annotations)
        XCTAssertTrue(app.navigationBars[chinese ? "批注与标记" : "Comments & Markup"].waitForExistence(timeout: 8))
        capture("Excellence annotation review")
        assertAppAlive(app)
    }

    func testMarketingHeroDocumentCapture() throws {
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = englishLaunchArguments + [
            "UITEST_DOCUMENT_LIFECYCLE=3EE66BC5-58F7-49C7-A4B3-A11DDDBBC028",
            "UITEST_HERO_DOCUMENT=\(tablet ? "Riverside Garden.pdf" : "Project Approval.pdf")",
            "-experience.onboardingCompleted.v4", "YES",
            "-library.workspaceLane", "home",
            "-workspace.toolMode", "annotate"
        ]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: tablet ? "Riverside Garden" : "Project Approval", in: app)
        if tablet {
            for title in ["Hide Sidebar", "Toggle Sidebar"] {
                let toggle = app.buttons[title].firstMatch
                if toggle.exists && toggle.isHittable { toggle.tap(); break }
            }
        }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.descendants(matching: .any)["pdfWorkspace"].firstMatch.exists
                && !app.activityIndicators.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed)
        // Give PDFKit's tiled page renderer time to finish before taking evidence.
        Thread.sleep(forTimeInterval: 3)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = tablet ? "hero-ipad" : "hero-phone"
        capture.lifetime = .keepAlways
        add(capture)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "hero-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = englishLaunchArguments + ["UITEST_WORKFLOW_FIXTURE"]
        if qualityCaptureEnabled {
            app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(qualityStoreID.uuidString)"]
            app.launchEnvironment["PAPERPATH_QUALITY_CASE_ID"] = qualityCaseID.uuidString
            app.launchEnvironment["PAPERPATH_QUALITY_TEST_ID"] = name
            app.launchEnvironment["PAPERPATH_QUALITY_FEATURE"] = qualityFeatureKey
        }
        return app
    }

    private func launchDownloadedPDFs() throws -> XCUIApplication {
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RealPDFCorpus", withExtension: nil))
        let original = try Data(contentsOf: root.appendingPathComponent("ocr-jbig2.pdf"))
        XCTAssertEqual(original.count, 42_818)
        let app = makeApp()
        app.launchArguments += ["UITEST_REAL_PDF_FIXTURE", "-workspace.toolMode", "pages"]
        app.launchEnvironment["PAPERPATH_REAL_PDF_BASE64"] = original.base64EncodedString()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        return app
    }

    func testDownloadedPDFMergeAndSplit() throws {
        let app = try launchDownloadedPDFs()
        openQuickTask(identifier: "mergePDFs", query: "Merge PDFs", in: app)
        for title in ["Downloaded scan A", "Downloaded scan B"] {
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "mergeAvailableDocument-", title)).firstMatch
            XCTAssertTrue(revealForCenterTap(row, in: app, maxSwipes: 8))
            tapCenter(row)
            XCTAssertTrue(row.waitForNonExistence(timeout: 8))
        }
        let name = app.textFields["mergeOutputName"].firstMatch
        XCTAssertTrue(revealForCenterTap(name, in: app, maxSwipes: 8))
        name.tap(); name.typeText("Downloaded merge")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        let create = app.buttons["mergeCreateAction"].firstMatch
        XCTAssertTrue(reveal(create, in: app, maxSwipes: 8)); XCTAssertTrue(create.isEnabled); create.tap()
        XCTAssertTrue(app.staticTexts["Merged PDF ready"].waitForExistence(timeout: 30))
        tapCenter(app.buttons["mergeOpenResult"].firstMatch)
        XCTAssertTrue(app.staticTexts["Downloaded merge"].waitForExistence(timeout: 15))
        addScreenshot(named: "Downloaded original PDFs merged", app: app)
        openDocumentTool(identifier: "organize", query: "Organize", in: app)
        completePageExtraction(in: app, sourceTitle: "Downloaded merge")
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Downloaded merge - extracted pages")
        addScreenshot(named: "Downloaded PDF split result", app: app)
        assertAppAlive(app)
    }

    func testDownloadedPDFCompressionAndProtection() throws {
        let app = try launchDownloadedPDFs()
        openDemoDocument(named: "Downloaded scan A", in: app)
        openDocumentTool(identifier: "compress", query: "Compress", in: app)
        let create = app.buttons["compressionCreateAction"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8)); create.tap()
        XCTAssertTrue(app.navigationBars["Compress"].waitForNonExistence(timeout: 45))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Downloaded scan A")
        addScreenshot(named: "Downloaded PDF compressed and saved", app: app)
        openDocumentTool(identifier: "protect", query: "Protect", in: app)
        completeProtection(navigationTitle: "Protect PDF", password: "RealPDF-2026", in: app)
        let protected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Downloaded scan A"), object: workspaceDocumentTitle(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [protected], timeout: 30), .completed)
        addScreenshot(named: "Downloaded PDF protected result", app: app)
        assertAppAlive(app)
    }

    func testDownloadedPDFOCR() throws {
        let app = try launchDownloadedPDFs()
        openQuickTask(identifier: "recognizeText", query: "OCR PDF", documentTitle: "Downloaded scan A", in: app)
        completeRecognition(query: "MIDI", in: app)
        addScreenshot(named: "Downloaded scanned manual recognized text", app: app)
        assertAppAlive(app)
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
        if !task.exists || !revealForCenterTap(task, in: app, maxSwipes: 10) {
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
        // A large Dynamic Type row may not enter the lazy picker hierarchy
        // until scrolled. Narrow the real picker before asserting existence.
        if !document.exists {
            let pickerSearch = app.searchFields["Search documents"].firstMatch
            if pickerSearch.waitForExistence(timeout: 2) {
                pickerSearch.tap()
                pickerSearch.typeText(documentTitle)
            }
        }
        XCTAssertTrue(
            document.waitForExistence(timeout: 8),
            "Document picker did not present \(documentTitle) for \(identifier)"
        )
        guard document.exists else { return }
        XCTAssertTrue(
            revealForCenterTap(document, in: app, maxSwipes: 10),
            "Could not choose \(documentTitle) for \(identifier)"
        )
        if identifier == "protectPDF" {
            addScreenshot(named: "Protect PDF source before selection", app: app)
            let selectionEvidence = XCTAttachment(string:
                "source=\(document.frame)\napp=\(app.frame)\n\(app.debugDescription)")
            selectionEvidence.name = "Protect PDF source accessibility before selection"
            selectionEvidence.lifetime = .keepAlways
            add(selectionEvidence)
            XCTAssertTrue(tapCurrentFrame(of: document, in: app))
        } else {
            tapCenter(document)
        }
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

    private func privacyScanEntry(chinese: Bool = false, in app: XCUIApplication) -> XCUIElement {
        selectProfessionalMode("deliver", chinese: chinese, in: app)
        return app.buttons["privacyScanDeliveryAction"].firstMatch
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
            revealInPresentedSheet(app.staticTexts[title].firstMatch,
                navigationTitle: "Comments & Markup", in: app, maxSwipes: 12),
            "Expected annotation type \(title)"
        )
        if let contents {
            XCTAssertTrue(
                revealInPresentedSheet(app.staticTexts[contents].firstMatch,
                    navigationTitle: "Comments & Markup", in: app, maxSwipes: 12),
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
        XCTAssertTrue(revealWorkflowControl(password, in: app, navigationTitle: navigationTitle,
            footerID: "protectionCreateAction", maxSwipes: 16))
        tapCenter(password)
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

    private func completePageExtraction(in app: XCUIApplication, sourceTitle: String = "Project handoff") {
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
            app.staticTexts["\(sourceTitle) - extracted pages"]
                .waitForExistence(timeout: 30)
        )
        let extractedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "\(sourceTitle) - extracted pages"
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
        XCTAssertTrue(create.waitForNonExistence(timeout: 45))
        let redactedCopyOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                "Project handoff"
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
                "Project handoff - Export"
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
        let receipt = app.buttons["deliveryReceiptBadge"].firstMatch
        if receipt.waitForExistence(timeout: 3), receipt.isHittable {
            receipt.tap()
        } else {
            openDeliveryReceipt(in: app)
        }
        XCTAssertTrue(app.navigationBars["Delivery receipt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["deliverySummary"].firstMatch.waitForExistence(timeout: 8))
        addScreenshot(named: "Safe-share export verification receipt", app: app)
        dismissPresentedWorkflow(title: "Delivery receipt", in: app)
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
                    "Project handoff - Export"
                ),
                object: verifiedTitle
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [titleUpdated], timeout: 20),
                .completed
            )
            XCTAssertEqual(
                verifiedTitle.label,
                "Project handoff - Export"
            )
        }
        openDeliveryReceipt(in: app)
        return app
    }

    private func openReadingNavigationMenu(chinese: Bool, in app: XCUIApplication) {
        let navigation = app.buttons["workspaceNavigationMenu"].firstMatch
        if !navigation.exists || !navigation.isHittable {
            app.buttons[chinese ? "文档菜单" : "Document menu"].firstMatch.tap()
            let collections = app.collectionViews.allElementsBoundByIndex
            guard let menu = collections.first(where: { $0.buttons["renameDocument"].exists })
                ?? collections.last(where: { $0.isHittable }) else {
                XCTFail("The document menu has no scrollable container")
                return
            }
            for _ in 0..<12 where !navigation.exists || !navigation.isHittable {
                let start = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                let end = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
        }
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertTrue(navigation.isHittable)
        tapCenter(navigation)
    }

    private func openDeliveryReceipt(in app: XCUIApplication) {
        app.buttons["Document menu"].tap()
        let results = app.buttons["Results"].firstMatch
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        let collections = app.collectionViews.allElementsBoundByIndex
        // Bind by index before scrolling. A live containing(renameDocument)
        // query stops matching once that first lazy menu row moves offscreen.
        guard let menu = collections.first(where: { $0.buttons["renameDocument"].exists })
            ?? collections.last(where: { $0.isHittable }) else {
            XCTFail("The document menu has no scrollable container")
            return
        }
        for _ in 0..<12 where !results.exists || !results.isHittable {
            XCTAssertTrue(menu.waitForExistence(timeout: 3))
            // The native menu's collection frame can extend below its clipped viewport.
            let start = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            let end = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        results.tap()
        let receipt = app.buttons["Delivery receipt"].firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        receipt.tap()
        XCTAssertTrue(app.navigationBars["Delivery receipt"].waitForExistence(timeout: 8))
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
            // All tools is pinned beside the scrolling actions in every mode.
            if !toolRow.buttons.matching(identifier: element.identifier).firstMatch.exists {
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

    private func expandPDFOptions(in app: XCUIApplication, chinese: Bool = false) {
        if !app.buttons["flattenedOutputOption"].exists {
            let disclosure = app.staticTexts[chinese ? "更多 PDF 选项" : "More PDF options"].firstMatch
            XCTAssertTrue(reveal(disclosure, in: app, maxSwipes: 6))
            disclosure.tap()
        }
    }

    private func selectRecommendedOfficeExport(
        in app: XCUIApplication
    ) -> XCUIElement {
        let mode = app.descendants(matching: .any)[
            "exportCatalogMode-office"
        ].firstMatch
        XCTAssertTrue(reveal(mode, in: app, maxSwipes: 8))
        tapCenter(mode)

        let recommended = app.descendants(matching: .any)[
            "officeFormat-wordDocument"
        ].firstMatch
        XCTAssertTrue(reveal(recommended, in: app, maxSwipes: 8))
        return recommended
    }

    private func waitForFormField(
        named fieldName: String,
        in app: XCUIApplication
    ) -> Bool {
        let field = app.descendants(matching: .any).matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND label == %@",
                "formField-",
                fieldName
            )
        ).firstMatch
        return revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app,
            maxSwipes: 20)
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
        maxSwipes: Int,
        searchUp: Bool = false,
        scrollInGutter: Bool = false
    ) -> Bool {
        let navigation = app.navigationBars[navigationTitle].firstMatch
        guard navigation.waitForExistence(timeout: 8) else {
            return false
        }
        // An iPad reader behind the sheet can be larger than the sheet itself.
        // Prefer the control's actual scroll ancestor; scrolling the largest
        // view can move the PDF and make a coordinate tap dismiss the sheet.
        let scrollTarget = element.exists
            ? (element.identifier.isEmpty ? element.label : element.identifier) : ""
        let ancestor = element.exists && !scrollTarget.isEmpty
            ? app.scrollViews.containing(.any, identifier: scrollTarget)
                .allElementsBoundByIndex.min(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                })
            : nil
        let minimumSheetWidth = navigation.frame.width * 0.8
        let annotationScroll = app.scrollViews["annotationReviewScroll"].firstMatch
        let formList = app.collectionViews["formReviewList"].firstMatch
        // A lazy tab can disappear above the viewport. Bind the PDF-to-images
        // transition to this sheet, rather than scrolling the reader behind it.
        let pdfExportScroll = app.scrollViews.containing(
            .button, identifier: "flattenedOutputOption"
        ).firstMatch
        let scrollView = (navigationTitle == "Create & Share" && pdfExportScroll.exists ? pdfExportScroll : nil)
            ?? (navigationTitle == "Fill Form" && formList.exists ? formList : nil)
            ?? (annotationScroll.exists ? annotationScroll : nil) ?? ancestor ?? app.scrollViews.allElementsBoundByIndex
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
            // Settings includes actions such as diagnostics sharing. Scroll
            // from empty padding rather than pressing one of those actions.
            let gestureX = scrollInGutter ? scrollView.frame.minX + 2 : scrollView.frame.midX
            let upper = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: gestureX, dy: safeTop + contentHeight * 0.15))
            let lower = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: gestureX, dy: safeTop + contentHeight * 0.85))
            if (element.exists ? element.frame.midY < safeTop : searchUp) {
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

// Programmatic regressions: no image recognition, no network, no selector that
// reopens the library to rescue a failed selection state.
@MainActor
private extension PaperPathUITests {
    struct MergeCorpusSource: Encodable {
        let name: String
        let base64: String
    }

    func launchMergeCorpus(largeText: Bool = false, includeLocked: Bool = false, includeDamaged: Bool = false, includeLarge: Bool = false, includeAttachment: Bool = false, openMerge: Bool = true, additionalArguments: [String] = [], includeForm: Bool = false) throws -> (XCUIApplication, String) {
        var sources: [MergeCorpusSource] = []
        // Distinct page counts, portrait/landscape, rotated page, annotations,
        // long names and one cached, genuine JBIG2 scanned PDF.
        for index in 0..<6 {
            let bounds = index == 2
                ? CGRect(x: 0, y: 0, width: 792, height: 612)
                : CGRect(x: 0, y: 0, width: 612, height: 792)
            let renderer = UIGraphicsPDFRenderer(bounds: bounds)
            let data = renderer.pdfData { context in
                for page in 0..<[1, 2, 1, 3, 1, 2][index] {
                    context.beginPage()
                    let marker = "MERGE-SOURCE-\(index + 1)-PAGE-\(page + 1)"
                    (marker as NSString).draw(at: CGPoint(x: 48, y: 80),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
                    ("Invoice / report / agreement fixture" as NSString).draw(
                        at: CGPoint(x: 48, y: 125),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                }
            }
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            if includeForm && index == 0, let page = pdf.page(at: 0) {
                let field = PDFAnnotation(bounds: CGRect(x: 50, y: 220, width: 260, height: 32),
                    forType: .widget, withProperties: nil)
                field.widgetFieldType = .text
                field.fieldName = "Draft field"
                field.widgetStringValue = ""
                page.addAnnotation(field)
            }
            if index == 4 { pdf.page(at: 0)?.rotation = 90 }
            if index == 5, let page = pdf.page(at: 0) {
                let note = PDFAnnotation(bounds: CGRect(x: 50, y: 200, width: 30, height: 30),
                    forType: .text, withProperties: nil)
                note.contents = "Merge annotation must survive"
                page.addAnnotation(note)
            }
            let name = "Merge \(String(format: "%02d", index + 1))" +
                (index < 2 ? " Invoice" : "") +
                (index == 3 ? " Long agreement name for layout and repeated selection" : "")
            sources.append(MergeCorpusSource(name: name,
                base64: try XCTUnwrap(pdf.dataRepresentation()).base64EncodedString()))
        }
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RealPDFCorpus", withExtension: nil))
        let scan = try Data(contentsOf: root.appendingPathComponent("ocr-jbig2.pdf"))
        XCTAssertEqual(scan.count, 42_818, "The cached original must be present")
        sources.append(MergeCorpusSource(name: "Merge 07 Real scanned PDF", base64: scan.base64EncodedString()))
        if includeLocked {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let pdf = try XCTUnwrap(PDFDocument(data: renderer.pdfData { $0.beginPage() }))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("merge-locked-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(pdf.write(to: url, withOptions: [.userPasswordOption: "Merge-Locked-2026",
                .ownerPasswordOption: "Merge-Owner-2026"]))
            let bytes = try Data(contentsOf: url)
            XCTAssertTrue(try XCTUnwrap(PDFDocument(data: bytes)).isLocked)
            sources.append(MergeCorpusSource(name: "Merge 08 Locked PDF", base64: bytes.base64EncodedString()))
        }
        if includeDamaged {
            sources.append(MergeCorpusSource(name: "Merge 09 Damaged PDF", base64: sources[0].base64))
        }
        if includeLarge {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let data = renderer.pdfData { context in
                for page in 1...120 {
                    context.beginPage()
                    ("MERGE-STRESS-PAGE-\(page)" as NSString).draw(at: CGPoint(x: 48, y: 80),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                }
            }
            XCTAssertLessThanOrEqual(data.count, 96 * 1_024)
            sources.append(MergeCorpusSource(name: "Merge 10 Stress 120 pages", base64: data.base64EncodedString()))
        }
        if includeAttachment {
            sources.append(MergeCorpusSource(name: "Merge 11 Embedded attachment", base64: mergeAttachmentPDF().base64EncodedString()))
        }
        let payload = try JSONEncoder().encode(sources)
        XCTAssertLessThan(payload.count, 256 * 1_024)
        let fixtureID = UUID().uuidString
        let app = makeApp()
        app.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(fixtureID)", "UITEST_MERGE_CORPUS",
            "-workspace.toolMode", "pages", "-privacy.hideLibraryPreviews", "NO"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if includeDamaged { app.launchArguments += ["UITEST_MERGE_DAMAGE_SOURCE"] }
        app.launchArguments += additionalArguments
        app.launchEnvironment["PAPERPATH_MERGE_CORPUS"] = String(decoding: payload, as: UTF8.self)
        // Preserve exact source bytes and fixture identity for independent host
        // verification of the files produced through the real UI.
        let manifest: [String: Any] = ["schema": "paperpath-merge-ui-v1", "fixtureID": fixtureID,
            "unreadableSources": includeDamaged ? ["Merge 09 Damaged PDF"] : [],
            "sources": sources.map { entry in
                ["name": entry.name, "base64": entry.name == "Merge 09 Damaged PDF"
                    ? Data("%PDF-1.7\nbroken-source\n".utf8).base64EncodedString() : entry.base64]
            }]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: manifest),
            uniformTypeIdentifier: "public.json")
        attachment.name = "merge-corpus-\(fixtureID).json"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        if openMerge {
            openQuickTask(identifier: "mergePDFs", query: "Merge PDFs", in: app)
            XCTAssertTrue(app.buttons["mergeCreateAction"].waitForExistence(timeout: 8))
        }
        return (app, fixtureID)
    }

    func mergeAttachmentPDF() -> Data {
        let content = "BT /F1 16 Tf 48 700 Td (MERGE ATTACHMENT PAGE) Tj ET\n"
        let attachment = "PaperPath embedded attachment must survive merge.\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(merge-evidence.txt) 5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Filespec /F (merge-evidence.txt) /UF (merge-evidence.txt) /EF << /F 6 0 R >> >>",
            "<< /Type /EmbeddedFile /Subtype /text#2Fplain /Length \(attachment.utf8.count) >>\nstream\n\(attachment)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { trailer += String(format: "%010d 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        data.append(Data(trailer.utf8))
        return data
    }

    func mergeSource(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "mergeAvailableDocument-", String(format: "Merge %02d", number))).firstMatch
    }

    func assertMergeLibraryExpanded(in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line) {
        // Existence of a lazy offscreen row is not evidence of expansion.
        let disclosure = app.descendants(matching: .any)["mergeLibraryDisclosure"].firstMatch
        XCTAssertTrue(disclosure.exists, file: file, line: line)
        XCTAssertEqual(disclosure.value as? String, "Expanded",
            "Library collapsed after selection; do not reopen it in the helper", file: file, line: line)
        XCTAssertTrue(app.textFields["mergeLibrarySearch"].exists,
            "Library search disappeared", file: file, line: line)
    }

    func addMergeSource(_ number: Int, count: Int, in app: XCUIApplication) {
        assertMergeLibraryExpanded(in: app)
        let row = mergeSource(number, in: app)
        // Scrolling is allowed; tapping the disclosure or search toolbar to
        // restore a hidden/collapsed library is deliberately forbidden.
        XCTAssertTrue(revealMergeControl(row, in: app, maxSwipes: 16))
        XCTAssertTrue(row.isEnabled)
        tapCenter(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 8))
        assertMergeLibraryExpanded(in: app)
        let create = app.buttons["mergeCreateAction"].firstMatch
        if count >= 2 { XCTAssertEqual(create.label, "Merge \(count) PDFs") }
        XCTAssertEqual(create.isEnabled, count >= 2)
    }

    func revealMergeControl(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int, searchUp: Bool = false) -> Bool {
        revealWorkflowControl(element, in: app, navigationTitle: "Merge PDFs", footerID: "mergeCreateAction", maxSwipes: maxSwipes, searchUp: searchUp)
    }

    func revealWorkflowControl(_ element: XCUIElement, in app: XCUIApplication, navigationTitle: String, footerID: String, maxSwipes: Int, searchUp: Bool = false) -> Bool {
        // The merge sheet's fixed action bar can be much taller at large text.
        // Underlying library navigation is not the sheet's visible scroll area.
        let selectionBeforeScrolling = app.buttons[footerID].label
        for _ in 0...maxSwipes {
            let navigation = app.navigationBars[navigationTitle].firstMatch
            let action = app.buttons[footerID].firstMatch
            let top = navigation.frame.maxY + 12
            var bottom = action.frame.minY - 24
            if app.keyboards.firstMatch.exists {
                bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 64)
            }
            guard bottom > top else { return false }
            if element.exists, element.isHittable,
               element.frame.midY >= top, element.frame.midY <= bottom {
                return true
            }
            let moveDown = element.exists ? element.frame.midY < top : searchUp
            // Scroll in the leading padding: the middle of a large-text
            // selected row can be its drag-to-reorder handle.
            let height = app.frame.height
            let gutter = (navigation.frame.minX + 8 - app.frame.minX) / app.frame.width
            let fromY = top + (bottom - top) * (moveDown ? 0.30 : 0.78)
            let toY = top + (bottom - top) * (moveDown ? 0.78 : 0.30)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: gutter,
                dy: (fromY - app.frame.minY) / height))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: gutter,
                dy: (toY - app.frame.minY) / height))
            start.press(forDuration: 0.01, thenDragTo: end,
                withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssertEqual(action.label, selectionBeforeScrolling,
                "Scrolling must not add, remove or reorder the selected PDFs")
        }
        return false
    }

    func clearMergeOrder(in app: XCUIApplication) {
        let clear = app.buttons["mergeClearSelection"].firstMatch
        XCTAssertTrue(revealMergeControl(clear, in: app, maxSwipes: 16, searchUp: true))
        let selectionLabel = app.buttons["mergeCreateAction"].label
        tapCenter(clear)
        let confirm = app.alerts.buttons["Clear merge order"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        addScreenshot(named: "Merge clear confirmation", app: app)
        let cancel = app.alerts.buttons["Cancel"].firstMatch
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["mergeCreateAction"].label, selectionLabel,
            "Cancel must preserve the selected PDFs")
        tapCenter(clear)
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mergeCreateAction"].isEnabled)
        assertMergeLibraryExpanded(in: app)
    }
}

extension PaperPathUITests {
    func testMergeCorpusStressAndEmbeddedAttachmentPreserveActualOutput() throws {
        let (app, fixtureID) = try launchMergeCorpus(includeLarge: true, includeAttachment: true)
        for (index, number) in [10, 11, 1].enumerated() { addMergeSource(number, count: index + 1, in: app) }
        let field = app.textFields["mergeOutputName"].firstMatch
        XCTAssertTrue(revealMergeControl(field, in: app, maxSwipes: 16, searchUp: true))
        field.tap()
        field.typeText("Stress and attachment merge")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        let expectation: [String: Any] = ["schema": "paperpath-merge-output-v1", "fixtureID": fixtureID,
            "resultName": "Stress and attachment merge", "order": [8, 9, 1]]
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: expectation), uniformTypeIdentifier: "public.json")
        proof.name = "merge-stress-attachment-output.json"
        proof.lifetime = .keepAlways
        add(proof)
        let create = app.buttons["mergeCreateAction"].firstMatch
        XCTAssertTrue(create.isHittable)
        tapCenter(create)
        XCTAssertTrue(app.staticTexts["Merged PDF ready"].waitForExistence(timeout: 90))
        tapCenter(app.buttons["mergeOpenResult"].firstMatch)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Stress and attachment merge")
        assertAppAlive(app)
    }

    func testMergeCorpusDamagedSourceFailsThenValidSelectionRecovers() throws {
        let (app, fixtureID) = try launchMergeCorpus(includeDamaged: true)
        addMergeSource(1, count: 1, in: app)
        addMergeSource(9, count: 2, in: app)
        let create = app.buttons["mergeCreateAction"].firstMatch
        XCTAssertTrue(create.isHittable)
        tapCenter(create)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30), "Corrupt source must produce an explicit recoverable error")
        XCTAssertFalse(app.staticTexts["Merged PDF ready"].exists, "A failed merge must not publish a result")
        dismissBlockingAlert(in: app)
        XCTAssertTrue(create.isEnabled, "Processing state must clear after a failed merge")
        let remove = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Remove", "Merge 09 Damaged PDF")).firstMatch
        XCTAssertTrue(revealMergeControl(remove, in: app, maxSwipes: 16, searchUp: true))
        tapCenter(remove)
        XCTAssertFalse(create.isEnabled)
        addMergeSource(2, count: 2, in: app)
        let name = app.textFields["mergeOutputName"].firstMatch
        XCTAssertTrue(revealMergeControl(name, in: app, maxSwipes: 16, searchUp: true))
        name.tap()
        name.typeText("Recovered Merge")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        let expectation: [String: Any] = ["schema": "paperpath-merge-output-v1", "fixtureID": fixtureID,
            "resultName": "Recovered Merge", "order": [1, 2]]
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: expectation), uniformTypeIdentifier: "public.json")
        proof.name = "merge-damaged-recovery-output.json"
        proof.lifetime = .keepAlways
        add(proof)
        tapCenter(create)
        XCTAssertTrue(app.staticTexts["Merged PDF ready"].waitForExistence(timeout: 45))
        tapCenter(app.buttons["mergeOpenResult"].firstMatch)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Recovered Merge")
        assertAppAlive(app)
    }

    func testMergeCorpusLockedSourceIsDisabledAndValidSourcesStillMerge() throws {
        let (app, _) = try launchMergeCorpus(includeLocked: true)
        let locked = mergeSource(8, in: app)
        XCTAssertTrue(revealMergeControl(locked, in: app, maxSwipes: 16))
        XCTAssertFalse(locked.isEnabled, "Password-locked source must not enter the merge order")
        XCTAssertFalse(app.buttons["mergeCreateAction"].isEnabled)
        for number in 1...3 { addMergeSource(number, count: number, in: app) }
        XCTAssertTrue(revealMergeControl(locked, in: app, maxSwipes: 16))
        XCTAssertFalse(locked.isEnabled)
        XCTAssertEqual(app.buttons["mergeCreateAction"].label, "Merge 3 PDFs")
        let create = app.buttons["mergeCreateAction"].firstMatch
        XCTAssertTrue(create.isHittable)
        tapCenter(create)
        XCTAssertTrue(app.staticTexts["Merged PDF ready"].waitForExistence(timeout: 45))
        assertAppAlive(app)
    }

    func testAnnotationOverviewAccessibilityMetricsKeepCountsReadable() throws {
        let arguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans"]
        let (app, _) = try launchMergeCorpus(largeText: true, openMerge: false, additionalArguments: arguments)
        let librarySearch = librarySearchField(in: app)
        librarySearch.tap()
        librarySearch.typeText("Merge 06\n")
        openDemoDocument(named: "Merge 06", in: app)
        openDocumentTools(chinese: true, in: app)
        let search = documentToolSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Annotations")
        let tool = app.buttons["documentTool-annotations"].firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        tapCenter(tool)
        let all = app.buttons["annotationFilter-all"].firstMatch
        let notes = app.buttons["annotationFilter-notes"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertTrue(notes.exists)
        XCTAssertTrue(all.label.contains("1") && all.label.contains("全部"), all.label)
        XCTAssertTrue(notes.label.contains("1") && notes.label.contains("备注"), notes.label)
        let page = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            "Merge annotation must survive", "第1页"
        )).firstMatch
        XCTAssertTrue(revealInPresentedSheet(page, navigationTitle: "批注与标记", in: app, maxSwipes: 16))
        addScreenshot(named: "Annotation overview readable AX metrics", app: app)
        let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "编辑")).firstMatch
        XCTAssertTrue(revealInPresentedSheet(edit, navigationTitle: "批注与标记", in: app, maxSwipes: 16))
        XCTAssertGreaterThanOrEqual(edit.frame.height + 0.001, 44)
        XCTAssertGreaterThanOrEqual(edit.frame.width + 0.001, 44)
        tapCenter(edit)
        XCTAssertTrue(app.navigationBars["编辑批注"].waitForExistence(timeout: 5))
    }

    func testCompactAnnotationEditorKeepsContentAndStyleReachable() throws {
        try checkCompactAnnotationEditor(chinese: false, largeText: false)
    }

    func testCompactAnnotationEditorChineseAccessibilityKeepsActionsReachable() throws {
        try checkCompactAnnotationEditor(chinese: true, largeText: true)
    }

    private func checkCompactAnnotationEditor(chinese: Bool, largeText: Bool) throws {
        let arguments = chinese ? ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-app.language", "zh-Hans"] : []
        let (app, _) = try launchMergeCorpus(largeText: largeText, openMerge: false,
            additionalArguments: arguments)
        if largeText {
            let librarySearch = librarySearchField(in: app)
            librarySearch.tap()
            librarySearch.typeText("Merge 06\n")
        }
        openDemoDocument(named: "Merge 06", in: app)
        openDocumentTools(chinese: chinese, in: app)
        let search = documentToolSearchField(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Annotations")
        let tool = app.buttons["documentTool-annotations"].firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        XCTAssertTrue(tool.isEnabled)
        tapCenter(tool)
        let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", chinese ? "编辑" : "Edit ")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(revealInPresentedSheet(edit, navigationTitle: chinese ? "批注与标记" : "Comments & Markup",
            in: app, maxSwipes: 20))
        tapCenter(edit)
        let title = chinese ? "编辑批注" : "Edit Annotation"
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        let text = app.descendants(matching: .any)["annotationComment"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "Merge annotation must survive")
        if !largeText {
            XCTAssertLessThan(text.frame.minY, app.navigationBars[title].frame.maxY + 220,
                "The editable note must appear near the top, without a tall metric header")
        }
        XCTAssertTrue(app.buttons["annotationOpenPage"].exists)
        XCTAssertFalse(app.buttons["saveAnnotationEdit"].isEnabled)
        addScreenshot(named: "Compact annotation editor " + (chinese ? "Chinese accessibility" : "standard"), app: app)
        let color = app.buttons["annotationColor-blue"].firstMatch
        let scroll = app.scrollViews["annotationEditorScroll"].firstMatch
        let save = app.buttons["saveAnnotationEdit"].firstMatch
        for _ in 0..<8 {
            let top = app.navigationBars[title].frame.maxY + 12
            let bottom = save.frame.minY - 12
            if color.isHittable && color.frame.midY > top && color.frame.midY < bottom { break }
            XCTAssertGreaterThan(bottom, top + 40)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = scroll.frame.minX + 8
            origin.withOffset(CGVector(dx: x, dy: top + (bottom - top) * 0.8))
                .press(forDuration: 0.01, thenDragTo: origin.withOffset(CGVector(dx: x, dy: top + (bottom - top) * 0.2)))
        }
        XCTAssertTrue(color.isHittable)
        XCTAssertLessThan(color.frame.midY, save.frame.minY - 8,
            "A color must be above the fixed save bar before tapping")
        tapCenter(color)
        XCTAssertTrue(app.buttons["saveAnnotationEdit"].isEnabled)
        addScreenshot(named: "Compact annotation controls " + (chinese ? "Chinese accessibility" : "standard"), app: app)
        app.navigationBars[title].buttons[chinese ? "取消" : "Cancel"].tap()
        let discard = app.buttons[chinese ? "放弃更改" : "Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.tap()
        XCTAssertTrue(app.navigationBars[title].waitForNonExistence(timeout: 5))
    }

    func testFormValueSaveSurvivesReopenAndIsolatedRelaunch() throws {
        let (app, fixtureID) = try launchMergeCorpus(openMerge: false, includeForm: true)
        let title = "Merge 01 Invoice"
        let expected = "PaperPath verified saved value"
        openDemoDocument(named: title, in: app)
        openDocumentTool(identifier: "fillForm", query: "Fill Form", in: app)
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "formField-", "Draft field")).firstMatch
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 8))
        tapCenter(field)
        let entry = app.textFields["formFieldValue"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        entry.typeText(expected)
        let save = app.buttons["formValueSave"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 30), "Save must finish and close the editor")
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 8))
        XCTAssertTrue(field.isEnabled)
        tapCenter(field)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.value as? String, expected)
        XCTAssertFalse(save.isEnabled, "Reopened saved value is unchanged")
        app.terminate()
        let reopened = makeApp()
        reopened.launchArguments += ["UITEST_DOCUMENT_LIFECYCLE=\(fixtureID)", "-workspace.toolMode", "pages"]
        reopened.launch()
        XCTAssertTrue(waitForLibrary(in: reopened))
        openDemoDocument(named: title, in: reopened)
        openDocumentTool(identifier: "fillForm", query: "Fill Form", in: reopened)
        let restoredField = reopened.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "formField-", "Draft field")).firstMatch
        XCTAssertTrue(revealInPresentedSheet(restoredField, navigationTitle: "Fill Form", in: reopened, maxSwipes: 8))
        tapCenter(restoredField)
        let restored = reopened.textFields["formFieldValue"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, expected)
        XCTAssertFalse(reopened.buttons["formValueSave"].isEnabled)
        addScreenshot(named: "Saved form value after relaunch", app: reopened)
        let oracle: [String: Any] = ["fixtureID": fixtureID, "documentName": title,
            "fieldName": "Draft field", "expectedValue": expected]
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: oracle),
            uniformTypeIdentifier: "public.json")
        proof.name = "form-value-roundtrip-oracle.json"
        proof.lifetime = .keepAlways
        add(proof)
    }

    func testFormValueDraftRequiresExplicitDiscardAndExplainsLengthLimit() throws {
        let (app, _) = try launchMergeCorpus(openMerge: false, includeForm: true)
        openDemoDocument(named: "Merge 01 Invoice", in: app)
        openDocumentTool(identifier: "fillForm", query: "Fill Form", in: app)
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "formField-", "Draft field")).firstMatch
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 8))
        tapCenter(field)
        let entry = app.textFields["formFieldValue"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["formValueSave"].isEnabled, "Unchanged fields must not create another save")
        entry.tap()
        entry.typeText("Keep this draft")
        XCTAssertTrue(app.buttons["formValueSave"].isEnabled)
        app.navigationBars["Fill Field"].buttons["Cancel"].tap()
        let keep = app.alerts.buttons["Keep Editing"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        keep.tap()
        XCTAssertEqual(entry.value as? String, "Keep this draft")
        app.navigationBars["Fill Field"].buttons["Cancel"].tap()
        app.alerts.buttons["Discard Changes"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 8))
        tapCenter(field)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["formValueSave"].isEnabled)
        entry.tap()
        entry.typeText(String(repeating: "n", count: 257))
        XCTAssertTrue(app.descendants(matching: .any)["formValueLengthWarning"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["formValueSave"].isEnabled)
        addScreenshot(named: "Form field explains length limit", app: app)
    }

    func testAnnotationEditorKeepsOverlongDraftAndDisablesSave() throws {
        let (app, _) = try launchMergeCorpus(openMerge: false)
        openDemoDocument(named: "Merge 06", in: app)
        openDocumentTool(identifier: "annotations", query: "Annotations", in: app)
        let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Annotation"].waitForExistence(timeout: 5))
        let text = app.descendants(matching: .any)["annotationComment"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertLessThan(text.frame.midY, app.buttons["saveAnnotationEdit"].frame.minY,
            "The editing field must open above the fixed save bar")
        tapCenter(text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: text)], timeout: 5), .completed)
        let marker = "TAIL-WITHOUT-TRUNCATION"
        text.typeText(String(repeating: "n", count: 2001) + marker)
        let warning = app.descendants(matching: .any)["annotationLengthWarning"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(warning.frame.maxY, app.buttons["saveAnnotationEdit"].frame.minY,
            "The length explanation must remain above the save button while typing")
        XCTAssertGreaterThan(warning.frame.minY, app.navigationBars["Edit Annotation"].frame.maxY)
        XCTAssertTrue((text.value as? String)?.contains(marker) == true,
            "The complete draft must remain editable instead of losing its tail")
        XCTAssertFalse(app.buttons["saveAnnotationEdit"].isEnabled)
        addScreenshot(named: "Annotation retains overlong draft", app: app)
    }

    func testProtectionOverlongInputCannotEnableSavingByTruncatingPasswords() throws {
        let (app, _) = try launchMergeCorpus(openMerge: false)
        openQuickTask(identifier: "protectPDF", query: "Protect PDF",
            documentTitle: "Merge 01 Invoice", in: app)
        XCTAssertTrue(app.navigationBars["Protect PDF"].waitForExistence(timeout: 8))
        let password = app.descendants(matching: .any)["protectionPassword"].firstMatch
        let confirmation = app.descendants(matching: .any)["protectionConfirmation"].firstMatch
        let prefix = String(repeating: "p", count: 128)
        password.tap()
        password.typeText(prefix + "A")
        XCTAssertTrue(app.descendants(matching: .any)["protectionValidation"].firstMatch.waitForExistence(timeout: 3))
        confirmation.tap()
        confirmation.typeText(prefix + "B")
        XCTAssertFalse(app.buttons["protectionCreateAction"].isEnabled,
            "Different overlong passwords must not become a matching truncated pair")
        addScreenshot(named: "Protection rejects overlong passwords", app: app)
    }

    func testMergeCorpusSevenSequentialAddsAndClear() throws {
        let (app, _) = try launchMergeCorpus()
        for number in 1...7 { addMergeSource(number, count: number, in: app) }
        XCTAssertTrue(revealMergeControl(app.staticTexts["All available PDFs are selected"], in: app, maxSwipes: 12))
        clearMergeOrder(in: app)
        // Clear must return all seven files, with no stale duplicate selection.
        for number in (1...7).reversed() { addMergeSource(number, count: 8 - number, in: app) }
        assertAppAlive(app)
    }

    func testMergeCorpusRemoveReaddAndCancelIsolation() throws {
        let (app, _) = try launchMergeCorpus()
        for number in 1...3 { addMergeSource(number, count: number, in: app) }
        let remove = app.buttons.matching(NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "Remove", "Merge 02")).firstMatch
        XCTAssertTrue(revealMergeControl(remove, in: app, maxSwipes: 12))
        tapCenter(remove)
        XCTAssertEqual(app.buttons["mergeCreateAction"].label, "Merge 2 PDFs")
        let removeFirst = app.buttons.matching(NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "Remove", "Merge 01")).firstMatch
        XCTAssertTrue(revealMergeControl(removeFirst, in: app, maxSwipes: 12))
        tapCenter(removeFirst)
        XCTAssertFalse(app.buttons["mergeCreateAction"].isEnabled, "One source cannot be merged")
        assertMergeLibraryExpanded(in: app)
        addMergeSource(2, count: 2, in: app)
        addMergeSource(1, count: 3, in: app)
        dismissPresentedWorkflow(title: "Merge PDFs", in: app)
        openQuickTask(identifier: "mergePDFs", query: "Merge PDFs", in: app)
        XCTAssertFalse(app.buttons["mergeCreateAction"].isEnabled)
        assertMergeLibraryExpanded(in: app)
        addMergeSource(7, count: 1, in: app)
        addMergeSource(4, count: 2, in: app)
    }

    func testMergeCorpusSearchNoMatchAndAddMatching() throws {
        let (app, _) = try launchMergeCorpus()
        let search = app.textFields["mergeLibrarySearch"].firstMatch
        XCTAssertTrue(revealMergeControl(search, in: app, maxSwipes: 8))
        search.tap()
        search.typeText("no-such-pdf")
        XCTAssertTrue(app.staticTexts["No matching PDFs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mergeCreateAction"].isEnabled)
        let clearSearch = app.buttons["Clear search"].firstMatch
        XCTAssertTrue(revealMergeControl(clearSearch, in: app, maxSwipes: 10))
        tapCenter(clearSearch)
        search.tap()
        search.typeText("Invoice")
        // Dismiss only the keyboard, without toggling library expansion.
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        let all = app.buttons["mergeAddAll"].firstMatch
        XCTAssertTrue(revealMergeControl(all, in: app, maxSwipes: 12))
        tapCenter(all)
        XCTAssertEqual(app.buttons["mergeCreateAction"].label, "Merge 2 PDFs", "Add matching must not select the other five PDFs")
        assertMergeLibraryExpanded(in: app)
        clearMergeOrder(in: app)
        XCTAssertTrue(revealMergeControl(search, in: app, maxSwipes: 12))
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Invoice".count))
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        addMergeSource(3, count: 1, in: app)
        addMergeSource(6, count: 2, in: app)
    }

    func testMergeCorpusLargeTextRetainsLibraryAfterSecondAndThird() throws {
        let (app, _) = try launchMergeCorpus(largeText: true)
        for number in 1...4 { addMergeSource(number, count: number, in: app) }
        clearMergeOrder(in: app)
        addMergeSource(7, count: 1, in: app)
        addMergeSource(5, count: 2, in: app)
    }

    func testMergeCorpusMixedOutputSurvivesRelaunch() throws {
        let (app, fixtureID) = try launchMergeCorpus()
        let order = [4, 1, 7, 3, 2, 5, 6]
        for (index, number) in order.enumerated() { addMergeSource(number, count: index + 1, in: app) }
        let field = app.textFields["mergeOutputName"].firstMatch
        XCTAssertTrue(revealMergeControl(field, in: app, maxSwipes: 16))
        field.tap()
        field.typeText("Merge regression output")
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        let expectation: [String: Any] = ["schema": "paperpath-merge-output-v1", "fixtureID": fixtureID,
            "resultName": "Merge regression output", "order": order]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: expectation),
            uniformTypeIdentifier: "public.json")
        attachment.name = "merge-output-expectation.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let create = app.buttons["mergeCreateAction"].firstMatch
        XCTAssertTrue(create.isHittable, "The fixed merge action must be directly tappable")
        XCTAssertTrue(create.isEnabled)
        tapCenter(create)
        XCTAssertTrue(app.staticTexts["Merged PDF ready"].waitForExistence(timeout: 45))
        tapCenter(app.buttons["mergeOpenResult"].firstMatch)
        XCTAssertTrue(workspaceDocumentTitle(in: app).waitForExistence(timeout: 15))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Merge regression output")
        app.terminate()
        // Same isolated store, without reseeding: verify actual persistence.
        app.launchArguments.removeAll { $0 == "UITEST_MERGE_CORPUS" }
        app.launchEnvironment.removeValue(forKey: "PAPERPATH_MERGE_CORPUS")
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: "Merge regression output", in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Merge regression output")
        assertAppAlive(app)
    }
}

// Quality wrappers call the existing functional journeys and capture actual saved files.
extension PaperPathUITests {
    func testQualityQuickTasksScanToPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.scanToPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testScanToPDFJourneyCreatesReviewedTwoPageDocument()
    }

    func testQualityQuickTasksScanToPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.scanToPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testScanToPDFJourneyCreatesReviewedTwoPageDocument()
    }

    func testQualityQuickTasksImagesToPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.imagesToPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testImagesToPDFJourneyCreatesReviewedTwoPageDocument()
    }

    func testQualityQuickTasksImagesToPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.imagesToPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testImagesToPDFJourneyCreatesReviewedTwoPageDocument()
    }

    func testQualityQuickTasksMergePDFs() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.mergePDFs"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testMergePDFJourneyCreatesNamedResultAfterCancelAndReentry()
    }

    func testQualityQuickTasksMergePDFsLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.mergePDFs"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testMergePDFJourneyCreatesNamedResultAfterCancelAndReentry()
    }

    func testQualityQuickTasksSplitPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.splitPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testSplitPDFQuickJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksSplitPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.splitPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testSplitPDFQuickJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksOrganizePages() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.organizePages"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testOrganizePagesQuickJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksOrganizePagesLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.organizePages"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testOrganizePagesQuickJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksCompressPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.compressPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testCompressPDFQuickJourneyKeepsAlreadySmallerOriginal()
    }

    func testQualityQuickTasksCompressPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.compressPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testCompressPDFQuickJourneyKeepsAlreadySmallerOriginal()
    }

    func testQualityQuickTasksFillForms() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.fillForms"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testFillFormsQuickJourneyAddsFieldAfterCancelAndReentry()
    }

    func testQualityQuickTasksFillFormsLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.fillForms"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testFillFormsQuickJourneyAddsFieldAfterCancelAndReentry()
    }

    func testQualityQuickTasksSignPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.signPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testSignPDFQuickJourneyPlacesSignatureAfterCancelAndReentry()
    }

    func testQualityQuickTasksSignPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.signPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testSignPDFQuickJourneyPlacesSignatureAfterCancelAndReentry()
    }

    func testQualityQuickTasksRedactPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.redactPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testRedactPDFQuickJourneyCreatesSecureCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksRedactPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.redactPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testRedactPDFQuickJourneyCreatesSecureCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksProtectPDF() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.protectPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testProtectPDFJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksProtectPDFLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.protectPDF"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testProtectPDFJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksSafeShare() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.safeShare"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testSafeShareQuickJourneyCreatesVerifiedCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksSafeShareLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.safeShare"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testSafeShareQuickJourneyCreatesVerifiedCopyAfterCancelAndReentry()
    }

    func testQualityQuickTasksRecognizeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.recognizeText"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try runQualityOriginalOCR(batch: true)
    }

    func testQualityQuickTasksRecognizeTextLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.recognizeText"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try runQualityOriginalOCR(batch: true)
    }

    func testQualityQuickTasksExportText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.exportText"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testExportTextQuickJourneyProducesResultAfterCancelAndReentry()
    }

    func testQualityQuickTasksExportTextLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.exportText"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testExportTextQuickJourneyProducesResultAfterCancelAndReentry()
    }

    func testQualityQuickTasksExportImages() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.exportImages"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testExportImagesJourneyProducesShareablePageFilesAfterReentry()
    }

    func testQualityQuickTasksExportImagesLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.exportImages"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testExportImagesJourneyProducesShareablePageFilesAfterReentry()
    }

    func testQualityDocumentToolsBrief() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.brief"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testBriefJourneyLoadsResultAfterCloseAndReentry()
    }

    func testQualityDocumentToolsBriefLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.brief"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testBriefJourneyLoadsResultAfterCloseAndReentry()
    }

    func testQualityDocumentToolsFind() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.find"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testFindJourneyReturnsResultAfterCancelAndReentry()
    }

    func testQualityDocumentToolsFindLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.find"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testFindJourneyReturnsResultAfterCancelAndReentry()
    }

    func testQualityDocumentToolsRecognize() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.recognize"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try runQualityOriginalOCR(batch: false)
    }

    func testQualityDocumentToolsRecognizeLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.recognize"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try runQualityOriginalOCR(batch: false)
    }

    func testQualityDocumentToolsHighlight() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.highlight"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testHighlightJourneyWritesMarkupAfterCancelAndReentry()
    }

    func testQualityDocumentToolsHighlightLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.highlight"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testHighlightJourneyWritesMarkupAfterCancelAndReentry()
    }

    func testQualityDocumentToolsUnderline() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.underline"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testUnderlineJourneyWritesMarkupAfterCancelAndReentry()
    }

    func testQualityDocumentToolsUnderlineLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.underline"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testUnderlineJourneyWritesMarkupAfterCancelAndReentry()
    }

    func testQualityDocumentToolsStrikeOut() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.strikeOut"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testStrikeoutJourneyWritesMarkupAfterCancelAndReentry()
    }

    func testQualityDocumentToolsStrikeOutLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.strikeOut"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testStrikeoutJourneyWritesMarkupAfterCancelAndReentry()
    }

    func testQualityDocumentToolsInk() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.ink"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testInkJourneyWritesDrawingAfterCancelAndReentry()
    }

    func testQualityDocumentToolsInkLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.ink"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testInkJourneyWritesDrawingAfterCancelAndReentry()
    }

    func testQualityDocumentToolsNote() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.note"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testNoteJourneyWritesCommentAfterCancelAndReentry()
    }

    func testQualityDocumentToolsNoteLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.note"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testNoteJourneyWritesCommentAfterCancelAndReentry()
    }

    func testQualityDocumentToolsStamp() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.stamp"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testStampJourneyAddsEditableAnnotationAfterCancelAndReentry()
    }

    func testQualityDocumentToolsStampLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.stamp"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testStampJourneyAddsEditableAnnotationAfterCancelAndReentry()
    }

    func testQualityDocumentToolsWatermark() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.watermark"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testWatermarkJourneyWritesAnnotationsAfterCancelAndReentry()
    }

    func testQualityDocumentToolsWatermarkLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.watermark"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testWatermarkJourneyWritesAnnotationsAfterCancelAndReentry()
    }

    func testQualityDocumentToolsBates() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.bates"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testBatesJourneyWritesPageIDsAfterCancelAndReentry()
    }

    func testQualityDocumentToolsBatesLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.bates"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testBatesJourneyWritesPageIDsAfterCancelAndReentry()
    }

    func testQualityDocumentToolsContent() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.content"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testContentJourneyCreatesEditedCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsContentLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.content"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testContentJourneyCreatesEditedCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsLinks() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.links"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testLinksJourneyCreatesEditedCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsLinksLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.links"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testLinksJourneyCreatesEditedCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsAnnotations() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.annotations"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testAnnotationsJourneyReloadsInventoryAfterCloseAndReentry()
    }

    func testQualityDocumentToolsAnnotationsLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.annotations"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testAnnotationsJourneyReloadsInventoryAfterCloseAndReentry()
    }

    func testQualityDocumentToolsAttachments() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.attachments"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testAttachmentsJourneyReloadsInspectionAfterCloseAndReentry()
    }

    func testQualityDocumentToolsAttachmentsLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.attachments"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testAttachmentsJourneyReloadsInspectionAfterCloseAndReentry()
    }

    func testQualityDocumentToolsCompare() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.compare"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testCompareJourneyLoadsResultAfterCancelAndReentry()
    }

    func testQualityDocumentToolsCompareLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.compare"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testCompareJourneyLoadsResultAfterCancelAndReentry()
    }

    func testQualityDocumentToolsSign() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.sign"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testSignJourneyPlacesSignatureAfterCancelAndReentry()
    }

    func testQualityDocumentToolsSignLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.sign"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testSignJourneyPlacesSignatureAfterCancelAndReentry()
    }

    func testQualityDocumentToolsRedact() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.redact"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testRedactJourneyCreatesSecureCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsRedactLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.redact"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testRedactJourneyCreatesSecureCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsFillForm() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.fillForm"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testFillFormJourneyAddsFieldAfterCancelAndReentry()
    }

    func testQualityDocumentToolsFillFormLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.fillForm"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testFillFormJourneyAddsFieldAfterCancelAndReentry()
    }

    func testQualityDocumentToolsBookmarks() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.bookmarks"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testBookmarksJourneyPersistsResultAfterCancelAndReentry()
    }

    func testQualityDocumentToolsBookmarksLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.bookmarks"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testBookmarksJourneyPersistsResultAfterCancelAndReentry()
    }

    func testQualityDocumentToolsOrganize() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.organize"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testOrganizeJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsOrganizeLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.organize"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testOrganizeJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsCompress() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.compress"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testCompressJourneyExplainsAlreadySmallerOriginalAfterReentry()
    }

    func testQualityDocumentToolsCompressLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.compress"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testCompressJourneyExplainsAlreadySmallerOriginalAfterReentry()
    }

    func testQualityDocumentToolsProtect() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.protect"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testDocumentProtectJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsProtectLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.protect"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testDocumentProtectJourneyCreatesCopyAfterCancelAndReentry()
    }

    func testQualityDocumentToolsExport() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.export"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testExportJourneyProducesPageFilesAfterCancelAndReentry()
    }

    func testQualityDocumentToolsExportLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.export"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testExportJourneyProducesPageFilesAfterCancelAndReentry()
    }

    func testQualityWorkflowsPrivacyScan() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "workflows.privacyScan"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        try testPrivacyScanJourneyCreatesManagedVerifiedCopyAfterCancelAndReentry()
    }

    func testQualityWorkflowsPrivacyScanLargeText() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "workflows.privacyScan"
        qualityContentSize = "UICTContentSizeCategoryAccessibilityXXXL"
        defer { qualityCaptureEnabled = false }
        try testPrivacyScanJourneyCreatesManagedVerifiedCopyAfterCancelAndReentry()
    }

}

@MainActor
private extension PaperPathUITests {
    func runQualityOriginalCompression(batch: Bool, largeText: Bool = false) throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = batch ? "quickTasks.compressPDF" : "documentTools.compress"
        qualityContentSize = largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        let app = makeApp()
        app.launchArguments += ["UITEST_SEED_DEMO", "UITEST_QUALITY_ORIGINAL_CORPUS"]
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        let title = "Quality nasa-webb"
        let navigation = batch ? "Compress PDF" : "Compress"
        let footer = batch ? "batchCompressionAction" : "compressionCreateAction"
        if batch {
            openQuickTask(identifier: "compressPDF", query: "Compress PDF", in: app)
            let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "batchCompressionDocument-", title)).firstMatch
            XCTAssertTrue(revealWorkflowControl(source, in: app, navigationTitle: navigation, footerID: footer, maxSwipes: 20))
            tapCenter(source)
        } else {
            openDemoDocument(named: title, in: app)
            openDocumentTool(identifier: "compress", query: "Compress", in: app)
            dismissPresentedWorkflow(title: "Compress", in: app)
            XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
            openDocumentTool(identifier: "compress", query: "Compress", in: app)
        }
        let method = app.descendants(matching: .any)["compressionMethodPicker"].firstMatch
        XCTAssertTrue(revealWorkflowControl(method, in: app, navigationTitle: navigation, footerID: footer, maxSwipes: 20, searchUp: true))
        let segments = app.segmentedControls["compressionMethodPicker"].firstMatch
        if segments.exists { segments.buttons["Lossless"].tap() }
        else {
            tapCenter(method)
            XCTAssertTrue(app.buttons["Lossless"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["Lossless"].firstMatch.tap()
        }
        let create = app.buttons[footer].firstMatch
        XCTAssertTrue(create.isEnabled)
        tapCenter(create)
        if batch {
            XCTAssertTrue(app.staticTexts["COMPRESSION RESULT"].waitForExistence(timeout: 90))
            XCTAssertFalse(app.staticTexts["Originals already smaller"].exists)
            let done = app.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(waitForLibrary(in: app))
        } else {
            XCTAssertTrue(app.navigationBars["Compress"].waitForNonExistence(timeout: 90))
            XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: title, in: app)
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        assertAppAlive(app)
    }
}

extension PaperPathUITests {
    func testQualityDocumentToolsCompressOriginalLosslessAndReopen() throws { try runQualityOriginalCompression(batch: false) }
    func testQualityQuickTasksCompressOriginalLosslessAndReopen() throws { try runQualityOriginalCompression(batch: true) }
    func testQualityDocumentToolsCompressOriginalLosslessAndReopenLargeText() throws { try runQualityOriginalCompression(batch: false, largeText: true) }
}

extension PaperPathUITests {
    private func runQualityOriginalImageExport(batch: Bool) throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = batch ? "quickTasks.exportImages" : "documentTools.export"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        let app = makeApp()
        app.launchArguments += ["UITEST_SEED_DEMO", "UITEST_QUALITY_ORIGINAL_CORPUS"]
        app.launchEnvironment["PAPERPATH_QUALITY_INPUTS"] = "ocr-multipage.pdf"
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        if batch {
            openQuickTask(identifier: "exportImages", query: "PDF Images", documentTitle: "Quality ocr-multipage", in: app)
            XCTAssertTrue(app.navigationBars["Save as Images"].waitForExistence(timeout: 10))
        } else {
            openDemoDocument(named: "Quality ocr-multipage", in: app)
            openDocumentTool(identifier: "export", query: "Export", in: app)
            let mode = app.descendants(matching: .any)["exportCatalogMode-images"].firstMatch
            XCTAssertTrue(revealInPresentedSheet(mode, navigationTitle: "Create & Share", in: app, maxSwipes: 20))
            tapCenter(mode)
            XCTAssertEqual(mode.value as? String, "Selected")
        }
        let export = app.buttons["exportPageImages-jpegCompact"].firstMatch
        XCTAssertTrue(revealForCenterTap(export, in: app, maxSwipes: 20)); XCTAssertTrue(export.isEnabled)
        tapCenter(export)
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 60))
        assertAppAlive(app)
    }

    func testQualityQuickImageExportOriginalSixPages() throws { try runQualityOriginalImageExport(batch: true) }
    func testQualityDocumentImageExportOriginalSixPages() throws { try runQualityOriginalImageExport(batch: false) }

    private func runQualityOriginalOCR(batch: Bool) throws {
        let title = "Quality ocr-multipage"
        let app = makeApp()
        app.launchArguments += ["UITEST_SEED_DEMO", "UITEST_QUALITY_ORIGINAL_CORPUS"]
        app.launchEnvironment["PAPERPATH_QUALITY_INPUTS"] = "ocr-multipage.pdf"
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        for pass in 0..<2 {
            if batch {
                openQuickTask(identifier: "recognizeText", query: "OCR PDF", documentTitle: title, in: app)
            } else {
                if pass == 0 { openDemoDocument(named: title, in: app) }
                openDocumentTool(identifier: "recognize", query: "OCR", in: app)
            }
            XCTAssertTrue(app.navigationBars["Recognition"].waitForExistence(timeout: 10))
            if pass == 0 { dismissPresentedWorkflow(title: "Recognition", in: app) }
        }
        let start = app.buttons["startOCR"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.buttons["recognizedTextCopyMenu"].waitForExistence(timeout: 90))
        let search = app.searchFields["Search recognized text"].firstMatch
        if !search.exists {
            let showSearch = app.buttons["Search recognized text"].firstMatch
            XCTAssertTrue(showSearch.waitForExistence(timeout: 5)); showSearch.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Watson")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        let filtered = app.buttons["copyFilteredRecognizedPages"].firstMatch
        XCTAssertTrue(filtered.waitForExistence(timeout: 10)); XCTAssertTrue(filtered.isEnabled)
        let cancelSearch = app.buttons["Cancel"].firstMatch
        if cancelSearch.exists && cancelSearch.isHittable { cancelSearch.tap() }
        let save = app.buttons["createSearchableCopyButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(revealForCenterTap(save, in: app, maxSwipes: 20)); XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 90), "Saving must actually finish and close the result view")
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, title)
        app.terminate()
        let reopened = makeApp()
        reopened.launchArguments += ["UITEST_SEED_DEMO"]
        reopened.launch()
        XCTAssertTrue(waitForLibrary(in: reopened))
        openDemoDocument(named: title, in: reopened)
        XCTAssertEqual(workspaceDocumentTitle(in: reopened).label, title)
        XCTAssertTrue(reopened.otherElements["pdfWorkspace"].exists)
        assertAppAlive(reopened)
    }

    func testQualityProtectedPasswordFailureThenSessionRecovery() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "quickTasks.protectPDF"
        defer { qualityCaptureEnabled = false }
        try testProtectPDFJourneyCreatesCopyAfterCancelAndReentry()
        let app = makeApp()
        app.launchArguments += ["UITEST_SEED_DEMO"]
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(named: "Project handoff", in: app)
        let unlock = app.buttons["Unlock"].firstMatch
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "Restart must require the document password again")
        unlock.tap()
        let password = app.secureTextFields["Password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        let wrong = "wrong-quality-pass"
        password.typeText(wrong)
        let submit = app.navigationBars["Unlock protected PDF"].buttons["Unlock"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "The password didn’t match")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["Unlock protected PDF"].exists)
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: wrong.count))
        password.typeText("PaperPath-2026")
        submit.tap()
        XCTAssertTrue(app.navigationBars["Unlock protected PDF"].waitForNonExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Protected PDF"].waitForNonExistence(timeout: 15))
        XCTAssertEqual(workspaceDocumentTitle(in: app).label, "Project handoff")
        assertAppAlive(app)
    }
}

extension PaperPathUITests {
    func testCoreFormValueSurvivesRelaunch() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "documentTools.fillForm"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        let app = launchResetDemo()
        openDemoDocument(in: app)
        openDocumentTool(identifier: "fillForm", query: "Fill Form", in: app)
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "formField-", "Recipient name")).firstMatch
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 12))
        tapCenter(field)
        let entry = app.textFields["formFieldValue"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "An actual editable field must open")
        let value = "Core Verified 2026"
        entry.tap()
        entry.typeText(value)
        app.buttons["formValueSave"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 30))
        dismissPresentedWorkflow(title: "Fill Form", in: app)
        XCTAssertTrue(app.staticTexts["Working copy updated"].firstMatch.waitForNonExistence(timeout: 8))
        XCTAssertTrue(waitForLibrary(in: app))
        app.launchArguments.removeAll { $0 == "UITEST_RESET_DEMO" }
        if !app.launchArguments.contains("UITEST_SEED_DEMO") { app.launchArguments.append("UITEST_SEED_DEMO") }
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary(in: app))
        openDemoDocument(in: app)
        openDocumentTool(identifier: "fillForm", query: "Fill Form", in: app)
        XCTAssertTrue(app.navigationBars["Fill Form"].waitForExistence(timeout: 8))
        let allFields = app.buttons["All"].firstMatch
        XCTAssertTrue(allFields.waitForExistence(timeout: 8))
        allFields.tap()
        XCTAssertTrue(revealInPresentedSheet(field, navigationTitle: "Fill Form", in: app, maxSwipes: 12))
        tapCenter(field)
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertEqual(entry.value as? String, value,
            "The actual typed form value must be saved and read back after relaunch")

    }
}

extension PaperPathUITests {
    func testCoreImportPDFFromFiles() throws {
        qualityCaptureEnabled = true
        qualityFeatureKey = "core.importPDF"
        qualityContentSize = "UICTContentSizeCategoryL"
        defer { qualityCaptureEnabled = false }
        let app = launchResetDemo()
        let importAction = app.buttons["deskImport"].firstMatch
        XCTAssertTrue(importAction.waitForExistence(timeout: 8))
        tapCenter(importAction)
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 3) { tapCenter(browse) }
        func openFileItem(_ name: String) throws {
            let matches = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", name, name))
            XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "Files item: \(name)")
            let item = try XCTUnwrap(matches.allElementsBoundByIndex.first(where: { $0.isHittable }),
                "Files item must be actionable: \(name)")
            tapCenter(item)
        }
        try openFileItem(UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone")
        try openFileItem("PaperPath Core Inputs")
        try openFileItem("ocr-jbig2")
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 2) { tapCenter(open) }
        let title = workspaceDocumentTitle(in: app)
        if !title.waitForExistence(timeout: 10) {
            XCTAssertTrue(waitForLibrary(in: app))
            openDemoDocument(named: "ocr-jbig2", in: app)
        }
        XCTAssertEqual(title.label, "ocr-jbig2")
        XCTAssertTrue(app.otherElements["pdfWorkspace"].firstMatch.waitForExistence(timeout: 10))
        assertAppAlive(app)
    }
}
