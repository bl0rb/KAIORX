import Foundation
import Workspace

/// One line of a parsed unified diff. Each line carries text and a symbol, and an accessibility
/// label that says what happened (Plan/macos-und-git.md: never color alone).
public struct DiffLine: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case fileHeader, hunk, context, added, removed, noNewline
    }

    public var id: Int
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    /// Display text: control and bidirectional characters escaped.
    public var text: String

    public init(id: Int, kind: Kind, oldLine: Int? = nil, newLine: Int? = nil, text: String) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }

    public var symbol: String {
        switch kind {
        case .added: "plus"
        case .removed: "minus"
        case .hunk: "text.line.first.and.arrowtriangle.forward"
        case .fileHeader: "doc"
        case .context, .noNewline: ""
        }
    }

    public var accessibilityLabel: String {
        switch kind {
        case .added: "Hinzugefügt, Zeile \(newLine ?? 0): \(text)"
        case .removed: "Entfernt, Zeile \(oldLine ?? 0): \(text)"
        case .context: "Unverändert, Zeile \(newLine ?? 0): \(text)"
        case .hunk: "Abschnitt \(text)"
        case .fileHeader: text
        case .noNewline: "Kein Zeilenende am Dateiende"
        }
    }
}

public enum DiffParser {
    /// Parses a unified diff. Lines before the first hunk are file headers.
    public static func parse(_ diff: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var old = 0, new = 0
        var inHunk = false
        // Split on LF bytes, not Characters: "\r\n" is one Character in Swift, and a CRLF file's
        // diff lines would otherwise merge into one row. The CR stays as escaped content.
        for raw in diff.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(String.UnicodeScalarView(raw))
            if line.hasPrefix("@@") {
                inHunk = true
                let (o, n) = hunkStarts(line)
                old = o
                new = n
                result.append(DiffLine(id: result.count, kind: .hunk, text: escape(line)))
                continue
            }
            if line.hasPrefix("diff --git ") {
                inHunk = false
            }
            guard inHunk else {
                if !line.isEmpty { result.append(DiffLine(id: result.count, kind: .fileHeader, text: escape(line))) }
                continue
            }
            switch line.first {
            case "+":
                result.append(DiffLine(id: result.count, kind: .added, newLine: new, text: escape(String(line.dropFirst()))))
                new += 1
            case "-":
                result.append(DiffLine(id: result.count, kind: .removed, oldLine: old, text: escape(String(line.dropFirst()))))
                old += 1
            case "\\":
                result.append(DiffLine(id: result.count, kind: .noNewline, text: escape(line)))
            case " ":
                result.append(DiffLine(id: result.count, kind: .context, oldLine: old, newLine: new, text: escape(String(line.dropFirst()))))
                old += 1
                new += 1
            default:
                // The empty string after the last newline, or anything unexpected: not a diff line.
                if !line.isEmpty { result.append(DiffLine(id: result.count, kind: .fileHeader, text: escape(line))) }
            }
        }
        return result
    }

    /// `@@ -12,3 +14,5 @@` → (12, 14).
    static func hunkStarts(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start("-"), start("+"))
    }

    /// Control characters (C0, DEL, C1), bidirectional overrides and line/paragraph separators
    /// become visible escapes, so a line or path cannot hide, reorder or split text.
    public static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09: out.append("\t")
            case 0x00...0x1F, 0x7F...0x9F: out += String(format: "\\u{%02X}", scalar.value)
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C, 0x2028, 0x2029: out += String(format: "\\u{%04X}", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// A file row of the review screen.
public struct DiffFileRow: Sendable, Equatable, Identifiable {
    public var id: String { file.path + "|" + (file.oldPath ?? "") }
    public var file: DiffFile
    public var label: StatusLabel
    public var displayPath: String
    public var counts: String

    public init(_ file: DiffFile) {
        self.file = file
        let path = DiffParser.escape(file.path)
        switch file.status {
        case .added: label = StatusLabel("Hinzugefügt", "plus.circle", .success)
        case .modified: label = StatusLabel("Geändert", "pencil.circle", .active)
        case .deleted: label = StatusLabel("Gelöscht", "minus.circle", .failure)
        case .renamed: label = StatusLabel("Umbenannt", "arrow.right.circle", .active)
        case .copied: label = StatusLabel("Kopiert", "doc.on.doc", .active)
        case .typeChanged: label = StatusLabel("Typ geändert", "arrow.triangle.2.circlepath", .warning)
        case .unmerged: label = StatusLabel("Nicht zusammengeführt", "exclamationmark.triangle", .warning)
        case .unknown: label = StatusLabel("Unbekannt", "questionmark.circle", .neutral)
        }
        if let old = file.oldPath, let new = file.newPath, old != new {
            displayPath = "\(DiffParser.escape(old)) → \(DiffParser.escape(new))"
        } else {
            displayPath = path
        }
        if file.isSubmodule { counts = "Submodul" }
        else if file.isBinary { counts = "Binär" }
        else if file.isSymlink { counts = "Symbolischer Link" }
        else { counts = "+\(file.added ?? 0) −\(file.deleted ?? 0)" }
    }
}

/// A line diff of two texts (the editor's external change): removed and added lines with numbers.
public enum LineDiff {
    public static func lines(from old: String, to new: String) -> [DiffLine] {
        func split(_ text: String) -> [String] {
            text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        }
        let a = split(old), b = split(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                result.append(DiffLine(id: result.count, kind: .removed, oldLine: i + 1, text: DiffParser.escape(a[i])))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                result.append(DiffLine(id: result.count, kind: .added, newLine: j + 1, text: DiffParser.escape(b[j])))
                j += 1
            } else {
                if i < a.count, j < b.count {
                    result.append(DiffLine(id: result.count, kind: .context, oldLine: i + 1, newLine: j + 1, text: DiffParser.escape(b[j])))
                }
                i += 1
                j += 1
            }
        }
        return result
    }
}
