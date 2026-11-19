import CGtk
import Foundation
import ReadFastCore

/// One document window: header bar (title, row count, Open, Find, menu), find and go-to bars,
/// and the grid. An empty window shows a drop hint until a file is opened.
final class Window {
    /// Open windows, so they stay alive while GTK shows them.
    private static var all: [ObjectIdentifier: Window] = [:]

    let window: UnsafeMutablePointer<GtkWidget>
    private let app: UnsafeMutablePointer<GtkApplication>
    private let grid = Grid()
    private let stack: UnsafeMutablePointer<GtkWidget>
    private let titleLabel: UnsafeMutablePointer<GtkWidget>
    private let subtitleLabel: UnsafeMutablePointer<GtkWidget>
    private let menuButton: UnsafeMutablePointer<GtkWidget>
    private let searchBar: UnsafeMutablePointer<GtkWidget>
    private let searchEntry: UnsafeMutablePointer<GtkWidget>
    private let searchStatus: UnsafeMutablePointer<GtkWidget>
    private let gotoBar: UnsafeMutablePointer<GtkWidget>
    private let gotoEntry: UnsafeMutablePointer<GtkWidget>
    private var stateActions: [String: OpaquePointer] = [:]
    private var doc: Document?

    init(app: UnsafeMutablePointer<GtkApplication>) {
        self.app = app
        window = gtk_application_window_new(app)
        gtk_window_set_default_size(cast(window), 1100, 720)
        gtk_window_set_title(cast(window), "ReadFast")

        // Header bar: title + status line in the middle.
        let header = gtk_header_bar_new()
        titleLabel = gtk_label_new("ReadFast")
        gtk_widget_add_css_class(titleLabel, "title")
        subtitleLabel = gtk_label_new(nil)
        gtk_widget_add_css_class(subtitleLabel, "subtitle")
        gtk_widget_set_visible(subtitleLabel, 0)
        let titles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_set_valign(titles, GTK_ALIGN_CENTER)
        gtk_box_append(cast(titles), titleLabel)
        gtk_box_append(cast(titles), subtitleLabel)
        gtk_header_bar_set_title_widget(cast(header), titles)
        let openButton = gtk_button_new_from_icon_name("document-open-symbolic")
        gtk_widget_set_tooltip_text(openButton, "Open (Ctrl+O)")
        gtk_actionable_set_action_name(cast(openButton), "win.open")
        gtk_header_bar_pack_start(cast(header), openButton)
        menuButton = gtk_menu_button_new()
        gtk_menu_button_set_icon_name(cast(menuButton), "open-menu-symbolic")
        gtk_header_bar_pack_end(cast(header), menuButton)
        let findButton = gtk_button_new_from_icon_name("edit-find-symbolic")
        gtk_widget_set_tooltip_text(findButton, "Find (Ctrl+F)")
        gtk_actionable_set_action_name(cast(findButton), "win.find")
        gtk_header_bar_pack_end(cast(header), findButton)
        gtk_window_set_titlebar(cast(window), header)

        // Find bar: entry, "3 of 120", previous/next.
        searchEntry = gtk_search_entry_new()
        gtk_widget_set_size_request(searchEntry, 320, -1)
        gtk_search_entry_set_placeholder_text(cast(searchEntry), "Find in file")
        searchStatus = gtk_label_new(nil)
        gtk_widget_add_css_class(searchStatus, "dim-label")
        let previous = gtk_button_new_from_icon_name("go-up-symbolic")
        gtk_widget_set_tooltip_text(previous, "Previous Match (Shift+Enter)")
        gtk_actionable_set_action_name(cast(previous), "win.find-previous")
        let next = gtk_button_new_from_icon_name("go-down-symbolic")
        gtk_widget_set_tooltip_text(next, "Next Match (Enter)")
        gtk_actionable_set_action_name(cast(next), "win.find-next")
        let findRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        for child in [searchEntry, searchStatus, previous, next] { gtk_box_append(cast(findRow), child) }
        searchBar = gtk_search_bar_new()
        gtk_search_bar_set_child(cast(searchBar), findRow)
        gtk_search_bar_connect_entry(cast(searchBar), cast(searchEntry))
        gtk_search_bar_set_show_close_button(cast(searchBar), 1)

        // Go-to-row bar.
        gotoEntry = gtk_entry_new()
        gtk_entry_set_placeholder_text(cast(gotoEntry), "Row number")
        gtk_entry_set_input_purpose(cast(gotoEntry), GTK_INPUT_PURPOSE_DIGITS)
        gotoBar = gtk_search_bar_new()
        gtk_search_bar_set_child(cast(gotoBar), gotoEntry)
        gtk_search_bar_connect_entry(cast(gotoBar), cast(gotoEntry))
        gtk_search_bar_set_show_close_button(cast(gotoBar), 1)

        let empty = gtk_label_new("Drop a CSV file here, or press Ctrl+O to open one.")
        gtk_widget_add_css_class(empty, "dim-label")
        stack = gtk_stack_new()
        gtk_widget_set_vexpand(stack, 1)
        gtk_stack_add_named(cast(stack), empty, "empty")
        gtk_stack_add_named(cast(stack), grid.widget, "grid")

        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        for child in [searchBar, gotoBar, stack] { gtk_box_append(cast(content), child) }
        gtk_window_set_child(cast(window), content)

        connectSignals()
        addActions()
        rebuildMenu()
        Self.all[ObjectIdentifier(self)] = self
        on(window, "destroy") { [unowned self] in Self.all[ObjectIdentifier(self)] = nil }
    }

