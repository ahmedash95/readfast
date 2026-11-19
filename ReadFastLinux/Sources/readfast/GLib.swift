import CGtk
import Foundation

// Thin glue between Swift closures and GLib's C callbacks. Each handler is boxed and
// passed as user_data; GLib releases the box when the signal is disconnected (object
// finalized) or the source is removed.

/// GTK hands back a mix of typed pointers (public structs) and opaque ones (final types).
/// `cast` converts between them, standing in for the GTK_WIDGET()-style macros.
protocol RawPointer { var raw: UnsafeMutableRawPointer? { get } }
extension UnsafeMutablePointer: RawPointer { var raw: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(self) } }
extension OpaquePointer: RawPointer { var raw: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(self) } }
extension UnsafeMutableRawPointer: RawPointer { var raw: UnsafeMutableRawPointer? { self } }

func cast<T>(_ p: (any RawPointer)?) -> UnsafeMutablePointer<T>! { p?.raw?.assumingMemoryBound(to: T.self) }
func cast(_ p: (any RawPointer)?) -> OpaquePointer! { p?.raw.map(OpaquePointer.init) }

private final class Box { let fn: Any; init(_ fn: Any) { self.fn = fn } }
private func retain(_ fn: Any) -> UnsafeMutableRawPointer { Unmanaged.passRetained(Box(fn)).toOpaque() }
private func unbox<T>(_ p: UnsafeMutableRawPointer?) -> T { Unmanaged<Box>.fromOpaque(p!).takeUnretainedValue().fn as! T }
private let release: GClosureNotify = { data, _ in Unmanaged<Box>.fromOpaque(data!).release() }

private func connect<F>(_ obj: (any RawPointer)?, _ signal: String, _ thunk: F, _ fn: Any) {
    // The thunk is a @convention(c) function; GCallback is `void (*)(void)`, cast like G_CALLBACK does.
    let callback = unsafeBitCast(thunk, to: GCallback.self)
    g_signal_connect_data(obj?.raw, signal, callback, retain(fn), release, GConnectFlags(rawValue: 0))
}

// One thunk per C signature we use.

/// `void handler(instance, user_data)`: clicked, activate, value-changed, destroy, search-changed…
func on(_ obj: (any RawPointer)?, _ signal: String, _ fn: @escaping () -> Void) {
    let thunk: @convention(c) (gpointer?, gpointer?) -> Void = { _, d in (unbox(d) as () -> Void)() }
    connect(obj, signal, thunk, fn)
}

/// `void handler(instance, double, double, user_data)`: drag-begin, drag-update, motion.
func on(_ obj: (any RawPointer)?, _ signal: String, _ fn: @escaping (Double, Double) -> Void) {
    let thunk: @convention(c) (gpointer?, Double, Double, gpointer?) -> Void = { _, x, y, d in
        (unbox(d) as (Double, Double) -> Void)(x, y)
    }
    connect(obj, signal, thunk, fn)
}

/// `gboolean handler(instance, double, double, user_data)`: scroll.
func on(_ obj: (any RawPointer)?, _ signal: String, _ fn: @escaping (Double, Double) -> Bool) {
    let thunk: @convention(c) (gpointer?, Double, Double, gpointer?) -> gboolean = { _, x, y, d in
        (unbox(d) as (Double, Double) -> Bool)(x, y) ? 1 : 0
    }
    connect(obj, signal, thunk, fn)
}

/// `void handler(instance, int, int, user_data)`: resize.
func on(_ obj: (any RawPointer)?, _ signal: String, _ fn: @escaping (Int32, Int32) -> Void) {
    let thunk: @convention(c) (gpointer?, Int32, Int32, gpointer?) -> Void = { _, a, b, d in
        (unbox(d) as (Int32, Int32) -> Void)(a, b)
    }
    connect(obj, signal, thunk, fn)
}

