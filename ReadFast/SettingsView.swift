import SwiftUI

/// ReadFast > Settings… (⌘,). A new pane = a new case + a branch in `detail`.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case table = "Table"

        var id: Self { self }
        var icon: String {
            switch self {
            case .appearance: "paintpalette"
            case .table: "tablecells"
            }
        }
    }

    @State private var pane = Pane.appearance

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch pane {
            case .appearance: AppearanceSettings()
            case .table: TableSettings()
            }
        }
        .navigationTitle(pane.rawValue)
        .frame(minWidth: 600, minHeight: 420)
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