    func present() { gtk_window_present(cast(window)) }

    // MARK: Opening

    func open(_ url: URL, options: CSVOptions? = nil) {
        do {
            let doc = try Document(url: url, options: options, previous: options == nil ? nil : self.doc)
            self.doc = doc
            doc.onChange = { [weak self, weak doc] in
                guard let self, let doc, self.doc === doc else { return }
                grid.rowCountChanged()
                updateStatus()
            }
            grid.doc = doc
            doc.startIndexing()
            let name = url.lastPathComponent
            gtk_window_set_title(cast(window), name)
            gtk_label_set_text(cast(titleLabel), name)
            gtk_stack_set_visible_child_name(cast(stack), "grid")
            gtk_widget_grab_focus(grid.area)
            rebuildMenu()
            setState("encoding", doc.options.encoding?.rawValue ?? "auto")
            setState("delimiter", doc.options.delimiter.flatMap { b in delimiters.first { $0.byte == b }?.key } ?? "auto")
            setState("header", doc.options.hasHeader.map { $0 ? "yes" : "no" } ?? "auto")
            if gtk_search_bar_get_search_mode(cast(searchBar)) != 0 { doc.search(query) }
            updateStatus()
        } catch {
            let alert = rf_alert_new("Couldn't open “\(url.lastPathComponent)”")
            gtk_alert_dialog_set_detail(alert, error.localizedDescription)
            gtk_alert_dialog_show(alert, cast(window))
            unref(alert)
        }
    }

    /// Opens here if this window is empty, else in a new window.
    private func openFromUser(_ url: URL) {
        if doc == nil { return open(url) }
        let other = Window(app: app)
        other.open(url)
        other.present()
    }

    private func showOpenDialog() {
        let dialog = gtk_file_dialog_new()
        let csv = gtk_file_filter_new()
        gtk_file_filter_set_name(csv, "CSV and text files")
        for suffix in ["csv", "tsv", "tab", "psv", "txt"] { gtk_file_filter_add_suffix(csv, suffix) }
        let all = gtk_file_filter_new()
        gtk_file_filter_set_name(all, "All files")
        gtk_file_filter_add_pattern(all, "*")
        let filters = g_list_store_new(rf_type_file_filter())
        g_list_store_append(filters, csv?.raw)
        g_list_store_append(filters, all?.raw)
        gtk_file_dialog_set_filters(dialog, cast(filters))
        unref(csv); unref(all); unref(filters)

        gtk_file_dialog_open(dialog, cast(window), nil, { source, result, data in
            let me = Unmanaged<Window>.fromOpaque(data!).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            if let file = gtk_file_dialog_open_finish(cast(source), result, &error) {
                if let url = fileURL(file) { me.openFromUser(url) }
                unref(file)
            }
            if let error { g_error_free(error) } // cancelled
        }, Unmanaged.passRetained(self).toOpaque())
        unref(dialog)
    }

    /// Reopens the file with a Format menu change (~10 ms; indexing restarts).
    private func reopen(_ change: (inout CSVOptions) -> Void) {
        guard let doc else { return }
        var options = doc.options
        change(&options)
        if options != doc.options { open(doc.url, options: options) }
    }

