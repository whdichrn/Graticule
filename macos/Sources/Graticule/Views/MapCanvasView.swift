import AppKit
import SwiftUI

struct MapCanvasView: NSViewRepresentable {
    let imagePath: String?
    let mapBbox: [Double]?
    let hoverGrid: HoverGrid?
    let interactionMode: InteractionMode
    let fitRequestToken: Int
    let actualSizeRequestToken: Int
    let onHoverCoordinate: @MainActor ((lon: Double, lat: Double)?) -> Void
    let onZoomChanged: @MainActor (Double) -> Void
    let onBoxSelected: @MainActor (_ u0: Double, _ v0: Double, _ u1: Double, _ v1: Double, _ forceNewTab: Bool) -> Void

    func makeNSView(context: Context) -> MapCanvasNSView {
        let view = MapCanvasNSView()
        view.onHoverCoordinate = onHoverCoordinate
        view.onZoomChanged = onZoomChanged
        view.onBoxSelected = onBoxSelected
        return view
    }

    func updateNSView(_ nsView: MapCanvasNSView, context: Context) {
        nsView.onHoverCoordinate = onHoverCoordinate
        nsView.onZoomChanged = onZoomChanged
        nsView.onBoxSelected = onBoxSelected
        nsView.hoverGrid = hoverGrid
        nsView.mapBbox = mapBbox
        nsView.setInteractionMode(interactionMode)
        nsView.updateImage(path: imagePath)
        nsView.handleViewRequests(fitToken: fitRequestToken, actualToken: actualSizeRequestToken)
    }
}

