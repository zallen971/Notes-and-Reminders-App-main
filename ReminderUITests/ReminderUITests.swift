//
//  ReminderUITests.swift
//  ReminderUITests
//
//  Created by Zachary Allen on 1/2/25.
//

import XCTest

final class ReminderUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testNotesHasSearchField() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.searchFields["Search notes"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNewNoteButtonOpensEditor() throws {
        let app = XCUIApplication()
        app.launch()

        // an empty new note isn't saved, so this leaves no data behind
        app.buttons["New note"].tap()
        XCTAssertTrue(app.textViews["Note text"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAddReminderButtonHasAccessibleLabel() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Reminders"].tap()
        XCTAssertTrue(app.buttons["Add reminder"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
