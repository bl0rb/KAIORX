import Foundation
import ProcessHost

/// Resolves a configured provider path to the native executable that actually runs. npm installs
/// `codex` as a Node launcher (`#!/usr/bin/env node`) that execs a platform binary from an
/// optional dependency; the adapters start processes with a minimal `PATH` and no Node, so they
/// must start that native binary directly (it is the same version). Only reads files.
public enum NativeBinary {
    public enum ResolutionError: Error, Equatable, Sendable {
        case notFound(String)
        case notMachO(String)
        case unknownLauncher(String)
    }

    /// The native executable for `path`: itself when it is a Mach-O file, the vendored binary when
    /// it is the npm `codex` launcher; anything else is refused.
    public static func resolve(_ path: String) throws -> String {
        let resolved = Confinement.resolved(path)
        guard FileManager.default.fileExists(atPath: resolved) else { throw ResolutionError.notFound(path) }
        if isMachO(resolved) { return resolved }
        // …/node_modules/@openai/codex/bin/codex.js → …/@openai/codex/node_modules/@openai/codex-darwin-<arch>/vendor/<triple>/bin/codex
        let url = URL(filePath: resolved)
        guard url.lastPathComponent == "codex.js", url.deletingLastPathComponent().lastPathComponent == "bin" else {
            throw ResolutionError.unknownLauncher(resolved)
        }
        let package = url.deletingLastPathComponent().deletingLastPathComponent()
        guard package.lastPathComponent == "codex", package.deletingLastPathComponent().lastPathComponent == "@openai" else {
            throw ResolutionError.unknownLauncher(resolved)
        }
        #if arch(arm64)
        let (platform, triple) = ("codex-darwin-arm64", "aarch64-apple-darwin")
        #else
        let (platform, triple) = ("codex-darwin-x64", "x86_64-apple-darwin")
        #endif
        let candidates = [
            package.appending(path: "node_modules/@openai/\(platform)/vendor/\(triple)/bin/codex"),
            package.deletingLastPathComponent().appending(path: "\(platform)/vendor/\(triple)/bin/codex"),
            package.appending(path: "vendor/\(triple)/bin/codex"),
        ].map { $0.path(percentEncoded: false) }
        guard let native = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ResolutionError.notFound(candidates[0])
        }
        let final = Confinement.resolved(native)
        guard isMachO(final) else { throw ResolutionError.notMachO(final) }
        return final
    }

    /// Mach-O 64-bit or universal (fat) magic in the first four bytes.
    public static func isMachO(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xFEED_FACF, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA, 0xFEED_FACE, 0xCEFA_EDFE].contains(magic)
    }
}
