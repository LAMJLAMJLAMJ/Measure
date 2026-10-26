#if os(macOS)
import Charts
import SwiftUI

/// One curve the data tip reads values from.
struct TipSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    /// Sorted by frequency.
    let points: [ChartPoint]

    /// The point nearest `f` on a log frequency axis.
    func value(at f: Double) -> ChartPoint? {
        guard !points.isEmpty, f > 0 else { return nil }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].x < f { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        guard a.x > 0, b.x > 0 else { return a.x > 0 ? a : b }
        return abs(log(a.x / f)) <= abs(log(b.x / f)) ? a : b
    }
}

/// A data tip for a frequency chart: hover to read the frequency and each curve's level under the
/// pointer, click to pin it there, click again to unpin. With a zoom, dragging across the chart zooms in.
struct FrequencyDataTip: ViewModifier {
    let series: [TipSeries]
    var unit = "dB"
    var zoom: Binding<ChartZoom>?
    @State private var hover: Double?
    @State private var pinned: Double?
    @State private var box: ZoomBox?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                if let anchor = proxy.plotFrame {
                    let plot = geo[anchor]
                    ZStack {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .frame(width: plot.width, height: plot.height)
                            .position(x: plot.midX, y: plot.midY)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let p): hover = proxy.value(atX: p.x - plot.minX)
                                case .ended: hover = nil
                                }
                            }
                            .onTapGesture { p in
                                if pinned != nil { pinned = nil } else { pinned = proxy.value(atX: p.x - plot.minX) }
                            }
                            .gesture(zoomDrag(proxy: proxy, plot: plot), including: zoom == nil ? .none : .all)
                        if let box {
                            box.view(in: plot)
                        } else if let f = pinned ?? hover {
                            tip(f, proxy: proxy, plot: plot)
                        }
                    }
                }
            }
        }
    }

    private func zoomDrag(proxy: ChartProxy, plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { box = ZoomBox(start: $0.startLocation, end: $0.location) }
            .onEnded { value in
                if let zoom {
                    ZoomBox(start: value.startLocation, end: value.location).apply(to: &zoom.wrappedValue, proxy: proxy, plot: plot)
                }
                box = nil
            }
    }

    @ViewBuilder
    private func tip(_ f: Double, proxy: ChartProxy, plot: CGRect) -> some View {
        let readings = series.prefix(8).compactMap { s in s.value(at: f).map { (s, $0) } }
        if let x = proxy.position(forX: f) {
            let lineX = plot.minX + x
            let onRight = lineX < plot.midX
            Path { path in
                path.move(to: CGPoint(x: lineX, y: plot.minY))
                path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
            }
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: pinned == nil ? [3, 3] : []))
            .allowsHitTesting(false)
            ForEach(readings, id: \.0.id) { s, p in
                if let y = proxy.position(forY: p.y), y >= 0, y <= plot.height {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                        .position(x: lineX, y: plot.minY + y)
                        .allowsHitTesting(false)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(frequencyText(f)).fontWeight(.semibold)
                ForEach(readings, id: \.0.id) { s, p in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(s.name).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                        Text(String(format: "%.1f %@", p.y, unit)).monospacedDigit()
                    }
                }
                if pinned != nil { Text("Click to unpin").foregroundStyle(.secondary) }
            }
            .font(.caption)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.top, 6)
            // Right of the line in the left half of the plot, left of it in the right half.
            .frame(width: max(1, onRight ? plot.maxX - lineX : lineX - plot.minX), height: plot.height,
                   alignment: onRight ? .topLeading : .topTrailing)
            .position(x: onRight ? (lineX + plot.maxX) / 2 : (plot.minX + lineX) / 2, y: plot.midY)
            .allowsHitTesting(false)
        }
    }

    private func frequencyText(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.2f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }
}

extension View {
    /// Adds a hover and click data tip to a chart with a log frequency axis.
    func frequencyDataTip(_ series: [TipSeries], unit: String = "dB", zoom: Binding<ChartZoom>? = nil) -> some View {
        modifier(FrequencyDataTip(series: series, unit: unit, zoom: zoom))
    }
}
#endif
