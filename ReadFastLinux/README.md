# ReadFast for Linux

A GTK 4 frontend over the same engine as the Mac app (`../ReadFastCore`). Swift, no
SwiftUI: the table is one `GtkDrawingArea` that paints only the rows on screen, with a
vertical scrollbar that counts rows, so a 100M-row file scrolls like a small one.

## Build and run

Ubuntu 24.04 (GTK 4.14) or newer, Swift 6.0+ ([swift.org/install](https://swift.org/install)):

```sh
sudo apt install libgtk-4-dev
cd ReadFastLinux
swift build -c release --static-swift-stdlib
.build/release/readfast file.csv
```

## Install (Ubuntu 24.04+)

Every release (`.github/workflows/release.yml` → `linux.yml`) attaches the `.deb`s and tarballs:

```sh
wget https://github.com/ahmedash95/readfast/releases/latest/download/readfast_amd64.deb   # arm64: readfast_arm64.deb
sudo apt install ./readfast_amd64.deb   # pulls in libgtk-4-1; ReadFast shows up in the app grid
```

Run the same two lines again to update. Other distros: the tarball next to it mirrors a
prefix (`tar -xzf readfast-linux-x86_64.tar.gz -C ~/.local`) and needs GTK 4.10+.

## What's there

| Mac app | Linux |
|---|---|
| Open, drag and drop, one window per file | Ctrl+O, drop on the window, `readfast a.csv b.csv` (single instance) |
| Progressive indexing, `~` row count | Same, in the header bar subtitle |
| Find (⌘F, ⌘G, ⇧⌘G) with highlights | Ctrl+F, Enter / Shift+Enter, Ctrl+G / Ctrl+Shift+G, F3 |
| Go to Row (⌘L) | Ctrl+L |
| Format menu: encoding, delimiter, header | Same, in the ☰ menu |
| Zoom, row numbers | Ctrl+= / Ctrl+- / Ctrl+0, ☰ › Show Row Numbers (both remembered) |
| hjkl / arrows, g / G, copy row | Same; Ctrl+C copies the selected row as TSV |
| Column resize | Drag a header edge |

Not ported yet: the launcher with recent files, Settings (translucency), copy as CSV/JSON
and multi-row selection, the debug HUD.

## Layout

```
Sources/CGtk/       system library module for gtk4 (pkg-config), plus a few macro shims
Sources/readfast/
  main.swift        GtkApplication, accelerators, open/activate
  Window.swift      header bar, find and go-to bars, actions, Format menu
  Grid.swift        the table: drawing, scrolling, selection, keys, column resize
  Document.swift    one open file (Linux twin of the Mac app's CSVTable)
  GLib.swift        Swift closures ↔ GLib signals, g_idle_add hop to the main thread
```

GTK owns the main thread through its own loop, so nothing here uses `@MainActor`;
background work (indexing, search) reports back with `onMain` (`g_idle_add`).
