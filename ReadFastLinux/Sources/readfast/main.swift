import CGtk
import Foundation

// `readfast [file…]`: one window per file; with none, an empty window to drop or open into.
// GApplication makes it single-instance: a second launch opens its files in the first process.
let app = gtk_application_new("dev.ahmedash.readfast", G_APPLICATION_HANDLES_OPEN)!

on(app, "startup") {
    let quit = g_simple_action_new("quit", nil)
    on(quit, "activate") { (_: OpaquePointer?) in g_application_quit(cast(app)) }
    g_action_map_add_action(cast(app), cast(quit))
    for (action, keys) in [
        ("app.quit", ["<Control>q"]),
        ("win.close", ["<Control>w"]),
        ("win.open", ["<Control>o"]),
        ("win.find", ["<Control>f"]),
        ("win.find-next", ["<Control>g", "F3"]),
        ("win.find-previous", ["<Control><Shift>g", "<Shift>F3"]),
        ("win.goto", ["<Control>l"]),
        ("win.zoom-in", ["<Control>plus", "<Control>equal", "<Control>KP_Add"]),
        ("win.zoom-out", ["<Control>minus", "<Control>KP_Subtract"]),
        ("win.zoom-reset", ["<Control>0"]),
    ] { setAccels(app, action, keys) }
}
on(app, "activate") { Window(app: app).present() }
onOpen(app) { urls in
    for url in urls {
        let window = Window(app: app)
        window.open(url)
        window.present()
    }
}

exit(g_application_run(cast(app), CommandLine.argc, CommandLine.unsafeArgv))
