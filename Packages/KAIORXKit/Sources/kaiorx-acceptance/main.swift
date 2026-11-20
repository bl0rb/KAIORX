import Acceptance
import Domain
import Foundation
import LocalAuthentication
import ProcessHost
import Providers
import Storage
import Workbench

// The account owner's live acceptance kit (package A, ADR 0008). Run it yourself in Terminal.app,
// never from Claude Code, Codex, a script or CI. Everything it writes stays in
// ~/Library/Application Support/KAIORX/acceptance/<run>; `export` copies the reviewed report.

/// How the owner started the kit (it is usually not on the PATH): the hint can be copied as is.
let selfCommand: String = {
    let path = CommandLine.arguments.first ?? "kaiorx-acceptance"
    let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-")
    return !path.isEmpty && path.allSatisfy(safe.contains) ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}()

let usage = """
    kaiorx-acceptance – Live-Abnahme durch den Kontoinhaber (ADR 0008)

      preflight                          Programme, Isolation und Anmeldebefehle zeigen (keine Modellaufrufe)
      run claude|codex|both --model M [--codex-model M]
                                         Abnahme starten (jeder Modellaufruf braucht deine getippte Zustimmung)
      resume RUN                         nach einem Schritt fortsetzen, der auf dich wartete
      status RUN                         Stand der Schritte
      report RUN                         Bericht und vorgeschlagene Matrixänderung erzeugen
      export RUN --to ORDNER             geprüften Bericht samt Aufzeichnungen in ORDNER/RUN kopieren
    """

struct TerminalPrompter: OwnerPrompter {
    func show(_ text: String) { print(text) }
    func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()
    }
}

struct KitError: Error, CustomStringConvertible {
    var description: String
}

func refuseUnlessOwner() throws {
    let reasons = OwnerGuard.refusals(.current())
    guard reasons.isEmpty else { throw KitError(description: "Abgelehnt:\n- " + reasons.joined(separator: "\n- ")) }
}

/// The Mac's owner authentication (Touch ID or password) once per session.
func authenticateOwner() async throws {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        throw KitError(description: "Die Anmeldung als Besitzer dieses Macs ist nicht verfügbar; das Kit läuft nicht ohne sie.")
    }
    let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "KAIORX-Live-Abnahme mit deinem Abo starten")
    guard ok else { throw KitError(description: "Nicht als Besitzer bestätigt.") }
}

func supportFolder() throws -> String {
    try AppPaths.supportFolder()
}

func configDirectory(_ provider: ProviderKind) throws -> String {
    try supportFolder() + (provider == .claude ? "/claude-config" : "/codex-home")
}

/// The repository's matrix source, next to this file in the source tree (nil when built elsewhere).
func compatibilitySource() -> String? {
    let path = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Providers/Compatibility.swift")
        .path(percentEncoded: false)
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

func runFolder(_ id: String) throws -> RunFolders {
    guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { throw KitError(description: "Ungültige Lauf-ID") }
    return RunFolders(root: try RunFolders.base() + "/" + id)
}

func context(_ folders: RunFolders) -> KitContext {
    KitContext(
        folders: folders, home: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), host: ProcessHost(),
        prompter: TerminalPrompter(), compatibilitySource: compatibilitySource()
    )
}

func writeReport(_ folders: RunFolders, state: RunState, context: KitContext) async throws {
    let report = AcceptanceReport.make(state, home: context.home)
    let json = try report.json()
    try json.write(to: URL(filePath: folders.root + "/report.json"), options: .atomic)
    try Data(report.markdown().utf8).write(to: URL(filePath: folders.root + "/report.md"), options: .atomic)
    print("Bericht: \(folders.root)/report.md")
    guard let sourcePath = context.compatibilitySource, let source = try? String(contentsOfFile: sourcePath, encoding: .utf8) else { return }
    let sha = json.sha256Hex
    var proposed = source
    for provider in report.providers where provider.passed {
        guard let version = provider.version, let binary = provider.binarySHA256 else { continue }
        proposed = try MatrixProposal.propose(
            source: proposed, provider: provider.provider, version: version, binarySHA256: binary,
            reportPath: "docs/live-acceptance/\(state.runID)/report.json", reportSHA256: sha, mode: provider.mode
        )
    }
    guard proposed != source else {
        print("Keine Matrixänderung: kein Anbieter hat bestanden.")
        return
    }
    let patch = try await MatrixProposal.diff(
        original: source, proposed: proposed, label: "Packages/KAIORXKit/Sources/Providers/Compatibility.swift", host: context.host, scratch: folders.temporary
    )
    try Data(patch.utf8).write(to: URL(filePath: folders.root + "/matrix.patch"), options: .atomic)
    print("Vorgeschlagene Matrixänderung: \(folders.root)/matrix.patch (prüfen, selbst anwenden und committen)")
}

extension Data {
    var sha256Hex: String {
        var hasher = CryptoHash()
        hasher.update(self)
        return hasher.hex
    }
}

import CryptoKit

struct CryptoHash {
    private var inner = SHA256()
    mutating func update(_ data: Data) { inner.update(data: data) }
    var hex: String { inner.finalize().map { String(format: "%02x", $0) }.joined() }
}

