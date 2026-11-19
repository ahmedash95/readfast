import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    enum Layout: String { case grid, list }

    @AppStorage("recentsLayout") private var layout = Layout.grid
    @State private var recents: [URL] = []
    @State private var selection = Set<URL>()
    @Environment(\.openDocument) private var openDocument

    private static let icon = NSWorkspace.shared.icon(for: .commaSeparatedText)

    var body: some View {
        Group {
            if recents.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Files", systemImage: "tablecells")
                } description: {
                    Text("Open a CSV file to get started.")
                } actions: {
                    Button("Open…", action: showOpenPanel)
                        .modifier(GlassButton(prominent: true))
                }
            } else if layout == .grid {
                grid
            } else {
                list
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .scrollContentBackground(.hidden)
        .modifier(WindowBackground())
        .toolbar {
            ToolbarItem {
                Picker("Layout", selection: $layout) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(Layout.grid)
                    Label("List", systemImage: "list.bullet").tag(Layout.list)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Open…", systemImage: "folder", action: showOpenPanel)
            }
        }
        .onAppear { recents = NSDocumentController.shared.recentDocumentURLs }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(recents, id: \.self) { url in
                    Button { open(url) } label: {
                        VStack(spacing: 6) {
                            Image(nsImage: Self.icon)
                                .resizable()
                                .frame(width: 64, height: 64)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .modifier(GlassButton())
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                    .help(url.path(percentEncoded: false))
                }
            }
            .padding(20)
        }
    }

    private var list: some View {
        List(recents, id: \.self, selection: $selection) { url in
            HStack {
                Image(nsImage: Self.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                    Text(url.deletingPathExtension().lastPathComponent)
                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            }
        }
        // Double-click or Return opens.
        .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
            urls.forEach(open)
        }
    }

    private func open(_ url: URL) {
        Task {
            do { try await openDocument(at: url) } catch { NSApp.presentError(error) }
        }
    }

    private func showOpenPanel() {
        NSDocumentController.shared.openDocument(nil)
    }
}

#Preview {
    LauncherView()
}

/// Liquid Glass button styles on macOS 26+, the closest bordered style on macOS 15.
private struct GlassButton: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}
