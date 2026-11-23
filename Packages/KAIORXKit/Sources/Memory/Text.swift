import Domain
import Foundation

/// Text helpers of the memory retriever (ADR 0006 §6). Retriever version: bump on any change
/// that can alter a selection.
public enum Retriever {
    public static let version = 2
    /// Bytes per estimated token.
    public static let bytesPerToken = 4
    public static func tokens(_ byteCount: Int) -> Int { (byteCount + bytesPerToken - 1) / bytesPerToken }
}

public struct TextChunk: Sendable, Equatable {
    public var ordinal: Int
    /// Half-open UTF-8 byte range in the revision body, on character boundaries.
    public var byteFrom: Int
    public var byteTo: Int
    public var text: String
    /// Identifier parts for the FTS `symbols` column.
    public var symbols: String
}

public enum Chunker {
    /// About 250 estimated tokens per chunk.
    public static let maxBytes = 1_000

    /// Splits along paragraphs; a long paragraph splits at line, then word boundaries, then
    /// character boundaries. Offsets index the UTF-8 bytes of `body`.
    public static func chunks(_ body: String) -> [TextChunk] {
        let bytes = Array(body.utf8)
        guard !bytes.isEmpty else { return [] }
        var pieces: [Range<Int>] = []
        var start = 0
        var index = 0
        // Paragraph boundaries: a blank line.
        while index < bytes.count {
            if bytes[index] == 0x0A, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                pieces.append(start..<(index + 2))
                index += 2
                while index < bytes.count, bytes[index] == 0x0A { index += 1 }
                start = index
                continue
            }
            index += 1
        }
        if start < bytes.count { pieces.append(start..<bytes.count) }
        // UTF-8 offsets where a `Character` (grapheme cluster) starts, plus the end.
        var boundaries = Set<Int>()
        var offset = 0
        for character in body {
            boundaries.insert(offset)
            offset += character.utf8.count
        }
        boundaries.insert(bytes.count)
        var merged: [Range<Int>] = []
        for piece in pieces.flatMap({ split($0, bytes, boundaries: boundaries) }) {
            if let last = merged.last, piece.upperBound - last.lowerBound <= maxBytes {
                merged[merged.count - 1] = last.lowerBound..<piece.upperBound
            } else {
                merged.append(piece)
            }
        }
        var result: [TextChunk] = []
        for range in merged {
            let text = String(decoding: bytes[range], as: UTF8.self)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(TextChunk(
                ordinal: result.count, byteFrom: range.lowerBound, byteTo: range.upperBound, text: text, symbols: Identifiers.symbols(in: text)
            ))
        }
        return result
    }

    /// A range longer than `maxBytes`, cut at the last newline, else space, else character
    /// boundary before the limit. Every cut is a `Character` boundary, so neither a UTF-8
    /// sequence nor a grapheme cluster (combining marks, ZWJ sequences) is split; a single
    /// cluster longer than the limit stays whole.
    static func split(_ range: Range<Int>, _ bytes: [UInt8], boundaries: Set<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > maxBytes {
            var cut = start + maxBytes
            if let newline = (start + maxBytes / 2..<cut).last(where: { bytes[$0] == 0x0A }) { cut = newline + 1 }
            else if let space = (start + maxBytes / 2..<cut).last(where: { bytes[$0] == 0x20 }) { cut = space + 1 }
            while cut > start, !boundaries.contains(cut) { cut -= 1 }
            if cut == start {
                cut = start + maxBytes
                while cut < range.upperBound, !boundaries.contains(cut) { cut += 1 }
            }
            result.append(start..<cut)
            start = cut
        }
        if start < range.upperBound { result.append(start..<range.upperBound) }
        return result
    }
}

public enum Identifiers {
    /// `buildCandidate` → `build`, `candidate`; `HTTPServer2` → `http`, `server2`; `snake_case`
    /// → `snake`, `case`. Lowercased.
    public static func split(_ identifier: String) -> [String] {
        var parts: [String] = []
        for piece in identifier.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var current = ""
            let chars = Array(piece)
            for (i, c) in chars.enumerated() {
                let prev = i > 0 ? chars[i - 1] : nil
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                // `sha256Digest` → `sha256`, `digest`: an uppercase letter after a digit also starts a part.
                let boundary = prev.map { p in
                    (c.isUppercase && (p.isLowercase || p.isNumber)) || (c.isUppercase && p.isUppercase && (next?.isLowercase ?? false))
                } ?? false
                if boundary, !current.isEmpty { parts.append(current); current = "" }
                current.append(c)
            }
            if !current.isEmpty { parts.append(current) }
        }
        return parts.map { $0.lowercased() }
    }

    /// Identifier-like words of a text (camelCase, snake_case, dotted) as their parts, unique,
    /// in order of appearance.
    public static func symbols(in text: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for word in words(text) where isIdentifier(word) {
            for part in split(word) where part.count > 1 && seen.insert(part).inserted { result.append(part) }
        }
        return result.joined(separator: " ")
    }

    /// Letters, digits, `_` and `.` runs.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    static func isIdentifier(_ word: String) -> Bool {
        word.contains("_") || word.contains(".") || (word.contains { $0.isUppercase } && word.contains { $0.isLowercase } && !(word.first!.isUppercase && word.dropFirst().allSatisfy { $0.isLowercase }))
    }
}

public enum QueryTerms {
    public static let maxTerms = 12

    static let stopwords: Set<String> = [
        "der", "die", "das", "und", "oder", "ein", "eine", "einen", "ist", "sind", "mit", "für", "von", "zu", "im", "in", "auf", "den",
        "dem", "des", "nicht", "als", "auch", "wird", "werden", "bei", "nach", "aus", "wie", "was", "wenn", "dass", "sich", "es",
        "the", "and", "or", "a", "an", "is", "are", "with", "for", "of", "to", "in", "on", "not", "as", "be", "by", "it", "this",
        "that", "from", "at", "when", "what", "how", "should", "must",
    ]

    /// At most twelve terms (ADR 0006 §5): identifiers from the texts (title, goal, criteria)
    /// and the file names of `paths` (read and write areas) first, then the other words of the
    /// texts, without stopwords and duplicates (case-insensitive), each group in order.
    public static func extract(texts: [String], paths: [String] = []) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
            let key = trimmed.lowercased()
            guard trimmed.count > 1, !stopwords.contains(key), seen.insert(key).inserted, result.count < maxTerms else { return }
            result.append(trimmed)
        }
        let words = texts.flatMap(Identifiers.words)
        for word in words where Identifiers.isIdentifier(word) { add(word) }
        for path in paths {
            if let name = path.split(separator: "/").last { add(String(name)) }
        }
        for word in words { add(word) }
        return result
    }

    /// An FTS5 query of literal terms joined by `OR`: each term (and each part of an identifier)
    /// is a quoted string, so no FTS operator or column filter comes from user text.
    public static func ftsQuery(_ terms: [String]) -> String? {
        var literals: [String] = []
        var seen = Set<String>()
        for term in terms {
            var forms = [term.lowercased()]
            if Identifiers.isIdentifier(term) { forms += Identifiers.split(term) }
            for form in forms {
                // A quoted FTS5 string is literal (only `"` is special and is doubled); the
                // tokenizer turns `6.2` into the phrase `6 2`, which matches the indexed text.
                guard form.count > 1, form.contains(where: { $0.isLetter || $0.isNumber }), seen.insert(form).inserted else { continue }
                literals.append("\"" + form.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            }
        }
        return literals.isEmpty ? nil : literals.joined(separator: " OR ")
    }
}
