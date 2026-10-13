import SwiftUI

/// Bridges the SwiftUI toolbar and the UIKit canvas.
final class CanvasController: ObservableObject {
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasSelection = false

    weak var canvas: InkCanvasView? {
        didSet { refresh() }
    }

    /// Called by the canvas whenever its undo or selection state changes.
    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let c = self.canvas else { return }
            if self.canUndo != c.canUndo { self.canUndo = c.canUndo }
            if self.canRedo != c.canRedo { self.canRedo = c.canRedo }
            if self.hasSelection != c.hasSelection { self.hasSelection = c.hasSelection }
        }
    }

    func undo() { canvas?.undo() }
    func redo() { canvas?.redo() }
    func copy() { canvas?.copySelection() }
    func cut() { canvas?.cutSelection() }
    func paste() { canvas?.pasteFromClipboard() }
    func deleteSelection() { canvas?.deleteSelection() }
    func zoomIn() { canvas?.zoom(by: 1.6) }
    func zoomOut() { canvas?.zoom(by: 1 / 1.6) }
    func fit() { canvas?.fitContent() }
}
