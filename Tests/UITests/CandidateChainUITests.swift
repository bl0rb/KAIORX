import XCTest

/// The candidate chain in the real app (ADR 0011): an agent's result is sealed and built on its
/// own; undeclared paths, empty results, conflicts and review starts wait for the user, through
/// decision sheets whose Return key never approves. Runs on a temporary database and repository
/// with the fake providers only (never the real CLIs).
@MainActor
final class CandidateChainUITests: XCTestCase {
    var app: XCUIApplication!

    func launch(script: String = "success", seed: String? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["-KAIORXUITest"]
        app.launchEnvironment = [
            "KAIORX_UITEST_FOLDER": NSTemporaryDirectory() + "kaiorx-uitest-\(UUID().uuidString)",
            "KAIORX_UITEST_SCRIPT": script,
        ]
        if let seed { app.launchEnvironment["KAIORX_UITEST_SEED"] = seed }
        app.launch()
    }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    // MARK: Helpers

    func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    func text(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    /// Waits until the element's label (badges) or value (plain texts) contains `fragment`.
    func waitForLabel(_ element: XCUIElement, containing fragment: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// Return on an open decision sheet takes the safe choice: the sheet closes, no outcome
    /// appears and the approval stays untaken (`key` .escape checks Escape the same way).
    func assertReturnDoesNotApprove(key: XCUIKeyboardKey = .return, file: StaticString = #filePath, line: UInt = #line) {
        let approve = app.buttons["decisionApprove"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "no decision sheet", file: file, line: line)
        XCTAssertTrue(text(containing: "Wenn du ablehnst").waitForExistence(timeout: 10), file: file, line: line)
        app.typeKey(key, modifierFlags: [])
        let outcome = app.descendants(matching: .any)["sheetResult"]
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5), "the key did not close the sheet", file: file, line: line)
        XCTAssertFalse(outcome.exists, "the key approved", file: file, line: line)
    }

