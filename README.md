# ReadFast

A fast CSV viewer for macOS and Linux. It opens multi-gigabyte files instantly and indexes
the rest in the background, so you can scroll, search, and jump to any row while it works.

## Install

### macOS

Requires macOS 15 (Sequoia) or later on Apple silicon.

**Homebrew (recommended):**

```sh
brew install --cask ahmedash95/tap/readfast
```

Update with `brew upgrade --cask readfast`.

**Manual:** download `ReadFast-<version>.dmg` from the
[latest release](https://github.com/ahmedash95/readfast/releases/latest), open it, and drag
ReadFast to Applications. The app is ad-hoc signed but not notarized, so macOS blocks the
first launch. Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/ReadFast.app
```

(Homebrew does this for you.)

### Linux

**Ubuntu 24.04+ / Debian-based (.deb):**

```sh
# x86_64
wget https://github.com/ahmedash95/readfast/releases/latest/download/readfast_amd64.deb
sudo apt install ./readfast_amd64.deb

# arm64
wget https://github.com/ahmedash95/readfast/releases/latest/download/readfast_arm64.deb
sudo apt install ./readfast_arm64.deb
```

`apt` pulls in GTK 4. ReadFast then shows up in the app grid, or run `readfast file.csv`.
Run the same commands again to update.

**Other distros (tarball):** needs GTK 4.10+ installed. The tarball mirrors a prefix, so
extract it into `~/.local` (or `/usr/local` with `sudo`):

```sh
# x86_64 (arm64: readfast-linux-aarch64.tar.gz)
wget https://github.com/ahmedash95/readfast/releases/latest/download/readfast-linux-x86_64.tar.gz
tar -xzf readfast-linux-x86_64.tar.gz -C ~/.local
```

Make sure `~/.local/bin` is on your `PATH`.

## Build from source

**macOS:** Xcode 27+. Open `ReadFast.xcodeproj` and run the `ReadFast` scheme (pick your
own team under Signing), or build ad-hoc signed from the command line:

```sh
xcodebuild -project ReadFast.xcodeproj -scheme ReadFast -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open build/Build/Products/Release/ReadFast.app
```

**Linux:** Swift 6.0+ and GTK 4 headers:

```sh
sudo apt install libgtk-4-dev
cd ReadFastLinux
swift build -c release --static-swift-stdlib
.build/release/readfast file.csv
```

## Project layout

| Path | What |
|---|---|
| `ReadFast/`, `ReadFast.xcodeproj` | macOS app (SwiftUI) |
| `ReadFastLinux/` | Linux app (GTK 4), see [its README](ReadFastLinux/README.md) |
| `ReadFastCore/` | Shared CSV engine, see [its README](ReadFastCore/README.md) |

## Releases

Every push to `main` publishes a `vX.Y.Z` release with the macOS DMG and the Linux `.deb`
and tarball for both architectures, and updates the Homebrew cask in
[ahmedash95/homebrew-tap](https://github.com/ahmedash95/homebrew-tap).
