import Darwin
import Foundation
import Testing
@testable import TestSupport

/// The tests' temporary folders must not pile up (they once filled the disk with 35 GB).
@Suite struct ScratchTests {
    @Test func folderLivesInThisProcessesTestFolder() throws {
        let folder = try Scratch.directory("scratch")
        #expect(folder.lastPathComponent.hasPrefix("scratch-"))
        #expect(FileManager.default.fileExists(atPath: Scratch.root.appending(path: folder.lastPathComponent).path(percentEncoded: false)))
        #expect(Scratch.root.lastPathComponent == "kaiorx-testrun-\(getpid())")
    }

    @Test func removeHandlesReadOnlyFoldersAndKeepsSymlinkTargets() throws {
        let folder = try Scratch.directory("remove").path(percentEncoded: false)
        let outside = try Scratch.directory("outside").path(percentEncoded: false)
        try "keep".write(toFile: outside + "/file", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: folder + "/sealed/deep", withIntermediateDirectories: true)
        try "x".write(toFile: folder + "/sealed/deep/file", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: folder + "/sealed/link", withDestinationPath: outside)
        chmod(folder + "/sealed/deep", 0o500)
        chmod(folder + "/sealed", 0o500)
        chmod(outside, 0o500)
        defer { chmod(outside, 0o700) }

        Scratch.remove(folder)

        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(FileManager.default.fileExists(atPath: outside + "/file"))
        var info = stat()
        #expect(stat(outside, &info) == 0 && info.st_mode & 0o777 == 0o500)
    }

    @Test func staleTestFoldersOfEndedProcessesAreRemoved() throws {
        let parent = try Scratch.directory("stale")
        let ended = parent.appending(path: "kaiorx-testrun-99999999")
        let running = parent.appending(path: "kaiorx-testrun-\(getppid())")
        let other = parent.appending(path: "kaiorx-other-1")
        for folder in [ended, running, other] {
            try FileManager.default.createDirectory(at: folder.appending(path: "inner"), withIntermediateDirectories: true)
        }
        chmod(ended.appending(path: "inner").path(percentEncoded: false), 0o500)

        Scratch.removeStaleRoots(in: parent)

        #expect(!FileManager.default.fileExists(atPath: ended.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: running.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }
}
