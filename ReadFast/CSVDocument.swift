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
    @State private var showGoToRow = false
    @State private var goToText = ""
    @State private var jump: RowJump?
    @State private var query = ""
    @State private var focusFind = 0

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Can't Read File", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if let table, table.header.isEmpty {
                ContentUnavailableView("Empty File", systemImage: "tablecells")
            } else if let table {
                CSVGrid(table: table, rowCount: table.rowCount, isExact: table.isExact,
                        fontSize: NSFont.systemFontSize * zoom, showRowNumbers: showRowNumbers,
                        stripes: renderStripes, opaque: renderOpaque, jump: jump, searchVersion: table.searchVersion)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        #if DEBUG
        .overlay(alignment: .bottomTrailing) { if table != nil { DebugHUD() } }
        #endif
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) { statusPill }
            ToolbarItem(placement: .primaryAction) {
                FindField(text: $query, enabled: table?.supportsSearch ?? false, focus: focusFind, submit: stepMatch)
                    .frame(width: 180)
            }
        }
        .modifier(WindowBackground())
        .background(TabBarShower())
        .focusedSceneValue(\.showGoToRow, table == nil ? nil : $showGoToRow)
        .focusedSceneValue(\.find, table?.supportsSearch == true ? FindActions(focus: { focusFind += 1 }, step: stepMatch) : nil)
        .task(id: query) {
            guard let table else { return }
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }   // debounce typing
            }
            await table.search(query)
        }
        .alert("Go to Row", isPresented: $showGoToRow) {
            TextField("Row number", text: $goToText)
            Button("Go") {
                if let row = Int(goToText.filter(\.isNumber)) { jump = RowJump(row: row - 1) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("1 – \(table?.rowCount.formatted() ?? "")")
        }
        .onAppear { dismissWindow(id: "launcher") }
        .task {
            guard let url else { return }
            do {
                let loaded = try await CSVTable.load(url) // header + preview rows: instant
                table = loaded
                await loaded.index()                      // rest of the file, in the background
            } catch {
                self.error = error
            }
        }
    }

    private func stepMatch(_ delta: Int) {
        guard let match = table?.stepMatch(by: delta) else { return NSSound.beep() }
        jump = RowJump(row: match.row, column: match.column)
    }

    /// "Searching… 1,234", "12 of 3,481", "No matches"; nil with no query.
    private func searchStatus(_ table: CSVTable) -> String? {
        guard !query.isEmpty else { return nil }
        let total = table.searchTotal.formatted()
        if table.isSearching { return "Searching… \(total)" }
        if table.searchTotal == 0 { return "No matches" }
        let capped = table.searchTotal > table.matches.count ? " (first \(table.matches.count.formatted()))" : ""
        guard let current = table.currentMatch else { return "\(total) matches" + capped }
        return "\(current + 1) of \(total)" + capped
    }

    #if DEBUG
    private var renderStripes: Bool { RenderStats.shared.stripes }
    private var renderOpaque: Bool { RenderStats.shared.opaque }
    #else
    private let renderStripes = true
    private let renderOpaque = false
    #endif

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
                    if let status = searchStatus(table) {
                        Label(status, systemImage: "magnifyingglass")
                            .help("Find in file: Return / ⌘G next, ⇧Return / ⇧⌘G previous")
                    }
                    if !table.isExact {
                        ProgressView(value: table.progress)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .help("Indexing \(table.progress.formatted(.percent.precision(.fractionLength(0))))")
                    }
                    Label((table.isExact ? "" : "~") + table.rowCount.formatted(), systemImage: "list.number")
                        .help(table.isExact ? "Rows" : "Rows (estimated while indexing)")
                    Label(table.header.count.formatted(), systemImage: "rectangle.split.3x1")
                        .help("Columns")
                    Label(table.byteCount.formatted(.byteCount(style: .file)), systemImage: "internaldrive")
                        .help("File size")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Opening…")
                }
            }
            .labelStyle(StatusLabelStyle())
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(minWidth: 360, idealWidth: 760, maxWidth: 1000)   // toolbar items take their ideal width
    }
}

/// A "scroll to this row" request. The id makes asking for the same row twice a new request.
struct RowJump: Equatable {
    let row: Int
    /// Set for a search match: scroll to and highlight this field instead of selecting the row.
    var column: Int?
    let id = UUID()
}

