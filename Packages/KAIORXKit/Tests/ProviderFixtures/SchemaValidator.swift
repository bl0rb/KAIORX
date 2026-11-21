import Foundation
import Providers

/// Minimal JSON Schema (draft-07 subset) checker for the contract tests: `$ref` to local
/// definitions, `type`, `enum`, `const`, `required`, `properties`, `additionalProperties`,
/// `items`, `oneOf` (exactly one), `anyOf`, `allOf`. Formats and numeric bounds are ignored.
public struct SchemaValidator {
    let root: [String: Any]

    public init(file: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.root = root
    }

    /// Problems with `value`, empty if it conforms.
    public func errors(_ value: JSONValue) -> [String] {
        check(value, against: root, path: "$")
    }

    /// For responses: the schema of the result of `method` within `ClientRequest.json` naming
    /// convention is file-based, so callers pick the response file directly.
    private func check(_ value: JSONValue, against schema: Any, path: String) -> [String] {
        if let flag = schema as? Bool { return flag ? [] : ["\(path): schema false"] }
        guard let schema = schema as? [String: Any] else { return [] }
        if let ref = schema["$ref"] as? String {
            let name = ref.replacingOccurrences(of: "#/definitions/", with: "")
            guard let definitions = root["definitions"] as? [String: Any], let target = definitions[name] else {
                return ["\(path): unresolved \(ref)"]
            }
            return check(value, against: target, path: path)
        }
        var problems: [String] = []
        if let types = schema["type"] {
            let allowed = (types as? [String]) ?? [types as? String].compactMap { $0 }
            if !allowed.contains(where: { Self.matches(value, type: $0) }) {
                return ["\(path): expected \(allowed), got \(value)"]
            }
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { Self.equal(value, $0) }) {
            problems.append("\(path): \(value) not in \(options)")
        }
        if let constant = schema["const"], !Self.equal(value, constant) {
            problems.append("\(path): \(value) is not \(constant)")
        }
        if let all = schema["allOf"] as? [Any] {
            for part in all { problems += check(value, against: part, path: path) }
        }
        if let any = schema["anyOf"] as? [Any], !any.contains(where: { check(value, against: $0, path: path).isEmpty }) {
            problems.append("\(path): matches none of anyOf")
        }
        if let one = schema["oneOf"] as? [Any] {
            let matching = one.filter { check(value, against: $0, path: path).isEmpty }.count
            if matching != 1 {
                let detail = matching == 0 ? Self.closestMismatch(value, one, self, path) : "\(matching) alternatives match"
                problems.append("\(path): oneOf: \(detail)")
            }
        }
        if case .object(let object) = value {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                problems.append("\(path): missing \(key)")
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, child) in object {
                if let property = properties[key] {
                    problems += check(child, against: property, path: "\(path).\(key)")
                } else if let additional = schema["additionalProperties"] {
                    problems += check(child, against: additional, path: "\(path).\(key)")
                }
            }
        }
        if case .array(let items) = value, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() { problems += check(item, against: itemSchema, path: "\(path)[\(index)]") }
        }
        return problems
    }

    private static func closestMismatch(_ value: JSONValue, _ options: [Any], _ validator: SchemaValidator, _ path: String) -> String {
        // The alternative whose type tag matches, if any, explains the problem best.
        if let tag = value["type"]?.string ?? value["method"]?.string {
            for option in options {
                guard let option = option as? [String: Any], let properties = option["properties"] as? [String: Any] else { continue }
                let tagSchema = (properties["type"] ?? properties["method"]) as? [String: Any]
                if let values = tagSchema?["enum"] as? [String], values.contains(tag) {
                    return validator.check(value, against: option, path: path).joined(separator: "; ")
                }
            }
        }
        return "no alternative matches"
    }

    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object): true
        case ("integer", .int): true
        case ("integer", .double(let number)): number.rounded() == number
        case ("number", .int), ("number", .double): true
        default: false
        }
    }

    static func equal(_ value: JSONValue, _ other: Any) -> Bool {
        switch value {
        case .string(let text): (other as? String) == text
        case .bool(let flag): (other as? Bool) == flag && !(other is NSNumber && CFGetTypeID(other as CFTypeRef) != CFBooleanGetTypeID())
        case .int(let number): (other as? NSNumber)?.int64Value == number
        case .null: other is NSNull
        default: false
        }
    }
}
