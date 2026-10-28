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
        // Zoomed out to the whole axis: nil would go back to the smaller preset range, so keep it all.
        y = ChartZoom.scaled(current, by: factor, full: full, log: false) ?? (shown == nil ? nil : full)
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
    @State private var settingRange = false

    var body: some View {
        HStack(spacing: 6) {
            Button("Zoom to Range…") { settingRange = true }
                .help("Type the lowest and highest values to show on each axis")
                .popover(isPresented: $settingRange, arrowEdge: .bottom) {
                    ZoomRangeForm(zoom: $zoom, xFull: xFull, yFull: yFull, xLog: xLog,
                                  yShown: zoom.y == nil ? (yStart ?? yFull) : zoom.yDomain(yFull)) { settingRange = false }
                }
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

/// Drag across a chart to zoom into that part of it, for a chart with no other pointer interaction.
private struct ZoomDrag: ViewModifier {
    @Binding var zoom: ChartZoom
    @State private var box: ZoomBox?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let plot = geo[anchor]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { box = ZoomBox(start: $0.startLocation, end: $0.location) }
                            .onEnded { value in
                                ZoomBox(start: value.startLocation, end: value.location).apply(to: &zoom, proxy: proxy, plot: plot)
                                box = nil
                            })
                    if let box { box.view(in: plot) }
                }
            }
        }
    }
}

/// Scroll bars beside and under a chart, to move along it while zoomed. Each shows only while its
/// axis shows less than the whole: drag the thumb, or click the track to centre the view there.
private struct ZoomScrollBars: ViewModifier {
    @Binding var zoom: ChartZoom
    let xFull: ClosedRange<Double>
    let yFull: ClosedRange<Double>
    let xLog: Bool
    /// What the level axis shows now, which can be a preset range less than `yFull` when not zoomed.
    let yShown: ClosedRange<Double>

    func body(content: Content) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                content
                ZoomScrollBar(vertical: true, full: yFull, shown: yShown, log: false) { zoom.y = $0 }
                    .frame(width: 9)
            }
            ZoomScrollBar(vertical: false, full: xFull, shown: zoom.xDomain(xFull), log: xLog) { zoom.x = $0 }
                .frame(height: 9)
                .padding(.trailing, 12)
        }
    }
}

private struct ZoomScrollBar: View {
    let vertical: Bool
    let full: ClosedRange<Double>
    let shown: ClosedRange<Double>
    let log: Bool
    let scroll: (ClosedRange<Double>) -> Void
    @State private var dragStart: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geo in
            let length = Double(max(vertical ? geo.size.height : geo.size.width, 1))
            let a = fraction(shown.lowerBound), b = fraction(shown.upperBound)
            if b - a < 0.999 {
                let thumb = CGFloat(max(16, (b - a) * length))
                let start = CGFloat(min(vertical ? (1 - b) * length : a * length, length - Double(thumb)))
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                        .contentShape(Rectangle())
                        .onTapGesture { p in
                            let along = Double(vertical ? p.y : p.x) / length
                            centre(at: vertical ? 1 - along : along)
                        }
                    Capsule().fill(Color.secondary.opacity(dragStart == nil ? 0.45 : 0.7))
                        .frame(width: vertical ? geo.size.width : thumb, height: vertical ? thumb : geo.size.height)
                        .offset(x: vertical ? 0 : start, y: vertical ? start : 0)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let from = dragStart ?? shown
                                dragStart = from
                                let moved = Double(vertical ? -value.translation.height : value.translation.width)
                                scroll(shifted(from, by: moved / length))
                            }
                            .onEnded { _ in dragStart = nil })
                }
            }
        }
    }

    private func map(_ v: Double) -> Double { log ? log10(max(v, 1e-12)) : v }
    private func unmap(_ v: Double) -> Double { log ? pow(10, v) : v }

    /// Where `v` sits along the whole axis, 0 to 1.
    private func fraction(_ v: Double) -> Double {
        let lo = map(full.lowerBound), hi = map(full.upperBound)
        return hi > lo ? (map(v) - lo) / (hi - lo) : 0
    }

    /// `range` moved by `amount` of the whole axis, kept inside it.
    private func shifted(_ range: ClosedRange<Double>, by amount: Double) -> ClosedRange<Double> {
        let lo = map(full.lowerBound), hi = map(full.upperBound)
        let width = map(range.upperBound) - map(range.lowerBound)
        let a = min(max(map(range.lowerBound) + amount * (hi - lo), lo), hi - width)
        return unmap(a)...unmap(a + width)
    }

    private func centre(at f: Double) {
        let half = (fraction(shown.upperBound) - fraction(shown.lowerBound)) / 2
        scroll(shifted(shown, by: f - half - fraction(shown.lowerBound)))
    }
}

extension View {
    /// Adds scroll bars to move along a zoomed chart.
    func zoomScrollBars(_ zoom: Binding<ChartZoom>, xFull: ClosedRange<Double>, yFull: ClosedRange<Double>,
                        xLog: Bool = false, yShown: ClosedRange<Double>? = nil) -> some View {
        modifier(ZoomScrollBars(zoom: zoom, xFull: xFull, yFull: yFull, xLog: xLog,
                                yShown: yShown ?? zoom.wrappedValue.yDomain(yFull)))
    }

    /// Lets a drag across the chart zoom into it.
    func chartZoomDrag(_ zoom: Binding<ChartZoom>) -> some View { modifier(ZoomDrag(zoom: zoom)) }
}
/// Zoom to Range: the lowest and highest value to show on each axis, typed in.
private struct ZoomRangeForm: View {
    @Binding var zoom: ChartZoom
    let xFull: ClosedRange<Double>
    let yFull: ClosedRange<Double>
    let xLog: Bool
    let yShown: ClosedRange<Double>
    let done: () -> Void
    @State private var xMin = 0.0
    @State private var xMax = 0.0
    @State private var yMin = 0.0
    @State private var yMax = 0.0

    var body: some View {
        let valid = xMin < xMax && yMin < yMax && (!xLog || xMin > 0)
        VStack(alignment: .leading, spacing: 10) {
            Text("Zoom to Range").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Minimum").foregroundStyle(.secondary)
                    Text("Maximum").foregroundStyle(.secondary)
                }
                GridRow {
                    Text(xLog ? "X (Hz)" : "X")
                    field($xMin)
                    field($xMax)
                }
                GridRow {
                    Text("Y")
                    field($yMin)
                    field($yMax)
                }
            }
            Text(String(format: "X can go from %g to %g, Y from %.0f to %.0f.", xFull.lowerBound, xFull.upperBound,
                        yFull.lowerBound, yFull.upperBound))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Zoom") { apply(); done() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            let x = zoom.xDomain(xFull)
            (xMin, xMax, yMin, yMax) = (x.lowerBound, x.upperBound, yShown.lowerBound, yShown.upperBound)
        }
    }

    private func field(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.significantDigits(1...6)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 100)
    }

    /// Sets the zoom, kept within what each axis can show.
    private func apply() {
        let x = max(xMin, xFull.lowerBound)...max(min(xMax, xFull.upperBound), max(xMin, xFull.lowerBound) + 1e-9)
        let y = max(yMin, yFull.lowerBound)...max(min(yMax, yFull.upperBound), max(yMin, yFull.lowerBound) + 1e-9)
        zoom.x = x == xFull ? nil : x
        zoom.y = y
    }
}
#endif
