import Domain
import Foundation
@testable import Storage

extension Store {
    /// A registered and confirmed test profile (ADR 0010): tests run only through the registry.
    func confirmedTestProfile(
        project: ProjectID, executable: String = "/bin/sh", arguments: [String], name: String? = nil, writesWorktree: Bool = false,
        testInputPrefixes: [String] = []
    ) throws -> TestProfileID {
        let profile = try proposeTestProfile(project: project, TestProfileSpec(
            name: name ?? "profil-\(UUID().uuidString.prefix(8))", executable: executable, arguments: arguments,
            writesWorktree: writesWorktree, testInputPrefixes: testInputPrefixes
        ))
        return try confirmTestProfile(profile.id, digest: profile.digest, actor: "user").id
    }
}
