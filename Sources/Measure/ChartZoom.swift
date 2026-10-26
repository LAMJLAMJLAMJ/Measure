#if os(macOS)
import Charts
import SwiftUI

/// The part of a chart that is zoomed in on. Nil on an axis shows the whole of it.
struct ChartZoom: Equatable {
    var x: ClosedRange<Double>?
    var y: ClosedRange<Double>?

    var isZoomed: Bool { x != nil || y != nil }

    /// The x axis to draw: the zoomed part, kept inside `full`, or all of it.
    func xDomain(_ full: ClosedRange<Double>) -> ClosedRange<Double> { ChartZoom.clamped(x, to: full) }
    func yDomain(_ full: ClosedRange<Double>) -> ClosedRange<Double> { ChartZoom.clamped(y, to: full) }

    /// Zooms the x axis about its centre: a factor below 1 zooms in. `log` for a log frequency axis.
    mutating func scaleX(_ factor: Double, full: ClosedRange<Double>, log: Bool) {
        x = ChartZoom.scaled(xDomain(full), by: factor, full: full, log: log)
    }

    /// Zooms the y axis about its centre. `shown` is what the chart shows when not zoomed, if less than `full`.
    mutating func scaleY(_ factor: Double, full: ClosedRange<Double>, shown: ClosedRange<Double>? = nil) {
        let current = y == nil ? (shown ?? full) : yDomain(full)
        y = ChartZoom.scaled(current, by: factor, full: full, log: false)
    }

    private static func clamped(_ range: ClosedRange<Double>?, to full: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let range else { return full }
        let lo = max(range.lowerBound, full.lowerBound)
        let hi = min(range.upperBound, full.upperBound)
        return lo < hi ? lo...hi : full
    }

    /// `range` widened or narrowed by `factor` about its centre, slid back inside `full` if it runs out
    /// of it. Nil once it covers all of `full`.
    private static func scaled(_ range: ClosedRange<Double>, by factor: Double, full: ClosedRange<Double>,
                               log: Bool) -> ClosedRange<Double>? {
        let map: (Double) -> Double = log ? { log10(max($0, 1e-12)) } : { $0 }
        let unmap: (Double) -> Double = log ? { pow(10, $0) } : { $0 }
        let lo = map(range.lowerBound), hi = map(range.upperBound)
        let fullLo = map(full.lowerBound), fullHi = map(full.upperBound)
        let width = (hi - lo) * factor
        guard width < (fullHi - fullLo) * 0.999 else { return nil }
        let centre = (lo + hi) / 2
        var a = centre - width / 2, b = centre + width / 2
        if a < fullLo { b += fullLo - a; a = fullLo }
        if b > fullHi { a -= b - fullHi; b = fullHi }
        return unmap(a)...unmap(b)
    }
}

/// Frequency axis ticks for the part of the axis shown: 1, 2 and 5 in each decade, or every whole
/// multiple when that gives too few.
func zoomedFrequencyTicks(in domain: ClosedRange<Double>) -> [Double] {
    func ticks(_ steps: [Double]) -> [Double] {
        var out: [Double] = []
        var decade = pow(10, (log10(max(domain.lowerBound, 1e-3))).rounded(.down))
        while decade <= domain.upperBound {
            for m in steps where (domain.lowerBound...domain.upperBound).contains(m * decade) { out.append(m * decade) }
            decade *= 10
        }
        return out
    }
    let coarse = ticks([1, 2, 5])
    return coarse.count >= 4 ? coarse : ticks([1, 2, 3, 4, 5, 6, 7, 8, 9])
}

/// A box dragged out on a chart's plot to zoom into, in the overlay's coordinates. A drag that is
/// mostly sideways zooms the time or frequency axis only, a mostly upright one the level axis only.
struct ZoomBox: Equatable {
    var start: CGPoint
    var end: CGPoint

    /// Shorter than this on an axis, in points, and the box leaves that axis alone.
    private static let minimum: CGFloat = 8

    private var zoomsX: Bool { abs(end.x - start.x) >= ZoomBox.minimum }
    private var zoomsY: Bool { abs(end.y - start.y) >= ZoomBox.minimum }

    /// The area shown while dragging, across the whole plot on an axis the box does not zoom.
    func rect(in plot: CGRect) -> CGRect {
        let x0 = zoomsX ? min(start.x, end.x) : plot.minX
        let x1 = zoomsX ? max(start.x, end.x) : plot.maxX
        let y0 = zoomsY ? min(start.y, end.y) : plot.minY
        let y1 = zoomsY ? max(start.y, end.y) : plot.maxY
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).intersection(plot)
    }

    /// Zooms `zoom` into the box.
    func apply(to zoom: inout ChartZoom, proxy: ChartProxy, plot: CGRect) {
        if zoomsX,
           let a: Double = proxy.value(atX: start.x - plot.minX),
           let b: Double = proxy.value(atX: end.x - plot.minX), a != b {
            zoom.x = min(a, b)...max(a, b)
        }
        if zoomsY,
           let a: Double = proxy.value(atY: start.y - plot.minY),
           let b: Double = proxy.value(atY: end.y - plot.minY), a != b {
            zoom.y = min(a, b)...max(a, b)
        }
    }

    /// The box drawn while dragging.
    func view(in plot: CGRect) -> some View {
        let r = rect(in: plot)
        return Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }
}

/// Zoom buttons for a chart: out and in on each axis, and back to the whole chart.
struct ZoomControls: View {
    @Binding var zoom: ChartZoom
    let xFull: ClosedRange<Double>
    let yFull: ClosedRange<Double>
    var xLog = false
    /// The level range shown before zooming, when it is less than `yFull`.
    var yStart: ClosedRange<Double>?

    var body: some View {
        HStack(spacing: 6) {
            axis("X", out: { zoom.scaleX(2, full: xFull, log: xLog) }, in: { zoom.scaleX(0.5, full: xFull, log: xLog) },
                 help: xLog ? "frequency" : "time")
            axis("Y", out: { zoom.scaleY(2, full: yFull, shown: yStart) }, in: { zoom.scaleY(0.5, full: yFull, shown: yStart) },
                 help: "level")
            Button { zoom = ChartZoom() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .disabled(!zoom.isZoomed)
                .help("Show the whole chart. Drag across the chart to zoom into part of it: sideways for the \(xLog ? "frequency" : "time") axis, up or down for the level axis, or a box for both.")
        }
        .fixedSize()
    }

    private func axis(_ name: String, out: @escaping () -> Void, in zoomIn: @escaping () -> Void, help: String) -> some View {
        HStack(spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            ControlGroup {
                Button(action: out) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out on the \(help) axis")
                Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in on the \(help) axis")
            }
        }
    }
}
#endif
