import UIKit
import Combine

/// An infinite, zoomable page that you draw on with Apple Pencil.
///
/// Everything is stored in "page coordinates". The view maps them to the screen with
/// `screen = page * scale + offset`, so zooming never runs out of room and ink stays sharp.
/// Fingers pan and zoom (two fingers when finger drawing is on); the Pencil draws.
final class InkCanvasView: UIView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {

    static let pasteboardType = "com.notetaker.elements"
    private let minScale: CGFloat = 0.002
    private let maxScale: CGFloat = 500

    // MARK: Model

    private(set) var elements: [PageElement] = []
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGPoint = .zero

    var onChange: (() -> Void)?
    var onViewportChange: ((CGFloat, CGPoint) -> Void)?
    weak var controller: CanvasController?

    private let settings: ToolSettings
    private var bag = Set<AnyCancellable>()
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    // Undo / redo
    private var undoStack: [[PageElement]] = []
    private var redoStack: [[PageElement]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Selection
    private var selection = Set<UUID>()
    var hasSelection: Bool { !selection.isEmpty }

    private var imageCache: [UUID: UIImage] = [:]

    // Live touch state
    private var activeTouch: UITouch?
    private var activeTool: Tool?
    private var inkPoints: [CGPoint] = []
    private var inkPressures: [CGFloat] = []
    private var inkColorHex = "FFFFFF"
    private var inkWidth: CGFloat = 1
    private var lassoPoints: [CGPoint] = []
    private var eraseBase: [PageElement]?

    private enum Drag { case none, lasso, move, resize }
    private var drag: Drag = .none
    private var lastDragPoint: CGPoint = .zero
    private var dragBase: [PageElement]?

    private var previousTool: Tool = .pen
    private var pasteCount: CGFloat = 0

    // MARK: Setup

    init(settings: ToolSettings) {
        self.settings = settings
        super.init(frame: .zero)
        backgroundColor = Theme.uiPage
        contentMode = .redraw
        isMultipleTouchEnabled = true

        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = fingers
        pan.delegate = self
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = fingers
        pinch.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        // With finger drawing on, one finger draws and two fingers pan. Otherwise one finger pans.
        settings.$fingerDrawing
            .sink { [weak self] on in self?.pan.minimumNumberOfTouches = on ? 2 : 1 }
            .store(in: &bag)
        settings.$tool
            .sink { [weak self] tool in
                guard let self, tool != .lasso, !self.selection.isEmpty else { return }
                self.selection.removeAll()
                self.setNeedsDisplay()
                self.controller?.refresh()
            }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    func load(elements: [PageElement], viewport: (scale: CGFloat, offset: CGPoint)?) {
        self.elements = elements
        if let v = viewport {
            scale = min(max(v.scale, minScale), maxScale)
            offset = v.offset
        } else {
            scale = 1
            offset = CGPoint(x: 60, y: 60)
        }
        undoStack = []
        redoStack = []
        selection = []
        setNeedsDisplay()
    }

    // MARK: Coordinates

    private func pagePoint(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - offset.x) / scale, y: (s.y - offset.y) / scale)
    }

