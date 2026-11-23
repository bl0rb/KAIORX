import Foundation

/// Package F (ADR 0005): a job's plan as a DAG of tasks, its validation and the values the
/// scheduler and router derive from it. Pure values; persistence lives in Storage.

public enum PlanTaskRisk: String, Sendable, Codable, CaseIterable, Hashable {
    case normal
    /// Security, migration, data loss or authentication: at least `standard`, and an extra
    /// human review before integration.
    case sensitive
}

/// Capability tiers the router maps to verified model profiles per provider.
public enum CapabilityTier: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
    case fast, standard, intensive

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    var rank: Int { switch self { case .fast: 0; case .standard: 1; case .intensive: 2 } }

    /// One tier up, or nil at the top.
    public var next: CapabilityTier? { switch self { case .fast: .standard; case .standard: .intensive; case .intensive: nil } }
}

/// The planner's evidence for a task's difficulty. `nil` means not stated: it adds no point
/// but marks the estimate as uncertain.
public struct DifficultyEvidence: Sendable, Codable, Equatable, Hashable {
    public var multipleModules: Bool?
    public var moreThanThreeFiles: Bool?
    public var unclearApproach: Bool?
    public var noReproducibleTest: Bool?

    public init(multipleModules: Bool? = nil, moreThanThreeFiles: Bool? = nil, unclearApproach: Bool? = nil, noReproducibleTest: Bool? = nil) {
        self.multipleModules = multipleModules
        self.moreThanThreeFiles = moreThanThreeFiles
        self.unclearApproach = unclearApproach
        self.noReproducibleTest = noReproducibleTest
    }

    var answers: [Bool?] { [multipleModules, moreThanThreeFiles, unclearApproach, noReproducibleTest] }
    public var points: Int { answers.filter { $0 == true }.count }
    public var isUncertain: Bool { answers.contains { $0 == nil } }

    /// 0–1 fast, 2 standard, 3–4 intensive; a sensitive task is at least standard.
    public func tier(risk: PlanTaskRisk) -> CapabilityTier {
        let byPoints: CapabilityTier = switch points { case 0...1: .fast; case 2: .standard; default: .intensive }
        return risk == .sensitive ? max(byPoints, .standard) : byPoints
    }
}

/// One task of a plan draft, as the user edits it or a planner proposes it.
public struct PlanTaskDraft: Sendable, Codable, Equatable, Hashable {
    /// Stable within the job: the same key in a later revision is the same task.
    public var key: String
    public var title: String
    public var goal: String
    /// Checkable acceptance criteria; at least one non-empty for an executable task.
    public var criteria: [String]
    public var readPaths: [String]
    /// Relative path prefixes the task may write. `nil`: unknown, which means the whole project.
    public var writePaths: [String]?
    public var predecessors: [String]
    /// Grouping only: tasks with children are not executed themselves.
    public var parent: String?
    public var risk: PlanTaskRisk
    public var difficulty: DifficultyEvidence
    /// Name of a confirmed test profile of the project, if the planner named one.
    public var testProfile: String?

    public init(
        key: String, title: String, goal: String = "", criteria: [String], readPaths: [String] = [], writePaths: [String]? = nil,
        predecessors: [String] = [], parent: String? = nil, risk: PlanTaskRisk = .normal,
        difficulty: DifficultyEvidence = DifficultyEvidence(), testProfile: String? = nil
    ) {
        self.key = key
        self.title = title
        self.goal = goal
        self.criteria = criteria
        self.readPaths = readPaths
        self.writePaths = writePaths
        self.predecessors = predecessors
        self.parent = parent
        self.risk = risk
        self.difficulty = difficulty
        self.testProfile = testProfile
    }
}

public struct PlanDraft: Sendable, Codable, Equatable, Hashable {
    public var tasks: [PlanTaskDraft]

    public init(tasks: [PlanTaskDraft]) { self.tasks = tasks }

    /// Over the canonical JSON: the same plan always has the same digest.
    public func digest() throws -> String { Canonical.sha256Hex(try Canonical.encode(self)) }
}

/// The part of the repository a task may write: everything, or a set of normalized path prefixes.
public enum WriteArea: Sendable, Codable, Equatable, Hashable {
    case wholeProject
    case paths(Set<String>)

