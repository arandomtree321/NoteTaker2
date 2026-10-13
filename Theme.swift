import SwiftUI
import UIKit

extension UIColor {
    /// Creates a color from an "RRGGBB" hex string (a leading # is allowed).
    convenience init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: String) { self.init(UIColor(hex: hex)) }
}

/// Black and green theme used across the whole app.
enum Theme {
    // SwiftUI colors
    static let background = Color(hex: "000000")
    static let surface = Color(hex: "0A0F0B")
    static let surfaceRaised = Color(hex: "121C15")
    static let accent = Color(hex: "22E36B")
    static let accentDim = Color(hex: "0F3D22")
    static let text = Color(hex: "E8F5EC")
    static let secondaryText = Color(hex: "7FA48B")

    // UIKit colors used by the canvas
    static let uiPage = UIColor(hex: "030504")
    static let uiGridMinor = UIColor(hex: "12301C")
    static let uiGridMajor = UIColor(hex: "1E5A33")
    static let uiAccent = UIColor(hex: "22E36B")
}

struct GreenButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.black : Theme.accent)
            .background(prominent ? Theme.accent : Theme.accentDim, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
