import Domain
import Foundation
import Orchestration
import Storage

/// The test profile registry in the app (ADR 0010): propose, confirm exactly what the sheet
/// showed, list, remove, and run the confirmed profile on a candidate.
extension WorkbenchActions {
    /// Adds a profile, or replaces the project's profile with the same name; changed content
    /// needs a new confirmation.
    @discardableResult
    public func proposeTestProfile(project: ProjectID, _ spec: TestProfileSpec) async throws -> TestProfileRecord {
        try await store.proposeTestProfile(project: project, spec)
    }

    /// Confirms the profile as the sheet showed it: `digest` is the shown digest, so a profile
    /// that changed meanwhile is refused and must be shown again.
    @discardableResult
    public func confirmTestProfile(_ id: TestProfileID, digest: String) async throws -> TestProfileRecord {
        try await store.confirmTestProfile(id, digest: digest, actor: WorkbenchActor.user)
    }

    public func testProfiles(project: ProjectID) async throws -> [TestProfileRecord] {
        try await store.testProfiles(project: project)
    }

    public func removeTestProfile(_ id: TestProfileID) async throws {
        try await store.removeTestProfile(id)
    }

    /// „Tests ausführen“: runs the candidate's confirmed profile (the plan task's named one, the
    /// chosen one, or the project's only one) on exactly the candidate's commit.
    @discardableResult
    public func runTests(_ candidate: CandidateID, profile requested: TestProfileID? = nil) async throws -> TestResultRecord {
        guard let integration = services.integration else { throw ActionError.unavailable("Integration") }
        let profile = try await integration.testProfile(for: candidate, requested: requested)
        return try await integration.runTests(candidate, profile: profile.id)
    }
}

/// What the profile form holds as text, and how it becomes a profile: one argument and one
/// test input prefix per line, so arguments with spaces stay whole and nothing is split by a
/// shell.
public struct TestProfileForm: Sendable, Equatable {
    public var name = ""
    public var executable = ""
    public var arguments = ""
    public var workingDirectory = "."
    public var timeoutSeconds = "600"
    public var writesWorktree = false
    public var testInputPrefixes = ""

    public init() {}

    public init(_ spec: TestProfileSpec) {
        name = spec.name
        executable = spec.executable
        arguments = spec.arguments.joined(separator: "\n")
        workingDirectory = spec.workingDirectory
        timeoutSeconds = String(spec.timeoutSeconds)
        writesWorktree = spec.writesWorktree
        testInputPrefixes = spec.testInputPrefixes.joined(separator: "\n")
    }

    /// The profile, or the German reasons it cannot be proposed.
    public func spec() -> Result<TestProfileSpec, TestProfileFormError> {
        guard let timeout = Int(timeoutSeconds.trimmingCharacters(in: .whitespaces)) else {
            return .failure(TestProfileFormError(messages: ["Das Zeitlimit muss eine ganze Zahl von Sekunden sein."]))
        }
        let spec = TestProfileSpec(
            name: name, executable: executable, arguments: Self.lines(arguments, trim: false), workingDirectory: workingDirectory,
            timeoutSeconds: timeout, writesWorktree: writesWorktree, testInputPrefixes: Self.lines(testInputPrefixes, trim: true)
        ).normalized()
        let issues = spec.issues
        return issues.isEmpty ? .success(spec) : .failure(TestProfileFormError(messages: issues.map(Labels.testProfileIssue)))
    }

    /// Non-empty lines (LF, CR or CRLF); arguments keep their inner and outer spaces.
    static func lines(_ text: String, trim: Bool) -> [String] {
        text.components(separatedBy: .newlines)
            .map { trim ? $0.trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }
    }
}

public struct TestProfileFormError: Error, Sendable, Equatable {
    public var messages: [String]
}

extension Labels {
    /// The command exactly as it runs, quoted for reading (it never goes through a shell).
    public static func commandLine(_ spec: TestProfileSpec) -> String {
        ([spec.executable] + spec.arguments).map(quoted).joined(separator: " ")
    }