    /// Shared manifest and lock files: tasks declaring any of them run one after another.
    public static let manifestNames: Set<String> = [
        "Package.swift", "Package.resolved", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "Podfile", "Podfile.lock", "Cartfile", "Cartfile.resolved", "Gemfile", "Gemfile.lock", "Cargo.toml", "Cargo.lock",
        "go.mod", "go.sum", "pyproject.toml", "poetry.lock", "requirements.txt", "project.pbxproj",
    ]
    static let manifestToken = "\u{0}manifests"
    static let foldedManifestNames = Set(manifestNames.map(fold))

    /// Normalizes declared prefixes. `nil`, an empty list, `.` or the empty path mean the whole
    /// project. Throws for absolute paths, `..`, `.git` and other unresolvable entries.
    public static func resolve(_ declared: [String]?) throws(PlanIssue) -> WriteArea {
        guard let declared, !declared.isEmpty else { return .wholeProject }
        var result = Set<String>()
        for raw in declared {
            guard let path = normalize(raw) else { throw PlanIssue.unresolvablePath(raw) }
            if path.isEmpty { return .wholeProject }
            result.insert(path)
            let components = path.split(separator: "/")
            let folded = fold(path)
            if let last = folded.split(separator: "/").last,
               foldedManifestNames.contains(String(last)) || last.hasSuffix(".xcodeproj") || folded.contains(".xcodeproj/") {
                result.insert(manifestToken)
            }
        }
        return .paths(result)
    }

    /// Relative, slash-separated, without `.` segments or trailing slash. `nil` if the path
    /// leaves the repository, is absolute, names `.git`, or contains control characters.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\\" }) else { return nil }
        var parts: [Substring] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            if part.lowercased() == ".git" { return nil }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// Whether two areas can touch the same file: one prefix contains the other (by whole path
    /// components), both declare manifest files, or either is the whole project.
    public func overlaps(_ other: WriteArea) -> Bool {
        switch (self, other) {
        case (.wholeProject, _), (_, .wholeProject): return true
        case (.paths(let a), .paths(let b)):
            for x in a { for y in b where Self.contains(x, y) || Self.contains(y, x) { return true } }
            return false
        }
    }

    /// Whether `area` lies inside the given roots (consent scope). Roots use the same notation;
    /// an empty or `nil` root list allows nothing, a root of `""` allows everything.
    public func isCovered(by roots: [String]) -> Bool {
        let normalized = roots.compactMap(Self.normalize)
        if normalized.contains("") { return true }
        switch self {
        case .wholeProject: return false
        case .paths(let paths):
            return paths.filter { $0 != Self.manifestToken }.allSatisfy { path in normalized.contains { Self.contains($0, path) } }
        }
    }

    /// By whole components, after NFC and without letter case (APFS is case-insensitive), so
    /// `Docs` and `docs` are the same area.
    static func contains(_ prefix: String, _ path: String) -> Bool {
        let p = fold(prefix), q = fold(path)
        return p.isEmpty || p == q || q.hasPrefix(p + "/")
    }

    static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}

public enum PlanIssue: Error, Sendable, Equatable, Hashable, Codable {
    case emptyPlan
    case duplicateKey(String)
    case emptyKey
    case unknownPredecessor(task: String, predecessor: String)
    case unknownParent(task: String, parent: String)
    case selfDependency(String)
    /// The keys along the cycle, first key repeated at the end.
    case cycle([String])
    case unresolvablePath(String)
    case noCriterion(String)
    /// More than `PlanLimits.maxLeaves` executable tasks or deeper than `PlanLimits.maxDepth`:
    /// shown for revision, not accepted.
    case oversized(leaves: Int, depth: Int)
    /// A predecessor ended without integration in the current state of the job.
    case unreachable(task: String, predecessor: String)
}

public enum PlanLimits {
    public static let maxLeaves = 12
    public static let maxDepth = 3
}

/// An executable task of a valid plan.
public struct PlannedTask: Sendable, Codable, Equatable, Hashable {
    public var key: String
    public var draft: PlanTaskDraft
    public var writeArea: WriteArea
    /// Leaf keys this task waits for (through parents expanded).
    public var predecessors: Set<String>
    public var tier: CapabilityTier
    public var uncertainDifficulty: Bool
}

