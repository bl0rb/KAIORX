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
            func flag(_ name: String) -> Bool? { (entry["difficulty"] as? [String: Any])?[name] as? Bool }
            let risk = (entry["risk"] as? String).flatMap(PlanTaskRisk.init(rawValue:)) ?? .normal
            tasks.append(PlanTaskDraft(
                key: key, title: title, goal: entry["goal"] as? String ?? "", criteria: try strings("criteria") ?? [],
                readPaths: try strings("readPaths") ?? [], writePaths: try strings("writePaths"),
                predecessors: try strings("predecessors") ?? [], parent: entry["parent"] as? String, risk: risk,
                difficulty: DifficultyEvidence(
                    multipleModules: flag("multipleModules"), moreThanThreeFiles: flag("moreThanThreeFiles"),
                    unclearApproach: flag("unclearApproach"), noReproducibleTest: flag("noReproducibleTest")
                ),
                testProfile: entry["testProfile"] as? String
            ))
        }
        return PlanDraft(tasks: tasks)
    }
}
