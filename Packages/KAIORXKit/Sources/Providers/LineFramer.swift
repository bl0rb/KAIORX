import Foundation

/// Splits a byte stream into newline-terminated lines (JSONL). Lines may arrive split across
/// reads, including in the middle of a UTF-8 sequence. A line longer than `maxLineBytes` is a
/// protocol error: the framer cannot know where the next frame starts.
public struct LineFramer: Sendable {
    public enum FramingError: Error, Equatable, Sendable {
        case lineTooLong(limit: Int)
        case invalidUTF8
    }

    public let maxLineBytes: Int
    private var buffer = Data()

    public init(maxLineBytes: Int = 8 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends bytes and returns every completed line (without the newline, `\r` trimmed).
    public mutating func append(_ data: Data) throws -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            buffer.removeSubrange(buffer.startIndex...newline)
            guard line.count <= maxLineBytes else { throw FramingError.lineTooLong(limit: maxLineBytes) }
            guard let text = String(data: Data(line), encoding: .utf8) else { throw FramingError.invalidUTF8 }
            if !text.isEmpty { lines.append(text) }
        }
        if buffer.count > maxLineBytes { throw FramingError.lineTooLong(limit: maxLineBytes) }
        return lines
    }

    /// Bytes after the last newline when the stream ends: a frame cut off mid-line.
    public var remainder: Data { buffer }
}
