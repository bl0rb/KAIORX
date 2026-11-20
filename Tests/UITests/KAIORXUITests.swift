import XCTest

/// Package H acceptance in the real app: keyboard-reachable main path, decision sheets whose
/// Return key never approves, and an interrupted run. Runs on a temporary database and a
/// temporary Git repository with the fake providers only (never the real CLIs).
@MainActor
final class KAIORXUITests: XCTestCase {
    var app: XCUIApplication!

    func launch(script: String = "success") {
        app = XCUIApplication()
        app.launchArguments = ["-KAIORXUITest"]
        app.launchEnvironment = [
            "KAIORX_UITEST_FOLDER": NSTemporaryDirectory() + "kaiorx-uitest-\(UUID().uuidString)",
            "KAIORX_UITEST_SCRIPT": script,
        ]
        app.launch()
    }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    /// Opens the fixture project through the trust sheet; Return on the sheet does not open.
    func openProject() {
        let open = app.buttons["onboardingOpenProject"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.click()
        let trust = app.buttons["trustOpen"]
        XCTAssertTrue(trust.waitForExistence(timeout: 5))
        // Return triggers the safe default: nothing is opened.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(trust.waitForExistence(timeout: 5))
        trust.click()
        XCTAssertTrue(app.staticTexts["repo"].waitForExistence(timeout: 10))
    }

    func createJob(title: String) {
        app.typeKey("n", modifierFlags: [.command, .shift])
        let goal = app.textFields["jobGoal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.click()
        goal.typeText("Leerwert dokumentieren")
        let task = app.textFields["taskTitle"].firstMatch
        task.click()
        task.typeText(title)
        app.buttons["createJob"].click()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    func testOnboardingShowsChecksAndOpensATrustedProject() {
        launch()
        XCTAssertTrue(app.otherElements["onboarding-git"].waitForExistence(timeout: 20) || app.staticTexts["Git"].waitForExistence(timeout: 5))
        openProject()
    }

    func testConsentIsAskedAndTheRunStarts() {
        launch()
        openProject()
        createJob(title: "Handbuch ergänzen")
        app.staticTexts["Handbuch ergänzen"].click()
        // The task waits for consent; the decision sheet names action, scope and consequence.
        let decide = app.buttons["decideTask"]
        XCTAssertTrue(decide.waitForExistence(timeout: 20), "no consent decision appeared")
        decide.click()
        XCTAssertTrue(app.staticTexts["Wenn du ablehnst"].waitForExistence(timeout: 5))
        app.buttons["decisionApprove"].click()
        XCTAssertTrue(app.descendants(matching: .any)["attemptStatus"].waitForExistence(timeout: 30))
    }

    func testARunningAttemptIsInterruptedFromTheKeyboard() {
        launch(script: "hang")
        openProject()
        createJob(title: "Lange Aufgabe")
        app.staticTexts["Lange Aufgabe"].click()
        let decide = app.buttons["decideTask"]
        XCTAssertTrue(decide.waitForExistence(timeout: 20))
        decide.click()
        let approve = app.buttons["decisionApprove"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.click()
        let running = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Läuft'")).firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 30))
        app.typeKey(".", modifierFlags: .command)
        let ended = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Abgebrochen'")).firstMatch
        XCTAssertTrue(ended.waitForExistence(timeout: 30))
    }
}
