import SwiftUI
import UniformTypeIdentifiers

/// Read-only. Doesn't touch the file contents: the view hands `fileURL` to the engine, which maps it.
nonisolated struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    init(configuration: ReadConfiguration) {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}

struct CSVDocumentView: View {
    let url: URL?

    @State private var table: CSVTable?
    @State private var error: Error?
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("showRowNumbers") private var showRowNumbers = true
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Can't Read File", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if let table, table.header.isEmpty {
                ContentUnavailableView("Empty File", systemImage: "tablecells")
            } else if let table {
                CSVGrid(table: table, fontSize: NSFont.systemFontSize * zoom, showRowNumbers: showRowNumbers)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { statusPill }
        }
        .modifier(WindowBackground())
        .background(TabBarShower())
        .onAppear { dismissWindow(id: "launcher") }
        .task {
            guard let url else { return }
            do { table = try await CSVTable.load(url) } catch { self.error = error }
        }
    }

    /// Xcode/TablePlus-style activity area in the middle of the toolbar.
    private var statusPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
            Text(url?.lastPathComponent ?? "Untitled")
                .fontWeight(.medium)
            Spacer(minLength: 16)
            HStack(spacing: 14) {
                if error != nil {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                } else if let table {
                    Label(table.rowCount.formatted(), systemImage: "list.number")
                        .help("Rows")
                    Label(table.header.count.formatted(), systemImage: "rectangle.split.3x1")
                        .help("Columns")
                    Label(table.byteCount.formatted(.byteCount(style: .file)), systemImage: "internaldrive")
                        .help("File size")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Indexing…")
                }
            }
            .labelStyle(StatusLabelStyle())
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(minWidth: 360, maxWidth: 560)
    }
}

/// Icon + value with tight spacing; the default toolbar label style shows only the icon.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Opens every document as a native tab of the existing document window. SwiftUI ignores the
/// "prefer tabs" setting, so the window is merged by hand. The tab bar hides itself at one tab.
private struct TabBarShower: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class View: NSView {
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.tabbingIdentifier = "ReadFast.document"
            window.tabbingMode = .preferred
            DispatchQueue.main.async {
                if let host = NSApp.orderedWindows.first(where: {
                       $0 !== window && $0.isVisible && $0.tabbingIdentifier == window.tabbingIdentifier
                   }),
                   host.tabbedWindows?.contains(window) != true {
                    host.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

/// NSTableView, not SwiftUI `Table`: ~10× cheaper per scroll frame and flat cost at any row count (measured).
struct CSVGrid: NSViewRepresentable {
    let table: CSVTable
    let fontSize: CGFloat
    let showRowNumbers: Bool

    func makeCoordinator() -> Coordinator { Coordinator(table: table) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = .solidVerticalGridLineMask
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let number = NSTableColumn(identifier: Coordinator.rowNumberID)
        number.title = ""
        number.width = 64
        tableView.addTableColumn(number)
        for (i, name) in table.header.enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.title = name
            column.width = 140
            tableView.addTableColumn(column)
        }
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        tableView.tableColumn(withIdentifier: Coordinator.rowNumberID)?.isHidden = !showRowNumbers
        guard coordinator.fontSize != fontSize else { return }
        let scale = fontSize / coordinator.fontSize
        coordinator.fontSize = fontSize
        // Same recipe as Sequel Ace: row height from the font's line height; the header view is left
        // alone (resizing it fights AppKit's layout), only its title font follows the zoom, capped so
        // it fits the system's fixed-height header.
        let font = NSFont.systemFont(ofSize: fontSize)
        tableView.rowHeight = (font.ascender - font.descender + font.leading + 8).rounded(.up)   // 24pt at 100%, the system default
        let headerFont = NSFont.systemFont(ofSize: min(max(fontSize * 11 / 13, 9), 14))
        for column in tableView.tableColumns {
            column.width = (column.width * scale).rounded()
            column.headerCell.attributedStringValue = NSAttributedString(string: column.title, attributes: [.font: headerFont])
        }
        tableView.headerView?.needsDisplay = true
        tableView.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let rowNumberID = NSUserInterfaceItemIdentifier("#")

        let table: CSVTable
        // Starts at the unzoomed size so the first updateNSView applies the current zoom.
        var fontSize = NSFont.systemFontSize
        // NSTableView asks for a row's cells one after another, so parse each row once.
        private var cachedRow = -1
        private var cachedFields: [String] = []

        init(table: CSVTable) { self.table = table }

        func numberOfRows(in tableView: NSTableView) -> Int { table.rowCount }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            StripedRowView(odd: row % 2 == 1)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier else { return nil }
            let field = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                if id == Self.rowNumberID {
                    f.textColor = .secondaryLabelColor
                    f.alignment = .right
                }
                return f
            }()

            if id == Self.rowNumberID {
                field.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
                field.stringValue = String(row + 1)
            } else {
                field.font = .systemFont(ofSize: fontSize)
                if row != cachedRow { cachedFields = table.fields(at: row); cachedRow = row }
                let i = Int(id.rawValue)!
                field.stringValue = i < cachedFields.count ? cachedFields[i] : ""
            }
            return field
        }
    }

    /// Translucent stripes; the system's alternating colors are opaque and would hide the window blur.
    final class StripedRowView: NSTableRowView {
        let odd: Bool
        init(odd: Bool) { self.odd = odd; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func drawBackground(in dirtyRect: NSRect) {
            guard odd else { return }
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            dirtyRect.fill()
        }
    }
}
