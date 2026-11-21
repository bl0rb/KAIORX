import AppKit
import Domain
import ProcessHost
import Storage
import SwiftTerm
import SwiftUI
import Workbench

// MARK: Monitor

struct MonitorView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @State private var selected: AttemptID?
    @State private var timeline = Timeline()
    @State private var loadedAttempt: AttemptID?
    @State private var loadingOlder = false

    var body: some View {
        @Bindable var model = model
        let rows = MonitorRow.rows(model.state, filter: model.monitorFilter, now: Int64(Date().timeIntervalSince1970 * 1000))
        VStack(spacing: 0) {
            HStack {
                Picker("Zeigen", selection: $model.monitorFilter.states) {
                    Text("Offen").tag(MonitorFilter.StateGroup.open)
                    Text("Beendet").tag(MonitorFilter.StateGroup.finished)
                    Text("Alle").tag(MonitorFilter.StateGroup.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                TextField("Suchen", text: $model.monitorFilter.text).textFieldStyle(.roundedBorder)
            }
            .padding(8)
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("Keine Läufe", systemImage: "waveform.path.ecg")
                } description: {
                    Text("Lege einen Auftrag an, um die erste Aufgabe zu starten.")
                } actions: {
                    Button("Neuer Auftrag …") { if let project = model.selectedProject { model.sheet = .newJob(project) } }
                        .disabled(model.selectedProject == nil)
                }
            } else {
                HSplitView {
                    Table(rows, selection: $selected) {
                        TableColumn("Aufgabe") { Text($0.taskTitle) }
                        TableColumn("Anbieter") { Text("\($0.provider) · \($0.model)") }
                        TableColumn("Rolle") { Text($0.role) }
                        TableColumn("Status") { StatusBadge(label: $0.status) }
                        TableColumn("Laufzeit") { Text($0.runtime ?? "–") }
                        TableColumn("") { row in
                            if row.canCancel { Button("Abbrechen") { model.perform { try await $0.cancel(row.id) } } }
                        }
                    }
                    .frame(minWidth: 420)
                    TimelineView(timeline: timeline, loadingOlder: loadingOlder) { Task { await loadOlder() } }
                        .frame(minWidth: 260)
                }
            }
        }
        .accessibilityIdentifier("monitor")
        // One loader per selection and activity change; a new one cancels the old, and a page
        // is only appended while it still belongs to the selected attempt.
        .task(id: TimelineKey(attempt: selected, activity: selected.flatMap { model.state.lastActivity[$0] })) { await load() }
    }

    struct TimelineKey: Hashable {
        var attempt: AttemptID?
        var activity: Int64?
    }

    func load() async {
        guard let attempt = selected, let store = model.services?.store else {
            timeline = Timeline()
            loadedAttempt = nil
            return
        }
        if loadedAttempt != attempt {
            timeline = Timeline()
            loadedAttempt = attempt
        }
        // Opening reads only the newest pages; older ones come with "Ältere Einträge laden".
        if timeline.lastOrdinal == 0 {
            guard let opened = try? await TimelinePaging.open(attempt, store: store) else { return }
            guard !Task.isCancelled, selected == attempt, loadedAttempt == attempt, timeline.lastOrdinal == 0 else { return }
            timeline = opened.timeline
        }
        // Newer pages to the end (the timeline itself stays bounded).
        while !Task.isCancelled {
            let page = (try? await store.attemptEvents(attempt, afterOrdinal: timeline.lastOrdinal, limit: TimelinePaging.pageSize)) ?? []
            guard !Task.isCancelled, selected == attempt, loadedAttempt == attempt else { return }
            timeline.append(page)
            if page.count < TimelinePaging.pageSize { return }
        }
    }

    /// One older page in front of the shown rows.
    func loadOlder() async {
        guard let attempt = loadedAttempt, selected == attempt, timeline.canLoadOlder, !loadingOlder,
              let store = model.services?.store else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        // A failed read keeps the control (an empty page would mean nothing older is left).
        guard let page = try? await store.latestAttemptEvents(attempt, beforeOrdinal: timeline.firstOrdinal, limit: TimelinePaging.pageSize),
              selected == attempt, loadedAttempt == attempt else { return }
        timeline.prepend(page)
    }
}

