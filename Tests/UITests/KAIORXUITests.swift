import XCTest

/// Package H acceptance in the real app: keyboard-reachable main path, decision sheets whose
/// Return key never approves, and an interrupted run. Runs on a temporary database and a
/// temporary Git repository with the fake providers only (never the real CLIs).
@MainActor
final class KAIORXUITests: XCTestCase {
    var app: XCUIApplication!
    var folder: String!

    func launch(script: String = "success", seed: String? = nil, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchArguments = ["-KAIORXUITest"]
        folder = NSTemporaryDirectory() + "kaiorx-uitest-\(UUID().uuidString)"
        app.launchEnvironment = [
            "KAIORX_UITEST_FOLDER": folder,
            "KAIORX_UITEST_SCRIPT": script,
        ]
        if let seed { app.launchEnvironment["KAIORX_UITEST_SEED"] = seed }
        app.launchEnvironment.merge(environment) { $1 }
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
        XCTAssertTrue(trust.waitForNonExistence(timeout: 5), "Return did not close the trust sheet")
        XCTAssertFalse(app.staticTexts["repo"].exists, "Return opened the project")
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

    /// ADR 0013 with fake CLIs (never the real ones): the login row offers both buttons, the
    /// check reads „Nicht angemeldet“, the login terminal logs in (the fake does so only with
    /// the self-update lock set) and „Fertig“ checks again, without a restart.
    func testTheLoginButtonsLogInAndCheckWithoutARestart() {
        launch(environment: ["KAIORX_UITEST_CLIS": "1"])
        let check = app.buttons["checkLogin-claude"]
        XCTAssertTrue(check.waitForExistence(timeout: 30), "no login buttons")
        XCTAssertTrue(app.buttons["login-codex"].exists, "no login button for Codex")
        check.click()
        XCTAssertTrue(label(containing: "Nicht angemeldet.").waitForExistence(timeout: 20), "the check did not run")
        app.buttons["login-claude"].click()
        XCTAssertTrue(app.descendants(matching: .any)["loginTerminal"].waitForExistence(timeout: 10), "no login terminal")
        // The fake logs in only with the self-update lock set.
        let marker = folder + "/claude-config/angemeldet"
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "the fake CLI did not log in (DISABLE_AUTOUPDATER missing?)")
        app.buttons["loginDone"].click()
        XCTAssertTrue(app.buttons["loginDone"].waitForNonExistence(timeout: 5), "the login sheet stayed open")
        XCTAssertTrue(label(containing: "Angemeldet mit Abo (max).").waitForExistence(timeout: 20), "the login was not checked after „Fertig“")
    }

    func label(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// ADR 0012 D7: „Einrichtung prüfen …“ shows the checks with a project open and runs them
    /// again (with the profile sync) without a restart.
    func testTheSetupCheckRunsAgainWithAProjectOpen() {
        launch()
        openProject()
        for name in ["Ablage", "File"] where app.menuBarItems[name].exists {
            app.menuBarItems[name].click()
            break
        }
        let menuItem = app.menuItems["Einrichtung prüfen …"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "no menu item")
        menuItem.click()
        let recheck = app.buttons["recheckSetup"]
        XCTAssertTrue(recheck.waitForExistence(timeout: 5), "no setup check sheet")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-project"].waitForExistence(timeout: 10))
        recheck.click()
        let done = NSPredicate(format: "isEnabled == true")
        expectation(for: done, evaluatedWith: recheck)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-project"].exists)
        app.buttons["closeSetupCheck"].click()
        XCTAssertTrue(recheck.waitForNonExistence(timeout: 5), "the sheet stayed open")
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

    /// ADR 0010: a test profile is added, confirmed from its full command (Return confirms
    /// nothing), and „Tests ausführen“ runs it on a candidate.
    func testAConfirmedProfileRunsTestsOnACandidate() {
        launch(seed: "candidate")
        let openProfiles = app.buttons["openTestProfiles"]
        XCTAssertTrue(openProfiles.waitForExistence(timeout: 30), "no candidate without a confirmed profile")
        // ADR 0010 §6: „Tests ausführen“ stays visible with the reason, but locked.
        let locked = app.buttons["runTests"]
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        XCTAssertFalse(locked.isEnabled, "tests can run without a confirmed profile")
        XCTAssertTrue(app.descendants(matching: .any)["testProfileBlocked"].exists)
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
        let status = app.descendants(matching: .any)["testProfileStatus-Schnelltest"]
        XCTAssertEqual(status.label, "Nicht bestätigt")
        confirm.click()
        // The page names the full command; Return is the safe choice and confirms nothing.
        // Plain texts carry their text as value, badges as label.
        let line = "Befehl: /bin/sh -c 'test -f LEERWERT.md'"
        let command = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", line, line)).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Nicht bestätigt")
        confirm.click()
        let approve = app.buttons["decisionApprove"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        XCTAssertEqual(status.label, "Bestätigt")
        app.buttons["closeTestProfiles"].click()

        let run = app.buttons["runTests"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.click()
        let passed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tests bestanden'")).firstMatch
        XCTAssertTrue(passed.waitForExistence(timeout: 60))
        let reviewing = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Im Review'")).firstMatch
        XCTAssertTrue(reviewing.waitForExistence(timeout: 10))
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