    static func quoted(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:,+@%"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ plain.contains($0) && $0.isASCII }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func testProfile(_ profile: TestProfileRecord) -> StatusLabel {
        profile.isConfirmed
            ? StatusLabel("Bestätigt", "checkmark.shield", .success)
            : StatusLabel(profile.confirmedAt == nil ? "Nicht bestätigt" : "Geändert – erneut bestätigen", "exclamationmark.shield", .warning)
    }

    public static func testStatus(_ status: TestStatus) -> StatusLabel {
        switch status {
        case .passed: StatusLabel("Tests bestanden", "checkmark.circle", .success)
        case .failed: StatusLabel("Tests fehlgeschlagen", "xmark.octagon", .failure)
        case .crashed: StatusLabel("Testprozess abgestürzt", "bolt.trianglebadge.exclamationmark", .failure)
        case .timedOut: StatusLabel("Zeitlimit überschritten", "clock.badge.exclamationmark", .warning)
        case .inputsModified: StatusLabel("Tests haben versionierte Dateien geändert", "pencil.slash", .failure)
        case .infrastructureError: StatusLabel("Tests konnten nicht laufen", "exclamationmark.triangle", .warning)
        }
    }

    public static func testProfileIssue(_ issue: TestProfileIssue) -> String {
        switch issue {
        case .emptyName: "Bitte gib dem Profil einen Namen."
        case .nameTooLong: "Der Name darf höchstens \(TestProfileSpec.maxNameLength) Zeichen haben."
        case .controlCharacters(let field): "Steuerzeichen sind nicht erlaubt (\(field))."
        case .executableNotAbsolute: "Das Programm braucht einen absoluten Pfad ohne „..“, zum Beispiel /usr/bin/make."
        case .workingDirectoryLeavesWorktree: "Der Arbeitsordner muss relativ zum Worktree sein und darf ihn nicht verlassen."
        case .invalidTimeout: "Das Zeitlimit muss zwischen 1 und \(TestProfileSpec.maxTimeoutSeconds) Sekunden liegen."
        case .invalidTestInputPrefix(let prefix): "Ungültiger Testeingabe-Pfad: \(prefix)"
        }
    }

    /// Why „Tests ausführen“ was refused, as a sentence.
    public static func testProfileError(_ error: TestProfileError) -> String {
        switch error {
        case .unknownProfile: "Das Testprofil gehört nicht zu diesem Projekt."
        case .unknownName(let name): "Die Aufgabe verlangt das Testprofil „\(name)“, das im Projekt fehlt."
        case .notConfirmed(let name): "Das Testprofil „\(name)“ ist nicht bestätigt."
        case .notThePlannedProfile(_, let planned): "Die Aufgabe verlangt das Testprofil „\(planned)“."
        case .noneConfirmed: "Kein bestätigtes Testprofil im Projekt."
        case .ambiguous: "Mehrere bestätigte Testprofile: Bitte wähle eines."
        }
    }
}

extension DecisionSheet {
    /// Confirming a test profile: the full command, where and how long it runs, what it may
    /// write. The approval binds to the digest shown in the scope.
    public static func confirmTestProfile(_ profile: TestProfileRecord) -> DecisionSheet {
        let spec = profile.spec
        return DecisionSheet(
            title: "Testprofil bestätigen",
            action: "„\(spec.name)“ als Testbefehl dieses Projekts bestätigen.",
            scope: [
                "Befehl: \(Labels.commandLine(spec))",
                "Arbeitsordner im Worktree: \(spec.workingDirectory)",
                "Zeitlimit: \(spec.timeoutSeconds) s",
                spec.writesWorktree ? "Darf in den Worktree schreiben (Build-Ausgaben)" : "Schreibt nur in seinen temporären Ordner",
                spec.testInputPrefixes.isEmpty ? "Testeingaben: keine zusätzlichen Pfade" : "Testeingaben: \(spec.testInputPrefixes.joined(separator: ", "))",
                "Läuft mit deinen Rechten unter der Test-Isolation in einem frischen Worktree des Kandidaten.",
                "Prüfsumme: \(profile.digest)",
            ],
            ifRejected: "Das Profil bleibt unbestätigt: Es läuft nicht, und das Gate hält ohne grünen Test eines bestätigten Profils.",
            approveLabel: "Bestätigen", rejectLabel: "Nicht bestätigen", reported: nil, blockers: [], shown: nil
        )
    }
}