@MainActor
final class MapCanvasNSView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    var onHoverCoordinate: ((lon: Double, lat: Double)?) -> Void = { _ in }
    var onZoomChanged: (Double) -> Void = { _ in }
    var onBoxSelected: (Double, Double, Double, Double, Bool) -> Void = { _, _, _, _, _ in }

    var hoverGrid: HoverGrid?
    var mapBbox: [Double]?

    private var loadedImagePath: String?
    private var cgImage: CGImage?
    private var imageSize: CGSize = .zero
    private var scale: CGFloat = 1.0
    private var offset: CGPoint = .zero
    private var hasInitializedFit = false

    private var interactionMode: InteractionMode = .pan
    private var isDraggingPan = false
    private var lastPanPoint: CGPoint = .zero
    private var isBoxSelecting = false
    private var boxStartPoint: CGPoint = .zero
    private var boxCurrentPoint: CGPoint = .zero
    private var boxSelectionForceNewTab = false

    private var lastFitToken: Int = 0
    private var lastActualToken: Int = 0
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = interactionMode == .select ? .crosshair : (isDraggingPan ? .closedHand : .openHand)
        addCursorRect(bounds, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasZero = bounds.width <= 1 || bounds.height <= 1
        super.setFrameSize(newSize)
        if wasZero && newSize.width > 1 && newSize.height > 1 && cgImage != nil && !hasInitializedFit {
            fitInView()
        }
    }

    func setInteractionMode(_ mode: InteractionMode) {
        guard interactionMode != mode else { return }
        interactionMode = mode
        isBoxSelecting = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func updateImage(path: String?) {
        guard path != loadedImagePath else { return }
        loadedImagePath = path
        guard let path,
              let nsImage = NSImage(contentsOfFile: path),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            cgImage = nil
            imageSize = .zero
            hasInitializedFit = false
            needsDisplay = true
            return
        }
        let previousSize = imageSize
        cgImage = cg
        imageSize = CGSize(width: cg.width, height: cg.height)
        if !hasInitializedFit || previousSize == .zero {
            fitInView()
        } else {
            fitInView()
        }
        needsDisplay = true
    }

    func handleViewRequests(fitToken: Int, actualToken: Int) {
        if fitToken != lastFitToken {
            lastFitToken = fitToken
            fitInView()
        }
        if actualToken != lastActualToken {
            lastActualToken = actualToken
            resetToActualSize()
        }
    }

    func fitInView() {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 16, bounds.height > 16 else {
            return
        }
        let padding: CGFloat = 24
        let availW = max(1, bounds.width - padding * 2)
        let availH = max(1, bounds.height - padding * 2)
        let nextScale = min(availW / imageSize.width, availH / imageSize.height)
        scale = max(0.05, min(20.0, nextScale))
        offset = CGPoint(
            x: (bounds.width - imageSize.width * scale) / 2.0,
            y: (bounds.height - imageSize.height * scale) / 2.0
        )
        hasInitializedFit = true
        onZoomChanged(Double(scale))
        needsDisplay = true
    }

    func resetToActualSize() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        scale = 1.0
        offset = CGPoint(
            x: (bounds.width - imageSize.width) / 2.0,
            y: (bounds.height - imageSize.height) / 2.0
        )
        hasInitializedFit = true
        onZoomChanged(1.0)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        NSColor.windowBackgroundColor.setFill()
        context.fill(bounds)

        if let cgImage, imageSize.width > 0, imageSize.height > 0 {
            let dest = CGRect(
                x: offset.x,
                y: offset.y,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )

            // Subtle paper shadow around rendered map
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.14).cgColor)
            NSColor.white.setFill()
            context.fill(dest)
            context.restoreGState()

            // Draw CGImage upright inside isFlipped == true view
            context.saveGState()
            context.interpolationQuality = .high
            context.translateBy(x: dest.minX, y: dest.maxY)
            context.scaleBy(x: 1.0, y: -1.0)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
            context.restoreGState()
        }

        if isBoxSelecting {
            let selRect = currentSelectionRect()
            if selRect.width >= 2, selRect.height >= 2 {
                let accent = NSColor.controlAccentColor
                context.saveGState()
                accent.withAlphaComponent(0.18).setFill()
                context.fill(selRect)
                accent.withAlphaComponent(0.9).setStroke()
                context.setLineWidth(1.5)
                context.stroke(selRect)
                context.restoreGState()
            }
        }
    }

    private func currentSelectionRect() -> CGRect {
        CGRect(
            x: min(boxStartPoint.x, boxCurrentPoint.x),
            y: min(boxStartPoint.y, boxCurrentPoint.y),
            width: abs(boxCurrentPoint.x - boxStartPoint.x),
            height: abs(boxCurrentPoint.y - boxStartPoint.y)
        )
    }

    private func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard imageSize.width > 0 else { return }
        let clampedScale = max(0.05, min(64.0, scale * factor))
        let effectiveFactor = clampedScale / scale
        guard abs(effectiveFactor - 1.0) > 1e-6 else { return }
        offset.x = anchor.x - (anchor.x - offset.x) * effectiveFactor
        offset.y = anchor.y - (anchor.y - offset.y) * effectiveFactor
        scale = clampedScale
        onZoomChanged(Double(scale))
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let factor = max(0.5, min(2.0, 1.0 + event.magnification))
        zoom(by: factor, anchor: anchor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard cgImage != nil else { return }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            needsDisplay = true
        } else {
            let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.25 : event.scrollingDeltaY * 3.0
            let factor = pow(2.0, rawDelta / 120.0)
            let anchor = convert(event.locationInWindow, from: nil)
            zoom(by: CGFloat(factor), anchor: anchor)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverCoordinate(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)
        let isOption = event.modifierFlags.contains(.option)
        let shouldBoxSelect = (interactionMode == .select || isShift || isOption) && cgImage != nil

        if shouldBoxSelect {
            isBoxSelecting = true
            boxStartPoint = pt
            boxCurrentPoint = pt
            boxSelectionForceNewTab = isOption
            needsDisplay = true
            return
        }

        if event.clickCount == 2 && cgImage != nil {
            fitInView()
            return
        }

        isDraggingPan = true
        lastPanPoint = pt
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if isBoxSelecting {
            boxCurrentPoint = pt
            needsDisplay = true
            return
        }
        if isDraggingPan {
            offset.x += pt.x - lastPanPoint.x
            offset.y += pt.y - lastPanPoint.y
            lastPanPoint = pt
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if isBoxSelecting {
            boxCurrentPoint = pt
            let rect = currentSelectionRect()
            isBoxSelecting = false
            needsDisplay = true

            if rect.width >= 12, rect.height >= 12, let bbox = mapBbox, bbox.count == 4 {
                let left = bbox[0], top = bbox[1], right = bbox[2], bottom = bbox[3]
                let px1 = Double((rect.minX - offset.x) / scale)
                let py1 = Double((rect.minY - offset.y) / scale)
                let px2 = Double((rect.maxX - offset.x) / scale)
                let py2 = Double((rect.maxY - offset.y) / scale)

                let cx1 = max(left, min(right, px1))
                let cy1 = max(top, min(bottom, py1))
                let cx2 = max(left, min(right, px2))
                let cy2 = max(top, min(bottom, py2))

                let frameW = max(1.0, right - left)
                let frameH = max(1.0, bottom - top)

                let u0 = (cx1 - left) / frameW
                let u1 = (cx2 - left) / frameW
                let v1 = 1.0 - (cy1 - top) / frameH
                let v0 = 1.0 - (cy2 - top) / frameH
                if u1 > u0, v1 > v0 {
                    onBoxSelected(u0, v0, u1, v1, boxSelectionForceNewTab)
                }
            }
            return
        }
        if isDraggingPan {
            isDraggingPan = false
            window?.invalidateCursorRects(for: self)
        }
    }

    private func updateHover(at point: CGPoint) {
        guard let hoverGrid, let bbox = mapBbox, bbox.count == 4, scale > 0 else {
            onHoverCoordinate(nil)
            return
        }
        let px = Double((point.x - offset.x) / scale)
        let py = Double((point.y - offset.y) / scale)
        let left = bbox[0], top = bbox[1], right = bbox[2], bottom = bbox[3]
        guard px >= left, px <= right, py >= top, py <= bottom else {
            onHoverCoordinate(nil)
            return
        }
        let u = (px - left) / max(1.0, right - left)
        let v = 1.0 - (py - top) / max(1.0, bottom - top)
        onHoverCoordinate(hoverGrid.coordinate(u: u, v: v))
    }
}
