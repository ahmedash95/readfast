import SwiftUI

@main struct ReadFastApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Welcome to ReadFast", id: "launcher") {
            LauncherView()
        }
        .defaultSize(width: 760, height: 520)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        DocumentGroup(viewing: CSVDocument.self) { file in
            CSVDocumentView(url: file.fileURL)
        }
        .defaultSize(width: 1100, height: 720)   // first launch only; after that the last frame is reused
        .commands {
            ZoomCommands()
            GoToRowCommands()
            FindCommands()
        }

        Settings {
            SettingsView()
        }
        .defaultSize(width: 680, height: 460)
        .windowResizability(.contentMinSize)
    }
}

struct ZoomCommands: Commands {
    @AppStorage("zoom") private var zoom = 1.0

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Actual Size") { zoom = 1 }
                .keyboardShortcut("0")
            Button("Zoom In") { zoom = min(zoom + 0.1, 3) }
                .keyboardShortcut("+")
            Button("Zoom Out") { zoom = max(zoom - 0.1, 0.6) }
                .keyboardShortcut("-")
        }
    }
}

/// Edit > Find, for the toolbar search field. Replaces the text-editing group (Find, Spelling…),
/// which a read-only viewer has no other use for.
struct FindCommands: Commands {
    @FocusedValue(\.find) private var find

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { find?.focus() }
                    .keyboardShortcut("f")
                Button("Find Next") { find?.step(1) }
                    .keyboardShortcut("g")
                Button("Find Previous") { find?.step(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(find == nil)
        }
    }
}

struct GoToRowCommands: Commands {
    @FocusedBinding(\.showGoToRow) private var showGoToRow

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Go to Row…") { showGoToRow = true }
                .keyboardShortcut("l")
                .disabled(showGoToRow == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // After the first windows are up, so the prompt isn't the first thing drawn.
        DispatchQueue.main.async { DefaultCSVApp.askOnce() }
    }

    // The launcher replaces the open panel a viewer-only DocumentGroup shows at launch.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// The tab bar's "+" button (and ⌘T) lands here via the responder chain: pick a file to open as a new tab.
    @IBAction func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }
}
