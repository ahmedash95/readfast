#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// Debug-only rendering stats and switches, shown by `DebugHUD` and fed by `FrameMeter`.
///
/// Launch arguments set the switches without clicking (for repeatable runs):
///     open -a ReadFast.app file.csv --args -RFAutoScroll YES -RFStripes NO -RFOpaque YES
/// With auto-scroll on, a one-line summary is printed every second.
@MainActor @Observable
final class RenderStats {
    static let shared = RenderStats()

    // Measured over the last second.
    private(set) var fps = 0.0
    private(set) var refreshHz = 0.0
    private(set) var worstFrameMs = 0.0
    private(set) var droppedFrames = 0
    private(set) var rowsFetched = 0
    private(set) var fetchMicros = 0.0
    private(set) var rowDraws = 0

    // Switches, to A/B what rendering costs.
    // bool(forKey:) also reads "YES"/"NO" strings, which is how launch arguments arrive.
    var autoScroll = UserDefaults.standard.bool(forKey: "RFAutoScroll")
    var stripes = UserDefaults.standard.object(forKey: "RFStripes") == nil || UserDefaults.standard.bool(forKey: "RFStripes")
    /// Opaque table background instead of the blurred window showing through.
    var opaque = UserDefaults.standard.bool(forKey: "RFOpaque")

    @ObservationIgnored private var fetches = 0
    @ObservationIgnored private var fetchTime: CFTimeInterval = 0
    @ObservationIgnored private var draws = 0

    func recordDraw() { draws += 1 }

    func recordFetch(_ seconds: CFTimeInterval) {
        fetches += 1
        fetchTime += seconds
    }

    fileprivate func publish(frames: Int, seconds: Double, worst: Double, dropped: Int, refreshHz: Double) {
        fps = Double(frames) / seconds
        self.refreshHz = refreshHz
        worstFrameMs = worst * 1000
        droppedFrames = dropped
        rowsFetched = fetches
        fetchMicros = fetches == 0 ? 0 : fetchTime / Double(fetches) * 1e6
        rowDraws = draws
        fetches = 0
        fetchTime = 0
        draws = 0
        if autoScroll {
            let line = String(format: "[HUD] fps %.0f/%.0f  worst %.1f ms  dropped %d  rows %d  draws %d  fetch %.1f µs  stripes %@ opaque %@\n",
                              fps, refreshHz, worstFrameMs, droppedFrames, rowsFetched, rowDraws, fetchMicros,
                              stripes ? "on" : "off", opaque ? "on" : "off")
            FileHandle.standardError.write(Data(line.utf8)) // unbuffered, survives the app being killed
        }
    }
}

/// Invisible view inside the grid's scroll view. Its display link fires on the main thread once
/// per screen refresh, so a busy main thread shows up as late callbacks: long frames and drops.
/// Also drives auto-scroll at a constant speed.
final class FrameMeter: NSView {
    weak var scrollView: NSScrollView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var dropped = 0
    private var worst: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private let speed: CGFloat = 4000 // points per second, a fast fling

    override func viewDidMoveToWindow() {
        link?.invalidate()
        link = nil
        last = 0
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { windowStart = now; return }
        let dt = now - last
        frames += 1
        worst = max(worst, dt)
        if dt > link.duration * 1.5 { dropped += 1 }

        let stats = RenderStats.shared
        if stats.autoScroll, let scrollView { scroll(scrollView, by: speed * dt) }
        if now - windowStart >= 1 {
            stats.publish(frames: frames, seconds: now - windowStart, worst: worst, dropped: dropped,
                          refreshHz: link.duration > 0 ? 1 / link.duration : 0)
            windowStart = now
            frames = 0
            dropped = 0
            worst = 0
        }
    }

    private func scroll(_ scrollView: NSScrollView, by distance: CGFloat) {
        let clip = scrollView.contentView
        let top = -clip.contentInsets.top
        let bottom = max(top, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        var y = clip.bounds.minY + direction * distance
        if y >= bottom || y <= top {
            direction = -direction
            y = min(max(y, top), bottom)
        }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Floating panel, bottom right of a document window.
struct DebugHUD: View {
    @State private var stats = RenderStats.shared
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(stats.fps, format: .number.precision(.fractionLength(0))) fps")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(fpsColor)
                Text("/ \(stats.refreshHz, format: .number.precision(.fractionLength(0))) Hz")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.link)
            }
            if expanded {
                row("worst frame", String(format: "%.1f ms", stats.worstFrameMs))
                row("dropped", "\(stats.droppedFrames)/s")
                row("rows fetched", "\(stats.rowsFetched)/s")
                row("fetch", String(format: "%.1f µs", stats.fetchMicros))
                row("row draws", "\(stats.rowDraws)/s")
                Divider()
                Toggle("Auto-scroll", isOn: $stats.autoScroll)
                Toggle("Striped rows", isOn: $stats.stripes)
                Toggle("Opaque table", isOn: $stats.opaque)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .toggleStyle(.checkbox)
        .padding(10)
        .frame(width: 210)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .padding(12)
    }

    private var fpsColor: Color {
        let target = max(stats.refreshHz, 60)
        return stats.fps >= target * 0.95 ? .green : stats.fps >= 50 ? .yellow : .red
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
#endif
