import XCTest

@MainActor
final class PaperPathUITests: XCTestCase {
    func testLibraryAndWorkspaceSmokeFlow() throws {
        let app = makeApp()
        app.launchArguments += [
            "UITEST_RESET_DEMO",
            "-AppleInterfaceStyle",
            "Dark"
        ]
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
            "Finish & send"
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
        XCTAssertTrue(app.buttons["workspaceNextAction"].exists)
        XCTAssertFalse(app.otherElements["recentDocumentTabs"].exists)
        XCTAssertFalse(app.otherElements["workspaceCommandRail"].exists)

        addScreenshot(named: "PaperPath Workspace", app: app)

        app.buttons["documentToolsAction"].tap()
        XCTAssertTrue(
            app.navigationBars["Choose a result"]
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
        app.keyboards.buttons["Search"].tap()
        let closeToolSearch = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Close",
                "关闭"
            )
        ).firstMatch
        XCTAssertTrue(closeToolSearch.waitForExistence(timeout: 3))
        closeToolSearch.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        app.buttons["Find"].tap()
        XCTAssertTrue(
            app.navigationBars["Find"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Find in document"].exists)
        addScreenshot(named: "PaperPath Document Find", app: app)
        app.buttons["Done"].tap()

        app.buttons["Pages"].tap()
        XCTAssertTrue(
            app.navigationBars["Organize pages"].waitForExistence(timeout: 5)
        )
        let selectPages = app.buttons["Select"]
        XCTAssertTrue(selectPages.exists)
        selectPages.tap()
        XCTAssertTrue(app.buttons["extractPagesButton"].exists)
        app.buttons["pageSelectionMenu"].tap()
        app.buttons["All Pages"].tap()
        addScreenshot(named: "PaperPath Page Selection", app: app)
        app.buttons["extractPagesButton"].tap()
        XCTAssertTrue(
            app.staticTexts["Project handoff - pages"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.otherElements["pdfWorkspace"].exists)
        addScreenshot(named: "PaperPath Extracted Copy", app: app)
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

    func testCompareVersionsUsesClearLocalWorkflow() throws {
        let app = makeApp()
        app.launchArguments += ["UITEST_RESET_DEMO"]
        app.launch()

        XCTAssertTrue(waitForLibrary(in: app))
        let document = app.buttons
            .containing(.staticText, identifier: "Project handoff")
            .firstMatch
        XCTAssertTrue(reveal(document, in: app, maxSwipes: 6))
        document.tap()

        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["documentToolsAction"].tap()
        XCTAssertTrue(
            app.navigationBars["Choose a result"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["All tools"].tap()
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

        let changedPage = app.buttons["changePage-1-revised"]
        XCTAssertTrue(changedPage.exists)
        changedPage.tap()
        XCTAssertTrue(
            app.navigationBars["Compare Versions"]
                .waitForNonExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.otherElements["pdfWorkspace"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["workspaceDocumentTitle"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.staticTexts["workspaceDocumentTitle"].firstMatch.label,
            "August invoice"
        )
        addScreenshot(named: "PaperPath Compare Page Direct", app: app)
    }

    func testVerifyAndShareShowsOutcomeBeforeTechnicalEvidence()
        throws {
        let app = try openVerifiedDeliveryReceipt()
        XCTAssertTrue(app.staticTexts["FINAL COPY CHECKED"].exists)
        XCTAssertTrue(app.buttons["shareVerifiedOutput"].exists)
        XCTAssertTrue(app.staticTexts["SOURCE KEPT"].exists)
        addScreenshot(named: "PaperPath Verified Outcome", app: app)

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
        search.typeText("Project handoff - verified")
        app.keyboards.buttons["Search"].tap()
        let verifiedDocument = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                "documentRow-",
                "Project handoff - verified"
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
        XCTAssertTrue(receipt.isHittable)
        receipt.tap()
        XCTAssertTrue(
            app.navigationBars["Delivery receipt"]
                .waitForExistence(timeout: 8)
        )

        let linkedMilestone = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "openLinkedMilestone-"
            )
        ).firstMatch
        XCTAssertTrue(reveal(linkedMilestone, in: app, maxSwipes: 14))
        linkedMilestone.tap()
        XCTAssertTrue(
            app.navigationBars["Version History"]
                .waitForExistence(timeout: 8)
        )

        let editMilestone = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Edit Milestone",
                "Edit milestone"
            )
        ).firstMatch
        XCTAssertTrue(
            reveal(editMilestone, in: app, maxSwipes: 14)
        )
        editMilestone.tap()

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
        search.typeText("not a pdf task")
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

        app.buttons["documentToolsAction"].tap()
        XCTAssertTrue(
            app.navigationBars["Choose a result"]
                .waitForExistence(timeout: 5)
        )
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("form")
        let fillForm = app.buttons["documentTool-fillForm"]
        XCTAssertTrue(fillForm.waitForExistence(timeout: 3))
        fillForm.tap()

        XCTAssertTrue(
            app.navigationBars["Form check"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Recipient name"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Approval signature"].exists)
        addScreenshot(named: "PaperPath Form Check", app: app)

        app.buttons["Add Field"].tap()
        XCTAssertTrue(
            app.navigationBars["Place Form Field"]
                .waitForExistence(timeout: 5)
        )
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
        app.buttons["Cancel"].tap()

        XCTAssertTrue(
            app.navigationBars["Form check"]
                .waitForExistence(timeout: 5)
        )
        let signatureField = app.buttons["formField-1-0"]
        XCTAssertTrue(signatureField.waitForExistence(timeout: 3))
        signatureField.tap()
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Sign for page 2"].exists)
        XCTAssertTrue(app.buttons["Continue to Placement"].exists)
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
        app.buttons["documentToolsAction"].tap()
        XCTAssertTrue(
            app.navigationBars["Choose a result"]
                .waitForExistence(timeout: 5)
        )
        let toolSearch = documentToolSearchField(in: app)
        toolSearch.tap()
        toolSearch.typeText("form")
        app.buttons["documentTool-fillForm"].tap()
        XCTAssertTrue(
            app.navigationBars["Form check"]
                .waitForExistence(timeout: 5)
        )
        let signatureField = app.buttons["formField-1-0"]
        XCTAssertTrue(signatureField.waitForExistence(timeout: 5))
        signatureField.tap()
        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Sign for page 2"].exists)
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
        XCTAssertTrue(
            app.staticTexts["Continue signing"]
                .waitForExistence(timeout: 5)
        )
        let resume = app.buttons["documentTask-prepareToSend"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        addScreenshot(named: "PaperPath Resume Signing", app: app)
        resume.tap()

        XCTAssertTrue(
            app.navigationBars["Add signature"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Sign for page 2"].exists)
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

        app.buttons["documentToolsAction"].tap()
        XCTAssertTrue(
            app.navigationBars["Choose a result"]
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
        let overlay = app.otherElements.matching(
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
        app.buttons["Bookmarks & Outline"].tap()
        XCTAssertTrue(
            app.navigationBars["Navigate"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Go to page"].exists)
        addScreenshot(named: "PaperPath Page Navigation", app: app)
        app.buttons["Done"].tap()

        app.buttons["Pages"].tap()
        XCTAssertTrue(
            app.navigationBars["Organize pages"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["Select"].tap()
        let selectionMenu = app.buttons["pageSelectionMenu"]
        XCTAssertTrue(selectionMenu.waitForExistence(timeout: 3))
        selectionMenu.tap()
        app.buttons["All Pages"].tap()
        let actions = app.buttons["pageSelectionActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        app.buttons["Copy to Document"].tap()
        XCTAssertTrue(
            app.navigationBars["Copy Pages To"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["August invoice"].exists)
        addScreenshot(named: "PaperPath Cross Document Pages", app: app)
        app.buttons["Cancel"].tap()
        app.buttons["Done"].tap()

        app.buttons["Document menu"].tap()
        app.buttons["Files & Source"].tap()
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
        let filesPicker = app.otherElements["Browse View (Picker)"]
        XCTAssertTrue(
            filesPicker.waitForExistence(timeout: 5)
        )
        addScreenshot(named: "PaperPath Files Export", app: app)
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

        app.buttons["documentToolsAction"].tap()
        XCTAssertTrue(
            app.navigationBars["Choose a result"]
                .waitForExistence(timeout: 5)
        )
        app.buttons["All tools"].tap()
        let exportResult = app.buttons["documentTool-export"].firstMatch
        XCTAssertTrue(reveal(exportResult, in: app, maxSwipes: 6))
        exportResult.tap()
        let officeExportPage = app.navigationBars["PDF to Office"]
        let unifiedExportPage = app.navigationBars["Export"]
        XCTAssertTrue(
            officeExportPage.waitForExistence(timeout: 2)
                || unifiedExportPage.waitForExistence(timeout: 3)
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
            officeExportPage.exists
                || unifiedExportPage.exists
                || app.otherElements["ActivityListView"].exists
        )
        addScreenshot(
            named: "PaperPath Office Export Double Tap",
            app: app
        )
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
            "en"
        ]
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = englishLaunchArguments
        return app
    }

    private func openVerifiedDeliveryReceipt(
        accessibilityText: Bool = false
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
        selectWorkspaceLane(
            title: "Tasks",
            identifier: "workspaceLane-tasks",
            in: app
        )
        XCTAssertTrue(
            app.buttons["taskPackage-prepareToSend"]
                .waitForExistence(timeout: 3)
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
        document.tap()

        let readyToVerify = app.staticTexts["Ready to verify"]
        if !readyToVerify.waitForExistence(timeout: 10) {
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
            verifiedShareAction.tap()
        }
        let create = app.buttons["safeShareButton"]
        XCTAssertTrue(reveal(create, in: app, maxSwipes: 12))
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: create
        )
        waitForExpectations(timeout: 10)
        create.tap()

        if !accessibilityText {
            let verifiedTitle = app.staticTexts["workspaceDocumentTitle"]
                .firstMatch
            XCTAssertTrue(verifiedTitle.waitForExistence(timeout: 20))
            XCTAssertEqual(
                verifiedTitle.label,
                "Project handoff - verified"
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

    private func waitForLibrary(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["libraryWorkspaceLanes"]
            .firstMatch
            .waitForExistence(timeout: 8)
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
        app.searchFields["Search PDFs or tools"].firstMatch
    }

    private func documentToolSearchField(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.searchFields["Search by goal"].firstMatch
    }

    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> Bool {
        if element.exists {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 0.5) {
                return true
            }
        }
        return false
    }
}
