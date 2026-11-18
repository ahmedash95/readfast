import SwiftUI
import UniformTypeIdentifiers

/// ReadFast > Settings… (⌘,). A new pane = a new case + a branch in `detail`.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case appearance = "Appearance"
        case table = "Table"

        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .table: "tablecells"
            }
        }
    }

    @State private var pane = Pane.general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch pane {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .table: TableSettings()
            }
        }
        .navigationTitle(pane.rawValue)
        .frame(minWidth: 600, minHeight: 420)
    }
}

private struct GeneralSettings: View {
    @State private var isDefault = DefaultCSVApp.isDefault

    var body: some View {
        Form {
            Section("Default App") {
                LabeledContent("Open CSV files with ReadFast") {
                    if isDefault {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") {
                            Task {
                                await DefaultCSVApp.makeDefault()
                                isDefault = DefaultCSVApp.isDefault
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The default can change elsewhere (Finder's Get Info), so re-check when shown.
        .onAppear { isDefault = DefaultCSVApp.isDefault }
    }
}

/// ReadFast as the system's default app for CSV files (what a double-click in Finder opens).
enum DefaultCSVApp {
    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: .commaSeparatedText) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm the change itself; declining just leaves things as they were.
    static func makeDefault() async {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .commaSeparatedText)
        } catch let error as CocoaError where error.code == .userCancelled {
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Once per install, at launch: offer to become the default, like browsers do.
    static func askOnce() {
        let key = "askedToBeDefaultCSVApp"
        guard !UserDefaults.standard.bool(forKey: key), !isDefault else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Make ReadFast your default app for CSV files?"
        alert.informativeText = "CSV files will open in ReadFast when you double-click them. You can change this later in ReadFast Settings or in Finder's Get Info."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault() }
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage("translucent") private var translucent = true
    @AppStorage("windowOpacity") private var opacity = 0.0

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Translucent windows", isOn: $translucent)
                Slider(value: $opacity, in: 0...0.9) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.dotted")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
                .disabled(!translucent)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TableSettings: View {
    @AppStorage("showRowNumbers") private var showRowNumbers = true

    var body: some View {
        Form {
            Section("Columns") {
                Toggle("Show row numbers", isOn: $showRowNumbers)
            }
        }
        .formStyle(.grouped)
    }
}

/// Window background driven by the Appearance settings. Applied to every window's root view.
struct WindowBackground: ViewModifier {
    @AppStorage("translucent") private var translucent = true
    @AppStorage("windowOpacity") private var opacity = 0.0

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor).opacity(translucent ? opacity : 1).ignoresSafeArea())
            .containerBackground(.thinMaterial, for: .window)
    }
}

#Preview {
    SettingsView()
}