public struct ValidatedPlan: Sendable, Equatable {
    public var draft: PlanDraft
    public var digest: String
    /// Executable tasks (leaves), in draft order.
    public var tasks: [PlannedTask]

    public func task(_ key: String) -> PlannedTask? { tasks.first { $0.key == key } }

    /// Longest chain of not yet finished tasks starting at each task (itself included), for
    /// the scheduler's critical-path order. Finished tasks count zero.
    public func remainingPathLengths(finished: Set<String>) -> [String: Int] {
        var successors: [String: [String]] = [:]
        for task in tasks { for predecessor in task.predecessors { successors[predecessor, default: []].append(task.key) } }
        var memo: [String: Int] = [:]
        func length(_ key: String) -> Int {
            if let known = memo[key] { return known }
            let own = finished.contains(key) ? 0 : 1
            let value = own + ((successors[key] ?? []).map(length).max() ?? 0)
            memo[key] = value
            return value
        }
        for task in tasks { _ = length(task.key) }
        return memo
    }
}

public enum PlanValidator {
    /// Validates a draft. `ended` names keys of existing tasks that ended without integration;
    /// depending on them makes completion unreachable. Returns every issue found, or the plan.
    public static func validate(_ draft: PlanDraft, ended: Set<String> = []) -> Result<ValidatedPlan, PlanIssues> {
        var issues: [PlanIssue] = []
        if draft.tasks.isEmpty { return .failure(PlanIssues([.emptyPlan])) }
        var byKey: [String: PlanTaskDraft] = [:]
        for task in draft.tasks {
            if task.key.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyKey); continue }
            if byKey[task.key] != nil { issues.append(.duplicateKey(task.key)) } else { byKey[task.key] = task }
        }
        for task in draft.tasks where byKey[task.key] == task {
            if let parent = task.parent, byKey[parent] == nil { issues.append(.unknownParent(task: task.key, parent: parent)) }
            for predecessor in task.predecessors {
                if predecessor == task.key { issues.append(.selfDependency(task.key)) }
                else if byKey[predecessor] == nil { issues.append(.unknownPredecessor(task: task.key, predecessor: predecessor)) }
            }
        }
        guard issues.isEmpty else { return .failure(PlanIssues(issues)) }

        // Parent chains: a parent cycle is a cycle; depth counts levels from the roots.
        var children: [String: [String]] = [:]
        for task in draft.tasks { if let parent = task.parent { children[parent, default: []].append(task.key) } }
        var depth = 0
        for task in draft.tasks {
            var chain = [task.key]
            var current = task.parent
            while let parent = current {
                if chain.contains(parent) { return .failure(PlanIssues([.cycle(chain.reversed() + [parent])])) }
                chain.append(parent)
                current = byKey[parent]?.parent
            }
            depth = max(depth, chain.count)
        }
        func leaves(of key: String) -> [String] {
            guard let kids = children[key], !kids.isEmpty else { return [key] }
            return kids.flatMap(leaves)
        }
        func ancestorsOrSelf(_ key: String) -> [String] {
            var result = [key]
            var current = byKey[key]?.parent
            while let parent = current { result.append(parent); current = byKey[parent]?.parent }
            return result
        }
        let leafKeys = draft.tasks.map(\.key).filter { (children[$0] ?? []).isEmpty }
        if leafKeys.count > PlanLimits.maxLeaves || depth > PlanLimits.maxDepth {
            issues.append(.oversized(leaves: leafKeys.count, depth: depth))
        }

        var planned: [PlannedTask] = []
        for key in leafKeys {
            let task = byKey[key]!
            var predecessors = Set<String>()
            for level in ancestorsOrSelf(key) {
                for predecessor in byKey[level]!.predecessors { predecessors.formUnion(leaves(of: predecessor)) }
            }
            if predecessors.contains(key) { issues.append(.cycle([key, key])) }
            if task.criteria.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { issues.append(.noCriterion(key)) }
            for predecessor in predecessors.sorted() where ended.contains(predecessor) {
                issues.append(.unreachable(task: key, predecessor: predecessor))
            }
            let area: WriteArea
            do { area = try WriteArea.resolve(task.writePaths) } catch { issues.append(error); area = .wholeProject }
            for path in task.readPaths where WriteArea.normalize(path) == nil { issues.append(.unresolvablePath(path)) }
            planned.append(PlannedTask(
                key: key, draft: task, writeArea: area, predecessors: predecessors,
                tier: task.difficulty.tier(risk: task.risk), uncertainDifficulty: task.difficulty.isUncertain
            ))
        }
        if let cycle = findCycle(planned) { issues.append(.cycle(cycle)) }
        guard issues.isEmpty else { return .failure(PlanIssues(issues)) }
        let digest: String
        do { digest = try draft.digest() } catch { return .failure(PlanIssues([.emptyPlan])) }
        return .success(ValidatedPlan(draft: draft, digest: digest, tasks: planned))
    }

    /// A cycle among leaves (by expanded predecessors), as keys with the first repeated.
    static func findCycle(_ tasks: [PlannedTask]) -> [String]? {
        let byKey = Dictionary(uniqueKeysWithValues: tasks.map { ($0.key, $0) })
        var state: [String: Int] = [:] // 1 visiting, 2 done
        var stack: [String] = []
        func visit(_ key: String) -> [String]? {
            if state[key] == 2 { return nil }
            if state[key] == 1 {
                let start = stack.firstIndex(of: key)!
                return Array(stack[start...]) + [key]
            }
            state[key] = 1
            stack.append(key)
            for predecessor in (byKey[key]?.predecessors ?? []).sorted() {
                if let cycle = visit(predecessor) { return cycle }
            }
            stack.removeLast()
            state[key] = 2
            return nil
        }
        for task in tasks { if let cycle = visit(task.key) { return cycle.reversed() } }
        return nil
    }
}