struct TimelineView: View {
    let timeline: Timeline
    var loadingOlder = false
    var loadOlder: () -> Void = {}
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Verlauf").font(.headline)
                if timeline.droppedRows > 0 { Text("(\(timeline.droppedRows) ältere ausgeblendet)").foregroundStyle(.secondary) }
                Spacer()
                Button(copied ? "Kopiert" : "Redigiert kopieren") {
                    let text = timeline.rows.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LogRedactor.redact(text), forType: .string)
                    copied = true
                }
            }
            .padding(6)
            List {
                // Only the newest pages are read on selection; older ones on request.
                if timeline.canLoadOlder {
                    Button(loadingOlder ? "Lädt …" : "Ältere Einträge laden", action: loadOlder)
                        .disabled(loadingOlder)
                        .accessibilityIdentifier("loadOlderEvents")
                        .accessibilityHint("Zeigt die vorherigen \(TimelinePaging.pageSize) Ereignisse dieses Laufs über den bisherigen Einträgen.")
                }
                ForEach(timeline.rows) { row in
                    VStack(alignment: .leading) {
                        Text(verbatim: row.text + (row.truncated ? " …" : "")).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: Editor

/// NSTextView with native find, selection and undo; the model owns identity and saving.
struct TextEditorView: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.setAccessibilityIdentifier("editorText")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.isEditable = editable
        if view.string != text {
            // Another document or a reload: the old undo history must not apply to the new text.
            view.string = text
            view.undoManager?.removeAllActions()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextEditorView
        init(_ parent: TextEditorView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

struct EditorWindow: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @State private var document: EditorDocument?
    @State private var path = ""
    @State private var message: String?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Pfad im Projekt (z. B. README.md)", text: $path).textFieldStyle(.roundedBorder).accessibilityIdentifier("editorPath")
                Button("Öffnen") { if document?.isDirty == true { confirmDiscard = true } else { open() } }
                    .disabled(model.selectedProject == nil || path.isEmpty)
                    .confirmationDialog("Ungesicherte Änderungen verwerfen?", isPresented: $confirmDiscard) {
                        Button("Verwerfen und öffnen", role: .destructive) { open() }
                        Button("Abbrechen", role: .cancel) {}
                    } message: {
                        Text("Die Änderungen an \(document?.title ?? "der Datei") gehen verloren.")
                    }
                Button("Sichern") { save() }.keyboardShortcut("s").disabled(!(document?.access.isWritable ?? false) || !(document?.isDirty ?? false))
            }
            .padding(8)
            if let document {
                HStack {
                    Text("\(document.root) · \(document.id.path)").font(.caption).foregroundStyle(.secondary)
                    if case .readOnly(let reason) = document.access { Label(reason.text, systemImage: "lock").font(.caption) }
                    if document.isDirty { Text("Geändert").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                }
                .padding(.horizontal, 8)
                if document.conflict != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Die Datei wurde außerhalb geändert. Unten: Fassung auf der Platte (−) gegen deine (+).", systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("Fassung von der Platte laden") { reload() }
                            Button("Meine Fassung behalten") { keepMine() }
                        }
                        DiffLinesView(lines: document.conflictDiff).frame(maxHeight: 220)
                    }
                    .padding(6)
                    .background(.yellow.opacity(0.2))
                    .accessibilityIdentifier("editorConflict")
                }
                TextEditorView(text: Binding(get: { self.document?.text ?? "" }, set: { self.document?.text = $0 }), editable: document.access.isWritable)
            } else {
                ContentUnavailableView("Keine Datei geöffnet", systemImage: "doc.text", description: Text("Öffne eine Datei aus dem Checkout des gewählten Projekts."))
            }
            if let message { Text(message).font(.caption).padding(4) }
        }
        .navigationTitle(document?.title ?? "Editor")
    }

    func open() {
        guard let project = model.selectedProject, let root = model.selectedProjectRoot else { return }
        do { document = try EditorDocument.open(.checkout(project: project, path: path), root: root); message = nil }
        catch { message = AppModel.describe(error) }
    }

    func save() {
        guard var current = document else { return }
        do {
            switch try current.save() {
            case .saved: message = "Gesichert."
            case .externalChange: message = "Nicht gesichert: Die Datei wurde außerhalb geändert."
            case .refused(let reason): message = reason.text
            }
            document = current
        } catch { message = AppModel.describe(error) }
    }

    func reload() {
        guard var current = document else { return }
        try? current.reloadFromDisk()
        document = current
    }

    /// Overwrites exactly the disk version shown above, never a newer one.
    func keepMine() {
        guard var current = document else { return }
        current.keepMine()
        document = current
    }
}

extension AppModel {
    var selectedProjectRoot: String? { selectedProject.flatMap { state.projects[$0]?.rootLocator } }
}

