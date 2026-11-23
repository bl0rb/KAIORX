import Foundation
import Testing
@testable import Acceptance
@testable import Providers

/// `kaiorx-acceptance preflight` names the verdict of the same check the gate uses, and
/// `scripts/e2e-durchlauf.sh` reads exactly that line.
@Suite struct PreflightTests {
    static let sha = String(repeating: "ab", count: 32)

    @Test func onlyAVerifiedBuildReadsLiveAbgenommen() {
        #expect(Preflight.buildLine(.verified, version: "1.0", sha256: Self.sha) == "Build abababababababab…: live abgenommen")
        for verdict in [LiveVerification.versionNotListed, .versionNotLiveVerified, .buildNotVerified] {
            let line = Preflight.buildLine(verdict, version: "1.0", sha256: Self.sha)
            #expect(line.hasPrefix("Build abababababababab…: NICHT live abgenommen ("), "\(line)")
        }
    }

    @Test func everyLiveVerifiedMatrixBuildIsReportedAsVerified() throws {
        let live = CompatibilityMatrix.entries.filter { $0.status == .liveVerified }
        #expect(!live.isEmpty)
        for entry in live {
            for build in entry.builds {
                let identity = BinaryIdentity(path: "/x", resolvedPath: "/x", sha256: build, version: entry.version)
                let verdict = CompatibilityMatrix.liveVerification(entry.provider, identity: identity)
                #expect(Preflight.text(verdict, version: entry.version) == "live abgenommen")
            }
        }
    }

    /// The script's pattern matches the verified line and no other.
    @Test func theEndToEndScriptReadsThisLine() throws {
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "scripts/e2e-durchlauf.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let pattern = "'^  Build [0-9a-f]{16}…: live abgenommen$'"
        #expect(text.contains("grep -Eq \(pattern)"))
        let regex = try Regex("^  Build [0-9a-f]{16}…: live abgenommen$")
        #expect(("  " + Preflight.buildLine(.verified, version: "1", sha256: Self.sha)).wholeMatch(of: regex) != nil)
        #expect(("  " + Preflight.buildLine(.buildNotVerified, version: "1", sha256: Self.sha)).wholeMatch(of: regex) == nil)
    }
}