    // MARK: Status

    private func updateStatus() {
        guard let doc else { return }
        let rows = formatCount(doc.rowCount) + (doc.rowCount == 1 ? " row" : " rows")
        let parts = [doc.isExact ? rows : "~\(rows), indexing \(Int(doc.progress * 100))%",
                     doc.header.count == 1 ? "1 column" : "\(doc.header.count) columns",formatBytes(doc.file.byteCount),
                     doc.file.encoding.name, delimiterName(doc.file.delimiter)]
        gtk_label_set_text(cast(subtitleLabel), parts.joined(separator: " · "))
        gtk_widget_set_visible(subtitleLabel, 1)
        gtk_label_set_text(cast(searchStatus), searchStatusText(doc))
    }

    private var query: String { String(cString: gtk_editable_get_text(cast(searchEntry))) }

    private func searchStatusText(_ doc: Document) -> String {
        if !doc.file.supportsSearch { return "Search isn't available for UTF-16 files yet" }
        if query.isEmpty { return "" }
        let total = formatCount(doc.searchTotal)
        if doc.isSearching { return "\(total)…" }
        if doc.searchTotal == 0 { return "No matches" }
        if let current = doc.currentMatch { return "\(formatCount(current + 1)) of \(total)" }
        return doc.searchTotal == 1 ? "1 match" : "\(total) matches"
    }

    private func stepMatch(_ delta: Int) {
        guard let doc, let match = doc.stepMatch(by: delta) else { return }
        grid.scrollTo(row: match.row, column: match.column, centered: true)
        updateStatus()
    }

    // MARK: Signals and actions

    private func connectSignals() {
        on(searchEntry, "search-changed") { [unowned self] in doc?.search(query) }
        on(searchEntry, "activate") { [unowned self] in stepMatch(1) }
        on(searchEntry, "next-match") { [unowned self] in stepMatch(1) }
        on(searchEntry, "previous-match") { [unowned self] in stepMatch(-1) }
        on(searchEntry, "stop-search") { [unowned self] in
            gtk_search_bar_set_search_mode(cast(searchBar), 0)
            gtk_widget_grab_focus(grid.area)
        }
        let shiftEnter = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(cast(shiftEnter), GTK_PHASE_CAPTURE)
        onKey(shiftEnter) { [unowned self] key, state in
            guard state & GDK_SHIFT_MASK.rawValue != 0,
                  key == UInt32(GDK_KEY_Return) || key == UInt32(GDK_KEY_KP_Enter) else { return false }
            stepMatch(-1)
            return true
        }
        gtk_widget_add_controller(searchEntry, cast(shiftEnter))

        on(gotoEntry, "activate") { [unowned self] in
            let text = String(cString: gtk_editable_get_text(cast(gotoEntry))).filter(\.isNumber)
            gtk_search_bar_set_search_mode(cast(gotoBar), 0)
            gtk_widget_grab_focus(grid.area)
            if let row = Int(text) { grid.select(row: row - 1, centered: true) }
        }

        let drop = gtk_drop_target_new(rf_type_file(), GDK_ACTION_COPY)
        onDrop(drop) { [unowned self] value in
            guard let object = g_value_get_object(value), let url = fileURL(cast(object)) else { return false }
            openFromUser(url)
            return true
        }
        gtk_widget_add_controller(window, cast(drop))
    }

    private func addAction(_ name: String, _ fn: @escaping () -> Void) {
        let action = g_simple_action_new(name, nil)
        on(action, "activate") { (_: OpaquePointer?) in fn() }
        g_action_map_add_action(cast(window), cast(action))
        unref(action)
    }

    /// A radio action whose state is a string ("auto", "comma", …); menu items target it as "win.name::value".
    private func addRadio(_ name: String, _ fn: @escaping (String) -> Void) {
        let action = g_simple_action_new_stateful(name, rf_variant_type_string(), g_variant_new_string("auto"))!
        on(action, "change-state") { (value: OpaquePointer?) in
            g_simple_action_set_state(action, value)
            fn(String(cString: g_variant_get_string(value, nil)))
        }
        g_action_map_add_action(cast(window), cast(action))
        stateActions[name] = action
    }

    private func setState(_ name: String, _ value: String) {
        if let action = stateActions[name] { g_simple_action_set_state(action, g_variant_new_string(value)) }
    }