// MARK: Terminal

/// SwiftTerm's view fed from a PTY process in ProcessHost. Escape-sequence requests (clipboard,
/// links) only queue a prompt; the user acts on it.
struct TerminalWindow: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @State private var session: TerminalBridge?
    @State private var starting = false
    @State private var visible = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.map { "Arbeitsordner: \($0.folder)" } ?? "Kein Terminal").font(.caption)
                Spacer()
                Button(session == nil ? "Terminal starten" : "Neu starten") { start() }.disabled(model.selectedProjectRoot == nil || starting)
            }
            .padding(6)
            ForEach(Array(model.pendingTerminalRequests.enumerated()), id: \.offset) { index, request in
                HStack {
                    Text(request.prompt)
                    Button("Ausführen") { execute(request, at: index) }
                    Button("Verwerfen") { model.pendingTerminalRequests.remove(at: index) }
                }
                .padding(6)
                .background(.yellow.opacity(0.2))
            }
            if let session {
                TerminalHost(bridge: session).accessibilityIdentifier("terminal")
            } else {
                ContentUnavailableView("Terminal", systemImage: "terminal", description: Text("Startet deine eigene Shell im Checkout des gewählten Projekts."))
            }
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            let old = session
            session = nil
            Task { await old?.stop() }
        }
    }

    /// One start at a time; a shell started for a window that closed meanwhile is stopped again.
    func start() {
        guard !starting, let root = model.selectedProjectRoot, let host = model.services?.terminals else { return }
        starting = true
        let old = session
        session = nil
        Task {
            await old?.stop()
            let bridge = await TerminalBridge.start(folder: root, host: host) { request in model.queueTerminalRequest(request) }
            if visible { session = bridge } else { await bridge?.stop() }
            starting = false
        }
    }

    func execute(_ request: TerminalRequest, at index: Int) {
        switch request {
        case .copyToClipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openLink(let url):
            NSWorkspace.shared.open(url)
        }
        model.pendingTerminalRequests.remove(at: index)
    }
}

@MainActor
final class TerminalBridge: NSObject, TerminalViewDelegate {
    let folder: String
    let process: TerminalProcess
    let view: TerminalView
    private let onRequest: @MainActor (TerminalRequest) -> Void
    private var pump: Task<Void, Never>?

    private init(folder: String, process: TerminalProcess, onRequest: @escaping @MainActor (TerminalRequest) -> Void) {
        self.folder = folder
        self.process = process
        self.onRequest = onRequest
        var options = TerminalOptions(cols: 100, rows: 30)
        options.scrollback = 5_000
        self.view = TerminalView(frame: .zero, font: nil, options: options)
        super.init()
        view.terminalDelegate = self
    }

    /// `onRequest` runs synchronously on the main actor (where SwiftTerm calls the delegate), so
    /// a flood of requests is bounded by the receiver instead of queueing tasks.
    static func start(folder: String, host: ProcessHost, onRequest: @escaping @MainActor (TerminalRequest) -> Void) async -> TerminalBridge? {
        guard let process = try? await host.launchTerminal(TerminalSessions.spec(folder: folder, rows: 30, columns: 100)) else { return nil }
        let bridge = TerminalBridge(folder: folder, process: process, onRequest: onRequest)
        bridge.startPump()
        return bridge
    }

    /// Pulls output at the pace of the screen: one chunk per turn, at most 64 KiB, so a flood
    /// cannot freeze the window and the program blocks on the full PTY instead.
    private func startPump() {
        let process = process
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let chunk = await process.read(maximum: 64 * 1024) else { break }
                self?.view.feed(byteArray: ArraySlice([UInt8](chunk)))
                try? await Task.sleep(for: .milliseconds(4))
            }
            self?.view.feed(text: "\r\n[Prozess beendet]\r\n")
        }
    }

    func stop() async {
        pump?.cancel()
        await process.hangUp()
    }

    // TerminalViewDelegate
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        process.resize(rows: UInt16(clamping: newRows), columns: UInt16(clamping: newCols))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { process.write(Data(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let request = TerminalRequest.link(link) { onRequest(request) }
    }
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if let link = TerminalRequest.link(request.link) { onRequest(link) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) {
        onRequest(.copyToClipboard(String(decoding: content, as: UTF8.self)))
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalHost: NSViewRepresentable {
    let bridge: TerminalBridge
    func makeNSView(context: Context) -> TerminalView { bridge.view }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
