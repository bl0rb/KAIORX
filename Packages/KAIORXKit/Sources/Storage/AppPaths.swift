import Foundation

public enum AppPaths {
    /// `~/Library/Application Support/KAIORX/kaiorx.sqlite`; the folder is readable only by the user.
    public static func defaultDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = support.appending(path: "KAIORX", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
        return folder.appending(path: "kaiorx.sqlite", directoryHint: .notDirectory)
    }

    /// The app's support folder as a path without a trailing slash (`…/KAIORX`), so joined
    /// paths have no `//` and match what other programs print.
    public static func supportFolder() throws -> String {
        let path = try defaultDatabaseURL().deletingLastPathComponent().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
