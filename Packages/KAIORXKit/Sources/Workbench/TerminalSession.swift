import Darwin
import Foundation
import ProcessHost

/// The user's own shell on a PTY (Plan/macos-und-git.md: a native user shell with a visible
/// working folder, separate from the agents' protocol). It starts in the project checkout;
/// attempt worktrees stay closed until a handover exists (ADR 0007). Its environment is built
/// from an allow-list: KAIORX's provider session data (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
/// access tokens) and the SSH agent socket never reach it.
public enum TerminalSessions {
    /// Host variables the shell may get. Everything else (tokens, KAIORX settings, provider
    /// configuration folders) stays out; the login shell sets up the user's own tools itself.
    public static let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LC_COLLATE", "LC_NUMERIC", "LC_TIME", "TMPDIR"]
    public static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    /// The user's login shell from the account database if `/etc/shells` lists it, else `/bin/zsh`.
    public static func shell() -> String {
        var candidate: String?
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell { candidate = String(cString: raw) }
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8))?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") } ?? []
        if let candidate, candidate.hasPrefix("/"), listed.contains(candidate), FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/bin/zsh"
    }

    /// The environment for the user's shell.
    public static func environment(host: [String: String] = ProcessInfo.processInfo.environment, shell: String) -> [String: String] {
        var result: [String: String] = ["PATH": fixedPath, "TERM": "xterm-256color", "COLORTERM": "truecolor", "SHELL": shell, "TERM_PROGRAM": "KAIORX"]
        for name in allowed { if let value = host[name] { result[name] = value } }
        if result["LANG"] == nil { result["LANG"] = "de_DE.UTF-8" }
        return result
    }

    /// The spec for a login shell in `folder` (an absolute directory).
    public static func spec(folder: String, rows: UInt16, columns: UInt16, host: [String: String] = ProcessInfo.processInfo.environment) -> TerminalSpec {
        let shell = shell()
        return TerminalSpec(executable: shell, arguments: ["-l"], workingDirectory: folder, environment: environment(host: host, shell: shell), rows: rows, columns: columns)
    }
}

/// Requests a terminal program makes through escape sequences (clipboard, links): they are
/// queued, never executed, until the user clicks and sees the content (Plan/macos-und-git.md).
public enum TerminalRequest: Sendable, Equatable {
    case copyToClipboard(String)
    case openLink(URL)

    /// Links open only for http and https, after the user saw the address.
    public static func link(_ text: String) -> TerminalRequest? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return .openLink(url)
    }

    public var prompt: String {
        switch self {
        case .copyToClipboard(let text): "Das Programm im Terminal möchte \(text.count) Zeichen in die Zwischenablage kopieren."
        case .openLink(let url): "Link öffnen: \(url.absoluteString)"
        }
    }
}
