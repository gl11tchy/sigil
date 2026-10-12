import AppKit
import SwiftUI

/// Captures the seam on mouse-down, before window dragging can claim it.
struct DividerDragHandle: View {
    enum Direction: Double {
        case left = -1
        case right = 1
    }

    @Binding var width: Double
    let limits: ClosedRange<Double>
    let direction: Direction
    let onDragStart: () -> Void
    @State private var capture = Capture()

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in
                        guard let event = NSApp.currentEvent, let window = event.window else { return }
                        let started = !capture.isActive
                        if let next = capture.update(
                            with: event, in: window, width: width, limits: limits, direction: direction)
                        {
                            width = next
                            if started { onDragStart() }
                        }
                    }
                    .onEnded { _ in capture.end() }
            )
            .onChange(of: width) { _, value in capture.adopt(value, limits: limits) }
            .onDisappear { capture.end() }
    }

    struct Capture {
        private var previousScreenX: Double?
        private var dragWidth: Double?
        var isActive: Bool { previousScreenX != nil }

        mutating func update(
            with event: NSEvent, in window: NSWindow, width: Double,
            limits: ClosedRange<Double>, direction: Direction
        ) -> Double? {
            guard event.type == .leftMouseDown || event.type == .leftMouseDragged else { return nil }
            let x = window.convertPoint(toScreen: event.locationInWindow).x
            guard x.isFinite else { return nil }
            func clamp(_ value: Double) -> Double {
                min(limits.upperBound, max(limits.lowerBound, value))
            }
            guard let previousScreenX, let dragWidth, event.type != .leftMouseDown else {
                self.previousScreenX = x
                self.dragWidth = clamp(width)
                return self.dragWidth
            }
            // Consume movement at the bounds, so reversing has no overshoot dead zone.
            let next = clamp(dragWidth + direction.rawValue * (x - previousScreenX))
            self.previousScreenX = x
            self.dragWidth = next
            return next
        }

        mutating func adopt(_ width: Double, limits: ClosedRange<Double>) {
            if isActive { dragWidth = min(limits.upperBound, max(limits.lowerBound, width)) }
        }

        mutating func end() {
            previousScreenX = nil
            dragWidth = nil
        }
    }
}