    func approveWhenEnabled(file: StaticString = #filePath, line: UInt = #line) {
        let approve = app.buttons["decisionApprove"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10), file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: approve)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "approval stays blocked", file: file, line: line)
        approve.click()
    }

    func openProject() {
        let open = app.buttons["onboardingOpenProject"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.click()
        let trust = app.buttons["trustOpen"]
        XCTAssertTrue(trust.waitForExistence(timeout: 5))
        trust.click()
        XCTAssertTrue(app.staticTexts["repo"].waitForExistence(timeout: 10))
    }

    func createJob(title: String) {
        app.typeKey("n", modifierFlags: [.command, .shift])
        let goal = app.textFields["jobGoal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.click()
        goal.typeText("Neue Datei")
        let task = app.textFields["taskTitle"].firstMatch
        task.click()
        task.typeText(title)
        app.buttons["createJob"].click()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    /// Picks one segment of a segmented picker, whichever element type AppKit reports for it.
    func choose(_ segment: String, in picker: XCUIElement) {
        for candidate in [picker.radioButtons[segment], picker.buttons[segment], picker.descendants(matching: .any)[segment]] where candidate.exists {
            candidate.click()
            return
        }
        XCTFail("segment \(segment) not found")
    }

    // MARK: Tests

    /// A consented plan task runs (the fake author writes `src/neu.swift`); the chain seals and
    /// builds its result without any further click.
    func testAnAgentRunBecomesACandidate() {
        launch(script: "writes")
        openProject()
        createJob(title: "Neue Datei anlegen")
        app.staticTexts["Neue Datei anlegen"].click()
        let decide = app.buttons["decideTask"]
        XCTAssertTrue(decide.waitForExistence(timeout: 20), "no consent decision appeared")
        decide.click()
        approveWhenEnabled()
        let status = element("candidateStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 60), "the result did not become a candidate")
        XCTAssertTrue(waitForLabel(status, containing: "Gebaut", timeout: 10))
        XCTAssertTrue(text(containing: "src/neu.swift").waitForExistence(timeout: 10))
        // Tests stay with the user (ADR 0010): the candidate waits for them.
        XCTAssertTrue(text(containing: "Noch kein Testlauf").waitForExistence(timeout: 10))
    }

    /// A seal that dropped a path outside the write area builds nothing until the user confirms.
    func testUndeclaredPathsNeedConfirmation() {
        launch(seed: "undeclared")
        let status = element("resultStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 30), "the seeded result is not shown")
        XCTAssertTrue(waitForLabel(status, containing: "1 Pfad verworfen", timeout: 10))
        XCTAssertTrue(element("rejectedPath-NOTIZ.md").exists)
        XCTAssertTrue(waitForLabel(element("writeArea"), containing: "docs/", timeout: 5))

        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(text(containing: "Verworfen: NOTIZ.md").waitForExistence(timeout: 10))
        assertReturnDoesNotApprove()
        XCTAssertFalse(element("candidateStatus").exists, "Return built a candidate")

        app.buttons["decideResult"].click()
        XCTAssertTrue(app.buttons["Ohne diese Pfade bauen"].waitForExistence(timeout: 10))
        approveWhenEnabled()
        XCTAssertTrue(waitForLabel(element("sheetResult"), containing: "Kandidat gebaut", timeout: 30))
        app.buttons["resultDone"].click()
        let candidate = element("candidateStatus")
        XCTAssertTrue(candidate.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForLabel(candidate, containing: "Gebaut", timeout: 10))
    }

    /// An empty result is never accepted on its own; the user accepts it as done.
    func testEmptyResultIsAcceptedExplicitly() {
        launch(seed: "empty")
        let status = element("resultStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 30), "the seeded result is not shown")
        XCTAssertTrue(waitForLabel(status, containing: "Leer", timeout: 10))
        // Several chain passes later the task still waits for the user.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(waitForLabel(element("taskStatus"), containing: "Ergebnis liegt vor", timeout: 5))

        app.buttons["decideResult"].click()
        XCTAssertTrue(text(containing: "Leeres Ergebnis").waitForExistence(timeout: 10))
        assertReturnDoesNotApprove()
        XCTAssertTrue(waitForLabel(element("taskStatus"), containing: "Ergebnis liegt vor", timeout: 5))

        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Als erledigt annehmen"].waitForExistence(timeout: 10))
        approveWhenEnabled()
        XCTAssertTrue(waitForLabel(element("sheetResult"), containing: "als erledigt angenommen", timeout: 20))
        app.buttons["resultDone"].click()
        XCTAssertTrue(waitForLabel(element("taskStatus"), containing: "Integriert", timeout: 20))
    }

    /// A conflicted candidate is resolved path by path; nothing is preselected.
    func testConflictsAreResolved() {
        launch(seed: "conflicted")
        let row = element("conflict-KONFLIKT.md")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the seeded conflict is not shown")
        XCTAssertTrue(waitForLabel(element("candidateStatus"), containing: "Konflikt", timeout: 10))

        app.typeKey("k", modifierFlags: [.command, .shift])
        let picker = element("conflictResolution-KONFLIKT.md")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Noch ohne Entscheidung: 1 Datei").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["decisionApprove"].isEnabled, "approval without a choice")
        assertReturnDoesNotApprove()
        XCTAssertTrue(waitForLabel(element("candidateStatus"), containing: "Konflikt", timeout: 5))

        app.buttons["resolveConflicts"].click()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        choose("Ergebnis übernehmen", in: picker)
        approveWhenEnabled()
        XCTAssertTrue(waitForLabel(element("sheetResult"), containing: "Konflikt gelöst", timeout: 30))
        app.buttons["conflictsDone"].click()
        XCTAssertTrue(waitForLabel(element("candidateStatus"), containing: "Gebaut", timeout: 20))
    }

    /// Continues `KAIORXUITests.testAConfirmedProfileRunsTestsOnACandidate`: after the tests the
    /// user starts the review explicitly; the chain collects it and the candidate can be approved.
    func testReviewMakesTheCandidateApprovable() {
        launch(seed: "candidate")
        let openProfiles = app.buttons["openTestProfiles"]
        XCTAssertTrue(openProfiles.waitForExistence(timeout: 30), "no candidate without a confirmed profile")
        openProfiles.click()
        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Schnelltest")
        let executable = app.textFields["profileExecutable"]
        executable.click()
        executable.typeText("/bin/sh")
        let arguments = app.textViews["profileArguments"]
        arguments.click()
        arguments.typeText("-c\ntest -f LEERWERT.md")
        app.buttons["proposeTestProfile"].click()
        let confirm = app.buttons["confirmTestProfile-Schnelltest"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.click()
        approveWhenEnabled()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        app.buttons["closeTestProfiles"].click()

        let run = app.buttons["runTests"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.click()
        XCTAssertTrue(waitForLabel(element("candidateStatus"), containing: "Im Review", timeout: 60))
        let review = element("reviewStatus")
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(review, containing: "Noch kein Review", timeout: 10))
        // Nothing starts a review on its own (ADR 0009 §8).
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(waitForLabel(review, containing: "Noch kein Review", timeout: 2))

        // The import sheet: without text nothing can be stored; declining stores nothing.
        app.buttons["importReview"].click()
        let pasted = app.textViews["importReviewText"]
        XCTAssertTrue(pasted.waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Füge den Text des Reviews ein").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["decisionApprove"].isEnabled)
        // Return inside the text is a line break, not the sheet's safe choice.
        pasted.click()
        pasted.typeText("Zeile 1\nZeile 2")
        XCTAssertTrue(app.buttons["decisionApprove"].waitForEnabled(timeout: 5))
        XCTAssertTrue(pasted.exists, "Return in the text closed the sheet")
        app.buttons["decisionReject"].click()
        XCTAssertTrue(pasted.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(review, containing: "Noch kein Review", timeout: 5))

        app.typeKey("r", modifierFlags: [.command, .option])
        let codex = element("reviewOption-codex")
        XCTAssertTrue(codex.waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Ein Review verbraucht Kontingent").waitForExistence(timeout: 5))
        assertReturnDoesNotApprove()
        XCTAssertTrue(waitForLabel(review, containing: "Noch kein Review", timeout: 5))

        app.buttons["startReview"].click()
        XCTAssertTrue(codex.waitForExistence(timeout: 10))
        codex.click()
        approveWhenEnabled()
        XCTAssertTrue(waitForLabel(element("sheetResult"), containing: "gestartet", timeout: 30))
        app.buttons["reviewDone"].click()
        XCTAssertTrue(waitForLabel(review, containing: "Zugestimmt", timeout: 60), "the review was not collected")
        let approve = app.buttons["approveCandidate"]
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "the candidate cannot be approved")
    }

    /// Return never approves in the result sheets: neither the build of undeclared paths nor
    /// discarding the result.
    func testReturnNeverApproves() {
        launch(seed: "undeclared")
        let status = element("resultStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(status, containing: "1 Pfad verworfen", timeout: 10))

        app.buttons["decideResult"].click()
        assertReturnDoesNotApprove()

        let discard = app.buttons["discardResult"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertTrue(text(containing: "Die Zählung der Versuche beginnt neu").waitForExistence(timeout: 10))
        assertReturnDoesNotApprove()
        // Escape takes the same safe choice.
        discard.click()
        XCTAssertTrue(text(containing: "Die Zählung der Versuche beginnt neu").waitForExistence(timeout: 10))
        assertReturnDoesNotApprove(key: .escape)

        // The secondary „Ergebnis verwerfen …“ in the build sheet switches, it does not discard.
        app.buttons["decideResult"].click()
        let secondary = app.buttons["sheetDiscardResult"]
        XCTAssertTrue(secondary.waitForExistence(timeout: 10))
        secondary.click()
        XCTAssertTrue(app.buttons["Verwerfen und neu bearbeiten lassen"].waitForExistence(timeout: 10))
        assertReturnDoesNotApprove()

        XCTAssertTrue(waitForLabel(element("taskStatus"), containing: "Ergebnis liegt vor", timeout: 5))
        XCTAssertTrue(waitForLabel(status, containing: "1 Pfad verworfen", timeout: 5))
        XCTAssertFalse(element("candidateStatus").exists)
    }
}
