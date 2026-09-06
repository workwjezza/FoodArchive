import XCTest

@MainActor
final class CoreFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-tests"]
        app.launch()
        XCTAssertTrue(app.buttons["addButton"].waitForExistence(timeout: 15))
    }

    private func reveal(_ element: XCUIElement, swipes: Int = 10) {
        for _ in 0..<swipes {
            let frame = element.exists ? element.frame : .zero
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
            let lowerEdge = min(app.frame.maxY - 100, keyboardTop - 16)
            let fullyVisible = frame.minY >= 130 && frame.maxY <= lowerEdge
            if element.exists && element.isHittable && (fullyVisible || element.elementType != .textField) { return }
            if element.exists && frame.maxY < 130 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected reachable control: \(element)")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        reveal(field)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    private func importPhoto(title: String, count: Int = 1) {
        app.buttons["addButton"].tap()
        let fixture = app.buttons["importTestPhoto"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        for index in 1...count {
            reveal(fixture)
            fixture.tap()
            XCTAssertTrue(app.staticTexts["\(index) ASSET(S) READY"].waitForExistence(timeout: 12))
        }
        replace(app.textFields["title"], with: title)
        app.swipeUp()
        let save = app.buttons["saveImport"]
        reveal(save)
        save.tap()
        XCTAssertTrue(app.buttons["addButton"].waitForExistence(timeout: 8))
    }

    private func tile(_ title: String) -> XCUIElement {
        app.buttons["foodTile_" + title]
    }

    func testImportOrganizeLogTwiceAndRelaunch() throws {
        importPhoto(title: "Miso toast")
        let food = tile("Miso toast")
        XCTAssertTrue(food.waitForExistence(timeout: 8))
        food.tap()

        let tagButton = app.buttons["TAG"]
        reveal(tagButton)
        tagButton.tap()
        replace(app.textFields["tag_name"], with: "Breakfast")
        app.buttons["addTag"].tap()
        app.buttons["DONE"].tap()

        app.buttons["COLLECT"].tap()
        replace(app.textFields["collection_name"], with: "Weekend")
        app.buttons["createCollection"].tap()
        replace(app.textFields["collection_name"], with: "Want to cook")
        app.buttons["createCollection"].tap()
        app.buttons["DONE"].tap()

        for _ in 0..<2 {
            let log = app.buttons["logExperience"]
            if !log.isHittable { app.swipeDown() }
            reveal(log)
            log.tap()
            let save = app.buttons["saveEntry"]
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            save.tap()
            XCTAssertTrue(app.buttons["logExperience"].waitForExistence(timeout: 5))
        }
        let history = app.staticTexts["2 EXPERIENCES · TRIED"]
        reveal(history)
        XCTAssertTrue(history.exists)
        XCTAssertTrue(app.staticTexts["BREAKFAST"].exists)
        XCTAssertTrue(app.staticTexts["WANT TO COOK / WEEKEND"].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(tile("Miso toast").waitForExistence(timeout: 10))
        app.buttons["journalTab"].tap()
        app.buttons["SUMMARY"].tap()
        XCTAssertTrue(app.navigationBars["SUMMARY"].waitForExistence(timeout: 5))
        let entryCount = app.buttons.matching(NSPredicate(format: "label CONTAINS 'ENTRIES' AND label CONTAINS '2'")).firstMatch
        XCTAssertTrue(entryCount.waitForExistence(timeout: 5))
        attachScreenshot("Summary after two persisted experiences")
    }

    func testBatchTagAndSearch() throws {
        importPhoto(title: "Lunch", count: 2)
        XCTAssertTrue(tile("Lunch 1").waitForExistence(timeout: 8))
        app.buttons["SELECT"].tap()
        app.buttons["Lunch 1"].tap()
        app.buttons["Lunch 2"].tap()
        app.buttons["TAG"].tap()
        replace(app.textFields["tag_name"], with: "Quick")
        app.buttons["addTag"].tap()
        app.navigationBars.buttons["DONE"].tap()
        app.buttons["DONE"].tap()
        app.buttons["SEARCH"].tap()
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("quick")
        XCTAssertTrue(tile("Lunch 1").exists)
        XCTAssertTrue(tile("Lunch 2").exists)
        replace(search, with: "does not exist")
        XCTAssertTrue(app.staticTexts["NO MATCHING ITEMS"].waitForExistence(timeout: 3))
        app.buttons["Clear and close search"].tap()
        XCTAssertTrue(tile("Lunch 1").exists)
    }

    func testTextOnlyDraftResumeEditAndRelaunch() throws {
        app.buttons["journalTab"].tap()
        app.buttons["addButton"].tap()
        let reflection = app.textViews["reflection"]
        reveal(reflection)
        reflection.tap()
        reflection.typeText("More lemon. Less hurry.")
        app.buttons["CANCEL"].tap()
        app.buttons["Keep draft"].tap()
        XCTAssertTrue(app.buttons["journalDrafts"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["journalTab"].tap()
        app.buttons["journalDrafts"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'More lemon'")).firstMatch.tap()
        app.buttons["saveEntry"].tap()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'journalEntry_'")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        app.buttons["Entry options"].tap()
        app.buttons["Edit entry"].tap()
        let editor = app.textViews["reflection"]
        reveal(editor)
        editor.tap()
        editor.typeText(" Next time, toast longer.")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["More lemon. Less hurry. Next time, toast longer."].waitForExistence(timeout: 5))
    }

    func testAccessibleHeaderAndCameraFallback() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-ui-tests",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let library = app.buttons["libraryTab"], journal = app.buttons["journalTab"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(library.isHittable)
        XCTAssertTrue(journal.isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["addButton"].frame.height, 44)
        XCTAssertFalse(library.frame.intersects(app.buttons["addButton"].frame))
        attachScreenshot("Accessibility header")
        app.buttons["addButton"].tap()
        let camera = app.buttons.matching(NSPredicate(format: "label CONTAINS 'CAMERA'")).firstMatch
        reveal(camera)
        camera.tap()
        let fallback = app.staticTexts["Camera is unavailable here. Use Photo Library or Files instead."]
        reveal(fallback)
        XCTAssertTrue(fallback.exists)
        XCTAssertTrue(app.buttons["photoLibrary"].exists)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}