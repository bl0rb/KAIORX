// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KAIORXKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KAIORXKit", targets: ["Domain", "Storage", "Providers", "Orchestration"]),
        .executable(name: "kaiorx-dev", targets: ["kaiorx-dev"]),
    ],
    targets: [
        // Values, IDs, commands, events and state machines. No SQLite, SwiftUI or vendor wire formats.
        .target(name: "Domain"),
        // Single-writer SQLite store on the system SQLite3 library (ADR 0001).
        .target(
            name: "Storage",
            dependencies: ["Domain"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Adapter contract and the deterministic fake adapter.
        .target(name: "Providers", dependencies: ["Domain"]),
        // Starts attempts, persists their event streams, recovers after restart.
        .target(name: "Orchestration", dependencies: ["Domain", "Storage", "Providers"]),
        // Development CLI until the Xcode app exists: open projects, start fake runs, list active runs.
        .executableTarget(name: "kaiorx-dev", dependencies: ["Domain", "Storage", "Providers", "Orchestration"]),

        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "StorageTests", dependencies: ["Domain", "Storage"]),
        .testTarget(name: "ProvidersTests", dependencies: ["Domain", "Providers"]),
        .testTarget(name: "OrchestrationTests", dependencies: ["Domain", "Storage", "Providers", "Orchestration"]),
    ]
)
