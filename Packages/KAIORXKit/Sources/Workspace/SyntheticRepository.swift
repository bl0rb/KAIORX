import Foundation

extension GitRunner {
    /// Creates a throwaway repository with one commit of `files` (relative path → content) in an
    /// empty folder the caller just created, never in a user's checkout. For synthetic test data
    /// (the owner's acceptance kit). Returns the commit.
    public func createSyntheticRepository(at folder: String, files: [String: String], message: String = "synthetic") async throws -> String {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        guard existing.isEmpty else { throw GitError.failed(arguments: ["init"], termination: .exited(1), stderr: "folder not empty: \(folder)") }
        try await run(["init", "-q", "-b", "main"], in: folder)
        for (path, content) in files.sorted(by: { $0.key < $1.key }) {
            let url = URL(filePath: folder).appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        try await run(["add", "-A"], in: folder)
        try await run(
            ["commit", "-q", "-m", message], in: folder,
            environment: ["GIT_AUTHOR_NAME": "KAIORX", "GIT_AUTHOR_EMAIL": "kaiorx@example.invalid",
                          "GIT_COMMITTER_NAME": "KAIORX", "GIT_COMMITTER_EMAIL": "kaiorx@example.invalid"]
        )
        return try await output(["rev-parse", "HEAD"], in: folder)
    }
}
