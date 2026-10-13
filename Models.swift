import Foundation
import CoreGraphics

// MARK: - Notebook structure (stored in notebook.json)

struct PageInfo: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
}

struct NotebookSection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var pages: [PageInfo] = []
}

struct Notebook: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var sections: [NotebookSection] = []
}

// MARK: - Page content (stored in pages/<pageID>.json)

struct InkStroke: Identifiable, Codable, Equatable {
    var id = UUID()
    var points: [CGPoint]
    /// Per-point width multipliers from Apple Pencil pressure. Empty means uniform width.
    var pressures: [CGFloat]
    var colorHex: String
    /// Width in page units.
    var width: CGFloat
    var isHighlighter: Bool
    private(set) var bounds: CGRect

    init(points: [CGPoint], pressures: [CGFloat], colorHex: String, width: CGFloat, isHighlighter: Bool) {
        self.points = points
        self.pressures = pressures
        self.colorHex = colorHex
        self.width = width
        self.isHighlighter = isHighlighter
        self.bounds = InkStroke.computeBounds(points: points, width: width)
    }

    static func computeBounds(points: [CGPoint], width: CGFloat) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = width * 0.9
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -pad, dy: -pad)
    }

    mutating func translate(by d: CGPoint) {
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        bounds = bounds.offsetBy(dx: d.x, dy: d.y)
    }
}

struct ImageElement: Identifiable, Codable, Equatable {
    var id = UUID()
    var imageData: Data
    var frame: CGRect
}

enum PageElement: Identifiable, Codable, Equatable {
    case stroke(InkStroke)
    case image(ImageElement)

    var id: UUID {
        switch self {
        case .stroke(let s): return s.id
        case .image(let i): return i.id
        }
    }

    var bounds: CGRect {
        switch self {
        case .stroke(let s): return s.bounds
        case .image(let i): return i.frame
        }
    }

    mutating func translate(by d: CGPoint) {
        switch self {
        case .stroke(var s):
            s.translate(by: d)
            self = .stroke(s)
        case .image(var i):
            i.frame = i.frame.offsetBy(dx: d.x, dy: d.y)
            self = .image(i)
        }
    }

    /// A copy with a fresh identity, used when pasting.
    func withNewID() -> PageElement {
        switch self {
        case .stroke(var s):
            s.id = UUID()
            return .stroke(s)
        case .image(var i):
            i.id = UUID()
            return .image(i)
        }
    }
}

struct PageContent: Codable {
    var elements: [PageElement] = []
}

// MARK: - Per-device view position (not synced, so each device keeps its own zoom)

enum ViewportStore {
    static func save(pageID: UUID, scale: CGFloat, offset: CGPoint) {
        UserDefaults.standard.set([Double(scale), Double(offset.x), Double(offset.y)], forKey: "viewport.\(pageID.uuidString)")
    }

    static func load(pageID: UUID) -> (scale: CGFloat, offset: CGPoint)? {
        guard let v = UserDefaults.standard.array(forKey: "viewport.\(pageID.uuidString)") as? [Double], v.count == 3 else { return nil }
        return (CGFloat(v[0]), CGPoint(x: v[1], y: v[2]))
    }
}
