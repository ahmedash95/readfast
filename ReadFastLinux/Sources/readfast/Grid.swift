import CGtk
import Foundation

/// The table: one GtkDrawingArea that paints only the rows on screen (like the Mac app's
/// GridRowView), plus two scrollbars. The vertical adjustment counts rows, not pixels, so a
/// 100M-row file scrolls the same as a small one.
final class Grid {
    let widget: UnsafeMutablePointer<GtkWidget>
    let area: UnsafeMutablePointer<GtkWidget>
    private let vadj: UnsafeMutablePointer<GtkAdjustment>
    private let hadj: UnsafeMutablePointer<GtkAdjustment>

    var doc: Document? { didSet { reset() } }
    private(set) var selectedRow: Int?
    private(set) var cursorColumn = 0
    private var widths: [Double] = []

    var zoom = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(zoom, forKey: "zoom")
            widths = widths.map { $0 * zoom / oldValue }
            updateMetrics()
        }
    }
    var showRowNumbers = UserDefaults.standard.object(forKey: "showRowNumbers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRowNumbers, forKey: "showRowNumbers"); updateMetrics() }
    }

    private var font: OpaquePointer?       // PangoFontDescription
    private var headerFont: OpaquePointer?
    private var rowH = 24.0, textH = 16.0, numberW = 0.0
    /// Column being resized by dragging its right edge in the header, and its width at drag start.
    private var resizing: (column: Int, start: Double)?

    /// Longest text drawn per cell; the rest would be ellipsized off-screen anyway.
    private static let maxCellCharacters = 512

    init() {
        area = gtk_drawing_area_new()
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_widget_set_focusable(area, 1)
        vadj = gtk_adjustment_new(0, 0, 0, 1, 10, 0)
        hadj = gtk_adjustment_new(0, 0, 0, 20, 200, 0)
        widget = gtk_grid_new()
        gtk_grid_attach(cast(widget), area, 0, 0, 1, 1)
        gtk_grid_attach(cast(widget), gtk_scrollbar_new(GTK_ORIENTATION_VERTICAL, vadj), 1, 0, 1, 1)
        gtk_grid_attach(cast(widget), gtk_scrollbar_new(GTK_ORIENTATION_HORIZONTAL, hadj), 0, 1, 1, 1)

        // The window owns the grid for the area's whole life, so an unretained pointer is safe.
        gtk_drawing_area_set_draw_func(cast(area), { _, cr, w, h, data in
            Unmanaged<Grid>.fromOpaque(data!).takeUnretainedValue().draw(cr!, Double(w), Double(h))
        }, Unmanaged.passUnretained(self).toOpaque(), nil)

        on(vadj, "value-changed") { [unowned self] in gtk_widget_queue_draw(area) }
        on(hadj, "value-changed") { [unowned self] in gtk_widget_queue_draw(area) }
        on(area, "resize") { [unowned self] (_: Int32, _: Int32) in layout() }

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)
        on(scroll, "scroll") { [unowned self] (dx: Double, dy: Double) -> Bool in
            var (dx, dy) = (dx, dy)
            let state = gtk_event_controller_get_current_event_state(cast(scroll)).rawValue
            if state & GDK_SHIFT_MASK.rawValue != 0, dx == 0 { (dx, dy) = (dy, 0) }
            let wheel = gtk_event_controller_scroll_get_unit(cast(scroll)) == GDK_SCROLL_UNIT_WHEEL
            move(vadj, by: wheel ? dy * 3 : dy / rowH)
            move(hadj, by: wheel ? dx * 3 * rowH : dx)
            return true
        }
        gtk_widget_add_controller(area, cast(scroll))

        let click = gtk_gesture_click_new()
        on(click, "pressed") { [unowned self] (_: Int32, x: Double, y: Double) in
            gtk_widget_grab_focus(area)
            guard y >= rowH, let doc else { return }
            let row = Int(gtk_adjustment_get_value(vadj) + (y - rowH) / rowH)
            guard row < doc.rowCount else { return }
            if let column = column(atX: x) { cursorColumn = column }
            select(row: row)
        }
        gtk_widget_add_controller(area, cast(click))

        let drag = gtk_gesture_drag_new()
        on(drag, "drag-begin") { [unowned self] (x: Double, y: Double) in
            resizing = y < rowH ? border(atX: x).map { ($0, widths[$0]) } : nil
        }
        on(drag, "drag-update") { [unowned self] (dx: Double, _: Double) in
            guard let resizing else { return }
            widths[resizing.column] = max(40, resizing.start + dx)
            layout()
            gtk_widget_queue_draw(area)
        }
        gtk_widget_add_controller(area, cast(drag))

        let motion = gtk_event_controller_motion_new()
        on(motion, "motion") { [unowned self] (x: Double, y: Double) in
            gtk_widget_set_cursor_from_name(area, y < rowH && border(atX: x) != nil ? "col-resize" : nil)
        }
        gtk_widget_add_controller(area, cast(motion))

        let keys = gtk_event_controller_key_new()
        onKey(keys) { [unowned self] key, state in handleKey(key, state) }
        gtk_widget_add_controller(area, cast(keys))

        updateMetrics()
    }

    // MARK: Layout

    private func reset() {
        selectedRow = nil
        cursorColumn = 0
        gtk_adjustment_set_value(vadj, 0)
        gtk_adjustment_set_value(hadj, 0)
        widths = measureColumns()
        updateMetrics()
    }

    /// Fonts and row height for the current zoom, then layout.
    private func updateMetrics() {
        let base = pango_context_get_font_description(gtk_widget_get_pango_context(area))
        let size = base.map { pango_font_description_get_size($0) } ?? 0
        for f in [font, headerFont] { if let f { pango_font_description_free(f) } }
        font = pango_font_description_copy(base)
        pango_font_description_set_size(font, Int32(Double(size > 0 ? size : 10 * PANGO_SCALE) * zoom))
        headerFont = pango_font_description_copy(font)
        pango_font_description_set_weight(headerFont, PANGO_WEIGHT_SEMIBOLD)
        textH = Double(measure("Ag").height)
        rowH = (textH + 8 * zoom).rounded()
        numberW = showRowNumbers && doc != nil ? Double(measure(String(repeating: "8", count: String(max(doc!.rowCount, 1)).count)).width) + 20 : 0
        layout()
        gtk_widget_queue_draw(area)
    }

    /// Scroll ranges from the row count, column widths and widget size. Call when any changes.
    func layout() {
        let w = Double(gtk_widget_get_width(area)), h = Double(gtk_widget_get_height(area))
        let rows = Double(doc?.rowCount ?? 0)
        let page = max(1, ((h - rowH) / rowH).rounded(.down))
        gtk_adjustment_configure(vadj, gtk_adjustment_get_value(vadj), 0, rows, 1, max(1, page - 1), page)
        let dataW = max(0, w - numberW)
        gtk_adjustment_configure(hadj, gtk_adjustment_get_value(hadj), 0, widths.reduce(0, +), 20, dataW * 0.9, dataW)
    }

    /// The row count changed (indexing): the number column may need another digit.
    func rowCountChanged() {
        let digits = String(max(doc?.rowCount ?? 1, 1)).count
        let w = showRowNumbers ? Double(measure(String(repeating: "8", count: digits)).width) + 20 : 0
        if w != numberW { updateMetrics() } else { layout(); gtk_widget_queue_draw(area) }
    }

    /// Default widths: the widest of header and sample rows, clamped.
    private func measureColumns() -> [Double] {
        guard let doc else { return [] }
        let sample = (0..<min(doc.rowCount, 100)).map { doc.fields(at: $0) }
        return doc.header.indices.map { c in
            let cells = sample.compactMap { c < $0.count ? measure(String($0[c].prefix(80))).width : nil }
            let widest = max(measure(doc.header[c], font: headerFont).width, cells.max() ?? 0)
            return min(max(Double(widest) + 20, 60 * zoom), 360 * zoom)
        }
    }

    private func measure(_ text: String, font: OpaquePointer? = nil) -> (width: Int32, height: Int32) {
        let layout = gtk_widget_create_pango_layout(area, displayText(text))
        defer { unref(layout) }
        pango_layout_set_font_description(layout, font ?? self.font)
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_pixel_size(layout, &w, &h)
        return (w, h)
    }

    private func move(_ adj: UnsafeMutablePointer<GtkAdjustment>, by delta: Double) {
        guard delta != 0 else { return }
        gtk_adjustment_set_value(adj, gtk_adjustment_get_value(adj) + delta) // clamps to the range
    }

    /// Data column under x, if any.
    private func column(atX x: Double) -> Int? {
        guard x >= numberW else { return nil }
        var edge = numberW - gtk_adjustment_get_value(hadj)
        for (c, w) in widths.enumerated() {
            edge += w
            if x < edge { return c }
        }
        return nil
    }

    /// Column whose right edge is within a few pixels of x (for resizing).
    private func border(atX x: Double) -> Int? {
        var edge = numberW - gtk_adjustment_get_value(hadj)
        for (c, w) in widths.enumerated() {
            edge += w
            if edge > numberW, abs(x - edge) <= 4 { return c }
        }
        return nil
    }

    // MARK: Selection

    /// Selects `row` (clamped), optionally moves the cursor column, and scrolls it into view.
    func select(row: Int, column: Int? = nil, centered: Bool = false) {
        guard let doc, doc.rowCount > 0 else { return }
        let row = min(max(row, 0), doc.rowCount - 1)
        selectedRow = row
        if let column { cursorColumn = min(max(column, 0), max(widths.count - 1, 0)) }
        scrollTo(row: row, column: column, centered: centered)
    }

    /// Scrolls `row` (and `column`) into view without selecting: used for search matches.
    func scrollTo(row: Int, column: Int? = nil, centered: Bool = false) {
        let top = gtk_adjustment_get_value(vadj), page = gtk_adjustment_get_page_size(vadj), r = Double(row)
        if centered { gtk_adjustment_set_value(vadj, r - page / 2) }
        else if r < top { gtk_adjustment_set_value(vadj, r) }
        else if r + 1 > top + page { gtk_adjustment_set_value(vadj, r + 1 - page) }
        if let column, column < widths.count {
            let x0 = widths[..<column].reduce(0, +), x1 = x0 + widths[column]
            let left = gtk_adjustment_get_value(hadj), page = gtk_adjustment_get_page_size(hadj)
            if x0 < left { gtk_adjustment_set_value(hadj, x0) }
            else if x1 > left + page { gtk_adjustment_set_value(hadj, min(x0, x1 - page)) }
        }
        gtk_widget_queue_draw(area)
    }

    private func handleKey(_ key: UInt32, _ state: UInt32) -> Bool {
        guard let doc, doc.rowCount > 0 else { return false }
        let row = selectedRow ?? Int(gtk_adjustment_get_value(vadj))
        let page = Int(gtk_adjustment_get_page_size(vadj))
        if state & GDK_CONTROL_MASK.rawValue != 0 {
            guard key == UInt32(GDK_KEY_c) else { return false }
            copySelectedRow()
            return true
        }
        if state & GDK_ALT_MASK.rawValue != 0 { return false }
        switch Int32(key) {
        case GDK_KEY_Down, GDK_KEY_j: select(row: selectedRow == nil ? row : row + 1)
        case GDK_KEY_Up, GDK_KEY_k: select(row: row - 1)
        case GDK_KEY_Left, GDK_KEY_h: select(row: row, column: cursorColumn - 1)
        case GDK_KEY_Right, GDK_KEY_l: select(row: row, column: cursorColumn + 1)
        case GDK_KEY_Page_Down: select(row: row + page)
        case GDK_KEY_Page_Up: select(row: row - page)
        case GDK_KEY_Home, GDK_KEY_g: select(row: 0)
        case GDK_KEY_End, GDK_KEY_G: select(row: doc.rowCount - 1)
        default: return false
        }
        return true
    }

    /// Ctrl+C: the selected row, tab-separated (like the Mac app's Copy).
    private func copySelectedRow() {
        guard let doc, let selectedRow else { return }
        let text = doc.fields(at: selectedRow)
            .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t")
        gdk_clipboard_set_text(gtk_widget_get_clipboard(area), text)
    }

    // MARK: Drawing

    /// One line per cell: line breaks become ↵, long text is cut.
    private func displayText(_ value: String) -> String {
        let hasBreak = value.utf8.contains { $0 == 10 || $0 == 13 }
        let short = value.utf8.count <= Self.maxCellCharacters
        if !hasBreak && short { return value }
        let cut = short ? Substring(value) : value.prefix(Self.maxCellCharacters)
        return hasBreak ? cut.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: "↵") : String(cut)
    }

    private func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double) {
        guard let doc else { return }
        var fg = GdkRGBA()
        gtk_widget_get_color(area, &fg)
        func ink(_ alpha: Double) {
            cairo_set_source_rgba(cr, Double(fg.red), Double(fg.green), Double(fg.blue), alpha * Double(fg.alpha))
        }
        func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { cairo_rectangle(cr, x, y, w, h); cairo_fill(cr) }

        let layout = pango_cairo_create_layout(cr)
        defer { unref(layout) }
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
        pango_layout_set_single_paragraph_mode(layout, 1)
        func text(_ s: String, _ x: Double, _ y: Double, _ width: Double, right: Bool = false) {
            guard width > 0 else { return }
            pango_layout_set_width(layout, Int32(width * Double(PANGO_SCALE)))
            pango_layout_set_alignment(layout, right ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT)
            pango_layout_set_text(layout, displayText(s), -1)
            cairo_move_to(cr, x, y + ((rowH - textH) / 2).rounded())
            pango_cairo_show_layout(cr, layout)
        }

        let top = gtk_adjustment_get_value(vadj), left = gtk_adjustment_get_value(hadj)
        let firstRow = Int(top)

        // Rows, below the header.
        cairo_save(cr)
        cairo_rectangle(cr, 0, rowH, w, h - rowH)
        cairo_clip(cr)
        pango_layout_set_font_description(layout, font)
        var y = rowH - (top - Double(firstRow)) * rowH
        var row = firstRow
        while y < h, row < doc.rowCount {
            if row % 2 == 1 { ink(0.04); fill(0, y, w, rowH) }
            if row == selectedRow { cairo_set_source_rgba(cr, 0.21, 0.52, 0.89, 0.3); fill(0, y, w, rowH) }
            let fields = doc.fields(at: row)
            let (matched, current) = doc.matchedColumns(inRow: row)

            cairo_save(cr)
            cairo_rectangle(cr, numberW, y, w - numberW, rowH)
            cairo_clip(cr)
            var x = numberW - left
            for (c, cw) in widths.enumerated() {
                defer { x += cw }
                if x + cw < numberW { continue }
                if x > w { break }
                if matched.contains(c) {
                    cairo_set_source_rgba(cr, 1, 0.8, 0, c == current ? 0.9 : 0.35)
                    fill(x + 2, y + 2, cw - 4, rowH - 4)
                }
                if row == selectedRow, c == cursorColumn {
                    ink(0.6)
                    cairo_set_line_width(cr, 1.5)
                    cairo_rectangle(cr, x + 2, y + 2, cw - 4, rowH - 4)
                    cairo_stroke(cr)
                }
                guard c < fields.count else { continue }
                if c == current { cairo_set_source_rgba(cr, 0, 0, 0, 1) } else { ink(1) } // readable on bright yellow
                text(fields[c], x + 6, y, cw - 12)
            }
            cairo_restore(cr)

            if numberW > 0 { ink(0.5); text(String(row + 1), 6, y, numberW - 14, right: true) }
            y += rowH
            row += 1
        }
        cairo_restore(cr)

        // Header and grid lines.
        ink(0.06); fill(0, 0, w, rowH)
        ink(0.15); fill(0, rowH - 1, w, 1)
        if numberW > 0 { ink(0.12); fill(numberW - 1, 0, 1, h) }
        cairo_save(cr)
        cairo_rectangle(cr, numberW, 0, w - numberW, h)
        cairo_clip(cr)
        pango_layout_set_font_description(layout, headerFont)
        var x = numberW - left
        for (c, cw) in widths.enumerated() {
            defer { x += cw }
            if x + cw < numberW { continue }
            if x > w { break }
            ink(0.85); text(doc.header[c], x + 6, 0, cw - 12)
            ink(0.08); fill(x + cw - 1, 0, 1, h)
        }
        cairo_restore(cr)
    }
}