/// All issues of a refused draft.
public struct PlanIssues: Error, Sendable, Equatable {
    public var issues: [PlanIssue]
    public init(_ issues: [PlanIssue]) { self.issues = issues }
}

/// What a new revision changes against the current one.
public struct PlanDiff: Sendable, Equatable, Codable {
    public var addedTasks: [String] = []
    public var removedTasks: [String] = []
    public var changedTasks: [String] = []
    public var addedEdges: [PlanEdge] = []
    public var removedEdges: [PlanEdge] = []

    public init(from old: ValidatedPlan?, to new: ValidatedPlan) {
        let oldTasks = Dictionary(uniqueKeysWithValues: (old?.tasks ?? []).map { ($0.key, $0) })
        let newTasks = Dictionary(uniqueKeysWithValues: new.tasks.map { ($0.key, $0) })
        addedTasks = new.tasks.map(\.key).filter { oldTasks[$0] == nil }
        removedTasks = (old?.tasks ?? []).map(\.key).filter { newTasks[$0] == nil }
        changedTasks = new.tasks.compactMap { task in
            guard let before = oldTasks[task.key] else { return nil }
            var a = before.draft, b = task.draft
            a.predecessors = []; b.predecessors = []; a.parent = nil; b.parent = nil
            return a == b ? nil : task.key
        }
        let oldEdges = Set((old?.tasks ?? []).flatMap { t in t.predecessors.map { PlanEdge(predecessor: $0, successor: t.key) } })
        let newEdges = Set(new.tasks.flatMap { t in t.predecessors.map { PlanEdge(predecessor: $0, successor: t.key) } })
        addedEdges = newEdges.subtracting(oldEdges).sorted()
        removedEdges = oldEdges.subtracting(newEdges).sorted()
    }

    public var isEmpty: Bool {
        addedTasks.isEmpty && removedTasks.isEmpty && changedTasks.isEmpty && addedEdges.isEmpty && removedEdges.isEmpty
    }
}

public struct PlanEdge: Sendable, Codable, Hashable, Comparable {
    public var predecessor: String
    public var successor: String

    public init(predecessor: String, successor: String) {
        self.predecessor = predecessor
        self.successor = successor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.predecessor, lhs.successor) < (rhs.predecessor, rhs.successor)
    }
}
