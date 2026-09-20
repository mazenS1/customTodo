import SwiftUI
import AppKit
import ServiceManagement
import Combine

// A neutral interface keeps attention on the observations and their evidence.
// Color is reserved for severity and errors, not navigation or decoration.
private let accent = Color.primary
private let canvas = Color(nsColor: .textBackgroundColor)
private let panel = Color(nsColor: .windowBackgroundColor)
private struct AppearanceSettings: Equatable {
    let isDarkMode: Bool
    let textScale: Double
}

private struct InboxFontScaleKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var inboxFontScale: Double {
        get { self[InboxFontScaleKey.self] }
        set { self[InboxFontScaleKey.self] = newValue }
    }
}
private struct InboxFont: ViewModifier {
    @Environment(\.inboxFontScale) var scale
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    func body(content: Content) -> some View { content.font(.system(size: size * scale, weight: weight, design: design)) }
}
extension View {
    func appFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(InboxFont(size: size, weight: weight, design: design))
    }
}
struct AppearanceRoot<Content: View>: View {
    @ObservedObject var store: Store
    var content: Content
    var body: some View {
        content.environment(\.inboxFontScale, store.db.preferences.textScale)
            .font(.system(size: 13 * store.db.preferences.textScale))
            .preferredColorScheme(store.db.preferences.isDarkMode ? .dark : .light)
    }
}

func severityColor(_ value: String) -> Color {
    switch value { case "Critical", "High": return .red; case "Medium": return .orange; case "Low", "Info": return .secondary; default: return .gray }
}
struct Badge: View {
    var text: String
    var color: Color = .secondary
    var body: some View { Text(text).appFont(size: 11, weight: .medium).foregroundStyle(color) }
}

