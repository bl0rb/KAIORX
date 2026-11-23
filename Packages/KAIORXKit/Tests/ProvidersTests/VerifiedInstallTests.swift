import Domain
import Foundation
import Testing
import TestSupport
@testable import Providers

/// ADR 0013: the app runs a kept, live-accepted Claude build when `claude` links to another one.
@Suite struct VerifiedInstallTests {
    /// `…/claude/versions/<version>` files with distinct contents, executable.
    func versions(_ names: [String]) throws -> String {
        let folder = try Scratch.directory("versions").appending(path: "share/claude/versions").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in names {
            try "build \(name)".write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
            chmod(folder + "/" + name, 0o755)
        }
        return folder
    }

    func live(_ version: String, _ path: String) -> CompatibilityEntry {
        CompatibilityEntry(provider: .claude, version: version, status: .liveVerified, notes: "", schemaDigest: nil, builds: [VerifiedInstall.sha256(path)!])
    }

    @Test func anUnacceptedLinkedBuildGivesWayToTheNewestAcceptedKeptOne() throws {
        let folder = try versions(["1.0", "1.1", "2.0"])
        let matrix = [live("1.0", folder + "/1.0"), live("1.1", folder + "/1.1")]
        #expect(VerifiedInstall.prefer(folder + "/2.0", provider: .claude, matrix: matrix) == folder + "/1.1")
        // An accepted linked build stays.
        #expect(VerifiedInstall.prefer(folder + "/1.0", provider: .claude, matrix: matrix) == folder + "/1.0")
    }

    @Test func aKeptFileWithAnotherBuildIsNeverChosen() throws {
        let folder = try versions(["1.0", "2.0"])
        let other = try versions(["1.0"])
        // The matrix names a different build of 1.0 than the kept file.
        let matrix = [live("1.0", other + "/1.0")]
        try "changed".write(toFile: folder + "/1.0", atomically: true, encoding: .utf8)
        #expect(VerifiedInstall.prefer(folder + "/2.0", provider: .claude, matrix: matrix) == folder + "/2.0")
    }

    @Test func onlyClaudesVersionFolderIsConsidered() throws {
        let folder = try versions(["1.0", "2.0"])
        let matrix = [live("1.0", folder + "/1.0")]
        #expect(VerifiedInstall.prefer(folder + "/2.0", provider: .codex, matrix: matrix) == folder + "/2.0")
        let elsewhere = try Scratch.directory("bin").appending(path: "claude").path(percentEncoded: false)
        try "x".write(toFile: elsewhere, atomically: true, encoding: .utf8)
        #expect(VerifiedInstall.prefer(elsewhere, provider: .claude, matrix: matrix) == elsewhere)
        // Without any accepted kept build the linked one stays (and the gate refuses it).
        #expect(VerifiedInstall.prefer(folder + "/2.0", provider: .claude, matrix: []) == folder + "/2.0")
    }

    @Test func onlyFilesNamedLikeAnAcceptedVersionAreHashed() throws {
        let folder = try versions(["1.0", "2.0", "3.0"])
        let matrix = [live("1.0", folder + "/1.0")]
        var hashed: [String] = []
        _ = VerifiedInstall.prefer(folder + "/3.0", provider: .claude, matrix: matrix) { path in
            hashed.append(URL(filePath: path).lastPathComponent)
            return VerifiedInstall.sha256(path)
        }
        #expect(hashed == ["1.0"])
    }
}
