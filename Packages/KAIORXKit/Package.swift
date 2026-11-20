// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KAIORXKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KAIORXKit", targets: ["Domain", "Storage", "Providers", "Orchestration", "ProcessHost", "Workspace", "Memory", "Workbench"]),
        .executable(name: "kaiorx-dev", targets: ["kaiorx-dev"]),
    ],
    targets: [
        // Values, IDs, commands, events and state machines. No SQLite, SwiftUI or vendor wire formats.
        .target(name: "Domain"),
        // Pure memory logic (ADR 0006): chunks, query terms, selection, secret scan, rendering.
        .target(name: "Memory", dependencies: ["Domain"]),
        // Single-writer SQLite store on the system SQLite3 library (ADR 0001).
        .target(
            name: "Storage",
            dependencies: ["Domain", "Memory"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Adapter contract, the deterministic fake, and the Claude Code and Codex adapters.
        .target(name: "Providers", dependencies: ["Domain", "ProcessHost"]),
        // Child processes: own process group, explicit environment, bounded output, stop/drain,
        // optional sandbox confinement (ADR 0002).
        .target(name: "ProcessHost"),
        // Host Git: worktrees per attempt, sealed results under private refs, test runs.
        .target(name: "Workspace", dependencies: ["ProcessHost"]),
        // Starts attempts, persists their event streams, recovers after restart.
        .target(name: "Orchestration", dependencies: ["Domain", "Storage", "Providers", "ProcessHost", "Workspace", "Memory"]),
        // UI-independent state of the workspace (ADR 0007): projection, labels, decisions, editor
        // documents, diffs, terminal sessions, backup restore, app bootstrap. No SwiftUI/AppKit.
        .target(name: "Workbench", dependencies: ["Domain", "Storage", "Memory", "Providers", "ProcessHost", "Workspace", "Orchestration"]),
        // Development CLI until the Xcode app exists: open projects, start fake runs, list active runs.
        .executableTarget(name: "kaiorx-dev", dependencies: ["Domain", "Storage", "Providers", "Orchestration"]),

        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "StorageTests", dependencies: ["Domain", "Storage"]),
        .testTarget(name: "MemoryTests", dependencies: ["Domain", "Memory"]),
        // Test support: fixture programs that speak the provider protocols, and a JSON Schema checker.
        .target(name: "ProviderFixtures", dependencies: ["Providers"], path: "Tests/ProviderFixtures"),
        .testTarget(name: "ProvidersTests", dependencies: ["Domain", "Providers", "ProcessHost", "ProviderFixtures"], exclude: ["Fixtures"]),
        .testTarget(name: "OrchestrationTests", dependencies: ["Domain", "Storage", "Providers", "Orchestration", "ProcessHost", "Workspace", "ProviderFixtures", "Memory", "Workbench"]),
        .testTarget(name: "ProcessHostTests", dependencies: ["ProcessHost"]),
        .testTarget(name: "WorkspaceTests", dependencies: ["ProcessHost", "Workspace"]),
        .testTarget(name: "WorkbenchTests", dependencies: ["Domain", "Storage", "Memory", "Providers", "ProcessHost", "Workspace", "Orchestration", "Workbench", "ProviderFixtures"]),
    ]
)