func run(_ arguments: [String]) async throws {
    guard let command = arguments.first, command != "--help", command != "-h" else {
        print(usage)
        return
    }
    try refuseUnlessOwner()
    let rest = Array(arguments.dropFirst())
    func option(_ name: String) -> String? { rest.firstIndex(of: name).flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil } }

    switch command {
    case "preflight":
        let host = ProcessHost()
        for provider in [ProviderKind.claude, .codex] {
            guard let native = Onboarding.locate(provider) else {
                print("\(provider.rawValue): nicht gefunden")
                continue
            }
            let identity = try await BinaryIdentity.probe(native, host: host)
            let entry = CompatibilityMatrix.entry(for: provider, version: identity.version)
            print("\(provider.rawValue): \(identity.version) \(native) (Matrix: \(entry?.status.rawValue ?? "fehlt"))")
            // Codex refuses a CODEX_HOME that does not exist: create both folders, owner-only.
            let folder = try configDirectory(provider)
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            print("  Anmeldung (selbst ausführen): \(Onboarding.loginCommand(provider, configDirectory: folder))")
        }
        let scratch = try RunFolders.base() + "/preflight"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        print("OS-Isolation: \(await Confinement.probe(host: host, scratch: URL(filePath: scratch)) == .effective ? "wirksam" : "NICHT wirksam")")
        print("Vor dem Lauf: Zusatz-Credits beim Anbieter ausschalten (Claude: Usage credits; ChatGPT: Credit-Nutzung für Apps).")

    case "run":
        guard let which = rest.first, ["claude", "codex", "both"].contains(which), let model = option("--model") else { throw KitError(description: usage) }
        try await authenticateOwner()
        let providers: [ProviderKind] = which == "both" ? [.claude, .codex] : [which == "claude" ? .claude : .codex]
        var runs: [ProviderRun] = []
        for provider in providers {
            guard let configured = Onboarding.candidatePaths(provider).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw KitError(description: "\(provider.rawValue) nicht gefunden")
            }
            let native = try NativeBinary.resolve(configured)
            let providerModel = provider == .codex ? (option("--codex-model") ?? model) : model
            runs.append(ProviderRun(provider: provider, configuredPath: configured, nativePath: native, model: providerModel, configDirectory: try configDirectory(provider)))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let id = formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        let folders = try runFolder(id)
        try folders.create()
        let state = RunState(runID: id, createdAt: Int64(Date().timeIntervalSince1970 * 1000), kaiorxCommit: nil, providers: runs)
        try state.save(folders.root)
        print("Lauf \(id) in \(folders.root)")
        let runner = AcceptanceRunner(state: state, context: context(folders))
        let finished = try await runner.run()
        try await writeReport(folders, state: await runner.state, context: context(folders))
        if !finished { print("Wartet auf dich. Danach: \(selfCommand) resume \(id)") }

    case "resume":
        guard let id = rest.first else { throw KitError(description: usage) }
        try await authenticateOwner()
        let folders = try runFolder(id)
        var state = try RunState.load(folders.root)
        // A changed binary voids the run: consent and evidence belong to the binary that was checked.
        for index in state.providers.indices {
            guard let identity = state.providers[index].identity else { continue }
            let now = try await BinaryIdentity.probe(state.providers[index].nativePath, host: ProcessHost())
            if now.sha256 != identity.sha256 { throw KitError(description: "Das Programm hat sich seit dem Start geändert; starte einen neuen Lauf.") }
        }
        let runner = AcceptanceRunner(state: state, context: context(folders))
        let finished = try await runner.run()
        state = await runner.state
        try await writeReport(folders, state: state, context: context(folders))
        if !finished { print("Wartet auf dich. Danach: \(selfCommand) resume \(id)") }

    case "status":
        guard let id = rest.first else { throw KitError(description: usage) }
        let state = try RunState.load(try runFolder(id).root)
        for run in state.providers {
            print("\(run.provider.rawValue) \(run.identity?.version ?? "?")")
            for step in StepID.allCases where step != .parallel { print("  \(step.title): \(run.steps[step]?.status.rawValue ?? "pending")") }
        }

    case "report":
        guard let id = rest.first else { throw KitError(description: usage) }
        let folders = try runFolder(id)
        try await writeReport(folders, state: try RunState.load(folders.root), context: context(folders))

    case "export":
        guard let id = rest.first, let target = option("--to") else { throw KitError(description: usage) }
        let folders = try runFolder(id)
        let destination = URL(filePath: target).appending(path: id).path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: destination) else { throw KitError(description: "\(destination) existiert bereits") }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for name in ["report.json", "report.md", "matrix.patch"] where FileManager.default.fileExists(atPath: folders.root + "/" + name) {
            try FileManager.default.copyItem(atPath: folders.root + "/" + name, toPath: destination + "/" + name)
        }
        if FileManager.default.fileExists(atPath: folders.fixtures) {
            try FileManager.default.copyItem(atPath: folders.fixtures, toPath: destination + "/fixtures")
        }
        print("Exportiert nach \(destination). Prüfe die Dateien, wende matrix.patch selbst an und committe.")

    default:
        throw KitError(description: usage)
    }
}

do {
    try await run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