extension FocusedValues {
    /// The focused document's Go to Row prompt (⌘L); nil when no table is open.
    @Entry var showGoToRow: Binding<Bool>?
    /// The focused document's Find actions; nil when it can't search.
    @Entry var find: FindActions?
}

/// What Edit > Find does in the focused document. `step` takes 1 (next) or -1 (previous).
struct FindActions {
    let focus: () -> Void
    let step: (Int) -> Void
}

/// Toolbar search field. NSSearchField, not `.searchable`: it can be disabled, and Return can
/// tell ⇧ apart for Find Previous. Esc clears it.
private struct FindField: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    /// Bumped to move the keyboard focus here (⌘F).
    let focus: Int
    let submit: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = enabled
        field.toolTip = enabled ? nil : "Find isn't available for UTF-16 files"
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: FindField
        var focus: Int
        init(_ parent: FindField) { self.parent = parent; focus = parent.focus }

        @objc func changed(_ field: NSSearchField) {
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = ""
                parent.text = ""
            default:
                return false
            }
            return true
        }
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
        static let frameName = "ReadFastDocument"

        override func viewDidMoveToWindow() {
            guard let window else { return }
            // Open at the last document window's frame instead of the default size, so it doesn't
            // jump (or get re-tiled) after appearing. Only one window can own an autosave name;
            // that's fine, since the rest become tabs that share its frame.
            window.setFrameUsingName(Self.frameName)
            window.setFrameAutosaveName(Self.frameName)
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
///
/// Each row is one `GridRowView` that draws its own text; there are no per-cell views. Per-cell
/// NSTextFields made AppKit lay out and restyle every cell on every scroll step (~45 fps at 120 Hz,
/// measured with the debug HUD). Now a row coming into view costs one fetch and one draw, and rows
/// already on screen are only moved. Columns still exist for the header, widths and resizing.
struct CSVGrid: NSViewRepresentable {
    let table: CSVTable
    // Passed as values (not read from `table` inside updateNSView) so SwiftUI calls updateNSView
    // each time indexing grows the count.
    let rowCount: Int
    let isExact: Bool
    let fontSize: CGFloat
    let showRowNumbers: Bool
    let stripes: Bool
    /// Opaque table background instead of the window's blur showing through.
    let opaque: Bool
    let jump: RowJump?
    /// `table.searchVersion`: matches or the current match changed, so visible rows re-highlight.
    let searchVersion: Int

    func makeCoordinator() -> Coordinator { Coordinator(table: table, rowCount: rowCount) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .fullWidth
        tableView.allowsMultipleSelection = true
        tableView.menu = NSMenu()
        tableView.menu?.delegate = context.coordinator
        context.coordinator.attach(tableView)
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

        // Rows draw their own cells, so they repaint when columns move or change width.
        for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.columnsChanged(_:)),
                                                   name: name, object: tableView)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        #if DEBUG
        let meter = FrameMeter()
        meter.scrollView = scrollView
        scrollView.addSubview(meter)
        #endif
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        if let column = tableView.tableColumn(withIdentifier: Coordinator.rowNumberID), column.isHidden == showRowNumbers {
            column.isHidden = !showRowNumbers
            coordinator.redrawRows(tableView)
        }
        if coordinator.stripes != stripes || coordinator.opaque != opaque {
            coordinator.stripes = stripes
            coordinator.opaque = opaque
            tableView.backgroundColor = opaque ? .windowBackgroundColor : .clear
            scrollView.drawsBackground = opaque
            scrollView.backgroundColor = .windowBackgroundColor
            tableView.enumerateAvailableRowViews { rowView, row in
                (rowView as? GridRowView)?.odd = stripes && row % 2 == 1
            }
        }
        if coordinator.rowCount != rowCount || coordinator.isExact != isExact {
            // Indexing moved on: the count changed and rows drawn as placeholders may be readable now.
            coordinator.rowCount = rowCount
            coordinator.isExact = isExact
            tableView.noteNumberOfRowsChanged()
            tableView.reloadData() // only visible rows are re-asked
        }
        if let jump, jump.id != coordinator.lastJump {
            coordinator.lastJump = jump.id
            (tableView as? GridTableView)?.goTo(row: jump.row, centered: true, select: jump.column == nil)
            if let field = jump.column,
               let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(field) }) {
                tableView.scrollColumnToVisible(column)
            }
        }
        if coordinator.searchVersion != searchVersion {
            coordinator.searchVersion = searchVersion
            tableView.enumerateAvailableRowViews { rowView, row in
                let matched = table.matchedColumns(inRow: row)
                (rowView as? GridRowView)?.setMatches(matched.columns, current: matched.current)
            }
        }
        guard coordinator.style.fontSize != fontSize else { return }
        let scale = fontSize / coordinator.style.fontSize
        coordinator.style = GridStyle(fontSize: fontSize)
        // Same recipe as Sequel Ace: row height from the font's line height; the header view is left
        // alone (resizing it fights AppKit's layout), only its title font follows the zoom, capped so
        // it fits the system's fixed-height header.
        let font = coordinator.style.font
        tableView.rowHeight = (font.ascender - font.descender + font.leading + 8).rounded(.up)   // 24pt at 100%, the system default
        let headerFont = NSFont.systemFont(ofSize: min(max(fontSize * 11 / 13, 9), 14))
        for column in tableView.tableColumns {
            column.width = (column.width * scale).rounded()
            column.headerCell.attributedStringValue = NSAttributedString(string: column.title, attributes: [.font: headerFont])
        }
        tableView.headerView?.needsDisplay = true
        tableView.reloadData()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let rowNumberID = NSUserInterfaceItemIdentifier("#")

        let table: CSVTable
        var lastJump: UUID?
        var searchVersion = 0
        /// The count the table view was last told about; changes go through noteNumberOfRowsChanged.
        var rowCount: Int
        var isExact = false
        var stripes = true
        var opaque = false
        // Starts at the unzoomed size so the first updateNSView applies the current zoom.
        var style = GridStyle(fontSize: NSFont.systemFontSize)

        init(table: CSVTable, rowCount: Int) {
            self.table = table
            self.rowCount = rowCount
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        /// No cell views: GridRowView draws the cells.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: GridRowView.reuseID, owner: nil) as? GridRowView ?? GridRowView()
            #if DEBUG
            let start = CACurrentMediaTime()
            let fields = table.fields(at: row)
            RenderStats.shared.recordFetch(CACurrentMediaTime() - start)
            #else
            let fields = table.fields(at: row)
            #endif
            // Empty = not indexed yet: drawn blank, filled by the reloadData when indexing reaches it.
            view.configure(tableView: tableView, number: row + 1, fields: fields, style: style, odd: stripes && row % 2 == 1)
            let matched = table.matchedColumns(inRow: row)
            view.setMatches(matched.columns, current: matched.current)
            return view
        }

        @objc func columnsChanged(_ note: Notification) {
            if let tableView = note.object as? NSTableView { redrawRows(tableView) }
        }

        func redrawRows(_ tableView: NSTableView) {
            tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        // MARK: Copy

        enum CopyFormat: Int { case tsv, csv, json }

        /// Right-click inside the selection acts on the selection; anywhere else on the clicked row.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, tableView.clickedRow >= 0 else { return }
            let rows = tableView.selectedRowIndexes.contains(tableView.clickedRow)
                ? tableView.selectedRowIndexes : IndexSet(integer: tableView.clickedRow)
            let noun = rows.count == 1 ? "Row" : "\(rows.count.formatted()) Rows"
            for (title, format) in [("Copy \(noun)", CopyFormat.tsv), ("Copy as CSV", .csv), ("Copy as JSON", .json)] {
                let item = NSMenuItem(title: title, action: #selector(copyRows(_:)), keyEquivalent: format == .tsv ? "c" : "")
                item.target = self
                item.tag = format.rawValue
                item.representedObject = rows
                menu.addItem(item)
            }
            if let field = dataIndex(tableView, column: tableView.clickedColumn) {
                menu.addItem(.separator())
                let item = NSMenuItem(title: "Copy Cell", action: #selector(copyCell(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = table.fields(at: tableView.clickedRow)[safe: field] ?? ""
                menu.addItem(item)
            }
        }

        /// The grid's table view, for the context menu's clicked row/column.
        private weak var tableView: NSTableView?
        func attach(_ tableView: NSTableView) { self.tableView = tableView }

        @objc private func copyRows(_ sender: NSMenuItem) {
            guard let rows = sender.representedObject as? IndexSet else { return }
            copy(rows: rows, as: CopyFormat(rawValue: sender.tag) ?? .tsv)
        }

        @objc private func copyCell(_ sender: NSMenuItem) {
            setPasteboard(sender.representedObject as? String ?? "")
        }

        /// CSV column index for a table column index, nil for the row-number column.
        func dataIndex(_ tableView: NSTableView, column: Int) -> Int? {
            guard tableView.tableColumns.indices.contains(column) else { return nil }
            return Int(tableView.tableColumns[column].identifier.rawValue)
        }

        func copy(rows: IndexSet, as format: CopyFormat) {
            // ponytail: builds the whole string in memory; past this, stream to a file instead.
            guard !rows.isEmpty, rows.count <= 100_000 else { NSSound.beep(); return }
            let records = rows.map { table.fields(at: $0) }
            switch format {
            case .tsv:
                // Tab-separated pastes into Numbers/Excel as cells; tabs and breaks inside a value would split it.
                setPasteboard(records.map { $0.map(Self.tsvField).joined(separator: "\t") }.joined(separator: "\n"))
            case .csv:
                setPasteboard(([table.header] + records).map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\n") + "\n")
            case .json:
                // Built by hand to keep column order (JSONSerialization would sort or shuffle keys).
                let keys = table.header.map(Self.jsonString)
                let objects = records.map { fields in
                    "  {" + keys.enumerated().map { "\($1): \(Self.jsonString(fields[safe: $0] ?? ""))" }.joined(separator: ", ") + "}"
                }
                setPasteboard("[\n" + objects.joined(separator: ",\n") + "\n]\n")
            }
        }

        private func setPasteboard(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        nonisolated static func tsvField(_ value: String) -> String {
            value.contains(where: { $0 == "\t" || $0.isNewline })
                ? String(value.map { $0 == "\t" || $0.isNewline ? " " : $0 }) : value
        }

        nonisolated static func csvField(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + value.replacing("\"", with: "\"\"") + "\"" : value
        }

        nonisolated static func jsonString(_ value: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes   // "a/b", not "a\/b"
            return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Adds keyboard navigation (hjkl, ←/→ between cells, g/G for top/bottom) and ⌘C.
/// The cell cursor is `cursorColumn` on the selected row; GridRowView draws it.
final class GridTableView: NSTableView {
    var cursorColumn = 1 {
        didSet {
            guard cursorColumn != oldValue else { return }
            for row in selectedRowIndexes { rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true }
        }
    }

    private var coordinator: CSVGrid.Coordinator? { dataSource as? CSVGrid.Coordinator }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Take the keyboard as soon as the document opens, so hjkl works without a click first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Select `row` (clamped) and scroll it into view; `centered` for jumps, edge-following for stepping.
    /// `select: false` only scrolls, leaving selection and keyboard focus alone (search matches).
    func goTo(row: Int, centered: Bool = false, select: Bool = true) {
        guard numberOfRows > 0 else { return }
        let row = min(max(row, 0), numberOfRows - 1)
        if select { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if centered, let clip = enclosingScrollView?.contentView {
            let y = rect(ofRow: row).midY - (clip.bounds.height - clip.contentInsets.top) / 2 - clip.contentInsets.top
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(-clip.contentInsets.top, y)))
            enclosingScrollView?.reflectScrolledClipView(clip)
        } else {
            scrollRowToVisible(row)
        }
        if select { window?.makeFirstResponder(self) }
    }

    private func moveCursor(by delta: Int) {
        let columns = tableColumns.indices.filter { !tableColumns[$0].isHidden && coordinator?.dataIndex(self, column: $0) != nil }
        guard !columns.isEmpty else { return }
        let i = columns.firstIndex(of: cursorColumn) ?? 0
        cursorColumn = columns[min(max(i + delta, 0), columns.count - 1)]
        if selectedRow < 0 { goTo(row: rows(in: visibleRect).location) }
        scrollColumnToVisible(cursorColumn)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .leftArrow?: return moveCursor(by: -1)
        case .rightArrow?: return moveCursor(by: 1)
        default: break
        }
        switch event.characters {
        case "j": goTo(row: selectedRow + 1)
        case "k": goTo(row: max(selectedRow, 1) - 1)
        case "h": moveCursor(by: -1)
        case "l": moveCursor(by: 1)
        case "g": goTo(row: 0)
        case "G": goTo(row: numberOfRows - 1)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let column = column(at: convert(event.locationInWindow, from: nil))
        if coordinator?.dataIndex(self, column: column) != nil { cursorColumn = column }
        super.mouseDown(with: event)
    }

    /// Edit > Copy and ⌘C: selected rows, tab-separated.
    @objc func copy(_ sender: Any?) {
        coordinator?.copy(rows: selectedRowIndexes, as: .tsv)
    }
}

/// Fonts and text attributes for one zoom level, built once instead of per cell.
struct GridStyle {
    let fontSize: CGFloat
    let font: NSFont
    let text: [NSAttributedString.Key: Any]
    let number: [NSAttributedString.Key: Any]

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        font = .systemFont(ofSize: fontSize)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let right = NSMutableParagraphStyle()
        right.lineBreakMode = .byTruncatingHead
        right.alignment = .right
        text = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating]
        number = [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                  .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: right]
    }
}

/// One table row: draws the stripe, then each visible column's text, straight into its layer.
final class GridRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("GridRow")
    /// Longest text drawn per cell; the rest would be truncated off-screen anyway.
    private static let maxCellCharacters = 512

    var odd = false { didSet { if odd != oldValue { needsDisplay = true } } }
    private weak var tableView: NSTableView?
    private var number = 0
    private var fields: [String] = []
    private var style = GridStyle(fontSize: NSFont.systemFontSize)
    /// Fields that contain the search query, and the one Find Next/Previous is on.
    private var matches: [Int] = []
    private var currentMatch: Int?

    convenience init() {
        self.init(frame: .zero)
        identifier = Self.reuseID
    }

    func configure(tableView: NSTableView, number: Int, fields: [String], style: GridStyle, odd: Bool) {
        self.tableView = tableView
        self.number = number
        self.fields = fields.map(Self.displayText)
        self.style = style
        self.odd = odd
        needsDisplay = true
    }

    func setMatches(_ matches: [Int], current: Int?) {
        guard matches != self.matches || current != currentMatch else { return }
        self.matches = matches
        currentMatch = current
        needsDisplay = true
    }

    /// One line per cell: line breaks become ↵ ("\r\n" is one Character, so one ↵), long text is cut.
    private static func displayText(_ value: String) -> String {
        let hasBreak = value.utf8.contains { $0 == 10 || $0 == 13 }
        let short = value.utf8.count <= maxCellCharacters
        if !hasBreak && short { return value }
        let cut = short ? Substring(value) : value.prefix(maxCellCharacters)
        return hasBreak ? cut.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: "↵") : String(cut)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard odd else { return }
        // Translucent stripes; the system's alternating colors are opaque and would hide the window blur.
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        dirtyRect.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect) // background, selection
        guard let tableView else { return }
        #if DEBUG
        RenderStats.shared.recordDraw()
        #endif
        let lineHeight = style.font.ascender - style.font.descender + style.font.leading
        let y = ((bounds.height - lineHeight) / 2).rounded()
        var attributes = style.text
        if isSelected && isEmphasized { attributes[.foregroundColor] = NSColor.alternateSelectedControlTextColor }
        // Keyboard cell cursor (hjkl): outline the cursor column on a single selected row.
        let cursor = isSelected && tableView.numberOfSelectedRows == 1 ? (tableView as? GridTableView)?.cursorColumn : nil

        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
            let columnRect = tableView.rect(ofColumn: index)
            guard columnRect.maxX >= dirtyRect.minX, columnRect.minX <= dirtyRect.maxX else { continue }
            if index == cursor {
                (isEmphasized ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor).setStroke()
                let path = NSBezierPath(roundedRect: NSRect(x: columnRect.minX, y: 0, width: columnRect.width, height: bounds.height)
                    .insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
                path.lineWidth = 1.5
                path.stroke()
            }
            let textRect = NSRect(x: columnRect.minX + 6, y: y, width: max(0, columnRect.width - 12), height: lineHeight)
            if column.identifier == CSVGrid.Coordinator.rowNumberID {
                (String(number) as NSString).draw(in: textRect, withAttributes: style.number)
            } else if let i = Int(column.identifier.rawValue) {
                if !matches.isEmpty, matches.contains(i) {
                    NSColor.systemYellow.withAlphaComponent(i == currentMatch ? 0.9 : 0.35).setFill()
                    NSBezierPath(roundedRect: NSRect(x: columnRect.minX, y: 0, width: columnRect.width, height: bounds.height)
                        .insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
                }
                if i < fields.count {
                    var attributes = attributes
                    if i == currentMatch { attributes[.foregroundColor] = NSColor.black }   // readable on the bright yellow
                    (fields[i] as NSString).draw(in: textRect, withAttributes: attributes)
                }
            }
        }
    }

    // Cells aren't views, so VoiceOver reads the row as one element.
    override func accessibilityLabel() -> String? {
        fields.joined(separator: ", ")
    }
}