/// `void handler(instance, int n_press, double x, double y, user_data)`: GtkGestureClick pressed.
func on(_ obj: (any RawPointer)?, _ signal: String, _ fn: @escaping (Int32, Double, Double) -> Void) {
    let thunk: @convention(c) (gpointer?, Int32, Double, Double, gpointer?) -> Void = { _, n, x, y, d in
        (unbox(d) as (Int32, Double, Double) -> Void)(n, x, y)
    }
    connect(obj, signal, thunk, fn)
}

/// `gboolean handler(instance, guint keyval, guint keycode, GdkModifierType state, user_data)`: key-pressed.
func onKey(_ obj: (any RawPointer)?, _ fn: @escaping (_ keyval: UInt32, _ state: UInt32) -> Bool) {
    let thunk: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = { _, key, _, state, d in
        (unbox(d) as (UInt32, UInt32) -> Bool)(key, state.rawValue) ? 1 : 0
    }
    connect(obj, "key-pressed", thunk, fn)
}

/// `void handler(instance, GVariant *, user_data)`: GSimpleAction activate / change-state.
func on(_ obj: (any RawPointer)?, _ signal: String, _ fn: @escaping (OpaquePointer?) -> Void) {
    let thunk: @convention(c) (gpointer?, OpaquePointer?, gpointer?) -> Void = { _, v, d in
        (unbox(d) as (OpaquePointer?) -> Void)(v)
    }
    connect(obj, signal, thunk, fn)
}

/// `gboolean handler(GtkDropTarget *, const GValue *, double, double, user_data)`: drop.
func onDrop(_ obj: (any RawPointer)?, _ fn: @escaping (UnsafePointer<GValue>?) -> Bool) {
    let thunk: @convention(c) (gpointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, v, _, _, d in
        (unbox(d) as (UnsafePointer<GValue>?) -> Bool)(v) ? 1 : 0
    }
    connect(obj, "drop", thunk, fn)
}

/// `void handler(GApplication *, GFile **, int, char *hint, user_data)`: GApplication open.
func onOpen(_ obj: (any RawPointer)?, _ fn: @escaping ([URL]) -> Void) {
    let thunk: @convention(c) (gpointer?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?, gpointer?) -> Void = { _, files, n, _, d in
        let urls = (0..<Int(n)).compactMap { files?[$0].flatMap(fileURL) }
        (unbox(d) as ([URL]) -> Void)(urls)
    }
    connect(obj, "open", thunk, fn)
}

/// A GFile's local path as a URL (nil for non-local files).
func fileURL(_ file: OpaquePointer) -> URL? {
    guard let path = g_file_get_path(file) else { return nil }
    defer { g_free(path) }
    return URL(fileURLWithPath: String(cString: path))
}

/// Runs `fn` on the GTK main thread (the GLib main loop), from any thread.
func onMain(_ fn: @escaping () -> Void) {
    g_idle_add_full(G_PRIORITY_DEFAULT, { d in
        (Unmanaged<Box>.fromOpaque(d!).takeRetainedValue().fn as! () -> Void)()
        return 0 // G_SOURCE_REMOVE
    } as GSourceFunc, retain(fn), nil)
}

/// Calls `fn` every `ms` milliseconds on the main thread while it returns true.
func every(ms: UInt32, _ fn: @escaping () -> Bool) {
    g_timeout_add_full(G_PRIORITY_DEFAULT, ms, { d in (unbox(d) as () -> Bool)() ? 1 : 0 },
                       retain(fn), { d in Unmanaged<Box>.fromOpaque(d!).release() })
}

/// gtk_application_set_accels_for_action with a Swift array.
func setAccels(_ app: (any RawPointer)?, _ action: String, _ keys: [String]) {
    let strings = keys.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var list: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
    gtk_application_set_accels_for_action(cast(app), action, &list)
}

func unref(_ object: (any RawPointer)?) { g_object_unref(object?.raw) }
