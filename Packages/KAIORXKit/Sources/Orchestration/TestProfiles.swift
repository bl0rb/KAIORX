import Domain
import Foundation
import Workspace

/// Why a test run was refused before it started (ADR 0010).
public enum TestProfileError: Error, Equatable, Sendable {
    /// Not in the candidate's project registry.
    case unknownProfile(TestProfileID)
    /// The plan task names a profile the registry does not have.
    case unknownName(String)
    /// Registered, but its current content is not confirmed.
    case notConfirmed(String)
    /// The plan task names another profile.
    case notThePlannedProfile(requested: String, planned: String)
    /// The project has no confirmed profile.
    case noneConfirmed
    /// Several confirmed profiles and none chosen.
    case ambiguous([String])
}

extension TestProfile {
    /// The run form of a registry profile: no extra environment, the default output limit.
    public init(_ spec: TestProfileSpec) {
        self.init(
            executable: spec.executable, arguments: spec.arguments, workingDirectory: spec.workingDirectory, timeoutSeconds: spec.timeoutSeconds,
            writesWorktree: spec.writesWorktree, testInputPrefixes: spec.testInputPrefixes
        )
    }
}
