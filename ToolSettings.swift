import SwiftUI

enum Tool: String, CaseIterable {
    case pen, highlighter, eraser, lasso
}

/// Shared drawing settings. The canvas reads these live, so changes apply immediately.
final class ToolSettings: ObservableObject {
    @Published var tool: Tool = .pen
    @Published var penColorHex = "22E36B"
    @Published var highlighterColorHex = "FFEB3B"
    /// Widths are in screen points, so ink looks the same thickness at any zoom level.
    @Published var penWidth: CGFloat = 3
    @Published var highlighterWidth: CGFloat = 20
    @Published var eraserRadius: CGFloat = 16
    @Published var fingerDrawing = false
    @Published var autoStraighten = true
    @Published var scribbleToDelete = true

    static let penPalette = ["22E36B", "FFFFFF", "FF5252", "40C4FF", "FFD740", "FF9100", "E040FB", "B2FF59", "9E9E9E"]
    static let highlighterPalette = ["FFEB3B", "69F0AE", "FF80AB", "80D8FF", "FFAB40", "B388FF"]
}