    private func pageRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: (r.minX - offset.x) / scale, y: (r.minY - offset.y) / scale,
               width: r.width / scale, height: r.height / scale)
    }

    private func invalidate(pageRect r: CGRect) {
        let s = CGRect(x: r.minX * scale + offset.x, y: r.minY * scale + offset.y,
                       width: r.width * scale, height: r.height * scale)
        setNeedsDisplay(s.insetBy(dx: -6, dy: -6))
    }

    // MARK: Pan and zoom

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .changed:
            let t = g.translation(in: self)
            offset = CGPoint(x: offset.x + t.x, y: offset.y + t.y)
            g.setTranslation(.zero, in: self)
            setNeedsDisplay()
        case .ended, .cancelled:
            viewportChanged()
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .changed:
            zoom(by: g.scale, about: g.location(in: self))
            g.scale = 1
        case .ended, .cancelled:
            viewportChanged()
        default:
            break
        }
    }

    private func zoom(by factor: CGFloat, about loc: CGPoint) {
        let newScale = min(max(scale * factor, minScale), maxScale)
        let ratio = newScale / scale
        offset = CGPoint(x: loc.x - (loc.x - offset.x) * ratio, y: loc.y - (loc.y - offset.y) * ratio)
        scale = newScale
        setNeedsDisplay()
    }

    func zoom(by factor: CGFloat) {
        zoom(by: factor, about: CGPoint(x: bounds.midX, y: bounds.midY))
        viewportChanged()
    }

    /// Zooms and pans so all content is visible. Useful for finding your way around an infinite page.
    func fitContent() {
        let box = elements.reduce(CGRect.null) { $0.union($1.bounds) }
        if box.isNull || bounds.width <= 0 {
            scale = 1
            offset = CGPoint(x: 60, y: 60)
        } else {
            let margin: CGFloat = 60
            let sx = (bounds.width - 2 * margin) / max(box.width, 1)
            let sy = (bounds.height - 2 * margin) / max(box.height, 1)
            scale = min(max(min(sx, sy), minScale), 8)
            offset = CGPoint(x: bounds.midX - box.midX * scale, y: bounds.midY - box.midY * scale)
        }
        viewportChanged()
    }

    private func viewportChanged() {
        setNeedsDisplay()
        onViewportChange?(scale, offset)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Touch handling (Apple Pencil draws)

    private func isDrawingTouch(_ t: UITouch) -> Bool {
        switch t.type {
        case .pencil, .indirectPointer: return true
        case .direct: return settings.fingerDrawing
        default: return false
        }
    }

    private func pressure(of t: UITouch) -> CGFloat {
        guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 1 }
        let n = t.force / t.maximumPossibleForce
        return min(1.5, max(0.35, 0.45 + n * 1.1))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder { becomeFirstResponder() }
        if let t = activeTouch, t.phase == .ended || t.phase == .cancelled {
            activeTouch = nil
            resetLiveState()
        }
        guard activeTouch == nil, let touch = touches.first(where: isDrawingTouch) else { return }
        activeTouch = touch
        let p = pagePoint(touch.location(in: self))
        let tool = settings.tool
        activeTool = tool
        switch tool {
        case .pen:
            inkColorHex = settings.penColorHex
            inkWidth = settings.penWidth / scale
            inkPoints = [p]
            inkPressures = [pressure(of: touch)]
        case .highlighter:
            inkColorHex = settings.highlighterColorHex
            inkWidth = settings.highlighterWidth / scale
            inkPoints = [p]
            inkPressures = [1]
        case .eraser:
            eraseBase = elements
            erase(at: p)
        case .lasso:
            beginLasso(at: p)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for s in samples { move(to: pagePoint(s.location(in: self)), touch: s) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        move(to: pagePoint(touch.location(in: self)), touch: touch)
        finishInteraction()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Nothing in progress is committed, for example when a second finger starts a pinch.
        activeTouch = nil
        resetLiveState()
        setNeedsDisplay()
        controller?.refresh()
    }

    private func move(to p: CGPoint, touch: UITouch) {
        switch activeTool {
        case .pen, .highlighter:
            guard let last = inkPoints.last else { return }
            if hypot(p.x - last.x, p.y - last.y) * scale < 0.6 { return }
            inkPoints.append(p)
            inkPressures.append(activeTool == .pen ? pressure(of: touch) : 1)
            let box = CGRect(x: min(p.x, last.x), y: min(p.y, last.y), width: abs(p.x - last.x), height: abs(p.y - last.y))
            invalidate(pageRect: box.insetBy(dx: -inkWidth * 1.6, dy: -inkWidth * 1.6))
        case .eraser:
            erase(at: p)
        case .lasso:
            moveLasso(to: p)
        case .none:
            break
        }
    }

    private func finishInteraction() {
        let tool = activeTool
        activeTouch = nil
        switch tool {
        case .pen, .highlighter: finishInk(tool: tool ?? .pen)
        case .eraser: eraseBase = nil
        case .lasso: finishLasso()
        case .none: break
        }
        resetLiveState()
        setNeedsDisplay()
        controller?.refresh()
    }

    private func resetLiveState() {
        activeTool = nil
        inkPoints = []
        inkPressures = []
        lassoPoints = []
        eraseBase = nil
        drag = .none
        dragBase = nil
    }

    // MARK: Finishing a stroke

    private func finishInk(tool: Tool) {
        var points = inkPoints
        var pressures = inkPressures
        if points.count == 1, let p = points.first {
            // A tap makes a dot.
            points.append(CGPoint(x: p.x + 0.01 / scale, y: p.y))
            pressures.append(pressures.first ?? 1)
        }
        guard points.count >= 2 else { return }

        // Scribbling over existing ink deletes it.
        if tool == .pen, settings.scribbleToDelete, let victims = scribbleVictims(for: points), !victims.isEmpty {
            commit(elements.filter { !victims.contains($0.id) })
            selection.subtract(victims)
            return
        }

        let isHighlighter = tool == .highlighter
        var width = inkWidth
        var uniform = isHighlighter || pressures.allSatisfy { abs($0 - 1) < 0.001 }

        // A straight-ish line becomes a perfectly straight one.
        if settings.autoStraighten, let line = straightened(points) {
            if !pressures.isEmpty && !isHighlighter {
                width *= pressures.reduce(0, +) / CGFloat(pressures.count)
            }
            points = line
            uniform = true
        }

        let stroke = InkStroke(
            points: points,
            pressures: uniform ? [] : pressures,
            colorHex: inkColorHex,
            width: width,
            isHighlighter: isHighlighter
        )
        commit(elements + [.stroke(stroke)])
    }

    /// Returns a two-point line if the stroke was meant to be straight.
    private func straightened(_ pts: [CGPoint]) -> [CGPoint]? {
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return nil }
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len * scale >= 40 else { return nil }
        guard pathLength(pts) / len < 1.1 else { return nil }
        var maxDeviation: CGFloat = 0
        for p in pts {
            let d = abs((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) / len
            maxDeviation = max(maxDeviation, d)
        }
        guard maxDeviation / len < 0.05 else { return nil }

        // Snap to perfectly horizontal or vertical when very close.
        var end = b
        let angle = atan2(b.y - a.y, b.x - a.x)
        let snap: CGFloat = 4 * .pi / 180
        for target in [0, CGFloat.pi / 2, CGFloat.pi, -CGFloat.pi / 2, -CGFloat.pi] where abs(angle - target) < snap {
            end = CGPoint(x: a.x + cos(target) * len, y: a.y + sin(target) * len)
        }
        return [a, end]
    }

    /// If the stroke is a scribble, returns the elements it covers (possibly empty).
    private func scribbleVictims(for points: [CGPoint]) -> Set<UUID>? {
        guard points.count >= 12, !elements.isEmpty else { return nil }

        // Resample so tiny jitters don't count as direction changes.
        var sampled = [points[0]]
        for p in points.dropFirst() {
            if let last = sampled.last, hypot(p.x - last.x, p.y - last.y) * scale >= 8 { sampled.append(p) }
        }
        guard sampled.count >= 8 else { return nil }

        var reversals = 0
        var pathLen: CGFloat = 0
        var previous: CGVector?
        for i in 1..<sampled.count {
            let d = CGVector(dx: sampled[i].x - sampled[i - 1].x, dy: sampled[i].y - sampled[i - 1].y)
            let len = hypot(d.dx, d.dy)
            pathLen += len
            if let pv = previous {
                let dot = (pv.dx * d.dx + pv.dy * d.dy) / (hypot(pv.dx, pv.dy) * len)
                if dot < -0.2 { reversals += 1 }
            }
            previous = d
        }

        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let diagonal = hypot(box.width, box.height) * scale
        guard reversals >= 4, diagonal > 20, pathLen * scale / diagonal >= 3 else { return nil }

        let area = box.insetBy(dx: -6 / scale, dy: -6 / scale)
        var victims = Set<UUID>()
        for el in elements {
            let b = el.bounds
            guard b.intersects(area) else { continue }
            let overlap = b.intersection(area)
            let ratio = (overlap.width * overlap.height) / max(b.width * b.height, 1e-9)
            if ratio >= 0.5 { victims.insert(el.id) }
        }
        return victims
    }

    // MARK: Eraser

    private func erase(at p: CGPoint) {
        let r = settings.eraserRadius / scale
        let hitRect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        var removed = Set<UUID>()
        for el in elements {
            guard case .stroke(let s) = el, s.bounds.intersects(hitRect) else { continue }
            if strokeTouches(s, p, r) { removed.insert(s.id) }
        }
        guard !removed.isEmpty else { return }
        if let base = eraseBase {
            pushUndo(base)
            eraseBase = nil
        }
        elements.removeAll { removed.contains($0.id) }
        selection.subtract(removed)
        changed()
    }

    private func strokeTouches(_ s: InkStroke, _ p: CGPoint, _ radius: CGFloat) -> Bool {
        let reach = radius + s.width / 2
        if s.points.count == 1 { return hypot(p.x - s.points[0].x, p.y - s.points[0].y) <= reach }
        for i in 1..<s.points.count where distance(from: p, toSegment: s.points[i - 1], s.points[i]) <= reach {
            return true
        }
        return false
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count { total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        return total
    }

    // MARK: Lasso selection, moving and resizing

    private var selectionBounds: CGRect? {
        guard !selection.isEmpty else { return nil }
        let box = elements.filter { selection.contains($0.id) }.reduce(CGRect.null) { $0.union($1.bounds) }
        return box.isNull ? nil : box
    }

    /// Corner handle for resizing a single selected image.
    private var resizeHandleCenter: CGPoint? {
        guard selection.count == 1,
              let el = elements.first(where: { selection.contains($0.id) }),
              case .image(let img) = el else { return nil }
        return CGPoint(x: img.frame.maxX, y: img.frame.maxY)
    }

    private func beginLasso(at p: CGPoint) {
        if let box = selectionBounds {
            if let c = resizeHandleCenter, hypot(p.x - c.x, p.y - c.y) <= 28 / scale {
                drag = .resize
                lastDragPoint = p
                dragBase = elements
                return
            }
            if box.insetBy(dx: -8 / scale, dy: -8 / scale).contains(p) {
                drag = .move
                lastDragPoint = p
                dragBase = elements
                return
            }
        }
        selection.removeAll()
        drag = .lasso
        lassoPoints = [p]
        controller?.refresh()
    }

    private func moveLasso(to p: CGPoint) {
        switch drag {
        case .lasso:
            lassoPoints.append(p)
            setNeedsDisplay()
        case .move:
            let d = CGPoint(x: p.x - lastDragPoint.x, y: p.y - lastDragPoint.y)
            guard d != .zero else { return }
            lastDragPoint = p
            if let base = dragBase {
                pushUndo(base)
                dragBase = nil
            }
            for i in elements.indices where selection.contains(elements[i].id) {
                elements[i].translate(by: d)
            }
            onChange?()
            setNeedsDisplay()
        case .resize:
            guard let idx = elements.firstIndex(where: { selection.contains($0.id) }),
                  case .image(var img) = elements[idx] else { return }
            if let base = dragBase {
                pushUndo(base)
                dragBase = nil
            }
            let aspect = img.frame.height / max(img.frame.width, 1e-9)
            let newWidth = max(24 / scale, p.x - img.frame.minX)
            img.frame = CGRect(x: img.frame.minX, y: img.frame.minY, width: newWidth, height: newWidth * aspect)
            elements[idx] = .image(img)
            onChange?()
            setNeedsDisplay()
        case .none:
            break
        }
    }

    private func finishLasso() {
        guard drag == .lasso else { return }
        if pathLength(lassoPoints) * scale < 12 {
            selectElement(at: lassoPoints.first ?? .zero)
        } else {
            selectInside(lassoPoints)
        }
    }

    private func selectInside(_ poly: [CGPoint]) {
        guard poly.count >= 3 else { return }
        let path = UIBezierPath()
        path.move(to: poly[0])
        for p in poly.dropFirst() { path.addLine(to: p) }
        path.close()
        let area = path.bounds
        var ids = Set<UUID>()
        for el in elements {
            guard el.bounds.intersects(area) else { continue }
            switch el {
            case .stroke(let s):
                var inside = 0, total = 0
                for i in s.points.indices {
                    total += 1
                    if path.contains(s.points[i]) { inside += 1 }
                    if i > 0 {
                        total += 1
                        let a = s.points[i - 1], b = s.points[i]
                        if path.contains(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) { inside += 1 }
                    }
                }
                if total > 0, Double(inside) / Double(total) >= 0.5 { ids.insert(s.id) }
            case .image(let img):
                if path.contains(CGPoint(x: img.frame.midX, y: img.frame.midY)) { ids.insert(img.id) }
            }
        }
        selection = ids
    }

    /// A tap with the lasso tool selects the element under the pencil.
    private func selectElement(at p: CGPoint) {
        let slop = 12 / scale
        for el in elements.reversed() {
            switch el {
            case .stroke(let s):
                if s.bounds.insetBy(dx: -slop, dy: -slop).contains(p), strokeTouches(s, p, slop) {
                    selection = [s.id]
                    return
                }
            case .image(let img):
                if img.frame.contains(p) {
                    selection = [img.id]
                    return
                }
            }
        }
    }

    // MARK: Undo and redo

    private func pushUndo(_ base: [PageElement]) {
        undoStack.append(base)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func commit(_ newElements: [PageElement]) {
        pushUndo(elements)
        elements = newElements
        changed()
    }

    private func changed() {
        if imageCache.count > 40 {
            let live = Set(elements.map(\.id))
            imageCache = imageCache.filter { live.contains($0.key) }
        }
        onChange?()
        controller?.refresh()
        setNeedsDisplay()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = previous
        selection = selection.intersection(Set(elements.map(\.id)))
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = next
        selection = selection.intersection(Set(elements.map(\.id)))
        changed()
    }

    // MARK: Copy, cut, paste, delete

    func deleteSelection() {
        guard hasSelection else { return }
        commit(elements.filter { !selection.contains($0.id) })
        selection.removeAll()
        controller?.refresh()
    }

    func copySelection() {
        let selected = elements.filter { selection.contains($0.id) }
        guard !selected.isEmpty, let data = try? JSONEncoder().encode(selected) else { return }
        var item: [String: Any] = [Self.pasteboardType: data]
        // A single image can also be pasted into other apps.
        if selected.count == 1, case .image(let img) = selected[0], let png = UIImage(data: img.imageData)?.pngData() {
            item["public.png"] = png
        }
        UIPasteboard.general.setItems([item], options: [:])
        pasteCount = 0
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func pasteFromClipboard() {
        let pb = UIPasteboard.general
        let center = pagePoint(CGPoint(x: bounds.midX, y: bounds.midY))

        if let data = pb.data(forPasteboardType: Self.pasteboardType),
           let items = try? JSONDecoder().decode([PageElement].self, from: data), !items.isEmpty {
            // Elements copied inside the app: paste near the middle of the screen, nudging repeat pastes.
            var fresh = items.map { $0.withNewID() }
            let box = fresh.reduce(CGRect.null) { $0.union($1.bounds) }
            let nudge = (pasteCount + 1) * 20 / scale
            pasteCount += 1
            let d = CGPoint(x: center.x - box.midX + nudge, y: center.y - box.midY + nudge)
            for i in fresh.indices { fresh[i].translate(by: d) }
            commit(elements + fresh)
            selection = Set(fresh.map(\.id))
            settings.tool = .lasso
        } else if let image = pb.image, let data = Self.encode(image) {
            // An image from Photos, Safari, another app, and so on.
            let aspect = image.size.height / max(image.size.width, 1)
            var w = bounds.width * 0.45 / scale
            if w * aspect > bounds.height * 0.7 / scale { w = bounds.height * 0.7 / scale / aspect }
            let frame = CGRect(x: center.x - w / 2, y: center.y - w * aspect / 2, width: w, height: w * aspect)
            let element = ImageElement(imageData: data, frame: frame)
            commit(elements + [.image(element)])
            selection = [element.id]
            settings.tool = .lasso
        }
        controller?.refresh()
        setNeedsDisplay()
    }

    private static func encode(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 2000
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let alphaInfo = image.cgImage?.alphaInfo
        let hasAlpha = !(alphaInfo == nil || alphaInfo == CGImageAlphaInfo.none
                         || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)
        var result = image
        let longest = max(pixelSize.width, pixelSize.height)
        if longest > maxSide {
            let k = maxSide / longest
            let size = CGSize(width: pixelSize.width * k, height: pixelSize.height * k)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = !hasAlpha
            result = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return hasAlpha ? result.pngData() : result.jpegData(compressionQuality: 0.85)
    }

    override func copy(_ sender: Any?) { copySelection() }
    override func cut(_ sender: Any?) { cutSelection() }
    override func paste(_ sender: Any?) { pasteFromClipboard() }

    override func selectAll(_ sender: Any?) {
        selection = Set(elements.map(\.id))
        settings.tool = .lasso
        controller?.refresh()
        setNeedsDisplay()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(UIResponderStandardEditActions.copy(_:)), #selector(UIResponderStandardEditActions.cut(_:)):
            return hasSelection
        case #selector(UIResponderStandardEditActions.paste(_:)):
            return UIPasteboard.general.contains(pasteboardTypes: [Self.pasteboardType]) || UIPasteboard.general.hasImages
        case #selector(UIResponderStandardEditActions.selectAll(_:)):
            return !elements.isEmpty
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    // Keyboard shortcuts for an attached keyboard.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoCommand)),
            UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoCommand)),
            UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(deleteCommand)),
        ]
    }

    @objc private func undoCommand() { undo() }
    @objc private func redoCommand() { redo() }
    @objc private func deleteCommand() { deleteSelection() }

    // MARK: Pencil double-tap switches to the eraser and back

    private func toggleEraser() {
        if settings.tool == .eraser {
            settings.tool = previousTool
        } else {
            previousTool = settings.tool
            settings.tool = .eraser
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { toggleEraser() }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        toggleEraser()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(Theme.uiPage.cgColor)
        ctx.fill(rect)
        drawGrid(in: ctx, rect: rect)

        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: scale, y: scale)
        let visible = pageRect(fromScreen: rect).insetBy(dx: -2 / scale, dy: -2 / scale)

        for case .image(let img) in elements where img.frame.intersects(visible) {
            drawImage(img)
        }

        // Highlighters sit under pen ink so writing never gets hidden.
        for case .stroke(let s) in elements where s.isHighlighter && s.bounds.intersects(visible) {
            draw(stroke: s, in: ctx)
        }
        let live = liveStroke
        if let live, live.isHighlighter { draw(stroke: live, in: ctx) }

        for case .stroke(let s) in elements where !s.isHighlighter && s.bounds.intersects(visible) {
            draw(stroke: s, in: ctx)
        }
        if let live, !live.isHighlighter { draw(stroke: live, in: ctx) }

        drawSelectionOverlay(in: ctx)
        ctx.restoreGState()
    }

    private var liveStroke: InkStroke? {
        guard let tool = activeTool, tool == .pen || tool == .highlighter, !inkPoints.isEmpty else { return nil }
        return InkStroke(
            points: inkPoints,
            pressures: tool == .pen ? inkPressures : [],
            colorHex: inkColorHex,
            width: inkWidth,
            isHighlighter: tool == .highlighter
        )
    }

    private func draw(stroke s: InkStroke, in ctx: CGContext) {
        let color = UIColor(hex: s.colorHex)
        let minWidth = 0.75 / scale
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if s.points.count == 1, let p = s.points.first {
            let w = max(s.width, minWidth)
            ctx.setFillColor((s.isHighlighter ? color.withAlphaComponent(0.4) : color).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - w / 2, y: p.y - w / 2, width: w, height: w))
            return
        }

        if s.isHighlighter {
            ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(max(s.width, minWidth))
            ctx.addLines(between: s.points)
            ctx.strokePath()
            return
        }

        ctx.setStrokeColor(color.cgColor)
        if s.pressures.count == s.points.count {
            for i in 1..<s.points.count {
                ctx.setLineWidth(max(s.width * (s.pressures[i - 1] + s.pressures[i]) / 2, minWidth))
                ctx.move(to: s.points[i - 1])
                ctx.addLine(to: s.points[i])
                ctx.strokePath()
            }
        } else {
            ctx.setLineWidth(max(s.width, minWidth))
            ctx.addLines(between: s.points)
            ctx.strokePath()
        }
    }

    private func drawImage(_ img: ImageElement) {
        let ui: UIImage
        if let cached = imageCache[img.id] {
            ui = cached
        } else if let decoded = UIImage(data: img.imageData) {
            imageCache[img.id] = decoded
            ui = decoded
        } else {
            return
        }
        ui.draw(in: img.frame)
    }

    private func drawSelectionOverlay(in ctx: CGContext) {
        ctx.setStrokeColor(Theme.uiAccent.cgColor)
        ctx.setLineWidth(1.5 / scale)

        if let box = selectionBounds {
            ctx.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
            ctx.stroke(box.insetBy(dx: -4 / scale, dy: -4 / scale))
            ctx.setLineDash(phase: 0, lengths: [])
            if let c = resizeHandleCenter {
                let d = 16 / scale
                ctx.setFillColor(Theme.uiAccent.cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            }
        }

        if drag == .lasso, lassoPoints.count > 1 {
            ctx.setLineDash(phase: 0, lengths: [5 / scale, 4 / scale])
            ctx.addLines(between: lassoPoints)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    /// Graph paper that adapts to the zoom level: finer squares appear as you zoom in, coarser ones as you zoom out.
    private func drawGrid(in ctx: CGContext, rect: CGRect) {
        var step: CGFloat = 32
        while step * scale < 14 { step *= 5 }
        while step * scale >= 70 { step /= 5 }
        let spacing = step * scale
        let minorAlpha = min(1, max(0, (spacing - 14) / 16))

        let x0 = (rect.minX - offset.x) / scale, x1 = (rect.maxX - offset.x) / scale
        let y0 = (rect.minY - offset.y) / scale, y1 = (rect.maxY - offset.y) / scale
        let i0 = Int(floor(x0 / step)), i1 = Int(ceil(x1 / step))
        let j0 = Int(floor(y0 / step)), j1 = Int(ceil(y1 / step))
        guard i1 - i0 < 500, j1 - j0 < 500 else { return }

        ctx.setLineWidth(1 / max(traitCollection.displayScale, 1))
        for pass in 0..<2 {
            let major = pass == 1
            let color = major ? Theme.uiGridMajor : Theme.uiGridMinor.withAlphaComponent(minorAlpha)
            ctx.setStrokeColor(color.cgColor)
            for i in i0...i1 where (i % 5 == 0) == major {
                let x = offset.x + CGFloat(i) * spacing
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for j in j0...j1 where (j % 5 == 0) == major {
                let y = offset.y + CGFloat(j) * spacing
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            ctx.strokePath()
        }
    }
}
