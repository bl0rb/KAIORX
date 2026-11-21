import AppKit
import SwiftUI
import Workbench

@main
struct KAIORXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("KAIORX", id: "main") {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onAppear { delegate.model = model }
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Projekt öffnen …") { model.requestOpenProject() }
                    .keyboardShortcut("o")
                    .disabled(model.phase != .ready)
                Button("Neuer Auftrag …") { if let project = model.selectedProject { model.sheet = .newJob(project) } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.selectedProject == nil)
                Button("Testprofile …") { if let project = model.selectedProject { model.sheet = .testProfiles(project) } }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(model.selectedProject == nil)
            }
            CommandMenu("Lauf") {
                Button("Ausgewählten Lauf abbrechen") { model.cancelSelected() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.selectedCancellable == nil)
            }
        }

        Window("Monitor", id: "monitor") {
            MonitorView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 400)
        }
        .keyboardShortcut("m", modifiers: [.command, .option])

        Window("Editor", id: "editor") {
            EditorWindow()
                .environment(model)
                .frame(minWidth: 640, minHeight: 400)
        }

        Window("Terminal", id: "terminal") {
            TerminalWindow()
                .environment(model)
                .frame(minWidth: 640, minHeight: 360)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Quitting stops running attempts in order, hangs up terminals, closes the store.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = MainActor.assumeIsolated({ self.model }) else { return .terminateNow }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// VoiceOver announcements, already bundled by the model.
enum Accessibility {
    @MainActor static func announce(_ text: String) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
}