// AppKit owns the two presentation surfaces, while both SwiftUI roots share one Store.
// Closing the full window leaves the menu bar capture and optional queue running.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var item: NSStatusItem!
    let popover = NSPopover()
    private var window: NSWindow?
    private var preferenceSubscription: AnyCancellable?
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Do not allow two independently launched app copies to race on the JSON database.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppConfig.current.bundleIdentifier).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first { existing.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return }
        let menu = NSMenu()
        let root = NSMenuItem(); menu.addItem(root)
        let submenu = NSMenu(); root.submenu = submenu
        let captureItem = submenu.addItem(withTitle: "Quick capture", action: #selector(toggleCapture), keyEquivalent: "N")
        captureItem.target = self
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(withTitle: "Quit \(AppConfig.current.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editRoot = NSMenuItem(); editRoot.title = "Edit"; menu.addItem(editRoot)
        let edit = NSMenu(title: "Edit"); editRoot.submenu = edit
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key) }
        let viewRoot = NSMenuItem(); viewRoot.title = "View"; menu.addItem(viewRoot)
        let viewMenu = NSMenu(title: "View"); viewRoot.submenu = viewMenu
        for (title, action, key) in [("Increase Text Size", #selector(increaseText), "+"), ("Decrease Text Size", #selector(decreaseText), "-"), ("Actual Text Size", #selector(resetText), "0")] {
            let command = viewMenu.addItem(withTitle: title, action: action, keyEquivalent: key); command.target = self
        }
        // Handle both Cmd+= and Cmd+Shift+= (plus), including while an editor has focus.
        // This local monitor affects only this app and does not register a global shortcut.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return event }
            switch event.charactersIgnoringModifiers {
            case "+", "=": self?.increaseText(); return nil
            case "-": self?.decreaseText(); return nil
            case "0": self?.resetText(); return nil
            default: return event
            }
        }
        NSApp.mainMenu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: AppConfig.current.appName)
        item.button?.target = self; item.button?.action = #selector(toggleCapture)
        item.button?.toolTip = "\(AppConfig.current.appName) — capture a development todo"
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 430, height: 410)
        // The database changes for every capture and review, but appearance only depends
        // on these two preference values. Deduplicate them so normal todo activity does
        // not ask AppKit to reapply window themes and popover geometry.
        preferenceSubscription = store.$db
            .map { AppearanceSettings(isDarkMode: $0.preferences.isDarkMode, textScale: $0.preferences.textScale) }
            .removeDuplicates()
            .sink { [weak self] appearance in
            self?.window?.appearance = NSAppearance(named: appearance.isDarkMode ? .darkAqua : .aqua)
            self?.popover.appearance = NSAppearance(named: appearance.isDarkMode ? .darkAqua : .aqua)
            self?.popover.contentSize = NSSize(width: 430 + 80 * (appearance.textScale - 1), height: 410 + 220 * (appearance.textScale - 1))
        }
        store.importLegacy()
        store.selected = store.db.todos.filter { !$0.done && !$0.isDeleted }.sorted { ($0.reviewed ?? .distantPast) > ($1.reviewed ?? .distantPast) }.first?.id
        // Launch quietly into the menu bar. The full inbox is opened explicitly
        // from capture, so login launches do not interrupt the user.
    }
    @objc func increaseText() { store.resizeText(by: 0.1) }
    @objc func decreaseText() { store.resizeText(by: -0.1) }
    @objc func resetText() { store.db.preferences.textScale = 1; store.save() }
    @objc func toggleCapture() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            preparePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func preparePopover() {
        guard popover.contentViewController == nil else { return }
        // A login launch may sit untouched in the menu bar for days. Defer the SwiftUI
        // capture hierarchy until the first tray click so that idle launches retain only
        // the status item, database, and optional one-shot automation timer.
        popover.contentViewController = NSHostingController(rootView: AppearanceRoot(store: store, content: CaptureView(store: store, openInbox: { [weak self] in self?.showWindow() })))
    }
    private func inboxWindow() -> NSWindow {
        if let window { return window }

        // Most launches use only quick capture in the menu bar. Build the large SwiftUI
        // hierarchy and its backing NSWindow only when the user opens the full inbox;
        // this removes their memory and layout cost from the normal idle process.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        // Reserve a real title-bar area. Extending content underneath it caused the
        // upper portion of controls to compete with the window's drag hit region.
        window.title = AppConfig.current.appName; window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 820, height: 580); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: store.db.preferences.isDarkMode ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: AppearanceRoot(store: store, content: InboxView(store: store)))
        // Remember the user's window geometry instead of reopening at a fixed size.
        // Include the bundle identifier so locally branded builds do not share window geometry.
        let frameName = "\(AppConfig.current.bundleIdentifier).main-window"
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) { window.center() }
        self.window = window
        return window
    }
    func showWindow() { popover.performClose(nil); NSApp.activate(ignoringOtherApps: true); inboxWindow().makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; store.cancel() }
}