    private func addActions() {
        addAction("open") { [unowned self] in showOpenDialog() }
        addAction("close") { [unowned self] in gtk_window_close(cast(window)) }
        addAction("find") { [unowned self] in
            guard doc != nil else { return }
            gtk_search_bar_set_search_mode(cast(gotoBar), 0)
            gtk_search_bar_set_search_mode(cast(searchBar), 1)
            gtk_widget_grab_focus(searchEntry)
        }
        addAction("find-next") { [unowned self] in stepMatch(1) }
        addAction("find-previous") { [unowned self] in stepMatch(-1) }
        addAction("goto") { [unowned self] in
            guard doc != nil else { return }
            gtk_search_bar_set_search_mode(cast(searchBar), 0)
            gtk_editable_set_text(cast(gotoEntry), "")
            gtk_search_bar_set_search_mode(cast(gotoBar), 1)
            gtk_widget_grab_focus(gotoEntry)
        }
        addAction("zoom-in") { [unowned self] in grid.zoom = min(grid.zoom + 0.1, 3) }
        addAction("zoom-out") { [unowned self] in grid.zoom = max(grid.zoom - 0.1, 0.6) }
        addAction("zoom-reset") { [unowned self] in grid.zoom = 1 }

        let numbers = g_simple_action_new_stateful("row-numbers", nil, g_variant_new_boolean(grid.showRowNumbers ? 1 : 0))!
        on(numbers, "change-state") { [unowned self] (value: OpaquePointer?) in
            g_simple_action_set_state(numbers, value)
            grid.showRowNumbers = g_variant_get_boolean(value) != 0
        }
        g_action_map_add_action(cast(window), cast(numbers))
        unref(numbers)

        addRadio("encoding") { [unowned self] value in reopen { $0.encoding = CSVEncoding(rawValue: value) } }
        addRadio("delimiter") { [unowned self] value in
            reopen { $0.delimiter = delimiters.first { $0.key == value }?.byte }
        }
        addRadio("header") { [unowned self] value in
            reopen { $0.hasHeader = value == "auto" ? nil : value == "yes" }
        }
    }

    /// The header bar menu. Rebuilt per file so "Automatic (…)" names what was detected.
    private func rebuildMenu() {
        let menu = g_menu_new()
        let file = g_menu_new()
        g_menu_append(file, "Open…", "win.open")
        g_menu_append(file, "Find…", "win.find")
        g_menu_append(file, "Go to Row…", "win.goto")
        g_menu_append_section(menu, nil, cast(file))

        if let doc {
            let encoding = g_menu_new()
            g_menu_append(encoding, "Automatic (\(doc.detected.encoding?.name ?? "detect"))", "win.encoding::auto")
            for e in CSVEncoding.allCases { g_menu_append(encoding, e.name, "win.encoding::\(e.rawValue)") }
            let delimiter = g_menu_new()
            g_menu_append(delimiter, "Automatic (\(doc.detected.delimiter.map(delimiterName) ?? "detect"))", "win.delimiter::auto")
            for d in delimiters { g_menu_append(delimiter, delimiterName(d.byte), "win.delimiter::\(d.key)") }
            let header = g_menu_new()
            g_menu_append(header, "Automatic (\(doc.detected.hasHeader.map { $0 ? "Yes" : "No" } ?? "detect"))", "win.header::auto")
            g_menu_append(header, "Yes", "win.header::yes")
            g_menu_append(header, "No", "win.header::no")
            let format = g_menu_new()
            g_menu_append_submenu(format, "Encoding", cast(encoding))
            g_menu_append_submenu(format, "Delimiter", cast(delimiter))
            g_menu_append_submenu(format, "First Row Is Header", cast(header))
            g_menu_append_section(menu, nil, cast(format))
            for m in [encoding, delimiter, header, format] { unref(m) }
        }

        let view = g_menu_new()
        g_menu_append(view, "Show Row Numbers", "win.row-numbers")
        g_menu_append(view, "Zoom In", "win.zoom-in")
        g_menu_append(view, "Zoom Out", "win.zoom-out")
        g_menu_append(view, "Actual Size", "win.zoom-reset")
        g_menu_append_section(menu, nil, cast(view))

        gtk_menu_button_set_menu_model(cast(menuButton), cast(menu))
        for m in [file, view, menu] { unref(m) }
    }
}
