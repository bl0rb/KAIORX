import XCTest

/// Item 0.2 in the real app: a published job is delivered into a new branch and its published
/// candidate reverted, from the keyboard, through decision sheets whose Return key never acts.
/// Runs on a temporary database and repository prepared with one published candidate
/// (`KAIORX_UITEST_FIXTURE=published`); no provider runs.
@MainActor
final class DeliveryUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-KAIORXUITest"]
        app.launchEnvironment = [
            "KAIORX_UITEST_FOLDER": NSTemporaryDirectory() + "kaiorx-uitest-\(UUID().uuidString)",
            "KAIORX_UITEST_FIXTURE": "published",
        ]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    func text(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    func replaceName(_ field: XCUIElement, with name: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
    }

    func testAPublishedJobIsDeliveredIntoANewBranchAndItsCandidateReverted() {
        let deliver = app.buttons["deliverJob"]
        XCTAssertTrue(deliver.waitForExistence(timeout: 30), "the prepared job is not shown")
        XCTAssertTrue(text(containing: "Veröffentlichte Kandidaten: 1").waitForExistence(timeout: 10))

        // ⇧⌘B opens the delivery sheet; Return takes the safe choice and creates nothing.
        app.typeKey("b", modifierFlags: [.command, .shift])
        let name = app.textFields["deliveryName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "Wenn du ablehnst").waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))

        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let approve = app.buttons["decisionApprove"]

        // An invalid name blocks the approval and says why.
        replaceName(name, with: "kaputt name")
        XCTAssertTrue(text(containing: "Kein gültiger Branchname").waitForExistence(timeout: 5))
        XCTAssertFalse(approve.isEnabled)

        // A taken name (APFS: case does not count) shows the suffix that will be used.
        replaceName(name, with: "Main")
        XCTAssertTrue(text(containing: "angelegt wird „Main-2“").waitForExistence(timeout: 5))
        XCTAssertTrue(approve.waitForEnabled(timeout: 5))
        approve.click()
        XCTAssertTrue(text(containing: "Branch „Main-2“ angelegt").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))

        // Revert of the published candidate: the sheet names the action, ⇧⌘R opens it.
        app.staticTexts["Begrüßung ergänzen"].firstMatch.click()
        XCTAssertTrue(app.buttons["revertCandidate"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Veröffentlicht").exists)
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(text(containing: "Veröffentlichung zurücknehmen").waitForExistence(timeout: 5))
        XCTAssertTrue(approve.waitForEnabled(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5))
        XCTAssertFalse(text(containing: "Revert von").exists, "Return built a revert")

        app.buttons["revertCandidate"].click()
        XCTAssertTrue(approve.waitForEnabled(timeout: 5))
        approve.click()
        XCTAssertTrue(text(containing: "Der Revert-Kandidat ist gebaut").waitForExistence(timeout: 20))
        app.buttons["showRevertTask"].click()
        XCTAssertTrue(app.staticTexts["Revert von „Begrüßung ergänzen“"].firstMatch.waitForExistence(timeout: 10))

        // A second revert of the same publication is refused in the sheet.
        app.staticTexts["Begrüßung ergänzen"].firstMatch.click()
        XCTAssertTrue(app.buttons["revertCandidate"].waitForExistence(timeout: 10))
        app.buttons["revertCandidate"].click()
        XCTAssertTrue(text(containing: "schon einen offenen Revert").waitForExistence(timeout: 5))
        XCTAssertFalse(approve.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}

extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