// All entry points edit the same saved default. A running review has its own
// immutable ReviewPolicy, so changing this control affects only subsequent runs.
struct ReviewDepthPicker: View {
    @ObservedObject var store: Store
    var body: some View {
        Picker("Review depth", selection: Binding(get: { store.db.preferences.depth }, set: { value in
            store.db.preferences.depth = value
            store.save()
        })) {
            Text("Quick").tag("quick")
            Text("Deep").tag("deep")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
            .accessibilityLabel("Review depth")
            .help("Quick: up to \(AppConfig.current.quickReviewMinutes) minutes. Deep: up to \(AppConfig.current.deepReviewMinutes) minutes. Applies to the next review.")
    }
}

struct CaptureForm: View {
    @ObservedObject var store: Store
    var onSave: () -> Void = {}
    @State private var text = ""
    @State private var project = "Auto"
    @State private var category = "Auto"
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty { Text("Write a todo…").foregroundStyle(.secondary).padding(10).allowsHitTesting(false) }
                TextEditor(text: $text).appFont(size: 14).scrollContentBackground(.hidden).padding(5).focused($focused).accessibilityLabel("Todo observation")
            }.frame(minHeight: 120, maxHeight: 165).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)).allowsHitTesting(false))
            HStack {
                Picker("Project", selection: $project) { Text("Auto-detect").tag("Auto"); ForEach(store.projects, id: \.self) { Text($0).tag($0) } }
                Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
            }.appFont(size: 11)
            HStack {
                Text("Review depth").appFont(size: 11).foregroundStyle(.secondary)
                Spacer()
                ReviewDepthPicker(store: store)
            }
            HStack {
                Text(store.db.preferences.automatic ? "Automatic review" : "Review manually").appFont(size: 11).foregroundStyle(.secondary)
                Spacer()
                Button { if store.add(text, project: project, category: category) { text = ""; onSave() } } label: { Label("Capture", systemImage: "plus").fontWeight(.semibold) }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas).keyboardShortcut(.return, modifiers: .command).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 20000 || !store.storageError.isEmpty)
            }
            if text.count > 20000 { Text("Keep observations under 20,000 characters.").foregroundStyle(.orange).appFont(size: 11, weight: .regular) }
        }.onAppear { store.refreshProjects(); focused = true }
    }
}
struct CaptureView: View {
    @ObservedObject var store: Store
    var openInbox: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(accent); Text("New todo").appFont(size: 15, weight: .semibold); Spacer(); Badge(text: "\(store.openCount) open", color: accent) }
            CaptureForm(store: store)
            if !store.storageError.isEmpty { Text(store.storageError).foregroundStyle(.red).appFont(size: 11, weight: .regular) }
            if !store.notice.isEmpty { Text(store.notice).appFont(size: 11, weight: .regular).foregroundStyle(.secondary).lineLimit(2) }
            Divider()
            HStack {
                // A bordered control makes the full-inbox action visibly interactive and
                // includes padding in its click target, matching native macOS buttons.
                Button(action: openInbox) {
                    Label("Open full inbox", systemImage: "rectangle.split.2x1")
                        .appFont(size: 12, weight: .medium)
                        .padding(.horizontal, 4).padding(.vertical, 4)
                }.buttonStyle(.bordered).controlSize(.large)
                    .help("Open the full todo list and investigations")
                Spacer()
                Text("⌘ ↵ to capture").appFont(size: 11, weight: .regular).foregroundStyle(.tertiary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).help("Quit \(AppConfig.current.appName)")
            }
        }.padding(24).frame(width: 430 + 80 * (store.db.preferences.textScale - 1), height: 410 + 220 * (store.db.preferences.textScale - 1)).background(canvas)
    }
}
struct InboxView: View {
    @ObservedObject var store: Store
    @State private var showCapture = false
    @State private var showSettings = false
    @State private var focusDetails = false
    var body: some View {
        HStack(spacing: 0) {
            if !focusDetails {
                sidebar.frame(width: 190)
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(store.filter).appFont(size: 22, weight: .semibold); Text("\(store.visible.count)").appFont(size: 15, design: .monospaced).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    ReviewDepthPicker(store: store)
                    Button { focusDetails.toggle() } label: {
                        Label(focusDetails ? "Show inbox" : "Expand details", systemImage: focusDetails ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.bordered).help("Give the selected todo the full window, or return to the split view")
                    Button { showCapture = true } label: { Label("Capture", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas).keyboardShortcut("n", modifiers: .command)
                }.padding(25)
                if !store.storageError.isEmpty { Text(store.storageError).appFont(size: 11, weight: .regular).foregroundStyle(.red).padding(.horizontal, 25) }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $store.query).textFieldStyle(.plain)
                    if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(11).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 25).padding(.bottom, 20)
                // Native split view supplies a draggable divider with correct cursor and
                // hit testing. Neither pane has a maximum width, so details can take all
                // space freed by shrinking the list or enlarging the window.
                HSplitView {
                    if !focusDetails {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if store.visible.isEmpty { VStack(spacing: 12) { Image(systemName: "tray").appFont(size: 28, weight: .regular); Text("Nothing here yet").appFont(size: 14, weight: .semibold); Text("Capture an observation or adjust your filters.").appFont(size: 11, weight: .regular) }.foregroundStyle(.secondary).padding(35) }
                            ForEach(store.visible) { todo in
                                Button { store.selected = todo.id } label: { TodoRow(todo: todo, selected: store.selected == todo.id).contentShape(Rectangle()) }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button(todo.isDeleted ? "Restore" : "Delete", systemImage: todo.isDeleted ? "arrow.uturn.backward" : "trash") { store.setDeleted(todo.id, deleted: !todo.isDeleted) }.disabled(store.active == todo.id)
                                    }
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 20)
                    }.frame(minWidth: 220, idealWidth: 300, maxWidth: .infinity)
                    }
                    if let todo = store.db.todos.first(where: { $0.id == store.selected }) {
                        DetailView(store: store, todo: todo).id(todo.id).frame(minWidth: 340, maxWidth: .infinity)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "text.alignleft").appFont(size: 25, weight: .light).foregroundStyle(.secondary)
                            Text("Select a todo").appFont(size: 14, weight: .semibold)
                            Text("Details and investigations appear here.").appFont(size: 13).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                HStack { Text(store.active == nil ? (store.notice.isEmpty ? "Saved" : store.notice) : "Investigating…").lineLimit(1); Spacer(); Text("\(store.usedToday)/\(store.db.preferences.dailyLimit) reviews today").monospacedDigit() }.appFont(size: 10).foregroundStyle(.secondary).padding(12).background(panel)
            }
        }.background(canvas).tint(accent)
        .sheet(isPresented: $showCapture) {
            VStack(alignment: .leading, spacing: 20) { HStack { Text("Capture an observation").appFont(size: 20, weight: .bold); Spacer(); Button("Close") { showCapture = false } }; CaptureForm(store: store) { showCapture = false } }.padding(28).frame(width: 580).background(canvas)
        }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) { showSettings = false } }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(AppConfig.current.appName).appFont(size: 16, weight: .semibold).padding(.horizontal, 10).padding(.top, 25).padding(.bottom, 24)
            nav("All open", "tray", count: store.openCount)
            nav("Needs review", "sparkle.magnifyingglass", count: store.db.todos.filter { !$0.done && !$0.isDeleted && $0.needsReview }.count)
            nav("Completed", "checkmark.circle", count: store.db.todos.filter { $0.done && !$0.isDeleted }.count)
            nav("Trash", "trash", count: store.db.todos.filter(\.isDeleted).count)
            Text("Projects").appFont(size: 11, weight: .medium).foregroundStyle(.secondary).padding(.top, 28).padding(.bottom, 8)
            ForEach(store.projects, id: \.self) { project in nav(project, "folder", count: store.db.todos.filter { !$0.done && !$0.isDeleted && $0.effectiveProject == project }.count) }
            nav("Unassigned", "questionmark.folder", count: store.db.todos.filter { !$0.done && !$0.isDeleted && $0.effectiveProject == "Unassigned" }.count)
            Spacer()
            Text(store.db.preferences.automatic ? "Automatic reviews on" : "Manual reviews").appFont(size: 11).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
            Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3").appFont(size: 12) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 15)
        }.padding(.horizontal, 16).background(panel)
    }
    private func nav(_ title: String, _ icon: String, count: Int) -> some View {
        Button { store.filter = title } label: {
            HStack { Image(systemName: icon).frame(width: 17); Text(title).lineLimit(1); Spacer(); Text("\(count)").appFont(size: 10, design: .monospaced).foregroundStyle(.secondary) }.appFont(size: 12).padding(.horizontal, 10).padding(.vertical, 10).background(store.filter == title ? Color.primary.opacity(0.065) : .clear).foregroundStyle(store.filter == title ? accent : Color.secondary).clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
struct TodoRow: View {
    var todo: Todo
    var selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: todo.done ? "checkmark.circle" : "circle").appFont(size: 13).foregroundStyle(.tertiary).padding(.top, 2)
                Text(todo.title).appFont(size: 13, weight: selected ? .medium : .regular).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 7) {
                Text(todo.effectiveProject)
                Text("·")
                Text(todo.effectiveCategory).lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: todo.reviewStale == true ? "Recheck" : (todo.finding?.severity ?? todo.state), color: severityColor(todo.finding?.severity ?? ""))
            }.appFont(size: 10).foregroundStyle(.secondary).padding(.leading, 22)
        }.padding(14).background(selected ? Color.primary.opacity(0.055) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 1).padding(.horizontal, 14).allowsHitTesting(false) }

    }
}
struct DetailView: View {
    @ObservedObject var store: Store
    var todo: Todo
    @State private var editing = false
    @State private var draft = ""
    var busy: Bool { store.active == todo.id }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(todo.isDeleted ? "In Trash" : "Todo").appFont(size: 12, weight: .medium).foregroundStyle(.secondary)
                    Spacer()
                    if !todo.isDeleted {
                        Button(todo.done ? "Reopen" : "Mark complete") { store.update(todo.id, done: !todo.done) }.buttonStyle(.bordered).disabled(busy)
                    }
                    Button { store.setDeleted(todo.id, deleted: !todo.isDeleted) } label: {
                        Label(todo.isDeleted ? "Restore" : "Delete", systemImage: todo.isDeleted ? "arrow.uturn.backward" : "trash")
                    }.buttonStyle(.bordered).disabled(busy || editing).help(busy ? "Cancel the active investigation before deleting" : "Move to Trash or restore without losing findings")
                }
                if editing {
                    TextEditor(text: $draft).frame(minHeight: 170).appFont(size: 13)
                    HStack { Button("Save observation") { store.update(todo.id, text: draft); editing = false }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 20000); Button("Cancel") { editing = false } }
                } else {
                    Text(todo.text).appFont(size: 15, weight: .medium).lineSpacing(5).textSelection(.enabled)
                    Button("Edit observation") { draft = todo.text; editing = true }.buttonStyle(.plain).foregroundStyle(accent).appFont(size: 11, weight: .regular).disabled(busy || todo.isDeleted)
                }
                VStack(spacing: 10) {
                    Picker("Project", selection: Binding(get: { todo.projectSelection }, set: { store.update(todo.id, project: $0) })) { Text("Auto-detect").tag("Auto"); ForEach(Array(Set(store.projects + (todo.projectSelection == "Auto" ? [] : [todo.projectSelection]))).sorted(), id: \.self) { Text($0).tag($0) } }
                    Picker("Category", selection: Binding(get: { todo.categorySelection }, set: { store.update(todo.id, category: $0) })) { ForEach(categories, id: \.self) { Text($0 == "Auto" ? "Automatic" : $0).tag($0) } }
                    if todo.category == "Auto", todo.finding != nil {
                        Text("Category assigned by Codex").appFont(size: 10).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }.appFont(size: 12).disabled(busy || todo.isDeleted)
                Divider()
                HStack {
                    Text("Investigation").appFont(size: 15, weight: .semibold)
                    Spacer()
                    if busy { Button("Cancel") { store.cancel() } }
                    else { Button(todo.finding == nil ? "Investigate" : "Recheck") { store.investigate(todo.id) }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(canvas).disabled(store.active != nil || todo.done || todo.isDeleted || editing) }
                }
                if busy { HStack { ProgressView().controlSize(.small); Text("Reading relevant source…").appFont(size: 11, weight: .regular).foregroundStyle(.secondary) }; Text("One review at a time · up to \(store.activeReviewPolicy?.timeoutMinutes ?? AppConfig.current.quickReviewMinutes) minutes").appFont(size: 11, weight: .regular).foregroundStyle(.tertiary) }
                if let error = todo.error { Text(error).appFont(size: 12).foregroundStyle(.orange).textSelection(.enabled) }
                if let finding = todo.finding {
                    if todo.reviewStale == true {
                        Text("The observation or project has changed. These findings are preserved; recheck to update them.").appFont(size: 12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack { Badge(text: finding.severity, color: severityColor(finding.severity)); Badge(text: "\(finding.confidence) confidence", color: accent) }
                    section("Assessment", finding.summary)
                    VStack(alignment: .leading, spacing: 10) {
                        label("Evidence")
                        ForEach(Array(finding.evidence.enumerated()), id: \.offset) { entry in
                            HStack(alignment: .top, spacing: 9) { Text(String(format: "%02d", entry.offset + 1)).appFont(size: 10, design: .monospaced).foregroundStyle(accent); Text(entry.element).appFont(size: 12).textSelection(.enabled) }
                        }
                    }
                    section("Next step", finding.nextStep)
                    section("Limitations", finding.limitations)
                    if let date = todo.reviewed { Text("Reviewed \(date.formatted(date: .abbreviated, time: .shortened)). Recheck after code changes.").appFont(size: 10).foregroundStyle(.tertiary) }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("Todo: \(todo.text)\n\nSeverity: \(finding.severity) (\(finding.confidence) confidence)\n\(finding.summary)\n\nEvidence:\n\(finding.evidence.joined(separator: "\n"))\n\nNext step: \(finding.nextStep)\nLimitations: \(finding.limitations)", forType: .string) } label: { Label("Copy findings", systemImage: "doc.on.doc") }.appFont(size: 11, weight: .regular)
                } else if !busy {
                    Text("Investigate to get findings, severity, and source references.").appFont(size: 13).foregroundStyle(.secondary).lineSpacing(4)
                }
                if let source = todo.source { Divider(); Text("Imported from \(source)").appFont(size: 10).foregroundStyle(.tertiary).textSelection(.enabled) }
            }.padding(25)
        }
    }
    private func label(_ text: String) -> some View { Text(text).appFont(size: 12, weight: .semibold).foregroundStyle(.secondary) }
    private func section(_ title: String, _ text: String) -> some View { VStack(alignment: .leading, spacing: 9) { label(title); Text(text).appFont(size: 13).lineSpacing(4).textSelection(.enabled) } }
}
struct SettingsView: View {
    @ObservedObject var store: Store
    var close: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
    @State private var models: [ModelChoice] = []
    private var efforts: [String] { supportedEfforts(models: models, model: store.db.preferences.model) }
    private func reconcileEffort() {
        if !store.db.preferences.effort.isEmpty, !efforts.contains(store.db.preferences.effort) { store.db.preferences.effort = ""; store.save() }
    }
    private func refreshModels() {
        models = modelChoices(at: store.modelCacheURL, selected: store.db.preferences.model)
        reconcileEffort()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("Settings & workflow").appFont(size: 20, weight: .bold); Spacer(); Button("Done", action: close).keyboardShortcut(.escape) }
            ScrollView { VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 15) {
                    Toggle("Automatically investigate new todos", isOn: $store.db.preferences.automatic).tint(accent)
                    Text("Runs while this app is open, one at a time. Imported todos use the manual Investigate button. Failed reviews wait for you to retry.").appFont(size: 11, weight: .regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Stepper("Daily review limit: \(store.db.preferences.dailyLimit)", value: $store.db.preferences.dailyLimit, in: 1...AppConfig.current.maximumDailyReviewLimit)
                    Text("Manual and automatic runs share this limit and your Codex allowance. It resets at local midnight. Turning automation off does not cancel an active review.").appFont(size: 11, weight: .regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Review depth", selection: $store.db.preferences.depth) {
                        Text("Quick · up to \(AppConfig.current.quickReviewMinutes) minutes").tag("quick")
                        Text("Deep · up to \(AppConfig.current.deepReviewMinutes) minutes").tag("deep")
                    }
                    Text("Deep reviews trace more dependencies and may use more of your Codex allowance.").appFont(size: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Allow web research", isOn: $store.db.preferences.allowsWebResearch)
                    Text("Public documentation and known issues. Codex is instructed to keep private code and sensitive details out of searches.").appFont(size: 11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Picker("Model", selection: $store.db.preferences.model) {
                            Text("Codex default").tag("")
                            ForEach(models) { model in Text(model.name).tag(model.id) }
                        }
                        Button { refreshModels() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh models from Codex")
                    }
                    if models.isEmpty { Text("Open Codex and sign in to populate the model list.").appFont(size: 11, weight: .regular).foregroundStyle(.secondary) }
                    Picker("Thinking effort", selection: $store.db.preferences.effort) {
                        Text("Model default").tag("")
                        ForEach(efforts, id: \.self) { value in Text(effortLabel(value)).tag(value) }
                    }
                    Text("Higher effort can take longer. Changes apply to the next review.").appFont(size: 11).foregroundStyle(.secondary)
                    TextField("Codex executable path", text: $store.db.preferences.codexPath).textFieldStyle(.roundedBorder)
                }.padding(10)
            } label: { Label("Codex investigation", systemImage: "sparkles") }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Open at login", isOn: $login).onChange(of: login) { _, enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = SMAppService.mainApp.status == .requiresApproval ? "Enable \(AppConfig.current.appName) in System Settings → General → Login Items." : "" } catch { loginError = error.localizedDescription }
                    }
                    if !loginError.isEmpty { Text(loginError).appFont(size: 11, weight: .regular).foregroundStyle(.orange) }
                    Text("Projects are discovered in \(AppConfig.current.projectRootPath) from folders beginning with \(AppConfig.current.projectDirectoryPrefix). New project folders appear when you capture or start a review.").appFont(size: 11, weight: .regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { Button("Refresh projects") { store.refreshProjects() }; Button("Import \(AppConfig.current.legacyTodoFilename) files") { store.importLegacy() }; Button("Show local data") { NSWorkspace.shared.open(store.directory) } }
                    Text("Observations and findings are stored locally. Codex sends the todo and relevant code to OpenAI using your existing CLI sign-in. Reviews remain read-only. Web research follows the setting above; account integrations remain disabled.").appFont(size: 11, weight: .regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(10)
            } label: { Label("This Mac", systemImage: "desktopcomputer") }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Dark mode", isOn: $store.db.preferences.isDarkMode)
                    HStack {
                        Text("Text size")
                        Spacer()
                        Button { store.resizeText(by: -0.1) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller text (⌘−)")
                        Text("\(Int((store.db.preferences.textScale * 100).rounded()))%").monospacedDigit().frame(width: 55)
                        Button { store.resizeText(by: 0.1) } label: { Image(systemName: "textformat.size.larger") }.help("Larger text (⌘+)")
                        Button("Reset") { store.db.preferences.textScale = 1; store.save() }
                    }
                    Text("⌘+ larger · ⌘− smaller · ⌘0 reset").appFont(size: 11).foregroundStyle(.secondary)
                }.padding(10)
            } label: { Label("Appearance", systemImage: "textformat") }
            Text(store.notice).appFont(size: 11, weight: .regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } }
        }.padding(24).frame(width: 630, height: 700).background(canvas)
        .onAppear { refreshModels() }
        .onDisappear { store.save() }
        .onChange(of: store.db.preferences.automatic) { store.save() }
        .onChange(of: store.db.preferences.depth) { store.save() }
        .onChange(of: store.db.preferences.allowsWebResearch) { store.save() }
        .onChange(of: store.db.preferences.dailyLimit) { store.save() }
        .onChange(of: store.db.preferences.model) { reconcileEffort(); store.save() }
        .onChange(of: store.db.preferences.effort) { store.save() }
        .onChange(of: store.db.preferences.isDarkMode) { store.save() }
        .onChange(of: store.db.preferences.codexPath) { store.save() }
    }
}

@main struct TodoInboxMain {
    @MainActor static func main() {
        // A CLI that exits before reading stdin must report a failed review, not
        // terminate the UI through SIGPIPE while the observation is being written.
        signal(SIGPIPE, SIG_IGN)
#if SELF_TESTS
        if CommandLine.arguments.contains("--self-test") {
            runTests()
            Task { @MainActor in await runWorkerTests(); exit(0) }
            dispatchMain()
        }
#endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory apps can show normal windows but do not occupy the Dock or
        // app switcher. Keep this policy when opening the full inbox as well.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
