import AppKit
import SwiftUI

struct HistoryViewportRequest: Equatable {
    let token = UUID()
    let point: CGPoint
}

struct HistoryPanRequest: Equatable {
    let token: UUID
    let translation: CGSize
}

/// AppKit owns wheel momentum and pinch magnification; SwiftUI supplies only the document.
struct NativeHistoryScrollView<Content: View>: NSViewRepresentable {
    @Binding var magnification: Double
    let documentSize: CGSize
    var focus: HistoryViewportRequest?
    var pan: HistoryPanRequest?
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(magnification: $magnification) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.55
        scroll.maxMagnification = 2.5
        scroll.usesPredominantAxisScrolling = false
        let host = NSHostingView(rootView: content())
        host.isFlipped = true
        host.frame = CGRect(origin: .zero, size: documentSize)
        host.sizingOptions = []
        scroll.documentView = host
        context.coordinator.host = host
        context.coordinator.scroll = scroll
        context.coordinator.observation = scroll.observe(\.magnification, options: [.new]) { [weak coordinator = context.coordinator] _, _ in
            Task { @MainActor in coordinator?.reportMagnification() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.magnification = $magnification
        coordinator.host?.rootView = content()
        if coordinator.host?.frame.size != documentSize { coordinator.host?.setFrameSize(documentSize) }
        let requested = CGFloat(min(2.5, max(0.55, magnification)))
        if abs(scroll.magnification - requested) > 0.001 {
            let visible = scroll.documentVisibleRect
            scroll.setMagnification(requested, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        }
        if let pan {
            if coordinator.lastPan != pan.token {
                coordinator.lastPan = pan.token
                coordinator.panOrigin = scroll.documentVisibleRect.origin
            }
            let scale = max(0.01, scroll.magnification)
            let origin = CGPoint(x: coordinator.panOrigin.x - pan.translation.width / scale,
                y: coordinator.panOrigin.y - pan.translation.height / scale)
            scroll.contentView.scroll(to: clamped(origin, scroll: scroll))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else { coordinator.lastPan = nil }
        if let focus, focus.token != coordinator.lastFocus {
            coordinator.lastFocus = focus.token
            let visible = scroll.documentVisibleRect
            let origin = CGPoint(x: focus.point.x - visible.width / 2, y: focus.point.y - visible.height / 2)
            scroll.contentView.scroll(to: clamped(origin, scroll: scroll))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func clamped(_ origin: CGPoint, scroll: NSScrollView) -> CGPoint {
        let visible = scroll.documentVisibleRect
        return CGPoint(x: min(max(0, origin.x), max(0, documentSize.width - visible.width)),
                       y: min(max(0, origin.y), max(0, documentSize.height - visible.height)))
    }

    @MainActor final class Coordinator {
        var magnification: Binding<Double>
        var host: NSHostingView<Content>?
        weak var scroll: NSScrollView?
        var observation: NSKeyValueObservation?
        var lastFocus: UUID?
        var lastPan: UUID?
        var panOrigin = CGPoint.zero

        init(magnification: Binding<Double>) { self.magnification = magnification }
        func reportMagnification() {
            guard let value = scroll?.magnification else { return }
            guard abs(magnification.wrappedValue - Double(value)) > 0.001 else { return }
            magnification.wrappedValue = Double(value)
        }
    }
}
