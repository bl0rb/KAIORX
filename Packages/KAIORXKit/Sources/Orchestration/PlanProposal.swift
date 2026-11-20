import Domain
import Foundation

/// A planner's proposal (ADR 0005 §1): the last ```json block of its answer, read with the same
/// fence rules as a review report, mapped to a `PlanDraft` that then goes through the validator.
public enum PlanProposal {
    public enum ParseError: Error, Equatable, Sendable {
        case noReadableBlock
        case tasksNotAList
        /// Entry index and the field that is missing or of the wrong type.
        case invalidTask(Int, String)
    }

    public static func parse(_ text: String) throws(ParseError) -> PlanDraft {
        guard let object = ReviewReport.jsonObject(in: text) else { throw .noReadableBlock }
        guard let entries = object["tasks"] as? [Any] else { throw .tasksNotAList }
        var tasks: [PlanTaskDraft] = []
        for (index, item) in entries.enumerated() {
            guard let entry = item as? [String: Any] else { throw .invalidTask(index, "entry") }
            guard let key = entry["key"] as? String, !key.isEmpty else { throw .invalidTask(index, "key") }
            guard let title = entry["title"] as? String else { throw .invalidTask(index, "title") }
            func strings(_ name: String) throws(ParseError) -> [String]? {
                guard let value = entry[name], !(value is NSNull) else { return nil }
                guard let list = value as? [String] else { throw .invalidTask(index, name) }
                return list
            }
            // A present field must have the right type; only a missing or null one is defaulted.
            func text(_ name: String) throws(ParseError) -> String? {
                guard let value = entry[name], !(value is NSNull) else { return nil }
                guard let string = value as? String else { throw .invalidTask(index, name) }
                return string
            }
            let difficulty: [String: Any]
            switch entry["difficulty"] {
            case nil, is NSNull: difficulty = [:]
            case let object as [String: Any]: difficulty = object
            default: throw .invalidTask(index, "difficulty")
            }
            func flag(_ name: String) throws(ParseError) -> Bool? {
                guard let value = difficulty[name], !(value is NSNull) else { return nil }
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw .invalidTask(index, name) }
                return number.boolValue
            }
            var risk = PlanTaskRisk.normal
            if let stated = try text("risk") {
                guard let known = PlanTaskRisk(rawValue: stated) else { throw .invalidTask(index, "risk") }
                risk = known
            }
            tasks.append(PlanTaskDraft(
                key: key, title: title, goal: try text("goal") ?? "", criteria: try strings("criteria") ?? [],
                readPaths: try strings("readPaths") ?? [], writePaths: try strings("writePaths"),
                predecessors: try strings("predecessors") ?? [], parent: try text("parent"), risk: risk,
                difficulty: DifficultyEvidence(
                    multipleModules: try flag("multipleModules"), moreThanThreeFiles: try flag("moreThanThreeFiles"),
                    unclearApproach: try flag("unclearApproach"), noReproducibleTest: try flag("noReproducibleTest")
                ),
                testProfile: try text("testProfile")
            ))
        }
        return PlanDraft(tasks: tasks)
    }
}
